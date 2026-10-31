//! 应用设置的持久化：一个小的 JSON 文件。
//!
//! ## 位置（三种形态都在各自的数据目录，`zig-out` 里不写）
//!
//!   * dev：`%LOCALAPPDATA%\OTTO\dev\settings.json`——开发者的本地目录，
//!     删掉不影响源码；**编译产物本身不承载运行数据**。
//!   * portable：`<exe 目录>\data\settings.json`。
//!   * installed：`%APPDATA%\OTTO\settings.json`。
//!
//! 三种都写 `<dataDir>\settings.json`（与库文件同一个数据目录）；dataDir 拿不到
//! 时退回内存态，绝不猜路径。
//!
//! ## 格式
//!
//! ```json
//! {"always_on_top":false,"update_url":null,"l2_budget_mib":64,"l3_budget_mib":256,"opacity":255}
//! ```
//!
//! 缺字段用默认值，未知字段忽略，坏 JSON / 读不到 / 类型不对**一律**回到默认值：
//! 设置文件坏了只该丢设置，不该让应用起不来（没有弹窗）。
//! **例外是 `opacity` 的越界值**：它是个 u8，手改出来的 300 / -5 不该让整份设置
//! 回默认（那会把用户的置顶与预算一起丢掉），所以按 0..255 钳住。
//!
//! ## 写
//!
//! 走 `ports/library_file.writeAtomic`：同目录 `.tmp` → `File.sync` →
//! `MoveFileExW(MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)`。目标目录
//! 不存在时先建（portable 第一次启动时 data 目录可能还没被库文件创建）。
//!
//! 本文件只做"值 ↔ 字节 ↔ 文件"，不认识 UI；面板在 `settings_ui.zig`。

const std = @import("std");
const library_file = @import("otto_library_file");
const mode_mod = @import("mode.zig");

/// 设置文件的上限。五个字段的 JSON 不到 300 字节；64 KiB 只用来拒绝
/// "把别的文件改名成 settings.json"这种明显不对的输入，不是产品策略。
pub const max_file_bytes: usize = 64 * 1024;

/// 更新源的最大字节数。和 `update_ui.Report.url` 的缓冲同一个量级。
pub const max_update_url: usize = 1024;

/// 预算字段的上限（MiB）。core 的缓存上限是 1 GiB；这里把设置也夹到同一档，
/// 避免 `u32 * MiB` 在 32 位目标上绕出新花样。
pub const max_budget_mib: u32 = 1024;

pub const default_l2_mib: u32 = 64;
pub const default_l3_mib: u32 = 256;
/// 窗口不透明度默认值：255 = 完全不透明（和没有这个功能时一样）。
pub const default_opacity: u8 = 255;

/// 百分比（0..100）→ 0..255 的 alpha。四舍五入，越界钳住。
///
/// 设置面板的滑块是浮点的（`ui.slider` 的入参），持久化的是 u8；先转成
/// 0..255 再存，读回来时 `alpha * 100 / 255` 正好能还原成同一个百分比
/// （60% → 153 → 60.0%）。
pub fn alphaFromPercent(percent: f32) u8 {
    // NaN / inf 不该走到这里（滑块和测试给的都是有限数）；真来了按"不透明"
    // 处理，而不是让 `@intFromFloat` 在安全模式下 panic。
    if (!std.math.isFinite(percent)) return default_opacity;
    const clamped = std.math.clamp(percent, 0, 100);
    return @intFromFloat(@round(clamped * 255.0 / 100.0));
}

/// 0..255 → 0..100 的百分比（滑块的初始位置）。
pub fn percentFromAlpha(alpha: u8) f32 {
    return @as(f32, @floatFromInt(alpha)) * 100.0 / 255.0;
}

/// 数据目录里的文件名。
pub const file_name = "settings.json";

