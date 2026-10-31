//! `options.zig` 里放不下的解析测试。
//!
//! 从 `options.zig` 拆出来只为守住单文件 600 行（与 `preview_test.zig` 同一条
//! 理由）：这里只依赖 `parse` 的公开行为，不碰文件系统、不碰窗口。

const std = @import("std");
const options_mod = @import("options.zig");

const testing = std.testing;
const parse = options_mod.parse;

test "--cache-budget-kib：两种写法、KiB → 字节、默认 256 MiB、非数字报 InvalidValue" {
    const joined = try parse(&[_][]const u8{ "otto-lite", "--cache-budget-kib=100" });
    try testing.expectEqual(@as(u64, 100 * 1024), joined.disk_cache_budget_bytes);
    try testing.expect(joined.cache_budget_set);

    const spaced = try parse(&[_][]const u8{ "otto-lite", "--cache-budget-kib", "256" });
    try testing.expectEqual(@as(u64, 256 * 1024), spaced.disk_cache_budget_bytes);
    try testing.expect(spaced.cache_budget_set);

    const plain = try parse(&[_][]const u8{"otto-lite"});
    try testing.expectEqual(@as(u64, 256 * 1024 * 1024), plain.disk_cache_budget_bytes);
    try testing.expect(!plain.cache_budget_set);

    try testing.expectError(error.MissingValue, parse(&[_][]const u8{ "otto-lite", "--cache-budget-kib" }));
    try testing.expectError(error.InvalidValue, parse(&[_][]const u8{ "otto-lite", "--cache-budget-kib=x" }));
}

test "--no-shell-preview：是开关、不吞下一个参数、不影响位置参数" {
    const plain = try parse(&[_][]const u8{"otto-lite"});
    try testing.expect(!plain.no_shell_preview);

    const enabled = try parse(&[_][]const u8{ "otto-lite", "--no-shell-preview", "lib.json" });
    try testing.expect(enabled.no_shell_preview);
    try testing.expectEqualStrings("lib.json", enabled.library_path.?);

    const with_preview = try parse(&[_][]const u8{ "otto-lite", "--preview", "img00.png", "--no-shell-preview" });
    try testing.expect(with_preview.no_shell_preview);
    try testing.expectEqualStrings("img00.png", with_preview.preview_path.?);
}

test "--seek-at：两种写法都收、0 合法、缺值/非数字报错，不占位置参数" {
    const spaced = try parse(&[_][]const u8{ "otto-lite", "--play-test", "tone.wav", "--seek-at", "600" });
    try testing.expectEqualStrings("tone.wav", spaced.play_test_path.?);
    try testing.expectEqual(@as(u64, 600), spaced.seek_at_ms.?);
    try testing.expect(spaced.library_path == null);

    const joined = try parse(&[_][]const u8{ "otto-lite", "--play-test=tone.wav", "--seek-at=600" });
    try testing.expectEqualStrings("tone.wav", joined.play_test_path.?);
    try testing.expectEqual(@as(u64, 600), joined.seek_at_ms.?);

    // 0 = 跳回开头，是合法值，不能和"没给"混成同一种状态。
    const zero = try parse(&[_][]const u8{ "otto-lite", "--seek-at=0" });
    try testing.expectEqual(@as(u64, 0), zero.seek_at_ms.?);
    const none = try parse(&[_][]const u8{"otto-lite"});
    try testing.expect(none.seek_at_ms == null);

    try testing.expectError(error.MissingValue, parse(&[_][]const u8{ "otto-lite", "--seek-at" }));
    try testing.expectError(error.InvalidValue, parse(&[_][]const u8{ "otto-lite", "--seek-at=x" }));
}
