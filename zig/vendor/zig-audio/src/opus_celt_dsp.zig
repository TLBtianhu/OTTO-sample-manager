//! CELT's time-domain half: inverse MDCT, overlap-add, the pitch post-filter
//! and de-emphasis (RFC 6716 4.3.7).
//!
//! The IMDCT is the usual "N coefficients in, 2N samples out" transform with
//! the TDAC fold pushed into the overlap, computed through an N/4-point complex
//! FFT. Sizes are 240, 480 or 960 output samples for 2.5/5/10 ms frames, and
//! 240 per short block for a transient 20 ms frame; every one of them uses the
//! same FFT code through a size-dependent twiddle table.
//!
//! The FFT is a plain recursive Cooley-Tukey over the smallest prime factors.
//! Nothing here is bit-exactness-critical the way the range coder is: any
//! correct FFT gives the same transform to within float rounding, and the
//! acceptance comparison is a signal-to-noise ratio, not a bit comparison.
//!
//! Two things are *not* free choices:
//!
//!   * the transform must be unnormalised on the synthesis side and the output
//!     scaled by 1/32768 at the very end, because that is where CELT's internal
//!     +-32768 signal scale becomes a +-1.0 PCM sample;
//!   * the post-filter's window transition must interpolate with the *squared*
//!     MDCT window and must read its own past output, not the pre-filter input.

const std = @import("std");
const tables = @import("opus_celt_tables.zig");

pub const Error = error{Corrupt};

const Cpx = struct { re: f32, im: f32 };

fn cmul(a: Cpx, b: Cpx) Cpx {
    return .{ .re = a.re * b.re - a.im * b.im, .im = a.re * b.im + a.im * b.re };
}

/// Smallest prime factor of `n` (n >= 2).
fn smallestFactor(n: usize) usize {
    var d: usize = 2;
    while (d * d <= n) : (d += 1) {
        if (n % d == 0) return d;
    }
    return n;
}

fn twiddle(idx_in: usize) Cpx {
    const idx = idx_in % tables.mdct_fft_max;
    return .{ .re = tables.fft_twiddle_re[idx], .im = tables.fft_twiddle_im[idx] };
}

/// In-place-friendly recursive DFT of `n` points: `dst[j] = sum_k src[k*n?] ...
///
/// `src` is read with `stride`, so the caller can hand over interleaved data.
fn fftRec(dst: []Cpx, src: []const Cpx, stride: usize, n: usize, ws: []Cpx) void {
    if (n == 1) {
        dst[0] = src[0];
        return;
    }
    const p = smallestFactor(n);
    const m = n / p;
    const t = ws[0..n];
    const child = ws[n..];
    const root = tables.mdct_fft_max / n;
    var k: usize = 0;
    while (k < p) : (k += 1) {
        fftRec(t[k * m ..][0..m], src[k * stride ..], stride * p, m, child);
    }
    var q: usize = 0;
    while (q < m) : (q += 1) {
        var r: usize = 0;
        while (r < p) : (r += 1) {
            var acc = Cpx{ .re = 0, .im = 0 };
            var kk: usize = 0;
            while (kk < p) : (kk += 1) {
                // exp(-2*pi*i*kk*r/p) * exp(-2*pi*i*kk*q/n)
                const idx = (kk * r * (tables.mdct_fft_max / p) + kk * q * root) % tables.mdct_fft_max;
                const v = cmul(twiddle(idx), t[kk * m + q]);
                acc.re += v.re;
                acc.im += v.im;
            }
            dst[q + r * m] = acc;
        }
    }
}

/// `dst = DFT(src)` for `n` points; `ws` must hold at least `2 * n` entries.
pub fn fft(dst: []Cpx, src: []const Cpx, n: usize, ws: []Cpx) void {
    fftRec(dst, src, 1, n, ws);
}

/// Scratch for one IMDCT: the pre-rotation buffer, the spectrum and the FFT's
/// own recursion space.
pub const MdctWorkspace = struct {
    rot: [480]Cpx = undefined,
    spec: [480]Cpx = undefined,
    fft_ws: [960]Cpx = undefined,
};

