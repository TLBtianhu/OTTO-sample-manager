//! 音频图标的**粗采样**：不为一个 32pt 小图解码整段音频。
//!
//! 列表左侧的缩略图不是"预览的缩小版"，而是**身份指纹**：要的是"一眼分清这是
//! 哪个文件"的判别力，不是保真度。所以这里只读头部 + 32 个等距窗口，每窗读两帧
//! 采样值，拼成 min/max 包络，再渲染成一张 64×64 的波形条（透明背景，行内的
//! 轨道底色透出来）。
//!
//! 预算：单张图标 **≤15 ms**。WAV 的头部最多读 64 KiB、数据只读 32 × 2 帧；
//! 40 秒的 44.1 kHz 立体声 WAV 也只需要几十次 seek + 几 KB 读数，不会把几十 MB
//! 的 PCM 搬进内存。`mf-audio` 走另一条 MF seek 采样，是否开启由实测开销决定
//! （见 `providers/mf_audio.zig` 与报告）。
//!
//! 颜色是中间调的蓝：浅色 / 深色两套轨道的底色上都能看见，不依赖主题。
//! 本文件只碰音频文件与像素，不碰窗口、不 import nanoui。

const std = @import("std");
const preview = @import("../preview.zig");
const file = @import("file.zig");
const peaks_mod = @import("peaks.zig");
const waveform = @import("waveform.zig");
const win = @import("win32.zig");
const wav_header = @import("otto_wav_header");

/// 图标里的包络桶数。32 桶画 64px 宽：每列合并两个桶，既有形状又够便宜。
pub const bucket_count: usize = 32;

/// 单张图标的预算（毫秒）。超过它的实现不该进 `icon_capable` 列表。
pub const budget_ms: u64 = 15;

/// 头部窗口：fmt/data 头正常在前几百字节；64 KiB 足够覆盖罕见的 LIST/JUNK 块。
const header_window_bytes: usize = 64 * 1024;

/// 每个窗口读两帧：一帧只能得到一个点，两帧才能看出局部起伏。
const frames_per_window: usize = 2;

/// 中间调蓝。浅色轨道（#f1f1f1 左右）与深色轨道（#2a2a2a 左右）上都有对比度。
pub const bar_color: waveform.Color = .{ .r = 0x70, .g = 0x9a, .b = 0xc8, .a = 0xff };

pub const Error = file.Error || wav_header.Error || std.mem.Allocator.Error || error{
    /// 头部没有可用数据（0 帧 / 空 data 块）。
    Empty,
};

/// 生成一张 WAV 的行内图标（BGRA、透明背景）。像素归调用方，用同一个 allocator
/// 释放。`max_px` 是请求的长边；图标固定画成正方形（行内槽就是正方形）。
pub fn wavIcon(allocator: std.mem.Allocator, path: []const u8, max_px: u32) Error!preview.Bitmap {
    const started = win.GetTickCount64();

    var reader = try file.openReader(allocator, path);
    defer reader.deinit();

    const prefix_len: usize = @intCast(@min(reader.size, header_window_bytes));
    const prefix = try allocator.alloc(u8, prefix_len);
    defer allocator.free(prefix);
    try reader.readAt(0, prefix);
    const header = try wav_header.parse(prefix);

    const frame_bytes = header.frameBytes();
    if (frame_bytes == 0) return error.Empty;
    const available = reader.size -| @as(u64, header.data_offset);
    const data_size = @min(header.data_size, available);
    const frames = data_size / frame_bytes;
    if (frames == 0) return error.Empty;

    const count: usize = @min(bucket_count, @as(usize, @intCast(frames)));
    const min = try allocator.alloc(i16, count);
    errdefer allocator.free(min);
    const max = try allocator.alloc(i16, count);
    errdefer allocator.free(max);
    var peaks = peaks_mod.Peaks{ .min = min, .max = max };
    defer peaks.deinit(allocator);

    const window_bytes = frame_bytes * frames_per_window;
    const buffer = try allocator.alloc(u8, window_bytes);
    defer allocator.free(buffer);

    var bucket: usize = 0;
    while (bucket < count) : (bucket += 1) {
        const start = @as(u64, bucket) * frames / count;
        const remaining = frames - start;
        const want_frames: usize = @intCast(@min(@as(u64, frames_per_window), remaining));
        const offset = @as(u64, header.data_offset) + start * @as(u64, frame_bytes);
        try reader.readAt(offset, buffer[0 .. want_frames * frame_bytes]);

        var low: i16 = std.math.maxInt(i16);
        var high: i16 = std.math.minInt(i16);
        var index: usize = 0;
        while (index < want_frames) : (index += 1) {
            const frame = buffer[index * frame_bytes ..][0..frame_bytes];
            const value = peaks_mod.frameValue(frame, 0, header.channels, header.bits, header.format);
            low = @min(low, value);
            high = @max(high, value);
        }
        min[bucket] = low;
        max[bucket] = high;
    }

    // 图标槽是 32pt，2x 屏 64px；请求别的边长时按 16..128 夹住，别让一个
    // 行内图去分配一张预览尺寸的位图。
    const side = std.math.clamp(max_px, 16, 128);
    const bitmap = try waveform.render(allocator, peaks, side, side, bar_color);

    const elapsed = win.GetTickCount64() -| started;
    std.debug.print(
        "otto-lite: wav-icon file={s} frames={d} buckets={d} side={d} elapsed={d}ms\n",
        .{ path, frames, count, side, elapsed },
    );
    return bitmap;
}

