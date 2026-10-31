//! Streaming MPEG-1 Layer III (MP3) decoder, mono and stereo.
//!
//! Scope of this version: MPEG-1 (version 11), Layer III (layer 01), one or two
//! channels, including joint stereo (mid/side and intensity). MPEG-2/2.5 and
//! Layer I/II return `error.Unsupported`. ID3v2 is skipped at open, ID3v1/APE/
//! Lyrics3 are recognized at frame boundaries.
//!
//! The bit reservoir is a 511-byte history: `main_data_begin` selects how many
//! bytes before this frame's main data the two granules start.

const std = @import("std");
const types = @import("types.zig");
const frame = @import("mp3_frame.zig");
const stereo = @import("mp3_stereo.zig");

pub const Error = types.Error;

const max_frame_len = 1441;
const reservoir_len = 511;
const main_buf_len = reservoir_len + max_frame_len;
/// Decoder delay of the polyphase filterbank, in samples. Gapless trimming in
/// LAME-tagged files skips encoder delay + this delay.
const decoder_delay = 529;

const Source = struct {
    reader: *std.Io.Reader,
    buf: [64]u8 = undefined,
    pos: usize = 0,
    len: usize = 0,

    fn init(reader: *std.Io.Reader, prefix: *const [12]u8) Source {
        var self = Source{ .reader = reader };
        @memcpy(self.buf[0..12], prefix);
        self.len = 12;
        return self;
    }

    fn ensure(self: *Source, n: usize) Error!bool {
        if (self.len - self.pos >= n) return true;
        if (self.pos > 0) {
            std.mem.copyForwards(u8, self.buf[0 .. self.len - self.pos], self.buf[self.pos..self.len]);
            self.len -= self.pos;
            self.pos = 0;
        }
        while (self.len < n) {
            const got = self.reader.readSliceShort(self.buf[self.len..]) catch |err| switch (err) {
                error.ReadFailed => return error.Io,
            };
            if (got == 0) return false;
            self.len += got;
        }
        return true;
    }

    fn peek(self: *Source, out: []u8) Error!bool {
        if (out.len > self.buf.len) return error.Corrupt;
        if (!try self.ensure(out.len)) return false;
        @memcpy(out, self.buf[self.pos..][0..out.len]);
        return true;
    }

    fn readExact(self: *Source, out: []u8) Error!bool {
        var done: usize = 0;
        while (done < out.len) {
            if (!try self.ensure(1)) {
                if (done == 0) return false;
                return error.Truncated;
            }
            const take = @min(out.len - done, self.len - self.pos);
            @memcpy(out[done..][0..take], self.buf[self.pos..][0..take]);
            self.pos += take;
            done += take;
        }
        return true;
    }

    fn readByte(self: *Source) Error!?u8 {
        if (!try self.ensure(1)) return null;
        const b = self.buf[self.pos];
        self.pos += 1;
        return b;
    }

    fn skip(self: *Source, n: usize) Error!void {
        var remaining = n;
        while (remaining > 0) {
            if (!try self.ensure(1)) return error.Truncated;
            const take = @min(remaining, self.len - self.pos);
            self.pos += take;
            remaining -= take;
        }
    }
};

const Header = struct {
    frame_len: usize,
    sample_rate: u32,
    sr_idx: usize,
    bitrate: u32,
    padding: u1,
    mode: u2,
    /// Only meaningful for joint stereo: bit 0 intensity, bit 1 mid/side.
    mode_ext: u2,
    emphasis: u2,
    has_crc: bool,
};

const RawHeader = struct {
    header: Header,
    bytes: [4]u8,
};

const bitrate_table = [16]u32{ 0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0 };
const sample_rate_table = [3]u32{ 44_100, 48_000, 32_000 };

fn tableIndex(sample_rate: u32) usize {
    return switch (sample_rate) {
        32_000 => 0,
        44_100 => 1,
        48_000 => 2,
        else => 1,
    };
}

