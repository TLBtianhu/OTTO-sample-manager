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

    // 缩略图口岸：公共 API（thumb.zig）+ Windows Shell 后端（thumb_win.zig）。
    // ole32 / shell32 / gdi32 是手写 extern 的落点，Windows 后端才需要；
    // 挂在模块上，消费方链接 otto_thumb 时自动带上。
    const thumb_module = b.addModule("otto_thumb", .{
        .root_source_file = b.path("src/thumb.zig"),
        .target = target,
        .optimize = optimize,
    });
    thumb_module.linkSystemLibrary("ole32", .{});
    thumb_module.linkSystemLibrary("shell32", .{});
    thumb_module.linkSystemLibrary("gdi32", .{});
    const thumb_library = b.addLibrary(.{
        .linkage = .static,
        .name = "otto_thumb",
        .root_module = thumb_module,
    });
    b.installArtifact(thumb_library);

    const test_step = b.step("test", "运行监听 / 缩略图口岸单元与集成测试（真 Win32 + 真 Shell）");

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/watch_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_tests = b.addRunArtifact(b.addTest(.{ .root_module = test_module }));
    test_step.dependOn(&run_tests.step);

    const thumb_test_module = b.createModule(.{
        .root_source_file = b.path("src/thumb_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    thumb_test_module.linkSystemLibrary("ole32", .{});
    thumb_test_module.linkSystemLibrary("shell32", .{});
    thumb_test_module.linkSystemLibrary("gdi32", .{});
    const run_thumb_tests = b.addRunArtifact(b.addTest(.{ .root_module = thumb_test_module }));
    // 两个测试进程串行：两边都会起 COM / 线程，Zig 0.17 的构建器还会把并行 test
    // step 的 stderr 与进度行交织在一起。串行后 --summary all 的输出可直接贴。
    run_thumb_tests.step.dependOn(&run_tests.step);
    test_step.dependOn(&run_thumb_tests.step);
}
