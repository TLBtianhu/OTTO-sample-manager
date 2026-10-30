//! 命令行选项：只消费 app 自己的带值标志，`--nanoui-*` 留给 nanoui 自己解析。
//! 放在单独文件里，是为了让 `main.zig` 只保留 UI 与生命周期（单文件 ≤600 行）。

const std = @import("std");

pub const Options = struct {
    library_path: []const u8 = "fixtures/library.json",
    demo_dir: ?[]const u8 = null,
    demo_thumbs_dir: ?[]const u8 = null,
    demo_transport: bool = false,
    watch_dir: ?[]const u8 = null,
    copy_now: ?[]const u8 = null,
    select: ?[]const u8 = null,
};

pub fn parse(args: anytype) error{MissingValue}!Options {
    var options = Options{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg: []const u8 = args[index];
        if (std.mem.eql(u8, arg, "--demo-transport")) {
            options.demo_transport = true;
        } else if (std.mem.eql(u8, arg, "--demo-thumbs")) {
            index += 1;
            if (index == args.len) return error.MissingValue;
            options.demo_thumbs_dir = args[index];
        } else if (std.mem.eql(u8, arg, "--demo")) {
            index += 1;
            if (index == args.len) return error.MissingValue;
            options.demo_dir = args[index];
        } else if (std.mem.eql(u8, arg, "--watch")) {
            index += 1;
            if (index == args.len) return error.MissingValue;
            options.watch_dir = args[index];
        } else if (std.mem.eql(u8, arg, "--copy-now")) {
            index += 1;
            if (index == args.len) return error.MissingValue;
            options.copy_now = args[index];
        } else if (std.mem.startsWith(u8, arg, "--copy-now=")) {
            options.copy_now = arg["--copy-now=".len..];
        } else if (std.mem.eql(u8, arg, "--select")) {
            index += 1;
            if (index == args.len) return error.MissingValue;
            options.select = args[index];
        } else if (std.mem.startsWith(u8, arg, "--select=")) {
            options.select = arg["--select=".len..];
        } else if (!std.mem.startsWith(u8, arg, "--")) {
            options.library_path = arg;
        }
    }
    return options;
}

// ---------------------------------------------------------------------------
// 测试：只跑解析，不碰文件系统
// ---------------------------------------------------------------------------

const testing = std.testing;

test "默认值：库文件是 fixtures/library.json，没有别的模式" {
    const options = try parse(&[_][]const u8{"otto-lite"});
    try testing.expectEqualStrings("fixtures/library.json", options.library_path);
    try testing.expect(!options.demo_transport);
    try testing.expect(options.copy_now == null);
    try testing.expect(options.select == null);
}

test "位置参数是库文件；--watch / --select 带值" {
    const options = try parse(&[_][]const u8{ "otto-lite", "lib.json", "--watch", "C:\\lib", "--select=0,2" });
    try testing.expectEqualStrings("lib.json", options.library_path);
    try testing.expectEqualStrings("C:\\lib", options.watch_dir.?);
    try testing.expectEqualStrings("0,2", options.select.?);
}

test "--copy-now 两种写法；--demo-transport 是开关" {
    const spaced = try parse(&[_][]const u8{ "otto-lite", "--copy-now", "a.wav" });
    try testing.expectEqualStrings("a.wav", spaced.copy_now.?);

    const joined = try parse(&[_][]const u8{ "otto-lite", "--copy-now=b.wav", "--demo-transport" });
    try testing.expectEqualStrings("b.wav", joined.copy_now.?);
    try testing.expect(joined.demo_transport);
}

test "缺值返回 MissingValue" {
    try testing.expectError(error.MissingValue, parse(&[_][]const u8{ "otto-lite", "--watch" }));
    try testing.expectError(error.MissingValue, parse(&[_][]const u8{ "otto-lite", "--copy-now" }));
    try testing.expectError(error.MissingValue, parse(&[_][]const u8{ "otto-lite", "--select" }));
}
