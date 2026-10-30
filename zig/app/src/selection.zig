//! 列表选择模型（v1）：按下标记录选中集合，外加一个锚点与一个"当前行"。
//!
//! 为什么是下标而不是路径/身份：列表的源是 `live.Live` 的 `Index` 视图，行号就是
//! 它给的下标；这一版不引入第二套身份表。代价写在报告里：磁盘删除会让后面的行
//! 前移，选中集合跟着前移（v1 已知限制）。
//!
//! 语义照抄资源管理器：
//!   * 点一行           = 只选它（锚点、当前行都变成它）；
//!   * Ctrl+点一行      = 切换它，其余不动（锚点、当前行变成它）；
//!   * Shift+点一行     = 锚点到它之间全选（锚点不动，当前行变成它）；
//!   * 空白处点击       = 清空（由 main 调用 `clear`）。
//!
//! 拖拽/复制用哪一组路径是**纯函数**：
//!   * 被拖的行在选中集合里 → 整个选中集合（按行号升序）；
//!   * 否则                 → 只有这一行。
//!
//! 本文件不 import nanoui：选择逻辑可以脱离窗口被 `--demo-transport` 与单元测试
//! 直接驱动。

const std = @import("std");
const core = @import("otto_core");

/// 一次点击带了哪些修饰键。`ctrl` 用 Windows 的语义（macOS 上是 Command，
/// nanoui 的 `Input.adding()` 做同样的分派；本 app 只跑 Windows）。
pub const Mods = struct {
    ctrl: bool = false,
    shift: bool = false,
};

/// 路径收集可能失败的原因：分配失败，或调用方给的行号越界。
pub const PathError = error{ OutOfMemory, InvalidIndex };

pub const Selection = struct {
    /// 第 i 位 = 第 i 行被选中。长度始终等于当前样本数（`main.State.syncSelection`）。
    bits: std.DynamicBitSetUnmanaged = .{},
    /// Shift 范围的起点；没有选中/没有点过时为 null。
    anchor: ?usize = null,
    /// 最后点过的那一行；Ctrl+C 在"没有选中"时用它当当前行。
    cursor: ?usize = null,

    pub fn deinit(self: *Selection, allocator: std.mem.Allocator) void {
        self.bits.deinit(allocator);
        self.* = undefined;
    }

    pub fn len(self: *const Selection) usize {
        return self.bits.bit_length;
    }

    pub fn count(self: *const Selection) usize {
        return self.bits.count();
    }

    pub fn isSelected(self: *const Selection, index: usize) bool {
        return index < self.len() and self.bits.isSet(index);
    }

    /// 样本数变了：按新长度裁剪。越界的锚点/当前行作废（不猜它们该落到哪）。
    pub fn resize(self: *Selection, allocator: std.mem.Allocator, new_len: usize) error{OutOfMemory}!void {
        if (new_len == self.len()) return;
        try self.bits.resize(allocator, new_len, false);
        if (self.anchor) |a| {
            if (a >= new_len) self.anchor = null;
        }
        if (self.cursor) |c| {
            if (c >= new_len) self.cursor = null;
        }
    }

    pub fn clear(self: *Selection) void {
        self.bits.unsetAll();
        self.anchor = null;
        self.cursor = null;
    }

    /// 只选中这一行；锚点与当前行都指向它。
    pub fn selectOnly(self: *Selection, index: usize) void {
        if (index >= self.len()) return;
        self.bits.unsetAll();
        self.bits.set(index);
        self.anchor = index;
        self.cursor = index;
    }

    /// 切换一行的选中状态；锚点与当前行指向它。
    pub fn toggle(self: *Selection, index: usize) void {
        if (index >= self.len()) return;
        self.bits.toggle(index);
        self.anchor = index;
        self.cursor = index;
    }

    /// 选中 [from, to] 闭区间（顺序无所谓）。不清空别的位——调用方决定。
    pub fn selectRange(self: *Selection, from: usize, to: usize) void {
        if (self.len() == 0) return;
        const lo = @min(from, to);
        const hi = @min(@max(from, to), self.len() - 1);
        var i = lo;
        while (i <= hi) : (i += 1) self.bits.set(i);
    }

    /// 往已存在的集合里加一行（`--select` 预置与测试用；不动锚点/当前行）。
    pub fn add(self: *Selection, index: usize) void {
        if (index >= self.len()) return;
        self.bits.set(index);
    }

    /// 一次点击的完整语义。行号越界时什么也不做（防御列表缩短的那一帧）。
    pub fn click(self: *Selection, index: usize, mods: Mods) void {
        if (index >= self.len()) return;
        if (mods.shift) {
            // 没有锚点（例如刚清空过）时以当前行为锚点：范围退化成一行。
            const anchor = self.anchor orelse index;
            self.bits.unsetAll();
            self.selectRange(anchor, index);
            self.anchor = anchor;
            self.cursor = index;
            return;
        }
        if (mods.ctrl) {
            self.toggle(index);
            return;
        }
        self.selectOnly(index);
    }

    /// 选中的行号，升序。返回的切片归调用方。
    pub fn selectedIndices(self: *const Selection, allocator: std.mem.Allocator) error{OutOfMemory}![]usize {
        const out = try allocator.alloc(usize, self.count());
        var n: usize = 0;
        var i: usize = 0;
        while (i < self.len()) : (i += 1) {
            if (self.bits.isSet(i)) {
                out[n] = i;
                n += 1;
            }
        }
        std.debug.assert(n == out.len);
        return out;
    }

    /// 拖拽这一行时真正要交给宿主的行号：该行在选中集合里 → 整个集合；
    /// 否则只有这一行。返回的切片归调用方。
    pub fn dragIndices(self: *const Selection, allocator: std.mem.Allocator, row: usize) error{OutOfMemory}![]usize {
        if (row < self.len() and self.bits.isSet(row)) return self.selectedIndices(allocator);
        const out = try allocator.alloc(usize, 1);
        out[0] = row;
        return out;
    }

    /// Ctrl+C 要复制的行号：有选中就整个集合；没有就用当前行；都没有就是空。
    pub fn copyIndices(self: *const Selection, allocator: std.mem.Allocator) error{OutOfMemory}![]usize {
        if (self.count() > 0) return self.selectedIndices(allocator);
        if (self.cursor) |cursor| {
            const out = try allocator.alloc(usize, 1);
            out[0] = cursor;
            return out;
        }
        return allocator.alloc(usize, 0);
    }
};

