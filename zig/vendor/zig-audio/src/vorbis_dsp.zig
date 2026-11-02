//! Vorbis synthesis: the inverse MDCT, the window, and the shape of the lap.
//!
//! The transform is the standard lapped MDCT. With `n` the block size, the
//! spectrum has `M = n/2` lines and the time output has `n` samples:
//!
//!     y[i] = sum_{k<M} X[k] * cos(pi/M * (i + 1/2 + M/2) * (k + 1/2))
//!
//! evaluated here as a DCT-IV through two complex FFTs of size `M`:
//!
//!     c[m] = sum_k X[k] cos(pi/M (m+1/2)(k+1/2))
//!          = Re{ e^{-i pi (m+1/2)/(2M)} * FFT_{2M}(X[k] e^{-i pi k/(2M)})[m] }
//!
//! and the 2M-point transform of a length-M sequence is the pair of M-point
//! transforms of the even and odd input (see `Transform.run`).
//!
//! **No normalisation.** The inverse transform here is the raw cosine sum: the
//! `2/M` of a textbook IMDCT is *not* applied, because Vorbis puts its `4/n`
//! on the encoder's forward transform (`mdct_forward` in the reference
//! implementation) and leaves `mdct_backward` unnormalised. Getting this wrong
//! is not subtle in the output — every sample is scaled by the block size — but
//! it is invisible in a per-sample correlation, so it is worth stating loudly.
//!
//! The IMDCT's time-aliased output is folded onto `c` using the symmetries of
//! `cos`, which is where the four index ranges in `Transform.fold` come from;
//! they are checked against a direct O(n*M) evaluation in `vorbis_dsp_test.zig`.

const std = @import("std");
const types = @import("types.zig");

pub const Error = types.Error;

pub const Complex = struct {
    re: f32 = 0,
    im: f32 = 0,
};

inline fn mul(a: Complex, b: Complex) Complex {
    return .{ .re = a.re * b.re - a.im * b.im, .im = a.re * b.im + a.im * b.re };
}

/// In-place radix-2 complex FFT, decimation in time.
pub const Fft = struct {
    n: usize = 0,
    twiddle: []Complex = &.{},
    reverse: []u32 = &.{},

    pub fn init(allocator: std.mem.Allocator, n: usize) Error!Fft {
        if (n < 2 or (n & (n - 1)) != 0) return error.Corrupt;
        var fft = Fft{ .n = n };
        errdefer fft.deinit(allocator);
        fft.twiddle = try allocator.alloc(Complex, n / 2);
        for (fft.twiddle, 0..) |*slot, k| {
            const angle = -2.0 * std.math.pi * @as(f32, @floatFromInt(k)) /
                @as(f32, @floatFromInt(n));
            slot.* = .{ .re = @cos(angle), .im = @sin(angle) };
        }
        fft.reverse = try allocator.alloc(u32, n);
        const bits: u6 = @intCast(std.math.log2_int(usize, n));
        for (fft.reverse, 0..) |*slot, i| {
            const reversed = @bitReverse(@as(u32, @intCast(i)));
            slot.* = reversed >> @intCast(32 - @as(u6, bits));
        }
        return fft;
    }

    pub fn deinit(self: *Fft, allocator: std.mem.Allocator) void {
        if (self.twiddle.len != 0) allocator.free(self.twiddle);
        if (self.reverse.len != 0) allocator.free(self.reverse);
        self.* = .{};
    }

    pub fn run(self: *const Fft, data: []Complex) void {
        const n = self.n;
        if (data.len != n) return;
        for (self.reverse, 0..) |target, i| {
            if (i < target) {
                const swap = data[i];
                data[i] = data[target];
                data[target] = swap;
            }
        }
        var len: usize = 2;
        while (len <= n) : (len <<= 1) {
            const half = len / 2;
            const stride = n / len;
            var start: usize = 0;
            while (start < n) : (start += len) {
                var k: usize = 0;
                while (k < half) : (k += 1) {
                    const w = self.twiddle[k * stride];
                    const a = data[start + k];
                    const b = data[start + k + half];
                    const t = mul(b, w);
                    data[start + k] = .{ .re = a.re + t.re, .im = a.im + t.im };
                    data[start + k + half] = .{ .re = a.re - t.re, .im = a.im - t.im };
                }
            }
        }
    }
};

