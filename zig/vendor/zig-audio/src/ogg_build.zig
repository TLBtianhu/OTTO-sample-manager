//! Test-only Ogg page writer.
//!
//! Builds exactly the bytes `ogg.zig` parses, including a correct CRC, so unit
//! tests can target one container behaviour at a time and the fuzzer gets a
//! structurally valid Ogg template. Not part of the library.

const std = @import("std");
const ogg = @import("ogg.zig");

pub const PageSpec = struct {
    flags: u8 = 0,
    granule: u64 = 0,
    serial: u32 = 0x0403_0201,
    sequence: u32 = 0,
    /// Lacing values; their sum must equal `body.len`.
    segments: []const u8 = &.{},
    body: []const u8 = &.{},
    /// Write this CRC instead of the correct one, for negative tests.
    crc_override: ?u32 = null,
};

pub fn buildPage(allocator: std.mem.Allocator, spec: PageSpec) ![]u8 {
    var total: usize = 0;
    for (spec.segments) |lace| total += lace;
    if (total != spec.body.len) return error.SegmentMismatch;
    if (spec.segments.len > 255) return error.TooManySegments;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "OggS");
    try out.append(allocator, 0); // version
    try out.append(allocator, spec.flags);
    try appendInt(&out, allocator, u64, spec.granule, .little);
    try appendInt(&out, allocator, u32, spec.serial, .little);
    try appendInt(&out, allocator, u32, spec.sequence, .little);
    try appendInt(&out, allocator, u32, 0, .little); // CRC, filled below
    try out.append(allocator, @intCast(spec.segments.len));
    try out.appendSlice(allocator, spec.segments);
    try out.appendSlice(allocator, spec.body);

    const crc = ogg.crc32(out.items);
    std.mem.writeInt(u32, out.items[22..26], spec.crc_override orelse crc, .little);
    return out.toOwnedSlice(allocator);
}

/// Sequential page writer for one logical stream.
pub const Writer = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    serial: u32,
    sequence: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, serial: u32) Writer {
        return .{ .allocator = allocator, .serial = serial };
    }

    pub fn deinit(self: *Writer) void {
        self.bytes.deinit(self.allocator);
    }

    /// One page holding complete packets. A packet of exactly 255 bytes gets a
    /// terminating zero lace, as the format requires.
    pub fn addPage(
        self: *Writer,
        flags: u8,
        granule: u64,
        packets: []const []const u8,
    ) !void {
        var laces: [255]u8 = undefined;
        var lace_count: usize = 0;
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.allocator);

        for (packets) |packet| {
            var left = packet.len;
            while (left >= 255) {
                if (lace_count == laces.len) return error.PageFull;
                laces[lace_count] = 255;
                lace_count += 1;
                left -= 255;
            }
            if (lace_count == laces.len) return error.PageFull;
            laces[lace_count] = @intCast(left);
            lace_count += 1;
            try body.appendSlice(self.allocator, packet);
        }
        try self.addRawPage(flags, granule, laces[0..lace_count], body.items);
    }

    pub fn addRawPage(
        self: *Writer,
        flags: u8,
        granule: u64,
        segments: []const u8,
        body: []const u8,
    ) !void {
        const page = try buildPage(self.allocator, .{
            .flags = flags,
            .granule = granule,
            .serial = self.serial,
            .sequence = self.sequence,
            .segments = segments,
            .body = body,
        });
        defer self.allocator.free(page);
        try self.bytes.appendSlice(self.allocator, page);
        self.sequence +%= 1;
    }

    pub fn finish(self: *Writer) ![]u8 {
        return self.bytes.toOwnedSlice(self.allocator);
    }
};

pub fn appendInt(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    comptime T: type,
    value: T,
    endian: std.builtin.Endian,
) !void {
    var buffer: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buffer, value, endian);
    try out.appendSlice(allocator, &buffer);
}
