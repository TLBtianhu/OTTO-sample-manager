//! The font scan's result kept between starts: which file and face each
//! family name, weight and slant came from.
//!
//! A cache describes one font folder and one build: a digest of the folder
//! (its mtime, the number of font files, and each font file's mtime and
//! size) says whether the folder still holds what the cache describes, and
//! the format number and the nanoui version say whether the bytes still
//! mean what this build reads. Anything else — another folder, a changed
//! file, a bad checksum, a short file, an older build — reads as "no
//! cache": the caller scans again and writes a new one. A damaged cache
//! never changes the faces text gets; it only costs the scan once.
//!
//! Off unless the app asks, by giving both a cache path and the folder it
//! describes (`fontdb.Db.cache_path` / `fonts_dir`). The cache file must
//! live outside that folder: writing it would change the folder's mtime and
//! with it the very digest the cache is checked against.
const std = @import("std");
const builtin = @import("builtin");
const font = @import("font.zig");
const win = @import("fontindex_win.zig");

/// The bytes' layout: bump it when a field or its meaning changes.
pub const format_version: u32 = 1;
/// The build that wrote the cache. An upgrade may change what a face's
/// style means, so the cache goes with it (build.zig.zon's version).
const nanoui_version = @import("build_options").version;

const magic = "NUFI";
const seed: u64 = 0x4e554649; // "NUFI"
const max_cache_bytes: usize = 8 << 20;
const max_entries: usize = 1 << 16;
const max_path_bytes: usize = 4096;
const max_family_bytes: usize = 64;

/// A face the cache holds: a font file (the path is the reader's) and the
/// index of its face in that file.
pub const Entry = struct {
    path: []u8,
    index: u32,
    style: font.Style,
};

/// What a cache lookup did, for a trace line or a test.
pub const State = enum {
    /// The app gave no cache path or no folder: the scan runs every start.
    off,
    /// The cache matched the folder and this build; it was used.
    hit,
    /// There was no cache file (first start, or one that was deleted).
    miss,
    /// The cache is for another folder/digest or another version.
    stale,
    /// The bytes are not a cache (short, bad magic, bad checksum, junk):
    /// the scan runs and writes a new one.
    damaged,
    /// The folder could not be read, so neither the cache nor a scan.
    unreadable,
    /// The scan ran and its result was written.
    written,
    /// The scan ran but the result could not be written (read-only folder,
    /// no space): the next start scans again.
    write_failed,
};

pub const Stats = struct {
    state: State = .off,
    /// Faces the cache held (on `hit`) or the scan wrote (on `written`).
    faces: usize = 0,
    /// The cache file's size.
    bytes: usize = 0,
    /// The lookup and the write, as measured by the caller (only while
    /// `ui.trace` is on).
    ms: f64 = 0,
};

pub const ReadError = error{ NotFound, Damaged, Stale, Unreadable, OutOfMemory };

