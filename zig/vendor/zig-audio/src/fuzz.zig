//! Mutation fuzzer: start from a valid WAV and a valid FLAC, flip/truncate
//! bytes, and drive the public parser/decoder through every reachable error
//! path.
//!
//! The same `run` function is used by `zig build fuzz` (10,000 rounds) and by a
//! normal test (1,000 rounds), so CI always exercises it.

const std = @import("std");
const root = @import("root.zig");
const testutil = @import("testutil.zig");
const flac_build = @import("flac_build.zig");

pub const default_rounds: usize = 10_000;
pub const default_seed: u64 = 0x5EED_2A11_D0C5_1234;

pub const Stats = struct {
    rounds: usize = 0,
    probed: usize = 0,
    opened: usize = 0,
    open_errors: usize = 0,
    read_errors: usize = 0,
    samples: u64 = 0,
};

pub fn main() !void {
    const stats = try run(std.heap.page_allocator, default_rounds, default_seed);
    std.debug.print(
        "fuzz: {d} rounds, probe-hit {d}, opened {d}, open errors {d}, read errors {d}, samples {d}\n",
        .{ stats.rounds, stats.probed, stats.opened, stats.open_errors, stats.read_errors, stats.samples },
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

    const buf = try allocator.alloc(
        u8,
        @max(@max(wav_base.len, flac_base.len), @max(mp3_base.len, mp3_stereo_base.len)),
    );
    defer allocator.free(buf);

    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var stats = Stats{ .rounds = rounds };

    var round: usize = 0;
    while (round < rounds) : (round += 1) {
        // Split the rounds across WAV, FLAC and MP3; the MP3 rounds alternate
        // between a mono and a joint-stereo frame so the stereo side-info,
        // intensity and mid/side paths are fuzzed too.
        const base = switch (round % 4) {
            0 => wav_base,
            1 => flac_base,
            2 => mp3_base,
            else => mp3_stereo_base,
        };
        const len = mutate(random, base, buf);

        if (root.probe(buf[0..@min(len, 12)]) != null) stats.probed += 1;

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
