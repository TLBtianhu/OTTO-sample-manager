//! 有界播放源的真文件 seek：向前、向后、跨窗口都与整段解码逐字节一致。
const std = @import("std");
const decode = @import("decode.zig");
const pcm_source = @import("pcm_source.zig");
const budget = @import("../mem_budget.zig");

test "bounded source：窗口外 seek 不丢帧且驻留有界" {
    const path = "C:\\src\\otto-testkit\\samples\\tone_660.flac";
    std.Io.Dir.cwd().access(std.testing.io, path, .{}) catch return error.SkipZigTest;
    var reference = try decode.decode(std.testing.allocator, path, .{});
    defer reference.deinit(std.testing.allocator);
    const initial = try std.testing.allocator.dupe(u8, reference.pcm[0..4096]);
    const source = pcm_source.createNative(std.testing.allocator, path, .{}, reference.channels, reference.frames, initial) catch |err| {
        std.testing.allocator.free(initial);
        return err;
    };
    defer pcm_source.destroyBoxed(source, std.testing.allocator);

    const block_align = @as(usize, reference.channels) * 2;
    const frames = [_]u64{ 50_000, 100, 60_000, 0, 32_768 };
    var actual: [4096]u8 = undefined;
    for (frames) |frame| {
        const bytes = @min(actual.len, reference.pcm.len - @as(usize, @intCast(frame * block_align)));
        const rounded = bytes / block_align * block_align;
        try source.read(frame, actual[0..rounded]);
        const offset: usize = @intCast(frame * block_align);
        try std.testing.expectEqualSlices(u8, reference.pcm[offset..][0..rounded], actual[0..rounded]);
        try std.testing.expect(source.residentBytes() <= budget.bounded_window_bytes + 80 * 1024);
    }
    try std.testing.expectError(error.EndOfStream, source.read(reference.frames, actual[0..block_align]));
}