pub const Settings = struct {
    /// 更新源字符串的分配器（只有 `update_url` 用它）。
    allocator: std.mem.Allocator,
    /// 窗口置顶。启动时应用一次；面板里的开关改完立即生效、关闭时持久化。
    always_on_top: bool = false,
    /// 窗口整体不透明度：0 = 全透明，255 = 完全不透明。启动时应用一次，滑块
    /// 拖动时立即生效、关闭面板时持久化（见 `settings_ui.zig`）。
    opacity: u8 = default_opacity,
    /// 更新 feed 地址；null = 未配置（点击「检查更新」只提示，不联网）。
    update_url: ?[]u8 = null,
    /// L2（缩略图内存缓存）预算，MiB。
    l2_budget_mib: u32 = default_l2_mib,
    /// L3（缩略图磁盘缓存）预算，MiB。
    l3_budget_mib: u32 = default_l3_mib,

    pub fn init(allocator: std.mem.Allocator) Settings {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Settings) void {
        if (self.update_url) |value| self.allocator.free(value);
        self.* = undefined;
    }

    pub fn l2BudgetBytes(self: *const Settings) usize {
        return @as(usize, @min(self.l2_budget_mib, max_budget_mib)) * 1024 * 1024;
    }

    pub fn l3BudgetBytes(self: *const Settings) u64 {
        return @as(u64, @min(self.l3_budget_mib, max_budget_mib)) * 1024 * 1024;
    }

    /// 换更新源：去掉首尾空白，空串 = 未配置（null）。
    /// 超长是显式错误——截断一个 URL 比"没改"更糟。
    pub fn setUpdateUrl(self: *Settings, text: []const u8) error{ OutOfMemory, UrlTooLong }!void {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len > max_update_url) return error.UrlTooLong;
        const copy: ?[]u8 = if (trimmed.len == 0) null else try self.allocator.dupe(u8, trimmed);
        if (self.update_url) |old| self.allocator.free(old);
        self.update_url = copy;
    }

    /// 一行可贴进日志的摘要。
    pub fn describe(self: *const Settings, buffer: []u8) []const u8 {
        return std.fmt.bufPrint(
            buffer,
            "always_on_top={} update_url={s} l2_budget_mib={d} l3_budget_mib={d} opacity={d}",
            .{
                self.always_on_top,
                self.update_url orelse "(未配置)",
                self.l2_budget_mib,
                self.l3_budget_mib,
                self.opacity,
            },
        ) catch "?";
    }

    /// 序列化成一行紧凑 JSON。调用方释放。
    pub fn toJson(self: *const Settings, allocator: std.mem.Allocator) ![]u8 {
        return std.json.Stringify.valueAlloc(allocator, .{
            .always_on_top = self.always_on_top,
            .update_url = self.update_url,
            .l2_budget_mib = self.l2_budget_mib,
            .l3_budget_mib = self.l3_budget_mib,
            .opacity = self.opacity,
        }, .{});
    }

    /// 原子写。目标目录不存在时先建；路径为空（内存态）返回 `error.NoPath`。
    pub fn save(self: *const Settings, io: std.Io, path: ?[]const u8) !void {
        const resolved = path orelse return error.NoPath;
        const bytes = try self.toJson(self.allocator);
        defer self.allocator.free(bytes);
        if (std.fs.path.dirname(resolved)) |dir| try std.Io.Dir.cwd().createDirPath(io, dir);
        try library_file.writeAtomic(self.allocator, io, resolved, bytes);
    }
};

// ---------------------------------------------------------------------------
// 路径
// ---------------------------------------------------------------------------

/// 纯路径：形态 → 数据目录下的 `settings.json`。
/// dataDir 拿不到（installed 没有 %APPDATA%，dev 没有 LOCALAPPDATA/TEMP）返回 null。
pub fn pathFor(
    allocator: std.mem.Allocator,
    mode: mode_mod.Mode,
    exe_path: []const u8,
    env: mode_mod.Env,
) !?[]u8 {
    const data_dir = (try mode_mod.dataDirFor(allocator, mode, exe_path, env)) orelse return null;
    defer allocator.free(data_dir);
    return try std.fs.path.join(allocator, &.{ data_dir, file_name });
}

