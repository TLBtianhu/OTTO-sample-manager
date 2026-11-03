//! Library drop-in: nanoui `ui.Drop` file URLs -> native paths -> the existing
//! import state machine. One folder uses `Import.start` exactly like the
//! button; one or more files use `Import.startFiles` and remain flat entries.
//! URLs belong to the delivery frame, so path copies are made before import.
const std = @import("std");
const nanoui = @import("nanoui");
const import_ui = @import("import_ui.zig");
const import_shape = @import("import_shape.zig");
const drop_files = @import("drop_files.zig");

pub const Classification = enum { folder, file, missing };

pub fn classify(io: std.Io, path: []const u8) Classification {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return .missing;
    return if (stat.kind == .directory) .folder else .file;
}

/// Same schedule signature as `nanoui.App.after`; keeping it here lets the
/// probe drive a hidden window without giving this module an app dependency.
pub const Schedule = *const fn (ms: u64, ctx: ?*anyopaque, func: *const fn (?*anyopaque) callconv(.c) void) void;

pub const Drop = struct {
    io: std.Io = undefined,
    import: *import_ui.Import = undefined,
    schedule: Schedule = undefined,
    seen: bool = false,
    started: bool = false,
    probe_path: ?[]const u8 = null,
    probe_hwnd: ?*anyopaque = null,
    probe_injected: bool = false,
    probe_kind: Classification = .missing,
    first_path: [std.Io.Dir.max_path_bytes]u8 = undefined,
    first_len: usize = 0,
    grace: u32 = 0,
    ticks: u32 = 0,

    pub fn init(self: *Drop, io: std.Io, import: *import_ui.Import) void {
        self.io = io;
        self.import = import;
    }

    /// The whole library window is the target. `dropAt` reads the previous
    /// frame's root rectangle, so drops over search/list/preview all arrive.
    pub fn accept(self: *Drop, c: *nanoui.ui.Context, index: u32) void {
        c.acceptDrop(index);
        if (!self.probe_injected) if (self.probe_path) |path| if (self.probe_hwnd) |hwnd| {
            self.probe_injected = true;
            std.debug.print("drop-probe: inject WM_DROPFILES during_frame=true\n", .{});
            drop_files.send(@ptrCast(hwnd), &.{path}) catch |err| {
                std.debug.print("drop-probe: 合成拖放失败（{s}）\n", .{@errorName(err)});
                std.process.exit(1);
            };
        };
        if (c.dropAt(index)) |event| {
            if (self.probe_path != null) std.debug.print("drop-probe: dropAt urls={d}\n", .{event.urls.len});
            self.onUrls(event.urls);
        }
    }

    /// Probe installation only: production delivery is accept/dropAt above.
    /// A synthetic HDROP still travels through Windows and nanoui's URL codec.
    pub fn install(
        self: *Drop,
        probe: ?[]const u8,
        window: anytype,
        schedule: Schedule,
    ) void {
        self.schedule = schedule;
        const path = probe orelse return;
        if (comptime !@hasField(@TypeOf(window.*), "hwnd")) return;
        const hwnd = window.hwnd orelse return;
        self.probe_path = path;
        self.probe_hwnd = @ptrCast(hwnd);
        self.probe_kind = classify(self.io, path);
        // Force one hidden frame; accept injects synchronously while that frame
        // is building, exercising the reentrant path real shell delivery can hit.
        window.redraw();
        self.schedule(0, self, tick);
    }

    fn onUrls(self: *Drop, urls: []const []const u8) void {
        self.seen = true;
        if (self.probe_path != null) std.debug.print("drop-probe: onUrls count={d}\n", .{urls.len});
        var arena: std.heap.ArenaAllocator = .init(self.import.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const paths = a.alloc([]const u8, urls.len) catch {
            self.import.reject("OutOfMemory", "file URL list");
            return;
        };
        for (urls, 0..) |url, i| {
            paths[i] = nanoui.file_url.toWindowsPath(a, url) catch |err| {
                self.import.reject(@errorName(err), url);
                return;
            };
        }
        if (paths.len > 0) {
            self.first_len = @min(paths[0].len, self.first_path.len);
            @memcpy(self.first_path[0..self.first_len], paths[0][0..self.first_len]);
        }
        self.handle(paths);
    }

    /// Classify the complete batch before starting anything: a missing path,
    /// mixed files/folders, or multiple folders gets a named, visible error.
    pub fn handle(self: *Drop, paths: []const []const u8) void {
        if (paths.len == 0) return;
        if (self.import.busy()) {
            std.debug.print("otto-lite: 正在导入，忽略这次拖入 paths={d}\n", .{paths.len});
            return;
        }
        var arena: std.heap.ArenaAllocator = .init(self.import.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var files: std.ArrayList([]const u8) = .empty;
        var folder: ?[]const u8 = null;
        for (paths) |path| {
            const kind = classify(self.io, path);
            std.debug.print("otto-lite: 拖入 path={s} kind={s}\n", .{ path, @tagName(kind) });
            switch (kind) {
                .folder => {
                    if (folder != null) {
                        self.import.reject("MultipleFolders", path);
                        return;
                    }
                    folder = path;
                },
                .file => files.append(a, path) catch {
                    self.import.reject("OutOfMemory", path);
                    return;
                },
                .missing => {
                    const stat = std.Io.Dir.cwd().statFile(self.io, path, .{});
                    if (stat) |_| {
                        self.import.reject("PathUnavailable", path);
                    } else |err| self.import.reject(@errorName(err), path);
                    return;
                },
            }
        }
        if (folder != null and files.items.len > 0) {
            self.import.reject("MixedFilesAndFolder", folder.?);
            return;
        }
        self.started = true;
        if (folder) |path| {
            std.debug.print("otto-lite: 拖入文件夹，走按钮导入 path={s}\n", .{path});
            self.import.start(path);
        } else {
            std.debug.print("otto-lite: 拖入文件 files={d}\n", .{files.items.len});
            self.import.startFiles(files.items);
        }
    }

    /// Probe beats: wait for delivery and import, then allow reload two beats.
    pub fn tick(ctx: ?*anyopaque) callconv(.c) void {
        const self: *Drop = @ptrCast(@alignCast(ctx.?));
        self.ticks += 1;
        if (!self.seen) {
            if (self.ticks > 300) abort("回调没有收到（30 秒）");
            self.schedule(100, self, tick);
            return;
        }
        if (self.import.busy()) {
            if (self.ticks > 300) abort("导入超时（30 秒）");
            self.schedule(100, self, tick);
            return;
        }
        if (self.grace == 0) {
            self.grace = 5;
            self.schedule(100, self, tick);
            return;
        }
        self.grace -= 1;
        if (self.grace > 0) {
            self.schedule(100, self, tick);
            return;
        }
        const phase = self.import.phase;
        const received = self.first_path[0..self.first_len];
        const matched = if (self.probe_path) |expected| std.mem.eql(u8, received, expected) else false;
        const samples = self.import.live().samples();
        const expected_source: import_ui.Source = if (self.probe_kind == .folder) .folder else .files;
        var structure_ok = self.import.source == expected_source and samples.len > 0;
        if (structure_ok and self.probe_kind == .folder) {
            structure_ok = std.mem.eql(u8, samples[0].rootPath(), received);
        } else if (structure_ok) {
            for (samples) |sample| {
                if (!import_shape.isFlatFile(sample)) structure_ok = false;
            }
        }
        const ok = matched and self.started and phase == .done and structure_ok;
        std.debug.print(
            "drop-probe: done phase={s} samples={d} started={} source={s} structure={} path={s} match={}\n",
            .{ @tagName(phase), samples.len, self.started, @tagName(self.import.source), structure_ok, received, matched },
        );
        std.process.exit(if (ok) 0 else 1);
    }

    fn abort(comptime why: []const u8) noreturn {
        std.debug.print("drop-probe: 失败 {s}\n", .{why});
        std.process.exit(1);
    }
};

const testing = std.testing;

test "拖入分类：目录、文件、不存在的路径分成三类" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(testing.io, &path_buffer);
    const root = path_buffer[0..root_len];

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "tone.wav", .data = "x" });
    try tmp.dir.createDir(testing.io, "samples", .default_dir);

    const file = try std.fs.path.join(testing.allocator, &.{ root, "tone.wav" });
    defer testing.allocator.free(file);
    const folder = try std.fs.path.join(testing.allocator, &.{ root, "samples" });
    defer testing.allocator.free(folder);
    const missing = try std.fs.path.join(testing.allocator, &.{ root, "nope" });
    defer testing.allocator.free(missing);

    try testing.expectEqual(Classification.folder, classify(testing.io, folder));
    try testing.expectEqual(Classification.file, classify(testing.io, file));
    try testing.expectEqual(Classification.missing, classify(testing.io, missing));
}
