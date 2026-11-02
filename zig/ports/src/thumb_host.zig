//! OTTO 缩略图隔离客户端：把「系统缩略图 handler」赶出 OTTO 的进程。
//!
//! ## 为什么要有这一层
//!
//! Shell 的缩略图 handler 是**第三方注册的进程内 COM 组件**（PS / AI / Blender、
//! 各种 codec pack 都会往 `HKCR\.<ext>\ShellEx\{E357FCCD-...}` 下挂自己的 DLL）。
//! `IShellItemImageFactory::GetImage` 会把它们加载进调用方进程执行，于是：
//!
//!   * handler 访问越界 → OTTO 一起崩；
//!   * handler 死循环 → 调用线程永远不返回；
//!   * handler 弹一个模态框 → 焦点从 OTTO 手里被抢走。
//!
//! 这些都不是 OTTO 的 bug，也不会因为"写得更小心"而消失——唯一的解法是**换一个进程**。
//! 本模块就是这个进程的客户端：`otto-thumb-host.exe` 崩溃 / 卡死 / 被 TerminateProcess，
//! 死的只是它；OTTO 这边看到的是"请求失败"，列表继续滚动（ROADMAP M4 的第一块）。
//!
//! 这不是推翻宪章的"不引入代理进程"：那是针对**我们自己的调用链**（内部仍然零转义、
//! 直呼 DLL）；对 Shell 这种第三方进程内组件，隔离是唯一能兑现"它崩了不能带走 OTTO"
//! 的做法，和拖拽必须经过 OLE 是同一类"生态逼的"例外。
//!
//! ## 协议与 helper
//!
//! helper 是同一个 Zig 构建产出的第二个 exe（`zig build` 一次出两个），协议见
//! `thumb_host_proto.zig`：
//!
//!     请求：u32 path_len | path(UTF-8)
//!     响应：u8 status | u32 width | u32 height | u32 stride | u32 bytes | BGRA
//!
//! helper 内部照旧调 `ports/thumb`（`thumb_win.get`），没有任何新的解码逻辑；它只多做了
//! 三件事：读帧、写帧、把诊断写 stderr。尺寸是 helper 的启动参数（`--size <px>`），
//! 因为请求帧里刻意不放尺寸——一个 helper 只服务一个边长，换边长就重启（见下）。
//!
//! ## 生命周期
//!
//!   * **懒启动**：第一次 `get()` 才 `CreateProcessW`（`CREATE_NO_WINDOW` + `SW_HIDE`），
//!     之后复用同一个进程；2000 张缩略图不会起 2000 个进程；
//!   * **超时**：每请求最多 `Options.timeout_ms`（默认 3 s）。到期由看门狗线程
//!     `TerminateProcess`，该请求返回 `error.Timeout`，下一个请求用新 helper；
//!   * **崩溃恢复**：写管道失败 / 读到 EOF / 响应头自相矛盾 → 记一次崩溃，重启一次，
//!     **把同一个请求重发**；再失败才返回 `error.ShellFailure`；
//!   * **不留孤儿**：helper 在一个 `KILL_ON_JOB_CLOSE` 的 Job 里，OTTO 自己崩了，
//!     系统也会收掉它（见 `thumb_host_win.zig`）；
//!   * **明确失败**：helper exe 不存在时 `ensurePresent` 返回 `error.HelperUnavailable`，
//!     由调用方打印一行可操作的错误并拒绝启动；**绝不**静默退回进程内（除非显式
//!     `--no-isolation`）。
//!
//! ## API 与错误
//!
//! `get()` / `getWithOptions()` 与 `ports/thumb.zig` 同形：一样的 `Thumbnail`
//! （BGRA8、顶行在前、预乘 alpha、`stride == width * 4`），一样的
//! `NoHandler` / `FileNotFound` / `ShellFailure` 三态，另外多两个**隔离层特有**的错误：
//!
//!   * `error.HelperUnavailable` —— helper 可执行文件缺失 / 起不来 / 路径不可用；
//!   * `error.Timeout`           —— 单个请求超过 `timeout_ms`，helper 已被杀掉。
//!
//! 两个都映射到 UI 的"取图失败"（`--demo-thumbs` 的 `failed`），与 Shell 失败同一格；
//! 分开只是因为日志里要说清楚"是谁的问题"。
//!
//! ## 线程模型
//!
//! 进程级单例，所有请求过一把自旋锁串行（缩略图工作线程本来就只有一条）。像素块由
//! 调用方的 allocator 分配并交给调用方，`deinit()` 只停 helper，不碰已发出的像素。
//!
//! 只依赖 Zig 0.17 标准库与 Win32 手写声明，没有 @cImport。

