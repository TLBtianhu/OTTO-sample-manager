//! LPC subframe tests: the pieces that the official corpus cannot isolate.
//!
//! The corpus proves real-world agreement (vectors 12, 13, 61 and others), but
//! it rarely uses the corners this file pins down with synthetic streams:
//! orders 1, 8 and 32, precision 1/2/15, a negative prediction shift, LPC on a
//! decorrelated side subframe, LPC under wasted bits, and a predictor sum that
//! does not fit 32 bits.
//!
//! Every synthetic stream is built by `flac_build.zig` from the same formula the
//! decoder implements, so an off-by-one in shift or coefficient order fails the
//! sample comparison instead of being masked by a matching encoder bug.

const std = @import("std");
const root = @import("root.zig");
const testutil = @import("testutil.zig");
const build = @import("flac_build.zig");
const compare = @import("compare.zig");
const testing = std.testing;

const all_ones: [32]i32 = @splat(1);

fn decode(allocator: std.mem.Allocator, bytes: []const u8) ![]i16 {
    return testutil.decodeAll(allocator, bytes, 512);
}

/// 16-bit source: the decoder's i16 output must equal the source samples.
fn expectSamples(planes: []const []const i32, actual: []const i16) !void {
    var index: usize = 0;
    for (0..planes[0].len) |i| {
        for (planes) |plane| {
            if (index >= actual.len) return error.TooFewSamples;
            try testing.expectEqual(@as(i16, @intCast(plane[i])), actual[index]);
            index += 1;
        }
    }
    try testing.expectEqual(actual.len, index);
}

fn buildMono(
    allocator: std.mem.Allocator,
    samples: []const i32,
    frame: build.Frame,
) ![]u8 {
    const planes = [_][]const i32{samples};
    var with_samples = frame;
    with_samples.samples = &planes;
    const frames = [_]build.Frame{with_samples};
    return build.build(allocator, .{
        .sample_rate = 44_100,
        .channels = 1,
        .bits_per_sample = 16,
        .total_samples = samples.len,
        .frames = &frames,
    });
}

test "LPC orders 1, 8 and 32 reconstruct exactly" {
    var values: [64]i32 = undefined;
    for (&values, 0..) |*slot, i| {
        // A deterministic triangle-ish wave, small enough for every order.
        slot.* = @as(i32, @intCast(i % 31)) * 97 - 1000;
    }

    const Case = struct {
        order: u8,
        coeffs: []const i32,
        shift: i5,
        precision: u6,
        rice: u4,
    };
    const cases = [_]Case{
        .{ .order = 1, .coeffs = &[_]i32{2}, .shift = 1, .precision = 12, .rice = 4 },
        .{ .order = 8, .coeffs = &[_]i32{ 1, 1, 1, 1, 1, 1, 1, 1 }, .shift = 3, .precision = 12, .rice = 6 },
        .{ .order = 32, .coeffs = &all_ones, .shift = 5, .precision = 12, .rice = 6 },
    };

    for (cases) |case| {
        const bytes = try buildMono(testing.allocator, &values, .{
            .block_size = values.len,
            .modes = &.{.lpc},
            .lpc_order = case.order,
            .lpc_coeffs = case.coeffs,
            .lpc_shift = case.shift,
            .lpc_precision = case.precision,
            .rice_param = case.rice,
        });
        defer testing.allocator.free(bytes);

        const decoded = try decode(testing.allocator, bytes);
        defer testing.allocator.free(decoded);
        try expectSamples(&.{&values}, decoded);
    }
}

test "LPC precision 2 coefficients decode exactly" {
    var values: [32]i32 = undefined;
    for (&values, 0..) |*slot, i| slot.* = @as(i32, @intCast(i)) * 111 - 1700;

    // Two-bit signed coefficients can only be -2..1; this set is not an
    // identity filter, so the residual really depends on precision.
    const bytes = try buildMono(testing.allocator, &values, .{
        .block_size = values.len,
        .modes = &.{.lpc},
        .lpc_order = 2,
        .lpc_coeffs = &[_]i32{ 1, -2 },
        .lpc_shift = 2,
        .lpc_precision = 2,
        .rice_param = 8,
    });
    defer testing.allocator.free(bytes);

    const decoded = try decode(testing.allocator, bytes);
    defer testing.allocator.free(decoded);
    try expectSamples(&.{&values}, decoded);
}

