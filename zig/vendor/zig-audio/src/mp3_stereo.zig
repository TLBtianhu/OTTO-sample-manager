//! MPEG-1 Layer III joint stereo: mid/side and intensity.
//!
//! Both work on the requantized spectral lines (`xr`), in exactly the layout
//! the Huffman decoder produced -- for a window-switched granule that is still
//! the interleaved short-block order. They run *before* reordering, alias
//! reduction and the IMDCT, and that position is not a style choice:
//!
//!   * mid/side is a linear change of basis on the spectrum. Reordering is a
//!     permutation (it commutes), but alias reduction is a rotation of adjacent
//!     spectral lines *within one channel*, so applying it first would rotate
//!     each channel's alias terms against the wrong partner. After the IMDCT
//!     the values are time-domain samples and `M + S` no longer means anything;
//!     the transform cannot be deferred at all.
//!   * intensity replaces the right channel's lines with scaled copies of the
//!     left channel's lines in the top scalefactor bands, so it needs both
//!     channels' spectra simultaneously -- before they are transformed.
//!
//! Ordering inside a granule: Huffman/dequant for both channels, then this
//! file, then per-channel reorder -> alias -> IMDCT -> synthesis. That is also
//! the order ISO 11172-3 2.4.3.4.9 describes and the order ffmpeg and minimp3
//! implement.

const std = @import("std");
const frame = @import("mp3_frame.zig");
const tables = @import("mp3_tables.zig");

pub const Options = struct {
    /// `mode_extension` bit 1: every scalefactor band is a mid/side pair.
    ms: bool = false,
    /// `mode_extension` bit 0: the top bands carry intensity positions instead
    /// of a right-channel spectrum.
    intensity: bool = false,
};

/// ISO 11172-3 Table B.9, the seven legal intensity positions:
///
///     kl = tan(p*pi/12) / (1 + tan(p*pi/12))
///     kr = 1            / (1 + tan(p*pi/12))
///
/// p = 6 is the limit as tan -> infinity, i.e. exactly (1, 0); evaluating
/// tan(pi/2) in floating point yields (1 - 6e-17, 6e-17) instead, which would
/// leave a non-zero right channel where the table says silence.
pub const pan = blk: {
    var gains: [2][7]f32 = undefined;
    for (0..6) |p| {
        const t = @tan(std.math.pi * @as(f64, @floatFromInt(p)) / 12.0);
        gains[0][p] = @floatCast(t / (1.0 + t));
        gains[1][p] = @floatCast(1.0 / (1.0 + t));
    }
    gains[0][6] = 1.0;
    gains[1][6] = 0.0;
    break :blk gains;
};

/// One scalefactor band of the current granule: where its lines start, how many
/// there are, and which scalefactor slot holds its long scalefactor or its
/// intensity position. Short blocks contribute one entry per window, because
/// every (band, window) pair carries its own scalefactor.
const Band = struct {
    off: usize,
    len: usize,
    sf: usize,
};

/// Walk the granule's bands in ascending frequency order and return how many
/// entries were written. The widths come from the scalefactor band tables, so
/// the entries tile all 576 lines exactly once, in the same order the
/// requantized spectrum uses.
fn layout(sr_idx: usize, gi: *const frame.GranuleInfo, out: *[40]Band) usize {
    var n: usize = 0;
    var off: usize = 0;

    // A mixed block is the first two subbands in long windows (36 lines, eight
    // long bands) followed by short bands from sfb 3 up.
    const long_bands: usize = if (gi.block_type != 2) 22 else if (gi.mixed) 8 else 0;
    for (0..long_bands) |sfb| {
        const width = tables.band_long[sr_idx][sfb];
        // Long blocks transmit 21 scalefactors, so the top band has no slot of
        // its own and reuses band 20's -- the same rule the reference decoders
        // apply (`k = (i == 21) ? 20 : i`).
        out[n] = .{ .off = off, .len = width, .sf = if (sfb == 21) 20 else sfb };
        off += width;
        n += 1;
    }

    if (gi.block_type == 2) {
        // Short-block scalefactors are grouped by band, three windows each. The
        // top band (12) is not transmitted and reads back as zeros, which is
        // also what the intensity scan expects to see there.
        const first: usize = if (gi.mixed) 3 else 0;
        for (first..13) |sfb| {
            for (0..3) |win| {
                const width = tables.band_short[sr_idx][sfb];
                const sf_index: usize = if (gi.mixed) 8 + (sfb - 3) * 3 + win else sfb * 3 + win;
                out[n] = .{ .off = off, .len = width, .sf = sf_index };
                off += width;
                n += 1;
            }
        }
    }
    std.debug.assert(off == 576);
    return n;
}

