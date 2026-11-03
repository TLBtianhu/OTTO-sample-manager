//! 渐进式音频预览：先解 1/32 前缀出波形，后台按同一桶边界补齐。
//! 总帧数未知的容器不能提前切桶；短文件与旧对照路径仍一次算完。
//! `peaks.Merger` 与 `peaks.compute` 使用同一边界公式；声明长度失真时有界重算。
//! 后台线程独占解码流，UI 只读原子进度并在 `pump` 接管峰值和 PCM/有界帧源。
//! 切走先 cancel+join，旧任务不会与新文件同时驻留。驻留档位见 `residency.zig`。

const std = @import("std");
const preview = @import("../preview.zig");
const decode_mod = @import("decode.zig");
const peaks_mod = @import("peaks.zig");
const player = @import("player.zig");
const lazy_player = @import("lazy_player.zig");
const session_mod = @import("session.zig");
const waveform = @import("waveform.zig");
const residency = @import("residency.zig");
const pcm_source = @import("pcm_source.zig");
const sync = @import("progressive_sync.zig");
const stream_peaks = @import("stream_peaks.zig");
const fallback = @import("fallback.zig");

/// 前缀长度：总帧数的 1/32。512 桶时约 16 个桶定稿；240 列时约 7 列可见，
/// 足够"一眼看出这是哪段声音"，又不至于把首次出图拖回整段解码。
const prefix_divisor: u64 = 32;

/// 反向证明开关：改成 `false` 之后所有音频都走"整段解码一次算"的老路径，
/// 第一版波形时间必须回到整段解码的水平（验收报告里那组 ~150 ms 就是它）。
/// 只用来做对照实验，产品路径永远是 `true`。
pub const progressive_enabled = true;

/// 短于这个长度就整段解完再返回：几秒的样本解完只要几毫秒，为此起一条线程、
/// 让波形分两拍出现反而是退步（用户原来就感觉不到等待）。
const short_seconds: u64 = 3;

/// 后台解码线程的栈：`FileReader` 的 64 KiB 缓冲 + 解码器状态 + 16 KiB 块缓冲，
/// 1 MiB 与预览工作线程同档，和 `--mem-probe` 的提交量对得上。
const thread_stack_size: usize = 1 << 20;

const SpinLock = sync.SpinLock;
const elapsedMs = sync.elapsedMs;

/// `start` 的错误集：解码错误（四态映射在 `decode.reason`）+ 建播放器的错误
/// （只在"整段解完"的路径上出现；渐进路径的 Player 在后台建，失败只记日志）。
pub const StartError = decode_mod.Error || player.Error;

/// 一次预览的产物。`progressive = true` 表示波形还会长；`false` 表示第一版就是
/// 最终版（短文件 / 总帧数未知的容器，见文件头）。
pub const Start = struct {
    session: preview.AudioSession,
    progressive: bool,
};

