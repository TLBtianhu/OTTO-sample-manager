//! Public types shared by the decoder implementations.
//!
//! These live in a separate file so `wav.zig` and the FLAC implementation can
//! use them without importing the public root (which imports them back).

pub const Format = enum { wav, flac, mp3, aiff };

pub const Info = struct {
    format: Format,
    sample_rate: u32,
    channels: u16,
    /// Bit depth of the source container: 8/16/24/32 for PCM, 32 for float.
    /// WAVE_FORMAT_EXTENSIBLE "valid bits" are deliberately not exposed:
    /// `read` always converts to i16, and FLAC has no container/valid split.
    bits_per_sample: u16,
    /// Frames declared by the container header. Null when the stream does not
    /// declare a length (e.g. WAV `data` size 0xFFFFFFFF). A declared count may
    /// still be larger than what the stream actually delivers; `read` reports
    /// `error.Truncated` in that case.
    total_frames: ?u64,
};

/// Every failure the public API can surface. Transport errors are kept
/// separate from malformed bytes on purpose.
pub const Error = error{
    /// Not a recognized audio signature (including an empty stream).
    NotAudio,
    /// Recognized, but not supported. For FLAC: side channels of a 32-bit
    /// stream (they would be 33 bits wide).
    Unsupported,
    /// The stream ended before a complete header or frame.
    Truncated,
    /// Structurally invalid fields: bad block alignment, impossible sizes,
    /// malformed `fmt `, ...
    Corrupt,
    /// Allocation failed inside `open`.
    OutOfMemory,
    /// The underlying `std.Io.Reader` reported `ReadFailed`.
    Io,
    /// The caller-provided output buffer cannot hold one frame.
    ShortBuffer,
};

/// Engineering cap, not a format limit: keeps one frame <= 256 bytes so the
/// no-allocation read path can use a fixed stack scratch buffer.
pub const max_channels: u16 = 64;
