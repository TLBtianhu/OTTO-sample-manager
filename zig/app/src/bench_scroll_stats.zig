//! `--bench-scroll` 的统计与报表：把帧日志（每帧 QPC 时间戳 + build/layout/
//! paint/raster/present/wait）变成 p50/p95/max、有效 fps、丢帧与预算判定。
//! 纯算术 + 打印，不碰窗口、不注入。
//!
//! 只统计**滚轮引起的那一帧**（`wheel_indices`）：nanoui 自己的 16 ms 动画定时器
//! 在滚动时可能额外插帧，那些帧记成"额外帧"；如果把它们算进滚轮帧的间隔，帧产量
//! 会翻倍，反而看不出"每次输入是否在 16.7 ms 内交付"。
//!
//! 两个丢掉的定义都报，因为软件节拍器不是硬件垂直同步：
//!   * `drops`：帧间隔 > 16.7 ms（任务口径，含节拍器 ±0.4 ms 抖动）；
//!   * `misses`：帧间隔 > 25 ms（≈ 掉了一个完整的 60 Hz 刷新，真丢帧）；
//!   * `over_budget`：这一帧的做工（六段之和）> 16.67 ms，说明"没做完"。
//! 60 fps 的判定用 `fps` + `over_budget` + `misses`，`drops` 只作为参考列。

const std = @import("std");
const nanoui = @import("nanoui");
const bench_stats = @import("bench_stats.zig");

const frame_log = nanoui.ui.frame_log;

pub const target_fps: f64 = 60.0;
pub const budget_ms: f64 = 1000.0 / target_fps;

pub const Stats = struct {
    posted: usize = 0,
    /// The frame each wheel message caused (one per injection, normally).
    frames: usize = 0,
    /// Every frame the log saw in the window, animation-timer frames included.
    all_frames: usize = 0,
    extra_frames: usize = 0,
    missing_frames: usize = 0,
    span_s: f64 = 0,
    wall_s: f64 = 0,
    fps: f64 = 0,
    all_fps: f64 = 0,
    wheel_hz: f64 = 0,
    intervals: bench_stats.Summary = .{},
    inject: bench_stats.Summary = .{},
    work: bench_stats.Summary = .{},
    build: bench_stats.Summary = .{},
    layout: bench_stats.Summary = .{},
    paint: bench_stats.Summary = .{},
    raster: bench_stats.Summary = .{},
    present: bench_stats.Summary = .{},
    wait: bench_stats.Summary = .{},
    after: bench_stats.Summary = .{},
    /// From the wheel message being posted to its frame starting.
    latency: bench_stats.Summary = .{},
    drops: usize = 0,
    misses: usize = 0,
    over_budget: usize = 0,
};

