//! OTTO 文件监听口岸的 Windows 后端：ReadDirectoryChangesW。
//!
//! 三条边界，对应 CHARTER「八、零转义的边界」：
//!   * Win32 声明、UTF-16 路径翻译只出现在本文件（口岸必须转义，且只准在口岸）；
//!   * 本文件不认识 watch.zig 的事件类型，只通过 `Sink` 回调交出「动作 + 路径字节」，
//!     所以它不依赖事件队列，可以单独喂合成缓冲区做单元测试；
//!   * 手写 `extern "kernel32"`：没有 @cImport、没有 C shim、没有外部依赖。
//!
//! 线程与停止（阻塞读 + 取消，任务允许的两种方案里择一）：
//!   后台线程跑阻塞式 ReadDirectoryChangesW；stop 时先置 `stop_requested`，
//!   再用 `CancelSynchronousIo(线程句柄)` 把线程从读里拔出来（返回 995
//!   ERROR_OPERATION_ABORTED），最后 join。
//!   两个细节保证不漏：
//!     - 线程每轮读之前都看通知位，置位后不再发起新读；
//!     - stop 侧在 `thread_active` 为真期间重试取消，覆盖「线程刚过检查、读还没
//!       真正挂起」那一瞬（此时第一次取消会 ERROR_NOT_FOUND，下一轮一定命中）。
//!   为什么不用 overlapped + 停止事件：本机（C:\src 所在卷）内核的 overlapped
//!   ReadDirectoryChangesW 直接返回 TRUE / bytes=0，不排队也不报错——20 行 C
//!   程序可复现；阻塞式同一参数工作正常。所以这里选阻塞式。
//!
//! 溢出：
//!   ERROR_NOTIFY_ENUM_DIR（以及返回成功但 bytes == 0）说明内核侧丢了变更，
//!   产出一条 `.overflow` 原始事件（lost 未知记 0），由上层变成显式 Event 与计数。

const std = @import("std");
const path_win = @import("otto_win_path");
const builtin = @import("builtin");

/// 平台闸门：这是 Windows 口岸，其它平台 init 直接 error.Unsupported。
pub const supported = builtin.os.tag == .windows;

// ---------------------------------------------------------------------------
// 手写 Win32 声明（等价于 windows.h / winbase.h 里用到的部分）
// ---------------------------------------------------------------------------

const HANDLE = *anyopaque;
const BOOL = i32;
const DWORD = u32;

const INVALID_HANDLE_VALUE: HANDLE = @as(HANDLE, @ptrFromInt(std.math.maxInt(usize)));

const FILE_LIST_DIRECTORY: DWORD = 0x0000_0001;
const FILE_SHARE_READ: DWORD = 0x0000_0001;
const FILE_SHARE_WRITE: DWORD = 0x0000_0002;
const FILE_SHARE_DELETE: DWORD = 0x0000_0004;
const OPEN_EXISTING: DWORD = 3;
const FILE_FLAG_BACKUP_SEMANTICS: DWORD = 0x0200_0000;

const ERROR_FILE_NOT_FOUND: DWORD = 2;
const ERROR_PATH_NOT_FOUND: DWORD = 3;
const ERROR_ACCESS_DENIED: DWORD = 5;
const ERROR_SHARING_VIOLATION: DWORD = 32;
const ERROR_INVALID_NAME: DWORD = 123;
const ERROR_BAD_PATHNAME: DWORD = 161;
const ERROR_DIRECTORY: DWORD = 267;
const ERROR_OPERATION_ABORTED: DWORD = 995;
const ERROR_NOTIFY_ENUM_DIR: DWORD = 1022;

/// FILE_NOTIFY_INFORMATION 的固定头：NextEntryOffset / Action / FileNameLength。
const notify_header_size: usize = 12;

const FILE_ACTION_ADDED: DWORD = 1;
const FILE_ACTION_REMOVED: DWORD = 2;
const FILE_ACTION_MODIFIED: DWORD = 3;
const FILE_ACTION_RENAMED_OLD_NAME: DWORD = 4;
const FILE_ACTION_RENAMED_NEW_NAME: DWORD = 5;

/// 与 watch.zig 的 max_path_bytes 保持一致（watch.zig 里有 comptime 对账）。
pub const max_path_bytes: usize = 1024;

/// 一次读的缓冲区。64 KiB 是 Windows 上的常用值：目录风暴下少触发内核溢出。
pub const read_buffer_bytes: usize = 64 * 1024;

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

