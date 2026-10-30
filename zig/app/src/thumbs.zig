//! 列表左侧那格 32×32 点（2x 屏按 64px 取）：把 `zig/ports` 的「能不能取图」与
//! 「Shell 取图」变成一个不阻塞 UI 的取图层。
//!
//! 分工（CHARTER「一、可发现 / 可解码 / 可调度」）：
//!   * `otto_caps` 回答**可发现**（这台机器登记了该扩展名的 IThumbnailProvider 吗），
//!     只读注册表，不加载第三方 DLL；
//!   * `otto_thumb` 回答**可解码**（真的把像素交出来），会加载第三方 handler；
//!     M4 起这一步默认发生在 `otto-thumb-host.exe` 里，崩溃/卡死只带走 helper；
//!   * 本文件回答**可调度**：门禁、缓存、后台线程、账号（requested / ready /
//!     no_handler / cached / failed / dropped），UI 只问 `acquire`。
//!
//! 三道关（按顺序，越早越便宜）：
//!   1. **缓存**：`core.cache.Cache`（kind = `.thumbnail`）命中就直接返回，零 IO；
//!   2. **能力门禁**：`caps.forPath`。`has_handler == false` 立刻返回「无预览」，
//!      **绝不**调 `thumb.get`——没有 handler 的文件在 Shell 里只会退回一个通用
//!      文件图标，那既不是缩略图，还会白白加载一遍 Shell；
//!   3. **后台队列**：只有真的登记了 handler 的才进有界队列，由唯一一条工作线程
//!      同步调隔离层（默认 `thumb_host.get`）。第三方 handler 卡死时卡的是 helper
//!      进程，超时由客户端杀掉，UI 线程与列表都不受影响。
//!
//! 缓存键（`keyFor`）：
//!   * 有文件身份（NTFS / ReFS 的卷序列号 + 文件索引）：`id|<卷>|<索引>|<mtime>|<边长>`。
//!     身份跨改名、跨同卷移动不变，所以改名后缩略图不会重取；
//!   * 没有身份（FAT32 / exFAT / 网络盘）：`fb|<大小>|<mtime>|<路径>|<mtime>|<边长>`，
//!     路径按字节原样进键，没有拼接歧义（分隔符固定）；
//!   * `mtime` 是为了内容一变就换键：身份不变但文件被覆盖时，旧像素不能再用；
//!   * 请求边长也进键：32px 的条目不能被 256px 的请求当成命中。
//!   路径长到放不进 `max_key_bytes` 时退化成 `hash|<stableKey 哈希>|<mtime>|<边长>`，
//!   键长固定、不会无界增长（Wyhash 64 位，和 core 的注释表同一套哈希）。
//!
//! 所有权 / 线程模型：
//!   * 像素内存归 `Cache` 所有；UI 拿到的 `View.pixels` 是借用，只在 pin 期间有效。
//!     每次 view 为可见行 `acquire` 时取一次 pin，下一帧开头 `beginFrame` 统一
//!     unpin——这样「这一帧要画的东西」在 view → paint 之间不会被淘汰；
//!   * 队列、缓存、失败记忆、inflight 都过同一把自旋锁（照 `ports/watch.zig` 的
//!     先例：Zig 0.17 的 `std.Io.Mutex` 需要 Io 实例，而这里只需要几十条指令的
//!     临界区）。`thumb.get` 在锁外执行；
//!   * 工作线程用 `std.Io.Semaphore` 睡眠（不轮询、不空转），`deinit` 时 post 一次
//!     唤醒并 join；
//!   * 传进来的 allocator 必须线程安全：工作线程要用它分配像素、路径和缓存条目。
//!
//! 失败记忆：`thumb.get` 失败（文件没了 / Shell 出错）会记进一张有界表，避免每一帧
//! 都去敲一遍 Shell；磁盘事件到来时调用 `clearFailures()` 让新文件有机会重试。
//!
//! 本文件不依赖 UI（不 import nanoui），`--demo-thumbs` 可以脱离窗口直接驱动。
//!
//! 只依赖 Zig 0.17 标准库与两个口岸，没有 @cImport。

