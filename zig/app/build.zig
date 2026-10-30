const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .ReleaseSafe,
    });

    const nanoui_dep = b.dependency("nanoui", .{
        .target = target,
        .optimize = optimize,
    });
    const core_dep = b.dependency("otto_core", .{
        .target = target,
        .optimize = optimize,
    });
    // 监听口岸（zig/ports）：模块名 otto_watch，与它自己的 addModule 一致。
    const ports_dep = b.dependency("ports", .{
        .target = target,
        .optimize = optimize,
    });

    const app_imports: []const std.Build.Module.Import = &.{
        .{ .name = "nanoui", .module = nanoui_dep.module("nanoui") },
        .{ .name = "otto_core", .module = core_dep.module("otto_core") },
        .{ .name = "otto_watch", .module = ports_dep.module("otto_watch") },
    };

    const exe = b.addExecutable(.{
        .name = "otto-lite",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = app_imports,
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // 适配层测试：只以 live.zig 为根（不拉 nanoui），用合成 Event 覆盖
    // 相对路径 join、rename 的 from/to、overflow 映射；真实链路由 --demo 覆盖。
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/live.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "otto_core", .module = core_dep.module("otto_core") },
            .{ .name = "otto_watch", .module = ports_dep.module("otto_watch") },
        },
    });
    const run_tests = b.addRunArtifact(b.addTest(.{ .root_module = test_module }));
    const test_step = b.step("test", "运行 live 适配层测试（合成事件，不碰真实文件系统）");
    test_step.dependOn(&run_tests.step);
}
