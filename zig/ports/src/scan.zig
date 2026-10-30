//! 文件系统扫描口岸（L0）：递归遍历一个目录，产出**目录项事实**。
//!
//! 这一层只回答"磁盘上有什么"：绝对路径、文件名、扩展名、大小、mtime、文件身份。
//! **不打开内容、不解析、不建 Sample**——L1 元数据在 `probe.zig`，入库在 app 层。
//!
//! 边界（CHARTER「八、零转义的边界」）：
//!   * 本文件只 import 标准库；不 import `otto_core`，所以文件身份在口岸里是同形的
//!     `Identity`（`core.model.FileIdentity` 的字段一一对应），由 app 侧转换一次；
//!   * Win32 声明全部手写 `extern "kernel32"`：没有 @cImport、没有 C shim；
//!   * 遍历用 `std.Io.Dir.walkSelectively`（条目顺序未定义），本文件负责**排序 +
//!     去重**，让调用方看到稳定顺序。
//!
//! ## 错误策略
//!
//! 单个文件/目录失败**不中断整体**：打开失败、查询身份失败、目录枚举失败都记进
//! `failures`（带 `@errorName`），扫描继续。只有"根目录打不开"和内存不足会让
//! `run` 返回错误——这两种情况下继续扫描没有意义。
//!
//! ## 跳过规则
//!
//! * 隐藏 / 系统文件（含目录）默认跳过；`Options.keep_hidden = true` 可关掉；
//! * 扩展名 `.tmp`（大小写不敏感）跳过——那是原子写留下的临时文件；
//! * 超过 `Options.max_file_bytes` 的文件跳过（0 = 不限制）；
//! * 符号链接 / 设备等非普通文件不跟随、不产出事实（`skipped_other` 计数）。
//!
//! 不跟随符号链接是有意的：目录 junction 成环时，跟随会把扫描变成无限递归。

const std = @import("std");
const builtin = @import("builtin");

pub const supported = builtin.os.tag == .windows;

/// 默认的大小上限：256 MiB。再大的文件不像采样，扫进来也只会拖慢导入。
pub const default_max_file_bytes: u64 = 256 * 1024 * 1024;

// ---------------------------------------------------------------------------
// 手写 Win32 声明（只用到属性与身份查询）
// ---------------------------------------------------------------------------

const BOOL = i32;
const DWORD = u32;
const HANDLE = *anyopaque;

const FILE_ATTRIBUTE_HIDDEN: DWORD = 0x0000_0002;
const FILE_ATTRIBUTE_SYSTEM: DWORD = 0x0000_0004;
const INVALID_FILE_ATTRIBUTES: DWORD = 0xFFFF_FFFF;

/// FILETIME：自 1601-01-01 起的 100ns 计数。
const FILETIME = extern struct {
    low: DWORD,
    high: DWORD,
};

/// `BY_HANDLE_FILE_INFORMATION`：一次查询同时给属性、大小、mtime 和文件身份。
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

extern "kernel32" fn GetFileAttributesW(file_name: [*:0]const u16) callconv(.winapi) DWORD;

extern "kernel32" fn GetFileInformationByHandle(
    file: HANDLE,
    information: *BY_HANDLE_FILE_INFORMATION,
) callconv(.winapi) BOOL;

/// 文件身份：卷序列号 + 文件索引。字段与 `core.model.FileIdentity` 一一对应。
///
/// 口岸不 import core（见文件头），所以这里独立定义；app 在生成 Sample 时转换。
pub const Identity = struct {
    volume_serial: u32,
    file_index: u64,

    pub fn eql(a: Identity, b: Identity) bool {
        return a.volume_serial == b.volume_serial and a.file_index == b.file_index;
    }

    pub fn hash(self: Identity) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&self.volume_serial));
        hasher.update(std.mem.asBytes(&self.file_index));
        return hasher.final();
    }
};

