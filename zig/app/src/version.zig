//! 版本号的唯一来源是 `build.zig.zon` 的 `.version`。
//!
//! `build.zig` 在配置阶段把清单读出来，注入成 `build_options.version`（见
//! `build.zig` 的 `manifestVersion`）；这里只做转发，源码里没有第二份字面量。
//!
//! 为什么不用"在源码里写死 + 一条测试比对清单"：
//!   * 那需要两处手写同一个数字，测试只在有人记得跑 `zig build test` 时才能发现漂移；
//!     编译期注入让"代码里的版本"与"清单里的版本"在构造上就是同一个值；
//!   * 打包脚本 `-Version` 再用同一个数字命名产物，并在打包前核对清单，三处不会各说各话。
//!
//! 代价是 `zig build` 每次配置阶段都要读一次几十行的 `build.zig.zon`——可忽略。

const std = @import("std");
const build_options = @import("build_options");

/// 与 `build.zig.zon` 的 `.version` 完全相同（编译期注入）。
pub const version: []const u8 = build_options.version;

/// 窗口标题里的产品名（`OTTO Lite 0.0.1`）。
pub const product = "OTTO Lite";

/// `--version` 行首的程序名：命令行习惯用小写。
pub const cli_name = "otto-lite";

/// `--version` 输出的完整一行：`otto-lite 0.0.1 (portable)`。
/// 单独抽出来是为了让格式能被单测钉住，而不是散落在 `main` 的打印里。
pub fn versionLine(buffer: []u8, mode_label: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{s} {s} ({s})\n", .{ cli_name, version, mode_label });
}

/// 窗口标题：`OTTO Lite 0.0.1 — 42`。
/// 版本必须出现在标题里（CHARTER 九：分发物要能一眼看出是哪个版本）；
/// 行数放在后面，截图和无头验收都能核对。
pub fn windowTitle(buffer: []u8, total: usize) []const u8 {
    return std.fmt.bufPrint(buffer, "{s} {s} — {d}", .{ product, version, total }) catch product;
}

const testing = std.testing;

test "版本号形如 x.y.z" {
    try testing.expect(version.len > 0);
    var parts: usize = 0;
    var it = std.mem.splitScalar(u8, version, '.');
    while (it.next()) |part| {
        try testing.expect(part.len > 0);
        for (part) |ch| try testing.expect(std.ascii.isDigit(ch));
        parts += 1;
    }
    try testing.expectEqual(@as(usize, 3), parts);
}

test "--version 一行：otto-lite <version> (<mode>)" {
    var line_buffer: [128]u8 = undefined;
    var expected_buffer: [128]u8 = undefined;

    const portable = try versionLine(&line_buffer, "portable");
    const expected_portable = try std.fmt.bufPrint(&expected_buffer, "otto-lite {s} (portable)\n", .{version});
    try testing.expectEqualStrings(expected_portable, portable);

    const installed = try versionLine(&line_buffer, "installed");
    const expected_installed = try std.fmt.bufPrint(&expected_buffer, "otto-lite {s} (installed)\n", .{version});
    try testing.expectEqualStrings(expected_installed, installed);
}

test "窗口标题带版本" {
    var buffer: [128]u8 = undefined;
    const title = windowTitle(&buffer, 42);
    const expected = try std.fmt.allocPrint(testing.allocator, "OTTO Lite {s} — 42", .{version});
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, title);
}
