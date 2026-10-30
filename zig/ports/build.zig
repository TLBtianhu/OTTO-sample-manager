const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 文件监听口岸：只产出静态库 + 模块。消费方（zig/app、将来的 Cutrans）链接
    // otto_watch，或 `@import("otto_watch")`。平台限定 Windows（见 src/win_watch.zig）。
    const library_module = b.addModule("otto_watch", .{
        .root_source_file = b.path("src/watch.zig"),
        .target = target,
        .optimize = optimize,
    });
    const library = b.addLibrary(.{
        .linkage = .static,
        .name = "otto_watch",
        .root_module = library_module,
    });
    b.installArtifact(library);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/watch_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_tests = b.addRunArtifact(b.addTest(.{ .root_module = test_module }));
    const test_step = b.step("test", "运行监听口岸单元 / 集成测试（真文件系统 + 真 Win32）");
    test_step.dependOn(&run_tests.step);
}
