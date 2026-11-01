//! The SILK resampler: 8, 12 or 16 kHz up to Opus's 48 kHz output rate.
//!
//! SILK is the only layer that runs below 48 kHz. Its synthesis filter is
//! defined at the bandwidth's own rate (8 kHz for narrowband, 12 for medium,
//! 16 for wide), and RFC 6716 4.2.9 leaves the conversion to 48 kHz to the
//! decoder. So this file is not an optimisation: without it there are no
//! samples to hand to the output path at all.
//!
//! The conversion has to agree with the reference *decoder*, not merely be
//! "good": the acceptance test compares sample by sample against `ffmpeg
//! -f f32le`, and ffmpeg's native Opus decoder resamples SILK with
//! `libswresample` (see `libavcodec/opus/dec.c`: it opens an `SwrContext` with
//! `filter_size` 16 and the input rate taken from the packet bandwidth, primes
//! it with a few zero samples, and calls `swr_convert` once per packet). Two
//! different upsamplers disagree by tens of dB on the same input — a 16-tap
//! polyphase interpolator and libopus's `silk_resampler` differ by about 47 dB
//! on the test vectors — so "any correct resampler" is not good enough here.
//!
//! What this file therefore reproduces is that resampler's *arithmetic*, for
//! the three rates this decoder can produce:
//!
//!   * the polyphase filter bank: 16 taps per phase, Kaiser window with beta 9,
//!     cutoff 0.97 (which never applies while upsampling), built with the
//!     exact-rational phase count (48/8 = 6, 48/12 = 4, 48/16 = 3 phases
//!     instead of the default 1024);
//!   * the fixed-point position bookkeeping (`index`, `frac`, `src_incr`,
//!     `dst_incr`), which with those ratios degenerates to "one phase step per
//!     output sample"; and
//!   * the streaming buffer, including the mirrored start-up region the
//!     reference builds when the first output sample needs input before the
//!     first sample.
//!
//! The kernel is the windowed sinc the reference builds; the window's Bessel
//! function is the power series for I0 rather than a copied rational
//! approximation, which differs by ~1e-16 relative — below one float32 ulp, and
//! therefore absent from the coefficients this file stores.

const std = @import("std");

pub const Error = error{Unsupported};

/// Taps per phase. `libavcodec/opus/dec.c` sets `filter_size` to 16; swresample
/// would use 32 by default.
const filter_size: usize = 16;
/// Exact-rational phase counts for the three rates: 6, 4 and 3.
const max_phases: usize = 6;
const kaiser_beta: f64 = 9.0;
const cutoff: f64 = 0.97;

/// The most input samples one call carries: a 60 ms packet at 16 kHz.
const max_in = 960;

const Progress = struct {
    /// Output samples written.
    written: usize,
    /// Input samples consumed.
    consumed: usize,
};

