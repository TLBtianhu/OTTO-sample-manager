//! 合成一次 Windows 的「文件拖入」：构造 `DROPFILES`（`fWide = TRUE`）放进
//! `GMEM_MOVEABLE` 的 HGLOBAL，再 `PostMessage(WM_DROPFILES, hglobal, 0)`。
//!
//! 为什么需要它：`DragQueryFileW` 只认 HGLOBAL 里的 DROPFILES，没有别的入口。
//! 有了这个构造器，验收就能在不碰鼠标、不开窗的情况下走真实的
//! `WM_DROPFILES` → `DragQueryFileW` → UTF-8 回调链（见 `drop_ui.zig` 的探针）。
//!
//! 内存所有权：`build` 返回的 HGLOBAL 在 `post` 成功后归窗口过程——它调用
//! `DragFinish` 释放；`post` 失败时本文件自己释放。测试直接 `DragFinish`。

const std = @import("std");

pub const HWND = *anyopaque;
pub const HDROP = *anyopaque;

pub const WM_DROPFILES: u32 = 0x0233;

/// `DROPFILES`（winuser.h）：文件列表在 `pFiles` 字节处，`fWide` 为 TRUE 时是
/// UTF-16LE，每条路径以 0 结尾，列表再以额外的 0 结尾。
const DROPFILES = extern struct {
    pFiles: u32 = 20,
    pt: POINT = .{},
    fNC: i32 = 0,
    fWide: i32 = 1,
};

const POINT = extern struct { x: i32 = 0, y: i32 = 0 };

comptime {
    // 20 = DWORD + POINT + BOOL + BOOL，和 winuser.h 一致。
    std.debug.assert(@sizeOf(DROPFILES) == 20);
    std.debug.assert(@sizeOf(POINT) == 8);
}

const GMEM_MOVEABLE: u32 = 0x0002;
const GMEM_ZEROINIT: u32 = 0x0040;

extern "kernel32" fn GlobalAlloc(flags: u32, bytes: usize) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GlobalLock(mem: *anyopaque) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GlobalUnlock(mem: *anyopaque) callconv(.winapi) i32;
extern "kernel32" fn GlobalFree(mem: *anyopaque) callconv(.winapi) ?*anyopaque;
extern "user32" fn PostMessageW(hwnd: HWND, msg: u32, wp: usize, lp: isize) callconv(.winapi) i32;
extern "shell32" fn DragQueryFileW(hdrop: HDROP, index: u32, file: ?[*]u16, chars: u32) callconv(.winapi) u32;
extern "shell32" fn DragFinish(hdrop: HDROP) callconv(.winapi) void;

/// HGLOBAL 需要多大：头部 + 每条路径（UTF-16 + 结尾 0）+ 列表最后的 0。
pub fn payloadSize(paths: []const []const u8) !usize {
    var size: usize = @sizeOf(DROPFILES) + 2;
    for (paths) |path| size += (try std.unicode.calcUtf16LeLen(path) + 1) * 2;
    return size;
}

/// 把 `paths` 写成 DROPFILES 载荷。`buffer` 必须至少有 `payloadSize` 字节；
/// 全部字节先清零，所以路径的结尾 0 与列表结尾的 0 不用手写。
pub fn writePayload(buffer: []u8, paths: []const []const u8) !void {
    const size = try payloadSize(paths);
    if (buffer.len < size) return error.BufferTooSmall;
    @memset(buffer, 0);
    const header: *DROPFILES = @ptrCast(@alignCast(buffer.ptr));
    header.* = .{ .pFiles = @sizeOf(DROPFILES), .fWide = 1 };
    var offset: usize = @sizeOf(DROPFILES);
    for (paths) |path| {
        const max = try std.unicode.calcUtf16LeLen(path);
        const units: [*]u16 = @ptrCast(@alignCast(buffer.ptr + offset));
        const written = try std.unicode.utf8ToUtf16Le(units[0..max], path);
        offset += (written + 1) * 2;
    }
}

/// 造一个 HGLOBAL 形式的 HDROP。调用方负责 `DragFinish`（或 `GlobalFree`）。
pub fn build(paths: []const []const u8) !HDROP {
    const size = try payloadSize(paths);
    const mem = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, size) orelse return error.OutOfMemory;
    errdefer _ = GlobalFree(mem);
    const raw = GlobalLock(mem) orelse return error.GlobalLockFailed;
    const buffer: []u8 = @as([*]u8, @ptrCast(raw))[0..size];
    try writePayload(buffer, paths);
    _ = GlobalUnlock(mem);
    return mem;
}

/// 向 `hwnd` 投递一次合成的拖放。窗口过程处理完会 `DragFinish` 这块内存。
pub fn post(hwnd: HWND, paths: []const []const u8) !void {
    const mem = try build(paths);
    errdefer _ = GlobalFree(mem);
    if (PostMessageW(hwnd, WM_DROPFILES, @intFromPtr(mem), 0) == 0) return error.PostMessageFailed;
}

// ---------------------------------------------------------------------------
// 测试：只碰 HGLOBAL 与 DragQueryFileW，不需要窗口
// ---------------------------------------------------------------------------

const testing = std.testing;

fn readPath(hdrop: HDROP, index: u32, buffer: []u16) []const u16 {
    const n = DragQueryFileW(hdrop, index, buffer.ptr, @intCast(buffer.len));
    return buffer[0..n];
}

test "合成 DROPFILES：宽字符路径按顺序读回，条数与内容都不变" {
    const paths = [_][]const u8{ "C:\\素材\\鼓组", "D:\\packs\\bass" };
    const hdrop = try build(&paths);
    defer DragFinish(hdrop);

    try testing.expectEqual(@as(u32, 2), DragQueryFileW(hdrop, 0xFFFF_FFFF, null, 0));

    var units: [512]u16 = undefined;
    for (paths, 0..) |expected, i| {
        const utf8 = try std.unicode.utf16LeToUtf8Alloc(testing.allocator, readPath(hdrop, @intCast(i), &units));
        defer testing.allocator.free(utf8);
        try testing.expectEqualStrings(expected, utf8);
    }
}

test "合成 DROPFILES：没有路径时条数是 0（列表仍以两个 0 结尾）" {
    const hdrop = try build(&.{});
    defer DragFinish(hdrop);
    try testing.expectEqual(@as(u32, 0), DragQueryFileW(hdrop, 0xFFFF_FFFF, null, 0));
}

test "DROPFILES 头部是宽字符、偏移 20，载荷以双 0 收尾" {
    const paths = [_][]const u8{"C:\\a"};
    const size = try payloadSize(&paths);
    const bytes = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(bytes);
    try writePayload(bytes, &paths);

    const header: *const DROPFILES = @ptrCast(@alignCast(bytes.ptr));
    try testing.expectEqual(@as(u32, 20), header.pFiles);
    try testing.expect(header.fWide != 0);
    // 路径 4 个 UTF-16 单元（C:\a）+ 结尾 0，再加列表结尾的 0：20 + 12。
    try testing.expectEqual(@as(usize, 20 + (4 + 1 + 1) * 2), size);
    try testing.expectEqual(@as(u8, 0), bytes[size - 2]);
    try testing.expectEqual(@as(u8, 0), bytes[size - 1]);
}
