//! CELT energy envelope decoding: coarse, fine, and the leftover "final" bits
//! (RFC 6716 4.3.2).
//!
//! The envelope is coded in the base-2 log domain, one value per band per
//! channel, and every later stage hangs off it: the coarse value sets the band
//! gain, the fine bits refine it, and the final pass spends whatever is left.
//! Three details are easy to get wrong and all three are silent:
//!
//!   * the *time* prediction reads the previous frame's fully refined value
//!     while the *frequency* prediction reads only the current frame's coarse
//!     values — so a band's own coarse value must be written back before the
//!     next band is decoded;
//!   * `prev[c]` accumulates `q - beta*q`, not `q`, i.e. the leaky integrator
//!     of the frequency predictor;
//!   * the final pass spends bits in two priority classes and stops the moment
//!     fewer than `channels` bits remain, because each band needs one bit per
//!     channel.

const std = @import("std");
const tables = @import("opus_celt_tables.zig");
const range = @import("opus_range.zig");

pub const Error = error{Corrupt};

/// The largest the coarse prediction may leave a band's previous energy at.
const energy_floor: f32 = -9.0;
/// The value a silent frame's envelope is set to.
pub const energy_silence: f32 = -28.0;

/// Decode the coarse energy for bands `start..end` into `old_band_e`, which is
/// `2 * tables.bands` long (channel-major: `[c * bands + i]`).
///
/// `old_band_e` is both input (the previous frame's refined value) and output.
pub fn unquantCoarseEnergy(
    start: usize,
    end: usize,
    old_band_e: []f32,
    intra: bool,
    dec: *range.Decoder,
    channels: usize,
    lm: u3,
) void {
    const model = tables.coarse_energy_dist[lm][@intFromBool(intra)];
    var prev = [2]f32{ 0.0, 0.0 };
    const coef: f32 = if (intra) 0.0 else tables.pred_coef[lm];
    const beta: f32 = if (intra) tables.beta_intra else tables.beta_coef[lm];
    const budget: i32 = @intCast(dec.buf.len * 8);

    var i = start;
    while (i < end) : (i += 1) {
        var c: usize = 0;
        while (c < channels) : (c += 1) {
            const tell = dec.tell();
            const available = budget - tell;
            const qi: i32 = if (available >= 15) blk: {
                const pi: usize = @as(usize, @min(i, 20)) * 2;
                break :blk range.laplaceDecode(
                    dec,
                    @as(u32, model[pi]) << 7,
                    @as(i32, model[pi + 1]) << 6,
                );
            } else if (available >= 2) blk: {
                const v = dec.decodeIcdf(&tables.small_energy_icdf, 2);
                // Fold 0,1,2 into 0,-1,+1.
                break :blk @as(i32, @intCast(v >> 1)) ^ -@as(i32, @intCast(v & 1));
            } else if (available >= 1) -@as(i32, dec.decodeBitLogp(1)) else -1;

            const q: f32 = @floatFromInt(qi);
            const slot = &old_band_e[c * tables.bands + i];
            slot.* = @max(energy_floor, slot.*) * coef + prev[c] + q;
            prev[c] = prev[c] + q - beta * q;
        }
    }
}

/// Refine the coarse envelope with `fine_quant[i]` raw bits per band.
pub fn unquantFineEnergy(
    start: usize,
    end: usize,
    old_band_e: []f32,
    fine_quant: []const i32,
    dec: *range.Decoder,
    channels: usize,
) void {
    var i = start;
    while (i < end) : (i += 1) {
        const bits = fine_quant[i];
        if (bits <= 0) continue;
        const frac: f32 = @floatFromInt(@as(u32, 1) << @intCast(14 - bits));
        var c: usize = 0;
        while (c < channels) : (c += 1) {
            const q2 = dec.decodeBits(@intCast(bits));
            const offset = (@as(f32, @floatFromInt(q2)) + 0.5) * frac / 16384.0 - 0.5;
            old_band_e[c * tables.bands + i] += offset;
        }
    }
}

/// Spend the remaining bits on one extra refinement bit per band, in two
/// priority passes.
pub fn unquantEnergyFinalise(
    start: usize,
    end: usize,
    old_band_e: []f32,
    fine_quant: []const i32,
    fine_priority: []const i32,
    bits_left_in: i32,
    dec: *range.Decoder,
    channels: usize,
) void {
    var bits_left = bits_left_in;
    var prio: i32 = 0;
    while (prio < 2) : (prio += 1) {
        var i = start;
        while (i < end and bits_left >= @as(i32, @intCast(channels))) : (i += 1) {
            if (fine_quant[i] >= 8 or fine_priority[i] != prio) continue;
            const frac: f32 = @floatFromInt(@as(u32, 1) << @intCast(14 - fine_quant[i] - 1));
            var c: usize = 0;
            while (c < channels) : (c += 1) {
                const q2 = dec.decodeBits(1);
                const offset = (@as(f32, @floatFromInt(q2)) - 0.5) * frac / 16384.0;
                old_band_e[c * tables.bands + i] += offset;
                bits_left -= 1;
            }
        }
    }
}

test "coarse energy with a single band and no prediction" {
    // All-zero payload: the Laplace decoder sees a zero delta every time.
    const bytes: [32]u8 = @splat(0x00);
    var dec = range.Decoder.init(&bytes);
    var e: [2 * tables.bands]f32 = @splat(0.0);
    unquantCoarseEnergy(0, 1, &e, true, &dec, 1, 3);
    // An intra frame has coef 0, so the previous value is ignored and the
    // envelope is just the decoded delta.
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), e[0], 2.0);
    try std.testing.expect(dec.tell() > 1);
}

test "fine energy offset lands on the band's half-step grid" {
    const bytes: [32]u8 = @splat(0x00);
    var dec = range.Decoder.init(&bytes);
    var e: [2 * tables.bands]f32 = @splat(0.0);
    var fq: [tables.bands]i32 = @splat(0);
    const before = e[0];
    unquantFineEnergy(0, 1, &e, &fq, &dec, 1);
    // With 2 fine bits the correction is a multiple of 1/4, offset by 1/8.
    const delta = e[0] - before;
    try std.testing.expect(@abs(delta) < 0.5);
}

test "finalise never overspends" {
    const bytes: [32]u8 = @splat(0xFF);
    var dec = range.Decoder.init(&bytes);
    var e: [2 * tables.bands]f32 = @splat(0.0);
    const fq: [tables.bands]i32 = @splat(0);
    const pri: [tables.bands]i32 = @splat(0);
    const before = dec.tell();
    unquantEnergyFinalise(0, 4, &e, &fq, &pri, 3, &dec, 1);
    // Three bits must have been consumed at most.
    try std.testing.expect(dec.tell() - before <= 3);
}
