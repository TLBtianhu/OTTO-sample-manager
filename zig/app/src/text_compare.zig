//! Offscreen text comparison probe. It renders the same 13px Segoe UI sample
//! that zig/text-compare.ps1 draws with System.Drawing ClearType. No HWND is
//! created: ui.Tester owns an in-process frame and writes a PNG directly.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;

const Sample = struct {
    dark: bool,
    fn view(self: *Sample, c: *ui.Context) void {
        ui.text(c, "Sample 0001 · 采样管理 13px", .{ .size = 13, .color = if (self.dark) .hex(0xf5f5f7) else .hex(0x1c1c1e) });
    }
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2 or args.len > 7) return error.ExpectedPngPathModeRawGridFallbackScaleAndTheme;
    const light = (args.len == 3 and std.mem.eql(u8, args[2], "light")) or (args.len >= 7 and std.mem.eql(u8, args[6], "light"));
    var sample: Sample = .{ .dark = !light };
    var theme = if (light) ui.Theme.light else ui.Theme.dark_theme;
    theme.font = "Segoe UI";
    var tester: ui.Tester = undefined;
    try tester.init(init.gpa, .init(&sample, Sample.view), .{
        .width = 360,
        .height = 48,
        .scale = 1,
        .theme = theme,
        .fonts_dir = "C:\\Windows\\Fonts",
    });
    defer tester.deinit();
    if (args.len >= 3 and !light) tester.text.atlas.native.rendering_override = try std.fmt.parseInt(u32, args[2], 10);
    if (args.len >= 4 and std.mem.eql(u8, args[3], "raw")) tester.text.atlas.native.blending = .{};
    if (args.len >= 5) tester.text.atlas.native.grid_override = try std.fmt.parseInt(u32, args[4], 10);
    if (args.len >= 6) tester.text.setFallbackScale(try std.fmt.parseFloat(f32, args[5]));
    if (args.len >= 3) {
        tester.text.atlas.phase_counts.clearRetainingCapacity();
        tester.text.atlas.reset();
    }
    tester.frame();
    try tester.screenshot(args[1]);

    const font = tester.text.font(.{ .size = 13 });
    const run_font = tester.text.run_fonts.items[font.id];
    const face_index = tester.text.run_faces.items[font.id];
    const native = &tester.text.atlas.native;
    const face = native.fonts.get(.{ .face = @intFromPtr(run_font.font), .simulations = 0 }) orelse return error.MissingNativeFace;
    const mode = native.mode(face, run_font.size, tester.scale);
    std.debug.print(
        "text-compare: family={s} size=13 scale=1 rendering={d} grid={d} cleartype={} gamma_contrast={d:.3}/{d:.3} failures={d}\n",
        .{
            tester.text.db.faces.items[face_index].style.name(),
            mode.rendering,
            mode.grid,
            native.cleartype,
            native.blending.contrast,
            native.blending.grayscale_contrast,
            native.failures,
        },
    );
    const text_layout = tester.text.layout("Sample 0001 · 采样管理 13px", .{ .size = 13 });
    for (text_layout.glyphs) |glyph| {
        const family = tester.text.db.faces.items[tester.text.run_faces.items[glyph.font]].style.name();
        std.debug.print("glyph index={d} id={d} family={s} size={d:.5} x={d:.3}\n", .{ glyph.index, glyph.glyph, family, tester.text.run_fonts.items[glyph.font].size, glyph.x });
    }
}
