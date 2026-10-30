//! helper 与客户端共用的管道读写：标准句柄、`ReadFile` / `WriteFile` 的循环封装。
//!
//! 只有两件事：把「一次调用可能只搬一部分字节」藏起来，以及把「对端没了」和
//! 「对端正常收尾」分开——调用方要据此判断是走崩溃恢复（Broken）还是安静退出（Eof）。
//! 不做缓冲、不做超时（超时是客户端看门狗的事，见 `thumb_host_win.zig`）。
//!
//! 本文件同时被 `thumb_host.zig`（客户端）和 `thumb_host_main.zig`（helper）引用。
//! 两边各自编译进自己的 exe，共享的只是这份 ABI 声明和循环逻辑。

const std = @import("std");

pub const Handle = *anyopaque;
pub const BOOL = i32;
pub const DWORD = u32;

/// `INVALID_HANDLE_VALUE` 是 `(HANDLE)-1`，不是 null。
pub const invalid_handle: Handle = @ptrFromInt(std.math.maxInt(usize));

/// `GetStdHandle` 的三个参数（DWORD 形式的 -10 / -11 / -12）。
pub const std_input_handle: DWORD = @bitCast(@as(i32, -10));
pub const std_output_handle: DWORD = @bitCast(@as(i32, -11));
pub const std_error_handle: DWORD = @bitCast(@as(i32, -12));

extern "kernel32" fn GetStdHandle(kind: DWORD) callconv(.winapi) ?Handle;
extern "kernel32" fn ReadFile(
    handle: Handle,
    buffer: [*]u8,
    to_read: DWORD,
    read: ?*DWORD,
    overlapped: ?*anyopaque,
) callconv(.winapi) BOOL;
extern "kernel32" fn WriteFile(
    handle: Handle,
    buffer: [*]const u8,
    to_write: DWORD,
    written: ?*DWORD,
    overlapped: ?*anyopaque,
) callconv(.winapi) BOOL;
extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;

/// 一次 `ReadFile` / `WriteFile` 最多搬多少字节。分块只是为了让计数落在 DWORD 里，
/// 也顺便给被杀的 helper 一个在块边界上被发现的窗口。
const max_chunk: usize = 1024 * 1024;

/// 管道读写只有两种失败，语义完全不同：
///   * `Eof`    —— 对端正常关闭了写端（helper 收工 / 父进程收工），不是错误；
///   * `Broken` —— 对端没了或管道坏了，客户端要按"崩溃"处理并重启。
pub const IoError = error{ Eof, Broken };

/// 取标准句柄；没有（GUI 进程、句柄被关掉）时返回 null。
pub fn stdHandle(kind: DWORD) ?Handle {
    const handle = GetStdHandle(kind) orelse return null;
    if (handle == invalid_handle) return null;
    return handle;
}

/// 平台错误码，只用于诊断输出（`Broken` 之后打一行）。
pub fn lastError() DWORD {
    return GetLastError();
}

/// 读满 `buffer`。中途 EOF 返回 `error.Eof`，读失败返回 `error.Broken`。
pub fn readExact(handle: Handle, buffer: []u8) IoError!void {
    var offset: usize = 0;
    while (offset < buffer.len) {
        const want: DWORD = @intCast(@min(buffer.len - offset, max_chunk));
        var got: DWORD = 0;
        if (ReadFile(handle, buffer.ptr + offset, want, &got, null) == 0) return error.Broken;
        // 管道上 0 字节 = 写端已经关了：干净收尾，不是错误。
        if (got == 0) return error.Eof;
        offset += got;
    }
}

/// 写完 `bytes`。对端关掉读端（helper 被 TerminateProcess）时返回 `error.Broken`。
pub fn writeAll(handle: Handle, bytes: []const u8) IoError!void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const want: DWORD = @intCast(@min(bytes.len - offset, max_chunk));
        var written: DWORD = 0;
        if (WriteFile(handle, bytes.ptr + offset, want, &written, null) == 0) return error.Broken;
        if (written == 0) return error.Broken;
        offset += written;
    }
}
