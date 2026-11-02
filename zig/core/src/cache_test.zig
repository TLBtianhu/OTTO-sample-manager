//! cache.zig（L2 字节预算缓存）的单元测试。
//!
//! 断言全部基于可观察行为：淘汰顺序用 `contains` / 统计数字验证，不依赖内部链表。
//! 全部使用 `std.testing.allocator`，所以任何 key / 载荷泄漏都会让测试失败。

const std = @import("std");
const cache = @import("cache.zig");

const testing = std.testing;

/// 用固定长度的合成载荷写入，避免每个测试都手写字节。
fn putSized(c: *cache.Cache, key: []const u8, kind: cache.Kind, len: usize) !void {
    var buffer: [1024]u8 = undefined;
    std.debug.assert(len <= buffer.len);
    @memset(buffer[0..len], 0xAB);
    try c.put(key, kind, buffer[0..len]);
}

fn keyFor(buffer: []u8, prefix: []const u8, index: usize) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{s}-{d}", .{ prefix, index });
}

test "预算内不淘汰，超预算淘汰最久未使用的" {
    var c = cache.Cache.init(testing.allocator, 100);
    defer c.deinit();

    try putSized(&c, "a", .pcm, 30);
    try putSized(&c, "b", .pcm, 30);
    try putSized(&c, "c", .pcm, 30);
    try testing.expectEqual(@as(usize, 3), c.stats().entries);
    try testing.expectEqual(@as(usize, 90), c.stats().bytes);
    try testing.expectEqual(@as(u64, 0), c.stats().evictions);

    try putSized(&c, "d", .pcm, 30); // 120 > 100，淘汰最旧的 a
    try testing.expectEqual(@as(usize, 3), c.stats().entries);
    try testing.expectEqual(@as(usize, 90), c.stats().bytes);
    try testing.expectEqual(@as(u64, 1), c.stats().evictions);
    try testing.expect(!c.contains("a"));
    try testing.expect(c.contains("b"));
    try testing.expect(c.contains("c"));
    try testing.expect(c.contains("d"));
}

test "get 命中刷新 LRU 使用序" {
    var c = cache.Cache.init(testing.allocator, 90);
    defer c.deinit();

    try putSized(&c, "a", .pcm, 30);
    try putSized(&c, "b", .pcm, 30);
    try putSized(&c, "c", .pcm, 30);

    _ = c.get("a"); // a 从最旧变成最新，b 成为最旧
    try putSized(&c, "d", .pcm, 30);
    try testing.expect(!c.contains("b"));
    try testing.expect(c.contains("a"));
    try testing.expect(c.contains("c"));
    try testing.expect(c.contains("d"));

    _ = c.get("c"); // c 最新，a 变成最旧
    try putSized(&c, "e", .pcm, 30);
    try testing.expect(!c.contains("a"));
    try testing.expect(c.contains("c"));
    try testing.expect(c.contains("d"));
    try testing.expect(c.contains("e"));
}

test "pin 住的条目在洪水下不被淘汰" {
    var c = cache.Cache.init(testing.allocator, 100);
    defer c.deinit();

    const preview_payload: [40]u8 = @splat('P');
    try c.put("preview", .pcm, &preview_payload);
    try testing.expect(c.pin("preview"));
    try testing.expect(c.isPinned("preview"));
    try testing.expect(!c.pin("missing"));

    // 先确认载荷可读；`get` 会把预览项提到最新端，但洪水足够长，它仍会回到最旧端。
    const seeded = c.get("preview") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 40), seeded.len);
    try testing.expectEqual(@as(u8, 'P'), seeded[0]);

    var index: usize = 0;
    while (index < 20) : (index += 1) {
        var key_buffer: [32]u8 = undefined;
        try putSized(&c, try keyFor(&key_buffer, "thumb", index), .thumbnail, 20);
    }

    try testing.expect(c.contains("preview"));
    try testing.expect(c.isPinned("preview"));
    try testing.expect(c.stats().bytes <= 100);
    try testing.expect(c.stats().evictions > 0);

    // 解除保护后预览项变成最旧，下一次溢出就被淘汰。
    try testing.expect(c.unpin("preview"));
    try testing.expect(!c.isPinned("preview"));
    try putSized(&c, "thumb-after", .thumbnail, 20);
    try testing.expect(!c.contains("preview"));
}

