//! 库文件口岸测试：真文件系统 + 真 `MoveFileExW`，没有 mock。
//!
//! 覆盖任务要求的四条：
//!   1. 原子替换后读回新内容，旧文件更长的尾巴不残留；
//!   2. 成功路径不留 `.tmp`；
//!   3. 目标只读时返回 `error.ReadOnly`，临时文件被清掉，原文件一个字节没动；
//!   4. 读取上限 / 缺失文件 / 空路径分别给出具名错误。
//!
//! 每个用例自己的 tmpDir；不弹窗、不抢焦点。

const std = @import("std");
const library_file = @import("library_file.zig");

const allocator = std.testing.allocator;
const io = std.testing.io;

const FILE_ATTRIBUTE_READONLY: u32 = 0x0000_0001;
const FILE_ATTRIBUTE_NORMAL: u32 = 0x0000_0080;

extern "kernel32" fn SetFileAttributesW(
    file_name: [*:0]const u16,
    attributes: u32,
) callconv(.winapi) i32;

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

    fn path(self: *const Fixture, buffer: []u8, name: []const u8) ![]const u8 {
        return std.fmt.bufPrint(buffer, "{s}{s}{s}", .{
            self.root[0..self.root_len],
            std.fs.path.sep_str,
            name,
        });
    }

    fn exists(self: *const Fixture, name: []const u8) bool {
        _ = self.tmp.dir.statFile(io, name, .{}) catch return false;
        return true;
    }

    fn read(self: *const Fixture, name: []const u8) ![]u8 {
        return self.tmp.dir.readFileAlloc(io, name, allocator, .limited(1024 * 1024));
    }
};

fn setAttributes(path: []const u8, attributes: u32) !void {
    const wide = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, path);
    defer allocator.free(wide);
    if (SetFileAttributesW(wide.ptr, attributes) == 0) return error.TestUnexpectedResult;
}

test "原子替换：新内容覆盖旧文件，长尾巴不残留，tmp 不留下" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try fixture.path(&buffer, "library.otto");

    try library_file.writeAtomic(allocator, io, path, "first-version-with-a-long-tail");
    try std.testing.expect(!fixture.exists("library.otto.tmp"));

    const first = try fixture.read("library.otto");
    defer allocator.free(first);
    try std.testing.expectEqualStrings("first-version-with-a-long-tail", first);

    try library_file.writeAtomic(allocator, io, path, "v2");
    try std.testing.expect(!fixture.exists("library.otto.tmp"));

    const second = try fixture.read("library.otto");
    defer allocator.free(second);
    try std.testing.expectEqualStrings("v2", second);
    try std.testing.expectEqual(@as(usize, 2), second.len);

    // 二进制原样往返（含 0 字节）。
    const payload = [_]u8{ 0x00, 0xFF, 0x10, 0x00, 'O', 'T', 'T', 'O' };
    try library_file.writeAtomic(allocator, io, path, &payload);
    const third = try fixture.read("library.otto");
    defer allocator.free(third);
    try std.testing.expectEqualSlices(u8, &payload, third);
}

test "只读目标：error.ReadOnly，原文件不动，tmp 清掉" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    if (!library_file.supported) return error.SkipZigTest;

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try fixture.path(&buffer, "readonly.otto");

    try library_file.writeAtomic(allocator, io, path, "original");
    try setAttributes(path, FILE_ATTRIBUTE_READONLY);
    defer setAttributes(path, FILE_ATTRIBUTE_NORMAL) catch {};

    try std.testing.expectError(
        error.ReadOnly,
        library_file.writeAtomic(allocator, io, path, "replacement"),
    );

    // 临时文件不能留在目标旁边；原文件必须一个字节都没变。
    try std.testing.expect(!fixture.exists("readonly.otto.tmp"));
    const kept = try fixture.read("readonly.otto");
    defer allocator.free(kept);
    try std.testing.expectEqualStrings("original", kept);

    // 去掉只读位后同一路径可以正常替换。
    try setAttributes(path, FILE_ATTRIBUTE_NORMAL);
    try library_file.writeAtomic(allocator, io, path, "replacement");
    const replaced = try fixture.read("readonly.otto");
    defer allocator.free(replaced);
    try std.testing.expectEqualStrings("replacement", replaced);
}

test "readAll：上限、缺失文件、空路径" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try fixture.path(&buffer, "bytes.bin");
    try library_file.writeAtomic(allocator, io, path, "0123456789");

    // std 的 limit 语义是"达到或超过"：读满 10 字节要传 11。
    const exact = try library_file.readAll(allocator, io, path, 11);
    defer allocator.free(exact);
    try std.testing.expectEqualStrings("0123456789", exact);

    try std.testing.expectError(
        error.FileTooLarge,
        library_file.readAll(allocator, io, path, 9),
    );

    const missing = try fixture.path(&buffer, "missing.otto");
    try std.testing.expectError(
        error.FileNotFound,
        library_file.readAll(allocator, io, missing, 1024),
    );

    try std.testing.expectError(
        error.InvalidPath,
        library_file.readAll(allocator, io, "", 1024),
    );
    try std.testing.expectError(
        error.InvalidPath,
        library_file.writeAtomic(allocator, io, "", "x"),
    );
}

test "目标路径是目录：明确拒绝，不留下 tmp" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try fixture.tmp.dir.createDir(io, "target.otto", .default_dir);

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try fixture.path(&buffer, "target.otto");
    try std.testing.expectError(
        error.InvalidPath,
        library_file.writeAtomic(allocator, io, path, "x"),
    );
    try std.testing.expect(!fixture.exists("target.otto.tmp"));
    try std.testing.expect(fixture.exists("target.otto"));
}
