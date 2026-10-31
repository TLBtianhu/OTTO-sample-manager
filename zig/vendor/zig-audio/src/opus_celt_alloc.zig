//! CELT bit allocation (RFC 6716 4.3.3).
//!
//! The number of bits each band gets for its shape is *not* signalled. It is
//! derived from the frame size, the channel count, the static Table 57, and
//! four decoded knobs (band boosts, allocation trim, band skipping, and the
//! stereo flags), all of which have to be reproduced bit-exactly because the
//! allocation decides how many symbols are read from every band afterwards.
//!
//! The structure, in the order the standard describes it:
//!
//!   1. reserve bits for anti-collapse, the skip flag, intensity stereo and
//!      dual stereo;
//!   2. per-band hard minimum `thresh[]` and tilt `trim_offset[]`;
//!   3. bisect the quality index to find the largest static allocation that
//!      fits, then bisect again between the two neighbouring rows (64 steps);
//!   4. walk bands from the top, decoding a "do not skip" bit whenever the band
//!      has enough bits to justify coding it;
//!   5. hand the leftover bits to the low bands, then split each band's bits
//!      between fine energy and PVQ.
//!
//! Two things bite here. `bits2pulses` is *not* a logarithm: it searches a
//! precomputed ladder and rounds down on an exact tie, and the rounding of the
//! fine-energy count uses `+ den/2` before dividing. Both change `tell` by a
//! fraction of a bit, which changes the next band's budget, which changes every
//! subsequent symbol.

const std = @import("std");
const tables = @import("opus_celt_tables.zig");
const pvq = @import("opus_celt_pvq.zig");
const range = @import("opus_range.zig");

pub const Error = error{Corrupt};

/// 1/8 bit resolution, matching `range.bitres`.
const bitres: u5 = 3;
/// Frequency offset of the fine-energy split, in 1/8 bit per degree of freedom.
const fine_offset: i32 = 21;
const max_fine_bits: i32 = 8;
/// Offset of the PVQ angle quantiser, in 1/8 bit.
pub const qtheta_offset: i32 = 4;
pub const qtheta_offset_twophase: i32 = 16;
/// Allocation granularity for the second bisection.
const alloc_steps: u5 = 6;

/// Scratch space for one allocation pass.
pub const Scratch = struct {
    bits1: [tables.bands]i32 = undefined,
    bits2: [tables.bands]i32 = undefined,
    thresh: [tables.bands]i32 = undefined,
    trim_offset: [tables.bands]i32 = undefined,
};

/// Per-band maximum useful allocation in 1/8 bits, from the mode's cache.
pub fn initCaps(cap: *[tables.bands]i32, lm: u3, channels: usize) void {
    for (0..tables.bands) |i| {
        const n: i32 = @as(i32, tables.freq_range[i]) << lm;
        const idx = tables.bands * (2 * @as(usize, lm) + channels - 1) + i;
        cap[i] = (@as(i32, tables.cache_caps[idx]) + 64) *
            @as(i32, @intCast(channels)) * n >> 2;
    }
}

/// One bit in 1/8 units.
fn bit8() i32 {
    return @as(i32, 1) << bitres;
}

pub const Result = struct {
    /// Highest band index with shape bits plus one; bands at or above it were
    /// skipped and spend their bits on fine energy only.
    coded_bands: usize,
    intensity: i32,
    dual_stereo: bool,
    balance: i32,
};

