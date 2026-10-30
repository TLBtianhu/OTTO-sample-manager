//! `--thumb-bench <dir>`：进程内取图 vs 隔离 helper 的同一份对照（不开窗、不碰 nanoui）。
//!
//! 三件事，按顺序：
//!
//!   1. **字节一致**：目录里每个文件各取一次（`thumb.get` 与 `thumb_host.get`），
//!      比较宽 / 高 / 跨度 / 字节数 / 像素；失败也要"同名"（NoHandler 对 NoHandler）。
//!      隔离层换的是进程，不是像素契约——**同一条调用链必须交出同一块 BGRA**。
//!   2. **200 张耗时**：找一张真能出图的文件，把字节拷成 200 个不同的文件名（不同路径
//!      才不会被 Shell 的路径缓存糊掉），两种后端各跑一遍，报"冷（含 helper spawn）"
//!      与"200 次摊销后"两组数字。这就是 M4 的验收点：一次进程启动被 200 张摊薄。
//!   3. **不留下进程**：结束前 `thumb_host.deinit()`，临时目录删干净。
//!
//! 这个命令是给"改隔离层的人"看的诊断入口，不是产品功能：它把 helper 的 spawn /
//! 重启 / 超时账一起打出来，方便判断"慢"是 Shell 的锅还是隔离层的锅。

const std = @import("std");
const thumb = @import("otto_thumb");
const thumb_host = @import("otto_thumb_host");

/// 与 `thumbs.default_size_px` 对齐：列表那格 32 点、2x 屏 64px。
const size_px: u32 = 64;

/// 计时那一轮请求多少张。题目给的数字（2000 张是最终场景，200 张是这里的样本量）。
const copy_count: usize = 200;

