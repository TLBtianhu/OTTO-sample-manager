//! 目录浏览（Stage 0）：把一个**真实目录**变成一份可滚动的行列表，全程只读。
//!
//! 三件事，分别落在三个文件里：
//!   1. **懒枚举**（`browse_source.zig`）：后台线程用 `ports/browse_dir.zig`
//!      （`FindFirstFileExW`）把目录读成 `Entry`，每 512 条发布一批；窗口先出来，
//!      行后到。目录条目上限 50000，超出置 `truncated`（**不静默丢**）。
//!   2. **事件驱动**（本文件 `poll`）：`ports/watch.zig` 的
//!      `ReadDirectoryChangesW`（**非递归**）→ 每帧一次合并应用。一次超过 500 条
//!      （或内核溢出）就改成一次全量重枚举；不做定时轮询。
//!   3. **选中项按身份跟踪**（`browse_select.zig`）：变更前记下选中行的
//!      `卷序列号 + 文件索引`（退化时用路径），变更后按身份找回它；文件被删掉时
//!      那一行留成墓碑（`deleted`），选中项移到相邻的存活行。
//!
//! 只读纪律：本文件没有任何写调用——不建文件、不写库、不写缩略图到源目录。唯一的
//! 文件系统操作是"列目录 / stat / 打开句柄问身份"。
//!
//! 与库模式的关系：浏览模式**不打开、不创建任何库文件**；它只是另一种行来源。
//! 选择、搜索、预览、缩略图都不认识"库"或"目录"，它们只认 `core.model.Sample`。

const std = @import("std");
const core = @import("otto_core");
const selection_mod = @import("selection.zig");
const watch = @import("otto_watch");
const source_mod = @import("browse_source.zig");
const select_mod = @import("browse_select.zig");
const browse_target = @import("browse_target.zig");
const types = @import("browse_types.zig");

const Entry = types.Entry;
const Batch = types.Batch;
const Status = types.Status;

pub const max_entries = types.max_entries;
pub const storm_threshold = types.storm_threshold;
pub const Report = types.Report;
pub const Info = types.Info;

/// 入口解析在 `browse_target.zig`（只碰一次 `statFile`）；这里转出给 `main` 用。
pub const Target = browse_target.Target;
pub const TargetError = browse_target.TargetError;
pub const resolveTarget = browse_target.resolve;

pub const InitError = error{
    OutOfMemory,
    InvalidPath,
    PathNotFound,
    NotDirectory,
    AccessDenied,
    Unexpected,
} || std.Thread.SpawnError;

