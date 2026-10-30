//! 文件身份层 / 注释表的集成测试。
//!
//! 覆盖四件事：
//!   * 同一身份、不同路径 -> 同一组注释（改名 / 同卷移动不丢）；
//!   * 没有身份 -> fallback 键，三元组全等才算同一个键；
//!   * `resolve` 把旧 fallback 注释搬到 identity 键上（不重复、不丢）；
//!   * store 对「有 / 没有 identity」两种 JSON 都能加载，老 fixture 不受影响。

const std = @import("std");
const fixtures = @import("fixtures");
const model = @import("model.zig");
const store = @import("store.zig");
const annotations = @import("annotations.zig");

/// 三条合成身份：卷序列号相同、文件索引不同。
const kick_identity = model.FileIdentity{ .volume_serial = 0x1a2b_3c4d, .file_index = 0x0000_0001_0000_9c4e };
const snare_identity = model.FileIdentity{ .volume_serial = 0x1a2b_3c4d, .file_index = 0x0000_0001_0000_9c4f };
const hat_identity = model.FileIdentity{ .volume_serial = 0x1a2b_3c4d, .file_index = 0x0000_0001_0000_9c50 };

const kick_mtime: i64 = 1_700_000_000_000;

fn expectStrings(expected: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, 0..) |item, index| {
        try std.testing.expectEqualStrings(item, actual[index]);
    }
}

test "同一身份、不同路径：改名 / 同卷移动后注释仍然命中" {
    var table = annotations.AnnotationTable.init(std.testing.allocator);
    defer table.deinit();

    const before = model.Sample{
        .id = "s1",
        .file_name = "Kick",
        .file_ext = ".wav",
        .file_path = "D:/packs/Kick.wav",
        .file_size = 1024,
        .mtime = kick_mtime,
        .identity = kick_identity,
    };
    // 同一个文件：改了名、换了目录、大小和 mtime 也变了，身份没变。
    const after = model.Sample{
        .id = "s1",
        .file_name = "Kick renamed",
        .file_ext = ".wav",
        .file_path = "E:/archive/2026/Kick renamed.wav",
        .file_size = 4096,
        .mtime = kick_mtime + 86_400_000,
        .identity = kick_identity,
    };

    try table.put(before.stableKey(), .{
        .group_ids = &.{"drums"},
        .tags = &.{ "red", "priority" },
        .rating = 4,
    });

    // 路径变了，注释照样在：键是身份，不是路径。
    try std.testing.expectEqual(@as(usize, 1), table.count());
    const stored = table.get(after.stableKey()) orelse return error.TestUnexpectedResult;
    try expectStrings(&.{"drums"}, stored.group_ids);
    try expectStrings(&.{ "red", "priority" }, stored.tags);
    try std.testing.expectEqual(@as(u8, 4), stored.rating);

    // 换成另一个身份（同路径）就查不到：身份不同 = 不同文件。
    const other = model.Sample{
        .id = "s9",
        .file_name = "Kick",
        .file_ext = ".wav",
        .file_path = "D:/packs/Kick.wav",
        .identity = snare_identity,
    };
    try std.testing.expect(table.get(other.stableKey()) == null);
}

