//! 搜索过滤的行映射：过滤结果是一份「行 → 样本下标」的数组，列表只遍历它。
//!
//! 为什么是映射而不是把命中的样本拷出来：选择、预览、拖拽/复制全部按样本下标
//! 认文件（`selection.zig`），拷一份样本会造出第二套下标。映射只回答"列表第 r
//! 行是哪个样本"，其余各层一行都不用改。
//!
//! 匹配规则只有一条，来自 `core.query.matchingIndices`（也就是
//! `containsIgnoreCase`）：文件名子串、ASCII 大小写不敏感、空查询等于不过滤。
//! 本文件不另写一套匹配。
//!
//! 纯逻辑：不 import nanoui、不碰窗口，`zig build test` 和 `--filter` 自检都能
//! 直接驱动。光标"保持/回落"也在这里（`cursorSample` / `moveRow`），这样它可以
//! 被单测覆盖，而不是埋在一个需要窗口的分支里。

const std = @import("std");
const core = @import("otto_core");

/// 行 → 样本下标。`items[row]` 是列表第 `row` 行对应的 `samples` 下标。
pub const Rows = struct {
    allocator: std.mem.Allocator,
    items: []usize = &.{},

    pub fn init(allocator: std.mem.Allocator) Rows {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Rows) void {
        // 空映射可能来自 `rebuild` 里的 0 命中（已当场释放），不是分配出来的。
        if (self.items.len > 0) self.allocator.free(self.items);
        self.items = &.{};
    }

    pub fn len(self: *const Rows) usize {
        return self.items.len;
    }

    pub fn sampleAt(self: *const Rows, row: usize) ?usize {
        if (row >= self.items.len) return null;
        return self.items[row];
    }

    /// 样本下标在过滤结果里的新行号；不在结果里就是 null。
    pub fn rowOfSample(self: *const Rows, sample_index: usize) ?usize {
        for (self.items, 0..) |item, row| {
            if (item == sample_index) return row;
        }
        return null;
    }

    /// 用当前查询重建映射。先分配新的、成功了才换掉旧的：分配失败时调用方
    /// 还留着上一帧能画的结果，不会出现"列表空了但查询还在"的半状态。
    pub fn rebuild(
        self: *Rows,
        samples: []const core.model.Sample,
        needle: []const u8,
    ) error{OutOfMemory}!void {
        return self.rebuildWithExt(samples, needle, null);
    }

    /// 查询与后缀筛选的**交集**：`exts` 为 null 或不含任何选择时等于 `rebuild`。
    /// 后缀之间是并集（选中 png + jpg 时两种都留），搜索与后缀之间是 AND。
    pub fn rebuildWithExt(
        self: *Rows,
        samples: []const core.model.Sample,
        needle: []const u8,
        exts: ?*const ExtFilter,
    ) error{OutOfMemory}!void {
        const next = try matchIndices(self.allocator, samples, needle, exts);
        if (self.items.len > 0) self.allocator.free(self.items);
        self.items = next;
        // 0 命中的切片没有行可遍历，交给 deinit 释放反而要记一个"空但不是静态"
        // 的标志；这里直接还掉，`items` 退回静态空切片。
        if (next.len == 0) {
            self.allocator.free(next);
            self.items = &.{};
        }
    }
};

fn matchIndices(
    backing: std.mem.Allocator,
    samples: []const core.model.Sample,
    needle: []const u8,
    exts: ?*const ExtFilter,
) error{OutOfMemory}![]usize {
    // 没有后缀条件时仍走 core 的那一条匹配，保证搜索语义只有一份实现。
    if (exts == null) return core.query.matchingIndices(backing, samples, needle);

    var result: std.ArrayListUnmanaged(usize) = .empty;
    errdefer result.deinit(backing);
    for (samples, 0..) |sample, index| {
        if (!core.query.containsIgnoreCase(sample.file_name, needle)) continue;
        if (!exts.?.matches(sample.file_ext)) continue;
        try result.append(backing, index);
    }
    return result.toOwnedSlice(backing);
}

// ---------------------------------------------------------------------------
// 后缀：归一化、多选筛选、当前库的后缀计数
// ---------------------------------------------------------------------------

/// 去掉前导点（`.PNG` / `PNG` / `..png` 都归一成 `PNG`/`png`），返回值指向入参，
/// 不分配。大小写留给 `eqlExt` 比较时忽略。
pub fn trimExt(ext: []const u8) []const u8 {
    var start: usize = 0;
    while (start < ext.len and ext[start] == '.') start += 1;
    return ext[start..];
}

