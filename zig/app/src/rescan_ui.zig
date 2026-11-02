//! 监听溢出后的**局部重扫**：500 ms 防抖 → 工作线程跑 `ports/scan` → `core.rescan`
//! 差分 → `Index.applyRescan` 应用到当前视图。
//!
//! 这一层只认识「扫描任务 / 防抖 / 临时压住的事件」三件事，不 import nanoui：
//! `--demo-rescan` 可以在没有窗口的情况下驱动同一条链路，UI 的 tick 只是每拍
//! 调一次 `service`。
//!
//! ## 为什么不是「溢出就全量重建」
//!
//! 全量重扫要重新 probe 每个文件（L1 元数据）、重建分组 / 目录关系、换掉整个
//! 视图；对一个几百毫秒的溢出窗口来说太重，而且会丢掉 Index 里已经积累的
//! `folder_id` / `group_ids` / 合成 id。局部重扫只回答「磁盘和视图的 L0 事实
//! 差在哪」，增删改都落在原视图上。
//!
//! ## 线程模型
//!
//! * UI 线程：`request` / `service` / `hold` / `replay`。扫描本身在工作线程；
//!   `ScanJob` 用自旋锁交换一个 `Outcome`（`scan.Scan` 或静态错误名），
//!   `finished` 是 acquire/release 的原子标志。
//! * 工作线程只碰 `ScanJob.root` / `io` / `allocator`。allocator 必须线程安全
//!   （main / import_ui 用的是 `init.gpa`），扫描结果的 arena 在 UI 线程 `take`
//!   之后才释放。
//!
//! ## 为什么压住事件
//!
//! 溢出意味着「有一批事件丢了」，所以重扫必须相对一个**稳定的基线**做差分。
//! 如果重扫期间继续把监听事件应用到视图，差分就会拿「已经部分更新的视图」和
//! 「扫描那一刻的磁盘」比较：既可能把刚冒出来的文件误判成删除，也数不清到底
//! 修了几条。这里在重扫请求 / 进行期间把非 overflow 事件暂存进 `Hold`，等差分
//! 应用完再按原顺序 replay。
//!
//! replay 是幂等的：`Index.apply` 对重复 created 记 modified、对已删除的 removed
//! 直接忽略、对 renamed 找不到来源时降级为 created——所以「重扫已经覆盖过」的
//! 事件再放一遍不会造出重复行。
//!
//! ## 防抖与失败
//!
//! 连续溢出会把 500 ms 窗口往后推；窗口到期才起线程。失败（根目录被删 / 权限 /
//! 内存不足）不清 dirty：视图仍然不可信，2 秒后自动重试，同时把压住的事件 replay
//! 掉，不让列表因为一次扫描失败而停止更新。

const std = @import("std");
const core = @import("otto_core");
const scan_mod = @import("otto_scan");

/// 连续溢出的合并窗口。
pub const debounce_ms: u64 = 500;
/// 扫描失败后的自动重试间隔。
pub const retry_ms: u64 = 2_000;

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

/// 扫描结果：要么一份 `Scan`（arena 随结果走），要么一个静态错误名。
const Outcome = union(enum) {
    ok: scan_mod.Scan,
    failed: []const u8,

    fn deinit(self: *Outcome) void {
        switch (self.*) {
            .ok => |*result| result.deinit(),
            .failed => {},
        }
        self.* = undefined;
    }
};

/// 一次性扫描任务。对象地址必须稳定（线程持有它的指针），所以按值放在
/// `Rescan` 里，`Rescan` 又按值放在 `Live` 里。
const ScanJob = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// 借用 `Rescan.root`，生命周期由 `Rescan` 保证。
    root: []const u8,
    lock: SpinLock = .{},
    result: ?Outcome = null,
    finished: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    fn init(allocator: std.mem.Allocator, io: std.Io, root: []const u8) ScanJob {
        return .{ .allocator = allocator, .io = io, .root = root };
    }

    fn deinit(self: *ScanJob) void {
        if (self.thread) |thread| thread.join();
        self.thread = null;
        if (self.result) |*outcome| outcome.deinit();
        self.result = null;
    }

    fn start(self: *ScanJob) std.Thread.SpawnError!void {
        const job = try self.allocator.create(Job);
        job.* = .{ .owner = self };
        self.finished.store(false, .release);
        self.thread = std.Thread.spawn(.{}, Job.run, .{job}) catch |err| {
            self.allocator.destroy(job);
            return err;
        };
    }

    /// UI 线程：拿已完成的结果；没完成返回 null（不阻塞）。
    fn take(self: *ScanJob) ?Outcome {
        if (!self.finished.load(.acquire)) return null;
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        self.lock.acquire();
        const result = self.result;
        self.result = null;
        self.lock.release();
        return result;
    }
};

