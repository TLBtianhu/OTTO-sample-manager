//! 波形峰值：解码后的 PCM → 每桶一对 `min`/`max`。
//!
//! 为什么单独一层：波形是**数据**，不是像素。峰值按桶算一次、存进
//! `preview.AudioSession`，渲染（`waveform.zig`）与将来的 L3 磁盘缓存都只消费
//! 这一层；换尺寸、换颜色不需要重新解码。
//!
//! 口径（报告里也要写）：
//!   * 输入是 `wav.decode` 的产物（交错、`channels` 声道、`bits` 位、`format`）；
//!     8/16/24/32 位 PCM 与 32 位 float 都先折算成 i16 再比较，所以下游只有一种数；
//!   * **多声道先混合再取峰值**（同一帧各声道简单平均）：听感上是一个整体，
//!     分轨波形是以后的事；
//!   * 桶数可配（默认 512）。第 i 桶覆盖的帧区间用整数除法切分：
//!     `[i*frames/buckets, (i+1)*frames/buckets)`——不重叠、不留空、不除零；
//!   * **桶数 > 帧数时夹到帧数**：每桶恰好覆盖一帧，输出长度 = 帧数。这样
//!     "每桶只覆盖一帧"成立，也不会出现空桶导致 `maxInt`/`minInt` 冒充数据；
//!   * 0 帧（空 PCM）返回空 `Peaks`（`len() == 0`），调用方不需要判空指针。
//!
//! 纯函数：不碰磁盘、不碰线程、不 import nanoui。`compute` 只分配两个 i16 数组，
//! 由调用方用**同一个 allocator** 调 `Peaks.deinit` 释放。

const std = @import("std");
const wav = @import("wav.zig");

/// 默认桶数。240 点宽的预览条在 2x 屏上是 480 设备像素：512 桶既不会让波形
/// 变成一根根柱子，又很便宜（800 ms 的 22050 Hz 素材只有 17640 帧、512 次边界）。
pub const default_buckets: usize = 512;

/// 每桶一对采样值。`min.len == max.len == 桶数`（空音频时为 0）。
pub const Peaks = struct {
    min: []i16 = &.{},
    max: []i16 = &.{},

    /// 桶数。空音频是 0；没有"未知"这一档。
    pub fn len(self: Peaks) usize {
        return self.min.len;
    }

    /// 释放两个数组。必须与 `compute` 用同一个 allocator；之后不可再用。
    /// 空 `Peaks`（`deinit` 一个从未算过的会话）是合法的无操作。
    pub fn deinit(self: Peaks, allocator: std.mem.Allocator) void {
        if (self.min.len != 0) allocator.free(self.min);
        if (self.max.len != 0) allocator.free(self.max);
    }
};

pub const Error = std.mem.Allocator.Error;

/// 把一段交错 PCM 压成 `buckets` 对 min/max。
///
/// `pcm` 只在调用期间借用；返回值里的两个切片归调用方所有。`bits`/`format`
/// 与 `wav.Wav` 的字段一一对应（wav 解码层已经把不支持的格式挡在门外，这里遇到
/// 未知位深按 0 处理，不 panic）。
pub fn compute(
    allocator: std.mem.Allocator,
    pcm: []const u8,
    channels: u16,
    bits: u16,
    format: wav.SampleFormat,
    buckets: usize,
) Error!Peaks {
    const bytes_per_sample: usize = @as(usize, bits) / 8;
    if (bytes_per_sample == 0 or channels == 0 or buckets == 0) return .{};

    const frame_bytes = @as(usize, channels) * bytes_per_sample;
    const frames: u64 = pcm.len / frame_bytes;
    // 空音频（0 帧）没有波形可算：返回空 peaks，而不是一条假的中线。
    if (frames == 0) return .{};

    // 桶比帧多时夹到帧数：每桶一帧，既不除零也不产生空桶。
    const count: usize = @intCast(@min(@as(u64, buckets), frames));
    const min = try allocator.alloc(i16, count);
    errdefer allocator.free(min);
    const max = try allocator.alloc(i16, count);
    errdefer allocator.free(max);

    var bucket: usize = 0;
    while (bucket < count) : (bucket += 1) {
        // count <= frames，所以每个区间至少一帧；`else` 分支只是防御，
        // 保证任何情况下都不会出现"空桶用 maxInt/minInt 冒充数据"。
        const start = @as(u64, bucket) * frames / count;
        const next = (@as(u64, bucket) + 1) * frames / count;
        const end = if (next > start) next else start + 1;
        var low: i16 = std.math.maxInt(i16);
        var high: i16 = std.math.minInt(i16);
        var frame = start;
        while (frame < end) : (frame += 1) {
            const value = mixedSample(
                pcm,
                @as(usize, @intCast(frame)),
                @as(usize, channels),
                bits,
                format,
            );
            low = @min(low, value);
            high = @max(high, value);
        }
        min[bucket] = low;
        max[bucket] = high;
    }

    return .{ .min = min, .max = max };
}

