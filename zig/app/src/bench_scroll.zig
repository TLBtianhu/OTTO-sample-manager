//! `--bench-scroll <library>`：**真实窗口**里的滚动帧率（宪章最后一条没有实测
//! 证据的数字）。
//!
//! 为什么不能再用 `ui.Tester`：它没有窗口、没有 `WM_PAINT`、没有上屏。本文件建一个
//! 380×700 的真 `HWND`（**屏外** `-4000,0`，`WS_EX_NOACTIVATE` + `SW_SHOWNOACTIVATE`），
//! 这样：
//!   * 窗口是"可见"的，所以消息循环真的会收到 `WM_PAINT`（隐藏窗口收不到）；
//!   * 它从来不是前台窗口，用户看不到、点不到，也不进任务栏（见 `run` 里的
//!     `GetForegroundWindow` 采样：只断言"我们不是前台"，前后值仅作诊断）；
//!   * `paint` 走和用户滚动时**同一条**路：`pixels.draw` 光栅化 → GDI 位图复制
//!     或 D3D11 `Present(1,0)`；缩略图、预览条、搜索框都在真实视图里。
//!
//! 注入：每 16.0 ms（62.5 Hz，见 `period_ms`：比 60 Hz 过驱动 4%，吸收软件
//! 节拍器抖动）`PostMessage(WM_MOUSEWHEEL)` 到列表
//! 上方，然后**在这一拍里**把消息泵空并用 `UpdateWindow` 强制把这一帧画掉——所以
//! "一帧"就是"一次滚轮 → 一次构帧 → 一次光栅化 → 一次上屏"，和播放器的 60Hz 时钟
//! 同拍。帧的时间戳来自 nanoui 的通用帧日志（`Surface.recordFrames`：每帧 QPC +
//! build/layout/paint/raster/present/wait），本文件只读它，不在视图里插桩。
//!
//! 报表：帧间隔 p50/p95/max、有效 fps、`>16.7 ms` 丢帧比例、真正超预算的帧数
//! （`work > 16.67 ms`）、分阶段 p50/p95、`WorkingSetSize`，以及**前台窗口
//! 不是我们的**证据（`GetForegroundWindow` 采样；无关程序抢前台不影响结论）。
//!
//! 测量边界写在 `PERF.md` §7：屏外（或主屏 1 像素边缘）窗口、DWM 可能不给离屏窗口
//! 上 vsync、节拍器是软件的（±0.4 ms）、机器负载会改变数字。跑完用 `std.process.exit`
//! 退出，不 join 缩略图/预览工作线程（理由同 `--bench-first-frame`）。

const std = @import("std");
const nanoui = @import("nanoui");
const core = @import("otto_core");
const bench_stats = @import("bench_stats.zig");
const bench_win = @import("bench_win.zig");
const library_io = @import("library_io.zig");
const row_probe = @import("row_probe.zig");
const scroll_stats = @import("bench_scroll_stats.zig");
const thumbs_mod = @import("thumbs.zig");
const trace = @import("trace.zig");

const frame_log = nanoui.ui.frame_log;

pub const Options = struct {
    library: []const u8,
    frames: u32 = 300,
    /// 每拍几个滚轮格：1 格 = 48 点 ≈ 1.09 行（44 点/行）。
    notches: u32 = 1,
    /// 主屏右下角 1 像素（DWM 会合成它），而不是完全屏外。
    edge: bool = false,
    /// 空闲预取开着吗（`--no-prefetch` 的反面）；只用于报表，判据在 `Thumbs`。
    prefetch: bool = true,
};

const mib: f64 = 1024.0 * 1024.0;
const target_fps = scroll_stats.target_fps;
const budget_ms = scroll_stats.budget_ms;

