//! 用户注释（分组 / 标签 / 评分）的存储与旧数据迁移。
//!
//! 键是 `model.StableKey`：有文件身份就用身份，没有才退回 `路径 + 大小 + mtime`。
//! 所以改名、同卷移动、索引重建都不会让注释变成孤儿（宪章「七」）；
//! 退化盘上才退到三元组，并在 `resolve` 里等身份到位后自动升级。
//!
//! 本文件是纯数据层：不读文件系统、不碰平台 API、没有全局状态。
//! 所有写入的键与字符串都由表自己的 arena 持有一份拷贝。

const std = @import("std");
const model = @import("model.zig");

/// 一条用户注释。
///
/// `rating` 用 0 表示「未评分」，这样部分更新（只改标签 / 只改分组）不需要
/// 额外的 optional 字段。
pub const Annotations = struct {
    /// 所属分组 id，顺序保留。
    group_ids: []const []const u8 = &.{},
    /// 标签，顺序保留。
    tags: []const []const u8 = &.{},
    /// 星级：0 = 未评分，1..5 = 评分。
    rating: u8 = 0,

    pub fn isEmpty(self: Annotations) bool {
        return self.group_ids.len == 0 and self.tags.len == 0 and self.rating == 0;
    }

    pub fn eql(self: Annotations, other: Annotations) bool {
        return self.rating == other.rating and
            stringListEql(self.group_ids, other.group_ids) and
            stringListEql(self.tags, other.tags);
    }
};

/// `AnnotationTable.entries()` 返回的只读视图。
pub const Entry = struct {
    key: model.StableKey,
    annotations: Annotations,
};

/// 以 `StableKey` 为键的注释表。
///
/// 生命周期：`init` 之后写入的键（退化键里的路径）与注释字符串都拷贝进内部
/// arena，`deinit` 一次回收。`get` / `entries` 返回的切片指向 arena：
/// arena 不会移动已分配的字符串，但 `remove` 会重排 `entries` 的元素顺序。
pub const AnnotationTable = struct {
    arena: std.heap.ArenaAllocator,
    /// 键 -> `items` 下标；键里的路径与 `items[i].key` 里的路径共用同一块 arena 内存。
    index: std.HashMapUnmanaged(
        model.StableKey,
        usize,
        model.StableKeyContext,
        80, // 与 std 默认装载因子一致
    ) = .empty,
    items: std.ArrayList(Entry) = .empty,

    pub fn init(backing_allocator: std.mem.Allocator) AnnotationTable {
        return .{ .arena = std.heap.ArenaAllocator.init(backing_allocator) };
    }

    pub fn deinit(self: *AnnotationTable) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn count(self: *const AnnotationTable) usize {
        return self.items.items.len;
    }

    pub fn get(self: *const AnnotationTable, key: model.StableKey) ?Annotations {
        const position = self.index.get(key) orelse return null;
        return self.items.items[position].annotations;
    }

    pub fn contains(self: *const AnnotationTable, key: model.StableKey) bool {
        return self.index.contains(key);
    }

    /// 写一条注释：键已存在则整体替换，否则新增。
    ///
    /// 键里的路径、分组 id、标签都会被拷贝；空串与重复项被丢弃（保序）。
    /// 调用方在返回后可以立刻释放自己的缓冲区。
    pub fn put(
        self: *AnnotationTable,
        key: model.StableKey,
        annotations: Annotations,
    ) error{OutOfMemory}!void {
        const allocator = self.arena.allocator();

        if (self.index.get(key)) |position| {
            // 替换：键已经归表所有，只换值。
            self.items.items[position].annotations = try copyAnnotations(allocator, annotations);
            return;
        }

        // 先把两个容量要点到位，后面的 append / put 就不会「插了一半」失败。
        try self.items.ensureUnusedCapacity(allocator, 1);
        try self.index.ensureUnusedCapacity(allocator, 1);
        const owned_key = try copyStableKey(allocator, key);
        const owned_annotations = try copyAnnotations(allocator, annotations);
        const position = self.items.items.len;
        self.items.appendAssumeCapacity(.{ .key = owned_key, .annotations = owned_annotations });
        self.index.putAssumeCapacity(owned_key, position);
    }

    /// 删一条；键不存在返回 false。arena 里的字符串不回收（表生命周期内）。
    pub fn remove(self: *AnnotationTable, key: model.StableKey) bool {
        const position = self.index.get(key) orelse return false;
        _ = self.index.remove(key);
        const last = self.items.items.len - 1;
        _ = self.items.swapRemove(position);
        if (position != last) {
            // 队尾元素被挪到了 position，同步它在 map 里的下标。
            const moved_key = self.items.items[position].key;
            if (self.index.getPtr(moved_key)) |slot| slot.* = position;
        }
        return true;
    }

    /// 全部条目，顺序不保证（`remove` 用 swapRemove 重排）。
    pub fn entries(self: *const AnnotationTable) []const Entry {
        return self.items.items;
    }
};

