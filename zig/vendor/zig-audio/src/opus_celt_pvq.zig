//! PVQ: the pyramid vector quantiser that codes each band's spectral shape
//! (RFC 6716 4.3.4.2, 4.3.4.3).
//!
//! A band of `N` bins with `K` pulses is a point on the surface of an L1 ball,
//! and the number of such points is `V(N,K)`. The decoder reads one uniform
//! integer in `[0, V(N,K))` and walks it back into a signed integer vector.
//! Two things make this delicate:
//!
//!   1. `V(N,K)` grows like `N^K`, so for wide high-frequency bands a
//!      codebook would not fit in 32 bits. `V` is therefore computed in `u32`
//!      with *deliberate* modular arithmetic and the encoder is required to
//!      split such bands (`quant_partition` does, recursively). Mixing in a
//!      wider integer here would change the index mapping, not just the range.
//!   2. The index-to-vector walk needs a "previous row" recurrence that runs
//!      *backwards* (`uprev`). Recomputation from scratch gives the same
//!      numbers but costs O(N*K) per bin instead of O(K).
//!
//! After the vector is decoded it is normalised, then rotated by a
//! spread-dependent angle to smear impulsive bands; the encoder applies the
//! same rotation before quantising, so this is a real part of the format and
//! not an optional enhancement.

const std = @import("std");
const tables = @import("opus_celt_tables.zig");
const range = @import("opus_range.zig");

pub const Error = error{Corrupt};

/// Spreading values, in the bitstream's order.
pub const spread_none: u8 = 0;
pub const spread_light: u8 = 1;
pub const spread_normal: u8 = 2;
pub const spread_aggressive: u8 = 3;

/// Pulse-count ladder: `getPulses(i)` maps a cache index to a pulse count so
/// that the codebook sizes stay roughly evenly spaced on a log scale.
pub fn getPulses(i: u32) u32 {
    return if (i < 8) i else (8 + (i & 7)) << @intCast((i >> 3) - 1);
}

/// `u[i] := u[i] + u[i-1] + acc` for i in 1..len, i.e. one row of the
/// `u[i][j] = u[i-1][j] + u[i][j-1] + u[i-1][j-1]` recurrence.
fn unext(u: []u32, len: usize, acc_in: u32) void {
    var acc = acc_in;
    var j: usize = 1;
    while (true) {
        const next = u[j] +% u[j - 1] +% acc;
        u[j - 1] = acc;
        acc = next;
        j += 1;
        if (j >= len) break;
    }
    u[j - 1] = acc;
}

/// The inverse: `u[i-1] := u[i] - u[i-1] - u0`. This is what lets `cwrsi` step
/// back one dimension at a time without rebuilding the table.
fn uprev(u: []u32, len: usize, acc_in: u32) void {
    var acc = acc_in;
    var j: usize = 1;
    while (true) {
        const next = u[j] -% u[j - 1] -% acc;
        u[j - 1] = acc;
        acc = next;
        j += 1;
        if (j >= len) break;
    }
    u[j - 1] = acc;
}

/// Fill `u[0..k+2]` with `U(n, 0..k+1)` and return `V(n, k) = u[k] + u[k+1]`.
pub fn ncwrsUrow(n: usize, k: usize, u: []u32) u32 {
    std.debug.assert(k > 0 and n >= 2);
    const len = k + 2;
    std.debug.assert(u.len >= len);
    u[0] = 0;
    u[1] = 1;
    var i: usize = 2;
    while (i < len) : (i += 1) u[i] = @intCast((i << 1) - 1);
    i = 2;
    while (i < n) : (i += 1) unext(u[1..len], k + 1, 1);
    return u[k] +% u[k + 1];
}

