//! 运行形态：dev / portable / installed（CHARTER 九）。
//!
//!   1. exe 同目录有 `otto-portable.flag` → portable（**标记**，不是路径猜测）
//!   2. exe 路径里有完整的 `zig-out` 路径段 → dev
//!   3. 其它 → installed
//!
//! 为了能单测，判定与路径拼装都是纯函数（`detectFrom` / `dataDirFor` /
//! `libraryPathFor`）：输入只有 exe 路径、标记是否存在，以及一个 `Env`。
//! 当前三种形态的数据目录都只由 exe 位置决定；`Env` 仅保留在纯函数签名中，
//! 不再用来寻找 dev 数据目录。碰文件系统的只有 `markerExists`。
//!
//! 三种形态的数据目录：
//!   * dev        `<zig-out 上一级>\.otto-dev`，开发数据留在项目目录，不写用户目录；
//!                默认库仍是 `fixtures/library.json`（相对 cwd，源码里的 fixture）
//!   * portable  `<exe 目录>\data`
//!   * installed `<安装根>\data`，exe 必须位于 `<安装根>\app`；缓存位于 `<安装根>\cache`
//!
//! installed 不读 `%APPDATA%\OTTO`，也不从旧结构迁移。安装根完全由 exe 位置推导。
//!
//! **编译产物（`zig-out`）不承载任何运行数据。** dev 数据位于源码树内、
//! `zig-out` 之外的 `.otto-dev`；该目录已加入 `.gitignore`，删掉不影响源码。

const std = @import("std");
const builtin = @import("builtin");
const import_target = @import("import_target.zig");

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

/// installed 的固定程序子目录：`<安装根>\app\otto-lite.exe`。
pub const install_app_dir_name = "app";

/// dev 形态的默认库文件（相对 cwd，和 `zig build run` 的工作目录一致）。
pub const dev_library_path = "fixtures/library.json";

/// 数据目录里的库文件名。
pub const library_file_name = "library.json";

/// 下载好的安装包放在 `<数据目录>\updates\`。
pub const updates_dir_name = "updates";

/// 纯函数的可选环境输入。当前路径计算不读取它；保留在签名里是为了让
/// “即使提供了用户目录也不能被使用”这一约束可以直接写成测试。
pub const Env = struct {
    appdata: ?[]const u8 = null,
    local_appdata: ?[]const u8 = null,
    temp: ?[]const u8 = null,

    pub fn deinit(self: *Env, allocator: std.mem.Allocator) void {
        if (self.appdata) |value| allocator.free(value);
        if (self.local_appdata) |value| allocator.free(value);
        if (self.temp) |value| allocator.free(value);
        self.* = .{};
    }
};

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

/// 从 exe 路径推导开发数据目录：`<zig-out 的上一级>\.otto-dev`。
/// 例如 `C:\src\otto-zig-lite\zig\app\zig-out\bin\otto-lite.exe`
/// → `C:\src\otto-zig-lite\zig\app\.otto-dev`。
/// 路径里没有完整 `zig-out` 段时返回 null，不回退用户目录。
pub fn devDataDirFromExe(allocator: std.mem.Allocator, exe_path: []const u8) !?[]u8 {
    const bin_dir = std.fs.path.dirname(exe_path) orelse return null;
    const zig_out = std.fs.path.dirname(bin_dir) orelse return null;
    if (!std.ascii.eqlIgnoreCase(std.fs.path.basename(zig_out), "zig-out")) return null;
    const project = std.fs.path.dirname(zig_out) orelse return null;
    return try std.fs.path.join(allocator, &.{ project, ".otto-dev" });
}

/// installed 的安装根。只认固定的 `app` 子目录，避免把任意绿色 exe 的父目录
/// 误当成数据根；路径非法是具名错误，绝不回退读取旧 `%APPDATA%\OTTO`。
pub fn installRootFor(allocator: std.mem.Allocator, exe_path: []const u8) ![]u8 {
    const app_dir = std.fs.path.dirname(exe_path) orelse return error.InstallRootUnavailable;
    if (!std.ascii.eqlIgnoreCase(std.fs.path.basename(app_dir), install_app_dir_name)) {
        return error.InstallRootUnavailable;
    }
    const root = std.fs.path.dirname(app_dir) orelse ".";
    return try allocator.dupe(u8, root);
}

