//! MP3 头部解析：跳过 ID3v2，找到第一帧，优先读 Xing/Info 的帧数，否则按
//! 比特率估算时长。**不解码、不读音频负载**。
//!
//! 只支持 Layer III（MPEG-1 / 2 / 2.5）——Layer I/II 的帧长公式与每帧样本数都
//! 不同，本轮不做；遇到就返回 `Unsupported`，让 `probe` 当"读不了"处理，而不是
//! 拿 Layer III 的公式算一个看起来合理的错数。
//!
//! ## Xing/Info 的位置
//!
//! ```text
//! [4 字节帧头][可选 2 字节 CRC][side info][Xing/Info + flags + frames ...]
//! ```
//!
//! side info 长度由 MPEG 版本与声道模式决定：
//!   * MPEG-1：单声道 17、双声道 32；
//!   * MPEG-2 / 2.5：单声道 9、双声道 17。
//!
//! `Xing`（VBR）与 `Info`（CBR 但写了帧数）只是四个字节的标志不同，后面的
//! flags/frames 布局一样。`frames` 是**第一帧的帧数**，总样本数 = frames ×
//! 1152（MPEG-1）或 frames × 576（MPEG-2 / 2.5）——这个数来自容器声明，不是估算。
//!
//! ## 没有 Xing 时
//!
//! `duration = (file_size - id3_bytes) * 8 / bitrate`。MP3 没有全局头，这个结果
//! 建立在"整段音频码率恒定"的假设上，所以调用方必须把 `estimated = true` 带到
//! 界面上（列表行显示 `≈`）。`viper.mp3` 就是这种文件。
//!
//! 本文件是纯字节解析：不读文件、不分配、不 import 任何平台模块。

const std = @import("std");

pub const Error = error{
    /// 前 4 字节连一个帧头都凑不齐，或声明的第一帧超出了文件大小。
    Truncated,
    /// ID3v2 头存在但 syncsafe 长度非法。
    BadId3,
    /// 没有找到任何有效的 Layer III 帧同步。
    NotMp3,
    /// 版本 / 层 / 码率索引不支持（例如 Layer I/II、free bitrate）。
    Unsupported,
};

pub const Info = struct {
    duration_ms: u64,
    /// true = 由文件大小 / 比特率推算；false = 来自 Xing/Info 的帧数。
    estimated: bool,
    sample_rate: u32,
    channels: u32,
    /// MP3 本身没有位深；16 是解码器输出的 PCM 位深（与预览会话一致）。
    bits: u16 = 16,
};

const Version = enum { mpeg1, mpeg2, mpeg25 };

const Header = struct {
    version: Version,
    sample_rate: u32,
    /// 比特率（bit/s）。
    bitrate: u32,
    padding: bool,
    mono: bool,
    /// 保护位为 0 时帧头后还有 2 字节 CRC，Xing 要再往后挪。
    has_crc: bool,

    /// Layer III 的帧长（字节）；整数除法与规范一致。
    fn frameLength(self: Header) u32 {
        const coefficient: u32 = if (self.version == .mpeg1) 144 else 72;
        const padding: u32 = if (self.padding) 1 else 0;
        return coefficient * self.bitrate / self.sample_rate + padding;
    }

    fn samplesPerFrame(self: Header) u64 {
        return if (self.version == .mpeg1) 1152 else 576;
    }
};

/// kbps；下标 0 = free（不支持），15 = 非法。
const bitrates_mpeg1_layer3 = [_]u32{
    0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0,
};
const bitrates_mpeg2_layer3 = [_]u32{
    0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0,
};

const sample_rates_mpeg1 = [_]u32{ 44_100, 48_000, 32_000 };
const sample_rates_mpeg2 = [_]u32{ 22_050, 24_000, 16_000 };
const sample_rates_mpeg25 = [_]u32{ 11_025, 12_000, 8_000 };

