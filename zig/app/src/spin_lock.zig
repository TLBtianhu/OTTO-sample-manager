//! app 内部共用的自适应自旋锁：只保护几次数值或指针交换，不做 IO、不做分配。
//! Zig 0.17 的 `std.Io.Mutex` 需要 Io 实例；这里保持原有 64 次自旋后让出的策略。
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

test "SpinLock：四条竞争线程的临界区互斥，释放后回到未持有态" {
    const iterations = 2_000;
    const Worker = struct {
        fn run(lock: *SpinLock, value: *usize) void {
            for (0..iterations) |_| {
                lock.acquire();
                defer lock.release();
                value.* += 1;
            }
        }
    };

    var lock: SpinLock = .{};
    var value: usize = 0;
    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, Worker.run, .{ &lock, &value });
    for (threads) |thread| thread.join();

    try std.testing.expectEqual(4 * iterations, value);
    try std.testing.expect(!lock.flag.load(.monotonic));
}
