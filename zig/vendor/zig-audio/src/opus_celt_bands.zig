//! CELT band decoding: theta (the split angle), recursive band splitting, the
//! PVQ shape, stereo merging, anti-collapse and denormalisation
//! (RFC 6716 4.3.4 - 4.3.6).
//!
//! A band is decoded either as one PVQ vector or, if it has more bits than a
//! single codebook can express, by splitting it in two and coding the *angle*
//! between the halves. Each split costs `qalloc` bits that come out of the
//! band's budget, so the recursion and the budget are coupled; `remaining_bits`
//! is threaded through every call and the order of the two halves decides which
//! one gets the rebalanced bits.
//!
//! The same recursion codes mid/side in stereo. The angle is coded with one of
//! three distributions (uniform for time splits, stepped for stereo, triangular
//! otherwise) and turned into gains by `bitexactCos` — a fixed Q15 polynomial
//! that is deliberately *not* `cos`, because its output feeds the bit
//! allocation of the next band. It is only ever called with an angle in
//! `[64, 16320]` (the smallest non-zero step of the angle quantiser), which is
//! what keeps its int16 intermediate inside range.
//!
//! Folding is the fourth mechanism: a band with zero pulses copies a lower
//! band's spectrum instead of going silent, perturbed by a tiny pseudo-random
//! term so that repeated frames do not sound identical. That random stream is
//! seeded from the range decoder's final state, so a wrong seed shows up as
//! broadband noise rather than as a parse failure.

const std = @import("std");
const tables = @import("opus_celt_tables.zig");
const pvq = @import("opus_celt_pvq.zig");
const alloc_mod = @import("opus_celt_alloc.zig");
const range = @import("opus_range.zig");
const math = @import("opus_celt_math.zig");
const post = @import("opus_celt_post.zig");

pub const Error = error{Corrupt};

const bitres: u5 = 3;
const q15_one: f32 = 1.0;

/// Maximum samples in one band at the largest frame size.
pub const max_band_samples: usize = 8 * 22;
/// Bins covered by bands `[0, bands-1)`: the folding history's length.
pub const norm_len: usize = 8 * 78;

/// State carried down the band recursion.
pub const BandCtx = struct {
    band: usize,
    intensity: i32,
    spread: u8,
    tf_change: i32,
    remaining_bits: i32,
    seed: u32,
    disable_inv: bool,
    avoid_split_noise: bool,
    channels: usize,
    dec: *range.Decoder,
};

/// Result of `computeTheta`.
pub const Split = struct {
    inv: bool,
    imid: i32,
    iside: i32,
    delta: i32,
    itheta: i32,
    qalloc: i32,
};

/// Everything one frame's band decoding needs to scribble on.
pub const Workspace = struct {
    norm: [2 * norm_len]f32 = undefined,
    lowband_scratch: [max_band_samples]f32 = undefined,
    hadamard_tmp: [max_band_samples]f32 = undefined,
    iy: [130]i32 = undefined,
    u: [130]u32 = undefined,
};


fn computeQn(n: usize, b: i32, offset: i32, pulse_cap: i32, stereo: bool) i32 {
    const n2: i32 = @as(i32, @intCast(2 * n)) - 1 - @as(i32, @intFromBool(stereo and n == 2));
    var qb = @divTrunc(b + n2 * offset, n2);
    qb = @min(b - pulse_cap - (4 << bitres), qb);
    qb = @min(8 << bitres, qb);
    if (qb < (1 << bitres >> 1)) return 1;
    const shift: i32 = 14 - (qb >> bitres);
    var qn: i32 = @as(i32, tables.exp2_table8[@intCast(qb & 0x7)]) >> @intCast(shift);
    qn = (qn + 1) >> 1 << 1;
    return qn;
}

