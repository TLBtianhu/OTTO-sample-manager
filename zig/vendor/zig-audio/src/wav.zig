//! Streaming RIFF/WAVE decoder.
//!
//! The parser is chunk-driven, not whole-file: `open` consumes the RIFF header
//! and chunk headers only, stopping at the `data` payload; `read` pulls exactly
//! as many bytes as the caller's buffer can hold. This is what makes it usable
//! for pipes and growing files (ffmpeg writes `data` size 0xFFFFFFFF there) and
//! keeps memory use flat.
//!
//! Scope: PCM 8/16/24/32, IEEE float32, WAVE_FORMAT_EXTENSIBLE with the PCM or
//! IEEE_FLOAT subformat, G.711 µ-law/A-law (tags 7/6), IMA ADPCM (0x11) and
//! Microsoft ADPCM (0x02), 1..64 channels, any non-zero sample rate. Unknown
//! chunks are skipped with the RIFF odd-length padding rule. Compressed tags
//! beyond those (GSM, MP3-in-WAV, ...), RIFX/RF64, 12/20-bit PCM and float64
//! are rejected by name.
//!
//! The two ADPCM codecs and G.711 decode to 16-bit linear samples; their
//! `Info.bits_per_sample` is reported as 16 because that is what `read`
//! produces, while the container's nibble/byte width stays internal. ADPCM is
//! block based: `open` allocates one staging block from the caller's
//! allocator, `read` never allocates, and `deinit` frees it.
//!
//! `data` before `fmt ` is rejected (`error.Unsupported`): a streaming decoder
//! cannot rewind to the payload after discovering the format.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const adpcm = @import("adpcm.zig");
const g711 = @import("g711.zig");

/// `data` size used by streaming WAV writers that cannot seek back to patch
/// the header. Treated as "decode until EOF", total_frames = null.
const data_size_unknown: u32 = 0xFFFF_FFFF;

/// Upper bound on how much of a `fmt ` payload is inspected. The standard
/// PCM/float form is 16 bytes, the EXTENSIBLE form is 40, and Microsoft ADPCM
/// needs 22 + 4 * coefficient_count (50 for the seven standard pairs).
const fmt_buf_len = 96;

const format_pcm: u16 = 0x0001;
const format_ms_adpcm: u16 = 0x0002;
const format_float: u16 = 0x0003;
const format_alaw: u16 = 0x0006;
const format_mulaw: u16 = 0x0007;
const format_ima_adpcm: u16 = 0x0011;
const format_extensible: u16 = 0xFFFE;

/// KSDATAFORMAT_SUBTYPE_PCM / _IEEE_FLOAT GUIDs, in the little-endian byte
/// order they appear in a `fmt ` chunk.
const guid_pcm = [16]u8{
    0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00,
    0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71,
};
const guid_float = [16]u8{
    0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00,
    0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71,
};

/// Sentinel for "no declared length"; must not collide with a real u64 size.
const unknown_size = std.math.maxInt(u64);

pub const SampleFormat = enum { pcm, float, mulaw, alaw };

const Fmt = struct {
    sample_rate: u32,
    channels: u16,
    bits: u16,
    format: SampleFormat,
    bytes_per_sample: usize,
    frame_bytes: usize,
    /// Non-null for the block codecs; the linear fields above are unused
    /// (`frame_bytes` is 0) and `read` dispatches to the block reader.
    adpcm_params: ?adpcm.Params = null,
};

/// Streaming state for the block codecs: one compressed block and its decoded
/// staging samples. Both buffers are allocated in `open`, never in `read`.
const BlockState = struct {
    allocator: std.mem.Allocator,
    params: adpcm.Params,
    input: []u8,
    staging: []i16,
    /// Samples currently in `staging` and the read position inside them.
    filled: usize = 0,
    pos: usize = 0,
    /// Compressed bytes left in `data`, or `unknown_size` for "until EOF".
    remaining: u64,
};

