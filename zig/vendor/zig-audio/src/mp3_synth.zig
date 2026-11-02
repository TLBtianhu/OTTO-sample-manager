//! MPEG-1 Layer III synthesis: alias reduction, IMDCT with the four window
//! shapes, frequency inversion and the 32-band polyphase filterbank.
//!
//! Spectral lines are kept subband-major (`x[subband * 18 + time]`), which is
//! also the layout the synthesis filter consumes: slot `t` is
//! `{ x[k * 18 + t] }` for the 32 subbands `k`.

const std = @import("std");
const types = @import("types.zig");
const tables = @import("mp3_tables.zig");

pub const Error = types.Error;

/// Long-block windows indexed by MPEG block_type (0 normal, 1 start, 3 stop).
/// The angles are evaluated in f64 and rounded once to f32: computing them in
/// f32 first loses up to 1e-6 per tap on the large arguments.
pub const long_window = blk: {
    @setEvalBranchQuota(100_000);
    var w: [4][36]f32 = @splat(@splat(0));
    for (0..36) |i| {
        const x = @as(f64, @floatFromInt(i));
        const base: f32 = @floatCast(@sin(std.math.pi * (x + 0.5) / 36.0));
        w[0][i] = base;
        if (i < 18) {
            w[1][i] = base;
        } else if (i < 24) {
            w[1][i] = 1.0;
        } else if (i < 30) {
            w[1][i] = @floatCast(@sin(std.math.pi * (x - 18.0 + 0.5) / 12.0));
        } else {
            w[1][i] = 0;
        }

        if (i < 6) {
            w[3][i] = 0;
        } else if (i < 12) {
            w[3][i] = @floatCast(@sin(std.math.pi * (x - 6.0 + 0.5) / 12.0));
        } else if (i < 18) {
            w[3][i] = 1.0;
        } else {
            w[3][i] = base;
        }
    }
    break :blk w;
};

/// Short-block 12-point window.
pub const short_window = blk: {
    @setEvalBranchQuota(10_000);
    var w: [12]f32 = undefined;
    for (&w, 0..) |*v, i| {
        const x = @as(f64, @floatFromInt(i));
        v.* = @floatCast(@sin(std.math.pi * (x + 0.5) / 12.0));
    }
    break :blk w;
};

const imdct36_cos = blk: {
    @setEvalBranchQuota(2_000_000);
    var m: [36][18]f32 = undefined;
    for (&m, 0..) |*row, i| {
        for (row, 0..) |*v, k| {
            const a = std.math.pi / 72.0 *
                (@as(f64, @floatFromInt(2 * i + 19))) *
                (@as(f64, @floatFromInt(2 * k + 1)));
            v.* = @floatCast(@cos(a));
        }
    }
    break :blk m;
};

const imdct12_cos = blk: {
    @setEvalBranchQuota(100_000);
    var m: [12][6]f32 = undefined;
    for (&m, 0..) |*row, i| {
        for (row, 0..) |*v, k| {
            const a = std.math.pi / 24.0 *
                (@as(f64, @floatFromInt(2 * i + 7))) *
                (@as(f64, @floatFromInt(2 * k + 1)));
            v.* = @floatCast(@cos(a));
        }
    }
    break :blk m;
};

/// ISO 11172-3 Table B.3, reconstructed from the 257-tap half window.
pub const synth_window = blk: {
    var d: [512]f32 = undefined;
    for (0..257) |i| {
        var v: f32 = @as(f32, @floatFromInt(tables.enwindow[i])) / 65536.0;
        d[i] = v;
        if ((i & 63) != 0) v = -v;
        if (i != 0) d[512 - i] = v;
    }
    break :blk d;
};

const synth_cos = blk: {
    @setEvalBranchQuota(2_000_000);
    var m: [64][32]f32 = undefined;
    for (&m, 0..) |*row, i| {
        for (row, 0..) |*v, k| {
            const a = std.math.pi / 64.0 *
                (@as(f64, @floatFromInt(16 + i))) *
                (@as(f64, @floatFromInt(2 * k + 1)));
            v.* = @floatCast(@cos(a));
        }
    }
    break :blk m;
};

pub fn aliasReduce(x: *[576]f32, boundaries: usize) void {
    var b: usize = 0;
    while (b < boundaries) : (b += 1) {
        const center = 18 * (b + 1);
        for (0..8) |j| {
            const lower = x[center - 1 - j];
            const upper = x[center + j];
            x[center - 1 - j] = lower * tables.alias_cs[j] + upper * tables.alias_ca[j];
            x[center + j] = upper * tables.alias_cs[j] - lower * tables.alias_ca[j];
        }
    }
}

