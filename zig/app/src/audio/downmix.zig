//! 多声道 PCM → 立体声下混的**唯一**实现：WAV 解码与 FLAC provider 共用。
//!
//! 为什么抽出来：`audio/wav.zig` 早就把 >2 声道混成双声道，而
//! `providers/native_audio.zig`（FLAC）在 0.11 第一次真实消费时漏了这一步。
//! 如果 FLAC 再抄一份规则，两条路以后一定会在"5.1 的 C/LFE 怎么分、平均还是
//! 加权、四舍五入还是截断"上漂移；同一段声音经 WAV 与 FLAC 播出来就会不同。
//! 所以这里只有 `downmixInto` 一个循环，两个调用方都走它：
//!
//!   * `audio/wav.zig`：源格式任意（8/16/24/32 位 PCM、float32），输出**保持
//!     源格式**（24 位 WAV 下混后仍是 24 位）；
//!   * `providers/native_audio.zig`：zig-audio 只交付交错 i16，输出 PCM16。
//!
//! 规则（与 0.9.0 的 WAV 行为逐字节一致）：
//!
//!   * 偶数下标 → 左，奇数下标 → 右；每侧各自**简单平均**；
//!   * 5.1 的 LFE 也参与平均（不装滤波器）；环绕同样按下标奇偶分到两侧；
//!   * 采样先归一化到 [-1, 1]（8 位无符号先减 128），写完再钳位；float 的
//!     NaN 当 0（NaN 在 float WAV 里合法，不能让它变成 UB）；
//!   * 不做相位/延迟/增益矩阵，不做采样率转换。
//!
//! 单声道 / 立体声**不经过本模块**：调用方直接保留原字节（逐位不变）。

const std = @import("std");
const wav_header = @import("otto_wav_header");

pub const SampleFormat = wav_header.SampleFormat;

pub const Error = error{OutOfMemory};

/// 下混只需要三个字段；采样率用不到。
pub const Fmt = struct {
    channels: u16,
    bits: u16,
    format: SampleFormat,
};

/// 一帧源数据 / 一帧目标数据的字节数。
fn srcFrameBytes(fmt: Fmt) usize {
    return @as(usize, fmt.channels) * (fmt.bits / 8);
}

fn dstFrameBytes(bits: u16) usize {
    return 2 * (bits / 8);
}

/// 下混后的字节数。调用方常用它先 `ensureTotalCapacity`，避免大文件反复 realloc。
pub fn outputByteLen(src_len: usize, fmt: Fmt) usize {
    const src_frame = srcFrameBytes(fmt);
    if (src_frame == 0) return 0;
    return (src_len / src_frame) * dstFrameBytes(fmt.bits);
}

/// 分配并下混：WAV 解码器用。输出与源同格式（位深/类型），2 声道。
pub fn allocate(allocator: std.mem.Allocator, src: []const u8, fmt: Fmt) Error![]u8 {
    const out = try allocator.alloc(u8, outputByteLen(src.len, fmt));
    errdefer allocator.free(out);
    downmixInto(out, src, fmt, fmt.bits, fmt.format);
    return out;
}

/// 原地写入调用方给的缓冲：FLAC provider 每解一块 i16 就下混一块，不攒整段
/// 多声道 PCM。`dst.len` 必须等于 `outputByteLen(src.len, fmt)`。
pub fn pcm16Into(dst: []u8, src: []const u8, channels: u16) void {
    downmixInto(dst, src, .{ .channels = channels, .bits = 16, .format = .pcm }, 16, .pcm);
}

/// 唯一的混音循环。`dst_bits/dst_format` 允许源与目标格式不同（FLAC 只有 i16
/// 源，但 WAV 可能是 24 位 / float；两侧规则仍完全一致）。
pub fn downmixInto(dst: []u8, src: []const u8, fmt: Fmt, dst_bits: u16, dst_format: SampleFormat) void {
    std.debug.assert(fmt.channels > 2);
    const src_frame = srcFrameBytes(fmt);
    const dst_frame = dstFrameBytes(dst_bits);
    std.debug.assert(src_frame != 0 and dst_frame != 0);
    const frames = src.len / src_frame;
    std.debug.assert(dst.len == frames * dst_frame);

    var frame: usize = 0;
    while (frame < frames) : (frame += 1) {
        var sum = [2]f64{ 0, 0 };
        var count = [2]u32{ 0, 0 };
        var channel: usize = 0;
        while (channel < fmt.channels) : (channel += 1) {
            const offset = frame * src_frame + channel * (fmt.bits / 8);
            const value = readSample(src, offset, fmt.bits, fmt.format);
            const side = channel & 1;
            sum[side] += value;
            count[side] += 1;
        }
        var side: usize = 0;
        while (side < 2) : (side += 1) {
            const value = if (count[side] == 0)
                0
            else
                sum[side] / @as(f64, @floatFromInt(count[side]));
            writeSample(dst, frame * dst_frame + side * (dst_bits / 8), dst_bits, dst_format, value);
        }
    }
}

// ---------------------------------------------------------------------------
// 采样读写（只在下混时使用；<= 2 声道走 memcpy）
// ---------------------------------------------------------------------------

