//! `thumbs.zig` 的纯函数测试：缓存键与载荷头。
//!
//! 线程、队列与真实 Shell 取图不在这里——它们由 `--demo-thumbs` 用真 BMP / WAV
//! 覆盖（见 `demo_thumbs.zig`），单元测试保持无 IO、无注册表、无第三方 handler。

const std = @import("std");
const core = @import("otto_core");
const thumbs = @import("thumbs.zig");
const testing = std.testing;

/// 测试里固定的 provider 版本。生产值来自 `providers.providerVersion()`。
const pv: u32 = 4242;

fn sampleWith(identity: ?core.model.FileIdentity, mtime: i64, path: []const u8) core.model.Sample {
    return .{
        .id = "s",
        .file_name = "s",
        .file_ext = ".bmp",
        .file_path = path,
        .mtime = mtime,
        .identity = identity,
    };
}

test "缓存键：身份优先，mtime 与请求尺寸都参与" {
    const identity = core.model.FileIdentity{ .volume_serial = 0x1a2b, .file_index = 0x9c4e };
    var buffer: [thumbs.max_key_bytes]u8 = undefined;

    const sample = sampleWith(identity, 111, "C:\\lib\\a.bmp");
    const key = thumbs.keyFor(sample, 32, pv, &buffer);
    try testing.expect(std.mem.startsWith(u8, key, "id|"));
    // 身份键里没有路径：改名不换键（缩略图跟着身份走）。
    try testing.expect(std.mem.indexOf(u8, key, "a.bmp") == null);

    var other_buffer: [thumbs.max_key_bytes]u8 = undefined;
    const later = sampleWith(identity, 222, "C:\\lib\\a.bmp");
    try testing.expect(!std.mem.eql(u8, key, thumbs.keyFor(later, 32, pv, &other_buffer)));

    const bigger = sampleWith(identity, 111, "C:\\lib\\a.bmp");
    try testing.expect(!std.mem.eql(u8, key, thumbs.keyFor(bigger, 64, pv, &other_buffer)));

    const same = thumbs.keyFor(sampleWith(identity, 111, "C:\\other\\renamed.bmp"), 32, pv, &other_buffer);
    try testing.expectEqualStrings(key, same);
}

test "缓存键：没有身份时路径 + 大小 + mtime 进键" {
    var buffer: [thumbs.max_key_bytes]u8 = undefined;
    const first = sampleWith(null, 0, "C:\\lib\\a.bmp");
    const key = thumbs.keyFor(first, 32, pv, &buffer);
    try testing.expect(std.mem.startsWith(u8, key, "fb|"));
    try testing.expect(std.mem.indexOf(u8, key, "C:\\lib\\a.bmp") != null);

    var other: [thumbs.max_key_bytes]u8 = undefined;
    try testing.expect(!std.mem.eql(u8, key, thumbs.keyFor(sampleWith(null, 1, "C:\\lib\\a.bmp"), 32, pv, &other)));
    try testing.expect(!std.mem.eql(u8, key, thumbs.keyFor(sampleWith(null, 0, "C:\\lib\\b.bmp"), 32, pv, &other)));
}

test "缓存键：超长路径退化成定长哈希键" {
    var buffer: [thumbs.max_key_bytes]u8 = undefined;
    var long_path: [thumbs.max_key_bytes + 40]u8 = undefined;
    @memset(&long_path, 'x');
    const sample = sampleWith(null, 7, &long_path);

    const key = thumbs.keyFor(sample, 32, pv, &buffer);
    try testing.expect(std.mem.startsWith(u8, key, "hash|"));
    try testing.expect(key.len < 48);
}

test "缓存键：像素格式 + 键格式版本 + provider 版本都在键里（缺一维就串用旧像素）" {
    var buffer: [thumbs.max_key_bytes]u8 = undefined;
    const sample = sampleWith(core.model.FileIdentity{ .volume_serial = 1, .file_index = 2 }, 3, "C:\\lib\\a.psd");
    const key = thumbs.keyFor(sample, 64, pv, &buffer);

    try testing.expect(std.mem.indexOf(u8, key, "|bgra") != null);
    try testing.expect(std.mem.indexOf(u8, key, "|k2|") != null);
    var version_buffer: [32]u8 = undefined;
    const expected_version = try std.fmt.bufPrint(&version_buffer, "|pv{d}|", .{pv});
    try testing.expect(std.mem.indexOf(u8, key, expected_version) != null);
}

