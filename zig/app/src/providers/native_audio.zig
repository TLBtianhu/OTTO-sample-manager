//! FLAC / MP3 试听 provider：**纯 Zig 解码**（vendor 的 zig-audio v0.7，提交 `f2d2ec2`），
//! 接在 WAV 之后、MF 之前。
//!
//! 与 `providers/audio.zig`（自写 RIFF 解析 + WASAPI）和 `providers/mf_audio.zig`
//! （Media Foundation）并列，三者产出同一种 `preview.AudioSession`，视图不认识
//! "这段 PCM 是 WAV / FLAC / MP3 解的"。
//!
//! ## 调用链
//!
//! ```
//! audio/file_reader.zig FileReader            ← Win32 句柄 + 64 KiB 缓冲
//! std.Io.Reader（readVec 契约）                ← 库只接受 std.Io.Reader
//! zig_audio.open(allocator, &reader)         ← 12 字节签名 → FLAC 或 MP3 解码器
//!   info: sample_rate / channels / bits_per_sample / total_frames
//!   loop decoder.read(&chunk)                ← 交错 i16，直到返回 0
//!   >2 声道：audio/downmix.zig 逐块混成双声道（与 WAV 同一份规则）
//! 按实际样本数算 frames / duration（不信容器声明）
//! audio/session.build                        ← 峰值/波形/Player 与 WAV/MF 共用
//! ```
//!
//! ## 为什么自给自足、不查能力表
//!
//! `supports` 只看扩展名 `.flac` / `.mp3`，**不打开文件、不读注册表**。两个解码器
//! 都是我们自己 vendor 的纯 Zig 代码，机器上有没有它不取决于系统装了什么；真正的
//! 能力（文件坏没坏、MP3 是不是 MPEG-1 Layer III、位深/声道是否在库的支持面内）要
//! 到 `open` 才知道——那正是 `zig_audio.open` 回答的问题。能力表在这里没有第二个
//! 真相可用。
//!
//! ## 格式约定：只交付 PCM16
//!
//! 库的公开读取路径只有一种输出：**交错 i16**。源 8/16/24/32 位与 float32 都在
//! 库内部转换完（24 位右移 8、32 位右移 16、float 钳到 [-1,1]），MP3 的合成滤波
//! 输出本来就在 i16 域，所以这里固定 `bits = 16`、`format = .pcm`，
//! `sample_rate` / `channels` 原样交给 WASAPI 共享模式。小端字节序与 WAV 的
//! PCM16 一致——`session.build` 与播放器看不出两者的差别。
//!
//! 不做重采样。单声道 / 立体声**原样**交给 `session.build`；多于 2 声道时，
//! 与 `audio/wav.zig` 共用 `audio/downmix.zig` 的同一条规则（标准顺序
//! `FL, FR, FC, LFE, BL, BR…`，C/环绕按 0.7071 进两侧，**LFE 丢弃**，矩阵
//! 表与理由都在那边），逐块混成双声道 PCM16 再交给会话（MP3 只有 1–2 声道，
//! 这条路径是给 5.1 FLAC 留的）。`audio/player.zig` 的 WASAPI 路径只接受 1–2
//! 声道，这一步是消费端的硬要求；下混规则只存在一份，FLAC 与 WAV 不会各混各的。
//!
//! ## MP3 的 `total_frames` 可能是 null：缓冲策略
//!
//! FLAC 的 STREAMINFO 通常带总样本数；MP3 只有带 Xing/Info 头时才知道长度，
//! 否则 `Info.total_frames` 是 **null**——`viper.mp3`（真实音乐，LAME 编码但没有
//! Xing 头）就是这种。所以容量不能只按 `total_frames` 预留：
//!
//!   * 有 `total_frames`（FLAC、带 Xing 的 MP3）→ 按输出字节数**精确**预留，
//!     一次分配到位，大文件不在 append 过程中反复 realloc；
//!   * 没有 → 用压缩文件大小 × [`estimate_expansion`]（12 ≈ 128 kbps 立体声的
//!     PCM 膨胀率）估一个初值，上限 [`estimate_cap_bytes`]（64 MiB）。
//!     估小了 `ArrayList.appendSlice` 自己几何扩容，**正确性不依赖这个估算**，
//!     它只决定 realloc 次数。`viper.mp3`：654942 B × 12 = 7.86 MB，正好覆盖
//!     7.22 MB 的实际 PCM（零次扩容）。
//!
//! 声明值超过 `max_pcm_bytes` 是**确定**超限，仍按 `TooLarge` 早退；估算值不参与
//! 上限判断（估大只是多占，估小由增量检查与最终上限兜住）。
//!
//! ## 图标：**不参与**
//!
//! `icon_capable = false`。FLAC 与 MP3 都没有"读几 KB 就能画出包络"的粗采样路径：
//! 要得到一段真实波形就得解完整段（FLAC 是帧内熵编码；MP3 的帧还依赖前 511 字节
//! 的比特池，随便 seek 到中间解不出正确样本）。按"绝不为 32px 图标解码整段音频"
//! 的原则，这两种行显示占位，图标表里也不出现本 provider（`registryForIcon` 按
//! 这一位过滤，见 `providers/root.zig`）。`open` 里再挡一次 `request.icon`：就算
//! 有人误把本项塞进图标表，也只会得到一次谢绝，而不是一段白解。
//!
//! ## 内存与失败
//!
//! **压缩文件不再整份进内存**：`audio/file_reader.zig` 把已打开的 Win32 句柄接成
//! `std.Io.Reader`，解码器按需拉取，适配器常驻缓冲固定 64 KiB
//! （`peak_buf=65536`，日志里可见）。峰值与压缩文件大小无关；20 MB 的 FLAC 或
//! MP3 不会因为"文件大"就多占 20 MB。
//!
//! 整段 **PCM** 仍进内存（与 WAV / MF 同量级，播放器/波形都要整段）：上限
//! `max_pcm_bytes` = 512 MiB，和 `audio/file.zig` 对 WAV 的上限一致；超了是
//! `none.failed`，不赌分配器。>2 声道是**逐块**下混的，不会先把 6 声道 PCM 全攒
//! 起来再混，所以多声道文件多出来的只有最终双声道输出。
//!
//! 错误按四态映射（CHARTER「一」，四者不合并）：
//!   * 文件/路径不存在            → `none.file_missing`
//!   * 路径非法 / 非 Windows      → `none.unsupported`
//!   * 解码失败（NotAudio / Corrupt / Truncated / Unsupported / Io / 空流 / 超限）
//!                                → `none.failed`（注册表会继续问 mf-audio / Shell）
//!   * 只有 OOM 是 `preview.Error`
//!
//! `none.*` 是**谢绝**：注册表会继续问下一个 provider。`.flac` / `.mp3` 排在
//! `mf-audio` 之前是因为 MF 在部分机器上也能解这两种，但它是系统组件、还多一层
//! COM；能用我们自己的解码器时先用它，失败了再让 MF 试一次——顺序表达偏好，
//! 谢绝保证不堵死。MP3 的 MPEG-2/2.5 与 Layer I/II 不在 v0.7 的支持面内，库返回
//! `Unsupported`，这里如实落成 `none.failed` 并让后面的 provider 接手。

