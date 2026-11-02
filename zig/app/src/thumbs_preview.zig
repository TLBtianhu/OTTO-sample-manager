//! 预览条（256px）与行内小图（64px）**共用的那一份像素缓存**，以及"从大图派生小图"
//! 的那一半规则。
//!
//! 背景（`docs/peer-project-recommendations.md` §5 P1）：以前预览条走
//! `preview_worker` → provider，行内图走 `thumbs.zig` → provider，两条链各有一份
//! 缓存，同一个 PSD 会被 Shell handler 取两次图。现在：
//!
//!   * 预览条的工作线程先问这一层（`acquire`，键里的请求边长 = 256）；
//!   * 未命中才问 provider，成功的一帧用 `publish` 回填（键仍然带 256）；
//!   * 行内小图的工作线程在"L3 也没有、provider 还没问"之前调 `derivePayload`：
//!     同一身份 + mtime 的 256 条目在 L2 里，就用盒式降采样派生 64px，**不问 provider**；
//!   * 反过来**不允许**：64px 的请求永远只问 64；`thumbs_worker.zig` 只会用更大的
//!     条目派生小图，不会为了行内图去要 256（那会把小图预算变成大图预算）。
//!
//! ## 为什么缓存单独一层（而不是塞进 `thumbs.zig` 的 L2）
//!
//! 任务要求"缩略图与完整预览仍分别计量预算"：256×256 BGRA 是 256 KiB，一张顶十六张
//! 64px 行内图，混在一个 LRU 里会把整屏行内图挤出去。所以这里是一份**独立的**
//! `core.cache.Cache`（预算默认 16 MiB），只由预览路径写、行内派生路径读；
//! 它有自己的锁，不和 `Thumbs.lock` 嵌套（派生时先读这里、再拿 Thumbs 的锁写 L2）。
//!
//! ## 键
//!
//! 与行内小图**同一套格式**（`thumbs_codec.keyFor`），只有请求边长不同（256 vs 64），
//! 所以"尺寸不同 → 键不同"是格式本身保证的，不靠调用方自觉。provider 版本来自
//! `providers/root.zig` 的聚合值（见那边的注释），两边算出来必须相等，否则派生
//! 永远不会命中——这是本文件唯一的跨模块不变量，测试里用同一个常量核对。
//!
//! ## 计数（验收输出）
//!
//! `provider_calls` 在调用 provider **之前**记（失败也算一次调用）；`bytes_fetched`
//! 只记真正拿到手的像素字节；`hits` 是预览缓存命中；`derived` 是成功派生并写进
//! 行内缓存的小图数；`max_request_px` 用来证明"冷启动只滚动时没有任何 256 请求"。
//!
//! 本文件不 import UI、不碰窗口、不调 provider；`preview_worker.zig` 负责在正确的
//! 线程上调用它。

const std = @import("std");
const core = @import("otto_core");
const preview = @import("preview.zig");
const codec = @import("thumbs_codec.zig");
const derive = @import("thumbs_derive.zig");
const types = @import("thumbs_types.zig");

/// 计数快照。全部是累计值；`entries` / `bytes` 是当前值。
pub const Counters = struct {
    hits: u32 = 0,
    derived: u32 = 0,
    provider_calls: u32 = 0,
    bytes_fetched: u64 = 0,
    max_request_px: u32 = 0,
    entries: usize = 0,
    bytes: usize = 0,
};

