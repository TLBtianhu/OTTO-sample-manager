//! Joint stereo end to end, on frames this file builds bit by bit (see
//! `mp3_build.zig`).
//!
//! None of the corpus vectors uses intensity stereo -- LAME, which produced all
//! of them, does not implement it -- so the only way to exercise that path and
//! its `is_pos == 7` special value is a stream ffmpeg also decodes, compared
//! sample for sample. The synthetic frames are long blocks with `big_values` 0,
//! so the whole spectrum is count1 quadruples: a line is +1, -1 or 0, which
//! keeps the band layout easy to verify.

const std = @import("std");
const mp3 = @import("mp3.zig");
const build = @import("mp3_build.zig");
const compare = @import("compare.zig");
const testing = std.testing;

const Analysis = struct {
    snr: f64,
    max: f64,
    left_energy: f64,
    right_energy: f64,
};

fn analyse(ours: []const f32, ref: []const f32) Analysis {
    var sig: f64 = 0;
    var err: f64 = 0;
    var max: f64 = 0;
    var left: f64 = 0;
    var right: f64 = 0;
    for (0..@min(ours.len, ref.len)) |i| {
        const d: f64 = @as(f64, ours[i]) - @as(f64, ref[i]);
        sig += @as(f64, ref[i]) * @as(f64, ref[i]);
        err += d * d;
        max = @max(max, @abs(d));
        if (i % 2 == 0) left += @as(f64, ref[i]) * @as(f64, ref[i]) else right += @as(f64, ref[i]) * @as(f64, ref[i]);
    }
    return .{
        .snr = 10.0 * @log10(sig / @max(err, 1e-30)),
        .max = max,
        .left_energy = left,
        .right_energy = right,
    };
}

fn ffmpegF32(allocator: std.mem.Allocator, bytes: []const u8) ![]f32 {
    const raw = try compare.runFfmpeg(allocator, bytes, "f32le");
    defer allocator.free(raw);
    const ref = try allocator.alloc(f32, raw.len / 4);
    for (ref, 0..) |*s, i| s.* = @bitCast(std.mem.readInt(u32, raw[i * 4 ..][0..4], .little));
    return ref;
}

fn peak(samples: []const f32) f32 {
    var p: f32 = 0;
    for (samples) |v| p = @max(p, @abs(v));
    return p;
}

test "intensity stereo: is_pos 0 puts the whole band in the right channel" {
    const allocator = testing.allocator;
    var is_pos: [21]u8 = @splat(3);
    is_pos[20] = 0; // full right; the top band reuses this position

    const bytes = try build.buildFrame(
        allocator,
        1, // joint stereo, intensity only
        .{ .sf = @splat(0), .energy_quad = build.bandQuad(20) },
        .{ .sf = is_pos },
    );
    defer allocator.free(bytes);

    const ours = try mp3.decodeToF32(allocator, bytes);
    defer allocator.free(ours);
    const ref = try ffmpegF32(allocator, bytes);
    defer allocator.free(ref);
    try testing.expectEqual(ours.len, ref.len);

    const a = analyse(ours, ref);
    std.debug.print("\nintensity is_pos=0: SNR {d:.2} dB max {e}\n", .{ a.snr, a.max });
    std.debug.print("  ref L {e} R {e}\n", .{ a.left_energy, a.right_energy });
    try testing.expect(a.snr >= 90.0);
    try testing.expect(a.max < 1e-4);
    // kl = 0 for the band that carries the energy, so the reference is silent
    // on the left and holds everything on the right.
    try testing.expect(a.left_energy < 1e-6);
    try testing.expect(a.right_energy > 1e-3);
}

test "intensity stereo: is_pos 7 mutes the band instead of panning it" {
    const allocator = testing.allocator;
    var is_pos: [21]u8 = @splat(3);
    is_pos[20] = 7;

    const bytes = try build.buildFrame(
        allocator,
        1,
        .{ .sf = @splat(0), .energy_quad = build.bandQuad(20) },
        .{ .sf = is_pos },
    );
    defer allocator.free(bytes);

    const ours = try mp3.decodeToF32(allocator, bytes);
    defer allocator.free(ours);
    std.debug.print("\nintensity is_pos=7: peak {e} n {d}\n", .{ peak(ours), ours.len });
    try testing.expectEqual(@as(usize, 3 * 2 * 1152), ours.len);
    try testing.expectEqual(@as(f32, 0), peak(ours));

    // ffmpeg does not implement "7 mutes the band": it treats 7 as "not a
    // position", ends the intensity region there and leaves the band in the
    // left channel. Record the difference rather than assert on it -- this is
    // the one place the decoder deliberately follows the specification instead.
    const ref = ffmpegF32(allocator, bytes) catch |err| switch (err) {
        error.SkipZigTest => return error.SkipZigTest,
        else => return err,
    };
    defer allocator.free(ref);
    std.debug.print("is_pos=7 ffmpeg peak {e}\n", .{peak(ref)});
}

test "intensity plus mid/side: the bands below the region use the MS coefficients" {
    const allocator = testing.allocator;
    const is_pos: [21]u8 = @splat(3); // centred in the intensity region

    const bytes = try build.buildFrame(
        allocator,
        3, // joint stereo, intensity + mid/side
        // Left energy in band 20 (intensity region) and band 0 (mid/side).
        .{ .sf = @splat(0), .energy_quad = build.bandQuad(20) },
        // The right channel's only energy is in band 0, which ends the region.
        .{ .sf = is_pos, .energy_quad = 0 },
    );
    defer allocator.free(bytes);

    const ours = try mp3.decodeToF32(allocator, bytes);
    defer allocator.free(ours);
    const ref = try ffmpegF32(allocator, bytes);
    defer allocator.free(ref);
    try testing.expectEqual(ours.len, ref.len);

    const a = analyse(ours, ref);
    std.debug.print("\nintensity+MS: SNR {d:.2} dB max {e}\n", .{ a.snr, a.max });
    std.debug.print("  ref L {e} R {e}\n", .{ a.left_energy, a.right_energy });
    try testing.expect(a.snr >= 90.0);
    try testing.expect(a.max < 1e-4);
}

test "mode_extension is read per frame, not cached from the first one" {
    const allocator = testing.allocator;
    // Both channels carry energy in band 0, so a mid/side frame decodes
    // differently from a plain left/right frame. Alternating the two is what a
    // real encoder does (LAME switches MS on and off frame by frame), and a
    // decoder that cached the first frame's flags would decode half of these
    // samples with the wrong matrix.
    const exts = [6]u2{ 0, 2, 0, 2, 2, 0 };

    const bytes = try build.buildFramesExts(
        allocator,
        &exts,
        .{ .sf = @splat(0), .energy_quad = 0 },
        .{ .sf = @splat(0), .energy_quad = 0 },
    );
    defer allocator.free(bytes);

    const ours = try mp3.decodeToF32(allocator, bytes);
    defer allocator.free(ours);
    const ref = try ffmpegF32(allocator, bytes);
    defer allocator.free(ref);
    try testing.expectEqual(ours.len, ref.len);

    const a = analyse(ours, ref);
    std.debug.print("\nalt mode_ext: SNR {d:.2} dB max {e}\n", .{ a.snr, a.max });
    try testing.expect(a.snr >= 90.0);
    try testing.expect(a.max < 1e-4);
}
