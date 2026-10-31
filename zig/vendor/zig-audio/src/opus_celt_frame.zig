//! CELT stereo reconstruction and the per-frame band loop (RFC 6716 4.3.4.4,
//! 4.3.8).
//!
//! Stereo is coded as mid/side with an *angle*: the decoder reads `theta`,
//! turns it into two gains, decodes a unit-norm mid vector and a unit-norm side
//! vector, and rotates them back. Two details decide whether the output is
//! right:
//!
//!   * `itheta == 0` and `itheta == 16384` are special: one side carries
//!     everything and the other is not coded at all, and the `fill` mask has to
//!     be rewritten so the empty side cannot fold from a lower band.
//!   * the merge's `mid2` is `SHR16(mid, 1)` in the reference, and the float
//!     build defines `SHR16` as the identity. Doing the fixed-point halving
//!     scales every decoded sample by two — shapes, stereo image and per-frame
//!     waveform all look right, only the level is 6 dB high.
//!
//! `quantAllBands` is the loop that connects them: it walks the bands from low
//! to high, computes each band's bit budget from the running balance, decides
//! where it may fold from, and calls the mono or stereo band decoder. The
//! *order* of the two halves of a split matters, because whichever half is
//! coded second gets the rebalanced bits.

const std = @import("std");
const tables = @import("opus_celt_tables.zig");
const pvq = @import("opus_celt_pvq.zig");
const math = @import("opus_celt_math.zig");
const bands_mod = @import("opus_celt_bands.zig");
const range = @import("opus_range.zig");

const BandCtx = bands_mod.BandCtx;
const Workspace = bands_mod.Workspace;

const q15_one: f32 = 1.0;
const bitres: u5 = 3;
/// Merge mid/side back into left/right, undoing the orthonormal rotation.
fn stereoMerge(x: []f32, y: []f32, mid: f32, n: usize) void {
    var xp: f32 = 0;
    var side: f32 = 0;
    for (0..n) |i| {
        xp += y[i] * x[i];
        side += y[i] * y[i];
    }
    xp *= mid;
    // `mid2` is `SHR16(mid, 1)` in the reference, and the float build defines
    // `SHR16` as the identity: there is no halving here. Doing the fixed-point
    // halving instead scales every decoded sample by two.
    const mid2 = mid;
    const el = mid2 * mid2 + side - 2 * xp;
    const er = mid2 * mid2 + side + 2 * xp;
    if (er < 6e-4 or el < 6e-4) {
        @memcpy(y[0..n], x[0..n]);
        return;
    }
    const lgain = 1.0 / @sqrt(el);
    const rgain = 1.0 / @sqrt(er);
    for (0..n) |j| {
        const l = mid * x[j];
        const r = y[j];
        x[j] = lgain * (l - r);
        y[j] = rgain * (l + r);
    }
}

