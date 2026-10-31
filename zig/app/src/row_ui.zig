//! 列表**行**的绘制与交互：一行怎么画、点击/拖拽怎么解释、复制与选择表怎么维护。
//!
//! 从 `main.zig` 独立出来，是因为它和"一帧的树"（`frame`）、"启动装配"
//! （`app_boot.zig`）的改动理由完全不同：这里只关心指针落在哪一行、这次移动算不算
//! 拖拽、按下之后松手该清掉什么；`main.State` 的字段由 `main.zig` 定义，这里只读写。
//!
//! 两条容易踩的语义：
//!   * `row` 是**过滤结果里的行号**（显示用），`index` 是**样本下标**（选择/预览/
//!     拖拽用）。过滤把两者分开之后，行号会随搜索变化，样本下标不会；
//!   * Ctrl+点击在 nanoui 里不算 `clicked`（它被当成右键按下，见 `interact` 的
//!     `right_pressed`），所以 `rowInput` 单独认那一种组合。
//!
//! 拖拽仍然分两拍：帧里只把要拖的路径复制进 `Transport` 的快照并挂一个 0ms 定时器
//! （`armDrag`），真正阻塞到松手的 `DoDragDrop` 在定时器里跑（`main.State.dragTimer`）。
//! 用定时器而不是直接调用，是为了让"按下行"和"开始拖"之间还能重画一帧。

const std = @import("std");
const nanoui = @import("nanoui");
const core = @import("otto_core");
const duration_text = @import("duration_text.zig");
const filter = @import("filter.zig");
const row_thumb = @import("row_thumb.zig");
const sample_facts = @import("sample_facts.zig");
const transport_mod = @import("transport.zig");
const State = @import("main.zig").State;
const ui = nanoui.ui;

/// 按住行后移动多少点算拖拽。和资源管理器一样，小于阈值的手抖仍按点击处理。
const drag_threshold: f32 = 6;

/// Ctrl+C 成功后的提示闪几拍。一拍 = `main.tick_ms`，10 拍 = 1.5 秒。
const flash_ticks: u32 = 10;

/// 一行的绘制 + 交互。`row` 是过滤结果里的行号（显示用），`index` 是样本
/// 下标（选择/预览/拖拽用）。返回 pressable 的 Interaction 给 `rowInput`。
pub fn drawRow(s: *State, c: *ui.Context, row: usize, index: usize, sample: core.model.Sample) ui.Interaction {
    const selected = s.selection.isSelected(index);
    // 光标行：过滤后选择会被清空，但光标还要停在一个样本上（预览也跟着它）；选中底色更重。
    const is_cursor = s.selection.cursor == index;
    const style: ui.Style = .{
        .direction = .row,
        .width = .fill,
        .height = .{ .px = 44 },
        .padding = .xy(12, 0),
        .gap = 10,
        .align_items = .center,
        // 选中底色：主题强调色的低透明度版本；未选中交给 hover 动画。
        .background = if (selected) c.theme.accent.alpha(0.16) else if (is_cursor) c.theme.accent.alpha(0.07) else null,
    };
    // 选中行悬停时加深底色而不是换成 surface_hover——否则刚点过的行看起来像没选中。
    const hover_color = if (selected) c.theme.accent.alpha(0.26) else if (is_cursor) c.theme.accent.alpha(0.14) else c.theme.surface_hover;
    const it = ui.pressable(c, style, hover_color);
    defer ui.end(c);

    const drew_image = row_thumb.draw(c, s.thumbs, sample);
    if (drew_image) s.rows_with_image += 1;
    // 验收探针：这一帧这一行画的是真图还是占位。`--bench-scroll` 用它数
    // "滚动经过的行里，图标已就绪的比例"（见 `row_probe.zig`）。
    s.row_probe.add(index, drew_image);
    // 行号是**过滤结果里的位置**（第 1 行是当前列表的第一行），不是样本下标。
    ui.textf(c, .{ .size = 11, .color = if (is_cursor) c.theme.accent else null }, "{d:0>4}", .{row + 1});
    // 名字是唯一可截断的：后缀用次要色贴在名字后面，长名字先被省略号吃掉，后缀永远完整。
    ui.text(c, sample.file_name, .{ .size = 13, .truncate = .ellipsis });
    const ext = filter.trimExt(sample.file_ext);
    if (ext.len > 0) ui.textf(c, .{ .size = 11, .color = c.theme.muted }, ".{s}", .{ext});
    // 估算时长必须显示成 `≈40.9s`：这个数是从文件大小 / 比特率推出来的，不是
    // 容器声明的。`duration_trust.display` 对库里已有的时长只判 MP3 的估算位（读
    // 一次头部并缓存）；对旧库 `duration <= 0` 的条目先问 `resolve`——就地补出
    // 时长，不写回库文件。`display` 内部命中缓存时不碰磁盘。
    var duration_buffer: [32]u8 = undefined;
    const shown = s.duration_trust.display(sample);
    ui.textf(c, .{ .size = 11 }, "{s}", .{
        duration_text.format(shown.seconds, shown.estimated, &duration_buffer),
    });
    // 视频行再写一格分辨率（`640×360`）。没有画面尺寸时这段不出现：音频行的
    // 输出与没有本功能时逐字节一致。颜色用次要色，和时长区分开。
    if (shown.width) |width| {
        if (shown.height) |height| {
            ui.textf(c, .{ .size = 11, .color = c.theme.muted }, "{d}×{d}", .{ width, height });
        }
    }
    return it;
}

