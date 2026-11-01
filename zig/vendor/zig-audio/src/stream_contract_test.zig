//! Cross-format error-mapping and truncated-prefix contracts.
//!
//! Two tables, both asserted here and documented in README under
//! "跨格式契约：短缓冲、前缀与错误映射".
//!
//! ## Truncated audio (header intact, payload cut)
//!
//! | family | call that cannot be satisfied | prefix | following reads |
//! | --- | --- | --- | --- |
//! | WAV PCM / G.711 | `error.Truncated`, no samples from that call | earlier calls only | same error |
//! | WAV ADPCM | `error.Truncated`, partial block discarded | earlier blocks | same error |
//! | AIFF | `error.Truncated`, no samples from that call | earlier calls only | same error |
//! | FLAC | samples decoded so far, then the error | yes | same error |
//! | MP3 | samples decoded so far, then the error | yes | same error |
//! | Ogg Vorbis | samples decoded so far, then the error | yes | same error |
//! | Ogg Opus | samples decoded so far, then the error | yes | same error |
//!
//! No row pads with silence: whatever is returned before the error is an exact
//! prefix of the untruncated decode, and it is shorter than that decode.
//!
//! ## Open-time error mapping
//!
//! | input | WAV | AIFF | FLAC | MP3 | Vorbis | Opus |
//! | --- | --- | --- | --- | --- | --- | --- |
//! | empty stream | NotAudio | NotAudio | NotAudio | NotAudio | NotAudio | NotAudio |
//! | random bytes | NotAudio | NotAudio | NotAudio | NotAudio | NotAudio | NotAudio |
//! | real header, cut to 12 bytes | Truncated | ... | ... | ... | ... | ... |
//! | corrupted magic | NotAudio | ... | ... | ... | ... | ... |
//! | transport failure | Io | ... | ... | ... | ... | ... |
//! | recognized but refused | Unsupported (RF64) | Unsupported (AIFC) | n/a at open | Unsupported (MPEG-2) | Unsupported (unknown Ogg codec) | Unsupported (mapping family 2) |
//! | structurally corrupt | Corrupt (bad fmt) | Corrupt (short COMM) | Corrupt (STREAMINFO) | Corrupt (bitrate index 15) | Corrupt (page CRC) | Corrupt (OpusHead version 0) |
//!
//! `open` never succeeds on any of these inputs; the assertion is on the error
//! class, not just on "some error". FLAC's only `Unsupported` verdict is a
//! per-frame one (a 32-bit decorrelated stream), covered at the bottom.

const std = @import("std");
const root = @import("root.zig");
const testutil = @import("testutil.zig");
const builders = @import("stream_builders.zig");
const flac_build = @import("flac_build.zig");
const opus_build = @import("opus_build.zig");
const ogg = @import("ogg.zig");
const ogg_build = @import("ogg_build.zig");
const testing = std.testing;

const Outcome = struct {
    err: ?root.Error,
    /// True when `open` succeeded and the first `read` returned 0 without an
    /// error: the "silently decodes to nothing" outcome the contract forbids.
    silent_zero: bool,
};

fn openOutcome(bytes: []const u8) Outcome {
    var reader = std.Io.Reader.fixed(bytes);
    var dec = root.open(testing.allocator, &reader) catch |err| {
        return .{ .err = err, .silent_zero = false };
    };
    defer dec.deinit();
    var buffer: [64]i16 = undefined;
    const written = dec.read(&buffer) catch |err| {
        return .{ .err = err, .silent_zero = false };
    };
    return .{ .err = null, .silent_zero = written == 0 };
}

fn openOutcomeReader(reader: *std.Io.Reader) Outcome {
    var dec = root.open(testing.allocator, reader) catch |err| {
        return .{ .err = err, .silent_zero = false };
    };
    defer dec.deinit();
    var buffer: [64]i16 = undefined;
    const written = dec.read(&buffer) catch |err| {
        return .{ .err = err, .silent_zero = false };
    };
    return .{ .err = null, .silent_zero = written == 0 };
}

