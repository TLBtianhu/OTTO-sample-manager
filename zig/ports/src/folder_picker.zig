//! 文件夹选择口岸（Windows）：`IFileOpenDialog` 的"选择文件夹"模式，阻塞在
//! 调用线程上，返回用户选中的**绝对文件系统路径**（UTF-8）。
//!
//! ```
//! CoInitializeEx(APARTMENTTHREADED)     线程套间（见下）
//! CoCreateInstance(CLSID_FileOpenDialog) → IFileOpenDialog
//! SetOptions(FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST)
//! Show(owner_hwnd)                      模态；owner 就是主窗口
//! GetResult                              → IShellItem
//! GetDisplayName(SIGDN_FILESYSPATH)      → 宽字符绝对路径
//! CoTaskMemFree + 转 UTF-8
//! Release
//! CoUninitialize（仅当这次调用初始化了套间）
//! ```
//!
//! ## 套间纪律（与 `thumb_win.zig` 同一条）
//!
//! UI 线程可能本来就是 STA，也可能完全没初始化 COM：
//!   * `CoInitializeEx(APARTMENTTHREADED)` 返回 `S_OK` / `S_FALSE`（含 S_FALSE，本线程
//!     之前已以同模式初始化）→ 这次调用自己**拥有**一次初始化，返回前配对
//!     `CoUninitialize`；
//!   * `RPC_E_CHANGED_MODE`（线程已在别的套间）→ 对话框仍可用，但**不配对**
//!     `CoUninitialize`：配对了就把别人的初始化关掉了；
//!   * 其它失败 → `error.OleFailure`，细节看 `lastHresult()`。
//!
//! ## 错误语义
//!
//! 用户按取消（`Show` 返回 `HRESULT_FROM_WIN32(ERROR_CANCELLED)`）是 `error.Cancelled`
//! ——**不是失败**，调用方不应报错、不应弹窗。真正的失败只有 `error.OleFailure`
//! （COM 创建/显示/取结果失败）与 `error.OutOfMemory`。
//!
//! ## 测试与无头运行
//!
//! 真实对话框无法自动化：它需要桌面、用户点击和一条带消息循环的 STA 线程。
//! 本文件只测纯逻辑（选项位组合、取消码分类、宽字符路径转换、环境变量开关），
//! 真实选择只能人工验证。
//!
//! `OTTO_NO_DIALOG=1`（或任何非空且非 `"0"` 的值）会让 `pick` 在**创建 COM 对象
//! 之前**返回 `error.Cancelled`，并往 stdout 打一行——这是给 `--nanoui-snapshot` /
//! `--nanoui-script` 的无头点击验收用的开关，保证测试期间绝不弹窗。没有窗口句柄
//! 时（`pickForWindow(null)`）也直接失败而不是让 Shell 弹一个无主对话框。
//!
//! 手写 COM vtable，没有 `@cImport`、没有 C shim、没有 uuid.lib。

const std = @import("std");
const builtin = @import("builtin");

pub const supported = builtin.os.tag == .windows;

pub const Error = error{ OutOfMemory, OleFailure, Cancelled };

// ---------------------------------------------------------------------------
// 手写 Win32 / COM 声明
// ---------------------------------------------------------------------------

const HWND = *anyopaque;
const HRESULT = i32;
const DWORD = u32;
const UINT = u32;

const GUID = extern struct {
    Data1: u32,
    Data2: u16,
    Data3: u16,
    Data4: [8]u8,
};

const COINIT_APARTMENTTHREADED: DWORD = 0x0000_0002;
const CLSCTX_INPROC_SERVER: DWORD = 0x0000_0001;

fn hr(comptime value: u32) HRESULT {
    return @bitCast(value);
}

const S_OK: HRESULT = hr(0x0000_0000);
const E_UNEXPECTED: HRESULT = hr(0x8000_FFFF);
const E_INVALIDARG: HRESULT = hr(0x8007_0057);
const RPC_E_CHANGED_MODE: HRESULT = hr(0x8001_0106);
/// `HRESULT_FROM_WIN32(ERROR_CANCELLED)`：用户按了取消。
const HRESULT_CANCELLED: HRESULT = hr(0x8007_04C7);

