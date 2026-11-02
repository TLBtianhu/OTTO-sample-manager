//! Per-format allocation, peak-memory and concurrency report.
//!
//! `zig build bench` runs this after the throughput rows. Every row is one
//! format, measured on one complete decode:
//!
//!   open_allocs / open_bytes    allocations while `open` runs
//!   read_allocs / read_bytes    allocations while `read` runs
//!   steady_allocs               allocations after the first non-empty read
//!   peak_bytes                  maximum live bytes during open + read
//!   samples_per_sec             interleaved i16 samples per second
//!
//! `read` is expected to be allocation-free once a frame has been produced;
//! Vorbis and Opus may allocate their packet look-ahead on the first read, so
//! the measured `steady_allocs` is printed instead of assumed to be zero.
//!
//! The concurrency section opens eight different decoders at the same time,
//! reads them interleaved, and compares every returned sample with the same
//! decoder read alone. That is the global-state crosstalk check: a shared
//! table or cache would change the bytes, not just the timing.

const std = @import("std");
const builtin = @import("builtin");
const root = @import("root.zig");
const testutil = @import("testutil.zig");
const Counter = @import("alloc_stats.zig").Counter;

const flac_fixture = @embedFile("fixtures/flac-s16-stereo-44100.flac");
const flac_lpc_fixture = @embedFile("fixtures/flac-s16-stereo-44100-lpc.flac");
const mp3_fixture = @embedFile("fixtures/mp3-mono-44k-128.mp3");
const mp3_stereo_fixture = @embedFile("fixtures/mp3-stereo-44k-128.mp3");
const vorbis_fixture = @embedFile("fixtures/vorbis-stereo-44k-q4.ogg");
const opus_fixture = @embedFile("fixtures/opus-stereo-48k-128.opus");
const opus_silk_fixture = @embedFile("fixtures/opus-silk-wb-12k.opus");
const opus_hybrid_fixture = @embedFile("fixtures/opus-hybrid-mono-48k.opus");
const opus_silk_stereo_fixture = @embedFile("fixtures/opus-stereo-silk-24k.opus");

const read_buffer_samples: usize = 8192;
const read_buffer_bytes: usize = read_buffer_samples * @sizeOf(i16);

const RowStats = struct {
    open_allocs: usize = 0,
    open_bytes: usize = 0,
    read_allocs: usize = 0,
    read_bytes: usize = 0,
    steady_allocs: usize = 0,
    peak_bytes: usize = 0,
    frames: u64 = 0,
    samples_per_sec: f64 = 0,
};