fn errName(err: ?root.Error) []const u8 {
    return if (err) |value| @errorName(value) else "none";
}

fn check(
    failures: *usize,
    label: []const u8,
    expected: root.Error,
    outcome: Outcome,
) void {
    if (outcome.err != null and outcome.err.? == expected) {
        std.debug.print(" {s}={s}", .{ label, @errorName(expected) });
        return;
    }
    failures.* += 1;
    std.debug.print(" {s}=FAIL(want {s} got {s} silent_zero={})", .{
        label,
        @errorName(expected),
        errName(outcome.err),
        outcome.silent_zero,
    });
}

fn find(variants: *builders.Variants, name: []const u8) *const builders.Variant {
    for (variants.items) |*variant| {
        if (std.mem.eql(u8, variant.name, name)) return variant;
    }
    @panic("stream_builders: variant name not found");
}

/// Copy `source` into `buffer` and set one byte, for corrupt-header cases.
fn patched(buffer: []u8, source: []const u8, offset: usize, value: u8) []const u8 {
    std.debug.assert(source.len <= buffer.len);
    std.debug.assert(offset < source.len);
    @memcpy(buffer[0..source.len], source);
    buffer[offset] = value;
    return buffer[0..source.len];
}

fn opusHeaders(allocator: std.mem.Allocator, spec: opus_build.HeadSpec) ![]u8 {
    var writer = ogg_build.Writer.init(allocator, 0x0F00D);
    defer writer.deinit();
    const head = try opus_build.head(allocator, spec);
    defer allocator.free(head);
    const tags = try opus_build.tags(allocator, "zig-audio-test", &.{});
    defer allocator.free(tags);
    try writer.addPage(ogg.Flag.bos, 0, &.{head});
    try writer.addPage(ogg.Flag.eos, 0, &.{tags});
    return writer.finish();
}

fn unknownOggCodec(allocator: std.mem.Allocator) ![]u8 {
    var writer = ogg_build.Writer.init(allocator, 0x0A0B_0C0D);
    defer writer.deinit();
    try writer.addPage(ogg.Flag.bos | ogg.Flag.eos, 0, &.{"mystery"});
    return writer.finish();
}

const Family = struct {
    name: []const u8,
    stream: []const u8,
};

