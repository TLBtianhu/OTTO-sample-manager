//! Ogg 容器的最小只读解析：认 Vorbis、谢绝 Opus、从**最后一页的 granule** 取时长。
//!
//! ## 为什么时长在文件尾
//!
//! Vorbis 的 PCM 帧数不写在任何头里。Ogg 规范把音频流的 granule position 定义成
//! "到这一页为止已完成解码的 PCM 帧数"，所以**最后一页**的 granule 就是总帧数
//! （识别头 / 注释 / setup 三页的 granule 都是 0）。probe 因此读两次：
//!
//!   1. 开头 64 KiB：`OggS` 页头 → segment table → 首包；`\x01vorbis` 给出声道数
//!      与采样率；`OpusHead` 直接返回 null（不是 Vorbis，本口岸不支持）；
//!   2. 结尾 64 KiB：从后往前找 `OggS`，只接受"页头声明的总长刚好到文件末"的
//!      候选，解析它的 granule。中间一页都不读，也不整份读。
//!
//! ## 为什么"页末 == 文件末"这一条是必须的
//!
//! 音频负载里完全可能恰好出现四个字节 `OggS`；只按魔数找会把它当成页头，拿它
//! 后面 8 个字节当 granule，得到一个荒谬的时长。一页的长度由页头的 segment
//! table 唯一确定（27 + segment 数 + 各 segment 之和），所以候选必须满足
//! `页起点 + 页长 == 文件大小`——负载里的假魔数几乎不可能同时满足这个等式。
//! 一页最大 27 + 255 + 255×255 = 65307 字节 < 64 KiB，所以"最后 64 KiB"一定
//! 含最后一页的页头；窗口从文件中间开始时也不影响，字节偏移由调用方一起传进来。
//!
//! 尾页 granule 是 `0xFFFF_FFFF_FFFF_FFFF`（"这一页没有包结束"）时不猜，返回
//! null；截断（页长超过文件末）、非 Vorbis、坏页头同样返回 null——probe 的契约
//! 是"不认识就 null"，不是"猜一个 0 秒"。
//!
//! 本文件只碰字节与文件句柄，不 import core、不认识 `Sample`，也不做解码。

const std = @import("std");

/// 一页的上限：页头 27 + segment table 255 + 255 个 255 字节的段。
pub const max_page_bytes: usize = 27 + 255 + 255 * 255;

/// probe 读尾的窗口。必须 ≥ `max_page_bytes`，否则最后一页的页头可能落在窗口外。
pub const tail_window: usize = 64 * 1024;

/// 页头的固定部分：`OggS` + 版本 + flags + granule(8) + serial(4) + seq(4) + crc(4) + 段数。
const page_header_len: usize = 27;

/// "这一页没有包结束"的 granule 标记（Ogg 规范里的 -1）。
const no_granule: u64 = std.math.maxInt(u64);

/// 首包给出的流参数。`sample_rate` 是 Vorbis 识别包里的声明值。
pub const Head = struct {
    sample_rate: u32,
    channels: u32,
};

/// `read` 的完整答案：头部的参数 + 尾页的帧数 + 由两者算出的时长。
pub const Info = struct {
    sample_rate: u32,
    channels: u32,
    /// 最后一页的 granule：Vorbis 里它就是总 PCM 帧数。
    total_frames: u64,
    /// `total_frames * 1000 / sample_rate`，向下取整。
    duration_ms: u64,
};

/// 一次 `read` 可能失败的地方：`stat` / 位置读 / 唯一的 64 KiB 缓冲。
/// "不是 Vorbis / 截断 / 没有 granule"不是错误，是 `null`。
pub const Error = std.Io.File.StatError || std.Io.File.ReadPositionalError || error{OutOfMemory};