/// 本进程的设置路径。判定与 `%APPDATA%` / `%LOCALAPPDATA%` 都走 `mode.zig`
/// 的同一条路径——这里不重新发明"什么算 portable"。
pub fn resolvePath(allocator: std.mem.Allocator, io: std.Io) !?[]u8 {
    const exe_path = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(exe_path);
    const mode = try mode_mod.detect(allocator, io, exe_path);
    const data_dir = (try mode_mod.dataDir(allocator, io, mode, exe_path)) orelse return null;
    defer allocator.free(data_dir);
    return try std.fs.path.join(allocator, &.{ data_dir, file_name });
}

// ---------------------------------------------------------------------------
// 读 / 解码
// ---------------------------------------------------------------------------

/// 解码一段 JSON。**永不失败**：坏 JSON、类型不对、内存不够都回到默认值。
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) Settings {
    const Wire = struct {
        always_on_top: bool = false,
        update_url: ?[]const u8 = null,
        l2_budget_mib: u32 = default_l2_mib,
        l3_budget_mib: u32 = default_l3_mib,
        /// 用 i64 接：手改出来的 300 / -5 要能读进来再钳到 0..255，用 u8 的话
        /// 300 会让整份解析失败、把别的设置一起丢回默认值。
        opacity: i64 = default_opacity,
    };

    var parsed = std.json.parseFromSlice(Wire, allocator, bytes, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        std.debug.print("otto-lite: settings 解析失败（{s}），用默认值\n", .{@errorName(err)});
        return Settings.init(allocator);
    };
    defer parsed.deinit();

    var settings = Settings.init(allocator);
    settings.always_on_top = parsed.value.always_on_top;
    // 缺字段时 Wire 的默认值已经生效；这里再夹一次范围，防止手改出来的天文数字。
    settings.l2_budget_mib = @min(parsed.value.l2_budget_mib, max_budget_mib);
    settings.l3_budget_mib = @min(parsed.value.l3_budget_mib, max_budget_mib);
    settings.opacity = @intCast(std.math.clamp(parsed.value.opacity, 0, 255));
    if (parsed.value.update_url) |text| {
        settings.setUpdateUrl(text) catch |err| switch (err) {
            error.UrlTooLong => std.debug.print(
                "otto-lite: settings update_url 超过 {d} 字节，忽略\n",
                .{max_update_url},
            ),
            error.OutOfMemory => {},
        };
    }
    return settings;
}

/// 读设置文件并打印一行摘要。**永不失败**：文件不存在 / 损坏 / 读不了都用默认值。
pub fn load(allocator: std.mem.Allocator, io: std.Io, path: ?[]const u8) Settings {
    const resolved = path orelse {
        std.debug.print("otto-lite: settings 无数据目录，本次用内存态默认值\n", .{});
        return Settings.init(allocator);
    };
    const bytes = library_file.readAll(allocator, io, resolved, max_file_bytes) catch |err| {
        std.debug.print(
            "otto-lite: settings path={s} 读不到（{s}），用默认值\n",
            .{ resolved, @errorName(err) },
        );
        return Settings.init(allocator);
    };
    defer allocator.free(bytes);

    const settings = decode(allocator, bytes);
    var buffer: [256]u8 = undefined;
    std.debug.print("otto-lite: settings path={s} {s}\n", .{ resolved, settings.describe(&buffer) });
    return settings;
}

// ---------------------------------------------------------------------------
// 测试：真临时目录 + 真原子写（坏文件只回默认值，不向上抛错）
// ---------------------------------------------------------------------------

const testing = std.testing;

fn tempPath(tmp: *testing.TmpDir, name: []const u8) ![]u8 {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(testing.io, &buffer);
    return std.fs.path.join(testing.allocator, &.{ buffer[0..length], name });
}