/// 单帧的 i16 值（多声道先平均）。给音频图标的**粗采样**用：只读几帧时不需要
/// 构造整段 PCM。调用方保证 `frame * channels * bytes_per_sample` 在 `pcm` 内。
pub fn frameValue(
    pcm: []const u8,
    frame: usize,
    channels: u16,
    bits: u16,
    format: wav.SampleFormat,
) i16 {
    if (channels == 0) return 0;
    return mixedSample(pcm, frame, @as(usize, channels), bits, format);
}

/// 一帧的所有声道先平均（i64 累加，不溢出）再夹回 i16。
fn mixedSample(
    pcm: []const u8,
    frame: usize,
    channels: usize,
    bits: u16,
    format: wav.SampleFormat,
) i16 {
    const bytes_per_sample: usize = @as(usize, bits) / 8;
    const base = frame * channels * bytes_per_sample;
    var sum: i64 = 0;
    var channel: usize = 0;
    while (channel < channels) : (channel += 1) {
        sum += sampleI16(pcm, base + channel * bytes_per_sample, bits, format);
    }
    const mixed = @divTrunc(sum, @as(i64, @intCast(channels)));
    return @intCast(std.math.clamp(mixed, std.math.minInt(i16), std.math.maxInt(i16)));
}

/// 单个采样 → i16。float 按 ±1.0 = 满幅折算（NaN/±inf 当 0，不能变成 UB）。
fn sampleI16(bytes: []const u8, offset: usize, bits: u16, format: wav.SampleFormat) i16 {
    return switch (format) {
        .float => floatToI16(@as(f32, @bitCast(readU32(bytes, offset)))),
        .pcm => switch (bits) {
            // 8 位 PCM 按 WAV 约定是无符号的，128 = 静音。
            8 => @intCast((@as(i32, bytes[offset]) - 128) * 256),
            16 => readI16(bytes, offset),
            24 => @intCast(readI24(bytes, offset) >> 8),
            32 => @intCast(readI32(bytes, offset) >> 16),
            else => 0,
        },
    };
}

fn floatToI16(value: f32) i16 {
    const finite = if (std.math.isNan(value)) 0.0 else std.math.clamp(value, -1.0, 1.0);
    const scaled = @round(finite * 32767.0);
    return @intFromFloat(std.math.clamp(scaled, -32768.0, 32767.0));
}

// 小端采样读取。与 `wav.zig` 里的同名辅助函数重复是有意的：那边是文件私有，
// 而"峰值层"不该为了 4 个三行函数去扩 `wav` 的公开 API（也让本层能单独测试）。

fn readU16(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}

fn readU32(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

fn readI16(bytes: []const u8, offset: usize) i16 {
    return @bitCast(readU16(bytes, offset));
}

fn readI32(bytes: []const u8, offset: usize) i32 {
    return @bitCast(readU32(bytes, offset));
}

fn readI24(bytes: []const u8, offset: usize) i32 {
    const raw: u32 = @as(u32, bytes[offset]) |
        (@as(u32, bytes[offset + 1]) << 8) |
        (@as(u32, bytes[offset + 2]) << 16);
    if (raw & 0x0080_0000 != 0) return @bitCast(raw | 0xFF00_0000);
    return @intCast(raw);
}

// ---------------------------------------------------------------------------
// 测试：全部在内存里造采样，不碰磁盘、不碰窗口
// ---------------------------------------------------------------------------

const testing = std.testing;

/// i16 交错 PCM 的便捷入口（测试与将来的 16 位快路径用）。
fn computeI16(
    allocator: std.mem.Allocator,
    samples: []const i16,
    channels: u16,
    buckets: usize,
) Error!Peaks {
    return compute(allocator, std.mem.sliceAsBytes(samples), channels, 16, .pcm, buckets);
}

test "正弦：包络上下对称，桶数是请求值" {
    // 1024 帧、每 64 帧一个周期（16 桶 = 每桶 1/4 周期）。
    var samples: [1024]i16 = undefined;
    for (&samples, 0..) |*sample, index| {
        const phase = @as(f32, @floatFromInt(index)) * 2.0 * std.math.pi / 64.0;
        sample.* = @intFromFloat(@round(@sin(phase) * 30000.0));
    }

    const peaks = try computeI16(testing.allocator, &samples, 1, 16);
    defer peaks.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 16), peaks.len());

    var sum_max: i64 = 0;
    var sum_min: i64 = 0;
    var highest: i16 = std.math.minInt(i16);
    var lowest: i16 = std.math.maxInt(i16);
    for (peaks.max) |value| {
        sum_max += value;
        highest = @max(highest, value);
    }
    for (peaks.min) |value| {
        sum_min += value;
        lowest = @min(lowest, value);
    }
    // 满幅在 ±30000 附近；包络对称 ⇒ 各桶 max 之和与 min 之和抵消。
    try testing.expect(highest > 29900);
    try testing.expect(lowest < -29900);
    try testing.expect(@abs(sum_max + sum_min) <= 32);
}