test "error mapping: six formats x empty/random/truncated/corrupt/transport/refused" {
    var variants = try builders.buildAll(testing.allocator);
    defer variants.deinit();

    // Inputs shared by every family.
    var random: [64]u8 = undefined;
    for (&random, 0..) |*byte, i| byte.* = @truncate(i * 97 + 13);
    try testing.expectEqual(@as(?root.Format, null), root.probe(&random));
    try testing.expectEqual(@as(?root.Format, null), root.probe(&.{}));

    const rf64 = "RF64" ++ [_]u8{ 0, 0, 0, 0 } ++ "WAVE";
    const aifc = "FORM" ++ [_]u8{ 0, 0, 0, 0 } ++ "AIFC";
    const opus_unsupported = try opusHeaders(testing.allocator, .{ .mapping_family = 2 });
    defer testing.allocator.free(opus_unsupported);
    const opus_bad_version = try opusHeaders(testing.allocator, .{ .version = 0 });
    defer testing.allocator.free(opus_bad_version);
    const unknown_codec = try unknownOggCodec(testing.allocator);
    defer testing.allocator.free(unknown_codec);

    const families = [_]Family{
        .{ .name = "wav", .stream = find(&variants, "wav/pcm16/stereo").bytes },
        .{ .name = "aiff", .stream = find(&variants, "aiff/16/stereo").bytes },
        .{ .name = "flac", .stream = find(&variants, "flac/16/stereo").bytes },
        .{ .name = "mp3", .stream = find(&variants, "mp3/mono").bytes },
        .{ .name = "vorbis", .stream = find(&variants, "vorbis/stereo").bytes },
        .{ .name = "opus", .stream = find(&variants, "opus/mono").bytes },
    };

    var failures: usize = 0;
    for (families) |family| {
        var scratch: [4096]u8 = undefined;
        var magic: [12]u8 = undefined;
        @memcpy(&magic, family.stream[0..12]);
        magic[0] ^= 0xFF;

        std.debug.print("errors {s:<6}", .{family.name});
        check(&failures, "empty", error.NotAudio, openOutcome(&.{}));
        check(&failures, "random", error.NotAudio, openOutcome(&random));
        check(
            &failures,
            "truncated",
            error.Truncated,
            openOutcome(family.stream[0..12]),
        );
        check(&failures, "magic", error.NotAudio, openOutcome(&magic));

        var transport_buffer: [64]u8 = undefined;
        var failing = testutil.failingReader(&transport_buffer);
        check(&failures, "io", error.Io, openOutcomeReader(&failing));

        // One recognized-but-refused input per family; FLAC has none at open.
        const unsupported: ?[]const u8 = if (std.mem.eql(u8, family.name, "wav"))
            rf64
        else if (std.mem.eql(u8, family.name, "aiff"))
            aifc
        else if (std.mem.eql(u8, family.name, "mp3"))
            patched(&scratch, family.stream, 1, 0xF3) // MPEG-2 version
        else if (std.mem.eql(u8, family.name, "vorbis"))
            unknown_codec
        else if (std.mem.eql(u8, family.name, "opus"))
            opus_unsupported
        else
            null;
        if (unsupported) |bytes| {
            check(&failures, "refused", error.Unsupported, openOutcome(bytes));
        } else {
            std.debug.print(" refused=n/a-at-open", .{});
        }

        // One structurally corrupt input per family.
        var corrupt_scratch: [4096]u8 = undefined;
        const corrupt: []const u8 = if (std.mem.eql(u8, family.name, "wav"))
            patched(&corrupt_scratch, family.stream, 32, 2) // block_align != 2*channels
        else if (std.mem.eql(u8, family.name, "aiff"))
            patched(&corrupt_scratch, family.stream, 19, 8) // COMM size 8 < 18
        else if (std.mem.eql(u8, family.name, "flac"))
            patched(&corrupt_scratch, family.stream, 9, 0) // min block size 0
        else if (std.mem.eql(u8, family.name, "mp3"))
            patched(&corrupt_scratch, family.stream, 2, 0xF0) // bitrate index 15
        else if (std.mem.eql(u8, family.name, "vorbis"))
            // Flip the first byte of the first page body: the CRC no longer
            // matches, and the demuxer verifies it on every page.
            patched(&corrupt_scratch, family.stream, 27 + family.stream[26], 0xFF)
        else
            opus_bad_version;
        check(&failures, "corrupt", error.Corrupt, openOutcome(corrupt));
        std.debug.print("\n", .{});
    }

    std.debug.print("error mapping failures={d}\n", .{failures});
    try testing.expectEqual(@as(usize, 0), failures);
}

fn decodeFully(allocator: std.mem.Allocator, bytes: []const u8) ![]i16 {
    var reader = std.Io.Reader.fixed(bytes);
    var dec = try root.open(allocator, &reader);
    defer dec.deinit();
    var list: std.ArrayList(i16) = .empty;
    errdefer list.deinit(allocator);
    var buffer: [full_buffer]i16 = undefined;
    while (true) {
        const written = try dec.read(&buffer);
        if (written == 0) break;
        try list.appendSlice(allocator, buffer[0..written]);
    }
    return list.toOwnedSlice(allocator);
}

const full_buffer = 4096;

const Truncation = struct {
    samples: []i16,
    err: ?root.Error,
    repeated: ?root.Error,
};

/// Read until the first error, then read again to see whether the error is
/// sticky. `chunk` is in i16 samples, deliberately tiny.
fn decodeUntilError(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    chunk: usize,
) !Truncation {
    var reader = std.Io.Reader.fixed(bytes);
    var dec = try root.open(allocator, &reader);
    defer dec.deinit();

    var list: std.ArrayList(i16) = .empty;
    errdefer list.deinit(allocator);
    var buffer: [64]i16 = undefined;
    var first: ?root.Error = null;
    while (true) {
        const written = dec.read(buffer[0..chunk]) catch |err| {
            first = err;
            break;
        };
        if (written == 0) break;
        try list.appendSlice(allocator, buffer[0..written]);
    }

    var repeated: ?root.Error = null;
    if (first != null) {
        if (dec.read(buffer[0..chunk])) |_| {} else |err| repeated = err;
    }
    return .{
        .samples = try list.toOwnedSlice(allocator),
        .err = first,
        .repeated = repeated,
    };
}

