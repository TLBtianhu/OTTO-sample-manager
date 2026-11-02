//! 窗口口岸（Windows）：把**已存在的** HWND 放进 / 移出 always-on-top 层，
//! 以及改它的整体不透明度（`WS_EX_LAYERED` + `SetLayeredWindowAttributes`）。
//!
//! ## 置顶
//!
//! 为什么不是 nanoui 的 `Window.setAlwaysOnTop`：那个调用没有带
//! `SWP_NOACTIVATE`（`SetWindowPos` 的 0x0010），在真实窗口上置顶时可能把窗口
//! 提到前台。设置面板的置顶开关是个普通控件，用户不希望点一下"置顶"就把窗口
//! 从别的程序后面抢出来。本口岸的调用位固定为：
//!
//! ```
//! SetWindowPos(hwnd,
//!              on ? HWND_TOPMOST : HWND_NOTOPMOST,
//!              0, 0, 0, 0,
//!              SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE)
//! ```
//!
//! 位置、大小、Z 序以外的四个参数都不动；`SWP_NOACTIVATE` 保证不激活、不抢焦点。
//!
//! 判定用 `GetWindowLongPtrW(hwnd, GWL_EXSTYLE) & WS_EX_TOPMOST`：这是 Windows
//! 自己维护的置顶位，也是验收脚本断言的同一个位（不是本口岸记的账）。
//!
//! ## 前台锁：`SetWindowPos` 的返回值会撒谎
//!
//! 后台进程（没有前台窗口的线程）调用 `SetWindowPos(HWND_TOPMOST)` 时，Windows
//! 只在调用线程与前台线程**共享输入队列**时才真正改 z-order；否则它可能返回
//! `TRUE`、`GetLastError` 还是 0，而 `WS_EX_TOPMOST` 位一点没变。启动时窗口还
//! 没被激活，正是这条路径——用户保存了"窗口置顶"，下次启动却静默失效。
//!
//! 所以 `setTopmost` 在每次 `SetWindowPos` 之后都**读回 `WS_EX_TOPMOST`**，以位
//! 为准、不以返回值为准；第一次读回不对时，取前台线程并与它临时
//! `AttachThreadInput`，再试一次，然后立刻解挂（`defer` 兜底，绝不留着挂住）。
//! 两次都改不动就返回 `error.TopmostRejected`，不假装成功。全程不调用
//! `SetForegroundWindow` / `SetActiveWindow` / `SetFocus`：接输入队列不等于抢焦点，
//! 前台窗口和焦点都不变。
//!
//! ## 不透明度
//!
//! ```
//! ex = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
//! alpha < 255:  ex |= WS_EX_LAYERED;   SetLayeredWindowAttributes(hwnd, 0, alpha, LWA_ALPHA);
//! alpha == 255: ex &= ~WS_EX_LAYERED;  （已经不在分层路径上就什么都不做）
//! ```
//!
//! **255 的取舍**：完全不透明时把 `WS_EX_LAYERED` 去掉，而不是留一个 alpha=255
//! 的分层窗口。两者像素上一模一样，但分层窗口每次合成都多一条 alpha 路径，
//! 而绝大多数用户从没碰过这个滑块——默认路径不该被改。代价是 `getOpacity`
//! 对"完全不透明"返回 `null`（没有分层窗口就没有 alpha 可读），不是 255；
//! 调用方按 `null = 255` 理解，测试钉住这个约定。
//!
//! **已知限制**：D3D11 翻转模型（`--d3d`）的交换链由 DWM 直接合成，
//! `SetLayeredWindowAttributes` 对它不起作用（可能完全不透明，也可能整块消失）。
//! 本口岸不认识上屏方式，app 在 `--d3d` 下设透明度时打一行警告，不静默。
//!
//! Win32 声明全部手写 `extern "user32"`：没有 `@cImport`、没有 C shim。
//! `supported` 之外的平台在运行期返回 `error.Unsupported`（本口岸只被 Windows
//! 构建的 app 引用，但测试可以在任何平台跑着 skip）。

const std = @import("std");
const builtin = @import("builtin");

pub const supported = builtin.os.tag == .windows;