fn parseHeader(bytes: *const [4]u8) Error!Header {
    if (bytes[0] != 0xFF or (bytes[1] & 0xE0) != 0xE0) return error.NotAudio;
    const version = (bytes[1] >> 3) & 3;
    const layer = (bytes[1] >> 1) & 3;
    if (version != 3 or layer != 1) return error.Unsupported;
    const has_crc = (bytes[1] & 1) == 0;
    const bitrate_index = (bytes[2] >> 4) & 15;
    if (bitrate_index == 0) return error.Unsupported;
    if (bitrate_index == 15) return error.Corrupt;
    const sr_index = (bytes[2] >> 2) & 3;
    if (sr_index == 3) return error.Corrupt;
    const padding = @as(u1, @intCast((bytes[2] >> 1) & 1));
    const mode = @as(u2, @intCast((bytes[3] >> 6) & 3));
    const mode_ext = @as(u2, @intCast((bytes[3] >> 4) & 3));

    const sample_rate = sample_rate_table[sr_index];
    const bitrate = bitrate_table[bitrate_index] * 1000;
    const frame_len = 144 * bitrate / sample_rate + padding;
    if (frame_len < 4 or frame_len > max_frame_len) return error.Corrupt;
    return .{
        .frame_len = frame_len,
        .sample_rate = sample_rate,
        .sr_idx = tableIndex(sample_rate),
        .bitrate = bitrate,
        .padding = padding,
        .mode = mode,
        .mode_ext = mode_ext,
        .emphasis = @intCast(bytes[3] & 3),
        .has_crc = has_crc,
    };
}

/// Mode 11 is mono; stereo, joint stereo and dual channel all carry two
/// channels (ISO 11172-3 2.4.1.7).
fn channelCount(mode: u2) u16 {
    return if (mode == 3) 1 else 2;
}

fn stereoOptions(header: Header) stereo.Options {
    if (header.mode != 1) return .{};
    return .{ .intensity = header.mode_ext & 1 != 0, .ms = header.mode_ext & 2 != 0 };
}

fn syncSafe(bytes: *const [4]u8) u32 {
    return (@as(u32, bytes[0] & 0x7F) << 21) |
        (@as(u32, bytes[1] & 0x7F) << 14) |
        (@as(u32, bytes[2] & 0x7F) << 7) |
        @as(u32, bytes[3] & 0x7F);
}

fn be32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .big);
}

fn isPrintable(bytes: []const u8) bool {
    for (bytes) |b| if (b < 0x20 or b > 0x7E) return false;
    return true;
}

