//! store.zig 的单元测试（从 store.zig 拆出，保持单文件行数可控）。
//! 全部使用内联合成 JSON，不依赖 fixtures/ 与磁盘。

const std = @import("std");
const store = @import("store.zig");

test "缺字段的旧数据补默认值" {
    const text =
        \\{
        \\  "samples": {
        \\    "legacy_1": {"filePath": "D:/packs/Kick 01.wav", "duration": 0.5},
        \\    "legacy_2": {"id": "kept_id", "filePath": "D:/packs/Snare.wav"}
        \\  }
        \\}
    ;
    var library = try store.load(std.testing.allocator, text);
    defer library.deinit();

    try std.testing.expectEqual(@as(usize, 2), library.samples.len);
    const first = library.sampleById("legacy_1").?;
    try std.testing.expectEqualStrings("Kick 01", first.file_name);
    try std.testing.expectEqualStrings(".wav", first.file_ext);
    // 旧数据没有 folderId：按 filePath 目录补出扁平目录（与 App.tsx 的 rebuildFolderMembership 一致）。
    try std.testing.expectEqualStrings("folder_D:/packs", first.folder_id.?);
    try std.testing.expectEqual(@as(usize, 0), first.group_ids.len);
    try std.testing.expectEqualStrings("legacy_1", first.original_id);
    try std.testing.expect(!first.is_copy);
    try std.testing.expect(first.duration == 0.5);
    try std.testing.expectEqual(@as(usize, 1), library.report.synthesized_folders);
    try std.testing.expectEqual(@as(usize, 2), library.report.rebuilt_folder_memberships);

    const second = library.sampleById("kept_id").?;
    try std.testing.expectEqualStrings("folder_D:/packs", second.folder_id.?);
    try std.testing.expectEqualStrings("kept_id", second.original_id);
}

test "悬空引用被清理并计数" {
    const text =
        \\{
        \\  "samples": {
        \\    "s1": {"id": "s1", "fileName": "Kick", "filePath": "D:/a/Kick.wav", "folderId": "f_missing", "groupIds": ["g_missing", "g1"]}
        \\  },
        \\  "groups": {"g1": {"id": "g1", "name": "G1", "sampleIds": ["s1", "ghost"]}},
        \\  "folderState": {
        \\    "folders": {"f1": {"id": "f1", "path": "D:/a", "sampleIds": ["s1", "ghost"], "parentId": null}},
        \\    "folderOrder": ["f1"]
        \\  }
        \\}
    ;
    var library = try store.load(std.testing.allocator, text);
    defer library.deinit();

    try std.testing.expectEqualStrings("folder_D:/a", library.samples[0].folder_id.?);
    try std.testing.expectEqual(@as(usize, 1), library.report.dangling_sample_folders);
    try std.testing.expectEqual(@as(usize, 1), library.report.dangling_sample_groups);
    try std.testing.expectEqual(@as(usize, 1), library.report.dangling_folder_samples);
    try std.testing.expectEqual(@as(usize, 1), library.report.dangling_group_samples);
    try std.testing.expectEqual(@as(usize, 1), library.report.synthesized_folders);
    try std.testing.expectEqual(@as(usize, 1), library.report.rebuilt_folder_memberships);
    // f1 里的 s1 与 sample.folderId 不一致，按 App 规则丢弃。
    try std.testing.expectEqual(@as(usize, 1), library.report.replaced_folder_memberships);
    try std.testing.expectEqual(@as(usize, 2), library.folders.len);
    try std.testing.expectEqual(@as(usize, 1), library.folderById("folder_D:/a").?.sample_ids.len);
    try std.testing.expectEqualStrings("s1", library.folderById("folder_D:/a").?.sample_ids[0]);
    try std.testing.expectEqual(@as(usize, 2), library.folder_order.len);
    try std.testing.expectEqualStrings("folder_D:/a", library.folder_order[1]);
    try std.testing.expectEqual(@as(usize, 1), library.groups[0].sample_ids.len);
    try std.testing.expectEqualStrings("g1", library.samples[0].group_ids[0]);
}

test "重复 id 去重" {
    const text =
        \\{
        \\  "samples": {
        \\    "key_a": {"id": "dup", "fileName": "First", "filePath": "D:/a.wav"},
        \\    "key_b": {"id": "dup", "fileName": "Second", "filePath": "D:/b.wav"}
        \\  },
        \\  "groups": {"g1": {"id": "g1", "name": "G1", "sampleIds": ["dup", "dup"]}}
        \\}
    ;
    var library = try store.load(std.testing.allocator, text);
    defer library.deinit();

    try std.testing.expectEqual(@as(usize, 1), library.samples.len);
    try std.testing.expectEqualStrings("First", library.samples[0].file_name);
    try std.testing.expectEqual(@as(usize, 1), library.report.duplicate_samples);
    try std.testing.expectEqual(@as(usize, 2), library.report.id_key_mismatches);
    try std.testing.expectEqual(@as(usize, 1), library.groups[0].sample_ids.len);
}

test "非法 JSON 与错误结构" {
    try std.testing.expectError(error.InvalidJson, store.load(std.testing.allocator, "{"));
    try std.testing.expectError(error.UnsupportedSchema, store.load(std.testing.allocator, "[]"));
    try std.testing.expectError(error.UnsupportedSchema, store.load(std.testing.allocator, "{\"samples\": []}"));
}

test "settings 默认值与覆盖" {
    var defaults = try store.load(std.testing.allocator, "{}");
    defer defaults.deinit();
    try std.testing.expect(defaults.settings.window.always_on_top);
    try std.testing.expectEqual(@as(u32, 380), defaults.settings.window.width);
    try std.testing.expect(defaults.settings.copy.enable_auto_copy);
    try std.testing.expect(defaults.settings.folder.expand_on_search);
    try std.testing.expectEqual(@as(usize, 0), defaults.folder_order.len);

    const text =
        \\{
        \\  "settings": {"windowAlwaysOnTop": false, "windowWidth": 500, "windowX": 12},
        \\  "copySettings": {"keepCopies": true},
        \\  "folderSettings": {"enableChinesePinyinFuzzySearch": true},
        \\  "groupOrder": ["g_missing"]
        \\}
    ;
    var custom = try store.load(std.testing.allocator, text);
    defer custom.deinit();
    try std.testing.expect(!custom.settings.window.always_on_top);
    try std.testing.expectEqual(@as(u32, 500), custom.settings.window.width);
    try std.testing.expectEqual(@as(?i64, 12), custom.settings.window.x);
    try std.testing.expect(custom.settings.copy.keep_copies);
    try std.testing.expect(custom.settings.folder.enable_chinese_pinyin_fuzzy_search);
    try std.testing.expectEqual(@as(usize, 1), custom.report.group_order_dangling);
}

test "loadFile 从磁盘读取 electron-store JSON" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "sample-manager-data.json",
        .data = "{\"samples\":{\"s1\":{\"filePath\":\"D:/x/Kick.wav\"}}}",
    });

    var library = try store.loadFile(std.testing.allocator, std.testing.io, tmp.dir, "sample-manager-data.json");
    defer library.deinit();
    try std.testing.expectEqual(@as(usize, 1), library.samples.len);
    try std.testing.expectEqualStrings("Kick", library.samples[0].file_name);
}
