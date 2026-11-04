//! 启动期最后的可见兜底：具名错误 / panic → 一份日志 + 一个 MessageBoxW。
//!
//! 正常路径只保存当前阶段，不读时钟、不碰文件、不建窗口。只有 `run` 收到错误，
//! 或根模块的 panic handler 被调用，才会写日志并弹窗。日志全部使用栈缓冲，避免
//! 在 OutOfMemory / panic 路径上再依赖一个可能已经无法工作的分配器。
//!
//! 路径与设置文件的形态规则一致：
//!   * dev       `<zig-out 上一级>\.otto-dev\crash.log`（开发数据留在项目目录）
//!   * portable  <exe>\data\crash.log
//!   * installed <安装根>\data\crash.log（exe 位于 <安装根>\app）
//! 安装版的 `app` 子目录只承载程序，永远不会成为日志目标。

const std = @import("std");
const builtin = @import("builtin");
const mode_mod = @import("mode.zig");
const version_mod = @import("version.zig");

pub const Stage = enum {
    startup,
    read_settings,
    read_library,
    create_window,
    first_frame,

    fn label(self: Stage) []const u8 {
        return @tagName(self);
    }
};

var process_init: ?std.process.Init = null;
var current_stage: Stage = .startup;

/// 根 `main` 的唯一入口。entry 成功或自行正常退出时，这里什么也不做。
pub fn run(init: std.process.Init, entry: *const fn (std.process.Init) anyerror!void) void {
    process_init = init;
    current_stage = .startup;
    entry(init) catch |err| fatal(init, @errorName(err), null);
}

/// 启动装配与建窗时更新；这只是内存中的一个 enum 写操作。
pub fn mark(stage: Stage) void {
    current_stage = stage;
}

/// 根模块通过 `std.debug.FullPanic(startup_dx.panic)` 接上所有 Zig 安全 panic。
pub fn panic(message: []const u8, return_address: ?usize) noreturn {
    if (process_init) |init| fatal(init, "Panic", message);
    // main 尚未进入（理论上）时没有可靠的 Io / 环境快照，交回标准实现。
    std.debug.defaultPanic(message, return_address);
}

fn fatal(init: std.process.Init, error_name: []const u8, detail: ?[]const u8) noreturn {
    var log_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const log_len = writeLog(init, error_name, detail, &log_buffer);
    const log_path: ?[]const u8 = if (log_len) |len| log_buffer[0..len] else null;

    // GUI 子系统也能写被重定向的 stderr；这给自动验收一条不依赖看图的证据。
    std.debug.print(
        "otto-lite: startup failed version={s} stage={s} error={s} log={s}\n",
        .{ version_mod.version, current_stage.label(), error_name, log_path orelse "unavailable" },
    );
    showMessage(error_name, log_path);
    std.process.exit(1);
}

/// 纯路径规则，运行时不分配。installed 的 app 路径非法时返回 null，绝不猜旧目录。
pub fn crashLogPathFor(
    buffer: []u8,
    mode: mode_mod.Mode,
    exe_path: []const u8,
) ?[]const u8 {
    switch (mode) {
        .portable => {
            const dir = std.fs.path.dirname(exe_path) orelse return null;
            return std.fmt.bufPrint(buffer, "{s}\\data\\crash.log", .{dir}) catch null;
        },
        .installed => {
            const app_dir = std.fs.path.dirname(exe_path) orelse return null;
            if (!std.ascii.eqlIgnoreCase(std.fs.path.basename(app_dir), mode_mod.install_app_dir_name)) return null;
            const root = std.fs.path.dirname(app_dir) orelse return null;
            return std.fmt.bufPrint(buffer, "{s}\\data\\crash.log", .{root}) catch null;
        },
        .dev => {
            const bin_dir = std.fs.path.dirname(exe_path) orelse return null;
            const zig_out = std.fs.path.dirname(bin_dir) orelse return null;
            if (!std.ascii.eqlIgnoreCase(std.fs.path.basename(zig_out), "zig-out")) return null;
            const project = std.fs.path.dirname(zig_out) orelse return null;
            return std.fmt.bufPrint(buffer, "{s}\\.otto-dev\\crash.log", .{project}) catch null;
        },
    }
}

