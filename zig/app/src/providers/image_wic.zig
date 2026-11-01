//! WIC 静态图解码：PNG / JPEG / BMP / GIF / TIFF → 顶行在前的 BGRA8。
//!
//! 这是图片 provider 的**解码器**，不是口岸：它不查注册表、不问 Shell、不加载任何
//! 第三方 handler。WIC（`windowscodecs.dll`）是 Windows 自带的系统组件，`CoCreateInstance`
//! 直接拿工厂，所以「这台机器能不能解 PNG」和我们自己的代码无关，也和用户装没装
//! 图片软件无关。这正是图片 provider「自给自足」的含义（CHARTER「一」的 provider
//! 表把图像从 Shell 一栏里拆出来的原因）。
//!
//! 调用链（每一步的 HRESULT 都存进 `lastHresult()`，失败按 `Error` 分类）：
//!
//!   CoInitializeEx(MTA)                     工作线程自己的套间；RPC_E_CHANGED_MODE 借用
//!   CoCreateInstance(CLSID_WICImagingFactory)
//!   CreateDecoderFromFilename(GENERIC_READ) 容器解码器（按文件内容，不信扩展名）
//!   GetFrame(0)                             第一帧（GIF/TIFF 的动画/多页只取首帧）
//!   GetSize                                 原始像素尺寸
//!   CreateBitmapScaler + Initialize         长边缩到 max_px（WIC 自己做重采样）
//!   CreateFormatConverter + Initialize      统一成 GUID_WICPixelFormat32bppBGRA
//!   CopyPixels(WICRect = null)              整幅拷进我们分配的缓冲；再预乘 alpha
//!   Release ×5 / CoUninitialize             全部在 defer 里配对
//!
//! ## 缩放策略
//!
//! **不自己写重采样**：只在「长边 > max_px」时才建 `IWICBitmapScaler`，插值模式用
//! `Fant`（WIC 为缩小设计的滤波），目标尺寸按长宽比取整、短边至少 1 像素。原图不比
//! `max_px` 大时**不放大**——预览条要的是"看得清"，不是把 32px 图标糊成 256px。
//!
//! `IWICBitmapScaler` 理论上不该失败，但它是可选的优化：建不出来 / Initialize 失败时
//! 退回**原尺寸**继续走格式转换，`lastUsedScaler()` 记下这次没用上，调用方可以打日志。
//! 也就是说缩放失败不会让一张本来能看的图变成 `none.failed`。
//!
//! ## alpha 契约
//!
//! `preview.Bitmap` 要求**预乘 alpha**（与 `ports/thumb.Thumbnail` 同形），而
//! `GUID_WICPixelFormat32bppBGRA` 是直通 alpha。所以 CopyPixels 之后做一遍预乘；
//! 不透明图（BMP/多数 JPEG）的 alpha 是 255，这一步只是扫描一遍，不改像素。
//!
//! ## 线程与 COM
//!
//! `decode` 不持有跨调用状态，可以在任意线程调用（`image.Provider.open` 由预览条的
//! 工作线程调用）。每次调用自己 `CoInitializeEx(COINIT_MULTITHREADED)`：
//!
//!   * `S_OK` / `S_FALSE`（本线程已初始化）→ 都算"我们持有一次"，配对 `CoUninitialize`；
//!   * `RPC_E_CHANGED_MODE`（别人把它初始化成 STA）→ 直接借用 MTA 工厂，**不**配对
//!     （配对了会把别人的初始化关掉）。
//!
//! 没有消息循环要求，不弹窗、不抢焦点。手写 extern / vtable，没有 @cImport、没有 C shim。

const std = @import("std");
const path_win = @import("otto_win_path");
const builtin = @import("builtin");

/// 平台闸门：这是 Windows 解码器，其它平台返回 `error.Unsupported`。
pub const supported = builtin.os.tag == .windows;

// ---------------------------------------------------------------------------
// 手写 Win32 / COM 声明（等价于 wincodec.h 里用到的部分）
// ---------------------------------------------------------------------------

