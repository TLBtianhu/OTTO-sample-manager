//! Ogg framing: pages, CRC-32, packet assembly and logical-stream selection.
//!
//! Scope is deliberately container-only: `PageReader` walks and verifies pages,
//! `Demuxer` picks the first audio bitstream (Vorbis or Opus identification) and
//! yields its packets in order. Codec setup lives in `vorbis.zig`.
//!
//! Byte order: every multi-byte Ogg field is little-endian. There is no bit
//! layer here; Vorbis packet bits are LSB-first and live in `vorbis_bits.zig`.
//!
//! The page CRC is Ogg's only integrity check, so it is verified on *every*
//! page this module reads, including pages of logical streams it skips.

const std = @import("std");
const types = @import("types.zig");

pub const Error = types.Error;

/// 27-byte header + up to 255 lacing values + at most 255*255 body bytes.
pub const max_page_bytes: usize = 27 + 255 + 255 * 255;

pub const Flag = struct {
    pub const continued: u8 = 0x01;
    pub const bos: u8 = 0x02;
    pub const eos: u8 = 0x04;
    /// Bits 3..7 are reserved and must be zero.
    pub const reserved: u8 = 0xF8;
};

/// "No packet completed on this page" granule position.
pub const no_granule: u64 = std.math.maxInt(u64);

/// Ogg CRC-32: polynomial 0x04C11DB7, MSB-first, init 0, no final xor.
pub fn crc32(bytes: []const u8) u32 {
    var crc: u32 = 0;
    for (bytes) |byte| {
        crc = (crc << 8) ^ crc32_table[@as(u8, @truncate(crc >> 24)) ^ byte];
    }
    return crc;
}

const crc32_table = blk: {
    @setEvalBranchQuota(8192);
    var table: [256]u32 = undefined;
    for (&table, 0..) |*slot, i| {
        var crc: u32 = @as(u32, @intCast(i)) << 24;
        for (0..8) |_| {
            crc = if (crc & 0x8000_0000 != 0) (crc << 1) ^ 0x04C1_1DB7 else crc << 1;
        }
        slot.* = crc;
    }
    break :blk table;
};

pub const PageHeader = struct {
    version: u8,
    flags: u8,
    granule: u64,
    serial: u32,
    sequence: u32,
    crc: u32,
    segment_count: u8,
    segments: [255]u8,

    pub fn isContinued(self: PageHeader) bool {
        return self.flags & Flag.continued != 0;
    }

    pub fn isBos(self: PageHeader) bool {
        return self.flags & Flag.bos != 0;
    }

    pub fn isEos(self: PageHeader) bool {
        return self.flags & Flag.eos != 0;
    }

    pub fn bodyLength(self: PageHeader) usize {
        var total: usize = 0;
        for (self.segments[0..self.segment_count]) |lace| total += lace;
        return total;
    }
};

pub const Page = struct {
    header: PageHeader,
    /// Borrowed from `PageReader.buffer`; valid until the next `next` call.
    body: []const u8,
};

