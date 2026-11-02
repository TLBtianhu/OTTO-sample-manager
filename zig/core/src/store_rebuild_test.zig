//! Index 收集器与 Library 业务快照的语义边界及 created 重建测试。
const std = @import("std");
const model = @import("model.zig");
const store = @import("store.zig");
const store_rebuild = @import("store_rebuild.zig");
const index = @import("index.zig");
const query = @import("query.zig");

const fixture =
    \\{
    \\  "samples": {
    \\    "old": {"id":"old","fileName":"old","fileExt":".wav","filePath":"D:/lib/old.wav","folderId":"f_root","groupIds":["g1"]}
    \\  },
    \\  "groups": {"g1":{"id":"g1","name":"既有分组","sampleIds":["old"]}},
    \\  "folderState": {"folders": {
    \\    "f_root":{"id":"f_root","name":"lib","path":"D:/lib","sampleIds":["old"],"parentId":null}
    \\  },"folderOrder":["f_root"]}
    \\}
;

test "Index 收集 created：查询读旧快照，显式重建补目录且保留分组" {
    var base = try store.load(std.testing.allocator, fixture);
    defer base.deinit();
    var view = try index.Index.init(std.testing.allocator, &base);
    defer view.deinit();

    _ = try view.apply(&.{.{ .created = "D:/lib/sub/new.wav" }});
    const created = view.samples()[view.samples().len - 1];
    // 监听口岸：已有导入根 D:/lib，不能把 sub 误当新根。
    try std.testing.expectEqualStrings("D:/lib", created.rootPath());
    try std.testing.expectEqualStrings("sub/new.wav", created.relativePath());
    // 收集器的临时关系状态：目录缓存尚未重建，没有擅自加入任何分组。
    try std.testing.expect(created.folder_id == null);
    try std.testing.expectEqual(@as(usize, 0), created.group_ids.len);

    const before = try query.byFileName(std.testing.allocator, &base, "new");
    defer std.testing.allocator.free(before);
    try std.testing.expectEqual(@as(usize, 0), before.len);
    try std.testing.expectEqual(@as(usize, 2), view.samples().len);

    var rebuilt = try store_rebuild.rebuild(std.testing.allocator, &base, view.samples());
    defer rebuilt.deinit();
    const persisted = rebuilt.sampleById(created.id).?;
    try std.testing.expectEqualStrings("D:/lib", persisted.rootPath());
    try std.testing.expectEqualStrings("sub/new.wav", persisted.relativePath());
    try std.testing.expectEqualStrings("folder_D:/lib/sub", persisted.folder_id.?);
    try std.testing.expectEqual(@as(usize, 0), persisted.group_ids.len);
    const folder = rebuilt.folderById("folder_D:/lib/sub").?;
    try std.testing.expectEqual(@as(usize, 1), folder.sample_ids.len);
    try std.testing.expectEqualStrings(created.id, folder.sample_ids[0]);

    const after = try query.byFileName(std.testing.allocator, &rebuilt, "new");
    defer std.testing.allocator.free(after);
    try std.testing.expectEqual(@as(usize, 1), after.len);
    try std.testing.expectEqualStrings(created.id, after[0].id);
    const in_folder = try query.byFolder(std.testing.allocator, &rebuilt, folder.id, false);
    defer std.testing.allocator.free(in_folder);
    try std.testing.expectEqual(@as(usize, 1), in_folder.len);

    // created 没有用户分组，不凭空加组；旧分组及旧成员一条不少。
    const grouped = try query.byGroup(std.testing.allocator, &rebuilt, "g1");
    defer std.testing.allocator.free(grouped);
    try std.testing.expectEqual(@as(usize, 1), grouped.len);
    try std.testing.expectEqualStrings("old", grouped[0].id);
    try std.testing.expectEqualStrings("old", rebuilt.groupById("g1").?.sample_ids[0]);
    // 原快照也未被重建顺手改写。
    try std.testing.expectEqual(@as(usize, 1), base.samples.len);
}

test "created 根匹配取最长前缀；没有已有根才退父目录" {
    const samples = [_]model.Sample{
        .{ .id = "outer", .file_name = "a", .file_ext = ".wav", .file_path = "D:/lib/a.wav", .root_path = 6, .relative_path = 7 },
        .{ .id = "inner", .file_name = "b", .file_ext = ".wav", .file_path = "D:/lib/sub/b.wav", .root_path = 10, .relative_path = 11 },
    };
    const nested = @import("sample_location.zig").inferFromLibrary("D:/lib/sub/deep/new.wav", &samples);
    try std.testing.expectEqualStrings("D:/lib/sub", nested.root_path);
    try std.testing.expectEqualStrings("deep/new.wav", nested.relative_path);
    const fallback = @import("sample_location.zig").inferFromLibrary("E:/free/new.wav", &samples);
    try std.testing.expectEqualStrings("E:/free", fallback.root_path);
    try std.testing.expectEqualStrings("new.wav", fallback.relative_path);
}