const std = @import("std");
const builtin = @import("builtin");
const core = @import("otto_core");
const zig_audio = @import("zig_audio");
const audio_file = @import("../audio/file.zig");
const downmix = @import("../audio/downmix.zig");
const file_reader_mod = @import("../audio/file_reader.zig");
const player = @import("../audio/player.zig");
const session_mod = @import("../audio/session.zig");
const preview = @import("../preview.zig");

/// 注册表里的这一项。`kind = .audio`：产出可播放的会话。
pub const provider: preview.Provider = .{
    .name = "native-audio",
    .kind = .audio,
    .supports = supports,
    .open = open,
    // 见文件头「图标」：FLAC / MP3 都没有便宜的粗采样路径，绝不整段解码换 32px。
    .icon_capable = false,
};

/// 整段 PCM 的上限。512 MiB 约等于 25 分钟 44.1 kHz/16-bit 立体声，和
/// `audio/file.zig` / `mf_audio` 的上限一致；再大就该流式（M2+）。
pub const max_pcm_bytes: usize = 512 * 1024 * 1024;

/// 没有 `total_frames` 时的初始预留倍数（见文件头「缓冲策略」）。只影响 realloc
/// 次数：128 kbps 立体声的 PCM 约是压缩数据的 11 倍，取 12 留一点余量。
const estimate_expansion: u64 = 12;

/// 估算初值的上限。初始预留不是容量承诺：再大就交给 `ArrayList` 按需扩，
/// 不为一个猜测先占几百 MiB。
const estimate_cap_bytes: u64 = 64 * 1024 * 1024;

