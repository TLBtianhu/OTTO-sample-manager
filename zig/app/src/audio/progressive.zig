//! 渐进式音频预览：**先出波形，后台补齐**。
//!
//! ## 为什么
//!
//! 预览条原来的路径是"整段解码 → 算 512 桶峰值 → 渲染位图 → 建 Player"，全部在
//! provider 的 `open` 里同步完成。41 秒 MP3 约 150 ms、10 分钟 FLAC 约 460 ms
//! （本机 release，见验收报告），长文件第一次点开时用户看到的是空白预览条。
//!
//! 现在 `open` 只解**开头 1/32 段**（`prefix_frames`），算出这一段已定稿的桶、
//! 立刻渲染一版波形返回；一条后台线程继续读剩下的帧，把峰值按**同一套桶边界**
//! 累加进同一组数组，UI 每拍把新完成的列画出来，直到整条波形长满。
//!
//! ## 逐桶相等是硬要求
//!
//! 桶区间由总帧数决定（`peaks.compute`：`[i*N/count, (i+1)*N/count)`），所以只有
//! **开流时总帧数已知**的容器能做渐进合并：
//!
//!   * WAV / FLAC / AIFF：头部就有总帧数；
//!   * MP3：有 Xing/VBRI 头时，第一帧解析完就有总帧数（读第一块之后才出现）；
//!   * **无 Xing 的 MP3、Ogg Vorbis、Ogg Opus：总帧数要到流尾的 granule 才知道**。
//!     提前切桶只能"按估计的总长画一版、最后再重排"，那是近似动画，不是 waveform。
//!     所以这些格式**走整段解码的老路径**（`fallback`）：第一版波形就是最终波形。
//!     Opus 的 20 ms 帧让"解 2 秒"只值 100 个包，但它真正的问题是**总长未知**，
//!     不是帧太短——这一点在报告里单独写清楚，不假装统一。
//!
//! 合并用 `peaks.Merger`：它按帧顺序、用与 `compute` **逐字相同**的边界公式累加。
//! 全部解完之后，如果实际帧数与声明的总帧数一致（正常文件），数组直接交出去；
//! 不一致（截断/头部说谎）就**从完整 PCM 重新算一次** `compute`——绝不把"按错误
//! 总长切的桶"当结果。`audio/progressive_test.zig` 用真文件钉住"逐桶相等"。
//!
//! ## 线程与所有权
//!
//!   1. `start` 在工作线程上跑：开流、解前缀、建峰值/位图、起后台线程；
//!   2. 后台线程独占 `decode.Stream` 与峰值累加器，过一把自旋锁发布
//!      `decoded_frames` / `complete_buckets`（UI 只读这两个数，不碰解码器）；
//!   3. 解完时线程 `finish` 出最终 PCM、把峰值交出去（或重算），不建 `Player`，
//!      然后在锁里放好 `finished` 并置 `done`；
//!   4. UI 线程 `pump`：还没完就按完成列数重画一版；`done` 后 join 并把 PCM /
//!      峰值**所有权转移**进 `preview.AudioSession`；首次播放才另建设备；
//!   5. 切换选中行时 `AudioSession.deinit` → `cancel`（置标志 + join）→ `destroy`，
//!      所以同一时刻只有一条解码线程，旧任务不会和新的抢 CPU。
//!
//! 位图只画**整列都定稿**的列（`waveform.completeColumns`），未解出的列保持透明。
//! 一列的像素因此只依赖已定稿的桶，`waveform_version`（= 完成列数）可以直接进
//! 图像缓存键，不会出现"同键不同像素"的旧图。

const std = @import("std");
const preview = @import("../preview.zig");
const decode_mod = @import("decode.zig");
const peaks_mod = @import("peaks.zig");
const player = @import("player.zig");
const lazy_player = @import("lazy_player.zig");
const session_mod = @import("session.zig");
const waveform = @import("waveform.zig");

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

/// 自旋锁：临界区只有"合并一块峰值 / 拷几个原子量"，没有 IO、没有分配。
/// 与 `preview_worker.zig` 同一套做法（Zig 0.17 没有不需要 Io 实例的 Mutex）。
const SpinLock = struct {
    flag: std.atomic.Value(bool) = .init(false),

    fn acquire(self: *SpinLock) void {
        var spins: u32 = 0;
        while (self.flag.swap(true, .acquire)) {
            spins +%= 1;
            if (spins > 64) {
                std.Thread.yield() catch {};
                spins = 0;
            }
        }
    }

    fn release(self: *SpinLock) void {
        self.flag.store(false, .release);
    }
};

