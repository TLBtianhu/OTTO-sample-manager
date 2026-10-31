//! L1 元数据口岸：只读文件头，产出时长 / 采样率 / 声道 / 位深 / 画面尺寸 / 编码。
//!
//! 七种容器，各自的头部解析在独立文件里（纯字节、可单测）：
//!   * WAV：`otto_wav_header.parse` 是解码器与 probe 共用的**唯一**一份块扫描，
//!     时长由 `wav_info` 按 codec 算（PCM/float、A-law、µ-law、IMA/MS ADPCM）；
//!   * FLAC：`flac_info.parse` 只读 STREAMINFO；
//!   * MP3：`mp3_info.parse` 跳 ID3、读第一帧、优先 Xing/Info 帧数；
//!   * AIFF：`aiff_info.parse` 只读 `COMM`（精确帧数 + 80 位扩展采样率）；
//!   * MP4 / MOV：`mp4_info` 走 box 到 `moov`（mvhd/tkhd/mdhd/stsd）；`moov` 在
//!     文件尾时由 `mp4_info.seek` 按 box 偏移跳过去，只读那一段，不读 `mdat`；
//!   * MKV / WebM：`mkv_info` 读 EBML 的 `Info`（TimecodeScale/Duration）与
//!     `Tracks`（TrackType/PixelWidth/PixelHeight/CodecID）；
//!   * Ogg：`ogg_info` 认首包的 `\x01vorbis` 与 `OpusHead`，时长取**最后一页的
//!     granule**——头里没有帧数，所以这一种要读文件尾（见下）。
//!
//! **视频只读容器、不解码任何一帧**：解码仍归 Media Foundation（`mf-video`）。
//! 非上述格式、坏头、截断一律返回 `null`——**不猜**，把 `pending_metadata`
//! 留给以后的 L1 实现，而不是凭空写 0 当作"已知是 0 秒"。`AIFC` 本轮不做，
//! 同样返回 null。
//!
//! 读的字节有硬上限：`max_header_bytes`（64 KiB）。WAV 的 `fmt ` 与 `data`
//! 块头都在文件最前面，64 KiB 足够；但 `data` 的负载通常远大于窗口，所以
//! 这里用 **`stat` 的文件大小**核对 `data` 的声明长度：
//!   * 声明长度 + 偏移 > 文件大小 → 文件被截断 / 头在撒谎 → `null`；
//!   * 否则按声明长度算帧数与时长，与窗口大小无关。
//! MP3 的 Xing/Info 在**第一帧**里，64 KiB 同样足够；CBR 估算用 `stat` 的
//! 文件大小，不会把音频负载读进来。FLAC 只需要 42 字节。
//!
//! Ogg 是唯一要读**文件尾**的音频容器：Vorbis 的总帧数就是最后一页的 granule，
//! 头里没有。`ogg_info.read` 用同一个 64 KiB 上限读最后一段（一页最大 65307
//! 字节，窗口一定含最后一页的页头），从后往前找"页末 == 文件末"的那一页；
//! 头尾之外一个字节都不读，别的 codec 返回 null。Opus 走同一条尾页路径，但它的
//! granule 含编码器的 pre_skip（2.000 s 的素材是 96312 而不是 96000），减去之后
//! 才是要播的帧数——所以这里给出 2000 ms，不是 2006 ms（见 `ogg_info.zig`）。
//!
//! `Metadata.estimated` 是"这个时长是不是推算的"：WAV（含 ADPCM / G.711）/
//! FLAC / AIFF / 带 Xing 的 MP3 / Ogg Vorbis / Ogg Opus 都来自容器声明（false），
//! 无 Xing 的 MP3 由文件大小 / 比特率算出（true）。界面必须把 true 显示成 `≈`，
//! 不能冒充精确值。ADPCM 的帧数由块头 + `block_align` 算出，仍是容器精确值，不是
//! 估算。MP4 / MKV / Ogg 的时长是容器声明的，也是 false。
//!
//! 本文件只碰标准库的文件 API；不 import core。

const std = @import("std");
const wav_header = @import("otto_wav_header");
const wav_info = @import("wav_info.zig");
const flac_info = @import("flac_info.zig");
const mp3_info = @import("mp3_info.zig");
const aiff_info = @import("aiff_info.zig");
const mp4_info = @import("mp4_info.zig");
const mkv_info = @import("mkv_info.zig");
const ogg_info = @import("ogg_info.zig");
const codec_text = @import("codec_text.zig");

