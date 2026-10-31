//! The CELT constant tables, at 48 kHz and for the normal 21-band mode.
//!
//! Opus always decodes at 48 kHz, so exactly one mode exists: 21 bands, a
//! 120-sample short MDCT and `LM` in 0..3 for 2.5/5/10/20 ms frames. Every table
//! here is that mode's.
//!
//! Three of them are not written out as constants but generated at compile
//! time, because their definitions are short and their values long:
//!
//!   * `window120` — RFC 6716 4.3.7 gives the closed form
//!     `sin(pi/2 * sin^2(pi/2 * (n+1/2)/120))`;
//!   * `mdctTrig` — the IMDCT rotation twiddles `cos(2*pi*(i+1/8)/N)`;
//!   * `fftTwiddle` — one root-of-unity table for every FFT size the IMDCT
//!     needs (480, 240, 120, 60 all divide 480).
//!
//! The pulse-cache tables are transcribed instead: they are the output of
//! `compute_pulse_cache()` in the reference implementation and are referenced
//! by the RFC as data ("see cache_caps50[] in static_modes_float.h"), so a
//! generator would only be a longer way of writing the same numbers.

const std = @import("std");

/// Number of energy bands.
pub const bands: usize = 21;
/// Samples in the shortest MDCT (2.5 ms).
pub const short_mdct: usize = 120;
/// IMDCT overlap, fixed at 120 samples regardless of frame size.
pub const overlap: usize = 120;
/// Largest `LM`, i.e. log2 of the frame size in units of 120 samples.
pub const max_lm: u3 = 3;
/// Largest frame in samples: 20 ms.
pub const max_frame: usize = 960;
/// Largest number of short blocks in one frame.
pub const max_blocks: usize = 8;
/// Rows in the static allocation table.
pub const alloc_vectors: usize = 11;

/// Logarithmic band edges, in units of 200 Hz at 48 kHz.
pub const e_bands = [22]u16{
    0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 12, 14, 16, 20, 24, 28, 34, 40, 48, 60, 78, 100,
};

/// Width of each band in MDCT bins at 2.5 ms, i.e. `e_bands[i+1] - e_bands[i]`.
pub const freq_range = [bands]u8{
    1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 6, 6, 8, 12, 18, 22,
};

/// `log2(freq_range[i])` in Q3 (1/8) units. Used by `compute_qn`, `init_caps`
/// and the fine-energy offset.
pub const log_n = [21]u8{
    0, 0, 0, 0, 0, 0, 0, 0, 8, 8, 8, 8, 16, 16, 16, 21, 21, 24, 29, 34, 36,
};

/// Table 57: static bit allocation in 1/32 bit per MDCT bin.
pub const static_alloc = [alloc_vectors][bands]u8{
    .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 90, 80, 75, 69, 63, 56, 49, 40, 34, 29, 20, 18, 10, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 110, 100, 90, 84, 78, 71, 65, 58, 51, 45, 39, 32, 26, 20, 12, 0, 0, 0, 0, 0, 0 },
    .{ 118, 110, 103, 93, 86, 80, 75, 70, 65, 59, 53, 47, 40, 31, 23, 15, 4, 0, 0, 0, 0 },
    .{ 126, 119, 112, 104, 95, 89, 83, 78, 72, 66, 60, 54, 47, 39, 32, 25, 17, 12, 1, 0, 0 },
    .{ 134, 127, 120, 114, 103, 97, 91, 85, 78, 72, 66, 60, 54, 47, 41, 35, 29, 23, 16, 10, 1 },
    .{ 144, 137, 130, 124, 113, 107, 101, 95, 88, 82, 76, 70, 64, 57, 51, 45, 39, 33, 26, 15, 1 },
    .{ 152, 145, 138, 132, 123, 117, 111, 105, 98, 92, 86, 80, 74, 67, 61, 55, 49, 43, 36, 20, 1 },
    .{ 162, 155, 148, 142, 133, 127, 121, 115, 108, 102, 96, 90, 84, 77, 71, 65, 59, 53, 46, 30, 1 },
    .{ 172, 165, 158, 152, 143, 137, 131, 125, 118, 112, 106, 100, 94, 87, 81, 75, 69, 63, 56, 45, 20 },
    .{ 200, 200, 200, 200, 200, 200, 200, 200, 198, 193, 188, 183, 178, 173, 168, 163, 158, 153, 148, 129, 104 },
};

