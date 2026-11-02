//! 缩略图能力表测试：真注册表 + 一个真 Shell 出图探针，没有 mock。
//!
//! 规矩（照抄 thumb_test.zig）：
//!   * 每个用例自己的 tmpDir，互不干扰；
//!   * 不创建窗口、不抢焦点；
//!   * 第 1 条先在这台机器上真探测一次：Shell 能出 .bmp 缩略图 → 能力表必须说
//!     "有 handler"，本机这条路径会走到 PerceivedType=image 回退；出不了图 →
//!     `error.SkipZigTest` 并打印实测原因，绝不为了"测试绿"伪造断言。
//!
//! 覆盖（对应任务 1–6）：
//!   1. `.bmp`：能力表与 Shell 实际出图一致（无 handler 则 Skip）；
//!   2. `.otto_probe`：不存在 → `has_handler=false`，不是错误；
//!   3. `.PSD` / `.psd` / `psd`：归一化后结果一致；
//!   4. `"..\\x"` / `""` 等非法输入 → `error.InvalidExtension`；
//!   5. 缓存：两次一致、`refresh()` 后一致、第二次是 `cache_hit`；
//!   6. CLSID 解析纯函数：长度 / 花括号 / 十六进制 / 连字符位置。
//! 另加：forPath 取扩展名、缓存容量上限、`.mp4` 直接登记的正控制组。

const std = @import("std");
const caps = @import("caps.zig");
const thumb = @import("thumb.zig");

const allocator = std.testing.allocator;
const io = std.testing.io;

// ---------------------------------------------------------------------------
// 装置：tmpDir + 手写最小 BMP（用来让 Shell 真出一次图）
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

    fn path(self: *const Fixture, buffer: []u8, name: []const u8) ![]const u8 {
        return std.fmt.bufPrint(buffer, "{s}{s}{s}", .{
            self.root[0..self.root_len],
            std.fs.path.sep_str,
            name,
        });
    }

    fn write(self: *Fixture, name: []const u8, bytes: []const u8) !void {
        try self.tmp.dir.writeFile(io, .{ .sub_path = name, .data = bytes });
    }
};

/// 手写最小 24bpp BMP（BI_RGB、行按 4 字节对齐）。上半红、下半蓝，与
/// thumb_test.zig 的装置同构；这里只关心 Shell 能不能出图。
fn buildBmp(allocator_: std.mem.Allocator, width: u32, height: u32) ![]u8 {
    const stride = (width * 3 + 3) & ~@as(u32, 3);
    const pixel_bytes = try std.math.mul(usize, stride, height);
    const total = 54 + pixel_bytes;
    const bytes = try allocator_.alloc(u8, total);
    errdefer allocator_.free(bytes);
    @memset(bytes, 0);

    bytes[0] = 'B';
    bytes[1] = 'M';
    std.mem.writeInt(u32, bytes[2..6], @intCast(total), .little);
    std.mem.writeInt(u32, bytes[10..14], 54, .little);
    std.mem.writeInt(u32, bytes[14..18], 40, .little);
    std.mem.writeInt(i32, bytes[18..22], @intCast(width), .little);
    std.mem.writeInt(i32, bytes[22..26], @intCast(height), .little);
    std.mem.writeInt(u16, bytes[26..28], 1, .little);
    std.mem.writeInt(u16, bytes[28..30], 24, .little);
    std.mem.writeInt(u32, bytes[34..38], @intCast(pixel_bytes), .little);

    var file_row: u32 = 0;
    while (file_row < height) : (file_row += 1) {
        const image_row = height - 1 - file_row;
        var column: u32 = 0;
        while (column < width) : (column += 1) {
            const offset = 54 + file_row * stride + column * 3;
            if (image_row < height / 2) {
                bytes[offset + 2] = 255; // R
            } else {
                bytes[offset + 0] = 255; // B
            }
        }
    }
    return bytes;
}

fn expectSameInfo(expected: caps.Info, actual: caps.Info) !void {
    try std.testing.expectEqual(expected.has_handler, actual.has_handler);
    try std.testing.expectEqual(expected.source, actual.source);
    if (expected.clsid) |expected_clsid| {
        const actual_clsid = actual.clsid orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualSlices(u8, expected_clsid[0..], actual_clsid[0..]);
    } else {
        try std.testing.expect(actual.clsid == null);
    }
}

// ---------------------------------------------------------------------------
// 1. 本机一致性：能力表 vs Shell 实际出图
// ---------------------------------------------------------------------------

