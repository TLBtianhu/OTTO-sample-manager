//! 取图队列：**有界环形缓冲 + 优先级**（可见 > 预取）。
//!
//! 为什么单独一层：有了空闲预取之后，队列第一次同时装两种来源的请求。规则只有两条，
//! 都是硬要求，写进数据结构而不是调用方的自觉：
//!
//!   1. 队列满时**可见请求永远进得来**：先挤掉一条预取项；一条预取项都没有
//!      （队列里全是可见行）才按老规则挤最旧的那条；
//!   2. 预取项**挤不掉任何可见项**：腾不出位置时丢的是新来的预取，不是别人的可见行。
//!
//! 这样"预取把可见请求饿死"在数据结构层面就不成立，不依赖调用顺序、不依赖线程时序，
//! 也不需要"预取要谦让"这类约定。单元测试在文件末尾直接构造两种优先级压满队列验证。
//!
//! 队列项（`thumbs_types.Job`）自带 `priority`；本文件不解析样本、不碰缓存、不起线程。
//! 线程安全由调用方的锁负责（`thumbs.zig` 的 `SpinLock`），这里不重复加锁——临界区
//! 只有几十次赋值，和原来一样在锁内跑。

const std = @import("std");
const types = @import("thumbs_types.zig");

const Job = types.Job;

/// 环形队列。`slots.len` 就是容量（至少 1）。
pub const Queue = struct {
    allocator: std.mem.Allocator,
    slots: []?Job,
    head: usize = 0,
    len: usize = 0,
    /// 被挤掉的请求数（可见与预取一起记，`Thumbs.stats().dropped`）。
    dropped: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) std.mem.Allocator.Error!Queue {
        const slots = try allocator.alloc(?Job, @max(1, capacity));
        @memset(slots, null);
        return .{ .allocator = allocator, .slots = slots };
    }

    /// 释放队列里剩下的请求与缓冲本身。调用方保证工作线程已经停了。
    pub fn deinit(self: *Queue) void {
        while (self.pop()) |job| freeJob(self.allocator, job);
        self.allocator.free(self.slots);
        self.* = .{ .allocator = undefined, .slots = &.{} };
    }

    /// 入队。返回 false = 这条**预取**腾不出位置，被丢弃（调用方负责释放它）；
    /// 可见请求永远返回 true（队列满时挤掉最旧的一条）。
    pub fn push(self: *Queue, job: Job) bool {
        if (self.len == self.slots.len) {
            if (!self.evictOne(job.priority)) {
                self.dropped += 1;
                return false;
            }
        }
        const index = (self.head + self.len) % self.slots.len;
        self.slots[index] = job;
        self.len += 1;
        return true;
    }

    pub fn pop(self: *Queue) ?Job {
        if (self.len == 0) return null;
        const job = self.slots[self.head] orelse return null;
        self.slots[self.head] = null;
        self.head = (self.head + 1) % self.slots.len;
        self.len -= 1;
        return job;
    }

    /// 队列里有没有这个键（去重用：同一条请求不重复入队）。环形缓冲可能绕过一圈，
    /// 所以从 `head` 起按偏移扫，不能直接切 `slots[0..len]`。
    pub fn contains(self: *const Queue, key: []const u8) bool {
        for (0..self.len) |offset| {
            const index = (self.head + offset) % self.slots.len;
            const job = self.slots[index] orelse continue;
            if (std.mem.eql(u8, job.key, key)) return true;
        }
        return false;
    }

    /// 某一优先级在队列里的条数（报表 / 测试断言用）。
    pub fn count(self: *const Queue, priority: types.Priority) usize {
        var total: usize = 0;
        for (0..self.len) |offset| {
            const index = (self.head + offset) % self.slots.len;
            const job = self.slots[index] orelse continue;
            if (job.priority == priority) total += 1;
        }
        return total;
    }

    /// 腾一个位置。返回 false 表示腾不出来（只有预取会走到这里）。
    fn evictOne(self: *Queue, incoming: types.Priority) bool {
        // 预取项先走：它不在屏幕上，重取一次只值几毫秒。
        if (self.dropFirstPrefetch()) return true;
        // 一条预取项都没有：预取请求自己走，可见请求按老规则挤最旧的。
        if (incoming == .prefetch) return false;
        if (self.len == 0) return false;
        const job = self.slots[self.head] orelse return false;
        self.slots[self.head] = null;
        self.head = (self.head + 1) % self.slots.len;
        self.len -= 1;
        self.dropped += 1;
        freeJob(self.allocator, job);
        return true;
    }

    /// 从队首往后找第一条预取项删掉（后面的项整体前移一格，容量只有几十，够便宜）。
    /// 找到返回 true。可见请求的数量一条都不会少。
    fn dropFirstPrefetch(self: *Queue) bool {
        for (0..self.len) |offset| {
            const index = (self.head + offset) % self.slots.len;
            const job = self.slots[index] orelse continue;
            if (job.priority != .prefetch) continue;
            var cursor = offset;
            while (cursor + 1 < self.len) : (cursor += 1) {
                const dst = (self.head + cursor) % self.slots.len;
                const src = (self.head + cursor + 1) % self.slots.len;
                self.slots[dst] = self.slots[src];
            }
            self.slots[(self.head + self.len - 1) % self.slots.len] = null;
            self.len -= 1;
            self.dropped += 1;
            freeJob(self.allocator, job);
            return true;
        }
        return false;
    }
};

