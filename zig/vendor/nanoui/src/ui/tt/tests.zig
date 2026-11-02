//! The TrueType reader and rasterizer on a real font file, where one is
//! installed (Arial on macOS, DejaVu Sans on Linux, Arial on Windows);
//! skipped elsewhere.
const std = @import("std");
const font = @import("font.zig");
const fontdb = @import("fontdb.zig");
const fontindex = @import("fontindex.zig");
const raster = @import("raster.zig");

const candidates = [_][]const u8{
    "/System/Library/Fonts/Supplemental/Arial.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/TTF/DejaVuSans.ttf",
    "C:\\Windows\\Fonts\\arial.ttf",
};

fn load(gpa: std.mem.Allocator) ?[]u8 {
    const io = std.testing.io;
    for (candidates) |p| {
        return std.Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(64 << 20)) catch continue;
    }
    return null;
}

test "a font's metrics, characters, advances, kerning and outlines" {
    const gpa = std.testing.allocator;
    const data = load(gpa) orelse return error.SkipZigTest;
    defer gpa.free(data);
    const f = try font.Font.init(data, 0);
    try std.testing.expect(f.units_per_em >= 1000);
    try std.testing.expect(f.ascent > 0 and f.descent > 0);
    try std.testing.expect(f.style.weight == 400 and !f.style.italic);
    try std.testing.expect(f.style.name().len > 0);
    const a = f.glyphIndex('A');
    const v = f.glyphIndex('V');
    try std.testing.expect(a != 0 and v != 0);
    try std.testing.expect(f.glyphIndex(0x10FFFF) == 0);
    // "i" is narrower than "m"; "AV" kerns closer.
    try std.testing.expect(f.advance(f.glyphIndex('i')) < f.advance(f.glyphIndex('m')));
    try std.testing.expect(f.kerning(a, v) <= 0);

    // "o" at 40 pixels: ink in its ring, none in its hole.
    const o = f.glyphIndex('o');
    const b = f.bounds(o).?;
    const s = 40 / f.units_per_em;
    const w: usize = @intFromFloat(@ceil((b[2] - b[0]) * s) + 2);
    const h: usize = @intFromFloat(@ceil((b[3] - b[1]) * s) + 2);
    var r = try raster.Raster.init(gpa, w, h);
    defer r.deinit(gpa);
    f.outline(o, .{ s, 0, 0, -s, 1 - b[0] * s, 1 + b[3] * s }, r.sink());
    const px = try gpa.alloc(u8, w * h);
    defer gpa.free(px);
    r.coverage(px);
    try std.testing.expectEqual(@as(u8, 0), px[(h / 2) * w + w / 2]);
    var ink: usize = 0;
    for (px) |p| ink += @intFromBool(p > 128);
    try std.testing.expect(ink > w * h / 5);
    try std.testing.expect(px[(h / 2) * w + 2] > 128);
}

test "a font the app brings is found by its family, from its bytes" {
    const gpa = std.testing.allocator;
    const data = load(gpa) orelse return error.SkipZigTest;
    defer gpa.free(data);
    var db = fontdb.Db.init(gpa, std.testing.io);
    defer db.deinit();
    // Only this font: no folders scanned.
    db.scanned = true;
    db.addMemory(data);
    const family = db.faces.items[0].style.name();
    const face = db.family(family, 400, false).?;
    const f = db.load(face).?;
    try std.testing.expect(f.glyphIndex('A') != 0);
    try std.testing.expect(db.family("No Such Family", 400, false) == null);
}

// One real font in a folder of its own, with a cache beside it: the
// first start scans and writes, the second is answered by the cache, a
// moved mtime or a damaged file scans again. This is the app's path
// (`Db.cache_path` + `Db.fonts_dir`) without the system font folder.
test "the font index cache: a second start skips the scan; a changed font or a damaged index rescans" {
    const gpa = std.testing.allocator;
    const data = load(gpa) orelse return error.SkipZigTest;
    defer gpa.free(data);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path_buffer);
    const root = path_buffer[0..len];
    try tmp.dir.createDir(std.testing.io, "fonts", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "fonts/one.ttf", .data = data });
    const fonts_dir = try std.fs.path.join(gpa, &.{ root, "fonts" });
    defer gpa.free(fonts_dir);
    // The cache lives beside the folder, as an app keeps it in its data
    // directory; putting it inside would change the folder it describes.
    const cache_path = try std.fs.path.join(gpa, &.{ root, "cache", "fonts.idx" });
    defer gpa.free(cache_path);

    // First start: scans, writes the index.
    var first = fontdb.Db.init(gpa, std.testing.io);
    defer first.deinit();
    first.cache_path = cache_path;
    first.fonts_dir = fonts_dir;
    first.scan();
    try std.testing.expectEqual(fontindex.State.written, first.cache.state);
    const faces = first.faces.items.len;
    try std.testing.expect(faces > 0);

    // Second start: the cache answers, no file is read.
    var second = fontdb.Db.init(gpa, std.testing.io);
    defer second.deinit();
    second.cache_path = cache_path;
    second.fonts_dir = fonts_dir;
    second.scan();
    try std.testing.expectEqual(fontindex.State.hit, second.cache.state);
    try std.testing.expectEqual(faces, second.faces.items.len);

    // The same font with a moved mtime is a different folder: scan again.
    var file = try tmp.dir.openFile(std.testing.io, "fonts/one.ttf", .{ .mode = .read_write });
    try file.setTimestamps(std.testing.io, .{
        .modify_timestamp = .{ .new = .{ .nanoseconds = 1_700_000_000_000_000_000 } },
    });
    file.close(std.testing.io);
    var moved = fontdb.Db.init(gpa, std.testing.io);
    defer moved.deinit();
    moved.cache_path = cache_path;
    moved.fonts_dir = fonts_dir;
    moved.scan();
    try std.testing.expectEqual(fontindex.State.written, moved.cache.state);
    try std.testing.expectEqual(faces, moved.faces.items.len);

    // A damaged index is not a smaller cache: it is ignored and rewritten.
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = cache_path, .data = "not a font index" });
    var damaged = fontdb.Db.init(gpa, std.testing.io);
    defer damaged.deinit();
    damaged.cache_path = cache_path;
    damaged.fonts_dir = fonts_dir;
    damaged.scan();
    try std.testing.expectEqual(fontindex.State.written, damaged.cache.state);
    try std.testing.expectEqual(faces, damaged.faces.items.len);
}

