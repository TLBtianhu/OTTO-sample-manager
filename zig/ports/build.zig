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

    // 缩略图隔离（M4 第一块）：客户端（thumb_host.zig + thumb_host_win.zig）与
    // helper 可执行文件。helper 是同一个包的第二个 exe，`zig build` 与客户端一起产出——
    // 不引脚本、不借外部工具，构建系统本身就是"一次出两个"的地方。
    const thumb_host_module = b.addModule("otto_thumb_host", .{
        .root_source_file = b.path("src/thumb_host.zig"),
        .target = target,
        .optimize = optimize,
    });
    thumb_host_module.addImport("otto_thumb", thumb_module);

    const thumb_host_main_module = b.addModule("otto_thumb_host_main", .{
        .root_source_file = b.path("src/thumb_host_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    thumb_host_main_module.addImport("otto_thumb", thumb_module);

    const thumb_host_exe = b.addExecutable(.{
        .name = "otto-thumb-host",
        .root_module = thumb_host_main_module,
    });
    // 显式拿到安装步：测试步骤要等 helper 真的落到 zig-out/bin（测试从环境变量拿路径）。
    const install_thumb_host = b.addInstallArtifact(thumb_host_exe, .{});
    b.getInstallStep().dependOn(&install_thumb_host.step);

    // 测试用的假 helper：只会睡觉、不读不写。验证超时与 TerminateProcess 需要它，
    // 名字带 `-fake`，不属于发布物（app 的安装步骤只装真 helper）。
    const thumb_host_fake_module = b.addModule("otto_thumb_host_fake", .{
        .root_source_file = b.path("src/thumb_host_fake.zig"),
        .target = target,
        .optimize = optimize,
    });
    const thumb_host_fake_exe = b.addExecutable(.{
        .name = "otto-thumb-host-fake",
        .root_module = thumb_host_fake_module,
    });
    const install_thumb_host_fake = b.addInstallArtifact(thumb_host_fake_exe, .{});
    b.getInstallStep().dependOn(&install_thumb_host_fake.step);

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

    // 文件夹选择口岸：IFileOpenDialog 的"选择文件夹"模式（手写 COM vtable）。
    // ole32 是 CoInitializeEx / CoCreateInstance / CoTaskMemFree 的落点。
    const folder_picker_module = b.addModule("otto_folder_picker", .{
        .root_source_file = b.path("src/folder_picker.zig"),
        .target = target,
        .optimize = optimize,
    });
    folder_picker_module.linkSystemLibrary("ole32", .{});
    const folder_picker_library = b.addLibrary(.{
        .linkage = .static,
        .name = "otto_folder_picker",
        .root_module = folder_picker_module,
    });
    b.installArtifact(folder_picker_library);

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

    // 库文件口岸：原子写（同目录 .tmp → sync → MoveFileExW）与带上限的整读。
    // 容器格式在 core 的 library_binary.zig；本口岸只收发字节，所以不依赖 core。
    const library_file_module = b.addModule("otto_library_file", .{
        .root_source_file = b.path("src/library_file.zig"),
        .target = target,
        .optimize = optimize,
    });
    const library_file_library = b.addLibrary(.{
        .linkage = .static,
        .name = "otto_library_file",
        .root_module = library_file_module,
    });
    b.installArtifact(library_file_library);

    // L0 扫描口岸：递归遍历 + 文件身份（GetFileInformationByHandle）+ 排序去重。
    // 只产出目录项事实，不打开内容；平台限定 Windows（见 src/scan.zig）。
    _ = b.addModule("otto_scan", .{
        .root_source_file = b.path("src/scan.zig"),
        .target = target,
        .optimize = optimize,
    });

    // L1 元数据口岸：只读前 64 KiB，WAV 头部解析与解码器共用 otto_wav_header。
    // WAV 头部解析是独立模块（app 的解码器也 import 它），这里是唯一的实现：
    // `probe` 通过模块名引用，而不是相对路径再编译一份（Zig 不允许一个文件属于
    // 两个模块）。
    const wav_header_module = b.addModule("otto_wav_header", .{
        .root_source_file = b.path("src/wav_header.zig"),
        .target = target,
        .optimize = optimize,
    });
    const probe_module = b.addModule("otto_probe", .{
        .root_source_file = b.path("src/probe.zig"),
        .target = target,
        .optimize = optimize,
    });
    probe_module.addImport("otto_wav_header", wav_header_module);

    const test_step = b.step("test", "运行监听 / 缩略图 / 能力表 / 拖出 / 库文件 / 扫描 / 探测 / 文件夹选择口岸的单元与集成测试（真 Win32 + 真 Shell）");

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

    // 库文件口岸最后跑：它只碰文件系统，不需要 COM / Shell，串行只是为了
    // `--summary all` 的输出能直接贴。
    const library_file_test_module = b.createModule(.{
        .root_source_file = b.path("src/library_file_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_library_file_tests = b.addRunArtifact(b.addTest(.{ .root_module = library_file_test_module }));
    run_library_file_tests.step.dependOn(&run_drag_tests.step);
    test_step.dependOn(&run_library_file_tests.step);

    // 扫描口岸：只碰文件系统（建树 / 隐藏位 / 真句柄），同样串行。
    const scan_test_module = b.createModule(.{
        .root_source_file = b.path("src/scan_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_scan_tests = b.addRunArtifact(b.addTest(.{ .root_module = scan_test_module }));
    run_scan_tests.step.dependOn(&run_library_file_tests.step);
    test_step.dependOn(&run_scan_tests.step);

    // 探测口岸：probe.zig 自己就是测试根（真临时文件 + 内存里造的 WAV）。
    const probe_test_module = b.createModule(.{
        .root_source_file = b.path("src/probe_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "otto_wav_header", .module = wav_header_module },
        },
    });
    const run_probe_tests = b.addRunArtifact(b.addTest(.{ .root_module = probe_test_module }));
    run_probe_tests.step.dependOn(&run_scan_tests.step);
    test_step.dependOn(&run_probe_tests.step);

    // WAV 头部解析：纯字节测试，单独一个编译图（不能和 otto_wav_header 模块
    // 同图，否则同一个文件会属于两个模块）。
    const wav_header_test_module = b.createModule(.{
        .root_source_file = b.path("src/wav_header_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_wav_header_tests = b.addRunArtifact(b.addTest(.{ .root_module = wav_header_test_module }));
    run_wav_header_tests.step.dependOn(&run_probe_tests.step);
    test_step.dependOn(&run_wav_header_tests.step);

    // 文件夹选择：只跑纯逻辑（选项位 / 取消码 / 宽字符路径 / 环境变量开关）；
    // 真实对话框必须人工验证，见 `folder_picker.zig` 的文件头。
    const folder_picker_test_module = b.createModule(.{
        .root_source_file = b.path("src/folder_picker_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    folder_picker_test_module.linkSystemLibrary("ole32", .{});
    const run_folder_picker_tests = b.addRunArtifact(b.addTest(.{ .root_module = folder_picker_test_module }));
    run_folder_picker_tests.step.dependOn(&run_wav_header_tests.step);
    test_step.dependOn(&run_folder_picker_tests.step);

    // 缩略图隔离（M4 第一块）：真 spawn 一个 helper、真写管道、真 TerminateProcess。
    // 路径通过环境变量给：test runner 只接受它自己的参数，路径没法走 argv。
    // 值是相对安装前缀的路径，配合下面显式 `setCwd(b.path("."))`（= 包根）使用——
    // Zig 0.17 的构建脚本拿不到安装前缀的字符串（它只以 LazyPath 存在），
    // 所以这里约定测试用默认前缀 `zig-out`（`zig build test` 的默认行为）。
    const thumb_host_test_module = b.createModule(.{
        .root_source_file = b.path("src/thumb_host_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "otto_thumb", .module = thumb_module },
            .{ .name = "otto_thumb_host", .module = thumb_host_module },
        },
    });
    const run_thumb_host_tests = b.addRunArtifact(b.addTest(.{ .root_module = thumb_host_test_module }));
    run_thumb_host_tests.setCwd(b.path("."));
    run_thumb_host_tests.setEnvironmentVariable("OTTO_THUMB_HOST", "zig-out/bin/otto-thumb-host.exe");
    run_thumb_host_tests.setEnvironmentVariable("OTTO_THUMB_FAKE", "zig-out/bin/otto-thumb-host-fake.exe");
    // 先装好两个 helper 再跑：环境变量指向的是安装位置，不是缓存里的编译产物。
    run_thumb_host_tests.step.dependOn(&install_thumb_host.step);
    run_thumb_host_tests.step.dependOn(&install_thumb_host_fake.step);
    run_thumb_host_tests.step.dependOn(&run_folder_picker_tests.step);
    test_step.dependOn(&run_thumb_host_tests.step);
}
