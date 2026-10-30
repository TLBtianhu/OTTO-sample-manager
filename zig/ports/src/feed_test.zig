//! 取 feed 口岸的测试：真文件系统 + 真 WinHTTP，没有 mock。
//!
//! 覆盖：
//!   1. 普通本地路径与 `file://` 两种写法读到同一份字节；
//!   2. 上限是硬的：等于上限可以，多一个字节就 `TooLarge`；
//!   3. 缺失 / 空串 / 未知 scheme / 坏端口各自具名，且**不发请求**（坏 URL 不会
//!      先连一次再报错）；
//!   4. 真发一次请求到回环地址上一个没人监听的端口：`NetFailure`，数字码落在
//!      `lastFailure()`（只碰本机回环，不依赖外网）。
//!
//! 每个用例自己的 tmpDir；不弹窗、不抢焦点。

const std = @import("std");
const feed = @import("feed.zig");

const allocator = std.testing.allocator;
const io = std.testing.io;

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

    fn rootPath(self: *const Fixture) []const u8 {
        return self.root[0..self.root_len];
    }

    /// 写一个文件，返回它的绝对路径（新分配，调用方释放）。
    fn write(self: *Fixture, name: []const u8, bytes: []const u8) ![]u8 {
        try self.tmp.dir.writeFile(io, .{ .sub_path = name, .data = bytes });
        var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const length = try self.tmp.dir.realPathFile(io, name, &buffer);
        return try allocator.dupe(u8, buffer[0..length]);
    }
};

/// `C:\a\b.json` → `file:///C:/a/b.json`。
fn fileUrl(path: []const u8) ![]u8 {
    const url = try allocator.alloc(u8, path.len + "file:///".len);
    @memcpy(url[0.."file:///".len], "file:///");
    for (path, 0..) |ch, index| {
        url["file:///".len + index] = if (ch == '\\') '/' else ch;
    }
    return url;
}

test "本地路径：读到原样字节" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    const body = "{\"version\":\"0.2.0\",\"notes\":\"测试用 feed\"}";
    const path = try fixture.write("feed.json", body);
    defer allocator.free(path);

    const bytes = try feed.fetch(allocator, io, path, feed.default_max_bytes);
    defer allocator.free(bytes);
    try std.testing.expectEqualStrings(body, bytes);
}

test "file:// 与普通路径等价：C:\\… → file:///C:/…" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    const body = "{}";
    const path = try fixture.write("latest.json", body);
    defer allocator.free(path);

    const url = try fileUrl(path);
    defer allocator.free(url);

    const bytes = try feed.fetch(allocator, io, url, feed.default_max_bytes);
    defer allocator.free(bytes);
    try std.testing.expectEqualStrings(body, bytes);
}

test "上限是硬的：等于上限可以，多一个字节就 TooLarge" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    const body = "0123456789";
    const path = try fixture.write("small.json", body);
    defer allocator.free(path);

    const exact = try feed.fetch(allocator, io, path, body.len);
    defer allocator.free(exact);
    try std.testing.expectEqualStrings(body, exact);

    try std.testing.expectError(error.TooLarge, feed.fetch(allocator, io, path, body.len - 1));
    // 0 字节上限对任何内容都是超限。
    try std.testing.expectError(error.TooLarge, feed.fetch(allocator, io, path, 0));
}

test "缺失文件是 NotFound，不是泛泛的失败" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    const missing = try std.fs.path.join(allocator, &.{ fixture.rootPath(), "no-such-feed.json" });
    defer allocator.free(missing);
    try std.testing.expectError(error.NotFound, feed.fetch(allocator, io, missing, feed.default_max_bytes));

    // 目录同样不可读——按"这里没有可读的 feed"处理。
    try std.testing.expectError(error.NotFound, feed.fetch(allocator, io, fixture.rootPath(), feed.default_max_bytes));
}

test "坏 URL 全部在发请求之前报 BadUrl" {
    const bad = [_][]const u8{
        "", // 空串
        "ftp://example.com/latest.json", // 不支持的 scheme
        "res://app/latest.json",
        "file://", // scheme 后面什么都没有
        "http://", // 没有 host
        "https:///latest.json", // host 是空的
        "http://:8080/latest.json", // 端口没有 host
        "http://example.com:abc/latest.json", // 端口不是数字
        "http://example.com:99999/latest.json", // 端口超出 u16
        "http://user:pass@example.com/latest.json", // 没有 userinfo 的概念
        "http://[::1/latest.json", // 缺右方括号
    };
    for (bad) |url| {
        try std.testing.expectError(error.BadUrl, feed.fetch(allocator, io, url, feed.default_max_bytes));
    }
}

test "连不上：NetFailure，且数字码留在 lastFailure（只碰本机回环）" {
    // 127.0.0.1:9 是 discard 端口，测试机上不该有服务；连接被拒绝是确定行为。
    // 万一有防火墙把它静默丢掉，WinHTTP 也会在 5 秒后超时，仍然是 NetFailure。
    const result = feed.fetch(allocator, io, "http://127.0.0.1:9/latest.json", feed.default_max_bytes);
    try std.testing.expectError(error.NetFailure, result);
    try std.testing.expect(feed.lastFailure() != 0);
    try std.testing.expectEqual(@as(u32, 0), feed.lastHttpStatus());
}

test "解析：authority / 端口 / 路径 / 片段都不进请求" {
    const plain = feed.parseTarget("example.com/a/b.json?x=1#frag", true).?;
    try std.testing.expectEqualStrings("example.com", plain.host);
    try std.testing.expectEqual(@as(u16, 443), plain.port);
    try std.testing.expectEqualStrings("/a/b.json?x=1", plain.path);

    const explicit = feed.parseTarget("example.com:8080", false).?;
    try std.testing.expectEqualStrings("example.com", explicit.host);
    try std.testing.expectEqual(@as(u16, 8080), explicit.port);
    try std.testing.expectEqualStrings("", explicit.path);

    const query_only = feed.parseTarget("example.com?x=1", false).?;
    try std.testing.expectEqualStrings("?x=1", query_only.path);

    const v6 = feed.parseTarget("[::1]:9000/feed", false).?;
    try std.testing.expectEqualStrings("::1", v6.host);
    try std.testing.expectEqual(@as(u16, 9000), v6.port);

    try std.testing.expect(feed.parseTarget("", false) == null);
    try std.testing.expect(feed.parseTarget(":80/", false) == null);
}
