//! 预览、播放与 PCM 驻留探针的参数；从 options_parse 拆出守住 600 行。
const std = @import("std");
const options_mod = @import("options.zig");
const residency = @import("audio/residency.zig");

fn nextValue(args: anytype, index: *usize) options_mod.ParseError![]const u8 {
    index.* += 1;
    if (index.* == args.len) return error.MissingValue;
    return args[index.*];
}

pub fn preview(options: *options_mod.Options, args: anytype, index: *usize, arg: []const u8) options_mod.ParseError!bool {
    if (std.mem.eql(u8, arg, "--preview")) {
        options.preview_path = try nextValue(args, index);
    } else if (std.mem.startsWith(u8, arg, "--preview=")) {
        options.preview_path = arg["--preview=".len..];
    } else if (std.mem.eql(u8, arg, "--play-test")) {
        options.play_test_path = try nextValue(args, index);
    } else if (std.mem.startsWith(u8, arg, "--play-test=")) {
        options.play_test_path = arg["--play-test=".len..];
    } else if (std.mem.eql(u8, arg, "--pcm-probe")) {
        options.pcm_probe_path = try nextValue(args, index);
    } else if (std.mem.startsWith(u8, arg, "--pcm-probe=")) {
        options.pcm_probe_path = arg["--pcm-probe=".len..];
    } else if (std.mem.startsWith(u8, arg, "--pcm-residency=")) {
        options.pcm_residency = residency.parse(arg["--pcm-residency=".len..]) catch return error.InvalidValue;
    } else if (std.mem.startsWith(u8, arg, "--pcm-cycles=")) {
        options.pcm_cycles = std.fmt.parseInt(u32, arg["--pcm-cycles=".len..], 10) catch return error.InvalidValue;
        if (options.pcm_cycles == 0 or options.pcm_cycles > 1000) return error.InvalidValue;
    } else if (std.mem.eql(u8, arg, "--pcm-play")) {
        options.pcm_play = true;
    } else if (std.mem.eql(u8, arg, "--pcm-ui-probe")) {
        options.pcm_ui_probe = true;
    } else if (std.mem.eql(u8, arg, "--seek-at")) {
        options.seek_at_ms = try parseMillis(try nextValue(args, index));
    } else if (std.mem.startsWith(u8, arg, "--seek-at=")) {
        options.seek_at_ms = try parseMillis(arg["--seek-at=".len..]);
    } else if (std.mem.eql(u8, arg, "--no-shell-preview")) {
        options.no_shell_preview = true;
    } else return false;
    return true;
}

fn parseMillis(text: []const u8) options_mod.ParseError!u64 {
    return std.fmt.parseInt(u64, text, 10) catch error.InvalidValue;
}
