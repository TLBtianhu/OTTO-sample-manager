//! Media Foundation 的**接口声明**：GUID 常量、手写 vtable、系统函数 extern。
//!
//! 与 `mf.zig` 的分工：本文件只说"系统长什么样"，不决定"失败怎么办"。
//! 生命周期、错误分类、文件路径、属性读写、读样本循环都在 `mf.zig`——那里才
//! 知道预览注册表的 decline 规则。拆成两个文件是为了守住单文件 600 行：光把
//! 用到的 `IMFAttributes` / `IMFSample` / `IMFSourceReader` 画清楚就占掉一半。
//!
//! 没有 @cImport、没有 C shim：函数用 `extern "mfplat"` / `"mfreadwrite"`，
//! 接口用 `extern struct` 写出 vtable 前缀。GUID 的值照抄 Windows SDK（mingw 头），
//! 所以链接期不需要 `mfuuid.lib`，也不存在"GUID 符号在哪个 lib 里"的平台差异。
//!
//! ## vtable 只用前缀 + 偏移量钉住
//!
//! 本层实际调用的方法很少（读/写属性、设类型、读样本、锁缓冲），中间那些用不到
//! 的槽用 `[N]usize` 占位；文件末尾对**每一个要用的方法**做 `@offsetOf` 编译期
//! 断言。漏写/多写一格不会等到运行期才跳错函数——编译就失败。
//!
//! ## 对象指针不缓存
//!
//! 本文件只声明类型，不持有任何实例；`mf.zig` 保证 SourceReader / 媒体类型 /
//! 样本的 `Release` 与创建在同一个 `open` 调用、同一条线程上完成。

const std = @import("std");
const builtin = @import("builtin");
const win = @import("../audio/win32.zig");

/// 平台闸门：Media Foundation 是 Windows 口岸。
pub const supported = builtin.os.tag == .windows;

pub const GUID = win.GUID;
pub const HRESULT = win.HRESULT;
pub const failed = win.failed;

// ---------------------------------------------------------------------------
// 常量（右侧注释是 Windows SDK 里的原名）
// ---------------------------------------------------------------------------

/// `MF_VERSION = MF_SDK_VERSION(0x2) << 16 | MF_API_VERSION(0x70)`。
pub const mf_version: u32 = 0x0002_0070;
/// `MFSTARTUP_FULL`（0）。不传 `MFSTARTUP_NOSOCKET`：`MFCreateSourceReaderFromURL`
/// 也接受 http:// 字节流，省那一个 socket 初始化不值得。
pub const mfstartup_full: u32 = 0;

/// `MF_SOURCE_READER_FIRST_AUDIO_STREAM` / `_FIRST_VIDEO_STREAM`。
pub const stream_audio: u32 = 0xFFFF_FFFD;
pub const stream_video: u32 = 0xFFFF_FFFC;
/// `MF_SOURCE_READER_MEDIASOURCE`：`GetPresentationAttribute` 的 index。
pub const stream_media_source: u32 = 0xFFFF_FFFF;

/// `MF_SOURCE_READERF_*`（mfreadwrite.h）。注意 `ENDOFSTREAM` 是 0x2，
/// `ERROR` 是 0x1——和很多"1 表示结束"的 API 相反。
pub const readerf_error: u32 = 0x0000_0001;
pub const readerf_endofstream: u32 = 0x0000_0002;
pub const readerf_current_media_type_changed: u32 = 0x0000_0020;
pub const readerf_streamtick: u32 = 0x0000_0100;

/// PROPVARIANT 的 `vt` 取值。
pub const vt_i8: u16 = 20;
pub const vt_ui8: u16 = 21;

/// 没有采样、也没有流结束标记时最多连读几次。正常文件读到 EOS 就停；这个上限
/// 只防"解码器一直回 STREAMTICK"把工作线程卡死。
pub const max_empty_reads: u32 = 4096;

pub const invalid_file_attributes: u32 = 0xFFFF_FFFF;

// ---------------------------------------------------------------------------
// 媒体类型 GUID（mfapi.h / mfidl.h / mfreadwrite.h）
// ---------------------------------------------------------------------------

