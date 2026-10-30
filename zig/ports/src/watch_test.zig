//! 监听口岸测试：真文件系统 + 真 Win32，没有 mock。
//!
//! 规矩：所有等待都是「轮询 + 超时」（每步最多 2 秒、10ms 一次），不用固定 sleep
//! 假装事件已经到了；Windows 的变更通知本来就会合并、会延迟。
//! 每个用例用自己的 tmpDir，互不干扰；不创建窗口、不抢焦点。

const std = @import("std");
const watch = @import("watch.zig");
const win = @import("win_watch.zig");

const allocator = std.testing.allocator;
const io = std.testing.io;

const step_timeout_ms = 2000;
const poll_interval_ms = 10;
/// 吸收上一步的尾随事件（创建文件常带一条 MODIFIED），用静默窗口而不是固定等待。
const quiet_ms = 120;

// ---------------------------------------------------------------------------
// 装置
// ---------------------------------------------------------------------------

const Pump = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayList(watch.Event) = .empty,

    fn deinit(self: *Pump) void {
        self.events.deinit(self.allocator);
    }

    /// 轮询至多 timeout_ms，返回下一条事件（没有就 null）。
    fn pollFor(self: *Pump, watcher: *watch.Watcher, timeout_ms: i64) !?watch.Event {
        var one: [1]watch.Event = undefined;
        const started = std.Io.Clock.Timestamp.now(io, .awake);
        while (true) {
            if (watcher.poll(&one) == 1) {
                try self.events.append(self.allocator, one[0]);
                return one[0];
            }
            if (started.untilNow(io).raw.nanoseconds >= @as(i96, timeout_ms) * std.time.ns_per_ms) return null;
            try io.sleep(std.Io.Duration.fromMilliseconds(poll_interval_ms), .awake);
        }
    }

    /// 等到匹配 kind（可选 path）的事件；超时则打印已收事件后失败。
    fn expectKind(
        self: *Pump,
        watcher: *watch.Watcher,
        kind: watch.Kind,
        path: ?[]const u8,
        timeout_ms: i64,
    ) !watch.Event {
        const started = std.Io.Clock.Timestamp.now(io, .awake);
        while (true) {
            if (try self.pollFor(watcher, poll_interval_ms)) |event| {
                const path_ok = path == null or std.mem.eql(u8, event.path.slice(), path.?);
                if (event.kind == kind and path_ok) return event;
            }
            if (started.untilNow(io).raw.nanoseconds >= @as(i96, timeout_ms) * std.time.ns_per_ms) {
                self.dump(watcher);
                return error.TestExpectedEvent;
            }
        }
    }

    /// 吸收静默窗口内的尾随事件。
    fn drain(self: *Pump, watcher: *watch.Watcher, idle_ms: i64) !void {
        while (try self.pollFor(watcher, idle_ms)) |_| {}
    }

    fn dump(self: *Pump, watcher: *watch.Watcher) void {
        std.debug.print(
            "超时：已收 {d} 条；队列 dropped={d} overflows={d} skipped={d} lastError={d}\n",
            .{ self.events.items.len, watcher.dropped(), watcher.overflows(), watcher.skipped(), watcher.lastError() },
        );
        for (self.events.items) |event| {
            std.debug.print("  seq={d} kind={s} path={s} old={s}\n", .{
                event.seq,
                @tagName(event.kind),
                event.path.slice(),
                event.old_path.slice(),
            });
        }
    }
};

