const std = @import("std");
const bounded_int = @import("bounded_int.zig");
const digest = @import("digest.zig");
const domain = @import("domain.zig");
const results = @import("agent_memory_results.zig");

pub const Message = results.Message;
pub const SessionInfo = results.SessionInfo;
pub const HistoryList = results.HistoryList;
pub const HistoryShow = results.HistoryShow;

const SessionInfoIndexMap = std.StringHashMap(usize);
const session_info_index_merge_threshold: usize = 256;

const SessionPageWindow = struct {
    start: usize,
    len: usize,
    end: usize,
};

pub fn scope(allocator: std.mem.Allocator, session_id: ?[]const u8) ![]u8 {
    if (session_id) |sid| return std.fmt.allocPrint(allocator, "session:{s}", .{sid});
    return allocator.dupe(u8, "session:*");
}

pub fn permissionsJson(allocator: std.mem.Allocator, actor_id: ?[]const u8) ![]u8 {
    if (actor_id) |actor| return domain.actorGrantJson(allocator, actor);
    return allocator.dupe(u8, "[]");
}

pub fn messageObjectId(allocator: std.mem.Allocator, session_id: []const u8, role: []const u8, content: []const u8, created_at_ms: i64, actor_id: ?[]const u8) ![]u8 {
    var ms_buf: [32]u8 = undefined;
    const ms = try std.fmt.bufPrint(&ms_buf, "{d}", .{created_at_ms});
    const hex = digest.sha256PartsHex(&.{ session_id, actor_id orelse "", role, content, ms });
    return std.fmt.allocPrint(allocator, "agsm_{s}", .{hex[0..]});
}

pub fn messageSetObjectId(allocator: std.mem.Allocator, session_id: []const u8, actor_id: ?[]const u8) ![]u8 {
    const hex = digest.sha256PartsHex(&.{ session_id, actor_id orelse "" });
    return std.fmt.allocPrint(allocator, "agsm_clear_{s}", .{hex[0..]});
}

pub fn autosaveSetObjectId(allocator: std.mem.Allocator, session_id: ?[]const u8, actor_id: ?[]const u8) ![]u8 {
    const hex = digest.sha256PartsHex(&.{ session_id orelse "*", actor_id orelse "" });
    return std.fmt.allocPrint(allocator, "agsm_autosave_clear_{s}", .{hex[0..]});
}

pub fn usageObjectId(allocator: std.mem.Allocator, session_id: []const u8, actor_id: ?[]const u8) ![]u8 {
    const hex = digest.sha256PartsHex(&.{ session_id, actor_id orelse "" });
    return std.fmt.allocPrint(allocator, "agsu_{s}", .{hex[0..]});
}

pub fn appendMessageSlice(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(Message), entries: []Message) !void {
    for (entries) |entry| try out.append(allocator, entry);
}

pub fn appendMissingMessageSlice(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(Message), entries: []Message) !void {
    for (entries) |entry| {
        if (messageSliceContains(out.items, entry)) {
            var skipped = entry;
            freeMessageOwned(allocator, &skipped);
            continue;
        }
        try out.append(allocator, entry);
    }
}

fn messageSliceContains(entries: []const Message, needle: Message) bool {
    for (entries) |entry| {
        if (!std.mem.eql(u8, entry.role, needle.role)) continue;
        if (!std.mem.eql(u8, entry.content, needle.content)) continue;
        if (entry.created_at_ms != needle.created_at_ms) continue;
        return true;
    }
    return false;
}

pub const sortMessages = results.sortMessages;

pub fn historyFromOwnedMessages(allocator: std.mem.Allocator, messages: []Message, limit: usize, offset: usize) !HistoryShow {
    errdefer {
        for (messages) |*message| freeMessageOwned(allocator, message);
        allocator.free(messages);
    }

    var visible_total: usize = 0;
    for (messages) |message| {
        if (domain.sessionMessageVisibleInHistory(message.role)) visible_total += 1;
    }

    const window = sessionPageWindow(visible_total, limit, offset);
    var page = try allocator.alloc(Message, window.len);
    var page_initialized: usize = 0;
    errdefer {
        for (page[0..page_initialized]) |*message| freeMessageOwned(allocator, message);
        allocator.free(page);
    }

    var visible_index: usize = 0;
    for (messages) |*message| {
        if (!domain.sessionMessageVisibleInHistory(message.role)) {
            freeMessageOwned(allocator, message);
            continue;
        }
        defer visible_index += 1;
        if (visible_index >= window.start and visible_index < window.end) {
            page[page_initialized] = message.*;
            page_initialized += 1;
            detachMessageOwned(message);
        } else {
            freeMessageOwned(allocator, message);
        }
    }
    allocator.free(messages);
    return .{ .total = bounded_int.usizeToU64Saturating(visible_total), .messages = page };
}

