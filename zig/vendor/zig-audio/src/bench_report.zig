//! Throughput row printer shared by the bench modules.

const std = @import("std");

pub fn report(
    label: []const u8,
    elapsed_ns: f64,
    decoded_frames: f64,
    rate: u32,
    channel_count: u16,
    target: f64,
    files: ?usize,
) !void {
    const elapsed_s = elapsed_ns / std.time.ns_per_s;
    const audio_s = decoded_frames / @as(f64, @floatFromInt(rate));
    const pcm_bytes = decoded_frames * @as(f64, @floatFromInt(channel_count)) * 2;
    const mb_per_s = pcm_bytes / (1024.0 * 1024.0) / elapsed_s;
    const speedup = audio_s / elapsed_s;

    if (files) |count| {
        std.debug.print(
            "zig-audio bench: {s} {d} Hz, {d} ch, {d:.1} s ({d:.0} frames from {d} files)\n",
            .{ label, rate, channel_count, audio_s, decoded_frames, count },
        );
    } else {
        std.debug.print(
            "zig-audio bench: {s} {d} Hz, {d} ch, {d:.1} s ({d:.0} frames)\n",
            .{ label, rate, channel_count, audio_s, decoded_frames },
        );
    }
    std.debug.print(
        "decoded in {d:.3} ms  =>  {d:.1} MiB/s (PCM out), {d:.0}x realtime\n",
        .{ elapsed_ns / std.time.ns_per_ms, mb_per_s, speedup },
    );

    if (speedup < target) {
        std.debug.print(
            "FAIL: {d:.1}x realtime is below the {d:.0}x target\n",
            .{ speedup, target },
        );
        return error.BelowThroughputTarget;
    }
    std.debug.print("OK: above the {d:.0}x realtime target\n", .{target});
}