/// 编码名的定长载体（见 `codec_text.zig`）。
pub const CodecText = codec_text.CodecText;
/// 头部读取上限：七种容器的头部都远小于 64 KiB。MP4 的 `moov` 在文件尾时按
/// 偏移单独读（见 `mp4_info.max_moov_bytes`），Ogg 的尾页走 `ogg_info.tail_window`，
/// 这一条只约束"从头读的那一段"。
pub const max_header_bytes: usize = 64 * 1024;

/// 支持的类型面。不在这个列表里的容器一律返回 null。
pub const Kind = enum { wav, flac, mp3, aiff, mp4, mkv, ogg };


pub const Metadata = struct {
    /// 声明或推算的时长（毫秒，向下取整）。
    duration_ms: u64,
    sample_rate: u32 = 0,
    channels: u32 = 0,
    bits: u16 = 0,
    kind: Kind,
    /// 画面尺寸与编码名：只对视频容器有值，音频 / 未知时 null。
    width: ?u32 = null,
    height: ?u32 = null,
    codec: ?CodecText = null,
    /// true = 时长由文件大小 / 比特率推算，不是容器声明。显示时必须加 `≈`。
    /// 默认 false：所有解析器都显式写它，默认值只是给测试/调用方的便利。
    estimated: bool = false,
};

/// 打开 / 读取 / `stat` 失败都原样交给调用方（导入流水线把它记进失败清单）；
/// "不是我们能解析的文件"不是错误，是 `null`。
pub const Error = std.Io.File.OpenError || std.Io.File.StatError || std.Io.File.ReadPositionalError || error{OutOfMemory};

/// 读 `path` 的头部。返回 `null` = 不认识的容器 / 空文件 / 截断 / 不支持的格式。
pub fn probe(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) Error!?Metadata {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    const buffer = try allocator.alloc(u8, max_header_bytes);
    defer allocator.free(buffer);
    const read = try file.readPositionalAll(io, buffer, 0);
    const bytes = buffer[0..read];

    // 先做最便宜的排除：空文件、明显不是这三种容器的文件不进入解析。
    if (bytes.len < 4) return null;

    if (isWav(bytes)) return probeWav(io, file, bytes);
    if (std.mem.eql(u8, bytes[0..4], "fLaC")) return probeFlac(bytes);
    if (isAiff(bytes)) return probeAiff(bytes);
    if (isMp4(bytes)) return probeMp4(allocator, io, file, bytes);
    if (isMkv(bytes)) return probeMkv(bytes);
    if (std.mem.eql(u8, bytes[0..4], "OggS")) return probeOgg(allocator, io, file, bytes);
    if (looksLikeMp3(bytes)) return probeMp3(io, file, bytes);
    return null;
}

fn isWav(bytes: []const u8) bool {
    return bytes.len >= 12 and
        std.mem.eql(u8, bytes[0..4], "RIFF") and
        std.mem.eql(u8, bytes[8..12], "WAVE");
}

/// 只认 `FORM....AIFF`；`AIFC` 本轮不做，落到下面的 `return null`。
fn isAiff(bytes: []const u8) bool {
    return bytes.len >= 12 and
        std.mem.eql(u8, bytes[0..4], "FORM") and
        std.mem.eql(u8, bytes[8..12], "AIFF");
}

/// ISO BMFF：第一个 box 的 type 是 `ftyp`（`.mov` / `.m4a` 也是同一个容器）。
fn isMp4(bytes: []const u8) bool {
    return bytes.len >= 12 and std.mem.eql(u8, bytes[4..8], "ftyp");
}

/// Matroska / WebM：EBML 魔数。
fn isMkv(bytes: []const u8) bool {
    return bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "\x1A\x45\xDF\xA3");
}

/// MP4 / MOV：`moov` 在头部窗口里就直接解析；不在（ffmpeg 默认把 moov 放尾部）
/// 就交给 `mp4_info.seek`，按 box size 逐个跳过、只把 `moov` 那一段读进来——
/// `mdat` 的负载一个字节都不读。容器声明是精确值，`estimated = false`。
fn probeMp4(
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    bytes: []const u8,
) Error!?Metadata {
    var info = mp4_info.parse(bytes);
    if (info.duration_ms == null) {
        const stat = try file.stat(io);
        if (try mp4_info.seek(allocator, io, file, stat.size)) |found| info = found;
    }
    const duration_ms = info.duration_ms orelse return null;
    return .{
        .duration_ms = duration_ms,
        .kind = .mp4,
        .width = info.width,
        .height = info.height,
        .codec = info.codec,
        .estimated = false,
    };
}

