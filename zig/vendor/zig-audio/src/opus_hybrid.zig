//! The speech layer's plumbing: SILK-only and Hybrid packets, including the
//! CELT redundancy section a mode switch leaves at the end of a packet.
//!
//! Opus's Hybrid mode runs both layers on the *same* frame: SILK codes the low
//! band (always wideband, 16 kHz internally), CELT codes from band 17 (8 kHz)
//! up to the packet's own end band, and the decoder adds the two waveforms
//! sample by sample. This file owns everything about that packet that is not
//! CELT bitstream or SILK synthesis: which bytes the CELT half starts at, how
//! the SILK half is resampled and aligned, and how the two are summed.
//!
//! Three facts decide the implementation:
//!
//!   * **The range decoder is shared.** SILK and CELT are not separate byte
//!     ranges with a length field: they are one arithmetic coder over one frame.
//!     SILK consumes symbols from the front, then CELT continues from whatever
//!     bit position SILK stopped at (`rc.tell()`), which is generally *not* a
//!     byte boundary. So the answer to "how many bytes does SILK take" is
//!     "ceil(tell/8) at the point where it stops", and the CELT bit budget is
//!     the frame length in bits, not the tail length.
//!   * **The redundancy section is the only byte-aligned split.** RFC 6716
//!     4.2.3: if at least 17 (SILK-only) or 37 (Hybrid) bits are left after
//!     SILK, the frame may carry a 5 ms CELT frame at the end for a mode
//!     switch. It is measured from the SILK-end bit position, and the range
//!     decoder's storage is shrunk so the CELT half's raw-bit tail ends before
//!     it.
//!   * **The mix is time-domain addition.** The reference decodes SILK, upsamples
//!     it to 48 kHz, decodes CELT into a second buffer and adds the second into
//!     the first (`vector_fmac_scalar`). It is not a frequency-domain join: the
//!     bands overlap at the crossover and the sum is what the encoder heard.
//!
//! Alignment is the subtle part. The SILK resampler has a fixed group delay, so
//! it produces slightly fewer samples than a frame's nominal 48 kHz length on
//! the first frames and carries the remainder into the next call. The reference
//! always asks for exactly one frame's worth (`swr_convert` with
//! `out_count = frame_duration`) and tracks the shortfall in `delayed_samples`;
//! this file does the same and *refuses* a hybrid frame whose SILK half is
//! short, because adding CELT at the wrong sample offset would be wrong audio
//! that still sounds like audio.

const std = @import("std");
const types = @import("types.zig");
const packet_mod = @import("opus_packet.zig");
const silk_mod = @import("opus_silk.zig");
const resample_mod = @import("opus_silk_resample.zig");
const range_mod = @import("opus_range.zig");
const celt_mod = @import("opus_celt.zig");
const tables = @import("opus_celt_tables.zig");

pub const Error = types.Error;

/// A redundancy frame is 5 ms at 48 kHz.
pub const redundancy_samples: usize = 240;
/// Its crossfade is half of that.
pub const fade: usize = 120;

/// The crossfade window: the reference's `ff_celt_window2`, the CELT mode window
/// squared. `window2` in the table module is exactly that.
pub const window = tables.window2;

/// SILK -> CELT: `dst[i] = src[i] * w[i] + dst[i] * (1 - w[i])` over the last
/// 2.5 ms of `dst`: the packet's tail fades *out* while the redundancy frame's
/// second half takes over, so the last sample is the redundancy frame's last.
pub fn fadeTail(dst: []f32, redundancy: []const f32) void {
    std.debug.assert(dst.len >= fade and redundancy.len >= redundancy_samples);
    const tail = dst[dst.len - fade ..][0..fade];
    const src = redundancy[fade..][0..fade];
    for (tail, src, window) |*d, s, w| d.* = s * w + d.* * (1.0 - w);
}

