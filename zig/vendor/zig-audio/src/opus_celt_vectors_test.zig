//! CELT conformance against `ffmpeg -f f32le` / `-f s16le`, end to end.
//!
//! Three real streams, all pure CELT (configuration 31, 20 ms, 48 kHz):
//!
//!   * `opus-48k-128-20ms.opus` — stereo, 2 s;
//!   * `opus-48k-96.opus`       — stereo, 3 s;
//!   * `opus-48k-mono.opus`     — mono, 3 s.
//!
//! The corpus lives outside the repository in `..\zig-audio-vectors\ogg`, so a
//! checkout without it prints one line and stays green.
//!
//! What is compared, and why the thresholds are what they are:
//!
//!   * f32: SNR >= 90 dB and per-sample max < 1e-4. This is the honest bar for
//!     "same decoder": the reference is a different float implementation, and
//!     the residual floor of two float CELT decoders is around 1e-7.
//!   * s16: SNR >= 70 dB and max <= 8 LSB. 70 dB is structural, not sloppy —
//!     two different i16 rounding rules cost about 0.5 LSB (~72 dB) on a
//!     full-scale signal, so a 90 dB bar in the s16 domain would be measuring
//!     the rounding rule rather than the decoder.
//!   * sample count identical to ffmpeg's, which is `granule - pre_skip`:
//!     96000 / 144000 / 144000. The pre-skip is *dropped*, not offset — see
//!     `opus.zig`'s decoder comment.
//!
//! For reference, the two independent reference decoders do not agree with
//! each other at 90 dB: ffmpeg's native CELT decoder and the libopus build
//! linked into this ffmpeg differ by about 77 dB on these same files, because
//! libopus uses a polynomial `exp2` approximation (its `FLOAT_APPROX` build)
//! where ffmpeg uses `exp2f`. That is why this implementation uses the exact
//! function: it is what the comparison target uses.

const std = @import("std");
const root = @import("root.zig");
const opus = @import("opus.zig");
const compare = @import("compare.zig");
const testing = std.testing;

const vector_dir = "..\\zig-audio-vectors\\ogg";

const Vector = struct {
    name: []const u8,
    channels: usize,
    frames: usize,
};

const vectors = [_]Vector{
    .{ .name = "opus-48k-128-20ms.opus", .channels = 2, .frames = 96_000 },
    .{ .name = "opus-48k-96.opus", .channels = 2, .frames = 144_000 },
    .{ .name = "opus-48k-mono.opus", .channels = 1, .frames = 144_000 },
};

fn readVector(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(allocator, "{s}\\{s}", .{ vector_dir, name });
    defer allocator.free(path);
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(8 << 20)) catch |err| switch (err) {
        error.FileNotFound => error.SkipZigTest,
        else => err,
    };
}

const Decoded = struct {
    pcm_f32: []f32,
    pcm_i16: []i16,

    fn deinit(self: Decoded, allocator: std.mem.Allocator) void {
        allocator.free(self.pcm_f32);
        allocator.free(self.pcm_i16);
    }
};

fn decodeAll(allocator: std.mem.Allocator, bytes: []const u8) !Decoded {
    var captured = std.ArrayList(f32).empty;
    errdefer captured.deinit(allocator);
    var interleaved = std.ArrayList(i16).empty;
    errdefer interleaved.deinit(allocator);

    var reader = std.Io.Reader.fixed(bytes);
    var dec = try opus.Decoder.open(allocator, &reader, "");
    defer dec.deinit();
    dec.capture = &captured;
    dec.capture_gpa = allocator;

    var buffer: [4096]i16 = undefined;
    while (true) {
        const written = try dec.read(&buffer);
        if (written == 0) break;
        try interleaved.appendSlice(allocator, buffer[0..written]);
    }
    return .{
        .pcm_f32 = try captured.toOwnedSlice(allocator),
        .pcm_i16 = try interleaved.toOwnedSlice(allocator),
    };
}

