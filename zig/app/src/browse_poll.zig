//! 目录监听与磁盘变化合入：watcher 生命周期、事件应用、重扫及 replay 状态机。
//! `browse.Session` 只拥有目录行/路径/预算/选择/导航；本文件拥有全部 poll 协议状态。
//!
//! 每帧顺序保持为：Session 先接收枚举批次，再调用 `pump` 读取监听事件。
//! 风暴、overflow 与序号缺口都启动一次全量重扫；重扫期间不消费队列，done 后
//! replay 留下的事件。replay 中再次出现缺口只合并成一次后续重扫。监听硬错误
//! 只标记路径不可用并关闭 watcher，恢复仍由用户下一次交互显式触发。

const std = @import("std");
const browse = @import("browse.zig");
const types = @import("browse_types.zig");
const watch = @import("otto_watch");

const Entry = types.Entry;
const Phase = enum { idle, rescan, replay };

pub const State = struct {
    allocator: std.mem.Allocator,
    enabled: bool,
    watcher: ?*watch.Watcher = null,
    event_buffer: []watch.Event = &.{},
    /// 事件新增路径借用 entries 中对应 Entry.path，仅供枚举分页去重。
    event_paths: std.ArrayListUnmanaged([]const u8) = .empty,

    events_total: u64 = 0,
    /// 已观察到的最大单调事件序号；缺口表示队列或内核丢过事件。
    last_event_seq: u64 = 0,
    rescan_seq: u64 = 0,
    phase: Phase = .idle,
    /// replay 中又发现 overflow/缺口：只记一次后续重扫。
    reconcile_again: bool = false,
    rescans: u64 = 0,
    reconciles: u64 = 0,

    /// 保持原启动时机：监听先于 Source 枚举线程启动；缓冲即使关监听也保留。
    pub fn init(allocator: std.mem.Allocator, root: []const u8, enabled: bool) error{OutOfMemory}!*State {
        const self = try allocator.create(State);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .enabled = enabled };
        if (enabled) self.watcher = openWatcher(allocator, root);
        errdefer self.close();
        self.event_buffer = try allocator.alloc(watch.Event, types.storm_threshold + 1);
        return self;
    }

    pub fn deinit(self: *State) void {
        self.close();
        self.event_paths.deinit(self.allocator);
        if (self.event_buffer.len > 0) self.allocator.free(self.event_buffer);
        self.allocator.destroy(self);
    }

    pub fn close(self: *State) void {
        if (self.watcher) |watcher| {
            watcher.deinit();
            self.allocator.destroy(watcher);
            self.watcher = null;
        }
    }

    pub fn reopen(self: *State, root: []const u8) void {
        if (self.enabled) self.watcher = openWatcher(self.allocator, root);
    }

    /// 清行之前先清借用路径；本表从不拥有 Entry.path。
    pub fn clearEventPaths(self: *State) void {
        self.event_paths.clearRetainingCapacity();
    }

    /// 枚举批次遇到事件先加入的同一路径时，调用方丢弃批次里的重复 Entry。
    pub fn acceptsBatchRow(self: *const State, path: []const u8) bool {
        for (self.event_paths.items) |known| {
            if (std.mem.eql(u8, known, path)) return false;
        }
        return true;
    }

    /// 非 append 的 done 是重扫与 replay 的唯一交接点。
    pub fn batchDone(self: *State, append: bool) void {
        if (self.phase == .rescan and !append) self.phase = .replay;
    }

    /// 导航已关闭旧 watcher、切换 Source 并打开新 watcher 后调用。
    /// 新 watcher 从 seq=1 开始，旧目录事件绝不能 replay 到新目录。
    pub fn beginNavigation(self: *State) void {
        self.last_event_seq = 0;
        self.rescan_seq = 0;
        self.phase = .rescan;
        self.reconcile_again = false;
        self.rescans += 1;
    }

    /// 路径恢复后 watcher 已重开；丢弃旧重扫相位，再按原水位请求重枚举。
    pub fn resetRetry(self: *State) void {
        self.phase = .idle;
        self.reconcile_again = false;
    }
};

