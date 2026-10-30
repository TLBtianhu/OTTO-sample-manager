//! WASAPI 输出（共享模式、事件驱动）的**手写 COM 层**。
//!
//! 没有 @cImport、没有 C shim、没有 uuid.lib：GUID 与 vtable 全部照 Windows SDK
//! 的顺序手写（与 `ports/src/drag_win.zig` 同一种做法——接口指针第一格是 vtable，
//! 每个方法都是 `callconv(.winapi)` 的函数指针）。
//!
//! ## 调用链（`open` 一次，`player.zig` 的播放线程里执行）
//!
//! ```
//! CoInitializeEx(NULL, COINIT_MULTITHREADED)      ← 由 player.zig 的线程做
//! CoCreateInstance(CLSID_MMDeviceEnumerator)     → IMMDeviceEnumerator
//!   GetDefaultAudioEndpoint(eRender, eConsole)   → IMMDevice
//!   IMMDevice::Activate(IID_IAudioClient)        → IAudioClient
//!   IAudioClient::Initialize(SHARED, EVENTCALLBACK, 0, 0, 源格式, NULL)
//!   IAudioClient::SetEventHandle(hEvent)         ← 事件驱动
//!   IAudioClient::GetService(IID_IAudioRenderClient)
//! ```
//!
//! **不做重采样**：`Initialize` 拿到的就是 WAV 的源采样率 / 声道 / 位深（多声道
//! 已在解码层下混成 ≤2 声道）。共享模式下音频引擎负责混音到设备格式；如果引擎
//! 不接受这个格式，`Initialize` 失败，调用方把它记成 `none.failed` 并带出 HRESULT，
//! 绝不自作主张改成别的格式。
//!
//! ## 缓冲循环（`player.zig`）
//!
//! ```
//! WaitForMultipleObjects([音频事件, 命令事件])
//!   GetCurrentPadding → 可写帧数 → GetBuffer → 拷贝/补静音 → ReleaseBuffer
//! ```
//!
//! 本文件不碰线程、不碰 UI，只拥有设备句柄。释放顺序：render client → client。

const std = @import("std");
const win = @import("win32.zig");

pub const Error = error{ NoAudioEndpoint, DeviceFailure };

// 这些 HRESULT 只用于诊断与"没有端点"的区分；失败一律映射成 Error.DeviceFailure。
const AUDCLNT_E_DEVICE_INVALIDATED: i32 = win.hresult(0x8889_0004);
const AUDCLNT_E_UNSUPPORTED_FORMAT: i32 = win.hresult(0x8889_0008);
const AUDCLNT_E_EXCLUSIVE_MODE_NOT_ALLOWED: i32 = win.hresult(0x8889_000E);

/// 所有 COM 失败共用的诊断槽：播放线程写、调用方在 ready 之后读。
/// 只存最近一次，够 `--preview` / `--play-test` 打一行 HRESULT。
var last_hresult: std.atomic.Value(i32) = .init(0);

pub fn lastHresult() i32 {
    return last_hresult.load(.acquire);
}

fn fail(code: i32) Error {
    last_hresult.store(code, .release);
    return error.DeviceFailure;
}

fn noteFailure(code: i32) void {
    last_hresult.store(code, .release);
}

pub fn describeFailure() []const u8 {
    return switch (lastHresult()) {
        AUDCLNT_E_DEVICE_INVALIDATED => "设备已失效",
        AUDCLNT_E_UNSUPPORTED_FORMAT => "共享模式不支持该格式",
        AUDCLNT_E_EXCLUSIVE_MODE_NOT_ALLOWED => "设备不容许共享模式",
        else => "WASAPI 初始化失败",
    };
}

// ---------------------------------------------------------------------------
// GUID / 常量
// ---------------------------------------------------------------------------

fn guid(d1: u32, d2: u16, d3: u16, d4: [8]u8) win.GUID {
    return .{ .Data1 = d1, .Data2 = d2, .Data3 = d3, .Data4 = d4 };
}

