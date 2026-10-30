//! OTTO 拖出口岸的 Windows 后端：`SHCreateDataObject` + `SHDoDragDrop` + OLE 剪贴板。
//!
//! 手写 Win32 / COM 声明：没有 @cImport、没有 C shim、没有 uuid.lib。
//! 本文件是唯一允许出现 HWND / PIDL / COM 指针的地方（CHARTER「八、零转义的边界」）。
//!
//! ## 调用链（拖拽）
//!
//! ```
//! GetFileAttributesW                确认每个路径存在且是文件（否则 InvalidPath）
//! OleInitialize(STA)                拖放要求 OLE STA
//! SHParseDisplayName                路径 → 绝对 PIDL
//! SHCreateDataObject(NULL, N, …)    → Explorer 同款 Shell IDataObject（CFSTR_SHELLIDLIST）
//! SetData(CF_HDROP, buildHdrop(…))  → 补上宿主真正认的文件列表格式
//! 隐藏 16×16 源窗口 + AttachThreadInput + SetCapture
//! SHDoDragDrop(hwnd, data, NULL, COPY)   psrc=NULL：由 Shell 创建标准放置源（Vista+）
//! Release / DestroyWindow / OleUninitialize
//! ```
//!
//! **为什么是 Shell 数据对象**：Melodyne 3.2.2 是 32 位宿主；它接受 Explorer 的
//! Shell 数据对象，而手写 `CF_HDROP` 的 x64 源正是已知会触发它 Bug Reporter 的路径。
//! 但 `SHCreateDataObject` 默认只保证 `CFSTR_SHELLIDLIST`，`CF_HDROP` 必须用
//! `IDataObject::SetData` 补上——这一步就是 `drag.buildHdrop` 的生产用途。
//!
//! ## 源窗口
//!
//! 不弹窗、不抢焦点：`WS_POPUP` + `WS_EX_TOOLWINDOW` + `WS_EX_LAYERED`，alpha = 1，
//! `SW_SHOWNOACTIVATE`。它只做一件事——把鼠标捕获从宿主（Electron/Chromium）手里
//! 接过来，让 `SHDoDragDrop` 收到终止拖拽的按键释放。`AttachThreadInput` 连到前台
//! 线程，`SetCapture` 后立刻用 `GetCapture()` 验证；拿不到捕获就失败，不赌。
//!
//! ## 剪贴板
//!
//! `OleSetClipboard` + `OleFlushClipboard`，数据对象同上（`CF_HDROP` + Shell IDList）。
//! flush 把数据变成静态的，本进程退出后粘贴仍然有效。
//!
//! 未挂 `CFSTR_PREFERREDDROPEFFECT`：`allowedEffects = DROPEFFECT_COPY` 已把拖拽锁成
//! 复制，Explorer 粘贴在缺省时也按复制处理。需要时在 `setHdrop` 之后用同一个
//! `IDataObject::SetData` 补一个 DWORD 即可，通道已经就绪。
//!
//! 只依赖 Zig 0.17 标准库。

const std = @import("std");
const builtin = @import("builtin");
const drag = @import("drag.zig");

pub const supported = builtin.os.tag == .windows;

// ---------------------------------------------------------------------------
// 手写 Win32 / COM 声明（用到多少写多少）
// ---------------------------------------------------------------------------

const HWND = *anyopaque;
const HGLOBAL = *anyopaque;
const LPCWSTR = [*:0]const u16;
const DWORD = u32;
const UINT = u32;
const BOOL = i32;
const HRESULT = i32;

const GUID = extern struct {
    Data1: u32,
    Data2: u16,
    Data3: u16,
    Data4: [8]u8,
};

const FORMATETC = extern struct {
    cfFormat: u16,
    ptd: ?*anyopaque,
    dwAspect: u32,
    lindex: i32,
    tymed: u32,
};

/// STGMEDIUM 只用到 HGLOBAL，但联合体必须保住指针宽度与整体布局。
const STGMEDIUM_Value = extern union {
    hGlobal: ?HGLOBAL,
    pstm: ?*anyopaque,
};

const STGMEDIUM = extern struct {
    tymed: u32,
    u: STGMEDIUM_Value,
    pUnkForRelease: ?*anyopaque,
};

const IDataObjectVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, ?*?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
    GetData: *const fn (*anyopaque, ?*FORMATETC, ?*STGMEDIUM) callconv(.winapi) HRESULT,
    GetDataHere: *const fn (*anyopaque, ?*FORMATETC, ?*STGMEDIUM) callconv(.winapi) HRESULT,
    QueryGetData: *const fn (*anyopaque, ?*FORMATETC) callconv(.winapi) HRESULT,
    GetCanonicalFormatEtc: *const fn (*anyopaque, ?*FORMATETC, ?*FORMATETC) callconv(.winapi) HRESULT,
    SetData: *const fn (*anyopaque, ?*FORMATETC, ?*STGMEDIUM, BOOL) callconv(.winapi) HRESULT,
    EnumFormatEtc: *const fn (*anyopaque, DWORD, ?*?*anyopaque) callconv(.winapi) HRESULT,
    DAdvise: *const fn (*anyopaque, ?*FORMATETC, DWORD, ?*anyopaque, ?*DWORD) callconv(.winapi) HRESULT,
    DUnadvise: *const fn (*anyopaque, DWORD) callconv(.winapi) HRESULT,
    EnumDAdvise: *const fn (*anyopaque, ?*?*anyopaque) callconv(.winapi) HRESULT,
};

extern "kernel32" fn GlobalAlloc(flags: UINT, bytes: usize) callconv(.winapi) ?HGLOBAL;
extern "kernel32" fn GlobalLock(memory: ?HGLOBAL) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GlobalUnlock(memory: ?HGLOBAL) callconv(.winapi) BOOL;
extern "kernel32" fn GlobalFree(memory: ?HGLOBAL) callconv(.winapi) ?HGLOBAL;
extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) DWORD;
extern "kernel32" fn GetFileAttributesW(name: [*:0]const u16) callconv(.winapi) DWORD;

extern "user32" fn CreateWindowExW(
    ex_style: DWORD,
    class_name: LPCWSTR,
    window_name: ?LPCWSTR,
    style: DWORD,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    parent: ?HWND,
    menu: ?*anyopaque,
    instance: ?*anyopaque,
    param: ?*anyopaque,
) callconv(.winapi) ?HWND;
extern "user32" fn DestroyWindow(window: HWND) callconv(.winapi) BOOL;
extern "user32" fn GetCursorPos(point: *drag.POINT) callconv(.winapi) BOOL;
extern "user32" fn GetForegroundWindow() callconv(.winapi) ?HWND;
extern "user32" fn GetWindowThreadProcessId(window: ?HWND, process_id: ?*DWORD) callconv(.winapi) DWORD;
extern "user32" fn AttachThreadInput(attach: DWORD, attach_to: DWORD, state: BOOL) callconv(.winapi) BOOL;
extern "user32" fn SetLayeredWindowAttributes(window: HWND, key: DWORD, alpha: u8, flags: DWORD) callconv(.winapi) BOOL;
extern "user32" fn ShowWindow(window: HWND, command: i32) callconv(.winapi) BOOL;
extern "user32" fn SetCapture(window: HWND) callconv(.winapi) ?HWND;
extern "user32" fn GetCapture() callconv(.winapi) ?HWND;
extern "user32" fn ReleaseCapture() callconv(.winapi) BOOL;

extern "ole32" fn OleInitialize(reserved: ?*anyopaque) callconv(.winapi) HRESULT;
extern "ole32" fn OleUninitialize() callconv(.winapi) void;
extern "ole32" fn CoTaskMemFree(memory: ?*anyopaque) callconv(.winapi) void;
extern "ole32" fn OleSetClipboard(data_object: ?*anyopaque) callconv(.winapi) HRESULT;
extern "ole32" fn OleFlushClipboard() callconv(.winapi) HRESULT;
extern "ole32" fn ReleaseStgMedium(medium: *STGMEDIUM) callconv(.winapi) void;

extern "shell32" fn SHParseDisplayName(
    name: [*:0]const u16,
    bind_ctx: ?*anyopaque,
    pidl: *?*anyopaque,
    attributes_in: u32,
    attributes_out: ?*u32,
) callconv(.winapi) HRESULT;
extern "shell32" fn SHCreateDataObject(
    pidl_folder: ?*const anyopaque,
    cidl: u32,
    apidl: ?[*]const ?*anyopaque,
    inner: ?*anyopaque,
    riid: *const GUID,
    out: *?*anyopaque,
) callconv(.winapi) HRESULT;
extern "shell32" fn SHDoDragDrop(
    window: ?HWND,
    data_object: ?*anyopaque,
    drop_source: ?*anyopaque,
    allowed_effects: DWORD,
    effect: *DWORD,
) callconv(.winapi) HRESULT;

