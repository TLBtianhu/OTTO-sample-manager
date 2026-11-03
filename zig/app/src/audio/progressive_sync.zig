//! 渐进引擎的小同步件；拆出让 progressive.zig 守住单文件 600 行。
const std = @import("std");

pub const SpinLock = @import("../spin_lock.zig").SpinLock;

pub fn elapsedMs(io: std.Io, started: std.Io.Clock.Timestamp) f64 {
    return @as(f64, @floatFromInt(started.untilNow(io).raw.nanoseconds)) / 1_000_000.0;
}
