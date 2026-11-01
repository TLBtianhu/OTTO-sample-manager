//! 目录浏览（Stage 0）：把一个**真实目录**变成一份可滚动的行列表，全程只读。
//!
//! 四件事，分别落在四个文件里：
//!   1. **懒枚举 + 分页**（`browse_source.zig`）：后台线程用 `ports/browse_dir.zig`
//!      （`FindFirstFileExW`）把目录读成 `Entry`，每 512 条发布一批；一页读满就
//!      **保留枚举句柄**，下一页接着 `FindNextFileW` 读，不从目录头重扫。窗口先
//!      出来，行后到。页大小 = `--browse-limit`（默认 50000，总硬上限 200000）。
//!   2. **内存预算**（`browse_budget.zig`）：实测每行字节数；「加载更多」之前按
//!      "当前工作集 + 预计新增行"判断 90 MiB 峰值，超了就拒绝并数清剩余条数
//!      （状态条写「已到内存上限，剩余 N 条未加载」——**不静默停**）。
//!   3. **事件驱动**（`browse_events.zig` + 本文件 `poll`）：`ports/watch.zig` 的
//!      `ReadDirectoryChangesW`（**非递归**）→ 每帧一次合并应用。一次超过 500 条
//!      （或内核溢出 / 序号缺口）就改成一次全量重枚举；重扫期间**不消费**事件，
//!      重扫完成后按单调序号把扫描开始之后的事件补应用一遍（reconcile-after-rescan），
//!      期间再来 overflow 只合并成一次重扫。不做定时轮询。
//!   4. **选中项按身份跟踪**（`browse_select.zig`）：变更前记下选中行的
//!      `卷序列号 + 文件索引`（退化时用路径），变更后按身份找回它；文件被删掉时
//!      那一行留成墓碑（`deleted`），选中项移到相邻的存活行。
//!
//! 路径不可用（目录被删 / U 盘拔出）时监听线程会硬退出：界面保持「路径不可用」，
//! **只在用户下一次交互时**（点击 / 滚动 / 键盘 / 获得焦点）重试一次——不是定时轮询。
//!
//! 只读纪律：本文件没有任何写调用——不建文件、不写库、不写缩略图到源目录。唯一的
//! 文件系统操作是"列目录 / stat / 打开句柄问身份"。

const std = @import("std");
const core = @import("otto_core");
const selection_mod = @import("selection.zig");
const watch = @import("otto_watch");
const source_mod = @import("browse_source.zig");
const select_mod = @import("browse_select.zig");
const reconcile_mod = @import("browse_reconcile.zig");
const budget_mod = @import("browse_budget.zig");
const bench_win = @import("bench_win.zig");
const browse_target = @import("browse_target.zig");
const types = @import("browse_types.zig");
const sort_mod = @import("browse_sort.zig");
const history_mod = @import("browse_history.zig");
const navigation = @import("browse_navigation.zig");
const view = @import("browse_view.zig");

const Entry = types.Entry;
const Batch = types.Batch;
pub const Report = types.Report;
pub const Info = types.Info;
pub const SortKey = sort_mod.Key;
pub const NavigationError = navigation.Error;

