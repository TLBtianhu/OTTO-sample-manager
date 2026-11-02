//! `--demo-rescan <dir>`：不开窗的溢出重扫自检。
//!
//! 步骤（与任务验收一一对应）：
//!   1. 在 `dir` 里建 3 个文件，扫描出 L0 事实并建成库；
//!   2. 启动 `Live` + watcher，排空初始事件；
//!   3. 删 1 个、改 1 个（size 变）、加 1 个；
//!   4. `Live.injectOverflow` 强制注入溢出（不依赖真实内核缓冲区溢出）；
//!   5. 驱动 `poll` 等重扫完成，断言 `before=3 after=3 added=1 removed=1 modified=1`；
//!   6. 不注入、主动再扫一次，断言 `added=0 removed=0 modified=0`；
//!   7. 全过退出 0，否则 1。
//!
//! 和 UI 走同一个 `Live.poll` → `rescan_ui.Rescan` 链路，只是没有窗口：本文件
//! 不 import nanoui，也不碰缩略图 / 预览 / 剪贴板。

const std = @import("std");
const core = @import("otto_core");
const live_mod = @import("live.zig");
const scan_mod = @import("otto_scan");

/// 等待一次重扫完成（`rescanSerial` 变化）；超时返回错误。
fn waitRescan(live: *live_mod.Live, serial: u64) !void {
    const now = std.Io.Timestamp.now(live.io, .awake);
    const deadline = now.addDuration(.{ .nanoseconds = 8 * std.time.ns_per_s });
    while (live.rescanSerial() == serial) {
        _ = try live.poll();
        const current = std.Io.Timestamp.now(live.io, .awake);
        if (current.nanoseconds >= deadline.nanoseconds) return error.RescanTimeout;
        try std.Io.sleep(live.io, std.Io.Duration.fromMilliseconds(10), .awake);
    }
}

fn buildLibrary(
    allocator: std.mem.Allocator,
    scan: *const scan_mod.Scan,
) !core.store.Library {
    var library = try core.store.empty(allocator);
    errdefer library.deinit();

    const samples = try allocator.alloc(core.model.Sample, scan.files.len);
    defer allocator.free(samples);
    var ids: [64][32]u8 = undefined;
    for (scan.files, 0..) |fact, index| {
        const id = try std.fmt.bufPrint(&ids[index], "demo-rescan-{d}", .{index});
        samples[index] = .{
            .id = id,
            .file_name = core.model.fileNameFromPath(fact.path),
            .file_ext = core.model.fileExtFromPath(fact.path),
            .file_path = fact.path,
            .file_size = fact.size,
            .mtime = fact.mtime,
            .identity = if (fact.identity) |identity| core.model.FileIdentity{
                .volume_serial = identity.volume_serial,
                .file_index = identity.file_index,
            } else null,
        };
    }
    _ = try library.appendSamples(samples);
    return library;
}

pub fn run(init: std.process.Init, dir_path: []const u8) !u8 {
    const allocator = init.gpa;
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    try cwd.createDirPath(io, dir_path);
    var dir = try cwd.openDir(io, dir_path, .{});
    defer dir.close(io);
    const root = try cwd.realPathFileAlloc(io, dir_path, allocator);
    defer allocator.free(root);

    // 清场：重跑同一个目录时不能把上一次的 four.wav 当成新文件。
    const names = [_][]const u8{ "one.wav", "two.wav", "three.wav", "four.wav" };
    for (names) |name| dir.deleteFile(io, name) catch {};

    try dir.writeFile(io, .{ .sub_path = "one.wav", .data = "one" });
    try dir.writeFile(io, .{ .sub_path = "two.wav", .data = "two-two" });
    try dir.writeFile(io, .{ .sub_path = "three.wav", .data = "three" });

    var scan = try scan_mod.run(allocator, io, root, .{}, null);
    defer scan.deinit();
    var library = try buildLibrary(allocator, &scan);
    defer library.deinit();

    var live = try live_mod.Live.init(allocator, io, &library, root, true);
    defer live.deinit();

    // 建 Live 之前的文件不该产生事件；这 100ms 只是把可能迟到的队列排空。
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(100), .awake);
    _ = try live.poll();
    const before = live.samples().len;
    std.debug.print("demo-rescan: root={s} before={d}\n", .{ root, before });

    // 删 1、改 1（size 变）、加 1。
    try dir.deleteFile(io, "one.wav");
    try dir.writeFile(io, .{ .sub_path = "two.wav", .data = "two-two-two-two" });
    try dir.writeFile(io, .{ .sub_path = "four.wav", .data = "four" });

    // 强制注入溢出：和 watcher 报 overflow 走同一条标脏 + 排重扫路径。
    try live.injectOverflow(1);

    const first_serial = live.rescanSerial();
    try waitRescan(&live, first_serial);
    const report = live.lastRescan();
    const after = live.samples().len;

    std.debug.print(
        "demo-rescan: before={d} after={d} added={d} removed={d} modified={d}\n",
        .{ before, after, report.added, report.removed, report.modified },
    );
    std.debug.print(
        "demo-rescan: detail ok={} moved={d} unchanged={d} dirtied={d} replayed={d} scanned={d} ms={d:.2}\n",
        .{
            report.ok,
            report.moved,
            report.unchanged,
            report.dirtied,
            report.replayed,
            report.scanned,
            report.elapsed_ms,
        },
    );

    const first_ok = report.ok and before == 3 and after == 3 and
        report.added == 1 and report.removed == 1 and report.modified == 1;
    if (!first_ok) {
        std.debug.print("demo-rescan: FAIL（期望 before=3 after=3 added=1 removed=1 modified=1）\n", .{});
        return 1;
    }

    // 让扫描开始之后才到的事件 replay 完，再验证「没有变化时重扫为 0」。
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(100), .awake);
    _ = try live.poll();

    live.requestRescan();
    const second_serial = live.rescanSerial();
    try waitRescan(&live, second_serial);
    const second = live.lastRescan();
    const second_after = live.samples().len;
    std.debug.print(
        "demo-rescan: second before={d} after={d} added={d} removed={d} modified={d}\n",
        .{ after, second_after, second.added, second.removed, second.modified },
    );

    const second_ok = second.ok and second_after == 3 and
        second.added == 0 and second.removed == 0 and second.modified == 0;
    if (!second_ok) {
        std.debug.print("demo-rescan: FAIL（期望第二次 added=0 removed=0 modified=0）\n", .{});
        return 1;
    }

    std.debug.print("demo-rescan: OK\n", .{});
    return 0;
}
