//! 浏览模式的 UI 动作接线；放在 main/row_ui 之外，避免两个文件继续长大。
const std = @import("std");
const nanoui = @import("nanoui");
const browse_ui = @import("browse_ui.zig");
const transport = @import("transport.zig");
const State = @import("main.zig").State;
const ui = nanoui.ui;

pub fn handleKeys(s: *State, c: *ui.Context) void {
    const session = s.browse orelse return;
    if (c.shortcut(.{ .key = ui.Shortcut.left, .alt = true })) {
        session.goBack(&s.selection) catch |err| {
            logFailure("back", err);
            return;
        };
        afterNavigation(s);
        return;
    }
    if (c.shortcut(.{ .key = ui.Shortcut.right, .alt = true })) {
        session.goForward(&s.selection) catch |err| {
            logFailure("forward", err);
            return;
        };
        afterNavigation(s);
        return;
    }
    if (c.shortcut(.{ .key = ui.Shortcut.up, .alt = true })) {
        session.goUp(&s.selection) catch |err| {
            logFailure("up", err);
            return;
        };
        afterNavigation(s);
        return;
    }
    if (c.input.key == .backspace and !c.input.alt and !c.input.ctrl and !s.search.focused) {
        c.input.key = null;
        session.goUp(&s.selection) catch |err| {
            logFailure("up", err);
            return;
        };
        afterNavigation(s);
    }
}

pub fn handleToolbar(s: *State, c: *ui.Context, action: browse_ui.Action) void {
    const session = s.browse orelse return;
    var navigated = false;
    if (action.back) {
        session.goBack(&s.selection) catch |err| {
            logFailure("back", err);
            return;
        };
        navigated = true;
    } else if (action.forward) {
        session.goForward(&s.selection) catch |err| {
            logFailure("forward", err);
            return;
        };
        navigated = true;
    } else if (action.up) {
        session.goUp(&s.selection) catch |err| {
            logFailure("up", err);
            return;
        };
        navigated = true;
    }
    if (navigated) afterNavigation(s);
    if (action.copy_path) {
        transport.copyPath(c.alloc(), session.rootPath()) catch |err| {
            std.debug.print("otto-lite: 复制路径失败（{s}）\n", .{@errorName(err)});
            return;
        };
        std.debug.print("otto-lite: 已复制目录路径 {s}\n", .{session.rootPath()});
    }
    if (action.sort) |key| {
        if (key == session.sortKey()) return;
        session.setSort(key, &s.selection) catch |err| {
            std.debug.print("otto-lite: 排序失败（{s}）\n", .{@errorName(err)});
            return;
        };
        // 只是行顺序变化：媒体身份与缓存仍有效，不能顺手清空。
        s.samples = session.samples();
        s.search.markStale();
        s.selection.resize(s.gpa, s.samples.len) catch {};
    }
}

pub fn enterAt(s: *State, index: usize) void {
    const session = s.browse orelse return;
    session.enterDirectory(index, &s.selection) catch |err| {
        logFailure("enter", err);
        return;
    };
    afterNavigation(s);
}

/// Enter：目录返回 true（已导航），文件返回 false（继续走媒体预览）。
pub fn activateCursor(s: *State, index: usize) bool {
    const session = s.browse orelse return false;
    if (!session.isDirectory(index)) return false;
    enterAt(s, index);
    return true;
}

fn afterNavigation(s: *State) void {
    afterModelChange(s);
    s.preview.sync(null, .{});
}

fn afterModelChange(s: *State) void {
    const session = s.browse orelse return;
    s.samples = session.samples();
    s.search.markStale();
    s.thumbs.clearFailures();
    s.duration_trust.clear();
    s.selection.resize(s.gpa, s.samples.len) catch {};
}

fn logFailure(action: []const u8, err: anyerror) void {
    std.debug.print("otto-lite: 浏览导航拒绝 action={s} reason={s}\n", .{ action, @errorName(err) });
}