/// 预览档共享缓存。对象按值放在 `Thumbs` 里（只有分配器、缓存与锁，没有自指指针）。
pub const Share = struct {
    allocator: std.mem.Allocator,
    /// 256px 预览像素（L2，软配额 100%）。与行内图的 L2 是两个独立预算。
    cache: core.cache.Cache,
    lock: types.SpinLock = .{},
    /// 这一层服务的请求边长（预览条的 `preview.default_max_px`，256）。
    size_px: u32,
    /// 与 `providers.providerVersion()` 相同的聚合值：键的一部分。
    provider_version: u32,

    hits: u32 = 0,
    derived: u32 = 0,
    provider_calls: u32 = 0,
    bytes_fetched: u64 = 0,
    max_request_px: u32 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        budget_bytes: usize,
        size_px: u32,
        provider_version: u32,
    ) Share {
        var self = Share{
            .allocator = allocator,
            .cache = core.cache.Cache.init(allocator, budget_bytes),
            .size_px = size_px,
            .provider_version = provider_version,
        };
        self.cache.setKindPercent(.thumbnail, 100);
        return self;
    }

    pub fn deinit(self: *Share) void {
        self.cache.deinit();
    }

    /// 键：与行内小图同一套格式，请求边长是这一层的 `size_px`。
    pub fn keyFor(self: *const Share, sample: core.model.Sample, buffer: *[codec.max_key_bytes]u8) []const u8 {
        return codec.keyFor(sample, self.size_px, self.provider_version, buffer);
    }

    /// 预览缓存命中：返回一份**调用方拥有**的位图（像素已复制出来，调用方用同一个
    /// allocator 释放）。未命中 / 条目损坏返回 null，调用方继续问 provider。
    pub fn acquire(
        self: *Share,
        allocator: std.mem.Allocator,
        sample: core.model.Sample,
    ) std.mem.Allocator.Error!?preview.Bitmap {
        var buffer: [codec.max_key_bytes]u8 = undefined;
        const key = self.keyFor(sample, &buffer);

        self.lock.acquire();
        const payload = self.cache.get(key) orelse {
            self.lock.release();
            return null;
        };
        if (!self.cache.pin(key)) {
            self.lock.release();
            return null;
        }
        self.lock.release();
        // pin 住期间条目不会被淘汰：像素可以在锁外复制，不占着自旋锁做 256 KiB 拷贝。
        defer {
            self.lock.acquire();
            _ = self.cache.unpin(key);
            self.lock.release();
        }

        const dims = codec.decodeHeader(payload) orelse return null;
        const bytes = dims.stride * @as(usize, dims.height);
        const pixels = try allocator.alloc(u8, bytes);
        errdefer allocator.free(pixels);
        @memcpy(pixels, payload[codec.header_bytes..][0..bytes]);

        self.lock.acquire();
        self.hits +%= 1;
        self.lock.release();

        return .{
            .pixels = pixels,
            .width = dims.width,
            .height = dims.height,
            .stride = dims.stride,
        };
    }

    /// provider 成功返回一帧预览图：按 256 的键回填。写失败只影响缓存，不影响本次显示。
    /// **不在这里记 `bytes_fetched`**：调用方（`preview_worker.zig`）不管共享开没开
    /// 都要记流量，对照实验里缓存关闭时数字才可比（见 `noteFetched`）。
    pub fn publish(self: *Share, sample: core.model.Sample, bitmap: preview.Bitmap) void {
        const pixel_bytes = bitmap.stride * @as(usize, bitmap.height);
        if (pixel_bytes == 0) return;

        var buffer: [codec.max_key_bytes]u8 = undefined;
        const key = self.keyFor(sample, &buffer);

        const payload = self.allocator.alloc(u8, codec.header_bytes + pixel_bytes) catch return;
        defer self.allocator.free(payload);
        codec.encodeHeader(payload, bitmap.width, bitmap.height, bitmap.stride);
        @memcpy(payload[codec.header_bytes..], bitmap.pixels[0..pixel_bytes]);

        self.lock.acquire();
        self.cache.put(key, .thumbnail, payload) catch {
            self.lock.release();
            return;
        };
        self.lock.release();
    }

    /// provider 交回一帧像素：记一次流量（与是否写进缓存无关）。
    pub fn noteFetched(self: *Share, pixel_bytes: usize) void {
        self.lock.acquire();
        defer self.lock.release();
        self.bytes_fetched += pixel_bytes;
    }

    /// 从这一层的 256 条目派生一张 `dst_px` 的小图，返回一份 L2 载荷
    /// （16 字节头 + BGRA，调用方拥有、用同一个 allocator 释放）。
    ///
    /// 返回 null 的三种情况都**不是错误**：没有 256 条目（先预览才有）、条目损坏、
    /// 或源图本来就不比目标大（此时复制而不是放大，仍算一次派生）。
    /// 调用方（`thumbs_worker.zig`）负责把小图按**它自己的键**写进行内缓存。
    pub fn derivePayload(
        self: *Share,
        allocator: std.mem.Allocator,
        sample: core.model.Sample,
        dst_px: u32,
    ) std.mem.Allocator.Error!?[]u8 {
        // 这一层是"大图"；目标不小于它就没有派生的意义（也防止配置成同尺寸时死循环）。
        if (dst_px == 0 or dst_px >= self.size_px) return null;

        var buffer: [codec.max_key_bytes]u8 = undefined;
        const key = self.keyFor(sample, &buffer);

        self.lock.acquire();
        const payload = self.cache.get(key) orelse {
            self.lock.release();
            return null;
        };
        if (!self.cache.pin(key)) {
            self.lock.release();
            return null;
        }
        self.lock.release();
        defer {
            self.lock.acquire();
            _ = self.cache.unpin(key);
            self.lock.release();
        }

        const dims = codec.decodeHeader(payload) orelse return null;
        const fit = derive.fitSize(dims.width, dims.height, dst_px);
        if (fit.width == 0 or fit.height == 0) return null;

        const src_bytes = dims.stride * @as(usize, dims.height);
        const src = payload[codec.header_bytes..][0..src_bytes];
        const out_stride = @as(usize, fit.width) * 4;
        const out_bytes = out_stride * @as(usize, fit.height);

        const out = try allocator.alloc(u8, codec.header_bytes + out_bytes);
        errdefer allocator.free(out);
        codec.encodeHeaderFrom(out, fit.width, fit.height, out_stride, self.size_px);

        if (fit.width == dims.width and fit.height == dims.height) {
            // 源图不比目标大（例如一张 48×48 的图在 256 档里就是 48×48）：复制同尺寸像素。
            // 这不是"放大冒充"，provider 在 64 档同样会返回 48×48。按行复制：源跨度
            // 可能带填充（`stride > width*4`），不能假设两边一样长。
            for (0..fit.height) |row| {
                const src_row = src[row * dims.stride ..][0..out_stride];
                @memcpy(out[codec.header_bytes + row * out_stride ..][0..out_stride], src_row);
            }
        } else {
            const small = try derive.boxDownsample(
                allocator,
                src,
                dims.width,
                dims.height,
                dims.stride,
                fit.width,
                fit.height,
            );
            defer allocator.free(small);
            @memcpy(out[codec.header_bytes..], small);
        }
        return out;
    }

    /// 调 provider **之前**记一笔（失败也算一次调用）；`request_px` 用来给验收证明
    /// "冷启动只滚动时没有 256 请求"。
    pub fn noteProviderCall(self: *Share, request_px: u32) void {
        self.lock.acquire();
        defer self.lock.release();
        self.provider_calls +%= 1;
        self.max_request_px = @max(self.max_request_px, request_px);
    }

    /// 派生的小图已经写进行内缓存：记一笔。
    pub fn noteDerived(self: *Share) void {
        self.lock.acquire();
        defer self.lock.release();
        self.derived +%= 1;
    }

    /// 这一层现在有没有某条目的 256 像素（测试 / 探针用，不 pin、不复制）。
    pub fn contains(self: *Share, sample: core.model.Sample) bool {
        var buffer: [codec.max_key_bytes]u8 = undefined;
        const key = self.keyFor(sample, &buffer);
        self.lock.acquire();
        defer self.lock.release();
        return self.cache.contains(key);
    }

    pub fn counters(self: *Share) Counters {
        self.lock.acquire();
        defer self.lock.release();
        const stats = self.cache.stats();
        return .{
            .hits = self.hits,
            .derived = self.derived,
            .provider_calls = self.provider_calls,
            .bytes_fetched = self.bytes_fetched,
            .max_request_px = self.max_request_px,
            .entries = stats.entries,
            .bytes = stats.bytes,
        };
    }

    /// 运行时换预算（设置面板的 L2 预算按比例分给预览一档，见 `Thumbs.setBudgets`）。
    pub fn setBudget(self: *Share, budget_bytes: usize) void {
        self.lock.acquire();
        self.cache.setBudget(budget_bytes);
        self.lock.release();
    }
};