pub const Error = error{
    /// 非 Windows 平台。
    Unsupported,
    /// 句柄为空（无窗口 / 窗口已销毁）。
    InvalidWindow,
    /// `SetWindowPos` 失败，具体 Win32 码见 `lastError()`。
    SetWindowPosFailed,
    /// `SetWindowPos` 返回成功，但读回 `WS_EX_TOPMOST` 仍不是期望值：
    /// 后台进程的前台锁拒绝了这条 z-order 修改（见文件头的"前台锁"）。
    TopmostRejected,
    /// `SetWindowLongPtrW` 改扩展样式失败（加/去 `WS_EX_LAYERED`）。
    SetStyleFailed,
    /// `SetLayeredWindowAttributes` 失败。
    SetLayeredWindowAttributesFailed,
    /// `GetLayeredWindowAttributes` 失败（窗口有分层位但系统仍拒绝查询）。
    GetLayeredWindowAttributesFailed,
};

// ---------------------------------------------------------------------------
// 手写 Win32 声明（置顶、扩展样式、分层窗口；不 @cImport）
// ---------------------------------------------------------------------------

const HWND = *anyopaque;
const BOOL = i32;
const DWORD = u32;
const LONG = i32;
const LONG_PTR = isize;

const SWP_NOSIZE: DWORD = 0x0000_0001;
const SWP_NOMOVE: DWORD = 0x0000_0002;
/// 关键的一位：不激活目标窗口，也不改变前台窗口。
const SWP_NOACTIVATE: DWORD = 0x0010;

/// `SetWindowPos` 的特殊 `hWndInsertAfter` 值（不是真实指针）。
const HWND_TOPMOST: isize = -1;
const HWND_NOTOPMOST: isize = -2;

const GWL_EXSTYLE: c_int = -20;
/// `WS_EX_TOPMOST`：窗口在置顶层。验收断言的位。
pub const WS_EX_TOPMOST: usize = 0x0000_0008;
/// `WS_EX_LAYERED`：窗口走分层合成；只有这一位置位时 `SetLayeredWindowAttributes`
/// 才有效。`setOpacity` / `getOpacity` 只认 Windows 自己维护的这一位。
pub const WS_EX_LAYERED: usize = 0x0008_0000;

/// `SetLayeredWindowAttributes` 的标志：按整窗 alpha 混合（本口岸唯一用的）。
const LWA_ALPHA: DWORD = 0x0000_0002;

/// 测试用的隐藏窗口样式：不激活、不进任务栏。
const WS_POPUP: DWORD = 0x8000_0000;
const WS_EX_NOACTIVATE: DWORD = 0x0800_0000;
const WS_EX_TOOLWINDOW: DWORD = 0x0000_0080;

extern "user32" fn SetWindowPos(
    hwnd: HWND,
    insert_after: ?HWND,
    x: i32,
    y: i32,
    cx: i32,
    cy: i32,
    flags: DWORD,
) callconv(.winapi) BOOL;

extern "user32" fn GetWindowLongPtrW(hwnd: HWND, index: c_int) callconv(.winapi) LONG_PTR;

extern "user32" fn GetWindowLongW(hwnd: HWND, index: c_int) callconv(.winapi) LONG;

// 改扩展样式：64 位用 Ptr 版，32 位用不带 Ptr 的（和上面两个查询一一对应）。
extern "user32" fn SetWindowLongPtrW(hwnd: HWND, index: c_int, value: LONG_PTR) callconv(.winapi) LONG_PTR;

extern "user32" fn SetWindowLongW(hwnd: HWND, index: c_int, value: LONG) callconv(.winapi) LONG;

// 分层窗口：加/去 WS_EX_LAYERED 之后设整窗 alpha；查询读回同一对数。
extern "user32" fn SetLayeredWindowAttributes(hwnd: HWND, color_key: DWORD, alpha: u8, flags: DWORD) callconv(.winapi) BOOL;

extern "user32" fn GetLayeredWindowAttributes(hwnd: HWND, color_key: ?*DWORD, alpha: *u8, flags: ?*DWORD) callconv(.winapi) BOOL;

extern "user32" fn IsWindowVisible(hwnd: HWND) callconv(.winapi) BOOL;

/// 句柄是不是一个还活着的窗口。无效 / 已销毁 / 风格不对的句柄都在碰 Win32
/// 之前变成 `error.InvalidWindow`，不让调用方拿到一个假的成功或一个崩溃。
extern "user32" fn IsWindow(hwnd: HWND) callconv(.winapi) BOOL;

extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;

/// 清零错误码：`SetWindowLongPtrW` 成功时也返回 0，只能靠"调用前清零 +
/// 调用后 GetLastError"区分成功与失败。
extern "kernel32" fn SetLastError(code: DWORD) callconv(.winapi) void;

