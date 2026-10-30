//! 可变索引层（`index.zig`）的集成测试。
//!
//! 用两个 fixture 驱动：
//!   * `subfolders.json`（既有）：5 条样本、没有身份，覆盖 created / overflow /
//!     混合批次 / 降级与忽略规则；
//!   * `index_events.json`（新增）：3 条**带身份**的样本，覆盖 renamed 保身份、
//!     removed 不动注释表、modified 的 invalidated 键。
//!
//! 所有断言都只用 `std.testing.allocator`：Index 自己持有的字符串有泄漏就会报错。

const std = @import("std");
const fixtures = @import("fixtures");
const model = @import("model.zig");
const store = @import("store.zig");
const annotations = @import("annotations.zig");
const index = @import("index.zig");

const Change = index.Change;

fn expectIds(expected: []const []const u8, samples: []const model.Sample) !void {
    try std.testing.expectEqual(expected.len, samples.len);
    for (expected, 0..) |id, position| {
        try std.testing.expectEqualStrings(id, samples[position].id);
    }
}

fn loadIndexEvents() !store.Library {
    return store.load(std.testing.allocator, fixtures.index_events);
}

fn loadSubfolders() !store.Library {
    return store.load(std.testing.allocator, fixtures.subfolders);
}

test "created：追加到末尾，派生名正确，不查磁盘" {
    var library = try loadSubfolders();
    defer library.deinit();
    const before = library.samples.len;

    var view = try index.Index.init(std.testing.allocator, &library);
    defer view.deinit();
    try expectIds(&.{ "s_root", "s_a", "s_a1", "s_b", "s_cn" }, view.samples());

    const report = try view.apply(&.{.{ .created = "D:/new/Crash 01.wav" }});
    try std.testing.expectEqual(@as(usize, 1), report.added);
    try std.testing.expectEqual(@as(usize, 0), report.removed);
    try std.testing.expectEqual(@as(usize, 0), report.renamed);
    try std.testing.expectEqual(@as(usize, 0), report.modified);
    try std.testing.expect(!report.overflowed);
    try std.testing.expectEqual(@as(usize, 0), report.invalidated.len);

    // 原顺序一个不动，新样本在末尾。
    try std.testing.expectEqual(before + 1, view.samples().len);
    for (library.samples, 0..) |original, position| {
        const current = view.samples()[position];
        try std.testing.expectEqualStrings(original.id, current.id);
        try std.testing.expectEqualStrings(original.file_path, current.file_path);
    }

    const added = view.samples()[before];
    try std.testing.expectEqualStrings("D:/new/Crash 01.wav", added.file_path);
    try std.testing.expectEqualStrings("Crash 01", added.file_name);
    try std.testing.expectEqualStrings(".wav", added.file_ext);
    try std.testing.expect(added.identity == null);
    try std.testing.expect(added.pending_metadata);
    try std.testing.expectEqual(@as(i64, 0), added.imported_at);
    try std.testing.expectEqual(@as(i64, 0), added.mtime);
    try std.testing.expectEqual(@as(u64, 0), added.file_size);
    try std.testing.expect(!added.is_copy);
    try std.testing.expectEqual(@as(usize, 0), added.group_ids.len);
    try std.testing.expect(added.folder_id == null);
    try std.testing.expectEqualStrings(added.id, added.original_id);
    try std.testing.expect(added.id.len > 0);
    // 合成 id 不能撞上库里的 id。
    try std.testing.expect(library.sampleById(added.id) == null);

    // 真源没有被改。
    try std.testing.expectEqual(before, library.samples.len);
}