/// Decode the split angle and its two gains.
pub fn computeTheta(
    ctx: *BandCtx,
    n: usize,
    b: *i32,
    bblocks: usize,
    b0: usize,
    lm: i32,
    stereo: bool,
    fill: *u32,
) Split {
    const band = ctx.band;
    const pulse_cap: i32 = @as(i32, tables.log_n[band]) + lm * (1 << bitres);
    const offset: i32 = (pulse_cap >> 1) -
        (if (stereo and n == 2) alloc_mod.qtheta_offset_twophase else alloc_mod.qtheta_offset);
    var qn = computeQn(n, b.*, offset, pulse_cap, stereo);
    if (stereo and @as(i32, @intCast(band)) >= ctx.intensity) qn = 1;

    const tell = ctx.dec.tellFrac();
    var itheta: i32 = 0;
    var inv = false;
    if (qn != 1) {
        if (stereo and n > 2) {
            // Stepped distribution: `p0` up to the halfway point, then flat.
            const p0: u32 = 3;
            const x0: u32 = @intCast(@divTrunc(qn, 2));
            const ft = p0 * (x0 + 1) + x0;
            const fs = ctx.dec.decode(ft);
            var xv: u32 = undefined;
            if (fs < (x0 + 1) * p0) {
                xv = fs / p0;
            } else {
                xv = x0 + 1 + (fs - (x0 + 1) * p0);
            }
            const fl = if (xv <= x0) p0 * xv else (xv - 1 - x0) + (x0 + 1) * p0;
            const fh = if (xv <= x0) p0 * (xv + 1) else (xv - x0) + (x0 + 1) * p0;
            ctx.dec.update(fl, fh, ft);
            itheta = @intCast(xv);
        } else if (b0 > 1 or stereo) {
            itheta = @intCast(ctx.dec.decodeUint(@intCast(qn + 1)));
        } else {
            // Triangular distribution centred on the halfway angle.
            const half: u32 = @intCast(@divTrunc(qn, 2));
            const ft: u32 = (half + 1) * (half + 1);
            const fm = ctx.dec.decode(ft);
            var fs: u32 = undefined;
            var fl: u32 = 0;
            if (fm < (half * (half + 1) >> 1)) {
                itheta = @intCast((math.isqrt32(8 * fm + 1) - 1) >> 1);
                fs = @intCast(itheta + 1);
                fl = @intCast((itheta * (itheta + 1)) >> 1);
            } else {
                itheta = @intCast((2 * @as(u32, @intCast(qn + 1)) - math.isqrt32(8 * (ft - fm - 1) + 1)) >> 1);
                const q: u32 = @intCast(qn + 1 - itheta);
                fs = @intCast(qn + 1 - itheta);
                fl = ft - ((q * (q + 1)) >> 1);
            }
            ctx.dec.update(fl, fl + fs, ft);
        }
        itheta = @divTrunc(itheta * 16384, qn);
    } else if (stereo) {
        if (b.* > 2 << bitres and ctx.remaining_bits > 2 << bitres) {
            inv = ctx.dec.decodeBitLogp(2) == 1;
        }
        if (ctx.disable_inv) inv = false;
        itheta = 0;
    }
    const qalloc: i32 = @intCast(ctx.dec.tellFrac() - tell);
    b.* -= qalloc;

    var imid: i32 = 0;
    var iside: i32 = 0;
    var delta: i32 = 0;
    const mask = (@as(u32, 1) << @intCast(bblocks)) - 1;
    if (itheta == 0) {
        imid = 32767;
        iside = 0;
        fill.* &= mask;
        delta = -16384;
    } else if (itheta == 16384) {
        imid = 0;
        iside = 32767;
        fill.* &= mask << @intCast(bblocks);
        delta = 16384;
    } else {
        imid = math.bitexactCos(itheta);
        iside = math.bitexactCos(16384 - itheta);
        delta = math.fracMul16((@as(i32, @intCast(n)) - 1) << 7, math.bitexactLog2tan(iside, imid));
    }
    return .{ .inv = inv, .imid = imid, .iside = iside, .delta = delta, .itheta = itheta, .qalloc = qalloc };
}

