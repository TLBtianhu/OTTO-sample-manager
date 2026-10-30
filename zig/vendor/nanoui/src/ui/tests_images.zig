//! Tests for `ui.image` device-pixel sizing in the atlas and decode budgeting.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");
const images = @import("images.zig");

const ViewState = struct {
    bytes: []const u8,
    fn view(s: *ViewState, c: *ui.Context) void {
        _ = ui.image(c, .{ .key = "icon", .source = .{ .encoded = s.bytes }, .max_width = 15, .max_height = 15, .radius = 0, .scale = 0.5 });
    }
};

test "ui.image at 15 pt packs side 30 at scale 2 and side 15 at scale 1" {
    const gpa = testing.allocator;
    const raw = try gpa.alloc(u8, 64 * 64 * 4);
    defer gpa.free(raw);
    @memset(raw, 200);
    const png = try ui.png.encode(gpa, .{ .bytes = raw, .width = 64, .height = 64 });
    defer gpa.free(png);

    const k = images.Images.key("icon");
    {
        var s: ViewState = .{ .bytes = png };
        var t: ui.Tester = undefined;
        try t.init(gpa, ui.View.init(&s, ViewState.view), .{ .width = 100, .height = 100, .scale = 2 });
        defer t.deinit();
        t.frame();
        try testing.expect(t.ctx.text.images.entries.get(.{ .key = k, .side = 30 }).?.entry != null);
    }
    {
        var s: ViewState = .{ .bytes = png };
        var t: ui.Tester = undefined;
        try t.init(gpa, ui.View.init(&s, ViewState.view), .{ .width = 100, .height = 100, .scale = 1 });
        defer t.deinit();
        t.frame();
        try testing.expect(t.ctx.text.images.entries.get(.{ .key = k, .side = 15 }).?.entry != null);
    }
}

const BudgetState = struct {
    bytes: []const u8,
    fn view(s: *BudgetState, c: *ui.Context) void {
        for (0..9) |i| {
            _ = ui.image(c, .{ .key = c.print("icon.{d}", .{i}), .source = .{ .encoded = s.bytes }, .max_width = 15, .max_height = 15, .radius = 0, .scale = 0.5 });
        }
    }
};

test "decode budget limits to 8 decodes per frame and requests next frame" {
    const gpa = testing.allocator;
    const raw = try gpa.alloc(u8, 16 * 16 * 4);
    defer gpa.free(raw);
    @memset(raw, 200);
    const png = try ui.png.encode(gpa, .{ .bytes = raw, .width = 16, .height = 16 });
    defer gpa.free(png);

    var s: BudgetState = .{ .bytes = png };
    var t: ui.Tester = undefined;
    try t.init(gpa, ui.View.init(&s, BudgetState.view), .{ .width = 200, .height = 200, .scale = 2 });
    defer t.deinit();
    try testing.expectEqual(@as(usize, 8), t.ctx.text.images.entries.count());
    try testing.expect(t.ctx.text.images.wants_frame);
    t.frame();
    try testing.expectEqual(@as(usize, 9), t.ctx.text.images.entries.count());
    try testing.expect(!t.ctx.text.images.wants_frame);
}

test "sink uploads survive render after pre-sink pixels allocation" {
    if (@import("build_options").portable or @import("builtin").os.tag != .macos) return;
    const gpa = testing.allocator;
    const raw = try gpa.alloc(u8, 16 * 16 * 4);
    defer gpa.free(raw);
    @memset(raw, 220);
    const png = try ui.png.encode(gpa, .{ .bytes = raw, .width = 16, .height = 16 });
    defer gpa.free(png);

    var s: BudgetState = .{ .bytes = png };
    var t: ui.Tester = undefined;
    // Frame 1 runs with sink == null, allocating im.pixels and decoding 8 of 9 icons.
    try t.init(gpa, ui.View.init(&s, BudgetState.view), .{ .width = 200, .height = 200, .scale = 2, .dark = true });
    defer t.deinit();
    // Sync the first 8 icons into images_texture, then attach the direct GPU sink for icon.8.
    t.renderer.syncImages(&t.text.images);
    t.text.images.sink = .{ .ctx = &t.renderer, .upload = @TypeOf(t.renderer).uploadImage };
    t.frame();
    const px = try t.render(gpa);
    defer px.deinit(gpa);
    const k8 = images.Images.key("icon.8");
    const e6 = t.ctx.text.images.entries.get(.{ .key = k8, .side = 30 }).?.entry.?;
    var r6: ?ui.Rect = null;
    for (t.ctx.nodes.items) |n| switch (n.content) {
        .image => |im| if (im.key == k8) {
            r6 = n.rect;
        },
        else => {},
    };
    try testing.expect(e6.uv[0] > 0);
    const rect = r6.?;
    const cx: usize = @intFromFloat(@round((rect.x + rect.w * 0.5) * 2));
    const cy: usize = @intFromFloat(@round((rect.y + rect.h * 0.5) * 2));
    const idx = (cy * px.width + cx) * 4;
    try testing.expect(px.bytes[idx] > 180 and px.bytes[idx + 1] > 180 and px.bytes[idx + 2] > 180);
}

