//! L1 元数据口岸：只读文件头，产出时长 / 采样率 / 声道 / 位深。
//!
//! 本轮只认 WAV：`otto_wav_header.parse` 是解码器与 probe 共用的**唯一**一份
//! 头部解析（见那边的文件头）。非 WAV 一律返回 `null`——**不猜**，把
//! `pending_metadata` 留给以后的 L1 实现，而不是凭空写 0 当作"已知是 0 秒"。
//!
//! 读的字节有硬上限：`max_header_bytes`（64 KiB）。WAV 的 `fmt ` 与 `data`
//! 块头都在文件最前面，64 KiB 足够；但 `data` 的负载通常远大于窗口，所以
//! 这里用 **`stat` 的文件大小**核对 `data` 的声明长度：
//!   * 声明长度 + 偏移 > 文件大小 → 文件被截断 / 头在撒谎 → `null`；
//!   * 否则按声明长度算帧数与时长，与窗口大小无关。
//!
//! 本文件只碰标准库的文件 API；不 import core，也不解析任何非 WAV 容器。

const std = @import("std");
const wav_header = @import("otto_wav_header");

/// 头部读取上限。WAV 的块头在最前面，64 KiB 足够覆盖 `fmt ` 与 `data` 头。
pub const max_header_bytes: usize = 64 * 1024;

/// 本轮支持的类型面。非 WAV 返回 null，所以暂时只有 `.wav`。
pub const Kind = enum { wav };

pub const Metadata = struct {
    /// 声明时长（毫秒，向下取整）。
    duration_ms: u64,
    sample_rate: u32,
    channels: u32,
    bits: u16,
    kind: Kind,
};

/// 打开 / 读取 / `stat` 失败都原样交给调用方（导入流水线把它记进失败清单）；
/// "不是我们能解析的 WAV"不是错误，是 `null`。
pub const Error = std.Io.File.OpenError || std.Io.File.StatError || std.Io.File.ReadPositionalError || error{OutOfMemory};

/// 读 `path` 的头部。返回 `null` = 不是 WAV / 空文件 / 截断 / 不支持的格式。
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

    // 先做最便宜的排除：空文件、明显不是 RIFF/WAVE 的文件不进入块扫描。
    if (bytes.len < 12) return null;
    if (!std.mem.eql(u8, bytes[0..4], "RIFF")) return null;
    if (!std.mem.eql(u8, bytes[8..12], "WAVE")) return null;

    const header = wav_header.parse(bytes) catch return null;
    const frame_bytes = header.frameBytes();
    if (frame_bytes == 0) return null;

    // 与真实文件大小核对：声明比实有大 → 截断，不按声明冒充完整时长。
    const data_offset: u64 = @intCast(header.data_offset);
    const data_end = std.math.add(u64, data_offset, header.data_size) catch return null;
    const stat = try file.stat(io);
    if (data_end > stat.size) return null;

    const frames = header.data_size / frame_bytes;
    const duration_ms = std.math.mul(u64, frames, 1000) catch return null;

    return .{
        .duration_ms = duration_ms / header.sample_rate,
        .sample_rate = header.sample_rate,
        .channels = header.channels,
        .bits = header.bits,
        .kind = .wav,
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

    const wav = try buildWav(test_allocator, 22_050, 1, 17_640);
    defer test_allocator.free(wav);
    // 头声明 35280 字节 data，实际只留 100 字节：截断。
    try tmp.dir.writeFile(test_io, .{ .sub_path = "cut.wav", .data = wav[0..100] });

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(test_io, &buffer);
    var full: [std.Io.Dir.max_path_bytes]u8 = undefined;

    inline for ([_][]const u8{ "empty.wav", "image.png", "cut.wav" }) |name| {
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

test "缺失文件：具名错误，不是 null" {
    try testing.expectError(
        error.FileNotFound,
        probe(test_allocator, test_io, "C:\\definitely\\missing\\x.wav"),
    );
}
