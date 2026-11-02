//! Test-only Vorbis header writer: LSB-first bit writer plus identification,
//! comment and setup packets.
//!
//! The point is to exercise each setup structure in isolation (ordered vs
//! sparse codebooks, lookup type 1 vs 2, floor 0 vs 1, residue cascades,
//! coupling, mux) and to give the fuzzer a structurally valid Ogg/Vorbis
//! template. Not part of the library.

const std = @import("std");
const vorbis_bits = @import("vorbis_bits.zig");
const ogg = @import("ogg.zig");
const ogg_build = @import("ogg_build.zig");

const ilog = vorbis_bits.ilog;
const lookup1Values = vorbis_bits.lookup1Values;

/// LSB-first bit writer that is the exact inverse of `vorbis_bits.BitReader`.
pub const BitWriter = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    /// Bits already used in the last byte, 0..7.
    used: u4 = 0,

    pub fn init(allocator: std.mem.Allocator) BitWriter {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *BitWriter) void {
        self.bytes.deinit(self.allocator);
    }

    pub fn writeBits(self: *BitWriter, value: u32, count: u6) !void {
        var i: u6 = 0;
        while (i < count) : (i += 1) {
            if (self.used == 0) try self.bytes.append(self.allocator, 0);
            const bit: u8 = @intCast((value >> @intCast(i)) & 1);
            const shift: u3 = @intCast(self.used);
            self.bytes.items[self.bytes.items.len - 1] |= bit << shift;
            self.used = @intCast((@as(u4, self.used) + 1) & 7);
        }
    }

    /// Byte-aligned write; only valid before the first bit or after a full byte.
    pub fn writeBytes(self: *BitWriter, bytes: []const u8) !void {
        std.debug.assert(self.used == 0);
        try self.bytes.appendSlice(self.allocator, bytes);
    }

    /// Codebook minimum/delta are stored in Vorbis's packed float format, not as
    /// IEEE-754 bits: see `vorbis_bits.float32Pack`.
    pub fn writeF32(self: *BitWriter, value: f32) !void {
        try self.writeBits(vorbis_bits.float32Pack(value), 32);
    }

    pub fn take(self: *BitWriter) ![]u8 {
        return self.bytes.toOwnedSlice(self.allocator);
    }
};

pub const IdentSpec = struct {
    version: u32 = 0,
    channels: u8 = 2,
    sample_rate: u32 = 44_100,
    bitrate_maximum: i32 = 0,
    bitrate_nominal: i32 = 128_000,
    bitrate_minimum: i32 = 0,
    blocksize_0_exp: u4 = 8,
    blocksize_1_exp: u4 = 11,
    framing: u8 = 1,
};

pub fn identification(allocator: std.mem.Allocator, spec: IdentSpec) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "\x01vorbis");
    try ogg_build.appendInt(&out, allocator, u32, spec.version, .little);
    try out.append(allocator, spec.channels);
    try ogg_build.appendInt(&out, allocator, u32, spec.sample_rate, .little);
    try ogg_build.appendInt(&out, allocator, i32, spec.bitrate_maximum, .little);
    try ogg_build.appendInt(&out, allocator, i32, spec.bitrate_nominal, .little);
    try ogg_build.appendInt(&out, allocator, i32, spec.bitrate_minimum, .little);
    try out.append(allocator, (@as(u8, spec.blocksize_1_exp) << 4) | spec.blocksize_0_exp);
    try out.append(allocator, spec.framing);
    return out.toOwnedSlice(allocator);
}

pub fn comment(
    allocator: std.mem.Allocator,
    vendor: []const u8,
    entries: []const []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "\x03vorbis");
    try ogg_build.appendInt(&out, allocator, u32, @intCast(vendor.len), .little);
    try out.appendSlice(allocator, vendor);
    try ogg_build.appendInt(&out, allocator, u32, @intCast(entries.len), .little);
    for (entries) |entry| {
        try ogg_build.appendInt(&out, allocator, u32, @intCast(entry.len), .little);
        try out.appendSlice(allocator, entry);
    }
    try out.append(allocator, 1); // framing bit
    return out.toOwnedSlice(allocator);
}

pub const CodebookSpec = struct {
    dimensions: u16 = 1,
    /// Codeword length per entry, 1..32; 0 is a sparse unused entry.
    lengths: []const u8,
    ordered: bool = false,
    sparse: bool = false,
    lookup_type: u4 = 0,
    minimum_value: f32 = 0,
    delta_value: f32 = 0,
    /// Actual width in bits, 1..16.
    value_bits: u5 = 1,
    sequence_p: bool = false,
    /// Empty means "generate i & mask"; otherwise must match the lookup count.
    multiplicands: []const u16 = &.{},
};