/// A one-bin band codes only a sign per channel.
pub fn quantBandN1(ctx: *BandCtx, x: []f32, y: ?[]f32, b: *i32, lowband_out: ?[]f32) u32 {
    var sign0: u32 = 0;
    if (ctx.remaining_bits >= 1 << bitres) {
        sign0 = ctx.dec.decodeBits(1);
        ctx.remaining_bits -= 1 << bitres;
        b.* -= 1 << bitres;
    }
    x[0] = if (sign0 != 0) -q15_one else q15_one;
    if (y) |yy| {
        var sign1: u32 = 0;
        if (ctx.remaining_bits >= 1 << bitres) {
            sign1 = ctx.dec.decodeBits(1);
            ctx.remaining_bits -= 1 << bitres;
            b.* -= 1 << bitres;
        }
        yy[0] = if (sign1 != 0) -q15_one else q15_one;
    }
    if (lowband_out) |out| out[0] = x[0];
    return 1;
}

/// Haar butterfly, the in-place building block of the time/frequency swaps.
fn haar1(x: []f32, n0_in: usize, stride: usize) void {
    const n0 = n0_in >> 1;
    const c: f32 = 0.70710678;
    var i: usize = 0;
    while (i < stride) : (i += 1) {
        var j: usize = 0;
        while (j < n0) : (j += 1) {
            const t1 = c * x[stride * 2 * j + i];
            const t2 = c * x[stride * (2 * j + 1) + i];
            x[stride * 2 * j + i] = t1 + t2;
            x[stride * (2 * j + 1) + i] = t1 - t2;
        }
    }
}

fn deinterleaveHadamard(x: []f32, n0: usize, stride: usize, hadamard: bool, tmp: []f32) void {
    const n = n0 * stride;
    if (hadamard) {
        const ordery = tables.ordery_table[stride - 2 ..];
        var i: usize = 0;
        while (i < stride) : (i += 1) {
            var j: usize = 0;
            while (j < n0) : (j += 1) {
                tmp[ordery[i] * n0 + j] = x[j * stride + i];
            }
        }
    } else {
        var i: usize = 0;
        while (i < stride) : (i += 1) {
            var j: usize = 0;
            while (j < n0) : (j += 1) {
                tmp[i * n0 + j] = x[j * stride + i];
            }
        }
    }
    @memcpy(x[0..n], tmp[0..n]);
}

fn interleaveHadamard(x: []f32, n0: usize, stride: usize, hadamard: bool, tmp: []f32) void {
    const n = n0 * stride;
    if (hadamard) {
        const ordery = tables.ordery_table[stride - 2 ..];
        var i: usize = 0;
        while (i < stride) : (i += 1) {
            var j: usize = 0;
            while (j < n0) : (j += 1) {
                tmp[j * stride + i] = x[ordery[i] * n0 + j];
            }
        }
    } else {
        var i: usize = 0;
        while (i < stride) : (i += 1) {
            var j: usize = 0;
            while (j < n0) : (j += 1) {
                tmp[j * stride + i] = x[i * n0 + j];
            }
        }
    }
    @memcpy(x[0..n], tmp[0..n]);
}

