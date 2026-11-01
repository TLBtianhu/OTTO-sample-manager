//! The CELT frame decoder: one packet's worth of range-coded CELT data in, one
//! frame of float PCM out.
//!
//! This file is the sequence, and the sequence is the format. RFC 6716 Table 56
//! lists the symbols in bitstream order; every one of them changes how many bits
//! the next one costs, so the order is not a style choice:
//!
//!   1. silence flag, then the pitch post-filter parameters;
//!   2. transient flag, then the intra flag;
//!   3. coarse energy, then the per-band time/frequency flags;
//!   4. spreading, band boosts, allocation trim, anti-collapse reservation;
//!   5. the allocation itself (which decodes the skip, intensity and dual
//!      stereo flags on the way);
//!   6. fine energy, then the band shapes;
//!   7. the anti-collapse bit, then whatever bits are left go to fine energy.
//!
//! The frame is stereo in the bitstream (`stream_channels`, from the TOC's
//! `s` bit) even when the output is mono, and vice versa: the two counts are
//! independent, and the decoder both downmixes and upmixes.
//!
//! State that survives a frame is small but all of it matters: the per-channel
//! overlap history, the two previous log-envelopes (anti-collapse reads frame
//! N-1 and N-2), the post-filter's period/gain history, the de-emphasis memory,
//! and the range decoder's final state, which seeds the next frame's folding
//! noise.

const std = @import("std");
const tables = @import("opus_celt_tables.zig");
const range = @import("opus_range.zig");
const energy = @import("opus_celt_energy.zig");
const alloc_mod = @import("opus_celt_alloc.zig");
const bands_mod = @import("opus_celt_bands.zig");
const frame_mod = @import("opus_celt_frame.zig");
const post_mod = @import("opus_celt_post.zig");
const dsp = @import("opus_celt_dsp.zig");
const pvq = @import("opus_celt_pvq.zig");

pub const Error = error{ Corrupt, Unsupported };

/// CELT's history buffer, in samples, before the current frame.
const decode_buffer_size: usize = 2048;
/// Total samples kept per channel.
const history = decode_buffer_size + tables.overlap;
/// Largest frame in samples.
pub const max_frame = tables.max_frame;

/// Output of one decoded frame.
pub const Frame = struct {
    pcm: []f32,
    samples: usize,
};

