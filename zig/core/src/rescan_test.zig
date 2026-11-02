//! `rescan.zig` 的差分测试（全部合成输入，不碰磁盘）+ `Index.applyRescan` 的
//! 应用测试（真 `Index`，断言视图、身份与新增样本的 L0 字段）。
//!
//! 覆盖任务要求的六类：新增、删除、改名（身份相同）、改内容（mtime / size）、
//! 完全不变、空到空；另外覆盖无身份盘只能按「删除 + 新增」看待的退化情况。

const std = @import("std");
const model = @import("model.zig");
const store = @import("store.zig");
const index_mod = @import("index.zig");
const rescan = @import("rescan.zig");
const testing = std.testing;

fn identity(volume: u32, file: u64) model.FileIdentity {
    return .{ .volume_serial = volume, .file_index = file };
}

fn sample(
    sample_id: []const u8,
    path: []const u8,
    size: u64,
    mtime: i64,
    file_identity: ?model.FileIdentity,
) model.Sample {
    return .{
        .id = sample_id,
        .file_name = model.fileNameFromPath(path),
        .file_ext = model.fileExtFromPath(path),
        .file_path = path,
        .file_size = size,
        .mtime = mtime,
        .identity = file_identity,
    };
}

fn entry(path: []const u8, size: u64, mtime: i64, file_identity: ?model.FileIdentity) rescan.ScanEntry {
    return .{
        .path = path,
        .name = model.baseName(path),
        .ext = model.fileExtFromPath(path),
        .size = size,
        .mtime = mtime,
        .identity = file_identity,
    };
}

test "新增：fresh 里多出来的路径进 added，按 fresh 顺序" {
    const old = [_]model.Sample{
        sample("a", "C:\\packs\\Kick.wav", 10, 100, identity(1, 1)),
        sample("b", "C:\\packs\\Snare.wav", 20, 200, identity(1, 2)),
    };
    const fresh = [_]rescan.ScanEntry{
        entry("C:\\packs\\Kick.wav", 10, 100, identity(1, 1)),
        entry("C:\\packs\\Snare.wav", 20, 200, identity(1, 2)),
        entry("C:\\packs\\Hat 01.wav", 30, 300, identity(1, 3)),
        entry("C:\\packs\\Hat 02.wav", 40, 400, identity(1, 4)),
    };

    var difference = try rescan.diff(testing.allocator, &old, &fresh);
    defer difference.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), difference.added.len);
    try testing.expectEqual(@as(usize, 2), difference.added[0].fresh);
    try testing.expectEqual(@as(usize, 3), difference.added[1].fresh);
    try testing.expect(difference.added[0].old == null);
    try testing.expectEqual(@as(usize, 0), difference.removed.len);
    try testing.expectEqual(@as(usize, 0), difference.modified.len);
    try testing.expectEqual(@as(usize, 0), difference.moved.len);
    try testing.expectEqual(@as(usize, 2), difference.unchanged);
}

test "删除：旧列表里没被配上的下标进 removed，升序" {
    const old = [_]model.Sample{
        sample("a", "C:\\packs\\Kick.wav", 10, 100, identity(1, 1)),
        sample("b", "C:\\packs\\Snare.wav", 20, 200, identity(1, 2)),
        sample("c", "C:\\packs\\Hat.wav", 30, 300, identity(1, 3)),
    };
    const fresh = [_]rescan.ScanEntry{
        entry("C:\\packs\\Kick.wav", 10, 100, identity(1, 1)),
        entry("C:\\packs\\Hat.wav", 30, 300, identity(1, 3)),
    };

    var difference = try rescan.diff(testing.allocator, &old, &fresh);
    defer difference.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), difference.removed.len);
    try testing.expectEqual(@as(usize, 1), difference.removed[0]);
    try testing.expectEqual(@as(usize, 0), difference.added.len);
    try testing.expectEqual(@as(usize, 2), difference.unchanged);
}

