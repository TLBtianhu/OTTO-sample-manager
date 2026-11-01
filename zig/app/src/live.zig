//! `zig/ports` 的文件监听 → `zig/core` 的 `Index`：`Live` 这个对象本身。
//!
//! 一枝三拆（本文件只留"驱动"）：
//!   * `live_adapt.zig` —— **翻译**：相对 → 绝对、kind → `Change`、`lost` → `overflow`，
//!     以及监听根的路径规则（`rootHasSamples` 等）。纯字符串，不碰磁盘；
//!   * 本文件 —— **驱动**：排空 watcher 队列、每批一次 adapt、把批次交给重扫协作，
//!     对外只暴露"视图 + 账"（`samples` / `dirty` / `poll` 的返回）；
//!   * `live_rescan.zig` —— **重扫协作**：溢出标脏、重扫期间压住事件、完成后 replay。
//!
//! 边界：
//!   * 不依赖 UI：`Live` 可以被人眼背后的定时器驱动，也可以被 `--demo` 直接驱动；
//!   * 只做适配、不替 `Index` 做决定：`renamed` 找不到 `from` 时怎么处理是
//!     `index.zig` 的语义（降级成 `created`，计入 `added`），这里不重复实现。
//!
//! 什么时候不监听（首次启动最容易撞上）：库所在目录还不存在；或者根里没有本库
//! 引用的样本——默认库在 `<dataDir>`，那里只有库文件 / `cache\thumbs` / settings，
//! 监听它会把应用自己刚写的缓存当成新素材（空库同样满足这一条）。这时 watcher
//! 是 null、`poll` 返回全零账；显式 `--watch` 不受影响。导入写出库之后
//! `import_ui.reload` 按同一规则重建 `Live`；其余监听打开失败仍然是错误。
//!
//! 线程模型：`ports.Watcher` 的后台线程只往固定队列里写；`poll()` 在调用方线程
//! 排空队列 → 适配 → `Index.apply` / 重扫协作。重扫的扫描线程只把 `scan.Scan`
//! 放进自旋锁保护的单格结果里；`Index` 仍然只在调用方线程上改。
//!
//! 所有权：
//!   * `Index` 借用 `library`（不复制），`library` 必须比 `Live` 活得久；
//!   * `poll()` 里 join 出来的路径放在每次 poll 重置的 arena 里，只活到本批
//!     `Index.apply` 返回——`Index` 会把它要长期持有的路径自己复制一份；
//!   * `root` 由 `Live` 复制持有，调用方传进来的切片之后可以失效；
//!   * `live_rescan.Bridge` 借用 `root`；`Live.deinit` 先停 watcher，再 join 扫描
//!     线程，最后才释放字符串——扫描线程不会读到悬空路径。

const std = @import("std");
const core = @import("otto_core");
const watch = @import("otto_watch");
const live_adapt = @import("live_adapt.zig");
const live_rescan = @import("live_rescan.zig");
const rescan_ui = @import("rescan_ui.zig");

/// `Live.init` 可能失败的集合：监听口岸打不开目录 / 起不了线程、根路径非法、分配失败。
pub const InitError = watch.InitError || watch.StartError || error{ OutOfMemory, InvalidRoot };