pub const media_type_audio: GUID = .{ .Data1 = 0x73647561, .Data2 = 0x0000, .Data3 = 0x0010, .Data4 = .{ 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71 } };
pub const media_type_video: GUID = .{ .Data1 = 0x73646976, .Data2 = 0x0000, .Data3 = 0x0010, .Data4 = .{ 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71 } };
pub const audio_format_pcm: GUID = .{ .Data1 = 0x0000_0001, .Data2 = 0x0000, .Data3 = 0x0010, .Data4 = .{ 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71 } };
/// `MFVideoFormat_RGB32` = `D3DFMT_X8R8G8B8`（22）。内存里的字节序是 **B,G,R,X**
/// ——和 `preview.Bitmap` 的 BGRA 只差"填不填 alpha"，不需要通道交换。
pub const video_format_rgb32: GUID = .{ .Data1 = 0x0000_0016, .Data2 = 0x0000, .Data3 = 0x0010, .Data4 = .{ 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71 } };
pub const mt_major_type: GUID = .{ .Data1 = 0x48eb_a18e, .Data2 = 0xf8c9, .Data3 = 0x4687, .Data4 = .{ 0xbf, 0x11, 0x0a, 0x74, 0xc9, 0xf9, 0x6a, 0x8f } };
pub const mt_subtype: GUID = .{ .Data1 = 0xf7e3_4c9a, .Data2 = 0x42e8, .Data3 = 0x4714, .Data4 = .{ 0xb7, 0x4b, 0xcb, 0x29, 0xd7, 0x2c, 0x35, 0xe5 } };
pub const mt_frame_size: GUID = .{ .Data1 = 0x1652_c33d, .Data2 = 0xd6b2, .Data3 = 0x4012, .Data4 = .{ 0xb8, 0x34, 0x72, 0x03, 0x08, 0x49, 0xa3, 0x7d } };
pub const mt_default_stride: GUID = .{ .Data1 = 0x644b_4e48, .Data2 = 0x1e02, .Data3 = 0x4516, .Data4 = .{ 0xb0, 0xeb, 0xc0, 0x1c, 0xa9, 0xd4, 0x9a, 0xc6 } };
pub const mt_audio_num_channels: GUID = .{ .Data1 = 0x37e4_8bf5, .Data2 = 0x645e, .Data3 = 0x4c5b, .Data4 = .{ 0x89, 0xde, 0xad, 0xa9, 0xe2, 0x9b, 0x69, 0x6a } };
pub const mt_audio_samples_per_second: GUID = .{ .Data1 = 0x5fae_eae7, .Data2 = 0x0290, .Data3 = 0x4c31, .Data4 = .{ 0x9e, 0x8a, 0xc5, 0x34, 0xf6, 0x8d, 0x9d, 0xba } };
pub const mt_audio_bits_per_sample: GUID = .{ .Data1 = 0xf2de_b57f, .Data2 = 0x40fa, .Data3 = 0x4764, .Data4 = .{ 0xaa, 0x33, 0xed, 0x4f, 0x2d, 0x1f, 0xf6, 0x69 } };
pub const mt_audio_block_alignment: GUID = .{ .Data1 = 0x322d_e230, .Data2 = 0x9eeb, .Data3 = 0x43bd, .Data4 = .{ 0xab, 0x7a, 0xff, 0x41, 0x22, 0x51, 0x54, 0x1d } };
pub const mt_audio_avg_bytes_per_second: GUID = .{ .Data1 = 0x1aab_75c8, .Data2 = 0xcfef, .Data3 = 0x451c, .Data4 = .{ 0xab, 0x95, 0xac, 0x03, 0x4b, 0x8e, 0x17, 0x31 } };
/// `MF_PD_DURATION`（100 ns 单位，VT_UI8）。只用于日志/交叉核对；音频时长以
/// 实际解码出的 PCM 帧数为准，不拿容器声明的时长冒充。
pub const pd_duration: GUID = .{ .Data1 = 0x6c99_0d33, .Data2 = 0xbb8e, .Data3 = 0x477a, .Data4 = .{ 0x85, 0x98, 0x0d, 0x5d, 0x96, 0xfc, 0xd8, 0x8a } };
/// `MF_SOURCE_READER_ENABLE_ADVANCED_VIDEO_PROCESSING`：允许 SourceReader 用
/// Video Processor MFT 做色彩转换（YUV → RGB32）。没有它，大多数 H.264 文件
/// 会拒绝把输出类型设成 RGB32。
pub const source_reader_enable_advanced_video_processing: GUID = .{ .Data1 = 0x0f81_da2c, .Data2 = 0xb537, .Data3 = 0x4672, .Data4 = .{ 0xa8, 0xb2, 0xa6, 0x81, 0xb1, 0x73, 0x07, 0xa3 } };
pub const guid_null: GUID = .{ .Data1 = 0, .Data2 = 0, .Data3 = 0, .Data4 = .{ 0, 0, 0, 0, 0, 0, 0, 0 } };

