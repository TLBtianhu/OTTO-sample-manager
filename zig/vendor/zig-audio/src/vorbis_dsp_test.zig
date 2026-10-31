//! Synthesis tests: the FFT, the IMDCT folding, the window shapes and the lap.

const std = @import("std");
const dsp = @import("vorbis_dsp.zig");
const testing = std.testing;

/// Direct evaluation of the IMDCT definition, in f64:
///   y[i] = sum_k X[k] * cos(pi/M * (i + 1/2 + M/2) * (k + 1/2))
fn referenceImdct(spectrum: []const f32, out: []f32) void {
    const half = spectrum.len;
    const n = half * 2;
    const m: f64 = @floatFromInt(half);
    for (0..n) |i| {
        var sum: f64 = 0;
        for (0..half) |k| {
            const angle = std.math.pi / m *
                (@as(f64, @floatFromInt(i)) + 0.5 + m / 2.0) *
                (@as(f64, @floatFromInt(k)) + 0.5);
            sum += @as(f64, spectrum[k]) * @cos(angle);
        }
        out[i] = @floatCast(sum);
    }
}

test "vorbis dsp: imdct matches the direct cosine sum" {
    const allocator = testing.allocator;
    const n = 64;
    var transform = try dsp.Transform.init(allocator, n);
    defer transform.deinit(allocator);

    const half = n / 2;
    const a = try allocator.alloc(dsp.Complex, half);
    defer allocator.free(a);
    const b = try allocator.alloc(dsp.Complex, half);
    defer allocator.free(b);
    const c = try allocator.alloc(f32, half);
    defer allocator.free(c);

    var prng = std.Random.DefaultPrng.init(0x0DC7_0004);
    const random = prng.random();
    var spectrum: [half]f32 = undefined;
    for (&spectrum) |*slot| slot.* = random.float(f32) * 2.0 - 1.0;

    var expected: [n]f32 = undefined;
    referenceImdct(&spectrum, &expected);

    var actual: [n]f32 = undefined;
    transform.run(&spectrum, &actual, a, b, c);

    var max_diff: f64 = 0;
    for (expected, actual) |want, got| {
        max_diff = @max(max_diff, @abs(@as(f64, want) - @as(f64, got)));
    }
    try testing.expect(max_diff < 1e-4);
}

test "vorbis dsp: a single spectral line produces the expected cosine" {
    const allocator = testing.allocator;
    const n = 32;
    var transform = try dsp.Transform.init(allocator, n);
    defer transform.deinit(allocator);
    const half = n / 2;
    const a = try allocator.alloc(dsp.Complex, half);
    defer allocator.free(a);
    const b = try allocator.alloc(dsp.Complex, half);
    defer allocator.free(b);
    const c = try allocator.alloc(f32, half);
    defer allocator.free(c);

    var spectrum: [half]f32 = @splat(0);
    spectrum[3] = 1.0;

    var actual: [n]f32 = undefined;
    transform.run(&spectrum, &actual, a, b, c);

    const m: f64 = @floatFromInt(half);
    for (0..n) |i| {
        const angle = std.math.pi / m *
            (@as(f64, @floatFromInt(i)) + 0.5 + m / 2.0) * (3.0 + 0.5);
        const want: f64 = @cos(angle);
        try testing.expect(@abs(@as(f64, actual[i]) - want) < 1e-5);
    }
}

