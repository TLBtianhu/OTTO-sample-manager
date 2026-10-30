//! 窗口小工具：原生句柄与标题。从 `main.zig` 拆出来，只为守住单文件行数。
//!
//! 两件事都只在有窗口时才有意义：拖拽口岸要 HWND（无窗口时返回 null，拖拽
//! 走"跳过"分支），标题跟着库里的行数走（`version.windowTitle`）。

const std = @import("std");
const nanoui = @import("nanoui");
const version_mod = @import("version.zig");

/// 平台原生窗口句柄。Windows 上 `Window` 有 `hwnd` 字段；其它平台没有（拖拽口岸
/// 也只在 Windows 上场），用 comptime 检查而不是条件编译整个 app。
pub fn nativeHandle(window: ?*nanoui.Window) ?*anyopaque {
    const win = window orelse return null;
    if (comptime @hasField(nanoui.Window, "hwnd")) {
        const hwnd = win.hwnd orelse return null;
        return @ptrCast(hwnd);
    }
    return null;
}

/// 窗口标题：`OTTO Lite <版本> — <行数>`（见 `version.windowTitle`）。
pub fn setTitle(window: *nanoui.Window, total: usize) void {
    var buffer: [96]u8 = undefined;
    window.setTitle(version_mod.windowTitle(&buffer, total));
}