/// 后缀等价：忽略前导点和 ASCII 大小写（`.PNG` == `png` == `.png`）。
pub fn eqlExt(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(trimExt(a), trimExt(b));
}

fn normalizeExt(allocator: std.mem.Allocator, ext: []const u8) error{OutOfMemory}![]u8 {
    const trimmed = trimExt(ext);
    const out = try allocator.alloc(u8, trimmed.len);
    _ = std.ascii.lowerString(out, trimmed);
    return out;
}

/// 用户选中的后缀集合（多选）。空集合 = 不筛（等同「全部」）。
///
/// 每个后缀存一份小写副本：库重新加载后 `sample.file_ext` 的指针会换，
/// 选中的条件不能跟着悬垂。
pub const ExtFilter = struct {
    allocator: std.mem.Allocator,
    /// 归一化后的后缀（无点、小写），按加入顺序。
    selected: std.ArrayListUnmanaged([]u8) = .empty,
    /// 选择变化计数：`Search` 靠它判断要不要重建行映射，不用逐帧比集合。
    revision: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) ExtFilter {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ExtFilter) void {
        for (self.selected.items) |ext| self.allocator.free(ext);
        self.selected.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn active(self: *const ExtFilter) bool {
        return self.selected.items.len > 0;
    }

    /// `ext` 可以带点、大小写任意；没有后缀（`.` / 空串）永远不算选中。
    pub fn contains(self: *const ExtFilter, ext: []const u8) bool {
        for (self.selected.items) |item| {
            if (eqlExt(item, ext)) return true;
        }
        return false;
    }

    /// 空筛选 = 全部；否则任一选中后缀命中即可（多选是并集）。
    pub fn matches(self: *const ExtFilter, ext: []const u8) bool {
        if (self.selected.items.len == 0) return true;
        return self.contains(ext);
    }

    /// 点一下 chip：已选就取消，没选就加入。没有后缀的文件不能成为一个 chip。
    pub fn toggle(self: *ExtFilter, ext: []const u8) error{OutOfMemory}!void {
        if (trimExt(ext).len == 0) return;
        for (self.selected.items, 0..) |item, index| {
            if (eqlExt(item, ext)) {
                self.allocator.free(item);
                _ = self.selected.orderedRemove(index);
                self.revision +%= 1;
                return;
            }
        }
        const label = try normalizeExt(self.allocator, ext);
        errdefer self.allocator.free(label);
        try self.selected.append(self.allocator, label);
        self.revision +%= 1;
    }

    /// 「全部」：清空筛选。本来就没有筛选时不算一次变化。
    pub fn clear(self: *ExtFilter) void {
        if (self.selected.items.len == 0) return;
        for (self.selected.items) |ext| self.allocator.free(ext);
        self.selected.clearRetainingCapacity();
        self.revision +%= 1;
    }

    /// `--filter-ext=png,.JPG` 这类逗号分隔列表；空格、空项、重复项都跳过。
    pub fn addList(self: *ExtFilter, text: []const u8) error{OutOfMemory}!void {
        var parts = std.mem.splitScalar(u8, text, ',');
        while (parts.next()) |raw| {
            const ext = std.mem.trim(u8, raw, " \t\r\n");
            if (trimExt(ext).len == 0 or self.contains(ext)) continue;
            try self.toggle(ext);
        }
    }

    /// 选中后缀的展示文本（小写、无点、`、` 连接）。空筛选返回空串。
    pub fn summary(self: *const ExtFilter, buffer: []u8) []const u8 {
        return self.join(buffer, "、");
    }

    /// 同一份选择，CLI 用逗号（`exts=wav,png`）。
    pub fn csv(self: *const ExtFilter, buffer: []u8) []const u8 {
        return self.join(buffer, ",");
    }

    fn join(self: *const ExtFilter, buffer: []u8, separator: []const u8) []const u8 {
        var len: usize = 0;
        for (self.selected.items, 0..) |ext, index| {
            if (index > 0) {
                if (len + separator.len + ext.len > buffer.len) break;
                @memcpy(buffer[len..][0..separator.len], separator);
                len += separator.len;
            }
            if (len + ext.len > buffer.len) break;
            @memcpy(buffer[len..][0..ext.len], ext);
            len += ext.len;
        }
        return buffer[0..len];
    }
};

