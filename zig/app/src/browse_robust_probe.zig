//! 按需补全与路径健壮性的无窗口探针。只读真实目录，不创建 HWND、不写源目录。
const std = @import("std");
const browse = @import("browse.zig");
const browse_dir = @import("otto_browse_dir");
const complete_mod = @import("browse_complete.zig");
const model = @import("browse_address_model.zig");
const nav_probe = @import("browse_nav_probe.zig");
const options_mod = @import("options.zig");
const path_win = @import("otto_win_path");
const selection_mod = @import("selection.zig");

pub fn complete(init: std.process.Init, directory: []const u8, options: options_mod.Options) !u8 {
    var editor = model.Editor{};
    editor.begin(directory);
    try editor.set(options.browse_text orelse "");
    var state = complete_mod.State.init(init.gpa);
    defer state.deinit();
    var sequence: std.ArrayListUnmanaged(u8) = .empty;
    defer sequence.deinit(init.gpa);

    _ = state.complete(directory, &editor, false) catch |err| {
        std.debug.print("browse-complete-probe: matches=0 current= sequence= enumerations={d} error={s} writes=0\n", .{ state.enumerations, @errorName(err) });
        return 0;
    };
    const count = state.matches.items.len;
    if (count > 0) {
        try appendName(&sequence, init.gpa, state.current().?);
        // N 个匹配再走 N-1 步，然后再走一步证明绕回第一项。
        for (1..count + 1) |_| {
            _ = try state.complete(directory, &editor, false);
            try appendName(&sequence, init.gpa, state.current().?);
        }
        _ = try state.complete(directory, &editor, true);
    } else {
        // 零匹配同样命中缓存，第二次 Tab 不能多一次 FindFirst。
        _ = try state.complete(directory, &editor, false);
    }
    std.debug.print(
        "browse-complete-probe: matches={d} current={s} sequence={s} enumerations={d} message={s} error=none writes=0\n",
        .{ count, currentName(state.current()), sequence.items, state.enumerations, if (state.noMatches()) "无匹配" else "none" },
    );
    return 0;
}

pub fn path(init: std.process.Init, directory: []const u8) !u8 {
    const kind = pathKind(directory);
    const input_attributes = browse_dir.attributesOf(init.gpa, directory) catch |err| {
        std.debug.print("browse-path-probe: kind={s} error={s} rows=0 resolved={s} reparse=false recursive=false\n", .{ kind, @errorName(err), directory });
        return 0;
    };
    if (input_attributes & browse_dir.FILE_ATTRIBUTE_DIRECTORY == 0) {
        std.debug.print("browse-path-probe: kind=file error=NotDirectory rows=0 resolved={s} reparse=false recursive=false\n", .{directory});
        return 0;
    }
    const reparse = input_attributes & browse_dir.FILE_ATTRIBUTE_REPARSE_POINT != 0;
    const session = browse.Session.init(init.gpa, init.io, directory, .{ .watch = false }) catch |err| {
        std.debug.print("browse-path-probe: kind={s} error={s} rows=0 resolved={s} reparse={} recursive=false\n", .{ kind, @errorName(err), directory, reparse });
        return 0;
    };
    defer session.deinit();
    var selected = selection_mod.Selection{};
    defer selected.deinit(init.gpa);
    try nav_probe.pumpIdle(session, &selected);
    const info = session.info();
    const failure = info.path_error orelse "none";
    const final_kind = if (reparse) "junction" else kind;
    std.debug.print(
        "browse-path-probe: kind={s} error={s} rows={d} resolved={s} reparse={} recursive=false unavailable={} denied={}\n",
        .{ final_kind, failure, info.entries, session.rootPath(), reparse, info.unavailable, info.denied },
    );
    return 0;
}

fn pathKind(value: []const u8) []const u8 {
    if (path_win.hasExtendedPrefix(value) or value.len > 260) return "long";
    if (value.len >= 2 and std.fs.path.isSep(value[0]) and std.fs.path.isSep(value[1])) return "unc";
    return "directory";
}

fn appendName(sequence: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    if (sequence.items.len > 0) try sequence.append(allocator, ';');
    try sequence.appendSlice(allocator, currentName(value));
}

fn currentName(value: ?[]const u8) []const u8 {
    const text = value orelse return "";
    return std.fs.path.basename(std.mem.trimEnd(u8, text, "\\/"));
}
