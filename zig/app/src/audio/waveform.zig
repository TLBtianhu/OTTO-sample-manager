//! 波形渲染：`peaks.Peaks` → BGRA 位图，形状与 `preview.Bitmap` 完全一致
//! （每像素 4 字节、`stride == width * 4`、顶行在前、alpha 预乘）。
//!
//! 为什么不给 nanoui 加画布 API：见报告——nanoui 已经有 `ui.image` 这条成熟路径
//! （像素进图集，GPU/CPU 两个后端都认），波形又只是"每列一对 min/max"的纯数据。
//! 渲染成一张 240×56 的图（52.5 KiB）比在 nanoui 里新开一套绘图 API 便宜得多：
//! 后者要过两个后端、要管裁剪与层叠，而本应用只需要"把已知的像素放上去"。
//!
//! 画法：
//!   * 每列一根竖直条，覆盖这一列所有桶的 min..max（列比桶少时先合并桶）；
//!   * `+32767` 映射到最上一行、`-32768` 映射到最下一行，整数除法，不除零；
//!   * **背景透明**（alpha = 0）：调用方决定"轨道"的底色，同一张位图还能被
//!     `ui.image` 的 tint 直接染成主题色，深浅两套主题都不用重新渲染；
//!   * 静音时 min == max == 0，画出来就是中间一条 1 像素细线。
//!
//! 纯函数：不碰磁盘、不碰线程、不 import nanoui。只分配一块像素内存，
//! 由调用方用同一个 allocator 调 `Bitmap.deinit` 释放。

const std = @import("std");
const peaks_mod = @import("peaks.zig");
const preview = @import("../preview.zig");

/// 默认尺寸（像素）：240 是预览条"整条区域"的可用宽度（380 窗口 − 边距 − 图位），
/// 56 够画出包络，又给两行事实和播放键留出纵向空间。
pub const default_width: u32 = 240;
pub const default_height: u32 = 56;

/// 竖条颜色。白色不是"白底"：调用方用 tint 把它染成主题强调色；
/// 不 tint 时白条在深浅两个轨道底色上都看得清。
pub const Color = struct { r: u8, g: u8, b: u8, a: u8 = 0xff };

pub const default_color: Color = .{ .r = 0xff, .g = 0xff, .b = 0xff, .a = 0xff };

pub const Error = std.mem.Allocator.Error;

/// 把峰值画成一张 `width` × `height` 的 BGRA 位图。
///
/// 空 peaks 也是一张合法的（全透明）位图：视图可以照常画，不需要额外判空。
pub fn render(
    allocator: std.mem.Allocator,
    peaks: peaks_mod.Peaks,
    width: u32,
    height: u32,
    color: Color,
) Error!preview.Bitmap {
    // 0 宽/0 高在 UI 里没有意义（`ui.image` 会直接拒绝），夹到 1 免得除零。
    const w: u32 = @max(1, width);
    const h: u32 = @max(1, height);
    const stride: usize = @as(usize, w) * 4;
    const pixels = try allocator.alloc(u8, stride * @as(usize, h));
    errdefer allocator.free(pixels);
    // 透明背景：预乘 alpha 下 RGB 也必须是 0，否则半透明处会泛白。
    @memset(pixels, 0);

    const bitmap: preview.Bitmap = .{
        .pixels = pixels,
        .width = w,
        .height = h,
        .stride = stride,
    };
    if (peaks.len() == 0) return bitmap;

    var x: u32 = 0;
    while (x < w) : (x += 1) {
        // 这一列覆盖的桶区间：列比桶多时多列共用一个桶，列比桶少时先合并
        // （否则 512 桶画 240 列会随机丢掉一半峰值，波形会"抖"）。
        const first: usize = @as(usize, x) * peaks.len() / w;
        const next: usize = (@as(usize, x) + 1) * peaks.len() / w;
        const last = if (next > first) next else first + 1;
        var low: i16 = peaks.min[first];
        var high: i16 = peaks.max[first];
        var index = first + 1;
        while (index < last) : (index += 1) {
            low = @min(low, peaks.min[index]);
            high = @max(high, peaks.max[index]);
        }

        const top = rowFor(high, h);
        const bottom = @max(top, rowFor(low, h));
        var y = top;
        while (y <= bottom) : (y += 1) {
            const at = @as(usize, y) * stride + @as(usize, x) * 4;
            // BGRA + 预乘：a == 0xff 时 RGB 原样即可。
            pixels[at] = color.b;
            pixels[at + 1] = color.g;
            pixels[at + 2] = color.r;
            pixels[at + 3] = color.a;
        }
    }

    return bitmap;
}