fn hasNonZero(x: *const [576]f32, band: Band) bool {
    for (x[band.off..][0..band.len]) |v| {
        if (v != 0) return true;
    }
    return false;
}

fn clearBand(left: *[576]f32, right: *[576]f32, band: Band) void {
    @memset(left[band.off..][0..band.len], 0);
    @memset(right[band.off..][0..band.len], 0);
}

/// Intensity stereo: both output channels become scaled copies of the left
/// channel's lines, so the right channel's requantized garbage (its Huffman
/// data is meaningless there) is overwritten rather than mixed.
fn panBand(left: *[576]f32, right: *[576]f32, band: Band, pos: u8) void {
    const kl = pan[0][pos];
    const kr = pan[1][pos];
    for (0..band.len) |i| {
        const x = left[band.off + i];
        left[band.off + i] = x * kl;
        right[band.off + i] = x * kr;
    }
}

/// Mid/side: L = M + S, R = M - S. The 1/sqrt(2) renormalization is not applied
/// here: for a mid/side-only frame the caller folds it into the global gain
/// (-2 quarter steps), and when intensity stereo is also on the two coefficient
/// sets meet in the M/S domain, where the bands that stay mid/side carry the
/// factor per band instead (`isqrt2` below). Both conventions match ffmpeg,
/// which is the decoder this project measures against.
fn butterflyBand(left: *[576]f32, right: *[576]f32, band: Band, scale: f32) void {
    for (0..band.len) |i| {
        const m = left[band.off + i];
        const s = right[band.off + i];
        left[band.off + i] = (m + s) * scale;
        right[band.off + i] = (m - s) * scale;
    }
}

const isqrt2: f32 = 0.70710678118654752440;

pub fn process(
    left: *[576]f32,
    right: *[576]f32,
    sr_idx: usize,
    gi: *const frame.GranuleInfo,
    sf: *const [40]u8,
    opts: Options,
) void {
    if (!opts.ms and !opts.intensity) return;

    if (opts.ms and !opts.intensity) {
        var i: usize = 0;
        while (i < 576) : (i += 1) {
            const m = left[i];
            const s = right[i];
            left[i] = m + s;
            right[i] = m - s;
        }
        return;
    }

    var bands: [40]Band = undefined;
    const count = layout(sr_idx, gi, &bands);
    // Intensity plus mid/side meet in the M/S domain: the bands that keep
    // mid/side need the 1/sqrt(2) that an MS-only frame puts in the global gain.
    const ms_scale: f32 = if (opts.ms) isqrt2 else 1.0;

    // Intensity positions are only meaningful for the contiguous run of top
    // bands where the right channel carries no data at all; its highest
    // non-zero line marks the boundary. Everything below is mid/side (or plain
    // left/right when MS is off).
    var scanning = true;
    var i = count;
    while (i > 0) {
        i -= 1;
        const band = bands[i];
        if (scanning) {
            const pos = sf[band.sf];
            if (hasNonZero(right, band)) {
                scanning = false;
            } else if (pos == 7) {
                // 7 is not a panning position: tan(7*pi/12) is negative, so
                // the band is muted instead of scaled.
                clearBand(left, right, band);
                continue;
            } else if (pos > 7) {
                // Only 0..7 are legal positions; anything larger means this
                // band is ordinary spectrum and the region ends here.
                scanning = false;
            } else {
                panBand(left, right, band, pos);
                continue;
            }
        }
        if (opts.ms) butterflyBand(left, right, band, ms_scale);
    }
}