/// Decode a stereo band: theta, then mid and side, then merge.
fn quantBandStereo(
    ctx: *BandCtx,
    x: []f32,
    y: []f32,
    n: usize,
    b_in: i32,
    bblocks: usize,
    lowband: ?[]f32,
    lm: i32,
    lowband_out: ?[]f32,
    lowband_scratch: ?[]f32,
    fill_in: u32,
    ws: *Workspace,
) u32 {
    var b = b_in;
    var fill = fill_in;
    if (n == 1) return bands_mod.quantBandN1(ctx, x, y, &b, lowband_out);
    const orig_fill = fill;
    const sp = bands_mod.computeTheta(ctx, n, &b, bblocks, bblocks, lm, true, &fill);
    const mid: f32 = @as(f32, @floatFromInt(sp.imid)) / 32768.0;
    const side: f32 = @as(f32, @floatFromInt(sp.iside)) / 32768.0;
    var cm: u32 = 0;

    if (n == 2) {
        // Two bins only: the side needs a single sign bit.
        var mbits = b;
        var sbits: i32 = 0;
        if (sp.itheta != 0 and sp.itheta != 16384) sbits = 1 << bitres;
        mbits -= sbits;
        const swap = sp.itheta > 8192;
        ctx.remaining_bits -= sp.qalloc + sbits;
        const x2 = if (swap) y else x;
        const y2 = if (swap) x else y;
        var sign: i32 = 0;
        if (sbits != 0) sign = @intCast(ctx.dec.decodeBits(1));
        sign = 1 - 2 * sign;
        const sgn: f32 = @floatFromInt(sign);
        cm = bands_mod.quantBand(ctx, x2, n, mbits, bblocks, lowband, lm, lowband_out, q15_one, lowband_scratch, orig_fill, ws);
        y2[0] = -sgn * x2[1];
        y2[1] = sgn * x2[0];
        x[0] = mid * x[0];
        x[1] = mid * x[1];
        y[0] = side * y[0];
        y[1] = side * y[1];
        const t0 = x[0];
        x[0] = t0 - y[0];
        y[0] = t0 + y[0];
        const t1 = x[1];
        x[1] = t1 - y[1];
        y[1] = t1 + y[1];
    } else {
        var mbits: i32 = @max(0, @min(b, @divTrunc(b - sp.delta, 2)));
        var sbits: i32 = b - mbits;
        ctx.remaining_bits -= sp.qalloc;
        var rebalance = ctx.remaining_bits;
        if (mbits >= sbits) {
            cm = bands_mod.quantBand(ctx, x, n, mbits, bblocks, lowband, lm, lowband_out, q15_one, lowband_scratch, fill, ws);
            rebalance = mbits - (rebalance - ctx.remaining_bits);
            if (rebalance > 3 << bitres and sp.itheta != 0) sbits += rebalance - (3 << bitres);
            cm |= bands_mod.quantBand(ctx, y, n, sbits, bblocks, null, lm, null, side, null, fill >> @intCast(bblocks), ws);
        } else {
            cm = bands_mod.quantBand(ctx, y, n, sbits, bblocks, null, lm, null, side, null, fill >> @intCast(bblocks), ws);
            rebalance = sbits - (rebalance - ctx.remaining_bits);
            if (rebalance > 3 << bitres and sp.itheta != 16384) mbits += rebalance - (3 << bitres);
            cm |= bands_mod.quantBand(ctx, x, n, mbits, bblocks, lowband, lm, lowband_out, q15_one, lowband_scratch, fill, ws);
        }
    }
    if (n != 2) stereoMerge(x, y, mid, n);
    if (sp.inv) {
        for (0..n) |j| y[j] = -y[j];
    }
    return cm;
}

/// Copy enough of the first band's folding data to cover the second, so the
/// second band never falls back on the pseudo-random noise. A no-op for
/// CELT-only frames, where the first two bands are the same width.
fn specialHybridFolding(norm: []f32, norm2: []f32, start: usize, m: usize, dual_stereo: bool) void {
    const n1 = m * (tables.e_bands[start + 1] - tables.e_bands[start]);
    const n2 = m * (tables.e_bands[start + 2] - tables.e_bands[start + 1]);
    if (n2 <= n1) return;
    const count = n2 - n1;
    @memcpy(norm[n1..][0..count], norm[2 * n1 - n2 ..][0..count]);
    if (dual_stereo) @memcpy(norm2[n1..][0..count], norm2[2 * n1 - n2 ..][0..count]);
}

pub const BandParams = struct {
    start: usize,
    end: usize,
    channels: usize,
    lm: u3,
    short_blocks: usize,
    spread: u8,
    dual_stereo: bool,
    intensity: i32,
    tf_res: []const i32,
    total_bits: i32,
    balance: i32,
    coded_bands: usize,
    disable_inv: bool,
    dec: *range.Decoder,
};