pub fn run(init: std.process.Init, allocator: std.mem.Allocator, dir_path: []const u8) !u8 {
    const io = init.io;

    const root = std.Io.Dir.cwd().realPathFileAlloc(io, dir_path, allocator) catch |err| {
        std.debug.print("thumb-bench: 解析目录失败 {s}（{s}）\n", .{ dir_path, @errorName(err) });
        return 1;
    };
    defer allocator.free(root);

    var files = std.ArrayList([]u8).empty;
    defer {
        for (files.items) |path| allocator.free(path);
        files.deinit(allocator);
    }
    collectFiles(io, allocator, root, &files) catch |err| {
        std.debug.print("thumb-bench: 列举目录失败 {s}（{s}）\n", .{ root, @errorName(err) });
        return 1;
    };
    if (files.items.len == 0) {
        std.debug.print("thumb-bench: 目录里没有文件：{s}\n", .{root});
        return 1;
    }

    defer thumb_host.deinit();
    std.debug.print(
        "thumb-bench: 目录 {s}，{d} 个文件；请求边长 {d}px；helper 取与本 exe 同目录的 otto-thumb-host.exe（OTTO_THUMB_HOST 可覆盖）\n",
        .{ root, files.items.len, size_px },
    );

    // ---- 1. 逐文件对照 -----------------------------------------------------
    var parity = true;
    for (files.items) |path| compareOne(allocator, path, &parity);
    if (!parity) {
        std.debug.print("thumb-bench: FAIL 隔离层与进程内结果不一致（见上）\n", .{});
        return 1;
    }

    // ---- 2. 200 张：先把一份真图拷成 200 个不同路径 -----------------------
    const source = findSource(allocator, files.items) orelse {
        std.debug.print("thumb-bench: FAIL 目录里没有一张能用进程内取到的图，无法做耗时对照\n", .{});
        return 1;
    };
    defer allocator.free(source);

    const bytes = readAlongside(io, allocator, root, source) catch |err| {
        std.debug.print("thumb-bench: 读取 {s} 失败（{s}）\n", .{ source, @errorName(err) });
        return 1;
    };
    defer allocator.free(bytes);

    var copies = Copies{};
    defer copies.deinit(io, allocator);
    copies.build(io, allocator, init.environ_map, root, source, bytes) catch |err| {
        std.debug.print("thumb-bench: 准备 200 份拷贝失败（{s}）\n", .{@errorName(err)});
        return 1;
    };

    // 计时方法（两种后端完全对称）：
    //   1) 冷启动一张：隔离这一侧含 CreateProcessW + helper 里的 Shell 初始化；
    //   2) 各跑一遍 200 张作为预热——Shell 的缩略图缓存是**系统级**的，
    //      不预热的话"谁后跑谁快"，比的就不是后端而是缓存；
    //   3) 再各跑一遍 200 张作为测量。两次都在同一份 200 个路径上。
    const local_cold = timeOne(io, allocator, copies.paths.items[0], .local);
    const isolated_cold = timeOne(io, allocator, copies.paths.items[0], .isolated);
    _ = timeMany(io, allocator, copies.paths.items, .local);
    _ = timeMany(io, allocator, copies.paths.items, .isolated);
    const local = timeMany(io, allocator, copies.paths.items, .local);
    const isolated = timeMany(io, allocator, copies.paths.items, .isolated);

    // 把"只发生一次"的进程启动摊进 200 张里，才是"走 helper 的总耗时"。
    const isolated_total = isolated_cold + isolated.total_ms;
    const resident_delta = isolated.total_ms - local.total_ms;
    const total_delta = isolated_total - local.total_ms;

    std.debug.print(
        "thumb-bench: 冷启动一张：进程内={d:.2} ms  隔离={d:.2} ms（含 CreateProcessW，整轮只此一次）\n",
        .{ local_cold, isolated_cold },
    );
    std.debug.print(
        "thumb-bench: 200 张·进程内 {d:.2} ms（{d:.2} ms/张）failed={d}\n",
        .{ local.total_ms, perImage(local.total_ms), local.failures },
    );
    std.debug.print(
        "thumb-bench: 200 张·隔离   {d:.2} ms（{d:.2} ms/张）failed={d}；此时 helper 已常驻\n",
        .{ isolated.total_ms, perImage(isolated.total_ms), isolated.failures },
    );
    std.debug.print(
        "thumb-bench: 只比 200 张：差值 {s}{d:.2} ms（{s}{d:.2} ms/张）——helper 一次启动都被摊掉了\n",
        .{
            if (resident_delta >= 0) "+" else "",
            resident_delta,
            if (resident_delta >= 0) "+" else "",
            resident_delta / @as(f64, @floatFromInt(copy_count)),
        },
    );
    std.debug.print(
        "thumb-bench: 把一次启动摊进去：{d:.2} ms vs 进程内 {d:.2} ms，差值 {s}{d:.2} ms（{s}{d:.2} ms/张）\n",
        .{
            isolated_total,
            local.total_ms,
            if (total_delta >= 0) "+" else "",
            total_delta,
            if (total_delta >= 0) "+" else "",
            total_delta / @as(f64, @floatFromInt(copy_count)),
        },
    );

    const stats = thumb_host.stats();
    std.debug.print(
        "thumb-bench: helper 账 spawns={d} restarts={d} crashes={d} timeouts={d} requests={d}\n",
        .{ stats.spawns, stats.restarts, stats.crashes, stats.timeouts, stats.requests },
    );

    if (local.failures != 0 or isolated.failures != 0) {
        std.debug.print("thumb-bench: FAIL 200 张里有取图失败（进程内 {d} / 隔离 {d}）\n", .{
            local.failures, isolated.failures,
        });
        return 1;
    }
    std.debug.print("thumb-bench: OK 字节一致 + 200 张走完；helper 已收掉\n", .{});
    return 0;
}

// ---------------------------------------------------------------------------
// 逐文件对照
// ---------------------------------------------------------------------------

