//! 可变索引层：在不可变的 `Library` 快照上滚动应用文件变更事件。
//!
//! 分工（CHARTER「七、身份与注释」「九、当前落点」）：
//!   * `store.Library` 是「加载一次」的不可变真源：本模块只读它，一个字节都不改；
//!   * `Index` 是事件流上的工作视图：按到达顺序把 `Change` 应用到样本行上，
//!     给 UI 与缓存层消费。
//!
//! 边界：
//!   * core 不认识 `zig/ports`。`Change` 是数据层自己的事件类型，由 `zig/app`
//!     把监听口岸的事件适配进来；本文件不 import ports、不读文件系统、
//!     不出现任何平台 / 窗口系统符号。
//!   * 只在单线程使用：没有锁，也不要跨线程共享同一个 `Index`。
//!   * 路径按字节比较，不做大小写 / 分隔符归一化——归一化是口岸的事。
//!
//! 事件语义：
//!
//! | 事件 | 处理 | 计数 |
//! | --- | --- | --- |
//! | `created` | 追加一条只有路径的样本：`file_name` / `file_ext` 从路径推导， `identity = null`、`pending_metadata = true`、`imported_at = 0`，不查磁盘 | `added` |
//! | `removed` | 从视图移除；**不碰注释表**（注释键在身份上，删文件不删用户标签）。找不到路径就忽略 | `removed` |
//! | `renamed` | 只改路径与派生名，身份 / id / 顺序 / 分组 / 目录 / mtime 全部保留，`stableKey()` 不变。找不到 `from` 就降级成 `created`（见下） | `renamed` |
//! | `modified` | 更新 `mtime`（`Change` 带了才更新），并把**更新前**的 `StableKey` 记进 `invalidated`。找不到路径就忽略 | `modified` |
//! | `overflow` | `isDirty = true`；不逐条处理（它本身只是一条「有事件丢了」的信号） | `overflowed` / `overflow_lost` |
//!
//! 三条容易踩的规则，单独写清楚：
//!
//! 1. **`renamed` 找不到 `from` 时降级为 `created`**：监听口岸丢过事件、或文件在
//!    校验与事件之间又变了一次，都可能出现「只看到新路径」。这时新路径按 `created`
//!    插入（计入 `added`，**不计** `renamed`），而不是把整条事件丢掉——样本至少以
//!    新路径出现在视图里；用户注释仍按身份命中（注释表不在本模块手里）。
//! 2. **`overflow` 之后仍然照常应用后续事件**：`dirty` 只表示「中间可能有缺口」，
//!    不表示「视图已经不可用」。每条后续事件本身仍是有效事实，丢掉它们只会让视图
//!    更旧。调用方重新加载 / 重建视图之后调 `clearDirty()`。`clearDirty()` 只清标志，
//!    不做重建。
//! 3. **视图顺序**：保持 `Library` 的原顺序，新样本追加到末尾；删除用有序删除，
//!    不留空洞、不打乱其它样本。
//!
//! 所有权与生命周期：
//!   * `Index` 借用 `library`（不复制、不拥有），`Library` 必须比 `Index` 活得久；
//!     视图里旧样本的字符串仍指向 `Library` 的 arena。
//!   * `created` / `renamed` 产生的路径与合成 id 由 `Index` 用传入的 allocator 复制
//!     并持有；样本被移除 / 改名时立刻释放，`deinit()` 兜底释放剩下的。
//!   * `ApplyReport.invalidated` 指向 `Index` 内部缓冲，有效期到**下一次 `apply`**
//!     或 `deinit()`；下一次 `apply` 会复用同一块内存。
//!   * `apply` 返回其它字段后，视图切片仍然有效，直到下一次 `apply` 让数组搬家。
//!
//! 已知取舍：
//!   * 路径查找是线性扫描（`locate`）：`Library` 的 `file_path` 不保证唯一，
//!     用路径哈希表要么丢掉重复路径、要么多一层「下标失效」的维护。按 2000 条素材、
//!     每批几十条事件的量级，线性扫描是微秒级；真到了十万条再换索引。
//!   * 同一路径在 `Library` 里出现多次时，`locate` 只认第一条。
//!   * 本模块不维护分组 / 目录的双向关系（那是 `Library` + `reconcile` 的事），
//!     新建样本的 `folder_id` 是 null、`group_ids` 为空。
//!   * OOM 时 `apply` 可能已经应用了前面几条事件：视图保持一致（没有悬空字符串），
//!     但这一批不完整，调用方应把错误当作「需要重建」的信号。

const std = @import("std");
const model = @import("model.zig");
const store = @import("store.zig");