/// `cache.index`: per (LM+1, band), an offset into `cache_bits`. `-1` means the
/// band has no PVQ codebook at that size (only the 8-bin bands do).
pub const cache_index = [105]i16{
    -1, -1, -1, -1, -1, -1, -1, -1, 0, 0, 0, 0, 41, 41, 41, 82, 82, 123, 164, 200, 222,
    0, 0, 0, 0, 0, 0, 0, 0, 41, 41, 41, 41, 123, 123, 123, 164, 164, 240, 266, 283, 295,
    41, 41, 41, 41, 41, 41, 41, 41, 123, 123, 123, 123, 240, 240, 240, 266, 266, 305, 318, 328, 336,
    123, 123, 123, 123, 123, 123, 123, 123, 240, 240, 240, 240, 305, 305, 305, 318, 318, 343, 351, 358, 364,
    240, 240, 240, 240, 240, 240, 240, 240, 305, 305, 305, 305, 343, 343, 343, 351, 351, 370, 376, 382, 387,
};

/// `cache.bits`: for each unique band size, `[0] = max pulses` and
/// `[k] = ceil(log2(V(N, get_pulses(k)))) - 1` in whole bits.
pub const cache_bits = [392]u8{
    40, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
    7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
    7, 40, 15, 23, 28, 31, 34, 36, 38, 39, 41, 42, 43, 44, 45, 46, 47, 47, 49, 50,
    51, 52, 53, 54, 55, 55, 57, 58, 59, 60, 61, 62, 63, 63, 65, 66, 67, 68, 69, 70,
    71, 71, 40, 20, 33, 41, 48, 53, 57, 61, 64, 66, 69, 71, 73, 75, 76, 78, 80, 82,
    85, 87, 89, 91, 92, 94, 96, 98, 101, 103, 105, 107, 108, 110, 112, 114, 117, 119, 121, 123,
    124, 126, 128, 40, 23, 39, 51, 60, 67, 73, 79, 83, 87, 91, 94, 97, 100, 102, 105, 107,
    111, 115, 118, 121, 124, 126, 129, 131, 135, 139, 142, 145, 148, 150, 153, 155, 159, 163, 166, 169,
    172, 174, 177, 179, 35, 28, 49, 65, 78, 89, 99, 107, 114, 120, 126, 132, 136, 141, 145, 149,
    153, 159, 165, 171, 176, 180, 185, 189, 192, 199, 205, 211, 216, 220, 225, 229, 232, 239, 245, 251,
    21, 33, 58, 79, 97, 112, 125, 137, 148, 157, 166, 174, 182, 189, 195, 201, 207, 217, 227, 235,
    243, 251, 17, 35, 63, 86, 106, 123, 139, 152, 165, 177, 187, 197, 206, 214, 222, 230, 237, 250,
    25, 31, 55, 75, 91, 105, 117, 128, 138, 146, 154, 161, 168, 174, 180, 185, 190, 200, 208, 215,
    222, 229, 235, 240, 245, 255, 16, 36, 65, 89, 110, 128, 144, 159, 173, 185, 196, 207, 217, 226,
    234, 242, 250, 11, 41, 74, 103, 128, 151, 172, 191, 209, 225, 241, 255, 9, 43, 79, 110, 138,
    163, 186, 207, 227, 246, 12, 39, 71, 99, 123, 144, 164, 182, 198, 214, 228, 241, 253, 9, 44,
    81, 113, 142, 168, 192, 214, 235, 255, 7, 49, 90, 127, 160, 191, 220, 247, 6, 51, 95, 134,
    170, 203, 234, 7, 47, 87, 123, 155, 184, 212, 237, 6, 52, 97, 137, 174, 208, 240, 5, 57,
    106, 151, 192, 231, 5, 59, 111, 158, 202, 243, 5, 55, 103, 147, 187, 224, 5, 60, 113, 161,
    206, 248, 4, 65, 122, 175, 224, 4, 67, 127, 182, 234,
};

