//! 库模式的文件夹树：只从 Sample.root_path / relative_path 计算，不读盘。
const std = @import("std");
const core = @import("otto_core");
const settings_v2 = @import("settings_v2.zig");

const none = std.math.maxInt(u32);
pub const RowKind = enum { folder, sample };
pub const Row = struct {
    kind: RowKind,
    name: []const u8,
    path: []const u8,
    depth: u32,
    sample_index: ?usize = null,
    expanded: bool = false,
    has_children: bool = false,
};

const Node = struct {
    kind: RowKind,
    name: []const u8,
    path: []const u8,
    parent: u32 = none,
    depth: u32 = 0,
    sample_index: ?usize = null,
    first_child: u32 = none,
    last_child: u32 = none,
    next_sibling: u32 = none,
};

pub const Tree = struct {
    backing: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    nodes: std.ArrayListUnmanaged(Node) = .empty,
    folders: std.StringHashMapUnmanaged(u32) = .empty,
    seen_paths: std.StringHashMapUnmanaged(void) = .empty,
    rows: std.ArrayListUnmanaged(Row) = .empty,
    root_first: u32 = none,
    root_last: u32 = none,
    expanded: ?*const settings_v2.ExpandedFolders = null,
    /// 最近一次 rebuild 的库视图借用；展开时从同一批路径补建子树，不读盘。
    samples: []const core.model.Sample = &.{},

    pub fn init(backing: std.mem.Allocator) Tree {
        return .{ .backing = backing, .arena = std.heap.ArenaAllocator.init(backing) };
    }

    pub fn deinit(self: *Tree) void {
        self.folders.deinit(self.backing);
        self.seen_paths.deinit(self.backing);
        self.nodes.deinit(self.backing);
        self.rows.deinit(self.backing);
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn setExpanded(self: *Tree, expanded: *const settings_v2.ExpandedFolders) void {
        self.expanded = expanded;
    }

    pub fn len(self: *const Tree) usize {
        return self.rows.items.len;
    }

    pub fn rowAt(self: *const Tree, row: usize) ?Row {
        if (row >= self.rows.items.len) return null;
        return self.rows.items[row];
    }

    pub fn rowOfSample(self: *const Tree, sample_index: usize) ?usize {
        for (self.rows.items, 0..) |row, index| {
            if (row.sample_index == sample_index) return index;
        }
        return null;
    }

    /// 全量重建只发生在库内容变化时；展开/收起只重排可见行。
    pub fn rebuild(self: *Tree, samples: []const core.model.Sample) error{OutOfMemory}!void {
        self.folders.clearRetainingCapacity();
        self.seen_paths.clearRetainingCapacity();
        self.nodes.clearRetainingCapacity();
        self.root_first = none;
        self.root_last = none;
        self.samples = samples;
        _ = self.arena.reset(.retain_capacity);
        for (samples, 0..) |sample, index| {
            if (sample.file_path.len == 0) continue;
            try self.addSample(sample, index);
        }
        try self.refreshVisible();
    }

    pub fn refreshVisible(self: *Tree) error{OutOfMemory}!void {
        self.rows.clearRetainingCapacity();
        var current = self.root_first;
        while (current != none) {
            const node = self.nodes.items[current];
            const is_folder = node.kind == .folder;
            const expanded = is_folder and self.isExpanded(node.path);
            try self.rows.append(self.backing, .{
                .kind = node.kind,
                .name = node.name,
                .path = node.path,
                .depth = node.depth,
                .sample_index = node.sample_index,
                .expanded = expanded,
                .has_children = is_folder and node.first_child != none,
            });
            if (expanded and node.first_child != none) {
                current = node.first_child;
                continue;
            }
            var ascent = current;
            while (true) {
                if (self.nodes.items[ascent].next_sibling != none) {
                    current = self.nodes.items[ascent].next_sibling;
                    break;
                }
                const parent = self.nodes.items[ascent].parent;
                if (parent == none) {
                    current = none;
                    break;
                }
                ascent = parent;
            }
        }
    }

    fn isExpanded(self: *const Tree, path: []const u8) bool {
        const expanded = self.expanded orelse return false;
        return expanded.contains(path);
    }

    fn addSample(self: *Tree, sample: core.model.Sample, sample_index: usize) error{OutOfMemory}!void {
        const inferred = core.sample_location.fromParent(sample.file_path);
        var root = if (sample.rootPath().len > 0) sample.rootPath() else inferred.root_path;
        if (root.len == 0) root = "(未分组)";
        const root_index = try self.ensureFolder(root, rootName(root), none, 0);
        // 收起的根只保留根节点；不可见的子路径不分配、不递归展开，也不做去重哈希。
        if (!self.isExpanded(root)) return;
        if (self.seen_paths.contains(sample.file_path)) return;
        try self.seen_paths.put(self.backing, sample.file_path, {});
        var relative = if (sample.relativePath().len > 0) sample.relativePath() else inferred.relative_path;
        if (relative.len == 0) relative = core.model.baseName(sample.file_path);
        var parent = root_index;
        var parent_path = root;

        var iterator = PathParts{ .text = relative };
        var segment = iterator.next() orelse return;
        while (iterator.next()) |next| {
            const path = try join(self.arena.allocator(), parent_path, segment);
            parent = try self.ensureFolder(path, segment, parent, self.nodes.items[parent].depth + 1);
            parent_path = path;
            segment = next;
        }
        _ = try self.appendNode(.{
            .kind = .sample,
            .name = segment,
            .path = sample.file_path,
            .parent = parent,
            .depth = self.nodes.items[parent].depth + 1,
            .sample_index = sample_index,
        });
    }

    fn ensureFolder(self: *Tree, path: []const u8, name: []const u8, parent: u32, depth: u32) error{OutOfMemory}!u32 {
        if (self.folders.get(path)) |index| return index;
        const key = try self.arena.allocator().dupe(u8, path);
        const index = try self.appendNode(.{
            .kind = .folder,
            .name = name,
            .path = key,
            .parent = parent,
            .depth = depth,
        });
        try self.folders.put(self.backing, key, index);
        return index;
    }

    fn appendNode(self: *Tree, node: Node) error{OutOfMemory}!u32 {
        const index: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(self.backing, node);
        if (node.parent == none) {
            if (self.root_last == none) self.root_first = index else self.nodes.items[self.root_last].next_sibling = index;
            self.root_last = index;
        } else {
            if (self.nodes.items[node.parent].last_child == none) {
                self.nodes.items[node.parent].first_child = index;
            } else {
                self.nodes.items[self.nodes.items[node.parent].last_child].next_sibling = index;
            }
            self.nodes.items[node.parent].last_child = index;
        }
        return index;
    }
};

const PathParts = struct {
    text: []const u8,
    pos: usize = 0,

    fn next(self: *PathParts) ?[]const u8 {
        while (self.pos < self.text.len and isSep(self.text[self.pos])) self.pos += 1;
        if (self.pos == self.text.len) return null;
        const start = self.pos;
        while (self.pos < self.text.len and !isSep(self.text[self.pos])) self.pos += 1;
        return self.text[start..self.pos];
    }
};

fn isSep(char: u8) bool {
    return char == '/' or char == '\\';
}

fn join(allocator: std.mem.Allocator, parent: []const u8, name: []const u8) error{OutOfMemory}![]const u8 {
    if (parent.len > 0 and isSep(parent[parent.len - 1])) return std.fmt.allocPrint(allocator, "{s}{s}", .{ parent, name });
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ parent, name });
}

