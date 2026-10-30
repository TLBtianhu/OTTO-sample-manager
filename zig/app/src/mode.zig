//! 运行形态：dev / portable / installed（CHARTER 九）。
//!
//!   1. exe 同目录有 `otto-portable.flag` → portable（**标记**，不是路径猜测）
//!   2. exe 路径里有完整的 `zig-out` 路径段 → dev
//!   3. 其它 → installed
//!
//! 为了能单测，判定与路径拼装都是纯函数（`detectFrom` / `dataDirFor` /
//! `libraryPathFor`）：输入只有 exe 路径、标记是否存在、%APPDATA% 的值。
//! 碰文件系统的只有 `markerExists`，碰进程环境的只有 `appData`——两个薄封装，
//! 加起来不到三十行。
//!
//! 三种形态的数据目录：
//!   * dev       不写用户目录（默认库是 `fixtures/library.json`，相对 cwd）
//!   * portable  `<exe 目录>\data`
//!   * installed `%APPDATA%\OTTO`

const std = @import("std");
const builtin = @import("builtin");

pub const Mode = enum {
    dev,
    portable,
    installed,

    /// `--version` 括号里的那个词，也是日志/诊断里用的名字。
    pub fn label(mode: Mode) []const u8 {
        return switch (mode) {
            .dev => "dev",
            .portable => "portable",
            .installed => "installed",
        };
    }
};

/// 便携版的唯一判据：与 exe 同目录。
pub const portable_marker = "otto-portable.flag";

/// 安装版在 %APPDATA% 下的目录名。
pub const installed_dir_name = "OTTO";

/// dev 形态的默认库文件（相对 cwd，和 `zig build run` 的工作目录一致）。
pub const dev_library_path = "fixtures/library.json";

/// 数据目录里的库文件名。
pub const library_file_name = "library.json";

// ---------------------------------------------------------------------------
// 纯函数：判定与路径
// ---------------------------------------------------------------------------

/// 纯判定：标记优先于路径。
///
/// 顺序是有意的：一个从 `zig-out` 里拷出来、旁边放着标记的目录必须算 portable，
/// 否则"用户把开发产物拷到 U 盘"就会悄悄写进 `%APPDATA%`。
pub fn detectFrom(exe_path: []const u8, marker_exists: bool) Mode {
    if (marker_exists) return .portable;
    if (hasZigOutSegment(exe_path)) return .dev;
    return .installed;
}

/// `zig-out` 必须是**完整路径段**：`C:\...\zig-out\bin\x.exe` 是 dev，
/// `myzig-out` / `zig-out2` 不是。Windows 上路径大小写不敏感，段比较忽略大小写。
pub fn hasZigOutSegment(exe_path: []const u8) bool {
    var segments = std.mem.tokenizeAny(u8, exe_path, "\\/");
    while (segments.next()) |segment| {
        if (std.ascii.eqlIgnoreCase(segment, "zig-out")) return true;
    }
    return false;
}

/// 纯路径：形态 → 数据目录。
///
/// dev 返回 null（不写用户目录）；installed 需要调用方给出 `%APPDATA%` 的值，
/// 拿不到就是显式错误——绝不悄悄退化成"写到当前目录"。
pub fn dataDirFor(
    allocator: std.mem.Allocator,
    mode: Mode,
    exe_path: []const u8,
    appdata: ?[]const u8,
) !?[]u8 {
    switch (mode) {
        .dev => return null,
        .portable => {
            const exe_dir = std.fs.path.dirname(exe_path) orelse ".";
            return try std.fs.path.join(allocator, &.{ exe_dir, "data" });
        },
        .installed => {
            const base = appdata orelse return error.AppDataDirUnavailable;
            return try std.fs.path.join(allocator, &.{ base, installed_dir_name });
        },
    }
}

/// 纯路径：形态 → 默认库文件。
pub fn libraryPathFor(
    allocator: std.mem.Allocator,
    mode: Mode,
    exe_path: []const u8,
    appdata: ?[]const u8,
) ![]u8 {
    if (mode == .dev) return try allocator.dupe(u8, dev_library_path);
    const dir = (try dataDirFor(allocator, mode, exe_path, appdata)) orelse
        return try allocator.dupe(u8, dev_library_path);
    defer allocator.free(dir);
    return try std.fs.path.join(allocator, &.{ dir, library_file_name });
}