fn probeMkv(bytes: []const u8) ?Metadata {
    const info = mkv_info.parse(bytes) catch return null;
    const duration_ms = info.duration_ms orelse return null;
    return .{
        .duration_ms = duration_ms,
        .kind = .mkv,
        .width = info.width,
        .height = info.height,
        .codec = info.codec,
        .estimated = false,
    };
}

/// Ogg：首包认 Vorbis 与 Opus（Opus 的尾页 granule 会先减掉 pre_skip），别的
/// codec → null；时长取最后一页的 granule（容器精确值）。头 + 尾各读一次，中间
/// 不读（见 `ogg_info.zig`）。
/// **只有元数据**：Opus 能算时长不等于能播——解码仍然归 `native-audio`，而它不
/// 声明 `.opus`（见 `providers/native_audio.zig`），所以预览照旧谢绝。
/// `Kind` 只有 `.ogg`：它是容器名，Vorbis / Opus 都是 Ogg，编码不进 `Metadata`。
fn probeOgg(
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    bytes: []const u8,
) Error!?Metadata {
    const info = (try ogg_info.read(allocator, io, file, bytes)) orelse return null;
    return .{
        .duration_ms = info.duration_ms,
        .sample_rate = info.sample_rate,
        .channels = info.channels,
        .kind = .ogg,
        .estimated = false,
    };
}

/// WAV：块扫描 + 按 codec 算帧数 + 用文件大小核对 `data` 的声明长度。
fn probeWav(
    io: std.Io,
    file: std.Io.File,
    bytes: []const u8,
) Error!?Metadata {
    const header = wav_header.parse(bytes) catch return null;

    // 与真实文件大小核对：声明比实有大 → 截断，不按声明冒充完整时长。
    const data_offset: u64 = @intCast(header.data_offset);
    const data_end = std.math.add(u64, data_offset, header.data_size) catch return null;
    const stat = try file.stat(io);
    if (data_end > stat.size) return null;

    const duration_ms = wav_info.durationMs(header) catch return null;

    return .{
        .duration_ms = duration_ms,
        .sample_rate = header.sample_rate,
        .channels = header.channels,
        .bits = header.bits,
        .kind = .wav,
        .estimated = false,
    };
}

/// AIFF：`COMM` 的 numSampleFrames 就是精确帧数，不需要读 `SSND`。
fn probeAiff(bytes: []const u8) ?Metadata {
    const info = aiff_info.parse(bytes) catch return null;
    return .{
        .duration_ms = aiff_info.durationMs(info),
        .sample_rate = info.sample_rate,
        .channels = info.channels,
        .bits = info.bits,
        .kind = .aiff,
        .estimated = false,
    };
}

fn probeFlac(bytes: []const u8) ?Metadata {
    const info = flac_info.parse(bytes) catch return null;
    const duration_ms = flac_info.durationMs(info) orelse return null;
    return .{
        .duration_ms = duration_ms,
        .sample_rate = info.sample_rate,
        .channels = info.channels,
        .bits = info.bits,
        .kind = .flac,
        .estimated = false,
    };
}

/// 只在文件确实像 MP3 时才 `stat`：PNG 之类的文件不因为 probe 多一次系统调用。
fn looksLikeMp3(bytes: []const u8) bool {
    if (bytes.len >= 3 and std.mem.eql(u8, bytes[0..3], "ID3")) return true;
    return bytes.len >= 2 and bytes[0] == 0xFF and (bytes[1] & 0xE0) == 0xE0;
}

fn probeMp3(io: std.Io, file: std.Io.File, bytes: []const u8) Error!?Metadata {
    const stat = try file.stat(io);
    const info = mp3_info.parse(bytes, stat.size) catch return null;
    return .{
        .duration_ms = info.duration_ms,
        .sample_rate = info.sample_rate,
        .channels = info.channels,
        .bits = info.bits,
        .kind = .mp3,
        .estimated = info.estimated,
    };
}

// ---------------------------------------------------------------------------
// 测试：真文件系统 + 内存里造 WAV（不依赖外部 fixture）
// ---------------------------------------------------------------------------

const testing = std.testing;
const test_io = std.testing.io;
const test_allocator = std.testing.allocator;

