//! Integration tests against a real ffmpeg binary, when one is available.
//!
//! ffmpeg writes WAV to a pipe with `data` size 0xFFFFFFFF, so these tests also
//! cover the "unknown length, decode until EOF" path on real encoder output.
//! The FLAC cases are encoded with `-lpc_type none` and compared sample for
//! sample with ffmpeg's decoder; `-ch_mode` selects independent or one of the
//! three decorrelated channel assignments. On non-Windows runners (or when the
//! binary is absent) every test skips; CI does not depend on ffmpeg.

const std = @import("std");
const builtin = @import("builtin");
const root = @import("root.zig");
const compare = @import("compare.zig");
const testing = std.testing;

const ffmpeg_path = "C:\\Users\\30680\\.zcode\\workspace\\default\\music-to-midi\\tools\\ffmpeg\\bin\\ffmpeg.exe";

fn generate(
    allocator: std.mem.Allocator,
    codec: []const u8,
    channels_arg: []const u8,
    duration: []const u8,
) ![]u8 {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const filter = try std.fmt.allocPrint(
        allocator,
        "sine=frequency=440:duration={s}",
        .{duration},
    );
    defer allocator.free(filter);

    const result = std.process.run(allocator, std.testing.io, .{
        .argv = &.{
            ffmpeg_path, "-v",    "error",
            "-f",        "lavfi", "-i",
            filter,      "-ac",   channels_arg,
            "-ar",       "44100", "-c:a",
            codec,       "-f",    "wav",
            "pipe:1",
        },
        .stdout_limit = .limited(64 << 20),
        .stderr_limit = .limited(1 << 20),
    }) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (!result.term.success()) {
        std.debug.print("ffmpeg failed for {s}: {s}\n", .{ codec, result.stderr });
        return error.FfmpegFailed;
    }
    return allocator.dupe(u8, result.stdout);
}

fn expectGenerated(
    bytes: []const u8,
    expected_channels: u16,
    expected_bits: u16,
    expected_frames: u64,
) !void {
    try testing.expectEqual(root.Format.wav, root.probe(bytes).?);

    var reader = std.Io.Reader.fixed(bytes);
    var dec = try root.open(testing.allocator, &reader);
    defer dec.deinit();

    try testing.expectEqual(expected_channels, dec.info.channels);
    try testing.expectEqual(expected_bits, dec.info.bits_per_sample);
    try testing.expectEqual(@as(u32, 44_100), dec.info.sample_rate);
    // ffmpeg's pipe output has data size 0xFFFFFFFF.
    try testing.expectEqual(@as(?u64, null), dec.info.total_frames);

    var out: [4096]i16 = undefined;
    var frames: u64 = 0;
    var saw_signal = false;
    const channels: usize = expected_channels;
    while (true) {
        const n = try dec.read(&out);
        if (n == 0) break;
        try testing.expectEqual(@as(usize, 0), n % channels);
        frames += n / channels;
        for (out[0..n]) |sample| {
            if (sample != 0) saw_signal = true;
        }
    }

    try testing.expectEqual(expected_frames, frames);
    try testing.expect(saw_signal);
}

test "ffmpeg: PCM16 stereo" {
    const bytes = try generate(testing.allocator, "pcm_s16le", "2", "0.1");
    defer testing.allocator.free(bytes);
    try expectGenerated(bytes, 2, 16, 4410);
}

test "ffmpeg: unsigned PCM8 mono" {
    const bytes = try generate(testing.allocator, "pcm_u8", "1", "0.1");
    defer testing.allocator.free(bytes);
    try expectGenerated(bytes, 1, 8, 4410);
}

test "ffmpeg: PCM24 stereo" {
    const bytes = try generate(testing.allocator, "pcm_s24le", "2", "0.1");
    defer testing.allocator.free(bytes);
    try expectGenerated(bytes, 2, 24, 4410);
}

test "ffmpeg: PCM32 stereo" {
    const bytes = try generate(testing.allocator, "pcm_s32le", "2", "0.1");
    defer testing.allocator.free(bytes);
    try expectGenerated(bytes, 2, 32, 4410);
}

test "ffmpeg: float32 stereo" {
    const bytes = try generate(testing.allocator, "pcm_f32le", "2", "0.1");
    defer testing.allocator.free(bytes);
    try expectGenerated(bytes, 2, 32, 4410);
}

test "ffmpeg: 5.1 PCM24 through WAVE_FORMAT_EXTENSIBLE" {
    const bytes = try generate(testing.allocator, "pcm_s24le", "6", "0.1");
    defer testing.allocator.free(bytes);
    try expectGenerated(bytes, 6, 24, 4410);
}

