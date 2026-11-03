//! Stage 2 的每目录滚动记忆：存储挂在 `browse_history.Record`，这里没有磁盘与设置。
//! 恢复只消费一次；目录变短、视口变大都先夹到 `[0, content-view]`，越界不会进入列表。

const std = @import("std");
const browse = @import("browse.zig");

pub fn clamp(offset: f32, row_count: usize, row_height: f32, view_height: f32) f32 {
    if (!std.math.isFinite(offset) or !std.math.isFinite(view_height) or row_height <= 0) return 0;
    const content = @as(f32, @floatFromInt(row_count)) * row_height;
    const maximum = @max(0, content - @max(0, view_height));
    return std.math.clamp(offset, 0, maximum);
}

/// 返回本帧应恢复的偏移；枚举没完时不碰旧列表，也不消费这次恢复。
pub fn target(session: *browse.Session, row_count: usize, row_height: f32, view_height: f32) ?f32 {
    if (!session.scroll_restore or session.enumerating or session.swapping) return null;
    session.scroll_restore = false;
    return clamp(session.history.current().scroll_offset, row_count, row_height, view_height);
}

/// 每帧记下当前目录的实际偏移。待恢复期间不写新节点，免得旧目录残影覆盖目标值。
pub fn remember(session: *browse.Session, offset: f32) void {
    if (session.scroll_restore) return;
    if (!std.math.isFinite(offset)) return;
    session.history.currentMut().scroll_offset = @max(0, offset);
}

const testing = std.testing;

test "滚动记忆：A 的偏移在返回时恢复一次，之后不阻止用户继续滚动" {
    var history = try @import("browse_history.zig").History.init(testing.allocator, "A");
    defer history.deinit();
    history.currentMut().scroll_offset = 440;
    _ = try history.push("B");
    history.currentMut().scroll_offset = 88;
    try testing.expect(history.back());
    try testing.expectEqual(@as(f32, 440), history.current().scroll_offset);
    // 恢复是纯读；真正的 `target` 消费标志由 Session 测试覆盖。
    history.currentMut().scroll_offset = 132;
    try testing.expectEqual(@as(f32, 132), history.current().scroll_offset);
}

test "滚动记忆：目录内容减少后夹到合法范围，空目录与坏值归零" {
    try testing.expectEqual(@as(f32, 216), clamp(9999, 10, 44, 224));
    try testing.expectEqual(@as(f32, 0), clamp(9999, 2, 44, 224));
    try testing.expectEqual(@as(f32, 0), clamp(9999, 0, 44, 224));
    try testing.expectEqual(@as(f32, 0), clamp(-20, 10, 44, 224));
    try testing.expectEqual(@as(f32, 0), clamp(std.math.nan(f32), 10, 44, 224));
    try testing.expectEqual(@as(f32, 88), clamp(88, 10, 44, 224));
}