/// Compute the per-band shape (`pulses`) and fine-energy (`ebits`) allocation.
pub fn computeAllocation(
    start: usize,
    end: usize,
    offsets: []const i32,
    cap: []const i32,
    alloc_trim: i32,
    total_in: i32,
    pulses: []i32,
    ebits: []i32,
    fine_priority: []i32,
    channels: usize,
    lm: u3,
    dec: *range.Decoder,
    scratch: *Scratch,
) Result {
    var total: i32 = total_in;
    if (total < 0) total = 0;
    var skip_start = start;
    // Reserve one bit to signal the end of manually skipped bands.
    const skip_rsv: i32 = if (total >= bit8()) bit8() else 0;
    total -= skip_rsv;

    var intensity_rsv: i32 = 0;
    var dual_stereo_rsv: i32 = 0;
    if (channels == 2) {
        intensity_rsv = @intCast(tables.log2_frac[end - start]);
        if (intensity_rsv > total) {
            intensity_rsv = 0;
        } else {
            total -= intensity_rsv;
            dual_stereo_rsv = if (total >= bit8()) bit8() else 0;
            total -= dual_stereo_rsv;
        }
    }

    const c_i: i32 = @intCast(channels);
    const lm_i: i32 = lm;
    const s = scratch;
    for (start..end) |j| {
        const width: i32 = tables.freq_range[j];
        // Below this a band is not worth coding at all: one bit per channel,
        // or 48/128 bit per MDCT bin, whichever is larger.
        s.thresh[j] = @max(c_i << bitres, (3 * width << lm << bitres) >> 4);
        s.trim_offset[j] = c_i * width * (alloc_trim - 5 - lm_i) *
            @as(i32, @intCast(end - j - 1)) * (@as(i32, 1) << (lm + bitres)) >> 6;
        // A one-bin band benefits from the coarse energy value it already has,
        // so it is worth one bit less.
        if (width << lm == 1) s.trim_offset[j] -= c_i << bitres;
    }

    // Bisect the quality index over the static table.
    var lo: i32 = 1;
    var hi: i32 = tables.alloc_vectors - 1;
    while (lo <= hi) {
        var done = false;
        var psum: i32 = 0;
        const mid = @divTrunc(lo + hi, 2);
        var j = end;
        while (j > start) {
            j -= 1;
            const width: i32 = tables.freq_range[j];
            var bitsj = c_i * width * @as(i32, tables.static_alloc[@intCast(mid)][j]) << lm >> 2;
            if (bitsj > 0) bitsj = @max(0, bitsj + s.trim_offset[j]);
            bitsj += offsets[j];
            if (bitsj >= s.thresh[j] or done) {
                done = true;
                psum += @min(bitsj, cap[j]);
            } else if (bitsj >= c_i << bitres) {
                psum += c_i << bitres;
            }
        }
        if (psum > total) hi = mid - 1 else lo = mid + 1;
    }
    hi = lo;
    lo -= 1;

    // Interpolate between the two neighbouring rows.
    for (start..end) |j| {
        const width: i32 = tables.freq_range[j];
        var bits1j = c_i * width * @as(i32, tables.static_alloc[@intCast(lo)][j]) << lm >> 2;
        var bits2j = if (hi >= tables.alloc_vectors)
            cap[j]
        else
            c_i * width * @as(i32, tables.static_alloc[@intCast(hi)][j]) << lm >> 2;
        if (bits1j > 0) bits1j = @max(0, bits1j + s.trim_offset[j]);
        if (bits2j > 0) bits2j = @max(0, bits2j + s.trim_offset[j]);
        if (lo > 0) bits1j += offsets[j];
        bits2j += offsets[j];
        if (offsets[j] > 0) skip_start = j;
        s.bits2[j] = @max(0, bits2j - bits1j);
        s.bits1[j] = bits1j;
    }

    return interpBits2Pulses(
        start,
        end,
        skip_start,
        cap,
        total,
        skip_rsv,
        intensity_rsv,
        dual_stereo_rsv,
        pulses,
        ebits,
        fine_priority,
        channels,
        lm,
        dec,
        scratch,
    );
}

