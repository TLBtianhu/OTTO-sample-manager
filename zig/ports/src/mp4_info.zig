//! MP4 / MOV（ISO BMFF）容器头解析：只走 box 结构，**不解码任何一帧**。
//!
//! 读的全是元数据：
//!   * `moov` → `mvhd`：文件级 timescale / duration（时长的主答案）；
//!   * `moov` → `trak` → `tkhd`：宽高（16.16 定点，高 16 位是整数像素）；
//!   * `trak` → `mdia` → `mdhd`：轨自己的 timescale / duration（`mvhd` 没写时兜底）；
//!   * `mdia` → `hdlr`：`vide` / `soun`——只有视频轨的 `tkhd` 才是画面尺寸；
//!   * `mdia` → `minf` → `stbl` → `stsd`：第一条样本项的编码 fourcc（`avc1`/`hvc1`）。
//!
//! Box 头支持 32 位 size、`size == 1` 时跟 8 字节 largesize、`size == 0` 时表示
//! "到文件尾"。声明的 size 比手上窗口大，只交出剩下的那段并停止遍历——永远不会
//! 因为一个坏 size 读越界或死循环。
//!
//! ## `moov` 在文件尾部（ffmpeg 的默认布局）
//!
//! `parse(bytes)` 只看调用方给的窗口（probe 给的是文件头 64 KiB）。`moov` 在
//! `mdat` 之后时窗口里只有 `ftyp` + `mdat` 头，`parse` 什么也拿不到。这时用
//! `seek`：从偏移 0 开始，每次只读 16 字节 box 头，按 size 跳到下一个 top-level
//! box；只有跳到 `moov` 才把它那**一段**读进来。`mdat` 的负载一个字节都不读，
//! 也不把整个文件读进内存。
//!
//! `moov` 的读取本身封顶（`max_moov_bytes`）：正常文件只有几 KiB，封顶只是不让
//! 一个手写的巨大 moov 撑爆内存；超出的部分不解析，而第一条视频轨的字段都在最前面。
//!
//! `parse` / `parseMoov` 是纯字节函数（不读文件、不分配），可以脱离磁盘单测；
//! 只有 `seek` 碰文件读 API。
//!
//! 本文件不 import core、不 import 任何平台模块。

const std = @import("std");
const codec_text = @import("codec_text.zig");

/// 从文件尾部跳过去读 moov 时的缓冲区上限（1 MiB）。
pub const max_moov_bytes: usize = 1 << 20;

/// 最多跳多少个 top-level box。正常文件只有 3–6 个（ftyp / mdat / moov），
/// 上限只用来防止有人拿一串 8 字节空 box 拖住 probe。
const max_hops: u32 = 64;

pub const Info = struct {
    /// 容器声明的时长（毫秒，向下取整）。null = 没找到 / 声明为未知。
    duration_ms: ?u64 = null,
    width: ?u32 = null,
    height: ?u32 = null,
    /// 编码 fourcc（`avc1` / `hvc1` / …），定长复制，不指向任何缓冲区。
    codec: ?codec_text.CodecText = null,
};

/// 一个 box 头。`size` 是含头部的总长度；0 = 到文件尾。
pub const Header = struct {
    kind: [4]u8,
    size: u64,
    header_len: u8,
};

/// 读一个 box 头。窗口不够（含 64 位 largesize 的 16 字节）时返回 null；
/// 声明 size 小于头部本身也是 null——那是坏 box，不是"小 box"。
pub fn readHeader(bytes: []const u8) ?Header {
    if (bytes.len < 8) return null;
    const short = be32(bytes);
    var kind: [4]u8 = undefined;
    @memcpy(&kind, bytes[4..8]);
    if (short == 1) {
        if (bytes.len < 16) return null;
        const large = be64(bytes[8..]);
        if (large < 16) return null;
        return .{ .kind = kind, .size = large, .header_len = 16 };
    }
    if (short != 0 and short < 8) return null;
    return .{ .kind = kind, .size = short, .header_len = 8 };
}

pub const SeekError = std.Io.File.ReadPositionalError || std.mem.Allocator.Error;