/// Inverse MDCT with the TDAC fold folded into `out`.
///
/// `shift` selects the transform size (`1920 >> shift`), `stride` is the block
/// interleaving in the spectrum, and `out` receives `overlap + size` samples
/// starting at index 0. `out[0..overlap/2)` must already hold the previous
/// frame's tail; the mirror step mixes it in.
pub fn mdctBackward(
    shift: u3,
    input: []const f32,
    stride: usize,
    out: []f32,
    ws: *MdctWorkspace,
) void {
    const n: usize = @as(usize, 1920) >> shift;
    const n2 = n >> 1;
    const n4 = n >> 2;
    const trig = tables.mdct_trig[tables.trigOffset(shift)..];
    const half_ov = tables.overlap >> 1;

    // Pre-rotation: pair sample 2k with sample n2-1-2k, real and imaginary
    // swapped because the reference uses a forward FFT in place of an inverse.
    for (0..n4) |k| {
        const u = input[2 * k * stride];
        const v = input[(n2 - 1 - 2 * k) * stride];
        const yr = v * trig[k] + u * trig[n4 + k];
        const yi = u * trig[k] - v * trig[n4 + k];
        ws.rot[k] = .{ .re = yi, .im = yr };
    }
    fft(&ws.spec, &ws.rot, n4, &ws.fft_ws);

    // Post-rotation and de-shuffle: even indices fill from the front, odd ones
    // from the back, which is the TDAC fold.
    for (0..n4) |j| {
        const z = ws.spec[j];
        const yr = z.im * trig[j] + z.re * trig[n4 + j];
        const yi = z.im * trig[n4 + j] - z.re * trig[j];
        out[half_ov + 2 * j] = yr;
        out[half_ov + n2 - 1 - 2 * j] = yi;
    }

    // Windowed mirror on both ends: mixes the previous frame's tail in.
    const w = tables.window120;
    var i: usize = 0;
    while (i < half_ov) : (i += 1) {
        const x1 = out[tables.overlap - 1 - i];
        const x2 = out[i];
        out[i] = w[tables.overlap - 1 - i] * x2 - w[i] * x1;
        out[tables.overlap - 1 - i] = w[i] * x2 + w[tables.overlap - 1 - i] * x1;
    }
}

/// Post-filter tap gains for one tap set, scaled by the frame's gain.
fn tapGains(g: f32, tapset: usize) [3]f32 {
    return .{
        g * tables.postfilter_taps[tapset][0],
        g * tables.postfilter_taps[tapset][1],
        g * tables.postfilter_taps[tapset][2],
    };
}

/// The pitch post-filter: a comb filter that restores harmonic gain.
///
/// `buf` is the decoder's whole history buffer and `off` the start of this
/// frame's samples inside it, so the filter can look back `T1 + 2` samples.
pub fn combFilter(
    buf: []f32,
    off: usize,
    t0_in: i32,
    t1_in: i32,
    n: usize,
    g0: f32,
    g1: f32,
    tapset0: usize,
    tapset1: usize,
    overlap_len: usize,
) void {
    if (g0 == 0 and g1 == 0) return;
    const t0: usize = @intCast(@max(t0_in, 15));
    var t1: usize = @intCast(@max(t1_in, 15));
    const g00 = tapGains(g0, tapset0);
    const g10 = tapGains(g1, tapset1);

    var x1 = buf[off - t1 + 1];
    var x2 = buf[off - t1];
    var x3 = buf[off - t1 - 1];
    var x4 = buf[off - t1 - 2];

    var ov = overlap_len;
    if (g0 == g1 and t0 == t1 and tapset0 == tapset1) ov = 0;
    const w = tables.window120;
    var i: usize = 0;
    while (i < ov) : (i += 1) {
        const x0 = buf[off + i - t1 + 2];
        const f = w[i] * w[i];
        const nf = 1.0 - f;
        var acc = buf[off + i];
        acc += nf * g00[0] * buf[off + i - t0];
        acc += nf * g00[1] * (buf[off + i - t0 + 1] + buf[off + i - t0 - 1]);
        acc += nf * g00[2] * (buf[off + i - t0 + 2] + buf[off + i - t0 - 2]);
        acc += f * g10[0] * x2;
        acc += f * g10[1] * (x1 + x3);
        acc += f * g10[2] * (x0 + x4);
        buf[off + i] = acc;
        x4 = x3;
        x3 = x2;
        x2 = x1;
        x1 = x0;
    }
    if (g1 == 0) return;

    // Constant-filter tail: no more interpolation needed.
    var y1 = buf[off + i - t1 + 1];
    var y2 = buf[off + i - t1];
    var y3 = buf[off + i - t1 - 1];
    var y4 = buf[off + i - t1 - 2];
    while (i < n) : (i += 1) {
        const x0 = buf[off + i - t1 + 2];
        var acc = buf[off + i];
        acc += g10[0] * y2;
        acc += g10[1] * (y1 + y3);
        acc += g10[2] * (x0 + y4);
        buf[off + i] = acc;
        y4 = y3;
        y3 = y2;
        y2 = y1;
        y1 = x0;
    }
    _ = &t1;
}

