//! `library_binary.zig` 的测试：往返、具名错误、上限、以及"任意坏字节都不 panic"。
//!
//! 所有数据都是内联合成的，不依赖 fixtures/ 与磁盘；解码失败必须不留下分配，
//! 所以统一用 `std.testing.allocator` 检查泄漏。

const std = @import("std");
const model = @import("model.zig");
const store = @import("store.zig");
const binary = @import("library_binary.zig");

const allocator = std.testing.allocator;

/// 一个覆盖所有字段的合成库：身份、分组、目录、顺序、设置、复制链、待补元数据。
const sample_json =
    \\{
    \\  "samples": {
    \\    "s1": {
    \\      "id": "s1", "fileName": "Kick 01", "fileExt": ".wav",
    \\      "filePath": "D:/packs/Kick 01.wav", "folderId": "f1",
    \\      "duration": 1.5, "sampleRate": 48000, "channels": 2,
    \\      "fileSize": 123456, "mtime": 1700000000123, "importedAt": 1700000000456,
    \\      "identity": {"volumeSerial": 305419896, "fileIndex": 1234567890123},
    \\      "groupIds": ["g1"]
    \\    },
    \\    "s2": {
    \\      "id": "s2", "fileName": "Snare", "fileExt": ".flac",
    \\      "filePath": "D:/packs/Snare.flac", "folderId": "f1",
    \\      "duration": 0.25, "fileSize": 900,
    \\      "isCopy": true, "copyIndex": 3, "originalId": "s1",
    \\      "groupIds": ["g1", "g2"]
    \\    }
    \\  },
    \\  "groups": {
    \\    "g1": {"id": "g1", "name": "鼓", "color": "#112233", "sampleIds": ["s1", "s2"]},
    \\    "g2": {"id": "g2", "name": "备用", "sampleIds": ["s2"]}
    \\  },
    \\  "folderState": {
    \\    "folders": {
    \\      "f1": {
    \\        "id": "f1", "name": "packs", "path": "D:/packs",
    \\        "sampleIds": ["s1", "s2"], "parentId": null,
    \\        "rootId": "f1", "depth": 0, "importedAt": 1700000000789,
    \\        "isExpanded": true, "order": 3
    \\      }
    \\    },
    \\    "folderOrder": ["f1"]
    \\  },
    \\  "groupOrder": ["g2", "g1"],
    \\  "settings": {
    \\    "windowAlwaysOnTop": false, "windowOpacity": 0.75,
    \\    "windowWidth": 420, "windowHeight": 640,
    \\    "windowX": 12, "windowY": 34
    \\  },
    \\  "copySettings": {"keepCopies": true},
    \\  "folderSettings": {"enableChinesePinyinFuzzySearch": true}
    \\}
;

fn loadFixture() !store.Library {
    const library = try store.load(allocator, sample_json);
    return library;
}

/// 重新算 CRC：用于绕过"先 CRC"的检查，直接考 payload 解析的具名错误。
fn patchChecksum(bytes: []u8) void {
    const checksum = std.hash.Crc32.hash(bytes[0 .. bytes.len - binary.crc_size]);
    std.mem.writeInt(u32, bytes[bytes.len - binary.crc_size ..][0..4], checksum, .little);
}

fn decodedCopy(bytes: []const u8) !store.Library {
    return binary.decode(allocator, bytes);
}

