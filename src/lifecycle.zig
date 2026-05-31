const std = @import("std");
const domain = @import("domain.zig");
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

pub const RolloutMode = enum {
    off,
    shadow,
    canary,
    on,

    pub fn parse(value: ?[]const u8, has_percent: bool) RolloutMode {
        const raw = value orelse return if (has_percent) .canary else .off;
        if (std.ascii.eqlIgnoreCase(raw, "off")) return .off;
        if (std.ascii.eqlIgnoreCase(raw, "shadow")) return .shadow;
        if (std.ascii.eqlIgnoreCase(raw, "canary")) return .canary;
        if (std.ascii.eqlIgnoreCase(raw, "on")) return .on;
        return .off;
    }

    pub fn name(self: RolloutMode) []const u8 {
        return @tagName(self);
    }
};

pub const RolloutDecision = enum {
    disabled,
    enabled,
    shadow,

    pub fn name(self: RolloutDecision) []const u8 {
        return @tagName(self);
    }
};

pub const RolloutPolicy = struct {
    mode: RolloutMode = .off,
    percent: u8 = 0,
    shadow_percent: u8 = 100,
    salt: []const u8 = "",
    disabled: bool = false,
    required_scopes_json: []const u8 = "[]",
    blocked_scopes_json: []const u8 = "[]",
    target_scopes_json: []const u8 = "[]",
    required_capabilities_json: []const u8 = "[]",
    blocked_capabilities_json: []const u8 = "[]",
};

pub const RolloutSubject = struct {
    key: []const u8,
    actor_id: []const u8,
    session_id: ?[]const u8 = null,
    actor_scopes_json: []const u8 = "[]",
    actor_capabilities_json: []const u8 = "[]",
};

pub const RolloutResult = struct {
    decision: RolloutDecision,
    enabled: bool,
    shadow: bool,
    mode: RolloutMode,
    percent: u8,
    shadow_percent: u8,
    bucket: u8,
    reason: []const u8,
};

pub fn evaluateRollout(policy: RolloutPolicy, subject: RolloutSubject) RolloutResult {
    const bucket = rolloutBucket(policy, subject);
    if (policy.disabled) return rolloutResult(.disabled, policy, bucket, "disabled");
    if (!allRequiredScopesVisible(policy.required_scopes_json, subject.actor_scopes_json)) return rolloutResult(.disabled, policy, bucket, "missing_required_scope");
    if (!allRequiredScopesVisible(policy.target_scopes_json, subject.actor_scopes_json)) return rolloutResult(.disabled, policy, bucket, "target_scope_not_visible");
    if (anyBlockedScopeGranted(policy.blocked_scopes_json, subject.actor_scopes_json)) return rolloutResult(.disabled, policy, bucket, "blocked_scope");
    if (!allRequiredCapabilitiesPresent(policy.required_capabilities_json, subject.actor_scopes_json, subject.actor_capabilities_json)) return rolloutResult(.disabled, policy, bucket, "missing_required_capability");
    if (anyBlockedCapabilityPresent(policy.blocked_capabilities_json, subject.actor_capabilities_json)) return rolloutResult(.disabled, policy, bucket, "blocked_capability");

    return switch (policy.mode) {
        .off => rolloutResult(.disabled, policy, bucket, "mode_off"),
        .on => rolloutResult(.enabled, policy, bucket, "mode_on"),
        .canary => if (bucket < policy.percent)
            rolloutResult(.enabled, policy, bucket, "canary_hit")
        else
            rolloutResult(.disabled, policy, bucket, "canary_miss"),
        .shadow => if (bucket < policy.shadow_percent)
            rolloutResult(.shadow, policy, bucket, "shadow_hit")
        else
            rolloutResult(.disabled, policy, bucket, "shadow_miss"),
    };
}

fn rolloutResult(decision: RolloutDecision, policy: RolloutPolicy, bucket: u8, reason: []const u8) RolloutResult {
    return .{
        .decision = decision,
        .enabled = decision == .enabled,
        .shadow = decision == .shadow,
        .mode = policy.mode,
        .percent = policy.percent,
        .shadow_percent = policy.shadow_percent,
        .bucket = bucket,
        .reason = reason,
    };
}