/// 解析第一帧。`bytes` 是文件头窗口；`file_size` 用于核对截断与 CBR 估算。
pub fn parse(bytes: []const u8, file_size: u64) Error!Info {
    if (bytes.len < 4) return error.Truncated;
    const start = try skipId3(bytes);

    var offset = start;
    while (offset + 4 <= bytes.len) : (offset += 1) {
        if (bytes[offset] != 0xFF) continue;
        const header = parseHeader(bytes[offset..][0..4]) orelse continue;

        const frame_start: u64 = @intCast(offset);
        const frame_end = std.math.add(u64, frame_start, header.frameLength()) catch
            return error.Truncated;
        // 声明的第一帧都放不下 = 截断；不要拿半帧去算一个看似合理的时长。
        if (file_size < frame_end) return error.Truncated;

        const channel_count: u32 = if (header.mono) 1 else 2;
        if (try xingInfo(bytes, offset, header)) |from_xing| {
            return .{
                .duration_ms = from_xing,
                .estimated = false,
                .sample_rate = header.sample_rate,
                .channels = channel_count,
            };
        }

        // 没有 Xing/Info：CBR 估算。`frame_start` 就是 ID3v2 之后（若前面有垃圾
        // 则跳过垃圾后）的第一帧偏移，所以 (file_size - frame_start) 正好是
        // "音频字节数"（含帧头）。
        const audio_bytes = file_size - frame_start;
        const bits_total = std.math.mul(u64, audio_bytes, 8) catch return error.Truncated;
        const milliseconds = std.math.mul(u64, bits_total, 1000) catch return error.Truncated;
        return .{
            .duration_ms = milliseconds / header.bitrate,
            .estimated = true,
            .sample_rate = header.sample_rate,
            .channels = channel_count,
        };
    }
    return error.NotMp3;
}

/// 跳过 ID3v2（`ID3` + 2 字节版本 + 1 字节 flags + 4 字节 syncsafe 长度）。
/// 没有 ID3 时返回 0。footer 位只在 ID3v2.4 有效，它让标签尾多 10 字节。
fn skipId3(bytes: []const u8) Error!usize {
    if (bytes.len < 3) return error.Truncated;
    if (!std.mem.eql(u8, bytes[0..3], "ID3")) return 0;
    if (bytes.len < 10) return error.Truncated;

    var tag_size: usize = 0;
    for (bytes[6..10]) |byte| {
        // syncsafe：每字节只有低 7 位有效，最高位必须为 0。
        if (byte & 0x80 != 0) return error.BadId3;
        tag_size = (tag_size << 7) | byte;
    }
    var total = 10 + tag_size;
    if (bytes[3] == 4 and (bytes[5] & 0x10) != 0) total += 10;
    return total;
}

/// 解析 4 字节帧头；任何一位不合法都返回 null（调用方继续往后找同步）。
fn parseHeader(bytes: []const u8) ?Header {
    if (bytes.len < 4) return null;
    if (bytes[0] != 0xFF or (bytes[1] & 0xE0) != 0xE0) return null;

    const version_bits = (bytes[1] >> 3) & 0x3;
    const version: Version = switch (version_bits) {
        0 => .mpeg25,
        2 => .mpeg2,
        3 => .mpeg1,
        else => return null, // 01 = reserved
    };
    // 只做 Layer III（bits 01）。Layer I（11）/ II（10）的帧长公式不同。
    if (((bytes[1] >> 1) & 0x3) != 1) return null;

    const bitrate_index = (bytes[2] >> 4) & 0xF;
    if (bitrate_index == 0 or bitrate_index == 15) return null;
    const sample_rate_index = (bytes[2] >> 2) & 0x3;
    if (sample_rate_index == 3) return null;

    const bitrate_kbps = switch (version) {
        .mpeg1 => bitrates_mpeg1_layer3[bitrate_index],
        else => bitrates_mpeg2_layer3[bitrate_index],
    };
    const sample_rate = switch (version) {
        .mpeg1 => sample_rates_mpeg1[sample_rate_index],
        .mpeg2 => sample_rates_mpeg2[sample_rate_index],
        .mpeg25 => sample_rates_mpeg25[sample_rate_index],
    };

    return .{
        .version = version,
        .sample_rate = sample_rate,
        .bitrate = bitrate_kbps * 1000,
        .padding = (bytes[2] & 0x2) != 0,
        .mono = ((bytes[3] >> 6) & 0x3) == 3,
        .has_crc = (bytes[1] & 0x1) == 0,
    };
}

