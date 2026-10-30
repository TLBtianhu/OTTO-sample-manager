//! `--demo-thumbs <dir>`：不开窗口的取图自检。
//!
//! 建三个文件，覆盖三种结局：
//!   * `red.bmp`    —— 64×64、24 位真 BMP。系统有 image 缩略图 handler，Shell 能出图；
//!   * `tone.wav`   —— 合法的最小 PCM WAV。音频的结局是这台机器上「有 handler 但可能
//!     解不出像素」，用来覆盖 `thumb.get` 的失败分支；
//!   * `mystery.xyz`—— 故意用没人注册的扩展名，验证能力门禁**根本没把请求放进队列**。
//!
//! 同时往目录里写一份 `library.json`（三条样本、绝对路径），所以跑完可以直接用
//! `otto-lite.exe <dir>\library.json --nanoui-snapshot=thumb.png --nanoui-wait=2`
//! 看画面——不用另造 fixture。
//!
//! 判据（任何一条不成立 → 退出 1）：
//!   1. 等 `pending == 0`，不允许有请求永远挂着；
//!   2. BMP 必须 `ready` 且宽高 > 0、像素长度 = 跨度 × 高、alpha 已归一化成 255；
//!   3. 有 handler 的样本必须都进过队列（`requested` == handler 数）；
//!      没有 handler 的样本一次都不能进队列（`no_handler` == 两轮 × 无 handler 数）；
//!   4. 第二轮必须全部命中缓存（`cached` == `ready`），且 `ready` == `readyCount()`；
//!   5. 队列容量 32 > 3，不许丢请求（`dropped == 0`）。

const std = @import("std");
const core = @import("otto_core");
const caps = @import("otto_caps");
const thumbs_mod = @import("thumbs.zig");

/// 自检建的文件：名字 + 用途。
const demo_files = [_]struct { name: []const u8, what: []const u8 }{
    .{ .name = "red.bmp", .what = "64×64 真 BMP（红→暗红渐变）" },
    .{ .name = "tone.wav", .what = "8 kHz / 16 位 / 单声道 0.1s 静音" },
    .{ .name = "mystery.xyz", .what = "空文件，故意没有 handler" },
};

/// 等请求落地的最长时间。第三方 handler 卡住时由这里兜底（超时 = 失败）。
const settle_timeout_ms: u64 = 5000;

