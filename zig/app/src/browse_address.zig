//! 可编辑地址栏、面包屑与驱动器下拉的界面状态。没有自动补全，也没有输入期磁盘 IO。
const std = @import("std");
const nanoui = @import("nanoui");
const model = @import("browse_address_model.zig");
const crumbs = @import("browse_crumbs.zig");
const drives_mod = @import("browse_drives.zig");
const ui = nanoui.ui;

pub const Action = struct {
    submit: bool = false,
    crumb: ?usize = null,
    drive: ?u8 = null,
};

pub const Bar = struct {
    editor: model.Editor = .{},
    buffer: ui.TextBuffer = .{},
    focused: bool = false,
    drives_open: bool = false,

    pub fn init(root: []const u8) Bar {
        var self = Bar{};
        self.editor.cancel(root);
        self.buffer.set(root);
        return self;
    }

    pub fn deinit(self: *Bar) void {
        self.buffer.deinit();
    }

    pub fn keyboardOwned(self: *const Bar) bool {
        return self.editor.editing or self.focused;
    }

    pub fn text(self: *const Bar) []const u8 {
        return self.editor.text();
    }

    pub fn failure(self: *const Bar) ?[]const u8 {
        return self.editor.failure;
    }

    pub fn submitted(self: *Bar, c: *ui.Context, root: []const u8, err: ?anyerror) void {
        if (err) |submit_error| {
            self.editor.fail(submit_error);
            return;
        }
        self.editor.finish(root);
        self.buffer.set(root);
        self.focused = false;
        self.drives_open = false;
        c.focus = 0;
        c.changed = true;
    }

    pub fn navigated(self: *Bar, root: []const u8) void {
        self.editor.finish(root);
        self.buffer.set(root);
        self.focused = false;
        self.drives_open = false;
    }

    pub fn toggleDrives(self: *Bar, drives: *drives_mod.List) void {
        self.drives_open = !self.drives_open;
        if (self.drives_open) drives.* = drives_mod.enumerate();
    }

    /// 画在工具条地址区域。Ctrl+L 聚焦并全选；Esc 在 nanoui 看到按键前取消编辑。
    pub fn drawField(self: *Bar, c: *ui.Context, root: []const u8) Action {
        var action = Action{};
        if (c.shortcut(.{ .key = 'l', .ctrl = true })) {
            self.editor.begin(root);
            self.buffer.set(root);
            self.buffer.want_selection = .{ 0, root.len };
            self.buffer.focus();
            c.changed = true;
        }
        if (self.editor.editing and c.input.key == .escape) {
            c.input.key = null;
            self.editor.cancel(root);
            self.buffer.set(root);
            self.focused = false;
            c.focus = 0;
            c.changed = true;
        }

        if (self.editor.editing) {
            const result = ui.textField(c, &self.buffer, .{
                .placeholder = "输入目录路径，Enter 跳转",
                .width = .fill,
                .size = 11,
                .select_all_on_focus = true,
            });
            self.focused = result.focused;
            if (result.changed or result.submitted) self.editor.set(self.buffer.text()) catch {};
            if (result.submitted) {
                c.input.key = null; // 不许同一次 Enter 又激活旧列表行。
                action.submit = true;
            }
            return action;
        }

        self.focused = false;
        const slots = crumbs.visibleCount(root);
        for (0..slots) |slot| {
            if (slot > 0) ui.text(c, "\\", .{ .size = 10, .color = c.theme.muted });
            const index = crumbs.visibleIndex(root, slot) orelse {
                ui.text(c, "…", .{ .size = 10, .color = c.theme.muted });
                continue;
            };
            const path = crumbs.pathAt(root, index).?;
            const it = smallPressable(c);
            ui.text(c, crumbs.label(path), .{
                .size = 10,
                .color = if (index + 1 == crumbs.count(root)) c.theme.text else c.theme.muted,
                .truncate = .ellipsis,
            });
            ui.end(c);
            if (it.clicked) action.crumb = index;
        }
        return action;
    }

    /// 内联下拉，不开系统弹窗。虚拟列表把 26 个盘也限制在 110 点高。
    pub fn drawDrives(self: *Bar, c: *ui.Context, drives: *const drives_mod.List) ?u8 {
        if (!self.drives_open) return null;
        var selected: ?u8 = null;
        const height = @min(110.0, 24.0 * @as(f32, @floatFromInt(drives.len)));
        var rows = ui.list(c, .{
            .count = drives.len,
            .row_height = 24,
            .height = .{ .px = height },
        });
        while (rows.next()) |index| {
            const drive = drives.items[index];
            var root_buffer: [3]u8 = undefined;
            const root = drive.root(&root_buffer);
            const label = std.fmt.allocPrint(c.alloc(), "{s}  {s}{s}", .{
                root,
                drive.kind.label(),
                if (drive.available or drive.kind == .no_root) "" else "（不可访问）",
            }) catch continue;
            const it = ui.button(c, label, .{ .variant = .ghost, .width = .fill, .size = 10 });
            if (it.clicked) selected = drive.letter;
        }
        rows.end();
        if (selected != null) self.drives_open = false;
        return selected;
    }
};

fn smallPressable(c: *ui.Context) ui.Interaction {
    return ui.pressable(c, .{
        .height = .{ .px = 18 },
        .padding = .xy(2, 0),
        .radius = 5,
        .align_items = .center,
    }, c.theme.surface_hover);
}