test "LPC precision 15 coefficients decode exactly" {
    var values: [48]i32 = undefined;
    for (&values, 0..) |*slot, i| {
        const wave: i32 = @intCast((i * 163) % 3001);
        slot.* = wave - 1500;
    }

    // Full 15-bit coefficients, including the minimum (-16384). A sign-extension
    // bug at coefficient width shows up immediately at this precision.
    const bytes = try buildMono(testing.allocator, &values, .{
        .block_size = values.len,
        .modes = &.{.lpc},
        .lpc_order = 4,
        .lpc_coeffs = &[_]i32{ 16383, -16384, 8191, -8192 },
        .lpc_shift = 15,
        .lpc_precision = 15,
        .rice_param = 10,
    });
    defer testing.allocator.free(bytes);

    const decoded = try decode(testing.allocator, bytes);
    defer testing.allocator.free(decoded);
    try expectSamples(&.{&values}, decoded);
}

test "LPC precision 1 (stored field 0) is valid, not forbidden" {
    var values: [32]i32 = undefined;
    for (&values, 0..) |*slot, i| slot.* = @as(i32, @intCast(i)) * 37 - 500;

    // Table 22 stores precision - 1 and only 0b1111 is forbidden, so a stored 0
    // means a real one-bit coefficient: -1 or 0.
    const bytes = try buildMono(testing.allocator, &values, .{
        .block_size = values.len,
        .modes = &.{.lpc},
        .lpc_order = 2,
        .lpc_coeffs = &[_]i32{ 0, -1 },
        .lpc_shift = 1,
        .lpc_precision = 1,
        .rice_param = 8,
    });
    defer testing.allocator.free(bytes);

    const decoded = try decode(testing.allocator, bytes);
    defer testing.allocator.free(decoded);
    try expectSamples(&.{&values}, decoded);
}

test "LPC negative prediction shift is a left shift" {
    var values: [40]i32 = undefined;
    for (&values, 0..) |*slot, i| slot.* = @as(i32, @intCast(i % 9)) * 60 - 240;

    // RFC 9639 A.4 says encoders must not emit a negative shift, but the field
    // is signed. The intended meaning (and what old decoders did) is a left
    // shift; refusing the file would be stricter than the format, decoding it
    // as a right shift would be wrong audio.
    const bytes = try buildMono(testing.allocator, &values, .{
        .block_size = values.len,
        .modes = &.{.lpc},
        .lpc_order = 2,
        .lpc_coeffs = &[_]i32{ 1, 2 },
        .lpc_shift = -3,
        .lpc_precision = 12,
        .rice_param = 10,
    });
    defer testing.allocator.free(bytes);

    const decoded = try decode(testing.allocator, bytes);
    defer testing.allocator.free(decoded);
    try expectSamples(&.{&values}, decoded);
}

test "LPC under wasted bits predicts in the reduced domain" {
    // All source samples are multiples of 8, so the subframe stores them with
    // three implicit zero bits and the predictor must run on the reduced values.
    var values: [48]i32 = undefined;
    for (&values, 0..) |*slot, i| {
        slot.* = (@as(i32, @intCast(i % 13)) * 173 - 1100) * 8;
    }

    const bytes = try buildMono(testing.allocator, &values, .{
        .block_size = values.len,
        .modes = &.{.lpc},
        .lpc_order = 3,
        .lpc_coeffs = &[_]i32{ 2, -1, 1 },
        .lpc_shift = 1,
        .lpc_precision = 4,
        .wasted = 3,
        .rice_param = 6,
    });
    defer testing.allocator.free(bytes);

    const decoded = try decode(testing.allocator, bytes);
    defer testing.allocator.free(decoded);
    try expectSamples(&.{&values}, decoded);
}

