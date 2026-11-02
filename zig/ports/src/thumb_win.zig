//! OTTO 缩略图口岸的 Windows 后端：`IShellItemImageFactory` + GDI。
//!
//! 手写 Win32 / COM 声明：没有 @cImport、没有 C shim、没有 uuid.lib。
//! 本文件是唯一允许出现 HWND / PIDL / COM 指针的地方（CHARTER「八、零转义的边界」），
//! 出口只有一块 BGRA 字节和 `thumb.Thumbnail`。
//!
//! 调用链（每一步的错误都映射成 `thumb.Error`，HRESULT 存进 `lastHresult()`）：
//!
//!   GetFileAttributesW            文件在不在（便宜，且能精确给出 FileNotFound）
//!   CoInitializeEx(STA)           线程套间；RPC_E_CHANGED_MODE 视为成功且不配对
//!   SHCreateItemFromParsingName   路径 → IShellItemImageFactory
//!   GetImage({size,size}, flags)  → HBITMAP
//!   GetObjectW(BITMAP)            位图尺寸 / 位深
//!   GetDIBits(32bpp, 负高度)      → 顶行在前的 BGRA
//!   normalizeAlpha                → 预乘 alpha（见 thumb.zig）
//!   DeleteObject / Release        释放
//!
//! ## 实测（本机 Windows，2026-10）
//!
//! * `GetDIBits` 的 `biHeight = -h` **确实**输出顶行在前的扫描线；同一 HBITMAP 用
//!   正高度取回的是上下颠倒的。所以不需要在 Zig 里翻转行，省一次整幅拷贝。
//! * 不带 `SIIGBF_THUMBNAILONLY` 时，没有 handler 的文件（`mystery.xyz`）会拿到
//!   一个 48×48 的**通用文件图标**，HRESULT 是 S_OK——"没有 handler"在数据上
//!   与真实缩略图无法区分。这就是默认带 `THUMBNAILONLY` 的原因：它让 GetImage 在
//!   无 handler 时返回 `WTS_E_FAILEDEXTRACTION (0x8004B200)` + 空位图，于是
//!   `NoHandler` 这一态才真的可达（`Options.allow_icon_fallback` 可关掉它）。
//! * 同一枚图标位图的 alpha 是**直通 alpha**（存在"颜色 > alpha"的像素），
//!   所以 `normalizeAlpha` 的预乘分支不是理论洁癖，是实测需要。
//!
//! ## 进程内 handler 的风险
//!
//! Shell 的缩略图 handler 是第三方注册的**进程内 COM 组件**，GetImage 会把它们的
//! DLL 加载进本进程。第三方 handler 崩溃 / 死循环会直接打穿本进程，本文件无法防住；
//! 本版按约定**不做隔离、不做超时**。公共 API 不含任何 COM / 线程状态，就是为了
//! 将来把本文件的调用整体搬进 helper 进程时，调用方无感（详见 thumb.zig 顶部）。
//!
//! 线程模型：`get()` 不持有跨调用的状态，`CoInitializeEx` / `CoUninitialize` 在
//! 每次调用内配对，所以可以在任意线程调用；没有消息循环要求，也不弹窗。

const std = @import("std");
const builtin = @import("builtin");
const thumb = @import("thumb.zig");
const path_win = @import("otto_win_path");

/// 平台闸门：这是 Windows 口岸，其它平台返回 error.Unsupported。
pub const supported = builtin.os.tag == .windows;

// ---------------------------------------------------------------------------
// 手写 Win32 / COM 声明（等价于 windows.h / shobjidl_core.h / wingdi.h 里用到的部分）
// ---------------------------------------------------------------------------

const HANDLE = *anyopaque;
const HBITMAP = *anyopaque;
const HDC = *anyopaque;
const BOOL = i32;
const DWORD = u32;
const HRESULT = i32;
const LONG = i32;
const UINT = u32;

const GUID = extern struct {
    Data1: u32,
    Data2: u16,
    Data3: u16,
    Data4: [8]u8,
};

/// wingdi.h 的 SIZE：两个 LONG。x64 上传值占 8 字节。
const SIZE = extern struct {
    cx: LONG,
    cy: LONG,
};

const RGBQUAD = extern struct {
    rgbBlue: u8,
    rgbGreen: u8,
    rgbRed: u8,
    rgbReserved: u8,
};