test "intensity table matches the tangent formula" {
    for (0..6) |p| {
        const t = @tan(std.math.pi * @as(f64, @floatFromInt(p)) / 12.0);
        try std.testing.expectApproxEqAbs(t / (1.0 + t), @as(f64, pan[0][p]), 1e-7);
        try std.testing.expectApproxEqAbs(1.0 / (1.0 + t), @as(f64, pan[1][p]), 1e-7);
    }
    try std.testing.expectEqual(@as(f32, 1.0), pan[0][6]);
    try std.testing.expectEqual(@as(f32, 0.0), pan[1][6]);
    // 0 is hard right, 6 is hard left, 3 is centred.
    try std.testing.expectEqual(@as(f32, 0.0), pan[0][0]);
    try std.testing.expectEqual(@as(f32, 1.0), pan[1][0]);
    try std.testing.expectEqual(@as(f32, 0.5), pan[0][3]);
    try std.testing.expectEqual(@as(f32, 0.5), pan[1][3]);
}

test "band layout tiles all 576 lines for every block shape and rate" {
    for (0..3) |sr| {
        for ([_]struct { block_type: u2, mixed: bool }{
            .{ .block_type = 0, .mixed = false },
            .{ .block_type = 2, .mixed = false },
            .{ .block_type = 2, .mixed = true },
        }) |cfg| {
            var gi = quietGranule();
            gi.block_type = cfg.block_type;
            gi.mixed = cfg.mixed;
            var bands: [40]Band = undefined;
            const n = layout(sr, &gi, &bands);
            var expect_off: usize = 0;
            for (bands[0..n]) |band| {
                try std.testing.expectEqual(expect_off, band.off);
                expect_off += band.len;
            }
            try std.testing.expectEqual(@as(usize, 576), expect_off);
        }
    }
}

fn quietGranule() frame.GranuleInfo {
    return .{
        .part2_3_length = 0,
        .big_values = 0,
        .global_gain = 0,
        .scalefac_compress = 0,
        .block_type = 0,
        .mixed = false,
        .table_select = .{ 0, 0, 0 },
        .subblock_gain = .{ 0, 0, 0 },
        .region0 = 0,
        .region1 = 0,
        .preflag = false,
        .scalefac_scale = 0,
        .count1table_select = 0,
        .scfsi = 0,
    };
}

test "is_pos 0..6 pan the left spectrum and 7 mutes the band" {
    // A single long block at 44.1 kHz: band sfb has lines [offset, offset+len).
    // The right channel carries no data in the intensity region, exactly as an
    // encoder writes it -- the scan ends at the first non-zero right line.
    const gi = quietGranule();
    const sr = 1;
    var pos: [40]u8 = @splat(3);
    pos[19] = 7; // muted
    pos[18] = 0; // hard right
    pos[17] = 6; // hard left
    pos[16] = 5; // heavily left

    var left: [576]f32 = @splat(0.25);
    var right: [576]f32 = @splat(0);

    process(&left, &right, sr, &gi, &pos, .{ .intensity = true });

    var bands: [40]Band = undefined;
    const n = layout(sr, &gi, &bands);
    try std.testing.expectEqual(@as(usize, 22), n);
    for (bands[0..n], 0..) |band, i| {
        for (0..band.len) |k| {
            const x = left[band.off + k];
            const y = right[band.off + k];
            if (i == 19) {
                try std.testing.expectEqual(@as(f32, 0), x);
                try std.testing.expectEqual(@as(f32, 0), y);
            } else if (i == 18) {
                try std.testing.expectEqual(@as(f32, 0), x);
                try std.testing.expectApproxEqAbs(@as(f32, 0.25), y, 1e-9);
            } else if (i == 17) {
                try std.testing.expectApproxEqAbs(@as(f32, 0.25), x, 1e-9);
                try std.testing.expectEqual(@as(f32, 0), y);
            } else {
                try std.testing.expectApproxEqAbs(0.25 * pan[0][pos[band.sf]], x, 1e-9);
                try std.testing.expectApproxEqAbs(0.25 * pan[1][pos[band.sf]], y, 1e-9);
            }
        }
    }
}

