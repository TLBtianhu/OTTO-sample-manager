//! `thumbs.zig` 与 `otto_diskcache` 之间的薄适配层：把「L2 键串 → 32 字节摘要」和
//! 「L2 载荷（12B 头 + BGRA）↔ 裸像素」这两件事留在同一处。
//!
//! 为什么不把磁盘格式直接塞进 `thumbs.zig`：
//!   * `diskcache` 是 `ports` 口岸，只收发字节、不认识缩略图；它需要的是
//!     `width/height/stride/pixels`，而取图层内部流通的是带 12 字节头的 L2 载荷；
//!   * 这层转换一旦出错（头没写、跨度算错）只会让缓存失效，不会影响 helper 的像素；
//!     放在一个不到 100 行、能单独读的文件里，比散在取图流程里更容易核对。
//!
//! 失败方向：所有方法都把错误交回 `thumbs.zig`，由它决定「退回 helper」；
//! 本层不吞错、也不 panic。

const std = @import("std");
const diskcache = @import("otto_diskcache");
const codec = @import("thumbs_codec.zig");

/// 与 `diskcache.Key` 同一个类型；取图层只通过 `L3.keyFor` 产生它。
pub const Key = diskcache.Key;
pub const Stats = diskcache.Stats;
pub const PruneReport = diskcache.PruneReport;

/// L3 默认预算：256 MiB。一张 64×64 BGRA 约 16 KiB，够放一万多张。
pub const default_budget_bytes: u64 = diskcache.default_budget_bytes;

/// L3 磁盘缓存的适配器。内部就是 `diskcache.DiskCache` 加两段格式转换。
pub const L3 = struct {
    cache: diskcache.DiskCache,

    pub fn open(
        allocator: std.mem.Allocator,
        io: std.Io,
        root_dir: []const u8,
        budget_bytes: u64,
    ) !L3 {
        return .{ .cache = try diskcache.DiskCache.open(allocator, io, root_dir, budget_bytes) };
    }

    pub fn deinit(self: *L3) void {
        self.cache.deinit();
    }

    pub fn prune(self: *L3) !PruneReport {
        return self.cache.prune();
    }

    pub fn stats(self: *const L3) Stats {
        return self.cache.stats();
    }

    /// L2 键串 → 32 字节磁盘摘要。纯函数，跨进程稳定。
    pub fn keyFor(l2_key: []const u8) Key {
        return codec.diskKeyFor(l2_key);
    }

    /// 命中时返回一份**新的 L2 载荷**（12B 头 + 像素），调用方用同一个 allocator
    /// 释放。未命中 / 损坏条目返回 null；IO 错误原样上交。
    pub fn get(self: *L3, allocator: std.mem.Allocator, key: Key) !?[]u8 {
        const entry = (try self.cache.get(allocator, key)) orelse return null;
        defer allocator.free(entry.bytes);

        const total = codec.header_bytes + entry.bytes.len;
        const payload = try allocator.alloc(u8, total);
        errdefer allocator.free(payload);
        codec.encodeHeader(payload, entry.width, entry.height, entry.stride);
        @memcpy(payload[codec.header_bytes..], entry.bytes);
        // CRC 只证明字节没坏，不证明尺寸语义成立（例如 stride < width*4）。
        // 不合法就当 miss，别把一条永远画不出来的条目塞进 L2 造成重试循环。
        if (codec.decodeHeader(payload) == null) {
            allocator.free(payload);
            return null;
        }
        return payload;
    }

    /// 把一份 L2 载荷拆成裸像素写盘。载荷头不合法属于调用方 bug，返回
    /// `error.InvalidPayload`（`thumbs.zig` 会把它当「这次没写成」，不影响取图）。
    pub fn put(self: *L3, key: Key, payload: []const u8) !void {
        const dims = codec.decodeHeader(payload) orelse return error.InvalidPayload;
        const stride = std.math.cast(u32, dims.stride) orelse return error.InvalidPayload;
        const pixel_bytes = dims.stride * dims.height;
        const pixels = payload[codec.header_bytes..][0..pixel_bytes];
        try self.cache.put(key, dims.width, dims.height, stride, pixels);
    }
};
