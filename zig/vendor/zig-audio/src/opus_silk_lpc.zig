//! SILK's LPC stage: LSFs in, filter coefficients out.
//!
//! Everything here is fixed point, and the fixed point *is* the format. A
//! decoder that computed the same polynomials in float would produce a
//! different filter — the re-whitening step is sensitive to the last bit of
//! each coefficient — so the shifts and rounding constants below are not
//! implementation details that can be "cleaned up".
//!
//! The chain, in order:
//!
//!   1. the stage-1 index picks a codebook and a prediction-weight set;
//!   2. the stage-2 indices give a residual per LSF, which is un-predicted
//!      backwards (the residual of coefficient i+1 predicts coefficient i);
//!   3. codebook + weighted residual -> normalised LSF, Q15;
//!   4. stabilise: enforce the minimum spacing the format requires, then sort
//!      and push apart if the first pass ran out of attempts;
//!   5. LSFs -> LSPs (2*cos) by table interpolation, LSPs -> two polynomials
//!      by a Levinson-style recursion, and the two polynomials -> LPC;
//!   6. bound the coefficients (bandwidth expansion) and, if the prediction
//!      gain still makes the filter unstable, expand further — up to 16 times.

const std = @import("std");
const types = @import("opus_silk_types.zig");
const range = @import("opus_range.zig");
const tables = @import("opus_silk_tables_lsf.zig");
const cdf = @import("opus_silk_tables_cdf.zig");

const max_lpc = types.max_lpc;

/// One frame's filter: the interpolation lead-in for the first two subframes
/// (20 ms frames code their LSFs as a delta from the previous frame's) and the
/// body that the rest of the frame uses.
pub const Filter = struct {
    order: usize,
    leadin: [max_lpc]f32 = @splat(0.0),
    body: [max_lpc]f32 = @splat(0.0),
    has_leadin: bool = false,
    /// 0..3 while interpolating, 4 when this frame's LSFs apply to every
    /// subframe. The synthesis reads it to decide where the LTP scale changes.
    interp_factor: i32 = 4,
};

pub fn decode(
    rc: *range.Decoder,
    wb: bool,
    subframes: usize,
    frame: *types.Frame,
    voiced: bool,
) Filter {
    const order: usize = if (wb) 16 else 10;
    var out = Filter{ .order = order };

    const s1 = rc.decodeCdf(if (wb)
        &cdf.model_lsf_s1[1][@intFromBool(voiced)]
    else
        &cdf.model_lsf_s1[0][@intFromBool(voiced)]);
    var s2: [max_lpc]i32 = @splat(0);
    const sel: []const u8 = if (wb) &tables.lsf_s2_model_sel_wb[s1] else &tables.lsf_s2_model_sel_nbmb[s1];
    for (0..order) |i| {
        s2[i] = @as(i32, @intCast(rc.decodeCdf(&cdf.model_lsf_s2[sel[i]]))) - 4;
        if (s2[i] == -4) {
            s2[i] -= @intCast(rc.decodeCdf(&cdf.model_lsf_s2_ext));
        } else if (s2[i] == 4) {
            s2[i] += @intCast(rc.decodeCdf(&cdf.model_lsf_s2_ext));
        }
    }

    // Undo the backwards prediction: coefficient i's residual is the value
    // itself plus a weighted share of coefficient i+1's residual.
    var residual: [max_lpc]i16 = @splat(0);
    const qstep: i32 = if (wb) 9830 else 11796;
    var i = order;
    while (i > 0) {
        i -= 1;
        var r: i32 = s2[i] * 1024;
        if (s2[i] < 0) r += 102 else if (s2[i] > 0) r -= 102;
        r = (r *% qstep) >> 16;
        if (i + 1 < order) {
            const wsel: u8 = if (wb) tables.lsf_weight_sel_wb[s1][i] else tables.lsf_weight_sel_nbmb[s1][i];
            const weight: i32 = if (wb)
                tables.lsf_pred_weights_wb[wsel][i]
            else
                tables.lsf_pred_weights_nbmb[wsel][i];
            r +%= (@as(i32, residual[i + 1]) *% weight) >> 8;
        }
        residual[i] = @truncate(r);
    }

    // Codebook entry plus the residual, weighted by how much room the codebook
    // leaves between neighbouring coefficients.
    var nlsf: [max_lpc]i16 = @splat(0);
    const codebook: []const u8 = if (wb) &tables.lsf_codebook_wb[s1] else &tables.lsf_codebook_nbmb[s1];
    for (0..order) |k| {
        const cur: i32 = codebook[k];
        const prev: i32 = if (k == 0) 0 else codebook[k - 1];
        const next: i32 = if (k + 1 < order) codebook[k + 1] else 256;
        const weight = weightFromSpacing(cur - prev, next - cur);
        const value = cur *% 128 +% @divTrunc(@as(i32, residual[k]) *% 16384, weight);
        nlsf[k] = types.clipUint15(value);
    }

    const min_spacing = if (wb) &tables.lsf_min_spacing_wb else &tables.lsf_min_spacing_nbmb;
    stabilize(&nlsf, order, min_spacing);

    // Interpolation lead-in: 20 ms frames code an offset that blends the
    // previous frame's LSFs into this one's, covering the first two subframes.
    if (subframes == 4) {
        var offset: i32 = @intCast(rc.decodeCdf(&cdf.model_lsf_interpolation_offset));
        if (offset != 4 and frame.coded) {
            out.has_leadin = true;
            if (offset != 0) {
                var leadin_nlsf: [max_lpc]i16 = @splat(0);
                for (0..order) |k| {
                    const delta = (@as(i32, nlsf[k]) - frame.nlsf[k]) * offset;
                    leadin_nlsf[k] = @intCast(@as(i32, frame.nlsf[k]) + (delta >> 2));
                }
                lsfToLpc(&leadin_nlsf, &out.leadin, order);
            } else {
                out.leadin = frame.lpc;
            }
        } else {
            offset = 4;
        }
        out.interp_factor = offset;
        lsfToLpc(&nlsf, &out.body, order);
    } else {
        out.interp_factor = 4;
        lsfToLpc(&nlsf, &out.body, order);
    }

    for (0..order) |k| frame.nlsf[k] = nlsf[k];
    frame.lpc = out.body;
    return out;
}

