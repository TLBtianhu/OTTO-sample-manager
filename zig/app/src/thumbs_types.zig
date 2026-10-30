//! `thumbs.zig` 的数据契约与内部小工具：选项、借用视图、查询结果、账、队列项、
//! pin 记录与自旋锁。
//!
//! 拆出来的唯一理由是单文件行数上限（`thumbs.zig` 已经到 600 行附近）；这些类型
//! 没有行为，放在一起也让 UI / `--demo-thumbs` 读的「账」有单一出处。
//! 所有公开名字都从 `thumbs.zig` re-export，外部调用方不需要改 import 路径。

const std = @import("std");
const l3 = @import("thumbs_disk.zig");

/// 请求的边长（像素）。列表那格是 32 点，Windows 的窗口在 150% / 200% 缩放下是
/// 2x，所以按 64 请求：2x 屏上正好 1:1，1x 屏由图集缩到 32 点，不会糊。
pub const default_size_px: u32 = 64;

/// 有界队列容量。一屏 380×700 / 44px ≈ 17 行，32 条留了一屏半的余量：
/// 正常滚动不会丢，只有一次性塞进更多请求时才会触发「丢最旧」。
pub const default_queue_capacity: usize = 32;

/// 缩略图 L2 缓存预算。一张 64×64 BGRA 是 16 KiB，32 MiB 装得下两千张左右，
/// 远多于一屏的可见行数。
pub const default_budget_bytes: usize = 32 * 1024 * 1024;

/// 失败记忆的条数上限；满了丢最旧的。
pub const default_failure_memory: usize = 64;

pub const Options = struct {
    /// 请求的边长，1–`thumb.max_size_px`；超出按口岸上限夹住。
    size_px: u32 = default_size_px,
    queue_capacity: usize = default_queue_capacity,
    budget_bytes: usize = default_budget_bytes,
    failure_memory: usize = default_failure_memory,
    /// 是否把"碰 Shell"交给 `otto-thumb-host.exe`（M4 第一块）。
    /// 默认 `true`：第三方 handler 崩了/卡死/弹框只带走 helper，OTTO 列表照常滚；
    /// `false` 是显式对照开关（`--no-isolation`），退回进程内 `thumb.get`。
    isolation: bool = true,
    /// L3 磁盘缓存根目录；`null` = 本次不用 L3（dev 形态 / 目录建不出来）。
    disk_cache_dir: ?[]const u8 = null,
    /// L3 预算（字节）。默认 256 MiB，启动时裁剪到预算以内。
    disk_cache_budget: u64 = l3.default_budget_bytes,
};

/// 一次成功命中的借用视图。`key` 与 `pixels` 都归缓存所有，pin 期间有效。
pub const View = struct {
    /// 缓存键；`ui.image` 用它做图集的名字（同键同尺寸只解码一次）。
    key: []const u8,
    /// BGRA8、预乘 alpha、顶行在前（`thumb.Thumbnail` 的契约）。
    pixels: []const u8,
    width: u32,
    height: u32,
    stride: usize,
};

/// `acquire` 的四种答案。UI 对后三种都画占位，只是图标不同：
///   * `pending`   —— 已进队列 / 正在取，等一次 redraw；
///   * `no_handler`—— 能力门禁说这台机器没有 handler（正常态，不是错误）；
///   * `failed`    —— 文件没了 / Shell 失败 / 队列里丢了；已经记进失败表。
pub const Lookup = union(enum) {
    ready: View,
    pending,
    no_handler,
    failed,
};

/// 取图层的账。UI / `--demo-thumbs` 只读这个快照。
pub const Stats = struct {
    /// 真正进了队列的取图请求（能力门禁挡下的不算）。
    requested: u32 = 0,
    /// 取图成功、已放进缓存的次数（= `readyCount()`）。
    ready: u32 = 0,
    /// 被能力门禁挡下的查询次数（每次都算，含负缓存）。
    no_handler: u32 = 0,
    /// L2 缓存命中次数。
    cached: u32 = 0,
    /// 调了 `thumb.get` 但失败的次数（含文件不存在、Shell 出错）。
    failed: u32 = 0,
    /// 队列满时被顶掉的最旧请求数。
    dropped: u32 = 0,
    /// 还没落地的请求：队列里的 + 正在取的那一条。
    pending: u32 = 0,
    /// L2 缓存里当前的条目数 / 字节数。
    entries: usize = 0,
    bytes: usize = 0,
    /// L3 磁盘缓存的账：命中 / 未命中 / 写入 / 淘汰 / 当前占用字节。
    l3_hit: u64 = 0,
    l3_miss: u64 = 0,
    l3_write: u64 = 0,
    l3_evicted: u64 = 0,
    l3_bytes: u64 = 0,
    /// 读到的 L3 损坏条目数（已计入 l3_miss；这些文件当场删除）。
    l3_corrupt: u64 = 0,
};

/// 一个待取的请求。key / path 都是本层复制的，跨线程传递安全。
pub const Job = struct {
    key: []u8,
    path: []u8,
    size_px: u32,
    /// 入队时算好的 L3 摘要；`null` = 本次没有磁盘缓存。
    disk_key: ?l3.Key,
};

/// 自适应自旋锁：临界区只有查表、拷几十字节、入 / 出队，没有 IO。
/// 照 `ports/watch.zig` 的做法（Zig 0.17 没有不需要 Io 实例的 std.Thread.Mutex）。
pub const SpinLock = struct {
    flag: std.atomic.Value(bool) = .init(false),

    pub fn acquire(self: *SpinLock) void {
        var spins: u32 = 0;
        while (self.flag.swap(true, .acquire)) {
            spins +%= 1;
            if (spins > 64) {
                std.Thread.yield() catch {};
                spins = 0;
            }
        }
    }

    pub fn release(self: *SpinLock) void {
        self.flag.store(false, .release);
    }
};

/// pin 住的一个键。键串是本层复制的：缓存释放条目时不会连带释放它，
/// 而 `beginFrame` 必须拿着键原文才能 `cache.unpin`。
pub const Pinned = struct {
    key: []u8,
};
