//! 缩略图账：把 ready / 本帧画图 / 请求 / 无 handler / 缓存 / 失败 / pending 的
//! 合计打到 stdout，数字变了才打一行。`--nanoui-snapshot` 的日志里能数清最终账目。
//!
//! 从 `main.zig` 拆出来只为守住单文件行数（与 `preview_audio.zig` 同一条理由）。
//! 它不认识窗口，也不改任何状态；只是持有"上次打印过的数字"。

const std = @import("std");
const thumbs_mod = @import("thumbs.zig");

pub const Reporter = struct {
    reported: bool = false,
    printed_ready: u32 = 0,
    printed_rows: u32 = 0,
    printed_settled: bool = false,
    /// L3 计数的合计：写盘 / 淘汰可能发生在 ready 之后，单独看它才会补印最后一行。
    printed_l3: u64 = 0,

    /// 数字变了才打印。`rows_with_image` 是本帧真正画出缩略图的可见行数。
    pub fn report(self: *Reporter, thumbs: *thumbs_mod.Thumbs, rows_with_image: u32) void {
        const ready = thumbs.readyCount();
        const stats = thumbs.stats();
        // 「全部落地」也值得打一行：默认 fixture 的 wav 全都取不到，只有这一行能
        // 把最终账目（failed=N、pending=0）带出来。
        const settled = stats.pending == 0;
        const l3 = stats.l3_hit + stats.l3_miss + stats.l3_write + stats.l3_evicted + stats.l3_corrupt;
        const changed = !self.reported or ready != self.printed_ready or
            rows_with_image != self.printed_rows or l3 != self.printed_l3 or
            (settled and !self.printed_settled);
        if (!changed) return;
        self.reported = true;
        self.printed_ready = ready;
        self.printed_rows = rows_with_image;
        self.printed_settled = settled;
        self.printed_l3 = l3;

        std.debug.print(
            "otto-lite: 缩略图 ready={d} 本帧画图={d} requested={d} no_handler={d} cached={d} failed={d} pending={d} " ++
                "l3_hit={d} l3_miss={d} l3_write={d} l3_evicted={d} l3_bytes={d} l3_corrupt={d}\n",
            .{
                stats.ready,      rows_with_image, stats.requested,  stats.no_handler,
                stats.cached,     stats.failed,    stats.pending,    stats.l3_hit,
                stats.l3_miss,    stats.l3_write,  stats.l3_evicted, stats.l3_bytes,
                stats.l3_corrupt,
            },
        );
    }
};
