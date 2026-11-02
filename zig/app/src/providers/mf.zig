//! Media Foundation 的**生命周期与助手层**：启动、路径、属性、读样本、释放。
//!
//! 接口声明（GUID / vtable / extern）在 `mf_com.zig`；本文件只说"怎么用、失败
//! 怎么分类"。音频（`mf_audio.zig`）与视频（`mf_video.zig`）共用这一层，最可能
//! 漂移的不是解码本身，而是 COM 套间与 `MFShutdown` 的配对——那是最难在事后看
//! 日志发现的一类 bug，所以只有一个实现。
//!
//! ## 线程与生命周期
//!
//! `Startup.init` 在**调用线程**上做 `CoInitializeEx(MTA)` + `MFStartup(MF_VERSION)`；
//! `deinit` 按相反顺序配对 `MFShutdown` + `CoUninitialize`。`RPC_E_CHANGED_MODE`
//! （线程已被别人初始化成别的套间）按约定**可用但不配对**：此时不拥有套间，
//! 也就不能替别人关掉它。
//!
//! 所有 COM 接口指针只在**同一次 `open` 调用**内创建、使用、Release；本层不缓存
//! 任何跨调用的指针。SourceReader 的读循环是同步的，所以 provider 可以把整段
//! 解码放在预览条的工作线程上，而不必担心"指针跨线程"。
//!
//! ## 失败怎么表达
//!
//! 唯一诊断渠道是 `lastHresult()`（线程局部，日志用）。本层把失败收成
//! `error.Failed` / `error.MediaTypeChanged` 这类**可分类的原因**，由 provider
//! 决定映射成 `none.file_missing` / `none.failed`——"文件读不出来"不是错误，
//! 是预览注册表的一次谢绝（见 `preview.zig` 的 decline 规则）。

const std = @import("std");
const path_win = @import("otto_win_path");
const win = @import("../audio/win32.zig");
const com = @import("mf_com.zig");

pub const supported = com.supported;
pub const GUID = com.GUID;
pub const HRESULT = com.HRESULT;
pub const Size = struct { width: u32, height: u32 };

// 常量与 GUID 由 `mf_com.zig` 定义；这里再导出，provider 只 import 一个模块。
pub const stream_audio = com.stream_audio;
pub const stream_video = com.stream_video;
pub const media_type_audio = com.media_type_audio;
pub const media_type_video = com.media_type_video;
pub const audio_format_pcm = com.audio_format_pcm;
pub const video_format_rgb32 = com.video_format_rgb32;
pub const mt_major_type = com.mt_major_type;
pub const mt_subtype = com.mt_subtype;
pub const mt_frame_size = com.mt_frame_size;
pub const mt_default_stride = com.mt_default_stride;
pub const mt_audio_num_channels = com.mt_audio_num_channels;
pub const mt_audio_samples_per_second = com.mt_audio_samples_per_second;
pub const mt_audio_bits_per_sample = com.mt_audio_bits_per_sample;
pub const mt_audio_block_alignment = com.mt_audio_block_alignment;
pub const mt_audio_avg_bytes_per_second = com.mt_audio_avg_bytes_per_second;
pub const source_reader_enable_advanced_video_processing = com.source_reader_enable_advanced_video_processing;
pub const guid_null = com.guid_null;

const PropVariant = com.PropVariant;

/// 本层对外暴露的失败分类。`MediaTypeChanged` 单独一档：它意味着"解码器中途换了
/// 输出格式"，继续把字节拼进同一段 PCM 会造出一段格式不一致的音频——宁可谢绝。
pub const Error = error{
    OutOfMemory,
    InvalidPath,
    FileNotFound,
    Unavailable,
    Failed,
    MediaTypeChanged,
};

// ---------------------------------------------------------------------------
// 诊断
// ---------------------------------------------------------------------------

threadlocal var last_hresult: HRESULT = win.S_OK;

/// 当前线程最近一次失败的 HRESULT。成功不覆盖它——日志里"最后一次失败"比
/// "最后一次调用"更有用。零表示这个线程还没失败过。
pub fn lastHresult() HRESULT {
    return last_hresult;
}