/// The square root of `1024/(cur-prev) + 1024/(next-cur)` in Q16, by the
/// mandated integer approximation (RFC 6716 4.2.7.5.3): a mantissa/exponent
/// split plus one linear correction term.
fn weightFromSpacing(prev_gap: i32, next_gap: i32) i32 {
    const weight_sq: i32 = @divTrunc(1024, prev_gap) + @divTrunc(1024, next_gap);
    const shifted: u32 = @as(u32, @intCast(weight_sq)) << 16;
    const ipart: u32 = types.ilog(shifted);
    const fpart: i32 = @intCast((shifted >> @intCast(ipart - 8)) & 127);
    const y: i32 = @intCast((if (ipart & 1 != 0) @as(u32, 32768) else @as(u32, 46214)) >>
        @intCast((32 - ipart) >> 1));
    return y + ((213 * fpart * y) >> 16);
}

/// Enforce the minimum spacing between neighbouring LSFs.
///
/// The fast path moves the offenders directly; after 20 attempts the reference
/// falls back to sorting and pushing the vector apart from both ends. Ported
/// literally, including the `pass == 20` exit that cannot trigger from the loop
/// guard — "it can never happen" is exactly what a malformed payload breaks.
fn stabilize(nlsf: *[max_lpc]i16, order: usize, min_delta: []const u16) void {
    var pass: usize = 0;
    while (pass < 20) : (pass += 1) {
        var min_diff: i32 = 0;
        var k: usize = 0;
        var idx: usize = 0;
        while (idx < order + 1) : (idx += 1) {
            const low: i32 = if (idx != 0) nlsf[idx - 1] else 0;
            const high: i32 = if (idx != order) nlsf[idx] else 32768;
            const diff = (high - low) - @as(i32, min_delta[idx]);
            if (diff < min_diff) {
                min_diff = diff;
                k = idx;
                if (pass == 20) break;
            }
        }
        if (min_diff == 0) return;

        if (k == 0) {
            nlsf[0] = @truncate(@as(i32, min_delta[0]));
        } else if (k == order) {
            nlsf[order - 1] = @truncate(32768 - @as(i32, min_delta[order]));
        } else {
            var min_center: i32 = 0;
            for (0..k) |j| min_center += min_delta[j];
            min_center += @as(i32, min_delta[k]) >> 1;
            var max_center: i32 = 32768;
            var j = order;
            while (j > k) : (j -= 1) max_center -= min_delta[j];
            max_center -= @as(i32, min_delta[k]) >> 1;

            var center_val: i32 = @as(i32, nlsf[k - 1]) + nlsf[k];
            center_val = (center_val >> 1) + (center_val & 1);
            center_val = @max(min_center, @min(max_center, center_val));
            nlsf[k - 1] = @truncate(center_val - (@as(i32, min_delta[k]) >> 1));
            nlsf[k] = @truncate(@as(i32, nlsf[k - 1]) + @as(i32, min_delta[k]));
        }
    }

    // Fallback: sort (insertion sort; the vector is nearly sorted), then push
    // forwards and backwards to force the spacing.
    var i: usize = 1;
    while (i < order) : (i += 1) {
        const value = nlsf[i];
        var j = i;
        while (j > 0 and nlsf[j - 1] > value) : (j -= 1) nlsf[j] = nlsf[j - 1];
        nlsf[j] = value;
    }
    if (@as(i32, nlsf[0]) < min_delta[0]) nlsf[0] = @truncate(@as(i32, min_delta[0]));
    i = 1;
    while (i < order) : (i += 1) {
        const lower = @as(i32, nlsf[i - 1]) + min_delta[i];
        nlsf[i] = @truncate(@max(@as(i32, nlsf[i]), @min(lower, 32767)));
    }
    if (@as(i32, nlsf[order - 1]) > 32768 - @as(i32, min_delta[order])) {
        nlsf[order - 1] = @truncate(32768 - @as(i32, min_delta[order]));
    }
    i = order - 1;
    while (i > 0) : (i -= 1) {
        if (@as(i32, nlsf[i]) > @as(i32, nlsf[i + 1]) - min_delta[i + 1]) {
            nlsf[i] = @truncate(@as(i32, nlsf[i + 1]) - @as(i32, min_delta[i + 1]));
        }
    }
}