/// 注入节拍：比 60 Hz 快 4%（16.0 ms / 62.5 Hz）。软件节拍器有 ±0.4 ms 的唤醒
/// 抖动；如果按 16.667 ms 注入，帧间隔的均值就压在 16.7 ms 线上，"间隔 >16.7 ms"
/// 会把一半的抖动算成丢帧（第一版就是这样）。过驱动 4% 后，16.7 ms 这条线在注入
/// 节拍之上 0.7 ms：跟得上 62.5 Hz 的输入，60 Hz 就还有 4% 的余量；跟不上的帧会
/// 直接顶到做工时间（>16.7 才会出现）。判定预算仍按 60 Hz 的 16.667 ms。
const period_ms: f64 = 16.0;
const period_s: f64 = period_ms / 1000.0;
/// `wheel_indices` 里"这一拍没有帧"的标记。
const no_frame: usize = std.math.maxInt(usize);

// ---------------------------------------------------------------------------
// Win32：与 `mem_probe.zig` / `bench_win.zig` 一样手写 extern，不 @cImport。
// ---------------------------------------------------------------------------

const HWND = *anyopaque;
const POINT = extern struct { x: i32 = 0, y: i32 = 0 };
const RECT = extern struct { left: i32 = 0, top: i32 = 0, right: i32 = 0, bottom: i32 = 0 };
const MSG = extern struct {
    hwnd: ?HWND = null,
    message: u32 = 0,
    wparam: usize = 0,
    lparam: isize = 0,
    time: u32 = 0,
    x: i32 = 0,
    y: i32 = 0,
    private: u32 = 0,
};

const WM_MOUSEWHEEL: u32 = 0x020A;
const PM_REMOVE: u32 = 1;
const SWP_NOSIZE: u32 = 0x0001;
const SWP_NOZORDER: u32 = 0x0004;
const SWP_NOACTIVATE: u32 = 0x0010;
const DWMWA_CLOAKED: u32 = 14;
const MONITOR_DEFAULTTONULL: u32 = 0;
const GWL_EXSTYLE: i32 = -20;
const WS_EX_NOACTIVATE: u32 = 0x08000000;
const CREATE_WAITABLE_TIMER_HIGH_RESOLUTION: u32 = 0x00000002;
const TIMER_ALL_ACCESS: u32 = 0x1F0003;
const INFINITE: u32 = 0xFFFFFFFF;