/// 文件夹选择模式：只选目录、必须是真实文件系统路径、路径必须存在。
pub const FOS_PICKFOLDERS: DWORD = 0x0000_0020;
pub const FOS_FORCEFILESYSTEM: DWORD = 0x0000_0040;
pub const FOS_PATHMUSTEXIST: DWORD = 0x0000_0800;

/// `SIGDN_FILESYSPATH`：要绝对文件系统路径，不要显示名 / URL。
const SIGDN_FILESYSPATH: DWORD = 0x8005_8000;

const CLSID_FILEOPENDIALOG = GUID{
    .Data1 = 0xDC1C_5A9C,
    .Data2 = 0xE88A,
    .Data3 = 0x4DDE,
    .Data4 = .{ 0xA5, 0xA1, 0x60, 0xF8, 0x2A, 0x20, 0xAE, 0xF7 },
};

const IID_IFILEOPENDIALOG = GUID{
    .Data1 = 0xD57C_7288,
    .Data2 = 0xD4AD,
    .Data3 = 0x4768,
    .Data4 = .{ 0xBE, 0x02, 0x9D, 0x96, 0x95, 0x32, 0xD9, 0x60 },
};

/// `IFileOpenDialog` 的 vtable：IUnknown(3) + IModalWindow(Show) + IFileDialog(23)
/// + IFileOpenDialog(2)。只给真正要调的三格写签名，其余按 ABI 留占位指针——
/// 顺序错一格就会调错函数，所以这里把完整的 29 格都列出来。
const IFileOpenDialogVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, ?*?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
    // IModalWindow
    Show: *const fn (*anyopaque, ?HWND) callconv(.winapi) HRESULT,
    // IFileDialog
    SetFileTypes: *const anyopaque,
    SetFileTypeIndex: *const anyopaque,
    GetFileTypeIndex: *const anyopaque,
    Advise: *const anyopaque,
    Unadvise: *const anyopaque,
    SetOptions: *const fn (*anyopaque, DWORD) callconv(.winapi) HRESULT,
    GetOptions: *const anyopaque,
    SetDefaultFolder: *const anyopaque,
    SetFolder: *const anyopaque,
    GetFolder: *const anyopaque,
    GetCurrentSelection: *const anyopaque,
    SetFileName: *const anyopaque,
    GetFileName: *const anyopaque,
    SetTitle: *const anyopaque,
    SetOkButtonLabel: *const anyopaque,
    SetFileNameLabel: *const anyopaque,
    GetResult: *const fn (*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT,
    AddPlace: *const anyopaque,
    SetDefaultExtension: *const anyopaque,
    Close: *const anyopaque,
    SetClientGuid: *const anyopaque,
    ClearClientData: *const anyopaque,
    SetFilter: *const anyopaque,
    // IFileOpenDialog
    GetResults: *const anyopaque,
    GetSelectedItems: *const anyopaque,
};

/// `IShellItem` 的 vtable：IUnknown(3) + BindToHandler + GetParent + GetDisplayName
/// + GetAttributes + Compare。只需要 GetDisplayName（第 7 格）。
const IShellItemVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, ?*?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
    BindToHandler: *const anyopaque,
    GetParent: *const anyopaque,
    GetDisplayName: *const fn (*anyopaque, DWORD, *?[*:0]u16) callconv(.winapi) HRESULT,
    GetAttributes: *const anyopaque,
    Compare: *const anyopaque,
};

extern "ole32" fn CoInitializeEx(reserved: ?*anyopaque, co_init: DWORD) callconv(.winapi) HRESULT;
extern "ole32" fn CoUninitialize() callconv(.winapi) void;
extern "ole32" fn CoCreateInstance(
    rclsid: *const GUID,
    unk_outer: ?*anyopaque,
    cls_context: DWORD,
    riid: *const GUID,
    out: *?*anyopaque,
) callconv(.winapi) HRESULT;
extern "ole32" fn CoTaskMemFree(memory: ?*anyopaque) callconv(.winapi) void;

// ---------------------------------------------------------------------------
// 诊断
// ---------------------------------------------------------------------------

/// 当前线程最近一次 COM 失败的 HRESULT（0 = 没有失败）。只用于日志/排障。
threadlocal var last_hresult: HRESULT = S_OK;

pub fn lastHresult() i32 {
    return last_hresult;
}

fn failWith(code: HRESULT) Error {
    last_hresult = code;
    return error.OleFailure;
}