/// 按 box 偏移找 `moov`：从文件头开始逐个跳过 top-level box，只读 moov 那一段。
///
/// 返回 null = 文件里没有 moov / 声明的 size 超过文件大小（截断）/ 跳够次数。
/// 不读 `mdat` 负载：跳过一个 box 只需要它的 size。
pub fn seek(
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    file_size: u64,
) SeekError!?Info {
    const scratch = try allocator.alloc(u8, max_moov_bytes);
    defer allocator.free(scratch);

    var offset: u64 = 0;
    var hops: u32 = 0;
    while (offset + 8 <= file_size and hops < max_hops) : (hops += 1) {
        var raw: [16]u8 = undefined;
        const want: usize = @intCast(@min(@as(u64, raw.len), file_size - offset));
        const got = try file.readPositionalAll(io, raw[0..want], offset);
        const header = readHeader(raw[0..got]) orelse return null;
        const header_len: u64 = header.header_len;
        if (header.size != 0 and header.size < header_len) return null;
        const total: u64 = if (header.size == 0) file_size - offset else header.size;

        if (kindIs(header.kind, "moov")) {
            if (total < header_len) return null;
            const body_len: usize = @intCast(@min(total - header_len, scratch.len));
            const read = try file.readPositionalAll(io, scratch[0..body_len], offset + header_len);
            return parseMoov(scratch[0..read]);
        }
        // 声明比文件还大 = 截断 / 头在撒谎：不再往深处跳。
        if (total > file_size - offset) return null;
        offset += total;
    }
    return null;
}

/// 解析一段从 box 边界开始的字节（整份文件，或头部窗口）。只认 moov。
pub fn parse(bytes: []const u8) Info {
    var rest = bytes;
    while (nextBox(&rest)) |box| {
        if (kindIs(box.kind, "moov")) return parseMoov(box.body);
    }
    return .{};
}

/// 解析 `moov` 的**负载**（第一个字节是它第一个子 box 的头）。
pub fn parseMoov(payload: []const u8) Info {
    var info = Info{};
    var rest = payload;
    while (nextBox(&rest)) |box| {
        if (kindIs(box.kind, "mvhd")) {
            info.duration_ms = parseMvhd(box.body);
        } else if (kindIs(box.kind, "trak")) {
            const track = parseTrak(box.body);
            if (!track.video) continue;
            if (info.width == null) info.width = track.width;
            if (info.height == null) info.height = track.height;
            if (info.codec == null) info.codec = track.codec;
            if (info.duration_ms == null) info.duration_ms = track.duration_ms;
        }
    }
    return info;
}

// ---------------------------------------------------------------------------
// box 遍历
// ---------------------------------------------------------------------------

const Box = struct {
    kind: [4]u8,
    body: []const u8,
};

/// 取出 `rest` 开头的一个 box 并把它从 `rest` 里摘掉。声明的 size 大于窗口时
/// 只把剩下的字节当 body 交出去，同时清空 `rest`（遍历到此为止）。
fn nextBox(rest: *[]const u8) ?Box {
    const header = readHeader(rest.*) orelse return null;
    const header_len: usize = header.header_len;
    const declared: u64 = if (header.size == 0) rest.*.len else header.size;
    const total: usize = if (declared > rest.*.len) rest.*.len else @intCast(declared);
    if (total < header_len) return null;
    const body = rest.*[header_len..total];
    rest.* = if (total == rest.*.len) &.{} else rest.*[total..];
    return .{ .kind = header.kind, .body = body };
}

fn kindIs(kind: [4]u8, name: *const [4]u8) bool {
    return std.mem.eql(u8, &kind, name);
}

// ---------------------------------------------------------------------------
// trak / mdia / stbl
// ---------------------------------------------------------------------------

const Track = struct {
    video: bool = false,
    width: ?u32 = null,
    height: ?u32 = null,
    codec: ?codec_text.CodecText = null,
    duration_ms: ?u64 = null,
};

fn parseTrak(body: []const u8) Track {
    var track = Track{};
    var rest = body;
    while (nextBox(&rest)) |box| {
        if (kindIs(box.kind, "tkhd")) {
            const size = parseTkhd(box.body);
            track.width = size.width;
            track.height = size.height;
        } else if (kindIs(box.kind, "mdia")) {
            const media = parseMdia(box.body);
            track.video = media.video;
            track.codec = media.codec;
            track.duration_ms = media.duration_ms;
        }
    }
    return track;
}

