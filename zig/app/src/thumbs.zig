//! 列表左侧那格 32×32 点（2x 屏按 64px 取）：把**预览 provider 注册表**变成一条
//! 不阻塞 UI 的取图管线（缓存 + 有界优先级队列 + 工作线程）。
//!
//! 行内小图不是第二条解码链：工作线程调 `thumbs_icon.fetch`，它内部就是
//! `providers.registryForIcon(no_shell).open(...)`——PNG/BMP 由 `image-wic` 解，
//! 视频首帧由 `mf-video` 抽，PSD 之类才轮到 `shell-thumbnail`（默认走隔离 helper）。
//!
//! 分工（CHARTER「一、可发现 / 可解码 / 可调度」）：
//!   * provider 回答**可发现 + 可解码**：`supports` 是廉价声明，`open` 才真的取图；
//!   * 本文件回答**可调度**：缓存、后台线程、账号（requested / prefetched / ready /
//!     no_handler / cached / failed / dropped），UI 只问 `acquire`。
//!
//! 四道关（按顺序，越早越便宜）：
//!   1. **L2 内存缓存**：`core.cache.Cache`（kind = `.thumbnail`）命中就直接返回，零 IO；
//!   2. **失败 / 谢绝记忆**：同一文件不再重复取（负缓存），磁盘事件 `clearFailures()`
//!      后才重试；
//!   3. **L3 磁盘缓存**（`thumbs_disk.zig`）：L2 没命中就进队列，由工作线程先查
//!      `<dataDir>/cache/thumbs`。命中就把像素回填 L2，**完全不碰 provider**；
//!   4. **后台队列**：L3 也没有的，由唯一一条工作线程同步调 `registryForIcon().open`。
//!      Shell 的第三方 handler 卡死时卡的是 helper 进程（3 秒超时杀），UI 线程与列表
//!      都不受影响；`--no-isolation` 才是这条工作线程。
//!
//! **两种来源，一条队列**（`thumbs_queue.zig`）：可见行是 `acquire`，滚动停下后的
//! 空闲预取是 `prefetch`（视口上下各几十行）。队列满时的淘汰只认优先级：预取项先走，
//! 腾不出位置时丢的是新来的预取——**可见请求永远不会被预取饿死**（有单元测试）。
//! 预取不写 `requested`（那是可见请求的账），单独记 `prefetched`；失败照样进失败表，
//! 否则每次滚动都会重试同一个坏文件。
//!
//! 缓存键（`thumbs_codec.zig`）：有文件身份时 `id|<卷>|<索引>|<mtime>|<边长>`（改名、
//! 同卷移动不换键），没有身份时 `fb|<大小>|<mtime>|<路径>|<mtime>|<边长>`，超长路径
//! 退化成定长哈希键。L3 的键由 L2 键串派生（Wyhash → 32 字节），跨进程稳定。缓存层
//! **不知道 provider 是谁**：键只含样本身份 + mtime + 边长，换 provider 实现不用迁移。
//!
//! 所有权 / 线程模型：
//!   * 像素内存归 `Cache` 所有；UI 拿到的 `View.pixels` 是借用，只在 pin 期间有效。
//!     每次 view 为可见行 `acquire` 时取一次 pin，下一帧开头 `beginFrame` 统一 unpin；
//!   * 队列、缓存、失败/谢绝记忆、inflight 都过同一把自旋锁（Zig 0.17 的
//!     `std.Io.Mutex` 需要 Io 实例，而这里只需要几十条指令的临界区）。
//!     `provider.open` 在锁外执行；
//!   * 工作线程用 `std.Io.Semaphore` 睡眠（不轮询、不空转），`deinit` 时 post 一次
//!     唤醒并 join；传进来的 allocator 必须线程安全。
//!
//! 本文件不依赖 UI（不 import nanoui），`--demo-thumbs` 可以脱离窗口直接驱动；
//! 只依赖 Zig 0.17 标准库、`preview` / `providers` 与几个口岸，没有 @cImport。