/// 一条文件事实。所有切片归 `Scan` 的 arena 所有。
pub const FileFact = struct {
    /// 绝对路径（native 分隔符，原样保留磁盘上的大小写）。
    path: []const u8,
    /// 文件名，含扩展名。
    name: []const u8,
    /// 扩展名，含点；没有扩展名时为空串。
    ext: []const u8,
    size: u64,
    /// 修改时间（Unix 毫秒）；读不到时 0。
    mtime: i64,
    /// 卷序列号 + 文件索引；文件系统不提供时 null（调用方退回路径键）。
    identity: ?Identity,
};

/// 一条失败记录（路径 + 具名错误，不用字符串猜测原因）。
pub const Failure = struct {
    path: []const u8,
    err: []const u8,
};

pub const Counts = struct {
    /// 收进 `files` 的条数（排序去重之后）。
    files: usize = 0,
    failures: usize = 0,
    skipped_hidden: usize = 0,
    skipped_temp: usize = 0,
    skipped_size: usize = 0,
    /// 同一路径出现多次（排序后相邻去重）。
    duplicates: usize = 0,
    /// 非普通文件：符号链接、设备、管道……不产出事实。
    skipped_other: usize = 0,
};

pub const Options = struct {
    /// 单个文件的字节上限；0 = 不限制。
    max_file_bytes: u64 = default_max_file_bytes,
    /// 是否保留隐藏 / 系统文件（默认跳过）。
    keep_hidden: bool = false,
};

/// 遍历回调。文件按**排序去重后的顺序**逐条回调，失败条目也按收集顺序回调。
/// 回调里的指针只在 `run` 返回前有效；要留就自己拷贝。
pub const Visitor = struct {
    context: ?*anyopaque = null,
    on_file: *const fn (context: ?*anyopaque, fact: *const FileFact) void,
    on_failure: ?*const fn (context: ?*anyopaque, failure: *const Failure) void = null,
};

/// 一次扫描的结果。`deinit` 释放全部字符串与数组。
pub const Scan = struct {
    arena: std.heap.ArenaAllocator,
    root: []const u8,
    files: []const FileFact,
    failures: []const Failure,
    counts: Counts,

    pub fn deinit(self: *Scan) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Error = error{
    OutOfMemory,
    /// 非 Windows 平台，本口岸不上场。
    Unsupported,
} || std.Io.Dir.OpenError || std.Io.Dir.RealPathFileAllocError;

/// 递归扫描 `root_path`。`root_path` 可以是相对路径（内部 realpath 成绝对路径）。
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_path: []const u8,
    options: Options,
    visitor: ?Visitor,
) Error!Scan {
    if (!supported) return error.Unsupported;

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const scratch = arena.allocator();

    // 根路径先 canonicalize：库里存的是绝对路径，去重也按字节比较。
    const root = try std.Io.Dir.cwd().realPathFileAlloc(io, root_path, scratch);

    var root_dir = try std.Io.Dir.cwd().openDir(io, root, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer root_dir.close(io);

    var files: std.ArrayList(FileFact) = .empty;
    var failures: std.ArrayList(Failure) = .empty;
    var counts = Counts{};

    var walker = try root_dir.walkSelectively(scratch);
    defer walker.deinit();

    // 目录枚举失败时用来标注是哪个目录：进入子目录时更新。
    var current_dir: []const u8 = root;

    while (true) {
        const entry = walker.next(io) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            try recordFailure(scratch, &failures, &counts, current_dir, @errorName(err));
            continue;
        } orelse break;

        const path = try joinPath(scratch, root, entry.path);

        switch (entry.kind) {
            .directory => {
                if (!options.keep_hidden) {
                    const attributes = attributesOf(scratch, path) catch |err| {
                        try recordFailure(scratch, &failures, &counts, path, @errorName(err));
                        continue;
                    };
                    if (isHiddenOrSystem(attributes)) {
                        counts.skipped_hidden += 1;
                        continue;
                    }
                }
                walker.enter(io, entry) catch |err| {
                    try recordFailure(scratch, &failures, &counts, path, @errorName(err));
                    continue;
                };
                current_dir = path;
            },
            .file => {
                const name = baseName(path);
                const ext = extensionOf(name);
                if (isTempExtension(ext)) {
                    counts.skipped_temp += 1;
                    continue;
                }
                try collectFile(scratch, io, &files, &failures, &counts, path, name, ext, options);
            },
            else => counts.skipped_other += 1,
        }
    }

    // 排序 + 相邻去重：同一路径只留一条，顺序按路径字节稳定。
    std.mem.sort(FileFact, files.items, {}, lessThanPath);
    var write: usize = 0;
    var read: usize = 0;
    while (read < files.items.len) : (read += 1) {
        if (write != 0 and std.mem.eql(u8, files.items[write - 1].path, files.items[read].path)) {
            counts.duplicates += 1;
            continue;
        }
        files.items[write] = files.items[read];
        write += 1;
    }
    files.shrinkRetainingCapacity(write);
    counts.files = files.items.len;

    const file_slice = try files.toOwnedSlice(scratch);
    const failure_slice = try failures.toOwnedSlice(scratch);

    if (visitor) |sync| {
        for (file_slice) |*fact| sync.on_file(sync.context, fact);
        if (sync.on_failure) |on_failure| {
            for (failure_slice) |*failure| on_failure(sync.context, failure);
        }
    }

    return .{
        .arena = arena,
        .root = root,
        .files = file_slice,
        .failures = failure_slice,
        .counts = counts,
    };
}