test "vorbis dsp: the fft is the discrete transform" {
    const allocator = testing.allocator;
    const n = 16;
    var fft = try dsp.Fft.init(allocator, n);
    defer fft.deinit(allocator);

    var input: [n]dsp.Complex = undefined;
    var expected: [n]dsp.Complex = undefined;
    for (&input, 0..) |*slot, i| {
        slot.* = .{
            .re = @as(f32, @floatFromInt(i % 5)) - 2.0,
            .im = @as(f32, @floatFromInt(i % 3)) - 1.0,
        };
    }
    for (0..n) |k| {
        var sum_re: f64 = 0;
        var sum_im: f64 = 0;
        for (0..n) |j| {
            const angle = -2.0 * std.math.pi * @as(f64, @floatFromInt(k * j)) /
                @as(f64, @floatFromInt(n));
            const re = @as(f64, input[j].re);
            const im = @as(f64, input[j].im);
            sum_re += re * @cos(angle) - im * @sin(angle);
            sum_im += re * @sin(angle) + im * @cos(angle);
        }
        expected[k] = .{ .re = @floatCast(sum_re), .im = @floatCast(sum_im) };
    }

    var actual = input;
    fft.run(&actual);
    for (expected, actual) |want, got| {
        try testing.expect(@abs(@as(f64, want.re) - @as(f64, got.re)) < 1e-4);
        try testing.expect(@abs(@as(f64, want.im) - @as(f64, got.im)) < 1e-4);
    }
}

test "vorbis dsp: window slope has the specification's values" {
    // sin(pi/2 * sin^2((x+0.5)/n * pi)); the first and last of a 64-point
    // window are ~0, and the 32nd is ~1.
    try testing.expect(dsp.slope(0, 64) < 0.001);
    try testing.expect(dsp.slope(31, 64) > 0.9999);
    try testing.expect(dsp.slope(63, 64) < 0.001);
    // Symmetric about the centre.
    for (0..32) |i| {
        try testing.expect(@abs(dsp.slope(i, 64) - dsp.slope(63 - i, 64)) < 1e-6);
    }
}

test "vorbis dsp: hybrid windows pad with one and zero where the lap needs it" {
    const blocksize_0 = 64;
    const blocksize_1 = 512;
    var long_window: [blocksize_1]f32 = undefined;

    dsp.buildWindow(&long_window, blocksize_1, blocksize_0, .long_start);
    // Start window: zero before the short rise, one inside.
    try testing.expectEqual(@as(f32, 0), long_window[0]);
    try testing.expectEqual(@as(f32, 0), long_window[blocksize_1 / 4 - blocksize_0 / 4 - 1]);
    try testing.expectEqual(@as(f32, 1), long_window[blocksize_1 / 2 - 1]);
    const rise = dsp.slope(0, blocksize_0);
    try testing.expect(@abs(long_window[blocksize_1 / 4 - blocksize_0 / 4] - rise) < 1e-6);

    dsp.buildWindow(&long_window, blocksize_1, blocksize_0, .long_end);
    try testing.expectEqual(@as(f32, 1), long_window[blocksize_1 / 2]);
    try testing.expectEqual(@as(f32, 1), long_window[blocksize_1 * 3 / 4 - blocksize_0 / 4 - 1]);
    try testing.expectEqual(@as(f32, 0), long_window[blocksize_1 - 1]);

    // A normal long window has no padding at either end.
    dsp.buildWindow(&long_window, blocksize_1, blocksize_0, .long_normal);
    try testing.expect(long_window[0] > 0);
    try testing.expect(long_window[blocksize_1 - 1] > 0);

    // The short window is the long shape at the short size.
    var short_window: [blocksize_0]f32 = undefined;
    dsp.buildWindow(&short_window, blocksize_0, blocksize_0, .short);
    for (0..blocksize_0) |i| {
        try testing.expect(@abs(short_window[i] - dsp.slope(i, blocksize_0)) < 1e-7);
    }
}

test "vorbis dsp: window selection follows the neighbour flags" {
    try testing.expectEqual(
        dsp.WindowKind.short,
        dsp.WindowKind.select(64, 64, true, true),
    );
    try testing.expectEqual(
        dsp.WindowKind.long_normal,
        dsp.WindowKind.select(512, 64, true, true),
    );
    try testing.expectEqual(
        dsp.WindowKind.long_start,
        dsp.WindowKind.select(512, 64, false, true),
    );
    try testing.expectEqual(
        dsp.WindowKind.long_end,
        dsp.WindowKind.select(512, 64, true, false),
    );
    try testing.expectEqual(
        dsp.WindowKind.long_transient,
        dsp.WindowKind.select(512, 64, false, false),
    );
}


