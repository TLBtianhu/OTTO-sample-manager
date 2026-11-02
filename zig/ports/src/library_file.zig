//! OTTO 库文件口岸：把一段字节**原子地**写成库文件，或整段读回来。
//!
//! 边界的划法（CHARTER「八、零转义的边界」 + 硬约束「核心不碰 I/O」）：
//!   * 本文件只做 OS 文件操作：同目录 `.tmp` → `FlushFileBuffers`（`File.sync`）→
//!     `MoveFileExW(MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)`；
//!   * 容器格式（`OTTOLIB` magic / version / 计数 / CRC32 / 字段）在
//!     `core/src/library_binary.zig`。那是**序列化**，不需要句柄；这里不 import
//!     core，也不认识 `Library`——口岸只收发 `[]const u8`，不会把模型类型拖进
//!     平台层，更不会制造两份 `otto_core` 实例的类型冲突；
//!   * Win32 声明全部手写 `extern "kernel32"`：没有 @cImport、没有 C shim。
//!
//! ## 为什么是"同目录临时文件 + MoveFileExW"
//!
//! 直接截断目标再写，进程在两次写之间崩溃会留下半个库；`MoveFileExW` 在同一卷内
//! 是一次目录项替换，要么看到旧文件、要么看到新文件。要求的三步缺一不可：
//!
//!   1. 临时文件与目标**同目录**（跨目录/跨卷时 MoveFileEx 会退化成复制，不再原子）；
//!   2. 写完后 `File.sync(io)`，让内容先落到磁盘（否则替换成功也可能有个空文件
//!      在断电后出现）；
//!   3. `MOVEFILE_WRITE_THROUGH`，让替换这个目录操作也同步。
//!
//! 任何一步失败都会关句柄并删掉临时文件；错误用 `ReadOnly` / `AccessDenied` /
//! `SharingViolation` / `NoSpaceLeft` 等具名值交出去，不把"目标只读"说成泛泛的
//! `FileWrite`。目标只读时 Windows 的替换会返回 `ERROR_ACCESS_DENIED`，本文件
//! 再用 `GetFileAttributesW` 确认只读位，返回 `error.ReadOnly`。
//!
//! ## 读
//!
//! `readAll` 是带硬上限的整读：超过 `limit` 返回 `FileTooLarge`，不先信任文件
//! 大小、也不做无界分配。格式校验（magic / 版本 / 截断 / CRC）由 core 的
//! `library_binary.decode` 负责，这样 CLI 的 `--library-info` 能拿到
//! `BadMagic` / `UnknownVersion` / `Truncated` / `ChecksumMismatch` 这些具名错误。

const std = @import("std");
const builtin = @import("builtin");

pub const supported = builtin.os.tag == .windows;

/// 临时文件后缀。固定用 `<目标>.tmp`：崩溃留下的残骸下次会被 `CREATE_ALWAYS`
/// 覆盖，不需要扫描目录；同一目标本来也不该有并发写者。
pub const tmp_suffix = ".tmp";

pub const Error = error{
    OutOfMemory,
    /// 非 Windows 平台，本口岸不上场。
    Unsupported,
    /// 路径为空 / 不是合法 WTF-8 / 含 Windows 不接受的字符。
    InvalidPath,
    FileNotFound,
    /// 权限不足；具体 Win32 码见 `lastError()`。
    AccessDenied,
    /// 目标文件带只读属性，`MoveFileExW` 拒绝替换。
    ReadOnly,
    /// 目标被其他进程占用。
    SharingViolation,
    NoSpaceLeft,
    /// 读取超过调用方给的上限。
    FileTooLarge,
    /// 读失败（目录、设备错误等）。
    FileRead,
    /// 写临时文件 / 替换目标失败。
    FileWrite,
};

// ---------------------------------------------------------------------------
// 手写 Win32 声明（只用到替换与属性查询）
// ---------------------------------------------------------------------------

const BOOL = i32;
const DWORD = u32;
const HANDLE = *anyopaque;
const INVALID_FILE_ATTRIBUTES: DWORD = 0xFFFF_FFFF;

const MOVEFILE_REPLACE_EXISTING: DWORD = 0x0000_0001;
const MOVEFILE_WRITE_THROUGH: DWORD = 0x0000_0008;

const FILE_ATTRIBUTE_READONLY: DWORD = 0x0000_0001;
const FILE_ATTRIBUTE_DIRECTORY: DWORD = 0x0000_0010;

const ERROR_FILE_NOT_FOUND: DWORD = 2;
const ERROR_PATH_NOT_FOUND: DWORD = 3;
const ERROR_ACCESS_DENIED: DWORD = 5;
const ERROR_NOT_SAME_DEVICE: DWORD = 17;
const ERROR_WRITE_PROTECT: DWORD = 19;
const ERROR_SHARING_VIOLATION: DWORD = 32;
const ERROR_DISK_FULL: DWORD = 112;
const ERROR_HANDLE_DISK_FULL: DWORD = 39;
const ERROR_INVALID_NAME: DWORD = 123;
const ERROR_BAD_PATHNAME: DWORD = 161;
const ERROR_DIRECTORY: DWORD = 267;

/// 当前线程最近一次 Win32 调用的错误码（0 = 没有失败）。只用于日志/排障。
threadlocal var last_win32_error: DWORD = 0;

pub fn lastError() u32 {
    return last_win32_error;
}

extern "kernel32" fn MoveFileExW(
    existing_file_name: [*:0]const u16,
    new_file_name: [*:0]const u16,
    flags: DWORD,
) callconv(.winapi) BOOL;

