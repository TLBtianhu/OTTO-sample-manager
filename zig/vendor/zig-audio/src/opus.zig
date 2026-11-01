//! Ogg Opus: the container, both headers, every audio packet's framing, the
//! stream length, and all three decoding layers (CELT for music, SILK for
//! speech, and Hybrid, which runs both on one frame).
//!
//! Opus is not one codec but two layers plus a per-packet switch between them,
//! so the honest split is:
//!
//!   1. container, packet structure and length  <- this file;
//!   2. CELT decoding                           <- `opus_celt.zig` and friends;
//!   3. SILK decoding                           <- `opus_silk.zig` and friends;
//!   4. Hybrid, both layers on the same frame   <- `opus_hybrid.zig`.
//!
//! `inspect` walks the whole first Opus logical stream once and reports what a
//! player's file list needs: channel count, pre-skip, mapping, packet count,
//! frame counts per packet, configuration histogram, and the length in samples.
//! It never produces PCM.
//!
//! `Decoder` is the streaming decoder. It decodes CELT-only packets
//! (configuration 16-31), SILK-only packets (configuration 0-11) and Hybrid
//! packets (12-15), refuses stereo Hybrid with `error.Unsupported` (no vector
//! exercises the unmixing path), and refuses packets carrying more than two
//! frames. None of these refusals fabricates silence.
//!
//! Opus always runs at 48 kHz. Only the encoder's `input_sample_rate` hint
//! suggests otherwise, and RFC 7845 5.1 says that field is "not the sample rate
//! to use for playback", so `Info.sample_rate` is 48_000 for every stream and
//! the hint is kept beside it, unmodified. SILK is the one layer that runs at a
//! lower rate internally; its 8/12/16 kHz output is resampled to 48 kHz before
//! it reaches the shared output path, so no caller sees a different rate.
//!
//! Length comes from the granule position, which counts samples *including* the
//! pre-skip: RFC 7845 4.3 gives "PCM sample position = granule position -
//! pre-skip". Summing the packets instead overstates the length, because end
//! trimming lets the last granule cut into the final packet.

const std = @import("std");
const types = @import("types.zig");
const ogg = @import("ogg.zig");
const head_mod = @import("opus_head.zig");
const packet_mod = @import("opus_packet.zig");
const celt_mod = @import("opus_celt.zig");
const hybrid_mod = @import("opus_hybrid.zig");

pub const Error = types.Error;

pub const Head = head_mod.Head;
pub const Tags = head_mod.Tags;
pub const parseHead = head_mod.parse;
pub const parseTags = head_mod.parseTags;
pub const max_channels = head_mod.max_channels;
pub const max_version = head_mod.max_version;

pub const Packet = packet_mod.Packet;
pub const parsePacket = packet_mod.parse;
pub const Config = packet_mod.Config;
pub const configInfo = packet_mod.configInfo;
pub const samplesPerFrame = packet_mod.samplesPerFrame;
pub const max_frames = packet_mod.max_frames;
pub const max_frame_bytes = packet_mod.max_frame_bytes;

/// The one output rate Opus has. See the module comment.
pub const sample_rate: u32 = 48_000;

pub const Info = struct {
    version: u8,
    channels: u8,
    /// Samples to drop from the start of the decoded stream, and the amount
    /// to subtract from every granule position.
    pre_skip: u16,
    /// The encoder's original rate, kept as metadata. Never the playback rate.
    input_sample_rate: u32,
    /// Q7.8 dB. Recorded, not applied: applying it is a decoder's job.
    output_gain: i16,
    mapping_family: u8,
    stream_count: u8,
    coupled_count: u8,
    mapping: [max_channels]u8,
    mapping_len: u8,
    /// User comments in `OpusTags`; their contents are skipped.
    comment_count: u32,

    /// Always 48_000, independent of `input_sample_rate`.
    sample_rate: u32,
    /// Granule position of the last page that completed a packet.
    granule: u64,
    /// `granule - pre_skip`: the stream's length in samples at 48 kHz. This is
    /// what makes `ffprobe`'s `duration_ts` equal to `total_frames + pre_skip`.
    total_frames: u64,

    /// Audio packets, headers excluded.
    packets: u64,
    /// Opus frames across all packets: `packets` times the frames per packet.
    frames: u64,
    /// Sum of `frames * samples_per_frame`. May exceed `total_frames` by up to
    /// one packet's worth when end trimming cuts into the last packet.
    samples: u64,

    stereo_packets: u64,
    padding_packets: u64,
    /// Audio packets per TOC configuration, 0..31.
    configs: [32]u64,
    /// Audio packets per frame count, 1..48 (`frame_counts[0]` stays unused).
    frame_counts: [max_frames + 1]u64,
};

