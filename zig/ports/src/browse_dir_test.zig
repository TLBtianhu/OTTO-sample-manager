//! `browse_dir.zig` 的测试：真临时目录 + 真 FindFirstFileExW，不碰网络、不建窗口。
//!
//! 钉住的四件事：
//!   * 只列直接子项（`. ` / `..` 不出现，子目录出现且 `isDirectory` 为真）；
//!   * 空目录 `next` 直接返回 null（不是"第一条是 ."）；
//!   * 打不开的路径是**具名错误**（文件 ≠ 目录、不存在、无权限各一条）；
//!   * 身份跨改名不变（NTFS 上的 File ID 语义），FAT/网络盘返回 null 不算失败。

const std = @import("std");
const browse_dir = @import("browse_dir.zig");
const testing = std.testing;

fn realPath(tmp: *std.testing.TmpDir, buffer: []u8) ![]const u8 {
    const len = try tmp.dir.realPath(testing.io, buffer);
    return buffer[0..len];
}

test "枚举：只列直接子项，子目录带 DIRECTORY 位，点条目被跳过" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "kick.wav", .data = "1234" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "snare.mp3", .data = "12" });
    try tmp.dir.createDirPath(testing.io, "sub");

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try realPath(&tmp, &buffer);

    var it = try browse_dir.Iterator.open(testing.allocator, root);
    defer it.close();

    var files: usize = 0;
    var dirs: usize = 0;
    var saw_kick = false;
    while (try it.next()) |entry| {
        try testing.expect(!std.mem.eql(u8, entry.name, "."));
        try testing.expect(!std.mem.eql(u8, entry.name, ".."));
        if (entry.isDirectory()) {
            dirs += 1;
            try testing.expectEqualStrings("sub", entry.name);
            continue;
        }
        files += 1;
        if (std.mem.eql(u8, entry.name, "kick.wav")) {
            saw_kick = true;
            try testing.expectEqual(@as(u64, 4), entry.size);
            try testing.expect(entry.mtime > 0);
        }
    }
    try testing.expectEqual(@as(usize, 1), dirs);
    try testing.expectEqual(@as(usize, 2), files);
    try testing.expect(saw_kick);
    try testing.expectEqual(@as(u32, 0), it.skipped);
}

test "空目录：next 返回 null（不是一条 .）" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try realPath(&tmp, &buffer);

    var it = try browse_dir.Iterator.open(testing.allocator, root);
    defer it.close();
    try testing.expectEqual(@as(?browse_dir.Entry, null), try it.next());
}

test "打不开的路径是具名错误：文件 / 不存在 / 非法" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.wav", .data = "x" });

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try realPath(&tmp, &buffer);

    const file_path = try std.fs.path.join(testing.allocator, &.{ root, "a.wav" });
    defer testing.allocator.free(file_path);
    try testing.expectError(error.NotDirectory, browse_dir.Iterator.open(testing.allocator, file_path));

    const missing = try std.fs.path.join(testing.allocator, &.{ root, "no-such-dir" });
    defer testing.allocator.free(missing);
    try testing.expectError(error.PathNotFound, browse_dir.Iterator.open(testing.allocator, missing));

    try testing.expectError(error.InvalidPath, browse_dir.Iterator.open(testing.allocator, ""));
}

test "中文与长名字：宽字符 → WTF-8 往返不丢字" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const chinese = "素材-鼓组-01.wav";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "素材-鼓组-01.wav", .data = "z" });

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try realPath(&tmp, &buffer);

    var it = try browse_dir.Iterator.open(testing.allocator, root);
    defer it.close();
    var found = false;
    while (try it.next()) |entry| {
        if (entry.isDirectory()) continue;
        try testing.expectEqualStrings(chinese, entry.name);
        found = true;
    }
    try testing.expect(found);
}

test "身份：同一文件改名后不变；不存在的文件是错误" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "before.wav", .data = "abcd" });

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try realPath(&tmp, &buffer);

    const before = try std.fs.path.join(testing.allocator, &.{ root, "before.wav" });
    defer testing.allocator.free(before);
    const after = try std.fs.path.join(testing.allocator, &.{ root, "after.wav" });
    defer testing.allocator.free(after);

    const first = try browse_dir.identityOf(testing.io, before);
    try testing.expect(first != null);
    try testing.expect(first.?.file_index != 0);

    try tmp.dir.rename("before.wav", tmp.dir, "after.wav", testing.io);
    const second = try browse_dir.identityOf(testing.io, after);
    try testing.expect(second != null);
    try testing.expect(first.?.eql(second.?));

    try testing.expectError(error.FileNotFound, browse_dir.identityOf(testing.io, before));
}

test "批量：300 条计数正确，skipped 为 0（名字都合法）" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var name_buffer: [64]u8 = undefined;
    for (0..300) |index| {
        const name = try std.fmt.bufPrint(&name_buffer, "item-{d:0>3}.wav", .{index});
        try tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = "x" });
    }

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try realPath(&tmp, &buffer);

    var it = try browse_dir.Iterator.open(testing.allocator, root);
    defer it.close();
    var count: usize = 0;
    while (try it.next()) |entry| {
        if (entry.isDirectory()) continue;
        count += 1;
    }
    try testing.expectEqual(@as(usize, 300), count);
    try testing.expectEqual(@as(u32, 0), it.skipped);
}