fn writeCodebook(w: *BitWriter, spec: CodebookSpec) !void {
    const entries = spec.lengths.len;
    if (entries == 0 or entries > 0xFF_FFFF) return error.InvalidSpec;
    if (spec.dimensions == 0) return error.InvalidSpec;

    try w.writeBits(0x564342, 24);
    try w.writeBits(spec.dimensions, 16);
    try w.writeBits(@intCast(entries), 24);
    try w.writeBits(@intFromBool(spec.ordered), 1);

    if (spec.ordered) {
        var entry: usize = 0;
        var length: u32 = spec.lengths[0];
        if (length == 0 or length > 32) return error.InvalidSpec;
        // The first run's length is explicit; each following run implies the
        // next length, so gaps are written as zero-count runs.
        try w.writeBits(length - 1, 5);
        while (entry < entries) {
            if (spec.lengths[entry] < length) return error.InvalidSpec;
            var count: usize = 0;
            while (entry + count < entries and spec.lengths[entry + count] == length) count += 1;
            try w.writeBits(@intCast(count), ilog(@intCast(entries - entry)));
            entry += count;
            length += 1;
            if (length > 32) return error.InvalidSpec;
        }
    } else {
        try w.writeBits(@intFromBool(spec.sparse), 1);
        for (spec.lengths) |length| {
            if (spec.sparse) {
                if (length == 0) {
                    try w.writeBits(0, 1);
                    continue;
                }
                try w.writeBits(1, 1);
            }
            if (length == 0 or length > 32) return error.InvalidSpec;
            try w.writeBits(length - 1, 5);
        }
    }

    try w.writeBits(spec.lookup_type, 4);
    if (spec.lookup_type != 0) {
        if (spec.lookup_type > 2) return error.InvalidSpec;
        if (spec.value_bits == 0 or spec.value_bits > 16) return error.InvalidSpec;
        try w.writeF32(spec.minimum_value);
        try w.writeF32(spec.delta_value);
        try w.writeBits(spec.value_bits - 1, 4);
        try w.writeBits(@intFromBool(spec.sequence_p), 1);

        const count: u64 = if (spec.lookup_type == 1)
            lookup1Values(@intCast(entries), spec.dimensions)
        else
            @as(u64, @intCast(entries)) * spec.dimensions;
        if (count > (1 << 21)) return error.InvalidSpec;
        if (spec.multiplicands.len != 0 and spec.multiplicands.len != count) {
            return error.InvalidSpec;
        }
        const mask: u32 = (@as(u32, 1) << @intCast(spec.value_bits)) - 1;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const value: u16 = if (spec.multiplicands.len != 0)
                spec.multiplicands[i]
            else
                @intCast(i & mask);
            try w.writeBits(value, spec.value_bits);
        }
    }
}

pub const Floor0Spec = struct {
    order: u8 = 8,
    rate: u16 = 44_100,
    bark_map_size: u16 = 64,
    amplitude_bits: u8 = 6,
    amplitude_offset: u8 = 40,
    books: []const u8 = &.{0},
};

fn writeFloor0(w: *BitWriter, spec: Floor0Spec) !void {
    if (spec.books.len == 0 or spec.books.len > 16) return error.InvalidSpec;
    try w.writeBits(spec.order, 8);
    try w.writeBits(spec.rate, 16);
    try w.writeBits(spec.bark_map_size, 16);
    try w.writeBits(spec.amplitude_bits, 6);
    try w.writeBits(spec.amplitude_offset, 8);
    try w.writeBits(@intCast(spec.books.len - 1), 4);
    for (spec.books) |book| try w.writeBits(book, 8);
}

pub const Floor1ClassSpec = struct {
    dimensions: u8 = 2,
    subclasses: u8 = 0,
    masterbook: u8 = 0,
    /// `2^subclasses` entries; 0xFF writes the "unused" sentinel (0).
    books: []const u8 = &.{},
};

pub const Floor1Spec = struct {
    partition_class: []const u8 = &.{},
    classes: []const Floor1ClassSpec = &.{},
    multiplier: u8 = 2,
    rangebits: u4 = 7,
    /// X values after the implicit [0, 2^rangebits], in list order.
    xs: []const u16 = &.{},
};

