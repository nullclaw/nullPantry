const std = @import("std");
const access = @import("access.zig");
const agent_memory_runtime = @import("agent_memory_runtime.zig");
const domain = @import("domain.zig");
const store_lifecycle = @import("store_lifecycle.zig");
const store_ownership = @import("store_ownership.zig");
const store_primitive_runtime = @import("store_primitive_runtime.zig");
const store_types = @import("store_types.zig");

pub const SearchInput = store_types.SearchInput;

pub fn appendResults(
    store: anytype,
    allocator: std.mem.Allocator,
    input: SearchInput,
    runtime: *agent_memory_runtime.Runtime,
    store_name: []const u8,
    results: *std.ArrayListUnmanaged(domain.SearchResult),
) !void {
    const actor = input.actor_id orelse return;
    const search_limit = @max(input.limit, @as(usize, 20));
    const external = try runtime.searchByInput(allocator, .{
        .query = input.query,
        .limit = search_limit,
        .session_id = input.session_id,
        .scopes_json = input.scopes_json,
        .actor_id = actor,
        .capabilities_json = input.actor_capabilities_json,
        .any_session = input.session_id == null and input.include_sessions,
    });
    defer {
        for (external) |*entry| agent_memory_runtime.freeAgentMemory(allocator, entry);
        allocator.free(external);
    }

    for (external) |*entry| {
        if (domain.isInternalMemoryEntryKeyOrContent(entry.key, entry.content)) continue;
        const primitive_type = store_primitive_runtime.typeFromAgentCategory(entry.category);
        const status = if (primitive_type) |kind| blk: {
            const canonical_status = try primitiveRuntimeCanonicalStatus(store, allocator, kind, entry.key, input);
            if (canonical_status == null) continue;
            break :blk canonical_status.?;
        } else "active";
        const title = if (primitive_type) |kind|
            try store_primitive_runtime.title(allocator, kind, entry.key)
        else
            try std.fmt.allocPrint(allocator, "agent_memory:{s}", .{entry.key});
        const result_store = if (entry.store.len > 0) entry.store else store_name;
        const id = if (primitive_type != null)
            try store_primitive_runtime.objectId(allocator, entry.key, entry.id)
        else if (result_store.len > 0)
            try std.fmt.allocPrint(allocator, "agent_memory:{s}:{s}", .{ result_store, entry.id })
        else
            try allocator.dupe(u8, entry.id);
        const text = try allocator.dupe(u8, entry.content);
        const scope = try allocator.dupe(u8, entry.scope);
        const required_scopes = try access.requiredAccessJsonForActor(allocator, entry.scope, entry.permissions_json, actor);
        const result_session_id = if (primitive_type == null)
            if (entry.session_id) |sid| try allocator.dupe(u8, sid) else null
        else
            null;
        try results.append(allocator, .{
            .id = id,
            .result_type = primitive_type orelse "agent_memory",
            .title = title,
            .text = text,
            .scope = scope,
            .status = status,
            .score = entry.score orelse 0.5,
            .source_ids_json = try store_primitive_runtime.citations(allocator, primitive_type, id),
            .required_scopes_json = required_scopes,
            .actor_isolated = !access.isSharedAgentMemoryOwner(entry.actor_id),
            .created_at_ms = std.fmt.parseInt(i64, entry.timestamp, 10) catch 0,
            .confidence = 0.8,
            .store = if (primitive_type == null) result_store else "",
            .session_id = result_session_id,
        });
    }
}

fn primitiveRuntimeCanonicalStatus(store: anytype, allocator: std.mem.Allocator, result_type: []const u8, key: []const u8, input: SearchInput) !?[]const u8 {
    const id = try store_primitive_runtime.objectId(allocator, key, key);
    defer allocator.free(id);

    if (std.mem.eql(u8, result_type, "source")) {
        var source = (try store.getSource(allocator, id)) orelse return null;
        defer store_ownership.deinitSource(allocator, &source);
        const status = try store.primitiveLifecycleStatus(allocator, "source", id);
        if (!input.include_deprecated and !domain.isDefaultVisibleStatus(status)) return null;
        if (!try store.recordVisibleWithPolicyForActor(allocator, source.scope, source.permissions_json, input.scopes_json, input.actor_id)) return null;
        return status;
    }
    if (std.mem.eql(u8, result_type, "artifact")) {
        var artifact = (try store.getArtifact(allocator, id)) orelse return null;
        defer store_ownership.deinitArtifact(allocator, &artifact);
        const status = store_lifecycle.stableLifecycleStatus(artifact.status);
        if (!input.include_deprecated and !domain.isDefaultVisibleStatus(artifact.status)) return null;
        if (!try store.recordVisibleWithPolicyForActor(allocator, artifact.scope, artifact.permissions_json, input.scopes_json, input.actor_id)) return null;
        return status;
    }
    if (std.mem.eql(u8, result_type, "memory_atom")) {
        var atom = (try store.getMemoryAtom(allocator, id)) orelse return null;
        defer store_ownership.deinitMemoryAtom(allocator, &atom);
        const status = store_lifecycle.stableLifecycleStatus(atom.status);
        if (!input.include_deprecated and !domain.isDefaultVisibleStatus(atom.status)) return null;
        if (!try store.recordVisibleWithPolicyForActor(allocator, atom.scope, atom.permissions_json, input.scopes_json, input.actor_id)) return null;
        return status;
    }
    if (std.mem.eql(u8, result_type, "entity")) {
        var entity = (try store.getEntity(allocator, id)) orelse return null;
        defer store_ownership.deinitEntity(allocator, &entity);
        const status = try store.primitiveLifecycleStatus(allocator, "entity", id);
        if (!input.include_deprecated and !domain.isDefaultVisibleStatus(status)) return null;
        if (!try store.recordVisibleWithPolicyForActor(allocator, entity.scope, entity.permissions_json, input.scopes_json, input.actor_id)) return null;
        return status;
    }
    if (std.mem.eql(u8, result_type, "relation")) {
        var relation = (try store.getRelation(allocator, id)) orelse return null;
        defer store_ownership.deinitRelation(allocator, &relation);
        const status = store_lifecycle.stableLifecycleStatus(relation.status);
        if (!input.include_deprecated and !domain.isDefaultVisibleStatus(relation.status)) return null;
        if (!try store.recordVisibleWithPolicyForActor(allocator, relation.scope, relation.permissions_json, input.scopes_json, input.actor_id)) return null;
        return status;
    }
    if (std.mem.eql(u8, result_type, "context_pack")) {
        _ = (try store.contextPackLifecycleTarget(allocator, id, input.actor_id, input.scopes_json)) orelse return null;
        const status = try store.primitiveLifecycleStatus(allocator, "context_pack", id);
        if (!input.include_deprecated and !domain.isDefaultVisibleStatus(status)) return null;
        return status;
    }
    return "active";
}
