//! WAV（RIFF/WAVE）解码：把文件字节变成"可以直接交给 WASAPI 的交错 PCM"。
//!
//! 自己写，不引第三方：M1 只需要 PCM 与 IEEE float，格式面很小；真正麻烦的是
//! **块的边界**（奇数长度 padding、未知块、`data` 在 `fmt ` 之前），这些必须在
//! 解析层处理干净，而不是指望后面的播放器。
//!
//! 支持面（报告里也要写）：
//!   * RIFF/WAVE，`fmt ` + `data`；未知块跳过，**奇数长度块跳过 1 字节 padding**；
//!   * `fmt ` 在 `data` 之后 → `error.DataBeforeFmt`（少见，但不能猜）；
//!   * PCM 8/16/24/32 位（8 位按 WAV 约定是无符号）、IEEE float 32 位；
//!   * WAVE_FORMAT_EXTENSIBLE（`0xFFFE`）里的 PCM / IEEE_FLOAT 子格式；
//!   * 单声道 / 立体声原样保留；**多于 2 声道下混到立体声**（偶数下标 → L，
//!     奇数下标 → R，各自简单平均）。不做采样率转换；
//!   * 不支持：ADPCM / A-law / μ-law / float64、压缩格式、多 `data` 合并、
//!     大于 `file.max_file_bytes` 的文件（那是 provider 的事）。
//!
//! 返回的 `Wav.pcm` 由本模块用调用方的 allocator 分配，`Wav.deinit` 释放；它已经
//! 是交错、`channels`（1 或 2）声道、`bits` 位、`sample_rate` 的源格式，播放器
//! **不再转换**，只把它交给 `IAudioClient::Initialize`（共享模式由系统混音）。

const std = @import("std");
const wav_header = @import("otto_wav_header");

/// 头部错误来自共享的 `otto_wav_header`（probe 也用同一份解析）；本文件只加
/// 解码特有的两个：`OutOfMemory` 与 `Empty`（0 帧）。
pub const Error = wav_header.Error || error{
    OutOfMemory,
    Empty,
};

pub const SampleFormat = wav_header.SampleFormat;

pub const Wav = struct {
    /// 交错 PCM；`channels` 声道、`bits` 位、`sample_rate` Hz。归本结构所有。
    pcm: []u8,
    sample_rate: u32,
    channels: u16,
    bits: u16,
    format: SampleFormat,
    frames: u64,
    duration_ms: u64,

    pub fn byteLen(self: Wav) usize {
        return self.pcm.len;
    }

    /// 释放 PCM。每个 Wav 只调一次；之后 `pcm` 为空。
    pub fn deinit(self: *Wav, allocator: std.mem.Allocator) void {
        if (self.pcm.len != 0) allocator.free(self.pcm);
        self.pcm = &.{};
        self.frames = 0;
        self.duration_ms = 0;
    }
};

const format_pcm = wav_header.format_pcm;
const format_float = wav_header.format_float;
const format_extensible = wav_header.format_extensible;

/// KSDATAFORMAT_SUBTYPE_PCM 的磁盘字节序；测试里的 `fmt ` 构造器要用。
const guid_pcm = wav_header.guid_pcm;

