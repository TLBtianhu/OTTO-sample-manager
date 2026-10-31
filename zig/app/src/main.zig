//! OTTO Lite：用 nanoui 的 Windows CPU 后端把 `zig/core` 的资料库画成 380×700 列表，
//! 用 `zig/ports` 的文件监听让列表跟着磁盘变、用系统缩略图给每行左侧配一张小图。
//!
//!   otto-lite [library.json] [--watch <dir>] [--select=0,1]
//!   otto-lite --version | --convert <in> <out> | --library-info <file>
//!   otto-lite --demo <dir> | --demo-rescan <dir> | --demo-thumbs <dir> | --demo-transport
//!   otto-lite --preview <file> | --play-test <file> | --copy-now <file>
//!   otto-lite --import <folder> [--library <file>] --save <out.otto>
//!   otto-lite --check-update <url>     （无窗口更新检查，见 `update_ui.zig`）
//!   每条自检的用途见 `commands.zig`；都**不开窗**、不抢焦点。表头右上角的
//!   「检查更新」默认不联网：只有点击才起线程（`update_ui.zig`）。
//!
//! 列表下方是预览区（`preview_panel.zig`）：选中行变化时把样本交给注册表，按
//! `Outcome` 的分支画图/文字/占位；本文件不认识任何媒体类型（ROADMAP M1）。
//!
//! 没有位置参数时库路径由运行形态决定（`mode.zig`）：dev 用 `fixtures/library.json`，
//! 便携版用 `<exe 目录>\data\library.json`，安装版用 `%APPDATA%\OTTO\library.json`。
//!
//! 搜索（`search_ui.zig`）：Ctrl+F 聚焦、Esc 清空；输入即过滤（文件名子串、ASCII
//! 大小写不敏感），过滤变化时清空选择、光标尽量停在原样本。↑↓/Home/End/Enter 在
//! `search_ui.zig`；拖出与 Ctrl+C 见 `transport.zig`（DoDragDrop 绝不进 `view`）。

const std = @import("std");
const nanoui = @import("nanoui");
const core = @import("otto_core");
const bench_mod = @import("bench.zig");
const bench_scroll = @import("bench_scroll.zig");
const commands = @import("commands.zig");
const import_ui = @import("import_ui.zig");
const library_io = @import("library_io.zig");
const list_header = @import("list_header.zig");
const live_mod = @import("live.zig");
const mem_probe = @import("mem_probe.zig");
const mode_mod = @import("mode.zig");
const options_mod = @import("options.zig");
const preview_panel = @import("preview_panel.zig");
const preview_providers = @import("providers/root.zig");
const row_thumb = @import("row_thumb.zig");
const search_ui = @import("search_ui.zig");
const selection_mod = @import("selection.zig");
const settings_store = @import("settings_store.zig");
const settings_ui = @import("settings_ui.zig");
const thumbs_mod = @import("thumbs.zig");
const thumbs_report = @import("thumbs_report.zig");
const trace = @import("trace.zig");
const transport_mod = @import("transport.zig");
const update_ui = @import("update_ui.zig");
const version_mod = @import("version.zig");
const window_util = @import("window_util.zig");
const ui = nanoui.ui;

/// 轮询间隔：150ms 是「人眼觉得即时」与「闲时几乎不耗 CPU」的折中。监听线程自己
/// 阻塞在 ReadDirectoryChangesW 上，这里只是把队列搬进 Index。
const tick_ms: u64 = 150;

// 每一行左侧缩略图的边长在 `row_thumb.zig`（32 点）；向系统请求 64px（2x 屏 1:1）。

/// 按住行后移动多少点算拖拽。和资源管理器一样，小于阈值的手抖仍按点击处理。
const drag_threshold: f32 = 6;

/// Ctrl+C 成功后的提示闪几拍。一拍 = `tick_ms`，10 拍 = 1.5 秒。
const flash_ticks: u32 = 10;