extern "kernel32" fn ReadDirectoryChangesW(
    directory: HANDLE,
    buffer: *anyopaque,
    buffer_length: DWORD,
    watch_subtree: BOOL,
    notify_filter: DWORD,
    bytes_returned: ?*DWORD,
    overlapped: ?*anyopaque,
    completion_routine: ?*anyopaque,
) callconv(.winapi) BOOL;

extern "kernel32" fn CancelSynchronousIo(thread_handle: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn Sleep(milliseconds: DWORD) callconv(.winapi) void;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;

/// ReadDirectoryChangesW 的通知过滤器位。
pub const notify = struct {
    pub const file_name: u32 = 0x0000_0001;
    pub const dir_name: u32 = 0x0000_0002;
    pub const attributes: u32 = 0x0000_0004;
    pub const size: u32 = 0x0000_0008;
    pub const last_write: u32 = 0x0000_0010;
    pub const last_access: u32 = 0x0000_0020;
    pub const creation: u32 = 0x0000_0040;
    pub const security: u32 = 0x0000_0100;

    /// 任务要求的那一组：文件名 / 目录名 / 最后写入 / 大小 / 创建。
    pub const default_filter: u32 = file_name | dir_name | last_write | size | creation;
};

// ---------------------------------------------------------------------------
// 回调面：win_watch 只认识「动作 + 路径」，不认识 watch.zig 的 Event
// ---------------------------------------------------------------------------

pub const Action = enum {
    added,
    removed,
    modified,
    /// 成对的 OLD/NEW 已配对；path = 新名，old_path = 旧名。
    renamed,
    /// 内核缓冲区溢出；lost = 承认的丢失条数，0 表示未知。
    overflow,
    /// 装不下 / 认不出的通知（路径超过 max_path_bytes、未知 action）。
    skipped,
};

pub const RawEvent = struct {
    action: Action,
    /// 相对被监视目录的 WTF-8（合法名字即 UTF-8）；只在回调期间有效，接收方必须拷贝。
    path: []const u8 = "",
    /// 仅 `.renamed`：改名前的旧路径。
    old_path: []const u8 = "",
    /// 仅 `.overflow`：内核承认的丢失条数；0 表示「未知」。
    lost: u32 = 0,
};

pub const Sink = struct {
    context: *anyopaque,
    emit: *const fn (context: *anyopaque, event: RawEvent) void,
};

// ---------------------------------------------------------------------------
// 解码：FILE_NOTIFY_INFORMATION → RawEvent（含 rename 配对）
// ---------------------------------------------------------------------------

const PendingPath = struct {
    bytes: [max_path_bytes]u8 = @splat(0),
    len: usize = 0,

    fn set(self: *PendingPath, text: []const u8) bool {
        if (text.len > max_path_bytes) return false;
        @memcpy(self.bytes[0..text.len], text);
        self.len = text.len;
        return true;
    }

    fn slice(self: *const PendingPath) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const Decoder = struct {
    /// 还没等到 NEW 的 OLD 名字。跨缓冲区保留：Windows 不保证把一对改名放进同一次读。
    pending_old: PendingPath = .{},
    has_pending_old: bool = false,

    pub fn reset(self: *Decoder) void {
        self.has_pending_old = false;
        self.pending_old.len = 0;
    }

    /// 吃掉一次 ReadDirectoryChangesW 的输出。
    pub fn feed(self: *Decoder, buffer: []const u8, sink: Sink) void {
        var offset: usize = 0;
        while (offset + notify_header_size <= buffer.len) {
            const next_offset = readU32(buffer[offset..][0..4]);
            const action = readU32(buffer[offset + 4 ..][0..4]);
            const name_bytes = readU32(buffer[offset + 8 ..][0..4]);

            if (name_bytes % 2 != 0) return; // 损坏：直接放弃这一段
            const units: usize = name_bytes / 2;
            const name_start = offset + notify_header_size;

            if (name_start + units * 2 > buffer.len) return; // 截断：放弃这一段

            if (units > max_path_bytes) {
                sink.emit(sink.context, .{ .action = .skipped });
            } else {
                self.dispatch(action, buffer[name_start .. name_start + units * 2], sink);
            }

            if (next_offset == 0) break; // 最后一项
            if (next_offset < notify_header_size or next_offset % 4 != 0) break; // 损坏，防死循环
            offset += next_offset;
        }
    }

    /// ERROR_NOTIFY_ENUM_DIR：内核丢了变更。先把悬挂的 OLD 降级成 removed，再报溢出。
    pub fn feedOverflow(self: *Decoder, sink: Sink, lost: u32) void {
        self.flushPending(sink);
        sink.emit(sink.context, .{ .action = .overflow, .lost = lost });
    }

    /// 悬挂的 OLD：配不上 NEW，按 removed 降级，不静默丢。
    pub fn flushPending(self: *Decoder, sink: Sink) void {
        if (!self.has_pending_old) return;
        const old_path = self.pending_old.slice();
        sink.emit(sink.context, .{ .action = .removed, .path = old_path });
        self.has_pending_old = false;
        self.pending_old.len = 0;
    }

    fn dispatch(self: *Decoder, action: DWORD, name: []const u8, sink: Sink) void {
        var utf16: [max_path_bytes]u16 = undefined;
        const units = name.len / 2;
        for (0..units) |i| utf16[i] = readU16(name[i * 2 ..][0..2]);

        const needed = std.unicode.calcWtf8Len(utf16[0..units]);
        if (needed > max_path_bytes) {
            sink.emit(sink.context, .{ .action = .skipped });
            return;
        }
        var utf8: [max_path_bytes]u8 = undefined;
        const written = std.unicode.wtf16LeToWtf8(&utf8, utf16[0..units]);
        const path = utf8[0..written];

        switch (action) {
            FILE_ACTION_ADDED => {
                self.flushPending(sink);
                sink.emit(sink.context, .{ .action = .added, .path = path });
            },
            FILE_ACTION_REMOVED => {
                self.flushPending(sink);
                sink.emit(sink.context, .{ .action = .removed, .path = path });
            },
            FILE_ACTION_MODIFIED => {
                self.flushPending(sink);
                sink.emit(sink.context, .{ .action = .modified, .path = path });
            },
            FILE_ACTION_RENAMED_OLD_NAME => {
                // 连续两个 OLD：前一个配不上，降级 removed。
                self.flushPending(sink);
                if (!self.pending_old.set(path)) {
                    sink.emit(sink.context, .{ .action = .skipped });
                    return;
                }
                self.has_pending_old = true;
            },
            FILE_ACTION_RENAMED_NEW_NAME => {
                if (self.has_pending_old) {
                    sink.emit(sink.context, .{
                        .action = .renamed,
                        .path = path,
                        .old_path = self.pending_old.slice(),
                    });
                    self.has_pending_old = false;
                    self.pending_old.len = 0;
                } else {
                    // 只有 NEW、没有 OLD：旧名不可知，按 created 降级。
                    sink.emit(sink.context, .{ .action = .added, .path = path });
                }
            },
            else => sink.emit(sink.context, .{ .action = .skipped }),
        }
    }
};

// ---------------------------------------------------------------------------
// 句柄 / 读循环
// ---------------------------------------------------------------------------

pub const OpenError = error{
    OutOfMemory,
    Unsupported,
    InvalidPath,
    FileNotFound,
    AccessDenied,
    NotDir,
    SharingViolation,
    Unexpected,
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    handle: ?HANDLE = null,
    buffer: []u8 = &.{},
    decoder: Decoder = .{},
    last_error: std.atomic.Value(u32) = .init(0),
    stop_requested: std.atomic.Value(bool) = .init(false),
    /// 后台线程是否活着：stop 侧用它决定还要不要重试取消。
    thread_active: std.atomic.Value(bool) = .init(false),
    /// 第一轮读是否已经发起：start() 靠它等「已经架好」，否则 start 之后立刻发生的
    /// 变更会落在读生效之前，永远收不到。
    armed: std.atomic.Value(bool) = .init(false),

    /// 打开目录句柄。路径写错 / 没权限在这里就报出来，不用等 start。
    pub fn open(allocator: std.mem.Allocator, directory: []const u8) OpenError!Context {
        if (!supported) return error.Unsupported;

        const wide = path_win.wide(allocator, directory, 0) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidPath => return error.InvalidPath,
        };
        defer allocator.free(wide);

        const handle = CreateFileW(
            wide.ptr,
            FILE_LIST_DIRECTORY,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            null,
            OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS,
            null,
        );
        if (handle == INVALID_HANDLE_VALUE) return mapOpenError(GetLastError());

        var context = Context{ .allocator = allocator, .handle = handle };
        errdefer context.deinit();
        // ReadDirectoryChangesW 要求缓冲区按 DWORD 对齐（不对齐时 Windows 直接返回
        // ERROR_NOACCESS 998，线程当场退出）。调用方传进来的分配器可能是 bump/arena，
        // 只保证 1 字节对齐，所以这块固定大小的缓冲区不走它。
        context.buffer = try std.heap.page_allocator.alloc(u8, read_buffer_bytes);
        return context;
    }

    pub fn deinit(self: *Context) void {
        if (self.handle) |handle| _ = CloseHandle(handle);
        if (self.buffer.len != 0) std.heap.page_allocator.free(self.buffer);
        self.handle = null;
        self.buffer = &.{};
    }

    /// 重新 start 之前复位：清通知位、清错误码、清悬挂 OLD。
    pub fn resetForStart(self: *Context) void {
        self.stop_requested.store(false, .release);
        self.armed.store(false, .release);
        self.last_error.store(0, .monotonic);
        self.decoder.reset();
    }

    /// 等后台线程把第一轮读发起来（或超时）。start() 调它，缩小「start 之后立刻
    /// 发生变更却没人听」的窗口：线程在进入 ReadDirectoryChangesW 前置位。
    pub fn waitUntilArmed(self: *Context, timeout_ms: u32) bool {
        const deadline = GetTickCount64() + timeout_ms;
        while (!self.armed.load(.acquire)) {
            if (GetTickCount64() >= deadline) return false;
            std.Thread.yield() catch {};
        }
        return true;
    }

    /// 请求后台线程退出并把阻塞读取消掉。
    /// `thread` 是 std.Thread.getHandle()（Windows 上的 CreateThread 句柄），
    /// 只有它能让 CancelSynchronousIo 找到目标线程。
    pub fn requestStop(self: *Context, thread: ?HANDLE) void {
        self.stop_requested.store(true, .release);
        const thread_handle = thread orelse return;

        // 线程可能正好在两次读之间（取消会 ERROR_NOT_FOUND），也可能刚过检查、
        // 读还没挂起。只要它还活着就重试，最多 200 次：正常第一次就命中（线程正
        // 阻塞在 RDCW 上）；没命中的话，它要么马上进读被下一轮取消，要么在下一轮
        // 看到通知位自己退出——join 不会挂在读上。
        var attempts: u32 = 0;
        while (self.thread_active.load(.acquire) and attempts < 200) : (attempts += 1) {
            if (CancelSynchronousIo(thread_handle) != 0) break;
            if (attempts < 32) {
                std.Thread.yield() catch {};
            } else {
                Sleep(1);
            }
        }
    }

    pub fn lastError(self: *const Context) u32 {
        return self.last_error.load(.monotonic);
    }

    /// 后台线程主体：阻塞读 → 解码 → Sink，直到 stop_requested 或不可恢复的 IO 错误。
    pub fn run(self: *Context, sink: Sink, recursive: bool, filter: u32) void {
        const handle = self.handle orelse return;

        self.thread_active.store(true, .release);
        defer self.thread_active.store(false, .release);
        self.decoder.reset();

        while (!self.stop_requested.load(.acquire)) {
            var bytes: DWORD = 0;
            self.armed.store(true, .release);
            const started = ReadDirectoryChangesW(
                handle,
                @ptrCast(self.buffer.ptr),
                @intCast(self.buffer.len),
                if (recursive) 1 else 0,
                filter,
                &bytes,
                null,
                null,
            );
            if (started != 0) {
                if (bytes == 0) {
                    self.decoder.feedOverflow(sink, 0);
                } else {
                    self.decoder.feed(self.buffer[0..bytes], sink);
                }
                continue;
            }

            const error_code = GetLastError();
            if (error_code == ERROR_OPERATION_ABORTED) break; // stop() 取消的
            if (error_code == ERROR_NOTIFY_ENUM_DIR) {
                self.decoder.feedOverflow(sink, 0);
                continue;
            }
            self.last_error.store(error_code, .monotonic);
            break;
        }

        self.decoder.flushPending(sink);
    }
};

fn mapOpenError(code: DWORD) OpenError {
    return switch (code) {
        ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND => error.FileNotFound,
        ERROR_ACCESS_DENIED => error.AccessDenied,
        ERROR_SHARING_VIOLATION => error.SharingViolation,
        ERROR_DIRECTORY => error.NotDir,
        ERROR_INVALID_NAME, ERROR_BAD_PATHNAME => error.InvalidPath,
        else => error.Unexpected,
    };
}

fn readU32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .little);
}

fn readU16(bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], .little);
}
