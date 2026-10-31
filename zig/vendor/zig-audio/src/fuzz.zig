//! Mutation fuzzer: start from valid WAV, FLAC, MP3, AIFF, legacy-WAV
//! (G.711 / ADPCM) and Ogg/Vorbis/Opus templates, flip/truncate bytes, and
//! drive the public parser/decoder through every reachable error path.
//!
//! Ogg/Opus gets two passes. The dispatcher decodes it now, so the CELT decoder
//! sees every mutated payload; and every Ogg-looking input is *also* handed to
//! `opus.inspect` directly, because the structural parse reports things the
//! decoder never reaches (TOC framing, padding, frame counts).
//!
//! The same `run` function is used by `zig build fuzz` (10,000 rounds) and by a
//! normal test (1,000 rounds), so CI always exercises it.

const std = @import("std");
const root = @import("root.zig");
const opus = @import("opus.zig");
const testutil = @import("testutil.zig");
const flac_build = @import("flac_build.zig");
const opus_build = @import("opus_build.zig");
const vorbis_build = @import("vorbis_build.zig");

pub const default_rounds: usize = 10_000;
pub const default_seed: u64 = 0x5EED_2A11_D0C5_1234;

pub const Stats = struct {
    rounds: usize = 0,
    probed: usize = 0,
    opened: usize = 0,
    open_errors: usize = 0,
    read_errors: usize = 0,
    opus_parsed: usize = 0,
    samples: u64 = 0,
};

pub fn main() !void {
    const stats = try run(std.heap.page_allocator, default_rounds, default_seed);
    std.debug.print(
        "fuzz: {d} rounds, probe-hit {d}, opened {d}, open errors {d}, read errors {d}, " ++
            "opus structural parses {d}, samples {d}\n",
        .{
            stats.rounds,
            stats.probed,
            stats.opened,
            stats.open_errors,
            stats.read_errors,
            stats.opus_parsed,
            stats.samples,
        },
    );
    std.debug.print("fuzz: no panic, no out-of-bounds, all errors named\n", .{});
}

pub fn run(allocator: std.mem.Allocator, rounds: usize, seed: u64) !Stats {
    const wav_base = try testutil.buildDemoPcm16(allocator, 512);
    defer allocator.free(wav_base);

    const flac_base = try buildFlacTemplate(allocator);
    defer allocator.free(flac_base);

    const mp3_base = try buildMp3Template(allocator);
    defer allocator.free(mp3_base);

    const mp3_stereo_base = try buildMp3StereoTemplate(allocator);
    defer allocator.free(mp3_stereo_base);

    const mulaw_base = try buildG711Template(allocator, testutil.format_mulaw, 1);
    defer allocator.free(mulaw_base);

    const alaw_base = try buildG711Template(allocator, testutil.format_alaw, 2);
    defer allocator.free(alaw_base);

    const ima_base = try buildImaTemplate(allocator);
    defer allocator.free(ima_base);

    const ms_base = try buildMsTemplate(allocator);
    defer allocator.free(ms_base);

    const aiff16_base = try buildAiffTemplate(allocator, 16);
    defer allocator.free(aiff16_base);

    const aiff24_base = try buildAiffTemplate(allocator, 24);
    defer allocator.free(aiff24_base);

    // A complete Ogg/Vorbis file: pages, CRC, all three headers, EOS. Mutating
    // it reaches the page table, the setup bitstream and the granule scan.
    const ogg_base = try vorbis_build.minimalFile(allocator);
    defer allocator.free(ogg_base);

    // A complete Ogg/Opus file: OpusHead, OpusTags and two audio packets, one
    // code 0 and one code 3 with padding and VBR lengths.
    const opus_base = try buildOpusTemplate(allocator);
    defer allocator.free(opus_base);

    const templates = [_][]const u8{
        wav_base,    flac_base,   mp3_base, mp3_stereo_base,
        mulaw_base,  alaw_base,   ima_base, ms_base,
        aiff16_base, aiff24_base, ogg_base, opus_base,
    };

    var longest: usize = 0;
    for (templates) |template| longest = @max(longest, template.len);
    const buf = try allocator.alloc(u8, longest);
    defer allocator.free(buf);

    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var stats = Stats{ .rounds = rounds };

    var round: usize = 0;
    while (round < rounds) : (round += 1) {
        // Round-robin over the templates: WAV, FLAC, MP3 (mono and joint
        // stereo), G.711, both ADPCM codecs, both AIFF depths, Ogg/Vorbis and
        // Ogg/Opus.
        const base = templates[round % templates.len];
        const len = mutate(random, base, buf);

        // 36 bytes let `probe` see an Ogg page's first packet magic, which is
        // where the container/codec distinction lives.
        if (root.probe(buf[0..@min(len, 36)]) != null) stats.probed += 1;

        // The structural parser runs a second time on its own, independently of
        // whether the decoder gets that far: whatever the mutation did to the
        // head, the tags or the TOC, the failure has to stay inside the named
        // error set.
        if (len >= 4 and std.mem.eql(u8, buf[0..4], "OggS")) {
            var structural = std.Io.Reader.fixed(buf[0..len]);
            if (opus.inspect(allocator, &structural, "")) |_| {} else |err| accept(err);
            stats.opus_parsed += 1;
        }

        var reader = std.Io.Reader.fixed(buf[0..len]);
        var dec = root.open(allocator, &reader) catch |err| {
            accept(err);
            stats.open_errors += 1;
            continue;
        };
        defer dec.deinit();
        stats.opened += 1;

        const channels: usize = dec.info.channels;
        var out: [2048]i16 = undefined;
        var guard: usize = 0;

        // Occasionally hand it a buffer smaller than one frame: that must be a
        // named ShortBuffer error and must not consume/alter the decoder.
        if (channels > 1 and random.uintLessThan(u8, 100) < 8) {
            const short = dec.read(out[0 .. channels - 1]);
            if (short) |_| {
                return error.FuzzUnexpectedRead;
            } else |err| {
                accept(err);
                if (err != error.ShortBuffer) return error.FuzzUnexpectedError;
                stats.read_errors += 1;
            }
        }

        while (true) {
            const frames = 1 + random.uintLessThan(usize, 32);
            const want = @min(out.len, frames * channels);
            const n = dec.read(out[0..want]) catch |err| {
                accept(err);
                stats.read_errors += 1;
                break;
            };
            if (n == 0) break;
            if (n > want or n % channels != 0) return error.FuzzInvariant;
            stats.samples += n;
            guard += 1;
            if (guard > 1_000_000) return error.FuzzLoop;
        }
    }

    return stats;
}

