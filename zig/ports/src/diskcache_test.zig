//! L3 磁盘缓存的行为测试：真临时目录、真文件、真 `MoveFileExW`，没有 mock。
//!
//! 覆盖任务要求的六条：
//!   1. round-trip：put 后 get 拿回相同像素 / 尺寸；
//!   2. miss：未知键返回 null，不建文件；
//!   3. 损坏条目（截断 / CRC / magic / 版本）返回 miss、文件被删、之后还能重写；
//!   4. 预算裁剪：超预算按 mtime 从旧到新删，保留最新；
//!   5. 两级目录：`<root>/<key[0]>/<hex>.bin` 在嵌套根下也一次建齐；
//!   6. 字节数统计：`stats.bytes` 等于条目文件大小之和，损坏 / 淘汰后跟着减。
//!
//! 每个用例自己的 tmpDir；不弹窗、不抢焦点、不碰注册表与 Shell。

const std = @import("std");
const diskcache = @import("diskcache.zig");

const allocator = std.testing.allocator;
const io = std.testing.io;

const Fixture = struct {
    tmp: std.testing.TmpDir,
    root_buf: [4096]u8 = undefined,
    root_len: usize = 0,

    fn init() !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buffer: [4096]u8 = undefined;
        const length = try tmp.dir.realPath(io, &buffer);
        return .{ .tmp = tmp, .root_buf = buffer, .root_len = length };
    }

    fn deinit(self: *Fixture) void {
        self.tmp.cleanup();
    }

    fn root(self: *const Fixture) []const u8 {
        return self.root_buf[0..self.root_len];
    }
};

/// 一个稳定、可比较的键：首字节随 `seed` 变（分片目录也跟着变）。
fn keyOf(seed: u8) diskcache.Key {
    var key: diskcache.Key = undefined;
    for (&key, 0..) |*byte, index| {
        byte.* = seed +% @as(u8, @intCast(index));
    }
    return key;
}

fn pixelsOf(size: usize, seed: u8) []u8 {
    const bytes = allocator.alloc(u8, size) catch @panic("OOM");
    for (bytes, 0..) |*byte, index| byte.* = seed +% @as(u8, @truncate(index));
    return bytes;
}

fn entryFileBytes(pixel_bytes: usize) u64 {
    return @intCast(diskcache.header_bytes + pixel_bytes + diskcache.crc_bytes);
}

fn exists(path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

fn writeBytes(path: []const u8, bytes: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

fn readAll(path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4096));
}

fn freeEntry(entry: ?diskcache.Entry) void {
    if (entry) |value| allocator.free(value.bytes);
}

test "round-trip：像素 / 尺寸原样回来，stats.bytes 是文件字节数" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var cache = try diskcache.DiskCache.open(allocator, io, fixture.root(), 1024 * 1024);
    defer cache.deinit();

    const key = keyOf(0x10);
    const pixels = pixelsOf(4 * 3 * 4, 0x40);
    defer allocator.free(pixels);

    try cache.put(key, 4, 3, 16, pixels);

    const entry = (try cache.get(allocator, key)).?;
    defer freeEntry(entry);
    try std.testing.expectEqual(@as(u32, 4), entry.width);
    try std.testing.expectEqual(@as(u32, 3), entry.height);
    try std.testing.expectEqual(@as(u32, 16), entry.stride);
    try std.testing.expectEqualSlices(u8, pixels, entry.bytes);

    var stats = cache.stats();
    try std.testing.expectEqual(@as(u64, 1), stats.writes);
    try std.testing.expectEqual(@as(u64, 1), stats.hits);
    try std.testing.expectEqual(@as(u64, 0), stats.misses);
    try std.testing.expectEqual(@as(u64, 1), stats.entries);
    try std.testing.expectEqual(entryFileBytes(pixels.len), stats.bytes);

    // 磁盘上的文件大小与记账一致；再读一次只加 hits，不改字节数。
    const path = try cache.pathForKey(allocator, key);
    defer allocator.free(path);
    const file_stat = try std.Io.Dir.cwd().statFile(io, path, .{});
    try std.testing.expectEqual(stats.bytes, file_stat.size);

    const again = (try cache.get(allocator, key)).?;
    freeEntry(again);
    stats = cache.stats();
    try std.testing.expectEqual(@as(u64, 2), stats.hits);
    try std.testing.expectEqual(@as(u64, 1), stats.entries);
    try std.testing.expectEqual(entryFileBytes(pixels.len), stats.bytes);
}

