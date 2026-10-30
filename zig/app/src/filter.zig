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
        const next = try core.query.matchingIndices(self.allocator, samples, needle);
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
