//! 音频文件的 Win32 读入口：预览 provider 没有 `std.Io` 参数（`preview.Provider.open`
//! 的契约只有 allocator + Request），所以这里走手写 `CreateFileW`/`ReadFile`，不引入
//! 第三个"文件口岸"，也不改预览契约。
//!
//! 两条路：
//!   * `Reader`（`openReader` + `readAt`）：音频图标的粗采样与 `audio/file_reader.zig`
//!     的 64 KiB 流式适配器用——打开一次、按偏移读，不搬整段文件。**这是现在所有
//!     整段解码的入口**（zig-audio 的 WAV/FLAC/MP3/AIFF 都走它）。
//!   * `readAll`：整份读进调用方 allocator 的通用入口（上限 `max_file_bytes`），
//!     当前生产路径没有调用方；保留给需要完整字节的探针/测试。
//!
//! 错误映射：文件不存在与没有权限分开，provider 才能把前者落到
//! `none.file_missing`、后者落到 `none.failed`。

const std = @import("std");
const win = @import("win32.zig");

/// 整段 PCM / 整文件读取的上限。512 MiB 足够装下约 25 分钟 44.1 kHz/16-bit
/// 立体声的**解码后 PCM**（常驻内存的大头）；`readAll` 也用它挡住 4 GB 文件。
/// 流式 Reader 不按文件大小分配，只保留 64 KiB。
pub const max_file_bytes: u64 = 512 * 1024 * 1024;

pub const Error = error{
    OutOfMemory,
    InvalidPath,
    FileNotFound,
    AccessDenied,
    IoFailure,
    FileTooLarge,
    Truncated,
};

/// 随机读取器：给音频图标的粗采样用。打开一次、按偏移读几帧，**不**把整段音频
/// 搬进内存。句柄由调用方 `deinit`。
pub const Reader = struct {
    handle: win.HANDLE,
    size: u64,

    pub fn deinit(self: *Reader) void {
        _ = win.CloseHandle(self.handle);
        self.* = undefined;
    }

    /// 从 `offset` 读满 `buffer`。越界（文件比请求短）返回 `error.Truncated`，
    /// 不返回半截数据——调用方要么整块可用，要么按失败处理。
    pub fn readAt(self: *Reader, offset: u64, buffer: []u8) Error!void {
        if (offset > self.size) return error.Truncated;
        const available = self.size - offset;
        if (buffer.len > available) return error.Truncated;
        if (buffer.len == 0) return;

        if (win.SetFilePointerEx(self.handle, @intCast(offset), null, win.FILE_BEGIN) == 0) {
            return error.IoFailure;
        }
        var total: usize = 0;
        while (total < buffer.len) {
            const want: u32 = @intCast(@min(buffer.len - total, @as(usize, std.math.maxInt(u32))));
            var got: u32 = 0;
            if (win.ReadFile(self.handle, buffer.ptr + total, want, &got, null) == 0) {
                return error.IoFailure;
            }
            if (got == 0) return error.IoFailure;
            total += got;
        }
    }
};

/// 打开一个随机读取器。路径转换与错误映射与 `readAll` 相同。
pub fn openReader(allocator: std.mem.Allocator, path: []const u8) Error!Reader {
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

    var size: i64 = 0;
    if (win.GetFileSizeEx(handle, &size) == 0) {
        _ = win.CloseHandle(handle);
        return error.IoFailure;
    }
    if (size < 0) {
        _ = win.CloseHandle(handle);
        return error.IoFailure;
    }
    return .{ .handle = handle, .size = @intCast(size) };
}

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
