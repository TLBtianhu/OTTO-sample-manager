//! Ogg 容器的最小只读解析：认 Vorbis 与 Opus（**只取元数据**），时长取
//! **最后一页的 granule**。解码不在这里：Opus 的时长算得出来，声音仍然播不了。
//!
//! ## 为什么时长在文件尾
//!
//! Vorbis 的 PCM 帧数不写在任何头里。Ogg 规范把音频流的 granule position 定义成
//! "到这一页为止已完成解码的 PCM 帧数"，所以**最后一页**的 granule 就是总帧数
//! （识别头 / 注释 / setup 三页的 granule 都是 0）。Opus 遵守同一条规矩，唯一的
//! 差别是它的 granule 把 `pre_skip` 算在里面（见下）。probe 因此读两次：
//!
//!   1. 开头 64 KiB：`OggS` 页头 → segment table → 首包；`\x01vorbis` 给出声道数
//!      与采样率；`OpusHead` 给出 pre_skip / 声道数 / 输入采样率；
//!   2. 结尾 64 KiB：从后往前找 `OggS`，只接受"页头声明的总长刚好到文件末"的
//!      候选，解析它的 granule。中间一页都不读，也不整份读。
//!
//! ## Opus：pre_skip 与恒定的 48 kHz
//!
//! OpusHead（RFC 7845 §5.1）的定长部分，共 19 字节（mapping family > 0 时后面
//! 还有一张声道映射表，本口岸不读）：
//!
//!     "OpusHead"  version  channels  pre_skip(u16)  input_sample_rate(u32)  gain  family
//!         8B         1B        1B          2B                4B             2B      1B
//!
//!   * `pre_skip`（偏移 10）——解码器在**流开头**要丢掉的样本数。一段 2.000 s 的
//!     素材尾页 granule 是 96312 = 96000 + 312，那 312 就是它：granule 从"编码器
//!     上手第一帧之前"开始数，要把预滚的那 312 个样本减掉才是真正要播的长度；
//!   * `input_sample_rate`（偏移 12）——**录制时的**采样率，只作记录（规范允许
//!     写 0 表示未知）。它**不是**输出采样率：Opus 解码器的输出恒为 48 kHz。Opus
//!     只有 8/12/16/24/48 kHz 五种内部时钟，全部以 48 kHz 为基准做重采样，解码器
//!     交付的 PCM 永远是 48 kHz；所以用 44100 之类的值去除 granule 会算出错的时长；
//!   * `channels`（偏移 9）——0 是坏头。
//!
//! 于是 Opus 的时长 = `(尾页 granule − pre_skip) / 48000`。granule < pre_skip 的
//! 文件是坏的（差值是负的），返回 null，绝不把负数折成 0 或者回绕成天文数字。
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
//! null；截断（页长超过文件末）、未知编码、坏页头同样返回 null——probe 的契约
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

/// Opus 的输出采样率：解码器永远按 48 kHz 交付 PCM（见文件头）。
pub const opus_sample_rate: u32 = 48_000;

/// OpusHead 定长部分的字节数（含 8 字节魔数）。
const opus_head_len: usize = 19;

/// 首包认出来的编码。时长口径两者一致（尾页 granule），只是 Opus 要减 pre_skip。
pub const Codec = enum { vorbis, opus };

/// 首包给出的流参数。
pub const Head = struct {
    codec: Codec,
    /// **输出**采样率：Vorbis 是头里的声明值；Opus 恒为 `opus_sample_rate`。
    sample_rate: u32,
    channels: u32,
    /// 只有 Opus 可能非 0：解码开始时要丢掉的样本数（OpusHead 偏移 10）。
    pre_skip: u16 = 0,
    /// 只有 Opus 有：`input_sample_rate`（偏移 12）。**不是**输出采样率，
    /// 只作记录（可能是 0 = 未知）。
    input_sample_rate: u32 = 0,
};

/// `read` 的完整答案：头部的参数 + 尾页算出的帧数 + 由两者算出的时长。
pub const Info = struct {
    codec: Codec,
    sample_rate: u32,
    channels: u32,
    /// 真正要播的 PCM 帧数：Vorbis = 尾页 granule；Opus = granule − pre_skip。
    total_frames: u64,
    /// `total_frames * 1000 / sample_rate`，向下取整。
    duration_ms: u64,
};

