const std = @import("std");
const core = @import("otto_core");
const import_cli = @import("import_cli.zig");
const library_io = @import("library_io.zig");
const live_mod = @import("live.zig");
const scan_mod = @import("otto_scan");
const providers = @import("providers/root.zig");
const Panel = @import("preview_panel.zig").Panel;
const testing = std.testing;

fn idForPath(samples: []const core.model.Sample, suffix: []const u8) []const u8 {
    for (samples) |sample| {
        if (std.mem.endsWith(u8, sample.file_path, suffix)) return sample.id;
    }
    return "";
}

fn waitForRescan(live: *live_mod.Live) !void {
    const serial = live.rescanSerial();
    const deadline = std.Io.Timestamp.now(testing.io, .awake).addDuration(.{ .nanoseconds = 8 * std.time.ns_per_s });
    while (live.rescanSerial() == serial) {
        _ = try live.poll();
        if (std.Io.Timestamp.now(testing.io, .awake).nanoseconds >= deadline.nanoseconds) return error.TestTimeout;
        try std.Io.sleep(testing.io, std.Io.Duration.fromMilliseconds(5), .awake);
    }
}

fn expectCleanRescan(live: *live_mod.Live, expected_samples: usize) !void {
    live.requestRescan();
    try waitForRescan(live);
    const report = live.lastRescan();
    try testing.expect(report.ok);
    try testing.expectEqual(@as(usize, 0), report.added);
    try testing.expectEqual(@as(usize, 0), report.removed);
    try testing.expectEqual(@as(usize, 0), report.moved);
    try testing.expectEqual(@as(usize, 0), report.modified);
    try testing.expectEqual(expected_samples, report.unchanged);
    try testing.expectEqual(expected_samples, live.samples().len);
}

