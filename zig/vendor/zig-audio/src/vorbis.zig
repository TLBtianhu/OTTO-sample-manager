//! Vorbis I entry point: open the first Vorbis stream, parse its three headers
//! and report the stream length.
//!
//! The readers live in `vorbis_meta.zig` and the parsed data model in
//! `vorbis_types.zig`. Both are re-exported here, so callers keep using
//! `vorbis.Info`, `vorbis.Setup`, `vorbis.parseSetup` and `vorbis.open`.
//!
//! `open` walks the whole first audio stream to read its last granule position
//! (total PCM frames), which is how the header-only view reports a length. The
//! public dispatcher does not use it: it streams instead, so `total_frames`
//! there becomes known only at end of stream.

const std = @import("std");
const types = @import("types.zig");
const ogg = @import("ogg.zig");
const codebook_mod = @import("vorbis_codebook.zig");
const hdr = @import("vorbis_types.zig");
const meta = @import("vorbis_meta.zig");

pub const Error = types.Error;
pub const Codebook = codebook_mod.Codebook;

// Header data model (see `vorbis_types.zig`).
pub const Identification = hdr.Identification;
pub const Setup = hdr.Setup;
pub const Floor = hdr.Floor;
pub const Floor0 = hdr.Floor0;
pub const Floor1 = hdr.Floor1;
pub const Floor1Class = hdr.Floor1Class;
pub const Residue = hdr.Residue;
pub const Coupling = hdr.Coupling;
pub const Mapping = hdr.Mapping;
pub const Mode = hdr.Mode;

// Parser limits and the readers themselves (see `vorbis_meta.zig`).
pub const max_floors = meta.max_floors;
pub const max_residues = meta.max_residues;
pub const max_mappings = meta.max_mappings;
pub const max_modes = meta.max_modes;
pub const max_coupling_steps = meta.max_coupling_steps;
pub const max_floor1_x = meta.max_floor1_x;

pub const parseIdentification = meta.parseIdentification;
pub const parseComment = meta.parseComment;
pub const parseSetup = meta.parseSetup;

pub const Info = struct {
    version: u32 = 0,
    channels: u16 = 0,
    sample_rate: u32 = 0,
    bitrate_maximum: i32 = 0,
    bitrate_nominal: i32 = 0,
    bitrate_minimum: i32 = 0,
    blocksize_0: u16 = 0,
    blocksize_1: u16 = 0,
    /// Last granule position of the first audio stream: Vorbis frames.
    /// Null when no page carried a granule position.
    total_frames: ?u64 = null,
    setup: Setup = .{},

    pub fn deinit(self: *Info, allocator: std.mem.Allocator) void {
        self.setup.deinit(allocator);
        self.* = .{};
    }
};

/// Open the first Vorbis stream in `reader`, parse all three headers, and scan
/// to its end for the last granule position. Header-only view: it consumes the
/// whole stream to learn the length and produces no PCM; the public dispatcher
/// uses `vorbis_decoder.Decoder`, which streams.
pub fn open(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    prefix: []const u8,
) Error!Info {
    var demux = try ogg.Demuxer.init(allocator, reader, prefix);
    defer demux.deinit();

    if (demux.streamCodec() != .vorbis) return error.Unsupported;

    const identification_packet = (try demux.nextPacket()) orelse return error.Truncated;
    const identification = try parseIdentification(identification_packet);

    const comment_packet = (try demux.nextPacket()) orelse return error.Truncated;
    try parseComment(comment_packet);

    const setup_packet = (try demux.nextPacket()) orelse return error.Truncated;
    var setup = try parseSetup(allocator, setup_packet, identification.channels);
    errdefer setup.deinit(allocator);

    const total_frames = try demux.finish();

    return .{
        .version = identification.version,
        .channels = identification.channels,
        .sample_rate = identification.sample_rate,
        .bitrate_maximum = identification.bitrate_maximum,
        .bitrate_nominal = identification.bitrate_nominal,
        .bitrate_minimum = identification.bitrate_minimum,
        .blocksize_0 = identification.blocksize_0,
        .blocksize_1 = identification.blocksize_1,
        .total_frames = total_frames,
        .setup = setup,
    };
}