/// Parse the container, both headers and every packet of the first Opus
/// logical stream, and report its structure. Produces no PCM.
pub fn inspect(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    prefix: []const u8,
) Error!Info {
    var demux = try ogg.Demuxer.init(allocator, reader, prefix);
    defer demux.deinit();

    if (demux.streamCodec() != .opus) return error.Unsupported;

    // The identification header is required to be alone on the first page; the
    // demuxer already hands packets over one at a time, so the page layout
    // does not matter here, only the order.
    const head_packet = (try demux.nextPacket()) orelse return error.Truncated;
    const head = try head_mod.parse(head_packet);

    const tags_packet = (try demux.nextPacket()) orelse return error.Truncated;
    const tags = try head_mod.parseTags(tags_packet);

    var info = Info{
        .version = head.version,
        .channels = head.channels,
        .pre_skip = head.pre_skip,
        .input_sample_rate = head.input_sample_rate,
        .output_gain = head.output_gain,
        .mapping_family = head.mapping_family,
        .stream_count = head.stream_count,
        .coupled_count = head.coupled_count,
        .mapping = head.mapping,
        .mapping_len = head.mapping_len,
        .comment_count = tags.comments,
        .sample_rate = sample_rate,
        .granule = 0,
        .total_frames = 0,
        .packets = 0,
        .frames = 0,
        .samples = 0,
        .stereo_packets = 0,
        .padding_packets = 0,
        .configs = @splat(0),
        .frame_counts = @splat(0),
    };

    while (try demux.nextPacket()) |bytes| {
        const packet = try packet_mod.parse(bytes);
        info.packets += 1;
        info.frames += packet.frame_count;
        info.samples += packet.totalSamples();
        if (packet.stereo) info.stereo_packets += 1;
        if (packet.padding != 0) info.padding_packets += 1;
        info.configs[packet.config] += 1;
        info.frame_counts[packet.frame_count] += 1;
    }

    const granule = demux.lastGranule() orelse return error.Truncated;
    // A granule position before the pre-skip means the stream claims to end
    // before it starts; there is no PCM position to report.
    if (granule < head.pre_skip) return error.Corrupt;

    info.granule = granule;
    info.total_frames = granule - head.pre_skip;
    return info;
}

