//! 库文件的格式分派层：读文件 → 按 **magic**（不是扩展名）决定走 JSON 还是
//! OTTOLIB 二进制，再把结果交给 core 对应的解码器。
//!
//! 为什么单独一层：`main.zig` 只该说"打开这个库"，不该同时认识 electron-store
//! 的 JSON 和 `OTTOLIB` 的头。格式判断只有一条铁律——看文件头，不看后缀：
//! 用户把 `library.json` 改名成 `.otto`（或反过来）时，行为必须仍然正确。
//!
//! 文件读写只走 `ports/library_file.zig`（原子写 / 带上限的整读），序列化只走
//! `core/store.zig` 与 `core/library_binary.zig`。本文件是两者之间唯一的接线点。
//!
//! 两个打开入口：`load` 是纯读取（CLI 自检用，文件不在就是 `FileNotFound`）；
//! `open` 是**启动入口**——文件不存在 = 空库（首次启动），只有存在却读不了 /
//! 损坏才是错误。两者的分界就是 `error.FileNotFound`，没有第二种猜测。

const std = @import("std");
const core = @import("otto_core");
const library_file = @import("otto_library_file");

pub const Format = enum { json, otto };

/// 读文件、解码、识别格式可能返回的错误：JSON 侧 + 二进制侧 + 口岸侧。
pub const LoadError = core.store.LoadError || core.library_binary.Error || library_file.Error;
pub const SaveError = core.library_binary.Error || library_file.Error;

/// 一次 `inspect` 的结果（`--library-info` 的机器可读部分）。
pub const Info = struct {
    format: Format,
    samples: usize,
    groups: usize,
    bytes: u64,
};

/// 判断格式：magic 优先；magic 不匹配时，只有**看起来像 JSON 对象/数组**才走
/// JSON，否则仍交给 OTTOLIB 解码器。
///
/// 这条兜底是为了错误质量：magic 被改坏一个字节的库文件如果直接当 JSON 解析，
/// 只会得到 `InvalidJson`；按内容判断后仍会得到更具体的 `BadMagic`。反过来，
/// 正常 JSON 一定以 `{` / `[` 开头（允许 UTF-8 BOM 和前导空白），不受影响。
pub fn formatOf(bytes: []const u8) Format {
    if (core.library_binary.isOtto(bytes)) return .otto;

    var start: usize = 0;
    if (std.mem.startsWith(u8, bytes, "\xEF\xBB\xBF")) start = 3;
    while (start < bytes.len and std.ascii.isWhitespace(bytes[start])) start += 1;
    if (start < bytes.len and (bytes[start] == '{' or bytes[start] == '[')) return .json;
    return .otto;
}

/// 一次"打开库"的结果。
///
/// `empty = true` 表示文件**不存在**，按空库启动（首次启动的正常路径）；
/// 它不是错误，调用方照常开窗，只是列表里没有素材。
pub const Opened = struct {
    library: core.store.Library,
    empty: bool,
};

/// 打开一个库文件。返回的 `Library` 自己持有 arena，调用方 `deinit()`。
///
/// 读取上限取两套格式上限的较大者；JSON 再有 `store.max_file_bytes` 的独立
/// 检查，保持原来"超大 JSON 明确报 FileTooLarge"的行为。
pub fn load(init: std.process.Init, allocator: std.mem.Allocator, path: []const u8) LoadError!core.store.Library {
    return loadWith(init.io, allocator, path);
}

/// 首次启动的打开方式：文件**不存在** → `core.store.empty()` 的空库；
/// 存在但读不了 / 损坏（`AccessDenied` / `BadMagic` / `Truncated` / …）→ 原样
/// 返回具名错误。两者不能混：把损坏文件当空库会静默丢掉用户的库，把不存在当
/// 错误就是"点了没反应"。
pub fn open(init: std.process.Init, allocator: std.mem.Allocator, path: []const u8) LoadError!Opened {
    return openWith(init.io, allocator, path);
}

/// `open` 的 io 版本：`--import-into` / 测试不必伪造 `std.process.Init`。
pub fn openWith(io: std.Io, allocator: std.mem.Allocator, path: []const u8) LoadError!Opened {
    const library = loadWith(io, allocator, path) catch |err| switch (err) {
        // 文件不存在（含父目录也还不存在）：空库，不是错误。这里只认
        // FileNotFound——读失败与解码失败都要按具名错误冒上去。
        error.FileNotFound => return .{ .library = try core.store.empty(allocator), .empty = true },
        else => |other| return other,
    };
    return .{ .library = library, .empty = false };
}

/// `load` 的 io 版本：不开窗的命令行流水线（`--import`）与测试只需要 `std.Io`，
/// 不必伪造一个 `std.process.Init`。
pub fn loadWith(io: std.Io, allocator: std.mem.Allocator, path: []const u8) LoadError!core.store.Library {
    const read_limit = @max(core.library_binary.max_file_bytes, core.store.max_file_bytes) + 1;
    const bytes = try library_file.readAll(allocator, io, path, read_limit);
    defer allocator.free(bytes);

    if (formatOf(bytes) == .otto) return core.library_binary.decode(allocator, bytes);
    if (bytes.len > core.store.max_file_bytes) return error.FileTooLarge;
    return core.store.load(allocator, bytes);
}

