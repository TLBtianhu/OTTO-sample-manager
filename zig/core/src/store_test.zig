//! store.zig 的单元测试（从 store.zig 拆出，保持单文件行数可控）。
//! 全部使用内联合成 JSON，不依赖 fixtures/ 与磁盘。

const std = @import("std");
const model = @import("model.zig");
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

test "empty + appendSamples：深拷贝、计数、重复 id 防御" {
    var library = try store.empty(std.testing.allocator);
    defer library.deinit();
    try std.testing.expectEqual(@as(usize, 0), library.samples.len);
    try std.testing.expectEqual(@as(usize, 0), library.report.samples_loaded);

    // 来源字符串放在**可变**缓冲里：追加后改写它，库里的值不能跟着变。
    var path_buffer = [_]u8{ 'D', ':', '/', 'x', '.', 'w', 'a', 'v' };
    var incoming = [_]model.Sample{
        .{
            .id = "im_0000000000000001",
            .file_name = "Kick",
            .file_ext = ".wav",
            .file_path = &path_buffer,
            .duration = 0.8,
            .sample_rate = 22_050,
            .channels = 1,
            .file_size = 35_280,
            .imported_at = 1_700_000_000_000,
            .mtime = 1_699_000_000_000,
            .identity = .{ .volume_serial = 0x1a2b_3c4d, .file_index = 0x0000_0001_0000_9c4e },
            .pending_metadata = false,
        },
        .{
            .id = "im_0000000000000002",
            .file_name = "Snare",
            .file_ext = ".wav",
            .file_path = "D:/x/Snare.wav",
            .original_id = "im_0000000000000002",
            .group_ids = &.{ "g1", "g2" },
            .pending_metadata = true,
        },
    };

    try std.testing.expectEqual(@as(usize, 2), try library.appendSamples(&incoming));
    try std.testing.expectEqual(@as(usize, 2), library.samples.len);
    try std.testing.expectEqual(@as(usize, 2), library.report.samples_loaded);

    // 现在改写来源缓冲：深拷贝必须不受影响。
    @memset(&path_buffer, 'z');
    const kick = library.sampleById("im_0000000000000001").?;
    try std.testing.expectEqualStrings("D:/x.wav", kick.file_path);
    try std.testing.expect(kick.duration == 0.8);
    try std.testing.expectEqual(@as(u32, 22_050), kick.sample_rate);
    try std.testing.expectEqual(@as(u64, 0x0000_0001_0000_9c4e), kick.identity.?.file_index);

    const snare = library.sampleById("im_0000000000000002").?;
    try std.testing.expect(snare.pending_metadata);
    try std.testing.expectEqual(@as(usize, 2), snare.group_ids.len);
    try std.testing.expectEqualStrings("g1", snare.group_ids[0]);

    // 同一批再追加一次：id 已存在，一条都不加（导入层的路径/身份去重在前，
    // 这里是内核的防御，不负责计数）。
    try std.testing.expectEqual(@as(usize, 0), try library.appendSamples(&incoming));
    try std.testing.expectEqual(@as(usize, 2), library.samples.len);
}
