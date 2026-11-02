//! 一个音频播放会话：**播放线程 + 命令协议 + 原子位置快照**。
//!
//! ## 线程模型
//!
//! `Player.create` 起一条**播放线程**，在这条线程里完成 `CoInitializeEx(MTA)` 与
//! 整条 WASAPI 初始化（`wasapi.Render.open`）。初始化结果通过一条 manual-reset
//! 事件 `ready` 交回创建者：所以 `create` 能同步返回 `NoAudioEndpoint` /
//! `DeviceFailure`，而 COM 仍然只在播放线程里初始化过。
//!
//! 之后线程阻塞在 `WaitForMultipleObjects([音频事件, 命令事件])` 上——没有轮询：
//!
//!   * 音频事件 → `GetCurrentPadding` / `GetBuffer` / 拷贝 / `ReleaseBuffer`，
//!     并把"已播帧数"以毫秒写进 `position`（`std.atomic.Value(u64)`）；
//!   * 命令事件 → `play` / `stop` / `seek` / `quit`，各回一次 `ack`，调用方等待
//!     ack 所以 `play()` / `seek()` / `deinit()` 的错误与完成都是同步可见的。
//!
//! ## seek 为什么用 Stop + Reset（而不是填静音）
//!
//! `GetBuffer` 只能拿到缓冲的**空闲**部分；seek 时已经排队、还没播出去的旧数据
//! 是 `GetCurrentPadding` 报的 padding，用 GetBuffer 根本碰不到它。只填静音的话，
//! seek 之后会先把旧位置的声音播完，位置也会因为计算基准没变而跳回去。
//! `IAudioClient::Reset` 会丢弃整个端点缓冲并把 padding 归零（官方要求先 Stop），
//! 所以这里复用 `wasapi.Render.stop()` 的 Stop + Reset，再从新帧号重新 Start：
//! 缓冲里没有旧数据，`position = base + queued - padding` 也从新基准重新计。
//!
//! ## 播放位置
//!
//! `Playback.base` 是这一轮 Start 对应的 PCM 帧号；`queued` 是本轮 ReleaseBuffer
//! 的帧数；已播帧 = `base + queued - padding`。暂停时把 cursor 对齐到"确实离开
//! 设备缓冲"的那一帧，下一次 play 就从这个位置继续（播到结尾后则从 0 重播）。
//!
//! UI 线程**只读** `positionMs()` / `isPlaying()`（原子 load），绝不碰设备句柄；
//! 播放线程也绝不碰 UI。`deinit` 发 quit → join → 关事件/设备 → 释放自己。
//!
//! ## 所有权
//!
//! `Player` 由创建它的 allocator 分配；`pcm` **借用**（归 `AudioSession` 所有，
//! 生命周期必须覆盖 Player）。`deinit` 之后 Player 指针失效。
//!
//! 不重采样：交给 `Initialize` 的就是源采样率/位深/声道（见 `wasapi.buildFormat`）。

const std = @import("std");
const win = @import("win32.zig");
const wasapi = @import("wasapi.zig");

pub const Error = error{
    OutOfMemory,
    Unsupported,
    NoAudioEndpoint,
    DeviceFailure,
    ThreadFailure,
    InvalidFormat,
};

const Command = enum(u8) { idle, play, stop, seek, quit };
const InitState = enum(u8) { pending, ok, no_endpoint, device };

/// 等初始化结果的上限。设备枚举/Initialize 正常是毫秒级；真卡住也不该把
/// provider 的工作线程永远挂在 `create` 里。
const init_timeout_ms: u32 = 10_000;
/// 等 play/stop/quit 的 ack。Start/Stop 是很快的；超时按失败处理。
const command_timeout_ms: u32 = 2_000;

/// 所有会话共用的最近一次 HRESULT，供 `--preview` / `--play-test` 打一行诊断。
var last_hresult: std.atomic.Value(i32) = .init(0);

pub fn lastHresult() i32 {
    return last_hresult.load(.acquire);
}

/// 已交给 WASAPI 的帧数状态（只在播放线程里读写）。
const Playback = struct {
    running: bool = false,
    /// 下一个要拷贝的 PCM 帧号（整段 PCM 的绝对下标，不是本轮偏移）。
    cursor: u64 = 0,
    /// 本轮 Start 之后已 ReleaseBuffer 的总帧数（含结尾补的静音）。
    queued: u64 = 0,
    /// 本轮 Start 在整段 PCM 里的起始帧号（seek 后不是 0）。
    base: u64 = 0,
    /// 自然播到结尾：下一次 play 从头重播（seek 到中间不走这条）。
    completed: bool = false,
};