/// Encode FLAC with ffmpeg. `lpc_type` is ffmpeg's LPC stage (`none`, `fixed`,
/// `levinson`, `cholesky`); `ch_mode` is its channel-assignment switch
/// (`indep`, `left_side`, `right_side`, `mid_side`). The source is two
/// different tones so a side channel is never all zeros: a zero side plane
/// would make every reconstruction formula pass.
const FlacOptions = struct {
    channels_arg: []const u8 = "2",
    duration: []const u8 = "0.2",
    bits: u16 = 16,
    ch_mode: []const u8 = "indep",
    lpc_type: []const u8 = "none",
    /// ffmpeg spells libFLAC's `-lpc_order` as the min/max prediction order
    /// pair; setting both pins the order instead of letting it search.
    lpc_order: ?u8 = null,
    coeff_precision: ?u8 = null,
};

fn generateFlac(allocator: std.mem.Allocator, options: FlacOptions) ![]u8 {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const filter = try std.fmt.allocPrint(
        allocator,
        "aevalsrc=0.4*sin(2*PI*440*t)|0.4*sin(2*PI*660*t):s=44100:d={s}",
        .{options.duration},
    );
    defer allocator.free(filter);

    var order_buf: [4]u8 = undefined;
    var precision_buf: [4]u8 = undefined;

    var argv: [40][]const u8 = undefined;
    var len: usize = 0;
    const fixed_args = [_][]const u8{
        ffmpeg_path, "-v",            "error",                "-f",                 "lavfi",
        "-i",        filter,          "-ac",                  options.channels_arg, "-ar",
        "44100",     "-c:a",          "flac",                 "-lpc_type",          options.lpc_type,
        "-ch_mode",  options.ch_mode, "-max_partition_order", "4",
    };
    for (fixed_args) |arg| {
        argv[len] = arg;
        len += 1;
    }
    if (options.lpc_order) |order| {
        const text = try std.fmt.bufPrint(&order_buf, "{d}", .{order});
        for ([_][]const u8{
            "-min_prediction_order", text,
            "-max_prediction_order", text,
        }) |arg| {
            argv[len] = arg;
            len += 1;
        }
    }
    if (options.coeff_precision) |precision| {
        const text = try std.fmt.bufPrint(&precision_buf, "{d}", .{precision});
        for ([_][]const u8{ "-lpc_coeff_precision", text }) |arg| {
            argv[len] = arg;
            len += 1;
        }
    }
    if (options.bits == 16) {
        for ([_][]const u8{ "-sample_fmt", "s16" }) |arg| {
            argv[len] = arg;
            len += 1;
        }
    }
    if (options.bits == 24) {
        for ([_][]const u8{ "-sample_fmt", "s32", "-bits_per_raw_sample", "24" }) |arg| {
            argv[len] = arg;
            len += 1;
        }
    }
    for ([_][]const u8{ "-f", "flac", "pipe:1" }) |arg| {
        argv[len] = arg;
        len += 1;
    }

    const result = std.process.run(allocator, std.testing.io, .{
        .argv = argv[0..len],
        .stdout_limit = .limited(64 << 20),
        .stderr_limit = .limited(1 << 20),
    }) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer allocator.free(result.stderr);
    if (!result.term.success()) {
        std.debug.print("ffmpeg flac failed: {s}\n", .{result.stderr});
        allocator.free(result.stdout);
        return error.FfmpegFailed;
    }
    return result.stdout;
}

test "ffmpeg: FLAC fixed-predictor 16-bit stereo matches sample for sample" {
    const bytes = try generateFlac(testing.allocator, .{
        .channels_arg = "2",
        .duration = "0.2",
        .bits = 16,
        .ch_mode = "indep",
    });
    defer testing.allocator.free(bytes);

    var reader = std.Io.Reader.fixed(bytes);
    var dec = try root.open(testing.allocator, &reader);
    defer dec.deinit();
    try testing.expectEqual(@as(u16, 2), dec.info.channels);
    try testing.expectEqual(@as(u16, 16), dec.info.bits_per_sample);
    // ffmpeg writes to a pipe, so it cannot know the total sample count.
    try testing.expectEqual(@as(?u64, null), dec.info.total_frames);

    try compare.expectExact(testing.allocator, bytes);
}

test "ffmpeg: FLAC fixed-predictor 24-bit stereo matches s32 >> 16" {
    const bytes = try generateFlac(testing.allocator, .{
        .channels_arg = "2",
        .duration = "0.2",
        .bits = 24,
        .ch_mode = "indep",
    });
    defer testing.allocator.free(bytes);

    var reader = std.Io.Reader.fixed(bytes);
    var dec = try root.open(testing.allocator, &reader);
    defer dec.deinit();
    try testing.expectEqual(@as(u16, 24), dec.info.bits_per_sample);

    try compare.expectExactS32(testing.allocator, bytes);
}

