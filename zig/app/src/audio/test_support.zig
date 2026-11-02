//! 音频测试的小工具：峰值分配跟踪 + 给 FLAC 塞 PADDING。
//!
//! 只在测试构建里被 `providers/native_audio_test.zig` 引入；生产构建不会编译到
//! 这里。抽出来的原因：流式测试的脚手架（跟踪器 / 造 padded FLAC）不该挤占
//! provider 正文。

const std = @import("std");

/// 峰值分配跟踪器：只记请求字节的 live/peak，委托给 `child`（通常是
/// `testing.allocator`）。用来证明"流式解码的峰值不随压缩文件大小增长"。
pub const PeakTracker = struct {
    child: std.mem.Allocator,
    live: usize = 0,
    peak: usize = 0,

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = trackAlloc,
        .resize = trackResize,
        .remap = trackRemap,
        .free = trackFree,
    };

    pub fn allocator(self: *PeakTracker) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn grow(self: *PeakTracker, delta: usize) void {
        self.live += delta;
        if (self.live > self.peak) self.peak = self.live;
    }

    fn trackAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *PeakTracker = @ptrCast(@alignCast(ctx));
        const ptr = self.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.grow(len);
        return ptr;
    }

    fn trackResize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *PeakTracker = @ptrCast(@alignCast(ctx));
        if (!self.child.rawResize(memory, alignment, new_len, ret_addr)) return false;
        if (new_len >= memory.len) self.grow(new_len - memory.len) else self.live -= memory.len - new_len;
        return true;
    }

    fn trackRemap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *PeakTracker = @ptrCast(@alignCast(ctx));
        const ptr = self.child.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        if (new_len >= memory.len) self.grow(new_len - memory.len) else self.live -= memory.len - new_len;
        return ptr;
    }

    fn trackFree(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *PeakTracker = @ptrCast(@alignCast(ctx));
        self.live -= memory.len;
        self.child.rawFree(memory, alignment, ret_addr);
    }
};

/// 在最后一个 metadata block 之后插入一块 `pad_len` 字节的 PADDING（合法 FLAC，
/// 解码器按块长跳过）。文件会变成 pad_len + 原大小，但音频内容不变。
/// `pad_len` 是 24 位块长，最大 0xFFFFFF。
pub fn buildPaddedFlac(allocator: std.mem.Allocator, src: []const u8, pad_len: usize) ![]u8 {
    if (src.len < 8 or !std.mem.eql(u8, src[0..4], "fLaC")) return error.NotFlac;
    if (pad_len > 0xFFFFFF) return error.PaddingTooLarge;

    var pos: usize = 4;
    var last_header: usize = 0;
    var metadata_end: usize = 0;
    while (true) {
        if (pos + 4 > src.len) return error.Truncated;
        last_header = pos;
        const header = src[pos];
        const len = (@as(usize, src[pos + 1]) << 16) | (@as(usize, src[pos + 2]) << 8) | src[pos + 3];
        pos += 4 + len;
        if (pos > src.len) return error.Truncated;
        if (header & 0x80 != 0) {
            metadata_end = pos;
            break;
        }
    }

    const out = try allocator.alloc(u8, src.len + 4 + pad_len);
    errdefer allocator.free(out);
    @memcpy(out[0..metadata_end], src[0..metadata_end]);
    out[last_header] &= 0x7F; // 原来的最后一块让位给新的 PADDING
    out[metadata_end] = 0x80 | 1; // last-metadata-block + PADDING
    out[metadata_end + 1] = @intCast((pad_len >> 16) & 0xFF);
    out[metadata_end + 2] = @intCast((pad_len >> 8) & 0xFF);
    out[metadata_end + 3] = @intCast(pad_len & 0xFF);
    @memset(out[metadata_end + 4 ..][0..pad_len], 0);
    @memcpy(out[metadata_end + 4 + pad_len ..], src[metadata_end..]);
    return out;
}
