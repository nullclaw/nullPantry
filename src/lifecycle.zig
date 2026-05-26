const std = @import("std");
const vector = @import("vector.zig");

pub const HygieneDecision = enum {
    keep,
    mark_stale,
    archive,
    purge,
};

pub const CacheEntry = struct {
    key: []const u8,
    value: []const u8,
    created_at_ms: i64,
    ttl_ms: i64,

    pub fn isFresh(self: CacheEntry, now_ms: i64) bool {
        if (self.ttl_ms <= 0) return true;
        return now_ms <= self.created_at_ms + self.ttl_ms;
    }
};

pub const SemanticCacheEntry = struct {
    key: []const u8,
    value: []const u8,
    embedding: []const f32,
    created_at_ms: i64,
    ttl_ms: i64,
};

pub fn semanticCacheHit(query_embedding: []const f32, entries: []const SemanticCacheEntry, now_ms: i64, min_score: f32) ?usize {
    var best_idx: ?usize = null;
    var best_score: f32 = min_score;
    for (entries, 0..) |entry, i| {
        const cache_entry = CacheEntry{ .key = entry.key, .value = entry.value, .created_at_ms = entry.created_at_ms, .ttl_ms = entry.ttl_ms };
        if (!cache_entry.isFresh(now_ms)) continue;
        const score = vector.cosine(query_embedding, entry.embedding);
        if (score >= best_score) {
            best_idx = i;
            best_score = score;
        }
    }
    return best_idx;
}

pub fn hygieneDecision(status: []const u8, last_verified_at_ms: ?i64, now_ms: i64, stale_after_ms: i64, archive_after_ms: i64, purge_after_ms: i64) HygieneDecision {
    if (std.mem.eql(u8, status, "deprecated") or std.mem.eql(u8, status, "rejected")) return .archive;
    const last_seen = last_verified_at_ms orelse now_ms;
    const age = @max(@as(i64, 0), now_ms - last_seen);
    if (purge_after_ms > 0 and age >= purge_after_ms) return .purge;
    if (archive_after_ms > 0 and age >= archive_after_ms) return .archive;
    if (stale_after_ms > 0 and age >= stale_after_ms) return .mark_stale;
    return .keep;
}

pub fn summarizeMessages(allocator: std.mem.Allocator, messages: []const []const u8, max_chars: usize) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    for (messages, 0..) |message, i| {
        if (i > 0) try out.appendSlice(allocator, "\n");
        const remaining = if (out.items.len >= max_chars) 0 else max_chars - out.items.len;
        if (remaining == 0) break;
        try out.appendSlice(allocator, message[0..@min(message.len, remaining)]);
    }
    return out.toOwnedSlice(allocator);
}

pub fn snapshotName(allocator: std.mem.Allocator, prefix: []const u8, now_ms: i64) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}-{d}", .{ prefix, now_ms });
}

pub fn rolloutEnabled(key: []const u8, percent: u8) bool {
    if (percent == 0) return false;
    if (percent >= 100) return true;
    const bucket = std.hash.Wyhash.hash(0, key) % 100;
    return bucket < percent;
}

pub const Diagnostics = struct {
    total_memory_atoms: usize,
    stale_memory_atoms: usize,
    vector_outbox_pending: usize,
    cache_entries: usize,

    pub fn health(self: Diagnostics) []const u8 {
        if (self.vector_outbox_pending > 1000) return "degraded";
        if (self.total_memory_atoms > 0 and self.stale_memory_atoms * 2 > self.total_memory_atoms) return "needs_review";
        return "ok";
    }
};

test "lifecycle cache freshness respects ttl" {
    const entry = CacheEntry{ .key = "q", .value = "a", .created_at_ms = 1000, .ttl_ms = 500 };
    try std.testing.expect(entry.isFresh(1200));
    try std.testing.expect(!entry.isFresh(1600));
}

test "lifecycle semantic cache picks close fresh embedding" {
    const entries = [_]SemanticCacheEntry{
        .{ .key = "a", .value = "old", .embedding = &[_]f32{ 1, 0 }, .created_at_ms = 0, .ttl_ms = 10 },
        .{ .key = "b", .value = "fresh", .embedding = &[_]f32{ 1, 0 }, .created_at_ms = 100, .ttl_ms = 1000 },
    };
    const hit = semanticCacheHit(&[_]f32{ 1, 0 }, &entries, 200, 0.8).?;
    try std.testing.expectEqual(@as(usize, 1), hit);
}

test "lifecycle hygiene transitions old memory" {
    const day: i64 = 24 * 60 * 60 * 1000;
    try std.testing.expectEqual(HygieneDecision.mark_stale, hygieneDecision("verified", 0, 8 * day, 7 * day, 30 * day, 90 * day));
    try std.testing.expectEqual(HygieneDecision.archive, hygieneDecision("deprecated", 0, 1, 7 * day, 30 * day, 90 * day));
    try std.testing.expectEqual(HygieneDecision.purge, hygieneDecision("verified", 0, 100 * day, 7 * day, 30 * day, 90 * day));
}

test "lifecycle summarizer truncates deterministically" {
    const messages = [_][]const u8{ "hello", "world" };
    const summary = try summarizeMessages(std.testing.allocator, &messages, 8);
    defer std.testing.allocator.free(summary);
    try std.testing.expectEqualStrings("hello\nwo", summary);
}

test "lifecycle rollout handles boundaries" {
    try std.testing.expect(!rolloutEnabled("agent:a", 0));
    try std.testing.expect(rolloutEnabled("agent:a", 100));
}
