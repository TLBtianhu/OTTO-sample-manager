//! `live.Live` 的"要不要监听"测试（从 `live.zig` 拆出来，守住单文件 ≤600 行）。
//!
//! 监听只在根**确实有本库样本**（或显式 `--watch`）时启动。这条规则同时覆盖：
//!   * 首次启动：库所在目录还不存在 / 空库 → 没有监听根，`poll` 是空账；
//!   * 默认库在 `<dataDir>`：库、cache、settings 都在里面，监听它会把应用自己
//!     创建的缓存文件当成新素材（首次启动的 L3 目录就能凭空多出两行）；
//!   * 库文件与素材放在一起的用法（`otto-testkit` 那种）：照常监听。
//! 真实文件事件的适配测试仍在 `live.zig`。

const std = @import("std");
const core = @import("otto_core");
const live_mod = @import("live.zig");
const Live = live_mod.Live;
const testing = std.testing;

/// 临时目录的真实路径（`buffer` 归调用方，`tmp` 必须活到用完）。
fn tmpRoot(tmp: *std.testing.TmpDir, buffer: []u8) ![]const u8 {
    const len = try tmp.dir.realPath(testing.io, buffer);
    return buffer[0..len];
}

/// 转义 JSON 字符串里的反斜杠（Windows 路径写进 JSON 的唯一要求）。
fn escapeBackslashes(input: []const u8, out: []u8) []const u8 {
    var n: usize = 0;
    for (input) |ch| {
        if (ch == '\\') {
            out[n] = '\\';
            n += 1;
        }
        out[n] = ch;
        n += 1;
    }
    return out[0..n];
}

/// 造一个只含一条样本的库：`file_path` 就是传进来的路径（原样，不改大小写）。
fn libraryWithPath(allocator: std.mem.Allocator, path: []const u8) !core.store.Library {
    var escaped_buffer: [std.Io.Dir.max_path_bytes * 2]u8 = undefined;
    const escaped = escapeBackslashes(path, &escaped_buffer);
    var json_buffer: [std.Io.Dir.max_path_bytes * 2 + 128]u8 = undefined;
    const json = try std.fmt.bufPrint(
        &json_buffer,
        "{{\"samples\":{{\"s\":{{\"id\":\"s\",\"fileName\":\"a\",\"filePath\":\"{s}\"}}}}}}",
        .{escaped},
    );
    return core.store.load(allocator, json);
}

test "Live：库所在目录不存在时不启动监听，poll 是空账" {
    var library = try core.store.empty(testing.allocator);
    defer library.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &path_buffer);
    const missing = try std.fs.path.join(testing.allocator, &.{ root, "no-data" });
    defer testing.allocator.free(missing);

    var live = try Live.init(testing.allocator, testing.io, &library, missing, false);
    defer live.deinit();

    try testing.expect(!live.watching());
    try testing.expectEqual(@as(usize, 0), live.samples().len);
    try testing.expect(!live.dirty());
    const report = try live.poll();
    try testing.expectEqual(@as(usize, 0), report.added);
    // 没有监听根：注入溢出 / 主动重扫都不能真的去扫不存在的目录。
    try live.injectOverflow(3);
    live.requestRescan();
    try testing.expect(!live.rescanActive());
    try testing.expect(!live.dirty());
}

test "Live：根里没有本库样本（默认 dataDir）不启动监听——缓存文件不会被当成素材" {
    var library = try core.store.empty(testing.allocator);
    defer library.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &path_buffer);

    var live = try Live.init(testing.allocator, testing.io, &library, root, false);
    defer live.deinit();
    try testing.expect(!live.watching());

    // 目录里随后出现的文件（`<dataDir>\cache\thumbs` 这种）不该进视图：
    // 没有 watcher，`poll` 读不到任何事件。
    try tmp.dir.createDirPath(testing.io, "cache\\thumbs");
    try testing.expectEqual(@as(usize, 0), (try live.poll()).added);
    try testing.expectEqual(@as(usize, 0), live.samples().len);
}

test "Live：库有样本落在根下时照常挂上监听" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &path_buffer);
    const sample_path = try std.fs.path.join(testing.allocator, &.{ root, "a.wav" });
    defer testing.allocator.free(sample_path);

    var library = try libraryWithPath(testing.allocator, sample_path);
    defer library.deinit();

    var live = try Live.init(testing.allocator, testing.io, &library, root, false);
    defer live.deinit();

    try testing.expect(live.watching());
    try testing.expectEqual(@as(usize, 1), live.samples().len);
    _ = try live.poll();
}

test "Live：显式 --watch 时列表还空着也监听（等新文件掉进来）" {
    var library = try core.store.empty(testing.allocator);
    defer library.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &path_buffer);

    var live = try Live.init(testing.allocator, testing.io, &library, root, true);
    defer live.deinit();
    try testing.expect(live.watching());
    try testing.expect(live.watchForced());
}

test "rootHasSamples：Windows 大小写 / 分隔符等价，不能把相邻目录算进来" {
    var library = try libraryWithPath(testing.allocator, "C:\\Packs\\a.wav");
    defer library.deinit();

    try testing.expect(live_mod.rootHasSamples(&library, "c:\\packs"));
    try testing.expect(live_mod.rootHasSamples(&library, "C:/Packs"));
    try testing.expect(!live_mod.rootHasSamples(&library, "C:\\Pack"));
    try testing.expect(!live_mod.rootHasSamples(&library, "C:\\Other"));
    try testing.expect(live_mod.rootHasSamples(&library, "C:\\"));
}
