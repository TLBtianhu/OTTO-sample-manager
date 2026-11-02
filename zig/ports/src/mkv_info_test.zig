//! `mkv_info.zig` 的测试根：内存里造 EBML element，不碰磁盘。
//!
//! 和 `mp4_info_test.zig` 同一条理由：解析器本身只放"读文件头"的逻辑，
//! 测试单独一个编译图，不挂进 `otto_probe` 模块的文件图。

const std = @import("std");
const mkv_info = @import("mkv_info.zig");

const testing = std.testing;

// 用到的 EBML ID（原值，marker 位保留）。
const id_ebml = [_]u8{ 0x1A, 0x45, 0xDF, 0xA3 };
const id_segment = [_]u8{ 0x18, 0x53, 0x80, 0x67 };
const id_info = [_]u8{ 0x15, 0x49, 0xA9, 0x66 };
const id_timecode_scale = [_]u8{ 0x2A, 0xD7, 0xB1 };
const id_duration = [_]u8{ 0x44, 0x89 };
const id_tracks = [_]u8{ 0x16, 0x54, 0xAE, 0x6B };
const id_track_entry = [_]u8{0xAE};
const id_track_type = [_]u8{0x83};
const id_codec_id = [_]u8{0x86};
const id_video = [_]u8{0xE0};
const id_pixel_width = [_]u8{0xB0};
const id_pixel_height = [_]u8{0xBA};

/// 写一个 EBML element：ID + vint 长度 + 负载。测试里负载都很小（< 0x3FFF），
/// 1 或 2 字节的长度就够；再大直接返回 0（用不到，用到了测试会立刻挂）。
fn putElement(out: []u8, at: usize, id: []const u8, payload: []const u8) usize {
    @memcpy(out[at..][0..id.len], id);
    var cursor = at + id.len;
    const len = payload.len;
    if (len < 0x7F) {
        out[cursor] = 0x80 | @as(u8, @intCast(len));
        cursor += 1;
    } else if (len < 0x3FFF) {
        out[cursor] = 0x40 | @as(u8, @intCast(len >> 8));
        out[cursor + 1] = @intCast(len & 0xFF);
        cursor += 2;
    } else return 0;
    @memcpy(out[cursor..][0..len], payload);
    return cursor + len;
}

/// EBML uint：最少字节数的大端表示。
fn putUint(out: []u8, value: u64) []const u8 {
    var len: usize = 1;
    var probe = value;
    while (probe > 0xFF) : (probe >>= 8) len += 1;
    var cursor = len;
    probe = value;
    while (cursor > 0) : (cursor -= 1) {
        out[cursor - 1] = @intCast(probe & 0xFF);
        probe >>= 8;
    }
    return out[0..len];
}

fn putF32(out: []u8, value: f32) []const u8 {
    const bits: u32 = @bitCast(value);
    out[0] = @intCast(bits >> 24);
    out[1] = @intCast((bits >> 16) & 0xFF);
    out[2] = @intCast((bits >> 8) & 0xFF);
    out[3] = @intCast(bits & 0xFF);
    return out[0..4];
}

fn putF64(out: []u8, value: f64) []const u8 {
    const bits: u64 = @bitCast(value);
    var cursor: usize = 0;
    while (cursor < 8) : (cursor += 1) {
        out[cursor] = @intCast((bits >> @intCast(56 - 8 * cursor)) & 0xFF);
    }
    return out[0..8];
}

/// 拼一个最小的 Matroska 文件头：EBML 头 + Segment(Info, Tracks)。
fn putHeader(out: []u8, info_payload: []const u8, tracks_payload: ?[]const u8) []const u8 {
    var segment: [1024]u8 = undefined;
    var at: usize = 0;
    if (info_payload.len > 0) at = putElement(&segment, at, &id_info, info_payload);
    if (tracks_payload) |payload| at = putElement(&segment, at, &id_tracks, payload);
    var total: usize = putElement(out, 0, &id_ebml, "");
    total = putElement(out, total, &id_segment, segment[0..at]);
    return out[0..total];
}

test "Info：TimecodeScale 1e6 + Duration 3000 → 3000 ms" {
    var scratch: [8]u8 = undefined;
    var info: [64]u8 = undefined;
    var at: usize = 0;
    at = putElement(&info, at, &id_timecode_scale, putUint(&scratch, 1_000_000));
    at = putElement(&info, at, &id_duration, putF32(&scratch, 3000.0));

    var file: [256]u8 = undefined;
    const bytes = putHeader(&file, info[0..at], null);

    const parsed = try mkv_info.parse(bytes);
    try testing.expectEqual(@as(?u64, 3000), parsed.duration_ms);
    try testing.expect(parsed.width == null);
}

test "Info：TimecodeScale 缺席时用默认 1e6；8 字节 Duration" {
    var scratch: [8]u8 = undefined;
    var info: [64]u8 = undefined;
    const at = putElement(&info, 0, &id_duration, putF64(&scratch, 2500.0));

    var file: [256]u8 = undefined;
    const bytes = putHeader(&file, info[0..at], null);
    try testing.expectEqual(@as(?u64, 2500), (try mkv_info.parse(bytes)).duration_ms);

    // 自定义 TimecodeScale：90000 个刻度每毫秒 = 90 刻度/ms 的 45 秒。
    var scaled: [64]u8 = undefined;
    var scaled_at: usize = 0;
    scaled_at = putElement(&scaled, scaled_at, &id_timecode_scale, putUint(&scratch, 90_000));
    scaled_at = putElement(&scaled, scaled_at, &id_duration, putF32(&scratch, 4_050_000.0));
    var scaled_file: [256]u8 = undefined;
    const scaled_bytes = putHeader(&scaled_file, scaled[0..scaled_at], null);
    // 4,050,000 × 90,000 / 1e6 = 364,500 ms
    try testing.expectEqual(@as(?u64, 364_500), (try mkv_info.parse(scaled_bytes)).duration_ms);
}