/// 一次 `read` 的样本数（不是帧数）。8192 个 i16 = 16 KiB，足够摊薄调用开销，
/// 又不会在栈上留一大块。库保证 `out.len >= channels` 即可，余数尾帧原样跳过。
const chunk_samples: usize = 8192;

/// `.flac` / `.mp3` 归本 provider。大小写不敏感；不碰文件、不碰注册表。
pub fn supports(sample: *const core.model.Sample) bool {
    if (builtin.os.tag != .windows) return false;
    return supportsExtension(sample.file_ext);
}

/// 扩展名判定（带点，与 `core.model.Sample.file_ext` 同形）。`--play-test` 用它
/// 分流，避免两处各写一份 `.flac` / `.mp3` 比较。
pub fn supportsExtension(ext: []const u8) bool {
    if (builtin.os.tag != .windows) return false;
    return std.ascii.eqlIgnoreCase(ext, ".flac") or std.ascii.eqlIgnoreCase(ext, ".mp3");
}

/// 解码失败的全集：文件读取（`audio_file`）+ 库（`zig_audio`）+ 本文件的两个
/// 语义错误。两个错误集合里有同名项（OutOfMemory / Truncated）是允许的。
pub const DecodeError = audio_file.Error || zig_audio.Error || error{
    /// 流里一个样本都没有（0 帧）。空文件不是"能播的静音"。
    Empty,
    /// 解出来的 PCM 超过 `max_pcm_bytes`。
    TooLarge,
};

/// 读文件 + 解码整段，产出 `session.Decoded`。`--play-test` 与 provider 共用这一段，
/// 两边不会走出两种解析。
///
/// 成功时 `pcm` 归调用方（`Decoded.deinit`）；失败时不留任何分配。
/// PCM 是**小端交错 i16**，`bits = 16`、`format = .pcm`，与 WAV / MF 的产物同形。
pub fn decode(allocator: std.mem.Allocator, path: []const u8) DecodeError!session_mod.Decoded {
    return decodeInternal(allocator, path, null);
}

/// 测试/探针入口：与 `decode` 完全相同，只多带回流式统计（读次数、总字节）。
/// 生产路径不读它——日志里已经有 `reads/avg_read`。
pub fn decodeWithStats(
    allocator: std.mem.Allocator,
    path: []const u8,
    stats_out: *file_reader_mod.Stats,
) DecodeError!session_mod.Decoded {
    return decodeInternal(allocator, path, stats_out);
}

