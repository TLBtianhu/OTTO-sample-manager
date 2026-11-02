//! IMA ADPCM (WAVE format tag 0x11) and Microsoft ADPCM (tag 0x0002) block
//! decoders.
//!
//! Both codecs are block-stateful: every block begins with a header that
//! resets predictor history, followed by 4-bit nibbles. A block is decoded
//! into interleaved i16 here; block framing, allocation and streaming stay in
//! `wav.zig`.
//!
//! The two decoders deliberately differ from a naive reading of the reference
//! prose, because the reference is ffmpeg's decoder and the tests demand
//! sample-exact agreement:
//!
//!   * IMA computes `diff = ((2 * (nibble & 7) + 1) * step) >> 3` in one
//!     multiply. The textbook sum-of-shifts (`step>>3 + ...`) truncates each
//!     term separately and drifts by a few LSB, then diverges through the
//!     feedback loop.
//!   * MS computes the predictor with a *truncating* division by 256, not an
//!     arithmetic shift: for negative sums `>> 8` floors, `/ 256` truncates
//!     toward zero. It also treats the nibble as signed two's complement
//!     (-8..+7), not as an 8-biased value.
//!   * MS reads coefficients from the `fmt ` extension (7 pairs in the
//!     standard table, parsed as `i16`); ffmpeg scales the same standard
//!     values by 1/4 and divides by 64, which is bit-identical whenever the
//!     file stores the standard table.
//!
//! IMA's per-channel header is `predictor: i16`, `step_index: u8`,
//! `reserved: u8`. The data that follows is laid out in groups of eight
//! samples: four bytes for channel 0, then four for channel 1, and so on.
//! Within a byte the low nibble is the earlier sample.
//!
//! MS's per-channel header is `predictor_index: u8`, `delta: i16`,
//! `sample1: i16`, `sample2: i16`, written field-by-field across channels
//! (all predictors, then all deltas, ...). Output starts with `sample2` then
//! `sample1`; data nibbles are high first and each byte holds one frame of a
//! mono or stereo stream.

const std = @import("std");
const types = @import("types.zig");

pub const Kind = enum { ima, ms };

/// The fmt extension of a WAVE ADPCM stream. MS stores up to 7 coefficient
/// pairs in practice; 16 is a generous cap that keeps `Params` plain data.
pub const max_coefficients = 16;

pub const Params = struct {
    kind: Kind,
    channels: u16,
    block_align: usize,
    /// MS only. Indexed by the block header's predictor index.
    coefficients: [max_coefficients][2]i16 = @splat(.{ 0, 0 }),
    coefficient_count: u8 = 0,
};

/// IMA/DVI step table (ITU-T G.721), 89 entries covering the 16-bit range.
const ima_step_table = [89]i32{
    7,     8,     9,     10,    11,    12,    13,    14,    16,    17,
    19,    21,    23,    25,    28,    31,    34,    37,    41,    45,
    50,    55,    60,    66,    73,    80,    88,    97,    107,   118,
    130,   143,   157,   173,   190,   209,   230,   253,   279,   307,
    337,   371,   408,   449,   494,   544,   598,   658,   724,   796,
    876,   963,   1060,  1166,  1282,  1411,  1552,  1707,  1878,  2066,
    2272,  2499,  2749,  3024,  3327,  3660,  4026,  4428,  4871,  5358,
    5894,  6484,  7132,  7845,  8630,  9493,  10442, 11487, 12635, 13899,
    15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767,
};

/// Index adjustment per nibble: -1, +2, +4, +6, +8 for the magnitude bits.
const ima_index_table = [16]i8{ -1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8 };

/// MS adaptation table, multiplied into the step size after every nibble.
const ms_adaptation_table = [16]i32{
    230, 230, 230, 230, 307, 409, 512, 614,
    768, 614, 512, 409, 307, 230, 230, 230,
};

/// Samples (frames) produced by a complete block, derived from its byte
/// length so a short trailing block decodes to a shorter count.
pub fn samplesForBlock(p: Params, block_len: usize) usize {
    const channels: usize = p.channels;
    if (channels == 0) return 0;
    if (block_len < headerBytes(p.kind, channels)) return 0;
    return switch (p.kind) {
        .ima => 1 + ((block_len - 4 * channels) / (4 * channels)) * 8,
        .ms => 2 + (block_len - 7 * channels) * 2 / channels,
    };
}