/// An Opus decoding stream: all three packet modes, one 48 kHz timeline.
///
/// All three packet modes are decoded: CELT-only (configuration 16..31),
/// SILK-only (0..11) and Hybrid (12..15). Hybrid needs both layers on the same
/// frame — the same arithmetic coder, the same 48 kHz timeline — and that
/// plumbing lives in `opus_hybrid.zig`; stereo Hybrid is refused with a named
/// error because no vector has exercised the unmixing path. Packets carrying
/// more than two frames are refused too: the multi-frame packing path is not
/// implemented, and decoding only the first frame would quietly drop audio.
///
/// Two timeline details are the whole reason this type has state:
///
///   * the first `pre_skip` samples are the encoder's algorithmic delay and are
///     dropped, so the decoder's sample `k` is the stream's sample
///     `k + pre_skip`;
///   * the last page's granule position trims the tail, which is why one packet
///     of lookahead is held back: until the *next* packet is known to be absent,
///     the current one might be the one the granule cuts into.
///
/// Both were measured against `ffmpeg -f f32le`: it emits exactly
/// `last_granule - pre_skip` samples (96000 and 144000 for the test vectors),
/// and not dropping the pre-skip would put every sample 312 frames early.
pub const Decoder = struct {
    allocator: std.mem.Allocator,
    demux: ogg.Demuxer,
    celt: ?*celt_mod.Decoder = null,
    /// Everything the speech layer owns: SILK state, the resampler, and the
    /// mode-switch crossfade bookkeeping.
    layer: hybrid_mod.Layer = .{},
    info: types.Info,
    pre_skip: u32,
    channels: usize,

    /// Interleaved i16 for the chunk being handed out.
    chunk: []i16 = &.{},
    chunk_len: usize = 0,
    chunk_pos: usize = 0,
    /// Interleaved f32 for one packet, before the i16 conversion.
    fbuf: []f32 = &.{},
    /// When set, every emitted float sample is appended here. Tests use it to
    /// compare against `ffmpeg -f f32le` without going through a quantiser.
    capture: ?*std.ArrayList(f32) = null,
    capture_gpa: std.mem.Allocator = undefined,

    /// One packet of lookahead, so the last one can be trimmed to the granule.
    ahead: std.ArrayList(u8) = .empty,
    ahead_valid: bool = false,
    skipped: u64 = 0,
    delivered: u64 = 0,
    total: ?u64 = null,
    done: bool = false,
    pending_error: ?Error = null,

    /// Largest packet this decoder will produce: 120 ms of audio, the format's
    /// own bound (RFC 6716 3.1). A 60 ms SILK frame alone is 2880 samples, so
    /// this cannot be "two frames of 20 ms" any more.
    const max_packet_frames: usize = packet_mod.max_packet_samples;

    pub fn open(
        allocator: std.mem.Allocator,
        reader: *std.Io.Reader,
        prefix: []const u8,
    ) Error!Decoder {
        const demux = try ogg.Demuxer.init(allocator, reader, prefix);
        return openFromDemux(allocator, demux);
    }

    /// Same as `open`, but from a demultiplexer the caller already created; the
    /// dispatcher has to look at the first packet to tell Opus from Vorbis and
    /// must not read that page twice. On failure the demultiplexer is freed.
    pub fn openFromDemux(allocator: std.mem.Allocator, demux_in: ogg.Demuxer) Error!Decoder {
        var demux = demux_in;
        var demux_owned = false;
        errdefer if (!demux_owned) demux.deinit();
        if (demux.streamCodec() != .opus) return error.Unsupported;

        const head_packet = (try demux.nextPacket()) orelse return error.Truncated;
        const head = try head_mod.parse(head_packet);
        const tags_packet = (try demux.nextPacket()) orelse return error.Truncated;
        _ = try head_mod.parseTags(tags_packet);

        var decoder = Decoder{
            .allocator = allocator,
            .demux = demux,
            .celt = null,
            .info = .{
                .format = .ogg_opus,
                .sample_rate = sample_rate,
                .channels = head.channels,
                .bits_per_sample = 16,
                .total_frames = null,
            },
            .pre_skip = head.pre_skip,
            .channels = head.channels,
        };
        demux_owned = true;
        errdefer decoder.deinit();
        decoder.celt = try celt_mod.Decoder.init(allocator, head.channels);
        decoder.chunk = try allocator.alloc(i16, max_packet_frames * head.channels);
        decoder.fbuf = try allocator.alloc(f32, max_packet_frames * head.channels);
        return decoder;
    }

    pub fn deinit(self: *Decoder) void {
        const allocator = self.allocator;
        if (self.celt) |celt| celt.deinit();
        if (self.chunk.len != 0) allocator.free(self.chunk);
        if (self.fbuf.len != 0) allocator.free(self.fbuf);
        self.ahead.deinit(allocator);
        self.demux.deinit();
        self.* = undefined;
    }

    fn peekPacket(self: *Decoder) Error!?[]const u8 {
        if (self.ahead_valid) return self.ahead.items;
        const packet = (try self.demux.nextPacket()) orelse return null;
        self.ahead.clearRetainingCapacity();
        try self.ahead.appendSlice(self.allocator, packet);
        self.ahead_valid = true;
        return self.ahead.items;
    }

    /// Decode one packet into `fbuf`; returns the number of frames written.
    fn decodePacket(self: *Decoder, bytes: []const u8) Error!usize {
        const packet = try packet_mod.parse(bytes);
        const config = packet_mod.configInfo(packet.config);
        const end_band = endBand(config.bandwidth);
        switch (config.mode) {
            .celt => return self.decodeCeltPacket(bytes, packet, config),
            .silk => {
                // The SILK layer here is mono: the unmixer exists but no vector
                // has exercised it, and a stereo stream would need the
                // resampler and the i16 conversion to interleave two channels.
                if (self.channels != 1) return error.Unsupported;
                return self.layer.decodeSilkPacket(self.celt.?, self.fbuf, bytes, packet, config, end_band);
            },
            .hybrid => {
                if (self.channels != 1) return error.Unsupported;
                return self.layer.decodeHybridPacket(self.celt.?, self.fbuf, bytes, packet, config, end_band);
            },
        }
    }

    fn decodeCeltPacket(
        self: *Decoder,
        bytes: []const u8,
        packet: packet_mod.Packet,
        config: packet_mod.Config,
    ) Error!usize {
        if (packet.frame_count > 2) return error.Unsupported;

        // A CELT-only packet always codes from band 0: a Hybrid packet may have
        // left `start` at 17, so it is set here rather than assumed.
        self.celt.?.start = 0;
        self.celt.?.end = endBand(config.bandwidth);
        // Leaving SILK for CELT flushes the speech layer, as the reference does
        // when it closes its resampler.
        self.layer.leave();
        const stream_channels: u8 = if (packet.stereo) 2 else 1;
        const per_frame = config.samples;
        const stride = self.channels;

        var frames: usize = 0;
        for (0..packet.frame_count) |i| {
            const frame_bytes = packet.frame(bytes, i);
            if (frame_bytes.len == 0) return error.Corrupt;
            try self.celt.?.decodeFrame(frame_bytes, per_frame, stream_channels);
            const src = self.celt.?.pcmFrame(per_frame);
            @memcpy(self.fbuf[frames * stride ..][0 .. per_frame * stride], src);
            frames += per_frame;
        }
        return frames;
    }

    /// Apply the pre-skip and the granule trim, then convert to i16.
    fn convert(self: *Decoder, frames: usize) Error!void {
        const channels = self.channels;
        self.chunk_len = 0;
        self.chunk_pos = 0;
        for (0..frames) |f| {
            const absolute = self.skipped + self.delivered;
            if (absolute < self.pre_skip) {
                self.skipped += 1;
                continue;
            }
            // `delivered` counts emitted frames, so this is the "we already
            // handed out the whole stream" test, including the tail trim.
            if (self.total) |total| {
                if (self.delivered >= total) break;
            }
            const src = self.fbuf[f * channels ..][0..channels];
            const dst = self.chunk[self.chunk_len..][0..channels];
            for (src, dst) |value, *slot| slot.* = toI16(value);
            self.chunk_len += channels;
            if (self.capture) |sink| try sink.appendSlice(self.capture_gpa, src);
            self.delivered += 1;
        }
    }

    /// Decode forward until a chunk with samples is ready. Returns false at end
    /// of stream, after trimming the final packet to the last granule.
    fn produceChunk(self: *Decoder) Error!bool {
        while (true) {
            if (self.total) |total| {
                if (self.delivered >= total) return false;
            }
            const packet = (try self.peekPacket()) orelse return false;
            const frames = try self.decodePacket(packet);
            self.ahead_valid = false;
            const is_last = (try self.peekPacket()) == null;
            if (is_last) {
                const granule = self.demux.lastGranule() orelse return error.Truncated;
                if (granule < self.pre_skip) return error.Corrupt;
                self.total = granule - self.pre_skip;
                self.info.total_frames = self.total;
            }
            try self.convert(frames);
            if (self.chunk_len != 0) return true;
            if (is_last) return false;
        }
    }

    /// Decode up to `out.len / channels` frames into `out` as interleaved i16.
    /// Returns 0 at end of stream; a buffer smaller than one frame is
    /// `error.ShortBuffer`.
    pub fn read(self: *Decoder, out: []i16) Error!usize {
        if (out.len == 0) return 0;
        if (self.pending_error) |err| return err;
        if (self.done) return 0;

        const channels = self.channels;
        const capacity = (out.len / channels) * channels;
        if (capacity == 0) return error.ShortBuffer;

        var written: usize = 0;
        while (written < capacity) {
            if (self.chunk_pos == self.chunk_len) {
                const more = self.produceChunk() catch |err| {
                    self.pending_error = err;
                    if (written == 0) return err;
                    break;
                };
                if (!more) {
                    self.done = true;
                    if (self.total) |total| self.info.total_frames = total;
                    break;
                }
            }
            const take = @min(self.chunk_len - self.chunk_pos, capacity - written);
            @memcpy(out[written..][0..take], self.chunk[self.chunk_pos..][0..take]);
            self.chunk_pos += take;
            written += take;
        }
        return written;
    }
};

/// Which band a given audio bandwidth stops coding at (RFC 6716 4.3.3: the
/// coding end is 13/17/19/21 bands for NB/WB/SWB/FB).
fn endBand(bandwidth: packet_mod.Bandwidth) usize {
    return switch (bandwidth) {
        .narrow => 13,
        .medium, .wide => 17,
        .superwide => 19,
        .full => tables_bands,
    };
}

const tables_bands = 21;

/// The same float-to-i16 rule as the WAV float path: clamp, scale by 32768,
/// round to nearest. Rounding matters — truncating costs several dB of SNR
/// against ffmpeg's `lrintf`.
fn toI16(value: f32) i16 {
    const scaled = value * 32768.0;
    if (std.math.isNan(scaled)) return 0;
    return @intFromFloat(@round(std.math.clamp(scaled, -32768.0, 32767.0)));
}
