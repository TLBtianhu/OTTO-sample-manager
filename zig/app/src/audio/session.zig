//! 解码产物 → `preview.AudioSession` 的**唯一**装配点。
//!
//! 为什么单独一个文件：WAV（`wav.decode`）与 Media Foundation（MP3/AAC/WMA）的
//! 解码器完全不同，但解码之后的四件事必须逐字节一致：
//!
//!   1. 算波形峰值（`peaks.compute`，512 桶 min/max）；
//!   2. 把峰值渲染成 BGRA 波形位图（`waveform.render`，240×56）；
//!   3. 建播放会话（`player.Player.create`，WASAPI 设备 + 播放线程）；
//!   4. 把 PCM / 采样率 / 声道 / 位深 / 时长装进 `preview.AudioSession`，并把
//!      PCM 的所有权转移给它。
//!
//! 如果 MF provider 复制一份这段代码，两份就会在"桶数、波形尺寸、失败时谁释放
//! PCM、时长取整"上慢慢漂移——而这些恰好是 `--preview` 输出的可比性所在。所以
//! 这里只有一个 `build`，两个 provider 都调它；`providers/audio.zig` 的
//! `sessionFromWav` 只是 WAV → `Decoded` 的一层薄适配（历史 API, `--play-test`
//! 与旧调用方仍可用）。
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
const player = @import("player.zig");
const wav = @import("wav.zig");
const waveform = @import("waveform.zig");

/// 波形位图尺寸（像素）。`waveform.default_*` 是唯一来源，provider 不另写数字。
pub const wave_width: u32 = waveform.default_width;
pub const wave_height: u32 = waveform.default_height;

/// 解码器的中立产物：一段已经可播的交错 PCM + 它的格式事实。
///
/// 字段与 `wav.Wav` 一一对应（`wav` 是它的一个来源），但**不叫 Wav**：
/// MF 解出来的 MP3/AAC 同样是 PCM16，叫 Wav 只会让日志和报告说谎。
pub const Decoded = struct {
    /// 交错 PCM；归本结构所有（`build` 成功后转交会话）。
    pcm: []u8,
    sample_rate: u32,
    channels: u16,
    bits: u16,
    format: wav.SampleFormat,
    frames: u64,
    duration_ms: u64,

    pub fn byteLen(self: Decoded) usize {
        return self.pcm.len;
    }

    /// 释放 PCM。每个 `Decoded` 只调一次；`build` 成功后 `pcm` 为空，这里是无操作。
    pub fn deinit(self: *Decoded, allocator: std.mem.Allocator) void {
        if (self.pcm.len != 0) allocator.free(self.pcm);
        self.pcm = &.{};
        self.frames = 0;
        self.duration_ms = 0;
    }

    /// `wav.Wav` → `Decoded`。只拷贝字段，**不转移** PCM 所有权：原 `wav.Wav`
    /// 仍负责释放它，直到 `build` 成功把 `Decoded.pcm` 置空（调用方再把原结构
    /// 的 `pcm` 置空，见 `providers/audio.zig`）。
    pub fn fromWav(decoded: *const wav.Wav) Decoded {
        return .{
            .pcm = decoded.pcm,
            .sample_rate = decoded.sample_rate,
            .channels = decoded.channels,
            .bits = decoded.bits,
            .format = decoded.format,
            .frames = decoded.frames,
            .duration_ms = decoded.duration_ms,
        };
    }
};

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