test "没有身份：走 fallback 键，三元组全等才合并" {
    var table = annotations.AnnotationTable.init(std.testing.allocator);
    defer table.deinit();

    // FAT32 / 网络盘上的同一个文件被两条样本记录引用（路径 / 大小 / mtime 全同）。
    const first = model.Sample{
        .id = "net_1",
        .file_name = "Kick",
        .file_ext = ".wav",
        .file_path = "\\\\nas\\packs\\Kick.wav",
        .file_size = 1024,
        .mtime = kick_mtime,
    };
    const second = model.Sample{
        .id = "net_2",
        .file_name = "Kick",
        .file_ext = ".wav",
        .file_path = "\\\\nas\\packs\\Kick.wav",
        .file_size = 1024,
        .mtime = kick_mtime,
    };
    // 同路径，但大小 / mtime 不同：不是同一个退化身份。
    const rewritten = model.Sample{
        .id = "net_3",
        .file_name = "Kick",
        .file_ext = ".wav",
        .file_path = "\\\\nas\\packs\\Kick.wav",
        .file_size = 2048,
        .mtime = kick_mtime + 1,
    };

    try std.testing.expect(first.identity == null);
    try std.testing.expect(first.stableKey().isFallback());
    try std.testing.expect(first.stableKey().eql(second.stableKey()));
    try std.testing.expect(!first.stableKey().eql(rewritten.stableKey()));

    try table.put(first.stableKey(), .{ .tags = &.{"network"} });
    // 第二个样本 key 相同 -> 读到同一组注释（合并成一条记录，而不是两条）。
    try std.testing.expectEqualStrings("network", table.get(second.stableKey()).?.tags[0]);
    try std.testing.expectEqual(@as(usize, 1), table.count());

    // 大小变了 -> 新键，不会覆盖旧记录。
    try std.testing.expect(table.get(rewritten.stableKey()) == null);
    try table.put(rewritten.stableKey(), .{ .tags = &.{"rewritten"} });
    try std.testing.expectEqual(@as(usize, 2), table.count());
    try std.testing.expectEqualStrings("network", table.get(first.stableKey()).?.tags[0]);
}

test "resolve：fallback 上的旧注释搬到身份键，不重复、不丢" {
    var table = annotations.AnnotationTable.init(std.testing.allocator);
    defer table.deinit();

    const old_key = model.StableKey{ .fallback = .{
        .path = "D:/packs/Kick.wav",
        .size = 1024,
        .mtime = kick_mtime,
    } };
    const identity_key = model.StableKey{ .identity = kick_identity };

    // 旧版本只存 fallback 键。
    try table.put(old_key, .{ .group_ids = &.{"drums"}, .tags = &.{"old"}, .rating = 3 });
    // 新版本已经在 identity 键上写过一条（标签有重叠）。
    try table.put(identity_key, .{
        .group_ids = &.{"favorites"},
        .tags = &.{ "new", "old" },
        .rating = 0,
    });

    const sample = model.Sample{
        .id = "s1",
        .file_name = "Kick",
        .file_ext = ".wav",
        .file_path = "D:/packs/Kick.wav",
        .file_size = 1024,
        .mtime = kick_mtime,
        .identity = kick_identity,
    };

    const report = try annotations.resolve(&table, &.{sample});
    try std.testing.expectEqual(@as(usize, 1), report.migrated);
    try std.testing.expectEqual(@as(usize, 1), report.merged);
    try std.testing.expectEqual(@as(usize, 1), report.identity_entries);
    try std.testing.expectEqual(@as(usize, 0), report.keptFallback());
    try std.testing.expectEqual(@as(usize, 1), table.count());

    // fallback 键没了：注释真的搬走，不是复制了一份。
    try std.testing.expect(table.get(old_key) == null);
    const merged = table.get(identity_key) orelse return error.TestUnexpectedResult;
    try expectStrings(&.{ "favorites", "drums" }, merged.group_ids);
    try expectStrings(&.{ "new", "old" }, merged.tags);
    // identity 侧未评分 -> 继承旧评分；两边都没丢。
    try std.testing.expectEqual(@as(u8, 3), merged.rating);

    // 幂等：再跑一次什么都不该变。
    const again = try annotations.resolve(&table, &.{sample});
    try std.testing.expectEqual(@as(usize, 0), again.migrated);
    try std.testing.expectEqual(@as(usize, 0), again.merged);
    try std.testing.expectEqual(@as(usize, 1), again.identity_entries);
    try std.testing.expectEqual(@as(usize, 0), again.keptFallback());
    try std.testing.expectEqual(@as(usize, 1), table.count());
}