/// 把行号翻译成路径，并**复制**出来：返回的每个切片归 `allocator`。
///
/// 拖拽的关键一步：帧里收集的字符串不能直接带去帧外（`samples` 可能在下一批
/// `Index.apply` 里被释放/搬家），所以这里永远复制一份。
pub fn collectPaths(
    allocator: std.mem.Allocator,
    samples: []const core.model.Sample,
    indices: []const usize,
) PathError![]const []const u8 {
    const paths = try allocator.alloc([]const u8, indices.len);
    var built: usize = 0;
    errdefer {
        for (paths[0..built]) |path| allocator.free(path);
        allocator.free(paths);
    }
    for (indices, 0..) |index, n| {
        if (index >= samples.len) return error.InvalidIndex;
        paths[n] = try allocator.dupe(u8, samples[index].file_path);
        built += 1;
    }
    return paths;
}

/// 释放 `collectPaths` 的产物（顺序无关）。
pub fn freePaths(allocator: std.mem.Allocator, paths: []const []const u8) void {
    for (paths) |path| allocator.free(path);
    allocator.free(paths);
}

/// `--select=0,1,5` 的解析：只认十进制下标，逗号分隔，空项忽略。
/// 结果写进 `out`，返回条数；越界/非法/一条都没有都算 `Invalid`。
pub fn parseIndexList(text: []const u8, out: []usize) error{Invalid}!usize {
    var count: usize = 0;
    var parts = std.mem.splitScalar(u8, text, ',');
    while (parts.next()) |raw| {
        const part = std.mem.trim(u8, raw, " \t");
        if (part.len == 0) continue;
        if (count == out.len) return error.Invalid;
        out[count] = std.fmt.parseInt(usize, part, 10) catch return error.Invalid;
        count += 1;
    }
    if (count == 0) return error.Invalid;
    return count;
}

// ---------------------------------------------------------------------------
// 测试：纯逻辑，不需要窗口、磁盘或 nanoui
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectBits(sel: *const Selection, expected: []const bool) !void {
    try testing.expectEqual(expected.len, sel.len());
    for (expected, 0..) |want, i| {
        try testing.expectEqual(want, sel.isSelected(i));
    }
    try testing.expectEqual(std.mem.count(bool, expected, &.{true}), sel.count());
}

test "普通点击只选一行，锚点与当前行跟着走" {
    var sel: Selection = .{};
    defer sel.deinit(testing.allocator);
    try sel.resize(testing.allocator, 5);

    sel.click(2, .{});
    try expectBits(&sel, &.{ false, false, true, false, false });
    try testing.expectEqual(@as(?usize, 2), sel.anchor);
    try testing.expectEqual(@as(?usize, 2), sel.cursor);

    sel.click(4, .{});
    try expectBits(&sel, &.{ false, false, false, false, true });
}

test "Ctrl+点击切换，不清掉别的" {
    var sel: Selection = .{};
    defer sel.deinit(testing.allocator);
    try sel.resize(testing.allocator, 4);

    sel.click(1, .{});
    sel.click(3, .{ .ctrl = true });
    try expectBits(&sel, &.{ false, true, false, true });

    sel.click(1, .{ .ctrl = true });
    try expectBits(&sel, &.{ false, false, false, true });
}

