//! The fonts installed: found in the system's font folders once, each
//! face known by its family, weight, italics and width, and loaded when
//! first used. Matching a style picks the family's nearest face; a
//! character a font lacks is found in the fallback families, then in any
//! face that has it.
const std = @import("std");
const builtin = @import("builtin");
const font = @import("font.zig");
const fontindex = @import("fontindex.zig");
const fontmap = @import("fontmap.zig");
const trace = @import("../trace.zig");

/// A face's bytes; `fontmap` maps them read-only instead of copying when it can.
const Bytes = fontmap.Bytes;
const mapFile = fontmap.mapFile;
const freeBytes = fontmap.freeBytes;

/// What the last `scan` cost, split by phase. Filled only while
/// `ui.trace` is on (otherwise every counter stays zero and no clock is
/// read); printed by the scan's own `font.scan` mark, and readable by an
/// app that wants the numbers without the log.
pub const ScanStats = struct {
    /// Directory entries visited (files and links, before the extension
    /// filter), files read, and faces found.
    entries: usize = 0,
    files: usize = 0,
    faces: usize = 0,
    dirs: usize = 0,
    /// Enumerating the directories, opening and measuring the files,
    /// reading their headers, the extra table reads, and parsing the
    /// family/style records.
    walk_ms: f64 = 0,
    open_ms: f64 = 0,
    header_ms: f64 = 0,
    table_ms: f64 = 0,
    style_ms: f64 = 0,
    /// The rest of a file's pass: mapping, parsing the table directory.
    alloc_ms: f64 = 0,
    parse_ms: f64 = 0,
    /// The furthest byte any font made a scan read, when the face's
    /// records were past the header window (what the small buffer sizes
    /// were chosen against).
    max_end: usize = 0,
};

/// A stopwatch that costs nothing when `ui.trace` is off: one test at
/// construction, `lap` returns 0 and reads no clock.
const Lap = struct {
    traced: bool,
    at: f64,

    fn init() Lap {
        const traced = trace.on();
        return .{ .traced = traced, .at = if (traced) trace.stamp() else 0 };
    }

    fn lap(self: *Lap) f64 {
        if (!self.traced) return 0;
        const now = trace.stamp();
        const ms = (now - self.at) * 1000;
        self.at = now;
        return ms;
    }
};

pub const Face = struct {
    path: []const u8,
    index: u32,
    style: font.Style,
    /// A font the app brought (`ui.registerFont`): its bytes, not a file.
    memory: ?[]const u8 = null,

    fn read(f: Face, db: *Db) ?Bytes {
        if (f.memory) |m| {
            const copy = db.gpa.dupe(u8, m) catch return null;
            return .{ .data = copy };
        }
        if (mapFile(f.path)) |mapped| return mapped;
        const data = std.Io.Dir.cwd().readFileAlloc(db.io, f.path, db.gpa, .limited(256 << 20)) catch return null;
        return .{ .data = data };
    }
};

const Loaded = struct {
    data: []u8,
    mapped: bool = false,
    font: font.Font,
};

const android = builtin.abi.isAndroid();
/// How much of a font file a scan reads whole: its table directory, which
/// every face starts from, and the head/OS-2/name records that usually sit
/// beside it. Anything past this is read where its table says it is.
const scan_window: usize = 64 * 1024;
/// The tables a scan reads to know a face's family, weight and italics.
const scan_tables = [_][]const u8{ "head", "os2", "name" };
/// The most of a name table a scan reads into its small buffer: records
/// come first, and a damaged directory may claim any length.
const max_name_read: usize = 1 << 20;
/// Families tried when the theme names none (or one not installed):
/// Android's own first there.
const sans = (if (android) [_][]const u8{"Roboto"} else [_][]const u8{}) ++ [_][]const u8{ "Inter", "Geist", "Segoe UI", "Noto Sans", "Cantarell", "Ubuntu", "DejaVu Sans", "Liberation Sans", "Arial", "Helvetica" };
const monos = (if (android) [_][]const u8{ "Droid Sans Mono", "Cutive Mono" } else [_][]const u8{}) ++ [_][]const u8{ "JetBrains Mono", "Geist Mono", "Cascadia Mono", "Consolas", "Noto Sans Mono", "DejaVu Sans Mono", "Ubuntu Mono", "Liberation Mono", "Menlo", "Courier New" };
/// Families a CJK string needs when the UI family has no glyph for it:
/// Windows, macOS and Linux each name theirs. Kept ahead of the symbol
/// fallbacks so a hanzi never lands in a partial-coverage font.
const cjk = [_][]const u8{ "Microsoft YaHei UI", "Microsoft YaHei", "PingFang SC", "Hiragino Sans GB", "Noto Sans CJK SC", "Noto Sans SC", "Source Han Sans SC", "SimSun", "MS Gothic" };
/// Where characters a font lacks are looked for first.
const fallbacks = cjk ++ [_][]const u8{ "Noto Sans", "DejaVu Sans", "Segoe UI Symbol", "Noto Sans Symbols", "Noto Sans Symbols2", "Arial Unicode MS", "Symbola" };

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

