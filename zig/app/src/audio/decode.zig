//! zig-audio → `audio/session.Decoded` 的**唯一**解码路径。
//!
//! WAV / FLAC / MP3 / AIFF / Ogg Vorbis 现在都由 vendor 的 zig-audio 解（`vendored
//! v0.10`），`providers/audio.zig`（wasapi-pcm）与 `providers/native_audio.zig` 只差在
//! `supports` 的扩展名表与图标能力——解码循环、声道规则、256/512 MiB 上限、
//! 流式 Reader 必须只有这一份。上一轮的 WAV/FLAC 下混分叉已经证明：两份实现
//! 迟早会在"多声道怎么混、空流算不算成功、时长怎么取整"上漂移。
//!
//! ## 调用链
//!
//! ```
//! audio/file_reader.zig FileReader            ← Win32 句柄 + 64 KiB 缓冲
//! std.Io.Reader（readVec 契约）                ← 库只接受 std.Io.Reader
//! zig_audio.open(allocator, &reader)         ← 按**内容**识别容器
//!   info: format / sample_rate / channels / bits_per_sample / total_frames
//!   loop decoder.read(&chunk)                ← 交错 i16，直到返回 0
//!   >2 声道：audio/downmix.zig 逐块混成双声道（唯一矩阵）
//! 按实际样本数算 frames / duration（不信容器声明）
//! audio/session.build                        ← 峰值/波形/Player 与 MF 共用
//! ```
//!
//! `Info.total_frames` 是**开流时**的声明值：WAV/FLAC/AIFF 打开就有，MP3 通常为
//! null，Ogg Vorbis 也要读到流尾才由库填上。所以缓冲策略不能假设"开头就知道
//! 长度"——`reservePcm` 的估算分支就是为这几种准备的；最终 `frames` 永远按实际
//! 解出的样本数算（日志里 `container_frames` 与 `eof_frames` 各是开流时 / EOF 时
//! 的声明值，Vorbis 正好是 `null` → 真值）。
//!
//! ## 为什么按内容识别、而不是按扩展名
//!
//! `supports` 只能做廉价声明，扩展名是**声明**不是事实：`.wav` 里可能装着 FLAC，
//! `.flac` 里可能装着 MP3。库的 `open` 回答的是"这段字节是什么"，所以：
//!
//!   * `providers/audio.zig` 带 `expected_format = .wav`：内容不是 WAV →
//!     `error.UnexpectedFormat`，映射成 `none.unsupported`（不是我的格式），
//!     注册表继续问 native-audio；
//!   * `providers/native_audio.zig` 不设期望格式：库认出什么就解什么（它声明
//!     `.wav` / `.flac` / `.mp3` / `.aiff` / `.aif` 都是"我可能能解"）。
//!
//! ## 输出格式：只交付 PCM16
//!
//! 库的公开读取路径只有一种输出：**交错 i16**。源 8/16/24/32 位、float32、
//! G.711 µ-law/A-law 与两种 ADPCM 都在库内部转换完，所以这里固定 `bits = 16`、
//! `format = .pcm`；`sample_rate` / `channels` 原样交给 WASAPI 共享模式。
//! 小端字节序与 `session.build` / 播放器一致——它们看不出容器差别。
//!
//! >2 声道时逐块走 `audio/downmix.zig`（标准顺序 `FL, FR, FC, LFE, BL, BR…`，
//! C/环绕按 0.7071 进两侧，**LFE 丢弃**）。单声道 / 立体声原样保留。
//!
//! ## 内存
//!
//! 压缩文件不再整份进内存：`FileReader` 把已打开的 Win32 句柄接成 `std.Io.Reader`，
//! 解码器按需拉取，适配器常驻缓冲固定 64 KiB。整段 **PCM** 仍进内存（播放器/波形
//! 都要整段），上限 512 MiB；超了是 `error.TooLarge`，不赌分配器。没有
//! `total_frames` 的文件（MP3，以及 **Ogg Vorbis**——它的帧数在最后一页的 granule
//! 里，`open` 时还不知道）用压缩大小 × 12 估初值（上限 64 MiB），只影响 realloc
//! 次数，正确性由增量检查与最终上限兜住。
//!
//! ## 错误 → 四态（与 `preview.zig` 的规则逐字对应）
//!
//!   * `FileNotFound`                                  → `file_missing`
//!   * `InvalidPath` / `Unsupported` / `UnexpectedFormat` → `unsupported`
//!     （不是我的格式、或不是我能解的编码）
//!   * `AccessDenied` / `IoFailure` / `FileTooLarge` / `TooLarge` /
//!     `NotAudio` / `Truncated` / `Corrupt` / `Io` / `ShortBuffer` / `Empty`
//!                                                      → `failed`
//!     （认领了、但文件损坏或 IO 出错）
//!   * 只有 `OutOfMemory` 是 `preview.Error`，由 provider 直接上抛。

