//! Matroska / WebM（EBML）容器头解析：只读 Segment 里的 `Info` 与 `Tracks`，
//! **不解码任何一帧**。
//!
//! 读的全是元数据：
//!   * `Segment` → `Info`：`TimecodeScale`（默认 1,000,000 ns）与 `Duration`
//!     （浮点，单位是 TimecodeScale）；毫秒 = Duration × scale / 1e6；
//!   * `Segment` → `Tracks` → `TrackEntry`：`TrackType`（1 = 视频）、
//!     `CodecID`（`V_MPEG4/ISO/AVC` 这种字符串）、`Video` → `PixelWidth`/`PixelHeight`。
//!
//! EBML 的 element 是"ID + vint 长度 + 负载"：
//!   * ID 的长度由首字节前导零的个数决定（1–4 字节，marker 位保留在值里）；
//!   * 长度的长度同理（1–8 字节），去掉 marker 位就是负载字节数；全 1 表示
//!     长度未知（`Segment` 用得多），这时负载就是"到窗口尾"。
//!
//! 遍历是顺序的：认识的 element 解析，不认识的按 size 跳过——`Cluster`（真正
//! 的帧数据）永远不会被读进来，因为 `Info` / `Tracks` 在所有 muxer 里都写在它
//! 前面，而且窗口只有 64 KiB。跳过的依据是 size，不是逐个字节扫描。
//!
//! 本文件是纯字节解析：不读文件、不分配、不 import 任何平台模块。

const std = @import("std");
const codec_text = @import("codec_text.zig");

pub const Error = error{
    /// 前 4 字节不是 EBML 的 `1A 45 DF A3`。
    NotMatroska,
};

pub const Info = struct {
    /// 容器声明的时长（毫秒，四舍五入到整毫秒）。null = Info 里没写 Duration。
    duration_ms: ?u64 = null,
    width: ?u32 = null,
    height: ?u32 = null,
    /// `CodecID`（`V_MPEG4/ISO/AVC`），定长 16 字节，超长截断。
    codec: ?codec_text.CodecText = null,
};

/// 单个容器里最多看多少个 element。正常文件是几十个；上限只防止病态文件。
const max_elements: u32 = 512;

/// 已知的 element ID（EBML ID 本身含 marker 位，这里按原值写）。
const id_ebml: u32 = 0x1A45DFA3;
const id_segment: u32 = 0x18538067;
const id_info: u32 = 0x1549A966;
const id_timecode_scale: u32 = 0x2AD7B1;
const id_duration: u32 = 0x4489;
const id_tracks: u32 = 0x1654AE6B;
const id_track_entry: u32 = 0xAE;
const id_track_type: u32 = 0x83;
const id_codec_id: u32 = 0x86;
const id_video: u32 = 0xE0;
const id_pixel_width: u32 = 0xB0;
const id_pixel_height: u32 = 0xBA;

const Element = struct {
    id: u32,
    body: []const u8,
};

/// 解析文件头窗口。`bytes` 至少要从 EBML 头开始；不够长时按"读到这里为止"处理，
/// 不会越界（窗口被截断时 `Info` / `Tracks` 仍然能拿到）。
pub fn parse(bytes: []const u8) Error!Info {
    if (bytes.len < 4 or !std.mem.eql(u8, bytes[0..4], "\x1A\x45\xDF\xA3")) {
        return error.NotMatroska;
    }

    const info = Info{};
    var at: usize = 0;
    var guard: u32 = 0;
    while (at < bytes.len and guard < max_elements) : (guard += 1) {
        const element = readElement(bytes, &at) orelse break;
        if (element.id == id_segment) return parseSegment(element.body);
    }
    // 窗口里连 Segment 都没走到：不是错误，只是"还没看到"。
    return info;
}

fn parseSegment(body: []const u8) Info {
    var info = Info{};
    var at: usize = 0;
    var guard: u32 = 0;
    while (at < body.len and guard < max_elements) : (guard += 1) {
        const element = readElement(body, &at) orelse break;
        if (element.id == id_info) {
            parseInfoElement(&info, element.body);
        } else if (element.id == id_tracks) {
            const track = parseTracks(element.body);
            if (track.video) {
                info.width = track.width;
                info.height = track.height;
                info.codec = track.codec;
            }
        }
        // SeekHead / Cues / Cluster …：readElement 已按 size 跳过。
    }
    return info;
}

/// `Info`：TimecodeScale 与 Duration 谁先出现都行，所以先都收下来再换算。
fn parseInfoElement(info: *Info, body: []const u8) void {
    var scale: u64 = 1_000_000;
    var duration: ?f64 = null;
    var at: usize = 0;
    var guard: u32 = 0;
    while (at < body.len and guard < max_elements) : (guard += 1) {
        const element = readElement(body, &at) orelse break;
        if (element.id == id_timecode_scale) {
            scale = readUint(element.body) orelse scale;
        } else if (element.id == id_duration) {
            duration = readFloat(element.body);
        }
    }
    const value = duration orelse return;
    if (!(value > 0)) return;
    if (scale == 0) return;
    const milliseconds = value * @as(f64, @floatFromInt(scale)) / 1_000_000.0;
    if (!(milliseconds > 0) or milliseconds >= 1e15) return;
    info.duration_ms = @intFromFloat(@round(milliseconds));
}

