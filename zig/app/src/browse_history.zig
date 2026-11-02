//! 按目录记录的浏览历史。每个节点只在离开该目录时保存一份选中快照，
//! 所以内存随历史深度增长，不随目录行数增长。返回时按 File ID 核验，路径只用于定位。

const std = @import("std");
const core = @import("otto_core");
const selection_mod = @import("selection.zig");
const select_mod = @import("browse_select.zig");
const types = @import("browse_types.zig");

pub const Memory = struct {
    identity: ?core.model.FileIdentity,
    path: []u8,
};

pub const Record = struct {
    path: []u8,
    selected: ?Memory = null,
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
        for (self.records.items) |record| freeRecord(self.allocator, record);
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

    /// 离开当前目录前调用；覆盖该节点旧快照，避免保留已失效的身份/路径。
    pub fn remember(
        self: *History,
        io: std.Io,
        entries: []types.Entry,
        selected: *const selection_mod.Selection,
        unreadable: *u32,
    ) error{OutOfMemory}!void {
        const record = self.currentMut();
        if (record.selected) |memory| self.allocator.free(memory.path);
        record.selected = null;
        const index = selectedIndex(entries.len, selected) orelse return;
        const identity = select_mod.identityFor(io, entries, index, unreadable);
        const path = try self.allocator.dupe(u8, entries[index].path);
        record.selected = .{ .identity = identity, .path = path };
    }

    /// 新目录成为当前节点，截掉前进分支。路径全栈唯一：已有节点移到栈顶，
    /// 保留它自己的选中快照；Back 仍回到刚离开的那个目录。
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
        errdefer freeRecord(self.allocator, record);
        if (found) |index| {
            if (index < self.index) self.index -= 1;
        }
        var tail = self.records.items.len;
        while (tail > self.index + 1) {
            tail -= 1;
            freeRecord(self.allocator, self.records.items[tail]);
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

    /// 只扫描到路径候选即停止；身份核验至多打开一次句柄，不为恢复选中而扫 10 万句柄。
    pub fn restore(
        self: *History,
        io: std.Io,
        entries: []types.Entry,
        selected: *selection_mod.Selection,
        unreadable: *u32,
    ) error{OutOfMemory}!void {
        try selected.resize(self.allocator, entries.len);
        selected.clear();
        const memory = self.current().selected orelse return;
        for (entries, 0..) |entry, index| {
            if (entry.deleted or !std.ascii.eqlIgnoreCase(entry.path, memory.path)) continue;
            if (memory.identity) |expected| {
                const actual = select_mod.identityFor(io, entries, index, unreadable) orelse return;
                if (!expected.eql(actual)) return; // 同路径但已被替换，不冒充原选中项。
            }
            selected.selectOnly(index);
            return;
        }
    }
};

fn selectedIndex(len: usize, selected: *const selection_mod.Selection) ?usize {
    if (selected.cursor) |cursor| if (cursor < len) return cursor;
    var index: usize = 0;
    while (index < @min(len, selected.len())) : (index += 1) {
        if (selected.bits.isSet(index)) return index;
    }
    return null;
}

fn freeRecord(allocator: std.mem.Allocator, record: Record) void {
    if (record.selected) |memory| allocator.free(memory.path);
    allocator.free(record.path);
}