test "改名：身份相同、路径不同只进 moved，不算新增/删除" {
    const key = identity(7, 42);
    const old = [_]model.Sample{
        sample("a", "C:\\packs\\Old\\Snare.wav", 10, 100, key),
    };
    const fresh = [_]rescan.ScanEntry{
        entry("C:\\packs\\New\\Snare renamed.wav", 10, 100, key),
    };

    var difference = try rescan.diff(testing.allocator, &old, &fresh);
    defer difference.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), difference.added.len);
    try testing.expectEqual(@as(usize, 0), difference.removed.len);
    try testing.expectEqual(@as(usize, 0), difference.modified.len);
    try testing.expectEqual(@as(usize, 1), difference.moved.len);
    try testing.expectEqual(@as(usize, 0), difference.moved[0].old.?);
    try testing.expectEqual(@as(usize, 0), difference.moved[0].fresh);
    try testing.expectEqual(@as(usize, 0), difference.changed.len);
    try testing.expectEqual(@as(usize, 0), difference.unchanged);

    // 无身份盘：路径变了就没法证明是同一个文件，只能按「删除 + 新增」。
    const old_plain = [_]model.Sample{sample("p", "C:\\packs\\Old.wav", 10, 100, null)};
    const fresh_plain = [_]rescan.ScanEntry{entry("C:\\packs\\New.wav", 10, 100, null)};
    var plain = try rescan.diff(testing.allocator, &old_plain, &fresh_plain);
    defer plain.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), plain.added.len);
    try testing.expectEqual(@as(usize, 1), plain.removed.len);
    try testing.expectEqual(@as(usize, 0), plain.moved.len);
}

test "改内容：身份相同但 size / mtime 变了进 modified 与 changed" {
    const key = identity(7, 42);
    const old = [_]model.Sample{sample("a", "C:\\packs\\Kick.wav", 10, 100, key)};

    // size 变。
    const bigger = [_]rescan.ScanEntry{entry("C:\\packs\\Kick.wav", 20, 100, key)};
    var resized = try rescan.diff(testing.allocator, &old, &bigger);
    defer resized.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), resized.modified.len);
    try testing.expectEqual(@as(usize, 0), resized.modified[0]);
    try testing.expectEqual(@as(usize, 1), resized.changed.len);
    try testing.expectEqual(@as(usize, 0), resized.changed[0].old.?);
    try testing.expectEqual(@as(usize, 0), resized.moved.len);

    // mtime 变。
    const touched = [_]rescan.ScanEntry{entry("C:\\packs\\Kick.wav", 10, 999, key)};
    var rewritten = try rescan.diff(testing.allocator, &old, &touched);
    defer rewritten.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), rewritten.modified.len);
    try testing.expectEqual(@as(usize, 0), rewritten.added.len);
    try testing.expectEqual(@as(usize, 0), rewritten.removed.len);
}

test "完全不变：路径 / 大小 / mtime / 身份全一致只累计 unchanged" {
    const old = [_]model.Sample{
        sample("a", "C:\\packs\\Kick.wav", 10, 100, identity(1, 1)),
        sample("b", "C:\\packs\\Snare.wav", 20, 200, identity(1, 2)),
    };
    const fresh = [_]rescan.ScanEntry{
        entry("C:\\packs\\Snare.wav", 20, 200, identity(1, 2)),
        entry("C:\\packs\\Kick.wav", 10, 100, identity(1, 1)),
    };

    var difference = try rescan.diff(testing.allocator, &old, &fresh);
    defer difference.deinit(testing.allocator);

    try testing.expect(difference.isEmpty());
    try testing.expectEqual(@as(usize, 2), difference.unchanged);
    try testing.expectEqual(@as(usize, 0), difference.added.len);
    try testing.expectEqual(@as(usize, 0), difference.removed.len);
    try testing.expectEqual(@as(usize, 0), difference.modified.len);
    try testing.expectEqual(@as(usize, 0), difference.moved.len);
}

test "空到空：没有旧样本也没有新事实" {
    var difference = try rescan.diff(testing.allocator, &.{}, &.{});
    defer difference.deinit(testing.allocator);
    try testing.expect(difference.isEmpty());
    try testing.expectEqual(@as(usize, 0), difference.unchanged);

    // 边界：空列表 → 有文件（全是新增），有文件 → 空列表（全是删除）。
    const one = [_]rescan.ScanEntry{entry("C:\\packs\\Kick.wav", 10, 100, null)};
    var from_empty = try rescan.diff(testing.allocator, &.{}, &one);
    defer from_empty.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), from_empty.added.len);

    const old = [_]model.Sample{sample("a", "C:\\packs\\Kick.wav", 10, 100, null)};
    var to_empty = try rescan.diff(testing.allocator, &old, &.{});
    defer to_empty.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), to_empty.removed.len);
}

test "无身份时退回 路径+size+mtime：同路径可判修改，同路径同三元组算不变" {
    const old = [_]model.Sample{sample("a", "C:\\packs\\Kick.wav", 10, 100, null)};
    const same = [_]rescan.ScanEntry{entry("C:\\packs\\Kick.wav", 10, 100, null)};
    var untouched = try rescan.diff(testing.allocator, &old, &same);
    defer untouched.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), untouched.unchanged);

    const changed = [_]rescan.ScanEntry{entry("C:\\packs\\Kick.wav", 10, 101, null)};
    var modified = try rescan.diff(testing.allocator, &old, &changed);
    defer modified.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), modified.modified.len);
    try testing.expectEqual(@as(usize, 1), modified.changed.len);
}