fn readSample(bytes: []const u8, offset: usize, bits: u16, format: SampleFormat) f64 {
    return switch (format) {
        .float => @as(f64, @floatCast(@as(f32, @bitCast(readU32(bytes, offset))))),
        .pcm => switch (bits) {
            8 => (@as(f64, @floatFromInt(bytes[offset])) - 128.0) / 128.0,
            16 => @as(f64, @floatFromInt(readI16(bytes, offset))) / 32768.0,
            24 => @as(f64, @floatFromInt(readI24(bytes, offset))) / 8388608.0,
            32 => @as(f64, @floatFromInt(readI32(bytes, offset))) / 2147483648.0,
            else => 0,
        },
    };
}

fn writeSample(bytes: []u8, offset: usize, bits: u16, format: SampleFormat, value: f64) void {
    // NaN / ±inf 在 float WAV 里是合法数据；下混时不能把它变成 UB。
    const finite = if (std.math.isNan(value)) 0.0 else std.math.clamp(value, -1.0, 1.0);
    switch (format) {
        .float => writeU32(bytes, offset, @bitCast(@as(f32, @floatCast(finite)))),
        .pcm => switch (bits) {
            8 => {
                const scaled: i64 = @intFromFloat(@round(finite * 127.0));
                bytes[offset] = @intCast(std.math.clamp(scaled + 128, 0, 255));
            },
            16 => writeU16(bytes, offset, @bitCast(@as(i16, @intFromFloat(@round(finite * 32767.0))))),
            24 => writeU24(bytes, offset, @intFromFloat(@round(finite * 8388607.0))),
            32 => writeU32(bytes, offset, @bitCast(@as(i32, @intFromFloat(@round(finite * 2147483647.0))))),
            else => {},
        },
    }
}

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

fn writeU16(bytes: []u8, offset: usize, value: u16) void {
    std.mem.writeInt(u16, bytes[offset..][0..2], value, .little);
}

fn writeU32(bytes: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], value, .little);
}

fn writeU24(bytes: []u8, offset: usize, value: i32) void {
    const raw: u32 = @bitCast(value);
    bytes[offset] = @truncate(raw);
    bytes[offset + 1] = @truncate(raw >> 8);
    bytes[offset + 2] = @truncate(raw >> 16);
}

// ---------------------------------------------------------------------------
// 测试：规则本身 + WAV/FLAC 两条调用路径的等价性
// ---------------------------------------------------------------------------

const testing = std.testing;

test "5.1：偶数下标 → L、奇数下标 → R（L/R 保留，C/LFE/环绕按同一份平均）" {
    // 一帧：L=1000, R=2000, C=3000, LFE=4000, Ls=5000, Rs=6000
    // L = (1000+3000+5000)/3 = 3000；R = (2000+4000+6000)/3 = 4000。
    const samples = [_]i16{ 1000, 2000, 3000, 4000, 5000, 6000 };
    const src = std.mem.sliceAsBytes(&samples);
    const out = try allocate(testing.allocator, src, .{ .channels = 6, .bits = 16, .format = .pcm });
    defer testing.allocator.free(out);
    const expected = [_]i16{ 3000, 4000 };
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&expected), out);
}

test "5.1：WAV 路径（allocate）与 FLAC 路径（pcm16Into）逐字节相同" {
    const samples = [_]i16{
        1000,  2000,   3000,  4000,  5000,  6000,
        -1000, -2000,  -3000, -4000, -5000, -6000,
        32767, -32768, 1234,  -2345, 9876,  -8765,
    };
    const src = std.mem.sliceAsBytes(&samples);
    const expected = [_]i16{ 3000, 4000, -3000, -4000, 14625, -14626 };
    const wav_side = try allocate(testing.allocator, src, .{ .channels = 6, .bits = 16, .format = .pcm });
    defer testing.allocator.free(wav_side);

    var flac_side: [expected.len * 2]u8 = undefined;
    pcm16Into(&flac_side, src, 6);

    const expected_bytes = std.mem.sliceAsBytes(&expected);
    try testing.expectEqualSlices(u8, expected_bytes, wav_side);
    try testing.expectEqualSlices(u8, expected_bytes, &flac_side);
}

test "outputByteLen：按整帧计，尾部残片不计入" {
    const fmt: Fmt = .{ .channels = 6, .bits = 16, .format = .pcm };
    // 3 帧 × 6 声道 × 2 字节 = 36 字节；再塞 2 字节残片仍只算 3 帧。
    try testing.expectEqual(@as(usize, 3 * 2 * 2), outputByteLen(36, fmt));
    try testing.expectEqual(@as(usize, 3 * 2 * 2), outputByteLen(38, fmt));
    try testing.expectEqual(@as(usize, 0), outputByteLen(5, fmt));
}

test "24 位 WAV 下混保持 24 位；5.1 的 LFE 也参与平均" {
    // 一帧 6 声道 24 位：L=0x100000, R=0x200000, C=0x300000, LFE=0x400000,
    // Ls=0x500000, Rs=0x600000 → L=0x300000, R=0x400000。
    const samples = [_]u8{
        0x00, 0x00, 0x10, // L  0x100000
        0x00, 0x00, 0x20, // R  0x200000
        0x00, 0x00, 0x30, // C  0x300000
        0x00, 0x00, 0x40, // LFE
        0x00, 0x00, 0x50, // Ls
        0x00, 0x00, 0x60, // Rs
    };
    const out = try allocate(testing.allocator, &samples, .{ .channels = 6, .bits = 24, .format = .pcm });
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x00, 0x30, 0x00, 0x00, 0x40 }, out);
}
