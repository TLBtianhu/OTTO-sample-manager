//! 浏览模式的**选中项跟踪**：变更前后按"身份（卷+文件索引）→ 路径"把选中的行找回来。
//!
//! 从 `browse.zig` 拆出来，因为它是一段**可以单独讲清楚**的算法，而且只碰
//! `Entry` 切片与 `Selection`，不碰线程、批次、监听：
//!
//!   1. `capture`：改动**之前**把选中集合 + 光标 + 锚点各自记成一把键
//!      `身份（有的话）+ 路径 + 旧行号`。取身份要打开句柄——只对选中行做，
//!      5 万行目录里 99.99% 的行从不被选中；
//!   2. `restore`：改动之后单趟扫 `entries`，用两张小表（身份哈希 / 路径）找回
//!      每一把键；墓碑行（`deleted`）不参与——选中项要离开被删掉的那一行；
//!   3. 光标那一行被删掉时，落到相邻的存活行（先往后、到末尾再往前）。
//!
//! 为什么必须有这一层：变更事件会让行号整体移动（删一行，后面全部前移），
//! 而"选中项"是用户的意图，不是行号。按行号记会在下一次删除时指到别的文件。

const std = @import("std");
const core = @import("otto_core");
const browse_dir = @import("otto_browse_dir");
const selection_mod = @import("selection.zig");
const types = @import("browse_types.zig");

const Entry = types.Entry;

/// 一个选中项的追踪键：身份（优先）+ 路径（退化 / 改名后仍能找到）。
pub const Key = struct {
    identity: ?core.model.FileIdentity,
    path: []const u8,
    /// 记下它时在旧视图里的行号：光标/锚点与选中行是同一行时只留一把键。
    old_index: usize,
};

/// 一次 `poll` 里记下的追踪状态。
pub const Capture = struct {
    keys: std.ArrayListUnmanaged(Key) = .empty,
    /// `keys[0..selected_count]` 是选中集合；其后是光标与锚点各自的槽位。
    selected_count: usize = 0,
    cursor_slot: ?usize = null,
    anchor_slot: ?usize = null,
    /// 旧视图里"当前行"的下标：它的文件被删时用来找相邻行。
    tracked_index: ?usize = null,
    /// 被删的当前行留在列表里的位置（墓碑）；`restore` 从它往两边找存活行。
    tombstone_index: ?usize = null,
};