/// 解析一个完整的 WAV 文件。`bytes` 只在调用期间借用；输出 PCM 新分配。
///
/// 块扫描与 `fmt ` 规则在 `otto_wav_header.parse`（与 `--import` 的 probe 共用
/// 同一份实现）；这里只负责取 `data` 负载、换算帧数并（多声道时）下混。
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) Error!Wav {
    const header = try wav_header.parse(bytes);

    const frame_bytes: usize = header.frameBytes();
    if (frame_bytes == 0) return error.BadFmt;

    // 解码拿得到整份字节，所以 data 的声明长度必须真的在文件里；
    // 超出的半帧残片按整帧截掉（见文件头）。
    const declared: usize = std.math.cast(usize, header.data_size) orelse return error.Truncated;
    const end = std.math.add(usize, header.data_offset, declared) catch return error.Truncated;
    if (end > bytes.len) return error.Truncated;

    const payload = bytes[header.data_offset..end];
    const frames = payload.len / frame_bytes;
    if (frames == 0) return error.Empty;
    const used = frames * frame_bytes;

    // 单声道 / 立体声原样保留（不做无谓的 float 往返，声音逐位不变）；
    // 多于 2 声道才下混，且下混后统一成 2 声道。
    const fmt: Fmt = .{
        .channels = header.channels,
        .bits = header.bits,
        .format = header.format,
    };
    const pcm = if (fmt.channels <= 2)
        try allocator.dupe(u8, payload[0..used])
    else
        try downmix(allocator, payload[0..used], fmt);

    return .{
        .pcm = pcm,
        .sample_rate = header.sample_rate,
        .channels = if (fmt.channels <= 2) fmt.channels else 2,
        .bits = fmt.bits,
        .format = fmt.format,
        .frames = frames,
        // 毫秒向下取整：1 帧 @ 44.1 kHz 是 0 ms，不冒充 1 ms。
        .duration_ms = @as(u64, @intCast(frames)) * 1000 / header.sample_rate,
    };
}

/// 下混只需要三个字段；采样率用不到。
const Fmt = struct {
    channels: u16,
    bits: u16,
    format: SampleFormat,
};


/// 多声道 → 立体声：偶数下标进左、奇数下标进右，各自平均。5.1 的 LFE 也参与
/// 平均（M1 不装滤波器）；某些声道的缺失用 0 补齐，不做相位处理。
fn downmix(allocator: std.mem.Allocator, payload: []const u8, fmt: Fmt) Error![]u8 {
    const bytes_per_sample: usize = fmt.bits / 8;
    const src_frame = @as(usize, fmt.channels) * bytes_per_sample;
    const dst_frame = 2 * bytes_per_sample;
    const frames = payload.len / src_frame;
    const out = try allocator.alloc(u8, frames * dst_frame);
    errdefer allocator.free(out);

    var frame: usize = 0;
    while (frame < frames) : (frame += 1) {
        var sum = [2]f64{ 0, 0 };
        var count = [2]u32{ 0, 0 };
        var channel: usize = 0;
        while (channel < fmt.channels) : (channel += 1) {
            const offset = frame * src_frame + channel * bytes_per_sample;
            const value = readSample(payload, offset, fmt.bits, fmt.format);
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
            writeSample(out, frame * dst_frame + side * bytes_per_sample, fmt.bits, fmt.format, value);
        }
    }
    return out;
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
// 测试：全部在内存里造 WAV，不碰磁盘
// ---------------------------------------------------------------------------

const testing = std.testing;

/// 造一个 RIFF/WAVE 字节流。`finish` 回填 RIFF 长度并把所有权交出去。
const Builder = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,

    fn init(allocator: std.mem.Allocator) !Builder {
        var bytes: std.ArrayList(u8) = .empty;
        errdefer bytes.deinit(allocator);
        try bytes.appendSlice(allocator, "RIFF");
        try bytes.appendNTimes(allocator, 0, 4);
        try bytes.appendSlice(allocator, "WAVE");
        return .{ .allocator = allocator, .bytes = bytes };
    }

    fn addChunk(self: *Builder, id: []const u8, payload: []const u8) !void {
        std.debug.assert(id.len == 4);
        try self.bytes.appendSlice(self.allocator, id);
        var size: [4]u8 = undefined;
        std.mem.writeInt(u32, &size, @intCast(payload.len), .little);
        try self.bytes.appendSlice(self.allocator, &size);
        try self.bytes.appendSlice(self.allocator, payload);
        if (payload.len % 2 == 1) try self.bytes.append(self.allocator, 0);
    }

    fn finish(self: *Builder) ![]u8 {
        const riff_size: u32 = @intCast(self.bytes.items.len - 8);
        std.mem.writeInt(u32, self.bytes.items[4..8], riff_size, .little);
        return self.bytes.toOwnedSlice(self.allocator);
    }

    fn deinit(self: *Builder) void {
        self.bytes.deinit(self.allocator);
    }
};

