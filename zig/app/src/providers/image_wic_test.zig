//! `image_wic.zig` 的测试：纯尺寸/alpha 计算 + 真 WIC 解码。
//!
//! 为什么单独一个文件：解码器本身（手写 COM + 调用链）加上测试会超过单文件 600 行。
//! 与 `preview_test.zig` / `options_test.zig` 同一条理由：这里只依赖解码器的公开
//! 行为，不碰窗口、不碰 Shell。
//!
//! 真素材用 `C:\src\otto-testkit\samples` 里的 `img00.png` / `img00.bmp`（都是
//! 96×96）；目录不在时 `SkipZigTest`，测试不依赖这台机器的绝对路径。
//! 截断文件用 tmpDir 自己造，不污染素材目录。

const std = @import("std");
const wic = @import("image_wic.zig");

const testing = std.testing;
const io = testing.io;

const samples_dir = "C:\\src\\otto-testkit\\samples";

fn samplePath(buffer: []u8, name: []const u8) []const u8 {
    return std.fmt.bufPrint(buffer, "{s}\\{s}", .{ samples_dir, name }) catch unreachable;
}

fn sampleExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// 素材不在时返回 null，调用方 `SkipZigTest`。
fn existingSample(buffer: []u8, name: []const u8) ?[]const u8 {
    const path = samplePath(buffer, name);
    return if (sampleExists(path)) path else null;
}

fn hasNonZeroPixel(pixels: []const u8) bool {
    for (pixels) |byte| {
        if (byte != 0) return true;
    }
    return false;
}

test "fitDimensions：保持长宽比、短边至少 1、不放大" {
    // 96×96 → 32×32
    const square = wic.fitDimensions(96, 96, 32);
    try testing.expectEqual(@as(u32, 32), square.width);
    try testing.expectEqual(@as(u32, 32), square.height);

    // 200×100 → 32×16（2:1 不变）
    const wide = wic.fitDimensions(200, 100, 32);
    try testing.expectEqual(@as(u32, 32), wide.width);
    try testing.expectEqual(@as(u32, 16), wide.height);

    // 100×200 → 16×32（竖图同理）
    const tall = wic.fitDimensions(100, 200, 32);
    try testing.expectEqual(@as(u32, 16), tall.width);
    try testing.expectEqual(@as(u32, 32), tall.height);

    // 原图不比 max_px 大：不放大，尺寸原样。
    const small = wic.fitDimensions(24, 16, 256);
    try testing.expectEqual(@as(u32, 24), small.width);
    try testing.expectEqual(@as(u32, 16), small.height);

    // 极端长条：短边夹到 1，不会变成 0。
    const line = wic.fitDimensions(1000, 3, 16);
    try testing.expectEqual(@as(u32, 16), line.width);
    try testing.expectEqual(@as(u32, 1), line.height);

    // max_px = 0 视为不限制。
    const unlimited = wic.fitDimensions(96, 48, 0);
    try testing.expectEqual(@as(u32, 96), unlimited.width);
    try testing.expectEqual(@as(u32, 48), unlimited.height);
}

test "premultiplyAlpha：BGRA 原地预乘，255 原样、0 变黑" {
    var pixels = [_]u8{
        200, 100, 50, 255, // 不透明：不动
        200, 100, 50, 128, // 半透明：各通道 × 128/255
        200, 100, 50, 0, // 全透明：颜色归零
    };
    wic.premultiplyAlpha(pixels[0..]);
    try testing.expectEqual(@as(u8, 200), pixels[0]);
    try testing.expectEqual(@as(u8, 100), pixels[1]);
    try testing.expectEqual(@as(u8, 50), pixels[2]);
    try testing.expectEqual(@as(u8, 100), pixels[4]);
    try testing.expectEqual(@as(u8, 50), pixels[5]);
    try testing.expectEqual(@as(u8, 25), pixels[6]);
    try testing.expectEqual(@as(u8, 0), pixels[8]);
    try testing.expectEqual(@as(u8, 0), pixels[9]);
    try testing.expectEqual(@as(u8, 0), pixels[10]);
}