/// `ROUND_MULL(a, b, s)`: multiply in 64 bits, round with one extra bit, shift.
fn roundMulL(a: i32, b: i32, s: u6) i32 {
    const prod: i64 = @as(i64, a) * @as(i64, b);
    // C wraps on overflow here; truncation keeps the same bit pattern.
    return @truncate(((prod >> (s - 1)) + 1) >> 1);
}

/// `MULH(a, b)`: the high 32 bits of the product.
fn mulHigh(a: i32, b: i32) i32 {
    return @intCast((@as(i64, a) * @as(i64, b)) >> 32);
}

/// Is the Q12 LPC filter stable, i.e. is its prediction gain finite? This runs
/// the Levinson recursion on the reflection coefficients and quits early when a
/// coefficient is too large to be representable — RFC 8251 section 6 requires
/// treating that overflow as "unstable" rather than wrapping.
fn isLpcStable(lpc: *const [max_lpc]i16, order: usize) bool {
    var lpc32: [2][max_lpc]i32 = @splat(@splat(0));
    var row: usize = 0;
    var dc_resp: i32 = 0;
    for (0..order) |k| {
        dc_resp += lpc[k];
        lpc32[0][k] = @as(i32, lpc[k]) * 4096;
    }
    if (dc_resp >= 4096) return false;

    var total_inv_gain: i32 = 1 << 30;
    var k: i32 = @intCast(order - 1);
    while (true) : (k -= 1) {
        const kk: usize = @intCast(k);
        if (@abs(@as(i64, lpc32[row][kk])) > 16773022) return false;

        const rc: i32 = 0 -% @as(i32, @bitCast(@as(u32, @bitCast(lpc32[row][kk])) *% 128));
        const gaindiv: i32 = (1 << 30) - mulHigh(rc, rc);
        total_inv_gain = mulHigh(total_inv_gain, gaindiv) << 2;
        if (kk == 0) return total_inv_gain >= 107374;

        // Approximate 1.0/gaindiv in Q(fbits-16), then refine it once.
        const fbits: u6 = @intCast(types.ilog(@intCast(gaindiv)));
        var gain: i32 = @divTrunc((1 << 29) - 1, gaindiv >> @intCast(fbits + 1 - 16));
        // C shifts into the sign bit here; wrapping keeps the same value.

        const scaled: i32 = @bitCast(@as(u32, @bitCast(gaindiv)) << @intCast(15 + 16 - fbits));
        const err: i32 = (1 << 29) - @as(i32, @intCast((@as(i64, scaled) * gain) >> 16));
        gain = gain *% 65536 +% ((err *% gain) >> 13);

        const prev = lpc32[row];
        row ^= 1;
        for (0..kk) |j| {
            const x = satSub32(prev[j], roundMulL(prev[kk - j - 1], rc, 31));
            const tmp: i64 = @as(i64, x) * @as(i64, gain);
            const value = ((tmp >> @intCast(fbits - 1)) + 1) >> 1;
            if (value < std.math.minInt(i32) or value > std.math.maxInt(i32)) return false;
            lpc32[row][j] = @intCast(value);
        }
    }
}

