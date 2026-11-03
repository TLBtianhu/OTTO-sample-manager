//! 按目录记录的浏览历史。每个节点只在离开该目录时保存一份选择快照与滚动偏移。
//! 选择复用 `browse_select.Tracker`：整组按 File ID 恢复，无身份才退到路径，绝不按行号。
//! 所有状态只在内存；每个选择快照最多 `browse_types.hard_limit` 项，进程结束即释放。

const std = @import("std");
const selection_mod = @import("selection.zig");
const select_mod = @import("browse_select.zig");
const types = @import("browse_types.zig");

pub const Record = struct {
    path: []u8,
    /// 整个多选集合 + 光标 + Shift 锚点；不是只记一个“当前文件”。
    selection: ?select_mod.Tracker = null,
    /// 本目录最后一次可见滚动位置（点）。由 UI 每帧记，导航后夹到合法范围。
    scroll_offset: f32 = 0,
};

pub const History = struct {
    allocator: std.mem.Allocator,
    records: std.ArrayListUnmanaged(Record) = .empty,
    index: usize = 0,

    pub fn init(allocator: std.mem.Allocator, root: []const u8) error{OutOfMemory}!History {
        var self = History{ .allocator = allocator };
        errdefer self.deinit();
        try self.records.append(allocator, .{ .path = try allocator.dupe(u8, root) });
        return self;
    }

    pub fn deinit(self: *History) void {
        for (self.records.items) |*record| freeRecord(self.allocator, record);
        self.records.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn current(self: *const History) *const Record {
        return &self.records.items[self.index];
    }

    pub fn currentMut(self: *History) *Record {
        return &self.records.items[self.index];
    }

    pub fn canBack(self: *const History) bool {
        return self.index > 0;
    }

    pub fn canForward(self: *const History) bool {
        return self.index + 1 < self.records.items.len;
    }

    pub fn len(self: *const History) usize {
        return self.records.items.len;
    }

    /// 离开当前目录前调用；覆盖旧快照，避免保留已失效的身份/路径。
    pub fn remember(
        self: *History,
        io: std.Io,
        entries: []types.Entry,
        selected: *const selection_mod.Selection,
        unreadable: *u32,
    ) error{OutOfMemory}!void {
        const record = self.currentMut();
        if (record.selection == null) record.selection = select_mod.Tracker.init(self.allocator);
        try record.selection.?.capture(io, entries, selected, unreadable);
    }

    /// 新目录成为当前节点，截掉前进分支。路径全栈唯一：已有节点移到栈顶，
    /// 保留它自己的选择/滚动快照；Back 仍回到刚离开的那个目录。
    pub fn push(self: *History, path: []const u8) error{OutOfMemory}!bool {
        if (std.ascii.eqlIgnoreCase(self.current().path, path)) return false;
        var found: ?usize = null;
        for (self.records.items, 0..) |record, index| {
            if (std.ascii.eqlIgnoreCase(record.path, path)) {
                found = index;
                break;
            }
        }
        const record = if (found) |index|
            self.records.orderedRemove(index)
        else
            Record{ .path = try self.allocator.dupe(u8, path) };
        errdefer {
            var doomed = record;
            freeRecord(self.allocator, &doomed);
        }
        if (found) |index| {
            if (index < self.index) self.index -= 1;
        }
        var tail = self.records.items.len;
        while (tail > self.index + 1) {
            tail -= 1;
            freeRecord(self.allocator, &self.records.items[tail]);
        }
        self.records.shrinkRetainingCapacity(self.index + 1);
        try self.records.append(self.allocator, record);
        self.index = self.records.items.len - 1;
        return true;
    }

    pub fn back(self: *History) bool {
        if (!self.canBack()) return false;
        self.index -= 1;
        return true;
    }

    pub fn forward(self: *History) bool {
        if (!self.canForward()) return false;
        self.index += 1;
        return true;
    }

    /// 新目录枚举完成后恢复整组选择。Tracker 至多为选中行取身份，不扫全目录句柄。
    pub fn restore(
        self: *History,
        io: std.Io,
        entries: []types.Entry,
        selected: *selection_mod.Selection,
        unreadable: *u32,
    ) error{OutOfMemory}!void {
        _ = io;
        _ = unreadable;
        try selected.resize(self.allocator, entries.len);
        selected.clear();
        if (self.currentMut().selection) |*tracker| try tracker.restore(entries, selected);
    }
};

fn freeRecord(allocator: std.mem.Allocator, record: *Record) void {
    if (record.selection) |*tracker| tracker.deinit();
    allocator.free(record.path);
}
