//! settings.json v2 的 view / layout 值与展开路径集合。
const std = @import("std");

pub const version: u16 = 2;
pub const ViewMode = enum {
    library,
    browse,

    pub fn parse(text: ?[]const u8) ViewMode {
        const value = text orelse return .library;
        if (std.mem.eql(u8, value, "browse")) return .browse;
        return .library;
    }
};

/// 绝对目录路径集合，保插入顺序，写 JSON 因而可复现。
pub const ExpandedFolders = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayListUnmanaged([]const u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) ExpandedFolders {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ExpandedFolders) void {
        for (self.items.items) |path| self.allocator.free(path);
        self.items.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn contains(self: *const ExpandedFolders, path: []const u8) bool {
        for (self.items.items) |item| {
            if (std.mem.eql(u8, item, path)) return true;
        }
        return false;
    }

    pub fn set(self: *ExpandedFolders, path: []const u8, expanded: bool) error{OutOfMemory}!void {
        for (self.items.items, 0..) |item, index| {
            if (!std.mem.eql(u8, item, path)) continue;
            if (expanded) return;
            self.allocator.free(item);
            _ = self.items.orderedRemove(index);
            return;
        }
        if (!expanded or path.len == 0) return;
        const owned = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned);
        try self.items.append(self.allocator, owned);
    }

    /// 返回切换后的状态。路径会先复制，调用方可以随后重建树 arena。
    pub fn toggle(self: *ExpandedFolders, path: []const u8) error{OutOfMemory}!bool {
        const next = !self.contains(path);
        try self.set(path, next);
        return next;
    }
};

pub const View = struct {
    mode: ViewMode = .library,
    expanded_folders: ExpandedFolders,

    pub fn init(allocator: std.mem.Allocator) View {
        return .{ .expanded_folders = ExpandedFolders.init(allocator) };
    }

    pub fn deinit(self: *View) void {
        self.expanded_folders.deinit();
    }
};

pub const Layout = struct {
    width: u32 = 380,
    height: u32 = 700,
};

test "展开集合：复制路径、切换、去重、保序" {
    var expanded = ExpandedFolders.init(std.testing.allocator);
    defer expanded.deinit();
    var path = [_]u8{ 'D', ':', '/', 'a' };
    try expanded.set(&path, true);
    path[3] = 'b';
    try std.testing.expect(expanded.contains("D:/a"));
    try std.testing.expect(!expanded.contains("D:/b"));
    try expanded.set("D:/a", true);
    try std.testing.expectEqual(@as(usize, 1), expanded.items.items.len);
    try expanded.set("D:/c", true);
    try std.testing.expectEqualStrings("D:/a", expanded.items.items[0]);
    try std.testing.expectEqualStrings("D:/c", expanded.items.items[1]);
    try std.testing.expect(!try expanded.toggle("D:/a"));
    try std.testing.expect(!expanded.contains("D:/a"));
}