/// Total frames of a `data` payload made of `block_align`-sized blocks plus a
/// possible short final block.
pub fn framesForData(p: Params, data_bytes: u64) u64 {
    if (p.block_align == 0) return 0;
    const block: u64 = p.block_align;
    var frames = (data_bytes / block) * samplesForBlock(p, p.block_align);
    const rest = data_bytes % block;
    if (rest != 0) frames += samplesForBlock(p, @intCast(rest));
    return frames;
}

fn headerBytes(kind: Kind, channels: usize) usize {
    return switch (kind) {
        .ima => 4 * channels,
        .ms => 7 * channels,
    };
}

/// Decode one block. `out` must hold at least
/// `samplesForBlock(p, block.len) * channels` samples; the return value is the
/// number of frames written.
pub fn decodeBlock(p: Params, block: []const u8, out: []i16) types.Error!usize {
    return switch (p.kind) {
        .ima => decodeIma(p, block, out),
        .ms => decodeMs(p, block, out),
    };
}

// ---------------------------------------------------------------------------
// IMA ADPCM
// ---------------------------------------------------------------------------

const ImaChannel = struct {
    predictor: i32,
    step_index: u8,

    fn expand(self: *ImaChannel, nibble: u8) i16 {
        const step = ima_step_table[self.step_index];
        const index = @as(i32, self.step_index) + ima_index_table[nibble];
        const magnitude: i32 = nibble & 7;
        const diff = ((2 * magnitude + 1) * step) >> 3;

        var predictor = self.predictor;
        if (nibble & 8 != 0) {
            predictor -= diff;
        } else {
            predictor += diff;
        }
        self.predictor = std.math.clamp(predictor, -32768, 32767);
        self.step_index = @intCast(std.math.clamp(index, 0, 88));
        return @intCast(self.predictor);
    }
};

fn decodeIma(p: Params, block: []const u8, out: []i16) types.Error!usize {
    const channels: usize = p.channels;
    if (channels == 0 or channels > types.max_channels) return error.Unsupported;
    if (block.len < 4 * channels) return 0;

    var state: [types.max_channels]ImaChannel = undefined;
    for (0..channels) |c| {
        const off = 4 * c;
        const step_index = block[off + 2];
        if (step_index > 88) return error.Corrupt;
        state[c] = .{
            .predictor = std.mem.readInt(i16, block[off..][0..2], .little),
            .step_index = step_index,
        };
    }

    const frames = samplesForBlock(p, block.len);
    for (0..channels) |c| out[c] = @intCast(state[c].predictor);

    var frame: usize = 1;
    var offset: usize = 4 * channels;
    while (frame < frames) : (frame += 8) {
        for (0..channels) |c| {
            for (0..4) |j| {
                const byte = block[offset + c * 4 + j];
                // Low nibble is the earlier of the two samples.
                out[(frame + 2 * j) * channels + c] = state[c].expand(byte & 0x0F);
                out[(frame + 2 * j + 1) * channels + c] = state[c].expand(byte >> 4);
            }
        }
        offset += 4 * channels;
    }
    return frames;
}

// ---------------------------------------------------------------------------
// Microsoft ADPCM
// ---------------------------------------------------------------------------

const MsChannel = struct {
    delta: i32,
    sample1: i32,
    sample2: i32,
    coeff1: i32,
    coeff2: i32,

    fn expand(self: *MsChannel, nibble: u8) i16 {
        // The predictor is not clipped before the nibble term is added: a
        // clipped intermediate would turn a saturated history into a small
        // decoded sample, which ffmpeg never does.
        const sum = @as(i64, self.sample1) * self.coeff1 + @as(i64, self.sample2) * self.coeff2;
        const signed: i64 = if (nibble & 0x08 != 0) @as(i64, nibble) - 16 else nibble;
        const predictor = @divTrunc(sum, 256) + signed * self.delta;

        const sample: i32 = @intCast(std.math.clamp(predictor, -32768, 32767));
        self.sample2 = self.sample1;
        self.sample1 = sample;

        // Arithmetic shift, exactly as the reference: delta may be negative
        // only in a malformed header, and the floor keeps this identical.
        var next = (@as(i64, ms_adaptation_table[nibble]) * self.delta) >> 8;
        if (next < 16) next = 16;
        const ceiling = std.math.maxInt(i32) / 768;
        if (next > ceiling) next = ceiling;
        self.delta = @intCast(next);
        return @intCast(sample);
    }
};

