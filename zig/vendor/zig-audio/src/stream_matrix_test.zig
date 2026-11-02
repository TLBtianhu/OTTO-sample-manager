//! Cross-format short-buffer matrix.
//!
//! Every decoder is driven through the same sequence of caller buffer sizes:
//! the full buffer, one sample (one i16), 3, 7, 13 samples, a fixed-seed
//! random 1..64 samples, and a mixed sequence that alternates tiny buffers
//! with full ones so a partially consumed frame has to survive a size change.
//! The concatenated output must equal the full-buffer reference exactly: no
//! duplicated sample, no dropped sample, no inserted silence, and the tail of
//! a non-frame-aligned buffer must stay untouched.
//!
//! Two more properties are asserted here:
//!
//!   * `read` allocates nothing (WAV, AIFF, FLAC, MP3) or allocates only
//!     per-packet scratch whose total is independent of the caller buffer size
//!     (Ogg Vorbis/Opus). `read_alloc_cap` is the measured baseline with a
//!     wide margin: the largest single request observed is 51 bytes (an Opus
//!     packet) and the Ogg page buffer is an `open`-time allocation, excluded.
//!   * a buffer smaller than one frame is `ShortBuffer` and moves nothing;
//!     switching back to a full buffer then finishes the stream exactly.
//!
//! The streams are built in memory (`stream_builders.zig`), so this is an L1
//! pure-library test: no fixtures, no vectors, no ffmpeg.

const std = @import("std");
const root = @import("root.zig");
const testutil = @import("testutil.zig");
const builders = @import("stream_builders.zig");
const testing = std.testing;

/// Output-buffer size of the reference run and of any full-sized read.
const full_buffer = 4096;

/// Cap on a single allocation made from inside `read` (bytes). Measured
/// baseline across all 26 variants: WAV/AIFF/FLAC/MP3 allocate 0; Vorbis's
/// packet-lookahead ArrayList tops out at 134 bytes; Opus's at 204 bytes
/// (its packet is 51 bytes). 512 keeps a margin for one more growth step
/// while still refusing anything proportional to the caller's buffer.
const read_alloc_cap: usize = 512;

/// Filler for the part of `out` a call must not write. Any value works as long
/// as no decoder writes it legitimately.
const sentinel: i16 = 0x5A5A;

const Pattern = struct {
    label: []const u8,
    size: usize,
    random: bool,
    /// Alternate one tiny buffer with a full one, so the decoder has to
    /// resume a partially consumed frame/chunk across a size change.
    mixed: bool = false,
};

const patterns = [_]Pattern{
    .{ .label = "full", .size = full_buffer, .random = false },
    .{ .label = "1", .size = 1, .random = false },
    .{ .label = "3", .size = 3, .random = false },
    .{ .label = "7", .size = 7, .random = false },
    .{ .label = "13", .size = 13, .random = false },
    .{ .label = "rnd", .size = 0, .random = true },
    .{ .label = "mix", .size = 0, .random = false, .mixed = true },
};

/// Allocator wrapper that records every request the decoder's `read` path
/// makes. `resize` is forwarded and not counted: growing an existing block in
/// place cannot hide a new buffer-sized allocation.
const Counting = struct {
    parent: std.mem.Allocator,
    total: usize = 0,
    requests: usize = 0,
    max_single: usize = 0,

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn allocator(self: *Counting) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn reset(self: *Counting) void {
        self.total = 0;
        self.requests = 0;
        self.max_single = 0;
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        const ptr = self.parent.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.total += len;
        self.requests += 1;
        self.max_single = @max(self.max_single, len);
        return ptr;
    }

    fn resize(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        return self.parent.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        const ptr = self.parent.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        if (new_len > memory.len) {
            self.total += new_len - memory.len;
            self.requests += 1;
            self.max_single = @max(self.max_single, new_len);
        }
        return ptr;
    }

    fn free(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) void {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.parent.rawFree(memory, alignment, ret_addr);
    }
};

const Run = struct {
    samples: std.ArrayList(i16) = .empty,
    short_buffer: usize = 0,
    tail_touched: usize = 0,
    empty_read_moved: bool = false,
    eof_violation: bool = false,
    overrun: bool = false,
    err: ?root.Error = null,
    alloc_bytes: usize = 0,
    alloc_requests: usize = 0,
    alloc_max_single: usize = 0,

    fn deinit(self: *Run, allocator: std.mem.Allocator) void {
        self.samples.deinit(allocator);
    }
};

