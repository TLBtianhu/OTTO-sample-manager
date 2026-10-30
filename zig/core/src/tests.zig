//! 集成测试：用 fixtures/ 下的合成 JSON 驱动 store + query。
//! 所有数据均为手工构造，不包含任何真实用户数据。

const std = @import("std");
const fixtures = @import("fixtures");
const model = @import("model.zig");
const store = @import("store.zig");
const query = @import("query.zig");
const root = @import("root.zig");

test {
    _ = root;
    _ = model;
    _ = store;
    _ = query;
    _ = @import("json.zig");
    _ = @import("settings.zig");
    _ = @import("reconcile.zig");
    _ = @import("diagnostics.zig");
    _ = @import("store_test.zig");
}

fn expectIds(expected: []const []const u8, samples: []const model.Sample) !void {
    try std.testing.expectEqual(expected.len, samples.len);
    for (expected, 0..) |id, index| {
        try std.testing.expectEqualStrings(id, samples[index].id);
    }
}

fn expectStringIds(expected: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, 0..) |id, index| {
        try std.testing.expectEqualStrings(id, actual[index]);
    }
}

fn expectUniqueIds(items: []const []const u8) !void {
    var seen = std.StringHashMapUnmanaged(void){};
    defer seen.deinit(std.testing.allocator);
    for (items) |item| {
        try std.testing.expect(!seen.contains(item));
        try seen.put(std.testing.allocator, item, {});
    }
}

/// 加载后的所有引用都必须闭合，不能留下悬空 id。
fn expectRefsClosed(library: *const store.Library) !void {
    for (library.samples) |sample| {
        if (sample.folder_id) |folder_id| {
            try std.testing.expect(library.folderById(folder_id) != null);
        }
        for (sample.group_ids) |group_id| {
            try std.testing.expect(library.groupById(group_id) != null);
        }
    }
    for (library.groups) |group| {
        for (group.sample_ids) |sample_id| {
            try std.testing.expect(library.sampleById(sample_id) != null);
        }
    }
    for (library.folders) |folder| {
        for (folder.sample_ids) |sample_id| {
            try std.testing.expect(library.sampleById(sample_id) != null);
        }
        for (folder.child_folder_ids) |child_id| {
            try std.testing.expect(library.folderById(child_id) != null);
        }
        if (folder.parent_id) |parent_id| {
            const parent = library.folderById(parent_id) orelse return error.TestUnexpectedResult;
            var found = false;
            for (parent.child_folder_ids) |child_id| {
                if (std.mem.eql(u8, child_id, folder.id)) found = true;
            }
            try std.testing.expect(found);
        }
    }
}