// 下面四个只在测试里用：建一个从不显示的 STATIC 窗口来断言真实的置顶位。
extern "user32" fn CreateWindowExW(
    ex_style: DWORD,
    class_name: [*:0]const u16,
    window_name: ?[*:0]const u16,
    style: DWORD,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    parent: ?HWND,
    menu: ?*anyopaque,
    instance: ?*anyopaque,
    param: ?*anyopaque,
) callconv(.winapi) ?HWND;

extern "user32" fn DestroyWindow(hwnd: HWND) callconv(.winapi) BOOL;

extern "user32" fn GetForegroundWindow() callconv(.winapi) ?HWND;

/// 前台锁的解法：临时与前台线程共享输入队列，让后台进程的 z-order 修改被接受。
/// 只用于 `setTopmost` 的第二次尝试；不激活、不改变前台窗口。
extern "user32" fn AttachThreadInput(id_attach: DWORD, id_attach_to: DWORD, attach: BOOL) callconv(.winapi) BOOL;

extern "user32" fn GetWindowThreadProcessId(hwnd: HWND, process_id: ?*DWORD) callconv(.winapi) DWORD;

extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) DWORD;

/// 当前线程最近一次 Win32 失败的码（0 = 没有失败）。只用于日志/排障。
threadlocal var last_win32_error: DWORD = 0;

pub fn lastError() u32 {
    return last_win32_error;
}

// ---------------------------------------------------------------------------
// 公共 API
// ---------------------------------------------------------------------------

/// 置顶 / 取消置顶。`hwnd` 为空 / 无效是 `error.InvalidWindow`，不是崩溃。
///
/// 不移动、不缩放、不激活窗口；成功返回后 `isTopmost(hwnd)` 立即反映新状态。
/// 返回 `error.TopmostRejected` 表示系统没有接受这次 z-order 修改（读回的位不
/// 符合期望），调用方不该把它当成成功；窗口被拒绝后第一次成为前台时可以再试。
pub fn setTopmost(hwnd: ?*anyopaque, on: bool) Error!void {
    if (!supported) return error.Unsupported;
    const raw = hwnd orelse return error.InvalidWindow;
    const handle: HWND = @ptrCast(raw);
    // 无效句柄在 SetWindowPos 里可能只是失败，也可能返回一个莫名其妙的码；
    // 先问 IsWindow，给调用方一个稳定的具名错误。
    if (IsWindow(handle) == 0) return error.InvalidWindow;

    const first_call_ok = setWindowPosTopmost(handle, on);
    // 以读回的位为准：即使 SetWindowPos 报失败，期望状态已经成立也算成功。
    if (isTopmost(handle) == on) return;
    // 硬失败（句柄已失效 / 权限不足）不是前台锁，不做徒劳的 attach。
    if (!first_call_ok) return error.SetWindowPosFailed;

    // 第一次 SetWindowPos 返回 TRUE，但位没变：后台进程被前台锁挡下了。
    // 找到前台线程，临时与它共享输入队列，再试一次。全程不激活、不改前台。
    const me = GetCurrentThreadId();
    var foreground_thread: DWORD = 0;
    if (GetForegroundWindow()) |foreground| {
        foreground_thread = GetWindowThreadProcessId(foreground, null);
    }
    // 前台就是本线程（或根本取不到）：没有可接的输入队列，直接如实拒绝。
    if (foreground_thread == 0 or foreground_thread == me) return error.TopmostRejected;

    var attached = false;
    // 兜底：任何提前返回路径都不能让两个线程的输入队列留在挂住状态。
    defer {
        if (attached) _ = AttachThreadInput(me, foreground_thread, 0);
    }
    if (AttachThreadInput(me, foreground_thread, 1) == 0) {
        last_win32_error = GetLastError();
        // 接不上也再试一次：最终只认读回的位，第二次的返回值同样不可信。
    } else {
        attached = true;
    }

    _ = setWindowPosTopmost(handle, on);
    if (attached) {
        // 立刻解挂：两个线程共享输入状态是严重问题，不能拖到函数返回。
        if (AttachThreadInput(me, foreground_thread, 0) != 0) attached = false;
    }
    if (isTopmost(handle) != on) return error.TopmostRejected;
}

/// 一次原始 `SetWindowPos`。返回 false 时 `last_win32_error` 是 Win32 码。
///
/// **返回值不是结果**：见文件头"前台锁"，它可能在位没变时也返回 true。
fn setWindowPosTopmost(handle: HWND, on: bool) bool {
    const insert_after: isize = if (on) HWND_TOPMOST else HWND_NOTOPMOST;
    const after: ?HWND = @ptrFromInt(@as(usize, @bitCast(insert_after)));
    if (SetWindowPos(handle, after, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE) == 0) {
        last_win32_error = GetLastError();
        return false;
    }
    return true;
}

