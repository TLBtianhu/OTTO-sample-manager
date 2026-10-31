//! WAV（RIFF/WAVE）**头部**解析：只读块头与 `fmt `，不碰 `data` 的负载。
//!
//! 为什么单独一个文件：解析一份、两处使用——
//!   * `zig/app/src/audio/coarse.zig` 的图标粗采样只读头部 + 32 个等距窗口；
//!   * `zig/ports/src/probe.zig` 只读前 64 KiB 取 L1 元数据（时长/采样率/声道）。
//!
//! **整段解码不在这里**：WAV/FLAC/MP3/AIFF 都交给 vendor 的 zig-audio
//! （`zig/app/src/audio/decode.zig`），app 侧已经没有 WAV 解码器。本文件只服务
//! "不读整段 PCM"的头部读取，所以**不需要**支持 ADPCM / G.711 的负载布局——遇到
//! 这些编码返回 `UnsupportedFormat`，由调用方决定是谢绝还是让 Shell 兜底。
//!
//! 复制两份块扫描逻辑迟早会漂移（奇数块 padding、未知块、`fmt ` 在 `data` 之后、
//! EXTENSIBLE 子格式），所以这里定义唯一的规则集，两处都从这里拿。
//!
//! ## 与完整解码的差别：`data` 的负载可以不在这段字节里
//!
//! probe 只读文件头，`data` 块声明的长度通常远大于窗口。因此 `parse` 遇到
//! `data` 时**记下偏移与声明长度就停**，不要求负载存在；调用方自己决定：
//!   * 图标粗采样用 `stat` 的文件大小核对，声明大于实有就当作截断；
//!   * probe 用 `stat` 的文件大小做同样的核对，声明大于实有就返回 null。
//!
//! 其余块（`fmt ` 与未知块）必须完整落在给定字节里，否则无法可靠地继续找
//! `data`，返回 `Truncated`——不猜。
//!
//! 支持面：PCM 8/16/24/32、IEEE float 32、WAVE_FORMAT_EXTENSIBLE 里的这两种子格式；
//! 别的（ADPCM / A-law / µ-law / float64…）返回 `UnsupportedFormat`。本文件是
//! **纯字节解析**：不读文件、不分配、不 import 任何平台模块。

const std = @import("std");

pub const Error = error{
    Truncated,
    NotRiff,
    NotWave,
    MissingFmt,
    MissingData,
    DataBeforeFmt,
    UnsupportedFormat,
    BadFmt,
};

pub const SampleFormat = enum { pcm, float };

pub const format_pcm: u16 = 1;
pub const format_float: u16 = 3;
pub const format_extensible: u16 = 0xFFFE;

/// KSDATAFORMAT_SUBTYPE_PCM / _IEEE_FLOAT 的磁盘字节序（GUID 的 Data1..Data4
/// 按小端写出）。`fmt ` 的 SubFormat 字段就是这 16 个字节。
pub const guid_pcm = [16]u8{ 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71 };
pub const guid_float = [16]u8{ 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71 };

pub const Header = struct {
    sample_rate: u32,
    channels: u16,
    bits: u16,
    format: SampleFormat,
    /// `data` 负载在整份字节里的起点（块头之后）。
    data_offset: usize,
    /// `data` 块声明的负载长度（可能大于给定字节的长度）。
    data_size: u64,

    /// 一帧的字节数。0 = 头部自相矛盾（调用方应当拒绝）。
    pub fn frameBytes(self: Header) usize {
        return @as(usize, self.channels) * @as(usize, self.bits / 8);
    }
};

const Fmt = struct {
    channels: u16,
    sample_rate: u32,
    bits: u16,
    format: SampleFormat,
};

/// 解析 RIFF/WAVE 头部。`bytes` 可以只有文件的前一小段（见文件头）。
pub fn parse(bytes: []const u8) Error!Header {
    if (bytes.len < 12) return error.Truncated;
    if (!std.mem.eql(u8, bytes[0..4], "RIFF")) return error.NotRiff;
    if (!std.mem.eql(u8, bytes[8..12], "WAVE")) return error.NotWave;

    var info: ?Fmt = null;
    var data_offset: ?usize = null;
    var data_size: u64 = 0;
    var offset: usize = 12;

    while (offset + 8 <= bytes.len) {
        const id = bytes[offset..][0..4];
        const declared = readU32(bytes, offset + 4);
        const start = offset + 8;
        const end = std.math.add(usize, start, declared) catch return error.Truncated;

        if (std.mem.eql(u8, id, "fmt ")) {
            // 第一个 fmt 说了算；重复的 fmt 是坏文件，忽略后一个即可。
            if (end > bytes.len) return error.Truncated;
            if (info == null) info = try parseFmt(bytes[start..end]);
        } else if (std.mem.eql(u8, id, "data")) {
            if (info == null) return error.DataBeforeFmt;
            // 只记位置，不要求负载在窗口里：probe 只有前 64 KiB。
            data_offset = start;
            data_size = declared;
            break;
        } else {
            // 未知块（LIST / fact / JUNK…）跳过；但要继续找 data 就必须完整看见它。
            if (end > bytes.len) return error.Truncated;
        }
        // RIFF 规定奇数长度的块后面补 1 字节 padding。
        offset = end + (declared & 1);
    }

    const fmt = info orelse return error.MissingFmt;
    const data_start = data_offset orelse return error.MissingData;
    return .{
        .sample_rate = fmt.sample_rate,
        .channels = fmt.channels,
        .bits = fmt.bits,
        .format = fmt.format,
        .data_offset = data_start,
        .data_size = data_size,
    };
}

