//! `mode.zig` 的测试：形态判定、数据目录、默认库与监听根。
//!
//! 从 `mode.zig` 拆出来守住单文件行数；这里只碰 pub 函数，私有实现留在
//! `mode.zig`（`fileExists` / `realPathDupe` 由使用它们的路径间接覆盖）。

const std = @import("std");
const builtin = @import("builtin");
const mode = @import("mode.zig");

const testing = std.testing;
const Mode = mode.Mode;
const Env = mode.Env;

test "判定顺序：标记优先于 zig-out，zig-out 优先于 installed" {
    try testing.expectEqual(Mode.portable, mode.detectFrom("C:\\src\\zig-out\\bin\\otto-lite.exe", true));
    try testing.expectEqual(Mode.portable, mode.detectFrom("D:\\anywhere\\otto-lite.exe", true));
    try testing.expectEqual(Mode.dev, mode.detectFrom("C:\\src\\zig-out\\bin\\otto-lite.exe", false));
    try testing.expectEqual(Mode.installed, mode.detectFrom("C:\\Program Files\\OTTO Lite\\otto-lite.exe", false));
    try testing.expectEqual(Mode.installed, mode.detectFrom("otto-lite.exe", false));
}

test "zig-out 必须是完整路径段" {
    // 正斜杠、反斜杠都算段分隔。
    try testing.expect(mode.hasZigOutSegment("C:/src/zig-out/bin/otto-lite.exe"));
    try testing.expect(mode.hasZigOutSegment("/home/me/zig-out/bin/otto-lite"));
    try testing.expect(mode.hasZigOutSegment("\\\\server\\share\\zig-out\\otto-lite.exe"));
    // 只是名字里带 zig-out 的不算：否则用户目录会被误判成开发目录。
    try testing.expect(!mode.hasZigOutSegment("C:\\src\\myzig-out\\bin\\otto-lite.exe"));
    try testing.expect(!mode.hasZigOutSegment("C:\\src\\zig-out2\\bin\\otto-lite.exe"));
    try testing.expect(!mode.hasZigOutSegment("C:\\src\\zig-out-backup\\otto-lite.exe"));
    try testing.expect(!mode.hasZigOutSegment("C:\\src\\zig_out\\otto-lite.exe"));
}

test "数据目录：dev 在 %LOCALAPPDATA%，portable 在 exe 旁边，installed 在 %APPDATA%" {
    const env = Env{
        .appdata = "C:\\Users\\me\\AppData\\Roaming",
        .local_appdata = "C:\\Users\\me\\AppData\\Local",
        .temp = "C:\\Temp",
    };

    const dev = (try mode.dataDirFor(testing.allocator, .dev, "C:\\src\\zig-out\\bin\\otto-lite.exe", env)).?;
    defer testing.allocator.free(dev);
    try testing.expectEqualStrings("C:\\Users\\me\\AppData\\Local\\OTTO\\dev", dev);

    const portable = (try mode.dataDirFor(testing.allocator, .portable, "D:\\tools\\otto\\otto-lite.exe", env)).?;
    defer testing.allocator.free(portable);
    try testing.expectEqualStrings("D:\\tools\\otto\\data", portable);

    const installed = (try mode.dataDirFor(testing.allocator, .installed, "C:\\Program Files\\OTTO Lite\\otto-lite.exe", env)).?;
    defer testing.allocator.free(installed);
    try testing.expectEqualStrings("C:\\Users\\me\\AppData\\Roaming\\OTTO", installed);
}

test "dev 数据目录不在 zig-out 下（编译产物不承载任何运行数据）" {
    const dev = (try mode.dataDirFor(testing.allocator, .dev, "C:\\src\\zig-out\\bin\\otto-lite.exe", .{
        .local_appdata = "C:\\Users\\me\\AppData\\Local",
    })).?;
    defer testing.allocator.free(dev);

    // 路径本身必须是开发者本地目录，而不是 exe 所在的构建目录。
    try testing.expectEqualStrings("C:\\Users\\me\\AppData\\Local\\OTTO\\dev", dev);
    try testing.expect(!mode.hasZigOutSegment(dev));
    try testing.expect(std.mem.indexOf(u8, dev, "zig-out") == null);
}

