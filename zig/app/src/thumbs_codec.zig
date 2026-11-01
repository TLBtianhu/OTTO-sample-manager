//! 缩略图缓存键与载荷头的纯函数，以及 L2 键串 → L3 磁盘摘要的派生。
//!
//! 从 `thumbs.zig` 拆出来只为守住单文件行数；这里不碰线程、不碰磁盘，测试不需要
//! 起窗口，也不需要第三方 Shell handler。
//!
//! ## L2 缓存键（`keyFor`）
//!
//! ```
//! id|<卷>|<索引>|<mtime>|<边长>|k2|pv<provider_version>|bgra
//! fb|<大小>|<mtime>|<路径>|<mtime>|<边长>|k2|pv<provider_version>|bgra
//! hash|<stableKey 哈希>|<mtime>|<边长>|k2|pv<provider_version>|bgra   （超长路径退化）
//! ```
//!
//! 每一段的理由：
//!   * 有文件身份（NTFS / ReFS 的卷序列号 + 文件索引）：`id|…`。身份跨改名、跨同卷
//!     移动不变，所以改名后缩略图不会重取；
//!   * 没有身份（FAT32 / exFAT / 网络盘）：`fb|<大小>|<mtime>|<路径>|…`，路径按字节
//!     原样进键，没有拼接歧义（分隔符固定）；
//!   * `mtime` 是为了内容一变就换键：身份不变但文件被覆盖时，旧像素不能再用；
//!   * 请求边长（`<边长>`）也进键：64px 的条目不能被 256px 的请求当成命中，反过来
//!     也一样——**尺寸不同 → 键不同**是格式保证的，派生结果因此天然落在自己的键上；
//!   * `k2` 是**键格式版本**。改这个文件里的任何一段（新增维度、改分隔符、改编码）
//!     都必须把它 +1；旧条目会因为键字符串不同而整体不命中，不需要迁移代码。
//!   * `pv<provider_version>` 是 `providers/root.zig` 的**聚合** provider 版本（每个
//!     provider 一个常量，谁改了取图行为谁 +1）。键在 `open` 之前就要算出来，所以
//!     这里不可能放"赢家 provider 的版本"；聚合值能保证任何一家变了旧键就失效。
//!     helper 协议 / Shell 取图行为变化时 bump `providers/thumb.zig` 的常量即可。
//!   * `bgra` 是**像素格式**。现在载荷只有 BGRA8 预乘一种；写进键是为将来换成别的
//!     格式时"旧像素不会被当成新格式命中"，改格式时同时 bump `pixel_format` 与 `k2`。
//!
//! **改这里要 bump 版本。** 新维度进键 = `key_format_version` +1；provider 行为变化 =
//! 那个 provider 的 `provider_version` +1。`thumbs_test.zig` 里有一条"故意弄坏会红"
//! 的测试：版本 +1 后旧键不再命中。版本只增不减。
//!
//! 路径长到放不进 `max_key_bytes` 时退化成 `hash|…`，键长固定、不会无界增长
//! （Wyhash 64 位，和 core 的注释表同一套哈希）。
//!
//! ## L3 摘要（`diskKeyFor`）
//!
//! 磁盘缓存的键是 32 字节，不直接拿 L2 的字符串当文件名（路径里的分隔符、大小写、
//! 非法字符都会出问题）。做法是对 L2 键串做四轮 Wyhash-64（种子依次为上一轮的
//! 结果），四段小端拼成 32 字节：
//!
//!   * 同一个 L2 键串 → 同一个 32 字节摘要，跨进程、跨重启稳定；
//!   * 摘要里不含任何语义，缓存层不解释它（`diskcache.zig` 的契约）；
//!   * 键格式 / provider 版本变了，L3 摘要自然跟着变，旧条目成为孤儿，由预算裁剪回收。
//!
//! ## L2 载荷头
//!
//! 宽 / 高 / 行跨度 / 来源边长，各 4 字节小端，之后才是 BGRA 像素。尺寸必须和像素
//! 一起进缓存，否则命中的是一个不知道多大、跨度多少的字节块；`source_px` 是
//! **派生来源**：0 = provider 直接取图，256 = 由 256px 预览档降采样而来
//! （`derived_from=256`）。L3 只存裸像素 + 自己的宽高跨度，回填时 `source_px` 为 0
//! （见 `thumbs_disk.zig`）——它只是诊断标注，像素本身与直接取图完全等价。

