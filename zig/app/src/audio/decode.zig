//! zig-audio → `audio/session.Decoded` 的**唯一**解码路径。
//!
//! WAV / FLAC / MP3 / AIFF / Ogg Vorbis / Ogg Opus（CELT 层）现在都由 vendor 的
//! zig-audio 解（`vendored v0.13`），`providers/audio.zig`（wasapi-pcm）与
//! `providers/native_audio.zig` 只差在 `supports` 的扩展名表与图标能力——解码循环、
//! 声道规则、256/512 MiB 上限、流式 Reader 必须只有这一份。上一轮的 WAV/FLAC 下混
//! 分叉已经证明：两份实现迟早会在"多声道怎么混、空流算不算成功、时长怎么取整"上漂移。
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
//! ## 两种用法：整段一次解 / 分块解
//!
//! `decode()` 是"读到 EOF 再交整段"的便捷入口（`--play-test`、测试、渐进路径
//! 的总帧数未知时）。渐进式预览需要**边解边看**，所以同一个循环被拆成 `Stream`：
//! `init` 开流 → 反复 `step(&chunk)`（每块 ≤8192 个 i16，下混并追加进 PCM）→
//! `finish` 终检并交出所有权。两条路径共用同一个容器识别、下混、512 MiB 上限与
//! 流式 Reader，不会因为"预览要渐进"而分叉出第二套解码器。
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
//!
//! `Unsupported` **不是只在开流时出现**：Opus 的包模式逐包声明，`zig_audio.open` 对
//! 一个 Opus 流会成功（它只知道"这是 Ogg Opus"），多帧包（TOC code 3、一包多于两帧）
//! 要到第 N 次 `Decoder.read` 才被拒绝（见 `vendor/zig-audio/src/opus.zig` 的 `Decoder`
//! 注释）。读取循环里的 `try decoder.read` 让这条中途错误与开流错误汇成同一个
//! `Error`，于是**同一张** `reason` 表覆盖两条路径——不需要"读到一半"的特殊分支，
//! 也不会因为 `open` 成功就把一个不能解的编码认领成 `failed`。

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
pub const chunk_samples: usize = 8192;

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
    /// `null` = 保留整段；否则调用方消费后按档位丢弃或另存有界首窗。
    /// 预留也受此限制，长文件不会先按声明长度提交一整份 PCM。
    retain_bytes: ?usize = null,
};

/// 读文件 + 解码整段，产出 `session.Decoded`。成功时 `pcm` 归调用方
/// （`Decoded.deinit`）；失败时不留任何分配。
pub fn decode(
    allocator: std.mem.Allocator,
    path: []const u8,
    options: Options,
) Error!session_mod.Decoded {
    var stream: Stream = undefined;
    try stream.init(allocator, path, options);
    defer stream.deinit();
    while (true) {
        if (try stream.step(&chunk_scratch) == 0) break; // 解码到 EOF
    }
    return stream.finish();
}

/// `step` 的调用方缓冲。模块级 `threadlocal` 而不是函数局部：8192 个 i16 是 16 KiB，
/// 渐进式解码线程与 `decode()` 都可能用，放线程局部既不用栈也不用堆。
threadlocal var chunk_scratch: [chunk_samples]i16 = undefined;