/// 读一次头 + 一次尾，给出 Vorbis 的精确时长。返回 null = 不是 Vorbis（Opus 或
/// 别的 codec）、坏页头、截断、或尾页没有 granule——一律不猜。
///
/// `header` 是调用方已经读进来的文件开头（probe 的 64 KiB 窗口，短文件就是全文）。
pub fn read(
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    header: []const u8,
) Error!?Info {
    const head = parseHead(header) orelse return null;

    const size = (try file.stat(io)).size;
    const window: usize = @intCast(@min(size, @as(u64, tail_window)));
    const tail = try allocator.alloc(u8, window);
    defer allocator.free(tail);
    const got = try file.readPositionalAll(io, tail, size - window);

    const granule = lastGranule(tail[0..got], size - got, size) orelse return null;
    const duration_ms = durationMs(granule, head.sample_rate) orelse return null;
    return .{
        .sample_rate = head.sample_rate,
        .channels = head.channels,
        .total_frames = granule,
        .duration_ms = duration_ms,
    };
}

/// 首包是 Vorbis 识别包时给出声道数与采样率；Opus / 别的 codec / 坏页头 → null。
///
/// Vorbis 识别包（规范 §4.2.2）：`\x01vorbis` + version(4) + channels(1) +
/// sample_rate(4) + 三个 bitrate(4) + blocksize(1) + framing(1)，共 30 字节。
pub fn parseHead(header: []const u8) ?Head {
    const page = parsePage(header) orelse return null;
    // 识别包必须独占 BOS 页；不是 BOS（或续页）就不是流的第一页。
    if (page.flags & flag_bos == 0) return null;
    if (page.flags & flag_continued != 0) return null;

    const packet = firstPacket(header, page) orelse return null;
    if (packet.len < 16) return null;
    if (packet[0] != 1 or !std.mem.eql(u8, packet[1..7], "vorbis")) return null;

    const channels = packet[11];
    const sample_rate = std.mem.readInt(u32, packet[12..16], .little);
    if (channels == 0 or sample_rate == 0) return null;
    return .{ .sample_rate = sample_rate, .channels = channels };
}

/// 尾页的 granule = 总帧数。`tail` 是文件最后一段，`tail_offset` 是它在文件里的
/// 偏移（`tail.len + tail_offset == file_size` 由调用方保证）。
///
/// 从后往前扫描：只接受"页起点 + 该页声明的总长 == file_size"的候选——这一条
/// 同时排除了负载里的假 `OggS` 与被截断的尾页。找不到就 null。
pub fn lastGranule(tail: []const u8, tail_offset: u64, file_size: u64) ?u64 {
    if (tail.len < page_header_len) return null;

    var at: usize = tail.len - page_header_len;
    while (true) : (at -= 1) {
        if (std.mem.eql(u8, tail[at..][0..4], "OggS")) {
            if (parsePage(tail[at..])) |page| {
                const page_start = tail_offset + @as(u64, @intCast(at));
                const page_end = page_start + @as(u64, @intCast(page.total_len));
                if (page_end == file_size) {
                    // 尾页没有包结束（-1）时，上一页的 granule 不是"总帧数"。
                    if (page.granule == no_granule) return null;
                    return page.granule;
                }
            }
        }
        if (at == 0) return null;
    }
}

/// 帧数 → 毫秒（向下取整）。采样率为 0 或结果溢出 u64 时 null。
fn durationMs(total_frames: u64, sample_rate: u32) ?u64 {
    if (sample_rate == 0) return null;
    const ms = @as(u128, total_frames) * 1000 / sample_rate;
    if (ms > std.math.maxInt(u64)) return null;
    return @intCast(ms);
}

const flag_continued: u8 = 0x01;
const flag_bos: u8 = 0x02;
const flag_eos: u8 = 0x04;

/// 一页的页头解析结果（不复制负载）。
const Page = struct {
    granule: u64,
    flags: u8,
    /// 页头 + segment table 的字节数。
    header_len: usize,
    /// 整页（页头 + 所有段的负载）的字节数。
    total_len: usize,
};

