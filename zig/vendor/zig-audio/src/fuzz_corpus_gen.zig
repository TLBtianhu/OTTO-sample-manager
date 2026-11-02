//! Generate the committed fuzz corpus in `src/fuzz_corpus/`.
//!
//! Run from the repository root:
//!
//!     zig run tools/gen_fuzz_corpus.zig
//!
//! Every sample is built from the same structural helpers the tests use, so
//! the bytes in the repository are reproducible rather than hand-edited
//! blobs. The program also decodes each sample and prints the stage and error
//! it actually produces; `src/fuzz_corpus/corpus.json` must agree with that.
//!
//! This is a development tool, not part of the library build.

const std = @import("std");
const root = @import("root.zig");
const testutil = @import("testutil.zig");
const ogg = @import("ogg.zig");
const ogg_build = @import("ogg_build.zig");
const opus_build = @import("opus_build.zig");
const flac_build = @import("flac_build.zig");

const out_dir = "src/fuzz_corpus";

const serial: u32 = 0x0C0F_FFEE;

const Sample = struct {
    name: []const u8,
    family: []const u8,
    bytes: []const u8,
};

fn oggOpusBase(allocator: std.mem.Allocator) !struct { head: []u8, tags: []u8 } {
    return .{
        .head = try opus_build.head(allocator, .{}),
        .tags = try opus_build.tags(allocator, "zig-audio-corpus", &.{}),
    };
}

/// A complete Opus file whose audio page carries the supplied raw packets.
fn opusFile(allocator: std.mem.Allocator, packets: []const []const u8) ![]u8 {
    const base = try oggOpusBase(allocator);
    defer allocator.free(base.head);
    defer allocator.free(base.tags);

    var writer = ogg_build.Writer.init(allocator, serial);
    defer writer.deinit();
    try writer.addPage(ogg.Flag.bos, 0, &.{base.head});
    try writer.addPage(0, 0, &.{base.tags});
    try writer.addPage(ogg.Flag.eos, 312, packets);
    return writer.finish();
}

fn buildOggBosContinued(allocator: std.mem.Allocator) ![]u8 {
    const head = try opus_build.head(allocator, .{});
    defer allocator.free(head);
    return ogg_build.buildPage(allocator, .{
        .flags = ogg.Flag.bos | ogg.Flag.continued,
        .serial = serial,
        .segments = &.{19},
        .body = head,
    });
}

/// A page header that promises two laces (30 body bytes) but supplies ten.
fn buildOggBodyShort(allocator: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "OggS");
    try out.append(allocator, 0); // version
    try out.append(allocator, ogg.Flag.bos);
    try ogg_build.appendInt(&out, allocator, u64, 0, .little); // granule
    try ogg_build.appendInt(&out, allocator, u32, serial, .little);
    try ogg_build.appendInt(&out, allocator, u32, 0, .little); // sequence
    try ogg_build.appendInt(&out, allocator, u32, 0, .little); // CRC (never reached)
    try out.append(allocator, 2); // segment count
    try out.appendSlice(allocator, &.{ 10, 20 });
    try out.appendNTimes(allocator, 'A', 10);
    return out.toOwnedSlice(allocator);
}

fn buildOggCrc(allocator: std.mem.Allocator) ![]u8 {
    const head = try opus_build.head(allocator, .{});
    defer allocator.free(head);
    return ogg_build.buildPage(allocator, .{
        .flags = ogg.Flag.bos,
        .serial = serial,
        .segments = &.{19},
        .body = head,
        .crc_override = 0xDEAD_BEEF,
    });
}

/// A page whose only lace is 255, at EOS: the packet is still incomplete when
/// the physical stream ends.
fn buildOggEofMidPacket(allocator: std.mem.Allocator) ![]u8 {
    const base = try oggOpusBase(allocator);
    defer allocator.free(base.head);
    defer allocator.free(base.tags);

    var writer = ogg_build.Writer.init(allocator, serial);
    defer writer.deinit();
    try writer.addPage(ogg.Flag.bos, 0, &.{base.head});
    try writer.addPage(0, 0, &.{base.tags});
    const body = try allocator.alloc(u8, 255);
    defer allocator.free(body);
    for (body, 0..) |*byte, i| byte.* = @truncate(i * 7 + 3);
    try writer.addRawPage(ogg.Flag.eos, 0, &.{255}, body);
    return writer.finish();
}

