//! 音频分支的绘制：标题与播放键、格式/时长，以及会话里**已经画好**的波形位图与
//! 播放进度竖线。
//!
//! 为什么单独一个文件：`preview_panel.zig` 已经贴着单文件行数上限；这一节只依赖
//! `audio_session.AudioSession` 的公开字段，拆出来两边都留有余量，五个分支的 switch
//! 仍然在视图那一枝（`preview_view.zig`）里（视图依然是"按 Outcome 分支画"，
//! 不按媒体类型分叉）。
//!
//! 为什么视图只画"一张图"：波形不是视图算出来的，是解码时顺带算好、存在会话里的
//! （`audio/peaks.zig` + `audio/waveform.zig`）。这里不认识 WAV、不认识采样率、
//! 不认识 min/max，只认识"会话里有一张图和一个毫秒位置"。
//!
//! 渐进式解码期间同一张位图会被重画（后台每解出一批列就画一次），所以位图的缓存键
//! 里带 `wave_version`（完成列数）：版本不变就不重新上传像素，版本变了才换键。
//! 未解出的列是透明的，露出轨道底色——不是猜测出来的波形。
//!
//! 为什么进度线不画进位图：位图的 key 只随文件内容变化（路径 + mtime + size），
//! 播放时不该每帧重新编码/上传像素。线用绝对定位的 div 画，动的只有 offset。
//!
//! 位图的颜色是**白色**、背景透明：这里用 `ui.image` 的 `tint` 把它染成主题
//! 强调色，深浅两套主题共用同一张位图。

const std = @import("std");
const nanoui = @import("nanoui");
const preview = @import("preview.zig");
const audio_session = @import("preview_audio_session.zig");
const media_key = @import("media_key.zig");
const player_mod = @import("audio/player.zig");
const waveform = @import("audio/waveform.zig");
const ui = nanoui.ui;

/// 进度竖线的宽度（点）。
const line_width: f32 = 2;

/// 位图的身份：路径 + mtime + size。内容变了键就变（与图位的缩略图同一套规则，
/// 但前缀不同——两张不同的图不能共用一个键，否则图集会拿错像素）。
pub const Identity = struct {
    path: []const u8,
    mtime: i64 = 0,
    size: u64 = 0,
    /// 波形位图的内容版本（完成列数）。渐进式解码每长出一批列就 +1，键跟着换，
    /// 图集才会重新上传像素；静态图（`preview_view`）一直用 0。
    wave_version: u32 = 0,
};

/// 画 `.audio` 分支。`provider` 是注册表答话的 provider 名字（截图能核对"是谁答的"）。
/// 由 UI 线程调用：`play()/stop()` 只投递命令，设备与播放线程都在 `audio/player.zig`。
pub fn draw(
    c: *ui.Context,
    session: *audio_session.AudioSession,
    provider: ?[]const u8,
    identity: Identity,
) void {
    const playing = session.isPlaying();
    const starting = session.isStartingAudio();

    // 标题与播放键同一行：波形要占 56 点，纵向预算只够四行。
    const header = ui.div(c).row().wFull().itemsCenter().justifyBetween().gap(8);
    caption(c, provider);
    const tools = ui.div(c).row().itemsCenter().gap(8);
    // 位置常驻（不在播放时显示 0）：按钮不会因为文字出现/消失而左右跳。
    ui.textf(c, .{ .size = 10, .color = c.theme.muted }, "{d} / {d} ms", .{
        session.positionMs(),
        session.durationMs(),
    });
    const label = if (starting) "取消" else if (playing) "停止" else if (session.audioError() != null) "重试" else "播放";
    const button = ui.button(c, label, .{ .size = 18 });
    tools.end();
    header.end();
    if (button.clicked) {
        if (starting or playing) session.stop() else _ = play(session);
        c.changed = true;
    }

    if (starting) {
        ui.text(c, "正在启动音频…", .{ .size = 18, .color = c.theme.accent });
    } else if (session.audioError()) |err| {
        ui.textf(c, .{ .size = 18, .color = c.theme.muted }, "音频启动失败：{s}", .{@errorName(err)});
    } else {
        ui.textf(c, .{ .size = 18 }, "{d} Hz · {d} 声道 · {d} 位", .{
            session.sample_rate,
            session.channels,
            session.bits,
        });
    }
    ui.textf(c, .{ .size = 10, .color = c.theme.muted }, "时长 {d}.{d:0>3} 秒 · {d} 字节 PCM{s}", .{
        session.duration_ms / 1000,
        session.duration_ms % 1000,
        session.pcmBytes(),
        if (session.isDecoding()) "（解码中）" else "",
    });

    drawWave(c, session, identity);
}