/// x64 PROPVARIANT 的前 24 字节：`vt` + 保留 + 8 字节联合体（这里只读 `u64`）。
/// 布局用编译期断言钉住；本层只用到 VT_I8 / VT_UI8。
pub const PropVariant = extern struct {
    vt: u16,
    reserved: [3]u16,
    value: u64,
    padding: u64,
};

// ---------------------------------------------------------------------------
// vtable 前缀（每个字段 = 一个机器字；未调用的槽用 usize 数组占位）
// ---------------------------------------------------------------------------

pub const IMFAttributesVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
    /// 3..6：GetItem / GetItemType / CompareItem / Compare，本层不调用。
    unused_3_to_6: [4]usize,
    GetUINT32: *const fn (*anyopaque, *const GUID, *u32) callconv(.winapi) HRESULT,
    GetUINT64: *const fn (*anyopaque, *const GUID, *u64) callconv(.winapi) HRESULT,
    GetDouble: *const fn (*anyopaque, *const GUID, *f64) callconv(.winapi) HRESULT,
    GetGUID: *const fn (*anyopaque, *const GUID, *GUID) callconv(.winapi) HRESULT,
    /// 11..20：字符串 / Blob / Unknown / SetItem / DeleteItem / DeleteAllItems。
    unused_11_to_20: [10]usize,
    SetUINT32: *const fn (*anyopaque, *const GUID, u32) callconv(.winapi) HRESULT,
    SetUINT64: *const fn (*anyopaque, *const GUID, u64) callconv(.winapi) HRESULT,
    SetDouble: *const fn (*anyopaque, *const GUID, f64) callconv(.winapi) HRESULT,
    SetGUID: *const fn (*anyopaque, *const GUID, *const GUID) callconv(.winapi) HRESULT,
};

/// `IMFMediaType` 只继承 `IMFAttributes`，没有新增方法：读属性时直接用上面这张表。
/// `IMFMediaBuffer` 只调用 `Lock` / `Unlock`（读长度靠 Lock 的输出参数）。
pub const IMFMediaBufferVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
    Lock: *const fn (*anyopaque, *?[*]u8, ?*u32, *u32) callconv(.winapi) HRESULT,
    Unlock: *const fn (*anyopaque) callconv(.winapi) HRESULT,
};

/// 3..32 是 `IMFAttributes` 的全部方法（sample 本身就是属性容器），本层不通过
/// sample 读属性；41 才是 `ConvertToContiguousBuffer`。
pub const IMFSampleVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
    attributes_3_to_32: [30]usize,
    /// 33..40：SampleFlags / Time / Duration / BufferCount / GetBufferByIndex。
    unused_33_to_40: [8]usize,
    ConvertToContiguousBuffer: *const fn (*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT,
};

pub const IMFSourceReaderVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
    GetStreamSelection: *const fn (*anyopaque, u32, *i32) callconv(.winapi) HRESULT,
    SetStreamSelection: *const fn (*anyopaque, u32, i32) callconv(.winapi) HRESULT,
    GetNativeMediaType: *const fn (*anyopaque, u32, u32, *?*anyopaque) callconv(.winapi) HRESULT,
    GetCurrentMediaType: *const fn (*anyopaque, u32, *?*anyopaque) callconv(.winapi) HRESULT,
    SetCurrentMediaType: *const fn (*anyopaque, u32, ?*u32, *anyopaque) callconv(.winapi) HRESULT,
    SetCurrentPosition: *const fn (*anyopaque, *const GUID, *const PropVariant) callconv(.winapi) HRESULT,
    ReadSample: *const fn (*anyopaque, u32, u32, *u32, *u32, *i64, *?*anyopaque) callconv(.winapi) HRESULT,
    Flush: *const fn (*anyopaque, u32) callconv(.winapi) HRESULT,
    GetServiceForStream: *const fn (*anyopaque, u32, *const GUID, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    GetPresentationAttribute: *const fn (*anyopaque, u32, *const GUID, *PropVariant) callconv(.winapi) HRESULT,
};