fn imdct36(input: *const [18]f32, out: *[36]f32) void {
    for (out, 0..) |*v, i| {
        var sum: f32 = 0;
        for (input, 0..) |c, k| sum += c * imdct36_cos[i][k];
        v.* = sum;
    }
}

fn imdct12(input: *const [6]f32, out: *[12]f32) void {
    for (out, 0..) |*v, i| {
        var sum: f32 = 0;
        for (input, 0..) |c, k| sum += c * imdct12_cos[i][k];
        v.* = sum;
    }
}

pub fn imdctGranule(
    x: *[576]f32,
    block_type: u2,
    mixed: bool,
    overlap: *[32][18]f32,
    pcm: *[576]f32,
) void {
    const long_end: usize = if (mixed) 2 else if (block_type == 2) 0 else 32;
    var sub: usize = 0;
    while (sub < long_end) : (sub += 1) {
        var out: [36]f32 = undefined;
        const input: *const [18]f32 = @ptrCast(x[sub * 18 ..][0..18]);
        imdct36(input, &out);
        const win = if (block_type == 2) &long_window[0] else &long_window[block_type];
        for (0..36) |i| out[i] *= win[i];
        for (0..18) |i| {
            pcm[sub * 18 + i] = overlap[sub][i] + out[i];
            overlap[sub][i] = out[18 + i];
        }
    }

    if (block_type == 2) {
        while (sub < 32) : (sub += 1) {
            var s: [36]f32 = @splat(0);
            for (0..3) |w| {
                var input: [6]f32 = undefined;
                for (0..6) |k| input[k] = x[sub * 18 + 3 * k + w];
                var out: [12]f32 = undefined;
                imdct12(&input, &out);
                for (0..12) |i| s[6 + 6 * w + i] += out[i] * short_window[i];
            }
            for (0..18) |i| {
                pcm[sub * 18 + i] = overlap[sub][i] + s[i];
                overlap[sub][i] = s[18 + i];
            }
        }
    } else {
        const win = &long_window[block_type];
        while (sub < 32) : (sub += 1) {
            var out: [36]f32 = undefined;
            const input: *const [18]f32 = @ptrCast(x[sub * 18 ..][0..18]);
            imdct36(input, &out);
            for (0..36) |i| out[i] *= win[i];
            for (0..18) |i| {
                pcm[sub * 18 + i] = overlap[sub][i] + out[i];
                overlap[sub][i] = out[18 + i];
            }
        }
    }

    // Frequency inversion: odd subbands, odd time slots.
    sub = 1;
    while (sub < 32) : (sub += 2) {
        var t: usize = 1;
        while (t < 18) : (t += 2) pcm[sub * 18 + t] = -pcm[sub * 18 + t];
    }
}

/// One channel's 1024-slot synthesis delay line.
pub const SynthState = struct {
    v: [1024]f32 = @splat(0),

    pub fn reset(self: *SynthState) void {
        self.v = @splat(0);
    }

    /// 18 slots (576 samples) of subband input to 576 PCM samples.
    pub fn process(self: *SynthState, pcm: *const [576]f32, out: *[576]f32) void {
        for (0..18) |slot| {
            var s: [32]f32 = undefined;
            for (&s, 0..) |*v, k| v.* = pcm[k * 18 + slot];

            std.mem.copyBackwards(f32, self.v[64..1024], self.v[0..960]);
            for (0..64) |i| {
                var sum: f32 = 0;
                for (s, 0..) |sample, k| sum += sample * synth_cos[i][k];
                self.v[i] = sum;
            }

            for (0..32) |j| {
                var sum: f32 = 0;
                for (0..8) |i| {
                    const a = self.v[i * 128 + j];
                    const b = self.v[i * 128 + 96 + j];
                    sum += a * synth_window[i * 64 + j];
                    sum += b * synth_window[i * 64 + 32 + j];
                }
                out[slot * 32 + j] = sum;
            }
        }
    }
};

test "long window is a 36-point sine window" {
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), long_window[0][17], 0.03);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), long_window[1][35], 1e-7);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), long_window[1][18], 1e-7);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), long_window[3][0], 1e-7);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), long_window[3][12], 1e-7);
}

test "alias reduction preserves a constant boundary field" {
    var x: [576]f32 = @splat(0);
    x[17] = 0.5;
    x[18] = 0.5;
    aliasReduce(&x, 1);
    // Orthogonal rotation: squares add up to the same energy.
    const e = x[17] * x[17] + x[18] * x[18];
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), e, 1e-5);
}

test "synthesis of all-zero subbands is silence" {
    var state = SynthState{};
    var pcm: [576]f32 = @splat(0);
    var out: [576]f32 = undefined;
    state.process(&pcm, &out);
    for (out) |v| try std.testing.expectEqual(@as(f32, 0), v);
}