/// CELT -> SILK: replace the first 2.5 ms outright, then fade from the
/// redundancy frame's second half back into `dst`.
pub fn spliceHead(dst: []f32, redundancy: []const f32) void {
    std.debug.assert(dst.len >= 2 * fade and redundancy.len >= redundancy_samples);
    @memcpy(dst[0..fade], redundancy[0..fade]);
    const head = dst[fade..][0..fade];
    const src = redundancy[fade..][0..fade];
    for (head, src, window) |*d, s, w| d.* = d.* * w + s * (1.0 - w);
}

/// Everything that survives a SILK frame: the synthesis state, the resamplers
/// and their buffered samples, and the last crossfade a mode switch asked for.
///
/// **Stereo.** A stereo SILK frame is *not* two independent SILK streams: it is
/// one mid channel plus one side channel, coded with three prediction weights
/// per frame (RFC 6716 4.2.2, "stereo prediction weights"), and turned back
/// into left/right by `silk_stereo_MS_to_LR` (`opus_silk.zig`'s `unmixMs`).
/// What *is* per channel downstream of that is the resampler and the 48 kHz
/// output, so this struct holds one resampler per output channel. The reference
/// gives swresample a two-channel context whose filter position is shared, and
/// each channel sees the same taps at the same positions, so two instances kept
/// in lockstep are the same arithmetic.
pub const Layer = struct {
    silk: ?silk_mod.Decoder = null,
    /// One resampler per output channel, created and primed together.
    resampler: [2]?resample_mod.Resampler = .{ null, null },
    /// Channels the stream decodes to (1 or 2), from `OpusHead`.
    output_channels: u8 = 1,
    /// One SILK frame at the bandwidth's own rate: up to 60 ms at 16 kHz.
    rate: [2][960]f32 = @splat(@splat(0.0)),
    /// The same frame resampled to 48 kHz, plane per channel, clamped to the
    /// frame's own length.
    out: [2][2880]f32 = @splat(@splat(0.0)),
    /// Samples the resamplers still owe from earlier frames (the reference's
    /// `delayed_samples`). Hybrid decoding needs this at zero; the end of the
    /// stream turns it into the flush tail.
    delayed: usize = 0,
    /// The 5 ms redundancy frame, in its own buffer: the main CELT decode would
    /// overwrite the decoder's PCM buffer.
    redundancy: [2][redundancy_samples]f32 = @splat(@splat(0.0)),

    /// Create the SILK decoder on first use and (re)build the resamplers when
    /// the bandwidth changes. The zero priming is what cancels the filter's
    /// group delay; the delay count is the reference's per-bandwidth one.
    fn ensure(self: *Layer, bandwidth: silk_mod.Bandwidth) Error!void {
        if (self.output_channels == 0 or self.output_channels > 2) return error.Unsupported;
        if (self.silk == null) self.silk = silk_mod.Decoder.init(self.output_channels);
        const rate = bandwidth.sampleRate();
        if (self.resampler[0] == null or self.resampler[0].?.in_rate != rate) {
            for (0..self.output_channels) |c| {
                self.resampler[c] = try resample_mod.Resampler.init(rate);
                self.resampler[c].?.primeZeros(bandwidth.resamplerDelay());
            }
            self.delayed = 0;
        }
    }

    /// What a CELT-only packet does to this layer: the reference flushes SILK
    /// and closes the resampler when the stream leaves SILK, so a later SILK
    /// packet starts from a clean history instead of resuming stale state.
    pub fn leave(self: *Layer) void {
        if (self.silk) |*silk| silk.reset();
        self.resampler = .{ null, null };
        self.delayed = 0;
    }

    /// Decode one frame's SILK half and resample it, asking for exactly one
    /// frame's worth of 48 kHz samples so the CELT half can be added at the
    /// frame's own offset. Returns how many samples that produced.
    fn decodeHalf(
        self: *Layer,
        rc: *range_mod.Decoder,
        bandwidth: silk_mod.Bandwidth,
        duration_ms: u32,
        per_frame: usize,
        coded_channels: u8,
    ) Error!usize {
        const rate_samples = try self.silk.?.decodeSuperframe(
            rc,
            .{ self.rate[0][0..], self.rate[1][0..] },
            bandwidth,
            coded_channels,
            duration_ms,
        );
        // Every channel runs the same filter position over the same input
        // count, so they must agree; the smallest count is the safe answer.
        var written = per_frame;
        for (0..self.output_channels) |c| {
            const w = self.resampler[c].?.convert(self.out[c][0..per_frame], self.rate[c][0..rate_samples]);
            written = @min(written, w);
        }
        self.delayed += per_frame - written;
        return written;
    }

    /// Decode the 5 ms CELT redundancy frame a packet carries for a mode switch,
    /// into this layer's own buffer. The reference flushes CELT first, so the
    /// redundancy frame starts from a silent overlap history, and it decodes
    /// with start band 0 and the packet's end band.
    fn decodeRedundancy(
        self: *Layer,
        celt: *celt_mod.Decoder,
        bytes: []const u8,
        end_band: usize,
        stream_channels: u8,
    ) Error!void {
        celt.reset();
        celt.start = 0;
        celt.end = end_band;
        var rc = range_mod.Decoder.init(bytes);
        try celt.decodeFrameWithEc(&rc, redundancy_samples, stream_channels);
        const pcm = celt.pcmFrame(redundancy_samples);
        // `pcmFrame` is interleaved at the decoder's channel count, which is the
        // stream's; a mono packet in a stereo stream leaves channel 1 as it was,
        // exactly as the reference's two-channel redundancy buffer does.
        std.debug.assert(celt.channels == self.output_channels);
        for (0..self.output_channels) |c| {
            for (0..redundancy_samples) |i| {
                self.redundancy[c][i] = pcm[i * self.output_channels + c];
            }
        }
    }

    /// Copy one frame of planar 48 kHz audio out as interleaved PCM.
    fn emit(self: *Layer, dst: []f32, frames: usize) void {
        const channels = self.output_channels;
        if (channels == 1) {
            @memcpy(dst[0..frames], self.out[0][0..frames]);
            return;
        }
        for (0..frames) |i| {
            for (0..channels) |c| dst[i * channels + c] = self.out[c][i];
        }
    }

    /// The reference's end-of-stream resampler flush: mirror the buffered input
    /// and produce the samples still owed, into `out[c]`; returns how many.
    /// The caller emits them *after* the last packet's granule trim, which is
    /// where the reference puts them (`opus_flush_resample`).
    pub fn flushTail(self: *Layer) usize {
        const delayed = self.delayed;
        if (delayed == 0 or self.resampler[0] == null) return 0;
        var produced = delayed;
        for (0..self.output_channels) |c| {
            const resampler = &self.resampler[c].?;
            resampler.flush();
            const written = resampler.convert(self.out[c][0..delayed], &.{});
            produced = @min(produced, written);
        }
        self.delayed = 0;
        return produced;
    }

    /// SILK-only: one coded frame per Opus frame, resampled to 48 kHz, plus the
    /// CELT redundancy section a mode switch leaves at the end.
    ///
    /// One refusal lives here rather than in `opus_silk.zig`, because it is
    /// about this layer's plumbing: a stream carrying more than two frames per
    /// packet (the multi-frame packing path is not implemented).
    ///
    /// A stereo packet's two channels are mid and side (see `Layer`); the
    /// resampling that follows is per channel.
    pub fn decodeSilkPacket(
        self: *Layer,
        celt: *celt_mod.Decoder,
        fbuf: []f32,
        bytes: []const u8,
        packet: packet_mod.Packet,
        config: packet_mod.Config,
        end_band: usize,
    ) Error!usize {
        const bandwidth: silk_mod.Bandwidth = switch (config.bandwidth) {
            .narrow => .narrow,
            .medium => .medium,
            .wide => .wide,
            else => return error.Unsupported,
        };
        if (packet.frame_count > 2) return error.Unsupported;
        // A SILK packet is what flushes CELT in the reference: a stream that
        // came from hybrid must not resume CELT's overlap history later.
        celt.reset();
        try self.ensure(bandwidth);

        const coded_channels: u8 = if (packet.stereo) 2 else 1;
        const duration_ms: u32 = config.samples / 48;
        var frames: usize = 0;
        for (0..packet.frame_count) |i| {
            const data = packet.frame(bytes, i);
            if (data.len == 0) return error.Corrupt;
            const delayed_before = self.delayed;
            var rc = range_mod.Decoder.init(data);
            const written = try self.decodeHalf(&rc, bandwidth, duration_ms, config.samples, coded_channels);
            if (written == 0) return error.Corrupt;

            // RFC 6716 4.2.3: with at least 17 bits left the rest of the frame
            // is a CELT redundancy section, measured from where SILK stopped.
            const consumed = rc.tell();
            if (consumed + 17 <= @as(i32, @intCast(data.len * 8))) {
                if (delayed_before != 0) return error.Unsupported;
                const to_silk = rc.decodeBitLogp(1) == 1;
                const red_start: usize = @intCast(@divTrunc(consumed + 7, 8));
                if (red_start >= data.len) return error.Corrupt;
                try self.decodeRedundancy(celt, data[red_start..], end_band, coded_channels);
                for (0..self.output_channels) |c| {
                    const dst = self.out[c][0..written];
                    if (to_silk) spliceHead(dst, self.redundancy[c][0..]) else fadeTail(dst, self.redundancy[c][0..]);
                }
                if (to_silk) {
                    // The reference flushes again after a CELT -> SILK splice,
                    // so the next CELT frame does not continue the redundancy.
                    celt.reset();
                }
            }
            self.emit(fbuf[frames * self.output_channels ..], written);
            frames += written;
        }
        return frames;
    }

    /// Hybrid: one frame, both layers.
    ///
    /// Bit split: SILK and CELT share one arithmetic coder, so CELT starts at
    /// the bit position SILK stopped at, not at a byte boundary. The only
    /// byte-aligned boundary is the redundancy section at the end, and its
    /// length is coded too (`decodeUint(256) + 2`).
    ///
    /// Band split: CELT starts at band 17 (8 kHz) and ends at the packet
    /// bandwidth's band (19 for SWB, 21 for FB). The SILK half is wideband
    /// internally whatever the packet signals, and is resampled to 48 kHz.
    ///
    /// Mixing: sample-wise addition on the frame's own 48 kHz grid, per channel.
    /// For a stereo packet the SILK half is mid/side (unmixed to L/R before the
    /// resampler) and the CELT half is CELT's own stereo, so the two layers meet
    /// per channel, not as a shared mid/side pair.
    pub fn decodeHybridPacket(
        self: *Layer,
        celt: *celt_mod.Decoder,
        fbuf: []f32,
        bytes: []const u8,
        packet: packet_mod.Packet,
        config: packet_mod.Config,
        end_band: usize,
    ) Error!usize {
        if (packet.frame_count > 2) return error.Unsupported;
        if (self.delayed != 0) return error.Unsupported;
        try self.ensure(.wide);

        const coded_channels: u8 = if (packet.stereo) 2 else 1;
        const per_frame = config.samples;
        const duration_ms: u32 = per_frame / 48;
        var frames: usize = 0;
        for (0..packet.frame_count) |i| {
            const data = packet.frame(bytes, i);
            if (data.len == 0) return error.Corrupt;
            var rc = range_mod.Decoder.init(data);
            const written = try self.decodeHalf(&rc, .wide, duration_ms, per_frame, coded_channels);
            // The CELT half is added at the frame's start, so a SILK half that
            // is short by even one sample would shift it. Refuse, do not smear.
            if (written != per_frame) return error.Unsupported;

            const total_bits: i32 = @intCast(data.len * 8);
            const silk_bits = rc.tell();
            var celt_size = data.len;
            var to_silk = false;
            var has_redundancy = false;
            // Hybrid needs 37 bits: the flag itself, the direction bit and the
            // smallest possible length field, plus room for the frame.
            if (silk_bits + 37 <= total_bits and rc.decodeBitLogp(12) == 1) {
                to_silk = rc.decodeBitLogp(1) == 1;
                const red_bytes = rc.decodeUint(256) + 2;
                if (red_bytes > data.len) return error.Corrupt;
                celt_size = data.len - red_bytes;
                if (@as(i32, @intCast(celt_size * 8)) < rc.tell()) return error.Corrupt;
                has_redundancy = true;
                if (to_silk) {
                    try self.decodeRedundancy(celt, data[celt_size..], end_band, coded_channels);
                    celt.reset();
                }
            }

            // The raw-bit tail and the bit budget both end where the CELT
            // payload ends, so the redundancy bytes are excluded here.
            rc.shrink(celt_size);
            celt.start = 17;
            celt.end = end_band;
            try celt.decodeFrameWithEc(&rc, per_frame, coded_channels);

            const celt_pcm = celt.pcmFrame(per_frame);
            std.debug.assert(celt.channels == self.output_channels);
            for (0..self.output_channels) |c| {
                for (0..per_frame) |s| self.out[c][s] += celt_pcm[s * self.output_channels + c];
            }
            if (to_silk) {
                for (0..self.output_channels) |c| {
                    spliceHead(self.out[c][0..per_frame], self.redundancy[c][0..]);
                }
            } else if (has_redundancy) {
                // A SILK -> CELT transition: the redundancy frame's second half
                // replaces the tail, so the next CELT packet continues it.
                try self.decodeRedundancy(celt, data[celt_size..], end_band, coded_channels);
                for (0..self.output_channels) |c| {
                    fadeTail(self.out[c][0..per_frame], self.redundancy[c][0..]);
                }
            }
            self.emit(fbuf[frames * self.output_channels ..], per_frame);
            frames += per_frame;
        }
        return frames;
    }
};

