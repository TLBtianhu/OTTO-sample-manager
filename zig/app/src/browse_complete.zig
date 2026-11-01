//! 地址栏按需补全：只有 Tab 调 `complete` 才枚举；匹配结果缓存到下一次编辑。
//! 连续 Tab / Shift+Tab 只改缓存下标，没有后台搜索、逐键枚举或递归展开。
const std = @import("std");
const browse_dir = @import("otto_browse_dir");
const model = @import("browse_address_model.zig");

pub const State = struct {
    allocator: std.mem.Allocator,
    query: []u8 = &.{},
    matches: std.ArrayListUnmanaged([]u8) = .empty,
    index: ?usize = null,
    enumerations: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) State {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *State) void {
        self.invalidate();
        self.matches.deinit(self.allocator);
    }

    pub fn invalidate(self: *State) void {
        if (self.query.len > 0) self.allocator.free(self.query);
        self.query = &.{};
        for (self.matches.items) |item| self.allocator.free(item);
        self.matches.clearRetainingCapacity();
        self.index = null;
        self.enumerations = 0;
    }

    pub fn noMatches(self: *const State) bool {
        return self.query.len > 0 and self.matches.items.len == 0;
    }

    pub fn current(self: *const State) ?[]const u8 {
        const index = self.index orelse return null;
        if (index >= self.matches.items.len) return null;
        return self.matches.items[index];
    }

    /// 一次用户按键。返回 false 仅表示当前没有匹配；磁盘错误仍具名上抛。
    pub fn complete(self: *State, root: []const u8, editor: *model.Editor, reverse: bool) !bool {
        if (self.index) |index| {
            if (index < self.matches.items.len and std.mem.eql(u8, editor.text(), self.matches.items[index])) {
                self.advance(reverse);
                try editor.set(self.current().?);
                return true;
            }
        } else if (self.query.len > 0 and std.mem.eql(u8, self.query, editor.text())) {
            // 零匹配也缓存：反复 Tab 不会每下都重新列目录。
            return false;
        }

        self.invalidate();
        try self.enumerate(root, editor.text());
        if (self.matches.items.len == 0) return false;
        self.index = if (reverse) self.matches.items.len - 1 else 0;
        try editor.set(self.current().?);
        return true;
    }

    fn advance(self: *State, reverse: bool) void {
        const count = self.matches.items.len;
        const old = self.index orelse 0;
        self.index = if (reverse) (old + count - 1) % count else (old + 1) % count;
    }

    fn enumerate(self: *State, root: []const u8, input: []const u8) !void {
        self.query = try self.allocator.dupe(u8, input);
        errdefer self.invalidate();
        const split = std.mem.lastIndexOfAny(u8, input, "\\/");
        const parent_display = if (split) |at| input[0 .. at + 1] else "";
        const prefix = if (split) |at| input[at + 1 ..] else input;
        const parent = if (split == null)
            try self.allocator.dupe(u8, root)
        else
            try std.fs.path.resolveAlloc(self.allocator, &.{ root, parent_display });
        defer self.allocator.free(parent);

        self.enumerations += 1;
        var iterator = try browse_dir.Iterator.open(self.allocator, parent);
        defer iterator.close();
        while (try iterator.next()) |entry| {
            if (!entry.isDirectory() or !std.ascii.startsWithIgnoreCase(entry.name, prefix)) continue;
            const completed = try std.fmt.allocPrint(self.allocator, "{s}{s}\\", .{ parent_display, entry.name });
            errdefer self.allocator.free(completed);
            try self.matches.append(self.allocator, completed);
        }
        std.mem.sort([]u8, self.matches.items, {}, lessThan);
    }
};

fn lessThan(_: void, a: []u8, b: []u8) bool {
    return std.ascii.lessThanIgnoreCase(a, b);
}

test "Tab 只枚举父目录一次，只补目录，正反向循环且零匹配也缓存" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "sub-b");
    try tmp.dir.createDirPath(std.testing.io, "sub-a");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "sub-file.txt", .data = "not a target" });
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &buffer);
    const root = buffer[0..len];

    var editor = model.Editor{};
    editor.begin(root);
    try editor.set("su");
    var state = State.init(std.testing.allocator);
    defer state.deinit();
    try std.testing.expect(try state.complete(root, &editor, false));
    try std.testing.expectEqualStrings("sub-a\\", editor.text());
    try std.testing.expectEqual(@as(usize, 2), state.matches.items.len);
    try std.testing.expectEqual(@as(u32, 1), state.enumerations);
    _ = try state.complete(root, &editor, false);
    try std.testing.expectEqualStrings("sub-b\\", editor.text());
    _ = try state.complete(root, &editor, false);
    try std.testing.expectEqualStrings("sub-a\\", editor.text());
    _ = try state.complete(root, &editor, true);
    try std.testing.expectEqualStrings("sub-b\\", editor.text());
    try std.testing.expectEqual(@as(u32, 1), state.enumerations);

    state.invalidate();
    try editor.set("nothing-");
    try std.testing.expect(!(try state.complete(root, &editor, false)));
    try std.testing.expect(state.noMatches());
    try std.testing.expect(!(try state.complete(root, &editor, false)));
    try std.testing.expectEqual(@as(u32, 1), state.enumerations);
}
