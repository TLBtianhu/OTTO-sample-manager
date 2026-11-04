const std = @import("std");
const core = @import("otto_core");
const library_io = @import("library_io.zig");
const library_session = @import("library_session.zig");
const testing = std.testing;

fn sessionFromFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    root: []const u8,
    force_watch: bool,
) !library_session.LibrarySession {
    var session = try library_session.LibrarySession.init(allocator, testing.io, path, false);
    errdefer session.deinit();
    const initial = try library_io.loadWith(testing.io, allocator, path);
    session.adoptInitial(initial);
    try session.startLive(root, force_watch);
    return session;
}

fn pathIn(allocator: std.mem.Allocator, tmp: anytype, name: []const u8) ![]u8 {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(testing.io, &buffer);
    return std.fs.path.join(allocator, &.{ buffer[0..len], name });
}

test "重载失败：旧 Library/Live 指针、路径与可轮询视图全部保留" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "old.json",
        .data = "{\"samples\":{\"old\":{\"id\":\"old\",\"fileName\":\"old.wav\"}}}",
    });
    const old_path = try pathIn(testing.allocator, &tmp, "old.json");
    defer testing.allocator.free(old_path);
    const missing_path = try pathIn(testing.allocator, &tmp, "missing.otto");
    defer testing.allocator.free(missing_path);
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(testing.io, &root_buffer);

    var session = try sessionFromFile(testing.allocator, old_path, root_buffer[0..root_len], false);
    defer session.deinit();
    const old_library = session.library();
    const old_live = session.live();

    try testing.expectError(error.FileNotFound, session.reloadSaved(missing_path));
    try testing.expect(old_library == session.library());
    try testing.expect(old_live == session.live());
    try testing.expectEqualStrings(old_path, session.path());
    try testing.expectEqual(@as(usize, 1), old_library.samples.len);
    try testing.expectEqualStrings("old", old_live.samples()[0].id);
    const report = try old_live.poll();
    try testing.expectEqual(@as(usize, 0), report.added);
    try testing.expectEqual(@as(usize, 1), old_live.samples().len);
}

/// 只记录指定堆对象的 destroy 次数；其内部分配仍委托 testing.allocator，
/// 因此重复 deinit 导致的二次释放也会直接被测试分配器抓住。
const ReleaseTracker = struct {
    child: std.mem.Allocator,
    library_address: usize = 0,
    live_address: usize = 0,
    library_frees: usize = 0,
    live_frees: usize = 0,

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn allocator(self: *ReleaseTracker) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn track(self: *ReleaseTracker, library: *core.store.Library, live: anytype) void {
        self.library_address = @intFromPtr(library);
        self.live_address = @intFromPtr(live);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *ReleaseTracker = @ptrCast(@alignCast(ctx));
        return self.child.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *ReleaseTracker = @ptrCast(@alignCast(ctx));
        return self.child.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *ReleaseTracker = @ptrCast(@alignCast(ctx));
        return self.child.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *ReleaseTracker = @ptrCast(@alignCast(ctx));
        const address = @intFromPtr(memory.ptr);
        if (address == self.library_address) self.library_frees += 1;
        if (address == self.live_address) self.live_frees += 1;
        self.child.rawFree(memory, alignment, ret_addr);
    }
};

test "重载成功：旧对象各释放一次，路径更新且 root/watchForced 保留" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "old.json",
        .data = "{\"samples\":{\"old\":{\"id\":\"old\",\"fileName\":\"old.wav\"}}}",
    });
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "next.json",
        .data = "{\"samples\":{\"a\":{\"id\":\"a\",\"fileName\":\"a.wav\"},\"b\":{\"id\":\"b\",\"fileName\":\"b.wav\"}}}",
    });
    const old_path = try pathIn(testing.allocator, &tmp, "old.json");
    defer testing.allocator.free(old_path);
    const next_path = try pathIn(testing.allocator, &tmp, "next.json");
    defer testing.allocator.free(next_path);
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(testing.io, &root_buffer);

    var tracker: ReleaseTracker = .{ .child = testing.allocator };
    var session = try sessionFromFile(tracker.allocator(), old_path, root_buffer[0..root_len], true);
    var active = true;
    defer if (active) session.deinit();
    const old_library = session.library();
    const old_live = session.live();
    tracker.track(old_library, old_live);
    const expected_root = try testing.allocator.dupe(u8, old_live.root);
    defer testing.allocator.free(expected_root);
    const expected_forced = old_live.watchForced();
    try testing.expect(expected_forced);

    try session.reloadSaved(next_path);
    try testing.expect(old_library != session.library());
    try testing.expect(old_live != session.live());
    try testing.expectEqual(@as(usize, 1), tracker.library_frees);
    try testing.expectEqual(@as(usize, 1), tracker.live_frees);
    try testing.expectEqualStrings(next_path, session.path());
    try testing.expectEqual(@as(usize, 2), session.library().samples.len);
    try testing.expectEqual(@as(usize, 2), session.live().samples().len);
    try testing.expectEqualStrings(expected_root, session.live().root);
    try testing.expectEqual(expected_forced, session.live().watchForced());

    // session 收尾只能释放新对象，不能再次碰到旧对象。
    session.deinit();
    active = false;
    try testing.expectEqual(@as(usize, 1), tracker.library_frees);
    try testing.expectEqual(@as(usize, 1), tracker.live_frees);
}

test "浏览 session：空内存库且保存/重载 ReadOnly，库与源文件零写入" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const source_bytes = "source-must-not-change";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "source.wav", .data = source_bytes });
    const library_path = try pathIn(testing.allocator, &tmp, "browse.otto");
    defer testing.allocator.free(library_path);
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(testing.io, &root_buffer);

    var session = try library_session.LibrarySession.init(testing.allocator, testing.io, library_path, true);
    defer session.deinit();
    try session.startLive(root_buffer[0..root_len], true);
    try testing.expect(session.isReadOnly());
    try testing.expectEqual(@as(usize, 0), session.library().samples.len);
    try testing.expectEqual(@as(usize, 0), session.live().samples().len);
    try testing.expect(session.live().watcher == null);

    try testing.expectError(error.ReadOnly, session.save(library_path, session.library()));
    try testing.expectError(error.ReadOnly, session.reloadSaved(library_path));
    try testing.expectEqualStrings(library_path, session.path());
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, "browse.otto", .{}));
    const actual = try tmp.dir.readFileAlloc(testing.io, "source.wav", testing.allocator, .limited(1024));
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings(source_bytes, actual);
}