const std = @import("std");
const zig_audio = @import("zig_audio");
const preview = @import("../preview.zig");
const audio_file = @import("file.zig");
const downmix = @import("downmix.zig");
const file_reader_mod = @import("file_reader.zig");
const session_mod = @import("session.zig");

/// 整段 PCM 的上限。512 MiB 约等于 25 分钟 44.1 kHz/16-bit 立体声，和 MF 的
/// 上限一致；再大就该流式（M2+）。
pub const max_pcm_bytes: usize = 512 * 1024 * 1024;

/// 没有 `total_frames` 时的初始预留倍数（见文件头「内存」）。128 kbps 立体声的
/// PCM 约是压缩数据的 11 倍，取 12 留一点余量。
const estimate_expansion: u64 = 12;

/// 估算初值的上限。初始预留不是容量承诺：再大就交给 `ArrayList` 按需扩。
const estimate_cap_bytes: u64 = 64 * 1024 * 1024;

/// 一次 `read` 的样本数（不是帧数）。8192 个 i16 = 16 KiB，足够摊薄调用开销，
/// 又不会在栈上留一大块。库保证 `out.len >= channels` 即可。
const chunk_samples: usize = 8192;

/// 解码失败的全集：文件读取（`audio_file`）+ 库（`zig_audio`）+ 本层的三个语义
/// 错误。两个错误集合里有同名项（OutOfMemory / Truncated）是允许的。
pub const Error = audio_file.Error || zig_audio.Error || error{
    /// 流里一个样本都没有（0 帧）。空文件不是"能播的静音"。
    Empty,
    /// 解出来的 PCM 超过 `max_pcm_bytes`。
    TooLarge,
    /// 内容是一个库能解的容器，但不是调用方 `supports` 声明的那一种
    /// （例如 `.wav` 里装着 FLAC）。这是"不是我的格式"，不是"文件坏了"。
    UnexpectedFormat,
};

pub const Options = struct {
    /// 只接受这种容器；`null` 表示"库认出什么就解什么"。
    expected_format: ?zig_audio.Format = null,
    /// 测试/探针入口的流式统计；生产路径传 null（日志里本来就有 reads/avg_read）。
    stats_out: ?*file_reader_mod.Stats = null,
};