/// A valid head and tags page followed by an audio page whose sequence number
/// skips one. The packet itself is well formed.
fn buildOggSequenceGap(allocator: std.mem.Allocator) ![]u8 {
    const base = try oggOpusBase(allocator);
    defer allocator.free(base.head);
    defer allocator.free(base.tags);

    var writer = ogg_build.Writer.init(allocator, serial);
    defer writer.deinit();
    try writer.addPage(ogg.Flag.bos, 0, &.{base.head});
    try writer.addPage(0, 0, &.{base.tags});
    writer.sequence = 3;
    try writer.addPage(ogg.Flag.eos, 312, &.{&.{0x00}});
    return writer.finish();
}

fn buildOpusTocOneByte(allocator: std.mem.Allocator) ![]u8 {
    return opusFile(allocator, &.{&.{0x03}});
}

fn buildOpusTocCode1Odd(allocator: std.mem.Allocator) ![]u8 {
    return opusFile(allocator, &.{&.{ 0x01, 0x00 }});
}

fn buildOpusTocCountZero(allocator: std.mem.Allocator) ![]u8 {
    return opusFile(allocator, &.{&.{ 0x03, 0x00 }});
}

fn buildOpusTocTooLong(allocator: std.mem.Allocator) ![]u8 {
    // Config 0 is 10 ms (480 samples); 13 frames are 6240 > 5760.
    return opusFile(allocator, &.{&.{ 0x03, 0x0D }});
}

fn buildFlacConstant(allocator: std.mem.Allocator) ![]u8 {
    const plane: [32]i32 = @splat(1234);
    const planes = [_][]const i32{&plane};
    const frames = [_]flac_build.Frame{
        .{ .block_size = 32, .modes = &.{.constant}, .samples = &planes },
    };
    return flac_build.build(allocator, .{
        .sample_rate = 44_100,
        .channels = 1,
        .bits_per_sample = 16,
        .total_samples = 32,
        .frames = &frames,
    });
}

/// The frame starts after `fLaC`, the metadata header and 34 STREAMINFO bytes.
const flac_frame_offset = 42;

fn buildFlacTruncatedFrame(allocator: std.mem.Allocator) ![]u8 {
    const full = try buildFlacConstant(allocator);
    defer allocator.free(full);
    // Drop the footer and two payload bytes: the bit reader hits EOF while
    // still inside the subframe.
    return allocator.dupe(u8, full[0 .. full.len - 4]);
}

fn buildFlacTruncatedHeader(allocator: std.mem.Allocator) ![]u8 {
    const full = try buildFlacConstant(allocator);
    defer allocator.free(full);
    return allocator.dupe(u8, full[0 .. flac_frame_offset + 3]);
}

/// A VALID frame header followed by a subframe whose wasted-bits unary run is
/// 32 zero bits. `BitReader.readUnary(31)` must name `Corrupt` instead of
/// spinning; the frame CRC is never reached.
fn buildFlacWastedOverrun(allocator: std.mem.Allocator) ![]u8 {
    const full = try buildFlacConstant(allocator);
    const body = flac_frame_offset + 7;
    std.debug.assert(full.len >= body + 5);
    full[body + 0] = 0x01; // pad 0, CONSTANT, wasted-bits flag = 1
    full[body + 1] = 0;
    full[body + 2] = 0;
    full[body + 3] = 0;
    full[body + 4] = 0;
    return full;
}

fn buildAiffCommShort(allocator: std.mem.Allocator) ![]u8 {
    var builder = try testutil.AiffBuilder.init(allocator);
    defer builder.deinit();
    const zeros: [12]u8 = @splat(0);
    try builder.addChunkSized("COMM", 12, &zeros);
    return builder.finish();
}

