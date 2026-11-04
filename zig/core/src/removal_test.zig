const std = @import("std");
const model = @import("model.zig");
const store = @import("store.zig");
const binary = @import("library_binary.zig");
const removal = @import("removal.zig");
const index_mod = @import("index.zig");
const rescan = @import("rescan.zig");

const fixture =
    \\{
    \\ "samples": {
    \\  "s1": {"fileName":"a","filePath":"D:/pack/root/a.wav","folderId":"root","groupIds":["g"],"identity":{"volumeSerial":7,"fileIndex":101}},
    \\  "s2": {"fileName":"b","filePath":"D:/pack/root/sub/b.wav","folderId":"sub"},
    \\  "s3": {"fileName":"c","filePath":"D:/pack/root/sub/deep/c.wav","folderId":"deep"},
    \\  "s4": {"fileName":"keep","filePath":"D:/pack/other/keep.wav","folderId":"other"}
    \\ },
    \\ "groups":{"g":{"name":"G"}},
    \\ "folderState":{"folders":{
    \\  "root":{"path":"D:/pack/root","childFolderIds":["sub"]},
    \\  "sub":{"path":"D:/pack/root/sub","parentId":"root","childFolderIds":["deep"]},
    \\  "deep":{"path":"D:/pack/root/sub/deep","parentId":"sub"},
    \\  "other":{"path":"D:/pack/other"}
    \\ },"folderOrder":["root","other"]}
    \\}
;

fn load() !store.Library {
    return store.load(std.testing.allocator, fixture);
}

test "多选按 Sample.id 移除，与目标顺序和行号无关" {
    var base = try load();
    defer base.deinit();
    var result = try removal.apply(std.testing.allocator, &base, &.{
        .{ .sample_id = "s3" },
        .{ .sample_id = "s1" },
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.report.samples);
    try std.testing.expectEqual(@as(usize, 2), result.library.samples.len);
    try std.testing.expectEqualStrings("s2", result.library.samples[0].id);
    try std.testing.expectEqualStrings("s4", result.library.samples[1].id);
    try std.testing.expect(result.library.sampleById("s1") == null);
    try std.testing.expect(result.library.sampleById("s3") == null);
    try std.testing.expectEqual(@as(usize, 0), result.library.groupById("g").?.sample_ids.len);
    try std.testing.expectEqual(@as(usize, 2), result.library.exclusions.len);
    try std.testing.expect(result.library.isExcluded("D:/pack/root/a.wav", null));
    try std.testing.expect(result.library.isExcluded("D:/elsewhere/a.wav", .{ .volume_serial = 7, .file_index = 101 }));
}

test "目录递归移除样本与目录记录，保留兄弟并闭合引用" {
    var base = try load();
    defer base.deinit();
    var result = try removal.apply(std.testing.allocator, &base, &.{.{ .folder_path = "D:/pack/root/sub" }});
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.report.samples);
    try std.testing.expectEqual(@as(usize, 2), result.report.folders);
    try std.testing.expectEqual(@as(usize, 2), result.library.samples.len);
    try std.testing.expect(result.library.folderById("sub") == null);
    try std.testing.expect(result.library.folderById("deep") == null);
    try std.testing.expectEqual(@as(usize, 0), result.library.folderById("root").?.child_folder_ids.len);
    try std.testing.expectEqual(@as(usize, 1), result.library.exclusions.len);
    try std.testing.expect(result.library.isExcluded("D:/pack/root/sub/new.wav", null));
    try std.testing.expect(!result.library.isExcluded("D:/pack/root/submarine.wav", null));
}

test "v2 排除记录往返后，重启/监听/重扫均不复活" {
    var base = try load();
    defer base.deinit();
    var removed = try removal.apply(std.testing.allocator, &base, &.{
        .{ .sample_id = "s1" },
        .{ .folder_path = "D:/pack/root/sub" },
    });
    defer removed.deinit();

    const bytes = try binary.encode(std.testing.allocator, &removed.library);
    defer std.testing.allocator.free(bytes);
    var restarted = try binary.decode(std.testing.allocator, bytes);
    defer restarted.deinit();
    try std.testing.expectEqual(@as(usize, 2), restarted.exclusions.len);
    var file_tombstone: ?model.Exclusion = null;
    for (restarted.exclusions) |item| {
        if (item.kind == .file) file_tombstone = item;
    }
    try std.testing.expectEqual(@as(u64, 101), file_tombstone.?.identity.?.file_index);

    var view = try index_mod.Index.init(std.testing.allocator, &restarted);
    defer view.deinit();
    const before = view.samples().len;
    const events = try view.apply(&.{
        .{ .created = "D:/pack/root/a.wav" },
        .{ .created = "D:/pack/root/sub/new.wav" },
        .{ .renamed = .{ .from = "D:/pack/root/a.wav", .to = "D:/pack/renamed.wav" } },
    });
    try std.testing.expectEqual(@as(usize, 0), events.added);
    try std.testing.expectEqual(before, view.samples().len);

    const fresh = [_]rescan.ScanEntry{
        .{ .path = "D:/pack/renamed.wav", .name = "renamed.wav", .ext = ".wav", .size = 1, .mtime = 2, .identity = .{ .volume_serial = 7, .file_index = 101 } },
        .{ .path = "D:/pack/root/sub/new.wav", .name = "new.wav", .ext = ".wav", .size = 1, .mtime = 2 },
        .{ .path = "D:/pack/other/keep.wav", .name = "keep.wav", .ext = ".wav", .size = 0, .mtime = 0 },
        .{ .path = "D:/pack/new.wav", .name = "new.wav", .ext = ".wav", .size = 1, .mtime = 2 },
    };
    var difference = try rescan.diffExcluding(std.testing.allocator, view.samples(), &fresh, restarted.exclusions);
    defer difference.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), difference.added.len);
    const applied = try view.applyRescan(difference, &fresh);
    try std.testing.expectEqual(@as(usize, 1), applied.added);
    try std.testing.expectEqual(before + 1, view.samples().len);
    try std.testing.expectEqualStrings("D:/pack/new.wav", view.samples()[view.samples().len - 1].file_path);
}

test "显式恢复只清匹配墓碑，身份与目录前缀遵循同一规则" {
    var base = try load();
    defer base.deinit();
    var removed = try removal.apply(std.testing.allocator, &base, &.{
        .{ .sample_id = "s1" },
        .{ .folder_path = "D:/pack/root/sub" },
    });
    defer removed.deinit();
    try std.testing.expectEqual(@as(usize, 2), removed.library.exclusions.len);

    const unrelated = try removed.library.clearExclusionsFor("D:/unrelated.wav", null);
    try std.testing.expectEqual(@as(usize, 0), unrelated);
    const by_identity = try removed.library.clearExclusionsFor("D:/renamed/a.wav", .{ .volume_serial = 7, .file_index = 101 });
    try std.testing.expectEqual(@as(usize, 1), by_identity);
    try std.testing.expectEqual(@as(usize, 1), removed.library.exclusions.len);
    try std.testing.expectEqual(model.Exclusion.Kind.folder, removed.library.exclusions[0].kind);

    const by_folder = try removed.library.clearExclusionsFor("D:/pack/root/sub/deep/new.wav", null);
    try std.testing.expectEqual(@as(usize, 1), by_folder);
    try std.testing.expectEqual(@as(usize, 0), removed.library.exclusions.len);
}