pub fn reportAll(allocator: std.mem.Allocator, io: std.Io) !void {
    std.debug.print(
        "\nzig-audio alloc bench: build=ReleaseFast (bench step always builds ReleaseFast, " ++
            "builtin.mode={s}) cpu={s} os={s}\n",
        .{
            @tagName(builtin.mode),
            builtin.cpu.model.name,
            @tagName(builtin.os.tag),
        },
    );
    std.debug.print(
        "input: embedded fixtures + in-memory templates; output=s16le interleaved; " ++
            "read buffer={d} i16 ({d} B)\n",
        .{ read_buffer_samples, read_buffer_bytes },
    );
    std.debug.print(
        "format                           open_allocs open_bytes read_allocs read_bytes steady_allocs peak_bytes samples_per_sec\n",
        .{},
    );

    // WAV: the same 10 s in-memory shape as the throughput row, so the two
    // tables describe the same input rather than a cache-resident toy.
    {
        const wav = try testutil.buildDemoPcm16(allocator, 44_100 * 10);
        defer allocator.free(wav);
        try row(allocator, io, "WAV PCM16 44.1k stereo", wav, 2);
    }

    try row(allocator, io, "FLAC fixed 44.1k stereo", flac_fixture, 2);
    try row(allocator, io, "FLAC LPC 44.1k stereo", flac_lpc_fixture, 2);
    try row(allocator, io, "MP3 128k mono", mp3_fixture, 1);
    try row(allocator, io, "MP3 128k stereo", mp3_stereo_fixture, 2);
    try row(allocator, io, "Ogg Vorbis q4 stereo", vorbis_fixture, 2);
    try row(allocator, io, "Opus 128k stereo (CELT)", opus_fixture, 2);
    try row(allocator, io, "Opus 12k mono (SILK)", opus_silk_fixture, 1);
    try row(allocator, io, "Opus 32k mono (Hybrid)", opus_hybrid_fixture, 1);
    try row(allocator, io, "Opus 24k stereo (SILK)", opus_silk_stereo_fixture, 2);

    // Legacy rows: built in memory exactly like the throughput rows.
    {
        const codes = try allocator.alloc(u8, 16_000);
        defer allocator.free(codes);
        for (codes, 0..) |*code, i| code.* = @truncate(i * 37 + 11);
        const wav = try testutil.buildG711(allocator, testutil.format_mulaw, 1, 8000, codes);
        defer allocator.free(wav);
        try row(allocator, io, "WAV mu-law 8k mono", wav, 1);
    }
    {
        const wav = try buildAdpcm(allocator, testutil.format_ima_adpcm);
        defer allocator.free(wav);
        try row(allocator, io, "WAV IMA ADPCM 44.1k mono", wav, 1);
    }
    {
        const wav = try buildAdpcm(allocator, testutil.format_ms_adpcm);
        defer allocator.free(wav);
        try row(allocator, io, "WAV MS ADPCM 44.1k mono", wav, 1);
    }
    {
        const frames: u32 = 44_100 * 2;
        const samples = try allocator.alloc(u8, frames * 2);
        defer allocator.free(samples);
        for (samples, 0..) |*byte, i| byte.* = @truncate(i * 13 + 5);
        const aiff = try testutil.buildAiff(allocator, 1, 44_100, 16, frames, samples);
        defer allocator.free(aiff);
        try row(allocator, io, "AIFF PCM16 44.1k mono", aiff, 1);
    }

    try concurrency(allocator);

    std.debug.print(
        "steady-state: allocations counted after the first non-empty read; " ++
            "a non-zero value is Vorbis/Opus packet look-ahead, not a per-frame alloc.\n",
        .{},
    );
}

fn row(
    allocator: std.mem.Allocator,
    io: std.Io,
    label: []const u8,
    bytes: []const u8,
    channels: u16,
) !void {
    var stats = try measure(allocator, bytes, channels);
    stats.samples_per_sec = try speed(allocator, io, bytes, channels);
    std.debug.print(
        "{s:<32} {d:11} {d:10} {d:10} {d:10} {d:12} {d:10} {d:15.1}\n",
        .{
            label,
            stats.open_allocs,
            stats.open_bytes,
            stats.read_allocs,
            stats.read_bytes,
            stats.steady_allocs,
            stats.peak_bytes,
            stats.samples_per_sec,
        },
    );
}

fn measure(allocator: std.mem.Allocator, bytes: []const u8, channels: u16) !RowStats {
    var counter = Counter.init(allocator);
    var reader = std.Io.Reader.fixed(bytes);
    var out: [read_buffer_samples]i16 = undefined;

    var dec = try root.open(counter.allocator(), &reader);
    const opened = counter.snapshot();
    var after_first: Counter.Snapshot = opened;
    var first_read = false;
    var frames: u64 = 0;
    var checksum: i64 = 0;

    while (true) {
        const n = dec.read(&out) catch |err| {
            dec.deinit();
            std.debug.print("alloc bench: {s} failed: {s}\n", .{ "decode", @errorName(err) });
            return err;
        };
        if (n == 0) break;
        if (n % channels != 0) {
            dec.deinit();
            return error.UnexpectedSampleCount;
        }
        frames += n / channels;
        for (out[0..n]) |sample| checksum +%= sample;
        if (!first_read) {
            first_read = true;
            after_first = counter.snapshot();
        }
    }
    dec.deinit();
    std.mem.doNotOptimizeAway(checksum);
    const total = counter.snapshot();
    if (total.current != 0 or total.live != 0) return error.MemoryNotBalanced;

    return .{
        .open_allocs = opened.allocs,
        .open_bytes = opened.alloc_bytes,
        .read_allocs = total.allocs - opened.allocs,
        .read_bytes = total.alloc_bytes - opened.alloc_bytes,
        .steady_allocs = total.allocs - after_first.allocs,
        .peak_bytes = total.peak,
        .frames = frames,
    };
}

