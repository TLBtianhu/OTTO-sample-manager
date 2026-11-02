//! 目录地址栏的 CF_UNICODETEXT 出口；不写文件、不建窗口、不抢焦点。
const std = @import("std");
const drag = @import("drag.zig");

const HGLOBAL = *anyopaque;
extern "kernel32" fn GlobalAlloc(flags: u32, bytes: usize) callconv(.winapi) ?HGLOBAL;
extern "kernel32" fn GlobalLock(memory: ?HGLOBAL) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GlobalUnlock(memory: ?HGLOBAL) callconv(.winapi) i32;
extern "kernel32" fn GlobalFree(memory: ?HGLOBAL) callconv(.winapi) ?HGLOBAL;
extern "user32" fn OpenClipboard(owner: ?*anyopaque) callconv(.winapi) i32;
extern "user32" fn EmptyClipboard() callconv(.winapi) i32;
extern "user32" fn CloseClipboard() callconv(.winapi) i32;
extern "user32" fn SetClipboardData(format: u32, memory: ?HGLOBAL) callconv(.winapi) ?*anyopaque;

pub fn copy(allocator: std.mem.Allocator, text: []const u8) drag.Error!void {
    if (text.len == 0 or std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidPath;
    const wide = std.unicode.wtf8ToWtf16LeAllocZ(allocator, text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidWtf8 => return error.InvalidPath,
    };
    defer allocator.free(wide);
    const memory = GlobalAlloc(0x0002, (wide.len + 1) * 2) orelse return error.OutOfMemory;
    errdefer _ = GlobalFree(memory);
    const locked = GlobalLock(memory) orelse return error.OleFailure;
    const destination: [*]u16 = @ptrCast(@alignCast(locked));
    @memcpy(destination[0..wide.len], wide);
    destination[wide.len] = 0;
    _ = GlobalUnlock(memory);
    if (OpenClipboard(null) == 0) return error.OleFailure;
    defer _ = CloseClipboard();
    if (EmptyClipboard() == 0) return error.OleFailure;
    // 成功后 HGLOBAL 归系统所有；errdefer 不执行。
    if (SetClipboardData(13, memory) == null) return error.OleFailure;
}

test "空路径在碰剪贴板前拒绝" {
    try std.testing.expectError(error.InvalidPath, copy(std.testing.allocator, ""));
}