/// 当前库每个后缀的素材数。顺序按后缀在库里第一次出现的顺序，标签为小写无点。
/// 没有后缀的样本不单独成项，但它们仍计入 `total`（「全部」的数字）。
pub const ExtCounts = struct {
    pub const Item = struct { label: []u8, count: usize };

    allocator: std.mem.Allocator,
    items: []Item = &.{},
    total: usize = 0,

    pub fn init(allocator: std.mem.Allocator) ExtCounts {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ExtCounts) void {
        for (self.items) |item| self.allocator.free(item.label);
        if (self.items.len > 0) self.allocator.free(self.items);
        self.* = undefined;
    }

    /// 整表重算；先算新的、成功了才换掉旧的（分配失败保留上一帧的 chip）。
    pub fn rebuild(self: *ExtCounts, samples: []const core.model.Sample) error{OutOfMemory}!void {
        var next: std.ArrayListUnmanaged(Item) = .empty;
        errdefer {
            for (next.items) |item| self.allocator.free(item.label);
            next.deinit(self.allocator);
        }
        for (samples) |sample| {
            const ext = trimExt(sample.file_ext);
            if (ext.len == 0) continue;
            var found: ?usize = null;
            for (next.items, 0..) |item, index| {
                if (eqlExt(item.label, ext)) {
                    found = index;
                    break;
                }
            }
            if (found) |index| {
                next.items[index].count += 1;
            } else {
                const label = try normalizeExt(self.allocator, ext);
                errdefer self.allocator.free(label); // append 失败时还没进 next
                try next.append(self.allocator, .{ .label = label, .count = 1 });
            }
        }
        const owned = try next.toOwnedSlice(self.allocator);
        for (self.items) |item| self.allocator.free(item.label);
        if (self.items.len > 0) self.allocator.free(self.items);
        self.items = owned;
        self.total = samples.len;
    }
};

/// 键盘让光标行怎么走。
pub const Move = enum { up, down, home, end };

/// 光标行的下一次位置（0 基行号）。越过边缘**不环绕**：第 0 行再按 ↑ 还是 0，
/// 最后一行再按 ↓ 还是最后一行。没有当前行时先落到第 0 行（`end` 除外）。
pub fn moveRow(matches: usize, current: ?usize, move: Move) ?usize {
    if (matches == 0) return null;
    const last = matches - 1;
    const row = current orelse return switch (move) {
        .up, .down, .home => 0,
        .end => last,
    };
    return switch (move) {
        .up => if (row == 0) 0 else @min(row - 1, last),
        .down => @min(row + 1, last),
        .home => 0,
        .end => last,
    };
}

/// 过滤后光标该落在哪个样本：原样本还在结果里就保持它（行号由调用方用
/// `rowOfSample` 重新算）；否则回落到第 0 行；一条命中都没有就是 null。
///
/// 注意这里记的是**样本下标**而不是行号：过滤后行号整体会变，样本下标不会。
pub fn cursorSample(rows: []const usize, previous_sample: ?usize) ?usize {
    if (previous_sample) |sample| {
        for (rows) |item| {
            if (item == sample) return sample;
        }
    }
    return if (rows.len > 0) rows[0] else null;
}

// ---------------------------------------------------------------------------
// 测试：纯逻辑，不需要窗口、磁盘或 nanoui
// ---------------------------------------------------------------------------

const testing = std.testing;

const fixture_samples = [_]core.model.Sample{
    .{ .id = "a", .file_name = "Kick 01", .file_ext = ".wav", .file_path = "C:\\lib\\kick.wav" },
    .{ .id = "b", .file_name = "Snare", .file_ext = ".wav", .file_path = "C:\\lib\\snare.wav" },
    .{ .id = "c", .file_name = "IMG_002", .file_ext = ".png", .file_path = "C:\\lib\\img.png" },
    .{ .id = "d", .file_name = "img loop", .file_ext = ".wav", .file_path = "C:\\lib\\img loop.wav" },
};