fn fmtPayload(
    buffer: *[40]u8,
    tag: u16,
    channels: u16,
    sample_rate: u32,
    bits: u16,
) []const u8 {
    @memset(buffer, 0);
    const bytes_per_sample: u16 = bits / 8;
    const block_align: u16 = channels * bytes_per_sample;
    std.mem.writeInt(u16, buffer[0..2], tag, .little);
    std.mem.writeInt(u16, buffer[2..4], channels, .little);
    std.mem.writeInt(u32, buffer[4..8], sample_rate, .little);
    std.mem.writeInt(u32, buffer[8..12], sample_rate * @as(u32, block_align), .little);
    std.mem.writeInt(u16, buffer[12..14], block_align, .little);
    std.mem.writeInt(u16, buffer[14..16], bits, .little);
    if (tag == format_extensible) {
        std.mem.writeInt(u16, buffer[16..18], 22, .little);
        std.mem.writeInt(u16, buffer[18..20], bits, .little);
        std.mem.writeInt(u32, buffer[20..24], if (channels == 1) 0x4 else 0x3, .little);
        @memcpy(buffer[24..40], &guid_pcm);
        return buffer[0..40];
    }
    return buffer[0..16];
}

fn buildWav(
    allocator: std.mem.Allocator,
    tag: u16,
    channels: u16,
    sample_rate: u32,
    bits: u16,
    pcm: []const u8,
) ![]u8 {
    var builder = try Builder.init(allocator);
    defer builder.deinit();
    var fmt_buffer: [40]u8 = undefined;
    try builder.addChunk("fmt ", fmtPayload(&fmt_buffer, tag, channels, sample_rate, bits));
    try builder.addChunk("data", pcm);
    return builder.finish();
}

test "16 位单声道：头字段、PCM 字节、时长换算" {
    const pcm = [_]u8{ 0x00, 0x00, 0xFF, 0x7F, 0x00, 0x80, 0x00, 0x00 };
    const file = try buildWav(testing.allocator, format_pcm, 1, 8000, 16, &pcm);
    defer testing.allocator.free(file);

    var wav = try decode(testing.allocator, file);
    defer wav.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 8000), wav.sample_rate);
    try testing.expectEqual(@as(u16, 1), wav.channels);
    try testing.expectEqual(@as(u16, 16), wav.bits);
    try testing.expectEqual(SampleFormat.pcm, wav.format);
    try testing.expectEqual(@as(u64, 4), wav.frames);
    try testing.expectEqual(@as(u64, 0), wav.duration_ms); // 4 帧 @8 kHz = 0.5 ms
    try testing.expectEqualSlices(u8, &pcm, wav.pcm);
}

test "时长换算：48000 Hz / 24000 帧 = 500 ms（向下取整）" {
    var pcm: [48_000]u8 = undefined;
    @memset(&pcm, 0);
    const file = try buildWav(testing.allocator, format_pcm, 1, 48_000, 16, &pcm);
    defer testing.allocator.free(file);

    var wav = try decode(testing.allocator, file);
    defer wav.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 24_000), wav.frames);
    try testing.expectEqual(@as(u64, 500), wav.duration_ms);
}

test "24 位 PCM：每帧 3 字节，字节原样保留" {
    const pcm = [_]u8{
        0x00, 0x00, 0x00, // 0
        0x01, 0x00, 0x80, // -8388607
        0xFF, 0xFF, 0x7F, //  8388607
    };
    const file = try buildWav(testing.allocator, format_pcm, 1, 44_100, 24, &pcm);
    defer testing.allocator.free(file);

    var wav = try decode(testing.allocator, file);
    defer wav.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 24), wav.bits);
    try testing.expectEqual(@as(u64, 3), wav.frames);
    try testing.expectEqualSlices(u8, &pcm, wav.pcm);
}

test "float32 立体声：不转换，逐字节保留" {
    const samples = [_]f32{ 0.0, 0.5, -0.5, 1.0 };
    const pcm = std.mem.sliceAsBytes(&samples);
    const file = try buildWav(testing.allocator, format_float, 2, 96_000, 32, pcm);
    defer testing.allocator.free(file);

    var wav = try decode(testing.allocator, file);
    defer wav.deinit(testing.allocator);
    try testing.expectEqual(SampleFormat.float, wav.format);
    try testing.expectEqual(@as(u16, 2), wav.channels);
    try testing.expectEqual(@as(u64, 2), wav.frames);
    try testing.expectEqualSlices(u8, pcm, wav.pcm);
}