const std = @import("std");
const core = @import("otto_core");
const caps = @import("otto_caps");
const thumb = @import("otto_thumb");
const thumb_host = @import("otto_thumb_host");

/// 请求的边长（像素）。列表那格是 32 点，Windows 的窗口在 150% / 200% 缩放下是
/// 2x，所以按 64 请求：2x 屏上正好 1:1，1x 屏由图集缩到 32 点，不会糊。
pub const default_size_px: u32 = 64;

/// 有界队列容量。一屏 380×700 / 44px ≈ 17 行，32 条留了一屏半的余量：
/// 正常滚动不会丢，只有一次性塞进更多请求时才会触发「丢最旧」。
pub const default_queue_capacity: usize = 32;

/// 缩略图缓存预算。一张 64×64 BGRA 是 16 KiB，32 MiB 装得下两千张左右，
/// 远多于一屏的可见行数。
pub const default_budget_bytes: usize = 32 * 1024 * 1024;

/// 失败记忆的条数上限；满了丢最旧的。
pub const default_failure_memory: usize = 64;

/// 缓存键的栈上缓冲。Windows 长路径可能超过它，超了走哈希退化（见文件头）。
pub const max_key_bytes: usize = 512;

/// 缓存载荷的前缀：宽 / 高 / 行跨度，各 4 字节小端，之后才是 BGRA 像素。
/// 尺寸必须和像素一起进缓存，否则命中的是一个不知道多大、跨度多少的字节块。
pub const header_bytes: usize = 12;

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
    /// 缓存命中次数。
    cached: u32 = 0,
    /// 调了 `thumb.get` 但失败的次数（含文件不存在、Shell 出错）。
    failed: u32 = 0,
    /// 队列满时被顶掉的最旧请求数。
    dropped: u32 = 0,
    /// 还没落地的请求：队列里的 + 正在取的那一条。
    pending: u32 = 0,
    /// 缓存里当前的条目数 / 字节数。
    entries: usize = 0,
    bytes: usize = 0,
};

/// 一个待取的请求。key / path 都是本层复制的，跨线程传递安全。
const Job = struct {
    key: []u8,
    path: []u8,
    size_px: u32,
};

/// 自适应自旋锁：临界区只有查表、拷几十字节、入 / 出队，没有 IO。
/// 照 `ports/watch.zig` 的做法（Zig 0.17 没有不需要 Io 实例的 std.Thread.Mutex）。
const SpinLock = struct {
    flag: std.atomic.Value(bool) = .init(false),

    fn acquire(self: *SpinLock) void {
        var spins: u32 = 0;
        while (self.flag.swap(true, .acquire)) {
            spins +%= 1;
            if (spins > 64) {
                std.Thread.yield() catch {};
                spins = 0;
            }
        }
    }

    fn release(self: *SpinLock) void {
        self.flag.store(false, .release);
    }
};

/// pin 住的一个键。键串是本层复制的：缓存释放条目时不会连带释放它，
/// 而 `beginFrame` 必须拿着键原文才能 `cache.unpin`。
const Pinned = struct {
    key: []u8,
};

pub const InitError = std.mem.Allocator.Error || std.Thread.SpawnError || error{HelperUnavailable};

