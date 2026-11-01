//! The SILK layer: speech decoding for Opus configurations 0-11.
//!
//! SILK is a predictive coder: a short-term LPC filter plus a long-term (pitch)
//! predictor, driven by a sparse pulse excitation. The bitstream order is
//! normative (RFC 6716 4.2.3-4.2.7) because every field changes how many bits
//! the next one costs:
//!
//!   1. for each Opus frame: the VAD flags, one per SILK frame, then the LBRR
//!      flag; 40 and 60 ms frames add a per-frame LBRR bitmap;
//!   2. the LBRR frames, if any (decoded for their bits only — nothing is
//!      synthesised from them);
//!   3. per 20 ms frame: stereo weights and the mid-only flag (stereo only),
//!      the frame type (inactive / unvoiced / voiced, plus the quantisation
//!      offset), four subframe gains, the LSF indices, the interpolation
//!      offset, pitch lag and LTP taps, the LTP scale, then the excitation;
//!   4. synthesis: re-whitening across a coefficient change, LTP, LPC, clip.
//!
//! The decoder is fixed point where the format is fixed point (gain, LSF,
//! pitch, excitation) and float where the reference synthesis is float. That
//! mix is not a compromise: the acceptance target is ffmpeg's native decoder,
//! whose SILK implementation is exactly this — integer parameter decoding,
//! float LPC synthesis. Using libopus's all-fixed-point synthesis instead would
//! be "a correct SILK decoder" that disagrees with the comparison target by
//! ~40 dB, because the two differ in every sample's last few bits.
//!
//! One SILK-only Opus packet holds 10, 20, 40 or 60 ms, i.e. one, one, two or
//! three 20 ms SILK frames. Everything below works in SILK frames; the caller
//! sees one block of samples per packet at the bandwidth's own rate and
//! resamples it with `opus_silk_resample.zig`.

const std = @import("std");
const types = @import("opus_silk_types.zig");
const range = @import("opus_range.zig");
const lpc = @import("opus_silk_lpc.zig");
const cdf = @import("opus_silk_tables_cdf.zig");
const lsf_tables = @import("opus_silk_tables_lsf.zig");
const pitch_tables = @import("opus_silk_tables_pitch.zig");

pub const Error = error{Corrupt};

pub const Bandwidth = types.Bandwidth;
pub const history = types.history;
pub const max_frame = types.max_frame;
const ltp_order = types.ltp_order;
const max_lag = types.max_lag;

/// Per-subframe parameters, gathered before synthesis.
const Subframe = struct {
    gain: f32 = 0.0,
    pitch_lag: i32 = 0,
    ltp_taps: [ltp_order]f32 = @splat(0.0),
};