/// 打开一个音频预览。`options.expected_format` 与 `decode()` 完全一致：
/// wasapi-pcm 传 `.wav`（内容不是 WAV 就谢绝），native-audio 传 null（认出什么解什么）。
pub fn start(
    allocator: std.mem.Allocator,
    path: []const u8,
    options: decode_mod.Options,
) StartError!Start {
    const self = try Engine.create(allocator, path, options);
    var owned = true;
    defer if (owned) self.deinit(allocator);
    const io = std.Io.Threaded.global_single_threaded.io();

    var chunk: [decode_mod.chunk_samples]i16 = undefined;
    // 先读一块：MP3 的 Xing 头在这一块里解析，总帧数之后才可见。
    const first = try self.stream.step(&chunk);
    if (first == 0) return error.Empty;

    const total = self.stream.declaredFrames();
    const short = total != null and total.? <= @as(u64, self.stream.sample_rate) * short_seconds;
    if (total) |frames| self.mode = residency.choose(residency.estimatedBytes(frames, self.stream.sample_rate, self.stream.channels));
    if (progressive_enabled and total == null) {
        const session = try fallback.build(allocator, &self.stream, self.path, self.options);
        owned = false;
        self.deinit(allocator);
        return .{ .session = session, .progressive = false };
    }
    if (!progressive_enabled or total == null or total.? == 0 or (short and self.mode == .full_decode)) {
        // 老路径：整段解码 + 一次 compute + 建 Player。第一版波形就是最终波形。
        try self.stream.retainAll();
        while (true) {
            if (try self.stream.step(&chunk) == 0) break;
        }
        var decoded = try self.stream.finish();
        defer decoded.deinit(allocator);
        const session = try session_mod.build(allocator, &decoded);
        owned = false;
        self.deinit(allocator);
        return .{ .session = session, .progressive = false };
    }
    if (self.mode == .full_decode) try self.stream.retainAll() else self.stream.setRetention(residency.retentionBytes(self.mode).?);

    const total_frames = total.?;
    self.total_frames = total_frames;
    self.count = @intCast(@min(@as(u64, peaks_mod.default_buckets), total_frames));
    self.peaks_min = try allocator.alloc(i16, self.count);
    self.peaks_max = try allocator.alloc(i16, self.count);
    self.merger = peaks_mod.Merger.init(total_frames, self.count, self.peaks_min, self.peaks_max);
    self.decoded_frames.store(self.stream.frames, .release);
    self.mergePending();
    try self.compact();
    const init_done = std.Io.Clock.Timestamp.now(io, .awake);
    const init_ms = elapsedMs(io, self.started_at);

    // 前缀：总帧数的 1/32（至少 1 帧）。此时约 16 个桶定稿。
    const target = @max(@as(u64, 1), total_frames / prefix_divisor);
    while (self.stream.frames < target) {
        if (try self.stream.step(&chunk) == 0) break;
        self.mergePending();
        try self.compact();
        self.decoded_frames.store(self.stream.frames, .release);
    }
    const prefix_done = std.Io.Clock.Timestamp.now(io, .awake);
    const prefix_ms = elapsedMs(io, init_done);

    const bitmap = try waveform.renderPrefix(
        allocator,
        .{ .min = self.peaks_min, .max = self.peaks_max },
        waveform.default_width,
        waveform.default_height,
        waveform.default_color,
        self.merger.complete,
    );
    const bitmap_ms = elapsedMs(io, prefix_done);
    var bitmap_owned = true;
    defer if (bitmap_owned) allocator.free(bitmap.pixels);

    const channels = self.stream.channels;
    const session: preview.AudioSession = .{
        .pcm = &.{},
        .sample_rate = self.stream.sample_rate,
        .channels = channels,
        .bits = 16,
        .duration_ms = total_frames * 1000 / self.stream.sample_rate,
        .total_frames = total_frames,
        .pcm_residency = self.mode,
        .lazy = .{ .allocator = allocator },
        .peaks = .{},
        .waveform = bitmap,
        .waveform_version = waveform.completeColumns(self.count, bitmap.width, self.merger.complete),
        .progress = self.interface(),
    };
    self.rendered_columns = session.waveform_version;

    self.thread = std.Thread.spawn(.{ .stack_size = thread_stack_size }, Engine.threadMain, .{self}) catch {
        return error.ThreadFailure;
    };
    bitmap_owned = false;
    owned = false;
    std.debug.print(
        "otto-lite: 渐进波形首帧 file={s} prefix_frames={d}/{d} first_wave_ms={d:.2} init_ms={d:.2} prefix_ms={d:.2} bitmap_ms={d:.2} columns={d}/{d} decoding=1\n",
        .{
            self.path,
            self.stream.frames,
            total_frames,
            elapsedMs(io, self.started_at),
            init_ms,
            prefix_ms,
            bitmap_ms,
            session.waveform_version,
            bitmap.width,
        },
    );
    return .{ .session = session, .progressive = true };
}

