//! Stage 2 的多选真实链路：Ctrl/Shift → 重扫/分页/排序 → 预览与拖出。
//! 反向证明共用同一份真实重扫场景，只切换 Tracker 的恢复算法。

const std = @import("std");
const core = @import("otto_core");
const browse = @import("browse.zig");
const select_mod = @import("browse_select.zig");
const selection_mod = @import("selection.zig");
const types = @import("browse_types.zig");
const testing = std.testing;

fn sleepMs(ms: u64) void {
    std.Io.sleep(testing.io, std.Io.Duration.fromMilliseconds(@intCast(ms)), .awake) catch {};
}

fn waitIdle(session: *browse.Session, selected: *selection_mod.Selection) !void {
    var spins: usize = 0;
    while (session.info().enumerating and spins < 5000) : (spins += 1) {
        _ = try session.poll(selected);
        sleepMs(1);
    }
    for (0..4) |_| _ = try session.poll(selected);
    try testing.expect(!session.info().enumerating);
    try selected.resize(testing.allocator, session.samples().len);
}

fn makeFiles(tmp: *std.testing.TmpDir) !void {
    const names = [_][]const u8{ "a.wav", "b.wav", "c.wav", "d.wav", "e.wav" };
    for (names, 0..) |name, index| {
        var data: [8]u8 = undefined;
        const content = try std.fmt.bufPrint(&data, "{d}", .{index + 1});
        try tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = content });
    }
}

fn rootOf(tmp: *std.testing.TmpDir, buffer: []u8) ![]const u8 {
    const len = try tmp.dir.realPath(testing.io, buffer);
    return buffer[0..len];
}

fn expectSelectedNames(session: *browse.Session, selected: *selection_mod.Selection, expected: []const []const u8) !void {
    const indices = try selected.selectedIndices(testing.allocator);
    defer testing.allocator.free(indices);
    try testing.expectEqual(expected.len, indices.len);
    for (indices, expected) |index, name| {
        try testing.expectEqualStrings(name, core.model.baseName(session.samples()[index].file_path));
    }
}

fn checkRescan(mode: ?select_mod.Mode, expected: []const []const u8) !void {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeFiles(&tmp);
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const session = try browse.Session.init(testing.allocator, testing.io, try rootOf(&tmp, &buffer), .{ .watch = false });
    defer session.deinit();
    var selected = selection_mod.Selection{};
    defer selected.deinit(testing.allocator);
    try waitIdle(session, &selected);

    const b = session.indexOfName("b.wav").?;
    const d = session.indexOfName("d.wav").?;
    selected.click(b, .{});
    selected.click(d, .{ .ctrl = true });
    _ = try session.poll(&selected); // 先缓存两个真实 File ID。
    try testing.expect(session.identityOfIndex(b) != null);
    try testing.expect(session.identityOfIndex(d) != null);
    if (mode) |value| session.tracker.mode = value;

    // a 消失后 b/c/d 全部换行；按旧行号会把 b 错成 c。
    try tmp.dir.deleteFile(testing.io, "a.wav");
    session.forceRescan(0, 0);
    try waitIdle(session, &selected);
    try expectSelectedNames(session, &selected, expected);
}

test "多选按文件身份跟踪：重扫删掉前一行后仍选中 b+d，选中计数正确" {
    try checkRescan(null, &.{ "b.wav", "d.wav" });
}

test "反向证明：同一重扫若改成按行号恢复，b+d 会错成 c+e" {
    // 生产测试上一行使用默认身份算法；把默认算法换成行号就会立刻变红。
    try checkRescan(.row_for_reverse_proof, &.{ "c.wav", "e.wav" });
}

