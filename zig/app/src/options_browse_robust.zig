//! 补全 / 路径探针的 CLI 片段。独立文件只为守住 options_parse.zig 的 600 行上限。
const std = @import("std");

pub fn parse(options: anytype, args: anytype, index: *usize, arg: []const u8) error{MissingValue}!bool {
    if (std.mem.eql(u8, arg, "--browse-complete-probe")) {
        options.browse_complete_probe = try value(args, index);
        return true;
    }
    if (std.mem.startsWith(u8, arg, "--browse-complete-probe=")) {
        options.browse_complete_probe = arg["--browse-complete-probe=".len..];
        return true;
    }
    if (std.mem.eql(u8, arg, "--browse-path-probe")) {
        options.browse_path_probe = try value(args, index);
        return true;
    }
    if (std.mem.startsWith(u8, arg, "--browse-path-probe=")) {
        options.browse_path_probe = arg["--browse-path-probe=".len..];
        return true;
    }
    if (std.mem.startsWith(u8, arg, "--text=")) {
        options.browse_text = arg["--text=".len..];
        return true;
    }
    if (std.mem.eql(u8, arg, "--text")) {
        options.browse_text = try value(args, index);
        return true;
    }
    return false;
}

fn value(args: anytype, index: *usize) error{MissingValue}![]const u8 {
    if (index.* + 1 >= args.len) return error.MissingValue;
    index.* += 1;
    return args[index.*];
}