/// F5、显式强制重扫与交互重试共用的入口。
pub fn requestRescan(session: *browse.Session) void {
    startRescan(session, session.changes.last_event_seq);
}

/// 一帧的监听步骤：不重排 Session 的“批次 → 事件 → 排序/视图/选择”顺序。
pub fn pump(session: *browse.Session, report: *types.Report) error{OutOfMemory}!void {
    const self = session.changes;
    const watcher = self.watcher orelse {
        self.phase = .idle;
        checkRoot(session);
        return;
    };

    if (self.phase == .replay) {
        self.phase = .idle;
        try replayQueued(session, watcher, report);
        return;
    }
    // 重扫在飞时不取队列；容量导致的丢失会由 replay 的序号缺口发现。
    if (self.phase == .rescan) {
        noteWatcherHealth(session);
        return;
    }

    const n = watcher.poll(self.event_buffer);
    report.events = n;
    self.events_total += n;
    if (n == self.event_buffer.len) {
        // 一帧超过阈值：排空剩余事件，合并成一次全量重枚举。
        var last = self.event_buffer[n - 1].seq;
        while (true) {
            const more = watcher.poll(self.event_buffer);
            if (more == 0) break;
            last = self.event_buffer[more - 1].seq;
        }
        noteWatcherHealth(session);
        startRescan(session, last);
        report.rescanned = true;
        report.changed = true;
        return;
    }

    var overflow = false;
    var gap = false;
    var expected = self.last_event_seq + 1;
    for (self.event_buffer[0..n]) |event| {
        if (event.seq > expected) gap = true;
        if (event.seq > self.last_event_seq) self.last_event_seq = event.seq;
        expected = event.seq + 1;
        if (event.kind == .overflow) {
            overflow = true;
            continue;
        }
        if (try apply(session, event, report)) report.changed = true;
    }
    if (overflow or gap) {
        startRescan(session, self.last_event_seq);
        report.rescanned = true;
        report.changed = true;
    } else if (n > 0) {
        checkRoot(session);
    }
    noteWatcherHealth(session);
}

/// done 后补应用扫描窗口中的事件；任何缺口只触发一次后续重扫。
fn replayQueued(
    session: *browse.Session,
    watcher: *watch.Watcher,
    report: *types.Report,
) error{OutOfMemory}!void {
    const self = session.changes;
    var expected = self.last_event_seq + 1;
    var guard: usize = 0;
    while (true) {
        const n = watcher.poll(self.event_buffer);
        if (n == 0) break;
        report.events += n;
        self.events_total += n;
        for (self.event_buffer[0..n]) |event| {
            if (event.seq > expected) self.reconcile_again = true;
            if (event.seq > self.last_event_seq) self.last_event_seq = event.seq;
            expected = event.seq + 1;
            if (event.kind == .overflow) {
                self.reconcile_again = true;
                continue;
            }
            if (try apply(session, event, report)) report.changed = true;
            report.replayed += 1;
        }
        guard += 1;
        if (guard > 64) {
            self.reconcile_again = true;
            break;
        }
    }
    self.reconciles += 1;
    if (self.reconcile_again) {
        self.reconcile_again = false;
        startRescan(session, self.last_event_seq);
        report.rescanned = true;
        report.changed = true;
    }
    checkRoot(session);
    noteWatcherHealth(session);
}

/// 旧行保留到首批新行到达；选择身份由 Session 的 restore_pending 跨重扫保留。
fn startRescan(session: *browse.Session, last_seq: u64) void {
    const self = session.changes;
    if (self.phase == .rescan) {
        self.reconcile_again = true;
        return;
    }
    self.phase = .rescan;
    self.reconcile_again = false;
    self.rescan_seq = last_seq;
    self.last_event_seq = @max(self.last_event_seq, last_seq);
    session.swapping = true;
    session.enumerating = true;
    session.loading_more = false;
    session.truncated = false;
    session.has_more = false;
    session.skipped = 0;
    session.remaining = 0;
    session.mem_refused = false;
    session.pages = 0;
    session.restore_pending = session.tracker.state.keys.items.len > 0;
    self.rescans += 1;
    session.source.request();
}