test "round-trip：五个字段经原子写读回来一模一样（含 URL 转义与 opacity）" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tempPath(&tmp, "settings.json");
    defer testing.allocator.free(path);

    var original = Settings.init(testing.allocator);
    defer original.deinit();
    original.always_on_top = true;
    original.l2_budget_mib = 96;
    original.l3_budget_mib = 512;
    original.opacity = alphaFromPercent(60);
    try testing.expectEqual(@as(u8, 153), original.opacity);
    try original.setUpdateUrl("https://example.com/feed.json?channel=dev&lang=zh");

    try original.save(testing.io, path);
    try tmp.dir.access(testing.io, "settings.json", .{});

    var loaded = load(testing.allocator, testing.io, path);
    defer loaded.deinit();
    try testing.expect(loaded.always_on_top);
    try testing.expectEqual(@as(u32, 96), loaded.l2_budget_mib);
    try testing.expectEqual(@as(u32, 512), loaded.l3_budget_mib);
    try testing.expectEqual(@as(u8, 153), loaded.opacity);
    try testing.expectEqualStrings("https://example.com/feed.json?channel=dev&lang=zh", loaded.update_url.?);

    // 重复写同一个目标：旧文件被替换，不是追加。
    original.always_on_top = false;
    original.opacity = default_opacity;
    try original.save(testing.io, path);
    var again = load(testing.allocator, testing.io, path);
    defer again.deinit();
    try testing.expect(!again.always_on_top);
    try testing.expectEqual(default_opacity, again.opacity);
}

test "缺字段用默认值；空 URL 读回来是 null" {
    const text =
        \\{"always_on_top":true}
    ;
    var settings = decode(testing.allocator, text);
    defer settings.deinit();
    try testing.expect(settings.always_on_top);
    try testing.expect(settings.update_url == null);
    try testing.expectEqual(default_l2_mib, settings.l2_budget_mib);
    try testing.expectEqual(default_l3_mib, settings.l3_budget_mib);
    try testing.expectEqual(default_opacity, settings.opacity);

    const empty_url =
        \\{"update_url":""}
    ;
    var clear = decode(testing.allocator, empty_url);
    defer clear.deinit();
    try testing.expect(clear.update_url == null);
}

test "坏 JSON / 类型不对：回到默认值，不报错" {
    const cases = [_][]const u8{
        "{",
        "not json at all",
        "",
        \\{"always_on_top":"yes","l2_budget_mib":"64"}
        ,
        \\{"l2_budget_mib":-1}
        ,
    };
    for (cases) |text| {
        var settings = decode(testing.allocator, text);
        defer settings.deinit();
        try testing.expect(!settings.always_on_top);
        try testing.expect(settings.update_url == null);
        try testing.expectEqual(default_l2_mib, settings.l2_budget_mib);
        try testing.expectEqual(default_l3_mib, settings.l3_budget_mib);
        try testing.expectEqual(default_opacity, settings.opacity);
    }
}

test "未知字段忽略；手改的超大预算与 opacity 夹到上限" {
    const text =
        \\{"always_on_top":true,"future_field":{"nested":[1,2,3]},"l2_budget_mib":999999,"l3_budget_mib":999999,"opacity":70000}
    ;
    var settings = decode(testing.allocator, text);
    defer settings.deinit();
    try testing.expect(settings.always_on_top);
    try testing.expectEqual(max_budget_mib, settings.l2_budget_mib);
    try testing.expectEqual(max_budget_mib, settings.l3_budget_mib);
    try testing.expectEqual(@as(u8, 255), settings.opacity);
}

test "opacity 越界钳到 0..255，而不是让整份设置回默认" {
    // 负数 → 0；超 255 → 255。别的字段仍然按文件里的值读（不能因为一个越界
    // 数字就把置顶/预算一起丢掉）。
    const low =
        \\{"always_on_top":true,"opacity":-5,"l2_budget_mib":96}
    ;
    var negative = decode(testing.allocator, low);
    defer negative.deinit();
    try testing.expect(negative.always_on_top);
    try testing.expectEqual(@as(u32, 96), negative.l2_budget_mib);
    try testing.expectEqual(@as(u8, 0), negative.opacity);

    const high =
        \\{"opacity":4096}
    ;
    var too_big = decode(testing.allocator, high);
    defer too_big.deinit();
    try testing.expectEqual(@as(u8, 255), too_big.opacity);
}