/// The rectangle the last frame gave the picture `name`.
fn imageRect(t: *ui.Tester, name: []const u8) ?ui.Rect {
    const k = images.Images.key(name);
    for (t.ctx.nodes.items) |n| switch (n.content) {
        .image => |im| if (im.key == k) return n.rect,
        else => {},
    };
    return null;
}

const Tile = struct {
    bgra: []const u8,
    png: []const u8,
    fn view(s: *Tile, c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(10), .gap = 2 });
        defer ui.end(c);
        _ = ui.image(c, .{ .key = "raw", .source = .{ .pixels = .{ .bgra = s.bgra, .width = 4, .height = 4 } }, .max_width = 4, .max_height = 4, .radius = 0, .scale = 1 });
        _ = ui.image(c, .{ .key = "png", .source = .{ .encoded = s.png }, .max_width = 4, .max_height = 4, .radius = 0, .scale = 1 });
    }
};

test "raw pixels draw like the same picture decoded from a PNG" {
    const gpa = testing.allocator;
    // A 4×4 opaque checker, so the PNG round trip is exact: BGRA.
    var px: [4 * 4 * 4]u8 = undefined;
    for (0..4) |y| for (0..4) |x| {
        px[(y * 4 + x) * 4 ..][0..4].* = if ((x + y) % 2 == 0) .{ 30, 90, 200, 255 } else .{ 220, 40, 10, 255 };
    };
    const png = try ui.png.encode(gpa, .{ .bytes = &px, .width = 4, .height = 4 });
    defer gpa.free(png);
    var s: Tile = .{ .bgra = &px, .png = png };
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, Tile.view), .{ .width = 60, .height = 60, .scale = 1 });
    defer t.deinit();
    t.settle(1);
    const a = imageRect(&t, "raw").?;
    const b = imageRect(&t, "png").?;
    try testing.expectEqual(a.w, b.w);
    try testing.expectEqual(a.h, b.h);
    // Both are packed, in different places of the atlas.
    const kw = images.Images.key("raw");
    const kp = images.Images.key("png");
    const ew = t.ctx.text.images.entries.get(.{ .key = kw, .side = 4 }).?.entry.?;
    const ep = t.ctx.text.images.entries.get(.{ .key = kp, .side = 4 }).?.entry.?;
    try testing.expect(ew.uv[0] != ep.uv[0]);
    const out = try t.render(gpa);
    defer out.deinit(gpa);
    const ax: usize = @intFromFloat(@round(a.x));
    const ay: usize = @intFromFloat(@round(a.y));
    const bx: usize = @intFromFloat(@round(b.x));
    const by: usize = @intFromFloat(@round(b.y));
    const w: usize = @intFromFloat(@round(a.w));
    const h: usize = @intFromFloat(@round(a.h));
    try testing.expect(w == 4 and h == 4);
    for (0..h) |y| for (0..w) |x| {
        const p = ((ay + y) * out.width + ax + x) * 4;
        const q = ((by + y) * out.width + bx + x) * 4;
        // The raw pixels are what the source says, and the two differ by at
        // most rounding: the checker alternates, so a blank or stretched
        // picture would show.
        for (0..4) |ch| {
            const want = if ((x + y) % 2 == 0) [4]u8{ 30, 90, 200, 255 } else [4]u8{ 220, 40, 10, 255 };
            const d = if (out.bytes[p + ch] > want[ch]) out.bytes[p + ch] - want[ch] else want[ch] - out.bytes[p + ch];
            try testing.expect(d <= 1);
            const e = if (out.bytes[p + ch] > out.bytes[q + ch]) out.bytes[p + ch] - out.bytes[q + ch] else out.bytes[q + ch] - out.bytes[p + ch];
            try testing.expect(e <= 1);
        }
    };
}

const Same = struct {
    bgra: []const u8,
    fn view(s: *Same, c: *ui.Context) void {
        _ = ui.image(c, .{ .key = "same", .source = .{ .pixels = .{ .bgra = s.bgra, .width = 2, .height = 2 } }, .max_width = 2, .max_height = 2, .radius = 0, .scale = 1 });
    }
};

test "a key keeps the first pixels it was given" {
    const gpa = testing.allocator;
    var px = [_]u8{ 0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255, 255 }; // opaque red, BGRA
    var s: Same = .{ .bgra = &px };
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, Same.view), .{ .width = 20, .height = 20, .scale = 1 });
    defer t.deinit();
    const r = imageRect(&t, "same").?;
    const first = try t.render(gpa);
    defer first.deinit(gpa);
    const p = (@as(usize, @intFromFloat(@round(r.y))) * first.width + @as(usize, @intFromFloat(@round(r.x)))) * 4;
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 255, 255 }, first.bytes[p..][0..4]);
    // New pixels under the same key are not seen: a key names a picture.
    @memset(&px, 0);
    px[3] = 255; // opaque black now
    t.frame();
    const second = try t.render(gpa);
    defer second.deinit(gpa);
    try testing.expectEqualSlices(u8, first.bytes[p..][0..4], second.bytes[p..][0..4]);
}
