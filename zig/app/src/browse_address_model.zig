//! 地址栏编辑状态：文本变化是纯内存操作；磁盘检查只在 navigation.enterPath 的提交里。
const std = @import("std");

pub const Editor = struct {
    storage: [std.Io.Dir.max_path_bytes]u8 = undefined,
    len: usize = 0,
    editing: bool = false,
    failure: ?[]const u8 = null,

    pub fn text(self: *const Editor) []const u8 {
        return self.storage[0..self.len];
    }

    pub fn begin(self: *Editor, current_path: []const u8) void {
        self.set(current_path) catch return;
        self.editing = true;
        self.failure = null;
    }

    /// 模拟或承接文本输入：只复制字节，不 stat、不列目录、不改 Session。
    pub fn set(self: *Editor, value: []const u8) error{PathTooLong}!void {
        if (value.len > self.storage.len) {
            self.failure = "路径过长";
            return error.PathTooLong;
        }
        @memcpy(self.storage[0..value.len], value);
        self.len = value.len;
        self.failure = null;
    }

    pub fn cancel(self: *Editor, current_path: []const u8) void {
        self.set(current_path) catch {};
        self.editing = false;
        self.failure = null;
    }

    pub fn finish(self: *Editor, current_path: []const u8) void {
        self.cancel(current_path);
    }

    pub fn fail(self: *Editor, err: anyerror) void {
        self.failure = errorText(err);
    }
};

/// UI 与探针共用同一组具名文案，避免一个写英文、另一个写中文。
pub fn errorText(err: anyerror) []const u8 {
    return switch (err) {
        error.PathNotFound => "路径不存在",
        error.NotDirectory => "不是目录",
        error.AccessDenied => "没有访问权限",
        error.NotReady => "介质未就绪",
        error.InvalidPath, error.PathTooLong => "路径无效",
        error.OutOfMemory => "内存不足",
        else => "路径不可用",
    };
}

test "地址编辑只改文本，取消恢复当前路径" {
    var editor = Editor{};
    editor.begin("C:\\root");
    try editor.set("  ..\\missing\\  ");
    try std.testing.expectEqualStrings("  ..\\missing\\  ", editor.text());
    try std.testing.expect(editor.editing);
    editor.cancel("C:\\root");
    try std.testing.expectEqualStrings("C:\\root", editor.text());
    try std.testing.expect(!editor.editing);
}
