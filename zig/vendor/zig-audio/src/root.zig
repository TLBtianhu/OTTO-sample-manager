//! zig-audio: streaming audio decoding in pure Zig.
//!
//! A FLAC decoder covering CONSTANT, VERBATIM, FIXED(0..4) and LPC(1..32)
//! subframes with Rice partitions, independent channels and the left/side,
//! right/side and mid/side channel assignments. See README for the support
//! matrix.
//!
//! The API deliberately has one output path: interleaved i16. Source PCM
//! (8/16/24/32) and float32 are converted inside the decoder, so a player
//! never branches on source format.

const std = @import("std");
const types = @import("types.zig");
const wav = @import("wav.zig");
const flac = @import("flac.zig");

pub const Format = types.Format;
pub const Info = types.Info;
pub const Error = types.Error;

/// Reader buffer size used by `openFile` / `openFileWithIo`. One refill is one
/// read from the file, so a 512 KiB file takes at least eight reads and never
/// one file-sized allocation.
const file_read_buffer_len = 64 * 1024;

/// State owned by the convenience constructors. It lives on the heap because
/// `wav.Decoder` and `flac.Decoder` store a pointer to the Reader, and a
/// `Decoder` returned by value would otherwise move the Reader's address.
const OwnedSource = union(enum) {
    bytes: *std.Io.Reader,
    file: *FileSource,
};

const FileSource = struct {
    reader: std.Io.File.Reader,
    buffer: [file_read_buffer_len]u8,
};

/// Identify a format from its first bytes without touching a reader or
/// modifying `header`.
///
/// `header` is the beginning of the stream, not a full file: 4 bytes are
/// enough to recognize FLAC's `fLaC` magic, 12 bytes are needed for RIFF/WAVE.
/// Anything shorter returns null. RF64 and RIFX return null on purpose: they
/// are WAV-like containers this version does not decode, and `probe` never
/// promises a format that `open` cannot open.
pub fn probe(header: []const u8) ?Format {
    if (header.len >= 4 and std.mem.eql(u8, header[0..4], "fLaC")) return .flac;
    if (header.len >= 12 and std.mem.eql(u8, header[0..4], "RIFF") and
        std.mem.eql(u8, header[8..12], "WAVE"))
    {
        return .wav;
    }
    return null;
}

/// Open a decoder at the current position of `reader`.
///
/// Consumes the 12-byte signature and scans RIFF chunks up to the start of the
/// `data` payload. The reader is borrowed: the caller owns it and must keep it
/// alive longer than the returned `Decoder`.
pub fn open(allocator: std.mem.Allocator, reader: *std.Io.Reader) Error!Decoder {
    var header: [12]u8 = undefined;
    const got = reader.readSliceShort(&header) catch |err| switch (err) {
        error.ReadFailed => return error.Io,
    };
    if (got == 0) return error.NotAudio;
    if (got < header.len) return error.Truncated;

    if (std.mem.eql(u8, header[0..4], "fLaC")) {
        const dec = try flac.open(allocator, reader, &header);
        return .{
            .info = dec.info,
            .allocator = allocator,
            .impl = .{ .flac = dec },
        };
    }

    if (std.mem.eql(u8, header[0..4], "RIFF") and std.mem.eql(u8, header[8..12], "WAVE")) {
        const dec = try wav.open(allocator, reader, &header);
        return .{
            .info = dec.info,
            .allocator = allocator,
            .impl = .{ .wav = dec },
        };
    }

    // Recognize the containers we reject, so the error is Unsupported rather
    // than a vague NotAudio.
    if ((std.mem.eql(u8, header[0..4], "RF64") or std.mem.eql(u8, header[0..4], "RIFX")) and
        std.mem.eql(u8, header[8..12], "WAVE"))
    {
        return error.Unsupported;
    }

    return error.NotAudio;
}