extern "user32" fn PostMessageW(hwnd: HWND, msg: u32, wp: usize, lp: isize) callconv(.winapi) i32;
extern "user32" fn PeekMessageW(msg: *MSG, hwnd: ?HWND, min: u32, max: u32, remove: u32) callconv(.winapi) i32;
extern "user32" fn TranslateMessage(msg: *const MSG) callconv(.winapi) i32;
extern "user32" fn DispatchMessageW(msg: *const MSG) callconv(.winapi) isize;
extern "user32" fn UpdateWindow(hwnd: HWND) callconv(.winapi) i32;
extern "user32" fn IsWindowVisible(hwnd: HWND) callconv(.winapi) i32;
extern "user32" fn GetForegroundWindow() callconv(.winapi) ?HWND;
extern "user32" fn GetWindowRect(hwnd: HWND, rect: *RECT) callconv(.winapi) i32;
extern "user32" fn GetWindowLongPtrW(hwnd: HWND, index: i32) callconv(.winapi) isize;
extern "user32" fn ClientToScreen(hwnd: HWND, point: *POINT) callconv(.winapi) i32;
extern "user32" fn SetWindowPos(hwnd: HWND, after: ?HWND, x: i32, y: i32, cx: i32, cy: i32, flags: u32) callconv(.winapi) i32;
extern "user32" fn GetSystemMetrics(index: i32) callconv(.winapi) i32;
extern "user32" fn MonitorFromWindow(hwnd: HWND, flags: u32) callconv(.winapi) ?HWND;
extern "dwmapi" fn DwmFlush() callconv(.winapi) i32;
extern "dwmapi" fn DwmGetWindowAttribute(hwnd: HWND, attribute: u32, value: *anyopaque, size: u32) callconv(.winapi) i32;
extern "kernel32" fn CreateWaitableTimerExW(attrs: ?*anyopaque, name: ?[*:0]const u16, flags: u32, access: u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn SetWaitableTimer(handle: *anyopaque, due: *const i64, period: i32, routine: ?*anyopaque, arg: ?*anyopaque, wake: i32) callconv(.winapi) i32;
extern "kernel32" fn WaitForSingleObject(handle: *anyopaque, ms: u32) callconv(.winapi) u32;
extern "kernel32" fn CloseHandle(handle: *anyopaque) callconv(.winapi) i32;

// ---------------------------------------------------------------------------
// 节拍器：高分辨率可等待计时器（不调用 timeBeginPeriod，不改系统全局定时器精度）。
// ---------------------------------------------------------------------------

const Pacer = struct {
    timer: ?*anyopaque = null,

    fn init() Pacer {
        return .{ .timer = CreateWaitableTimerExW(null, null, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_ALL_ACCESS) };
    }

    fn deinit(self: *Pacer) void {
        if (self.timer) |handle| _ = CloseHandle(handle);
        self.timer = null;
    }

    /// 等到 `deadline`（QPC 秒）。最后 3 ms 自旋：`SetWaitableTimer` 的唤醒
    /// 误差通常是 0.1–0.5 ms（调度器延迟），如果只在最后 1 ms 自旋，剩余误差
    /// 会直接变成帧间隔的抖动；自旋把每拍的相位钉在同一个绝对时间轴上。
    fn waitUntil(self: *Pacer, deadline: f64) void {
        while (true) {
            const remain = deadline - trace.now();
            if (remain <= 0) return;
            if (self.timer != null and remain > 0.003) {
                var due: i64 = -@as(i64, @intFromFloat(remain * 10_000_000.0));
                if (due >= 0) due = -1;
                if (SetWaitableTimer(self.timer.?, &due, 0, null, null, 0) != 0) {
                    _ = WaitForSingleObject(self.timer.?, INFINITE);
                    continue;
                }
            }
            std.atomic.spinLoopHint();
        }
    }
};

// ---------------------------------------------------------------------------
// 入口
// ---------------------------------------------------------------------------

/// `main` 的入口：窗口由基准自己建——380×700、先不 show（`run` 里用
/// `SW_SHOWNOACTIVATE` 显示），带 `WS_EX_NOACTIVATE`。建完跑一遍，直接以
/// 基准的退出码退出：它不 join 工作线程，也不跑 `otto-lite` 的 150 ms tick。
pub fn runCli(
    init: std.process.Init,
    app: *nanoui.App,
    thumbs: *thumbs_mod.Thumbs,
    options: anytype,
    view: nanoui.ui.View,
    title: []const u8,
    probe: *row_probe.RowProbe,
) !noreturn {
    const library = options.bench_scroll orelse return error.NoLibrary;
    const window = try app.newWindow(.{
        .title = title,
        .width = 380,
        .height = 700,
        .content = .{ .view = view },
        .visible = false,
        .non_activating = true,
        .x = -4000,
        .y = 0,
    });
    const code = try run(init, app, window, thumbs, probe, .{
        .library = library,
        .frames = options.frames,
        .notches = options.scroll_notches,
        .edge = options.bench_scroll_edge,
        .prefetch = !options.no_prefetch,
    });
    std.process.exit(code);
}

pub fn run(
    init: std.process.Init,
    app: *nanoui.App,
    window: *nanoui.Window,
    thumbs: *thumbs_mod.Thumbs,
    probe: *row_probe.RowProbe,
    options: Options,
) !u8 {
    if (app.flags.hidden) {
        std.debug.print("scroll-bench: 需要真实可见窗口（不要加 --nanoui-hidden）\n", .{});
        return 1;
    }
    const surface = window.surface orelse {
        std.debug.print("scroll-bench: 没有 Surface（窗口没建起来）\n", .{});
        return 1;
    };
    const hwnd = window.hwnd orelse {
        std.debug.print("scroll-bench: 没有 HWND（gui=false？）\n", .{});
        return 1;
    };
    const h: HWND = @ptrCast(hwnd);
    const io = init.io;
    const allocator = init.arena.allocator();

    // 位置：默认完全屏外；`edge` 贴主屏右下角，只露 1 个像素（DWM 会把它当在屏
    // 窗口合成，D3D 的 Present(1,0) 才会去等垂直同步）。
    if (options.edge) {
        const sw = GetSystemMetrics(0);
        const sh = GetSystemMetrics(1);
        _ = SetWindowPos(h, null, sw - 1, sh - 1, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
    }

    // 显示窗口前后各看一眼前台窗口：这是"绝不抢焦点"的实测证据。
    const fg_before = GetForegroundWindow();
    window.showNoActivate();
    const fg_after_show = GetForegroundWindow();
    drain(io, h, 20);
    _ = UpdateWindow(h);

    var ps: RECT = .{};
    _ = GetWindowRect(h, &ps);
    var cloaked: u32 = 0;
    _ = DwmGetWindowAttribute(h, DWMWA_CLOAKED, &cloaked, @sizeOf(u32));
    const monitor: ?HWND = MonitorFromWindow(h, MONITOR_DEFAULTTONULL);
    const visible = IsWindowVisible(h) != 0;
    const ex_style: u32 = @truncate(@as(usize, @bitCast(GetWindowLongPtrW(h, GWL_EXSTYLE))));

    // DWM 的合成节拍：20 次 `DwmFlush` 的间隔。它就是显示器的刷新周期（本机
    // 240 Hz → 4.17 ms），用来解释"为什么上屏可能被降频/封顶"。
    const refresh = measureRefresh(allocator);

    std.debug.print(
        "scroll-bench: ==== real-window scroll: {s} ====\n" ++
            "scroll-bench: library={s} frames={d} notches={d} size={d:.0}x{d:.0} scale={d:.2} pixels={d}x{d}\n" ++
            "scroll-bench: window hwnd=0x{x} visible={} ex_style=0x{x} non_activating_bit={} rect=({d},{d})-({d},{d}) monitor_attached={} cloaked={d}\n" ++
            "scroll-bench: self_check gdi={}\n",
        .{
            if (surface.no_d3d) "GDI" else "D3D11",
            options.library,
            options.frames,
            options.notches,
            surface.size.w,
            surface.size.h,
            surface.scale,
            surface.pixels.width,
            surface.pixels.height,
            @intFromPtr(h),
            visible,
            ex_style,
            (ex_style & WS_EX_NOACTIVATE) != 0,
            ps.left,
            ps.top,
            ps.right,
            ps.bottom,
            monitor != null,
            cloaked,
            surface.no_d3d,
        },
    );
    reportRefresh(refresh);

    // 预热：先把前 ~100 行滚过去，让 100 个缩略图都进 L2/图像图集；再等取图线程
    // 停下（最多 5 秒），这样计时窗口里不会混进"新图首次进图集"的一次性成本。
    const warmup: u32 = @max(8, @min(120, options.frames / 3));
    var pacer = Pacer.init();
    defer pacer.deinit();
    var next = trace.now() + period_s;
    var warm_i: u32 = 0;
    while (warm_i < warmup) : (warm_i += 1) {
        pacer.waitUntil(next);
        next += period_s;
        postWheel(h, surface, options.notches);
        pump();
        _ = UpdateWindow(h);
    }
    const settled = waitThumbs(io, thumbs, h, 5.0);
    // 新到的图要再画一帧才会进图集；用两次普通帧收尾。
    for (0..2) |_| {
        pacer.waitUntil(next);
        next += period_s;
        postWheel(h, surface, options.notches);
        pump();
        _ = UpdateWindow(h);
    }

    // 预取验收：量"滚动经过的行里，图标已就绪的比例"。行 → 样本的下标由视图写进
    // `probe`（每帧一份），这里按样本去重、只看**第一次**出现在视口的那一帧。
    var loaded: ?core.store.Library = library_io.loadWith(io, allocator, options.library) catch null;
    defer if (loaded) |*value| value.deinit();
    var visits: Visits = .{ .seen = &.{} };
    if (loaded) |*value| {
        visits.seen = try allocator.alloc(bool, value.samples.len);
        @memset(visits.seen, false);
    }

    // 从这里开始记每一帧。日志在内存里（不带 path = 不写文件）。
    const log = try surface.recordFrames(init.gpa);
    const inject_times = try allocator.alloc(f64, options.frames);
    // 每拍**滚轮引起的那一帧**在日志里的下标。nanoui 自己还有 16 ms 的动画
    // 定时器：滚动时悬停行在换，hover 动画会额外插帧。那些帧是真实开销，但不该
    // 混进"滚轮帧间隔"——所以这里按消息分界，把滚轮帧单独标出来。
    const wheel_indices = try allocator.alloc(usize, options.frames);
    @memset(wheel_indices, no_frame);

    const started = trace.now();
    next = started + period_s;
    var posted: usize = 0;
    // 这一拍结束时队列是空的帧数：预取只有在这样的帧尾才可能入队（见 Scheduler）。
    var idle_frames: usize = 0;
    while (posted < options.frames) : (posted += 1) {
        pacer.waitUntil(next);
        next += period_s;
        inject_times[posted] = trace.now();
        if (PostMessageW(h, WM_MOUSEWHEEL, wheelWParam(options.notches), wheelLParam(h, surface)) == 0) break;
        // 泵到"我们那条滚轮消息"被 Dispatch 为止：之前排队的定时器消息照常
        // 处理（它们的帧算额外帧），之后立刻停手，别把后面的消息也算进这一拍。
        if (pumpToWheel(log)) |index| wheel_indices[posted] = index;
        // WM_PAINT 有时会排到下一轮消息之后；强制现在画掉，让"这一拍"闭合。
        _ = UpdateWindow(h);
        // 这一帧画了哪些行、有没有图：只看第一次出现的行（见 `Visits`）。
        visits.record(probe);
        if (thumbs.stats().pending == 0) idle_frames += 1;
    }
    drain(io, h, 20);
    _ = UpdateWindow(h);
    const ended = trace.now();

    const fg_after_run = GetForegroundWindow();
    const records = log.spanFrom(0);
    const stats = try scroll_stats.summarize(allocator, records, wheel_indices[0..posted], inject_times[0..posted], started, ended);

    // 前台窗口对比：只要求"我们的窗口任何时候都不是前台"。通知弹窗、后台
    // 更新、用户切窗口都会合法地改变前台，所以 before/show/after 三个值只
    // 打印出来做诊断，不要求相等；stolen 只表示其中之一是我们。
    const fg_value = hwndValue(fg_after_run);
    const stolen = isOurWindow(fg_before, h) or isOurWindow(fg_after_show, h) or isOurWindow(fg_after_run, h);
    std.debug.print(
        "scroll-bench: focus foreground_before=0x{x} after_show=0x{x} after_run=0x{x} hwnd=0x{x} stolen={}\n",
        .{ hwndValue(fg_before), hwndValue(fg_after_show), fg_value, @intFromPtr(h), stolen },
    );

    const memory = bench_win.resident();
    const thumb_stats = thumbs.stats();
    std.debug.print(
        "scroll-bench: loop posted={d} wheel_frames={d} all_frames={d} extra_frames={d} missing_frames={d} wall={d:.2}s span={d:.2}s warmup={d} thumbs_settled={}\n",
        .{ stats.posted, stats.frames, stats.all_frames, stats.extra_frames, stats.missing_frames, stats.wall_s, stats.span_s, warmup, settled },
    );
    scroll_stats.print(stats);
    std.debug.print(
        "scroll-bench: phases_p50 build={d:.2} layout={d:.2} paint={d:.2} raster={d:.2} present={d:.2} wait={d:.2} after={d:.2} ms\n",
        .{ stats.build.p50, stats.layout.p50, stats.paint.p50, stats.raster.p50, stats.present.p50, stats.wait.p50, stats.after.p50 },
    );
    std.debug.print(
        "scroll-bench: phases_p95 build={d:.2} layout={d:.2} paint={d:.2} raster={d:.2} present={d:.2} wait={d:.2} after={d:.2} ms\n",
        .{ stats.build.p95, stats.layout.p95, stats.paint.p95, stats.raster.p95, stats.present.p95, stats.wait.p95, stats.after.p95 },
    );
    if (memory) |resident| {
        std.debug.print(
            "scroll-bench: ws_mib={d:.2} private_mib={d:.2} peak_ws_mib={d:.2}\n",
            .{
                @as(f64, @floatFromInt(resident.working_set)) / mib,
                @as(f64, @floatFromInt(resident.private_bytes)) / mib,
                @as(f64, @floatFromInt(resident.peak_working_set)) / mib,
            },
        );
    } else {
        std.debug.print("scroll-bench: ws_mib=n/a（K32GetProcessMemoryInfo 不可用）\n", .{});
    }
    std.debug.print(
        "scroll-bench: thumbs ready={d} pending={d} entries={d} bytes_mib={d:.2} prefetched={d} dropped={d}\n",
        .{
            thumbs.readyCount(),
            thumb_stats.pending,
            thumb_stats.entries,
            @as(f64, @floatFromInt(thumb_stats.bytes)) / mib,
            thumb_stats.prefetched,
            thumb_stats.dropped,
        },
    );
    reportPrefetch(thumbs, if (loaded) |*value| value else null, &visits, options, thumb_stats, idle_frames, posted);

    // 判据：帧产量 ≥ 60/s、单帧做工 p95 在 16.67 ms 内、没有一帧超预算、
    // 我们的窗口从来不是前台。无关程序抢前台不影响 verdict。
    const fps_ok = stats.fps >= target_fps;
    const work_ok = stats.work.p95 <= budget_ms;
    const pass = fps_ok and work_ok and stats.over_budget == 0 and !stolen;
    std.debug.print(
        "scroll-bench: summary mode={s} fps={d:.2} p50={d:.2} p95={d:.2} max={d:.2} drops={d}/{d} over_budget={d} work_p50={d:.2} work_p95={d:.2} ws_mib={d:.2} verdict={s}\n",
        .{
            if (surface.no_d3d) "gdi" else "d3d",
            stats.fps,
            stats.intervals.p50,
            stats.intervals.p95,
            stats.intervals.max,
            stats.drops,
            stats.intervals.n,
            stats.over_budget,
            stats.work.p50,
            stats.work.p95,
            if (memory) |resident| @as(f64, @floatFromInt(resident.working_set)) / mib else 0,
            if (pass) "PASS" else "FAIL",
        },
    );
    return if (pass) 0 else 1;
}

// ---------------------------------------------------------------------------
// 预取验收：滚动经过的行里，图标已就绪的比例
// ---------------------------------------------------------------------------

/// 行就绪的账：一行只在第一次出现在视口的那一帧记一次（按样本下标去重），
/// 否则"盯了很久的那一屏"会把比例稀释成 100%。字段含义见各自注释。
const Visits = struct {
    /// 每个样本是否出现过（长度 = 库的样本数；库读不出来时是空切片）。
    seen: []bool,
    /// 第一次出现在视口里的行数（去重后的 `visited`）。
    visited: usize = 0,
    /// 其中**那一帧就已经画出图标**的行数。
    ready_arriving: usize = 0,
    frames: usize = 0,

    fn record(self: *Visits, probe: *const row_probe.RowProbe) void {
        if (probe.len == 0) return;
        self.frames += 1;
        for (probe.samples[0..probe.len], probe.ready[0..probe.len]) |sample, ready| {
            if (sample >= self.seen.len) continue;
            if (self.seen[sample]) continue;
            self.seen[sample] = true;
            self.visited += 1;
            if (ready) self.ready_arriving += 1;
        }
    }
};

/// 预取的账：`ready_arriving` = 滚动经过的行里**进入视口那一帧就已经有图标**的比例
/// （没有预取时新行是滚到眼前才入队的，所以接近 0）；`ready_end` 只证明"没有漏画"。
fn reportPrefetch(
    thumbs: *thumbs_mod.Thumbs,
    library: ?*core.store.Library,
    visits: *const Visits,
    options: Options,
    thumb_stats: thumbs_mod.Stats,
    idle_frames: usize,
    total_frames: usize,
) void {
    const percent = if (visits.visited == 0) 0.0 else 100.0 * @as(f64, @floatFromInt(visits.ready_arriving)) / @as(f64, @floatFromInt(visits.visited));
    const idle_pct = if (total_frames == 0) 0.0 else 100.0 * @as(f64, @floatFromInt(idle_frames)) / @as(f64, @floatFromInt(total_frames));
    if (library == null) {
        std.debug.print(
            "scroll-bench: prefetch enabled={} visited={d} ready_arriving={d} ({d:.1}%) ready_end=n/a prefetched={d} idle_frames={d}/{d}（库读不出来，末态不统计）\n",
            .{ options.prefetch, visits.visited, visits.ready_arriving, percent, thumb_stats.prefetched, idle_frames, total_frames },
        );
        return;
    }
    var ready_end: usize = 0;
    const samples = library.?.samples;
    for (visits.seen, 0..) |seen, index| {
        if (!seen or index >= samples.len) continue;
        if (thumbs.has(samples[index])) ready_end += 1;
    }
    std.debug.print(
        "scroll-bench: prefetch enabled={} visited={d} ready_arriving={d} ({d:.1}%) ready_end={d} ({d:.1}%) prefetched={d} dropped={d} frames={d} idle_frames={d}/{d} ({d:.1}%)\n",
        .{
            options.prefetch,
            visits.visited,
            visits.ready_arriving,
            percent,
            ready_end,
            if (visits.visited == 0) 0.0 else 100.0 * @as(f64, @floatFromInt(ready_end)) / @as(f64, @floatFromInt(visits.visited)),
            thumb_stats.prefetched,
            thumb_stats.dropped,
            visits.frames,
            idle_frames,
            total_frames,
            idle_pct,
        },
    );
}

// ---------------------------------------------------------------------------
// 注入与泵
// ---------------------------------------------------------------------------

/// 滚轮消息的屏幕坐标：列表中部（和 `mem_probe.scrollTo` 同一个点，190,420 点）。
/// 滚轮消息带的是**屏幕**坐标，`WM_MOUSEWHEEL` 处理器自己 `ScreenToClient`。
fn wheelLParam(h: HWND, surface: anytype) isize {
    var point: POINT = .{
        .x = @intFromFloat(190.0 * surface.scale),
        .y = @intFromFloat(420.0 * surface.scale),
    };
    _ = ClientToScreen(h, &point);
    const x: u16 = @bitCast(@as(i16, @intCast(point.x)));
    const y: i16 = @intCast(point.y);
    return @as(isize, y) << 16 | @as(isize, @intCast(x));
}

/// `wParam` 的高 16 位是滚轮增量（120 的整数倍，向下滚为负）。
fn wheelWParam(notches: u32) usize {
    const delta: i16 = @intCast(-120 * @as(i32, @intCast(notches)));
    return @as(usize, @as(u16, @bitCast(delta))) << 16;
}

fn postWheel(h: HWND, surface: anytype, notches: u32) void {
    _ = PostMessageW(h, WM_MOUSEWHEEL, wheelWParam(notches), wheelLParam(h, surface));
}

/// 把消息泵空（含 `WM_PAINT` / `WM_TIMER`）。
fn pump() void {
    var msg: MSG = .{};
    while (PeekMessageW(&msg, null, 0, 0, PM_REMOVE) != 0) {
        _ = TranslateMessage(&msg);
        _ = DispatchMessageW(&msg);
    }
}

/// 泵到**我们刚刚 Post 的那条滚轮消息**被 Dispatch 为止，返回它在帧日志里的
/// 下标（没有帧就返回 null）。之前排队的定时器消息照常走；之后的消息留给下一拍。
fn pumpToWheel(log: *frame_log.FrameLog) ?usize {
    var msg: MSG = .{};
    while (PeekMessageW(&msg, null, 0, 0, PM_REMOVE) != 0) {
        const wheel = msg.message == WM_MOUSEWHEEL;
        const before = if (wheel) log.mark() else 0;
        _ = TranslateMessage(&msg);
        _ = DispatchMessageW(&msg);
        if (wheel) return if (log.mark() > before) before else null;
    }
    return null;
}

/// A window handle as a number, for the report: 0 when there is none.
fn hwndValue(handle: ?HWND) usize {
    return if (handle) |value| @intFromPtr(value) else 0;
}

/// "没有抢焦点"：我们的窗口不是前台窗口。无关程序改变前台不算 stolen。
fn isOurWindow(handle: ?HWND, hwnd: HWND) bool {
    return if (handle) |value| value == hwnd else false;
}

/// 抽 `ms` 毫秒消息（收尾用）：让最后几帧的 paint 落完。
fn drain(io: std.Io, h: HWND, ms: u32) void {
    const until = trace.now() + @as(f64, @floatFromInt(ms)) / 1000.0;
    while (trace.now() < until) {
        pump();
        _ = UpdateWindow(h);
        sleepMs(io, 1);
    }
}

fn sleepMs(io: std.Io, ms: u64) void {
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(@intCast(ms)), .awake) catch {};
}

/// 等取图线程停：缩略图是异步的，计时窗口里不想混进"新图第一次进图集"。
/// 返回是否在截止时间前等到（false 也继续跑，报表里如实写）。
fn waitThumbs(io: std.Io, thumbs: *thumbs_mod.Thumbs, h: HWND, seconds: f64) bool {
    const until = trace.now() + seconds;
    while (trace.now() < until) {
        if (thumbs.stats().pending == 0) return true;
        pump();
        _ = UpdateWindow(h);
        sleepMs(io, 10);
    }
    return false;
}

/// DWM 合成节拍的 p50/p95（毫秒）。它也是显示器的刷新周期。
const Refresh = struct { summary: bench_stats.Summary = .{} };

fn measureRefresh(allocator: std.mem.Allocator) Refresh {
    var samples: [20]f64 = undefined;
    var previous = trace.now();
    for (&samples) |*slot| {
        _ = DwmFlush();
        const now = trace.now();
        slot.* = (now - previous) * 1000;
        previous = now;
    }
    return .{ .summary = bench_stats.summarize(allocator, &samples) };
}

fn reportRefresh(refresh: Refresh) void {
    if (refresh.summary.n == 0) {
        std.debug.print("scroll-bench: dwm_tick n/a（DwmFlush 没有返回样本）\n", .{});
        return;
    }
    std.debug.print(
        "scroll-bench: dwm_tick p50={d:.2} p95={d:.2} ms n={d}（≈ {d:.0} Hz 的合成节拍；离屏窗口可能不参与它）\n",
        .{ refresh.summary.p50, refresh.summary.p95, refresh.summary.n, 1000.0 / @max(0.1, refresh.summary.p50) },
    );
}
