//! 拖出口岸测试：纯 CF_HDROP 契约 + 真 Shell 数据对象自检，没有 mock。
//!
//! 规矩（照抄 thumb_test.zig / watch_test.zig）：
//!   * 每个用例自己的 tmpDir，互不干扰；
//!   * 不创建窗口、不抢焦点、**不动真实剪贴板**——`copyToClipboard` 只测参数校验，
//!     且校验发生在 `OleInitialize` / `OleSetClipboard` 之前；
//!   * `start()` 不测：没有真实放置目标，测不了拖拽交互。取而代之的是
//!     `drag.selftest()`：构造 Shell 数据对象、查询格式、读回 `CF_HDROP` 载荷。
//!
//! 覆盖：
//!   1. 3 条路径 → 顺序 / 双 NUL / fWide=1 / pFiles=20 全部对得上；
//!   2. 空列表 → InvalidPath；
//!   3. 中文多字节路径、超长路径（> MAX_PATH）编码正确；
//!   4. 空路径元素 / 非法 WTF-8 → InvalidPath；
//!   5. copyToClipboard 的空列表 / 不存在 / 目录 → InvalidPath，不碰剪贴板；
//!   6. selftest：真临时文件 → Shell 数据对象的 CF_HDROP 可读、文本被拒。

const std = @import("std");
const drag = @import("drag.zig");

const allocator = std.testing.allocator;
const io = std.testing.io;

// ---------------------------------------------------------------------------
// 装置
// ---------------------------------------------------------------------------

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

    fn path(self: *const Fixture, name: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{
            self.root[0..self.root_len],
            std.fs.path.sep_str,
            name,
        });
    }

    fn write(self: *Fixture, name: []const u8, bytes: []const u8) !void {
        try self.tmp.dir.writeFile(io, .{ .sub_path = name, .data = bytes });
    }
};

/// 把 buildHdrop 的输出解析回来，逐条与 expected 比对，并检查头与双 NUL。
fn expectHdrop(bytes: []const u8, expected: []const []const u8) !void {
    try std.testing.expectEqual(@as(usize, 20), drag.dropfiles_size);
    try std.testing.expect(bytes.len >= drag.dropfiles_size);

    // DROPFILES: pFiles / pt / fNC / fWide
    try std.testing.expectEqual(
        @as(u32, @intCast(@sizeOf(drag.DROPFILES))),
        std.mem.readInt(u32, bytes[0..4], .little),
    );
    try std.testing.expectEqual(@as(i32, 0), std.mem.readInt(i32, bytes[4..8], .little));
    try std.testing.expectEqual(@as(i32, 0), std.mem.readInt(i32, bytes[8..12], .little));
    try std.testing.expectEqual(@as(i32, 0), std.mem.readInt(i32, bytes[12..16], .little));
    try std.testing.expectEqual(@as(i32, 1), std.mem.readInt(i32, bytes[16..20], .little));

    var offset: usize = drag.dropfiles_size;
    for (expected) |path| {
        const wide = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, path);
        defer allocator.free(wide);

        for (wide) |unit| {
            try std.testing.expect(offset + 2 <= bytes.len);
            const actual = std.mem.readInt(u16, bytes[offset..][0..2], .little);
            try std.testing.expectEqual(unit, actual);
            offset += 2;
        }
        try std.testing.expect(offset + 2 <= bytes.len);
        try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, bytes[offset..][0..2], .little));
        offset += 2;
    }

    // 最后一条路径的 NUL 之后恰好还有一个 NUL：双 NUL 结尾，且没有多余字节。
    try std.testing.expectEqual(bytes.len, offset + 2);
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, bytes[offset..][0..2], .little));
}

// ---------------------------------------------------------------------------
// 1–5：buildHdrop 纯函数
// ---------------------------------------------------------------------------

test "3 条路径：顺序、双 NUL、fWide=1、pFiles=20 全部对得上" {
    const paths = [_][]const u8{
        "C:\\素材\\底鼓 01.wav",
        "D:\\samples\\snare.mp3",
        "E:\\三个 空格\\loop final.flac",
    };
    const bytes = try drag.buildHdrop(allocator, &paths);
    defer allocator.free(bytes);

    try expectHdrop(bytes, &paths);
}

test "空列表 → InvalidPath" {
    try std.testing.expectError(error.InvalidPath, drag.buildHdrop(allocator, &.{}));
}

test "空路径元素 / 含 NUL / 非法 WTF-8 → InvalidPath" {
    try std.testing.expectError(error.InvalidPath, drag.buildHdrop(allocator, &.{""}));
    try std.testing.expectError(error.InvalidPath, drag.buildHdrop(allocator, &.{ "ok.wav", "" }));
    try std.testing.expectError(error.InvalidPath, drag.buildHdrop(allocator, &.{"bad\x00path.wav"}));
    try std.testing.expectError(error.InvalidPath, drag.buildHdrop(allocator, &.{"\xFF\xFE"}));
}

