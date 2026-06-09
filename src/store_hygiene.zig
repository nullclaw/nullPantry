const std = @import("std");
const domain = @import("domain.zig");
const lifecycle_mod = @import("lifecycle.zig");
const store_types = @import("store_types.zig");

pub const RunInput = store_types.HygieneRunInput;

pub const RunResult = struct {
    checked: usize = 0,
    marked_stale: usize = 0,
    archived: usize = 0,
    purged: usize = 0,
    expired_cache_entries: usize = 0,
    dedupe_checked: usize = 0,
    dedupe_groups: usize = 0,
    dedupe_deprecated: usize = 0,
    dedupe_purged: usize = 0,
    agent_memory_dedupe_checked: usize = 0,
    agent_memory_dedupe_groups: usize = 0,
    agent_memory_dedupe_deprecated: usize = 0,
    agent_memory_dedupe_purged: usize = 0,
};

pub const DedupeWinner = struct {
    id: []const u8,
    status: []const u8,
    scope: []const u8,
    permissions_json: []const u8,
    created_at_ms: i64,
    last_verified_at_ms: ?i64,
    seen_duplicate: bool = false,
};

pub const AgentMemoryDedupeWinner = struct {
    item_id: []const u8,
    atom_id: []const u8,
    status: []const u8,
    scope: []const u8,
    permissions_json: []const u8,
    created_at_ms: i64,
    last_verified_at_ms: ?i64,
    seen_duplicate: bool = false,
};

pub const RoutedAgentMemoryDedupeWinner = struct {
    key: []const u8,
    session_id: ?[]const u8,
    actor_id: []const u8,
    store: []const u8,
    status: []const u8,
    scope: []const u8,
    permissions_json: []const u8,
    created_at_ms: i64,
    seen_duplicate: bool = false,
};

pub fn canVerify(input: RunInput, scope: []const u8, permissions_json: []const u8) bool {
    return domain.hasCapability(input.scopes_json, input.capabilities_json, "verify") and
        domain.scopeVerifiable(scope, input.scopes_json) and
        domain.permissionsWritable(permissions_json, input.scopes_json);
}

pub fn canDelete(input: RunInput, scope: []const u8, permissions_json: []const u8) bool {
    return domain.hasCapability(input.scopes_json, input.capabilities_json, "delete") and
        domain.scopeDeletable(scope, input.scopes_json) and
        domain.permissionsWritable(permissions_json, input.scopes_json);
}

pub fn atomDedupeRank(status: []const u8) u8 {
    if (std.mem.eql(u8, status, "verified")) return 4;
    if (std.mem.eql(u8, status, "accepted")) return 4;
    if (std.mem.eql(u8, status, "proposed")) return 3;
    if (std.mem.eql(u8, status, "stale")) return 2;
    return 1;
}

pub fn shouldReplaceWinner(current_status: []const u8, current_created_at_ms: i64, current_last_verified_at_ms: ?i64, winner: DedupeWinner) bool {
    const current_rank = atomDedupeRank(current_status);
    const winner_rank = atomDedupeRank(winner.status);
    if (current_rank != winner_rank) return current_rank > winner_rank;
    const current_seen = current_last_verified_at_ms orelse current_created_at_ms;
    const winner_seen = winner.last_verified_at_ms orelse winner.created_at_ms;
    return current_seen > winner_seen;
}

pub fn shouldReplaceAgentMemoryWinner(current_status: []const u8, current_created_at_ms: i64, current_last_verified_at_ms: ?i64, winner: AgentMemoryDedupeWinner) bool {
    const current_rank = atomDedupeRank(current_status);
    const winner_rank = atomDedupeRank(winner.status);
    if (current_rank != winner_rank) return current_rank > winner_rank;
    const current_seen = current_last_verified_at_ms orelse current_created_at_ms;
    const winner_seen = winner.last_verified_at_ms orelse winner.created_at_ms;
    return current_seen > winner_seen;
}

pub fn canDeprecateAtom(input: RunInput, status: []const u8, scope: []const u8, permissions_json: []const u8) bool {
    if (input.hard_delete) return canDelete(input, scope, permissions_json);
    if (std.mem.eql(u8, status, "deprecated") or std.mem.eql(u8, status, "rejected") or std.mem.eql(u8, status, "superseded")) return false;
    return canVerify(input, scope, permissions_json);
}