test "fixtures/legacy_v1.json：缺 folderId / groupIds 的旧数据" {
    var library = try store.load(std.testing.allocator, fixtures.legacy_v1);
    defer library.deinit();

    try std.testing.expectEqual(@as(usize, 3), library.samples.len);
    try std.testing.expectEqual(@as(usize, 1), library.groups.len);
    try std.testing.expectEqual(@as(usize, 1), library.folders.len);
    try std.testing.expectEqual(@as(usize, 0), library.report.duplicate_samples);
    try std.testing.expectEqual(@as(usize, 0), library.report.dangling_folder_samples);
    try std.testing.expectEqual(@as(usize, 0), library.report.dangling_sample_folders);
    try std.testing.expectEqual(@as(usize, 0), library.report.id_key_mismatches);
    try std.testing.expectEqual(@as(usize, 3), library.report.samples_loaded);
    try std.testing.expectEqual(@as(usize, 0), library.report.synthesized_folders);
    try std.testing.expectEqual(@as(usize, 3), library.report.rebuilt_folder_memberships);

    // 三条旧样本都没有 folderId，按 filePath 归入已存在的扁平目录 folder_D:/packs/Drums。
    try expectStringIds(&.{ "legacy_1", "legacy_2", "legacy_3" }, library.folders[0].sample_ids);
    try std.testing.expectEqualStrings("Drums", library.folders[0].name);
    try std.testing.expect(library.folders[0].isRoot());

    const hat = library.sampleById("legacy_3").?;
    try std.testing.expectEqualStrings("Hat 03", hat.file_name);
    try std.testing.expectEqualStrings(".wav", hat.file_ext);
    try std.testing.expectEqualStrings("folder_D:/packs/Drums", hat.folder_id.?);
    try std.testing.expectEqual(@as(usize, 0), hat.group_ids.len);
    try std.testing.expectEqualStrings("legacy_3", hat.original_id);

    const snare = library.sampleById("legacy_2").?;
    try std.testing.expectEqualStrings("legacy_2", snare.original_id);
    try std.testing.expect(!snare.is_copy);
    try std.testing.expectEqual(@as(u32, 0), snare.sample_rate);
    try std.testing.expectEqualStrings(model.default_group_color, library.groups[0].color);
    try std.testing.expectEqualStrings("Old Group", library.groups[0].name);

    try std.testing.expectEqual(@as(usize, 1), library.folder_order.len);
    try std.testing.expectEqualStrings("folder_D:/packs/Drums", library.folder_order[0]);
    try std.testing.expectEqual(@as(usize, 1), library.group_order.len);
    try std.testing.expectEqualStrings("g_old", library.group_order[0]);
    try std.testing.expect(library.settings.window.always_on_top);

    const hits = try query.byFolder(std.testing.allocator, &library, "folder_D:/packs/Drums", true);
    defer std.testing.allocator.free(hits);
    try expectIds(&.{ "legacy_1", "legacy_2", "legacy_3" }, hits);
    try expectRefsClosed(&library);
}

test "fixtures/dangling_refs.json：悬空引用被清理" {
    var library = try store.load(std.testing.allocator, fixtures.dangling_refs);
    defer library.deinit();

    try std.testing.expectEqual(@as(usize, 2), library.samples.len);
    try std.testing.expectEqual(@as(usize, 2), library.groups.len);
    try std.testing.expectEqual(@as(usize, 4), library.folders.len);

    try std.testing.expectEqual(@as(usize, 1), library.report.dangling_sample_folders);
    try std.testing.expectEqual(@as(usize, 1), library.report.dangling_sample_groups);
    try std.testing.expectEqual(@as(usize, 2), library.report.dangling_folder_samples);
    try std.testing.expectEqual(@as(usize, 2), library.report.dangling_group_samples);
    try std.testing.expectEqual(@as(usize, 1), library.report.dangling_folder_children);
    try std.testing.expectEqual(@as(usize, 1), library.report.repaired_folder_parents);
    try std.testing.expectEqual(@as(usize, 1), library.report.synthesized_folders);
    try std.testing.expectEqual(@as(usize, 1), library.report.replaced_folder_memberships);
    try std.testing.expectEqual(@as(usize, 2), library.report.rebuilt_folder_memberships);
    try std.testing.expectEqual(@as(usize, 1), library.report.folder_order_dangling);
    try std.testing.expectEqual(@as(usize, 1), library.report.folder_order_duplicates);
    try std.testing.expectEqual(@as(usize, 1), library.report.group_order_dangling);
    try std.testing.expectEqual(@as(usize, 1), library.report.group_order_duplicates);

    // s1 的 folderId 悬空 -> 补扁平目录 folder_D:/a；s2 仍在 f_root。
    const kick = library.sampleById("s1").?;
    try std.testing.expectEqualStrings("folder_D:/a", kick.folder_id.?);
    try std.testing.expectEqual(@as(usize, 1), kick.group_ids.len);
    try std.testing.expectEqualStrings("g_ok", kick.group_ids[0]);

    // f_child 里记录的 s2 与 sample.folderId=f_root 不一致，按 App 规则丢弃。
    const child = library.folderById("f_child").?;
    try std.testing.expectEqual(@as(usize, 0), child.sample_ids.len);

    const orphan = library.folderById("f_orphan").?;
    try std.testing.expect(orphan.parent_id == null);
    try std.testing.expectEqual(@as(u32, 0), orphan.depth);
    try std.testing.expectEqualStrings("f_orphan", orphan.root_id);
    try std.testing.expectEqual(@as(usize, 0), orphan.sample_ids.len);

    try std.testing.expectEqual(@as(usize, 1), library.folderById("f_root").?.sample_ids.len);
    try std.testing.expectEqualStrings("s2", library.folderById("f_root").?.sample_ids[0]);
    try std.testing.expectEqual(@as(usize, 1), library.folderById("folder_D:/a").?.sample_ids.len);
    try std.testing.expectEqual(@as(usize, 1), library.groups[0].sample_ids.len);

    try std.testing.expectEqual(@as(usize, 3), library.folder_order.len);
    try std.testing.expectEqualStrings("f_root", library.folder_order[0]);
    try std.testing.expectEqualStrings("f_orphan", library.folder_order[1]);
    try std.testing.expectEqualStrings("folder_D:/a", library.folder_order[2]);

    try std.testing.expectEqual(@as(usize, 2), library.group_order.len);
    try std.testing.expectEqualStrings("g_ok", library.group_order[0]);
    try std.testing.expectEqualStrings("g_empty", library.group_order[1]);

    const root_hits = try query.byFolder(std.testing.allocator, &library, "f_root", true);
    defer std.testing.allocator.free(root_hits);
    try expectIds(&.{"s2"}, root_hits);

    const orphan_hits = try query.byFolder(std.testing.allocator, &library, "folder_D:/a", false);
    defer std.testing.allocator.free(orphan_hits);
    try expectIds(&.{"s1"}, orphan_hits);
    try expectRefsClosed(&library);
}