pub const Resampler = struct {
    in_rate: u32,
    phase_count: usize,
    /// `ceil(filter_size / factor)` rounded up to even: 16 at every rate here.
    filter_length: usize,
    /// Row stride of the filter bank: one extra row holds the rotated copy the
    /// linear-interpolation path reads (that path is never taken for these
    /// integer ratios, but the copy is part of the bank's shape).
    filter_alloc: usize,
    filter: [max_phases + 1][filter_size]f32,

    /// Position of the next output sample, in units of 1/phase_count of an
    /// input sample, relative to the first sample of the next call.
    index: i32,
    frac: i32 = 0,
    src_incr: i32,
    dst_incr: i32,
    dst_incr_div: i32,
    dst_incr_mod: i32,

    /// Input samples not yet consumed, oldest first. The reference keeps this
    /// as a ring it compacts when it runs out of room; one packet plus one
    /// filter is the maximum, so a fixed buffer is enough.
    in_buffer: [2 * max_in]f32 = @splat(0.0),
    in_buffer_index: usize = 0,
    in_buffer_count: usize = 0,
    resample_in_constraint: bool = false,

    pub fn init(in_rate: u32) Error!Resampler {
        const out_rate: u32 = 48_000;
        if (in_rate != 8_000 and in_rate != 12_000 and in_rate != 16_000) return error.Unsupported;
        if (out_rate % in_rate != 0) return error.Unsupported;

        var self = Resampler{
            .in_rate = in_rate,
            .phase_count = out_rate / in_rate,
            .filter_length = filter_size,
            .filter_alloc = filter_size,
            .filter = @splat(@splat(0.0)),
            .index = 0,
            .src_incr = 0,
            .dst_incr = 0,
            .dst_incr_div = 0,
            .dst_incr_mod = 0,
        };
        self.buildFilter();

        // `av_reduce(out_rate, in_rate * phase_count)` is exactly 1/1 for these
        // rates; the reference then scales both increments up until they reach
        // 1 << 20, so the position maths is integer-exact.
        self.src_incr = 1;
        self.dst_incr = 1;
        while (self.dst_incr < (1 << 20) and self.src_incr < (1 << 20)) {
            self.src_incr *= 2;
            self.dst_incr *= 2;
        }
        self.dst_incr_div = @divTrunc(self.dst_incr, self.src_incr);
        self.dst_incr_mod = @rem(self.dst_incr, self.src_incr);

        // Start far enough back that the first output sample is centred on the
        // first input sample.
        self.index = -@as(i32, @intCast(self.phase_count)) *
            @as(i32, @intCast((self.filter_length - 1) / 2));
        return self;
    }

    /// One row of the polyphase bank per phase, plus the rotated extra row the
    /// linear path would read.
    fn buildFilter(self: *Resampler) void {
        const phase_count = self.phase_count;
        const taps = self.filter_length;
        const center = (taps - 1) / 2;
        const factor: f64 = 1.0; // every rate here upsamples, so factor clamps
        const pi = std.math.pi;

        const ph_nb = if (phase_count % 2 != 0) phase_count else phase_count / 2 + 1;
        var sin_lut: [max_phases]f64 = @splat(0.0);
        for (0..ph_nb) |ph| {
            sin_lut[ph] = @sin(pi * @as(f64, @floatFromInt(ph)) /
                @as(f64, @floatFromInt(phase_count))) *
                (if (center & 1 != 0) @as(f64, 1.0) else @as(f64, -1.0));
        }

        var tab: [filter_size]f64 = @splat(0.0);
        var norm: f64 = 0.0;
        for (0..ph_nb) |ph| {
            var s = sin_lut[ph];
            for (0..taps) |i| {
                const x = pi * (@as(f64, @floatFromInt(i)) -
                    @as(f64, @floatFromInt(center)) -
                    @as(f64, @floatFromInt(ph)) /
                        @as(f64, @floatFromInt(phase_count))) * factor;
                var y: f64 = if (x == 0) 1.0 else s / x;
                // Kaiser window: the interpolation kernel is tapered to zero at
                // the ends of its 16 taps.
                const w = 2.0 * x / (factor * @as(f64, @floatFromInt(taps)) * pi);
                y *= besselI0(kaiser_beta * @sqrt(@max(1.0 - w * w, 0.0)));
                tab[i] = y;
                s = -s;
                if (ph == 0) norm += y;
            }
            for (0..taps) |i| {
                self.filter[ph][i] = @floatCast(tab[i] / norm);
            }
            if (phase_count % 2 == 0) {
                // The upper half of an even phase bank is the lower half
                // reversed. Writing the phase-0 mirror into the spare row is
                // what the reference does; the rotation below overwrites it.
                for (0..taps) |i| {
                    self.filter[phase_count - ph][taps - 1 - i] = self.filter[ph][i];
                }
            }
        }

        // Rotated copy of phase 0 in the spare row, and phase 0's last tap in
        // its first slot: the layout the linear path indexes.
        for (0..self.filter_alloc - 1) |i| {
            self.filter[phase_count][i + 1] = self.filter[0][i];
        }
        self.filter[phase_count][0] = self.filter[0][self.filter_alloc - 1];
    }

    /// Prime the resampler with `n` zero samples, as the reference decoder does
    /// before the first packet so that its group delay is cancelled.
    pub fn primeZeros(self: *Resampler, n: usize) void {
        const zeros: [16]f32 = @splat(0.0);
        _ = self.convert(&.{}, zeros[0..@min(n, zeros.len)]);
    }

    /// Push `in` through the resampler, writing at most `out.len` samples.
    /// Returns the number written; a short return is not an error, the rest of
    /// the input stays buffered for the next call.
    pub fn convert(self: *Resampler, out: []f32, in: []const f32) usize {
        var out_count = out.len;
        var ret_sum: usize = 0;
        var in_pos: usize = 0;
        var in_count: usize = in.len;
        // Number of input samples fed to the resampler since the last mirror.
        // The reference calls this `border`; it is only non-zero while the
        // buffer still holds the mirrored start-up region.
        var border: usize = 0;

        if (self.index < 0 and in_count != 0) {
            // The first output sample is centred `filter_length / 2` samples
            // before the first input sample, so the reference fills the gap by
            // mirroring what it has and then advances the index to the first
            // whole phase.
            const num = @min(in_count + self.in_buffer_count, self.filter_length + 1);
            var n = self.in_buffer_count;
            while (n < num) : (n += 1) {
                self.in_buffer[self.filter_length + n] = in[n - self.in_buffer_count];
            }
            if (num < self.filter_length + 1) {
                // Not enough data yet: hold it and wait for the next call.
                self.in_buffer_count = num;
                self.in_buffer_index = self.filter_length;
                return 0;
            }
            n = 1;
            while (n <= self.filter_length) : (n += 1) {
                self.in_buffer[self.filter_length - n] = self.in_buffer[self.filter_length + n];
            }
            border = num - self.in_buffer_count;
            self.in_buffer_index = self.filter_length;
            while (self.index < 0) {
                self.in_buffer_index -= 1;
                self.index += @intCast(self.phase_count);
            }
            self.in_buffer_count = @max(
                self.in_buffer_count + self.filter_length,
                1 + self.filter_length * 2,
            ) - self.in_buffer_index;
            if (border > in_count) border = in_count;
            in_pos += border;
            in_count -= border;
            self.resample_in_constraint = false;
        }

        while (true) {
            if (!self.resample_in_constraint and self.in_buffer_count != 0) {
                const buffered = self.in_buffer_count;
                const p = self.resampleCommon(out[ret_sum..], self.in_buffer[self.in_buffer_index..][0..buffered]);
                out_count -= p.written;
                ret_sum += p.written;
                self.in_buffer_count -= p.consumed;
                self.in_buffer_index += p.consumed;
                if (in_count == 0) break;
                if (self.in_buffer_count <= border) {
                    in_pos -= self.in_buffer_count;
                    in_count += self.in_buffer_count;
                    self.in_buffer_count = 0;
                    self.in_buffer_index = 0;
                    border = 0;
                }
            }

            if (in_count != 0 and self.in_buffer_count == 0) {
                self.in_buffer_index = 0;
                const p = self.resampleCommon(out[ret_sum..], in[in_pos..][0..in_count]);
                out_count -= p.written;
                ret_sum += p.written;
                in_count -= p.consumed;
                in_pos += p.consumed;
            }

            const size = self.in_buffer_index + self.in_buffer_count + in_count;
            if (size > self.in_buffer.len) {
                // Unreachable: one packet plus one filter cannot fill the
                // buffer. Drop the pending input rather than overrun.
                break;
            }

            if (in_count != 0) {
                var count = in_count;
                if (self.in_buffer_count != 0 and self.in_buffer_count + 2 < count and out_count != 0) {
                    count = self.in_buffer_count + 2;
                }
                @memcpy(
                    self.in_buffer[self.in_buffer_index + self.in_buffer_count ..][0..count],
                    in[in_pos..][0..count],
                );
                self.in_buffer_count += count;
                in_count -= count;
                border += count;
                in_pos += count;
                self.resample_in_constraint = false;
                if (self.in_buffer_count != count or in_count != 0) continue;
            }
            break;
        }

        self.resample_in_constraint = out_count != 0;
        return ret_sum;
    }

    /// The convolution loop: one output sample per step, `phase_count` steps per
    /// input sample. `val` and `val2` accumulate the even and odd taps
    /// separately and are added at the end, which is the reference's summation
    /// order and therefore part of the result.
    fn resampleCommon(self: *Resampler, out: []f32, src: []const f32) Progress {
        var index = self.index;
        var sample_index: usize = 0;
        while (index >= @as(i32, @intCast(self.phase_count))) {
            sample_index += 1;
            index -= @intCast(self.phase_count);
        }

        var n = out.len;
        // How many output samples fit before the filter reads past `src`.
        if (src.len < self.filter_length) {
            n = 0;
        } else {
            const available: i64 = @as(i64, @intCast(src.len - self.filter_length + 1));
            const steps = available * @as(i64, @intCast(self.phase_count)) - @as(i64, index);
            n = @min(n, if (steps <= 0) 0 else @as(usize, @intCast(steps)));
        }
        if (n == 0) return .{ .written = 0, .consumed = 0 };

        const taps = self.filter_length;
        for (0..n) |dst_index| {
            const filter = &self.filter[@intCast(index)];
            var val: f32 = 0.0;
            var val2: f32 = 0.0;
            var i: usize = 0;
            while (i + 1 < taps) : (i += 2) {
                val += src[sample_index + i] * filter[i];
                val2 += src[sample_index + i + 1] * filter[i + 1];
            }
            if (i < taps) val += src[sample_index + i] * filter[i];
            out[dst_index] = val + val2;

            self.frac += self.dst_incr_mod;
            index += self.dst_incr_div;
            if (self.frac >= self.src_incr) {
                self.frac -= self.src_incr;
                index += 1;
            }
            while (index >= @as(i32, @intCast(self.phase_count))) {
                sample_index += 1;
                index -= @intCast(self.phase_count);
            }
        }

        self.index = index;
        return .{ .written = n, .consumed = sample_index };
    }
};

