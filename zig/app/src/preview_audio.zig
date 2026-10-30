//! 音频分支的绘制：标题与播放键、格式/时长，以及会话里**已经画好**的波形位图与
//! 播放进度竖线。
//!
//! 为什么单独一个文件：`preview_panel.zig` 已经贴着单文件行数上限；这一节只依赖
//! `preview.AudioSession` 的公开字段，拆出来两边都留有余量，五个分支的 switch
//! 仍然在 `preview_panel.zig` 里（视图依然是"按 Outcome 分支画"，不按媒体类型分叉）。
//!
//! 为什么视图只画"一张图"：波形不是视图算出来的，是解码时顺带算好、存在会话里的
//! （`audio/peaks.zig` + `audio/waveform.zig`）。这里不认识 WAV、不认识采样率、
//! 不认识 min/max，只认识"会话里有一张图和一个毫秒位置"。
//!
//! 为什么进度线不画进位图：位图的 key 只随文件内容变化（路径 + mtime + size），
//! 播放时不该每帧重新编码/上传像素。线用绝对定位的 div 画，动的只有 offset。
//!
//! 位图的颜色是**白色**、背景透明：这里用 `ui.image` 的 `tint` 把它染成主题
//! 强调色，深浅两套主题共用同一张位图。

const std = @import("std");
const nanoui = @import("nanoui");
const preview = @import("preview.zig");
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
};

/// 画 `.audio` 分支。`provider` 是注册表答话的 provider 名字（截图能核对"是谁答的"）。
/// 由 UI 线程调用：`play()/stop()` 只投递命令，设备与播放线程都在 `audio/player.zig`。
pub fn draw(
    c: *ui.Context,
    session: *preview.AudioSession,
    provider: ?[]const u8,
    identity: Identity,
) void {
    const playing = session.isPlaying();

    // 标题与播放键同一行：波形要占 56 点，纵向预算只够四行。
    const header = ui.div(c).row().wFull().itemsCenter().justifyBetween().gap(8);
    caption(c, provider);
    const tools = ui.div(c).row().itemsCenter().gap(8);
    // 位置常驻（不在播放时显示 0）：按钮不会因为文字出现/消失而左右跳。
    ui.textf(c, .{ .size = 10, .color = c.theme.muted }, "{d} / {d} ms", .{
        session.positionMs(),
        session.durationMs(),
    });
    const button = ui.button(c, if (playing) "停止" else "播放", .{ .size = 11 });
    tools.end();
    header.end();
    if (button.clicked) {
        if (playing) session.stop() else _ = play(session);
        c.changed = true;
    }

    ui.textf(c, .{ .size = 13 }, "{d} Hz · {d} 声道 · {d} 位", .{
        session.sample_rate,
        session.channels,
        session.bits,
    });
    ui.textf(c, .{ .size = 10, .color = c.theme.muted }, "时长 {d}.{d:0>3} 秒 · {d} 字节 PCM", .{
        session.duration_ms / 1000,
        session.duration_ms % 1000,
        session.pcm.len,
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

/// 播放会话（播放键与 Enter 共用）；失败只打一行日志，不弹窗、不抢焦点。
/// 返回是否真的开始播放，调用方据此决定要不要重画。
pub fn play(session: *preview.AudioSession) bool {
    session.play() catch |err| {
        std.debug.print(
            "otto-lite: 音频播放失败（{s} hresult=0x{x:0>8}）\n",
            .{ @errorName(err), @as(u32, @bitCast(player_mod.lastHresult())) },
        );
        return false;
    };
    return true;
}

/// 波形（图）+ 播放进度（div）。`waveform.pixels` 为空时什么都不画，
/// 调用方不用先判断。
fn drawWave(c: *ui.Context, session: *const preview.AudioSession, identity: Identity) void {
    const bitmap = session.waveform;
    if (bitmap.width == 0 or bitmap.height == 0 or bitmap.pixels.len == 0) return;

    const w: f32 = @floatFromInt(bitmap.width);
    const h: f32 = @floatFromInt(bitmap.height);
    // 轨道：圆角浅底，透明背景的位图叠上去才有"波形在条里"的样子；`clip` 让
    // 进度线不会画出圆角之外。
    const stack = ui.div(c).w(w).h(h).rounded(4).bg(c.theme.track).clip();
    defer stack.end();

    var key_buffer: [64]u8 = undefined;
    if (!ui.image(c, .{
        .key = key(&key_buffer, identity),
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

fn key(buffer: *[64]u8, identity: Identity) []const u8 {
    var hasher = std.hash.Wyhash.init(0x7761_7665); // "wave"
    hasher.update(identity.path);
    hasher.update(std.mem.asBytes(&identity.mtime));
    hasher.update(std.mem.asBytes(&identity.size));
    return std.fmt.bufPrint(buffer, "wave|{x:0>16}", .{hasher.final()}) catch "wave";
}