test "removed：从视图消失，同一身份的注释仍在表里" {
    var library = try loadIndexEvents();
    defer library.deinit();

    var table = annotations.AnnotationTable.init(std.testing.allocator);
    defer table.deinit();

    var view = try index.Index.init(std.testing.allocator, &library);
    defer view.deinit();

    const snare = library.sampleById("snare").?;
    const snare_key = snare.stableKey();
    try std.testing.expect(snare_key.isIdentity());
    try table.put(snare_key, .{ .group_ids = &.{"drums"}, .tags = &.{"keep"}, .rating = 5 });

    const report = try view.apply(&.{.{ .removed = "D:/packs/Snare.wav" }});
    try std.testing.expectEqual(@as(usize, 1), report.removed);
    try std.testing.expectEqual(@as(usize, 0), report.added);
    try std.testing.expectEqual(@as(usize, 2), view.samples().len);
    // 删除不留空洞：后面的样本整体前移。
    try expectIds(&.{ "kick", "hat" }, view.samples());

    // 注释键在身份上：删文件不删用户标签。
    try std.testing.expectEqual(@as(usize, 1), table.count());
    const kept = table.get(snare_key) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("drums", kept.group_ids[0]);
    try std.testing.expectEqualStrings("keep", kept.tags[0]);
    try std.testing.expectEqual(@as(u8, 5), kept.rating);

    // 再删同一条：找不到，什么都不做。
    const again = try view.apply(&.{.{ .removed = "D:/packs/Snare.wav" }});
    try std.testing.expectEqual(@as(usize, 0), again.removed);
    try std.testing.expectEqual(@as(usize, 2), view.samples().len);
}

test "renamed：路径与派生名变了，身份 / 顺序 / stableKey 不变" {
    var library = try loadIndexEvents();
    defer library.deinit();

    var table = annotations.AnnotationTable.init(std.testing.allocator);
    defer table.deinit();

    var view = try index.Index.init(std.testing.allocator, &library);
    defer view.deinit();

    const before = library.sampleById("snare").?;
    const before_key = before.stableKey();
    try table.put(before_key, .{ .tags = &.{"kept"} });

    const report = try view.apply(&.{.{ .renamed = .{
        .from = "D:/packs/Snare.wav",
        .to = "E:/archive/Snare 02.wav",
    } }});
    try std.testing.expectEqual(@as(usize, 1), report.renamed);
    try std.testing.expectEqual(@as(usize, 0), report.added);
    try std.testing.expectEqual(@as(usize, 0), report.removed);
    try std.testing.expectEqual(@as(usize, 0), report.modified);

    // 顺序不变：仍在中间。
    try expectIds(&.{ "kick", "snare", "hat" }, view.samples());
    const moved = view.samples()[1];
    try std.testing.expectEqualStrings("E:/archive/Snare 02.wav", moved.file_path);
    try std.testing.expectEqualStrings("Snare 02", moved.file_name);
    try std.testing.expectEqualStrings(".wav", moved.file_ext);
    // id / 身份 / 目录 / 元数据状态都还是原来那条样本的。
    try std.testing.expectEqualStrings("snare", moved.id);
    try std.testing.expect(moved.identity.?.eql(before.identity.?));
    try std.testing.expectEqualStrings("folder_packs", moved.folder_id.?);
    try std.testing.expect(!moved.pending_metadata);
    try std.testing.expectEqual(@as(i64, 0), moved.mtime);

    // stableKey 仍指向同一身份：改名不丢注释。
    try std.testing.expect(moved.stableKey().eql(before_key));
    try std.testing.expectEqual(before_key.hash(), moved.stableKey().hash());
    try std.testing.expectEqualStrings("kept", table.get(moved.stableKey()).?.tags[0]);

    // 真源仍是旧路径。
    try std.testing.expectEqualStrings("D:/packs/Snare.wav", library.sampleById("snare").?.file_path);
}