const Track = struct {
    video: bool = false,
    width: ?u32 = null,
    height: ?u32 = null,
    codec: ?codec_text.CodecText = null,
};

/// 找第一条视频轨。音频轨（TrackType 2）、字幕轨直接跳过，不影响结果。
fn parseTracks(body: []const u8) Track {
    var at: usize = 0;
    var guard: u32 = 0;
    while (at < body.len and guard < max_elements) : (guard += 1) {
        const element = readElement(body, &at) orelse break;
        if (element.id != id_track_entry) continue;
        const track = parseTrackEntry(element.body);
        if (track.video) return track;
    }
    return .{};
}

fn parseTrackEntry(body: []const u8) Track {
    var track = Track{};
    var track_type: u64 = 0;
    var at: usize = 0;
    var guard: u32 = 0;
    while (at < body.len and guard < max_elements) : (guard += 1) {
        const element = readElement(body, &at) orelse break;
        if (element.id == id_track_type) {
            track_type = readUint(element.body) orelse 0;
        } else if (element.id == id_codec_id) {
            if (element.body.len > 0) track.codec = codec_text.CodecText.init(element.body);
        } else if (element.id == id_video) {
            const size = parseVideo(element.body);
            track.width = size.width;
            track.height = size.height;
        }
    }
    track.video = track_type == 1;
    return track;
}

/// `Video`：PixelWidth / PixelHeight。0 视为没写。
fn parseVideo(body: []const u8) struct { width: ?u32, height: ?u32 } {
    var width: ?u32 = null;
    var height: ?u32 = null;
    var at: usize = 0;
    var guard: u32 = 0;
    while (at < body.len and guard < max_elements) : (guard += 1) {
        const element = readElement(body, &at) orelse break;
        if (element.id == id_pixel_width) {
            width = readU32(element.body);
        } else if (element.id == id_pixel_height) {
            height = readU32(element.body);
        }
    }
    return .{ .width = width, .height = height };
}

// ---------------------------------------------------------------------------
// EBML 原语
// ---------------------------------------------------------------------------

/// 读一个 element 并前进 `at`。窗口不够、ID/长度非法都返回 null（遍历结束）。
/// 声明的长度超过窗口时只交出剩下的字节：`Info` / `Tracks` 的字段都在前面。
fn readElement(bytes: []const u8, at: *usize) ?Element {
    const id = readId(bytes, at.*) orelse return null;
    var cursor = at.* + id.len;
    const size = readSize(bytes, cursor) orelse return null;
    cursor += size.len;
    if (cursor > bytes.len) return null;
    const body_len: usize = if (size.unknown)
        bytes.len - cursor
    else
        @intCast(@min(size.value, bytes.len - cursor));
    at.* = cursor + body_len;
    return .{ .id = id.value, .body = bytes[cursor..][0..body_len] };
}

fn readId(bytes: []const u8, at: usize) ?struct { value: u32, len: u4 } {
    if (at >= bytes.len) return null;
    const first = bytes[at];
    if (first == 0) return null;
    const len: u4 = @intCast(@clz(first) + 1);
    if (at + len > bytes.len) return null;
    var value: u32 = 0;
    for (bytes[at..][0..len]) |byte| value = (value << 8) | byte;
    return .{ .value = value, .len = len };
}

fn readSize(bytes: []const u8, at: usize) ?struct { value: u64, len: u4, unknown: bool } {
    if (at >= bytes.len) return null;
    const first = bytes[at];
    if (first == 0) return null;
    const len: u4 = @intCast(@clz(first) + 1);
    if (at + len > bytes.len) return null;
    const marker: u32 = @as(u32, 0xFF) >> @intCast(len);
    const mask: u8 = @intCast(marker);
    var value: u64 = first & mask;
    var unknown = (first & mask) == mask;
    for (bytes[at + 1 ..][0 .. len - 1]) |byte| {
        value = (value << 8) | byte;
        if (byte != 0xFF) unknown = false;
    }
    return .{ .value = value, .len = len, .unknown = unknown };
}

/// 大端无符号整数（EBML uint）。0 或超过 8 字节返回 null。
fn readUint(bytes: []const u8) ?u64 {
    if (bytes.len == 0 or bytes.len > 8) return null;
    var value: u64 = 0;
    for (bytes) |byte| value = (value << 8) | byte;
    return value;
}

fn readU32(bytes: []const u8) ?u32 {
    const value = readUint(bytes) orelse return null;
    if (value == 0 or value > std.math.maxInt(u32)) return null;
    return @intCast(value);
}

/// EBML float：4 或 8 字节 IEEE-754 大端。
fn readFloat(bytes: []const u8) ?f64 {
    if (bytes.len == 4) {
        const bits = @as(u32, @intCast(readUint(bytes) orelse return null));
        return @floatCast(@as(f32, @bitCast(bits)));
    }
    if (bytes.len == 8) {
        const bits = readUint(bytes) orelse return null;
        return @bitCast(bits);
    }
    return null;
}