pub const Tracker = struct {
    arena: std.heap.ArenaAllocator,
    /// 最近一次 `capture` 记下的东西（`restore` 读它）。字段叫 `state` 而不是
    /// `capture`：`capture()` 是方法名，同名会让 Zig 报 "duplicate struct member"。
    state: Capture = .{},

    pub fn init(allocator: std.mem.Allocator) Tracker {
        return .{ .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn deinit(self: *Tracker) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// 丢掉上一次的记录（`restore` 完成后调用：键字符串在下一次 `capture` 才复用）。
    pub fn reset(self: *Tracker) void {
        self.state = .{};
    }

    /// 变更前记下选中集合 + 光标 + 锚点。
    ///
    /// `unreadable` 是给会话的计数：打不开的文件仍然留在列表里（和资源管理器一致），
    /// 只是拿不到身份——这件事必须计数，不静默。
    pub fn capture(
        self: *Tracker,
        io: std.Io,
        entries: []Entry,
        sel: *const selection_mod.Selection,
        unreadable: *u32,
    ) error{OutOfMemory}!void {
        _ = self.arena.reset(.retain_capacity);
        self.state = .{};

        self.state.tracked_index = sel.cursor orelse blk: {
            var i: usize = 0;
            while (i < sel.len()) : (i += 1) {
                if (sel.bits.isSet(i)) break :blk i;
            }
            break :blk null;
        };

        var i: usize = 0;
        while (i < sel.len()) : (i += 1) {
            if (!sel.bits.isSet(i)) continue;
            if (i >= entries.len) break;
            try self.state.keys.append(self.arena.allocator(), try self.keyFor(io, self.arena.allocator(), entries, i, unreadable));
        }
        self.state.selected_count = self.state.keys.items.len;

        // 光标与锚点常常**就是**某一条选中行。同一个行号只能有一把键：`restore` 的
        // 身份→槽位表是"一把键一个槽"，重复的键会把前一个槽挤掉（真踩过：选中
        // 一行时 keys 里有三个同身份副本，找回后 cursor 变 null）。
        if (sel.cursor) |cursor| {
            if (cursor < entries.len) {
                self.state.cursor_slot = try self.slotFor(io, entries, cursor, unreadable);
            }
        }
        if (sel.anchor) |anchor| {
            if (anchor < entries.len) {
                self.state.anchor_slot = try self.slotFor(io, entries, anchor, unreadable);
            }
        }
    }

    /// 这个行号的键在 `keys` 里的槽位（没有就追加）。按旧行号去重，不走内容比较。
    fn slotFor(self: *Tracker, io: std.Io, entries: []Entry, index: usize, unreadable: *u32) error{OutOfMemory}!usize {
        for (self.state.keys.items, 0..) |key, slot| {
            if (key.old_index == index) return slot;
        }
        const slot = self.state.keys.items.len;
        try self.state.keys.append(self.arena.allocator(), try self.keyFor(io, self.arena.allocator(), entries, index, unreadable));
        return slot;
    }

    fn keyFor(
        _: *Tracker,
        io: std.Io,
        arena: std.mem.Allocator,
        entries: []Entry,
        index: usize,
        unreadable: *u32,
    ) error{OutOfMemory}!Key {
        return .{
            .identity = identityFor(io, entries, index, unreadable),
            .path = try arena.dupe(u8, entries[index].path),
            .old_index = index,
        };
    }

    /// 变更后把选中项放回去：先按身份、再看路径；都找不到就落到相邻的存活行。
    pub fn restore(self: *Tracker, entries: []const Entry, sel: *selection_mod.Selection) error{OutOfMemory}!void {
        const arena = self.arena.allocator();
        const keys = self.state.keys.items;
        sel.clearBits();
        if (keys.len == 0) {
            sel.cursor = null;
            return;
        }
        const found = try arena.alloc(?usize, keys.len);
        @memset(found, null);

        var identities = std.AutoHashMapUnmanaged(u64, usize){};
        var paths = std.StringHashMapUnmanaged(usize){};
        for (keys, 0..) |key, slot| {
            if (key.identity) |identity| try identities.put(arena, types.identityHash(identity), slot);
            try paths.put(arena, key.path, slot);
        }

        // 单趟扫条目：路径命中先记，身份命中后写（身份胜过路径——同名可能是别的文件）。
        // 墓碑行不参与：选中项要离开被删的那一行。
        for (entries, 0..) |entry, index| {
            if (entry.deleted) continue;
            if (paths.get(entry.path)) |slot| found[slot] = index;
            if (entry.identity) |identity| {
                if (identities.get(types.identityHash(identity))) |slot| {
                    if (keys[slot].identity.?.eql(identity)) found[slot] = index;
                }
            }
        }

        var first: ?usize = null;
        for (found[0..@min(self.state.selected_count, found.len)]) |maybe| {
            if (maybe) |index| {
                sel.add(index);
                if (first == null) first = index;
            }
        }

        var cursor: ?usize = null;
        if (self.state.cursor_slot) |slot| {
            if (slot < found.len) cursor = found[slot];
        }
        // 光标那一行被删了：落到相邻的存活行（墓碑那一格不选）。
        const final_cursor = cursor orelse adjacent(entries, self.state.tombstone_index);
        sel.cursor = final_cursor;
        if (self.state.anchor_slot) |slot| {
            if (slot < found.len) sel.anchor = found[slot];
        }
        if (sel.count() == 0) {
            if (final_cursor) |value| {
                sel.add(value);
                sel.anchor = value;
            }
        } else if (sel.anchor == null) {
            sel.anchor = first;
        }
    }
};

/// 取一行的身份：第一次调用会打开句柄问一次，之后就是缓存值。
///
/// 打不开（权限拒绝 / 被独占 / 已删除）**不是**错误：那一行仍然留在列表里，
/// 只是退回路径键，并计进 `unreadable`。
pub fn identityFor(io: std.Io, entries: []Entry, index: usize, unreadable: *u32) ?core.model.FileIdentity {
    const entry = &entries[index];
    if (entry.identity) |identity| return identity;
    if (entry.deleted) return null;
    const found = browse_dir.identityOf(io, entry.path) catch {
        unreadable.* +|= 1;
        return null;
    };
    const identity = found orelse return null;
    const converted = core.model.FileIdentity{
        .volume_serial = identity.volume_serial,
        .file_index = identity.file_index,
    };
    entry.identity = converted;
    return converted;
}

/// 从 `from` 起找相邻的存活行：先往后（下一行），到末尾再往前（上一行）。
pub fn adjacent(entries: []const Entry, from: ?usize) ?usize {
    const start = from orelse return null;
    if (entries.len == 0) return null;
    var i = @min(start, entries.len - 1);
    while (i < entries.len) : (i += 1) {
        if (!entries[i].deleted) return i;
    }
    var j = @min(start, entries.len);
    while (j > 0) {
        j -= 1;
        if (!entries[j].deleted) return j;
    }
    return null;
}
