//! 浏览模式 Stage 1 的三条判据的测试：
//!   * 分页：首批截断后「加载更多」从上次停下的地方接着读（`FindNextFileW` 续读），
//!     条数正确、不重复；
//!   * 内存预算：拒绝下一页时**数清剩余条数**（不静默停）；
//!   * 恢复：目录被删掉 → `unavailable=true` → 目录回来 → 下一次交互重试 → 恢复；
//!   * reconcile：重扫窗口里新增的文件在重扫完成后补应用，最终行数与磁盘一致。
//!
//! 全部走生产代码（`browse.Session` / 真 RDCW），不 import nanoui：测试进程不建窗口。

const std = @import("std");
const core = @import("otto_core");
const browse = @import("browse.zig");
const browse_dir = @import("otto_browse_dir");
const budget_mod = @import("browse_budget.zig");
const types = @import("browse_types.zig");
const selection_mod = @import("selection.zig");
const testing = std.testing;

fn realPath(tmp: *std.testing.TmpDir, sub: []const u8, buffer: []u8) ![]const u8 {
    const len = try tmp.dir.realPathFile(testing.io, sub, buffer);
    return buffer[0..len];
}

fn sleepMs(ms: u64) void {
    std.Io.sleep(testing.io, std.Io.Duration.fromMilliseconds(@intCast(ms)), .awake) catch {};
}

/// 等"不在枚举"为止（最多 `budget_ms` 毫秒）。
fn waitIdle(session: *browse.Session, selection: *selection_mod.Selection, budget_ms: usize) !void {
    var waited: usize = 0;
    while (session.info().enumerating and waited < budget_ms) : (waited += 1) {
        _ = try session.poll(selection);
        sleepMs(1);
    }
    try testing.expect(!session.info().enumerating);
}

test "分页：首批截断后加载更多接着读，条数正确且不重复" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const names = [_][]const u8{ "a.wav", "b.wav", "c.wav", "d.wav", "e.wav" };
    for (names) |name| try tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = "x" });

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try realPath(&tmp, ".", &buffer);

    const session = try browse.Session.init(testing.allocator, testing.io, root, .{
        .watch = false,
        .limit = 2, // 页大小 2：5 个文件 = 首发 2 + 两页
    });
    defer session.deinit();
    var selection = selection_mod.Selection{};
    defer selection.deinit(testing.allocator);

    try waitIdle(session, &selection, 3000);
    try testing.expectEqual(@as(usize, 2), session.samples().len);
    try testing.expect(session.info().has_more);
    try testing.expect(session.info().truncated);
    try testing.expectEqual(@as(usize, 1), session.info().pages);

    // 第一次「加载更多」：追加 2 条（不是从头重扫）。
    try testing.expect(try session.loadMore());
    try waitIdle(session, &selection, 3000);
    try testing.expectEqual(@as(usize, 4), session.samples().len);
    try testing.expectEqual(@as(usize, 2), session.info().pages);
    try testing.expect(session.info().has_more);

    // 第二次：把最后 1 条读进来，偷看确认没有更多。
    try testing.expect(try session.loadMore());
    try waitIdle(session, &selection, 3000);
    try testing.expectEqual(@as(usize, 5), session.samples().len);
    try testing.expect(!session.info().has_more);
    try testing.expect(!session.info().truncated);
    try testing.expect(!session.canLoadMore());
    try testing.expectEqual(@as(usize, 3), session.info().pages);

    // 不重复：5 行 5 个不同文件名。
    var seen = std.StringHashMapUnmanaged(void){};
    defer seen.deinit(testing.allocator);
    for (session.samples()) |sample| {
        try testing.expect(!seen.contains(sample.file_name));
        try seen.put(testing.allocator, sample.file_name, {});
    }
}

