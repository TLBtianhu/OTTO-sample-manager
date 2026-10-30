//! The input method on Windows: the IME's composition string, through
//! Imm32, becomes the text ops a focused field applies (marked text, then
//! the committed text), and the composition and candidate windows follow
//! the caret. nanoui draws the composition itself, in the text field, so
//! the system's composition window stays hidden (`WM_IME_SETCONTEXT`);
//! the candidate window is still the IME's, placed at the caret.
const std = @import("std");
const w = @import("win32.zig");
const ctx_mod = @import("../ui/context.zig");

pub const HIMC = *opaque {};
pub const COMPOSITIONFORM = extern struct {
    dwStyle: u32 = 0,
    ptCurrentPos: w.POINT = .{},
    rcArea: w.RECT = .{},
};
pub const CANDIDATEFORM = extern struct {
    dwIndex: u32 = 0,
    dwStyle: u32 = 0,
    ptCurrentPos: w.POINT = .{},
    rcArea: w.RECT = .{},
};

/// ImmGetCompositionStringW's indexes (GCS_*).
pub const GCS_COMPSTR = 0x0008;
pub const GCS_CURSORPOS = 0x0080;
pub const GCS_RESULTSTR = 0x0800;
/// COMPOSITIONFORM's and CANDIDATEFORM's styles (CFS_*).
pub const CFS_POINT = 0x0002;
pub const CFS_CANDIDATEPOS = 0x0040;
/// WM_IME_SETCONTEXT's type bit for the system's composition window.
pub const ISC_SHOWUICOMPOSITIONWINDOW: u32 = 0x80000000;

pub extern "imm32" fn ImmGetContext(hwnd: w.HWND) callconv(.winapi) ?HIMC;
pub extern "imm32" fn ImmReleaseContext(hwnd: w.HWND, himc: HIMC) callconv(.winapi) w.BOOL;
pub extern "imm32" fn ImmGetCompositionStringW(himc: HIMC, index: u32, buf: ?*anyopaque, len: u32) callconv(.winapi) i32;
pub extern "imm32" fn ImmSetCompositionWindow(himc: HIMC, form: *const COMPOSITIONFORM) callconv(.winapi) w.BOOL;
pub extern "imm32" fn ImmSetCandidateWindow(himc: HIMC, form: *const CANDIDATEFORM) callconv(.winapi) w.BOOL;

/// What the input method remembers between messages.
pub const State = struct {
    /// Between WM_IME_STARTCOMPOSITION and WM_IME_ENDCOMPOSITION.
    composing: bool = false,
    /// The focused field shows a composition (the IME's text is marked in
    /// it), so an empty composition string is one that erases that text.
    marked: bool = false,
    /// The composition string's UTF-16 units, as the IME gave them.
    wide: std.ArrayList(u16) = .empty,
    /// The composition and the committed text as UTF-8: the ops of the last
    /// message point into these, valid until the next one.
    composition: std.ArrayList(u8) = .empty,
    result: std.ArrayList(u8) = .empty,
    /// Memory for the ops `compose` returns.
    out: [2]ctx_mod.TextOp = undefined,

    pub fn deinit(s: *State, gpa: std.mem.Allocator) void {
        s.wide.deinit(gpa);
        s.composition.deinit(gpa);
        s.result.deinit(gpa);
        s.* = .{};
    }
};

/// The strings one WM_IME_COMPOSITION carries.
pub const Message = struct {
    /// GCS_RESULTSTR: text the IME committed, UTF-8.
    result: []const u8 = "",
    /// GCS_COMPSTR: the text being composed, UTF-8; null when the message
    /// carries no composition string.
    composition: ?[]const u8 = null,
    /// The caret inside the composition, in UTF-8 bytes.
    caret: usize = 0,
};

/// The UTF-8 of `units` in `out`; null when they are not UTF-16 (or out of
/// memory), and "" for none.
pub fn decode(gpa: std.mem.Allocator, out: *std.ArrayList(u8), units: []const u16) ?[]const u8 {
    out.clearRetainingCapacity();
    // Three UTF-8 bytes per UTF-16 unit at most (four for a surrogate pair
    // of two units).
    out.resize(gpa, units.len * 3) catch return null;
    const n = std.unicode.utf16LeToUtf8(out.items, units) catch {
        out.clearRetainingCapacity();
        return null;
    };
    out.shrinkRetainingCapacity(n);
    return out.items;
}

/// Where in UTF-8 a caret at UTF-16 unit `at` of `units` is.
pub fn byteOfUnit(units: []const u16, at: usize) usize {
    var i: usize = 0;
    var bytes: usize = 0;
    while (i < units.len and i < at) : (i += 1) {
        const u = units[i];
        if (u >= 0xD800 and u <= 0xDBFF) {
            // A surrogate pair: four bytes, whether the caret is between
            // its halves or after it.
            bytes += 4;
            if (i + 1 < at) i += 1;
        } else if (u >= 0xDC00 and u <= 0xDFFF) {
            bytes += 3; // a lone low half: U+FFFD
        } else bytes += std.unicode.utf8CodepointSequenceLength(u) catch 3;
    }
    return bytes;
}

