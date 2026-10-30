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

    // 缩略图能力表口岸：只读注册表判断扩展名有没有 IThumbnailProvider 登记，
    // 不加载任何第三方 DLL。advapi32 只有 Windows 后端（caps_win.zig）需要。
    const caps_module = b.addModule("otto_caps", .{
        .root_source_file = b.path("src/caps.zig"),
        .target = target,
        .optimize = optimize,
    });
    caps_module.linkSystemLibrary("advapi32", .{});
    const caps_library = b.addLibrary(.{
        .linkage = .static,
        .name = "otto_caps",
        .root_module = caps_module,
    });
    b.installArtifact(caps_library);

    // 拖出口岸：公共 API（drag.zig）+ OLE / Shell 后端（drag_win.zig）。
    // user32 是隐藏源窗口与鼠标捕获的落点；ole32 / shell32 是拖放、PIDL 与
    // 剪贴板的落点。同样挂在模块上，消费方链接 otto_drag 自动带上。
    const drag_module = b.addModule("otto_drag", .{
        .root_source_file = b.path("src/drag.zig"),
        .target = target,
        .optimize = optimize,
    });
    drag_module.linkSystemLibrary("ole32", .{});
    drag_module.linkSystemLibrary("shell32", .{});
    drag_module.linkSystemLibrary("user32", .{});
    const drag_library = b.addLibrary(.{
        .linkage = .static,
        .name = "otto_drag",
        .root_module = drag_module,
    });
    b.installArtifact(drag_library);

    const test_step = b.step("test", "运行监听 / 缩略图 / 能力表 / 拖出口岸单元与集成测试（真 Win32 + 真 Shell）");

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
    // 四个测试进程串行：监听 / 缩略图 / 能力表 / 拖出都会碰 COM 或线程，Zig 0.17 的
    // 构建器还会把并行 test step 的 stderr 与进度行交织在一起。串行后
    // --summary all 的输出可直接贴。
    run_thumb_tests.step.dependOn(&run_tests.step);
    test_step.dependOn(&run_thumb_tests.step);

    // 能力表测试串在缩略图之后：第 1 条会调 thumb.get 做"Shell 真的能出图"的
    // 独立探针，必须和缩略图测试用同一套 Shell / COM 环境。
    const caps_test_module = b.createModule(.{
        .root_source_file = b.path("src/caps_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    caps_test_module.linkSystemLibrary("advapi32", .{});
    caps_test_module.linkSystemLibrary("ole32", .{});
    caps_test_module.linkSystemLibrary("shell32", .{});
    caps_test_module.linkSystemLibrary("gdi32", .{});
    const run_caps_tests = b.addRunArtifact(b.addTest(.{ .root_module = caps_test_module }));
    run_caps_tests.step.dependOn(&run_thumb_tests.step);
    test_step.dependOn(&run_caps_tests.step);

    // 拖出测试串在能力表之后：selftest 会真的建立 Shell 数据对象并读回 CF_HDROP，
    // 需要一个没被别的测试弄脏的 OLE 套间（每个 test 进程本来也是独立进程）。
    const drag_test_module = b.createModule(.{
        .root_source_file = b.path("src/drag_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    drag_test_module.linkSystemLibrary("ole32", .{});
    drag_test_module.linkSystemLibrary("shell32", .{});
    drag_test_module.linkSystemLibrary("user32", .{});
    const run_drag_tests = b.addRunArtifact(b.addTest(.{ .root_module = drag_test_module }));
    run_drag_tests.step.dependOn(&run_caps_tests.step);
    test_step.dependOn(&run_drag_tests.step);
}