// ---------------------------------------------------------------------------
// 薄封装：文件系统与进程环境
// ---------------------------------------------------------------------------

/// exe 同目录有没有便携标记。打不开目录 / 没有权限一律当"没有"——
/// 判定的失败方向是 installed，而不是让程序起不来。
pub fn markerExists(allocator: std.mem.Allocator, io: std.Io, exe_path: []const u8) bool {
    const exe_dir = std.fs.path.dirname(exe_path) orelse return false;
    const flag = std.fs.path.join(allocator, &.{ exe_dir, portable_marker }) catch return false;
    defer allocator.free(flag);
    std.Io.Dir.cwd().access(io, flag, .{}) catch return false;
    return true;
}

/// 薄封装：exe 路径 + 标记 → 形态。
pub fn detect(allocator: std.mem.Allocator, io: std.Io, exe_path: []const u8) !Mode {
    return detectFrom(exe_path, markerExists(allocator, io, exe_path));
}

/// 薄封装：形态 → 数据目录（installed 时读 %APPDATA%）。
pub fn dataDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    mode: Mode,
    exe_path: []const u8,
) !?[]u8 {
    _ = io; // 保留参数：将来数据目录可能需要 Io（例如跟随重定向目录）。
    const appdata = try appData(allocator);
    defer if (appdata) |value| allocator.free(value);
    return dataDirFor(allocator, mode, exe_path, appdata);
}

/// 启动时的默认库位置：dev 用 fixtures，其它在数据目录下。
/// `--version` 之外的正常启动都走这里，所以 exe 路径与标记都从进程自身取。
pub fn defaultLibraryPath(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const exe_path = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(exe_path);
    const mode = try detect(allocator, io, exe_path);
    const appdata = try appData(allocator);
    defer if (appdata) |value| allocator.free(value);
    return libraryPathFor(allocator, mode, exe_path, appdata);
}

/// 缩略图 L3 缓存目录的纯路径：`<dataDir>\cache\thumbs`；没有 dataDir 就是 null
/// （dev 形态不写盘，避免污染工程目录）。
pub fn cacheDirFor(allocator: std.mem.Allocator, data_dir: ?[]const u8) !?[]u8 {
    const base = data_dir orelse return null;
    return try std.fs.path.join(allocator, &.{ base, "cache", "thumbs" });
}

/// 字体索引缓存的纯路径：`<dataDir>\cache\fonts.idx`；没有 dataDir 就是 null
/// （dev 形态不写盘，行为和没有缓存时完全一样）。
pub fn fontCachePathFor(allocator: std.mem.Allocator, data_dir: ?[]const u8) !?[]u8 {
    const base = data_dir orelse return null;
    return try std.fs.path.join(allocator, &.{ base, "cache", "fonts.idx" });
}

/// 系统字体目录：字体索引描述的就是它，必须和 nanoui 扫描的目录一致。
/// 非 Windows 没有这个形态（app 本身只构建 Windows 目标）。
pub fn systemFontDir() ?[]const u8 {
    if (builtin.os.tag != .windows) return null;
    return "C:\\Windows\\Fonts";
}

/// 文件监听根：`--watch` 优先，否则用解析后的库文件所在目录；都解析成绝对路径，
/// 保证 join 出来的路径能和库里的 `filePath` 按字节比较。
///
/// 从 `main.zig` 挪到这里：`main` 要保持 ≤600 行（`--bench-first-frame` 的接线
/// 也要占几行），而"库路径 → 监听根"本来就是运行形态的一部分。
pub fn watchRoot(
    allocator: std.mem.Allocator,
    io: std.Io,
    watch_dir: ?[]const u8,
    library_path: []const u8,
) ![]const u8 {
    const cwd = std.Io.Dir.cwd();
    if (watch_dir) |dir| return try cwd.realPathFileAlloc(io, dir, allocator);
    const parent = std.fs.path.dirname(library_path) orelse ".";
    return try cwd.realPathFileAlloc(io, parent, allocator);
}

/// 启动时的数据目录：dev 没有（不写盘），其它形态按 exe 旁边的标记 /
/// %APPDATA% 判定；拿不到也是 null——缓存只是加速层，不值得让启动失败。
fn startupDataDir(allocator: std.mem.Allocator, io: std.Io) !?[]u8 {
    const exe_path = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(exe_path);
    const mode = try detect(allocator, io, exe_path);
    if (mode == .dev) return null;
    return dataDir(allocator, io, mode, exe_path);
}