fn rolloutBucket(policy: RolloutPolicy, subject: RolloutSubject) u8 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(policy.salt);
    hasher.update("\x1f");
    hasher.update(subject.key);
    hasher.update("\x1f");
    hasher.update(subject.actor_id);
    hasher.update("\x1f");
    if (subject.session_id) |session_id| hasher.update(session_id);
    return @intCast(hasher.final() % 100);
}

fn allRequiredScopesVisible(required_scopes_json: []const u8, actor_scopes_json: []const u8) bool {
    var cursor: usize = 0;
    var saw_scope = false;
    while (nextQuotedString(required_scopes_json, &cursor)) |scope| {
        saw_scope = true;
        if (!domain.scopeVisible(scope, actor_scopes_json)) return false;
    }
    return saw_scope or jsonStringListEmpty(required_scopes_json);
}

fn anyBlockedScopeGranted(blocked_scopes_json: []const u8, actor_scopes_json: []const u8) bool {
    var cursor: usize = 0;
    while (nextQuotedString(blocked_scopes_json, &cursor)) |blocked| {
        if (std.mem.eql(u8, blocked, "public")) return true;
        if (actorScopeGrants(actor_scopes_json, blocked)) return true;
    }
    return false;
}

fn allRequiredCapabilitiesPresent(required_capabilities_json: []const u8, actor_scopes_json: []const u8, actor_capabilities_json: []const u8) bool {
    var cursor: usize = 0;
    while (nextQuotedString(required_capabilities_json, &cursor)) |capability| {
        if (!domain.hasCapability(actor_scopes_json, actor_capabilities_json, capability)) return false;
    }
    return true;
}

fn anyBlockedCapabilityPresent(blocked_capabilities_json: []const u8, actor_capabilities_json: []const u8) bool {
    var cursor: usize = 0;
    while (nextQuotedString(blocked_capabilities_json, &cursor)) |capability| {
        if (jsonContainsExact(actor_capabilities_json, capability)) return true;
    }
    return false;
}

fn actorScopeGrants(actor_scopes_json: []const u8, scope: []const u8) bool {
    var cursor: usize = 0;
    while (nextQuotedString(actor_scopes_json, &cursor)) |actor_scope| {
        if (std.mem.eql(u8, actor_scope, scope)) return true;
        if (actor_scope.len > 0 and actor_scope[actor_scope.len - 1] == '*') {
            const prefix = actor_scope[0 .. actor_scope.len - 1];
            if (std.mem.startsWith(u8, scope, prefix)) return true;
        }
    }
    return false;
}

