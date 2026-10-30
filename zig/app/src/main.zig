//! OTTO Lite：用 nanoui 的 Windows CPU 后端把 `zig/core` 的资料库画成 380×700 列表，
//! 用 `zig/ports` 的文件监听让列表跟着磁盘变、用系统缩略图给每行左侧配一张小图，
//! 用拖拽口岸把选中的素材交给别的程序。
//!
//!   otto-lite [library.json] [--watch <dir>] [--select=0,1]
//!   otto-lite --demo <dir>           文件监听自检（不取缩略图）
//!   otto-lite --demo-thumbs <dir>    缩略图取图层自检（不开窗）
//!   otto-lite --demo-transport       选择/路径/拖拽快照自检（不开窗、不碰剪贴板）
//!   otto-lite --copy-now <file>      显式把 1 个文件写进剪贴板（CF_HDROP）
//!
//! 选择：点一行 = 只选它；Ctrl+点击 = 切换；Shift+点击 = 从锚点连选；
//! 空白处点击 = 清空。选中行有可见底色，表头是「N 个素材 · M 选中」。
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
const demo_transport = @import("demo_transport.zig");
const demo_thumbs = @import("demo_thumbs.zig");
const demo_watch = @import("demo_watch.zig");
const live_mod = @import("live.zig");
const options_mod = @import("options.zig");
const selection_mod = @import("selection.zig");
const thumbs_mod = @import("thumbs.zig");
const transport_mod = @import("transport.zig");
const ui = nanoui.ui;

/// 轮询间隔：150ms 是「人眼觉得即时」与「闲时几乎不耗 CPU」的折中。监听线程自己
/// 阻塞在 ReadDirectoryChangesW 上，这里只是把队列搬进 Index。
const tick_ms: u64 = 150;

