//! browse_poll 的生产路径实测：真实 RDCW 的四类事件按操作顺序合入，
//! 以及注入现有 watcher 队列的 overflow 触发同一 Session.poll 重扫。
//! 不建窗口、不写库或设置；唯一磁盘写入都在测试自己的临时目录。

const std = @import("std");
const browse = @import("browse.zig");
const types = @import("browse_types.zig");
const testing = std.testing;

const Tally = struct {
    added: usize = 0,
    removed: usize = 0,
    renamed: usize = 0,
    modified: usize = 0,
    rescans: usize = 0,

    fn note(self: *Tally, report: types.Report) void {
        self.added += report.added;
        self.removed += report.removed;
        self.renamed += report.renamed;
        self.modified += report.modified;
        if (report.rescanned) self.rescans += 1;
    }
};

const Target = union(enum) {
    rows: usize,
    present: []const u8,
    size: struct { name: []const u8, bytes: u64 },
    renamed: struct { old_name: []const u8, new_name: []const u8 },
};

fn sleepMs(ms: u64) void {
    std.Io.sleep(testing.io, std.Io.Duration.fromMilliseconds(@intCast(ms)), .awake) catch {};
}

fn ready(session: *const browse.Session, target: Target) bool {
    return switch (target) {
        .rows => |count| session.samples().len == count,
        .present => |name| session.indexOfName(name) != null,
        .size => |wanted| if (session.indexOfName(wanted.name)) |index|
            session.samples()[index].file_size == wanted.bytes
        else
            false,
        .renamed => |names| session.indexOfName(names.old_name) == null and
            session.indexOfName(names.new_name) != null,
    };
}

/// 每一站都等上一操作真正经过生产 poll，再发出下一项磁盘变更。
fn waitTarget(session: *browse.Session, target: Target, tally: *Tally) !void {
    for (0..5000) |_| {
        const report = try session.poll(null);
        tally.note(report);
        if (ready(session, target)) return;
        sleepMs(1);
    }
    std.debug.print("browse-poll-test: timeout rows={d} info={any}\n", .{ session.samples().len, session.info() });
    return error.TestUnexpectedResult;
}

fn waitIdle(session: *browse.Session, tally: *Tally) !void {
    for (0..5000) |_| {
        const report = try session.poll(null);
        tally.note(report);
        if (!session.info().enumerating) return;
        sleepMs(1);
    }
    return error.TestUnexpectedResult;
}

test "poll 顺序：created、modified、renamed、removed，overflow 后重扫" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "a" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b.txt", .data = "b" });

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(testing.io, &path_buffer);
    const session = try browse.Session.init(testing.allocator, testing.io, path_buffer[0..root_len], .{});
    defer session.deinit();
    if (!session.hasWatcher()) return error.SkipZigTest;

    var tally = Tally{};
    try waitIdle(session, &tally);
    try testing.expectEqual(@as(usize, 2), session.samples().len);
    tally = .{};

    // created：只建空文件，避免 Windows 把创建+写内容合并成 modified。
    var created = try tmp.dir.createFile(testing.io, "c.txt", .{});
    created.close(testing.io);
    try waitTarget(session, .{ .present = "c.txt" }, &tally);
    try testing.expect(tally.added >= 1);

    // modified：改变大小，refreshStat 必须发布实际的新大小。
    const modified_data = "modified-content";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = modified_data });
    try waitTarget(session, .{ .size = .{ .name = "a.txt", .bytes = modified_data.len } }, &tally);
    try testing.expect(tally.modified >= 1);

    // renamed：旧名消失、新名出现，且仍只有三行（不是 remove+create 两行）。
    try tmp.dir.rename("a.txt", tmp.dir, "z.txt", testing.io);
    try waitTarget(session, .{ .renamed = .{ .old_name = "a.txt", .new_name = "z.txt" } }, &tally);
    try testing.expect(tally.renamed >= 1);
    try testing.expectEqual(@as(usize, 3), session.samples().len);

    try tmp.dir.deleteFile(testing.io, "b.txt");
    try waitTarget(session, .{ .rows = 2 }, &tally);
    try testing.expect(tally.removed >= 1);
    try testing.expect(session.indexOfName("c.txt") != null);
    try testing.expect(session.indexOfName("z.txt") != null);

    // 只注入现有口岸队列；后续仍完全走生产的 seq/overflow/rescan/replay 状态机。
    const watcher = session.changes.watcher orelse return error.SkipZigTest;
    watcher.queue.recordOverflow(0);
    const rescans_before = session.info().rescans;
    var overflow_accepted = false;
    for (0..5000) |_| {
        const report = try session.poll(null);
        tally.note(report);
        if (report.rescanned) {
            overflow_accepted = true;
            break;
        }
        sleepMs(1);
    }
    try testing.expect(overflow_accepted);
    try waitIdle(session, &tally);
    for (0..8) |_| {
        const report = try session.poll(null);
        tally.note(report);
        sleepMs(1);
    }
    try testing.expect(session.info().rescans > rescans_before);
    try testing.expect(session.info().reconciles >= 1);
    try testing.expectEqual(@as(usize, 2), session.samples().len);
    try testing.expect(session.indexOfName("c.txt") != null);
    try testing.expect(session.indexOfName("z.txt") != null);
}
