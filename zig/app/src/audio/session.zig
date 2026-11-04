//! 解码产物 → `audio_session.AudioSession` 的**唯一**装配点。
//!
//! 为什么单独一个文件：zig-audio（WAV/FLAC/MP3/AIFF）与 Media Foundation
//! （MP3/AAC/WMA）的解码器完全不同，但解码之后的四件事必须逐字节一致：
//!
//!   1. 算波形峰值（`peaks.compute`，512 桶 min/max）；
//!   2. 把峰值渲染成 BGRA 波形位图（`waveform.render`，240×56）；
//!   3. 把 PCM / 采样率 / 声道 / 位深 / 时长装进 `audio_session.AudioSession`，并把
//!      PCM 的所有权转移给它；Player 留到第一次播放再建。
//!
//! 如果每个 provider 复制一份这段代码，几份就会在"桶数、波形尺寸、失败时谁释放
//! PCM、时长取整"上慢慢漂移——而这些恰好是 `--preview` 输出的可比性所在。所以
//! 这里只有一个 `build`，所有音频 provider 都调它。`Decoded` 的形状在
//! `audio/pcm.zig`：它不再叫 Wav，因为解出来的可能是 WAV / FLAC / MP3 / AIFF /
//! MF 的任意一种容器。
//!
//! 所有权约定（与 `audio_session.AudioSession` 文件头一致）：
//!   * `build` 成功时把 `decoded.pcm` 交给会话，并把 `decoded.pcm` 置空；
//!   * `build` 失败时 `decoded` 仍完整归调用方，调用方照常 `deinit`——不会出现
//!     "波形算到一半失败，PCM 已经被会话吃掉"的半所有权状态；
//!   * `peaks` 与 `waveform` 由同一个 allocator 分配，由 `AudioSession.deinit` 释放。
//!
//! 不 import nanoui、不碰窗口；只依赖预览契约、峰值、波形与播放器。

const std = @import("std");
const audio_session = @import("../preview_audio_session.zig");
const peaks_mod = @import("peaks.zig");
const pcm = @import("pcm.zig");
const player = @import("player.zig");
const lazy_player = @import("lazy_player.zig");
const waveform = @import("waveform.zig");

/// 波形位图尺寸（像素）。`waveform.default_*` 是唯一来源，provider 不另写数字。
pub const wave_width: u32 = waveform.default_width;
pub const wave_height: u32 = waveform.default_height;

/// 解码器的中立产物。定义在 `pcm.zig`，这里转出去让 provider 继续用
/// `session.Decoded`（历史调用点不必改 import）。
pub const Decoded = pcm.Decoded;

/// 字节含义。zig-audio 与 MF 的生产路径都只交 `.pcm` + 16 位；类型留在 `pcm.zig`。
pub const SampleFormat = pcm.SampleFormat;

/// 算峰值 → 渲染波形 → 装会话。默认不建 Player，首次播放的具名设备错误由
/// `AudioSession.play` 原样上抛；`lazy_player.enabled = false` 仅用于反向对照。
///
/// 成功时 `decoded.pcm` 的所有权归会话；失败时仍归 `decoded`。
pub fn build(
    allocator: std.mem.Allocator,
    decoded: *Decoded,
) player.Error!audio_session.AudioSession {
    const io = std.Io.Threaded.global_single_threaded.io();
    const peaks_started = std.Io.Clock.Timestamp.now(io, .awake);
    const peaks = try peaks_mod.compute(
        allocator,
        decoded.pcm,
        decoded.channels,
        decoded.bits,
        decoded.format,
        peaks_mod.default_buckets,
    );
    errdefer peaks.deinit(allocator);
    const peaks_ms = @as(f64, @floatFromInt(peaks_started.untilNow(io).raw.nanoseconds)) / 1_000_000.0;
    const wave_started = std.Io.Clock.Timestamp.now(io, .awake);
    const bitmap = try waveform.render(
        allocator,
        peaks,
        wave_width,
        wave_height,
        waveform.default_color,
    );
    errdefer bitmap.deinit(allocator);
    const wave_ms = @as(f64, @floatFromInt(wave_started.untilNow(io).raw.nanoseconds)) / 1_000_000.0;
    const player_started = std.Io.Clock.Timestamp.now(io, .awake);

    var created: ?*player.Player = null;
    if (!lazy_player.enabled) {
        created = try player.Player.create(
            allocator,
            decoded.pcm,
            decoded.sample_rate,
            decoded.channels,
            decoded.bits,
            decoded.format == .float,
        );
    }
    const player_ms = @as(f64, @floatFromInt(player_started.untilNow(io).raw.nanoseconds)) / 1_000_000.0;
    const session: audio_session.AudioSession = .{
        .pcm = decoded.pcm,
        .sample_rate = decoded.sample_rate,
        .channels = decoded.channels,
        .bits = decoded.bits,
        .sample_float = decoded.format == .float,
        .duration_ms = decoded.duration_ms,
        .position_ms = 0,
        .player = created,
        .total_frames = decoded.frames,
        .lazy = .{ .allocator = allocator, .state = if (created != null) .ready else .idle },
        .peaks = peaks,
        .waveform = bitmap,
        // 非渐进会话的第一版就是最终版：完成列数 = 整条宽度（空 peaks 为 0）。
        // 视图把它放进图像缓存键，和渐进会话用同一套规则。
        .waveform_version = waveform.completeColumns(peaks.len(), bitmap.width, peaks.len()),
    };
    std.debug.print(
        "otto-lite: audio-phase peaks_ms={d:.2} waveform_ms={d:.2} player_ms={d:.2} player_deferred={}\n",
        .{ peaks_ms, wave_ms, player_ms, lazy_player.enabled },
    );
    // 所有权已经交给会话；`Decoded.deinit` 之后只释放空切片。
    decoded.pcm = &.{};
    return session;
}
