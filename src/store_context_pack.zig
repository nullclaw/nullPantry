const std = @import("std");
const access = @import("access.zig");
const context_pack = @import("context_pack.zig");
const domain = @import("domain.zig");
const json = @import("json_util.zig");
const store_types = @import("store_types.zig");

pub const Input = store_types.ContextPackInput;

pub const SnapshotInput = struct {
    id: ?[]const u8 = null,
    purpose: []const u8 = "snapshot_hydrate",
    target: []const u8 = "agent",
    query: []const u8,
    generated_summary: []const u8,
    sections_json: []const u8 = "{}",
    citations_json: []const u8 = "[]",
    forbidden_assumptions_json: []const u8 = context_pack.forbidden_assumptions_json,
    suggested_next_steps_json: []const u8 = context_pack.suggested_next_steps_json,
    included_sources_json: []const u8 = "[]",
    included_artifacts_json: []const u8 = "[]",
    included_memory_atoms_json: []const u8 = "[]",
    included_result_refs_json: []const u8 = "[]",
    required_scopes_json: []const u8 = "[\"admin\"]",
    actor_id: ?[]const u8 = null,
    actor_isolated: bool = false,
    token_budget: i64 = 12000,
    actor_id_for_audit: ?[]const u8 = null,
    suppress_feed: bool = false,
};

pub const Result = struct {
    id: []const u8,
    purpose: []const u8,
    target: []const u8,
    query: []const u8,
    generated_summary: []const u8,
    sections_json: []const u8,
    citations_json: []const u8,
    forbidden_assumptions_json: []const u8,
    suggested_next_steps_json: []const u8,
    included_sources_json: []const u8,
    included_artifacts_json: []const u8,
    included_memory_atoms_json: []const u8,
    included_result_refs_json: []const u8 = "[]",
    required_scopes_json: []const u8 = "[\"admin\"]",
    actor_id: ?[]const u8 = null,
    actor_isolated: bool = false,
    token_budget: i64,
    created_at_ms: i64,
    persisted: bool = true,
};

pub fn feedScope(allocator: std.mem.Allocator, pack: Result) ![]const u8 {
    if (pack.actor_isolated) {
        if (pack.actor_id) |actor| return domain.defaultAgentMemoryScope(allocator, actor);
    }
    return access.scopeFromRequiredScopesJson(allocator, pack.required_scopes_json);
}

pub fn feedPermissions(allocator: std.mem.Allocator, pack: Result) ![]const u8 {
    if (pack.actor_isolated) {
        if (pack.actor_id) |actor| return domain.actorGrantJson(allocator, actor);
    }
    const scope = try feedScope(allocator, pack);
    defer allocator.free(scope);
    return access.permissionsJsonFromRequiredAccessJson(allocator, scope, pack.required_scopes_json);
}

pub fn hasEvidence(pack: Result) bool {
    return jsonArrayTextHasItems(pack.included_sources_json) or
        jsonArrayTextHasItems(pack.included_artifacts_json) or
        jsonArrayTextHasItems(pack.included_memory_atoms_json);
}

pub fn requiredScopesCoverRecord(allocator: std.mem.Allocator, required_scopes_json: []const u8, scope: []const u8, permissions_json: []const u8, actor_id: ?[]const u8) !bool {
    const record_required = try access.requiredAccessJsonForActor(allocator, scope, permissions_json, actor_id);
    defer allocator.free(record_required);
    return requiredScopeSetCovers(allocator, required_scopes_json, record_required);
}

pub fn validateResultRefs(allocator: std.mem.Allocator, refs_json: []const u8, required_scopes_json: []const u8, actor_isolated: bool) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, refs_json, .{}) catch return error.InvalidPayload;
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidPayload;
    for (parsed.value.array.items) |item| {
        if (item != .object) return error.InvalidPayload;
        const obj = item.object;
        if ((json.boolField(obj, "actor_isolated") orelse false) and !actor_isolated) return error.ContextPackAclBroaderThanRefs;
        const ref_required = try rawJsonField(allocator, obj, "required_scopes", "[]");
        defer allocator.free(ref_required);
        if (!requiredScopeSetCovers(allocator, required_scopes_json, ref_required)) return error.ContextPackAclBroaderThanRefs;
    }
}

pub fn requiredScopeSetCovers(allocator: std.mem.Allocator, covering_json: []const u8, required_json: []const u8) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, required_json, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .array) return false;
    for (parsed.value.array.items) |item| {
        if (item != .string) return false;
        const required = item.string;
        if (required.len == 0) return false;
        if (std.mem.eql(u8, required, "public")) continue;
        if (!domain.hasJsonString(covering_json, required)) return false;
    }
    return true;
}