pub const Decoder = struct {
    reader: *std.Io.Reader,
    info: types.Info,
    sample_format: SampleFormat,
    bytes_per_sample: usize,
    frame_bytes: usize,
    /// Bytes left in `data`, or `unknown_size` for "until EOF".
    remaining: u64,
    done: bool = false,
    block: ?BlockState = null,

    /// Decode into `out`. See `root.Decoder.read` for the public contract.
    pub fn read(self: *Decoder, out: []i16) types.Error!usize {
        if (out.len == 0) return 0;
        if (self.done) return 0;

        if (self.block) |*block| return self.readBlock(block, out);

        const channels: usize = self.info.channels;
        const capacity_frames = out.len / channels;
        if (capacity_frames == 0) return error.ShortBuffer;

        var want_frames = capacity_frames;
        if (self.remaining != unknown_size) {
            const left_frames64 = self.remaining / self.frame_bytes;
            const left_frames: usize = std.math.cast(usize, left_frames64) orelse std.math.maxInt(usize);
            if (left_frames == 0) {
                self.done = true;
                return 0;
            }
            want_frames = @min(want_frames, left_frames);
        }

        // Fast path: PCM16 is already the output representation. Read directly
        // into the caller's i16 slice (no scratch copy) and byte-swap only on
        // a big-endian host.
        if (self.sample_format == .pcm and self.bytes_per_sample == 2) {
            const want_bytes = want_frames * self.frame_bytes;
            const dst = std.mem.sliceAsBytes(out)[0..want_bytes];
            const got = try self.readBytes(dst);
            const frames = got / self.frame_bytes;
            const samples = frames * channels;
            if (builtin.cpu.arch.endian() == .big) {
                std.mem.byteSwapAllElements(i16, out[0..samples]);
            }
            return samples;
        }

        return self.readConverted(out, want_frames);
    }

    pub fn deinit(self: *Decoder) void {
        if (self.block) |*block| {
            block.allocator.free(block.input);
            block.allocator.free(block.staging);
            self.block = null;
        }
    }

    fn readConverted(self: *Decoder, out: []i16, want_frames: usize) types.Error!usize {
        const channels: usize = self.info.channels;
        var scratch: [4096]u8 = undefined;
        const max_chunk_frames = scratch.len / self.frame_bytes;
        if (max_chunk_frames == 0) return error.Corrupt;

        var frames_done: usize = 0;
        while (frames_done < want_frames) {
            const chunk_frames = @min(want_frames - frames_done, max_chunk_frames);
            const chunk_bytes = chunk_frames * self.frame_bytes;
            const got = try self.readBytes(scratch[0..chunk_bytes]);
            const got_frames = got / self.frame_bytes;
            if (got_frames == 0) break;

            const dst_start = frames_done * channels;
            const dst_len = got_frames * channels;
            convertSamples(
                scratch[0..got],
                self.sample_format,
                self.bytes_per_sample,
                out[dst_start..][0..dst_len],
            );
            frames_done += got_frames;
            if (got < chunk_bytes) break;
        }
        return frames_done * channels;
    }

    // -----------------------------------------------------------------------
    // Block codecs (IMA / MS ADPCM)
    // -----------------------------------------------------------------------

    fn readBlock(self: *Decoder, state: *BlockState, out: []i16) types.Error!usize {
        const channels: usize = self.info.channels;
        const capacity_frames = out.len / channels;
        if (capacity_frames == 0) return error.ShortBuffer;

        var frames: usize = 0;
        while (frames < capacity_frames) {
            if (state.pos >= state.filled) {
                if (!try self.nextBlock(state)) break;
            }
            const available = (state.filled - state.pos) / channels;
            const take = @min(available, capacity_frames - frames);
            const samples = take * channels;
            @memcpy(
                out[frames * channels ..][0..samples],
                state.staging[state.pos..][0..samples],
            );
            state.pos += samples;
            frames += take;
            if (state.pos >= state.filled) {
                state.pos = 0;
                state.filled = 0;
            }
        }

        if (frames == 0) {
            self.done = true;
            return 0;
        }
        return frames * channels;
    }

    /// Decode the next compressed block into the staging buffer. Returns false
    /// at a clean end of stream.
    fn nextBlock(self: *Decoder, state: *BlockState) types.Error!bool {
        const known = state.remaining != unknown_size;
        var want = state.input.len;
        if (known) {
            if (state.remaining == 0) return false;
            want = @intCast(@min(state.remaining, @as(u64, state.input.len)));
        }

        const got = try self.fillBlock(state.input[0..want]);
        if (got == 0) {
            // A declared length that stops before the first block of the
            // stream is a truncation; an unknown length is simply EOF.
            if (known) return error.Truncated;
            return false;
        }
        if (known) {
            state.remaining -= @as(u64, got);
            if (got < want) return error.Truncated;
        }

        const frames = try adpcm.decodeBlock(state.params, state.input[0..got], state.staging);
        if (frames == 0) {
            // Only a final fragment shorter than the block header can get
            // here: with a declared size that is a broken header.
            return if (known) error.Corrupt else false;
        }

        state.filled = frames * @as(usize, self.info.channels);
        state.pos = 0;
        return true;
    }

    /// Fill `dst` from the reader unless the stream ends first. A single
    /// `readSliceShort` may under-fill a streaming reader even when more is
    /// coming, so block framing must loop.
    fn fillBlock(self: *Decoder, dst: []u8) types.Error!usize {
        var got: usize = 0;
        while (got < dst.len) {
            const n = try readSome(self.reader, dst[got..]);
            if (n == 0) break;
            got += n;
        }
        return got;
    }

    /// Read exactly `dst.len` bytes when the length is known (EOF there is a
    /// truncation), or up to `dst.len` when it is not.
    fn readBytes(self: *Decoder, dst: []u8) types.Error!usize {
        if (self.remaining != unknown_size) {
            try readExact(self.reader, dst);
            self.remaining -= dst.len;
            if (self.remaining == 0) self.done = true;
            return dst.len;
        }

        const got = try readSome(self.reader, dst);
        if (got == 0) {
            self.done = true;
            return 0;
        }
        if (got % self.frame_bytes != 0) {
            self.done = true;
            return error.Truncated;
        }
        if (got < dst.len) self.done = true;
        return got;
    }
};

