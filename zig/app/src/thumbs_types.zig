//! `thumbs.zig` 的数据契约与内部小工具：选项、借用视图、查询结果、账、队列项、
//! pin 记录与自旋锁。
//!
//! 拆出来的唯一理由是单文件行数上限（`thumbs.zig` 已经到 600 行附近）；这些类型
//! 没有行为，放在一起也让 UI / `--demo-thumbs` 读的「账」有单一出处。
//! 所有公开名字都从 `thumbs.zig` re-export，外部调用方不需要改 import 路径。

const std = @import("std");
const l3 = @import("thumbs_disk.zig");
const icon = @import("thumbs_icon.zig");
const mem_budget = @import("mem_budget.zig");

/// 请求的边长（像素）。列表那格是 32 点，Windows 的窗口在 150% / 200% 缩放下是
/// 2x，所以按 64 请求：2x 屏上正好 1:1，1x 屏由图集缩到 32 点，不会糊。
pub const default_size_px: u32 = 64;

/// 有界队列容量。一屏 380×700 / 44px ≈ 17 行，32 条留了一屏半的余量：
/// 正常滚动不会丢，只有一次性塞进更多请求时才会触发「丢最旧」。
pub const default_queue_capacity: usize = 32;

/// 缩略图 L2 缓存预算。一张 64×64 BGRA 是 16 KiB，32 MiB 装得下两千张左右，
/// 远多于一屏的可见行数。上限与预览一档一起由 `mem_budget.zig` 统一管。
pub const default_budget_bytes: usize = mem_budget.default_l2_mib * 1024 * 1024;

/// 预览一档（256px）的 L2 预算。一张 256×256 BGRA 是 256 KiB（顶十六张行内图），
/// 所以**单独一份缓存**：16 MiB ≈ 64 张预览，与行内图互不挤占。
pub const default_preview_budget_bytes: usize = mem_budget.default_preview_mib * 1024 * 1024;

/// 失败记忆的条数上限；满了丢最旧的。
pub const default_failure_memory: usize = 64;

pub const Options = struct {
    /// 请求的边长，1–`thumb.max_size_px`；超出按口岸上限夹住。
    size_px: u32 = default_size_px,
    queue_capacity: usize = default_queue_capacity,
    budget_bytes: usize = default_budget_bytes,
    /// 预览一档（256px）的 L2 预算。**与 `budget_bytes` 分开计量**：256×256 是
    /// 256 KiB，一张顶十六张行内图；混用一个 LRU 会把整屏的行内图挤出去。
    preview_budget_bytes: usize = default_preview_budget_bytes,
    failure_memory: usize = default_failure_memory,
    /// 是否把"碰 Shell"交给 `otto-thumb-host.exe`（M4 第一块）。
    /// 默认 `true`：第三方 handler 只在 helper 执行；缺失/启动失败、超时或崩溃
    /// 都是具名失败，绝不自动回主进程。`false` 只来自显式 `--no-isolation`，
    /// 此时日志必须写 `execution_domain=in_process`。
    isolation: bool = true,
    /// 行内小图是否也遵守 `--no-shell-preview`：`true` 时 `registryForIcon(true)`
    /// 里根本没有 Shell provider，PSD 之类只能显示占位，绝不偷偷问系统缩略图。
    no_shell_preview: bool = false,
    /// L3 磁盘缓存根目录；`null` = 本次不用 L3（目录建不出来 / 调用方关闭）。
    disk_cache_dir: ?[]const u8 = null,
    /// L3 预算（字节）。默认 256 MiB，启动时裁剪到预算以内。
    disk_cache_budget: u64 = l3.default_budget_bytes,
    /// 空闲预取开关（`--no-prefetch` 关掉）。关掉时 `prefetch()` 是空操作，
    /// 其余路径（可见行 `acquire`）完全不受影响——对比实验只差这一项。
    prefetch: bool = true,
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
    /// 派生来源：0 = provider 直接取图，256 = 由预览档（256px）降采样而来。
    /// 只是诊断标注（`derived_from`），像素与直接取图等价。
    source_px: u32 = 0,
};

/// `acquire` 的四种答案。UI 对后三种都画占位，只是图标不同：
///   * `pending`   —— 已进队列 / 正在取，等一次 redraw；
///   * `no_handler`—— provider 注册表全部谢绝且原因是 no_handler/unsupported
///                    （正常态，不是错误；已经负缓存）；
///   * `failed`    —— 文件没了 / provider 失败 / 队列里丢了；已经记进失败表。
pub const Lookup = union(enum) {
    ready: View,
    pending,
    no_handler,
    failed,
};

/// 取图层的账。UI / `--demo-thumbs` 只读这个快照。
pub const Stats = struct {
    /// 真正进了队列的**可见**取图请求。现在所有可见行都会入队一次，provider 的
    /// 谢绝发生在工作线程上（不再有 UI 线程的能力门禁）。
    requested: u32 = 0,
    /// 空闲预取入队的请求数。和 `requested` 分开记：预取不是用户"要"的图，
    /// 混进 requested 就看不出滚动本身到底请求了多少（验收按这个差值判断省了多少）。
    prefetched: u32 = 0,
    /// 取图成功、已放进缓存的次数（= `readyCount()`）。
    ready: u32 = 0,
    /// provider 全部谢绝且原因是 no_handler/unsupported 的次数；每条只记一次
    /// （负缓存命中不再累加）。
    no_handler: u32 = 0,
    /// L2 缓存命中次数。
    cached: u32 = 0,
    /// provider 返回 failed/file_missing（含 OOM、Shell 出错）的次数；每条只记一次。
    failed: u32 = 0,
    /// 队列满时被顶掉的请求数（可见与预取一起记）。
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
    /// 真正调 provider 的次数（行内取图 + 预览取图；**失败也算一次调用**）。
    provider_calls: u64 = 0,
    /// 其中由预览条（256px）那条路径发起的 provider 调用。冷启动只滚动时必须为 0。
    preview_calls: u32 = 0,
    /// 从预览缓存的大图派生出来的行内小图数（没有再问 provider）。
    derived: u32 = 0,
    /// 预览一档（256px）的 L2 命中次数。行内图的命中数仍记在 `cached`。
    preview_hits: u32 = 0,
    /// provider 返回的像素字节总数（行内 + 预览；命中缓存不计）。
    bytes_fetched: u64 = 0,
    /// provider 收到过的最大请求边长：64 = 只取过行内图，256 = 取过预览大图。
    max_request_px: u32 = 0,
    /// 预览一档的缓存占用（与行内图的 `entries` / `bytes` 分开计量）。
    preview_entries: usize = 0,
    preview_bytes: usize = 0,
};

/// 队列优先级：可见行 > 预取。队列满时的淘汰规则只认它（见 `thumbs_queue.zig`）：
/// 预取项只能挤掉预取项，可见请求永远进得来——"预取饿死可见请求"在数据结构层面
/// 就不成立，不依赖调用顺序。
pub const Priority = enum { visible, prefetch };

/// 一个待取的请求。key / 样本都是本层复制的，跨线程传递安全。
pub const Job = struct {
    key: []u8,
    /// 深拷贝后的样本；工作线程用它问 provider 注册表。
    sample: icon.Snapshot,
    size_px: u32,
    /// 入队时算好的 L3 摘要；`null` = 本次没有磁盘缓存。
    disk_key: ?l3.Key,
    /// 这条请求是谁要的（可见行 / 空闲预取）。只影响队列满时谁被淘汰。
    priority: Priority = .visible,
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