/// A digest of the folder the cache describes: its own mtime, the number of
/// font files in it (recursively), and each font file's path, mtime and
/// size. Order-independent, so an enumeration order that changes between
/// starts does not look like a change. Null when the folder cannot be read.
pub fn fingerprint(allocator: std.mem.Allocator, io: std.Io, fonts_dir: []const u8) ?u64 {
    var dir = std.Io.Dir.cwd().openDir(io, fonts_dir, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    const meta = dir.stat(io) catch return null;
    const mtime = meta.mtime.nanoseconds;
    var sum: u64 = std.hash.Wyhash.hash(seed, std.mem.asBytes(&mtime));
    // Windows' FindFirstFileW already reports each entry's mtime and size:
    // one enumeration instead of an open/stat/close per file (measured
    // 15 ms for 372 fonts the portable way, 0.5 ms this way). A folder with
    // subfolders takes the portable walk below.
    if (builtin.os.tag == .windows) {
        if (win.fingerprint(allocator, fonts_dir, &sum)) |_| {
            return sum;
        } else |_| {}
    }
    if (!walkFingerprint(allocator, io, dir, &sum)) return null;
    return sum;
}

/// The portable digest: a recursive walk, a stat per folder and per font.
fn walkFingerprint(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, sum: *u64) bool {
    var walker = dir.walk(allocator) catch return false;
    defer walker.deinit();
    var count: usize = 0;
    while (true) {
        const next = walker.next(io) catch return false;
        const e = next orelse break;
        var h = std.hash.Wyhash.init(seed);
        h.update(e.path);
        const kind: u8 = @intFromEnum(e.kind);
        h.update(std.mem.asBytes(&kind));
        switch (e.kind) {
            .directory => {
                const st = dir.statFile(io, e.path, .{}) catch return false;
                h.update(std.mem.asBytes(&st.mtime.nanoseconds));
                sum.* +%= h.final();
            },
            .file, .sym_link => {
                if (!isFontName(e.basename)) continue;
                const st = dir.statFile(io, e.path, .{}) catch return false;
                // A link to a folder is a folder: its contents count too.
                if (st.kind == .directory) {
                    h.update(std.mem.asBytes(&st.mtime.nanoseconds));
                    sum.* +%= h.final();
                    continue;
                }
                h.update(std.mem.asBytes(&st.mtime.nanoseconds));
                h.update(std.mem.asBytes(&st.size));
                sum.* +%= h.final();
                count += 1;
            },
            else => {},
        }
    }
    sum.* +%= std.hash.Wyhash.hash(seed, std.mem.asBytes(&count));
    return true;
}

/// Whether a name would be scanned as a font: the scan's own extension
/// filter, so the digest covers exactly the files that become faces.
fn isFontName(name: []const u8) bool {
    const ext = std.fs.path.extension(name);
    return std.ascii.eqlIgnoreCase(ext, ".ttf") or std.ascii.eqlIgnoreCase(ext, ".ttc");
}

/// Whether a cache at `cache_path` describes `fonts_dir` at `digest`, and
/// what it holds. The returned entries and their paths are the caller's;
/// free them with `freeEntries`. Every kind of damage is an error, never a
/// partial list.
pub fn read(
    gpa: std.mem.Allocator,
    io: std.Io,
    cache_path: []const u8,
    fonts_dir: []const u8,
    digest: u64,
) ReadError![]Entry {
    const data = std.Io.Dir.cwd().readFileAlloc(io, cache_path, gpa, .limited(max_cache_bytes)) catch |err| switch (err) {
        error.FileNotFound => return error.NotFound,
        error.StreamTooLong => return error.Damaged,
        else => return error.Unreadable,
    };
    defer gpa.free(data);
    if (data.len < 8) return error.Damaged;
    const body = data[0 .. data.len - 8];
    const stored_sum = std.mem.readInt(u64, data[data.len - 8 ..][0..8], .little);
    if (std.hash.Wyhash.hash(seed, body) != stored_sum) return error.Damaged;

    var r: Reader = .{ .data = body };
    if (!std.mem.eql(u8, try r.take(4), magic)) return error.Damaged;
    if (try r.readU32() != format_version) return error.Stale;
    const version = try r.take(try r.readU8());
    if (!std.mem.eql(u8, version, nanoui_version)) return error.Stale;
    const dir = try r.take(try r.readU16());
    if (!std.mem.eql(u8, dir, fonts_dir)) return error.Stale;
    if (try r.readU64() != digest) return error.Stale;
    const count = try r.readU32();
    if (count > max_entries) return error.Damaged;

    const entries = try gpa.alloc(Entry, count);
    var made: usize = 0;
    errdefer {
        for (entries[0..made]) |e| gpa.free(e.path);
        gpa.free(entries);
    }
    while (made < count) : (made += 1) {
        const path_len = try r.readU16();
        if (path_len == 0 or path_len > max_path_bytes) return error.Damaged;
        const path = try gpa.dupe(u8, try r.take(path_len));
        errdefer gpa.free(path);
        const index = try r.readU32();
        const family_len = try r.readU8();
        if (family_len > max_family_bytes) return error.Damaged;
        var style: font.Style = .{};
        const family = try r.take(family_len);
        @memcpy(style.family[0..family_len], family);
        style.family_len = family_len;
        style.weight = try r.readU16();
        const flags = try r.readU8();
        if (flags & ~@as(u8, 0x03) != 0) return error.Damaged;
        style.italic = flags & 1 != 0;
        style.mono = flags & 2 != 0;
        entries[made] = .{ .path = path, .index = index, .style = style };
    }
    if (r.at != body.len) return error.Damaged;
    return entries;
}

/// Writes `faces` (anything with `.path`, `.index`, `.style`) as the cache
/// for `fonts_dir` at `digest`; the bytes, or null when they could not be
/// written (a cache is an optimization: never an error). The write is
/// atomic (temp file + rename), so a crash mid-write leaves no half cache.
pub fn write(
    gpa: std.mem.Allocator,
    io: std.Io,
    cache_path: []const u8,
    fonts_dir: []const u8,
    digest: u64,
    faces: anytype,
) ?usize {
    if (fonts_dir.len > std.math.maxInt(u16) or nanoui_version.len > std.math.maxInt(u8)) return null;
    var body: usize = 4 + 4 + 1 + nanoui_version.len + 2 + fonts_dir.len + 8 + 4;
    var count: usize = 0;
    for (faces) |f| {
        if (f.path.len == 0 or f.path.len > max_path_bytes or f.style.family_len > max_family_bytes) return null;
        body += 2 + f.path.len + 4 + 1 + f.style.family_len + 2 + 1;
        count += 1;
    }
    if (count > max_entries or body + 8 > max_cache_bytes) return null;

    const data = gpa.alloc(u8, body + 8) catch return null;
    defer gpa.free(data);
    var c: Cursor = .{ .data = data };
    c.bytes(magic);
    c.addU32(format_version);
    c.addU8(@intCast(nanoui_version.len));
    c.bytes(nanoui_version);
    c.addU16(@intCast(fonts_dir.len));
    c.bytes(fonts_dir);
    c.addU64(digest);
    c.addU32(@intCast(count));
    for (faces) |f| {
        c.addU16(@intCast(f.path.len));
        c.bytes(f.path);
        c.addU32(f.index);
        c.addU8(f.style.family_len);
        c.bytes(f.style.family[0..f.style.family_len]);
        c.addU16(f.style.weight);
        c.addU8(@as(u8, @intFromBool(f.style.italic)) | @as(u8, @intFromBool(f.style.mono)) << 1);
    }
    std.debug.assert(c.at == body);
    std.mem.writeInt(u64, data[body..][0..8], std.hash.Wyhash.hash(seed, data[0..body]), .little);

    writeAtomically(io, cache_path, data) catch return null;
    return data.len;
}

fn writeAtomically(io: std.Io, cache_path: []const u8, bytes: []const u8) !void {
    var af = try std.Io.Dir.cwd().createFileAtomic(io, cache_path, .{ .replace = true, .make_path = true });
    defer af.deinit(io);
    try af.file.writeStreamingAll(io, bytes);
    try af.replace(io);
}

/// Frees entries `read` returned: their paths, then their array.
pub fn freeEntries(gpa: std.mem.Allocator, entries: []Entry) void {
    for (entries) |e| gpa.free(e.path);
    gpa.free(entries);
}

const Cursor = struct {
    data: []u8,
    at: usize = 0,

    fn bytes(c: *Cursor, s: []const u8) void {
        @memcpy(c.data[c.at..][0..s.len], s);
        c.at += s.len;
    }
    fn addU8(c: *Cursor, v: u8) void {
        c.data[c.at] = v;
        c.at += 1;
    }
    fn addU16(c: *Cursor, v: u16) void {
        std.mem.writeInt(u16, c.data[c.at..][0..2], v, .little);
        c.at += 2;
    }
    fn addU32(c: *Cursor, v: u32) void {
        std.mem.writeInt(u32, c.data[c.at..][0..4], v, .little);
        c.at += 4;
    }
    fn addU64(c: *Cursor, v: u64) void {
        std.mem.writeInt(u64, c.data[c.at..][0..8], v, .little);
        c.at += 8;
    }
};

const Reader = struct {
    data: []const u8,
    at: usize = 0,

    fn take(r: *Reader, n: usize) error{Damaged}![]const u8 {
        if (r.at > r.data.len or n > r.data.len - r.at) return error.Damaged;
        const s = r.data[r.at..][0..n];
        r.at += n;
        return s;
    }
    fn readU8(r: *Reader) error{Damaged}!u8 {
        return (try r.take(1))[0];
    }
    fn readU16(r: *Reader) error{Damaged}!u16 {
        return std.mem.readInt(u16, (try r.take(2))[0..2], .little);
    }
    fn readU32(r: *Reader) error{Damaged}!u32 {
        return std.mem.readInt(u32, (try r.take(4))[0..4], .little);
    }
    fn readU64(r: *Reader) error{Damaged}!u64 {
        return std.mem.readInt(u64, (try r.take(8))[0..8], .little);
    }
};

// ---------------------------------------------------------------------------
// Tests: serialization and the folder digest; no system fonts are touched.
// ---------------------------------------------------------------------------

const testing = std.testing;

fn testStyle(family: []const u8, weight: u16, italic: bool, mono: bool) font.Style {
    var s: font.Style = .{};
    @memcpy(s.family[0..family.len], family);
    s.family_len = @intCast(family.len);
    s.weight = weight;
    s.italic = italic;
    s.mono = mono;
    return s;
}

test "a written cache reads back with the same faces" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(testing.io, &path_buffer);
    const dir = path_buffer[0..len];
    const cache_path = try std.fs.path.join(gpa, &.{ dir, "cache", "fonts.idx" });
    defer gpa.free(cache_path);

    const family = "Test Sans";
    const faces = [_]struct { path: []const u8, index: u32, style: font.Style }{
        .{ .path = "C:\\fonts\\a.ttf", .index = 0, .style = testStyle(family, 400, false, false) },
        .{ .path = "C:\\fonts\\b.ttc", .index = 3, .style = testStyle("Test Mono", 700, true, true) },
    };
    const digest: u64 = 0x1234_5678_9abc_def0;
    // The parent folder does not exist yet: writing creates it.
    const bytes = write(gpa, testing.io, cache_path, "C:\\Windows\\Fonts", digest, &faces) orelse return error.WriteFailed;
    try testing.expect(bytes > 0);

    const entries = try read(gpa, testing.io, cache_path, "C:\\Windows\\Fonts", digest);
    defer freeEntries(gpa, entries);
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqualStrings("C:\\fonts\\a.ttf", entries[0].path);
    try testing.expectEqual(@as(u32, 0), entries[0].index);
    try testing.expectEqualStrings(family, entries[0].style.name());
    try testing.expectEqual(@as(u16, 400), entries[0].style.weight);
    try testing.expect(!entries[0].style.italic and !entries[0].style.mono);
    try testing.expectEqual(@as(u32, 3), entries[1].index);
    try testing.expectEqualStrings("Test Mono", entries[1].style.name());
    try testing.expectEqual(@as(u16, 700), entries[1].style.weight);
    try testing.expect(entries[1].style.italic and entries[1].style.mono);
}