const BITMAPINFOHEADER = extern struct {
    biSize: DWORD,
    biWidth: LONG,
    biHeight: LONG,
    biPlanes: u16,
    biBitCount: u16,
    biCompression: DWORD,
    biSizeImage: DWORD,
    biXPelsPerMeter: LONG,
    biYPelsPerMeter: LONG,
    biClrUsed: DWORD,
    biClrImportant: DWORD,
};

const BITMAPINFO = extern struct {
    bmiHeader: BITMAPINFOHEADER,
    bmiColors: [1]RGBQUAD,
};

/// wingdi.h 的 BITMAP：GetObjectW 用它问尺寸和位深。
const BITMAP = extern struct {
    bmType: LONG,
    bmWidth: LONG,
    bmHeight: LONG,
    bmWidthBytes: LONG,
    bmPlanes: u16,
    bmBitsPixel: u16,
    bmBits: ?*anyopaque,
};

/// IShellItemImageFactory 的 vtable。前三格是 IUnknown，第四格是 GetImage。
const IShellItemImageFactoryVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, ?*?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
    GetImage: *const fn (*anyopaque, SIZE, u32, *?HBITMAP) callconv(.winapi) HRESULT,
};

extern "ole32" fn CoInitializeEx(reserved: ?*anyopaque, co_init: DWORD) callconv(.winapi) HRESULT;
extern "ole32" fn CoUninitialize() callconv(.winapi) void;

extern "shell32" fn SHCreateItemFromParsingName(
    name: [*:0]const u16,
    bind_ctx: ?*anyopaque,
    riid: *const GUID,
    out: *?*anyopaque,
) callconv(.winapi) HRESULT;

extern "gdi32" fn CreateCompatibleDC(dc: ?HDC) callconv(.winapi) ?HDC;
extern "gdi32" fn DeleteDC(dc: HDC) callconv(.winapi) BOOL;
extern "gdi32" fn GetObjectW(obj: HANDLE, count: i32, out: *anyopaque) callconv(.winapi) i32;
extern "gdi32" fn GetDIBits(
    dc: ?HDC,
    bitmap: HBITMAP,
    start: UINT,
    lines: UINT,
    bits: [*]u8,
    info: *BITMAPINFO,
    usage: UINT,
) callconv(.winapi) i32;
extern "gdi32" fn DeleteObject(obj: HANDLE) callconv(.winapi) BOOL;

extern "kernel32" fn GetFileAttributesW(name: [*:0]const u16) callconv(.winapi) DWORD;
extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;

// ---------------------------------------------------------------------------
// 常量
// ---------------------------------------------------------------------------

fn hr(comptime value: u32) HRESULT {
    return @bitCast(value);
}

const S_OK: HRESULT = hr(0x0000_0000);
const S_FALSE: HRESULT = hr(0x0000_0001);
const E_NOTIMPL: HRESULT = hr(0x8000_4001);
const E_FAIL: HRESULT = hr(0x8000_4005);
const E_ACCESSDENIED: HRESULT = hr(0x8007_0005);
const E_OUTOFMEMORY: HRESULT = hr(0x8007_000E);
const E_INVALIDARG: HRESULT = hr(0x8007_0057);
const E_UNEXPECTED: HRESULT = hr(0x8000_FFFF);
/// Shell 的"抽不出缩略图"：GetImage 在无 handler / handler 交不出图时返回它。
const WTS_E_FAILEDEXTRACTION: HRESULT = hr(0x8004_B200);
/// 线程已经被初始化到别的套间。任务要求：视为成功，且不要配对 CoUninitialize。
const RPC_E_CHANGED_MODE: HRESULT = hr(0x8001_0106);

const COINIT_APARTMENTTHREADED: DWORD = 0x0000_0002;

const SIIGBF_BIGGERSIZEOK: u32 = 0x0000_0001;
const SIIGBF_RESIZETOFIT: u32 = 0x0000_0000;
const SIIGBF_THUMBNAILONLY: u32 = 0x0000_0008;

const BI_RGB: DWORD = 0;
const DIB_RGB_COLORS: UINT = 0;

const INVALID_FILE_ATTRIBUTES: DWORD = 0xFFFF_FFFF;

const ERROR_FILE_NOT_FOUND: DWORD = 2;
const ERROR_PATH_NOT_FOUND: DWORD = 3;
const ERROR_ACCESS_DENIED: DWORD = 5;
const ERROR_NOT_ENOUGH_MEMORY: DWORD = 8;
const ERROR_INVALID_NAME: DWORD = 123;
const ERROR_BAD_PATHNAME: DWORD = 161;
const ERROR_NOT_SUPPORTED: DWORD = 50;
const ERROR_NOT_FOUND: DWORD = 1168;