/// 一个"已经打开、还没读完"的解码会话。`decode()` 与渐进式预览共用它：
///
///   * `init` 只做开流与格式校验（容器识别、声道/采样率、PCM 上限预留）；
///   * `step` 解一块（≤ `chunk_samples` 个 i16），下混、追加进 `pcm`，返回本次
///     新增的**帧数**（0 = EOF）。渐进式预览在每次 `step` 后把新增字节喂给峰值
///     合并器，峰值因此与解码同步长出来；
///   * `finish` 做终检（空流、整帧、时长）并打印那一行流式证据，把 PCM 的所有权
///     交给 `Decoded`；之后本结构只剩解码器与文件句柄，`deinit` 照常释放。
///
/// 为什么必须是"先 init 再 step"而不是返回一个值：`FileReader.reader.buffer` 指向
/// 自己的字段，`zig_audio` 的容器解码器也借用这个 Reader 指针。本结构**不能搬家**，
/// 调用方必须在稳定地址上 `init`（栈上 `var` 或堆上的字段）。
pub const Stream = struct {
    allocator: std.mem.Allocator,
    /// 借用：调用方保证在 `finish` 之前有效（渐进式引擎自己持有一份拷贝）。
    path: []const u8 = "",
    file_reader: file_reader_mod.FileReader = undefined,
    file_opened: bool = false,
    decoder: zig_audio.Decoder = undefined,
    pcm: std.ArrayList(u8) = .empty,
    sample_rate: u32 = 0,
    source_channels: usize = 0,
    channels: u16 = 0,
    out_block_bytes: usize = 0,
    frames: u64 = 0,
    /// 开流时容器声明/估算的总帧数；`null` = 读到流尾才知道（MP3 无 Xing、Vorbis、Opus）。
    container_frames: ?u64 = null,
    opened: bool = false,
    stats_out: ?*file_reader_mod.Stats = null,
    retain_bytes: ?usize = null,

    pub fn init(
        self: *Stream,
        allocator: std.mem.Allocator,
        path: []const u8,
        options: Options,
    ) Error!void {
        self.* = .{ .allocator = allocator, .path = path, .stats_out = options.stats_out, .retain_bytes = options.retain_bytes };
        errdefer self.deinit();

        // 64 KiB 句柄适配器：库按需拉取，压缩文件不再整份搬进内存。
        try self.file_reader.init(allocator, path);
        self.file_opened = true;
        self.decoder = try zig_audio.open(allocator, self.file_reader.interface());
        self.opened = true;

        const info = self.decoder.info;
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

        self.sample_rate = info.sample_rate;
        self.source_channels = info.channels;
        // 播放器只接受 1–2 声道：>2 时逐块走与其它音频 provider 共用的下混。
        self.channels = if (self.source_channels > 2) 2 else info.channels;
        self.out_block_bytes = @as(usize, self.channels) * 2;
        self.container_frames = info.total_frames;
        try reservePcmLimit(
            allocator,
            &self.pcm,
            info.total_frames,
            self.file_reader.compressedBytes(),
            self.out_block_bytes,
            self.retain_bytes,
        );
    }

    /// 释放解码器、文件句柄与（还没交出去的）PCM。`finish` 成功之后 PCM 已为空，
    /// 这里只剩解码器的内部状态要放。
    pub fn deinit(self: *Stream) void {
        if (self.opened) {
            self.decoder.deinit();
            self.opened = false;
        }
        if (self.file_opened) {
            self.file_reader.deinit();
            self.file_opened = false;
        }
        self.pcm.deinit(self.allocator);
        self.pcm = .empty;
        self.frames = 0;
    }

    /// 容器**现在**声明的总帧数：开流时已知（WAV/FLAC/AIFF），MP3 的 Xing 头要读
    /// 第一帧之后才有；Vorbis / Opus 要到流尾。渐进式预览用它决定能不能按固定桶
    /// 边界合并（null → 不做渐进，见 `audio/progressive.zig`）。
    pub fn declaredFrames(self: *const Stream) ?u64 {
        return self.decoder.info.total_frames;
    }

    /// 短文件在读完第一块后切回整段保留；此时尚未发生大容量预留。
    pub fn retainAll(self: *Stream) Error!void {
        self.retain_bytes = null;
        try reservePcm(self.allocator, &self.pcm, self.decoder.info.total_frames, self.file_reader.compressedBytes(), self.out_block_bytes);
    }

    pub fn setRetention(self: *Stream, limit: usize) void {
        self.retain_bytes = limit;
    }

    pub fn decodedBytes(self: *const Stream) usize {
        return @intCast(self.frames * @as(u64, self.out_block_bytes));
    }

    /// 峰值/顺序播放已经消费的块无需保留，也不为维护窗口做整块 memmove。
    pub fn discardConsumed(self: *Stream) void {
        self.pcm.clearRetainingCapacity();
    }

    /// 解一块：追加到 `pcm`，返回新增的**帧数**（0 = EOF）。多声道在这里下混。
    /// 错误与 `zig_audio`/IO 的错误集一致；`errdefer` 在调用方，半截 PCM 不会被
    /// 当成成功交出去。
    pub fn step(self: *Stream, out: []i16) Error!u64 {
        // 这一行是"读到一半才不支持"的唯一出口：Opus 的多帧包（TOC code 3）在
        // `open` 成功之后由 `read` 返回 `error.Unsupported`，与开流阶段的同名错误值
        // 汇合，交给 `reason` 映射成 `unsupported`（谢绝）。
        const got = try self.decoder.read(out);
        if (got == 0) return 0;
        // 小端 i16 的字节就是内存里的那两字节（Windows x86_64 是 LE）。
        // 库承诺按整帧交付；`got` 不是声道数的整数倍说明流坏了。
        if (got % self.source_channels != 0) return error.Corrupt;

        if (self.source_channels <= 2) {
            try self.pcm.appendSlice(self.allocator, std.mem.sliceAsBytes(out[0..got]));
        } else {
            // 逐块下混：不攒整段多声道 PCM，多出来的只有最终双声道输出。
            const frames = got / self.source_channels;
            const dst = try self.pcm.addManyAsSlice(self.allocator, frames * 4);
            downmix.pcm16Into(dst, std.mem.sliceAsBytes(out[0..got]), self.decoder.info.channels);
        }
        if (self.retain_bytes == null and self.pcm.items.len > max_pcm_bytes) return error.TooLarge;
        self.frames += got / self.source_channels;
        return got / self.source_channels;
    }

    /// 终检 + 把 PCM 交出去。所有权转移之后 `self.pcm` 为空，`deinit` 不会重复释放。
    pub fn finish(self: *Stream) Error!session_mod.Decoded {
        if (self.frames == 0) return error.Empty;
        // 库承诺 `read` 只按整帧交付；下混后也必须是整帧。
        if (self.pcm.items.len % self.out_block_bytes != 0) return error.Corrupt;

        const info = self.decoder.info;
        const frames = self.frames;
        const pcm_bytes = try self.pcm.toOwnedSlice(self.allocator);

        // 流式证据：compressed 是压缩文件大小（与峰值无关），peak_buf 是适配器唯一的
        // 常驻缓冲；reads/avg_read 证明是分块读而不是一次预读。
        // `container_frames` / `eof_frames` 走 `{?d}`：null 是"容器没写长度"，不是错误。
        // 两者不同正是 Vorbis：开流时 null，读完最后一页后库才把 granule 填进 `info`。
        const stats = self.file_reader.stats();
        if (self.stats_out) |out| out.* = stats;
        const avg_read = if (stats.reads == 0) 0 else stats.bytes / stats.reads;
        std.debug.print(
            "otto-lite: zig-audio decode file={s} container={s} compressed={d} pcm={d} decoded_pcm={d} peak_buf={d} reads={d} avg_read={d} rate={d} ch={d} src_ch={d} bits=16 frames={d} duration={d}ms source_bits={d} container_frames={?d} eof_frames={?d}\n",
            .{
                self.path,
                @tagName(info.format),
                self.file_reader.compressedBytes(),
                pcm_bytes.len,
                self.decodedBytes(),
                file_reader_mod.buffer_size,
                stats.reads,
                avg_read,
                info.sample_rate,
                self.channels,
                info.channels,
                frames,
                frames * 1000 / info.sample_rate,
                info.bits_per_sample,
                self.container_frames,
                info.total_frames,
            },
        );

        return .{
            .pcm = pcm_bytes,
            .sample_rate = info.sample_rate,
            .channels = self.channels,
            .bits = 16,
            .format = .pcm,
            .frames = frames,
            // 毫秒向下取整：1 帧 @ 44.1 kHz 是 0 ms，不冒充 1 ms。
            .duration_ms = frames * 1000 / info.sample_rate,
        };
    }
};

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
    return reservePcmLimit(allocator, pcm, declared_frames, compressed_bytes, out_block_bytes, null);
}