pub fn run(init: std.process.Init, allocator: std.mem.Allocator, dir_path: []const u8) !u8 {
    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, dir_path);
    // 绝对根：库里写绝对路径，`thumb.get` / `caps.forPath` 都按路径字节比对。
    const root = try cwd.realPathFileAlloc(io, dir_path, allocator);
    defer allocator.free(root);

    var dir = try cwd.openDir(io, dir_path, .{});
    defer dir.close(io);

    // 重跑同一个目录时先清场：旧文件会让「谁建的」说不清。
    for (demo_files) |file| dir.deleteFile(io, file.name) catch {};
    dir.deleteFile(io, "library.json") catch {};

    if (!try buildFiles(io, dir, allocator)) {
        std.debug.print("demo-thumbs: FAIL 建不出 BMP fixture（见上面的错误）\n", .{});
        return 1;
    }

    var paths: [demo_files.len][]const u8 = undefined;
    for (demo_files, 0..) |file, i| {
        paths[i] = try std.fs.path.join(allocator, &.{ root, file.name });
    }
    defer {
        for (paths) |path| allocator.free(path);
    }
    const json_text = try libraryJson(allocator, &paths);
    defer allocator.free(json_text);
    try dir.writeFile(io, .{ .sub_path = "library.json", .data = json_text });

    std.debug.print("demo-thumbs: root={s}\n", .{root});
    for (demo_files) |file| {
        std.debug.print("demo-thumbs: 建 {s}（{s}）\n", .{ file.name, file.what });
    }

    var library = try core.store.load(allocator, json_text);
    defer library.deinit();
    var thumbs = try thumbs_mod.Thumbs.init(allocator, io, .{});
    defer thumbs.deinit();

    // 期望：有 handler 的才该进队列；没有 handler 的必须被门禁挡下。
    var handler_count: u32 = 0;
    var gated_count: u32 = 0;
    for (library.samples) |sample| {
        const info = caps.forPath(allocator, sample.file_path) catch |err| {
            std.debug.print("demo-thumbs: FAIL caps.forPath({s})：{s}\n", .{ sample.file_path, @errorName(err) });
            return 1;
        };
        if (info.has_handler) handler_count += 1 else gated_count += 1;
    }

    // 第一轮：全部请求。此时缓存是空的，所以每一条有 handler 的都该入队。
    for (library.samples) |sample| _ = thumbs.acquire(sample);

    const settled = waitSettled(io, thumbs);
    var ok = true;
    check(&ok, settled, "等了 {d}ms 仍有请求没落地（pending={d}）", .{ settle_timeout_ms, thumbs.stats().pending });

    const first = thumbs.stats();
    check(&ok, first.requested == handler_count, "requested={d} 应等于有 handler 的样本数 {d}", .{ first.requested, handler_count });
    check(&ok, first.no_handler == gated_count, "no_handler={d} 应等于没有 handler 的样本数 {d}", .{ first.no_handler, gated_count });
    check(&ok, first.dropped == 0, "dropped={d} 不该丢请求（队列容量 32 > 3）", .{first.dropped});

    // 第二轮：逐条再问一次。有图的必须命中缓存，没 handler 的仍然被门禁挡下。
    var ready_entries: u32 = 0;
    for (library.samples) |sample| {
        const outcome = thumbs.acquire(sample);
        switch (outcome) {
            .ready => |view| {
                ready_entries += 1;
                std.debug.print(
                    "demo-thumbs: {s:<14} {d}×{d} 像素 {d}B alpha={d}（缓存命中）\n",
                    .{ sample.file_name, view.width, view.height, view.pixels.len, view.pixels[3] },
                );
                if (std.ascii.eqlIgnoreCase(std.fs.path.extension(sample.file_path), ".bmp")) {
                    check(&ok, view.width > 0 and view.height > 0, "{s}: 尺寸是 {d}×{d}", .{ sample.file_name, view.width, view.height });
                    check(&ok, view.pixels.len == view.stride * view.height, "{s}: 像素长度 {d} ≠ 跨度×高 {d}", .{ sample.file_name, view.pixels.len, view.stride * view.height });
                    check(&ok, view.pixels[3] == 255, "{s}: alpha 没归一化（{d}）", .{ sample.file_name, view.pixels[3] });
                }
            },
            .pending => {
                check(&ok, false, "{s}: 第二轮还 pending（没落地）", .{sample.file_name});
            },
            .no_handler => {
                check(&ok, !hasHandler(allocator, sample.file_path), "{s}: 有 handler 却被门禁挡下", .{sample.file_name});
                std.debug.print("demo-thumbs: {s:<14} 无预览（能力门禁，没调 thumb.get）\n", .{sample.file_name});
            },
            .failed => {
                std.debug.print("demo-thumbs: {s:<14} 取图失败（文件没了 / Shell 出错）\n", .{sample.file_name});
            },
        }
    }
    thumbs.beginFrame();

    const stats = thumbs.stats();
    check(&ok, ready_entries == stats.ready, "第二轮命中 {d} 条，但 ready={d}", .{ ready_entries, stats.ready });
    check(&ok, stats.cached == stats.ready, "cached={d} 应等于 ready={d}（第二轮全部命中）", .{ stats.cached, stats.ready });
    check(&ok, stats.ready == thumbs.readyCount(), "readyCount()={d} 与账上 ready={d} 不一致", .{ thumbs.readyCount(), stats.ready });
    check(&ok, stats.ready >= 1, "一张图都没取到（BMP 必须能出图）", .{});
    check(&ok, stats.dropped == 0, "dropped={d}", .{stats.dropped});

    std.debug.print(
        "demo-thumbs: requested={d} ready={d} no_handler={d} cached={d} failed={d} dropped={d} pending={d} entries={d} bytes={d}\n",
        .{ stats.requested, stats.ready, stats.no_handler, stats.cached, stats.failed, stats.dropped, stats.pending, stats.entries, stats.bytes },
    );

    // 给下一步用：这份 fixture 可以直接拿去看画面。
    std.debug.print("demo-thumbs: 画面自检：otto-lite.exe {s}\\library.json --nanoui-snapshot=thumb.png --nanoui-wait=2\n", .{root});

    if (!ok) {
        std.debug.print("demo-thumbs: FAIL\n", .{});
        return 1;
    }
    std.debug.print("demo-thumbs: OK\n", .{});
    return 0;
}

fn hasHandler(allocator: std.mem.Allocator, path: []const u8) bool {
    const info = caps.forPath(allocator, path) catch return false;
    return info.has_handler;
}

fn check(ok: *bool, condition: bool, comptime fmt: []const u8, args: anytype) void {
    if (condition) return;
    ok.* = false;
    std.debug.print("demo-thumbs: FAIL " ++ fmt ++ "\n", args);
}

/// 每 2ms 看一次账，直到 `pending == 0`。返回 false = 超时。
fn waitSettled(io: std.Io, thumbs: *thumbs_mod.Thumbs) bool {
    var waited: u64 = 0;
    while (waited < settle_timeout_ms) : (waited += 2) {
        if (thumbs.stats().pending == 0) return true;
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(2), .awake) catch return false;
    }
    return thumbs.stats().pending == 0;
}

// ---------------------------------------------------------------------------
// fixture：真 BMP / 最小 WAV / 空文件
// ---------------------------------------------------------------------------