test "modified：invalidated 给出更新前的 StableKey，mtime 一并更新" {
    var library = try loadIndexEvents();
    defer library.deinit();

    var view = try index.Index.init(std.testing.allocator, &library);
    defer view.deinit();

    const hat = library.sampleById("hat").?;
    const hat_key = hat.stableKey();
    const new_mtime: i64 = 1_700_000_999_000;

    const report = try view.apply(&.{.{ .modified = .{
        .path = "D:/packs/Hat.wav",
        .mtime = new_mtime,
    } }});
    try std.testing.expectEqual(@as(usize, 1), report.modified);
    try std.testing.expectEqual(@as(usize, 1), report.invalidated.len);
    try std.testing.expect(report.invalidated[0].eql(hat_key));
    try std.testing.expectEqual(new_mtime, view.samples()[2].mtime);
    // 真源不动。
    try std.testing.expectEqual(@as(i64, 0), hat.mtime);

    // 未知路径：忽略。
    const missing = try view.apply(&.{.{ .modified = .{ .path = "D:/packs/Ghost.wav" } }});
    try std.testing.expectEqual(@as(usize, 0), missing.modified);
    try std.testing.expectEqual(@as(usize, 0), missing.invalidated.len);

    // 没有身份的样本：按退化键作废，且用的是**更新前**的 mtime。
    _ = try view.apply(&.{.{ .created = "D:/tmp/Tom.wav" }});
    const created_position = view.samples().len - 1;
    const fallback_key = view.samples()[created_position].stableKey();
    const fallback_report = try view.apply(&.{.{ .modified = .{
        .path = "D:/tmp/Tom.wav",
        .mtime = 5_000,
    } }});
    try std.testing.expectEqual(@as(usize, 1), fallback_report.modified);
    try std.testing.expectEqual(@as(usize, 1), fallback_report.invalidated.len);
    try std.testing.expect(fallback_report.invalidated[0].eql(fallback_key));
    switch (fallback_report.invalidated[0]) {
        .fallback => |fallback| {
            try std.testing.expectEqualStrings("D:/tmp/Tom.wav", fallback.path);
            try std.testing.expectEqual(@as(i64, 0), fallback.mtime);
        },
        .identity => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(i64, 5_000), view.samples()[created_position].mtime);
}

test "overflow：置脏，后续事件照常应用，clearDirty 恢复" {
    var library = try loadSubfolders();
    defer library.deinit();

    var view = try index.Index.init(std.testing.allocator, &library);
    defer view.deinit();

    const report = try view.apply(&.{.{ .overflow = 7 }});
    try std.testing.expect(report.overflowed);
    try std.testing.expectEqual(@as(u32, 7), report.overflow_lost);
    try std.testing.expectEqual(@as(usize, 0), report.added + report.removed + report.renamed + report.modified);
    try std.testing.expect(view.isDirty());
    try std.testing.expectEqual(@as(usize, 5), view.samples().len);

    // 脏视图继续应用后续事件：每条事件本身仍是有效事实。
    const after = try view.apply(&.{.{ .created = "D:/lib/B/Clap.wav" }});
    try std.testing.expectEqual(@as(usize, 1), after.added);
    try std.testing.expectEqual(@as(usize, 6), view.samples().len);
    try std.testing.expect(view.isDirty());

    // 条数未知（0）同样是 overflow。
    const unknown = try view.apply(&.{.{ .overflow = 0 }});
    try std.testing.expect(unknown.overflowed);
    try std.testing.expectEqual(@as(u32, 0), unknown.overflow_lost);
    try std.testing.expect(view.isDirty());

    view.clearDirty();
    try std.testing.expect(!view.isDirty());

    const resumed = try view.apply(&.{.{ .removed = "D:/lib/B/Clap.wav" }});
    try std.testing.expectEqual(@as(usize, 1), resumed.removed);
    try std.testing.expectEqual(@as(usize, 5), view.samples().len);
    try std.testing.expect(!view.isDirty());

    // 空批次：空报告，不动视图，也不把脏标记加回来。
    const empty = try view.apply(&.{});
    try std.testing.expectEqual(@as(usize, 0), empty.added + empty.removed + empty.renamed + empty.modified);
    try std.testing.expect(!empty.overflowed);
    try std.testing.expectEqual(@as(usize, 0), empty.invalidated.len);
    try std.testing.expectEqual(@as(usize, 5), view.samples().len);
}