/// `started` 到现在的毫秒数（单调时钟；只用于日志）。
fn elapsedMs(io: std.Io, started: std.Io.Clock.Timestamp) f64 {
    return @as(f64, @floatFromInt(started.untilNow(io).raw.nanoseconds)) / 1_000_000.0;
}

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
    if (!progressive_enabled or total == null or total.? == 0 or short) {
        // 老路径：整段解码 + 一次 compute + 建 Player。第一版波形就是最终波形。
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

    const total_frames = total.?;
    self.total_frames = total_frames;
    self.count = @intCast(@min(@as(u64, peaks_mod.default_buckets), total_frames));
    self.peaks_min = try allocator.alloc(i16, self.count);
    self.peaks_max = try allocator.alloc(i16, self.count);
    self.merger = peaks_mod.Merger.init(total_frames, self.count, self.peaks_min, self.peaks_max);
    self.decoded_frames.store(self.stream.frames, .release);
    self.mergePending();
    const init_done = std.Io.Clock.Timestamp.now(io, .awake);
    const init_ms = elapsedMs(io, self.started_at);

    // 前缀：总帧数的 1/32（至少 1 帧）。此时约 16 个桶定稿。
    const target = @max(@as(u64, 1), total_frames / prefix_divisor);
    while (self.stream.frames < target) {
        if (try self.stream.step(&chunk) == 0) break;
        self.mergePending();
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
    peaks: peaks_mod.Peaks = .{},
    player: ?*player.Player = null,
    duration_ms: u64 = 0,
};

/// 已解出但还没交给会话的最终结果。`peaks` 要么是累加器（所有权已移进来），
/// 要么是"实际帧数与声明不符"时重算出来的新数组。
const Engine = struct {
    allocator: std.mem.Allocator,
    path: []u8 = &.{},
    stream: decode_mod.Stream = undefined,
    total_frames: u64 = 0,
    count: usize = 0,
    peaks_min: []i16 = &.{},
    peaks_max: []i16 = &.{},
    merger: peaks_mod.Merger = undefined,
    merged_bytes: usize = 0,

    lock: SpinLock = .{},
    decoded_frames: std.atomic.Value(u64) = .init(0),
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
        self.* = .{ .allocator = allocator };
        // 计时从分配引擎之前算起：这一行之后就是路径拷贝 + 开文件 + 容器头 +
        // PCM 容量预留，`--preview` 的 open_ms 与日志里的 first_wave_ms 因此同一口径。
        self.started_at = std.Io.Clock.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .awake);
        self.path = allocator.dupe(u8, path) catch {
            allocator.destroy(self);
            return error.OutOfMemory;
        };
        self.stream.init(allocator, self.path, options) catch |err| {
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

    /// 线程内：EOF 之后收尾。峰值必须与"整段一次算"逐桶相等：
    ///   * 实际帧数 == 声明帧数 → 累加器就是答案，直接移交给 `Finished`；
    ///   * 不一致（截断/头部说谎）→ 从完整 PCM 重算，绝不移交按错误总长切的桶。
    fn finalize(self: *Engine) void {
        var decoded = self.stream.finish() catch |err| return self.fail(err);
        const io = std.Io.Threaded.global_single_threaded.io();
        const decode_ms = elapsedMs(io, self.started_at);
        const player_started = std.Io.Clock.Timestamp.now(io, .awake);

        var peaks: peaks_mod.Peaks = undefined;
        if (decoded.frames == self.total_frames) {
            // 累加器就是最终答案：**先别把数组从 `peaks_min/max` 摘走**——Player
            // 初始化还要几十毫秒，这期间 UI 可能已经推进到"全部桶定稿"并重画一版；
            // 摘走会让 renderPrefixInto 看到空 peaks、把位图清空并以新版本号缓存，
            // 之后同版本的最终像素再也画不出来（图集一个键只记第一张图）。
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
            peaks = peaks_mod.compute(
                self.allocator,
                decoded.pcm,
                decoded.channels,
                decoded.bits,
                decoded.format,
                peaks_mod.default_buckets,
            ) catch |err| {
                decoded.deinit(self.allocator);
                return self.fail(err);
            };
            // 声明长度与真实长度不符时不能把水位推到"全部桶定稿"：累加器要释放，
            // 而 UI 可能正处在 Player 初始化那几十毫秒里。保持最后一次一致的水位，
            // 最终版本由 adopt 用重算出来的 peaks 画。
            if (self.peaks_min.len != 0) self.allocator.free(self.peaks_min);
            if (self.peaks_max.len != 0) self.allocator.free(self.peaks_max);
            self.peaks_min = &.{};
            self.peaks_max = &.{};
            self.peaks_recomputed = true;
        }

        // 默认把 Player 留到第一次播放；false 仅用于恢复旧行为做反向测量。
        // 即便 eager 对照中设备失败，也只损失播放，完整波形仍正常交付。
        var created: ?*player.Player = null;
        if (!lazy_player.enabled and !self.cancel_flag.load(.acquire)) {
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

        self.lock.acquire();
        self.finished = .{
            .pcm = decoded.pcm,
            .peaks = peaks,
            .player = created,
            .duration_ms = decoded.duration_ms,
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
            session.peaks = fin.peaks;
            session.player = fin.player;
            if (fin.player != null) session.lazy.state = .ready;
            session.duration_ms = fin.duration_ms;
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
                "otto-lite: 渐进波形完成 file={s} frames={d} peaks={d} wave_version={d}\n",
                .{ self.path, session.pcm.len / (@as(usize, session.channels) * 2), session.peaks.len(), session.waveform_version },
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
        self.peaks_min = &.{};
        self.peaks_max = &.{};
        if (self.finished) |fin| {
            if (fin.pcm.len != 0) allocator.free(fin.pcm);
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
    const self = cast(ctx);
    const frames = self.decoded_frames.load(.acquire);
    return @intCast(frames * @as(u64, self.stream.channels) * 2);
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
