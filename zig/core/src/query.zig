//! 查询层：按目录（含子目录递归）、按分组、按文件名子串过滤。
//!
//! 与现有 UI 的行为对齐：
//! * 目录过滤使用 `folder.sample_ids` + `child_folder_ids` 递归（src/store/sampleStore.ts 的
//!   descendantSampleIdsByFolder），而不是只读 sample.folderId；
//! * 分组过滤使用 `sample.group_ids`（与 App.tsx 的 activeGroupId 过滤一致）；
//! * 文件名只做 ASCII 大小写不敏感的子串匹配，拼音搜索尚未实现；
//! * 默认按 importedAt 升序（现有应用无搜索词时的排序）。
//!
//! 返回的切片由调用方负责释放（`allocator.free(result)`），切片内的 Sample 是浅拷贝，
//! 字符串仍属于 Library 的 arena，Library 释放后不可再使用。

const std = @import("std");
const model = @import("model.zig");
const store = @import("store.zig");

pub const QueryError = error{OutOfMemory};

pub const Sort = enum {
    /// 保持样本在 JSON / 内存中的顺序。
    library_order,
    /// importedAt 升序，id 作为次级键；默认值。
    imported_at,
    /// 文件名大小写不敏感排序，id 作为次级键。
    file_name,
};

pub const Filter = struct {
    folder_id: ?[]const u8 = null,
    /// 为 true 时包含所有后代目录；false 时只看该目录自身。
    include_subfolders: bool = true,
    group_id: ?[]const u8 = null,
    /// 文件名子串（ASCII 大小写不敏感）。空串等价于不过滤。
    name_contains: ?[]const u8 = null,
    sort: Sort = .imported_at,
};

/// 按组合条件查询，返回调用方拥有的切片。
pub fn apply(
    backing: std.mem.Allocator,
    library: *const store.Library,
    filter: Filter,
) QueryError![]const model.Sample {
    var scratch_arena = std.heap.ArenaAllocator.init(backing);
    defer scratch_arena.deinit();
    const scratch = scratch_arena.allocator();

    var folder_samples = std.StringHashMapUnmanaged(void){};
    if (filter.folder_id) |folder_id| {
        try collectFolderSampleIds(scratch, library, folder_id, filter.include_subfolders, &folder_samples);
    }

    var result: std.ArrayList(model.Sample) = .empty;
    errdefer result.deinit(backing);

    for (library.samples) |sample| {
        if (filter.folder_id != null and !folder_samples.contains(sample.id)) continue;
        if (filter.group_id) |group_id| {
            if (!sample.inGroup(group_id)) continue;
        }
        if (filter.name_contains) |needle| {
            if (!containsIgnoreCase(sample.file_name, needle)) continue;
        }
        try result.append(backing, sample);
    }

    sortSamples(result.items, filter.sort);
    return result.toOwnedSlice(backing);
}

pub fn byFolder(
    backing: std.mem.Allocator,
    library: *const store.Library,
    folder_id: []const u8,
    include_subfolders: bool,
) QueryError![]const model.Sample {
    return apply(backing, library, .{
        .folder_id = folder_id,
        .include_subfolders = include_subfolders,
    });
}

pub fn byGroup(
    backing: std.mem.Allocator,
    library: *const store.Library,
    group_id: []const u8,
) QueryError![]const model.Sample {
    return apply(backing, library, .{ .group_id = group_id });
}

pub fn byFileName(
    backing: std.mem.Allocator,
    library: *const store.Library,
    needle: []const u8,
) QueryError![]const model.Sample {
    return apply(backing, library, .{ .name_contains = needle });
}