/// 把 `extra` 并进 `base`，用于「旧 fallback 条目」与「新 identity 条目」相遇时。
///
/// * 分组 / 标签：保序并集去重，任何一边都不丢；
/// * 评分：`base`（identity 侧，更新）优先，`base` 未评分（0）时才继承 `extra`。
///
/// 返回的切片借用 `base` / `extra` 里的字符串；要交给表长期持有请走
/// `AnnotationTable.put`（它会拷贝）。
pub fn merge(
    allocator: std.mem.Allocator,
    base: Annotations,
    extra: Annotations,
) error{OutOfMemory}!Annotations {
    return .{
        .group_ids = try unionStrings(allocator, base.group_ids, extra.group_ids),
        .tags = try unionStrings(allocator, base.tags, extra.tags),
        .rating = if (base.rating != 0) base.rating else extra.rating,
    };
}

/// `resolve` 的迁移结果。
pub const ResolveReport = struct {
    /// 表里本来就是 identity 键、无需迁移的条目数（原样保留）。
    identity_entries: usize = 0,
    /// 从 fallback 键搬到 identity 键的条目数。
    migrated: usize = 0,
    /// 其中目标 identity 键上已有注释、做了并集的条目数（已计入 migrated）。
    merged: usize = 0,
    /// 找不到带 identity 的同路径样本，保留在 fallback 上。
    unmatched: usize = 0,
    /// 同路径出现多个不同身份，保留在 fallback 上（宁可不搬，也不搬错）。
    ambiguous: usize = 0,
    /// 大小两边都已知且不一致，判定为不同文件，保留在 fallback 上。
    size_mismatch: usize = 0,
    /// mtime 两边都已知且不一致，判定为不同文件，保留在 fallback 上。
    mtime_mismatch: usize = 0,

    /// 迁移结束后仍留在 fallback 键上的条目数。
    pub fn keptFallback(self: ResolveReport) usize {
        return self.unmatched + self.ambiguous + self.size_mismatch + self.mtime_mismatch;
    }
};

/// 同一路径上带身份的样本汇总：迁移时只认唯一身份。
const IdentityCandidate = struct {
    identity: model.FileIdentity,
    size: u64 = 0,
    mtime: i64 = 0,
    /// 同一路径上出现多个不同身份 -> 迁移有歧义。
    conflict: bool = false,
};