test "ffmpeg: FLAC fixed-predictor 5.1 matches sample for sample" {
    const bytes = try generateFlac(testing.allocator, .{
        .channels_arg = "6",
        .duration = "0.1",
        .bits = 16,
        .ch_mode = "indep",
    });
    defer testing.allocator.free(bytes);

    var reader = std.Io.Reader.fixed(bytes);
    var dec = try root.open(testing.allocator, &reader);
    defer dec.deinit();
    try testing.expectEqual(@as(u16, 6), dec.info.channels);

    try compare.expectExact(testing.allocator, bytes);
}

test "ffmpeg: FLAC left/side, right/side and mid/side match sample for sample" {
    const Case = struct { ch_mode: []const u8, bits: u16 };
    const cases = [_]Case{
        .{ .ch_mode = "left_side", .bits = 16 },
        .{ .ch_mode = "right_side", .bits = 16 },
        .{ .ch_mode = "mid_side", .bits = 16 },
        // A 24-bit source makes the side subframe 25 bits wide.
        .{ .ch_mode = "mid_side", .bits = 24 },
    };

    for (cases) |case| {
        const bytes = try generateFlac(testing.allocator, .{
            .channels_arg = "2",
            .duration = "0.2",
            .bits = case.bits,
            .ch_mode = case.ch_mode,
        });
        defer testing.allocator.free(bytes);

        var reader = std.Io.Reader.fixed(bytes);
        var dec = try root.open(testing.allocator, &reader);
        defer dec.deinit();
        try testing.expectEqual(@as(u16, 2), dec.info.channels);
        try testing.expectEqual(case.bits, dec.info.bits_per_sample);

        if (case.bits > 16) {
            const result = try compare.compareWithFfmpegS32(testing.allocator, bytes);
            std.debug.print(
                "ffmpeg FLAC {s} {d}-bit: {d} samples, max_diff {d}\n",
                .{ case.ch_mode, case.bits, result.samples, result.max_diff },
            );
            try testing.expectEqual(@as(u16, 0), result.max_diff);
        } else {
            const result = try compare.compareWithFfmpeg(testing.allocator, bytes);
            std.debug.print(
                "ffmpeg FLAC {s} {d}-bit: {d} samples, max_diff {d}\n",
                .{ case.ch_mode, case.bits, result.samples, result.max_diff },
            );
            try testing.expectEqual(@as(u16, 0), result.max_diff);
        }
    }
}

test "ffmpeg: LPC levinson/cholesky, orders 1/8/32 match sample for sample" {
    const Case = struct {
        lpc_type: []const u8,
        order: u8,
        bits: u16,
        ch_mode: []const u8,
        coeff_precision: ?u8 = null,
    };
    const cases = [_]Case{
        .{ .lpc_type = "levinson", .order = 1, .bits = 16, .ch_mode = "indep" },
        // LPC on the side subframe: the predictor sees the one-bit-wider plane.
        .{ .lpc_type = "levinson", .order = 8, .bits = 16, .ch_mode = "left_side" },
        .{ .lpc_type = "levinson", .order = 32, .bits = 16, .ch_mode = "mid_side" },
        .{ .lpc_type = "cholesky", .order = 1, .bits = 16, .ch_mode = "right_side" },
        .{ .lpc_type = "cholesky", .order = 8, .bits = 16, .ch_mode = "mid_side" },
        // A 24-bit source makes the side subframe 25 bits wide, which also
        // forces the wide accumulator.
        .{ .lpc_type = "cholesky", .order = 32, .bits = 24, .ch_mode = "right_side" },
        // Force the smallest precision ffmpeg accepts instead of its automatic
        // choice, so a low-precision coefficient set is exercised live too.
        .{ .lpc_type = "levinson", .order = 1, .bits = 16, .ch_mode = "indep", .coeff_precision = 2 },
    };

    for (cases) |case| {
        const bytes = try generateFlac(testing.allocator, .{
            .channels_arg = "2",
            .duration = "0.2",
            .bits = case.bits,
            .ch_mode = case.ch_mode,
            .lpc_type = case.lpc_type,
            .lpc_order = case.order,
            .coeff_precision = case.coeff_precision,
        });
        defer testing.allocator.free(bytes);

        var reader = std.Io.Reader.fixed(bytes);
        var dec = try root.open(testing.allocator, &reader);
        defer dec.deinit();
        try testing.expectEqual(@as(u16, 2), dec.info.channels);
        try testing.expectEqual(case.bits, dec.info.bits_per_sample);

        const result = if (case.bits > 16)
            try compare.compareWithFfmpegS32(testing.allocator, bytes)
        else
            try compare.compareWithFfmpeg(testing.allocator, bytes);
        std.debug.print(
            "ffmpeg FLAC lpc {s} order {d}, {d}-bit {s}, precision {?d}: {d} samples, max_diff {d}\n",
            .{
                case.lpc_type,
                case.order,
                case.bits,
                case.ch_mode,
                case.coeff_precision,
                result.samples,
                result.max_diff,
            },
        );
        try testing.expectEqual(@as(u16, 0), result.max_diff);
    }
}