test "缓存键：provider 版本 +1 后旧键不再命中（故意弄坏会红）" {
    // 这条测试钉的是"helper/provider 行为变化后旧结果作废"：键必须随版本变。
    var old_buffer: [thumbs.max_key_bytes]u8 = undefined;
    var new_buffer: [thumbs.max_key_bytes]u8 = undefined;
    const sample = sampleWith(core.model.FileIdentity{ .volume_serial = 0xaa, .file_index = 0xbb }, 99, "C:\\lib\\a.psd");

    const old_key = thumbs.keyFor(sample, 64, pv, &old_buffer);
    const new_key = thumbs.keyFor(sample, 64, pv + 1, &new_buffer);
    try testing.expect(!std.mem.eql(u8, old_key, new_key));

    // 用真缓存验证"不命中"，而不只是字符串不等：旧条目留在 L2 里，新键查不到它。
    var cache = core.cache.Cache.init(testing.allocator, 1024 * 1024);
    defer cache.deinit();
    // put 会复制键，所以 old_buffer 可以复用。
    try cache.put(old_key, .thumbnail, "old-pixels");
    try testing.expect(cache.contains(old_key));
    try testing.expect(!cache.contains(new_key));
    try testing.expect(cache.get(new_key) == null);
}

test "载荷头：尺寸 / 跨度往返，长度不够就是 null" {
    var payload: [thumbs.header_bytes + 4 * 4]u8 = undefined;
    thumbs.encodeHeader(&payload, 2, 2, 8);
    const dims = thumbs.decodeHeader(&payload).?;
    try testing.expectEqual(@as(u32, 2), dims.width);
    try testing.expectEqual(@as(u32, 2), dims.height);
    try testing.expectEqual(@as(usize, 8), dims.stride);
    try testing.expectEqual(@as(u32, 0), dims.source_px); // provider 直接取图

    // 派生条目：来源边长写进头里（derived_from=256）。
    thumbs.encodeHeaderFrom(&payload, 2, 2, 8, 256);
    try testing.expectEqual(@as(u32, 256), thumbs.decodeHeader(&payload).?.source_px);

    // 跨度小于一行 / 载荷被截断 / 尺寸为 0：都不算可用条目。
    thumbs.encodeHeader(&payload, 2, 2, 4);
    try testing.expect(thumbs.decodeHeader(&payload) == null);
    thumbs.encodeHeader(&payload, 2, 2, 8);
    try testing.expect(thumbs.decodeHeader(payload[0 .. thumbs.header_bytes + 8]) == null);
    thumbs.encodeHeader(&payload, 0, 2, 8);
    try testing.expect(thumbs.decodeHeader(&payload) == null);
    try testing.expect(thumbs.decodeHeader(payload[0..4]) == null);
}

test "L3 摘要：同一 L2 键串稳定、不同键串不同、正好 32 字节" {
    const first = thumbs.diskKeyFor("id|00000001|0000000000000002|111|64|k2|pv4242|bgra");
    const second = thumbs.diskKeyFor("id|00000001|0000000000000002|111|64|k2|pv4242|bgra");
    try testing.expectEqualSlices(u8, &first, &second);
    try testing.expectEqual(@as(usize, 32), first.len);

    // mtime 变一位就必须换键：旧像素不能拿来当新内容的命中。
    const other = thumbs.diskKeyFor("id|00000001|0000000000000002|112|64|k2|pv4242|bgra");
    try testing.expect(!std.mem.eql(u8, &first, &other));

    // provider 版本变一位也必须换 L3 键（旧盘上条目成为孤儿，由预算裁剪回收）。
    const bumped = thumbs.diskKeyFor("id|00000001|0000000000000002|111|64|k2|pv4243|bgra");
    try testing.expect(!std.mem.eql(u8, &first, &bumped));

    // 由 keyFor 产出的键串同样稳定（同一路径 + mtime + 尺寸调两次）。
    var buffer: [thumbs.max_key_bytes]u8 = undefined;
    const sample = sampleWith(null, 5, "C:\\lib\\a.bmp");
    const key = thumbs.keyFor(sample, 64, pv, &buffer);
    const a = thumbs.diskKeyFor(key);
    const b = thumbs.diskKeyFor(key);
    try testing.expectEqualSlices(u8, &a, &b);
}