test "本机 .bmp：能力表与 Shell 实际出图一致（无 handler 则 Skip）" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    const bmp = try buildBmp(allocator, 48, 32);
    defer allocator.free(bmp);
    try fixture.write("probe.bmp", bmp);

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try fixture.path(&path_buffer, "probe.bmp");

    caps.refresh();
    const info = try caps.forExtension(allocator, "bmp");

    // 独立探针：真让 Shell 出一次图。它走的不是 caps 的注册表代码，所以能证明
    // "能力表说没有"不是漏读。
    var image = thumb.get(allocator, path, 64) catch |err| switch (err) {
        error.NoHandler => {
            std.debug.print(
                ".bmp：本机 Shell 抽不出缩略图（NoHandler）；能力表 has_handler={}，按约定 Skip 不伪造断言\n",
                .{info.has_handler},
            );
            return error.SkipZigTest;
        },
        else => return err,
    };
    defer image.deinit(allocator);

    // Shell 真能出图 => 系统里必然有能覆盖 .bmp 的 IThumbnailProvider 登记。
    // 本机这条登记在 PerceivedType=image 下，不在直接键里；能力表若说 false，
    // 就是漏了回退链（也正是这条测试要防的回归）。
    try std.testing.expect(info.has_handler);
    try std.testing.expect(info.clsid != null);
    try std.testing.expect(caps.parseClsid(info.clsidText().?) != null);
}

// ---------------------------------------------------------------------------
// 2. 不存在的扩展名：false，不是错误
// ---------------------------------------------------------------------------

test ".otto_probe：没有 handler 不是错误" {
    caps.refresh();
    const info = try caps.forExtension(allocator, ".otto_probe");

    try std.testing.expect(!info.has_handler);
    try std.testing.expect(info.clsid == null);
    try std.testing.expectEqual(caps.Source.none, info.source);
    // 查询本身成功返回；诊断是"没有 handler"而不是 registry_error。
    try std.testing.expect(caps.lastDiagnostic() != .registry_error);
}

// ---------------------------------------------------------------------------
// 3. 大小写 / 前导点归一化
// ---------------------------------------------------------------------------

test ".PSD == .psd == psd（每次都重新查注册表，不靠缓存）" {
    caps.refresh();
    const dotted_upper = try caps.forExtension(allocator, ".PSD");
    caps.refresh();
    const dotted_lower = try caps.forExtension(allocator, ".psd");
    caps.refresh();
    const bare = try caps.forExtension(allocator, "psd");

    try expectSameInfo(dotted_upper, dotted_lower);
    try expectSameInfo(dotted_upper, bare);
}

test ".MP4 == mp4；本机有直接登记时 source 必须是 direct" {
    caps.refresh();
    const upper = try caps.forExtension(allocator, ".MP4");
    caps.refresh();
    const lower = try caps.forExtension(allocator, "mp4");

    try expectSameInfo(upper, lower);

    if (!upper.has_handler or upper.source != .direct) {
        std.debug.print(
            ".mp4：本机没有直接登记（has_handler={} source={s}），跳过直接路径断言\n",
            .{ upper.has_handler, @tagName(upper.source) },
        );
        return error.SkipZigTest;
    }

    try std.testing.expect(upper.clsid != null);
    try std.testing.expect(caps.parseClsid(upper.clsidText().?) != null);
}

// ---------------------------------------------------------------------------
// 4. 非法输入
// ---------------------------------------------------------------------------

test "非法扩展名 → error.InvalidExtension" {
    const invalid = [_][]const u8{
        "", // 空
        ".", // 只有点
        "...", // 归一化后为空
        "..\\x", // 反斜杠
        "a/b", // 正斜杠
        "C:psd", // 冒号
        "psd\\", // 尾随分隔符
    };
    for (invalid) |ext| {
        try std.testing.expectError(error.InvalidExtension, caps.forExtension(allocator, ext));
    }
}

test "扩展名归一化纯函数：去点、转小写、保留合法字符" {
    var buffer: [caps.max_extension_bytes]u8 = undefined;

    try std.testing.expectEqualStrings("psd", try caps.normalizeExtension("psd", &buffer));
    try std.testing.expectEqualStrings("psd", try caps.normalizeExtension(".psd", &buffer));
    try std.testing.expectEqualStrings("psd", try caps.normalizeExtension(".PSD", &buffer));
    try std.testing.expectEqualStrings("psd", try caps.normalizeExtension("..PsD", &buffer));
    try std.testing.expectEqualStrings("tar.gz", try caps.normalizeExtension(".TAR.GZ", &buffer));

    try std.testing.expectError(error.InvalidExtension, caps.normalizeExtension("", &buffer));
    try std.testing.expectError(error.InvalidExtension, caps.normalizeExtension(".", &buffer));
    try std.testing.expectError(error.InvalidExtension, caps.normalizeExtension("..\\x", &buffer));
    try std.testing.expectError(error.InvalidExtension, caps.normalizeExtension("a/b", &buffer));
    try std.testing.expectError(error.InvalidExtension, caps.normalizeExtension("C:psd", &buffer));
}

