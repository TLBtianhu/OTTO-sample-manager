//! `zig/ports` 的文件监听 → `zig/core` 的 `Index`：唯一同时认识两边的适配层。
//!
//! 分工（CHARTER「八、零转义的边界」）：
//!   * `zig/ports` 只认路径字节（相对被监视目录的 WTF-8），不认识样本、id、分组；
//!   * `zig/core` 只认 `Change` 里的绝对路径，不碰文件系统、不碰 Win32；
//!   * 本文件是两者之间唯一的翻译：相对 → 绝对、kind → `Change` 变体、
//!     `overflow.lost` → `Change.overflow`；
//!   * `Change.overflow` 不逐条补课：标脏后交给 `rescan_ui.Rescan`，500 ms 防抖
//!     后在后台线程重扫 watch root，再按 L0 差分增删改当前视图。
//!
//! 边界：
//!   * 不依赖 UI：`Live` 可以被人眼背后的定时器驱动，也可以被 `--demo` 直接驱动；
//!   * 只做适配、不替 `Index` 做决定：`renamed` 找不到 `from` 时怎么处理是
//!     `index.zig` 的语义（降级成 `created`，计入 `added`），这里不重复实现。
//!
//! 路径适配规则（`adapt`）：
//!   * ports 的路径是**相对 root** 的 WTF-8；`std.fs.path.join` 拼成绝对路径，
//!     Windows 下用 `\` 连接，分隔符重复由 join 自己折叠；
//!   * `renamed` 的 `from` / `to` 都要 join；`to` 为空的事件直接丢弃
//!     （`Index.applyRenamed` 对空 `to` 也是忽略），`from` 为空时原样交给
//!     `Index` 处理（它会按 `created` 收下新路径）；
//!   * `overflow` 没有路径，`lost` 原样透传；空路径的路径事件丢弃。
//!
//! 线程模型：`ports.Watcher` 的后台线程只往固定队列里写；`poll()` 在调用方线程
//! 排空队列 → 适配 → `Index.apply` / `Rescan.service`。重扫的扫描线程只把
//! `scan.Scan` 放进自旋锁保护的单格结果里；`Index` 仍然只在调用方线程上改。
//!
//! 所有权：
//!   * `Index` 借用 `library`（不复制），`library` 必须比 `Live` 活得久；
//!   * `poll()` 里 join 出来的路径放在每次 poll 重置的 arena 里，只活到本批
//!     `Index.apply` 返回——`Index` 会把它要长期持有的路径自己复制一份；
//!   * `root` 由 `Live` 复制持有，调用方传进来的切片之后可以失效；
//!   * `rescan_ui.Rescan` 借用 `root`；`Live.deinit` 先停 watcher，再 join 扫描
//!     线程，最后才释放字符串——扫描线程不会读到悬空路径。

const std = @import("std");
const core = @import("otto_core");
const watch = @import("otto_watch");
const rescan_ui = @import("rescan_ui.zig");

