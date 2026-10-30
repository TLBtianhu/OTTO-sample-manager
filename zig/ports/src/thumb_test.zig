//! 缩略图口岸测试：真文件 + 真 Shell + 真 COM，没有 mock。
//!
//! 规矩（照抄 watch_test.zig）：
//!   * 每个用例一个自己的 tmpDir，互不干扰；
//!   * 不创建窗口、不抢焦点——`get()` 里没有 UI，Shell 的缩略图也不该弹窗；
//!   * 无 handler 的机器上，第 4 / 第 5 条用 `error.SkipZigTest` 跳过并打印实测结果，
//!     绝不为了"测试绿"伪造断言。
//!
//! 前三条是任务要求的契约：
//!   1. 临时目录里手写一个 48×32 的 BMP → get 成功、尺寸与像素长度对得上；
//!   2. 不存在的路径 → error.FileNotFound；
//!   3. 同一文件请求两个不同尺寸 → 两次都成功，且不共享缓冲（无全局状态）。

const std = @import("std");
const thumb = @import("thumb.zig");
const win = @import("thumb_win.zig");

const allocator = std.testing.allocator;
const io = std.testing.io;

// ---------------------------------------------------------------------------
// 装置
// ---------------------------------------------------------------------------

const Fixture = struct {
    tmp: std.testing.TmpDir,
    root: [std.Io.Dir.max_path_bytes]u8 = undefined,
    root_len: usize = 0,

    fn init() !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const length = try tmp.dir.realPath(io, &buffer);
        return .{ .tmp = tmp, .root = buffer, .root_len = length };
    }

    fn deinit(self: *Fixture) void {
        self.tmp.cleanup();
    }

    fn path(self: *const Fixture, buffer: []u8, name: []const u8) ![]const u8 {
        return std.fmt.bufPrint(buffer, "{s}{s}{s}", .{
            self.root[0..self.root_len],
            std.fs.path.sep_str,
            name,
        });
    }

    fn write(self: *Fixture, name: []const u8, bytes: []const u8) !void {
        try self.tmp.dir.writeFile(io, .{ .sub_path = name, .data = bytes });
    }
};

/// 手写最小 24bpp BMP（BI_RGB、行按 4 字节对齐、文件里自下而上存）。
/// 上半红、下半蓝：既能验证"顶行在前"，也能验证 BGRA 的通道顺序。
fn buildBmp(allocator_: std.mem.Allocator, width: u32, height: u32) ![]u8 {
    const stride = (width * 3 + 3) & ~@as(u32, 3);
    const pixel_bytes = try std.math.mul(usize, stride, height);
    const total = 54 + pixel_bytes;
    const bytes = try allocator_.alloc(u8, total);
    errdefer allocator_.free(bytes);
    @memset(bytes, 0);

    // BITMAPFILEHEADER（14 字节）
    bytes[0] = 'B';
    bytes[1] = 'M';
    std.mem.writeInt(u32, bytes[2..6], @intCast(total), .little);
    std.mem.writeInt(u32, bytes[10..14], 54, .little);
    // BITMAPINFOHEADER（40 字节）
    std.mem.writeInt(u32, bytes[14..18], 40, .little);
    std.mem.writeInt(i32, bytes[18..22], @intCast(width), .little);
    std.mem.writeInt(i32, bytes[22..26], @intCast(height), .little);
    std.mem.writeInt(u16, bytes[26..28], 1, .little);
    std.mem.writeInt(u16, bytes[28..30], 24, .little);
    std.mem.writeInt(u32, bytes[34..38], @intCast(pixel_bytes), .little);

    // 文件里的第 0 行是图像最下面一行（bottom-up）。
    var file_row: u32 = 0;
    while (file_row < height) : (file_row += 1) {
        const image_row = height - 1 - file_row;
        const top_half = image_row < height / 2;
        var column: u32 = 0;
        while (column < width) : (column += 1) {
            const offset = 54 + file_row * stride + column * 3;
            if (top_half) {
                bytes[offset + 0] = 0; // B
                bytes[offset + 1] = 0; // G
                bytes[offset + 2] = 255; // R
            } else {
                bytes[offset + 0] = 255; // B
                bytes[offset + 1] = 0; // G
                bytes[offset + 2] = 0; // R
            }
        }
    }
    return bytes;
}

/// 取像素（顶行在前、BGRA）的一个通道。
fn channel(image: thumb.Thumbnail, x: u32, y: u32, offset: usize) u8 {
    return image.pixels[@as(usize, y) * image.stride + @as(usize, x) * 4 + offset];
}

