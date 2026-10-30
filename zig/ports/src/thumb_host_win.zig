//! 缩略图隔离客户端的 Windows 后端：helper 进程的生命周期（spawn / 收尾 / 重启）。
//!
//! 手写 Win32 声明在 `thumb_host_win32.zig`，管道协议与超时看门狗在 `thumb_host_ipc.zig`；
//! 本文件只管"那个进程"和进程级单例状态。这是刻意的分层，也是单文件 ≤600 行的结果。
//!
//! ## 一个 helper，串行服务
//!
//! 进程级只有一个 helper（`otto-thumb-host.exe`），由 `state.lock` 串行化所有请求：
//! 缩略图工作线程本来就只有一条，串行不是瓶颈，却把"谁在写管道"变成显然的。
//! 懒启动——第一次 `get()` 才 spawn；之后复用，直到超时 / 崩溃 / 参数变化。
//!
//! ## 崩溃恢复：失联一次 = 重启一次 + 重试一次
//!
//! `WriteFile` 失败 / `ReadFile` 返回 EOF / 响应头自相矛盾（见 `thumb_host_ipc.zig`）
//! 都按"helper 没了"处理：记一次 `crashes`、关掉旧句柄、重新 spawn、把**同一个请求**
//! 再发一次。第二次再失联就返回 `error.ShellFailure`——不无限重启，也不把崩溃说成
//! "没有预览"。
//!
//! ## 不留孤儿：Job Object
//!
//! helper 被放进一个 `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` 的 Job：OTTO 自己崩了 /
//! 被任务管理器杀掉时，Windows 会关掉我们的句柄，Job 随之关掉并杀掉 helper。
//! 正常退出时先 `TerminateProcess` 再关句柄，走的是同一条路。
//!
//! ## 不弹窗、不抢焦点
//!
//! spawn 用 `CREATE_NO_WINDOW`（没有控制台窗口）+ `STARTF_USESHOWWINDOW / SW_HIDE`；
//! helper 里没有消息循环，需要泵的模态 UI 没有泵可驱动，系统错误对话框被 helper 的
//! `SetErrorMode` 关掉。极端情况下第三方 handler 自己起线程弹框：那也弹在 helper 进程里，
//! 抢的是 helper 的焦点而不该是「OTTO 卡住了」，而且超时被杀时对话框跟着消失。
//! helper 的 stdin/stdout 是我们给的管道，stderr 继承父进程——诊断能看见，
//! 但永远不会有一行混进协议帧（协议只走 stdout）。
//!
//! 句柄继承：两对管道都带 `SECURITY_ATTRIBUTES.bInheritHandle`，spawn 后立刻把父进程
//! 这一侧的端 `SetHandleInformation(HANDLE_FLAG_INHERIT, 0)` 关掉继承，
//! 子进程只拿到它该拿的三根句柄。

const std = @import("std");
const builtin = @import("builtin");
const host = @import("thumb_host.zig");
const ipc = @import("thumb_host_ipc.zig");
const pipe = @import("thumb_host_pipe.zig");
const win32 = @import("thumb_host_win32.zig");

/// helper 可执行文件的名字：与 `otto-lite.exe` 同目录（`zig build` 一次出两个）。
pub const helper_exe_name = "otto-thumb-host.exe";

/// 覆盖 helper 路径的环境变量。测试与诊断之外一般用不到；
/// 它存在是为了"不把调试用的路径写进命令行"。
const env_helper_name = std.unicode.wtf8ToWtf16LeStringLiteral("OTTO_THUMB_HOST");

// ---------------------------------------------------------------------------
// 日志
// ---------------------------------------------------------------------------

fn log(comptime format: []const u8, args: anytype) void {
    std.debug.print("[thumb-host] " ++ format ++ "\n", args);
}

// ---------------------------------------------------------------------------
// 进程级状态
// ---------------------------------------------------------------------------

