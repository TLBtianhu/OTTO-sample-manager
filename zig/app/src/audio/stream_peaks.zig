//! 用真实总帧数做第二遍有界峰值计算：头部说谎或开流长度未知时也不保留整段 PCM。
const std = @import("std");
const decode = @import("decode.zig");
const peaks_mod = @import("peaks.zig");
const budget = @import("../mem_budget.zig");

pub fn compute(
    allocator: std.mem.Allocator,
    path: []const u8,
    options: decode.Options,
    total_frames: u64,
    buckets: usize,
) decode.Error!peaks_mod.Peaks {
    if (total_frames == 0) return error.Empty;
    const count: usize = @intCast(@min(@as(u64, buckets), total_frames));
    var result: peaks_mod.Peaks = .{
        .min = try allocator.alloc(i16, count),
        .max = undefined,
    };
    errdefer if (result.min.len != 0) allocator.free(result.min);
    result.max = try allocator.alloc(i16, count);
    errdefer allocator.free(result.max);

    var stream: decode.Stream = undefined;
    var stream_options = options;
    stream_options.stats_out = null;
    stream_options.retain_bytes = budget.streaming_pcm_bytes;
    try stream.init(allocator, path, stream_options);
    defer stream.deinit();
    var merger = peaks_mod.Merger.init(total_frames, count, result.min, result.max);
    var chunk: [decode.chunk_samples]i16 = undefined;
    while (true) {
        const before = stream.pcm.items.len;
        const got = try stream.step(&chunk);
        if (got == 0) break;
        merger.push(stream.pcm.items[before..], stream.channels, 16, .pcm);
        stream.discardConsumed();
    }
    if (stream.frames != total_frames) return error.Corrupt;
    merger.finish();
    return result;
}