test "resolve：只有 fallback 条目时原样搬到 identity 键" {
    var table = annotations.AnnotationTable.init(std.testing.allocator);
    defer table.deinit();

    const old_key = model.StableKey{ .fallback = .{ .path = "D:/packs/Snare.wav", .size = 512, .mtime = 7 } };
    try table.put(old_key, .{ .group_ids = &.{"drums"}, .tags = &.{"acoustic"}, .rating = 5 });

    // 样本的 mtime 未知（0）当作通配：路径和大小对上就迁移。
    const sample = model.Sample{
        .id = "s2",
        .file_name = "Snare",
        .file_ext = ".wav",
        .file_path = "D:/packs/Snare.wav",
        .file_size = 512,
        .identity = snare_identity,
    };

    const report = try annotations.resolve(&table, &.{sample});
    try std.testing.expectEqual(@as(usize, 1), report.migrated);
    try std.testing.expectEqual(@as(usize, 0), report.merged);
    try std.testing.expectEqual(@as(usize, 1), table.count());

    const moved = table.get(.{ .identity = snare_identity }) orelse return error.TestUnexpectedResult;
    try expectStrings(&.{"drums"}, moved.group_ids);
    try expectStrings(&.{"acoustic"}, moved.tags);
    try std.testing.expectEqual(@as(u8, 5), moved.rating);
    try std.testing.expect(table.get(old_key) == null);
}

test "resolve：身份冲突 / 大小不符 / 无身份样本时保留 fallback" {
    // 1) 大小不符：同路径但大小对不上，判为另一个文件。
    {
        var table = annotations.AnnotationTable.init(std.testing.allocator);
        defer table.deinit();
        const key = model.StableKey{ .fallback = .{ .path = "D:/packs/Kick.wav", .size = 1024 } };
        try table.put(key, .{ .tags = &.{"old"} });

        const replaced = model.Sample{
            .id = "s1",
            .file_name = "Kick",
            .file_ext = ".wav",
            .file_path = "D:/packs/Kick.wav",
            .file_size = 2048,
            .identity = kick_identity,
        };
        const report = try annotations.resolve(&table, &.{replaced});
        try std.testing.expectEqual(@as(usize, 0), report.migrated);
        try std.testing.expectEqual(@as(usize, 1), report.size_mismatch);
        try std.testing.expect(table.get(key) != null);
        try std.testing.expect(table.get(.{ .identity = kick_identity }) == null);
    }

    // 2) mtime 不符：两边都已知且不一致。
    {
        var table = annotations.AnnotationTable.init(std.testing.allocator);
        defer table.deinit();
        const key = model.StableKey{ .fallback = .{ .path = "D:/packs/Kick.wav", .mtime = 1000 } };
        try table.put(key, .{ .tags = &.{"old"} });

        const touched = model.Sample{
            .id = "s1",
            .file_name = "Kick",
            .file_ext = ".wav",
            .file_path = "D:/packs/Kick.wav",
            .mtime = 2000,
            .identity = kick_identity,
        };
        const report = try annotations.resolve(&table, &.{touched});
        try std.testing.expectEqual(@as(usize, 0), report.migrated);
        try std.testing.expectEqual(@as(usize, 1), report.mtime_mismatch);
        try std.testing.expect(table.get(key) != null);
    }

    // 3) 样本自己还没有身份：没有可迁的目标，注释留在 fallback。
    {
        var table = annotations.AnnotationTable.init(std.testing.allocator);
        defer table.deinit();
        const key = model.StableKey{ .fallback = .{ .path = "E:/fat32/Kick.wav", .size = 1024 } };
        try table.put(key, .{ .tags = &.{"old"} });

        const no_identity = model.Sample{
            .id = "s1",
            .file_name = "Kick",
            .file_ext = ".wav",
            .file_path = "E:/fat32/Kick.wav",
            .file_size = 1024,
        };
        const report = try annotations.resolve(&table, &.{no_identity});
        try std.testing.expectEqual(@as(usize, 0), report.migrated);
        try std.testing.expectEqual(@as(usize, 1), report.unmatched);
        try std.testing.expect(table.get(key) != null);
    }

    // 4) 同一路径两个不同身份：搬给谁都不对，保留 fallback。
    {
        var table = annotations.AnnotationTable.init(std.testing.allocator);
        defer table.deinit();
        const key = model.StableKey{ .fallback = .{ .path = "D:/packs/Kick.wav" } };
        try table.put(key, .{ .tags = &.{"old"} });

        const first = model.Sample{
            .id = "s1",
            .file_name = "Kick",
            .file_ext = ".wav",
            .file_path = "D:/packs/Kick.wav",
            .identity = kick_identity,
        };
        const second = model.Sample{
            .id = "s2",
            .file_name = "Kick copy",
            .file_ext = ".wav",
            .file_path = "D:/packs/Kick.wav",
            .identity = hat_identity,
        };
        const report = try annotations.resolve(&table, &.{ first, second });
        try std.testing.expectEqual(@as(usize, 0), report.migrated);
        try std.testing.expectEqual(@as(usize, 1), report.ambiguous);
        try std.testing.expect(table.get(key) != null);
        try std.testing.expectEqual(@as(usize, 1), table.count());
    }
}

