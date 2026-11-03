//! 响应式布局的纯逻辑验收：不建窗口、不读磁盘。
const std = @import("std");
const layout = @import("responsive_layout.zig");
const testing = std.testing;

test "轨道分配：fixed、fraction、minmax 下限与 max 余量再分配" {
    const tracks = [_]layout.Track{
        .{ .fixed = 32 },
        .{ .fraction = 1 },
        .{ .minmax = .{ .min = 56, .max = 80, .weight = 1 } },
        .{ .minmax = .{ .min = 20, .max = 200, .weight = 2 } },
    };
    var storage: [4]u16 = undefined;
    const sizes = layout.distribute(400, &tracks, &storage);
    try testing.expectEqual(@as(u16, 32), sizes[0]);
    try testing.expectEqual(@as(u16, 80), sizes[2]);
    try testing.expectEqual(@as(u16, 198), sizes[3]);
    try testing.expectEqual(@as(u16, 90), sizes[1]);
    try testing.expectEqual(@as(u32, 400), sum(sizes));

    const capped = layout.distribute(240, &tracks, &storage);
    try testing.expectEqual(@as(u16, 80), capped[2]);
    try testing.expectEqual(@as(u32, 240), sum(capped));
    for (capped, tracks) |size, track| switch (track) {
        .minmax => |range| {
            try testing.expect(size >= range.min);
            try testing.expect(size <= @max(range.min, range.max));
        },
        else => {},
    };
}

test "轨道分配：舍入不丢像素，极端小总量也无负尺寸" {
    const tracks = [_]layout.Track{ .{ .fraction = 1 }, .{ .fraction = 1 }, .{ .fraction = 1 } };
    var storage: [3]u16 = undefined;
    const sizes = layout.distribute(2, &tracks, &storage);
    try testing.expectEqual(@as(u32, 2), sum(sizes));
    const tiny = layout.distribute(1, &tracks, &storage);
    try testing.expectEqual(@as(u32, 1), sum(tiny));
}

fn sum(values: []const u16) u32 {
    var total: u32 = 0;
    for (values) |value| total += value;
    return total;
}

test "连续布局：各密度区间均无重叠/负尺寸/越界，目标和名称可读" {
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
        try testing.expectEqual(@as(u16, 13), plan.font_size);
        try testing.expectEqual(@as(u16, 44), plan.row.height);
    }
}

test "窗口下限：0×0 和负值输入不会拖垮布局" {
    const zero = layout.solve(0, 0);
    try layout.validate(&zero);
    try testing.expectEqual(layout.min_window_width, zero.width);
    try testing.expectEqual(layout.min_window_height, zero.height);
    var cache: layout.Cache = .{};
    const plan = cache.update(-100, std.math.nan(f32));
    try layout.validate(plan);
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

test "预览条：连续插值、小窗口紧凑预览与不足时明确占位" {
    try testing.expectEqual(@as(u16, 56), layout.solve(360, 700).preview_height);
    try testing.expectEqual(@as(u16, 75), layout.solve(380, 700).preview_height);
    try testing.expectEqual(@as(u16, 174), layout.solve(479, 700).preview_height);
    try testing.expectEqual(@as(u16, 175), layout.solve(480, 700).preview_height);
    try testing.expectEqual(@as(u16, 0), layout.previewHeight(480, 100));
    try testing.expectEqual(@as(u16, 0), layout.solve(480, 100).preview_height);
    try testing.expectEqual(@as(u16, 180), layout.solve(900, 1200).preview_height);
    for ([_]layout.Plan{
        layout.solve(280, 420), layout.solve(300, 400),
        layout.solve(320, 380), layout.solve(360, 480),
    }) |plan| {
        try layout.validate(&plan);
        try testing.expectEqual(layout.compact_preview_height, plan.preview_height);
    }
    for ([_]u16{ 0, 100, 119, 120, 130, 140, 150, 159 }) |height| {
        const plan = layout.solve(320, height);
        try layout.validate(&plan);
        try testing.expectEqual(@as(u16, 0), plan.preview_height);
    }
    try testing.expectEqual(layout.compact_preview_height, layout.solve(320, 160).preview_height);
    for ([_]u16{ 1, 15, 27, 55 }) |height| {
        var invalid = layout.solve(320, 420);
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
    scaled.preview_height = 56;
    scaled.font_size = @divTrunc(13 * 280, 900);
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
    stale.preview_height = 56;
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
