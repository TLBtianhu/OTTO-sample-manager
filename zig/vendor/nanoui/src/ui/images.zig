//! Pictures the UI shows (`ui.image`): decoded once from the bytes the app
//! gives (ImageIO on macOS and iOS, nanoui's PNG decoder elsewhere), or
//! copied once from the pixels it gives (a shell's thumbnail, a captured
//! frame), scaled to at most `max_side` pixels, and packed into one BGRA
//! atlas the renderers sample (premultiplied). Made on the first picture;
//! when full, emptied and packed again, and the frame painted again.
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const png_decode = @import("png_decode.zig");

const portable = build_options.portable or !(builtin.os.tag == .macos or builtin.os.tag == .ios);
const imageio = if (portable) void else @import("image.zig");

pub const max_size: u32 = 2048;
/// The first atlas is this big: 512² BGRA is 1 MiB, room for a screenful of
/// 64 px row thumbnails. Growing (up to `max_size`) is what a full-size
/// preview picture asks for; before 2026-10 every app paid 16 MiB for a
/// 2048² atlas even if it only ever drew 32 pt icons.
pub const min_size: u32 = 512;
/// The longest side a picture keeps.
pub const max_side: u32 = 1024;
const pad: u32 = 1;

pub const Entry = struct {
    uv: [4]f32,
    /// The picture's own size in pixels (before scaling down).
    width: u32,
    height: u32,
};

/// A picture decoded (or copied) and scaled down, kept so packing it again
/// is a copy.
pub const Decoded = struct {
    /// Its own size in pixels.
    width: u32,
    height: u32,
    /// The scaled pixels, `w` × `h`.
    w: u32,
    h: u32,
    bgra: []u8,
};

/// Where a picture comes from, the first time it is drawn: encoded bytes,
/// or pixels the app already has.
pub const Source = union(enum) {
    /// An encoded picture (PNG; on macOS and iOS anything ImageIO reads),
    /// kept by the caller while it is shown.
    encoded: []const u8,
    /// Pixels the app already has (a shell's thumbnail: `GetImage`'s
    /// HBITMAP), kept by the caller while it is shown.
    pixels: Pixels,

    /// BGRA8, premultiplied (as the atlas and `gpu.Texture` are), top row
    /// first, `stride` bytes a row.
    pub const Pixels = struct {
        bgra: []const u8,
        width: u32,
        height: u32,
        /// Bytes from one row's first pixel to the next's; 0 is
        /// `width * 4`.
        stride: usize = 0,
    };
};

/// Decoded pictures kept at most (the oldest go first).
const max_kept_bytes = 12 * 1024 * 1024;
/// Larger pictures are refused rather than copied (64 megapixels), as
/// `probeHeader` refuses encoded ones.
const max_pixels: u64 = 64 * 1024 * 1024;

/// Where packed pictures go instead of `pixels`: the GPU's texture, so no
/// copy of the atlas is kept in memory (a window on Metal).
pub const Sink = struct {
    ctx: *anyopaque,
    /// `side` is the atlas's own side now: it grows with the pictures, so a
    /// sink that keeps a texture must make it this large (and again when the
    /// number changes), not the `max_size` it used to assume.
    upload: *const fn (ctx: *anyopaque, side: u32, x: u32, y: u32, w: u32, h: u32, bgra: []const u8) void,
};

pub const SizedKey = struct {
    key: u64,
    side: u32,
};

pub const Info = struct {
    width: u32,
    height: u32,
};

const KeptEntry = struct {
    entry: ?Entry,
    last_frame: u64,
};

pub const SvgSpec = struct {
    width: u32,
    height: u32,
    /// `currentColor`, straight RGBA.
    current: [4]f32,
};

