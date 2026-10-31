//! AIFF (Audio Interchange File Format) decoder.
//!
//! The container is a big-endian `FORM` of type `AIFF`:
//!
//!   * `COMM` declares channels, frame count, sample size and the sample rate
//!     as an 80-bit IEEE 754 extended value (10 bytes);
//!   * `SSND` holds an 8-byte offset/block-size header, an optional offset
//!     region, then the samples.
//!
//! PCM 8/16/24/32 is supported, all big-endian and all signed: 8-bit AIFF is
//! signed, unlike 8-bit WAV's 128 bias. `AIFC` (the compressed variant, which
//! is also how 32/64-bit float is signalled via `fl32`/`fl64`) is rejected by
//! name. Chunks of unknown type are skipped with the AIFF padding rule, and
//! `COMM` must precede `SSND`: a streaming decoder cannot rewind to the
//! samples after learning the format.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");

/// `SSND` size used by writers that cannot seek back; treat as "until EOF".
const unknown_size = std.math.maxInt(u64);

const Comm = struct {
    channels: u16,
    frames: u32,
    bits: u16,
    sample_rate: u32,
    bytes_per_sample: usize,
    frame_bytes: usize,
};

pub const Decoder = struct {
    reader: *std.Io.Reader,
    info: types.Info,
    bytes_per_sample: usize,
    frame_bytes: usize,
    /// Frames the `COMM` chunk still promises.
    frames_left: u64,
    /// Bytes left in the `SSND` payload, or `unknown_size`.
    bytes_left: u64,
    done: bool = false,

    /// Decode into `out`. See `root.Decoder.read` for the public contract.
    pub fn read(self: *Decoder, out: []i16) types.Error!usize {
        if (out.len == 0) return 0;
        if (self.done) return 0;

        const channels: usize = self.info.channels;
        const capacity_frames = out.len / channels;
        if (capacity_frames == 0) return error.ShortBuffer;
        if (self.frames_left == 0) {
            self.done = true;
            return 0;
        }

        var want = @min(capacity_frames, std.math.cast(usize, self.frames_left) orelse
            std.math.maxInt(usize));
        if (self.bytes_left != unknown_size) {
            const available = self.bytes_left / self.frame_bytes;
            want = @min(want, std.math.cast(usize, available) orelse std.math.maxInt(usize));
            if (want == 0) {
                // `COMM` promises more frames than `SSND` can hold.
                self.done = true;
                return error.Truncated;
            }
        }

        // 16-bit samples are already the output representation; read them
        // straight into the caller's slice and fix the byte order.
        if (self.bytes_per_sample == 2) {
            const want_bytes = want * self.frame_bytes;
            const dst = std.mem.sliceAsBytes(out)[0..want_bytes];
            try readExact(self.reader, dst);
            self.consume(want);
            if (builtin.cpu.arch.endian() == .little) {
                std.mem.byteSwapAllElements(i16, out[0 .. want * channels]);
            }
            return want * channels;
        }

        return self.readConverted(out, want);
    }

    pub fn deinit(self: *Decoder) void {
        // AIFF owns no memory.
        _ = self;
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
            try readExact(self.reader, scratch[0..chunk_bytes]);
            convertSamples(
                scratch[0..chunk_bytes],
                self.bytes_per_sample,
                out[frames_done * channels ..][0 .. chunk_frames * channels],
            );
            frames_done += chunk_frames;
        }
        self.consume(frames_done);
        return frames_done * channels;
    }

    fn consume(self: *Decoder, frames: usize) void {
        const bytes = @as(u64, frames) * self.frame_bytes;
        self.frames_left -= @as(u64, frames);
        if (self.bytes_left != unknown_size) self.bytes_left -= bytes;
        if (self.frames_left == 0) self.done = true;
    }
};

/// Open an AIFF decoder after the caller has read the 12-byte `FORM` header.
/// `reader` must be positioned right after those 12 bytes.
pub fn open(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    form: *const [12]u8,
) types.Error!Decoder {
    _ = allocator; // AIFF decoding does not allocate.
    if (!std.mem.eql(u8, form[0..4], "FORM")) return error.NotAudio;
    // AIFC carries a compression type in COMM; its PCM payloads would be
    // fine, but supporting the variant properly means parsing the extra
    // compression fields, so it is refused by name instead of guessed.
    if (std.mem.eql(u8, form[8..12], "AIFC")) return error.Unsupported;
    if (!std.mem.eql(u8, form[8..12], "AIFF")) return error.NotAudio;

    var comm: ?Comm = null;

    while (true) {
        var chunk_header: [8]u8 = undefined;
        const got = try readSome(reader, &chunk_header);
        if (got != chunk_header.len) return error.Truncated;

        const id = chunk_header[0..4];
        const size: u32 = std.mem.readInt(u32, chunk_header[4..8], .big);
        const size64: u64 = size;

        if (std.mem.eql(u8, id, "COMM")) {
            if (size < 18) return error.Corrupt;
            var payload: [18]u8 = undefined;
            try readExact(reader, &payload);
            if (size64 > payload.len) try skip(reader, size64 - payload.len);
            if (size & 1 != 0) try skip(reader, 1);
            if (comm == null) comm = try parseComm(&payload);
            continue;
        }

        if (std.mem.eql(u8, id, "SSND")) {
            // Without COMM the channel count and frame size are unknown and
            // a streaming decoder cannot rewind to the samples later.
            const parsed = comm orelse return error.Unsupported;
            return openSound(reader, parsed, size);
        }

        try skip(reader, size64);
        if (size & 1 != 0) try skip(reader, 1);
    }
}