/// Streaming page reader. `prefix` is what the public dispatcher already
/// consumed from the stream (12 bytes); it is spliced in front of the first
/// page header instead of being read twice.
pub const PageReader = struct {
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    prefix: []const u8,
    buffer: []u8,
    page: Page,

    pub fn init(
        allocator: std.mem.Allocator,
        reader: *std.Io.Reader,
        prefix: []const u8,
    ) Error!PageReader {
        std.debug.assert(prefix.len <= 27);
        const buffer = try allocator.alloc(u8, max_page_bytes);
        return .{
            .allocator = allocator,
            .reader = reader,
            .prefix = prefix,
            .buffer = buffer,
            .page = .{ .header = undefined, .body = &.{} },
        };
    }

    pub fn deinit(self: *PageReader) void {
        if (self.buffer.len != 0) self.allocator.free(self.buffer);
        self.buffer = &.{};
    }

    /// Read the next page. Returns false on a clean end of stream. Every page
    /// that is returned has had its CRC checked.
    pub fn next(self: *PageReader) Error!bool {
        var header: [27]u8 = undefined;
        var have: usize = 0;
        if (self.prefix.len != 0) {
            const n = @min(self.prefix.len, header.len);
            @memcpy(header[0..n], self.prefix[0..n]);
            have = n;
            self.prefix = self.prefix[n..];
        }
        if (have < header.len) {
            const got = self.reader.readSliceShort(header[have..]) catch |err| switch (err) {
                error.ReadFailed => return error.Io,
            };
            if (got == 0 and have == 0) return false;
            if (have + got < header.len) return error.Truncated;
        }

        if (!std.mem.eql(u8, header[0..4], "OggS")) return error.Corrupt;
        if (header[4] != 0) return error.Corrupt;
        const flags = header[5];
        if (flags & Flag.reserved != 0) return error.Corrupt;

        const segment_count = header[26];
        const header_len: usize = 27 + @as(usize, segment_count);
        @memcpy(self.buffer[0..27], &header);
        const stored_crc = std.mem.readInt(u32, header[22..26], .little);
        @memset(self.buffer[22..26], 0);

        if (segment_count != 0) {
            const got = self.reader.readSliceShort(self.buffer[27..][0..segment_count]) catch |err| switch (err) {
                error.ReadFailed => return error.Io,
            };
            if (got != segment_count) return error.Truncated;
        }

        var body_len: usize = 0;
        for (self.buffer[27..][0..segment_count]) |lace| body_len += lace;
        if (body_len != 0) {
            const got = self.reader.readSliceShort(self.buffer[header_len..][0..body_len]) catch |err| switch (err) {
                error.ReadFailed => return error.Io,
            };
            if (got != body_len) return error.Truncated;
        }

        if (crc32(self.buffer[0 .. header_len + body_len]) != stored_crc) return error.Corrupt;

        var segments: [255]u8 = undefined;
        @memset(&segments, 0);
        if (segment_count != 0) {
            @memcpy(segments[0..segment_count], self.buffer[27..][0..segment_count]);
        }

        self.page = .{
            .header = .{
                .version = header[4],
                .flags = flags,
                .granule = std.mem.readInt(u64, header[6..14], .little),
                .serial = std.mem.readInt(u32, header[14..18], .little),
                .sequence = std.mem.readInt(u32, header[18..22], .little),
                .crc = stored_crc,
                .segment_count = segment_count,
                .segments = segments,
            },
            .body = self.buffer[header_len..][0..body_len],
        };
        return true;
    }
};

/// Codec of a logical stream, identified from its first packet.
pub const Codec = enum { vorbis, opus, unknown };

pub fn identifyPacket(packet: []const u8) Codec {
    if (packet.len >= 7 and packet[0] == 1 and
        std.mem.eql(u8, packet[1..7], "vorbis"))
    {
        return .vorbis;
    }
    if (packet.len >= 8 and std.mem.eql(u8, packet[0..8], "OpusHead")) return .opus;
    return .unknown;
}

/// Identify a stream from its first bytes, for `probe`.
///
/// A page header is 27 bytes plus the segment table, and the first packet's
/// magic follows it, so at least `27 + 1 + 8 = 36` bytes are needed for the
/// usual single-segment BOS page. Anything shorter is `.unknown` rather than a
/// guess: `probe` must never report Opus as Vorbis.
pub fn identify(header: []const u8) Codec {
    if (header.len < 28) return .unknown;
    if (!std.mem.eql(u8, header[0..4], "OggS")) return .unknown;
    if (header[4] != 0) return .unknown;
    const offset: usize = 27 + @as(usize, header[26]);
    if (header.len < offset + 8) return .unknown;
    return identifyPacket(header[offset..]);
}

/// First packet of a BOS page, if it ends on that page. Vorbis and Opus
/// identification packets are required to be the only packet on the BOS page.
fn firstPacketOf(page: Page) ?[]const u8 {
    var total: usize = 0;
    for (page.header.segments[0..page.header.segment_count]) |lace| {
        total += lace;
        if (lace < 255) return page.body[0..total];
    }
    return null;
}

/// Largest packet this module will assemble. Vorbis setup headers are a few
/// KiB; the cap keeps a hostile 255-lace page chain from growing without bound.
pub const max_packet_bytes: usize = 4 << 20;

