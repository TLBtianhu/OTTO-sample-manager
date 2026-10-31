//! Test/bench-only helpers: in-memory WAV construction and small-buffer
//! readers. No filesystem, no `/tmp`, no external files.

const std = @import("std");
const root = @import("root.zig");

pub const format_pcm: u16 = 0x0001;
pub const format_float: u16 = 0x0003;
pub const format_extensible: u16 = 0xFFFE;

pub const guid_pcm = [16]u8{
    0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00,
    0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71,
};
pub const guid_float = [16]u8{
    0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00,
    0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71,
};

pub const Builder = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) !Builder {
        var bytes: std.ArrayList(u8) = .empty;
        errdefer bytes.deinit(allocator);
        try bytes.appendSlice(allocator, "RIFF");
        try bytes.appendNTimes(allocator, 0, 4);
        try bytes.appendSlice(allocator, "WAVE");
        return .{ .allocator = allocator, .bytes = bytes };
    }

    pub fn deinit(self: *Builder) void {
        self.bytes.deinit(self.allocator);
    }

    /// Append a chunk whose declared length matches its payload.
    pub fn addChunk(self: *Builder, id: []const u8, payload: []const u8) !void {
        try self.addChunkSized(id, @intCast(payload.len), payload);
    }

    /// Append a chunk with an explicit declared length. Useful for truncation
    /// tests: the payload can be shorter than the header claims.
    pub fn addChunkSized(self: *Builder, id: []const u8, declared: u32, payload: []const u8) !void {
        std.debug.assert(id.len == 4);
        try self.bytes.appendSlice(self.allocator, id);
        var size_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &size_bytes, declared, .little);
        try self.bytes.appendSlice(self.allocator, &size_bytes);
        try self.bytes.appendSlice(self.allocator, payload);
        // A streaming WAV writer cannot know the final length, so it writes
        // 0xFFFFFFFF and no trailing pad byte. Adding one here would turn the
        // pad into a half frame in the "read until EOF" path.
        if (declared & 1 != 0 and declared != 0xFFFF_FFFF) {
            try self.bytes.append(self.allocator, 0);
        }
    }

    /// Patch the RIFF size and transfer ownership to the caller.
    pub fn finish(self: *Builder) ![]u8 {
        const riff_size: u32 = @intCast(self.bytes.items.len - 8);
        std.mem.writeInt(u32, self.bytes.items[4..8], riff_size, .little);
        return self.bytes.toOwnedSlice(self.allocator);
    }
};

/// Standard 16-byte `fmt ` payload (PCM or float, no extension).
pub fn fmtPayload(buffer: *[40]u8, tag: u16, channels: u16, sample_rate: u32, bits: u16) []const u8 {
    @memset(buffer, 0);
    const bytes_per_sample: u16 = bits / 8;
    const block_align: u16 = channels * bytes_per_sample;
    std.mem.writeInt(u16, buffer[0..2], tag, .little);
    std.mem.writeInt(u16, buffer[2..4], channels, .little);
    std.mem.writeInt(u32, buffer[4..8], sample_rate, .little);
    std.mem.writeInt(u32, buffer[8..12], sample_rate * @as(u32, block_align), .little);
    std.mem.writeInt(u16, buffer[12..14], block_align, .little);
    std.mem.writeInt(u16, buffer[14..16], bits, .little);
    return buffer[0..16];
}

/// 40-byte WAVE_FORMAT_EXTENSIBLE `fmt ` payload.
pub fn fmtPayloadExtensible(
    buffer: *[40]u8,
    channels: u16,
    sample_rate: u32,
    container_bits: u16,
    valid_bits: u16,
    float: bool,
) []const u8 {
    @memset(buffer, 0);
    const bytes_per_sample: u16 = container_bits / 8;
    const block_align: u16 = channels * bytes_per_sample;
    std.mem.writeInt(u16, buffer[0..2], format_extensible, .little);
    std.mem.writeInt(u16, buffer[2..4], channels, .little);
    std.mem.writeInt(u32, buffer[4..8], sample_rate, .little);
    std.mem.writeInt(u32, buffer[8..12], sample_rate * @as(u32, block_align), .little);
    std.mem.writeInt(u16, buffer[12..14], block_align, .little);
    std.mem.writeInt(u16, buffer[14..16], container_bits, .little);
    std.mem.writeInt(u16, buffer[16..18], 22, .little); // cbSize
    std.mem.writeInt(u16, buffer[18..20], valid_bits, .little);
    std.mem.writeInt(u32, buffer[20..24], 0, .little); // channel mask: ignored
    @memcpy(buffer[24..40], if (float) &guid_float else &guid_pcm);
    return buffer[0..40];
}