const Job = struct {
    owner: *ScanJob,

    fn run(self: *Job) void {
        const owner = self.owner;
        const outcome: Outcome = if (scan_mod.run(
            owner.allocator,
            owner.io,
            owner.root,
            .{},
            null,
        )) |result| .{ .ok = result } else |err| .{ .failed = @errorName(err) };

        owner.lock.acquire();
        owner.result = outcome;
        owner.finished.store(true, .release);
        owner.lock.release();

        owner.allocator.destroy(self);
    }
};

/// 重扫期间被压住的监听事件。字符串复制进自己的 arena，与 `poll` 的
/// per-poll arena 解耦。
const Hold = struct {
    allocator: std.mem.Allocator,
    list: std.ArrayListUnmanaged(core.index.Change) = .empty,
    arena: std.heap.ArenaAllocator,

    fn init(allocator: std.mem.Allocator) Hold {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    fn deinit(self: *Hold) void {
        self.list.deinit(self.allocator);
        self.arena.deinit();
        self.* = undefined;
    }

    fn add(self: *Hold, change: core.index.Change) error{OutOfMemory}!void {
        const arena = self.arena.allocator();
        const copied: core.index.Change = switch (change) {
            .created => |path| .{ .created = try arena.dupe(u8, path) },
            .removed => |path| .{ .removed = try arena.dupe(u8, path) },
            .renamed => |rename| .{ .renamed = .{
                .from = try arena.dupe(u8, rename.from),
                .to = try arena.dupe(u8, rename.to),
            } },
            .modified => |modified| .{ .modified = .{
                .path = try arena.dupe(u8, modified.path),
                .mtime = modified.mtime,
            } },
            .overflow => |lost| .{ .overflow = lost },
        };
        try self.list.append(self.allocator, copied);
    }

    fn items(self: *const Hold) []const core.index.Change {
        return self.list.items;
    }

    fn reset(self: *Hold) void {
        self.list.clearRetainingCapacity();
        _ = self.arena.reset(.retain_capacity);
    }
};

/// 一次重扫的账。`failure` 是静态 `@errorName`，可以安全复制。
pub const Report = struct {
    ok: bool = true,
    failure: ?[]const u8 = null,
    scanned: usize = 0,
    added: usize = 0,
    removed: usize = 0,
    moved: usize = 0,
    modified: usize = 0,
    unchanged: usize = 0,
    /// 更新前需要作废缩略图缓存的条数。
    dirtied: usize = 0,
    /// 重扫期间压住、重扫后 replay 的事件条数。
    replayed: usize = 0,
    elapsed_ms: f64 = 0,
};

const State = enum { idle, debounce, scanning };

pub const Rescan = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// 借用 `Live.root`：Live 比本对象活得久，且 deinit 时先 join 扫描线程。
    root: []const u8,
    job: ScanJob,
    hold: Hold,
    state: State = .idle,
    deadline: std.Io.Timestamp = .zero,
    retry_at: std.Io.Timestamp = .zero,
    started_at: std.Io.Timestamp = .zero,
    /// 每收到一次溢出 +1；扫描完成时比较它有没有涨，决定要不要再扫一轮。
    epoch: u64 = 0,
    epoch_at_start: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, root: []const u8) Rescan {
        return .{
            .allocator = allocator,
            .io = io,
            .root = root,
            .job = ScanJob.init(allocator, io, root),
            .hold = Hold.init(allocator),
        };
    }

    pub fn deinit(self: *Rescan) void {
        self.job.deinit();
        self.hold.deinit();
        self.* = undefined;
    }

    /// 是否有一次重扫在排队或进行中（UI 可据此显示「正在重扫」）。
    pub fn active(self: *const Rescan) bool {
        return self.state != .idle;
    }

    /// 请求一次重扫：排队中则把 500 ms 窗口往后推；扫描中则记下「完成后再来一轮」。
    pub fn request(self: *Rescan) void {
        self.epoch +%= 1;
        const now = self.nowTimestamp();
        switch (self.state) {
            .idle => {
                self.state = .debounce;
                self.deadline = addMs(now, debounce_ms);
            },
            .debounce => self.deadline = addMs(now, debounce_ms),
            .scanning => {},
        }
    }

    /// 压住一条监听事件，等重扫应用完再 replay。`overflow` 不进这里：
    /// 它只负责标脏 / 计数，由调用方直接处理。
    pub fn holdChange(self: *Rescan, change: core.index.Change) error{OutOfMemory}!void {
        try self.hold.add(change);
    }

    /// 每拍调一次：到点起线程、收结果、差分、应用、replay。返回非 null = 刚完成
    /// 一次重扫（成功或失败），调用方据此打日志 / 重画。
    ///
    /// `out` 用来把 replay 的事件账合并回本批的 `ApplyReport`；重扫自己的账在
    /// 返回的 `Report` 里，两边不混。
    pub fn service(
        self: *Rescan,
        index: *core.index.Index,
        out: *core.index.ApplyReport,
    ) error{OutOfMemory}!?Report {
        const now = self.nowTimestamp();

        switch (self.state) {
            .idle => {
                // 上一次失败留下的 dirty（或外部直接标脏）：到点自动重试。
                if (index.isDirty() and now.nanoseconds >= self.retry_at.nanoseconds) {
                    self.state = .debounce;
                    self.deadline = addMs(now, debounce_ms);
                }
                return null;
            },
            .debounce => {
                if (now.nanoseconds < self.deadline.nanoseconds) return null;
                self.job.start() catch |err| {
                    index.markDirty();
                    self.state = .idle;
                    self.retry_at = addMs(now, retry_ms);
                    self.hold.reset();
                    return Report{ .ok = false, .failure = @errorName(err) };
                };
                self.state = .scanning;
                self.started_at = now;
                self.epoch_at_start = self.epoch;
                return null;
            },
            .scanning => {},
        }

        const outcome = self.job.take() orelse return null;
        var report = Report{ .elapsed_ms = elapsedMs(self.started_at, now) };

        switch (outcome) {
            .failed => |name| {
                report.ok = false;
                report.failure = name;
                self.replay(index, out, &report) catch |err| {
                    report.failure = @errorName(err);
                };
                self.failAfterScan(index, now);
                return report;
            },
            .ok => |scan_value| {
                var scan = scan_value;
                defer scan.deinit();
                report.scanned = scan.files.len;
                self.apply(index, out, &report, &scan) catch |err| {
                    report.ok = false;
                    report.failure = @errorName(err);
                    self.failAfterScan(index, now);
                    return report;
                };
                self.replay(index, out, &report) catch |err| {
                    report.ok = false;
                    report.failure = @errorName(err);
                    self.failAfterScan(index, now);
                    return report;
                };

                // 扫描期间又来了溢出：这一轮只覆盖到扫描开始时的磁盘状态，
                // 后面还有缺口，保持 dirty 并再排一轮（500 ms 后）。
                if (self.epoch != self.epoch_at_start) {
                    index.markDirty();
                    self.state = .debounce;
                    self.deadline = addMs(now, debounce_ms);
                } else {
                    index.clearDirty();
                    self.state = .idle;
                    self.retry_at = .zero;
                }
                return report;
            },
        }
    }

    /// 扫描结果 → core 事实 → 差分 → 应用到 Index。字符串仍借用 `scan` 的 arena，
    /// `applyRescan` 会在返回前把需要的路径复制进 Index。
    fn apply(
        self: *Rescan,
        index: *core.index.Index,
        out: *core.index.ApplyReport,
        report: *Report,
        scan: *const scan_mod.Scan,
    ) error{OutOfMemory}!void {
        const entries = try self.allocator.alloc(core.rescan.ScanEntry, scan.files.len);
        defer self.allocator.free(entries);
        for (scan.files, 0..) |fact, position| {
            entries[position] = .{
                .path = fact.path,
                .name = fact.name,
                .ext = fact.ext,
                .size = fact.size,
                .mtime = fact.mtime,
                .identity = if (fact.identity) |identity| core.model.FileIdentity{
                    .volume_serial = identity.volume_serial,
                    .file_index = identity.file_index,
                } else null,
            };
        }

        var difference = try core.rescan.diff(self.allocator, index.samples(), entries);
        defer difference.deinit(self.allocator);

        const applied = try index.applyRescan(difference, entries);
        report.added = applied.added;
        report.removed = applied.removed;
        report.moved = applied.moved;
        report.modified = applied.modified;
        report.unchanged = applied.unchanged;
        report.dirtied = applied.invalidated.len;

        out.invalidated = applied.invalidated;
        out.rescanned = true;
        out.rescan_added = applied.added;
        out.rescan_removed = applied.removed;
        out.rescan_moved = applied.moved;
        out.rescan_modified = applied.modified;
        out.rescan_unchanged = applied.unchanged;
    }

    /// 重扫后把压住的事件按原顺序放回 Index。幂等，重复事件不会造出重复行。
    fn replay(
        self: *Rescan,
        index: *core.index.Index,
        out: *core.index.ApplyReport,
        report: *Report,
    ) error{OutOfMemory}!void {
        const events = self.hold.items();
        report.replayed = events.len;
        if (events.len == 0) {
            self.hold.reset();
            return;
        }
        const replayed = try index.apply(events);
        out.added += replayed.added;
        out.removed += replayed.removed;
        out.renamed += replayed.renamed;
        out.modified += replayed.modified;
        out.overflowed = out.overflowed or replayed.overflowed;
        out.overflow_lost +|= replayed.overflow_lost;
        out.invalidated = replayed.invalidated;
        self.hold.reset();
    }

    /// 扫描 / 应用失败后的统一收尾：视图仍是脏的、2 秒后重试、压住的事件不再留
    /// （下一次重扫会重新建立基线）。
    fn failAfterScan(self: *Rescan, index: *core.index.Index, now: std.Io.Timestamp) void {
        index.markDirty();
        self.state = .idle;
        self.retry_at = addMs(now, retry_ms);
        self.hold.reset();
    }

    fn nowTimestamp(self: *const Rescan) std.Io.Timestamp {
        return std.Io.Timestamp.now(self.io, .awake);
    }
};