fn openSound(reader: *std.Io.Reader, comm: Comm, size: u32) types.Error!Decoder {
    if (size < 8) return error.Corrupt;

    var header: [8]u8 = undefined;
    try readExact(reader, &header);
    const offset = std.mem.readInt(u32, header[0..4], .big);
    const payload_bytes: u64 = size;
    if (offset > payload_bytes - 8) return error.Corrupt;
    if (offset > 0) try skip(reader, offset);

    const unknown = size == 0xFFFF_FFFF;
    return .{
        .reader = reader,
        .info = .{
            .format = .aiff,
            .sample_rate = comm.sample_rate,
            .channels = comm.channels,
            .bits_per_sample = comm.bits,
            .total_frames = comm.frames,
        },
        .bytes_per_sample = comm.bytes_per_sample,
        .frame_bytes = comm.frame_bytes,
        .frames_left = comm.frames,
        .bytes_left = if (unknown) unknown_size else payload_bytes - 8 - offset,
    };
}

fn parseComm(payload: *const [18]u8) types.Error!Comm {
    const channels = std.mem.readInt(u16, payload[0..2], .big);
    const frames = std.mem.readInt(u32, payload[2..6], .big);
    const bits = std.mem.readInt(u16, payload[6..8], .big);
    const sample_rate = try extendedToU32(payload[8..18]);

    if (channels == 0) return error.Corrupt;
    if (channels > types.max_channels) return error.Unsupported;
    if (sample_rate == 0) return error.Corrupt;

    const bytes_per_sample: usize = switch (bits) {
        8, 16, 24, 32 => bits / 8,
        // 1..32-bit packed PCM and float payloads live in AIFC; neither is
        // supported here, and guessing a container width would corrupt the
        // sample stream.
        else => return error.Unsupported,
    };

    return .{
        .channels = channels,
        .frames = frames,
        .bits = bits,
        .sample_rate = sample_rate,
        .bytes_per_sample = bytes_per_sample,
        .frame_bytes = @as(usize, channels) * bytes_per_sample,
    };
}

/// Parse the 80-bit IEEE 754 extended value AIFF uses for the sample rate.
///
/// Layout: 1 sign bit, 15-bit biased exponent (bias 16383), then an explicit
/// integer bit plus 63 fraction bits, so the value is
/// `mantissa * 2^(exponent - 16383 - 63)`. A lookup table of common rates is
/// not enough: 8012, 22254, 37800 and 44056 all occur in real files, and any
/// value that fits `u32` is a valid AIFF rate. Fractional rates are rounded to
/// nearest because `Info.sample_rate` is an integer.
pub fn extendedToU32(bytes: []const u8) types.Error!u32 {
    if (bytes.len < 10) return error.Corrupt;
    const raw_exponent = (@as(u16, bytes[0]) << 8) | bytes[1];
    if (raw_exponent & 0x8000 != 0) return error.Corrupt; // negative rate
    const exponent: i32 = raw_exponent & 0x7FFF;

    var mantissa: u64 = 0;
    for (bytes[2..10]) |byte| mantissa = (mantissa << 8) | byte;

    if (exponent == 0x7FFF) return error.Unsupported; // infinity / NaN
    if (exponent == 0) {
        // Zero is "no rate"; a denormal is far below any usable rate.
        return if (mantissa == 0) 0 else error.Corrupt;
    }

    // The arithmetic is done in u128 so both the left shift for huge rates
    // and the rounding shift for tiny ones stay in range.
    const wide: u128 = mantissa;
    const shift: i32 = exponent - 16383 - 63;
    var value: u128 = undefined;
    if (shift >= 0) {
        if (shift > 127) return error.Unsupported;
        value = wide << @intCast(shift);
    } else {
        const right: u32 = @intCast(-shift);
        if (right > 127) return error.Corrupt; // far below 1 Hz
        value = wide >> @intCast(right);
        // Round the fractional remainder to nearest, half up.
        const mask = (@as(u128, 1) << @intCast(right)) - 1;
        const remainder = wide & mask;
        const half = @as(u128, 1) << @intCast(right - 1);
        if (remainder >= half) value += 1;
    }

    if (value > std.math.maxInt(u32)) return error.Unsupported;
    if (value == 0) return error.Corrupt;
    return @intCast(value);
}

// ---------------------------------------------------------------------------
// Reader helpers
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
// Sample conversion: big-endian source to native i16.
// ---------------------------------------------------------------------------

fn convertSamples(src: []const u8, bytes_per_sample: usize, dst: []i16) void {
    for (dst, 0..) |*slot, i| {
        const off = i * bytes_per_sample;
        slot.* = switch (bytes_per_sample) {
            1 => @as(i16, @as(i8, @bitCast(src[off]))) * 256,
            3 => @intCast(readI24(src, off) >> 8),
            4 => @intCast(readI32(src, off) >> 16),
            else => unreachable,
        };
    }
}

fn readI32(bytes: []const u8, off: usize) i32 {
    return @bitCast(std.mem.readInt(u32, bytes[off..][0..4], .big));
}

fn readI24(bytes: []const u8, off: usize) i32 {
    const raw: u32 = (@as(u32, bytes[off]) << 16) |
        (@as(u32, bytes[off + 1]) << 8) |
        @as(u32, bytes[off + 2]);
    if (raw & 0x0080_0000 != 0) return @bitCast(raw | 0xFF00_0000);
    return @intCast(raw);
}