fn jsonContainsExact(list_json: []const u8, needle: []const u8) bool {
    var cursor: usize = 0;
    while (nextQuotedString(list_json, &cursor)) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

fn jsonStringListEmpty(list_json: []const u8) bool {
    var cursor: usize = 0;
    return nextQuotedString(list_json, &cursor) == null;
}

fn nextQuotedString(list_json: []const u8, cursor: *usize) ?[]const u8 {
    while (cursor.* < list_json.len and list_json[cursor.*] != '"') : (cursor.* += 1) {}
    if (cursor.* >= list_json.len) return null;
    const start = cursor.* + 1;
    cursor.* = start;
    while (cursor.* < list_json.len) : (cursor.* += 1) {
        if (list_json[cursor.*] == '\\') {
            cursor.* += 1;
            continue;
        }
        if (list_json[cursor.*] == '"') {
            const value = list_json[start..cursor.*];
            cursor.* += 1;
            return value;
        }
    }
    return null;
}

pub const Diagnostics = struct {
    total_memory_atoms: usize,
    stale_memory_atoms: usize,
    vector_outbox_pending: usize,
    lucid_projection_pending: usize = 0,
    lucid_projection_failed: usize = 0,
    cache_entries: usize,
    queued_jobs: usize = 0,
    running_jobs: usize = 0,
    failed_jobs: usize = 0,
    pending_feed_events: usize = 0,
    open_conflicts: usize = 0,
    agent_memories: usize = 0,
    sessions: usize = 0,

    pub fn health(self: Diagnostics) []const u8 {
        if (self.failed_jobs > 0) return "degraded";
        if (self.lucid_projection_failed > 0) return "degraded";
        if (self.vector_outbox_pending > 1000) return "degraded";
        if (self.lucid_projection_pending > 1000) return "degraded";
        if (self.queued_jobs > 1000 or self.pending_feed_events > 1000) return "degraded";
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

test "lifecycle rollout policy supports nullclaw modes" {
    const subject = RolloutSubject{ .key = "feature:hybrid", .actor_id = "agent:a", .session_id = "s1", .actor_scopes_json = "[\"public\"]", .actor_capabilities_json = "[\"read\"]" };

    try std.testing.expectEqual(RolloutDecision.disabled, evaluateRollout(.{ .mode = .off, .percent = 100 }, subject).decision);
    try std.testing.expectEqual(RolloutDecision.enabled, evaluateRollout(.{ .mode = .on }, subject).decision);
    try std.testing.expectEqual(RolloutDecision.shadow, evaluateRollout(.{ .mode = .shadow, .shadow_percent = 100 }, subject).decision);
    try std.testing.expectEqual(RolloutDecision.disabled, evaluateRollout(.{ .mode = .canary, .percent = 0 }, subject).decision);
    try std.testing.expectEqual(RolloutDecision.enabled, evaluateRollout(.{ .mode = .canary, .percent = 100 }, subject).decision);
}

test "lifecycle rollout policy is deterministic per actor session and salt" {
    const subject = RolloutSubject{ .key = "feature:rag", .actor_id = "agent:a", .session_id = "session:1", .actor_scopes_json = "[\"public\"]", .actor_capabilities_json = "[\"read\"]" };
    const policy = RolloutPolicy{ .mode = .canary, .percent = 50, .salt = "rollout:v1" };
    const first = evaluateRollout(policy, subject);
    for (0..32) |_| {
        const next = evaluateRollout(policy, subject);
        try std.testing.expectEqual(first.bucket, next.bucket);
        try std.testing.expectEqual(first.decision, next.decision);
    }
}

test "lifecycle rollout policy gates scopes and capabilities" {
    const subject = RolloutSubject{
        .key = "feature:team-memory",
        .actor_id = "agent:a",
        .actor_scopes_json = "[\"project:nullpantry\",\"team:agents\"]",
        .actor_capabilities_json = "[\"read\",\"write\"]",
    };

    try std.testing.expectEqual(
        RolloutDecision.enabled,
        evaluateRollout(.{ .mode = .on, .required_scopes_json = "[\"project:nullpantry\"]", .required_capabilities_json = "[\"read\"]" }, subject).decision,
    );
    const missing_scope = evaluateRollout(.{ .mode = .on, .required_scopes_json = "[\"project:secret\"]" }, subject);
    try std.testing.expectEqual(RolloutDecision.disabled, missing_scope.decision);
    try std.testing.expectEqualStrings("missing_required_scope", missing_scope.reason);

    const blocked_scope = evaluateRollout(.{ .mode = .on, .blocked_scopes_json = "[\"team:agents\"]" }, subject);
    try std.testing.expectEqual(RolloutDecision.disabled, blocked_scope.decision);
    try std.testing.expectEqualStrings("blocked_scope", blocked_scope.reason);

    const missing_capability = evaluateRollout(.{ .mode = .on, .required_capabilities_json = "[\"export\"]" }, subject);
    try std.testing.expectEqual(RolloutDecision.disabled, missing_capability.decision);
    try std.testing.expectEqualStrings("missing_required_capability", missing_capability.reason);

    const blocked_capability = evaluateRollout(.{ .mode = .on, .blocked_capabilities_json = "[\"write\"]" }, subject);
    try std.testing.expectEqual(RolloutDecision.disabled, blocked_capability.decision);
    try std.testing.expectEqualStrings("blocked_capability", blocked_capability.reason);
}