test "身份未知 / pending_metadata 不制造假修改" {
    const key = identity(7, 42);
    var old = [_]model.Sample{sample("a", "C:\\packs\\Kick.wav", 10, 100, key)};
    old[0].pending_metadata = true; // L1 没读过，不是 L0 变了

    // 这一轮扫描拿不到身份（FAT / 网络盘 / 权限）：事实没变就是 unchanged，
    // 不能每次重扫都把同一条报成 modified。
    const without_identity = [_]rescan.ScanEntry{entry("C:\\packs\\Kick.wav", 10, 100, null)};
    var unknown = try rescan.diff(testing.allocator, &old, &without_identity);
    defer unknown.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), unknown.unchanged);
    try testing.expectEqual(@as(usize, 0), unknown.modified.len);

    // 反过来：旧样本没有身份、扫描补上了身份——要回填一次（modified）。
    const no_identity = [_]model.Sample{sample("a", "C:\\packs\\Kick.wav", 10, 100, null)};
    const with_identity = [_]rescan.ScanEntry{entry("C:\\packs\\Kick.wav", 10, 100, key)};
    var gained = try rescan.diff(testing.allocator, &no_identity, &with_identity);
    defer gained.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), gained.modified.len);
    try testing.expectEqual(@as(usize, 1), gained.changed.len);
}

test "applyRescan：更新 / 移动 / 删除 / 追加都落到视图，注释键不被碰" {
    var library = try store.empty(testing.allocator);
    defer library.deinit();

    const kick_key = identity(1, 1);
    const snare_key = identity(1, 2);
    const hat_key = identity(1, 3);
    const base = [_]model.Sample{
        sample("s_kick", "C:\\packs\\Kick.wav", 10, 100, kick_key),
        sample("s_snare", "C:\\packs\\Snare.wav", 20, 200, snare_key),
        sample("s_hat", "C:\\packs\\Hat.wav", 30, 300, hat_key),
    };
    _ = try library.appendSamples(&base);

    var view = try index_mod.Index.init(testing.allocator, &library);
    defer view.deinit();

    // Snare 改名（同身份）、Hat 改内容、Kick 删除、新增 Crash。
    const fresh = [_]rescan.ScanEntry{
        entry("C:\\packs\\Snare renamed.wav", 20, 200, snare_key),
        entry("C:\\packs\\Hat.wav", 31, 301, hat_key),
        entry("C:\\packs\\Crash.wav", 40, 400, identity(1, 4)),
    };
    var difference = try rescan.diff(testing.allocator, view.samples(), &fresh);
    defer difference.deinit(testing.allocator);

    const report = try view.applyRescan(difference, &fresh);
    try testing.expectEqual(@as(usize, 1), report.added);
    try testing.expectEqual(@as(usize, 1), report.removed);
    try testing.expectEqual(@as(usize, 1), report.moved);
    try testing.expectEqual(@as(usize, 1), report.modified);
    try testing.expectEqual(@as(usize, 0), report.unchanged);
    // Hat 改内容记一条旧键；Snare 是纯身份改名（键不变）不用作废；Kick 被删不在表里。
    try testing.expectEqual(@as(usize, 1), report.invalidated.len);

    try testing.expectEqual(@as(usize, 3), view.samples().len);
    // 顺序：Snare（下标 1，前移）+ Hat（下标 2，前移）+ 追加的 Crash。
    try testing.expectEqualStrings("s_snare", view.samples()[0].id);
    try testing.expectEqualStrings("C:\\packs\\Snare renamed.wav", view.samples()[0].file_path);
    try testing.expectEqualStrings("Snare renamed", view.samples()[0].file_name);
    try testing.expectEqualStrings("s_hat", view.samples()[1].id);
    try testing.expectEqual(@as(u64, 31), view.samples()[1].file_size);
    try testing.expectEqual(@as(i64, 301), view.samples()[1].mtime);
    try testing.expectEqualStrings("Crash", view.samples()[2].file_name);
    try testing.expectEqual(@as(u64, 40), view.samples()[2].file_size);
    try testing.expectEqual(@as(i64, 400), view.samples()[2].mtime);
    try testing.expect(view.samples()[2].identity.?.eql(identity(1, 4)));
    try testing.expect(view.samples()[2].pending_metadata);
    try testing.expect(view.samples()[2].id.len > 0);
    try testing.expect(library.sampleById(view.samples()[2].id) == null);
}
