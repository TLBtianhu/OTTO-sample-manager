//! Floor 1 tests: the X-order used for curve synthesis, the integer
//! interpolation helpers, and the gain curve the decoder multiplies in.

const std = @import("std");
const vorbis = @import("vorbis.zig");
const vorbis_bits = @import("vorbis_bits.zig");
const floor_mod = @import("vorbis_floor.zig");
const testing = std.testing;

const AudioBits = vorbis_bits.AudioBits;

fn sampleFloor(x_list: []u16) vorbis.Floor1 {
    return .{
        .partition_class = &.{},
        .classes = &.{},
        .multiplier = 2,
        .rangebits = 7,
        .x_list = x_list,
    };
}

test "vorbis floor: the whole X list is sorted, so the top post is rendered last" {
    // The bug this pins: keeping posts 0 and 1 fixed leaves post 1 (X = 2^rangebits,
    // the largest) in slot 1 and draws every segment against the wrong endpoint.
    // The curve then has the right *values* but the wrong shape, which is why it
    // is worth a dedicated test.
    var x_list = [_]u16{ 0, 128, 8, 33, 4, 16, 70, 2, 6, 12, 23, 46, 90 };
    const table = try floor_mod.Table.init(sampleFloor(&x_list));
    try testing.expectEqual(@as(u8, 13), table.posts);
    try testing.expectEqualSlices(
        u8,
        &.{ 0, 7, 4, 8, 2, 9, 5, 10, 3, 11, 6, 12, 1 },
        table.forward[0..13],
    );
    // Ascending X, with X = 2^rangebits last.
    for (0..12) |i| {
        try testing.expect(x_list[table.forward[i]] < x_list[table.forward[i + 1]]);
    }
    try testing.expectEqual(@as(u16, 128), x_list[table.forward[12]]);
}

test "vorbis floor: neighbour search follows list order, not X order" {
    var x_list = [_]u16{ 0, 128, 8, 33, 4 };
    const table = try floor_mod.Table.init(sampleFloor(&x_list));
    // Post 2 (X = 8): the posts with a lower number are 0 (0), 1 (128) and
    // 3? no — only 0 and 1 exist below it, so low = 0, high = 1.
    try testing.expectEqual(@as(u8, 0), table.low[0]);
    try testing.expectEqual(@as(u8, 1), table.high[0]);
    // Post 3 (X = 33): post 2 (X = 8) is now a better low neighbour.
    try testing.expectEqual(@as(u8, 2), table.low[1]);
    try testing.expectEqual(@as(u8, 1), table.high[1]);
    // Post 4 (X = 4): post 2 is above it in X, so low stays 0 and high becomes 2.
    try testing.expectEqual(@as(u8, 0), table.low[2]);
    try testing.expectEqual(@as(u8, 2), table.high[2]);
}

test "vorbis floor: render_point is the specification's integer interpolation" {
    // Straight line from (0,0) to (128,64): the midpoint is 32.
    try testing.expectEqual(@as(i32, 32), floor_mod.renderPoint(0, 0, 128, 64, 64));
    try testing.expectEqual(@as(i32, 0), floor_mod.renderPoint(0, 0, 128, 64, 0));
    // Descending line, and the rounding is truncation toward zero.
    try testing.expectEqual(@as(i32, 8), floor_mod.renderPoint(0, 16, 16, 0, 8));
    try testing.expectEqual(@as(i32, 15), floor_mod.renderPoint(0, 16, 16, 0, 1));
}

test "vorbis floor: the dB table spans 140 dB and increases monotonically" {
    try testing.expect(@abs(floor_mod.db_table[0] - 1.0649863e-7) < 1e-12);
    try testing.expectEqual(@as(f32, 1.0), floor_mod.db_table[255]);
    for (1..256) |i| {
        try testing.expect(floor_mod.db_table[i] > floor_mod.db_table[i - 1]);
    }
    // Every step is about 0.55 dB.
    const ratio = floor_mod.db_table[255] / floor_mod.db_table[0];
    const total_db = 20.0 * std.math.log10(ratio);
    try testing.expect(@abs(total_db - 139.5) < 1.0);
}

test "vorbis floor: curve synthesis draws segments in X order and holds the last gain" {
    var x_list = [_]u16{ 0, 128, 8, 33 };
    const floor = sampleFloor(&x_list);
    const table = try floor_mod.Table.init(floor);

    var state = floor_mod.State{};
    state.final_y[0] = 64; // X = 0   -> index 128
    state.final_y[1] = 96; // X = 128 -> index 192
    state.final_y[2] = 32; // X = 8   -> index 64
    state.final_y[3] = 80; // X = 33  -> index 160
    for (0..4) |i| state.step2[i] = true;

    var spectrum: [256]f32 = @splat(1.0);
    floor_mod.applyCurve(&table, floor, &state, &spectrum);

    try testing.expectEqual(floor_mod.db_table[128], spectrum[0]);
    try testing.expectEqual(floor_mod.db_table[64], spectrum[8]);
    try testing.expectEqual(floor_mod.db_table[160], spectrum[33]);
    // From the last post (X = 128) to the end of the block the last gain holds.
    try testing.expectEqual(floor_mod.db_table[192], spectrum[128]);
    try testing.expectEqual(floor_mod.db_table[192], spectrum[255]);
    // The middle segment rises monotonically.
    for (34..128) |i| {
        try testing.expect(spectrum[i] >= spectrum[i - 1]);
    }
    // Everything is a gain, never an amplification.
    for (spectrum) |value| try testing.expect(value <= 1.0 + 1e-6);
}

test "vorbis floor: a cleared nonzero flag is one bit and means silence" {
    var x_list = [_]u16{ 0, 128 };
    const floor = sampleFloor(&x_list);
    const table = try floor_mod.Table.init(floor);
    var state = floor_mod.State{};
    const packet = [_]u8{0};
    var bits = AudioBits.init(&packet);
    const used = try floor_mod.decodePacket(&table, floor, &.{}, &bits, &state);
    try testing.expect(!used);
    try testing.expectEqual(@as(usize, 1), bits.bit);
}

