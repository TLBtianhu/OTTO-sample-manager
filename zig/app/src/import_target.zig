//! 导入的保存目标策略：当前库是 `.otto` 就原地保存；是旧 JSON 就存到同目录的
//! `<stem>.otto`（并告诉调用方"这是一次格式转换"，UI 表头提示一次）。
//!
//! 为什么单独一层：UI 的按钮与 `--import-into` 的无头入口必须给出**同一个**目标，
//! 否则两条路径会写出两份库。本文件只做字符串策略，不读文件、不碰磁盘；真正的
//! 格式判断仍由 `library_io.zig` 按 magic 做（这里看扩展名只是决定"写去哪"）。
//!
//! 显式的 `override`（`--save <file>`）优先：调用方已经点名了位置，不再猜。

const std = @import("std");

/// 一次导入的落点。`path` 归调用方，用同一个 allocator 释放。
pub const Target = struct {
    path: []u8,
    /// true = 当前库不是 OTTOLIB（按扩展名），这次会把结果写成同目录的 `.otto`。
    /// UI 只在 true 时提示一次「已转为 OTTOLIB」。
    converted: bool,

    pub fn deinit(self: *Target, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.* = undefined;
    }
};

/// 扩展名是不是 `.otto`（ASCII 大小写不敏感）。只是保存策略，不是格式真相。
pub fn isOttoPath(path: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ".otto");
}

/// 决定这次导入写到哪里。
///
///   * `override` 非空 → 原样使用，不算转换（用户点名了 `--save`）；
///   * 当前库是 `.otto` → 原地保存；
///   * 否则 → 同目录 `<stem>.otto`，`converted = true`。
pub fn resolve(
    allocator: std.mem.Allocator,
    library_path: []const u8,
    override: ?[]const u8,
) error{OutOfMemory}!Target {
    if (override) |path| {
        return .{ .path = try allocator.dupe(u8, path), .converted = false };
    }
    if (isOttoPath(library_path)) {
        return .{ .path = try allocator.dupe(u8, library_path), .converted = false };
    }

    const stem = std.fs.path.stem(library_path);
    const file_name = try std.fmt.allocPrint(allocator, "{s}.otto", .{stem});
    defer allocator.free(file_name);

    const path = if (std.fs.path.dirname(library_path)) |directory|
        try std.fs.path.join(allocator, &.{ directory, file_name })
    else
        try allocator.dupe(u8, file_name);
    return .{ .path = path, .converted = true };
}

// ---------------------------------------------------------------------------
// 测试：纯字符串策略
// ---------------------------------------------------------------------------

const testing = std.testing;

test "JSON 库：存到同目录 <stem>.otto，标记为转换" {
    const source = try std.fs.path.join(testing.allocator, &.{ "C:\\lib", "kit.json" });
    defer testing.allocator.free(source);
    var target = try resolve(testing.allocator, source, null);
    defer target.deinit(testing.allocator);

    const expected = try std.fs.path.join(testing.allocator, &.{ "C:\\lib", "kit.otto" });
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, target.path);
    try testing.expect(target.converted);
}

test "已经是 .otto：原地保存，不算转换（大小写不敏感）" {
    for ([_][]const u8{ "kit.otto", "KIT.OTTO", "C:\\lib\\Kit.OtTo" }) |source| {
        var target = try resolve(testing.allocator, source, null);
        defer target.deinit(testing.allocator);
        try testing.expectEqualStrings(source, target.path);
        try testing.expect(!target.converted);
    }
}

test "--save 覆盖优先：原样使用，不标记转换" {
    var target = try resolve(testing.allocator, "C:\\lib\\old.json", "D:\\out\\chosen.otto");
    defer target.deinit(testing.allocator);
    try testing.expectEqualStrings("D:\\out\\chosen.otto", target.path);
    try testing.expect(!target.converted);
}

test "多点文件名：只换最后一个扩展名" {
    var target = try resolve(testing.allocator, "C:\\lib\\pack.v2.json", null);
    defer target.deinit(testing.allocator);
    const expected = try std.fs.path.join(testing.allocator, &.{ "C:\\lib", "pack.v2.otto" });
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, target.path);
}

test "没有目录的库路径：落在当前目录的 <stem>.otto" {
    var target = try resolve(testing.allocator, "library.json", null);
    defer target.deinit(testing.allocator);
    try testing.expectEqualStrings("library.otto", target.path);
    try testing.expect(target.converted);
}