pub const Decoder = struct {
    source: Source,
    info: types.Info,
    header: Header,
    have_header: bool = false,
    frames_loaded: u64 = 0,
    is_meta: bool = false,
    frame_buf: [max_frame_len]u8 = undefined,
    frame_len: usize = 0,
    side_off: usize = 0,
    main_off: usize = 0,
    side: frame.SideInfo = undefined,
    history: [reservoir_len]u8 = undefined,
    history_len: usize = 0,
    main: [main_buf_len]u8 = undefined,
    /// Per channel: IMDCT overlap, synthesis delay line, previous long
    /// scalefactors. Index 1 is unused for a mono stream.
    channels: [2]frame.ChannelState = .{ .{}, .{} },
    sf: [2][40]u8 = .{ @splat(0), @splat(0) },
    /// One frame, frame-major interleaved: sample `f`, channel `c` is
    /// `frame_samples[f * out_channels + c]`.
    frame_samples: [2 * 1152]i16 = undefined,
    out_channels: usize = 1,
    stereo_opts: stereo.Options = .{},
    /// Test support: when non-null, every decoded granule's f32 PCM (before the
    /// i16 conversion) is appended here. The public API stays i16-only.
    float_sink: ?*std.ArrayList(f32) = null,
    float_sink_gpa: std.mem.Allocator = undefined,
    frame_sample_pos: usize = 0,
    frame_sample_count: usize = 0,
    skip_remaining: u64 = 0,
    deliver_remaining: ?u64 = null,
    audio_frames_remaining: ?u64 = null,
    done: bool = false,
    pending_error: ?types.Error = null,

    pub fn read(self: *Decoder, out: []i16) types.Error!usize {
        if (out.len == 0) return 0;
        if (self.pending_error) |err| return err;
        if (self.done) return 0;

        // `out` is frame-major, like every other decoder in this library: a
        // buffer that cannot hold one whole frame is a named error, and a
        // partial frame is never returned.
        const channels: usize = self.out_channels;
        const capacity_frames = out.len / channels;
        if (capacity_frames == 0) return error.ShortBuffer;
        const capacity = capacity_frames * channels;

        var written: usize = 0;
        while (written < capacity) {
            if (self.frame_sample_pos == self.frame_sample_count) {
                const more = self.nextAudio() catch |err| {
                    self.pending_error = err;
                    if (written == 0) return err;
                    break;
                };
                if (!more) break;
            }

            var available = self.frame_sample_count - self.frame_sample_pos;
            if (self.skip_remaining > 0) {
                const skip = @min(@as(u64, available), self.skip_remaining);
                self.frame_sample_pos += @intCast(skip);
                self.skip_remaining -= skip;
                available -= @intCast(skip);
                if (available == 0) continue;
            }

            var take = @min(available, capacity - written);
            if (self.deliver_remaining) |remaining| {
                if (remaining == 0) {
                    self.done = true;
                    break;
                }
                const allowed: usize = if (remaining > std.math.maxInt(usize))
                    std.math.maxInt(usize)
                else
                    @intCast(remaining);
                take = @min(take, allowed);
            }

            @memcpy(
                out[written..][0..take],
                self.frame_samples[self.frame_sample_pos..][0..take],
            );
            self.frame_sample_pos += take;
            written += take;
            if (self.deliver_remaining) |remaining| {
                self.deliver_remaining = remaining - take;
                if (self.deliver_remaining.? == 0) {
                    self.done = true;
                    break;
                }
            }
        }
        return written;
    }

    pub fn deinit(self: *Decoder) void {
        self.* = undefined;
    }

    fn nextAudio(self: *Decoder) Error!bool {
        if (self.done) return false;
        if (self.audio_frames_remaining) |remaining| {
            if (remaining == 0) {
                self.done = true;
                return false;
            }
        }
        while (true) {
            if (!try self.loadFrame()) {
                if (self.audio_frames_remaining) |remaining| {
                    if (remaining > 0) return error.Truncated;
                }
                self.done = true;
                return false;
            }
            if (self.is_meta) continue;
            try self.decodeLoadedFrame();
            return true;
        }
    }

    fn loadFrame(self: *Decoder) Error!bool {
        const raw = (try self.readHeader()) orelse return false;
        if (!self.have_header) {
            self.header = raw.header;
            self.have_header = true;
            self.out_channels = channelCount(raw.header.mode);
            self.info = .{
                .format = .mp3,
                .sample_rate = raw.header.sample_rate,
                .channels = @intCast(self.out_channels),
                .bits_per_sample = 16,
                .total_frames = null,
            };
        } else if (raw.header.sample_rate != self.header.sample_rate or
            channelCount(raw.header.mode) != self.out_channels)
        {
            return error.Corrupt;
        }
        // Joint stereo flags are per frame: an encoder is free to switch
        // mid/side off on some frames and on for others (LAME does exactly
        // that), so this cannot be cached from the first frame.
        self.stereo_opts = stereoOptions(raw.header);
        self.frames_loaded += 1;
        self.frame_len = raw.header.frame_len;
        self.side_off = 4 + (if (raw.header.has_crc) @as(usize, 2) else 0);
        self.main_off = self.side_off + if (self.out_channels == 2) @as(usize, 32) else 17;
        if (self.frame_len < self.main_off) return error.Corrupt;

        @memcpy(self.frame_buf[0..4], &raw.bytes);
        if (!try self.source.readExact(self.frame_buf[4..self.frame_len])) return error.Truncated;

        self.side = try frame.parseSideInfo(self.frame_buf[self.side_off..][0..(self.main_off - self.side_off)], self.out_channels);
        self.is_meta = false;
        if (self.frames_loaded == 1 and self.frame_len >= self.main_off + 4) {
            const magic = self.frame_buf[self.main_off..][0..4];
            if (std.mem.eql(u8, magic, "Xing") or std.mem.eql(u8, magic, "Info")) {
                self.is_meta = true;
                self.parseXing();
            }
        }
        return true;
    }

    fn parseXing(self: *Decoder) void {
        var p = self.main_off + 4;
        if (p + 4 > self.frame_len) return;
        const flags = be32(self.frame_buf[p..][0..4]);
        p += 4;

        var frames: ?u32 = null;
        if (flags & 1 != 0) {
            if (p + 4 > self.frame_len) return;
            frames = be32(self.frame_buf[p..][0..4]);
            p += 4;
        }
        if (flags & 2 != 0) {
            if (p + 4 > self.frame_len) return;
            p += 4;
        }
        if (flags & 4 != 0) {
            if (p + 100 > self.frame_len) return;
            p += 100;
        }
        if (flags & 8 != 0) {
            if (p + 4 > self.frame_len) return;
            p += 4;
        }

        var delay: u32 = 0;
        var padding: u32 = 0;
        var have_lame = false;
        if (p + 36 <= self.frame_len and isPrintable(self.frame_buf[p..][0..9])) {
            const delay_padding = (@as(u32, self.frame_buf[p + 21]) << 16) |
                (@as(u32, self.frame_buf[p + 22]) << 8) |
                @as(u32, self.frame_buf[p + 23]);
            delay = delay_padding >> 12;
            padding = delay_padding & 0xFFF;
            if (delay <= 3000 and padding <= 3000) have_lame = true;
        }

        if (frames) |count| {
            if (count != 0) {
                self.audio_frames_remaining = count;
                const total = @as(u64, count) * 1152;
                const ch: u64 = self.out_channels;
                if (have_lame) {
                    const trim = @as(u64, delay) + padding;
                    if (total > trim) {
                        self.info.total_frames = total - trim;
                        self.deliver_remaining = (total - trim) * ch;
                    }
                    self.skip_remaining = (@as(u64, delay) + decoder_delay) * ch;
                } else {
                    self.info.total_frames = total;
                    self.deliver_remaining = total * ch;
                }
            }
        }
        self.history_len = 0;
    }

    fn decodeLoadedFrame(self: *Decoder) Error!void {
        if (self.frame_len <= self.main_off) return error.Corrupt;
        const nch = self.out_channels;
        const mdb: usize = self.side.main_data_begin;
        if (mdb > self.history_len) return error.Corrupt;
        const main_bytes = self.frame_len - self.main_off;
        const payload = mdb + main_bytes;
        if (payload > self.main.len) return error.Corrupt;

        if (mdb > 0) @memcpy(self.main[0..mdb], self.history[self.history_len - mdb .. self.history_len]);
        @memcpy(self.main[mdb..][0..main_bytes], self.frame_buf[self.main_off..self.frame_len]);

        // Spectral lines stay in the Huffman layout until joint stereo has run;
        // only then is each channel reordered, de-aliased and transformed.
        // A mid/side-only frame requantizes 2 quarter-steps low on both
        // channels; the mid/side sum restores the level (ISO 11172-3's
        // 1/sqrt(2) normalization, folded into the gain instead of the spectra).
        const ms_only = self.stereo_opts.ms and !self.stereo_opts.intensity;
        const gain_bias: i32 = if (ms_only) -2 else 0;
        var xr: [2][576]f32 = undefined;
        var granule_f32: [2 * 576]f32 = undefined;
        var bit: usize = 0;
        for (0..2) |g| {
            for (0..nch) |ch| {
                const info = &self.side.granules[g][ch];
                const end = bit + info.part2_3_length;
                if (end > payload * 8) return error.Corrupt;
                // `self.sf[ch]` is both the output and the scfsi history: a
                // reused scalefactor group reads back granule 0's value.
                try frame.decodeSpectrum(
                    info,
                    self.header.sr_idx,
                    self.main[0..payload],
                    bit,
                    end,
                    if (g == 1) self.sf[ch][0..22] else null,
                    &self.sf[ch],
                    &xr[ch],
                    gain_bias,
                );
                bit = end;
            }

            if (nch == 2) {
                stereo.process(
                    &xr[0],
                    &xr[1],
                    self.header.sr_idx,
                    &self.side.granules[g][1],
                    &self.sf[1],
                    self.stereo_opts,
                );
            }

            for (0..nch) |ch| {
                const capture: ?[]f32 = if (self.float_sink != null)
                    granule_f32[0 .. 576 * nch]
                else
                    null;
                frame.renderChannel(
                    &self.side.granules[g][ch],
                    self.header.sr_idx,
                    &xr[ch],
                    &self.channels[ch],
                    self.frame_samples[g * 576 * nch ..][0 .. 576 * nch],
                    capture,
                    ch,
                    nch,
                );
            }
            if (self.float_sink) |sink| {
                try sink.appendSlice(self.float_sink_gpa, granule_f32[0 .. 576 * nch]);
            }
        }

        const keep = @min(payload, reservoir_len);
        @memcpy(self.history[0..keep], self.main[payload - keep .. payload]);
        self.history_len = keep;
        self.frame_sample_pos = 0;
        self.frame_sample_count = 1152 * nch;
        if (self.audio_frames_remaining) |*remaining| {
            if (remaining.* > 0) remaining.* -= 1;
        }
    }

    fn readHeader(self: *Decoder) Error!?RawHeader {
        while (true) {
            var magic: [4]u8 = undefined;
            if (!try self.source.peek(&magic)) return null;
            if (std.mem.eql(u8, magic[0..3], "TAG")) {
                try self.source.skip(128);
                continue;
            }
            if (std.mem.eql(u8, magic[0..3], "LYR")) return null;
            if (std.mem.eql(u8, magic[0..3], "APE")) return null;
            if (!try self.source.readExact(&magic)) return null;
            return .{ .header = try parseHeader(&magic), .bytes = magic };
        }
    }
};