/// Open a decoder over a byte slice, without consuming or copying it.
///
/// `bytes` is borrowed, not copied: the caller keeps ownership and must keep
/// it alive (and unmodified) until `deinit`. The only allocation is a small
/// `std.Io.Reader` record; the audio bytes themselves stay where they are. For
/// a copy-free wrapper around a caller-owned handle, see README
/// "接入你自己的文件层".
pub fn openBytes(allocator: std.mem.Allocator, bytes: []const u8) Error!Decoder {
    const reader = try allocator.create(std.Io.Reader);
    errdefer allocator.destroy(reader);
    reader.* = std.Io.Reader.fixed(bytes);

    var dec = try open(allocator, reader);
    dec.source = .{ .bytes = reader };
    return dec;
}

/// Open a decoder over a `std.Io.File`, streaming from the file.
///
/// The file is borrowed: `deinit` does not close it. A 64 KiB read buffer and
/// the Reader state are allocated from `allocator` and released by `deinit`;
/// the file itself is never read into one buffer. Reads are positional and
/// start at offset 0, matching `file.reader()`'s default.
///
/// Zig 0.17 moved `File` to `std.Io.File` and made `file.reader()` take an
/// `Io`. This convenience entry uses `std.Io.Threaded.global_single_threaded`,
/// which is the right choice for a single-threaded blocking app. If the caller
/// already owns an `Io` (concurrency, cancelation, a custom event loop), use
/// `openFileWithIo` instead so the library never reaches for a global.
pub fn openFile(allocator: std.mem.Allocator, file: std.Io.File) Error!Decoder {
    return openFileWithIo(allocator, std.Io.Threaded.global_single_threaded.io(), file);
}

/// Like `openFile`, but with an explicit `Io` to perform the reads.
pub fn openFileWithIo(
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
) Error!Decoder {
    const source = try allocator.create(FileSource);
    errdefer allocator.destroy(source);
    source.reader = file.reader(io, &source.buffer);

    var dec = try open(allocator, &source.reader.interface);
    dec.source = .{ .file = source };
    return dec;
}

/// Public surface: `info`, `read`, and `deinit`. The remaining fields are
/// implementation details and must not be mutated by callers.
pub const Decoder = struct {
    info: Info,
    allocator: std.mem.Allocator,
    impl: union(enum) {
        wav: wav.Decoder,
        flac: flac.Decoder,
    },
    /// Non-null only for `openBytes` / `openFile*`: reader state owned by this
    /// decoder. Plain `open` borrows the caller's reader and leaves it null.
    source: ?OwnedSource = null,

    /// Decode up to `out.len / info.channels` frames into `out` as
    /// interleaved i16, returning the number of i16 elements written.
    ///
    /// Samples are frame-major: frame `f`, channel `c` is
    /// `out[f * info.channels + c]`, with source channel order preserved.
    /// Conversion is fixed for every source format: 8-bit unsigned WAV PCM uses
    /// `(byte - 128) << 8`, FLAC 8-bit is signed (`sample << 8`), 16-bit is
    /// copied, and wider sources shift right so the top 16 bits survive
    /// (WAV 24-bit by 8, 32-bit by 16; FLAC by `bits - 16`). Float32 is clamped
    /// to [-1, 1] and rounded to i16. Integer conversions match ffmpeg
    /// `-f s16le` sample for sample.
    ///
    /// Returns 0 at end of stream. An empty `out` is a no-op that also returns
    /// 0, so callers must not use a zero-length read as an EOF probe. The tail
    /// of `out` is untouched when `out.len` is not a multiple of `channels`.
    /// A non-empty `out` smaller than one frame returns `error.ShortBuffer`.
    pub fn read(self: *Decoder, out: []i16) Error!usize {
        switch (self.impl) {
            .wav => |*dec| return dec.read(out),
            .flac => |*dec| return dec.read(out),
        }
    }

    /// Release decoder-owned memory. Does not close the caller's reader or
    /// file; for `openBytes` / `openFile*` it also releases the wrapper state
    /// (but never the bytes or the file).
    pub fn deinit(self: *Decoder) void {
        switch (self.impl) {
            .wav => |*dec| dec.deinit(),
            .flac => |*dec| dec.deinit(),
        }
        if (self.source) |source| switch (source) {
            .bytes => |reader| self.allocator.destroy(reader),
            .file => |file_source| self.allocator.destroy(file_source),
        };
        self.* = undefined;
    }
};
