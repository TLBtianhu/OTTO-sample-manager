//! 响应式布局的纯逻辑验收：不建窗口、不读磁盘。
const std = @import("std");
const layout = @import("responsive_layout.zig");
const testing = std.testing;

test "连续布局：各密度区间约束成立，行高来自唯一常量" {
    const widths = [_]u16{
        280, 300, 320, 359, // compact_with_overflow
        360, 380, 424, 425, // name_and_duration
        426, 480, 560, 561, // no_sample_rate
        562, 640, 720, 900, 1200, // full（采样率从 1px 连续长大）
    };
    for (widths) |width| {
        const plan = layout.solve(width, 700);
        try layout.validate(&plan);
        try testing.expectEqual(layout.listProfile(width), plan.profile);
        try testing.expectEqual(@as(u16, 16), plan.font_size);
        try testing.expectEqual(layout.row_height, plan.row.height);
    }
}

test "行高同源：样本行、树行、列表与浏览滚动共享布局来源" {
    // 编译期嵌入的接线快照：四个调用点都不能再私藏 44。
    try testing.expect(std.mem.indexOf(u8, @embedFile("main.zig"), ".row_height = @floatFromInt(layout_plan.row.height)") != null);
    try testing.expect(std.mem.indexOf(u8, @embedFile("row_ui.zig"), ".px = @floatFromInt(plan.height)") != null);
    try testing.expect(std.mem.indexOf(u8, @embedFile("library_tree_ui.zig"), ".px = @floatFromInt(responsive_layout.row_height)") != null);
    try testing.expect(std.mem.indexOf(u8, @embedFile("browse_action.zig"), "scroll.target(session, s.search.len(), @floatFromInt(s.layout.plan.row.height), view_height)") != null);
}

test "窗口下限：0×0 和负值输入不会拖垮布局" {
    const zero = layout.solve(0, 0);
    try layout.validate(&zero);
    try testing.expectEqual(layout.min_window_width, zero.width);
    try testing.expectEqual(layout.min_window_height, zero.height);
    var cache: layout.Cache = .{};
    const plan = cache.update(-100, std.math.nan(f32));
    try layout.validate(plan);
    try testing.expectEqual(@as(u16, 540), layout.default_window_width);
    try testing.expectEqual(@as(u16, 960), layout.default_window_height);
    try testing.expectEqual(layout.default_window_width, plan.width);
    try testing.expectEqual(layout.default_window_height, plan.height);
    try testing.expectEqual(@as(u16, 384), layout.min_window_width);
    try testing.expectEqual(@as(u16, 768), layout.min_window_height);
}

test "让位顺序与逐像素连续：辅助列依次收缩，所有相邻尺寸变化最多 1px" {
    const full = layout.solve(640, 700);
    const no_rate = layout.solve(560, 700);
    const no_size = layout.solve(480, 700);
    const names = layout.solve(425, 700);
    const compact = layout.solve(359, 700);

    try testing.expect(full.row.visible(.sample_rate));
    try testing.expect(!no_rate.row.visible(.sample_rate));
    try testing.expect(no_rate.row.visible(.format));
    try testing.expect(no_rate.row.visible(.size));
    try testing.expect(!no_size.row.visible(.sample_rate));
    try testing.expect(!no_size.row.visible(.size));
    try testing.expect(no_size.row.visible(.format));
    try testing.expect(!names.row.visible(.format));
    try testing.expect(!names.row.visible(.size));
    try testing.expect(names.row.visible(.duration));
    try testing.expect(!compact.row.visible(.format));
    for ([_]layout.Plan{ full, no_rate, no_size, names, compact }) |plan| {
        try testing.expect(plan.row.visible(.name));
        try testing.expect((plan.row.width(.name) orelse 0) >= layout.min_name_width);
    }

    var previous = layout.solve(280, 700);
    for (281..901) |width| {
        const plan = layout.solve(@intCast(width), 700);
        try layout.validate(&plan);
        try testing.expect(absDelta(previous.row.width(.name).?, plan.row.width(.name).?) <= 1);
        for ([_]layout.ColumnKind{ .duration, .format, .sample_rate, .size }) |kind| {
            const before = previous.row.width(kind);
            const after = plan.row.width(kind);
            if (before != null and after != null) {
                try testing.expect(absDelta(before.?, after.?) <= 1);
            } else if (before != null) {
                try testing.expect(before.? <= 1);
            } else if (after != null) {
                try testing.expect(after.? <= 1);
            }
        }
        try testing.expect(absDelta(previous.preview_height, plan.preview_height) <= 1);
        previous = plan;
    }
}

fn absDelta(a: u16, b: u16) u16 {
    return if (a > b) a - b else b - a;
}