// ---------------------------------------------------------------------------
// 1. 核心契约：真 BMP → 真缩略图
// ---------------------------------------------------------------------------

test "真 BMP：get 成功，尺寸/像素长度/字节序/顶行在前都对" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    const bmp = try buildBmp(allocator, 48, 32);
    defer allocator.free(bmp);
    try fixture.write("sample.bmp", bmp);

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try fixture.path(&buffer, "sample.bmp");

    var image = try thumb.get(allocator, path, 48);
    defer image.deinit(allocator);

    try std.testing.expect(image.width > 0);
    try std.testing.expect(image.height > 0);
    try std.testing.expect(image.pixels.len >= @as(usize, image.width) * image.height * 4);
    try std.testing.expectEqual(@as(usize, image.width) * 4, image.stride);
    try std.testing.expectEqual(image.stride * image.height, image.pixels.len);

    // 顶行中心是红、底行中心是蓝：同时证明"顶行在前"和 BGRA 通道顺序。
    const mid_x = image.width / 2;
    const top = image.height - 1;
    const top_red = channel(image, mid_x, 0, 2);
    const top_blue = channel(image, mid_x, 0, 0);
    const bottom_red = channel(image, mid_x, top, 2);
    const bottom_blue = channel(image, mid_x, top, 0);
    try std.testing.expect(top_red > 200 and top_blue < 60);
    try std.testing.expect(bottom_blue > 200 and bottom_red < 60);
    // 图像不透明，alpha 应被归一化成 255（GetDIBits 的 0 → 255 分支）。
    try std.testing.expectEqual(@as(u8, 255), channel(image, mid_x, 0, 3));
}

// ---------------------------------------------------------------------------
// 2. 文件不存在
// ---------------------------------------------------------------------------

test "不存在的路径 → error.FileNotFound" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try fixture.path(&buffer, "no-such-file.bmp");

    try std.testing.expectError(error.FileNotFound, thumb.get(allocator, path, 64));
    // 错误保留平台码供日志：HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND) = 0x80070002。
    try std.testing.expectEqual(@as(i32, @bitCast(@as(u32, 0x8007_0002))), thumb.lastFailure().code);
}

// ---------------------------------------------------------------------------
// 3. 两次不同尺寸：不依赖全局状态
// ---------------------------------------------------------------------------

test "同一文件两个尺寸：都成功、缓冲互不共享" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    const bmp = try buildBmp(allocator, 48, 32);
    defer allocator.free(bmp);
    try fixture.write("twice.bmp", bmp);

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try fixture.path(&buffer, "twice.bmp");

    var small = try thumb.get(allocator, path, 32);
    defer small.deinit(allocator);
    var large = try thumb.get(allocator, path, 96);
    defer large.deinit(allocator);

    for ([_]*const thumb.Thumbnail{ &small, &large }) |image| {
        try std.testing.expect(image.width > 0);
        try std.testing.expect(image.height > 0);
        try std.testing.expectEqual(@as(usize, image.width) * 4, image.stride);
        try std.testing.expectEqual(image.stride * image.height, image.pixels.len);
    }

    // 两次调用各自分配：不是同一个全局缓冲，改小的不影响大的。
    try std.testing.expect(small.pixels.ptr != large.pixels.ptr);
    @memset(small.pixels, 0);
    try std.testing.expectEqual(@as(u8, 255), channel(large, large.width / 2, 0, 3));
}

// ---------------------------------------------------------------------------
// 4. 能力探测：无预览 handler 的机器应 Skip，而不是失败
// ---------------------------------------------------------------------------

test "能力探测：BMP 缩略图（无 handler 的机器 Skip）" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    const bmp = try buildBmp(allocator, 48, 32);
    defer allocator.free(bmp);
    try fixture.write("probe.bmp", bmp);

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try fixture.path(&buffer, "probe.bmp");

    // 先真试一次，再决定断言还是跳过；跳过时把实测原因打到 CI 日志里。
    const attempt = thumb.get(allocator, path, 64);
    if (attempt) |value| {
        var image = value;
        defer image.deinit(allocator);
        try std.testing.expect(image.width > 0 and image.height > 0);
    } else |err| switch (err) {
        error.NoHandler => {
            std.debug.print(
                "BMP 缩略图：本机 Shell 返回 NoHandler（HRESULT=0x{X:0>8}），按约定 Skip\n",
                .{@as(u32, @bitCast(thumb.lastFailure().code))},
            );
            return error.SkipZigTest;
        },
        else => {
            std.debug.print("BMP 缩略图：失败 {s}（HRESULT=0x{X:0>8}）\n", .{
                @errorName(err),
                @as(u32, @bitCast(thumb.lastFailure().code)),
            });
            return err;
        },
    }
}

