//! Small, synchronous test runner for auditable integration-test accounting.
//! Server mode is intentionally unnecessary: the build runs this as a simple
//! runner, inherits its output, and checks its exit status.

const std = @import("std");
const builtin = @import("builtin");
const options = @import("test_options");
const audit = @import("test_audit");

const LayerStats = struct {
    executed: usize = 0,
    compared: usize = 0,
    skipped: usize = 0,
    reasons: [@typeInfo(audit.SkipReason).@"enum".field_names.len]usize = @splat(0),
};

fn envEnabled(key: []const u8) bool {
    const value = std.testing.environ.getAlloc(std.heap.page_allocator, key) catch return false;
    defer std.heap.page_allocator.free(value);
    return std.mem.eql(u8, value, "1");
}

fn printLayer(layer: audit.Layer, stats: LayerStats) void {
    std.debug.print("{s} executed={d} compared={d} skipped={d}", .{
        audit.layerName(layer),
        stats.executed,
        stats.compared,
        stats.skipped,
    });
    if (stats.skipped != 0) {
        std.debug.print("(", .{});
        var first = true;
        for (std.meta.tags(audit.SkipReason), 0..) |reason, i| {
            const count = stats.reasons[i];
            if (count == 0) continue;
            if (!first) std.debug.print(",", .{});
            first = false;
            std.debug.print("{s}={d}", .{ @tagName(reason), count });
        }
        std.debug.print(")", .{});
    }
    std.debug.print("\n", .{});
}

pub fn main(init: std.process.Init.Minimal) void {
    @disableInstrumentation();
    const tests = builtin.test_functions;
    var stats: [4]LayerStats = @splat(.{});
    var passed: usize = 0;
    var skipped: usize = 0;
    var failed: usize = 0;
    var gate_failures: usize = 0;
    var leaks: usize = 0;

    std.testing.environ = init.environ;
    const require_ffmpeg = options.require_ffmpeg or envEnabled("ZA_REQUIRE_FFMPEG");
    std.debug.print(
        "test audit: discovered={d} require_ffmpeg={} (L4 skips are failures when enabled)\n",
        .{ tests.len, require_ffmpeg },
    );

    for (tests) |test_fn| {
        std.testing.allocator_instance = .init(std.heap.page_allocator, .{
            .canary = 0xc3a701ba,
            .check_write_after_free = true,
        });
        std.testing.io_instance = .init(std.testing.allocator, .{
            .argv0 = .init(init.args),
            .environ = init.environ,
        });
        defer {
            std.testing.io_instance.deinit();
            if (std.testing.allocator_instance.deinit() != 0) {
                leaks += 1;
                std.debug.print("LEAK {s}\n", .{test_fn.name});
            }
        }
        std.testing.log_level = .warn;
        std.testing.environ = init.environ;
        audit.beginTest();
        const layer = audit.classify(test_fn.name);
        const layer_stats = &stats[@backingInt(layer)];

        if (test_fn.func()) |_| {
            passed += 1;
            layer_stats.executed += 1;
            // `compared` counts completed tests with a fixture/published/live
            // reference oracle, not individual samples or ffmpeg invocations.
            if (layer != .l1) layer_stats.compared += 1;
        } else |err| switch (err) {
            error.SkipZigTest => {
                const reason = audit.skipReason();
                skipped += 1;
                layer_stats.skipped += 1;
                layer_stats.reasons[@backingInt(reason)] += 1;
                std.debug.print("SKIP {s} layer={s} reason={s}\n", .{
                    test_fn.name,
                    audit.layerName(layer),
                    @tagName(reason),
                });
                if (require_ffmpeg and layer == .l4) {
                    failed += 1;
                    gate_failures += 1;
                    std.debug.print(
                        "REQUIRE-FFMPEG FAIL {s}: L4 skipped reason={s}\n",
                        .{ test_fn.name, @tagName(reason) },
                    );
                }
            },
            else => {
                failed += 1;
                std.debug.print("FAIL {s} error={t}\n", .{ test_fn.name, err });
                if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            },
        }
    }

    std.debug.print("test layers (compared = completed reference-oracle tests):\n", .{});
    for (std.meta.tags(audit.Layer), 0..) |layer, i| printLayer(layer, stats[i]);
    std.debug.print(
        "test summary: passed={d} skipped={d} failed={d} require_ffmpeg_failures={d} leaks={d}\n",
        .{ passed, skipped, failed, gate_failures, leaks },
    );
    if (failed != 0 or leaks != 0) std.process.exit(1);
}