test "多选与目录移除：真实重扫不复活，源文件逐字节不变" {
    var source = testing.tmpDir(.{});
    defer source.cleanup();
    try source.dir.createDirPath(testing.io, "root/sub/deep");
    try source.dir.createDirPath(testing.io, "other");
    const names = [_][]const u8{ "root/a.wav", "root/sub/b.wav", "root/sub/deep/c.wav", "other/keep.wav" };
    const contents = [_][]const u8{ "alpha\x00\x01", "bravo\x02\x03", "charlie\x04\x05", "keep\x06\x07" };
    for (names, contents) |name, data| try source.dir.writeFile(testing.io, .{ .sub_path = name, .data = data });
    var before: [4][]u8 = undefined;
    for (names, 0..) |name, index| before[index] = try source.dir.readFileAlloc(testing.io, name, testing.allocator, .limited(1024));
    defer for (&before) |bytes| testing.allocator.free(bytes);

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try source.dir.realPath(testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    var scan = try scan_mod.run(testing.allocator, testing.io, root, .{}, null);
    defer scan.deinit();
    var base = try core.store.empty(testing.allocator);
    defer base.deinit();
    var samples: std.ArrayList(core.model.Sample) = .empty;
    defer samples.deinit(testing.allocator);
    var ids: [4][32]u8 = undefined;
    for (scan.files, 0..) |fact, index| {
        const id = try std.fmt.bufPrint(&ids[index], "base-{d}", .{index});
        try samples.append(testing.allocator, .{
            .id = id,
            .file_name = core.model.fileNameFromPath(fact.path),
            .file_ext = fact.ext,
            .file_path = fact.path,
            .file_size = fact.size,
            .mtime = fact.mtime,
            .identity = if (fact.identity) |value| .{ .volume_serial = value.volume_serial, .file_index = value.file_index } else null,
        });
    }
    _ = try base.appendSamples(samples.items);

    var library_dir = testing.tmpDir(.{});
    defer library_dir.cleanup();
    var library_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const library_len = try library_dir.dir.realPath(testing.io, &library_buffer);
    const library_path = try std.fs.path.join(testing.allocator, &.{ library_buffer[0..library_len], "library.otto" });
    defer testing.allocator.free(library_path);

    // 多选按 id，故意先选后面的 root/a，再选前面的 other/keep。
    var multi = try core.removal.apply(testing.allocator, &base, &.{
        .{ .sample_id = idForPath(base.samples, "a.wav") },
        .{ .sample_id = idForPath(base.samples, "keep.wav") },
    });
    defer multi.deinit();
    try testing.expectEqual(@as(usize, 2), multi.report.samples);
    _ = try library_io.saveWith(testing.io, testing.allocator, library_path, &multi.library);
    var restarted = try library_io.loadWith(testing.io, testing.allocator, library_path);
    defer restarted.deinit();
    try testing.expectEqual(@as(usize, 2), restarted.samples.len);
    try testing.expectEqual(@as(usize, 2), restarted.exclusions.len);
    {
        var live = try live_mod.Live.init(testing.allocator, testing.io, &restarted, root, true);
        defer live.deinit();
        try expectCleanRescan(&live, 2);
    }

    const folder = try std.fs.path.join(testing.allocator, &.{ root, "root", "sub" });
    defer testing.allocator.free(folder);
    var folder_removed = try core.removal.apply(testing.allocator, &restarted, &.{.{ .folder_path = folder }});
    defer folder_removed.deinit();
    try testing.expectEqual(@as(usize, 2), folder_removed.report.samples);
    _ = try library_io.saveWith(testing.io, testing.allocator, library_path, &folder_removed.library);
    var restarted_folder = try library_io.loadWith(testing.io, testing.allocator, library_path);
    defer restarted_folder.deinit();
    try testing.expectEqual(@as(usize, 0), restarted_folder.samples.len);
    try testing.expectEqual(@as(usize, 3), restarted_folder.exclusions.len);
    {
        var live = try live_mod.Live.init(testing.allocator, testing.io, &restarted_folder, root, true);
        defer live.deinit();
        try expectCleanRescan(&live, 0);
    }

    // 显式重新导入是恢复意图：清 2 个文件墓碑 + 1 个目录墓碑并恢复 4 条；
    // 这与上面的自动重扫 added=0 是同一条边界的一体两面。
    const restored = try import_cli.importRun(testing.allocator, testing.io, root, library_path, library_path);
    try testing.expect(restored.failure == null);
    try testing.expectEqual(@as(usize, 4), restored.added);
    try testing.expectEqual(@as(usize, 3), restored.restored_exclusions);
    var restored_library = try library_io.loadWith(testing.io, testing.allocator, library_path);
    defer restored_library.deinit();
    try testing.expectEqual(@as(usize, 4), restored_library.samples.len);
    try testing.expectEqual(@as(usize, 0), restored_library.exclusions.len);
    {
        var live = try live_mod.Live.init(testing.allocator, testing.io, &restored_library, root, true);
        defer live.deinit();
        try expectCleanRescan(&live, 4);
    }

    for (names, contents, before) |name, expected, original| {
        const actual = try source.dir.readFileAlloc(testing.io, name, testing.allocator, .limited(1024));
        defer testing.allocator.free(actual);
        try testing.expectEqualSlices(u8, expected, original);
        try testing.expectEqualSlices(u8, original, actual);
    }
}

test "当前预览被移除：清空事实与播放意图，旧结果不落回" {
    const path = "C:\\src\\otto-testkit\\samples\\tone_440.wav";
    std.Io.Dir.cwd().access(testing.io, path, .{}) catch return error.SkipZigTest;
    const registry = providers.registryFor(false);
    const panel = try Panel.init(testing.allocator, testing.io, registry, .{});
    defer panel.deinit();
    const sample = core.model.Sample{
        .id = "removed-preview",
        .file_name = "tone_440",
        .file_ext = ".wav",
        .file_path = path,
    };
    panel.sync(&sample, .{});
    var attempts: usize = 0;
    while (panel.current == null and attempts < 400) : (attempts += 1) {
        _ = panel.poll();
        try std.Io.sleep(testing.io, std.Io.Duration.fromMilliseconds(5), .awake);
    }
    try testing.expect(panel.current != null);
    _ = panel.playCurrent(); // 有端点时真播；无端点时也覆盖启动/失败状态的安全清理。
    panel.sync(null, .{});
    try testing.expect(panel.current == null);
    try testing.expect(panel.requested_path == null);
    try testing.expect(panel.facts == null);
    try testing.expect(!panel.pending);
    try testing.expect(!panel.wants_play);
    try testing.expect(!panel.isPlaying());
    _ = panel.poll();
    try testing.expect(panel.current == null);
}
