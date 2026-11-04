//! 库树的文件夹行；样本行仍由 row_ui.zig 负责。
const nanoui = @import("nanoui");
const library_tree = @import("library_tree.zig");
const responsive_layout = @import("responsive_layout.zig");
const ui = nanoui.ui;

pub fn draw(c: *ui.Context, row: library_tree.Row, selected: bool) ui.Interaction {
    const indent: f32 = 12 + @as(f32, @floatFromInt(row.depth)) * 16;
    const it = ui.pressable(c, .{
        .direction = .row,
        .width = .fill,
        .height = .{ .px = @floatFromInt(responsive_layout.row_height) },
        .padding = .{ .left = indent, .right = 12 },
        .gap = 8,
        .align_items = .center,
        .control = true,
        .background = if (selected) c.theme.accent.alpha(0.16) else null,
    }, c.theme.surface_hover);
    defer ui.end(c);
    ui.text(c, if (row.expanded) "▾" else "▸", .{ .size = 18, .color = c.theme.accent });
    ui.icon(c, "folder", .{ .size = 22, .color = c.theme.accent });
    ui.text(c, row.name, .{ .size = 18, .weight = .semibold, .truncate = .ellipsis });
    return it;
}
