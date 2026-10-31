//! 空闲预取的**策略**：视口上下各取多宽、什么时候允许跑一轮、跑过之后怎么记账。
//!
//! 触发点只有两个，都在 UI 线程上（`main.zig`）：帧尾一次、150ms 的 `tick` 一次。
//! 帧尾负责"滚动刚停下"的那一下，tick 负责"停下来了但不再重画"的情况——两者走同一
//! 个闸门，所以**一次视口变化最多补一轮**：
//!
//!   1. `enabled`（`--no-prefetch` 关掉）→ 直接不跑；
//!   2. 视口没变（`dirty == false`）→ 不重跑（停在原地不会反复扫同 50 行）；
//!   3. 距上一轮不到 `interval_s`（默认 120ms，略小于 150ms 的 tick，保证每一拍都
//!      有机会跑）→ 跳过；
//!   4. `Thumbs.stats().pending != 0`（队列里还有可见请求没落地）→ **跳过这一拍**，
//!      视口仍然是 dirty，下一拍再看。这就是"滚动中不预取"：滚动时队列几乎从不清空，
//!      预取自然只在两帧之间真正空闲时才发生。
//!
//! 宽度：前方 `ahead_rows` 行、后方 `behind_rows` 行，夹到 `[0, count)`。40 行 ≈ 2.4 屏，
//! 按 WIC 实测 1.47ms/张 ≈ 59ms 的取图时间——比"40 行滚到眼前"（≈40 帧 = 640ms）
//! 短一个数量级，所以预取几乎总是赶在行进入视口之前完成；10 行后方是给上滚用的。
//!
//! 上限：调度层一次最多要 `max_rows`（50）行，而**队列容量只有 32**，多出来的预取项
//! 由队列按优先级丢掉。所以预取在内存上的上限由"队列容量（在途请求）+ L2 预算（已取
//! 像素）"两道闸共同决定，与滚动速度无关——快速滚动不会让请求或内存无界增长。
//!
//! 本文件不 import UI、不碰 Thumbs（只依赖 zig 标准库），所以 `windowRows` 与节流逻辑
//! 可以在没有窗口、没有工作线程的单元测试里验证。

const std = @import("std");

/// 视口下方预取多少行（"马上要看到的"）。
pub const ahead_rows: usize = 40;
/// 视口上方预取多少行（"往上翻马上要看到的"）。
pub const behind_rows: usize = 10;
/// 一轮最多要多少行；也是调用方准备的 `[]usize` 缓冲长度。
pub const max_rows: usize = ahead_rows + behind_rows;

/// 一轮预取覆盖的行：`[last+1, last+ahead]` 与 `[first-behind, first-1]`，夹到
/// `[0, count)`、写入 `out`、返回写了多少行。前方优先（往下翻是默认方向）。
///
/// 纯函数：不分配、不查缓存、不碰线程。视口行本身（`[first, last]`）不在结果里——
/// 它们这一帧已经由 `acquire` 要过了。
pub fn windowRows(out: []usize, first: usize, last: usize, count: usize) usize {
    if (count == 0 or out.len == 0) return 0;
    const last_row = @min(last, count - 1);
    var used: usize = 0;

    // 前方：紧接视口往下 ahead_rows 行。
    var row = last_row + 1;
    const ahead_stop = @min(count, row + ahead_rows);
    while (row < ahead_stop and used < out.len) : (row += 1) {
        out[used] = row;
        used += 1;
    }

    // 后方：视口上方 behind_rows 行。范围不越过 `last+1`，所以和前方那段不会重复
    // （视口行号理论上连续；这里对 first > last 的输入也成立）。
    const first_row = @min(first, count - 1);
    const behind_stop = @min(first_row, last_row + 1);
    row = behind_stop -| behind_rows;
    while (row < behind_stop and used < out.len) : (row += 1) {
        out[used] = row;
        used += 1;
    }
    return used;
}

/// 预取闸门与记账。只由 UI 线程写、只由 UI 线程读，不需要锁。
pub const Scheduler = struct {
    /// `--no-prefetch` 时为 false：两个触发点都直接返回。
    enabled: bool = true,
    /// 两次预取之间的最小间隔（秒）。120ms 略小于 `main.tick_ms` 的 150ms。
    interval_s: f64 = 0.12,
    /// 最近一次视口（过滤后的行号，含 overscan；和 `ui.list` 建出来的范围一致）。
    first: usize = 0,
    last: usize = 0,
    /// 视口变了、还没跑过预取。
    dirty: bool = true,
    /// 上一轮（或上一次尝试）的时间，QPC 秒。
    last_try_s: f64 = 0,
    /// 因为队列不空闲而跳过的次数 / 真正跑过的轮数（诊断与验收用）。
    skipped_busy: u32 = 0,
    passes: u32 = 0,

    /// 帧尾记下这一帧画出来的行范围。变了才置 dirty（原地不动不重复扫）。
    pub fn noteWindow(self: *Scheduler, first: usize, last: usize) void {
        if (first == self.first and last == self.last) return;
        self.first = first;
        self.last = last;
        self.dirty = true;
    }

    /// 现在允许跑一轮吗（开关 + 视口变过 + 节流）。
    pub fn due(self: *Scheduler, now_s: f64) bool {
        if (!self.enabled or !self.dirty) return false;
        return now_s - self.last_try_s >= self.interval_s;
    }

    /// 队列里还有可见请求：这一拍跳过，但视口仍算"没预取过"，下一拍再看。
    pub fn markBusy(self: *Scheduler, now_s: f64) void {
        self.last_try_s = now_s;
        self.skipped_busy +%= 1;
    }

    /// 记一轮真正跑过的预取（无论入队几条：视口没变之前不再重跑）。
    pub fn markPass(self: *Scheduler, now_s: f64) void {
        self.last_try_s = now_s;
        self.dirty = false;
        self.passes +%= 1;
    }
};