pub const Options = struct {
    /// 起 `ReadDirectoryChangesW` 监听（探针关掉它只为测静态枚举）。
    watch: bool = true,
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// 目录绝对路径（末尾分隔符已去掉）。本对象拥有。
    root: []u8,
    /// `root` 的最后一段（显示用，指向 `root`）。
    name: []const u8,
    /// 目录不存在 / 被删掉：界面显示"路径不可用"，其余行为照常（不崩）。
    unavailable: bool = false,
    denied: bool = false,

    /// 枚举线程与批次交接（`browse_source.zig`）。
    source: *source_mod.Source,
    /// 正在枚举（已发出请求、还没拿到 done）。界面显示"正在读取目录…"。
    enumerating: bool = true,
    /// 本次枚举被截断（条目数超过上限）。
    truncated: bool = false,
    /// 本次枚举里认不出 / 读不到的条目数（不静默）。
    skipped: u32 = 0,
    /// 列出来了、但**打不开**的条目数（权限拒绝 / 被独占）：它们照旧出现在列表里
    /// （和资源管理器一致），只是拿不到身份、时长与预览。计数不静默。
    unreadable: u32 = 0,
    /// 墓碑行数（被删掉、但那一行还留着标"已删除"）。增量维护，`info()` 不扫全表。
    tombstones: usize = 0,
    /// `restart` 之后旧行还留着，等新一批到了再整体换掉（列表不闪空）。
    swapping: bool = false,

    // ---- 会话计时 ----
    started_ns: i128,
    first_page_ns: ?i128 = null,
    done_ns: ?i128 = null,

    // ---- 监听 ----
    watcher: ?*watch.Watcher = null,
    event_buffer: []watch.Event = &.{},
    events_total: u64 = 0,

    // ---- 消费侧（只有 UI 线程碰） ----
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    view_rows: std.ArrayListUnmanaged(core.model.Sample) = .empty,
    /// 合成 id 的字节（每条一段，指向这里；`view_rows` 每轮重建）。
    ids: std.ArrayListUnmanaged(u8) = .empty,
    /// 选中项的身份跟踪（`browse_select.zig`）。
    tracker: select_mod.Tracker,
    /// 全量重枚举之前记下的选中项：等新行到了再按身份找回。
    restore_pending: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, directory: []const u8, options: Options) InitError!*Session {
        const trimmed = types.trimTrailingSeparators(directory);
        if (trimmed.len == 0) return error.InvalidPath;
        const absolute = types.realPathAlloc(allocator, io, trimmed) catch |err| return mapInitError(err);
        errdefer allocator.free(absolute);
        // 入口是文件 / 盘符不存在：在**建会话之前**就说清楚（不要等到枚举才报
        // "路径不可用"——那会让 `--browse <文件>` 看起来像一次成功的空目录）。
        const stat = std.Io.Dir.cwd().statFile(io, absolute, .{}) catch |err| return mapInitError(err);
        if (stat.kind != .directory) return error.NotDirectory;

        const self = try allocator.create(Session);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .root = absolute,
            // 盘根（`C:\`）没有最后一段：退回完整路径，别在状态条上显示空名字。
            .name = if (core.model.baseName(absolute).len > 0) core.model.baseName(absolute) else absolute,
            .source = undefined,
            .started_ns = types.nowNs(io),
            .tracker = select_mod.Tracker.init(allocator),
        };
        errdefer self.tracker.deinit();

        // 监听先于枚举：枚举期间的新文件也要能看到（RDCW 的读取窗口越小越好）。
        // 非递归是**要求**：浏览模式只列当前这一层。
        if (options.watch) self.watcher = openWatcher(allocator, absolute);
        errdefer if (self.watcher) |watcher| {
            watcher.deinit();
            allocator.destroy(watcher);
        };

        self.event_buffer = try allocator.alloc(watch.Event, storm_threshold + 1);
        errdefer allocator.free(self.event_buffer);

        self.source = try source_mod.Source.init(allocator, io, absolute);
        errdefer self.source.deinit();
        return self;
    }

    /// 停线程、停监听、释放全部行与字符串。
    pub fn deinit(self: *Session) void {
        self.source.deinit();
        if (self.watcher) |watcher| {
            watcher.deinit();
            self.allocator.destroy(watcher);
            self.watcher = null;
        }
        self.clearEntries();
        self.entries.deinit(self.allocator);
        self.view_rows.deinit(self.allocator);
        self.ids.deinit(self.allocator);
        self.tracker.deinit();
        if (self.event_buffer.len > 0) self.allocator.free(self.event_buffer);
        self.allocator.free(self.root);
        self.allocator.destroy(self);
    }

    /// 当前视图（只读）。下次 `poll` 可能让它搬家，别长期持有。
    pub fn samples(self: *const Session) []const core.model.Sample {
        return self.view_rows.items;
    }

    pub fn isDeleted(self: *const Session, index: usize) bool {
        if (index >= self.entries.items.len) return false;
        return self.entries.items[index].deleted;
    }

    pub fn rootName(self: *const Session) []const u8 {
        return self.name;
    }

    pub fn rootPath(self: *const Session) []const u8 {
        return self.root;
    }

    pub fn info(self: *const Session) Info {
        return .{
            .root = self.root,
            .name = self.name,
            .entries = self.entries.items.len,
            .truncated = self.truncated,
            .enumerating = self.enumerating,
            .unavailable = self.unavailable,
            .denied = self.denied,
            .skipped = self.skipped,
            .unreadable = self.unreadable,
            .first_page_ms = if (self.first_page_ns) |ns| types.nsToMs(ns - self.started_ns) else 0,
            .enum_ms = if (self.done_ns) |ns| types.nsToMs(ns - self.started_ns) else 0,
            .events = self.events_total,
            .tombstones = self.tombstones,
        };
    }

    /// 按文件名（含扩展名，大小写不敏感）找行号。`--browse-select` 与探针用。
    pub fn indexOfName(self: *const Session, wanted: []const u8) ?usize {
        for (self.entries.items, 0..) |entry, index| {
            if (std.ascii.eqlIgnoreCase(core.model.baseName(entry.path), wanted)) return index;
        }
        return null;
    }

    /// 一行现在有没有身份（取过就是缓存的值；没取过返回 null）。
    pub fn identityOfIndex(self: *const Session, index: usize) ?core.model.FileIdentity {
        if (index >= self.entries.items.len) return null;
        return self.entries.items[index].identity;
    }

    /// 基准用：同步跑完第一轮枚举（`--bench-scroll` 自己泵消息时不跑 `tick`，
    /// 行不会自己到视图里）。只搬行，不计时；超时也继续——基准会如实报 0 行。
    pub fn prime(self: *Session, selection: ?*selection_mod.Selection, timeout_s: f64) void {
        const deadline = types.nowNs(self.io) + @as(i128, @intFromFloat(timeout_s * 1_000_000_000.0));
        while (self.enumerating and types.nowNs(self.io) < deadline) {
            _ = self.poll(selection) catch return;
            std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
        }
        if (selection) |sel| sel.resize(self.allocator, self.view_rows.items.len) catch {};
    }

    /// 一帧的全部工作：先把到达的行搬进来，再把监听事件合并应用。
    ///
    /// `selection` 不为 null 时，变更前后按身份/路径把选中项找回来（见
    /// `browse_select.Tracker`）。返回的账给 UI 决定要不要重画。
    pub fn poll(self: *Session, selection: ?*selection_mod.Selection) error{OutOfMemory}!Report {
        var report = Report{};

        // 1. 改动之前记下选中项的身份：行号马上就会整体移动。
        //    重枚举窗口里不重记：旧身份要留到新行到了才用得上。
        if (selection) |sel| {
            if (!self.swapping and !self.restore_pending) {
                try self.tracker.capture(self.io, self.entries.items, sel, &self.unreadable);
            }
        }

        // 2. 枚举线程发布的批次。
        if (try self.pumpBatches()) report.changed = true;

        // 3. 监听事件（一次取一批；取满 = 风暴）。
        if (self.watcher) |watcher| {
            const n = watcher.poll(self.event_buffer);
            report.events = n;
            self.events_total += n;
            if (n == self.event_buffer.len) {
                // 一帧超过阈值：剩下的直接排空丢弃，改成一次全量重枚举。
                while (watcher.poll(self.event_buffer) != 0) {}
                self.startRescan();
                report.rescanned = true;
                report.changed = true;
            } else if (n > 0) {
                var overflow = false;
                for (self.event_buffer[0..n]) |event| {
                    if (event.kind == .overflow) {
                        overflow = true;
                        continue;
                    }
                    if (try self.applyEvent(event, &report)) report.changed = true;
                }
                // 内核缓冲区溢出：和风暴同一条路（全量重枚举）。
                if (overflow) {
                    self.startRescan();
                    report.rescanned = true;
                    report.changed = true;
                }
                self.checkRoot();
            }
            // 监听线程自己报了错（例如目录被删掉）：只触发一次存在性检查，不轮询。
            if (watcher.lastError() != 0) self.checkRoot();
        } else {
            // 没有监听（权限 / 目录刚被删）：只能靠存在性检查发现"路径不可用"。
            // 这不是"定时轮询变化"——没有监听时本来就没有变化可听。
            self.checkRoot();
        }

        // 4. 行变了：重建样本视图，再把选中项按身份放回去。
        if (report.changed) try self.rebuildSamples();
        if (selection) |sel| {
            // 换行的窗口里不 restore：等新行到齐（swapping 结束）再按身份找回。
            if (!self.swapping and (report.changed or self.restore_pending)) {
                try self.tracker.restore(self.entries.items, sel);
                self.restore_pending = false;
                self.tracker.reset();
            }
        }
        return report;
    }

    // -----------------------------------------------------------------------
    // 枚举批次：消费侧
    // -----------------------------------------------------------------------

    /// 搬走队列里的全部批次。返回行列表是否变了。
    fn pumpBatches(self: *Session) error{OutOfMemory}!bool {
        var local = self.source.takeBatches();
        defer self.source.releaseList(&local);

        var changed = false;
        const current = self.source.currentEpoch();
        for (local.items) |node| {
            defer self.source.releaseBatch(node);
            if (node.epoch != current) {
                // 过期代次的批次：连条目的 path 一起丢掉。
                types.freeEntries(self.allocator, node.items);
                continue;
            }
            if (node.done) {
                self.enumerating = false;
                self.swapping = false;
                self.truncated = node.truncated;
                self.skipped = node.skipped;
                self.done_ns = types.nowNs(self.io);
                switch (node.status) {
                    .ok => {
                        self.unavailable = false;
                        self.denied = false;
                    },
                    .path_unavailable => self.unavailable = true,
                    .denied => self.denied = true,
                    .failed => self.unavailable = true,
                }
                changed = true;
                continue;
            }
            if (node.items.len == 0) continue;

            // 重枚举的第一批到了：这一刻才整体换掉旧行（列表不闪空）。
            if (self.swapping) {
                self.clearEntries();
                self.swapping = false;
            }
            try self.entries.ensureUnusedCapacity(self.allocator, node.items.len);
            for (node.items) |entry| self.entries.appendAssumeCapacity(entry);
            if (self.first_page_ns == null and self.entries.items.len > 0) {
                self.first_page_ns = types.nowNs(self.io);
            }
            changed = true;
        }
        return changed;
    }

    /// 目录风暴 / 内核溢出：代次 +1、让枚举线程重来，旧行等新批次到了再换。
    fn startRescan(self: *Session) void {
        self.swapping = true;
        self.enumerating = true;
        self.truncated = false;
        self.skipped = 0;
        self.restore_pending = self.tracker.state.keys.items.len > 0;
        self.source.request();
    }

    // -----------------------------------------------------------------------
    // 监听事件：合并应用
    // -----------------------------------------------------------------------

    /// 应用一条事件。返回 entries 是否变了。
    ///
    /// 非递归监听只报直接子项；带分隔符的相对路径（子目录里的东西）直接忽略——
    /// 那是 Stage 1 的目录导航该关心的事。
    fn applyEvent(self: *Session, event: watch.Event, report: *Report) error{OutOfMemory}!bool {
        const relative = event.path.slice();
        if (relative.len == 0 or types.hasSeparator(relative)) return false;

        switch (event.kind) {
            .created => return self.eventCreated(relative, report),
            .removed => return self.eventRemoved(relative, report),
            .modified => return self.eventModified(relative, report),
            .renamed => {
                const old_relative = event.old_path.slice();
                if (old_relative.len == 0 or types.hasSeparator(old_relative)) return false;
                return self.eventRenamed(old_relative, relative, report);
            },
            .overflow => return false,
        }
    }

    fn eventCreated(self: *Session, relative: []const u8, report: *Report) error{OutOfMemory}!bool {
        const full = try types.joinPath(self.allocator, self.root, relative);

        if (self.indexOfPath(full)) |index| {
            // 重复事件（枚举期间已经收过这条）：只刷新大小/时间。
            self.allocator.free(full);
            return self.refreshStat(index);
        }

        // 新条目：stat 一次决定它是文件还是目录（监听也会报子目录创建）。
        const stat = std.Io.Dir.cwd().statFile(self.io, full, .{}) catch {
            self.allocator.free(full);
            self.skipped +|= 1;
            return false;
        };
        if (stat.kind == .directory) {
            self.allocator.free(full);
            return false;
        }

        errdefer self.allocator.free(full);
        try self.entries.append(self.allocator, .{
            .path = full,
            .size = stat.size,
            .mtime = types.mtimeMs(stat),
        });
        report.added += 1;
        return true;
    }

    fn eventRemoved(self: *Session, relative: []const u8, report: *Report) error{OutOfMemory}!bool {
        const full = try types.joinPath(self.allocator, self.root, relative);
        defer self.allocator.free(full);

        const index = self.indexOfPath(full) orelse return false;
        // 选中/光标那一行被删：留成墓碑（"已删除"），选中项由 `restore` 移到相邻行。
        if (self.tracker.state.tracked_index) |tracked| {
            if (tracked == index) {
                if (!self.entries.items[index].deleted) {
                    self.entries.items[index].deleted = true;
                    self.tracker.state.tombstone_index = index;
                    self.tombstones += 1;
                    report.removed += 1;
                }
                return true;
            }
            if (index < tracked) {
                self.tracker.state.tracked_index = tracked - 1;
                if (self.tracker.state.tombstone_index) |tomb| {
                    if (index < tomb) self.tracker.state.tombstone_index = tomb - 1;
                }
            }
        }
        self.removeAt(index);
        report.removed += 1;
        return true;
    }

    fn eventModified(self: *Session, relative: []const u8, report: *Report) error{OutOfMemory}!bool {
        const full = try types.joinPath(self.allocator, self.root, relative);
        defer self.allocator.free(full);

        const index = self.indexOfPath(full) orelse return false;
        if (!self.refreshStat(index)) return false;
        report.modified += 1;
        return true;
    }

    fn eventRenamed(self: *Session, old_relative: []const u8, new_relative: []const u8, report: *Report) error{OutOfMemory}!bool {
        const old_full = try types.joinPath(self.allocator, self.root, old_relative);
        defer self.allocator.free(old_full);

        const index = self.indexOfPath(old_full) orelse {
            // 旧路径没在视图里（枚举前就改了名）：按新文件处理。
            return self.eventCreated(new_relative, report);
        };
        if (self.entries.items[index].deleted) return false;

        const new_full = try types.joinPath(self.allocator, self.root, new_relative);
        const entry = &self.entries.items[index];
        const stat = std.Io.Dir.cwd().statFile(self.io, new_full, .{}) catch {
            // 新名字已经不可读（又被删了）：这一行按删除处理。
            self.allocator.free(new_full);
            self.removeAt(index);
            report.removed += 1;
            return true;
        };
        if (stat.kind == .directory) {
            // 改成一个目录了：这一行不再是文件。
            self.allocator.free(new_full);
            self.removeAt(index);
            report.removed += 1;
            return true;
        }
        self.allocator.free(entry.path);
        entry.path = new_full;
        entry.size = stat.size;
        entry.mtime = types.mtimeMs(stat);
        report.renamed += 1;
        return true;
    }

    /// 重新 stat 一行并刷新 size/mtime；返回值是否真的变了。
    fn refreshStat(self: *Session, index: usize) bool {
        const entry = &self.entries.items[index];
        const stat = std.Io.Dir.cwd().statFile(self.io, entry.path, .{}) catch return false;
        if (stat.kind == .directory) return false;
        const mtime = types.mtimeMs(stat);
        const changed = entry.size != stat.size or entry.mtime != mtime;
        entry.size = stat.size;
        entry.mtime = mtime;
        return changed;
    }

    /// 目录还在吗？只在"有事件 / 监听没起来 / 监听报错"时问一次，不做定时轮询。
    fn checkRoot(self: *Session) void {
        if (self.unavailable) return;
        const stat = std.Io.Dir.cwd().statFile(self.io, self.root, .{}) catch {
            self.unavailable = true;
            return;
        };
        if (stat.kind != .directory) self.unavailable = true;
    }

    // -----------------------------------------------------------------------
    // 行维护
    // -----------------------------------------------------------------------

    fn clearEntries(self: *Session) void {
        for (self.entries.items) |entry| self.allocator.free(entry.path);
        self.entries.clearRetainingCapacity();
        self.view_rows.clearRetainingCapacity();
        self.ids.clearRetainingCapacity();
        self.tombstones = 0;
    }

    fn removeAt(self: *Session, index: usize) void {
        const entry = self.entries.orderedRemove(index);
        if (entry.deleted) self.tombstones -|= 1;
        self.allocator.free(entry.path);
    }

    fn indexOfPath(self: *const Session, path: []const u8) ?usize {
        for (self.entries.items, 0..) |entry, index| {
            if (std.mem.eql(u8, entry.path, path)) return index;
        }
        return null;
    }

    /// 把 `entries` 投影成 `core.model.Sample`（UI / 选择 / 预览只认这个）。
    ///
    /// id 是合成的（`b<下标>`），不写任何地方；缩略图缓存键用的是 `stableKey()`
    /// （身份或 路径+大小+mtime），与 id 无关。
    fn rebuildSamples(self: *Session) error{OutOfMemory}!void {
        const count = self.entries.items.len;
        try self.view_rows.resize(self.allocator, count);
        try self.ids.resize(self.allocator, count * types.id_stride);

        for (self.entries.items, 0..) |entry, index| {
            const text = self.ids.items[index * types.id_stride ..][0..types.id_stride];
            const id = std.fmt.bufPrint(text, "b{d}", .{index}) catch unreachable;
            self.view_rows.items[index] = .{
                .id = id,
                .file_name = core.model.fileNameFromPath(entry.path),
                .file_ext = core.model.fileExtFromPath(entry.path),
                .file_path = entry.path,
                .original_id = id,
                .file_size = entry.size,
                .mtime = entry.mtime,
                .identity = entry.identity,
                // 时长/采样率/声道等行被画到时由 `duration_trust` 现读文件头；
                // 浏览模式不写库，所以没有"导入时补元数据"那一步。
                .pending_metadata = true,
            };
        }
    }
};

/// 监听器在堆上（`start()` 之后对象不能移动）；起不来返回 null——静态列表照样能看。
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

fn mapInitError(err: anyerror) InitError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.FileNotFound => error.PathNotFound,
        error.NotDir => error.NotDirectory,
        error.AccessDenied => error.AccessDenied,
        error.InvalidUtf8, error.NameTooLong => error.InvalidPath,
        else => error.Unexpected,
    };
}