/// 自适应自旋锁：照 `ports/watch.zig` 与 `app/thumbs.zig` 的先例（Zig 0.17 的
/// `std.Thread.Mutex` 需要 Io 实例），临界区里是查状态、写几十字节管道。
const SpinLock = struct {
    flag: std.atomic.Value(bool) = .init(false),

    fn acquire(self: *SpinLock) void {
        var spins: u32 = 0;
        while (self.flag.swap(true, .acquire)) {
            spins +%= 1;
            if (spins > 64) {
                std.Thread.yield() catch {};
                spins = 0;
            }
        }
    }

    fn release(self: *SpinLock) void {
        self.flag.store(false, .release);
    }
};

const State = struct {
    lock: SpinLock = .{},
    /// 分配 `helper_path` 的分配器（谁分配谁释放）。
    path_allocator: std.mem.Allocator = std.heap.smp_allocator,
    /// 当前 helper 的可执行文件路径（UTF-8 副本），用来识别"换了路径"。
    helper_path: ?[]u8 = null,
    proc: ?pipe.Handle = null,
    pid: win32.DWORD = 0,
    /// 最近一次被终止的 pid（诊断 / 测试用：证明进程真的被杀了）。
    last_pid: win32.DWORD = 0,
    stdin_write: ?pipe.Handle = null,
    stdout_read: ?pipe.Handle = null,
    job: ?pipe.Handle = null,
    size_px: u32 = 0,

    spawns: u32 = 0,
    restarts: u32 = 0,
    crashes: u32 = 0,
    timeouts: u32 = 0,
    requests: u32 = 0,
};

var state: State = .{};

// ---------------------------------------------------------------------------
// 公共入口（由 thumb_host.zig 的平台门禁调用）
// ---------------------------------------------------------------------------

pub fn get(
    allocator: std.mem.Allocator,
    path_utf8: []const u8,
    size_px: u32,
    options: host.Options,
) host.Error!host.Thumbnail {
    if (builtin.os.tag != .windows) return error.Unsupported;

    state.lock.acquire();
    defer state.lock.release();
    state.requests +%= 1;

    const timeout_ms: win32.DWORD = @max(1, options.timeout_ms);
    try startLocked(allocator, size_px, options);

    var attempt: u32 = 0;
    while (true) : (attempt += 1) {
        const stdin_write = state.stdin_write orelse return error.ShellFailure;
        const stdout_read = state.stdout_read orelse return error.ShellFailure;
        const process = state.proc orelse return error.ShellFailure;

        const reply = ipc.exchange(allocator, stdin_write, stdout_read, process, path_utf8, timeout_ms) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Timeout => {
                state.timeouts +%= 1;
                log("请求超时（{d} ms）：终止 helper pid={d}，重启后下次请求再试", .{
                    timeout_ms, state.pid,
                });
                terminateLocked();
                state.restarts +%= 1;
                // 超时的请求按约定返回 failed；重启是为了让下一张图不被拖累。
                try startLocked(allocator, size_px, options);
                return error.Timeout;
            },
        };

        switch (reply) {
            .image => |image| return image,
            .status => |status| return ipc.statusToError(status),
            .broken => {
                state.crashes +%= 1;
                log("helper 失联（pid={d} exit=0x{X:0>8}）：重启一次并重试本请求", .{
                    state.pid, exitCodeLocked(),
                });
                terminateLocked();
                if (attempt >= 1) return error.ShellFailure;
                state.restarts +%= 1;
                try startLocked(allocator, size_px, options);
                log("helper 已重启 pid={d}", .{state.pid});
            },
        }
    }
}

/// 启动前自检：helper 可执行文件在不在。**只查文件，不 spawn**（懒启动不变）。
/// 缺失是明确错误：调用方负责打印"装丢了"的提示并以启动失败退出，不许静默退回进程内。
pub fn ensurePresent(allocator: std.mem.Allocator, options: host.Options) host.Error!void {
    const path = resolveHelperPath(allocator, options) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidPath => {
            log("缩略图 helper 路径不可用（OTTO_THUMB_HOST 或可执行文件目录）", .{});
            return error.HelperUnavailable;
        },
    };
    defer allocator.free(path);

    const wide = std.unicode.wtf8ToWtf16LeAllocZ(allocator, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidWtf8 => {
            log("缩略图 helper 路径不是合法 UTF-8：{s}", .{path});
            return error.HelperUnavailable;
        },
    };
    defer allocator.free(wide);

    const attributes = win32.GetFileAttributesW(wide.ptr);
    if (attributes == win32.INVALID_FILE_ATTRIBUTES or
        (attributes & win32.FILE_ATTRIBUTE_DIRECTORY) != 0)
    {
        log("找不到缩略图 helper：{s}（zig build 应同时产出 {s}；--no-isolation 可退回进程内）", .{
            path, helper_exe_name,
        });
        return error.HelperUnavailable;
    }
}