/// 纯路径：形态 → 数据目录。
///
/// dev 的数据在项目内的 `.otto-dev`，**不在 `zig-out` 里，也不读用户目录**；
/// installed 由 `<根>\app\otto-lite.exe` 推出 `<根>\data`。
pub fn dataDirFor(
    allocator: std.mem.Allocator,
    mode: Mode,
    exe_path: []const u8,
    env: Env,
) !?[]u8 {
    _ = env;
    switch (mode) {
        .dev => return try devDataDirFromExe(allocator, exe_path),
        .portable => {
            const exe_dir = std.fs.path.dirname(exe_path) orelse ".";
            return try std.fs.path.join(allocator, &.{ exe_dir, "data" });
        },
        .installed => {
            const root = try installRootFor(allocator, exe_path);
            defer allocator.free(root);
            return try std.fs.path.join(allocator, &.{ root, "data" });
        },
    }
}

/// 纯路径：形态 → 下载目录。
///
/// 三种形态都放在各自的数据目录下；dev 也不例外——`zig-out` 里不留 `updates\`。
/// installed 路径非法时返回 null，由调用方报 `UpdatesDirUnavailable`；OOM 仍然是错误。
pub fn updatesDirFor(
    allocator: std.mem.Allocator,
    mode: Mode,
    exe_path: []const u8,
    env: Env,
) !?[]u8 {
    const data_dir = dataDirFor(allocator, mode, exe_path, env) catch |err| switch (err) {
        error.InstallRootUnavailable => return null,
        else => return err,
    };
    const resolved = data_dir orelse return null;
    defer allocator.free(resolved);
    return try std.fs.path.join(allocator, &.{ resolved, updates_dir_name });
}

/// 本进程的下载目录：和 `defaultLibraryPath` 一样从进程自身的 exe 路径判定形态。
/// installed 路径非法时返回 null——由调用方报具名错误，不猜旧目录。
pub fn updatesDir(allocator: std.mem.Allocator, io: std.Io) !?[]u8 {
    const exe_path = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(exe_path);
    const mode = try detect(allocator, io, exe_path);
    return updatesDirFor(allocator, mode, exe_path, .{});
}

/// 纯路径：形态 → 默认库文件。
pub fn libraryPathFor(
    allocator: std.mem.Allocator,
    mode: Mode,
    exe_path: []const u8,
    env: Env,
) ![]u8 {
    // dev 的库是源码里的 fixture，不是用户数据：它继续相对 cwd，不进数据目录。
    if (mode == .dev) return try allocator.dupe(u8, dev_library_path);
    const dir = (try dataDirFor(allocator, mode, exe_path, env)) orelse
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

/// 薄封装：形态 → 数据目录。dev 由 exe 所在的项目路径决定，不读取用户目录。
pub fn dataDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    mode: Mode,
    exe_path: []const u8,
) !?[]u8 {
    _ = io; // 保留参数：将来数据目录可能需要 Io（例如跟随重定向目录）。
    return dataDirFor(allocator, mode, exe_path, .{});
}

/// 启动时的默认库位置：dev 用 fixtures，其它在数据目录下。
/// `--version` 之外的正常启动都走这里，所以 exe 路径与标记都从进程自身取。
pub fn defaultLibraryPath(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const exe_path = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(exe_path);
    const mode = try detect(allocator, io, exe_path);
    return libraryPathFor(allocator, mode, exe_path, .{});
}

/// 启动/自检真正打开的默认库（`defaultLibraryPath` 之上再看一眼 `.otto`）。
///
/// 为什么需要：首次导入按 `import_target` 的规则把 JSON 位置写成同目录的
/// `library.otto`；下一次启动若只认名义上的 `library.json`，用户刚导入的素材
/// 就又变回空状态。`.otto` 存在就优先它（它是导入之后的真源），否则用名义
/// JSON（老用户的原库，不需要迁移）。
pub fn resolveDefaultLibrary(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const nominal = try defaultLibraryPath(allocator, io);
    return preferOtto(allocator, io, nominal);
}

/// `resolveDefaultLibrary` 的路径部分：`nominal` 归本函数所有（释放或原样返回）。
///
///   * 同目录 `<stem>.otto` 存在 → 返回它的副本，释放 nominal；
///   * 否则 → 原样返回 nominal（它也可能不存在：那就是首次启动）。
pub fn preferOtto(
    allocator: std.mem.Allocator,
    io: std.Io,
    nominal: []u8,
) error{OutOfMemory}![]u8 {
    var target = import_target.resolve(allocator, nominal, null) catch |err| switch (err) {
        error.OutOfMemory => {
            allocator.free(nominal);
            return error.OutOfMemory;
        },
    };
    defer target.deinit(allocator);
    // 名义路径本来就是 `.otto`：不用再挑，也绝不能拼成 `library.otto.otto`。
    if (std.mem.eql(u8, target.path, nominal)) return nominal;
    if (!fileExists(io, target.path)) return nominal;
    allocator.free(nominal);
    return allocator.dupe(u8, target.path);
}