const IID_ISHELLITEMIMAGEFACTORY = GUID{
    .Data1 = 0xbcc18b79,
    .Data2 = 0xba16,
    .Data3 = 0x442f,
    .Data4 = .{ 0x80, 0xc4, 0x8a, 0x59, 0xc3, 0x0c, 0x46, 0x3b },
};

/// 单张位图的硬上限（防御第三方 handler 返回离谱尺寸）。4096 的请求尺寸下
/// 正常最多 64 MiB；超过这个数直接当失败，不赌分配器。
const max_bitmap_bytes: usize = 256 * 1024 * 1024;

// ---------------------------------------------------------------------------
// 诊断：当前线程最近一次 HRESULT
// ---------------------------------------------------------------------------

/// 线程局部，因为 `get()` 可以在任意线程调用；日志只关心"我刚这一次调用"。
/// 不是公开 API 的一部分（thumb.zig 只把它包成平台无关的 `Failure.code`）。
threadlocal var last_hresult: HRESULT = S_OK;

pub fn lastHresult() i32 {
    return last_hresult;
}

// ---------------------------------------------------------------------------
// 入口
// ---------------------------------------------------------------------------

pub fn get(
    allocator: std.mem.Allocator,
    path_utf8: []const u8,
    size_px: u32,
    options: thumb.Options,
) thumb.Error!thumb.Thumbnail {
    last_hresult = S_OK;
    if (!supported) return error.Unsupported;
    if (path_utf8.len == 0) {
        last_hresult = E_INVALIDARG;
        return error.InvalidPath;
    }
    if (size_px == 0) {
        last_hresult = E_INVALIDARG;
        return error.InvalidSize;
    }

    // 请求尺寸夹到上限：Shell 本来也给不出更大的图，而第三方 handler 可能相信它。
    const size: LONG = @intCast(@min(size_px, thumb.max_size_px));

    const wide = path_win.wide(allocator, path_utf8, 0) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidPath => return error.InvalidPath,
    };
    defer allocator.free(wide);

    try ensureExists(wide.ptr);

    // 套间：STA。S_FALSE = 本线程已经以同模式初始化过，仍要配对一次；
    // RPC_E_CHANGED_MODE = 别人把它初始化成了别的套间，直接用、**不**配对
    // （配对了就把别人的初始化关掉了）。
    var com_owned = false;
    const init_hr = CoInitializeEx(null, COINIT_APARTMENTTHREADED);
    if (init_hr >= 0) {
        com_owned = true;
    } else if (init_hr != RPC_E_CHANGED_MODE) {
        last_hresult = init_hr;
        return error.ShellFailure;
    }
    defer if (com_owned) CoUninitialize();

    var item: ?*anyopaque = null;
    const create_hr = SHCreateItemFromParsingName(
        wide.ptr,
        null,
        &IID_ISHELLITEMIMAGEFACTORY,
        &item,
    );
    if (create_hr < 0 or item == null) {
        const code: HRESULT = if (create_hr < 0) create_hr else E_UNEXPECTED;
        last_hresult = code;
        return mapCreateItemHresult(code);
    }

    // COM 对象指针 → vtable 指针：接口指针指向的对象，第一格才是 vtable。
    const interface = item.?;
    const vtable = vtableOf(IShellItemImageFactoryVtbl, interface);
    defer _ = vtable.Release(interface);

    var bitmap: ?HBITMAP = null;
    const flags = SIIGBF_BIGGERSIZEOK | SIIGBF_RESIZETOFIT |
        (if (options.allow_icon_fallback) @as(u32, 0) else SIIGBF_THUMBNAILONLY);
    const image_hr = vtable.GetImage(interface, .{ .cx = size, .cy = size }, flags, &bitmap);

    const hbitmap = bitmap orelse {
        // 空位图 = 没有可用的图：S_OK 是"没有 handler"，失败码再按能力缺失/真错误分类。
        last_hresult = image_hr;
        return if (image_hr >= 0) error.NoHandler else mapGetImageHresult(image_hr);
    };
    defer _ = DeleteObject(hbitmap);
    if (image_hr < 0) {
        // 给了图却报失败：不吞，交给调用方当错误（图在 defer 里释放）。
        last_hresult = image_hr;
        return error.ShellFailure;
    }

    return copyOut(allocator, hbitmap);
}

// ---------------------------------------------------------------------------
// 步骤实现
// ---------------------------------------------------------------------------

