//! Media Foundation 视频 provider：**MP4 / M4V / MOV / WMV 首帧**。
//!
//! 视频首帧也是"一张图"，所以产出的是 `Outcome.image`——不新增 Outcome 分支，
//! 预览条图位、`--preview`、`--nanoui-snapshot` 三条路径零改动就认识它。
//!
//! ## 调用链
//!
//! ```
//! 文件存在？(GetFileAttributesW)             没有 → none.file_missing
//! MFStartup + CoInitializeEx(MTA)
//!   MFCreateAttributes
//!     SetUINT32(MF_SOURCE_READER_ENABLE_ADVANCED_VIDEO_PROCESSING, 1)
//!   MFCreateSourceReaderFromURL                ← 属性必须在这里给
//!   SetStreamSelection(FIRST_VIDEO_STREAM)
//!   MFCreateMediaType
//!     MF_MT_MAJOR_TYPE = MFMediaType_Video
//!     MF_MT_SUBTYPE    = MFVideoFormat_RGB32
//!   SetCurrentMediaType                        ← Video Processor 做 YUV→RGB32
//!   GetCurrentMediaType / MF_MT_FRAME_SIZE / MF_MT_DEFAULT_STRIDE
//!   （at_ms 非空时 SetCurrentPosition，100 ns 单位）
//!   ReadSample 到第一个样本（EOS / ERROR → none.failed）
//!   ConvertToContiguousBuffer → Lock
//!   最近邻缩放到 max_px（长边），BGRA + alpha=255
//! MFShutdown + CoUninitialize
//! ```
//!
//! ## 像素转换：为什么不用 MF 的 Video Processor 缩放
//!
//! MF 确实能在 `SetCurrentMediaType` 时把 `MF_MT_FRAME_SIZE` 设成目标尺寸，
//! 让 Video Processor 顺手缩放。但那要求"输出类型写死目标尺寸"——**缩放策略就
//! 从本文件搬进了驱动/系统组件**：不同机器上 D3D 视频处理器的缩放算法（双线性/
//! 点采样）与对齐规则（某些尺寸会被补齐到 16 的倍数）不一致，会让同一素材在
//! 两台机器上出不同像素。首帧缩略图只需要"看得清是什么"，本文件用**最近邻**
//! 在自己的内存里缩：结果确定、可单元测试、不依赖 D3D 能力。代价是边缘有锯齿，
//! 对 256px 的缩略图可接受。
//!
//! `MFVideoFormat_RGB32` 是 `D3DFMT_X8R8G8B8`：内存字节序就是 **B,G,R,X**，
//! 与 `preview.Bitmap` 的 BGRA 只差第 4 字节。所以这里不做通道交换，只把
//! `X` 写成 255（不透明图，预乘 alpha 下颜色不变）。若某台机器的解码器给的是
//! 自底向上的负 stride（`MF_MT_DEFAULT_STRIDE < 0`），这里按行翻转处理。
//!
//! ## 内存
//!
//! 只读第一帧：SourceReader 自己按块读文件，不把整个 MP4 读进内存。转换后立刻
//! 释放样本缓冲，只留下 ≤ max_px² 的 BGRA 位图。

const std = @import("std");
const core = @import("otto_core");
const mf = @import("mf.zig");
const preview = @import("../preview.zig");

/// 注册表里的这一项。`kind = .image`：产出的是位图（视频首帧）。
pub const provider: preview.Provider = .{
    .name = "mf-video",
    .kind = .image,
    .supports = supports,
    .open = open,
};

const extensions = [_][]const u8{ ".mp4", ".m4v", ".mov", ".wmv" };

pub fn supportsExtension(ext: []const u8) bool {
    if (!mf.supported) return false;
    for (extensions) |candidate| {
        if (std.ascii.eqlIgnoreCase(ext, candidate)) return true;
    }
    return false;
}