// ---------------------------------------------------------------------------
// 常量
// ---------------------------------------------------------------------------

fn hr(comptime value: u32) HRESULT {
    return @bitCast(value);
}

const S_OK: HRESULT = hr(0x0000_0000);
const E_FAIL: HRESULT = hr(0x8000_4005);
const E_UNEXPECTED: HRESULT = hr(0x8000_FFFF);
const E_INVALIDARG: HRESULT = hr(0x8007_0057);
const E_OUTOFMEMORY: HRESULT = hr(0x8007_000E);
const RPC_E_CHANGED_MODE: HRESULT = hr(0x8001_0106);
const DRAGDROP_S_DROP: HRESULT = hr(0x0004_0100);
const DRAGDROP_S_CANCEL: HRESULT = hr(0x0004_0101);

const CF_HDROP: u16 = 15;
const CF_UNICODETEXT: u16 = 13;
const TYMED_HGLOBAL: u32 = 1;
const DVASPECT_CONTENT: u32 = 1;
const DROPEFFECT_NONE: u32 = 0;
const DROPEFFECT_COPY: u32 = 1;

const GMEM_MOVEABLE: UINT = 0x0002;
const WS_POPUP: DWORD = 0x8000_0000;
const WS_EX_TOOLWINDOW: DWORD = 0x0000_0080;
const WS_EX_LAYERED: DWORD = 0x0008_0000;
const WS_EX_NOACTIVATE: DWORD = 0x0800_0000;
const SW_SHOWNOACTIVATE: i32 = 4;
const LWA_ALPHA: DWORD = 0x0000_0002;
const FILE_ATTRIBUTE_DIRECTORY: DWORD = 0x0000_0010;
const INVALID_FILE_ATTRIBUTES: DWORD = 0xFFFF_FFFF;

const IID_IDATAOBJECT = GUID{
    .Data1 = 0x0000010E,
    .Data2 = 0x0000,
    .Data3 = 0x0000,
    .Data4 = .{ 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 },
};

const STATIC_CLASS = w("STATIC");

fn w(comptime ascii: []const u8) [ascii.len:0]u16 {
    var out: [ascii.len:0]u16 = undefined;
    for (ascii, 0..) |ch, i| out[i] = ch;
    out[ascii.len] = 0;
    return out;
}

// ---------------------------------------------------------------------------
// 诊断与公共辅助
// ---------------------------------------------------------------------------

threadlocal var last_hresult: HRESULT = S_OK;

pub fn lastHresult() i32 {
    return last_hresult;
}

fn hresultFromWin32(code: DWORD) HRESULT {
    return @bitCast(@as(u32, 0x8007_0000) | (code & 0xFFFF));
}

fn failWith(code: HRESULT) drag.Error {
    last_hresult = code;
    return error.OleFailure;
}

fn invalidPath(code: HRESULT) drag.Error {
    last_hresult = code;
    return error.InvalidPath;
}

/// 接口指针 → vtable。COM 的 ABI：对象第一格是 vtable 指针。
fn vtableOf(comptime Vtbl: type, interface: *anyopaque) *const Vtbl {
    const object: *const *const Vtbl = @ptrCast(@alignCast(interface));
    return object.*;
}

fn formatEtc(format: u16) FORMATETC {
    return .{
        .cfFormat = format,
        .ptd = null,
        .dwAspect = DVASPECT_CONTENT,
        .lindex = -1,
        .tymed = TYMED_HGLOBAL,
    };
}

// ---------------------------------------------------------------------------
// 入口：拖拽
// ---------------------------------------------------------------------------