/// 释放一个请求（键 + 样本副本）。队列与 `thumbs.zig` 共用这一处所有权规则。
pub fn freeJob(allocator: std.mem.Allocator, job: Job) void {
    allocator.free(job.key);
    job.sample.deinit(allocator);
}

// ---------------------------------------------------------------------------
// 测试：优先级规则就是验收那条硬要求（预取不能饿死可见请求）
// ---------------------------------------------------------------------------

const testing = std.testing;
const core = @import("otto_core");
const icon = @import("thumbs_icon.zig");

/// 造一个真请求（键与样本都真的分配）：这样 `deinit` 会被 testing.allocator 查泄漏，
/// 淘汰路径漏释放会直接让测试失败。
fn makeJob(allocator: std.mem.Allocator, name: []const u8, priority: types.Priority) !Job {
    const sample = core.model.Sample{
        .id = name,
        .file_name = name,
        .file_ext = ".bmp",
        .file_path = name,
    };
    return .{
        .key = try allocator.dupe(u8, name),
        .sample = try icon.Snapshot.init(allocator, sample),
        .size_px = 64,
        .disk_key = null,
        .priority = priority,
    };
}

test "队列满：可见请求挤掉预取项，队列里可见项一条不少" {
    var queue = try Queue.init(testing.allocator, 3);
    defer queue.deinit();

    try testing.expect(queue.push(try makeJob(testing.allocator, "p1", .prefetch)));
    try testing.expect(queue.push(try makeJob(testing.allocator, "p2", .prefetch)));
    try testing.expect(queue.push(try makeJob(testing.allocator, "v1", .visible)));

    // 第四条是可见请求：挤掉队首的预取 p1，而不是任何可见项。
    try testing.expect(queue.push(try makeJob(testing.allocator, "v2", .visible)));
    try testing.expectEqual(@as(usize, 3), queue.len);
    try testing.expectEqual(@as(usize, 1), queue.count(.prefetch));
    try testing.expectEqual(@as(usize, 2), queue.count(.visible));
    try testing.expect(!queue.contains("p1"));
    try testing.expect(queue.contains("p2"));
    try testing.expect(queue.contains("v1"));
    try testing.expect(queue.contains("v2"));
    // 被挤掉的预取记进 dropped（不是被静默丢掉）。
    try testing.expectEqual(@as(u32, 1), queue.dropped);

    // 只剩预取 p2 时又来一条可见：p2 让位，可见项还是两条。
    try testing.expect(queue.push(try makeJob(testing.allocator, "v3", .visible)));
    try testing.expectEqual(@as(usize, 0), queue.count(.prefetch));
    try testing.expectEqual(@as(usize, 3), queue.count(.visible));
    try testing.expect(!queue.contains("p2"));
}

