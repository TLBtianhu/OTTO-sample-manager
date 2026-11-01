//! 浏览模式的**监听事件泵 + 重扫调和**：从 `browse.zig` 拆出来，因为它是一段
//! 独立的时序协议，而不是"行维护"。
//!
//! 协议（缺口的修法）：
//!   1. 监听队列的每条事件带单调序号（`watch.Event.seq`）。风暴 / 内核溢出 /
//!      序号缺口都走同一条路：记下**取走事件的最大序号** `rescan_seq`，然后请求
//!      一次全量重枚举（epoch+1）；
//!   2. 重扫在飞期间**不消费**监听队列——消费了就丢了。事件留在队列里（容量 513），
//!      数量超过容量时队列会丢最旧的事件，但序号缺口会在第 4 步暴露出来；
//!   3. 重扫的 `done` 到了之后，把队列里的事件全部补应用（reconcile-after-rescan）；
//!      重复的 created 由 `browse_events` 的去重表/路径查找吸收；
//!   4. replay 期间又看到 overflow 或序号缺口：**只合并成一次**后续重扫
//!      （`reconcile_again` 是 bool，不是计数），不按事件条数递归放大；
//!   5. 监听线程硬错误（目录被删 / U 盘拔出）→ `unavailable=true` 并关掉监听；
//!      恢复只在 `Session.retryUnavailable`（用户下一次交互）里发生。
//!
//! 不做定时轮询：这里只有 `poll` 调用时的一次队列读取与重扫完成后的补读。

const std = @import("std");
const browse = @import("browse.zig");
const events_mod = @import("browse_events.zig");
const types = @import("browse_types.zig");
const watch = @import("otto_watch");

/// 一帧的事件读取 / 重扫调和。
pub fn pump(session: *browse.Session, report: *types.Report) error{OutOfMemory}!void {
    const watcher = session.watcher orelse {
        session.replay_after_rescan = false;
        session.reconciling = false;
        checkRoot(session);
        return;
    };

    if (session.replay_after_rescan) {
        session.replay_after_rescan = false;
        try replayQueued(session, watcher, report);
        return;
    }
    // 重扫在飞：不消费队列（消费了就丢了）；队列满时由序号缺口在 reconcile 里
    // 变成"再来一次重扫"，不静默。
    if (session.reconciling) {
        noteWatcherHealth(session);
        return;
    }

    const n = watcher.poll(session.event_buffer);
    report.events = n;
    session.events_total += n;
    if (n == session.event_buffer.len) {
        // 一帧超过阈值：剩下的直接排空，改成一次全量重枚举。
        var last = session.event_buffer[n - 1].seq;
        while (true) {
            const more = watcher.poll(session.event_buffer);
            if (more == 0) break;
            last = session.event_buffer[more - 1].seq;
        }
        noteWatcherHealth(session);
        startRescan(session, last);
        report.rescanned = true;
        report.changed = true;
        return;
    }

    var overflow = false;
    var gap = false;
    var expected = session.last_event_seq + 1;
    for (session.event_buffer[0..n]) |event| {
        if (event.seq > expected) gap = true;
        if (event.seq > session.last_event_seq) session.last_event_seq = event.seq;
        expected = event.seq + 1;
        if (event.kind == .overflow) {
            overflow = true;
            continue;
        }
        if (try events_mod.apply(session, event, report)) report.changed = true;
    }
    // 内核缓冲区溢出 / 监听队列丢过事件：和风暴同一条路（全量重枚举）。
    if (overflow or gap) {
        startRescan(session, session.last_event_seq);
        report.rescanned = true;
        report.changed = true;
    } else if (n > 0) {
        checkRoot(session);
    }
    noteWatcherHealth(session);
}

/// 重扫完成后：把扫描开始之后到达的事件全部补应用（单调序号，缺口 = 还要再扫）。
fn replayQueued(
    session: *browse.Session,
    watcher: *watch.Watcher,
    report: *types.Report,
) error{OutOfMemory}!void {
    var expected = session.last_event_seq + 1;
    var guard: usize = 0;
    while (true) {
        const n = watcher.poll(session.event_buffer);
        if (n == 0) break;
        report.events += n;
        session.events_total += n;
        for (session.event_buffer[0..n]) |event| {
            if (event.seq > expected) session.reconcile_again = true;
            if (event.seq > session.last_event_seq) session.last_event_seq = event.seq;
            expected = event.seq + 1;
            if (event.kind == .overflow) {
                session.reconcile_again = true;
                continue;
            }
            if (try events_mod.apply(session, event, report)) report.changed = true;
            report.replayed += 1;
        }
        guard += 1;
        if (guard > 64) {
            // 事件多到一帧灌不完：交给一次后续重扫，别在这里无限循环。
            session.reconcile_again = true;
            break;
        }
    }
    session.reconciles += 1;
    // reconcile 期间的 overflow / 缺口：合并成一次后续重扫（不按事件条数递归）。
    if (session.reconcile_again) {
        session.reconcile_again = false;
        startRescan(session, session.last_event_seq);
        report.rescanned = true;
        report.changed = true;
    }
    checkRoot(session);
    noteWatcherHealth(session);
}

/// 目录风暴 / 内核溢出 / 序号缺口：代次 +1、让枚举线程重来，旧行等新批次到了再换。
/// 重扫在飞时再触发只记一个"再来一次"，不递归放大。
pub fn startRescan(session: *browse.Session, last_seq: u64) void {
    if (session.reconciling) {
        session.reconcile_again = true;
        return;
    }
    session.reconciling = true;
    session.reconcile_again = false;
    session.rescan_seq = last_seq;
    session.last_event_seq = @max(session.last_event_seq, last_seq);
    session.swapping = true;
    session.enumerating = true;
    session.loading_more = false;
    session.truncated = false;
    session.has_more = false;
    session.skipped = 0;
    session.remaining = 0;
    session.mem_refused = false;
    session.pages = 0;
    session.restore_pending = session.tracker.state.keys.items.len > 0;
    session.rescans += 1;
    session.source.request();
}

/// 监听线程因硬错误退出了吗？是就保持"路径不可用"，等用户下一次交互重试。
pub fn noteWatcherHealth(session: *browse.Session) void {
    const watcher = session.watcher orelse return;
    if (watcher.lastError() == 0 or watcher.isRunning()) return;
    session.unavailable = true;
    session.closeWatcher();
}

/// 目录还在吗？只在"有事件 / 监听没起来 / 监听报错"时问一次，不做定时轮询。
pub fn checkRoot(session: *browse.Session) void {
    if (session.unavailable) return;
    const stat = std.Io.Dir.cwd().statFile(session.io, session.root, .{}) catch {
        session.unavailable = true;
        return;
    };
    if (stat.kind != .directory) session.unavailable = true;
}
