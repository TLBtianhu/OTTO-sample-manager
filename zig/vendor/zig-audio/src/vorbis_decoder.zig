//! Streaming Ogg/Vorbis decoder.
//!
//! The decode order is the specification's, and the order matters:
//!
//!   1. packet type, mode number, block size and the two window flags;
//!   2. floor decode, one channel at a time (a "used" floor also means the
//!      channel has residue this frame);
//!   3. nonzero propagation through the coupling steps — a coupled pair is
//!      decoded if *either* side has a floor;
//!   4. residue decode, one submap at a time, over the channels that have one;
//!   5. inverse coupling, in *reverse* step order, on the residue vectors;
//!   6. floor curve applied by *multiplying* the residue, which is the dot
//!      product; a channel with an unused floor is zeroed here, not in step 2;
//!   7. IMDCT, window, and the lap with the previous block.
//!
//! Steps 5 and 6 cannot be swapped: coupling works on the residue vectors before
//! the floor gain is applied, and its sign logic (`M > 0`, `A > 0` quadrants) is
//! the square-polar decode, not a plain M+A / M-A butterfly.
//!
//! Lapping. A block of `n` samples keeps its second half and returns the overlap
//! of that half with the next block's first half; `previous/4 + n/4` samples come
//! out per block. The first block returns nothing — it primes the lap — which is
//! exactly the encoder's pre-roll. The stream's last granule position is the
//! total number of samples the file represents, so the final block is trimmed to
//! it; nothing is trimmed at the start.

const std = @import("std");
const types = @import("types.zig");
const ogg = @import("ogg.zig");
const vorbis = @import("vorbis.zig");
const vorbis_bits = @import("vorbis_bits.zig");
const vorbis_codebook = @import("vorbis_codebook.zig");
const huffman = @import("vorbis_huffman.zig");
const floor_mod = @import("vorbis_floor.zig");
const residue_mod = @import("vorbis_residue.zig");
const dsp = @import("vorbis_dsp.zig");

pub const Error = types.Error;
const AudioBits = vorbis_bits.AudioBits;
const ilog = vorbis_bits.ilog;

