//! electron-store JSON 的容错读取工具。
//!
//! 这里只处理「标量缺失 / null / 类型不对时回退默认值」以及字符串数组去重，
//! 不涉及任何业务语义，方便单独审阅兼容性规则。

const std = @import("std");

/// 取子对象；字段缺失或类型不是对象时返回 null（可选容器用）。
pub fn objectField(container: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const value = container.get(key) orelse return null;
    return switch (value) {
        .object => |object| object,
        else => null,
    };
}

/// 取非空字符串；缺失 / null / 空串 / 非字符串都返回 null。
pub fn optionalString(container: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = container.get(key) orelse return null;
    return switch (value) {
        .string => |text| if (text.len > 0) text else null,
        else => null,
    };
}

pub fn string(container: std.json.ObjectMap, key: []const u8, default: []const u8) []const u8 {
    return optionalString(container, key) orelse default;
}

pub fn optionalBool(container: std.json.ObjectMap, key: []const u8) ?bool {
    const value = container.get(key) orelse return null;
    return switch (value) {
        .bool => |flag| flag,
        .integer => |number| number != 0,
        else => null,
    };
}

pub fn boolean(container: std.json.ObjectMap, key: []const u8, default: bool) bool {
    return optionalBool(container, key) orelse default;
}

pub fn optionalI64(container: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = container.get(key) orelse return null;
    return switch (value) {
        .integer => |number| number,
        .float => |number| floatToI64(number),
        .number_string => |text| std.fmt.parseInt(i64, text, 10) catch null,
        else => null,
    };
}

pub fn int64(container: std.json.ObjectMap, key: []const u8, default: i64) i64 {
    return optionalI64(container, key) orelse default;
}

pub fn uint32(container: std.json.ObjectMap, key: []const u8, default: u32) u32 {
    return std.math.cast(u32, int64(container, key, default)) orelse default;
}

pub fn uint64(container: std.json.ObjectMap, key: []const u8, default: u64) u64 {
    const value = optionalI64(container, key) orelse return default;
    if (value < 0) return default;
    return @intCast(value);
}

pub fn float64(container: std.json.ObjectMap, key: []const u8, default: f64) f64 {
    const value = container.get(key) orelse return default;
    return switch (value) {
        .float => |number| if (std.math.isFinite(number)) number else default,
        .integer => |number| @floatFromInt(number),
        .number_string => |text| blk: {
            const number = std.fmt.parseFloat(f64, text) catch break :blk default;
            break :blk if (std.math.isFinite(number)) number else default;
        },
        else => default,
    };
}

fn floatToI64(number: f64) ?i64 {
    if (!std.math.isFinite(number)) return null;
    const min_bound = @as(f64, @floatFromInt(std.math.minInt(i64)));
    const max_bound = @as(f64, @floatFromInt(std.math.maxInt(i64)));
    if (number < min_bound or number >= max_bound) return null;
    return @intFromFloat(number);
}

/// 读字符串数组：缺失 / 非数组返回空；非字符串元素与空串跳过；重复项保留给 dedupeStrings。
pub fn readStringList(
    allocator: std.mem.Allocator,
    container: std.json.ObjectMap,
    key: []const u8,
) error{OutOfMemory}![]const []const u8 {
    const value = container.get(key) orelse return &.{};
    const items = switch (value) {
        .array => |array| array,
        else => return &.{},
    };
    var result: std.ArrayList([]const u8) = .empty;
    for (items.items) |item| {
        switch (item) {
            .string => |text| if (text.len > 0) try result.append(allocator, text),
            else => {},
        }
    }
    return result.toOwnedSlice(allocator);
}

/// 保序去重；空串会被丢弃。
pub fn dedupeStrings(
    allocator: std.mem.Allocator,
    items: []const []const u8,
) error{OutOfMemory}![]const []const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    var seen = std.StringHashMapUnmanaged(void){};
    defer seen.deinit(allocator);
    for (items) |item| {
        if (item.len == 0) continue;
        if (seen.contains(item)) continue;
        try seen.put(allocator, item, {});
        try result.append(allocator, item);
    }
    return result.toOwnedSlice(allocator);
}

test "标量容错：缺失 / null / 类型错误回退默认值" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"name":"Kick","count":42,"ratio":0.5,"flag":true,"empty":"","nil":null,"bad":"oops"}
    , .{});
    defer parsed.deinit();
    const object = parsed.value.object;

    try std.testing.expectEqualStrings("Kick", string(object, "name", "fallback"));
    try std.testing.expectEqualStrings("oops", string(object, "bad", "fallback"));
    try std.testing.expectEqualStrings("fallback", string(object, "missing", "fallback"));
    try std.testing.expectEqualStrings("fallback", string(object, "nil", "fallback"));
    try std.testing.expectEqual(@as(?[]const u8, null), optionalString(object, "empty"));
    try std.testing.expectEqual(@as(i64, 42), int64(object, "count", 0));
    try std.testing.expectEqual(@as(i64, 0), int64(object, "ratio", 0));
    try std.testing.expectEqual(@as(f64, 0.5), float64(object, "ratio", 0));
    try std.testing.expectEqual(@as(u32, 42), uint32(object, "count", 1));
    try std.testing.expect(boolean(object, "flag", false));
    try std.testing.expect(!boolean(object, "missing", false));
}

test "字符串数组：跳过非字符串与空串，保留重复" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"ids":["a","","b",3,null,"a"]}
    , .{});
    defer parsed.deinit();
    const raw = try readStringList(std.testing.allocator, parsed.value.object, "ids");
    defer std.testing.allocator.free(raw);
    try std.testing.expectEqual(@as(usize, 3), raw.len);
    try std.testing.expectEqualStrings("a", raw[0]);
    try std.testing.expectEqualStrings("b", raw[1]);
    try std.testing.expectEqualStrings("a", raw[2]);

    const unique = try dedupeStrings(std.testing.allocator, raw);
    defer std.testing.allocator.free(unique);
    try std.testing.expectEqual(@as(usize, 2), unique.len);
}