test "the crossfade window is the squared mode window, monotone and complete" {
    for (window, 0..) |w, n| {
        const reference = tables.window120_reference[n];
        try std.testing.expectEqual(reference * reference, w);
    }
    try std.testing.expect(window[0] < 1e-8);
    try std.testing.expectEqual(@as(f32, 1.0), window[fade - 1]);
    var n: usize = 1;
    while (n < fade) : (n += 1) {
        try std.testing.expect(window[n] >= window[n - 1]);
    }
}

test "fadeTail leaves the first sample and ends on the redundancy frame" {
    var dst: [fade]f32 = @splat(0.5);
    var redundancy: [redundancy_samples]f32 = @splat(0.0);
    for (&redundancy, 0..) |*v, i| v.* = @as(f32, @floatFromInt(i)) / 240.0;
    fadeTail(&dst, &redundancy);
    // w[0] ~ 4.5e-9, so the first sample is still the packet's own; w[119] is
    // 1.0, so the last is the redundancy frame's sample 239.
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), dst[0], 1e-6);
    try std.testing.expectApproxEqAbs(redundancy[redundancy_samples - 1], dst[fade - 1], 1e-6);
    try std.testing.expect(dst[fade / 2] != @as(f32, 0.5));
}

test "spliceHead copies the first half and fades the second" {
    var dst: [2 * fade]f32 = @splat(0.25);
    var redundancy: [redundancy_samples]f32 = @splat(-0.75);
    redundancy[fade] = -1.0;
    spliceHead(&dst, &redundancy);
    for (dst[0..fade], redundancy[0..fade]) |got, want| try std.testing.expectEqual(want, got);
    try std.testing.expectApproxEqAbs(redundancy[fade], dst[fade], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), dst[2 * fade - 1], 1e-5);
}