fn parseMdia(body: []const u8) Track {
    var track = Track{};
    var rest = body;
    while (nextBox(&rest)) |box| {
        if (kindIs(box.kind, "mdhd")) {
            track.duration_ms = parseMdhd(box.body);
        } else if (kindIs(box.kind, "hdlr")) {
            track.video = isVideoHandler(box.body);
        } else if (kindIs(box.kind, "minf")) {
            track.codec = parseMinf(box.body);
        }
    }
    return track;
}

fn parseMinf(body: []const u8) ?codec_text.CodecText {
    var rest = body;
    while (nextBox(&rest)) |box| {
        if (kindIs(box.kind, "stbl")) return parseStbl(box.body);
    }
    return null;
}

fn parseStbl(body: []const u8) ?codec_text.CodecText {
    var rest = body;
    while (nextBox(&rest)) |box| {
        if (kindIs(box.kind, "stsd")) return parseStsd(box.body);
    }
    return null;
}

// ---------------------------------------------------------------------------
// 字段
// ---------------------------------------------------------------------------

/// `mvhd`：v0 的 timescale 在 12、duration 在 16；v1 是 20 / 24（64 位）。
fn parseMvhd(body: []const u8) ?u64 {
    if (body.len < 4) return null;
    if (body[0] == 1) {
        if (body.len < 32) return null;
        const duration = be64(body[24..]);
        if (duration == std.math.maxInt(u64)) return null;
        return durationMs(be32(body[20..]), duration);
    }
    if (body.len < 20) return null;
    const duration = be32(body[16..]);
    if (duration == std.math.maxInt(u32)) return null;
    return durationMs(be32(body[12..]), duration);
}

/// `mdhd`：v0 的 timescale 在 12、duration 在 16；v1 是 20 / 24（64 位）。
fn parseMdhd(body: []const u8) ?u64 {
    if (body.len < 4) return null;
    if (body[0] == 1) {
        if (body.len < 32) return null;
        const duration = be64(body[24..]);
        if (duration == std.math.maxInt(u64)) return null;
        return durationMs(be32(body[20..]), duration);
    }
    if (body.len < 20) return null;
    const duration = be32(body[16..]);
    if (duration == std.math.maxInt(u32)) return null;
    return durationMs(be32(body[12..]), duration);
}

/// `tkhd` 的宽高偏移：v0 在 76/80，v1 在 88/92（多出来的 8+8 是 64 位时间戳）。
const TkhdSize = struct { width: ?u32, height: ?u32 };

fn parseTkhd(body: []const u8) TkhdSize {
    const at: usize = if (body.len > 0 and body[0] == 1) 88 else 76;
    if (body.len < at + 8) return .{ .width = null, .height = null };
    return .{ .width = fixed16(body[at..]), .height = fixed16(body[at + 4 ..]) };
}

/// 16.16 定点 → 整数像素。0 是"tkhd 没写尺寸"（比如未初始化的轨），不是 0×0。
fn fixed16(bytes: []const u8) ?u32 {
    const value = be32(bytes) >> 16;
    return if (value == 0) null else value;
}

/// `hdlr`：version/flags(4) + pre_defined(4) + handler_type(4)。
fn isVideoHandler(body: []const u8) bool {
    return body.len >= 12 and std.mem.eql(u8, body[8..12], "vide");
}

/// `stsd`：fullbox(4) + entry_count(4) + 第一条样本项的 size(4) + fourcc(4)。
fn parseStsd(body: []const u8) ?codec_text.CodecText {
    if (body.len < 16) return null;
    if (be32(body[4..]) == 0) return null;
    return codec_text.CodecText.init(body[12..16]);
}

/// timescale / duration → 毫秒（向下取整）。0 或全 1 都是"没写"，null 而不是 0。
fn durationMs(timescale: u32, duration: u64) ?u64 {
    if (timescale == 0 or duration == 0) return null;
    const scaled = std.math.mul(u64, duration, 1000) catch return null;
    return scaled / timescale;
}

fn be32(bytes: []const u8) u32 {
    return (@as(u32, bytes[0]) << 24) | (@as(u32, bytes[1]) << 16) |
        (@as(u32, bytes[2]) << 8) | @as(u32, bytes[3]);
}

fn be64(bytes: []const u8) u64 {
    return (@as(u64, be32(bytes)) << 32) | @as(u64, be32(bytes[4..]));
}
