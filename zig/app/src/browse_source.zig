//! 浏览模式的**生产者**：后台线程、`FindFirstFileExW` 枚举、分页与批次交接。
//!
//! 从 `browse.zig` 拆出来：这里是唯一一处会阻塞在文件系统上的代码（网络盘上一次
//! 枚举可能几秒），把它和"消费批次 / 应用事件 / 维护选中项"分开，两边都能单独读。
//!
//! 线程模型：
//!   * 一条常驻线程（`enumThreadMain`）睡在 `std.Io.Semaphore` 上；请求是几个
//!     原子位（重扫 / 加载更多 / 数剩余），被 `wake` 唤醒后按优先级处理；
//!   * 每 `batch_size` 条发布一个 `Batch`（所有权转移：数组 + 每条 path 都归消费方），
//!     每页最后一并发布 `done`（带截断/跳过/耗时/has_more/剩余条数）；
//!   * `epoch`：每次重来 +1。生产线程带着它发布，消费线程丢弃过期批次——
//!     这样"风暴时立刻重来"不需要 join 正在读的线程（网络盘上 join 可能几秒）。
//!
//! **分页怎么续**：枚举句柄（`browse_dir.Iterator`）在页与页之间**保持打开**，
//! 下一页直接 `FindNextFileW` 接着读，不从目录头重扫。理由：
//!   * 重开再跳到"最后一条名字之后"是 O(已读条数) 的二次成本（10 万条、5 页就是
//!     多扫 100 万次目录项），而句柄继续读是 O(本页条数)；
//!   * 枚举器本来就是"游标"，续读是它唯一诚实的语义。
//! 代价（写进报告，不藏）：页与页之间目录变了，新文件可能排在游标之前而漏读；
//! 这正是监听事件要补的洞——消费侧用事件把漏掉的新增补进来（`event_paths` 去重）。
//!
//! 只读：本文件不创建、不修改、不删除任何文件；唯一的写操作是内存分配。

const std = @import("std");
const browse_dir = @import("otto_browse_dir");
const types = @import("browse_types.zig");

const Entry = types.Entry;
const Batch = types.Batch;
const Status = types.Status;

pub const InitError = error{OutOfMemory} || std.Thread.SpawnError;

/// 生产线程要做的活（位掩码：重扫优先，其次加载更多，最后数剩余）。
const job_rescan: u8 = 1;
const job_more: u8 = 2;
const job_count: u8 = 4;

/// 探针的"暂停一下"用：枚举到第 N 条时停一会儿，让外部/探针在这段窗口里改目录。
/// 只有 `--browse-watch-probe --force-rescan` 会设它；产品路径永远不暂停。
const Pause = struct {
    after: usize = 0,
    ms: u64 = 0,
};

