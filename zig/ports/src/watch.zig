//! OTTO 文件监听口岸：事件类型、有界队列与公共 API。
//!
//! 边界（CHARTER「八、零转义的边界」）：本文件只认路径字节、事件与队列，
//! 不出现句柄 / HWND / PIDL；Win32 全部在 win_watch.zig，两个文件之间只有一条
//! `win_watch.Sink` 回调边。
//!
//! 线程模型：
//!   `start()` 起一条后台线程阻塞在 ReadDirectoryChangesW；它把每条变更变成 `Event`
//!   塞进固定容量的环形队列，调用方在自己的线程 `poll()`。
//!   `stop()` 置通知位 + CancelSynchronousIo 取消阻塞读 + join，返回时就意味着线程
//!   已经退出（细节在 win_watch.zig 顶部）。
//!
//! 债可见（宪章：债可欠，但必须欠得有限、欠得可见）：
//!   * 队列容量固定；满了按 `Options.overflow_policy` 丢最旧或丢最新，`dropped()` 计数；
//!   * 内核缓冲区溢出（ERROR_NOTIFY_ENUM_DIR）产出一条 `overflow` 事件，`overflows()` 计数；
//!   * 路径装不进定长槽（或通知认不出）时不截断，事件计入 `skipped()`；
//!   * 每个事件带单调递增 `seq`；被丢的事件同样消耗 `seq`，所以序号缺口就是丢失量。

const std = @import("std");
const win = @import("win_watch.zig");

/// 变更类型。`overflow` 不是一次文件变更，而是「内核那边有变更被丢了」的显式信号。
pub const Kind = enum {
    created,
    removed,
    modified,
    renamed,
    overflow,
};

/// 单条事件的路径上限（WTF-8 字节）。装不下就丢事件并记 skipped，绝不截断路径。
pub const max_path_bytes: usize = 1024;

comptime {
    if (max_path_bytes != win.max_path_bytes) {
        @compileError("watch.max_path_bytes 与 win_watch.max_path_bytes 必须一致");
    }
}