// ---------------------------------------------------------------------------
// 系统函数
// ---------------------------------------------------------------------------

pub extern "mfplat" fn MFStartup(version: u32, flags: u32) callconv(.winapi) HRESULT;
pub extern "mfplat" fn MFShutdown() callconv(.winapi) HRESULT;
pub extern "mfplat" fn MFCreateMediaType(out: *?*anyopaque) callconv(.winapi) HRESULT;
pub extern "mfplat" fn MFCreateAttributes(out: *?*anyopaque, initial_size: u32) callconv(.winapi) HRESULT;
pub extern "mfreadwrite" fn MFCreateSourceReaderFromURL(
    url: [*:0]const u16,
    attributes: ?*anyopaque,
    out: *?*anyopaque,
) callconv(.winapi) HRESULT;

pub extern "kernel32" fn GetFileAttributesW(name: [*:0]const u16) callconv(.winapi) u32;
pub extern "kernel32" fn GetLastError() callconv(.winapi) u32;
/// 毫秒墙钟（GetTickCount64）。provider 只拿它量一次解码耗时，不需要高精度计时器；
/// 也用不到 `std.Io`（`preview.Provider.open` 没有 io 参数）。
pub extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;

// ---------------------------------------------------------------------------
// 编译期布局断言：漏掉一个 vtable 字段会在这里失败，而不是运行期跳错函数
// ---------------------------------------------------------------------------

comptime {
    if (@sizeOf(PropVariant) != 24) @compileError("x64 PROPVARIANT 应该是 24 字节");
    if (@offsetOf(PropVariant, "value") != 8) @compileError("PROPVARIANT.value 偏移应为 8");

    const slot = @sizeOf(usize);
    if (@offsetOf(IMFAttributesVtbl, "GetUINT32") != 7 * slot) @compileError("IMFAttributes.GetUINT32 槽位错误");
    if (@offsetOf(IMFAttributesVtbl, "GetUINT64") != 8 * slot) @compileError("IMFAttributes.GetUINT64 槽位错误");
    if (@offsetOf(IMFAttributesVtbl, "GetGUID") != 10 * slot) @compileError("IMFAttributes.GetGUID 槽位错误");
    if (@offsetOf(IMFAttributesVtbl, "SetUINT32") != 21 * slot) @compileError("IMFAttributes.SetUINT32 槽位错误");
    if (@offsetOf(IMFAttributesVtbl, "SetGUID") != 24 * slot) @compileError("IMFAttributes.SetGUID 槽位错误");
    if (@offsetOf(IMFMediaBufferVtbl, "Lock") != 3 * slot) @compileError("IMFMediaBuffer.Lock 槽位错误");
    if (@offsetOf(IMFMediaBufferVtbl, "Unlock") != 4 * slot) @compileError("IMFMediaBuffer.Unlock 槽位错误");
    if (@offsetOf(IMFSampleVtbl, "ConvertToContiguousBuffer") != 41 * slot) @compileError("IMFSample.ConvertToContiguousBuffer 槽位错误");
    if (@offsetOf(IMFSourceReaderVtbl, "SetCurrentMediaType") != 7 * slot) @compileError("IMFSourceReader.SetCurrentMediaType 槽位错误");
    if (@offsetOf(IMFSourceReaderVtbl, "ReadSample") != 9 * slot) @compileError("IMFSourceReader.ReadSample 槽位错误");
    if (@offsetOf(IMFSourceReaderVtbl, "GetPresentationAttribute") != 12 * slot) @compileError("IMFSourceReader.GetPresentationAttribute 槽位错误");
    if (@sizeOf(IMFSourceReaderVtbl) != 13 * slot) @compileError("IMFSourceReader vtable 应该是 13 格");
}
