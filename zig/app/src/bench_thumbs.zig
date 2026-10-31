//! 缩略图基准：100 个**全新路径**各取一次（冷），同一批路径再取一次（热）。
//!
//! **走的是行内小图同一条 provider 注册表**：`providers.registryForIcon(false).open`
//! （`image-wic` → `mf-video` → `shell-thumbnail`），不是旧的 `thumb_host.get`。
//! 这样 `--bench` 的缩略图一项量到的就是列表左侧那格 64px 的真实链路；PNG/BMP
//! 由 WIC 在进程内解，不再为每一张起 helper。计时与 fixture 的造法仍复用
//! `thumb_bench.zig`（`Copies` / `collectFiles` / `readAlongside` + 时钟），不另写一套。
//!
//! 冷/热的准确含义（报告里要按这个写，不能含糊）：
//!   * **冷**：100 个从没被 Shell 见过的文件名（真图字节复制而成），并且先
//!     `thumb_host.deinit()` 把 helper 收掉。首张包含 provider 的首次初始化
//!     （WIC 工厂 / 可能的 helper 启动），其余 99 张是「系统缓存未命中 + provider
//!     已就绪」；
//!   * **热**：同一批 100 个路径再跑一遍。系统级缩略图缓存 + provider 都已热，
//!     测的是"重复预览"的路径。
//!
//! **OTTO 自己的 L3（磁盘缩略图缓存）不在这条测量里**：`--bench` 不开 `Thumbs`，
//! 也不写用户目录（宪章第九节 dev 形态不落盘）。L3 的命中/未命中要靠带 mtime 与
//! 文件身份的 `Sample` 才能造出缓存键，属于下一轮「真实窗口 + 真 Thumbs」脚本的
//! 范围；`PERF.md` 把这条限制写清楚，不用假数字凑。

const std = @import("std");
const core = @import("otto_core");
const preview = @import("preview.zig");
const providers = @import("providers/root.zig");
const thumb_host = @import("otto_thumb_host");
const stats = @import("bench_stats.zig");
const thumb_bench = @import("thumb_bench.zig");

/// 每轮请求多少张（任务要求 100）。
pub const count: usize = 100;

/// 与 `thumbs.default_size_px` 对齐：列表那格 32 点、2x 屏 64px。
pub const size_px: u32 = 64;

pub const Report = struct {
    cold: stats.Summary = .{},
    hot: stats.Summary = .{},
    /// 冷轮第一张（含 helper 冷启动）：p95 之外单独看，别把一次进程启动摊进 p95。
    cold_first_ms: f64 = 0,
    hot_first_ms: f64 = 0,
    cold_failures: u32 = 0,
    hot_failures: u32 = 0,
};

/// 造好的 100 份拷贝。`paths()` 同时被计时与内存测量使用。
pub const Fixture = struct {
    copies: thumb_bench.Copies = .{},

    pub fn paths(self: *const Fixture) []const []u8 {
        return self.copies.paths.items;
    }

    pub fn deinit(self: *Fixture, io: std.Io, allocator: std.mem.Allocator) void {
        self.copies.deinit(io, allocator);
    }
};

/// 从一个真实素材目录里挑一张能出图的文件，拷成 100 个不同文件名。
pub fn prepare(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ_map: *std.process.Environ.Map,
    samples_dir: []const u8,
) !Fixture {
    const root = std.Io.Dir.cwd().realPathFileAlloc(io, samples_dir, allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NoSamples,
    };
    defer allocator.free(root);

    var files: std.ArrayList([]u8) = .empty;
    defer {
        for (files.items) |path| allocator.free(path);
        files.deinit(allocator);
    }
    thumb_bench.collectFiles(io, allocator, root, &files) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NoSamples,
    };
    if (files.items.len == 0) return error.NoSamples;

    const source = (try findIconSource(allocator, files.items)) orelse return error.NoImageSource;
    defer allocator.free(source);
    const bytes = try thumb_bench.readAlongside(io, allocator, root, source);
    defer allocator.free(bytes);

    var fixture = Fixture{};
    errdefer fixture.deinit(io, allocator);
    try fixture.copies.build(io, allocator, environ_map, root, source, bytes, count);
    return fixture;
}

/// 从一个目录里挑第一张 **provider 图标表真的能出图** 的栅格图片。
/// 只试图片扩展名：视频抽帧虽然也 icon_capable，但拿 100 个视频副本做 100 次
/// 首帧解码不是这条基准要量的事。
fn findIconSource(allocator: std.mem.Allocator, files: []const []u8) !?[]u8 {
    const registry = providers.registryForIcon(false);
    for (files) |path| {
        if (!isRasterImage(path)) continue;
        if (!try providerSucceeds(allocator, registry, path, 16)) continue;
        return try allocator.dupe(u8, path);
    }
    return null;
}