pub fn nowMs() u64 {
    return com.GetTickCount64();
}

/// 每次 `open` 开始时清掉线程局部的"最近失败"。工作线程会连续服务多个样本，
/// 不清的话一次无害的可选属性缺失会让后面"没有视频帧"的日志带上别人的 HRESULT。
pub fn resetDiag() void {
    last_hresult = win.S_OK;
}

fn vt(comptime Vtbl: type, interface: *anyopaque) *const Vtbl {
    return win.vtableOf(Vtbl, interface);
}

fn check(code: HRESULT) Error!void {
    if (win.failed(code)) {
        last_hresult = code;
        return error.Failed;
    }
}

// ---------------------------------------------------------------------------
// 套间 + MF 生命周期
// ---------------------------------------------------------------------------

/// 一次 `open` 的 MF 会话。**必须**在创建它的线程上 `deinit`。
pub const Startup = struct {
    com_owned: bool = false,
    mf_started: bool = false,

    pub fn init() Error!Startup {
        if (!supported) return error.Unavailable;

        var self = Startup{};
        const co = win.CoInitializeEx(null, win.COINIT_MULTITHREADED);
        if (win.failed(co)) {
            // 线程已经被初始化成别的套间：按约定继续用，但**不**配对
            // CoUninitialize（那会把别人的初始化关掉）。其余失败则没有 COM。
            if (co != win.RPC_E_CHANGED_MODE) {
                last_hresult = co;
                return error.Unavailable;
            }
        } else {
            self.com_owned = true;
        }

        const hr = com.MFStartup(com.mf_version, com.mfstartup_full);
        if (win.failed(hr)) {
            last_hresult = hr;
            if (self.com_owned) win.CoUninitialize();
            return error.Unavailable;
        }
        self.mf_started = true;
        return self;
    }

    pub fn deinit(self: *Startup) void {
        if (self.mf_started) {
            _ = com.MFShutdown();
            self.mf_started = false;
        }
        if (self.com_owned) {
            win.CoUninitialize();
            self.com_owned = false;
        }
    }
};

// ---------------------------------------------------------------------------
// 文件 / 路径
// ---------------------------------------------------------------------------

/// UTF-8 路径 → 以 0 结尾的 UTF-16，并确认文件存在。返回的切片归调用方。
///
/// 先查文件属性再进 MF：文件没了要落到 `none.file_missing`，而不是让
/// `MFCreateSourceReaderFromURL` 给一个泛化的 `MF_E_UNSUPPORTED_BYTESTREAM_TYPE`
/// 之类的"解码失败"。
pub fn existingWidePath(allocator: std.mem.Allocator, path: []const u8) Error![:0]const u16 {
    if (!supported) return error.Unavailable;
    if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;

    const wide = path_win.wide(allocator, path, 0) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidPath => return error.InvalidPath,
    };
    errdefer allocator.free(wide);

    if (com.GetFileAttributesW(wide.ptr) == com.invalid_file_attributes) {
        const code = com.GetLastError();
        last_hresult = win.hresultFromWin32(code);
        return switch (code) {
            2, 3 => error.FileNotFound, // ERROR_FILE_NOT_FOUND / PATH_NOT_FOUND
            else => error.Failed,
        };
    }
    return wide;
}

// ---------------------------------------------------------------------------
// 工厂与属性
// ---------------------------------------------------------------------------

pub fn createReader(url: [*:0]const u16, attributes: ?*anyopaque) Error!*anyopaque {
    var reader: ?*anyopaque = null;
    const hr = com.MFCreateSourceReaderFromURL(url, attributes, &reader);
    if (win.failed(hr) or reader == null) {
        last_hresult = hr;
        return error.Failed;
    }
    return reader.?;
}

pub fn createAttributes(capacity: u32) Error!*anyopaque {
    var attributes: ?*anyopaque = null;
    const hr = com.MFCreateAttributes(&attributes, capacity);
    if (win.failed(hr) or attributes == null) {
        last_hresult = hr;
        return error.Failed;
    }
    return attributes.?;
}

