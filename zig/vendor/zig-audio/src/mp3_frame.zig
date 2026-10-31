//! One MPEG-1 Layer III granule: side-info structures, scalefactors,
//! requantization, reordering and the hand-off to the synthesis filter.

const std = @import("std");
const types = @import("types.zig");
const tables = @import("mp3_tables.zig");
const bits = @import("mp3_bits.zig");
const huff = @import("mp3_huffman.zig");
const synth = @import("mp3_synth.zig");

pub const Error = types.Error;

pub const GranuleInfo = struct {
    part2_3_length: u16,
    big_values: u16,
    global_gain: u8,
    scalefac_compress: u8,
    block_type: u2,
    mixed: bool,
    table_select: [3]u8,
    subblock_gain: [3]u8,
    region0: u8,
    region1: u8,
    preflag: bool,
    scalefac_scale: u1,
    count1table_select: u1,
    /// Only granule 1 carries scfsi bits; granule 0 transmits everything.
    scfsi: u8,
};

pub const SideInfo = struct {
    main_data_begin: u16,
    /// `[granule][channel]`. A mono frame uses channel 0 only; an MPEG-1
    /// stereo frame has four blocks, granule-major: gr0ch0, gr0ch1, gr1ch0,
    /// gr1ch1 -- not channel-major.
    granules: [2][2]GranuleInfo,
};

/// MPEG-1 side info is 17 bytes for one channel and 32 for two: 9
/// main_data_begin bits, 5 (mono) or 3 (stereo) private bits, 4 scfsi bits
/// *per channel*, then 59 bits per granule/channel block.
pub fn parseSideInfo(si: []const u8, channels: usize) Error!SideInfo {
    const len: usize = if (channels == 2) 32 else 17;
    if (si.len < len) return error.Corrupt;
    var br = bits.BitReader.init(si[0..len]);
    var side: SideInfo = std.mem.zeroes(SideInfo);
    side.main_data_begin = @intCast(br.read(9));
    _ = br.read(if (channels == 2) 3 else 5); // private bits
    var scfsi: [2]u8 = .{ 0, 0 };
    for (0..channels) |ch| scfsi[ch] = @intCast(br.read(4));

    for (0..2) |g| {
        for (0..channels) |ch| {
            side.granules[g][ch] = try parseGranule(&br, if (g == 1) scfsi[ch] else 0);
        }
    }
    if (br.pos != len * 8) return error.Corrupt;
    return side;
}

fn parseGranule(br: *bits.BitReader, scfsi: u8) Error!GranuleInfo {
    var info: GranuleInfo = undefined;
    info.part2_3_length = @intCast(br.read(12));
    info.big_values = @intCast(br.read(9));
    if (info.big_values > 288) return error.Corrupt;
    info.global_gain = @intCast(br.read(8));
    info.scalefac_compress = @intCast(br.read(4));
    info.scfsi = scfsi;
    info.preflag = false;
    info.scalefac_scale = 0;
    info.count1table_select = 0;
    info.region0 = 0;
    info.region1 = 0;
    info.subblock_gain = .{ 0, 0, 0 };
    info.table_select = .{ 0, 0, 0 };

    if (br.read(1) != 0) {
        info.block_type = @intCast(br.read(2));
        if (info.block_type == 0) return error.Corrupt;
        info.mixed = br.read(1) != 0;
        info.table_select[0] = @intCast(br.read(5));
        info.table_select[1] = @intCast(br.read(5));
        info.table_select[2] = 0;
        for (0..3) |i| info.subblock_gain[i] = @intCast(br.read(3));
    } else {
        info.block_type = 0;
        info.mixed = false;
        for (0..3) |i| info.table_select[i] = @intCast(br.read(5));
        info.region0 = @intCast(br.read(4));
        info.region1 = @intCast(br.read(3));
    }
    info.preflag = br.read(1) != 0;
    info.scalefac_scale = @intCast(br.read(1));
    info.count1table_select = @intCast(br.read(1));
    return info;
}

fn exponentScale(exponent: i32) f32 {
    const clamped = std.math.clamp(exponent, -512, 511);
    return tables.two_pow_q[@intCast(clamped + 512)];
}

fn dequant(magnitude: u16, exponent: i32, negative: bool) f32 {
    const table_value = tables.pow43[@min(magnitude, 8207)];
    const v = table_value * exponentScale(exponent);
    return if (negative) -v else v;
}