// ---------------------------------------------------------------------------
// Reference implementations, written directly from ISO 11172-3 and evaluated
// in f64. They share no table or loop with the decoder above, so an indexing,
// window-shape or overlap-placement error cannot cancel out.
//
// The decoder's transforms are already the plain O(n^2) cosine sums over a
// precomputed f32 matrix (there is no fast transform in this file), so the
// comparison here is "f32 matrix vs f64 closed form": the agreement bound is
// f32 rounding, not 1e-9. A structural error (wrong index, window or overlap
// slot) is O(1) and cannot hide under that bound.
// ---------------------------------------------------------------------------

fn refCos(i: usize, k: usize, n: usize) f64 {
    // IMDCT: out[i] = sum_k X[k] cos(pi/N (i + 0.5 + N/2)(k + 0.5)), 0 <= i < 2N.
    const a = std.math.pi / @as(f64, @floatFromInt(4 * n)) *
        (@as(f64, @floatFromInt(2 * i)) + @as(f64, @floatFromInt(n)) + 1.0) *
        (@as(f64, @floatFromInt(2 * k)) + 1.0);
    return @cos(a);
}

fn refImdct(comptime n: usize, input: *const [n]f32, out: *[2 * n]f64) void {
    for (out, 0..) |*v, i| {
        var sum: f64 = 0;
        for (input, 0..) |c, k| sum += @as(f64, c) * refCos(i, k, n);
        v.* = sum;
    }
}

fn refLongWindow(i: usize, block_type: u2) f64 {
    const x = @as(f64, @floatFromInt(i));
    const base = @sin(std.math.pi * (x + 0.5) / 36.0);
    return switch (block_type) {
        0 => base,
        1 => if (i < 18) base else if (i < 24) 1.0 else if (i < 30)
            @sin(std.math.pi * (x - 18.0 + 0.5) / 12.0)
        else
            0.0,
        else => if (i < 6) 0.0 else if (i < 12)
            @sin(std.math.pi * (x - 6.0 + 0.5) / 12.0)
        else if (i < 18)
            1.0
        else
            base,
    };
}

fn refShortWindow(i: usize) f64 {
    return @sin(std.math.pi * (@as(f64, @floatFromInt(i)) + 0.5) / 12.0);
}

/// Spec-literal short block: three 12-point IMDCTs at 6 + 6*w, each windowed
/// by the 12-point sine window; returns the 36-sample buffer.
fn refShortBlock(x: *const [18]f32, s: *[36]f64) void {
    for (s) |*v| v.* = 0;
    for (0..3) |w| {
        var input: [6]f32 = undefined;
        for (0..6) |k| input[k] = x[3 * k + w];
        var y: [12]f64 = undefined;
        refImdct(6, &input, &y);
        for (0..12) |i| s[6 + 6 * w + i] += y[i] * refShortWindow(i);
    }
}

fn prng(state: *u32) f32 {
    state.* = state.* *% 1_664_525 +% 1_013_904_223;
    return @as(f32, @floatFromInt(state.* >> 8)) / 8388608.0 - 1.0;
}

test "36-point IMDCT matches a direct cosine sum" {
    var rng: u32 = 0x5eed_1234;
    var input: [18]f32 = undefined;
    for (&input) |*v| v.* = prng(&rng);
    var got: [36]f32 = undefined;
    imdct36(&input, &got);
    var want: [36]f64 = undefined;
    refImdct(18, &input, &want);
    for (got, want) |g, w| try std.testing.expectApproxEqAbs(w, @as(f64, g), 2e-5);
}

test "12-point short IMDCT matches a direct cosine sum" {
    var rng: u32 = 0xc0ff_ee01;
    var input: [6]f32 = undefined;
    for (&input) |*v| v.* = prng(&rng);
    var got: [12]f32 = undefined;
    imdct12(&input, &got);
    var want: [12]f64 = undefined;
    refImdct(6, &input, &want);
    for (got, want) |g, w| try std.testing.expectApproxEqAbs(w, @as(f64, g), 5e-6);
}

test "the transform matrices equal the closed-form cosines" {
    for (0..36) |i| {
        for (0..18) |k| {
            try std.testing.expectApproxEqAbs(refCos(i, k, 18), @as(f64, imdct36_cos[i][k]), 3e-6);
        }
    }
    for (0..12) |i| {
        for (0..6) |k| {
            try std.testing.expectApproxEqAbs(refCos(i, k, 6), @as(f64, imdct12_cos[i][k]), 1e-6);
        }
    }
}