test "静音：每桶 min == max == 0" {
    const samples = [_]i16{ 0, 0, 0, 0, 0, 0, 0, 0 };
    const peaks = try computeI16(testing.allocator, &samples, 1, 4);
    defer peaks.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 4), peaks.len());
    for (peaks.min) |value| try testing.expectEqual(@as(i16, 0), value);
    for (peaks.max) |value| try testing.expectEqual(@as(i16, 0), value);
}

test "满幅方波：每桶都顶到 ±32767" {
    // 逐帧翻转的方波（Nyquist）：每个桶里都有正负两极，所以每桶都到满幅。
    var samples: [1024]i16 = undefined;
    for (&samples, 0..) |*sample, index| sample.* = if (index % 2 == 0) 32767 else -32767;

    const peaks = try computeI16(testing.allocator, &samples, 1, 8);
    defer peaks.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 8), peaks.len());
    for (peaks.max) |value| try testing.expectEqual(@as(i16, 32767), value);
    for (peaks.min) |value| try testing.expectEqual(@as(i16, -32767), value);
}

test "单帧：桶数大于帧数时夹到 1 桶（每桶一帧，不除零）" {
    const samples = [_]i16{-12345};
    const peaks = try computeI16(testing.allocator, &samples, 1, default_buckets);
    defer peaks.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), peaks.len());
    try testing.expectEqual(@as(i16, -12345), peaks.min[0]);
    try testing.expectEqual(@as(i16, -12345), peaks.max[0]);
}

test "空音频（0 帧）：空 peaks，deinit 无操作" {
    const peaks = try compute(testing.allocator, &.{}, 1, 16, .pcm, default_buckets);
    // 注意：这里不调 deinit 也不泄漏——空 peaks 没有分配。
    try testing.expectEqual(@as(usize, 0), peaks.len());
    try testing.expect(peaks.min.len == 0 and peaks.max.len == 0);

    const empty = try compute(testing.allocator, &.{}, 1, 16, .pcm, 0);
    try testing.expectEqual(@as(usize, 0), empty.len());
}

test "立体声按混合后算：左右反相 = 静音，同相 = 原值" {
    // 两帧：第一帧 L=+32767 R=-32767（抵消），第二帧 L=R=1000。
    const samples = [_]i16{ 32767, -32767, 1000, 1000 };
    const peaks = try computeI16(testing.allocator, &samples, 2, 2);
    defer peaks.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), peaks.len());
    try testing.expectEqual(@as(i16, 0), peaks.min[0]);
    try testing.expectEqual(@as(i16, 0), peaks.max[0]);
    try testing.expectEqual(@as(i16, 1000), peaks.min[1]);
    try testing.expectEqual(@as(i16, 1000), peaks.max[1]);
}

test "float32：±1.0 折成满幅，0 是静音" {
    const samples = [_]f32{ 1.0, -1.0, 0.0 };
    const peaks = try compute(
        testing.allocator,
        std.mem.sliceAsBytes(&samples),
        1,
        32,
        .float,
        3,
    );
    defer peaks.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), peaks.len());
    try testing.expectEqual(@as(i16, 32767), peaks.max[0]);
    try testing.expectEqual(@as(i16, -32767), peaks.min[1]);
    try testing.expectEqual(@as(i16, 0), peaks.max[2]);
    try testing.expectEqual(@as(i16, 0), peaks.min[2]);
}

test "桶边界：10 帧 3 桶 = 3/3/4 帧，不重不漏" {
    // 单调上升的斜坡：每桶 max 是该桶最后一帧，min 是第一帧。
    var samples: [10]i16 = undefined;
    for (&samples, 0..) |*sample, index| sample.* = @intCast(index);
    const peaks = try computeI16(testing.allocator, &samples, 1, 3);
    defer peaks.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), peaks.len());
    try testing.expectEqualSlices(i16, &[_]i16{ 0, 3, 6 }, peaks.min);
    try testing.expectEqualSlices(i16, &[_]i16{ 2, 5, 9 }, peaks.max);
}

test "24 位 PCM：按高位折算成 i16" {
    // 单声道两帧：+8388607（满幅正）、-8388608（满幅负）。
    const pcm = [_]u8{ 0xFF, 0xFF, 0x7F, 0x00, 0x00, 0x80 };
    const peaks = try compute(testing.allocator, &pcm, 1, 24, .pcm, 2);
    defer peaks.deinit(testing.allocator);
    try testing.expectEqual(@as(i16, 32767), peaks.max[0]);
    try testing.expectEqual(@as(i16, -32768), peaks.min[1]);
}