/// Decode one partition: either a single PVQ vector or a recursive split.
fn quantPartition(
    ctx: *BandCtx,
    x: []f32,
    n_in: usize,
    b_in: i32,
    bblocks_in: usize,
    lowband: ?[]f32,
    lm_in: i32,
    gain: f32,
    fill_in: u32,
    ws: *Workspace,
) u32 {
    var n = n_in;
    var b = b_in;
    var bblocks = bblocks_in;
    var lm = lm_in;
    var fill = fill_in;
    const band = ctx.band;
    const cache_idx = tables.cache_index[@as(usize, @intCast(lm + 1)) * tables.bands + band];
    // A band with no codebook at this size has no bits worth reading; the
    // reference cannot hit this because only bands wider than two bins split,
    // and those always have a codebook. Guarding keeps a corrupt stream from
    // indexing before the table.
    if (cache_idx < 0) return 0;
    const cache = tables.cache_bits[@intCast(cache_idx)..];
    var cm: u32 = 0;

    if (lm != -1 and b > @as(i32, cache[cache[0]]) + 12 and n > 2) {
        const b0 = bblocks;
        n >>= 1;
        lm -= 1;
        if (bblocks == 1) fill = (fill & 1) | (fill << 1);
        bblocks = (bblocks + 1) >> 1;
        const sp = computeTheta(ctx, n, &b, bblocks, b0, lm, false, &fill);
        const mid_gain = gain * (@as(f32, @floatFromInt(sp.imid)) / 32768.0);
        const side_gain = gain * (@as(f32, @floatFromInt(sp.iside)) / 32768.0);
        var delta = sp.delta;
        if (b0 > 1 and (sp.itheta & 0x3fff) != 0) {
            if (sp.itheta > 8192) {
                delta -= delta >> @intCast(4 - lm);
            } else {
                delta = @min(0, delta + (@as(i32, @intCast(n)) << bitres >> @intCast(5 - lm)));
            }
        }
        var mbits: i32 = @max(0, @min(b, @divTrunc(b - delta, 2)));
        var sbits = b - mbits;
        ctx.remaining_bits -= sp.qalloc;

        var lowband2: ?[]f32 = null;
        if (lowband) |lb| lowband2 = lb[n..];

        var rebalance = ctx.remaining_bits;
        if (mbits >= sbits) {
            cm = quantPartition(ctx, x[0..n], n, mbits, bblocks, lowband, lm, mid_gain, fill, ws);
            rebalance = mbits - (rebalance - ctx.remaining_bits);
            if (rebalance > 3 << bitres and sp.itheta != 0) sbits += rebalance - (3 << bitres);
            cm |= quantPartition(ctx, x[n..][0..n], n, sbits, bblocks, lowband2, lm, side_gain, fill >> @intCast(bblocks), ws) << @intCast(b0 >> 1);
        } else {
            cm = quantPartition(ctx, x[n..][0..n], n, sbits, bblocks, lowband2, lm, side_gain, fill >> @intCast(bblocks), ws) << @intCast(b0 >> 1);
            rebalance = sbits - (rebalance - ctx.remaining_bits);
            if (rebalance > 3 << bitres and sp.itheta != 16384) mbits += rebalance - (3 << bitres);
            cm |= quantPartition(ctx, x[0..n], n, mbits, bblocks, lowband, lm, mid_gain, fill, ws);
        }
        return cm;
    }

    // No split: one PVQ codebook.
    var qv = pvq.bits2pulses(band, lm, b);
    var curr_bits: i32 = @intCast(pvq.pulses2bits(band, lm, qv));
    ctx.remaining_bits -= curr_bits;
    while (ctx.remaining_bits < 0 and qv > 0) {
        ctx.remaining_bits += curr_bits;
        qv -= 1;
        curr_bits = @intCast(pvq.pulses2bits(band, lm, qv));
        ctx.remaining_bits -= curr_bits;
    }
    if (qv != 0) {
        const k = pvq.getPulses(qv);
        cm = pvq.algUnquant(x[0..n], n, k, ctx.spread, bblocks, ctx.dec, gain, &ws.iy, &ws.u);
    } else {
        const cm_mask: u32 = (@as(u32, 1) << @intCast(bblocks)) - 1;
        fill &= cm_mask;
        if (fill == 0) {
            @memset(x[0..n], 0);
        } else {
            if (lowband) |lb| {
                // Fold: copy the lower band and nudge it so frames differ.
                var j: usize = 0;
                while (j < n) : (j += 1) {
                    ctx.seed = math.lcgRand(ctx.seed);
                    const tiny: f32 = 1.0 / 256.0;
                    const t = if (ctx.seed & 0x8000 != 0) tiny else -tiny;
                    x[j] = lb[j] + t;
                }
                cm = fill;
            } else {
                var j: usize = 0;
                while (j < n) : (j += 1) {
                    ctx.seed = math.lcgRand(ctx.seed);
                    x[j] = @floatFromInt(@as(i32, @bitCast(ctx.seed)) >> 20);
                }
                cm = cm_mask;
            }
            pvq.renormaliseVector(x, n, gain);
        }
    }
    return cm;
}