/// 已播帧数：本轮起点 + 离开设备缓冲的帧（`queued - padding`），钳到总帧。
/// `queued` 是**本次快照之前**的值；`+|` 防止设备刚 Reset 时的计数回绕。
fn playedFrames(base: u64, queued: u64, padding: u32, total: u64) u64 {
    const in_buffer = @min(queued, @as(u64, padding));
    return @min(base +| (queued - in_buffer), total);
}

/// 毫秒 → PCM 帧号（按源采样率，不重采样），并钳到总帧。
fn frameForMs(ms: u64, sample_rate: u32, total_frames: u64) u64 {
    if (sample_rate == 0) return 0;
    return @min(ms *| @as(u64, sample_rate) / 1000, total_frames);
}

pub const Player = struct {
    allocator: std.mem.Allocator,
    /// 借用：归 AudioSession，Player 不释放。
    pcm: []const u8,
    sample_rate: u32,
    channels: u16,
    bits: u16,
    block_align: u32,
    total_frames: u64,
    float: bool,

    thread: std.Thread = undefined,
    thread_started: bool = false,

    ready_event: ?win.HANDLE = null,
    command_event: ?win.HANDLE = null,
    ack_event: ?win.HANDLE = null,

    init_state: std.atomic.Value(InitState) = .init(.pending),
    init_hresult: std.atomic.Value(i32) = .init(0),

    command: std.atomic.Value(Command) = .init(.idle),
    /// `.seek` 的参数。UI 线程先写这里、再投递命令；播放线程在 ack 前已经读走。
    seek_target_ms: std.atomic.Value(u64) = .init(0),
    ack_hresult: std.atomic.Value(i32) = .init(0),

    playing: std.atomic.Value(bool) = .init(false),
    /// 毫秒。播放线程写、UI 线程读；这是唯一的跨线程播放位置。
    position: std.atomic.Value(u64) = .init(0),

    /// 建会话并完成 WASAPI 初始化（同步返回结果，COM 在播放线程里初始化）。
    /// 成功返回的 Player 需要 `deinit`；`pcm` 必须活到 `deinit` 之后。
    pub fn create(
        allocator: std.mem.Allocator,
        pcm: []const u8,
        sample_rate: u32,
        channels: u16,
        bits: u16,
        float: bool,
    ) Error!*Player {
        if (!win.supported) return error.Unsupported;
        if (sample_rate == 0 or channels == 0 or channels > 2) return error.InvalidFormat;
        if (bits == 0 or bits > 32 or bits % 8 != 0) return error.InvalidFormat;
        if (float and bits != 32) return error.InvalidFormat;

        const block_align: u32 = @as(u32, channels) * (bits / 8);
        if (pcm.len == 0 or pcm.len % @as(usize, block_align) != 0) return error.InvalidFormat;

        const self = try allocator.create(Player);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .pcm = pcm,
            .sample_rate = sample_rate,
            .channels = channels,
            .bits = bits,
            .block_align = block_align,
            .total_frames = pcm.len / @as(usize, block_align),
            .float = float,
        };

        self.ready_event = win.CreateEventW(null, 1, 0, null) orelse return self.failCreate(win.GetLastError());
        self.command_event = win.CreateEventW(null, 0, 0, null) orelse return self.failCreate(win.GetLastError());
        self.ack_event = win.CreateEventW(null, 0, 0, null) orelse return self.failCreate(win.GetLastError());

        self.thread = std.Thread.spawn(.{}, threadMain, .{self}) catch {
            self.closeHandles();
            last_hresult.store(win.E_FAIL, .release);
            return error.ThreadFailure;
        };
        self.thread_started = true;

        const ready = win.WaitForSingleObject(self.ready_event.?, init_timeout_ms);
        if (ready != win.WAIT_OBJECT_0) {
            self.thread.join();
            self.thread_started = false;
            self.closeHandles();
            last_hresult.store(win.hresultFromWin32(win.WAIT_TIMEOUT), .release);
            return error.ThreadFailure;
        }

        const state = self.init_state.load(.acquire);
        if (state != .ok) {
            self.thread.join();
            self.thread_started = false;
            self.closeHandles();
            return switch (state) {
                .no_endpoint => error.NoAudioEndpoint,
                else => error.DeviceFailure,
            };
        }
        return self;
    }

    /// 从当前位置播放（首次是 0；暂停/seek 之后就是那个位置；播完再调一次是重播）。
    /// 失败返回 DeviceFailure，原因在 `lastHresult()`。
    pub fn play(self: *Player) Error!void {
        if (self.init_state.load(.acquire) != .ok) return error.DeviceFailure;
        const code = self.post(.play);
        if (win.failed(code)) return error.DeviceFailure;
    }

    /// 把播放头设到 `ms`（钳到 `[0, duration]`）。
    ///
    /// 正在播时：Stop + Reset 丢掉整条端点缓冲，再从新位置 Start——已经排队但
    /// 没播出去的旧数据不会先响一下（见文件头）。没在播时：只改 cursor，下一次
    /// `play` 从这里开始。两种情况下 `position` 都在 ack 之前更新。
    pub fn seek(self: *Player, ms: u64) Error!void {
        if (self.init_state.load(.acquire) != .ok) return error.DeviceFailure;
        const target = @min(ms, self.durationMs());
        self.seek_target_ms.store(target, .release);
        const code = self.post(.seek);
        if (win.failed(code)) return error.DeviceFailure;
    }

    /// 停止播放，位置保留在最后播到的地方（`--play-test` 的"最终位置"）。
    pub fn stop(self: *Player) void {
        if (self.init_state.load(.acquire) != .ok) return;
        _ = self.post(.stop);
    }

    /// UI 线程只读：播放位置（毫秒）。
    pub fn positionMs(self: *const Player) u64 {
        return self.position.load(.acquire);
    }

    pub fn durationMs(self: *const Player) u64 {
        return self.total_frames * 1000 / self.sample_rate;
    }

    pub fn isPlaying(self: *const Player) bool {
        return self.playing.load(.acquire);
    }

    /// 停播 → 发 quit → join → 关句柄 → 释放自己。之后指针不可再用。
    pub fn deinit(self: *Player) void {
        if (self.thread_started) {
            _ = self.post(.quit);
            self.thread.join();
            self.thread_started = false;
        }
        self.closeHandles();
        self.allocator.destroy(self);
    }

    // -----------------------------------------------------------------------
    // 内部
    // -----------------------------------------------------------------------

    fn failCreate(self: *Player, win32_code: u32) Error!*Player {
        const code = win.hresultFromWin32(win32_code);
        self.init_hresult.store(code, .release);
        last_hresult.store(code, .release);
        self.closeHandles();
        return error.ThreadFailure;
    }

    fn closeHandles(self: *Player) void {
        inline for (.{ "ready_event", "command_event", "ack_event" }) |field| {
            if (@field(self, field)) |handle| {
                _ = win.CloseHandle(handle);
                @field(self, field) = null;
            }
        }
    }

    /// 把命令放进唯一一格并等 ack。返回 ack 的 HRESULT（S_OK = 成功）。
    fn post(self: *Player, command: Command) i32 {
        const command_event = self.command_event orelse return win.E_FAIL;
        const ack_event = self.ack_event orelse return win.E_FAIL;
        self.ack_hresult.store(win.S_OK, .release);
        self.command.store(command, .release);
        _ = win.SetEvent(command_event);
        const waited = win.WaitForSingleObject(ack_event, command_timeout_ms);
        if (waited != win.WAIT_OBJECT_0) {
            last_hresult.store(win.E_FAIL, .release);
            return win.E_FAIL;
        }
        const code = self.ack_hresult.load(.acquire);
        if (win.failed(code)) last_hresult.store(code, .release);
        return code;
    }

    fn finishInit(self: *Player, state: InitState, code: i32) void {
        self.init_hresult.store(code, .release);
        self.init_state.store(state, .release);
        last_hresult.store(code, .release);
        if (self.ready_event) |event| _ = win.SetEvent(event);
    }

    /// 播放线程：COM 初始化 → 设备 → 事件循环。所有设备句柄都死在这条线程里。
    fn threadMain(self: *Player) void {
        const co_hr = win.CoInitializeEx(null, win.COINIT_MULTITHREADED);
        if (win.failed(co_hr)) {
            self.finishInit(.device, co_hr);
            return;
        }
        defer win.CoUninitialize();

        const audio_event = win.CreateEventW(null, 0, 0, null) orelse {
            self.finishInit(.device, win.hresultFromWin32(win.GetLastError()));
            return;
        };
        defer _ = win.CloseHandle(audio_event);

        // 共享模式下把源格式原样交给引擎：不重采样、不改位深。
        const format = wasapi.buildFormat(self.channels, self.sample_rate, self.bits, self.float);
        const render = wasapi.Render.open(&format, audio_event) catch |err| {
            const state: InitState = if (err == error.NoAudioEndpoint) .no_endpoint else .device;
            self.finishInit(state, wasapi.lastHresult());
            return;
        };
        defer render.close();
        self.finishInit(.ok, win.S_OK);

        var playback = Playback{};
        const command_event = self.command_event orelse return;
        const handles = [2]win.HANDLE{ audio_event, command_event };

        while (true) {
            const waited = win.WaitForMultipleObjects(2, &handles, 0, win.INFINITE);
            if (waited == win.WAIT_OBJECT_0) {
                if (playback.running) self.service(render, &playback);
            } else if (waited == win.WAIT_OBJECT_0 + 1) {
                const command = self.command.swap(.idle, .acquire);
                switch (command) {
                    .play => {
                        // 已经在播：Enter/Space 自己判过，不在这里重头再来。
                        if (!playback.running) {
                            if (playback.completed or playback.cursor >= self.total_frames) {
                                playback.cursor = 0;
                                playback.base = 0;
                            }
                            // 从 cursor 续播：base 必须跟着它走（service 误差路径下
                            // 可能还留着上一轮的 base）。
                            playback.base = playback.cursor;
                            playback.queued = 0;
                            playback.running = true;
                            playback.completed = false;
                            self.position.store(playback.cursor * 1000 / self.sample_rate, .release);
                            render.start() catch {
                                playback.running = false;
                                self.playing.store(false, .release);
                                self.ack_hresult.store(wasapi.lastHresult(), .release);
                                _ = win.SetEvent(self.ack_event.?);
                                continue;
                            };
                        }
                        self.playing.store(true, .release);
                        self.ack_hresult.store(win.S_OK, .release);
                        _ = win.SetEvent(self.ack_event.?);
                    },
                    .stop => {
                        if (playback.running) {
                            // 先把"确实离开缓冲"的帧对齐到 cursor：Stop 之后 padding
                            // 归零，再算就会把还没来得及播的帧也算成已播。
                            self.settlePosition(render, &playback);
                            render.stop();
                        }
                        playback.running = false;
                        self.playing.store(false, .release);
                        // 位置保留：stop 之后 UI 还能显示"停在哪"，play 也从这里续。
                        self.ack_hresult.store(win.S_OK, .release);
                        _ = win.SetEvent(self.ack_event.?);
                    },
                    .seek => {
                        const target_ms = @min(self.seek_target_ms.load(.acquire), self.durationMs());
                        const frame = frameForMs(target_ms, self.sample_rate, self.total_frames);
                        const was_running = playback.running;
                        // Stop + Reset 丢弃整条端点缓冲（包括 GetBuffer 碰不到的
                        // padding）；然后从新帧号重新开始。
                        if (was_running) render.stop();
                        playback.cursor = frame;
                        playback.base = frame;
                        playback.queued = 0;
                        playback.completed = false;
                        playback.running = false;
                        self.position.store(frame * 1000 / self.sample_rate, .release);
                        if (was_running) {
                            render.start() catch {
                                self.playing.store(false, .release);
                                self.ack_hresult.store(wasapi.lastHresult(), .release);
                                _ = win.SetEvent(self.ack_event.?);
                                continue;
                            };
                            playback.running = true;
                            self.playing.store(true, .release);
                        }
                        self.ack_hresult.store(win.S_OK, .release);
                        _ = win.SetEvent(self.ack_event.?);
                    },
                    .quit => {
                        if (playback.running) render.stop();
                        self.playing.store(false, .release);
                        self.ack_hresult.store(win.S_OK, .release);
                        _ = win.SetEvent(self.ack_event.?);
                        return;
                    },
                    .idle => {},
                }
            } else {
                // WAIT_FAILED / 其它：没有可恢复的动作，结束线程让 deinit 能 join。
                self.playing.store(false, .release);
                return;
            }
        }
    }

    /// 暂停前把位置对齐到"确实离开设备缓冲"的那一帧。读不到 padding 就保留
    /// 上一次 service 写下的位置（宁可下一次多播一点，也不把位置跳回去）。
    fn settlePosition(self: *Player, render: wasapi.Render, playback: *Playback) void {
        const padding = render.padding() catch return;
        const played = playedFrames(playback.base, playback.queued, padding, self.total_frames);
        playback.cursor = played;
        playback.base = played;
        playback.queued = 0;
        self.position.store(played * 1000 / self.sample_rate, .release);
    }

    /// 一次音频事件：把缓冲填满（真实 PCM 或结尾静音），更新位置，播完就停。
    fn service(self: *Player, render: wasapi.Render, playback: *Playback) void {
        const padding = render.padding() catch {
            playback.running = false;
            self.playing.store(false, .release);
            return;
        };
        if (padding > render.buffer_frames) return;
        const available = render.buffer_frames - padding;
        if (available == 0) return;

        const data = render.getBuffer(available) catch {
            playback.running = false;
            self.playing.store(false, .release);
            return;
        };

        const before = playback.queued;
        const remaining = if (playback.cursor < self.total_frames) self.total_frames - playback.cursor else 0;
        const real: u32 = @intCast(@min(@as(u64, available), remaining));
        const real_bytes: usize = @as(usize, real) * self.block_align;
        if (real_bytes > 0) {
            const source: usize = @intCast(playback.cursor * self.block_align);
            @memcpy(data[0..real_bytes], self.pcm[source..][0..real_bytes]);
        }
        const queued_bytes: usize = @as(usize, available) * self.block_align;
        if (real_bytes < queued_bytes) @memset(data[real_bytes..queued_bytes], 0);
        render.releaseBuffer(available);

        playback.cursor += real;
        playback.queued += available;

        // 这一刻还留在缓冲里的帧是 padding；已离开缓冲的帧（= 已播）是
        // base + queued_before - padding。按源采样率换算成毫秒，超过总长钉在总长。
        const played = playedFrames(playback.base, before, padding, self.total_frames);
        self.position.store(played * 1000 / self.sample_rate, .release);

        if (playback.cursor >= self.total_frames and played >= self.total_frames) {
            render.stop();
            playback.running = false;
            playback.completed = true;
            playback.cursor = self.total_frames;
            playback.base = self.total_frames;
            playback.queued = 0;
            self.playing.store(false, .release);
        }
    }
};