fn ensureExists(wide: [*:0]const u16) thumb.Error!void {
    const attributes = GetFileAttributesW(wide);
    if (attributes != INVALID_FILE_ATTRIBUTES) return;

    const code = GetLastError();
    last_hresult = hresultFromWin32(code);
    return switch (code) {
        ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND => error.FileNotFound,
        ERROR_INVALID_NAME, ERROR_BAD_PATHNAME => error.InvalidPath,
        else => error.ShellFailure,
    };
}

/// HBITMAP → 顶行在前的 BGRA8。调用方持有 hbitmap，返回后由调用方 DeleteObject。
fn copyOut(allocator: std.mem.Allocator, hbitmap: HBITMAP) thumb.Error!thumb.Thumbnail {
    var source = std.mem.zeroes(BITMAP);
    const copied = GetObjectW(hbitmap, @sizeOf(BITMAP), @ptrCast(&source));
    if (copied != @sizeOf(BITMAP)) {
        last_hresult = lastErrorHresult();
        return error.ShellFailure;
    }
    if (source.bmWidth <= 0 or source.bmHeight <= 0) return error.NoHandler;

    const width: u32 = @intCast(source.bmWidth);
    const height: u32 = @intCast(source.bmHeight);
    const stride: usize = std.math.mul(usize, @as(usize, width), 4) catch return error.ShellFailure;
    const total: usize = std.math.mul(usize, stride, @as(usize, height)) catch return error.ShellFailure;
    if (total > max_bitmap_bytes) {
        last_hresult = E_OUTOFMEMORY;
        return error.ShellFailure;
    }

    const pixels = try allocator.alloc(u8, total);
    errdefer allocator.free(pixels);

    // 负 biHeight = 顶行在前的 DIB。GetDIBits 要求位图没有被选进任何 DC；
    // Shell 给我们的 HBITMAP 没有进过我们的 DC，所以这里只需要一个查询用 DC。
    var info = std.mem.zeroes(BITMAPINFO);
    info.bmiHeader.biSize = @sizeOf(BITMAPINFOHEADER);
    info.bmiHeader.biWidth = source.bmWidth;
    info.bmiHeader.biHeight = -source.bmHeight;
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB;

    const dc = CreateCompatibleDC(null) orelse {
        last_hresult = lastErrorHresult();
        return error.ShellFailure;
    };
    defer _ = DeleteDC(dc);

    const lines = GetDIBits(dc, hbitmap, 0, height, pixels.ptr, &info, DIB_RGB_COLORS);
    if (lines != @as(i32, @intCast(height))) {
        last_hresult = lastErrorHresult();
        return error.ShellFailure;
    }

    // DIB 的 alpha 不可信（可能全 0、可能是直通 alpha）；统一成 nanoui 的预乘契约。
    thumb.normalizeAlpha(pixels);

    return .{
        .pixels = pixels,
        .width = width,
        .height = height,
        .stride = stride,
    };
}

/// 接口指针 → vtable。COM 的 ABI：对象第一格是 vtable 指针，方法在 vtable 里
/// 按声明顺序排列（IUnknown 三格 + 各自的方法）。写错这一层会直接跳到数据上，
/// 所以单独抽出来，只此一处。
fn vtableOf(comptime Vtbl: type, interface: *anyopaque) *const Vtbl {
    const object: *const *const Vtbl = @ptrCast(@alignCast(interface));
    return object.*;
}

// ---------------------------------------------------------------------------
// HRESULT 分类
// ---------------------------------------------------------------------------

fn hresultFromWin32(code: DWORD) HRESULT {
    return @bitCast(@as(u32, 0x8007_0000) | (code & 0xFFFF));
}

/// GDI 不保证每次都写 GetLastError；为 0 时退到 E_UNEXPECTED，免得日志里出现
/// 一个"成功"的 HRESULT 配一条失败。
fn lastErrorHresult() HRESULT {
    const code = GetLastError();
    return if (code == 0) E_UNEXPECTED else hresultFromWin32(code);
}

/// SHCreateItemFromParsingName / QI 失败：文件没了是 FileNotFound，其余是 ShellFailure。
fn mapCreateItemHresult(value: HRESULT) thumb.Error {
    return switch (@as(u32, @bitCast(value))) {
        0x8007_0002, 0x8007_0003 => error.FileNotFound,
        else => error.ShellFailure,
    };
}

