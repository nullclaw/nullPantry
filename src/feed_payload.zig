const std = @import("std");
const domain = @import("domain.zig");
const json = @import("json_util.zig");

pub fn agentMemoryWriteEventType(store_name: []const u8, operation: domain.AgentMemoryOperation) []const u8 {
    const native = std.mem.eql(u8, store_name, "native");
    return switch (operation) {
        .put => if (native) "agent_memory.put" else "agent_memory.runtime_put",
        .merge_object => if (native) "agent_memory.merge_object" else "agent_memory.runtime_merge_object",
        .merge_string_set => if (native) "agent_memory.merge_string_set" else "agent_memory.runtime_merge_string_set",
    };
}

pub fn agentMemoryDeleteEventType(store_name: []const u8) []const u8 {
    return if (std.mem.eql(u8, store_name, "native")) "agent_memory.delete" else "agent_memory.runtime_delete";
}

pub fn agentMemoryDeleteAllEventType(store_name: []const u8) []const u8 {
    return if (std.mem.eql(u8, store_name, "native")) "agent_memory.delete_all" else "agent_memory.runtime_delete_all";
}

pub fn agentMemoryWrite(allocator: std.mem.Allocator, store_name: []const u8, entry: domain.AgentMemory, operation: domain.AgentMemoryOperation, operation_content: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"store\":");
    try json.appendString(&out, allocator, store_name);
    try out.appendSlice(allocator, ",\"key\":");
    try json.appendString(&out, allocator, entry.key);
    try out.appendSlice(allocator, ",\"content\":");
    try json.appendString(&out, allocator, entry.content);
    try out.appendSlice(allocator, ",\"category\":");
    try json.appendString(&out, allocator, entry.category);
    try out.appendSlice(allocator, ",\"session_id\":");
    try json.appendNullableString(&out, allocator, entry.session_id);
    try out.appendSlice(allocator, ",\"scope\":");
    try json.appendString(&out, allocator, entry.scope);
    try out.appendSlice(allocator, ",\"permissions\":");
    try json.appendRawJsonOr(&out, allocator, entry.permissions_json, "[]");
    try out.appendSlice(allocator, ",\"owner_id\":");
    try json.appendString(&out, allocator, entry.actor_id);
    try out.appendSlice(allocator, ",\"writer_actor_id\":");
    try json.appendString(&out, allocator, if (entry.writer_actor_id.len > 0) entry.writer_actor_id else entry.actor_id);
    switch (operation) {
        .put => {},
        .merge_string_set => {
            try out.appendSlice(allocator, ",\"values\":");
            try json.appendRawJsonOr(&out, allocator, operation_content, "[]");
        },
        .merge_object => {
            try out.appendSlice(allocator, ",\"object\":");
            try json.appendRawJsonOr(&out, allocator, operation_content, "{}");
        },
    }
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

pub fn agentMemoryDelete(allocator: std.mem.Allocator, store_name: []const u8, key: []const u8, session_id: ?[]const u8, owner_actor_id: []const u8, scope: []const u8, permissions_json: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"store\":");
    try json.appendString(&out, allocator, store_name);
    try out.appendSlice(allocator, ",\"key\":");
    try json.appendString(&out, allocator, key);
    try out.appendSlice(allocator, ",\"session_id\":");
    try json.appendNullableString(&out, allocator, session_id);
    try out.appendSlice(allocator, ",\"scope\":");
    try json.appendString(&out, allocator, scope);
    try out.appendSlice(allocator, ",\"permissions\":");
    try json.appendRawJsonOr(&out, allocator, permissions_json, "[]");
    try out.appendSlice(allocator, ",\"owner_id\":");
    try json.appendString(&out, allocator, owner_actor_id);
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

pub fn domainObject(allocator: std.mem.Allocator, value: anytype) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try value.writeJson(allocator, &out);
    return out.toOwnedSlice(allocator);
}