/// 小标题。provider 名字让截图能核对"是谁答的"；没有 provider 时只有标题。
fn caption(c: *ui.Context, provider: ?[]const u8) void {
    if (provider) |name| {
        ui.textf(c, .{ .size = 10, .color = c.theme.muted }, "音频预览 · {s}", .{name});
    } else {
        ui.text(c, "音频预览", .{ .size = 10, .color = c.theme.muted });
    }
}

/// 请求播放；首次 WASAPI 初始化在后台进行，视图显示“正在启动音频…”。
/// 返回请求是否被接受；设备错误由 `pump` 落地成具名状态与日志。
pub fn play(session: *audio_session.AudioSession) bool {
    session.startPlayback() catch |err| {
        std.debug.print(
            "otto-lite: 音频播放失败（{s} hresult=0x{x:0>8}）\n",
            .{ @errorName(err), @as(u32, @bitCast(player_mod.lastHresult())) },
        );
        return false;
    };
    return true;
}

/// 空格：正在播就停（保留位置），否则从当前位置播；不是音频就什么都不做。
/// 返回 true = 播放状态真的变了（调用方据此重画）。日志是 `--nanoui-script`
/// 验收 `play`/`stop` 两行的来源。
pub fn toggle(outcome: *preview.Outcome, name: []const u8) bool {
    switch (outcome.*) {
        .audio => |*session| {
            if (session.isPlaying() or session.isStartingAudio()) {
                session.stop();
                std.debug.print("otto-lite: stop name={s}\n", .{name});
                return true;
            }
            if (play(session)) {
                std.debug.print("otto-lite: play name={s} position_ms={d}\n", .{ name, session.positionMs() });
                return true;
            }
        },
        else => {},
    }
    return false;
}

/// 波形（图）+ 播放进度（div）。`waveform.pixels` 为空时什么都不画，
/// 调用方不用先判断。
///
/// 整条波形是可点击的：x 比例 → 毫秒 → `AudioSession.seek()`。点击帧里先处理
/// seek 再画进度线，所以线在同一帧就到点击位置；未播放时只是把播放头放过去。
fn drawWave(c: *ui.Context, session: *audio_session.AudioSession, identity: Identity) void {
    const bitmap = session.waveform;
    if (bitmap.width == 0 or bitmap.height == 0 or bitmap.pixels.len == 0) return;

    const w: f32 = @floatFromInt(bitmap.width);
    const h: f32 = @floatFromInt(bitmap.height);
    // 轨道：圆角浅底，透明背景的位图叠上去才有"波形在条里"的样子；`clip` 让
    // 进度线不会画出圆角之外。
    const stack = ui.div(c).w(w).h(h).rounded(4).bg(c.theme.track).clip();
    const it = stack.interaction();
    defer stack.end();

    if (it.clicked) seekFromClick(c, session, it.rect);

    var key_buffer: [64]u8 = undefined;
    const wave_key = media_key.makeVersioned(
        &key_buffer,
        "wave",
        identity.path,
        identity.mtime,
        identity.size,
        identity.wave_version,
    );
    if (!ui.image(c, .{
        .key = wave_key,
        .source = .{ .pixels = .{
            .bgra = bitmap.pixels,
            .width = bitmap.width,
            .height = bitmap.height,
            .stride = bitmap.stride,
        } },
        // 位图按 1:1 点阵渲染（240×56），按 1 声明；高分屏由 nanoui 放大。
        .max_width = w,
        .max_height = h,
        .scale = 1,
        .radius = 4,
        .tint = c.theme.accent,
    })) return;

    // 进度线：位置来自 Player 的原子量。播放时 `tick` 每拍重画，线跟着走。
    const x: f32 = @floatFromInt(waveform.progressX(
        bitmap.width,
        session.positionMs(),
        session.durationMs(),
        @intFromFloat(line_width),
    ));
    ui.div(c).absolute().w(line_width).hFull().offset(x, 0).rounded(1).bg(c.theme.accent).end();
}

/// 波形点击：把鼠标相对矩形左边缘的 x 换成比例，再换成目标毫秒。
/// `it.rect` 是上一帧的布局矩形（nanoui 的命中就是按上一帧算的），用它做换算
/// 与用户看到的波形一致。失败只打日志，不弹窗。
fn seekFromClick(c: *ui.Context, session: *audio_session.AudioSession, rect: ?ui.Rect) void {
    const r = rect orelse return;
    if (r.w <= 0) return;
    const target = waveform.positionMsAt(c.input.mouse.x - r.x, r.w, session.durationMs());
    session.seek(target) catch |err| {
        std.debug.print(
            "otto-lite: 音频 seek 失败（{s} hresult=0x{x:0>8}）\n",
            .{ @errorName(err), @as(u32, @bitCast(player_mod.lastHresult())) },
        );
        return;
    };
    c.changed = true;
    std.debug.print("otto-lite: seek position_ms={d}\n", .{session.positionMs()});
}