pub const Images = struct {
    gpa: std.mem.Allocator,
    /// Header dimensions per picture key (null: invalid image).
    headers: std.AutoHashMapUnmanaged(u64, ?Info) = .empty,
    /// Every picture decoded, by (key, target_side) (null: it can't be).
    decoded: std.AutoArrayHashMapUnmanaged(SizedKey, ?Decoded) = .empty,
    kept_bytes: usize = 0,
    /// Rows of `pixels` changed since the GPU's copy was made.
    dirty: ?[2]u32 = null,
    sink: ?Sink = null,
    /// BGRA, `side` × `side`; empty until a picture comes.
    pixels: []u8 = &.{},
    /// The atlas's side in pixels (0: not made yet). It grows to fit the
    /// biggest picture drawn so far, never past `max_size`.
    side: u32 = 0,
    entries: std.AutoHashMapUnmanaged(SizedKey, KeptEntry) = .empty,
    frame: u64 = 0,
    /// Pictures drawn from SVG (`ui.svg`), by key: the size and color they
    /// are drawn at, so they are drawn again the same if they're let go.
    svgs: std.AutoHashMapUnmanaged(u64, SvgSpec) = .empty,
    shelf_x: u32 = 0,
    shelf_y: u32 = 0,
    shelf_h: u32 = 0,
    /// Changes whenever the pixels do, for the GPU's copy.
    generation: u64 = 0,
    /// Bumped when it starts over: a picture may now be where another was.
    resets: u64 = 0,
    /// Emptied during a frame: its earlier pictures must be painted again.
    reset_during_frame: bool = false,
    decodes_left: u32 = 8,
    wants_frame: bool = false,

    pub fn deinit(im: *Images) void {
        if (im.pixels.len > 0) im.gpa.free(im.pixels);
        im.headers.deinit(im.gpa);
        im.entries.deinit(im.gpa);
        im.svgs.deinit(im.gpa);
        im.trimDecoded();
        im.decoded.deinit(im.gpa);
    }

    pub fn trimDecoded(im: *Images) void {
        for (im.decoded.values()) |d| if (d) |x| im.gpa.free(x.bgra);
        im.decoded.clearRetainingCapacity();
        im.kept_bytes = 0;
    }

    /// Called at the start of `paint`: compacts stale entries before any
    /// instance is emitted when the atlas is filling up.
    pub fn beginPaint(im: *Images) void {
        im.frame +%= 1;
        im.decodes_left = 8;
        im.wants_frame = false;
        if (im.side > 0 and im.shelf_y + im.shelf_h > im.side * 3 / 4) im.repackLive();
    }

    /// The picture `k`'s native dimensions (from `bytes` the first time), or
    /// null. Sizing a picture needs only this: it is decoded and packed when
    /// drawn.
    pub fn info(im: *Images, k: u64, src: Source) ?Info {
        switch (src) {
            .pixels => |p| return if (pixelsOk(p)) .{ .width = p.width, .height = p.height } else null,
            .encoded => |bytes| {
                if (im.headers.get(k)) |h| return h;
                if (im.headers.count() >= 2048) im.headers.clearRetainingCapacity();
                const h = probeHeader(bytes);
                im.headers.put(im.gpa, k, h) catch {};
                return h;
            },
        }
    }

    fn getDecoded(im: *Images, sk: SizedKey, src: Source) ?Decoded {
        if (im.decoded.get(sk)) |d| return d;
        const d: ?Decoded = switch (src) {
            .encoded => |bytes| if (im.svgs.get(sk.key)) |spec| drawSvg(im.gpa, bytes, spec) catch null else load(im.gpa, bytes, sk.side) catch null,
            .pixels => |p| if (pixelsOk(p)) loadPixels(im.gpa, p, sk.side) catch null else null,
        };
        if (d) |x| im.kept_bytes += x.bgra.len;
        im.decoded.put(im.gpa, sk, d) catch {
            if (d) |x| im.gpa.free(x.bgra);
            return null;
        };
        // Over budget: the oldest go (not this one); they decode again if
        // they are drawn again.
        var i: usize = 0;
        while (im.kept_bytes > max_kept_bytes and i + 1 < im.decoded.count()) {
            if (im.decoded.values()[i]) |x| {
                im.kept_bytes -= x.bgra.len;
                im.gpa.free(x.bgra);
                const old = im.decoded.keys()[i];
                im.decoded.orderedRemoveAt(i);
                _ = im.entries.remove(old);
            } else i += 1;
        }
        return d;
    }

    /// The SVG document `bytes` drawn at `spec`'s size and color, as
    /// picture `k`: decoded once, then packed when drawn like any other.
    pub fn infoSvg(im: *Images, k: u64, bytes: []const u8, spec: SvgSpec) ?Decoded {
        im.svgs.put(im.gpa, k, spec) catch return null;
        return im.getDecoded(.{ .key = k, .side = spec.width }, .{ .encoded = bytes });
    }

    /// The atlas as the CPU renderer reads it.
    pub fn pictures(im: *const Images) @import("raster.zig").Pictures {
        return .{ .pixels = im.pixels, .size = im.side };
    }

    pub fn key(name: []const u8) u64 {
        return std.hash.Wyhash.hash(0x1a9e, name);
    }

    /// The picture `k` in the atlas at `target_px`, packing it (decoding
    /// `src` the first time) when it is not there; null if it can't be read.
    /// The first source given for a key at a size is the one kept: new
    /// content needs a new key.
    pub fn get(im: *Images, k: u64, src: Source, target_px: u32) ?Entry {
        const side = std.math.clamp(target_px, 1, max_side);
        const sk: SizedKey = .{ .key = k, .side = side };
        if (im.entries.getPtr(sk)) |ke| {
            ke.last_frame = im.frame;
            return ke.entry;
        }
        if (!im.decoded.contains(sk)) {
            if (im.decodes_left == 0) {
                im.wants_frame = true;
                return null;
            }
            im.decodes_left -= 1;
        }
        const d = im.getDecoded(sk, src) orelse {
            im.entries.put(im.gpa, sk, .{ .entry = null, .last_frame = im.frame }) catch {};
            return null;
        };
        if (!im.fits(d.w, d.h)) im.repackLive();
        const e = im.pack(d) catch return null;
        im.entries.put(im.gpa, sk, .{ .entry = e, .last_frame = im.frame }) catch {};
        return e;
    }

    /// Evicts entries not drawn in the current or previous frame and repacks
    /// live ones from their cached decoded pixels.
    fn repackLive(im: *Images) void {
        var live: std.ArrayList(SizedKey) = .empty;
        defer live.deinit(im.gpa);
        var same_frame = false;
        var it = im.entries.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.entry == null) continue;
            if (kv.value_ptr.last_frame == im.frame) same_frame = true;
            if (kv.value_ptr.last_frame + 1 >= im.frame) live.append(im.gpa, kv.key_ptr.*) catch {};
        }
        im.empty();
        if (same_frame) im.reset_during_frame = true;
        for (live.items) |sk| {
            const d = (im.decoded.get(sk) orelse continue) orelse continue;
            if (!im.fits(d.w, d.h)) break;
            const e = im.pack(d) catch break;
            im.entries.put(im.gpa, sk, .{ .entry = e, .last_frame = im.frame }) catch break;
        }
    }
    fn pack(im: *Images, d: Decoded) !Entry {
        try im.ensureRoom(d.w + pad, d.h + pad);
        if (im.shelf_x + d.w + pad > im.side) {
            im.shelf_y += im.shelf_h + pad;
            im.shelf_x = 0;
            im.shelf_h = 0;
        }
        const x = im.shelf_x;
        const y = im.shelf_y;
        const side = im.side;
        if (im.sink) |sk| {
            sk.upload(sk.ctx, side, x, y, d.w, d.h, d.bgra);
        } else for (0..d.h) |row| {
            const src = d.bgra[row * d.w * 4 ..][0 .. d.w * 4];
            @memcpy(im.pixels[((y + row) * side + x) * 4 ..][0 .. d.w * 4], src);
        }
        im.shelf_x += d.w + pad;
        im.shelf_h = @max(im.shelf_h, d.h);
        im.generation +%= 1;
        im.dirty = if (im.dirty) |r| .{ @min(r[0], y), @max(r[1], y + d.h) } else .{ y, y + d.h };
        const s: f32 = @floatFromInt(side);
        return .{
            .uv = .{ @as(f32, @floatFromInt(x)) / s, @as(f32, @floatFromInt(y)) / s, @as(f32, @floatFromInt(x + d.w)) / s, @as(f32, @floatFromInt(y + d.h)) / s },
            .width = d.width,
            .height = d.height,
        };
    }

    /// Room for a `w` × `h` picture: the atlas starts at `min_size` and doubles
    /// until the picture fits (up to `max_size`). Growing moves every packed
    /// picture, so what was drawn before it must be painted again.
    fn ensureRoom(im: *Images, w: u32, h: u32) !void {
        if (im.side == 0) return im.resizeAtlas(if (w <= min_size and h <= min_size) min_size else growTo(0, w, h));
        if (w <= im.side and h <= im.side) return;
        try im.resizeAtlas(growTo(im.side, w, h));
    }

    fn growTo(from: u32, w: u32, h: u32) u32 {
        var n = @max(from, min_size);
        while (n < max_size and (w > n or h > n)) n *= 2;
        return n;
    }

    fn resizeAtlas(im: *Images, side: u32) !void {
        const had = im.side != 0;
        if (im.sink == null) {
            const px = try im.gpa.alloc(u8, @as(usize, side) * side * 4);
            @memset(px, 0);
            if (im.pixels.len > 0) im.gpa.free(im.pixels);
            im.pixels = px;
        }
        im.side = side;
        im.generation +%= 1;
        im.dirty = null;
        if (had) {
            // Every earlier uv points somewhere else now.
            im.entries.clearRetainingCapacity();
            im.shelf_x = 0;
            im.shelf_y = 0;
            im.shelf_h = 0;
            im.resets +%= 1;
            im.reset_during_frame = true;
        }
    }

    fn fits(im: *const Images, w: u32, h: u32) bool {
        if (im.shelf_x + w + pad <= im.side) return im.shelf_y + @max(im.shelf_h, h) <= im.side;
        return im.shelf_y + im.shelf_h + pad + h <= im.side;
    }

    fn empty(im: *Images) void {
        im.entries.clearRetainingCapacity();
        im.shelf_x = 0;
        im.shelf_y = 0;
        im.shelf_h = 0;
        im.resets +%= 1;
    }
};