/// Demultiplexer for the first audio logical stream of an Ogg physical stream.
///
/// Pages of other logical streams are read (so their CRC is verified) and
/// discarded. Chained streams after the first EOS are ignored.
pub const Demuxer = struct {
    allocator: std.mem.Allocator,
    pages: PageReader,
    serial: u32 = 0,
    codec: Codec = .unknown,
    /// Bytes of the packet currently being assembled.
    packet: std.ArrayList(u8) = .empty,
    /// Cursor within `pages.page`.
    page_active: bool = false,
    seg_index: u8 = 0,
    body_pos: usize = 0,
    /// Previous page ended on a 255-byte lace, so a packet spans pages.
    continued: bool = false,
    expected_sequence: u32 = 0,
    eos_pending: bool = false,
    done: bool = false,
    discard: bool = false,
    last_granule: u64 = no_granule,

    pub fn init(
        allocator: std.mem.Allocator,
        reader: *std.Io.Reader,
        prefix: []const u8,
    ) Error!Demuxer {
        const pages = try PageReader.init(allocator, reader, prefix);
        var demux = Demuxer{
            .allocator = allocator,
            .pages = pages,
        };
        errdefer demux.deinit();

        while (try demux.pages.next()) {
            const page = demux.pages.page;
            if (!page.header.isBos()) continue;
            if (page.header.isContinued()) return error.Corrupt;
            const first = firstPacketOf(page) orelse continue;
            const codec = identifyPacket(first);
            if (codec == .unknown) continue;

            demux.serial = page.header.serial;
            demux.codec = codec;
            demux.expected_sequence = page.header.sequence +% 1;
            demux.page_active = true;
            demux.seg_index = 0;
            demux.body_pos = 0;
            demux.continued = false;
            if (page.header.granule != no_granule) demux.last_granule = page.header.granule;
            return demux;
        }
        return error.Unsupported;
    }

    pub fn deinit(self: *Demuxer) void {
        self.packet.deinit(self.allocator);
        freeBuffer(self.allocator, self.pages.buffer);
    }

    /// Codec of the selected stream. `.unknown` cannot happen after `init`
    /// succeeds; it exists so callers can switch exhaustively.
    pub fn streamCodec(self: *const Demuxer) Codec {
        return self.codec;
    }

    /// Next complete packet of the selected stream, or null at end of stream.
    /// The slice is owned by the demuxer and invalidated by the next call.
    pub fn nextPacket(self: *Demuxer) Error!?[]const u8 {
        if (self.done) return null;
        self.packet.clearRetainingCapacity();

        while (true) {
            if (!self.page_active) {
                if (!try self.advancePage()) {
                    // A packet that ended mid-lace is a truncated stream even
                    // in `discard` mode, where no bytes were accumulated.
                    if (self.packet.items.len != 0 or self.continued) return error.Truncated;
                    self.done = true;
                    return null;
                }
            }

            const page = self.pages.page;
            const header = page.header;
            while (self.seg_index < header.segment_count) {
                const lace: usize = header.segments[self.seg_index];
                self.seg_index += 1;
                const chunk = page.body[self.body_pos..][0..lace];
                self.body_pos += lace;
                if (!self.discard) {
                    if (self.packet.items.len + lace > max_packet_bytes) return error.Corrupt;
                    try self.packet.appendSlice(self.allocator, chunk);
                }
                if (lace < 255) {
                    self.continued = false;
                    if (self.discard) return &.{};
                    return self.packet.items;
                }
            }

            // Page exhausted. A final 255-byte lace means the packet continues
            // on the next page; a page with no laces leaves the state alone.
            if (header.segment_count != 0) {
                self.continued = header.segments[header.segment_count - 1] == 255;
            }
            self.page_active = false;
            if (self.eos_pending and !self.continued) self.done = true;
            if (self.done) return null;
        }
    }

    /// Walk the rest of the selected stream without assembling packets and
    /// return its last granule position (Vorbis: total PCM frames), or null.
    pub fn finish(self: *Demuxer) Error!?u64 {
        self.discard = true;
        while (true) {
            const packet = try self.nextPacket();
            if (packet == null) break;
        }
        return self.lastGranule();
    }

    pub fn lastGranule(self: *const Demuxer) ?u64 {
        return if (self.last_granule == no_granule) null else self.last_granule;
    }

    /// Read pages until one belongs to the selected stream. Returns false at
    /// end of stream.
    fn advancePage(self: *Demuxer) Error!bool {
        while (try self.pages.next()) {
            const page = self.pages.page;
            if (page.header.serial != self.serial) continue;

            if (page.header.isBos()) return error.Corrupt;
            if (page.header.sequence != self.expected_sequence) return error.Corrupt;
            self.expected_sequence +%= 1;
            if (page.header.isContinued() != self.continued) return error.Corrupt;
            if (page.header.granule != no_granule) self.last_granule = page.header.granule;

            self.page_active = true;
            self.seg_index = 0;
            self.body_pos = 0;
            self.eos_pending = page.header.isEos();
            return true;
        }
        return false;
    }
};

fn freeBuffer(allocator: std.mem.Allocator, buffer: []u8) void {
    if (buffer.len != 0) allocator.free(buffer);
}