test "混合批次：按到达顺序生效，计数与顺序正确" {
    var library = try loadSubfolders();
    defer library.deinit();

    var view = try index.Index.init(std.testing.allocator, &library);
    defer view.deinit();

    const changes = [_]Change{
        .{ .created = "D:/lib/B/Clap 01.wav" },
        .{ .removed = "D:/lib/A/Deep/Snare A1.wav" },
        .{ .renamed = .{ .from = "D:/lib/B/Bass B.wav", .to = "D:/lib/B/Bass B 02.wav" } },
        .{ .modified = .{ .path = "D:/lib/B/鼓组 循环 01.wav", .mtime = 42 } },
    };
    const report = try view.apply(&changes);
    try std.testing.expectEqual(@as(usize, 1), report.added);
    try std.testing.expectEqual(@as(usize, 1), report.removed);
    try std.testing.expectEqual(@as(usize, 1), report.renamed);
    try std.testing.expectEqual(@as(usize, 1), report.modified);
    try std.testing.expect(!report.overflowed);

    try std.testing.expectEqual(@as(usize, 5), view.samples().len);
    const samples = view.samples();
    try std.testing.expectEqualStrings("s_root", samples[0].id);
    try std.testing.expectEqualStrings("s_a", samples[1].id);
    try std.testing.expectEqualStrings("s_b", samples[2].id);
    try std.testing.expectEqualStrings("D:/lib/B/Bass B 02.wav", samples[2].file_path);
    try std.testing.expectEqualStrings("Bass B 02", samples[2].file_name);
    try std.testing.expectEqualStrings("f_b", samples[2].folder_id.?);
    try std.testing.expectEqualStrings("s_cn", samples[3].id);
    try std.testing.expectEqual(@as(i64, 42), samples[3].mtime);
    try std.testing.expectEqualStrings("D:/lib/B/Clap 01.wav", samples[4].file_path);
    try std.testing.expect(samples[4].pending_metadata);

    // 作废键用的是修改前的退化键（store 不读 mtime，所以旧值是 0）。
    try std.testing.expectEqual(@as(usize, 1), report.invalidated.len);
    switch (report.invalidated[0]) {
        .fallback => |fallback| {
            try std.testing.expectEqualStrings("D:/lib/B/鼓组 循环 01.wav", fallback.path);
            try std.testing.expectEqual(@as(i64, 0), fallback.mtime);
        },
        .identity => return error.TestUnexpectedResult,
    }

    // 真源一条都没动。
    try std.testing.expectEqual(@as(usize, 5), library.samples.len);
    try std.testing.expectEqualStrings("D:/lib/B/Bass B.wav", library.sampleById("s_b").?.file_path);
    try std.testing.expectEqual(@as(i64, 0), library.sampleById("s_cn").?.mtime);

    // 到达顺序：同一批里先 created 再 removed，两条都算，净效果为零。
    const churn = [_]Change{
        .{ .created = "D:/lib/B/Temp.wav" },
        .{ .removed = "D:/lib/B/Temp.wav" },
    };
    const churn_report = try view.apply(&churn);
    try std.testing.expectEqual(@as(usize, 1), churn_report.added);
    try std.testing.expectEqual(@as(usize, 1), churn_report.removed);
    try std.testing.expectEqual(@as(usize, 5), view.samples().len);
    for (view.samples()) |sample| {
        try std.testing.expect(!std.mem.eql(u8, sample.file_path, "D:/lib/B/Temp.wav"));
    }
}