// ---------------------------------------------------------------------------
// 5. 三态中的 NoHandler：无 handler 的扩展名
// ---------------------------------------------------------------------------

test "无 handler 的扩展名 → error.NoHandler（有 codec pack 认领时 Skip）" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.write("mystery.otto_probe", "not a media file at all");

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try fixture.path(&buffer, "mystery.otto_probe");

    const attempt = thumb.get(allocator, path, 64);
    if (attempt) |value| {
        var image = value;
        defer image.deinit(allocator);
        // 某个 shell extension 认领了这个扩展名：本机不适用这条断言，跳过。
        std.debug.print(
            ".otto_probe 在本机有 handler（{d}×{d}）：跳过 NoHandler 断言\n",
            .{ image.width, image.height },
        );
        return error.SkipZigTest;
    } else |err| switch (err) {
        // 本机实测：GetImage 返回 0x8004B200（WTS_E_FAILEDEXTRACTION）+ 空位图。
        // 不断言具体 HRESULT：S_OK + 空位图也是合法的 NoHandler 表现。
        error.NoHandler => {},
        else => {
            std.debug.print(".otto_probe 失败 {s}（HRESULT=0x{X:0>8}）\n", .{
                @errorName(err),
                @as(u32, @bitCast(thumb.lastFailure().code)),
            });
            return err;
        },
    }
}

test "allow_icon_fallback：无 handler 时退回通用图标（连图标都给不出就 Skip）" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.write("fallback.otto_probe", "still not a media file");

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try fixture.path(&buffer, "fallback.otto_probe");

    var image = thumb.getWithOptions(allocator, path, 64, .{ .allow_icon_fallback = true }) catch |err| switch (err) {
        error.NoHandler => return error.SkipZigTest,
        else => return err,
    };
    defer image.deinit(allocator);
    try std.testing.expect(image.width > 0 and image.height > 0);
}

// ---------------------------------------------------------------------------
// 参数校验（纯 Zig，不进 Shell）
// ---------------------------------------------------------------------------

test "空路径 → error.InvalidPath；尺寸 0 → error.InvalidSize" {
    try std.testing.expectError(error.InvalidPath, thumb.get(allocator, "", 64));
    try std.testing.expectError(error.InvalidSize, thumb.get(allocator, "C:\\whatever.bmp", 0));
}

// ---------------------------------------------------------------------------
// alpha 归一化（纯函数，不需要 Shell）
// ---------------------------------------------------------------------------

test "normalizeAlpha：整幅 alpha=0 填 255，颜色不动" {
    var pixels = [_]u8{
        10, 20, 30, 0,
        40, 50, 60, 0,
    };
    thumb.normalizeAlpha(&pixels);
    try std.testing.expectEqualSlices(u8, &.{ 10, 20, 30, 255, 40, 50, 60, 255 }, &pixels);
}

test "normalizeAlpha：已经预乘的数据原样保留" {
    var pixels = [_]u8{
        0,   0,   0,   0,
        64,  32,  16,  128,
        255, 255, 255, 255,
    };
    const before = pixels;
    thumb.normalizeAlpha(&pixels);
    try std.testing.expectEqualSlices(u8, &before, &pixels);
}

test "normalizeAlpha：直通 alpha 按 alpha/255 预乘（四舍五入）" {
    var pixels = [_]u8{
        255, 128, 64, 128,
    };
    thumb.normalizeAlpha(&pixels);
    try std.testing.expectEqualSlices(u8, &.{ 128, 64, 32, 128 }, &pixels);
}

test "normalizeAlpha：全不透明是恒等变换" {
    var pixels = [_]u8{
        1, 2, 3, 255,
        4, 5, 6, 255,
    };
    const before = pixels;
    thumb.normalizeAlpha(&pixels);
    try std.testing.expectEqualSlices(u8, &before, &pixels);
}

// ---------------------------------------------------------------------------
// 诊断：平台错误码是线程局部的，成功时清零
// ---------------------------------------------------------------------------

test "lastFailure：成功时 HRESULT 清零" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    const bmp = try buildBmp(allocator, 48, 32);
    defer allocator.free(bmp);
    try fixture.write("diag.bmp", bmp);

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try fixture.path(&buffer, "diag.bmp");

    var image = thumb.get(allocator, path, 48) catch |err| switch (err) {
        error.NoHandler => return error.SkipZigTest, // 无 handler 的机器
        else => return err,
    };
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(i32, 0), thumb.lastFailure().code);
    try std.testing.expectEqual(@as(i32, 0), win.lastHresult());
}
