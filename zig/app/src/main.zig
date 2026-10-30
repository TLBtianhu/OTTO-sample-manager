//! OTTO Lite spike: the real library data layer (zig/core) rendered by
//! nanoui's Windows CPU backend in a 380x700 window.
//!
//!   otto-lite [path-to-library.json]
//!
//! With no argument it reads `fixtures/library.json`, a synthetic 2000-sample
//! electron-store dump.
const std = @import("std");
const nanoui = @import("nanoui");
const core = @import("otto_core");
const ui = nanoui.ui;

const State = struct {
    samples: []const core.model.Sample,

    fn view(s: *State, c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .height = .fill });
        defer ui.end(c);

        var rows = ui.list(c, .{ .count = s.samples.len, .row_height = 44 });
        while (rows.next()) |i| {
            const sample = s.samples[i];
            const row = ui.div(c).row().wFull().h(44).px(12).gap(10).itemsCenter();
            defer row.end();

            ui.textf(c, .{ .size = 11 }, "{d:0>4}", .{i + 1});
            ui.text(c, sample.file_name, .{ .size = 13 });
            ui.textf(c, .{ .size = 11 }, "{d:.2}s", .{sample.duration});
        }
        rows.end();
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    // nanoui's own --nanoui-* flags share argv; only a plain first argument is
    // a library path.
    const path = if (args.len > 1 and !std.mem.startsWith(u8, args[1], "--"))
        args[1]
    else
        "fixtures/library.json";

    const library = try core.store.loadCwdFile(allocator, init.io, path);

    const app = try nanoui.App.create(init, .{ .name = "OTTO Lite" });
    defer app.destroy();

    var state = State{ .samples = library.samples };
    _ = try app.newWindow(.{
        .title = "OTTO Lite",
        .width = 380,
        .height = 700,
        .content = .{ .view = .init(&state, State.view) },
    });

    try app.run();
}