/// 返回写入 log_buffer 的路径长度；任何诊断故障都只让日志 unavailable，不二次崩溃。
fn writeLog(
    init: std.process.Init,
    error_name: []const u8,
    detail: ?[]const u8,
    log_buffer: []u8,
) ?usize {
    var exe_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const exe_len = std.process.executablePath(init.io, &exe_buffer) catch return null;
    const exe_path = exe_buffer[0..exe_len];

    var marker_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const marker = if (std.fs.path.dirname(exe_path)) |dir|
        std.fmt.bufPrint(&marker_buffer, "{s}\\{s}", .{ dir, mode_mod.portable_marker }) catch null
    else
        null;
    const portable = if (marker) |path| blk: {
        std.Io.Dir.cwd().access(init.io, path, .{}) catch break :blk false;
        break :blk true;
    } else false;
    const mode = mode_mod.detectFrom(exe_path, portable);
    const log_path = crashLogPathFor(log_buffer, mode, exe_path) orelse return null;

    const parent = std.fs.path.dirname(log_path) orelse return null;
    std.Io.Dir.cwd().createDirPath(init.io, parent) catch return null;
    const file = std.Io.Dir.cwd().createFile(init.io, log_path, .{ .truncate = true }) catch return null;
    defer file.close(init.io);

    var time_buffer: [64]u8 = undefined;
    var windows_buffer: [96]u8 = undefined;
    var detail_buffer: [1024]u8 = undefined;
    const clean_detail = oneLine(&detail_buffer, detail orelse "none");
    var report_buffer: [8192]u8 = undefined;
    const report = std.fmt.bufPrint(&report_buffer,
        \\timestamp={s}
        \\version={s}
        \\windows={s}
        \\mode={s}
        \\stage={s}
        \\error={s}
        \\executable={s}
        \\detail={s}
        \\
    , .{
        localTime(&time_buffer), version_mod.version,   windowsVersion(&windows_buffer),
        mode.label(),            current_stage.label(), error_name,
        exe_path,                clean_detail,
    }) catch return null;
    file.writeStreamingAll(init.io, report) catch return null;
    return log_path.len;
}

/// 日志保持一行一个字段；panic 文案里的 CR/LF 不会伪装成新字段。
fn oneLine(buffer: []u8, text: []const u8) []const u8 {
    const len = @min(buffer.len, text.len);
    for (text[0..len], 0..) |ch, index| {
        buffer[index] = if (ch == '\r' or ch == '\n' or ch == 0) ' ' else ch;
    }
    return buffer[0..len];
}

const SystemTime = extern struct {
    year: u16,
    month: u16,
    day_of_week: u16,
    day: u16,
    hour: u16,
    minute: u16,
    second: u16,
    milliseconds: u16,
};

extern "kernel32" fn GetLocalTime(out: *SystemTime) callconv(.winapi) void;

fn localTime(buffer: []u8) []const u8 {
    if (builtin.os.tag != .windows) return "unavailable";
    var now = std.mem.zeroes(SystemTime);
    GetLocalTime(&now);
    return std.fmt.bufPrint(buffer, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}local", .{
        now.year, now.month, now.day, now.hour, now.minute, now.second, now.milliseconds,
    }) catch "unavailable";
}

fn windowsVersion(buffer: []u8) []const u8 {
    if (builtin.os.tag != .windows) return @tagName(builtin.os.tag);
    var info = std.mem.zeroes(std.os.windows.RTL_OSVERSIONINFOW);
    info.dwOSVersionInfoSize = @sizeOf(std.os.windows.RTL_OSVERSIONINFOW);
    if (std.os.windows.ntdll.RtlGetVersion(&info) != .SUCCESS) return "unknown";
    return std.fmt.bufPrint(buffer, "{d}.{d}.{d}", .{
        info.dwMajorVersion, info.dwMinorVersion, info.dwBuildNumber,
    }) catch "unknown";
}

extern "user32" fn MessageBoxW(
    owner: ?*anyopaque,
    text: [*:0]const u16,
    caption: [*:0]const u16,
    kind: u32,
) callconv(.winapi) i32;

fn showMessage(error_name: []const u8, log_path: ?[]const u8) void {
    if (builtin.os.tag != .windows) return;
    var text_buffer: [2048]u8 = undefined;
    const text = if (log_path) |path|
        std.fmt.bufPrint(
            &text_buffer,
            "OTTO 启动失败（{s}）。\n请重新启动；若仍失败，请把这份日志发给开发者：\n{s}",
            .{ error_name, path },
        ) catch "OTTO 启动失败。请重新启动；若仍失败，请联系开发者。"
    else
        "OTTO 启动失败。请重新启动；若仍失败，请联系开发者（日志目录不可写）。";
    var wide_buffer: [2048]u16 = undefined;
    const caption = std.unicode.utf8ToUtf16LeStringLiteral("OTTO Sample Manager");
    _ = MessageBoxW(null, wide(&wide_buffer, text), caption, 0x10); // MB_OK | MB_ICONERROR
}

/// 有效 UTF-8/WTF-8 正常转换；路径损坏或过长时仍保留一个可读的错误框。
fn wide(buffer: []u16, text: []const u8) [*:0]const u16 {
    const count = std.unicode.utf8ToUtf16Le(buffer[0 .. buffer.len - 1], text) catch blk: {
        const fallback = "OTTO startup failed; please restart and contact the developer.";
        for (fallback, 0..) |ch, index| buffer[index] = ch;
        break :blk fallback.len;
    };
    buffer[count] = 0;
    return @ptrCast(buffer.ptr);
}

test "dev 崩溃日志在项目内 .otto-dev，不写用户目录" {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = crashLogPathFor(&buffer, .dev, "C:\\src\\app\\zig-out\\bin\\otto-lite.exe").?;
    try std.testing.expectEqualStrings("C:\\src\\app\\.otto-dev\\crash.log", path);
    try std.testing.expect(std.mem.indexOf(u8, path, "AppData") == null);
    try std.testing.expect(std.mem.indexOf(u8, path, "zig-out") == null);
}

test "dev 崩溃日志路径没有 zig-out 段时不可用，不回退用户目录" {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try std.testing.expect(crashLogPathFor(&buffer, .dev, "C:\\tools\\otto-lite.exe") == null);
}
