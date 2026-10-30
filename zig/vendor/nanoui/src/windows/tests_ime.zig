const std = @import("std");
const testing = std.testing;
const ui = @import("../ui/ui.zig");
const ctx_mod = @import("../ui/context.zig");
const ime = @import("ime.zig");

const Field = struct {
    buf: ui.TextBuffer = .{},
    fn view(s: *Field, c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(20), .gap = 12 });
        defer ui.end(c);
        _ = ui.textField(c, &s.buf, .{ .placeholder = "Type", .width = .{ .px = 160 } });
    }
};

test "IME: a composition string becomes UTF-8, its caret in bytes" {
    var st: ime.State = .{};
    defer st.deinit(testing.allocator);
    // にほん: three units, three bytes each.
    const units = [_]u16{ 0x306B, 0x307B, 0x3093 };
    try testing.expectEqualStrings("にほん", ime.decode(testing.allocator, &st.composition, &units).?);
    try testing.expectEqual(@as(usize, 0), ime.byteOfUnit(&units, 0));
    try testing.expectEqual(@as(usize, 3), ime.byteOfUnit(&units, 1));
    try testing.expectEqual(@as(usize, 9), ime.byteOfUnit(&units, 3));
    // A surrogate pair is four UTF-8 bytes for two units (𝄞).
    const pair = [_]u16{ 0xD834, 0xDD1E };
    try testing.expectEqualStrings("\u{1D11E}", ime.decode(testing.allocator, &st.composition, &pair).?);
    try testing.expectEqual(@as(usize, 4), ime.byteOfUnit(&pair, 2));
    // Nothing composed: nothing, not a slice of stale bytes.
    try testing.expectEqualStrings("", ime.decode(testing.allocator, &st.composition, &[_]u16{}).?);
    // Not UTF-16 (half a surrogate pair): null, so nothing changes.
    try testing.expect(ime.decode(testing.allocator, &st.composition, &[_]u16{0xD834}) == null);
}

test "IME: commit, compose, erase and unmark become text ops" {
    var st: ime.State = .{};
    defer st.deinit(testing.allocator);
    var out: [2]ctx_mod.TextOp = undefined;
    var one_op: [1]ctx_mod.TextOp = undefined;

    // Nothing marked and an empty composition: no op, so a selection is
    // not eaten by the IME's idle message.
    try testing.expectEqual(@as(usize, 0), ime.ops(&st, .{ .composition = "" }, &out).len);

    // Composing に at the end.
    const composed = ime.ops(&st, .{ .composition = "に", .caret = 3 }, &out);
    try testing.expectEqual(@as(usize, 1), composed.len);
    try testing.expectEqualStrings("に", composed[0].set_marked.text);
    try testing.expectEqual(@as(usize, 3), composed[0].set_marked.sel_start);
    try testing.expect(st.marked);

    // Committing 日本 replaces the marked text.
    const commit = ime.ops(&st, .{ .result = "日本" }, &out);
    try testing.expectEqual(@as(usize, 1), commit.len);
    try testing.expectEqualStrings("日本", commit[0].insert);
    try testing.expect(!st.marked);

    // Composed again, then a backspace emptied it: the empty composition
    // deletes the marked text it once set.
    _ = ime.ops(&st, .{ .composition = "に", .caret = 3 }, &out);
    const erased = ime.ops(&st, .{ .composition = "", .caret = 0 }, &out);
    try testing.expectEqual(@as(usize, 1), erased.len);
    try testing.expectEqualStrings("", erased[0].set_marked.text);
    try testing.expect(!st.marked);
    try testing.expectEqual(@as(usize, 0), ime.end(&st, &one_op).len);

    // A composition still marked when the IME ends it: unmark it.
    _ = ime.ops(&st, .{ .composition = "に", .caret = 3 }, &out);
    try testing.expect(st.marked);
    const ended = ime.end(&st, &one_op);
    try testing.expectEqual(@as(usize, 1), ended.len);
    try testing.expectEqual(std.meta.activeTag(one_op[0]), .unmark);
    try testing.expect(!st.marked);
}

test "IME: a composition reaches a text field through its ops" {
    var s: Field = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Field.view), .{});
    defer t.deinit();
    try t.clickText("Type");
    try testing.expect(t.ctx.focused_text != null);

    var st: ime.State = .{};
    defer st.deinit(testing.allocator);
    var out: [2]ctx_mod.TextOp = undefined;

    // The IME composes にほん, its caret after に: the field shows the
    // composition, marked, with the caret inside it.
    const units = [_]u16{ 0x306B, 0x307B, 0x3093 };
    const text = ime.decode(testing.allocator, &st.composition, &units).?;
    t.textOps(ime.ops(&st, .{ .composition = text, .caret = ime.byteOfUnit(&units, 1) }, &out));
    try testing.expectEqualStrings("にほん", s.buf.text());
    const f = t.ctx.focused_text.?;
    try testing.expect(f.marked != null);
    try testing.expectEqual(@as(usize, 0), f.marked.?[0]);
    try testing.expectEqual(@as(usize, 3), f.caret);

    // It commits 日本 in place of the composition.
    const commit = [_]u16{ 0x65E5, 0x672C };
    t.textOps(ime.ops(&st, .{ .result = ime.decode(testing.allocator, &st.result, &commit).? }, &out));
    try testing.expectEqualStrings("日本", s.buf.text());
    try testing.expect(t.ctx.focused_text.?.marked == null);
    try testing.expectEqual(@as(usize, 6), t.ctx.focused_text.?.caret);
}
