//! L2 分级缓存：一套预算、一套 LRU、一份统计、同一个淘汰器。
//!
//! 对应 CHARTER.md 第二节「一个缓存层，不是四个」：PCM / 波形峰值 / 缩略图位图 /
//! 视频帧的载荷都退化成 `[]u8`，媒体类型只体现为 `Kind`。调用方只问
//! `get` / `put`，预算、命中率、淘汰策略和监控数据只有一份实现。
//!
//! 规则：
//! * 一个字节预算 `budget_bytes`（默认 256 MiB，上限 1 GiB，绝不允许无上限）；
//! * 每次 `put` 之后若总量超预算，就从 LRU 尾部淘汰，直到不超或没有可淘汰条目；
//! * `get` 命中把条目移到最新端——淘汰按热度，不按插入顺序；
//! * `pin` / `unpin`：正在预览的条目（「选中项」）不会被淘汰，即使它撑破了预算；
//! * 软配额：某 `Kind` 的占用超过 `floor(budget * percent / 100)` 时，淘汰器优先从
//!   这些「超出自己份额」的 Kind 里挑最久未使用的条目；总量没超预算时谁也不淘汰。
//!   份额是准入权重而不是硬隔离：缩略图洪水不会把 PCM 挤空，但也不保证哪个 Kind
//!   恒定占满份额。
//! * 统计 `hits` / `misses` / `evictions` / `entries` / `bytes` / 每个 Kind 的占用。
//!
//! 所有权与生命周期：
//! * `key` 与载荷都复制进缓存，调用方保留自己的所有权；
//! * 空 key 被拒绝（`error.EmptyKey`）；0 字节载荷是合法条目；
//! * 重复 `put` 同一个 key 是替换：旧载荷释放、条目移到最新端、pin 状态保留；
//! * `get` 返回的切片在后续 `put` / `remove` / `setBudget` / `clear` 之后可能失效；
//! * 单条成本超过预算的条目会在同一次 `put` 里把自己淘汰掉（等价于不缓存）。
//!
//! 只依赖 Zig 0.17 标准库，没有 @cImport、没有外部依赖。

const std = @import("std");

/// 载荷类别。不同媒体类型的载荷共享同一套缓存机制，只在这里区分。
pub const Kind = enum {
    /// 音频 PCM 样本。
    pcm,
    /// 波形峰值。
    waveform,
    /// 缩略图位图。
    thumbnail,
    /// 视频关键帧。
    video_frame,
    /// 尚未分类的其它字节载荷。
    other,
};

/// Kind 的数量；统计数组按枚举声明顺序索引。
pub const kind_count: usize = @typeInfo(Kind).@"enum".field_names.len;

/// L2 默认预算：256 MiB（宪章「L2 永远有界」）。
pub const default_budget_bytes: usize = 256 * 1024 * 1024;

/// 预算上限：1 GiB（宪章允许的调节范围上限）。
pub const max_budget_bytes: usize = 1024 * 1024 * 1024;

/// 单个 Kind 的默认软配额，百分比；100 表示不额外限制。
pub const default_kind_percent: u8 = 100;

pub const CacheError = error{
    OutOfMemory,
    /// key 为空。路径 / 素材 id 不应为空，空 key 属于调用错误而不是缓存未命中。
    EmptyKey,
};

/// 只读统计快照。计数器是累计值，entries / bytes 是当前值。
pub const Stats = struct {
    hits: u64 = 0,
    misses: u64 = 0,
    evictions: u64 = 0,
    entries: usize = 0,
    bytes: usize = 0,
    budget_bytes: usize = 0,
    /// 每个 Kind 当前占用的字节数，顺序与 Kind 的声明顺序一致。
    kind_bytes: [kind_count]usize = @splat(0),

    /// 某个 Kind 当前的占用字节数。
    pub fn bytesFor(self: Stats, kind: Kind) usize {
        return self.kind_bytes[@backingInt(kind)];
    }
};

/// 缓存条目。key / payload 都是缓存自己分配的内存；节点串成双向 LRU 链表。
const Entry = struct {
    key: []u8,
    payload: []u8,
    kind: Kind,
    cost_bytes: usize,
    /// 嵌套 pin 计数，> 0 时淘汰器跳过该条目。
    pin_count: u32 = 0,
    /// 更新的邻居（朝 head 方向）。
    prev: ?*Entry = null,
    /// 更旧的邻居（朝 tail 方向）。
    next: ?*Entry = null,
};