/// 预览区事实要显示的时长：与 `drawRow` 走同一条 `duration_trust.display`，
/// 保证一行两处（行文本 / 底部事实区）用的值完全一致。null = 没有选中。
pub fn previewDuration(s: *State, sample: ?*const core.model.Sample) sample_facts.Duration {
    const target = sample orelse return .{};
    const shown = s.duration_trust.display(target.*);
    return .{
        .seconds = shown.seconds,
        .estimated = shown.estimated,
        .width = shown.width,
        .height = shown.height,
    };
}

/// 点击语义、拖拽阈值。Ctrl+点击在 nanoui 里不算 clicked（它被当成右键按下，
/// 见 `interact` 的 `right_pressed`），所以这里单独认。
pub fn rowInput(s: *State, c: *ui.Context, index: usize, it: ui.Interaction) void {
    if (it.right_pressed and c.input.button == .left and c.input.ctrl) {
        s.selection.click(index, .{ .ctrl = true });
        cancelPress(s);
        noteSelection(s);
        c.changed = true;
        return;
    }
    if (it.clicked) {
        if (c.input.shift) {
            s.search.selectVisible(c, &s.selection, index);
        } else {
            s.selection.click(index, .{});
        }
        cancelPress(s);
        noteSelection(s);
        c.changed = true;
        return;
    }
    if (s.drag_ended or s.drag_armed or !it.pressed) return;
    if (s.press_row == null) {
        s.press_row = index;
        s.press_origin = c.input.mouse;
    }
    if (s.press_row != index) return;
    const dx = c.input.mouse.x - s.press_origin.x;
    const dy = c.input.mouse.y - s.press_origin.y;
    if (dx * dx + dy * dy <= drag_threshold * drag_threshold) return;
    armDrag(s, c, index);
}

/// 选择集合变了就打一行：无头验收（`--nanoui-script` + snapshot）也能从
/// stdout 读到选中数，不用只靠看图。
pub fn noteSelection(s: *State) void {
    std.debug.print("otto-lite: selected={d}/{d}\n", .{ s.selection.count(), s.samples.len });
}

