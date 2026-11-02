//! `zig/ports` 的监听事件 → `zig/core` 的 `Change`：**唯一的翻译层**，外加监听根的
//! 路径规则。纯字符串逻辑，不碰文件系统、不碰 UI，可以用合成事件直接测试。
//!
//! 分工（CHARTER「八、零转义的边界」）：
//!   * `zig/ports` 只认路径字节（相对被监视目录的 WTF-8），不认识样本、id、分组；
//!   * `zig/core` 只认 `Change` 里的绝对路径，不碰文件系统、不碰 Win32；
//!   * 本文件是两者之间唯一的翻译：相对 → 绝对、kind → `Change` 变体、
//!     `overflow.lost` → `Change.overflow`；
//!   * 只做适配、不替 `Index` 做决定：`renamed` 找不到 `from` 时怎么处理是
//!     `index.zig` 的语义（降级成 `created`，计入 `added`），这里不重复实现。
//!
//! 路径适配规则（`adapt`）：
//!   * ports 的路径是**相对 root** 的 WTF-8；`std.fs.path.join` 拼成绝对路径，
//!     Windows 下用 `\` 连接，分隔符重复由 join 自己折叠；
//!   * `renamed` 的 `from` / `to` 都要 join；`to` 为空的事件直接丢弃
//!     （`Index.applyRenamed` 对空 `to` 也是忽略），`from` 为空时原样交给
//!     `Index` 处理（它会按 `created` 收下新路径）；
//!   * `overflow` 没有路径，`lost` 原样透传；空路径的路径事件丢弃。
//!
//! 调用方是 `live.zig`：它把每次 poll 的 arena 传进来，适配出来的路径只活到
//! 本批 `Index.apply` 返回（`Index` 会把它要长期持有的路径自己复制一份）。

const std = @import("std");
const core = @import("otto_core");
const watch = @import("otto_watch");

/// 把一条监听事件适配成 core 的变更；返回 null = 这条事件没有可应用的路径。
///
/// 分配出来的路径归 `allocator` 所有（`Live.poll` 传的是 per-poll arena）；
/// 不做任何释放，也不读取磁盘——纯字符串适配，可以用合成事件直接测试。
pub fn adapt(
    event: *const watch.Event,
    root: []const u8,
    allocator: std.mem.Allocator,
) error{OutOfMemory}!?core.index.Change {
    switch (event.kind) {
        .created => {
            const path = (try joinRelative(allocator, root, event.path.slice())) orelse return null;
            return .{ .created = path };
        },
        .removed => {
            const path = (try joinRelative(allocator, root, event.path.slice())) orelse return null;
            return .{ .removed = path };
        },
        .modified => {
            const path = (try joinRelative(allocator, root, event.path.slice())) orelse return null;
            // 口岸只知道「变了」，拿不到新的 mtime：交给 Index 保留旧值。
            return .{ .modified = .{ .path = path, .mtime = null } };
        },
        .renamed => {
            const to = (try joinRelative(allocator, root, event.path.slice())) orelse return null;
            if (event.old_path.len == 0) {
                // 只有新名（旧名不可知）：保持 from 为空，让 Index 按 created 收下。
                return .{ .renamed = .{ .from = "", .to = to } };
            }
            errdefer allocator.free(to);
            const from = try std.fs.path.join(allocator, &.{ root, event.old_path.slice() });
            return .{ .renamed = .{ .from = from, .to = to } };
        },
        .overflow => return .{ .overflow = event.lost },
    }
}

/// 把相对路径 join 到 root 上；空相对路径返回 null（没有可定位的样本）。
fn joinRelative(
    allocator: std.mem.Allocator,
    root: []const u8,
    relative: []const u8,
) error{OutOfMemory}!?[]const u8 {
    if (relative.len == 0) return null;
    return try std.fs.path.join(allocator, &.{ root, relative });
}

/// 复制 root 并去掉末尾分隔符：`C:\packs\` 与 `C:\packs` 对 `join` 等价，
/// 但存一份统一的字符串便于比较与打印。盘根（`C:\`）的分隔符要保留，
/// 否则 `C:` 会变成「C 盘当前目录」。
pub fn normalizeRoot(allocator: std.mem.Allocator, root: []const u8) error{ OutOfMemory, InvalidRoot }![]u8 {
    var end = root.len;
    while (end > 1 and std.fs.path.isSep(root[end - 1])) {
        if (end == 3 and root[1] == ':') break;
        end -= 1;
    }
    if (end == 0) return error.InvalidRoot;
    return allocator.dupe(u8, root[0..end]);
}

/// 监听根里有没有本库引用的样本（没有就没什么可监听的，见 `live.Live.init`）。
pub fn rootHasSamples(library: *const core.store.Library, root: []const u8) bool {
    for (library.samples) |sample| {
        if (underRoot(sample.file_path, root)) return true;
    }
    return false;
}

/// `path` 在 `root` 下吗？Windows：大小写不敏感、`/` 与 `\` 等价；纯字符串判断。
fn underRoot(path: []const u8, root: []const u8) bool {
    if (root.len == 0 or path.len <= root.len) return false;
    for (path[0..root.len], root) |a, b| {
        if (isSep(a) and isSep(b)) continue;
        if (std.ascii.toLower(a) != std.ascii.toLower(b)) return false;
    }
    // 盘根（`C:\`）以分隔符结尾：前缀对上就是它的孩子。
    return isSep(root[root.len - 1]) or isSep(path[root.len]);
}

fn isSep(ch: u8) bool {
    return ch == '\\' or ch == '/';
}

// ---------------------------------------------------------------------------
// 测试：合成 Event 直接调适配函数，不依赖真实文件系统
// ---------------------------------------------------------------------------