test "rebuild：行→样本映射保持样本顺序，空查询全中，大小写不敏感，无命中为空" {
    var rows = Rows.init(testing.allocator);
    defer rows.deinit();

    try rows.rebuild(&fixture_samples, "");
    try testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3 }, rows.items);
    try testing.expectEqual(@as(?usize, 0), rows.sampleAt(0));
    try testing.expectEqual(@as(?usize, 3), rows.sampleAt(3));
    try testing.expectEqual(@as(?usize, null), rows.sampleAt(4));

    try rows.rebuild(&fixture_samples, "IMG");
    try testing.expectEqualSlices(usize, &.{ 2, 3 }, rows.items);
    try testing.expectEqual(@as(?usize, 0), rows.rowOfSample(2));
    try testing.expectEqual(@as(?usize, 1), rows.rowOfSample(3));
    try testing.expectEqual(@as(?usize, null), rows.rowOfSample(0));

    // 再重建一次：旧映射要被释放，新结果不能叠在旧的后面。
    try rows.rebuild(&fixture_samples, "kick");
    try testing.expectEqualSlices(usize, &.{0}, rows.items);
    try testing.expectEqual(@as(usize, 1), rows.len());

    try rows.rebuild(&fixture_samples, "guitar");
    try testing.expectEqual(@as(usize, 0), rows.len());
    try testing.expectEqual(@as(?usize, null), rows.sampleAt(0));
}

test "moveRow：↑↓ 越界不环绕，Home/End 到两端，0 命中没有光标" {
    // 5 行：第 0 行按 ↑ 还是 0；最后一行按 ↓ 还是最后。
    try testing.expectEqual(@as(?usize, 0), moveRow(5, 0, .up));
    try testing.expectEqual(@as(?usize, 1), moveRow(5, 0, .down));
    try testing.expectEqual(@as(?usize, 2), moveRow(5, 1, .down));
    try testing.expectEqual(@as(?usize, 4), moveRow(5, 4, .down));
    try testing.expectEqual(@as(?usize, 3), moveRow(5, 4, .up));
    try testing.expectEqual(@as(?usize, 0), moveRow(5, 3, .home));
    try testing.expectEqual(@as(?usize, 4), moveRow(5, 0, .end));

    // 没有当前行：先落到第 0 行；End 直接到最后一行。
    try testing.expectEqual(@as(?usize, 0), moveRow(5, null, .up));
    try testing.expectEqual(@as(?usize, 0), moveRow(5, null, .down));
    try testing.expectEqual(@as(?usize, 4), moveRow(5, null, .end));

    // 一条命中都没有：任何键都不该造出一个行号。
    try testing.expectEqual(@as(?usize, null), moveRow(0, null, .down));
    try testing.expectEqual(@as(?usize, null), moveRow(0, 0, .end));
}

test "cursorSample：原样本还在结果里就保持，否则回落第 0 行，0 命中为 null" {
    // 原样本 2 在 "img" 结果 [2,3] 里：保持样本 2（新行号是 0，由 rowOfSample 算）。
    try testing.expectEqual(@as(?usize, 2), cursorSample(&.{ 2, 3 }, 2));

    // 原样本 1 不在结果里：回落第 0 行的样本。
    try testing.expectEqual(@as(?usize, 2), cursorSample(&.{ 2, 3 }, 1));

    // 原本就没有光标：同样落到第 0 行。
    try testing.expectEqual(@as(?usize, 2), cursorSample(&.{ 2, 3 }, null));

    // 清空查询（结果变回全部）：原样本仍然在，保持它。
    try testing.expectEqual(@as(?usize, 3), cursorSample(&.{ 0, 1, 2, 3 }, 3));

    try testing.expectEqual(@as(?usize, null), cursorSample(&.{}, 3));
    try testing.expectEqual(@as(?usize, null), cursorSample(&.{}, null));
}

// ---------------------------------------------------------------------------
// 后缀筛选：混模态的小库（wav / png / jpg / mp4 / 无后缀）
// ---------------------------------------------------------------------------

const mixed_samples = [_]core.model.Sample{
    .{ .id = "0", .file_name = "Tone kick", .file_ext = ".WAV", .file_path = "C:\\lib\\kick.WAV" },
    .{ .id = "1", .file_name = "tone snare", .file_ext = "wav", .file_path = "C:\\lib\\snare.wav" },
    .{ .id = "2", .file_name = "Tone pad", .file_ext = ".PNG", .file_path = "C:\\lib\\pad.png" },
    .{ .id = "3", .file_name = "cover art", .file_ext = ".jpg", .file_path = "C:\\lib\\cover.jpg" },
    .{ .id = "4", .file_name = "clip", .file_ext = ".mp4", .file_path = "C:\\lib\\clip.mp4" },
    .{ .id = "5", .file_name = "noext", .file_ext = "", .file_path = "C:\\lib\\noext" },
    .{ .id = "6", .file_name = "tone noext", .file_ext = "", .file_path = "C:\\lib\\tone noext" },
};

