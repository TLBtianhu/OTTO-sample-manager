//! WAV 的**帧数 / 时长**：只看 `wav_header.Header` 里的容器事实，不碰负载。
//!
//! 为什么不能一律 `data_size / 一帧字节数`：ADPCM 的 `data` 是**块**的序列，
//! 每块开头有解码器状态（IMA 每声道 4 字节、MS 每声道 7 字节），这些字节不产生
//! 样本；4 位样本又让"一帧多少字节"变成 0（`bits / 8 == 0`）。所以 G.711 与
//! ADPCM 各自有明确的帧数公式，全部是整数的容器算术：
//!
//! ```text
//! PCM / float          frames = data_size / (channels * bits/8)
//! A-law / µ-law        frames = data_size / channels          （1 字节/样本）
//! IMA ADPCM (0x11)     hb    = 4 * channels                   （每块头字节）
//!                      spb   = 1 + (block_align - hb) * 2 / channels
//!                      frames = 完整块数 * spb + 末块残量
//! MS ADPCM  (0x02)     hb    = 7 * channels
//!                      spb   = 2 + (block_align - hb) * 2 / channels
//!                      frames = 完整块数 * spb + 末块残量
//! ```
//!
//! `* 2` 是因为 4 位样本：块头之后的每个字节装 2 个样本（`/ channels` 是因为
//! 多声道时每声道的字节按组交错）。`+1` / `+2` 是块头里自带的初始样本。
//!
//! 末块残量：`rem = data_size % block_align`，只有 `rem` 超过块头时才有样本：
//!
//! ```text
//! IMA: rem > hb ? 1 + (rem - hb) * 2 / channels : 0
//! MS : rem > hb ? 2 + (rem - hb) * 2 / channels : 0
//! ```
//!
//! 这些值是容器算出来的**精确**帧数（`estimated = false`）：它们就是解码器按
//! 标准块布局会交出的帧数。`data_size` 已在 `probe` 里用 `stat` 核对过，不会
//! 比文件实际长度大。
//!
//! 本文件是纯算术：不读文件、不分配、不 import 任何平台模块。

const std = @import("std");
const wav_header = @import("otto_wav_header");

pub const Error = error{
    /// 这些编码没有块/帧公式（或 `frameBytes` 算出了 0）。
    UnsupportedCodec,
    /// ADPCM 的 `block_align` 装不下块头。
    BadBlockAlign,
    /// 帧数 × 1000 超出 u64（只可能来自坏得离谱的 data_size）。
    Overflow,
};

/// ADPCM 一个块能解出的样本数（每声道）。其他 codec 没有"块"的概念，返回错误。
pub fn samplesPerBlock(header: wav_header.Header) Error!u64 {
    const channels: u64 = header.channels;
    const block_align: u64 = header.block_align;
    switch (header.codec) {
        .ima_adpcm => {
            const header_bytes = 4 * channels;
            if (block_align <= header_bytes) return error.BadBlockAlign;
            return 1 + (block_align - header_bytes) * 2 / channels;
        },
        .ms_adpcm => {
            const header_bytes = 7 * channels;
            if (block_align <= header_bytes) return error.BadBlockAlign;
            return 2 + (block_align - header_bytes) * 2 / channels;
        },
        .pcm, .float, .alaw, .mulaw => return error.UnsupportedCodec,
    }
}

/// 容器声明的 `data` 会解出的帧数。
pub fn frameCount(header: wav_header.Header) Error!u64 {
    switch (header.codec) {
        .pcm, .float => {
            // 校验过的 PCM 位深保证 frameBytes 非 0；仍显式挡一次，避免以后
            // 放宽位深时静默除零。
            const frame_bytes = header.frameBytes();
            if (frame_bytes == 0) return error.UnsupportedCodec;
            return header.data_size / frame_bytes;
        },
        .alaw, .mulaw => return header.data_size / @as(u64, header.channels),
        .ima_adpcm, .ms_adpcm => return blockFrameCount(header),
    }
}

fn blockFrameCount(header: wav_header.Header) Error!u64 {
    const channels: u64 = header.channels;
    const header_bytes: u64 = switch (header.codec) {
        .ima_adpcm => 4 * channels,
        .ms_adpcm => 7 * channels,
        else => unreachable,
    };
    const block_align: u64 = header.block_align;
    if (block_align <= header_bytes) return error.BadBlockAlign;

    const per_block = try samplesPerBlock(header);
    const full_blocks = header.data_size / block_align;
    const remainder = header.data_size % block_align;
    const full_frames = std.math.mul(u64, full_blocks, per_block) catch
        return error.Overflow;

    if (remainder <= header_bytes) return full_frames;
    const first: u64 = if (header.codec == .ima_adpcm) 1 else 2;
    const tail = first + (remainder - header_bytes) * 2 / channels;
    return std.math.add(u64, full_frames, tail) catch error.Overflow;
}

/// 时长（毫秒，向下取整）。容器能算出帧数就一定能算出毫秒。
pub fn durationMs(header: wav_header.Header) Error!u64 {
    const frames = try frameCount(header);
    const scaled = std.math.mul(u64, frames, 1000) catch return error.Overflow;
    return scaled / header.sample_rate;
}