fn parseFmt(chunk: []const u8) Error!Fmt {
    if (chunk.len < 16) return error.BadFmt;

    const tag = readU16(chunk, 0);
    const channels = readU16(chunk, 2);
    const sample_rate = readU32(chunk, 4);
    const bits = readU16(chunk, 14);
    if (channels == 0 or sample_rate == 0) return error.BadFmt;

    var format: SampleFormat = undefined;
    if (tag == format_extensible) {
        if (chunk.len < 40) return error.BadFmt;
        const cb_size = readU16(chunk, 16);
        if (cb_size < 22) return error.BadFmt;
        const sub = chunk[24..40];
        if (std.mem.eql(u8, sub, &guid_pcm)) {
            format = .pcm;
        } else if (std.mem.eql(u8, sub, &guid_float)) {
            format = .float;
        } else {
            return error.UnsupportedFormat;
        }
    } else if (tag == format_pcm) {
        format = .pcm;
    } else if (tag == format_float) {
        format = .float;
    } else {
        return error.UnsupportedFormat;
    }

    switch (format) {
        .pcm => switch (bits) {
            8, 16, 24, 32 => {},
            else => return error.UnsupportedFormat,
        },
        .float => if (bits != 32) return error.UnsupportedFormat,
    }

    return .{
        .channels = channels,
        .sample_rate = sample_rate,
        .bits = bits,
        .format = format,
    };
}

fn readU16(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}