/// 接口指针 → vtable。COM 的 ABI：对象第一格是 vtable 指针。
fn vtableOf(comptime Vtbl: type, interface: *anyopaque) *const Vtbl {
    const object: *const *const Vtbl = @ptrCast(@alignCast(interface));
    return object.*;
}

// ---------------------------------------------------------------------------
// 公共 API
// ---------------------------------------------------------------------------

/// 阻塞：弹出"选择文件夹"对话框，返回用户选的绝对路径（UTF-8）。
/// 取消返回 `error.Cancelled`。返回的切片归调用方，用同一个 allocator 释放。
pub fn pick(allocator: std.mem.Allocator, owner_hwnd: *anyopaque) Error![]u8 {
    return pickImpl(allocator, owner_hwnd);
}

/// `pick` 的"窗口句柄可能为空"版本：只给无头运行（`--nanoui-snapshot` /
/// `--nanoui-script`）与将来非窗口宿主用。句柄为空时不会调用 `Show`，直接失败，
/// 避免 Shell 在没有 owner 的情况下弹出一个没人能关掉的对话框。
pub fn pickForWindow(allocator: std.mem.Allocator, owner_hwnd: ?*anyopaque) Error![]u8 {
    return pickImpl(allocator, owner_hwnd);
}

fn pickImpl(allocator: std.mem.Allocator, owner_hwnd: ?*anyopaque) Error![]u8 {
    last_hresult = S_OK;
    if (!supported) return error.OleFailure;

    // 验收钩子：无头点击时必须在创建任何 COM 对象之前退出，绝不能真的弹窗。
    if (try dialogSuppressed(allocator)) {
        printSuppressed();
        return error.Cancelled;
    }

    const owner: HWND = if (owner_hwnd) |raw| @ptrCast(raw) else {
        last_hresult = E_UNEXPECTED;
        return error.OleFailure;
    };

    // 套间：S_FALSE（1）也算"这次调用拥有一次初始化"，仍要配对 CoUninitialize；
    // RPC_E_CHANGED_MODE 是别人初始化过，直接用、**不**配对（见文件头）。
    var com_owned = false;
    const init_hr = CoInitializeEx(null, COINIT_APARTMENTTHREADED);
    if (init_hr >= 0) {
        com_owned = true;
    } else if (init_hr != RPC_E_CHANGED_MODE) {
        return failWith(init_hr);
    }
    defer if (com_owned) CoUninitialize();

    var dialog: ?*anyopaque = null;
    const create_hr = CoCreateInstance(
        &CLSID_FILEOPENDIALOG,
        null,
        CLSCTX_INPROC_SERVER,
        &IID_IFILEOPENDIALOG,
        &dialog,
    );
    if (create_hr < 0 or dialog == null) {
        return failWith(if (create_hr < 0) create_hr else E_UNEXPECTED);
    }
    const interface = dialog.?;
    const vtbl = vtableOf(IFileOpenDialogVtbl, interface);
    defer _ = vtbl.Release(interface);

    // 只设三个位：选择文件夹、只要文件系统路径、路径必须存在。
    const options_hr = vtbl.SetOptions(interface, folderOptions());
    if (options_hr < 0) return failWith(options_hr);

    const show_hr = vtbl.Show(interface, owner);
    if (show_hr < 0) {
        last_hresult = show_hr;
        if (isCancelled(show_hr)) return error.Cancelled;
        return error.OleFailure;
    }

    var item: ?*anyopaque = null;
    const result_hr = vtbl.GetResult(interface, &item);
    if (result_hr < 0 or item == null) {
        last_hresult = if (result_hr < 0) result_hr else E_UNEXPECTED;
        // 部分 Windows 版本把取消放在 GetResult 而不是 Show：同样不是失败。
        if (isCancelled(result_hr)) return error.Cancelled;
        return error.OleFailure;
    }
    const item_vtbl = vtableOf(IShellItemVtbl, item.?);
    defer _ = item_vtbl.Release(item.?);

    var display: ?[*:0]u16 = null;
    const name_hr = item_vtbl.GetDisplayName(item.?, SIGDN_FILESYSPATH, &display);
    if (name_hr < 0 or display == null) {
        return failWith(if (name_hr < 0) name_hr else E_UNEXPECTED);
    }
    const wide = display.?;
    defer CoTaskMemFree(@as(?*anyopaque, @ptrCast(wide)));
    return wideToUtf8(allocator, wide);
}