fn noteWatcherHealth(session: *browse.Session) void {
    const self = session.changes;
    const watcher = self.watcher orelse return;
    if (watcher.lastError() == 0 or watcher.isRunning()) return;
    session.unavailable = true;
    self.close();
}

/// 只在有事件、监听未启动或监听报错时查一次；没有定时轮询。
fn checkRoot(session: *browse.Session) void {
    if (session.unavailable) return;
    const stat = std.Io.Dir.cwd().statFile(session.io, session.root, .{}) catch {
        session.unavailable = true;
        return;
    };
    if (stat.kind != .directory) session.unavailable = true;
}

fn openWatcher(allocator: std.mem.Allocator, root: []const u8) ?*watch.Watcher {
    const watcher = allocator.create(watch.Watcher) catch return null;
    watcher.* = watch.Watcher.init(allocator, root, .{
        .capacity = types.watch_capacity,
        .recursive = false,
    }) catch |err| {
        allocator.destroy(watcher);
        if (err != error.OutOfMemory) {
            std.debug.print("otto-lite: 浏览目录监听不可用（{s}），本次只显示静态列表\n", .{@errorName(err)});
        }
        return null;
    };
    watcher.start() catch |err| {
        watcher.deinit();
        allocator.destroy(watcher);
        std.debug.print("otto-lite: 浏览目录监听线程起不来（{s}）\n", .{@errorName(err)});
        return null;
    };
    return watcher;
}

// ---------------------------------------------------------------------------
// 单条事件 → 目录行。相对路径含分隔符的事件不属于本非递归监听视图。
// ---------------------------------------------------------------------------

fn apply(session: *browse.Session, event: watch.Event, report: *types.Report) error{OutOfMemory}!bool {
    const relative = event.path.slice();
    if (relative.len == 0 or types.hasSeparator(relative)) return false;

    switch (event.kind) {
        .created => return eventCreated(session, relative, report),
        .removed => return eventRemoved(session, relative, report),
        .modified => return eventModified(session, relative, report),
        .renamed => {
            const old_relative = event.old_path.slice();
            if (old_relative.len == 0 or types.hasSeparator(old_relative)) return false;
            return eventRenamed(session, old_relative, relative, report);
        },
        .overflow => return false,
    }
}

fn eventCreated(session: *browse.Session, relative: []const u8, report: *types.Report) error{OutOfMemory}!bool {
    const self = session.changes;
    const full = try session.path_store.join(session.root, relative);

    if (indexOfPath(session, full)) |index| {
        session.pathAllocator().free(full);
        return refreshStat(session, index);
    }

    const stat = std.Io.Dir.cwd().statFile(session.io, full, .{}) catch {
        session.pathAllocator().free(full);
        session.skipped +|= 1;
        return false;
    };
    if (stat.kind != .directory and stat.kind != .file) {
        session.pathAllocator().free(full);
        return false;
    }

    errdefer session.pathAllocator().free(full);
    // 两个数组先预留再追加，避免 OOM 留下无主的 Entry。
    try self.event_paths.ensureUnusedCapacity(session.allocator, 1);
    try session.entries.append(session.allocator, .{
        .path = full,
        .size = stat.size,
        .mtime = types.mtimeMs(stat),
        .is_directory = stat.kind == .directory,
    });
    self.event_paths.appendAssumeCapacity(session.entries.items[session.entries.items.len - 1].path);
    session.needs_sort = true;
    report.added += 1;
    return true;
}

