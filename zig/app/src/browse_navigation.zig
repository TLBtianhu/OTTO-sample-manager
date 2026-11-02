//! Stage 1 的目录导航。历史只在这里改变；枚举、分页、预算和 reconcile 仍归原 Session。
//! 每次切换都是 source epoch+1，旧监听先关闭，新监听先于新枚举架好。

const std = @import("std");
const core = @import("otto_core");
const browse = @import("browse.zig");
const selection_mod = @import("selection.zig");
const reconcile = @import("browse_reconcile.zig");
const crumbs = @import("browse_crumbs.zig");
const types = @import("browse_types.zig");
const browse_dir = @import("otto_browse_dir");

pub const Error = error{
    OutOfMemory,
    NotDirectory,
    PathNotFound,
    InvalidPath,
    AccessDenied,
    NotReady,
    Unexpected,
    AtFilesystemRoot,
    NoBackHistory,
    NoForwardHistory,
    InvalidCrumb,
};

pub fn enterIndex(
    session: *browse.Session,
    index: usize,
    selected: *selection_mod.Selection,
) Error!void {
    if (index >= session.entries.items.len or !session.entries.items[index].is_directory) {
        return error.NotDirectory;
    }
    try activate(session, session.entries.items[index].path, selected, .push);
}

pub fn back(session: *browse.Session, selected: *selection_mod.Selection) Error!void {
    if (!session.history.canBack()) return error.NoBackHistory;
    try activate(session, session.history.records.items[session.history.index - 1].path, selected, .back);
}

pub fn forward(session: *browse.Session, selected: *selection_mod.Selection) Error!void {
    if (!session.history.canForward()) return error.NoForwardHistory;
    try activate(session, session.history.records.items[session.history.index + 1].path, selected, .forward);
}

pub fn up(session: *browse.Session, selected: *selection_mod.Selection) Error!void {
    const parent = std.fs.path.dirname(session.root) orelse return error.AtFilesystemRoot;
    if (parent.len == 0 or std.ascii.eqlIgnoreCase(parent, session.root)) return error.AtFilesystemRoot;
    try activate(session, parent, selected, .push);
}

/// 地址栏提交：这是唯一允许把用户文本变成磁盘查询的地方。set/编辑阶段不会调用这里。
/// 先解析并 stat，成功后才进入 activate；失败时路径、历史和列表均保持原样。
pub fn enterPath(
    session: *browse.Session,
    input: []const u8,
    selected: *selection_mod.Selection,
) Error!void {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidPath;
    // 地址栏里的 `C:` 按资源管理器习惯表示盘根，而不是驱动器相对当前目录。
    const rooted = if (trimmed.len == 2 and trimmed[1] == ':')
        try std.fmt.allocPrint(session.allocator, "{s}\\", .{trimmed})
    else
        try session.allocator.dupe(u8, trimmed);
    defer session.allocator.free(rooted);
    const candidate = try std.fs.path.resolveAlloc(session.allocator, &.{ session.root, rooted });
    defer session.allocator.free(candidate);
    const attributes = browse_dir.attributesOf(session.allocator, candidate) catch |err| return mapPathError(err);
    if (attributes & browse_dir.FILE_ATTRIBUTE_DIRECTORY == 0) return error.NotDirectory;
    const absolute = types.realPathAlloc(session.allocator, session.io, candidate) catch |err| return mapPathError(err);
    defer session.allocator.free(absolute);
    if (std.ascii.eqlIgnoreCase(absolute, session.root)) return;
    try activate(session, absolute, selected, .push);
}

/// 点击面包屑与地址栏共用 activate/push；最后一层就是当前目录，不制造重复历史。
pub fn crumb(session: *browse.Session, index: usize, selected: *selection_mod.Selection) Error!void {
    const target = crumbs.pathAt(session.root, index) orelse return error.InvalidCrumb;
    if (index + 1 == crumbs.count(session.root)) return;
    try activate(session, target, selected, .push);
}

pub fn drive(session: *browse.Session, letter: u8, selected: *selection_mod.Selection) Error!void {
    if (!std.ascii.isAlphabetic(letter)) return error.InvalidPath;
    const root = [3]u8{ std.ascii.toUpper(letter), ':', '\\' };
    try enterPath(session, &root, selected);
}

fn mapPathError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.FileNotFound, error.PathNotFound => error.PathNotFound,
        error.NotDir => error.NotDirectory,
        error.AccessDenied => error.AccessDenied,
        error.NotReady => error.NotReady,
        error.InvalidUtf8, error.NameTooLong => error.InvalidPath,
        else => error.Unexpected,
    };
}

const Mode = enum { push, back, forward };

/// F5：先捕获选中身份，再 epoch+1 全量重枚举；不改历史、不清空草稿。
pub fn refresh(session: *browse.Session, selected: *selection_mod.Selection) Error!void {
    try session.tracker.capture(session.io, session.entries.items, selected, &session.unreadable);
    reconcile.startRescan(session, session.last_event_seq);
}

/// 路径不可用后的交互重试：不轮询，成功才重开监听与枚举。
pub fn retryUnavailable(session: *browse.Session) void {
    if (!session.unavailable) return;
    const stat = std.Io.Dir.cwd().statFile(session.io, session.root, .{}) catch return;
    if (stat.kind != .directory) return;
    session.closeWatcher();
    session.reopenWatcher();
    if (session.watch_enabled and session.watcher == null) return;
    session.unavailable = false;
    session.denied = false;
    session.path_error = null;
    session.reconciling = false;
    session.replay_after_rescan = false;
    session.reconcile_again = false;
    reconcile.startRescan(session, session.last_event_seq);
}

fn activate(
    session: *browse.Session,
    target: []const u8,
    selected: *selection_mod.Selection,
    mode: Mode,
) Error!void {
    // 先把离开目录的选中项存进它自己的历史节点；新根与 Source 路径均先分配。
    try session.history.remember(session.io, session.entries.items, selected, &session.unreadable);
    const new_root = try session.allocator.dupe(u8, target);
    errdefer session.allocator.free(new_root);

    switch (mode) {
        .push => _ = try session.history.push(target),
        .back => _ = session.history.back(),
        .forward => _ = session.history.forward(),
    }

    session.closeWatcher();
    try session.source.requestNavigate(session.history.current().path);
    session.allocator.free(session.root);
    session.root = new_root;
    session.name = if (core.model.baseName(new_root).len > 0) core.model.baseName(new_root) else new_root;
    session.reopenWatcher();

    session.started_ns = @import("browse_types.zig").nowNs(session.io);
    session.first_page_ns = null;
    session.done_ns = null;
    session.unavailable = false;
    session.denied = false;
    session.path_error = null;
    session.enumerating = true;
    session.loading_more = false;
    session.has_more = false;
    session.truncated = false;
    session.mem_refused = false;
    session.remaining = 0;
    session.skipped = 0;
    session.pages = 0;
    session.swapping = true;
    session.restore_pending = false;
    session.navigation_restore = true;
    session.needs_sort = false;
    session.tracker.reset();
    selected.clear();

    // 新 watcher 的序号从 1 开始；旧目录事件绝不 replay 到新目录。
    session.last_event_seq = 0;
    session.rescan_seq = 0;
    session.reconciling = true;
    session.replay_after_rescan = false;
    session.reconcile_again = false;
    session.rescans += 1;
}