/// Decode every band of one frame into `coeffs`, which holds `channels` blocks
/// of `frame_size` samples (channel-major).
pub fn quantAllBands(
    p: BandParams,
    coeffs: []f32,
    collapse_masks: []u8,
    pulses: []const i32,
    seed: u32,
    ws: *Workspace,
) u32 {
    const m = @as(usize, 1) << p.lm;
    const frame = m * tables.short_mdct;
    const b: usize = if (p.short_blocks != 0) m else 1;
    const norm_offset = m * tables.e_bands[p.start];
    const span = m * tables.e_bands[tables.bands - 1] - norm_offset;

    var ctx = BandCtx{
        .band = 0,
        .intensity = p.intensity,
        .spread = p.spread,
        .tf_change = 0,
        .remaining_bits = 0,
        .seed = seed,
        .disable_inv = p.disable_inv,
        .avoid_split_noise = b > 1,
        .channels = p.channels,
        .dec = p.dec,
    };

    const norm = ws.norm[0..span];
    const norm2 = ws.norm[span..][0..span];

    var balance = p.balance;
    var lowband_offset: usize = 0;
    var update_lowband = true;
    var dual_stereo = p.dual_stereo;
    const ch_stride = if (p.channels == 2) frame else 0;

    for (p.start..p.end) |i| {
        const last = i == p.end - 1;
        ctx.band = i;
        const off = m * tables.e_bands[i];
        const n = m * tables.e_bands[i + 1] - off;
        const tell = ctx.dec.tellFrac();
        if (i != p.start) balance -= @intCast(tell);
        const remaining_bits = p.total_bits - @as(i32, @intCast(tell)) - 1;
        ctx.remaining_bits = remaining_bits;
        var bb: i32 = 0;
        if (i <= p.coded_bands - 1) {
            const denom: i32 = @intCast(@min(@as(usize, 3), p.coded_bands - i));
            const curr_balance = @divTrunc(balance, denom);
            bb = @max(0, @min(16383, @min(remaining_bits + 1, pulses[i] + curr_balance)));
        }

        // Compared in signed arithmetic: `m*eBands[i] - n` is negative for the
        // first bands, which is exactly the "no room to fold from yet" case.
        const fold_room: i64 = @as(i64, @intCast(m * tables.e_bands[i])) - @as(i64, @intCast(n));
        if ((fold_room >= @as(i64, @intCast(m * tables.e_bands[p.start])) or i == p.start + 1) and
            (update_lowband or lowband_offset == 0))
        {
            lowband_offset = i;
        }
        if (i == p.start + 1) specialHybridFolding(norm, norm2, p.start, m, dual_stereo);

        ctx.tf_change = p.tf_res[i];
        var scratch: ?[]f32 = ws.lowband_scratch[0..];
        if (last) scratch = null;

        // Which lower bands may be folded from.
        var x_cm: u32 = 0;
        var y_cm: u32 = 0;
        var effective_lowband: i32 = -1;
        if (lowband_offset != 0 and
            (p.spread != pvq.spread_aggressive or b > 1 or ctx.tf_change < 0))
        {
            effective_lowband = @max(0, @as(i32, @intCast(m * tables.e_bands[lowband_offset])) -
                @as(i32, @intCast(norm_offset)) - @as(i32, @intCast(n)));
            const target: usize = @as(usize, @intCast(effective_lowband)) + norm_offset;
            var fold_start = lowband_offset;
            while (fold_start > 0 and m * tables.e_bands[fold_start - 1] > target) fold_start -= 1;
            var fold_end = lowband_offset - 1;
            while (fold_end + 1 < i and m * tables.e_bands[fold_end + 1] < target + n) fold_end += 1;
            x_cm = 0;
            y_cm = 0;
            var fold_i = fold_start;
            while (true) {
                x_cm |= collapse_masks[fold_i * p.channels];
                y_cm |= collapse_masks[fold_i * p.channels + p.channels - 1];
                fold_i += 1;
                if (fold_i >= fold_end) break;
            }
        } else {
            x_cm = (@as(u32, 1) << @intCast(b)) - 1;
            y_cm = x_cm;
        }

        if (dual_stereo and i == @as(usize, @intCast(@max(p.intensity, 0)))) {
            dual_stereo = false;
            for (0..m * tables.e_bands[i] - norm_offset) |j| {
                norm[j] = 0.5 * (norm[j] + norm2[j]);
            }
        }

        const lb_off: usize = @intCast(@max(effective_lowband, 0));
        const lowband_slice: ?[]f32 = if (effective_lowband != -1) norm[lb_off..] else null;
        const lowband_slice2: ?[]f32 = if (effective_lowband != -1) norm2[lb_off..] else null;
        const out_off = m * tables.e_bands[i] - norm_offset;
        const lowband_out: ?[]f32 = if (last) null else norm[out_off..];
        const lowband_out2: ?[]f32 = if (last) null else norm2[out_off..];

        const x_ch = coeffs[off..][0..n];
        if (dual_stereo) {
            x_cm = bands_mod.quantBand(&ctx, x_ch, n, @divTrunc(bb, 2), b, lowband_slice, p.lm, lowband_out, q15_one, scratch, x_cm, ws);
            y_cm = bands_mod.quantBand(&ctx, coeffs[ch_stride + off ..][0..n], n, @divTrunc(bb, 2), b, lowband_slice2, p.lm, lowband_out2, q15_one, scratch, y_cm, ws);
        } else if (p.channels == 2) {
            x_cm = quantBandStereo(&ctx, x_ch, coeffs[ch_stride + off ..][0..n], n, bb, b, lowband_slice, p.lm, lowband_out, scratch, x_cm | y_cm, ws);
            y_cm = x_cm;
        } else {
            x_cm = bands_mod.quantBand(&ctx, x_ch, n, bb, b, lowband_slice, p.lm, lowband_out, q15_one, scratch, x_cm | y_cm, ws);
            y_cm = x_cm;
        }
        collapse_masks[i * p.channels] = @truncate(x_cm);
        collapse_masks[i * p.channels + p.channels - 1] = @truncate(y_cm);
        balance += pulses[i] + @as(i32, @intCast(tell));
        update_lowband = bb > (@as(i32, @intCast(n)) << bitres);
        ctx.avoid_split_noise = false;
    }
    return ctx.seed;
}

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