/// `Live.init` 可能失败的集合：监听口岸打不开目录 / 起不了线程、根路径非法、
/// 以及任何一次分配失败。
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
    /// `FILE_NOTIFY_INFORMATION`（DWORD 字段）的自然要求，这里取 16 留余量，
    /// 顺便覆盖常见 SIMD / 原子类型。
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
    /// 监听器放在堆上：`Watcher.start()` 之后对象不能移动（后台线程持有它的指针），
    /// 而 `Live` 会按值返回。
    watcher: *watch.Watcher,
    /// 监听器各次分配走这层包装（RDCW 缓冲区必须对齐，见 `AlignedAllocator`）。
    watch_allocator: *AlignedAllocator,
    /// 每次 poll 重置：本批 join 出来的路径只活到 `Index.apply` 返回。
    poll_arena: std.heap.ArenaAllocator,
    /// 溢出后的局部重扫（500 ms 防抖 + 工作线程）。借用 `root`。
    rescan: rescan_ui.Rescan,
    last_rescan: rescan_ui.Report = .{},
    rescan_serial: u64 = 0,

    /// 建立视图并开始监听 `root`。返回时后台线程已经挂好第一轮读。
    ///
    /// `allocator` 必须线程安全：重扫线程会用它在扫描结果里分配 arena。
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        library: *const core.store.Library,
        root: []const u8,
    ) InitError!Live {
        const owned_root = try normalizeRoot(allocator, root);
        errdefer allocator.free(owned_root);

        var index = try core.index.Index.init(allocator, library);
        errdefer index.deinit();

        // 监听器的分配走对齐包装（端口拿到的 allocator 决定 RDCW 缓冲区的对齐）。
        const watch_allocator = try allocator.create(AlignedAllocator);
        errdefer allocator.destroy(watch_allocator);
        watch_allocator.* = .{ .child = allocator };
        const watcher_memory = watch_allocator.allocator();

        const watcher = try watcher_memory.create(watch.Watcher);
        errdefer watcher_memory.destroy(watcher);
        watcher.* = try watch.Watcher.init(watcher_memory, owned_root, .{});
        errdefer watcher.deinit();
        try watcher.start();

        return .{
            .allocator = allocator,
            .io = io,
            .root = owned_root,
            .index = index,
            .watcher = watcher,
            .watch_allocator = watch_allocator,
            .poll_arena = std.heap.ArenaAllocator.init(allocator),
            .rescan = rescan_ui.Rescan.init(allocator, io, owned_root),
        };
    }

    /// 停监听、释放视图与全部字符串；之后不可再用。
    pub fn deinit(self: *Live) void {
        self.watcher.deinit();
        self.rescan.deinit();
        self.watch_allocator.allocator().destroy(self.watcher);
        self.allocator.destroy(self.watch_allocator);
        self.index.deinit();
        self.poll_arena.deinit();
        self.allocator.free(self.root);
        self.* = undefined;
    }

    /// 排空 watcher → 适配成 `core.Change` → 一次性 `index.apply`。
    ///
    /// 返回的账是本批事件的合计；空批次（没事件）返回全零报告。
    /// `report.invalidated` 的生命周期与 `Index.apply` 一致：到下一次 `poll` 失效。
    pub fn poll(self: *Live) error{OutOfMemory}!core.index.ApplyReport {
        _ = self.poll_arena.reset(.retain_capacity);
        const arena = self.poll_arena.allocator();

        var changes: std.ArrayListUnmanaged(core.index.Change) = .empty;
        while (self.watcher.next()) |event| {
            if (try adapt(&event, self.root, arena)) |change| {
                try changes.append(arena, change);
            }
        }

        var report = core.index.ApplyReport{};
        var overflow_lost: u32 = 0;
        var has_overflow = false;
        for (changes.items) |change| {
            switch (change) {
                .overflow => |lost| {
                    has_overflow = true;
                    overflow_lost +|= lost;
                },
                else => {},
            }
        }

        if (has_overflow) {
            // 溢出本身只是一条「有事件丢了」的信号：先标脏并排一次重扫窗口，
            // 本批的其余事件不能先应用——重扫需要一个稳定的旧视图做基线。
            self.index.markDirty();
            self.rescan.request();
            report.overflowed = true;
            report.overflow_lost = overflow_lost;
        }

        if (has_overflow or self.rescan.active()) {
            // 重扫期间压住事件，完成后再按原顺序 replay（Index.apply 幂等）。
            // overflow 不压：它只标脏，同一批不需要再触发一轮。
            for (changes.items) |change| {
                switch (change) {
                    .overflow => {},
                    else => try self.rescan.holdChange(change),
                }
            }
        } else {
            report = try self.index.apply(changes.items);
        }

        if (try self.rescan.service(&self.index, &report)) |finished| {
            self.last_rescan = finished;
            self.rescan_serial +%= 1;
            report.rescanned = true;
            if (finished.ok) {
                report.rescan_added = finished.added;
                report.rescan_removed = finished.removed;
                report.rescan_moved = finished.moved;
                report.rescan_modified = finished.modified;
                report.rescan_unchanged = finished.unchanged;
                std.debug.print(
                    "rescan: added={d} removed={d} moved={d} modified={d} dirtied={d} " ++
                        "unchanged={d} scanned={d} replayed={d} dirty={} ms={d:.2}\n",
                    .{
                        finished.added,
                        finished.removed,
                        finished.moved,
                        finished.modified,
                        finished.dirtied,
                        finished.unchanged,
                        finished.scanned,
                        finished.replayed,
                        self.index.isDirty(),
                        finished.elapsed_ms,
                    },
                );
            } else {
                std.debug.print(
                    "rescan: failed error={s} replayed={d} dirty={} ms={d:.2}\n",
                    .{
                        finished.failure orelse "?",
                        finished.replayed,
                        self.index.isDirty(),
                        finished.elapsed_ms,
                    },
                );
            }
        }

        return report;
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
    pub fn injectOverflow(self: *Live, lost: u32) error{OutOfMemory}!void {
        _ = try self.index.apply(&.{.{ .overflow = lost }});
        self.rescan.request();
    }

    /// 不经过溢出、主动排一次重扫（`--demo-rescan` 的「再跑一次」用它）。
    pub fn requestRescan(self: *Live) void {
        self.rescan.request();
    }

    /// 重扫排队 / 进行中（UI 可以据此决定是否显示「正在重扫」）。
    pub fn rescanActive(self: *const Live) bool {
        return self.rescan.active();
    }

    /// 已完成的重扫次数；每完成一次 +1（成功和失败都算，用来等结果）。
    pub fn rescanSerial(self: *const Live) u64 {
        return self.rescan_serial;
    }

    /// 最近一次完成的重扫的账。
    pub fn lastRescan(self: *const Live) rescan_ui.Report {
        return self.last_rescan;
    }
};