const Fixture = struct {
    tmp: std.testing.TmpDir,
    path: []u8,
    watcher: watch.Watcher,
    pump: Pump,

    fn init(options: watch.Options) !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const length = try tmp.dir.realPath(io, &buffer);
        const path = try allocator.dupe(u8, buffer[0..length]);
        errdefer allocator.free(path);

        const watcher = try watch.Watcher.init(allocator, path, options);
        return .{
            .tmp = tmp,
            .path = path,
            .watcher = watcher,
            .pump = .{ .allocator = allocator },
        };
    }

    fn deinit(self: *Fixture) void {
        self.watcher.deinit();
        self.pump.deinit();
        allocator.free(self.path);
        self.tmp.cleanup();
    }

    fn start(self: *Fixture) !void {
        try self.watcher.start();
    }

    fn write(self: *Fixture, sub_path: []const u8, data: []const u8) !void {
        try self.tmp.dir.writeFile(io, .{ .sub_path = sub_path, .data = data });
    }

    /// 建一个空文件（不写内容）。Windows 会把「创建 + 立刻写」合并成一条 MODIFIED，
    /// 要稳定验证 ADDED，就必须只创建、不写。
    fn touch(self: *Fixture, sub_path: []const u8) !void {
        var file = try self.tmp.dir.createFile(io, sub_path, .{});
        file.close(io);
    }

    fn expectKind(self: *Fixture, kind: watch.Kind, path: ?[]const u8) !watch.Event {
        return self.pump.expectKind(&self.watcher, kind, path, step_timeout_ms);
    }

    fn drain(self: *Fixture) !void {
        try self.pump.drain(&self.watcher, quiet_ms);
    }
};

// ---------------------------------------------------------------------------
// 1–5：四类变更 + 递归
// ---------------------------------------------------------------------------

test "创建文件 → created" {
    var fixture = try Fixture.init(.{ .capacity = 32 });
    defer fixture.deinit();
    try fixture.start();
    try std.testing.expect(fixture.watcher.isRunning());

    try fixture.touch("a.txt");
    const event = try fixture.expectKind(.created, "a.txt");

    try std.testing.expect(event.seq > 0);
    try std.testing.expectEqualStrings("a.txt", event.path.slice());
    try std.testing.expectEqual(watch.Kind.created, event.kind);
    try std.testing.expectEqual(@as(u64, 0), fixture.watcher.dropped());
}

test "写入 / 追加内容 → modified" {
    var fixture = try Fixture.init(.{ .capacity = 32 });
    defer fixture.deinit();
    try fixture.start();

    try fixture.touch("b.txt");
    _ = try fixture.expectKind(.created, "b.txt");
    try fixture.drain();

    try fixture.write("b.txt", "more bytes");
    const event = try fixture.expectKind(.modified, "b.txt");
    try std.testing.expectEqual(watch.Kind.modified, event.kind);
    try std.testing.expectEqualStrings("b.txt", event.path.slice());
}

test "改名 → renamed 且 from / to 正确" {
    var fixture = try Fixture.init(.{ .capacity = 32 });
    defer fixture.deinit();
    try fixture.start();

    try fixture.touch("old.txt");
    _ = try fixture.expectKind(.created, "old.txt");
    try fixture.drain();

    try fixture.tmp.dir.rename("old.txt", fixture.tmp.dir, "new.txt", io);
    const event = try fixture.expectKind(.renamed, "new.txt");

    try std.testing.expect(event.isRename());
    try std.testing.expectEqualStrings("old.txt", event.old_path.slice());
    try std.testing.expectEqualStrings("new.txt", event.path.slice());
}

test "删除 → removed" {
    var fixture = try Fixture.init(.{ .capacity = 32 });
    defer fixture.deinit();
    try fixture.start();

    try fixture.touch("c.txt");
    _ = try fixture.expectKind(.created, "c.txt");
    try fixture.drain();

    try fixture.tmp.dir.deleteFile(io, "c.txt");
    const event = try fixture.expectKind(.removed, "c.txt");
    try std.testing.expectEqual(watch.Kind.removed, event.kind);
}

test "子目录里的文件也能收到（递归）" {
    const nested = "sub" ++ std.fs.path.sep_str ++ "deep" ++ std.fs.path.sep_str ++ "nested.txt";

    var fixture = try Fixture.init(.{ .capacity = 32 });
    defer fixture.deinit();
    // 子目录在 start 之前建好，避免目录创建事件混进断言。
    try fixture.tmp.dir.createDirPath(io, "sub" ++ std.fs.path.sep_str ++ "deep");
    try fixture.start();

    try fixture.touch(nested);
    const event = try fixture.expectKind(.created, nested);
    try std.testing.expectEqualStrings(nested, event.path.slice());
}

// ---------------------------------------------------------------------------
// 6–7：停止可靠 + 有界缓冲
// ---------------------------------------------------------------------------