test "软配额：缩略图洪水仍保留 PCM 份额" {
    var c = cache.Cache.init(testing.allocator, 1000);
    defer c.deinit();
    c.setKindPercent(.pcm, 40);
    c.setKindPercent(.thumbnail, 50);

    var index: usize = 0;
    while (index < 4) : (index += 1) {
        var key_buffer: [32]u8 = undefined;
        try putSized(&c, try keyFor(&key_buffer, "pcm", index), .pcm, 100);
    }
    try testing.expectEqual(@as(usize, 400), c.stats().bytesFor(.pcm));

    // 缩略图持续涌入：总量溢出时优先淘汰缩略图自己，PCM 的 40% 份额保持完整。
    index = 0;
    while (index < 20) : (index += 1) {
        var key_buffer: [32]u8 = undefined;
        try putSized(&c, try keyFor(&key_buffer, "thumb", index), .thumbnail, 100);
    }

    const stats = c.stats();
    try testing.expectEqual(@as(usize, 400), stats.bytesFor(.pcm));
    try testing.expect(stats.bytesFor(.thumbnail) <= 600);
    try testing.expect(stats.bytes <= 1000);
    try testing.expect(stats.evictions > 0);

    index = 0;
    while (index < 4) : (index += 1) {
        var key_buffer: [32]u8 = undefined;
        try testing.expect(c.contains(try keyFor(&key_buffer, "pcm", index)));
    }
}

test "统计数字与按 kind 占用" {
    var c = cache.Cache.init(testing.allocator, 100);
    defer c.deinit();

    try testing.expect(c.get("missing") == null); // misses = 1
    try putSized(&c, "a", .pcm, 40);
    try putSized(&c, "b", .thumbnail, 60);
    try testing.expect(c.get("a") != null); // hits = 1
    try testing.expect(c.get("missing") == null); // misses = 2

    try putSized(&c, "c", .pcm, 50); // 150 > 100，淘汰最旧的 b
    try testing.expectEqual(@as(u64, 1), c.stats().hits);
    try testing.expectEqual(@as(u64, 2), c.stats().misses);
    try testing.expectEqual(@as(u64, 1), c.stats().evictions);
    try testing.expectEqual(@as(usize, 2), c.stats().entries);
    try testing.expectEqual(@as(usize, 90), c.stats().bytes);
    try testing.expectEqual(@as(usize, 100), c.stats().budget_bytes);
    try testing.expectEqual(@as(usize, 90), c.stats().bytesFor(.pcm));
    try testing.expectEqual(@as(usize, 0), c.stats().bytesFor(.thumbnail));
    try testing.expectEqual(@as(usize, 0), c.stats().bytesFor(.waveform));

    // 扩容不淘汰；成本可以由调用方指定，与载荷长度解耦。
    c.setBudget(1000);
    try c.putWithCost("d", .thumbnail, "12345678", 500);
    const stats = c.stats();
    try testing.expectEqual(@as(usize, 1000), stats.budget_bytes);
    try testing.expectEqual(@as(usize, 590), stats.bytes);
    try testing.expectEqual(@as(usize, 500), stats.bytesFor(.thumbnail));
    try testing.expectEqual(@as(usize, 90), stats.bytesFor(.pcm));
    try testing.expectEqual(@as(usize, 3), stats.entries);
    try testing.expectEqual(@as(u64, 1), stats.evictions);
}

test "remove 与 setBudget 立即淘汰" {
    var c = cache.Cache.init(testing.allocator, 200);
    defer c.deinit();

    try putSized(&c, "a", .pcm, 50);
    try putSized(&c, "b", .waveform, 50);
    try putSized(&c, "c", .thumbnail, 50);
    try testing.expectEqual(@as(usize, 150), c.stats().bytes);
    try testing.expectEqual(@as(u64, 0), c.stats().evictions);

    try testing.expect(c.remove("b"));
    try testing.expect(!c.remove("b"));
    try testing.expectEqual(@as(usize, 2), c.stats().entries);
    try testing.expectEqual(@as(usize, 100), c.stats().bytes);
    try testing.expectEqual(@as(usize, 0), c.stats().bytesFor(.waveform));
    try testing.expect(!c.contains("b"));

    c.setBudget(60); // 100 > 60，淘汰最旧的 a
    try testing.expectEqual(@as(usize, 60), c.stats().budget_bytes);
    try testing.expectEqual(@as(usize, 50), c.stats().bytes);
    try testing.expectEqual(@as(usize, 1), c.stats().entries);
    try testing.expectEqual(@as(u64, 1), c.stats().evictions);
    try testing.expect(!c.contains("a"));
    try testing.expect(c.contains("c"));

    c.setBudget(1000); // 扩容不淘汰
    try testing.expectEqual(@as(usize, 1), c.stats().entries);
    try testing.expectEqual(@as(usize, 50), c.stats().bytes);

    c.clear();
    try testing.expectEqual(@as(usize, 0), c.stats().entries);
    try testing.expectEqual(@as(usize, 0), c.stats().bytes);
    try testing.expectEqual(@as(usize, 0), c.stats().bytesFor(.thumbnail));
    try testing.expect(!c.contains("c"));
}