fn decodeMs(p: Params, block: []const u8, out: []i16) types.Error!usize {
    const channels: usize = p.channels;
    if (channels == 0 or channels > 2) return error.Unsupported;
    if (p.coefficient_count == 0) return error.Corrupt;
    if (block.len < 7 * channels) return 0;

    var state: [2]MsChannel = undefined;
    var offset: usize = 0;

    // Header fields are written across channels, one field at a time.
    for (0..channels) |c| {
        const index = block[offset];
        offset += 1;
        if (index >= p.coefficient_count) return error.Corrupt;
        const coefficients = p.coefficients[index];
        state[c].coeff1 = coefficients[0];
        state[c].coeff2 = coefficients[1];
    }
    for (0..channels) |c| {
        state[c].delta = std.mem.readInt(i16, block[offset..][0..2], .little);
        offset += 2;
    }
    for (0..channels) |c| {
        state[c].sample1 = std.mem.readInt(i16, block[offset..][0..2], .little);
        offset += 2;
    }
    for (0..channels) |c| {
        state[c].sample2 = std.mem.readInt(i16, block[offset..][0..2], .little);
        offset += 2;
    }

    const frames = samplesForBlock(p, block.len);
    for (0..channels) |c| out[c] = @intCast(state[c].sample2);
    for (0..channels) |c| out[channels + c] = @intCast(state[c].sample1);

    var frame: usize = 2;
    while (frame < frames) : (frame += 1) {
        // Nibbles are packed two per byte across the interleaved stream: for
        // mono that is two consecutive frames, for stereo the two channels of
        // the same frame.
        for (0..channels) |c| {
            const nibble_index = (frame - 2) * channels + c;
            const byte = block[offset + nibble_index / 2];
            const nibble: u8 = if (nibble_index % 2 == 0) byte >> 4 else byte & 0x0F;
            out[frame * channels + c] = state[c].expand(nibble);
        }
    }
    return frames;
}

// ---------------------------------------------------------------------------
// `fmt ` extension parsing
// ---------------------------------------------------------------------------

/// Parse the WAVE `fmt ` extension for an ADPCM stream. `chunk` is the kept
/// prefix of the payload and `declared` its real length; both must cover the
/// extension fields this codec needs.
pub fn parseFmt(
    kind: Kind,
    channels: u16,
    block_align: usize,
    chunk: []const u8,
    declared: u32,
) types.Error!Params {
    if (declared < 18 or chunk.len < 18) return error.Corrupt;
    const cb_size = readU16(chunk, 16);
    if (cb_size < 2) return error.Corrupt;

    const minimum_block = headerBytes(kind, channels);
    if (block_align < minimum_block) return error.Corrupt;

    var params = Params{
        .kind = kind,
        .channels = channels,
        .block_align = block_align,
    };

    switch (kind) {
        .ima => {
            // The format extension's samples_per_block is redundant: the
            // nibble layout is fully determined by block_align and channels,
            // and ffmpeg derives its count the same way.
        },
        .ms => {
            if (channels > 2) return error.Unsupported;
            if (declared < 22 or chunk.len < 22) return error.Corrupt;
            const coefficient_count = readU16(chunk, 20);
            if (coefficient_count == 0) return error.Corrupt;
            if (coefficient_count > max_coefficients) return error.Unsupported;
            const needed: usize = 22 + 4 * @as(usize, coefficient_count);
            const declared_len: usize = @intCast(declared);
            if (declared_len < needed or chunk.len < needed) return error.Corrupt;
            const needed_cb: u16 = @intCast(4 + 4 * @as(usize, coefficient_count));
            if (cb_size < needed_cb) return error.Corrupt;

            params.coefficient_count = @intCast(coefficient_count);
            for (0..@as(usize, coefficient_count)) |i| {
                const off = 22 + 4 * i;
                params.coefficients[i] = .{
                    std.mem.readInt(i16, chunk[off..][0..2], .little),
                    std.mem.readInt(i16, chunk[off + 2 ..][0..2], .little),
                };
            }
        },
    }
    return params;
}

fn readU16(bytes: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, bytes[off..][0..2], .little);
}