/// 造一份 16 位 PCM WAV 字节；`frames` 决定 data 长度。
fn buildWav(allocator: std.mem.Allocator, sample_rate: u32, channels: u16, frames: usize) ![]u8 {
    const block_align: u16 = channels * 2;
    const data_bytes: u32 = @intCast(frames * block_align);
    const total = 44 + data_bytes;
    const bytes = try allocator.alloc(u8, total);
    @memcpy(bytes[0..4], "RIFF");
    std.mem.writeInt(u32, bytes[4..8], total - 8, .little);
    @memcpy(bytes[8..12], "WAVE");
    @memcpy(bytes[12..16], "fmt ");
    std.mem.writeInt(u32, bytes[16..20], 16, .little);
    std.mem.writeInt(u16, bytes[20..22], 1, .little);
    std.mem.writeInt(u16, bytes[22..24], channels, .little);
    std.mem.writeInt(u32, bytes[24..28], sample_rate, .little);
    std.mem.writeInt(u32, bytes[28..32], sample_rate * block_align, .little);
    std.mem.writeInt(u16, bytes[32..34], block_align, .little);
    std.mem.writeInt(u16, bytes[34..36], 16, .little);
    @memcpy(bytes[36..40], "data");
    std.mem.writeInt(u32, bytes[40..44], data_bytes, .little);
    @memset(bytes[44..], 0);
    return bytes;
}

test "有效 WAV：800ms / 22050 / 单声道 / 16 位" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const wav = try buildWav(test_allocator, 22_050, 1, 17_640); // 17640 帧 = 800 ms
    defer test_allocator.free(wav);
    try tmp.dir.writeFile(test_io, .{ .sub_path = "tone.wav", .data = wav });

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(test_io, &buffer);
    var full: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const absolute = try std.fmt.bufPrint(&full, "{s}\\tone.wav", .{buffer[0..root_len]});
    const metadata = (try probe(test_allocator, test_io, absolute)).?;
    try testing.expectEqual(@as(u64, 800), metadata.duration_ms);
    try testing.expectEqual(@as(u32, 22_050), metadata.sample_rate);
    try testing.expectEqual(@as(u32, 1), metadata.channels);
    try testing.expectEqual(@as(u16, 16), metadata.bits);
    try testing.expectEqual(Kind.wav, metadata.kind);
    try testing.expect(!metadata.estimated);
}

test "大于 64 KiB 的 WAV：时长按声明长度算，与读取窗口无关" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // 5 秒 @ 44.1 kHz 立体声 = 882000 字节，远超 64 KiB 窗口。
    const wav = try buildWav(test_allocator, 44_100, 2, 44_100 * 5);
    defer test_allocator.free(wav);
    try tmp.dir.writeFile(test_io, .{ .sub_path = "long.wav", .data = wav });

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(test_io, &buffer);
    var full: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const absolute = try std.fmt.bufPrint(&full, "{s}\\long.wav", .{buffer[0..root_len]});

    const metadata = (try probe(test_allocator, test_io, absolute)).?;
    try testing.expectEqual(@as(u64, 5000), metadata.duration_ms);
    try testing.expectEqual(@as(u32, 2), metadata.channels);
}

test "空文件 / PNG / 截断的 WAV：null，不猜" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(test_io, .{ .sub_path = "empty.wav", .data = "" });
    try tmp.dir.writeFile(test_io, .{ .sub_path = "image.png", .data = "\x89PNG\r\n\x1a\n" ++ "rest-of-png" });
    // AIFC 是另一种容器：本轮不做，probe 必须返回 null 而不是猜。
    try tmp.dir.writeFile(test_io, .{ .sub_path = "compressed.aiff", .data = "FORM" ++ [_]u8{ 0, 0, 0, 4 } ++ "AIFC" });

    const wav = try buildWav(test_allocator, 22_050, 1, 17_640);
    defer test_allocator.free(wav);
    // 头声明 35280 字节 data，实际只留 100 字节：截断。
    try tmp.dir.writeFile(test_io, .{ .sub_path = "cut.wav", .data = wav[0..100] });

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(test_io, &buffer);
    var full: [std.Io.Dir.max_path_bytes]u8 = undefined;

    inline for ([_][]const u8{ "empty.wav", "image.png", "compressed.aiff", "cut.wav" }) |name| {
        const absolute = try std.fmt.bufPrint(&full, "{s}\\{s}", .{ buffer[0..root_len], name });
        try testing.expect((try probe(test_allocator, test_io, absolute)) == null);
    }
}

test "真 testkit wav（存在才跑）：tone_440.wav 是 800 ms" {
    const path = "C:\\src\\otto-testkit\\samples\\tone_440.wav";
    std.Io.Dir.cwd().access(test_io, path, .{}) catch return error.SkipZigTest;

    const metadata = (try probe(test_allocator, test_io, path)).?;
    try testing.expectEqual(@as(u64, 800), metadata.duration_ms);
    try testing.expectEqual(@as(u32, 22_050), metadata.sample_rate);
    try testing.expectEqual(@as(u32, 1), metadata.channels);
}

