//! 音频层共用的手写 Win32 / COM 声明：只用到多少写多少，没有 @cImport、没有 C shim。
//!
//! 这里只放**类型与系统调用**，不放业务：音频解码在 vendor 的 zig-audio 与
//! `audio/decode.zig`（纯 Zig，不认识 Windows），WASAPI 在 `wasapi.zig`，播放线程
//! 与生命周期在 `player.zig`。
//!
//! 约定与 `ports/src/drag_win.zig` 一致：`HRESULT` 是 i32，成功码 >= 0；GUID 用
//! extern struct 保证与 Win64 ABI 同布局；接口指针的第一格是 vtable 指针。
//!
//! 本文件同时承担"有没有音频能力"的编译期判断：`supported` 为假时 `player.zig`
//! 的 `create` 直接返回 `error.Unsupported`，`providers/audio.zig` 的 `supports`
//! 返回 false（音频 provider 不会在任何非 Windows 目标上声明接手）。

const std = @import("std");
const builtin = @import("builtin");

pub const supported = builtin.os.tag == .windows;

pub const HANDLE = *anyopaque;
pub const LPCWSTR = [*:0]const u16;
pub const DWORD = u32;
pub const UINT = u32;
pub const BOOL = i32;
pub const HRESULT = i32;

pub const GUID = extern struct {
    Data1: u32,
    Data2: u16,
    Data3: u16,
    Data4: [8]u8,
};

/// `WAVEFORMATEX` / `WAVEFORMATEXTENSIBLE` 的**扁平化**声明。
///
/// `mmreg.h` 里的 `WAVEFORMATEX` 是 `#pragma pack(1)` 的 18 字节结构；Zig 的
/// `extern struct` 会补尾部 padding，而 `packed struct` 的 `@sizeOf` 又会被
/// 向上取整到宿主整数宽度。既然我们只需要"一块 40 字节、偏移正确的内存"交给
/// `Initialize`，就把 EXTENSIBLE 的字段摊平成一个 `extern struct`：
/// 关键偏移恰好自然对齐（cbSize@16、valid@18、mask@20、SubFormat@24），
/// 总长 40。comptime 断言在文件末尾兜底。
pub const WAVEFORMATEXTENSIBLE = extern struct {
    wFormatTag: u16,
    nChannels: u16,
    nSamplesPerSec: u32,
    nAvgBytesPerSec: u32,
    nBlockAlign: u16,
    wBitsPerSample: u16,
    cbSize: u16,
    wValidBitsPerSample: u16,
    dwChannelMask: u32,
    SubFormat: GUID,
};

pub fn hresult(comptime value: u32) HRESULT {
    return @bitCast(value);
}

pub const S_OK: HRESULT = hresult(0x0000_0000);
pub const S_FALSE: HRESULT = hresult(0x0000_0001);
pub const E_NOTFOUND: HRESULT = hresult(0x8007_0490);
pub const E_INVALIDARG: HRESULT = hresult(0x8007_0057);
pub const E_POINTER: HRESULT = hresult(0x8000_4003);
pub const E_FAIL: HRESULT = hresult(0x8000_4005);
pub const E_OUTOFMEMORY: HRESULT = hresult(0x8007_000E);
pub const RPC_E_CHANGED_MODE: HRESULT = hresult(0x8001_0106);

pub fn failed(code: HRESULT) bool {
    return code < 0;
}

pub fn hresultFromWin32(code: DWORD) HRESULT {
    return @bitCast(@as(u32, 0x8007_0000) | (code & 0xFFFF));
}

// ---------------------------------------------------------------------------
// kernel32：事件 / 文件
// ---------------------------------------------------------------------------

pub const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

pub const WAIT_OBJECT_0: DWORD = 0;
pub const WAIT_TIMEOUT: DWORD = 258;
pub const WAIT_FAILED: DWORD = 0xFFFF_FFFF;
pub const INFINITE: DWORD = 0xFFFF_FFFF;