test "WAVE_FORMAT_EXTENSIBLE：认 PCM 子格式，按容器位深播放" {
    var builder = try Builder.init(testing.allocator);
    defer builder.deinit();
    var fmt_buffer: [40]u8 = undefined;
    // 32 位容器、24 位有效位（真实世界很常见的 24-in-32）。
    const fmt = fmtPayload(&fmt_buffer, format_extensible, 1, 48_000, 32);
    std.mem.writeInt(u16, fmt_buffer[18..20], 24, .little);
    try builder.addChunk("fmt ", fmt);
    try builder.addChunk("data", &[_]u8{ 1, 2, 3, 4 });
    const file = try builder.finish();
    defer testing.allocator.free(file);

    var wav = try decode(testing.allocator, file);
    defer wav.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 32), wav.bits);
    try testing.expectEqual(SampleFormat.pcm, wav.format);
}

test "奇数长度的未知块：跳过 padding，后面的 data 仍能找到" {
    var builder = try Builder.init(testing.allocator);
    defer builder.deinit();
    var fmt_buffer: [40]u8 = undefined;
    try builder.addChunk("fmt ", fmtPayload(&fmt_buffer, format_pcm, 1, 8000, 16));
    // 3 字节的未知块：后面必须补 1 字节 padding，否则 data 的 id 会读歪。
    try builder.addChunk("JUNK", &[_]u8{ 0xAA, 0xBB, 0xCC });
    try builder.addChunk("data", &[_]u8{ 0x01, 0x00, 0x02, 0x00 });
    const file = try builder.finish();
    defer testing.allocator.free(file);

    var wav = try decode(testing.allocator, file);
    defer wav.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 2), wav.frames);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x00, 0x02, 0x00 }, wav.pcm);
}

test "偶数长度的未知块（LIST）直接跳过" {
    var builder = try Builder.init(testing.allocator);
    defer builder.deinit();
    var fmt_buffer: [40]u8 = undefined;
    try builder.addChunk("LIST", "INFOxxxxxxxx");
    try builder.addChunk("fmt ", fmtPayload(&fmt_buffer, format_pcm, 1, 8000, 16));
    try builder.addChunk("data", &[_]u8{ 0x00, 0x00 });
    const file = try builder.finish();
    defer testing.allocator.free(file);

    var wav = try decode(testing.allocator, file);
    defer wav.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 1), wav.frames);
}

test "缺 fmt：error.MissingFmt" {
    var builder = try Builder.init(testing.allocator);
    defer builder.deinit();
    // 只有未知块：既没有 fmt 也没有 data，但绝不能误报成 DataBeforeFmt。
    try builder.addChunk("JUNK", &[_]u8{ 0x00, 0x00 });
    const file = try builder.finish();
    defer testing.allocator.free(file);
    try testing.expectError(error.MissingFmt, decode(testing.allocator, file));
}

test "缺 data：error.MissingData" {
    var builder = try Builder.init(testing.allocator);
    defer builder.deinit();
    var fmt_buffer: [40]u8 = undefined;
    try builder.addChunk("fmt ", fmtPayload(&fmt_buffer, format_pcm, 1, 8000, 16));
    const file = try builder.finish();
    defer testing.allocator.free(file);
    try testing.expectError(error.MissingData, decode(testing.allocator, file));
}

test "data 在 fmt 之前：error.DataBeforeFmt（不猜、不重排）" {
    var builder = try Builder.init(testing.allocator);
    defer builder.deinit();
    var fmt_buffer: [40]u8 = undefined;
    try builder.addChunk("data", &[_]u8{ 0x00, 0x00 });
    try builder.addChunk("fmt ", fmtPayload(&fmt_buffer, format_pcm, 1, 8000, 16));
    const file = try builder.finish();
    defer testing.allocator.free(file);
    try testing.expectError(error.DataBeforeFmt, decode(testing.allocator, file));
}