test "真 legacy 素材（存在才跑）：四个 WAV tag + AIFF 全是容器精确值" {
    const Case = struct {
        name: []const u8,
        duration_ms: u64,
        sample_rate: u32,
        channels: u32,
        bits: u16,
        kind: Kind,
    };
    // ADPCM 的 2036 / 2031 是"完整块 × 每块样本数"的结果；和 ffprobe 的 2.000 s
    // 差 36 / 31 ms（ffprobe 读 fact / 平均码率），仍在 50 ms 容差内。
    const cases = [_]Case{
        .{ .name = "alaw-8k.wav", .duration_ms = 2000, .sample_rate = 8_000, .channels = 1, .bits = 8, .kind = .wav },
        .{ .name = "mulaw-8k.wav", .duration_ms = 2000, .sample_rate = 8_000, .channels = 1, .bits = 8, .kind = .wav },
        .{ .name = "ima-wav-44k.wav", .duration_ms = 2036, .sample_rate = 44_100, .channels = 1, .bits = 4, .kind = .wav },
        .{ .name = "ms-adpcm-44k.wav", .duration_ms = 2031, .sample_rate = 44_100, .channels = 1, .bits = 4, .kind = .wav },
        .{ .name = "aiff-s16.aiff", .duration_ms = 2000, .sample_rate = 44_100, .channels = 1, .bits = 16, .kind = .aiff },
        .{ .name = "aiff-s24.aiff", .duration_ms = 2000, .sample_rate = 44_100, .channels = 1, .bits = 24, .kind = .aiff },
    };

    for (cases) |case| {
        var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(
            &path_buffer,
            "C:\\src\\zig-audio-vectors\\legacy\\{s}",
            .{case.name},
        ) catch return error.SkipZigTest;
        std.Io.Dir.cwd().access(test_io, path, .{}) catch return error.SkipZigTest;

        const metadata = (try probe(test_allocator, test_io, path)).?;
        try testing.expectEqual(case.duration_ms, metadata.duration_ms);
        try testing.expectEqual(case.sample_rate, metadata.sample_rate);
        try testing.expectEqual(case.channels, metadata.channels);
        try testing.expectEqual(case.bits, metadata.bits);
        try testing.expectEqual(case.kind, metadata.kind);
        try testing.expect(!metadata.estimated);
    }
}

test "缺失文件：具名错误，不是 null" {
    try testing.expectError(
        error.FileNotFound,
        probe(test_allocator, test_io, "C:\\definitely\\missing\\x.wav"),
    );
}

test "真 testkit flac（存在才跑）：tone_660.flac = 1500 ms，精确" {
    const path = "C:\\src\\otto-testkit\\samples\\tone_660.flac";
    std.Io.Dir.cwd().access(test_io, path, .{}) catch return error.SkipZigTest;

    const metadata = (try probe(test_allocator, test_io, path)).?;
    try testing.expectEqual(@as(u64, 1500), metadata.duration_ms);
    try testing.expectEqual(@as(u32, 44_100), metadata.sample_rate);
    try testing.expectEqual(@as(u32, 1), metadata.channels);
    try testing.expectEqual(@as(u16, 16), metadata.bits);
    try testing.expectEqual(Kind.flac, metadata.kind);
    try testing.expect(!metadata.estimated);
}

test "真 testkit mp3（存在才跑）：viper.mp3 无 Xing，按比特率估算 40933 ms" {
    const path = "C:\\src\\otto-testkit\\samples\\viper.mp3";
    std.Io.Dir.cwd().access(test_io, path, .{}) catch return error.SkipZigTest;

    const metadata = (try probe(test_allocator, test_io, path)).?;
    // (654942 - 0) * 8 / 128000 = 40.933875 s -> 40933 ms
    try testing.expectEqual(@as(u64, 40_933), metadata.duration_ms);
    try testing.expectEqual(@as(u32, 44_100), metadata.sample_rate);
    try testing.expectEqual(@as(u32, 2), metadata.channels);
    try testing.expectEqual(Kind.mp3, metadata.kind);
    try testing.expect(metadata.estimated);
}

test "真 FLAC 没有 total_samples（存在才跑）：null，不是 0 秒" {
    const path = "C:\\src\\zig-audio-vectors\\45 - no total number of samples set.flac";
    std.Io.Dir.cwd().access(test_io, path, .{}) catch return error.SkipZigTest;

    try testing.expect((try probe(test_allocator, test_io, path)) == null);
}