/// 停掉 helper。可重复调用；之后再用 `get()` 会重新懒启动。
pub fn deinit() void {
    state.lock.acquire();
    defer state.lock.release();
    terminateLocked();
}

pub fn stats() host.Stats {
    state.lock.acquire();
    defer state.lock.release();
    return .{
        .running = state.proc != null,
        .pid = state.pid,
        .last_pid = state.last_pid,
        .spawns = state.spawns,
        .restarts = state.restarts,
        .crashes = state.crashes,
        .timeouts = state.timeouts,
        .requests = state.requests,
        .size_px = state.size_px,
    };
}

pub fn helperPid() ?u32 {
    state.lock.acquire();
    defer state.lock.release();
    if (state.proc == null) return null;
    return state.pid;
}

// ---------------------------------------------------------------------------
// 路径：OTTO_THUMB_HOST > 可执行文件同目录下的 otto-thumb-host.exe
// ---------------------------------------------------------------------------

fn resolveHelperPath(
    allocator: std.mem.Allocator,
    options: host.Options,
) error{ OutOfMemory, InvalidPath }![]u8 {
    if (options.helper_path) |explicit| {
        if (explicit.len == 0) return error.InvalidPath;
        return allocator.dupe(u8, explicit);
    }

    switch (envHelperPath(allocator)) {
        .path => |path| return path,
        .not_found => {},
        .unusable => |name| {
            log("环境变量 OTTO_THUMB_HOST 不可用（{s}），不猜别的路径", .{name});
            return error.InvalidPath;
        },
    }
    return siblingHelperPath(allocator);
}

const EnvResult = union(enum) {
    path: []u8,
    not_found: void,
    /// 变量设了但内容读不出来 / 太长 / 不是合法 UTF-16。
    unusable: []const u8,
};

fn envHelperPath(allocator: std.mem.Allocator) EnvResult {
    var buffer: [4096]u16 = undefined;
    const length = win32.GetEnvironmentVariableW(env_helper_name, &buffer, buffer.len);
    if (length == 0) {
        const code = pipe.lastError();
        // ERROR_ENVVAR_NOT_FOUND = 203；别的错误（比如权限）也不要静默换成默认路径。
        return if (code == 203) .{ .not_found = {} } else .{ .unusable = "读取失败" };
    }
    if (length >= buffer.len) return .{ .unusable = "路径过长" };

    const path = std.unicode.wtf16LeToWtf8Alloc(allocator, buffer[0..length]) catch
        return .{ .unusable = "不是合法 UTF-16" };
    if (path.len == 0) {
        allocator.free(path);
        return .{ .not_found = {} };
    }
    return .{ .path = path };
}

fn siblingHelperPath(allocator: std.mem.Allocator) error{ OutOfMemory, InvalidPath }![]u8 {
    var buffer: [4096]u16 = undefined;
    const length = win32.GetModuleFileNameW(null, &buffer, buffer.len);
    if (length == 0 or length >= buffer.len) return error.InvalidPath;

    const exe_path = std.unicode.wtf16LeToWtf8Alloc(allocator, buffer[0..length]) catch
        return error.OutOfMemory;
    defer allocator.free(exe_path);

    const dir = std.fs.path.dirname(exe_path) orelse return error.InvalidPath;
    return std.fs.path.join(allocator, &.{ dir, helper_exe_name }) catch return error.OutOfMemory;
}

// ---------------------------------------------------------------------------
// 启动 / 收尾
// ---------------------------------------------------------------------------

