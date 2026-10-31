//! Streaming FLAC decoder.
//!
//! `open` parses the metadata (STREAMINFO plus skipped blocks) and stops at the
//! first frame. `read` decodes whole frames on demand, so memory is one frame
//! of planar i32 samples and never the file.
//!
//! Samples are converted to i16 at the boundary, per the rule documented in
//! README: sources of 16 bits or fewer shift left, wider ones shift right. FLAC
//! 8-bit PCM is signed, so no unsigned bias is applied (unlike WAV).

const std = @import("std");
const types = @import("types.zig");
const meta = @import("flac_meta.zig");
const frame = @import("flac_frame.zig");

pub const Decoder = struct {
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    info: types.Info,
    stream: meta.StreamInfo,
    /// Planar frame buffer: `samples[channel * frame_stride + sample]`.
    samples: []i32 = &.{},
    frame_stride: usize = 0,
    /// Samples per channel still deliverable from the current frame.
    frame_len: usize = 0,
    frame_pos: usize = 0,
    delivered: u64 = 0,
    done: bool = false,
    /// A frame-level error discovered after some samples were already handed
    /// to the caller. `read` returns those samples first, then this error, so a
    /// stream that goes corrupt or truncated halfway still yields its valid
    /// prefix.
    pending_error: ?types.Error = null,

    /// Decode up to `out.len / channels` frames. See `root.Decoder.read`.
    pub fn read(self: *Decoder, out: []i16) types.Error!usize {
        if (out.len == 0) return 0;
        if (self.pending_error) |err| return err;
        if (self.done) return 0;

        const channels: usize = self.stream.channels;
        const capacity = out.len / channels;
        if (capacity == 0) return error.ShortBuffer;

        var written: usize = 0;
        while (written < capacity) {
            if (self.frame_pos == self.frame_len) {
                const more = self.nextFrame() catch |err| {
                    self.pending_error = err;
                    if (written == 0) return err;
                    break;
                };
                if (!more) break;
            }
            const available = self.frame_len - self.frame_pos;
            const want = @min(available, capacity - written);
            self.store(out[written * channels ..][0 .. want * channels], want);
            self.frame_pos += want;
            self.delivered += want;
            written += want;
        }
        return written * channels;
    }

    pub fn deinit(self: *Decoder) void {
        if (self.samples.len != 0) self.allocator.free(self.samples);
        self.* = undefined;
    }

    /// Decode one frame into the sample buffer. Returns false at end of stream.
    fn nextFrame(self: *Decoder) types.Error!bool {
        const total = self.info.total_frames;
        if (total) |declared| {
            if (self.delivered >= declared) {
                self.done = true;
                return false;
            }
        }

        _ = self.reader.peekByte() catch |err| switch (err) {
            error.EndOfStream => {
                if (total) |declared| {
                    if (self.delivered < declared) return error.Truncated;
                }
                self.done = true;
                return false;
            },
            error.ReadFailed => return error.Io,
        };

        const header = try frame.readHeader(self.reader);
        if (header.channels() != self.stream.channels) return error.Corrupt;
        // STREAMINFO declares the largest block in the stream; anything larger
        // is a corrupt header and would also overflow the frame buffer that
        // `open` sized exactly once.
        if (header.block_size > self.stream.max_block_size) return error.Corrupt;

        const stride: usize = header.block_size;
        const needed = stride * self.stream.channels;
        try frame.decode(self.reader, header, &self.stream, self.samples[0..needed]);

        var len = stride;
        if (total) |declared| {
            const remaining = declared - self.delivered;
            if (len > remaining) len = @intCast(remaining);
        }
        self.frame_stride = stride;
        self.frame_len = len;
        self.frame_pos = 0;
        return true;
    }

    fn store(self: *Decoder, out: []i16, frames: usize) void {
        const channels: usize = self.stream.channels;
        const bps = self.stream.bits_per_sample;
        const start = self.frame_pos;
        if (bps <= 16) {
            const shift: u5 = @intCast(16 - bps);
            for (0..frames) |i| {
                const base = start + i;
                for (0..channels) |channel| {
                    const value = self.samples[channel * self.frame_stride + base];
                    out[i * channels + channel] = @intCast(@as(i64, value) << shift);
                }
            }
        } else {
            const shift: u5 = @intCast(bps - 16);
            for (0..frames) |i| {
                const base = start + i;
                for (0..channels) |channel| {
                    const value = self.samples[channel * self.frame_stride + base];
                    out[i * channels + channel] = @intCast(value >> shift);
                }
            }
        }
    }
};

/// Open a FLAC decoder. `prefix` is the 12 bytes the caller already consumed:
/// `fLaC`, the STREAMINFO block header and its first 4 payload bytes.
pub fn open(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    prefix: *const [12]u8,
) types.Error!Decoder {
    const stream = try meta.open(reader, prefix);
    // One allocation at open, sized by STREAMINFO: every `read` after this is
    // allocation-free, and a corrupt frame cannot grow it.
    const capacity: usize = @as(usize, stream.max_block_size) * stream.channels;
    const samples = try allocator.alloc(i32, capacity);
    return .{
        .allocator = allocator,
        .reader = reader,
        .info = .{
            .format = .flac,
            .sample_rate = stream.sample_rate,
            .channels = stream.channels,
            .bits_per_sample = stream.bits_per_sample,
            .total_frames = stream.frameCount(),
        },
        .stream = stream,
        .samples = samples,
    };
}
