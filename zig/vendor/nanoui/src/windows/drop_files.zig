//! Files dropped on a Windows window: one HDROP becomes one native UI drop,
//! with file URLs like the ones AppKit delivers and the point in view points.
const std = @import("std");
const w = @import("win32.zig");
const Surface = @import("surface.zig").Surface;
const types = @import("../ui/types.zig");
const file_url = @import("../file_url.zig");

/// One WM_DROPFILES, however many files it carries. The URLs and their UTF-8
/// storage live for the frame, as they do on the Mac; the HDROP does not.
pub fn handle(surface: ?*Surface, hwnd: w.HWND, hdrop: w.HDROP) void {
    defer w.DragFinish(hdrop);
    const s = surface orelse return;
    var p: w.POINT = .{};
    // A non-client drop is reported in screen coordinates; a client one is
    // already in the coordinates the surface uses before its DPI scale.
    if (w.DragQueryPoint(hdrop, &p) == 0) _ = w.ScreenToClient(hwnd, &p);
    const point: types.Point = .{ .x = @as(f32, @floatFromInt(p.x)) / s.scale, .y = @as(f32, @floatFromInt(p.y)) / s.scale };
    // As on the Mac, a box opts in with acceptDrop. Other windows and boxes
    // keep their old behavior: no input event and no frame for a drop.
    if (!s.ctx.acceptsDropAt(point)) return;
    var arena: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const urls = readUrls(a, hdrop) catch return;
    if (urls.len == 0) return;
    s.ctx.input.drag_over = null;
    s.ctx.input.drop = .{ .point = point, .urls = urls };
    defer s.ctx.input.drop = null;
    s.frame();
}

fn readUrls(a: std.mem.Allocator, hdrop: w.HDROP) ![]const []const u8 {
    const count = w.DragQueryFileW(hdrop, 0xFFFF_FFFF, null, 0);
    const urls = try a.alloc([]const u8, count);
    var n: usize = 0;
    for (0..count) |i| {
        const index: u32 = @intCast(i);
        // With no buffer this is the length without the null terminator.
        const len = w.DragQueryFileW(hdrop, index, null, 0);
        if (len == 0) continue;
        const units = try a.alloc(u16, @as(usize, len) + 1);
        const got = w.DragQueryFileW(hdrop, index, units.ptr, @intCast(units.len));
        if (got == 0 or got > len) continue;
        urls[n] = fileUrlUtf16(a, units[0..got]) catch continue;
        n += 1;
    }
    return urls[0..n];
}

fn fileUrlUtf16(a: std.mem.Allocator, units: []const u16) ![]u8 {
    const path = try std.unicode.utf16LeToUtf8Alloc(a, units);
    defer a.free(path);
    return file_url.fromWindowsPath(a, path);
}

fn expectFileUrl(expected: []const u8, path: []const u8) !void {
    const a = std.testing.allocator;
    const units = try std.unicode.utf8ToUtf16LeAlloc(a, path);
    defer a.free(units);
    const url = try fileUrlUtf16(a, units);
    defer a.free(url);
    try std.testing.expectEqualStrings(expected, url);
}

test "Windows drop converts UTF-16 Chinese paths and escapes URL bytes" {
    try expectFileUrl("file:///C:/Users/%E4%B8%AD%E6%96%87/%E6%8A%A5%E5%91%8A%20%231%3F100%25.txt", "C:\\Users\\中文\\报告 #1?100%.txt");
}

test "Windows drop keeps a long path without its extended-length prefix" {
    const a = std.testing.allocator;
    const tail: [280]u8 = @splat('a');
    var path_buf: [320]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "\\\\?\\C:\\{s}\\file.txt", .{tail});
    const expected = try std.fmt.allocPrint(a, "file:///C:/{s}/file.txt", .{tail});
    defer a.free(expected);
    try expectFileUrl(expected, path);
}

test "Windows drop converts UNC and extended UNC paths" {
    try expectFileUrl("file://server/share/dir/%E4%B8%AD%E6%96%87.txt", "\\\\server\\share\\dir\\中文.txt");
    try expectFileUrl("file://server/share/long.txt", "\\\\?\\UNC\\server\\share\\long.txt");
}