fn collectFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    files: *std.ArrayList(FileFact),
    failures: *std.ArrayList(Failure),
    counts: *Counts,
    path: []const u8,
    name: []const u8,
    ext: []const u8,
    options: Options,
) error{OutOfMemory}!void {
    // 只以只读权限打开：身份查询不需要读内容，也不阻止别的进程同时写这个文件。
    // std 的 openFile 在 Windows 上会处理 `\\?\` 长路径前缀与共享模式。
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch |err| {
        try recordFailure(allocator, failures, counts, path, @errorName(err));
        return;
    };
    defer file.close(io);

    var information: BY_HANDLE_FILE_INFORMATION = undefined;
    if (GetFileInformationByHandle(file.handle, &information) == 0) {
        try recordFailure(allocator, failures, counts, path, "GetFileInformationByHandle");
        return;
    }

    if (!options.keep_hidden and isHiddenOrSystem(information.file_attributes)) {
        counts.skipped_hidden += 1;
        return;
    }

    const size: u64 = (@as(u64, information.file_size_high) << 32) | information.file_size_low;
    if (options.max_file_bytes != 0 and size > options.max_file_bytes) {
        counts.skipped_size += 1;
        return;
    }

    // 文件索引为 0 表示文件系统没给稳定的 File ID（某些 FAT / 网络盘）：
    // 置空让调用方退回「路径 + 大小 + mtime」，不做假身份。
    const identity: ?Identity = if (information.file_index_high == 0 and information.file_index_low == 0)
        null
    else
        .{
            .volume_serial = information.volume_serial_number,
            .file_index = (@as(u64, information.file_index_high) << 32) | information.file_index_low,
        };

    try files.append(allocator, .{
        .path = path,
        .name = name,
        .ext = ext,
        .size = size,
        .mtime = fileTimeToUnixMs(information.last_write_time),
        .identity = identity,
    });
}

fn recordFailure(
    allocator: std.mem.Allocator,
    failures: *std.ArrayList(Failure),
    counts: *Counts,
    path: []const u8,
    err: []const u8,
) error{OutOfMemory}!void {
    try failures.append(allocator, .{
        .path = try allocator.dupe(u8, path),
        .err = try allocator.dupe(u8, err),
    });
    counts.failures += 1;
}

fn lessThanPath(_: void, a: FileFact, b: FileFact) bool {
    return std.mem.order(u8, a.path, b.path) == .lt;
}

// ---------------------------------------------------------------------------
// 路径与属性
// ---------------------------------------------------------------------------