/// SNR between two raw f32le buffers, used to compare two reference decoders
/// with each other. `compareF32` cannot do this because it wants a typed slice
/// for one side, and the buffers ffmpeg hands back are alignment 1.
fn compareRaw(ours_bytes: []const u8, ref_bytes: []const u8) !Stats {
    const a = std.mem.bytesAsSlice(f32, ours_bytes);
    const b = std.mem.bytesAsSlice(f32, ref_bytes);
    if (a.len != b.len) return error.SampleCountMismatch;
    var signal: f64 = 0;
    var noise: f64 = 0;
    var max_diff: f64 = 0;
    for (a, b) |x, y| {
        const s: f64 = @floatCast(y);
        const d: f64 = @as(f64, @floatCast(x)) - s;
        signal += s * s;
        noise += d * d;
        max_diff = @max(max_diff, @abs(d));
    }
    return .{
        .snr_db = 10.0 * std.math.log10(signal / @max(noise, 1e-300)),
        .max_diff = max_diff,
        .samples = a.len,
    };
}
const Stats = struct { snr_db: f64, max_diff: f64, samples: usize };

fn compareF32(ours: []const f32, reference: []const u8) !Stats {
    const ref = std.mem.bytesAsSlice(f32, reference);
    if (ref.len != ours.len) return error.SampleCountMismatch;
    var signal: f64 = 0;
    var noise: f64 = 0;
    var max_diff: f64 = 0;
    for (ours, ref) |a, b| {
        const s: f64 = @floatCast(b);
        const d: f64 = @as(f64, @floatCast(a)) - s;
        signal += s * s;
        noise += d * d;
        max_diff = @max(max_diff, @abs(d));
    }
    const snr = 10.0 * std.math.log10(signal / @max(noise, 1e-300));
    return .{ .snr_db = snr, .max_diff = max_diff, .samples = ours.len };
}

fn compareI16(ours: []const i16, reference: []const u8) !Stats {
    const ref = std.mem.bytesAsSlice(i16, reference);
    if (ref.len != ours.len) return error.SampleCountMismatch;
    var signal: f64 = 0;
    var noise: f64 = 0;
    var max_diff: f64 = 0;
    for (ours, ref) |a, b| {
        const s: f64 = @floatFromInt(b);
        const d = @as(f64, @floatFromInt(a)) - s;
        signal += s * s;
        noise += d * d;
        max_diff = @max(max_diff, @abs(d));
    }
    const snr = 10.0 * std.math.log10(signal / @max(noise, 1e-300));
    return .{ .snr_db = snr, .max_diff = max_diff, .samples = ours.len };
}

/// Run ffmpeg's *libopus* decoder instead of its native one. The two reference
/// decoders disagree with each other on CELT streams, so this is what tells
/// "our decoder is wrong" apart from "the two references disagree".
fn runLibopus(allocator: std.mem.Allocator, bytes: []const u8, sample_format: []const u8) ![]u8 {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "input.bin", .data = bytes });

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &path_buffer);
    const input_path = try std.fmt.allocPrint(
        allocator,
        "{s}{s}input.bin",
        .{ path_buffer[0..dir_len], std.fs.path.sep_str },
    );
    defer allocator.free(input_path);

    const result = std.process.run(allocator, std.testing.io, .{
        .argv = &.{
            compare.ffmpeg_path, "-v",      "error",
            "-c:a",              "libopus", "-i",
            input_path,          "-f",      sample_format,
            "pipe:1",
        },
        .stdout_limit = .limited(64 << 20),
        .stderr_limit = .limited(1 << 20),
    }) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer allocator.free(result.stderr);
    if (!result.term.success()) {
        allocator.free(result.stdout);
        return error.FfmpegFailed;
    }
    return result.stdout;
}
test "celta vectors: f32 and s16 match ffmpeg, sample counts identical" {
    var ran: usize = 0;
    for (vectors) |vector| {
        const bytes = readVector(testing.allocator, vector.name) catch |err| switch (err) {
            error.SkipZigTest => {
                std.debug.print("opus vector missing: {s}\\{s}\n", .{ vector_dir, vector.name });
                continue;
            },
            else => return err,
        };
        defer testing.allocator.free(bytes);

        const decoded = try decodeAll(testing.allocator, bytes);
        defer decoded.deinit(testing.allocator);

        // Sample count first: everything else is meaningless if the streams are
        // not aligned. `granule - pre_skip` is the length, with the pre-skip
        // dropped from the front.
        try testing.expectEqual(vector.frames * vector.channels, decoded.pcm_f32.len);
        try testing.expectEqual(vector.frames * vector.channels, decoded.pcm_i16.len);

        const ref_f32_raw = try compare.runFfmpeg(testing.allocator, bytes, "f32le");
        defer testing.allocator.free(ref_f32_raw);
        const quality_f32 = try compareF32(decoded.pcm_f32, ref_f32_raw);

        const ref_s16_raw = try compare.runFfmpeg(testing.allocator, bytes, "s16le");
        defer testing.allocator.free(ref_s16_raw);
        const quality_s16 = try compareI16(decoded.pcm_i16, ref_s16_raw);

        std.debug.print(
            "celta {s}: {d} ch, {d} frames | f32 SNR {d:.2} dB max {e:.3} | s16 SNR {d:.2} dB max {d:.0} LSB\n",
            .{ vector.name, vector.channels, vector.frames, quality_f32.snr_db, quality_f32.max_diff, quality_s16.snr_db, quality_s16.max_diff },
        );

        try testing.expect(quality_f32.snr_db >= 90.0);
        try testing.expect(quality_f32.max_diff < 1e-4);
        try testing.expect(quality_s16.snr_db >= 70.0);
        try testing.expect(quality_s16.max_diff <= 8.0);
        ran += 1;
    }
    if (ran == 0) return error.SkipZigTest;
}