/// 薄封装：只判"在不在"。查不了（没权限等）一律当"不在"——真正的读取失败
/// 会由 `library_io.open` 报具名错误，这里不制造第二种失败。
fn fileExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// 缩略图 L3 缓存目录的纯路径：`<dataDir>\cache\thumbs`；没有 dataDir 就是 null。
pub fn cacheDirFor(allocator: std.mem.Allocator, data_dir: ?[]const u8) !?[]u8 {
    const base = data_dir orelse return null;
    return try std.fs.path.join(allocator, &.{ base, "cache", "thumbs" });
}

/// 字体索引缓存的纯路径：`<dataDir>\cache\fonts.idx`；没有 dataDir 就是 null。
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
///
/// 首次启动时库所在目录可能**还不存在**（`<dataDir>` 还没建）：这条路径不能报
/// FileNotFound（那会变成"双击没反应"），而是按 cwd 给出绝对路径；没有监听根
/// 时 `live.Live.init` 不启动 watcher（目录不存在只是不监听的原因之一，见
/// `live.zig`）。`--watch` 是用户点名要监听的目录，仍按真实路径解析，不存在就是错误。
pub fn watchRoot(
    allocator: std.mem.Allocator,
    io: std.Io,
    watch_dir: ?[]const u8,
    library_path: []const u8,
) ![]u8 {
    const cwd = std.Io.Dir.cwd();
    if (watch_dir) |dir| return realPathDupe(allocator, cwd, io, dir);
    // `dirname` 对 "library.json" 返回 null：那时根就是 cwd，不能让 null 落到
    // 路径拼接里。
    const parent = std.fs.path.dirname(library_path) orelse ".";
    return realPathDupe(allocator, cwd, io, parent) catch |err| switch (err) {
        // 首次启动：库所在目录还不存在（`<dataDir>` 还没建）。这不是错误，
        // 给一个按 cwd 解析的绝对路径；`Live.init` 会据此不启动 watcher。
        error.FileNotFound => absolutePath(allocator, io, parent),
        else => |other| return other,
    };
}

/// 真实路径 → 普通 `[]u8`。
///
/// 不直接用 `realPathFileAlloc`：它返回 `[:0]u8`（分配里多一个尾 0），而调用方
/// 按普通切片释放；哨兵被抹掉后长度对不上，`testing.allocator` 会当场报
/// "free … mismatches allocation"。这里用栈缓冲 + `dupe`，长度与分配一致。
fn realPathDupe(
    allocator: std.mem.Allocator,
    cwd: std.Io.Dir,
    io: std.Io,
    path: []const u8,
) ![]u8 {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try cwd.realPathFile(io, path, &buffer);
    return try allocator.dupe(u8, buffer[0..len]);
}

/// 不碰文件系统的绝对化：把 `path` 拼到 cwd 上并归一化，不要求它存在。
/// 只用在"库所在目录还不存在"这一条路上。
fn absolutePath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    return try std.fs.path.resolveAlloc(allocator, &.{ cwd, path });
}

/// 启动时的缓存根：installed 是 `<安装根>`，其它形态仍使用自己的数据目录。
/// 这样安装版得到 `<根>\cache`，而不是把缓存藏回 `<根>\data\cache`。
fn startupCacheBaseDir(allocator: std.mem.Allocator, io: std.Io) !?[]u8 {
    const exe_path = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(exe_path);
    const mode = try detect(allocator, io, exe_path);
    if (mode == .installed) return try installRootFor(allocator, exe_path);
    return dataDir(allocator, io, mode, exe_path);
}

/// 启动时的 L3 缓存目录：installed 为 `<根>\cache\thumbs`，dev/portable 保持原位置。
/// 路径不可用就返回 null——缓存只是加速层，不值得让启动失败。
pub fn thumbsCacheDir(allocator: std.mem.Allocator, io: std.Io) !?[]u8 {
    const base = (try startupCacheBaseDir(allocator, io)) orelse return null;
    defer allocator.free(base);
    return cacheDirFor(allocator, base);
}

/// 启动时的字体索引缓存，与 L3 使用同一个缓存根。
pub fn fontCachePath(allocator: std.mem.Allocator, io: std.Io) !?[]u8 {
    const base = (try startupCacheBaseDir(allocator, io)) orelse return null;
    defer allocator.free(base);
    return fontCachePathFor(allocator, base);
}