pub fn open(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    prefix: *const [12]u8,
) Error!Decoder {
    return openWithSink(allocator, reader, prefix, null);
}

fn openWithSink(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    prefix: *const [12]u8,
    sink: ?*std.ArrayList(f32),
) Error!Decoder {
    var src = Source.init(reader, prefix);
    try skipId3(&src);
    var dec = Decoder{
        .source = src,
        .info = undefined,
        .header = undefined,
        .float_sink = sink,
        .float_sink_gpa = allocator,
    };
    if (!try dec.nextAudio()) return error.NotAudio;
    return dec;
}

/// Decode the whole stream to f32 PCM, applying the same LAME delay/padding
/// trimming `read` applies, before the i16 conversion. Test support only: the
/// public API is i16. Returns `error.NotAudio` for an empty stream.
pub fn decodeToF32(allocator: std.mem.Allocator, bytes: []const u8) Error![]f32 {
    var header: [12]u8 = undefined;
    var reader = std.Io.Reader.fixed(bytes);
    const got = reader.readSliceShort(&header) catch return error.Io;
    if (got < header.len) return error.Truncated;

    var list: std.ArrayList(f32) = .empty;
    errdefer list.deinit(allocator);

    var dec = try openWithSink(allocator, &reader, &header, &list);
    defer dec.deinit();

    const skip: usize = @intCast(@min(dec.skip_remaining, std.math.maxInt(usize)));
    const deliver: ?usize = blk: {
        const remaining = dec.deliver_remaining orelse break :blk null;
        break :blk @intCast(@min(remaining, std.math.maxInt(usize)));
    };
    dec.skip_remaining = 0;
    dec.deliver_remaining = null;

    var buf: [4096]i16 = undefined;
    while (true) {
        const n = try dec.read(&buf);
        if (n == 0) break;
    }

    const end = if (deliver) |d| @min(list.items.len, skip + d) else list.items.len;
    if (skip >= end) return list.toOwnedSlice(allocator);
    const out = try allocator.dupe(f32, list.items[skip..end]);
    list.deinit(allocator);
    return out;
}

fn skipId3(src: *Source) Error!void {
    while (true) {
        var magic: [3]u8 = undefined;
        if (!try src.peek(&magic)) return;
        if (!std.mem.eql(u8, &magic, "ID3")) return;
        var header: [10]u8 = undefined;
        if (!try src.readExact(&header)) return error.Truncated;
        if (header[0] != 'I' or header[1] != 'D' or header[2] != '3') return error.Corrupt;
        if (header[3] < 2 or header[3] > 4) return error.Corrupt;
        const size = syncSafe(header[6..10]);
        const footer: u32 = if (header[5] & 0x10 != 0) 10 else 0;
        try src.skip(@as(usize, size) + footer);
    }
}
