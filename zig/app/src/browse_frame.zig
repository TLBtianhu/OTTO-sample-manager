//! 目录浏览模式的一帧装配：地址栏/工具栏/导航/banner/只读空状态在这里，
//! 不注册 drop target，也不调用打开导入或库移除。共享列表与预览仍走 frame_shared。

const nanoui = @import("nanoui");
const browse_action = @import("browse_action.zig");
const browse_mod = @import("browse.zig");
const browse_ui = @import("browse_ui.zig");
const frame_shared = @import("frame_shared.zig");
const responsive_layout = @import("responsive_layout.zig");
const State = @import("main.zig").State;
const ui = nanoui.ui;

pub fn view(
    s: *State,
    c: *ui.Context,
    session: *browse_mod.Session,
    layout_plan: *const responsive_layout.Plan,
    busy: bool,
) void {
    // 保持原顺序：全局共享输入之后、根节点与工具栏之前处理路径不可用重试。
    if (!busy) {
        const focused = if (s.window) |window| window.isFocused() else false;
        const gained_focus = focused and !s.window_focused;
        s.window_focused = focused;
        if (gained_focus or hasInteraction(c.input)) session.retryUnavailable();
    }

    const root_box = ui.div(c).sizeFull().column();
    defer root_box.end();

    const toolbar_action = browse_ui.drawToolbar(c, session.info(), &s.address, &s.drives);
    if (!busy) browse_action.handleToolbar(s, c, toolbar_action);

    if (!busy) browse_action.handleKeys(s, c);
    frame_shared.drawSearch(s, c, null, s.address.keyboardOwned(), busy);
    frame_shared.drawHeader(s, c, layout_plan, false, false, busy);

    const load_more_clicked = browse_ui.drawBanner(c, session.info(), s.shell.message()).load_more_clicked;
    if (!busy and load_more_clicked) {
        _ = session.loadMore() catch {};
        c.changed = true;
    }

    const body = ui.div(c).sizeFull();
    const body_it = body.interaction();
    const rows = frame_shared.drawRows(s, c, layout_plan, busy);

    if (!busy and s.samples.len > 0 and s.search.len() == 0) s.search.drawNoMatches(c);
    if (s.samples.len == 0) browse_ui.drawEmpty(c, session.info());

    frame_shared.handleBodyInput(s, c, body_it, busy);
    body.end();
    frame_shared.drawTail(s, c, layout_plan, rows, busy);
}

/// 这一帧有没有真实交互；只用于“路径不可用 → 下一次交互时重试”。
fn hasInteraction(input: anytype) bool {
    return input.pressed or input.released or input.secondary or
        input.scroll.x != 0 or input.scroll.y != 0 or
        input.key != null or input.chars.len != 0 or
        input.drop != null or input.a11y_press != 0 or
        input.zoom != 1 or input.pan.x != 0 or input.pan.y != 0;
}
