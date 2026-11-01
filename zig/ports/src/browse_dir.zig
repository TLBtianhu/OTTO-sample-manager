//! 目录浏览口岸（Stage 0）：**不递归**地列出一个目录里的直接子项，外加单文件身份查询。
//!
//! 与 `scan.zig` 的分工：
//!   * `scan` 回答「这个目录树里有哪些素材」（递归、跳过隐藏/临时/超大、排序去重）；
//!   * 本文件回答「这个目录里现在有什么」（只一层、不过滤任何条目、不排序），
//!     并按需回答「这个文件的身份是什么」。浏览模式要的是后者：用户看到的东西
//!     必须和资源管理器一致，任何"我们觉得不重要"的过滤都是静默丢条目。
//!
//! 边界（CHARTER「八、零转义的边界」）：
//!   * 只 import 标准库；不 import `otto_core`（身份在这里是同形的 `Identity`，
//!     app 侧转换一次）；
//!   * Win32 全部手写 `extern "kernel32"`：没有 @cImport、没有 C shim；
//!   * 不打开文件内容，只读目录项与句柄元数据。
//!
//! 为什么用 `FindFirstFileExW` 而不是 `std.Io.Dir.iterate`：`FindExInfoBasic` 不给
//! 8.3 短名（每个条目少一次名字解析），`FIND_FIRST_EX_LARGE_FETCH` 让内核一次返回
//! 更多条目——10 万条目的目录上这两项合起来是数量级的差别，而浏览模式的第一屏
//! 预算只有 100 ms。std 的迭代器没有这两个开关。
//!
//! 错误策略：目录打不开（不存在 / 没权限 / 不是目录）在 `open` 就是具名错误；
//! 枚举中途的单条失败记进 `Iterator.skipped` 并继续，只有 `FindNextFileW` 真的
//! 失败才结束这一趟（调用方决定是"截断"还是"路径不可用"）。

const std = @import("std");
const builtin = @import("builtin");

pub const supported = builtin.os.tag == .windows;

// ---------------------------------------------------------------------------
// 手写 Win32 声明
// ---------------------------------------------------------------------------

const HANDLE = *anyopaque;
const BOOL = i32;
const DWORD = u32;

const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(std.math.maxInt(usize));
const FILE_SHARE_READ_WRITE_DELETE: DWORD = 0x7;
const OPEN_EXISTING: DWORD = 3;
const FILE_FLAG_BACKUP_SEMANTICS: DWORD = 0x0200_0000;

/// `FILE_ATTRIBUTE_DIRECTORY`：条目是目录（浏览模式只列文件，所以调用方要跳过它）。
pub const FILE_ATTRIBUTE_DIRECTORY: DWORD = 0x0000_0010;
const FILE_ATTRIBUTE_REPARSE_POINT: DWORD = 0x0000_0400;

/// `FINDEX_INFO_LEVELS`：FindExInfoBasic = 1（不给 8.3 短名）。
const FindExInfoBasic: DWORD = 1;
/// `FIND_FIRST_EX_LARGE_FETCH`：一次内核往返拿更多条目。
const FIND_FIRST_EX_LARGE_FETCH: DWORD = 0x0000_0002;
const ERROR_NO_MORE_FILES: DWORD = 18;

const FILETIME = extern struct {
    low: DWORD,
    high: DWORD,
};

/// `WIN32_FIND_DATAW`（Win64）。只读前五个字段与文件名；短名字段留着占位。
const WIN32_FIND_DATAW = extern struct {
    file_attributes: DWORD,
    creation_time: FILETIME,
    last_access_time: FILETIME,
    last_write_time: FILETIME,
    file_size_high: DWORD,
    file_size_low: DWORD,
    reserved0: DWORD,
    reserved1: DWORD,
    file_name: [260]u16,
    alternate_file_name: [14]u16,
};