fn eventRemoved(session: *browse.Session, relative: []const u8, report: *types.Report) error{OutOfMemory}!bool {
    const full = try session.path_store.join(session.root, relative);
    defer session.pathAllocator().free(full);

    const index = indexOfPath(session, full) orelse return false;
    if (session.tracker.state.tracked_index) |tracked| {
        if (tracked == index) {
            if (!session.entries.items[index].deleted) {
                session.entries.items[index].deleted = true;
                session.tracker.state.tombstone_index = index;
                session.tombstones += 1;
                report.removed += 1;
            }
            return true;
        }
        if (index < tracked) {
            session.tracker.state.tracked_index = tracked - 1;
            if (session.tracker.state.tombstone_index) |tomb| {
                if (index < tomb) session.tracker.state.tombstone_index = tomb - 1;
            }
        }
    }
    removeAt(session, index);
    report.removed += 1;
    return true;
}

fn eventModified(session: *browse.Session, relative: []const u8, report: *types.Report) error{OutOfMemory}!bool {
    const full = try session.path_store.join(session.root, relative);
    defer session.pathAllocator().free(full);

    const index = indexOfPath(session, full) orelse return false;
    if (!refreshStat(session, index)) return false;
    report.modified += 1;
    return true;
}

fn eventRenamed(
    session: *browse.Session,
    old_relative: []const u8,
    new_relative: []const u8,
    report: *types.Report,
) error{OutOfMemory}!bool {
    const old_full = try session.path_store.join(session.root, old_relative);
    defer session.pathAllocator().free(old_full);

    const index = indexOfPath(session, old_full) orelse {
        return eventCreated(session, new_relative, report);
    };
    if (session.entries.items[index].deleted) return false;

    const new_full = try session.path_store.join(session.root, new_relative);
    const entry = &session.entries.items[index];
    const stat = std.Io.Dir.cwd().statFile(session.io, new_full, .{}) catch {
        session.pathAllocator().free(new_full);
        removeAt(session, index);
        report.removed += 1;
        return true;
    };
    if (stat.kind != .directory and stat.kind != .file) {
        session.pathAllocator().free(new_full);
        removeAt(session, index);
        report.removed += 1;
        return true;
    }
    const was_event_row = forgetEventPath(session, entry.path);
    if (was_event_row) try session.changes.event_paths.ensureUnusedCapacity(session.allocator, 1);
    session.pathAllocator().free(entry.path);
    entry.path = new_full;
    entry.size = stat.size;
    entry.mtime = types.mtimeMs(stat);
    entry.is_directory = stat.kind == .directory;
    if (was_event_row) session.changes.event_paths.appendAssumeCapacity(entry.path);
    session.needs_sort = true;
    report.renamed += 1;
    return true;
}

fn refreshStat(session: *browse.Session, index: usize) bool {
    const entry = &session.entries.items[index];
    const stat = std.Io.Dir.cwd().statFile(session.io, entry.path, .{}) catch return false;
    if (stat.kind != .directory and stat.kind != .file) return false;
    const mtime = types.mtimeMs(stat);
    const changed = entry.size != stat.size or entry.mtime != mtime or
        entry.is_directory != (stat.kind == .directory);
    entry.size = stat.size;
    entry.mtime = mtime;
    entry.is_directory = stat.kind == .directory;
    if (changed) session.needs_sort = true;
    return changed;
}

fn indexOfPath(session: *const browse.Session, path: []const u8) ?usize {
    for (session.entries.items, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.path, path)) return index;
    }
    return null;
}

fn removeAt(session: *browse.Session, index: usize) void {
    const entry = session.entries.orderedRemove(index);
    if (entry.deleted) session.tombstones -|= 1;
    _ = forgetEventPath(session, entry.path);
    session.pathAllocator().free(entry.path);
}

fn forgetEventPath(session: *browse.Session, path: []const u8) bool {
    const self = session.changes;
    for (self.event_paths.items, 0..) |known, index| {
        if (std.mem.eql(u8, known, path)) {
            _ = self.event_paths.swapRemove(index);
            return true;
        }
    }
    return false;
}
