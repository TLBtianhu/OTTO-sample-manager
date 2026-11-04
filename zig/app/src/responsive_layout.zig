//! OTTO 的容器驱动布局：列表 profile + 尺寸缓存。
//!
//! 这里不做通用 flexbox，也不做等比缩放。所有尺寸都是容器内的逻辑点；
//! 字体、行高和点击目标是常量。只有 `Cache.update` 看到容器尺寸真的变化，
//! 才重新求解；profile 不变时 `display_revision` 不变，调用方只更新数值。
const std = @import("std");

pub const min_window_width: u16 = 384;
pub const min_window_height: u16 = 768;
pub const min_name_width: u16 = 96;
pub const row_height: u16 = 44;
pub const font_size: u16 = 16;
pub const min_click_target: u16 = 24;
/// 按最占空间的音频分支定量：18px 播放按钮/正文、56px 波形与两行事实
/// 需要 192px；240px 波形加图位和横向间距需要约 374px，宽度取 384。
/// Windows 在 384×768 夹住缩放，因此产品里没有紧凑条或隐藏态。
pub const min_preview_height: u16 = 192;
pub const max_preview_height: u16 = 216;
pub const default_window_width: u16 = 540;
pub const default_window_height: u16 = 960;

const row_padding: u16 = 12;
const row_gap: u16 = 8;
/// 18px 下四位序号也需要完整点击/绘制槽，不能沿用 13px 时代的 34px。
const ordinal_width: u16 = 44;

pub const Profile = enum {
    compact_with_overflow,
    name_and_duration,
    no_sample_rate,
    full,
};

/// Profile describes structural density, not a second set of dimensions.
/// Column widths themselves come from the continuous slots below.
pub fn listProfile(container_width: u16) Profile {
    const width = @max(container_width, min_window_width);
    if (slotContent(auxiliarySlot(width, .sample_rate), .sample_rate) > 0) return .full;
    if (slotContent(auxiliarySlot(width, .format), .format) > 0 or
        slotContent(auxiliarySlot(width, .size), .size) > 0) return .no_sample_rate;
    if (width >= 360) return .name_and_duration;
    return .compact_with_overflow;
}

pub const ColumnKind = enum { name, duration, format, sample_rate, size };

pub const Rect = struct {
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,
};

pub const Column = struct {
    kind: ColumnKind,
    rect: Rect,
    /// Flow gap owned by this column. It shrinks with the column, so removing
    /// a column never hands a whole 8px gap back to the name in one frame.
    gap_before: u16 = 0,
};

pub const RowPlan = struct {
    container_width: u16,
    height: u16 = row_height,
    thumb: Rect,
    ordinal: Rect,
    columns: [5]Column = @splat(.{ .kind = .name, .rect = .{} }),
    column_count: usize = 0,

    pub fn visible(self: *const RowPlan, kind: ColumnKind) bool {
        return self.find(kind) != null;
    }

    pub fn width(self: *const RowPlan, kind: ColumnKind) ?u16 {
        const column = self.find(kind) orelse return null;
        return @intCast(column.rect.w);
    }

    fn find(self: *const RowPlan, kind: ColumnKind) ?*const Column {
        for (self.columns[0..self.column_count]) |*column| {
            if (column.kind == kind) return column;
        }
        return null;
    }
};

pub const Plan = struct {
    width: u16,
    height: u16,
    profile: Profile,
    row: RowPlan,
    preview_height: u16,
    font_size: u16 = font_size,
    toolbar_target: u16 = min_click_target,
    search_target: u16 = 28,
};

pub fn previewHeight(container_width: u16, container_height: u16) u16 {
    _ = container_width;
    // 高度每增加 4px，预览最多增加 1px；宽度只参与列表列求解。
    // 窗口下限保证这里至少是 192，任何尺寸都不会出现紧凑细条。
    return std.math.clamp(container_height / 4, min_preview_height, max_preview_height);
}

pub fn solve(container_width: u16, container_height: u16) Plan {
    // 即使无头脚本或损坏的设置送来 0，也先回到安全下限，不产生负尺寸。
    const width = @max(container_width, min_window_width);
    const height = @max(container_height, min_window_height);
    const profile = listProfile(width);

    // 辅助列的 slot 同时包含列宽与它前面的 gap。缩窗时依次收缩采样率、
    // 大小、格式；名称始终拿剩余。slot 每变 1px，名称也只反向变 1px。
    const duration_slot: u16 = fixedWidth(.duration) + row_gap;
    const format_slot = auxiliarySlot(width, .format);
    const rate_slot = auxiliarySlot(width, .sample_rate);
    const size_slot = auxiliarySlot(width, .size);
    const leading: u16 = 2 * row_padding + 32 + row_gap + ordinal_width + row_gap;
    const name_width = width - leading - duration_slot - format_slot - rate_slot - size_slot;

    var row: RowPlan = .{
        .container_width = width,
        .thumb = rect(row_padding, 32),
        .ordinal = rect(row_padding + 32 + row_gap, ordinal_width),
    };
    var x: u16 = row_padding + 32 + row_gap + ordinal_width;
    const kinds = [_]ColumnKind{ .name, .duration, .format, .sample_rate, .size };
    for (kinds) |kind| {
        const slot = switch (kind) {
            .name => name_width + row_gap,
            .duration => duration_slot,
            .format => format_slot,
            .sample_rate => rate_slot,
            .size => size_slot,
        };
        const content = if (kind == .name) name_width else slotContent(slot, kind);
        if (content == 0) continue;
        const gap = slot - content;
        x += gap;
        row.columns[row.column_count] = .{ .kind = kind, .rect = rect(x, content), .gap_before = gap };
        row.column_count += 1;
        x += content;
    }
    return .{
        .width = width,
        .height = height,
        .profile = profile,
        .row = row,
        .preview_height = previewHeight(width, height),
    };
}