/// `BY_HANDLE_FILE_INFORMATION`：身份查询只需要卷序列号与文件索引。
const BY_HANDLE_FILE_INFORMATION = extern struct {
    file_attributes: DWORD,
    creation_time: FILETIME,
    last_access_time: FILETIME,
    last_write_time: FILETIME,
    volume_serial_number: DWORD,
    file_size_high: DWORD,
    file_size_low: DWORD,
    number_of_links: DWORD,
    file_index_high: DWORD,
    file_index_low: DWORD,
};

extern "kernel32" fn FindFirstFileExW(
    file_name: [*:0]const u16,
    info_level: DWORD,
    find_data: *WIN32_FIND_DATAW,
    search_op: DWORD,
    search_filter: ?*anyopaque,
    additional_flags: DWORD,
) callconv(.winapi) HANDLE;
extern "kernel32" fn FindNextFileW(handle: HANDLE, find_data: *WIN32_FIND_DATAW) callconv(.winapi) BOOL;
extern "kernel32" fn FindClose(handle: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn GetFileInformationByHandle(
    file: HANDLE,
    information: *BY_HANDLE_FILE_INFORMATION,
) callconv(.winapi) BOOL;
extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
extern "kernel32" fn CreateFileW(
    file_name: [*:0]const u16,
    desired_access: DWORD,
    share_mode: DWORD,
    security_attributes: ?*anyopaque,
    creation_disposition: DWORD,
    flags_and_attributes: DWORD,
    template_file: ?HANDLE,
) callconv(.winapi) HANDLE;
extern "kernel32" fn CloseHandle(object: HANDLE) callconv(.winapi) BOOL;

comptime {
    // 布局是契约：Windows SDK 在 Win64 上就是 592 字节（含 260 个 WCHAR 的文件名）。
    // 改错一个字段，FindFirstFileExW 会把数据写到栈上别的地方。
    if (@sizeOf(WIN32_FIND_DATAW) != 592) @compileError("WIN32_FIND_DATAW 布局不对");
}

/// 文件身份：卷序列号 + 文件索引。字段与 `core.model.FileIdentity` 一一对应。
///
/// 口岸不 import core（见文件头），所以这里独立定义；app 在生成 Sample 时转换。
pub const Identity = struct {
    volume_serial: u32,
    file_index: u64,

    pub fn eql(a: Identity, b: Identity) bool {
        return a.volume_serial == b.volume_serial and a.file_index == b.file_index;
    }
};

/// 一条目录项。`name` 指向 `Iterator` 的内部缓冲，**只在下次 `next` 之前有效**。
pub const Entry = struct {
    /// 文件名（不含目录），WTF-8。合法名字即 UTF-8。
    name: []const u8,
    attributes: DWORD,
    size: u64,
    /// 修改时间（Unix 毫秒）；读不到时 0。
    mtime: i64,

    pub fn isDirectory(self: Entry) bool {
        return self.attributes & FILE_ATTRIBUTE_DIRECTORY != 0;
    }

    /// 符号链接 / junction：浏览模式把它当普通条目列出来，但不跟随。
    pub fn isReparsePoint(self: Entry) bool {
        return self.attributes & FILE_ATTRIBUTE_REPARSE_POINT != 0;
    }
};

/// `open` 可能失败的原因：每一条都能直接告诉用户"为什么这个目录打不开"。
pub const OpenError = error{
    Unsupported,
    OutOfMemory,
    /// 路径不是目录（给了文件 / 盘符不存在）。
    NotDirectory,
    /// 目录不存在。
    PathNotFound,
    /// 没有列出目录的权限。
    AccessDenied,
    InvalidPath,
    Unexpected,
};

/// 枚举过程中的失败。只有 `FindNextFileW` 的硬失败会到这里；单条坏名字记 `skipped`。
pub const NextError = error{EnumerationFailed};

/// 目录迭代器。**不排序**：顺序由文件系统决定（NTFS 上按名字的索引顺序）。
pub const Iterator = struct {
    allocator: std.mem.Allocator,
    /// `<dir>\*` 的宽字符形式（含 `\\?\` 长路径前缀），以 0 结尾。
    pattern: [:0]u16,
    handle: HANDLE,
    data: WIN32_FIND_DATAW = undefined,
    /// 第一条来自 `FindFirstFileExW`，后面的来自 `FindNextFileW`。
    first: bool = true,
    /// 认不出 / 装不下的名字条数（不静默：调用方把它加进"跳过"计数）。
    skipped: u32 = 0,
    /// UTF-8 名字缓冲：一条 255 个 UTF-16 单元的名字最多 765 个 WTF-8 字节。
    name_buffer: [1024]u8 = undefined,

    /// 打开目录并读第一条。空目录也会成功（`*` 至少匹配 `.`）。
    pub fn open(allocator: std.mem.Allocator, directory: []const u8) OpenError!Iterator {
        if (!supported) return error.Unsupported;

        const pattern = try widePattern(allocator, directory);
        errdefer allocator.free(pattern);

        var data: WIN32_FIND_DATAW = undefined;
        const handle = FindFirstFileExW(
            pattern.ptr,
            FindExInfoBasic,
            &data,
            // fSearchOp：FindExSearchNameMatch = 0（通配符匹配）。
            0,
            null,
            // dwAdditionalFlags：一次内核往返多拿条目（必须配 FindExInfoBasic）。
            FIND_FIRST_EX_LARGE_FETCH,
        );
        if (handle == INVALID_HANDLE_VALUE) return mapOpenError(GetLastError());

        return .{
            .allocator = allocator,
            .pattern = pattern,
            .handle = handle,
            .data = data,
        };
    }

    /// 关句柄并释放模式串。幂等：重复调用是空操作（`handle` 同时是"还开着吗"的标志）。
    pub fn close(self: *Iterator) void {
        if (self.handle == INVALID_HANDLE_VALUE) return;
        _ = FindClose(self.handle);
        self.handle = INVALID_HANDLE_VALUE;
        self.allocator.free(self.pattern);
    }

    /// 下一条。调用方必须当场决定要不要拷走 `name`。
    pub fn next(self: *Iterator) NextError!?Entry {
        while (true) {
            if (self.first) {
                self.first = false;
            } else if (FindNextFileW(self.handle, &self.data) == 0) {
                const code = GetLastError();
                if (code == ERROR_NO_MORE_FILES) return null;
                return error.EnumerationFailed;
            }

            const wide = nameOf(&self.data);
            // `.` / `..` 是每条目录都有的两个伪条目，不是文件。
            if (isDot(wide)) continue;

            const needed = std.unicode.calcWtf8Len(wide);
            if (needed > self.name_buffer.len) {
                self.skipped += 1;
                continue;
            }
            const written = std.unicode.wtf16LeToWtf8(&self.name_buffer, wide);
            return .{
                .name = self.name_buffer[0..written],
                .attributes = self.data.file_attributes,
                .size = (@as(u64, self.data.file_size_high) << 32) | self.data.file_size_low,
                .mtime = fileTimeToUnixMs(self.data.last_write_time),
            };
        }
    }
};

/// 单文件身份：打开句柄问一次 `GetFileInformationByHandle`。
///
/// 只在**需要时**调用（浏览模式只为选中的那一行取身份）：每条一次 `CreateFileW`
/// 在本地盘是 ~10 µs，但 10 万条目录上就是 1 秒，而 99.99% 的行从不被选中。
/// 文件系统不提供稳定 File ID 时返回 null（FAT / 网络盘），调用方退回路径键。
pub fn identityOf(io: std.Io, path: []const u8) !?Identity {
    if (!supported) return error.Unsupported;
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
    if (stat.kind == .directory) return identityOfDirectory(path);
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch |err| return err;
    defer file.close(io);
    return identityFromHandle(file.handle);
}

fn identityOfDirectory(path: []const u8) !?Identity {
    const wide = try std.unicode.wtf8ToWtf16LeAllocZ(std.heap.page_allocator, path);
    defer std.heap.page_allocator.free(wide);
    const handle = CreateFileW(wide.ptr, 0, FILE_SHARE_READ_WRITE_DELETE, null, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, null);
    if (handle == INVALID_HANDLE_VALUE) return error.AccessDenied;
    defer _ = CloseHandle(handle);
    return identityFromHandle(handle);
}

fn identityFromHandle(handle: HANDLE) ?Identity {
    var information: BY_HANDLE_FILE_INFORMATION = undefined;
    if (GetFileInformationByHandle(handle, &information) == 0) return null;
    if (information.file_index_high == 0 and information.file_index_low == 0) return null;
    return .{
        .volume_serial = information.volume_serial_number,
        .file_index = (@as(u64, information.file_index_high) << 32) | information.file_index_low,
    };
}

// ---------------------------------------------------------------------------
// 路径与时间
// ---------------------------------------------------------------------------

/// `<directory>\*` → 以 0 结尾的 UTF-16，带 `\\?\` 长路径前缀。
///
/// 前缀规则与 `scan.widePath` 一致（这里不能复用它：两个文件属于两个模块）。
fn widePattern(allocator: std.mem.Allocator, directory: []const u8) OpenError![:0]u16 {
    if (directory.len == 0) return error.InvalidPath;

    const prefixed = if (isSep(directory[0]) and directory.len >= 2 and isSep(directory[1]))
        try std.fmt.allocPrint(allocator, "\\\\?\\UNC\\{s}\\*", .{directory[2..]})
    else if (directory.len >= 3 and std.ascii.isAlphabetic(directory[0]) and directory[1] == ':' and isSep(directory[2]))
        try std.fmt.allocPrint(allocator, "\\\\?\\{s}\\*", .{directory})
    else if (directory.len >= 4 and isSep(directory[0]) and isSep(directory[1]) and
        (directory[2] == '?' or directory[2] == '.') and isSep(directory[3]))
        try std.fmt.allocPrint(allocator, "{s}\\*", .{directory})
    else
        try std.fmt.allocPrint(allocator, "{s}\\*", .{directory});
    defer allocator.free(prefixed);

    return std.unicode.wtf8ToWtf16LeAllocZ(allocator, prefixed) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidWtf8 => error.InvalidPath,
    };
}

