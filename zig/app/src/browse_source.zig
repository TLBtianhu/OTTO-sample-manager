//! 浏览模式的**生产者**：后台线程、`FindFirstFileExW` 枚举、批次交接。
//!
//! 从 `browse.zig` 拆出来：这里是唯一一处会阻塞在文件系统上的代码（网络盘上一次
//! 枚举可能几秒），把它和"消费批次 / 应用事件 / 维护选中项"分开，两边都能单独读。
//!
//! 线程模型：
//!   * 一条常驻线程（`enumThreadMain`）睡在 `std.Io.Semaphore` 上，被 `request()`
//!     唤醒就跑一趟全量枚举；
//!   * 每 `batch_size` 条发布一个 `Batch`（所有权转移：数组 + 每条 path 都归消费方），
//!     最后一并发布 `done`（带截断/跳过/耗时/终态）；
//!   * `epoch`：每次重来 +1。生产线程带着它发布，消费线程丢弃过期批次——
//!     这样"风暴时立刻重来"不需要 join 正在读的线程（网络盘上 join 可能几秒）。
//!
//! 只读：本文件不创建、不修改、不删除任何文件；唯一的写操作是内存分配。

const std = @import("std");
const browse_dir = @import("otto_browse_dir");
const types = @import("browse_types.zig");

const Entry = types.Entry;
const Batch = types.Batch;
const Status = types.Status;

pub const InitError = error{OutOfMemory} || std.Thread.SpawnError;

pub const Source = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// 被枚举目录的绝对路径（末尾分隔符已去掉）。借用调用方的字符串。
    root: []const u8,

    thread: ?std.Thread = null,
    wake: std.Io.Semaphore = .{},
    stop: std.atomic.Value(bool) = .init(false),
    /// 全量重枚举代次：生产线程带着它发布，消费线程丢弃过期批次。
    epoch: std.atomic.Value(u32) = .init(1),
    lock: types.SpinLock = .{},
    queue: std.ArrayListUnmanaged(*Batch) = .empty,

    /// 起线程并立刻排第一趟枚举。返回的对象在堆上（线程持有它的指针）。
    pub fn init(allocator: std.mem.Allocator, io: std.Io, root: []const u8) InitError!*Source {
        const self = try allocator.create(Source);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .io = io, .root = root };
        self.thread = try std.Thread.spawn(.{ .stack_size = 1 << 20 }, enumThreadMain, .{self});
        errdefer {
            self.stop.store(true, .release);
            self.wake.post(io);
            if (self.thread) |thread| thread.join();
            self.thread = null;
        }
        self.wake.post(io);
        return self;
    }

    /// 停线程并释放还没被消费的批次（连条目的 path 一起）。
    pub fn deinit(self: *Source) void {
        self.stop.store(true, .release);
        self.wake.post(self.io);
        if (self.thread) |thread| thread.join();
        self.thread = null;

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

    /// 要求重来：代次 +1 并唤醒生产线程。旧批次由消费方按 epoch 丢弃。
    pub fn request(self: *Source) void {
        _ = self.epoch.fetchAdd(1, .monotonic);
        self.wake.post(self.io);
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
            self.enumeratePass();
        }
    }

    /// 一趟全量枚举：从读到的代次起按批发布；代次变了就立刻放弃。
    fn enumeratePass(self: *Source) void {
        const epoch = self.epoch.load(.acquire);
        const started = types.nowNs(self.io);

        var iterator = browse_dir.Iterator.open(self.allocator, self.root) catch |err| {
            self.publishDone(epoch, switch (err) {
                error.PathNotFound, error.NotDirectory => .path_unavailable,
                error.AccessDenied => .denied,
                else => .failed,
            }, false, 0, types.nowNs(self.io) - started);
            return;
        };
        defer iterator.close();

        var batch: std.ArrayListUnmanaged(Entry) = .empty;
        var skipped: u32 = 0;
        var truncated = false;
        var collected: usize = 0;

        while (true) {
            if (self.stop.load(.acquire) or self.epoch.load(.acquire) != epoch) {
                // 有人要求重来 / 进程要退出：这一批作废（已发布的批次消费侧按 epoch 丢）。
                types.freeEntries(self.allocator, batch.items);
                batch.deinit(self.allocator);
                return;
            }

            const next = iterator.next() catch {
                skipped += 1;
                break;
            };
            const entry = next orelse break;
            if (entry.isDirectory()) continue; // 不列子目录（Stage 0）
            if (collected == types.max_entries) {
                truncated = true;
                break;
            }

            const path = types.joinPath(self.allocator, self.root, entry.name) catch {
                skipped += 1;
                continue;
            };
            batch.append(self.allocator, .{
                .path = path,
                .size = entry.size,
                .mtime = entry.mtime,
            }) catch {
                self.allocator.free(path);
                skipped += 1;
                continue;
            };
            collected += 1;
            if (batch.items.len == types.batch_size) self.publishRows(epoch, &batch);
        }
        skipped += iterator.skipped;
        if (batch.items.len > 0) self.publishRows(epoch, &batch);
        batch.deinit(self.allocator);
        self.publishDone(epoch, .ok, truncated, skipped, types.nowNs(self.io) - started);
    }

    /// 把一批行交给消费侧（所有权转移：条目数组 + 每条 path）。
    fn publishRows(self: *Source, epoch: u32, batch: *std.ArrayListUnmanaged(Entry)) void {
        const items = batch.toOwnedSlice(self.allocator) catch {
            types.freeEntries(self.allocator, batch.items);
            batch.clearRetainingCapacity();
            return;
        };
        self.publish(.{ .epoch = epoch, .items = items });
    }

    fn publishDone(self: *Source, epoch: u32, status: Status, truncated: bool, skipped: u32, enum_ns: i128) void {
        self.publish(.{
            .epoch = epoch,
            .done = true,
            .status = status,
            .truncated = truncated,
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
};
