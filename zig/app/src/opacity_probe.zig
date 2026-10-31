//! `--settings-probe --set-opacity=<0..100>`：验收专用的可编程入口。
//!
//! 它不是第二条应用路径：写的是滑块同一个字段（`settings.opacity`），调的是
//! 滑块同一个 `Panel.applyOpacity`，落盘用的是关闭面板同一个 `Panel.save`
//! （见 `settings_ui.setOpacityPercent`）。本文件只做产品路径之外的三件事：
//! 校验参数、打印一行机器可读的 Windows 状态、退出进程。
//!
//! 窗口仍由 `main.zig` 用 hidden / no_activate 建出来：验收要的是真 HWND
//! （`WS_EX_LAYERED` / `GetLayeredWindowAttributes` 是系统事实），但绝不弹窗、
//! 不抢焦点、不进任务栏。

const std = @import("std");
const options_mod = @import("options.zig");
const settings_ui = @import("settings_ui.zig");
const win_window = @import("otto_win_window");

/// 解析失败：`InvalidOpacity` 打印具名错误并 exit 1（脚本 grep
/// `set-opacity-invalid`）；其它解析错误沿用原来的"打印用法 + 退出 1"。
pub fn parseError(err: anyerror) error{InvalidArguments} {
    if (err == error.InvalidOpacity) {
        std.debug.print(
            "otto-lite: set-opacity-invalid（--set-opacity 需要 0..100 的整数；0 合法）\n",
            .{},
        );
        std.process.exit(1);
    }
    options_mod.printUsage();
    return error.InvalidArguments;
}

/// 启动时应用一次窗口状态；带 `--set-opacity` 时再走一次与滑块相同的应用路径，
/// 原子写设置文件，打印一行机器可读状态后退出 0。
pub fn applyStartup(panel: *settings_ui.Panel, hwnd: ?*anyopaque, percent: ?u8) void {
    panel.applyWindowState(hwnd);
    const value = percent orelse return;
    const alpha = panel.setOpacityPercent(value, hwnd);
    const readback = win_window.getOpacity(hwnd) catch null;
    const address: usize = if (hwnd) |handle| @intFromPtr(handle) else 0;
    std.debug.print(
        "otto-lite: opacity-set percent={d} alpha={d} layered={} getOpacity={?d} visible={} hwnd=0x{x}\n",
        .{
            value,
            alpha,
            win_window.isLayered(hwnd),
            readback,
            win_window.isVisible(hwnd),
            address,
        },
    );
    std.process.exit(0);
}