pub const Source = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// 被枚举目录的绝对路径。生产线程拥有；导航时在 beginPage 原子换代。
    root: []u8,
    pending_root: ?[]u8 = null,

    thread: ?std.Thread = null,
    wake: std.Io.Semaphore = .{},
    stop: std.atomic.Value(bool) = .init(false),
    /// 全量重枚举代次：生产线程带着它发布，消费线程丢弃过期批次。
    epoch: std.atomic.Value(u32) = .init(1),
    job: std.atomic.Value(u8) = .init(0),
    paused: std.atomic.Value(bool) = .init(false),
    pause: Pause = .{},
    /// 每页条数（`--browse-limit`）与总条数硬上限。
    page_limit: usize,
    total_cap: usize,
    lock: types.SpinLock = .{},
    queue: std.ArrayListUnmanaged(*Batch) = .empty,

    // ---- 只有生产线程碰 ----
    iterator: ?browse_dir.Iterator = null,
    /// 当前代次已经装进页里的行数（页大小/硬上限都按它算）。
    collected: usize = 0,
    /// 页读满时"偷看"到的下一条：下一页从它开始，不丢也不重读。
    pending: ?Pending = null,

    const Pending = struct {
        path: []u8,
        size: u64,
        mtime: i64,
        is_directory: bool,
        is_reparse_point: bool,
    };

    /// 起线程并立刻排第一趟枚举。返回的对象在堆上（线程持有它的指针）。
    pub fn init(allocator: std.mem.Allocator, io: std.Io, root: []const u8, page_limit: usize) InitError!*Source {
        const self = try allocator.create(Source);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .root = try allocator.dupe(u8, root),
            .page_limit = @max(1, @min(page_limit, types.hard_limit)),
            .total_cap = types.hard_limit,
        };
        errdefer allocator.free(self.root);
        self.thread = try std.Thread.spawn(.{ .stack_size = 1 << 20 }, enumThreadMain, .{self});
        errdefer {
            self.stop.store(true, .release);
            self.wake.post(io);
            if (self.thread) |thread| thread.join();
            self.thread = null;
        }
        self.request();
        return self;
    }

    /// 停线程并释放还没被消费的批次（连条目的 path 一起）。
    pub fn deinit(self: *Source) void {
        self.stop.store(true, .release);
        self.wake.post(self.io);
        if (self.thread) |thread| thread.join();
        self.thread = null;

        self.closeIterator();
        self.freePending();
        if (self.pending_root) |root| self.allocator.free(root);
        self.allocator.free(self.root);

        self.lock.acquire();
        var leftover = self.queue;
        self.queue = .empty;
        self.lock.release();
        for (leftover.items) |node| {
            types.freeEntries(self.allocator, node.items);
            if (node.items.len > 0) self.allocator.free(node.items);
            self.allocator.destroy(node);
        }
        leftover.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// 当前代次（消费方用它判断批次新不新）。
    pub fn currentEpoch(self: *const Source) u32 {
        return self.epoch.load(.acquire);
    }

    /// 要求重来（从头扫）：代次 +1 并唤醒生产线程。旧批次由消费方按 epoch 丢弃。
    pub fn request(self: *Source) void {
        _ = self.epoch.fetchAdd(1, .monotonic);
        self.job.store(job_rescan, .release);
        self.wake.post(self.io);
    }

    /// 导航：路径由生产线程在下一次重扫开头换掉，旧枚举绝不会读到已释放字符串。
    pub fn requestNavigate(self: *Source, root: []const u8) error{OutOfMemory}!void {
        const copy = try self.allocator.dupe(u8, root);
        self.lock.acquire();
        if (self.pending_root) |old| self.allocator.free(old);
        self.pending_root = copy;
        self.lock.release();
        self.request();
    }

    /// 要求再读一页：**不**动代次，也不从头扫——生产线程接着用打开的枚举句柄。
    pub fn requestMore(self: *Source) void {
        if (self.stop.load(.acquire)) return;
        // 重扫已经在排队：这一页作废（新页会由重扫的 done 重新给出 has_more）。
        if (self.job.load(.acquire) & job_rescan != 0) return;
        _ = self.job.fetchOr(job_more, .release);
        self.wake.post(self.io);
    }

    /// 内存预算拒绝了下一页：继续把枚举器读到末尾，**只数不装**，好告诉用户还剩多少。
    pub fn requestCount(self: *Source) void {
        if (self.job.load(.acquire) & job_rescan != 0) return;
        _ = self.job.fetchOr(job_count, .release);
        self.wake.post(self.io);
    }

    /// 探针用：下一次重扫枚举到 `after` 条时暂停 `ms` 毫秒（只生效一次）。
    pub fn setPause(self: *Source, after: usize, ms: u64) void {
        self.pause = .{ .after = after, .ms = ms };
    }

    pub fn pausedNow(self: *const Source) bool {
        return self.paused.load(.acquire);
    }

    /// 取走当前队列里的全部批次（所有权转移给调用方，用 `releaseList` 还回来）。
    pub fn takeBatches(self: *Source) std.ArrayListUnmanaged(*Batch) {
        self.lock.acquire();
        const list = self.queue;
        self.queue = .empty;
        self.lock.release();
        return list;
    }

    /// 消费方处理完（或丢弃）一批之后释放它的壳；条目的 path 由消费方负责。
    pub fn releaseBatch(self: *Source, node: *Batch) void {
        if (node.items.len > 0) self.allocator.free(node.items);
        self.allocator.destroy(node);
    }

    pub fn releaseList(self: *Source, list: *std.ArrayListUnmanaged(*Batch)) void {
        list.deinit(self.allocator);
    }

    // -----------------------------------------------------------------------
    // 生产线程
    // -----------------------------------------------------------------------

    fn enumThreadMain(self: *Source) void {
        while (true) {
            self.wake.waitUncancelable(self.io);
            if (self.stop.load(.acquire)) return;
            const bits = self.job.swap(0, .acquire);
            if (bits & job_rescan != 0) {
                self.beginPage(false);
            } else if (bits & job_more != 0) {
                self.beginPage(true);
            } else if (bits & job_count != 0) {
                self.countRemaining();
            }
        }
    }

    /// 读一页：`append=false` = 首批/重扫（换掉旧行），`append=true` = 追加一页。
    fn beginPage(self: *Source, append: bool) void {
        const epoch = self.epoch.load(.acquire);
        const started = types.nowNs(self.io);

        if (!append) {
            self.closeIterator();
            self.freePending();
            self.collected = 0;
            self.lock.acquire();
            const next_root = self.pending_root;
            self.pending_root = null;
            self.lock.release();
            if (next_root) |root| {
                self.allocator.free(self.root);
                self.root = root;
            }
        }

        if (self.iterator == null) {
            self.iterator = browse_dir.Iterator.open(self.allocator, self.root) catch |err| {
                self.publishDone(epoch, append, switch (err) {
                    error.PathNotFound, error.NotDirectory => .path_unavailable,
                    error.AccessDenied => .denied,
                    error.NotReady => .not_ready,
                    else => .failed,
                }, false, false, 0, 0, 0, false);
                return;
            };
            // 防御：只有 has_more 才会点「加载更多」，正常路径这里不会发生。
            if (append and self.collected > 0) self.skipFiles(self.collected);
        }

        const iterator = &(self.iterator orelse return);
        const skipped_before = iterator.skipped;
        const limit = @min(
            if (append) self.page_limit else @min(self.page_limit, types.first_page_cap),
            types.hard_limit,
        );

        var batch: std.ArrayListUnmanaged(Entry) = .empty;
        var page_rows: usize = 0;
        var join_failures: u32 = 0;
        var exhausted = false;
        var cap_hit = false;

        while (page_rows < limit) {
            if (self.stop.load(.acquire) or self.epoch.load(.acquire) != epoch) {
                // 有人要求重来 / 进程要退出：这一页作废（已发布的批次消费侧按 epoch 丢）。
                types.freeEntries(self.allocator, batch.items);
                batch.deinit(self.allocator);
                return;
            }

            if (self.pending) |pending| {
                if (self.collected >= self.total_cap) {
                    cap_hit = true;
                    break;
                }
                self.pending = null;
                batch.append(self.allocator, .{
                    .path = pending.path,
                    .size = pending.size,
                    .mtime = pending.mtime,
                    .is_directory = pending.is_directory,
                    .is_reparse_point = pending.is_reparse_point,
                }) catch {
                    self.allocator.free(pending.path);
                    join_failures += 1;
                    continue;
                };
                self.collected += 1;
                page_rows += 1;
                if (batch.items.len == types.batch_size) self.publishRows(epoch, append, &batch);
                continue;
            }

            const next = iterator.next() catch {
                join_failures += 1;
                exhausted = true;
                break;
            };
            const entry = next orelse {
                exhausted = true;
                break;
            };
            if (self.collected >= self.total_cap) {
                cap_hit = true;
                break;
            }

            const path = types.joinPath(self.allocator, self.root, entry.name) catch {
                join_failures += 1;
                continue;
            };
            batch.append(self.allocator, .{
                .path = path,
                .size = entry.size,
                .mtime = entry.mtime,
                .is_directory = entry.isDirectory(),
                .is_reparse_point = entry.isReparsePoint(),
            }) catch {
                self.allocator.free(path);
                join_failures += 1;
                continue;
            };
            self.collected += 1;
            page_rows += 1;
            if (batch.items.len == types.batch_size) self.publishRows(epoch, append, &batch);

            // 探针的确定性窗口：枚举到第 N 条时暂停，外部在这段时间里改目录。
            if (!append and self.pause.ms != 0 and self.pause.after != 0 and
                self.collected >= self.pause.after)
            {
                self.pauseOnce();
            }
        }

        // 页读满不等于"没有更多"：偷看下一条文件，确认 has_more，也让下一页从它开头。
        if (!exhausted and !cap_hit) self.peekNextFile(&join_failures);
        // `iterator.skipped` 在 peek 里也可能涨（超长名字）：一次算清这一页的跳过数。
        const skipped = join_failures + (iterator.skipped - skipped_before);
        const has_more = cap_hit or (!exhausted and self.pending != null);

        if (batch.items.len > 0) self.publishRows(epoch, append, &batch);
        batch.deinit(self.allocator);

        self.publishDone(
            epoch,
            append,
            .ok,
            has_more,
            has_more,
            0,
            skipped,
            types.nowNs(self.io) - started,
            false,
        );
    }

    /// 把"下一条文件"读进 `pending`（页边界那一行）：页与页之间不重复、也不丢掉。
    fn peekNextFile(self: *Source, skipped: *u32) void {
        const iterator = &(self.iterator orelse return);
        while (true) {
            const next = iterator.next() catch {
                skipped.* += 1;
                return;
            };
            const entry = next orelse return;
            const path = types.joinPath(self.allocator, self.root, entry.name) catch {
                skipped.* += 1;
                continue;
            };
            self.pending = .{
                .path = path,
                .size = entry.size,
                .mtime = entry.mtime,
                .is_directory = entry.isDirectory(),
                .is_reparse_point = entry.isReparsePoint(),
            };
            return;
        }
    }

    fn pauseOnce(self: *Source) void {
        const ms = self.pause.ms;
        self.pause = .{};
        self.paused.store(true, .release);
        std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(@intCast(ms)), .awake) catch {};
        self.paused.store(false, .release);
    }

    /// 防御性续页：没有句柄时重开并把已发布的条数跳过去（正常路径不走这里）。
    fn skipFiles(self: *Source, count: usize) void {
        const iterator = &(self.iterator orelse return);
        var skipped: usize = 0;
        while (skipped < count) {
            const next = iterator.next() catch return;
            _ = next orelse return;
            skipped += 1;
        }
    }

    /// 只数不装：内存预算拒绝之后，把枚举器读到末尾，报出还剩多少条。
    fn countRemaining(self: *Source) void {
        const epoch = self.epoch.load(.acquire);
        const started = types.nowNs(self.io);
        var remaining: usize = if (self.pending != null) 1 else 0;
        var skipped: u32 = 0;

        if (self.iterator) |*iterator| {
            const skipped_before = iterator.skipped;
            while (true) {
                if (self.stop.load(.acquire) or self.epoch.load(.acquire) != epoch) return;
                const next = iterator.next() catch {
                    skipped += 1;
                    break;
                };
                _ = next orelse break;
                remaining += 1;
            }
            skipped += iterator.skipped - skipped_before;
        }
        self.closeIterator();
        self.freePending();
        // 内存拒绝之后剩余条数是终态：has_more=false，免得 UI 再点一次。
        self.publishDone(epoch, true, .ok, true, false, remaining, skipped, types.nowNs(self.io) - started, true);
    }

    // -----------------------------------------------------------------------
    // 发布
    // -----------------------------------------------------------------------

    /// 把一批行交给消费侧（所有权转移：条目数组 + 每条 path）。
    fn publishRows(self: *Source, epoch: u32, append: bool, batch: *std.ArrayListUnmanaged(Entry)) void {
        const items = batch.toOwnedSlice(self.allocator) catch {
            types.freeEntries(self.allocator, batch.items);
            batch.clearRetainingCapacity();
            return;
        };
        self.publish(.{ .epoch = epoch, .append = append, .items = items });
    }

    fn publishDone(
        self: *Source,
        epoch: u32,
        append: bool,
        status: Status,
        truncated: bool,
        has_more: bool,
        remaining: usize,
        skipped: u32,
        enum_ns: i128,
        count_only: bool,
    ) void {
        self.publish(.{
            .epoch = epoch,
            .append = append,
            .done = true,
            .count_only = count_only,
            .status = status,
            .truncated = truncated,
            .has_more = has_more,
            .remaining = remaining,
            .skipped = skipped,
            .enum_ns = @intCast(@max(0, enum_ns)),
        });
    }

    fn publish(self: *Source, batch: Batch) void {
        const node = self.allocator.create(Batch) catch {
            types.freeEntries(self.allocator, batch.items);
            if (batch.items.len > 0) self.allocator.free(batch.items);
            return;
        };
        node.* = batch;
        self.lock.acquire();
        self.queue.append(self.allocator, node) catch {
            self.lock.release();
            types.freeEntries(self.allocator, node.items);
            if (node.items.len > 0) self.allocator.free(node.items);
            self.allocator.destroy(node);
            return;
        };
        self.lock.release();
    }

    fn closeIterator(self: *Source) void {
        if (self.iterator) |*iterator| iterator.close();
        self.iterator = null;
    }

    fn freePending(self: *Source) void {
        if (self.pending) |pending| self.allocator.free(pending.path);
        self.pending = null;
    }
};