test "fixtures/duplicate_ids.json：重复 id 去重" {
    var library = try store.load(std.testing.allocator, fixtures.duplicate_ids);
    defer library.deinit();

    try std.testing.expectEqual(@as(usize, 2), library.samples.len);
    try std.testing.expectEqual(@as(usize, 1), library.report.duplicate_samples);
    try std.testing.expectEqual(@as(usize, 4), library.report.id_key_mismatches);
    // 3 条样本的 map 键与对象内 id 都不一致（其中 key_b 随后因重复 id 被丢弃），
    // 另加 1 个重复 folder id（键 f2 / 对象内 f1）。
    try std.testing.expectEqualStrings("Dup A", library.sampleById("dup_1").?.file_name);
    try std.testing.expect(library.sampleById("Dup B") == null);

    try std.testing.expectEqual(@as(usize, 2), library.folders.len);
    try std.testing.expectEqual(@as(usize, 1), library.report.duplicate_folders);
    try std.testing.expectEqual(@as(usize, 1), library.report.synthesized_folders);
    try std.testing.expectEqual(@as(usize, 2), library.report.replaced_folder_memberships);
    try std.testing.expectEqual(@as(usize, 1), library.report.folder_order_duplicates);

    // 重复的 folder id（f2）被丢弃，保留第一个 f1；f1 的成员缓存与 folderId 不一致，重建后为空。
    try std.testing.expectEqualStrings("F1", library.folderById("f1").?.name);
    try std.testing.expectEqual(@as(usize, 0), library.folderById("f1").?.sample_ids.len);
    try std.testing.expect(library.folderById("f2") == null);
    try std.testing.expectEqual(@as(usize, 2), library.folderById("folder_D:/d").?.sample_ids.len);
    try std.testing.expectEqual(@as(usize, 2), library.folder_order.len);
    try std.testing.expectEqualStrings("f1", library.folder_order[0]);
    try std.testing.expectEqualStrings("folder_D:/d", library.folder_order[1]);

    try std.testing.expectEqual(@as(usize, 1), library.groups[0].sample_ids.len);
    try expectUniqueIds(library.groups[0].sample_ids);
    try expectUniqueIds(library.folders[1].sample_ids);

    const hits = try query.byFolder(std.testing.allocator, &library, "folder_D:/d", true);
    defer std.testing.allocator.free(hits);
    try expectIds(&.{ "dup_1", "dup_2" }, hits);
    try expectRefsClosed(&library);
}

