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
    // 版本号的唯一来源是 build.zig.zon 的 .version：配置阶段读出来注入成
    // `@import("build_options").version`。源码里不再抄第二份。
    const app_version = manifestVersion(b);
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
    // 缩略图隔离：客户端模块 + 同一个包里构建的 helper exe（`otto-thumb-host`）。
    const thumb_host_dep = b.dependency("thumb_host", .{
        .target = target,
        .optimize = optimize,
    });

    const app_imports: []const std.Build.Module.Import = &.{
        .{ .name = "nanoui", .module = nanoui_dep.module("nanoui") },
        .{ .name = "otto_core", .module = core_dep.module("otto_core") },
        .{ .name = "otto_watch", .module = ports_dep.module("otto_watch") },
        // 缩略图口岸（公共 API + Windows Shell 后端）与能力表口岸（只读注册表）。
        .{ .name = "otto_thumb", .module = thumb_dep.module("otto_thumb") },
        // 缩略图隔离客户端：把第三方 handler 关进 helper 进程（M4 第一块）。
        .{ .name = "otto_thumb_host", .module = thumb_host_dep.module("otto_thumb_host") },
        .{ .name = "otto_caps", .module = caps_dep.module("otto_caps") },
        // 拖出口岸：拖拽与剪贴板（OLE / Shell，只在 Windows 上场）。
        .{ .name = "otto_drag", .module = drag_dep.module("otto_drag") },
        // 库文件口岸：原子写 / 整读（容器格式在 core 的 library_binary）。
        .{ .name = "otto_library_file", .module = ports_dep.module("otto_library_file") },
        // L3 缩略图磁盘缓存（M4 第二块）：条目格式、原子替换、预算裁剪。
        .{ .name = "otto_diskcache", .module = ports_dep.module("otto_diskcache") },
        // 文件夹选择口岸：IFileOpenDialog（UI 的「导入文件夹」按钮）。
        .{ .name = "otto_folder_picker", .module = ports_dep.module("otto_folder_picker") },
        // 导入流水线的两个口岸：L0 扫描（真 Win32 属性/身份）与 L1 头部探测。
        .{ .name = "otto_scan", .module = ports_dep.module("otto_scan") },
        .{ .name = "otto_probe", .module = ports_dep.module("otto_probe") },
        // WAV 头部解析：解码器（audio/wav.zig）与 probe 共用同一份块扫描。
        .{ .name = "otto_wav_header", .module = ports_dep.module("otto_wav_header") },
        // 更新 feed 口岸（M5）：WinHTTP GET / 本地文件，只收发字节。
        .{ .name = "otto_feed", .module = ports_dep.module("otto_feed") },
    };

    const app_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = app_imports,
    });
    // 版本号走 build options，app 与测试两个 module 都要能 import。
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", app_version);
    // 更新公钥也走 build options：`zig/keys/otto-lite.key.pub` 是唯一来源，
    // 源码里没有第二份拷贝（公钥换掉时旧版本必然验不过，见 keys/README.md）。
    build_options.addOption([]const u8, "update_public_key", updatePublicKey(b));
    app_module.addOptions("build_options", build_options);
    // 音频 provider 的 WASAPI 是手写 extern（ole32：CoInitializeEx/CoCreateInstance），
    // 不经过 ports，也不引入 C shim；kernel32 由 Windows 目标默认链接。
    app_module.linkSystemLibrary("ole32", .{});
    const exe = b.addExecutable(.{
        .name = "otto-lite",
        .root_module = app_module,
    });

    b.installArtifact(exe);

    // 缩略图隔离的 helper：由 `zig/ports` 的构建图产出（`--size` 由客户端在 spawn 时给），
    // 这里只把它拷进同一个 `zig-out/bin`。**一次 `zig build` 出两个 exe**，
    // 而不是让用户/打包脚本自己拼——helper 与 otto-lite 必须是同一次构建的产物。
    const thumb_host_exe = thumb_host_dep.artifact("otto-thumb-host");
    const install_thumb_host = b.addInstallBinFile(thumb_host_exe.getEmittedBin(), "otto-thumb-host.exe");
    b.getInstallStep().dependOn(&install_thumb_host.step);

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
            .{ .name = "otto_thumb_host", .module = thumb_host_dep.module("otto_thumb_host") },
            .{ .name = "otto_caps", .module = caps_dep.module("otto_caps") },
            .{ .name = "otto_drag", .module = drag_dep.module("otto_drag") },
            .{ .name = "otto_library_file", .module = ports_dep.module("otto_library_file") },
            .{ .name = "otto_diskcache", .module = ports_dep.module("otto_diskcache") },
            .{ .name = "otto_folder_picker", .module = ports_dep.module("otto_folder_picker") },
            .{ .name = "otto_scan", .module = ports_dep.module("otto_scan") },
            .{ .name = "otto_probe", .module = ports_dep.module("otto_probe") },
            .{ .name = "otto_wav_header", .module = ports_dep.module("otto_wav_header") },
            .{ .name = "otto_feed", .module = ports_dep.module("otto_feed") },
        },
    });
    test_module.addOptions("build_options", build_options);
    // 测试进程不建音频设备，但链接期要认识音频 provider 引用的 ole32 符号。
    test_module.linkSystemLibrary("ole32", .{});
    const run_tests = b.addRunArtifact(b.addTest(.{ .root_module = test_module }));
    const test_step = b.step("test", "运行 live 适配层与 thumbs 取图层的单元测试");
    test_step.dependOn(&run_tests.step);
}

