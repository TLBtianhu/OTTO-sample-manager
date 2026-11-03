//! Unified Open entry: an in-app two-choice row leads to the multi-file picker
//! or the existing folder picker. Both choices use the same Import state machine
//! as drag-in: files stay a file batch, one folder keeps its folder hierarchy.
const std = @import("std");
const nanoui = @import("nanoui");
const folder_picker = @import("otto_folder_picker");
const import_ui = @import("import_ui.zig");
const ui = nanoui.ui;

pub fn toggle(open: *bool, c: *ui.Context) void {
    open.* = !open.*;
    c.changed = true;
}

/// Drawn only after the user chooses Open. No native dialog is created here;
/// tests use OTTO_NO_DIALOG=1, either cancelling or supplying scripted paths.
pub fn frame(c: *ui.Context, open: *bool, import: *import_ui.Import, owner: ?*anyopaque) void {
    if (!open.*) return;
    const row = ui.div(c).row().gap(8).px(12).py(4);
    defer row.end();
    const files = ui.button(c, "选择文件…", .{ .size = 13 });
    if (files.clicked) {
        open.* = false;
        c.changed = true;
        beginFiles(import, owner);
    }
    const folder = ui.button(c, "选择文件夹…", .{ .size = 13 });
    if (folder.clicked) {
        open.* = false;
        c.changed = true;
        beginFolder(import, owner);
    }
}

fn beginFolder(import: *import_ui.Import, owner: ?*anyopaque) void {
    if (import.busy()) return;
    const scripted_paths = scriptedPaths(import, "OTTO_TEST_OPEN_FOLDER") catch {
        import.fail("导入失败：OutOfMemory", .{});
        return;
    };
    if (scripted_paths) |paths| {
        defer folder_picker.freePaths(import.allocator, paths);
        if (paths.len != 1) {
            import.fail("打开文件夹测试夹具必须恰好给一个路径", .{});
            return;
        }
        std.debug.print("otto-lite: 打开文件夹（测试选择）path={s}\n", .{paths[0]});
        import.start(paths[0]);
        return;
    }
    import.begin(owner);
}

fn beginFiles(import: *import_ui.Import, owner: ?*anyopaque) void {
    if (import.busy()) return;
    const scripted_paths = scriptedPaths(import, "OTTO_TEST_OPEN_FILES") catch {
        import.fail("导入失败：OutOfMemory", .{});
        return;
    };
    if (scripted_paths) |paths| {
        defer folder_picker.freePaths(import.allocator, paths);
        std.debug.print("otto-lite: 打开文件（测试选择）files={d}\n", .{paths.len});
        import.startFiles(paths);
        return;
    }
    const paths = folder_picker.pickFilesForWindow(import.allocator, owner) catch |err| {
        switch (err) {
            error.Cancelled => std.debug.print("otto-lite: 打开文件取消（不算错误）\n", .{}),
            error.OutOfMemory => import.fail("导入失败：OutOfMemory", .{}),
            error.OleFailure => {
                std.debug.print(
                    "otto-lite: 文件对话框失败 hresult=0x{x:0>8}\n",
                    .{@as(u32, @bitCast(folder_picker.lastHresult()))},
                );
                import.fail("打开文件对话框失败（OleFailure）", .{});
            },
        }
        return;
    };
    defer folder_picker.freePaths(import.allocator, paths);
    std.debug.print("otto-lite: 打开文件 files={d}\n", .{paths.len});
    import.startFiles(paths);
}

/// Controlled selection for hidden UI tests. It is ignored unless the existing
/// OTTO_NO_DIALOG guard is also set, so a normal launch can never be redirected.
/// OTTO_TEST_OPEN_FILES uses '|' (not legal in a Windows filename) as separator;
/// OTTO_TEST_OPEN_FOLDER contains exactly one folder.
fn scriptedPaths(import: *import_ui.Import, name: []const u8) error{OutOfMemory}!?[][]u8 {
    const allocator = import.allocator;
    var map = std.process.Environ.createMap(.{ .block = .global }, allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unexpected => return null,
    };
    defer map.deinit();
    if (!folder_picker.envEnabled(map.get("OTTO_NO_DIALOG"))) return null;
    const text = map.get(name) orelse return null;
    var out: std.ArrayList([]u8) = .empty;
    defer out.deinit(allocator);
    errdefer for (out.items) |path| allocator.free(path);
    var parts = std.mem.splitScalar(u8, text, '|');
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        const path = try allocator.dupe(u8, part);
        out.append(allocator, path) catch |err| {
            allocator.free(path);
            return err;
        };
    }
    if (out.items.len == 0) return null;
    return try out.toOwnedSlice(allocator);
}
