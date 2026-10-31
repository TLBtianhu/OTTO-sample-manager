//! zig-audio: streaming audio decoding in pure Zig.
//!
//! WAV (PCM, IEEE float, G.711 µ-law/A-law, IMA and Microsoft ADPCM), AIFF
//! (big-endian PCM), FLAC (CONSTANT, VERBATIM, FIXED(0..4), LPC(1..32)) and
//! mono/stereo MPEG-1 Layer III decoders, plus a complete Ogg Vorbis decoder.
//! The FLAC side covers Rice partitions, independent channels and the
//! left/side, right/side and mid/side assignments; the MP3 side covers long and
//! window-switched (start/short/stop) granules, mid/side and intensity stereo;
//! the Ogg side covers the container, the three Vorbis headers, floor 1, residue
//! formats 0/1/2, inverse coupling, the IMDCT and the lap, and Ogg Opus up to
//! the CELT layer (configuration 16-31): `open` returns a real decoder and
//! `read` produces PCM, while SILK/Hybrid packets are refused as `Unsupported`
//! rather than approximated (see `opus.zig`). Floor 0 is not supported and is
//! named as such. See README for the support matrix.
//!
//! The API deliberately has one output path: interleaved i16. Source PCM
//! (8/16/24/32) and float32 are converted inside the decoder, so a player
//! never branches on source format.

const std = @import("std");
const types = @import("types.zig");
const wav = @import("wav.zig");
const aiff = @import("aiff.zig");
const flac = @import("flac.zig");
const mp3 = @import("mp3.zig");
const ogg = @import("ogg.zig");
const vorbis = @import("vorbis.zig");
const vorbis_decoder = @import("vorbis_decoder.zig");

pub const Format = types.Format;
pub const Info = types.Info;
pub const Error = types.Error;

/// Ogg Opus: `inspect` reports the head fields, packet framing and length;
/// `Decoder.open` returns a streaming decoder that produces PCM for CELT-only
/// packets (configuration 16-31) and refuses SILK/Hybrid ones with
/// `error.Unsupported`.
pub const opus = @import("opus.zig");

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
/// enough to recognize FLAC's `fLaC` magic, 12 bytes are needed for RIFF/WAVE
/// and `FORM`/`AIFF`. Ogg is a two-level identification: the first page's
/// payload decides between Vorbis and Opus, so `OggS` needs at least 28 bytes
/// and the usual single-segment BOS page needs 36 bytes. With less than that
/// the answer is null rather than a guess, because reporting Opus as
/// `.ogg_vorbis` would be a lie. Anything shorter than a recognizable signature
/// returns null. RF64 and RIFX return null on purpose: they are WAV-like
/// containers this version does not decode. AIFC returns null for the same
/// reason, even though `open` names it `Unsupported`.
///
/// `.ogg_opus` is the one format this function names without being able to
/// decode it: the Opus path reports the container and the codec truthfully
/// (head fields, packet framing, length) and `open` still answers
/// `error.Unsupported`. Naming it here is what lets a caller list an `.opus`
/// file with its duration instead of showing nothing.
pub fn probe(header: []const u8) ?Format {
    if (header.len >= 4 and std.mem.eql(u8, header[0..4], "fLaC")) return .flac;
    if (header.len >= 12 and std.mem.eql(u8, header[0..4], "RIFF") and
        std.mem.eql(u8, header[8..12], "WAVE"))
    {
        return .wav;
    }
    if (header.len >= 12 and std.mem.eql(u8, header[0..4], "FORM") and
        std.mem.eql(u8, header[8..12], "AIFF"))
    {
        return .aiff;
    }
    // Ogg: the container magic alone does not name a codec, so the first
    // packet decides. Both codecs are named; only Vorbis is decodable.
    if (header.len >= 4 and std.mem.eql(u8, header[0..4], "OggS")) {
        return switch (ogg.identify(header)) {
            .vorbis => .ogg_vorbis,
            .opus => .ogg_opus,
            .unknown => null,
        };
    }
    // MP3: an ID3v2 tag or an MPEG audio sync word. Any layer/version is
    // recognized here so `open` can report Unsupported instead of NotAudio.
    if (header.len >= 3 and std.mem.eql(u8, header[0..3], "ID3")) return .mp3;
    if (header.len >= 2 and header[0] == 0xFF and (header[1] & 0xE0) == 0xE0) return .mp3;
    return null;
}

