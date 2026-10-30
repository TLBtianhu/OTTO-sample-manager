//! 缩略图隔离的管道协议：一次请求的帧交换、超时看门狗、状态码 → 错误。
//!
//! 这里不认识"进程级状态"：句柄由调用方给（`thumb_host_win.zig` 持有单例），
//! 本文件只负责"把一帧发出去、把一帧收回来、到点就杀"。拆开还有一个好处：
//! 协议层可以在没有 helper 的情况下被读懂、被审阅——它是隔离层里最该稳定的一层。
//!
//! ## 超时为什么用看门狗线程
//!
//! Win32 的匿名管道没有 `ReadFile` 超时（overlapped 只对命名管道有效）。所以每个请求
//! 配一个看门狗：`WaitForSingleObject(事件, timeout)`。
//!
//!   * 请求正常结束 → 调用方 `SetEvent` → 看门狗立刻返回 → join；
//!   * 到期没结束 → `TerminateProcess(helper)`，主线程正阻塞的 `ReadFile` / `WriteFile`
//!     随管道断开返回失败 → 上层判定 `error.Timeout`。
//!
//! 这样超时是**硬上限**：写管道被卡住（路径帧超过管道缓冲且 helper 不读）也照样到期。
//!
//! ## 一次交换的四种结局
//!
//!   * `.image`  —— 一块自洽的 BGRA（尺寸 / 跨度 / 字节数都验过）；
//!   * `.status` —— helper 明确回了"没有 handler / 文件没了 / 失败"，**不重启**；
//!   * `.broken` —— 写失败、读到 EOF、响应头自相矛盾：按崩溃处理，上层重启并重试；
//!   * `error.Timeout` / `error.OutOfMemory` —— 不是 helper 的错，单独传上去。

const std = @import("std");
const host = @import("thumb_host.zig");
const pipe = @import("thumb_host_pipe.zig");
const proto = @import("thumb_host_proto.zig");
const win32 = @import("thumb_host_win32.zig");

pub const Reply = union(enum) {
    image: host.Thumbnail,
    /// helper 明确回了"没有 / 文件没了 / 失败"——不是崩溃，不要重启。
    status: proto.Status,
    /// 管道断了 / 协议失配：按崩溃处理（上层重启一次再重试）。
    broken: void,
};

pub const ExchangeError = error{ OutOfMemory, Timeout };

/// 发一帧、收一帧。`process` 只交给看门狗在超时时杀。
pub fn exchange(
    allocator: std.mem.Allocator,
    stdin_write: pipe.Handle,
    stdout_read: pipe.Handle,
    process: pipe.Handle,
    path_utf8: []const u8,
    timeout_ms: win32.DWORD,
) ExchangeError!Reply {
    var watchdog = Watchdog{ .done = null, .process = process, .timeout_ms = timeout_ms };
    // 看门狗起不来就不做这次 IO：在没有超时保护的情况下读管道 = 拿整个工作线程赌第三方 handler。
    if (!watchdog.start()) return Reply{ .broken = {} };
    defer watchdog.stop();

    var header: [proto.request_header_bytes]u8 = undefined;
    proto.encodeRequestHeader(&header, path_utf8.len) catch return Reply{ .broken = {} };

    // 写也可能被卡住（帧比管道缓冲大、helper 又不读）；卡到看门狗开杀时，
    // 这仍然是"超时"，不能算成崩溃——否则会白等两轮、还会把 timeout 账记成 crash。
    pipe.writeAll(stdin_write, &header) catch {
        if (watchdog.fired()) return error.Timeout;
        return Reply{ .broken = {} };
    };
    pipe.writeAll(stdin_write, path_utf8) catch {
        if (watchdog.fired()) return error.Timeout;
        return Reply{ .broken = {} };
    };

    var response: [proto.response_header_bytes]u8 = undefined;
    pipe.readExact(stdout_read, &response) catch {
        if (watchdog.fired()) return error.Timeout;
        return Reply{ .broken = {} };
    };
    if (watchdog.fired()) return error.Timeout;

    const parsed = proto.decodeHeader(&response) orelse return Reply{ .broken = {} };
    if (parsed.status != .ok) return .{ .status = parsed.status };

    const pixels = try allocator.alloc(u8, parsed.bytes);
    var owned = false;
    defer if (!owned) allocator.free(pixels);

    pipe.readExact(stdout_read, pixels) catch {
        if (watchdog.fired()) return error.Timeout;
        return Reply{ .broken = {} };
    };
    if (watchdog.fired()) return error.Timeout;

    owned = true;
    return .{ .image = .{
        .pixels = pixels,
        .width = parsed.width,
        .height = parsed.height,
        .stride = parsed.stride,
    } };
}

/// 协议状态 → 公共错误集。三态与 `ports/thumb.zig` 一一对应，不合并。
pub fn statusToError(status: proto.Status) host.Error {
    return switch (status) {
        .ok => unreachable, // 调用方只在 status != .ok 时进来
        .no_handler => error.NoHandler,
        .file_missing => error.FileNotFound,
        .failed => error.ShellFailure,
    };
}

// ---------------------------------------------------------------------------
// 看门狗：到期就 TerminateProcess，让阻塞中的读写立刻失败
// ---------------------------------------------------------------------------

const Watchdog = struct {
    done: ?pipe.Handle,
    process: pipe.Handle,
    timeout_ms: win32.DWORD,
    /// 只由看门狗线程写、主线程读。
    timed_out: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    /// 建事件 + 起线程。失败时调用方按"崩溃"处理（不会在没有超时保护的情况下读管道）。
    fn start(self: *Watchdog) bool {
        const event = win32.CreateEventW(null, 1, 0, null) orelse return false;
        self.done = event;
        self.thread = std.Thread.spawn(.{}, watch, .{self}) catch {
            _ = win32.CloseHandle(event);
            self.done = null;
            return false;
        };
        return true;
    }

    fn watch(self: *Watchdog) void {
        const result = win32.WaitForSingleObject(self.done.?, self.timeout_ms);
        if (result != win32.WAIT_TIMEOUT) return;
        self.timed_out.store(true, .release);
        _ = win32.TerminateProcess(self.process, 1);
    }

    fn fired(self: *const Watchdog) bool {
        return self.timed_out.load(.acquire);
    }

    fn stop(self: *Watchdog) void {
        if (self.done) |event| _ = win32.SetEvent(event);
        if (self.thread) |thread| thread.join();
        if (self.done) |event| _ = win32.CloseHandle(event);
        self.done = null;
        self.thread = null;
    }
};