fn joinPath(allocator: std.mem.Allocator, root: []const u8, relative: []const u8) error{OutOfMemory}![]const u8 {
    const has_separator = root.len != 0 and
        (root[root.len - 1] == '\\' or root[root.len - 1] == '/');
    if (has_separator) return std.fmt.allocPrint(allocator, "{s}{s}", .{ root, relative });
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ root, std.fs.path.sep_str, relative });
}

/// 取最后一段（同时识别两种分隔符）。
fn baseName(path: []const u8) []const u8 {
    var start: usize = 0;
    for (path, 0..) |char, index| {
        if (char == '/' or char == '\\') start = index + 1;
    }
    return path[start..];
}

/// 最后一个扩展名（含点）；`name` 以点开头或没有点时返回空串。
fn extensionOf(name: []const u8) []const u8 {
    var index = name.len;
    while (index > 0) {
        index -= 1;
        if (name[index] == '.') return if (index == 0) "" else name[index..];
    }
    return "";
}

fn isTempExtension(ext: []const u8) bool {
    return std.ascii.eqlIgnoreCase(ext, ".tmp");
}

fn isHiddenOrSystem(attributes: DWORD) bool {
    return attributes & (FILE_ATTRIBUTE_HIDDEN | FILE_ATTRIBUTE_SYSTEM) != 0;
}

/// `GetFileAttributesW`。目录枚举不给属性，只能按路径再问一次。
fn attributesOf(allocator: std.mem.Allocator, path: []const u8) !DWORD {
    const wide = try widePath(allocator, path);
    defer allocator.free(wide);
    const attributes = GetFileAttributesW(wide.ptr);
    if (attributes == INVALID_FILE_ATTRIBUTES) return error.GetFileAttributes;
    return attributes;
}

/// 转成以 0 结尾的 UTF-16 并加 NT 前缀（长路径）。
///
/// `realPathFileAlloc` 产出的一定是盘符绝对路径或 UNC 路径，所以这里只需要处理
/// 这两种：
///   `C:\dir\a.wav`        -> `\\?\C:\dir\a.wav`
///   `\\server\share\a`    -> `\\?\UNC\server\share\a`
/// 已经是 `\\?\` / `\\.\` 前缀的原样转换。其它形态（相对路径、rooted 路径）不该
/// 出现；真出现了就按原样转换，让 Win32 自己报错，不做猜测。
fn widePath(allocator: std.mem.Allocator, path: []const u8) error{ OutOfMemory, InvalidPath }![:0]u16 {
    if (path.len >= 4 and isSep(path[0]) and isSep(path[1]) and
        (path[2] == '?' or path[2] == '.') and isSep(path[3]))
    {
        return std.unicode.wtf8ToWtf16LeAllocZ(allocator, path) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidWtf8 => error.InvalidPath,
        };
    }

    const prefixed = if (path.len >= 2 and isSep(path[0]) and isSep(path[1]))
        try std.fmt.allocPrint(allocator, "\\\\?\\UNC\\{s}", .{path[2..]})
    else if (path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and isSep(path[2]))
        try std.fmt.allocPrint(allocator, "\\\\?\\{s}", .{path})
    else
        try std.fmt.allocPrint(allocator, "{s}", .{path});
    defer allocator.free(prefixed);

    return std.unicode.wtf8ToWtf16LeAllocZ(allocator, prefixed) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidWtf8 => error.InvalidPath,
    };
}

fn isSep(char: u8) bool {
    return char == '\\' or char == '/';
}

/// FILETIME（1601-01-01 起的 100ns）→ Unix 毫秒。早于 1970 的值按 0 处理。
fn fileTimeToUnixMs(time: FILETIME) i64 {
    const ticks: u64 = (@as(u64, time.high) << 32) | time.low;
    // 1601-01-01 到 1970-01-01 的 100ns 数。
    const epoch_offset: u64 = 116_444_736_000_000_000;
    if (ticks <= epoch_offset) return 0;
    return @intCast((ticks - epoch_offset) / 10_000);
}
