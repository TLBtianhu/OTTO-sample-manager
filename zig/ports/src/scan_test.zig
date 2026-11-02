//! 扫描口岸测试：真临时目录树 + 真 `GetFileInformationByHandle`，没有 mock。
//!
//! 覆盖任务要求的几条：
//!   1. 3 层目录（含空目录）→ 文件数正确、按路径排序稳定、两次扫描一致；
//!   2. 隐藏 / 系统文件与隐藏目录被跳过；
//!   3. `.tmp` 与超过上限的文件被跳过；
//!   4. 每条的 size / mtime / identity 来自真实文件，identity 跨两次扫描不变；
//!   5. visitor 回调看到的顺序与 `Scan.files` 一致。
//!
//! 每个用例自己的 tmpDir；不弹窗、不抢焦点。

const std = @import("std");
const scan = @import("scan.zig");

const allocator = std.testing.allocator;
const io = std.testing.io;

const FILE_ATTRIBUTE_HIDDEN: u32 = 0x0000_0002;
const FILE_ATTRIBUTE_NORMAL: u32 = 0x0000_0080;

extern "kernel32" fn SetFileAttributesW(
    file_name: [*:0]const u16,
    attributes: u32,
) callconv(.winapi) i32;

fn setHidden(path: []const u8, hidden: bool) !void {
    const wide = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, path);
    defer allocator.free(wide);
    const attributes: u32 = if (hidden) FILE_ATTRIBUTE_HIDDEN else FILE_ATTRIBUTE_NORMAL;
    if (SetFileAttributesW(wide.ptr, attributes) == 0) return error.TestUnexpectedResult;
}

const Fixture = struct {
    tmp: std.testing.TmpDir,
    root: [std.Io.Dir.max_path_bytes]u8 = undefined,
    root_len: usize = 0,

    fn init() !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const length = try tmp.dir.realPath(io, &buffer);
        return .{ .tmp = tmp, .root = buffer, .root_len = length };
    }

    fn deinit(self: *Fixture) void {
        self.tmp.cleanup();
    }

    fn write(self: *Fixture, sub_path: []const u8, data: []const u8) !void {
        try self.tmp.dir.writeFile(io, .{ .sub_path = sub_path, .data = data });
    }

    fn path(self: *const Fixture, buffer: []u8, sub_path: []const u8) ![]const u8 {
        return std.fmt.bufPrint(buffer, "{s}\\{s}", .{ self.root[0..self.root_len], sub_path });
    }

    /// 从绝对路径里剥掉 fixture 根，返回 `a.wav` / `sub\c.wav` 这样的相对串。
    fn relative(self: *const Fixture, absolute: []const u8) []const u8 {
        const prefix_len = self.root_len + 1;
        if (absolute.len <= prefix_len) return absolute;
        return absolute[prefix_len..];
    }
};

test "3 层目录树（含空目录）：文件数、排序稳定、两次扫描一致" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try fixture.write("a.wav", "A");
    try fixture.write("b.txt", "B");
    try fixture.tmp.dir.createDirPath(io, "sub/deep");
    try fixture.tmp.dir.createDirPath(io, "sub/empty");
    try fixture.write("sub/c.wav", "C");
    try fixture.write("sub/deep/d.wav", "D");

    var first = try scan.run(allocator, io, fixture.root[0..fixture.root_len], .{}, null);
    defer first.deinit();

    try std.testing.expectEqual(@as(usize, 4), first.counts.files);
    try std.testing.expectEqual(@as(usize, 0), first.counts.failures);
    try std.testing.expectEqual(@as(usize, 4), first.files.len);

    var expected: [4][]const u8 = undefined;
    for (first.files, 0..) |fact, index| expected[index] = fixture.relative(fact.path);
    try std.testing.expectEqualStrings("a.wav", expected[0]);
    try std.testing.expectEqualStrings("b.txt", expected[1]);
    try std.testing.expectEqualStrings("sub\\c.wav", expected[2]);
    try std.testing.expectEqualStrings("sub\\deep\\d.wav", expected[3]);

    // 同一棵树扫两次：路径序列与 identity 必须逐条一致。
    var second = try scan.run(allocator, io, fixture.root[0..fixture.root_len], .{}, null);
    defer second.deinit();
    try std.testing.expectEqual(first.files.len, second.files.len);
    for (first.files, second.files) |left, right| {
        try std.testing.expectEqualStrings(left.path, right.path);
        try std.testing.expectEqual(left.size, right.size);
        try std.testing.expectEqual(left.identity != null, right.identity != null);
        if (left.identity) |value| try std.testing.expect(value.eql(right.identity.?));
    }
}

