//! 设置面板：置顶 / 更新源 / 两级缓存预算。
//!
//! 分工与 `search_ui.zig` / `preview_panel.zig` 相同：
//!   * 本文件拥有**面板的临时编辑状态**（三个 `TextBuffer`）与打开/关闭；
//!   * 值的真相在 `settings_store.Settings`（持久化）与 `Settings` 指向的运行时
//!     对象（`Thumbs` 的预算、`Update` 的 URL）；
//!   * "改完立即生效"在关闭时落地：置顶在开关被点的那一帧就调用 Win32，URL 交给
//!     `Update.setUrl`，L2 / L3 预算交给 `Thumbs.setBudgets`；随后原子写设置文件。
//!
//! ## 布局（380 点时）
//!
//! 面板是 `ui.card`，绝对定位覆盖在列表上（不参与列表布局，搜索框宽度不变）。
//! 底层还有一层半透明遮罩：点遮罩关闭面板，也挡住它下面的列表点击。
//! 控件从上到下：标题 + 「关闭」、「窗口置顶」开关、更新源、「缩略图内存预算
//! (MiB)」、「磁盘缓存预算 (MiB)」。
//!
//! ## 为什么关闭时才写盘
//!
//! 拖滚动条/打字时每个字符都写一次文件既慢又制造无意义的 `.tmp` 替换。值在关闭
//! 时一次应用、一次原子写；置顶是例外——它必须从点击那一帧起就真的置顶。

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

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        settings: settings_store.Settings,
        path: ?[]const u8,
    ) !Panel {
        const owned_path: ?[]u8 = if (path) |value| try allocator.dupe(u8, value) else null;
        errdefer if (owned_path) |value| allocator.free(value);
        var panel = Panel{
            .allocator = allocator,
            .io = io,
            .settings = settings,
            .path = owned_path,
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

    pub fn alwaysOnTop(self: *const Panel) bool {
        return self.settings.always_on_top;
    }

    /// 打开面板：文本框回到**已保存**的值（上一次没关闭的编辑不保留）。
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

    /// 启动时应用一次保存的置顶状态；面板里的开关也走这里。
    pub fn applyTopmost(self: *Panel, hwnd: ?*anyopaque) void {
        const state = self.settings.always_on_top;
        win_window.setTopmost(hwnd, state) catch |err| {
            std.debug.print(
                "otto-lite: topmost={} 未应用（{s}，无窗口时正常）\n",
                .{ state, @errorName(err) },
            );
            return;
        };
        const address: usize = if (hwnd) |handle| @intFromPtr(handle) else 0;
        std.debug.print(
            "otto-lite: topmost={} WS_EX_TOPMOST={} hwnd=0x{x}\n",
            .{ state, win_window.isTopmost(hwnd), address },
        );
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

        ui.text(c, "关闭面板时自动保存；预算立即生效", .{ .size = 10, .color = c.theme.muted });

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
