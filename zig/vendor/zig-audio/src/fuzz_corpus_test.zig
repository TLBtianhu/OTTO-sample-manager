//! Permanent regression corpus replay (L1).
//!
//! The bytes are committed under `src/fuzz_corpus/` and embedded here, so the
//! test needs no filesystem and cannot silently skip. `corpus.json` is the
//! single description of each sample: family, construction, expected error and
//! the stage that must produce it.
//!
//! For every sample this file asserts more than "no panic":
//!
//!   * the error *name* and the *stage* (open vs read) match the manifest;
//!   * the reader is never asked for more bytes than the sample contains, and
//!     the number of reader calls is bounded;
//!   * peak allocation stays at or below the peak of a valid file of the same
//!     family, and `read` does not allocate more than that baseline;
//!   * `deinit` leaves zero live bytes and zero live blocks.
//!
//! A deliberate one-character edit to an `expected_error` in `corpus.json` must
//! turn this test red; that is the reverse proof that the assertion is real.

const std = @import("std");
const root = @import("root.zig");
const testutil = @import("testutil.zig");
const flac_build = @import("flac_build.zig");
const Counter = @import("alloc_stats.zig").Counter;

const manifest_bytes = @embedFile("fuzz_corpus/corpus.json");

const Embedded = struct {
    name: []const u8,
    bytes: []const u8,
};

const embedded = [_]Embedded{
    .{ .name = "ogg_bos_continued", .bytes = @embedFile("fuzz_corpus/ogg_bos_continued.bin") },
    .{ .name = "ogg_page_body_short", .bytes = @embedFile("fuzz_corpus/ogg_page_body_short.bin") },
    .{ .name = "ogg_page_crc", .bytes = @embedFile("fuzz_corpus/ogg_page_crc.bin") },
    .{ .name = "ogg_eof_mid_packet", .bytes = @embedFile("fuzz_corpus/ogg_eof_mid_packet.bin") },
    .{ .name = "ogg_sequence_gap", .bytes = @embedFile("fuzz_corpus/ogg_sequence_gap.bin") },
    .{ .name = "opus_toc_one_byte", .bytes = @embedFile("fuzz_corpus/opus_toc_one_byte.bin") },
    .{ .name = "opus_toc_code1_odd", .bytes = @embedFile("fuzz_corpus/opus_toc_code1_odd.bin") },
    .{ .name = "opus_toc_count_zero", .bytes = @embedFile("fuzz_corpus/opus_toc_count_zero.bin") },
    .{ .name = "opus_toc_too_long", .bytes = @embedFile("fuzz_corpus/opus_toc_too_long.bin") },
    .{ .name = "flac_frame_truncated", .bytes = @embedFile("fuzz_corpus/flac_frame_truncated.bin") },
    .{ .name = "flac_header_truncated", .bytes = @embedFile("fuzz_corpus/flac_header_truncated.bin") },
    .{ .name = "flac_wasted_overrun", .bytes = @embedFile("fuzz_corpus/flac_wasted_overrun.bin") },
    .{ .name = "aiff_comm_short", .bytes = @embedFile("fuzz_corpus/aiff_comm_short.bin") },
    .{ .name = "aiff_negative_rate", .bytes = @embedFile("fuzz_corpus/aiff_negative_rate.bin") },
    .{ .name = "aiff_frames_exceed_ssnd", .bytes = @embedFile("fuzz_corpus/aiff_frames_exceed_ssnd.bin") },
    .{ .name = "aiff_ssnd_before_comm", .bytes = @embedFile("fuzz_corpus/aiff_ssnd_before_comm.bin") },
    .{ .name = "adpcm_ima_step89", .bytes = @embedFile("fuzz_corpus/adpcm_ima_step89.bin") },
    .{ .name = "adpcm_ima_short_tail", .bytes = @embedFile("fuzz_corpus/adpcm_ima_short_tail.bin") },
    .{ .name = "adpcm_ms_bad_predictor", .bytes = @embedFile("fuzz_corpus/adpcm_ms_bad_predictor.bin") },
    .{ .name = "adpcm_ms_block_align_short", .bytes = @embedFile("fuzz_corpus/adpcm_ms_block_align_short.bin") },
};

const Entry = struct {
    name: []const u8,
    family: []const u8,
    file: []const u8,
    stage: []const u8,
    expected_error: []const u8,
    input_bytes: usize,
    source: []const u8 = "",
    construction: []const u8 = "",
    symptom: []const u8 = "",
};

const Manifest = struct {
    version: u32,
    note: []const u8 = "",
    samples: []const Entry,
};

const families = [_][]const u8{ "ogg", "opus_toc", "flac_bits", "aiff", "adpcm" };
const error_names = [_][]const u8{ "Corrupt", "Truncated", "Unsupported", "NotAudio", "OutOfMemory", "Io", "ShortBuffer" };

fn findEmbedded(name: []const u8) ?Embedded {
    for (embedded) |item| {
        if (std.mem.eql(u8, item.name, name)) return item;
    }
    return null;
}