pub fn createMediaType() Error!*anyopaque {
    var media_type: ?*anyopaque = null;
    const hr = com.MFCreateMediaType(&media_type);
    if (win.failed(hr) or media_type == null) {
        last_hresult = hr;
        return error.Failed;
    }
    return media_type.?;
}

pub fn release(interface: *anyopaque, comptime Vtbl: type) void {
    _ = vt(Vtbl, interface).Release(interface);
}

pub fn releaseReader(reader: *anyopaque) void {
    release(reader, com.IMFSourceReaderVtbl);
}

/// 媒体类型与属性对象共用一张 vtable（`IMFMediaType` 没有新增方法）。
pub fn releaseMediaType(media_type: *anyopaque) void {
    release(media_type, com.IMFAttributesVtbl);
}

/// `MFCreateAttributes` 出来的对象同样只有 `IMFAttributes` 的方法。
pub fn releaseAttributes(attributes: *anyopaque) void {
    release(attributes, com.IMFAttributesVtbl);
}

// ---- 属性读写 ----

pub fn setU32(object: *anyopaque, key: *const GUID, value: u32) Error!void {
    try check(vt(com.IMFAttributesVtbl, object).SetUINT32(object, key, value));
}

pub fn setU64(object: *anyopaque, key: *const GUID, value: u64) Error!void {
    try check(vt(com.IMFAttributesVtbl, object).SetUINT64(object, key, value));
}

pub fn setGuid(object: *anyopaque, key: *const GUID, value: *const GUID) Error!void {
    try check(vt(com.IMFAttributesVtbl, object).SetGUID(object, key, value));
}

pub fn getU32(object: *anyopaque, key: *const GUID) Error!u32 {
    var value: u32 = 0;
    try check(vt(com.IMFAttributesVtbl, object).GetUINT32(object, key, &value));
    return value;
}

/// 可选属性：属性不存在返回 null，且**不**污染 `lastHresult()`。媒体类型上
/// `MF_MT_DEFAULT_STRIDE`、`MF_MT_AUDIO_*` 在协商结果里都可能缺席，那不是失败。
pub fn getU32Optional(object: *anyopaque, key: *const GUID) ?u32 {
    var value: u32 = 0;
    if (win.failed(vt(com.IMFAttributesVtbl, object).GetUINT32(object, key, &value))) return null;
    return value;
}

pub fn getU64(object: *anyopaque, key: *const GUID) Error!u64 {
    var value: u64 = 0;
    try check(vt(com.IMFAttributesVtbl, object).GetUINT64(object, key, &value));
    return value;
}

pub fn getGuid(object: *anyopaque, key: *const GUID) Error!GUID {
    var value: GUID = guid_null;
    try check(vt(com.IMFAttributesVtbl, object).GetGUID(object, key, &value));
    return value;
}

/// 媒体类型里 `MF_MT_FRAME_SIZE` 的高 32 位是宽、低 32 位是高。
pub fn sizeFromPacked(packed_size: u64) Size {
    return .{
        .width = @intCast(packed_size >> 32),
        .height = @intCast(packed_size & 0xFFFF_FFFF),
    };
}

pub fn frameSize(media_type: *anyopaque) Error!Size {
    const size = sizeFromPacked(try getU64(media_type, &mt_frame_size));
    if (size.width == 0 or size.height == 0) return error.Failed;
    return size;
}

/// `MF_MT_DEFAULT_STRIDE`：负值表示自底向上的行序（见 `mf_video.zig`）。
/// 属性不存在时返回 null，由调用方按"紧凑、顶行在前"处理。
pub fn defaultStride(media_type: *anyopaque) ?i32 {
    const raw = getU32Optional(media_type, &mt_default_stride) orelse return null;
    return @bitCast(raw);
}

pub fn subtypeIs(media_type: *anyopaque, expected: *const GUID) bool {
    const actual = getGuid(media_type, &mt_subtype) catch return false;
    return std.mem.eql(u8, std.mem.asBytes(&actual), std.mem.asBytes(expected));
}

