//! 解码产物 → `preview.AudioSession` 的**唯一**装配点。
//!
//! 为什么单独一个文件：zig-audio（WAV/FLAC/MP3/AIFF）与 Media Foundation
//! （MP3/AAC/WMA）的解码器完全不同，但解码之后的四件事必须逐字节一致：
//!
//!   1. 算波形峰值（`peaks.compute`，512 桶 min/max）；
//!   2. 把峰值渲染成 BGRA 波形位图（`waveform.render`，240×56）；
//!   3. 建播放会话（`player.Player.create`，WASAPI 设备 + 播放线程）；
//!   4. 把 PCM / 采样率 / 声道 / 位深 / 时长装进 `preview.AudioSession`，并把
//!      PCM 的所有权转移给它。
//!
//! 如果每个 provider 复制一份这段代码，几份就会在"桶数、波形尺寸、失败时谁释放
//! PCM、时长取整"上慢慢漂移——而这些恰好是 `--preview` 输出的可比性所在。所以
//! 这里只有一个 `build`，所有音频 provider 都调它。`Decoded` 的形状在
//! `audio/pcm.zig`：它不再叫 Wav，因为解出来的可能是 WAV / FLAC / MP3 / AIFF /
//! MF 的任意一种容器。
//!
//! 所有权约定（与 `preview.AudioSession` 文件头一致）：
//!   * `build` 成功时把 `decoded.pcm` 交给会话，并把 `decoded.pcm` 置空；
//!   * `build` 失败时 `decoded` 仍完整归调用方，调用方照常 `deinit`——不会出现
//!     "波形算到一半失败，PCM 已经被会话吃掉"的半所有权状态；
//!   * `peaks` 与 `waveform` 由同一个 allocator 分配，由 `AudioSession.deinit` 释放。
//!
//! 不 import nanoui、不碰窗口；只依赖预览契约、峰值、波形与播放器。

const std = @import("std");
const preview = @import("../preview.zig");
const peaks_mod = @import("peaks.zig");
const pcm = @import("pcm.zig");
const player = @import("player.zig");
const waveform = @import("waveform.zig");

/// 波形位图尺寸（像素）。`waveform.default_*` 是唯一来源，provider 不另写数字。
pub const wave_width: u32 = waveform.default_width;
pub const wave_height: u32 = waveform.default_height;

/// 解码器的中立产物。定义在 `pcm.zig`，这里转出去让 provider 继续用
/// `session.Decoded`（历史调用点不必改 import）。
pub const Decoded = pcm.Decoded;

/// 字节含义。zig-audio 与 MF 的生产路径都只交 `.pcm` + 16 位；类型留在 `pcm.zig`。
pub const SampleFormat = pcm.SampleFormat;

/// 算峰值 → 渲染波形 → 建播放器 → 装会话。`player.Error` 原样上抛，调用方按
/// 自己的语境把它映射成 `none.*`（音频 provider 与 MF provider 日志文案不同）。
///
/// 成功时 `decoded.pcm` 的所有权归会话；失败时仍归 `decoded`。
pub fn build(
    allocator: std.mem.Allocator,
    decoded: *Decoded,
) player.Error!preview.AudioSession {
    const peaks = try peaks_mod.compute(
        allocator,
        decoded.pcm,
        decoded.channels,
        decoded.bits,
        decoded.format,
        peaks_mod.default_buckets,
    );
    errdefer peaks.deinit(allocator);
    const bitmap = try waveform.render(
        allocator,
        peaks,
        wave_width,
        wave_height,
        waveform.default_color,
    );
    errdefer bitmap.deinit(allocator);

    const created = try player.Player.create(
        allocator,
        decoded.pcm,
        decoded.sample_rate,
        decoded.channels,
        decoded.bits,
        decoded.format == .float,
    );
    const session: preview.AudioSession = .{
        .pcm = decoded.pcm,
        .sample_rate = decoded.sample_rate,
        .channels = decoded.channels,
        .bits = decoded.bits,
        .duration_ms = decoded.duration_ms,
        .position_ms = 0,
        .player = created,
        .peaks = peaks,
        .waveform = bitmap,
    };
    // 所有权已经交给会话；`Decoded.deinit` 之后只释放空切片。
    decoded.pcm = &.{};
    return session;
}