fn buildAiffNegativeRate(allocator: std.mem.Allocator) ![]u8 {
    var builder = try testutil.AiffBuilder.init(allocator);
    defer builder.deinit();
    var comm: [18]u8 = undefined;
    _ = testutil.aiffCommPayload(&comm, 1, 2, 16, 44_100);
    comm[8] |= 0x80; // sign bit: a negative sample rate
    try builder.addChunk("COMM", &comm);
    const payload = [_]u8{ 0, 1, 0, 2 };
    try testutil.addSsnd(&builder, &payload, 0);
    return builder.finish();
}

fn buildAiffFramesExceedSsnd(allocator: std.mem.Allocator) ![]u8 {
    var builder = try testutil.AiffBuilder.init(allocator);
    defer builder.deinit();
    var comm: [18]u8 = undefined;
    _ = testutil.aiffCommPayload(&comm, 1, 100, 16, 44_100);
    try builder.addChunk("COMM", &comm);
    try testutil.addSsnd(&builder, &[_]u8{ 0, 1, 0, 2 }, 0);
    return builder.finish();
}

fn buildAiffSsndBeforeComm(allocator: std.mem.Allocator) ![]u8 {
    var builder = try testutil.AiffBuilder.init(allocator);
    defer builder.deinit();
    const zeros: [8]u8 = @splat(0);
    try builder.addChunk("SSND", &zeros);
    var comm: [18]u8 = undefined;
    _ = testutil.aiffCommPayload(&comm, 1, 2, 16, 44_100);
    try builder.addChunk("COMM", &comm);
    return builder.finish();
}

fn buildImaTemplate(allocator: std.mem.Allocator, step_index: u8, total_bytes: usize) ![]u8 {
    const block_align: u16 = 32;
    const payload = try allocator.alloc(u8, total_bytes);
    defer allocator.free(payload);
    @memset(payload, 0);
    if (payload.len >= 4) {
        std.mem.writeInt(i16, payload[0..2], 1000, .little);
        payload[2] = step_index;
        payload[3] = 0;
    }
    return testutil.buildAdpcm(allocator, .{
        .tag = testutil.format_ima_adpcm,
        .channels = 1,
        .sample_rate = 8000,
        .block_align = block_align,
        .bits = 4,
        .samples_per_block = 57,
    }, payload);
}

fn buildImaStep89(allocator: std.mem.Allocator) ![]u8 {
    return buildImaTemplate(allocator, 89, 64);
}

fn buildImaShortTail(allocator: std.mem.Allocator) ![]u8 {
    return buildImaTemplate(allocator, 5, 35);
}

fn buildMsTemplate(allocator: std.mem.Allocator, predictor: u8, block_align: u16) ![]u8 {
    const payload = try allocator.alloc(u8, block_align * 2);
    defer allocator.free(payload);
    @memset(payload, 0);
    payload[0] = predictor;
    if (payload.len >= 7) {
        std.mem.writeInt(i16, payload[1..3], 16, .little);
        std.mem.writeInt(i16, payload[3..5], 1000, .little);
        std.mem.writeInt(i16, payload[5..7], 0, .little);
    }
    return testutil.buildAdpcm(allocator, .{
        .tag = testutil.format_ms_adpcm,
        .channels = 1,
        .sample_rate = 8000,
        .block_align = block_align,
        .bits = 4,
        .samples_per_block = 52,
        .coefficients = &testutil.ms_coefficients,
    }, payload);
}

fn buildMsBadPredictor(allocator: std.mem.Allocator) ![]u8 {
    return buildMsTemplate(allocator, 7, 32);
}

fn buildMsBlockAlignShort(allocator: std.mem.Allocator) ![]u8 {
    return buildMsTemplate(allocator, 0, 6);
}

fn append(samples: *std.ArrayList(Sample), sample: Sample) !void {
    try samples.append(std.heap.page_allocator, sample);
}