pub fn start(
    allocator: std.mem.Allocator,
    hwnd: *anyopaque,
    paths: []const []const u8,
) drag.Error!drag.Outcome {
    last_hresult = S_OK;
    if (!supported) return error.Unsupported;
    if (paths.len == 0) return invalidPath(E_INVALIDARG);
    try validatePaths(allocator, paths);

    const owned = try oleInit(true);
    defer if (owned) OleUninitialize();

    const data = try createShellDataObject(allocator, paths);
    defer data.release();
    try setHdrop(data, allocator, paths);

    const source_window = createSourceWindow(hwnd) orelse return error.OleFailure;
    defer source_window.destroy();

    var effect: DWORD = DROPEFFECT_NONE;
    const result = SHDoDragDrop(source_window.hwnd, data.object, null, DROPEFFECT_COPY, &effect);

    if (result == DRAGDROP_S_CANCEL) return .{ .cancelled = true, .effect = effect };
    if (result == DRAGDROP_S_DROP) {
        // 目标接受 → effect 非 0；在无效目标/空白处松手 → S_DROP + NONE，等同取消。
        const dropped = effect != DROPEFFECT_NONE;
        return .{ .dropped = dropped, .cancelled = !dropped, .effect = effect };
    }
    return failWith(result);
}

// ---------------------------------------------------------------------------
// 入口：剪贴板
// ---------------------------------------------------------------------------

pub fn copyToClipboard(allocator: std.mem.Allocator, paths: []const []const u8) drag.Error!void {
    last_hresult = S_OK;
    if (!supported) return error.Unsupported;
    if (paths.len == 0) return invalidPath(E_INVALIDARG);
    // 参数校验必须在任何剪贴板动作之前：测试只跑失败路径，绝不改写用户剪贴板。
    try validatePaths(allocator, paths);

    // 剪贴板容忍线程已是别的套间（Shell 数据对象是敏捷的），此时不配对 Uninitialize。
    const owned = try oleInit(false);
    defer if (owned) OleUninitialize();

    const data = try createShellDataObject(allocator, paths);
    defer data.release();
    try setHdrop(data, allocator, paths);

    const set_hr = OleSetClipboard(data.object);
    if (set_hr < 0) return failWith(set_hr);
    const flush_hr = OleFlushClipboard();
    if (flush_hr < 0) return failWith(flush_hr);
}

// ---------------------------------------------------------------------------
// 入口：不开窗自检
// ---------------------------------------------------------------------------

/// 构造 Shell 数据对象并像放置目标一样查询它：`CF_HDROP` 必须可读、头部
/// `pFiles=20` / `fWide=1`、路径逐条与输入一致、列表以双 NUL 结尾；
/// `CF_UNICODETEXT` 必须不被接受。不写剪贴板、不开窗、不进拖拽循环。
pub fn selftest(allocator: std.mem.Allocator, paths: []const []const u8) drag.Error!void {
    last_hresult = S_OK;
    if (!supported) return error.Unsupported;
    if (paths.len == 0) return invalidPath(E_INVALIDARG);
    try validatePaths(allocator, paths);

    const owned = try oleInit(false);
    defer if (owned) OleUninitialize();

    const data = try createShellDataObject(allocator, paths);
    defer data.release();
    try setHdrop(data, allocator, paths);

    var hdrop = formatEtc(CF_HDROP);
    const query_hr = data.vtbl.QueryGetData(data.object, &hdrop);
    if (query_hr != S_OK) return failWith(query_hr);

    // QueryGetData 的语义：S_OK = 支持，S_FALSE = 不支持（成功码但语义是"没有"）。
    var text = formatEtc(CF_UNICODETEXT);
    if (data.vtbl.QueryGetData(data.object, &text) == S_OK) return failWith(E_UNEXPECTED);

    var medium = std.mem.zeroes(STGMEDIUM);
    const get_hr = data.vtbl.GetData(data.object, &hdrop, &medium);
    if (get_hr != S_OK) return failWith(get_hr);
    defer ReleaseStgMedium(&medium);
    if (medium.tymed != TYMED_HGLOBAL) return failWith(E_UNEXPECTED);

    const locked = GlobalLock(medium.u.hGlobal) orelse return failWith(E_FAIL);
    defer _ = GlobalUnlock(medium.u.hGlobal);

    const base: [*]const u8 = @ptrCast(locked);
    const header: *const drag.DROPFILES = @ptrCast(@alignCast(base));
    if (header.pFiles != @as(u32, @intCast(drag.dropfiles_size)) or header.fWide != 1) {
        return failWith(E_UNEXPECTED);
    }

    var cursor: [*:0]const u16 = @ptrCast(@alignCast(base + drag.dropfiles_size));
    for (paths) |path| {
        const expected = std.unicode.wtf8ToWtf16LeAllocZ(allocator, path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidWtf8 => return invalidPath(E_INVALIDARG),
        };
        defer allocator.free(expected);

        const actual = std.mem.span(cursor);
        if (!samePath(expected, actual)) return failWith(E_UNEXPECTED);
        cursor += actual.len + 1;
    }
    // 最后一条路径的 NUL 之后必须还有一个 NUL：双 NUL 结尾。
    if (cursor[0] != 0) return failWith(E_UNEXPECTED);
}