/// 把旧数据里「只有 fallback 键」的注释迁移到 identity 键上（宪章「七」的旧库升级）。
///
/// 规则：
/// 1. 只处理 fallback 键；identity 键原样保留（计入 `identity_entries`）。
/// 2. 用 fallback 键里的路径找样本：路径上必须存在**带 identity** 的样本，
///    否则保留 fallback（`unmatched`）。
/// 3. 同一路径出现多个**不同** identity -> 有歧义，保留 fallback（`ambiguous`）。
/// 4. fallback 键与样本的 size / mtime 都已知且不一致 -> 视为不同文件，
///    保留 fallback（`size_mismatch` / `mtime_mismatch`）。0 表示未知，当作通配。
/// 5. 通过检查 -> 合并进 identity 键：分组 / 标签取保序并集，评分 identity 侧优先；
///    合并后删除 fallback 条目（不重复、不丢）。
///
/// 幂等：迁移完成后表里不再有可迁移的 fallback 条目，再跑一次是空操作。
pub fn resolve(
    table: *AnnotationTable,
    samples: []const model.Sample,
) error{OutOfMemory}!ResolveReport {
    var report = ResolveReport{};
    const allocator = table.arena.allocator();

    // 1) 每条路径上带身份的样本汇总。没身份的样本不参与（它自己还得靠 fallback 键）。
    var candidates: std.StringHashMapUnmanaged(IdentityCandidate) = .empty;
    for (samples) |sample| {
        const identity = sample.identity orelse continue;
        const slot = try candidates.getOrPut(allocator, sample.file_path);
        if (!slot.found_existing) {
            slot.value_ptr.* = .{
                .identity = identity,
                .size = sample.file_size,
                .mtime = sample.mtime,
            };
        } else if (!slot.value_ptr.identity.eql(identity)) {
            slot.value_ptr.conflict = true;
        }
    }

    // 2) 先拍 fallback 键的快照：迁移里会 remove / put，直接遍历 entries()
    //    会踩到 swapRemove 造成的下标变化。快照里的路径指向 arena，不会失效。
    var pending: std.ArrayList(model.StableKey) = .empty;
    defer pending.deinit(allocator);
    for (table.entries()) |entry| {
        switch (entry.key) {
            .identity => report.identity_entries += 1,
            .fallback => try pending.append(allocator, entry.key),
        }
    }

    // 3) 逐条判定：能唯一确定身份就搬，否则留着。
    for (pending.items) |key| {
        const fallback = switch (key) {
            .fallback => |value| value,
            .identity => continue,
        };
        const candidate = candidates.get(fallback.path) orelse {
            report.unmatched += 1;
            continue;
        };
        if (candidate.conflict) {
            report.ambiguous += 1;
            continue;
        }
        if (knownMismatch(u64, fallback.size, candidate.size)) {
            report.size_mismatch += 1;
            continue;
        }
        if (knownMismatch(i64, fallback.mtime, candidate.mtime)) {
            report.mtime_mismatch += 1;
            continue;
        }

        const target = model.StableKey{ .identity = candidate.identity };
        const incoming = table.get(key) orelse continue;
        const annotations = if (table.get(target)) |existing| blk: {
            report.merged += 1;
            break :blk try merge(allocator, existing, incoming);
        } else incoming;

        _ = table.remove(key);
        try table.put(target, annotations);
        report.migrated += 1;
    }

    return report;
}

// ---------------------------------------------------------------------------
// 内部工具
// ---------------------------------------------------------------------------

/// 两个「0 表示未知」的数值是否【已知且不相等】。
fn knownMismatch(comptime T: type, left: T, right: T) bool {
    return left != 0 and right != 0 and left != right;
}

/// 拷贝退化键里的路径；身份键是纯值，直接复制。
fn copyStableKey(
    allocator: std.mem.Allocator,
    key: model.StableKey,
) error{OutOfMemory}!model.StableKey {
    return switch (key) {
        .identity => |identity| .{ .identity = identity },
        .fallback => |fallback| .{ .fallback = .{
            .path = try allocator.dupe(u8, fallback.path),
            .size = fallback.size,
            .mtime = fallback.mtime,
        } },
    };
}

fn copyAnnotations(
    allocator: std.mem.Allocator,
    annotations: Annotations,
) error{OutOfMemory}!Annotations {
    return .{
        .group_ids = try copyStringList(allocator, annotations.group_ids),
        .tags = try copyStringList(allocator, annotations.tags),
        .rating = annotations.rating,
    };
}

/// 深拷贝 + 保序去重；空串丢弃。
fn copyStringList(
    allocator: std.mem.Allocator,
    items: []const []const u8,
) error{OutOfMemory}![]const []const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    try result.ensureTotalCapacity(allocator, items.len);
    for (items) |item| {
        if (item.len == 0) continue;
        if (containsString(result.items, item)) continue;
        result.appendAssumeCapacity(try allocator.dupe(u8, item));
    }
    return result.toOwnedSlice(allocator);
}

/// 保序并集（借用入参字符串，不拷贝）。
fn unionStrings(
    allocator: std.mem.Allocator,
    first: []const []const u8,
    second: []const []const u8,
) error{OutOfMemory}![]const []const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    try result.ensureTotalCapacity(allocator, first.len + second.len);
    for (first) |item| {
        if (item.len == 0) continue;
        if (containsString(result.items, item)) continue;
        result.appendAssumeCapacity(item);
    }
    for (second) |item| {
        if (item.len == 0) continue;
        if (containsString(result.items, item)) continue;
        result.appendAssumeCapacity(item);
    }
    return result.toOwnedSlice(allocator);
}

