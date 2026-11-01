//! 冷启动的**系统下限**探针：一个只会 create window + present 一帧的空程序。
//!
//! 为什么需要它：`--bench` 的「冷启动→首帧」量的是整条启动链。当这个数接近
//! 100 ms 时，必须能回答"这里面有多少是 Windows 自己的"——否则优化会把系统
//! 成本当成自己的锅，或者把"改指标"当成"改代码"。本探针就是那个分母：
//!
//!   * 不建 nanoui App、不读库、不扫字体、不布局、不取图；
//!   * 只做真窗口应用躲不开的四件事：进程启动、注册窗口类、建 HWND、上屏一帧；
//!   * 每一步用 QPC 夹一次，`age_ms` 用 `GetProcessTimes` 从**内核记的进程创建
//!     时间**算到 main 第一行（不是猜的）。
//!
//! 输出一行：
//!
//!     floor: age_ms=13.07 dpi=0.09 register=0.02 window1=82.03 window2=4.60
//!            present=0.22 total_after_main=86.96 total_wall=100.03
//!            msg_hwnd=true win_hwnd=true present_ok=true
//!
//! `window1` 是进程里**第一个** `CreateWindowExW`（message-only，和 nanoui
//! `fdwatch.prepare` 同形）；`window2`（380×700 的普通窗口）只要 0.6–5 ms——
//! 也就是说 60–85 ms 是"进程里第一次碰 win32k/DWM"的一次性成本，与窗口类型无关。
//! `present` 是 GDI `SetDIBitsToDevice` 一帧 380×700 BGRA（应用的默认上屏路径）。
//! `total_wall` 与 `--bench` 的「CreateProcess → 首帧」差一个 spawn/管道开销
//! （本机约 5 ms），比较时要么都看探针、要么都在这个数上加那 5 ms。
//!
//! 这不是产品代码，`zig build` 不编译它（不进 `zig-out`，不参与测试与分发）。
//! 复核方法（任意 ReleaseSafe 构建都一样）：
//!
//!     cd zig
//!     zig build-exe tools/floor-probe.zig -O ReleaseSafe \
//!         -luser32 -lgdi32 -lkernel32 --name floor-probe
//!     # 连跑 9 次，取 p50/p95（脚本见 PERF.md §12.3）
//!
//! 零 C、没有 @cImport：所有 Win32 入口都是手写 `extern`，和 `bench_win.zig`
//! 一样的写法。窗口从不 show、不抢焦点、不进任务栏。

const std = @import("std");

const HWND = *anyopaque;
const HDC = *anyopaque;
const HINSTANCE = *anyopaque;
const LRESULT = isize;
const WPARAM = usize;
const LPARAM = isize;
const UINT = u32;
const DWORD = u32;
const BOOL = i32;
const WNDPROC = *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;

const WNDCLASSEXW = extern struct {
    cb_size: UINT,
    style: UINT,
    wnd_proc: ?WNDPROC,
    cb_cls_extra: i32,
    cb_wnd_extra: i32,
    instance: ?HINSTANCE,
    icon: ?*anyopaque,
    cursor: ?*anyopaque,
    background: ?*anyopaque,
    menu_name: ?[*:0]const u16,
    class_name: [*:0]const u16,
    icon_small: ?*anyopaque,
};

const BITMAPINFOHEADER = extern struct {
    size: u32 = 40,
    width: i32,
    height: i32,
    planes: u16 = 1,
    bit_count: u16 = 32,
    compression: u32 = 0,
    size_image: u32 = 0,
    x_pels: i32 = 0,
    y_pels: i32 = 0,
    clr_used: u32 = 0,
    clr_important: u32 = 0,
};

const FILETIME = extern struct { low: u32, high: u32 };

/// `HWND_MESSAGE`：message-only 窗口的父句柄（-3）。nanoui 的 `fdwatch` 用它。
const hwnd_message: ?HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -3))));