test "内存预算：拒绝加载更多后数清剩余条数，不静默停" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const names = [_][]const u8{ "a.wav", "b.wav", "c.wav", "d.wav", "e.wav" };
    for (names) |name| try tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = "x" });

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try realPath(&tmp, ".", &buffer);

    // 预算注入 1 字节：第一页能看（首批有 `first_page_cap` 兜底），第二页必然拒绝。
    const session = try browse.Session.init(testing.allocator, testing.io, root, .{
        .watch = false,
        .limit = 2,
        .memory_budget_bytes = 1,
    });
    defer session.deinit();
    var selection = selection_mod.Selection{};
    defer selection.deinit(testing.allocator);

    try waitIdle(session, &selection, 3000);
    try testing.expectEqual(@as(usize, 2), session.samples().len);
    try testing.expect(session.info().has_more);

    // 拒绝：返回 false，会话进入"数剩余"而不是悄悄停。
    try testing.expect(!try session.loadMore());
    try testing.expect(session.info().mem_refused);
    try waitIdle(session, &selection, 3000);
    const info = session.info();
    try testing.expectEqual(@as(usize, 2), info.entries);
    try testing.expectEqual(@as(usize, 3), info.remaining);
    try testing.expect(!info.has_more);
    try testing.expect(info.truncated);
    try testing.expect(!session.canLoadMore());
}

test "重扫窗口里新增的文件：reconcile 之后行数与磁盘一致" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // 30 个 `w…`：重扫枚举到一半时暂停，此时从游标**后面**（名字序在前）加 5 个
    // `a-…` 文件，枚举器不会再列它们——只有 reconcile 能把它们补进来。
    for (0..30) |index| {
        var name: [24]u8 = undefined;
        const file = try std.fmt.bufPrint(&name, "w{d:0>3}.png", .{index});
        try tmp.dir.writeFile(testing.io, .{ .sub_path = file, .data = "x" });
    }
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try realPath(&tmp, ".", &buffer);

    const session = try browse.Session.init(testing.allocator, testing.io, root, .{});
    defer session.deinit();
    if (session.watcher == null) return error.SkipZigTest;
    var selection = selection_mod.Selection{};
    defer selection.deinit(testing.allocator);

    try waitIdle(session, &selection, 3000);
    try testing.expectEqual(@as(usize, 30), session.samples().len);

    // 暂停在枚举了 10 条之后（600 ms 足够写 5 个文件）。
    session.forceRescan(10, 600);
    var paused = false;
    var waited: usize = 0;
    while (waited < 5000) : (waited += 1) {
        _ = try session.poll(&selection);
        if (session.rescanPaused()) {
            paused = true;
            break;
        }
        sleepMs(1);
    }
    try testing.expect(paused);

    for (0..5) |index| {
        var name: [24]u8 = undefined;
        const file = try std.fmt.bufPrint(&name, "a-{d:0>3}.png", .{index});
        try tmp.dir.writeFile(testing.io, .{ .sub_path = file, .data = "x" });
    }

    // 等重扫收尾 + reconcile 补事件。
    waited = 0;
    while (waited < 5000) : (waited += 1) {
        _ = try session.poll(&selection);
        if (!session.info().enumerating and !session.rescanPaused()) break;
        sleepMs(2);
    }
    for (0..8) |_| {
        _ = try session.poll(&selection);
        sleepMs(2);
    }

    try testing.expectEqual(@as(usize, 35), session.samples().len);
    // 补进来的 5 个 `a-…` 真的在行里，而且没有重复。
    var found: usize = 0;
    for (session.samples()) |sample| {
        if (std.mem.startsWith(u8, sample.file_name, "a-")) found += 1;
    }
    try testing.expectEqual(@as(usize, 5), found);
    try testing.expect(session.info().reconciles >= 1);
}

