//! Stage 1 的无头导航/监听探针。所有步骤都调用生产 Session，不另写目录模型。
const std = @import("std");
const browse = @import("browse.zig");
const options_mod = @import("options.zig");
const selection_mod = @import("selection.zig");
const trace = @import("trace.zig");
const bench_win = @import("bench_win.zig");

pub fn run(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    directory: []const u8,
    options: options_mod.Options,
    watch_after_steps: bool,
) !u8 {
    _ = allocator;
    const session = browse.Session.init(init.gpa, init.io, directory, .{
        .limit = options.browse_limit,
    }) catch |err| {
        std.debug.print("browse-nav-probe: FAIL reason={s} path={s}\n", .{ @errorName(err), directory });
        return 2;
    };
    defer session.deinit();
    var selected = selection_mod.Selection{};
    defer selected.deinit(init.gpa);

    try pumpIdle(session, &selected);
    var pages: u32 = 0;
    while (pages < options.browse_pages and session.canLoadMore()) : (pages += 1) {
        const before = session.info().pages;
        _ = try session.loadMore();
        try pumpIdle(session, &selected);
        if (session.info().pages <= before) break;
    }
    printStep(session, &selected, 0, "start", null);
    var steps = std.mem.splitScalar(u8, options.browse_steps, ',');
    var number: usize = 0;
    while (steps.next()) |raw| {
        const action = std.mem.trim(u8, raw, " \t\r\n");
        if (action.len == 0) continue;
        number += 1;
        perform(session, &selected, action) catch |err| {
            printStep(session, &selected, number, action, @errorName(err));
            continue;
        };
        try pumpIdle(session, &selected);
        printStep(session, &selected, number, action, null);
    }

    if (watch_after_steps) {
        const rows_before = session.samples().len;
        const events_before = session.info().events;
        var added: usize = 0;
        const seconds = if (options.watch_seconds > 0) options.watch_seconds else 4;
        const deadline = trace.now() + seconds;
        while (trace.now() < deadline) {
            const report = try session.poll(&selected);
            added += report.added;
            try selected.resize(init.gpa, session.samples().len);
            sleepMs(init.io, 16);
        }
        const info = session.info();
        std.debug.print(
            "browse-nav-watch-probe: path={s} events={d} added={d} rows_before={d} rows_after={d} unavailable={}\n",
            .{ session.rootPath(), info.events - events_before, added, rows_before, info.entries, info.unavailable },
        );
    }
    return 0;
}

fn perform(session: *browse.Session, selected: *selection_mod.Selection, action: []const u8) !void {
    if (std.mem.eql(u8, action, "back")) return session.goBack(selected);
    if (std.mem.eql(u8, action, "forward")) return session.goForward(selected);
    if (std.mem.eql(u8, action, "up")) return session.goUp(selected);
    const colon = std.mem.indexOfScalar(u8, action, ':') orelse return error.InvalidStep;
    const verb = action[0..colon];
    const value = action[colon + 1 ..];
    if (std.mem.eql(u8, verb, "sort")) {
        const key = browse.SortKey.parse(value) orelse return error.InvalidSort;
        return session.setSort(key, selected);
    }
    const index = session.indexOfName(value) orelse return error.RowNotFound;
    if (std.mem.eql(u8, verb, "select")) {
        try selected.resize(session.allocator, session.samples().len);
        selected.selectOnly(index);
        _ = try session.poll(selected);
        return;
    }
    if (std.mem.eql(u8, verb, "enter")) return session.enterDirectory(index, selected);
    return error.InvalidStep;
}

fn pumpIdle(session: *browse.Session, selected: *selection_mod.Selection) !void {
    const deadline = trace.now() + 120;
    while (session.info().enumerating and trace.now() < deadline) {
        _ = try session.poll(selected);
        sleepMs(session.io, 1);
    }
    // done 后的下一帧才 replay 新 watcher 队列；给恢复选中与 reconcile 各一拍。
    for (0..6) |_| {
        _ = try session.poll(selected);
        try selected.resize(session.allocator, session.samples().len);
        sleepMs(session.io, 2);
    }
}

fn printStep(
    session: *browse.Session,
    selected: *selection_mod.Selection,
    number: usize,
    action: []const u8,
    failure: ?[]const u8,
) void {
    var name: []const u8 = "";
    if (selected.cursor) |cursor| {
        if (cursor < session.samples().len) name = std.fs.path.basename(session.samples()[cursor].file_path);
    }
    const info = session.info();
    var order_buffer: [2048]u8 = undefined;
    const order = orderText(session, &order_buffer);
    const peak = if (bench_win.residentMax(1)) |resident|
        @as(f64, @floatFromInt(resident.peak_working_set)) / (1024.0 * 1024.0)
    else
        0;
    std.debug.print(
        "browse-nav-probe: step={d} action={s} path={s} rows={d} selected={s} sort={s} unavailable={} error={s} epoch={d} history={d} peak_mib={d:.2} mem_refused={} remaining={d} order={s}\n",
        .{ number, action, session.rootPath(), info.entries, name, info.sort, info.unavailable, failure orelse "none", info.epoch, session.historyLength(), peak, info.mem_refused, info.remaining, order },
    );
}

fn orderText(session: *browse.Session, buffer: []u8) []const u8 {
    var used: usize = 0;
    for (session.samples()[0..@min(8, session.samples().len)]) |sample| {
        const name = std.fs.path.basename(sample.file_path);
        const separator: u8 = if (used == 0) 0 else ';';
        if (used + name.len + 1 > buffer.len) break;
        if (separator != 0) {
            buffer[used] = separator;
            used += 1;
        }
        @memcpy(buffer[used..][0..name.len], name);
        used += name.len;
    }
    return buffer[0..used];
}

fn sleepMs(io: std.Io, ms: u64) void {
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(@intCast(ms)), .awake) catch {};
}