pub fn policyScope(allocator: std.mem.Allocator, policy: anytype) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"scope\":");
    try json.appendString(&out, allocator, policy.scope);
    try out.appendSlice(allocator, ",\"visibility\":");
    try json.appendString(&out, allocator, policy.visibility);
    try out.appendSlice(allocator, ",\"permissions\":");
    try json.appendRawJsonOr(&out, allocator, policy.permissions_json, "[]");
    try out.appendSlice(allocator, ",\"owner\":");
    try json.appendNullableString(&out, allocator, policy.owner);
    try out.appendSlice(allocator, ",\"ttl_ms\":");
    if (policy.ttl_ms) |v| try out.print(allocator, "{d}", .{v}) else try out.appendSlice(allocator, "null");
    try out.appendSlice(allocator, ",\"review_after_ms\":");
    if (policy.review_after_ms) |v| try out.print(allocator, "{d}", .{v}) else try out.appendSlice(allocator, "null");
    try out.appendSlice(allocator, ",\"metadata\":");
    try json.appendRawJsonOr(&out, allocator, policy.metadata_json, "{}");
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

pub fn policyScopeDedupeKey(allocator: std.mem.Allocator, scope: []const u8, payload_json: []const u8) ![]const u8 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(scope);
    hasher.update("\n");
    hasher.update(payload_json);
    return std.fmt.allocPrint(allocator, "direct:policy_scope:{s}:{x}", .{ scope, hasher.final() });
}

pub fn withStorageRoute(allocator: std.mem.Allocator, payload_json: []const u8, route: anytype) ![]const u8 {
    if (route.target == .primary) return allocator.dupe(u8, payload_json);
    const trimmed = std.mem.trim(u8, payload_json, " \t\r\n");
    if (trimmed.len < 2 or trimmed[0] != '{' or trimmed[trimmed.len - 1] != '}') {
        return allocator.dupe(u8, payload_json);
    }
    if (try hasTopLevelStorageRoute(allocator, trimmed)) {
        return allocator.dupe(u8, payload_json);
    }

    const inner = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t\r\n");
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '{');
    if (inner.len > 0) {
        try out.appendSlice(allocator, inner);
        try out.append(allocator, ',');
    }
    switch (route.target) {
        .primary => unreachable,
        .native => try out.appendSlice(allocator, "\"storage\":\"native\""),
        .runtime => try out.appendSlice(allocator, "\"store\":\"runtime\""),
        .named => {
            try out.appendSlice(allocator, "\"store\":");
            try json.appendString(&out, allocator, route.name orelse "runtime");
        },
        .all => try out.appendSlice(allocator, "\"storage\":\"all\""),
        .subset => {
            try out.appendSlice(allocator, "\"stores\":[");
            for (route.stores, 0..) |store_name, i| {
                if (i > 0) try out.append(allocator, ',');
                try json.appendString(&out, allocator, store_name);
            }
            try out.append(allocator, ']');
        },
    }
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

fn hasTopLevelStorageRoute(allocator: std.mem.Allocator, payload_json: []const u8) !bool {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const obj = parsed.value.object;
    return obj.get("store") != null or obj.get("storage") != null or obj.get("stores") != null;
}

pub fn storageRouteDedupePart(allocator: std.mem.Allocator, route: anytype) ![]const u8 {
    return switch (route.target) {
        .primary => allocator.dupe(u8, "primary"),
        .native => allocator.dupe(u8, "native"),
        .runtime => allocator.dupe(u8, "runtime"),
        .named => std.fmt.allocPrint(allocator, "named:{s}", .{route.name orelse "runtime"}),
        .all => allocator.dupe(u8, "all"),
        .subset => blk: {
            var out: std.ArrayListUnmanaged(u8) = .empty;
            errdefer out.deinit(allocator);
            try out.appendSlice(allocator, "subset:");
            for (route.stores, 0..) |store_name, i| {
                if (i > 0) try out.append(allocator, ',');
                try out.appendSlice(allocator, store_name);
            }
            break :blk try out.toOwnedSlice(allocator);
        },
    };
}