/// 只按扩展名声明接手（见报告"为什么不需要能力表"）：容器/编码能不能解，
/// `SetCurrentMediaType` 与第一次 `ReadSample` 会给出诚实的答案。
pub fn supports(sample: *const core.model.Sample) bool {
    return supportsExtension(sample.file_ext);
}

fn open(allocator: std.mem.Allocator, request: preview.Request) preview.Error!preview.Outcome {
    if (!mf.supported) return .{ .none = .unsupported };
    mf.resetDiag();
    const started = mf.nowMs();
    const path = request.sample.file_path;

    const wide = mf.existingWidePath(allocator, path) catch |err| return decline(err, path);
    defer allocator.free(wide);

    var startup = mf.Startup.init() catch |err| return decline(err, path);
    defer startup.deinit();

    // 高级视频处理开关必须在创建 SourceReader 的**那一刻**给：它是 reader 的
    // 构造属性，不是之后能补的类型属性。
    const attributes = mf.createAttributes(2) catch return failed(path, "创建属性");
    defer mf.releaseAttributes(attributes);
    mf.setU32(attributes, &mf.source_reader_enable_advanced_video_processing, 1) catch
        return failed(path, "设置高级视频处理");

    const reader = mf.createReader(wide.ptr, attributes) catch |err| return decline(err, path);
    defer mf.releaseReader(reader);

    mf.selectStream(reader, mf.stream_video) catch return failed(path, "没有视频流");

    const target = mf.createMediaType() catch return failed(path, "创建媒体类型");
    defer mf.releaseMediaType(target);
    mf.setGuid(target, &mf.mt_major_type, &mf.media_type_video) catch return failed(path, "设置主类型");
    mf.setGuid(target, &mf.mt_subtype, &mf.video_format_rgb32) catch return failed(path, "设置 RGB32");
    mf.setCurrentType(reader, mf.stream_video, target) catch return failed(path, "切换到 RGB32");

    const current = mf.currentType(reader, mf.stream_video) catch return failed(path, "读取协商类型");
    defer mf.releaseMediaType(current);
    if (!mf.subtypeIs(current, &mf.video_format_rgb32)) return failed(path, "协商结果不是 RGB32");
    var source_size = mf.frameSize(current) catch return failed(path, "读取帧尺寸");
    var stride = mf.defaultStride(current) orelse 0;

    // at_ms：让 SourceReader 从该时间点往前找关键帧、再解码到目标；不指定就读
    // 文件开头（首帧）。
    if (request.at_ms) |ms| {
        const target_ms: u64 = if (ms <= 0) 0 else @intCast(ms);
        mf.seek(reader, target_ms) catch return failed(path, "seek");
    }

    const sample = switch (mf.readNext(reader, mf.stream_video) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return failed(path, "读取首帧"),
    }) {
        .end_of_stream => return failed(path, "没有可用的视频帧"),
        .sample => |ptr| ptr,
        // 首帧常带 CURRENTMEDIATYPECHANGED（Video Processor 补齐属性）：重新读
        // 协商类型再解释同一块字节，尺寸/stride 以刷新后的为准。
        .sample_after_type_change => |ptr| blk: {
            const changed = mf.currentType(reader, mf.stream_video) catch
                return failed(path, "刷新协商类型");
            defer mf.releaseMediaType(changed);
            if (!mf.subtypeIs(changed, &mf.video_format_rgb32)) return failed(path, "类型变化后不是 RGB32");
            source_size = mf.frameSize(changed) catch return failed(path, "刷新帧尺寸");
            stride = mf.defaultStride(changed) orelse 0;
            break :blk ptr;
        },
    };

    var locked = mf.lockSample(sample) catch return failed(path, "锁定样本");
    defer locked.deinit();

    const bitmap = toBitmap(allocator, .{
        .data = locked.data,
        .width = source_size.width,
        .height = source_size.height,
        .stride = stride,
    }, request.max_px) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidFrame => return failed(path, "帧数据不完整"),
    };

    var at_buffer: [24]u8 = undefined;
    const at_text = if (request.at_ms) |ms|
        std.fmt.bufPrint(&at_buffer, "{d}ms", .{ms}) catch "?"
    else
        "first";

    std.debug.print(
        "otto-lite: mf-video first frame file={s} src={d}x{d} stride={d} dst={d}x{d} at={s} bytes={d} elapsed={d}ms\n",
        .{
            path,
            source_size.width,
            source_size.height,
            stride,
            bitmap.width,
            bitmap.height,
            at_text,
            bitmap.byteLen(),
            mf.nowMs() -| started,
        },
    );

    return .{ .image = bitmap };
}

