//! `--pcm-probe`：真实预览生命周期的 PCM 驻留与进程峰值（不建窗口）。
const std = @import("std");
const progressive = @import("audio/progressive.zig");
const bench_win = @import("bench_win.zig");
const budget = @import("mem_budget.zig");

const mib = 1024.0 * 1024.0;

fn mb(bytes: usize) f64 {
    return @as(f64, @floatFromInt(bytes)) / mib;
}

fn memory() usize {
    const value = bench_win.resident() orelse return 0;
    return value.working_set;
}

fn peakMemory() usize {
    const value = bench_win.resident() orelse return 0;
    return value.peak_working_set;
}

fn sleepMs(io: std.Io, ms: u64) void {
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(@intCast(ms)), .awake) catch {};
}

pub fn run(init: std.process.Init, allocator: std.mem.Allocator, path: []const u8, cycles: u32, play: bool) !u8 {
    const baseline = memory();
    var wave_ws_max = baseline;
    var play_ws_max: usize = 0;
    var wave_resident_max: usize = 0;
    var play_resident_max: usize = 0;
    var after_ws_max = baseline;
    var after_ws_min = baseline;
    var released: u32 = 0;
    var played = false;
    var last_mode: @import("audio/residency.zig").Mode = .auto;
    var decoded_pcm: u64 = 0;

    for (0..@max(1, cycles)) |index| {
        var started = progressive.start(allocator, path, .{}) catch |err| {
            std.debug.print("pcm-probe: open failed error={s}\n", .{@errorName(err)});
            return 1;
        };
        started.session.waitComplete();
        _ = started.session.pump();
        last_mode = started.session.pcm_residency;
        decoded_pcm = started.session.total_frames * @as(u64, started.session.channels) * 2;
        const resident = started.session.pcmBytes();
        const wave_ws = memory();
        wave_resident_max = @max(wave_resident_max, resident);
        wave_ws_max = @max(wave_ws_max, wave_ws);
        std.debug.print(
            "pcm-probe: cycle={d} phase=waveform mode={s} resident_pcm={d} decoded_pcm={d} ws_mib={d:.2} peak_ws_mib={d:.2}\n",
            .{ index + 1, last_mode.label(), resident, decoded_pcm, mb(wave_ws), mb(peakMemory()) },
        );

        if (play and index == 0) {
            started.session.play() catch |err| {
                if (err == error.NoAudioEndpoint) {
                    std.debug.print("pcm-probe: play=NoAudioEndpoint（具名环境限制）\n", .{});
                } else {
                    std.debug.print("pcm-probe: play failed error={s}\n", .{@errorName(err)});
                    started.session.deinit(allocator);
                    return 1;
                }
            };
            if (started.session.player != null) {
                played = true;
                sleepMs(init.io, 300);
                play_resident_max = @max(play_resident_max, started.session.pcmBytes());
                play_ws_max = @max(play_ws_max, memory());
                started.session.seek(started.session.duration_ms / 2) catch |err| {
                    std.debug.print("pcm-probe: seek failed error={s}\n", .{@errorName(err)});
                    started.session.deinit(allocator);
                    return 1;
                };
                sleepMs(init.io, 300);
                play_resident_max = @max(play_resident_max, started.session.pcmBytes());
                play_ws_max = @max(play_ws_max, memory());
                std.debug.print(
                    "pcm-probe: phase=playing resident_pcm={d} ws_mib={d:.2} position_ms={d} peak_ws_mib={d:.2}\n",
                    .{ started.session.pcmBytes(), mb(memory()), started.session.positionMs(), mb(peakMemory()) },
                );
                started.session.stop();
            }
        }
        started.session.deinit(allocator);
        released += 1;
        const after = memory();
        after_ws_max = @max(after_ws_max, after);
        after_ws_min = @min(after_ws_min, after);
    }

    const within = @max(wave_resident_max, play_resident_max) <= budget.pcm_max_bytes;
    std.debug.print(
        "pcm-probe: summary file={s} mode={s} cycles={d} released={d} decoded_pcm={d} wave_resident_max={d} play_resident_max={d} pcm_budget={d} pcm_within_budget={} baseline_ws_mib={d:.2} wave_ws_max_mib={d:.2} play_ws_max_mib={d:.2} peak_ws_mib={d:.2} after_ws_min_mib={d:.2} after_ws_max_mib={d:.2} played={}\n",
        .{
            path,
            last_mode.label(),
            @max(1, cycles),
            released,
            decoded_pcm,
            wave_resident_max,
            play_resident_max,
            budget.pcm_max_bytes,
            within,
            mb(baseline),
            mb(wave_ws_max),
            mb(play_ws_max),
            mb(peakMemory()),
            mb(after_ws_min),
            mb(after_ws_max),
            played,
        },
    );
    return 0;
}
