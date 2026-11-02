//! Test-only ffmpeg discovery and process execution. The public library does
//! not import this file. Resolution is deliberately repeated per invocation so
//! every test uses the same audited rules without owning global path memory.

const std = @import("std");
const builtin = @import("builtin");
const audit = @import("test_audit");

const default_path = "C:\\Users\\30680\\.zcode\\workspace\\default\\music-to-midi\\tools\\ffmpeg\\bin\\ffmpeg.exe";
const config_path = "ffmpeg.path";

const Source = enum { env, file, default };
const Resolved = struct {
    path: []u8,
    source: Source,
};

var source_reported = false;

fn normalize(allocator: std.mem.Allocator, raw: []const u8, source: Source) !Resolved {
    const path = std.mem.trim(u8, raw, " \t\r\n");
    if (path.len == 0) return error.EmptyFfmpegPath;

    // An existing directory means its bin-style ffmpeg executable. Anything
    // else is kept verbatim so a missing configured path produces an explicit
    // executable-not-found skip (or a require-ffmpeg failure), never a fallback.
    if (std.Io.Dir.cwd().openDir(std.testing.io, path, .{})) |opened| {
        var dir = opened;
        dir.close(std.testing.io);
        const exe = if (builtin.os.tag == .windows) "ffmpeg.exe" else "ffmpeg";
        return .{
            .path = try std.fs.path.join(allocator, &.{ path, exe }),
            .source = source,
        };
    } else |err| switch (err) {
        error.FileNotFound, error.NotDir => {},
        else => return err,
    }
    return .{ .path = try allocator.dupe(u8, path), .source = source };
}

fn fromEnvironment(allocator: std.mem.Allocator) !?Resolved {
    const value = std.testing.environ.getAlloc(allocator, "ZA_FFMPEG_PATH") catch |err| switch (err) {
        error.EnvironmentVariableMissing => return null,
        else => return err,
    };
    defer allocator.free(value);
    return try normalize(allocator, value, .env);
}

fn fromFile(allocator: std.mem.Allocator) !?Resolved {
    const contents = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        config_path,
        allocator,
        .limited(4096),
    ) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(contents);
    return try normalize(allocator, contents, .file);
}

fn resolve(allocator: std.mem.Allocator) !Resolved {
    // Priority is authoritative: an explicitly configured bad path must not
    // silently fall through to a working lower-priority ffmpeg.
    if (try fromEnvironment(allocator)) |resolved| return resolved;
    if (try fromFile(allocator)) |resolved| return resolved;
    return normalize(allocator, default_path, .default);
}

fn reportOnce(resolved: Resolved) void {
    if (source_reported) return;
    source_reported = true;
    std.debug.print("ffmpeg: source={s} path={s}\n", .{
        @tagName(resolved.source),
        resolved.path,
    });
}

/// Run ffmpeg with arguments that do not include argv[0]. FileNotFound is the
/// only availability error converted to SkipZigTest; execution failures remain
/// real test failures rather than disguised skips.
pub fn run(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout_limit: std.Io.Limit,
) !std.process.RunResult {
    const resolved = try resolve(allocator);
    defer allocator.free(resolved.path);
    reportOnce(resolved);

    const argv = try allocator.alloc([]const u8, args.len + 1);
    defer allocator.free(argv);
    argv[0] = resolved.path;
    @memcpy(argv[1..], args);

    return std.process.run(allocator, std.testing.io, .{
        .argv = argv,
        .stdout_limit = stdout_limit,
        .stderr_limit = .limited(1 << 20),
    }) catch |err| switch (err) {
        error.FileNotFound => {
            audit.noteSkip(.ffmpeg_unavailable);
            std.debug.print(
                "ffmpeg: executable-not-found source={s} path={s}\n",
                .{ @tagName(resolved.source), resolved.path },
            );
            return error.SkipZigTest;
        },
        else => err,
    };
}