fn probeHeader(bytes: []const u8) ?Info {
    if (!portable) {
        const d = imageio.dimensions(bytes) orelse return null;
        return .{ .width = d.width, .height = d.height };
    }
    if (bytes.len >= 24 and std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n") and std.mem.eql(u8, bytes[12..16], "IHDR")) {
        const w = std.mem.readInt(u32, bytes[16..20], .big);
        const h = std.mem.readInt(u32, bytes[20..24], .big);
        if (w > 0 and h > 0 and @as(u64, w) * h <= 64 * 1024 * 1024) return .{ .width = w, .height = h };
    }
    return null;
}

fn drawSvg(gpa: std.mem.Allocator, bytes: []const u8, spec: SvgSpec) !Decoded {
    const px = try @import("svg.zig").render(gpa, bytes, .{ .width = spec.width, .height = spec.height, .current = spec.current });
    return .{ .width = spec.width, .height = spec.height, .w = spec.width, .h = spec.height, .bgra = px };
}

const Raw = struct { width: u32, height: u32, bgra: []u8 };

/// Decodes and scales a picture to keep.
fn load(gpa: std.mem.Allocator, bytes: []const u8, side: u32) !Decoded {
    if (!portable) {
        const f = try imageio.decodeFit(gpa, bytes, @min(side, max_side));
        return .{ .width = f.width, .height = f.height, .w = f.w, .h = f.h, .bgra = f.bgra };
    }
    const d = try decode(gpa, bytes);
    const scaled = fit(gpa, d.bgra, d.width, d.height, @min(side, max_side)) catch |e| {
        gpa.free(d.bgra);
        return e;
    };
    if (scaled.bgra.ptr != d.bgra.ptr) gpa.free(d.bgra);
    return .{ .width = d.width, .height = d.height, .w = scaled.w, .h = scaled.h, .bgra = scaled.bgra };
}