const window_kinds = @typeInfo(dsp.WindowKind).@"enum".field_names.len;
pub const Decoder = struct {
    allocator: std.mem.Allocator,
    demux: ogg.Demuxer,
    info: types.Info,
    setup: vorbis.Setup = .{},
    channels: usize = 0,
    blocksize_0: usize = 0,
    blocksize_1: usize = 0,
    half_1: usize = 0,

    books: []huffman.Table = &.{},
    floors: []floor_mod.Table = &.{},
    /// `channels * half_1` spectra, one row per channel.
    spectra: []f32 = &.{},
    /// `channels * blocksize_1` windowed IMDCT output.
    block: []f32 = &.{},
    /// `channels * half_1`: the previous block's windowed second half.
    tail: []f32 = &.{},
    /// `channels * half_1` for format 2's interleaved vector.
    interleaved: []f32 = &.{},
    floor_states: []floor_mod.State = &.{},
    classes: []u8 = &.{},
    vectors: [][]f32 = &.{},

    windows: [window_kinds][]f32 = @splat(&.{}),
    transform_0: dsp.Transform = .{},
    transform_1: dsp.Transform = .{},
    fft_a: []dsp.Complex = &.{},
    fft_b: []dsp.Complex = &.{},
    imdct_c: []f32 = &.{},

    chunk: []i16 = &.{},
    /// The same chunk before the i16 conversion; kept so tests can compare
    /// against ffmpeg's float output without going through a quantizer.
    chunk_f32: []f32 = &.{},
    capture: ?*std.ArrayList(f32) = null,
    capture_gpa: std.mem.Allocator = undefined,
    chunk_len: usize = 0,
    chunk_pos: usize = 0,

    /// One packet of lookahead, so the last block can be trimmed to the granule
    /// before any of its samples are handed out.
    ahead: std.ArrayList(u8) = .empty,
    ahead_valid: bool = false,
    stream_done: bool = false,
    first_block: bool = true,
    previous_size: usize = 0,
    delivered: u64 = 0,
    done: bool = false,
    pending_error: ?types.Error = null,

    pub fn deinit(self: *Decoder) void {
        const allocator = self.allocator;
        for (self.books) |*book| book.deinit(allocator);
        if (self.books.len != 0) allocator.free(self.books);
        if (self.floors.len != 0) allocator.free(self.floors);
        freeF32(allocator, self.spectra);
        freeF32(allocator, self.block);
        freeF32(allocator, self.tail);
        freeF32(allocator, self.interleaved);
        if (self.floor_states.len != 0) allocator.free(self.floor_states);
        if (self.classes.len != 0) allocator.free(self.classes);
        if (self.vectors.len != 0) allocator.free(self.vectors);
        for (&self.windows) |*window| freeF32(allocator, window.*);
        self.transform_0.deinit(allocator);
        self.transform_1.deinit(allocator);
        if (self.fft_a.len != 0) allocator.free(self.fft_a);
        if (self.fft_b.len != 0) allocator.free(self.fft_b);
        freeF32(allocator, self.imdct_c);
        if (self.chunk.len != 0) allocator.free(self.chunk);
        if (self.chunk_f32.len != 0) allocator.free(self.chunk_f32);
        self.ahead.deinit(allocator);
        self.setup.deinit(allocator);
        self.demux.deinit();
        self.* = undefined;
    }

    /// Open the first Vorbis stream in `reader`. `prefix` is what the public
    /// dispatcher already consumed (12 bytes).
    pub fn open(
        allocator: std.mem.Allocator,
        reader: *std.Io.Reader,
        prefix: []const u8,
    ) Error!Decoder {
        const demux = try ogg.Demuxer.init(allocator, reader, prefix);
        return openFromDemux(allocator, demux);
    }

    /// Same as `open`, but from a demultiplexer the caller already created. The
    /// dispatcher needs this: it has to look at the first packet to tell Vorbis
    /// from Opus, and the demultiplexer has already consumed that page, so
    /// handing the demultiplexer over is the only way not to read it twice.
    /// On failure the demultiplexer is freed here.
    pub fn openFromDemux(allocator: std.mem.Allocator, demux_in: ogg.Demuxer) Error!Decoder {
        var demux = demux_in;
        var demux_owned = false;
        errdefer if (!demux_owned) demux.deinit();
        if (demux.streamCodec() != .vorbis) return error.Unsupported;

        const identification_packet = (try demux.nextPacket()) orelse return error.Truncated;
        const identification = try vorbis.parseIdentification(identification_packet);
        const comment_packet = (try demux.nextPacket()) orelse return error.Truncated;
        try vorbis.parseComment(comment_packet);
        const setup_packet = (try demux.nextPacket()) orelse return error.Truncated;

        var decoder = Decoder{
            .allocator = allocator,
            .demux = demux,
            .info = undefined,
            .channels = identification.channels,
            .blocksize_0 = identification.blocksize_0,
            .blocksize_1 = identification.blocksize_1,
        };
        demux_owned = true;
        errdefer decoder.deinit();
        decoder.setup = try vorbis.parseSetup(allocator, setup_packet, identification.channels);
        decoder.info = .{
            .format = .ogg_vorbis,
            .sample_rate = identification.sample_rate,
            .channels = identification.channels,
            .bits_per_sample = 16,
            .total_frames = null,
        };
        try decoder.initialise();
        return decoder;
    }

    fn initialise(self: *Decoder) Error!void {
        const allocator = self.allocator;
        const channels = self.channels;
        if (channels == 0 or channels > types.max_channels) return error.Unsupported;
        if (self.blocksize_0 < 64 or self.blocksize_1 < self.blocksize_0) return error.Corrupt;
        self.half_1 = self.blocksize_1 / 2;

        var budget = huffman.Budget{};
        self.books = try allocator.alloc(huffman.Table, self.setup.codebooks.len);
        for (self.books) |*book| book.* = .{};
        for (self.setup.codebooks, 0..) |codebook, i| {
            self.books[i] = try huffman.build(allocator, codebook, &budget);
        }

        self.floors = try allocator.alloc(floor_mod.Table, self.setup.floors.len);
        for (self.floors) |*floor| floor.* = .{};
        for (self.setup.floors, 0..) |floor, i| {
            switch (floor) {
                .floor0 => {},
                .floor1 => |f1| self.floors[i] = try floor_mod.Table.init(f1),
            }
        }
        try self.validate();

        self.spectra = try allocator.alloc(f32, channels * self.half_1);
        self.block = try allocator.alloc(f32, channels * self.blocksize_1);
        self.tail = try allocator.alloc(f32, channels * self.half_1);
        self.interleaved = try allocator.alloc(f32, channels * self.half_1);
        self.floor_states = try allocator.alloc(floor_mod.State, channels);
        self.classes = try allocator.alloc(u8, channels * self.half_1);
        self.vectors = try allocator.alloc([]f32, channels);
        self.chunk = try allocator.alloc(i16, channels * (self.blocksize_1 / 2));
        self.chunk_f32 = try allocator.alloc(f32, channels * (self.blocksize_1 / 2));
        @memset(self.spectra, 0);
        @memset(self.block, 0);
        @memset(self.tail, 0);
        @memset(self.interleaved, 0);

        self.fft_a = try allocator.alloc(dsp.Complex, self.half_1);
        self.fft_b = try allocator.alloc(dsp.Complex, self.half_1);
        self.imdct_c = try allocator.alloc(f32, self.half_1);

        self.transform_0 = try dsp.Transform.init(allocator, self.blocksize_0);
        self.transform_1 = try dsp.Transform.init(allocator, self.blocksize_1);

        for (&self.windows, 0..) |*window, index| {
            const kind: dsp.WindowKind = @enumFromInt(index);
            const n = if (kind == .short) self.blocksize_0 else self.blocksize_1;
            window.* = try allocator.alloc(f32, n);
            dsp.buildWindow(window.*, n, self.blocksize_0, kind);
        }
    }

    /// Reject the setup shapes this decoder does not implement, before any PCM
    /// is promised: floor 0 channels and residue books without a value mapping.
    fn validate(self: *Decoder) Error!void {
        for (self.setup.mappings) |mapping| {
            for (mapping.submap_floor) |floor_index| {
                if (floor_index >= self.setup.floors.len) return error.Corrupt;
                if (self.setup.floors[floor_index].kind() != 1) return error.Unsupported;
            }
            for (mapping.submap_residue) |residue_index| {
                if (residue_index >= self.setup.residues.len) return error.Corrupt;
                const residue = self.setup.residues[residue_index];
                if (residue.residue_type > 2) return error.Corrupt;
                if (residue.classbook >= self.setup.codebooks.len) return error.Corrupt;
                for (residue.books) |book| {
                    if (book == 0xFF) continue;
                    if (book >= self.setup.codebooks.len) return error.Corrupt;
                    if (self.setup.codebooks[book].lookup_type == 0) return error.Corrupt;
                }
            }
        }
    }

    fn transformFor(self: *Decoder, blocksize: usize) *const dsp.Transform {
        return if (blocksize == self.blocksize_0) &self.transform_0 else &self.transform_1;
    }

    fn windowFor(self: *Decoder, kind: dsp.WindowKind) []const f32 {
        return self.windows[@intFromEnum(kind)];
    }

    fn peekPacket(self: *Decoder) Error!?[]const u8 {
        if (self.ahead_valid) return self.ahead.items;
        if (self.stream_done) return null;
        const packet = (try self.demux.nextPacket()) orelse {
            self.stream_done = true;
            return null;
        };
        self.ahead.clearRetainingCapacity();
        try self.ahead.appendSlice(self.allocator, packet);
        self.ahead_valid = true;
        return self.ahead.items;
    }

    /// Decode the next block that yields samples. Returns false at end of
    /// stream, after trimming the final block to the stream's granule.
    fn produceChunk(self: *Decoder) Error!bool {
        while (true) {
            const packet = (try self.peekPacket()) orelse return false;
            try self.decodeBlock(packet);
            self.ahead_valid = false;
            const is_last = (try self.peekPacket()) == null;
            if (is_last) self.trimToGranule();
            if (self.capture) |sink| {
                try sink.appendSlice(self.capture_gpa, self.chunk_f32[0..self.chunk_len]);
            }
            if (self.chunk_len != 0) return true;
            if (is_last) return false;
        }
    }

    /// The stream's last granule is a frame count; `chunk_len` is interleaved
    /// samples, so the comparison has to happen in frames.
    fn trimToGranule(self: *Decoder) void {
        const total = self.demux.lastGranule() orelse return;
        if (total <= self.delivered) {
            self.chunk_len = 0;
            return;
        }
        const remaining_frames = total - self.delivered;
        const chunk_frames = self.chunk_len / self.channels;
        if (remaining_frames < chunk_frames) {
            self.chunk_len = @intCast(remaining_frames * self.channels);
        }
    }

    fn decodeBlock(self: *Decoder, packet: []const u8) Error!void {
        const setup = &self.setup;
        var bits = AudioBits.init(packet);
        if (bits.readBits(1) != 0) return error.Corrupt;
        const mode_bits: u6 = ilog(@intCast(setup.modes.len - 1));
        const mode_number = bits.readBits(mode_bits);
        if (mode_number >= setup.modes.len) return error.Corrupt;
        const mode = setup.modes[mode_number];
        const mapping = &setup.mappings[mode.mapping];
        const blocksize = if (mode.blockflag) self.blocksize_1 else self.blocksize_0;
        const half = blocksize / 2;

        var previous_long = false;
        var next_long = false;
        if (mode.blockflag) {
            previous_long = bits.readBits(1) != 0;
            next_long = bits.readBits(1) != 0;
        }

        @memset(self.spectra, 0);
        var has_floor: [types.max_channels]bool = @splat(false);
        var nonzero: [types.max_channels]bool = @splat(false);

        if (!bits.overrun) {
            for (0..self.channels) |channel| {
                const submap: usize = if (mapping.submaps > 1) mapping.mux[channel] else 0;
                has_floor[channel] = try self.decodeFloor(
                    mapping.submap_floor[submap],
                    &bits,
                    channel,
                );
                nonzero[channel] = has_floor[channel];
            }
        }

        if (bits.overrun) {
            // End of packet while decoding a floor: the whole frame is silent,
            // but it still takes part in the lap.
            @memset(self.spectra, 0);
        } else {
            for (mapping.coupling) |step| {
                if (nonzero[step.magnitude] or nonzero[step.angle]) {
                    nonzero[step.magnitude] = true;
                    nonzero[step.angle] = true;
                }
            }
            try self.decodeResidues(mapping, &bits, nonzero[0..self.channels], half);
            self.inverseCoupling(mapping, half);
            {
                var smax: f32 = 0;
                var nz: usize = 0;
                for (0..self.channels) |c| {
                    for (self.spectra[c * self.half_1 ..][0..half]) |v| {
                        if (v != 0) {
                            nz += 1;
                            smax = @max(smax, @abs(v));
                        }
                    }
                }
            }
            self.applyFloors(mapping, has_floor[0..self.channels], half);
        }

        self.synthesise(blocksize, previous_long, next_long, half);
    }

    fn decodeFloor(self: *Decoder, floor_index: usize, bits: *AudioBits, channel: usize) Error!bool {
        const floor = self.setup.floors[floor_index];
        return switch (floor) {
            .floor0 => error.Unsupported,
            .floor1 => |f1| floor_mod.decodePacket(
                &self.floors[floor_index],
                f1,
                self.books,
                bits,
                &self.floor_states[channel],
            ),
        };
    }

    fn decodeResidues(
        self: *Decoder,
        mapping: *const vorbis.Mapping,
        bits: *AudioBits,
        nonzero: []const bool,
        half: usize,
    ) Error!void {
        const books = residue_mod.Books{
            .huffman = self.books,
            .codebooks = self.setup.codebooks,
        };
        var submap: usize = 0;
        while (submap < mapping.submaps) : (submap += 1) {
            var count: usize = 0;
            for (0..self.channels) |channel| {
                const channel_submap: usize = if (mapping.submaps > 1) mapping.mux[channel] else 0;
                if (channel_submap != submap) continue;
                if (!nonzero[channel]) continue;
                self.vectors[count] = self.spectra[channel * self.half_1 ..][0..half];
                count += 1;
            }
            if (count == 0) continue;
            const residue_index = mapping.submap_residue[submap];
            const residue = &self.setup.residues[residue_index];
            if (residue.residue_type == 2) {
                try self.decodeResidueInterleaved(books, residue, bits, self.vectors[0..count], half);
            } else {
                try residue_mod.decode(books, residue, bits, self.vectors[0..count], self.classes);
            }
        }
    }

    /// Format 2 codes one interleaved vector of `channels * half` elements; the
    /// decode itself is format 1, and only the deinterleave at the end is new.
    fn decodeResidueInterleaved(
        self: *Decoder,
        books: residue_mod.Books,
        residue: *const vorbis.Residue,
        bits: *AudioBits,
        vectors: []const []f32,
        half: usize,
    ) Error!void {
        const channels = vectors.len;
        const total = channels * half;
        const interleaved = self.interleaved[0..total];
        @memset(interleaved, 0);
        const single = [1][]f32{interleaved};
        try residue_mod.decode(books, residue, bits, &single, self.classes);
        for (0..channels) |channel| {
            const destination = vectors[channel];
            for (0..half) |i| destination[i] = interleaved[i * channels + channel];
        }
    }

    fn inverseCoupling(self: *Decoder, mapping: *const vorbis.Mapping, half: usize) void {
        var index = mapping.coupling.len;
        while (index > 0) {
            index -= 1;
            const step = mapping.coupling[index];
            const magnitude = self.spectra[step.magnitude * self.half_1 ..][0..half];
            const angle = self.spectra[step.angle * self.half_1 ..][0..half];
            for (0..half) |i| {
                const m = magnitude[i];
                const a = angle[i];
                if (m > 0) {
                    if (a > 0) {
                        magnitude[i] = m;
                        angle[i] = m - a;
                    } else {
                        angle[i] = m;
                        magnitude[i] = m + a;
                    }
                } else {
                    if (a > 0) {
                        magnitude[i] = m;
                        angle[i] = m + a;
                    } else {
                        angle[i] = m;
                        magnitude[i] = m - a;
                    }
                }
            }
        }
    }

    fn applyFloors(
        self: *Decoder,
        mapping: *const vorbis.Mapping,
        has_floor: []const bool,
        half: usize,
    ) void {
        for (0..self.channels) |channel| {
            const submap: usize = if (mapping.submaps > 1) mapping.mux[channel] else 0;
            const floor_index = mapping.submap_floor[submap];
            const spectrum = self.spectra[channel * self.half_1 ..][0..half];
            if (!has_floor[channel]) {
                @memset(spectrum, 0);
                continue;
            }
            floor_mod.applyCurve(
                &self.floors[floor_index],
                self.setup.floors[floor_index].floor1,
                &self.floor_states[channel],
                spectrum,
            );
        }
    }

    /// IMDCT, window, lap with the previous block, and the i16 conversion.
    fn synthesise(
        self: *Decoder,
        blocksize: usize,
        previous_long: bool,
        next_long: bool,
        half: usize,
    ) void {
        const kind = dsp.WindowKind.select(blocksize, self.blocksize_0, previous_long, next_long);
        const window = self.windowFor(kind);
        const transform = self.transformFor(blocksize);

        for (0..self.channels) |channel| {
            const spectrum = self.spectra[channel * self.half_1 ..][0..half];
            const block = self.block[channel * self.blocksize_1 ..][0..blocksize];
            transform.run(spectrum, block, self.fft_a, self.fft_b, self.imdct_c);
            for (0..blocksize) |i| block[i] *= window[i];
        }

        const previous = self.previous_size;
        const half_previous = previous / 2;
        const half_current = blocksize / 2;
        const out_frames = (previous + blocksize) / 4;
        const delta: i64 = @divTrunc(
            @as(i64, @intCast(blocksize)) - @as(i64, @intCast(previous)),
            4,
        );

        if (self.first_block) {
            self.chunk_len = 0;
        } else {
            for (0..self.channels) |channel| {
                const tail = self.tail[channel * self.half_1 ..][0..half_previous];
                const block = self.block[channel * self.blocksize_1 ..][0..blocksize];
                for (0..out_frames) |frame| {
                    var value: f32 = 0;
                    if (frame < half_previous) value += tail[frame];
                    const source = @as(i64, @intCast(frame)) + delta;
                    if (source >= 0 and source < @as(i64, @intCast(half_current))) {
                        value += block[@intCast(source)];
                    }
                    self.chunk[frame * self.channels + channel] = toI16(value);
                    self.chunk_f32[frame * self.channels + channel] = value;
                }
            }
            self.chunk_len = out_frames * self.channels;
        }
        self.chunk_pos = 0;

        // Keep the second half of this block for the next lap. `previous_size`
        // also records the block size, so a short/long transition knows how much
        // of this tail actually takes part.
        for (0..self.channels) |channel| {
            const source = self.block[channel * self.blocksize_1 + half_current ..][0..half_current];
            @memcpy(self.tail[channel * self.half_1 ..][0..half_current], source);
        }
        self.previous_size = blocksize;
        self.first_block = false;
    }

    /// Decode up to `out.len / channels` frames into `out` as interleaved i16.
    /// Returns 0 at end of stream; a buffer smaller than one frame is
    /// `error.ShortBuffer`.
    pub fn read(self: *Decoder, out: []i16) Error!usize {
        if (out.len == 0) return 0;
        if (self.pending_error) |err| return err;
        if (self.done) return 0;

        const channels = self.channels;
        const capacity_frames = out.len / channels;
        if (capacity_frames == 0) return error.ShortBuffer;
        const capacity = capacity_frames * channels;

        var written: usize = 0;
        while (written < capacity) {
            if (self.chunk_pos == self.chunk_len) {
                const more = self.produceChunk() catch |err| {
                    self.pending_error = err;
                    if (written == 0) return err;
                    break;
                };
                if (!more) {
                    self.done = true;
                    self.info.total_frames = self.demux.lastGranule();
                    break;
                }
            }
            const take = @min(self.chunk_len - self.chunk_pos, capacity - written);
            @memcpy(out[written..][0..take], self.chunk[self.chunk_pos..][0..take]);
            self.chunk_pos += take;
            written += take;
            self.delivered += take / channels;
        }
        return written;
    }
};

/// Float to i16, rounding to nearest. A Vorbis decoder is float by definition,
/// so this conversion is the only lossy step left; ffmpeg rounds (`lrintf`) and
/// truncating instead would cost several dB of SNR for nothing.
fn toI16(value: f32) i16 {
    const scaled = value * 32768.0;
    if (std.math.isNan(scaled)) return 0;
    return @intFromFloat(@round(std.math.clamp(scaled, -32768.0, 32767.0)));
}

fn freeF32(allocator: std.mem.Allocator, slice: []f32) void {
    if (slice.len != 0) allocator.free(slice);
}

