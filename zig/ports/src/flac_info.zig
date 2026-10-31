//! FLAC 的 **STREAMINFO** 头部解析：只读文件最前面的 42 字节，不解码、不看帧。
//!
//! 布局固定（FLAC 规范）：
//!
//! ```text
//! "fLaC"                         4 字节魔数
//! metadata block header          1 字节 last/type + 3 字节大端长度
//! STREAMINFO                     34 字节：类型必须是 0、长度必须是 34
//! ```
//!
//! STREAMINFO 里只有最后 8 字节与我们有关（前 10 字节是 block/frame size）：
//!
//! ```text
//! 20 bit sample_rate | 3 bit channels-1 | 5 bit bits-1 | 36 bit total_samples
//! ```
//!
//! `total_samples == 0` 在 FLAC 里是合法值："编码器没写总样本数"。这时**时长未知**，
//! 不是 0 秒——调用方（`probe`）必须返回 null，不能把 0 当成已知时长。
//!
//! 本文件是纯字节解析：不读文件、不分配、不 import 任何平台模块。

const std = @import("std");

pub const Error = error{
    /// 前 4 字节不是 `fLaC`。
    NotFlac,
    /// 魔数 / block header / STREAMINFO 没有完整落在给定的字节里。
    Truncated,
    /// 第一个 metadata block 不是 STREAMINFO，或它的长度不是 34。
    BadStreamInfo,
};

pub const Info = struct {
    sample_rate: u32,
    channels: u32,
    bits: u16,
    /// 容器声明的总样本数；0 = 编码器没写（时长未知）。
    total_samples: u64,
};

/// 解析 FLAC 文件头。`bytes` 只需要文件的前 42 字节（可以更多）。
pub fn parse(bytes: []const u8) Error!Info {
    if (bytes.len < 4) return error.Truncated;
    if (!std.mem.eql(u8, bytes[0..4], "fLaC")) return error.NotFlac;
    if (bytes.len < 8) return error.Truncated;

    // block header：bit7 = last-metadata-block，低 7 位是类型。
    const block_type = bytes[4] & 0x7F;
    const block_length: usize = (@as(usize, bytes[5]) << 16) |
        (@as(usize, bytes[6]) << 8) |
        @as(usize, bytes[7]);
    // 第一个 block 必须是 STREAMINFO（类型 0），固定 34 字节。顺序不对就不是
    // 我们能解析的 FLAC，不做"往后找找看"的猜测。
    if (block_type != 0 or block_length != 34) return error.BadStreamInfo;

    const start: usize = 8;
    if (bytes.len < start + 34) return error.Truncated;
    const block = bytes[start..][0..34];

    // 前 10 字节是 min/max block size 与 min/max frame size；从第 10 字节起是
    // 8 字节位域（20 + 3 + 5 + 36 = 64 bit）。
    const sample_rate: u32 = (@as(u32, block[10]) << 12) |
        (@as(u32, block[11]) << 4) |
        (@as(u32, block[12]) >> 4);
    const channels: u32 = ((@as(u32, block[12]) >> 1) & 0x7) + 1;
    const bits: u16 = (((@as(u16, block[12]) & 0x1) << 4) |
        (@as(u16, block[13]) >> 4)) + 1;
    const total_samples: u64 = (@as(u64, block[13] & 0x0F) << 32) |
        (@as(u64, block[14]) << 24) |
        (@as(u64, block[15]) << 16) |
        (@as(u64, block[16]) << 8) |
        @as(u64, block[17]);

    // 0 Hz 是非法的；继续算会除以零。channels / bits 的 +1 保证非零。
    if (sample_rate == 0) return error.BadStreamInfo;

    return .{
        .sample_rate = sample_rate,
        .channels = channels,
        .bits = bits,
        .total_samples = total_samples,
    };
}

/// 时长（毫秒，向下取整）。`total_samples == 0` 返回 null = 时长未知。
///
/// 36 bit 最大 2^36，乘 1000 只有 ~2^46，不会溢出 u64；仍用 `mul` 兜底，避免
/// 以后改成更宽的字段时静默回绕。
pub fn durationMs(info: Info) ?u64 {
    if (info.total_samples == 0) return null;
    const scaled = std.math.mul(u64, info.total_samples, 1000) catch return null;
    return scaled / info.sample_rate;
}

