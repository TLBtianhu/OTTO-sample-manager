//! 当前库会话的唯一所有者：库路径、`Library` 与借用它的 `Live`。
//!
//! 启动允许两阶段装配：先建空库占位并重叠读盘，再 `adoptInitial` / `startLive`。
//! 运行期的保存与重载只能走这里。重载先把新路径、新库、新 Live 全部建好，
//! 才按 Live → Library 的依赖逆序释放旧对象；任何失败都不会动当前会话。
//! 浏览模式只有空内存库与 idle Live，保存和重载入口都以 `ReadOnly` 拒绝。

const std = @import("std");
const core = @import("otto_core");
const library_io = @import("library_io.zig");
const live_mod = @import("live.zig");

pub const LibrarySession = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    library_path: []u8,
    library_object: *core.store.Library,
    live_object: ?*live_mod.Live = null,
    read_only: bool,

    /// 建立启动占位。此时还没有 Live；启动加载线程只改这个 session 拥有的库。
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        initial_path: []const u8,
        read_only: bool,
    ) !LibrarySession {
        const owned_path = try allocator.dupe(u8, initial_path);
        errdefer allocator.free(owned_path);
        const empty_library = try allocator.create(core.store.Library);
        errdefer allocator.destroy(empty_library);
        empty_library.* = try core.store.empty(allocator);
        return .{
            .allocator = allocator,
            .io = io,
            .library_path = owned_path,
            .library_object = empty_library,
            .read_only = read_only,
        };
    }

    pub fn deinit(self: *LibrarySession) void {
        if (self.live_object) |opened_live| self.destroyPair(opened_live, self.library_object) else {
            self.library_object.deinit();
            self.allocator.destroy(self.library_object);
        }
        self.allocator.free(self.library_path);
        self.* = undefined;
    }

    /// 启动加载完成后接管解码结果；空库占位只在这里释放一次。
    /// 只能在没有 Live 的装配阶段调用，运行期替换一律走 `reloadSaved`。
    pub fn adoptInitial(self: *LibrarySession, initial_library: core.store.Library) void {
        std.debug.assert(self.live_object == null);
        self.library_object.deinit();
        self.library_object.* = initial_library;
    }

    /// 启动顺序要求 Live 可早于或晚于 `App.create` 建立，因此与 init 分开。
    pub fn startLive(self: *LibrarySession, root: []const u8, force_watch: bool) !void {
        std.debug.assert(self.live_object == null);
        const opened_live = try self.allocator.create(live_mod.Live);
        errdefer self.allocator.destroy(opened_live);
        opened_live.* = if (self.read_only)
            try live_mod.Live.initIdle(self.allocator, self.io, self.library_object)
        else
            try live_mod.Live.init(self.allocator, self.io, self.library_object, root, force_watch);
        self.live_object = opened_live;
    }

    pub fn path(self: *const LibrarySession) []const u8 {
        return self.library_path;
    }

    pub fn library(self: *const LibrarySession) *core.store.Library {
        return self.library_object;
    }

    pub fn live(self: *const LibrarySession) *live_mod.Live {
        return self.live_object.?;
    }

    pub fn isReadOnly(self: *const LibrarySession) bool {
        return self.read_only;
    }

    /// 保存只是写候选文件；只有随后的 `reloadSaved` 成功才更新当前路径。
    pub fn save(
        self: *LibrarySession,
        save_path: []const u8,
        saved_library: *const core.store.Library,
    ) !usize {
        if (self.read_only) return error.ReadOnly;
        return library_io.saveWith(self.io, self.allocator, save_path, saved_library);
    }

    /// 完整加载刚保存的库并重建 Live，全部成功才替换当前对象与路径。
    /// root / watchForced 来自旧 Live；失败时旧指针、旧路径和旧视图原样可用。
    pub fn reloadSaved(self: *LibrarySession, save_path: []const u8) !void {
        if (self.read_only) return error.ReadOnly;
        const old_live = self.live_object orelse return error.LiveNotReady;
        const old_library = self.library_object;

        // 路径也属于本次事务：先复制，避免交换成功后才发现内存不足。
        const next_path = try self.allocator.dupe(u8, save_path);
        errdefer self.allocator.free(next_path);
        // Live 拥有 root；必须在旧 Live 销毁前为候选视图复制。
        const root = try self.allocator.dupe(u8, old_live.root);
        defer self.allocator.free(root);

        const next_library = try self.allocator.create(core.store.Library);
        errdefer self.allocator.destroy(next_library);
        next_library.* = try library_io.loadWith(self.io, self.allocator, save_path);
        errdefer next_library.deinit();

        const next_live = try self.allocator.create(live_mod.Live);
        errdefer self.allocator.destroy(next_live);
        next_live.* = try live_mod.Live.init(
            self.allocator,
            self.io,
            next_library,
            root,
            old_live.watchForced(),
        );
        errdefer next_live.deinit();

        // 此后没有失败点。旧 Live 先于它借用的旧 Library 释放，且只走这一次。
        self.destroyPair(old_live, old_library);
        self.live_object = next_live;
        self.library_object = next_library;
        self.allocator.free(self.library_path);
        self.library_path = next_path;
    }

    fn destroyPair(
        self: *LibrarySession,
        old_live: *live_mod.Live,
        old_library: *core.store.Library,
    ) void {
        old_live.deinit();
        self.allocator.destroy(old_live);
        old_library.deinit();
        self.allocator.destroy(old_library);
    }
};