test "store：JSON 有 / 没有 identity 两种输入都能加载" {
    const text =
        \\{
        \\  "samples": {
        \\    "with_id": {
        \\      "filePath": "D:/packs/Kick.wav",
        \\      "identity": {"volumeSerial": 439041101, "fileIndex": 8589935694}
        \\    },
        \\    "without_id": {"filePath": "D:/packs/Snare.wav"},
        \\    "broken_id": {"filePath": "D:/packs/Hat.wav", "identity": {"volumeSerial": 439041101}},
        \\    "bad_id": {"filePath": "D:/packs/Tom.wav", "identity": {"volumeSerial": -1, "fileIndex": 1}}
        \\  }
        \\}
    ;
    var library = try store.load(std.testing.allocator, text);
    defer library.deinit();
    try std.testing.expectEqual(@as(usize, 4), library.samples.len);

    const with_id = library.sampleById("with_id").?;
    try std.testing.expect(with_id.identity != null);
    try std.testing.expectEqual(@as(u32, 439041101), with_id.identity.?.volume_serial);
    try std.testing.expectEqual(@as(u64, 8589935694), with_id.identity.?.file_index);
    try std.testing.expect(with_id.stableKey().isIdentity());

    // 缺字段 / 只有一半 / 负数：都当成「没有身份」，退回 fallback，不算加载失败。
    for ([_][]const u8{ "without_id", "broken_id", "bad_id" }) |sample_id| {
        const sample = library.sampleById(sample_id).?;
        try std.testing.expect(sample.identity == null);
        try std.testing.expect(sample.stableKey().isFallback());
    }

    // 加载后的样本可以直接当注释键用：同一身份跨路径命中。
    var table = annotations.AnnotationTable.init(std.testing.allocator);
    defer table.deinit();
    try table.put(with_id.stableKey(), .{ .tags = &.{"imported"} });
    const moved = model.Sample{
        .id = "with_id",
        .file_name = "Kick moved",
        .file_ext = ".wav",
        .file_path = "D:/elsewhere/Kick moved.wav",
        .identity = with_id.identity,
    };
    try std.testing.expectEqualStrings("imported", table.get(moved.stableKey()).?.tags[0]);
}

test "老 fixture：identity 全为 null，stableKey 走 fallback" {
    var library = try store.load(std.testing.allocator, fixtures.legacy_v1);
    defer library.deinit();

    try std.testing.expectEqual(@as(usize, 3), library.samples.len);
    for (library.samples) |sample| {
        try std.testing.expect(sample.identity == null);
        try std.testing.expect(sample.stableKey().isFallback());
        // 退化键里的路径就是样本路径：老库不需要补任何字段。
        const fallback = switch (sample.stableKey()) {
            .fallback => |value| value,
            .identity => return error.TestUnexpectedResult,
        };
        try std.testing.expectEqualStrings(sample.file_path, fallback.path);
        try std.testing.expectEqual(sample.file_size, fallback.size);
    }
}