/// 一条文件变更事件。
///
/// 与 `zig/ports/src/watch.zig` 的 `Event` 形状对应，但**两边各自定义**：
/// core 不 import ports，适配在 `zig/app`。区别只有两处，都是数据层需要的：
///   * 路径直接是 `[]const u8`（不需要定长槽）；
///   * `modified` 可以带新 `mtime`（口岸拿不到时传 null）。
pub const Change = union(enum) {
    /// 新文件。路径必须是绝对路径（归一化由口岸负责）。
    created: []const u8,
    /// 文件被删除。
    removed: []const u8,
    /// 改名 / 同卷移动。
    renamed: Renamed,
    /// 内容被改写。
    modified: Modified,
    /// 内核缓冲区溢出：丢了 `lost` 条事件（0 = 未知）。
    overflow: u32,

    pub const Renamed = struct {
        /// 旧路径。
        from: []const u8,
        /// 新路径。
        to: []const u8,
    };

    pub const Modified = struct {
        path: []const u8,
        /// 新的修改时间（Unix 毫秒）。null = 口岸只知道「变了」，没有时间戳。
        mtime: ?i64 = null,
    };
};

/// 一批事件应用完之后给调用方的账。
pub const ApplyReport = struct {
    /// 新插入视图的样本数（含 `renamed` 找不到来源时降级产生的 created）。
    added: usize = 0,
    /// 从视图移除的样本数（含改名时同路径陈旧条目被丢弃的那一条）。
    removed: usize = 0,
    /// 成功改名的条数；找不到 `from` 的降级**不计**在这里。
    renamed: usize = 0,
    /// 被标记修改的条数（重复 `created` 也按 modified 记一次）。
    modified: usize = 0,
    /// 本批是否出现 `overflow`。
    overflowed: bool = false,
    /// 本批 `overflow` 声称丢失的条数之和；0 = 没有 overflow，或有但条数未知。
    overflow_lost: u32 = 0,
    /// 需要作废缓存的样本身份（`modified` 的那些，用**更新前**的键——
    /// 缓存里现在挂着的就是这个键）。
    ///
    /// 指向 `Index` 内部缓冲：有效期到下一次 `apply` 或 `deinit`。
    invalidated: []const model.StableKey = &.{},
};

