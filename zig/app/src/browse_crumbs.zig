//! 面包屑是纯路径切片：不分配、不访问磁盘。下标从 0 开始，0 是文件系统根。
const std = @import("std");

pub fn count(path: []const u8) usize {
    var n: usize = 1;
    var current = path;
    while (std.fs.path.dirname(current)) |parent| {
        if (parent.len == 0 or std.ascii.eqlIgnoreCase(parent, current)) break;
        n += 1;
        current = parent;
    }
    return n;
}

/// 第 index 段对应的完整目录，切片仍指向 path。
pub fn pathAt(path: []const u8, index: usize) ?[]const u8 {
    const n = count(path);
    if (index >= n) return null;
    var current = path;
    var remaining = n - 1 - index;
    while (remaining > 0) : (remaining -= 1) {
        current = std.fs.path.dirname(current) orelse return null;
    }
    return current;
}

pub fn label(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    return if (base.len == 0) path else base;
}

/// 超过四段时只画 `…\parent\current`；slot 1/2 才是可点的真实下标。
pub fn visibleIndex(path: []const u8, slot: usize) ?usize {
    const n = count(path);
    if (n <= 4) return if (slot < n) slot else null;
    if (slot == 0) return null; // 省略号不是目录，不伪造一个跳转目标。
    if (slot == 1) return n - 2;
    if (slot == 2) return n - 1;
    return null;
}

pub fn visibleCount(path: []const u8) usize {
    const n = count(path);
    return if (n <= 4) n else 3;
}

test "面包屑定位与深层截断" {
    const path = "C:\\one\\two\\three\\four\\five";
    try std.testing.expectEqual(@as(usize, 6), count(path));
    try std.testing.expectEqualStrings("C:\\", pathAt(path, 0).?);
    try std.testing.expectEqualStrings("C:\\one\\two", pathAt(path, 2).?);
    try std.testing.expectEqualStrings("four", label(pathAt(path, visibleIndex(path, 1).?).?));
    try std.testing.expectEqualStrings("five", label(pathAt(path, visibleIndex(path, 2).?).?));
    try std.testing.expect(visibleIndex(path, 0) == null);
}
