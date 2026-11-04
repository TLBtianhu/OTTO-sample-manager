//! 音频预览会话：PCM / 有界帧源、波形、渐进解码接口与按需播放。
//!
//! 本文件拥有 `AudioSession` 的全部状态与生命周期。provider 注册表只通过
//! `Outcome.audio` 持有这个类型； progressive 直接实现这里的 `AudioProgress`，
//! 不再 import `preview.zig`。共享位图来自 `preview_bitmap.zig`，因此依赖始终单向：
//!
//! ```
//! preview_bitmap.zig ← preview_audio_session.zig ← preview.zig
//!                              ↑
//!                       audio/progressive.zig
//! ```
//!
//! 渐进任务先 cancel/join，再释放引擎；Player 创建工作线程也先 join，最后才释放
//! 它借用的 PCM/帧源。没有播放意图时不创建 Player。

const std = @import("std");
const bitmap_mod = @import("preview_bitmap.zig");
const audio_player = @import("audio/player.zig");
const lazy_player = @import("audio/lazy_player.zig");
const peaks_mod = @import("audio/peaks.zig");
const pcm_source = @import("audio/pcm_source.zig");
const residency = @import("audio/residency.zig");

const Bitmap = bitmap_mod.Bitmap;
const emptyBitmap = bitmap_mod.emptyBitmap;

/// 后台解码的最小接口：`AudioSession` 只知道"有个东西在继续解码、可以问它
/// 进度、可以取消"，不认识 `zig_audio`、线程或 `audio/progressive.zig`。
///
/// vtable 是契约与 progressive 实现之间的唯一接缝；两边共同依赖本会话模块，
/// 不需要让 provider 契约与 progressive 互相 import。
///
/// 线程约定（实现方必须遵守）：
///   * `pump` / `wait` / `cancel` / `requestPlay` 只由 **UI 线程**调用；
///   * `pump` 把新完成的峰值画进 `session.waveform`，完成时把最终的 PCM / 峰值 /
///     Player 移进 `session`（所有权一次性转移），并返回"画面变了没有"；
///   * `deinit` 先 `cancel`（join 后台线程）再 `destroy`，所以这里看不到活线程。
pub const AudioProgress = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// UI 线程：把进度画进会话。返回 true = 画面（或播放可用性）变了。
        pump: *const fn (ctx: *anyopaque, session: *AudioSession) bool,
        /// 阻塞到后台解码结束，然后把最终结果交给会话（`--preview` / 测试用）。
        wait: *const fn (ctx: *anyopaque, session: *AudioSession) void,
        /// 请求停止并 join。幂等；不释放引擎。
        cancel: *const fn (ctx: *anyopaque) void,
        /// 释放引擎（以及它还没交出去的东西）。必须已 cancel/wait。
        destroy: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) void,
        /// 已经解出的 PCM 字节数（UI 的"PCM N 字节"用；未交出去时读原子量）。
        decodedBytes: *const fn (ctx: *anyopaque) usize,
        /// 还在解吗？`false` = 已结束（成功/失败/取消都算结束）。
        decoding: *const fn (ctx: *anyopaque) bool,
        /// 记录/撤销“解码完成后播放”的意图；真正建 Player 仍由会话按需发起。
        requestPlay: *const fn (ctx: *anyopaque, wanted: bool) void,
    };
};