/// 每一行左侧缩略图的边长（点）。真正向系统请求的像素是 64（2x 屏上的 32 点），
/// 缓存键里拼的是请求像素数，不是这里的点数。
const thumb_side: f32 = 32;

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
    /// 选择模型（下标 + 锚点 + 当前行）；帧里只改它，不碰磁盘。
    selection: selection_mod.Selection = .{},
    /// 拖拽快照与执行（把 `DoDragDrop` 挡在帧外）。
    transport: transport_mod.Transport,
    window: ?*nanoui.Window = null,
    /// 上一次 poll 之后看到的 ready 计数，用来判断「后台取到新图了」。
    last_ready: u32 = 0,
    /// 本帧真正画出缩略图的可见行数（tick / 打印用）。
    rows_with_image: u32 = 0,
    /// 上一次打印时的两个数字，避免每帧重复刷同一行；第一次一定打印。
    printed_ready: u32 = 0,
    printed_rows: u32 = 0,
    reported: bool = false,
    printed_settled: bool = false,
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

        // 首行显示总数与选中数（截图里也能核对的数字）。
        // 注意这里是显式 end：`defer header.end()` 会拖到函数返回才关盒，
        // 列表会变成 header 的子节点（行方向），只剩一行能看见。
        const header = ui.div(c).row().wFull().h(30).px(12).gap(8).itemsCenter();
        ui.textf(c, .{ .size = 12 }, "{d} 个素材 · {d} 选中", .{ s.samples.len, s.selection.count() });
        if (s.flash_left > 0) {
            ui.textf(c, .{ .size = 11, .color = c.theme.accent }, "· 已复制 {d} 个素材", .{s.flash_count});
        } else if (s.printed_rows > 0) {
            ui.textf(c, .{ .size = 11, .color = c.theme.muted }, "· {d} 行有缩略图", .{s.printed_rows});
        }
        if (s.live.dirty()) ui.text(c, "· 有事件丢失，视图可能不完整", .{ .size = 11 });
        header.end();

        // 列表容器：在空白处按下再松开 = 清空选择。行是它的后代：点行时
        // 上一帧的 hot 落在行上，容器的 interact 不会 clicked（见 nanoui
        // `context_hooks.interact` 的 top/active 规则）。
        const body = ui.div(c).sizeFull();
        defer body.end();
        const body_it = body.interaction();

        var rows = ui.list(c, .{ .count = s.samples.len, .row_height = 44 });
        while (rows.next()) |i| {
            const it = s.drawRow(c, i, s.samples[i]);
            if (!busy) s.rowInput(c, i, it);
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

        s.report();
    }

    /// 一行的绘制 + 交互。返回 pressable 的 Interaction 给 `rowInput` 判点击/拖拽。
    fn drawRow(s: *State, c: *ui.Context, i: usize, sample: core.model.Sample) ui.Interaction {
        const selected = s.selection.isSelected(i);
        const style: ui.Style = .{
            .direction = .row,
            .width = .fill,
            .height = .{ .px = 44 },
            .padding = .xy(12, 0),
            .gap = 10,
            .align_items = .center,
            // 选中底色：主题强调色的低透明度版本；未选中交给 hover 动画。
            .background = if (selected) c.theme.accent.alpha(0.16) else null,
        };
        // 选中行悬停时把底色加深而不是换成灰色的 surface_hover——否则鼠标停在
        // 刚点过的那一行上，选中底色会被 hover 盖掉，看起来像没选中。
        const hover_color = if (selected) c.theme.accent.alpha(0.26) else c.theme.surface_hover;
        const it = ui.pressable(c, style, hover_color);
        defer ui.end(c);

        if (drawThumb(c, s.thumbs, sample)) s.rows_with_image += 1;
        ui.textf(c, .{ .size = 11 }, "{d:0>4}", .{i + 1});
        ui.text(c, sample.file_name, .{ .size = 13 });
        ui.textf(c, .{ .size = 11 }, "{d:.2}s", .{sample.duration});
        return it;
    }

    /// 点击语义、拖拽阈值。Ctrl+点击在 nanoui 里不算 clicked（它被当成右键按下，
    /// 见 `interact` 的 `right_pressed`），所以这里单独认。
    fn rowInput(s: *State, c: *ui.Context, i: usize, it: ui.Interaction) void {
        if (it.right_pressed and c.input.button == .left and c.input.ctrl) {
            s.selection.click(i, .{ .ctrl = true });
            s.cancelPress();
            s.noteSelection();
            c.changed = true;
            return;
        }
        if (it.clicked) {
            s.selection.click(i, .{ .shift = c.input.shift });
            s.cancelPress();
            s.noteSelection();
            c.changed = true;
            return;
        }
        if (s.drag_ended or s.drag_armed or !it.pressed) return;
        if (s.press_row == null) {
            s.press_row = i;
            s.press_origin = c.input.mouse;
        }
        if (s.press_row != i) return;
        const dx = c.input.mouse.x - s.press_origin.x;
        const dy = c.input.mouse.y - s.press_origin.y;
        if (dx * dx + dy * dy <= drag_threshold * drag_threshold) return;
        s.armDrag(c, i);
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

    /// 数字变了才打印一行：`--nanoui-snapshot` 的 stdout 里就能数清「多少行取到图」。
    fn report(s: *State) void {
        const ready = s.thumbs.readyCount();
        const stats = s.thumbs.stats();
        // 「全部落地」也值得打一行：默认 fixture 的 wav 全都取不到，只有这一行能
        // 把最终账目（failed=N、pending=0）带出来。
        const settled = stats.pending == 0;
        const changed = !s.reported or ready != s.printed_ready or
            s.rows_with_image != s.printed_rows or (settled and !s.printed_settled);
        if (!changed) return;
        s.reported = true;
        s.printed_ready = ready;
        s.printed_rows = s.rows_with_image;
        s.printed_settled = settled;

        std.debug.print(
            "otto-lite: 缩略图 ready={d} 本帧画图={d} requested={d} no_handler={d} cached={d} failed={d} pending={d}\n",
            .{ stats.ready, s.rows_with_image, stats.requested, stats.no_handler, stats.cached, stats.failed, stats.pending },
        );
    }

    /// 自续期定时器回调：poll 一次，有实际变更就重画；然后重新挂 150ms。
    /// 也负责让 Ctrl+C 的表头提示在 1.5 秒后恢复。
    fn tick(ctx: ?*anyopaque) callconv(.c) void {
        const s: *State = @ptrCast(@alignCast(ctx.?));
        // 拖放循环里不许再碰 UI（连轮询也不做）：等它返回后下一次 tick 再补。
        if (!s.transport.busy) {
            s.refresh();
            if (s.flash_left > 0) {
                s.flash_left -= 1;
                if (s.flash_left == 0) if (s.window) |window| window.redraw();
            }
        }
        nanoui.App.after(tick_ms, ctx, tick);
    }

    fn refresh(s: *State) void {
        const report_events = s.live.poll() catch |err| {
            std.debug.print("otto-lite: poll 失败：{s}\n", .{@errorName(err)});
            return;
        };
        // 即使四个计数都是零，`apply` 的扩容也可能让切片搬家，所以无条件重取。
        s.samples = s.live.samples();

        const changed = report_events.added != 0 or report_events.removed != 0 or
            report_events.renamed != 0 or report_events.modified != 0 or report_events.overflowed;
        // 磁盘变了：之前「文件没了 / Shell 失败」的结论值得重试一次。
        if (changed) s.thumbs.clearFailures();

        // 后台取到新图也要重画：ready 计数是本层唯一的变化信号。
        const ready = s.thumbs.readyCount();
        const ready_changed = ready != s.last_ready;
        if (ready_changed) s.last_ready = ready;

        if (!changed and !ready_changed) return;

        const window = s.window orelse return;
        if (changed) setTitle(window, s.samples.len);
        window.redraw();
    }

    /// 帧外（定时器）执行一次待拖拽。进入前把计划从 `Transport` 摘下来。
    fn dragTimer(ctx: ?*anyopaque) callconv(.c) void {
        const s: *State = @ptrCast(@alignCast(ctx.?));
        if (s.transport.busy) return;
        const result = s.transport.execute(nativeHandle(s.window));
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

/// 平台原生窗口句柄。Windows 上 `Window` 有 `hwnd` 字段；其它平台没有（拖拽口岸
/// 也只在 Windows 上场），用 comptime 检查而不是条件编译整个 app。
fn nativeHandle(window: ?*nanoui.Window) ?*anyopaque {
    const win = window orelse return null;
    if (comptime @hasField(nanoui.Window, "hwnd")) {
        const hwnd = win.hwnd orelse return null;
        return @ptrCast(hwnd);
    }
    return null;
}

/// 一行左侧的缩略图槽：有图画图，没有图按原因画占位图标。
/// 返回 true 表示这一帧真的画上了缩略图（`State.report` 拿它数行）。
fn drawThumb(c: *ui.Context, thumbs: *thumbs_mod.Thumbs, sample: core.model.Sample) bool {
    // 先问取图层，再开盒子：占位要按答案选背景，而 `div` 的样式必须在子节点之前设。
    const outcome = thumbs.acquire(sample);

    const slot = ui.div(c).w(thumb_side).h(thumb_side).rounded(6).itemsCenter().justifyCenter();
    defer slot.end();

    switch (outcome) {
        .ready => |view| {
            const drawn = ui.image(c, .{
                .key = view.key,
                .source = .{ .pixels = .{
                    .bgra = view.pixels,
                    .width = view.width,
                    .height = view.height,
                    .stride = view.stride,
                } },
                .max_width = thumb_side,
                .max_height = thumb_side,
                // 取图层按 64px 请求（见 thumbs.default_size_px）：这里声明「源图是 2x」，
                // 于是 2x 屏上 1:1 显示、1x 屏由图集缩到 32 点。
                .scale = 2,
                .radius = 6,
            });
            if (drawn) return true;
            // 图集拒了这块像素（理论上不会）：不静默留空，退回占位。
            placeholder(c, slot, "photo");
            return false;
        },
        .pending => {
            // 排队 / 正在取：先按类型给占位，取到了下一次 redraw 会换成真图。
            placeholder(c, slot, placeholderIcon(sample));
            return false;
        },
        .no_handler => {
            // 能力门禁：这台机器没有该扩展名的 handler。音频用波形，其它用文档。
            placeholder(c, slot, placeholderIcon(sample));
            return false;
        },
        .failed => {
            // 文件没了 / Shell 出错：给一个警告三角，别让它看起来像「没有预览」。
            placeholder(c, slot, "exclamationmark.triangle");
            return false;
        },
    }
}

fn placeholder(c: *ui.Context, slot: ui.Div, icon_name: []const u8) void {
    _ = slot.bg(c.theme.track);
    ui.icon(c, icon_name, .{ .size = 16, .color = c.theme.muted });
}

/// 没有 handler 时用哪个图标：音频认波形，其余认文档。
fn placeholderIcon(sample: core.model.Sample) []const u8 {
    const audio_exts = [_][]const u8{
        ".wav", ".mp3", ".flac", ".aiff", ".aif", ".ogg", ".m4a", ".wma", ".aac", ".opus", ".caf",
    };
    for (audio_exts) |ext| {
        if (std.ascii.eqlIgnoreCase(sample.file_ext, ext)) return "waveform.path.ecg";
    }
    return "doc";
}

fn setTitle(window: *nanoui.Window, total: usize) void {
    var buffer: [64]u8 = undefined;
    const title = std.fmt.bufPrint(&buffer, "OTTO Lite — {d}", .{total}) catch "OTTO Lite";
    window.setTitle(title);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    const options = options_mod.parse(args) catch {
        std.debug.print(
            "用法：otto-lite [library.json] [--watch <dir>] [--select=0,1]\n" ++
                "      otto-lite --demo <dir> | --demo-thumbs <dir> | --demo-transport\n" ++
                "      otto-lite --copy-now <file>\n",
            .{},
        );
        return error.InvalidArguments;
    };

    // 选择/拖拽快照/参数校验自检：不开窗，也不碰剪贴板。
    if (options.demo_transport) {
        const code = try demo_transport.run(init, allocator);
        if (code != 0) std.process.exit(code);
        return;
    }

    // 真正写剪贴板只走这条显式命令（用户点名的文件）。
    if (options.copy_now) |path| {
        const code = transport_mod.copyNow(init.gpa, path);
        if (code != 0) std.process.exit(code);
        return;
    }

    // 取图自检：完全不开窗，也不碰 nanoui。
    if (options.demo_thumbs_dir) |dir_path| {
        const code = try demo_thumbs.run(init, init.gpa, dir_path);
        if (code != 0) std.process.exit(code);
        return;
    }

    if (options.demo_dir) |dir_path| return demo_watch.run(init, allocator, dir_path);

    const library = try core.store.loadCwdFile(allocator, init.io, options.library_path);
    const root = try watchRoot(init, allocator, options);

    // 监听打不开（目录被删 / 没权限）就是明确的启动错误：不静默退化成「列表不更新」。
    var live = try live_mod.Live.init(allocator, &library, root);
    defer live.deinit();

    // 取图层用自己的分配器（`init.gpa` 线程安全，Debug 下还查泄漏）：
    // 工作线程要拿它分配像素、路径与缓存条目，不能用进程级 arena。
    const thumbs = try thumbs_mod.Thumbs.init(init.gpa, init.io, .{});
    defer thumbs.deinit();

    const app = try nanoui.App.create(init, .{ .name = "OTTO Lite" });
    defer app.destroy();

    var state = State{
        .gpa = init.gpa,
        .live = &live,
        .samples = live.samples(),
        .thumbs = thumbs,
        .transport = transport_mod.Transport.init(init.gpa),
    };
    defer state.selection.deinit(init.gpa);
    defer state.transport.deinit();
    state.selection.resize(init.gpa, state.samples.len) catch {};
    if (options.select) |text| state.seedSelection(text);

    var title_buffer: [64]u8 = undefined;
    const title = try std.fmt.bufPrint(&title_buffer, "OTTO Lite — {d}", .{state.samples.len});
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

/// 监听根：`--watch` 优先，否则用库文件所在目录；都解析成绝对路径，保证
/// join 出来的路径能和库里的 `filePath` 按字节比较。
fn watchRoot(init: std.process.Init, allocator: std.mem.Allocator, options: options_mod.Options) ![]const u8 {
    const cwd = std.Io.Dir.cwd();
    if (options.watch_dir) |dir| return try cwd.realPathFileAlloc(init.io, dir, allocator);
    const parent = std.fs.path.dirname(options.library_path) orelse ".";
    return try cwd.realPathFileAlloc(init.io, parent, allocator);
}
