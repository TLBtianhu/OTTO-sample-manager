//! OTTO 的真实窗口图标。PE 资源只负责 Explorer / 快捷方式；nanoui 注册的窗口类
//! 没有 hIcon，所以还必须在 app 拿到 HWND 后显式 WM_SETICON。
//!
//! 这里只声明需要的 Win32 ABI：不经过 C 头文件、@cImport 或 nanoui 渲染层。
//! 两个图标都来自当前模块（otto-lite.exe）的资源 ID 1，与 build.zig 的 `1 ICON` 同源。

const std = @import("std");

const HINSTANCE = *opaque {};
const HICON = *opaque {};
const resource_id: usize = 1;
const image_icon: u32 = 1;
const lr_shared: u32 = 0x8000;
const wm_seticon: u32 = 0x0080;
const wm_geticon: u32 = 0x007f;
const icon_small: usize = 0;
const icon_big: usize = 1;
const sm_cxicon: i32 = 11;
const sm_cxsmicon: i32 = 49;

extern "kernel32" fn GetModuleHandleW(name: ?[*:0]const u16) callconv(.winapi) ?HINSTANCE;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;
extern "user32" fn GetSystemMetrics(index: i32) callconv(.winapi) i32;
extern "user32" fn LoadImageW(
    instance: ?HINSTANCE,
    name: ?*anyopaque,
    image_type: u32,
    width: i32,
    height: i32,
    flags: u32,
) callconv(.winapi) ?HICON;
extern "user32" fn SendMessageW(
    hwnd: *anyopaque,
    message: u32,
    wparam: usize,
    lparam: isize,
) callconv(.winapi) isize;

/// 在窗口创建后应用大/小图标。任何失败都只打具名日志，绝不阻止启动。
/// 离屏 Tester / 无窗口快照没有 HWND，本来就不需要设置，直接返回。
pub fn apply(native_hwnd: ?*anyopaque) void {
    const hwnd = native_hwnd orelse return;
    const instance = GetModuleHandleW(null) orelse {
        std.debug.print(
            "otto-lite: app-icon failed stage=GetModuleHandleW error={d}\n",
            .{GetLastError()},
        );
        return;
    };

    const big_size = metricOr(sm_cxicon, 32);
    const small_size = metricOr(sm_cxsmicon, 16);
    const big = load(instance, big_size, "big");
    const small = load(instance, small_size, "small");
    const big_ok = if (big) |icon| setAndVerify(hwnd, icon, icon_big, "big") else false;
    const small_ok = if (small) |icon| setAndVerify(hwnd, icon, icon_small, "small") else false;
    if (big_ok and small_ok) {
        std.debug.print(
            "otto-lite: app-icon applied resource={d} big={d}px small={d}px\n",
            .{ resource_id, big_size, small_size },
        );
    }
}

fn metricOr(metric: i32, fallback: i32) i32 {
    const value = GetSystemMetrics(metric);
    return if (value > 0) value else fallback;
}

fn load(instance: HINSTANCE, size: i32, label: []const u8) ?HICON {
    const resource_name: *anyopaque = @ptrFromInt(resource_id);
    // LR_SHARED 的生命周期由系统管理；窗口销毁时不应 DestroyIcon 这份共享句柄。
    const icon = LoadImageW(instance, resource_name, image_icon, size, size, lr_shared) orelse {
        std.debug.print(
            "otto-lite: app-icon failed stage=LoadImageW kind={s} size={d} error={d}\n",
            .{ label, size, GetLastError() },
        );
        return null;
    };
    return icon;
}

fn setAndVerify(hwnd: *anyopaque, icon: HICON, kind: usize, label: []const u8) bool {
    const icon_lparam: isize = @bitCast(@intFromPtr(icon));
    _ = SendMessageW(hwnd, wm_seticon, kind, icon_lparam);
    const current = SendMessageW(hwnd, wm_geticon, kind, 0);
    if (current == 0) {
        std.debug.print(
            "otto-lite: app-icon failed stage=WM_GETICON kind={s} error=IconNotSet\n",
            .{label},
        );
        return false;
    }
    const current_address: usize = @bitCast(current);
    if (current_address != @intFromPtr(icon)) {
        std.debug.print(
            "otto-lite: app-icon failed stage=WM_GETICON kind={s} error=IconMismatch\n",
            .{label},
        );
        return false;
    }
    return true;
}