/// 读 Xing/Info 的 frames。返回 null = 没有可用的帧数字段（继续走 CBR 估算）。
fn xingInfo(bytes: []const u8, frame_offset: usize, header: Header) Error!?u64 {
    const side_info: usize = switch (header.version) {
        .mpeg1 => if (header.mono) 17 else 32,
        else => if (header.mono) 9 else 17,
    };
    const crc: usize = if (header.has_crc) 2 else 0;
    const xing_at = frame_offset + 4 + crc + side_info;
    if (xing_at + 4 > bytes.len) return null;

    if (!std.mem.eql(u8, bytes[xing_at..][0..4], "Xing") and
        !std.mem.eql(u8, bytes[xing_at..][0..4], "Info"))
    {
        return null;
    }
    if (xing_at + 12 > bytes.len) return error.Truncated;

    const flags = readU32Be(bytes, xing_at + 4);
    if ((flags & 0x1) == 0) return null; // 没有 frames 字段
    const frames = readU32Be(bytes, xing_at + 8);
    if (frames == 0) return null;

    const total_samples = @as(u64, frames) * header.samplesPerFrame();
    const scaled = std.math.mul(u64, total_samples, 1000) catch return error.Truncated;
    return scaled / header.sample_rate;
}

fn readU32Be(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .big);
}

// ---------------------------------------------------------------------------
// 测试：纯内存字节，不碰磁盘
// ---------------------------------------------------------------------------

const testing = std.testing;

/// 在 `buffer[offset..]` 写一个 Layer III 帧头。
fn putHeader(buffer: []u8, offset: usize, b1: u8, b2: u8, b3: u8) void {
    buffer[offset] = 0xFF;
    buffer[offset + 1] = b1;
    buffer[offset + 2] = b2;
    buffer[offset + 3] = b3;
}

/// 写 Xing/Info：magic + flags(1) + frames，全部大端。
fn putXing(buffer: []u8, offset: usize, magic: []const u8, frames: u32) void {
    @memcpy(buffer[offset..][0..4], magic);
    std.mem.writeInt(u32, buffer[offset + 4 ..][0..4], 1, .big);
    std.mem.writeInt(u32, buffer[offset + 8 ..][0..4], frames, .big);
}

test "Xing：MPEG-1 双声道，100 帧 = 2612 ms，estimated = false" {
    var bytes: [1024]u8 = @splat(0);
    putHeader(&bytes, 0, 0xFB, 0x90, 0x00); // MPEG-1 L3 / 128 kbps / 44.1 kHz / stereo
    putXing(&bytes, 4 + 32, "Xing", 100);

    const info = try parse(&bytes, bytes.len);
    try testing.expectEqual(@as(u64, 2612), info.duration_ms);
    try testing.expect(!info.estimated);
    try testing.expectEqual(@as(u32, 44_100), info.sample_rate);
    try testing.expectEqual(@as(u32, 2), info.channels);
    try testing.expectEqual(@as(u16, 16), info.bits);
}

test "Info（CBR 也写了帧数）同样优先于文件大小估算" {
    var bytes: [1024]u8 = @splat(0);
    putHeader(&bytes, 0, 0xFB, 0x90, 0xC0); // stereo -> mono
    putXing(&bytes, 4 + 17, "Info", 116); // 单声道 side info = 17

    const info = try parse(&bytes, 1024);
    try testing.expectEqual(@as(u64, 3030), info.duration_ms);
    try testing.expect(!info.estimated);
    try testing.expectEqual(@as(u32, 1), info.channels);
}

test "无 Xing：按（文件大小 - ID3 字节）/ 比特率估算，estimated = true" {
    // 16000 字节 @ 128 kbps = 1.000 秒。
    var bytes: [16_000]u8 = @splat(0);
    putHeader(&bytes, 0, 0xFB, 0x90, 0x00);

    const info = try parse(&bytes, bytes.len);
    try testing.expectEqual(@as(u64, 1000), info.duration_ms);
    try testing.expect(info.estimated);
}

