//! 基准用的小工具：百分位 / 中位数 / 单调时钟。
//!
//! 只做算术，不碰 IO、不碰窗口；`--bench` 的各个子测量共用这一份实现，
//! 免得「缩略图按 nearest-rank 算 p95、搜索按另一种算法算」这种表格自相矛盾。
//!
//! 时间戳沿用 `thumb_bench.zig` 的取法（`std.Io.Clock.Timestamp.now(io, .awake)`），
//! 因为那里已经在用、且不受系统墙上时钟调整影响。

const std = @import("std");

/// 一组延迟的汇总。全部单位由调用方决定（基准里只用毫秒，但本文件不假设）。
pub const Summary = struct {
    n: usize = 0,
    p50: f64 = 0,
    p95: f64 = 0,
    max: f64 = 0,
};

/// 单调时钟：基准的每个计时区间都从它开始。
pub fn now(io: std.Io) std.Io.Clock.Timestamp {
    return std.Io.Clock.Timestamp.now(io, .awake);
}

/// `now(io) - started` 的毫秒数。
pub fn sinceMs(io: std.Io, started: std.Io.Clock.Timestamp) f64 {
    return @as(f64, @floatFromInt(started.untilNow(io).raw.nanoseconds)) / 1_000_000.0;
}

/// 汇总一组样本。
///
/// 百分位用 **nearest-rank**（升序第 ceil(q·n) 个，1 起算）：样本量是 20 / 100 / 200
/// 这种整数，报出来的数一定是**真实测到过的一次**，不会出现「99.7 ms」这种没人见过
/// 的值。超过 512 个时退回堆上的副本（基准里不会发生，保留正确性）。
pub fn summarize(allocator: std.mem.Allocator, samples: []const f64) Summary {
    if (samples.len == 0) return .{};
    var buffer: [512]f64 = undefined;
    var owned: ?[]f64 = null;
    defer if (owned) |copy| allocator.free(copy);
    const scratch = if (samples.len <= buffer.len) buffer[0..samples.len] else blk: {
        owned = allocator.dupe(f64, samples) catch return .{ .n = samples.len };
        break :blk owned.?;
    };
    if (scratch.ptr != samples.ptr) @memcpy(scratch, samples);
    std.mem.sort(f64, scratch, {}, lessThan);

    return .{
        .n = scratch.len,
        .p50 = nearestRank(scratch, 0.50),
        .p95 = nearestRank(scratch, 0.95),
        .max = scratch[scratch.len - 1],
    };
}

fn nearestRank(sorted: []const f64, q: f64) f64 {
    const rank = @ceil(q * @as(f64, @floatFromInt(sorted.len)));
    const index: usize = if (rank < 1) 0 else @min(@as(usize, @intFromFloat(rank - 1)), sorted.len - 1);
    return sorted[index];
}

fn lessThan(_: void, a: f64, b: f64) bool {
    return a < b;
}

/// 中位数（偶数个取上中位；nearest-rank p50 与它一致，便于表格互相核对）。
pub fn median(allocator: std.mem.Allocator, samples: []const f64) f64 {
    return summarize(allocator, samples).p50;
}

// ---------------------------------------------------------------------------
// 测试：纯算术，不碰 IO
// ---------------------------------------------------------------------------

const testing = std.testing;

test "百分位用 nearest-rank：取到的值一定是真实样本" {
    const samples = [_]f64{ 5, 1, 4, 2, 3 };
    const summary = summarize(testing.allocator, &samples);
    try testing.expectEqual(@as(f64, 3), summary.p50);
    try testing.expectEqual(@as(f64, 5), summary.p95);
    try testing.expectEqual(@as(f64, 5), summary.max);
}

test "20 个样本的 p95 是第 19 个（升序），不是第 20 个" {
    var samples: [20]f64 = undefined;
    for (&samples, 0..) |*value, index| value.* = @floatFromInt(index + 1);
    const summary = summarize(testing.allocator, &samples);
    try testing.expectEqual(@as(f64, 19), summary.p95);
    try testing.expectEqual(@as(f64, 10), summary.p50);
}

test "空样本返回全 0，不崩" {
    const summary = summarize(testing.allocator, &.{});
    try testing.expectEqual(@as(usize, 0), summary.n);
    try testing.expectEqual(@as(f64, 0), summary.p95);
}

test "summarize 不修改调用方的切片" {
    const samples = [_]f64{ 3, 1, 2 };
    _ = summarize(testing.allocator, &samples);
    try testing.expectEqualSlices(f64, &.{ 3, 1, 2 }, &samples);
}