test "中文路径按 UTF-16LE 逐码元对得上（不是 UTF-8 直出）" {
    const paths = [_][]const u8{
        "C:\\素材\\鼓组\\底鼓 01.wav",
        "C:\\素材\\贝斯\\贝斯 02.wav",
    };
    const bytes = try drag.buildHdrop(allocator, &paths);
    defer allocator.free(bytes);

    try expectHdrop(bytes, &paths);
}

test "超长路径：无 MAX_PATH 固定缓冲假设；超过 32767 码元才拒绝" {
    // > MAX_PATH（260），但远小于 Windows 长路径上限。
    const long = try allocator.alloc(u8, 1200);
    defer allocator.free(long);
    @memset(long, 'a');
    @memcpy(long[long.len - 4 ..], ".wav");

    const paths = [_][]const u8{long};
    const bytes = try drag.buildHdrop(allocator, &paths);
    defer allocator.free(bytes);
    try expectHdrop(bytes, &paths);
    try std.testing.expect(bytes.len > 260 * 2);

    // 32767 个码元是 Windows 的上限：刚好能装下，再多一个就 InvalidPath。
    const at_limit = try allocator.alloc(u8, drag.max_path_units);
    defer allocator.free(at_limit);
    @memset(at_limit, 'b');
    const at_limit_paths = [_][]const u8{at_limit};
    const at_limit_bytes = try drag.buildHdrop(allocator, &at_limit_paths);
    defer allocator.free(at_limit_bytes);
    try expectHdrop(at_limit_bytes, &at_limit_paths);

    const over_limit = try allocator.alloc(u8, drag.max_path_units + 1);
    defer allocator.free(over_limit);
    @memset(over_limit, 'c');
    try std.testing.expectError(error.InvalidPath, drag.buildHdrop(allocator, &.{over_limit}));
}

test "DROPFILES 结构体在 Win64 上必须是 20 字节" {
    try std.testing.expectEqual(@as(usize, 20), @sizeOf(drag.DROPFILES));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(drag.DROPFILES, "pFiles"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(drag.DROPFILES, "fWide"));
}

// ---------------------------------------------------------------------------
// 6：copyToClipboard 只做参数校验（绝不碰真实剪贴板）
// ---------------------------------------------------------------------------

test "copyToClipboard 参数校验：空列表 / 不存在 / 目录 → InvalidPath，不碰剪贴板" {
    // 空列表
    try std.testing.expectError(error.InvalidPath, drag.copyToClipboard(allocator, &.{}));

    var fixture = try Fixture.init();
    defer fixture.deinit();

    // 不存在
    const missing = try fixture.path("missing.wav");
    defer allocator.free(missing);
    try std.testing.expectError(error.InvalidPath, drag.copyToClipboard(allocator, &.{missing}));

    // 目录（存在，但不是文件）
    const directory: []const u8 = fixture.root[0..fixture.root_len];
    try std.testing.expectError(
        error.InvalidPath,
        drag.copyToClipboard(allocator, &.{directory}),
    );

    // 合法文件不在这里调用：真实写入留给人工 / 演示命令。
}

// ---------------------------------------------------------------------------
// 7：不开窗自检（真 Shell 数据对象）
// ---------------------------------------------------------------------------

test "selftest：真文件 → CF_HDROP 可读、顺序与内容一致、文本格式被拒" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.write("底鼓 01.wav", "RIFF....WAVE");
    try fixture.write("snare.mp3", "ID3");
    try fixture.write("loop final.flac", "fLaC");

    const names = [_][]const u8{ "底鼓 01.wav", "snare.mp3", "loop final.flac" };
    var paths: [names.len][]const u8 = undefined;
    var count: usize = 0;
    defer for (paths[0..count]) |path| allocator.free(path);
    for (names, 0..) |name, index| {
        paths[index] = try fixture.path(name);
        count += 1;
    }

    try drag.selftest(allocator, &paths);
}

test "selftest：不存在 / 目录 → InvalidPath（校验在任何 Shell 调用之前）" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    const missing = try fixture.path("nope.wav");
    defer allocator.free(missing);
    const directory: []const u8 = fixture.root[0..fixture.root_len];

    try std.testing.expectError(error.InvalidPath, drag.selftest(allocator, &.{missing}));
    try std.testing.expectError(error.InvalidPath, drag.selftest(allocator, &.{directory}));
    try std.testing.expectError(error.InvalidPath, drag.selftest(allocator, &.{}));
}

test "InvalidPath 会把 Win32/HRESULT 错误码记进 lastFailure" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const missing = try fixture.path("nope.wav");
    defer allocator.free(missing);

    _ = drag.copyToClipboard(allocator, &.{missing}) catch {};
    try std.testing.expect(drag.lastFailure().code != 0);
}