fn decline(err: mf.Error, path: []const u8) preview.Error!preview.Outcome {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.FileNotFound => .{ .none = .file_missing },
        error.InvalidPath => .{ .none = .unsupported },
        error.Unavailable => blk: {
            std.debug.print(
                "otto-lite: Media Foundation 不可用，MF 视频预览谢绝（{s} hresult=0x{x:0>8}）\n",
                .{ path, @as(u32, @bitCast(mf.lastHresult())) },
            );
            break :blk .{ .none = .failed };
        },
        error.MediaTypeChanged, error.Failed => failed(path, @errorName(err)),
    };
}

/// 一行诊断 + 谢绝。`none.failed` 不是错误：注册表会继续问下一个 provider。
fn failed(path: []const u8, what: []const u8) preview.Outcome {
    std.debug.print(
        "otto-lite: MF 视频预览失败（{s}：{s} hresult=0x{x:0>8}）\n",
        .{ path, what, @as(u32, @bitCast(mf.lastHresult())) },
    );
    return .{ .none = .failed };
}

// ---------------------------------------------------------------------------
// 帧 → 位图（纯函数，可单测；不碰 COM）
// ---------------------------------------------------------------------------

pub const Frame = struct {
    /// SourceReader 锁住的样本字节（RGB32 = 内存里的 B,G,R,X）。
    data: []const u8,
    width: u32,
    height: u32,
    /// `MF_MT_DEFAULT_STRIDE`：行跨距；负值 = 自底向上。0 = 没有该属性。
    stride: i32,
};

pub const ConvertError = error{ OutOfMemory, InvalidFrame };

/// 长边不超过 `max_px`，保持宽高比；**不放大**（小图原样保留，避免糊成一片）。
pub const Size = struct { width: u32, height: u32 };

pub fn fitSize(width: u32, height: u32, max_px: u32) ConvertError!Size {
    if (width == 0 or height == 0) return error.InvalidFrame;
    const longest = @max(width, height);
    const limit: u32 = @max(1, max_px);
    if (longest <= limit) return .{ .width = width, .height = height };
    const scaled_w: u64 = @as(u64, width) * limit / longest;
    const scaled_h: u64 = @as(u64, height) * limit / longest;
    return .{
        .width = @intCast(@max(1, scaled_w)),
        .height = @intCast(@max(1, scaled_h)),
    };
}