test "dev 没有 LOCALAPPDATA 时退回 %TEMP%\\OTTO-dev，两个都没有就是 null" {
    const fallback = (try mode.devDataDirFor(testing.allocator, null, "C:\\Users\\me\\AppData\\Local\\Temp")).?;
    defer testing.allocator.free(fallback);
    try testing.expectEqualStrings("C:\\Users\\me\\AppData\\Local\\Temp\\OTTO-dev", fallback);
    try testing.expect(!mode.hasZigOutSegment(fallback));

    const viaDataDir = (try mode.dataDirFor(testing.allocator, .dev, "C:\\src\\zig-out\\bin\\otto-lite.exe", .{
        .temp = "C:\\Temp",
    })).?;
    defer testing.allocator.free(viaDataDir);
    try testing.expectEqualStrings("C:\\Temp\\OTTO-dev", viaDataDir);

    // 两个都没有：不猜当前目录，调用方退回内存态。
    try testing.expect((try mode.dataDirFor(testing.allocator, .dev, "C:\\src\\zig-out\\bin\\otto-lite.exe", .{})) == null);
}

test "下载目录：三种形态都在各自的数据目录下，dev 不写 zig-out" {
    const env = Env{
        .appdata = "C:\\Users\\me\\AppData\\Roaming",
        .local_appdata = "C:\\Users\\me\\AppData\\Local",
        .temp = "C:\\Temp",
    };

    const dev = (try mode.updatesDirFor(testing.allocator, .dev, "C:\\src\\zig-out\\bin\\otto-lite.exe", env)).?;
    defer testing.allocator.free(dev);
    try testing.expectEqualStrings("C:\\Users\\me\\AppData\\Local\\OTTO\\dev\\updates", dev);
    try testing.expect(!mode.hasZigOutSegment(dev));

    const fallback = (try mode.updatesDirFor(testing.allocator, .dev, "C:\\src\\zig-out\\bin\\otto-lite.exe", .{
        .temp = "C:\\Temp",
    })).?;
    defer testing.allocator.free(fallback);
    try testing.expectEqualStrings("C:\\Temp\\OTTO-dev\\updates", fallback);

    const portable = (try mode.updatesDirFor(
        testing.allocator,
        .portable,
        "D:\\tools\\otto\\otto-lite.exe",
        env,
    )).?;
    defer testing.allocator.free(portable);
    try testing.expectEqualStrings("D:\\tools\\otto\\data\\updates", portable);

    const installed = (try mode.updatesDirFor(
        testing.allocator,
        .installed,
        "C:\\Program Files\\OTTO Lite\\otto-lite.exe",
        env,
    )).?;
    defer testing.allocator.free(installed);
    try testing.expectEqualStrings("C:\\Users\\me\\AppData\\Roaming\\OTTO\\updates", installed);

    // installed 拿不到 %APPDATA%：null，不猜路径。
    try testing.expect((try mode.updatesDirFor(
        testing.allocator,
        .installed,
        "C:\\Program Files\\OTTO Lite\\otto-lite.exe",
        .{},
    )) == null);
}

test "installed 拿不到 %APPDATA% 是显式错误，不落到当前目录" {
    try testing.expectError(
        error.AppDataDirUnavailable,
        mode.dataDirFor(testing.allocator, .installed, "C:\\Program Files\\OTTO Lite\\otto-lite.exe", .{}),
    );
}

test "默认库文件：dev 仍是 fixtures，其余在数据目录下" {
    const dev = try mode.libraryPathFor(testing.allocator, .dev, "C:\\src\\zig-out\\bin\\otto-lite.exe", .{});
    defer testing.allocator.free(dev);
    try testing.expectEqualStrings(mode.dev_library_path, dev);

    const portable = try mode.libraryPathFor(testing.allocator, .portable, "D:\\tools\\otto\\otto-lite.exe", .{});
    defer testing.allocator.free(portable);
    try testing.expectEqualStrings("D:\\tools\\otto\\data\\library.json", portable);

    const installed = try mode.libraryPathFor(testing.allocator, .installed, "C:\\Program Files\\OTTO Lite\\otto-lite.exe", .{
        .appdata = "C:\\Users\\me\\AppData\\Roaming",
    });
    defer testing.allocator.free(installed);
    try testing.expectEqualStrings("C:\\Users\\me\\AppData\\Roaming\\OTTO\\library.json", installed);
}

test "exe 没有目录部分时，portable 的数据目录落在相对 data" {
    const dir = (try mode.dataDirFor(testing.allocator, .portable, "otto-lite.exe", .{})).?;
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
    try testing.expect(!mode.markerExists(testing.allocator, testing.io, exe_path));
    try testing.expectEqual(Mode.installed, try mode.detect(testing.allocator, testing.io, exe_path));

    // 放了标记就是 portable，哪怕路径里本来没有 zig-out。
    try tmp.dir.writeFile(testing.io, .{ .sub_path = mode.portable_marker, .data = "" });
    try testing.expect(mode.markerExists(testing.allocator, testing.io, exe_path));
    try testing.expectEqual(Mode.portable, try mode.detect(testing.allocator, testing.io, exe_path));

    // 标记在别的目录不算：判据必须是 exe 的邻居，不是"这台机器上有标记"。
    const other_exe = try std.fs.path.join(testing.allocator, &.{ root, "bin", "otto-lite.exe" });
    defer testing.allocator.free(other_exe);
    try testing.expect(!mode.markerExists(testing.allocator, testing.io, other_exe));
}