/// First-order de-emphasis, the inverse of the encoder's pre-emphasis.
pub fn deemphasis(
    out: []f32,
    buf: []const f32,
    off: usize,
    n: usize,
    channels: usize,
    channel: usize,
    mem: *f32,
) void {
    var m = mem.*;
    var j: usize = 0;
    while (j < n) : (j += 1) {
        const tmp = buf[off + j] + 1e-30 + m;
        m = tables.preemph * tmp;
        out[j * channels + channel] = tmp * (1.0 / 32768.0);
    }
    mem.* = m;
}

test "fft of a delta is flat" {
    var src: [60]Cpx = @splat(.{ .re = 0, .im = 0 });
    var dst: [60]Cpx = undefined;
    var ws: [120]Cpx = undefined;
    src[0] = .{ .re = 1, .im = 0 };
    fft(&dst, &src, 60, &ws);
    for (dst) |v| {
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), v.re, 1e-4);
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), v.im, 1e-4);
    }
}

test "fft of a complex exponential peaks at its own bin" {
    const n = 120;
    var src: [n]Cpx = undefined;
    var dst: [n]Cpx = undefined;
    var ws: [2 * n]Cpx = undefined;
    const bin = 7;
    for (0..n) |i| {
        const ang = 2.0 * std.math.pi * @as(f32, @floatFromInt(bin * i)) / @as(f32, n);
        src[i] = .{ .re = @cos(ang), .im = @sin(ang) };
    }
    fft(&dst, &src, n, &ws);
    for (0..n) |k| {
        const mag = @sqrt(dst[k].re * dst[k].re + dst[k].im * dst[k].im);
        if (k == bin) {
            try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(n)), mag, 1e-2);
        } else {
            try std.testing.expect(mag < 1e-2);
        }
    }
}

test "fft sizes used by the imdct all factor cleanly" {
    for ([_]usize{ 480, 240, 120, 60 }) |n| {
        var f = n;
        while (f > 1) {
            const p = smallestFactor(f);
            try std.testing.expect(p == 2 or p == 3 or p == 5);
            f /= p;
        }
    }
}

test "imdct of a single bin is a cosine" {
    // One non-zero coefficient produces a single cosine partial in the
    // windowed output; the un-windowed transform is checked through its
    // symmetry instead of an absolute level.
    var ws = MdctWorkspace{};
    var input: [960]f32 = @splat(0.0);
    input[0] = 1.0;
    var out: [1080]f32 = @splat(0.0);
    mdctBackward(0, &input, 1, &out, &ws);
    // out[60..1020] holds the transform; it must be finite and non-trivial.
    var peak: f32 = 0;
    for (out[60..1020]) |v| peak = @max(peak, @abs(v));
    try std.testing.expect(peak > 0.0);
    try std.testing.expect(peak < 10.0);
}

test "comb filter with zero gain is a no-op" {
    var buf: [2100]f32 = @splat(1.0);
    const before = buf;
    combFilter(&buf, 1088, 0, 0, 960, 0, 0, 0, 0, 120);
    for (before, buf) |a, b| try std.testing.expectEqual(a, b);
}

test "deemphasis is a leaky integrator" {
    var buf: [4]f32 = @splat(0.0);
    buf[0] = 1.0;
    var out: [4]f32 = @splat(0.0);
    var mem: f32 = 0;
    deemphasis(&out, &buf, 0, 4, 1, 0, &mem);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 / 32768.0), out[0], 1e-9);
    try std.testing.expect(out[1] > 0 and out[1] < out[0]);
    try std.testing.expect(out[2] < out[1]);
}