test "miss：未知键返回 null、计一次 miss、不创建文件" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var cache = try diskcache.DiskCache.open(allocator, io, fixture.root(), 1024 * 1024);
    defer cache.deinit();

    const key = keyOf(0x77);
    try std.testing.expect((try cache.get(allocator, key)) == null);

    const path = try cache.pathForKey(allocator, key);
    defer allocator.free(path);
    try std.testing.expect(!exists(path));

    const stats = cache.stats();
    try std.testing.expectEqual(@as(u64, 1), stats.misses);
    try std.testing.expectEqual(@as(u64, 0), stats.hits);
    try std.testing.expectEqual(@as(u64, 0), stats.entries);
    try std.testing.expectEqual(@as(u64, 0), stats.bytes);
}

test "损坏条目：截断 / CRC / magic / 版本都当 miss 并删除，之后还能重写" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var cache = try diskcache.DiskCache.open(allocator, io, fixture.root(), 1024 * 1024);
    defer cache.deinit();

    const pixels = pixelsOf(8 * 8 * 4, 0x11);
    defer allocator.free(pixels);
    const keys = [_]diskcache.Key{ keyOf(0x20), keyOf(0x30), keyOf(0x40), keyOf(0x50) };

    for (keys) |key| try cache.put(key, 8, 8, 32, pixels);

    // 1) 截断：头部还在、payload 少了，长度对不上。
    const path_a = try cache.pathForKey(allocator, keys[0]);
    defer allocator.free(path_a);
    const blob_a = try readAll(path_a);
    defer allocator.free(blob_a);
    try writeBytes(path_a, blob_a[0 .. diskcache.header_bytes + 10]);
    try std.testing.expect((try cache.get(allocator, keys[0])) == null);
    try std.testing.expect(!exists(path_a));

    // 2) CRC：文件长度不变，翻一个像素字节。
    const path_b = try cache.pathForKey(allocator, keys[1]);
    defer allocator.free(path_b);
    const blob = try readAll(path_b);
    defer allocator.free(blob);
    blob[diskcache.header_bytes + 3] ^= 0xFF;
    try writeBytes(path_b, blob);
    try std.testing.expect((try cache.get(allocator, keys[1])) == null);
    try std.testing.expect(!exists(path_b));

    // 3) magic 被改。
    const path_c = try cache.pathForKey(allocator, keys[2]);
    defer allocator.free(path_c);
    const magic_blob = try readAll(path_c);
    defer allocator.free(magic_blob);
    magic_blob[0] = 'X';
    try writeBytes(path_c, magic_blob);
    try std.testing.expect((try cache.get(allocator, keys[2])) == null);
    try std.testing.expect(!exists(path_c));

    // 4) 版本不认识（旧/未来格式）：同样删掉，避免每次启动都读一遍坏文件。
    const path_d = try cache.pathForKey(allocator, keys[3]);
    defer allocator.free(path_d);
    const version_blob = try readAll(path_d);
    defer allocator.free(version_blob);
    std.mem.writeInt(u16, version_blob[6..8], diskcache.format_version + 1, .little);
    try writeBytes(path_d, version_blob);
    try std.testing.expect((try cache.get(allocator, keys[3])) == null);
    try std.testing.expect(!exists(path_d));

    var stats = cache.stats();
    try std.testing.expectEqual(@as(u64, 4), stats.corrupt);
    try std.testing.expectEqual(@as(u64, 0), stats.entries);
    try std.testing.expectEqual(@as(u64, 0), stats.bytes);

    // 缓存坏掉不妨碍重新写回：下一轮 helper 成功后 put 仍然工作。
    try cache.put(keys[0], 8, 8, 32, pixels);
    const recovered = (try cache.get(allocator, keys[0])).?;
    defer freeEntry(recovered);
    try std.testing.expectEqualSlices(u8, pixels, recovered.bytes);
    stats = cache.stats();
    try std.testing.expectEqual(@as(u64, 1), stats.entries);
}

