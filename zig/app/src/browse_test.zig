//! 浏览模式的测试：入口解析（库 vs 目录）、真临时目录上的懒枚举，以及
//! "外部删文件 → 墓碑 + 选中按身份移到相邻行"这一条真实链路（真 RDCW）。
//!
//! 不 import nanoui：测试进程不建窗口。界面那一半由 `--nanoui-snapshot` 的无头
//! 快照与 `--browse-probe` / `--browse-watch-probe` 覆盖（见 `zig/browse.ps1`）。

const std = @import("std");
const core = @import("otto_core");
const browse = @import("browse.zig");
const options_mod = @import("options.zig");
const selection_mod = @import("selection.zig");
const testing = std.testing;

fn realPath(tmp: *std.testing.TmpDir, buffer: []u8) ![]const u8 {
    const len = try tmp.dir.realPath(testing.io, buffer);
    return buffer[0..len];
}

fn sleepMs(ms: u64) void {
    std.Io.sleep(testing.io, std.Io.Duration.fromMilliseconds(@intCast(ms)), .awake) catch {};
}

/// 等这一轮枚举结束（最多 5 秒）。
fn waitEnumeration(session: *browse.Session, selection: *selection_mod.Selection) !void {
    var waited: usize = 0;
    while (session.info().enumerating and waited < 500) : (waited += 1) {
        _ = try session.poll(selection);
        sleepMs(10);
    }
    try testing.expect(!session.info().enumerating);
}

test "入口解析：位置参数是目录就浏览、是文件就是库；--browse 只接受目录" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.otto", .data = "x" });

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try realPath(&tmp, &buffer);
    const file_path = try std.fs.path.join(testing.allocator, &.{ root, "a.otto" });
    defer testing.allocator.free(file_path);

    // 位置参数给目录 → 浏览。
    var positional = options_mod.Options{};
    positional.library_path = root;
    const target = try browse.resolveTarget(testing.io, testing.allocator, positional);
    defer testing.allocator.free(target.browse);
    try testing.expectEqualStrings(root, target.browse);

    // 位置参数给文件 → 库（0.34.0 的行为不变）。
    var as_library = options_mod.Options{};
    as_library.library_path = file_path;
    const library_target = try browse.resolveTarget(testing.io, testing.allocator, as_library);
    defer testing.allocator.free(library_target.library);
    try testing.expectEqualStrings(file_path, library_target.library);

    // `--browse` 给文件 → 具名错误（调用方 exit 2）。
    var explicit = options_mod.Options{};
    explicit.browse_dir = file_path;
    try testing.expectError(
        error.BrowseNotADirectory,
        browse.resolveTarget(testing.io, testing.allocator, explicit),
    );

    // `--browse` 给不存在的路径 → 同样是"不是目录"。
    var missing = options_mod.Options{};
    const missing_path = try std.fs.path.join(testing.allocator, &.{ root, "no-such-dir" });
    defer testing.allocator.free(missing_path);
    missing.browse_dir = missing_path;
    try testing.expectError(
        error.BrowseNotADirectory,
        browse.resolveTarget(testing.io, testing.allocator, missing),
    );
}

test "懒枚举：不列子目录、不排序、行来自目录；没有监听也能用" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "kick.wav", .data = "1234" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "snare.mp3", .data = "12" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "cover.png", .data = "x" });
    try tmp.dir.createDirPath(testing.io, "sub");

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try realPath(&tmp, &buffer);

    const session = try browse.Session.init(testing.allocator, testing.io, root, .{ .watch = false });
    defer session.deinit();
    var selection = selection_mod.Selection{};
    defer selection.deinit(testing.allocator);

    try waitEnumeration(session, &selection);
    const samples = session.samples();
    try testing.expectEqual(@as(usize, 3), samples.len);
    for (samples) |sample| {
        try testing.expect(sample.file_size > 0);
        try testing.expect(sample.mtime > 0);
        try testing.expect(!std.mem.eql(u8, sample.file_name, "sub"));
    }
    // 首批行与整轮枚举的耗时都记下来了（`--browse-probe` 打的就是这两个数）。
    const info = session.info();
    try testing.expect(info.first_page_ms >= 0);
    try testing.expect(info.enum_ms >= info.first_page_ms);
    try testing.expect(!info.truncated);
    try testing.expectEqual(@as(usize, 0), info.tombstones);
}

test "删除选中的文件：那一行留成墓碑，选中项按身份移到相邻行" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.wav", .data = "aaaa" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b.wav", .data = "bbbb" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "c.wav", .data = "cccc" });

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try realPath(&tmp, &buffer);

    const session = try browse.Session.init(testing.allocator, testing.io, root, .{});
    defer session.deinit();
    if (session.watcher == null) return error.SkipZigTest;

    var selection = selection_mod.Selection{};
    defer selection.deinit(testing.allocator);

    try waitEnumeration(session, &selection);
    try selection.resize(testing.allocator, session.samples().len);

    const index_b = session.indexOfName("b.wav") orelse return error.TestUnexpectedResult;
    selection.selectOnly(index_b);
    _ = try session.poll(&selection);
    // 选中的那一行取到了身份（卷序列号 + 文件索引）：后面的找回靠它，不靠行号。
    try testing.expect(session.identityOfIndex(index_b) != null);

    // 删掉"前一行"：行号整体前移，选中项必须还是 b.wav（按路径/身份找回）。
    try tmp.dir.deleteFile(testing.io, "a.wav");
    var waited: usize = 0;
    while (session.samples().len != 2 and waited < 300) : (waited += 1) {
        _ = try session.poll(&selection);
        sleepMs(10);
    }
    try testing.expectEqual(@as(usize, 2), session.samples().len);
    try selection.resize(testing.allocator, session.samples().len);
    const cursor_after_shift = selection.cursor orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("b.wav", core.model.baseName(session.samples()[cursor_after_shift].file_path));

    // 删掉选中的这一行：墓碑留在原位，选中项落到相邻的存活行。
    const tomb = cursor_after_shift;
    try tmp.dir.deleteFile(testing.io, "b.wav");
    waited = 0;
    while (!session.isDeleted(tomb) and waited < 300) : (waited += 1) {
        _ = try session.poll(&selection);
        sleepMs(10);
    }
    try testing.expect(session.isDeleted(tomb));
    try selection.resize(testing.allocator, session.samples().len);
    const cursor = selection.cursor orelse return error.TestUnexpectedResult;
    try testing.expect(cursor != tomb);
    try testing.expectEqualStrings("c.wav", core.model.baseName(session.samples()[cursor].file_path));
    try testing.expectEqual(@as(usize, 1), session.info().tombstones);
}