fn reservePcmLimit(
    allocator: std.mem.Allocator,
    pcm: *std.ArrayList(u8),
    declared_frames: ?u64,
    compressed_bytes: u64,
    out_block_bytes: usize,
    retain_bytes: ?usize,
) Error!void {
    if (declared_frames) |frames| {
        const bytes = std.math.mul(u64, frames, @as(u64, @intCast(out_block_bytes))) catch return error.TooLarge;
        if (retain_bytes == null and bytes > @as(u64, max_pcm_bytes)) return error.TooLarge;
        const target = if (retain_bytes) |limit| @min(bytes, @as(u64, @intCast(limit + chunk_samples * 2))) else bytes;
        return pcm.ensureTotalCapacityPrecise(allocator, @intCast(target));
    }

    const estimated = std.math.mul(u64, compressed_bytes, estimate_expansion) catch return;
    var target = @min(estimated, estimate_cap_bytes);
    if (retain_bytes) |limit| target = @min(target, @as(u64, @intCast(limit + chunk_samples * 2)));
    // 空文件不预留：`Empty` 会在读完时给出，而不是在这里分配 0 字节。
    if (target == 0) return;
    try pcm.ensureTotalCapacityPrecise(allocator, @intCast(target));
}

/// 解码错误 → 四态原因。只有 OOM 不是原因（它是 `preview.Error`，调用方先挡）。
/// 这个函数是音频链上**唯一**的映射表，wasapi-pcm 与 native-audio 都从这里取，
/// 两份 provider 不会一个把 `Unsupported` 当 failed、另一个当 unsupported。
///
/// `Unsupported` 同时覆盖两种时机：`open` 就答不了（容器/编码不认），以及**读到一半**
/// 才答不了（Opus 的多帧包）。两者都是"这个编码我没有"，不是
/// "文件坏了"，所以都落 `unsupported`——谢绝，注册表继续问下一个。
pub fn reason(err: Error) preview.Reason {
    return switch (err) {
        error.FileNotFound => .file_missing,
        error.InvalidPath, error.Unsupported, error.UnexpectedFormat => .unsupported,
        else => .failed,
    };
}