fn interpBits2Pulses(
    start: usize,
    end: usize,
    skip_start: usize,
    cap: []const i32,
    total_in: i32,
    skip_rsv: i32,
    intensity_rsv_in: i32,
    dual_stereo_rsv: i32,
    pulses: []i32,
    ebits: []i32,
    fine_priority: []i32,
    channels: usize,
    lm: u3,
    dec: *range.Decoder,
    scratch: *Scratch,
) Result {
    const s = scratch;
    var total = total_in;
    const c_i: i32 = @intCast(channels);
    const stereo: u5 = if (channels > 1) 1 else 0;
    const alloc_floor: i32 = c_i << bitres;
    const log_m: i32 = @as(i32, lm) << bitres;

    // Bisect the fractional position between bits1 and bits2.
    var lo: i32 = 0;
    var hi: i32 = @as(i32, 1) << alloc_steps;
    for (0..alloc_steps) |_| {
        const mid = @divTrunc(lo + hi, 2);
        var psum: i32 = 0;
        var done = false;
        var j = end;
        while (j > start) {
            j -= 1;
            const tmp = s.bits1[j] + (mid * s.bits2[j] >> alloc_steps);
            if (tmp >= s.thresh[j] or done) {
                done = true;
                psum += @min(tmp, cap[j]);
            } else if (tmp >= alloc_floor) {
                psum += alloc_floor;
            }
        }
        if (psum > total) hi = mid else lo = mid;
    }
    var psum: i32 = 0;
    var done = false;
    var j = end;
    while (j > start) {
        j -= 1;
        var tmp = s.bits1[j] + (lo * s.bits2[j] >> alloc_steps);
        if (tmp < s.thresh[j] and !done) {
            tmp = if (tmp >= alloc_floor) alloc_floor else 0;
        } else {
            done = true;
        }
        tmp = @min(tmp, cap[j]);
        pulses[j] = tmp;
        psum += tmp;
    }

    // Walk bands from the top, coding a skip decision where it can pay off.
    var coded_bands = end;
    var intensity_rsv = intensity_rsv_in;
    while (true) {
        j = coded_bands - 1;
        // Never skip the first band, nor a boosted one: in the first case the
        // skip bit would cost as much as it saves.
        if (j <= skip_start) {
            total += skip_rsv;
            break;
        }
        var left = total - psum;
        const span: i32 = @as(i32, tables.e_bands[coded_bands]) - tables.e_bands[start];
        const percoeff = @divTrunc(left, span);
        left -= span * percoeff;
        const rem: i32 = @max(left - (@as(i32, tables.e_bands[j]) - tables.e_bands[start]), 0);
        const band_width: i32 = @as(i32, tables.e_bands[coded_bands]) - tables.e_bands[j];
        var band_bits = pulses[j] + percoeff * band_width + rem;
        if (band_bits >= @max(s.thresh[j], alloc_floor + bit8())) {
            if (dec.decodeBitLogp(1) == 1) break;
            psum += bit8();
            band_bits -= bit8();
        }
        // Reclaim what the band had, and re-reserve the smaller intensity code.
        psum -= pulses[j] + intensity_rsv;
        if (intensity_rsv > 0) intensity_rsv = @intCast(tables.log2_frac[j - start]);
        psum += intensity_rsv;
        if (band_bits >= alloc_floor) {
            psum += alloc_floor;
            pulses[j] = alloc_floor;
        } else {
            pulses[j] = 0;
        }
        coded_bands -= 1;
    }
    std.debug.assert(coded_bands > start);

    var intensity: i32 = 0;
    var dual_stereo = false;
    if (intensity_rsv > 0) {
        intensity = @as(i32, @intCast(start)) +
            @as(i32, @intCast(dec.decodeUint(@intCast(coded_bands + 1 - start))));
    }
    if (intensity <= @as(i32, @intCast(start))) {
        total += dual_stereo_rsv;
    } else if (dual_stereo_rsv > 0) {
        dual_stereo = dec.decodeBitLogp(1) == 1;
    }

    // Hand the remaining bits to the low bands, one pass for equal shares and
    // one for the remainder.
    var left = total - psum;
    const span: i32 = @as(i32, tables.e_bands[coded_bands]) - tables.e_bands[start];
    const percoeff = @divTrunc(left, span);
    left -= span * percoeff;
    for (start..coded_bands) |band| {
        pulses[band] += percoeff * tables.freq_range[band];
    }
    for (start..coded_bands) |band| {
        const tmp = @min(left, @as(i32, tables.freq_range[band]));
        pulses[band] += tmp;
        left -= tmp;
    }

    var balance: i32 = 0;
    for (start..coded_bands) |band| {
        const n0: i32 = tables.freq_range[band];
        const n = n0 << lm;
        const bit = pulses[band] + balance;
        var excess: i32 = 0;
        if (n > 1) {
            excess = @max(bit - cap[band], 0);
            pulses[band] = bit - excess;

            // Intensity stereo adds one more degree of freedom.
            var den = c_i * n;
            if (channels == 2 and n > 2 and !dual_stereo and
                @as(i32, @intCast(band)) < intensity)
            {
                den += 1;
            }
            const nc_log_n = den * (@as(i32, tables.log_n[band]) + log_m);
            var offset = (nc_log_n >> 1) - den * fine_offset;
            // N == 2 is the one point that does not fit the curve.
            if (n == 2) offset += den << bitres >> 2;
            // Bias the second and third fine bit.
            if (pulses[band] + offset < den * 2 << bitres) {
                offset += nc_log_n >> 2;
            } else if (pulses[band] + offset < den * 3 << bitres) {
                offset += nc_log_n >> 3;
            }
            var e: i32 = @max(0, pulses[band] + offset + (den << (bitres - 1)));
            e = @divTrunc(e, den) >> bitres;
            // Never take more fine bits than the band has bits at all.
            if (c_i * e > pulses[band] >> bitres) e = pulses[band] >> stereo >> bitres;
            e = @min(e, max_fine_bits);
            fine_priority[band] = @intFromBool(e * (den << bitres) >= pulses[band] + offset);
            ebits[band] = e;
            pulses[band] -= c_i * e << bitres;
        } else {
            // A one-bin band spends everything on fine energy but one sign bit.
            excess = @max(0, bit - (c_i << bitres));
            pulses[band] = bit - excess;
            ebits[band] = 0;
            fine_priority[band] = 1;
        }
        // Fine energy cannot benefit from the rebalancing in `quantAllBands`,
        // so any overflow over the cap is spent here instead.
        if (excess > 0) {
            var extra_fine: i32 = @min(excess >> (stereo + bitres), max_fine_bits - ebits[band]);
            if (extra_fine < 0) extra_fine = 0;
            ebits[band] += extra_fine;
            const extra_bits = extra_fine * c_i << bitres;
            fine_priority[band] = @intFromBool(extra_bits >= excess - balance);
            excess -= extra_bits;
        }
        balance = excess;
    }

    // The skipped bands spend everything on fine energy.
    var band = coded_bands;
    while (band < end) : (band += 1) {
        ebits[band] = pulses[band] >> stereo >> bitres;
        pulses[band] = 0;
        fine_priority[band] = @intFromBool(ebits[band] < 1);
    }

    return .{
        .coded_bands = coded_bands,
        .intensity = intensity,
        .dual_stereo = dual_stereo,
        .balance = balance,
    };
}