pub const GENERIC_READ: DWORD = 0x8000_0000;
pub const FILE_SHARE_READ: DWORD = 0x0000_0001;
pub const FILE_SHARE_WRITE: DWORD = 0x0000_0002;
pub const FILE_SHARE_DELETE: DWORD = 0x0000_0004;
pub const OPEN_EXISTING: DWORD = 3;
pub const FILE_ATTRIBUTE_NORMAL: DWORD = 0x0000_0080;
pub const FILE_BEGIN: DWORD = 0;
pub const FILE_CURRENT: DWORD = 1;
pub const FILE_END: DWORD = 2;

pub const COINIT_MULTITHREADED: DWORD = 0x0;
pub const CLSCTX_ALL: DWORD = 0x17;

pub extern "kernel32" fn CreateEventW(
    attributes: ?*anyopaque,
    manual_reset: BOOL,
    initial_state: BOOL,
    name: ?LPCWSTR,
) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn SetEvent(event: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn CloseHandle(object: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn WaitForSingleObject(object: HANDLE, milliseconds: DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn WaitForMultipleObjects(
    count: DWORD,
    objects: [*]const HANDLE,
    wait_all: BOOL,
    milliseconds: DWORD,
) callconv(.winapi) DWORD;

pub extern "kernel32" fn CreateFileW(
    name: [*:0]const u16,
    access: DWORD,
    share: DWORD,
    security: ?*anyopaque,
    disposition: DWORD,
    flags: DWORD,
    template: ?HANDLE,
) callconv(.winapi) HANDLE;
pub extern "kernel32" fn GetFileSizeEx(file: HANDLE, size: *i64) callconv(.winapi) BOOL;
pub extern "kernel32" fn SetFilePointerEx(
    file: HANDLE,
    distance: i64,
    new_position: ?*i64,
    method: DWORD,
) callconv(.winapi) BOOL;
pub extern "kernel32" fn ReadFile(
    file: HANDLE,
    buffer: [*]u8,
    to_read: DWORD,
    read: *DWORD,
    overlapped: ?*anyopaque,
) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
pub extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;

// ---------------------------------------------------------------------------
// ole32：套间与 COM 激活
// ---------------------------------------------------------------------------

pub extern "ole32" fn CoInitializeEx(reserved: ?*anyopaque, co_init: DWORD) callconv(.winapi) HRESULT;
pub extern "ole32" fn CoUninitialize() callconv(.winapi) void;
pub extern "ole32" fn CoCreateInstance(
    clsid: *const GUID,
    outer: ?*anyopaque,
    context: DWORD,
    iid: *const GUID,
    out: *?*anyopaque,
) callconv(.winapi) HRESULT;
pub extern "ole32" fn CoTaskMemFree(memory: ?*anyopaque) callconv(.winapi) void;

/// 接口指针 → vtable。COM 的 ABI：对象第一格是 vtable 指针。
pub fn vtableOf(comptime Vtbl: type, interface: *anyopaque) *const Vtbl {
    const object: *const *const Vtbl = @ptrCast(@alignCast(interface));
    return object.*;
}

pub fn release(interface: *anyopaque, comptime Vtbl: type) void {
    _ = vtableOf(Vtbl, interface).Release(interface);
}

comptime {
    if (@sizeOf(GUID) != 16) @compileError("GUID 布局不符合 Win64 ABI");
    if (@sizeOf(WAVEFORMATEXTENSIBLE) != 40) @compileError("WAVEFORMATEXTENSIBLE 必须是 40 字节");
    if (@offsetOf(WAVEFORMATEXTENSIBLE, "cbSize") != 16) @compileError("cbSize 偏移错误");
    if (@offsetOf(WAVEFORMATEXTENSIBLE, "wValidBitsPerSample") != 18) @compileError("wValidBits 偏移错误");
    if (@offsetOf(WAVEFORMATEXTENSIBLE, "dwChannelMask") != 20) @compileError("dwChannelMask 偏移错误");
    if (@offsetOf(WAVEFORMATEXTENSIBLE, "SubFormat") != 24) @compileError("SubFormat 偏移错误");
}