const HRESULT = i32;
const DWORD = u32;
const UINT = u32;

const GUID = extern struct {
    Data1: u32,
    Data2: u16,
    Data3: u16,
    Data4: [8]u8,
};

/// wincodec.h 的 `WICRect`：CopyPixels 的感兴趣区域；传 null 表示整幅。
const WICRect = extern struct {
    X: i32,
    Y: i32,
    Width: i32,
    Height: i32,
};

/// `IWICBitmapSource` 的 8 个方法（IUnknown 3 + 5）。派生接口的 vtable 以它开头。
const IWICBitmapSourceVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, ?*?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
    GetSize: *const fn (*anyopaque, *UINT, *UINT) callconv(.winapi) HRESULT,
    GetPixelFormat: *const anyopaque,
    GetResolution: *const anyopaque,
    CopyPalette: *const anyopaque,
    CopyPixels: *const fn (*anyopaque, ?*const WICRect, UINT, UINT, [*]u8) callconv(.winapi) HRESULT,
};

const IUnknownVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, ?*?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
};

/// `IWICImagingFactory`：只用到 create-decoder / format-converter / scaler 三个方法。
/// 中间的方法按 wincodec.h 的顺序占位，**不能删**——vtable 是按下标跳的。
const IWICImagingFactoryVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, ?*?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
    CreateDecoderFromFilename: *const fn (
        *anyopaque,
        [*:0]const u16,
        ?*const GUID,
        DWORD,
        i32,
        *?*anyopaque,
    ) callconv(.winapi) HRESULT,
    CreateDecoderFromStream: *const anyopaque,
    CreateDecoderFromFileHandle: *const anyopaque,
    CreateComponentInfo: *const anyopaque,
    CreateDecoder: *const anyopaque,
    CreateEncoder: *const anyopaque,
    CreatePalette: *const anyopaque,
    CreateFormatConverter: *const fn (*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT,
    CreateBitmapScaler: *const fn (*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT,
};

/// `IWICBitmapDecoder`：只用到 GetFrame（第 13 格）。
const IWICBitmapDecoderVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, ?*?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
    QueryCapability: *const anyopaque,
    Initialize: *const anyopaque,
    GetContainerFormat: *const anyopaque,
    GetDecoderInfo: *const anyopaque,
    CopyPalette: *const anyopaque,
    GetMetadataQueryReader: *const anyopaque,
    GetPreview: *const anyopaque,
    GetColorContexts: *const anyopaque,
    GetThumbnail: *const anyopaque,
    GetFrameCount: *const anyopaque,
    GetFrame: *const fn (*anyopaque, UINT, *?*anyopaque) callconv(.winapi) HRESULT,
};

/// `IWICBitmapFrameDecode`：IWICBitmapSource + 三个元数据方法。只用到 GetSize / CopyPixels。
const IWICBitmapFrameDecodeVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, ?*?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
    GetSize: *const fn (*anyopaque, *UINT, *UINT) callconv(.winapi) HRESULT,
    GetPixelFormat: *const anyopaque,
    GetResolution: *const anyopaque,
    CopyPalette: *const anyopaque,
    CopyPixels: *const fn (*anyopaque, ?*const WICRect, UINT, UINT, [*]u8) callconv(.winapi) HRESULT,
    GetMetadataQueryReader: *const anyopaque,
    GetColorContexts: *const anyopaque,
    GetThumbnail: *const anyopaque,
};

/// `IWICFormatConverter`：IWICBitmapSource + Initialize + CanConvert。
const IWICFormatConverterVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, ?*?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
    GetSize: *const fn (*anyopaque, *UINT, *UINT) callconv(.winapi) HRESULT,
    GetPixelFormat: *const anyopaque,
    GetResolution: *const anyopaque,
    CopyPalette: *const anyopaque,
    CopyPixels: *const fn (*anyopaque, ?*const WICRect, UINT, UINT, [*]u8) callconv(.winapi) HRESULT,
    Initialize: *const fn (
        *anyopaque,
        *anyopaque,
        *const GUID,
        i32,
        ?*anyopaque,
        f64,
        i32,
    ) callconv(.winapi) HRESULT,
    CanConvert: *const anyopaque,
};

