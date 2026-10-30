//! OTTO 拖出口岸：把素材文件交给别的程序。
//!
//! 这是管理器**唯一**的对外出口，两条路共用同一个载荷契约：
//!
//!   * `start()`             —— 同步 OLE 拖放（`SHCreateDataObject` + `SHDoDragDrop`）；
//!   * `copyToClipboard()`   —— OLE 剪贴板（`OleSetClipboard` + `OleFlushClipboard`）；
//!   * `buildHdrop()`        —— 纯函数，构造 `CF_HDROP` 载荷（DROPFILES 头 + 双 NUL
//!                              结尾的 UTF-16LE 路径列表）；`drag_win.setHdrop()` 会把它
//!                              挂到 Shell 数据对象上，拖拽与剪贴板共用同一份载荷。
//!
//! 边界（CHARTER「八、零转义的边界」）：
//!   * 公共面只认「路径字节 + Outcome」，不出现 HWND / PIDL / COM 指针；
//!     `start()` 的 `hwnd` 是**不透明**的，只为让调用方递一个窗口句柄进来。
//!   * Win32 / Shell / COM 全部在 `drag_win.zig`；本文件只有错误分类、Outcome、
//!     CF_HDROP 布局和平台分派。将来拖拽整体搬到 helper 进程时，签名不变。
//!
//! ## 错误三态与"取消不是错误"
//!
//!   * `InvalidPath` —— 路径为空 / 不是合法 WTF-8 / 不存在 / 是目录（不是文件）；
//!   * `OleFailure`  —— COM / Shell / 窗口层面的失败，具体 HRESULT 留在
//!                      `lastFailure().code` 里，只用于日志与排障；
//!   * 取消          —— **不是错误**。用户按 Esc、或在无效目标上松手，都会正常返回
//!                      `Outcome{ .cancelled = true }`。把取消写成 error 会逼调用方
//!                      在日志里记一条假故障，也会让 UI 弹出不该有的提示。
//!
//! ## 线程模型
//!
//! `start()` 必须在**已经/愿意初始化 OLE STA 的 UI 线程**上调用：它内部跑
//! `SHDoDragDrop` 的消息循环，返回时拖拽已经结束。`copyToClipboard()` 与
//! `selftest()` 同样是同步调用，可以在任意线程（内部配对 `OleInitialize`）。
//! 与缩略图口岸"任意线程都行"的承诺不同，拖拽绑定 UI 线程是 OLE 的协议要求。
//!
//! 只依赖 Zig 0.17 标准库，没有 @cImport、没有 C shim、没有外部依赖。

const std = @import("std");
const builtin = @import("builtin");
const win = @import("drag_win.zig");

/// 出口错误。取消不在其中——见文件头。
pub const Error = error{
    OutOfMemory,
    /// 非 Windows 平台，本口岸不上场。
    Unsupported,
    /// 路径为空、含 NUL、不是合法 WTF-8、不存在，或是目录而不是文件。
    InvalidPath,
    /// OLE / Shell / 源窗口失败。HRESULT 见 `lastFailure().code`。
    OleFailure,
};

/// 一次拖拽的结果。正常情况下 `dropped` 与 `cancelled` 恰好一真；
/// 未知的 Shell 返回码走 `OleFailure`，不会构造出"都假"的 Outcome。
pub const Outcome = struct {
    /// 目标接受了数据（`effect != DROPEFFECT_NONE`）。
    dropped: bool = false,
    /// 用户按了 Esc，或松手在无效目标上（Shell 回 S_DROP + NONE）。
    cancelled: bool = false,
    /// 目标返回的 DROPEFFECT 位组：`DROPEFFECT_COPY = 1`，`DROPEFFECT_NONE = 0`。
    /// 原样透出，便于调用方区分"复制"和将来的"移动/链接"。
    effect: u32 = 0,
};

/// 平台诊断码。Windows 上就是 HRESULT（0 = S_OK）；不是公开 API 的输入。
pub const Failure = struct {
    code: i32 = 0,
};

/// 最近一次出口调用在**当前线程**上留下的平台错误码。成功时是 0。
pub fn lastFailure() Failure {
    return .{ .code = win.lastHresult() };
}

/// 同步拖出 N 个文件。返回时拖拽已结束：`dropped` / `cancelled` 恰好一真。
///
/// `hwnd` 是调用方窗口的**不透明句柄**：用来创建隐藏的 16×16 源窗口并抢鼠标捕获。
/// 传 0 也可以（源窗口无 owner），但真实宿主应该把它绑到自己的窗口上。
///
/// 必须在 UI 线程调用；内部会跑 `SHDoDragDrop` 的消息循环。
pub fn start(
    allocator: std.mem.Allocator,
    hwnd: *anyopaque,
    paths: []const []const u8,
) Error!Outcome {
    if (builtin.os.tag != .windows) return error.Unsupported;
    return win.start(allocator, hwnd, paths);
}

/// 把 N 个文件放进剪贴板（`CF_HDROP`），并 `OleFlushClipboard` 成静态数据：
/// 本进程退出后剪贴板仍然可用。
///
/// 这是**用户状态**写入：测试只做参数校验，真实写入留给人工 / 演示命令。
pub fn copyToClipboard(allocator: std.mem.Allocator, paths: []const []const u8) Error!void {
    if (builtin.os.tag != .windows) return error.Unsupported;
    return win.copyToClipboard(allocator, paths);
}

