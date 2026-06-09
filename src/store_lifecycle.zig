const std = @import("std");
const access = @import("access.zig");
const domain = @import("domain.zig");
const json = @import("json_util.zig");
const lucid_runtime = @import("lucid_runtime.zig");

pub const PrimitiveMirrorKind = enum {
    source,
    artifact,
    memory_atom,
    entity,
    relation,
    context_pack,

    pub fn resultType(self: PrimitiveMirrorKind) []const u8 {
        return switch (self) {
            .source => "source",
            .artifact => "artifact",
            .memory_atom => "memory_atom",
            .entity => "entity",
            .relation => "relation",
            .context_pack => "context_pack",
        };
    }
};

pub fn primitiveLifecycleUsesOverlay(object_type: []const u8) bool {
    return std.mem.eql(u8, object_type, "source") or
        std.mem.eql(u8, object_type, "entity") or
        std.mem.eql(u8, object_type, "context_pack") or
        std.mem.eql(u8, object_type, "space") or
        std.mem.eql(u8, object_type, "policy_scope");
}

pub fn stableLifecycleStatus(status: []const u8) []const u8 {
    if (std.mem.eql(u8, status, "active")) return "active";
    if (std.mem.eql(u8, status, "fresh")) return "fresh";
    if (std.mem.eql(u8, status, "probably_fresh")) return "probably_fresh";
    if (std.mem.eql(u8, status, "needs_review") or std.mem.eql(u8, status, "needs review")) return "needs_review";
    if (std.mem.eql(u8, status, "verified")) return "verified";
    if (std.mem.eql(u8, status, "accepted")) return "accepted";
    if (std.mem.eql(u8, status, "proposed")) return "proposed";
    if (std.mem.eql(u8, status, "stale")) return "stale";
    if (std.mem.eql(u8, status, "deprecated")) return "deprecated";
    if (std.mem.eql(u8, status, "superseded")) return "superseded";
    if (std.mem.eql(u8, status, "rejected")) return "rejected";
    if (std.mem.eql(u8, status, "archived")) return "archived";
    if (std.mem.eql(u8, status, "hidden")) return "hidden";
    if (std.mem.eql(u8, status, "ignored")) return "ignored";
    return "unknown";
}

pub fn lucidProjectionKey(allocator: std.mem.Allocator, object_type: []const u8, object_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}:{s}", .{ object_type, object_id });
}

pub fn agentMemoryProjectionKey(allocator: std.mem.Allocator, entry: domain.AgentMemory) ![]u8 {
    return agentMemoryProjectionKeyFromParts(allocator, entry.key, entry.session_id, entry.actor_id);
}

pub fn agentMemoryProjectionKeyFromParts(allocator: std.mem.Allocator, key: []const u8, session_id: ?[]const u8, actor_id: ?[]const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "agent_memory:{s}:{s}:{s}", .{ actor_id orelse "unknown", session_id orelse "global", key });
}

pub fn lucidTypeForPrimitive(object_type: []const u8, title: []const u8, text: []const u8) []const u8 {
    if (std.mem.eql(u8, object_type, "memory_atom")) return lucid_runtime.typeForMemoryAtom(title, text);
    if (std.mem.eql(u8, object_type, "agent_memory")) return lucid_runtime.typeForAgentCategory(title);
    if (std.mem.eql(u8, object_type, "artifact")) {
        if (std.ascii.eqlIgnoreCase(title, "decision") or std.ascii.eqlIgnoreCase(title, "adr")) return "decision";
        if (std.ascii.eqlIgnoreCase(title, "meeting_note")) return "conversation";
        if (std.ascii.eqlIgnoreCase(title, "runbook") or std.ascii.eqlIgnoreCase(title, "recipe")) return "context";
    }
    if (std.mem.eql(u8, object_type, "context_pack")) return "context";
    return "learning";
}

pub fn lucidProjectionJobInputJson(allocator: std.mem.Allocator, action: []const u8, key: []const u8, content: []const u8, lucid_type: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"action\":");
    try json.appendString(&out, allocator, action);
    try out.appendSlice(allocator, ",\"key\":");
    try json.appendString(&out, allocator, key);
    try out.appendSlice(allocator, ",\"content\":");
    try json.appendString(&out, allocator, content);
    try out.appendSlice(allocator, ",\"type\":");
    try json.appendString(&out, allocator, lucid_type);
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

pub const malformed_required_scopes_gate = access.malformed_required_scopes_gate;
pub const lifecycleScopeFromRequiredScopesJson = access.scopeFromRequiredScopesJson;

test "lifecycle scope fails closed for malformed required scopes json" {
    const allocator = std.testing.allocator;

    const public_scope = try lifecycleScopeFromRequiredScopesJson(allocator, "[]");
    defer allocator.free(public_scope);
    try std.testing.expectEqualStrings("public", public_scope);

    const project_scope = try lifecycleScopeFromRequiredScopesJson(allocator, "[\"public\",\"project:nullpantry\"]");
    defer allocator.free(project_scope);
    try std.testing.expectEqualStrings("project:nullpantry", project_scope);

    const not_json = try lifecycleScopeFromRequiredScopesJson(allocator, "not-json");
    defer allocator.free(not_json);
    try std.testing.expectEqualStrings(malformed_required_scopes_gate, not_json);

    const mixed_array = try lifecycleScopeFromRequiredScopesJson(allocator, "[\"public\",42]");
    defer allocator.free(mixed_array);
    try std.testing.expectEqualStrings(malformed_required_scopes_gate, mixed_array);
}

test "store lifecycle helpers normalize projection metadata" {
    try std.testing.expect(primitiveLifecycleUsesOverlay("source"));
    try std.testing.expect(!primitiveLifecycleUsesOverlay("artifact"));
    try std.testing.expectEqualStrings("needs_review", stableLifecycleStatus("needs review"));
    try std.testing.expectEqualStrings("unknown", stableLifecycleStatus("other"));
    try std.testing.expectEqualStrings("decision", lucidTypeForPrimitive("artifact", "ADR", "Use SQLite"));
}