/// 把一条监听事件适配成 core 的变更；返回 null = 这条事件没有可应用的路径。
///
/// 分配出来的路径归 `allocator` 所有（`Live.poll` 传的是 per-poll arena）；
/// 不做任何释放，也不读取磁盘——纯字符串适配，可以用合成事件直接测试。
pub fn adapt(
    event: *const watch.Event,
    root: []const u8,
    allocator: std.mem.Allocator,
) error{OutOfMemory}!?core.index.Change {
    switch (event.kind) {
        .created => {
            const path = (try joinRelative(allocator, root, event.path.slice())) orelse return null;
            return .{ .created = path };
        },
        .removed => {
            const path = (try joinRelative(allocator, root, event.path.slice())) orelse return null;
            return .{ .removed = path };
        },
        .modified => {
            const path = (try joinRelative(allocator, root, event.path.slice())) orelse return null;
            // 口岸只知道「变了」，拿不到新的 mtime：交给 Index 保留旧值。
            return .{ .modified = .{ .path = path, .mtime = null } };
        },
        .renamed => {
            const to = (try joinRelative(allocator, root, event.path.slice())) orelse return null;
            if (event.old_path.len == 0) {
                // 只有新名（旧名不可知）：保持 from 为空，让 Index 按 created 收下。
                return .{ .renamed = .{ .from = "", .to = to } };
            }
            errdefer allocator.free(to);
            const from = try std.fs.path.join(allocator, &.{ root, event.old_path.slice() });
            return .{ .renamed = .{ .from = from, .to = to } };
        },
        .overflow => return .{ .overflow = event.lost },
    }
}

/// 把相对路径 join 到 root 上；空相对路径返回 null（没有可定位的样本）。
fn joinRelative(
    allocator: std.mem.Allocator,
    root: []const u8,
    relative: []const u8,
) error{OutOfMemory}!?[]const u8 {
    if (relative.len == 0) return null;
    return try std.fs.path.join(allocator, &.{ root, relative });
}

/// 复制 root 并去掉末尾分隔符：`C:\packs\` 与 `C:\packs` 对 `join` 等价，
/// 但存一份统一的字符串便于比较与打印。盘根（`C:\`）的分隔符要保留，
/// 否则 `C:` 会变成「C 盘当前目录」。
fn normalizeRoot(allocator: std.mem.Allocator, root: []const u8) error{ OutOfMemory, InvalidRoot }![]u8 {
    var end = root.len;
    while (end > 1 and std.fs.path.isSep(root[end - 1])) {
        if (end == 3 and root[1] == ':') break;
        end -= 1;
    }
    if (end == 0) return error.InvalidRoot;
    return allocator.dupe(u8, root[0..end]);
}

// ---------------------------------------------------------------------------
// 测试：合成 Event 直接调适配函数，不依赖真实文件系统
// ---------------------------------------------------------------------------

const testing = std.testing;

fn syntheticEvent(kind: watch.Kind, path: []const u8, old_path: []const u8) watch.Event {
    std.debug.assert(path.len <= watch.max_path_bytes);
    std.debug.assert(old_path.len <= watch.max_path_bytes);
    var event = watch.Event{ .kind = kind };
    @memcpy(event.path.bytes[0..path.len], path);
    event.path.len = @intCast(path.len);
    @memcpy(event.old_path.bytes[0..old_path.len], old_path);
    event.old_path.len = @intCast(old_path.len);
    return event;
}

/// 断言 actual 确实是 `join(root, relative)`：不仅内容对，而且没把相对路径
/// 原样递出去、也没把 root 弄丢。
fn expectJoined(actual: []const u8, root: []const u8, relative: []const u8) !void {
    const expected = try std.fs.path.join(testing.allocator, &.{ root, relative });
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, actual);
    try testing.expect(!std.mem.eql(u8, actual, relative));
    try testing.expect(std.mem.startsWith(u8, actual, root));
    try testing.expect(std.mem.endsWith(u8, actual, relative));
}