const CLSID_MMDeviceEnumerator = guid(
    0xBCDE0395,
    0xE52F,
    0x467C,
    .{ 0x8E, 0x3D, 0xC4, 0x57, 0x92, 0x91, 0x69, 0x2E },
);
const IID_IMMDeviceEnumerator = guid(
    0xA95664D2,
    0x9614,
    0x4F35,
    .{ 0xA7, 0x46, 0xDE, 0x8D, 0xB6, 0x36, 0x17, 0xE6 },
);
const IID_IAudioClient = guid(
    0x1CB9AD4C,
    0xDBFA,
    0x4C32,
    .{ 0xB1, 0x78, 0xC2, 0xF5, 0x68, 0xA7, 0x03, 0xB2 },
);
const IID_IAudioRenderClient = guid(
    0xF294ACFC,
    0x3146,
    0x4483,
    .{ 0xA7, 0xBF, 0xAD, 0xDC, 0xA7, 0xC2, 0x60, 0xE2 },
);
const KSDATAFORMAT_SUBTYPE_PCM = guid(
    0x0000_0001,
    0x0000,
    0x0010,
    .{ 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71 },
);
const KSDATAFORMAT_SUBTYPE_IEEE_FLOAT = guid(
    0x0000_0003,
    0x0000,
    0x0010,
    .{ 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71 },
);

const AUDCLNT_SHAREMODE_SHARED: u32 = 0;
const AUDCLNT_STREAMFLAGS_EVENTCALLBACK: u32 = 0x0004_0000;
/// 共享模式下的"让音频引擎自己转"：采样率/位深/声道由系统混音器转换，
/// 我们**不做重采样**。没有这两个标志时，非混音格式（比如 22050 Hz 单声道）
/// 会在 `Initialize` 直接得到 AUDCLNT_E_UNSUPPORTED_FORMAT。
const AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY: u32 = 0x0800_0000;
const AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM: u32 = 0x8000_0000;

const E_RENDER: u32 = 0; // EDataFlow::eRender
const E_CONSOLE: u32 = 0; // ERole::eConsole

// WAVEFORMATEXTENSIBLE 的常量（与 wav.zig 的磁盘 GUID 顺序一致，但这里用 SDK 结构）。
const WAVE_FORMAT_EXTENSIBLE: u16 = 0xFFFE;
const SPEAKER_FRONT_LEFT: u32 = 0x1;
const SPEAKER_FRONT_RIGHT: u32 = 0x2;
const SPEAKER_FRONT_CENTER: u32 = 0x4;

// ---------------------------------------------------------------------------
// vtable：顺序必须与 Windows SDK 一致（错的顺序在运行期就是跳到别的函数）
// ---------------------------------------------------------------------------

const IMMDeviceEnumeratorVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const win.GUID, *?*anyopaque) callconv(.winapi) win.HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
    EnumAudioEndpoints: *const fn (*anyopaque, u32, u32, *?*anyopaque) callconv(.winapi) win.HRESULT,
    GetDefaultAudioEndpoint: *const fn (*anyopaque, u32, u32, *?*anyopaque) callconv(.winapi) win.HRESULT,
    GetDevice: *const fn (*anyopaque, [*:0]const u16, *?*anyopaque) callconv(.winapi) win.HRESULT,
    RegisterEndpointNotificationCallback: *const fn (*anyopaque, ?*anyopaque) callconv(.winapi) win.HRESULT,
    UnregisterEndpointNotificationCallback: *const fn (*anyopaque, ?*anyopaque) callconv(.winapi) win.HRESULT,
};

const IMMDeviceVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const win.GUID, *?*anyopaque) callconv(.winapi) win.HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
    Activate: *const fn (*anyopaque, *const win.GUID, u32, ?*anyopaque, *?*anyopaque) callconv(.winapi) win.HRESULT,
    OpenPropertyStore: *const fn (*anyopaque, u32, *?*anyopaque) callconv(.winapi) win.HRESULT,
    GetId: *const fn (*anyopaque, *?[*:0]u16) callconv(.winapi) win.HRESULT,
    GetState: *const fn (*anyopaque, *u32) callconv(.winapi) win.HRESULT,
};

const IAudioClientVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const win.GUID, *?*anyopaque) callconv(.winapi) win.HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
    Initialize: *const fn (
        *anyopaque,
        u32, // AUDCLNT_SHAREMODE
        u32, // stream flags
        i64, // hnsBufferDuration
        i64, // hnsPeriodicity
        *const win.WAVEFORMATEXTENSIBLE,
        ?*const win.GUID,
    ) callconv(.winapi) win.HRESULT,
    GetBufferSize: *const fn (*anyopaque, *u32) callconv(.winapi) win.HRESULT,
    GetStreamLatency: *const fn (*anyopaque, *i64) callconv(.winapi) win.HRESULT,
    GetCurrentPadding: *const fn (*anyopaque, *u32) callconv(.winapi) win.HRESULT,
    IsFormatSupported: *const fn (
        *anyopaque,
        u32,
        *const win.WAVEFORMATEXTENSIBLE,
        *?*win.WAVEFORMATEXTENSIBLE,
    ) callconv(.winapi) win.HRESULT,
    GetMixFormat: *const fn (*anyopaque, *?*win.WAVEFORMATEXTENSIBLE) callconv(.winapi) win.HRESULT,
    GetDevicePeriod: *const fn (*anyopaque, *i64, *i64) callconv(.winapi) win.HRESULT,
    Start: *const fn (*anyopaque) callconv(.winapi) win.HRESULT,
    Stop: *const fn (*anyopaque) callconv(.winapi) win.HRESULT,
    Reset: *const fn (*anyopaque) callconv(.winapi) win.HRESULT,
    SetEventHandle: *const fn (*anyopaque, win.HANDLE) callconv(.winapi) win.HRESULT,
    GetService: *const fn (*anyopaque, *const win.GUID, *?*anyopaque) callconv(.winapi) win.HRESULT,
};

const IAudioRenderClientVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const win.GUID, *?*anyopaque) callconv(.winapi) win.HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
    GetBuffer: *const fn (*anyopaque, u32, *?[*]u8) callconv(.winapi) win.HRESULT,
    ReleaseBuffer: *const fn (*anyopaque, u32, u32) callconv(.winapi) win.HRESULT,
};

// ---------------------------------------------------------------------------
// 源格式：WAVEFORMATEXTENSIBLE（PCM / float 共用）
// ---------------------------------------------------------------------------

/// 用 WAV 的源参数拼一个 40 字节的 WAVEFORMATEXTENSIBLE。
///
/// 为什么总是 EXTENSIBLE：24/32 位与 float 用普通 WAVEFORMATEX 在共享模式下
/// 会被引擎判成"格式不支持"；扩展头 + KSDATAFORMAT_SUBTYPE 才是设备能认的形状。
/// `channels` 只会是 1 或 2（多声道已在 `wav.zig` 下混）。
pub fn buildFormat(
    channels: u16,
    sample_rate: u32,
    bits: u16,
    float: bool,
) win.WAVEFORMATEXTENSIBLE {
    std.debug.assert(channels == 1 or channels == 2);
    std.debug.assert(bits == 8 or bits == 16 or bits == 24 or bits == 32);
    const bytes_per_sample: u16 = bits / 8;
    const block_align: u16 = channels * bytes_per_sample;
    const sub = if (float) KSDATAFORMAT_SUBTYPE_IEEE_FLOAT else KSDATAFORMAT_SUBTYPE_PCM;
    return .{
        .wFormatTag = WAVE_FORMAT_EXTENSIBLE,
        .nChannels = channels,
        .nSamplesPerSec = sample_rate,
        .nAvgBytesPerSec = sample_rate * @as(u32, block_align),
        .nBlockAlign = block_align,
        .wBitsPerSample = bits,
        .cbSize = 22,
        .wValidBitsPerSample = bits,
        .dwChannelMask = if (channels == 1) SPEAKER_FRONT_CENTER else (SPEAKER_FRONT_LEFT | SPEAKER_FRONT_RIGHT),
        .SubFormat = sub,
    };
}