/// One block size's precomputed MDCT plan.
pub const Transform = struct {
    /// Block size in samples; the spectrum has `half` lines.
    n: usize = 0,
    half: usize = 0,
    fft: Fft = .{},
    /// `(2/M) * e^{-i pi k/(2M)}`
    pre: []Complex = &.{},
    /// `e^{-i pi k/M}` — the half-bin shift that turns even bins into odd ones.
    odd: []Complex = &.{},
    /// `e^{-i pi (m+1/2)/(2M)}`
    post: []Complex = &.{},

    pub fn init(allocator: std.mem.Allocator, n: usize) Error!Transform {
        if (n < 8 or (n & (n - 1)) != 0) return error.Corrupt;
        const half = n / 2;
        var transform = Transform{ .n = n, .half = half };
        errdefer transform.deinit(allocator);
        transform.fft = try Fft.init(allocator, half);
        transform.pre = try allocator.alloc(Complex, half);
        transform.odd = try allocator.alloc(Complex, half);
        transform.post = try allocator.alloc(Complex, half);

        const scale = 1.0;
        const m: f32 = @floatFromInt(half);
        for (0..half) |k| {
            const kf: f32 = @floatFromInt(k);
            const pre_angle = -std.math.pi * kf / (2.0 * m);
            transform.pre[k] = .{
                .re = scale * @cos(pre_angle),
                .im = scale * @sin(pre_angle),
            };
            const odd_angle = -std.math.pi * kf / m;
            transform.odd[k] = .{ .re = @cos(odd_angle), .im = @sin(odd_angle) };
            const post_angle = -std.math.pi * (kf + 0.5) / (2.0 * m);
            transform.post[k] = .{ .re = @cos(post_angle), .im = @sin(post_angle) };
        }
        return transform;
    }

    pub fn deinit(self: *Transform, allocator: std.mem.Allocator) void {
        self.fft.deinit(allocator);
        if (self.pre.len != 0) allocator.free(self.pre);
        if (self.odd.len != 0) allocator.free(self.odd);
        if (self.post.len != 0) allocator.free(self.post);
        self.* = .{};
    }

    /// `spectrum` is `half` lines; `out` receives `n` time samples.
    ///
    /// `a`, `b` and `c` are caller-owned scratch of `half` entries each: two
    /// complex FFT buffers and one real buffer for the DCT-IV result (each `c`
    /// value lands in two output samples, so it cannot be folded in place).
    pub fn run(
        self: *const Transform,
        spectrum: []const f32,
        out: []f32,
        a: []Complex,
        b: []Complex,
        c: []f32,
    ) void {
        const half = self.half;
        if (self.n == 0) return;
        if (spectrum.len < half or out.len < self.n) return;
        if (a.len < half or b.len < half or c.len < half) return;

        for (0..half) |k| {
            a[k] = .{ .re = spectrum[k] * self.pre[k].re, .im = spectrum[k] * self.pre[k].im };
        }
        for (0..half) |k| {
            b[k] = mul(a[k], self.odd[k]);
        }
        self.fft.run(a[0..half]);
        self.fft.run(b[0..half]);

        // Even bins of the 2M-point transform are FFT(a), odd bins are FFT(b).
        for (0..half) |m| {
            const bin = if (m & 1 == 0) a[m / 2] else b[m / 2];
            const p = self.post[m];
            c[m] = bin.re * p.re - bin.im * p.im;
        }

        self.foldTransform(c[0..half], out[0..self.n]);
    }

    /// Fold the DCT-IV result into the n-sample IMDCT output. Writing
    /// `y[n] = c[n + M/2]` and reducing the index with
    /// `cos(pi - t) = -cos(t)` and `C(t + 2M) = -C(t)` gives three ranges.
    fn foldTransform(self: *const Transform, c: []const f32, out: []f32) void {
        _ = self;
        const half = c.len;
        const quarter = half / 2;
        // y[0 .. M/2) = c[M/2 .. M)
        for (0..quarter) |i| out[i] = c[quarter + i];
        // y[M/2 .. 3M/2) = -c[M-1 .. 0]
        for (0..half) |i| out[quarter + i] = -c[half - 1 - i];
        // y[3M/2 .. 2M) = -c[0 .. M/2)
        for (0..quarter) |i| out[half + quarter + i] = -c[i];
    }
};