/// The container width at which each auxiliary slot is full. The next slot
/// starts yielding exactly where the previous one reaches zero.
fn auxiliarySlot(width: u16, kind: ColumnKind) u16 {
    const full_at: u16 = switch (kind) {
        .sample_rate => 640,
        .size => 560,
        .format => 480,
        else => return 0,
    };
    const slot_capacity = fixedWidth(kind) + row_gap;
    return std.math.clamp(width -| (full_at - slot_capacity), 0, slot_capacity);
}

fn slotContent(slot: u16, kind: ColumnKind) u16 {
    const slot_capacity = fixedWidth(kind) + row_gap;
    return @intCast((@as(u32, slot) * fixedWidth(kind)) / slot_capacity);
}

fn fixedWidth(kind: ColumnKind) u16 {
    return switch (kind) {
        .name => min_name_width,
        .duration => 56,
        .format => 48,
        .sample_rate => 72,
        .size => 72,
    };
}

fn rect(x: u16, width: u16) Rect {
    return .{ .x = x, .y = 0, .w = width, .h = row_height };
}

pub const Cache = struct {
    plan: Plan = undefined,
    has_size: bool = false,
    last_width: u16 = 0,
    last_height: u16 = 0,
    solves: u32 = 0,
    /// 列结构（不是 nanoui 每帧的 GPU display list）的版本。
    display_revision: u32 = 0,

    pub fn update(self: *Cache, width_points: f32, height_points: f32) *const Plan {
        const width = points(width_points, default_window_width);
        const height = points(height_points, default_window_height);
        if (self.has_size and width == self.last_width and height == self.last_height) return &self.plan;
        const old_profile = if (self.has_size) self.plan.profile else null;
        self.plan = solve(width, height);
        self.last_width = width;
        self.last_height = height;
        self.has_size = true;
        self.solves += 1;
        if (old_profile == null or old_profile.? != self.plan.profile) self.display_revision += 1;
        return &self.plan;
    }
};

fn points(value: f32, fallback: u16) u16 {
    if (!std.math.isFinite(value) or value <= 0) return fallback;
    return @intFromFloat(std.math.clamp(@round(value), 1, 16384));
}

pub const ValidationError = error{
    NameTooNarrow,
    TargetTooSmall,
    FontScaled,
    NegativeSize,
    OutOfBounds,
    Overlap,
    MissingName,
    DuplicateColumn,
    StaleProfile,
    PreviewBounds,
};

/// 验收共用的约束断言；测试也会把等比缩放/不重排的计划喂给它做反向证明。
pub fn validate(plan: *const Plan) ValidationError!void {
    if (plan.profile != listProfile(plan.width)) return error.StaleProfile;
    if (plan.font_size != font_size) return error.FontScaled;
    if (plan.row.height < min_click_target or plan.toolbar_target < min_click_target or plan.search_target < min_click_target) return error.TargetTooSmall;
    if (plan.preview_height < min_preview_height or plan.preview_height > max_preview_height or plan.preview_height > plan.height) return error.PreviewBounds;
    if (!plan.row.visible(.name)) return error.MissingName;
    if ((plan.row.width(.name) orelse 0) < min_name_width) return error.NameTooNarrow;
    if (plan.row.container_width != plan.width) return error.OutOfBounds;

    var rects: [7]Rect = undefined;
    rects[0] = plan.row.thumb;
    rects[1] = plan.row.ordinal;
    for (plan.row.columns[0..plan.row.column_count], 0..) |column, index| {
        if (column.kind != .name) {
            for (plan.row.columns[0..index]) |previous| {
                if (previous.kind == column.kind) return error.DuplicateColumn;
            }
        }
        rects[index + 2] = column.rect;
    }
    const count = plan.row.column_count + 2;
    for (rects[0..count], 0..) |a, i| {
        if (a.x < 0 or a.y < 0 or a.w <= 0 or a.h <= 0) return error.NegativeSize;
        if (a.x + a.w > plan.width or a.y + a.h > plan.row.height) return error.OutOfBounds;
        for (rects[i + 1 .. count]) |b| {
            if (a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h) return error.Overlap;
        }
    }
}