pub fn atomDedupeKey(allocator: std.mem.Allocator, scope: []const u8, permissions_json: []const u8, predicate: []const u8, object: []const u8, text: []const u8, normalized: bool) !?[]u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return null;
    const content = if (normalized) try lifecycle_mod.normalizeDedupeContent(allocator, trimmed) else try allocator.dupe(u8, trimmed);
    defer allocator.free(content);
    if (content.len == 0) return null;
    return try std.fmt.allocPrint(allocator, "{s}\x1f{s}\x1f{s}\x1f{s}\x1f{s}", .{ scope, permissions_json, predicate, object, content });
}

pub fn agentMemoryDedupeKey(allocator: std.mem.Allocator, scope: []const u8, permissions_json: []const u8, category: []const u8, session_id: ?[]const u8, text: []const u8, normalized: bool) !?[]u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return null;
    const content = if (normalized) try lifecycle_mod.normalizeDedupeContent(allocator, trimmed) else try allocator.dupe(u8, trimmed);
    defer allocator.free(content);
    if (content.len == 0) return null;
    return try std.fmt.allocPrint(allocator, "{s}\x1f{s}\x1f{s}\x1f{s}\x1f{s}", .{ scope, permissions_json, category, session_id orelse "", content });
}

pub fn routedAgentMemoryDedupeKey(allocator: std.mem.Allocator, store_name: []const u8, scope: []const u8, permissions_json: []const u8, category: []const u8, session_id: ?[]const u8, text: []const u8, normalized: bool) !?[]u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return null;
    const content = if (normalized) try lifecycle_mod.normalizeDedupeContent(allocator, trimmed) else try allocator.dupe(u8, trimmed);
    defer allocator.free(content);
    if (content.len == 0) return null;
    return try std.fmt.allocPrint(allocator, "{s}\x1f{s}\x1f{s}\x1f{s}\x1f{s}\x1f{s}", .{ store_name, scope, permissions_json, category, session_id orelse "", content });
}

test "store hygiene policy gates verify and delete operations" {
    const verify_input: RunInput = .{
        .scopes_json = "[\"admin\"]",
        .capabilities_json = "[\"verify\"]",
    };
    try std.testing.expect(canVerify(verify_input, "project:alpha", "[\"project:alpha\"]"));
    try std.testing.expect(canDeprecateAtom(verify_input, "verified", "project:alpha", "[\"project:alpha\"]"));
    try std.testing.expect(!canDeprecateAtom(verify_input, "deprecated", "project:alpha", "[\"project:alpha\"]"));

    const delete_input: RunInput = .{
        .scopes_json = "[\"admin\"]",
        .capabilities_json = "[\"delete\"]",
        .hard_delete = true,
    };
    try std.testing.expect(canDelete(delete_input, "project:alpha", "[\"project:alpha\"]"));
    try std.testing.expect(canDeprecateAtom(delete_input, "verified", "project:alpha", "[\"project:alpha\"]"));
}

test "store hygiene dedupe keys and ranks are deterministic" {
    const key = (try atomDedupeKey(std.testing.allocator, "public", "[]", "agent.memory", "pref.lang", "  Use Zig  ", false)).?;
    defer std.testing.allocator.free(key);
    try std.testing.expectEqualStrings("public\x1f[]\x1fagent.memory\x1fpref.lang\x1fUse Zig", key);
    try std.testing.expect((try atomDedupeKey(std.testing.allocator, "public", "[]", "agent.memory", "pref.lang", " \t ", false)) == null);

    try std.testing.expectEqual(@as(u8, 4), atomDedupeRank("verified"));
    try std.testing.expectEqual(@as(u8, 3), atomDedupeRank("proposed"));
    const older_proposed: DedupeWinner = .{
        .id = "old",
        .status = "proposed",
        .scope = "public",
        .permissions_json = "[]",
        .created_at_ms = 1,
        .last_verified_at_ms = null,
    };
    try std.testing.expect(shouldReplaceWinner("verified", 2, null, older_proposed));
    try std.testing.expect(shouldReplaceWinner("proposed", 3, null, older_proposed));
    try std.testing.expect(!shouldReplaceWinner("stale", 4, null, older_proposed));
}