/// Read one channel's scalefactors into `out_sf[0..39]`.
///
/// `out_sf` doubles as the `scfsi` history: granule 1 is handed the same array
/// as `prev`, so a "reuse" group reads back what granule 0 stored there.
fn readScaleFactors(
    gi: *const GranuleInfo,
    br: *bits.BitReader,
    prev: ?*const [22]u8,
    out_sf: *[40]u8,
) void {
    const sf = out_sf;
    const slen1 = tables.slen1[gi.scalefac_compress & 15];
    const slen2 = tables.slen2[gi.scalefac_compress & 15];

    if (gi.block_type == 2) {
        var j: usize = 0;
        const n: usize = if (gi.mixed) 17 else 18;
        for (0..n) |_| {
            sf[j] = @intCast(br.read(@intCast(slen1)));
            j += 1;
        }
        for (0..18) |_| {
            sf[j] = @intCast(br.read(@intCast(slen2)));
            j += 1;
        }
        for (0..3) |_| {
            sf[j] = 0;
            j += 1;
        }
    } else {
        var j: usize = 0;
        for (0..4) |group| {
            const n: usize = if (group == 0) 6 else 5;
            const reuse = (gi.scfsi & (@as(u8, 0x8) >> @intCast(group))) != 0;
            if (reuse and prev != null) {
                for (0..n) |i| sf[j + i] = prev.?[j + i];
            } else {
                const width = if (group < 2) slen1 else slen2;
                for (0..n) |i| sf[j + i] = @intCast(br.read(@intCast(width)));
            }
            j += n;
        }
        // 6 + 5 + 5 + 5 = 21 scalefactors are transmitted for a long block; the
        // 22nd band's scalefactor is implicit and always zero. Leaving the slot
        // untouched would let it hold the previous granule's value.
        sf[21] = 0;
    }
}

fn fillExponents(
    gi: *const GranuleInfo,
    sr_idx: usize,
    sf: *const [40]u8,
    exp: *[576]i16,
    gain_bias: i32,
) void {
    // ISO 11172-3 2.4.3.4.8: exponent = global_gain - 210 - 8*subblock_gain
    //            - 2*(scalefac_scale+1)*scalefac, in quarter-exponent units.
    // The scalefactor step is 2^(0.5*(1+scalefac_scale)) -- half a power of two
    // at scalefac_scale=0 -- not a whole one. Using 4*shift here squares the
    // attenuation and was the audible window-switching bug: long blocks with
    // all-zero scalefactors were unaffected, every short block was quiet.
    //
    // `gain_bias` carries the -2 quarter-steps a mid/side-only frame needs: the
    // encoder normalises M and S by 1/sqrt(2), which the decoder folds into the
    // global gain rather than scaling the spectrum after requantization.
    const gain: i32 = @as(i32, gi.global_gain) - 210 + gain_bias;
    const shift: i32 = @as(i32, gi.scalefac_scale) + 1;
    var line: usize = 0;

    if (gi.block_type == 2) {
        var k: usize = 0;
        if (gi.mixed) {
            for (0..8) |sfb| {
                const width = tables.band_long[sr_idx][sfb];
                const s = @as(i32, sf[sfb]) + (if (gi.preflag) @as(i32, tables.pretab[sfb]) else 0);
                const e = gain - 2 * shift * s;
                for (0..width) |_| {
                    exp[line] = @intCast(e);
                    line += 1;
                }
            }
            k = 8;
        }
        const first_band: usize = if (gi.mixed) 3 else 0;
        for (first_band..13) |sfb| {
            const width = tables.band_short[sr_idx][sfb];
            for (0..3) |win| {
                const e = gain - 8 * @as(i32, gi.subblock_gain[win]) - 2 * shift * @as(i32, sf[k]);
                k += 1;
                for (0..width) |_| {
                    exp[line] = @intCast(e);
                    line += 1;
                }
            }
        }
    } else {
        for (0..22) |sfb| {
            const width = tables.band_long[sr_idx][sfb];
            const scale = if (sfb < 21) sf[sfb] else 0;
            const s = @as(i32, scale) + (if (gi.preflag) @as(i32, tables.pretab[sfb]) else 0);
            const e = gain - 2 * shift * s;
            for (0..width) |_| {
                exp[line] = @intCast(e);
                line += 1;
            }
        }
    }
}