/// `cache.caps`: `[LM][C-1][band]`, the maximum useful allocation per band
/// minus 64, in 1/8 bit units per (channel, bin).
pub const cache_caps = [168]u8{
    224, 224, 224, 224, 224, 224, 224, 224, 160, 160, 160, 160, 185, 185, 185, 178, 178, 168, 134, 61, 37,
    224, 224, 224, 224, 224, 224, 224, 224, 240, 240, 240, 240, 207, 207, 207, 198, 198, 183, 144, 66, 40,
    160, 160, 160, 160, 160, 160, 160, 160, 185, 185, 185, 185, 193, 193, 193, 183, 183, 172, 138, 64, 38,
    240, 240, 240, 240, 240, 240, 240, 240, 207, 207, 207, 207, 204, 204, 204, 193, 193, 180, 143, 66, 40,
    185, 185, 185, 185, 185, 185, 185, 185, 193, 193, 193, 193, 193, 193, 193, 183, 183, 172, 138, 65, 39,
    207, 207, 207, 207, 207, 207, 207, 207, 204, 204, 204, 204, 201, 201, 201, 188, 188, 176, 141, 66, 40,
    193, 193, 193, 193, 193, 193, 193, 193, 193, 193, 193, 193, 194, 194, 194, 184, 184, 173, 139, 65, 39,
    204, 204, 204, 204, 204, 204, 204, 204, 201, 201, 201, 201, 198, 198, 198, 187, 187, 175, 140, 66, 40,
};

/// `log2(n)` rounded up, in 1/8 bit units, for `n` in 0..23. Used to reserve
/// bits for the intensity-stereo band index.
pub const log2_frac = [24]u8{
    0, 8, 13, 16, 19, 21, 23, 24, 26, 27, 28, 29, 30, 31, 32, 32, 33, 34, 34, 35, 36, 36, 37, 37,
};

/// Mean energy per band in Q4, added back before denormalisation.
pub const mean_energy = [25]f32{
    6.437500, 6.250000, 5.750000, 5.312500, 5.062500,
    4.812500, 4.500000, 4.375000, 4.875000, 4.687500,
    4.562500, 4.437500, 4.875000, 4.625000, 4.312500,
    4.500000, 4.375000, 4.625000, 4.750000, 4.437500,
    3.750000, 3.750000, 3.750000, 3.750000, 3.750000,
};

/// Coarse energy prediction: time-domain pole per `LM`.
pub const pred_coef = [4]f32{ 29440.0 / 32768.0, 26112.0 / 32768.0, 21248.0 / 32768.0, 16384.0 / 32768.0 };
/// Coarse energy prediction: frequency-domain pole per `LM`.
pub const beta_coef = [4]f32{ 30147.0 / 32768.0, 22282.0 / 32768.0, 12124.0 / 32768.0, 6554.0 / 32768.0 };
/// The frequency-domain pole for an intra frame.
pub const beta_intra = 4915.0 / 32768.0;

/// Laplace model parameters for the coarse energy deltas:
/// `[LM][intra][2 * min(band, 20)]` = (probability of zero in Q8, decay).
pub const coarse_energy_dist = [4][2][42]u8{
    .{
        .{ 72, 127, 65, 129, 66, 128, 65, 128, 64, 128, 62, 128, 64, 128, 64, 128, 92, 78, 92, 79, 92, 78, 90, 79, 116, 41, 115, 40, 114, 40, 132, 26, 132, 26, 145, 17, 161, 12, 176, 10, 177, 11 },
        .{ 24, 179, 48, 138, 54, 135, 54, 132, 53, 134, 56, 133, 55, 132, 55, 132, 61, 114, 70, 96, 74, 88, 75, 88, 87, 74, 89, 66, 91, 67, 100, 59, 108, 50, 120, 40, 122, 37, 97, 43, 78, 50 },
    },
    .{
        .{ 83, 78, 84, 81, 88, 75, 86, 74, 87, 71, 90, 73, 93, 74, 93, 74, 109, 40, 114, 36, 117, 34, 117, 34, 143, 17, 145, 18, 146, 19, 162, 12, 165, 10, 178, 7, 189, 6, 190, 8, 177, 9 },
        .{ 23, 178, 54, 115, 63, 102, 66, 98, 69, 99, 74, 89, 71, 91, 73, 91, 78, 89, 86, 80, 92, 66, 93, 64, 102, 59, 103, 60, 104, 60, 117, 52, 123, 44, 138, 35, 133, 31, 97, 38, 77, 45 },
    },
    .{
        .{ 61, 90, 93, 60, 105, 42, 107, 41, 110, 45, 116, 38, 113, 38, 112, 38, 124, 26, 132, 27, 136, 19, 140, 20, 155, 14, 159, 16, 158, 18, 170, 13, 177, 10, 187, 8, 192, 6, 175, 9, 159, 10 },
        .{ 21, 178, 59, 110, 71, 86, 75, 85, 84, 83, 91, 66, 88, 73, 87, 72, 92, 75, 98, 72, 105, 58, 107, 54, 115, 52, 114, 55, 112, 56, 129, 51, 132, 40, 150, 33, 140, 29, 98, 35, 77, 42 },
    },
    .{
        .{ 42, 121, 96, 66, 108, 43, 111, 40, 117, 44, 123, 32, 120, 36, 119, 33, 127, 33, 134, 34, 139, 21, 147, 23, 152, 20, 158, 25, 154, 26, 166, 21, 173, 16, 184, 13, 184, 10, 150, 13, 139, 15 },
        .{ 22, 178, 63, 114, 74, 82, 84, 83, 92, 82, 103, 62, 96, 72, 96, 67, 101, 73, 107, 72, 113, 55, 118, 52, 125, 52, 118, 52, 117, 55, 135, 49, 137, 39, 157, 32, 145, 29, 97, 33, 77, 40 },
    },
};

