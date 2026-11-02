//! CELT's fixed-point-flavoured arithmetic: the pieces the bitstream's
//! structure depends on having *exactly* the same value in every decoder.
//!
//! Everything here is integer, and every one of these functions is a place
//! where "do the obvious float thing" changes the decoded audio:
//!
//!   * `bitexactCos` is a Q15 polynomial, not `cos`. Its output is the mid/side
//!     gain and also feeds `bitexactLog2tan`, whose result becomes the split's
//!     bit budget. A float cosine is more accurate and completely wrong here.
//!   * `fracMul16` narrows both operands to `int16` before multiplying. The
//!     narrowing is part of the definition, not an oversight: it is what makes
//!     the result identical on platforms with and without `float32`.
//!   * `isqrt32` is a shift-and-subtract square root; `@sqrt` on a float would
//!     differ in the last bit and move a triangular-PDF boundary.
//!   * `lcgRand` is the folding noise generator. Its state is seeded from the
//!     range decoder's final value, so a different multiplier turns into
//!     broadband noise rather than a decode failure.

const std = @import("std");
const range = @import("opus_range.zig");

/// The linear congruential generator CELT uses for folding noise and
/// anti-collapse. Wrapping on purpose.
pub fn lcgRand(seed: u32) u32 {
    return seed *% 1664525 +% 1013904223;
}

/// Narrow to `int16` the way the reference's implicit conversion does: take the
/// low 16 bits and reinterpret them as signed.
inline fn asI16(v: i32) i32 {
    return @as(i16, @bitCast(@as(u16, @truncate(@as(u32, @bitCast(v))))));
}

/// `(16384 + (int16)a * (int16)b) >> 15`, the reference's Q15 multiply.
pub fn fracMul16(a: i32, b: i32) i32 {
    return (16384 + asI16(a) * asI16(b)) >> 15;
}

/// Integer cosine in Q15, bit-exact with the reference.
///
/// `x` is an angle in Q14: 0 is 0 rad and 16384 is pi/2. Every intermediate is
/// truncated to `int16`, exactly like the C source. Callers only pass angles in
/// `[64, 16320]` (the angle quantiser's smallest non-zero step), which is what
/// keeps those truncations in range; outside that window the reference would
/// wrap and so does this.
pub fn bitexactCos(x_in: i32) i32 {
    const x: i32 = asI16(x_in);
    var x2: i32 = asI16((4096 + x * x) >> 13);
    const inner = asI16(8277 + fracMul16(-626, x2));
    const mid = asI16(-7651 + fracMul16(x2, inner));
    x2 = asI16((32767 - x2) + fracMul16(x2, mid));
    return 1 + x2;
}

/// `log2(tan)` in Q11 of the angle `(isin, icos)`, without any float.
pub fn bitexactLog2tan(isin_in: i32, icos_in: i32) i32 {
    var isin = isin_in;
    var icos = icos_in;
    const lc: i32 = @intCast(range.ilog(@intCast(@max(icos, 1))));
    const ls: i32 = @intCast(range.ilog(@intCast(@max(isin, 1))));
    icos = asI16(icos << @intCast(15 - lc));
    isin = asI16(isin << @intCast(15 - ls));
    return (ls - lc) * (1 << 11) +
        fracMul16(isin, fracMul16(isin, -2597) + 7932) -
        fracMul16(icos, fracMul16(icos, -2597) + 7932);
}

/// Integer square root, bit-exact with the reference's shift-and-subtract.
pub fn isqrt32(val_in: u32) u32 {
    if (val_in == 0) return 0;
    var val = val_in;
    var g: u32 = 0;
    var bshift: i32 = @intCast((range.ilog(val) - 1) >> 1);
    var b: u32 = @as(u32, 1) << @intCast(bshift);
    while (true) {
        const t = ((g << 1) + b) << @intCast(bshift);
        if (t <= val) {
            g += b;
            val -= t;
        }
        b >>= 1;
        bshift -= 1;
        if (bshift < 0) break;
    }
    return g;
}

/// `cos(pi/2 * t)`, the reference's `celt_cos_norm`. Plain float: the spread
/// rotation is on the resynthesis side only and does not steer the bitstream.
pub fn cosNorm(t: f32) f32 {
    return @floatCast(@cos(@as(f64, std.math.pi) * 0.5 * @as(f64, t)));
}

test "bitexact cos hits the reference's landmarks" {
    // cos(0) = 1 in Q15 the reference way: the polynomial is exact at 0.
    try std.testing.expectEqual(@as(i32, 32767), bitexactCos(64));
    // 45 degrees: cos = 0.7071
    const c1 = bitexactCos(8192);
    try std.testing.expect(c1 > 23000 and c1 < 23300);
    // Just below pi/2: cos ~ 0.006
    const c2 = bitexactCos(16320);
    try std.testing.expect(c2 >= 0 and c2 < 400);
}

test "fracMul16 narrows its operands to 16 bits" {
    try std.testing.expectEqual(@as(i32, 32766), fracMul16(32767, 32767));
    try std.testing.expectEqual(@as(i32, 0), fracMul16(0, 12345));
    // 40000 truncates to -25536 as an int16, so both calls agree.
    try std.testing.expectEqual(fracMul16(-25536, 32767), fracMul16(40000, 32767));
}

test "isqrt32 rounds down" {
    try std.testing.expectEqual(@as(u32, 0), isqrt32(0));
    try std.testing.expectEqual(@as(u32, 1), isqrt32(1));
    try std.testing.expectEqual(@as(u32, 3), isqrt32(9));
    try std.testing.expectEqual(@as(u32, 3), isqrt32(15));
    try std.testing.expectEqual(@as(u32, 4), isqrt32(16));
    try std.testing.expectEqual(@as(u32, 46340), isqrt32(2147483647));
}

test "lcg matches the reference's first steps" {
    // 1664525 * 0 + 1013904223, then the classic next value.
    try std.testing.expectEqual(@as(u32, 1013904223), lcgRand(0));
    try std.testing.expectEqual(@as(u32, 1196435762), lcgRand(1013904223));
}

test "cosNorm is a cosine of a quarter turn" {
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), cosNorm(0.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), cosNorm(1.0), 1e-6);
}