// ---------------------------------------------------------------------------
// 测试：键与行内小图同源、命中/回填/派生、坏条目、尺寸不同的键不同
// ---------------------------------------------------------------------------

const testing = std.testing;

fn sampleWith(path: []const u8, mtime: i64, size: u64) core.model.Sample {
    return .{
        .id = path,
        .file_name = std.fs.path.basename(path),
        .file_ext = std.fs.path.extension(path),
        .file_path = path,
        .mtime = mtime,
        .file_size = size,
    };
}

fn bigBitmap(allocator: std.mem.Allocator, width: u32, height: u32) !preview.Bitmap {
    const stride = @as(usize, width) * 4;
    const pixels = try allocator.alloc(u8, stride * @as(usize, height));
    for (0..height) |y| {
        for (0..width) |x| {
            const at = y * stride + x * 4;
            pixels[at] = @intCast((x * 4) % 256);
            pixels[at + 1] = @intCast((y * 4) % 256);
            pixels[at + 2] = 7;
            pixels[at + 3] = 255;
        }
    }
    return .{ .pixels = pixels, .width = width, .height = height, .stride = stride };
}

test "共享缓存：256 回填后命中，命中返回的位图归调用方且尺寸一致" {
    var share = Share.init(testing.allocator, 4 * 1024 * 1024, 256, 9);
    defer share.deinit();

    const sample = sampleWith("C:\\lib\\a.psd", 123, 4567);
    try testing.expect(!share.contains(sample));

    const bitmap = try bigBitmap(testing.allocator, 256, 256);
    defer testing.allocator.free(bitmap.pixels);
    share.publish(sample, bitmap);
    share.noteFetched(bitmap.byteLen());
    try testing.expect(share.contains(sample));

    const hit = (try share.acquire(testing.allocator, sample)).?;
    try testing.expectEqual(@as(u32, 256), hit.width);
    try testing.expectEqual(@as(usize, 256 * 4 * 256), hit.pixels.len);
    try testing.expect(hit.pixels.ptr != bitmap.pixels.ptr); // 真的是副本
    std.testing.allocator.free(hit.pixels);

    const counters = share.counters();
    try testing.expectEqual(@as(u32, 1), counters.hits);
    try testing.expectEqual(@as(u64, 256 * 4 * 256), counters.bytes_fetched);
    try testing.expectEqual(@as(usize, 1), counters.entries);
}

