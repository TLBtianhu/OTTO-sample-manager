//! Test helper: compare this decoder's i16 output against ffmpeg's raw PCM,
//! sample by sample.
//!
//! Two comparison modes:
//!   * `expectExact` — full file, ffmpeg `-f s16le` (integer sources <= 16 bit,
//!     and WAV's own conversion rules);
//!   * `expectExactS32` — full file, ffmpeg `-f s32le`, reference shifted right
//!     by 16. This is the rule for FLAC sources wider than 16 bits.
//!
//! `decodePrefix` returns the samples delivered before a frame error, which the
//! truncation and corrupt-stream tests use.
//!
//! For float WAV input a tolerance of 1 LSB may be used, because the source is
//! not integer PCM and ffmpeg's float->s16 rounding is not part of the format.

const std = @import("std");
const root = @import("root.zig");
const testutil = @import("testutil.zig");
const ffmpeg = @import("ffmpeg.zig");

pub const Result = struct {
    samples: usize,
    max_diff: u16,
    first_mismatch: ?usize = null,
    first_ours: i16 = 0,
    first_ref: i16 = 0,
};

pub const Prefix = struct {
    samples: []i16,
    err: ?root.Error,
};

/// Decode as much as the stream allows, keeping the samples delivered before
/// the first error. `err` is null when the stream ended cleanly.
pub fn decodePrefix(allocator: std.mem.Allocator, bytes: []const u8) !Prefix {
    var reader = std.Io.Reader.fixed(bytes);
    var dec = root.open(allocator, &reader) catch |err| {
        return .{ .samples = try allocator.alloc(i16, 0), .err = err };
    };
    defer dec.deinit();

    const channels: usize = dec.info.channels;
    var list: std.ArrayList(i16) = .empty;
    errdefer list.deinit(allocator);

    var buffer: [4096]i16 = undefined;
    while (true) {
        const n = dec.read(&buffer) catch |err| {
            return .{ .samples = try list.toOwnedSlice(allocator), .err = err };
        };
        if (n == 0) break;
        try list.appendSlice(allocator, buffer[0..n]);
        if (n % channels != 0) return error.UnalignedRead;
    }
    return .{ .samples = try list.toOwnedSlice(allocator), .err = null };
}

/// Run ffmpeg over `bytes` and return its raw little-endian output for
/// `sample_format` ("s16le", "s32le" or "f32le").
pub fn runFfmpeg(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    sample_format: []const u8,
) ![]u8 {
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

    const result = try ffmpeg.run(allocator, &.{
        "-v",     "error",
        "-i",     input_path,
        "-f",     sample_format,
        "pipe:1",
    }, .limited(64 << 20));
    defer allocator.free(result.stderr);

    if (!result.term.success()) {
        std.debug.print("ffmpeg reference decode failed: {s}\n", .{result.stderr});
        allocator.free(result.stdout);
        return error.FfmpegFailed;
    }
    return result.stdout;
}

fn diff(ours: []const i16, reference: []const i16) Result {
    var max_diff: u16 = 0;
    var first_mismatch: ?usize = null;
    var first_ours: i16 = 0;
    var first_ref: i16 = 0;
    for (ours, 0..) |ours_sample, i| {
        const ref_sample = reference[i];
        const delta: i32 = @as(i32, ours_sample) - @as(i32, ref_sample);
        const abs_diff: u16 = @intCast(if (delta < 0) -delta else delta);
        if (abs_diff != 0 and first_mismatch == null) {
            first_mismatch = i;
            first_ours = ours_sample;
            first_ref = ref_sample;
        }
        if (abs_diff > max_diff) max_diff = abs_diff;
    }
    return .{
        .samples = ours.len,
        .max_diff = max_diff,
        .first_mismatch = first_mismatch,
        .first_ours = first_ours,
        .first_ref = first_ref,
    };
}

fn report(result: Result, tolerance: u16) !void {
    if (result.max_diff <= tolerance) return;
    std.debug.print(
        "PCM mismatch: {d} samples, max diff {d} > tolerance {d}, first at {d}: ours {d}, ffmpeg {d}\n",
        .{
            result.samples,
            result.max_diff,
            tolerance,
            result.first_mismatch.?,
            result.first_ours,
            result.first_ref,
        },
    );
    return error.PcmMismatch;
}

/// Decode `bytes` with zig-audio and with ffmpeg `-f s16le`, and return the
/// largest absolute difference between corresponding samples.
pub fn compareWithFfmpeg(allocator: std.mem.Allocator, bytes: []const u8) !Result {
    const ours = try testutil.decodeAll(allocator, bytes, 512);
    defer allocator.free(ours);

    const raw = try runFfmpeg(allocator, bytes, "s16le");
    defer allocator.free(raw);
    if (raw.len % 2 != 0) return error.OddReferenceLength;

    const reference = try allocator.alloc(i16, raw.len / 2);
    defer allocator.free(reference);
    for (reference, 0..) |*slot, i| {
        slot.* = std.mem.readInt(i16, raw[i * 2 ..][0..2], .little);
    }

    if (reference.len != ours.len) {
        std.debug.print(
            "sample count mismatch: zig-audio {d}, ffmpeg {d}\n",
            .{ ours.len, reference.len },
        );
        return error.SampleCountMismatch;
    }
    return diff(ours, reference);
}

/// Like `compareWithFfmpeg`, but the reference is `-f s32le` shifted right by
/// 16: the documented conversion for FLAC sources wider than 16 bits.
pub fn compareWithFfmpegS32(allocator: std.mem.Allocator, bytes: []const u8) !Result {
    const ours = try testutil.decodeAll(allocator, bytes, 512);
    defer allocator.free(ours);

    const raw = try runFfmpeg(allocator, bytes, "s32le");
    defer allocator.free(raw);
    if (raw.len % 4 != 0) return error.OddReferenceLength;

    const reference = try allocator.alloc(i16, raw.len / 4);
    defer allocator.free(reference);
    for (reference, 0..) |*slot, i| {
        const wide = std.mem.readInt(i32, raw[i * 4 ..][0..4], .little);
        slot.* = @intCast(wide >> 16);
    }

    if (reference.len != ours.len) {
        std.debug.print(
            "sample count mismatch: zig-audio {d}, ffmpeg(s32) {d}\n",
            .{ ours.len, reference.len },
        );
        return error.SampleCountMismatch;
    }
    return diff(ours, reference);
}

/// Require bit-exact agreement with ffmpeg's s16 output. Prints the first
/// failing sample and both values.
pub fn expectExact(allocator: std.mem.Allocator, bytes: []const u8) !void {
    try report(try compareWithFfmpeg(allocator, bytes), 0);
}

/// Require bit-exact agreement after the s32 reference is shifted right by 16.
pub fn expectExactS32(allocator: std.mem.Allocator, bytes: []const u8) !void {
    try report(try compareWithFfmpegS32(allocator, bytes), 0);
}

/// Require agreement within `tolerance` LSBs (use 0 for integer PCM).
pub fn expectWithin(allocator: std.mem.Allocator, bytes: []const u8, tolerance: u16) !void {
    try report(try compareWithFfmpeg(allocator, bytes), tolerance);
}