test "bitexact cos hits the reference's landmarks" {
    // The angle quantiser's smallest non-zero step keeps x2 inside int16.
    try std.testing.expectEqual(@as(i32, 32767), math.bitexactCos(64));
    const c1 = math.bitexactCos(8192); // 45 degrees, cos = 0.7071
    try std.testing.expect(c1 > 23000 and c1 < 23300);
    const c2 = math.bitexactCos(16320);
    try std.testing.expect(c2 >= 0 and c2 < 400);
}

test "fracMul16 narrows its operands to 16 bits" {
    try std.testing.expectEqual(@as(i32, 32766), math.fracMul16(32767, 32767));
    try std.testing.expectEqual(@as(i32, 0), math.fracMul16(0, 12345));
    // 40000 truncates to -25536 as an int16.
    try std.testing.expectEqual(math.fracMul16(-25536, 32767), math.fracMul16(40000, 32767));
}

test "isqrt32 rounds down" {
    try std.testing.expectEqual(@as(u32, 0), math.isqrt32(0));
    try std.testing.expectEqual(@as(u32, 1), math.isqrt32(1));
    try std.testing.expectEqual(@as(u32, 3), math.isqrt32(9));
    try std.testing.expectEqual(@as(u32, 3), math.isqrt32(15));
    try std.testing.expectEqual(@as(u32, 4), math.isqrt32(16));
    try std.testing.expectEqual(@as(u32, 46340), math.isqrt32(2147483647));
}


test "stereo merge of an identical pair keeps both channels equal" {
    var x: [4]f32 = @splat(0.5);
    var y: [4]f32 = @splat(0.5);
    stereoMerge(&x, &y, 1.0, 4);
    for (0..4) |i| try std.testing.expectApproxEqAbs(x[i], y[i], 1e-5);
}

test "stereo merge does not halve the mid gain" {
    // With a silent side and mid = 1 the merge must be a no-op: the reference's
    // `SHR16(mid, 1)` is the identity in a float build. Halving here would
    // double the output (the +6 dB bug this file's header describes).
    var x: [4]f32 = @splat(0.25);
    var y: [4]f32 = @splat(0.0);
    stereoMerge(&x, &y, 1.0, 4);
    for (0..4) |i| try std.testing.expectApproxEqAbs(@as(f32, 0.25), x[i], 1e-6);
}