test "all four window shapes match the specification" {
    for (0..36) |i| {
        try std.testing.expectApproxEqAbs(refLongWindow(i, 0), @as(f64, long_window[0][i]), 2e-7);
        try std.testing.expectApproxEqAbs(refLongWindow(i, 1), @as(f64, long_window[1][i]), 2e-7);
        try std.testing.expectApproxEqAbs(refLongWindow(i, 3), @as(f64, long_window[3][i]), 2e-7);
    }
    for (0..12) |i| {
        try std.testing.expectApproxEqAbs(refShortWindow(i), @as(f64, short_window[i]), 2e-7);
    }
    // Start and stop share the long first/last half with block type 0.
    for (0..18) |i| {
        try std.testing.expectEqual(long_window[0][i], long_window[1][i]);
        try std.testing.expectEqual(long_window[0][18 + i], long_window[3][18 + i]);
    }
}

test "overlap-add matches the specification for two long granules" {
    var x1: [576]f32 = @splat(0);
    var x2: [576]f32 = @splat(0);
    var rng: u32 = 0xabcd_0001;
    for (&x1) |*v| v.* = prng(&rng) * 0.25;
    for (&x2) |*v| v.* = prng(&rng) * 0.25;

    var overlap: [32][18]f32 = @splat(@splat(0));
    var pcm1: [576]f32 = undefined;
    var pcm2: [576]f32 = undefined;
    imdctGranule(&x1, 0, false, &overlap, &pcm1);
    const tail = overlap;
    imdctGranule(&x2, 0, false, &overlap, &pcm2);

    for (0..32) |sub| {
        var input: [18]f32 = undefined;
        for (0..18) |k| input[k] = x1[sub * 18 + k];
        var y1: [36]f64 = undefined;
        refImdct(18, &input, &y1);
        for (0..18) |k| input[k] = x2[sub * 18 + k];
        var y2: [36]f64 = undefined;
        refImdct(18, &input, &y2);

        for (0..18) |i| {
            // Frequency inversion applies to odd subbands at odd slots; the
            // reference below models it explicitly.
            const sign: f64 = if (sub % 2 == 1 and i % 2 == 1) -1.0 else 1.0;
            const want1 = y1[i] * refLongWindow(i, 0) * sign;
            const want2 = (y1[18 + i] * refLongWindow(18 + i, 0) + y2[i] * refLongWindow(i, 0)) * sign;
            try std.testing.expectApproxEqAbs(want1, @as(f64, pcm1[sub * 18 + i]), 2e-5);
            try std.testing.expectApproxEqAbs(want2, @as(f64, pcm2[sub * 18 + i]), 2e-5);
        }
        // The stored tail is the windowed second half, uninverted.
        for (0..18) |i| {
            try std.testing.expectApproxEqAbs(y1[18 + i] * refLongWindow(18 + i, 0), @as(f64, tail[sub][i]), 2e-5);
        }
    }
}

test "short block lands at 6/12/18 and overlaps through six taps" {
    var x: [576]f32 = @splat(0);
    var rng: u32 = 0x1357_9bdf;
    for (&x) |*v| v.* = prng(&rng) * 0.25;

    var overlap: [32][18]f32 = @splat(@splat(0));
    // Seed every slot with a sentinel so a missing overlap is visible.
    for (&overlap) |*band| for (band) |*v| {
        v.* = 0.5;
    };
    const prev = overlap;

    var pcm: [576]f32 = undefined;
    imdctGranule(&x, 2, false, &overlap, &pcm);

    for (0..32) |sub| {
        var input: [18]f32 = undefined;
        for (0..18) |k| input[k] = x[sub * 18 + k];
        var s: [36]f64 = undefined;
        refShortBlock(&input, &s);

        for (0..18) |i| {
            const sign: f64 = if (sub % 2 == 1 and i % 2 == 1) -1.0 else 1.0;
            const want = (s[i] + @as(f64, prev[sub][i])) * sign;
            try std.testing.expectApproxEqAbs(want, @as(f64, pcm[sub * 18 + i]), 2e-5);
        }
        for (0..18) |i| {
            try std.testing.expectApproxEqAbs(s[18 + i], @as(f64, overlap[sub][i]), 2e-5);
        }
        // The short block's first six and last six time samples are zero, so
        // the first six output slots are pure overlap and the last six stored
        // taps are zero.
        for (0..6) |i| {
            const sign: f64 = if (sub % 2 == 1 and i % 2 == 1) -1.0 else 1.0;
            try std.testing.expectApproxEqAbs(@as(f64, prev[sub][i]) * sign, @as(f64, pcm[sub * 18 + i]), 2e-5);
            try std.testing.expectEqual(@as(f32, 0), overlap[sub][12 + i]);
        }
    }
}