/// 读 Windows 自己维护的 `WS_EX_TOPMOST` 位。空句柄 / 非 Windows 返回 false。
pub fn isTopmost(hwnd: ?*anyopaque) bool {
    if (!supported) return false;
    const raw = hwnd orelse return false;
    return exStyle(@ptrCast(raw)) & WS_EX_TOPMOST != 0;
}

/// 我们的窗口是不是当前前台窗口。空句柄 / 非 Windows / 没有前台返回 false。
///
/// nanoui 没有 focus 回调（只有每帧的 `Context.window_focused`），app 的启动
/// 置顶补救在 tick 里用这个系统事实判断"窗口第一次被激活"。
pub fn isForeground(hwnd: ?*anyopaque) bool {
    if (!supported) return false;
    const raw = hwnd orelse return false;
    const foreground = GetForegroundWindow() orelse return false;
    return foreground == @as(HWND, @ptrCast(raw));
}

/// 整体不透明度：0 = 全透明，255 = 完全不透明。
///
/// 先确保 `WS_EX_LAYERED`（`alpha < 255` 时需要，`alpha == 255` 时去掉），
/// 再 `SetLayeredWindowAttributes(hwnd, 0, alpha, LWA_ALPHA)`。
///
/// 不移动、不缩放、不激活窗口；也不碰上屏方式（GDI / D3D 由调用方决定，
/// 见文件头的已知限制）。重复设置是幂等的。
pub fn setOpacity(hwnd: ?*anyopaque, alpha: u8) Error!void {
    if (!supported) return error.Unsupported;
    const raw = hwnd orelse return error.InvalidWindow;
    const handle: HWND = @ptrCast(raw);

    const style = exStyle(handle);
    const layered = style & WS_EX_LAYERED != 0;

    if (alpha == 255) {
        // 完全不透明：没有分层窗口要做的事。已经在普通路径上就一次 Win32
        // 都不调；否则只去这一位（不去碰其它扩展样式）。
        if (!layered) return;
        try writeExStyle(handle, style & ~WS_EX_LAYERED);
        return;
    }

    if (!layered) try writeExStyle(handle, style | WS_EX_LAYERED);
    if (SetLayeredWindowAttributes(handle, 0, alpha, LWA_ALPHA) == 0) {
        last_win32_error = GetLastError();
        return error.SetLayeredWindowAttributesFailed;
    }
}

/// 读回整体不透明度。**没有分层窗口时返回 `null`**（= 完全不透明，见文件头
/// "255 的取舍"）；空句柄是 `error.InvalidWindow`，不是崩溃。
pub fn getOpacity(hwnd: ?*anyopaque) Error!?u8 {
    if (!supported) return error.Unsupported;
    const raw = hwnd orelse return error.InvalidWindow;
    const handle: HWND = @ptrCast(raw);
    if (exStyle(handle) & WS_EX_LAYERED == 0) return null;

    var alpha: u8 = 0;
    var flags: DWORD = 0;
    if (GetLayeredWindowAttributes(handle, null, &alpha, &flags) == 0) {
        last_win32_error = GetLastError();
        return error.GetLayeredWindowAttributesFailed;
    }
    // 只设了 LWA_COLORKEY 的窗口 bAlpha 恒为 0，但整窗其实不透明；本口岸只设
    // LWA_ALPHA，这里把"没有 alpha 位"如实当成 255，而不是报一个假的 0。
    if (flags & LWA_ALPHA == 0) return 255;
    return alpha;
}

/// 窗口是否在分层路径上（`WS_EX_LAYERED`）。空句柄 / 非 Windows 返回 false。
pub fn isLayered(hwnd: ?*anyopaque) bool {
    if (!supported) return false;
    const raw = hwnd orelse return false;
    return exStyle(@ptrCast(raw)) & WS_EX_LAYERED != 0;
}

/// 窗口是否可见。验收脚本用它钉住"探针窗口全程 hidden"（置顶/透明度都不该
/// 把窗口弹出来）。空句柄 / 非 Windows 返回 false。
pub fn isVisible(hwnd: ?*anyopaque) bool {
    if (!supported) return false;
    const raw = hwnd orelse return false;
    return IsWindowVisible(@ptrCast(raw)) != 0;
}

