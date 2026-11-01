//! Shared state and small helpers for the SILK decoder.
//!
//! SILK keeps a surprising amount of state per channel: the previous frame's
//! LSF vector and LPC coefficients (the 20 ms frames interpolate towards them),
//! the last gain (gains are coded as deltas), the primary pitch lag (pitch is
//! coded as a delta too), and two 322-sample histories, one of the output
//! signal and one of the *unclipped* LPC synthesis signal. The second one is
//! not a duplicate: the re-whitening step that bridges a coefficient change
//! needs the signal before the final clip, or it would feed a distorted
//! residual back into the filter.

const std = @import("std");

pub const history = 322;
pub const max_lpc = 16;
/// Order of the long-term (pitch) predictor.
pub const ltp_order = 5;
/// Longest pitch lag plus the LTP filter's own lookback, per RFC 6716 4.2.7.6.1.
pub const max_lag = 288 + ltp_order / 2;
/// Largest SILK output for one Opus frame: 60 ms at 16 kHz.
pub const max_frame = 960;

pub const Bandwidth = enum(u2) {
    narrow = 0,
    medium = 1,
    wide = 2,

    /// Samples per subframe: 5 ms at the bandwidth's own rate.
    pub fn subframeSamples(self: Bandwidth) usize {
        return 20 * (@as(usize, @backingInt(self)) + 2);
    }

    pub fn sampleRate(self: Bandwidth) u32 {
        return switch (self) {
            .narrow => 8_000,
            .medium => 12_000,
            .wide => 16_000,
        };
    }

    /// Zero samples the reference feeds to its resampler before the first
    /// packet, so that the resampler's group delay is cancelled.
    pub fn resamplerDelay(self: Bandwidth) usize {
        return switch (self) {
            .narrow => 4,
            .medium => 8,
            .wide => 11,
        };
    }
};

pub const Frame = struct {
    /// Cleared after a reset; a frame that was never coded has no history to
    /// interpolate from.
    coded: bool = false,
    /// Q7 log gain of the last subframe that was decoded.
    log_gain: i32 = 0,
    /// Previous frame's normalised LSFs, Q15.
    nlsf: [max_lpc]i16 = @splat(0),
    /// Previous frame's LPC coefficients.
    lpc: [max_lpc]f32 = @splat(0.0),
    /// Output signal with `history` samples of lead-in.
    output: [2 * history]f32 = @splat(0.0),
    /// The same signal *before* clipping, which the re-whitening filter needs.
    lpc_history: [2 * history]f32 = @splat(0.0),
    primary_lag: i32 = 0,
    prev_voiced: bool = false,

    pub fn flush(self: *Frame) void {
        if (!self.coded) return;
        self.output = @splat(0.0);
        self.lpc_history = @splat(0.0);
        self.lpc = @splat(0.0);
        self.nlsf = @splat(0);
        self.log_gain = 0;
        self.primary_lag = 0;
        self.prev_voiced = false;
        self.coded = false;
    }
};

/// `av_clipf`: max then min, which maps NaN to the lower bound like the
/// reference's macro does.
pub fn clipf(x: f32, lo: f32, hi: f32) f32 {
    const a = if (x > lo) x else lo;
    return if (a < hi) a else hi;
}

/// `av_clip_int16`.
pub fn clipInt16(x: i32) i16 {
    return @intCast(std.math.clamp(x, -32768, 32767));
}

/// `av_clip_uintp2(v, 15)`.
pub fn clipUint15(x: i32) i16 {
    return @intCast(std.math.clamp(x, 0, 32767));
}

/// `opus_ilog`: the number of bits needed, i.e. floor(log2(v)) + 1.
pub fn ilog(v: u32) u32 {
    return if (v == 0) 0 else 32 - @as(u32, @clz(v));
}