/// Open a WAV decoder after the caller has already read the 12-byte RIFF
/// header into `riff`. `reader` must be positioned right after those 12 bytes.
pub fn open(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    riff: *const [12]u8,
) types.Error!Decoder {
    if (!std.mem.eql(u8, riff[0..4], "RIFF") or !std.mem.eql(u8, riff[8..12], "WAVE")) {
        return error.NotAudio;
    }

    var fmt: ?Fmt = null;

    while (true) {
        var chunk_header: [8]u8 = undefined;
        const got = try readSome(reader, &chunk_header);
        if (got != chunk_header.len) return error.Truncated;

        const id = chunk_header[0..4];
        const size: u32 = std.mem.readInt(u32, chunk_header[4..8], .little);

        if (std.mem.eql(u8, id, "fmt ")) {
            const size64: u64 = size;
            const kept64 = @min(size64, fmt_buf_len);
            const take: usize = @intCast(kept64);
            var payload: [fmt_buf_len]u8 = undefined;
            try readExact(reader, payload[0..take]);
            if (size64 > kept64) try skip(reader, size64 - kept64);
            if (size64 & 1 != 0) try skip(reader, 1);
            if (fmt == null) fmt = try parseFmt(payload[0..take], size);
            continue;
        }

        if (std.mem.eql(u8, id, "data")) {
            // Without a preceding fmt we would have to rewind to the payload
            // later; a streaming decoder cannot do that. Say so explicitly.
            const parsed = fmt orelse return error.Unsupported;
            return openData(allocator, reader, parsed, size);
        }

        // LIST / fact / JUNK / anything else: skip payload and odd padding.
        try skip(reader, size);
        if (size & 1 != 0) try skip(reader, 1);
    }
}