fn randomSize(seed: *u64) usize {
    seed.* = seed.* *% 6364136223846793005 +% 1442695040888963407;
    return 1 + @as(usize, @intCast((seed.* >> 33) % 64));
}

/// One frame, then a full read, then a deliberately non-frame-aligned size,
/// and so on: the point is the size change, not the sizes themselves.
fn mixedSize(channels: u16, step: *usize) usize {
    const sizes = [6]usize{ channels, full_buffer, 3, full_buffer, 7, 13 };
    const size = sizes[step.* % sizes.len];
    step.* += 1;
    return size;
}

fn errName(err: ?root.Error) []const u8 {
    return if (err) |value| @errorName(value) else "none";
}

fn firstDiff(a: []const i16, b: []const i16) ?usize {
    const common = @min(a.len, b.len);
    for (0..common) |i| {
        if (a[i] != b[i]) return i;
    }
    return if (a.len == b.len) null else common;
}

/// Drive one decoder to EOF with `pattern`'s buffer size. A buffer that cannot
/// hold one frame yields `ShortBuffer` once and then the rest of the stream is
/// read with a full buffer, which is what proves the failed call moved nothing.
fn decodeRun(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    channels: u16,
    pattern: Pattern,
) !Run {
    var run: Run = .{};
    errdefer run.deinit(allocator);

    var counting = Counting{ .parent = allocator };
    var reader = std.Io.Reader.fixed(bytes);
    var dec = try root.open(counting.allocator(), &reader);
    defer dec.deinit();

    // `open` sizes its frame/page buffers on purpose; the contract here is
    // about `read`, so the counter starts after opening.
    counting.reset();

    var buf: [full_buffer]i16 = undefined;
    var seed: u64 = 0x9E37_79B9_7F4A_7C15;
    var mixed_step: usize = 0;
    var force_full = false;

    // Documented: an empty output is a no-op that returns 0.
    if (try dec.read(buf[0..0]) != 0) run.empty_read_moved = true;

    while (true) {
        const want = if (force_full)
            full_buffer
        else if (pattern.random)
            randomSize(&seed)
        else if (pattern.mixed)
            mixedSize(channels, &mixed_step)
        else
            pattern.size;

        @memset(buf[0..want], sentinel);
        const got = dec.read(buf[0..want]) catch |err| {
            if (err == error.ShortBuffer and want < channels) {
                run.short_buffer += 1;
                force_full = true;
                continue;
            }
            run.err = err;
            break;
        };
        if (got == 0) break;
        if (got > want) {
            run.overrun = true;
            break;
        }
        for (buf[got..want]) |value| {
            if (value != sentinel) run.tail_touched += 1;
        }
        try run.samples.appendSlice(allocator, buf[0..got]);
    }

    if (run.err == null) {
        // EOF is sticky: repeated reads return 0, not an error.
        if (try dec.read(buf[0..full_buffer]) != 0) run.eof_violation = true;
        if (try dec.read(buf[0..full_buffer]) != 0) run.eof_violation = true;
    }

    run.alloc_bytes = counting.total;
    run.alloc_requests = counting.requests;
    run.alloc_max_single = counting.max_single;
    return run;
}

fn ok(run: *const Run, reference: []const i16) bool {
    return run.err == null and
        !run.overrun and
        !run.empty_read_moved and
        !run.eof_violation and
        run.tail_touched == 0 and
        std.mem.eql(i16, run.samples.items, reference);
}

