//! OTTO Lite：用 nanoui 的 Windows CPU 后端把 `zig/core` 的资料库画成 380×700 列表，
//! 用 `zig/ports` 的文件监听让列表跟着磁盘变、用系统缩略图给每行左侧配一张小图，
//! 用拖拽口岸把选中的素材交给别的程序。
//!
//!   otto-lite [library.json] [--watch <dir>] [--select=0,1]
//!   otto-lite --version              打印版本与运行形态（dev/portable/installed）
//!   otto-lite --demo <dir> / --demo-rescan <dir>  监听与溢出重扫自检（不开窗）
//!   otto-lite --demo-thumbs <dir>    缩略图取图层自检（不开窗）
//!   otto-lite --preview <file>       预览自检（不开窗，打印事实 + kind/outcome/摘要）
//!   otto-lite --play-test <file>     音频试听自检（解码 + 播 300ms + 断言位置前进）
//!   otto-lite --demo-transport       选择/路径/拖拽快照自检（不开窗、不碰剪贴板）
//!   otto-lite --copy-now <file>      显式把 1 个文件写进剪贴板（CF_HDROP）
//!   otto-lite --convert <in> <out>   旧 JSON → OTTOLIB v1（原子写，打印条数/字节数）
//!   otto-lite --library-info <file>  按 magic 打印 format=json|otto 与条数/字节数
//!   otto-lite --import <folder> [--library <file>] --save <out.otto>
//!                                    扫描 + L1 头部解析 + 去重 + 合并 + 原子写
//!
//! 列表下方是一条固定高度的预览区（`preview_panel.zig`）：选中行变化时把样本交给
//! 注册表，按 `Outcome` 的五个分支画图/文字/占位/原因；名称/大小/时长/路径是样本
//! 自带的事实，无条件显示在预览区下方。本文件不认识任何媒体类型，也不判断扩展名
//! ——换一个 provider 不需要改这里（ROADMAP M1 的验收）。
//!
//! 没有位置参数时库路径由运行形态决定（`mode.zig`）：dev 用 `fixtures/library.json`，
//! 便携版用 `<exe 目录>\data\library.json`，安装版用 `%APPDATA%\OTTO\library.json`。
//!
//! 选择：点一行 = 只选它；Ctrl+点击 = 切换；Shift+点击 = 从锚点连选；
//! 空白处点击 = 清空。选中行有可见底色，表头是「N 个素材 · M 命中 · K 选中」。
//!
//! 搜索（M2 第一半，`search_ui.zig`）：列表上方是搜索框（占位「搜索素材…」），
//! Ctrl+F 聚焦、Esc 清空并失焦；输入即过滤，规则只有一条——文件名子串、ASCII
//! 大小写不敏感（`core.query.matchingIndices`），空查询 = 全部。列表只遍历一份
//! 「行 → 样本下标」的映射（`filter.zig`），选择/预览/拖拽仍然只认样本下标。
//! 过滤条件变化时**清空选择**：行号会整体变，保留会指错文件（v1 的诚实做法）；
//! 光标尽量停在原样本的新行，原样本不在了才回落到第 0 行。↑↓（越界不环绕）、
//! Home/End、Enter（音频行触发播放）、Esc（先清搜索再清选择）都在 `search_ui.zig`。
//!
//! 拖出：在行上按住移动超过 6 px 就进入"待拖拽"（`State.rowInput`）。帧里只做
//! **快照**（`Transport.stage` 把路径复制出帧的生命周期），帧结束后由
//! `nanoui.App.after(0, …)` 的定时器调 `Transport.execute`——`DoDragDrop` 会阻塞
//! 到用户松手，绝不能在 `view` 里调（见 `transport.zig` 的文件头）。
//! 拖哪些：该行在选中集合里 → 整个集合；否则只有这一行。
//!
//! Ctrl+C：选中集合（没有选中就当前行）写剪贴板，表头闪 1.5 秒提示。
//! 取消（Esc / 无效目标）只清状态，不算错误；OLE 失败只打日志，不弹窗。