/// 确保有一个能服务 `size_px` 的 helper。路径或边长变了就换一个：
/// 边长是 helper 的启动参数（协议帧里没有尺寸，见 `thumb_host_proto.zig`）。
fn startLocked(allocator: std.mem.Allocator, size_px: u32, options: host.Options) host.Error!void {
    const wanted = resolveHelperPath(allocator, options) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidPath => return error.HelperUnavailable,
    };
    defer allocator.free(wanted);

    if (state.proc != null and state.size_px == size_px and state.helper_path != null and
        std.mem.eql(u8, state.helper_path.?, wanted))
    {
        return;
    }

    terminateLocked();

    state.helper_path = allocator.dupe(u8, wanted) catch return error.OutOfMemory;
    state.path_allocator = allocator;
    state.size_px = size_px;

    spawnLocked() catch |err| {
        // 句柄已由 spawnLocked 清干净；路径副本留着，下次还会再试。
        return err;
    };
    state.spawns +%= 1;
    log("helper 启动 pid={d} size={d}（累计 spawn={d}）", .{ state.pid, size_px, state.spawns });
}

/// 杀掉并释放当前 helper。幂等。
fn terminateLocked() void {
    if (state.stdin_write) |handle| _ = win32.CloseHandle(handle);
    if (state.stdout_read) |handle| _ = win32.CloseHandle(handle);
    state.stdin_write = null;
    state.stdout_read = null;

    if (state.proc) |process| {
        state.last_pid = state.pid;
        _ = win32.TerminateProcess(process, 1);
        _ = win32.CloseHandle(process);
    }
    state.proc = null;
    state.pid = 0;
    state.size_px = 0;

    // Job 关掉的那一刻，就算上面漏杀了，系统也会把 job 里的进程一起收掉。
    if (state.job) |job| _ = win32.CloseHandle(job);
    state.job = null;

    if (state.helper_path) |path| state.path_allocator.free(path);
    state.helper_path = null;
}

/// spawn 过程中需要收尾的句柄。成功时逐个搬进 `state`，失败时 `cleanup` 全关。
const Spawned = struct {
    stdin_read: ?pipe.Handle = null,
    stdin_write: ?pipe.Handle = null,
    stdout_read: ?pipe.Handle = null,
    stdout_write: ?pipe.Handle = null,
    process: ?pipe.Handle = null,
    job: ?pipe.Handle = null,

    fn cleanup(self: *Spawned) void {
        if (self.stdin_read) |h| _ = win32.CloseHandle(h);
        if (self.stdin_write) |h| _ = win32.CloseHandle(h);
        if (self.stdout_read) |h| _ = win32.CloseHandle(h);
        if (self.stdout_write) |h| _ = win32.CloseHandle(h);
        if (self.process) |h| _ = win32.CloseHandle(h);
        if (self.job) |h| _ = win32.CloseHandle(h);
        self.* = .{};
    }
};