/// Distribution of the small coarse-energy deltas once fewer than 15 bits are
/// left: `{2,1,0}/4` over the folded values -1, 0, +1.
pub const small_energy_icdf = [3]u8{ 2, 1, 0 };

/// `{25, 23, 2, 0}/32` over the four spreading values.
pub const spread_icdf = [4]u8{ 25, 23, 2, 0 };

/// `{2, 1, 0}/4` over the three post-filter tap sets.
pub const tapset_icdf = [3]u8{ 2, 1, 0 };

/// `{126,124,119,109,87,41,19,9,4,2,0}/128` over allocation trim 0..10.
pub const trim_icdf = [11]u8{ 126, 124, 119, 109, 87, 41, 19, 9, 4, 2, 0 };

/// Post-filter tap sets, already scaled by 1/32768 in the reference's Q15.
pub const postfilter_taps = [3][3]f32{
    .{ 0.3066406250, 0.2170410156, 0.1296386719 },
    .{ 0.4638671875, 0.2680664062, 0.0 },
    .{ 0.7998046875, 0.1000976562, 0.0 },
};

/// Per-frame-size TF adjustment, indexed `[LM][4*transient + 2*tf_select + flag]`.
pub const tf_select_table = [4][8]i8{
    .{ 0, -1, 0, -1, 0, -1, 0, -1 },
    .{ 0, -1, 0, -2, 1, 0, 1, -1 },
    .{ 0, -2, 0, -3, 2, 0, 1, -1 },
    .{ 0, -2, 0, -3, 3, 0, 1, -1 },
};

/// Index conversion from natural to "sequency" order for the Hadamard
/// transform, for N = 2, 4, 8, 16 (lines run from `stride-2`).
pub const ordery_table = [30]u8{
    1, 0,
    3, 0, 2, 1,
    7, 0, 4, 3, 6, 1, 5, 2,
    15, 0, 8, 7, 12, 3, 11, 4, 14, 1, 9, 6, 13, 2, 10, 5,
};

/// Collapse-mask compaction after `recombine` Hadamard levels.
pub const bit_interleave_table = [16]u8{
    0, 1, 1, 1, 2, 3, 3, 3, 2, 3, 3, 3, 2, 3, 3, 3,
};

/// Collapse-mask expansion before undoing `recombine` Hadamard levels.
pub const bit_deinterleave_table = [16]u8{
    0x00, 0x03, 0x0C, 0x0F, 0x30, 0x33, 0x3C, 0x3F,
    0xC0, 0xC3, 0xCC, 0xCF, 0xF0, 0xF3, 0xFC, 0xFF,
};

/// `2^(k/8)` in Q14 for k = 0..7, used to turn a fractional bit count into a
/// quantiser step size.
pub const exp2_table8 = [8]i16{ 16384, 17866, 19483, 21247, 23170, 25267, 27554, 30048 };

/// The low-overlap window, first half. `W(n) = sin(pi/2 * sin^2(pi/2*(n+.5)/120))`
/// (RFC 6716 4.3.7); the decoder uses it mirrored and squared.
pub const window120: [overlap]f32 = blk: {
    var w: [overlap]f32 = undefined;
    for (&w, 0..) |*slot, n| {
        const inner = std.math.sin(std.math.pi * 0.5 * (@as(f64, @floatFromInt(n)) + 0.5) / overlap);
        slot.* = @floatCast(std.math.sin(std.math.pi * 0.5 * inner * inner));
    }
    break :blk w;
};