pub fn detachMessageOwned(message: *Message) void {
    message.role = "";
    message.content = "";
    message.created_at_ms = 0;
}

pub fn freeMessageOwned(allocator: std.mem.Allocator, message: *Message) void {
    if (message.role.len > 0) allocator.free(message.role);
    if (message.content.len > 0) allocator.free(message.content);
    detachMessageOwned(message);
}

pub fn routeFanInPageSize() usize {
    return 1000;
}

pub const FanInStats = struct {
    non_empty_routes: usize = 0,
    total_sum: u64 = 0,
    all_fetched: bool = true,

    pub fn observe(self: *FanInStats, total: u64, fetched: usize) void {
        if (total == 0) return;
        self.non_empty_routes = bounded_int.saturatingUsizeAdd(self.non_empty_routes, 1);
        self.total_sum = bounded_int.saturatingU64Add(self.total_sum, total);
        if (bounded_int.usizeToU64Saturating(fetched) < total) self.all_fetched = false;
    }
};

pub fn fanInCandidateLimit(limit: usize, offset: usize) usize {
    return bounded_int.saturatingUsizeAdd(offset, limit);
}

pub fn fanInOffsetAfterFetch(offset: usize, fetched: usize) ?usize {
    if (fetched == 0) return null;
    const next = bounded_int.saturatingUsizeAdd(offset, fetched);
    if (next == offset) return null;
    return next;
}

pub fn fanInOffsetReachedTotal(offset: usize, total: u64) bool {
    return bounded_int.usizeToU64Saturating(offset) >= total;
}

fn sessionInfoMergedCount(out_len: usize, entries_len: usize) usize {
    return bounded_int.saturatingUsizeAdd(out_len, entries_len);
}

fn shouldIndexSessionInfoMerge(out_len: usize, entries_len: usize) bool {
    return sessionInfoMergedCount(out_len, entries_len) >= session_info_index_merge_threshold;
}

fn sessionInfoIndexCapacity(out_len: usize, entries_len: usize) SessionInfoIndexMap.Size {
    const count = sessionInfoMergedCount(out_len, entries_len);
    const max_capacity: usize = std.math.maxInt(SessionInfoIndexMap.Size);
    return @intCast(@min(count, max_capacity));
}

pub fn takeSessionInfoPage(allocator: std.mem.Allocator, entries: *std.ArrayListUnmanaged(SessionInfo), limit: usize, offset: usize) !HistoryList {
    return takeSessionInfoPageWithTotal(allocator, entries, limit, offset, bounded_int.usizeToU64Saturating(entries.items.len));
}

pub fn takeSessionInfoPageWithTotal(allocator: std.mem.Allocator, entries: *std.ArrayListUnmanaged(SessionInfo), limit: usize, offset: usize, total: u64) !HistoryList {
    sortSessionsInfo(entries.items);

    const window = sessionPageWindow(entries.items.len, limit, offset);
    var page = try allocator.alloc(SessionInfo, window.len);
    var page_initialized: usize = 0;
    errdefer {
        for (page[0..page_initialized]) |*session| freeSessionInfoOwned(allocator, session);
        allocator.free(page);
    }
    for (entries.items, 0..) |*session, i| {
        if (i >= window.start and i < window.end) {
            page[page_initialized] = session.*;
            page_initialized += 1;
            detachSessionInfoOwned(session);
        } else {
            freeSessionInfoOwned(allocator, session);
        }
    }
    entries.deinit(allocator);
    return .{ .total = total, .sessions = page };
}

fn sessionPageWindow(total: usize, limit: usize, offset: usize) SessionPageWindow {
    const start = @min(offset, total);
    const len = @min(limit, total - start);
    return .{
        .start = start,
        .len = len,
        .end = bounded_int.saturatingUsizeAdd(start, len),
    };
}