/// 启动时的 L3 缓存目录：按运行形态取 dataDir 再拼 `cache/thumbs`。
/// dev 返回 null；其它形态拿不到 dataDir（例如 installed 没有 %APPDATA%）也返回
/// null——缓存只是加速层，不值得让启动失败。
pub fn thumbsCacheDir(allocator: std.mem.Allocator, io: std.Io) !?[]u8 {
    const data_dir = (try startupDataDir(allocator, io)) orelse return null;
    defer allocator.free(data_dir);
    return cacheDirFor(allocator, data_dir);
}

/// 启动时的字体索引缓存：按运行形态取 dataDir 再拼 `cache/fonts.idx`。
/// dev / 拿不到 dataDir → null（每次启动重扫，与没有这个功能时一致）。
pub fn fontCachePath(allocator: std.mem.Allocator, io: std.Io) !?[]u8 {
    const data_dir = (try startupDataDir(allocator, io)) orelse return null;
    defer allocator.free(data_dir);
    return fontCachePathFor(allocator, data_dir);
}

/// `%APPDATA%` 的薄封装。
///
/// `std.process.Init.environ_map` 只在 `main` 的签名里可见，而这里的函数签名
/// 不想把环境变量一路穿透下去；Zig 0.17 的 `Environ` 允许直接读进程环境块，
/// 这里用它。非 Windows 目标没有 `APPDATA` 这个概念，返回 null。
fn appData(allocator: std.mem.Allocator) !?[]u8 {
    var map = switch (builtin.os.tag) {
        .windows => std.process.Environ.createMap(.{ .block = .global }, allocator) catch return null,
        else => return null,
    };
    defer map.deinit();
    const value = map.get("APPDATA") orelse return null;
    return try allocator.dupe(u8, value);
}

// ---------------------------------------------------------------------------
// 测试：纯判定为主；最后一条用真临时目录验证"标记文件"这一薄封装
// ---------------------------------------------------------------------------

const testing = std.testing;

test "判定顺序：标记优先于 zig-out，zig-out 优先于 installed" {
    try testing.expectEqual(Mode.portable, detectFrom("C:\\src\\zig-out\\bin\\otto-lite.exe", true));
    try testing.expectEqual(Mode.portable, detectFrom("D:\\anywhere\\otto-lite.exe", true));
    try testing.expectEqual(Mode.dev, detectFrom("C:\\src\\zig-out\\bin\\otto-lite.exe", false));
    try testing.expectEqual(Mode.installed, detectFrom("C:\\Program Files\\OTTO Lite\\otto-lite.exe", false));
    try testing.expectEqual(Mode.installed, detectFrom("otto-lite.exe", false));
}

test "zig-out 必须是完整路径段" {
    // 正斜杠、反斜杠都算段分隔。
    try testing.expect(hasZigOutSegment("C:/src/zig-out/bin/otto-lite.exe"));
    try testing.expect(hasZigOutSegment("/home/me/zig-out/bin/otto-lite"));
    try testing.expect(hasZigOutSegment("\\\\server\\share\\zig-out\\otto-lite.exe"));
    // 只是名字里带 zig-out 的不算：否则用户目录会被误判成开发目录。
    try testing.expect(!hasZigOutSegment("C:\\src\\myzig-out\\bin\\otto-lite.exe"));
    try testing.expect(!hasZigOutSegment("C:\\src\\zig-out2\\bin\\otto-lite.exe"));
    try testing.expect(!hasZigOutSegment("C:\\src\\zig-out-backup\\otto-lite.exe"));
    try testing.expect(!hasZigOutSegment("C:\\src\\zig_out\\otto-lite.exe"));
}