/// 取图层。对象在堆上：工作线程持有它的指针，`Thumbs` 本身不能搬家。
pub const Thumbs = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    size_px: u32,
    /// 取图走隔离 helper（默认）还是进程内 `thumb.get`（`--no-isolation`）。
    isolation: bool,
    cache: core.cache.Cache,

    lock: SpinLock = .{},
    /// 有界环形队列。`slots.len` 就是容量；满了由 `pushLocked` 丢最旧。
    slots: []?Job,
    head: usize = 0,
    len: usize = 0,
    /// 工作线程正在处理的请求（只为了去重与 `pending` 计数；数据归工作线程）。
    inflight: ?Job = null,
    /// 失败记忆：键原文，条数上限 `failure_memory`。
    failed_keys: std.ArrayListUnmanaged([]u8) = .empty,
    failure_memory: usize,

    /// 只由 UI 线程访问（`beginFrame` / `acquire`），不需要锁。
    pinned: std.ArrayListUnmanaged(Pinned) = .empty,

    thread: ?std.Thread = null,
    stop: std.atomic.Value(bool) = .init(false),
    wake: std.Io.Semaphore = .{},

    requested: std.atomic.Value(u32) = .init(0),
    ready: std.atomic.Value(u32) = .init(0),
    no_handler: std.atomic.Value(u32) = .init(0),
    cached: std.atomic.Value(u32) = .init(0),
    failed: std.atomic.Value(u32) = .init(0),
    dropped: std.atomic.Value(u32) = .init(0),

    /// 建立缓存、起工作线程。`allocator` 必须线程安全（工作线程也用）。
    /// 返回的对象由 `deinit` 释放，中间不要移动。
    pub fn init(allocator: std.mem.Allocator, io: std.Io, options: Options) InitError!*Thumbs {
        const self = try allocator.create(Thumbs);
        errdefer allocator.destroy(self);

        const capacity = @max(1, options.queue_capacity);
        const slots = try allocator.alloc(?Job, capacity);
        errdefer allocator.free(slots);
        @memset(slots, null);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .size_px = std.math.clamp(options.size_px, 1, thumb.max_size_px),
            .isolation = options.isolation,
            .cache = core.cache.Cache.init(allocator, options.budget_bytes),
            .slots = slots,
            .failure_memory = @max(1, options.failure_memory),
        };
        // 缩略图占满整个预算：L2 里缩略图不该被别的 Kind 挤出去（软配额 100%）。
        self.cache.setKindPercent(.thumbnail, 100);

        // 隔离是默认路径：helper exe 不在就是**启动错误**，不是「没有预览」。
        // 只查文件、不 spawn（懒启动）；也不静默退回进程内（那等于把第三方 handler
        // 又请回 OTTO 的进程里，而且用户不会知道）。
        if (self.isolation) {
            thumb_host.ensurePresent(allocator, .{}) catch |err| {
                self.cache.deinit();
                if (err == error.OutOfMemory) return error.OutOfMemory;
                std.debug.print(
                    "otto-lite: 缩略图隔离 helper 不可用（{s}）；zig build 应同时产出 otto-thumb-host.exe。\n" ++
                        "          确实要退回进程内取图（第三方 handler 与 OTTO 同生共死）加 --no-isolation。\n",
                    .{@errorName(err)},
                );
                return error.HelperUnavailable;
            };
        }

        self.thread = std.Thread.spawn(.{}, workerMain, .{self}) catch |err| {
            self.cache.deinit();
            return err;
        };
        return self;
    }

    /// 停线程、释放缓存与所有键。之后不可再用。
    pub fn deinit(self: *Thumbs) void {
        self.stop.store(true, .release);
        self.wake.post(self.io);
        if (self.thread) |thread| thread.join();

        // 工作线程已停：helper 没有在途请求了，可以收掉整个进程（隔离层的单例）。
        if (self.isolation) thumb_host.deinit();

        // 线程停了，队列 / inflight 只剩没人要的请求，逐个释放。
        self.lock.acquire();
        while (self.popLocked()) |job| {
            self.allocator.free(job.key);
            self.allocator.free(job.path);
        }
        self.lock.release();

        for (self.pinned.items) |pin| self.allocator.free(pin.key);
        self.pinned.deinit(self.allocator);
        for (self.failed_keys.items) |key| self.allocator.free(key);
        self.failed_keys.deinit(self.allocator);
        self.cache.deinit();
        self.allocator.free(self.slots);
        self.allocator.destroy(self);
    }

    /// 每帧开头调一次：把上一帧 pin 住的条目全部放掉。
    ///
    /// view 期间 pin 住的条目要活到这一帧的 paint 结束，paint 之后没有回调，
    /// 所以约定「活到下一帧开头」——中间不会被淘汰，也不会漏掉 unpin。
    pub fn beginFrame(self: *Thumbs) void {
        for (self.pinned.items) |pin| {
            _ = self.cache.unpin(pin.key);
            self.allocator.free(pin.key);
        }
        self.pinned.clearRetainingCapacity();
    }

    /// 为一行要一张缩略图。命中返回借用视图（已 pin），否则返回待取 / 无预览 / 失败。
    ///
    /// 这里的调用都在 UI 线程：缓存与去重过一次锁，能力门禁在锁外查注册表，
    /// `thumb.get` 从不在这里发生。
    pub fn acquire(self: *Thumbs, sample: core.model.Sample) Lookup {
        var buffer: [max_key_bytes]u8 = undefined;
        const key = keyFor(sample, self.size_px, &buffer);

        self.lock.acquire();
        if (self.cachedViewLocked(key)) |view| {
            self.lock.release();
            return .{ .ready = view };
        }
        if (self.knownFailureLocked(key)) {
            self.lock.release();
            return .failed;
        }
        if (self.isPendingLocked(key)) {
            self.lock.release();
            return .pending;
        }
        self.lock.release();

        // 能力门禁：没有登记 handler 的文件，`thumb.get` 只会给一个通用图标，
        // 那既不是缩略图、又会白加载一遍 Shell。这里直接给「无预览」。
        const info = caps.forPath(self.allocator, sample.file_path) catch |err| switch (err) {
            // 没有扩展名 / 扩展名非法：同样不可能有 handler。
            error.InvalidExtension, error.Unsupported => {
                _ = self.no_handler.fetchAdd(1, .monotonic);
                return .no_handler;
            },
            else => return .failed,
        };
        if (!info.has_handler) {
            _ = self.no_handler.fetchAdd(1, .monotonic);
            return .no_handler;
        }

        return self.enqueue(key, sample.file_path);
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
        return .{
            .requested = self.requested.load(.monotonic),
            .ready = self.ready.load(.monotonic),
            .no_handler = self.no_handler.load(.monotonic),
            .cached = self.cached.load(.monotonic),
            .failed = self.failed.load(.monotonic),
            .dropped = self.dropped.load(.monotonic),
            .pending = @intCast(self.len + @intFromBool(self.inflight != null)),
            .entries = cache_stats.entries,
            .bytes = cache_stats.bytes,
        };
    }

    /// 磁盘有变化（新增 / 改写 / 改名）时清空失败记忆：刚出现的文件值得再试一次。
    pub fn clearFailures(self: *Thumbs) void {
        self.lock.acquire();
        defer self.lock.release();
        for (self.failed_keys.items) |key| self.allocator.free(key);
        self.failed_keys.clearRetainingCapacity();
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

    fn knownFailureLocked(self: *const Thumbs, key: []const u8) bool {
        for (self.failed_keys.items) |failed_key| {
            if (std.mem.eql(u8, failed_key, key)) return true;
        }
        return false;
    }

    fn isPendingLocked(self: *const Thumbs, key: []const u8) bool {
        if (self.inflight) |job| {
            if (std.mem.eql(u8, job.key, key)) return true;
        }
        // 环形队列可能已经绕过一圈：从 head 起按偏移扫，不能直接切 slots[0..len]。
        for (0..self.len) |offset| {
            const index = (self.head + offset) % self.slots.len;
            const job = self.slots[index] orelse continue;
            if (std.mem.eql(u8, job.key, key)) return true;
        }
        return false;
    }

    /// 复制键与路径后入队；满了先丢最旧（计 `dropped`）。
    fn enqueue(self: *Thumbs, key: []const u8, path: []const u8) Lookup {
        const owned_key = self.allocator.dupe(u8, key) catch return .failed;
        errdefer self.allocator.free(owned_key);
        const owned_path = self.allocator.dupe(u8, path) catch return .failed;

        self.lock.acquire();
        self.pushLocked(.{ .key = owned_key, .path = owned_path, .size_px = self.size_px });
        _ = self.requested.fetchAdd(1, .monotonic);
        self.lock.release();

        self.wake.post(self.io);
        return .pending;
    }

    // -----------------------------------------------------------------------
    // 内部：环形队列（都在锁内调用）
    // -----------------------------------------------------------------------

    fn pushLocked(self: *Thumbs, job: Job) void {
        if (self.len == self.slots.len) self.dropOldestLocked();
        const index = (self.head + self.len) % self.slots.len;
        self.slots[index] = job;
        self.len += 1;
    }

    fn popLocked(self: *Thumbs) ?Job {
        if (self.len == 0) return null;
        const job = self.slots[self.head] orelse return null;
        self.slots[self.head] = null;
        self.head = (self.head + 1) % self.slots.len;
        self.len -= 1;
        return job;
    }

    /// 队列满时丢最旧：它多半已经不在屏幕上（列表往下滚了），新请求更值得做。
    fn dropOldestLocked(self: *Thumbs) void {
        const job = self.slots[self.head] orelse return;
        self.slots[self.head] = null;
        self.head = (self.head + 1) % self.slots.len;
        self.len -= 1;
        self.allocator.free(job.key);
        self.allocator.free(job.path);
        _ = self.dropped.fetchAdd(1, .monotonic);
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
        const job = self.popLocked() orelse return null;
        self.inflight = job;
        return job;
    }

    /// 真正碰 Shell 的地方：锁外执行；隔离时卡住的是 helper 进程（3 秒后被客户端杀掉），
    /// `--no-isolation` 时才是这条工作线程。
    fn fetch(self: *Thumbs, job: Job) void {
        const result = self.fetchImage(job) catch {
            self.recordFailure(job);
            return;
        };
        defer result.deinit(self.allocator);

        const pixel_bytes = result.stride * @as(usize, result.height);
        const payload = self.allocator.alloc(u8, header_bytes + pixel_bytes) catch {
            self.recordFailure(job);
            return;
        };
        defer self.allocator.free(payload);
        encodeHeader(payload, result.width, result.height, result.stride);
        @memcpy(payload[header_bytes..], result.pixels[0..pixel_bytes]);

        self.lock.acquire();
        self.inflight = null;
        self.cache.put(job.key, .thumbnail, payload) catch {
            self.lock.release();
            _ = self.failed.fetchAdd(1, .monotonic);
            // 缓存写不进去（OOM）不算「这个文件没有预览」：不记失败表，下次还会重试。
            self.allocator.free(job.key);
            self.allocator.free(job.path);
            return;
        };
        // put 成功：缓存复制了键与像素，job 自己的内存可以还了。
        _ = self.ready.fetchAdd(1, .release);
        self.lock.release();

        self.allocator.free(job.key);
        self.allocator.free(job.path);
    }

    /// 取一张图的唯一分叉点：隔离（默认）还是进程内（`--no-isolation`）。
    /// 返回类型用隔离层的错误集（`thumb.Error` 的超集），进程内分支的错误自动并上去。
    fn fetchImage(self: *Thumbs, job: Job) thumb_host.Error!thumb.Thumbnail {
        if (self.isolation) return thumb_host.get(self.allocator, job.path, job.size_px);
        return thumb.get(self.allocator, job.path, job.size_px);
    }

    /// 失败：清 inflight、记进失败表（键的所有权转移给表），路径还回去。
    fn recordFailure(self: *Thumbs, job: Job) void {
        self.lock.acquire();
        self.inflight = null;
        self.rememberFailureLocked(job.key);
        _ = self.failed.fetchAdd(1, .monotonic);
        self.lock.release();

        self.allocator.free(job.path);
    }

    fn rememberFailureLocked(self: *Thumbs, key: []u8) void {
        if (self.failed_keys.items.len >= self.failure_memory) {
            const oldest = self.failed_keys.orderedRemove(0);
            self.allocator.free(oldest);
        }
        self.failed_keys.append(self.allocator, key) catch {
            self.allocator.free(key);
        };
    }
};

// ---------------------------------------------------------------------------
// 缓存键与载荷头：纯函数，测试不用起线程、不用碰 Shell
// ---------------------------------------------------------------------------

/// 一条样本的缓存键。规则见文件头；结果写进 `buffer`，返回它的切片。
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