test "后缀归一化：.PNG / png / .png 等价，前导点可有可无" {
    try testing.expect(eqlExt(".PNG", "png"));
    try testing.expect(eqlExt("png", ".png"));
    try testing.expect(eqlExt("Png", "PNG"));
    try testing.expect(eqlExt("..png", ".png"));
    try testing.expect(!eqlExt("png", "jpg"));
    try testing.expectEqualStrings("PNG", trimExt(".PNG"));
    try testing.expectEqualStrings("wav", trimExt("wav"));
    try testing.expectEqualStrings("", trimExt("."));
}

test "多选后缀是并集，与搜索是交集；空筛选 = 全部；不存在的后缀 = 0 命中" {
    var rows = Rows.init(testing.allocator);
    defer rows.deinit();
    var exts = ExtFilter.init(testing.allocator);
    defer exts.deinit();

    // 空筛选 = 全部（包括没有后缀的两条）。
    try rows.rebuildWithExt(&mixed_samples, "", &exts);
    try testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3, 4, 5, 6 }, rows.items);

    // 选 png：只剩样本 2；大小写与前导点在 toggle 里归一。
    try exts.toggle(".PNG");
    try rows.rebuildWithExt(&mixed_samples, "", &exts);
    try testing.expectEqualSlices(usize, &.{2}, rows.items);

    // 再选 jpg：两个后缀的**并集**。
    try exts.toggle("JPG");
    try rows.rebuildWithExt(&mixed_samples, "", &exts);
    try testing.expectEqualSlices(usize, &.{ 2, 3 }, rows.items);

    // 搜索 tone 与后缀集合**交集**：只有 png 那条同时满足。
    try rows.rebuildWithExt(&mixed_samples, "tone", &exts);
    try testing.expectEqualSlices(usize, &.{2}, rows.items);

    // 搜索命中但不在后缀集合里 -> 0 行（不是"忽略后缀"）：clip 是 mp4。
    try rows.rebuildWithExt(&mixed_samples, "clip", &exts);
    try testing.expectEqual(@as(usize, 0), rows.len());

    // 清空后缀（「全部」）后，搜索 tone 命中 wav 两条 + png 一条 + 无后缀一条。
    exts.clear();
    try rows.rebuildWithExt(&mixed_samples, "tone", &exts);
    try testing.expectEqualSlices(usize, &.{ 0, 1, 2, 6 }, rows.items);

    // 不存在的后缀：0 命中，但筛选条件仍然有效（不是退化成全部）。
    try exts.toggle("xyz");
    try testing.expect(exts.active());
    try rows.rebuildWithExt(&mixed_samples, "", &exts);
    try testing.expectEqual(@as(usize, 0), rows.len());
}

test "后缀 chip 计数来自当前库：按首次出现排序，无后缀不单独成项但计入全部" {
    var counts = ExtCounts.init(testing.allocator);
    defer counts.deinit();

    try counts.rebuild(&mixed_samples);
    try testing.expectEqual(@as(usize, 7), counts.total);
    try testing.expectEqual(@as(usize, 4), counts.items.len);
    try testing.expectEqualStrings("wav", counts.items[0].label);
    try testing.expectEqual(@as(usize, 2), counts.items[0].count);
    try testing.expectEqualStrings("png", counts.items[1].label);
    try testing.expectEqual(@as(usize, 1), counts.items[1].count);
    try testing.expectEqualStrings("jpg", counts.items[2].label);
    try testing.expectEqualStrings("mp4", counts.items[3].label);

    // 库变小：计数整表重算，旧标签不能残留。
    try counts.rebuild(mixed_samples[0..3]);
    try testing.expectEqual(@as(usize, 3), counts.total);
    try testing.expectEqual(@as(usize, 2), counts.items.len);
}

test "ExtFilter.addList：逗号分隔、空格/空项/重复项跳过，summary 用顿号连接" {
    var exts = ExtFilter.init(testing.allocator);
    defer exts.deinit();

    try exts.addList("PNG, .Jpg,png,, xyz ");
    try testing.expectEqual(@as(usize, 3), exts.selected.items.len);
    try testing.expect(exts.contains(".Png"));
    try testing.expect(exts.contains("jpg"));
    try testing.expect(exts.contains("XYZ"));

    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("png、jpg、xyz", exts.summary(&buffer));

    // 没有后缀的文件不能成为一个筛选条件。
    try exts.toggle(".");
    try testing.expectEqual(@as(usize, 3), exts.selected.items.len);

    exts.clear();
    try testing.expect(!exts.active());
    try testing.expectEqualStrings("", exts.summary(&buffer));
    try testing.expect(exts.matches("anything")); // 空筛选 = 全部
}
