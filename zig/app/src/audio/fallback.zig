//! 开流总帧数未知的非渐进预览：第一遍计数，第二遍按真帧数有界算峰值。
const std = @import("std");
const preview = @import("../preview.zig");
const decode = @import("decode.zig");
const session_mod = @import("session.zig");
const stream_peaks = @import("stream_peaks.zig");
const peaks_mod = @import("peaks.zig");
const waveform = @import("waveform.zig");
const pcm_source = @import("pcm_source.zig");
const residency = @import("residency.zig");
const pcm_spool = @import("pcm_spool.zig");
const player = @import("player.zig");

pub fn build(
    allocator: std.mem.Allocator,
    stream: *decode.Stream,
    path: []const u8,
    options: decode.Options,
) (decode.Error || player.Error)!preview.AudioSession {
    const requested = residency.requested();
    if (requested == .full_decode) {
        try stream.retainAll();
    } else if (requested != .auto) {
        stream.setRetention(residency.retentionBytes(requested).?);
    }
    var chunk: [decode.chunk_samples]i16 = undefined;
    var spool: ?pcm_spool.Spool = if (requested != .auto and requested != .full_decode) try pcm_spool.Spool.create() else null;
    defer if (spool) |*value| value.deinit();
    var playback_window: []u8 = &.{};
    errdefer if (playback_window.len != 0) allocator.free(playback_window);
    while (true) {
        if (try stream.step(&chunk) == 0) break;
        if (requested == .full_decode) continue;
        if (spool == null and stream.pcm.items.len >= @import("../mem_budget.zig").full_decode_max_bytes) {
            spool = try pcm_spool.Spool.create();
        }
        if (spool) |*value| try value.writeAll(stream.pcm.items);
        if (requested != .waveform_only and playback_window.len == 0) {
            const window_bytes = @import("../mem_budget.zig").bounded_window_bytes;
            if (stream.pcm.items.len < window_bytes) continue;
            playback_window = try allocator.dupe(u8, stream.pcm.items[0..window_bytes]);
            stream.pcm.deinit(allocator);
            stream.pcm = .empty;
            try stream.pcm.ensureTotalCapacityPrecise(allocator, @import("../mem_budget.zig").streaming_pcm_bytes + decode.chunk_samples * 2);
        }
        stream.discardConsumed();
    }
    var decoded = try stream.finish();
    stream.deinit();
    errdefer decoded.deinit(allocator);
    if (spool) |*value| {
        const total = decoded.frames * @as(u64, decoded.channels) * 2;
        if (value.written < total) {
            const missing: usize = @intCast(total - value.written);
            if (missing > decoded.pcm.len) return error.Corrupt;
            try value.writeAll(decoded.pcm[decoded.pcm.len - missing ..]);
        }
    }
    const mode = residency.choose(residency.estimatedBytes(decoded.frames, decoded.sample_rate, decoded.channels));
    if (mode == .full_decode) return session_mod.build(allocator, &decoded);

    const peaks = if (spool) |*value|
        try value.computePeaks(allocator, decoded.frames, decoded.channels, peaks_mod.default_buckets)
    else
        try stream_peaks.compute(allocator, path, options, decoded.frames, peaks_mod.default_buckets);
    errdefer peaks.deinit(allocator);
    const bitmap = try waveform.render(allocator, peaks, waveform.default_width, waveform.default_height, waveform.default_color);
    errdefer bitmap.deinit(allocator);
    if (decoded.pcm.len != 0) {
        allocator.free(decoded.pcm);
        decoded.pcm = &.{};
    }
    const initial: []u8 = if (mode == .bounded_playback) playback_window else &.{};
    const source = try pcm_source.createNative(allocator, path, options, decoded.channels, decoded.frames, initial);
    if (mode == .bounded_playback) playback_window = &.{};
    return .{
        .pcm = &.{},
        .source = source,
        .pcm_residency = mode,
        .sample_rate = decoded.sample_rate,
        .channels = decoded.channels,
        .bits = 16,
        .duration_ms = decoded.duration_ms,
        .total_frames = decoded.frames,
        .lazy = .{ .allocator = allocator },
        .peaks = peaks,
        .waveform = bitmap,
        .waveform_version = waveform.completeColumns(peaks.len(), bitmap.width, peaks.len()),
    };
}