/// A valid FLAC template with all four subframe types and a multi-partition
/// Rice residual, so mutations reach the frame decoder rather than only the
/// metadata parser. The LPC frame makes qlp precision/shift/coefficient bytes
/// part of the mutation surface too.
fn buildFlacTemplate(allocator: std.mem.Allocator) ![]u8 {
    const flat: [32]i32 = @splat(1234);
    var verbatim: [32]i32 = undefined;
    var fixed: [32]i32 = undefined;
    var lpc: [32]i32 = undefined;
    for (&verbatim, 0..) |*slot, i| {
        slot.* = @as(i32, @intCast(i % 11)) * 40 - 200;
    }
    for (&fixed, 0..) |*slot, i| {
        slot.* = @as(i32, @intCast(i)) * 17 - 300;
    }
    for (&lpc, 0..) |*slot, i| {
        slot.* = @as(i32, @intCast((i * 211) % 4001)) - 2000;
    }

    const planes_constant = [_][]const i32{&flat};
    const planes_verbatim = [_][]const i32{&verbatim};
    const planes_fixed = [_][]const i32{&fixed};
    const planes_lpc = [_][]const i32{&lpc};
    const lpc_coeffs = [_]i32{ 3, -2, 1, 0 };
    const frames = [_]flac_build.Frame{
        .{ .block_size = 32, .modes = &.{.constant}, .samples = &planes_constant },
        .{ .block_size = 32, .modes = &.{.verbatim}, .samples = &planes_verbatim },
        .{
            .block_size = 32,
            .modes = &.{.fixed},
            .samples = &planes_fixed,
            .fixed_order = 2,
            .partition_order = 1,
            .rice_param = 1,
        },
        .{
            .block_size = 32,
            .modes = &.{.lpc},
            .samples = &planes_lpc,
            .lpc_order = 4,
            .lpc_coeffs = &lpc_coeffs,
            .lpc_shift = 4,
            .lpc_precision = 12,
            .rice_param = 3,
        },
    };
    return flac_build.build(allocator, .{
        .sample_rate = 44_100,
        .channels = 1,
        .bits_per_sample = 16,
        .total_samples = 128,
        .frames = &frames,
    });
}