// ---------------------------------------------------------------------------
// 测试：纯内存字节，不碰磁盘
// ---------------------------------------------------------------------------

const testing = std.testing;

/// 造一份只有 42 字节头的 FLAC：`fLaC` + STREAMINFO（34 字节）。
fn buildInfo(
    buffer: []u8,
    sample_rate: u32,
    channels: u32,
    bits: u16,
    total_samples: u64,
) []u8 {
    @memset(buffer[0..42], 0);
    @memcpy(buffer[0..4], "fLaC");
    buffer[4] = 0x80; // last metadata block + type 0（STREAMINFO）
    buffer[5] = 0;
    buffer[6] = 0;
    buffer[7] = 34;

    const block = buffer[8..][0..34];
    block[10] = @intCast(sample_rate >> 12);
    block[11] = @intCast((sample_rate >> 4) & 0xFF);
    block[12] = @intCast(((sample_rate & 0xF) << 4) |
        ((channels - 1) << 1) |
        ((bits - 1) >> 4));
    block[13] = @intCast(((bits - 1) & 0xF) << 4 |
        @as(u16, @intCast(total_samples >> 32)));
    block[14] = @intCast((total_samples >> 24) & 0xFF);
    block[15] = @intCast((total_samples >> 16) & 0xFF);
    block[16] = @intCast((total_samples >> 8) & 0xFF);
    block[17] = @intCast(total_samples & 0xFF);
    return buffer[0..42];
}

test "STREAMINFO：44100 / 单声道 / 16 位 / 66150 样本 = 1500 ms" {
    var bytes: [42]u8 = undefined;
    const info = try parse(buildInfo(&bytes, 44_100, 1, 16, 66_150));
    try testing.expectEqual(@as(u32, 44_100), info.sample_rate);
    try testing.expectEqual(@as(u32, 1), info.channels);
    try testing.expectEqual(@as(u16, 16), info.bits);
    try testing.expectEqual(@as(u64, 66_150), info.total_samples);
    try testing.expectEqual(@as(?u64, 1500), durationMs(info));
}

test "STREAMINFO：声道的 3 bit 与位深的 5 bit 都带 -1 偏置" {
    var bytes: [42]u8 = undefined;
    const surround = try parse(buildInfo(&bytes, 48_000, 6, 24, 48_000));
    try testing.expectEqual(@as(u32, 6), surround.channels);
    try testing.expectEqual(@as(u16, 24), surround.bits);

    // 8 声道、32 位是这两个字段的上界（(7)+1 / (31)+1）。
    var max_bytes: [42]u8 = undefined;
    const max = try parse(buildInfo(&max_bytes, 192_000, 8, 32, 192_000));
    try testing.expectEqual(@as(u32, 8), max.channels);
    try testing.expectEqual(@as(u16, 32), max.bits);
}

test "total_samples = 0：时长未知返回 null，不是 0 秒" {
    var bytes: [42]u8 = undefined;
    const info = try parse(buildInfo(&bytes, 44_100, 2, 16, 0));
    try testing.expectEqual(@as(u64, 0), info.total_samples);
    try testing.expect(durationMs(info) == null);
}

test "截断 / 非 FLAC / 第一个 block 不是 STREAMINFO：具名错误" {
    try testing.expectError(error.Truncated, parse("fLa"));
    try testing.expectError(error.NotFlac, parse("RIFF\x00\x00\x00\x00WAVE"));

    var bytes: [42]u8 = undefined;
    const full = buildInfo(&bytes, 44_100, 1, 16, 1000);
    try testing.expectError(error.Truncated, parse(full[0..41]));

    // 第一个 block 是 PADDING（类型 1）而不是 STREAMINFO。
    var wrong_type: [42]u8 = undefined;
    _ = buildInfo(&wrong_type, 44_100, 1, 16, 1000);
    wrong_type[4] = 0x81;
    try testing.expectError(error.BadStreamInfo, parse(wrong_type[0..42]));

    // 类型对但长度不是 34。
    var wrong_size: [42]u8 = undefined;
    _ = buildInfo(&wrong_size, 44_100, 1, 16, 1000);
    wrong_size[7] = 33;
    try testing.expectError(error.BadStreamInfo, parse(wrong_size[0..42]));
}