test "预览条：只随高度连续插值，最小窗口仍是 192px 完整预览" {
    // 宽度不再参与预览高度；低于最小高度的输入也先夹到 768。
    for ([_]u16{ 360, 380, 479, 480, 540, 900 }) |width| {
        try testing.expectEqual(@as(u16, 192), layout.solve(width, 700).preview_height);
    }
    try testing.expectEqual(@as(u16, 192), layout.solve(384, 768).preview_height);
    try testing.expectEqual(@as(u16, 193), layout.solve(384, 772).preview_height);
    try testing.expectEqual(@as(u16, 216), layout.solve(540, 960).preview_height);
    try testing.expectEqual(@as(u16, 216), layout.solve(900, 1200).preview_height);

    // 逐高度扫描：可见预览始终是 192–216，增长相邻至多 1px；
    // 即使损坏输入绕过 Windows 下限，求解器也只回完整预览，不返回细条或隐藏态。
    var previous = layout.previewHeight(540, 0);
    try testing.expectEqual(layout.min_preview_height, previous);
    for (1..961) |height| {
        const current = layout.previewHeight(540, @intCast(height));
        try testing.expect(current >= layout.min_preview_height and current <= layout.max_preview_height);
        try testing.expect(absDelta(previous, current) <= 1);
        previous = current;
    }
    for ([_]u16{ 0, 100, 360, 600, 767 }) |height| {
        const plan = layout.solve(384, height);
        try layout.validate(&plan);
        try testing.expectEqual(layout.min_window_height, plan.height);
        try testing.expectEqual(layout.min_preview_height, plan.preview_height);
    }
    for ([_]u16{ 0, 1, 15, 96, 150, 180, 191, 217 }) |height| {
        var invalid = layout.solve(384, 768);
        invalid.preview_height = height;
        try testing.expectError(error.PreviewBounds, layout.validate(&invalid));
    }
}

test "懒重算：滚动/刷新/hover 的同尺寸帧不求解，同 profile 不重建列结构" {
    var cache: layout.Cache = .{};
    _ = cache.update(500, 700);
    const revision = cache.display_revision;
    for (0..1000) |_| _ = cache.update(500, 700);
    try testing.expectEqual(@as(u32, 1), cache.solves);
    try testing.expectEqual(revision, cache.display_revision);

    _ = cache.update(501, 700);
    try testing.expectEqual(@as(u32, 2), cache.solves);
    try testing.expectEqual(revision, cache.display_revision);
    _ = cache.update(561, 700);
    try testing.expectEqual(revision, cache.display_revision);
    _ = cache.update(562, 700);
    try testing.expectEqual(revision + 1, cache.display_revision);
}

test "性能：连续改变宽度 200 次的布局总耗时低于 62.5fps 的一帧" {
    var cache: layout.Cache = .{};
    _ = cache.update(280, 700);
    const started = std.Io.Timestamp.now(testing.io, .awake);
    for (0..200) |index| {
        const width: f32 = @floatFromInt(280 + index * 3);
        const plan = cache.update(width, 700);
        try layout.validate(plan);
    }
    const elapsed = std.Io.Timestamp.now(testing.io, .awake).nanoseconds - started.nanoseconds;
    std.debug.print("responsive-layout: 200 resizes {d:.3} ms, solves={d}\n", .{
        @as(f64, @floatFromInt(elapsed)) / std.time.ns_per_ms,
        cache.solves,
    });
    try testing.expectEqual(@as(u32, 200), cache.solves);
    try testing.expect(elapsed < 16 * std.time.ns_per_ms);
}

test "反向证明：等比缩放会缩字体，约束断言必须红" {
    var scaled = layout.solve(900, 700);
    scaled.width = 280;
    scaled.height = 420;
    scaled.profile = layout.listProfile(280);
    scaled.preview_height = layout.min_preview_height;
    scaled.font_size = @divTrunc(16 * 280, 900);
    scaled.row.container_width = 280;
    scaled.row.thumb = scaleRect(scaled.row.thumb, 280, 900);
    scaled.row.ordinal = scaleRect(scaled.row.ordinal, 280, 900);
    for (scaled.row.columns[0..scaled.row.column_count]) |*column| column.rect = scaleRect(column.rect, 280, 900);
    try testing.expectError(error.FontScaled, layout.validate(&scaled));
}

test "反向证明：窗口变窄但不重排会越界，约束断言必须红" {
    var stale = layout.solve(900, 700);
    stale.width = 280;
    stale.height = 420;
    stale.profile = layout.listProfile(280);
    stale.preview_height = layout.min_preview_height;
    stale.row.container_width = 280;
    try testing.expectError(error.OutOfBounds, layout.validate(&stale));
}

fn scaleRect(rect: layout.Rect, numerator: u16, denominator: u16) layout.Rect {
    return .{
        .x = @divTrunc(rect.x * numerator, denominator),
        .y = rect.y,
        .w = @divTrunc(rect.w * numerator, denominator),
        .h = @divTrunc(rect.h * numerator, denominator),
    };
}