/// Decode a mono band, including the time/frequency (Hadamard) reshaping.
pub fn quantBand(
    ctx: *BandCtx,
    x: []f32,
    n: usize,
    b_in: i32,
    bblocks_in: usize,
    lowband_in: ?[]f32,
    lm: i32,
    lowband_out: ?[]f32,
    gain: f32,
    lowband_scratch: ?[]f32,
    fill_in: u32,
    ws: *Workspace,
) u32 {
    const n0 = n;
    var b = b_in;
    var bblocks = bblocks_in;
    const b0_in = bblocks_in;
    var time_divide: usize = 0;
    var recombine: usize = 0;
    var fill = fill_in;
    var tf_change = ctx.tf_change;
    const long_blocks = b0_in == 1;
    var lowband = lowband_in;

    if (n == 1) return quantBandN1(ctx, x, null, &b, lowband_out);

    var n_b = n / bblocks;
    if (tf_change > 0) recombine = @intCast(tf_change);
    if (lowband_scratch != null and lowband != null and
        (recombine != 0 or ((n_b & 1) == 0 and tf_change < 0) or b0_in > 1))
    {
        @memcpy(lowband_scratch.?[0..n], lowband.?[0..n]);
        lowband = lowband_scratch.?[0..n];
    }
    var k: usize = 0;
    while (k < recombine) : (k += 1) {
        if (lowband) |lb| haar1(lb, n >> @intCast(k), @as(usize, 1) << @intCast(k));
        fill = @as(u32, tables.bit_interleave_table[fill & 0xF]) |
            @as(u32, tables.bit_interleave_table[fill >> 4]) << 2;
    }
    bblocks >>= @intCast(recombine);
    n_b <<= @intCast(recombine);

    // More time resolution: keep halving while the block count is even.
    while ((n_b & 1) == 0 and tf_change < 0) {
        if (lowband) |lb| haar1(lb, n_b, bblocks);
        fill |= fill << @intCast(bblocks);
        bblocks <<= 1;
        n_b >>= 1;
        time_divide += 1;
        tf_change += 1;
    }
    const b0 = bblocks;
    const n_b0 = n_b;

    // Samples are stored in frequency order but quantised in time order.
    if (b0 > 1) {
        if (lowband) |lb| deinterleaveHadamard(lb, n_b >> @intCast(recombine), b0 << @intCast(recombine), long_blocks, &ws.hadamard_tmp);
    }

    var cm = quantPartition(ctx, x, n, b, bblocks, lowband, lm, gain, fill, ws);

    // Undo the reorganisation.
    if (b0 > 1) {
        interleaveHadamard(x, n_b >> @intCast(recombine), b0 << @intCast(recombine), long_blocks, &ws.hadamard_tmp);
    }
    n_b = n_b0;
    bblocks = b0;
    k = 0;
    while (k < time_divide) : (k += 1) {
        bblocks >>= 1;
        n_b <<= 1;
        cm |= cm >> @intCast(bblocks);
        haar1(x, n_b, bblocks);
    }
    k = 0;
    while (k < recombine) : (k += 1) {
        cm = tables.bit_deinterleave_table[cm & 0xF];
        haar1(x, n0 >> @intCast(k), @as(usize, 1) << @intCast(k));
    }
    bblocks <<= @intCast(recombine);

    // Scale the output so that later bands can fold from it.
    if (lowband_out) |out| {
        const nf: f32 = @floatFromInt(n0);
        const scale: f32 = @sqrt(nf);
        var j: usize = 0;
        while (j < n0) : (j += 1) out[j] = scale * x[j];
    }
    return cm & ((@as(u32, 1) << @intCast(bblocks)) - 1);
}

test "haar1 is a rotation pair" {
    var x = [_]f32{ 1.0, 0.0, 0.0, 0.0 };
    haar1(&x, 4, 1);
    try std.testing.expectApproxEqAbs(@as(f32, 0.70710678), x[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.70710678), x[1], 1e-6);
}

test "hadamard interleave and deinterleave are inverses" {
    var x = [_]f32{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var tmp: [8]f32 = undefined;
    const copy = x;
    deinterleaveHadamard(&x, 4, 2, false, &tmp);
    interleaveHadamard(&x, 4, 2, false, &tmp);
    for (copy, x) |a, b| try std.testing.expectApproxEqAbs(a, b, 1e-6);
}