test "多选在换页与排序后保持；预览跟随当前行，拖出包含全部选中项" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeFiles(&tmp);
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const session = try browse.Session.init(testing.allocator, testing.io, try rootOf(&tmp, &buffer), .{ .watch = false, .limit = 2 });
    defer session.deinit();
    var selected = selection_mod.Selection{};
    defer selected.deinit(testing.allocator);
    try waitIdle(session, &selected);
    try testing.expectEqual(@as(usize, 2), session.samples().len);

    selected.click(session.indexOfName("a.wav").?, .{});
    _ = try session.poll(&selected);
    try testing.expect(try session.loadMore());
    try waitIdle(session, &selected);
    const d = session.indexOfName("d.wav").?;
    selected.click(d, .{ .ctrl = true });
    try testing.expectEqual(d, selected.previewIndex().?);
    try testing.expect(try session.loadMore());
    try waitIdle(session, &selected);
    try expectSelectedNames(session, &selected, &.{ "a.wav", "d.wav" });

    try session.setSort(.size, &selected);
    try expectSelectedNames(session, &selected, &.{ "a.wav", "d.wav" });
    try testing.expectEqual(@as(usize, 2), selected.count());
    const dragged_from = session.indexOfName("d.wav").?;
    const drag = try selected.dragIndices(testing.allocator, dragged_from);
    defer testing.allocator.free(drag);
    try testing.expectEqual(@as(usize, 2), drag.len);
    const paths = try selection_mod.collectPaths(testing.allocator, session.samples(), drag);
    defer selection_mod.freePaths(testing.allocator, paths);
    try testing.expectEqualStrings("a.wav", core.model.baseName(paths[0]));
    try testing.expectEqualStrings("d.wav", core.model.baseName(paths[1]));

    // Shift 范围、Esc/空白共用的 clear，以及清空后不再预览。
    selected.click(session.indexOfName("e.wav").?, .{ .shift = true });
    try testing.expect(selected.count() >= 2);
    selected.clear();
    try testing.expectEqual(@as(usize, 0), selected.count());
    try testing.expect(selected.previewIndex() == null);
}

test "多选集合受浏览硬上限约束，不产生第二份无界行存储" {
    try testing.expectEqual(@as(usize, 200_000), types.hard_limit);
    var selected = selection_mod.Selection{};
    defer selected.deinit(testing.allocator);
    try selected.resize(testing.allocator, types.hard_limit);
    selected.selectRange(0, types.hard_limit - 1);
    try testing.expectEqual(types.hard_limit, selected.count());
    // 位图是 200000/8 ≈ 25 KiB；身份快照才在变更时临时生成并复用 arena。
    try testing.expect(selected.len() == types.hard_limit);
}

test "只读探针：浏览设置保存入口被 read_only 截断，文件逐字节不变" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "settings.json", .data = "do-not-write" });
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPathFile(testing.io, "settings.json", &buffer);
    const settings_ui = @import("settings_ui.zig");
    const settings_store = @import("settings_store.zig");
    var panel = try settings_ui.Panel.init(testing.allocator, testing.io, settings_store.Settings.init(testing.allocator), buffer[0..len], .{ .read_only = true });
    panel.settings.view.mode = .browse;
    panel.saveViewState();
    panel.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, buffer[0..len], testing.allocator, .limited(64));
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("do-not-write", bytes);
}

test "A→B→A 同时恢复多选与各自滚动位置，目录变短后偏移被夹住" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "root/sub");
    try makeFiles(&tmp);
    // makeFiles 位于 tmp 根；把它们移到 root 下以保持夹具路径简单。
    for ([_][]const u8{ "a.wav", "b.wav", "c.wav", "d.wav", "e.wav" }) |name| {
        var destination: [64]u8 = undefined;
        const sub_path = try std.fmt.bufPrint(&destination, "root/{s}", .{name});
        try tmp.dir.rename(name, tmp.dir, sub_path, testing.io);
    }
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPathFile(testing.io, "root", &buffer);
    const session = try browse.Session.init(testing.allocator, testing.io, buffer[0..root_len], .{ .watch = false });
    defer session.deinit();
    var selected = selection_mod.Selection{};
    defer selected.deinit(testing.allocator);
    try waitIdle(session, &selected);

    selected.click(session.indexOfName("a.wav").?, .{});
    selected.click(session.indexOfName("c.wav").?, .{ .ctrl = true });
    _ = try session.poll(&selected);
    session.history.currentMut().scroll_offset = 440;
    const sub = session.indexOfName("sub").?;
    try session.enterDirectory(sub, &selected);
    try waitIdle(session, &selected);
    session.history.currentMut().scroll_offset = 88;
    try session.goBack(&selected);
    try waitIdle(session, &selected);
    try expectSelectedNames(session, &selected, &.{ "a.wav", "c.wav" });
    try testing.expectEqual(@as(f32, 440), session.history.current().scroll_offset);
    try testing.expectEqual(@as(f32, 40), @import("browse_scroll.zig").clamp(session.history.current().scroll_offset, 6, 44, 224));
}