fn samePath(expected: []const u16, actual: []const u16) bool {
    if (expected.len != actual.len) return false;
    for (expected, actual) |left, right| {
        if (left == right) continue;
        if (asciiLower(left) != asciiLower(right)) return false;
    }
    return true;
}

fn asciiLower(unit: u16) u16 {
    return if (unit >= 'A' and unit <= 'Z') unit + 32 else unit;
}

// ---------------------------------------------------------------------------
// OLE 套间 / 路径校验
// ---------------------------------------------------------------------------

/// 返回 true = 这次调用自己初始化了 OLE，必须配对 `OleUninitialize`。
/// `require_sta`：拖拽必须是 STA；剪贴板/自检允许线程已经是别的套间。
fn oleInit(require_sta: bool) drag.Error!bool {
    const init_hr = OleInitialize(null);
    if (init_hr >= 0) return true;
    if (!require_sta and init_hr == RPC_E_CHANGED_MODE) return false;
    last_hresult = init_hr;
    return error.OleFailure;
}

fn validatePaths(allocator: std.mem.Allocator, paths: []const []const u8) drag.Error!void {
    for (paths) |path| {
        if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) {
            return invalidPath(E_INVALIDARG);
        }
        const wide = std.unicode.wtf8ToWtf16LeAllocZ(allocator, path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidWtf8 => return invalidPath(E_INVALIDARG),
        };
        defer allocator.free(wide);

        const attributes = GetFileAttributesW(wide.ptr);
        if (attributes == INVALID_FILE_ATTRIBUTES) return invalidPath(hresultFromWin32(GetLastError()));
        if ((attributes & FILE_ATTRIBUTE_DIRECTORY) != 0) return invalidPath(E_INVALIDARG);
    }
}

// ---------------------------------------------------------------------------
// Shell 数据对象 + CF_HDROP
// ---------------------------------------------------------------------------

const ShellDataObject = struct {
    object: *anyopaque,
    vtbl: *const IDataObjectVtbl,

    fn release(self: ShellDataObject) void {
        _ = self.vtbl.Release(self.object);
    }
};

/// 路径 → 绝对 PIDL 数组 → `SHCreateDataObject`。
/// `pidlFolder = NULL`（桌面根）时 `apidl` 放全限定 PIDL，这是 CIDLData 文档明确
/// 支持的用法；不同目录的多个文件因此能进同一个数据对象。
fn createShellDataObject(
    allocator: std.mem.Allocator,
    paths: []const []const u8,
) drag.Error!ShellDataObject {
    const pidls = try allocator.alloc(?*anyopaque, paths.len);
    defer allocator.free(pidls);
    var parsed: usize = 0;
    defer for (pidls[0..parsed]) |pidl| CoTaskMemFree(pidl);

    for (paths, 0..) |path, index| {
        const wide = std.unicode.wtf8ToWtf16LeAllocZ(allocator, path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidWtf8 => return invalidPath(E_INVALIDARG),
        };
        defer allocator.free(wide);

        var pidl: ?*anyopaque = null;
        const parse_hr = SHParseDisplayName(wide.ptr, null, &pidl, 0, null);
        if (parse_hr < 0 or pidl == null) {
            return failWith(if (parse_hr < 0) parse_hr else E_FAIL);
        }
        pidls[index] = pidl;
        parsed += 1;
    }

    var object: ?*anyopaque = null;
    const create_hr = SHCreateDataObject(
        null,
        @intCast(paths.len),
        pidls.ptr,
        null,
        &IID_IDATAOBJECT,
        &object,
    );
    if (create_hr < 0 or object == null) {
        return failWith(if (create_hr < 0) create_hr else E_UNEXPECTED);
    }
    return .{ .object = object.?, .vtbl = vtableOf(IDataObjectVtbl, object.?) };
}