fn addMs(time: std.Io.Timestamp, milliseconds: u64) std.Io.Timestamp {
    const ns: i96 = @as(i96, @intCast(milliseconds)) * std.time.ns_per_ms;
    return time.addDuration(.{ .nanoseconds = ns });
}

fn elapsedMs(from: std.Io.Timestamp, to: std.Io.Timestamp) f64 {
    const ns = to.nanoseconds - from.nanoseconds;
    const safe: f64 = @floatFromInt(if (ns > 0) ns else 0);
    return safe / 1_000_000.0;
}

// ---------------------------------------------------------------------------
// 测试：防抖倒计时与 Hold 的所有权（扫描线程 / 真文件由 `--demo-rescan` 覆盖）
// ---------------------------------------------------------------------------

const testing = std.testing;

test "防抖：请求后进入 500ms 窗口，连续请求把窗口往后推" {
    var rescan = Rescan.init(testing.allocator, testing.io, "C:\\fake-root");
    defer rescan.deinit();

    try testing.expect(!rescan.active());
    rescan.request();
    try testing.expectEqual(State.debounce, rescan.state);
    try testing.expect(rescan.deadline.nanoseconds > rescan.nowTimestamp().nanoseconds);

    const first_deadline = rescan.deadline.nanoseconds;
    rescan.request(); // 再推一次窗口
    try testing.expectEqual(State.debounce, rescan.state);
    try testing.expect(rescan.deadline.nanoseconds >= first_deadline);
}

test "Hold：事件字符串被复制，reset 后行为仍可重复使用" {
    var hold = Hold.init(testing.allocator);
    defer hold.deinit();

    const path = try testing.allocator.dupe(u8, "C:\\packs\\Kick.wav");
    try hold.add(.{ .created = path });
    testing.allocator.free(path); // Hold 已经复制，释放调用方字符串不影响它
    try hold.add(.{ .renamed = .{ .from = "C:\\a.wav", .to = "C:\\b.wav" } });
    try hold.add(.{ .overflow = 3 });

    try testing.expectEqual(@as(usize, 3), hold.items().len);
    try testing.expectEqualStrings("C:\\packs\\Kick.wav", hold.items()[0].created);
    switch (hold.items()[1]) {
        .renamed => |rename| {
            try testing.expectEqualStrings("C:\\a.wav", rename.from);
            try testing.expectEqualStrings("C:\\b.wav", rename.to);
        },
        else => return error.ExpectedRenamed,
    }

    hold.reset();
    try testing.expectEqual(@as(usize, 0), hold.items().len);
    try hold.add(.{ .removed = "C:\\c.wav" });
    try testing.expectEqual(@as(usize, 1), hold.items().len);
}
