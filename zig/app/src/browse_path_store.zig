//! 浏览行的路径存储：保留每行完整的绝对路径切片，但不再让每条短路径独占一个堆块。
//!
//! 生产/消费线程都会分配和释放路径，所以块表与 bump 指针由同一把自旋锁保护。
//! 每个切片前有 8 字节块指针；块内路径地址永不移动。某一行删除/改名时可单独释放，
//! 非当前块的所有路径都释放后立即归还整块；当前空块清零复用。因而重扫不会退化成
//! “arena 只涨不跌”，长路径（大于常规块）也有独立的精确容量块。
//!
//! `legacy` 模式直接返回后备分配器，是行为与内存的反向对照开关。

const std = @import("std");
const types = @import("browse_types.zig");

pub const Mode = enum { compact, legacy };
pub const default_chunk_bytes: usize = 64 * 1024;
const header_bytes: usize = @sizeOf(*Chunk);

const Header = extern struct { chunk: *Chunk };
const Chunk = struct {
    next: ?*Chunk = null,
    data: []u8,
    used: usize = 0,
    live: usize = 0,
};

pub const Store = struct {
    backing: std.mem.Allocator,
    mode: Mode,
    lock: types.SpinLock = .{},
    chunks: ?*Chunk = null,
    current: ?*Chunk = null,
    allocated_bytes: usize = 0,
    live_paths: usize = 0,
    live_path_bytes: usize = 0,

    pub fn init(backing: std.mem.Allocator, mode: Mode) Store {
        return .{ .backing = backing, .mode = mode };
    }

    /// 所有 Entry.path 的分配/释放都走这里；legacy 模式与原逐条分配完全一致。
    pub fn allocator(self: *Store) std.mem.Allocator {
        if (self.mode == .legacy) return self.backing;
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn join(self: *Store, root: []const u8, name: []const u8) error{OutOfMemory}![]u8 {
        if (self.mode == .legacy) return types.joinPath(self.backing, root, name);
        return types.joinPathExact(self.allocator(), root, name);
    }

    /// 此刻路径块向后备分配器实际申请的容量（含块元数据）。只含路径，不含 Entry/Sample。
    pub fn allocatedBytes(self: *Store) usize {
        if (self.mode == .legacy) return 0;
        self.lock.acquire();
        defer self.lock.release();
        return self.allocated_bytes;
    }

    pub fn liveCount(self: *Store) usize {
        self.lock.acquire();
        defer self.lock.release();
        return self.live_paths;
    }

    /// 必须在 Source 停止、全部 Entry 与 pending path 释放之后调用。
    pub fn deinit(self: *Store) void {
        var next = self.chunks;
        while (next) |chunk| {
            next = chunk.next;
            self.backing.free(chunk.data);
            self.backing.destroy(chunk);
        }
        self.* = undefined;
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = std.mem.Allocator.noResize,
        .remap = std.mem.Allocator.noRemap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        const self: *Store = @ptrCast(@alignCast(ctx));
        self.lock.acquire();
        defer self.lock.release();

        if (self.current) |chunk| {
            if (location(chunk, len, alignment)) |start| return finish(self, chunk, start, len);
        }
        const worst_case = std.math.add(usize, header_bytes + len, alignment.toByteUnits() - 1) catch return null;
        const chunk = self.newChunk(@max(default_chunk_bytes, worst_case)) catch return null;
        chunk.next = self.chunks;
        self.chunks = chunk;
        self.current = chunk;
        const start = location(chunk, len, alignment) orelse unreachable;
        return finish(self, chunk, start, len);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        _ = alignment;
        _ = ret_addr;
        const self: *Store = @ptrCast(@alignCast(ctx));
        const header: *align(1) const Header = @ptrCast(memory.ptr - header_bytes);
        const chunk = header.chunk;

        self.lock.acquire();
        defer self.lock.release();
        std.debug.assert(chunk.live > 0);
        std.debug.assert(self.live_paths > 0);
        chunk.live -= 1;
        self.live_paths -= 1;
        self.live_path_bytes -= memory.len;
        if (self.live_paths == 0) {
            self.releaseAllChunks();
            return;
        }
        if (chunk.live != 0) return;
        if (chunk == self.current) {
            chunk.used = 0;
            return;
        }
        self.releaseEmptyChunk(chunk);
    }

    fn newChunk(self: *Store, capacity: usize) error{OutOfMemory}!*Chunk {
        const chunk = try self.backing.create(Chunk);
        errdefer self.backing.destroy(chunk);
        const data = try self.backing.alloc(u8, capacity);
        chunk.* = .{ .data = data };
        self.allocated_bytes += @sizeOf(Chunk) + capacity;
        return chunk;
    }

    fn releaseAllChunks(self: *Store) void {
        var next = self.chunks;
        while (next) |chunk| {
            next = chunk.next;
            self.backing.free(chunk.data);
            self.backing.destroy(chunk);
        }
        self.chunks = null;
        self.current = null;
        self.allocated_bytes = 0;
    }

    fn releaseEmptyChunk(self: *Store, wanted: *Chunk) void {
        var link: *?*Chunk = &self.chunks;
        while (link.*) |chunk| : (link = &chunk.next) {
            if (chunk != wanted) continue;
            link.* = chunk.next;
            self.allocated_bytes -= @sizeOf(Chunk) + chunk.data.len;
            self.backing.free(chunk.data);
            self.backing.destroy(chunk);
            return;
        }
        unreachable;
    }
};

fn location(chunk: *Chunk, len: usize, alignment: std.mem.Alignment) ?usize {
    const unaligned = std.math.add(usize, chunk.used, header_bytes) catch return null;
    const start = std.mem.alignForward(usize, unaligned, alignment.toByteUnits());
    if (start < unaligned) return null;
    const end = std.math.add(usize, start, len) catch return null;
    if (end > chunk.data.len) return null;
    return start;
}

fn finish(self: *Store, chunk: *Chunk, start: usize, len: usize) [*]u8 {
    chunk.used = start + len;
    chunk.live += 1;
    self.live_paths += 1;
    self.live_path_bytes += len;
    const result = chunk.data.ptr + start;
    const header: *align(1) Header = @ptrCast(result - header_bytes);
    header.chunk = chunk;
    return result;
}

test "紧凑路径块：完整内容、长路径与空块回收" {
    var store = Store.init(std.testing.allocator, .compact);
    defer store.deinit();
    const allocator = store.allocator();

    const long_unc = "\\\\?\\UNC\\server\\音频\\很长的目录名\\很长的目录名\\很长的目录名\\很长的目录名\\很长的目录名\\很长的目录名\\很长的目录名\\很长的目录名\\很长的目录名\\很长的目录名\\很长的目录名\\很长的目录名\\很长的目录名\\很长的目录名\\文件.wav";
    try std.testing.expect(long_unc.len > 260);
    const first = try allocator.dupe(u8, long_unc);
    try std.testing.expectEqualStrings(long_unc, first);
    const filler = try allocator.alloc(u8, default_chunk_bytes);
    const second = try allocator.dupe(u8, "C:\\目录\\第二个.wav");
    try std.testing.expectEqualStrings("C:\\目录\\第二个.wav", second);
    try std.testing.expectEqual(@as(usize, 3), store.liveCount());

    allocator.free(first);
    allocator.free(second);
    try std.testing.expectEqual(@as(usize, 1), store.liveCount());
    allocator.free(filler);
    try std.testing.expectEqual(@as(usize, 0), store.liveCount());
    try std.testing.expectEqual(@as(usize, 0), store.allocatedBytes());

    var paths: [1000][]u8 = undefined;
    for (&paths) |*path| {
        path.* = try store.join("C:\\Users\\30680\\AppData\\Local\\Temp\\otto-rowcost\\100k", "b000000.wav");
    }
    try std.testing.expect(store.allocatedBytes() <= 2 * (default_chunk_bytes + @sizeOf(Chunk)));
    for (paths) |path| allocator.free(path);
    try std.testing.expectEqual(@as(usize, 0), store.allocatedBytes());
}

test "legacy 对照仍逐条走后备分配器" {
    var store = Store.init(std.testing.allocator, .legacy);
    defer store.deinit();
    const path = try store.allocator().dupe(u8, "\\\\server\\共享\\音.wav");
    try std.testing.expectEqual(@as(usize, 0), store.allocatedBytes());
    store.allocator().free(path);
}