// ---------------------------------------------------------------------------
// 设备会话
// ---------------------------------------------------------------------------

/// 一个已初始化、尚未 Start 的共享模式渲染客户端。
/// 只由 `player.zig` 的播放线程创建、使用、释放；它本身没有线程。
pub const Render = struct {
    client: *anyopaque,
    client_vtbl: *const IAudioClientVtbl,
    render: *anyopaque,
    render_vtbl: *const IAudioRenderClientVtbl,
    buffer_frames: u32,

    /// 建枚举器 → 默认渲染端点 → IAudioClient → Initialize → SetEventHandle →
    /// IAudioRenderClient。失败时设备句柄全部释放，`lastHresult()` 留下原因。
    pub fn open(format: *const win.WAVEFORMATEXTENSIBLE, event: win.HANDLE) Error!Render {
        noteFailure(win.S_OK);
        if (!win.supported) return fail(win.E_FAIL);

        var enumerator_ptr: ?*anyopaque = null;
        const create_hr = win.CoCreateInstance(
            &CLSID_MMDeviceEnumerator,
            null,
            win.CLSCTX_ALL,
            &IID_IMMDeviceEnumerator,
            &enumerator_ptr,
        );
        if (win.failed(create_hr) or enumerator_ptr == null) {
            return fail(if (win.failed(create_hr)) create_hr else win.E_POINTER);
        }
        const enumerator = enumerator_ptr.?;
        const enumerator_vtbl = win.vtableOf(IMMDeviceEnumeratorVtbl, enumerator);
        defer win.release(enumerator, IMMDeviceEnumeratorVtbl);

        var device_ptr: ?*anyopaque = null;
        const endpoint_hr = enumerator_vtbl.GetDefaultAudioEndpoint(enumerator, E_RENDER, E_CONSOLE, &device_ptr);
        if (win.failed(endpoint_hr) or device_ptr == null) {
            // E_NOTFOUND：这台机器压根没有渲染端点。它不是"坏了"，但预览层能做的
            // 只有谢绝；`--play-test` 会把它翻译成 no_audio_endpoint（退出码 0）。
            if (endpoint_hr == win.E_NOTFOUND) {
                noteFailure(endpoint_hr);
                return error.NoAudioEndpoint;
            }
            return fail(if (win.failed(endpoint_hr)) endpoint_hr else win.E_POINTER);
        }
        const device = device_ptr.?;
        const device_vtbl = win.vtableOf(IMMDeviceVtbl, device);
        defer win.release(device, IMMDeviceVtbl);

        var client_ptr: ?*anyopaque = null;
        const activate_hr = device_vtbl.Activate(device, &IID_IAudioClient, win.CLSCTX_ALL, null, &client_ptr);
        if (win.failed(activate_hr) or client_ptr == null) {
            return fail(if (win.failed(activate_hr)) activate_hr else win.E_POINTER);
        }
        const client = client_ptr.?;
        const client_vtbl = win.vtableOf(IAudioClientVtbl, client);
        errdefer win.release(client, IAudioClientVtbl);

        // 共享模式：缓冲时长与周期都传 0，由音频引擎给默认值。事件驱动要求
        // EVENTCALLBACK，随后 SetEventHandle 把系统事件和这个句柄绑定。
        // AUTOCONVERTPCM + SRC_DEFAULT_QUALITY：源采样率/位深/声道交给系统转换，
        // 失败时（老系统/策略）仍然老老实实报 HRESULT，不自己写重采样。
        const init_hr = client_vtbl.Initialize(
            client,
            AUDCLNT_SHAREMODE_SHARED,
            AUDCLNT_STREAMFLAGS_EVENTCALLBACK |
                AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM |
                AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
            0,
            0,
            format,
            null,
        );
        if (win.failed(init_hr)) return fail(init_hr);

        var buffer_frames: u32 = 0;
        const size_hr = client_vtbl.GetBufferSize(client, &buffer_frames);
        if (win.failed(size_hr) or buffer_frames == 0) {
            return fail(if (win.failed(size_hr)) size_hr else win.E_FAIL);
        }

        const event_hr = client_vtbl.SetEventHandle(client, event);
        if (win.failed(event_hr)) return fail(event_hr);

        var render_ptr: ?*anyopaque = null;
        const service_hr = client_vtbl.GetService(client, &IID_IAudioRenderClient, &render_ptr);
        if (win.failed(service_hr) or render_ptr == null) {
            return fail(if (win.failed(service_hr)) service_hr else win.E_POINTER);
        }

        return .{
            .client = client,
            .client_vtbl = client_vtbl,
            .render = render_ptr.?,
            .render_vtbl = win.vtableOf(IAudioRenderClientVtbl, render_ptr.?),
            .buffer_frames = buffer_frames,
        };
    }

    /// 释放 render client 与 audio client。设备/枚举器在 `open` 里已释放。
    pub fn close(self: Render) void {
        win.release(self.render, IAudioRenderClientVtbl);
        win.release(self.client, IAudioClientVtbl);
    }

    pub fn start(self: Render) Error!void {
        const hr = self.client_vtbl.Start(self.client);
        if (win.failed(hr)) return fail(hr);
    }

    /// 停止并回到 0 位置。失败只记诊断：调用方正在停播/退出，不能再抛。
    pub fn stop(self: Render) void {
        const stop_hr = self.client_vtbl.Stop(self.client);
        if (win.failed(stop_hr)) noteFailure(stop_hr);
        const reset_hr = self.client_vtbl.Reset(self.client);
        if (win.failed(reset_hr)) noteFailure(reset_hr);
    }

    pub fn padding(self: Render) Error!u32 {
        var value: u32 = 0;
        const hr = self.client_vtbl.GetCurrentPadding(self.client, &value);
        if (win.failed(hr)) return fail(hr);
        return value;
    }

    pub fn getBuffer(self: Render, frames: u32) Error![*]u8 {
        var data: ?[*]u8 = null;
        const hr = self.render_vtbl.GetBuffer(self.render, frames, &data);
        if (win.failed(hr) or data == null) {
            return fail(if (win.failed(hr)) hr else win.E_POINTER);
        }
        return data.?;
    }

    pub fn releaseBuffer(self: Render, frames: u32) void {
        const hr = self.render_vtbl.ReleaseBuffer(self.render, frames, 0);
        if (win.failed(hr)) noteFailure(hr);
    }
};

// ---------------------------------------------------------------------------
// 编译期布局自检
// ---------------------------------------------------------------------------

comptime {
    if (@sizeOf(win.WAVEFORMATEXTENSIBLE) != 40) @compileError("格式头必须是 40 字节");
    // vtable 的槽位数与顺序无法用类型系统证明；用关键方法的偏移做一次抽查：
    // IAudioRenderClient::GetBuffer 是第 3 个槽（0..2 是 QI/AddRef/Release）。
    if (@offsetOf(IAudioRenderClientVtbl, "GetBuffer") != 3 * @sizeOf(*const anyopaque)) {
        @compileError("IAudioRenderClient vtable 顺序错误");
    }
    if (@offsetOf(IAudioClientVtbl, "GetService") != 14 * @sizeOf(*const anyopaque)) {
        @compileError("IAudioClient vtable 顺序错误");
    }
    if (@offsetOf(IMMDeviceEnumeratorVtbl, "GetDefaultAudioEndpoint") != 4 * @sizeOf(*const anyopaque)) {
        @compileError("IMMDeviceEnumerator vtable 顺序错误");
    }
}