// ---------------------------------------------------------------------------
// 测试：临时目录里造一段 8 kHz / 16 位 / 单声道正弦，不碰设备、不碰窗口
// ---------------------------------------------------------------------------

const testing = std.testing;

fn writeSineWav(io: std.Io, dir: std.Io.Dir, name: []const u8, frames: usize) !void {
    const sample_rate: u32 = 8000;
    const data_bytes: u32 = @intCast(frames * 2);
    const bytes = try testing.allocator.alloc(u8, 44 + data_bytes);
    defer testing.allocator.free(bytes);
    @memset(bytes, 0);

    @memcpy(bytes[0..4], "RIFF");
    std.mem.writeInt(u32, bytes[4..8], 36 + data_bytes, .little);
    @memcpy(bytes[8..12], "WAVE");
    @memcpy(bytes[12..16], "fmt ");
    std.mem.writeInt(u32, bytes[16..20], 16, .little);
    std.mem.writeInt(u16, bytes[20..22], 1, .little); // PCM
    std.mem.writeInt(u16, bytes[22..24], 1, .little); // mono
    std.mem.writeInt(u32, bytes[24..28], sample_rate, .little);
    std.mem.writeInt(u32, bytes[28..32], sample_rate * 2, .little);
    std.mem.writeInt(u16, bytes[32..34], 2, .little);
    std.mem.writeInt(u16, bytes[34..36], 16, .little);
    @memcpy(bytes[36..40], "data");
    std.mem.writeInt(u32, bytes[40..44], data_bytes, .little);

    for (0..frames) |index| {
        const phase = @as(f32, @floatFromInt(index)) * 2.0 * std.math.pi * 440.0 / @as(f32, sample_rate);
        const value: i16 = @intFromFloat(@round(@sin(phase) * 20_000.0));
        std.mem.writeInt(i16, bytes[44 + index * 2 ..][0..2], value, .little);
    }
    try dir.writeFile(io, .{ .sub_path = name, .data = bytes });
}

test "wavIcon：8 kHz 正弦 → 64×64 BGRA 波形，有可见像素；不读整段 PCM" {
    if (!win.supported) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeSineWav(testing.io, tmp.dir, "sine.wav", 800);

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(testing.io, &root_buffer);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}\\sine.wav", .{root_buffer[0..root_len]});

    const bitmap = try wavIcon(testing.allocator, path, 64);
    defer bitmap.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 64), bitmap.width);
    try testing.expectEqual(@as(u32, 64), bitmap.height);
    try testing.expectEqual(@as(usize, 64 * 4), bitmap.stride);

    var visible: usize = 0;
    var index: usize = 3;
    while (index < bitmap.pixels.len) : (index += 4) {
        if (bitmap.pixels[index] != 0) visible += 1;
    }
    try testing.expect(visible > 0);
}

test "wavIcon：空 data 块 → error.Empty（不是崩溃 / 不是一张假图）" {
    if (!win.supported) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "empty.wav",
        .data = "RIFF" ++ [_]u8{ 36, 0, 0, 0 } ++ "WAVEfmt " ++ [_]u8{ 16, 0, 0, 0 } ++
            [_]u8{ 1, 0, 1, 0, 0x40, 0x1f, 0, 0, 0x80, 0x3e, 0, 0, 2, 0, 16, 0 } ++
            "data" ++ [_]u8{ 0, 0, 0, 0 },
    });

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(testing.io, &root_buffer);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}\\empty.wav", .{root_buffer[0..root_len]});

    try testing.expectError(error.Empty, wavIcon(testing.allocator, path, 64));
}
