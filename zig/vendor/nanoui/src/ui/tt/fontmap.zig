//! A font file's bytes, without copying them when the platform can map.
//!
//! Why this exists: a CJK collection is ~20 MB, and a window that shapes one
//! hanzi needs a few hundred kilobytes of it. `readFileAlloc` therefore charged
//! the whole file to the process's private pages; a read-only view charges only
//! the pages the parser (and DirectWrite, which borrows the same bytes) touch —
//! measured at 74.8 → 55.6 MiB of working set for the real window in `PERF.md`
//! §11, with the 19.7 MB `msyh.ttc` itself costing ~0.5 MiB resident.
//!
//! The mapping is released with `freeBytes`; on platforms without a mapping the
//! caller reads the file and gets the same `Bytes` with `mapped = false`.
const std = @import("std");
const builtin = @import("builtin");

/// A face's bytes, and whether they are a read-only file mapping rather than a
/// heap copy.
pub const Bytes = struct { data: []u8, mapped: bool = false };

const invalid_handle: usize = ~@as(usize, 0);

extern "kernel32" fn CreateFileW(path: [*]const u16, access: u32, share: u32, sec: ?*anyopaque, disposition: u32, flags: u32, template: ?*anyopaque) callconv(.winapi) usize;
extern "kernel32" fn CreateFileMappingW(file: usize, sec: ?*anyopaque, protect: u32, high: u32, low: u32, name: ?*const u16) callconv(.winapi) usize;
extern "kernel32" fn MapViewOfFile(mapping: usize, access: u32, high: u32, low: u32, bytes: usize) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn UnmapViewOfFile(addr: ?*const anyopaque) callconv(.winapi) i32;
extern "kernel32" fn GetFileSizeEx(file: usize, size: *i64) callconv(.winapi) i32;
extern "kernel32" fn CloseHandle(handle: usize) callconv(.winapi) i32;

/// A read-only mapping of `path`, or null when this platform (or this path)
/// cannot be mapped — the caller then reads the file.
pub fn mapFile(path: []const u8) ?Bytes {
    if (builtin.os.tag != .windows or path.len == 0 or path.len > 1000) return null;
    var wide: [1001]u16 = undefined;
    const len = std.unicode.utf8ToUtf16Le(wide[0..path.len], path) catch return null;
    wide[len] = 0;
    // GENERIC_READ, share read|delete, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL.
    const file = CreateFileW(&wide, 0x80000000, 0x1 | 0x4, null, 3, 0x80, null);
    if (file == invalid_handle) return null;
    defer _ = CloseHandle(file);
    var size: i64 = 0;
    if (GetFileSizeEx(file, &size) == 0 or size <= 0) return null;
    const mapping = CreateFileMappingW(file, null, 2, 0, 0, null); // PAGE_READONLY
    if (mapping == 0) return null;
    const view = MapViewOfFile(mapping, 4, 0, 0, 0) orelse { // FILE_MAP_READ
        _ = CloseHandle(mapping);
        return null;
    };
    // The view keeps both alive; the handles go now so nothing leaks one (a
    // mapped file still can't be deleted until it is unmapped).
    _ = CloseHandle(mapping);
    const bytes: [*]u8 = @ptrCast(view);
    return .{ .data = bytes[0..@intCast(size)], .mapped = true };
}

/// Releases a face's bytes: an unmap for a mapping, a free for a copy. The
/// unmap is inside a compile-time platform test, so a Linux or Android build
/// never references kernel32 (the fork this came from was Windows-only).
pub fn freeBytes(gpa: std.mem.Allocator, bytes: Bytes) void {
    if (builtin.os.tag == .windows) {
        if (bytes.mapped) {
            _ = UnmapViewOfFile(bytes.data.ptr);
            return;
        }
    }
    gpa.free(bytes.data);
}

const testing = std.testing;

test "mapping a file gives its bytes; a missing path gives null" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const text = "not a font, only bytes";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "plain.ttf", .data = text });
    var dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buffer);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}{c}plain.ttf", .{ dir_buffer[0..dir_len], std.fs.path.sep });
    const bytes = mapFile(path) orelse {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        return error.MappingFailed;
    };
    defer freeBytes(testing.allocator, bytes);
    try testing.expectEqualStrings(text, bytes.data);
    try testing.expect(bytes.mapped);
    try testing.expect(mapFile("no such file anywhere.ttf") == null);
}
