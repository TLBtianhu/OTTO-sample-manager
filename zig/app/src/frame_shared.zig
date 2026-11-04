//! 两种模式共用的一帧部件：搜索、表头、样本列表、预览、设置与空闲预取。
//! 这里只搬动原有调用，不抽象新的 UI 框架；模式专属动作留在 library_frame /
//! browse_frame。尤其 `allow_remove=false` 时，表头既不构建移除按钮，也不执行库写。

const std = @import("std");
const nanoui = @import("nanoui");
const browse_action = @import("browse_action.zig");
const list_header = @import("list_header.zig");
const library_tree_ui = @import("library_tree_ui.zig");
const open_ui = @import("open_ui.zig");
const remove_ui = @import("remove_ui.zig");
const responsive_layout = @import("responsive_layout.zig");
const row_ui = @import("row_ui.zig");
const search_ui = @import("search_ui.zig");
const State = @import("main.zig").State;
const ui = nanoui.ui;

pub const Rows = struct {
    first: usize = 0,
    last: usize = 0,
    built: usize = 0,
};

/// 搜索框仍先处理键盘/重建映射再绘制，保证本帧输入立即参与过滤。
pub fn drawSearch(
    s: *State,
    c: *ui.Context,
    trailing: ?search_ui.Trailing,
    keyboard_owned: bool,
    busy: bool,
) void {
    if (!busy) {
        var action: search_ui.Outcome = .{};
        if (keyboard_owned) {
            _ = s.search.draw(c, trailing);
        } else {
            action = s.search.frame(c, s.samples, &s.selection, trailing);
        }
        if (action.filter_changed) {
            s.remove.clearFolder();
            row_ui.noteSelection(s);
        }
        if (action.activate) row_ui.activateCursor(s, c);
        if (action.toggle_play) c.changed = s.preview.togglePlay(row_ui.previewRow(s)) or c.changed;
        if (action.trailing_clicked) open_ui.toggle(&s.open_menu, c);
    } else {
        _ = s.search.draw(c, trailing);
    }
}

/// 表头与动作顺序保持不变：溢出 → 检查 →（仅库）移除 → 更新 → 设置。
pub fn drawHeader(
    s: *State,
    c: *ui.Context,
    layout_plan: *const responsive_layout.Plan,
    dirty: bool,
    allow_remove: bool,
    busy: bool,
) void {
    var status_buffer: [128]u8 = undefined;
    var update_buffer: [160]u8 = undefined;
    var update_action_buffer: [32]u8 = undefined;
    var ext_buffer: [128]u8 = undefined;
    const header_action = list_header.draw(c, .{
        .total = s.samples.len,
        .matched = s.search.matchCount(),
        .selected = s.selection.count(),
        .ext_filter = s.search.extSummary(&ext_buffer),
        .flash_left = s.flash_left,
        .flash_count = s.flash_count,
        .flash_remove = s.flash_remove,
        .can_remove = allow_remove and remove_ui.canRemove(s),
        .rows_with_image = s.reporter.printed_rows,
        .dirty = dirty,
        .import_status = s.import.status(&status_buffer),
        .import_failed = s.import.phase == .failed,
        .update_status = s.update.status(&update_buffer),
        .update_action_label = s.update.actionLabel(&update_action_buffer),
        .compact = layout_plan.profile == .compact_with_overflow,
        .overflow_open = s.overflow_open,
    });
    if (!busy) {
        if (header_action.overflow_clicked) {
            s.overflow_open = !s.overflow_open;
            c.changed = true;
        }
        if (header_action.check_clicked) s.update.begin();
        if (allow_remove and header_action.remove_clicked) remove_ui.removeCurrent(s, c);
        if (header_action.update_clicked and s.update.clickButton()) std.process.exit(0);
        if (header_action.settings_clicked) s.settings.openPanel(c);
    }
}

/// 列表只遍历过滤后的行映射；文件夹行、选择、拖出与滚动记录均沿用原实现。
pub fn drawRows(s: *State, c: *ui.Context, layout_plan: *const responsive_layout.Plan, busy: bool) Rows {
    const list_id = c.peekId(null);
    const scroll_target = browse_action.scrollTarget(s, c, list_id);
    var rows = ui.list(c, .{ .count = s.search.len(), .row_height = @floatFromInt(layout_plan.row.height), .scroll_to = scroll_target });
    var result: Rows = .{};
    while (rows.next()) |row| {
        if (s.search.folderAt(row)) |folder| {
            const it = library_tree_ui.draw(c, folder, remove_ui.folderSelected(s, folder.path));
            if (!busy and it.clicked) remove_ui.folderClicked(s, c, row);
            continue;
        }
        const index = s.search.sampleAt(row) orelse continue;
        const it = row_ui.drawRow(s, c, row, index, s.samples[index]);
        if (!busy) row_ui.rowInput(s, c, index, it);
        if (result.built == 0) result.first = row;
        result.last = row;
        result.built += 1;
    }
    rows.end();
    browse_action.rememberScroll(s, c, list_id);
    return result;
}

/// 空白处点击清选择，以及松手取消按压；调用方随后立即 `body.end()`。
pub fn handleBodyInput(s: *State, c: *ui.Context, body_it: anytype, busy: bool) void {
    if (!busy) {
        if (body_it.clicked) {
            s.selection.clear();
            s.remove.clearFolder();
            row_ui.cancelPress(s);
            row_ui.noteSelection(s);
            c.changed = true;
        }
        if (c.input.released or !c.input.down) row_ui.cancelPress(s);
    }
}

/// 列表后的固定顺序：预览 sync/draw → 缩略图账 → 设置顶层 → 视口/预取。
pub fn drawTail(
    s: *State,
    c: *ui.Context,
    layout_plan: *const responsive_layout.Plan,
    rows: Rows,
    busy: bool,
) void {
    const preview_sample = row_ui.previewRow(s);
    s.preview.sync(preview_sample, row_ui.previewDuration(s, preview_sample));
    s.preview.draw(c, layout_plan.preview_height);

    s.reporter.report(s.thumbs, s.rows_with_image);
    s.settings.draw(c, s.thumbs, &s.update, s.window);

    if (rows.built > 0) s.prefetch.noteWindow(rows.first, rows.last);
    if (!busy) s.maybePrefetch();
}
