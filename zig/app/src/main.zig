//! OTTO Lite：用 nanoui 的 Windows CPU 后端把 `zig/core` 的资料库画成 380×700 列表，
//! 用 `zig/ports` 的文件监听让列表跟着磁盘变、用系统缩略图给每行左侧配一张小图。
//!
//!   otto-lite [library.json] [--watch <dir>] [--select=0,1]
//!   otto-lite --version | --convert <in> <out> | --library-info <file>
//!   otto-lite --demo <dir> | --demo-rescan <dir> | --demo-thumbs <dir> | --demo-transport
//!   otto-lite --preview <file> | --play-test <file> | --copy-now <file>
//!   otto-lite --import <folder> [--library <file>] --save <out.otto>
//!   otto-lite --check-update <url>     （无窗口更新检查，见 `update_ui.zig`）
//!   每条自检的用途见 `commands.zig`；都**不开窗**、不抢焦点；更新检查默认不联网。
//!
//! 本文件只留三件事：**参数分派**（`options` + `commands`）、**生命周期**
//! （`tick` / `refresh` / 重载 / 拖拽定时器）、**`State` 组装**。其余在各枝：
//!   * `app_boot.zig` —— 启动装配：库 / Live / 设置 / 缩略图 / 预览条 / 字体与上屏后端；
//!   * `row_ui.zig`   —— 列表行的绘制、点击与拖拽、复制与选择表；
//!   * `live.zig` / `live_adapt.zig` / `live_rescan.zig` —— 监听、翻译、重扫协作。
//!
//! 列表下方是预览区（`preview_panel.zig`）：本文件不认识任何媒体类型（ROADMAP M1）。
//!
//! 没有位置参数时库路径由运行形态决定（`mode.zig`）：dev 用 `fixtures/library.json`，
//! 便携/安装版用 `<数据目录>\library.json`（导入过的库是那里的 `library.otto`）；库文件不存在 = 空库。
//! 搜索（`search_ui.zig`）：Ctrl+F 聚焦、Esc 清空；输入即过滤（文件名子串、ASCII
//! 大小写不敏感），过滤变化时清空选择、光标尽量停在原样本；拖出与 Ctrl+C 见 `transport.zig`。

const std = @import("std");
const nanoui = @import("nanoui");
const core = @import("otto_core");
const app_boot = @import("app_boot.zig");
const bench_mod = @import("bench.zig");
const bench_scroll = @import("bench_scroll.zig");
const commands = @import("commands.zig");
const drop_ui = @import("drop_ui.zig");
const duration_trust = @import("duration_trust.zig");
const empty_state = @import("empty_state.zig");
const import_ui = @import("import_ui.zig");
const list_header = @import("list_header.zig");
const live_mod = @import("live.zig");
const mem_probe = @import("mem_probe.zig");
const opacity_probe = @import("opacity_probe.zig");
const options_mod = @import("options.zig");
const preview_panel = @import("preview_panel.zig");
const row_probe = @import("row_probe.zig");
const row_ui = @import("row_ui.zig");
const search_ui = @import("search_ui.zig");
const selection_mod = @import("selection.zig");
const settings_ui = @import("settings_ui.zig");
const thumbs_mod = @import("thumbs.zig");
const thumbs_prefetch = @import("thumbs_prefetch.zig");
const thumbs_report = @import("thumbs_report.zig");
const trace = @import("trace.zig");
const transport_mod = @import("transport.zig");
const update_ui = @import("update_ui.zig");
const version_mod = @import("version.zig");
const window_util = @import("window_util.zig");
const ui = nanoui.ui;
/// 轮询间隔：150ms 是「人眼觉得即时」与「闲时几乎不耗 CPU」的折中（监听线程自己阻塞在 ReadDirectoryChangesW 上）。
const tick_ms: u64 = 150;