// ---------------------------------------------------------------------------
// 内部：扩展样式的读 / 写（64 位与 32 位各一条分支）
// ---------------------------------------------------------------------------

fn exStyle(handle: HWND) usize {
    return if (@sizeOf(usize) == 8)
        @bitCast(GetWindowLongPtrW(handle, GWL_EXSTYLE))
    else
        @bitCast(GetWindowLongW(handle, GWL_EXSTYLE));
}

fn writeExStyle(handle: HWND, style: usize) Error!void {
    SetLastError(0);
    // 返回值是**旧**样式，不是成功与否：旧样式正好是 0 时也返回 0，所以只能
    // 靠"先清零再读 GetLastError"区分（Win32 的经典坑）。
    const previous: isize = if (@sizeOf(usize) == 8)
        SetWindowLongPtrW(handle, GWL_EXSTYLE, @bitCast(style))
    else
        SetWindowLongW(handle, GWL_EXSTYLE, @bitCast(@as(u32, @truncate(style))));
    if (previous == 0) {
        const code = GetLastError();
        if (code != 0) {
            last_win32_error = code;
            return error.SetStyleFailed;
        }
    }
}

// ---------------------------------------------------------------------------
// 测试：真实隐藏窗口（STATIC 系统类），不显示、不激活、不抢焦点
// ---------------------------------------------------------------------------

const testing = std.testing;

/// "没有抢焦点"的唯一正确断言：**我们的 hwnd 不是前台窗口**。
///
/// 不能断言"操作前后 `GetForegroundWindow()` 完全相等"：通知弹窗、后台更新、
/// 用户切窗口都会合法地改变前台，那条断言测的是"这台机器没人动前台"，会把
/// 无关的环境变化记成我们的失败。前台为 null（锁屏/切桌面）同样说明不是我们。
fn expectNotForeground(hwnd: HWND) !void {
    if (GetForegroundWindow()) |foreground| {
        try testing.expect(foreground != hwnd);
    }
}

fn hwndValue(handle: ?HWND) usize {
    return if (handle) |value| @intFromPtr(value) else 0;
}

fn isOurs(handle: ?HWND, hwnd: HWND) bool {
    return if (handle) |value| value == hwnd else false;
}

/// 建一个从未 `ShowWindow` 过的系统 `STATIC` 窗口：没有消息循环也能被
/// `SetWindowPos` 改扩展样式。`WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW` 保证它
/// 即使被误显示也不会抢焦点、不进任务栏。
fn createHiddenWindow() !HWND {
    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("STATIC");
    return CreateWindowExW(
        WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW,
        class_name,
        null,
        WS_POPUP,
        -32000,
        -32000,
        64,
        64,
        null,
        null,
        null,
        null,
    ) orelse error.CreateWindowFailed;
}

test "topmost-foreground-input: 真实隐藏窗口，调用方不 attach，setTopmost 自己处理前台锁" {
    if (!supported) return error.SkipZigTest;

    const hwnd = try createHiddenWindow();
    defer _ = DestroyWindow(hwnd);

    // 新建的窗口不在置顶层。
    try testing.expect(!isTopmost(hwnd));
    // 前后两个前台值只作诊断打印用；断言只看"前台是不是我们"。
    const foreground_before = GetForegroundWindow();
    try expectNotForeground(hwnd);
    try testing.expect(!isForeground(hwnd));

    // 验收 2：调用方**绝不** AttachThreadInput。测试进程通常是后台进程，
    // 前台锁必须由 setTopmost 自己接、自己解；失败会以具名错误返回（`try`
    // 会让测试失败），不会静默放过。
    try setTopmost(hwnd, true);
    try testing.expect(isTopmost(hwnd));
    try expectNotForeground(hwnd);
    try testing.expect(!isForeground(hwnd));

    try setTopmost(hwnd, false);
    try testing.expect(!isTopmost(hwnd));
    try expectNotForeground(hwnd);

    // 全程没有激活：我们的窗口任何时候都不是前台（隐藏窗口本来也不会被点到，
    // 这里钉住 SWP_NOACTIVATE 的语义）。无关程序抢前台不影响这个断言。
    const foreground_after = GetForegroundWindow();
    std.debug.print(
        "win_window topmost: foreground_before=0x{x} foreground_after=0x{x} our_hwnd=0x{x} our_window_was_foreground={}\n",
        .{
            hwndValue(foreground_before),
            hwndValue(foreground_after),
            @intFromPtr(hwnd),
            isOurs(foreground_before, hwnd) or isOurs(foreground_after, hwnd),
        },
    );
    try expectNotForeground(hwnd);
}