test "celta vectors: closer to ffmpeg than the reference decoder itself is" {
    // The two reference decoders do not agree with each other on these files:
    // the libopus build linked into this ffmpeg uses a polynomial `exp2`
    // approximation (its FLOAT_APPROX build) where ffmpeg's native CELT
    // decoder uses `exp2f`, and that alone costs about 77 dB on every band.
    // So the meaningful statement is not "we match libopus" but "we are closer
    // to the comparison target than libopus is". This test measures both
    // distances and asserts exactly that, on every file.
    var ran: usize = 0;
    for (vectors) |vector| {
        const bytes = readVector(testing.allocator, vector.name) catch |err| switch (err) {
            error.SkipZigTest => continue,
            else => return err,
        };
        defer testing.allocator.free(bytes);

        const decoded = try decodeAll(testing.allocator, bytes);
        defer decoded.deinit(testing.allocator);

        const native_raw = try compare.runFfmpeg(testing.allocator, bytes, "f32le");
        defer testing.allocator.free(native_raw);
        const ours = try compareF32(decoded.pcm_f32, native_raw);

        const libopus_raw = try runLibopus(testing.allocator, bytes, "f32le");
        defer testing.allocator.free(libopus_raw);
        const reference = try compareRaw(libopus_raw, native_raw);

        std.debug.print(
            "celta {s}: ours vs ffmpeg {d:.2} dB, libopus vs ffmpeg {d:.2} dB\n",
            .{ vector.name, ours.snr_db, reference.snr_db },
        );
        try testing.expect(ours.snr_db > reference.snr_db);
        ran += 1;
    }
    if (ran == 0) return error.SkipZigTest;
}
test "celta vectors: info reports the stream length after the last page" {
    const bytes = readVector(testing.allocator, vectors[0].name) catch |err| switch (err) {
        error.SkipZigTest => return error.SkipZigTest,
        else => return err,
    };
    defer testing.allocator.free(bytes);

    var reader = std.Io.Reader.fixed(bytes);
    var dec = try root.open(testing.allocator, &reader);
    defer dec.deinit();
    try testing.expectEqual(root.Format.ogg_opus, dec.info.format);
    try testing.expectEqual(@as(u32, 48_000), dec.info.sample_rate);
    try testing.expectEqual(@as(u16, 2), dec.info.channels);
    // The length lives in the last page's granule, so it is unknown up front.
    try testing.expectEqual(@as(?u64, null), dec.info.total_frames);

    var buffer: [4096]i16 = undefined;
    var total: usize = 0;
    while (true) {
        const written = try dec.read(&buffer);
        if (written == 0) break;
        total += written;
    }
    try testing.expectEqual(@as(usize, 96_000 * 2), total);
    try testing.expectEqual(@as(?u64, 96_000), dec.info.total_frames);
}

test "celta vectors: a hybrid packet is refused, not approximated" {
    // The VOIP vector mixes SILK-only, Hybrid and CELT packets and *starts* with
    // Hybrid: the decoder must say so instead of emitting only part of the
    // frame. (SILK itself decodes now; see opus_silk_vectors_test.zig.)
    const name = "opus-48k-24-voip.opus";
    const bytes = readVector(testing.allocator, name) catch |err| switch (err) {
        error.SkipZigTest => return error.SkipZigTest,
        else => return err,
    };
    defer testing.allocator.free(bytes);

    var reader = std.Io.Reader.fixed(bytes);
    var dec = try opus.Decoder.open(testing.allocator, &reader, "");
    defer dec.deinit();
    var buffer: [64]i16 = undefined;
    try testing.expectError(error.Unsupported, dec.read(&buffer));
}
