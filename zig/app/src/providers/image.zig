//! 图片 provider：**自己解码**的 PNG / JPEG / BMP / GIF / TIFF（WIC，不是 Shell）。
//!
//! 这是「每种 provider 自给自足、彼此平等」这条架构规则的第一个落地：图片不再靠
//! 这台机器上装没装图片软件、有没有注册 `IThumbnailProvider`，也不再经过 Shell 的
//! 第三方 COM handler。`supports` 只看扩展名（廉价声明，不读注册表、不打开文件），
//! `open` 里 WIC 按**文件内容**选解码器，所以我们声明的七种格式在任意 Windows 上
//! 都有同一套行为。
//!
//! 结局映射（四态不许合并，见 `preview.zig` / CHARTER「一」）：
//!
//!   * 解码成功                    → `image`（BGRA8、预乘 alpha、顶行在前）
//!   * 文件不存在 / 路径没了        → `none.file_missing`
//!   * 路径非法 / 非 Windows        → `none.unsupported`
//!   * 坏图、权限、WIC 意外         → `none.failed`
//!
//! `none.*` 是**谢绝**：注册表会继续问下一个 provider。所以这个 provider 只声明
//! 七种栅格格式，PSD / AI / BLEND 之类天然落到 `shell-thumbnail`（或者两者都谢绝），
//! 而不是让 Shell 抢在图片解码前面。
//!
//! 缩放策略与 WIC 调用链在 `image_wic.zig` 的文件头：优先用 WIC 的
//! `IWICBitmapScaler`（不自己写重采样），它不可用时退回原尺寸并在 stderr 说明；
//! 原图不比 `max_px` 大时不放大。
//!
//! 线程：`open` 是同步阻塞的，和所有 provider 一样**不在 UI 线程上调**——预览条
//! 的工作线程负责调它。WIC 是系统 DLL，没有第三方 handler 的崩溃风险，将来即使
//! provider 都搬进 helper 进程，这个 provider 留在进程内也不会打穿别人。
//!
//! 只依赖 Zig 0.17 标准库、`otto_core` 与 `image_wic.zig`；没有 @cImport、没有 C shim。

const std = @import("std");
const builtin = @import("builtin");
const core = @import("otto_core");
const image_wic = @import("image_wic.zig");
const preview = @import("../preview.zig");

/// 注册表里的这一项。`kind = .image`：它产出的永远是位图。
pub const provider: preview.Provider = .{
    .name = "image-wic",
    .kind = .image,
    .supports = supports,
    .open = open,
    // 列表行内的 32pt 小图也归这里：PNG/BMP 的行内图与预览图走同一条 WIC 解码链，
    // 不再为了一个 32px 图标去问 Shell。
    .icon_capable = true,
};

/// 本 provider 自己负责的栅格格式。**故意不含 `.psd` / `.ai` / `.blend`**：
/// 那些没有系统解码器，应该轮到 Shell 的第三方 handler（或诚实地说没有预览）。
const extensions = [_][]const u8{ "png", "jpg", "jpeg", "bmp", "gif", "tif", "tiff" };

/// 廉价声明：按扩展名。大小写不敏感，`file_ext` 带不带点都收（`Sample` 的约定是
/// 带点，但这里不把格式判断绑在某个字段的拼写上）。
///
/// **不查注册表、不问 Shell、不分配内存**：这台机器有没有 WIC 由 `open` 回答，
/// 而 WIC 是系统组件，不存在"这个扩展名在这台机器上没有解码器"的可发现状态。
pub fn supports(sample: *const core.model.Sample) bool {
    if (builtin.os.tag != .windows) return false;
    var ext = sample.file_ext;
    if (ext.len == 0) return false;
    if (ext[0] == '.') ext = ext[1..];
    for (extensions) |known| {
        if (std.ascii.eqlIgnoreCase(ext, known)) return true;
    }
    return false;
}

fn open(allocator: std.mem.Allocator, request: preview.Request) preview.Error!preview.Outcome {
    const got = image_wic.decode(allocator, request.sample.file_path, request.max_px) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unsupported => return .{ .none = .unsupported },
        error.FileNotFound => return .{ .none = .file_missing },
        error.AccessDenied, error.Failed => |code| {
            std.debug.print(
                "otto-lite: 图片解码失败 {s}（{s} hresult=0x{x:0>8}）\n",
                .{ request.sample.file_path, @errorName(code), @as(u32, @bitCast(image_wic.lastHresult())) },
            );
            return .{ .none = .failed };
        },
    };

    // WIC 承诺 BGRA + stride == width*4；和 Shell provider 一样不把坏跨度交给视图。
    if (got.stride != @as(usize, got.width) * 4) {
        got.deinit(allocator);
        return .{ .none = .failed };
    }

    return .{ .image = .{
        .pixels = got.pixels,
        .width = got.width,
        .height = got.height,
        .stride = got.stride,
    } };
}

// ---------------------------------------------------------------------------
// 测试：supports / 文件缺失 / 损坏文件；真解码在 image_wic.zig（同一份代码）
// ---------------------------------------------------------------------------

const testing = std.testing;

fn sampleWith(ext: []const u8) core.model.Sample {
    return .{
        .id = "s1",
        .file_name = "img00",
        .file_ext = ext,
        .file_path = "C:\\lib\\img00.png",
    };
}

test "supports：七种栅格格式归图片管，大小写不敏感，带不带点都收" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    for ([_][]const u8{ ".png", ".jpg", ".jpeg", ".bmp", ".gif", ".tif", ".tiff", ".PNG", ".Jpeg", "png" }) |ext| {
        const sample = sampleWith(ext);
        try testing.expect(supports(&sample));
    }
}

test "supports：PSD / AI / BLEND / 未知扩展名不归图片管（留给 Shell）" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    for ([_][]const u8{ ".psd", ".ai", ".blend", ".xyz", ".mp4", "" }) |ext| {
        const sample = sampleWith(ext);
        try testing.expect(!supports(&sample));
    }
}

test "open 一个不存在的 png：none.file_missing（不崩、不碰 Shell）" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const missing = core.model.Sample{
        .id = "gone",
        .file_name = "gone",
        .file_ext = ".png",
        .file_path = "C:\\definitely\\not\\here\\otto-missing.png",
    };
    const outcome = try open(testing.allocator, .{ .sample = &missing, .max_px = 128 });
    defer outcome.deinit(testing.allocator);
    switch (outcome) {
        .none => |reason| try testing.expectEqual(preview.Reason.file_missing, reason),
        else => return error.ExpectedNone,
    }
}

test "open 一个坏 png：none.failed（不崩）" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "broken.png",
        .data = "\x89PNG\r\n\x1a\n" ++ "not-a-real-png",
    });

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(testing.io, &root_buffer);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}\\broken.png", .{root_buffer[0..root_len]});

    const broken = core.model.Sample{
        .id = "broken",
        .file_name = "broken",
        .file_ext = ".png",
        .file_path = path,
    };
    const outcome = try open(testing.allocator, .{ .sample = &broken, .max_px = 128 });
    defer outcome.deinit(testing.allocator);
    switch (outcome) {
        .none => |reason| try testing.expectEqual(preview.Reason.failed, reason),
        else => return error.ExpectedNone,
    }
}
