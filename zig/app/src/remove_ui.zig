//! 「从库中移除」的 UI 胶水：选中目标 → 核心纯变换 → OTTOLIB 原子保存 → 重载。
//! 只写库文件，不调用任何源文件/源目录写入口；浏览模式没有该入口。
const std = @import("std");
const nanoui = @import("nanoui");
const core = @import("otto_core");
const import_target = @import("import_target.zig");
const window_util = @import("window_util.zig");
const win_window = @import("otto_win_window");
const State = @import("main.zig").State;
const ui = nanoui.ui;

pub const Selection = struct {
    allocator: std.mem.Allocator,
    folder_path: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator) Selection {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Selection) void {
        self.clearFolder();
        self.* = undefined;
    }

    pub fn clearFolder(self: *Selection) void {
        if (self.folder_path) |path| self.allocator.free(path);
        self.folder_path = null;
    }

    fn selectFolder(self: *Selection, path: []const u8) !void {
        const copy = try self.allocator.dupe(u8, path);
        self.clearFolder();
        self.folder_path = copy;
    }
};

pub fn folderSelected(s: *const State, path: []const u8) bool {
    const selected = s.remove.folder_path orelse return false;
    return std.mem.eql(u8, selected, path);
}

/// 文件夹单击仍然展开/收起，同时把“移除”目标切到这个节点；样本多选互斥。
pub fn folderClicked(s: *State, c: *ui.Context, row: usize) void {
    const folder = s.search.folderAt(row) orelse return;
    s.remove.selectFolder(folder.path) catch return;
    s.selection.clear();
    if (s.search.toggleFolder(row)) s.settings.saveViewState();
    std.debug.print("otto-lite: selected folder={s}\n", .{folder.path});
    c.changed = true;
}

/// Delete 只从列表接管；搜索框聚焦时必须保留文本编辑的 Delete 语义。
/// Esc 清掉文件夹目标；其它情况仍交给搜索框原来的两步 Esc。
pub fn handleKey(s: *State, c: *ui.Context) bool {
    if (s.browse != null or s.search.focused) return false;
    const key = c.input.key orelse return false;
    if (key == .escape and s.remove.folder_path != null) {
        c.input.key = null;
        s.remove.clearFolder();
        s.selection.clear();
        c.changed = true;
        return true;
    }
    if (key != .delete) return false;
    if (s.selection.count() == 0 and s.remove.folder_path == null) return false;
    c.input.key = null;
    removeCurrent(s, c);
    return true;
}

pub fn canRemove(s: *const State) bool {
    return s.browse == null and !s.import.busy() and
        (s.selection.count() != 0 or s.remove.folder_path != null);
}

pub fn removeCurrent(s: *State, c: *ui.Context) void {
    if (!canRemove(s)) return;
    const folder_count: usize = if (s.remove.folder_path != null) 1 else 0;
    const sample_count = s.selection.count();
    const targets = s.gpa.alloc(core.removal.Target, sample_count + folder_count) catch {
        s.import.fail("移除失败：OutOfMemory", .{});
        return;
    };
    defer s.gpa.free(targets);
    const indices = s.selection.selectedIndices(s.gpa) catch {
        s.import.fail("移除失败：OutOfMemory", .{});
        return;
    };
    defer s.gpa.free(indices);
    for (indices, 0..) |index, n| {
        if (index >= s.samples.len) return;
        // 立即固定 Sample.id；后续重扫/排序/分页不会让目标漂到另一行。
        targets[n] = .{ .sample_id = s.samples[index].id };
    }
    if (s.remove.folder_path) |path| targets[targets.len - 1] = .{ .folder_path = path };

    var result = core.removal.apply(s.gpa, s.session.library(), targets) catch |err| {
        s.import.fail("移除失败：{s}", .{@errorName(err)});
        return;
    };
    defer result.deinit();
    if (result.report.samples == 0 and result.report.folders == 0) return;

    var target = import_target.resolve(s.gpa, s.session.path(), null) catch {
        s.import.fail("移除失败：OutOfMemory", .{});
        return;
    };
    defer target.deinit(s.gpa);
    _ = s.session.save(target.path, &result.library) catch |err| {
        s.import.fail("移除失败：{s}", .{@errorName(err)});
        return;
    };

    // 保存已经成功，先停掉并清掉当前预览/播放，再销毁旧 Library/Live。
    // Panel 的 generation 递增后，工作线程旧结果也不会落回新选择。
    s.preview.sync(null, .{});
    s.session.reloadSaved(target.path) catch |err| {
        s.import.fail("移除已保存，但重载失败：{s}", .{@errorName(err)});
        return;
    };
    s.afterReload();
    s.import.phase = .idle;
    s.flash_left = 10;
    s.flash_count = result.report.samples;
    s.flash_remove = true;
    std.debug.print(
        "otto-lite: 已从库中移除 samples={d} folders={d} exclusions={d} file={s}\n",
        .{ result.report.samples, result.report.folders, result.library.exclusions.len, target.path },
    );
    const hwnd = window_util.nativeHandle(s.window);
    std.debug.print("otto-lite: remove-window visible={} foreground={}\n", .{
        win_window.isVisible(hwnd),
        win_window.isForeground(hwnd),
    });
    c.changed = true;
}