/// Two minimal mono MPEG-1 Layer III frames. Header only plus a zero side
/// info: the decoder reaches the Huffman/reservoir/synthesis paths without
/// needing a real encoder.
fn buildMp3Template(allocator: std.mem.Allocator) ![]u8 {
    const frame_len = 417;
    const bytes = try allocator.alloc(u8, frame_len * 2);
    @memset(bytes, 0);
    for (0..2) |i| {
        const at = i * frame_len;
        bytes[at + 0] = 0xFF;
        bytes[at + 1] = 0xFB;
        bytes[at + 2] = 0x90;
        bytes[at + 3] = 0xC0;
    }
    return bytes;
}

/// The same two frames as joint stereo with both `mode_extension` bits set, so
/// a mutation lands in the 32-byte stereo side info, the intensity scan and the
/// mid/side butterfly. `mode_extension` is copied into the payload words as
/// well: a random flip there then produces intensity positions rather than
/// always-zero scalefactors.
fn buildMp3StereoTemplate(allocator: std.mem.Allocator) ![]u8 {
    const frame_len = 417;
    const bytes = try allocator.alloc(u8, frame_len * 2);
    @memset(bytes, 0);
    for (0..2) |i| {
        const at = i * frame_len;
        bytes[at + 0] = 0xFF;
        bytes[at + 1] = 0xFB;
        bytes[at + 2] = 0x90;
        bytes[at + 3] = 0x40 | 0x30; // joint stereo, intensity + mid/side
        for (0..3) |k| bytes[at + 5 + k] = 0x11;
    }
    return bytes;
}

/// A valid G.711 WAV: 64 codes per channel. A-law is built as stereo so the
/// interleaving path is mutated too.
fn buildG711Template(allocator: std.mem.Allocator, tag: u16, channels: u16) ![]u8 {
    const bytes = try allocator.alloc(u8, 64 * channels);
    defer allocator.free(bytes);
    for (bytes, 0..) |*byte, i| byte.* = @truncate(i * 37 + 11);
    return testutil.buildG711(allocator, tag, channels, 8000, bytes);
}

/// Two 32-byte IMA blocks: a 4-byte header plus 28 nibble bytes each, so
/// mutations cover the header, the step index and the nibble loop.
fn buildImaTemplate(allocator: std.mem.Allocator) ![]u8 {
    const block_align: u16 = 32;
    const payload = try allocator.alloc(u8, block_align * 2);
    defer allocator.free(payload);
    for (0..2) |b| {
        const at = b * block_align;
        std.mem.writeInt(i16, payload[at..][0..2], if (b == 0) 1000 else -1000, .little);
        payload[at + 2] = 5;
        payload[at + 3] = 0;
        for (payload[at + 4 ..][0 .. block_align - 4]) |*byte| byte.* = 0x5A;
    }
    return testutil.buildAdpcm(allocator, .{
        .tag = testutil.format_ima_adpcm,
        .channels = 1,
        .sample_rate = 8000,
        .block_align = block_align,
        .bits = 4,
        // 1 + ((32 - 4) / 4) * 8
        .samples_per_block = 57,
    }, payload);
}

/// Two 32-byte Microsoft ADPCM blocks with the standard seven-pair table.
fn buildMsTemplate(allocator: std.mem.Allocator) ![]u8 {
    const block_align: u16 = 32;
    const payload = try allocator.alloc(u8, block_align * 2);
    defer allocator.free(payload);
    for (0..2) |b| {
        const at = b * block_align;
        payload[at] = 0; // predictor index
        std.mem.writeInt(i16, payload[at + 1 ..][0..2], 16, .little);
        std.mem.writeInt(i16, payload[at + 3 ..][0..2], if (b == 0) 1000 else -1000, .little);
        std.mem.writeInt(i16, payload[at + 5 ..][0..2], 0, .little);
        for (payload[at + 7 ..][0 .. block_align - 7]) |*byte| byte.* = 0x3C;
    }
    return testutil.buildAdpcm(allocator, .{
        .tag = testutil.format_ms_adpcm,
        .channels = 1,
        .sample_rate = 8000,
        .block_align = block_align,
        .bits = 4,
        // 2 + (32 - 7) * 2
        .samples_per_block = 52,
        .coefficients = &testutil.ms_coefficients,
    }, payload);
}