test "stop 之后后台线程在 200ms 内退出" {
    var fixture = try Fixture.init(.{ .capacity = 32 });
    defer fixture.deinit();
    try fixture.start();

    // 先制造一次变更，确认线程已经进过阻塞读。
    try fixture.touch("s.txt");
    _ = try fixture.expectKind(.created, "s.txt");

    const started = std.Io.Clock.Timestamp.now(io, .awake);
    fixture.watcher.stop();
    const elapsed_ns = started.untilNow(io).raw.nanoseconds;

    try std.testing.expect(!fixture.watcher.isRunning());
    try std.testing.expect(elapsed_ns < 200 * std.time.ns_per_ms);
}

test "stop 之后可以再次 start" {
    var fixture = try Fixture.init(.{ .capacity = 8 });
    defer fixture.deinit();

    try fixture.start();
    try fixture.touch("first.txt");
    _ = try fixture.expectKind(.created, "first.txt");
    fixture.watcher.stop();
    try std.testing.expect(!fixture.watcher.isRunning());

    try fixture.start();
    try std.testing.expect(fixture.watcher.isRunning());
    try fixture.touch("second.txt");
    _ = try fixture.expectKind(.created, "second.txt");
}

test "start 之后立刻 stop 也能退出（不挂在读上）" {
    var fixture = try Fixture.init(.{ .capacity = 8 });
    defer fixture.deinit();

    // 反复撞「线程刚起来、读还没挂起」的窗口：stop 侧的重试取消要能兜住。
    for (0..20) |_| {
        try fixture.start();
        const started = std.Io.Clock.Timestamp.now(io, .awake);
        fixture.watcher.stop();
        const elapsed_ns = started.untilNow(io).raw.nanoseconds;
        try std.testing.expect(!fixture.watcher.isRunning());
        try std.testing.expect(elapsed_ns < 200 * std.time.ns_per_ms);
    }
}

test "容量 4 + 连续 50 次变更 → dropped > 0 且不崩" {
    var fixture = try Fixture.init(.{ .capacity = 4 });
    defer fixture.deinit();
    try fixture.start();
    try std.testing.expectEqual(@as(usize, 4), fixture.watcher.capacity());

    var name_buffer: [32]u8 = undefined;
    for (0..50) |index| {
        const name = try std.fmt.bufPrint(&name_buffer, "f{d:0>3}.txt", .{index});
        try fixture.touch(name);
    }

    // 不主动 poll，让生产者把 4 格队列顶爆。
    const started = std.Io.Clock.Timestamp.now(io, .awake);
    while (fixture.watcher.dropped() == 0) {
        if (started.untilNow(io).raw.nanoseconds >= @as(i96, step_timeout_ms) * std.time.ns_per_ms) break;
        try io.sleep(std.Io.Duration.fromMilliseconds(poll_interval_ms), .awake);
    }
    try std.testing.expect(fixture.watcher.dropped() > 0);

    var buffer: [8]watch.Event = undefined;
    var received: usize = 0;
    var last_seq: u64 = 0;
    while (true) {
        const count = fixture.watcher.poll(&buffer);
        if (count == 0) break;
        for (buffer[0..count]) |event| {
            try std.testing.expect(event.seq > last_seq);
            last_seq = event.seq;
            received += 1;
        }
    }
    // 队列最多 4 条；剩下的都在 dropped 里，序号有缺口。
    try std.testing.expect(received > 0);
    try std.testing.expect(received <= 4);
    try std.testing.expect(last_seq >= received);

    // 溢出之后仍然活着：还能收新事件。
    try fixture.touch("after.txt");
    _ = try fixture.expectKind(.created, "after.txt");
}

// ---------------------------------------------------------------------------
// 队列（纯内存）与解码（合成 FILE_NOTIFY_INFORMATION）单元测试
// ---------------------------------------------------------------------------

test "队列 drop_oldest：满时丢最旧并计数，序号留缺口" {
    var queue = try watch.Queue.init(allocator, 2, .drop_oldest);
    defer queue.deinit();

    queue.record(.created, "a", "", 0);
    queue.record(.created, "b", "", 0);
    queue.record(.created, "c", "", 0);
    try std.testing.expectEqual(@as(u64, 1), queue.dropped());

    var out: [4]watch.Event = undefined;
    const count = queue.poll(&out);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqualStrings("b", out[0].path.slice());
    try std.testing.expectEqualStrings("c", out[1].path.slice());
    try std.testing.expectEqual(@as(u64, 2), out[0].seq);
    try std.testing.expectEqual(@as(u64, 3), out[1].seq);
}