/// 容器声明的时长（毫秒）。读不到返回 null；**音频以实际 PCM 帧数为准**，
/// 这个值只用日志核对（有些容器把首帧前的编码延迟算进去，会差几十毫秒）。
pub fn durationMs(reader: *anyopaque) ?u64 {
    var attribute = std.mem.zeroes(PropVariant);
    const hr = vt(com.IMFSourceReaderVtbl, reader).GetPresentationAttribute(
        reader,
        com.stream_media_source,
        &com.pd_duration,
        &attribute,
    );
    if (win.failed(hr)) return null;
    if (attribute.vt != com.vt_ui8 and attribute.vt != com.vt_i8) return null;
    return attribute.value / 10_000;
}

// ---------------------------------------------------------------------------
// 流选择 / 读样本
// ---------------------------------------------------------------------------

pub fn selectStream(reader: *anyopaque, stream: u32) Error!void {
    try check(vt(com.IMFSourceReaderVtbl, reader).SetStreamSelection(reader, stream, 1));
}

pub fn setCurrentType(reader: *anyopaque, stream: u32, media_type: *anyopaque) Error!void {
    try check(vt(com.IMFSourceReaderVtbl, reader).SetCurrentMediaType(reader, stream, null, media_type));
}

pub fn currentType(reader: *anyopaque, stream: u32) Error!*anyopaque {
    var media_type: ?*anyopaque = null;
    const hr = vt(com.IMFSourceReaderVtbl, reader).GetCurrentMediaType(reader, stream, &media_type);
    if (win.failed(hr) or media_type == null) {
        last_hresult = hr;
        return error.Failed;
    }
    return media_type.?;
}

pub fn nativeType(reader: *anyopaque, stream: u32, index: u32) Error!*anyopaque {
    var media_type: ?*anyopaque = null;
    const hr = vt(com.IMFSourceReaderVtbl, reader).GetNativeMediaType(reader, stream, index, &media_type);
    if (win.failed(hr) or media_type == null) {
        last_hresult = hr;
        return error.Failed;
    }
    return media_type.?;
}

/// 把读头移到 `ms`（100 ns 单位、`GUID_NULL` 时间格式）。只在没开始读时调；
/// SourceReader 会自己从关键帧解码到目标时间。
pub fn seek(reader: *anyopaque, ms: u64) Error!void {
    const position = PropVariant{
        .vt = com.vt_i8,
        .reserved = .{ 0, 0, 0 },
        .value = ms *| 10_000,
        .padding = 0,
    };
    try check(vt(com.IMFSourceReaderVtbl, reader).SetCurrentPosition(reader, &guid_null, &position));
}

pub const ReadResult = union(enum) {
    sample: *anyopaque,
    /// 有样本，但同时带 `MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED`：调用方应先
    /// 重新 `GetCurrentMediaType` 再解释这块字节。首帧常见（Video Processor 在
    /// 第一次 ReadSample 时把协商属性补齐），所以不能当错误。
    sample_after_type_change: *anyopaque,
    end_of_stream,
};

/// 读到下一个**真样本**；EOS 返回 `.end_of_stream`。
///
/// 跳过 STREAMTICK（它没有 sample）；`CURRENTMEDIATYPECHANGED` 与样本一起返回时
/// 走 `.sample_after_type_change`，没有样本时才报错——调用方已经按一种格式收了
/// 若干字节，中途换格式会让 PCM 拼接失去意义。
/// 返回的 sample 归调用方，必须 `lockSample`（它会 Release）或自行 Release。
pub fn readNext(reader: *anyopaque, stream: u32) Error!ReadResult {
    var empty: u32 = 0;
    while (empty < com.max_empty_reads) : (empty += 1) {
        var actual: u32 = 0;
        var flags: u32 = 0;
        var timestamp: i64 = 0;
        var sample: ?*anyopaque = null;
        const hr = vt(com.IMFSourceReaderVtbl, reader).ReadSample(
            reader,
            stream,
            0,
            &actual,
            &flags,
            &timestamp,
            &sample,
        );
        if (win.failed(hr)) {
            last_hresult = hr;
            return error.Failed;
        }
        if (flags & com.readerf_error != 0) return error.Failed;
        if (sample) |ptr| {
            // 首帧通常带 0x20：类型属性被补齐，但字节已经是协商好的格式。
            if (flags & com.readerf_current_media_type_changed != 0) {
                return .{ .sample_after_type_change = ptr };
            }
            return .{ .sample = ptr };
        }
        if (flags & com.readerf_current_media_type_changed != 0) return error.MediaTypeChanged;
        if (flags & com.readerf_endofstream != 0) return .end_of_stream;
        // STREAMTICK / NEWSTREAM 等没有样本的标记：继续读。
        if (flags & com.readerf_streamtick != 0) continue;
    }
    return error.Failed;
}