test "百分比 ↔ alpha：60% = 153、100% = 255、越界钳住、往返不漂" {
    try testing.expectEqual(@as(u8, 153), alphaFromPercent(60));
    try testing.expectEqual(@as(u8, 255), alphaFromPercent(100));
    try testing.expectEqual(@as(u8, 0), alphaFromPercent(0));
    try testing.expectEqual(@as(u8, 255), alphaFromPercent(120));
    try testing.expectEqual(@as(u8, 0), alphaFromPercent(-10));
    // 四舍五入：0.5% 落在 1（1.275 → 1），99.9% 落在 255（254.7 → 255）。
    try testing.expectEqual(@as(u8, 1), alphaFromPercent(0.5));
    try testing.expectEqual(@as(u8, 255), alphaFromPercent(99.9));
    // NaN 不 panic：按"不透明"处理（滑块的浮点值也可能是 NaN 之外的脏值，
    // 但这条边界至少不会让程序在安全模式下崩）。
    try testing.expectEqual(default_opacity, alphaFromPercent(std.math.nan(f32)));

    try testing.expectEqual(@as(f32, 60), percentFromAlpha(153));
    try testing.expectEqual(@as(f32, 100), percentFromAlpha(255));
    try testing.expectEqual(@as(f32, 0), percentFromAlpha(0));

    // 往返：256 个 alpha 全部落回同一个值（存 u8 不会因为浮点漂移变一格）。
    var alpha: u16 = 0;
    while (alpha <= 255) : (alpha += 1) {
        const round_trip = alphaFromPercent(percentFromAlpha(@intCast(alpha)));
        if (round_trip != alpha) {
            std.debug.print("opacity round-trip 漂了：{d} -> {d}\n", .{ alpha, round_trip });
            return error.TestUnexpectedResult;
        }
    }
}

test "读不到文件：默认值，不向上抛错" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tempPath(&tmp, "missing.json");
    defer testing.allocator.free(path);

    var settings = load(testing.allocator, testing.io, path);
    defer settings.deinit();
    try testing.expectEqual(default_l2_mib, settings.l2_budget_mib);
    try testing.expectEqual(default_l3_mib, settings.l3_budget_mib);
}

test "路径：dev 在 %LOCALAPPDATA%，便携版在 data 目录" {
    const dev = (try pathFor(testing.allocator, .dev, "C:\\build\\zig-out\\bin\\otto-lite.exe", .{
        .local_appdata = "C:\\Users\\me\\AppData\\Local",
    })).?;
    defer testing.allocator.free(dev);
    try testing.expectEqualStrings("C:\\Users\\me\\AppData\\Local\\OTTO\\dev\\settings.json", dev);
    try testing.expect(std.mem.indexOf(u8, dev, "zig-out") == null);

    const portable = (try pathFor(testing.allocator, .portable, "D:\\tools\\otto\\otto-lite.exe", .{})).?;
    defer testing.allocator.free(portable);
    try testing.expectEqualStrings("D:\\tools\\otto\\data\\settings.json", portable);

    const installed = (try pathFor(testing.allocator, .installed, "C:\\Program Files\\OTTO Lite\\otto-lite.exe", .{
        .appdata = "C:\\Users\\me\\AppData\\Roaming",
    })).?;
    defer testing.allocator.free(installed);
    try testing.expectEqualStrings("C:\\Users\\me\\AppData\\Roaming\\OTTO\\settings.json", installed);
}

test "dev 没有 LOCALAPPDATA 时设置退到 %TEMP%\\OTTO-dev，不写回 exe 目录" {
    const path = (try pathFor(testing.allocator, .dev, "C:\\build\\zig-out\\bin\\otto-lite.exe", .{
        .temp = "C:\\Temp",
    })).?;
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("C:\\Temp\\OTTO-dev\\settings.json", path);
    try testing.expect(std.mem.indexOf(u8, path, "zig-out") == null);
}
