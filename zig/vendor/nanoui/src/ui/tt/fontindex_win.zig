//! The folder digest the cheap Windows way: FindFirstFileW reports each
//! entry's last-write time and size along with its name, so one enumeration
//! gives what the portable path pays an open/stat/close per font for
//! (measured: 0.5 ms vs 15 ms for 372 files).
//!
//! A folder with subfolders is not descended here: `fontindex` falls back
//! to the portable walk for that (the font folders on Windows are flat).
const std = @import("std");

const FILETIME = extern struct { low: u32, high: u32 };
/// `WIN32_FIND_DATAW` (Win64): the name's attributes, three file times,
/// size and reserved words before the names.
const FindData = extern struct {
    attributes: u32,
    creation: FILETIME,
    access: FILETIME,
    write: FILETIME,
    size_high: u32,
    size_low: u32,
    reserved0: u32,
    reserved1: u32,
    name: [260]u16,
    alternate: [14]u16,
};

extern "kernel32" fn FindFirstFileW(path: [*:0]const u16, data: *FindData) callconv(.winapi) *anyopaque;
extern "kernel32" fn FindNextFileW(handle: *anyopaque, data: *FindData) callconv(.winapi) i32;
extern "kernel32" fn FindClose(handle: *anyopaque) callconv(.winapi) i32;

const attribute_directory: u32 = 0x10;

pub const Error = error{ HasSubdirectory, OutOfMemory, InvalidUtf8 };

/// Adds every top-level font file's name, mtime and size to `sum`; the
/// count joins them at the end. `error.HasSubdirectory` means the caller
/// should use the portable walk instead.
pub fn fingerprint(allocator: std.mem.Allocator, dir_path: []const u8, sum: *u64) Error!void {
    const pattern = try std.fs.path.join(allocator, &.{ dir_path, "*" });
    defer allocator.free(pattern);
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(allocator, pattern);
    defer allocator.free(wide);

    var data: FindData = undefined;
    const handle = FindFirstFileW(wide.ptr, &data);
    // INVALID_HANDLE_VALUE: an empty folder (or no access). The walk below
    // handles those, and a failure must never look like an empty digest.
    if (@intFromPtr(handle) == std.math.maxInt(usize)) return error.HasSubdirectory;
    defer _ = FindClose(handle);

    var count: usize = 0;
    while (true) {
        const name = std.mem.sliceTo(&data.name, 0);
        if (data.attributes & attribute_directory != 0) {
            // `.` and `..` are directories too: only real subfolders matter.
            if (!(name.len == 1 and name[0] == '.') and !(name.len == 2 and name[0] == '.' and name[1] == '.')) {
                return error.HasSubdirectory;
            }
        } else if (isFont(name)) {
            const mtime = (@as(u64, data.write.high) << 32) | data.write.low;
            const size = (@as(u64, data.size_high) << 32) | data.size_low;
            var h = std.hash.Wyhash.init(0x4e554649);
            h.update(std.mem.sliceAsBytes(name));
            h.update(std.mem.asBytes(&mtime));
            h.update(std.mem.asBytes(&size));
            sum.* +%= h.final();
            count += 1;
        }
        if (FindNextFileW(handle, &data) == 0) break;
    }
    sum.* +%= std.hash.Wyhash.hash(0x4e554649, std.mem.asBytes(&count));
}

/// The scan's extension filter in UTF-16: `.ttf` or `.ttc`, any case.
fn isFont(name: []const u16) bool {
    if (name.len < 4 or name[name.len - 4] != '.') return false;
    const t = lower(name[name.len - 3]);
    const t2 = lower(name[name.len - 2]);
    const t3 = lower(name[name.len - 1]);
    return t == 't' and t2 == 't' and (t3 == 'f' or t3 == 'c');
}

fn lower(c: u16) u16 {
    return if (c >= 'A' and c <= 'Z') c + ('a' - 'A') else c;
}
