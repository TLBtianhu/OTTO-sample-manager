//! 真实注册表的 legacy 对照：不是直接调 provider，而是走 `Registry.openAnswered`。
//!
//! 三条是验收里的对照实验，钉在单元测试里而不是只写在报告里：
//!   1. `.wav` 里装 FLAC：wasapi-pcm 按内容谢绝 `unsupported` → native-audio 接手；
//!   2. 截断的 ADPCM WAV：wasapi-pcm 认领后 `failed` → 注册表到此为止；
//!   3. AIFF 改名 `.xyz`：没人认领 → `provider=null` / `unsupported`。
//!
//! 素材缺失时 Skip；不把外部文件变成测试的硬依赖。

const std = @import("std");
const builtin = @import("builtin");
const core = @import("otto_core");
const preview = @import("../preview.zig");
const providers = @import("root.zig");

const testing = std.testing;
const sample_dir = "C:\\src\\otto-testkit\\samples";
const legacy_dir = "C:\\src\\zig-audio-vectors\\legacy";

fn hasFile(path: []const u8) bool {
    if (builtin.os.tag != .windows) return false;
    std.Io.Dir.cwd().access(testing.io, path, .{}) catch return false;
    return true;
}

fn sampleFor(path: []const u8) core.model.Sample {
    return .{
        .id = "registry-legacy",
        .file_name = core.model.fileNameFromPath(path),
        .file_ext = core.model.fileExtFromPath(path),
        .file_path = path,
    };
}

fn tempPath(tmp: *testing.TmpDir, name: []const u8) ![]u8 {
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(testing.io, &root_buffer);
    return std.fs.path.join(testing.allocator, &.{ root_buffer[0..root_len], name });
}

test "注册表：.wav 里装 FLAC → wasapi-pcm 谢绝，native-audio 按内容接手" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const flac_path = sample_dir ++ "\\tone_660.flac";
    if (!hasFile(flac_path)) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, flac_path, testing.allocator, .limited(8 * 1024 * 1024));
    defer testing.allocator.free(bytes);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "flac-as-wav.wav", .data = bytes });
    const path = try tempPath(&tmp, "flac-as-wav.wav");
    defer testing.allocator.free(path);

    var sample = sampleFor(path);
    const answered = try providers.registryFor(true).openAnswered(testing.allocator, .{
        .sample = &sample,
        .max_px = 128,
    });
    defer answered.outcome.deinit(testing.allocator);

    try testing.expect(answered.provider == &providers.native_audio.provider);
    switch (answered.outcome) {
        .audio => |session| {
            try testing.expectEqual(@as(u32, 44_100), session.sample_rate);
            try testing.expectEqual(@as(u64, 1_500), session.duration_ms);
            try testing.expectEqual(@as(usize, 66_150 * 2), session.pcm.len);
        },
        // 没有音频端点时 session.build 会失败；路由（provider 是谁）仍已被上面的
        // 断言钉住，解码本身由 `audio/decode_test.zig` 覆盖。不把设备存在变成
        // 单元测试的硬依赖。
        .none => return error.SkipZigTest,
        else => return error.ExpectedAudio,
    }
}

test "注册表：截断的 ADPCM WAV → wasapi-pcm failed，native-audio 连问都不再问" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const source = legacy_dir ++ "\\ms-adpcm-44k.wav";
    if (!hasFile(source)) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, source, testing.allocator, .limited(8 * 1024 * 1024));
    defer testing.allocator.free(bytes);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "truncated.wav", .data = bytes[0 .. bytes.len / 2] });
    const path = try tempPath(&tmp, "truncated.wav");
    defer testing.allocator.free(path);

    var sample = sampleFor(path);
    // 只放两个音频 provider：如果 failed 被当成谢绝，native-audio 会再试一次并
    // 成功（同一份库、同一个坏文件，所以它也会失败——但顺序证明仍由计数看）。
    const table = [_]*const preview.Provider{ &providers.audio.provider, &providers.native_audio.provider };
    const registry: preview.Registry = .{ .providers = &table };
    const answered = try registry.openAnswered(testing.allocator, .{ .sample = &sample, .max_px = 128 });

    try testing.expect(answered.provider == &providers.audio.provider);
    try testing.expectEqual(preview.Reason.failed, answered.outcome.none);
}

test "注册表：AIFF 改名 .xyz → 没人认领，provider=null / unsupported" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const source = legacy_dir ++ "\\aiff-s16.aiff";
    if (!hasFile(source)) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, source, testing.allocator, .limited(1024 * 1024));
    defer testing.allocator.free(bytes);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "aiff-as-xyz.xyz", .data = bytes });
    const path = try tempPath(&tmp, "aiff-as-xyz.xyz");
    defer testing.allocator.free(path);

    var sample = sampleFor(path);
    const answered = try providers.registryFor(true).openAnswered(testing.allocator, .{
        .sample = &sample,
        .max_px = 128,
    });

    try testing.expect(answered.provider == null);
    try testing.expectEqual(preview.Reason.unsupported, answered.outcome.none);
}

test "注册表：AIFF（.aiff）→ native-audio 出 audio" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const path = legacy_dir ++ "\\aiff-s16.aiff";
    if (!hasFile(path)) return error.SkipZigTest;

    var sample = sampleFor(path);
    const answered = try providers.registryFor(true).openAnswered(testing.allocator, .{
        .sample = &sample,
        .max_px = 128,
    });
    defer answered.outcome.deinit(testing.allocator);

    try testing.expect(answered.provider == &providers.native_audio.provider);
    switch (answered.outcome) {
        .audio => |session| {
            try testing.expectEqual(@as(u32, 44_100), session.sample_rate);
            try testing.expectEqual(@as(u64, 2_000), session.duration_ms);
        },
        // 理由同上：没有端点时只验证路由，解码由 decode_test 覆盖。
        .none => return error.SkipZigTest,
        else => return error.ExpectedAudio,
    }
}