/// 读 `../keys/otto-lite.key.pub`（public key 文件的原文，base64）。
///
/// 为什么不在 `update_check.zig` 里 `@embedFile`：密钥文件在 `zig/keys/`，
/// 而本包的模块根是 `zig/app/`，`@embedFile("../../keys/…")` 会被"文件在模块外"
/// 拒绝。为什么不在 app 里复制一份：那会让公钥有两个来源，换密钥时必然漂移。
/// 构建脚本读一次、注入成常量，和版本号走同一条路。
fn updatePublicKey(b: *std.Build) []const u8 {
    const path = b.root.joinString(b.allocator, "../keys/otto-lite.key.pub") catch @panic("OOM");
    const text = b.root.root_dir.handle.readFileAlloc(
        b.graph.io,
        path,
        b.allocator,
        .limited(4 * 1024),
    ) catch |err| @panic(b.fmt("读取更新公钥 {s} 失败：{t}", .{ path, err }));
    // 构建选项是编译期常量，去掉尾部换行比在运行期反复 trim 更省事。
    return std.mem.trim(u8, text, " \t\r\n");
}

/// 读 `build.zig.zon` 的 `.version`，供编译期注入。
///
/// `b.root` 是当前包的构建根（`Build` 自己报错时也用它拼 `build.zig.zon`），
/// 所以不受调用者 cwd 影响。ZON 用 `std.zon.parse` 解析，只声明需要的一个字段，
/// 其余字段用 `ignore_unknown_fields` 跳过：清单以后加字段不会弄坏构建脚本。
fn manifestVersion(b: *std.Build) []const u8 {
    const manifest_path = b.root.joinString(b.allocator, "build.zig.zon") catch @panic("OOM");
    const manifest = b.root.root_dir.handle.readFileAlloc(
        b.graph.io,
        manifest_path,
        b.allocator,
        .limited(64 * 1024),
    ) catch |err| @panic(b.fmt("读取 {s} 失败：{t}", .{ manifest_path, err }));

    // std.zon 要求 [:0]const u8。
    const source = b.allocator.dupeSentinel(u8, manifest, 0) catch @panic("OOM");

    const Manifest = struct { version: []const u8 };
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const parsed: Manifest = std.zon.parse.fromSlice(Manifest, .{
        .gpa = b.allocator,
        .arena = b.allocator,
        .source = source,
        .diagnostics = &diagnostics,
        .ignore_unknown_fields = true,
    }) catch {
        diagnostics.fatal(manifest_path);
    };
    return b.dupe(parsed.version);
}
