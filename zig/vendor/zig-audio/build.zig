const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The importable module consumers get: `@import("zig_audio")`.
    const mod = b.addModule("zig_audio", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // A static archive is built and installed so `zig build` has a concrete
    // artifact to check; library consumers normally depend on the module.
    const lib = b.addLibrary(.{
        .name = "zig_audio",
        .root_module = mod,
        .linkage = .static,
    });
    b.installArtifact(lib);

    const require_ffmpeg = b.option(
        bool,
        "require-ffmpeg",
        "Fail when any live-ffmpeg (L4) test skips; ZA_REQUIRE_FFMPEG=1 is equivalent",
    ) orelse false;
    const test_options = b.addOptions();
    test_options.addOption(bool, "require_ffmpeg", require_ffmpeg);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addOptions("test_options", test_options);
    const test_audit_mod = b.createModule(.{
        .root_source_file = b.path("src/test_audit.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("test_audit", test_audit_mod);
    const tests = b.addTest(.{
        .root_module = test_mod,
        .test_runner = .{ .path = b.path("src/test_runner.zig"), .mode = .simple },
    });
    const run_tests = b.addRunArtifact(tests);
    // Integration availability is an environment input, not a source-file
    // cache key. Always execute so a changed ZA_FFMPEG_PATH cannot reuse green.
    run_tests.stdio = .inherit;
    const test_step = b.step("test", "Run unit, API, integration and fuzz tests with L1-L4 audit");
    test_step.dependOn(&run_tests.step);

    const fuzz_mod = b.createModule(.{
        .root_source_file = b.path("src/fuzz.zig"),
        .target = target,
        .optimize = optimize,
    });
    const fuzz_exe = b.addExecutable(.{
        .name = "zig-audio-fuzz",
        .root_module = fuzz_mod,
    });
    const run_fuzz = b.addRunArtifact(fuzz_exe);
    const fuzz_step = b.step("fuzz", "Run one round of 10,000 mutation-fuzz iterations");
    fuzz_step.dependOn(&run_fuzz.step);

    // Benchmarks are always ReleaseFast, independent of -Doptimize: comparing
    // Debug numbers against a realtime factor is meaningless.
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    const bench_exe = b.addExecutable(.{
        .name = "zig-audio-bench",
        .root_module = bench_mod,
    });
    const run_bench = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Benchmark WAV and FLAC decoding against a realtime target");
    bench_step.dependOn(&run_bench.step);
}