fn validFamily(family: []const u8) bool {
    for (families) |known| if (std.mem.eql(u8, known, family)) return true;
    return false;
}

fn validError(name: []const u8) bool {
    for (error_names) |known| if (std.mem.eql(u8, known, name)) return true;
    return false;
}

fn parseManifest(allocator: std.mem.Allocator) !std.json.Parsed(Manifest) {
    return std.json.parseFromSlice(Manifest, allocator, manifest_bytes, .{
        .ignore_unknown_fields = true,
    });
}

// ---------------------------------------------------------------------------
// Valid baselines: peak allocation of a normal file of each family.
// ---------------------------------------------------------------------------

const Baseline = struct {
    peak: usize,
    open_allocs: usize,
    read_allocs: usize,
};

fn measure(allocator: std.mem.Allocator, bytes: []const u8) !Baseline {
    var counter = Counter.init(allocator);
    var reader = std.Io.Reader.fixed(bytes);
    var opened: Counter.Snapshot = undefined;
    var read_allocs: usize = 0;

    {
        var dec = try root.open(counter.allocator(), &reader);
        defer dec.deinit();
        opened = counter.snapshot();

        var out: [4096]i16 = undefined;
        var iterations: usize = 0;
        while (iterations < 1_000_000) : (iterations += 1) {
            const n = try dec.read(&out);
            if (n == 0) break;
        }
        read_allocs = counter.allocs - opened.allocs;
    }

    try std.testing.expectEqual(@as(usize, 0), counter.current);
    try std.testing.expectEqual(@as(usize, 0), counter.live);
    return .{
        .peak = counter.peak,
        .open_allocs = opened.allocs,
        .read_allocs = read_allocs,
    };
}

fn buildFlacBaseline(allocator: std.mem.Allocator) ![]u8 {
    const plane: [32]i32 = @splat(1234);
    const planes = [_][]const i32{&plane};
    const frames = [_]flac_build.Frame{
        .{ .block_size = 32, .modes = &.{.constant}, .samples = &planes },
    };
    return flac_build.build(allocator, .{
        .sample_rate = 44_100,
        .channels = 1,
        .bits_per_sample = 16,
        .total_samples = 32,
        .frames = &frames,
    });
}

fn buildAiffBaseline(allocator: std.mem.Allocator) ![]u8 {
    var builder = try testutil.AiffBuilder.init(allocator);
    defer builder.deinit();
    var comm: [18]u8 = undefined;
    _ = testutil.aiffCommPayload(&comm, 1, 2, 16, 44_100);
    try builder.addChunk("COMM", &comm);
    try testutil.addSsnd(&builder, &[_]u8{ 0, 1, 0, 2 }, 0);
    return builder.finish();
}

fn buildAdpcmBaseline(allocator: std.mem.Allocator) ![]u8 {
    const block_align: u16 = 32;
    const payload = try allocator.alloc(u8, block_align * 2);
    defer allocator.free(payload);
    @memset(payload, 0);
    for (0..2) |b| {
        const at = b * block_align;
        std.mem.writeInt(i16, payload[at..][0..2], 1000, .little);
        payload[at + 2] = 5;
        for (payload[at + 4 ..][0 .. block_align - 4]) |*byte| byte.* = 0x5A;
    }
    return testutil.buildAdpcm(allocator, .{
        .tag = testutil.format_ima_adpcm,
        .channels = 1,
        .sample_rate = 8000,
        .block_align = block_align,
        .bits = 4,
        .samples_per_block = 57,
    }, payload);
}

fn baselineFor(allocator: std.mem.Allocator, family: []const u8) !Baseline {
    if (std.mem.eql(u8, family, "ogg") or std.mem.eql(u8, family, "opus_toc")) {
        return measure(allocator, @embedFile("fixtures/opus-stereo-48k-128.opus"));
    }
    const bytes = if (std.mem.eql(u8, family, "flac_bits"))
        try buildFlacBaseline(allocator)
    else if (std.mem.eql(u8, family, "aiff"))
        try buildAiffBaseline(allocator)
    else
        try buildAdpcmBaseline(allocator);
    defer allocator.free(bytes);
    return measure(allocator, bytes);
}

// ---------------------------------------------------------------------------
// Replay
// ---------------------------------------------------------------------------

fn expectNamed(entry: Entry, err: root.Error) !void {
    const actual = @errorName(err);
    if (!std.mem.eql(u8, actual, entry.expected_error)) {
        std.debug.print(
            "corpus {s}: expected {s} at {s}, got {s}\n",
            .{ entry.name, entry.expected_error, entry.stage, actual },
        );
        return error.CorpusWrongError;
    }
}

fn expectCaps(counter: *const Counter, chunked: *const testutil.ChunkedReader, entry: Entry, baseline: Baseline) !void {
    try std.testing.expectEqual(@as(usize, 0), counter.current);
    try std.testing.expectEqual(@as(usize, 0), counter.live);
    // Never read past the sample, and never spin on a reader that keeps
    // returning EOF: both are failures of the input-length contract.
    try std.testing.expect(chunked.pos <= entry.input_bytes);
    try std.testing.expect(chunked.calls <= 4096);
    try std.testing.expect(counter.peak <= baseline.peak);
}