test "truncated audio: exact prefix, then the same error, never zero fill" {
    var variants = try builders.buildAll(testing.allocator);
    defer variants.deinit();

    const names = [_][]const u8{
        "wav/pcm16/stereo",
        "wav/ima-adpcm/mono",
        "aiff/16/stereo",
        "flac/16/stereo",
        "mp3/mono",
        "vorbis/stereo",
        "opus/mono",
    };

    var failures: usize = 0;
    for (names) |name| {
        const variant = find(&variants, name);
        const full = try decodeFully(testing.allocator, variant.bytes);
        defer testing.allocator.free(full);

        // Header intact, 20 bytes of the payload gone: the cut lands inside the
        // last frame/page of every stream, so a decodable prefix must exist.
        const cut = variant.bytes[0 .. variant.bytes.len - 20];
        const result = try decodeUntilError(testing.allocator, cut, 8);
        defer testing.allocator.free(result.samples);

        const prefix_ok = result.samples.len > 0 and
            result.samples.len < full.len and
            std.mem.eql(i16, result.samples, full[0..result.samples.len]);
        const error_ok = result.err != null and result.err.? == error.Truncated;
        const repeat_ok = result.repeated != null and result.repeated.? == result.err.?;

        std.debug.print(
            "prefix {s:<18} samples={d}/{d} err={s} repeat={s} {s}\n",
            .{
                name,
                result.samples.len,
                full.len,
                errName(result.err),
                errName(result.repeated),
                if (prefix_ok and error_ok and repeat_ok) "PASS" else "FAIL",
            },
        );
        if (!prefix_ok or !error_ok or !repeat_ok) failures += 1;
        if (!prefix_ok) {
            std.debug.print(
                "  prefix mismatch: first difference at {d}\n",
                .{firstDiff(result.samples, full)},
            );
        }
    }

    std.debug.print("truncation failures={d}\n", .{failures});
    try testing.expectEqual(@as(usize, 0), failures);
}

fn firstDiff(a: []const i16, b: []const i16) usize {
    const common = @min(a.len, b.len);
    for (0..common) |i| {
        if (a[i] != b[i]) return i;
    }
    return common;
}

test "FLAC: 32-bit decorrelated is Unsupported at read, not at open" {
    // The side subframe would be 33 bits wide. `open` cannot know without
    // decoding a frame, so the verdict is a read-time one and must be named.
    var storage: [2][64]i32 = undefined;
    for (&storage) |*plane| {
        for (plane, 0..) |*value, i| value.* = @intCast(@as(i32, @intCast(i)) - 32);
    }
    var planes: [2][]const i32 = undefined;
    for (0..2) |channel| planes[channel] = &storage[channel];
    const modes = [_]flac_build.Mode{ .verbatim, .verbatim };
    const frames = [_]flac_build.Frame{.{
        .block_size = 64,
        .modes = &modes,
        .samples = &planes,
        .channel_assignment = 8, // left/side
    }};
    const bytes = try flac_build.build(testing.allocator, .{
        .sample_rate = 44_100,
        .channels = 2,
        .bits_per_sample = 32,
        .total_samples = 64,
        .frames = &frames,
    });
    defer testing.allocator.free(bytes);

    var reader = std.Io.Reader.fixed(bytes);
    var dec = try root.open(testing.allocator, &reader);
    defer dec.deinit();
    var buffer: [64]i16 = undefined;
    try testing.expectError(error.Unsupported, dec.read(&buffer));
    std.debug.print("flac 32-bit side channel: open=ok read=Unsupported\n", .{});
}
