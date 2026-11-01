//! 地址栏无头探针：Editor 负责编辑/取消，navigation 负责唯一的提交与历史路径。
const std = @import("std");
const browse = @import("browse.zig");
const navigation = @import("browse_navigation.zig");
const model = @import("browse_address_model.zig");
const drives_mod = @import("browse_drives.zig");
const options_mod = @import("options.zig");
const selection_mod = @import("selection.zig");
const nav_probe = @import("browse_nav_probe.zig");
const bench_win = @import("bench_win.zig");

pub fn run(
    init: std.process.Init,
    directory: []const u8,
    options: options_mod.Options,
) !u8 {
    const session = browse.Session.init(init.gpa, init.io, directory, .{
        .limit = options.browse_limit,
    }) catch |err| {
        std.debug.print("browse-address-probe: FAIL reason={s} path={s}\n", .{ @errorName(err), directory });
        return 2;
    };
    defer session.deinit();
    var selected = selection_mod.Selection{};
    defer selected.deinit(init.gpa);
    var editor = model.Editor{};
    editor.cancel(session.rootPath());
    const drives = drives_mod.enumerate(); // 一次快照；set/输入过程绝不重新枚举。
    try nav_probe.pumpIdle(session, &selected);
    var pages: u32 = 0;
    while (pages < options.browse_pages and session.canLoadMore()) : (pages += 1) {
        _ = try session.loadMore();
        try nav_probe.pumpIdle(session, &selected);
    }
    print(session, &selected, &editor, &drives, 0, "start", null);

    if (options.browse_set_path) |path| {
        editor.begin(session.rootPath());
        editor.set(path) catch {};
        submit(session, &selected, &editor);
        print(session, &selected, &editor, &drives, 0, "set-path", editor.failure);
    }

    var steps = std.mem.splitScalar(u8, options.browse_steps, ',');
    var number: usize = 0;
    while (steps.next()) |raw| {
        const action = std.mem.trim(u8, raw, " \t\r\n");
        if (action.len == 0) continue;
        number += 1;
        perform(session, &selected, &editor, action) catch |err| {
            editor.fail(err);
            print(session, &selected, &editor, &drives, number, action, editor.failure);
            continue;
        };
        if (needsPump(action)) try nav_probe.pumpIdle(session, &selected);
        print(session, &selected, &editor, &drives, number, action, editor.failure);
    }
    return 0;
}

fn perform(
    session: *browse.Session,
    selected: *selection_mod.Selection,
    editor: *model.Editor,
    action: []const u8,
) !void {
    if (std.mem.eql(u8, action, "enter")) return submit(session, selected, editor);
    if (std.mem.eql(u8, action, "esc") or std.mem.eql(u8, action, "cancel")) {
        editor.cancel(session.rootPath());
        return;
    }
    if (std.mem.eql(u8, action, "back")) {
        try session.goBack(selected);
        editor.finish(session.rootPath());
        return;
    }
    if (std.mem.eql(u8, action, "forward")) {
        try session.goForward(selected);
        editor.finish(session.rootPath());
        return;
    }
    const colon = std.mem.indexOfScalar(u8, action, ':') orelse return error.InvalidStep;
    const verb = action[0..colon];
    const value = action[colon + 1 ..];
    if (std.mem.eql(u8, verb, "set")) {
        editor.begin(session.rootPath());
        try editor.set(value); // 只有内存复制；这里有意不 pump、不 stat。
        return;
    }
    if (std.mem.eql(u8, verb, "select")) {
        const index = session.indexOfName(value) orelse return error.RowNotFound;
        try selected.resize(session.allocator, session.samples().len);
        selected.selectOnly(index);
        _ = try session.poll(selected);
        return;
    }
    if (std.mem.eql(u8, verb, "crumb")) {
        const one_based = try std.fmt.parseUnsigned(usize, value, 10);
        if (one_based == 0) return error.InvalidCrumb;
        try navigation.crumb(session, one_based - 1, selected);
        editor.finish(session.rootPath());
        return;
    }
    if (std.mem.eql(u8, verb, "drive")) {
        if (value.len == 0) return error.InvalidPath;
        try navigation.drive(session, value[0], selected);
        editor.finish(session.rootPath());
        return;
    }
    return error.InvalidStep;
}

fn submit(session: *browse.Session, selected: *selection_mod.Selection, editor: *model.Editor) void {
    navigation.enterPath(session, editor.text(), selected) catch |err| {
        editor.fail(err);
        return;
    };
    editor.finish(session.rootPath());
}

fn needsPump(action: []const u8) bool {
    return !std.mem.startsWith(u8, action, "set:") and
        !std.mem.eql(u8, action, "esc") and
        !std.mem.eql(u8, action, "cancel");
}

fn print(
    session: *browse.Session,
    selected: *selection_mod.Selection,
    editor: *model.Editor,
    drives: *const drives_mod.List,
    number: usize,
    action: []const u8,
    failure: ?[]const u8,
) void {
    var name: []const u8 = "";
    if (selected.cursor) |cursor| {
        if (cursor < session.samples().len) name = std.fs.path.basename(session.samples()[cursor].file_path);
    }
    var drive_buffer: [2048]u8 = undefined;
    const drive_text = drives.text(&drive_buffer);
    const peak = if (bench_win.residentMax(1)) |resident|
        @as(f64, @floatFromInt(resident.peak_working_set)) / (1024.0 * 1024.0)
    else
        0;
    const info = session.info();
    std.debug.print(
        "browse-address-probe: step={d} action={s} path={s} rows={d} selected={s} error={s} unavailable={} history={d} drives={s} peak_mib={d:.2} mem_refused={} remaining={d} editing={}\n",
        .{ number, action, session.rootPath(), info.entries, name, failure orelse "none", info.unavailable, session.historyLength(), drive_text, peak, info.mem_refused, info.remaining, editor.editing },
    );
}