/// 定长路径槽：事件自带路径字节，拷走即独立，生命周期不依赖队列。
pub const PathBuf = struct {
    bytes: [max_path_bytes]u8 = @splat(0),
    len: u16 = 0,

    pub fn slice(self: *const PathBuf) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const Event = struct {
    /// 单调递增序号（从 1 起）。被丢弃的事件同样消耗序号：缺口 = 丢失。
    seq: u64 = 0,
    kind: Kind,
    /// created/removed/modified：变更路径；renamed：改名后的新路径；overflow：空。
    path: PathBuf = .{},
    /// 仅 renamed：改名前的旧路径。
    old_path: PathBuf = .{},
    /// 仅 overflow：内核承认的丢失条数；0 表示「未知（缓冲区装不下）」。
    lost: u32 = 0,

    pub fn isRename(self: *const Event) bool {
        return self.kind == .renamed;
    }
};

/// 队列满时的策略。默认丢最旧：文件监听里新的变更比旧的更值得留下。
pub const OverflowPolicy = enum {
    /// 覆盖队列头（最旧），新事件入队。
    drop_oldest,
    /// 丢掉新事件，队列原样保留。
    drop_newest,
};

/// 自适应自旋锁：临界区只有一次事件拷贝（~2 KiB），没有 IO、没有分配。
/// 为什么不用 std.Io.Mutex：Zig 0.17 的 Mutex 需要 Io 实例，而口岸不该把 Io
/// 依赖强加给调用方。自旋 64 次后 SwitchToThread，避免和持有者抢同一个核。
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

/// 固定容量环形队列。生产者 = 后台线程，消费者 = poll 调用方；两侧都过锁。
pub const Queue = struct {
    allocator: std.mem.Allocator,
    slots: []Event,
    policy: OverflowPolicy,
    head: usize = 0,
    len: usize = 0,
    next_seq: u64 = 1,
    dropped_count: u64 = 0,
    overflow_count: u64 = 0,
    skipped_count: u64 = 0,
    lock: SpinLock = .{},

    pub const QueueError = error{ OutOfMemory, InvalidCapacity };

    pub fn init(allocator: std.mem.Allocator, capacity: usize, policy: OverflowPolicy) QueueError!Queue {
        if (capacity == 0) return error.InvalidCapacity;
        return .{
            .allocator = allocator,
            .slots = try allocator.alloc(Event, capacity),
            .policy = policy,
        };
    }

    pub fn deinit(self: *Queue) void {
        self.allocator.free(self.slots);
        self.slots = &.{};
    }

    /// 记录一条文件变更。路径超长时不截断、不入队，只记 skipped。
    pub fn record(self: *Queue, kind: Kind, path: []const u8, old_path: []const u8, lost: u32) void {
        if (path.len > max_path_bytes or old_path.len > max_path_bytes) {
            self.noteSkipped();
            return;
        }

        self.lock.acquire();
        defer self.lock.release();

        var event = Event{ .seq = self.next_seq, .kind = kind, .lost = lost };
        self.next_seq += 1;
        @memcpy(event.path.bytes[0..path.len], path);
        event.path.len = @intCast(path.len);
        @memcpy(event.old_path.bytes[0..old_path.len], old_path);
        event.old_path.len = @intCast(old_path.len);
        self.enqueueLocked(event);
    }

    /// 内核缓冲区溢出：既进 overflows 计数，也排一条 overflow 事件（可能随后被队列丢，
    /// 但计数不会丢——可见性不依赖队列容量）。
    pub fn recordOverflow(self: *Queue, lost: u32) void {
        self.lock.acquire();
        defer self.lock.release();

        self.overflow_count += 1;
        const event = Event{ .seq = self.next_seq, .kind = .overflow, .lost = lost };
        self.next_seq += 1;
        self.enqueueLocked(event);
    }

    pub fn noteSkipped(self: *Queue) void {
        self.lock.acquire();
        defer self.lock.release();
        self.skipped_count += 1;
    }

    fn enqueueLocked(self: *Queue, event: Event) void {
        if (self.len == self.slots.len) {
            self.dropped_count += 1;
            if (self.policy == .drop_newest) return;
            self.head = (self.head + 1) % self.slots.len;
            self.len -= 1;
        }
        const tail = (self.head + self.len) % self.slots.len;
        self.slots[tail] = event;
        self.len += 1;
    }

    /// 取走最多 out.len 条事件（最旧优先），返回条数。一次只持锁拷一条，锁窗口很短。
    pub fn poll(self: *Queue, out: []Event) usize {
        var count: usize = 0;
        while (count < out.len) {
            self.lock.acquire();
            if (self.len == 0) {
                self.lock.release();
                break;
            }
            out[count] = self.slots[self.head];
            self.head = (self.head + 1) % self.slots.len;
            self.len -= 1;
            self.lock.release();
            count += 1;
        }
        return count;
    }

    pub fn dropped(self: *Queue) u64 {
        self.lock.acquire();
        defer self.lock.release();
        return self.dropped_count;
    }

    pub fn overflows(self: *Queue) u64 {
        self.lock.acquire();
        defer self.lock.release();
        return self.overflow_count;
    }

    pub fn skipped(self: *Queue) u64 {
        self.lock.acquire();
        defer self.lock.release();
        return self.skipped_count;
    }
};

pub const Options = struct {
    /// 队列容量（事件条数）。最小 1；测试里会故意设成 4。
    capacity: usize = 256,
    /// 是否递归监视子目录。
    recursive: bool = true,
    /// FILE_NOTIFY_CHANGE_* 位。默认：文件名 | 目录名 | 最后写入 | 大小 | 创建。
    notify_filter: u32 = win.notify.default_filter,
    overflow_policy: OverflowPolicy = .drop_oldest,
};

pub const InitError = win.OpenError || error{InvalidCapacity};
pub const StartError = std.Thread.SpawnError || error{ Unsupported, AlreadyRunning };

/// 目录监听器。`start()` 之后对象不能移动（后台线程持有它的指针）。
pub const Watcher = struct {
    options: Options,
    queue: Queue,
    os: win.Context,
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = .init(false),

    /// 打开目录就开始持有句柄：路径写错、没权限在 init 阶段就能报出来，不用等 start。
    pub fn init(allocator: std.mem.Allocator, directory: []const u8, options: Options) InitError!Watcher {
        var queue = try Queue.init(allocator, options.capacity, options.overflow_policy);
        errdefer queue.deinit();
        const os = try win.Context.open(allocator, directory);
        return .{ .options = options, .queue = queue, .os = os };
    }

    /// stop + 关句柄 + 释放队列。可以重复调用；调用后对象不再可用。
    pub fn deinit(self: *Watcher) void {
        self.stop();
        self.os.deinit();
        self.queue.deinit();
    }

    /// 起后台线程，并等它把第一轮读发起来再返回：
    /// 否则「start 之后立刻改文件」可能落在读生效之前，事件永远收不到。
    pub fn start(self: *Watcher) StartError!void {
        if (self.running.load(.acquire)) return error.AlreadyRunning;
        if (!win.supported) return error.Unsupported;
        self.os.resetForStart();
        self.running.store(true, .release);
        self.thread = std.Thread.spawn(.{}, threadMain, .{self}) catch |err| {
            self.running.store(false, .release);
            return err;
        };
        // 最长等 500ms；拿不到也不报错：线程可能已经在读，只是置位慢了一拍。
        // 置位发生在进入 ReadDirectoryChangesW 之前，剩下的窗口是几条指令。
        _ = self.os.waitUntilArmed(500);
    }

    /// 幂等。返回时后台线程已经 join 完毕——不会挂在 ReadDirectoryChangesW 上。
    pub fn stop(self: *Watcher) void {
        self.running.store(false, .release);
        if (self.thread) |thread| {
            self.os.requestStop(thread.getHandle());
            thread.join();
            self.thread = null;
        } else {
            self.os.requestStop(null);
        }
    }

    pub fn isRunning(self: *const Watcher) bool {
        return self.running.load(.acquire);
    }

    pub fn poll(self: *Watcher, out: []Event) usize {
        return self.queue.poll(out);
    }

    /// poll 一条的便捷形式。
    pub fn next(self: *Watcher) ?Event {
        var one: [1]Event = undefined;
        if (self.poll(&one) == 1) return one[0];
        return null;
    }

    pub fn dropped(self: *Watcher) u64 {
        return self.queue.dropped();
    }

    pub fn overflows(self: *Watcher) u64 {
        return self.queue.overflows();
    }

    pub fn skipped(self: *Watcher) u64 {
        return self.queue.skipped();
    }

    pub fn capacity(self: *const Watcher) usize {
        return self.queue.slots.len;
    }

    /// 后台线程最后一次 Win32 错误码；0 表示没有。
    pub fn lastError(self: *const Watcher) u32 {
        return self.os.lastError();
    }
};

fn threadMain(self: *Watcher) void {
    defer self.running.store(false, .release);
    self.os.run(
        .{ .context = self, .emit = onRaw },
        self.options.recursive,
        self.options.notify_filter,
    );
}

fn onRaw(context: *anyopaque, raw: win.RawEvent) void {
    const self: *Watcher = @ptrCast(@alignCast(context));
    switch (raw.action) {
        .added => self.queue.record(.created, raw.path, "", 0),
        .removed => self.queue.record(.removed, raw.path, "", 0),
        .modified => self.queue.record(.modified, raw.path, "", 0),
        .renamed => self.queue.record(.renamed, raw.path, raw.old_path, 0),
        .overflow => self.queue.recordOverflow(raw.lost),
        .skipped => self.queue.noteSkipped(),
    }
}