test "short-buffer matrix: every format yields the same samples at every buffer size" {
    var variants = try builders.buildAll(testing.allocator);
    defer variants.deinit();

    var failures: usize = 0;
    var cells: usize = 0;

    for (variants.items) |variant| {
        var reference = try decodeRun(testing.allocator, variant.bytes, variant.channels, patterns[0]);
        defer reference.deinit(testing.allocator);

        std.debug.print("matrix {s:<22} ch={d}", .{ variant.name, variant.channels });

        var alloc_bytes: [patterns.len]usize = @splat(0);
        var max_single: [patterns.len]usize = @splat(0);

        for (patterns, 0..) |pattern, index| {
            var run = try decodeRun(testing.allocator, variant.bytes, variant.channels, pattern);
            defer run.deinit(testing.allocator);
            alloc_bytes[index] = run.alloc_bytes;
            max_single[index] = run.alloc_max_single;
            cells += 1;

            const passed = ok(&run, reference.samples.items);
            if (!passed) {
                failures += 1;
                const diff = firstDiff(run.samples.items, reference.samples.items);
                std.debug.print(
                    "\nFAIL matrix {s} pattern={s}: err={s} got={d} want={d} short={d} tail={d} overrun={} empty={} eof={} first_diff={s}\n",
                    .{
                        variant.name,
                        pattern.label,
                        errName(run.err),
                        run.samples.items.len,
                        reference.samples.items.len,
                        run.short_buffer,
                        run.tail_touched,
                        run.overrun,
                        run.empty_read_moved,
                        run.eof_violation,
                        if (diff != null) "yes" else "no",
                    },
                );
                if (diff) |at| {
                    const got_value: i32 = if (at < run.samples.items.len)
                        run.samples.items[at]
                    else
                        std.math.minInt(i16);
                    const want_value: i32 = if (at < reference.samples.items.len)
                        reference.samples.items[at]
                    else
                        std.math.minInt(i16);
                    std.debug.print(
                        "  first difference at {d}: got={d} want={d}\n",
                        .{ at, got_value, want_value },
                    );
                }
            }

            // Short buffer cells are marked with `*`, not excused: a buffer
            // smaller than one frame is the contracted ShortBuffer, and the
            // recovery run above still had to reproduce every sample.
            std.debug.print(" {s}={s}{s}", .{
                pattern.label,
                if (passed) "PASS" else "FAIL",
                if (run.short_buffer != 0) "*" else "",
            });
        }

        // Allocations inside `read` must stay under the cap and must not
        // depend on the caller's buffer size.
        for (patterns, 0..) |pattern, index| {
            if (max_single[index] > read_alloc_cap) {
                failures += 1;
                std.debug.print(
                    "\nFAIL alloc {s} pattern={s}: single request {d} > cap {d}\n",
                    .{ variant.name, pattern.label, max_single[index], read_alloc_cap },
                );
            }
            if (alloc_bytes[index] != alloc_bytes[0]) {
                failures += 1;
                std.debug.print(
                    "\nFAIL alloc {s} pattern={s}: total {d} != full-buffer total {d}\n",
                    .{ variant.name, pattern.label, alloc_bytes[index], alloc_bytes[0] },
                );
            }
        }
        std.debug.print("  read_alloc={d}B max_single={d}B\n", .{
            alloc_bytes[0],
            max_single[0],
        });
    }

    std.debug.print("matrix summary: {d} variants x {d} patterns = {d} cells, failures={d}\n", .{
        variants.items.len,
        patterns.len,
        cells,
        failures,
    });
    try testing.expectEqual(@as(usize, 0), failures);
}

test "short-buffer contract: empty output, ShortBuffer and EOF leave state alone" {
    const payload = try testutil.leI16Payload(
        testing.allocator,
        &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 },
    );
    defer testing.allocator.free(payload);
    const file = try testutil.buildPcm(testing.allocator, 2, 44_100, 16, payload);
    defer testing.allocator.free(file);

    var reader = std.Io.Reader.fixed(file);
    var dec = try root.open(testing.allocator, &reader);
    defer dec.deinit();
    try testing.expectEqual(@as(u16, 2), dec.info.channels);

    var out: [8]i16 = undefined;
    try testing.expectEqual(@as(usize, 0), try dec.read(out[0..0]));

    // One i16 is less than one stereo frame: named error, nothing consumed.
    try testing.expectError(error.ShortBuffer, dec.read(out[0..1]));
    // The very next read still starts at sample 0.
    try testing.expectEqual(@as(usize, 2), try dec.read(out[0..2]));
    try testing.expectEqualSlices(i16, &.{ 1, 2 }, out[0..2]);

    // 7 samples hold three frames; the seventh slot must stay untouched.
    @memset(out[0..7], sentinel);
    try testing.expectEqual(@as(usize, 6), try dec.read(out[0..7]));
    try testing.expectEqualSlices(i16, &.{ 3, 4, 5, 6, 7, 8 }, out[0..6]);
    try testing.expectEqual(sentinel, out[6]);

    // Drain, then EOF repeats 0 and is not an error.
    while (try dec.read(out[0..7]) != 0) {}
    try testing.expectEqual(@as(usize, 0), try dec.read(out[0..7]));
    try testing.expectEqual(@as(usize, 0), try dec.read(out[0..7]));
}