/// Decode the `i`-th combination of `k` pulses over `n` samples, with signs.
/// Returns the squared norm of the vector.
pub fn cwrsi(n: usize, k_in: usize, i_in: u32, y: []i32, u: []u32) u32 {
    std.debug.assert(n > 0);
    var idx = i_in;
    var k = k_in;
    var yy: u32 = 0;
    var j: usize = 0;
    while (true) {
        var p = u[k + 1];
        // `neg` is the sign bit: the reference encodes it as `s = -(i >= p)`
        // and then uses `-yj` by complementing, which is what this does.
        const neg = idx >= p;
        if (neg) idx -= p;
        var yj: i32 = @intCast(k);
        p = u[k];
        while (p > idx) {
            k -= 1;
            p = u[k];
        }
        idx -= p;
        yj -= @intCast(k);
        const val: i32 = if (neg) -yj else yj;
        y[j] = val;
        yy = yy +% @as(u32, @bitCast(val *% val));
        uprev(u[0 .. k + 2], k + 2, 0);
        j += 1;
        if (j >= n) break;
    }
    return yy;
}

/// Decode a PVQ codeword into `y[0..n]`; returns the squared norm.
///
/// `u` must hold at least `k+2` entries.
pub fn decodePulses(y: []i32, n: usize, k: usize, dec: *range.Decoder, u: []u32) u32 {
    std.debug.assert(k > 0 and n > 1);
    const v = ncwrsUrow(n, k, u);
    return cwrsi(n, k, dec.decodeUint(v), y, u);
}

/// Number of bits the reference charges for `pulses` pulses in this band.
pub fn pulses2bits(band: usize, lm: i32, pulses: u32) u32 {
    if (pulses == 0) return 0;
    const base = cacheFor(band, @intCast(lm + 1));
    return @as(u32, base[pulses]) + 1;
}

/// Inverse of `pulses2bits`: the pulse count closest to `bits`, rounding down
/// on a tie.
pub fn bits2pulses(band: usize, lm: i32, bits_in: i32) u32 {
    const base = cacheFor(band, @intCast(lm + 1));
    const hi_max: i32 = base[0];
    var lo: i32 = 0;
    var hi: i32 = hi_max;
    const bits = bits_in - 1;
    var iter: u32 = 0;
    while (iter < 6) : (iter += 1) {
        const mid = (lo + hi + 1) >> 1;
        if (@as(i32, base[@intCast(mid)]) >= bits) hi = mid else lo = mid;
    }
    const lo_bits: i32 = if (lo == 0) -1 else @as(i32, base[@intCast(lo)]);
    if (bits - lo_bits <= @as(i32, base[@intCast(hi)]) - bits) return @intCast(lo);
    return @intCast(hi);
}

fn cacheFor(band: usize, lm1: u5) []const u8 {
    const idx = tables.cache_index[@as(usize, lm1) * tables.bands + band];
    std.debug.assert(idx >= 0);
    return tables.cache_bits[@intCast(idx)..];
}

/// One in-place 2-D rotation sweep across a stride.
fn expRotation1(x: []f32, len: usize, stride: usize, c: f32, s: f32) void {
    const ms = -s;
    var ptr: usize = 0;
    while (ptr + stride < len) : (ptr += 1) {
        const x1 = x[ptr];
        const x2 = x[ptr + stride];
        x[ptr + stride] = c * x2 + s * x1;
        x[ptr] = c * x1 + ms * x2;
    }
    if (len < 2 * stride + 1) return;
    var back = len - 2 * stride - 1;
    while (true) {
        const x1 = x[back];
        const x2 = x[back + stride];
        x[back + stride] = c * x2 + s * x1;
        x[back] = c * x1 + ms * x2;
        if (back == 0) break;
        back -= 1;
    }
}

/// Rotate a decoded (or to-be-quantised) band vector by the spread angle.
///
/// `dir` is +1 before quantisation and -1 after decoding; `stride` is the
/// number of interleaved blocks in the frame.
pub fn expRotation(x: []f32, len_in: usize, dir: i32, stride_in: usize, k: u32, spread: u8) void {
    const spread_factor = [3]u32{ 15, 10, 5 };
    var len = len_in;
    if (2 * k >= len or spread == spread_none) return;
    const factor: f32 = @floatFromInt(spread_factor[spread - 1]);
    const kf: f32 = @floatFromInt(k);
    const gain = @as(f32, @floatFromInt(len)) / (@as(f32, @floatFromInt(len)) + factor * kf);
    const theta = 0.5 * gain * gain;
    // cos_norm(t) == cos(pi/2 * t), which is sin for the complementary angle.
    const c = cosNorm(theta);
    const s = cosNorm(1.0 - theta);

    var stride2: usize = 0;
    if (len >= 8 * stride_in) {
        stride2 = 1;
        while ((stride2 * stride2 + stride2) * stride_in + (stride_in >> 2) < len) stride2 += 1;
    }
    len = len / stride_in;
    var i: usize = 0;
    while (i < stride_in) : (i += 1) {
        const base = x[i * len ..];
        if (dir < 0) {
            if (stride2 != 0) expRotation1(base, len, stride2, s, c);
            expRotation1(base, len, 1, c, s);
        } else {
            expRotation1(base, len, 1, c, -s);
            if (stride2 != 0) expRotation1(base, len, stride2, s, -c);
        }
    }
}