/// Whether `p` holds a whole picture: `height` rows of at least `width * 4`
/// bytes, no more than 64 megapixels.
fn pixelsOk(p: Source.Pixels) bool {
    const w: u64 = p.width;
    const h: u64 = p.height;
    if (w == 0 or h == 0 or w * h > max_pixels) return false;
    const stride: u64 = if (p.stride == 0) w * 4 else @intCast(p.stride);
    if (stride < w * 4 or stride > max_pixels * 4) return false;
    return @as(u64, p.bgra.len) >= (h - 1) * stride + w * 4;
}

/// Copies `p`'s rows apart from the stride, then scales it down to `side`:
/// the same pixels `load` gives for an encoded picture of the same size.
fn loadPixels(gpa: std.mem.Allocator, p: Source.Pixels, side: u32) !Decoded {
    const w: usize = p.width;
    const h: usize = p.height;
    const stride: usize = if (p.stride == 0) w * 4 else p.stride;
    const tight = w * 4;
    const pixels = try gpa.alloc(u8, tight * h);
    errdefer gpa.free(pixels);
    if (stride == tight) {
        @memcpy(pixels, p.bgra[0..tight * h]);
    } else for (0..h) |y| {
        @memcpy(pixels[y * tight ..][0..tight], p.bgra[y * stride ..][0..tight]);
    }
    const scaled = try fit(gpa, pixels, p.width, p.height, @min(side, max_side));
    if (scaled.bgra.ptr != pixels.ptr) gpa.free(pixels);
    return .{ .width = p.width, .height = p.height, .w = scaled.w, .h = scaled.h, .bgra = scaled.bgra };
}

fn decode(gpa: std.mem.Allocator, bytes: []const u8) !Raw {
    if (!portable) {
        const d = try imageio.decode(gpa, bytes);
        return .{ .width = d.width, .height = d.height, .bgra = d.bgra };
    }
    const d = try png_decode.decode(gpa, bytes);
    return .{ .width = d.width, .height = d.height, .bgra = d.bgra };
}

const Scaled = struct { w: u32, h: u32, bgra: []u8 };

