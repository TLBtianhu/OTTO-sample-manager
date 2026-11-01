//! 盒式降采样：把**已经在缓存里的大图**派生成行内小图（`thumbs.zig` 的 64px 那一格）。
//!
//! 为什么单独一层：派生是"同一份像素换一种分辨率"，与缓存、线程、provider 无关；
//! 写成纯函数以后可以在没有窗口、没有 Shell handler、没有磁盘的单元测试里验证
//! 每一条规则（面积平均、不放大、BGRA 四通道、非方形保持长宽比）。
//!
//! ## 只许缩小，不许放大
//!
//! `fitSize` 与 `providers/image_wic.zig` 的 `fitDimensions` 是同一条规则：长边不超过
//! 目标，短边按比例、至少 1 像素；**原图不比目标大时原样返回**。调用方据此判断
//! "能不能派生"：`fit` 的结果等于源尺寸就说明没有可缩的空间，不要凭空造一张
//! "64px"（那是把小图放大冒充预览质量，任务里明令禁止的方向）。
//!
//! ## 为什么是面积平均（box）
//!
//! 缩略图像素是**预乘 alpha** 的 BGRA。预乘之后做线性平均是正确的（透明像素已经
//! 按 alpha 加权过），不需要先反预乘；整数和的上界是 `255 * 桶内像素数`，桶最大
//! 是整张 256×256 = 65536，u64 累加不会溢出。采样按比例映射到源矩形，整数边界
//! 用 `floor(d*src/dst)`，缩小时每个目标像素至少覆盖一个源像素；256→64 时正好是
//! 4×4 的精确平均，64→16 是 4×4，非整数比例（如 96→64）是 1–2 像素的矩形。
//!
//! ## 成本
//!
//! 256×256 → 64×64：读 65536 像素、写 4096 像素，本机 < 0.2 ms；它发生在工作线程上
//! （`thumbs_worker.zig`），不在 UI 线程。对比"再问一次 Shell handler"（几十毫秒、
//! 还可能拉起 helper），这是把一次重复取图换成一次内存遍历。
//!
//! 本文件只依赖 Zig 0.17 标准库，不认识缓存键、不碰 `core.cache`、不 import 任何口岸。

const std = @import("std");

/// 目标尺寸（宽 / 高）。
pub const Fit = struct {
    width: u32,
    height: u32,
};