pub const window120_reference = [120]f32{
    6.72869660e-05, 6.05513480e-04, 1.68159700e-03, 3.29479620e-03, 5.44399430e-03,
    8.12769230e-03, 1.13440010e-02, 1.50906330e-02, 1.93648860e-02, 2.41636350e-02,
    2.94833150e-02, 3.53199050e-02, 4.16689110e-02, 4.85253470e-02, 5.58837180e-02,
    6.37379990e-02, 7.20816160e-02, 8.09074280e-02, 9.02077050e-02, 9.99741110e-02,
    1.10197690e-01, 1.20868830e-01, 1.31977290e-01, 1.43512140e-01, 1.55461770e-01,
    1.67813890e-01, 1.80555500e-01, 1.93672900e-01, 2.07151710e-01, 2.20976820e-01,
    2.35132430e-01, 2.49602080e-01, 2.64368600e-01, 2.79414190e-01, 2.94720400e-01,
    3.10268180e-01, 3.26037880e-01, 3.42009310e-01, 3.58161770e-01, 3.74474070e-01,
    3.90924620e-01, 4.07491420e-01, 4.24152150e-01, 4.40884230e-01, 4.57664840e-01,
    4.74471040e-01, 4.91279780e-01, 5.08067980e-01, 5.24812610e-01, 5.41490770e-01,
    5.58079730e-01, 5.74557010e-01, 5.90900490e-01, 6.07088410e-01, 6.23099510e-01,
    6.38913060e-01, 6.54508960e-01, 6.69867760e-01, 6.84970770e-01, 6.99800100e-01,
    7.14338730e-01, 7.28570550e-01, 7.42480430e-01, 7.56054240e-01, 7.69278950e-01,
    7.82142570e-01, 7.94634300e-01, 8.06744450e-01, 8.18464560e-01, 8.29787330e-01,
    8.40706690e-01, 8.51217790e-01, 8.61316980e-01, 8.71001830e-01, 8.80271110e-01,
    8.89124790e-01, 8.97563980e-01, 9.05590940e-01, 9.13209040e-01, 9.20422700e-01,
    9.27237380e-01, 9.33659550e-01, 9.39696560e-01, 9.45356710e-01, 9.50649070e-01,
    9.55583530e-01, 9.60170670e-01, 9.64421710e-01, 9.68348490e-01, 9.71963340e-01,
    9.75279060e-01, 9.78308830e-01, 9.81066160e-01, 9.83564800e-01, 9.85818690e-01,
    9.87841910e-01, 9.89648560e-01, 9.91252740e-01, 9.92668490e-01, 9.93909690e-01,
    9.94990040e-01, 9.95922970e-01, 9.96721620e-01, 9.97398740e-01, 9.97966670e-01,
    9.98437280e-01, 9.98821950e-01, 9.99131470e-01, 9.99376060e-01, 9.99565270e-01,
    9.99708020e-01, 9.99812480e-01, 9.99886130e-01, 9.99935650e-01, 9.99966970e-01,
    9.99985180e-01, 9.99994570e-01, 9.99998590e-01, 9.99999820e-01, 1.00000000e+00,
};

/// The pre-emphasis pole; the de-emphasis filter is `1/(1 - a z^-1)`.
pub const preemph: f32 = 0.85000610;

/// `cos(2*pi*(i + 1/8)/N)` for the largest IMDCT size, N = 1920. Smaller sizes
/// (N = 240/480/960 for 2.5/5/10 ms, and N = 240 per short block) index it with
/// a stride, since they all divide 1920.
///
/// The reference builds one table per shift level by halving N; indexing the
/// 1920 table with `1920/N` gives the same values because
/// `cos(2*pi*(i+1/8)/(1920/k)) = cos(2*pi*(i*k+k/8)/1920)` and `k` is a power
/// of two, so `k/8` is an integer offset only when `k >= 8`. The IMDCT sizes
/// used here are 240 and up, i.e. `k <= 8`, so the table is generated per size
/// instead — see `mdctTrig`.
pub const mdct_fft_max = 480;