fn satSub32(a: i32, b: i32) i32 {
    const wide = @as(i64, a) - @as(i64, b);
    return @intCast(std.math.clamp(wide, std.math.minInt(i32), std.math.maxInt(i32)));
}

/// Two polynomials from one LSP set, by the recursion
/// `pol[i+1] = 2*pol[i-1] - 2*cos(w)*pol[i]`.
fn lsp2poly(lsp: []const i32, pol: []i32, half_order: usize) void {
    pol[0] = 65536;
    pol[1] = -lsp[0];
    var i: usize = 1;
    while (i < half_order) : (i += 1) {
        pol[i + 1] = pol[i - 1] *% 2 -% roundMulL(lsp[2 * i], pol[i], 16);
        var j = i;
        while (j > 1) : (j -= 1) {
            pol[j] +%= pol[j - 2] -% roundMulL(lsp[2 * i], pol[j - 1], 16);
        }
        pol[1] -%= lsp[2 * i];
    }
}

/// LSFs (Q15) to LPC coefficients (float, unit-gain scale).
fn lsfToLpc(nlsf: []const i16, lpcf: *[max_lpc]f32, order: usize) void {
    var lsp: [max_lpc]i32 = @splat(0);
    for (0..order) |k| {
        const index: usize = @intCast(@as(i32, nlsf[k]) >> 8);
        const offset: i32 = @as(i32, nlsf[k]) & 255;
        const k2: usize = if (order == 10) tables.lsf_ordering_nbmb[k] else tables.lsf_ordering_wb[k];
        var value: i32 = @as(i32, tables.cosine[index]) *% 256;
        value +%= (@as(i32, tables.cosine[index + 1]) -% tables.cosine[index]) *% offset;
        lsp[k2] = (value + 4) >> 3;
    }

    var p: [9]i32 = @splat(0);
    var q: [9]i32 = @splat(0);
    const half = order >> 1;
    lsp2poly(&lsp, &p, half);
    lsp2poly(lsp[1..], &q, half);

    var lpc32: [max_lpc]i32 = @splat(0);
    for (0..half) |k| {
        const p_tmp = p[k + 1] + p[k];
        const q_tmp = q[k + 1] - q[k];
        lpc32[k] = -%q_tmp -% p_tmp;
        lpc32[order - k - 1] = q_tmp -% p_tmp;
    }

    // Bound the coefficients so each fits in Q12.
    var lpc: [max_lpc]i16 = @splat(0);
    var attempt: usize = 0;
    while (attempt < 10) : (attempt += 1) {
        var maxabs: u32 = 0;
        var k: usize = 0;
        for (0..order) |j| {
            const x: u32 = @intCast(@abs(@as(i64, lpc32[j])));
            if (x > maxabs) {
                maxabs = x;
                k = j;
            }
        }
        maxabs = (maxabs + 16) >> 5;
        if (maxabs <= 32767) break;

        maxabs = @min(maxabs, 163838);
        var chirp: u32 = 65470 -
            (((maxabs - 32767) << 14) / ((maxabs * @as(u32, @intCast(k + 1))) >> 2));
        const chirp_base = chirp;
        for (0..order) |m| {
            lpc32[m] = roundMulL(lpc32[m], @intCast(chirp), 16);
            chirp = (chirp_base * chirp + 32768) >> 16;
        }
    }

    if (attempt == 10) {
        // Time's up: clamp, accepting the spec's dropped low bits.
        for (0..order) |k| {
            lpc[k] = types.clipInt16((lpc32[k] +% 16) >> 5);
            lpc32[k] = @as(i32, lpc[k]) *% 32;
        }
    } else {
        for (0..order) |k| lpc[k] = @truncate((lpc32[k] +% 16) >> 5);
    }

    // If the prediction gain is still too high, expand the bandwidth further.
    var i: usize = 1;
    while (i <= 16 and !isLpcStable(&lpc, order)) : (i += 1) {
        const chirp_base: u32 = 65536 - (@as(u32, 1) << @intCast(i));
        var chirp: u32 = chirp_base;
        for (0..order) |k| {
            lpc32[k] = roundMulL(lpc32[k], @intCast(chirp), 16);
            lpc[k] = @truncate((lpc32[k] +% 16) >> 5);
            chirp = (chirp_base * chirp + 32768) >> 16;
        }
    }

    for (0..order) |k| lpcf[k] = @as(f32, @floatFromInt(lpc[k])) / 4096.0;
}