/// Window shape selector. The four long-window variants are the "normal" long
/// window plus the two hybrids that lap against a short block.
pub const WindowKind = enum {
    /// Blocksize_0 window, used whenever the block itself is short.
    short,
    /// Long block with long blocks on both sides.
    long_normal,
    /// Long block whose *previous* block was short: zero, short rise, one.
    long_start,
    /// Long block whose *next* block was short: one, short fall, zero.
    long_end,
    /// Long block with short blocks on both sides.
    long_transient,

    /// Pick the shape from the block size and the two neighbour flags.
    pub fn select(n: usize, blocksize_0: usize, previous_long: bool, next_long: bool) WindowKind {
        if (n == blocksize_0) return .short;
        if (previous_long and next_long) return .long_normal;
        if (previous_long) return .long_end;
        if (next_long) return .long_start;
        return .long_transient;
    }
};

/// The Vorbis slope function `sin(pi/2 * sin^2((index+0.5)/length * pi))`.
pub fn slope(index: usize, length: usize) f32 {
    const position = (@as(f32, @floatFromInt(index)) + 0.5) /
        @as(f32, @floatFromInt(length)) * std.math.pi;
    const s = @sin(position);
    return @sin(0.5 * std.math.pi * s * s);
}

/// Build the `n`-sample window for `kind`. `out.len` must be at least `n`.
///
/// The hybrid halves use the *short* window's slope over `blocksize_0 / 2`
/// samples: the specification's `(i - start + 0.5) / (blocksize_0/2) * pi/2`
/// argument is exactly `slope(i - start, blocksize_0)`, so the rise and fall are
/// the short window's two halves shifted into place, with 1.0 inside and 0.0
/// outside. That 1.0/0.0 padding is what lets a long block lap a short one
/// without breaking reconstruction — the samples in the padded region take no
/// part in the overlap.
pub fn buildWindow(out: []f32, n: usize, blocksize_0: usize, kind: WindowKind) void {
    if (n == 0 or out.len < n) return;
    switch (kind) {
        .short, .long_normal => {
            for (0..n) |i| out[i] = slope(i, n);
        },
        .long_start => {
            const short_half = blocksize_0 / 2;
            const start = n / 4 - blocksize_0 / 4;
            const end = start + short_half;
            for (0..n) |i| {
                out[i] = if (i < start)
                    0
                else if (i < end)
                    slope(i - start, blocksize_0)
                else if (i < n / 2)
                    1
                else
                    slope(i, n);
            }
        },
        .long_end => {
            const short_half = blocksize_0 / 2;
            const start = n * 3 / 4 - blocksize_0 / 4;
            const end = start + short_half;
            for (0..n) |i| {
                out[i] = if (i < n / 2)
                    slope(i, n)
                else if (i < start)
                    1
                else if (i < end)
                    slope(short_half - 1 - (i - start), blocksize_0)
                else
                    0;
            }
        },
        .long_transient => {
            const short_half = blocksize_0 / 2;
            const left_start = n / 4 - blocksize_0 / 4;
            const left_end = left_start + short_half;
            const right_start = n * 3 / 4 - blocksize_0 / 4;
            const right_end = right_start + short_half;
            for (0..n) |i| {
                out[i] = if (i < left_start)
                    0
                else if (i < left_end)
                    slope(i - left_start, blocksize_0)
                else if (i < right_start)
                    1
                else if (i < right_end)
                    slope(short_half - 1 - (i - right_start), blocksize_0)
                else
                    0;
            }
        },
    }
}