test "created / removed / modified：相对路径 join 到 root" {
    const root = "C:\\Library";

    var created = syntheticEvent(.created, "Drums\\Kick 01.wav", "");
    const created_change = try adapt(&created, root, testing.allocator) orelse return error.ExpectedChange;
    switch (created_change) {
        .created => |path| {
            defer testing.allocator.free(path);
            try expectJoined(path, root, "Drums\\Kick 01.wav");
        },
        else => return error.ExpectedCreated,
    }

    var removed = syntheticEvent(.removed, "Drums\\Kick 01.wav", "");
    const removed_change = try adapt(&removed, root, testing.allocator) orelse return error.ExpectedChange;
    switch (removed_change) {
        .removed => |path| {
            defer testing.allocator.free(path);
            try expectJoined(path, root, "Drums\\Kick 01.wav");
        },
        else => return error.ExpectedRemoved,
    }

    var modified = syntheticEvent(.modified, "Pads\\Long.wav", "");
    const modified_change = try adapt(&modified, root, testing.allocator) orelse return error.ExpectedChange;
    switch (modified_change) {
        .modified => |change| {
            defer testing.allocator.free(change.path);
            try expectJoined(change.path, root, "Pads\\Long.wav");
            // 口岸不提供 mtime：不能编一个 0 出来覆盖 Index 里的旧值。
            try testing.expect(change.mtime == null);
        },
        else => return error.ExpectedModified,
    }
}

test "renamed：from 与 to 都 join 到 root" {
    const root = "C:\\Library";
    var event = syntheticEvent(.renamed, "New\\Snare.wav", "Old\\Snare.wav");
    const change = try adapt(&event, root, testing.allocator) orelse return error.ExpectedChange;
    switch (change) {
        .renamed => |rename| {
            defer testing.allocator.free(rename.from);
            defer testing.allocator.free(rename.to);
            try expectJoined(rename.from, root, "Old\\Snare.wav");
            try expectJoined(rename.to, root, "New\\Snare.wav");
        },
        else => return error.ExpectedRenamed,
    }
}

test "renamed 只有新名：from 交给 Index 降级，to 仍然 join" {
    const root = "C:\\Library";
    var event = syntheticEvent(.renamed, "New\\Snare.wav", "");
    const change = try adapt(&event, root, testing.allocator) orelse return error.ExpectedChange;
    switch (change) {
        .renamed => |rename| {
            defer testing.allocator.free(rename.to);
            try testing.expectEqualStrings("", rename.from);
            try expectJoined(rename.to, root, "New\\Snare.wav");
        },
        else => return error.ExpectedRenamed,
    }
}

test "overflow：lost 透传成 Change.overflow" {
    const root = "C:\\Library";
    var event = syntheticEvent(.overflow, "", "");
    event.lost = 7;
    const change = try adapt(&event, root, testing.allocator) orelse return error.ExpectedChange;
    switch (change) {
        .overflow => |lost| try testing.expectEqual(@as(u32, 7), lost),
        else => return error.ExpectedOverflow,
    }
}

test "空路径事件被丢弃" {
    const root = "C:\\Library";

    var empty_created = syntheticEvent(.created, "", "");
    try testing.expect((try adapt(&empty_created, root, testing.allocator)) == null);

    var empty_modified = syntheticEvent(.modified, "", "");
    try testing.expect((try adapt(&empty_modified, root, testing.allocator)) == null);

    // 改名目标为空：Index 也会忽略，这里直接不进批次。
    var empty_target = syntheticEvent(.renamed, "", "Old\\Snare.wav");
    try testing.expect((try adapt(&empty_target, root, testing.allocator)) == null);
}

test "root 末尾分隔符归一化，盘根保留" {
    const sep = std.fs.path.sep;

    const trailing = try std.fmt.allocPrint(testing.allocator, "otto-live{c}lib{c}", .{ sep, sep });
    defer testing.allocator.free(trailing);
    const normalized = try normalizeRoot(testing.allocator, trailing);
    defer testing.allocator.free(normalized);
    const expected = try std.fmt.allocPrint(testing.allocator, "otto-live{c}lib", .{sep});
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, normalized);

    try testing.expectError(error.InvalidRoot, normalizeRoot(testing.allocator, ""));

    if (std.fs.path.sep == '\\') {
        const drive = try normalizeRoot(testing.allocator, "C:\\");
        defer testing.allocator.free(drive);
        try testing.expectEqualStrings("C:\\", drive);
    }
}

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
