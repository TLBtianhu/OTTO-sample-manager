//! 窗口置顶口岸（Windows）：把**已存在的** HWND 放进 / 移出 always-on-top 层。
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
};

// ---------------------------------------------------------------------------
// 手写 Win32 声明（只用到置顶与扩展样式查询）
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

extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;

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

/// 当前线程最近一次 Win32 失败的码（0 = 没有失败）。只用于日志/排障。
threadlocal var last_win32_error: DWORD = 0;

pub fn lastError() u32 {
    return last_win32_error;
}

// ---------------------------------------------------------------------------
// 公共 API
// ---------------------------------------------------------------------------

/// 置顶 / 取消置顶。`hwnd` 为空是 `error.InvalidWindow`，不是崩溃。
///
/// 不移动、不缩放、不激活窗口；成功返回后 `isTopmost(hwnd)` 立即反映新状态。
pub fn setTopmost(hwnd: ?*anyopaque, on: bool) Error!void {
    if (!supported) return error.Unsupported;
    const raw = hwnd orelse return error.InvalidWindow;
    const handle: HWND = @ptrCast(raw);

    const insert_after: isize = if (on) HWND_TOPMOST else HWND_NOTOPMOST;
    const after: ?HWND = @ptrFromInt(@as(usize, @bitCast(insert_after)));
    if (SetWindowPos(handle, after, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE) == 0) {
        last_win32_error = GetLastError();
        return error.SetWindowPosFailed;
    }
}

/// 读 Windows 自己维护的 `WS_EX_TOPMOST` 位。空句柄 / 非 Windows 返回 false。
pub fn isTopmost(hwnd: ?*anyopaque) bool {
    if (!supported) return false;
    const raw = hwnd orelse return false;
    const handle: HWND = @ptrCast(raw);

    const style: usize = if (@sizeOf(usize) == 8)
        @bitCast(GetWindowLongPtrW(handle, GWL_EXSTYLE))
    else
        @bitCast(GetWindowLongW(handle, GWL_EXSTYLE));
    return style & WS_EX_TOPMOST != 0;
}

// ---------------------------------------------------------------------------
// 测试：真实隐藏窗口（STATIC 系统类），不显示、不激活、不抢焦点
// ---------------------------------------------------------------------------

const testing = std.testing;

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

test "真实隐藏窗口：设置/取消 WS_EX_TOPMOST，且不抢前台" {
    if (!supported) return error.SkipZigTest;

    const hwnd = try createHiddenWindow();
    defer _ = DestroyWindow(hwnd);

    // 新建的窗口不在置顶层。
    try testing.expect(!isTopmost(hwnd));
    const foreground_before = GetForegroundWindow();

    try setTopmost(hwnd, true);
    try testing.expect(isTopmost(hwnd));

    try setTopmost(hwnd, false);
    try testing.expect(!isTopmost(hwnd));

    // 全程没有激活：前台窗口不变（隐藏窗口本来也不会被点到，这里钉住
    // SWP_NOACTIVATE 的语义）。
    try testing.expectEqual(foreground_before, GetForegroundWindow());
}

test "空句柄是具名错误；重复设置是幂等的" {
    if (!supported) return error.SkipZigTest;

    try testing.expectError(error.InvalidWindow, setTopmost(null, true));
    try testing.expect(!isTopmost(null));

    const hwnd = try createHiddenWindow();
    defer _ = DestroyWindow(hwnd);

    try setTopmost(hwnd, true);
    try setTopmost(hwnd, true);
    try testing.expect(isTopmost(hwnd));
    try setTopmost(hwnd, false);
    try setTopmost(hwnd, false);
    try testing.expect(!isTopmost(hwnd));
}