/// I0(x), the modified Bessel function of the first kind of order zero, by its
/// power series. Used only as the Kaiser window's taper.
fn besselI0(x: f64) f64 {
    const q = x * x * 0.25;
    var term: f64 = 1.0;
    var sum: f64 = 1.0;
    var k: f64 = 0.0;
    while (true) {
        k += 1.0;
        term *= q / (k * k);
        sum += term;
        if (term <= sum * 1e-18) break;
    }
    return sum;
}

test "filter bank: phase 0 is the interpolating phase" {
    const r = try Resampler.init(16_000);
    try std.testing.expectEqual(@as(usize, 3), r.phase_count);
    try std.testing.expectEqual(@as(usize, 16), r.filter_length);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), r.filter[0][7], 1e-6);
    for (0..16) |i| {
        if (i != 7) try std.testing.expectApproxEqAbs(@as(f32, 0.0), r.filter[0][i], 1e-6);
    }
    // Every phase is a low-pass interpolation kernel: its taps sum to 1.
    for (0..r.phase_count) |ph| {
        var sum: f64 = 0;
        for (0..16) |i| sum += r.filter[ph][i];
        try std.testing.expectApproxEqAbs(@as(f64, 1.0), sum, 1e-5);
    }
    // The even-order banks mirror their upper phases.
    const r12 = try Resampler.init(12_000);
    try std.testing.expectEqual(@as(usize, 4), r12.phase_count);
    for (0..16) |i| {
        try std.testing.expectEqual(r12.filter[1][i], r12.filter[3][15 - i]);
    }
    const r8 = try Resampler.init(8_000);
    try std.testing.expectEqual(@as(usize, 6), r8.phase_count);
    try std.testing.expectEqual(r8.filter[2][0], r8.filter[4][15]);
}

test "phase-0 outputs reproduce the ramp exactly" {
    // A ramp is the one input whose interpolated values are predictable without
    // re-deriving the kernel: on the phase-0 lattice the output must be an
    // input sample, so it is an integer, and consecutive ones differ by 1.
    // The other two phases land between samples and are not integers.
    var r = try Resampler.init(16_000);
    r.primeZeros(11);
    var in: [320]f32 = undefined;
    for (&in, 0..) |*v, i| v.* = @floatFromInt(i);
    var out: [960]f32 = @splat(0.0);
    const n = r.convert(&out, &in);
    try std.testing.expect(n > 500);

    var prev: ?f32 = null;
    var lattice: usize = 0;
    for (0..n) |k| {
        if (k < 200) continue; // skip the mirrored start-up region
        if (k % 3 != 0) {
            try std.testing.expect(out[k] != @round(out[k]));
            continue;
        }
        try std.testing.expectEqual(out[k], @round(out[k]));
        if (prev) |p| try std.testing.expectApproxEqAbs(@as(f32, 1.0), out[k] - p, 1e-6);
        prev = out[k];
        lattice += 1;
    }
    try std.testing.expect(lattice > 100);
}
