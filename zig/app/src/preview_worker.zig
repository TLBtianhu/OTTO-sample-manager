//! 预览条的**工作线程 + 请求队列**：`preview_panel.Panel` 的线程侧，单独一枝。
//!
//! 为什么要一条线程（CHARTER「一」/ `ports/thumb.zig` 的警告）：缩略图 provider
//! 会加载第三方 COM handler，`open` 可能被它卡住甚至打穿进程。`open` 是同步的，
//! 但**绝不能在 UI 线程上调**；`thumbs.zig` 的约定也是"第三方 handler 卡死时卡的是
//! 工作线程，不是 UI 线程"。这里照抄同一套：
//!
//!   * 一条工作线程 + `std.Io.Semaphore` 睡眠（不轮询、不空转），`deinit` 时 post
//!     一次唤醒并 join；
//!   * 队列只有**一格**，新请求顶掉旧请求——预览条只显示"当前选中行"，积压没有意义
//!     （与缩略图队列的"丢最旧"同一条理由）；
//!   * 临界区只有换指针，`open` 在锁外执行；队列/结果/最新 generation 过同一把自旋锁。
//!
//! 所有权与生命周期：
//!   * 工作线程拿到的是 `preview_snapshot.Snapshot`：样本的值拷贝 + 深拷贝的
//!     路径 / 名字 / 扩展名三个字符串。`Index.apply` 可能让列表数组搬家、删文件
//!     可能释放旧字符串，复制这三个字符串后请求就不会指向别人的内存；
//!   * `Outcome` 的载荷由工作线程用 `Worker.allocator`（必须是线程安全的 `init.gpa`）
//!     分配；UI 线程在 `take` 里接手，之后由 `Panel` 用它自己的同一个 allocator 释放；
//!   * 旧结果没有人取走又被新结果顶掉时，工作线程自己释放旧的 `Outcome`；
//!   * `deinit` 先 join 再释放剩余请求/结果，之后不可再用。
//!
//! 本文件不画任何东西、不认识 `ui`：视图在 `preview_panel.zig` / `preview_view.zig`。

const std = @import("std");
const preview = @import("preview.zig");
const Snapshot = @import("preview_snapshot.zig").Snapshot;

/// 自旋锁：临界区只有换 `?Snapshot` / `?Result` 指针，没有 IO、没有分配。
/// 照 `thumbs.zig` / `ports/watch.zig` 的先例（Zig 0.17 没有不需要 Io 实例的
/// `std.Thread.Mutex`）。
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

/// 工作线程交回来的一份答案。`provider` 是静态名字，`outcome` 归本结构所有。
pub const Result = struct {
    generation: u64,
    provider: ?[]const u8,
    outcome: preview.Outcome,
};

pub const InitError = std.mem.Allocator.Error || std.Thread.SpawnError;

/// 一条工作线程 + 两格（请求 / 结果）。对象在堆上：工作线程持有它的指针，
/// `Worker` 本身不能搬家。
pub const Worker = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    registry: *const preview.Registry,
    max_px: u32,

    // ---- 工作线程共享（过 lock）----
    lock: SpinLock = .{},
    /// 最多一格请求；新请求顶掉旧的。
    request: ?Snapshot = null,
    /// 最多一格结果；UI 还没取走时被顶掉，工作线程负责释放旧的。
    result: ?Result = null,
    /// 最近一次提交的 generation。工作线程用它丢弃"已经被顶掉"的结果。
    latest_generation: u64 = 0,

    thread: ?std.Thread = null,
    stop: std.atomic.Value(bool) = .init(false),
    wake: std.Io.Semaphore = .{},

    /// 起工作线程。`allocator` 必须线程安全（工作线程也用它分配像素和文本）。
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        registry: *const preview.Registry,
        max_px: u32,
    ) InitError!*Worker {
        const self = try allocator.create(Worker);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .registry = registry,
            .max_px = max_px,
        };
        // 1 MiB 栈（不是 std.Thread 默认的 16 MiB）：这个线程只做解码与文本布局，
        // 少掉的 15 MiB 是**提交**，`--mem-probe` 的 private 列能看到。
        self.thread = std.Thread.spawn(.{ .stack_size = 1 << 20 }, workerMain, .{self}) catch |err| {
            self.* = undefined;
            return err;
        };
        return self;
    }

    /// 停线程、释放请求/结果。之后不可再用（`Worker` 本身也被释放）。
    pub fn deinit(self: *Worker) void {
        self.stop.store(true, .release);
        self.wake.post(self.io);
        if (self.thread) |thread| thread.join();

        if (self.request) |snapshot| snapshot.deinit(self.allocator);
        self.request = null;
        if (self.result) |result| result.outcome.deinit(self.allocator);
        self.result = null;
        self.allocator.destroy(self);
    }

    /// 把一格请求放进队列（新请求顶掉旧的）并唤醒工作线程。
    ///
    /// `snapshot` 为 null 表示"这一帧没有选中行"：队列被清空，工作线程醒来后
    /// 没有活可干，不上屏也不查注册表。
    pub fn submit(self: *Worker, generation: u64, snapshot: ?Snapshot) void {
        self.lock.acquire();
        const replaced = self.request;
        self.request = snapshot;
        self.latest_generation = generation;
        self.lock.release();
        if (replaced) |old| old.deinit(self.allocator);
        if (snapshot != null) self.wake.post(self.io);
    }

    /// 取走一格结果（没有就 null）。只由 UI 线程调，一次最多接手一份。
    pub fn take(self: *Worker) ?Result {
        self.lock.acquire();
        const taken = self.result;
        self.result = null;
        self.lock.release();
        return taken;
    }

    fn workerMain(self: *Worker) void {
        while (true) {
            self.wake.waitUncancelable(self.io);
            if (self.stop.load(.acquire)) break;
            while (true) {
                self.lock.acquire();
                const snapshot = self.request;
                self.request = null;
                const latest = self.latest_generation;
                self.lock.release();

                const current_snapshot = snapshot orelse break;
                // 还没开始跑就已经被更新的选中行顶掉：不浪费一次 Shell 调用。
                if (current_snapshot.generation != latest) {
                    current_snapshot.deinit(self.allocator);
                    continue;
                }
                self.run(current_snapshot);
            }
        }
    }

    /// 真正调 `registry.open` 的地方：锁外执行，第三方 handler 卡住也只卡这条线程。
    fn run(self: *Worker, snapshot: Snapshot) void {
        defer snapshot.deinit(self.allocator);

        const answered = self.registry.openAnswered(
            self.allocator,
            .{ .sample = &snapshot.sample, .max_px = self.max_px },
        ) catch |err| {
            std.debug.print("otto-lite: 预览 provider 异常（{s}）\n", .{@errorName(err)});
            self.publish(snapshot.generation, null, .{ .none = .failed });
            return;
        };
        self.publish(snapshot.generation, if (answered.provider) |provider| provider.name else null, answered.outcome);
    }

    /// 把答案放进唯一一格。过期结果直接释放（不能交给 UI，UI 已经显示新的选中行）。
    fn publish(
        self: *Worker,
        generation: u64,
        provider: ?[]const u8,
        outcome: preview.Outcome,
    ) void {
        self.lock.acquire();
        const wanted = generation == self.latest_generation;
        var replaced: ?Result = null;
        if (wanted) {
            replaced = self.result;
            self.result = .{ .generation = generation, .provider = provider, .outcome = outcome };
        }
        self.lock.release();

        if (!wanted) {
            outcome.deinit(self.allocator);
            return;
        }
        if (replaced) |old| old.outcome.deinit(self.allocator);
    }
};