// ---------------------------------------------------------------------------
// 测试：纯 Header 字面量，不碰磁盘
// ---------------------------------------------------------------------------

const testing = std.testing;

fn makeHeader(
    codec: wav_header.Codec,
    channels: u16,
    block_align: u16,
    data_size: u64,
) wav_header.Header {
    return .{
        .sample_rate = 44_100,
        .channels = channels,
        .bits = switch (codec) {
            .ima_adpcm, .ms_adpcm => 4,
            .alaw, .mulaw => 8,
            .float => 32,
            .pcm => 16,
        },
        .codec = codec,
        .format_tag = 0,
        .block_align = block_align,
        .data_offset = 0,
        .data_size = data_size,
    };
}

test "PCM / float：仍按帧字节数除，与旧 probe 结果一致" {
    const pcm = makeHeader(.pcm, 2, 4, 352_800); // 2ch × 16bit × 5s
    try testing.expectEqual(@as(u64, 88_200), try frameCount(pcm));
    try testing.expectEqual(@as(u64, 2000), try durationMs(pcm));

    const float = makeHeader(.float, 1, 4, 176_400); // 1ch × float32 × 1s
    try testing.expectEqual(@as(u64, 44_100), try frameCount(float));
    try testing.expectEqual(@as(u64, 1000), try durationMs(float));
}

test "G.711：1 字节/样本，帧数 = data_size / channels" {
    const cases = [_]struct {
        codec: wav_header.Codec,
        channels: u16,
        data_size: u64,
        frames: u64,
    }{
        .{ .codec = .alaw, .channels = 1, .data_size = 16_000, .frames = 16_000 },
        .{ .codec = .mulaw, .channels = 1, .data_size = 16_000, .frames = 16_000 },
        .{ .codec = .alaw, .channels = 2, .data_size = 16_000, .frames = 8_000 },
        .{ .codec = .mulaw, .channels = 2, .data_size = 16_001, .frames = 8_000 },
    };
    for (cases) |case| {
        const header = makeHeader(case.codec, case.channels, case.channels, case.data_size);
        try testing.expectEqual(case.frames, try frameCount(header));
    }

    var header = makeHeader(.alaw, 1, 1, 16_000);
    header.sample_rate = 8_000;
    try testing.expectEqual(@as(u64, 2000), try durationMs(header));
}

test "IMA ADPCM：每块 2041 样本（1024 字节 / 单声道），44 块 = 2036 ms" {
    const header = makeHeader(.ima_adpcm, 1, 1024, 45_056);
    try testing.expectEqual(@as(u64, 2041), try samplesPerBlock(header));
    try testing.expectEqual(@as(u64, 89_804), try frameCount(header));
    try testing.expectEqual(@as(u64, 2036), try durationMs(header));

    // 立体声：块头 8 字节，样本数 (1024-8)*2/2 + 1。
    const stereo = makeHeader(.ima_adpcm, 2, 1024, 2048);
    try testing.expectEqual(@as(u64, 1017), try samplesPerBlock(stereo));
    try testing.expectEqual(@as(u64, 2034), try frameCount(stereo));
}

test "MS ADPCM：每块 2036 样本（1024 字节 / 单声道），44 块 = 2031 ms" {
    const header = makeHeader(.ms_adpcm, 1, 1024, 45_056);
    try testing.expectEqual(@as(u64, 2036), try samplesPerBlock(header));
    try testing.expectEqual(@as(u64, 89_584), try frameCount(header));
    try testing.expectEqual(@as(u64, 2031), try durationMs(header));
}

test "ADPCM 末块残量：完整块 + 残块按块头之后的字节算" {
    // IMA：1024 + 100 字节残块 = 4 字节块头 + 96 字节数据 = 1 + 192 样本。
    const ima = makeHeader(.ima_adpcm, 1, 1024, 1024 + 100);
    try testing.expectEqual(@as(u64, 2041 + 193), try frameCount(ima));

    // MS：1024 + 100 字节残块 = 7 字节块头 + 93 字节 = 2 + 186 样本。
    const ms = makeHeader(.ms_adpcm, 1, 1024, 1024 + 100);
    try testing.expectEqual(@as(u64, 2036 + 188), try frameCount(ms));

    // 残块不足以装下块头：不产生样本，只算完整块。
    const ima_short = makeHeader(.ima_adpcm, 1, 1024, 1024 + 4);
    try testing.expectEqual(@as(u64, 2041), try frameCount(ima_short));
    const ms_short = makeHeader(.ms_adpcm, 1, 1024, 1024 + 7);
    try testing.expectEqual(@as(u64, 2036), try frameCount(ms_short));
}

test "ADPCM 块头装不下 / 非块编码：具名错误" {
    const ima_tiny = makeHeader(.ima_adpcm, 2, 8, 1024);
    try testing.expectError(error.BadBlockAlign, samplesPerBlock(ima_tiny));
    const ms_tiny = makeHeader(.ms_adpcm, 1, 7, 1024);
    try testing.expectError(error.BadBlockAlign, samplesPerBlock(ms_tiny));
    try testing.expectError(error.UnsupportedCodec, samplesPerBlock(makeHeader(.pcm, 1, 2, 4)));
}