/// 采样值 → 行号：`+32767` 是第 0 行（顶），`-32768` 是最后一行。
/// 归一化用 `(v + 32768) / 65536`，所以静音（0）正好在正中：56 行时是第 27/28
/// 行之间的上方那行（55 是奇数，取整到 27），9 行时正好是第 4 行。
fn rowFor(value: i16, height: u32) u32 {
    const span: i64 = @as(i64, height) - 1;
    if (span <= 0) return 0;
    const numerator = (32768 - @as(i64, value)) * span;
    const row = @divTrunc(numerator, 65536);
    return @intCast(std.math.clamp(row, 0, span));
}

/// 进度竖线的左边缘（像素）：`position / duration` 映射到 `0 .. width - line`。
/// duration 为 0、position 越界、line 比 width 宽都夹住，不产生负偏移或越界。
/// 放在这里而不是视图里：它是纯几何，能在没有窗口的测试里验证。
pub fn progressX(width: u32, position_ms: u64, duration_ms: u64, line: u32) u32 {
    if (duration_ms == 0 or width == 0) return 0;
    const usable = width -| @min(width, line);
    if (usable == 0) return 0;
    const clamped = @min(position_ms, duration_ms);
    return @intCast(@as(u64, usable) * clamped / duration_ms);
}

/// 波形上点击的 x 偏移（点，相对波形左边缘）→ 目标毫秒。
/// `0` 在左端、`width` 在右端；点击越界时夹到两端，四舍五入到整毫秒。
/// 纯几何，放在这里能在没有窗口的测试里验证；视图只负责把鼠标坐标减掉矩形原点。
pub fn positionMsAt(offset_x: f32, width: f32, duration_ms: u64) u64 {
    if (width <= 0 or duration_ms == 0) return 0;
    const fraction = std.math.clamp(offset_x / width, 0, 1);
    const ms: f32 = @round(fraction * @as(f32, @floatFromInt(duration_ms)));
    return @intFromFloat(@max(0, ms));
}

// ---------------------------------------------------------------------------
// 测试：纯内存，不碰窗口（需要的人眼确认交给 `--nanoui-snapshot`）
// ---------------------------------------------------------------------------

const testing = std.testing;

fn peaksOf(min: []const i16, max: []const i16) peaks_mod.Peaks {
    return .{ .min = @constCast(min), .max = @constCast(max) };
}

test "尺寸：width/height/stride/像素数，stride == width * 4" {
    const mins = [_]i16{ -1000, -2000 };
    const maxs = [_]i16{ 1000, 2000 };
    const bitmap = try render(
        testing.allocator,
        peaksOf(&mins, &maxs),
        default_width,
        default_height,
        default_color,
    );
    defer bitmap.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, default_width), bitmap.width);
    try testing.expectEqual(@as(u32, default_height), bitmap.height);
    try testing.expectEqual(@as(usize, default_width * 4), bitmap.stride);
    try testing.expectEqual(@as(usize, 240 * 56 * 4), bitmap.byteLen());
    try testing.expectEqual(bitmap.stride * default_height, bitmap.pixels.len);
}

test "静音：中间一条 1 像素细线，其余全透明" {
    const mins = [_]i16{ 0, 0 };
    const maxs = [_]i16{ 0, 0 };
    // 9 行（奇数）：正中是第 4 行，映射没有取整歧义。
    const bitmap = try render(testing.allocator, peaksOf(&mins, &maxs), 8, 9, default_color);
    defer bitmap.deinit(testing.allocator);

    var y: u32 = 0;
    while (y < bitmap.height) : (y += 1) {
        var x: u32 = 0;
        while (x < bitmap.width) : (x += 1) {
            const alpha = bitmap.pixels[@as(usize, y) * bitmap.stride + @as(usize, x) * 4 + 3];
            if (y == 4) {
                try testing.expectEqual(@as(u8, 0xff), alpha);
            } else {
                try testing.expectEqual(@as(u8, 0), alpha);
            }
        }
    }
}