/// 把库原子地写成 OTTOLIB v1。返回写出的字节数。失败时目标文件保持原样。
pub fn save(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    path: []const u8,
    library: *const core.store.Library,
) SaveError!usize {
    return saveWith(init.io, allocator, path, library);
}

/// `save` 的 io 版本（同上）。
pub fn saveWith(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    library: *const core.store.Library,
) SaveError!usize {
    const bytes = try core.library_binary.encode(allocator, library);
    defer allocator.free(bytes);
    try library_file.writeAtomic(allocator, io, path, bytes);
    return bytes.len;
}

/// 按 magic 读格式并完整解码一遍，返回条数与文件字节数。
/// 损坏文件在这里就会拿到 `BadMagic` / `UnknownVersion` / `Truncated` /
/// `ChecksumMismatch` / `TooLarge` 这些具名错误。
pub fn inspect(init: std.process.Init, allocator: std.mem.Allocator, path: []const u8) LoadError!Info {
    return inspectWith(init.io, allocator, path);
}

/// `inspect` 的 io 版本（导入测试用它读回 `.otto` 核对条数）。
pub fn inspectWith(io: std.Io, allocator: std.mem.Allocator, path: []const u8) LoadError!Info {
    const read_limit = @max(core.library_binary.max_file_bytes, core.store.max_file_bytes) + 1;
    const bytes = try library_file.readAll(allocator, io, path, read_limit);
    defer allocator.free(bytes);

    const format = formatOf(bytes);
    var library = if (format == .otto)
        try core.library_binary.decode(allocator, bytes)
    else blk: {
        if (bytes.len > core.store.max_file_bytes) return error.FileTooLarge;
        break :blk try core.store.load(allocator, bytes);
    };
    defer library.deinit();

    return .{
        .format = format,
        .samples = library.samples.len,
        .groups = library.groups.len,
        .bytes = bytes.len,
    };
}

test "open：文件不存在（含父目录不存在）= 空库，不是错误" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &buffer);
    const root = buffer[0..len];

    // 父目录就在、文件不在（便携版 data 已建、还没有库）。
    const missing = try std.fs.path.join(std.testing.allocator, &.{ root, "library.otto" });
    defer std.testing.allocator.free(missing);
    var opened = try openWith(std.testing.io, std.testing.allocator, missing);
    defer opened.library.deinit();
    try std.testing.expect(opened.empty);
    try std.testing.expectEqual(@as(usize, 0), opened.library.samples.len);

    // 父目录也不在（全新安装，第一次导入之前）：同样是空库，不能崩在路径拼接上。
    const missing_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "not-yet", "library.json" });
    defer std.testing.allocator.free(missing_dir);
    var opened_dir = try openWith(std.testing.io, std.testing.allocator, missing_dir);
    defer opened_dir.library.deinit();
    try std.testing.expect(opened_dir.empty);
    try std.testing.expectEqual(@as(usize, 0), opened_dir.library.samples.len);
}

test "open：存在但损坏仍是具名错误，绝不当成空库" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &buffer);
    const root = buffer[0..len];

    // 一个字节的垃圾：短于 OTTOLIB magic，解码器给 Truncated。
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "half.otto", .data = "X" });
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "half.otto" });
    defer std.testing.allocator.free(path);
    try std.testing.expectError(error.Truncated, openWith(std.testing.io, std.testing.allocator, path));
}

test "open：能读的库照常解析，empty = false" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &buffer);
    const root = buffer[0..len];

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "library.json",
        .data = "{\"samples\":{\"a\":{\"id\":\"a\",\"fileName\":\"a\"}}}",
    });
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "library.json" });
    defer std.testing.allocator.free(path);
    var opened = try openWith(std.testing.io, std.testing.allocator, path);
    defer opened.library.deinit();
    try std.testing.expect(!opened.empty);
    try std.testing.expectEqual(@as(usize, 1), opened.library.samples.len);
}

test "formatOf：magic 优先，坏 magic 仍按 otto，JSON 按内容判断" {
    try std.testing.expectEqual(Format.otto, formatOf("OTTOLIB\x00" ++ "rest"));
    try std.testing.expectEqual(Format.json, formatOf("{\"samples\":{}}"));
    try std.testing.expectEqual(Format.json, formatOf("\xEF\xBB\xBF \n[]"));
    // magic 被改坏一个字节：不能误判成 JSON，否则错误会退化成 InvalidJson。
    try std.testing.expectEqual(Format.otto, formatOf("XTTOLIB\x00" ++ "rest"));
    // 空文件也按 otto 交给解码器，得到 Truncated 而不是 JSON 语法错误。
    try std.testing.expectEqual(Format.otto, formatOf(""));
}