test "不支持的格式：12 位 PCM / float64 → error.UnsupportedFormat" {
    {
        const file = try buildWav(testing.allocator, format_pcm, 1, 8000, 12, &[_]u8{ 0, 0 });
        defer testing.allocator.free(file);
        try testing.expectError(error.UnsupportedFormat, decode(testing.allocator, file));
    }
    {
        const zeros: [8]u8 = @splat(0);
        const file = try buildWav(testing.allocator, format_float, 1, 8000, 64, &zeros);
        defer testing.allocator.free(file);
        try testing.expectError(error.UnsupportedFormat, decode(testing.allocator, file));
    }
    {
        // A-law（0x0006）也不在 M1 的支持面里。
        const file = try buildWav(testing.allocator, 6, 1, 8000, 8, &[_]u8{ 0x00, 0x00 });
        defer testing.allocator.free(file);
        try testing.expectError(error.UnsupportedFormat, decode(testing.allocator, file));
    }
}

test "坏文件：不是 RIFF/WAVE、块越界" {
    try testing.expectError(error.Truncated, decode(testing.allocator, "RIFF"));
    try testing.expectError(error.NotRiff, decode(testing.allocator, "RIFX\x00\x00\x00\x00WAVEfmt "));

    var builder = try Builder.init(testing.allocator);
    defer builder.deinit();
    var fmt_buffer: [40]u8 = undefined;
    try builder.addChunk("fmt ", fmtPayload(&fmt_buffer, format_pcm, 1, 8000, 16));
    try builder.addChunk("data", &[_]u8{ 0x00, 0x00 });
    const file = try builder.finish();
    defer testing.allocator.free(file);

    // 砍掉最后一个字节：data 块声明的长度比文件大，必须报 Truncated，不能越界读。
    const truncated = try testing.allocator.dupe(u8, file[0 .. file.len - 1]);
    defer testing.allocator.free(truncated);
    try testing.expectError(error.Truncated, decode(testing.allocator, truncated));
}

test "4 声道下混到立体声：偶数下标 → L、奇数下标 → R 的平均" {
    // 两帧：L=(1000+3000)/2=2000，R=(2000+4000)/2=3000。
    const samples = [_]i16{ 1000, 2000, 3000, 4000, -1000, -2000, -3000, -4000 };
    const pcm = std.mem.sliceAsBytes(&samples);
    const file = try buildWav(testing.allocator, format_pcm, 4, 44_100, 16, pcm);
    defer testing.allocator.free(file);

    var wav = try decode(testing.allocator, file);
    defer wav.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 2), wav.channels);
    try testing.expectEqual(@as(u64, 2), wav.frames);
    const out = std.mem.bytesAsSlice(i16, wav.pcm);
    try testing.expectEqual(@as(i16, 2000), out[0]);
    try testing.expectEqual(@as(i16, 3000), out[1]);
    try testing.expectEqual(@as(i16, -2000), out[2]);
    try testing.expectEqual(@as(i16, -3000), out[3]);
}

test "8 位 PCM 是无符号的（128 = 静音），下混先归一化" {
    // 4 声道 8 位一帧：0(-1), 255(+127/128), 0(-1), 255(+127/128)
    // → L 平均 -1 → 1；R 平均 ≈ +0.992 → 254。
    const pcm = [_]u8{ 0, 255, 0, 255 };
    const file = try buildWav(testing.allocator, format_pcm, 4, 8000, 8, &pcm);
    defer testing.allocator.free(file);

    var wav = try decode(testing.allocator, file);
    defer wav.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 2), wav.channels);
    try testing.expectEqualSlices(u8, &[_]u8{ 1, 254 }, wav.pcm);
}

test "data 长度不是整帧：尾部的半帧被丢弃，不冒充一帧" {
    const pcm = [_]u8{ 0x00, 0x00, 0x01 }; // 2 字节一帧 + 1 字节残片
    const file = try buildWav(testing.allocator, format_pcm, 1, 8000, 16, &pcm);
    defer testing.allocator.free(file);

    var wav = try decode(testing.allocator, file);
    defer wav.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 1), wav.frames);
    try testing.expectEqual(@as(usize, 2), wav.pcm.len);
}