/// 三个选项位的组合。单独成函数是为了能纯测位组合（对话框本身不可自动化）。
pub fn folderOptions() DWORD {
    return FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST;
}

/// `Show` 的"用户取消"判定。取消不是失败：调用方据此静默返回。
pub fn isCancelled(result: HRESULT) bool {
    return result == HRESULT_CANCELLED;
}

/// 宽字符绝对路径 → UTF-8。空串按失败处理（拿不到路径时 Shell 不该给空串）。
///
/// 公开只为了测试（真实对话框不可自动化）：这是纯转换，不碰 COM。
pub fn wideToUtf8(allocator: std.mem.Allocator, wide: [*:0]const u16) Error![]u8 {
    const span = std.mem.span(wide);
    if (span.len == 0) {
        last_hresult = E_UNEXPECTED;
        return error.OleFailure;
    }
    return std.unicode.wtf16LeToWtf8Alloc(allocator, span) catch error.OutOfMemory;
}

/// `OTTO_NO_DIALOG` 的取值判定：非空且不等于 `"0"` 才算抑制。
pub fn envEnabled(value: ?[]const u8) bool {
    const text = value orelse return false;
    if (text.len == 0) return false;
    return !std.mem.eql(u8, text, "0");
}

fn dialogSuppressed(allocator: std.mem.Allocator) Error!bool {
    var map = std.process.Environ.createMap(.{ .block = .global }, allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // 环境块异常时按"没有开关"处理：不能因为读不到变量就替换成取消。
        error.Unexpected => return false,
    };
    defer map.deinit();
    return envEnabled(map.get("OTTO_NO_DIALOG"));
}

fn printSuppressed() void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const line = "otto-lite: folder picker suppressed by OTTO_NO_DIALOG=1 -> Cancelled\n";
    std.Io.File.stdout().writeStreamingAll(io, line) catch {};
}

// ---------------------------------------------------------------------------
// 测试：只测纯逻辑；真实对话框只能人工验证（见文件头）
// ---------------------------------------------------------------------------

const testing = std.testing;

test "文件夹选项：三个位都在，且不误开别的位" {
    const options = folderOptions();
    try testing.expectEqual(@as(DWORD, 0x0000_0860), options);
    try testing.expect(options & FOS_PICKFOLDERS != 0);
    try testing.expect(options & FOS_FORCEFILESYSTEM != 0);
    try testing.expect(options & FOS_PATHMUSTEXIST != 0);
    // 三项各不相同：组合不是把同一个位或了三次。
    try testing.expect(FOS_PICKFOLDERS != FOS_FORCEFILESYSTEM);
    try testing.expect(FOS_FORCEFILESYSTEM != FOS_PATHMUSTEXIST);
}

test "取消码：只有 HRESULT_FROM_WIN32(ERROR_CANCELLED) 算取消" {
    try testing.expect(isCancelled(HRESULT_CANCELLED));
    try testing.expectEqual(@as(i32, -2147023673), HRESULT_CANCELLED);
    try testing.expect(!isCancelled(S_OK));
    try testing.expect(!isCancelled(E_INVALIDARG));
    try testing.expect(!isCancelled(hr(0x8000_4005))); // E_FAIL：真失败，不是取消
}

test "环境变量开关：非空且非 0 才抑制" {
    try testing.expect(!envEnabled(null));
    try testing.expect(!envEnabled(""));
    try testing.expect(!envEnabled("0"));
    try testing.expect(envEnabled("1"));
    try testing.expect(envEnabled("yes"));
}

test "宽字符路径转 UTF-8：中文、空格、反斜杠原样保留" {
    const source = "C:\\素材\\Kick 01.wav";
    const wide = try std.unicode.wtf8ToWtf16LeAllocZ(testing.allocator, source);
    defer testing.allocator.free(wide);

    const converted = try wideToUtf8(testing.allocator, wide.ptr);
    defer testing.allocator.free(converted);
    try testing.expectEqualStrings(source, converted);
    try testing.expect(std.mem.indexOfScalar(u8, converted, 0) == null);
}

test "宽字符空路径：按失败处理，不返回空切片" {
    const wide = [_:0]u16{};
    try testing.expectError(error.OleFailure, wideToUtf8(testing.allocator, &wide));
}