/// 监听器专用的分配器包装：保证每次分配至少 16 字节对齐。
///
/// 为什么需要（实测踩到的坑）：端口用 `allocator.alloc(u8, 64 KiB)` 申请
/// ReadDirectoryChangesW 的缓冲区，而对齐只有 1。Windows 对这个缓冲区有隐含的
/// 对齐要求：地址不是 4 的倍数时，RDCW 不返回「缓冲区太小」之类的可恢复错误，
/// 而是直接 `ERROR_NOACCESS`（998），监听线程当场退出、`watcher` 永远收不到事件。
/// `std.heap.ArenaAllocator` 是 bump 分配，完全可能给出 `…82` 这种地址（本机实测），
/// 于是 `start()` 看起来成功、后面一片安静。这里在 app 侧把对齐兜住，端口文件不动。
///
/// 实现：向 child 多要 `header + align - 1` 字节，把「原始地址 + 原始总长」写在
/// 对齐后的指针前面，free 时按 header 归还。只支持原地缩小（resize），
/// 扩容走 std 的 alloc + copy + free。
const AlignedAllocator = struct {
    child: std.mem.Allocator,

    /// 对齐下限。本机实测：地址是 2 的倍数但不是 4 的倍数时必定失败；4 字节是
    /// `FILE_NOTIFY_INFORMATION`（DWORD）的自然要求，这里取 16 留余量。
    const min_align: usize = 16;
    /// 对齐后的指针前面存两个 usize：原始地址、原始总长度（free 需要原长度）。
    const header_size: usize = 2 * @sizeOf(usize);

    fn allocator(self: *AlignedAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
        const self: *AlignedAllocator = @ptrCast(@alignCast(context));
        const align_bytes = @max(alignment.toByteUnits(), min_align);
        const total = len + header_size + align_bytes - 1;
        const raw = self.child.alloc(u8, total) catch return null;
        const aligned = std.mem.alignForward(usize, @intFromPtr(raw.ptr) + header_size, align_bytes);
        const header: [*]usize = @ptrFromInt(aligned - header_size);
        header[0] = @intFromPtr(raw.ptr);
        header[1] = total;
        return @ptrFromInt(aligned);
    }

    fn resize(_: *anyopaque, memory: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
        // 尾部本来就有 header + 对齐余量：缩小可以原地完成。free 用的是 header 里的
        // 原始长度，所以缩过再 free 也没问题；扩容交给 remap 的 null 走复制路径。
        return new_len <= memory.len;
    }

    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }

    fn free(context: *anyopaque, memory: []u8, _: std.mem.Alignment, _: usize) void {
        const self: *AlignedAllocator = @ptrCast(@alignCast(context));
        const header: [*]const usize = @ptrFromInt(@intFromPtr(memory.ptr) - header_size);
        const raw: [*]u8 = @ptrFromInt(header[0]);
        self.child.free(raw[0..header[1]]);
    }
};