/// 返回 root_id 及其全部后代目录 id（先序、去重、环安全）。未知目录返回只含自身的列表。
pub fn folderSubtreeIds(
    backing: std.mem.Allocator,
    library: *const store.Library,
    root_id: []const u8,
) QueryError![]const []const u8 {
    var scratch_arena = std.heap.ArenaAllocator.init(backing);
    defer scratch_arena.deinit();
    const scratch = scratch_arena.allocator();

    var result: std.ArrayList([]const u8) = .empty;
    errdefer result.deinit(backing);
    var stack: std.ArrayList([]const u8) = .empty;
    defer stack.deinit(scratch);
    var visited = std.StringHashMapUnmanaged(void){};

    try stack.append(scratch, root_id);
    while (stack.pop()) |folder_id| {
        if (visited.contains(folder_id)) continue;
        try visited.put(scratch, folder_id, {});
        try result.append(backing, folder_id);

        const folder = library.folderById(folder_id) orelse continue;
        var index = folder.child_folder_ids.len;
        while (index > 0) {
            index -= 1;
            if (!visited.contains(folder.child_folder_ids[index])) {
                try stack.append(scratch, folder.child_folder_ids[index]);
            }
        }
    }

    return result.toOwnedSlice(backing);
}

/// 收集目录子树里的 sample id 集合。
/// 用一个显式栈 + visited 集合，损坏的 parent/child 环不会导致无限递归。
fn collectFolderSampleIds(
    scratch: std.mem.Allocator,
    library: *const store.Library,
    root_id: []const u8,
    include_subfolders: bool,
    out: *std.StringHashMapUnmanaged(void),
) QueryError!void {
    var stack: std.ArrayList([]const u8) = .empty;
    defer stack.deinit(scratch);
    var visited = std.StringHashMapUnmanaged(void){};

    try stack.append(scratch, root_id);
    while (stack.pop()) |folder_id| {
        if (visited.contains(folder_id)) continue;
        try visited.put(scratch, folder_id, {});

        const folder = library.folderById(folder_id) orelse continue;
        for (folder.sample_ids) |sample_id| {
            if (out.contains(sample_id)) continue;
            try out.put(scratch, sample_id, {});
        }
        if (!include_subfolders) continue;
        for (folder.child_folder_ids) |child_id| {
            if (!visited.contains(child_id)) try stack.append(scratch, child_id);
        }
    }
}

/// ASCII 大小写不敏感的字节子串匹配。
/// 非 ASCII 字节（例如中文 UTF-8）原样比较，所以「循环」也能正常命中。
pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}

fn sortSamples(samples: []model.Sample, sort: Sort) void {
    switch (sort) {
        .library_order => {},
        .imported_at => std.mem.sort(model.Sample, samples, {}, lessByImportedAt),
        .file_name => std.mem.sort(model.Sample, samples, {}, lessByFileName),
    }
}

fn lessByImportedAt(_: void, left: model.Sample, right: model.Sample) bool {
    if (left.imported_at != right.imported_at) return left.imported_at < right.imported_at;
    return std.mem.lessThan(u8, left.id, right.id);
}

fn lessByFileName(_: void, left: model.Sample, right: model.Sample) bool {
    switch (compareIgnoreCase(left.file_name, right.file_name)) {
        .lt => return true,
        .gt => return false,
        .eq => return std.mem.lessThan(u8, left.id, right.id),
    }
}

