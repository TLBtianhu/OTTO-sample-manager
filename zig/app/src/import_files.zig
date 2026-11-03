//! Multi-file import: collect only the dropped files, then reuse the folder
//! pipeline's probe, dedupe, sample construction, merge and atomic save rules.
const std = @import("std");
const core = @import("otto_core");
const import_cli = @import("import_cli.zig");
const library_io = @import("library_io.zig");
const scan_mod = @import("otto_scan");

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    paths: []const []const u8,
    base_library_path: []const u8,
    save_path: []const u8,
) error{ OutOfMemory, IdCollision }!import_cli.Report {
    const started = std.Io.Clock.Timestamp.now(io, .awake);
    var report: import_cli.Report = .{};
    var transient: std.heap.ArenaAllocator = .init(allocator);
    defer transient.deinit();
    const temp = transient.allocator();

    var library = library_io.loadWith(io, allocator, base_library_path) catch |err| switch (err) {
        error.FileNotFound => try core.store.empty(allocator),
        else => {
            report.failure = .{ .stage = .library, .name = @errorName(err) };
            return report;
        },
    };
    defer library.deinit();

    var scan = scan_mod.runFiles(temp, io, paths, .{}) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        report.failure = .{ .stage = .scan, .name = @errorName(err) };
        return report;
    };
    defer scan.deinit();
    // A dropped path that disappeared is not a successful zero-file import.
    // Keep its actual FileNotFound / AccessDenied name visible in the header.
    if (scan.failures.len > 0) {
        report.failure = .{ .stage = .scan, .name = scan.failures[0].err };
        report.failed = scan.failures.len;
        return report;
    }

    try import_cli.mergeScan(temp, io, &library, &scan, &report);
    import_cli.ensureParentDir(io, save_path) catch |err| {
        report.failure = .{ .stage = .save, .name = @errorName(err) };
        return report;
    };
    report.bytes = library_io.saveWith(io, allocator, save_path, &library) catch |err| {
        report.failure = .{ .stage = .save, .name = @errorName(err) };
        return report;
    };
    report.ms = elapsedMs(io, started);
    return report;
}

fn elapsedMs(io: std.Io, started: std.Io.Clock.Timestamp) f64 {
    const nanoseconds = started.untilNow(io).raw.nanoseconds;
    return @as(f64, @floatFromInt(nanoseconds)) / 1_000_000.0;
}