/// 一次 `read` 可能失败的地方：`stat` / 位置读 / 唯一的 64 KiB 缓冲。
/// "不认识的编码 / 截断 / 没有 granule / granule < pre_skip"不是错误，是 `null`。
pub const Error = std.Io.File.StatError || std.Io.File.ReadPositionalError || error{OutOfMemory};

/// 读一次头 + 一次尾，给出 Vorbis / Opus 的精确时长。返回 null = 不认识的编码、
/// 坏页头、截断、尾页没有 granule、或 granule 比 pre_skip 还小——一律不猜。
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

    // 尾页定位只有这一份实现：先找"页末 == 文件末"的那一页，再拿它的 granule。
    const granule = lastGranule(tail[0..got], size - got, size) orelse return null;
    const frames = totalFrames(head, granule) orelse return null;
    const duration_ms = durationMs(frames, head.sample_rate) orelse return null;
    return .{
        .codec = head.codec,
        .sample_rate = head.sample_rate,
        .channels = head.channels,
        .total_frames = frames,
        .duration_ms = duration_ms,
    };
}

/// 首包是 Vorbis 识别包或 OpusHead 时给出流参数；别的 codec / 坏页头 → null。
///
/// Vorbis 识别包（规范 §4.2.2）：`\x01vorbis` + version(4) + channels(1) +
/// sample_rate(4) + 三个 bitrate(4) + blocksize(1) + framing(1)，共 30 字节。
pub fn parseHead(header: []const u8) ?Head {
    const page = parsePage(header) orelse return null;
    // 识别包必须独占 BOS 页；不是 BOS（或续页）就不是流的第一页。
    if (page.flags & flag_bos == 0) return null;
    if (page.flags & flag_continued != 0) return null;

    const packet = firstPacket(header, page) orelse return null;
    if (isOpusHead(packet)) return parseOpusHead(packet);

    if (packet.len < 16) return null;
    if (packet[0] != 1 or !std.mem.eql(u8, packet[1..7], "vorbis")) return null;

    const channels = packet[11];
    const sample_rate = std.mem.readInt(u32, packet[12..16], .little);
    if (channels == 0 or sample_rate == 0) return null;
    return .{ .codec = .vorbis, .sample_rate = sample_rate, .channels = channels };
}

/// 首包是不是 `OpusHead`。魔数就够长（8 字节），先做这一条最便宜的判断。
fn isOpusHead(packet: []const u8) bool {
    return packet.len >= 8 and std.mem.eql(u8, packet[0..8], "OpusHead");
}

/// 解析 OpusHead 的定长部分（见文件头）。短头 / 0 声道 → null（不猜）。
/// 采样率**不用**头里声明的 `input_sample_rate`：Opus 的输出恒为 48 kHz。
fn parseOpusHead(packet: []const u8) ?Head {
    if (packet.len < opus_head_len) return null;
    const channels = packet[9];
    if (channels == 0) return null;
    return .{
        .codec = .opus,
        .sample_rate = opus_sample_rate,
        .channels = channels,
        .pre_skip = std.mem.readInt(u16, packet[10..12], .little),
        .input_sample_rate = std.mem.readInt(u32, packet[12..16], .little),
    };
}

/// 尾页 granule → 要播的帧数。Opus 的 granule 含编码器的预滚样本，减掉 pre_skip；
/// 不够减就是坏文件（负数不折成 0，也不回绕）。
fn totalFrames(head: Head, granule: u64) ?u64 {
    if (head.codec == .vorbis) return granule;
    if (granule < head.pre_skip) return null;
    return granule - head.pre_skip;
}

/// 尾页的 granule。`tail` 是文件最后一段，`tail_offset` 是它在文件里的偏移
/// （`tail.len + tail_offset == file_size` 由调用方保证）。
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

// 测试在 `ogg_info_test.zig`（单独一个测试根，同 `mp4_info_test.zig` 的理由：
// 本文件正文要留出行数给注释与解析，也便于把"真素材"那几条集中在一处）。