/// `IWICBitmapScaler`：IWICBitmapSource + Initialize。
const IWICBitmapScalerVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, ?*?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
    GetSize: *const fn (*anyopaque, *UINT, *UINT) callconv(.winapi) HRESULT,
    GetPixelFormat: *const anyopaque,
    GetResolution: *const anyopaque,
    CopyPalette: *const anyopaque,
    CopyPixels: *const fn (*anyopaque, ?*const WICRect, UINT, UINT, [*]u8) callconv(.winapi) HRESULT,
    Initialize: *const fn (*anyopaque, *anyopaque, UINT, UINT, i32) callconv(.winapi) HRESULT,
};

extern "ole32" fn CoInitializeEx(reserved: ?*anyopaque, co_init: DWORD) callconv(.winapi) HRESULT;
extern "ole32" fn CoUninitialize() callconv(.winapi) void;
extern "ole32" fn CoCreateInstance(
    rclsid: *const GUID,
    outer: ?*anyopaque,
    cls_context: DWORD,
    riid: *const GUID,
    out: *?*anyopaque,
) callconv(.winapi) HRESULT;

// ---------------------------------------------------------------------------
// 常量
// ---------------------------------------------------------------------------

fn hr(comptime value: u32) HRESULT {
    return @bitCast(value);
}

const S_OK: HRESULT = hr(0x0000_0000);
const E_INVALIDARG: HRESULT = hr(0x8007_0057);
const E_OUTOFMEMORY: HRESULT = hr(0x8007_000E);
const E_UNEXPECTED: HRESULT = hr(0x8000_FFFF);
/// 线程已经在别的套间里初始化过。任务要求：借用，且不要配对 CoUninitialize。
const RPC_E_CHANGED_MODE: HRESULT = hr(0x8001_0106);

const CLSCTX_INPROC_SERVER: DWORD = 0x0000_0001;
const COINIT_MULTITHREADED: DWORD = 0x0000_0000;
const GENERIC_READ: DWORD = 0x8000_0000;
/// `WICDecodeMetadataCacheOnDemand`：预览不解元数据，别在 open 里替用户全部解一遍。
const WICDecodeMetadataCacheOnDemand: i32 = 0;
/// `WICBitmapInterpolationModeFant`：WIC 为缩小准备的滤波。
const WICBitmapInterpolationModeFant: i32 = 3;
/// `WICBitmapDitherTypeNone` / `WICBitmapPaletteTypeCustom`。
const WICBitmapDitherTypeNone: i32 = 0;
const WICBitmapPaletteTypeCustom: i32 = 0;

const CLSID_WICImagingFactory = GUID{
    .Data1 = 0xcacaf262,
    .Data2 = 0x9370,
    .Data3 = 0x4615,
    .Data4 = .{ 0xa1, 0x3b, 0x9f, 0x55, 0x39, 0xda, 0x4c, 0x0a },
};
const IID_IWICImagingFactory = GUID{
    .Data1 = 0xec5ec8a9,
    .Data2 = 0xc395,
    .Data3 = 0x4314,
    .Data4 = .{ 0x9c, 0x77, 0x54, 0xd7, 0xa9, 0x35, 0xff, 0x70 },
};
/// 32bpp BGRA（直通 alpha）。转换完我们自己做预乘，见文件头「alpha 契约」。
const GUID_WICPixelFormat32bppBGRA = GUID{
    .Data1 = 0x6fddc324,
    .Data2 = 0x4e03,
    .Data3 = 0x4bfe,
    .Data4 = .{ 0xb1, 0x85, 0x3d, 0x77, 0x76, 0x8d, 0xc9, 0x0f },
};

/// 单张位图的硬上限：同 `ports/thumb_win.zig`，不赌损坏/恶意文件报出来的尺寸。
const max_image_bytes: usize = 256 * 1024 * 1024;