pub const Decoder = struct {
    /// Channels the stream asks for (1 or 2). With mono output only the mid
    /// channel is synthesised.
    output_channels: u8,
    /// Channels coded in the current frame (from the packet's stereo flag).
    coded_channels: u8 = 1,
    prev_coded_channels: u8 = 0,

    bandwidth: Bandwidth = .narrow,
    wb: bool = false,
    /// 5 ms subframes in one 20 ms SILK frame: always 4.
    subframes: usize = 4,
    /// Samples per subframe at the bandwidth's rate.
    sflength: usize = 40,
    /// Samples per 20 ms SILK frame.
    flength: usize = 160,

    midonly: bool = false,
    /// 0..3 when the first two subframes interpolate from the previous frame,
    /// 4 when they do not.
    interp_factor: i32 = 4,
    frames: [2]types.Frame = .{ .{}, .{} },
    stereo_weights: [2]f32 = .{ 0.0, 0.0 },
    prev_stereo_weights: [2]f32 = .{ 0.0, 0.0 },

    /// One SILK frame's excitation plus the LTP lookback it reads.
    residual: [max_lag + history]f32 = @splat(0.0),
    /// Excitation in Q23 while it is being assembled (16 samples per shell
    /// block, at most 20 blocks).
    excitation: [320]i32 = @splat(0),
    pulse_count: [20]u8 = @splat(0),
    lsb_count: [20]u8 = @splat(0),

    pub fn init(output_channels: u8) Decoder {
        return .{ .output_channels = output_channels };
    }

    /// Drop all state, as if the stream restarted.
    pub fn reset(self: *Decoder) void {
        for (&self.frames) |*frame| frame.* = .{};
        self.stereo_weights = .{ 0.0, 0.0 };
        self.prev_stereo_weights = .{ 0.0, 0.0 };
        self.midonly = false;
        self.prev_coded_channels = 0;
    }

    /// Decode one Opus frame's SILK data. `out[0]` (and `out[1]` for stereo)
    /// receive `nb_frames * flength` samples at the bandwidth's rate; the
    /// return value is that count. The caller resamples.
    pub fn decodeSuperframe(
        self: *Decoder,
        rc: *range.Decoder,
        out: [2][]f32,
        bandwidth: Bandwidth,
        coded_channels: u8,
        duration_ms: u32,
    ) Error!usize {
        if (coded_channels == 0 or coded_channels > 2 or duration_ms > 60) return error.Corrupt;

        const nb_frames: usize = 1 + @as(usize, @intFromBool(duration_ms > 20)) + @as(usize, @intFromBool(duration_ms > 40));
        self.subframes = @intCast(duration_ms / nb_frames / 5);
        self.sflength = bandwidth.subframeSamples();
        self.flength = self.sflength * self.subframes;
        const needed = nb_frames * self.flength;
        if (needed > out[0].len or needed > out[1].len) return error.Corrupt;
        self.bandwidth = bandwidth;
        self.wb = bandwidth == .wide;

        // A side channel that was not there before has no history to continue.
        if (coded_channels > self.prev_coded_channels) self.frames[1].flush();
        self.prev_coded_channels = coded_channels;

        var active: [2][6]u8 = @splat(@splat(0));
        var redundancy: [2]u8 = .{ 0, 0 };
        for (0..coded_channels) |ch| {
            for (0..nb_frames) |f| active[ch][f] = @intCast(rc.decodeBitLogp(1));
            redundancy[ch] = @intCast(rc.decodeBitLogp(1));
        }

        // LBRR (low bit rate redundancy) frames: only 40 and 60 ms packets can
        // carry more than one, and each needs a bitmap. They are decoded for
        // their bits — the samples they describe duplicate an earlier frame, so
        // nothing is synthesised from them.
        for (0..coded_channels) |ch| {
            if (redundancy[ch] != 0 and duration_ms > 20) {
                const model = if (duration_ms == 40) &cdf.model_lbrr_flags_40 else &cdf.model_lbrr_flags_60;
                redundancy[ch] = @intCast(rc.decodeCdf(model));
            }
        }

        for (0..nb_frames) |f| {
            for (0..coded_channels) |ch| {
                if (redundancy[ch] & (@as(u8, 1) << @intCast(f)) != 0) {
                    const active1: u8 = if (ch == 0 and (redundancy[1] & (@as(u8, 1) << @intCast(f))) == 0) 0 else 1;
                    self.decodeFrame(rc, f, ch, coded_channels, 1, active1, true);
                }
            }
            self.midonly = false;
        }

        for (0..nb_frames) |f| {
            var ch: usize = 0;
            while (ch < coded_channels and !self.midonly) : (ch += 1) {
                self.decodeFrame(rc, f, ch, coded_channels, active[ch][f], active[1][f], false);
            }
            if (self.midonly and self.frames[1].coded) self.frames[1].flush();

            if (coded_channels == 1 or self.output_channels == 1) {
                // The reference takes the block 2 samples earlier than the frame
                // it just wrote: that is a real 2-sample advance of the output
                // timeline, and skipping it shifts every sample.
                const src = self.frames[0].output[320 - self.flength ..][0..self.flength];
                for (0..self.output_channels) |ch_out| {
                    @memcpy(out[ch_out][f * self.flength ..][0..self.flength], src);
                }
            } else {
                self.unmixMs(
                    out[0][f * self.flength ..][0..self.flength],
                    out[1][f * self.flength ..][0..self.flength],
                    self.frames[1].output[320 - self.flength ..],
                );
            }
            self.midonly = false;
        }

        return needed;
    }

    fn decodeFrame(
        self: *Decoder,
        rc: *range.Decoder,
        frame_num: usize,
        channel: usize,
        coded_channels: u8,
        active: u8,
        active1: u8,
        redundant: bool,
    ) void {
        const frame = &self.frames[channel];
        var sf: [4]Subframe = @splat(.{});

        // Stereo: the two prediction weights and the mid-only flag are coded
        // once, ahead of the mid channel's own data.
        if (coded_channels == 2 and channel == 0) {
            const n = rc.decodeCdf(&cdf.model_stereo_s1);
            var wi: [2]i32 = @splat(0);
            var ws: [2]i32 = @splat(0);
            wi[0] = @as(i32, @intCast(rc.decodeCdf(&cdf.model_stereo_s2))) + 3 * @as(i32, @intCast(n / 5));
            ws[0] = @intCast(rc.decodeCdf(&cdf.model_stereo_s3));
            wi[1] = @as(i32, @intCast(rc.decodeCdf(&cdf.model_stereo_s2))) + 3 * @as(i32, @intCast(n % 5));
            ws[1] = @intCast(rc.decodeCdf(&cdf.model_stereo_s3));

            var w: [2]i32 = @splat(0);
            for (0..2) |i| {
                const idx: usize = @intCast(wi[i]);
                const base: i32 = lsf_tables.stereo_weights[idx];
                const slope: i32 = lsf_tables.stereo_weights[idx + 1] - base;
                w[i] = base + ((slope * 6554) >> 16) * (ws[i] * 2 + 1);
            }
            // The reference divides by a double literal, so these two go
            // through double before being stored as float.
            self.stereo_weights[0] = @floatCast(@as(f64, @floatFromInt(w[0] - w[1])) / 8192.0);
            self.stereo_weights[1] = @floatCast(@as(f64, @floatFromInt(w[1])) / 8192.0);
            self.midonly = if (active1 != 0) false else rc.decodeCdf(&cdf.model_mid_only) != 0;
        }

        var qoffset_high: i32 = 0;
        var voiced: u8 = 0;
        if (active == 0) {
            qoffset_high = @intCast(rc.decodeCdf(&cdf.model_frame_type_inactive));
            voiced = 0;
        } else {
            const frame_type = rc.decodeCdf(&cdf.model_frame_type_active);
            qoffset_high = @intCast(frame_type & 1);
            voiced = @intCast(frame_type >> 1);
        }

        // Subframe gains: absolute for the first subframe of the first frame of
        // a voiced segment, differential otherwise.
        for (0..self.subframes) |i| {
            var log_gain: i32 = 0;
            if (i == 0 and (frame_num == 0 or !frame.coded)) {
                const high = rc.decodeCdf(&cdf.model_gain_highbits[active + voiced]);
                const low = rc.decodeCdf(&cdf.model_gain_lowbits);
                log_gain = @intCast((high << 3) | low);
                if (frame.coded) log_gain = @max(log_gain, frame.log_gain - 16);
            } else {
                const delta: i32 = @intCast(rc.decodeCdf(&cdf.model_gain_delta));
                log_gain = std.math.clamp(@max((delta << 1) - 16, frame.log_gain + delta - 4), 0, 63);
            }
            frame.log_gain = log_gain;

            // 2^(x/128) through a Q16 base-2 approximation, in Q7.
            const scaled = ((log_gain * 0x1D1C71) >> 16) + 2090;
            const ipart: u5 = @intCast(scaled >> 7);
            const fpart: i32 = scaled & 127;
            const lingain: i32 = (@as(i32, 1) << ipart) +
                (((-174 * fpart * (128 - fpart)) >> 16) + fpart) * ((@as(i32, 1) << ipart) >> 7);
            sf[i].gain = @as(f32, @floatFromInt(lingain)) / 65536.0;
        }

        const filter = lpc.decode(rc, self.wb, self.subframes, frame, voiced != 0);
        self.interp_factor = filter.interp_factor;

        // Pitch: an absolute lag, or a delta from the previous voiced frame's.
        if (voiced != 0) {
            var lag_absolute = frame_num == 0 or !frame.prev_voiced;
            var primary_lag: i32 = 0;
            if (!lag_absolute) {
                const delta: i32 = @intCast(rc.decodeCdf(&cdf.model_pitch_delta));
                if (delta != 0) {
                    primary_lag = frame.primary_lag + delta - 9;
                } else {
                    lag_absolute = true;
                }
            }
            const bw: usize = @backingInt(self.bandwidth);
            if (lag_absolute) {
                const high: i32 = @intCast(rc.decodeCdf(&cdf.model_pitch_highbits));
                const low: i32 = @intCast(rc.decodeCdf(switch (self.bandwidth) {
                    .narrow => &cdf.model_pitch_lowbits_nb,
                    .medium => &cdf.model_pitch_lowbits_mb,
                    .wide => &cdf.model_pitch_lowbits_wb,
                }));
                primary_lag = @as(i32, pitch_tables.pitch_min_lag[bw]) +
                    high * @as(i32, pitch_tables.pitch_scale[bw]) + low;
            }
            frame.primary_lag = primary_lag;

            const offsets: []const i8 = if (self.subframes == 2)
                (if (self.bandwidth == .narrow)
                    &pitch_tables.pitch_offset_nb10ms[@intCast(rc.decodeCdf(&cdf.model_pitch_contour_nb10ms))]
                else
                    &pitch_tables.pitch_offset_mbwb10ms[@intCast(rc.decodeCdf(&cdf.model_pitch_contour_mbwb10ms))])
            else
                (if (self.bandwidth == .narrow)
                    &pitch_tables.pitch_offset_nb20ms[@intCast(rc.decodeCdf(&cdf.model_pitch_contour_nb20ms))]
                else
                    &pitch_tables.pitch_offset_mbwb20ms[@intCast(rc.decodeCdf(&cdf.model_pitch_contour_mbwb20ms))]);

            for (0..self.subframes) |i| {
                sf[i].pitch_lag = std.math.clamp(
                    primary_lag + offsets[i],
                    @as(i32, pitch_tables.pitch_min_lag[bw]),
                    @as(i32, pitch_tables.pitch_max_lag[bw]),
                );
            }

            const ltpfilter: usize = @intCast(rc.decodeCdf(&cdf.model_ltp_filter));
            const filter_sel = switch (ltpfilter) {
                0 => &cdf.model_ltp_filter0_sel,
                1 => &cdf.model_ltp_filter1_sel,
                else => &cdf.model_ltp_filter2_sel,
            };
            for (0..self.subframes) |i| {
                const index: usize = @intCast(rc.decodeCdf(filter_sel));
                const taps: *const [ltp_order]i8 = switch (ltpfilter) {
                    0 => &pitch_tables.ltp_filter0_taps[index],
                    1 => &pitch_tables.ltp_filter1_taps[index],
                    else => &pitch_tables.ltp_filter2_taps[index],
                };
                for (0..ltp_order) |j| sf[i].ltp_taps[j] = @as(f32, @floatFromInt(taps[j])) / 128.0;
            }
        }

        // The LTP scale factor only appears at the start of a voiced segment.
        const ltp_scale: f32 = if (voiced != 0 and frame_num == 0)
            @as(f32, @floatFromInt(pitch_tables.ltp_scale_factor[@intCast(rc.decodeCdf(&cdf.model_ltp_scale_index))])) / 16384.0
        else
            15565.0 / 16384.0;

        self.decodeExcitation(rc, qoffset_high, active, voiced);

        if (self.output_channels == channel or redundant) return;

        self.synthesize(frame, filter, &sf, voiced != 0, ltp_scale);

        frame.prev_voiced = voiced != 0;
        // Slide the histories by one frame.
        std.mem.copyForwards(f32, frame.lpc_history[0..history], frame.lpc_history[self.flength..][0..history]);
        std.mem.copyForwards(f32, frame.output[0..history], frame.output[self.flength..][0..history]);
        frame.coded = true;
    }

    fn synthesize(
        self: *Decoder,
        frame: *types.Frame,
        filter: lpc.Filter,
        sf: *const [4]Subframe,
        voiced: bool,
        ltp_scale: f32,
    ) void {
        const order = filter.order;
        const stride = self.sflength;
        const residual = &self.residual;

        for (0..self.subframes) |i| {
            const coeff = if (i < 2 and filter.has_leadin) &filter.leadin else &filter.body;
            const dst_base = history + i * stride;
            const res_base = max_lag + i * stride;
            const lpc_base = history + i * stride;

            if (voiced) {
                const has_leadin_here = i < 2 or self.interp_factor == 4;
                const out_end: i32 = if (has_leadin_here)
                    -@as(i32, @intCast(i * stride))
                else
                    -@as(i32, @intCast((i - 2) * stride));
                const scale: f32 = if (has_leadin_here) ltp_scale else 1.0;

                // Re-whitening: when the coefficients changed, the residual the
                // LTP filter should see is the *output* run back through the new
                // filter, not the residual that was decoded for it.
                var j: i32 = -sf[i].pitch_lag - ltp_order / 2;
                while (j < out_end) : (j += 1) {
                    var sum: f32 = frame.output[at(dst_base, j)];
                    for (0..order) |k| {
                        sum -= coeff[k] * frame.output[at(dst_base, j) - k - 1];
                    }
                    residual[at(res_base, j)] = types.clipf(sum, -1.0, 1.0) * scale / sf[i].gain;
                }

                if (out_end != 0) {
                    const rescale = sf[i - 1].gain / sf[i].gain;
                    var jr = out_end;
                    while (jr < 0) : (jr += 1) residual[at(res_base, jr)] *= rescale;
                }

                // Long-term prediction: five taps around the pitch lag.
                for (0..stride) |j0| {
                    const jj: i32 = @intCast(j0);
                    var sum: f32 = residual[at(res_base, jj)];
                    for (0..ltp_order) |k| {
                        const off = jj - sf[i].pitch_lag + ltp_order / 2 - @as(i32, @intCast(k));
                        sum += sf[i].ltp_taps[k] * residual[at(res_base, off)];
                    }
                    residual[at(res_base, jj)] = sum;
                }
            }

            // Short-term (LPC) synthesis, then clip.
            for (0..stride) |j0| {
                const jj: i32 = @intCast(j0);
                var sum: f32 = residual[at(res_base, jj)] * sf[i].gain;
                for (1..order + 1) |k| {
                    sum += coeff[k - 1] * frame.lpc_history[at(lpc_base, jj - @as(i32, @intCast(k)))];
                }
                frame.lpc_history[at(lpc_base, jj)] = sum;
                frame.output[at(dst_base, jj)] = types.clipf(sum, -1.0, 1.0);
            }
        }
    }

    /// Excitation: shell-block pulse counts, pulse positions by PVQ, raw LSBs,
    /// signs, then the Q23 assembly with its pseudo-random sign flips.
    fn decodeExcitation(self: *Decoder, rc: *range.Decoder, qoffset_high: i32, active: u8, voiced: u8) void {
        var seed: u32 = rc.decodeCdf(&cdf.model_lcg_seed);
        const bw: usize = @backingInt(self.bandwidth);
        const shell_blocks: usize = pitch_tables.shell_blocks[bw][self.subframes >> 2];
        const rate_level: usize = @intCast(rc.decodeCdf(&cdf.model_exc_rate[voiced]));

        self.pulse_count = @splat(0);
        self.lsb_count = @splat(0);
        for (0..shell_blocks) |i| {
            self.pulse_count[i] = @intCast(rc.decodeCdf(&cdf.model_pulse_count[rate_level]));
            if (self.pulse_count[i] == 17) {
                while (self.pulse_count[i] == 17) {
                    self.lsb_count[i] += 1;
                    if (self.lsb_count[i] == 10) break;
                    self.pulse_count[i] = @intCast(rc.decodeCdf(&cdf.model_pulse_count[9]));
                }
                if (self.lsb_count[i] == 10) {
                    self.pulse_count[i] = @intCast(rc.decodeCdf(&cdf.model_pulse_count[10]));
                }
            }
        }

        // Shell blocks are 16 samples each. For a 10 ms mediumband frame the
        // count works out at 8 blocks = 128 samples for a 120-sample frame, so
        // the last eight excitation samples are coded and then unused. The
        // reference decoder behaves the same way, so the surplus is decoded and
        // discarded rather than special-cased away.
        const samples = shell_blocks * 16;

        // Pulse positions: a binary split of the block, four levels deep.
        for (0..shell_blocks) |i| {
            const base = 16 * i;
            if (self.pulse_count[i] == 0) {
                @memset(self.excitation[base..][0..16], 0);
                continue;
            }
            var branch: [4][2]i32 = @splat(@splat(0));
            branch[0][0] = self.pulse_count[i];
            countChildren(rc, 0, branch[0][0], &branch[1]);
            for (0..2) |b| {
                countChildren(rc, 1, branch[1][b], &branch[2]);
                for (0..2) |c| {
                    countChildren(rc, 2, branch[2][c], &branch[3]);
                    for (0..2) |d| {
                        var child: [2]i32 = undefined;
                        countChildren(rc, 3, branch[3][d], &child);
                        const slot = base + 8 * b + 4 * c + 2 * d;
                        self.excitation[slot] = child[0];
                        self.excitation[slot + 1] = child[1];
                    }
                }
            }
        }

        // Least significant bits, most significant of them first.
        for (0..samples) |i| {
            var bit: usize = 0;
            while (bit < self.lsb_count[i >> 4]) : (bit += 1) {
                self.excitation[i] = (self.excitation[i] << 1) |
                    @as(i32, @intCast(rc.decodeCdf(&cdf.model_excitation_lsb)));
            }
        }

        // Signs, with a probability that depends on the pulse count.
        for (0..samples) |i| {
            if (self.excitation[i] != 0) {
                const count = @min(self.pulse_count[i >> 4], 6);
                const sign = rc.decodeCdf(&cdf.model_excitation_sign[active + voiced][@intCast(qoffset_high)][count]);
                if (sign == 0) self.excitation[i] *= -1;
            }
        }

        // Assemble: quantisation offset, then the pseudo-random sign flip whose
        // generator is seeded by the seed index and nudged by the pulse values.
        for (0..samples) |i| {
            const value = self.excitation[i];
            var assembled: i32 = (value * 256) | @as(i32, pitch_tables.quant_offset[voiced][@intCast(qoffset_high)]);
            if (value < 0) {
                assembled += 20;
            } else if (value > 0) {
                assembled -= 20;
            }
            self.excitation[i] = assembled;

            seed = seed *% 196314165 +% 907633515;
            if (seed & 0x80000000 != 0) self.excitation[i] *= -1;
            seed +%= @bitCast(value);

            self.residual[max_lag + i] = @as(f32, @floatFromInt(self.excitation[i])) / 8388608.0;
        }
    }

    /// Stereo: mid/side back to left/right, with the prediction weights
    /// interpolated over the first `stereo_interp_len` samples.
    fn unmixMs(self: *Decoder, left: []f32, right: []f32, side: []const f32) void {
        // The reference's `mid` pointer starts two samples before the frame's
        // own samples, so `mid[i - 2]` is this slice's `[i]`.
        const mid = self.frames[0].output[history - self.flength - 2 ..];
        const w0 = self.stereo_weights[0];
        const w1 = self.stereo_weights[1];
        const w0_prev = self.prev_stereo_weights[0];
        const w1_prev = self.prev_stereo_weights[1];
        const ramp: usize = @intCast(pitch_tables.stereo_interp_len[@backingInt(self.bandwidth)]);

        for (0..ramp) |i| {
            const fi: f32 = @floatFromInt(i);
            const interp0 = w0_prev + fi * (w0 - w0_prev) / @as(f32, @floatFromInt(ramp));
            const interp1 = w1_prev + fi * (w1 - w1_prev) / @as(f32, @floatFromInt(ramp));
            const p0 = 0.25 * (mid[i] + 2.0 * mid[i + 1] + mid[i + 2]);
            left[i] = types.clipf((1.0 + interp1) * mid[i + 1] + side[i + 1] + interp0 * p0, -1.0, 1.0);
            right[i] = types.clipf((1.0 - interp1) * mid[i + 1] - side[i + 1] - interp0 * p0, -1.0, 1.0);
        }
        for (ramp..self.flength) |i| {
            const p0 = 0.25 * (mid[i] + 2.0 * mid[i + 1] + mid[i + 2]);
            left[i] = types.clipf((1.0 + w1) * mid[i + 1] + side[i + 1] + w0 * p0, -1.0, 1.0);
            right[i] = types.clipf((1.0 - w1) * mid[i + 1] - side[i + 1] - w0 * p0, -1.0, 1.0);
        }
        self.prev_stereo_weights = self.stereo_weights;
    }
};