test "满幅：每列从第一行画到最后一行，BGRA 顺序正确" {
    const mins = [_]i16{-32768};
    const maxs = [_]i16{32767};
    const bitmap = try render(
        testing.allocator,
        peaksOf(&mins, &maxs),
        4,
        6,
        .{ .r = 0x11, .g = 0x22, .b = 0x33, .a = 0xff },
    );
    defer bitmap.deinit(testing.allocator);

    var y: u32 = 0;
    while (y < bitmap.height) : (y += 1) {
        const at = @as(usize, y) * bitmap.stride;
        // BGRA：蓝、绿、红、alpha。
        try testing.expectEqual(@as(u8, 0x33), bitmap.pixels[at]);
        try testing.expectEqual(@as(u8, 0x22), bitmap.pixels[at + 1]);
        try testing.expectEqual(@as(u8, 0x11), bitmap.pixels[at + 2]);
        try testing.expectEqual(@as(u8, 0xff), bitmap.pixels[at + 3]);
    }
}

test "空 peaks：位图仍按尺寸分配，内容全透明" {
    const bitmap = try render(testing.allocator, .{}, 5, 3, default_color);
    defer bitmap.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 5 * 3 * 4), bitmap.pixels.len);
    for (bitmap.pixels) |byte| try testing.expectEqual(@as(u8, 0), byte);
}

test "不越界写：像素区之后的哨兵字节原样保留" {
    // FixedBufferAllocator 把整块缓冲区当堆：渲染写出的字节之外必须全是 0xAA。
    var buffer: [4096]u8 align(8) = @splat(0xAA);
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    const mins = [_]i16{-32768};
    const maxs = [_]i16{32767};
    const bitmap = try render(fba.allocator(), peaksOf(&mins, &maxs), 16, 8, default_color);

    const start = @intFromPtr(bitmap.pixels.ptr) - @intFromPtr(buffer[0..].ptr);
    try testing.expect(start + bitmap.pixels.len <= buffer.len);
    for (buffer[start + bitmap.pixels.len ..]) |byte| {
        try testing.expectEqual(@as(u8, 0xAA), byte);
    }
}

test "progressX：0 / 中间 / 末尾 / 越界 / duration 为 0" {
    try testing.expectEqual(@as(u32, 0), progressX(240, 0, 800, 2));
    try testing.expectEqual(@as(u32, 119), progressX(240, 400, 800, 2));
    try testing.expectEqual(@as(u32, 238), progressX(240, 800, 800, 2));
    // 位置超过时长（设备时钟抖动）夹到末尾，不越界。
    try testing.expectEqual(@as(u32, 238), progressX(240, 900, 800, 2));
    // 没有时长（0 帧/未知）就不画进度。
    try testing.expectEqual(@as(u32, 0), progressX(240, 400, 0, 2));
    // 线比画布还宽的退化情况：不产生负的可用宽度。
    try testing.expectEqual(@as(u32, 0), progressX(2, 400, 800, 4));
}

test "positionMsAt：50% 点击 = 半个时长，越界夹到两端，0 宽/0 时长安全" {
    try testing.expectEqual(@as(u64, 0), positionMsAt(0, 240, 800));
    try testing.expectEqual(@as(u64, 400), positionMsAt(120, 240, 800));
    try testing.expectEqual(@as(u64, 800), positionMsAt(240, 240, 800));
    // 点在波形外面（左边/右边）：夹到 0 / duration，不产生负毫秒。
    try testing.expectEqual(@as(u64, 0), positionMsAt(-30, 240, 800));
    try testing.expectEqual(@as(u64, 800), positionMsAt(300, 240, 800));
    // 四舍五入：33% 的 800 ms = 264 ms。
    try testing.expectEqual(@as(u64, 264), positionMsAt(79.2, 240, 800));
    // 退化输入不除零。
    try testing.expectEqual(@as(u64, 0), positionMsAt(10, 0, 800));
    try testing.expectEqual(@as(u64, 0), positionMsAt(10, 240, 0));
}
