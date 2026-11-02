//! Channel decorrelation tests: left/side, right/side and mid/side.
//!
//! `flac_build.zig` writes the *transformed* planes exactly as a FLAC encoder
//! would: the side channel is one bit wider than the source, and the
//! assignment decides whether it is the first or the second subframe. The
//! expected output is always the original left/right pair, so these tests fail
//! if the extra bit is put on the wrong subframe, if the reconstruction formula
//! is wrong, or if mid/side drops the side channel's low bit.

const std = @import("std");
const testutil = @import("testutil.zig");
const build = @import("flac_build.zig");
const testing = std.testing;

const Options = struct {
    modes: []const build.Mode = &.{ .verbatim, .verbatim },
    wasted: u5 = 0,
    fixed_order: u8 = 1,
};

/// Build a 16-bit stereo stream for `assignment` (8 = left/side, 9 =
/// right/side, 10 = mid/side) from the original left/right samples.
fn encode(
    allocator: std.mem.Allocator,
    assignment: u4,
    left: []const i32,
    right: []const i32,
    options: Options,
) ![]u8 {
    std.debug.assert(left.len == right.len);
    const n = left.len;

    const first = try allocator.alloc(i32, n);
    defer allocator.free(first);
    const second = try allocator.alloc(i32, n);
    defer allocator.free(second);
    for (left, right, 0..) |l, r, i| {
        switch (assignment) {
            8 => {
                first[i] = l;
                second[i] = l - r;
            },
            9 => {
                first[i] = l - r;
                second[i] = r;
            },
            10 => {
                first[i] = (l + r) >> 1;
                second[i] = l - r;
            },
            else => unreachable,
        }
    }

    const planes = [_][]const i32{ first, second };
    const frames = [_]build.Frame{.{
        .block_size = @intCast(n),
        .modes = options.modes,
        .samples = &planes,
        .fixed_order = options.fixed_order,
        .wasted = options.wasted,
        .channel_assignment = assignment,
    }};
    return build.build(allocator, .{
        .sample_rate = 44_100,
        .channels = 2,
        .bits_per_sample = 16,
        .total_samples = n,
        .frames = &frames,
    });
}

fn decode(allocator: std.mem.Allocator, bytes: []const u8) ![]i16 {
    return testutil.decodeAll(allocator, bytes, 7);
}

/// Source samples are 16-bit, so the decoder's i16 output must equal them.
fn expectStereo(left: []const i32, right: []const i32, actual: []const i16) !void {
    try testing.expectEqual(left.len * 2, actual.len);
    for (left, right, 0..) |l, r, i| {
        try testing.expectEqual(@as(i16, @intCast(l)), actual[i * 2]);
        try testing.expectEqual(@as(i16, @intCast(r)), actual[i * 2 + 1]);
    }
}

/// Values that force a 17-bit side plane (32767 - -32768 = 65535) and both
/// parities of the mid/side sum, including the minimum side value.
const extremes_left = [_]i32{ 32767, -32768, 0, 1, -1, 12345, -23456, 7, -7, 1000 };
const extremes_right = [_]i32{ -32768, 32767, 0, 0, 1, 23456, -12345, -7, 7, -1000 };

test "left/side: side is the second subframe and is one bit wider" {
    const bytes = try encode(
        testing.allocator,
        8,
        &extremes_left,
        &extremes_right,
        .{},
    );
    defer testing.allocator.free(bytes);

    const decoded = try decode(testing.allocator, bytes);
    defer testing.allocator.free(decoded);
    try expectStereo(&extremes_left, &extremes_right, decoded);
}

test "right/side: side is the FIRST subframe, so the +1 goes on channel 0" {
    const bytes = try encode(
        testing.allocator,
        9,
        &extremes_left,
        &extremes_right,
        .{},
    );
    defer testing.allocator.free(bytes);

    const decoded = try decode(testing.allocator, bytes);
    defer testing.allocator.free(decoded);
    try expectStereo(&extremes_left, &extremes_right, decoded);
}

test "mid/side: (mid << 1) | (side & 1) restores the dropped parity" {
    // Sums alternate even/odd: an implementation that forgets `side & 1`
    // reconstructs samples that are off by one but still "sound" plausible.
    const bytes = try encode(
        testing.allocator,
        10,
        &extremes_left,
        &extremes_right,
        .{},
    );
    defer testing.allocator.free(bytes);

    const decoded = try decode(testing.allocator, bytes);
    defer testing.allocator.free(decoded);
    try expectStereo(&extremes_left, &extremes_right, decoded);
}

test "decorrelation composes with FIXED orders 0..4" {
    var left: [64]i32 = undefined;
    var right: [64]i32 = undefined;
    for (&left, &right, 0..) |*l, *r, i| {
        l.* = @as(i32, @intCast(i)) * 3 - 50;
        r.* = 40 - @as(i32, @intCast(i)) * 2;
    }

    var assignment: u4 = 8;
    while (assignment <= 10) : (assignment += 1) {
        var order: u8 = 0;
        while (order <= 4) : (order += 1) {
            const bytes = try encode(
                testing.allocator,
                assignment,
                &left,
                &right,
                .{ .modes = &.{ .fixed, .fixed }, .fixed_order = order },
            );
            defer testing.allocator.free(bytes);

            const decoded = try decode(testing.allocator, bytes);
            defer testing.allocator.free(decoded);
            try expectStereo(&left, &right, decoded);
        }
    }
}

test "decorrelation happens after wasted bits are restored" {
    // Every source value is a multiple of 4, so both stored planes can legally
    // carry `wasted = 2`; the reconstruction must run on the restored samples.
    var left: [32]i32 = undefined;
    var right: [32]i32 = undefined;
    for (&left, &right, 0..) |*l, *r, i| {
        const base: i32 = @as(i32, @intCast(i)) * 8;
        l.* = base - 64;
        r.* = 64 - base;
    }

    var assignment: u4 = 8;
    while (assignment <= 10) : (assignment += 1) {
        const bytes = try encode(
            testing.allocator,
            assignment,
            &left,
            &right,
            .{ .wasted = 2 },
        );
        defer testing.allocator.free(bytes);

        const decoded = try decode(testing.allocator, bytes);
        defer testing.allocator.free(decoded);
        try expectStereo(&left, &right, decoded);
    }
}

test "LPC inside a decorrelated frame composes with all three assignments" {
    const values = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };

    var assignment: u4 = 8;
    while (assignment <= 10) : (assignment += 1) {
        // The LPC subframe sits where each assignment puts the side channel, so
        // the one-bit-wider plane is the one doing prediction.
        const modes: []const build.Mode = if (assignment == 9)
            &.{ .lpc, .verbatim }
        else
            &.{ .verbatim, .lpc };

        const bytes = try encode(
            testing.allocator,
            assignment,
            &values,
            &values,
            .{ .modes = modes },
        );
        defer testing.allocator.free(bytes);

        const decoded = try decode(testing.allocator, bytes);
        defer testing.allocator.free(decoded);
        try expectStereo(&values, &values, decoded);
    }
}