extern "kernel32" fn DeleteFileW(file_name: [*:0]const u16) callconv(.winapi) BOOL;

extern "kernel32" fn GetFileAttributesW(file_name: [*:0]const u16) callconv(.winapi) DWORD;

extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;

// ---------------------------------------------------------------------------
// 公共 API
// ---------------------------------------------------------------------------

/// 整读文件。`limit` 是硬上限（字节），超了返回 `FileTooLarge`。
/// 返回的切片归调用方，用同一个 allocator 释放。
pub fn readAll(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    limit: usize,
) Error![]u8 {
    if (path.len == 0) return error.InvalidPath;
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(limit)) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.StreamTooLong => error.FileTooLarge,
        error.FileNotFound => error.FileNotFound,
        error.AccessDenied, error.PermissionDenied, error.ReadOnlyFileSystem => error.AccessDenied,
        error.NameTooLong, error.BadPathName => error.InvalidPath,
        error.IsDir, error.NotDir => error.FileRead,
        else => error.FileRead,
    };
}

/// 原子写：写 `<path>.tmp` → sync → `MoveFileExW` 替换 `<path>`。
///
/// 目标是只读文件时返回 `error.ReadOnly`；任何失败都会尽量删掉临时文件
/// （删除也失败时原始错误仍然优先，残骸最多是一个 `.tmp`，不会污染目标）。
pub fn writeAtomic(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    bytes: []const u8,
) Error!void {
    if (path.len == 0) return error.InvalidPath;
    if (!supported) return error.Unsupported;

    // 目标路径是目录时，`<path>.tmp` 可能写得进去但替换必失败；提前说清楚。
    if (try isDirectory(allocator, path)) return error.InvalidPath;

    const tmp_path = std.fmt.allocPrint(allocator, "{s}{s}", .{ path, tmp_suffix }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer allocator.free(tmp_path);

    var file = std.Io.Dir.cwd().createFile(io, tmp_path, .{ .truncate = true }) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied, error.ReadOnlyFileSystem => return error.AccessDenied,
        error.NoSpaceLeft => return error.NoSpaceLeft,
        error.NameTooLong, error.BadPathName => return error.InvalidPath,
        error.FileNotFound, error.NotDir => return error.FileNotFound,
        error.FileBusy, error.DeviceBusy => return error.SharingViolation,
        else => return error.FileWrite,
    };

    var file_open = true;
    errdefer if (file_open) file.close(io);
    var tmp_present = true;
    errdefer if (tmp_present) deleteQuiet(allocator, tmp_path);

    file.writeStreamingAll(io, bytes) catch |err| switch (err) {
        error.NoSpaceLeft, error.DiskQuota => return error.NoSpaceLeft,
        error.AccessDenied, error.PermissionDenied => return error.AccessDenied,
        else => return error.FileWrite,
    };
    file.sync(io) catch |err| switch (err) {
        error.NoSpaceLeft, error.DiskQuota => return error.NoSpaceLeft,
        error.AccessDenied => return error.AccessDenied,
        else => return error.FileWrite,
    };
    file.close(io);
    file_open = false;

    const wide_tmp = widePath(allocator, tmp_path) catch |err| return err;
    defer allocator.free(wide_tmp);
    const wide_target = widePath(allocator, path) catch |err| return err;
    defer allocator.free(wide_target);

    if (MoveFileExW(wide_tmp.ptr, wide_target.ptr, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != 0) {
        tmp_present = false;
        return;
    }

    const code = GetLastError();
    last_win32_error = code;
    deleteQuiet(allocator, tmp_path);
    tmp_present = false;
    return switch (code) {
        ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND => error.FileNotFound,
        ERROR_SHARING_VIOLATION => error.SharingViolation,
        ERROR_DISK_FULL, ERROR_HANDLE_DISK_FULL => error.NoSpaceLeft,
        ERROR_WRITE_PROTECT => error.ReadOnly,
        ERROR_ACCESS_DENIED => if (try isReadOnly(allocator, path)) error.ReadOnly else error.AccessDenied,
        ERROR_NOT_SAME_DEVICE, ERROR_DIRECTORY, ERROR_INVALID_NAME, ERROR_BAD_PATHNAME => error.FileWrite,
        else => error.FileWrite,
    };
}

fn widePath(allocator: std.mem.Allocator, path: []const u8) Error![:0]u16 {
    return std.unicode.wtf8ToWtf16LeAllocZ(allocator, path) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidWtf8 => error.InvalidPath,
    };
}

fn deleteQuiet(allocator: std.mem.Allocator, path: []const u8) void {
    const wide = widePath(allocator, path) catch return;
    defer allocator.free(wide);
    _ = DeleteFileW(wide.ptr);
}

fn isReadOnly(allocator: std.mem.Allocator, path: []const u8) Error!bool {
    const wide = try widePath(allocator, path);
    defer allocator.free(wide);
    const attributes = GetFileAttributesW(wide.ptr);
    if (attributes == INVALID_FILE_ATTRIBUTES) return false;
    return attributes & FILE_ATTRIBUTE_READONLY != 0;
}

fn isDirectory(allocator: std.mem.Allocator, path: []const u8) Error!bool {
    const wide = try widePath(allocator, path);
    defer allocator.free(wide);
    const attributes = GetFileAttributesW(wide.ptr);
    if (attributes == INVALID_FILE_ATTRIBUTES) return false;
    return attributes & FILE_ATTRIBUTE_DIRECTORY != 0;
}