/// 在 `Library` 之上滚动应用变更的工作视图。
pub const Index = struct {
    allocator: std.mem.Allocator,
    /// 真源，只读。必须比 `Index` 活得久。
    library: *const store.Library,
    /// 当前视图；顺序 = `Library` 原顺序 + 追加的 created。
    items: std.ArrayListUnmanaged(model.Sample) = .empty,
    /// Index 自己分配的字符串：地址 -> 字节数。按地址而不是内容记账——
    /// 库里借来的字符串可能和索引自己的字符串内容偶然相等，按内容释放会释放错指针。
    owned: std.AutoHashMapUnmanaged(usize, usize) = .empty,
    /// 当前这批要作废的键；`apply` 开头清空并复用容量。
    invalidated: std.ArrayListUnmanaged(model.StableKey) = .empty,
    /// `invalidated` 里退化键的路径副本（identity 键是纯值，不需要拷贝）。
    /// 每次 `apply` 重置，保证上一次报告里的键不会在批内被释放的路径带成悬空。
    invalidated_arena: std.heap.ArenaAllocator,
    /// 合成 id 的序号，只增不减。
    next_serial: u64 = 1,
    /// `overflow` 之后为 true；`clearDirty()` 之前一直保持。
    dirty: bool = false,

    /// 建立视图：把 `Library` 的样本**浅**复制一份（字符串仍归 `Library` 所有）。
    pub fn init(allocator: std.mem.Allocator, library: *const store.Library) error{OutOfMemory}!Index {
        var self = Index{
            .allocator = allocator,
            .library = library,
            .invalidated_arena = std.heap.ArenaAllocator.init(allocator),
        };
        errdefer self.invalidated_arena.deinit();
        errdefer self.items.deinit(allocator);
        try self.items.appendSlice(allocator, library.samples);
        return self;
    }

    /// 释放视图与它自己持有的全部字符串；之后不可再用。
    pub fn deinit(self: *Index) void {
        var iterator = self.owned.iterator();
        while (iterator.next()) |entry| {
            const bytes: [*]u8 = @ptrFromInt(entry.key_ptr.*);
            self.allocator.free(bytes[0..entry.value_ptr.*]);
        }
        self.owned.deinit(self.allocator);
        self.items.deinit(self.allocator);
        self.invalidated.deinit(self.allocator);
        self.invalidated_arena.deinit();
        self.* = undefined;
    }

    /// 按到达顺序应用一批事件。
    ///
    /// * 空路径事件直接忽略（路径是定位样本的唯一键）；
    /// * `overflow` 不会中止本批：后续事件照常应用，`dirty` 保持为 true；
    /// * 返回的 `invalidated` 归 `Index` 所有，下一次 `apply` 会覆盖。
    pub fn apply(self: *Index, changes: []const Change) error{OutOfMemory}!ApplyReport {
        self.invalidated.clearRetainingCapacity();
        _ = self.invalidated_arena.reset(.retain_capacity);

        var report = ApplyReport{};
        // 先把本批要用的容量要到位：之后的事件处理只剩字符串复制可能失败。
        try self.items.ensureUnusedCapacity(self.allocator, changes.len);
        try self.invalidated.ensureUnusedCapacity(self.allocator, changes.len);

        for (changes) |change| {
            switch (change) {
                .created => |path| try self.applyCreated(path, &report),
                .removed => |path| self.applyRemoved(path, &report),
                .renamed => |rename| try self.applyRenamed(rename, &report),
                .modified => |modified| try self.applyModified(modified, &report),
                .overflow => |lost| {
                    // 只是一条「有事件丢了」的信号，不逐条补课。
                    self.dirty = true;
                    report.overflowed = true;
                    report.overflow_lost +|= lost;
                },
            }
        }

        report.invalidated = self.invalidated.items;
        return report;
    }

    /// 当前视图（只读）。下次 `apply` 可能让数组搬家，别长期持有这个切片。
    pub fn samples(self: *const Index) []const model.Sample {
        return self.items.items;
    }

    /// `overflow` 之后是否为「可能缺事件」的脏视图。
    pub fn isDirty(self: *const Index) bool {
        return self.dirty;
    }

    /// 清除脏标记。只清标志、不重建视图：调用方应在重新加载 / 重建之后调用。
    pub fn clearDirty(self: *Index) void {
        self.dirty = false;
    }

    // -----------------------------------------------------------------------
    // 事件处理
    // -----------------------------------------------------------------------

    /// `created`：追加一条只有路径的样本；同一路径已经在视图里时按 `modified` 处理。
    fn applyCreated(self: *Index, path: []const u8, report: *ApplyReport) error{OutOfMemory}!void {
        if (path.len == 0) return;

        if (self.locate(path)) |position| {
            // 重复的 created（事件重放 / 漏了中间的 removed）：文件其实已经知道，
            // 但它的 L1 元数据可能已经过期，按 modified 记账并作废缓存。
            try self.recordInvalidated(self.items.items[position].stableKey());
            report.modified += 1;
            return;
        }

        try self.insertCreated(path);
        report.added += 1;
    }

    fn insertCreated(self: *Index, path: []const u8) error{OutOfMemory}!void {
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        const sample_id = try self.newCreatedId();
        errdefer self.allocator.free(sample_id);

        try self.items.ensureUnusedCapacity(self.allocator, 1);
        try self.owned.ensureUnusedCapacity(self.allocator, 2);

        self.items.appendAssumeCapacity(.{
            .id = sample_id,
            .file_name = model.fileNameFromPath(owned_path),
            .file_ext = model.fileExtFromPath(owned_path),
            .file_path = owned_path,
            // 与 store 的口径一致：没写 originalId 的样本，original_id 等于 id。
            .original_id = sample_id,
            .imported_at = 0,
            .mtime = 0,
            .identity = null,
            // 时长 / 采样率 / 声道还没有人读过：等后台扫描补齐。
            .pending_metadata = true,
        });
        self.ownString(owned_path);
        self.ownString(sample_id);
    }

    /// `removed`：从视图移除。注释表不归本模块管，所以这里不会碰它。
    fn applyRemoved(self: *Index, path: []const u8, report: *ApplyReport) void {
        if (path.len == 0) return;
        const position = self.locate(path) orelse return;
        self.removeAt(position);
        report.removed += 1;
    }

    /// `renamed`：只改地址与派生名；找不到 `from` 时降级为 `created`。
    fn applyRenamed(self: *Index, rename: Change.Renamed, report: *ApplyReport) error{OutOfMemory}!void {
        if (rename.to.len == 0) return;

        if (rename.from.len == 0) {
            // 没有旧路径就没法定位：按新文件处理。
            try self.applyCreated(rename.to, report);
            return;
        }

        if (self.locate(rename.from) == null) {
            // 降级：新路径至少要以样本形式出现在视图里（按 created 计数，不算 renamed）。
            try self.applyCreated(rename.to, report);
            return;
        }

        if (std.mem.eql(u8, rename.from, rename.to)) {
            // 同名不是改名，但事件确实被应用了。
            report.renamed += 1;
            return;
        }

        // 先把新路径复制下来：下面可能释放同路径的旧条目，而 rename.to 也许正指向它。
        const new_path = try self.allocator.dupe(u8, rename.to);
        errdefer self.allocator.free(new_path);
        try self.owned.ensureUnusedCapacity(self.allocator, 1);

        // 目标路径上还留着旧条目（覆盖式改名 / 事件乱序）：那条记录已经陈旧，
        // 按 removed 丢掉，保证视图里一条路径只有一个样本。
        if (self.locate(rename.to)) |stale| {
            self.removeAt(stale);
            report.removed += 1;
        }

        // removeAt 用有序删除，下标可能整体前移：重新定位来源。
        const position = self.locate(rename.from) orelse {
            // 防御分支：上面丢掉的陈旧条目不可能就是来源（来源路径是 from，不是 to）。
            self.allocator.free(new_path);
            return;
        };

        const sample = &self.items.items[position];
        const old_path = sample.file_path;
        sample.file_path = new_path;
        sample.file_name = model.fileNameFromPath(new_path);
        sample.file_ext = model.fileExtFromPath(new_path);
        self.ownString(new_path);
        self.releaseString(old_path);

        // 身份、id、folder_id、group_ids、mtime、pending_metadata 原样保留。
        report.renamed += 1;
    }

    /// `modified`：作废缓存键（更新前的键），能拿到 mtime 就一并更新。
    fn applyModified(self: *Index, modified: Change.Modified, report: *ApplyReport) error{OutOfMemory}!void {
        if (modified.path.len == 0) return;
        const position = self.locate(modified.path) orelse return;
        const sample = &self.items.items[position];

        // 先记键再改 mtime：缓存里挂着的是更新前的那个键。
        try self.recordInvalidated(sample.stableKey());
        if (modified.mtime) |mtime| sample.mtime = mtime;
        report.modified += 1;
    }

    // -----------------------------------------------------------------------
    // 视图维护
    // -----------------------------------------------------------------------

    /// 按路径找视图下标；`Library` 里有重复路径时只认第一条。
    fn locate(self: *const Index, path: []const u8) ?usize {
        for (self.items.items, 0..) |sample, position| {
            if (std.mem.eql(u8, sample.file_path, path)) return position;
        }
        return null;
    }

    /// 有序删除：后面的样本整体前移，不留空洞、不打乱顺序。
    fn removeAt(self: *Index, position: usize) void {
        const sample = self.items.orderedRemove(position);
        // created / renamed 产生的字符串由 Index 持有；从 Library 借来的原样不动。
        self.releaseString(sample.file_path);
        self.releaseString(sample.id);
    }

    /// 记一条作废键。退化键里的路径复制进本次 `apply` 专属的 arena，
    /// 这样同一批里后续的 removed 也不会把它带成悬空。
    fn recordInvalidated(self: *Index, key: model.StableKey) error{OutOfMemory}!void {
        const owned: model.StableKey = switch (key) {
            .identity => |identity| .{ .identity = identity },
            .fallback => |fallback| .{ .fallback = .{
                .path = try self.invalidated_arena.allocator().dupe(u8, fallback.path),
                .size = fallback.size,
                .mtime = fallback.mtime,
            } },
        };
        self.invalidated.appendAssumeCapacity(owned);
    }

    /// 生成一个不与 `Library` 已有 id 冲突的合成 id。
    /// 视图里不会同时出现两个 Index 自己发的 id（序号只增），所以只需避开库里的 id。
    fn newCreatedId(self: *Index) error{OutOfMemory}![]u8 {
        while (true) {
            const serial = self.next_serial;
            self.next_serial += 1;
            const candidate = try std.fmt.allocPrint(self.allocator, "idx:{d}", .{serial});
            if (!self.library.sample_index.contains(candidate)) return candidate;
            self.allocator.free(candidate);
        }
    }

    /// 记一笔「这块内存是 Index 的」；调用前必须确保 `owned` 有容量。
    fn ownString(self: *Index, string: []u8) void {
        self.owned.putAssumeCapacity(@intFromPtr(string.ptr), string.len);
    }

    /// 若这块内存是 Index 自己分配的，释放它；指向 `Library` arena 的字符串不动。
    fn releaseString(self: *Index, string: []const u8) void {
        if (string.len == 0) return;
        const entry = self.owned.fetchRemove(@intFromPtr(string.ptr)) orelse return;
        const bytes: [*]u8 = @ptrFromInt(entry.key);
        self.allocator.free(bytes[0..entry.value]);
    }
};