const std = @import("std");
const core = @import("otto_core");
const diskcache = @import("otto_diskcache");

/// 缓存键的栈上缓冲。Windows 长路径可能超过它，超了走哈希退化（见文件头）。
pub const max_key_bytes: usize = 512;

/// 载荷头的字节数：宽 / 高 / 跨度 / 来源边长，各 4 字节小端。
pub const header_bytes: usize = 16;

/// 载荷的像素格式。现在只有 BGRA8 预乘一种；换格式时改这里并 bump `key_format_version`。
pub const pixel_format = "bgra";

/// 键格式版本。**改 `keyFor` 的布局就必须 +1**（旧条目不命中，不做迁移）。
pub const key_format_version: u32 = 2;

/// 一条样本的 L2 缓存键。规则见文件头；结果写进 `buffer`，返回它的切片。
///
/// `provider_version` 必须与 `providers.providerVersion()` 相同；行内小图与预览条
/// 用同一个聚合值，否则派生永远不命中（`thumbs_preview.zig` 的不变量）。
pub fn keyFor(
    sample: core.model.Sample,
    size_px: u32,
    provider_version: u32,
    buffer: *[max_key_bytes]u8,
) []const u8 {
    return switch (sample.stableKey()) {
        .identity => |identity| std.fmt.bufPrint(
            buffer,
            "id|{x:0>8}|{x:0>16}|{d}|{d}|k{d}|pv{d}|{s}",
            .{ identity.volume_serial, identity.file_index, sample.mtime, size_px, key_format_version, provider_version, pixel_format },
        ) catch unreachable,
        .fallback => |fallback| std.fmt.bufPrint(
            buffer,
            "fb|{d}|{d}|{s}|{d}|{d}|k{d}|pv{d}|{s}",
            .{ fallback.size, fallback.mtime, fallback.path, sample.mtime, size_px, key_format_version, provider_version, pixel_format },
        ) catch hashedKey(sample, size_px, provider_version, buffer),
    };
}

/// 路径太长时的退化键：稳定、定长，内容里仍有 stableKey 的哈希、mtime、尺寸与版本。
fn hashedKey(
    sample: core.model.Sample,
    size_px: u32,
    provider_version: u32,
    buffer: *[max_key_bytes]u8,
) []const u8 {
    return std.fmt.bufPrint(
        buffer,
        "hash|{x:0>16}|{d}|{d}|k{d}|pv{d}|{s}",
        .{ sample.stableKey().hash(), sample.mtime, size_px, key_format_version, provider_version, pixel_format },
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

/// 把尺寸写进载荷头（宽 / 高 / 跨度，各 4 字节小端）。`source_px = 0`：provider 直接取图。
pub fn encodeHeader(payload: []u8, width: u32, height: u32, stride: usize) void {
    encodeHeaderFrom(payload, width, height, stride, 0);
}

/// 同上，但带派生来源（`source_px` = 派生时用的预览边长，例如 256）。
pub fn encodeHeaderFrom(payload: []u8, width: u32, height: u32, stride: usize, source_px: u32) void {
    std.debug.assert(payload.len >= header_bytes);
    std.mem.writeInt(u32, payload[0..4], width, .little);
    std.mem.writeInt(u32, payload[4..8], height, .little);
    std.mem.writeInt(u32, payload[8..12], @intCast(stride), .little);
    std.mem.writeInt(u32, payload[12..16], source_px, .little);
}

pub const Dims = struct {
    width: u32,
    height: u32,
    stride: usize,
    /// 派生来源边长；0 = provider 直接取图。
    source_px: u32 = 0,
};

/// 解析载荷头；尺寸为 0 或长度对不上（载荷被截断）时返回 null。
pub fn decodeHeader(payload: []const u8) ?Dims {
    if (payload.len < header_bytes) return null;
    const width = std.mem.readInt(u32, payload[0..4], .little);
    const height = std.mem.readInt(u32, payload[4..8], .little);
    const stride: usize = std.mem.readInt(u32, payload[8..12], .little);
    const source_px = std.mem.readInt(u32, payload[12..16], .little);
    if (width == 0 or height == 0) return null;
    if (stride < @as(usize, width) * 4) return null;
    if (payload.len < header_bytes + stride * height) return null;
    return .{ .width = width, .height = height, .stride = stride, .source_px = source_px };
}