test "ID3v2 跳过：tag 长度 + footer 位都算进去，估算只看音频字节" {
    // 10 字节 ID3 头 + 20 字节标签 = 30 字节，第一帧从 30 开始。
    var bytes: [16_000]u8 = @splat(0);
    @memcpy(bytes[0..3], "ID3");
    bytes[3] = 4;
    bytes[6..10].* = .{ 0, 0, 0, 20 };
    putHeader(&bytes, 30, 0xFB, 0x90, 0x00);

    // 文件 16030 字节，音频 = 16000 字节 -> 1000 ms。
    const without_footer = try parse(&bytes, 16_030);
    try testing.expectEqual(@as(u64, 1000), without_footer.duration_ms);
    try testing.expect(without_footer.estimated);

    // v2.4 footer 位：标签后再多 10 字节，第一帧从 40 开始。
    var footer_bytes: [16_000]u8 = @splat(0);
    @memcpy(footer_bytes[0..3], "ID3");
    footer_bytes[3] = 4;
    footer_bytes[5] = 0x10;
    footer_bytes[6..10].* = .{ 0, 0, 0, 20 };
    putHeader(&footer_bytes, 40, 0xFB, 0x90, 0x00);

    const with_footer = try parse(&footer_bytes, 16_040);
    try testing.expectEqual(@as(u64, 1000), with_footer.duration_ms);
}

test "MPEG-2 / 2.5：每帧 576 个样本，side info 更短" {
    // MPEG-2 L3 / 64 kbps / 22.05 kHz / mono：side info = 9，Xing 在 13。
    var bytes: [1024]u8 = @splat(0);
    putHeader(&bytes, 0, 0xF3, 0x80, 0xC0);
    putXing(&bytes, 13, "Xing", 100);

    const info = try parse(&bytes, bytes.len);
    try testing.expectEqual(@as(u64, 2612), info.duration_ms); // 100 * 576 / 22050
    try testing.expect(!info.estimated);
    try testing.expectEqual(@as(u32, 22_050), info.sample_rate);
    try testing.expectEqual(@as(u32, 1), info.channels);

    // MPEG-2.5 / 8 kbps / 8 kHz：版本 bits 00、码率索引 1、采样率索引 2。
    var low: [1024]u8 = @splat(0);
    putHeader(&low, 0, 0xE3, 0x18, 0xC0);
    putXing(&low, 13, "Xing", 100);
    const mpeg25 = try parse(&low, low.len);
    try testing.expectEqual(@as(u64, 7200), mpeg25.duration_ms); // 100 * 576 / 8000
    try testing.expectEqual(@as(u32, 8_000), mpeg25.sample_rate);
}

test "截断 / 坏 ID3 / 非 MP3 / 不支持的层：具名错误" {
    try testing.expectError(error.Truncated, parse("", 0));
    try testing.expectError(error.Truncated, parse("\xFF\xFB\x90", 3));

    // 帧头合法，但文件比第一帧短。
    var tiny: [4]u8 = undefined;
    putHeader(&tiny, 0, 0xFB, 0x90, 0x00);
    try testing.expectError(error.Truncated, parse(&tiny, 4));

    // ID3 的 syncsafe 长度最高位非法。
    var bad_id3: [64]u8 = @splat(0);
    @memcpy(bad_id3[0..3], "ID3");
    bad_id3[3] = 4;
    bad_id3[6] = 0x80;
    try testing.expectError(error.BadId3, parse(&bad_id3, bad_id3.len));

    // Layer II（bits 10）不支持。
    var layer2: [1024]u8 = @splat(0);
    layer2[0] = 0xFF;
    layer2[1] = 0xFD;
    try testing.expectError(error.NotMp3, parse(&layer2, layer2.len));

    // free bitrate（索引 0）不支持。
    var free: [1024]u8 = @splat(0);
    free[0] = 0xFF;
    free[1] = 0xFB;
    free[2] = 0x00;
    free[3] = 0x00;
    try testing.expectError(error.NotMp3, parse(&free, free.len));

    // 文件头里出现 Xing，但 frames 字段被窗口截断。
    var cut: [40]u8 = @splat(0);
    putHeader(&cut, 0, 0xFB, 0x90, 0x00);
    @memcpy(cut[36..40], "Xing");
    try testing.expectError(error.Truncated, parse(&cut, 417));
}

test "帧头前有垃圾：扫描到第一个有效同步" {
    var bytes: [1024]u8 = @splat(0);
    bytes[5] = 0xFF; // 假同步：下一字节不是 0xE0 掩码
    bytes[6] = 0x00;
    putHeader(&bytes, 20, 0xFB, 0x90, 0x00);
    putXing(&bytes, 20 + 36, "Xing", 10);

    const info = try parse(&bytes, 1024);
    try testing.expectEqual(@as(u64, 261), info.duration_ms); // 10 * 1152 / 44100
    try testing.expect(!info.estimated);
}