// ---------------------------------------------------------------------------
// 诊断：当前线程最近一次 HRESULT / 有没有用上 scaler
// ---------------------------------------------------------------------------

threadlocal var last_hresult: HRESULT = S_OK;
threadlocal var used_scaler: bool = false;

pub fn lastHresult() i32 {
    return last_hresult;
}

/// 最近一次 `decode` 是否真的用了 WIC scaler。false 有两种：原图不比 `max_px` 大
/// （不需要），或 scaler 不可用退回原尺寸（值得在报告里说明）。
pub fn lastUsedScaler() bool {
    return used_scaler;
}

// ---------------------------------------------------------------------------
// 公共类型
// ---------------------------------------------------------------------------

pub const Error = error{
    /// 非 Windows / 空路径 / 路径不是合法 UTF-8。
    Unsupported,
    /// 文件不存在（WIC 把 Win32 的 ERROR_FILE_NOT_FOUND 包成 HRESULT）。
    FileNotFound,
    AccessDenied,
    /// 解码、转换、尺寸、内存上限等其余失败。
    Failed,
    OutOfMemory,
};

/// 一张解码好的图，与 `preview.Bitmap` 同形：BGRA8、预乘 alpha、顶行在前、
/// `stride == width * 4`。`pixels` 用调用方传入的 allocator 分配。
pub const Image = struct {
    pixels: []u8,
    width: u32,
    height: u32,
    stride: usize,

    pub fn deinit(self: Image, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }

    pub fn byteLen(self: Image) usize {
        return self.pixels.len;
    }
};

/// 目标尺寸：长边不超过 `max_px`，保持长宽比，短边至少 1 像素；**不放大**。
/// `max_px == 0` 按"没有限制"处理（注册表不会传 0，但测试会）。
pub fn fitDimensions(src_w: u32, src_h: u32, max_px: u32) struct { width: u32, height: u32 } {
    const longest = @max(src_w, src_h);
    if (max_px == 0 or longest <= max_px) return .{ .width = src_w, .height = src_h };
    return .{
        .width = fitEdge(src_w, longest, max_px),
        .height = fitEdge(src_h, longest, max_px),
    };
}

fn fitEdge(edge: u32, longest: u32, max_px: u32) u32 {
    const scaled = (@as(u64, edge) * max_px + longest / 2) / longest;
    return @intCast(@max(1, scaled));
}

// ---------------------------------------------------------------------------
// 入口
// ---------------------------------------------------------------------------