fn isSep(ch: u8) bool {
    return ch == '\\' or ch == '/';
}

fn nameOf(data: *const WIN32_FIND_DATAW) []const u16 {
    var end: usize = 0;
    while (end < data.file_name.len and data.file_name[end] != 0) end += 1;
    return data.file_name[0..end];
}

fn isDot(name: []const u16) bool {
    if (name.len == 1 and name[0] == '.') return true;
    return name.len == 2 and name[0] == '.' and name[1] == '.';
}

fn mapOpenError(code: DWORD) OpenError {
    return switch (code) {
        2, 3 => error.PathNotFound, // ERROR_FILE_NOT_FOUND / ERROR_PATH_NOT_FOUND
        5 => error.AccessDenied, // ERROR_ACCESS_DENIED
        267 => error.NotDirectory, // ERROR_DIRECTORY
        123, 161 => error.InvalidPath, // ERROR_INVALID_NAME / ERROR_BAD_PATHNAME
        else => error.Unexpected,
    };
}

/// FILETIME（1601-01-01 起的 100ns）→ Unix 毫秒。早于 1970 的值按 0 处理。
fn fileTimeToUnixMs(time: FILETIME) i64 {
    const ticks: u64 = (@as(u64, time.high) << 32) | time.low;
    const epoch_offset: u64 = 116_444_736_000_000_000;
    if (ticks <= epoch_offset) return 0;
    return @intCast((ticks - epoch_offset) / 10_000);
}