test "mid/side adds and subtracts, and a non-constant right band ends the intensity region" {
    const gi = quietGranule();
    const sr = 1;
    var left: [576]f32 = @splat(0);
    var right: [576]f32 = @splat(0);
    var bands: [40]Band = undefined;
    const n = layout(sr, &gi, &bands);

    // Make the top band's right channel non-zero: that band and everything
    // below it must be mid/side, not intensity.
    for (right[bands[n - 1].off..][0..bands[n - 1].len]) |*v| v.* = 0.5;
    for (&left) |*v| v.* = 0.25;
    for (bands[0..n]) |band| {
        for (right[band.off..][0..band.len]) |*v| {
            if (v.* == 0) v.* = 0.5;
        }
    }
    var pos: [40]u8 = @splat(3);
    pos[20] = 7;

    process(&left, &right, sr, &gi, &pos, .{ .ms = true, .intensity = true });
    // The whole spectrum is mid/side because the top band has right-channel
    // data, so no band is muted and every line is (L +- R) / sqrt(2): with
    // intensity on, the 1/sqrt(2) the encoder applied lives in the band
    // coefficients rather than in the global gain.
    for (0..576) |i| {
        try std.testing.expectApproxEqAbs(@as(f32, 0.75 * isqrt2), left[i], 1e-6);
        try std.testing.expectApproxEqAbs(@as(f32, -0.25 * isqrt2), right[i], 1e-6);
    }
}

test "pure mid/side leaves the bands untouched otherwise" {
    const gi = quietGranule();
    const sr = 1;
    var left: [576]f32 = undefined;
    var right: [576]f32 = undefined;
    for (&left, 0..) |*v, i| v.* = @as(f32, @floatFromInt(i)) * 1e-3;
    for (&right, 0..) |*v, i| v.* = -@as(f32, @floatFromInt(i)) * 1e-3;
    var pos: [40]u8 = @splat(0);
    process(&left, &right, sr, &gi, &pos, .{ .ms = true });
    for (left, 0..) |v, i| {
        const x = @as(f32, @floatFromInt(i)) * 1e-3;
        try std.testing.expectApproxEqAbs(@as(f32, 0), v, 1e-6);
        try std.testing.expectApproxEqAbs(2.0 * x, right[i], 1e-6);
    }
}

test "short blocks take one intensity position per band and window" {
    // Short-block scalefactors are stored band-major, three windows each, so
    // the position for (band, window) sits at sf[3 * band + window]. Position
    // 0 on band 5, window 1 must pan exactly those lines and nothing else.
    var gi = quietGranule();
    gi.block_type = 2;
    const sr = 1;
    var pos: [40]u8 = @splat(3);
    pos[3 * 5 + 1] = 0;

    var left: [576]f32 = @splat(0.25);
    var right: [576]f32 = @splat(0);
    process(&left, &right, sr, &gi, &pos, .{ .intensity = true });

    var bands: [40]Band = undefined;
    const n = layout(sr, &gi, &bands);
    try std.testing.expectEqual(@as(usize, 39), n);
    for (bands[0..n]) |band| {
        const panned = band.sf == 3 * 5 + 1;
        for (0..band.len) |k| {
            const x = left[band.off + k];
            const y = right[band.off + k];
            if (panned) {
                try std.testing.expectEqual(@as(f32, 0), x);
                try std.testing.expectApproxEqAbs(@as(f32, 0.25), y, 1e-9);
            } else {
                try std.testing.expectApproxEqAbs(@as(f32, 0.125), x, 1e-9);
                try std.testing.expectApproxEqAbs(@as(f32, 0.125), y, 1e-9);
            }
        }
    }
}

test "a position above 7 ends the intensity region without panning it" {
    const gi = quietGranule();
    const sr = 1;
    var pos: [40]u8 = @splat(3);
    pos[20] = 0; // the top two bands pan hard right
    pos[15] = 9; // not a legal position: bands 15 and below stay untouched

    var left: [576]f32 = @splat(0.25);
    var right: [576]f32 = @splat(0);
    process(&left, &right, sr, &gi, &pos, .{ .intensity = true });

    var bands: [40]Band = undefined;
    const n = layout(sr, &gi, &bands);
    for (bands[0..n], 0..) |band, i| {
        for (0..band.len) |k| {
            const x = left[band.off + k];
            const y = right[band.off + k];
            if (i >= 16) {
                // In the region: hard right above band 19, centred below it.
                if (i >= 20) {
                    try std.testing.expectEqual(@as(f32, 0), x);
                    try std.testing.expectApproxEqAbs(@as(f32, 0.25), y, 1e-9);
                } else {
                    try std.testing.expectApproxEqAbs(@as(f32, 0.125), x, 1e-9);
                    try std.testing.expectApproxEqAbs(@as(f32, 0.125), y, 1e-9);
                }
            } else {
                try std.testing.expectApproxEqAbs(@as(f32, 0.25), x, 1e-9);
                try std.testing.expectEqual(@as(f32, 0), y);
            }
        }
    }
}