/// 音频会话：**能播的声音**，不是一个空壳。
///
/// 字段是解码后的 PCM（交错、`channels` 声道、`bits` 位、`sample_rate`）、时长，
/// 以及一个 `audio/player.Player`——后者拥有 WASAPI 设备句柄与**播放线程**。
///
/// 所有权：
///   * `pcm` 用创建这个 Outcome 的 allocator 分配，`deinit(allocator)` 释放；
///   * `peaks`（每桶一对 min/max）与 `waveform`（由 peaks 渲染的 BGRA 位图）
///     同样由 `open` 的 allocator 分配，`deinit` 一并释放。非渐进会话在 `open`
///     里算一次**存起来**：播放时每帧重画只读它们，不重新解码、不重新算峰值；
///   * 渐进式会话（`progress != null`）先只有前缀峰值和第一版位图；后台线程解完
///     之后，`pump`/`waitComplete` 把最终 PCM / 峰值 / Player 移进来，`pcm` 与
///     `peaks` 到这时才是完整的；
///   * `player` 由 `Player.create` 分配，`Player.deinit` 释放（内部停播 + join）；
///   * `position_ms` 是 UI 线程最后一次读到的快照；跨线程的真值在 Player 的
///     `std.atomic.Value(u64)` 里。UI **只读** `positionMs()`，不碰播放线程。
///
/// `play` / `stop` / `seek` 可以在 UI 线程调用（只投递命令并等 ack，不碰设备句柄）。
pub const AudioSession = struct {
    pcm: []const u8,
    sample_rate: u32,
    channels: u16,
    bits: u16,
    sample_float: bool = false,
    duration_ms: u64,
    position_ms: u64 = 0,
    player: ?*audio_player.Player = null,
    /// 长音频的有界帧源；与 pcm 二选一，由会话拥有。
    source: ?*pcm_source.Source = null,
    pcm_residency: residency.Mode = .full_decode,
    total_frames: u64 = 0,
    /// 按需创建的状态/工作线程。实际会话在装配时写入 allocator；测试可替换 factory。
    lazy: lazy_player.Lazy = .{},
    /// 波形峰值，长度 = 桶数（`audio/peaks.zig` 的 `default_buckets`）；空音频为 0。
    peaks: peaks_mod.Peaks = .{},
    /// 由 `peaks` 渲染的 BGRA 位图（`audio/waveform.zig`）。视图把它当图片画，
    /// 不认识它是怎么来的；空位图（`width == 0`）表示"没有波形"。
    waveform: Bitmap = emptyBitmap,
    /// 波形位图的**内容版本**：位图只在整列完成时才重画，这个数就是当时完成的
    /// 列数（单调不减）。视图把它放进图像缓存键，图集才会重新上传像素；同一版本
    /// 的像素永远相同（列的内容只依赖已定稿的桶）。
    waveform_version: u32 = 0,
    /// 非 null = 后台还在解码：峰值会继续长出来，播放要等 Player 建好。
    progress: ?AudioProgress = null,

    /// 同步播放入口（`--play-test` / bench）：首次调用同步建 Player，设备错误原样上抛。
    pub fn play(self: *AudioSession) !void {
        if (self.player) |player| return self.playExisting(player);
        if (self.lazy.starter != null) {
            self.lazy.cancelled = false;
            _ = try self.finishStart(true);
            return;
        }
        if (self.pcm.len == 0 and self.source == null) {
            if (self.progress) |progress| {
                self.lazy.state = .starting;
                progress.vtable.requestPlay(progress.ctx, true);
                return;
            }
            return error.NoAudioPlayer;
        }
        if (self.lazy.allocator == null) return error.NoAudioPlayer;
        const created = try self.lazy.createSync(
            self.pcm,
            self.sample_rate,
            self.channels,
            self.bits,
            self.sample_float,
            self.source,
            self.total_frames,
        );
        try self.adoptCreated(created);
    }

    /// UI 播放入口：WASAPI 在后台创建，状态立即可见，完成由 `pump` 接手并起播。
    pub fn startPlayback(self: *AudioSession) !void {
        if (self.player) |player| return self.playExisting(player);
        if (self.lazy.starter != null) {
            self.lazy.cancelled = false;
            return;
        }
        if (self.pcm.len == 0 and self.source == null) {
            const progress = self.progress orelse return error.NoAudioPlayer;
            self.lazy.state = .starting;
            self.lazy.failure = null;
            self.lazy.cancelled = false;
            progress.vtable.requestPlay(progress.ctx, true);
            return;
        }
        if (self.lazy.allocator == null) return error.NoAudioPlayer;
        try self.lazy.startAsync(self.pcm, self.sample_rate, self.channels, self.bits, self.sample_float, self.source, self.total_frames);
    }

    fn playExisting(self: *AudioSession, player: *audio_player.Player) audio_player.Error!void {
        try player.play();
        self.lazy.ready();
    }

    fn adoptCreated(self: *AudioSession, created: *audio_player.Player) audio_player.Error!void {
        self.player = created;
        self.playCreated(created) catch |err| {
            self.lazy.fail(err);
            return err;
        };
    }

    fn playCreated(self: *AudioSession, created: *audio_player.Player) audio_player.Error!void {
        // 打开后、首次播放前点击过波形：把暂存的播放头交给新建 Player。
        if (self.position_ms > 0) try created.seek(self.position_ms);
        try created.play();
        self.lazy.ready();
    }

    fn finishStart(self: *AudioSession, block: bool) audio_player.Error!bool {
        const created = (try self.lazy.collect(block)) orelse return false;
        if (self.lazy.cancelled) {
            created.deinit();
            self.lazy.state = .idle;
            self.lazy.failure = null;
            return true;
        }
        try self.adoptCreated(created);
        return true;
    }

    pub fn isStartingAudio(self: *const AudioSession) bool {
        return self.lazy.state == .starting;
    }

    pub fn audioError(self: *const AudioSession) ?audio_player.Error {
        return self.lazy.failure;
    }

    /// 停播；位置保留在最后播到的地方（不是归零）。
    pub fn stop(self: *AudioSession) void {
        self.lazy.cancelled = true;
        if (self.progress) |progress| progress.vtable.requestPlay(progress.ctx, false);
        if (self.player) |player| player.stop();
        self.position_ms = self.positionMs();
    }

    pub fn isPlaying(self: *const AudioSession) bool {
        const player = self.player orelse return false;
        return player.isPlaying();
    }

    /// UI 线程读取：来自 Player 的原子快照；没有设备时退回 `position_ms`。
    pub fn positionMs(self: *const AudioSession) u64 {
        const player = self.player orelse return self.position_ms;
        return player.positionMs();
    }

    pub fn durationMs(self: *const AudioSession) u64 {
        return self.duration_ms;
    }

    /// 已经解出的 PCM 字节数（渐进式解码中会增长；完成后等于 `pcm.len`）。
    pub fn pcmBytes(self: *const AudioSession) usize {
        if (self.pcm.len != 0) return self.pcm.len;
        if (self.source) |source| return source.residentBytes();
        const progress = self.progress orelse return 0;
        return progress.vtable.decodedBytes(progress.ctx);
    }

    /// 后台还在解码吗？视图用它显示"解码中"，不自己猜。
    pub fn isDecoding(self: *const AudioSession) bool {
        const progress = self.progress orelse return false;
        return progress.vtable.decoding(progress.ctx);
    }

    /// UI 线程每拍调一次：有新完成的波形就重画一版，全部完成时接手最终结果。
    /// 返回 true = 画面变了，调用方应重画。没有后台解码时是无操作。
    pub fn pump(self: *AudioSession) bool {
        var changed = false;
        if (self.progress) |progress| {
            changed = progress.vtable.pump(progress.ctx, self);
        }
        const player_changed = self.finishStart(false) catch |err| {
            std.debug.print(
                "otto-lite: 音频启动失败（{s} hresult=0x{x:0>8}）\n",
                .{ @errorName(err), @as(u32, @bitCast(audio_player.lastHresult())) },
            );
            return true;
        };
        return changed or player_changed;
    }

    /// 等后台解码结束并接手结果（无头命令 / 测试；正常 UI 用 `pump`）。
    pub fn waitComplete(self: *AudioSession) void {
        if (self.progress) |progress| progress.vtable.wait(progress.ctx, self);
    }

    /// 打断后台解码并 join（不释放引擎；`deinit` 会释放）。切换选中行时由
    /// `AudioSession.deinit` 调用，保证同一时刻只有一个解码任务在跑。
    pub fn cancelDecode(self: *AudioSession) void {
        if (self.progress) |progress| progress.vtable.cancel(progress.ctx);
    }

    /// 把播放头设到 `ms`，钳到 `[0, duration]`。
    ///
    /// 正在播时由 Player 丢弃端点缓冲后从新位置继续；没在播（或没有播放设备）
    /// 时只是记住位置，下一次 `play` 从这里开始。Player 的 seek 是同步的：
    /// 返回时 `positionMs()` 已经是新位置。
    pub fn seek(self: *AudioSession, ms: u64) !void {
        const target = @min(ms, self.duration_ms);
        if (self.player) |player| {
            try player.seek(target);
            self.position_ms = player.positionMs();
            return;
        }
        self.position_ms = target;
    }

    /// 停播 → join 播放线程 → 释放 Player、波形位图、峰值、PCM。
    /// 必须与 `open` 用同一个 allocator。
    pub fn deinit(self: *AudioSession, allocator: std.mem.Allocator) void {
        // 先打断后台解码并 join：它可能还在写 PCM / 峰值，不能先释放这些内存。
        if (self.progress) |progress| {
            progress.vtable.cancel(progress.ctx);
            progress.vtable.destroy(progress.ctx, allocator);
            self.progress = null;
        }
        // Player 创建工作线程借用 PCM，必须先 join，再释放 PCM/波形。
        self.lazy.deinit();
        if (self.player) |player| {
            player.stop();
            player.deinit();
            self.player = null;
        }
        if (self.waveform.pixels.len != 0) self.waveform.deinit(allocator);
        self.waveform = emptyBitmap;
        self.peaks.deinit(allocator);
        self.peaks = .{};
        if (self.pcm.len != 0) allocator.free(self.pcm);
        self.pcm = &.{};
        if (self.source) |source| pcm_source.destroyBoxed(source, allocator);
        self.source = null;
        self.total_frames = 0;
        self.position_ms = 0;
    }
};
