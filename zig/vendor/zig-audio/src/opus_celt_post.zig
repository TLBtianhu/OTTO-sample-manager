//! CELT's final spectral stages: anti-collapse and denormalisation
//! (RFC 6716 4.3.5, 4.3.6).
//!
//! Both run after the band shapes are decoded and before the IMDCT, and both
//! are easy to skip without noticing at high rates:
//!
//!   * **anti-collapse** only matters for transient frames, where the frame is
//!     several short MDCTs. If one short block got no pulse in a band, the
//!     decoder substitutes noise at the band's minimum recent energy instead of
//!     leaving a hole that clicks. The noise comes from the folding LCG, so a
//!     wrong seed is audible noise, not a parse error. Skipping it entirely is
//!     the classic "sounds mostly right, clicks on drums" bug.
//!   * **denormalisation** multiplies each band by `2^(logE + meanEnergy)`.
//!     The mean-energy table is why a band's decoded log value is not its gain:
//!     forgetting `mean_energy` scales every band by a different constant, which
//!     is audible as a fixed spectral tilt and invisible to any structural test.
//!
//! The gain uses `exp2`, and *which* `exp2` matters: the reference's float
//! build substitutes a polynomial with ~1e-4 relative error (its
//! `FLOAT_APPROX`), and that single choice is the 77 dB gap between the two
//! reference decoders on the same file.

const std = @import("std");
const tables = @import("opus_celt_tables.zig");
const pvq = @import("opus_celt_pvq.zig");
const math = @import("opus_celt_math.zig");

const q15_one: f32 = 1.0;
/// Undo denormalisation: multiply each band by `2^(logE + mean)`.
pub fn denormaliseBands(
    x: []const f32,
    freq: []f32,
    band_log_e: []const f32,
    start: usize,
    end: usize,
    m: usize,
    silence: bool,
) void {
    const total = m * tables.short_mdct;
    var bound = m * tables.e_bands[end];
    var s = start;
    var e = end;
    if (silence) {
        bound = 0;
        s = 0;
        e = 0;
    }
    @memset(freq[0 .. m * tables.e_bands[s]], 0);
    for (s..e) |i| {
        const band_end = m * tables.e_bands[i + 1];
        const lg = band_log_e[i] + tables.mean_energy[i];
        const g: f32 = @exp2(@min(@as(f32, 32.0), lg));
        const base = m * tables.e_bands[i];
        var j = base;
        while (j < band_end) : (j += 1) freq[j] = x[j] * g;
    }
    if (bound < total) @memset(freq[bound..total], 0);
}

/// Replace collapsed time blocks with noise at the band's minimum energy.
///
/// Band-major, channel inner: the order decides which pseudo-random value each
/// collapsed bin gets because one generator feeds both channels.
pub fn antiCollapse(
    x: []f32,
    collapse_masks: []const u8,
    lm: u3,
    channels: usize,
    size: usize,
    start: usize,
    end: usize,
    log_e: []const f32,
    prev1_log_e: []const f32,
    prev2_log_e: []const f32,
    pulses: []const i32,
    seed_in: u32,
) u32 {
    var seed = seed_in;
    for (start..end) |i| {
        const n0: usize = tables.freq_range[i];
        var depth = (1 + @as(u32, @intCast(pulses[i]))) / @as(u32, @intCast(n0));
        depth >>= lm;
        const thresh: f32 = 0.5 * @exp2(-0.125 * @as(f32, @floatFromInt(depth)));
        const bins: usize = n0 << lm;
        const nfl: f32 = @floatFromInt(bins);
        const sqrt_1: f32 = 1.0 / @sqrt(nfl);
        for (0..channels) |c| {
            var prev1 = prev1_log_e[c * tables.bands + i];
            var prev2 = prev2_log_e[c * tables.bands + i];
            if (channels == 1) {
                prev1 = @max(prev1, prev1_log_e[tables.bands + i]);
                prev2 = @max(prev2, prev2_log_e[tables.bands + i]);
            }
            const ediff = @max(@as(f32, 0.0), log_e[c * tables.bands + i] - @min(prev1, prev2));
            var r = 2.0 * @exp2(-ediff);
            if (lm == 3) r *= 1.41421356;
            r = @min(thresh, r) * sqrt_1;

            const base = c * size + (tables.e_bands[i] << lm);
            var renormalize = false;
            const blocks = @as(usize, 1) << lm;
            for (0..blocks) |k| {
                if (collapse_masks[i * channels + c] & (@as(u8, 1) << @intCast(k)) == 0) {
                    for (0..n0) |j| {
                        seed = math.lcgRand(seed);
                        x[base + (j << lm) + k] = if (seed & 0x8000 != 0) r else -r;
                    }
                    renormalize = true;
                }
            }
            if (renormalize) pvq.renormaliseVector(x[base..][0..bins], bins, q15_one);
        }
    }
    return seed;
}

test "denormalise zeroes the uncoded and out-of-bound parts" {
    var x: [tables.max_frame]f32 = @splat(1.0);
    var freq: [tables.max_frame]f32 = @splat(9.0);
    const log_e: [tables.bands]f32 = @splat(0.0);
    // LM = 3 (960 samples) and only band 0 coded: bins 8..959 are zeroed.
    denormaliseBands(&x, &freq, &log_e, 0, 1, 8, false);
    try std.testing.expect(freq[0] != 9.0);
    try std.testing.expectEqual(@as(f32, 0.0), freq[8]);
    try std.testing.expectEqual(@as(f32, 0.0), freq[959]);
}

test "anti-collapse fills collapsed blocks with the same magnitude" {
    // One band of 8 bins at LM=0 (one block), collapse mask 0, so the whole band
    // is replaced by noise of magnitude r and then renormalised to unit norm.
    var x: [8]f32 = @splat(0.0);
    const masks: [tables.bands]u8 = @splat(0);
    const log_e: [2 * tables.bands]f32 = @splat(-2.0);
    const prev1: [2 * tables.bands]f32 = @splat(-2.0);
    const prev2: [2 * tables.bands]f32 = @splat(-2.0);
    var pulses: [tables.bands]i32 = @splat(0);
    pulses[0] = 0;
    _ = antiCollapse(&x, &masks, 0, 1, 8, 0, 1, &log_e, &prev1, &prev2, &pulses, 12345);
    var norm: f32 = 0;
    for (x) |v| norm += v * v;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), norm, 1e-5);
}