test "another digest, folder or version reads as stale; junk as damaged" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(testing.io, &path_buffer);
    const dir = path_buffer[0..len];
    const cache_path = try std.fs.path.join(gpa, &.{ dir, "fonts.idx" });
    defer gpa.free(cache_path);
    const faces = [_]struct { path: []const u8, index: u32, style: font.Style }{
        .{ .path = "C:\\fonts\\a.ttf", .index = 0, .style = testStyle("Test Sans", 400, false, false) },
    };
    _ = write(gpa, testing.io, cache_path, "C:\\Windows\\Fonts", 111, &faces) orelse return error.WriteFailed;

    try testing.expectError(error.Stale, read(gpa, testing.io, cache_path, "C:\\Windows\\Fonts", 222));
    try testing.expectError(error.Stale, read(gpa, testing.io, cache_path, "D:\\Other", 111));
    const missing = try std.fs.path.join(gpa, &.{ dir, "no-such-fonts.idx" });
    defer gpa.free(missing);
    try testing.expectError(error.NotFound, read(gpa, testing.io, missing, "C:\\Windows\\Fonts", 111));

    const good = try std.Io.Dir.cwd().readFileAlloc(testing.io, cache_path, gpa, .limited(1 << 20));
    defer gpa.free(good);
    try testing.expect(good.len > 20);

    // One flipped byte anywhere: the checksum catches it.
    const flipped = try gpa.dupe(u8, good);
    defer gpa.free(flipped);
    flipped[flipped.len / 2] ^= 0x40;
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = cache_path, .data = flipped });
    try testing.expectError(error.Damaged, read(gpa, testing.io, cache_path, "C:\\Windows\\Fonts", 111));

    // A truncated file is damage too, not a smaller cache.
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = cache_path, .data = good[0 .. good.len - 3] });
    try testing.expectError(error.Damaged, read(gpa, testing.io, cache_path, "C:\\Windows\\Fonts", 111));
}