const testing = std.testing;

fn syntheticEvent(kind: watch.Kind, path: []const u8, old_path: []const u8) watch.Event {
    std.debug.assert(path.len <= watch.max_path_bytes);
    std.debug.assert(old_path.len <= watch.max_path_bytes);
    var event = watch.Event{ .kind = kind };
    @memcpy(event.path.bytes[0..path.len], path);
    event.path.len = @intCast(path.len);
    @memcpy(event.old_path.bytes[0..old_path.len], old_path);
    event.old_path.len = @intCast(old_path.len);
    return event;
}

/// 断言 actual 确实是 `join(root, relative)`：不仅内容对，而且没把相对路径
/// 原样递出去、也没把 root 弄丢。
fn expectJoined(actual: []const u8, root: []const u8, relative: []const u8) !void {
    const expected = try std.fs.path.join(testing.allocator, &.{ root, relative });
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, actual);
    try testing.expect(!std.mem.eql(u8, actual, relative));
    try testing.expect(std.mem.startsWith(u8, actual, root));
    try testing.expect(std.mem.endsWith(u8, actual, relative));
}

test "created / removed / modified：相对路径 join 到 root" {
    const root = "C:\\Library";

    var created = syntheticEvent(.created, "Drums\\Kick 01.wav", "");
    const created_change = try adapt(&created, root, testing.allocator) orelse return error.ExpectedChange;
    switch (created_change) {
        .created => |path| {
            defer testing.allocator.free(path);
            try expectJoined(path, root, "Drums\\Kick 01.wav");
        },
        else => return error.ExpectedCreated,
    }

    var removed = syntheticEvent(.removed, "Drums\\Kick 01.wav", "");
    const removed_change = try adapt(&removed, root, testing.allocator) orelse return error.ExpectedChange;
    switch (removed_change) {
        .removed => |path| {
            defer testing.allocator.free(path);
            try expectJoined(path, root, "Drums\\Kick 01.wav");
        },
        else => return error.ExpectedRemoved,
    }

    var modified = syntheticEvent(.modified, "Pads\\Long.wav", "");
    const modified_change = try adapt(&modified, root, testing.allocator) orelse return error.ExpectedChange;
    switch (modified_change) {
        .modified => |change| {
            defer testing.allocator.free(change.path);
            try expectJoined(change.path, root, "Pads\\Long.wav");
            // 口岸不提供 mtime：不能编一个 0 出来覆盖 Index 里的旧值。
            try testing.expect(change.mtime == null);
        },
        else => return error.ExpectedModified,
    }
}

test "renamed：from 与 to 都 join 到 root" {
    const root = "C:\\Library";
    var event = syntheticEvent(.renamed, "New\\Snare.wav", "Old\\Snare.wav");
    const change = try adapt(&event, root, testing.allocator) orelse return error.ExpectedChange;
    switch (change) {
        .renamed => |rename| {
            defer testing.allocator.free(rename.from);
            defer testing.allocator.free(rename.to);
            try expectJoined(rename.from, root, "Old\\Snare.wav");
            try expectJoined(rename.to, root, "New\\Snare.wav");
        },
        else => return error.ExpectedRenamed,
    }
}

test "renamed 只有新名：from 交给 Index 降级，to 仍然 join" {
    const root = "C:\\Library";
    var event = syntheticEvent(.renamed, "New\\Snare.wav", "");
    const change = try adapt(&event, root, testing.allocator) orelse return error.ExpectedChange;
    switch (change) {
        .renamed => |rename| {
            defer testing.allocator.free(rename.to);
            try testing.expectEqualStrings("", rename.from);
            try expectJoined(rename.to, root, "New\\Snare.wav");
        },
        else => return error.ExpectedRenamed,
    }
}

test "overflow：lost 透传成 Change.overflow" {
    const root = "C:\\Library";
    var event = syntheticEvent(.overflow, "", "");
    event.lost = 7;
    const change = try adapt(&event, root, testing.allocator) orelse return error.ExpectedChange;
    switch (change) {
        .overflow => |lost| try testing.expectEqual(@as(u32, 7), lost),
        else => return error.ExpectedOverflow,
    }
}

test "空路径事件被丢弃" {
    const root = "C:\\Library";

    var empty_created = syntheticEvent(.created, "", "");
    try testing.expect((try adapt(&empty_created, root, testing.allocator)) == null);

    var empty_modified = syntheticEvent(.modified, "", "");
    try testing.expect((try adapt(&empty_modified, root, testing.allocator)) == null);

    // 改名目标为空：Index 也会忽略，这里直接不进批次。
    var empty_target = syntheticEvent(.renamed, "", "Old\\Snare.wav");
    try testing.expect((try adapt(&empty_target, root, testing.allocator)) == null);
}

test "root 末尾分隔符归一化，盘根保留" {
    const sep = std.fs.path.sep;

    const trailing = try std.fmt.allocPrint(testing.allocator, "otto-live{c}lib{c}", .{ sep, sep });
    defer testing.allocator.free(trailing);
    const normalized = try normalizeRoot(testing.allocator, trailing);
    defer testing.allocator.free(normalized);
    const expected = try std.fmt.allocPrint(testing.allocator, "otto-live{c}lib", .{sep});
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, normalized);

    try testing.expectError(error.InvalidRoot, normalizeRoot(testing.allocator, ""));

    if (std.fs.path.sep == '\\') {
        const drive = try normalizeRoot(testing.allocator, "C:\\");
        defer testing.allocator.free(drive);
        try testing.expectEqualStrings("C:\\", drive);
    }
}
