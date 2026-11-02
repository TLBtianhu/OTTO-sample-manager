//! 真实 OTTOLIB v1 → v2 的无损迁移验收。
const std = @import("std");
const model = @import("model.zig");
const binary = @import("library_binary.zig");
const annotations = @import("annotations.zig");
const fixtures = @import("fixtures");

const allocator = std.testing;

test "v1 二进制：条目/路径/分组逐条保留，补导入根与相对路径，注释键不孤儿" {
    var legacy = try binary.decode(allocator.allocator, fixtures.legacy_binary_v1);
    defer legacy.deinit();
    try allocator.expectEqual(@as(usize, 2), legacy.samples.len);
    try allocator.expectEqual(@as(usize, 2), legacy.groups.len);
    try allocator.expectEqual(@as(usize, 3), legacy.folders.len);

    // 注释/标签在 AnnotationTable 中按 StableKey 存，不在 Sample 里。用 v1
    // 解码后的键建表，再经过 v2 写读，必须仍能逐条取回完全相同的值。
    var table = annotations.AnnotationTable.init(allocator.allocator);
    defer table.deinit();
    for (legacy.samples, 0..) |sample, index| {
        try table.put(sample.stableKey(), .{
            .group_ids = sample.group_ids,
            .tags = if (index == 0) &.{"原注释", "kick"} else &.{"原注释", "snare"},
            .rating = @intCast(index + 3),
        });
    }

    const kick = legacy.sampleById("s1").?;
    try allocator.expectEqualStrings("D:/packs/Drums/Kick 01.wav", kick.file_path);
    try allocator.expectEqualStrings("D:/packs", kick.rootPath());
    try allocator.expectEqualStrings("Drums/Kick 01.wav", kick.relativePath());
    try allocator.expectEqualStrings("g1", kick.group_ids[0]);
    const snare = legacy.sampleById("s2").?;
    try allocator.expectEqualStrings("D:/packs/Drums/四层/同名 Snare.flac", snare.file_path);
    try allocator.expectEqualStrings("D:/packs", snare.rootPath());
    try allocator.expectEqualStrings("Drums/四层/同名 Snare.flac", snare.relativePath());
    try allocator.expectEqual(@as(usize, 2), snare.group_ids.len);
    try allocator.expectEqualStrings("鼓", legacy.groupById("g1").?.name);
    try allocator.expectEqualStrings("标签·备用", legacy.groupById("g2").?.name);

    const upgraded = try binary.encode(allocator.allocator, &legacy);
    defer allocator.allocator.free(upgraded);
    try allocator.expectEqual(@as(u16, 2), std.mem.readInt(u16, upgraded[8..10], .little));
    var current = try binary.decode(allocator.allocator, upgraded);
    defer current.deinit();
    try allocator.expectEqual(legacy.samples.len, current.samples.len);
    try allocator.expectEqual(legacy.groups.len, current.groups.len);
    try allocator.expectEqual(legacy.folders.len, current.folders.len);
    for (legacy.samples) |before| {
        const after = current.sampleById(before.id) orelse return error.TestUnexpectedResult;
        try allocator.expectEqualStrings(before.file_path, after.file_path);
        try allocator.expectEqualStrings(before.rootPath(), after.rootPath());
        try allocator.expectEqualStrings(before.relativePath(), after.relativePath());
        try allocator.expectEqual(before.group_ids.len, after.group_ids.len);
        for (before.group_ids, after.group_ids) |a, b| try allocator.expectEqualStrings(a, b);
        try allocator.expect(before.stableKey().eql(after.stableKey()));
        const note = table.get(after.stableKey()) orelse return error.TestUnexpectedResult;
        try allocator.expectEqual(@as(usize, 2), note.tags.len);
        try allocator.expectEqualStrings("原注释", note.tags[0]);
    }
}

test "未知库版本必须报 UnknownVersion，绝不能退成空库" {
    const broken = try allocator.allocator.dupe(u8, fixtures.legacy_binary_v1);
    defer allocator.allocator.free(broken);
    std.mem.writeInt(u16, broken[8..10], 0x7777, .little);
    try allocator.expectError(error.UnknownVersion, binary.decode(allocator.allocator, broken));
}

test "无目录的 v1 路径退到父目录，不丢条目" {
    const location = @import("sample_location.zig").infer("D:/legacy/a/b/c.wav", null);
    try allocator.expectEqualStrings("D:/legacy/a/b", location.root_path);
    try allocator.expectEqualStrings("c.wav", location.relative_path);
    var key = model.Sample{
        .id = "x", .file_name = "c", .file_ext = ".wav", .file_path = "D:/legacy/a/b/c.wav",
    };
    @import("sample_location.zig").setBorrowed(&key, location.root_path, location.relative_path);
    try allocator.expectEqualStrings("D:/legacy/a/b/c.wav", key.file_path);
    try allocator.expectEqualStrings("D:/legacy/a/b", key.rootPath());
    try allocator.expectEqualStrings("c.wav", key.relativePath());
}