pub fn buildPcm(
    allocator: std.mem.Allocator,
    channels: u16,
    sample_rate: u32,
    bits: u16,
    pcm: []const u8,
) ![]u8 {
    var builder = try Builder.init(allocator);
    defer builder.deinit();
    var fmt_buffer: [40]u8 = undefined;
    try builder.addChunk("fmt ", fmtPayload(&fmt_buffer, format_pcm, channels, sample_rate, bits));
    try builder.addChunk("data", pcm);
    return builder.finish();
}

pub fn buildFloat(
    allocator: std.mem.Allocator,
    channels: u16,
    sample_rate: u32,
    samples: []const f32,
) ![]u8 {
    const payload = try allocator.alloc(u8, samples.len * 4);
    defer allocator.free(payload);
    for (samples, 0..) |sample, i| {
        std.mem.writeInt(u32, payload[i * 4 ..][0..4], @bitCast(sample), .little);
    }

    var builder = try Builder.init(allocator);
    defer builder.deinit();
    var fmt_buffer: [40]u8 = undefined;
    try builder.addChunk(
        "fmt ",
        fmtPayload(&fmt_buffer, format_float, channels, sample_rate, 32),
    );
    try builder.addChunk("data", payload);
    return builder.finish();
}

pub fn buildExtensiblePcm(
    allocator: std.mem.Allocator,
    channels: u16,
    sample_rate: u32,
    container_bits: u16,
    valid_bits: u16,
    payload: []const u8,
) ![]u8 {
    var builder = try Builder.init(allocator);
    defer builder.deinit();
    var fmt_buffer: [40]u8 = undefined;
    try builder.addChunk(
        "fmt ",
        fmtPayloadExtensible(&fmt_buffer, channels, sample_rate, container_bits, valid_bits, false),
    );
    try builder.addChunk("data", payload);
    return builder.finish();
}

pub fn buildExtensibleFloat(
    allocator: std.mem.Allocator,
    channels: u16,
    sample_rate: u32,
    samples: []const f32,
) ![]u8 {
    const payload = try allocator.alloc(u8, samples.len * 4);
    defer allocator.free(payload);
    for (samples, 0..) |sample, i| {
        std.mem.writeInt(u32, payload[i * 4 ..][0..4], @bitCast(sample), .little);
    }

    var builder = try Builder.init(allocator);
    defer builder.deinit();
    var fmt_buffer: [40]u8 = undefined;
    try builder.addChunk(
        "fmt ",
        fmtPayloadExtensible(&fmt_buffer, channels, sample_rate, 32, 32, true),
    );
    try builder.addChunk("data", payload);
    return builder.finish();
}

/// Build a short stereo 16-bit WAV used as the fuzz/bench template.
pub fn buildDemoPcm16(allocator: std.mem.Allocator, frames: usize) ![]u8 {
    const payload = try allocator.alloc(u8, frames * 4);
    defer allocator.free(payload);
    for (0..frames) |i| {
        const phase: i16 = @intCast(i % 200);
        const left: i16 = (phase - 100) * 300;
        const right: i16 = (100 - phase) * 300;
        std.mem.writeInt(i16, payload[i * 4 ..][0..2], left, .little);
        std.mem.writeInt(i16, payload[i * 4 + 2 ..][0..2], right, .little);
    }
    return buildPcm(allocator, 2, 44_100, 16, payload);
}

/// Decode every sample into a freshly allocated slice. `chunk_frames` controls
/// the caller buffer size per read, so a test can force many small calls.
pub fn decodeAll(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    chunk_frames: usize,
) ![]i16 {
    var reader = std.Io.Reader.fixed(bytes);
    var dec = try root.open(allocator, &reader);
    defer dec.deinit();

    var list: std.ArrayList(i16) = .empty;
    errdefer list.deinit(allocator);

    const channels: usize = dec.info.channels;
    var buffer: [4096]i16 = undefined;
    while (true) {
        const want = @min(buffer.len, @max(chunk_frames, 1) * channels);
        const n = try dec.read(buffer[0..want]);
        if (n == 0) break;
        try list.appendSlice(allocator, buffer[0..n]);
    }
    return list.toOwnedSlice(allocator);
}

