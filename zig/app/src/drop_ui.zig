//! 文件拖入 → 导入：把 nanoui 的 `DropHandler` 接到既有的导入状态机上。
//!
//!   * 是目录 → `import_ui.Import.start`（工作线程、状态机、reload 与
//!     「导入文件夹」按钮完全同一条路，UI 显示「正在导入…」）；
//!   * 不是目录（文件 / 不存在的路径）→ 一行日志「只接受文件夹」，不导入；
//!   * 一次拖多个目录 → 只导入第一个，其余各打一行日志（同一时刻只有一个导入）。
//!
//! 回调里的路径只在调用期间有效（nanoui 用 arena 持有它们），所以这里立刻
//! 分类并 `start`（`start` 自己复制路径），不保存任何切片。
//!
//! ## 验收探针
//!
//! `Drop.install` 的 `probe` 非空时（`--drop-probe=<path>`），会合成一次
//! `WM_DROPFILES`（见 `drop_files.zig`）并在窗口隐藏时跑完整个回调 → 导入 →
//! reload 链路，然后打印 `drop-probe: done …` 退出。这样验收不需要鼠标，
//! 也不需要可见窗口。

const std = @import("std");
const import_ui = @import("import_ui.zig");
const drop_files = @import("drop_files.zig");

/// 拖入路径的三类：目录可导入，其余（文件 / 打不开）都只要一行日志。
pub const Classification = enum { folder, file, missing };

pub fn classify(io: std.Io, path: []const u8) Classification {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return .missing;
    return if (stat.kind == .directory) .folder else .file;
}

/// 与 `nanoui.App.after` 同签名：探针把「下一拍」的调度留给调用方，本文件
/// 不 import nanoui，测试根因此不需要窗口/工具包。
pub const Schedule = *const fn (ms: u64, ctx: ?*anyopaque, func: *const fn (?*anyopaque) callconv(.c) void) void;

pub const Drop = struct {
    io: std.Io = undefined,
    import: *import_ui.Import = undefined,
    schedule: Schedule = undefined,
    /// 回调至少进来过一次（文件路径不会起导入，不能只看 `busy()`）。
    seen: bool = false,
    /// 这次拖入确实起了导入。
    started: bool = false,
    /// 探针投递的路径（argv 的切片，活到进程结束）与回调实际拿到的第一条路径。
    probe_path: ?[]const u8 = null,
    first_path: [std.Io.Dir.max_path_bytes]u8 = undefined,
    first_len: usize = 0,
    grace: u32 = 0,
    ticks: u32 = 0,

    /// 给窗口装 handler；`probe` 非空时再合成一次拖放（窗口必须已经有 HWND）。
    pub fn install(
        self: *Drop,
        io: std.Io,
        import: *import_ui.Import,
        probe: ?[]const u8,
        window: anytype,
        schedule: Schedule,
    ) void {
        self.io = io;
        self.import = import;
        self.schedule = schedule;
        if (comptime @hasField(@TypeOf(window.*), "hwnd")) {
            window.setDropHandler(.{ .context = self, .onPaths = onPaths });
        }
        const path = probe orelse return;
        if (comptime !@hasField(@TypeOf(window.*), "hwnd")) return;
        const hwnd = window.hwnd orelse return;
        self.probe_path = path;
        drop_files.post(@ptrCast(hwnd), &.{path}) catch |err| {
            std.debug.print("otto-lite: drop-probe 合成拖放失败（{s}）\n", .{@errorName(err)});
            std.process.exit(1);
        };
        self.schedule(0, self, tick);
    }

    /// nanoui 的回调。`context` 就是 `install` 里的这个 `Drop`。
    pub fn onPaths(context: *anyopaque, paths: []const []const u8) void {
        const self: *Drop = @ptrCast(@alignCast(context));
        self.seen = true;
        if (paths.len > 0) {
            self.first_len = @min(paths[0].len, self.first_path.len);
            @memcpy(self.first_path[0..self.first_len], paths[0][0..self.first_len]);
        }
        self.handle(paths);
    }

    /// 分类 + 导入第一个目录。日志是验收的一部分：文件路径必须出现
    /// 「只接受文件夹」，目录则要能对上合成进来的路径。
    pub fn handle(self: *Drop, paths: []const []const u8) void {
        var first: ?[]const u8 = null;
        for (paths) |path| {
            const kind = classify(self.io, path);
            std.debug.print("otto-lite: 拖入 path={s} kind={s}\n", .{ path, @tagName(kind) });
            switch (kind) {
                .folder => if (first == null) {
                    first = path;
                } else {
                    std.debug.print("otto-lite: 一次只导入一个文件夹，忽略 path={s}\n", .{path});
                },
                .file, .missing => std.debug.print("otto-lite: 只接受文件夹，忽略 path={s}\n", .{path}),
            }
        }
        const folder = first orelse return;
        if (self.import.busy()) {
            std.debug.print("otto-lite: 正在导入，忽略这次拖入 path={s}\n", .{folder});
            return;
        }
        self.started = true;
        std.debug.print("otto-lite: 拖入导入 path={s}\n", .{folder});
        self.import.start(folder);
    }

    /// 探针的拍子：等回调、等导入结束，再给状态机/reload 两拍，然后退出。
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
        std.debug.print(
            "drop-probe: done phase={s} samples={d} started={} path={s} match={}\n",
            .{ @tagName(phase), self.import.live().samples().len, self.started, received, matched },
        );
        if (self.probe_path != null and !matched) std.process.exit(1);
        std.process.exit(if (phase == .failed) 1 else 0);
    }

    fn abort(comptime why: []const u8) noreturn {
        std.debug.print("drop-probe: 失败 {s}\n", .{why});
        std.process.exit(1);
    }
};

// ---------------------------------------------------------------------------
// 测试：拖入路径的分类（真临时目录；导入链路由 `--drop-probe` 验收）
// ---------------------------------------------------------------------------

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
