//! 读整个文件：音频 provider 没有 `std.Io` 参数（`preview.Provider.open` 的契约
//! 只有 allocator + Request），所以这里走手写 `CreateFileW`/`ReadFile`，不引入
//! 第三个"文件口岸"，也不改预览契约。
//!
//! 只给音频用：路径 → UTF-16（`wtf8ToWtf16LeAllocZ`）→ 打开 → 一次读进调用方给的
//! allocator。上限 `max_file_bytes` 防止把 4 GB 的 wav 整个搬进内存；超限是明确的
//! `FileTooLarge`，由 provider 记成 `none.failed`（不是崩溃，也不是"没有预览组件"）。
//!
//! 错误映射：文件不存在与没有权限分开，provider 才能把前者落到
//! `none.file_missing`、后者落到 `none.failed`。

const std = @import("std");
const win = @import("win32.zig");

/// 单个音频文件的上限。M1 的试听是"整段解码进内存"，没有流式；512 MiB 已经
/// 能装下约 25 分钟 44.1 kHz/16-bit 立体声，再大就该走流式（M2+）。
pub const max_file_bytes: u64 = 512 * 1024 * 1024;

pub const Error = error{
    OutOfMemory,
    InvalidPath,
    FileNotFound,
    AccessDenied,
    IoFailure,
    FileTooLarge,
};

/// 读取整个文件；返回的字节归调用方，用同一个 allocator 释放。
pub fn readAll(allocator: std.mem.Allocator, path: []const u8) Error![]u8 {
    if (!win.supported) return error.IoFailure;
    if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;

    const wide = std.unicode.wtf8ToWtf16LeAllocZ(allocator, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidWtf8 => return error.InvalidPath,
    };
    defer allocator.free(wide);

    const handle = win.CreateFileW(
        wide.ptr,
        win.GENERIC_READ,
        win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE,
        null,
        win.OPEN_EXISTING,
        win.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (handle == win.INVALID_HANDLE_VALUE) return openError(win.GetLastError());
    defer _ = win.CloseHandle(handle);

    var size: i64 = 0;
    if (win.GetFileSizeEx(handle, &size) == 0) return error.IoFailure;
    if (size < 0) return error.IoFailure;
    const total: u64 = @intCast(size);
    if (total > max_file_bytes) return error.FileTooLarge;

    const bytes = try allocator.alloc(u8, @intCast(total));
    errdefer allocator.free(bytes);

    var read_total: usize = 0;
    while (read_total < bytes.len) {
        // ReadFile 的计数是 DWORD；分块循环对未来的大文件也成立（当前上限 < 4 GiB，
        // 一次就够，但这里不写死这个假设）。
        const want: u32 = @intCast(@min(bytes.len - read_total, @as(usize, std.math.maxInt(u32))));
        var got: u32 = 0;
        const buffer: [*]u8 = bytes.ptr + read_total;
        if (win.ReadFile(handle, buffer, want, &got, null) == 0) return error.IoFailure;
        if (got == 0) return error.IoFailure;
        read_total += got;
    }
    return bytes;
}

fn openError(code: u32) Error {
    return switch (code) {
        2 => error.FileNotFound, // ERROR_FILE_NOT_FOUND
        3 => error.FileNotFound, // ERROR_PATH_NOT_FOUND
        5 => error.AccessDenied, // ERROR_ACCESS_DENIED
        32 => error.IoFailure, // ERROR_SHARING_VIOLATION
        else => error.IoFailure,
    };
}
