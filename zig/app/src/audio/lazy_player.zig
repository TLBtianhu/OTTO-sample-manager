//! 按需建立 `Player`：打开预览只交付 PCM/波形，第一次播放才碰 WASAPI。
//!
//! UI 用 `startAsync` + `collect(false)`，创建期间可以画出“正在启动音频…”；
//! `--play-test` 用 `createSync`，`NoAudioEndpoint` 等具名错误仍同步上抛。
//! `Starter` 在堆上保持稳定地址；会话销毁时即使创建尚未结束，也会 join 并释放结果。

const std = @import("std");
const player = @import("player.zig");

/// 反向证明开关。改为 false：普通预览在 build、渐进预览在 finish 恢复建 Player。
pub const enabled = true;

pub const CreateFn = *const fn (
    std.mem.Allocator,
    []const u8,
    u32,
    u16,
    u16,
    bool,
) player.Error!*player.Player;

pub const State = enum(u8) { idle, starting, ready, failed };

pub const Lazy = struct {
    allocator: ?std.mem.Allocator = null,
    factory: CreateFn = player.Player.create,
    state: State = .idle,
    failure: ?player.Error = null,
    starter: ?*Starter = null,
    cancelled: bool = false,

    pub fn createSync(
        self: *Lazy,
        pcm: []const u8,
        sample_rate: u32,
        channels: u16,
        bits: u16,
        float: bool,
    ) player.Error!*player.Player {
        const allocator = self.allocator orelse return error.OutOfMemory;
        self.state = .starting;
        self.failure = null;
        self.cancelled = false;
        const created = self.factory(allocator, pcm, sample_rate, channels, bits, float) catch |err| {
            self.fail(err);
            return err;
        };
        self.state = .ready;
        return created;
    }

    pub fn startAsync(
        self: *Lazy,
        pcm: []const u8,
        sample_rate: u32,
        channels: u16,
        bits: u16,
        float: bool,
    ) player.Error!void {
        if (self.starter != null) {
            self.cancelled = false;
            return;
        }
        const allocator = self.allocator orelse return error.OutOfMemory;
        self.state = .starting;
        self.failure = null;
        self.cancelled = false;
        self.starter = Starter.start(
            allocator,
            self.factory,
            pcm,
            sample_rate,
            channels,
            bits,
            float,
        ) catch |err| {
            self.fail(err);
            return err;
        };
    }

    /// 非阻塞返回 null = 尚未完成；阻塞模式用于同步 play 与异步启动重叠的边界。
    /// 返回错误前已销毁 Starter；成功时 Player 所有权转给调用方。
    pub fn collect(self: *Lazy, block: bool) player.Error!?*player.Player {
        const starter = self.starter orelse return null;
        if (!block and !starter.done.load(.acquire)) return null;
        self.starter = null;
        return starter.finish(block) catch |err| {
            self.fail(err);
            return err;
        };
    }

    pub fn fail(self: *Lazy, err: player.Error) void {
        self.state = .failed;
        self.failure = err;
    }

    pub fn ready(self: *Lazy) void {
        self.state = .ready;
        self.failure = null;
        self.cancelled = false;
    }

    pub fn deinit(self: *Lazy) void {
        if (self.starter) |starter| starter.deinit();
        self.starter = null;
        self.state = .idle;
        self.failure = null;
        self.cancelled = false;
    }
};

const Starter = struct {
    allocator: std.mem.Allocator,
    factory: CreateFn,
    pcm: []const u8,
    sample_rate: u32,
    channels: u16,
    bits: u16,
    float: bool,
    thread: std.Thread = undefined,
    done: std.atomic.Value(bool) = .init(false),
    created: ?*player.Player = null,
    failure: ?player.Error = null,

    fn start(
        allocator: std.mem.Allocator,
        factory: CreateFn,
        pcm: []const u8,
        sample_rate: u32,
        channels: u16,
        bits: u16,
        float: bool,
    ) player.Error!*Starter {
        const self = try allocator.create(Starter);
        self.* = .{
            .allocator = allocator,
            .factory = factory,
            .pcm = pcm,
            .sample_rate = sample_rate,
            .channels = channels,
            .bits = bits,
            .float = float,
        };
        self.thread = std.Thread.spawn(.{}, threadMain, .{self}) catch {
            allocator.destroy(self);
            return error.ThreadFailure;
        };
        return self;
    }

    fn threadMain(self: *Starter) void {
        const created = self.factory(
            self.allocator,
            self.pcm,
            self.sample_rate,
            self.channels,
            self.bits,
            self.float,
        ) catch |err| {
            self.failure = err;
            self.done.store(true, .release);
            return;
        };
        self.created = created;
        self.done.store(true, .release);
    }

    /// 回收线程与 Starter 本身。只有完成/ join 之后才读 worker 写的两个结果字段。
    fn finish(self: *Starter, block: bool) player.Error!?*player.Player {
        if (block) {
            self.thread.join();
        } else {
            std.debug.assert(self.done.load(.acquire));
            self.thread.join();
        }
        const allocator = self.allocator;
        const failure = self.failure;
        const created = self.created;
        allocator.destroy(self);
        if (failure) |err| return err;
        return created;
    }

    fn deinit(self: *Starter) void {
        self.thread.join();
        if (self.created) |created| created.deinit();
        self.allocator.destroy(self);
    }
};