fn compareOne(allocator: std.mem.Allocator, path: []const u8, ok: *bool) void {
    const name = std.fs.path.basename(path);

    var local_image: ?thumb.Thumbnail = null;
    var local_error: ?[]const u8 = null;
    if (thumb.get(allocator, path, size_px)) |image| local_image = image else |err| local_error = @errorName(err);
    defer if (local_image) |image| image.deinit(allocator);

    var remote_image: ?thumb.Thumbnail = null;
    var remote_error: ?[]const u8 = null;
    if (thumb_host.get(allocator, path, size_px)) |image| remote_image = image else |err| remote_error = @errorName(err);
    defer if (remote_image) |image| image.deinit(allocator);

    if (local_image != null and remote_image != null) {
        const local = local_image.?;
        const remote = remote_image.?;
        const same = local.width == remote.width and local.height == remote.height and
            local.stride == remote.stride and std.mem.eql(u8, local.pixels, remote.pixels);
        std.debug.print("thumb-bench: 进程内 {s:<16} {d}×{d} stride={d} {d}B\n", .{
            name, local.width, local.height, local.stride, local.pixels.len,
        });
        std.debug.print("thumb-bench: 隔离   {s:<16} {d}×{d} stride={d} {d}B  {s}\n", .{
            name, remote.width, remote.height, remote.stride, remote.pixels.len,
            if (same) "逐字节一致" else "不一致!",
        });
        if (!same) ok.* = false;
        return;
    }

    if (local_error != null and remote_error != null) {
        const same = std.mem.eql(u8, local_error.?, remote_error.?);
        std.debug.print("thumb-bench: 同错   {s:<16} 进程内={s} 隔离={s} {s}\n", .{
            name, local_error.?, remote_error.?, if (same) "一致" else "不一致!",
        });
        if (!same) ok.* = false;
        return;
    }

    ok.* = false;
    std.debug.print("thumb-bench: 不一致 {s:<16} 进程内={s} 隔离={s}\n", .{
        name,
        local_error orelse "ok",
        remote_error orelse "ok",
    });
}

// ---------------------------------------------------------------------------
// 200 份拷贝：临时目录 + 真图字节
// ---------------------------------------------------------------------------

const Copies = struct {
    parent: ?[]u8 = null,
    name: ?[]u8 = null,
    dir: ?[]u8 = null,
    paths: std.ArrayList([]u8) = .empty,

    fn build(
        self: *Copies,
        io: std.Io,
        allocator: std.mem.Allocator,
        environ_map: *std.process.Environ.Map,
        root: []const u8,
        source: []const u8,
        bytes: []const u8,
    ) !void {
        // 临时目录优先放系统 TEMP；拿不到就放在被测目录里的一个子目录（退出时删掉）。
        // 名字是固定的：上一次被强杀留下的同名目录会在下面先清掉，不会越积越多。
        const parent_owned = if (environ_map.get("TEMP")) |temp|
            try allocator.dupe(u8, temp)
        else
            try allocator.dupe(u8, root);
        self.parent = parent_owned;

        const name = try allocator.dupe(u8, "otto-thumb-bench");
        self.name = name;

        const dir = try std.fs.path.join(allocator, &.{ parent_owned, name });
        errdefer allocator.free(dir);

        if (std.Io.Dir.openDirAbsolute(io, parent_owned, .{})) |parent_dir| {
            parent_dir.deleteTree(io, name) catch {};
            parent_dir.close(io);
        } else |_| {}
        try std.Io.Dir.createDirAbsolute(io, dir, .default_dir);
        self.dir = dir;

        var handle = try std.Io.Dir.openDirAbsolute(io, dir, .{});
        defer handle.close(io);

        const extension = std.fs.path.extension(source);
        for (0..copy_count) |index| {
            const file_name = try std.fmt.allocPrint(allocator, "bench{d:0>3}{s}", .{ index, extension });
            defer allocator.free(file_name);
            try handle.writeFile(io, .{ .sub_path = file_name, .data = bytes });
            try self.paths.append(allocator, try std.fs.path.join(allocator, &.{ dir, file_name }));
        }
    }

    fn deinit(self: *Copies, io: std.Io, allocator: std.mem.Allocator) void {
        for (self.paths.items) |path| allocator.free(path);
        self.paths.deinit(allocator);

        if (self.parent != null and self.name != null) {
            // 删除用父目录句柄 + 相对名：绝对路径的 deleteTree 不受 Dir 实现影响。
            if (std.Io.Dir.openDirAbsolute(io, self.parent.?, .{})) |parent| {
                parent.deleteTree(io, self.name.?) catch {};
                parent.close(io);
            } else |_| {}
        }
        if (self.dir) |dir| allocator.free(dir);
        if (self.name) |name| allocator.free(name);
        if (self.parent) |parent| allocator.free(parent);
        self.* = .{};
    }
};