// ---------------------------------------------------------------------------
// 测试：只测纯换算/计数，不碰设备、不开线程
// ---------------------------------------------------------------------------

const testing = std.testing;

test "frameForMs：按源采样率换帧，钳到总帧，0 采样率不除零" {
    try testing.expectEqual(@as(u64, 0), frameForMs(0, 44100, 44100));
    try testing.expectEqual(@as(u64, 26460), frameForMs(600, 44100, 44100));
    try testing.expectEqual(@as(u64, 13230), frameForMs(600, 22050, 17640));
    // 超过时长：钉在总帧，不越界。
    try testing.expectEqual(@as(u64, 17640), frameForMs(5000, 22050, 17640));
    try testing.expectEqual(@as(u64, 0), frameForMs(100, 0, 100));
}

test "playedFrames：base + 离开缓冲的帧；padding 比已排队还大时不回绕" {
    // 从 600 ms（13230 帧）开始，本轮排了 1000 帧，其中 400 帧还在缓冲里。
    try testing.expectEqual(@as(u64, 13830), playedFrames(13230, 1000, 400, 17640));
    // 设备刚 Reset / stop 之后 padding 可能为 0：全部算已播。
    try testing.expectEqual(@as(u64, 14230), playedFrames(13230, 1000, 0, 17640));
    // Reset 前后计数未对齐：padding > queued 时按 0 算，不能下溢。
    try testing.expectEqual(@as(u64, 13230), playedFrames(13230, 100, 500, 17640));
    // 永远不超过总帧。
    try testing.expectEqual(@as(u64, 17640), playedFrames(17640, 100, 0, 17640));
}