fn openData(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    fmt: Fmt,
    size: u32,
) types.Error!Decoder {
    if (fmt.adpcm_params) |params| return openAdpcm(allocator, reader, fmt, params, size);

    var remaining: u64 = unknown_size;
    var total_frames: ?u64 = null;

    if (size != data_size_unknown) {
        const size64: u64 = size;
        const frame_bytes: u64 = @intCast(fmt.frame_bytes);
        if (size64 % frame_bytes != 0) return error.Corrupt;
        remaining = size64;
        total_frames = size64 / frame_bytes;
    }

    return .{
        .reader = reader,
        .info = .{
            .format = .wav,
            .sample_rate = fmt.sample_rate,
            .channels = fmt.channels,
            .bits_per_sample = fmt.bits,
            .total_frames = total_frames,
        },
        .sample_format = fmt.format,
        .bytes_per_sample = fmt.bytes_per_sample,
        .frame_bytes = fmt.frame_bytes,
        .remaining = remaining,
    };
}

fn openAdpcm(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    fmt: Fmt,
    params: adpcm.Params,
    size: u32,
) types.Error!Decoder {
    var remaining: u64 = unknown_size;
    var total_frames: ?u64 = null;
    if (size != data_size_unknown) {
        remaining = size;
        total_frames = adpcm.framesForData(params, size);
    }

    const capacity_frames = adpcm.samplesForBlock(params, params.block_align);
    if (capacity_frames == 0) return error.Corrupt;

    // One compressed block plus its decoded samples: the whole allocation is
    // bounded by 64 KiB (block_align) * 4 + frames * channels * 2 bytes, and
    // `read` never allocates.
    const staging = try allocator.alloc(i16, capacity_frames * params.channels);
    errdefer allocator.free(staging);
    const input = try allocator.alloc(u8, params.block_align);
    errdefer allocator.free(input);

    return .{
        .reader = reader,
        .info = .{
            .format = .wav,
            .sample_rate = fmt.sample_rate,
            .channels = fmt.channels,
            // Block codecs expand to 16-bit linear samples.
            .bits_per_sample = 16,
            .total_frames = total_frames,
        },
        .sample_format = .pcm,
        .bytes_per_sample = 0,
        .frame_bytes = 0,
        .remaining = remaining,
        .block = .{
            .allocator = allocator,
            .params = params,
            .input = input,
            .staging = staging,
            .remaining = remaining,
        },
    };
}

fn parseFmt(chunk: []const u8, declared_size: u32) types.Error!Fmt {
    if (chunk.len < 16 or declared_size < 16) return error.Corrupt;

    const tag = readU16(chunk, 0);
    const channels = readU16(chunk, 2);
    const sample_rate = readU32(chunk, 4);
    const block_align = readU16(chunk, 12);
    const bits = readU16(chunk, 14);

    if (channels == 0 or sample_rate == 0 or bits == 0) return error.Corrupt;
    if (channels > types.max_channels) return error.Unsupported;

    // Block codecs first: their `fmt ` extension carries parameters the
    // linear path never sees, and their fields mean different things
    // (`bits` is the nibble width, `block_align` is the block size).
    if (tag == format_ms_adpcm or tag == format_ima_adpcm) {
        if (bits != 4) return error.Unsupported;
        if (block_align == 0) return error.Corrupt;
        const kind: adpcm.Kind = if (tag == format_ms_adpcm) .ms else .ima;
        const params = try adpcm.parseFmt(kind, channels, block_align, chunk, declared_size);
        return .{
            .sample_rate = sample_rate,
            .channels = channels,
            .bits = 16,
            .format = .pcm,
            .bytes_per_sample = 0,
            .frame_bytes = 0,
            .adpcm_params = params,
        };
    }

    var format: SampleFormat = undefined;
    if (tag == format_extensible) {
        if (declared_size < 40 or chunk.len < 40) return error.Corrupt;
        const cb_size = readU16(chunk, 16);
        if (cb_size < 22) return error.Corrupt;

        const valid_bits = readU16(chunk, 18);
        if (valid_bits == 0 or valid_bits > bits) return error.Corrupt;

        const subformat = chunk[24..40];
        if (std.mem.eql(u8, subformat, &guid_pcm)) {
            format = .pcm;
        } else if (std.mem.eql(u8, subformat, &guid_float)) {
            format = .float;
        } else {
            return error.Unsupported;
        }
    } else if (tag == format_pcm) {
        format = .pcm;
    } else if (tag == format_float) {
        format = .float;
    } else if (tag == format_alaw) {
        format = .alaw;
    } else if (tag == format_mulaw) {
        format = .mulaw;
    } else {
        // GSM, MP3-in-WAV, ...: named refusals instead of guesses.
        return error.Unsupported;
    }

    const bytes_per_sample: usize = switch (format) {
        .pcm => switch (bits) {
            8 => 1,
            16 => 2,
            24 => 3,
            32 => 4,
            else => return error.Unsupported,
        },
        .float => if (bits == 32) 4 else return error.Unsupported,
        // G.711 always codes one 8-bit sample per byte; a header claiming
        // anything else is a different law or a broken file.
        .alaw, .mulaw => if (bits == 8) 1 else return error.Unsupported,
    };

    const frame_bytes = @as(usize, channels) * bytes_per_sample;
    if (@as(usize, block_align) != frame_bytes) return error.Corrupt;

    // G.711 expands to 16-bit linear samples, so that is what `read`
    // produces and what `Info.bits_per_sample` reports.
    const reported_bits: u16 = switch (format) {
        .pcm, .float => bits,
        .alaw, .mulaw => 16,
    };

    return .{
        .sample_rate = sample_rate,
        .channels = channels,
        .bits = reported_bits,
        .format = format,
        .bytes_per_sample = bytes_per_sample,
        .frame_bytes = frame_bytes,
    };
}