test "LPC on a left/side frame predicts the one-bit-wider side plane" {
    var left: [64]i32 = undefined;
    var right: [64]i32 = undefined;
    var side: [64]i32 = undefined;
    for (&left, &right, &side, 0..) |*l, *r, *s, i| {
        l.* = if (i % 2 == 0) 30_000 - @as(i32, @intCast(i)) * 7 else -30_000 + @as(i32, @intCast(i)) * 5;
        r.* = @divTrunc(l.*, 2) + @as(i32, @intCast(i % 11)) - 5;
        s.* = l.* - r.*; // up to 17 bits, just like a real side subframe
    }

    const planes = [_][]const i32{ &left, &side };
    const frames = [_]build.Frame{.{
        .block_size = left.len,
        .modes = &.{ .lpc, .lpc },
        .samples = &planes,
        .lpc_order = 3,
        .lpc_coeffs = &[_]i32{ 2, -1, 1 },
        .lpc_shift = 1,
        .lpc_precision = 3,
        .rice_param = 10,
        .channel_assignment = 8,
    }};
    const bytes = try build.build(testing.allocator, .{
        .sample_rate = 44_100,
        .channels = 2,
        .bits_per_sample = 16,
        .total_samples = left.len,
        .frames = &frames,
    });
    defer testing.allocator.free(bytes);

    const decoded = try decode(testing.allocator, bytes);
    defer testing.allocator.free(decoded);
    try expectSamples(&.{ &left, &right }, decoded);
}

test "LPC predictor sums wider than 32 bits are not wrapped" {
    // 32 taps * 16383 * 32767 = 17,178,296,352: just under 2^34 and about 8x
    // the i32 limit. After >> 15 the prediction is 524,240, so the residual can
    // bring every sample back to 0. An i32 accumulator wraps that sum to
    // -1,572,832, predicts -48, and reconstructs -524,288 instead of 0:
    // plausible-looking audio with the wrong samples.
    const order = 32;
    var values: [64]i32 = undefined;
    for (values[0..order]) |*slot| slot.* = 32_767;
    @memset(values[order..], 0);

    const coefficients: [32]i32 = @splat(16_383);
    var frames = [_]build.Frame{.{
        .block_size = values.len,
        .modes = &.{.lpc},
        .lpc_order = order,
        .lpc_coeffs = &coefficients,
        .lpc_shift = 15,
        .lpc_precision = 15,
        .rice_param = 14,
    }};
    const planes = [_][]const i32{&values};
    frames[0].samples = &planes;

    const bytes = try build.build(testing.allocator, .{
        .sample_rate = 44_100,
        .channels = 1,
        .bits_per_sample = 16,
        .total_samples = values.len,
        .frames = &frames,
    });
    defer testing.allocator.free(bytes);

    const decoded = try decode(testing.allocator, bytes);
    defer testing.allocator.free(decoded);
    try expectSamples(&.{&values}, decoded);

    // Pin the test itself: the sum must overflow i32, and the wrapped prediction
    // must differ, otherwise this case would not prove anything.
    const exact_sum: i64 = @as(i64, order) * 16_383 * 32_767;
    try testing.expect(exact_sum > std.math.maxInt(i32));
    const wrapped: i32 = @bitCast(@as(u32, @truncate(@as(u64, @bitCast(exact_sum)))));
    try testing.expectEqual(@as(i32, -1_572_832), wrapped);
    try testing.expect(@as(i64, wrapped >> 15) != @divFloor(exact_sum, 1 << 15));
}

test "forbidden coefficient precision 0b1111 is Corrupt, not precision 16" {
    const values = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    const bytes = try buildMono(testing.allocator, &values, .{
        .block_size = values.len,
        .modes = &.{.lpc},
        .lpc_order = 1,
        .lpc_raw_precision = 15,
    });
    defer testing.allocator.free(bytes);

    var reader = std.Io.Reader.fixed(bytes);
    var dec = try root.open(testing.allocator, &reader);
    defer dec.deinit();
    var out: [32]i16 = undefined;
    try testing.expectError(error.Corrupt, dec.read(&out));
}

test "synthetic LPC stream matches ffmpeg sample for sample" {
    var values: [64]i32 = undefined;
    for (&values, 0..) |*slot, i| slot.* = @as(i32, @intCast(i % 29)) * 211 - 3000;
    const bytes = try buildMono(testing.allocator, &values, .{
        .block_size = values.len,
        .modes = &.{.lpc},
        .lpc_order = 8,
        .lpc_coeffs = &[_]i32{ 3, -2, 1, 0, -1, 2, -3, 1 },
        .lpc_shift = 4,
        .lpc_precision = 15,
        .rice_param = 8,
    });
    defer testing.allocator.free(bytes);

    try compare.expectExact(testing.allocator, bytes);
}