fn pairOffsets(sr_idx: usize) [23]u16 {
    var out: [23]u16 = undefined;
    out[0] = 0;
    for (0..22) |i| {
        out[i + 1] = out[i] + tables.band_long[sr_idx][i] / 2;
    }
    return out;
}

fn decodeHuffman(
    gi: *const GranuleInfo,
    sr_idx: usize,
    data: []const u8,
    start: usize,
    end: usize,
    exp: *const [576]i16,
    xr: *[576]f32,
) Error!void {
    var br = bits.BitReader.initWindow(data, start, end);
    var line: usize = 0;
    const offsets = pairOffsets(sr_idx);

    // Huffman region boundaries, in big-value pairs. Long blocks take the two
    // transmitted region counts. Window-switched granules do not transmit them:
    // the first region always ends after `region_count[0] + 1` scalefactor
    // bands, which for block_type 2 is 9 chunks (36 lines) and for start/stop
    // 8 long bands (36 lines) -- 18 pairs either way. Table 2 is never used.
    // Leaving region0/region1 at zero here once sent pairs 2.. onward through
    // the zero table, which silently truncated every start/stop granule.
    var region1: u16 = 18;
    var region2: u16 = 288;
    if (gi.block_type == 0) {
        region1 = offsets[@min(@as(usize, gi.region0) + 1, 22)];
        region2 = offsets[@min(@as(usize, gi.region0) + @as(usize, gi.region1) + 2, 22)];
    }

    var pair: usize = 0;
    while (pair < gi.big_values and line + 1 < 576 and br.pos < end) : (pair += 1) {
        const table_index: usize = if (pair < region1) 0 else if (pair < region2) 1 else 2;
        var ts = gi.table_select[table_index];
        if (gi.block_type == 2 and ts > 31) ts = 0;
        const symbol = huff.decodePair(ts, &br);
        var x: u16 = symbol >> 4;
        var y: u16 = symbol & 15;
        const lb = huff.linbits(ts);
        if (x == 15) x += @intCast(br.read(@intCast(lb)));
        if (x != 0) {
            xr[line] = dequant(x, exp[line], br.readBit() != 0);
        } else {
            xr[line] = 0;
        }
        line += 1;
        if (y == 15) y += @intCast(br.read(@intCast(lb)));
        if (y != 0) {
            xr[line] = dequant(y, exp[line], br.readBit() != 0);
        } else {
            xr[line] = 0;
        }
        line += 1;
    }

    while (line + 3 < 576 and br.pos < end) {
        const quad = huff.decodeQuad(gi.count1table_select, &br);
        for (0..4) |b| {
            if ((quad & (@as(u4, 8) >> @intCast(b))) != 0) {
                xr[line + b] = if (br.readBit() != 0)
                    -exponentScale(exp[line + b])
                else
                    exponentScale(exp[line + b]);
            } else {
                xr[line + b] = 0;
            }
        }
        line += 4;
    }

    while (line < 576) : (line += 1) xr[line] = 0;
    br.pos = end;
}

fn reorder(xr: *[576]f32, sr_idx: usize, mixed: bool) void {
    const start_band: usize = if (mixed) 3 else 0;
    var base: usize = if (mixed) 36 else 0;
    for (start_band..13) |sfb| {
        const width = tables.band_short[sr_idx][sfb];
        // 3 windows of `width` lines; the widest band is 66 (48 kHz), so the
        // scratch has to hold 3 * 66, not one subband's 18.
        var tmp: [3 * 66]f32 = undefined;
        for (0..width) |j| {
            for (0..3) |win| tmp[3 * j + win] = xr[base + win * width + j];
        }
        for (0..3 * width) |i| xr[base + i] = tmp[i];
        base += 3 * width;
    }
}

/// Per-channel decoder state that outlives one granule: the IMDCT overlap
/// half, the polyphase synthesis delay line and the previous granule's long
/// scalefactors (for `scfsi`).
pub const ChannelState = struct {
    overlap: [32][18]f32 = @splat(@splat(0)),
    synth_state: synth.SynthState = .{},
};