/// 不开窗的自检：构造 Shell 数据对象，像 OLE 放置目标那样查询它——
/// 断言 `CF_HDROP` 可读、内容与 `paths` 一致，且文本类格式被拒。
/// 不写剪贴板、不创建窗口、不调 `DoDragDrop`，可无人值守运行。
///
/// 供 `--drag-selftest` 这类入口使用；不能替代真实拖拽交互测试。
pub fn selftest(allocator: std.mem.Allocator, paths: []const []const u8) Error!void {
    if (builtin.os.tag != .windows) return error.Unsupported;
    return win.selftest(allocator, paths);
}

// ---------------------------------------------------------------------------
// CF_HDROP 布局
// ---------------------------------------------------------------------------

/// shellapi.h 的 POINT：两个 LONG。
pub const POINT = extern struct {
    x: i32,
    y: i32,
};

/// shellapi.h 的 DROPFILES：CF_HDROP 载荷的固定 20 字节头。
///
/// 布局（x86 / x64 相同，全部 4 字节对齐）：
/// ```
/// 偏移 0  pFiles : DWORD   路径列表相对本结构开头的字节偏移，恒为 20
/// 偏移 4  pt     : POINT   拖放点（资源管理器填光标位置；我们填 0,0）
/// 偏移 12 fNC    : BOOL    是否来自文件管理器（FALSE）
/// 偏移 16 fWide  : BOOL    TRUE = 路径是 UTF-16，FALSE = ANSI
/// ```
/// 后面紧跟 `路径1\0路径2\0…\0`（UTF-16LE），最后再补一个 `\0` —— 整个列表
/// 以**双 NUL** 结尾。`fWide = TRUE` 是多字节中文路径能正确到达宿主的前提。
pub const DROPFILES = extern struct {
    pFiles: u32,
    pt: POINT,
    fNC: i32,
    fWide: i32,
};

pub const dropfiles_size: usize = @sizeOf(DROPFILES);

comptime {
    if (@sizeOf(DROPFILES) != 20) @compileError("DROPFILES 必须是 20 字节");
    if (@offsetOf(DROPFILES, "pFiles") != 0) @compileError("DROPFILES.pFiles 必须在偏移 0");
    if (@offsetOf(DROPFILES, "fWide") != 16) @compileError("DROPFILES.fWide 必须在偏移 16");
}

/// 单条路径的 UTF-16 码元上限。Windows 的长路径上限是 32767 个字符；
/// 超过它连 `\\?\` 也表达不了，提前拒绝比让 Shell 截断好。
pub const max_path_units: usize = 32767;

/// 整块载荷的防御上限（64 MiB）。按宪章的 200 文件目标，正常只用到几百 KiB；
/// 超过它更可能是调用方把二进制当路径传进来了，不赌分配器。
pub const max_payload_bytes: usize = 64 * 1024 * 1024;

/// 纯函数：构造 `CF_HDROP` 载荷。
///
/// 返回的字节归调用方，用同一个 allocator 释放。布局严格是：
/// `DROPFILES{ pFiles=20, pt={0,0}, fNC=0, fWide=1 }` +
/// `path1\0path2\0…pathN\0\0`（UTF-16LE）。路径按输入顺序排列，不做去重、
/// 不检查文件是否存在——那是 `start()` / `copyToClipboard()` 的事。
///
/// 空列表、空路径、含 NUL 的路径、非法 WTF-8、超过 `max_path_units` 的路径
/// 都返回 `InvalidPath`。
pub fn buildHdrop(allocator: std.mem.Allocator, paths: []const []const u8) Error![]u8 {
    if (paths.len == 0) return error.InvalidPath;

    var payload: std.ArrayList(u8) = .empty;
    errdefer payload.deinit(allocator);

    // 先占位，最后回填；这样 header 与路径列表在同一个连续块里。
    try payload.appendNTimes(allocator, 0, dropfiles_size);

    for (paths) |path| {
        if (path.len == 0) return error.InvalidPath;
        if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;

        const wide = std.unicode.wtf8ToWtf16LeAllocZ(allocator, path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidWtf8 => return error.InvalidPath,
        };
        defer allocator.free(wide);

        if (wide.len > max_path_units) return error.InvalidPath;

        // 逐码元写 UTF-16LE：不依赖宿主机字节序，也不做对齐假设。
        try payload.ensureUnusedCapacity(allocator, wide.len * 2 + 2);
        for (wide) |unit| {
            var encoded: [2]u8 = undefined;
            std.mem.writeInt(u16, &encoded, unit, .little);
            payload.appendSliceAssumeCapacity(&encoded);
        }
        // 每条路径自己的结尾 NUL。
        payload.appendSliceAssumeCapacity(&.{ 0, 0 });
    }

    // 最后一条路径的 NUL 之后再补一个 NUL：整个列表双 NUL 结尾。
    try payload.appendSlice(allocator, &.{ 0, 0 });

    if (payload.items.len > max_payload_bytes) return error.OutOfMemory;

    const header: DROPFILES = .{
        .pFiles = @intCast(dropfiles_size),
        .pt = .{ .x = 0, .y = 0 },
        .fNC = 0,
        .fWide = 1,
    };
    @memcpy(payload.items[0..dropfiles_size], std.mem.asBytes(&header));

    return payload.toOwnedSlice(allocator);
}