test "caps grow with channels and frame size" {
    var mono: [tables.bands]i32 = undefined;
    var st: [tables.bands]i32 = undefined;
    initCaps(&mono, 3, 1);
    initCaps(&st, 3, 2);
    for (0..tables.bands) |i| {
        try std.testing.expect(mono[i] > 0);
        try std.testing.expect(st[i] >= mono[i]);
    }
}

test "allocation never exceeds the frame's bits" {
    const bytes: [300]u8 = @splat(0x5A);
    var dec = range.Decoder.init(&bytes);
    var scratch = Scratch{};
    var cap: [tables.bands]i32 = undefined;
    var offsets: [tables.bands]i32 = @splat(0);
    var pulses: [tables.bands]i32 = @splat(0);
    var ebits: [tables.bands]i32 = @splat(0);
    var prio: [tables.bands]i32 = @splat(0);
    initCaps(&cap, 3, 2);
    const total: i32 = 300 * 8 * 8 - @as(i32, @intCast(dec.tellFrac())) - 1;
    const r = computeAllocation(0, tables.bands, &offsets, &cap, 5, total, &pulses, &ebits, &prio, 2, 3, &dec, &scratch);
    try std.testing.expect(r.coded_bands >= 1 and r.coded_bands <= tables.bands);
    var sum: i64 = 0;
    for (0..tables.bands) |i| {
        sum += pulses[i] + @as(i64, channelsBits(2, ebits[i]));
        try std.testing.expect(pulses[i] >= 0);
        try std.testing.expect(ebits[i] >= 0 and ebits[i] <= 8);
    }
    try std.testing.expect(sum <= @as(i64, total) + 8 * tables.bands);
}

fn channelsBits(channels: usize, ebits: i32) i32 {
    return ebits * @as(i32, @intCast(channels)) << bitres;
}
