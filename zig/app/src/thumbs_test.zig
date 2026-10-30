//! `thumbs.zig` 的纯函数测试：缓存键与载荷头。
//!
//! 线程、队列与真实 Shell 取图不在这里——它们由 `--demo-thumbs` 用真 BMP / WAV
//! 覆盖（见 `demo_thumbs.zig`），单元测试保持无 IO、无注册表、无第三方 handler。

const std = @import("std");
const core = @import("otto_core");
const thumbs = @import("thumbs.zig");
const testing = std.testing;

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
    const key = thumbs.keyFor(sample, 32, &buffer);
    try testing.expect(std.mem.startsWith(u8, key, "id|"));
    // 身份键里没有路径：改名不换键（缩略图跟着身份走）。
    try testing.expect(std.mem.indexOf(u8, key, "a.bmp") == null);

    var other_buffer: [thumbs.max_key_bytes]u8 = undefined;
    const later = sampleWith(identity, 222, "C:\\lib\\a.bmp");
    try testing.expect(!std.mem.eql(u8, key, thumbs.keyFor(later, 32, &other_buffer)));

    const bigger = sampleWith(identity, 111, "C:\\lib\\a.bmp");
    try testing.expect(!std.mem.eql(u8, key, thumbs.keyFor(bigger, 64, &other_buffer)));

    const same = thumbs.keyFor(sampleWith(identity, 111, "C:\\other\\renamed.bmp"), 32, &other_buffer);
    try testing.expectEqualStrings(key, same);
}

test "缓存键：没有身份时路径 + 大小 + mtime 进键" {
    var buffer: [thumbs.max_key_bytes]u8 = undefined;
    const first = sampleWith(null, 0, "C:\\lib\\a.bmp");
    const key = thumbs.keyFor(first, 32, &buffer);
    try testing.expect(std.mem.startsWith(u8, key, "fb|"));
    try testing.expect(std.mem.indexOf(u8, key, "C:\\lib\\a.bmp") != null);

    var other: [thumbs.max_key_bytes]u8 = undefined;
    try testing.expect(!std.mem.eql(u8, key, thumbs.keyFor(sampleWith(null, 1, "C:\\lib\\a.bmp"), 32, &other)));
    try testing.expect(!std.mem.eql(u8, key, thumbs.keyFor(sampleWith(null, 0, "C:\\lib\\b.bmp"), 32, &other)));
}

test "缓存键：超长路径退化成定长哈希键" {
    var buffer: [thumbs.max_key_bytes]u8 = undefined;
    var long_path: [thumbs.max_key_bytes + 40]u8 = undefined;
    @memset(&long_path, 'x');
    const sample = sampleWith(null, 7, &long_path);

    const key = thumbs.keyFor(sample, 32, &buffer);
    try testing.expect(std.mem.startsWith(u8, key, "hash|"));
    try testing.expect(key.len < 48);
}

test "载荷头：尺寸 / 跨度往返，长度不够就是 null" {
    var payload: [thumbs.header_bytes + 4 * 4]u8 = undefined;
    thumbs.encodeHeader(&payload, 2, 2, 8);
    const dims = thumbs.decodeHeader(&payload).?;
    try testing.expectEqual(@as(u32, 2), dims.width);
    try testing.expectEqual(@as(u32, 2), dims.height);
    try testing.expectEqual(@as(usize, 8), dims.stride);

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
    const first = thumbs.diskKeyFor("id|00000001|0000000000000002|111|64");
    const second = thumbs.diskKeyFor("id|00000001|0000000000000002|111|64");
    try testing.expectEqualSlices(u8, &first, &second);
    try testing.expectEqual(@as(usize, 32), first.len);

    // mtime 变一位就必须换键：旧像素不能拿来当新内容的命中。
    const other = thumbs.diskKeyFor("id|00000001|0000000000000002|112|64");
    try testing.expect(!std.mem.eql(u8, &first, &other));

    // 由 keyFor 产出的键串同样稳定（同一路径 + mtime + 尺寸调两次）。
    var buffer: [thumbs.max_key_bytes]u8 = undefined;
    const sample = sampleWith(null, 5, "C:\\lib\\a.bmp");
    const key = thumbs.keyFor(sample, 64, &buffer);
    const a = thumbs.diskKeyFor(key);
    const b = thumbs.diskKeyFor(key);
    try testing.expectEqualSlices(u8, &a, &b);
}