/// 找一张"进程内真的能取到图"的文件当样本：拷贝出来的 200 张必须都能出图，
/// 否则计时里混进失败分支就不好看了。
fn findSource(allocator: std.mem.Allocator, files: []const []u8) ?[]u8 {
    for (files) |path| {
        if (thumb.get(allocator, path, 16)) |image| {
            var owned = image;
            owned.deinit(allocator);
            return allocator.dupe(u8, path) catch null;
        } else |_| {}
    }
    return null;
}

fn readAlongside(io: std.Io, allocator: std.mem.Allocator, root: []const u8, path: []const u8) ![]u8 {
    const dir = try std.Io.Dir.openDirAbsolute(io, root, .{});
    defer dir.close(io);
    return dir.readFileAlloc(io, std.fs.path.basename(path), allocator, .limited(64 * 1024 * 1024));
}

fn collectFiles(io: std.Io, allocator: std.mem.Allocator, root: []const u8, files: *std.ArrayList([]u8)) !void {
    var dir = try std.Io.Dir.openDirAbsolute(io, root, .{ .iterate = true });
    defer dir.close(io);

    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file) continue;
        try files.append(allocator, try std.fs.path.join(allocator, &.{ root, entry.name }));
    }
}

// ---------------------------------------------------------------------------
// 计时
// ---------------------------------------------------------------------------

/// 两种后端。除了取图入口，计时与收尾逻辑完全一样——对照才成立。
const Mode = enum {
    /// 进程内 `thumb.get`：第三方 handler 与 OTTO 同生共死的那条老路。
    local,
    /// 隔离 `thumb_host.get`：`otto-thumb-host.exe` 里跑同一条 `thumb.get`。
    isolated,
};

const Timing = struct {
    total_ms: f64 = 0,
    failures: u32 = 0,
};

fn perImage(total_ms: f64) f64 {
    return total_ms / @as(f64, @floatFromInt(copy_count));
}

fn elapsedMs(io: std.Io, started: std.Io.Clock.Timestamp) f64 {
    return @as(f64, @floatFromInt(started.untilNow(io).raw.nanoseconds)) / 1_000_000.0;
}

fn fetch(mode: Mode, allocator: std.mem.Allocator, path: []const u8) thumb_host.Error!thumb.Thumbnail {
    return switch (mode) {
        .local => thumb.get(allocator, path, size_px),
        .isolated => thumb_host.get(allocator, path, size_px),
    };
}

/// 单张：隔离这一侧先 `deinit()`，所以量到的是"冷启动 + 一张图"。
fn timeOne(io: std.Io, allocator: std.mem.Allocator, path: []const u8, mode: Mode) f64 {
    if (mode == .isolated) thumb_host.deinit();
    const started = std.Io.Clock.Timestamp.now(io, .awake);
    if (fetch(mode, allocator, path)) |image| {
        var owned = image;
        owned.deinit(allocator);
    } else |_| {}
    return elapsedMs(io, started);
}

/// 200 张一遍。helper 在测量前已经是常驻的（冷启动那一张已经付过账）。
fn timeMany(io: std.Io, allocator: std.mem.Allocator, paths: []const []u8, mode: Mode) Timing {
    var timing = Timing{};
    const started = std.Io.Clock.Timestamp.now(io, .awake);
    for (paths) |path| {
        if (fetch(mode, allocator, path)) |image| {
            var owned = image;
            owned.deinit(allocator);
        } else |_| timing.failures += 1;
    }
    timing.total_ms = elapsedMs(io, started);
    return timing;
}