const Finished = struct {
    pcm: []u8 = &.{},
    source: ?*pcm_source.Source = null,
    mode: residency.Mode = .auto,
    peaks: peaks_mod.Peaks = .{},
    player: ?*player.Player = null,
    duration_ms: u64 = 0,
    total_frames: u64 = 0,
};

/// 已解出但还没交给会话的最终结果。`peaks` 要么是累加器（所有权已移进来），
/// 要么是"实际帧数与声明不符"时重算出来的新数组。
const Engine = struct {
    allocator: std.mem.Allocator,
    path: []u8 = &.{},
    stream: decode_mod.Stream = undefined,
    options: decode_mod.Options = .{},
    mode: residency.Mode = .auto,
    total_frames: u64 = 0,
    count: usize = 0,
    peaks_min: []i16 = &.{},
    peaks_max: []i16 = &.{},
    merger: peaks_mod.Merger = undefined,
    merged_bytes: usize = 0,
    playback_window: []u8 = &.{},

    lock: SpinLock = .{},
    decoded_frames: std.atomic.Value(u64) = .init(0),
    resident_bytes: std.atomic.Value(usize) = .init(0),
    /// 已定稿的桶数（锁内读写）。
    complete_buckets: usize = 0,
    status: std.atomic.Value(Status) = .init(.decoding),
    done: std.atomic.Value(bool) = .init(false),
    cancel_flag: std.atomic.Value(bool) = .init(false),
    want_play: std.atomic.Value(bool) = .init(false),
    finished: ?Finished = null,
    /// `finished.peaks` 是重算出来的新数组（与累加器不是同一块内存）。
    /// `false` 时 `finished.peaks` 只是 `peaks_min/max` 的别名，所有权在 adopt 时转移。
    peaks_recomputed: bool = false,
    adopted: bool = false,
    rendered_columns: u32 = 0,
    /// 开流时刻（`start` 入口）：日志里的 first_wave_ms / full_ms 用它。
    started_at: std.Io.Clock.Timestamp = undefined,

    thread: ?std.Thread = null,

    const Status = enum(u8) { decoding, done, failed, cancelled, adopted };

    fn create(
        allocator: std.mem.Allocator,
        path: []const u8,
        options: decode_mod.Options,
    ) StartError!*Engine {
        const self = try allocator.create(Engine);
        self.* = .{ .allocator = allocator, .options = .{ .expected_format = options.expected_format } };
        // 计时从分配引擎之前算起：这一行之后就是路径拷贝 + 开文件 + 容器头 +
        // PCM 容量预留，`--preview` 的 open_ms 与日志里的 first_wave_ms 因此同一口径。
        self.started_at = std.Io.Clock.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .awake);
        self.path = allocator.dupe(u8, path) catch {
            allocator.destroy(self);
            return error.OutOfMemory;
        };
        var stream_options = options;
        stream_options.retain_bytes = residency.initialRetention();
        self.stream.init(allocator, self.path, stream_options) catch |err| {
            allocator.free(self.path);
            allocator.destroy(self);
            return err;
        };
        return self;
    }

    fn interface(self: *Engine) preview.AudioProgress {
        return .{ .ctx = self, .vtable = &vtable };
    }

    /// 线程内：解一块并合并峰值。返回新增帧数（0 = EOF）。
    fn stepAndMerge(self: *Engine, chunk: []i16) decode_mod.Error!u64 {
        const got = try self.stream.step(chunk);
        if (got == 0) return 0;
        self.lock.acquire();
        self.mergePendingLocked();
        self.complete_buckets = self.merger.complete;
        self.lock.release();
        self.decoded_frames.store(self.stream.frames, .release);
        try self.compact();
        return got;
    }

    fn mergePending(self: *Engine) void {
        self.lock.acquire();
        self.mergePendingLocked();
        self.complete_buckets = self.merger.complete;
        self.lock.release();
    }

    fn mergePendingLocked(self: *Engine) void {
        if (self.count == 0) return;
        const items = self.stream.pcm.items;
        if (self.merged_bytes >= items.len) return;
        const from = self.merged_bytes;
        self.merged_bytes = items.len;
        self.merger.push(items[from..], self.stream.channels, 16, .pcm);
    }

    fn compact(self: *Engine) error{OutOfMemory}!void {
        if (self.mode == .bounded_playback and self.playback_window.len == 0) {
            const window_bytes = @import("../mem_budget.zig").bounded_window_bytes;
            if (self.stream.pcm.items.len < window_bytes) {
                self.resident_bytes.store(self.stream.pcm.capacity + @import("file_reader.zig").buffer_size, .release);
                return;
            }
            self.playback_window = try self.allocator.dupe(u8, self.stream.pcm.items[0..window_bytes]);
            self.stream.pcm.deinit(self.allocator);
            self.stream.pcm = .empty;
            self.stream.setRetention(@import("../mem_budget.zig").streaming_pcm_bytes);
            try self.stream.pcm.ensureTotalCapacityPrecise(self.allocator, @import("../mem_budget.zig").streaming_pcm_bytes + decode_mod.chunk_samples * 2);
        }
        if (self.mode != .full_decode) self.stream.discardConsumed();
        self.merged_bytes = self.stream.pcm.items.len;
        self.resident_bytes.store(self.playback_window.len + self.stream.pcm.capacity + @import("file_reader.zig").buffer_size, .release);
    }

    fn threadMain(self: *Engine) void {
        var chunk: [decode_mod.chunk_samples]i16 = undefined;
        while (true) {
            if (self.cancel_flag.load(.acquire)) return self.finishCancelled();
            const got = self.stepAndMerge(&chunk) catch |err| return self.fail(err);
            if (got == 0) break;
        }
        if (self.cancel_flag.load(.acquire)) return self.finishCancelled();
        self.finalize();
    }

    fn finishCancelled(self: *Engine) void {
        self.lock.acquire();
        self.status.store(.cancelled, .release);
        self.done.store(true, .release);
        self.lock.release();
    }

    fn fail(self: *Engine, err: decode_mod.Error) void {
        self.lock.acquire();
        self.status.store(.failed, .release);
        self.done.store(true, .release);
        self.lock.release();
        std.debug.print(
            "otto-lite: 渐进式解码中断 file={s} error={s} decoded={d}/{d} frames\n",
            .{ self.path, @errorName(err), self.decoded_frames.load(.acquire), self.total_frames },
        );
    }

    fn finalize(self: *Engine) void {
        var decoded = self.stream.finish() catch |err| return self.fail(err);
        self.stream.deinit(); // 解码已完成：文件句柄/读取缓冲不等会话关闭才释放。
        const io = std.Io.Threaded.global_single_threaded.io();
        const decode_ms = elapsedMs(io, self.started_at);
        const player_started = std.Io.Clock.Timestamp.now(io, .awake);

        var peaks: peaks_mod.Peaks = undefined;
        if (decoded.frames == self.total_frames) {
            self.lock.acquire();
            self.merger.finish();
            self.complete_buckets = self.merger.complete;
            self.lock.release();
            peaks = .{ .min = self.peaks_min, .max = self.peaks_max };
        } else {
            std.debug.print(
                "otto-lite: 渐进峰值按实际帧数重算 file={s} declared={d} actual={d}\n",
                .{ self.path, self.total_frames, decoded.frames },
            );
            peaks = if (self.mode == .full_decode)
                peaks_mod.compute(
                    self.allocator,
                    decoded.pcm,
                    decoded.channels,
                    decoded.bits,
                    decoded.format,
                    peaks_mod.default_buckets,
                ) catch |err| {
                    decoded.deinit(self.allocator);
                    return self.fail(err);
                }
            else
                stream_peaks.compute(self.allocator, self.path, self.options, decoded.frames, peaks_mod.default_buckets) catch |err| {
                    decoded.deinit(self.allocator);
                    return self.fail(err);
                };
            if (self.peaks_min.len != 0) self.allocator.free(self.peaks_min);
            if (self.peaks_max.len != 0) self.allocator.free(self.peaks_max);
            self.peaks_min = &.{};
            self.peaks_max = &.{};
            self.peaks_recomputed = true;
        }

        var created: ?*player.Player = null;
        if (!lazy_player.enabled and self.mode == .full_decode and !self.cancel_flag.load(.acquire)) {
            created = player.Player.create(
                self.allocator,
                decoded.pcm,
                decoded.sample_rate,
                decoded.channels,
                decoded.bits,
                decoded.format == .float,
            ) catch |err| blk: {
                std.debug.print(
                    "otto-lite: 渐进预览播放器未建立 file={s} error={s} hresult=0x{x:0>8}\n",
                    .{ self.path, @errorName(err), @as(u32, @bitCast(player.lastHresult())) },
                );
                break :blk null;
            };
        }

        var source: ?*pcm_source.Source = null;
        if (self.mode != .full_decode) {
            if (decoded.pcm.len != 0) {
                self.allocator.free(decoded.pcm);
                decoded.pcm = &.{};
            }
            const initial: []u8 = if (self.mode == .bounded_playback) self.playback_window else &.{};
            source = pcm_source.createNative(
                self.allocator,
                self.path,
                self.options,
                decoded.channels,
                decoded.frames,
                initial,
            ) catch |err| {
                decoded.deinit(self.allocator);
                return self.fail(err);
            };
            if (self.mode == .bounded_playback) self.playback_window = &.{};
        }

        self.lock.acquire();
        self.finished = .{
            .pcm = decoded.pcm,
            .source = source,
            .mode = self.mode,
            .peaks = peaks,
            .player = created,
            .duration_ms = decoded.duration_ms,
            .total_frames = decoded.frames,
        };
        decoded.pcm = &.{};
        self.status.store(.done, .release);
        self.done.store(true, .release);
        self.lock.release();

        std.debug.print(
            "otto-lite: 渐进波形补全 file={s} decode_ms={d:.2} player_ms={d:.2} frames={d} peaks={d}\n",
            .{
                self.path,
                decode_ms,
                elapsedMs(io, player_started),
                decoded.frames,
                peaks.len(),
            },
        );
    }

    /// UI 线程：把最终结果移进会话并画最终波形。返回画面是否真的变了。
    fn adopt(self: *Engine, session: *preview.AudioSession) bool {
        if (self.adopted) return false;
        self.adopted = true;
        self.lock.acquire();
        const finished = self.finished;
        self.finished = null;
        self.lock.release();

        if (finished) |fin| {
            session.pcm = fin.pcm;
            session.source = fin.source;
            session.pcm_residency = fin.mode;
            session.peaks = fin.peaks;
            session.player = fin.player;
            if (fin.player != null) session.lazy.state = .ready;
            session.duration_ms = fin.duration_ms;
            session.total_frames = fin.total_frames;
            // 累加器的所有权现在归会话：摘掉引擎这边的别名，`deinit` 就不会重复释放。
            if (!self.peaks_recomputed) {
                self.peaks_min = &.{};
                self.peaks_max = &.{};
            }
            if (session.waveform.pixels.len != 0) {
                waveform.renderPrefixInto(
                    session.waveform.pixels,
                    session.waveform.stride,
                    session.waveform.width,
                    session.waveform.height,
                    session.peaks,
                    waveform.default_color,
                    session.peaks.len(),
                );
                session.waveform_version = session.waveform.width;
            }
            if (self.want_play.swap(false, .acquire)) {
                session.startPlayback() catch |err| std.debug.print(
                    "otto-lite: 预览补播失败 file={s} error={s}\n",
                    .{ self.path, @errorName(err) },
                );
            }
            std.debug.print(
                "otto-lite: 渐进波形完成 file={s} frames={d} peaks={d} wave_version={d} mode={s} resident_pcm={d}\n",
                .{ self.path, session.total_frames, session.peaks.len(), session.waveform_version, fin.mode.label(), session.pcmBytes() },
            );
        }
        self.status.store(.adopted, .release);
        return finished != null;
    }

    fn deinit(self: *Engine, allocator: std.mem.Allocator) void {
        self.cancel();
        self.stream.deinit();
        if (self.peaks_min.len != 0) allocator.free(self.peaks_min);
        if (self.peaks_max.len != 0) allocator.free(self.peaks_max);
        if (self.playback_window.len != 0) allocator.free(self.playback_window);
        self.playback_window = &.{};
        self.peaks_min = &.{};
        self.peaks_max = &.{};
        if (self.finished) |fin| {
            if (fin.pcm.len != 0) allocator.free(fin.pcm);
            if (fin.source) |source| pcm_source.destroyBoxed(source, allocator);
            // 重算出来的 peaks 是新数组；别名情形由下面的 peaks_min/max 释放。
            if (self.peaks_recomputed) fin.peaks.deinit(allocator);
            if (fin.player) |created| {
                created.stop();
                created.deinit();
            }
            self.finished = null;
        }
        if (self.path.len != 0) allocator.free(self.path);
        self.path = &.{};
        allocator.destroy(self);
    }

    fn cancel(self: *Engine) void {
        self.cancel_flag.store(true, .release);
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }
};

