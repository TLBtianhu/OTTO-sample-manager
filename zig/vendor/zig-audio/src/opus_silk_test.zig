//! SILK unit tests: the parts that can be checked without a reference decoder.
//!
//! Conformance lives in `opus_silk_vectors_test.zig`; what is here is the
//! contract this layer has to keep on its own — that it refuses impossible
//! parameters by name rather than by crashing, that it survives payloads that
//! are not SILK at all, and that its state can be dropped and rebuilt.

const std = @import("std");
const silk = @import("opus_silk.zig");
const opus = @import("opus.zig");
const range = @import("opus_range.zig");

test "impossible superframe parameters are refused, not decoded" {
    var dec = silk.Decoder.init(1);
    var out = [_][silk.max_frame]f32{ @splat(0.0), @splat(0.0) };
    const bytes: [64]u8 = @splat(0);
    var rc = range.Decoder.init(&bytes);
    // 0 channels, more than 2 channels, and a duration longer than the format
    // allows are all structural, not bitstream errors.
    try std.testing.expectError(error.Corrupt, dec.decodeSuperframe(&rc, .{ &out[0], &out[1] }, .wide, 0, 20));
    var rc2 = range.Decoder.init(&bytes);
    try std.testing.expectError(error.Corrupt, dec.decodeSuperframe(&rc2, .{ &out[0], &out[1] }, .wide, 3, 20));
    var rc3 = range.Decoder.init(&bytes);
    try std.testing.expectError(error.Corrupt, dec.decodeSuperframe(&rc3, .{ &out[0], &out[1] }, .wide, 1, 120));
    // A buffer that cannot hold the frame is an error too, not a truncation.
    var rc4 = range.Decoder.init(&bytes);
    var tiny: [16]f32 = @splat(0.0);
    try std.testing.expectError(error.Corrupt, dec.decodeSuperframe(&rc4, .{ &tiny, &tiny }, .wide, 1, 20));
}

test "arbitrary bytes decode to finite samples" {
    // A payload that is not SILK still has to behave: the range decoder will
    // hand out whatever probability mass the symbols land on, so the parameters
    // can be extreme (maximum gains, minimum pitch lags, saturated LSFs). The
    // synthesis must stay finite instead of producing inf/NaN.
    var prng = std.Random.DefaultPrng.init(0x51_1C_0F_0D_2026);
    const random = prng.random();

    var dec = silk.Decoder.init(1);
    var out = [_][silk.max_frame]f32{ @splat(0.0), @splat(0.0) };
    const bands = [_]silk.Bandwidth{ .narrow, .medium, .wide };
    var payload: [64]u8 = undefined;

    for (0..300) |round| {
        random.bytes(&payload);
        const bandwidth = bands[round % bands.len];
        const duration: u32 = switch (round % 4) {
            0 => 10,
            1 => 20,
            2 => 40,
            else => 60,
        };
        var rc = range.Decoder.init(&payload);
        const n = dec.decodeSuperframe(
            &rc,
            .{ &out[0], &out[1] },
            bandwidth,
            1,
            duration,
        ) catch |err| {
            try std.testing.expectEqual(error.Corrupt, err);
            continue;
        };
        try std.testing.expect(n <= silk.max_frame);
        for (out[0][0..n]) |v| {
            try std.testing.expect(!std.math.isNan(v));
            try std.testing.expect(!std.math.isInf(v));
            try std.testing.expect(@abs(v) <= 1.0);
        }
    }
}

test "reset drops history so a restarted stream decodes identically" {
    var prng = std.Random.DefaultPrng.init(0x5A_11_C0_DE);
    const random = prng.random();
    var payload: [48]u8 = undefined;
    random.bytes(&payload);

    var a = silk.Decoder.init(1);
    var b = silk.Decoder.init(1);
    var out = [_][silk.max_frame]f32{ @splat(0.0), @splat(0.0) };
    var reference = [_][silk.max_frame]f32{ @splat(0.0), @splat(0.0) };

    var rc = range.Decoder.init(&payload);
    const n = try a.decodeSuperframe(&rc, .{ &out[0], &out[1] }, .wide, 1, 20);
    @memcpy(&reference[0], &out[0]);
    _ = n;

    // `b` is a fresh decoder with the same input: same output, to the bit.
    var rc2 = range.Decoder.init(&payload);
    _ = try b.decodeSuperframe(&rc2, .{ &out[0], &out[1] }, .wide, 1, 20);
    try std.testing.expectEqualSlices(f32, &reference[0], &out[0]);

    // `a` has history now, so a reset has to make it agree with `b` again.
    a.reset();
    var rc3 = range.Decoder.init(&payload);
    _ = try a.decodeSuperframe(&rc3, .{ &out[0], &out[1] }, .wide, 1, 20);
    try std.testing.expectEqualSlices(f32, &reference[0], &out[0]);
}

test "a stereo speech stream decodes to two channels, not one doubled" {
    // The committed fixture is 2 s of stereo 24 kbps speech: 91 SILK wideband
    // packets (mid/side) and the ten Hybrid packets the encoder puts at the
    // ends. It is the one hermetic check that the stereo path runs at all —
    // conformance against ffmpeg lives in `opus_silk_vectors_test.zig`, which
    // needs the external corpus.
    const bytes = @embedFile("fixtures/opus-stereo-silk-24k.opus");
    var reader = std.Io.Reader.fixed(bytes);
    var dec = try opus.Decoder.open(std.testing.allocator, &reader, "");
    defer dec.deinit();
    try std.testing.expectEqual(@as(u8, 2), dec.info.channels);

    var captured: std.ArrayList(f32) = .empty;
    defer captured.deinit(std.testing.allocator);
    dec.capture = &captured;
    dec.capture_gpa = std.testing.allocator;

    var buffer: [4096]i16 = undefined;
    while (true) {
        const n = try dec.read(&buffer);
        if (n == 0) break;
        try std.testing.expectEqual(@as(usize, 0), n % 2);
    }
    // `granule - pre_skip`, per channel.
    try std.testing.expectEqual(@as(usize, 96_000 * 2), captured.items.len);

    // The two channels are *not* the same signal: the fixture's left and right
    // carry different tones, so a decoder that skipped the mid/side unmix would
    // return two identical channels.
    var max_difference: f32 = 0;
    var i: usize = 0;
    while (i + 1 < captured.items.len) : (i += 2) {
        max_difference = @max(max_difference, @abs(captured.items[i] - captured.items[i + 1]));
    }
    try std.testing.expect(max_difference > 1e-3);
}
