//! 缩略图缓存键与载荷头的纯函数，以及 L2 键串 → L3 磁盘摘要的派生。
//!
//! 从 `thumbs.zig` 拆出来只为守住单文件行数；这里不碰线程、不碰磁盘，测试不需要
//! 起窗口，也不需要第三方 Shell handler。
//!
//! ## L2 缓存键（`keyFor`）
//!
//!   * 有文件身份（NTFS / ReFS 的卷序列号 + 文件索引）：`id|<卷>|<索引>|<mtime>|<边长>`。
//!     身份跨改名、跨同卷移动不变，所以改名后缩略图不会重取；
//!   * 没有身份（FAT32 / exFAT / 网络盘）：`fb|<大小>|<mtime>|<路径>|<mtime>|<边长>`，
//!     路径按字节原样进键，没有拼接歧义（分隔符固定）；
//!   * `mtime` 是为了内容一变就换键：身份不变但文件被覆盖时，旧像素不能再用；
//!   * 请求边长也进键：32px 的条目不能被 256px 的请求当成命中。
//!   路径长到放不进 `max_key_bytes` 时退化成 `hash|<stableKey 哈希>|<mtime>|<边长>`，
//!   键长固定、不会无界增长（Wyhash 64 位，和 core 的注释表同一套哈希）。
//!
//! ## L3 摘要（`diskKeyFor`）
//!
//! 磁盘缓存的键是 32 字节，不直接拿 L2 的字符串当文件名（路径里的分隔符、大小写、
//! 非法字符都会出问题）。做法是对 L2 键串做四轮 Wyhash-64（种子依次为上一轮的
//! 结果），四段小端拼成 32 字节：
//!
//!   * 同一个 L2 键串 → 同一个 32 字节摘要，跨进程、跨重启稳定；
//!   * 摘要里不含任何语义，缓存层不解释它（`diskcache.zig` 的契约）；
//!   * 32 字节 = 256 位，碰撞概率对几万张缩略图可以忽略。
//!
//! ## L2 载荷头
//!
//! 宽 / 高 / 行跨度各 4 字节小端，之后才是 BGRA 像素。尺寸必须和像素一起进缓存，
//! 否则命中的是一个不知道多大、跨度多少的字节块。

const std = @import("std");
const core = @import("otto_core");
const diskcache = @import("otto_diskcache");

/// 缓存键的栈上缓冲。Windows 长路径可能超过它，超了走哈希退化（见文件头）。
pub const max_key_bytes: usize = 512;

/// 缓存载荷的前缀：宽 / 高 / 行跨度，各 4 字节小端，之后才是 BGRA 像素。
pub const header_bytes: usize = 12;

/// 一条样本的 L2 缓存键。规则见文件头；结果写进 `buffer`，返回它的切片。
pub fn keyFor(sample: core.model.Sample, size_px: u32, buffer: *[max_key_bytes]u8) []const u8 {
    return switch (sample.stableKey()) {
        .identity => |identity| std.fmt.bufPrint(
            buffer,
            "id|{x:0>8}|{x:0>16}|{d}|{d}",
            .{ identity.volume_serial, identity.file_index, sample.mtime, size_px },
        ) catch unreachable,
        .fallback => |fallback| std.fmt.bufPrint(
            buffer,
            "fb|{d}|{d}|{s}|{d}|{d}",
            .{ fallback.size, fallback.mtime, fallback.path, sample.mtime, size_px },
        ) catch hashedKey(sample, size_px, buffer),
    };
}

/// 路径太长时的退化键：稳定、定长，内容里仍有 stableKey 的哈希、mtime 和尺寸。
fn hashedKey(sample: core.model.Sample, size_px: u32, buffer: *[max_key_bytes]u8) []const u8 {
    return std.fmt.bufPrint(
        buffer,
        "hash|{x:0>16}|{d}|{d}",
        .{ sample.stableKey().hash(), sample.mtime, size_px },
    ) catch unreachable;
}

/// L2 键串 → L3 的 32 字节摘要。四轮 Wyhash 串联，每轮 8 字节小端。
pub fn diskKeyFor(l2_key: []const u8) diskcache.Key {
    var key: diskcache.Key = undefined;
    var seed: u64 = 0;
    for (0..4) |index| {
        const digest = std.hash.Wyhash.hash(seed, l2_key);
        std.mem.writeInt(u64, key[index * 8 ..][0..8], digest, .little);
        seed = digest;
    }
    return key;
}

/// 把尺寸写进载荷头（宽 / 高 / 跨度，各 4 字节小端）。
pub fn encodeHeader(payload: []u8, width: u32, height: u32, stride: usize) void {
    std.debug.assert(payload.len >= header_bytes);
    std.mem.writeInt(u32, payload[0..4], width, .little);
    std.mem.writeInt(u32, payload[4..8], height, .little);
    std.mem.writeInt(u32, payload[8..12], @intCast(stride), .little);
}

pub const Dims = struct {
    width: u32,
    height: u32,
    stride: usize,
};

/// 解析载荷头；尺寸为 0 或长度对不上（载荷被截断）时返回 null。
pub fn decodeHeader(payload: []const u8) ?Dims {
    if (payload.len < header_bytes) return null;
    const width = std.mem.readInt(u32, payload[0..4], .little);
    const height = std.mem.readInt(u32, payload[4..8], .little);
    const stride: usize = std.mem.readInt(u32, payload[8..12], .little);
    if (width == 0 or height == 0) return null;
    if (stride < @as(usize, width) * 4) return null;
    if (payload.len < header_bytes + stride * height) return null;
    return .{ .width = width, .height = height, .stride = stride };
}
