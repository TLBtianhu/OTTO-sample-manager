//! 设置面板：置顶 / 窗口不透明度 / 更新源 / 两级缓存预算。
//!
//! 分工与 `search_ui.zig` / `preview_panel.zig` 相同：
//!   * 本文件拥有**面板的临时编辑状态**（三个 `TextBuffer` + 滑块值）；
//!   * 值的真相在 `settings_store.Settings`（持久化）与 `Settings` 指向的运行时
//!     对象（`Thumbs` 的预算、`Update` 的 URL）；
//!   * "改完立即生效"：置顶在开关被点的那一帧就调用 Win32；不透明度在滑块拖动
//!     的每一帧调用 `SetLayeredWindowAttributes`；URL 交给 `Update.setUrl`，
//!     L2 / L3 预算交给 `Thumbs.setBudgets`；随后原子写设置文件。
//!
//! ## 布局（380 点时）
//!
//! 面板是 `ui.card`，绝对定位覆盖在列表上（不参与列表布局，搜索框宽度不变）。
//! 底层还有一层半透明遮罩：点遮罩关闭面板，也挡住它下面的列表点击。
//! 控件从上到下：标题 + 「关闭」、「窗口置顶」开关、「窗口不透明度」+ 滑块 +
//! 百分比、更新源、「缩略图内存预算 (MiB)」、「磁盘缓存预算 (MiB)」。
//!
//! ## 为什么关闭时才写盘
//!
//! 拖滚动条/打字时每个字符都写一次文件既慢又制造无意义的 `.tmp` 替换。值在关闭
//! 时一次应用、一次原子写；置顶与不透明度是例外——它们必须从点击/拖动那一帧起
//! 就真的改窗口。

const std = @import("std");
const nanoui = @import("nanoui");
const settings_store = @import("settings_store.zig");
const thumbs_mod = @import("thumbs.zig");
const update_ui = @import("update_ui.zig");
const win_window = @import("otto_win_window");
const ui = nanoui.ui;

const panel_width: f32 = 332;
const panel_x: f32 = 24;
const panel_y: f32 = 64;

pub const Options = struct {
    /// 上屏走 D3D11 翻转交换链（`--d3d`）：分层窗口在这个模型下无效，设透明度时
    /// 打一行警告（不静默，见 `applyOpacity`）。
    d3d: bool = false,
};