/// 把一帧 RGB32 转成 `preview.Bitmap`：最近邻缩放 + alpha 填 255。
pub fn toBitmap(
    allocator: std.mem.Allocator,
    frame: Frame,
    max_px: u32,
) ConvertError!preview.Bitmap {
    if (frame.width == 0 or frame.height == 0) return error.InvalidFrame;

    const min_pitch: usize = @as(usize, frame.width) * 4;
    var pitch: usize = min_pitch;
    if (frame.stride != 0) {
        // 声明的行跨距：取绝对值（负值 = 自底向上），必须容得下一行。
        const declared: i32 = if (frame.stride < 0) -frame.stride else frame.stride;
        pitch = @intCast(declared);
        if (pitch < min_pitch) return error.InvalidFrame;
    } else if (frame.height != 0 and frame.data.len % frame.height == 0) {
        // 没有 stride 属性时，若整块缓冲恰好是 height 行，每行长度就是真实行距
        // （Video Processor 常按 16 字节对齐，pitch 会大于 width*4）。
        const candidate = frame.data.len / frame.height;
        if (candidate >= min_pitch) pitch = candidate;
    }

    const declared_bytes = std.math.mul(usize, pitch, @as(usize, frame.height)) catch return error.InvalidFrame;
    if (frame.data.len < declared_bytes) {
        // 声明/推断的行距比实际缓冲大：退到按实际长度算 pitch。
        pitch = frame.data.len / frame.height;
        if (pitch < min_pitch) return error.InvalidFrame;
        const used = std.math.mul(usize, pitch, @as(usize, frame.height)) catch return error.InvalidFrame;
        if (frame.data.len < used) return error.InvalidFrame;
    }

    const dest = try fitSize(frame.width, frame.height, max_px);
    const dest_stride: usize = @as(usize, dest.width) * 4;
    const total = std.math.mul(usize, dest_stride, @as(usize, dest.height)) catch return error.InvalidFrame;
    const pixels = try allocator.alloc(u8, total);
    errdefer allocator.free(pixels);

    const bottom_up = frame.stride < 0;
    var y: u32 = 0;
    while (y < dest.height) : (y += 1) {
        // 目标行 → 源行（按比例取整，最近邻）。自底向上的输入再翻一次。
        var source_row: u32 = @intCast(@as(u64, y) * frame.height / dest.height);
        if (bottom_up) source_row = frame.height - 1 - source_row;
        const row_offset = @as(usize, source_row) * pitch;

        var x: u32 = 0;
        while (x < dest.width) : (x += 1) {
            const source_x: usize = @intCast(@as(u64, x) * frame.width / dest.width);
            const source = row_offset + source_x * 4;
            const destination = @as(usize, y) * dest_stride + @as(usize, x) * 4;
            pixels[destination + 0] = frame.data[source + 0];
            pixels[destination + 1] = frame.data[source + 1];
            pixels[destination + 2] = frame.data[source + 2];
            // RGB32 的第 4 字节是 X（未定义）；不透明视频统一写 255。预乘 alpha 下
            // 颜色通道不需要乘——alpha 已是 1。
            pixels[destination + 3] = 0xFF;
        }
    }

    return .{
        .pixels = pixels,
        .width = dest.width,
        .height = dest.height,
        .stride = dest_stride,
    };
}

// ---------------------------------------------------------------------------
// 测试：扩展名表、文件缺失、纯缩放/像素转换（真首帧由 --preview 覆盖）
// ---------------------------------------------------------------------------

const testing = std.testing;

fn sampleWith(ext: []const u8) core.model.Sample {
    return .{
        .id = "s1",
        .file_name = "clip",
        .file_ext = ext,
        .file_path = "C:\\lib\\clip.mp4",
    };
}

test "supports：mp4/m4v/mov/wmv 归 MF 视频管，其它不归" {
    if (!mf.supported) return error.SkipZigTest;
    for ([_][]const u8{ ".mp4", ".m4v", ".mov", ".wmv", ".MP4", ".Mov" }) |ext| {
        const sample = sampleWith(ext);
        try testing.expect(supports(&sample));
    }
    for ([_][]const u8{ ".mp3", ".wav", ".mkv", ".avi", ".webm", "" }) |ext| {
        const sample = sampleWith(ext);
        try testing.expect(!supports(&sample));
    }
}

test "open 一个不存在的 mp4：none.file_missing" {
    if (!mf.supported) return error.SkipZigTest;
    const missing = core.model.Sample{
        .id = "gone",
        .file_name = "gone",
        .file_ext = ".mp4",
        .file_path = "C:\\definitely\\not\\here\\otto-missing.mp4",
    };
    const outcome = try open(testing.allocator, .{ .sample = &missing, .max_px = 128 });
    defer outcome.deinit(testing.allocator);
    switch (outcome) {
        .none => |reason| try testing.expectEqual(preview.Reason.file_missing, reason),
        else => return error.ExpectedNone,
    }
}