/// Decode one channel block into 576 requantized spectral lines.
///
/// The lines come out in the order the Huffman decoder produced them: for a
/// window-switched granule that is still the interleaved short-block layout, so
/// `renderChannel` owns the reordering step. Joint stereo runs between the two
/// functions, on exactly this layout (ISO 11172-3 2.4.3.4.9).
pub fn decodeSpectrum(
    gi: *const GranuleInfo,
    sr_idx: usize,
    data: []const u8,
    start: usize,
    end: usize,
    prev_sf: ?*const [22]u8,
    out_sf: *[40]u8,
    xr: *[576]f32,
    /// Added to `global_gain`, in quarter exponents. A mid/side-only frame
    /// passes -2 so both channels come out of requantization 3 dB low; the
    /// mid/side sum then restores the level.
    gain_bias: i32,
) Error!void {
    if (start > end or end > data.len * 8) return error.Corrupt;

    var br = bits.BitReader.initWindow(data, start, end);
    readScaleFactors(gi, &br, prev_sf, out_sf);
    var exp: [576]i16 = undefined;
    fillExponents(gi, sr_idx, out_sf, &exp, gain_bias);
    try decodeHuffman(gi, sr_idx, data, br.pos, end, &exp, xr);
}

/// Reorder, de-alias, inverse-transform and synthesize one channel's granule.
///
/// Samples are written to `out[base + i * stride]`, so a stereo frame can be
/// interleaved in place (`stride` 2, `base` 0 or 1). `out_f32`, when non-null,
/// receives the same samples before the fixed-point conversion; the SNR tests
/// compare it against ffmpeg's `-f f32le` output.
pub fn renderChannel(
    gi: *const GranuleInfo,
    sr_idx: usize,
    xr: *[576]f32,
    state: *ChannelState,
    out: []i16,
    out_f32: ?[]f32,
    base: usize,
    stride: usize,
) void {
    if (gi.block_type == 2) {
        reorder(xr, sr_idx, gi.mixed);
        if (gi.mixed) synth.aliasReduce(xr, 1);
    } else {
        synth.aliasReduce(xr, 31);
    }

    var pcm: [576]f32 = undefined;
    synth.imdctGranule(xr, gi.block_type, gi.mixed, &state.overlap, &pcm);
    var samples: [576]f32 = undefined;
    state.synth_state.process(&pcm, &samples);
    for (samples, 0..) |value, i| {
        if (out_f32) |dst| dst[base + i * stride] = value;
        var scaled = value * 32768.0;
        if (std.math.isNan(scaled)) scaled = 0;
        out[base + i * stride] = @intFromFloat(std.math.clamp(scaled, -32768.0, 32767.0));
    }
}

test "mono side info is exactly 136 bits" {
    var raw: [17]u8 = @splat(0);
    const side = try parseSideInfo(&raw, 1);
    try std.testing.expectEqual(@as(u16, 0), side.main_data_begin);
}

fn setBits(bytes: []u8, start: usize, n: usize, value: u32) void {
    for (0..n) |i| {
        const bit: u8 = @intCast((value >> @intCast(n - 1 - i)) & 1);
        const pos = start + i;
        const shift: u3 = @intCast(pos % 8);
        const mask: u8 = @as(u8, 0x80) >> shift;
        if (bit != 0) bytes[pos / 8] |= mask else bytes[pos / 8] &= ~mask;
    }
}

test "stereo side info is four 59-bit blocks, granule-major" {
    var raw: [32]u8 = @splat(0);
    // Block b starts at bit 20 (9 main_data_begin + 3 private + 8 scfsi) plus
    // b * 59. big_values sits 12 bits in, global_gain 21 bits in.
    setBits(&raw, 20 + 59 + 12, 9, 7); // gr0ch1 big_values
    setBits(&raw, 20 + 118 + 21, 8, 99); // gr1ch0 global_gain
    const side = try parseSideInfo(&raw, 2);
    try std.testing.expectEqual(@as(u16, 0), side.granules[0][0].big_values);
    try std.testing.expectEqual(@as(u16, 7), side.granules[0][1].big_values);
    try std.testing.expectEqual(@as(u8, 0), side.granules[0][0].global_gain);
    try std.testing.expectEqual(@as(u8, 99), side.granules[1][0].global_gain);
    try std.testing.expectEqual(@as(u8, 0), side.granules[1][1].global_gain);
}

test "pair offsets end at 288 pairs" {
    for (0..3) |sr| try std.testing.expectEqual(@as(u16, 288), pairOffsets(sr)[22]);
}
