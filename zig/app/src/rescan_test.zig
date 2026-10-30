//! `Live` 溢出重扫的应用层测试：真临时目录、真 watcher、真后台扫描线程。
//!
//! 验收三件事：
//!   1. 删除 / 新增 / 改内容各一条，重扫账必须是 `added=1 removed=1 modified=1`；
//!   2. 删除只动视图，按身份保存的注释表一条都不能少；
//!   3. 再来一次没有变化的主动重扫，账必须是 `0 / 0 / 0`。
//!
//! 不依赖真实的内核缓冲区溢出：用 `Live.injectOverflow` 走同一条标脏 + 排队路径。

const std = @import("std");
const core = @import("otto_core");
const live_mod = @import("live.zig");
const scan_mod = @import("otto_scan");
const testing = std.testing;

fn containsPath(samples: []const core.model.Sample, path: []const u8) bool {
    for (samples) |sample| {
        if (std.mem.eql(u8, sample.file_path, path)) return true;
    }
    return false;
}

fn buildSamples(
    allocator: std.mem.Allocator,
    facts: []const scan_mod.FileFact,
) ![]core.model.Sample {
    const samples = try allocator.alloc(core.model.Sample, facts.len);
    errdefer allocator.free(samples);
    var ids: [64][32]u8 = undefined;
    for (facts, 0..) |fact, index| {
        const id = try std.fmt.bufPrint(&ids[index], "base-{d}", .{index});
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
    return samples;
}

/// 等到下一次重扫完成（`rescanSerial` 变化）。超时返回错误，测试进程不会挂死。
fn waitForRescan(live: *live_mod.Live) !u64 {
    const serial = live.rescanSerial();
    const now = std.Io.Timestamp.now(testing.io, .awake);
    const deadline = now.addDuration(.{ .nanoseconds = 8 * std.time.ns_per_s });
    while (live.rescanSerial() == serial) {
        _ = try live.poll();
        const current = std.Io.Timestamp.now(testing.io, .awake);
        if (current.nanoseconds >= deadline.nanoseconds) return error.TestTimeout;
        try std.Io.sleep(testing.io, std.Io.Duration.fromMilliseconds(5), .awake);
    }
    return live.rescanSerial();
}

test "溢出重扫：删 1 / 加 1 / 改 1，注释按身份保留；无变化再扫为 0" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "one.wav", .data = "one" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "two.wav", .data = "two-two" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "three.wav", .data = "three" });

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(testing.io, &root_buffer);
    const root = root_buffer[0..root_len];

    var scan = try scan_mod.run(testing.allocator, testing.io, root, .{}, null);
    defer scan.deinit();
    try testing.expectEqual(@as(usize, 3), scan.files.len);

    var library = try core.store.empty(testing.allocator);
    defer library.deinit();
    const samples = try buildSamples(testing.allocator, scan.files);
    defer testing.allocator.free(samples);
    _ = try library.appendSamples(samples);

    var live = try live_mod.Live.init(testing.allocator, testing.io, &library, root);
    defer live.deinit();

    // 建 Live 之前就存在的文件不会产生事件；这里只是把可能迟到的队列排空。
    try std.Io.sleep(testing.io, std.Io.Duration.fromMilliseconds(100), .awake);
    _ = try live.poll();
    try testing.expectEqual(@as(usize, 3), live.samples().len);

    // 每条样本按身份写一条注释。删除文件之后，被删身份的注释必须还在。
    var table = core.annotations.AnnotationTable.init(testing.allocator);
    defer table.deinit();
    for (live.samples()) |sample| {
        try table.put(sample.stableKey(), .{ .tags = &.{"keep"}, .rating = 5 });
    }
    try testing.expectEqual(@as(usize, 3), table.count());

    var deleted_key: core.model.StableKey = undefined;
    var deleted_path: []const u8 = undefined;
    for (live.samples()) |sample| {
        if (std.mem.endsWith(u8, sample.file_path, "one.wav")) {
            deleted_key = sample.stableKey();
            deleted_path = sample.file_path;
            break;
        }
    } else return error.TestUnexpectedResult;

    // 删 1、改 1（size 变了）、加 1；然后注入一次溢出，不等真实缓冲区溢出。
    try tmp.dir.deleteFile(testing.io, "one.wav");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "two.wav", .data = "two-two-two-two" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "four.wav", .data = "four" });
    try live.injectOverflow(1);

    _ = try waitForRescan(&live);
    const report = live.lastRescan();
    try testing.expect(report.ok);
    try testing.expectEqual(@as(usize, 1), report.added);
    try testing.expectEqual(@as(usize, 1), report.removed);
    try testing.expectEqual(@as(usize, 1), report.modified);
    try testing.expectEqual(@as(usize, 0), report.moved);
    try testing.expectEqual(@as(usize, 1), report.unchanged);
    try testing.expect(!live.dirty());

    try testing.expectEqual(@as(usize, 3), live.samples().len);
    try testing.expect(!containsPath(live.samples(), deleted_path));
    const four = try std.fs.path.join(testing.allocator, &.{ root, "four.wav" });
    defer testing.allocator.free(four);
    try testing.expect(containsPath(live.samples(), four));

    // 注释表不归 Live/Rescan 管：删文件只删视图行，不删用户标签。
    try testing.expectEqual(@as(usize, 3), table.count());
    const kept = table.get(deleted_key) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("keep", kept.tags[0]);
    try testing.expectEqual(@as(u8, 5), kept.rating);

    // 把可能在扫描开始之后才到的事件排空，列表仍然只有 3 行（replay 幂等）。
    try std.Io.sleep(testing.io, std.Io.Duration.fromMilliseconds(100), .awake);
    _ = try live.poll();
    try testing.expectEqual(@as(usize, 3), live.samples().len);

    // 第二次：磁盘没有任何变化，主动重扫必须是 0 / 0 / 0。
    live.requestRescan();
    _ = try waitForRescan(&live);
    const again = live.lastRescan();
    try testing.expect(again.ok);
    try testing.expectEqual(@as(usize, 0), again.added);
    try testing.expectEqual(@as(usize, 0), again.removed);
    try testing.expectEqual(@as(usize, 0), again.modified);
    try testing.expectEqual(@as(usize, 0), again.moved);
    try testing.expectEqual(@as(usize, 3), again.unchanged);
    try testing.expectEqual(@as(usize, 3), table.count());
}