/// Address a buffer that is indexed by a signed offset around a base position.
/// SILK's windows reach into the history by construction, so this is the only
/// way to say "the sample three before the subframe start" without lying to the
/// type system.
fn at(base: usize, offset: i32) usize {
    const value = @as(i64, @intCast(base)) + @as(i64, offset);
    std.debug.assert(value >= 0);
    return @intCast(value);
}

/// Split `total` pulses between two children; the CDF used depends only on the
/// parent's count, and the table row is addressed by that count's triangular
/// number.
fn countChildren(rc: *range.Decoder, model: usize, total: i32, child: *[2]i32) void {
    if (total != 0) {
        const offset: usize = @intCast((total - 1 + 5) * (total - 1) >> 1);
        child[0] = @intCast(rc.decodeCdf(cdf.model_pulse_location[model][offset..]));
        child[1] = total - child[0];
    } else {
        child[0] = 0;
        child[1] = 0;
    }
}

test "bandwidth rates and subframe sizes" {
    try std.testing.expectEqual(@as(usize, 40), Bandwidth.narrow.subframeSamples());
    try std.testing.expectEqual(@as(usize, 60), Bandwidth.medium.subframeSamples());
    try std.testing.expectEqual(@as(usize, 80), Bandwidth.wide.subframeSamples());
    try std.testing.expectEqual(@as(u32, 8_000), Bandwidth.narrow.sampleRate());
    try std.testing.expectEqual(@as(u32, 16_000), Bandwidth.wide.sampleRate());
    try std.testing.expectEqual(@as(usize, 4), Bandwidth.wide.resamplerDelay() - 7);
}