/// 把 `path` 解成 BGRA8。成功时 `pixels` 归调用方，用**同一个** allocator 释放。
pub fn decode(allocator: std.mem.Allocator, path: []const u8, max_px: u32) Error!Image {
    last_hresult = S_OK;
    used_scaler = false;
    if (!supported) return error.Unsupported;
    if (path.len == 0) {
        last_hresult = E_INVALIDARG;
        return error.Unsupported;
    }

    const wide = path_win.wide(allocator, path, 0) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidPath => return error.Unsupported,
    };
    defer allocator.free(wide);

    // 套间：MTA。S_FALSE = 本线程已经以同模式初始化过，仍要配对一次；RPC_E_CHANGED_MODE
    // = 别人初始化成了 STA，直接用、不配对（配对了就把别人的初始化关掉了）。
    var com_owned = false;
    const init_hr = CoInitializeEx(null, COINIT_MULTITHREADED);
    if (init_hr >= 0) {
        com_owned = true;
    } else if (init_hr != RPC_E_CHANGED_MODE) {
        last_hresult = init_hr;
        return error.Failed;
    }
    defer if (com_owned) CoUninitialize();

    var factory: ?*anyopaque = null;
    const factory_hr = CoCreateInstance(
        &CLSID_WICImagingFactory,
        null,
        CLSCTX_INPROC_SERVER,
        &IID_IWICImagingFactory,
        &factory,
    );
    if (factory_hr < 0 or factory == null) {
        last_hresult = if (factory_hr < 0) factory_hr else E_UNEXPECTED;
        return errorFor(last_hresult);
    }
    const factory_ptr = factory.?;
    defer release(factory_ptr);
    const factory_vt = vtableOf(IWICImagingFactoryVtbl, factory_ptr);

    var decoder: ?*anyopaque = null;
    const decoder_hr = factory_vt.CreateDecoderFromFilename(
        factory_ptr,
        wide.ptr,
        null,
        GENERIC_READ,
        WICDecodeMetadataCacheOnDemand,
        &decoder,
    );
    if (decoder_hr < 0 or decoder == null) {
        last_hresult = if (decoder_hr < 0) decoder_hr else E_UNEXPECTED;
        return errorFor(last_hresult);
    }
    const decoder_ptr = decoder.?;
    defer release(decoder_ptr);
    const decoder_vt = vtableOf(IWICBitmapDecoderVtbl, decoder_ptr);

    var frame: ?*anyopaque = null;
    const frame_hr = decoder_vt.GetFrame(decoder_ptr, 0, &frame);
    if (frame_hr < 0 or frame == null) {
        last_hresult = if (frame_hr < 0) frame_hr else E_UNEXPECTED;
        return errorFor(last_hresult);
    }
    const frame_ptr = frame.?;
    defer release(frame_ptr);
    const frame_vt = vtableOf(IWICBitmapFrameDecodeVtbl, frame_ptr);

    var src_w: UINT = 0;
    var src_h: UINT = 0;
    const size_hr = frame_vt.GetSize(frame_ptr, &src_w, &src_h);
    if (size_hr < 0 or src_w == 0 or src_h == 0) {
        last_hresult = if (size_hr < 0) size_hr else E_UNEXPECTED;
        return errorFor(last_hresult);
    }

    // 缩放：只有真的要缩小时才建 scaler；它失败不影响出图（退回原尺寸）。
    const fit = fitDimensions(src_w, src_h, max_px);
    var source = frame_ptr;
    var out_w: u32 = src_w;
    var out_h: u32 = src_h;
    var scaler: ?*anyopaque = null;
    if (fit.width != src_w or fit.height != src_h) {
        scaler = createScaler(factory_ptr, factory_vt, frame_ptr, fit.width, fit.height) orelse null;
        if (scaler) |scaler_ptr| {
            source = scaler_ptr;
            out_w = fit.width;
            out_h = fit.height;
            used_scaler = true;
        } else {
            std.debug.print(
                "otto-lite: WIC scaler 不可用（hresult=0x{x:0>8}），按原尺寸 {d}x{d} 返回\n",
                .{ @as(u32, @bitCast(last_hresult)), src_w, src_h },
            );
        }
    }
    defer if (scaler) |scaler_ptr| release(scaler_ptr);

    var converter: ?*anyopaque = null;
    const converter_hr = factory_vt.CreateFormatConverter(factory_ptr, &converter);
    if (converter_hr < 0 or converter == null) {
        last_hresult = if (converter_hr < 0) converter_hr else E_UNEXPECTED;
        return errorFor(last_hresult);
    }
    const converter_ptr = converter.?;
    defer release(converter_ptr);
    const converter_vt = vtableOf(IWICFormatConverterVtbl, converter_ptr);

    const convert_hr = converter_vt.Initialize(
        converter_ptr,
        source,
        &GUID_WICPixelFormat32bppBGRA,
        WICBitmapDitherTypeNone,
        null,
        0.0,
        WICBitmapPaletteTypeCustom,
    );
    if (convert_hr < 0) {
        last_hresult = convert_hr;
        return errorFor(convert_hr);
    }

    const stride = std.math.mul(usize, @as(usize, out_w), 4) catch return error.Failed;
    const total = std.math.mul(usize, stride, @as(usize, out_h)) catch return error.Failed;
    if (total == 0 or total > max_image_bytes or total > std.math.maxInt(UINT)) {
        last_hresult = E_OUTOFMEMORY;
        return error.Failed;
    }
    const pixels = allocator.alloc(u8, total) catch return error.OutOfMemory;
    errdefer allocator.free(pixels);

    const copy_hr = converter_vt.CopyPixels(
        converter_ptr,
        null,
        @intCast(stride),
        @intCast(total),
        pixels.ptr,
    );
    if (copy_hr < 0) {
        last_hresult = copy_hr;
        return errorFor(copy_hr);
    }

    premultiplyAlpha(pixels);

    return .{
        .pixels = pixels,
        .width = out_w,
        .height = out_h,
        .stride = stride,
    };
}