test "renamed 找不到 from：降级为 created，renamed 不计数" {
    var library = try loadSubfolders();
    defer library.deinit();

    var view = try index.Index.init(std.testing.allocator, &library);
    defer view.deinit();

    const report = try view.apply(&.{.{ .renamed = .{
        .from = "D:/lib/Ghost.wav",
        .to = "D:/lib/Ghost 02.wav",
    } }});
    try std.testing.expectEqual(@as(usize, 0), report.renamed);
    try std.testing.expectEqual(@as(usize, 1), report.added);

    try std.testing.expectEqual(@as(usize, 6), view.samples().len);
    const added = view.samples()[5];
    try std.testing.expectEqualStrings("D:/lib/Ghost 02.wav", added.file_path);
    try std.testing.expectEqualStrings("Ghost 02", added.file_name);
    try std.testing.expect(added.identity == null);
    try std.testing.expect(added.pending_metadata);
    try std.testing.expectEqual(@as(i64, 0), added.imported_at);

    // 旧路径为空：同样没有可定位的来源 -> 按 created 处理。
    const from_empty = try view.apply(&.{.{ .renamed = .{
        .from = "",
        .to = "D:/lib/From Nothing.wav",
    } }});
    try std.testing.expectEqual(@as(usize, 0), from_empty.renamed);
    try std.testing.expectEqual(@as(usize, 1), from_empty.added);
    try std.testing.expectEqual(@as(usize, 7), view.samples().len);

    // 新路径为空：没有可插入的地址 -> 整条忽略。
    const to_empty = try view.apply(&.{.{ .renamed = .{
        .from = "D:/lib/Root Loop.wav",
        .to = "",
    } }});
    try std.testing.expectEqual(
        @as(usize, 0),
        to_empty.added + to_empty.removed + to_empty.renamed + to_empty.modified,
    );
    try std.testing.expectEqual(@as(usize, 7), view.samples().len);
}

test "重复 created 按 modified 处理，未知 / 空路径事件被忽略" {
    var library = try loadSubfolders();
    defer library.deinit();

    var view = try index.Index.init(std.testing.allocator, &library);
    defer view.deinit();

    const first = try view.apply(&.{.{ .created = "D:/lib/B/Clap.wav" }});
    try std.testing.expectEqual(@as(usize, 1), first.added);

    // 同一个路径再来一条 created：不产生第二条样本，按 modified 记账并作废缓存。
    const second = try view.apply(&.{.{ .created = "D:/lib/B/Clap.wav" }});
    try std.testing.expectEqual(@as(usize, 0), second.added);
    try std.testing.expectEqual(@as(usize, 1), second.modified);
    try std.testing.expectEqual(@as(usize, 1), second.invalidated.len);
    switch (second.invalidated[0]) {
        .fallback => |fallback| try std.testing.expectEqualStrings("D:/lib/B/Clap.wav", fallback.path),
        .identity => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(usize, 6), view.samples().len);

    // 未知路径的 removed / modified：忽略，不计数。
    const unknown = try view.apply(&.{
        .{ .removed = "D:/nope.wav" },
        .{ .modified = .{ .path = "D:/nope.wav" } },
    });
    try std.testing.expectEqual(@as(usize, 0), unknown.removed);
    try std.testing.expectEqual(@as(usize, 0), unknown.modified);
    try std.testing.expectEqual(@as(usize, 0), unknown.invalidated.len);

    // 空路径：路径是唯一键，空串什么都定位不了。
    const empty = try view.apply(&.{
        .{ .created = "" },
        .{ .removed = "" },
        .{ .modified = .{ .path = "" } },
    });
    try std.testing.expectEqual(
        @as(usize, 0),
        empty.added + empty.removed + empty.renamed + empty.modified,
    );
    try std.testing.expectEqual(@as(usize, 6), view.samples().len);
}