test "fixtures/subfolders.json：子文件夹递归查询与设置" {
    var library = try store.load(std.testing.allocator, fixtures.subfolders);
    defer library.deinit();

    try std.testing.expectEqual(@as(usize, 5), library.samples.len);
    try std.testing.expectEqual(@as(usize, 2), library.groups.len);
    try std.testing.expectEqual(@as(usize, 4), library.folders.len);
    try std.testing.expectEqual(@as(usize, 0), library.report.synthesized_folders);
    try std.testing.expectEqual(@as(usize, 5), library.report.rebuilt_folder_memberships);
    try std.testing.expectEqual(@as(usize, 4), library.report.linked_group_memberships);
    try std.testing.expectEqual(@as(usize, 0), library.report.replaced_folder_memberships);
    try expectStringIds(&.{"s_root"}, library.folderById("f_root").?.sample_ids);
    try expectStringIds(&.{"s_a"}, library.folderById("f_a").?.sample_ids);
    try expectStringIds(&.{ "s_b", "s_cn" }, library.folderById("f_b").?.sample_ids);

    try std.testing.expectEqual(@as(usize, 1), library.folder_order.len);
    try std.testing.expectEqualStrings("f_root", library.folder_order[0]);
    try std.testing.expectEqual(@as(usize, 2), library.group_order.len);

    // 设置：electron-store 的 settings / copySettings / folderSettings。
    try std.testing.expect(!library.settings.window.always_on_top);
    try std.testing.expectEqual(@as(u32, 500), library.settings.window.width);
    try std.testing.expectEqual(@as(u32, 900), library.settings.window.height);
    try std.testing.expect(!library.settings.copy.enable_auto_copy);
    try std.testing.expect(library.settings.copy.keep_copies);
    try std.testing.expect(library.settings.copy.melodyne_compatibility_mode);
    try std.testing.expect(!library.settings.folder.expand_on_search);
    try std.testing.expect(!library.settings.folder.folder_classification_enabled);
    try std.testing.expect(library.settings.folder.memory_optimization_mode);
    try std.testing.expect(!library.settings.folder.enable_chinese_pinyin_fuzzy_search);

    const subtree = try query.folderSubtreeIds(std.testing.allocator, &library, "f_root");
    defer std.testing.allocator.free(subtree);
    try std.testing.expectEqual(@as(usize, 4), subtree.len);
    try std.testing.expectEqualStrings("f_root", subtree[0]);
    try std.testing.expectEqualStrings("f_a", subtree[1]);
    try std.testing.expectEqualStrings("f_a1", subtree[2]);
    try std.testing.expectEqualStrings("f_b", subtree[3]);

    const all = try query.byFolder(std.testing.allocator, &library, "f_root", true);
    defer std.testing.allocator.free(all);
    try expectIds(&.{ "s_root", "s_a", "s_a1", "s_b", "s_cn" }, all);

    const shallow = try query.byFolder(std.testing.allocator, &library, "f_root", false);
    defer std.testing.allocator.free(shallow);
    try expectIds(&.{"s_root"}, shallow);

    const nested = try query.byFolder(std.testing.allocator, &library, "f_a", true);
    defer std.testing.allocator.free(nested);
    try expectIds(&.{ "s_a", "s_a1" }, nested);

    const nested_shallow = try query.byFolder(std.testing.allocator, &library, "f_a", false);
    defer std.testing.allocator.free(nested_shallow);
    try expectIds(&.{"s_a"}, nested_shallow);

    const drums = try query.byGroup(std.testing.allocator, &library, "g_drums");
    defer std.testing.allocator.free(drums);
    try expectIds(&.{ "s_root", "s_a" }, drums);

    const bass = try query.byGroup(std.testing.allocator, &library, "g_bass");
    defer std.testing.allocator.free(bass);
    try expectIds(&.{ "s_a", "s_b" }, bass);

    const kick = try query.byFileName(std.testing.allocator, &library, "KICK");
    defer std.testing.allocator.free(kick);
    try expectIds(&.{"s_a"}, kick);

    const chinese = try query.byFileName(std.testing.allocator, &library, "循环");
    defer std.testing.allocator.free(chinese);
    try expectIds(&.{"s_cn"}, chinese);

    const loop = try query.byFileName(std.testing.allocator, &library, "loop");
    defer std.testing.allocator.free(loop);
    try expectIds(&.{"s_root"}, loop);

    const filtered = try query.apply(std.testing.allocator, &library, .{
        .folder_id = "f_root",
        .include_subfolders = true,
        .group_id = "g_bass",
        .name_contains = "bass",
    });
    defer std.testing.allocator.free(filtered);
    try expectIds(&.{"s_b"}, filtered);

    const sorted_by_name = try query.apply(std.testing.allocator, &library, .{ .sort = .file_name });
    defer std.testing.allocator.free(sorted_by_name);
    try expectIds(&.{ "s_b", "s_a", "s_root", "s_a1", "s_cn" }, sorted_by_name);
    try expectRefsClosed(&library);
}