fn outcome(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var reader = std.Io.Reader.fixed(bytes);
    var dec = root.open(allocator, &reader) catch |err| {
        return std.fmt.allocPrint(allocator, "open:{s}", .{@errorName(err)});
    };
    defer dec.deinit();

    var out: [4096]i16 = undefined;
    var rounds: usize = 0;
    while (rounds < 100_000) : (rounds += 1) {
        const n = dec.read(&out) catch |err| {
            return std.fmt.allocPrint(allocator, "read:{s}", .{@errorName(err)});
        };
        if (n == 0) return std.fmt.allocPrint(allocator, "eof", .{});
    }
    return std.fmt.allocPrint(allocator, "loop", .{});
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var samples: std.ArrayList(Sample) = .empty;
    defer samples.deinit(allocator);

    try append(&samples, .{ .name = "ogg_bos_continued", .family = "ogg", .bytes = try buildOggBosContinued(allocator) });
    try append(&samples, .{ .name = "ogg_page_body_short", .family = "ogg", .bytes = try buildOggBodyShort(allocator) });
    try append(&samples, .{ .name = "ogg_page_crc", .family = "ogg", .bytes = try buildOggCrc(allocator) });
    try append(&samples, .{ .name = "ogg_eof_mid_packet", .family = "ogg", .bytes = try buildOggEofMidPacket(allocator) });
    try append(&samples, .{ .name = "ogg_sequence_gap", .family = "ogg", .bytes = try buildOggSequenceGap(allocator) });

    try append(&samples, .{ .name = "opus_toc_one_byte", .family = "opus_toc", .bytes = try buildOpusTocOneByte(allocator) });
    try append(&samples, .{ .name = "opus_toc_code1_odd", .family = "opus_toc", .bytes = try buildOpusTocCode1Odd(allocator) });
    try append(&samples, .{ .name = "opus_toc_count_zero", .family = "opus_toc", .bytes = try buildOpusTocCountZero(allocator) });
    try append(&samples, .{ .name = "opus_toc_too_long", .family = "opus_toc", .bytes = try buildOpusTocTooLong(allocator) });

    try append(&samples, .{ .name = "flac_frame_truncated", .family = "flac", .bytes = try buildFlacTruncatedFrame(allocator) });
    try append(&samples, .{ .name = "flac_header_truncated", .family = "flac", .bytes = try buildFlacTruncatedHeader(allocator) });
    try append(&samples, .{ .name = "flac_wasted_overrun", .family = "flac", .bytes = try buildFlacWastedOverrun(allocator) });

    try append(&samples, .{ .name = "aiff_comm_short", .family = "aiff", .bytes = try buildAiffCommShort(allocator) });
    try append(&samples, .{ .name = "aiff_negative_rate", .family = "aiff", .bytes = try buildAiffNegativeRate(allocator) });
    try append(&samples, .{ .name = "aiff_frames_exceed_ssnd", .family = "aiff", .bytes = try buildAiffFramesExceedSsnd(allocator) });
    try append(&samples, .{ .name = "aiff_ssnd_before_comm", .family = "aiff", .bytes = try buildAiffSsndBeforeComm(allocator) });

    try append(&samples, .{ .name = "adpcm_ima_step89", .family = "adpcm", .bytes = try buildImaStep89(allocator) });
    try append(&samples, .{ .name = "adpcm_ima_short_tail", .family = "adpcm", .bytes = try buildImaShortTail(allocator) });
    try append(&samples, .{ .name = "adpcm_ms_bad_predictor", .family = "adpcm", .bytes = try buildMsBadPredictor(allocator) });
    try append(&samples, .{ .name = "adpcm_ms_block_align_short", .family = "adpcm", .bytes = try buildMsBlockAlignShort(allocator) });

    const io = std.Io.Threaded.global_single_threaded.io();
    try std.Io.Dir.cwd().createDirPath(io, out_dir);

    for (samples.items) |sample| {
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}.bin", .{ out_dir, sample.name });
        defer allocator.free(path);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = sample.bytes });

        const result = try outcome(allocator, sample.bytes);
        defer allocator.free(result);
        std.debug.print("{s:32} {s:8} {d:5} bytes  {s}\n", .{
            sample.name, sample.family, sample.bytes.len, result,
        });
    }
}