// ---------------------------------------------------------------------------
// 样本 → 字节
// ---------------------------------------------------------------------------

/// 一段已锁定的样本内存。`deinit` 依次 Unlock → Release(buffer) → Release(sample)。
pub const Locked = struct {
    sample: *anyopaque,
    buffer: *anyopaque,
    data: []const u8,

    pub fn deinit(self: *Locked) void {
        _ = vt(com.IMFMediaBufferVtbl, self.buffer).Unlock(self.buffer);
        release(self.buffer, com.IMFMediaBufferVtbl);
        release(self.sample, com.IMFSampleVtbl);
        self.* = undefined;
    }
};

/// 把样本合成一块连续内存并锁住。**无论成功失败都接管 sample 引用**：失败时
/// 内部已经 Release，调用方不要再碰它。
pub fn lockSample(sample: *anyopaque) Error!Locked {
    var buffer: ?*anyopaque = null;
    const buffer_hr = vt(com.IMFSampleVtbl, sample).ConvertToContiguousBuffer(sample, &buffer);
    if (win.failed(buffer_hr) or buffer == null) {
        last_hresult = buffer_hr;
        release(sample, com.IMFSampleVtbl);
        return error.Failed;
    }

    var data: ?[*]u8 = null;
    var current: u32 = 0;
    const lock_hr = vt(com.IMFMediaBufferVtbl, buffer.?).Lock(buffer.?, &data, null, &current);
    if (win.failed(lock_hr) or data == null) {
        last_hresult = lock_hr;
        release(buffer.?, com.IMFMediaBufferVtbl);
        release(sample, com.IMFSampleVtbl);
        return error.Failed;
    }
    return .{
        .sample = sample,
        .buffer = buffer.?,
        .data = data.?[0..current],
    };
}

// ---------------------------------------------------------------------------
// 测试：只测与系统无关的纯函数 / 常量（真正解码由 --preview / --play-test 覆盖）
// ---------------------------------------------------------------------------

const testing = std.testing;

test "sizeFromPacked：高 32 位是宽，低 32 位是高" {
    const size = sizeFromPacked((@as(u64, 320) << 32) | 240);
    try testing.expectEqual(@as(u32, 320), size.width);
    try testing.expectEqual(@as(u32, 240), size.height);
    try testing.expectEqual(@as(u32, 0), sizeFromPacked(0).width);
}

test "GUID 常量是 16 字节，且 subtype 比较按字节" {
    try testing.expectEqual(@as(usize, 16), @sizeOf(GUID));
    try testing.expect(std.mem.eql(
        u8,
        std.mem.asBytes(&audio_format_pcm),
        &[_]u8{ 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71 },
    ));
    try testing.expect(std.mem.eql(
        u8,
        std.mem.asBytes(&video_format_rgb32),
        &[_]u8{ 0x16, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71 },
    ));
}

test "Startup 在非 Windows 上是 Unavailable；Windows 上能启动并配对" {
    if (!supported) {
        try testing.expectError(error.Unavailable, Startup.init());
        return;
    }
    var startup = try Startup.init();
    startup.deinit();
    // 再启动一次：配对之后同一线程仍然可以重新初始化（没有泄漏套间计数）。
    var again = try Startup.init();
    again.deinit();
}