test "目录消失再回来：不可用正确翻转，交互重试后行数与磁盘一致" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "watched");
    for (0..3) |index| {
        var path: [48]u8 = undefined;
        const sub = try std.fmt.bufPrint(&path, "watched/w{d}.wav", .{index});
        try tmp.dir.writeFile(testing.io, .{ .sub_path = sub, .data = "x" });
    }
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try realPath(&tmp, "watched", &buffer);

    const session = try browse.Session.init(testing.allocator, testing.io, root, .{});
    defer session.deinit();
    if (session.watcher == null) return error.SkipZigTest;
    var selection = selection_mod.Selection{};
    defer selection.deinit(testing.allocator);

    try waitIdle(session, &selection, 3000);
    try testing.expectEqual(@as(usize, 3), session.samples().len);

    // 目录被删掉（U 盘拔出 / 磁盘被移走）：监听线程硬退出，界面显示"路径不可用"。
    try tmp.dir.deleteTree(testing.io, "watched");
    var unavailable = false;
    var waited: usize = 0;
    while (waited < 5000) : (waited += 1) {
        _ = try session.poll(&selection);
        if (session.info().unavailable) {
            unavailable = true;
            break;
        }
        sleepMs(2);
    }
    try testing.expect(unavailable);

    // 目录回来：同样的 3 个文件。
    try tmp.dir.createDirPath(testing.io, "watched");
    for (0..3) |index| {
        var path: [48]u8 = undefined;
        const sub = try std.fmt.bufPrint(&path, "watched/w{d}.wav", .{index});
        try tmp.dir.writeFile(testing.io, .{ .sub_path = sub, .data = "x" });
    }

    // "用户的下一次交互"：只在这里重试一次（没有定时轮询）。
    session.retryUnavailable();
    waited = 0;
    while (waited < 5000) : (waited += 1) {
        _ = try session.poll(&selection);
        if (!session.info().unavailable and !session.info().enumerating) break;
        sleepMs(2);
    }
    const info = session.info();
    try testing.expect(!info.unavailable);
    try testing.expectEqual(@as(usize, 3), info.entries);
    try testing.expect(info.rescans >= 1);
}

test "预算：每行字节取两种口径的较大值，只增不减" {
    var budget = budget_mod.Budget{ .baseline_ws = 0, .cap_bytes = 4 * 1024 * 1024 };
    budget.observe(10, 100, 200); // 分配口径 10 B/行；常驻口径 20 B/行 → 20
    try testing.expectApproxEqAbs(@as(f64, 20), budget.per_row.?, 0.001);
    budget.observe(20, 200, 300); // 分配 10；常驻 15 → 不得把 20 降下来
    try testing.expectApproxEqAbs(@as(f64, 20), budget.per_row.?, 0.001);
    // 4 MiB 预算、当前 1 MiB、每行 20 B：加 20 万行 = 3.8 MiB → 越过。
    try testing.expect(budget.wouldExceed(1024 * 1024, 20, 200_020));
    try testing.expect(!budget.wouldExceed(1024 * 1024, 20, 100));
}

test "宪章 90 MiB：10 万行在 90 处拒绝，每行略小则放行" {
    // 上限本身是 90 MiB（不是 89、也不是 91）。
    try testing.expectEqual(@as(usize, 90), types.memory_budget_bytes >> 20);

    var budget = budget_mod.Budget{ .baseline_ws = 0, .cap_bytes = types.memory_budget_bytes };
    // 0.35.0 的实测常驻口径是 ~721 B/行；这里取 1000 B/行，模拟路径更长的目录。
    budget.per_row = 1000;
    const ws: usize = 45 * 1024 * 1024;
    // 45 MiB + 5 万行 × 1000 B + 2 MiB 安全页 = 95.7 MiB → 必须拒绝。
    try testing.expect(budget.wouldExceed(ws, 50_000, 100_000));
    // 同样的 10 万行，每行 900 B：45 + 42.9 + 2 = 89.9 MiB → 放行（刚好在 90 以内）。
    budget.per_row = 900;
    try testing.expect(!budget.wouldExceed(ws, 50_000, 100_000));
}

test "宪章 10 万行 ≤ 90 MiB：每行固定字节再多 512 B 就越线" {
    // 这条是「5 万行 × 你加的字节 = 多少 MiB」的可执行版：把行结构 + id 的
    // 固定开销乘上 10 万行，和 0.35.0 实测基线 13.44 MiB、2 MiB 安全页一起算。
    // 下次给 Entry / Sample 加固定字段，这个乘数会自己变大，越线就红。
    const per_row: usize = @sizeOf(types.Entry) + @sizeOf(core.model.Sample) + types.id_stride;
    const baseline: usize = 14 * 1024 * 1024;
    const rows: usize = 100_000;
    try testing.expect(rows * per_row + baseline + types.memory_safety_bytes <= types.memory_budget_bytes);
    // 每行固定部分 +512 B（例如路径/身份字段扩宽）就会越过 90 MiB。
    try testing.expect(rows * (per_row + 512) + baseline + types.memory_safety_bytes > types.memory_budget_bytes);
}