/// `decode` 的实现；`stats_out` 只给测试/探针读流式统计（读次数、总字节），
/// 生产路径传 null。日志里始终带 `reads/avg_read`，所以 --preview 也能看到。
fn decodeInternal(
    allocator: std.mem.Allocator,
    path: []const u8,
    stats_out: ?*file_reader_mod.Stats,
) DecodeError!session_mod.Decoded {
    // 64 KiB 句柄适配器：库按需拉取，压缩文件不再整份搬进内存。
    var file_reader: file_reader_mod.FileReader = undefined;
    try file_reader.init(allocator, path);
    defer file_reader.deinit();

    var decoder = try zig_audio.open(allocator, file_reader.interface());
    defer decoder.deinit();

    const info = decoder.info;
    if (info.sample_rate == 0) return error.Corrupt;
    if (info.channels == 0) return error.Corrupt;
    const source_channels: usize = info.channels;
    // 播放器只接受 1–2 声道：>2 时逐块走与 WAV 共用的下混，输出双声道 PCM16。
    const out_channels: u16 = if (source_channels > 2) 2 else info.channels;
    const out_block_bytes: usize = @as(usize, out_channels) * 2;

    var pcm: std.ArrayList(u8) = .empty;
    errdefer pcm.deinit(allocator);
    try reservePcm(allocator, &pcm, info.total_frames, file_reader.compressedBytes(), out_block_bytes);

    var chunk: [chunk_samples]i16 = undefined;
    while (true) {
        const got = try decoder.read(&chunk);
        if (got == 0) break;
        // 小端 i16 的字节就是在内存里的那两字节（Windows x86_64 是 LE）。
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
    // 库承诺 `read` 只按整帧交付；下混后也必须是整帧，坏掉的是"字节含义"而不是数据。
    if (pcm.items.len % out_block_bytes != 0) return error.Corrupt;

    const frames: u64 = @intCast(pcm.items.len / out_block_bytes);
    const pcm_bytes = try pcm.toOwnedSlice(allocator);

    // 流式证据：compressed 是压缩文件大小（与峰值无关），peak_buf 是适配器唯一的
    // 常驻缓冲；reads/avg_read 证明是分块读而不是一次预读（1 次读 = 可疑）。
    // `container_frames` 走 `{?d}`：null 是"容器没写长度"（FLAC total_samples = 0，
    // 或 MP3 没有 Xing/Info 头），不是错误，也不需要为它编一个数字。
    const stats = file_reader.stats();
    if (stats_out) |out| out.* = stats;
    const avg_read = if (stats.reads == 0) 0 else stats.bytes / stats.reads;
    std.debug.print(
        "otto-lite: native-audio decode file={s} compressed={d} pcm={d} peak_buf={d} reads={d} avg_read={d} rate={d} ch={d} src_ch={d} bits=16 frames={d} duration={d}ms source_bits={d} container_frames={?d}\n",
        .{
            path,
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
        },
    );

    return .{
        .pcm = pcm_bytes,
        .sample_rate = info.sample_rate,
        .channels = out_channels,
        .bits = 16,
        .format = .pcm,
        .frames = frames,
        // 毫秒向下取整，与 WAV / MF 一致：1 帧 @ 44.1 kHz 是 0 ms，不冒充 1 ms。
        .duration_ms = frames * 1000 / info.sample_rate,
    };
}

/// 初始容量：见文件头「MP3 的 `total_frames` 可能是 null：缓冲策略」。
/// 声明值超限是确定的 `TooLarge`；估算值只决定一次分配的大小。
/// `pub` 是为了让测试直接验证 null 时的估算策略（纯函数，不碰文件）。
pub fn reservePcm(
    allocator: std.mem.Allocator,
    pcm: *std.ArrayList(u8),
    declared_frames: ?u64,
    compressed_bytes: u64,
    out_block_bytes: usize,
) DecodeError!void {
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

fn open(allocator: std.mem.Allocator, request: preview.Request) preview.Error!preview.Outcome {
    if (builtin.os.tag != .windows) return .{ .none = .unsupported };
    // 图标请求：不整段解码，直接谢绝（正常路径下注册表根本不会问到这里）。
    if (request.icon) return .{ .none = .unsupported };

    var decoded = decode(allocator, request.sample.file_path) catch |err| return decline(err, request.sample.file_path);
    defer decoded.deinit(allocator);

    // 与 WAV / MF 完全相同的会话装配（峰值/波形/Player）；失败文案按本 provider 语境。
    const session = session_mod.build(allocator, &decoded) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NoAudioEndpoint => {
            std.debug.print(
                "otto-lite: 没有默认音频输出端点，FLAC/MP3 预览谢绝（{s}）\n",
                .{request.sample.file_path},
            );
            return .{ .none = .failed };
        },
        error.Unsupported => return .{ .none = .unsupported },
        error.InvalidFormat, error.DeviceFailure, error.ThreadFailure => {
            std.debug.print(
                "otto-lite: FLAC/MP3 播放初始化失败 {s}（{s} hresult=0x{x:0>8}）\n",
                .{ request.sample.file_path, @errorName(err), @as(u32, @bitCast(player.lastHresult())) },
            );
            return .{ .none = .failed };
        },
    };

    return .{ .audio = session };
}

/// 解码错误 → 谢绝原因。只有 OOM 是 `preview.Error`，其余都是"这次我答不了"。
fn decline(err: DecodeError, path: []const u8) preview.Error!preview.Outcome {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.FileNotFound => .{ .none = .file_missing },
        error.InvalidPath => .{ .none = .unsupported },
        error.AccessDenied, error.IoFailure, error.FileTooLarge, error.TooLarge => |code| blk: {
            std.debug.print("otto-lite: FLAC/MP3 文件读取/容量失败 {s}（{s}）\n", .{ path, @errorName(code) });
            break :blk .{ .none = .failed };
        },
        error.NotAudio, error.Unsupported, error.Truncated, error.Corrupt, error.Io, error.ShortBuffer, error.Empty => |code| blk: {
            std.debug.print("otto-lite: FLAC/MP3 解码失败 {s}（{s}）\n", .{ path, @errorName(code) });
            break :blk .{ .none = .failed };
        },
    };
}