// 1000 条合成数据：只打印耗时，不做性能断言（不同机器差异太大）。
test "1000 条合成数据加载耗时粗测" {
    const allocator = std.testing.allocator;
    const json = try buildSyntheticJson(allocator, 1000);
    defer allocator.free(json);
    const json_len = json.len;

    const started = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
    var library = try store.load(allocator, json);
    const finished = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
    defer library.deinit();

    try std.testing.expectEqual(@as(usize, 1000), library.samples.len);
    try std.testing.expectEqual(@as(usize, 1000), library.groups[0].sample_ids.len);
    try std.testing.expectEqual(@as(usize, 1000), library.folders[0].sample_ids.len);
    try std.testing.expectEqual(@as(usize, 1000), library.report.linked_group_memberships);
    try std.testing.expectEqual(@as(usize, 1000), library.report.rebuilt_folder_memberships);

    const hits = try query.byFolder(allocator, &library, "folder_synthetic", true);
    defer allocator.free(hits);
    try std.testing.expectEqual(@as(usize, 1000), hits.len);

    const elapsed_ns: i96 = finished.raw.nanoseconds - started.raw.nanoseconds;
    const safe_ns: f64 = @floatFromInt(if (elapsed_ns > 0) elapsed_ns else 1);
    const elapsed_ms = safe_ns / 1e6;
    const mib = @as(f64, @floatFromInt(json_len)) / (1024.0 * 1024.0);
    const throughput = mib / (safe_ns / 1e9);
    std.debug.print(
        "\n[perf] 1000 条合成样本：输入 {d} 字节，加载 {d:.3} ms，吞吐 {d:.1} MiB/s（仅打印，不断言）\n",
        .{ json_len, elapsed_ms, throughput },
    );
}

fn buildSyntheticJson(allocator: std.mem.Allocator, count: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"samples\":{");
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const separator: []const u8 = if (index == 0) "" else ",";
        var buffer: [512]u8 = undefined;
        const entry = try std.fmt.bufPrint(
            &buffer,
            "{s}\"s{d}\":{{\"id\":\"s{d}\",\"fileName\":\"Kick {d}\",\"fileExt\":\".wav\"," ++
                "\"filePath\":\"D:/synthetic/Kick {d}.wav\",\"folderId\":\"folder_synthetic\"," ++
                "\"groupIds\":[\"group_a\"],\"duration\":0.5,\"sampleRate\":44100," ++
                "\"channels\":1,\"fileSize\":44100,\"importedAt\":{d}}}",
            .{ separator, index, index, index, index, index + 1 },
        );
        try out.appendSlice(allocator, entry);
    }
    try out.appendSlice(allocator, "},\"groups\":{\"group_a\":{\"id\":\"group_a\",\"name\":\"A\",\"color\":\"#ffffff\",\"sampleIds\":[]}}," ++
        "\"folderState\":{\"folders\":{\"folder_synthetic\":{\"id\":\"folder_synthetic\"," ++
        "\"name\":\"synthetic\",\"path\":\"D:/synthetic\",\"sampleIds\":[],\"childFolderIds\":[]," ++
        "\"parentId\":null}},\"folderOrder\":[\"folder_synthetic\"]}}");
    return out.toOwnedSlice(allocator);
}