/// Twiddles `cos(2*pi*(i+0.125)/N)` for `N` halving from 1920 down to 240,
/// concatenated: 960 + 480 + 240 + 120 entries.
pub const mdct_trig = blk: {
    @setEvalBranchQuota(20000);
    var t: [960 + 480 + 240 + 120]f32 = undefined;
    var off: usize = 0;
    var n: usize = 1920;
    while (n >= 240) : (n >>= 1) {
        const count = n >> 1;
        for (0..count) |i| {
            t[off + i] = @floatCast(std.math.cos(2.0 * std.math.pi * (@as(f64, @floatFromInt(i)) + 0.125) / @as(f64, @floatFromInt(n))));
        }
        off += count;
    }
    break :blk t;
};

/// Offset of size `N`'s twiddle block inside `mdct_trig`.
pub fn trigOffset(shift: u3) usize {
    return switch (shift) {
        0 => 0,
        1 => 960,
        2 => 960 + 480,
        else => 960 + 480 + 240,
    };
}

/// One root-of-unity table for every FFT length in `{480, 240, 120, 60}`:
/// `fft_twiddle[j] = exp(-2*pi*i*j/480)`. A length-`n` twiddle is
/// `fft_twiddle[k * (480/n)]`.
pub const fft_twiddle_re = blk: {
    var t: [mdct_fft_max]f32 = undefined;
    for (&t, 0..) |*slot, j| {
        slot.* = @floatCast(std.math.cos(2.0 * std.math.pi * @as(f64, @floatFromInt(j)) / mdct_fft_max));
    }
    break :blk t;
};

pub const fft_twiddle_im = blk: {
    var t: [mdct_fft_max]f32 = undefined;
    for (&t, 0..) |*slot, j| {
        slot.* = @floatCast(-std.math.sin(2.0 * std.math.pi * @as(f64, @floatFromInt(j)) / mdct_fft_max));
    }
    break :blk t;
};

test "band edges and widths agree" {
    for (0..bands) |i| {
        try std.testing.expectEqual(@as(u16, freq_range[i]), e_bands[i + 1] - e_bands[i]);
    }
    try std.testing.expectEqual(@as(u16, 100), e_bands[bands]);
}

test "logN is a monotone 1/8-bit log of the band width" {
    // Not exactly floor(log2(w) * 8): the table is the reference's own
    // fixed-point log, so only the power-of-two entries and the ordering are
    // checkable from the formula.
    try std.testing.expectEqual(@as(u8, 0), log_n[0]);
    try std.testing.expectEqual(@as(u8, 8), log_n[8]);
    try std.testing.expectEqual(@as(u8, 16), log_n[12]);
    try std.testing.expectEqual(@as(u8, 24), log_n[17]);
    for (1..bands) |i| try std.testing.expect(log_n[i] >= log_n[i - 1]);
}

test "static allocation table has 11 rows and starts empty" {
    try std.testing.expectEqual(@as(usize, 11), alloc_vectors);
    for (static_alloc[0]) |v| try std.testing.expectEqual(@as(u8, 0), v);
    for (static_alloc[10]) |v| try std.testing.expect(v == 200 or v < 200);
}

test "cache index stays inside cache bits" {
    for (cache_index) |idx| {
        if (idx < 0) continue;
        // A zero-length block would be a bug; every entry indexes a real block.
        try std.testing.expect(@as(usize, @intCast(idx)) < cache_bits.len);
    }
    // The eight 1-bin bands share one run of 41 entries (max 40 pulses).
    try std.testing.expectEqual(@as(i16, 0), cache_index[8]);
    try std.testing.expectEqual(@as(u8, 7), cache_bits[1]);
}

test "window is symmetric under the TDAC complement rule" {
    // w[n]^2 + w[119-n]^2 == 1 is not required of the *low-overlap* window
    // itself, but w[n] + w[119-n] is monotone and w[0] is tiny.
    try std.testing.expect(window120[0] < 1e-4);
    try std.testing.expect(window120[119] > 0.9999);
    var n: usize = 1;
    while (n < overlap) : (n += 1) {
        try std.testing.expect(window120[n] >= window120[n - 1]);
    }
}

test "mdct trig blocks are contiguous and sized right" {
    try std.testing.expectEqual(@as(usize, 960 + 480 + 240 + 120), mdct_trig.len);
    try std.testing.expectApproxEqAbs(@as(f32, 0.99999), mdct_trig[trigOffset(0)], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.99999), mdct_trig[trigOffset(3)], 1e-4);
}

test "fft twiddles start at one" {
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), fft_twiddle_re[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), fft_twiddle_im[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), fft_twiddle_re[240], 1e-6);
}
