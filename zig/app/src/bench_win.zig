//! 基准里唯一需要系统调用的两件事：**本进程常驻内存**与**一次冷进程的首帧墙钟**。
//!
//! 内存不用 PowerShell 的近似值：`K32GetProcessMemoryInfo` 直接读内核记的计数，
//! 结构布局按 Win64 的 `PROCESS_MEMORY_COUNTERS_EX` 手写（没有 @cImport，符合宪章
//! 「金属层」一条）。`K32GetProcessMemoryInfo` 在 Windows 7+ 由 kernel32 导出，
//! 所以不用额外链接 psapi。
//!
//! 首帧为什么开子进程：`std.Io` 的进程启动、DLL 装载、库读取、整套 State 初始化
//! 都发生在 `main` 之前或之内，只有**从 CreateProcess 到子进程打印第一帧耗时**
//! 这一段墙钟才包含它们。父进程量的正是这一段；子进程自己再报一个 `main` 内的
//! 数（不含进程创建），两个数都给，报告里不会把两者混为一谈。
//!
//! 计时终止点是**子进程打出 `bench-first-frame:`（含 `first_frame_ms=`）那一行**，
//! 不是子进程退出：退出路径（收工作线程、DLL 分离、被懒启动的缩略图 helper 继承
//! 管道而拖住 EOF）在本机稳定贡献 50–90 ms，和"冷启动到首帧"无关。见
//! `measureFirstFrame` 的注释与 `PERF.md` §4.2。

const std = @import("std");
const stats = @import("bench_stats.zig");

pub const HANDLE = *anyopaque;
pub const DWORD = u32;
pub const BOOL = i32;

/// `PROCESS_MEMORY_COUNTERS_EX`（Win64）。前十个字段与基础版同布局，最后多
/// `PrivateUsage`——`cb` 传本结构大小，系统就按 EX 填。
pub const ProcessMemoryCountersEx = extern struct {
    cb: DWORD,
    page_fault_count: DWORD,
    peak_working_set_size: usize,
    working_set_size: usize,
    quota_peak_paged_pool_usage: usize,
    quota_paged_pool_usage: usize,
    quota_peak_non_paged_pool_usage: usize,
    quota_non_paged_pool_usage: usize,
    pagefile_usage: usize,
    peak_pagefile_usage: usize,
    private_usage: usize,
};

pub const Resident = struct {
    /// `WorkingSetSize`：常驻内存的判据（宪章「常驻内存」）。
    working_set: usize,
    /// `PrivateUsage`：不含共享页的私有提交，用来解释「为什么 WS 比想象的大」。
    private_bytes: usize,
    /// 提交的峰值与换页文件占用：解释「WS 小但提交大」的情况（保留的分配器页、
    /// 线程栈的提交部分）。`--bench` 只读前两个字段，这里只做加法。
    peak_working_set: usize = 0,
    pagefile_usage: usize = 0,
    peak_pagefile: usize = 0,
};

extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;
extern "kernel32" fn K32GetProcessMemoryInfo(
    process: HANDLE,
    counters: *ProcessMemoryCountersEx,
    cb: DWORD,
) callconv(.winapi) BOOL;

/// 读一次本进程的常驻内存；系统调用失败返回 null（基准会把它标成 FAIL 而不是 0）。
pub fn resident() ?Resident {
    var counters = std.mem.zeroes(ProcessMemoryCountersEx);
    counters.cb = @sizeOf(ProcessMemoryCountersEx);
    if (K32GetProcessMemoryInfo(GetCurrentProcess(), &counters, counters.cb) == 0) return null;
    return .{
        .working_set = counters.working_set_size,
        .private_bytes = counters.private_usage,
        .peak_working_set = counters.peak_working_set_size,
        .pagefile_usage = counters.pagefile_usage,
        .peak_pagefile = counters.peak_pagefile_usage,
    };
}

/// 三次取最大：GC/工作集抖动只会让后来的样本变大，取最大代表「这一刻真的驻留过」。
pub fn residentMax(times: usize) ?Resident {
    var best: ?Resident = null;
    for (0..@max(1, times)) |_| {
        const sample = resident() orelse return null;
        if (best == null or sample.working_set > best.?.working_set) best = sample;
    }
    return best;
}

pub const FirstFrame = struct {
    /// 父进程看到的墙钟：CreateProcess → 子进程打出首帧那一行（不含退出）。
    wall_ms: f64,
    /// 子进程在 `main` 里自量的：入口 → 第一帧构建完成。解析不到就是 null。
    internal_ms: ?f64,
    /// 入口 → 窗口建好（库、监听、取图层、预览条、nanoui App）。
    setup_ms: ?f64,
    /// 第一帧本身（nanoui Tester 初始化 + 一次 frame）。
    frame_ms: ?f64,
    /// 子进程第一帧之后的 WorkingSetSize（MiB）。这是**完整 UI 状态**的驻留，
    /// 与 `--bench` 主进程的内存口径不同（那边没有 nanoui 字体/图集）。
    ws_mib: ?f64,
};

pub const FirstFrameError = error{ FirstFrameChildFailed, MissingExecutable };

/// The child prints this once the first frame is built; the clock stops there.
const first_frame_marker = "first_frame_ms=";