test "编码 / 解码往返：字段、顺序与设置逐字节一致" {
    var library = try loadFixture();
    defer library.deinit();

    const first = try binary.encode(allocator, &library);
    defer allocator.free(first);

    var decoded = try decodedCopy(first);
    defer decoded.deinit();

    try std.testing.expectEqual(library.samples.len, decoded.samples.len);
    try std.testing.expectEqual(library.groups.len, decoded.groups.len);
    try std.testing.expectEqual(library.folders.len, decoded.folders.len);
    try std.testing.expectEqual(library.folder_order.len, decoded.folder_order.len);
    try std.testing.expectEqual(library.group_order.len, decoded.group_order.len);

    const kick = decoded.sampleById("s1").?;
    try std.testing.expectEqualStrings("Kick 01", kick.file_name);
    try std.testing.expectEqualStrings(".wav", kick.file_ext);
    try std.testing.expectEqualStrings("D:/packs/Kick 01.wav", kick.file_path);
    try std.testing.expectEqualStrings("f1", kick.folder_id.?);
    try std.testing.expectEqual(@as(f64, 1.5), kick.duration);
    try std.testing.expectEqual(@as(u32, 48000), kick.sample_rate);
    try std.testing.expectEqual(@as(u32, 2), kick.channels);
    try std.testing.expectEqual(@as(u64, 123456), kick.file_size);
    // 现有 JSON 模型没有 mtime（那是 L0 扫描时由口岸填的），store 读完是 0；
    // mtime / pending_metadata 的往返由下一条用例用直构样本覆盖。
    try std.testing.expectEqual(@as(i64, 0), kick.mtime);
    try std.testing.expectEqual(@as(u64, 1234567890123), kick.identity.?.file_index);
    try std.testing.expectEqual(@as(u32, 305419896), kick.identity.?.volume_serial);

    const snare = decoded.sampleById("s2").?;
    try std.testing.expect(snare.is_copy);
    try std.testing.expectEqual(@as(u32, 3), snare.copy_index);
    try std.testing.expectEqualStrings("s1", snare.original_id);
    try std.testing.expect(snare.identity == null);

    try std.testing.expectEqualStrings("鼓", decoded.groupById("g1").?.name);
    try std.testing.expectEqualStrings("#112233", decoded.groupById("g1").?.color);
    try std.testing.expect(decoded.folderById("f1").?.is_expanded);
    try std.testing.expectEqual(@as(i64, 3), decoded.folderById("f1").?.order);
    try std.testing.expectEqualStrings("g2", decoded.group_order[0]);
    try std.testing.expect(!decoded.settings.window.always_on_top);
    try std.testing.expectEqual(@as(f64, 0.75), decoded.settings.window.opacity);
    try std.testing.expectEqual(@as(?i64, 12), decoded.settings.window.x);
    try std.testing.expect(decoded.settings.copy.keep_copies);
    try std.testing.expect(decoded.settings.folder.enable_chinese_pinyin_fuzzy_search);

    // 再编码一次：CRC、字段顺序、长度都与第一次相同，说明没有丢字段。
    const second = try binary.encode(allocator, &decoded);
    defer allocator.free(second);
    try std.testing.expectEqualSlices(u8, first, second);
}

test "空库也能往返" {
    var library = try store.load(allocator, "{}");
    defer library.deinit();

    const bytes = try binary.encode(allocator, &library);
    defer allocator.free(bytes);
    try std.testing.expect(binary.isOtto(bytes));

    var decoded = try decodedCopy(bytes);
    defer decoded.deinit();
    try std.testing.expectEqual(@as(usize, 0), decoded.samples.len);
    try std.testing.expectEqual(@as(usize, 0), decoded.groups.len);
    try std.testing.expectEqual(@as(usize, 0), decoded.folders.len);
}