pub const Panel = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// 设置值的唯一持有者（`deinit` 释放 update_url）。
    settings: settings_store.Settings,
    /// 设置文件的路径（本对象复制一份）；null = 内存态（dataDir 拿不到）。
    path: ?[]u8,
    open: bool = false,
    url_field: ui.TextBuffer = .{},
    l2_field: ui.TextBuffer = .{},
    l3_field: ui.TextBuffer = .{},
    /// 滑块的当前值（0..100；`ui.slider` 只收浮点）。持久值在 `settings.opacity`
    /// 的 0..255 上，两者用 `settings_store.alphaFromPercent` 换算。
    opacity_percent: f32 = 100,
    /// 上一次真正写进 Win32 的 alpha。用来让日志只在**值变了**时打一行：
    /// 拖动滑块每帧都会调用 `applyOpacity`，不然日志会被刷屏。
    applied_alpha: ?u8 = null,
    /// `--d3d` 下的透明度警告只打一行（拖动时每次改值都警告同样是刷屏）。
    d3d_warned: bool = false,
    /// 上屏是否是 D3D 翻转交换链（`--d3d`）。
    d3d: bool = false,
    /// 启动置顶被前台锁拒绝（`error.TopmostRejected`）：等窗口第一次成为前台时
    /// 补一次。只排一次，补完就清掉——不在 tick 里循环重试。
    topmost_retry_pending: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        settings: settings_store.Settings,
        path: ?[]const u8,
        opts: Options,
    ) !Panel {
        const owned_path: ?[]u8 = if (path) |value| try allocator.dupe(u8, value) else null;
        errdefer if (owned_path) |value| allocator.free(value);
        var panel = Panel{
            .allocator = allocator,
            .io = io,
            .settings = settings,
            .path = owned_path,
            .d3d = opts.d3d,
        };
        panel.syncFields();
        return panel;
    }

    pub fn deinit(self: *Panel) void {
        self.settings.deinit();
        self.url_field.deinit();
        self.l2_field.deinit();
        self.l3_field.deinit();
        if (self.path) |value| self.allocator.free(value);
        self.* = undefined;
    }

    /// 打开面板：文本框与滑块回到**已保存**的值（上一次没关闭的编辑不保留）。
    pub fn openPanel(self: *Panel, c: *ui.Context) void {
        self.syncFields();
        self.open = true;
        c.changed = true;
    }

    /// 关闭面板：应用 → 持久化。重复调用是安全的（close 后 open=false）。
    pub fn close(self: *Panel, thumbs: *thumbs_mod.Thumbs, update: *update_ui.Update, hwnd: ?*anyopaque) void {
        if (!self.open) return;
        self.apply(thumbs, update);
        self.open = false;
        self.applyTopmost(hwnd);
        self.save();
    }

    /// 启动时应用一次窗口状态：置顶（只在保存了 true 时）+ 不透明度。
    ///
    /// 两件事都只碰**已存在**的 HWND：不显示窗口、不激活、不抢焦点
    /// （`win_window.zig` 的调用位）。
    pub fn applyWindowState(self: *Panel, hwnd: ?*anyopaque) void {
        if (self.settings.always_on_top) self.applyTopmost(hwnd);
        self.applyOpacity(hwnd);
    }

    /// 应用一次保存的置顶状态；面板里的开关也走这里。
    pub fn applyTopmost(self: *Panel, hwnd: ?*anyopaque) void {
        // 新的一次应用（启动或用户点开关）作废旧补救计划：只认最后一次状态。
        self.topmost_retry_pending = false;
        win_window.setTopmost(hwnd, self.settings.always_on_top) catch |err| {
            self.logTopmostFailure(err);
            return;
        };
        self.logTopmostState(hwnd);
    }

    /// 启动置顶被前台锁拒绝后，窗口第一次成为前台时补一次。
    ///
    /// 由 `main.zig` 的 tick 每 150ms 调一次。nanoui 没有 focus 回调（只有每帧的
    /// `Context.window_focused`），所以用系统事实 `GetForegroundWindow() == 我们的
    /// hwnd` 判断"第一次被激活"；不激活窗口、不改前台。补一次就清掉 pending：
    /// 再失败也只记一行，不会在 tick 里循环。
    pub fn retryTopmostIfActivated(self: *Panel, hwnd: ?*anyopaque) void {
        if (!self.topmost_retry_pending) return;
        if (!win_window.isForeground(hwnd)) return;
        self.topmost_retry_pending = false;
        std.debug.print(
            "otto-lite: 窗口已激活，重试置顶 topmost-retry state={}\n",
            .{self.settings.always_on_top},
        );
        win_window.setTopmost(hwnd, self.settings.always_on_top) catch |err| {
            std.debug.print(
                "otto-lite: 重试置顶仍失败（{s}），不再重试\n",
                .{@errorName(err)},
            );
            return;
        };
        self.logTopmostState(hwnd);
    }

    /// 置顶失败的日志。`TopmostRejected` 是"系统拒绝"，必须让人看见，并且排一次
    /// 窗口激活后的补救；其它错误（无窗口 / 句柄无效）沿用原来那行。
    fn logTopmostFailure(self: *Panel, err: win_window.Error) void {
        if (err == error.TopmostRejected) {
            self.topmost_retry_pending = true;
            // `topmost-rejected` 是给验收脚本 grep 的 ASCII 锚点（PS 5.1 读不了
            // 无 BOM 的中文脚本，中文部分只给人看）。
            std.debug.print(
                "otto-lite: 置顶失败：系统拒绝（后台进程限制）topmost-rejected " ++
                    "retry_on_activate=1 state={}\n",
                .{self.settings.always_on_top},
            );
            return;
        }
        std.debug.print(
            "otto-lite: topmost={} 未应用（{s}，无窗口时正常）\n",
            .{ self.settings.always_on_top, @errorName(err) },
        );
    }

    fn logTopmostState(self: *Panel, hwnd: ?*anyopaque) void {
        const address: usize = if (hwnd) |handle| @intFromPtr(handle) else 0;
        std.debug.print(
            "otto-lite: topmost={} WS_EX_TOPMOST={} visible={} hwnd=0x{x}\n",
            .{
                self.settings.always_on_top,
                win_window.isTopmost(hwnd),
                win_window.isVisible(hwnd),
                address,
            },
        );
    }

    /// 应用保存的不透明度：启动时一次，滑块拖动的每一帧也走这里（热生效）。
    ///
    /// `opacity=255` 时窗口不在分层路径上，`getOpacity` 读回 `null`（= 完全不
    /// 透明，见 `win_window.zig` 的"255 的取舍"）；日志里 `layered=false` 就是
    /// 这件事的证据。
    pub fn applyOpacity(self: *Panel, hwnd: ?*anyopaque) void {
        const alpha = self.settings.opacity;
        if (self.d3d and alpha != 255 and !self.d3d_warned) {
            self.d3d_warned = true;
            // 机器可读的前缀（`opacity-d3d-warning`）给验收脚本 grep：这份脚本是
            // ASCII-only 的 PowerShell，认不出中文。后面那半句是给人看的。
            std.debug.print(
                "otto-lite: opacity-d3d-warning alpha={d}：--d3d（DXGI 翻转模型）" ++
                    "下层窗口透明度可能无效（SetLayeredWindowAttributes 对翻转交换链" ++
                    "不起作用）；需要半透明请去掉 --d3d（默认 GDI 上屏）\n",
                .{alpha},
            );
        }
        win_window.setOpacity(hwnd, alpha) catch |err| {
            std.debug.print(
                "otto-lite: opacity={d} 未应用（{s}，无窗口时正常）\n",
                .{ alpha, @errorName(err) },
            );
            return;
        };
        // 拖动滑块每帧都会到这里；只有值真的变了才打一行（否则日志被刷屏）。
        if (self.applied_alpha == alpha) return;
        self.applied_alpha = alpha;
        const readback = win_window.getOpacity(hwnd) catch |err| blk: {
            std.debug.print("otto-lite: opacity 读回失败（{s}）\n", .{@errorName(err)});
            break :blk null;
        };
        const address: usize = if (hwnd) |handle| @intFromPtr(handle) else 0;
        std.debug.print(
            "otto-lite: opacity={d} layered={} getOpacity={?d} visible={} hwnd=0x{x}\n",
            .{
                alpha,
                win_window.isLayered(hwnd),
                readback,
                win_window.isVisible(hwnd),
                address,
            },
        );
    }

    /// 验收探针入口（`--set-opacity=<n>`，见 `opacity_probe.zig`）：与滑块
    /// **同一条**链路——写同一个字段、调同一个 `commitOpacityPercent`（→
    /// `applyOpacity`）、用关闭面板时同一个原子写。返回写进 Win32 的 alpha。
    pub fn setOpacityPercent(self: *Panel, percent: u8, hwnd: ?*anyopaque) u8 {
        self.opacity_percent = @floatFromInt(percent);
        const alpha = self.commitOpacityPercent(hwnd);
        self.save();
        return alpha;
    }

    /// 覆盖在列表上的面板。只在 `open` 时构建；关闭后本帧不再画。
    pub fn draw(
        self: *Panel,
        c: *ui.Context,
        thumbs: *thumbs_mod.Thumbs,
        update: *update_ui.Update,
        hwnd: ?*anyopaque,
    ) void {
        if (!self.open) return;

        // 遮罩：挡住下面的列表点击；点它（而不是卡片）关闭面板。
        const shade = ui.div(c).fixed().sizeFull().bg(ui.Color.black.alpha(0.32)).layer(1);
        const shade_it = shade.interaction();

        const host = ui.div(c).fixed().offset(panel_x, panel_y).w(panel_width).layer(1);
        // 卡片自己的空白也要挡住遮罩的点击：只有卡片外面的点击才关闭面板。
        _ = host.interaction();
        ui.card(c, .{ .width = .fill, .gap = 10 });

        const header = ui.div(c).row().wFull().itemsCenter().gap(8);
        ui.text(c, "设置", .{ .size = 15, .weight = .semibold });
        ui.spacer(c);
        const close_it = ui.button(c, "关闭", .{ .variant = .ghost, .size = 11, .width = .{ .px = 48 } });
        header.end();
        ui.divider(c);

        // 置顶：点的那一帧就调用 SetWindowPos，不等关闭。
        if (ui.toggle(c, "窗口置顶", &self.settings.always_on_top)) {
            self.applyTopmost(hwnd);
        }

        // 不透明度：标签 + 百分比在同一行，滑块占满卡片内宽（380 点面板下
        // 卡片内宽 300 点，滑块与上面的文本框同宽，不会撑破）。
        const opacity_row = ui.div(c).row().wFull().itemsCenter().gap(8);
        ui.text(c, "窗口不透明度", .{ .size = 11, .color = c.theme.muted });
        ui.spacer(c);
        ui.textf(c, .{ .size = 11, .color = c.theme.muted }, "{d:.0}%", .{self.opacity_percent});
        opacity_row.end();
        // 拖动（按下）期间每帧都在改：不等关闭面板，这就是"热生效"。
        if (ui.slider(c, &self.opacity_percent, .{ .min = 0, .max = 100, .width = .fill })) {
            self.setOpacityFromSlider(hwnd);
        }

        ui.text(c, "更新源", .{ .size = 11, .color = c.theme.muted });
        _ = ui.textField(c, &self.url_field, .{
            .placeholder = "空 = 未配置",
            .width = .fill,
            .size = 11,
            // 点进去就全选：改一个已经存在的值不用先按 Ctrl+A。
            .select_all_on_focus = true,
        });

        ui.text(c, "缩略图内存预算 (MiB)", .{ .size = 11, .color = c.theme.muted });
        _ = ui.textField(c, &self.l2_field, .{
            .placeholder = "64",
            .width = .fill,
            .size = 11,
            .select_all_on_focus = true,
        });

        ui.text(c, "磁盘缓存预算 (MiB)", .{ .size = 11, .color = c.theme.muted });
        _ = ui.textField(c, &self.l3_field, .{
            .placeholder = "256",
            .width = .fill,
            .size = 11,
            .select_all_on_focus = true,
        });

        ui.text(c, "关闭面板时自动保存；置顶 / 不透明度 / 预算立即生效", .{ .size = 10, .color = c.theme.muted });

        ui.end(c); // card
        host.end();
        shade.end();

        if (close_it.clicked or shade_it.clicked) {
            c.changed = true;
            self.close(thumbs, update, hwnd);
        }
    }

    // -----------------------------------------------------------------------
    // 内部：打开时同步文本框、关闭时应用与保存
    // -----------------------------------------------------------------------

    fn syncFields(self: *Panel) void {
        self.url_field.set(self.settings.update_url orelse "");
        var buffer: [16]u8 = undefined;
        self.l2_field.set(std.fmt.bufPrint(&buffer, "{d}", .{self.settings.l2_budget_mib}) catch "64");
        self.l3_field.set(std.fmt.bufPrint(&buffer, "{d}", .{self.settings.l3_budget_mib}) catch "256");
        self.opacity_percent = settings_store.percentFromAlpha(self.settings.opacity);
    }

    /// 滑块动了：写进 `settings.opacity`，并立刻改窗口（不等关闭面板）。
    fn setOpacityFromSlider(self: *Panel, hwnd: ?*anyopaque) void {
        _ = self.commitOpacityPercent(hwnd);
    }

    /// 把 `opacity_percent` 写进设置并立刻改窗口。滑块与验收探针共用这一条，
    /// 探针不复制任何应用逻辑。返回写进设置文件的 alpha。
    fn commitOpacityPercent(self: *Panel, hwnd: ?*anyopaque) u8 {
        self.settings.opacity = settings_store.alphaFromPercent(self.opacity_percent);
        self.applyOpacity(hwnd);
        return self.settings.opacity;
    }

    fn apply(self: *Panel, thumbs: *thumbs_mod.Thumbs, update: *update_ui.Update) void {
        // URL 先应用：它和预算互不依赖，先做失败面更小的那个。
        self.settings.setUpdateUrl(self.url_field.text()) catch |err| switch (err) {
            error.UrlTooLong => std.debug.print(
                "otto-lite: 更新源超过 {d} 字节，保留上一次的值\n",
                .{settings_store.max_update_url},
            ),
            error.OutOfMemory => std.debug.print("otto-lite: 更新源保存失败（OOM）\n", .{}),
        };
        update.setUrl(self.settings.update_url);

        const l2 = parseBudget(&self.l2_field, self.settings.l2_budget_mib, "缩略图内存预算");
        const l3 = parseBudget(&self.l3_field, self.settings.l3_budget_mib, "磁盘缓存预算");
        if (l2 != self.settings.l2_budget_mib or l3 != self.settings.l3_budget_mib) {
            self.settings.l2_budget_mib = l2;
            self.settings.l3_budget_mib = l3;
            thumbs.setBudgets(self.settings.l2BudgetBytes(), self.settings.l3BudgetBytes());
        }
    }

    fn save(self: *Panel) void {
        const path = self.path orelse {
            std.debug.print("otto-lite: settings 无数据目录，本次不写盘\n", .{});
            return;
        };
        self.settings.save(self.io, path) catch |err| {
            std.debug.print(
                "otto-lite: settings 保存失败 path={s}（{s}），本次运行仍生效\n",
                .{ path, @errorName(err) },
            );
            return;
        };
        var buffer: [256]u8 = undefined;
        std.debug.print(
            "otto-lite: settings saved path={s} {s}\n",
            .{ path, self.settings.describe(&buffer) },
        );
    }
};

/// 文本框 → MiB。空串表示"不改"；非数字也是不改（并打一行），不静默变成 0。
fn parseBudget(field: *const ui.TextBuffer, fallback: u32, label: []const u8) u32 {
    const text = std.mem.trim(u8, field.text(), " \t\r\n");
    if (text.len == 0) return fallback;
    const value = std.fmt.parseInt(u32, text, 10) catch {
        std.debug.print("otto-lite: {s} 不是整数，保留 {d}MiB\n", .{ label, fallback });
        return fallback;
    };
    return @min(value, settings_store.max_budget_mib);
}
