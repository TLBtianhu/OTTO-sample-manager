//! 行就绪探针：每帧记下"这一帧建出来的行（样本下标）"和"这一行这一帧画出图标没有"。
//!
//! 只为一件事存在：`--bench-scroll` 要能量出**滚动经过的行里，图标已就绪的比例**。
//! 那个判断只有视图本身做得了（它拿到的是过滤后的行号、样本下标和 `row_thumb.draw`
//! 的返回值），而验收又要在帧外统计，所以视图把这一帧的结论写进这里，基准每帧读一次。
//!
//! 零分配、固定容量（一屏 17 行 + 上下 overscan 各 4 行 = 25，72 留了两倍余量）、
//! 不参与布局与绘制：`add` 就是两次写。溢出时静默截断（多出来的行这一帧不记账，
//! 不 panic、不分配，也不影响画面）。
//!
//! 产品路径不读它；只有 `--bench-scroll` 的计数器读。放在单独文件里是为了让
//! "生产代码里那段只为验收存在的记账"一眼可见、也只占一处。

pub const RowProbe = struct {
    /// 一帧最多记多少行。大于任何窗口尺寸（见文件头），溢出截断。
    pub const capacity: usize = 72;

    /// 这一帧建出来的行的样本下标。
    samples: [capacity]usize = @splat(0),
    /// 对应行这一帧是否画上了真图（不是占位/待取/无预览）。
    ready: [capacity]bool = @splat(false),
    /// 有效条数。
    len: usize = 0,
    /// 从启动到现在 view 跑过多少帧（诊断用）。
    frames: u64 = 0,

    /// 每帧开头调一次：清空上一帧的记账。
    pub fn begin(self: *RowProbe) void {
        self.len = 0;
        self.frames +%= 1;
    }

    /// 记一行。容量满了就丢这一行（不影响其它行，也不影响画面）。
    pub fn add(self: *RowProbe, sample_index: usize, has_image: bool) void {
        if (self.len == capacity) return;
        self.samples[self.len] = sample_index;
        self.ready[self.len] = has_image;
        self.len += 1;
    }
};

// ---------------------------------------------------------------------------
// 测试：容量上限 / begin 清零 / 帧计数（纯数据，无 IO）
// ---------------------------------------------------------------------------

const testing = @import("std").testing;

test "探针：记录顺序、begin 清零、容量满了截断不越界" {
    var probe: RowProbe = .{};
    try testing.expectEqual(@as(usize, 0), probe.len);

    probe.begin();
    probe.add(7, true);
    probe.add(8, false);
    try testing.expectEqual(@as(usize, 2), probe.len);
    try testing.expectEqual(@as(usize, 7), probe.samples[0]);
    try testing.expect(probe.ready[0]);
    try testing.expectEqual(@as(usize, 8), probe.samples[1]);
    try testing.expect(!probe.ready[1]);
    try testing.expectEqual(@as(u64, 1), probe.frames);

    // 溢出：写满之后多出来的条目被丢掉，len 停在容量上。
    probe.begin();
    for (0..RowProbe.capacity + 20) |index| probe.add(index, false);
    try testing.expectEqual(RowProbe.capacity, probe.len);
    try testing.expectEqual(RowProbe.capacity - 1, probe.samples[RowProbe.capacity - 1]);
    try testing.expectEqual(@as(u64, 2), probe.frames);

    probe.begin();
    try testing.expectEqual(@as(usize, 0), probe.len);
}