fn speed(
    allocator: std.mem.Allocator,
    io: std.Io,
    bytes: []const u8,
    channels: u16,
) !f64 {
    var out: [read_buffer_samples]i16 = undefined;
    var checksum: i64 = 0;

    // First pass sets the repetition count, so even a 20 ms fixture is timed
    // for long enough that the wall clock is meaningful.
    var frames: u64 = 0;
    const first_start = std.Io.Clock.Timestamp.now(io, .awake);
    {
        var reader = std.Io.Reader.fixed(bytes);
        var dec = try root.open(allocator, &reader);
        defer dec.deinit();
        while (true) {
            const n = try dec.read(&out);
            if (n == 0) break;
            frames += n / channels;
            for (out[0..n]) |sample| checksum +%= sample;
        }
    }
    const first_ns: f64 = @floatFromInt(first_start.untilNow(io).raw.nanoseconds);
    if (first_ns <= 0) return error.TimerResolutionTooLow;
    const target_ns: f64 = 200.0 * std.time.ns_per_ms;
    var reps: usize = @intFromFloat(@max(1.0, target_ns / first_ns));
    reps = @min(reps, 2000);

    var total_frames: u64 = 0;
    const started = std.Io.Clock.Timestamp.now(io, .awake);
    var round: usize = 0;
    while (round < reps) : (round += 1) {
        var reader = std.Io.Reader.fixed(bytes);
        var dec = try root.open(allocator, &reader);
        defer dec.deinit();
        while (true) {
            const n = try dec.read(&out);
            if (n == 0) break;
            total_frames += n / channels;
            for (out[0..n]) |sample| checksum +%= sample;
        }
    }
    std.mem.doNotOptimizeAway(checksum);
    const elapsed_ns: f64 = @floatFromInt(started.untilNow(io).raw.nanoseconds);
    if (elapsed_ns <= 0) return error.TimerResolutionTooLow;
    const seconds = elapsed_ns / std.time.ns_per_s;
    const samples = @as(f64, @floatFromInt(total_frames)) * @as(f64, @floatFromInt(channels));
    return samples / seconds;
}

const adpcm_blocks: usize = 44;

fn buildAdpcm(allocator: std.mem.Allocator, tag: u16) ![]u8 {
    const block_align: u16 = 1024;
    const payload = try allocator.alloc(u8, block_align * adpcm_blocks);
    defer allocator.free(payload);
    for (0..adpcm_blocks) |b| {
        const at = b * block_align;
        if (tag == testutil.format_ima_adpcm) {
            std.mem.writeInt(i16, payload[at..][0..2], 0, .little);
            payload[at + 2] = 5;
            payload[at + 3] = 0;
            for (payload[at + 4 ..][0 .. block_align - 4]) |*byte| byte.* = 0x5A;
        } else {
            payload[at] = 0;
            std.mem.writeInt(i16, payload[at + 1 ..][0..2], 32, .little);
            std.mem.writeInt(i16, payload[at + 3 ..][0..2], 0, .little);
            std.mem.writeInt(i16, payload[at + 5 ..][0..2], 0, .little);
            for (payload[at + 7 ..][0 .. block_align - 7]) |*byte| byte.* = 0x3C;
        }
    }
    return testutil.buildAdpcm(allocator, .{
        .tag = tag,
        .channels = 1,
        .sample_rate = 44_100,
        .block_align = block_align,
        .bits = 4,
        .samples_per_block = if (tag == testutil.format_ima_adpcm) 2041 else 2036,
        .coefficients = &testutil.ms_coefficients,
    }, payload);
}

// ---------------------------------------------------------------------------
// Concurrency: eight decoders alive at once, reads interleaved.
// ---------------------------------------------------------------------------

const ConcurrentItem = struct {
    label: []const u8,
    bytes: []const u8,
    channels: u16,
};