test "the folder digest follows font files' names, sizes and mtimes" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(testing.io, &path_buffer);
    const dir = path_buffer[0..len];

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ttf", .data = "one" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b.TTC", .data = "two" });
    const first = fingerprint(gpa, testing.io, dir) orelse return error.NoFingerprint;
    try testing.expectEqual(first, fingerprint(gpa, testing.io, dir).?);

    // The same names and sizes, but one file's mtime moved: a rebuild.
    // (The file's own timestamp call: `Dir.setTimestamps` has no Windows
    // implementation yet, and this test runs on Windows first.)
    var a = try tmp.dir.openFile(testing.io, "a.ttf", .{ .mode = .read_write });
    defer a.close(testing.io);
    try a.setTimestamps(testing.io, .{
        .modify_timestamp = .{ .new = .{ .nanoseconds = 1_700_000_000_000_000_000 } },
    });
    const moved = fingerprint(gpa, testing.io, dir) orelse return error.NoFingerprint;
    try testing.expect(first != moved);

    // A new font file changes the digest: the digest covers the files a scan
    // would read, by name, size and mtime. (`c.ttf`, not something the scan
    // ignores: the entry that changes must be the one the digest describes.
    // The fork's test wrote a `.otf` here and saw a change anyway, because
    // writing any file bumps the folder's own mtime, which the digest also
    // carries — true on Windows only as long as NTFS updates it at once, and
    // this failed here once.)
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "c.ttf", .data = "not read by a scan" });
    const after_c = fingerprint(gpa, testing.io, dir) orelse return error.NoFingerprint;
    try testing.expect(moved != after_c);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "d.ttf", .data = "three" });
    const after_d = fingerprint(gpa, testing.io, dir) orelse return error.NoFingerprint;
    try testing.expect(after_c != after_d);

    // ... as does the same file with different bytes (a new size).
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "d.ttf", .data = "three and more" });
    const grown = fingerprint(gpa, testing.io, dir) orelse return error.NoFingerprint;
    try testing.expect(after_d != grown);
}