pub fn appendOrMergeSessionInfoSlice(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(SessionInfo), entries: []SessionInfo) !void {
    if (shouldIndexSessionInfoMerge(out.items.len, entries.len)) return appendOrMergeSessionInfoSliceIndexed(allocator, out, entries);
    for (entries) |*entry| {
        if (sessionInfoIndex(out.items, entry.session_id)) |idx| {
            mergeSessionInfoInto(allocator, &out.items[idx], entry);
            continue;
        }
        try out.append(allocator, entry.*);
        detachSessionInfoOwned(entry);
    }
}

fn appendOrMergeSessionInfoSliceIndexed(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(SessionInfo), entries: []SessionInfo) !void {
    var index = SessionInfoIndexMap.init(allocator);
    defer index.deinit();
    try index.ensureTotalCapacity(sessionInfoIndexCapacity(out.items.len, entries.len));
    for (out.items, 0..) |entry, idx| try index.put(entry.session_id, idx);
    for (entries) |*entry| {
        if (index.get(entry.session_id)) |idx| {
            mergeSessionInfoInto(allocator, &out.items[idx], entry);
            continue;
        }
        const idx = out.items.len;
        try out.append(allocator, entry.*);
        const session_id = out.items[idx].session_id;
        detachSessionInfoOwned(entry);
        try index.put(session_id, idx);
    }
}

fn mergeSessionInfoInto(allocator: std.mem.Allocator, current: *SessionInfo, incoming: *SessionInfo) void {
    current.message_count = @max(current.message_count, incoming.message_count);
    current.first_message_at = if (current.first_message_at == 0) incoming.first_message_at else if (incoming.first_message_at == 0) current.first_message_at else @min(current.first_message_at, incoming.first_message_at);
    current.last_message_at = @max(current.last_message_at, incoming.last_message_at);
    freeSessionInfoOwned(allocator, incoming);
}

fn sessionInfoIndex(entries: []const SessionInfo, session_id: []const u8) ?usize {
    for (entries, 0..) |entry, idx| {
        if (std.mem.eql(u8, entry.session_id, session_id)) return idx;
    }
    return null;
}

pub fn sortSessionsInfo(entries: []SessionInfo) void {
    std.mem.sort(SessionInfo, entries, {}, struct {
        fn lessThan(_: void, a: SessionInfo, b: SessionInfo) bool {
            return a.last_message_at > b.last_message_at;
        }
    }.lessThan);
}

pub fn detachSessionInfoOwned(info: *SessionInfo) void {
    info.session_id = "";
    info.message_count = 0;
    info.first_message_at = 0;
    info.last_message_at = 0;
}

pub fn freeSessionInfoOwned(allocator: std.mem.Allocator, info: *SessionInfo) void {
    if (info.session_id.len > 0) allocator.free(info.session_id);
    detachSessionInfoOwned(info);
}

fn exerciseSessionInfoMergeAllocationFailure(allocator: std.mem.Allocator) !void {
    var out: std.ArrayListUnmanaged(SessionInfo) = .empty;
    errdefer {
        for (out.items) |*session| freeSessionInfoOwned(allocator, session);
        out.deinit(allocator);
    }

    const entry_count: usize = 260;
    var entries = try allocator.alloc(SessionInfo, entry_count);
    errdefer allocator.free(entries);
    var entries_initialized: usize = 0;
    errdefer {
        for (entries[0..entries_initialized]) |*session| freeSessionInfoOwned(allocator, session);
    }

    for (0..entry_count) |i| {
        const session_id = try std.fmt.allocPrint(allocator, "fan-in-session-{d}", .{i % 130});
        entries[i] = .{
            .session_id = session_id,
            .message_count = @intCast(i + 1),
            .first_message_at = @intCast(i + 1),
            .last_message_at = @intCast(i + 1000),
        };
        entries_initialized += 1;
    }

    try appendOrMergeSessionInfoSlice(allocator, &out, entries);
    for (entries) |entry| try std.testing.expectEqual(@as(usize, 0), entry.session_id.len);

    for (out.items) |*session| freeSessionInfoOwned(allocator, session);
    out.deinit(allocator);
    allocator.free(entries);
}

test "store session feed object ids use stable sha256 digests" {
    const allocator = std.testing.allocator;
    const msg = try messageObjectId(allocator, "session-a", "assistant", "hello", 42, "agent:one");
    defer allocator.free(msg);
    const clear = try messageSetObjectId(allocator, "session-a", "agent:one");
    defer allocator.free(clear);
    const autosave = try autosaveSetObjectId(allocator, "session-a", "agent:one");
    defer allocator.free(autosave);
    const usage = try usageObjectId(allocator, "session-a", "agent:one");
    defer allocator.free(usage);

    try std.testing.expect(std.mem.startsWith(u8, msg, "agsm_"));
    try std.testing.expectEqual(@as(usize, "agsm_".len + 64), msg.len);
    try std.testing.expectEqual(@as(usize, "agsm_clear_".len + 64), clear.len);
    try std.testing.expectEqual(@as(usize, "agsm_autosave_clear_".len + 64), autosave.len);
    try std.testing.expectEqual(@as(usize, "agsu_".len + 64), usage.len);
}

