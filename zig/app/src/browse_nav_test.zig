//! Stage 1 的真实目录导航测试：唯一历史、选中身份恢复、排序不改变选中。
const std = @import("std");
const browse = @import("browse.zig");
const selection_mod = @import("selection.zig");
const testing = std.testing;

fn waitIdle(session: *browse.Session, selected: *selection_mod.Selection) !void {
    var waited: usize = 0;
    while (session.info().enumerating and waited < 5000) : (waited += 1) {
        _ = try session.poll(selected);
        std.Io.sleep(testing.io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }
    for (0..4) |_| _ = try session.poll(selected);
    try testing.expect(!session.info().enumerating);
    try selected.resize(testing.allocator, session.samples().len);
}

fn expectPath(session: *browse.Session, suffix: []const u8) !void {
    try testing.expect(std.ascii.endsWithIgnoreCase(session.rootPath(), suffix));
}

test "进入/返回/前进/上一级：目录历史唯一，返回按身份恢复目录选中" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "root/sub1");
    try tmp.dir.createDirPath(testing.io, "root/sub2");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "root/a.wav", .data = "a" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "root/b.mp3", .data = "bbbb" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "root/sub1/child.txt", .data = "child" });
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPathFile(testing.io, "root", &buffer);
    const root = buffer[0..root_len];

    const session = try browse.Session.init(testing.allocator, testing.io, root, .{ .watch = false });
    defer session.deinit();
    var selected = selection_mod.Selection{};
    defer selected.deinit(testing.allocator);
    try waitIdle(session, &selected);
    try testing.expectEqual(@as(usize, 4), session.samples().len);
    try testing.expect(session.isDirectory(0) and session.isDirectory(1));

    // 排序移动行号，选中仍按身份指向同一文件。
    const file_index = session.indexOfName("b.mp3") orelse return error.TestUnexpectedResult;
    selected.selectOnly(file_index);
    _ = try session.poll(&selected);
    try session.setSort(.size, &selected);
    const after_sort = selected.cursor orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("b.mp3", std.fs.path.basename(session.samples()[after_sort].file_path));
    try session.setSort(.name, &selected);

    const sub_index = session.indexOfName("sub1") orelse return error.TestUnexpectedResult;
    selected.selectOnly(sub_index);
    try session.enterDirectory(sub_index, &selected);
    try waitIdle(session, &selected);
    try expectPath(session, "sub1");
    try testing.expectEqual(@as(usize, 1), session.samples().len);
    const entered_epoch = session.info().epoch;

    try session.goBack(&selected);
    try waitIdle(session, &selected);
    try expectPath(session, "root");
    const restored = selected.cursor orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("sub1", session.samples()[restored].file_name);
    try testing.expectEqual(@as(usize, 2), session.historyLength());

    try session.goForward(&selected);
    try waitIdle(session, &selected);
    try expectPath(session, "sub1");
    try testing.expect(session.info().epoch > entered_epoch);
    try testing.expectEqual(@as(usize, 2), session.historyLength());

    // Up 回到已有 root：节点移到栈顶而非重复追加；Back 再回 sub1。
    try session.goUp(&selected);
    try waitIdle(session, &selected);
    try expectPath(session, "root");
    try testing.expectEqual(@as(usize, 2), session.historyLength());
    try session.goBack(&selected);
    try waitIdle(session, &selected);
    try expectPath(session, "sub1");
    try session.goForward(&selected);
    try waitIdle(session, &selected);
    try expectPath(session, "root");
    try testing.expectEqual(@as(usize, 2), session.historyLength());
}
