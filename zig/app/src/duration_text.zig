//! 列表行里的时长文本：`40.9s` / `≈40.9s` / `未知`。
//!
//! 单独成一个纯函数文件，是为了让"估算值必须带 ≈"这条规则可以被单测钉住，
//! 而不需要建窗口。`row_ui.zig` 只负责把返回值塞进 `ui.textf`（帧 arena 会复制，
//! 栈上的 buffer 不会悬垂）。
//!
//! `estimated` 来自 `duration_trust.zig` 的 app 侧 side table：`Sample` 只有一个
//! `f64`（core 的语义不允许改），所以"这个时长是不是推算的"不能存在样本里。

const std = @import("std");

/// 格式化一位小数的秒数。`seconds <= 0` 在模型里表示"还没读过头"，显示"未知"
/// 而不是 `0.0s`（和 `sample_facts.formatDuration` 同一口径）。
pub fn format(seconds: f64, estimated: bool, buffer: *[32]u8) []const u8 {
    if (!(seconds > 0)) return "未知";
    const prefix = if (estimated) "≈" else "";
    return std.fmt.bufPrint(buffer, "{s}{d:.1}s", .{ prefix, seconds }) catch "?";
}

// ---------------------------------------------------------------------------
// 测试：纯格式化
// ---------------------------------------------------------------------------

const testing = std.testing;

test "精确时长不带前缀；估算时长必须带 ≈" {
    var buffer: [32]u8 = undefined;
    try testing.expectEqualStrings("40.9s", format(40.933, false, &buffer));
    try testing.expectEqualStrings("≈40.9s", format(40.933, true, &buffer));
    try testing.expectEqualStrings("1.5s", format(1.5, false, &buffer));
    try testing.expectEqualStrings("0.8s", format(0.8, false, &buffer));
}

test "未知 / 非正数：显示“未知”，不显示 0.0s" {
    var buffer: [32]u8 = undefined;
    try testing.expectEqualStrings("未知", format(0, false, &buffer));
    try testing.expectEqualStrings("未知", format(0, true, &buffer));
    try testing.expectEqualStrings("未知", format(-1, false, &buffer));
    try testing.expectEqualStrings("未知", format(std.math.nan(f64), true, &buffer));
}

test "四舍五入到一位小数" {
    var buffer: [32]u8 = undefined;
    try testing.expectEqualStrings("0.1s", format(0.05, false, &buffer));
    try testing.expectEqualStrings("1.0s", format(0.99, false, &buffer));
}