fn readU32(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

// ---------------------------------------------------------------------------
// 测试：纯内存字节，不碰磁盘
// ---------------------------------------------------------------------------

const testing = std.testing;

fn build(
    buffer: []u8,
    write_fmt: bool,
    data_size: u32,
    available_data: usize,
) []u8 {
    var length: usize = 0;
    @memcpy(buffer[0..4], "RIFF");
    std.mem.writeInt(u32, buffer[4..8], 0, .little);
    @memcpy(buffer[8..12], "WAVE");
    length = 12;

    if (write_fmt) {
        @memcpy(buffer[length..][0..4], "fmt ");
        std.mem.writeInt(u32, buffer[length + 4 ..][0..4], 16, .little);
        const chunk = buffer[length + 8 ..][0..16];
        std.mem.writeInt(u16, chunk[0..2], format_pcm, .little);
        std.mem.writeInt(u16, chunk[2..4], 1, .little);
        std.mem.writeInt(u32, chunk[4..8], 22_050, .little);
        std.mem.writeInt(u32, chunk[8..12], 44_100, .little);
        std.mem.writeInt(u16, chunk[12..14], 2, .little);
        std.mem.writeInt(u16, chunk[14..16], 16, .little);
        length += 24;
    }

    @memcpy(buffer[length..][0..4], "data");
    std.mem.writeInt(u32, buffer[length + 4 ..][0..4], data_size, .little);
    length += 8;
    const copy_len = @min(available_data, buffer.len - length);
    @memset(buffer[length..][0..copy_len], 0);
    length += copy_len;

    std.mem.writeInt(u32, buffer[4..8], @intCast(length - 8), .little);
    return buffer[0..length];
}

test "完整头：fmt + data 声明长度，负载可以不在窗口里" {
    var bytes: [64]u8 = undefined;
    // 声明 4 秒，但只给 40 字节负载（模拟 probe 的 64 KiB 窗口）。
    const file = build(&bytes, true, 22_050 * 2 * 4, 40);
    const header = try parse(file);

    try testing.expectEqual(@as(u32, 22_050), header.sample_rate);
    try testing.expectEqual(@as(u16, 1), header.channels);
    try testing.expectEqual(@as(u16, 16), header.bits);
    try testing.expectEqual(SampleFormat.pcm, header.format);
    try testing.expectEqual(@as(usize, 44), header.data_offset);
    try testing.expectEqual(@as(u64, 22_050 * 2 * 4), header.data_size);
    try testing.expectEqual(@as(usize, 2), header.frameBytes());
}

test "未知块与奇数 padding：data 仍能找到" {
    var bytes: [128]u8 = undefined;
    var length: usize = 0;
    @memcpy(bytes[0..4], "RIFF");
    std.mem.writeInt(u32, bytes[4..8], 0, .little);
    @memcpy(bytes[8..12], "WAVE");
    length = 12;

    // JUNK 3 字节 + 1 字节 padding
    @memcpy(bytes[length..][0..4], "JUNK");
    std.mem.writeInt(u32, bytes[length + 4 ..][0..4], 3, .little);
    @memcpy(bytes[length + 8 ..][0..3], "abc");
    bytes[length + 11] = 0;
    length += 12;

    @memcpy(bytes[length..][0..4], "fmt ");
    std.mem.writeInt(u32, bytes[length + 4 ..][0..4], 16, .little);
    const chunk = bytes[length + 8 ..][0..16];
    std.mem.writeInt(u16, chunk[0..2], format_pcm, .little);
    std.mem.writeInt(u16, chunk[2..4], 2, .little);
    std.mem.writeInt(u32, chunk[4..8], 48_000, .little);
    std.mem.writeInt(u32, chunk[8..12], 192_000, .little);
    std.mem.writeInt(u16, chunk[12..14], 4, .little);
    std.mem.writeInt(u16, chunk[14..16], 16, .little);
    length += 24;

    @memcpy(bytes[length..][0..4], "data");
    std.mem.writeInt(u32, bytes[length + 4 ..][0..4], 8, .little);
    length += 8;
    @memset(bytes[length..][0..8], 0);
    length += 8;
    std.mem.writeInt(u32, bytes[4..8], @intCast(length - 8), .little);

    const header = try parse(bytes[0..length]);
    try testing.expectEqual(@as(u32, 48_000), header.sample_rate);
    try testing.expectEqual(@as(u16, 2), header.channels);
    try testing.expectEqual(@as(u64, 8), header.data_size);
}

test "截断 / 非 WAV / data 在 fmt 前：具名错误" {
    try testing.expectError(error.Truncated, parse("RIFF"));
    try testing.expectError(error.NotRiff, parse("RIFX\x00\x00\x00\x00WAVEfmt "));
    try testing.expectError(error.NotWave, parse("RIFF\x00\x00\x00\x00AVI "));

    var bytes: [64]u8 = undefined;
    // 没有 fmt 只有 data -> DataBeforeFmt
    var file = build(&bytes, false, 2, 2);
    try testing.expectError(error.DataBeforeFmt, parse(file));

    // fmt 在窗口里被截断
    file = build(&bytes, true, 4, 0);
    try testing.expectError(error.Truncated, parse(file[0..20]));

    // 只有 fmt 没有 data -> MissingData
    var only_fmt: [64]u8 = undefined;
    const built = build(&only_fmt, true, 0, 0);
    try testing.expectError(error.MissingData, parse(built[0 .. built.len - 8]));
}

test "EXTENSIBLE：认 PCM 子格式；A-law / 12 位 PCM 不支持" {
    var bytes: [128]u8 = undefined;
    var length: usize = 0;
    @memcpy(bytes[0..4], "RIFF");
    std.mem.writeInt(u32, bytes[4..8], 0, .little);
    @memcpy(bytes[8..12], "WAVE");
    length = 12;

    @memcpy(bytes[length..][0..4], "fmt ");
    std.mem.writeInt(u32, bytes[length + 4 ..][0..4], 40, .little);
    const chunk = bytes[length + 8 ..][0..40];
    @memset(chunk, 0);
    std.mem.writeInt(u16, chunk[0..2], format_extensible, .little);
    std.mem.writeInt(u16, chunk[2..4], 1, .little);
    std.mem.writeInt(u32, chunk[4..8], 48_000, .little);
    std.mem.writeInt(u16, chunk[12..14], 4, .little);
    std.mem.writeInt(u16, chunk[14..16], 32, .little);
    std.mem.writeInt(u16, chunk[16..18], 22, .little);
    std.mem.writeInt(u16, chunk[18..20], 32, .little);
    @memcpy(chunk[24..40], &guid_pcm);
    length += 48;

    @memcpy(bytes[length..][0..4], "data");
    std.mem.writeInt(u32, bytes[length + 4 ..][0..4], 8, .little);
    length += 8;
    @memset(bytes[length..][0..8], 0);
    length += 8;
    std.mem.writeInt(u32, bytes[4..8], @intCast(length - 8), .little);

    const header = try parse(bytes[0..length]);
    try testing.expectEqual(@as(u16, 32), header.bits);
    try testing.expectEqual(SampleFormat.pcm, header.format);

    // A-law（0x0006）不支持。
    var plain: [64]u8 = undefined;
    const alaw = build(&plain, true, 2, 2);
    std.mem.writeInt(u16, plain[20..22], 6, .little);
    try testing.expectError(error.UnsupportedFormat, parse(alaw));
}