test "预算裁剪：超预算删最旧、保留最新；setBudget 后 prune 报告淘汰数" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    const pixel_bytes = 1000;
    const entry_bytes = entryFileBytes(pixel_bytes);
    const budget = entry_bytes * 2;
    var cache = try diskcache.DiskCache.open(allocator, io, fixture.root(), budget);
    defer cache.deinit();

    const pixels = pixelsOf(pixel_bytes, 0x60);
    defer allocator.free(pixels);
    const keys = [_]diskcache.Key{
        keyOf(0x01), keyOf(0x02), keyOf(0x03), keyOf(0x04), keyOf(0x05),
    };

    // 写 5 条，每写完一条都保证在预算内：最终只留最后两条。
    for (keys) |key| {
        try cache.put(key, 100, 10, 100, pixels);
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(2), .awake) catch {};
    }

    const stats = cache.stats();
    try std.testing.expectEqual(@as(u64, 5), stats.writes);
    try std.testing.expectEqual(@as(u64, 3), stats.evicted);
    try std.testing.expectEqual(@as(u64, 2), stats.entries);
    try std.testing.expectEqual(budget, stats.bytes);

    for (keys[0..3]) |key| {
        const path = try cache.pathForKey(allocator, key);
        defer allocator.free(path);
        try std.testing.expect(!exists(path));
    }
    for (keys[3..]) |key| {
        const entry = (try cache.get(allocator, key)).?;
        freeEntry(entry);
        const path = try cache.pathForKey(allocator, key);
        defer allocator.free(path);
        try std.testing.expect(exists(path));
    }

    // 再跑一次 prune：已经在预算内，没有新淘汰。
    const report = try cache.prune();
    try std.testing.expectEqual(@as(u64, 2), report.scanned);
    try std.testing.expectEqual(@as(u64, 2), report.kept);
    try std.testing.expectEqual(@as(u64, 0), report.evicted);
    try std.testing.expectEqual(budget, report.bytes_after);
    try std.testing.expectEqual(budget, report.budget_bytes);

    // 预算缩到只放得下一条：prune 删掉更旧的那条，保留最新。
    cache.setBudget(entry_bytes);
    const shrunk = try cache.prune();
    try std.testing.expectEqual(@as(u64, 1), shrunk.evicted);
    try std.testing.expectEqual(@as(u64, 1), shrunk.kept);
    try std.testing.expect(shrunk.bytes_after <= shrunk.budget_bytes);
    const newest = (try cache.get(allocator, keys[4])).?;
    freeEntry(newest);
}

test "两级目录：嵌套根一次建齐，条目落在 <root>/<key[0]>/<hex>.bin" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    const root = try std.fs.path.join(allocator, &.{ fixture.root(), "deep", "cache", "thumbs" });
    defer allocator.free(root);
    var cache = try diskcache.DiskCache.open(allocator, io, root, 1024 * 1024);
    defer cache.deinit();

    // open 只建根；分片目录由第一次 put 建。
    const root_stat = try std.Io.Dir.cwd().statFile(io, root, .{});
    try std.testing.expectEqual(std.Io.File.Kind.directory, root_stat.kind);

    const key = keyOf(0xAB);
    const pixels = pixelsOf(2 * 2 * 4, 0x01);
    defer allocator.free(pixels);
    try cache.put(key, 2, 2, 8, pixels);

    const path = try cache.pathForKey(allocator, key);
    defer allocator.free(path);
    try std.testing.expect(exists(path));

    const hex = std.fmt.bytesToHex(key, .lower);
    const shard = std.fs.path.basename(std.fs.path.dirname(path).?);
    try std.testing.expectEqualStrings(hex[0..2], shard);
    const shard_stat = try std.Io.Dir.cwd().statFile(
        io,
        std.fs.path.dirname(path).?,
        .{},
    );
    try std.testing.expectEqual(std.Io.File.Kind.directory, shard_stat.kind);

    const name = std.fs.path.basename(path);
    try std.testing.expectEqual(@as(usize, diskcache.entry_name_len), name.len);
    try std.testing.expect(std.mem.endsWith(u8, name, ".bin"));
    try std.testing.expectEqualStrings(hex[0..64], name[0..64]);
}

test "prune 顺手清掉崩溃留下的 .tmp 残骸" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var cache = try diskcache.DiskCache.open(allocator, io, fixture.root(), 1024 * 1024);
    defer cache.deinit();

    const key = keyOf(0x99);
    const pixels = pixelsOf(4 * 2 * 4, 0x02);
    defer allocator.free(pixels);
    try cache.put(key, 4, 2, 16, pixels);

    const path = try cache.pathForKey(allocator, key);
    defer allocator.free(path);
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp_path);
    try writeBytes(tmp_path, "half-written");
    try std.testing.expect(exists(tmp_path));

    const report = try cache.prune();
    try std.testing.expectEqual(@as(u64, 1), report.scanned);
    try std.testing.expectEqual(@as(u64, 0), report.evicted);
    try std.testing.expect(!exists(tmp_path));
    try std.testing.expect(exists(path));
}