/// A `std.Io.Reader` that hands out at most `chunk` bytes per underlying read,
/// over a larger in-memory source. Exercises refills at arbitrary boundaries
/// without needing a file or a large Reader buffer.
pub const ChunkedReader = struct {
    source: []const u8,
    pos: usize = 0,
    chunk: usize,
    interface: std.Io.Reader,

    const vtable = std.Io.Reader.VTable{
        .stream = stream,
        .discard = discard,
        .readVec = readVec,
    };

    pub fn init(source: []const u8, chunk: usize, buffer: []u8) ChunkedReader {
        std.debug.assert(chunk >= 1);
        return .{
            .source = source,
            .chunk = chunk,
            .interface = .{
                .vtable = &vtable,
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
        };
    }

    pub fn reader(self: *ChunkedReader) *std.Io.Reader {
        return &self.interface;
    }

    fn selfFromInterface(r: *std.Io.Reader) *ChunkedReader {
        return @fieldParentPtr("interface", r);
    }

    fn nextLen(self: *ChunkedReader, limit: std.Io.Limit) usize {
        const available = self.source.len - self.pos;
        if (available == 0) return 0;
        const wanted = limit.toInt() orelse available;
        return @min(@min(wanted, self.chunk), available);
    }

    fn stream(
        r: *std.Io.Reader,
        w: *std.Io.Writer,
        limit: std.Io.Limit,
    ) std.Io.Reader.StreamError!usize {
        const self = selfFromInterface(r);
        const n = self.nextLen(limit);
        if (n == 0) return error.EndOfStream;
        try w.writeAll(self.source[self.pos..][0..n]);
        self.pos += n;
        return n;
    }

    fn discard(r: *std.Io.Reader, limit: std.Io.Limit) std.Io.Reader.Error!usize {
        const self = selfFromInterface(r);
        const n = self.nextLen(limit);
        if (n == 0) return error.EndOfStream;
        self.pos += n;
        return n;
    }

    fn readVec(r: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
        const self = selfFromInterface(r);
        if (data.len == 0) return 0;
        const dst = data[0];
        if (dst.len == 0) {
            // `std.Io.Reader` contract: when the caller has no buffer the
            // implementation fills `Reader.buffer` and returns 0. Returning 0
            // *without* filling makes `fillUnbuffered` spin forever, which the
            // FLAC path (peekByte/takeByte) exercises but the WAV path does not.
            const space = r.buffer.len - r.end;
            const n = self.nextLen(.limited(space));
            if (n == 0) return error.EndOfStream;
            @memcpy(r.buffer[r.end..][0..n], self.source[self.pos..][0..n]);
            r.end += n;
            self.pos += n;
            return 0;
        }
        const n = self.nextLen(.limited(dst.len));
        if (n == 0) return error.EndOfStream;
        @memcpy(dst[0..n], self.source[self.pos..][0..n]);
        self.pos += n;
        return n;
    }
};

/// A reader whose every operation fails at the transport layer, for testing
/// the `error.Io` mapping.
pub fn failingReader(buffer: []u8) std.Io.Reader {
    return .{
        .vtable = &.{
            .stream = failingStream,
            .discard = failingDiscard,
            .readVec = failingReadVec,
        },
        .buffer = buffer,
        .seek = 0,
        .end = 0,
    };
}

fn failingStream(
    r: *std.Io.Reader,
    w: *std.Io.Writer,
    limit: std.Io.Limit,
) std.Io.Reader.StreamError!usize {
    _ = r;
    _ = w;
    _ = limit;
    return error.ReadFailed;
}

fn failingDiscard(r: *std.Io.Reader, limit: std.Io.Limit) std.Io.Reader.Error!usize {
    _ = r;
    _ = limit;
    return error.ReadFailed;
}

fn failingReadVec(r: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
    _ = r;
    _ = data;
    return error.ReadFailed;
}