/// The picture within `max_side`, averaging the pixels each new one covers.
fn fit(gpa: std.mem.Allocator, bgra: []u8, w: u32, h: u32, limit: u32) !Scaled {
    const longest = @max(w, h);
    if (longest <= limit) return .{ .w = w, .h = h, .bgra = bgra };
    const nw = @max(1, w * limit / longest);
    const nh = @max(1, h * limit / longest);
    const out = try gpa.alloc(u8, nw * nh * 4);
    for (0..nh) |y| {
        const sy0 = y * h / nh;
        const sy1 = @max(sy0 + 1, (y + 1) * h / nh);
        for (0..nw) |x| {
            const sx0 = x * w / nw;
            const sx1 = @max(sx0 + 1, (x + 1) * w / nw);
            var acc: [4]u32 = .{ 0, 0, 0, 0 };
            for (sy0..sy1) |sy| for (sx0..sx1) |sx| {
                const p = bgra[(sy * w + sx) * 4 ..][0..4];
                for (0..4) |k| acc[k] += p[k];
            };
            const n: u32 = @intCast((sy1 - sy0) * (sx1 - sx0));
            for (0..4) |k| out[(y * nw + x) * 4 + k] = @intCast(acc[k] / n);
        }
    }
    return .{ .w = nw, .h = nh, .bgra = out };
}

test "pictures pack, scale down and come back by key" {
    const gpa = std.testing.allocator;
    var im: Images = .{ .gpa = gpa };
    defer im.deinit();
    // A 2×1 PNG, red then half-transparent blue.
    var px = [_]u8{ 0, 0, 255, 255, 128, 0, 0, 128 };
    const bytes = try @import("png.zig").encode(gpa, .{ .bytes = &px, .width = 2, .height = 1 });
    defer gpa.free(bytes);
    const e = im.get(Images.key("a.png"), .{ .encoded = bytes }, max_side).?;
    try std.testing.expectEqual(@as(u32, 2), e.width);
    try std.testing.expectEqualSlices(u8, &px, im.pixels[0..8]);
    const gen = im.generation;
    _ = im.get(Images.key("a.png"), .{ .encoded = bytes }, max_side);
    try std.testing.expectEqual(gen, im.generation);
    try std.testing.expect(im.get(Images.key("bad"), .{ .encoded = "not an image" }, max_side) == null);
    // Too big: averaged down to the longest side.
    const big = try gpa.alloc(u8, 2048 * 2 * 4);
    defer gpa.free(big);
    @memset(big, 200);
    const s = try fit(gpa, big, 2048, 2, max_side);
    defer gpa.free(s.bgra);
    try std.testing.expectEqual(@as(u32, 1024), s.w);
    try std.testing.expectEqual(@as(u32, 1), s.h);
    try std.testing.expectEqual(@as(u8, 200), s.bgra[0]);
}

test "raw pixels pack with their stride, and a key keeps its first picture" {
    const gpa = std.testing.allocator;
    var im: Images = .{ .gpa = gpa };
    defer im.deinit();
    // A 2×2 picture, two pixels of padding after each row.
    var buf = [_]u8{
        10, 20,  30, 255, 40, 50,  60, 255, 0, 0, 0, 0, 0, 0, 0, 0,
        70, 80,  90, 128, 100, 110, 120, 128, 0, 0, 0, 0, 0, 0, 0, 0,
    };
    const source: Source = .{ .pixels = .{ .bgra = &buf, .width = 2, .height = 2, .stride = 16 } };
    const k = Images.key("raw");
    try std.testing.expectEqual(Info{ .width = 2, .height = 2 }, im.info(k, source).?);
    const e = im.get(k, source, 2).?;
    try std.testing.expectEqual(@as(u32, 2), e.width);
    try std.testing.expectEqualSlices(u8, buf[0..8], im.pixels[0..8]);
    try std.testing.expectEqualSlices(u8, buf[16..24], im.pixels[im.side * 4 ..][0..8]);
    // The first source a key gives wins: changing the pixels changes nothing.
    @memset(buf[0..32], 7);
    _ = im.get(k, source, 2);
    try std.testing.expectEqual(@as(u8, 10), im.pixels[0]);
    // A buffer too short for its rows, or a stride shorter than a row, is refused.
    try std.testing.expect(im.info(Images.key("short"), .{ .pixels = .{ .bgra = buf[0..8], .width = 2, .height = 2 } }) == null);
    try std.testing.expect(im.info(Images.key("stride"), .{ .pixels = .{ .bgra = &buf, .width = 2, .height = 2, .stride = 4 } }) == null);
    try std.testing.expect(im.info(Images.key("empty"), .{ .pixels = .{ .bgra = &.{}, .width = 0, .height = 2 } }) == null);
}