// ---------------------------------------------------------------------------
// Reader helpers: map the two Reader errors once, so every parse failure is a
// public, named error.
// ---------------------------------------------------------------------------

fn readSome(reader: *std.Io.Reader, buf: []u8) types.Error!usize {
    return reader.readSliceShort(buf) catch |err| switch (err) {
        error.ReadFailed => error.Io,
    };
}

fn readExact(reader: *std.Io.Reader, buf: []u8) types.Error!void {
    const got = try readSome(reader, buf);
    if (got != buf.len) return error.Truncated;
}

fn skip(reader: *std.Io.Reader, count: u64) types.Error!void {
    reader.discardAll64(count) catch |err| switch (err) {
        error.EndOfStream => return error.Truncated,
        error.ReadFailed => return error.Io,
    };
}

// ---------------------------------------------------------------------------
// Sample conversion. All paths end at i16 so callers have one buffer format.
// ---------------------------------------------------------------------------

fn convertSamples(
    src: []const u8,
    format: SampleFormat,
    bytes_per_sample: usize,
    dst: []i16,
) void {
    for (dst, 0..) |*slot, i| {
        const off = i * bytes_per_sample;
        slot.* = switch (format) {
            .pcm => switch (bytes_per_sample) {
                1 => @intCast((@as(i32, src[off]) - 128) * 256),
                3 => @intCast(readI24(src, off) >> 8),
                4 => @intCast(readI32(src, off) >> 16),
                else => unreachable,
            },
            .float => floatToI16(@bitCast(readU32(src, off))),
            .mulaw => g711.mulaw_table[src[off]],
            .alaw => g711.alaw_table[src[off]],
        };
    }
}

fn floatToI16(value: f32) i16 {
    if (std.math.isNan(value)) return 0;
    const clamped = std.math.clamp(value, -1.0, 1.0);
    const scaled = @round(clamped * 32768.0);
    if (scaled >= 32767.0) return 32767;
    if (scaled <= -32768.0) return -32768;
    return @intFromFloat(scaled);
}

fn readU16(bytes: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, bytes[off..][0..2], .little);
}

fn readU32(bytes: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, bytes[off..][0..4], .little);
}

fn readI32(bytes: []const u8, off: usize) i32 {
    return @bitCast(readU32(bytes, off));
}

fn readI24(bytes: []const u8, off: usize) i32 {
    const raw: u32 = @as(u32, bytes[off]) |
        (@as(u32, bytes[off + 1]) << 8) |
        (@as(u32, bytes[off + 2]) << 16);
    if (raw & 0x0080_0000 != 0) return @bitCast(raw | 0xFF00_0000);
    return @intCast(raw);
}
