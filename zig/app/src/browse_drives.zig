//! 本机驱动器入口。只在启动或用户打开菜单时枚举，不做后台轮询、不递归读盘。
const std = @import("std");
const builtin = @import("builtin");

pub const Kind = enum {
    unknown,
    no_root,
    removable,
    fixed,
    remote,
    cdrom,
    ramdisk,

    pub fn text(self: Kind) []const u8 {
        return switch (self) {
            .unknown => "unknown",
            .no_root => "no_root",
            .removable => "removable",
            .fixed => "fixed",
            .remote => "network",
            .cdrom => "cdrom",
            .ramdisk => "ramdisk",
        };
    }

    pub fn label(self: Kind) []const u8 {
        return switch (self) {
            .unknown => "未知类型",
            .no_root => "不可访问",
            .removable => "可移动盘",
            .fixed => "固定盘",
            .remote => "网络盘",
            .cdrom => "光驱",
            .ramdisk => "内存盘",
        };
    }
};

pub const Drive = struct {
    letter: u8,
    kind: Kind,
    available: bool,
    volume: [261 * 3]u8 = @splat(0),
    volume_len: u16 = 0,

    pub fn volumeLabel(self: *const Drive) []const u8 {
        return self.volume[0..self.volume_len];
    }

    pub fn displayLabel(self: *const Drive) []const u8 {
        return if (self.volume_len > 0) self.volumeLabel() else self.kind.label();
    }

    pub fn root(self: Drive, buffer: *[3]u8) []const u8 {
        buffer.* = .{ self.letter, ':', '\\' };
        return buffer;
    }

    pub fn probeText(self: *const Drive, buffer: []u8) []const u8 {
        const label = self.volumeLabel();
        return std.fmt.bufPrint(buffer, "{c}:\\={s}{s}{s}{s}{s}", .{
            self.letter,
            self.kind.text(),
            if (label.len > 0) "[" else "",
            label,
            if (label.len > 0) "]" else "",
            if (self.available) "" else "(unavailable)",
        }) catch buffer[0..0];
    }
};

pub const List = struct {
    items: [26]Drive = undefined,
    len: usize = 0,

    pub fn slice(self: *const List) []const Drive {
        return self.items[0..self.len];
    }

    pub fn find(self: *const List, letter: u8) ?Drive {
        for (self.slice()) |drive| {
            if (std.ascii.toUpper(drive.letter) == std.ascii.toUpper(letter)) return drive;
        }
        return null;
    }

    pub fn text(self: *const List, buffer: []u8) []const u8 {
        var used: usize = 0;
        for (self.slice()) |drive| {
            var item_buffer: [1024]u8 = undefined;
            const item = drive.probeText(&item_buffer);
            if (used + item.len + @intFromBool(used > 0) > buffer.len) break;
            if (used > 0) {
                buffer[used] = ';';
                used += 1;
            }
            @memcpy(buffer[used..][0..item.len], item);
            used += item.len;
        }
        return buffer[0..used];
    }
};

pub fn enumerate() List {
    var result = List{};
    if (comptime builtin.os.tag != .windows) return result;
    const mask = GetLogicalDrives();
    for (0..26) |index| {
        if (mask & (@as(u32, 1) << @intCast(index)) == 0) continue;
        const letter: u8 = @intCast('A' + index);
        const wide = [4:0]u16{ letter, ':', '\\', 0 };
        const raw = GetDriveTypeW(wide[0..3 :0]);
        const kind: Kind = switch (raw) {
            1 => .no_root,
            2 => .removable,
            3 => .fixed,
            4 => .remote,
            5 => .cdrom,
            6 => .ramdisk,
            else => .unknown,
        };
        result.items[result.len] = .{
            .letter = letter,
            .kind = kind,
            .available = raw != 0 and raw != 1,
        };
        var volume_name: [261]u16 = @splat(0);
        if (GetVolumeInformationW(wide[0..3 :0], &volume_name, volume_name.len, null, null, null, null, 0) != 0) {
            const label = std.mem.sliceTo(&volume_name, 0);
            const written = std.unicode.wtf16LeToWtf8(&result.items[result.len].volume, label);
            result.items[result.len].volume_len = @intCast(written);
        }
        result.len += 1;
    }
    return result;
}

extern "kernel32" fn GetLogicalDrives() callconv(.winapi) u32;
extern "kernel32" fn GetDriveTypeW(root: [*:0]const u16) callconv(.winapi) u32;
extern "kernel32" fn GetVolumeInformationW(
    root: [*:0]const u16,
    volume_name: ?[*]u16,
    volume_name_size: u32,
    serial_number: ?*u32,
    maximum_component_length: ?*u32,
    flags: ?*u32,
    file_system_name: ?[*]u16,
    file_system_name_size: u32,
) callconv(.winapi) i32;

test "驱动器列表保留类型与不可访问名字" {
    var list = List{};
    list.items[0] = .{ .letter = 'C', .kind = .fixed, .available = true };
    list.items[1] = .{ .letter = 'E', .kind = .no_root, .available = false };
    list.len = 2;
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("C:\\=fixed;E:\\=no_root(unavailable)", list.text(&buffer));
    try std.testing.expectEqual('E', list.find('e').?.letter);
}