/// Open a decoder at the current position of `reader`.
///
/// Consumes the 12-byte signature and scans RIFF chunks up to the start of the
/// `data` payload. The reader is borrowed: the caller owns it and must keep it
/// alive longer than the returned `Decoder`.
///
/// For Ogg this version parses the container and all three Vorbis headers and
/// returns a streaming decoder; `total_frames` is the stream's last granule, so
/// it stays `null` until `read` reaches the end. Ogg Opus parses its head,
/// comment header and every packet's framing, then returns
/// `error.Unsupported`: there is no Opus decoder, and no silent PCM is invented
/// for one. Unknown Ogg logical streams return `error.Unsupported` too.
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

    if (std.mem.eql(u8, header[0..4], "FORM")) {
        // AIFF and AIFC share the FORM signature; `aiff.open` returns
        // Unsupported for AIFC and NotAudio for other FORM types (AVI, ...).
        const dec = try aiff.open(allocator, reader, &header);
        return .{
            .info = dec.info,
            .allocator = allocator,
            .impl = .{ .aiff = dec },
        };
    }

    if (std.mem.eql(u8, header[0..3], "ID3") or
        (header[0] == 0xFF and (header[1] & 0xE0) == 0xE0))
    {
        const dec = try mp3.open(allocator, reader, &header);
        return .{
            .info = dec.info,
            .allocator = allocator,
            .impl = .{ .mp3 = dec },
        };
    }

    if (std.mem.eql(u8, header[0..4], "OggS")) {
        // Ogg names its codec in the first packet, and the demultiplexer has to
        // read that page to see it, so it is created here and handed to the
        // codec decoder that matches. Reading it twice is not an option: a
        // caller's reader may be a socket.
        const demux = try ogg.Demuxer.init(allocator, reader, &header);
        switch (demux.streamCodec()) {
            .vorbis => {
                const dec = try vorbis_decoder.Decoder.openFromDemux(allocator, demux);
                return .{
                    .info = dec.info,
                    .allocator = allocator,
                    .impl = .{ .ogg_vorbis = dec },
                };
            },
            .opus => {
                const dec = try opus.Decoder.openFromDemux(allocator, demux);
                return .{
                    .info = dec.info,
                    .allocator = allocator,
                    .impl = .{ .ogg_opus = dec },
                };
            },
            .unknown => {
                var discarded = demux;
                discarded.deinit();
                return error.Unsupported;
            },
        }
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
        aiff: aiff.Decoder,
        flac: flac.Decoder,
        mp3: mp3.Decoder,
        ogg_vorbis: vorbis_decoder.Decoder,
        ogg_opus: opus.Decoder,
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
    /// `(byte - 128) << 8`, FLAC and AIFF 8-bit are signed (`sample << 8`),
    /// 16-bit is copied, and wider sources shift right so the top 16 bits
    /// survive (WAV/AIFF 24-bit by 8, 32-bit by 16; FLAC by `bits - 16`).
    /// Float32 is clamped to [-1, 1] and rounded to i16. G.711 µ-law/A-law and
    /// both ADPCM block codecs expand to 16-bit linear. Integer conversions
    /// match ffmpeg `-f s16le` sample for sample.
    ///
    /// Returns 0 at end of stream. An empty `out` is a no-op that also returns
    /// 0, so callers must not use a zero-length read as an EOF probe. The tail
    /// of `out` is untouched when `out.len` is not a multiple of `channels`.
    /// A non-empty `out` smaller than one frame returns `error.ShortBuffer`.
    pub fn read(self: *Decoder, out: []i16) Error!usize {
        switch (self.impl) {
            .wav => |*dec| return dec.read(out),
            .aiff => |*dec| return dec.read(out),
            .flac => |*dec| return dec.read(out),
            .mp3 => |*dec| return dec.read(out),
            .ogg_vorbis => |*dec| {
                const written = try dec.read(out);
                // Vorbis length lives in the stream's last granule position, so
                // it becomes known only when the last page has been read.
                self.info.total_frames = dec.info.total_frames;
                return written;
            },
            .ogg_opus => |*dec| {
                const written = try dec.read(out);
                // Same for Opus: `granule - pre_skip` is only known once the
                // last page has been read, which is where reading ends.
                self.info.total_frames = dec.info.total_frames;
                return written;
            },
        }
    }

    /// Release decoder-owned memory. Does not close the caller's reader or
    /// file; for `openBytes` / `openFile*` it also releases the wrapper state
    /// (but never the bytes or the file).
    pub fn deinit(self: *Decoder) void {
        switch (self.impl) {
            .wav => |*dec| dec.deinit(),
            .aiff => |*dec| dec.deinit(),
            .flac => |*dec| dec.deinit(),
            .mp3 => |*dec| dec.deinit(),
            .ogg_vorbis => |*dec| dec.deinit(),
            .ogg_opus => |*dec| dec.deinit(),
        }
        if (self.source) |source| switch (source) {
            .bytes => |reader| self.allocator.destroy(reader),
            .file => |file_source| self.allocator.destroy(file_source),
        };
        self.* = undefined;
    }
};
