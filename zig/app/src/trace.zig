//! 启动分段计时：`OTTO_TRACE=1` 时把每一段的毫秒数打到 stderr，默认是**零开销**
//! 的（每次调用只读一次全局 bool，不读时钟、不分配、不打印）。
//!
//! 打开时同时打开 nanoui 的 `ui.trace`：字体扫描、字形栅格化、Tester 各段由
//! nanoui 打自己的 `nanoui-trace` 行。两边都用 QueryPerformanceCounter，`t=`
//! 都从同一次 `begin` 起算，所以两边的数字可以直接相加对齐。
//!
//! 用法（只在启动路径上，不给每帧/每条加）：
//!
//!     trace.begin(init);          // main 第一行
//!     ...
//!     trace.mark("setup.library"); // 每段结束处
//!     trace.markf("frame", "build_ms={d:.2}", .{stats.build_ms});
//!
//! 行格式：`otto-trace <name> d=<距上一段 ms> t=<距 begin ms> [细节]`。

const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");

pub var enabled: bool = false;

var started: f64 = 0;
var previous: f64 = 0;

extern "kernel32" fn QueryPerformanceCounter(count: *i64) callconv(.winapi) i32;
extern "kernel32" fn QueryPerformanceFrequency(freq: *i64) callconv(.winapi) i32;

/// 单调时钟（秒）。和 nanoui 的 `ui.clock` 同源（QPC），不读系统墙上时间。
pub fn now() f64 {
    switch (builtin.os.tag) {
        .windows => {
            var counter: i64 = 0;
            var frequency: i64 = 1;
            _ = QueryPerformanceCounter(&counter);
            _ = QueryPerformanceFrequency(&frequency);
            return @as(f64, @floatFromInt(counter)) / @as(f64, @floatFromInt(frequency));
        },
        else => {
            var ts: std.c.timespec = undefined;
            _ = std.c.clock_gettime(.MONOTONIC, &ts);
            return @as(f64, @floatFromInt(ts.sec)) + @as(f64, @floatFromInt(ts.nsec)) / 1e9;
        },
    }
}

/// 读 `OTTO_TRACE`。只有它存在时才打开 nanoui 那边同名的 trace。
pub fn begin(init: std.process.Init) void {
    enabled = init.environ_map.get("OTTO_TRACE") != null;
    if (!enabled) return;
    nanoui.ui.trace.enabled = true;
    nanoui.ui.trace.restart();
    started = now();
    previous = started;
    std.debug.print("otto-trace process.begin age_ms={d:.2}\n", .{processAgeMs()});
}

// 进程创建到现在多少毫秒：CreateProcess → main 第一行的真实长度（不是猜的）。
const FILETIME = extern struct { low: u32, high: u32 };
extern "kernel32" fn GetCurrentProcess() *anyopaque;
extern "kernel32" fn GetProcessTimes(
    process: *anyopaque,
    creation: *FILETIME,
    exit_time: *FILETIME,
    kernel: *FILETIME,
    user: *FILETIME,
) callconv(.winapi) i32;
extern "kernel32" fn GetSystemTimePreciseAsFileTime(out: *FILETIME) callconv(.winapi) void;

fn fileTimeValue(t: FILETIME) u64 {
    return (@as(u64, t.high) << 32) | t.low;
}

pub fn processAgeMs() f64 {
    var creation = std.mem.zeroes(FILETIME);
    var exit_time = std.mem.zeroes(FILETIME);
    var kernel = std.mem.zeroes(FILETIME);
    var user = std.mem.zeroes(FILETIME);
    if (GetProcessTimes(GetCurrentProcess(), &creation, &exit_time, &kernel, &user) == 0) return 0;
    var current = std.mem.zeroes(FILETIME);
    GetSystemTimePreciseAsFileTime(&current);
    const ticks = fileTimeValue(current) -% fileTimeValue(creation);
    return @as(f64, @floatFromInt(ticks)) / 10_000.0;
}

pub fn mark(comptime name: []const u8) void {
    if (!enabled) return;
    const at = now();
    std.debug.print("otto-trace {s} d={d:.2} t={d:.2}\n", .{ name, (at - previous) * 1000, (at - started) * 1000 });
    previous = at;
}

pub fn markf(comptime name: []const u8, comptime detail: []const u8, args: anytype) void {
    if (!enabled) return;
    const at = now();
    std.debug.print("otto-trace {s} d={d:.2} t={d:.2} ", .{ name, (at - previous) * 1000, (at - started) * 1000 });
    std.debug.print(detail ++ "\n", args);
    previous = at;
}

/// `begin` 到现在的毫秒数：给"某一段自己再细拆"用。
pub fn since() f64 {
    return (now() - started) * 1000;
}

// ---------------------------------------------------------------------------
// 测试：纯算术 + 一个默认关闭的开关，不碰进程环境
// ---------------------------------------------------------------------------

const testing = std.testing;

test "默认关闭：mark 只读一次 bool，不打印也不读时钟" {
    try testing.expect(!enabled);
    const before = now();
    mark("nothing");
    markf("nothing", "x={d}", .{1});
    try testing.expect(now() >= before);
}

test "打开后 mark 推进 previous，d 是两段之差" {
    enabled = true;
    defer enabled = false;
    started = now();
    previous = started;
    mark("first");
    const first = previous;
    try testing.expect(first >= started);
    mark("second");
    try testing.expect(previous >= first);
}