test "数据目录：dev 不写用户目录，portable 在 exe 旁边，installed 在 %APPDATA%" {
    try testing.expect((try dataDirFor(testing.allocator, .dev, "C:\\src\\zig-out\\bin\\otto-lite.exe", "C:\\Users\\me\\AppData\\Roaming")) == null);

    const portable = (try dataDirFor(testing.allocator, .portable, "D:\\tools\\otto\\otto-lite.exe", "C:\\Users\\me\\AppData\\Roaming")).?;
    defer testing.allocator.free(portable);
    try testing.expectEqualStrings("D:\\tools\\otto\\data", portable);

    const installed = (try dataDirFor(testing.allocator, .installed, "C:\\Program Files\\OTTO Lite\\otto-lite.exe", "C:\\Users\\me\\AppData\\Roaming")).?;
    defer testing.allocator.free(installed);
    try testing.expectEqualStrings("C:\\Users\\me\\AppData\\Roaming\\OTTO", installed);
}

test "installed 拿不到 %APPDATA% 是显式错误，不落到当前目录" {
    try testing.expectError(
        error.AppDataDirUnavailable,
        dataDirFor(testing.allocator, .installed, "C:\\Program Files\\OTTO Lite\\otto-lite.exe", null),
    );
}

test "默认库文件：dev 用 fixtures，其余在数据目录下" {
    const dev = try libraryPathFor(testing.allocator, .dev, "C:\\src\\zig-out\\bin\\otto-lite.exe", null);
    defer testing.allocator.free(dev);
    try testing.expectEqualStrings("fixtures/library.json", dev);

    const portable = try libraryPathFor(testing.allocator, .portable, "D:\\tools\\otto\\otto-lite.exe", null);
    defer testing.allocator.free(portable);
    try testing.expectEqualStrings("D:\\tools\\otto\\data\\library.json", portable);

    const installed = try libraryPathFor(testing.allocator, .installed, "C:\\Program Files\\OTTO Lite\\otto-lite.exe", "C:\\Users\\me\\AppData\\Roaming");
    defer testing.allocator.free(installed);
    try testing.expectEqualStrings("C:\\Users\\me\\AppData\\Roaming\\OTTO\\library.json", installed);
}

test "exe 没有目录部分时，portable 的数据目录落在相对 data" {
    const dir = (try dataDirFor(testing.allocator, .portable, "otto-lite.exe", null)).?;
    defer testing.allocator.free(dir);
    try testing.expect(std.mem.endsWith(u8, dir, "data"));
    try testing.expect(!std.fs.path.isAbsolute(dir));
}

test "薄封装：标记只在 exe 同目录时成立" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(testing.io, &path_buffer);
    const root = path_buffer[0..root_len];

    const exe_path = try std.fs.path.join(testing.allocator, &.{ root, "otto-lite.exe" });
    defer testing.allocator.free(exe_path);

    // 没有标记：不在 zig-out 下 → installed。
    try testing.expect(!markerExists(testing.allocator, testing.io, exe_path));
    try testing.expectEqual(Mode.installed, try detect(testing.allocator, testing.io, exe_path));

    // 放了标记就是 portable，哪怕路径里本来没有 zig-out。
    try tmp.dir.writeFile(testing.io, .{ .sub_path = portable_marker, .data = "" });
    try testing.expect(markerExists(testing.allocator, testing.io, exe_path));
    try testing.expectEqual(Mode.portable, try detect(testing.allocator, testing.io, exe_path));

    // 标记在别的目录不算：判据必须是 exe 的邻居，不是"这台机器上有标记"。
    const other_exe = try std.fs.path.join(testing.allocator, &.{ root, "bin", "otto-lite.exe" });
    defer testing.allocator.free(other_exe);
    try testing.expect(!markerExists(testing.allocator, testing.io, other_exe));
}

test "薄封装：installed 的数据目录真的落在 %APPDATA% 下" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const dir = (try dataDir(testing.allocator, testing.io, .installed, "C:\\Program Files\\OTTO Lite\\otto-lite.exe")).?;
    defer testing.allocator.free(dir);
    try testing.expect(std.mem.endsWith(u8, dir, installed_dir_name));
    try testing.expect(std.fs.path.isAbsolute(dir));
}

test "L3 缓存目录：dataDir 下的 cache/thumbs；没有 dataDir 就是 null（dev 不写盘）" {
    try testing.expect((try cacheDirFor(testing.allocator, null)) == null);

    const dir = (try cacheDirFor(testing.allocator, "C:\\Users\\me\\AppData\\Roaming\\OTTO")).?;
    defer testing.allocator.free(dir);
    try testing.expectEqualStrings("C:\\Users\\me\\AppData\\Roaming\\OTTO\\cache\\thumbs", dir);
}
