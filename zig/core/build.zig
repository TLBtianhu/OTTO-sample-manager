const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 数据层静态库：消费方（Electron 主进程 / Tauri / 测试）链接 otto_core。
    const library_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const library = b.addLibrary(.{
        .linkage = .static,
        .name = "otto_core",
        .root_module = library_module,
    });
    b.installArtifact(library);

    // 测试：fixtures/ 以匿名模块方式内嵌，保证测试不依赖运行目录。
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addImport("fixtures", b.createModule(.{
        .root_source_file = b.path("fixtures/fixtures.zig"),
        .target = target,
        .optimize = optimize,
    }));

    const run_tests = b.addRunArtifact(b.addTest(.{ .root_module = test_module }));
    const test_step = b.step("test", "运行数据层单元 / 集成测试");
    test_step.dependOn(&run_tests.step);
}
