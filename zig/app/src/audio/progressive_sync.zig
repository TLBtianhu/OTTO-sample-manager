//! 渐进引擎的小同步件；拆出让 progressive.zig 守住单文件 600 行。
const std = @import("std");

pub const SpinLock = struct {
    flag: std.atomic.Value(bool) = .init(false),

    pub fn acquire(self: *SpinLock) void {
        var spins: u32 = 0;
        while (self.flag.swap(true, .acquire)) {
            spins +%= 1;
            if (spins > 64) {
                std.Thread.yield() catch {};
                spins = 0;
            }
        }
    }

    pub fn release(self: *SpinLock) void {
        self.flag.store(false, .release);
    }
};

pub fn elapsedMs(io: std.Io, started: std.Io.Clock.Timestamp) f64 {
    return @as(f64, @floatFromInt(started.untilNow(io).raw.nanoseconds)) / 1_000_000.0;
}
