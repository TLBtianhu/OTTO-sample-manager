//! 库模式的一帧装配：drop/open/移除只在这里出现；列表、预览等共享部件由
//! frame_shared 提供。调用顺序与原 main.State.view 的库分支一致。

const nanoui = @import("nanoui");
const empty_state = @import("empty_state.zig");
const frame_shared = @import("frame_shared.zig");
const import_ui = @import("import_ui.zig");
const open_ui = @import("open_ui.zig");
const remove_ui = @import("remove_ui.zig");
const responsive_layout = @import("responsive_layout.zig");
const search_ui = @import("search_ui.zig");
const window_util = @import("window_util.zig");
const State = @import("main.zig").State;
const ui = nanoui.ui;

pub fn view(s: *State, c: *ui.Context, layout_plan: *const responsive_layout.Plan, busy: bool) void {
    const root_box = ui.div(c).sizeFull().column();
    defer root_box.end();
    s.drop.accept(c, root_box.index);

    const import_button: search_ui.Trailing = .{
        .label = import_ui.button_label,
        .width = import_ui.button_width,
        .disabled = s.import.busy(),
    };
    if (!busy) _ = remove_ui.handleKey(s, c);
    frame_shared.drawSearch(s, c, import_button, false, busy);
    if (!busy) open_ui.frame(c, &s.open_menu, &s.import, window_util.nativeHandle(s.window));

    frame_shared.drawHeader(s, c, layout_plan, s.session.live().dirty(), true, busy);

    const body = ui.div(c).sizeFull();
    const body_it = body.interaction();
    const rows = frame_shared.drawRows(s, c, layout_plan, busy);

    if (!busy and s.samples.len > 0 and s.search.len() == 0) s.search.drawNoMatches(c);
    const empty_clicked = empty_state.draw(c, s.samples.len, s.import.busy());
    if (!busy and empty_clicked) open_ui.toggle(&s.open_menu, c);

    frame_shared.handleBodyInput(s, c, body_it, busy);
    body.end();
    frame_shared.drawTail(s, c, layout_plan, rows, busy);
}