fn env(name: [*:0]const u8) ?[]const u8 {
    if (builtin.os.tag == .windows) return null;
    const v = getenv(name) orelse return null;
    return std.mem.span(v);
}

pub const Db = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    faces: std.ArrayList(Face) = .empty,
    loaded: std.AutoHashMapUnmanaged(u32, *Loaded) = .empty,
    scanned: bool = false,
    /// Characters' fallback faces, found once (null: none has it).
    found: std.AutoHashMapUnmanaged(u21, ?u32) = .empty,
    /// How many of the app's fonts (`font_registry`) are added.
    bundled: usize = 0,
    /// What the last `scan` cost, per phase (zeros unless traced).
    scan_stats: ScanStats = .{},
    /// Fonts read from disk and parsed, first-use fallback lookups, and
    /// what they cost (zeros unless traced).
    loads: usize = 0,
    load_ms: f64 = 0,
    fallback_searches: usize = 0,
    fallback_ms: f64 = 0,
    /// One reused buffer for reading the parts of a font a scan needs,
    /// sized for the largest file seen (`page_allocator`, freed with the
    /// database). Allocating a whole file per font instead cost more than
    /// reading it: 69 ms of commits and 35 ms of releases over 372 files.
    file_buf: []u8 = &.{},
    /// Where the scan's result is kept between starts, and the folder it
    /// describes (both borrowed; null: no cache, the platform's folders).
    /// The app chooses the path; without both, a scan runs every start,
    /// exactly as before this cache existed.
    cache_path: ?[]const u8 = null,
    fonts_dir: ?[]const u8 = null,
    /// What the last scan's cache lookup and write cost and found.
    cache: fontindex.Stats = .{},
    /// The folder digest the lookup computed, reused by the write so the
    /// first start enumerates the folder once, not twice.
    cache_digest: ?u64 = null,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) Db {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(db: *Db) void {
        for (db.faces.items) |f| db.gpa.free(f.path);
        db.faces.deinit(db.gpa);
        var it = db.loaded.valueIterator();
        while (it.next()) |l| {
            freeBytes(db.gpa, .{ .data = l.*.data, .mapped = l.*.mapped });
            db.gpa.destroy(l.*);
        }
        db.loaded.deinit(db.gpa);
        db.found.deinit(db.gpa);
        if (db.file_buf.len > 0) std.heap.page_allocator.free(db.file_buf);
    }

    /// Adds the faces of fonts the app registered since last asked.
    fn addBundled(db: *Db) void {
        const all = @import("../font_registry.zig").registered();
        while (db.bundled < all.len) : (db.bundled += 1) db.addMemory(all[db.bundled]);
    }

    /// Adds the faces of a font file's bytes, kept by the caller.
    pub fn addMemory(db: *Db, data: []const u8) void {
        for (0..font.faces(data)) |i| {
            const t = font.Tables.read(data, i) catch continue;
            const style = font.Style.read(data, t);
            if (style.family_len == 0) continue;
            const owned = db.gpa.dupe(u8, "") catch return;
            db.faces.append(db.gpa, .{ .path = owned, .index = @intCast(i), .style = style, .memory = data }) catch db.gpa.free(owned);
        }
    }

    /// Adds the faces of the fonts in the system's font folders, after
    /// those the app brought.
    pub fn scan(db: *Db) void {
        db.addBundled();
        if (db.scanned) return;
        db.scanned = true;
        const traced = trace.on();
        if (traced) {
            db.scan_stats = .{};
            trace.mark("font.scan.start");
        }
        if (db.loadCached()) {
            db.traceScan();
            db.traceCache();
            return;
        }
        db.scanFonts();
        db.traceScan();
        db.saveCached();
        db.traceCache();
    }

    /// The folders a scan reads: the one the cache describes when the app
    /// named it (so the cache and the scan always mean the same thing),
    /// else the platform's own.
    fn scanFonts(db: *Db) void {
        if (db.fonts_dir) |dir| {
            db.scanDir(dir);
            return;
        }
        var buf: [1024]u8 = undefined;
        switch (builtin.os.tag) {
            .windows => {
                db.scanDir("C:\\Windows\\Fonts");
                // Under Wine, the Linux system's fonts are on drive Z:.
                if (db.faces.items.len < 8) db.scanDir("Z:\\usr\\share\\fonts");
            },
            .macos => {
                for ([_][]const u8{ "/System/Library/Fonts", "/Library/Fonts" }) |d| db.scanDir(d);
                if (env("HOME")) |home| db.scanDir(std.fmt.bufPrint(&buf, "{s}/Library/Fonts", .{home}) catch return);
            },
            else => if (android) {
                for ([_][]const u8{ "/system/fonts", "/product/fonts" }) |d| db.scanDir(d);
            } else {
                for ([_][]const u8{ "/usr/share/fonts", "/usr/local/share/fonts" }) |d| db.scanDir(d);
                if (env("HOME")) |home| {
                    db.scanDir(std.fmt.bufPrint(&buf, "{s}/.local/share/fonts", .{home}) catch return);
                    db.scanDir(std.fmt.bufPrint(&buf, "{s}/.fonts", .{home}) catch return);
                }
            },
        }
    }

    /// Appends the faces a valid cache holds; false when there is none
    /// (off, missing, stale, damaged, unreadable), so the scan runs and
    /// then rewrites it. A cache never makes text worse: every problem
    /// here is only a reason to scan.
    fn loadCached(db: *Db) bool {
        const path = db.cache_path orelse return false;
        const dir = db.fonts_dir orelse return false;
        const traced = trace.on();
        const at = if (traced) trace.stamp() else 0;
        defer if (traced) {
            db.cache.ms += trace.msSince(at);
        };
        const digest = fontindex.fingerprint(db.gpa, db.io, dir) orelse {
            db.cache.state = .unreadable;
            return false;
        };
        db.cache_digest = digest;
        const entries = fontindex.read(db.gpa, db.io, path, dir, digest) catch |err| {
            db.cache.state = switch (err) {
                error.NotFound => .miss,
                error.Stale => .stale,
                error.OutOfMemory => .unreadable,
                else => .damaged,
            };
            return false;
        };
        defer db.gpa.free(entries);
        for (entries) |e| {
            db.faces.append(db.gpa, .{ .path = e.path, .index = e.index, .style = e.style }) catch {
                db.gpa.free(e.path);
                continue;
            };
        }
        db.cache.state = .hit;
        db.cache.faces = entries.len;
        return true;
    }

    /// Writes the scan's file faces for the next start. A cache is an
    /// optimization: any failure leaves the app and the next start's scan
    /// exactly as they were.
    fn saveCached(db: *Db) void {
        const path = db.cache_path orelse return;
        const dir = db.fonts_dir orelse return;
        const traced = trace.on();
        const at = if (traced) trace.stamp() else 0;
        defer if (traced) {
            db.cache.ms += trace.msSince(at);
        };
        const digest = db.cache_digest orelse fontindex.fingerprint(db.gpa, db.io, dir) orelse {
            db.cache.state = .unreadable;
            return;
        };
        const written = fontindex.write(db.gpa, db.io, path, dir, digest, db.faces.items[db.bundled..]) orelse {
            db.cache.state = .write_failed;
            return;
        };
        db.cache.state = .written;
        db.cache.faces = db.faces.items.len - db.bundled;
        db.cache.bytes = written;
    }

    /// One line with what the cache lookup or write did, when tracing.
    fn traceCache(db: *const Db) void {
        if (!trace.on()) return;
        trace.markf(
            "font.cache",
            "state={s} faces={d} bytes={d} ms={d:.2}",
            .{ @tagName(db.cache.state), db.cache.faces, db.cache.bytes, db.cache.ms },
        );
    }

    /// One line with what the scan cost, when `ui.trace` is on.
    fn traceScan(db: *const Db) void {
        if (!trace.on()) return;
        const s = db.scan_stats;
        trace.markf(
            "font.scan",
            "dirs={d} entries={d} files={d} faces={d} bundled={d} walk_ms={d:.2} open_ms={d:.2} alloc_ms={d:.2} header_ms={d:.2} parse_ms={d:.2} table_ms={d:.2} style_ms={d:.2} max_end={d}",
            .{ s.dirs, s.entries, s.files, s.faces, db.bundled, s.walk_ms, s.open_ms, s.alloc_ms, s.header_ms, s.parse_ms, s.table_ms, s.style_ms, s.max_end },
        );
    }

    pub fn scanDir(db: *Db, path: []const u8) void {
        var dir = std.Io.Dir.cwd().openDir(db.io, path, .{ .iterate = true }) catch return;
        defer dir.close(db.io);
        var walker = dir.walk(db.gpa) catch return;
        defer walker.deinit();
        const traced = trace.on();
        if (traced) db.scan_stats.dirs += 1;
        while (true) {
            const walked_at = if (traced) trace.stamp() else 0;
            const next = walker.next(db.io) catch null;
            if (traced) db.scan_stats.walk_ms += trace.msSince(walked_at);
            const e = next orelse break;
            if (traced) db.scan_stats.entries += 1;
            if (e.kind != .file and e.kind != .sym_link) continue;
            const ext = std.fs.path.extension(e.basename);
            if (!std.ascii.eqlIgnoreCase(ext, ".ttf") and !std.ascii.eqlIgnoreCase(ext, ".ttc")) continue;
            var full: [1024]u8 = undefined;
            const p = std.fmt.bufPrint(&full, "{s}{c}{s}", .{ path, std.fs.path.sep, e.path }) catch continue;
            db.addFile(p);
        }
    }

    /// Reads a file's faces' styles, touching only the tables they need.
    ///
    /// One read of the header window covers the table directory, and most
    /// faces' head/OS-2/name records too. A face whose records sit further
    /// in is read table by table into a buffer the size of the records
    /// (`readStyleFar`): a file-sized mapping per font cost 69 ms of
    /// commits and 35 ms of releases over one Windows font folder, and
    /// commit is working set, so it bought nothing to keep.
    pub fn addFile(db: *Db, path: []const u8) void {
        var lap: Lap = .init();
        var file = std.Io.Dir.cwd().openFile(db.io, path, .{}) catch return;
        defer file.close(db.io);
        const len = file.length(db.io) catch return;
        if (len < 12 or len > 256 << 20) return;
        db.scan_stats.open_ms += lap.lap();
        const window: usize = @min(len, scan_window);
        const data = db.scanBuffer(window) orelse return;
        db.scan_stats.alloc_ms += lap.lap();
        // Only the first window of the file is read whole: it holds the
        // table directory every face starts from.
        _ = file.readPositionalAll(db.io, data[0..window], 0) catch return;
        db.scan_stats.files += 1;
        db.scan_stats.header_ms += lap.lap();

        for (0..font.faces(data)) |i| {
            const faces_at = if (lap.traced) trace.stamp() else 0;
            const t = font.Tables.read(data, i) catch continue;
            if (lap.traced) db.scan_stats.parse_ms += trace.msSince(faces_at);
            const style_at = if (lap.traced) trace.stamp() else 0;
            const style = if (farTables(t, len, window))
                db.readStyleFar(file, t, len, &lap)
            else
                font.Style.read(data, t);
            if (lap.traced) db.scan_stats.style_ms += trace.msSince(style_at);
            const s = style orelse continue;
            if (s.family_len == 0) continue;
            const owned = db.gpa.dupe(u8, path) catch return;
            db.faces.append(db.gpa, .{ .path = owned, .index = @intCast(i), .style = s }) catch db.gpa.free(owned);
            if (lap.traced) db.scan_stats.faces += 1;
        }
    }

    /// Whether any table a scan needs reaches past the header window.
    fn farTables(t: font.Tables, len: usize, window: usize) bool {
        inline for (scan_tables) |name| {
            if (tableSpan(t, name, len)) |span| {
                if (span[1] > window) return true;
            }
        }
        return false;
    }

    /// A face's style when the tables it needs are past the header window:
    /// head, OS/2 and the name table are read into a buffer of their own
    /// with the table offsets moved to it.
    fn readStyleFar(db: *Db, file: std.Io.File, t: font.Tables, len: usize, lap: *Lap) ?font.Style {
        const name_span = tableSpan(t, "name", len);
        // A damaged directory can claim any length: the records sit at the
        // front of the table, so the first megabyte is all a scan reads.
        const name_len: usize = if (name_span) |span| @min(span[1] - span[0], max_name_read) else 0;
        const local = db.gpa.alloc(u8, 2 * 100 + name_len) catch return null;
        defer db.gpa.free(local);
        var shifted = t;
        var at: usize = 0;
        inline for (.{ "head", "os2" }) |name| {
            if (tableSpan(t, name, len)) |span| {
                @memset(local[at..][0..100], 0);
                const n = @min(span[1] - span[0], 100);
                const read_at = if (lap.traced) trace.stamp() else 0;
                _ = file.readPositionalAll(db.io, local[at..][0..n], span[0]) catch {};
                if (lap.traced) db.scan_stats.table_ms += trace.msSince(read_at);
                @field(shifted, name) = @intCast(at);
                at += 100;
            } else @field(shifted, name) = 0;
        }
        if (name_span) |span| {
            const read_at = if (lap.traced) trace.stamp() else 0;
            _ = file.readPositionalAll(db.io, local[at..][0..name_len], span[0]) catch {};
            if (lap.traced) {
                db.scan_stats.table_ms += trace.msSince(read_at);
                db.scan_stats.max_end = @max(db.scan_stats.max_end, span[1]);
            }
            shifted.name = @intCast(at);
            at += name_len;
        } else shifted.name = 0;
        return font.Style.read(local[0..at], shifted);
    }

    /// A face's table a scan needs, as `{ offset, end }` clamped to the
    /// file (null when the face has none).
    fn tableSpan(t: font.Tables, comptime name: []const u8, len: usize) ?[2]usize {
        const off: usize = @field(t, name);
        if (off == 0 or off >= len) return null;
        const want: usize = if (comptime std.mem.eql(u8, name, "name")) t.name_len else 100;
        return .{ off, @min(len, off + want) };
    }

    /// The reused header-window buffer: the first `scan_window` bytes of
    /// whichever file is being read.
    ///
    /// Bytes no read filled still hold an earlier file's: a scan reads only
    /// the ranges the current file's table directory names, and
    /// `font.Style` keeps its records inside the name table it read, so a
    /// scan never sees another font's bytes.
    fn scanBuffer(db: *Db, at_least: usize) ?[]u8 {
        if (db.file_buf.len < at_least) {
            const grown = std.heap.page_allocator.alloc(u8, at_least) catch return null;
            if (db.file_buf.len > 0) std.heap.page_allocator.free(db.file_buf);
            db.file_buf = grown;
        }
        return db.file_buf[0..@min(db.file_buf.len, at_least)];
    }

    /// The face of `family` nearest `weight` and `italic`, null when the
    /// family has none.
    pub fn family(db: *Db, name: []const u8, weight: u16, italic: bool) ?u32 {
        db.scan();
        var best: ?u32 = null;
        var best_score: u32 = std.math.maxInt(u32);
        for (db.faces.items, 0..) |f, i| {
            if (!std.ascii.eqlIgnoreCase(f.style.name(), name)) continue;
            const dw: u32 = @abs(@as(i32, f.style.weight) - @as(i32, weight));
            const score = dw + @as(u32, if (f.style.italic != italic) 1000 else 0);
            if (score < best_score) {
                best_score = score;
                best = @intCast(i);
            }
        }
        return best;
    }

    /// The face for a style: its family if installed, else the first
    /// installed of the defaults.
    pub fn match(db: *Db, name: ?[]const u8, weight: u16, italic: bool, mono: bool) ?u32 {
        if (name) |n| if (db.family(n, weight, italic)) |f| return f;
        for (if (mono) &monos else &sans) |n| if (db.family(n, weight, italic)) |f| return f;
        db.scan();
        for (db.faces.items, 0..) |f, i| if (f.style.mono == mono) return @intCast(i);
        return if (db.faces.items.len > 0) 0 else null;
    }

    /// A face's font, loaded on first use (null if it cannot be read).
    pub fn load(db: *Db, face: u32) ?*const font.Font {
        if (db.loaded.get(face)) |l| return &l.font;
        const traced = trace.on();
        const started = if (traced) trace.stamp() else 0;
        const f = db.faces.items[face];
        const bytes = f.read(db) orelse return null;
        const parsed = font.Font.init(bytes.data, f.index) catch {
            freeBytes(db.gpa, bytes);
            return null;
        };
        const l = db.gpa.create(Loaded) catch {
            freeBytes(db.gpa, bytes);
            return null;
        };
        l.* = .{ .data = bytes.data, .mapped = bytes.mapped, .font = parsed };
        l.font.data = l.data;
        db.loaded.put(db.gpa, face, l) catch {};
        if (traced) {
            db.loads += 1;
            db.load_ms += trace.msSince(started);
        }
        return &l.font;
    }

    /// Bytes of font files held in memory: each loaded face keeps its whole
    /// file (a CJK collection is tens of megabytes), so this is what the
    /// text system costs beyond its atlases. Read by `--mem-probe`.
    pub fn loadedBytes(db: *const Db) usize {
        var total: usize = 0;
        var it = db.loaded.valueIterator();
        while (it.next()) |l| total += l.*.data.len;
        return total;
    }

    /// The faces loaded so far, by index (for diagnostics).
    pub fn loadedCount(db: *const Db) usize {
        return db.loaded.count();
    }

    /// A face that has `cp`, for text its font lacks.
    pub fn fallback(db: *Db, cp: u21, weight: u16) ?u32 {        if (db.found.get(cp)) |f| return f;
        const traced = trace.on();
        const started = if (traced) trace.stamp() else 0;
        const f = db.findFallback(cp, weight);
        db.found.put(db.gpa, cp, f) catch {};
        if (traced) {
            db.fallback_searches += 1;
            db.fallback_ms += trace.msSince(started);
        }
        return f;
    }

    fn findFallback(db: *Db, cp: u21, weight: u16) ?u32 {
        for (fallbacks) |n| if (db.family(n, weight, false)) |face| {
            if (db.load(face)) |f| if (f.glyphIndex(cp) != 0) return face;
        };
        // Any face at all: the loaded first, then the rest.
        var it = db.loaded.iterator();
        while (it.next()) |e| if (e.value_ptr.*.font.glyphIndex(cp) != 0) return e.key_ptr.*;
        // Read, checked and let go unless it has it; a few dozen at most.
        var tries: usize = 0;
        for (0..db.faces.items.len) |i| {
            if (tries >= 48) break;
            if (db.loaded.contains(@intCast(i))) continue;
            if (i > 0 and std.mem.eql(u8, db.faces.items[i - 1].style.name(), db.faces.items[i].style.name())) continue;
            tries += 1;
            const face = db.faces.items[i];
            const bytes = face.read(db) orelse continue;
            defer freeBytes(db.gpa, bytes);
            const f = font.Font.init(bytes.data, face.index) catch continue;
            if (f.glyphIndex(cp) != 0) return @intCast(i);
        }
        return null;
    }
};