fn writeFloor1(w: *BitWriter, spec: Floor1Spec) !void {
    if (spec.partition_class.len > 31) return error.InvalidSpec;
    var maximum_class: i16 = -1;
    for (spec.partition_class) |class| {
        if (class > 15) return error.InvalidSpec;
        if (@as(i16, class) > maximum_class) maximum_class = class;
        if (class >= spec.classes.len) return error.InvalidSpec;
    }
    try w.writeBits(@intCast(spec.partition_class.len), 5);
    for (spec.partition_class) |class| try w.writeBits(class, 4);

    var expected_x: usize = 0;
    for (spec.classes, 0..) |class, i| {
        try w.writeBits(class.dimensions - 1, 3);
        try w.writeBits(class.subclasses, 2);
        if (class.subclasses != 0) try w.writeBits(class.masterbook, 8);
        const book_count: usize = @as(usize, 1) << @intCast(class.subclasses);
        if (class.books.len != book_count) return error.InvalidSpec;
        for (class.books) |book| {
            try w.writeBits(if (book == 0xFF) 0 else @as(u16, book) + 1, 8);
        }
        _ = i;
    }
    for (spec.partition_class) |class| expected_x += spec.classes[class].dimensions;
    if (spec.xs.len != expected_x) return error.InvalidSpec;

    try w.writeBits(spec.multiplier - 1, 2);
    try w.writeBits(spec.rangebits, 4);
    for (spec.xs) |x| try w.writeBits(x, spec.rangebits);
}

pub const ResidueSpec = struct {
    residue_type: u16 = 2,
    begin: u32 = 0,
    end: u32 = 0,
    partition_size: u32 = 1,
    classifications: u8 = 1,
    classbook: u8 = 0,
    cascade: []const u8 = &.{0},
    /// Per classification, the books for the stages selected by `cascade`.
    books: []const []const u8 = &.{},
};

fn writeResidue(w: *BitWriter, spec: ResidueSpec) !void {
    if (spec.classifications == 0 or spec.cascade.len != spec.classifications) {
        return error.InvalidSpec;
    }
    try w.writeBits(spec.residue_type, 16);
    try w.writeBits(spec.begin, 24);
    try w.writeBits(spec.end, 24);
    try w.writeBits(spec.partition_size - 1, 24);
    try w.writeBits(@as(u32, spec.classifications) - 1, 6);
    try w.writeBits(spec.classbook, 8);
    for (spec.cascade) |cascade| {
        try w.writeBits(cascade & 7, 3);
        if (cascade & 0xF8 != 0) {
            try w.writeBits(1, 1);
            try w.writeBits(cascade >> 3, 5);
        } else {
            try w.writeBits(0, 1);
        }
    }
    for (spec.cascade, 0..) |cascade, classification| {
        const provided: []const u8 = if (classification < spec.books.len) spec.books[classification] else &.{};
        var used: usize = 0;
        for (0..8) |stage| {
            if (cascade & (@as(u8, 1) << @intCast(stage)) != 0) used += 1;
        }
        if (provided.len != used) return error.InvalidSpec;
        var index: usize = 0;
        for (0..8) |stage| {
            if (cascade & (@as(u8, 1) << @intCast(stage)) != 0) {
                try w.writeBits(provided[index], 8);
                index += 1;
            }
        }
    }
}

pub const CouplingSpec = struct {
    magnitude: u8,
    angle: u8,
};

pub const MappingSpec = struct {
    submaps: u8 = 1,
    coupling: []const CouplingSpec = &.{},
    mux: []const u8 = &.{},
    floors: []const u8,
    residues: []const u8,
};

fn writeMapping(w: *BitWriter, spec: MappingSpec, channels: u16) !void {
    if (spec.submaps == 0 or spec.submaps > 16) return error.InvalidSpec;
    if (spec.floors.len != spec.submaps or spec.residues.len != spec.submaps) {
        return error.InvalidSpec;
    }
    try w.writeBits(0, 16);
    if (spec.submaps == 1) {
        try w.writeBits(0, 1);
    } else {
        try w.writeBits(1, 1);
        try w.writeBits(spec.submaps - 1, 4);
        if (spec.mux.len != channels) return error.InvalidSpec;
    }
    if (spec.coupling.len == 0) {
        try w.writeBits(0, 1);
    } else {
        try w.writeBits(1, 1);
        try w.writeBits(@intCast(spec.coupling.len - 1), 8);
        for (spec.coupling) |step| {
            if (step.magnitude >= channels or step.angle >= channels) return error.InvalidSpec;
            if (step.magnitude == step.angle) return error.InvalidSpec;
            try w.writeBits(step.magnitude, ilog(channels - 1));
            try w.writeBits(step.angle, ilog(channels - 1));
        }
    }
    try w.writeBits(0, 2); // reserved
    if (spec.submaps > 1) {
        for (spec.mux) |mux| try w.writeBits(mux, 4);
    }
    for (0..spec.submaps) |i| {
        try w.writeBits(0, 8); // time configuration placeholder
        try w.writeBits(spec.floors[i], 8);
        try w.writeBits(spec.residues[i], 8);
    }
}

