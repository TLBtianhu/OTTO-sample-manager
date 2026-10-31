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
    return exStyle(@ptrCast(raw)) & WS_EX_TOPMOST != 0;
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

test "真实隐藏窗口：0 / 128 / 255 的读回、WS_EX_LAYERED 位与前台不变" {
    if (!supported) return error.SkipZigTest;

    const hwnd = try createHiddenWindow();
    defer _ = DestroyWindow(hwnd);

    const foreground_before = GetForegroundWindow();
    try testing.expect(!isLayered(hwnd));
    try testing.expect(!isVisible(hwnd));
    // 没有分层窗口 = 没有 alpha 可读；调用方按"255 完全不透明"理解。
    try testing.expectEqual(@as(?u8, null), try getOpacity(hwnd));

    try setOpacity(hwnd, 128);
    try testing.expect(isLayered(hwnd));
    try testing.expectEqual(@as(?u8, 128), try getOpacity(hwnd));
    // 改样式不该让窗口变得可见：探针/正常启动都必须保持 hidden。
    try testing.expect(!isVisible(hwnd));

    // 255：去掉分层位，窗口回到普通（非分层）合成路径。
    try setOpacity(hwnd, 255);
    try testing.expect(!isLayered(hwnd));
    try testing.expectEqual(@as(?u8, null), try getOpacity(hwnd));

    try setOpacity(hwnd, 0);
    try testing.expect(isLayered(hwnd));
    try testing.expectEqual(@as(?u8, 0), try getOpacity(hwnd));

    // 重复设置同一值是幂等的（不会把分层位移掉或在两条路径之间来回切）。
    try setOpacity(hwnd, 0);
    try testing.expect(isLayered(hwnd));
    try testing.expectEqual(@as(?u8, 0), try getOpacity(hwnd));

    // 只改了扩展样式与 alpha，没有 SetWindowPos / SetForegroundWindow：
    // 前台窗口全程不变（和置顶那条测试同一个断言）。
    try testing.expectEqual(foreground_before, GetForegroundWindow());
}

test "不透明度：空句柄是具名错误；isLayered / isVisible 对空句柄是 false" {
    if (!supported) return error.SkipZigTest;

    try testing.expectError(error.InvalidWindow, setOpacity(null, 128));
    try testing.expectError(error.InvalidWindow, getOpacity(null));
    try testing.expect(!isLayered(null));
    try testing.expect(!isVisible(null));
}