/// GetImage 返回失败且没有位图时的分类。
///
/// "能力缺失"一类（handler 不存在 / handler 交不出图）归 `NoHandler`：
///   * WTS_E_FAILEDEXTRACTION —— 无 handler 或无图可交（实测主力信号）；
///   * E_NOTIMPL / E_FAIL —— handler 明确表示做不到；
///   * HRESULT_FROM_WIN32(ERROR_NOT_SUPPORTED / ERROR_NOT_FOUND) —— 格式不支持 / 找不到可用的图。
/// 文件在 GetImage 期间消失（ERROR_FILE_NOT_FOUND / PATH_NOT_FOUND）归 `FileNotFound`。
/// 其余（权限、内存、意外、RPC 断连……）归 `ShellFailure`——"不认识"不等于
/// "没有预览"，不能把真错误说成正常态。
fn mapGetImageHresult(value: HRESULT) thumb.Error {
    const code: u32 = @bitCast(value);
    if (code == @as(u32, @bitCast(WTS_E_FAILEDEXTRACTION)) or
        code == @as(u32, @bitCast(E_NOTIMPL)) or
        code == @as(u32, @bitCast(E_FAIL)) or
        code == @as(u32, @bitCast(hresultFromWin32(ERROR_NOT_SUPPORTED))) or
        code == @as(u32, @bitCast(hresultFromWin32(ERROR_NOT_FOUND))))
    {
        return error.NoHandler;
    }
    if (code == @as(u32, @bitCast(hresultFromWin32(ERROR_FILE_NOT_FOUND))) or
        code == @as(u32, @bitCast(hresultFromWin32(ERROR_PATH_NOT_FOUND))))
    {
        return error.FileNotFound;
    }
    return error.ShellFailure;
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

test "vtableOf 取到的是对象第一格，不是对象本身" {
    // 用一个假对象验证索引：对象第一个机器字 = vtable 指针。
    var fake_vtable = IShellItemImageFactoryVtbl{
        .QueryInterface = undefined,
        .AddRef = undefined,
        .Release = undefined,
        .GetImage = undefined,
    };
    var object = [_]usize{@intFromPtr(&fake_vtable)};
    const recovered = vtableOf(IShellItemImageFactoryVtbl, @ptrCast(&object));
    try std.testing.expectEqual(@intFromPtr(&fake_vtable), @intFromPtr(recovered));
}

test "GetImage 的 HRESULT 三态分类" {
    // 无 handler / 能力缺失 → NoHandler
    try std.testing.expectEqual(thumb.Error.NoHandler, mapGetImageHresult(WTS_E_FAILEDEXTRACTION));
    try std.testing.expectEqual(thumb.Error.NoHandler, mapGetImageHresult(E_NOTIMPL));
    try std.testing.expectEqual(thumb.Error.NoHandler, mapGetImageHresult(E_FAIL));
    try std.testing.expectEqual(thumb.Error.NoHandler, mapGetImageHresult(hresultFromWin32(ERROR_NOT_SUPPORTED)));
    // 文件没了 → FileNotFound（保留"文件消失了"这一态）
    try std.testing.expectEqual(thumb.Error.FileNotFound, mapGetImageHresult(hresultFromWin32(ERROR_FILE_NOT_FOUND)));
    // 其它 COM 故障 → ShellFailure
    try std.testing.expectEqual(thumb.Error.ShellFailure, mapGetImageHresult(E_ACCESSDENIED));
    try std.testing.expectEqual(thumb.Error.ShellFailure, mapGetImageHresult(E_OUTOFMEMORY));
    try std.testing.expectEqual(thumb.Error.ShellFailure, mapGetImageHresult(hr(0x8001_0108)));
}

test "SHCreateItem 失败：缺文件 vs 其它" {
    try std.testing.expectEqual(thumb.Error.FileNotFound, mapCreateItemHresult(hresultFromWin32(ERROR_FILE_NOT_FOUND)));
    try std.testing.expectEqual(thumb.Error.FileNotFound, mapCreateItemHresult(hresultFromWin32(ERROR_PATH_NOT_FOUND)));
    try std.testing.expectEqual(thumb.Error.ShellFailure, mapCreateItemHresult(E_ACCESSDENIED));
}

test "hresultFromWin32 的合成规则" {
    try std.testing.expectEqual(@as(u32, 0x8007_0002), @as(u32, @bitCast(hresultFromWin32(2))));
    try std.testing.expectEqual(@as(u32, 0x8007_0032), @as(u32, @bitCast(hresultFromWin32(50))));
}