fn buildFiles(io: std.Io, dir: std.Io.Dir, allocator: std.mem.Allocator) !bool {
    writeBmp(io, dir, allocator, "red.bmp", .{ 0, 0, 220 }, .{ 0, 0, 70 }) catch |err| {
        std.debug.print("demo-thumbs: 写 red.bmp 失败：{s}\n", .{@errorName(err)});
        return false;
    };
    writeWav(io, dir, allocator, "tone.wav") catch |err| {
        std.debug.print("demo-thumbs: 写 tone.wav 失败：{s}\n", .{@errorName(err)});
        return false;
    };
    var file = dir.createFile(io, "mystery.xyz", .{}) catch |err| {
        std.debug.print("demo-thumbs: 建 mystery.xyz 失败：{s}\n", .{@errorName(err)});
        return false;
    };
    file.close(io);
    return true;
}

/// 24 位 BMP 的 14 + 40 字节头；像素行自底向上，每行按 4 字节对齐。
const bmp_header_bytes: usize = 54;
const bmp_width: u32 = 64;
const bmp_height: u32 = 64;

/// 写一张 64×64 的 24 位 BMP：从 `top` 到 `bottom` 的竖直渐变（BGR 顺序）。
fn writeBmp(
    io: std.Io,
    dir: std.Io.Dir,
    allocator: std.mem.Allocator,
    name: []const u8,
    top: [3]u8,
    bottom: [3]u8,
) !void {
    const width: usize = bmp_width;
    const height: usize = bmp_height;
    const stride: usize = ((width * 3 + 3) / 4) * 4;
    const pixel_bytes = stride * height;
    const bytes = try allocator.alloc(u8, bmp_header_bytes + pixel_bytes);
    defer allocator.free(bytes);
    @memset(bytes, 0);

    bytes[0] = 'B';
    bytes[1] = 'M';
    std.mem.writeInt(u32, bytes[2..6], @intCast(bytes.len), .little);
    std.mem.writeInt(u32, bytes[10..14], bmp_header_bytes, .little);
    std.mem.writeInt(u32, bytes[14..18], 40, .little);
    std.mem.writeInt(i32, bytes[18..22], @intCast(width), .little);
    std.mem.writeInt(i32, bytes[22..26], @intCast(height), .little);
    std.mem.writeInt(u16, bytes[26..28], 1, .little);
    std.mem.writeInt(u16, bytes[28..30], 24, .little);
    std.mem.writeInt(u32, bytes[30..34], 0, .little);
    std.mem.writeInt(u32, bytes[34..38], @intCast(pixel_bytes), .little);
    std.mem.writeInt(i32, bytes[38..42], 2835, .little);
    std.mem.writeInt(i32, bytes[42..46], 2835, .little);

    // 文件里的第一行是图像最下面那行。
    for (0..height) |row| {
        const y = height - 1 - row;
        const t: u32 = @intCast(y * 255 / (height - 1));
        const start = bmp_header_bytes + row * stride;
        for (0..width) |x| {
            for (0..3) |channel| {
                const a: u32 = top[channel];
                const b: u32 = bottom[channel];
                bytes[start + x * 3 + channel] = @intCast((a * (255 - t) + b * t) / 255);
            }
        }
    }

    try dir.writeFile(io, .{ .sub_path = name, .data = bytes });
}

/// 最小合法 WAV：8 kHz / 16 位 / 单声道 / 0.1 秒静音（1600 字节 PCM）。
fn writeWav(io: std.Io, dir: std.Io.Dir, allocator: std.mem.Allocator, name: []const u8) !void {
    const sample_rate: u32 = 8000;
    const data_bytes: u32 = 1600;
    const bytes = try allocator.alloc(u8, 44 + data_bytes);
    defer allocator.free(bytes);
    @memset(bytes, 0);

    @memcpy(bytes[0..4], "RIFF");
    std.mem.writeInt(u32, bytes[4..8], 36 + data_bytes, .little);
    @memcpy(bytes[8..12], "WAVE");
    @memcpy(bytes[12..16], "fmt ");
    std.mem.writeInt(u32, bytes[16..20], 16, .little);
    std.mem.writeInt(u16, bytes[20..22], 1, .little);
    std.mem.writeInt(u16, bytes[22..24], 1, .little);
    std.mem.writeInt(u32, bytes[24..28], sample_rate, .little);
    std.mem.writeInt(u32, bytes[28..32], sample_rate * 2, .little);
    std.mem.writeInt(u16, bytes[32..34], 2, .little);
    std.mem.writeInt(u16, bytes[34..36], 16, .little);
    @memcpy(bytes[36..40], "data");
    std.mem.writeInt(u32, bytes[40..44], data_bytes, .little);

    try dir.writeFile(io, .{ .sub_path = name, .data = bytes });
}

/// 内存里拼一份最小 electron-store 快照：3 条样本，路径是绝对路径。
fn libraryJson(allocator: std.mem.Allocator, paths: []const []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;

    try writer.writeAll("{\"samples\":{");
    for (paths, 0..) |path, i| {
        if (i != 0) try writer.writeByte(',');
        try writer.print("\"demo-{d}\":{{\"filePath\":", .{i + 1});
        try std.json.Stringify.encodeJsonString(path, .{}, writer);
        try writer.writeByte('}');
    }
    try writer.writeAll("}}");
    return out.toOwnedSlice();
}