test "四个具名损坏错误：BadMagic / UnknownVersion / Truncated / ChecksumMismatch" {
    var library = try loadFixture();
    defer library.deinit();
    const valid = try binary.encode(allocator, &library);
    defer allocator.free(valid);

    // magic 错
    {
        const broken = try allocator.dupe(u8, valid);
        defer allocator.free(broken);
        broken[0] = 'X';
        try std.testing.expectError(error.BadMagic, binary.decode(allocator, broken));
    }

    // 版本未知
    {
        const broken = try allocator.dupe(u8, valid);
        defer allocator.free(broken);
        std.mem.writeInt(u16, broken[8..10], 2, .little);
        try std.testing.expectError(error.UnknownVersion, binary.decode(allocator, broken));
    }

    // 截断一半 / 截掉 CRC 尾
    try std.testing.expectError(error.Truncated, binary.decode(allocator, valid[0 .. valid.len / 2]));
    try std.testing.expectError(error.Truncated, binary.decode(allocator, valid[0 .. valid.len - 1]));

    // 改 payload 里的一个字节：CRC 兜住
    {
        const broken = try allocator.dupe(u8, valid);
        defer allocator.free(broken);
        broken[binary.header_size + binary.settings_bytes + 2] ^= 0xFF;
        try std.testing.expectError(error.ChecksumMismatch, binary.decode(allocator, broken));
    }
}

test "TooLarge：头里的数量超限、单字符串超限" {
    var library = try loadFixture();
    defer library.deinit();
    const valid = try binary.encode(allocator, &library);
    defer allocator.free(valid);

    // 样本数写成 u32 上限：在分配之前就该被拦下。
    {
        const broken = try allocator.dupe(u8, valid);
        defer allocator.free(broken);
        std.mem.writeInt(u32, broken[12..16], std.math.maxInt(u32), .little);
        try std.testing.expectError(error.TooLarge, binary.decode(allocator, broken));
    }

    // 第一个样本的 id 长度写成 1 MiB + 1（CRC 重算，穿过 CRC 检查）。
    {
        const broken = try allocator.dupe(u8, valid);
        defer allocator.free(broken);
        const length_offset = binary.header_size + binary.settings_bytes;
        const too_long: u32 = @intCast(binary.max_string_bytes + 1);
        std.mem.writeInt(u32, broken[length_offset..][0..4], too_long, .little);
        patchChecksum(broken);
        try std.testing.expectError(error.TooLarge, binary.decode(allocator, broken));
    }
}

test "Corrupt：保留位 / 非法判别字节" {
    var library = try loadFixture();
    defer library.deinit();
    const valid = try binary.encode(allocator, &library);
    defer allocator.free(valid);

    // flags 非 0
    {
        const broken = try allocator.dupe(u8, valid);
        defer allocator.free(broken);
        std.mem.writeInt(u16, broken[10..12], 1, .little);
        try std.testing.expectError(error.Corrupt, binary.decode(allocator, broken));
    }

    // 第一个样本的 has_folder 字节改成 2（合法值只有 0/1）
    {
        const broken = try allocator.dupe(u8, valid);
        defer allocator.free(broken);
        var offset = binary.header_size + binary.settings_bytes;
        // id / file_name / file_ext / file_path 四个字符串
        for (0..4) |_| {
            const length = std.mem.readInt(u32, broken[offset..][0..4], .little);
            offset += 4 + length;
        }
        broken[offset] = 2;
        patchChecksum(broken);
        try std.testing.expectError(error.Corrupt, binary.decode(allocator, broken));
    }
}

test "定长字段：mtime / pending_metadata / identity / duration 原样往返" {
    // 直接从模型构造：store.load 不解析 mtime（那是口岸扫描时才有的字段）。
    const library = store.Library{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .samples = &.{.{
            .id = "s9",
            .file_name = "Scan",
            .file_ext = ".wav",
            .file_path = "D:/scan/Scan.wav",
            .duration = 2.345,
            .sample_rate = 44100,
            .channels = 1,
            .file_size = 987654321,
            .mtime = 1700000000999,
            .imported_at = 1700000001000,
            .identity = .{ .volume_serial = 0xDEADBEEF, .file_index = 0x1_0000_0002 },
            .pending_metadata = true,
        }},
        .groups = &.{},
        .folders = &.{},
        .sample_index = .{},
        .group_index = .{},
        .folder_index = .{},
        .folder_order = &.{},
        .group_order = &.{},
        .settings = .{},
        .report = .{},
    };

    const bytes = try binary.encode(allocator, &library);
    defer allocator.free(bytes);
    var decoded = try decodedCopy(bytes);
    defer decoded.deinit();

    const sample = decoded.samples[0];
    try std.testing.expectEqual(@as(i64, 1700000000999), sample.mtime);
    try std.testing.expectEqual(@as(i64, 1700000001000), sample.imported_at);
    try std.testing.expectEqual(@as(u64, 987654321), sample.file_size);
    try std.testing.expectEqual(@as(f64, 2.345), sample.duration);
    try std.testing.expect(sample.pending_metadata);
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), sample.identity.?.volume_serial);
    try std.testing.expectEqual(@as(u64, 0x1_0000_0002), sample.identity.?.file_index);
}