fn jsonArrayTextHasItems(value: []const u8) bool {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    return trimmed.len > 2 and !std.mem.eql(u8, trimmed, "[]");
}

fn rawJsonField(allocator: std.mem.Allocator, obj: std.json.ObjectMap, name: []const u8, fallback: []const u8) ![]u8 {
    const value = obj.get(name) orelse return json.rawJsonFieldFallback(allocator, name, fallback);
    return try json.rawJsonFieldValue(allocator, name, value, fallback);
}

test "store context pack feed ACL helpers preserve actor isolation" {
    const pack: Result = .{
        .id = "ctx",
        .purpose = "task",
        .target = "agent",
        .query = "architecture",
        .generated_summary = "summary",
        .sections_json = "{}",
        .citations_json = "[]",
        .forbidden_assumptions_json = "[]",
        .suggested_next_steps_json = "[]",
        .included_sources_json = "[]",
        .included_artifacts_json = "[]",
        .included_memory_atoms_json = "[]",
        .required_scopes_json = "[\"team:alpha\",\"write:team:alpha\"]",
        .actor_id = "agent:a",
        .actor_isolated = true,
        .token_budget = 12000,
        .created_at_ms = 1,
    };
    const scope = try feedScope(std.testing.allocator, pack);
    defer std.testing.allocator.free(scope);
    const permissions = try feedPermissions(std.testing.allocator, pack);
    defer std.testing.allocator.free(permissions);
    try std.testing.expectEqualStrings("agent:agent:a", scope);
    try std.testing.expectEqualStrings("[\"actor:agent:a\"]", permissions);
}

test "store context pack feed ACL helpers derive scope and permissions fail closed" {
    const allocator = std.testing.allocator;
    const pack: Result = .{
        .id = "ctx",
        .purpose = "task",
        .target = "agent",
        .query = "architecture",
        .generated_summary = "summary",
        .sections_json = "{}",
        .citations_json = "[]",
        .forbidden_assumptions_json = "[]",
        .suggested_next_steps_json = "[]",
        .included_sources_json = "[]",
        .included_artifacts_json = "[]",
        .included_memory_atoms_json = "[]",
        .required_scopes_json = "[\"public\",\"project:secret\",\"team:secret\"]",
        .token_budget = 12000,
        .created_at_ms = 1,
    };

    const scope = try feedScope(allocator, pack);
    defer allocator.free(scope);
    const permissions = try feedPermissions(allocator, pack);
    defer allocator.free(permissions);
    try std.testing.expectEqualStrings("project:secret", scope);
    try std.testing.expectEqualStrings("[\"team:secret\"]", permissions);

    var malformed_pack = pack;
    malformed_pack.required_scopes_json = "not-json";
    const malformed_scope = try feedScope(allocator, malformed_pack);
    defer allocator.free(malformed_scope);
    const malformed_permissions = try feedPermissions(allocator, malformed_pack);
    defer allocator.free(malformed_permissions);
    try std.testing.expectEqualStrings(access.malformed_required_scopes_gate, malformed_scope);
    try std.testing.expect(std.mem.indexOf(u8, malformed_permissions, access.malformed_required_access_gate) != null);
}

test "store context pack reference ACL validation is fail closed" {
    try std.testing.expect(requiredScopeSetCovers(std.testing.allocator, "[\"team:alpha\",\"admin\"]", "[\"team:alpha\"]"));
    try std.testing.expect(!requiredScopeSetCovers(std.testing.allocator, "[\"team:alpha\"]", "[\"team:beta\"]"));

    try validateResultRefs(std.testing.allocator, "[{\"required_scopes\":[\"team:alpha\"]}]", "[\"team:alpha\",\"admin\"]", false);
    try std.testing.expectError(error.ContextPackAclBroaderThanRefs, validateResultRefs(std.testing.allocator, "[{\"required_scopes\":[\"team:beta\"]}]", "[\"team:alpha\"]", false));
    try std.testing.expectError(error.ContextPackAclBroaderThanRefs, validateResultRefs(std.testing.allocator, "[{\"actor_isolated\":true,\"required_scopes\":[\"team:alpha\"]}]", "[\"team:alpha\"]", false));
    try std.testing.expectError(error.ContextPackAclBroaderThanRefs, validateResultRefs(std.testing.allocator, "[{\"required_scopes\":\"[\\\"team:alpha\\\"]\"}]", "[\"team:alpha\"]", false));
}