pub fn contextPack(allocator: std.mem.Allocator, pack: anytype) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"id\":");
    try json.appendString(&out, allocator, pack.id);
    try out.appendSlice(allocator, ",\"purpose\":");
    try json.appendString(&out, allocator, pack.purpose);
    try out.appendSlice(allocator, ",\"target\":");
    try json.appendString(&out, allocator, pack.target);
    try out.appendSlice(allocator, ",\"query\":");
    try json.appendString(&out, allocator, pack.query);
    try out.appendSlice(allocator, ",\"task\":");
    try json.appendString(&out, allocator, pack.query);
    try out.appendSlice(allocator, ",\"token_budget\":");
    try out.print(allocator, "{d}", .{pack.token_budget});
    try out.appendSlice(allocator, ",\"scopes\":");
    try json.appendRawJsonOr(&out, allocator, pack.required_scopes_json, "[]");
    try out.appendSlice(allocator, ",\"generated_summary\":");
    try json.appendString(&out, allocator, pack.generated_summary);
    try out.appendSlice(allocator, ",\"included_sources\":");
    try json.appendRawJsonOr(&out, allocator, pack.included_sources_json, "[]");
    try out.appendSlice(allocator, ",\"included_artifacts\":");
    try json.appendRawJsonOr(&out, allocator, pack.included_artifacts_json, "[]");
    try out.appendSlice(allocator, ",\"included_memory_atoms\":");
    try json.appendRawJsonOr(&out, allocator, pack.included_memory_atoms_json, "[]");
    try out.appendSlice(allocator, ",\"included_result_refs\":");
    try json.appendRawJsonOr(&out, allocator, pack.included_result_refs_json, "[]");
    try out.appendSlice(allocator, ",\"actor_isolated\":");
    try out.appendSlice(allocator, if (pack.actor_isolated) "true" else "false");
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

pub fn agentSessionMessagePut(allocator: std.mem.Allocator, route: anytype, session_id: []const u8, role: []const u8, content: []const u8, created_at_ms: i64, actor_id: ?[]const u8, scope: []const u8, permissions_json: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"session_id\":");
    try json.appendString(&out, allocator, session_id);
    try out.appendSlice(allocator, ",\"actor_id\":");
    try json.appendNullableString(&out, allocator, actor_id);
    try out.appendSlice(allocator, ",\"role\":");
    try json.appendString(&out, allocator, role);
    try out.appendSlice(allocator, ",\"content\":");
    try json.appendString(&out, allocator, content);
    try out.print(allocator, ",\"created_at_ms\":{d}", .{created_at_ms});
    try out.appendSlice(allocator, ",\"scope\":");
    try json.appendString(&out, allocator, scope);
    try out.appendSlice(allocator, ",\"permissions\":");
    try json.appendRawJsonOr(&out, allocator, permissions_json, "[]");
    try out.append(allocator, '}');
    const payload = try out.toOwnedSlice(allocator);
    defer allocator.free(payload);
    return withStorageRoute(allocator, payload, route);
}

pub fn agentSessionMessageDelete(allocator: std.mem.Allocator, route: anytype, session_id: []const u8, actor_id: ?[]const u8, scope: []const u8, permissions_json: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"session_id\":");
    try json.appendString(&out, allocator, session_id);
    try out.appendSlice(allocator, ",\"actor_id\":");
    try json.appendNullableString(&out, allocator, actor_id);
    try out.appendSlice(allocator, ",\"delete_all\":true,\"scope\":");
    try json.appendString(&out, allocator, scope);
    try out.appendSlice(allocator, ",\"permissions\":");
    try json.appendRawJsonOr(&out, allocator, permissions_json, "[]");
    try out.append(allocator, '}');
    const payload = try out.toOwnedSlice(allocator);
    defer allocator.free(payload);
    return withStorageRoute(allocator, payload, route);
}