test "renamed 覆盖同名目标：陈旧条目按 removed 丢弃" {
    var library = try loadIndexEvents();
    defer library.deinit();

    var view = try index.Index.init(std.testing.allocator, &library);
    defer view.deinit();

    const report = try view.apply(&.{.{ .renamed = .{
        .from = "D:/packs/Snare.wav",
        .to = "D:/packs/Hat.wav",
    } }});
    try std.testing.expectEqual(@as(usize, 1), report.renamed);
    try std.testing.expectEqual(@as(usize, 1), report.removed);
    try std.testing.expectEqual(@as(usize, 0), report.added);

    // 一条路径只留一条样本：hat 的陈旧条目被丢掉，snare 占了它的位置。
    try std.testing.expectEqual(@as(usize, 2), view.samples().len);
    try expectIds(&.{ "kick", "snare" }, view.samples());
    const moved = view.samples()[1];
    try std.testing.expectEqualStrings("D:/packs/Hat.wav", moved.file_path);
    try std.testing.expectEqualStrings("Hat", moved.file_name);
    try std.testing.expectEqualStrings("snare", moved.id);
    try std.testing.expect(moved.stableKey().eql(library.sampleById("snare").?.stableKey()));
}

test "created 之后再 renamed：合成样本的路径跟着改名走" {
    var library = try loadSubfolders();
    defer library.deinit();

    var view = try index.Index.init(std.testing.allocator, &library);
    defer view.deinit();

    _ = try view.apply(&.{.{ .created = "D:/lib/B/Temp.wav" }});
    const created_id = view.samples()[5].id;

    const report = try view.apply(&.{.{ .renamed = .{
        .from = "D:/lib/B/Temp.wav",
        .to = "D:/lib/B/Temp 02.wav",
    } }});
    try std.testing.expectEqual(@as(usize, 1), report.renamed);
    try std.testing.expectEqual(@as(usize, 6), view.samples().len);

    const moved = view.samples()[5];
    try std.testing.expectEqualStrings(created_id, moved.id);
    try std.testing.expectEqualStrings("D:/lib/B/Temp 02.wav", moved.file_path);
    try std.testing.expectEqualStrings(".wav", moved.file_ext);
    try std.testing.expectEqualStrings("Temp 02", moved.file_name);
    try std.testing.expect(moved.pending_metadata);
    // 没有身份：退化键跟着路径走，改名之后就是另一个键（这是退化盘上的已知代价）。
    switch (moved.stableKey()) {
        .fallback => |fallback| try std.testing.expectEqualStrings("D:/lib/B/Temp 02.wav", fallback.path),
        .identity => return error.TestUnexpectedResult,
    }

    // 移除它：新路径与合成 id 都要被释放（testing allocator 会抓漏）。
    const removed = try view.apply(&.{.{ .removed = "D:/lib/B/Temp 02.wav" }});
    try std.testing.expectEqual(@as(usize, 1), removed.removed);
    try std.testing.expectEqual(@as(usize, 5), view.samples().len);
}

test "同一批里 modified 之后 removed：invalidated 里的路径不悬空" {
    var library = try loadIndexEvents();
    defer library.deinit();

    var view = try index.Index.init(std.testing.allocator, &library);
    defer view.deinit();

    const changes = [_]Change{
        .{ .created = "D:/tmp/Temp.wav" },
        .{ .modified = .{ .path = "D:/tmp/Temp.wav", .mtime = 7 } },
        .{ .removed = "D:/tmp/Temp.wav" },
    };
    const report = try view.apply(&changes);
    try std.testing.expectEqual(@as(usize, 1), report.added);
    try std.testing.expectEqual(@as(usize, 1), report.modified);
    try std.testing.expectEqual(@as(usize, 1), report.removed);

    // 作废键里的路径是 Index 的 arena 副本：样本已经删了，键仍然可读。
    try std.testing.expectEqual(@as(usize, 1), report.invalidated.len);
    switch (report.invalidated[0]) {
        .fallback => |fallback| {
            try std.testing.expectEqualStrings("D:/tmp/Temp.wav", fallback.path);
            try std.testing.expectEqual(@as(i64, 0), fallback.mtime);
        },
        .identity => return error.TestUnexpectedResult,
    }
    try expectIds(&.{ "kick", "snare", "hat" }, view.samples());
}