/// 读文件 + 解码整段，产出 `session.Decoded`。成功时 `pcm` 归调用方
/// （`Decoded.deinit`）；失败时不留任何分配。
pub fn decode(
    allocator: std.mem.Allocator,
    path: []const u8,
    options: Options,
) Error!session_mod.Decoded {
    // 64 KiB 句柄适配器：库按需拉取，压缩文件不再整份搬进内存。
    var file_reader: file_reader_mod.FileReader = undefined;
    try file_reader.init(allocator, path);
    defer file_reader.deinit();

    var decoder = try zig_audio.open(allocator, file_reader.interface());
    defer decoder.deinit();

    const info = decoder.info;
    if (options.expected_format) |expected| {
        if (info.format != expected) {
            std.debug.print(
                "otto-lite: zig-audio 容器不匹配 file={s} expected={s} actual={s}（按 unsupported 谢绝）\n",
                .{ path, @tagName(expected), @tagName(info.format) },
            );
            return error.UnexpectedFormat;
        }
    }
    if (info.sample_rate == 0) return error.Corrupt;
    if (info.channels == 0) return error.Corrupt;

    const source_channels: usize = info.channels;
    // 播放器只接受 1–2 声道：>2 时逐块走与其它音频 provider 共用的下混。
    const out_channels: u16 = if (source_channels > 2) 2 else info.channels;
    const out_block_bytes: usize = @as(usize, out_channels) * 2;

    var pcm: std.ArrayList(u8) = .empty;
    errdefer pcm.deinit(allocator);
    try reservePcm(allocator, &pcm, info.total_frames, file_reader.compressedBytes(), out_block_bytes);

    var chunk: [chunk_samples]i16 = undefined;
    while (true) {
        const got = try decoder.read(&chunk);
        if (got == 0) break;
        // 小端 i16 的字节就是内存里的那两字节（Windows x86_64 是 LE）。
        // 库承诺按整帧交付；`got` 不是声道数的整数倍说明流坏了。
        if (got % source_channels != 0) return error.Corrupt;

        if (source_channels <= 2) {
            try pcm.appendSlice(allocator, std.mem.sliceAsBytes(chunk[0..got]));
        } else {
            // 逐块下混：不攒整段多声道 PCM，多出来的只有最终双声道输出。
            const frames = got / source_channels;
            const dst = try pcm.addManyAsSlice(allocator, frames * 4);
            downmix.pcm16Into(dst, std.mem.sliceAsBytes(chunk[0..got]), info.channels);
        }
        if (pcm.items.len > max_pcm_bytes) return error.TooLarge;
    }

    if (pcm.items.len == 0) return error.Empty;
    // 库承诺 `read` 只按整帧交付；下混后也必须是整帧。
    if (pcm.items.len % out_block_bytes != 0) return error.Corrupt;

    const frames: u64 = @intCast(pcm.items.len / out_block_bytes);
    const pcm_bytes = try pcm.toOwnedSlice(allocator);

    // 流式证据：compressed 是压缩文件大小（与峰值无关），peak_buf 是适配器唯一的
    // 常驻缓冲；reads/avg_read 证明是分块读而不是一次预读。
    // `container_frames` / `eof_frames` 走 `{?d}`：null 是"容器没写长度"，不是错误。
    // 两者不同正是 Vorbis：开流时 null，读完最后一页后库才把 granule 填进 `info`。
    const stats = file_reader.stats();
    if (options.stats_out) |out| out.* = stats;
    const avg_read = if (stats.reads == 0) 0 else stats.bytes / stats.reads;
    std.debug.print(
        "otto-lite: zig-audio decode file={s} container={s} compressed={d} pcm={d} peak_buf={d} reads={d} avg_read={d} rate={d} ch={d} src_ch={d} bits=16 frames={d} duration={d}ms source_bits={d} container_frames={?d} eof_frames={?d}\n",
        .{
            path,
            @tagName(info.format),
            file_reader.compressedBytes(),
            pcm_bytes.len,
            file_reader_mod.buffer_size,
            stats.reads,
            avg_read,
            info.sample_rate,
            out_channels,
            info.channels,
            frames,
            frames * 1000 / info.sample_rate,
            info.bits_per_sample,
            info.total_frames,
            decoder.info.total_frames,
        },
    );

    return .{
        .pcm = pcm_bytes,
        .sample_rate = info.sample_rate,
        .channels = out_channels,
        .bits = 16,
        .format = .pcm,
        .frames = frames,
        // 毫秒向下取整：1 帧 @ 44.1 kHz 是 0 ms，不冒充 1 ms。
        .duration_ms = frames * 1000 / info.sample_rate,
    };
}

/// 初始容量：有声明值就精确预留（超限是确定的 `TooLarge`）；没有就按压缩大小
/// 估算，估算只决定一次分配的大小，不参与上限判断。
/// `pub` 是为了让测试直接验证 null 时的估算策略（纯函数，不碰文件）。
pub fn reservePcm(
    allocator: std.mem.Allocator,
    pcm: *std.ArrayList(u8),
    declared_frames: ?u64,
    compressed_bytes: u64,
    out_block_bytes: usize,
) Error!void {
    if (declared_frames) |frames| {
        const bytes = std.math.mul(u64, frames, @as(u64, @intCast(out_block_bytes))) catch return error.TooLarge;
        if (bytes > @as(u64, max_pcm_bytes)) return error.TooLarge;
        return pcm.ensureTotalCapacityPrecise(allocator, @intCast(bytes));
    }

    const estimated = std.math.mul(u64, compressed_bytes, estimate_expansion) catch return;
    const target = @min(estimated, estimate_cap_bytes);
    // 空文件不预留：`Empty` 会在读完时给出，而不是在这里分配 0 字节。
    if (target == 0) return;
    try pcm.ensureTotalCapacityPrecise(allocator, @intCast(target));
}

/// 解码错误 → 四态原因。只有 OOM 不是原因（它是 `preview.Error`，调用方先挡）。
/// 这个函数是音频链上**唯一**的映射表，wasapi-pcm 与 native-audio 都从这里取，
/// 两份 provider 不会一个把 `Unsupported` 当 failed、另一个当 unsupported。
pub fn reason(err: Error) preview.Reason {
    return switch (err) {
        error.FileNotFound => .file_missing,
        error.InvalidPath, error.Unsupported, error.UnexpectedFormat => .unsupported,
        else => .failed,
    };
}