test "共享缓存：不同尺寸（64 vs 256）不会互相命中" {
    var share = Share.init(testing.allocator, 4 * 1024 * 1024, 256, 9);
    defer share.deinit();

    const sample = sampleWith("C:\\lib\\a.psd", 123, 4567);
    var buffer: [codec.max_key_bytes]u8 = undefined;
    const key256 = share.keyFor(sample, &buffer);
    var other: [codec.max_key_bytes]u8 = undefined;
    const key64 = codec.keyFor(sample, 64, 9, &other);
    try testing.expect(!std.mem.eql(u8, key256, key64));
}

test "派生：256 条目 → 64px，键尺寸不同、标注 derived_from=256、像素是面积平均" {
    var share = Share.init(testing.allocator, 4 * 1024 * 1024, 256, 9);
    defer share.deinit();

    const sample = sampleWith("C:\\lib\\a.psd", 123, 4567);
    const bitmap = try bigBitmap(testing.allocator, 256, 256);
    defer testing.allocator.free(bitmap.pixels);
    share.publish(sample, bitmap);

    // 没有 64 条目也能派生：派生读的是 256 那一档。
    const payload = (try share.derivePayload(testing.allocator, sample, 64)).?;
    defer testing.allocator.free(payload);
    const dims = codec.decodeHeader(payload).?;
    try testing.expectEqual(@as(u32, 64), dims.width);
    try testing.expectEqual(@as(u32, 64), dims.height);
    try testing.expectEqual(@as(u32, 256), dims.source_px); // derived_from=256
    try testing.expectEqual(@as(usize, 64 * 4 * 64), payload.len - codec.header_bytes);
}

test "派生：没有 256 条目时返回 null（不凭空造图）；源太小则复制而不是放大" {
    var share = Share.init(testing.allocator, 4 * 1024 * 1024, 256, 9);
    defer share.deinit();

    const sample = sampleWith("C:\\lib\\a.psd", 123, 4567);
    try testing.expect((try share.derivePayload(testing.allocator, sample, 64)) == null);

    // 源图 48×48（provider 在 256 档里也不会放大）：派生 64 时同尺寸复制。
    const small = try bigBitmap(testing.allocator, 48, 48);
    defer testing.allocator.free(small.pixels);
    share.publish(sample, small);
    const payload = (try share.derivePayload(testing.allocator, sample, 64)).?;
    defer testing.allocator.free(payload);
    const dims = codec.decodeHeader(payload).?;
    try testing.expectEqual(@as(u32, 48), dims.width);
    try testing.expectEqual(@as(u32, 48), dims.height);
    try testing.expectEqual(@as(u32, 256), dims.source_px);
}

test "调用账：provider_calls 在调用前记、max_request_px 体现 256 / 64" {
    var share = Share.init(testing.allocator, 4 * 1024 * 1024, 256, 9);
    defer share.deinit();

    try testing.expectEqual(@as(u32, 0), share.counters().max_request_px);
    share.noteProviderCall(64);
    try testing.expectEqual(@as(u32, 64), share.counters().max_request_px);
    share.noteProviderCall(256);
    share.noteDerived();
    const counters = share.counters();
    try testing.expectEqual(@as(u32, 2), counters.provider_calls);
    try testing.expectEqual(@as(u32, 256), counters.max_request_px);
    try testing.expectEqual(@as(u32, 1), counters.derived);
}