fn compareIgnoreCase(left: []const u8, right: []const u8) std.math.Order {
    const shared = @min(left.len, right.len);
    var index: usize = 0;
    while (index < shared) : (index += 1) {
        const a = std.ascii.toLower(left[index]);
        const b = std.ascii.toLower(right[index]);
        if (a != b) return if (a < b) .lt else .gt;
    }
    if (left.len == right.len) return .eq;
    return if (left.len < right.len) .lt else .gt;
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const subfolder_json =
    \\{
    \\  "samples": {
    \\    "s_root": {"fileName": "Root Loop", "folderId": "f_root", "importedAt": 10},
    \\    "s_a": {"fileName": "Kick A", "folderId": "f_a", "importedAt": 20, "groupIds": ["g1"]},
    \\    "s_a1": {"fileName": "Snare A1", "folderId": "f_a1", "importedAt": 30},
    \\    "s_b": {"fileName": "Bass B", "folderId": "f_b", "importedAt": 40}
    \\  },
    \\  "groups": {"g1": {"id": "g1", "name": "Drums"}},
    \\  "folderState": {
    \\    "folders": {
    \\      "f_root": {"id": "f_root", "name": "lib", "childFolderIds": ["f_a", "f_b"], "parentId": null},
    \\      "f_a": {"id": "f_a", "name": "A", "childFolderIds": ["f_a1"], "parentId": "f_root"},
    \\      "f_a1": {"id": "f_a1", "name": "A1", "parentId": "f_a"},
    \\      "f_b": {"id": "f_b", "name": "B", "parentId": "f_root"}
    \\    },
    \\    "folderOrder": ["f_root"]
    \\  }
    \\}
;

fn expectIds(expected: []const []const u8, samples: []const model.Sample) !void {
    try std.testing.expectEqual(expected.len, samples.len);
    for (expected, 0..) |id, index| {
        try std.testing.expectEqualStrings(id, samples[index].id);
    }
}

test "按目录递归过滤" {
    var library = try store.load(std.testing.allocator, subfolder_json);
    defer library.deinit();

    const all = try byFolder(std.testing.allocator, &library, "f_root", true);
    defer std.testing.allocator.free(all);
    try expectIds(&.{ "s_root", "s_a", "s_a1", "s_b" }, all);

    const shallow = try byFolder(std.testing.allocator, &library, "f_root", false);
    defer std.testing.allocator.free(shallow);
    try expectIds(&.{"s_root"}, shallow);

    const nested = try byFolder(std.testing.allocator, &library, "f_a", true);
    defer std.testing.allocator.free(nested);
    try expectIds(&.{ "s_a", "s_a1" }, nested);

    const unknown = try byFolder(std.testing.allocator, &library, "f_missing", true);
    defer std.testing.allocator.free(unknown);
    try std.testing.expectEqual(@as(usize, 0), unknown.len);
}

test "按分组与文件名过滤" {
    var library = try store.load(std.testing.allocator, subfolder_json);
    defer library.deinit();

    const grouped = try byGroup(std.testing.allocator, &library, "g1");
    defer std.testing.allocator.free(grouped);
    try expectIds(&.{"s_a"}, grouped);

    const case_insensitive = try byFileName(std.testing.allocator, &library, "kIcK");
    defer std.testing.allocator.free(case_insensitive);
    try expectIds(&.{"s_a"}, case_insensitive);

    const combined = try apply(std.testing.allocator, &library, .{
        .folder_id = "f_root",
        .group_id = "g1",
        .name_contains = "kick",
    });
    defer std.testing.allocator.free(combined);
    try expectIds(&.{"s_a"}, combined);

    const empty_needle = try byFileName(std.testing.allocator, &library, "");
    defer std.testing.allocator.free(empty_needle);
    try std.testing.expectEqual(@as(usize, 4), empty_needle.len);
}

test "containsIgnoreCase 支持中文与空串" {
    try std.testing.expect(containsIgnoreCase("Kick 01", "kIcK"));
    try std.testing.expect(containsIgnoreCase("鼓组 循环 01", "循环"));
    try std.testing.expect(!containsIgnoreCase("Kick", "snare"));
    try std.testing.expect(containsIgnoreCase("Kick", ""));
    try std.testing.expect(!containsIgnoreCase("", "kick"));
}

test "目录环不会让递归查询死循环" {
    const json =
        \\{
        \\  "samples": {"s1": {"fileName": "Kick", "folderId": "fa", "importedAt": 1}},
        \\  "folderState": {"folders": {
        \\    "fa": {"id": "fa", "childFolderIds": ["fb"], "parentId": "fb"},
        \\    "fb": {"id": "fb", "childFolderIds": ["fa"], "parentId": "fa"}
        \\  }}
        \\}
    ;
    var library = try store.load(std.testing.allocator, json);
    defer library.deinit();

    const subtree = try folderSubtreeIds(std.testing.allocator, &library, "fa");
    defer std.testing.allocator.free(subtree);
    try std.testing.expectEqual(@as(usize, 2), subtree.len);

    const hits = try byFolder(std.testing.allocator, &library, "fa", true);
    defer std.testing.allocator.free(hits);
    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectEqualStrings("s1", hits[0].id);
}
