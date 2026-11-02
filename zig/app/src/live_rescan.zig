//! `Live` 的**重扫协作**：溢出标脏、重扫期间压住事件（hold）、重扫完成后按原顺序
//! replay，以及那本「排了几次 / 上一次扫成什么样」的账。
//!
//! 为什么单独一枝：`Change.overflow` 不是一条普通的增删改，它是一条「有事件丢了」
//! 的信号。处理它需要**三拍**协作——先标脏并排一次重扫窗口，本批其余事件先压住
//! （重扫要一个稳定的旧视图做基线），等扫描线程交回结果后再按原顺序把压住的事件
//! `Index.apply` 一遍（`Index.apply` 幂等，重复应用同一条是安全的）。
//!
//! 原来的写法把这三拍和「排空 watcher」「适配事件」挤在同一个 `poll` 里，读的人
//! 很难分清哪几行是重扫、哪几行是监听。这里把三拍收进 `applyBatch`：调用方交出
//! 一批 `Change`，拿回一本 `ApplyReport`，中间的状态全在本结构里。
//!
//! 线程模型：扫描线程只把 `scan.Scan` 放进自旋锁保护的单格结果里，
//! `service` 与 `holdChange` 仍然只在调用方线程（UI 的 tick）上跑——`Index`
//! 永远只被同一个线程改。
//!
//! 所有权：`Bridge` 借用 `root`（由 `Live` 复制持有，并保证比本结构活得久），
//! `deinit` 会 join 掉扫描线程，所以之后释放 root 是安全的。

const std = @import("std");
const core = @import("otto_core");
const rescan_ui = @import("rescan_ui.zig");

/// 溢出后的局部重扫：防抖窗口 + 工作线程 + 压住的事件队列。借用 `root`。
pub const Bridge = struct {
    rescan: rescan_ui.Rescan,
    /// 最近一次完成的重扫的账（`--demo-rescan` 与日志读它）。
    last: rescan_ui.Report = .{},
    /// 已完成的重扫次数；每完成一次 +1（成功和失败都算，用来等结果）。
    serial: u64 = 0,

    /// 建好防抖/扫描状态。`allocator` 必须线程安全：扫描线程用它分配 arena。
    pub fn init(allocator: std.mem.Allocator, io: std.Io, root: []const u8) Bridge {
        return .{ .rescan = rescan_ui.Rescan.init(allocator, io, root) };
    }

    /// 停扫描线程；之后不可再用（`root` 才可以释放）。
    pub fn deinit(self: *Bridge) void {
        self.rescan.deinit();
    }

    /// 排一次重扫（防抖从这一刻起算）；已在排队/进行中时是幂等的。
    pub fn request(self: *Bridge) void {
        self.rescan.request();
    }

    /// 重扫排队 / 进行中（UI 可以据此决定是否显示「正在重扫」）。
    pub fn active(self: *const Bridge) bool {
        return self.rescan.active();
    }

    /// 已完成的重扫次数（见 `Live.rescanSerial`）。
    pub fn rescanSerial(self: *const Bridge) u64 {
        return self.serial;
    }

    /// 最近一次完成的重扫的账。
    pub fn lastRescan(self: *const Bridge) rescan_ui.Report {
        return self.last;
    }

    /// 应用一批事件，顺带推进一次重扫。返回的是本批的合计（`Live.poll` 原样交出去）。
    ///
    /// 三条路径：
    ///   * 批里有 overflow：标脏 + 排重扫 + 记账，并把**其余**事件压住（overflow 本身
    ///     不压：它只标脏，同一批不需要再触发一轮）；
    ///   * 批里没有 overflow，但上一轮的扫描还在跑：同样压住，等它完成；
    ///   * 都不是：直接 `Index.apply`。
    ///
    /// 压住的事件由 `rescan_ui.Rescan` 在扫描结束时按原顺序 replay，`service` 把
    /// 结果折进 `report`（`rescanned` 与四个 rescan_* 计数）。
    pub fn applyBatch(
        self: *Bridge,
        index: *core.index.Index,
        changes: []const core.index.Change,
    ) error{OutOfMemory}!core.index.ApplyReport {
        var report = core.index.ApplyReport{};
        var overflow_lost: u32 = 0;
        var has_overflow = false;
        for (changes) |change| {
            switch (change) {
                .overflow => |lost| {
                    has_overflow = true;
                    overflow_lost +|= lost;
                },
                else => {},
            }
        }

        if (has_overflow) {
            // 溢出本身只是一条「有事件丢了」的信号：先标脏并排一次重扫窗口，
            // 本批的其余事件不能先应用——重扫需要一个稳定的旧视图做基线。
            index.markDirty();
            self.rescan.request();
            report.overflowed = true;
            report.overflow_lost = overflow_lost;
        }

        if (has_overflow or self.rescan.active()) {
            // 重扫期间压住事件，完成后再按原顺序 replay（Index.apply 幂等）。
            // overflow 不压：它只标脏，同一批不需要再触发一轮。
            for (changes) |change| {
                switch (change) {
                    .overflow => {},
                    else => try self.rescan.holdChange(change),
                }
            }
        } else {
            report = try index.apply(changes);
        }

        if (try self.rescan.service(index, &report)) |finished| {
            self.last = finished;
            self.serial +%= 1;
            report.rescanned = true;
            if (finished.ok) {
                report.rescan_added = finished.added;
                report.rescan_removed = finished.removed;
                report.rescan_moved = finished.moved;
                report.rescan_modified = finished.modified;
                report.rescan_unchanged = finished.unchanged;
                std.debug.print(
                    "rescan: added={d} removed={d} moved={d} modified={d} dirtied={d} " ++
                        "unchanged={d} scanned={d} replayed={d} dirty={} ms={d:.2}\n",
                    .{
                        finished.added,
                        finished.removed,
                        finished.moved,
                        finished.modified,
                        finished.dirtied,
                        finished.unchanged,
                        finished.scanned,
                        finished.replayed,
                        index.isDirty(),
                        finished.elapsed_ms,
                    },
                );
            } else {
                std.debug.print(
                    "rescan: failed error={s} replayed={d} dirty={} ms={d:.2}\n",
                    .{
                        finished.failure orelse "?",
                        finished.replayed,
                        index.isDirty(),
                        finished.elapsed_ms,
                    },
                );
            }
        }

        return report;
    }
};
