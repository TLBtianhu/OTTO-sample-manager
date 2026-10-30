//! `--demo <dir>`：不开窗的监听链路自检（与缩略图、选择、拖拽无关，行为保持原样）。
//!
//! 步骤：在目录里建 3 个空 wav → 起监听 → 200ms 后建第 4 个 → 400ms 后 poll →
//! 断言 `before=3 after=4 report.added=1`。任何一条不成立就退出 1。
//!
//! 空文件必须"创建后立刻关闭"：Windows 会把"创建 + 立刻写"合并成一条 MODIFIED
//! （见 `zig/ports/src/watch_test.zig` 的说明），要拿到稳定的 ADDED 就只能纯创建。

const std = @import("std");
const core = @import("otto_core");
const live_mod = @import("live.zig");

pub fn run(init: std.process.Init, allocator: std.mem.Allocator, dir_path: []const u8) !void {
    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, dir_path);
    // 绝对根：ports 给的是相对路径，join 之后要和下面的 filePath 逐字节一致。
    const root = try cwd.realPathFileAlloc(io, dir_path, allocator);
    var dir = try cwd.openDir(io, dir_path, .{});
    defer dir.close(io);

    // 重跑同一个目录时先清场：four.wav 已存在的话，再写一次只会是 modified。
    const names = [_][]const u8{ "one.wav", "two.wav", "three.wav", "four.wav" };
    for (names) |name| dir.deleteFile(io, name) catch {};

    var paths: [3][]const u8 = undefined;
    for (names[0..3], 0..) |name, i| {
        try createEmptyFile(io, dir, name);
        paths[i] = try std.fs.path.join(allocator, &.{ root, name });
    }

    const json_text = try demoLibraryJson(allocator, &paths);
    const library = try core.store.load(allocator, json_text);

    var live = try live_mod.Live.init(init.gpa, init.io, &library, root);
    defer live.deinit();

    const before = live.samples().len;
    std.debug.print("demo: root={s}\n", .{root});

    // 200ms：磁盘上多出第 4 个文件。
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(200), .awake);
    try createEmptyFile(io, dir, "four.wav");

    // 600ms：排空事件，打印账。
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(400), .awake);
    const report = try live.poll();
    const after = live.samples().len;
    std.debug.print(
        "before={d} after={d} report=added={d} removed={d} renamed={d} modified={d} overflowed={} lost={d}\n",
        .{
            before,
            after,
            report.added,
            report.removed,
            report.renamed,
            report.modified,
            report.overflowed,
            report.overflow_lost,
        },
    );

    // 900ms：稳定的退出时间线。
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(300), .awake);

    if (after != 4 or report.added != 1) {
        std.debug.print("demo: FAIL（期望 before=3 after=4 report.added=1）\n", .{});
        std.process.exit(1);
    }
    std.debug.print("demo: OK\n", .{});
}

/// 建一个空文件：创建后立刻关闭，不写内容。
fn createEmptyFile(io: std.Io, dir: std.Io.Dir, name: []const u8) !void {
    var file = try dir.createFile(io, name, .{});
    file.close(io);
}

/// 在内存里拼一个最小 electron-store 快照：3 条样本，路径指向刚建的文件。
fn demoLibraryJson(allocator: std.mem.Allocator, paths: []const []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;

    try writer.writeAll("{\"samples\":{");
    for (paths, 0..) |path, i| {
        if (i != 0) try writer.writeByte(',');
        try writer.print("\"demo-{d}\":{{\"filePath\":", .{i + 1});
        try std.json.Stringify.encodeJsonString(path, .{}, writer);
        try writer.writeByte('}');
    }
    try writer.writeAll("}}");
    return out.toOwnedSlice();
}