/// 把 `drag.buildHdrop` 的载荷挂成 `CF_HDROP`。这是关键格式（只认 CF_HDROP 的
/// 宿主靠它），失败就是失败，不吞。
fn setHdrop(
    data: ShellDataObject,
    allocator: std.mem.Allocator,
    paths: []const []const u8,
) drag.Error!void {
    const bytes = drag.buildHdrop(allocator, paths) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidPath => return invalidPath(E_INVALIDARG),
        else => return failWith(E_UNEXPECTED),
    };
    defer allocator.free(bytes);

    const memory = GlobalAlloc(GMEM_MOVEABLE, bytes.len) orelse return failWith(E_OUTOFMEMORY);
    const locked = GlobalLock(memory) orelse {
        _ = GlobalFree(memory);
        return failWith(E_OUTOFMEMORY);
    };
    const destination: [*]u8 = @ptrCast(locked);
    @memcpy(destination[0..bytes.len], bytes);
    _ = GlobalUnlock(memory);

    var format = formatEtc(CF_HDROP);
    var medium = STGMEDIUM{
        .tymed = TYMED_HGLOBAL,
        .u = .{ .hGlobal = memory },
        .pUnkForRelease = null,
    };
    // fRelease = TRUE：成功后数据对象接管这块 HGLOBAL。
    const set_hr = data.vtbl.SetData(data.object, &format, &medium, 1);
    if (set_hr < 0) {
        _ = GlobalFree(memory); // 失败时所有权仍在我们这边
        return failWith(set_hr);
    }
}

// ---------------------------------------------------------------------------
// 隐藏的 16×16 源窗口
// ---------------------------------------------------------------------------

const SourceWindow = struct {
    hwnd: HWND,
    /// 被 AttachThreadInput 的前台线程 id；0 = 没挂。
    attached_thread: DWORD = 0,

    fn destroy(self: SourceWindow) void {
        if (GetCapture() == self.hwnd) _ = ReleaseCapture();
        if (self.attached_thread != 0) {
            _ = AttachThreadInput(GetCurrentThreadId(), self.attached_thread, 0);
        }
        _ = DestroyWindow(self.hwnd);
    }
};

/// 用系统 `STATIC` 类建一个 16×16 的隐藏源窗口（不注册我们自己的窗口类，
/// 也就不需要 WNDPROC / WNDCLASSW）。全程 NOACTIVATE：不弹窗、不抢焦点。
fn createSourceWindow(owner: *anyopaque) ?SourceWindow {
    var cursor = drag.POINT{ .x = 0, .y = 0 };
    _ = GetCursorPos(&cursor);

    const owner_handle: ?HWND = if (@intFromPtr(owner) == 0) null else @ptrCast(@alignCast(owner));
    const window = CreateWindowExW(
        WS_EX_TOOLWINDOW | WS_EX_LAYERED | WS_EX_NOACTIVATE,
        &STATIC_CLASS,
        null,
        WS_POPUP,
        cursor.x - 8,
        cursor.y - 8,
        16,
        16,
        owner_handle,
        null,
        null,
        null,
    ) orelse {
        last_hresult = hresultFromWin32(GetLastError());
        return null;
    };

    var result = SourceWindow{ .hwnd = window };

    // 把输入队列挂到前台线程：宿主（Chromium）手里的捕获才会交出来。
    const current_thread = GetCurrentThreadId();
    const foreground_thread = GetWindowThreadProcessId(GetForegroundWindow(), null);
    if (foreground_thread != 0 and foreground_thread != current_thread) {
        if (AttachThreadInput(current_thread, foreground_thread, 1) == 0) {
            last_hresult = hresultFromWin32(GetLastError());
            _ = DestroyWindow(window);
            return null;
        }
        result.attached_thread = foreground_thread;
    }

    _ = SetLayeredWindowAttributes(window, 0, 1, LWA_ALPHA);
    _ = ShowWindow(window, SW_SHOWNOACTIVATE);
    _ = SetCapture(window);

    if (GetCapture() != window) {
        result.destroy();
        last_hresult = E_FAIL;
        return null;
    }
    return result;
}

// ---------------------------------------------------------------------------
// 编译期布局自检（写错 vtable / 结构体在运行期就是跳数据）
// ---------------------------------------------------------------------------

comptime {
    if (@sizeOf(FORMATETC) != 32 or @offsetOf(FORMATETC, "cfFormat") != 0) {
        @compileError("FORMATETC 布局不符合 Win64 ABI");
    }
}
