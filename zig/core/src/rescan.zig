//! 局部重扫的**纯差分**：把「当前视图里的旧样本」和「刚扫出来的目录项事实」
//! 对齐成增 / 删 / 改 / 移动四类，不读磁盘、不碰 `Index`、不分配任何长期状态。
//!
//! 这是 M4「监听溢出后局部重扫」的数据层半边；另一半在 `zig/app/src/rescan_ui.zig`
//! （工作线程扫描 + 500 ms 防抖）。本文件只做纯函数，所以可以用合成输入覆盖
//! 全部边界，不需要真文件。
//!
//! ## 匹配规则
//!
//! 1. **身份优先**：`Sample.identity` 与 `ScanEntry.identity` 都存在时，按
//!    卷序列号 + 文件索引配对。路径变了但身份相同 = 同一个文件被改名 / 移动：
//!    进 `moved`，**不算新增、也不算删除**。
//! 2. **没有身份时退回路径**：至少一侧没有身份（旧库没有 identity，或扫描盘是
//!    FAT32 / 网络盘拿不到 File ID）时，按路径字节配对，再用 `size` / `mtime`
//!    判断是「完全不变」还是「内容被改写」（`modified`）。
//!    这是宪章「七」的三元组规则：路径 + 大小 + mtime。
//! 3. **两侧都有身份但身份不同**：即使路径相同也不配对（同名文件被删后重建 =
//!    新文件）。旧样本进 `removed`、新事实进 `added`，不拿路径硬凑。
//!
//! `modified` 还包含「一侧身份从无变成有」的情况（扫描补上了身份）：这种事实
//! 需要回填到样本上，但路径 / 大小 / mtime 可能都没变，所以不能只靠 `same_facts`
//! 判断。`pending_metadata`（L1 元数据没读过）不参与比较——重扫只刷新 L0 事实，
//! 不负责 probe 内容，用它当修改条件会让每次重扫都永远「有修改」。
//!
//! ## 顺序
//!
//! * `added`：按 `fresh` 顺序（扫描口岸已按路径排序，结果稳定）；
//! * `removed` / `modified` / `moved` / `changed`：按旧列表下标升序；
//! * `unchanged` 是「路径、大小、mtime、身份都没变」的条数。
//!
//! ## 所有权
//!
//! `diff` 返回的数组由调用方的 allocator 持有，用 `Diff.deinit` 一次释放。
//! 数组元素里的路径仍是 `Sample` / `ScanEntry` 的借用，本层不复制字符串。

const std = @import("std");
const model = @import("model.zig");

/// 扫描口岸事实在 core 里的最小形状（与 `ports/scan.zig` 的 `FileFact` 一一对应）。
/// 不 import ports：数据层只认识事实字段，不认识 Win32。
pub const ScanEntry = struct {
    /// 绝对路径（native 分隔符，大小写保持磁盘原样）。
    path: []const u8,
    /// 文件名，含扩展名（本层不用，留给调用方做展示 / 调试）。
    name: []const u8,
    /// 扩展名，含点；没有扩展名时为空串。
    ext: []const u8,
    size: u64,
    /// 修改时间（Unix 毫秒）；读不到时 0。
    mtime: i64,
    /// 卷序列号 + 文件索引；文件系统不提供时 null。
    identity: ?model.FileIdentity = null,
};

/// 一条配对：`old` 是旧列表下标，`fresh` 是扫描结果下标。
///
/// `added` 里的 `old` 为 null（没有旧样本）；`moved` / `changed` 两边都有。
pub const SampleRef = struct {
    old: ?usize = null,
    fresh: usize,
};

/// 一次差分的账。数组本身归调用方，元素里的路径是借用；`deinit` 释放数组。
pub const Diff = struct {
    /// 真正的新文件（`fresh` 顺序）。
    added: []SampleRef = &.{},
    /// 从视图消失的旧下标（升序）。
    removed: []usize = &.{},
    /// 大小 / mtime / 身份需要刷新的旧下标（升序）。
    modified: []usize = &.{},
    /// 路径变了、身份没变的配对（改名 / 同卷移动，升序）。
    moved: []SampleRef = &.{},
    /// 所有需要写回样本的配对（`modified` 的 `fresh` 侧视图，升序）。
    /// `moved` 与它有交集：移动 + 改内容会同时出现在两边。
    changed: []SampleRef = &.{},
    /// 路径、大小、mtime、身份全部一致。
    unchanged: usize = 0,

    pub fn deinit(self: *Diff, allocator: std.mem.Allocator) void {
        freeSlice(allocator, self.added);
        freeSlice(allocator, self.removed);
        freeSlice(allocator, self.modified);
        freeSlice(allocator, self.moved);
        freeSlice(allocator, self.changed);
        self.* = .{};
    }

    /// 是否没有任何需要应用的变更（`unchanged` 不算变更）。
    pub fn isEmpty(self: *const Diff) bool {
        return self.added.len == 0 and self.removed.len == 0 and
            self.modified.len == 0 and self.moved.len == 0;
    }
};