const State = struct {
    /// 选择表与拖拽快照的分配器（`init.gpa`，长生命周期；不是帧 arena）。
    gpa: std.mem.Allocator,
    live: *live_mod.Live,
    /// 当前视图；每次 poll 之后都要重新取——`Index.apply` 的扩容会让数组搬家。
    samples: []const core.model.Sample,
    thumbs: *thumbs_mod.Thumbs,
    /// 底部预览条：注册表 + 工作线程 + 五分支渲染（见 `preview_panel.zig`）。
    preview: *preview_panel.Panel,
    /// 选择模型（下标 + 锚点 + 当前行）；帧里只改它，不碰磁盘。
    selection: selection_mod.Selection = .{},
    /// 搜索框 + 过滤行映射 + 键盘导航（见 `search_ui.zig`）。
    search: search_ui.Search,
    /// 「导入文件夹」：选择框 → 工作线程 `importRun` → 重载（见 `import_ui.zig`）。
    import: import_ui.Import,
    /// 「检查更新」：入口 → 工作线程取 feed → 一行提示（`update_ui.zig`）；默认不联网。
    update: update_ui.Update,
    /// 设置面板（置顶 / 不透明度 / 更新源 / 缓存预算，见 `settings_ui.zig`）。
    settings: settings_ui.Panel,
    /// 拖拽快照与执行（把 `DoDragDrop` 挡在帧外）。
    transport: transport_mod.Transport,
    window: ?*nanoui.Window = null,
    /// 上一次 poll 之后看到的 ready 计数，用来判断「后台取到新图了」。
    last_ready: u32 = 0,
    /// 本帧真正画出缩略图的可见行数（tick / 打印用）。
    rows_with_image: u32 = 0,
    /// 缩略图的排队/取图情况，数字变了才打印一行（见 `thumbs_report.zig`）。
    reporter: thumbs_report.Reporter = .{},
    /// 按下时的行与位置（只记一次；松手/离开后清掉）。
    press_row: ?usize = null,
    press_origin: ui.Point = .{},
    /// 已经越过阈值、定时器已挂上：同一次按压里不许再排第二次。
    drag_armed: bool = false,
    /// 一次 OLE 拖拽刚结束：nanoui 的鼠标 down/active 可能还停在按下状态
    /// （详见 `resyncInput`），下一帧不是新按下时清掉。
    drag_ended: bool = false,
    /// 表头提示还剩几拍（>0 = 正在闪），以及刚复制了几个。
    flash_left: u32 = 0,
    flash_count: usize = 0,

    fn view(s: *State, c: *ui.Context) void {
        // 上一帧 pin 住的条目到这里才放掉：view 之后还有 paint，paint 期间像素要有效。
        s.thumbs.beginFrame();
        s.rows_with_image = 0;
        // 拖放循环里窗口仍可能收到 WM_PAINT：这一帧只按现有状态重画，不处理输入、
        // 不调用任何口岸。`Transport.execute` 返回后 `busy` 才落回 false。
        const busy = s.transport.busy;
        if (!busy) {
            s.syncSelection();
            s.resyncInput(c);
            // Ctrl+C：在构建树之前处理，`c.changed` 会让这一帧重建出表头提示。
            if (c.shortcut(.{ .key = 'c', .ctrl = true })) s.copySelection(c);
        }

        ui.column(c, .{ .width = .fill, .height = .fill });
        defer ui.end(c);

        // 搜索框在列表上方：先处理键盘/重建映射再画它，本帧输入的字符在同一帧
        // 就参与过滤。拖拽循环里只按现有状态重画（那几帧不处理输入）。
        // 「导入文件夹」按钮和搜索框同一行、宽度固定（见 `search_ui.Trailing`）。
        const import_button: search_ui.Trailing = .{
            .label = import_ui.button_label,
            .width = import_ui.button_width,
            .disabled = s.import.busy(),
        };
        if (!busy) {
            const action = s.search.frame(c, s.samples, &s.selection, import_button);
            if (action.filter_changed) s.noteSelection();
            if (action.activate) s.activateCursor(c);
            // 模态选择框在 UI 线程上跑；取消不进状态机（见 `import_ui.begin`）。
            if (action.trailing_clicked) s.import.begin(window_util.nativeHandle(s.window));
        } else {
            _ = s.search.draw(c, import_button);
        }

        var status_buffer: [128]u8 = undefined;
        var update_buffer: [160]u8 = undefined;
        var update_action_buffer: [32]u8 = undefined;
        const header_action = list_header.draw(c, .{
            .total = s.samples.len,
            .matched = s.search.len(),
            .selected = s.selection.count(),
            .flash_left = s.flash_left,
            .flash_count = s.flash_count,
            .rows_with_image = s.reporter.printed_rows,
            .dirty = s.live.dirty(),
            .import_status = s.import.status(&status_buffer),
            .import_failed = s.import.phase == .failed,
            .update_status = s.update.status(&update_buffer),
            .update_action_label = s.update.actionLabel(&update_action_buffer),
        });
        if (!busy) {
            if (header_action.check_clicked) s.update.begin();
            if (header_action.update_clicked and s.update.clickButton()) std.process.exit(0);
            if (header_action.settings_clicked) s.settings.openPanel(c);
        }
        // 列表容器：在空白处按下再松开 = 清空选择。行是它的后代：点行时
        // 上一帧的 hot 落在行上，容器的 interact 不会 clicked（见 nanoui
        // `context_hooks.interact` 的 top/active 规则）。
        const body = ui.div(c).sizeFull();
        const body_it = body.interaction();

        // 列表只遍历行映射：第 row 行 → 第 index 个样本。选择/预览/拖拽仍然
        // 只认样本下标，过滤不会造出第二套身份。
        var rows = ui.list(c, .{ .count = s.search.len(), .row_height = 44 });
        while (rows.next()) |row| {
            const index = s.search.sampleAt(row) orelse continue;
            const it = s.drawRow(c, row, index, s.samples[index]);
            if (!busy) s.rowInput(c, index, it);
        }
        rows.end();

        if (!busy) {
            if (body_it.clicked) {
                s.selection.clear();
                s.cancelPress();
                s.noteSelection();
                c.changed = true;
            }
            // 松手（或按钮已经不在了）就放弃这次按压：定时器若还没跑，会看到空计划。
            if (c.input.released or !c.input.down) s.cancelPress();
        }
        // 列表到此为止：预览条必须是它的兄弟，不能变成列表的子节点。
        body.end();

        // 预览条：只在选中行变化时提交请求（`sync` 自己判重）；工作线程读完由
        // `tick` 接手，这里只按 Outcome 的五个分支画。
        s.preview.sync(s.previewRow());
        s.preview.draw(c);

        s.reporter.report(s.thumbs, s.rows_with_image);
        // 设置面板是最后一层：遮罩 + 卡片覆盖列表，点击优先级由树序保证。
        s.settings.draw(c, s.thumbs, &s.update, window_util.nativeHandle(s.window));
    }

    /// 一行的绘制 + 交互。`row` 是过滤结果里的行号（显示用），`index` 是样本
    /// 下标（选择/预览/拖拽用）。返回 pressable 的 Interaction 给 `rowInput`。
    fn drawRow(s: *State, c: *ui.Context, row: usize, index: usize, sample: core.model.Sample) ui.Interaction {
        const selected = s.selection.isSelected(index);
        // 光标行：过滤后选择会被清空，但光标还要停在一个样本上（预览也跟着它）。
        // 选中底色更重；只有光标时给一层很浅的底色 + 强调色行号。
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
        // 选中行悬停时把底色加深而不是换成灰色的 surface_hover——否则鼠标停在
        // 刚点过的那一行上，选中底色会被 hover 盖掉，看起来像没选中。
        const hover_color = if (selected) c.theme.accent.alpha(0.26) else if (is_cursor) c.theme.accent.alpha(0.14) else c.theme.surface_hover;
        const it = ui.pressable(c, style, hover_color);
        defer ui.end(c);

        if (row_thumb.draw(c, s.thumbs, sample)) s.rows_with_image += 1;
        // 行号是**过滤结果里的位置**（第 1 行是当前列表的第一行），不是样本下标。
        ui.textf(c, .{ .size = 11, .color = if (is_cursor) c.theme.accent else null }, "{d:0>4}", .{row + 1});
        ui.text(c, sample.file_name, .{ .size = 13 });
        ui.textf(c, .{ .size = 11 }, "{d:.2}s", .{sample.duration});
        return it;
    }

    /// 点击语义、拖拽阈值。Ctrl+点击在 nanoui 里不算 clicked（它被当成右键按下，
    /// 见 `interact` 的 `right_pressed`），所以这里单独认。
    fn rowInput(s: *State, c: *ui.Context, index: usize, it: ui.Interaction) void {
        if (it.right_pressed and c.input.button == .left and c.input.ctrl) {
            s.selection.click(index, .{ .ctrl = true });
            s.cancelPress();
            s.noteSelection();
            c.changed = true;
            return;
        }
        if (it.clicked) {
            if (c.input.shift) {
                s.search.selectVisible(c, &s.selection, index);
            } else {
                s.selection.click(index, .{});
            }
            s.cancelPress();
            s.noteSelection();
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
        s.armDrag(c, index);
    }

    /// 选择集合变了就打一行：无头验收（`--nanoui-script` + snapshot）也能从
    /// stdout 读到选中数，不用只靠看图。
    fn noteSelection(s: *State) void {
        std.debug.print("otto-lite: selected={d}/{d}\n", .{ s.selection.count(), s.samples.len });
    }

    /// 帧里：决定拖哪些行，把路径复制进 `Transport` 的快照，并挂一个 0ms 定时器。
    /// 不在这里调 `drag.start`（它会阻塞到松手）。
    fn armDrag(s: *State, c: *ui.Context, row: usize) void {
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
    fn cancelPress(s: *State) void {
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
    fn resyncInput(s: *State, c: *ui.Context) void {
        if (!s.drag_ended) return;
        s.drag_ended = false;
        if (!c.input.pressed and c.input.down) {
            c.input.down = false;
            c.active = 0;
        }
        s.cancelPress();
    }

    /// Ctrl+C：复制选中集合；没有选中就用当前行；都没有就什么也不做。
    fn copySelection(s: *State, c: *ui.Context) void {
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
    fn syncSelection(s: *State) void {
        s.selection.resize(s.gpa, s.samples.len) catch {
            std.debug.print("otto-lite: 选择表扩容失败（OOM）\n", .{});
        };
    }

    /// 底部预览条要预览的那一行：最近点击的"当前行"；没有选中/越界就是 null。
    /// 用 `cursor` 而不是"选中集合的第一个"，这样 Ctrl+点取消选中时预览条不闪。
    fn previewRow(s: *const State) ?*const core.model.Sample {
        const row = s.selection.cursor orelse return null;
        if (row >= s.samples.len) return null;
        return &s.samples[row];
    }

    /// Enter：预览当前行。预览条已经跟着光标装载；如果它是音频，这里开始播放。
    fn activateCursor(s: *State, c: *ui.Context) void {
        const sample = s.selection.cursor orelse return;
        if (sample >= s.samples.len) return;
        const playing = s.preview.playCurrent();
        c.changed = true;
        std.debug.print(
            "otto-lite: enter row={d} sample={d} name={s} playing={}\n",
            .{ (s.search.rowOfSample(sample) orelse 0) + 1, sample, s.samples[sample].file_name, playing },
        );
    }

    /// 自续期定时器回调：poll 一次，有实际变更就重画；然后重新挂 150ms。
    /// 也负责让 Ctrl+C 的表头提示在 1.5 秒后恢复。
    fn tick(ctx: ?*anyopaque) callconv(.c) void {
        const s: *State = @ptrCast(@alignCast(ctx.?));
        // 拖放循环里不许再碰 UI（连轮询也不做）：等它返回后下一次 tick 再补。
        if (!s.transport.busy) {
            s.refresh();
            // 导入是异步的：结果回来先重载（换 Live/库指针），再刷新本帧的状态。
            const import_event = s.import.poll();
            if (import_event == .reloaded) s.afterReload();
            if (import_event != .none) if (s.window) |window| window.redraw();
            if (s.import.tick()) if (s.window) |window| window.redraw();
            // 更新检查也是异步的：结果回来就换表头那一行并重画。
            if (s.update.poll()) if (s.window) |window| window.redraw();
            // 预览是异步的：工作线程交回结果就换画面并打一行账。`poll` 只在
            // UI 线程调；`sync` 在 view 里提交，这里不重复提交。
            if (s.preview.poll()) {
                var preview_line: [96]u8 = undefined;
                std.debug.print("otto-lite: preview {s}\n", .{s.preview.describe(&preview_line)});
                if (s.window) |window| window.redraw();
            }
            // 音频播放期间每拍重画一次，位置文字才会走；自然播完时
            // `playbackChanged` 再补一帧，把按钮从"停止"换回"播放"。
            if (s.preview.isPlaying() or s.preview.playbackChanged()) {
                if (s.window) |window| window.redraw();
            }
            if (s.flash_left > 0) {
                s.flash_left -= 1;
                if (s.flash_left == 0) if (s.window) |window| window.redraw();
            }
        }
        nanoui.App.after(tick_ms, ctx, tick);
    }

    /// 导入成功后重载：内存列表换成刚保存的那份库（理由见 `import_ui.zig` 文件头）。
    /// 选择清空、过滤重建、预览重提交——都走和启动时同一条初始化路径。
    fn afterReload(s: *State) void {
        s.live = s.import.live();
        s.samples = s.live.samples();
        s.thumbs.clearFailures();
        s.search.markStale();
        s.selection.clear();
        s.selection.resize(s.gpa, s.samples.len) catch {};
        s.preview.sync(null);
        if (s.window) |window| {
            window_util.setTitle(window, s.samples.len);
            window.redraw();
        }
    }

    fn refresh(s: *State) void {
        const report_events = s.live.poll() catch |err| {
            std.debug.print("otto-lite: poll 失败：{s}\n", .{@errorName(err)});
            return;
        };
        // 即使四个计数都是零，`apply` 的扩容也可能让切片搬家，所以无条件重取。
        s.samples = s.live.samples();

        const changed = report_events.added != 0 or report_events.removed != 0 or
            report_events.renamed != 0 or report_events.modified != 0 or
            report_events.overflowed or report_events.rescanned;
        // 磁盘变了：之前「文件没了 / Shell 失败」的结论值得重试一次；过滤映射
        // 也要重建（改名不改样本数，光看数量会漏）。
        if (changed) {
            s.thumbs.clearFailures();
            s.search.markStale();
        }

        // 后台取到新图也要重画：ready 计数是本层唯一的变化信号。
        const ready = s.thumbs.readyCount();
        const ready_changed = ready != s.last_ready;
        if (ready_changed) s.last_ready = ready;

        if (!changed and !ready_changed) return;

        const window = s.window orelse return;
        if (changed) window_util.setTitle(window, s.samples.len);
        window.redraw();
    }

    /// 帧外（定时器）执行一次待拖拽。进入前把计划从 `Transport` 摘下来。
    fn dragTimer(ctx: ?*anyopaque) callconv(.c) void {
        const s: *State = @ptrCast(@alignCast(ctx.?));
        if (s.transport.busy) return;
        const result = s.transport.execute(window_util.nativeHandle(s.window));
        switch (result.outcome) {
            .none => return,
            .no_window => std.debug.print(
                "otto-lite: 拖拽跳过（无窗口句柄）files={d}\n",
                .{result.files},
            ),
            .dropped => {
                s.drag_ended = true;
                std.debug.print(
                    "otto-lite: 拖拽完成 files={d} effect=0x{x}\n",
                    .{ result.files, result.effect },
                );
            },
            .cancelled => {
                s.drag_ended = true;
                std.debug.print("otto-lite: 拖拽取消（不算错误）files={d}\n", .{result.files});
            },
            .failed => {
                s.drag_ended = true;
                std.debug.print(
                    "otto-lite: 拖拽失败 files={d} hresult=0x{x:0>8}\n",
                    .{ result.files, @as(u32, @bitCast(result.hresult)) },
                );
            },
        }
        s.cancelPress();
        if (s.window) |window| window.redraw();
    }
};

pub fn main(init: std.process.Init) !void {
    // `--bench` 的子进程用这个时间戳量"main 入口 → 第一帧建完"；普通启动只多一次
    // 单调时钟读取。
    const started = std.Io.Clock.Timestamp.now(init.io, .awake);
    trace.begin(init);
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    const options = options_mod.parse(args) catch {
        options_mod.printUsage();
        return error.InvalidArguments;
    };

    // 所有不开窗的模式（--version / 自检 / 转换 / 查库）都在这里返回；
    // null 才继续走 UI。顺序与实现见 `commands.zig`。
    if (try commands.run(init, allocator, options)) |code| {
        if (code != 0) std.process.exit(code);
        return;
    }
    // `--mem-probe`：真实窗口形态的内存分解（隐藏窗口，见 `mem_probe.zig`）。
    // 没开时 `begin` / `mark` 都只是一次 bool 判断，不读内存。
    var probe = mem_probe.Probe.begin(init, options);

    // 位置参数优先；没有就按运行形态给默认库（见文件头）。
    // 格式按文件头判断：`.otto` 走 OTTOLIB，其余走 electron-store JSON。
    const library_path = options.library_path orelse try mode_mod.defaultLibraryPath(allocator, init.io);
    var library = try init.gpa.create(core.store.Library);
    library.* = library_io.load(init, init.gpa, library_path) catch |err| {
        // 损坏的库（BadMagic / UnknownVersion / Truncated / ChecksumMismatch）在
        // 这里给一行具名错误，而不是把 Zig 调用栈甩给用户。
        std.debug.print("otto-lite: 打开库失败 file={s} error={s}\n", .{ library_path, @errorName(err) });
        std.process.exit(1);
    };
    trace.mark("setup.library");
    probe.mark("library", .{});
    defer {
        library.deinit();
        init.gpa.destroy(library);
    }
    const root = try mode_mod.watchRoot(allocator, init.io, options.watch_dir, library_path);
    // 监听打不开（目录被删 / 没权限）就是明确的启动错误：不静默退化成「列表不更新」。
    var live = try init.gpa.create(live_mod.Live);
    errdefer init.gpa.destroy(live);
    live.* = try live_mod.Live.init(init.gpa, init.io, library, root);
    trace.mark("setup.live");
    defer {
        live.deinit();
        init.gpa.destroy(live);
    }
    // 设置：dev 写 exe 旁边的 `.otto-settings.json`（不碰用户目录），
    // portable / installed 写数据目录；读不到 / 坏了都用默认值（见 settings_store）。
    const settings_path = settings_store.resolvePath(allocator, init.io) catch null;
    const settings = settings_store.load(init.gpa, init.io, settings_path);
    // 取图层用自己的分配器（`init.gpa` 线程安全，Debug 下还查泄漏）；L3 目录按
    // 运行形态决定：dev 没有 dataDir → null（不写盘）。预算来自设置；显式
    // `--cache-budget-kib` 仍优先于设置里的 L3 值。
    const thumbs = try thumbs_mod.Thumbs.init(init.gpa, init.io, .{ .isolation = !options.no_isolation, .disk_cache_dir = mode_mod.thumbsCacheDir(allocator, init.io) catch null, .disk_cache_budget = if (options.cache_budget_set) options.disk_cache_budget_bytes else settings.l3BudgetBytes(), .budget_bytes = settings.l2BudgetBytes() });
    defer thumbs.deinit();
    // 预览条也用 `init.gpa`：工作线程要用它分配位图/文本。注册表只有一张
    // （`providers/root.zig`），`--preview` 自检与 UI 看到的是同一份顺序。
    const panel = try preview_panel.Panel.init(init.gpa, init.io, &preview_providers.registry, .{});
    defer panel.deinit();
    // 字体索引只写进数据目录形态（portable/installed）；dev 传 null → 每次重扫。
    // 上屏：默认 GDI（`--mem-probe` 实测比 D3D11 翻转交换链少 29 MiB 常驻、
    // present 便宜一个数量级）；`--d3d` 回到旧的 D3D 路径（要 vsync 时用）。
    const app = try nanoui.App.create(init, .{ .name = "OTTO Lite", .fonts_dir = mode_mod.systemFontDir(), .font_cache = mode_mod.fontCachePath(allocator, init.io) catch null, .gdi = !options.d3d });
    trace.mark("setup.app");
    // 验收探针：快照默认不开真实窗口，但置顶断言需要真 HWND；仍然 hidden。
    if (options.settings_probe) {
        app.gui = true;
        app.flags.hidden = true;
    }
    // 探针窗口必须隐藏：不弹窗、不抢焦点、不进任务栏。
    if (probe.active) app.flags.hidden = true;
    probe.mark("app", .{});
    defer app.destroy();
    var state = State{
        .gpa = init.gpa,
        .live = live,
        .samples = live.samples(),
        .thumbs = thumbs,
        .preview = panel,
        .search = search_ui.Search.init(init.gpa),
        .import = try import_ui.Import.init(init.gpa, init.io, &library, &live, library_path),
        .update = try update_ui.Update.initForProcess(init.gpa, init.io, options.update_url orelse settings.update_url, options.no_exec, options.update_current),
        .settings = try settings_ui.Panel.init(init.gpa, init.io, settings, settings_path, .{ .d3d = options.d3d }),
        .transport = transport_mod.Transport.init(init.gpa),
    };
    trace.mark("setup.state");
    defer state.import.deinit();
    defer state.update.deinit();
    defer state.settings.deinit();
    defer state.selection.deinit(init.gpa);
    defer state.search.deinit();
    defer state.transport.deinit();
    state.selection.resize(init.gpa, state.samples.len) catch {};
    if (options.select) |text| selection_mod.seedSelection(&state.selection, state.samples.len, text);
    var title_buffer: [96]u8 = undefined;
    const title = version_mod.windowTitle(&title_buffer, state.samples.len);
    // `--bench-first-frame` 是离屏探针：不建真实 HWND，也不 show。
    if (options.bench_first_frame) app.gui = false;
    // `--bench-scroll`：真实窗口、屏外、从不激活；窗口由基准自己建，进程交给它。
    if (options.bench_scroll != null) try bench_scroll.runCli(init, app, thumbs, options, .init(&state, State.view), title);
    state.window = try app.newWindow(.{
        .title = title,
        .width = 380,
        .height = 700,
        // 设置验收的脚本要真 HWND，但仍然绝不激活。
        .no_activate = options.settings_probe,
        .content = .{ .view = .init(&state, State.view) },
    });
    trace.mark("setup.window");
    probe.mark("window", .{ .window = state.window, .thumbs = thumbs });
    // 窗口状态启动时应用一次：置顶（true 才碰 Win32）+ 不透明度（重启后恢复）。
    state.settings.applyWindowState(window_util.nativeHandle(state.window));
    if (options.bench_first_frame) {
        try bench_mod.firstFrame(init, app, started);
        // 一次性探针：打印完就退出，不 join 缩略图/预览工作线程。它们可能正在
        // Shell 里做冷启动的第一次取图；收尾时间不能算进"首帧墙钟"，否则量到的
        // 是"首帧 + 关窗"。
        std.process.exit(0);
    }
    // snapshot 模式没有消息循环，定时器不会跑到；离屏出图只画初始视图。
    // 想看到后台取到的图，加 `--nanoui-wait=<秒>`：事件循环会跑、tick 会重画。
    nanoui.App.after(tick_ms, &state, State.tick);
    // 探针：D3D、8/50/100 张缩略图、空闲 10 秒，打完表就退出（不 join 工作线程）。
    if (probe.active) probe.finish(state.window.?, thumbs);
    try app.run();
}
