//! A Windows surface's part of the frame log (`ui.FrameLog`): the record a
//! frame appends when it is built, and the canvas and presentation times the
//! `WM_PAINT` that follows it fills in.
//!
//! Windows paints after the frame that asked for it, not inside it, so one
//! frame is two moments: `appendFrame` at the end of `buildFrame`, then
//! `painted` around the blit, the upload and `Present`, or the Direct3D 11
//! frame. `log_last_end` is when the last paint ended, which is what the
//! next frame's `drawable_wait_ms` waited for. Everything here costs one
//! null check per frame until an app calls `Surface.recordFrames`.
const std = @import("std");
const clock = @import("../ui/clock.zig");
const frame_log = @import("../ui/frame_log.zig");
const FrameLog = frame_log.FrameLog;
const ctx_mod = @import("../ui/context.zig");

pub const Timing = struct {
    /// The record the next `WM_PAINT` belongs to.
    index: usize = 0,
    /// A frame was appended and its paint has not run yet.
    pending: bool = false,
    /// When the last frame's painting ended: what the next frame waited for.
    last_end: f64 = 0,

    /// Appends one built frame: when it started, how long it had waited since
    /// the last paint ended, and what its phases cost. `sync` says the frame
    /// is presented with vsync (the swap chain), not the blit.
    pub fn appendFrame(t: *Timing, log: *FrameLog, c: *const ctx_mod.Context, now: f64, dt: f32, sync: bool) void {
        const end = clock.now();
        const phases_ms = c.stats.build_ms + c.stats.layout_ms + c.stats.paint_ms;
        const wait_ms = if (t.last_end > 0) @max(0, (now - t.last_end) * 1000) else 0;
        t.index = log.append(.{
            .t = now,
            .kind = .input,
            .interval_ms = if (log.last_t > 0) @max(0, (now - log.last_t) * 1000) else 0,
            .duration = if (dt > 0) dt else 1.0 / 60.0,
            .dt = dt,
            .build_ms = c.stats.build_ms,
            .layout_ms = c.stats.layout_ms,
            .paint_ms = c.stats.paint_ms,
            .after_frame_ms = @max(0, (end - now) * 1000 - phases_ms),
            .drawable_wait_ms = wait_ms,
            .encode_ms = 0,
            .sync = sync,
            .nodes = c.stats.nodes,
            .instances = c.stats.instances,
            .atlas_reset = false,
            .animating = c.animating,
        });
        t.pending = true;
        t.last_end = end;
    }

    /// The canvas and the presentation of the pending frame: `t_paint` is
    /// just before it was drawn, `t_raster` after the canvas was rasterized
    /// (the same moment as `t_paint` when the GPU drew the frame, so its
    /// `raster_ms` is 0 and its `present_ms` is the whole thing).
    pub fn painted(t: *Timing, log: *FrameLog, t_paint: f64, t_raster: f64) void {
        if (!t.pending) return;
        const end = clock.now();
        log.setPresent(t.index, @max(0, (t_raster - t_paint) * 1000), @max(0, (end - t_raster) * 1000));
        t.pending = false;
        t.last_end = end;
    }
};