const std = @import("std");
const nanoui = @import("nanoui");
const core = @import("otto_core");
const commands = @import("commands.zig");
const import_ui = @import("import_ui.zig");
const library_io = @import("library_io.zig");
const list_header = @import("list_header.zig");
const live_mod = @import("live.zig");
const mode_mod = @import("mode.zig");
const options_mod = @import("options.zig");
const preview_panel = @import("preview_panel.zig");
const preview_providers = @import("providers/root.zig");
const row_thumb = @import("row_thumb.zig");
const search_ui = @import("search_ui.zig");
const selection_mod = @import("selection.zig");
const thumbs_mod = @import("thumbs.zig");
const thumbs_report = @import("thumbs_report.zig");
const transport_mod = @import("transport.zig");
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
        list_header.draw(c, .{
            .total = s.samples.len,
            .matched = s.search.len(),
            .selected = s.selection.count(),
            .flash_left = s.flash_left,
            .flash_count = s.flash_count,
            .rows_with_image = s.reporter.printed_rows,
            .dirty = s.live.dirty(),
            .import_status = s.import.status(&status_buffer),
            .import_failed = s.import.phase == .failed,
        });

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

    /// `--select=0,1`：截图/自检用的预置选择，不是给最终用户的入口。
    fn seedSelection(s: *State, text: []const u8) void {
        var buffer: [64]usize = undefined;
        const count = selection_mod.parseIndexList(text, &buffer) catch |err| {
            std.debug.print("otto-lite: --select 解析失败（{s}）：{s}\n", .{ @errorName(err), text });
            return;
        };
        s.selection.clear();
        for (buffer[0..count]) |index| {
            if (index >= s.samples.len) {
                std.debug.print("otto-lite: --select 忽略越界行 {d}（共 {d} 行）\n", .{ index, s.samples.len });
                continue;
            }
            s.selection.add(index);
            s.selection.anchor = index;
            s.selection.cursor = index;
        }
        std.debug.print(
            "otto-lite: --select 预置 {d} 行（selected={d}）\n",
            .{ count, s.selection.count() },
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
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    const options = options_mod.parse(args) catch {
        std.debug.print(
            "用法：otto-lite [library.json|library.otto] [--watch <dir>] [--select=0,1]\n" ++
                "      otto-lite --version\n" ++
                "      otto-lite [library.json|library.otto] --filter=<text>\n" ++
                "      otto-lite --demo <dir> | --demo-rescan <dir> | --demo-thumbs <dir> | --demo-transport\n" ++
                "      otto-lite --thumb-bench <dir> [--no-isolation] [--cache-budget-kib=<n>]\n" ++
                "      otto-lite --preview <file> | --play-test <file>\n" ++
                "      otto-lite --copy-now <file>\n" ++
                "      otto-lite --convert <in.json> <out.otto>\n" ++
                "      otto-lite --library-info <file>\n" ++
                "      otto-lite --import <folder> [--library <file>] --save <out.otto>\n" ++
                "      otto-lite --import-into <folder> [--save <file>]\n",
            .{},
        );
        return error.InvalidArguments;
    };

    // 所有不开窗的模式（--version / 自检 / 转换 / 查库）都在这里返回；
    // null 才继续走 UI。顺序与实现见 `commands.zig`。
    if (try commands.run(init, allocator, options)) |code| {
        if (code != 0) std.process.exit(code);
        return;
    }

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
    defer {
        library.deinit();
        init.gpa.destroy(library);
    }
    const root = try watchRoot(init, allocator, options, library_path);
    // 监听打不开（目录被删 / 没权限）就是明确的启动错误：不静默退化成「列表不更新」。
    var live = try init.gpa.create(live_mod.Live);
    errdefer init.gpa.destroy(live);
    live.* = try live_mod.Live.init(init.gpa, init.io, library, root);
    defer {
        live.deinit();
        init.gpa.destroy(live);
    }
    // 取图层用自己的分配器（`init.gpa` 线程安全，Debug 下还查泄漏）；L3 目录按
    // 运行形态决定：dev 没有 dataDir → null（不写盘）。
    const thumbs = try thumbs_mod.Thumbs.init(init.gpa, init.io, .{ .isolation = !options.no_isolation, .disk_cache_dir = mode_mod.thumbsCacheDir(allocator, init.io) catch null, .disk_cache_budget = options.disk_cache_budget_bytes });
    defer thumbs.deinit();
    // 预览条也用 `init.gpa`：工作线程要用它分配位图/文本。注册表只有一张
    // （`providers/root.zig`），`--preview` 自检与 UI 看到的是同一份顺序。
    const panel = try preview_panel.Panel.init(init.gpa, init.io, &preview_providers.registry, .{});
    defer panel.deinit();
    const app = try nanoui.App.create(init, .{ .name = "OTTO Lite" });
    defer app.destroy();

    var state = State{
        .gpa = init.gpa,
        .live = live,
        .samples = live.samples(),
        .thumbs = thumbs,
        .preview = panel,
        .search = search_ui.Search.init(init.gpa),
        .import = try import_ui.Import.init(init.gpa, init.io, &library, &live, library_path),
        .transport = transport_mod.Transport.init(init.gpa),
    };
    defer state.import.deinit();
    defer state.selection.deinit(init.gpa);
    defer state.search.deinit();
    defer state.transport.deinit();
    state.selection.resize(init.gpa, state.samples.len) catch {};
    if (options.select) |text| state.seedSelection(text);
    var title_buffer: [96]u8 = undefined;
    const title = version_mod.windowTitle(&title_buffer, state.samples.len);
    state.window = try app.newWindow(.{
        .title = title,
        .width = 380,
        .height = 700,
        .content = .{ .view = .init(&state, State.view) },
    });
    // snapshot 模式没有消息循环，定时器不会跑到；离屏出图只画初始视图。
    // 想看到后台取到的图，加 `--nanoui-wait=<秒>`：事件循环会跑、tick 会重画。
    nanoui.App.after(tick_ms, &state, State.tick);
    try app.run();
}

/// 监听根：`--watch` 优先，否则用解析后的库文件所在目录；都解析成绝对路径，保证
/// join 出来的路径能和库里的 `filePath` 按字节比较。
fn watchRoot(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    options: options_mod.Options,
    library_path: []const u8,
) ![]const u8 {
    const cwd = std.Io.Dir.cwd();
    if (options.watch_dir) |dir| return try cwd.realPathFileAlloc(init.io, dir, allocator);
    const parent = std.fs.path.dirname(library_path) orelse ".";
    return try cwd.realPathFileAlloc(init.io, parent, allocator);
}