test "队列 drop_newest：满时丢新事件，队列原样" {
    var queue = try watch.Queue.init(allocator, 2, .drop_newest);
    defer queue.deinit();

    queue.record(.created, "a", "", 0);
    queue.record(.created, "b", "", 0);
    queue.record(.created, "c", "", 0);
    try std.testing.expectEqual(@as(u64, 1), queue.dropped());

    var out: [4]watch.Event = undefined;
    const count = queue.poll(&out);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqualStrings("a", out[0].path.slice());
    try std.testing.expectEqualStrings("b", out[1].path.slice());
}

test "内核溢出 → overflow 事件 + 计数" {
    var queue = try watch.Queue.init(allocator, 4, .drop_oldest);
    defer queue.deinit();

    queue.recordOverflow(0);
    try std.testing.expectEqual(@as(u64, 1), queue.overflows());

    var out: [2]watch.Event = undefined;
    try std.testing.expectEqual(@as(usize, 1), queue.poll(&out));
    try std.testing.expectEqual(watch.Kind.overflow, out[0].kind);
    try std.testing.expectEqual(@as(u32, 0), out[0].lost);
}

const Capture = struct {
    action: win.Action,
    path_bytes: [64]u8 = undefined,
    path_len: usize = 0,
    old_bytes: [64]u8 = undefined,
    old_len: usize = 0,
    lost: u32 = 0,

    fn path(self: *const Capture) []const u8 {
        return self.path_bytes[0..self.path_len];
    }

    fn oldPath(self: *const Capture) []const u8 {
        return self.old_bytes[0..self.old_len];
    }
};

const Collector = struct {
    items: [16]Capture = undefined,
    len: usize = 0,

    fn sink(self: *Collector) win.Sink {
        return .{ .context = self, .emit = emit };
    }

    fn emit(context: *anyopaque, event: win.RawEvent) void {
        const self: *Collector = @ptrCast(@alignCast(context));
        std.debug.assert(self.len < self.items.len);
        self.items[self.len] = .{ .action = event.action, .lost = event.lost };
        const capture = &self.items[self.len];
        capture.path_len = @min(event.path.len, capture.path_bytes.len);
        @memcpy(capture.path_bytes[0..capture.path_len], event.path[0..capture.path_len]);
        capture.old_len = @min(event.old_path.len, capture.old_bytes.len);
        @memcpy(capture.old_bytes[0..capture.old_len], event.old_path[0..capture.old_len]);
        self.len += 1;
    }
};

/// 按 Windows 的 FILE_NOTIFY_INFORMATION 布局拼一段通知缓冲区。
const NotifyBuilder = struct {
    bytes: [2048]u8 = undefined,
    len: usize = 0,
    last_entry: ?usize = null,

    fn add(self: *NotifyBuilder, action: u32, name: []const u8) void {
        var units: [256]u16 = undefined;
        const unit_count = std.unicode.wtf8ToWtf16Le(&units, name) catch unreachable;

        const start = self.len;
        const padded = std.mem.alignForward(usize, 12 + unit_count * 2, 4);
        if (self.last_entry) |previous| {
            std.mem.writeInt(u32, self.bytes[previous..][0..4], @intCast(start - previous), .little);
        }
        @memset(self.bytes[start .. start + padded], 0);
        std.mem.writeInt(u32, self.bytes[start + 4 ..][0..4], action, .little);
        std.mem.writeInt(u32, self.bytes[start + 8 ..][0..4], @intCast(unit_count * 2), .little);
        for (0..unit_count) |index| {
            std.mem.writeInt(u16, self.bytes[start + 12 + index * 2 ..][0..2], units[index], .little);
        }
        self.last_entry = start;
        self.len = start + padded;
    }

    fn buffer(self: *const NotifyBuilder) []const u8 {
        return self.bytes[0..self.len];
    }
};

const action_added: u32 = 1;
const action_modified: u32 = 3;
const action_old_name: u32 = 4;
const action_new_name: u32 = 5;