test "Tracks：TrackType=1 + PixelWidth/PixelHeight + CodecID" {
    var scratch: [16]u8 = undefined;
    var video: [32]u8 = undefined;
    var video_at: usize = 0;
    video_at = putElement(&video, video_at, &id_pixel_width, putUint(&scratch, 640));
    video_at = putElement(&video, video_at, &id_pixel_height, putUint(&scratch, 360));

    var entry: [128]u8 = undefined;
    var entry_at: usize = 0;
    entry_at = putElement(&entry, entry_at, &id_track_type, putUint(&scratch, 1));
    entry_at = putElement(&entry, entry_at, &id_codec_id, "V_MPEG4/ISO/AVC");
    entry_at = putElement(&entry, entry_at, &id_video, video[0..video_at]);

    var tracks: [160]u8 = undefined;
    const tracks_at = putElement(&tracks, 0, &id_track_entry, entry[0..entry_at]);

    var file: [512]u8 = undefined;
    const bytes = putHeader(&file, "", tracks[0..tracks_at]);

    const parsed = try mkv_info.parse(bytes);
    try testing.expectEqual(@as(?u32, 640), parsed.width);
    try testing.expectEqual(@as(?u32, 360), parsed.height);
    try testing.expectEqualStrings("V_MPEG4/ISO/AVC", parsed.codec.?.slice());
}

test "第一条音频轨被跳过；不认识的 element 按 size 跳过" {
    var scratch: [16]u8 = undefined;
    // 音频轨：TrackType 2 + Video 尺寸（坏文件里会有，但不算画面）。
    var audio_entry: [64]u8 = undefined;
    var audio_at: usize = 0;
    audio_at = putElement(&audio_entry, audio_at, &id_track_type, putUint(&scratch, 2));
    audio_at = putElement(&audio_entry, audio_at, &id_codec_id, "A_AAC");
    var audio_video: [16]u8 = undefined;
    var audio_video_at: usize = 0;
    audio_video_at = putElement(&audio_video, audio_video_at, &id_pixel_width, putUint(&scratch, 8));
    audio_at = putElement(&audio_entry, audio_at, &id_video, audio_video[0..audio_video_at]);

    // 视频轨：TrackType 1 + 1280×720。
    var video_entry: [96]u8 = undefined;
    var video_at: usize = 0;
    video_at = putElement(&video_entry, video_at, &id_track_type, putUint(&scratch, 1));
    video_at = putElement(&video_entry, video_at, &id_codec_id, "V_MPEGH/ISO/HEVC");
    var video_dims: [16]u8 = undefined;
    var dims_at: usize = 0;
    dims_at = putElement(&video_dims, dims_at, &id_pixel_width, putUint(&scratch, 1280));
    dims_at = putElement(&video_dims, dims_at, &id_pixel_height, putUint(&scratch, 720));
    video_at = putElement(&video_entry, video_at, &id_video, video_dims[0..dims_at]);

    var tracks: [256]u8 = undefined;
    var tracks_at: usize = 0;
    tracks_at = putElement(&tracks, tracks_at, &id_track_entry, audio_entry[0..audio_at]);
    tracks_at = putElement(&tracks, tracks_at, &id_track_entry, video_entry[0..video_at]);

    // Info 前面塞一个 Void（0xEC）和一个假 Cluster 头：必须按 size 跳过。
    var info: [64]u8 = undefined;
    var info_at: usize = 0;
    info_at = putElement(&info, info_at, &[_]u8{0xEC}, "void-payload");
    info_at = putElement(&info, info_at, &id_duration, putF32(&scratch, 1500.0));

    var file: [1024]u8 = undefined;
    const bytes = putHeader(&file, info[0..info_at], tracks[0..tracks_at]);

    const parsed = try mkv_info.parse(bytes);
    try testing.expectEqual(@as(?u32, 1280), parsed.width);
    try testing.expectEqual(@as(?u32, 720), parsed.height);
    try testing.expectEqualStrings("V_MPEGH/ISO/HEVC", parsed.codec.?.slice());
    try testing.expectEqual(@as(?u64, 1500), parsed.duration_ms);
}

test "非 EBML / 只有 EBML 头：具名错误或空结果，不 panic" {
    try testing.expectError(error.NotMatroska, mkv_info.parse("RIFF"));
    try testing.expectError(error.NotMatroska, mkv_info.parse(""));

    var file: [64]u8 = @splat(0);
    const total = putElement(&file, 0, &id_ebml, "");
    const parsed = try mkv_info.parse(file[0..total]);
    try testing.expectEqual(@as(?u64, null), parsed.duration_ms);
    try testing.expectEqual(@as(?u32, null), parsed.width);

    // 窗口在 Segment 中间被截断：能读多少算多少，不越界。
    var cut: [24]u8 = @splat(0);
    const at = putElement(&cut, 0, &id_ebml, "");
    @memcpy(cut[at..][0..4], &id_segment);
    cut[at + 4] = 0x90; // 声明 16 字节，实际只剩 14
    const truncated = try mkv_info.parse(cut[0..24]);
    try testing.expectEqual(@as(?u64, null), truncated.duration_ms);
}