test "Corrupt：重复 id / 悬空引用（编码不校验关系，解码必须拒绝）" {
    {
        const library = store.Library{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .samples = &.{
                .{ .id = "dup", .file_name = "a", .file_ext = ".wav", .file_path = "D:/a.wav" },
                .{ .id = "dup", .file_name = "b", .file_ext = ".wav", .file_path = "D:/b.wav" },
            },
            .groups = &.{},
            .folders = &.{},
            .sample_index = .{},
            .group_index = .{},
            .folder_index = .{},
            .folder_order = &.{},
            .group_order = &.{},
            .settings = .{},
            .report = .{},
        };
        const bytes = try binary.encode(allocator, &library);
        defer allocator.free(bytes);
        try std.testing.expectError(error.Corrupt, binary.decode(allocator, bytes));
    }

    {
        // 分组指向一个不存在的样本 id：格式长度/CRC 都对，但引用不闭合。
        const library = store.Library{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .samples = &.{.{
                .id = "s1",
                .file_name = "a",
                .file_ext = ".wav",
                .file_path = "D:/a.wav",
            }},
            .groups = &.{.{
                .id = "g1",
                .name = "G",
                .sample_ids = &.{"ghost"},
            }},
            .folders = &.{},
            .sample_index = .{},
            .group_index = .{},
            .folder_index = .{},
            .folder_order = &.{},
            .group_order = &.{},
            .settings = .{},
            .report = .{},
        };
        const bytes = try binary.encode(allocator, &library);
        defer allocator.free(bytes);
        try std.testing.expectError(error.Corrupt, binary.decode(allocator, bytes));
    }
}

test "编码侧的 TooLarge：单个字段超过 1 MiB" {
    const huge = try allocator.alloc(u8, binary.max_string_bytes + 1);
    defer allocator.free(huge);
    @memset(huge, 'x');

    const library = store.Library{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .samples = &.{.{
            .id = "s1",
            .file_name = "huge",
            .file_ext = ".bin",
            .file_path = huge,
        }},
        .groups = &.{},
        .folders = &.{},
        .sample_index = .{},
        .group_index = .{},
        .folder_index = .{},
        .folder_order = &.{},
        .group_order = &.{},
        .settings = .{},
        .report = .{},
    };
    try std.testing.expectError(error.TooLarge, binary.encode(allocator, &library));
}

test "任意截断或翻转一个字节都返回错误，不 panic" {
    var library = try store.load(allocator, "{}");
    defer library.deinit();
    const valid = try binary.encode(allocator, &library);
    defer allocator.free(valid);

    var cut: usize = 0;
    while (cut < valid.len) : (cut += 1) {
        if (binary.decode(allocator, valid[0..cut])) |value| {
            var leaked = value;
            leaked.deinit();
            return error.TestUnexpectedResult;
        } else |_| {}
    }

    for (valid, 0..) |_, offset| {
        const broken = try allocator.dupe(u8, valid);
        defer allocator.free(broken);
        broken[offset] ^= 0xFF;
        if (binary.decode(allocator, broken)) |value| {
            var leaked = value;
            leaked.deinit();
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}