/// `wheel_indices[post]` 是那一拍滚轮消息引起的帧在日志里的下标；没有帧的位置
/// 传一个越界下标（`bench_scroll.no_frame`），这里按"没交付"跳过。
pub fn summarize(
    allocator: std.mem.Allocator,
    records: []const frame_log.Record,
    wheel_indices: []const usize,
    inject_times: []const f64,
    started: f64,
    ended: f64,
) !Stats {
    var out: Stats = .{
        .posted = inject_times.len,
        .all_frames = records.len,
        .wall_s = @max(0, ended - started),
    };
    const count = wheel_indices.len;
    var wheel_times = try allocator.alloc(f64, count);
    var intervals = try allocator.alloc(f64, count -| 1);
    var works = try allocator.alloc(f64, count);
    var builds = try allocator.alloc(f64, count);
    var layouts = try allocator.alloc(f64, count);
    var paints = try allocator.alloc(f64, count);
    var rasters = try allocator.alloc(f64, count);
    var presents = try allocator.alloc(f64, count);
    var waits = try allocator.alloc(f64, count);
    var afters = try allocator.alloc(f64, count);
    var latencies = try allocator.alloc(f64, count);

    var used: usize = 0;
    var previous_t: f64 = 0;
    for (wheel_indices, 0..) |record_index, post| {
        if (record_index >= records.len) continue;
        const record = records[record_index];
        wheel_times[used] = record.t;
        if (used > 0) intervals[used - 1] = @max(0, (record.t - previous_t) * 1000);
        works[used] = record.workMs();
        builds[used] = record.build_ms;
        layouts[used] = record.layout_ms;
        paints[used] = record.paint_ms;
        rasters[used] = record.raster_ms;
        presents[used] = record.present_ms;
        waits[used] = record.drawable_wait_ms;
        afters[used] = record.after_frame_ms;
        latencies[used] = @max(0, (record.t - inject_times[post]) * 1000);
        previous_t = record.t;
        used += 1;
    }
    out.frames = used;
    out.extra_frames = records.len -| used;
    out.missing_frames = count -| used;
    if (used == 0) return out;
    out.span_s = @max(0, wheel_times[used - 1] - wheel_times[0]);
    if (out.span_s > 0) out.fps = @as(f64, @floatFromInt(used - 1)) / out.span_s;
    if (out.wall_s > 0) out.wheel_hz = @as(f64, @floatFromInt(out.posted)) / out.wall_s;
    if (records.len > 1) {
        const all_span = records[records.len - 1].t - records[0].t;
        if (all_span > 0) out.all_fps = @as(f64, @floatFromInt(records.len - 1)) / all_span;
    }

    out.intervals = bench_stats.summarize(allocator, intervals[0 .. used -| 1]);
    out.work = bench_stats.summarize(allocator, works[0..used]);
    out.build = bench_stats.summarize(allocator, builds[0..used]);
    out.layout = bench_stats.summarize(allocator, layouts[0..used]);
    out.paint = bench_stats.summarize(allocator, paints[0..used]);
    out.raster = bench_stats.summarize(allocator, rasters[0..used]);
    out.present = bench_stats.summarize(allocator, presents[0..used]);
    out.wait = bench_stats.summarize(allocator, waits[0..used]);
    out.after = bench_stats.summarize(allocator, afters[0..used]);
    out.latency = bench_stats.summarize(allocator, latencies[0..used]);
    var injections = try allocator.alloc(f64, inject_times.len -| 1);
    for (inject_times, 0..) |at, index| {
        if (index > 0) injections[index - 1] = @max(0, (at - inject_times[index - 1]) * 1000);
    }
    out.inject = bench_stats.summarize(allocator, injections);

    for (intervals[0 .. used -| 1]) |ms| {
        if (ms > 16.7) out.drops += 1;
        if (ms > 25.0) out.misses += 1;
    }
    for (works[0..used]) |ms| {
        if (ms > budget_ms) out.over_budget += 1;
    }
    return out;
}

pub fn print(stats: Stats) void {
    const interval_n = stats.intervals.n;
    const drop_pct = if (interval_n > 0)
        100.0 * @as(f64, @floatFromInt(stats.drops)) / @as(f64, @floatFromInt(interval_n))
    else
        0;
    std.debug.print(
        "scroll-bench: fps={d:.2}（滚轮帧）  all_fps={d:.2}（含动画定时器帧）  inject p50={d:.2} p95={d:.2} max={d:.2} ms\n",
        .{ stats.fps, stats.all_fps, stats.inject.p50, stats.inject.p95, stats.inject.max },
    );
    std.debug.print(
        "scroll-bench: interval p50={d:.2} p95={d:.2} max={d:.2} ms  drops_gt_16.7={d}/{d} ({d:.1}%)  missed_gt_25={d}\n",
        .{ stats.intervals.p50, stats.intervals.p95, stats.intervals.max, stats.drops, interval_n, drop_pct, stats.misses },
    );
    std.debug.print(
        "scroll-bench: post→frame latency p50={d:.2} p95={d:.2} max={d:.2} ms\n",
        .{ stats.latency.p50, stats.latency.p95, stats.latency.max },
    );
    std.debug.print(
        "scroll-bench: work p50={d:.2} p95={d:.2} max={d:.2} ms  over_budget(>16.67)={d}/{d}（p95 占预算 {d:.0}%）\n",
        .{ stats.work.p50, stats.work.p95, stats.work.max, stats.over_budget, stats.frames, if (stats.work.p95 > 0) 100.0 * stats.work.p95 / budget_ms else 0 },
    );
}