/// 解析一页的页头。`bytes` 从页起点开始；不足一页时 null（不猜）。
fn parsePage(bytes: []const u8) ?Page {
    if (bytes.len < page_header_len) return null;
    if (!std.mem.eql(u8, bytes[0..4], "OggS")) return null;
    // 版本 0 是唯一发布过的 Ogg 版本；别的值按"不认识"处理。
    if (bytes[4] != 0) return null;

    const segments = bytes[26];
    const header_len = page_header_len + @as(usize, segments);
    if (bytes.len < header_len) return null;

    var body_len: usize = 0;
    for (bytes[page_header_len..header_len]) |lace| body_len += lace;
    return .{
        .granule = std.mem.readInt(u64, bytes[6..14], .little),
        .flags = bytes[5],
        .header_len = header_len,
        .total_len = header_len + body_len,
    };
}

/// 首包（只在本页上完整结束时才返回）；Vorbis/Opus 的识别包都独占 BOS 页。
fn firstPacket(header: []const u8, page: Page) ?[]const u8 {
    if (page.header_len > header.len) return null;
    var packet_len: usize = 0;
    for (header[page_header_len..page.header_len]) |lace| {
        packet_len += lace;
        if (lace < 255) {
            // 包必须落在这页的负载里，且负载已经读进窗口。
            const end = page.header_len + packet_len;
            if (packet_len > page.total_len - page.header_len) return null;
            if (end > header.len) return null;
            return header[page.header_len..end];
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// 测试：内存里造页（真字节），外加两件真素材（存在才跑）
// ---------------------------------------------------------------------------

const testing = std.testing;

/// 造一页：一个包（≤255 字节的整数倍也正确终止）、给定 flags 与 granule。
/// 返回下一页的偏移。`out` 必须够大。
fn putPage(out: []u8, at: usize, flags: u8, granule: u64, packet: []const u8) usize {
    const segments = packet.len / 255 + 1;
    const header_len = page_header_len + segments;
    const total = header_len + packet.len;

    @memset(out[at..][0..total], 0);
    @memcpy(out[at..][0..4], "OggS");
    out[at + 5] = flags;
    std.mem.writeInt(u64, out[at + 6 ..][0..8], granule, .little);
    out[at + 26] = @intCast(segments);

    var remaining = packet.len;
    for (0..segments) |index| {
        const lace: u8 = @intCast(@min(remaining, 255));
        out[at + page_header_len + index] = lace;
        remaining -= lace;
    }
    @memcpy(out[at + header_len ..][0..packet.len], packet);
    return at + total;
}

/// Vorbis 识别包（30 字节）。
fn vorbisIdent(channels: u8, sample_rate: u32) [30]u8 {
    var packet: [30]u8 = @splat(0);
    packet[0] = 1;
    @memcpy(packet[1..7], "vorbis");
    packet[11] = channels;
    std.mem.writeInt(u32, packet[12..16], sample_rate, .little);
    return packet;
}

test "parseHead：Vorbis 识别包给出 44100 / 2 声道" {
    var bytes: [128]u8 = undefined;
    const ident = vorbisIdent(2, 44_100);
    const len = putPage(&bytes, 0, flag_bos, 0, &ident);

    const head = parseHead(bytes[0..len]).?;
    try testing.expectEqual(@as(u32, 44_100), head.sample_rate);
    try testing.expectEqual(@as(u32, 2), head.channels);
}

test "parseHead：Opus / 非 BOS / 短头 / 坏帧全是 null（不猜）" {
    var bytes: [128]u8 = undefined;

    // OpusHead：19 字节的识别包，独占 BOS 页。
    var opus: [19]u8 = @splat(0);
    @memcpy(opus[0..8], "OpusHead");
    opus[8] = 1;
    opus[9] = 2;
    std.mem.writeInt(u16, opus[10..12], 312, .little);
    std.mem.writeInt(u32, opus[12..16], 48_000, .little);
    const opus_len = putPage(&bytes, 0, flag_bos, 0, &opus);
    try testing.expect(parseHead(bytes[0..opus_len]) == null);

    // 不是 BOS：识别包不在流的第一页。
    const ident = vorbisIdent(2, 44_100);
    const mid_len = putPage(&bytes, 0, 0, 0, &ident);
    try testing.expect(parseHead(bytes[0..mid_len]) == null);

    try testing.expect(parseHead(&[_]u8{}) == null);
    try testing.expect(parseHead("OggS") == null);
    try testing.expect(parseHead("RIFFxxxxWAVE") == null);
}

test "lastGranule：尾页 granule = 132300，页末正好到文件末" {
    var bytes: [256]u8 = undefined;
    var at = putPage(&bytes, 0, flag_bos, 0, "ident");
    at = putPage(&bytes, at, 0, 0, "setup");
    at = putPage(&bytes, at, flag_eos, 132_300, "audio-page");

    try testing.expectEqual(@as(u64, 132_300), lastGranule(bytes[0..at], 0, at).?);
}

test "lastGranule：窗口从文件中间开始（尾页头在窗口内）" {
    var bytes: [256]u8 = undefined;
    var at = putPage(&bytes, 0, flag_bos, 0, "ident");
    const last_at = at;
    at = putPage(&bytes, at, flag_eos, 8_820, "audio-page");

    // 窗口从上一页的负载中间开始（不是文件头），偏移量交给调用方。
    const offset: usize = last_at - 5;
    try testing.expectEqual(@as(u64, 8_820), lastGranule(bytes[offset..at], offset, at).?);
}

test "lastGranule：截断 / granule=-1 / 负载里的假 OggS 都不冒充时长" {
    var bytes: [256]u8 = undefined;
    var at = putPage(&bytes, 0, flag_bos, 0, "ident");
    at = putPage(&bytes, at, flag_eos, 4_410, "audio-page");

    // 文件比页头声明的短 10 字节：尾页被截断，上一页的 granule 也不能冒充。
    try testing.expect(lastGranule(bytes[0 .. at - 10], 0, at - 10) == null);

    // 尾页 granule = -1："这一页没有包结束"，不是 0 帧也不是上一页的帧数。
    var pages: [256]u8 = undefined;
    var end = putPage(&pages, 0, flag_bos, 0, "ident");
    end = putPage(&pages, end, flag_eos, no_granule, "no-packet-end");
    try testing.expect(lastGranule(pages[0..end], 0, end) == null);

    // 负载里恰好有 "OggS""：它后面凑不出"页长刚好到文件末"，必须继续往前找。
    var noisy: [512]u8 = undefined;
    var at2 = putPage(&noisy, 0, flag_bos, 0, "ident");
    var payload: [64]u8 = @splat(0);
    @memcpy(payload[20..24], "OggS");
    at2 = putPage(&noisy, at2, flag_eos, 44_100, &payload);
    try testing.expectEqual(@as(u64, 44_100), lastGranule(noisy[0..at2], 0, at2).?);
}

test "真 testkit ogg（存在才跑）：132300 帧 / 44100 / 2 声道 / 3000 ms" {
    const path = "C:\\src\\otto-testkit\\samples\\vorbis-44k.ogg";
    std.Io.Dir.cwd().access(testing.io, path, .{}) catch return error.SkipZigTest;

    const file = try std.Io.Dir.cwd().openFile(testing.io, path, .{});
    defer file.close(testing.io);
    const header = try testing.allocator.alloc(u8, tail_window);
    defer testing.allocator.free(header);
    const got = try file.readPositionalAll(testing.io, header, 0);

    const info = (try read(testing.allocator, testing.io, file, header[0..got])).?;
    try testing.expectEqual(@as(u32, 44_100), info.sample_rate);
    try testing.expectEqual(@as(u32, 2), info.channels);
    try testing.expectEqual(@as(u64, 132_300), info.total_frames);
    try testing.expectEqual(@as(u64, 3000), info.duration_ms);
}

test "真 opus 素材（存在才跑）：OpusHead → null（不支持，不猜）" {
    const path = "C:\\src\\zig-audio-vectors\\ogg\\opus-48k-96.opus";
    std.Io.Dir.cwd().access(testing.io, path, .{}) catch return error.SkipZigTest;

    const file = try std.Io.Dir.cwd().openFile(testing.io, path, .{});
    defer file.close(testing.io);
    const header = try testing.allocator.alloc(u8, tail_window);
    defer testing.allocator.free(header);
    const got = try file.readPositionalAll(testing.io, header, 0);

    try testing.expect((try read(testing.allocator, testing.io, file, header[0..got])) == null);
}