fn containsString(items: []const []const u8, needle: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

fn stringListEql(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (!std.mem.eql(u8, left, right)) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// 单元测试（集成测试见 annotations_test.zig）
// ---------------------------------------------------------------------------

test "AnnotationTable：put / get / 替换 / remove / entries" {
    var table = AnnotationTable.init(std.testing.allocator);
    defer table.deinit();

    const identity = model.FileIdentity{ .volume_serial = 7, .file_index = 42 };
    const key = model.StableKey{ .identity = identity };

    try std.testing.expect(table.get(key) == null);
    try std.testing.expectEqual(@as(usize, 0), table.count());

    try table.put(key, .{ .group_ids = &.{"drums"}, .tags = &.{ "red", "", "red" }, .rating = 4 });
    try std.testing.expectEqual(@as(usize, 1), table.count());
    // 空串与重复项被丢弃。
    const stored = table.get(key).?;
    try std.testing.expectEqual(@as(usize, 1), stored.group_ids.len);
    try std.testing.expectEqual(@as(usize, 1), stored.tags.len);
    try std.testing.expectEqualStrings("red", stored.tags[0]);
    try std.testing.expectEqual(@as(u8, 4), stored.rating);
    try std.testing.expect(table.contains(key));

    // 同键写入 = 整体替换。
    try table.put(key, .{ .tags = &.{"blue"} });
    try std.testing.expectEqual(@as(usize, 1), table.count());
    try std.testing.expect(table.get(key).?.eql(.{ .tags = &.{"blue"} }));

    // entries 视图与 get 一致。
    try std.testing.expectEqual(@as(usize, 1), table.entries().len);
    try std.testing.expect(table.entries()[0].key.eql(key));

    try std.testing.expect(table.remove(key));
    try std.testing.expect(!table.remove(key));
    try std.testing.expectEqual(@as(usize, 0), table.count());
    try std.testing.expect(table.get(key) == null);
}

test "AnnotationTable：remove 后下标仍然对齐" {
    var table = AnnotationTable.init(std.testing.allocator);
    defer table.deinit();

    const keys = [_]model.StableKey{
        .{ .identity = .{ .volume_serial = 1, .file_index = 1 } },
        .{ .identity = .{ .volume_serial = 1, .file_index = 2 } },
        .{ .identity = .{ .volume_serial = 1, .file_index = 3 } },
    };
    for (keys, 0..) |key, position| {
        var buffer: [8]u8 = undefined;
        const tag = try std.fmt.bufPrint(&buffer, "t{d}", .{position});
        try table.put(key, .{ .tags = &.{tag} });
    }
    try std.testing.expectEqual(@as(usize, 3), table.count());

    // 删中间一条：队尾会被 swapRemove 挪过来，它的 map 下标必须同步。
    try std.testing.expect(table.remove(keys[1]));
    try std.testing.expect(table.get(keys[2]) != null);
    try std.testing.expectEqualStrings("t2", table.get(keys[2]).?.tags[0]);
    try std.testing.expectEqualStrings("t0", table.get(keys[0]).?.tags[0]);
    try std.testing.expect(table.get(keys[1]) == null);
}

test "merge：分组 / 标签取并集，评分不丢" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const merged = try merge(
        allocator,
        .{ .group_ids = &.{"favorites"}, .tags = &.{ "new", "both" }, .rating = 0 },
        .{ .group_ids = &.{"drums"}, .tags = &.{ "both", "old" }, .rating = 3 },
    );
    try std.testing.expectEqual(@as(usize, 2), merged.group_ids.len);
    try std.testing.expectEqualStrings("favorites", merged.group_ids[0]);
    try std.testing.expectEqualStrings("drums", merged.group_ids[1]);
    try std.testing.expectEqual(@as(usize, 3), merged.tags.len);
    try std.testing.expectEqualStrings("new", merged.tags[0]);
    try std.testing.expectEqualStrings("both", merged.tags[1]);
    try std.testing.expectEqualStrings("old", merged.tags[2]);
    // base 未评分 -> 继承 extra；base 已评分 -> 优先 base。
    try std.testing.expectEqual(@as(u8, 3), merged.rating);
    const rated = try merge(allocator, .{ .rating = 5 }, .{ .rating = 2 });
    try std.testing.expectEqual(@as(u8, 5), rated.rating);
}