pub const Decoder = struct {
    allocator: std.mem.Allocator,
    /// Output channels (1 or 2).
    channels: u8,
    /// Channels coded in the current frame (from the TOC).
    stream_channels: u8,
    start: usize = 0,
    end: usize = tables.bands,
    disable_inv: bool,

    decode_mem: [2][history]f32 = @splat(@splat(0.0)),
    preemph_mem: [2]f32 = .{ 0.0, 0.0 },
    old_band_e: [2 * tables.bands]f32 = @splat(0.0),
    old_log_e: [2 * tables.bands]f32 = @splat(-28.0),
    old_log_e2: [2 * tables.bands]f32 = @splat(-28.0),

    pf_period: i32 = 0,
    pf_period_old: i32 = 0,
    pf_gain: f32 = 0,
    pf_gain_old: f32 = 0,
    pf_tapset: usize = 0,
    pf_tapset_old: usize = 0,

    rng: u32 = 0,

    // Per-frame scratch.
    pulses: [tables.bands]i32 = @splat(0),
    ebits: [tables.bands]i32 = @splat(0),
    fine_priority: [tables.bands]i32 = @splat(0),
    caps: [tables.bands]i32 = @splat(0),
    offsets: [tables.bands]i32 = @splat(0),
    tf_res: [tables.bands]i32 = @splat(0),
    collapse_masks: [2 * tables.bands]u8 = @splat(0),
    coeffs: [2 * tables.max_frame]f32 = @splat(0.0),
    freq: [tables.max_frame]f32 = @splat(0.0),
    freq2: [tables.max_frame]f32 = @splat(0.0),
    scratch: alloc_mod.Scratch = .{},
    ws: bands_mod.Workspace = .{},
    mdct_ws: dsp.MdctWorkspace = .{},
    pcm: [2 * tables.max_frame]f32 = @splat(0.0),

    pub fn init(allocator: std.mem.Allocator, channels: u8) Error!*Decoder {
        const self = allocator.create(Decoder) catch return error.Unsupported;
        self.* = .{
            .allocator = allocator,
            .channels = channels,
            .stream_channels = channels,
            .disable_inv = channels == 1,
        };
        return self;
    }

    pub fn deinit(self: *Decoder) void {
        self.allocator.destroy(self);
    }

    /// Drop all decoder state, as if the stream restarted. This is the
    /// reference's "flush" (`ff_celt_flush`), which is what a stream that
    /// leaves CELT for SILK and comes back sees: the overlap history, the
    /// post-filter and the folding seed go to zero, the *current* envelope goes
    /// to zero (it is the next inter frame's prediction) and both past
    /// envelopes go to silence.
    pub fn reset(self: *Decoder) void {
        @memset(std.mem.asBytes(&self.decode_mem), 0);
        self.preemph_mem = .{ 0.0, 0.0 };
        self.old_band_e = @splat(0.0);
        self.old_log_e = @splat(energy.energy_silence);
        self.old_log_e2 = @splat(energy.energy_silence);
        self.pf_period = 0;
        self.pf_period_old = 0;
        self.pf_gain = 0;
        self.pf_gain_old = 0;
        self.pf_tapset = 0;
        self.pf_tapset_old = 0;
        self.rng = 0;
    }

    /// Decode one CELT frame of `frame_size` samples (120/240/480/960) from
    /// `data`, and write interleaved float PCM into `out_pcm`.
    ///
    /// `stream_channels` comes from the packet's TOC bit and may differ from
    /// the output channel count.
    pub fn decodeFrame(
        self: *Decoder,
        data: []const u8,
        frame_size: usize,
        stream_channels: u8,
    ) Error!void {
        var dec = range.Decoder.init(data);
        try self.decodeFrameWithEc(&dec, frame_size, stream_channels);
    }

    /// Same, but continuing a range decoder that already carries state: a
    /// hybrid packet's SILK half consumed the first bits of the *same*
    /// arithmetic coder, so CELT must start where SILK stopped. `dec.buf` is
    /// the CELT payload (the reference excludes a trailing redundancy section
    /// from its storage, which also fixes the raw-bit tail and the frame's bit
    /// budget).
    pub fn decodeFrameWithEc(
        self: *Decoder,
        dec: *range.Decoder,
        frame_size: usize,
        stream_channels: u8,
    ) Error!void {
        const total_bits_in: i32 = @intCast(dec.buf.len * 8);
        if (dec.buf.len == 0 or dec.buf.len > 1275) return error.Corrupt;
        if (frame_size != 120 and frame_size != 240 and frame_size != 480 and frame_size != 960) {
            return error.Unsupported;
        }
        if (stream_channels == 0 or stream_channels > 2) return error.Corrupt;
        self.stream_channels = stream_channels;
        const c_ch: usize = stream_channels;
        const out_ch: usize = self.channels;
        const cc_ch: usize = out_ch;

        var lm: u3 = 0;
        while ((@as(usize, 1) << lm) * tables.short_mdct != frame_size) : (lm += 1) {}
        const m = @as(usize, 1) << lm;
        const n = frame_size;

        // A mono decoder keeps its energy history in channel 0 only.
        if (c_ch == 1) {
            for (0..tables.bands) |i| {
                self.old_band_e[i] = @max(self.old_band_e[i], self.old_band_e[tables.bands + i]);
            }
        }

        var tell = dec.tell();
        var silence = false;
        if (tell >= total_bits_in) {
            silence = true;
        } else if (tell == 1) {
            silence = dec.decodeBitLogp(15) == 1;
        }
        if (silence) {
            dec.skipToEnd(total_bits_in);
            tell = total_bits_in;
        }

        var postfilter_gain: f32 = 0;
        var postfilter_pitch: i32 = 0;
        var postfilter_tapset: usize = 0;
        if (self.start == 0 and tell + 16 <= total_bits_in) {
            if (dec.decodeBitLogp(1) == 1) {
                const octave = dec.decodeUint(6);
                const fine_bits: u5 = @intCast(4 + octave);
                postfilter_pitch = @as(i32, 16) << @intCast(octave);
                postfilter_pitch += @intCast(dec.decodeBits(fine_bits));
                postfilter_pitch -= 1;
                const qg = dec.decodeBits(3);
                if (dec.tell() + 2 <= total_bits_in) {
                    postfilter_tapset = dec.decodeIcdf(&tables.tapset_icdf, 2);
                }
                postfilter_gain = 0.09375 * @as(f32, @floatFromInt(qg + 1));
            }
            tell = dec.tell();
        }

        var is_transient = false;
        if (lm > 0 and tell + 3 <= total_bits_in) {
            is_transient = dec.decodeBitLogp(3) == 1;
            tell = dec.tell();
        }
        const short_blocks: usize = if (is_transient) m else 0;

        const intra_ener = tell + 3 <= total_bits_in and dec.decodeBitLogp(3) == 1;
        energy.unquantCoarseEnergy(self.start, self.end, &self.old_band_e, intra_ener, dec, c_ch, lm);

        self.decodeTf(is_transient, lm, dec, total_bits_in);

        tell = dec.tell();
        var spread: u8 = pvq.spread_normal;
        if (tell + 4 <= total_bits_in) spread = @intCast(dec.decodeIcdf(&tables.spread_icdf, 5));

        alloc_mod.initCaps(&self.caps, lm, c_ch);

        // Band boosts.
        var dynalloc_logp: u5 = 6;
        var total_bits: i32 = total_bits_in << range.bitres;
        var tell_frac = dec.tellFrac();
        for (self.start..self.end) |i| {
            const width: i32 = @as(i32, @intCast(c_ch)) * tables.freq_range[i] << lm;
            const quanta: i32 = @min(width << range.bitres, @max(6 << range.bitres, width));
            var loop_logp = dynalloc_logp;
            var boost: i32 = 0;
            while (tell_frac + @as(u32, loop_logp) * (1 << range.bitres) < @as(u32, @intCast(total_bits)) and
                boost < self.caps[i])
            {
                const flag = dec.decodeBitLogp(loop_logp);
                tell_frac = dec.tellFrac();
                if (flag == 0) break;
                boost += quanta;
                total_bits -= quanta;
                loop_logp = 1;
            }
            self.offsets[i] = boost;
            if (boost > 0) dynalloc_logp = @max(2, dynalloc_logp - 1);
        }

        const alloc_trim: i32 = if (tell_frac + (6 << range.bitres) <= @as(u32, @intCast(total_bits)))
            @intCast(dec.decodeIcdf(&tables.trim_icdf, 7))
        else
            5;

        var bits: i32 = total_bits_in << range.bitres;
        bits -= @intCast(dec.tellFrac());
        bits -= 1;
        const anti_collapse_rsv: i32 = if (is_transient and lm >= 2 and
            bits >= (@as(i32, lm) + 2) << range.bitres) 1 << range.bitres else 0;
        bits -= anti_collapse_rsv;

        const result = alloc_mod.computeAllocation(
            self.start,
            self.end,
            &self.offsets,
            &self.caps,
            alloc_trim,
            bits,
            &self.pulses,
            &self.ebits,
            &self.fine_priority,
            c_ch,
            lm,
            dec,
            &self.scratch,
        );

        energy.unquantFineEnergy(self.start, self.end, &self.old_band_e, &self.ebits, dec, c_ch);

        // Slide the overlap history down by one frame.
        for (0..cc_ch) |c| {
            std.mem.copyForwards(
                f32,
                self.decode_mem[c][0 .. decode_buffer_size - n + tables.overlap / 2],
                self.decode_mem[c][n..][0 .. decode_buffer_size - n + tables.overlap / 2],
            );
        }

        @memset(self.coeffs[0 .. c_ch * n], 0);
        const bp = frame_mod.BandParams{
            .start = self.start,
            .end = self.end,
            .channels = c_ch,
            .lm = lm,
            .short_blocks = short_blocks,
            .spread = spread,
            .dual_stereo = result.dual_stereo,
            .intensity = result.intensity,
            .tf_res = &self.tf_res,
            .total_bits = total_bits_in * (1 << range.bitres) - anti_collapse_rsv,
            .balance = result.balance,
            .coded_bands = result.coded_bands,
            .disable_inv = self.disable_inv,
            .dec = dec,
        };
        self.rng = frame_mod.quantAllBands(bp, self.coeffs[0 .. c_ch * n], &self.collapse_masks, &self.pulses, self.rng, &self.ws);

        var anti_collapse_on = false;
        if (anti_collapse_rsv > 0) anti_collapse_on = dec.decodeBits(1) != 0;

        energy.unquantEnergyFinalise(
            self.start,
            self.end,
            &self.old_band_e,
            &self.ebits,
            &self.fine_priority,
            total_bits_in - dec.tell(),
            dec,
            c_ch,
        );

        if (anti_collapse_on) {
            _ = post_mod.antiCollapse(
                &self.coeffs,
                &self.collapse_masks,
                lm,
                c_ch,
                n,
                self.start,
                self.end,
                &self.old_band_e,
                &self.old_log_e,
                &self.old_log_e2,
                &self.pulses,
                self.rng,
            );
        }

        if (silence) {
            for (0..c_ch * tables.bands) |i| self.old_band_e[i] = energy.energy_silence;
        }

        self.synthesis(c_ch, cc_ch, is_transient, lm, silence);

        // Post-filter, in two stages so a changed pitch/gain interpolates.
        for (0..cc_ch) |c| {
            self.pf_period = @max(self.pf_period, 15);
            self.pf_period_old = @max(self.pf_period_old, 15);
            const off = decode_buffer_size - n;
            dsp.combFilter(
                &self.decode_mem[c],
                off,
                self.pf_period_old,
                self.pf_period,
                tables.short_mdct,
                self.pf_gain_old,
                self.pf_gain,
                self.pf_tapset_old,
                self.pf_tapset,
                tables.overlap,
            );
            if (lm != 0) {
                dsp.combFilter(
                    &self.decode_mem[c],
                    off + tables.short_mdct,
                    self.pf_period,
                    postfilter_pitch,
                    n - tables.short_mdct,
                    self.pf_gain,
                    postfilter_gain,
                    self.pf_tapset,
                    postfilter_tapset,
                    tables.overlap,
                );
            }
        }
        self.pf_period_old = self.pf_period;
        self.pf_gain_old = self.pf_gain;
        self.pf_tapset_old = self.pf_tapset;
        self.pf_period = postfilter_pitch;
        self.pf_gain = postfilter_gain;
        self.pf_tapset = postfilter_tapset;
        if (lm != 0) {
            self.pf_period_old = self.pf_period;
            self.pf_gain_old = self.pf_gain;
            self.pf_tapset_old = self.pf_tapset;
        }

        if (c_ch == 1) @memcpy(self.old_band_e[tables.bands..], self.old_band_e[0..tables.bands]);

        if (!is_transient) {
            @memcpy(self.old_log_e2[0 .. 2 * tables.bands], self.old_log_e[0 .. 2 * tables.bands]);
            @memcpy(self.old_log_e[0 .. 2 * tables.bands], self.old_band_e[0 .. 2 * tables.bands]);
        } else {
            for (0..2 * tables.bands) |i| {
                self.old_log_e[i] = @min(self.old_log_e[i], self.old_band_e[i]);
            }
        }
        for (0..2) |c| {
            for (0..self.start) |i| {
                self.old_band_e[c * tables.bands + i] = 0;
                self.old_log_e[c * tables.bands + i] = -28.0;
                self.old_log_e2[c * tables.bands + i] = -28.0;
            }
            for (self.end..tables.bands) |i| {
                self.old_band_e[c * tables.bands + i] = 0;
                self.old_log_e[c * tables.bands + i] = -28.0;
                self.old_log_e2[c * tables.bands + i] = -28.0;
            }
        }
        self.rng = dec.rng;

        const off = decode_buffer_size - n;
        for (0..cc_ch) |c| {
            dsp.deemphasis(
                &self.pcm,
                &self.decode_mem[c],
                off,
                n,
                cc_ch,
                c,
                &self.preemph_mem[c],
            );
        }
    }

    fn decodeTf(self: *Decoder, is_transient: bool, lm: u3, dec: *range.Decoder, total_bits: i32) void {
        const transient: usize = @intFromBool(is_transient);
        var logp: u5 = if (is_transient) 2 else 4;
        var tell = dec.tell();
        const tf_select_rsv = lm > 0 and tell + @as(i32, logp) + 1 <= total_bits;
        const budget = total_bits - @as(i32, @intFromBool(tf_select_rsv));

        var curr: i32 = 0;
        var tf_changed: i32 = 0;
        for (self.start..self.end) |i| {
            if (tell + @as(i32, logp) <= budget) {
                curr ^= @as(i32, dec.decodeBitLogp(logp));
                tell = dec.tell();
                tf_changed |= curr;
            }
            self.tf_res[i] = curr;
            logp = if (is_transient) 4 else 5;
        }

        var tf_select: usize = 0;
        if (tf_select_rsv and
            tables.tf_select_table[lm][4 * transient + @as(usize, @intCast(tf_changed))] !=
                tables.tf_select_table[lm][4 * transient + 2 + @as(usize, @intCast(tf_changed))])
        {
            tf_select = dec.decodeBitLogp(1);
        }
        for (self.start..self.end) |i| {
            const idx = 4 * transient + 2 * tf_select + @as(usize, @intCast(self.tf_res[i]));
            self.tf_res[i] = tables.tf_select_table[lm][idx];
        }
    }

    /// IMDCT and overlap-add for each coded channel.
    fn synthesis(self: *Decoder, c_ch: usize, cc_ch: usize, is_transient: bool, lm: u3, silence: bool) void {
        const m = @as(usize, 1) << lm;
        const n = m * tables.short_mdct;
        const out_off = decode_buffer_size - n;

        var blocks: usize = 1;
        var nb: usize = n;
        var shift: u3 = tables.max_lm - lm;
        if (is_transient) {
            blocks = m;
            nb = tables.short_mdct;
            shift = tables.max_lm;
        }
        const eff_end = @min(self.end, tables.bands);

        if (cc_ch == 2 and c_ch == 1) {
            post_mod.denormaliseBands(&self.coeffs, &self.freq, self.old_band_e[0..], self.start, eff_end, m, silence);
            @memcpy(&self.freq2, &self.freq);
            for (0..blocks) |b| {
                dsp.mdctBackward(shift, self.freq2[b..], blocks, self.decode_mem[1][out_off + nb * b ..], &self.mdct_ws);
            }
            for (0..blocks) |b| {
                dsp.mdctBackward(shift, self.freq[b..], blocks, self.decode_mem[0][out_off + nb * b ..], &self.mdct_ws);
            }
        } else if (cc_ch == 1 and c_ch == 2) {
            post_mod.denormaliseBands(&self.coeffs, &self.freq, self.old_band_e[0..], self.start, eff_end, m, silence);
            post_mod.denormaliseBands(self.coeffs[n..], &self.freq2, self.old_band_e[tables.bands..], self.start, eff_end, m, silence);
            for (0..n) |i| self.freq[i] = 0.5 * self.freq[i] + 0.5 * self.freq2[i];
            for (0..blocks) |b| {
                dsp.mdctBackward(shift, self.freq[b..], blocks, self.decode_mem[0][out_off + nb * b ..], &self.mdct_ws);
            }
        } else {
            for (0..cc_ch) |c| {
                post_mod.denormaliseBands(
                    self.coeffs[c * n ..],
                    &self.freq,
                    self.old_band_e[c * tables.bands ..],
                    self.start,
                    eff_end,
                    m,
                    silence,
                );
                for (0..blocks) |b| {
                    dsp.mdctBackward(shift, self.freq[b..], blocks, self.decode_mem[c][out_off + nb * b ..], &self.mdct_ws);
                }
            }
        }
    }

    /// Interleaved float PCM of the frame just decoded.
    pub fn pcmFrame(self: *Decoder, samples: usize) []f32 {
        return self.pcm[0 .. samples * self.channels];
    }
};

test "decoder state starts silent and can be reset" {
    var dec = try Decoder.init(std.testing.allocator, 2);
    defer dec.deinit();
    try std.testing.expectEqual(@as(u32, 0), dec.rng);
    dec.rng = 12345;
    dec.reset();
    try std.testing.expectEqual(@as(u32, 0), dec.rng);
    try std.testing.expectEqual(@as(f32, -28.0), dec.old_log_e[0]);
}

test "a decode with a degenerate frame fails cleanly" {
    var dec = try Decoder.init(std.testing.allocator, 2);
    defer dec.deinit();
    try std.testing.expectError(error.Corrupt, dec.decodeFrame(&.{}, 960, 2));
    try std.testing.expectError(error.Unsupported, dec.decodeFrame(&.{ 0, 0, 0 }, 0, 2));
    try std.testing.expectError(error.Unsupported, dec.decodeFrame(&.{ 0, 0, 0, 0 }, 100, 2));
    try std.testing.expectError(error.Corrupt, dec.decodeFrame(&.{ 0, 0, 0 }, 960, 3));
}