test "解码：ADDED → added" {
    var builder = NotifyBuilder{};
    builder.add(action_added, "hello.txt");
    var collector = Collector{};
    var decoder = win.Decoder{};
    decoder.feed(builder.buffer(), collector.sink());

    try std.testing.expectEqual(@as(usize, 1), collector.len);
    try std.testing.expectEqual(win.Action.added, collector.items[0].action);
    try std.testing.expectEqualStrings("hello.txt", collector.items[0].path());
}

test "解码：OLD + NEW 配对成一个 renamed" {
    var builder = NotifyBuilder{};
    builder.add(action_old_name, "old.txt");
    builder.add(action_new_name, "new.txt");
    var collector = Collector{};
    var decoder = win.Decoder{};
    decoder.feed(builder.buffer(), collector.sink());

    try std.testing.expectEqual(@as(usize, 1), collector.len);
    try std.testing.expectEqual(win.Action.renamed, collector.items[0].action);
    try std.testing.expectEqualStrings("old.txt", collector.items[0].oldPath());
    try std.testing.expectEqualStrings("new.txt", collector.items[0].path());
}

test "解码：OLD 与 NEW 分属两次读也能配对" {
    var first = NotifyBuilder{};
    first.add(action_old_name, "before.txt");
    var second = NotifyBuilder{};
    second.add(action_new_name, "after.txt");

    var collector = Collector{};
    var decoder = win.Decoder{};
    decoder.feed(first.buffer(), collector.sink());
    try std.testing.expectEqual(@as(usize, 0), collector.len);

    decoder.feed(second.buffer(), collector.sink());
    try std.testing.expectEqual(@as(usize, 1), collector.len);
    try std.testing.expectEqual(win.Action.renamed, collector.items[0].action);
    try std.testing.expectEqualStrings("before.txt", collector.items[0].oldPath());
    try std.testing.expectEqualStrings("after.txt", collector.items[0].path());
}

test "解码：只有 OLD → 降级 removed；只有 NEW → 降级 created" {
    var mixed = NotifyBuilder{};
    mixed.add(action_old_name, "gone.txt");
    mixed.add(action_modified, "other.txt");

    var collector = Collector{};
    var decoder = win.Decoder{};
    decoder.feed(mixed.buffer(), collector.sink());

    try std.testing.expectEqual(@as(usize, 2), collector.len);
    try std.testing.expectEqual(win.Action.removed, collector.items[0].action);
    try std.testing.expectEqualStrings("gone.txt", collector.items[0].path());
    try std.testing.expectEqual(win.Action.modified, collector.items[1].action);

    var lonely = NotifyBuilder{};
    lonely.add(action_new_name, "fresh.txt");
    var second = Collector{};
    decoder.feed(lonely.buffer(), second.sink());

    try std.testing.expectEqual(@as(usize, 1), second.len);
    try std.testing.expectEqual(win.Action.added, second.items[0].action);
    try std.testing.expectEqualStrings("fresh.txt", second.items[0].path());
}

test "解码：内核溢出先降级悬挂 OLD，再报 overflow" {
    var builder = NotifyBuilder{};
    builder.add(action_old_name, "half.txt");
    var collector = Collector{};
    var decoder = win.Decoder{};
    decoder.feed(builder.buffer(), collector.sink());
    try std.testing.expectEqual(@as(usize, 0), collector.len);

    decoder.feedOverflow(collector.sink(), 0);
    try std.testing.expectEqual(@as(usize, 2), collector.len);
    try std.testing.expectEqual(win.Action.removed, collector.items[0].action);
    try std.testing.expectEqualStrings("half.txt", collector.items[0].path());
    try std.testing.expectEqual(win.Action.overflow, collector.items[1].action);
    try std.testing.expectEqual(@as(u32, 0), collector.items[1].lost);
}

test "读缓冲按 DWORD 对齐：bump 分配器也不会把监听打死" {
    // ReadDirectoryChangesW 的缓冲区地址不是 4 的倍数时，Windows 直接返回
    // ERROR_NOACCESS(998)，线程当场退出。调用方给的是 arena/bump 时地址可能落在
    // 2 mod 4 上，所以这条性质由口岸自己保证，而不是靠调用方的分配器碰巧对齐。
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(io, &buffer);

    var context = try win.Context.open(arena.allocator(), buffer[0..length]);
    defer context.deinit();

    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(context.buffer.ptr) % @alignOf(u32));
}