extern "kernel32" fn QueryPerformanceCounter(counter: *i64) callconv(.winapi) i32;
extern "kernel32" fn QueryPerformanceFrequency(freq: *i64) callconv(.winapi) i32;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) *anyopaque;
extern "kernel32" fn GetProcessTimes(
    process: *anyopaque,
    creation: *FILETIME,
    exit_time: *FILETIME,
    kernel: *FILETIME,
    user: *FILETIME,
) callconv(.winapi) i32;
extern "kernel32" fn GetSystemTimePreciseAsFileTime(out: *FILETIME) callconv(.winapi) void;
extern "user32" fn GetModuleHandleW(name: ?[*:0]const u16) callconv(.winapi) ?HINSTANCE;
extern "user32" fn RegisterClassExW(class: *const WNDCLASSEXW) callconv(.winapi) u16;
extern "user32" fn CreateWindowExW(
    ex_style: DWORD,
    class_name: [*:0]const u16,
    window_name: [*:0]const u16,
    style: DWORD,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    parent: ?HWND,
    menu: ?*anyopaque,
    instance: ?HINSTANCE,
    param: ?*anyopaque,
) callconv(.winapi) ?HWND;
extern "user32" fn DefWindowProcW(h: HWND, msg: UINT, wp: WPARAM, lp: LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn SetProcessDpiAwarenessContext(value: isize) callconv(.winapi) BOOL;
extern "user32" fn GetDC(h: ?HWND) callconv(.winapi) ?HDC;
extern "user32" fn ReleaseDC(h: ?HWND, dc: HDC) callconv(.winapi) i32;
extern "gdi32" fn SetDIBitsToDevice(
    dc: HDC,
    x: i32,
    y: i32,
    w: u32,
    h: u32,
    sx: i32,
    sy: i32,
    start: u32,
    lines: u32,
    bits: *const anyopaque,
    info: *const BITMAPINFOHEADER,
    usage: u32,
) callconv(.winapi) i32;

var qpc_frequency: i64 = 1;

fn stamp() f64 {
    var counter: i64 = 0;
    _ = QueryPerformanceCounter(&counter);
    return @as(f64, @floatFromInt(counter)) / @as(f64, @floatFromInt(qpc_frequency));
}

fn fileTimeValue(t: FILETIME) u64 {
    return (@as(u64, t.high) << 32) | t.low;
}

/// CreateProcess → 现在。用内核记的进程创建时间，不含任何"从 main 起算"的假设。
fn processAgeMs() f64 {
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

fn windowProc(h: HWND, msg: UINT, wp: WPARAM, lp: LPARAM) callconv(.winapi) LRESULT {
    return DefWindowProcW(h, msg, wp, lp);
}

pub fn main() !void {
    var frequency: i64 = 1;
    _ = QueryPerformanceFrequency(&frequency);
    qpc_frequency = frequency;

    const age_ms = processAgeMs();
    const began = stamp();
    const previous = began;

    // 1. DPI 感知：GUI 应用的第一件事（nanoui `App.create` 同一条调用）。
    _ = SetProcessDpiAwarenessContext(-4);
    const after_dpi = stamp();

    // 2. 注册窗口类（nanoui `fdwatch.prepare` 同形）。
    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("otto.floor.probe");
    const instance = GetModuleHandleW(null);
    const class: WNDCLASSEXW = .{
        .cb_size = @sizeOf(WNDCLASSEXW),
        .style = 0x0020, // CS_OWNDC
        .wnd_proc = &windowProc,
        .cb_cls_extra = 0,
        .cb_wnd_extra = 0,
        .instance = instance,
        .icon = null,
        .cursor = null,
        .background = null,
        .menu_name = null,
        .class_name = class_name,
        .icon_small = null,
    };
    _ = RegisterClassExW(&class);
    const after_register = stamp();

    // 3. 进程里第一个窗口：message-only（nanoui 的跨线程投递窗口就是这个）。
    const message_window = CreateWindowExW(
        0,
        class_name,
        class_name,
        0,
        0,
        0,
        0,
        0,
        hwnd_message,
        null,
        instance,
        null,
    );
    const after_first_window = stamp();

    // 4. 第二个窗口：380×700 的普通窗口，不 show（应用的窗口尺寸）。
    const window = CreateWindowExW(
        0,
        class_name,
        class_name,
        0x00CF_0000, // WS_OVERLAPPEDWINDOW 的 style 位
        0,
        0,
        380,
        700,
        null,
        null,
        instance,
        null,
    );
    const after_second_window = stamp();

    // 5. 上屏一帧：GDI SetDIBitsToDevice，380×700 BGRA（应用默认的 GDI 路径）。
    const width: usize = 380;
    const height: usize = 700;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const pixels = try arena.allocator().alloc(u8, width * height * 4);
    @memset(pixels, 0x20);
    const info = BITMAPINFOHEADER{ .width = @intCast(width), .height = -@as(i32, @intCast(height)) };
    var presented = false;
    if (window) |h| {
        if (GetDC(h)) |dc| {
            presented = SetDIBitsToDevice(
                dc,
                0,
                0,
                @intCast(width),
                @intCast(height),
                0,
                0,
                0,
                @intCast(height),
                pixels.ptr,
                &info,
                0,
            ) != 0;
            _ = ReleaseDC(h, dc);
        }
    }
    const finished = stamp();

    std.debug.print(
        "floor: age_ms={d:.2} dpi={d:.2} register={d:.2} window1={d:.2} window2={d:.2} " ++
            "present={d:.2} total_after_main={d:.2} total_wall={d:.2} msg_hwnd={} win_hwnd={} present_ok={}\n",
        .{
            age_ms,
            (after_dpi - previous) * 1000,
            (after_register - after_dpi) * 1000,
            (after_first_window - after_register) * 1000,
            (after_second_window - after_first_window) * 1000,
            (finished - after_second_window) * 1000,
            (finished - began) * 1000,
            age_ms + (finished - began) * 1000,
            message_window != null,
            window != null,
            presented,
        },
    );
}