const std = @import("std");
const core = @import("otto_core");
const preview = @import("preview.zig");
const providers = @import("providers/root.zig");
const thumb = @import("otto_thumb");
const thumb_host = @import("otto_thumb_host");
const codec = @import("thumbs_codec.zig");
const icon = @import("thumbs_icon.zig");
const keys_mod = @import("thumbs_keys.zig");
const l3 = @import("thumbs_disk.zig");
const queue_mod = @import("thumbs_queue.zig");

const types = @import("thumbs_types.zig");
const trace = @import("trace.zig");

pub const default_size_px: u32 = types.default_size_px;
pub const default_queue_capacity: usize = types.default_queue_capacity;
pub const default_budget_bytes: usize = types.default_budget_bytes;
pub const default_failure_memory: usize = types.default_failure_memory;
pub const Options = types.Options;
pub const View = types.View;
pub const Lookup = types.Lookup;
pub const Stats = types.Stats;
pub const Priority = types.Priority;
const Job = types.Job;
const SpinLock = types.SpinLock;
const Pinned = types.Pinned;
const Queue = queue_mod.Queue;

/// 缓存键的栈上缓冲。Windows 长路径可能超过它，超了走哈希退化（见文件头）。
pub const max_key_bytes: usize = codec.max_key_bytes;

/// 缓存载荷的前缀：宽 / 高 / 行跨度，各 4 字节小端，之后才是 BGRA 像素。
/// 尺寸必须和像素一起进缓存，否则命中的是一个不知道多大、跨度多少的字节块。
pub const header_bytes: usize = codec.header_bytes;

pub const keyFor = codec.keyFor;
pub const encodeHeader = codec.encodeHeader;
pub const decodeHeader = codec.decodeHeader;
pub const diskKeyFor = codec.diskKeyFor;

pub const InitError = std.mem.Allocator.Error || std.Thread.SpawnError || error{HelperUnavailable};