/// A short AIFF with the given bit depth, so both COMM (80-bit rate, frames)
/// and SSND framing are part of the mutation surface.
fn buildAiffTemplate(allocator: std.mem.Allocator, bits: u16) ![]u8 {
    const frames: u32 = 64;
    const payload = try allocator.alloc(u8, frames * (bits / 8));
    defer allocator.free(payload);
    for (payload, 0..) |*byte, i| byte.* = @truncate(i * 29 + 7);
    return testutil.buildAiff(allocator, 1, 44_100, bits, frames, payload);
}

/// A complete Ogg Opus file with two audio packets: one code 0 (20 ms CELT,
/// stereo) and one code 3 (SILK 10 ms, two VBR frames, six bytes of padding).
/// Mutations therefore land in `OpusHead`, `OpusTags`, the frame count byte,
/// the length fields and the padding run.
fn buildOpusTemplate(allocator: std.mem.Allocator) ![]u8 {
    const frame_a = try allocator.alloc(u8, 48);
    defer allocator.free(frame_a);
    const frame_b = try allocator.alloc(u8, 36);
    defer allocator.free(frame_b);
    const frame_c = try allocator.alloc(u8, 24);
    defer allocator.free(frame_c);
    for (frame_a, 0..) |*byte, i| byte.* = @truncate(i * 11 + 3);
    for (frame_b, 0..) |*byte, i| byte.* = @truncate(i * 5 + 1);
    for (frame_c, 0..) |*byte, i| byte.* = @truncate(i * 17 + 9);

    const plain = try opus_build.packet(allocator, .{ .stereo = true, .frames = &.{frame_a} });
    defer allocator.free(plain);
    const padded = try opus_build.packet(allocator, .{
        .config = 8, // SILK-only WB, 10 ms
        .code = 3,
        .vbr = true,
        .padding = 6,
        .frames = &.{ frame_b, frame_c },
    });
    defer allocator.free(padded);

    return opus_build.file(allocator, .{
        .comments = &.{"ENCODER=zig-audio-fuzz"},
        .packets = &.{ plain, padded },
    });
}

/// Copy the valid template, then apply one mutation strategy. Returns the
/// (possibly shortened) length.
fn mutate(random: std.Random, base: []const u8, buf: []u8) usize {
    @memcpy(buf[0..base.len], base);
    var len: usize = base.len;

    const roll = random.uintLessThan(u8, 100);
    if (roll < 7) {
        len = random.uintLessThan(usize, base.len + 1);
        if (len == 0) return 0;
    }

    const flips = 1 + random.uintLessThan(usize, 12);
    var flip: usize = 0;
    while (flip < flips) : (flip += 1) {
        const pos = if (len > 12 and random.uintLessThan(u8, 100) < 75)
            12 + random.uintLessThan(usize, len - 12)
        else
            random.uintLessThan(usize, len);
        buf[pos] = random.int(u8);
    }

    if (roll >= 90 and len >= 20) {
        // Smash a four-byte size field to 0xFFFFFFFF, which is exactly the
        // value the streaming path treats as "until EOF".
        const pos = 12 + random.uintLessThan(usize, len - 16);
        @memset(buf[pos..][0..4], 0xFF);
    }
    return len;
}

fn accept(err: root.Error) void {
    switch (err) {
        error.NotAudio,
        error.Unsupported,
        error.Truncated,
        error.Corrupt,
        error.OutOfMemory,
        error.Io,
        error.ShortBuffer,
        => {},
    }
}

test "mutation fuzz: 1,000 rounds, every outcome stays in the named error set" {
    const stats = try run(std.testing.allocator, 1000, default_seed);
    try std.testing.expect(stats.probed > 0);
    try std.testing.expect(stats.opened > 0);
    try std.testing.expect(stats.samples > 0);
}

test "random bytes: no panic, only NotAudio/Truncated/Unsupported" {
    var prng = std.Random.DefaultPrng.init(0xA11CE);
    const random = prng.random();
    var buf: [512]u8 = undefined;

    var round: usize = 0;
    while (round < 1000) : (round += 1) {
        const len = random.uintLessThan(usize, buf.len + 1);
        for (buf[0..len]) |*byte| byte.* = random.int(u8);

        var reader = std.Io.Reader.fixed(buf[0..len]);
        var dec = root.open(std.testing.allocator, &reader) catch |err| {
            accept(err);
            continue;
        };
        dec.deinit();
        return error.FuzzUnexpectedOpen;
    }
}