/// 统一的字节预算缓存。
pub const Cache = struct {
    allocator: std.mem.Allocator,
    budget_bytes: usize,
    total_bytes: usize,
    kind_bytes: [kind_count]usize,
    /// 每个 Kind 的软配额，单位百分比（0–100），默认 100。
    kind_percent: [kind_count]u8,
    entries: std.StringHashMapUnmanaged(*Entry),
    /// 最新使用端。
    head: ?*Entry,
    /// 最久未使用端，也是淘汰起点。
    tail: ?*Entry,
    hits: u64,
    misses: u64,
    evictions: u64,

    /// 建立缓存。`budget_bytes` 超过 `max_budget_bytes` 时按上限处理。
    pub fn init(allocator: std.mem.Allocator, budget_bytes: usize) Cache {
        return .{
            .allocator = allocator,
            .budget_bytes = clampBudget(budget_bytes),
            .total_bytes = 0,
            .kind_bytes = @splat(0),
            .kind_percent = @splat(default_kind_percent),
            .entries = .{},
            .head = null,
            .tail = null,
            .hits = 0,
            .misses = 0,
            .evictions = 0,
        };
    }

    /// 释放全部条目与哈希表；之后 Cache 不可再使用。
    pub fn deinit(self: *Cache) void {
        self.clear();
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    /// 查询并刷新使用序。命中返回缓存持有的载荷（只读），未命中返回 null。
    /// 返回的切片只在下次写操作之前有效。
    pub fn get(self: *Cache, key: []const u8) ?[]const u8 {
        const entry = self.entries.get(key) orelse {
            self.misses += 1;
            return null;
        };
        self.hits += 1;
        if (self.head != entry) {
            self.unlink(entry);
            self.linkFront(entry);
        }
        return entry.payload;
    }

    /// 写入或替换一个条目，成本取载荷长度。
    /// 成功后立即按预算淘汰；调用方保留 key 与 payload 的所有权。
    pub fn put(self: *Cache, key: []const u8, kind: Kind, payload: []const u8) CacheError!void {
        return self.putWithCost(key, kind, payload, payload.len);
    }

    /// `put` 的成本估算版本：成本由调用方给出（例如位图的显存占用、解码后的
    /// 展开大小），而不是 `payload.len`。成本只影响预算，不影响复制的字节数。
    pub fn putWithCost(
        self: *Cache,
        key: []const u8,
        kind: Kind,
        payload: []const u8,
        cost_bytes: usize,
    ) CacheError!void {
        if (key.len == 0) return error.EmptyKey;

        // 先完成所有可失败的分配，保证失败时缓存原样不动。
        const new_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(new_key);
        const new_payload = try self.allocator.dupe(u8, payload);
        errdefer self.allocator.free(new_payload);
        const entry = try self.allocator.create(Entry);
        errdefer self.allocator.destroy(entry);
        if (!self.entries.contains(key)) {
            try self.entries.ensureUnusedCapacity(self.allocator, 1);
        }

        var pin_count: u32 = 0;
        if (self.entries.fetchRemove(key)) |old_kv| {
            const old = old_kv.value;
            // 替换语义：同一 key 仍然是同一个预览对象，pin 状态延续。
            pin_count = old.pin_count;
            self.release(old);
        }

        entry.* = .{
            .key = new_key,
            .payload = new_payload,
            .kind = kind,
            .cost_bytes = cost_bytes,
            .pin_count = pin_count,
        };
        self.linkFront(entry);
        self.accountAdd(entry);
        self.entries.putAssumeCapacity(entry.key, entry);
        self.evict();
    }

    /// 显式删除。删除不计入 evictions；key 不存在时返回 false。
    pub fn remove(self: *Cache, key: []const u8) bool {
        const kv = self.entries.fetchRemove(key) orelse return false;
        self.release(kv.value);
        return true;
    }

    /// 是否存在该 key。不刷新使用序、不计数。
    pub fn contains(self: *const Cache, key: []const u8) bool {
        return self.entries.contains(key);
    }

    /// 保护条目不被淘汰（可嵌套调用）。key 不存在时返回 false。
    pub fn pin(self: *Cache, key: []const u8) bool {
        const entry = self.entries.get(key) orelse return false;
        entry.pin_count +|= 1;
        return true;
    }

    /// 解除保护（可嵌套调用）。key 不存在时返回 false；未 pin 时是幂等的。
    /// 本操作不触发淘汰——下次 put / setBudget 时补上。
    pub fn unpin(self: *Cache, key: []const u8) bool {
        const entry = self.entries.get(key) orelse return false;
        entry.pin_count -|= 1;
        return true;
    }

    /// 是否处于保护状态。
    pub fn isPinned(self: *const Cache, key: []const u8) bool {
        const entry = self.entries.get(key) orelse return false;
        return entry.pin_count > 0;
    }

    /// 清空所有条目并释放它们的载荷；累计计数器（hits / misses / evictions）保留。
    pub fn clear(self: *Cache) void {
        var node = self.head;
        while (node) |entry| {
            const next = entry.next;
            self.allocator.free(entry.key);
            self.allocator.free(entry.payload);
            self.allocator.destroy(entry);
            node = next;
        }
        self.head = null;
        self.tail = null;
        self.total_bytes = 0;
        self.kind_bytes = @splat(0);
        self.entries.clearAndFree(self.allocator);
    }

    /// 运行时调整预算（超过 `max_budget_bytes` 时按上限处理），并立即按新预算淘汰。
    pub fn setBudget(self: *Cache, budget_bytes: usize) void {
        self.budget_bytes = clampBudget(budget_bytes);
        self.evict();
    }

    /// 设置某个 Kind 的软配额（百分比，0–100，超过 100 按 100 处理）。
    /// 份额只影响淘汰顺序，本操作不主动淘汰。
    pub fn setKindPercent(self: *Cache, kind: Kind, percent: u8) void {
        self.kind_percent[@backingInt(kind)] = @min(percent, 100);
    }

    /// 当前统计快照。
    pub fn stats(self: *const Cache) Stats {
        return .{
            .hits = self.hits,
            .misses = self.misses,
            .evictions = self.evictions,
            .entries = self.entries.count(),
            .bytes = self.total_bytes,
            .budget_bytes = self.budget_bytes,
            .kind_bytes = self.kind_bytes,
        };
    }

    // -----------------------------------------------------------------------
    // 内部：LRU 链表 / 记账 / 淘汰器
    // -----------------------------------------------------------------------

    /// 头插：最新使用端。
    fn linkFront(self: *Cache, entry: *Entry) void {
        entry.prev = null;
        entry.next = self.head;
        if (self.head) |head| head.prev = entry else self.tail = entry;
        self.head = entry;
    }

    /// 从 LRU 链表摘下，但不清空 prev / next 以外的内容。
    fn unlink(self: *Cache, entry: *Entry) void {
        if (entry.prev) |prev| prev.next = entry.next else self.head = entry.next;
        if (entry.next) |next| next.prev = entry.prev else self.tail = entry.prev;
        entry.prev = null;
        entry.next = null;
    }

    fn accountAdd(self: *Cache, entry: *Entry) void {
        self.total_bytes += entry.cost_bytes;
        self.kind_bytes[@backingInt(entry.kind)] += entry.cost_bytes;
    }

    fn accountRemove(self: *Cache, entry: *Entry) void {
        self.total_bytes -= entry.cost_bytes;
        self.kind_bytes[@backingInt(entry.kind)] -= entry.cost_bytes;
    }

    /// 摘下并释放一个已经从哈希表移除（或即将被覆盖）的条目。
    fn release(self: *Cache, entry: *Entry) void {
        self.unlink(entry);
        self.accountRemove(entry);
        self.allocator.free(entry.key);
        self.allocator.free(entry.payload);
        self.allocator.destroy(entry);
    }

    /// 某 Kind 的软配额字节数：floor(budget * percent / 100)。
    fn quotaBytes(self: *const Cache, kind: Kind) usize {
        const percent = self.kind_percent[@backingInt(kind)];
        // 64 位中间值避免 32 位目标上 budget * percent 溢出。
        return @intCast(@as(u64, self.budget_bytes) * percent / 100);
    }

    fn overQuota(self: *const Cache, kind: Kind) bool {
        return self.kind_bytes[@backingInt(kind)] > self.quotaBytes(kind);
    }

    /// 挑受害者：从最久未使用端向最新端扫，优先返回「超出自己软配额」的 Kind 的
    /// 最久未使用条目；找不到就退化为全局最久未使用的未 pin 条目。
    fn selectVictim(self: *const Cache) ?*Entry {
        var fallback: ?*Entry = null;
        var node = self.tail;
        while (node) |entry| {
            node = entry.prev;
            if (entry.pin_count > 0) continue;
            if (self.overQuota(entry.kind)) return entry;
            if (fallback == null) fallback = entry;
        }
        return fallback;
    }

    /// 淘汰到预算以内，或到所有剩余条目都被 pin 住为止。
    fn evict(self: *Cache) void {
        while (self.total_bytes > self.budget_bytes) {
            const victim = self.selectVictim() orelse return;
            _ = self.entries.remove(victim.key);
            self.evictions += 1;
            self.release(victim);
        }
    }
};

fn clampBudget(budget_bytes: usize) usize {
    return @min(budget_bytes, max_budget_bytes);
}