/// 帧里：决定拖哪些行，把路径复制进 `Transport` 的快照，并挂一个 0ms 定时器。
/// 不在这里调 `drag.start`（它会阻塞到松手）。
pub fn armDrag(s: *State, c: *ui.Context, row: usize) void {
    s.drag_armed = true;
    const from_selection = s.selection.isSelected(row);
    const indices = s.selection.dragIndices(c.alloc(), row) catch {
        std.debug.print("otto-lite: 收集拖拽行号失败（OOM）\n", .{});
        return;
    };
    s.transport.stage(s.samples, indices, row, from_selection) catch |err| {
        std.debug.print("otto-lite: 拖拽快照失败（{s}）\n", .{@errorName(err)});
        return;
    };
    std.debug.print(
        "otto-lite: 待拖拽 row={d} files={d} from_selection={}\n",
        .{ row, s.transport.stagedFiles(), from_selection },
    );
    nanoui.App.after(0, s, State.dragTimer);
}

/// 清掉一次按压的状态（松手、拖拽结束、空白点击）。定时器若之后才跑，
/// 会看到 `plan == null` 直接返回——这就是"松手前没拖成"的取消路径。
pub fn cancelPress(s: *State) void {
    s.press_row = null;
    s.drag_armed = false;
    s.transport.cancel();
}

/// 拖拽刚结束时同步 nanoui 的鼠标状态。
///
/// 为什么需要：OLE 的拖放循环把 `WM_LBUTTONUP` 交给了它自己创建的隐藏源窗口
/// （`zig/ports/src/drag_win.zig` 的 `createSourceWindow` + `SetCapture`），
/// nanoui 的 surface 收不到，`input.down` 会停在 true。于是"松手后移动鼠标"
/// 会被误判成还按着。这里只在**这一帧不是由新按下触发**时清掉，若 `pressed`
/// 为真说明用户已经重新按下，保留这次真实输入。
pub fn resyncInput(s: *State, c: *ui.Context) void {
    if (!s.drag_ended) return;
    s.drag_ended = false;
    if (!c.input.pressed and c.input.down) {
        c.input.down = false;
        c.active = 0;
    }
    cancelPress(s);
}

/// Ctrl+C：复制选中集合；没有选中就用当前行；都没有就什么也不做。
pub fn copySelection(s: *State, c: *ui.Context) void {
    const indices = s.selection.copyIndices(c.alloc()) catch return;
    if (indices.len == 0) return;
    const count = transport_mod.copy(c.alloc(), s.samples, indices) catch |err| {
        std.debug.print(
            "otto-lite: 复制失败 {s}（hresult=0x{x:0>8}）\n",
            .{ @errorName(err), @as(u32, @bitCast(transport_mod.lastFailureCode())) },
        );
        return;
    };
    s.flash_left = flash_ticks;
    s.flash_count = count;
    c.changed = true;
    std.debug.print("otto-lite: 已复制 {d} 个素材到剪贴板\n", .{count});
}

/// 选择表长度跟着样本数走；缩短时越界的锚点/当前行作废。
pub fn syncSelection(s: *State) void {
    s.selection.resize(s.gpa, s.samples.len) catch {
        std.debug.print("otto-lite: 选择表扩容失败（OOM）\n", .{});
    };
}

/// 底部预览条要预览的那一行：最近点击的"当前行"；没有选中/越界就是 null。
/// 用 `cursor` 而不是"选中集合的第一个"，这样 Ctrl+点取消选中时预览条不闪。
pub fn previewRow(s: *const State) ?*const core.model.Sample {
    const row = s.selection.cursor orelse return null;
    if (row >= s.samples.len) return null;
    return &s.samples[row];
}

/// Enter：预览当前行。预览条已经跟着光标装载；如果它是音频，这里开始播放。
pub fn activateCursor(s: *State, c: *ui.Context) void {
    const sample = s.selection.cursor orelse return;
    if (sample >= s.samples.len) return;
    const playing = s.preview.playCurrent();
    c.changed = true;
    std.debug.print(
        "otto-lite: enter row={d} sample={d} name={s} playing={}\n",
        .{ (s.search.rowOfSample(sample) orelse 0) + 1, sample, s.samples[sample].file_name, playing },
    );
}
