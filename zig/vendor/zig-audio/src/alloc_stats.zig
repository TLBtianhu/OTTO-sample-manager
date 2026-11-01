//! Test/bench-only allocation accounting.
//!
//! Wraps any `std.mem.Allocator` and records, per phase:
//!
//!   * `allocs`       — number of successful allocations / growing remaps;
//!   * `alloc_bytes`  — requested bytes of those operations;
//!   * `current`      — bytes currently live through this wrapper;
//!   * `peak`         — maximum `current` seen;
//!   * `live`         — number of live blocks (so a double free or a miss is
//!                      visible even when the byte count happens to balance).
//!
//! The wrapper is deliberately not thread-safe: both callers are single
//! threaded (the corpus replay and the benchmark). The decoders themselves
//! never see this type.
//!
//! Not part of the library build; it is only imported by tests and `bench.zig`.

const std = @import("std");

pub const Counter = struct {
    parent: std.mem.Allocator,
    current: usize = 0,
    peak: usize = 0,
    allocs: usize = 0,
    alloc_bytes: usize = 0,
    frees: usize = 0,
    live: usize = 0,

    pub fn init(parent: std.mem.Allocator) Counter {
        return .{ .parent = parent };
    }

    pub fn allocator(self: *Counter) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub const Snapshot = struct {
        allocs: usize,
        alloc_bytes: usize,
        current: usize,
        peak: usize,
        live: usize,
    };

    pub fn snapshot(self: *const Counter) Snapshot {
        return .{
            .allocs = self.allocs,
            .alloc_bytes = self.alloc_bytes,
            .current = self.current,
            .peak = self.peak,
            .live = self.live,
        };
    }

    pub fn reset(self: *Counter) void {
        self.current = 0;
        self.peak = 0;
        self.allocs = 0;
        self.alloc_bytes = 0;
        self.frees = 0;
        self.live = 0;
    }

    fn note(self: *Counter, bytes: usize) void {
        self.current += bytes;
        if (self.current > self.peak) self.peak = self.current;
        self.allocs += 1;
        self.alloc_bytes += bytes;
        self.live += 1;
    }

    fn alloc(
        ctx: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *Counter = @ptrCast(@alignCast(ctx));
        const ptr = self.parent.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.note(len);
        return ptr;
    }

    fn resize(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *Counter = @ptrCast(@alignCast(ctx));
        if (!self.parent.rawResize(memory, alignment, new_len, ret_addr)) return false;
        if (new_len >= memory.len) {
            self.current += new_len - memory.len;
            if (self.current > self.peak) self.peak = self.current;
            self.alloc_bytes += new_len - memory.len;
        } else {
            self.current -= memory.len - new_len;
        }
        return true;
    }

    fn remap(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *Counter = @ptrCast(@alignCast(ctx));
        const ptr = self.parent.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        if (new_len >= memory.len) {
            self.note(new_len - memory.len);
            // `note` counted a block, but remap replaced the old one.
            self.live -= 1;
        } else {
            self.current -= memory.len - new_len;
        }
        return ptr;
    }

    fn free(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) void {
        const self: *Counter = @ptrCast(@alignCast(ctx));
        self.parent.rawFree(memory, alignment, ret_addr);
        if (self.current < memory.len or self.live == 0) {
            @panic("alloc_stats: free without a live allocation");
        }
        self.current -= memory.len;
        self.live -= 1;
        self.frees += 1;
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };
};