fn replay(entry: Entry, bytes: []const u8, baseline: Baseline) !void {
    try std.testing.expectEqual(entry.input_bytes, bytes.len);
    var counter = Counter.init(std.testing.allocator);
    var scratch: [61]u8 = undefined;
    var chunked = testutil.ChunkedReader.init(bytes, 7, &scratch);
    const reader = chunked.reader();
    var out: [4096]i16 = undefined;

    if (std.mem.eql(u8, entry.stage, "open")) {
        if (root.open(counter.allocator(), reader)) |value| {
            var dec = value;
            dec.deinit();
            std.debug.print("corpus {s}: open unexpectedly succeeded\n", .{entry.name});
            return error.CorpusExpectedOpenError;
        } else |err| {
            try expectNamed(entry, err);
        }
        try expectCaps(&counter, &chunked, entry, baseline);
        return;
    }

    if (!std.mem.eql(u8, entry.stage, "read")) {
        std.debug.print("corpus {s}: unknown stage {s}\n", .{ entry.name, entry.stage });
        return error.CorpusBadManifest;
    }

    var read_allocs: usize = 0;
    {
        var dec = root.open(counter.allocator(), reader) catch |err| {
            std.debug.print("corpus {s}: open failed early with {s}\n", .{ entry.name, @errorName(err) });
            return error.CorpusUnexpectedOpen;
        };
        defer dec.deinit();
        const opened = counter.snapshot();

        var found: ?root.Error = null;
        var iterations: usize = 0;
        while (iterations < 100_000) : (iterations += 1) {
            const n = dec.read(&out) catch |err| {
                found = err;
                break;
            };
            if (n == 0) break;
        }
        if (found == null) {
            std.debug.print("corpus {s}: read reached EOF without the expected error\n", .{entry.name});
            return error.CorpusExpectedReadError;
        }
        try expectNamed(entry, found.?);
        read_allocs = counter.allocs - opened.allocs;
    }
    try expectCaps(&counter, &chunked, entry, baseline);
    try std.testing.expect(read_allocs <= baseline.read_allocs);
}

fn runFamily(family: []const u8) !void {
    const allocator = std.testing.allocator;
    const parsed = try parseManifest(allocator);
    defer parsed.deinit();

    const baseline = try baselineFor(allocator, family);
    var count: usize = 0;
    for (parsed.value.samples) |entry| {
        if (!std.mem.eql(u8, entry.family, family)) continue;
        const item = findEmbedded(entry.name) orelse {
            std.debug.print("corpus {s}: no embedded bytes\n", .{entry.name});
            return error.CorpusMissingSample;
        };
        try replay(entry, item.bytes, baseline);
        count += 1;
    }
    // A family that is silently empty must not become a green test.
    try std.testing.expect(count >= 3);
}

test "corpus manifest matches the embedded samples and stays non-empty" {
    const allocator = std.testing.allocator;
    const parsed = try parseManifest(allocator);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u32, 1), parsed.value.version);
    try std.testing.expect(parsed.value.samples.len >= 15);

    var seen: [embedded.len]bool = @splat(false);
    for (parsed.value.samples) |entry| {
        try std.testing.expect(validFamily(entry.family));
        try std.testing.expect(validError(entry.expected_error));
        try std.testing.expect(
            std.mem.eql(u8, entry.stage, "open") or std.mem.eql(u8, entry.stage, "read"),
        );
        try std.testing.expect(entry.input_bytes > 0);
        const expected_file = try std.fmt.allocPrint(allocator, "{s}.bin", .{entry.name});
        defer allocator.free(expected_file);
        try std.testing.expectEqualStrings(expected_file, entry.file);

        const item = findEmbedded(entry.name) orelse {
            std.debug.print("corpus {s}: listed but not embedded\n", .{entry.name});
            return error.CorpusMissingSample;
        };
        try std.testing.expectEqual(entry.input_bytes, item.bytes.len);
        for (embedded, 0..) |candidate, index| {
            if (std.mem.eql(u8, candidate.name, entry.name)) seen[index] = true;
        }
    }
    for (seen, 0..) |was_seen, index| {
        if (!was_seen) {
            std.debug.print("corpus {s}: embedded but not listed\n", .{embedded[index].name});
            return error.CorpusUnlistedSample;
        }
    }
    for (families) |family| {
        var count: usize = 0;
        for (parsed.value.samples) |entry| {
            if (std.mem.eql(u8, entry.family, family)) count += 1;
        }
        try std.testing.expect(count >= 3);
    }
}

test "corpus: Ogg lace and packet boundaries" {
    try runFamily("ogg");
}

test "corpus: Opus TOC framing" {
    try runFamily("opus_toc");
}

test "corpus: FLAC bit reader" {
    try runFamily("flac_bits");
}

test "corpus: AIFF big-endian lengths" {
    try runFamily("aiff");
}

test "corpus: ADPCM block boundaries" {
    try runFamily("adpcm");
}