test "队列全是可见项：预取请求自己被丢掉，可见项一条不少" {
    var queue = try Queue.init(testing.allocator, 2);
    defer queue.deinit();

    try testing.expect(queue.push(try makeJob(testing.allocator, "v1", .visible)));
    try testing.expect(queue.push(try makeJob(testing.allocator, "v2", .visible)));

    // 预取进不来：返回 false，调用方释放它；队列保持原样。
    const rejected = try makeJob(testing.allocator, "p1", .prefetch);
    try testing.expect(!queue.push(rejected));
    freeJob(testing.allocator, rejected);

    try testing.expectEqual(@as(usize, 2), queue.len);
    try testing.expectEqual(@as(usize, 2), queue.count(.visible));
    try testing.expect(queue.contains("v1"));
    try testing.expect(queue.contains("v2"));
    try testing.expectEqual(@as(u32, 1), queue.dropped);
}

test "队列满且全是可见项：再来一条可见请求仍按老规则挤最旧（预取不影响这条）" {
    var queue = try Queue.init(testing.allocator, 2);
    defer queue.deinit();

    try testing.expect(queue.push(try makeJob(testing.allocator, "v1", .visible)));
    try testing.expect(queue.push(try makeJob(testing.allocator, "v2", .visible)));
    try testing.expect(queue.push(try makeJob(testing.allocator, "v3", .visible)));

    try testing.expectEqual(@as(usize, 2), queue.len);
    try testing.expect(!queue.contains("v1"));
    try testing.expect(queue.contains("v2"));
    try testing.expect(queue.contains("v3"));

    // FIFO 顺序：pop 出来的是最旧的那条。
    const first = queue.pop().?;
    defer freeJob(testing.allocator, first);
    try testing.expectEqualStrings("v2", first.key);
}

test "环形缓冲绕圈后 contains / pop / 淘汰仍然正确（预取项在中间）" {
    var queue = try Queue.init(testing.allocator, 4);
    defer queue.deinit();

    // 先塞满再弹两条，head 往前走了 2 格：下一轮会"绕过"缓冲区末尾。
    for (0..4) |i| {
        var buffer: [8]u8 = undefined;
        const name = try std.fmt.bufPrint(&buffer, "a{d}", .{i});
        try testing.expect(queue.push(try makeJob(testing.allocator, name, .visible)));
    }
    for (0..2) |_| {
        const job = queue.pop().?;
        freeJob(testing.allocator, job);
    }
    try testing.expect(queue.push(try makeJob(testing.allocator, "v2", .visible)));
    try testing.expect(queue.push(try makeJob(testing.allocator, "v3", .visible)));
    // 现在顺序是 a2, a3, v2, v3 —— 队首之前的两格是空的。
    try testing.expect(queue.contains("a2"));
    try testing.expect(queue.contains("v3"));

    // 预取进来：队列满 → 自己走；可见请求进来 → 挤掉最旧的可见 a2。
    const rejected = try makeJob(testing.allocator, "p1", .prefetch);
    try testing.expect(!queue.push(rejected));
    freeJob(testing.allocator, rejected);
    try testing.expect(queue.push(try makeJob(testing.allocator, "v4", .visible)));
    try testing.expect(!queue.contains("a2"));
    try testing.expect(queue.contains("a3"));
    try testing.expect(queue.contains("v4"));

    const popped = queue.pop().?;
    defer freeJob(testing.allocator, popped);
    try testing.expectEqualStrings("a3", popped.key);
}