/// `argv[0]` 必须是本 exe 的绝对路径（`--bench` 自己的路径）。
///
/// **计时终点是子进程打出 `first_frame_ms=` 那一行，不是子进程退出。**
/// 旧写法用 `std.process.run` 等管道 EOF，于是把"首帧之后"的东西也算进了首帧：
///   * `Tester.deinit` 之类收尾（本机实测 3 ms）；
///   * 进程退出本身（本机实测约 50 ms：ExitProcess 收 3 个工作线程 + 等 DLL 分离）；
///   * 首帧期间被懒启动的缩略图 helper 进程——它继承了 stderr，父进程要等它退出
///     才看到 EOF。
/// 后两项与"冷启动到首帧"无关，却稳定贡献 50–90 ms。这里改成流式读 stderr，
/// 看到那一行就停表并收掉子进程；退出码不再参与判定（子进程是被主动结束的）。
pub fn measureFirstFrame(
    io: std.Io,
    allocator: std.mem.Allocator,
    exe: []const u8,
    library: []const u8,
) FirstFrameError!FirstFrame {
    _ = allocator;
    const argv = [_][]const u8{ exe, library, "--bench-first-frame" };
    const started = stats.now(io);
    var child = std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .pipe,
        .create_no_window = true,
    }) catch |err| {
        std.debug.print("bench: 首帧子进程起不来（{s}）exe={s}\n", .{ @errorName(err), exe });
        return error.FirstFrameChildFailed;
    };
    const pipe = child.stderr orelse return error.FirstFrameChildFailed;
    var log: [64 * 1024]u8 = undefined;
    var len: usize = 0;
    var wall_ms: ?f64 = null;
    while (true) {
        var chunk: [4096]u8 = undefined;
        const n = pipe.readStreaming(io, &.{chunk[0..]}) catch break; // EndOfStream
        const take = @min(n, log.len - len);
        @memcpy(log[len..][0..take], chunk[0..take]);
        len += take;
        if (completeLine(log[0..len], first_frame_marker)) {
            wall_ms = stats.sinceMs(io, started);
            break;
        }
    }
    // The probe's work is done: stop reading here instead of waiting for
    // EOF, which would count the process's teardown. Waiting for the child
    // itself is cheap and closes its handles (and with them the thumbnail
    // helper's job), so nothing is left behind.
    if (child.stderr) |file| file.close(io);
    child.stderr = null;
    _ = child.wait(io) catch {};

    const wall = wall_ms orelse {
        std.debug.print(
            "bench: 首帧子进程没打出 {s}\n--- child stderr ---\n{s}\n",
            .{ first_frame_marker, log[0..len] },
        );
        return error.FirstFrameChildFailed;
    };
    return .{
        .wall_ms = wall,
        .internal_ms = parseNumber(log[0..len], first_frame_marker),
        .setup_ms = parseNumber(log[0..len], "setup_ms="),
        .frame_ms = parseNumber(log[0..len], " frame_ms="),
        .ws_mib = parseNumber(log[0..len], "ws_mib="),
    };
}

/// Whether `text` holds `marker` and then a whole line after it: the value
/// is parsed from that line, so half a number must not stop the clock.
fn completeLine(text: []const u8, marker: []const u8) bool {
    const at = std.mem.indexOf(u8, text, marker) orelse return false;
    return std.mem.indexOfScalarPos(u8, text, at, '\n') != null;
}

/// 子进程把 `bench-first-frame: first_frame_ms=12.34 ...` 打在 stderr 上。
fn parseFirstFrameMs(text: []const u8) ?f64 {
    return parseNumber(text, "first_frame_ms=");
}

/// 在日志里找 `marker=12.34` 这样的数；找不到或格式不对返回 null。
fn parseNumber(text: []const u8, marker: []const u8) ?f64 {
    const at = std.mem.indexOf(u8, text, marker) orelse return null;
    const rest = text[at + marker.len ..];
    var end: usize = 0;
    while (end < rest.len and (std.ascii.isDigit(rest[end]) or rest[end] == '.' or rest[end] == '-')) end += 1;
    if (end == 0) return null;
    return std.fmt.parseFloat(f64, rest[0..end]) catch null;
}

/// 可执行文件路径：`--bench` 用它把自己再起一次。
pub fn executablePath(io: std.Io, allocator: std.mem.Allocator) ![]u8 {
    return std.process.executablePathAlloc(io, allocator);
}

// ---------------------------------------------------------------------------
// 测试：只测解析，不起进程、不读内存（真实数字由 --bench 打出来）
// ---------------------------------------------------------------------------

const testing = std.testing;

test "解析子进程的首帧耗时；日志里没有就返回 null" {
    try testing.expectEqual(
        @as(?f64, 12.5),
        parseFirstFrameMs("x bench-first-frame: first_frame_ms=12.50 size=380x700\n"),
    );
    try testing.expectEqual(@as(?f64, 0.0), parseFirstFrameMs("first_frame_ms=0.00"));
    try testing.expectEqual(@as(?f64, null), parseFirstFrameMs("first_frame_ms=abc"));
    try testing.expectEqual(@as(?f64, null), parseFirstFrameMs("nothing here"));
}

test "frame_ms 的 marker 带前导空格：不能把 first_frame_ms 当成 frame_ms" {
    const line = "bench-first-frame: first_frame_ms=222.76 setup_ms=64.40 frame_ms=158.36";
    try testing.expectEqual(@as(?f64, 222.76), parseFirstFrameMs(line));
    try testing.expectEqual(@as(?f64, 64.40), parseNumber(line, "setup_ms="));
    try testing.expectEqual(@as(?f64, 158.36), parseNumber(line, " frame_ms="));
}

test "PROCESS_MEMORY_COUNTERS_EX 的布局：Win64 下是 80 字节，cb 在前" {
    try testing.expectEqual(@as(usize, 80), @sizeOf(ProcessMemoryCountersEx));
    try testing.expectEqual(@as(usize, 0), @offsetOf(ProcessMemoryCountersEx, "cb"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(ProcessMemoryCountersEx, "peak_working_set_size"));
}
