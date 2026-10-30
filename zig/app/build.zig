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
    // zig/ports 是同一个 package，四个口岸各是一个 module：
    //   otto_watch / otto_thumb / otto_caps / otto_drag。依赖名分开写是为了让 app
    // 侧一眼看出自己引的是哪个口岸（build.zig.zon 里四个名字指向同一个 ../ports）。
    const ports_dep = b.dependency("ports", .{
        .target = target,
        .optimize = optimize,
    });
    const thumb_dep = b.dependency("thumb", .{
        .target = target,
        .optimize = optimize,
    });
    const caps_dep = b.dependency("caps", .{
        .target = target,
        .optimize = optimize,
    });
    const drag_dep = b.dependency("drag", .{
        .target = target,
        .optimize = optimize,
    });

    const app_imports: []const std.Build.Module.Import = &.{
        .{ .name = "nanoui", .module = nanoui_dep.module("nanoui") },
        .{ .name = "otto_core", .module = core_dep.module("otto_core") },
        .{ .name = "otto_watch", .module = ports_dep.module("otto_watch") },
        // 缩略图口岸（公共 API + Windows Shell 后端）与能力表口岸（只读注册表）。
        .{ .name = "otto_thumb", .module = thumb_dep.module("otto_thumb") },
        .{ .name = "otto_caps", .module = caps_dep.module("otto_caps") },
        // 拖出口岸：拖拽与剪贴板（OLE / Shell，只在 Windows 上场）。
        .{ .name = "otto_drag", .module = drag_dep.module("otto_drag") },
    };

    const app_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = app_imports,
    });
    const exe = b.addExecutable(.{
        .name = "otto-lite",
        .root_module = app_module,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // 测试根：只拉数据层 / 口岸 / 取图层 / 选择与拖拽快照，不碰 nanoui。
    //   * live.zig      合成 Event 覆盖相对路径 join、rename 的 from/to、overflow 映射；
    //   * thumbs.zig    缓存键与载荷头的纯函数（线程与真实 Shell 由 --demo-thumbs 覆盖）；
    //   * selection.zig 点击语义与路径收集（纯逻辑，不需要窗口）；
    //   * transport.zig 拖拽快照/取消与无窗口执行（真拖拽靠人工，见 README）。
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "otto_core", .module = core_dep.module("otto_core") },
            .{ .name = "otto_watch", .module = ports_dep.module("otto_watch") },
            .{ .name = "otto_thumb", .module = thumb_dep.module("otto_thumb") },
            .{ .name = "otto_caps", .module = caps_dep.module("otto_caps") },
            .{ .name = "otto_drag", .module = drag_dep.module("otto_drag") },
        },
    });
    const run_tests = b.addRunArtifact(b.addTest(.{ .root_module = test_module }));
    const test_step = b.step("test", "运行 live 适配层与 thumbs 取图层的单元测试");
    test_step.dependOn(&run_tests.step);
}
