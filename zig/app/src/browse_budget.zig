//! 浏览模式的**内存预算**：把"每行实际字节数"量出来，再用它判断「加载更多」会不会
//! 越过 90 MiB 峰值。
//!
//! 为什么不是拍一个 1 KiB：0.35.0 的实测是 50000 行 / 47.86 MiB（探针口径，
//! 基线 13.44），折合 **~721 B/行**（常驻口径），而不是 1 KiB。这个数取决于路径
//! 长度、分配器开销与 ArrayList 的容量余量，所以必须在运行时量：`observe` 拿
//! 一次"这一页装完之后的工作集 + 行分配字节"，取两种口径的**较大值**作为下界，
//! 只允许它随实测调大，不随某次抖动调小。
//!
//! 预算判断用的是**当前工作集 + 预计新增行的字节**，而不是"基线 + 全部行"：
//! 真实窗口的分栏、字体、缩略图都发生在会话建立之后，只有当前工作集包含它们。
//! 首屏没有上一页可量，所以生产侧把首批硬限制在 `first_page_cap`（50000）——
//! 那是 0.35.0 实测过的安全形态；第二批起才走这里的预算。

const core = @import("otto_core");
const bench_win = @import("bench_win.zig");
const types = @import("browse_types.zig");

/// 实测每行开销（常驻口径）。`null` = 还没有一页装完，无法测量。
pub const Budget = struct {
    /// 会话建立时、第一页行还没进来之前的工作集。只用来算"这一页让工作集涨了多少"。
    baseline_ws: usize = 0,
    /// 峰值上限（默认 90 MiB；测试可以注入更小的值走"拒绝"那条路）。
    cap_bytes: usize = types.memory_budget_bytes,
    /// 当前采用的行开销（字节/行）；只增不减。
    per_row: ?f64 = null,

    pub fn init() Budget {
        return initWithCap(types.memory_budget_bytes);
    }

    pub fn initWithCap(cap_bytes: usize) Budget {
        return .{
            .baseline_ws = if (bench_win.resident()) |resident| resident.working_set else 0,
            .cap_bytes = cap_bytes,
        };
    }

    /// 一页装完之后调一次：`row_bytes` 是行存储的**精确**分配字节（容量 + 路径），
    /// `current_ws` 是这一刻的工作集。两者都按"每行"折算，取大的那个。
    pub fn observe(self: *Budget, rows: usize, row_bytes: usize, current_ws: usize) void {
        if (rows == 0) return;
        const rows_f: f64 = @floatFromInt(rows);
        const alloc_per_row: f64 = @as(f64, @floatFromInt(row_bytes)) / rows_f;
        const grown = current_ws -| self.baseline_ws;
        const rss_per_row: f64 = @as(f64, @floatFromInt(grown)) / rows_f;
        const sample = @max(alloc_per_row, rss_per_row);
        if (self.per_row == null or sample > self.per_row.?) self.per_row = sample;
    }

    /// 从当前行数加到 `projected` 行，会不会越过预算？
    ///
    /// 没有实测值时返回 false（首批由 `first_page_cap` 兜底，不在这里猜）。
    pub fn wouldExceed(self: *const Budget, current_ws: usize, rows: usize, projected: usize) bool {
        if (projected <= rows) return false;
        const per_row = self.per_row orelse return false;
        const extra_rows: f64 = @floatFromInt(projected - rows);
        const predicted = @as(f64, @floatFromInt(current_ws)) + extra_rows * per_row +
            @as(f64, @floatFromInt(types.memory_safety_bytes));
        return predicted > @as(f64, @floatFromInt(self.cap_bytes));
    }

    /// 预测峰值（MiB），报告用。
    pub fn predictedMiB(self: *const Budget, current_ws: usize, rows: usize, projected: usize) f64 {
        const per_row = self.per_row orelse 0;
        const extra_rows: f64 = @floatFromInt(if (projected > rows) projected - rows else 0);
        const bytes = @as(f64, @floatFromInt(current_ws)) + extra_rows * per_row;
        return bytes / (1024.0 * 1024.0);
    }
};

/// 行存储这一刻实际占的分配字节：条目/样本/合成 id 的**容量** + 每条路径的真实长度。
///
/// 容量而不是长度：`ArrayList` 的余量也是常驻内存，不能假装它不存在。
pub fn rowBytes(
    entries_capacity: usize,
    samples_capacity: usize,
    ids_capacity: usize,
    entries: []const types.Entry,
) usize {
    var paths: usize = 0;
    for (entries) |entry| paths += entry.path.len;
    return entries_capacity * @sizeOf(types.Entry) +
        samples_capacity * @sizeOf(core.model.Sample) +
        ids_capacity +
        paths;
}