/// 取图层。对象在堆上：工作线程持有它的指针，`Thumbs` 本身不能搬家。
pub const Thumbs = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    size_px: u32,
    /// 取图走隔离 helper（默认）还是进程内（`--no-isolation`）。这个开关现在
    /// 只作为 `preview.Request.allow_isolation` 传给 Shell provider；具体走哪个
    /// 口岸由 provider 决定（见 `providers/thumb.zig`）。
    isolation: bool,
    /// 行内小图是否允许问 Shell。`--no-shell-preview` 时为 false：图标注册表里
    /// 根本没有 Shell，helper 也不需要存在。
    shell_enabled: bool,
    /// 行内小图的 provider 表（`providers.registryForIcon`）。按值保存：只有一枚
    /// 指向静态数组的切片，复制很便宜，调用时也不需要再查开关。
    icon_registry: preview.Registry,
    cache: core.cache.Cache,
    /// L3 磁盘缓存。只在工作线程上读写（启动时的 prune 例外，在起线程之前）。
    disk: ?l3.L3 = null,

    lock: SpinLock = .{},
    /// 有界环形队列（容量 = `Options.queue_capacity`）。满了按优先级淘汰：
    /// 预取项先走，可见请求永远进得来（见 `thumbs_queue.zig`）。
    queue: Queue,
    /// 工作线程正在处理的请求（只为了去重与 `pending` 计数；数据归工作线程）。
    inflight: ?Job = null,
    /// 空闲预取开关。`--no-prefetch` 时 `prefetch()` 立即返回，其余路径不变。
    prefetch_enabled: bool,
    /// 失败记忆：键原文，条数上限 `failure_memory`。文件没了 / provider 失败。
    failed_keys: std.ArrayListUnmanaged([]u8) = .empty,
    /// 谢绝记忆：provider 全部说 no_handler/unsupported 的键。没有它，没有预览的
    /// 行每一帧都会重新入队——负缓存让"同文件不重复取"对谢绝也成立。
    declined_keys: std.ArrayListUnmanaged([]u8) = .empty,
    failure_memory: usize,

    /// 只由 UI 线程访问（`beginFrame` / `acquire`），不需要锁。
    pinned: std.ArrayListUnmanaged(Pinned) = .empty,

    thread: ?std.Thread = null,
    stop: std.atomic.Value(bool) = .init(false),
    wake: std.Io.Semaphore = .{},

    requested: std.atomic.Value(u32) = .init(0),
    prefetched: std.atomic.Value(u32) = .init(0),
    ready: std.atomic.Value(u32) = .init(0),
    no_handler: std.atomic.Value(u32) = .init(0),
    cached: std.atomic.Value(u32) = .init(0),
    failed: std.atomic.Value(u32) = .init(0),

    /// 建立缓存、起工作线程。`allocator` 必须线程安全（工作线程也用）。
    /// 返回的对象由 `deinit` 释放，中间不要移动。
    pub fn init(allocator: std.mem.Allocator, io: std.Io, options: Options) InitError!*Thumbs {
        const self = try allocator.create(Thumbs);
        errdefer allocator.destroy(self);

        // 队列的缓冲先于 self 建好；建 self 之后中间再没有会失败的分配，所以不需要
        // errdefer（真要在这里 errdefer 一次，后面两条手写的 deinit 路径会二次释放）。
        const queue = try Queue.init(allocator, options.queue_capacity);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .size_px = std.math.clamp(options.size_px, 1, thumb.max_size_px),
            .isolation = options.isolation,
            .shell_enabled = !options.no_shell_preview,
            .icon_registry = providers.registryForIcon(options.no_shell_preview),
            .cache = core.cache.Cache.init(allocator, options.budget_bytes),
            .queue = queue,
            .prefetch_enabled = options.prefetch,
            .failure_memory = @max(1, options.failure_memory),
        };
        // 缩略图占满整个预算：L2 里缩略图不该被别的 Kind 挤出去（软配额 100%）。
        self.cache.setKindPercent(.thumbnail, 100);

        // 隔离是默认路径：helper exe 不在就是**启动错误**，不是「没有预览」。
        // 只查文件、不 spawn（懒启动）；也不静默退回进程内（那等于把第三方 handler
        // 又请回 OTTO 的进程里，而且用户不会知道）。
        //
        // `--no-shell-preview` 时图标表里根本没有 Shell，这条检查不能误伤它：
        // 没有 Shell 就不需要 helper，PNG/BMP 仍由 image-wic 自给自足。
        if (self.isolation and self.shell_enabled) {
            thumb_host.ensurePresent(allocator, .{}) catch |err| {
                self.cache.deinit();
                self.queue.deinit();
                if (err == error.OutOfMemory) return error.OutOfMemory;
                std.debug.print(
                    "otto-lite: 缩略图隔离 helper 不可用（{s}）；zig build 应同时产出 otto-thumb-host.exe。\n" ++
                        "          确实要退回进程内取图（第三方 handler 与 OTTO 同生共死）加 --no-isolation。\n",
                    .{@errorName(err)},
                );
                return error.HelperUnavailable;
            };
        }

        // L3 磁盘缓存是**可选加速层**：目录建不出来、prune 失败都只打一行日志，
        // 不让应用起不来；调用方传 null 时本次就不用 L3。
        if (options.disk_cache_dir) |dir| {
            self.disk = l3.L3.open(self.allocator, self.io, dir, options.disk_cache_budget) catch |err| blk: {
                std.debug.print("otto-lite: L3 缓存不可用（{s}），本次只用内存缓存。\n", .{@errorName(err)});
                break :blk null;
            };
            if (self.disk) |*disk| {
                if (disk.prune()) |report| {
                    std.debug.print(
                        "otto-lite: L3 缓存 dir={s} budget={d}B 启动裁剪 scanned={d} evicted={d} bytes={d}->{d}\n",
                        .{ dir, options.disk_cache_budget, report.scanned, report.evicted, report.bytes_before, report.bytes_after },
                    );
                } else |err| {
                    std.debug.print("otto-lite: L3 启动裁剪失败（{s}），继续。\n", .{@errorName(err)});
                }
            }
        }

        // 1 MiB 栈（不是 std.Thread 默认的 16 MiB）：工作线程只做缓存查询、
        // provider 取图与一次像素拷贝，少掉的 15 MiB 是提交而不是保留。
        self.thread = std.Thread.spawn(.{ .stack_size = 1 << 20 }, workerMain, .{self}) catch |err| {
            self.cache.deinit();
            self.queue.deinit();
            if (self.disk) |*disk| disk.deinit();
            return err;
        };
        trace.mark("setup.thumbs");
        return self;
    }

    /// 停线程、释放缓存与所有键。之后不可再用。
    pub fn deinit(self: *Thumbs) void {
        self.stop.store(true, .release);
        self.wake.post(self.io);
        if (self.thread) |thread| thread.join();

        // 工作线程已停：helper 没有在途请求了，可以收掉整个进程（隔离层的单例）。
        // `--no-isolation` / `--no-shell-preview` 下没有起过 helper，不必碰它。
        if (self.isolation and self.shell_enabled) thumb_host.deinit();

        // 线程停了，队列 / inflight 只剩没人要的请求：队列一次释放键与样本。
        self.lock.acquire();
        self.queue.deinit();
        self.lock.release();

        for (self.pinned.items) |pin| self.allocator.free(pin.key);
        self.pinned.deinit(self.allocator);
        keys_mod.deinit(self.allocator, &self.failed_keys);
        keys_mod.deinit(self.allocator, &self.declined_keys);
        self.cache.deinit();
        if (self.disk) |*disk| disk.deinit();
        self.allocator.destroy(self);
    }

    /// 每帧开头调一次：把上一帧 pin 住的条目全部放掉。view 期间 pin 住的条目要活到
    /// 这一帧的 paint 结束；paint 之后没有回调，所以约定「活到下一帧开头」。
    pub fn beginFrame(self: *Thumbs) void {
        for (self.pinned.items) |pin| {
            _ = self.cache.unpin(pin.key);
            self.allocator.free(pin.key);
        }
        self.pinned.clearRetainingCapacity();
    }

    /// 为一行要一张缩略图。命中返回借用视图（已 pin），否则返回待取 / 无预览 / 失败。
    ///
    /// 这里的调用都在 UI 线程：缓存、失败/谢绝记忆与去重过一次锁；**不查能力表、
    /// 不碰 provider**——`registryForIcon(...).open` 一律在工作线程上执行。
    pub fn acquire(self: *Thumbs, sample: core.model.Sample) Lookup {
        var buffer: [max_key_bytes]u8 = undefined;
        const key = keyFor(sample, self.size_px, &buffer);
        // L3 摘要只依赖上面的键串：同一路径 + mtime + 边长跨进程稳定。
        const disk_key: ?l3.Key = if (self.disk != null) diskKeyFor(key) else null;

        self.lock.acquire();
        if (self.cachedViewLocked(key)) |view| {
            self.lock.release();
            return .{ .ready = view };
        }
        if (keys_mod.contains(self.failed_keys.items, key)) {
            self.lock.release();
            return .failed;
        }
        if (keys_mod.contains(self.declined_keys.items, key)) {
            self.lock.release();
            return .no_handler;
        }
        if (self.isPendingLocked(key)) {
            self.lock.release();
            return .pending;
        }
        self.lock.release();

        return self.enqueue(key, sample, disk_key, .visible);
    }

    /// 空闲预取：把 `rows`（**样本下标**，视图先把过滤行映射好）里还值得取的提前入队。
    ///
    /// 只补「没缓存、没在队/在取、没进失败/谢绝表」的行——每轮要问几十行，全部判断
    /// 在锁内、不分配。预取计 `prefetched` 而不是 `requested`；失败同样进失败表，
    /// 否则每次滚动都会重试同一个坏文件。
    ///
    /// 队列满时预取只能挤预取（见 `thumbs_queue.zig`）：**可见请求永远不会被饿死**。
    pub fn prefetch(self: *Thumbs, samples: []const core.model.Sample, rows: []const usize) void {
        if (!self.prefetch_enabled) return;
        for (rows) |row| {
            if (row >= samples.len) continue;
            var buffer: [max_key_bytes]u8 = undefined;
            const sample = samples[row];
            const key = keyFor(sample, self.size_px, &buffer);

            self.lock.acquire();
            const wanted = self.wantedLocked(key);
            self.lock.release();
            if (!wanted) continue;

            const disk_key: ?l3.Key = if (self.disk != null) diskKeyFor(key) else null;
            _ = self.enqueue(key, sample, disk_key, .prefetch);
        }
    }

    /// 这一行现在有缓存像素吗？**不 pin、不入队**。验收（"滚动经过的行里有多少在
    /// 进入视口那一帧就已经有图"）与预取门禁用它；绘制路径仍走 `acquire`。
    pub fn has(self: *Thumbs, sample: core.model.Sample) bool {
        var buffer: [max_key_bytes]u8 = undefined;
        const key = keyFor(sample, self.size_px, &buffer);
        self.lock.acquire();
        defer self.lock.release();
        return self.cache.contains(key);
    }

    /// 取图成功次数（完成一次 = 放进缓存并加一）。UI 的 tick 看它变没变来决定重画。
    pub fn readyCount(self: *const Thumbs) u32 {
        return self.ready.load(.acquire);
    }

    /// 账快照。`entries` / `bytes` / `pending` 需要过锁。
    pub fn stats(self: *Thumbs) Stats {
        self.lock.acquire();
        defer self.lock.release();
        const cache_stats = self.cache.stats();
        const disk_stats: l3.Stats = if (self.disk) |*disk| disk.stats() else .{};
        return .{
            .requested = self.requested.load(.monotonic),
            .prefetched = self.prefetched.load(.monotonic),
            .ready = self.ready.load(.monotonic),
            .no_handler = self.no_handler.load(.monotonic),
            .cached = self.cached.load(.monotonic),
            .failed = self.failed.load(.monotonic),
            .dropped = self.queue.dropped,
            .pending = @intCast(self.queue.len + @intFromBool(self.inflight != null)),
            .entries = cache_stats.entries,
            .bytes = cache_stats.bytes,
            .l3_hit = disk_stats.hits,
            .l3_miss = disk_stats.misses,
            .l3_write = disk_stats.writes,
            .l3_evicted = disk_stats.evicted,
            .l3_bytes = disk_stats.bytes,
            .l3_corrupt = disk_stats.corrupt,
        };
    }

    /// 磁盘有变化（新增 / 改写 / 改名）时清空失败与谢绝记忆：刚出现的文件值得再试。
    pub fn clearFailures(self: *Thumbs) void {
        self.lock.acquire();
        defer self.lock.release();
        keys_mod.clear(self.allocator, &self.failed_keys);
        keys_mod.clear(self.allocator, &self.declined_keys);
    }

    /// 设置面板改预算：L2 立即按新预算淘汰（`Cache.setBudget` 自己会淘汰），L3 换预算
    /// 后立刻裁剪一次盘上条目。打印一行**实际生效**的预算：验收脚本按这一行判断热生效。
    pub fn setBudgets(self: *Thumbs, l2_bytes: usize, l3_bytes: u64) void {
        self.lock.acquire();
        self.cache.setBudget(l2_bytes);
        self.lock.release();

        const mib: u64 = 1024 * 1024;
        std.debug.print(
            "otto-lite: cache budget l2={d}MiB l3={d}MiB\n",
            .{ @as(u64, l2_bytes) / mib, l3_bytes / mib },
        );

        if (self.disk) |*disk| {
            disk.setBudget(l3_bytes);
            if (disk.prune()) |report| {
                std.debug.print(
                    "otto-lite: L3 budget applied scanned={d} evicted={d} bytes={d}->{d} budget={d}B\n",
                    .{ report.scanned, report.evicted, report.bytes_before, report.bytes_after, report.budget_bytes },
                );
            } else |err| {
                std.debug.print("otto-lite: L3 预算裁剪失败（{s}），下次写入时再裁\n", .{@errorName(err)});
            }
        }
    }

    // -----------------------------------------------------------------------
    // 内部：缓存命中 / 失败记忆 / 入队
    // -----------------------------------------------------------------------

    /// 命中时在锁内 pin 住并复制一份键（`beginFrame` 需要键原文来 unpin）。
    /// 返回的 `View.key` 指向本层复制的键串，pin 期间一直有效。
    fn cachedViewLocked(self: *Thumbs, key: []const u8) ?View {
        const payload = self.cache.get(key) orelse return null;
        const dims = decodeHeader(payload) orelse return null;
        if (!self.cache.pin(key)) return null;

        const owned = self.allocator.dupe(u8, key) catch {
            _ = self.cache.unpin(key);
            return null;
        };
        self.pinned.append(self.allocator, .{ .key = owned }) catch {
            self.allocator.free(owned);
            _ = self.cache.unpin(key);
            return null;
        };

        _ = self.cached.fetchAdd(1, .monotonic);
        return .{
            .key = owned,
            .pixels = payload[header_bytes..][0 .. dims.stride * dims.height],
            .width = dims.width,
            .height = dims.height,
            .stride = dims.stride,
        };
    }

    /// 锁内：这个键还需要为**预取**入队吗？缓存命中、失败/谢绝记忆、已在队/在取
    /// 都不需要。每轮预取要问几十行，所以这条判断不分配、只查表。
    pub fn wantedLocked(self: *const Thumbs, key: []const u8) bool {
        if (self.cache.contains(key)) return false;
        if (keys_mod.contains(self.failed_keys.items, key)) return false;
        if (keys_mod.contains(self.declined_keys.items, key)) return false;
        return !self.isPendingLocked(key);
    }

    pub fn isPendingLocked(self: *const Thumbs, key: []const u8) bool {
        if (self.inflight) |job| {
            if (std.mem.eql(u8, job.key, key)) return true;
        }
        return self.queue.contains(key);
    }

    /// 复制键与样本后入队。`priority` 决定队列满时谁被挤掉：预取项只能挤预取项，
    /// 腾不出位置就丢自己（返回 `.pending`，调用方本来就是"下次再说"）。
    fn enqueue(self: *Thumbs, key: []const u8, sample: core.model.Sample, disk_key: ?l3.Key, priority: Priority) Lookup {
        const owned_key = self.allocator.dupe(u8, key) catch return .failed;
        const snapshot = icon.Snapshot.init(self.allocator, sample) catch {
            self.allocator.free(owned_key);
            return .failed;
        };

        self.lock.acquire();
        // 预取在锁内再核一次：分配样本的几微秒里，同一行可能已经进了可见请求。
        const wanted = priority == .visible or self.wantedLocked(key);
        const accepted = wanted and self.queue.push(.{
            .key = owned_key,
            .sample = snapshot,
            .size_px = self.size_px,
            .disk_key = disk_key,
            .priority = priority,
        });
        if (accepted) {
            if (priority == .visible) {
                _ = self.requested.fetchAdd(1, .monotonic);
            } else {
                _ = self.prefetched.fetchAdd(1, .monotonic);
            }
        }
        self.lock.release();

        if (!accepted) {
            self.allocator.free(owned_key);
            snapshot.deinit(self.allocator);
            return .pending;
        }
        self.wake.post(self.io);
        return .pending;
    }

    // -----------------------------------------------------------------------
    // 内部：工作线程
    // -----------------------------------------------------------------------

    fn workerMain(self: *Thumbs) void {
        while (true) {
            self.wake.waitUncancelable(self.io);
            if (self.stop.load(.acquire)) break;
            while (self.takeJob()) |job| self.fetch(job);
        }
    }

    fn takeJob(self: *Thumbs) ?Job {
        self.lock.acquire();
        defer self.lock.release();
        const job = self.queue.pop() orelse return null;
        self.inflight = job;
        return job;
    }

    /// 真正取图的地方：锁外执行。**provider 决定**去哪取（image-wic / mf-video /
    /// Shell 的 helper 或进程内），本层只负责缓存、去重与失败/谢绝记忆。
    fn fetch(self: *Thumbs, job: Job) void {
        // L3 先于 provider：第二次打开库时 8 张图全部从这里返回，一个 helper 都不起。
        if (self.loadFromDisk(job)) return;

        const fetched = icon.fetch(
            self.allocator,
            self.icon_registry,
            &job.sample.sample,
            job.size_px,
            self.isolation,
        ) catch {
            // 只有 OOM / 连 outcome 都构造不出来才会到这里。
            self.recordFailure(job);
            return;
        };

        switch (fetched) {
            .image => |image| {
                var bitmap = image.bitmap;
                defer bitmap.deinit(self.allocator);
                self.storeImage(job, bitmap);
            },
            // 谢绝不是错误：no_handler/unsupported 进负缓存（UI 显示文档占位），
            // failed/file_missing 进失败表（UI 显示警告三角）。
            .none => |declined| switch (declined.reason) {
                .no_handler, .unsupported => self.recordDeclined(job),
                .failed, .file_missing => self.recordFailure(job),
            },
        }
    }

    /// 把一张位图按 L2 载荷格式入缓存，再补一笔 L3；失败只影响这一张。
    fn storeImage(self: *Thumbs, job: Job, bitmap: preview.Bitmap) void {
        const pixel_bytes = bitmap.stride * @as(usize, bitmap.height);
        const payload = self.allocator.alloc(u8, header_bytes + pixel_bytes) catch {
            self.recordFailure(job);
            return;
        };
        defer self.allocator.free(payload);
        encodeHeader(payload, bitmap.width, bitmap.height, bitmap.stride);
        @memcpy(payload[header_bytes..], bitmap.pixels[0..pixel_bytes]);

        self.lock.acquire();
        self.inflight = null;
        self.cache.put(job.key, .thumbnail, payload) catch {
            self.lock.release();
            _ = self.failed.fetchAdd(1, .monotonic);
            // 缓存写不进去（OOM）不算「这个文件没有预览」：不记失败表，下次还会重试。
            self.freeJob(job);
            return;
        };
        // put 成功：缓存复制了键与像素，job 自己的内存可以还了。
        _ = self.ready.fetchAdd(1, .release);
        self.lock.release();

        // L3 写在锁外：L2 已经可画，UI 不必等这一笔磁盘 IO。
        // 缓存写失败只意味着下次重新取图，绝不影响本次结果。
        if (job.disk_key) |disk_key| {
            if (self.disk) |*disk| disk.put(disk_key, payload) catch {};
        }

        self.freeJob(job);
    }

    /// L3 命中：把磁盘像素按 L2 载荷格式回填内存缓存，结束这个请求。
    /// 命中（含回填失败）返回 true；miss / IO 错误返回 false，调用方继续走 provider。
    fn loadFromDisk(self: *Thumbs, job: Job) bool {
        const disk = if (self.disk) |*value| value else return false;
        const disk_key = job.disk_key orelse return false;
        const payload = (disk.get(self.allocator, disk_key) catch return false) orelse return false;

        self.lock.acquire();
        self.inflight = null;
        self.cache.put(job.key, .thumbnail, payload) catch {
            self.lock.release();
            self.allocator.free(payload);
            _ = self.failed.fetchAdd(1, .monotonic);
            self.freeJob(job);
            return true;
        };
        _ = self.ready.fetchAdd(1, .release);
        self.lock.release();

        self.allocator.free(payload);
        self.freeJob(job);
        return true;
    }

    /// 失败：清 inflight、记进失败表（键的所有权转移给表），样本还回去。
    fn recordFailure(self: *Thumbs, job: Job) void {
        self.lock.acquire();
        self.inflight = null;
        keys_mod.remember(self.allocator, &self.failed_keys, self.failure_memory, job.key);
        _ = self.failed.fetchAdd(1, .monotonic);
        self.lock.release();

        job.sample.deinit(self.allocator);
    }

    /// 全部 provider 谢绝：清 inflight、记进负缓存（键的所有权转移给表）。
    fn recordDeclined(self: *Thumbs, job: Job) void {
        self.lock.acquire();
        self.inflight = null;
        keys_mod.remember(self.allocator, &self.declined_keys, self.failure_memory, job.key);
        _ = self.no_handler.fetchAdd(1, .monotonic);
        self.lock.release();

        job.sample.deinit(self.allocator);
    }

    fn freeJob(self: *Thumbs, job: Job) void {
        self.allocator.free(job.key);
        job.sample.deinit(self.allocator);
    }
};