pub const State = struct {
    /// 选择表与拖拽快照的分配器（`init.gpa`，长生命周期；不是帧 arena）。
    gpa: std.mem.Allocator,
    live: *live_mod.Live,
    /// 当前视图；每次 poll 之后都要重新取——`Index.apply` 的扩容会让数组搬家。
    samples: []const core.model.Sample,
    /// 行内时长的可信度 side table：MP3 的时长是不是按比特率估算的。
    /// core 的 `Sample` 只有一个 f64，估算位放不进模型，只能放在 app 侧。
    duration_trust: duration_trust.Trust,
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
    /// 空闲预取：视口窗口 + 150ms 节流（见 `thumbs_prefetch.zig`）。
    prefetch: thumbs_prefetch.Scheduler = .{},
    /// 行就绪探针：每帧建过的行 + 有没有画出图；`--bench-scroll` 数 ready/visited。
    row_probe: row_probe.RowProbe = .{},
    /// 缩略图的排队/取图情况，数字变了才打印一行（见 `thumbs_report.zig`）。
    reporter: thumbs_report.Reporter = .{},
    /// 按下时的行与位置（只记一次；松手/离开后清掉）。
    press_row: ?usize = null,
    press_origin: ui.Point = .{},
    /// 已经越过阈值、定时器已挂上：同一次按压里不许再排第二次。
    drag_armed: bool = false,
    /// 一次 OLE 拖拽刚结束：nanoui 的鼠标可能还停在按下状态（见 `resyncInput`）。
    drag_ended: bool = false,
    /// 表头提示还剩几拍（>0 = 正在闪），以及刚复制了几个。
    flash_left: u32 = 0,
    flash_count: usize = 0,
    fn view(s: *State, c: *ui.Context) void {
        // 上一帧 pin 住的条目到这里才放掉：view 之后还有 paint，paint 期间像素要有效。
        s.thumbs.beginFrame();
        s.rows_with_image = 0;
        s.row_probe.begin();
        // 拖放循环里窗口仍可能收到 WM_PAINT：这一帧只按现有状态重画，不处理输入、
        // 不调用任何口岸。`Transport.execute` 返回后 `busy` 才落回 false。
        const busy = s.transport.busy;
        if (!busy) {
            row_ui.syncSelection(s);
            row_ui.resyncInput(s, c);
            // Ctrl+C：在构建树之前处理，`c.changed` 会让这一帧重建出表头提示。
            if (c.shortcut(.{ .key = 'c', .ctrl = true })) row_ui.copySelection(s, c);
        }

        ui.column(c, .{ .width = .fill, .height = .fill });
        defer ui.end(c);

        // 搜索框在列表上方：先处理键盘/重建映射再画它，本帧输入的字符在同一帧就参与过滤；
        // 「导入文件夹」按钮和搜索框同一行、宽度固定（见 `search_ui.Trailing`）。
        const import_button: search_ui.Trailing = .{
            .label = import_ui.button_label,
            .width = import_ui.button_width,
            .disabled = s.import.busy(),
        };
        if (!busy) {
            const action = s.search.frame(c, s.samples, &s.selection, import_button);
            if (action.filter_changed) row_ui.noteSelection(s);
            if (action.activate) row_ui.activateCursor(s, c);
            if (action.toggle_play) c.changed = s.preview.togglePlay(row_ui.previewRow(s)) or c.changed;
            // 模态选择框在 UI 线程上跑；取消不进状态机（见 `import_ui.begin`）。
            if (action.trailing_clicked) s.import.begin(window_util.nativeHandle(s.window));
        } else {
            _ = s.search.draw(c, import_button);
        }

        var status_buffer: [128]u8 = undefined;
        var update_buffer: [160]u8 = undefined;
        var update_action_buffer: [32]u8 = undefined;
        var ext_buffer: [128]u8 = undefined;
        const header_action = list_header.draw(c, .{
            .total = s.samples.len,
            .matched = s.search.len(),
            .selected = s.selection.count(),
            .ext_filter = s.search.extSummary(&ext_buffer),
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
        // 列表容器：空白处按下再松开 = 清空选择（行是它的后代，点行时容器不会 clicked）。
        const body = ui.div(c).sizeFull();
        const body_it = body.interaction();

        // 列表只遍历行映射：第 row 行 → 第 index 个样本（选择/预览/拖拽仍只认样本下标）。
        var rows = ui.list(c, .{ .count = s.search.len(), .row_height = 44 });
        // 本帧建出来的行范围（含 list 的 overscan）。预取与验收都用它，不改列表行为。
        var first_row: usize = 0;
        var last_row: usize = 0;
        var built_rows: usize = 0;
        while (rows.next()) |row| {
            const index = s.search.sampleAt(row) orelse continue;
            const it = row_ui.drawRow(s, c, row, index, s.samples[index]);
            if (!busy) row_ui.rowInput(s, c, index, it);
            if (built_rows == 0) first_row = row;
            last_row = row;
            built_rows += 1;
        }
        rows.end();

        // 库非空但过滤到 0 行：给一段明确文案（不是一片空白）。
        if (!busy and s.samples.len > 0 and s.search.len() == 0) s.search.drawNoMatches(c);

        // 空库（首次启动）：列表区域换成空状态 + 居中的「导入文件夹」。
        const empty_clicked = empty_state.draw(c, s.samples.len, s.import.busy());
        if (!busy and empty_clicked) s.import.begin(window_util.nativeHandle(s.window));

        if (!busy) {
            if (body_it.clicked) {
                s.selection.clear();
                row_ui.cancelPress(s);
                row_ui.noteSelection(s);
                c.changed = true;
            }
            // 松手（或按钮已经不在了）就放弃这次按压：定时器若还没跑，会看到空计划。
            if (c.input.released or !c.input.down) row_ui.cancelPress(s);
        }
        // 列表到此为止：预览条必须是它的兄弟，不能变成列表的子节点。
        body.end();

        // 预览条：只在选中行变化时提交请求（`sync` 自己判重）；工作线程读完由
        // `tick` 接手。事实摘要的时长与列表行同一条 `duration_trust.display`。
        const preview_sample = row_ui.previewRow(s);
        s.preview.sync(preview_sample, row_ui.previewDuration(s, preview_sample));
        s.preview.draw(c);

        s.reporter.report(s.thumbs, s.rows_with_image);
        // 设置面板是最后一层：遮罩 + 卡片覆盖列表，点击优先级由树序保证。
        s.settings.draw(c, s.thumbs, &s.update, window_util.nativeHandle(s.window));

        // 帧尾：记下这一帧的视口，然后（有空的话）补一轮预取。每帧最多一次；
        // 滚动中队列几乎从不清空，所以真正跑起来的是停下之后的那一拍。
        // 拖放循环里的重画不预取（按约定那一帧不碰口岸），拖完由 tick / 下一帧补。
        if (built_rows > 0) s.prefetch.noteWindow(first_row, last_row);
        if (!busy) s.maybePrefetch();
    }

    /// 空闲预取的一趟：队列空闲（`pending == 0`）才把视口上下几十行提前入队。
    ///
    /// 三道闸在 `thumbs_prefetch.Scheduler`：开关（`--no-prefetch`）、视口是否变了、
    /// 距上一轮 ≥120ms。这里只做行号翻译（过滤后的行 → 样本下标）与入队；预取优先级
    /// 由 `Thumbs` 的队列保证（可见 > 预取），所以这一趟**挤不掉**任何可见请求。
    fn maybePrefetch(s: *State) void {
        const now = trace.now();
        if (!s.prefetch.due(now)) return;
        // 可见行还在排队：这一拍跳过，下一拍再看。队列空闲是"真的闲下来"的唯一判据。
        if (s.thumbs.stats().pending != 0) {
            s.prefetch.markBusy(now);
            return;
        }
        s.prefetch.markPass(now);

        var rows: [thumbs_prefetch.max_rows]usize = undefined;
        const count = thumbs_prefetch.windowRows(&rows, s.prefetch.first, s.prefetch.last, s.search.len());
        // 过滤后的行号必须翻译成样本下标：取图层只认样本（和选择/预览一致）。
        var indices: [thumbs_prefetch.max_rows]usize = undefined;
        var used: usize = 0;
        for (rows[0..count]) |row| {
            const index = s.search.sampleAt(row) orelse continue;
            if (index >= s.samples.len) continue;
            indices[used] = index;
            used += 1;
        }
        s.thumbs.prefetch(s.samples, indices[0..used]);
    }

    /// 自续期定时器回调：poll 一次，有实际变更就重画；然后重新挂 150ms。
    /// 也负责让 Ctrl+C 的表头提示在 1.5 秒后恢复。
    fn tick(ctx: ?*anyopaque) callconv(.c) void {
        const s: *State = @ptrCast(@alignCast(ctx.?));
        // 拖放循环里不许再碰 UI（连轮询也不做）：等它返回后下一次 tick 再补。
        if (!s.transport.busy) {
            // 启动置顶被前台锁拒绝时，窗口第一次成为前台后补一次（见 settings_ui）。
            s.settings.retryTopmostIfActivated(window_util.nativeHandle(s.window));
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
            // 150ms 一拍：滚轮停下之后不再有 view，预取靠这一拍补上（同一套闸门）。
            s.maybePrefetch();
        }
        nanoui.App.after(tick_ms, ctx, tick);
    }

    /// 导入成功后重载：内存列表换成刚保存的那份库（理由见 `import_ui.zig` 文件头）。
    /// 选择清空、过滤重建、预览重提交——都走和启动时同一条初始化路径。
    fn afterReload(s: *State) void {
        s.live = s.import.live();
        s.samples = s.live.samples();
        s.duration_trust.clear();
        s.thumbs.clearFailures();
        s.search.markStale();
        s.selection.clear();
        s.selection.resize(s.gpa, s.samples.len) catch {};
        s.preview.sync(null, .{});
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
    /// `pub` 是因为 `row_ui.armDrag` 要拿它当定时器回调（跨文件引用声明）。
    pub fn dragTimer(ctx: ?*anyopaque) callconv(.c) void {
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
        row_ui.cancelPress(s);
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
    const options = options_mod.parse(args) catch |err| return opacity_probe.parseError(err);
    // 所有不开窗的模式（--version / 自检 / 转换 / 查库）都在这里返回；
    // null 才继续走 UI。顺序与实现见 `commands.zig`。
    if (try commands.run(init, allocator, options)) |code| {
        if (code != 0) std.process.exit(code);
        return;
    }
    // `--mem-probe`：真实窗口形态的内存分解（隐藏窗口）；没开时 `begin`/`mark` 只是 bool 判断。
    var probe = mem_probe.Probe.begin(init, options);
    // 库 / Live / 设置 / 缩略图 / 预览条 / 字体与上屏后端：见 `app_boot.zig`。
    var boot = try app_boot.boot(init, allocator, options, &probe);
    defer boot.deinit();

    var state = State{
        .gpa = init.gpa,
        .live = boot.live,
        .samples = boot.live.samples(),
        .duration_trust = duration_trust.Trust.init(init.gpa, init.io),
        .thumbs = boot.thumbs,
        .preview = boot.preview,
        .search = search_ui.Search.init(init.gpa),
        .import = try import_ui.Import.init(init.gpa, init.io, &boot.library, &boot.live, boot.library_path),
        .update = try update_ui.Update.initForProcess(init.gpa, init.io, options.update_url orelse boot.settings.update_url, options.no_exec, options.update_current),
        .settings = try settings_ui.Panel.init(init.gpa, init.io, boot.settings, boot.settings_path, .{ .d3d = options.d3d }),
        .transport = transport_mod.Transport.init(init.gpa),
        // `--no-prefetch`：空闲预取关掉（对比实验只差这一项）。
        .prefetch = .{ .enabled = !options.no_prefetch, .last_try_s = trace.now() },
    };
    trace.mark("setup.state");
    defer state.import.deinit();
    defer state.update.deinit();
    defer state.settings.deinit();
    defer state.selection.deinit(init.gpa);
    defer state.search.deinit();
    defer state.transport.deinit();
    defer state.duration_trust.deinit();
    state.selection.resize(init.gpa, state.samples.len) catch {};
    if (options.select) |text| selection_mod.seedSelection(&state.selection, state.samples.len, text);
    var title_buffer: [96]u8 = undefined;
    const title = version_mod.windowTitle(&title_buffer, state.samples.len);
    // `--bench-first-frame` 是离屏探针：不建真实 HWND，也不 show。
    if (options.bench_first_frame) boot.app.gui = false;
    // `--bench-scroll`：真实窗口、屏外、从不激活；窗口由基准自己建，进程交给它。
    // 行就绪探针交出去：基准要靠它数"滚动经过的行里有多少已经画出图标"。
    if (options.bench_scroll != null) try bench_scroll.runCli(init, boot.app, boot.thumbs, options, .init(&state, State.view), title, &state.row_probe);
    state.window = try boot.app.newWindow(.{
        .title = title,
        .width = 380,
        .height = 700,
        // 设置验收的脚本要真 HWND，但仍然绝不激活。
        .no_activate = options.settings_probe or options.drop_probe != null or options.set_opacity != null,
        .content = .{ .view = .init(&state, State.view) },
    });
    // 文件拖入：目录走「导入文件夹」同一条 `Import.start`；`--drop-probe` 时
    // 还会合成一次 WM_DROPFILES（窗口隐藏，见 `drop_ui.zig`）。
    var drop: drop_ui.Drop = .{};
    drop.install(init.io, &state.import, options.drop_probe, state.window.?, nanoui.App.after);
    trace.mark("setup.window");
    probe.mark("window", .{ .window = state.window, .thumbs = boot.thumbs });
    // 窗口状态启动时应用一次：置顶（true 才碰 Win32）+ 不透明度（重启后恢复）。
    // `--set-opacity` 走同一处：先应用启动状态，再按滑块路径改一次并落盘退出。
    opacity_probe.applyStartup(&state.settings, window_util.nativeHandle(state.window), options.set_opacity);
    if (options.bench_first_frame) {
        try bench_mod.firstFrame(init, boot.app, started);
        // 一次性探针：打印完就退出，不 join 工作线程（冷启动取图不能算进首帧墙钟）。
        std.process.exit(0);
    }
    // snapshot 模式没有消息循环（`--nanoui-wait=<秒>` 才会跑事件循环、tick 重画）。
    nanoui.App.after(tick_ms, &state, State.tick);
    // 探针：D3D、8/50/100 张缩略图、空闲 10 秒，打完表就退出（不 join 工作线程）。
    if (probe.active) probe.finish(state.window.?, boot.thumbs);
    try boot.app.run();
}