pub const Live = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// 被监视目录的绝对路径（末尾分隔符已去掉）；`poll` 用它把相对路径 join 成绝对路径。
    root: []u8,
    index: core.index.Index,
    /// 显式 `--watch`：无条件监听（哪怕根里还没有样本）；默认根只在确实有样本时监听。
    force_watch: bool,
    /// 监听器放在堆上（`start()` 之后对象不能移动，而 `Live` 按值返回）。
    /// null = 没有监听根：库所在目录不存在、空库，或根里没有本库样本（见 `init`）。
    /// 这时视图就是库里的那份；导入重载会按同一规则再决定。
    watcher: ?*watch.Watcher,
    /// 监听器各次分配走这层包装（RDCW 缓冲区必须对齐，见 `AlignedAllocator`）。
    watch_allocator: *AlignedAllocator,
    /// 每次 poll 重置：本批 join 出来的路径只活到 `Index.apply` 返回。
    poll_arena: std.heap.ArenaAllocator,
    /// 溢出后的局部重扫（500 ms 防抖 + 工作线程 + hold/replay）。借用 `root`。
    rescan: live_rescan.Bridge,

    /// 建立视图并按需开始监听 `root`（`force_watch` 或根里有本库样本才监听）。
    ///
    /// 为什么不是"有目录就监听"：默认库是 `<dataDir>\library.json`，`Index.apply`
    /// 会把 watcher 报的 created 路径当成新素材——启动时建 `cache\thumbs`、写缩略图
    /// 缓存都会凭空多出几行，首次启动的空状态也会被顶掉；而那个目录里本来也永远
    /// 收不到用户素材的事件。`root` 不存在不是错误（watcher 为 null、poll 空账），
    /// 其它打开失败（权限 / 根不是目录 / 起不了线程）仍然照原样是启动错误。
    /// `allocator` 必须线程安全：重扫线程会用它在扫描结果里分配 arena。
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        library: *const core.store.Library,
        root: []const u8,
        force_watch: bool,
    ) InitError!Live {
        return initMode(allocator, io, library, root, if (force_watch) .force else .auto);
    }

    /// 浏览模式的空视图：**不监听、不建监听根**，只提供一个"没有样本"的 `Live`。
    ///
    /// 浏览模式的行来自 `browse.Session`，这里存在的唯一理由是 `main.State` 与
    /// 「导入文件夹」的状态机要一个类型正确的 `Live`（浏览模式下那个按钮不显示）。
    /// 它与 `init` 的区别只有一条：不打印"监听根没有本库的样本"——那对空库来说是
    /// 误导，而这条路本来就不该有监听。
    pub fn initIdle(allocator: std.mem.Allocator, io: std.Io, library: *const core.store.Library) InitError!Live {
        return initMode(allocator, io, library, ".", .idle);
    }

    const WatchMode = enum { auto, force, idle };

    fn initMode(
        allocator: std.mem.Allocator,
        io: std.Io,
        library: *const core.store.Library,
        root: []const u8,
        mode: WatchMode,
    ) InitError!Live {
        const owned_root = try live_adapt.normalizeRoot(allocator, root);
        errdefer allocator.free(owned_root);

        var index = try core.index.Index.init(allocator, library);
        errdefer index.deinit();

        // 监听器的分配走对齐包装（端口拿到的 allocator 决定 RDCW 缓冲区的对齐）。
        const watch_allocator = try allocator.create(AlignedAllocator);
        errdefer allocator.destroy(watch_allocator);
        watch_allocator.* = .{ .child = allocator };
        const watcher_memory = watch_allocator.allocator();

        const should_watch = switch (mode) {
            .idle => false,
            .force => true,
            .auto => live_adapt.rootHasSamples(library, owned_root),
        };
        const watcher = try watcher_memory.create(watch.Watcher);
        const watching_started = blk: {
            if (!should_watch) {
                if (mode == .auto) {
                    std.debug.print("otto-lite: 监听根没有本库的样本，暂不监听 dir={s}\n", .{owned_root});
                }
                break :blk false;
            }
            watcher.* = watch.Watcher.init(watcher_memory, owned_root, .{}) catch |err| switch (err) {
                // 目录还不存在：没有监听根。不启动 watcher（也不建目录、不监听
                // 别处——那会把事件路径对到不存在的样本上）。
                error.FileNotFound => {
                    std.debug.print("otto-lite: 监听根不存在，暂不监听 dir={s}\n", .{owned_root});
                    break :blk false;
                },
                else => |other| return other,
            };
            break :blk true;
        };
        if (watching_started) {
            watcher.start() catch |err| {
                watcher.deinit();
                watcher_memory.destroy(watcher);
                return err;
            };
        } else {
            watcher_memory.destroy(watcher);
        }

        return .{
            .allocator = allocator,
            .io = io,
            .root = owned_root,
            .index = index,
            .force_watch = mode == .force,
            .watcher = if (watching_started) watcher else null,
            .watch_allocator = watch_allocator,
            .poll_arena = std.heap.ArenaAllocator.init(allocator),
            .rescan = live_rescan.Bridge.init(allocator, io, owned_root),
        };
    }

    /// 停监听、释放视图与全部字符串；之后不可再用。
    pub fn deinit(self: *Live) void {
        if (self.watcher) |watcher| {
            watcher.deinit();
            self.watch_allocator.allocator().destroy(watcher);
        }
        self.rescan.deinit();
        self.allocator.destroy(self.watch_allocator);
        self.index.deinit();
        self.poll_arena.deinit();
        self.allocator.free(self.root);
        self.* = undefined;
    }

    /// 真的挂上了监听吗？空库 / 根里没有本库样本 / 根还不存在时是 false。
    pub fn watching(self: *const Live) bool {
        return self.watcher != null;
    }

    /// 启动时是否显式 `--watch`（`import_ui.reload` 建新 Live 时沿用）。
    pub fn watchForced(self: *const Live) bool {
        return self.force_watch;
    }

    /// 排空 watcher → 适配成 `core.Change` → 一次性交给重扫协作。
    ///
    /// 返回的账是本批事件的合计；空批次（没事件）返回全零报告。
    /// `report.invalidated` 的生命周期与 `Index.apply` 一致：到下一次 `poll` 失效。
    pub fn poll(self: *Live) error{OutOfMemory}!core.index.ApplyReport {
        _ = self.poll_arena.reset(.retain_capacity);
        const arena = self.poll_arena.allocator();

        var changes: std.ArrayListUnmanaged(core.index.Change) = .empty;
        if (self.watcher) |watcher| {
            while (watcher.next()) |event| {
                if (try live_adapt.adapt(&event, self.root, arena)) |change| {
                    try changes.append(arena, change);
                }
            }
        }

        return self.rescan.applyBatch(&self.index, changes.items);
    }

    /// 当前视图（只读）。下次 `poll` 可能让数组搬家，别长期持有这个切片。
    pub fn samples(self: *const Live) []const core.model.Sample {
        return self.index.samples();
    }

    /// 监听丢过事件、视图可能不完整（透传 `Index.isDirty()`）。
    pub fn dirty(self: *const Live) bool {
        return self.index.isDirty();
    }

    /// 强制注入一次溢出（测试 / `--demo-rescan` 的钩子）：和 watcher 报
    /// `Change.overflow` 走同一条路——标脏 + 排重扫。不依赖真实的内核缓冲区溢出。
    /// 没有监听根时是空操作：重扫要读的目录根本不存在，排了也只会失败重试。
    pub fn injectOverflow(self: *Live, lost: u32) error{OutOfMemory}!void {
        if (self.watcher == null) return;
        _ = try self.index.apply(&.{.{ .overflow = lost }});
        self.rescan.request();
    }

    /// 不经过溢出、主动排一次重扫（`--demo-rescan` 的「再跑一次」用它）。
    pub fn requestRescan(self: *Live) void {
        if (self.watcher == null) return;
        self.rescan.request();
    }

    /// 重扫排队 / 进行中（UI 可以据此决定是否显示「正在重扫」）。
    pub fn rescanActive(self: *const Live) bool {
        return self.rescan.active();
    }

    /// 已完成的重扫次数；每完成一次 +1（成功和失败都算，用来等结果）。
    pub fn rescanSerial(self: *const Live) u64 {
        return self.rescan.rescanSerial();
    }

    /// 最近一次完成的重扫的账。
    pub fn lastRescan(self: *const Live) rescan_ui.Report {
        return self.rescan.lastRescan();
    }
};