test "fitSize：长边压到 max_px、保持比例、小图不放大、0 尺寸报错" {
    try testing.expectEqual(Size{ .width = 256, .height = 192 }, try fitSize(320, 240, 256));
    try testing.expectEqual(Size{ .width = 192, .height = 256 }, try fitSize(240, 320, 256));
    try testing.expectEqual(Size{ .width = 100, .height = 50 }, try fitSize(100, 50, 256));
    try testing.expectEqual(Size{ .width = 1, .height = 1 }, try fitSize(100, 50, 1));
    try testing.expectError(error.InvalidFrame, fitSize(0, 50, 256));
    try testing.expectError(error.InvalidFrame, fitSize(50, 0, 256));
}

test "toBitmap：RGB32 的字节序原样进 BGRA，alpha 写 255" {
    // 2×1：第一个像素 B=0x10,G=0x20,R=0x30,X=0x00（X 是垃圾）；第二个像素同理。
    const frame_bytes = [_]u8{
        0x10, 0x20, 0x30, 0x00,
        0x40, 0x50, 0x60, 0xee,
    };
    const bitmap = try toBitmap(testing.allocator, .{
        .data = &frame_bytes,
        .width = 2,
        .height = 1,
        .stride = 8,
    }, 16);
    defer bitmap.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 2), bitmap.width);
    try testing.expectEqual(@as(u32, 1), bitmap.height);
    try testing.expectEqual(@as(usize, 8), bitmap.stride);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x10, 0x20, 0x30, 0xff, 0x40, 0x50, 0x60, 0xff }, bitmap.pixels);
}

test "toBitmap：负 stride = 自底向上，输出仍是顶行在前" {
    // 2×2、stride=-8：data 的第一行是**最下面**那行（0x01.. / 0x02..）。
    const frame_bytes = [_]u8{
        0x01, 0x01, 0x01, 0x00, 0x02, 0x02, 0x02, 0x00, // 底行
        0x03, 0x03, 0x03, 0x00, 0x04, 0x04, 0x04, 0x00, // 顶行
    };
    const bitmap = try toBitmap(testing.allocator, .{
        .data = &frame_bytes,
        .width = 2,
        .height = 2,
        .stride = -8,
    }, 16);
    defer bitmap.deinit(testing.allocator);

    // 输出第 0 行必须是源里的"顶行"（0x03/0x04），第 1 行是底行（0x01/0x02）。
    try testing.expectEqual(@as(u8, 0x03), bitmap.pixels[0]);
    try testing.expectEqual(@as(u8, 0x04), bitmap.pixels[4]);
    try testing.expectEqual(@as(u8, 0x01), bitmap.pixels[8]);
    try testing.expectEqual(@as(u8, 0x02), bitmap.pixels[12]);
}

test "toBitmap：没有 stride 属性时按缓冲长度推断行距（16 字节对齐的补白）" {
    // 2×2、每行补到 16 字节：row0 在 0，row1 在 16；每行只有前 8 字节有效。
    var frame_bytes = std.mem.zeroes([32]u8);
    frame_bytes[0] = 0x11;
    frame_bytes[16] = 0x22;
    const bitmap = try toBitmap(testing.allocator, .{
        .data = &frame_bytes,
        .width = 2,
        .height = 2,
        .stride = 0,
    }, 16);
    defer bitmap.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0x11), bitmap.pixels[0]);
    try testing.expectEqual(@as(u8, 0x22), bitmap.pixels[8]);
}

test "toBitmap：缓冲短于 stride×height 时按实际长度重算，仍不够则 InvalidFrame" {
    const bytes = [_]u8{ 0xaa, 0xbb, 0xcc, 0xff, 0xdd, 0xee, 0x11, 0xff };
    // 声明 stride=16（两行需要 32 字节），实际只有 8 字节：退到 pitch=4，
    // 但 4 < width*4=8 → InvalidFrame。
    try testing.expectError(error.InvalidFrame, toBitmap(testing.allocator, .{
        .data = &bytes,
        .width = 2,
        .height = 2,
        .stride = 16,
    }, 16));
}
