//! CSV evidence for the continuous layout audit. Run with `zig run`; stderr
//! is intentionally the output channel so no Windows stdout handle is needed.
const std = @import("std");
const layout = @import("responsive_layout.zig");

pub fn main() void {
    std.debug.print("width,name,duration,format,sample_rate,size,preview\n", .{});
    for (280..701) |width| {
        const plan = layout.solve(@intCast(width), 700);
        std.debug.print("{d},{d},{d},{d},{d},{d},{d}\n", .{
            width,
            plan.row.width(.name) orelse 0,
            plan.row.width(.duration) orelse 0,
            plan.row.width(.format) orelse 0,
            plan.row.width(.sample_rate) orelse 0,
            plan.row.width(.size) orelse 0,
            plan.preview_height,
        });
    }
}