test "空 key、0 字节载荷与重复 put 的替换语义" {
    var c = cache.Cache.init(testing.allocator, 100);
    defer c.deinit();

    try testing.expectError(error.EmptyKey, c.put("", .pcm, "abc"));
    try testing.expectEqual(@as(usize, 0), c.stats().entries);
    try testing.expectEqual(@as(usize, 0), c.stats().bytes);

    // 0 字节载荷是合法条目，命中时返回空切片而不是未命中。
    try c.put("zero", .thumbnail, "");
    try testing.expect(c.contains("zero"));
    try testing.expectEqual(@as(usize, 1), c.stats().entries);
    try testing.expectEqual(@as(usize, 0), c.stats().bytes);
    const zero_payload = c.get("zero") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 0), zero_payload.len);
    try testing.expectEqual(@as(u64, 1), c.stats().hits);

    // 重复 put 是替换：条目数不变、旧载荷释放、成本按新值重算。
    try c.put("same", .pcm, "12345");
    try c.put("same", .pcm, "0123456789");
    try testing.expectEqual(@as(usize, 2), c.stats().entries);
    try testing.expectEqual(@as(usize, 10), c.stats().bytes);
    try testing.expectEqualStrings("0123456789", c.get("same") orelse return error.TestUnexpectedResult);

    // 替换保留嵌套 pin 状态，并更新 kind 占用。
    try testing.expect(c.pin("same"));
    try testing.expect(c.pin("same"));
    try c.put("same", .waveform, "xyz");
    try testing.expect(c.isPinned("same"));
    try testing.expectEqual(@as(usize, 3), c.stats().bytes);
    try testing.expectEqual(@as(usize, 0), c.stats().bytesFor(.pcm));
    try testing.expectEqual(@as(usize, 3), c.stats().bytesFor(.waveform));
    try testing.expectEqualStrings("xyz", c.get("same") orelse return error.TestUnexpectedResult);

    try testing.expect(c.unpin("same"));
    try testing.expect(c.isPinned("same"));
    try testing.expect(c.unpin("same"));
    try testing.expect(!c.isPinned("same"));
    try testing.expect(c.unpin("same")); // 未 pin 时幂等
    try testing.expect(!c.pin("missing"));
    try testing.expect(!c.unpin("missing"));
}

test "全部条目都被 pin 时允许暂时超预算" {
    var c = cache.Cache.init(testing.allocator, 60);
    defer c.deinit();

    try putSized(&c, "a", .pcm, 50);
    try putSized(&c, "b", .waveform, 10);
    try testing.expect(c.pin("a"));
    try testing.expect(c.pin("b"));

    // 替换成更大的载荷：110 > 60，但两条都 pin 着，淘汰器无从下手。
    try putSized(&c, "a", .pcm, 100);
    try testing.expectEqual(@as(usize, 110), c.stats().bytes);
    try testing.expectEqual(@as(usize, 2), c.stats().entries);
    try testing.expectEqual(@as(u64, 0), c.stats().evictions);

    // 解除 a 的保护并重新设预算，淘汰重新开始。
    try testing.expect(c.unpin("a"));
    c.setBudget(60);
    try testing.expect(!c.contains("a"));
    try testing.expect(c.contains("b"));
    try testing.expectEqual(@as(u64, 1), c.stats().evictions);
}

test "单条成本超过预算时等价于不缓存" {
    var c = cache.Cache.init(testing.allocator, 50);
    defer c.deinit();

    try putSized(&c, "huge", .thumbnail, 100);
    try testing.expect(!c.contains("huge"));
    try testing.expectEqual(@as(usize, 0), c.stats().entries);
    try testing.expectEqual(@as(usize, 0), c.stats().bytes);
    try testing.expectEqual(@as(u64, 1), c.stats().evictions);
}

test "软配额是软的：总量没超预算时谁也不淘汰" {
    var c = cache.Cache.init(testing.allocator, 1000);
    defer c.deinit();
    c.setKindPercent(.pcm, 10); // 份额只有 100 字节

    try putSized(&c, "big", .pcm, 500);
    try testing.expect(c.contains("big"));
    try testing.expectEqual(@as(usize, 500), c.stats().bytesFor(.pcm));
    try testing.expectEqual(@as(u64, 0), c.stats().evictions);
}