pub const max_entries = types.default_limit;
pub const hard_limit = types.hard_limit;
pub const storm_threshold = types.storm_threshold;

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
    /// 页大小（`--browse-limit`）：首批与每次「加载更多」最多读多少条。
    limit: usize = types.default_limit,
    /// 内存预算；默认 90 MiB。测试注入更小的值来走"拒绝加载"那条路。
    memory_budget_bytes: usize = types.memory_budget_bytes,
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// 目录绝对路径（末尾分隔符已去掉）。本对象拥有。
    root: []u8,
    /// `root` 的最后一段（显示用，指向 `root`）。
    name: []const u8,
    /// 目录不存在 / 被删掉 / 监听硬退出：界面显示"路径不可用"，其余行为照常（不崩）。
    unavailable: bool = false,
    denied: bool = false,
    /// 这次会话允许"加载更多"到多少条（总硬上限 200000）。
    limit: usize,
    watch_enabled: bool,

    /// 枚举线程与批次交接（`browse_source.zig`）。
    source: *source_mod.Source,
    /// 正在枚举（已发出请求、还没拿到 done）。界面显示"正在读取目录…"。
    enumerating: bool = true,
    /// 正在加载下一页（与 `enumerating` 的区别只在状态条文案）。
    loading_more: bool = false,
    /// 本页之后还有没加载的行（可以「加载更多」）。
    has_more: bool = false,
    /// 本页读满、枚举器没到末尾（含硬上限）：状态条必须写出来。
    truncated: bool = false,
    /// 内存预算拒绝了下一页；`remaining` 是之后数出来的剩余条数。
    mem_refused: bool = false,
    remaining: usize = 0,
    /// 本次枚举里认不出 / 读不到的条目数（不静默）。
    skipped: u32 = 0,
    /// 列出来了、但**打不开**的条目数（权限拒绝 / 被独占）：它们照旧出现在列表里
    /// （和资源管理器一致），只是拿不到身份、时长与预览。计数不静默。
    unreadable: u32 = 0,
    /// 墓碑行数（被删掉、但那一行还留着标"已删除"）。增量维护，`info()` 不扫全表。
    tombstones: usize = 0,
    /// `restart` 之后旧行还留着，等新一批到了再整体换掉（列表不闪空）。
    swapping: bool = false,
    /// 已经加载的页数（含首批；`--pages` 探针用它验收）。
    pages: u32 = 0,
    /// 重扫次数 / reconcile 补事件次数（探针用，不参与 UI）。
    rescans: u64 = 0,
    reconciles: u64 = 0,

    // ---- 会话计时 ----
    started_ns: i128,
    first_page_ns: ?i128 = null,
    done_ns: ?i128 = null,

    // ---- 监听 ----
    watcher: ?*watch.Watcher = null,
    event_buffer: []watch.Event = &.{},
    events_total: u64 = 0,
    /// 已应用/已观察到的最大事件序号（监听队列的单调序号，缺口 = 丢失）。
    last_event_seq: u64 = 0,
    /// 本次重扫请求时的序号水位：> 它的事件要在重扫完成后补应用。
    rescan_seq: u64 = 0,
    /// 重扫在飞：**不消费**监听队列，把事件留给 reconcile。
    reconciling: bool = false,
    /// 本帧刚收尾一次重扫：下个事件步骤要把队列里的事件全部补应用。
    replay_after_rescan: bool = false,
    /// reconcile 期间又看到 overflow / 序号缺口：合并成**一次**后续重扫。
    reconcile_again: bool = false,

    // ---- 消费侧（只有 UI 线程碰） ----
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    view_rows: std.ArrayListUnmanaged(core.model.Sample) = .empty,
    /// 合成 id 的字节（每条一段，指向这里；`view_rows` 每轮重建）。
    ids: std.ArrayListUnmanaged(u8) = .empty,
    /// 监听事件先加进来的路径（借用 `entries` 里的 path 切片）：分页去重用。
    event_paths: std.ArrayListUnmanaged([]const u8) = .empty,
    /// 选中项的身份跟踪（`browse_select.zig`）。
    tracker: select_mod.Tracker,
    /// 全量重枚举之前记下的选中项：等新行到了再按身份找回。
    restore_pending: bool = false,
    /// 导航历史 / 返回时的身份选中快照。
    history: history_mod.History,
    navigation_restore: bool = false,
    /// 当前排序；一批行收尾后只排一次。
    sort_key: sort_mod.Key = .name,
    needs_sort: bool = false,

    // ---- 内存预算（`browse_budget.zig`） ----
    budget: budget_mod.Budget = .{},
    /// 行存储这一刻实际占的分配字节（报告用；`observeBudget` 更新）。
    row_bytes: usize = 0,

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
            .limit = @max(1, @min(options.limit, types.hard_limit)),
            .watch_enabled = options.watch,
            .source = undefined,
            .started_ns = types.nowNs(io),
            .tracker = select_mod.Tracker.init(allocator),
            .history = undefined,
        };
        errdefer self.tracker.deinit();
        self.history = try history_mod.History.init(allocator, absolute);
        errdefer self.history.deinit();

        // 监听先于枚举：枚举期间的新文件也要能看到（RDCW 的读取窗口越小越好）。
        // 非递归是**要求**：浏览模式只列当前这一层。
        if (options.watch) self.watcher = openWatcher(allocator, absolute);
        errdefer if (self.watcher) |watcher| {
            watcher.deinit();
            allocator.destroy(watcher);
        };

        self.event_buffer = try allocator.alloc(watch.Event, storm_threshold + 1);
        errdefer allocator.free(self.event_buffer);

        // 基线要在生产线程起跑**之前**量：之后的工作集里就有行了。
        self.budget = budget_mod.Budget.initWithCap(options.memory_budget_bytes);
        self.source = try source_mod.Source.init(allocator, io, absolute, self.limit);
        errdefer self.source.deinit();
        return self;
    }

    /// 停线程、停监听、释放全部行与字符串。
    pub fn deinit(self: *Session) void {
        self.source.deinit();
        self.closeWatcher();
        self.clearEntries();
        self.event_paths.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        self.view_rows.deinit(self.allocator);
        self.ids.deinit(self.allocator);
        self.tracker.deinit();
        self.history.deinit();
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

    pub fn isDirectory(self: *const Session, index: usize) bool {
        return index < self.entries.items.len and self.entries.items[index].is_directory;
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
            .has_more = self.has_more,
            .loading_more = self.loading_more,
            .mem_refused = self.mem_refused,
            .remaining = self.remaining,
            .limit = self.limit,
            .bytes_per_row = self.budget.per_row orelse 0,
            .rescans = self.rescans,
            .reconciles = self.reconciles,
            .pages = self.pages,
            .sort = self.sort_key.text(),
            .epoch = self.source.currentEpoch(),
            .can_back = self.history.canBack(),
            .can_forward = self.history.canForward(),
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

    // -----------------------------------------------------------------------
    // 分页：加载更多 / 内存拒绝
    // -----------------------------------------------------------------------

    /// 还能不能点「加载更多」：本页有更多、没在忙、没被内存拒绝、路径可用。
    pub fn canLoadMore(self: *const Session) bool {
        return self.has_more and !self.enumerating and !self.mem_refused and
            !self.unavailable and !self.denied and
            self.entries.items.len < types.hard_limit;
    }

    /// 「加载更多」：先按实测每行字节判断 90 MiB 预算，再让生产线程接着上一页读。
    /// 返回是否真的排上了一页；拒绝时 `mem_refused` 为 true（随后会数出剩余条数）。
    pub fn loadMore(self: *Session) error{OutOfMemory}!bool {
        if (!self.canLoadMore()) return false;
        const rows = self.entries.items.len;
        const projected = @min(rows + self.limit, types.hard_limit);
        const current_ws = if (bench_win.resident()) |resident| resident.working_set else 0;
        if (self.budget.wouldExceed(current_ws, rows, projected)) {
            // 不许悄悄停：状态条会写"已到内存上限，剩余 N 条未加载"。
            self.mem_refused = true;
            self.loading_more = true;
            self.enumerating = true;
            self.has_more = false;
            self.source.requestCount();
            return false;
        }
        // 先按"这一页装完"的容量精确预留：ArrayList 的 1.5× 增长会让 5 万→10 万
        // 的那次搬家同时握着新旧两块缓冲（峰值多出十几 MiB）。精确预留把峰值
        // 钉在 `rows + page`，也让"每行实际字节"更接近稳态。
        try self.entries.ensureTotalCapacityPrecise(self.allocator, projected);
        try self.view_rows.ensureTotalCapacityPrecise(self.allocator, projected);
        try self.ids.ensureTotalCapacityPrecise(self.allocator, projected * types.id_stride);
        self.enumerating = true;
        self.loading_more = true;
        self.has_more = false;
        self.source.requestMore();
        return true;
    }

    /// 内存拒绝后把剩下的条目数出来（生产线程只数不装）。
    fn observeBudget(self: *Session) void {
        const resident = bench_win.resident() orelse return;
        self.row_bytes = budget_mod.rowBytes(
            self.entries.capacity,
            self.view_rows.capacity,
            self.ids.capacity,
            self.entries.items,
        );
        self.budget.observe(self.entries.items.len, self.row_bytes, resident.working_set);
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
            if (!self.swapping and !self.restore_pending and !self.navigation_restore) {
                try self.tracker.capture(self.io, self.entries.items, sel, &self.unreadable);
            }
        }

        // 2. 枚举线程发布的批次。
        if (try self.pumpBatches(&report)) report.changed = true;

        // 3. 监听事件（重扫期间不取，留给 reconcile）。
        try reconcile_mod.pump(self, &report);

        // 一页或一批事件收尾才排序：O(n log n)，不是每 512 行重排一次。
        if (report.changed and !self.enumerating and !self.swapping and self.needs_sort) {
            sort_mod.entries(self.entries.items, self.sort_key);
            self.needs_sort = false;
        }
        // 4. 行变了：重建样本视图，再把选中项按身份放回去。
        if (report.changed) try self.rebuildSamples();
        if (selection) |sel| {
            if (self.navigation_restore and !self.enumerating and !self.swapping) {
                try self.history.restore(self.io, self.entries.items, sel, &self.unreadable);
                self.navigation_restore = false;
                self.tracker.reset();
            } else if (!self.navigation_restore and !self.swapping and (report.changed or self.restore_pending)) {
                try self.tracker.restore(self.entries.items, sel);
                self.restore_pending = false;
                self.tracker.reset();
            }
        }
        // 5. 一页收尾之后再量每行字节：这一刻的行存储就是"这一页的价格"。
        if (report.page_done) self.observeBudget();
        return report;
    }

    // -----------------------------------------------------------------------
    // 枚举批次：消费侧
    // -----------------------------------------------------------------------

    /// 搬走队列里的全部批次。返回行列表是否变了。
    fn pumpBatches(self: *Session, report: *Report) error{OutOfMemory}!bool {
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
                // 重扫完成但一条新行都没有（目录被清空 / 打不开）：旧行必须清掉，
                // 否则列表会继续显示一份不存在的快照——比"少显示"更糟。
                if (!node.append and self.swapping) {
                    self.clearEntries();
                    self.swapping = false;
                }
                self.enumerating = false;
                if (node.append) self.loading_more = false else self.swapping = false;
                self.truncated = node.truncated;
                self.skipped = node.skipped;
                self.has_more = node.has_more;
                if (node.remaining > 0 or self.mem_refused) self.remaining = node.remaining;
                if (!node.count_only) {
                    self.done_ns = types.nowNs(self.io);
                    if (!node.append) self.pages = 1 else self.pages += 1;
                    report.page_done = true;
                }
                switch (node.status) {
                    .ok => {
                        self.unavailable = false;
                        self.denied = false;
                    },
                    .path_unavailable => self.unavailable = true,
                    .denied => self.denied = true,
                    .failed => self.unavailable = true,
                }
                if (self.reconciling and !node.append) {
                    // 重扫的 done 到了：事件步骤把队列里的补应用一遍。
                    self.reconciling = false;
                    self.replay_after_rescan = true;
                }
                changed = true;
                continue;
            }
            if (node.items.len == 0) continue;

            // 重枚举的第一批到了：这一刻才整体换掉旧行（列表不闪空）。
            if (!node.append and self.swapping) {
                self.clearEntries();
                self.swapping = false;
            }
            try self.entries.ensureUnusedCapacity(self.allocator, node.items.len);
            for (node.items) |entry| self.appendRow(entry);
            if (self.first_page_ns == null and self.entries.items.len > 0) {
                self.first_page_ns = types.nowNs(self.io);
            }
            changed = true;
        }
        return changed;
    }

    /// 追加一条：先查"监听事件先加进来的路径"，同一条不装第二次。
    fn appendRow(self: *Session, entry: Entry) void {
        for (self.event_paths.items) |known| {
            if (std.mem.eql(u8, known, entry.path)) {
                self.allocator.free(entry.path);
                return;
            }
        }
        self.entries.appendAssumeCapacity(entry);
        self.needs_sort = true;
    }

    /// 探针/测试用：强制一次重扫，并可让生产线程在枚举到 `pause_after` 条时暂停。
    pub fn forceRescan(self: *Session, pause_after: usize, pause_ms: u64) void {
        self.source.setPause(pause_after, pause_ms);
        reconcile_mod.startRescan(self, self.last_event_seq);
    }

    pub fn rescanPaused(self: *const Session) bool {
        return self.source.pausedNow();
    }

    pub fn enterDirectory(self: *Session, index: usize, selection: *selection_mod.Selection) NavigationError!void {
        return navigation.enterIndex(self, index, selection);
    }

    pub fn goBack(self: *Session, selection: *selection_mod.Selection) NavigationError!void {
        return navigation.back(self, selection);
    }

    pub fn goForward(self: *Session, selection: *selection_mod.Selection) NavigationError!void {
        return navigation.forward(self, selection);
    }

    pub fn goUp(self: *Session, selection: *selection_mod.Selection) NavigationError!void {
        return navigation.up(self, selection);
    }

    /// 用户切排序：先记身份，再一次原地排序 + O(n) 视图重建，选中项不丢。
    pub fn setSort(self: *Session, key: SortKey, selection: *selection_mod.Selection) error{OutOfMemory}!void {
        if (self.sort_key == key) return;
        try self.tracker.capture(self.io, self.entries.items, selection, &self.unreadable);
        self.sort_key = key;
        sort_mod.entries(self.entries.items, key);
        self.needs_sort = false;
        try self.rebuildSamples();
        try self.tracker.restore(self.entries.items, selection);
        self.tracker.reset();
    }

    pub fn sortKey(self: *const Session) SortKey {
        return self.sort_key;
    }

    pub fn historyLength(self: *const Session) usize {
        return self.history.len();
    }

    // -----------------------------------------------------------------------
    // 行维护
    // -----------------------------------------------------------------------

    fn clearEntries(self: *Session) void {
        // 去重表借用条目的 path 切片：先清表，再释放字符串。
        self.event_paths.clearRetainingCapacity();
        for (self.entries.items) |entry| self.allocator.free(entry.path);
        self.entries.clearRetainingCapacity();
        self.view_rows.clearRetainingCapacity();
        self.ids.clearRetainingCapacity();
        self.tombstones = 0;
    }

    pub fn retryUnavailable(self: *Session) void {
        navigation.retryUnavailable(self);
    }

    pub fn closeWatcher(self: *Session) void {
        if (self.watcher) |watcher| {
            watcher.deinit();
            self.allocator.destroy(watcher);
            self.watcher = null;
        }
    }

    pub fn reopenWatcher(self: *Session) void {
        if (self.watch_enabled) self.watcher = openWatcher(self.allocator, self.root);
    }

    fn rebuildSamples(self: *Session) error{OutOfMemory}!void {
        return view.rebuild(self);
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