fn concurrency(allocator: std.mem.Allocator) !void {
    const wav = try testutil.buildDemoPcm16(allocator, 44_100);
    defer allocator.free(wav);

    const aiff_frames: u32 = 44_100 * 2;
    const aiff_pcm = try allocator.alloc(u8, aiff_frames * 2);
    defer allocator.free(aiff_pcm);
    for (aiff_pcm, 0..) |*byte, i| byte.* = @truncate(i * 13 + 5);
    const aiff = try testutil.buildAiff(allocator, 1, 44_100, 16, aiff_frames, aiff_pcm);
    defer allocator.free(aiff);

    const items = [_]ConcurrentItem{
        .{ .label = "WAV", .bytes = wav, .channels = 2 },
        .{ .label = "FLAC LPC", .bytes = flac_lpc_fixture, .channels = 2 },
        .{ .label = "MP3 mono", .bytes = mp3_fixture, .channels = 1 },
        .{ .label = "MP3 stereo", .bytes = mp3_stereo_fixture, .channels = 2 },
        .{ .label = "Vorbis", .bytes = vorbis_fixture, .channels = 2 },
        .{ .label = "Opus CELT", .bytes = opus_fixture, .channels = 2 },
        .{ .label = "Opus SILK", .bytes = opus_silk_fixture, .channels = 1 },
        .{ .label = "AIFF", .bytes = aiff, .channels = 1 },
    };

    // The reference is each decoder read alone, into one exact-size buffer.
    var expected: [items.len][]i16 = undefined;
    var expected_len: [items.len]usize = undefined;
    var expected_count: usize = 0;
    for (items, 0..) |item, index| {
        expected[index] = try testutil.decodeAll(allocator, item.bytes, 512);
        expected_len[index] = expected[index].len;
        expected_count += 1;
    }
    defer {
        for (expected[0..expected_count]) |samples| allocator.free(samples);
    }

    var counter = Counter.init(allocator);
    const pa = counter.allocator();

    var readers: [items.len]std.Io.Reader = undefined;
    var decoders: [items.len]*root.Decoder = undefined;
    var opened_count: usize = 0;
    var cleaned = false;
    defer if (!cleaned) {
        var i: usize = 0;
        while (i < opened_count) : (i += 1) {
            decoders[i].deinit();
            pa.destroy(decoders[i]);
        }
    };

    for (items, 0..) |item, index| {
        readers[index] = std.Io.Reader.fixed(item.bytes);
        decoders[index] = try pa.create(root.Decoder);
        decoders[index].* = root.open(pa, &readers[index]) catch |err| {
            pa.destroy(decoders[index]);
            return err;
        };
        opened_count += 1;
    }

    const all_open = counter.snapshot();
    std.debug.print(
        "concurrency: {d} decoders open together, live_bytes={d}, peak_bytes={d}\n",
        .{ items.len, all_open.current, all_open.peak },
    );

    var positions: [items.len]usize = @splat(0);
    var active: [items.len]bool = @splat(true);
    var samples: [read_buffer_samples]i16 = undefined;
    var compared: usize = 0;
    var mismatches: usize = 0;
    var rounds: usize = 0;
    var still_active: usize = items.len;

    while (still_active != 0 and rounds < 1_000_000) : (rounds += 1) {
        for (items, 0..) |item, index| {
            if (!active[index]) continue;
            const n = try decoders[index].read(&samples);
            if (n == 0) {
                active[index] = false;
                still_active -= 1;
                if (positions[index] != expected_len[index]) {
                    std.debug.print(
                        "concurrency: {s} ended at {d} samples, sequential read produced {d}\n",
                        .{ item.label, positions[index], expected_len[index] },
                    );
                    mismatches += 1;
                }
                continue;
            }
            const pos = positions[index];
            if (pos + n > expected_len[index] or
                !std.mem.eql(i16, samples[0..n], expected[index][pos .. pos + n]))
            {
                std.debug.print(
                    "concurrency: {s} differs at sample {d} (n={d})\n",
                    .{ item.label, pos, n },
                );
                mismatches += 1;
                active[index] = false;
                still_active -= 1;
                continue;
            }
            positions[index] = pos + n;
            compared += n;
        }
    }

    if (rounds >= 1_000_000) return error.ConcurrentReadLoop;
    if (mismatches != 0) return error.ConcurrentMismatch;

    for (decoders) |dec| {
        dec.deinit();
        pa.destroy(dec);
    }
    cleaned = true;

    std.debug.print(
        "concurrency: interleaved reads match sequential exactly ({d} samples, {d} rounds)\n",
        .{ compared, rounds },
    );
    std.debug.print(
        "concurrency: peak_bytes={d}, live_bytes_after_deinit={d}, live_blocks={d}\n",
        .{ counter.peak, counter.current, counter.live },
    );
    if (counter.current != 0 or counter.live != 0) return error.MemoryNotBalanced;
}
