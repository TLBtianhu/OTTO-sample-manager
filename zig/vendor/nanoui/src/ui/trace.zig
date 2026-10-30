//! Timing marks for the work a cold start pays for once: the font scan,
//! glyph rasterization, shaping and the first frame. Off by default: every
//! call is one `enabled` test, and nothing is timed, allocated or printed.
//!
//!     // the app, before its first window:
//!     ui.trace.enabled = true;
//!     try app.newWindow(...);   // marks go to stderr as `nanoui-trace ...`
//!
//! `NANOUI_TRACE=1` in the environment does the same for apps that do not
//! wire it up themselves (see `windows/app.zig`). Lines are
//! `nanoui-trace <name> d=<ms since the previous mark> t=<ms since begin>`
//! followed by whatever the mark adds.
const std = @import("std");
const clock = @import("clock.zig");

pub var enabled: bool = false;

var started: f64 = 0;
var previous: f64 = 0;
var begun: bool = false;

pub fn begin() void {
    if (!enabled) return;
    if (begun) return;
    started = clock.now();
    previous = started;
    begun = true;
}

/// Starts again from now: a second run measured on its own (a test's second
/// window, a child process).
pub fn restart() void {
    begun = false;
    begin();
}

/// Whether a caller should collect the detail a mark would print (counts,
/// per-phase sums): same flag, no second one.
pub fn on() bool {
    return enabled;
}

pub fn mark(comptime name: []const u8) void {
    if (!enabled) return;
    begin();
    const now = clock.now();
    std.debug.print("nanoui-trace {s} d={d:.2} t={d:.2}\n", .{ name, (now - previous) * 1000, (now - started) * 1000 });
    previous = now;
}

/// `mark` plus a formatted detail: `markf("font.scan", "files={d}", .{n})`.
pub fn markf(comptime name: []const u8, comptime detail: []const u8, args: anytype) void {
    if (!enabled) return;
    begin();
    const now = clock.now();
    std.debug.print("nanoui-trace {s} d={d:.2} t={d:.2} ", .{ name, (now - previous) * 1000, (now - started) * 1000 });
    std.debug.print(detail ++ "\n", args);
    previous = now;
}

/// Milliseconds from `then` to now: the per-phase arithmetic of a scan.
pub fn msSince(then: f64) f64 {
    return (clock.now() - then) * 1000;
}

pub fn stamp() f64 {
    return clock.now();
}

test "off by default: a mark costs one test" {
    try std.testing.expect(!enabled);
    mark("nothing");
    markf("nothing", "x={d}", .{1});
}

test "begin is idempotent, restart moves the base" {
    enabled = true;
    defer {
        enabled = false;
        begun = false;
    }
    begin();
    const first = started;
    begin();
    try std.testing.expectEqual(first, started);
    restart();
    try std.testing.expect(started >= first);
}