fn rootName(root: []const u8) []const u8 {
    var trimmed = root;
    while (trimmed.len > 1 and isSep(trimmed[trimmed.len - 1])) trimmed = trimmed[0 .. trimmed.len - 1];
    const name = core.model.baseName(trimmed);
    return if (name.len > 0) name else root;
}

const testing = std.testing;
fn fixtureSample(id: []const u8, path: []const u8, root: []const u8, relative: []const u8) core.model.Sample {
    var result = core.model.Sample{
        .id = id,
        .file_name = core.model.fileNameFromPath(path),
        .file_ext = core.model.fileExtFromPath(path),
        .file_path = path,
    };
    core.sample_location.setBorrowed(&result, root, relative);
    return result;
}

test "树：默认只显示导入根，四层中文/长路径/同名文件逐层准确" {
    const long = "很长的目录名称_0123456789_abcdefghijklmnopqrstuvwxyz_ABCDEFGHIJKLMNOPQRSTUVWXYZ";
    const deep = "一层/二层/三层/" ++ long ++ "/同名.wav";
    const other = "一层/二层/三层/另一目录/同名.wav";
    const samples = [_]core.model.Sample{
        fixtureSample("a", "D:/素材包/一层/二层/三层/" ++ long ++ "/同名.wav", "D:/素材包", deep),
        fixtureSample("b", "D:/素材包/一层/二层/三层/另一目录/同名.wav", "D:/素材包", other),
    };
    var expanded = settings_v2.ExpandedFolders.init(testing.allocator);
    defer expanded.deinit();
    var tree = Tree.init(testing.allocator);
    defer tree.deinit();
    tree.setExpanded(&expanded);
    try tree.rebuild(&samples);
    try testing.expectEqual(@as(usize, 1), tree.len());
    try testing.expectEqual(RowKind.folder, tree.rowAt(0).?.kind);
    try testing.expectEqualStrings("素材包", tree.rowAt(0).?.name);

    const paths = [_][]const u8{
        "D:/素材包",
        "D:/素材包/一层",
        "D:/素材包/一层/二层",
        "D:/素材包/一层/二层/三层",
    };
    const expected_counts = [_]usize{ 2, 3, 4, 6 };
    for (paths, 0..) |path, level| {
        try expanded.set(path, true);
        try tree.rebuild(&samples);
        try testing.expectEqual(expected_counts[level], tree.len());
        try testing.expectEqualStrings(core.model.baseName(path), tree.rowAt(level).?.name);
        try testing.expectEqual(@as(u32, @intCast(level)), tree.rowAt(level).?.depth);
    }
    try expanded.set("D:/素材包/一层/二层/三层/" ++ long, true);
    try expanded.set("D:/素材包/一层/二层/三层/另一目录", true);
    try tree.rebuild(&samples);
    var found: usize = 0;
    for (tree.rows.items) |row| {
        if (row.kind != .sample or !std.mem.eql(u8, row.name, "同名.wav")) continue;
        found += 1;
        try testing.expectEqual(@as(u32, 5), row.depth);
        try testing.expect(std.mem.indexOf(u8, samples[row.sample_index.?].relativePath(), "三层/") != null);
    }
    try testing.expectEqual(@as(usize, 2), found);
}

test "树：同一路径被两个导入根覆盖只出现一次，不同目录同名不合并" {
    const samples = [_]core.model.Sample{
        fixtureSample("first", "D:/a/same.wav", "D:/a", "same.wav"),
        fixtureSample("covered", "D:/a/same.wav", "D:/a", "same.wav"),
        fixtureSample("other", "D:/b/same.wav", "D:/b", "same.wav"),
    };
    var tree = Tree.init(testing.allocator);
    defer tree.deinit();
    var expanded = settings_v2.ExpandedFolders.init(testing.allocator);
    defer expanded.deinit();
    tree.setExpanded(&expanded);
    try tree.rebuild(&samples);
    try expanded.set("D:/a", true);
    try expanded.set("D:/b", true);
    try tree.rebuild(&samples);
    try testing.expectEqual(@as(usize, 4), tree.len()); // 两个根 + 两个不同路径的同名文件。
    try testing.expect(tree.rowOfSample(0) != null);
    try testing.expect(tree.rowOfSample(1) == null);
    try testing.expect(tree.rowOfSample(2) != null);
}