fn cosNorm(t: f32) f32 {
    return @floatCast(@cos(@as(f64, std.math.pi) * 0.5 * @as(f64, t)));
}

/// Scale the integer pulse vector to unit norm times `gain`.
pub fn normaliseResidual(iy: []const i32, x: []f32, n: usize, ryy: u32, gain: f32) void {
    const r: f32 = @floatFromInt(ryy);
    const g = gain / @sqrt(r);
    var i: usize = 0;
    while (i < n) : (i += 1) x[i] = g * @as(f32, @floatFromInt(iy[i]));
}

/// Renormalise an arbitrary vector to unit norm times `gain`.
pub fn renormaliseVector(x: []f32, n: usize, gain: f32) void {
    var e: f32 = 1e-15;
    var i: usize = 0;
    while (i < n) : (i += 1) e += x[i] * x[i];
    const g = gain / @sqrt(e);
    i = 0;
    while (i < n) : (i += 1) x[i] *= g;
}

/// One bit per interleaved block, set when that block got any pulse at all.
/// Anti-collapse uses this to find blocks that collapsed to silence.
pub fn extractCollapseMask(iy: []const i32, n: usize, b: usize) u32 {
    if (b <= 1) return 1;
    const n0 = n / b;
    var mask: u32 = 0;
    var i: usize = 0;
    while (i < b) : (i += 1) {
        var tmp: i32 = 0;
        var j: usize = 0;
        while (j < n0) : (j += 1) tmp |= iy[i * n0 + j];
        mask |= @as(u32, @intFromBool(tmp != 0)) << @intCast(i);
    }
    return mask;
}

/// Full band decode: read the codeword, normalise it, de-rotate it, and report
/// which time blocks were non-zero.
pub fn algUnquant(
    x: []f32,
    n: usize,
    k: usize,
    spread: u8,
    b: usize,
    dec: *range.Decoder,
    gain: f32,
    iy: []i32,
    u: []u32,
) u32 {
    const ryy = decodePulses(iy[0..n], n, k, dec, u);
    normaliseResidual(iy[0..n], x, n, ryy, gain);
    expRotation(x, n, -1, b, @intCast(k), spread);
    return extractCollapseMask(iy[0..n], n, b);
}

test "V(N,K) matches the small hand-computed cases" {
    var u: [16]u32 = undefined;
    // V(N,K) counts signed integer vectors of length N with L1 norm K.
    // V(2,1)=4, V(2,2)=8, V(3,1)=6, V(3,2)=18, V(3,3)=38, V(4,2)=32
    try std.testing.expectEqual(@as(u32, 4), ncwrsUrow(2, 1, &u));
    try std.testing.expectEqual(@as(u32, 8), ncwrsUrow(2, 2, &u));
    try std.testing.expectEqual(@as(u32, 6), ncwrsUrow(3, 1, &u));
    try std.testing.expectEqual(@as(u32, 18), ncwrsUrow(3, 2, &u));
    try std.testing.expectEqual(@as(u32, 38), ncwrsUrow(3, 3, &u));
    try std.testing.expectEqual(@as(u32, 32), ncwrsUrow(4, 2, &u));
}