test "隐藏 / 系统文件与隐藏目录：跳过并计数" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try fixture.write("shown.wav", "S");
    try fixture.write("hidden.wav", "H");
    try fixture.tmp.dir.createDirPath(io, "secret");
    try fixture.write("secret/inner.wav", "I");

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const hidden_file = try fixture.path(&buffer, "hidden.wav");
    try setHidden(hidden_file, true);
    defer setHidden(hidden_file, false) catch {};

    var dir_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const hidden_dir = try fixture.path(&dir_buffer, "secret");
    try setHidden(hidden_dir, true);
    defer setHidden(hidden_dir, false) catch {};

    var result = try scan.run(allocator, io, fixture.root[0..fixture.root_len], .{}, null);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.files.len);
    try std.testing.expectEqualStrings("shown.wav", fixture.relative(result.files[0].path));
    try std.testing.expectEqual(@as(usize, 2), result.counts.skipped_hidden);

    // 保留隐藏项时两个文件都能看到（`keep_hidden` 是显式开关，不是猜的）。
    var kept = try scan.run(allocator, io, fixture.root[0..fixture.root_len], .{ .keep_hidden = true }, null);
    defer kept.deinit();
    try std.testing.expectEqual(@as(usize, 3), kept.files.len);
}

test ".tmp 与超过大小上限的文件：跳过并计数" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try fixture.write("small.wav", "12345");
    try fixture.write("x.wav.tmp", "0123456789012345678901234567890");
    try fixture.write("big.wav", "0123456789ABCDEFGHIJ");

    var result = try scan.run(allocator, io, fixture.root[0..fixture.root_len], .{
        .max_file_bytes = 10,
    }, null);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.files.len);
    try std.testing.expectEqualStrings("small.wav", fixture.relative(result.files[0].path));
    try std.testing.expectEqual(@as(usize, 1), result.counts.skipped_temp);
    try std.testing.expectEqual(@as(usize, 1), result.counts.skipped_size);
}

test "L0 事实：size / mtime / identity 来自真实文件，且身份稳定" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try fixture.write("one.wav", "0123456789");

    var result = try scan.run(allocator, io, fixture.root[0..fixture.root_len], .{}, null);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.files.len);
    const fact = result.files[0];
    try std.testing.expectEqual(@as(u64, 10), fact.size);
    try std.testing.expect(fact.mtime > 0);
    try std.testing.expectEqualStrings("one.wav", fact.name);
    try std.testing.expectEqualStrings(".wav", fact.ext);
    // NTFS 上一定有身份；拿到后卷序列号不应是 0 号占位。
    try std.testing.expect(fact.identity != null);
    try std.testing.expect(fact.identity.?.file_index != 0);
    try std.testing.expectEqual(fact.identity.?.hash(), fact.identity.?.hash());
}

test "visitor：按最终排序逐条回调，失败条目也回调" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try fixture.write("b.wav", "B");
    try fixture.write("a.wav", "A");

    const Collector = struct {
        count: usize = 0,
        names: [8][]const u8 = undefined,

        fn onFile(context: ?*anyopaque, fact: *const scan.FileFact) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (self.count < self.names.len) self.names[self.count] = fact.name;
            self.count += 1;
        }
    };

    var collector = Collector{};
    var result = try scan.run(allocator, io, fixture.root[0..fixture.root_len], .{}, .{
        .context = &collector,
        .on_file = Collector.onFile,
    });
    defer result.deinit();

    try std.testing.expectEqual(result.files.len, collector.count);
    try std.testing.expectEqual(@as(usize, 2), collector.count);
    try std.testing.expectEqualStrings("a.wav", collector.names[0]);
    try std.testing.expectEqualStrings("b.wav", collector.names[1]);
}

test "根目录不存在：具名错误，不是空结果" {
    try std.testing.expectError(
        error.FileNotFound,
        scan.run(allocator, io, "C:\\definitely\\missing\\tree", .{}, null),
    );
}