pub const ModeSpec = struct {
    blockflag: bool = false,
    mapping: u8 = 0,
};

fn writeMode(w: *BitWriter, spec: ModeSpec) !void {
    try w.writeBits(@intFromBool(spec.blockflag), 1);
    try w.writeBits(0, 16); // window type
    try w.writeBits(0, 16); // transform type
    try w.writeBits(spec.mapping, 8);
}

/// Staged setup-header writer; counts must be declared before their bodies,
/// because that is how the bitstream is laid out.
pub const SetupWriter = struct {
    allocator: std.mem.Allocator,
    bits: BitWriter,

    pub fn init(allocator: std.mem.Allocator, codebook_count: u8) !SetupWriter {
        var bits = BitWriter.init(allocator);
        errdefer bits.deinit();
        try bits.writeBytes("\x05vorbis");
        try bits.writeBits(codebook_count - 1, 8);
        return .{ .allocator = allocator, .bits = bits };
    }

    pub fn deinit(self: *SetupWriter) void {
        self.bits.deinit();
    }

    pub fn codebook(self: *SetupWriter, spec: CodebookSpec) !void {
        try writeCodebook(&self.bits, spec);
    }

    pub fn times(self: *SetupWriter, count: u8) !void {
        try self.bits.writeBits(count - 1, 6);
        for (0..count) |_| try self.bits.writeBits(0, 16);
    }

    pub fn floors(self: *SetupWriter, count: u8) !void {
        try self.bits.writeBits(count - 1, 6);
    }

    pub fn floor0(self: *SetupWriter, spec: Floor0Spec) !void {
        try self.bits.writeBits(0, 16);
        try writeFloor0(&self.bits, spec);
    }

    pub fn floor1(self: *SetupWriter, spec: Floor1Spec) !void {
        try self.bits.writeBits(1, 16);
        try writeFloor1(&self.bits, spec);
    }

    pub fn residues(self: *SetupWriter, count: u8) !void {
        try self.bits.writeBits(count - 1, 6);
    }

    pub fn residue(self: *SetupWriter, spec: ResidueSpec) !void {
        try writeResidue(&self.bits, spec);
    }

    pub fn mappings(self: *SetupWriter, count: u8) !void {
        try self.bits.writeBits(count - 1, 6);
    }

    pub fn mapping(self: *SetupWriter, spec: MappingSpec, channels: u16) !void {
        try writeMapping(&self.bits, spec, channels);
    }

    pub fn modes(self: *SetupWriter, count: u8) !void {
        try self.bits.writeBits(count - 1, 6);
    }

    pub fn mode(self: *SetupWriter, spec: ModeSpec) !void {
        try writeMode(&self.bits, spec);
    }

    pub fn finish(self: *SetupWriter) ![]u8 {
        return self.finishWithFraming(1);
    }

    /// The framing bit is the last field of the setup header; a test can write
    /// zero here to prove the parser checks it.
    pub fn finishWithFraming(self: *SetupWriter, framing: u1) ![]u8 {
        try self.bits.writeBits(framing, 1);
        return self.bits.take();
    }
};

/// A complete, structurally valid Ogg/Vorbis file: two channels, one codebook,
/// one floor, one residue, one mapping, one mode, one EOS page. Header fields
/// are unremarkable on purpose; the fuzzer mutates from here.
pub fn minimalFile(allocator: std.mem.Allocator) ![]u8 {
    const ident = try identification(allocator, .{});
    defer allocator.free(ident);
    const comment_packet = try comment(allocator, "zig-audio", &.{});
    defer allocator.free(comment_packet);

    var setup = try SetupWriter.init(allocator, 1);
    defer setup.deinit();
    try setup.codebook(.{ .lengths = &.{ 1, 1 } });
    try setup.times(1);
    try setup.floors(1);
    try setup.floor1(.{});
    try setup.residues(1);
    try setup.residue(.{
        .residue_type = 0,
        .classifications = 1,
        .cascade = &.{0},
    });
    try setup.mappings(1);
    try setup.mapping(.{ .floors = &.{0}, .residues = &.{0} }, 2);
    try setup.modes(1);
    try setup.mode(.{});
    const setup_packet = try setup.finish();
    defer allocator.free(setup_packet);

    var writer = ogg_build.Writer.init(allocator, 0x5A17_0001);
    defer writer.deinit();
    try writer.addPage(ogg.Flag.bos, 0, &.{ident});
    try writer.addPage(0, 0, &.{ comment_packet, setup_packet });
    const audio = [_]u8{ 0x00, 0x12, 0x34, 0x56 };
    try writer.addPage(ogg.Flag.eos, 1024, &.{&audio});
    return writer.finish();
}
