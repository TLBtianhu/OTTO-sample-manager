//! 失败 / 谢绝记忆的共用实现：一张**有界**的键表。
//!
//! `thumbs.zig` 有两张同样的表：
//!   * `failed_keys`：provider 返回 `failed` / `file_missing`（文件没了、Shell 出错）；
//!   * `declined_keys`：provider 全部谢绝（`no_handler` / `unsupported`）。
//!
//! 两张表的作用都是"同一个文件不要每帧重新取"：失败 / 没有预览也是答案。它们都
//! 有上限（默认 64 条），满了丢最旧的；磁盘事件到来时由 `clearFailures()` 一起清空。
//!
//! 键的所有权：`remember` 接管 `key`（成功放进表或表满淘汰后），调用方不要再释放；
//! `clear` / `deinit` 负责释放表里剩余的键。表本身只是一个
//! `std.ArrayListUnmanaged([]u8)`，线程安全由调用方的锁负责（`thumbs.zig` 的
//! `SpinLock`），这里不重复加锁。

const std = @import("std");

pub const Keys = std.ArrayListUnmanaged([]u8);

pub fn contains(keys: []const []u8, key: []const u8) bool {
    for (keys) |candidate| {
        if (std.mem.eql(u8, candidate, key)) return true;
    }
    return false;
}

/// 记一条；表满时先丢最旧。`key` 的所有权转给表（OOM 时当场释放）。
pub fn remember(allocator: std.mem.Allocator, keys: *Keys, capacity: usize, key: []u8) void {
    if (keys.items.len >= @max(1, capacity)) {
        const oldest = keys.orderedRemove(0);
        allocator.free(oldest);
    }
    keys.append(allocator, key) catch {
        allocator.free(key);
    };
}

/// 清空表（保留容量），释放所有键。
pub fn clear(allocator: std.mem.Allocator, keys: *Keys) void {
    for (keys.items) |key| allocator.free(key);
    keys.clearRetainingCapacity();
}

/// 释放所有键与表本身。之后不可再用。
pub fn deinit(allocator: std.mem.Allocator, keys: *Keys) void {
    for (keys.items) |key| allocator.free(key);
    keys.deinit(allocator);
    keys.* = .empty;
}

// ---------------------------------------------------------------------------
// 测试：容量 / 淘汰顺序 / 命中 / 清空，全部使用 testing.allocator 查泄漏
// ---------------------------------------------------------------------------

const testing = std.testing;

fn own(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return allocator.dupe(u8, text);
}

test "有界键表：命中、满了丢最旧、clear/deinit 释放全部键" {
    var table: Keys = .empty;
    defer deinit(testing.allocator, &table);

    try testing.expect(!contains(table.items, "a"));

    remember(testing.allocator, &table, 2, try own(testing.allocator, "a"));
    remember(testing.allocator, &table, 2, try own(testing.allocator, "b"));
    try testing.expect(contains(table.items, "a"));
    try testing.expect(contains(table.items, "b"));

    // 第三条把最旧的 "a" 挤掉；容量 2 不变。
    remember(testing.allocator, &table, 2, try own(testing.allocator, "c"));
    try testing.expectEqual(@as(usize, 2), table.items.len);
    try testing.expect(!contains(table.items, "a"));
    try testing.expect(contains(table.items, "b"));
    try testing.expect(contains(table.items, "c"));

    clear(testing.allocator, &table);
    try testing.expectEqual(@as(usize, 0), table.items.len);
    try testing.expect(!contains(table.items, "b"));

    // clear 之后还能继续用；deinit 由 defer 覆盖。
    remember(testing.allocator, &table, 2, try own(testing.allocator, "d"));
    try testing.expect(contains(table.items, "d"));
}

test "有界键表：capacity 为 0 时仍保留最后一条（不除零 / 不无限淘汰）" {
    var table: Keys = .empty;
    defer deinit(testing.allocator, &table);

    remember(testing.allocator, &table, 0, try own(testing.allocator, "a"));
    remember(testing.allocator, &table, 0, try own(testing.allocator, "b"));
    try testing.expectEqual(@as(usize, 1), table.items.len);
    try testing.expect(contains(table.items, "b"));
}