/// 计算 `old` → `fresh` 的差分。失败只可能是 `OutOfMemory`。
pub fn diff(
    allocator: std.mem.Allocator,
    old: []const model.Sample,
    fresh: []const ScanEntry,
) error{OutOfMemory}!Diff {
    // 身份 → 旧下标列表。用列表而不是单值：硬链接会让两个路径共享一个身份，
    // 一个旧样本被配上之后，另一个仍未配的旧样本不能因此被当成删除。
    var by_identity: std.HashMapUnmanaged(
        model.FileIdentity,
        std.ArrayListUnmanaged(usize),
        IdentityContext,
        80,
    ) = .empty;
    defer {
        var iterator = by_identity.iterator();
        while (iterator.next()) |entry| entry.value_ptr.deinit(allocator);
        by_identity.deinit(allocator);
    }

    // 路径 → 旧下标（重复路径只认第一条，和 `Index.locate` 一致）。
    var by_path: std.StringHashMapUnmanaged(usize) = .empty;
    defer by_path.deinit(allocator);

    for (old, 0..) |sample, index| {
        if (sample.identity) |identity| {
            const slot = try by_identity.getOrPut(allocator, identity);
            if (!slot.found_existing) slot.value_ptr.* = .empty;
            try slot.value_ptr.append(allocator, index);
        }
        const path_slot = try by_path.getOrPut(allocator, sample.file_path);
        if (!path_slot.found_existing) path_slot.value_ptr.* = index;
    }

    const used = try allocator.alloc(bool, old.len);
    defer allocator.free(used);
    @memset(used, false);

    var added: std.ArrayListUnmanaged(SampleRef) = .empty;
    errdefer added.deinit(allocator);
    var removed: std.ArrayListUnmanaged(usize) = .empty;
    errdefer removed.deinit(allocator);
    var modified: std.ArrayListUnmanaged(usize) = .empty;
    errdefer modified.deinit(allocator);
    var moved: std.ArrayListUnmanaged(SampleRef) = .empty;
    errdefer moved.deinit(allocator);
    var changed: std.ArrayListUnmanaged(SampleRef) = .empty;
    errdefer changed.deinit(allocator);
    var unchanged: usize = 0;

    for (fresh, 0..) |entry, fresh_index| {
        const matched = try matchOld(old, &by_identity, &by_path, used, entry);
        if (matched) |old_index| {
            used[old_index] = true;
            const sample = old[old_index];

            // 身份：扫描「补上」身份算变化（需要回填）；扫描这一轮拿不到身份
            // 只说明「未知」，不能把旧样本已有的身份当成变了，否则每次重扫都
            // 会把同一条再报一次 modified。
            const same_facts = sample.file_size == entry.size and sample.mtime == entry.mtime;
            const path_changed = !std.mem.eql(u8, sample.file_path, entry.path);
            const metadata_changed = identityGained(sample.identity, entry.identity) or !same_facts;

            if (path_changed) try moved.append(allocator, .{ .old = old_index, .fresh = fresh_index });
            if (metadata_changed) {
                try modified.append(allocator, old_index);
                try changed.append(allocator, .{ .old = old_index, .fresh = fresh_index });
            }
            if (!path_changed and !metadata_changed) unchanged += 1;
            continue;
        }

        try added.append(allocator, .{ .fresh = fresh_index });
    }

    // 没有被任何 fresh 配上的旧样本 = 删除。按下标升序，调用方可以从后往前删。
    for (used, 0..) |was_used, index| {
        if (!was_used) try removed.append(allocator, index);
    }

    // 稳定顺序：调用方 / 测试不依赖 fresh 的遍历偶然。
    sortRefsByOld(moved.items);
    sortRefsByOld(changed.items);
    std.mem.sort(usize, modified.items, {}, std.sort.asc(usize));

    var result = Diff{};
    errdefer result.deinit(allocator);
    result.added = try added.toOwnedSlice(allocator);
    result.removed = try removed.toOwnedSlice(allocator);
    result.modified = try modified.toOwnedSlice(allocator);
    result.moved = try moved.toOwnedSlice(allocator);
    result.changed = try changed.toOwnedSlice(allocator);
    result.unchanged = unchanged;
    return result;
}

/// 为一条 fresh 事实找旧下标；没有就是 null。
fn matchOld(
    old: []const model.Sample,
    by_identity: *const std.HashMapUnmanaged(
        model.FileIdentity,
        std.ArrayListUnmanaged(usize),
        IdentityContext,
        80,
    ),
    by_path: *const std.StringHashMapUnmanaged(usize),
    used: []const bool,
    entry: ScanEntry,
) error{OutOfMemory}!?usize {
    if (entry.identity) |identity| {
        if (by_identity.get(identity)) |indices| {
            for (indices.items) |index| {
                if (!used[index]) return index;
            }
        }
    }

    const index = by_path.get(entry.path) orelse return null;
    if (used[index]) return null;

    const sample = old[index];
    // 路径相同但两侧都有身份且不同：这是删掉旧文件后在原地放了一个新文件，
    // 不是同一个文件。让它走 removed + added，注释键（身份）也才不会串。
    if (sample.identity != null and entry.identity != null and
        !sample.identity.?.eql(entry.identity.?))
    {
        return null;
    }
    return index;
}

/// fresh 带来了旧样本没有的身份（或身份变了）才需要回填。
/// fresh 没有身份 = 这一轮不知道，不是「身份没了」。
fn identityGained(old: ?model.FileIdentity, fresh: ?model.FileIdentity) bool {
    const fresh_identity = fresh orelse return false;
    const old_identity = old orelse return true;
    return !old_identity.eql(fresh_identity);
}

fn sortRefsByOld(items: []SampleRef) void {
    std.mem.sort(SampleRef, items, {}, struct {
        fn lessThan(_: void, a: SampleRef, b: SampleRef) bool {
            return a.old.? < b.old.?;
        }
    }.lessThan);
}

fn freeSlice(allocator: std.mem.Allocator, slice: anytype) void {
    if (slice.len != 0) allocator.free(slice);
}

const IdentityContext = struct {
    pub fn hash(_: IdentityContext, key: model.FileIdentity) u64 {
        return key.hash();
    }

    pub fn eql(_: IdentityContext, a: model.FileIdentity, b: model.FileIdentity) bool {
        return a.eql(b);
    }
};