const raster_extensions = [_][]const u8{ ".png", ".jpg", ".jpeg", ".bmp", ".gif", ".tif", ".tiff" };

fn isRasterImage(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    for (raster_extensions) |known| {
        if (std.ascii.eqlIgnoreCase(ext, known)) return true;
    }
    return false;
}

/// 行内小图用的样本（app 侧没有 core.store 索引，路径就是唯一身份）。
fn sampleFor(path: []const u8) core.model.Sample {
    return .{
        .id = path,
        .file_name = std.fs.path.basename(path),
        .file_ext = std.fs.path.extension(path),
        .file_path = path,
    };
}

fn openIcon(
    allocator: std.mem.Allocator,
    registry: preview.Registry,
    path: []const u8,
    max_px: u32,
) preview.Error!preview.Outcome {
    var sample = sampleFor(path);
    return registry.open(allocator, .{
        .sample = &sample,
        .max_px = max_px,
        .icon = true,
    });
}

fn providerSucceeds(
    allocator: std.mem.Allocator,
    registry: preview.Registry,
    path: []const u8,
    max_px: u32,
) !bool {
    const outcome = openIcon(allocator, registry, path, max_px) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    var owned = outcome;
    defer owned.deinit(allocator);
    return switch (owned) {
        .image => true,
        else => false,
    };
}

/// 冷 + 热各 100 次。调用方先 `prepare`，拿到 `paths()` 再调这里。
pub fn measure(io: std.Io, allocator: std.mem.Allocator, paths: []const []u8) !Report {
    var report = Report{};

    // 冷：把 helper 收掉，首张包含 provider 的首次初始化（WIC 工厂 / 可能的 helper）。
    thumb_host.deinit();
    const cold = try timeRound(io, allocator, paths, &report.cold_failures);
    defer allocator.free(cold);
    if (cold.len > 0) report.cold_first_ms = cold[0];
    report.cold = stats.summarize(allocator, cold);

    // 热：同一批路径，WIC / helper 与系统缓存都还在。
    const hot = try timeRound(io, allocator, paths, &report.hot_failures);
    defer allocator.free(hot);
    if (hot.len > 0) report.hot_first_ms = hot[0];
    report.hot = stats.summarize(allocator, hot);

    return report;
}

/// 一轮：逐张计时，成功的一张记一个样本（毫秒）。失败只计数，不参与百分位。
fn timeRound(
    io: std.Io,
    allocator: std.mem.Allocator,
    paths: []const []u8,
    failures: *u32,
) ![]f64 {
    const registry = providers.registryForIcon(false);
    const samples = try allocator.alloc(f64, paths.len);
    var used: usize = 0;
    for (paths) |path| {
        const started = stats.now(io);
        var ok = false;
        if (openIcon(allocator, registry, path, size_px)) |outcome| {
            var owned = outcome;
            defer owned.deinit(allocator);
            switch (owned) {
                .image => ok = true,
                else => {},
            }
        } else |_| {}
        const elapsed = stats.sinceMs(io, started);
        if (ok) {
            samples[used] = elapsed;
            used += 1;
        } else {
            failures.* += 1;
        }
    }
    return samples[0..used];
}

/// 取图并**持有**：内存测量要在"已经取到 100 张缩略图"的状态下读 WorkingSetSize，
/// 第 3 项指标说的就是这个状态。调用方测完再 `deinit`。
pub const Held = struct {
    images: std.ArrayList(preview.Bitmap) = .empty,

    pub fn pixelsBytes(self: *const Held) usize {
        var total: usize = 0;
        for (self.images.items) |image| total += image.pixels.len;
        return total;
    }

    pub fn deinit(self: *Held, allocator: std.mem.Allocator) void {
        for (self.images.items) |image| image.deinit(allocator);
        self.images.deinit(allocator);
        self.* = .{};
    }
};

pub fn hold(allocator: std.mem.Allocator, paths: []const []u8) !Held {
    const registry = providers.registryForIcon(false);
    var held = Held{};
    errdefer held.deinit(allocator);
    for (paths) |path| {
        const outcome = openIcon(allocator, registry, path, size_px) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
        var owned = outcome;
        switch (owned) {
            .image => |bitmap| {
                held.images.append(allocator, bitmap) catch {
                    bitmap.deinit(allocator);
                    return error.OutOfMemory;
                };
            },
            else => owned.deinit(allocator),
        }
    }
    return held;
}

/// 收掉隔离 helper：`--bench` 退出前调一次，不留孤儿进程。
pub fn shutdown() void {
    thumb_host.deinit();
}