// ---------------------------------------------------------------------------
// vtable：UI 线程只经过这几个函数，不认识 Engine
// ---------------------------------------------------------------------------

fn cast(ctx: *anyopaque) *Engine {
    return @ptrCast(@alignCast(ctx));
}

fn pumpImpl(ctx: *anyopaque, session: *preview.AudioSession) bool {
    const self = cast(ctx);
    if (self.adopted) return false;
    if (self.done.load(.acquire)) {
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        return self.adopt(session);
    }

    var changed = false;
    var columns: u32 = 0;
    var completed: usize = 0;
    self.lock.acquire();
    completed = self.complete_buckets;
    columns = waveform.completeColumns(self.count, session.waveform.width, completed);
    if (columns > self.rendered_columns and session.waveform.pixels.len != 0) {
        waveform.renderPrefixInto(
            session.waveform.pixels,
            session.waveform.stride,
            session.waveform.width,
            session.waveform.height,
            .{ .min = self.peaks_min, .max = self.peaks_max },
            waveform.default_color,
            completed,
        );
        session.waveform_version = columns;
        self.rendered_columns = columns;
        changed = true;
    }
    self.lock.release();

    if (changed) {
        std.debug.print(
            "otto-lite: 渐进波形 file={s} columns={d}/{d} buckets={d}/{d} version={d}\n",
            .{ self.path, columns, session.waveform.width, completed, self.count, session.waveform_version },
        );
    }
    return changed;
}

fn waitImpl(ctx: *anyopaque, session: *preview.AudioSession) void {
    const self = cast(ctx);
    if (self.adopted) return;
    if (self.thread) |thread| {
        thread.join();
        self.thread = null;
    }
    _ = self.adopt(session);
}

fn cancelImpl(ctx: *anyopaque) void {
    cast(ctx).cancel();
}

fn destroyImpl(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    cast(ctx).deinit(allocator);
}

fn decodedBytesImpl(ctx: *anyopaque) usize {
    return cast(ctx).resident_bytes.load(.acquire);
}

fn decodingImpl(ctx: *anyopaque) bool {
    return cast(ctx).status.load(.acquire) == .decoding;
}

fn requestPlayImpl(ctx: *anyopaque, wanted: bool) void {
    cast(ctx).want_play.store(wanted, .release);
}

const vtable: preview.AudioProgress.VTable = .{
    .pump = pumpImpl,
    .wait = waitImpl,
    .cancel = cancelImpl,
    .destroy = destroyImpl,
    .decodedBytes = decodedBytesImpl,
    .decoding = decodingImpl,
    .requestPlay = requestPlayImpl,
};