test "Shift+点击从锚点到当前行，重复 Shift 仍从同一锚点" {
    var sel: Selection = .{};
    defer sel.deinit(testing.allocator);
    try sel.resize(testing.allocator, 6);

    sel.click(1, .{});
    sel.click(4, .{ .shift = true });
    try expectBits(&sel, &.{ false, true, true, true, true, false });
    try testing.expectEqual(@as(?usize, 1), sel.anchor);
    try testing.expectEqual(@as(?usize, 4), sel.cursor);

    // 再 Shift 点 2：范围重算为 [1,2]，锚点不动。
    sel.click(2, .{ .shift = true });
    try expectBits(&sel, &.{ false, true, true, false, false, false });
    try testing.expectEqual(@as(?usize, 1), sel.anchor);
}

test "没有锚点时的 Shift+点击退化成一行" {
    var sel: Selection = .{};
    defer sel.deinit(testing.allocator);
    try sel.resize(testing.allocator, 3);

    sel.click(2, .{ .shift = true });
    try expectBits(&sel, &.{ false, false, true });
    try testing.expectEqual(@as(?usize, 2), sel.anchor);
}

test "越界点击被忽略；缩短后越界的锚点/当前行作废" {
    var sel: Selection = .{};
    defer sel.deinit(testing.allocator);
    try sel.resize(testing.allocator, 4);

    sel.click(4, .{});
    try expectBits(&sel, &.{ false, false, false, false });

    sel.click(3, .{});
    try sel.resize(testing.allocator, 2);
    try expectBits(&sel, &.{ false, false });
    try testing.expectEqual(@as(?usize, null), sel.anchor);
    try testing.expectEqual(@as(?usize, null), sel.cursor);
}

test "拖拽取集合：行在选中里 → 全部；不在 → 只有它" {
    var sel: Selection = .{};
    defer sel.deinit(testing.allocator);
    try sel.resize(testing.allocator, 6);

    sel.click(1, .{});
    sel.click(3, .{ .ctrl = true });
    sel.click(4, .{ .ctrl = true });

    const all = try sel.dragIndices(testing.allocator, 3);
    defer testing.allocator.free(all);
    try testing.expectEqualSlices(usize, &.{ 1, 3, 4 }, all);

    const one = try sel.dragIndices(testing.allocator, 2);
    defer testing.allocator.free(one);
    try testing.expectEqualSlices(usize, &.{2}, one);
}

test "Ctrl+C 取集合；没有选中就用当前行；都没有就是空" {
    var sel: Selection = .{};
    defer sel.deinit(testing.allocator);
    try sel.resize(testing.allocator, 4);

    const empty = try sel.copyIndices(testing.allocator);
    defer testing.allocator.free(empty);
    try testing.expectEqual(@as(usize, 0), empty.len);

    sel.click(2, .{});
    sel.click(0, .{ .ctrl = true });
    const both = try sel.copyIndices(testing.allocator);
    defer testing.allocator.free(both);
    try testing.expectEqualSlices(usize, &.{ 0, 2 }, both);

    sel.clear();
    sel.cursor = 3;
    const cursor = try sel.copyIndices(testing.allocator);
    defer testing.allocator.free(cursor);
    try testing.expectEqualSlices(usize, &.{3}, cursor);
}

test "collectPaths 复制路径并保持行号顺序；越界返回 InvalidIndex" {
    const samples = [_]core.model.Sample{
        .{ .id = "a", .file_name = "a", .file_ext = ".wav", .file_path = "C:\\lib\\a.wav" },
        .{ .id = "b", .file_name = "b", .file_ext = ".wav", .file_path = "C:\\lib\\b.wav" },
        .{ .id = "c", .file_name = "c", .file_ext = ".mp3", .file_path = "C:\\lib\\c.mp3" },
    };

    const paths = try collectPaths(testing.allocator, &samples, &.{ 2, 0 });
    defer freePaths(testing.allocator, paths);
    try testing.expectEqualStrings("C:\\lib\\c.mp3", paths[0]);
    try testing.expectEqualStrings("C:\\lib\\a.wav", paths[1]);
    // 复制出来的字节不指向样本的字符串。
    try testing.expect(paths[0].ptr != samples[2].file_path.ptr);

    try testing.expectError(error.InvalidIndex, collectPaths(testing.allocator, &samples, &.{3}));
}

test "parseIndexList 认逗号列表，拒绝空串与非法项" {
    var out: [8]usize = undefined;
    try testing.expectEqual(@as(usize, 3), try parseIndexList("0, 2 ,5", &out));
    try testing.expectEqualSlices(usize, &.{ 0, 2, 5 }, out[0..3]);

    try testing.expectError(error.Invalid, parseIndexList("", &out));
    try testing.expectError(error.Invalid, parseIndexList("  , ", &out));
    try testing.expectError(error.Invalid, parseIndexList("0,x", &out));
    try testing.expectError(error.Invalid, parseIndexList("-1", &out));

    var tiny: [1]usize = undefined;
    try testing.expectError(error.Invalid, parseIndexList("0,1", &tiny));
}