test "薄封装：installed 的数据目录真的落在 %APPDATA% 下" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const dir = (try mode.dataDir(testing.allocator, testing.io, .installed, "C:\\Program Files\\OTTO Lite\\otto-lite.exe")).?;
    defer testing.allocator.free(dir);
    try testing.expect(std.mem.endsWith(u8, dir, mode.installed_dir_name));
    try testing.expect(std.fs.path.isAbsolute(dir));
}

test "L3 缓存目录：dataDir 下的 cache/thumbs；没有 dataDir 就是 null" {
    try testing.expect((try mode.cacheDirFor(testing.allocator, null)) == null);

    const dir = (try mode.cacheDirFor(testing.allocator, "C:\\Users\\me\\AppData\\Roaming\\OTTO")).?;
    defer testing.allocator.free(dir);
    try testing.expectEqualStrings("C:\\Users\\me\\AppData\\Roaming\\OTTO\\cache\\thumbs", dir);
}

// ---------------------------------------------------------------------------
// 首次启动：默认库的 `.otto` 优先，监听根在目录不存在时也不能报错
// ---------------------------------------------------------------------------

/// `preferOtto` 拿走 nominal 的所有权：测试里每次给一份副本，读完自己释放。
fn expectPreferOtto(nominal: []const u8, expected: []const u8) !void {
    const copy = try testing.allocator.dupe(u8, nominal);
    const got = try mode.preferOtto(testing.allocator, testing.io, copy);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

test "默认库：同目录 .otto 存在就用它（导入落盘之后重启还要看得见）" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(testing.io, &path_buffer);
    const root = path_buffer[0..root_len];

    const nominal = try std.fs.path.join(testing.allocator, &.{ root, "library.json" });
    defer testing.allocator.free(nominal);
    const converted = try std.fs.path.join(testing.allocator, &.{ root, "library.otto" });
    defer testing.allocator.free(converted);

    // 都没有（首次启动）：原样给名义路径，由 `library_io.open` 变成空库。
    try expectPreferOtto(nominal, nominal);

    // 只有老 JSON：用 JSON，不逼老用户迁移。
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "library.json", .data = "{}" });
    try expectPreferOtto(nominal, nominal);

    // 导入写出的 `.otto` 存在：它才是真源。
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "library.otto", .data = "OTTOLIB\x00" });
    try expectPreferOtto(nominal, converted);
}

test "默认库：名义路径本来就是 .otto 时不会拼成 library.otto.otto" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(testing.io, &path_buffer);
    const root = path_buffer[0..root_len];

    const nominal = try std.fs.path.join(testing.allocator, &.{ root, "kit.otto" });
    defer testing.allocator.free(nominal);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "kit.otto", .data = "OTTOLIB\x00" });
    try expectPreferOtto(nominal, nominal);
}

test "监听根：库所在目录还不存在时给绝对路径，不报 FileNotFound" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(testing.io, &path_buffer);
    const root = path_buffer[0..root_len];

    const library = try std.fs.path.join(testing.allocator, &.{ root, "no-data", "library.json" });
    defer testing.allocator.free(library);
    const watch = try mode.watchRoot(testing.allocator, testing.io, null, library);
    defer testing.allocator.free(watch);

    try testing.expect(std.fs.path.isAbsolute(watch));
    try testing.expect(std.mem.endsWith(u8, watch, "no-data"));
    // 只是路径，目录确实还不存在；真去 access 会 FileNotFound——正是旧启动路径
    // 在这里报错退出。
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(testing.io, watch, .{}));
}

test "监听根：位置参数没有目录部分时落到 cwd，不把 null 拼进路径" {
    const watch = try mode.watchRoot(testing.allocator, testing.io, null, "library.json");
    defer testing.allocator.free(watch);
    try testing.expect(std.fs.path.isAbsolute(watch));
    const cwd = try std.process.currentPathAlloc(testing.io, testing.allocator);
    defer testing.allocator.free(cwd);
    // Windows 路径大小写不敏感：realPath 与 currentPath 的盘符/目录大小写可能不同。
    try testing.expect(std.ascii.eqlIgnoreCase(watch, cwd));
}