/// 监听根里有没有本库引用的样本；实现在 `live_adapt.zig`（路径规则那边），
/// 这里转出是给 `live_test.zig` 与调用方留同一个入口。
pub const rootHasSamples = live_adapt.rootHasSamples;

// ---------------------------------------------------------------------------
// 测试：只测本文件自己的东西（路径规则的测试在 `live_adapt.zig`）
// ---------------------------------------------------------------------------

const testing = std.testing;

test "AlignedAllocator：分配至少 16 字节对齐，缩小后 free 仍走回 child" {
    var wrapper = AlignedAllocator{ .child = testing.allocator };
    const allocator = wrapper.allocator();

    var blocks: [16][]u8 = undefined;
    for (&blocks, 0..) |*block, i| {
        block.* = try allocator.alloc(u8, 1 + i * 37);
        try testing.expectEqual(@as(usize, 0), @intFromPtr(block.ptr) % AlignedAllocator.min_align);
    }
    for (&blocks) |*block| allocator.free(block.*);

    // 缩小后按新长度 free：header 里记的是原始长度，不会错配。
    const block = try allocator.alloc(u8, 100);
    try testing.expect(allocator.resize(block, 10));
    allocator.free(block[0..10]);

    // testing.allocator 在测试结束时会检查泄漏与重复释放。
}