test "cwrsi enumerates every vector exactly once" {
    var u: [16]u32 = undefined;
    const n: usize = 3;
    const k: usize = 2;
    const v = ncwrsUrow(n, k, &u);
    try std.testing.expectEqual(@as(u32, 18), v);
    var seen = std.AutoHashMapUnmanaged(u64, void){};
    defer seen.deinit(std.testing.allocator);
    var idx: u32 = 0;
    while (idx < v) : (idx += 1) {
        var y: [3]i32 = undefined;
        var uu: [16]u32 = undefined;
        _ = ncwrsUrow(n, k, &uu);
        const yy = cwrsi(n, k, idx, &y, &uu);
        var sum: i32 = 0;
        var norm: i32 = 0;
        for (y) |val| {
            sum += @intCast(@abs(val));
            norm += val * val;
        }
        try std.testing.expectEqual(@as(i32, 2), sum);
        try std.testing.expectEqual(norm, @as(i32, @intCast(yy)));
        var key: u64 = 0;
        for (y) |val| key = key *% 31 +% @as(u64, @bitCast(@as(i64, val)));
        try std.testing.expect(!seen.contains(key));
        try seen.put(std.testing.allocator, key, {});
    }
}

test "getPulses ladder is the identity below nine and then grows by octaves" {
    for (0..9) |i| try std.testing.expectEqual(@as(u32, @intCast(i)), getPulses(@intCast(i)));
    // Above 8 the low three bits pick an offset and the rest a power of two.
    try std.testing.expectEqual(@as(u32, 9), getPulses(9));
    try std.testing.expectEqual(@as(u32, 15), getPulses(15));
    try std.testing.expectEqual(@as(u32, 16), getPulses(16));
    try std.testing.expectEqual(@as(u32, 18), getPulses(17));
    try std.testing.expectEqual(@as(u32, 32), getPulses(24));
    try std.testing.expectEqual(@as(u32, 64), getPulses(32));
}

test "pulses2bits is monotone and bits2pulses lands on an achievable cost" {
    for (0..4) |lm| {
        for (0..tables.bands) |band| {
            if (tables.cache_index[(lm + 1) * tables.bands + band] < 0) continue;
            const max_pulses = cacheFor(band, @intCast(lm + 1))[0];
            var prev: u32 = 0;
            var prev_back: u32 = 0;
            var p: u32 = 1;
            while (p <= max_pulses) : (p += 1) {
                const cost = pulses2bits(band, @intCast(lm), p);
                try std.testing.expect(cost >= prev);
                prev = cost;
                // Consecutive ladder entries can share a cost, so the inverse
                // is only guaranteed to land on a pulse count of equal cost.
                const back = bits2pulses(band, @intCast(lm), @intCast(cost));
                try std.testing.expectEqual(cost, pulses2bits(band, @intCast(lm), back));
                try std.testing.expect(back >= prev_back);
                prev_back = back;
            }
        }
    }
}

test "spread rotation preserves the L2 norm" {
    var x = [_]f32{ 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 };
    var before: f32 = 0;
    for (x) |v| before += v * v;
    expRotation(&x, x.len, -1, 1, 1, spread_aggressive);
    var after: f32 = 0;
    for (x) |v| after += v * v;
    try std.testing.expectApproxEqAbs(before, after, 1e-5);
}

test "spread none leaves the vector alone" {
    var x = [_]f32{ 0.6, -0.8, 0.0, 0.0 };
    const copy = x;
    expRotation(&x, x.len, -1, 1, 1, spread_none);
    for (copy, x) |a, b| try std.testing.expectEqual(a, b);
}

test "renormalise gives unit norm" {
    var x = [_]f32{ 3.0, 4.0, 0.0, 0.0 };
    renormaliseVector(&x, 4, 1.0);
    var e: f32 = 0;
    for (x) |v| e += v * v;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), e, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), x[0], 1e-6);
}

test "collapse mask reports per-block activity" {
    const iy = [_]i32{ 1, 0, 0, 0, 0, 2, 0, 0 };
    // Two blocks of four: block 0 has a pulse, block 1 has a pulse.
    try std.testing.expectEqual(@as(u32, 0b11), extractCollapseMask(&iy, 8, 2));
    const iy2 = [_]i32{ 1, 0, 0, 0, 0, 0, 0, 0 };
    try std.testing.expectEqual(@as(u32, 0b01), extractCollapseMask(&iy2, 8, 2));
    try std.testing.expectEqual(@as(u32, 1), extractCollapseMask(&iy2, 8, 1));
}