// ---------------------------------------------------------------------------
// 5. 缓存语义
// ---------------------------------------------------------------------------

test "缓存：两次一致、refresh 后一致、第二次是 cache_hit" {
    caps.refresh();

    const first = try caps.forExtension(allocator, ".otto_probe");
    const first_diagnostic = caps.lastDiagnostic();
    try std.testing.expect(first_diagnostic != .cache_hit);

    const second = try caps.forExtension(allocator, ".otto_probe");
    try std.testing.expectEqual(caps.Diagnostic.cache_hit, caps.lastDiagnostic());
    try expectSameInfo(first, second);

    caps.refresh();
    try std.testing.expectEqual(@as(usize, 0), caps.cachedCount());

    const third = try caps.forExtension(allocator, ".otto_probe");
    try expectSameInfo(first, third);
    // refresh 之后又碰了注册表，不是缓存命中。
    try std.testing.expect(caps.lastDiagnostic() != .cache_hit);
}

test "缓存容量：64 条满后不再吸收新条目" {
    caps.refresh();

    var name_buffer: [32]u8 = undefined;
    var index: usize = 0;
    while (index < caps.cache_capacity) : (index += 1) {
        const ext = try std.fmt.bufPrint(&name_buffer, ".otto_probe_{d}", .{index});
        _ = try caps.forExtension(allocator, ext);
    }
    try std.testing.expectEqual(caps.cache_capacity, caps.cachedCount());

    _ = try caps.forExtension(allocator, ".otto_probe_overflow");
    try std.testing.expectEqual(caps.cache_capacity, caps.cachedCount());

    // 第 65 条没被缓存：再查一次仍然要走注册表。
    _ = try caps.forExtension(allocator, ".otto_probe_overflow");
    try std.testing.expect(caps.lastDiagnostic() != .cache_hit);
}

// ---------------------------------------------------------------------------
// 6. CLSID 纯解析
// ---------------------------------------------------------------------------

test "CLSID 校验：长度 38、花括号、十六进制、连字符位置" {
    const good = "{e357fccd-a995-4576-b01f-234630154e96}";

    try std.testing.expectEqual(caps.clsid_len, good.len);
    const parsed = caps.parseClsid(good) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u8, good, parsed[0..]);

    // 大小写不敏感，原样保留。
    const upper = "{E357FCCD-A995-4576-B01F-234630154E96}";
    try std.testing.expect(caps.parseClsid(upper) != null);

    // 长度不对：37 / 39。
    try std.testing.expect(caps.parseClsid(good[0..37]) == null);
    try std.testing.expect(caps.parseClsid(good ++ "0") == null);

    // 缺花括号 / 花括号位置不对。
    try std.testing.expect(caps.parseClsid("e357fccd-a995-4576-b01f-234630154e96") == null);
    try std.testing.expect(caps.parseClsid("{e357fccd-a995-4576-b01f-234630154e96") == null);
    try std.testing.expect(caps.parseClsid("e357fccd-a995-4576-b01f-234630154e96}") == null);

    // 非十六进制 / 连字符位置不对。
    try std.testing.expect(caps.parseClsid("{g357fccd-a995-4576-b01f-234630154e96}") == null);
    try std.testing.expect(caps.parseClsid("{e357fccd_a995-4576-b01f-234630154e96}") == null);
    try std.testing.expect(caps.parseClsid("{e357fccd-a995-4576-b01f-234630154e-6}") == null);

    // 空 / 全零长度。
    try std.testing.expect(caps.parseClsid("") == null);
}

// ---------------------------------------------------------------------------
// forPath：取扩展名
// ---------------------------------------------------------------------------

test "forPath：只看最后一段，目录里的点不算扩展名" {
    caps.refresh();
    const from_path = try caps.forPath(allocator, "C:\\media.dir\\clip.PSD");
    const from_ext = try caps.forExtension(allocator, ".psd");
    try expectSameInfo(from_path, from_ext);

    caps.refresh();
    const mixed_separators = try caps.forPath(allocator, "C:/media.dir/clip.PSD");
    try expectSameInfo(from_path, mixed_separators);

    try std.testing.expectError(error.InvalidExtension, caps.forPath(allocator, "C:\\media.dir\\clip"));
    try std.testing.expectError(error.InvalidExtension, caps.forPath(allocator, "C:\\media.dir\\"));
    try std.testing.expectError(error.InvalidExtension, caps.forPath(allocator, ""));
}
