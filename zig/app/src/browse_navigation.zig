//! Stage 1 的目录导航。历史只在这里改变；枚举、分页、预算和 reconcile 仍归原 Session。
//! 每次切换都是 source epoch+1，旧监听先关闭，新监听先于新枚举架好。

const std = @import("std");
const core = @import("otto_core");
const browse = @import("browse.zig");
const selection_mod = @import("selection.zig");
const reconcile = @import("browse_reconcile.zig");

pub const Error = error{
    OutOfMemory,
    NotDirectory,
    AtFilesystemRoot,
    NoBackHistory,
    NoForwardHistory,
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

const Mode = enum { push, back, forward };

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