const std = @import("std");
const builtin = @import("builtin");
const thumb = @import("otto_thumb");
const win = @import("thumb_host_win.zig");

/// 协议常量与编解码（客户端 / helper / 测试共用同一份）。
pub const proto = @import("thumb_host_proto.zig");

/// 一次成功取图的结果，与 `thumb.Thumbnail` 是同一个类型（换后端不改调用方）。
pub const Thumbnail = thumb.Thumbnail;

/// 与 `thumb.Error` 同形，另加隔离层的两个错误（语义见文件头）。
pub const Error = thumb.Error || error{ HelperUnavailable, Timeout };

/// 默认超时：3 秒。Shell 缩略图正常是毫秒级；3 秒还没回来，基本可以断定 handler
/// 卡住了（死循环、等网络、弹了个没人能点掉的框），继续等只会拖住整条队列。
pub const default_timeout_ms: u32 = 3000;

pub const Options = struct {
    /// 单请求超时（毫秒），0 按 1 ms 处理。
    timeout_ms: u32 = default_timeout_ms,
    /// 显式指定 helper 可执行文件。`null` = 先看环境变量 `OTTO_THUMB_HOST`，
    /// 再找当前 exe 同目录的 `otto-thumb-host.exe`（正常安装/构建形态）。
    helper_path: ?[]const u8 = null,
};

/// 隔离层的账。字段都是**进程内累计值**（不随重启清零），测试用前后差值判断。
pub const Stats = struct {
    /// 当前是否有一个活着的 helper。
    running: bool = false,
    /// 当前 helper 的 pid；没有就是 0。
    pid: u32 = 0,
    /// 最近一次被终止的 pid（证明"超时后进程真的被杀了"）。
    last_pid: u32 = 0,
    /// 成功 spawn 的次数（首次 + 每次重启）。
    spawns: u32 = 0,
    /// 因崩溃 / 超时触发的重启次数。
    restarts: u32 = 0,
    /// 写失败 / EOF / 协议失配的次数。
    crashes: u32 = 0,
    /// 请求超时的次数（每次超时都会杀掉并重启 helper）。
    timeouts: u32 = 0,
    /// 走这一层的请求总数。
    requests: u32 = 0,
    /// 当前 helper 服务的边长；没有 helper 时是 0。
    size_px: u32 = 0,
};

/// 取缩略图（默认 3 秒超时）。错误语义见文件头。
pub fn get(allocator: std.mem.Allocator, path_utf8: []const u8, size_px: u32) Error!Thumbnail {
    return getWithOptions(allocator, path_utf8, size_px, .{});
}

/// 带选项的 `get`。`options` 只影响超时与 helper 路径，不改变像素契约。
pub fn getWithOptions(
    allocator: std.mem.Allocator,
    path_utf8: []const u8,
    size_px: u32,
    options: Options,
) Error!Thumbnail {
    if (builtin.os.tag != .windows) return error.Unsupported;
    // 参数校验与 `thumb.get` 保持一致：空路径 / 零尺寸在进管道之前就拒掉。
    if (path_utf8.len == 0) return error.InvalidPath;
    if (size_px == 0) return error.InvalidSize;
    const clamped = @min(size_px, thumb.max_size_px);
    return win.get(allocator, path_utf8, clamped, .{
        .timeout_ms = @max(1, options.timeout_ms),
        .helper_path = options.helper_path,
    });
}

/// 启动前自检：helper 可执行文件是否存在。只查文件，不 spawn。
pub fn ensurePresent(allocator: std.mem.Allocator, options: Options) Error!void {
    if (builtin.os.tag != .windows) return error.Unsupported;
    return win.ensurePresent(allocator, options);
}

/// 停掉 helper（可重复调用）。下一次 `get()` 会重新懒启动。
///
/// **每个进程在退出前都必须调用一次**：单例里还留着 `helper_path` 的堆副本
/// （`thumb_host_win.startLocked` 分配、`terminateLocked` 释放），不调用它，
/// debug / ReleaseSafe 的 SafeAllocator 就会在进程退出时报一条 `leaked`。
/// GUI 在 `thumbs.deinit()` 里调用，无窗口命令（`--preview` 等）在
/// `zig/app/src/commands.zig` 里调用——**CLI 与 GUI 都必须收尾**。
pub fn deinit() void {
    if (builtin.os.tag != .windows) return;
    win.deinit();
}

/// 隔离层的账快照。
pub fn stats() Stats {
    if (builtin.os.tag != .windows) return .{};
    return win.stats();
}

/// 当前 helper 的 pid（诊断与测试用：从外部 TerminateProcess 它，验证自动重启）。
pub fn helperPid() ?u32 {
    if (builtin.os.tag != .windows) return null;
    return win.helperPid();
}
