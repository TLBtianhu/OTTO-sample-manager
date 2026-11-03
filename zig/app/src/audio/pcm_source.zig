//! 有界 PCM 播放源。Player 只看到帧读取接口，不再要求整段 PCM 常驻。
//! 窗口外 seek 通过重开流并顺序解码定位； zig-audio 当前没有公开 seek API。
const std = @import("std");
const decode = @import("decode.zig");
const budget = @import("../mem_budget.zig");

pub const Source = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        read: *const fn (*anyopaque, u64, []u8) anyerror!void,
        residentBytes: *const fn (*const anyopaque) usize,
        destroy: *const fn (*anyopaque, std.mem.Allocator) void,
    };

    pub fn read(self: *Source, frame: u64, dst: []u8) !void {
        return self.vtable.read(self.ctx, frame, dst);
    }
    pub fn residentBytes(self: *const Source) usize {
        return self.vtable.residentBytes(self.ctx);
    }
    pub fn destroy(self: *Source, allocator: std.mem.Allocator) void {
        self.vtable.destroy(self.ctx, allocator);
    }
};

const Native = struct {
    allocator: std.mem.Allocator,
    path: []u8,
    options: decode.Options,
    channels: u16,
    block_align: usize,
    total_frames: u64,
    initial: []u8,
    initial_start: u64,
    stream: decode.Stream = undefined,
    stream_open: bool = false,
    stream_eof: bool = false,
    cache_consumed: usize = 0,
    resident_bytes: std.atomic.Value(usize),

    fn create(
        allocator: std.mem.Allocator,
        path: []const u8,
        options: decode.Options,
        channels: u16,
        total_frames: u64,
        initial: []u8,
    ) !*Native {
        const self = try allocator.create(Native);
        errdefer allocator.destroy(self);
        const owned_path = try allocator.dupe(u8, path);
        self.* = .{
            .allocator = allocator,
            .path = owned_path,
            .options = .{ .expected_format = options.expected_format },
            .channels = channels,
            .block_align = @as(usize, channels) * 2,
            .total_frames = total_frames,
            .initial = initial,
            .initial_start = 0, // 渐进/fallback 保留的是首个播放窗，不是解码尾块。
            .resident_bytes = .init(initial.len + owned_path.len),
        };
        return self;
    }

    fn source(self: *Native) Source {
        return .{ .ctx = self, .vtable = &native_vtable };
    }

    fn resident(self: *const Native) usize {
        return self.resident_bytes.load(.acquire);
    }

    fn refreshResident(self: *Native) void {
        var bytes = self.initial.len + self.path.len;
        if (self.stream_open) bytes += self.stream.pcm.capacity + @import("file_reader.zig").buffer_size;
        self.resident_bytes.store(bytes, .release);
    }

    fn deinit(self: *Native, allocator: std.mem.Allocator) void {
        if (self.stream_open) self.stream.deinit();
        if (self.initial.len != 0) allocator.free(self.initial);
        allocator.free(self.path);
        allocator.destroy(self);
    }

    fn openStream(self: *Native, allocator: std.mem.Allocator) !void {
        if (self.stream_open) self.stream.deinit();
        self.stream_open = false;
        // 首次真正流式读取时才释放预览首窗，避免两份 2 MiB 同时常驻。
        if (self.initial.len != 0) {
            allocator.free(self.initial);
            self.initial = &.{};
        }
        try self.stream.init(allocator, self.path, .{
            .expected_format = self.options.expected_format,
            .retain_bytes = budget.bounded_window_bytes,
        });
        self.stream_open = true;
        self.stream_eof = false;
        self.cache_consumed = 0;
        self.refreshResident();
    }

    fn cacheStart(self: *const Native) u64 {
        if (!self.stream_open) return 0;
        return self.stream.frames -| (self.stream.pcm.items.len - self.cache_consumed) / self.block_align;
    }

    fn copyCached(self: *Native, frame: u64, dst: []u8) usize {
        if (!self.stream_open or self.stream.pcm.items.len == 0) return 0;
        const start = self.cacheStart();
        if (frame < start or frame >= self.stream.frames) return 0;
        const physical_start = self.stream.frames -| self.stream.pcm.items.len / self.block_align;
        const offset: usize = @intCast((frame - physical_start) * self.block_align);
        const available = self.stream.pcm.items.len - offset;
        const count = @min(dst.len, available);
        @memcpy(dst[0..count], self.stream.pcm.items[offset..][0..count]);
        self.cache_consumed += count;
        if (self.cache_consumed == self.stream.pcm.items.len) {
            self.stream.discardConsumed();
            self.cache_consumed = 0;
        }
        return count;
    }

    fn read(self: *Native, allocator: std.mem.Allocator, frame: u64, dst: []u8) !void {
        defer self.refreshResident();
        if (dst.len % self.block_align != 0 or frame *| self.block_align > std.math.maxInt(usize)) return error.InvalidFormat;
        const frames = dst.len / self.block_align;
        if (frame > self.total_frames or frames > self.total_frames - frame) return error.EndOfStream;
        if (dst.len == 0) return;

        if (self.initial.len != 0 and frame >= self.initial_start) {
            const offset: usize = @intCast((frame - self.initial_start) * self.block_align);
            if (offset <= self.initial.len and dst.len <= self.initial.len - offset) {
                @memcpy(dst, self.initial[offset..][0..dst.len]);
                return;
            }
        }
        if (!self.stream_open) try self.openStream(allocator);

        var done: usize = 0;
        while (done < dst.len) {
            const target = frame + done / self.block_align;
            const copied = self.copyCached(target, dst[done..]);
            if (copied != 0) {
                done += copied;
                continue;
            }
            if (self.stream_eof or target < self.cacheStart()) {
                if (self.stream_eof and target >= self.cacheStart()) return error.EndOfStream;
                try self.openStream(allocator);
                continue;
            }
            // target >= 已解帧数：旧缓存已无用，清空后顺序解码定位，不做整块搬移。
            self.stream.discardConsumed();
            self.cache_consumed = 0;
            const got = try self.stream.step(&read_scratch);
            if (got == 0) {
                self.stream_eof = true;
                if (done != dst.len) return error.EndOfStream;
            }
        }
    }
};

threadlocal var read_scratch: [decode.chunk_samples]i16 = undefined;

const native_vtable: Source.VTable = .{
    .read = nativeRead,
    .residentBytes = nativeResident,
    .destroy = nativeDestroy,
};

fn cast(ctx: *anyopaque) *Native {
    return @ptrCast(@alignCast(ctx));
}
fn nativeRead(ctx: *anyopaque, frame: u64, dst: []u8) !void {
    const self = cast(ctx);
    return self.read(self.allocator, frame, dst);
}
fn nativeResident(ctx: *const anyopaque) usize {
    const self: *const Native = @ptrCast(@alignCast(ctx));
    return self.resident();
}
fn nativeDestroy(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    cast(ctx).deinit(allocator);
}

pub fn createNative(
    allocator: std.mem.Allocator,
    path: []const u8,
    options: decode.Options,
    channels: u16,
    total_frames: u64,
    initial: []u8,
) !*Source {
    const self = try Native.create(allocator, path, options, channels, total_frames, initial);
    const boxed = allocator.create(Source) catch |err| {
        allocator.free(self.path);
        allocator.destroy(self);
        return err; // initial 仍归调用方；只有成功返回才消费它。
    };
    boxed.* = self.source();
    return boxed;
}

pub fn destroyBoxed(source: *Source, allocator: std.mem.Allocator) void {
    source.destroy(allocator);
    allocator.destroy(source);
}