test "解码 img00.png：96×96、stride=384、像素非空" {
    if (!wic.supported) return error.SkipZigTest;
    var buffer: [256]u8 = undefined;
    const path = existingSample(&buffer, "img00.png") orelse return error.SkipZigTest;

    const image = try wic.decode(testing.allocator, path, 256);
    defer image.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 96), image.width);
    try testing.expectEqual(@as(u32, 96), image.height);
    try testing.expectEqual(@as(usize, 96 * 4), image.stride);
    try testing.expectEqual(@as(usize, 96 * 96 * 4), image.pixels.len);
    try testing.expect(hasNonZeroPixel(image.pixels));
    // 原图不比 256 大：不需要 scaler。
    try testing.expect(!wic.lastUsedScaler());
}

test "解码 img00.bmp：96×96、stride=384、像素非空" {
    if (!wic.supported) return error.SkipZigTest;
    var buffer: [256]u8 = undefined;
    const path = existingSample(&buffer, "img00.bmp") orelse return error.SkipZigTest;

    const image = try wic.decode(testing.allocator, path, 256);
    defer image.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 96), image.width);
    try testing.expectEqual(@as(u32, 96), image.height);
    try testing.expectEqual(@as(usize, 96 * 4), image.stride);
    try testing.expectEqual(@as(usize, 96 * 96 * 4), image.pixels.len);
    try testing.expect(hasNonZeroPixel(image.pixels));
}

test "max_px=32 时输出 ≤32 且长宽比正确（方形图仍为 1:1）" {
    if (!wic.supported) return error.SkipZigTest;
    var buffer: [256]u8 = undefined;
    const path = existingSample(&buffer, "img00.png") orelse return error.SkipZigTest;

    const image = try wic.decode(testing.allocator, path, 32);
    defer image.deinit(testing.allocator);

    try testing.expect(image.width <= 32);
    try testing.expect(image.height <= 32);
    try testing.expectEqual(@as(u32, 32), image.width);
    try testing.expectEqual(@as(u32, 32), image.height);
    // 真的缩了，而且用的是 WIC 自己的 scaler。
    try testing.expect(wic.lastUsedScaler());
}

test "文件不存在：FileNotFound（provider 会把它映射成 none.file_missing）" {
    if (!wic.supported) return error.SkipZigTest;
    var buffer: [256]u8 = undefined;
    const path = samplePath(&buffer, "definitely-missing-otto-image.png");
    const got = wic.decode(testing.allocator, path, 128);
    try testing.expectError(error.FileNotFound, got);
}

test "截断的 PNG：Failed，不崩" {
    if (!wic.supported) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var sample_buffer: [256]u8 = undefined;
    const original = existingSample(&sample_buffer, "img00.png");
    if (original) |path| {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, testing.allocator, .limited(1024 * 1024));
        defer testing.allocator.free(bytes);
        // 只留签名：最严格的"截断 PNG"。截到 120 字节时 WIC 会宽容地解出半张图，
        // 那不是我们要测的失败路径。
        try tmp.dir.writeFile(io, .{ .sub_path = "truncated.png", .data = bytes[0..@min(bytes.len, 8)] });
    } else {
        // 素材不在：至少给一个"签名像 PNG、后面是垃圾"的文件。
        try tmp.dir.writeFile(io, .{ .sub_path = "truncated.png", .data = "\x89PNG\r\n\x1a\n" ++ "not-a-real-png" });
    }

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}\\truncated.png", .{root_buffer[0..root_len]});

    const got = wic.decode(testing.allocator, path, 256);
    if (got) |image| {
        // 真解出来也不算崩，但这条用例要的是"坏文件被谢绝"。释放后报错。
        image.deinit(testing.allocator);
        return error.TestUnexpectedResult;
    } else |err| {
        try testing.expectEqual(@as(anyerror, error.Failed), err);
    }
}