/// 建 scaler 并 Initialize；任何一步失败都返回 null（已经建出来的对象在这里释放）。
fn createScaler(
    factory: *anyopaque,
    factory_vt: *const IWICImagingFactoryVtbl,
    frame: *anyopaque,
    width: u32,
    height: u32,
) ?*anyopaque {
    var scaler: ?*anyopaque = null;
    const create_hr = factory_vt.CreateBitmapScaler(factory, &scaler);
    if (create_hr < 0 or scaler == null) {
        last_hresult = if (create_hr < 0) create_hr else E_UNEXPECTED;
        return null;
    }
    const scaler_ptr = scaler.?;
    const scaler_vt = vtableOf(IWICBitmapScalerVtbl, scaler_ptr);
    const init_hr = scaler_vt.Initialize(
        scaler_ptr,
        frame,
        width,
        height,
        WICBitmapInterpolationModeFant,
    );
    if (init_hr < 0) {
        last_hresult = init_hr;
        release(scaler_ptr);
        return null;
    }
    return scaler_ptr;
}

// ---------------------------------------------------------------------------
// 像素 / HRESULT
// ---------------------------------------------------------------------------

/// 直通 alpha → 预乘 alpha（BGRA，原地）。alpha 已经是 255 的像素原样保留。
///
/// 公开只为 `image_wic_test.zig` 能单独验证它；它不是 provider 契约的一部分。
pub fn premultiplyAlpha(pixels: []u8) void {
    var index: usize = 0;
    while (index + 4 <= pixels.len) : (index += 4) {
        const alpha = pixels[index + 3];
        if (alpha == 255) continue;
        if (alpha == 0) {
            pixels[index] = 0;
            pixels[index + 1] = 0;
            pixels[index + 2] = 0;
            continue;
        }
        pixels[index] = @intCast((@as(u32, pixels[index]) * alpha + 127) / 255);
        pixels[index + 1] = @intCast((@as(u32, pixels[index + 1]) * alpha + 127) / 255);
        pixels[index + 2] = @intCast((@as(u32, pixels[index + 2]) * alpha + 127) / 255);
    }
}

/// WIC / COM 的失败码 → 谢绝语义。只有"文件没了/没权限/内存不够"值得单独说，
/// 其余（坏图、缺解码器、像素格式不支持）都归 `Failed`：扩展名归我们管，内容坏了
/// 是"处理失败"，不是"这台机器不支持这种格式"。
fn errorFor(value: HRESULT) Error {
    return switch (@as(u32, @bitCast(value))) {
        0x8007_0002, 0x8007_0003 => error.FileNotFound,
        0x8007_0005 => error.AccessDenied,
        0x8007_000E, 0x8007_0010 => error.OutOfMemory,
        else => error.Failed,
    };
}

/// 接口指针 → vtable。COM 的 ABI：对象第一格是 vtable 指针。
fn vtableOf(comptime Vtbl: type, interface: *anyopaque) *const Vtbl {
    const object: *const *const Vtbl = @ptrCast(@alignCast(interface));
    return object.*;
}

fn release(interface: ?*anyopaque) void {
    const ptr = interface orelse return;
    _ = vtableOf(IUnknownVtbl, ptr).Release(ptr);
}

// 测试在 `image_wic_test.zig`：解码器本身加上测试会超过单文件 600 行（与
// `preview_test.zig` / `options_test.zig` 拆分的同一条理由）。