// ---------------------------------------------------------------------------
// 测试：窗口夹取 / 上下限 / 节流（无窗口、无线程、无 IO）
// ---------------------------------------------------------------------------

const testing = std.testing;

fn collect(first: usize, last: usize, count: usize) ![]usize {
    const out = try testing.allocator.alloc(usize, max_rows);
    const used = windowRows(out, first, last, count);
    return out[0..used];
}

test "预取窗口：视口在开头时只有前方 40 行，后方为空" {
    const rows = try collect(0, 20, 2000);
    defer testing.allocator.free(rows.ptr[0..max_rows]);
    try testing.expectEqual(@as(usize, ahead_rows), rows.len);
    try testing.expectEqual(@as(usize, 21), rows[0]);
    try testing.expectEqual(@as(usize, 60), rows[rows.len - 1]);
}

test "预取窗口：视口中段 = 前方 40 + 后方 10，顺序是前方优先" {
    const rows = try collect(100, 120, 2000);
    defer testing.allocator.free(rows.ptr[0..max_rows]);
    try testing.expectEqual(max_rows, rows.len);
    try testing.expectEqual(@as(usize, 121), rows[0]);
    try testing.expectEqual(@as(usize, 160), rows[ahead_rows - 1]);
    // 后方紧接在前方之后：[first-10, first-1]。
    try testing.expectEqual(@as(usize, 90), rows[ahead_rows]);
    try testing.expectEqual(@as(usize, 99), rows[max_rows - 1]);
    // 视口行自己不在里面（它们在帧里已经 acquire 过了）。
    for (rows) |row| try testing.expect(row < 100 or row > 120);
}

test "预取窗口：贴近末尾只剩后方 10 行，不越界" {
    const rows = try collect(1990, 1999, 2000);
    defer testing.allocator.free(rows.ptr[0..max_rows]);
    try testing.expectEqual(behind_rows, rows.len);
    try testing.expectEqual(@as(usize, 1980), rows[0]);
    try testing.expectEqual(@as(usize, 1989), rows[rows.len - 1]);
}

test "预取窗口：空库 / 单屏 / 短缓冲都不越界，也不重复" {
    try testing.expectEqual(@as(usize, 0), windowRows(undefined, 0, 0, 0));
    var empty: [0]usize = undefined;
    try testing.expectEqual(@as(usize, 0), windowRows(&empty, 0, 0, 10));

    // 库只有 5 行且全部在视口里：没有可预取的行。
    var small: [max_rows]usize = undefined;
    try testing.expectEqual(@as(usize, 0), windowRows(&small, 0, 4, 5));

    // 缓冲比 max_rows 短：截断而不是写爆。
    var short: [7]usize = undefined;
    try testing.expectEqual(@as(usize, 7), windowRows(&short, 100, 120, 2000));
    try testing.expectEqual(@as(usize, 121), short[0]);
    try testing.expectEqual(@as(usize, 127), short[6]);

    // first > last 的防御输入：两段不重叠。
    var odd: [max_rows]usize = undefined;
    const used = windowRows(&odd, 60, 40, 2000);
    try testing.expectEqual(max_rows, used);
    for (odd[0..used], 0..) |row, index| {
        if (index == 0) continue;
        try testing.expect(row != odd[index - 1]);
    }
}

test "闸门：开关 / 视口是否变化 / 120ms 节流 / 队列忙时只记账不清 dirty" {
    var scheduler: Scheduler = .{ .last_try_s = 100.0 };

    // 刚构造时 dirty（第一帧就要补一轮），但仍要满足 120ms 节流。
    try testing.expect(!scheduler.due(100.0));
    try testing.expect(!scheduler.due(100.1));
    try testing.expect(scheduler.due(100.2));
    scheduler.markPass(100.2);
    try testing.expect(!scheduler.due(100.5)); // 已跑过：视口没变就不再跑

    // 视口变了：dirty，但还要等节流。
    scheduler.noteWindow(10, 30);
    try testing.expect(!scheduler.due(100.25));
    try testing.expect(!scheduler.due(100.3)); // 距上一轮 100ms，不够 120ms
    try testing.expect(scheduler.due(100.35));

    // 队列忙：只记一次跳过，dirty 保留，下一拍还能补。
    scheduler.markBusy(100.35);
    try testing.expectEqual(@as(u32, 1), scheduler.skipped_busy);
    try testing.expectEqual(@as(u32, 1), scheduler.passes);
    try testing.expect(scheduler.dirty);
    try testing.expect(!scheduler.due(100.4));
    try testing.expect(scheduler.due(100.5));
    scheduler.markPass(100.5);
    try testing.expect(!scheduler.dirty);

    // 关掉之后一律不跑（`--no-prefetch`）。
    scheduler.noteWindow(200, 220);
    scheduler.enabled = false;
    try testing.expect(!scheduler.due(999.0));
    try testing.expect(!scheduler.due(0.0));
}