test "store session fan-in sizing is overflow-safe" {
    const first_page = sessionPageWindow(10, 4, 0);
    try std.testing.expectEqual(@as(usize, 0), first_page.start);
    try std.testing.expectEqual(@as(usize, 4), first_page.len);
    try std.testing.expectEqual(@as(usize, 4), first_page.end);

    const tail_page = sessionPageWindow(10, 4, 8);
    try std.testing.expectEqual(@as(usize, 8), tail_page.start);
    try std.testing.expectEqual(@as(usize, 2), tail_page.len);
    try std.testing.expectEqual(@as(usize, 10), tail_page.end);

    const empty_page = sessionPageWindow(10, 4, 12);
    try std.testing.expectEqual(@as(usize, 10), empty_page.start);
    try std.testing.expectEqual(@as(usize, 0), empty_page.len);
    try std.testing.expectEqual(@as(usize, 10), empty_page.end);

    const zero_limit = sessionPageWindow(10, 0, 3);
    try std.testing.expectEqual(@as(usize, 3), zero_limit.start);
    try std.testing.expectEqual(@as(usize, 0), zero_limit.len);
    try std.testing.expectEqual(@as(usize, 3), zero_limit.end);

    const max_window = sessionPageWindow(std.math.maxInt(usize), std.math.maxInt(usize), std.math.maxInt(usize) - 1);
    try std.testing.expectEqual(std.math.maxInt(usize) - 1, max_window.start);
    try std.testing.expectEqual(@as(usize, 1), max_window.len);
    try std.testing.expectEqual(std.math.maxInt(usize), max_window.end);

    try std.testing.expectEqual(@as(usize, 30), fanInCandidateLimit(10, 20));
    try std.testing.expectEqual(std.math.maxInt(usize), fanInCandidateLimit(1, std.math.maxInt(usize)));
    try std.testing.expectEqual(@as(?usize, 30), fanInOffsetAfterFetch(20, 10));
    try std.testing.expectEqual(@as(?usize, null), fanInOffsetAfterFetch(20, 0));
    try std.testing.expectEqual(@as(?usize, std.math.maxInt(usize)), fanInOffsetAfterFetch(std.math.maxInt(usize) - 1, 4));
    try std.testing.expectEqual(@as(?usize, null), fanInOffsetAfterFetch(std.math.maxInt(usize), 1));
    try std.testing.expect(!fanInOffsetReachedTotal(19, 20));
    try std.testing.expect(fanInOffsetReachedTotal(20, 20));
    try std.testing.expect(fanInOffsetReachedTotal(std.math.maxInt(usize), std.math.maxInt(u64)));

    var stats: FanInStats = .{};
    stats.observe(10, 10);
    try std.testing.expectEqual(@as(usize, 1), stats.non_empty_routes);
    try std.testing.expectEqual(@as(u64, 10), stats.total_sum);
    try std.testing.expect(stats.all_fetched);
    stats.observe(std.math.maxInt(u64), 0);
    try std.testing.expectEqual(@as(usize, 2), stats.non_empty_routes);
    try std.testing.expectEqual(std.math.maxInt(u64), stats.total_sum);
    try std.testing.expect(!stats.all_fetched);
    stats.non_empty_routes = std.math.maxInt(usize);
    stats.observe(1, 1);
    try std.testing.expectEqual(std.math.maxInt(usize), stats.non_empty_routes);

    try std.testing.expect(!shouldIndexSessionInfoMerge(100, 155));
    try std.testing.expect(shouldIndexSessionInfoMerge(100, 156));
    try std.testing.expect(shouldIndexSessionInfoMerge(std.math.maxInt(usize), 1));

    try std.testing.expectEqual(std.math.maxInt(SessionInfoIndexMap.Size), sessionInfoIndexCapacity(std.math.maxInt(usize), 1));
}

test "store session fan-in merge owns entries safely under allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseSessionInfoMergeAllocationFailure, .{});
}