fn spawnLocked() host.Error!void {
    const allocator = state.path_allocator;
    const helper_path = state.helper_path.?;

    // 命令行是 `"<path>" --size <n>`：路径里有引号就没法可靠地拼，直接当不可用。
    if (std.mem.indexOfScalar(u8, helper_path, '"') != null) {
        log("helper 路径含引号，无法拼命令行：{s}", .{helper_path});
        return error.HelperUnavailable;
    }

    const application = std.unicode.wtf8ToWtf16LeAllocZ(allocator, helper_path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidWtf8 => return error.HelperUnavailable,
    };
    defer allocator.free(application);

    const command_utf8 = std.fmt.allocPrint(allocator, "\"{s}\" --size {d}", .{
        helper_path, state.size_px,
    }) catch return error.OutOfMemory;
    defer allocator.free(command_utf8);
    const command = std.unicode.wtf8ToWtf16LeAllocZ(allocator, command_utf8) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidWtf8 => return error.HelperUnavailable,
    };
    defer allocator.free(command);

    var spawned = Spawned{};
    errdefer spawned.cleanup();

    var inherit = win32.SECURITY_ATTRIBUTES{
        .nLength = @sizeOf(win32.SECURITY_ATTRIBUTES),
        .lpSecurityDescriptor = null,
        .bInheritHandle = 1,
    };

    if (win32.CreatePipe(&spawned.stdin_read, &spawned.stdin_write, &inherit, 0) == 0) {
        log("CreatePipe(stdin) 失败 error={d}", .{pipe.lastError()});
        return error.ShellFailure;
    }
    if (win32.CreatePipe(&spawned.stdout_read, &spawned.stdout_write, &inherit, 0) == 0) {
        log("CreatePipe(stdout) 失败 error={d}", .{pipe.lastError()});
        return error.ShellFailure;
    }
    // 父进程这一侧的两个端不许被 helper 继承（否则 helper 死了管道也不会 EOF）。
    _ = win32.SetHandleInformation(spawned.stdin_write.?, win32.HANDLE_FLAG_INHERIT, 0);
    _ = win32.SetHandleInformation(spawned.stdout_read.?, win32.HANDLE_FLAG_INHERIT, 0);

    var startup = std.mem.zeroes(win32.STARTUPINFOW);
    startup.cb = @sizeOf(win32.STARTUPINFOW);
    startup.dwFlags = win32.STARTF_USESHOWWINDOW | win32.STARTF_USESTDHANDLES;
    startup.wShowWindow = win32.SW_HIDE;
    startup.hStdInput = spawned.stdin_read;
    startup.hStdOutput = spawned.stdout_write;
    startup.hStdError = pipe.stdHandle(pipe.std_error_handle);

    var info = std.mem.zeroes(win32.PROCESS_INFORMATION);
    const created = win32.CreateProcessW(
        application.ptr,
        command.ptr,
        null,
        null,
        1, // bInheritHandles：只把上面三根可继承句柄带过去
        win32.CREATE_NO_WINDOW,
        null,
        null,
        &startup,
        &info,
    );
    if (created == 0) {
        log("CreateProcessW 失败 error={d} exe={s}", .{ pipe.lastError(), helper_path });
        return error.HelperUnavailable;
    }

    spawned.process = info.hProcess;
    if (info.hThread) |thread| _ = win32.CloseHandle(thread);

    // 子进程那一侧的端已经交给它了，父进程立刻关掉自己的副本。
    if (spawned.stdin_read) |handle| {
        _ = win32.CloseHandle(handle);
        spawned.stdin_read = null;
    }
    if (spawned.stdout_write) |handle| {
        _ = win32.CloseHandle(handle);
        spawned.stdout_write = null;
    }

    spawned.job = createKillOnCloseJob(spawned.process.?);

    state.stdin_write = spawned.stdin_write;
    state.stdout_read = spawned.stdout_read;
    state.proc = spawned.process;
    state.pid = info.dwProcessId;
    state.job = spawned.job;
    // 句柄已经搬进 state：清空局部副本，errdefer 的 cleanup 不会再关它们。
    spawned = .{};
}

/// 建一个"句柄一关就杀进程"的 Job 并把 helper 放进去。
/// 失败不算致命（老系统/嵌套 Job 限制）：返回 null，孤儿风险退回到正常退出路径。
fn createKillOnCloseJob(process: pipe.Handle) ?pipe.Handle {
    const job = win32.CreateJobObjectW(null, null) orelse return null;
    var limit = std.mem.zeroes(win32.JOB_EXTENDED_LIMIT);
    limit.BasicLimitInformation.LimitFlags = win32.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (win32.SetInformationJobObject(
        job,
        win32.JOB_OBJECT_EXTENDED_LIMIT_INFORMATION,
        &limit,
        @sizeOf(win32.JOB_EXTENDED_LIMIT),
    ) == 0) {
        _ = win32.CloseHandle(job);
        return null;
    }
    if (win32.AssignProcessToJobObject(job, process) == 0) {
        _ = win32.CloseHandle(job);
        return null;
    }
    return job;
}

fn exitCodeLocked() win32.DWORD {
    const process = state.proc orelse return 0;
    var code: win32.DWORD = 0;
    if (win32.GetExitCodeProcess(process, &code) == 0) return 0;
    return code;
}