pub fn agentSessionAutosaveDelete(allocator: std.mem.Allocator, route: anytype, session_id: ?[]const u8, actor_id: ?[]const u8, scope: []const u8, permissions_json: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"session_id\":");
    try json.appendNullableString(&out, allocator, session_id);
    try out.appendSlice(allocator, ",\"actor_id\":");
    try json.appendNullableString(&out, allocator, actor_id);
    try out.appendSlice(allocator, ",\"delete_autosaved\":true,\"autosave_only\":true,\"scope\":");
    try json.appendString(&out, allocator, scope);
    try out.appendSlice(allocator, ",\"permissions\":");
    try json.appendRawJsonOr(&out, allocator, permissions_json, "[]");
    try out.append(allocator, '}');
    const payload = try out.toOwnedSlice(allocator);
    defer allocator.free(payload);
    return withStorageRoute(allocator, payload, route);
}

pub fn agentSessionUsagePut(allocator: std.mem.Allocator, route: anytype, session_id: []const u8, total_tokens: u64, actor_id: ?[]const u8, scope: []const u8, permissions_json: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"session_id\":");
    try json.appendString(&out, allocator, session_id);
    try out.appendSlice(allocator, ",\"actor_id\":");
    try json.appendNullableString(&out, allocator, actor_id);
    try out.print(allocator, ",\"total_tokens\":{d}", .{total_tokens});
    try out.appendSlice(allocator, ",\"scope\":");
    try json.appendString(&out, allocator, scope);
    try out.appendSlice(allocator, ",\"permissions\":");
    try json.appendRawJsonOr(&out, allocator, permissions_json, "[]");
    try out.append(allocator, '}');
    const payload = try out.toOwnedSlice(allocator);
    defer allocator.free(payload);
    return withStorageRoute(allocator, payload, route);
}

pub fn agentSessionUsageDelete(allocator: std.mem.Allocator, route: anytype, session_id: []const u8, actor_id: ?[]const u8, scope: []const u8, permissions_json: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"session_id\":");
    try json.appendString(&out, allocator, session_id);
    try out.appendSlice(allocator, ",\"actor_id\":");
    try json.appendNullableString(&out, allocator, actor_id);
    try out.appendSlice(allocator, ",\"scope\":");
    try json.appendString(&out, allocator, scope);
    try out.appendSlice(allocator, ",\"permissions\":");
    try json.appendRawJsonOr(&out, allocator, permissions_json, "[]");
    try out.append(allocator, '}');
    const payload = try out.toOwnedSlice(allocator);
    defer allocator.free(payload);
    return withStorageRoute(allocator, payload, route);
}

const TestTarget = enum { primary, native, runtime, named, subset, all };
const TestRoute = struct {
    target: TestTarget = .primary,
    name: ?[]const u8 = null,
    stores: []const []const u8 = &.{},
};

test "feed payload route injection ignores nested route-like keys" {
    const allocator = std.testing.allocator;
    const payload = "{\"title\":\"route\",\"metadata\":{\"store\":\"embedded\"},\"content\":\"{\\\"storage\\\":\\\"inside\\\"}\"}";
    const routed = try withStorageRoute(allocator, payload, TestRoute{ .target = .named, .name = "scratch" });
    defer allocator.free(routed);

    try std.testing.expect(std.mem.indexOf(u8, routed, "\"store\":\"scratch\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, routed, "\"metadata\":{\"store\":\"embedded\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, routed, "\"content\":\"{\\\"storage\\\":\\\"inside\\\"}\"") != null);
}

test "feed payload route injection preserves explicit top-level selectors" {
    const allocator = std.testing.allocator;
    const payload = "{\"store\":\"archive\",\"title\":\"explicit\"}";
    const routed = try withStorageRoute(allocator, payload, TestRoute{ .target = .named, .name = "scratch" });
    defer allocator.free(routed);

    try std.testing.expectEqualStrings(payload, routed);
}
