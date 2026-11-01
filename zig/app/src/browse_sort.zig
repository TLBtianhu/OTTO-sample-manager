//! 浏览列表排序：一次 O(n log n) 的原地排序，目录分组优先于用户键。
//! 不在每个枚举批次里反复排序；Session 在页/事件批收尾时调用一次。

const std = @import("std");
const types = @import("browse_types.zig");

pub const Key = enum {
    name,
    size,
    mtime,
    type,

    pub fn label(self: Key) []const u8 {
        return switch (self) {
            .name => "名称",
            .size => "大小",
            .mtime => "修改时间",
            .type => "类型",
        };
    }

    pub fn text(self: Key) []const u8 {
        return @tagName(self);
    }

    pub fn parse(value: []const u8) ?Key {
        if (std.mem.eql(u8, value, "name")) return .name;
        if (std.mem.eql(u8, value, "size")) return .size;
        if (std.mem.eql(u8, value, "mtime")) return .mtime;
        if (std.mem.eql(u8, value, "type")) return .type;
        return null;
    }

    pub fn next(self: Key) Key {
        return switch (self) {
            .name => .size,
            .size => .mtime,
            .mtime => .type,
            .type => .name,
        };
    }
};

pub fn entries(items: []types.Entry, key: Key) void {
    std.mem.sort(types.Entry, items, key, lessThan);
}

fn lessThan(key: Key, a: types.Entry, b: types.Entry) bool {
    return compare(key, a, b) == .lt;
}

fn compare(key: Key, a: types.Entry, b: types.Entry) std.math.Order {
    if (a.is_directory != b.is_directory) {
        return if (a.is_directory) .lt else .gt;
    }
    const primary = switch (key) {
        .name => compareText(base(a.path), base(b.path)),
        .size => std.math.order(a.size, b.size),
        .mtime => std.math.order(a.mtime, b.mtime),
        .type => if (a.is_directory) .eq else compareText(std.fs.path.extension(a.path), std.fs.path.extension(b.path)),
    };
    if (primary != .eq) return primary;
    const names = compareText(base(a.path), base(b.path));
    if (names != .eq) return names;
    return std.mem.order(u8, a.path, b.path);
}

fn base(path: []const u8) []const u8 {
    return std.fs.path.basename(path);
}

fn compareText(a: []const u8, b: []const u8) std.math.Order {
    const count = @min(a.len, b.len);
    for (a[0..count], b[0..count]) |left, right| {
        const la = std.ascii.toLower(left);
        const lb = std.ascii.toLower(right);
        if (la < lb) return .lt;
        if (la > lb) return .gt;
    }
    return std.math.order(a.len, b.len);
}

test "四种排序都保持目录在前，名称与大小升序正确" {
    var items = [_]types.Entry{
        .{ .path = @constCast("C:\\z.wav"), .size = 2, .mtime = 9 },
        .{ .path = @constCast("C:\\sub"), .size = 0, .mtime = 1, .is_directory = true },
        .{ .path = @constCast("C:\\a.mp3"), .size = 8, .mtime = 3 },
        .{ .path = @constCast("C:\\b.wav"), .size = 1, .mtime = 4 },
    };
    entries(&items, .name);
    try std.testing.expect(items[0].is_directory);
    try std.testing.expectEqualStrings("C:\\a.mp3", items[1].path);
    entries(&items, .size);
    try std.testing.expect(items[0].is_directory);
    try std.testing.expectEqual(@as(u64, 1), items[1].size);
    entries(&items, .mtime);
    try std.testing.expect(items[0].is_directory);
    try std.testing.expectEqual(@as(i64, 3), items[1].mtime);
    entries(&items, .type);
    try std.testing.expect(items[0].is_directory);
    try std.testing.expectEqualStrings(".mp3", std.fs.path.extension(items[1].path));
    try std.testing.expectEqual(@as(?Key, .size), Key.parse("size"));
}