/// The ops one composition message makes, in `s.out`: the committed text
/// first (an insert, which replaces the marked text), then the composition
/// (marked text, underlined). Empty when there is nothing to change.
pub fn ops(s: *State, m: Message, out: *[2]ctx_mod.TextOp) []const ctx_mod.TextOp {
    var n: usize = 0;
    if (m.result.len > 0) {
        out[n] = .{ .insert = m.result };
        n += 1;
        s.marked = false;
    }
    if (m.composition) |text| {
        // An empty composition with nothing marked is the IME's "nothing
        // composed" between real ones: it must not eat a selection.
        if (text.len > 0 or s.marked) {
            out[n] = .{ .set_marked = .{ .text = text, .sel_start = m.caret, .sel_len = 0 } };
            n += 1;
            s.marked = text.len > 0;
        }
    }
    return out[0..n];
}

/// The end of a composition: the field's text is no longer underlined (its
/// bytes stay, as the IME committed them in its last message). Empty when
/// the field shows no composition.
pub fn end(s: *State, out: *[1]ctx_mod.TextOp) []const ctx_mod.TextOp {
    s.composing = false;
    if (!s.marked) return out[0..0];
    s.marked = false;
    out[0] = .unmark;
    return out[0..1];
}

/// One composition string (`index` is GCS_*), as UTF-8 in `out`; its UTF-16
/// units stay in `s.wide` for the caret (`GCS_CURSORPOS`). Null when the
/// string cannot be read: nothing changes, rather than the field's
/// composition going away.
fn string(himc: HIMC, index: u32, s: *State, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) ?[]const u8 {
    const bytes = ImmGetCompositionStringW(himc, index, null, 0);
    if (bytes < 0) return null;
    if (bytes == 0) {
        s.wide.clearRetainingCapacity();
        out.clearRetainingCapacity();
        return "";
    }
    const units: usize = @intCast(@divTrunc(bytes, 2));
    s.wide.resize(gpa, units) catch {
        s.wide.clearRetainingCapacity();
        return null;
    };
    const got = ImmGetCompositionStringW(himc, index, @ptrCast(s.wide.items.ptr), @intCast(bytes));
    if (got < 0) {
        s.wide.clearRetainingCapacity();
        return null;
    }
    const used = @min(@as(usize, @intCast(got)), units * 2);
    s.wide.shrinkRetainingCapacity(used / 2);
    return decode(gpa, out, s.wide.items);
}

/// Reads the strings of one WM_IME_COMPOSITION through its input context.
pub fn read(himc: HIMC, flags: u32, s: *State, gpa: std.mem.Allocator) Message {
    var m: Message = .{};
    if (flags & GCS_RESULTSTR != 0) if (string(himc, GCS_RESULTSTR, s, gpa, &s.result)) |text| {
        m.result = text;
    };
    if (flags & GCS_COMPSTR != 0) if (string(himc, GCS_COMPSTR, s, gpa, &s.composition)) |text| {
        m.composition = text;
        // The cursor is in UTF-16 units of the composition; at its end
        // when the message does not say.
        var caret: usize = s.wide.items.len;
        if (flags & GCS_CURSORPOS != 0) {
            const pos = ImmGetCompositionStringW(himc, GCS_CURSORPOS, null, 0);
            if (pos >= 0) caret = @intCast(pos);
        }
        caret = @min(caret, s.wide.items.len);
        m.caret = byteOfUnit(s.wide.items, caret);
    };
    return m;
}

/// The ops of a WM_IME_COMPOSITION; null when there is nothing to apply (or
/// no input context: no IME).
pub fn compose(s: *State, h: w.HWND, flags: u32, gpa: std.mem.Allocator) ?[]const ctx_mod.TextOp {
    const himc = ImmGetContext(h) orelse return null;
    defer _ = ImmReleaseContext(h, himc);
    const m = read(himc, flags, s, gpa);
    if (m.result.len == 0 and m.composition == null) return null;
    const n = ops(s, m, &s.out);
    return if (n.len == 0) null else n;
}

/// Places the composition and candidate windows at the caret: IMM's points
/// are client pixels, and the caret is in view points.
pub fn follow(h: w.HWND, c: *ctx_mod.Context, scale: f32) void {
    const f = c.focused_text orelse return;
    const himc = ImmGetContext(h) orelse return;
    defer _ = ImmReleaseContext(h, himc);
    const r = f.caret_rect;
    const left: i32 = @intFromFloat(r.x * scale);
    const top: i32 = @intFromFloat(r.y * scale);
    const bottom: i32 = @intFromFloat((r.y + r.h) * scale);
    const comp: COMPOSITIONFORM = .{ .dwStyle = CFS_POINT, .ptCurrentPos = .{ .x = left, .y = top } };
    _ = ImmSetCompositionWindow(himc, &comp);
    // Under the caret, where the field's text goes on: the IME picks the
    // side itself when there is no room below.
    const cand: CANDIDATEFORM = .{ .dwStyle = CFS_CANDIDATEPOS, .ptCurrentPos = .{ .x = left, .y = bottom } };
    _ = ImmSetCandidateWindow(himc, &cand);
}

/// WM_IME_SETCONTEXT: nanoui draws the composition in its text field, so the
/// system's composition window is not shown; the candidate window still is.
pub fn setContext(h: w.HWND, msg: u32, wp: w.WPARAM, lp: w.LPARAM) w.LRESULT {
    // The flags are the low 32 bits of lParam, whatever the width of a
    // pointer here; the rest of it is not used.
    const flags: u32 = @truncate(@as(usize, @bitCast(lp)));
    return w.DefWindowProcW(h, msg, wp, @intCast(flags & ~ISC_SHOWUICOMPOSITIONWINDOW));
}