/// 长边缩到 `max_px` 以内，保持长宽比，短边至少 1 像素；**不放大**。
/// `max_px == 0` 按"没有限制"处理（调用方不会传 0，测试会）。
pub fn fitSize(src_w: u32, src_h: u32, max_px: u32) Fit {
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

/// 把 `src`（BGRA8、`src_stride` 字节一行）盒式缩小到 `dst_w × dst_h`。
///
/// 前置条件：`dst_w <= src_w`、`dst_h <= src_h` 且都 > 0（`fitSize` 保证）。
/// 返回的像素用 `allocator` 分配，调用方释放；行跨度固定 `dst_w * 4`。
pub fn boxDownsample(
    allocator: std.mem.Allocator,
    src: []const u8,
    src_w: u32,
    src_h: u32,
    src_stride: usize,
    dst_w: u32,
    dst_h: u32,
) std.mem.Allocator.Error![]u8 {
    std.debug.assert(dst_w > 0 and dst_h > 0);
    std.debug.assert(dst_w <= src_w and dst_h <= src_h);
    std.debug.assert(src_stride >= @as(usize, src_w) * 4);
    std.debug.assert(src.len >= src_stride * @as(usize, src_h));

    const dst_stride = @as(usize, dst_w) * 4;
    const out = try allocator.alloc(u8, dst_stride * @as(usize, dst_h));
    errdefer allocator.free(out);

    const src_w64: u64 = src_w;
    const src_h64: u64 = src_h;
    for (0..dst_h) |dy| {
        const y0: usize = @intCast(@as(u64, dy) * src_h64 / dst_h);
        const y1: usize = @intCast(@max(
            @as(u64, dy) * src_h64 / dst_h + 1,
            (@as(u64, dy) + 1) * src_h64 / dst_h,
        ));
        for (0..dst_w) |dx| {
            const x0: usize = @intCast(@as(u64, dx) * src_w64 / dst_w);
            const x1: usize = @intCast(@max(
                @as(u64, dx) * src_w64 / dst_w + 1,
                (@as(u64, dx) + 1) * src_w64 / dst_w,
            ));

            var sum: [4]u64 = .{ 0, 0, 0, 0 };
            var count: u64 = 0;
            for (y0..y1) |y| {
                const row = src[y * src_stride ..];
                for (x0..x1) |x| {
                    const px = row[x * 4 ..][0..4];
                    for (0..4) |channel| sum[channel] += px[channel];
                    count += 1;
                }
            }
            std.debug.assert(count > 0);
            const half = count / 2;
            const at = dy * dst_stride + dx * 4;
            for (0..4) |channel| out[at + channel] = @intCast((sum[channel] + half) / count);
        }
    }
    return out;
}

// ---------------------------------------------------------------------------
// 测试：面积平均、非方形、不放大、预乘 alpha 的线性语义
// ---------------------------------------------------------------------------

const testing = std.testing;

/// 造一张 `w × h` 的 BGRA 图，像素值由 `fill(x, y, channel)` 决定。
fn make(
    allocator: std.mem.Allocator,
    w: u32,
    h: u32,
    fill: *const fn (u32, u32, usize) u8,
) ![]u8 {
    const stride = @as(usize, w) * 4;
    const pixels = try allocator.alloc(u8, stride * @as(usize, h));
    for (0..h) |y| {
        for (0..w) |x| {
            for (0..4) |channel| pixels[y * stride + x * 4 + channel] = fill(@intCast(x), @intCast(y), channel);
        }
    }
    return pixels;
}

fn fillQuadrant(x: u32, y: u32, channel: usize) u8 {
    // 2×2 象限，四个通道各自有独立取值，方便核对不是"只平均了一个通道"。
    const base: u8 = if (x < 2 and y < 2) 10 else if (x >= 2 and y < 2) 40 else if (x < 2) 70 else 100;
    return base + @as(u8, @intCast(channel * 10));
}

fn fillX(x: u32, _: u32, channel: usize) u8 {
    // 只随 x 变，且限制在 u8 内：每列 (x%16)*16 + channel*4（最大 252）。
    return @intCast((x % 16) * 16 + channel * 4);
}

test "盒式降采样：4×4 → 2×2 正好是四个源像素的面积平均（四个通道都在算）" {
    const src = try make(testing.allocator, 4, 4, &fillQuadrant);
    defer testing.allocator.free(src);

    const out = try boxDownsample(testing.allocator, src, 4, 4, 16, 2, 2);
    defer testing.allocator.free(out);

    // 四个象限各自 2×2 同值，所以平均等于原值。
    try testing.expectEqual(@as(u8, 10), out[0]);
    try testing.expectEqual(@as(u8, 20), out[1]);
    try testing.expectEqual(@as(u8, 30), out[2]);
    try testing.expectEqual(@as(u8, 40), out[3]);
    // 右上象限：x=2..3, y=0..1。
    try testing.expectEqual(@as(u8, 40), out[4]);
    try testing.expectEqual(@as(u8, 70), out[7]);
    // 左下象限从第二行开始（跨度 8 字节 = 2 像素）。
    try testing.expectEqual(@as(u8, 70), out[8]);
    try testing.expectEqual(@as(u8, 100), out[12]);
}

test "盒式降采样：256×256 → 64×64 是 4×4 的精确平均，不是抽点" {
    const src = try make(testing.allocator, 256, 256, &fillX);
    defer testing.allocator.free(src);

    const out = try boxDownsample(testing.allocator, src, 256, 256, 1024, 64, 64);
    defer testing.allocator.free(out);

    // 第一格覆盖 x=0..3：值 0,16,32,48 → 平均 24。
    try testing.expectEqual(@as(u8, 24), out[0]);
    // 第二格覆盖 x=4..7：64,80,96,112 → 88。
    try testing.expectEqual(@as(u8, 88), out[4]);
    // 同一个目标像素的四个通道各自平均（+4 的通道偏移原样保留）。
    try testing.expectEqual(@as(u8, 28), out[1]);
    // 最后一格覆盖 x=252..255（x%16 = 12..15）：192,208,224,240 → 216。
    try testing.expectEqual(@as(u8, 216), out[63 * 4]);
}

test "盒式降采样：非方形 96×64 → 48×32，行跨度按目标宽算" {
    const src = try make(testing.allocator, 96, 64, &fillX);
    defer testing.allocator.free(src);

    const fit = fitSize(96, 64, 48);
    try testing.expectEqual(Fit{ .width = 48, .height = 32 }, fit);

    const out = try boxDownsample(testing.allocator, src, 96, 64, 96 * 4, fit.width, fit.height);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 48 * 4 * 32), out.len);
    // 第一格覆盖 x=0..1 → 0,16 平均 8。
    try testing.expectEqual(@as(u8, 8), out[0]);
}

test "fitSize：不放大、长宽比、短边至少 1 像素、0 = 不限制" {
    try testing.expectEqual(Fit{ .width = 96, .height = 96 }, fitSize(96, 96, 256));
    try testing.expectEqual(Fit{ .width = 64, .height = 64 }, fitSize(256, 256, 64));
    try testing.expectEqual(Fit{ .width = 64, .height = 48 }, fitSize(320, 240, 64));
    try testing.expectEqual(Fit{ .width = 48, .height = 64 }, fitSize(240, 320, 64));
    // 极扁的图：短边被算成 0 时夹到 1，不返回 0 尺寸。
    try testing.expectEqual(Fit{ .width = 64, .height = 1 }, fitSize(1000, 1, 64));
    try testing.expectEqual(Fit{ .width = 10, .height = 7 }, fitSize(10, 7, 0));
}

test "预乘 alpha：透明像素的 RGB 以 0 参与平均，不会把颜色拉亮" {
    // 2×1：左像素 (255,0,0,255)，右像素 (0,0,0,0)（预乘后全 0）。
    const src = [_]u8{
        255, 0, 0, 255,
        0,   0, 0, 0,
    };
    const out = try boxDownsample(testing.allocator, &src, 2, 1, 8, 1, 1);
    defer testing.allocator.free(out);
    // 线性平均（预乘空间）：R=127（(255+0+1)/2），A=127。
    try testing.expectEqual(@as(u8, 128), out[0]);
    try testing.expectEqual(@as(u8, 0), out[1]);
    try testing.expectEqual(@as(u8, 0), out[2]);
    try testing.expectEqual(@as(u8, 128), out[3]);
}