test "topmost-invalid: null / 无效句柄是具名错误；重复设置是幂等的" {
    if (!supported) return error.SkipZigTest;

    try testing.expectError(error.InvalidWindow, setTopmost(null, true));
    try testing.expect(!isTopmost(null));

    // 验收 4：把一个无效句柄（比如已销毁 / 伪造的值）传进来，必须是具名错误，
    // 不是崩溃、也不是假装成功。`IsWindow` 先把它挡在 Win32 调用之前。
    const bogus: *anyopaque = @ptrFromInt(@as(usize, 0x1234_5678));
    try testing.expectError(error.InvalidWindow, setTopmost(bogus, true));
    try testing.expectError(error.InvalidWindow, setTopmost(bogus, false));
    try testing.expect(!isTopmost(bogus));
    try testing.expect(!isForeground(bogus));

    const hwnd = try createHiddenWindow();
    defer _ = DestroyWindow(hwnd);

    // 幂等：第二次设置同一值不会把置顶位弄丢，也不该触发前台锁兜底。
    try setTopmost(hwnd, true);
    try setTopmost(hwnd, true);
    try testing.expect(isTopmost(hwnd));
    try setTopmost(hwnd, false);
    try setTopmost(hwnd, false);
    try testing.expect(!isTopmost(hwnd));
}

test "真实隐藏窗口：0 / 128 / 255 的读回、WS_EX_LAYERED 位与前台不归我们" {
    if (!supported) return error.SkipZigTest;

    const hwnd = try createHiddenWindow();
    defer _ = DestroyWindow(hwnd);

    // 前后两个前台值只作诊断打印用；断言只看"前台是不是我们"。
    const foreground_before = GetForegroundWindow();
    try expectNotForeground(hwnd);
    try testing.expect(!isLayered(hwnd));
    try testing.expect(!isVisible(hwnd));
    // 没有分层窗口 = 没有 alpha 可读；调用方按"255 完全不透明"理解。
    try testing.expectEqual(@as(?u8, null), try getOpacity(hwnd));

    try setOpacity(hwnd, 128);
    try testing.expect(isLayered(hwnd));
    try testing.expectEqual(@as(?u8, 128), try getOpacity(hwnd));
    try expectNotForeground(hwnd);
    // 改样式不该让窗口变得可见：探针/正常启动都必须保持 hidden。
    try testing.expect(!isVisible(hwnd));

    // 255：去掉分层位，窗口回到普通（非分层）合成路径。
    try setOpacity(hwnd, 255);
    try testing.expect(!isLayered(hwnd));
    try testing.expectEqual(@as(?u8, null), try getOpacity(hwnd));
    try expectNotForeground(hwnd);

    try setOpacity(hwnd, 0);
    try testing.expect(isLayered(hwnd));
    try testing.expectEqual(@as(?u8, 0), try getOpacity(hwnd));
    try expectNotForeground(hwnd);

    // 重复设置同一值是幂等的（不会把分层位移掉或在两条路径之间来回切）。
    try setOpacity(hwnd, 0);
    try testing.expect(isLayered(hwnd));
    try testing.expectEqual(@as(?u8, 0), try getOpacity(hwnd));

    // 只改了扩展样式与 alpha，没有 SetWindowPos / SetForegroundWindow：
    // 我们的窗口全程都不是前台（和置顶那条测试同一个断言）。期间别人抢前台
    // 不算失败——那正是原来 before/after 相等断言产生假失败的原因。
    const foreground_after = GetForegroundWindow();
    std.debug.print(
        "win_window opacity: foreground_before=0x{x} foreground_after=0x{x} our_hwnd=0x{x} our_window_was_foreground={}\n",
        .{
            hwndValue(foreground_before),
            hwndValue(foreground_after),
            @intFromPtr(hwnd),
            isOurs(foreground_before, hwnd) or isOurs(foreground_after, hwnd),
        },
    );
    try expectNotForeground(hwnd);
}

test "不透明度：空句柄是具名错误；isLayered / isVisible 对空句柄是 false" {
    if (!supported) return error.SkipZigTest;

    try testing.expectError(error.InvalidWindow, setOpacity(null, 128));
    try testing.expectError(error.InvalidWindow, getOpacity(null));
    try testing.expect(!isLayered(null));
    try testing.expect(!isVisible(null));
}
