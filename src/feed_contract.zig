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

pub fn objectTypeHasVisibleBackingRecord(object_type: []const u8) bool {
    return std.mem.eql(u8, object_type, "source") or
        std.mem.eql(u8, object_type, "artifact") or
        std.mem.eql(u8, object_type, "memory_atom") or
        std.mem.eql(u8, object_type, "entity") or
        std.mem.eql(u8, object_type, "relation") or
        std.mem.eql(u8, object_type, "context_pack") or
        std.mem.eql(u8, object_type, "agent_memory");
}

pub fn objectTypeSupported(object_type: []const u8) bool {
    return std.mem.eql(u8, object_type, "memory_atom") or
        std.mem.eql(u8, object_type, "source") or
        std.mem.eql(u8, object_type, "artifact") or
        std.mem.eql(u8, object_type, "entity") or
        std.mem.eql(u8, object_type, "relation") or
        std.mem.eql(u8, object_type, "agent_memory") or
        isAgentSessionObject(object_type) or
        std.mem.eql(u8, object_type, "context_pack") or
        std.mem.eql(u8, object_type, "space") or
        std.mem.eql(u8, object_type, "policy_scope");
}

pub fn isAgentSessionObject(object_type: []const u8) bool {
    return std.mem.eql(u8, object_type, "agent_session_message") or
        std.mem.eql(u8, object_type, "agent_session_usage");
}

pub fn objectTypeUsesAgentMemoryStorageRoute(object_type: []const u8) bool {
    return std.mem.eql(u8, object_type, "agent_memory") or isAgentSessionObject(object_type);
}

pub fn objectTypeUsesKnowledgeStorageRoute(object_type: []const u8) bool {
    return std.mem.eql(u8, object_type, "memory_atom") or
        std.mem.eql(u8, object_type, "source") or
        std.mem.eql(u8, object_type, "artifact") or
        std.mem.eql(u8, object_type, "entity") or
        std.mem.eql(u8, object_type, "relation") or
        std.mem.eql(u8, object_type, "context_pack");
}

pub fn lifecycleUsesOverlay(object_type: []const u8) bool {
    return std.mem.eql(u8, object_type, "source") or
        std.mem.eql(u8, object_type, "entity") or
        std.mem.eql(u8, object_type, "context_pack") or
        std.mem.eql(u8, object_type, "space") or
        std.mem.eql(u8, object_type, "policy_scope");
}

pub fn operationFromEventType(event_type: []const u8) []const u8 {
    if (std.mem.endsWith(u8, event_type, ".delete_all") or std.mem.endsWith(u8, event_type, "_delete_all")) return "delete_all";
    if (std.mem.endsWith(u8, event_type, ".delete_scoped") or std.mem.endsWith(u8, event_type, "_delete_scoped")) return "delete_scoped";
    if (std.mem.endsWith(u8, event_type, ".delete") or std.mem.endsWith(u8, event_type, ".forget")) return "delete";
    if (std.mem.endsWith(u8, event_type, ".verify") or std.mem.endsWith(u8, event_type, "_verify")) return "verify";
    if (std.mem.endsWith(u8, event_type, ".mark_stale") or std.mem.endsWith(u8, event_type, "_mark_stale")) return "mark_stale";
    if (std.mem.endsWith(u8, event_type, ".stale") or std.mem.endsWith(u8, event_type, "_stale")) return "stale";
    if (std.mem.endsWith(u8, event_type, ".supersede") or std.mem.endsWith(u8, event_type, "_supersede")) return "supersede";
    if (std.mem.endsWith(u8, event_type, ".delete_autosaved") or std.mem.endsWith(u8, event_type, ".clear_autosaved")) return "delete_autosaved";
    if (std.mem.endsWith(u8, event_type, ".merge_object") or std.mem.endsWith(u8, event_type, "_merge_object")) return "merge_object";
    if (std.mem.endsWith(u8, event_type, ".merge_string_set") or std.mem.endsWith(u8, event_type, "_merge_string_set")) return "merge_string_set";
    return "put";
}

pub fn isLifecycleOperation(operation: []const u8) bool {
    return std.mem.eql(u8, operation, "delete") or
        std.mem.eql(u8, operation, "forget") or
        std.mem.eql(u8, operation, "verify") or
        std.mem.eql(u8, operation, "mark_stale") or
        std.mem.eql(u8, operation, "stale") or
        std.mem.eql(u8, operation, "supersede");
}

pub fn statusFromLifecycleOperation(operation: []const u8, payload_obj: std.json.ObjectMap) []const u8 {
    if (json.stringField(payload_obj, "status")) |status| return status;
    if (std.mem.eql(u8, operation, "verify")) return "verified";
    if (std.mem.eql(u8, operation, "mark_stale") or std.mem.eql(u8, operation, "stale")) return "stale";
    if (std.mem.eql(u8, operation, "supersede")) return "superseded";
    if (std.mem.eql(u8, operation, "delete") or std.mem.eql(u8, operation, "forget")) return "deprecated";
    return "proposed";
}

pub const OriginIdentity = struct {
    instance_id: []const u8,
    sequence: i64,
};

pub fn originIdentity(dedupe_key: ?[]const u8, fallback_instance_id: []const u8, fallback_sequence: i64) OriginIdentity {
    if (dedupe_key) |key| {
        if (parseOriginDedupeKey(key)) |origin| return origin;
    }
    return .{ .instance_id = fallback_instance_id, .sequence = fallback_sequence };
}

pub fn dedupeKeyFromObject(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !?[]const u8 {
    if (json.nullableStringField(obj, "dedupe_key")) |dedupe_key| return dedupe_key;
    const origin_instance_id = json.stringField(obj, "origin_instance_id") orelse
        json.stringField(obj, "source_instance_id") orelse
        json.stringField(obj, "instance_id") orelse
        return null;
    const origin_sequence = json.intField(obj, "origin_sequence") orelse
        json.intField(obj, "sequence") orelse
        json.intField(obj, "id") orelse
        return null;
    return try std.fmt.allocPrint(allocator, "origin:{s}:{d}", .{ origin_instance_id, origin_sequence });
}

pub const DedupeMatchInput = struct {
    event_type: []const u8,
    operation: []const u8,
    object_type: []const u8,
    object_id: ?[]const u8,
    scope: []const u8,
    permissions_json: []const u8,
    actor_id: []const u8,
    causality_json: []const u8,
    payload_json: []const u8,
};

pub fn dedupeMatches(event: anytype, input: DedupeMatchInput) bool {
    if (!std.mem.eql(u8, event.event_type, input.event_type)) return false;
    if (!std.mem.eql(u8, event.operation, input.operation)) return false;
    if (!std.mem.eql(u8, event.object_type, input.object_type)) return false;
    const origin_replay = if (event.dedupe_key) |key| std.mem.startsWith(u8, key, "origin:") else false;
    if (!origin_replay) {
        if (input.object_id) |expected_object_id| {
            if (!std.mem.eql(u8, event.object_id, expected_object_id)) return false;
        }
    }
    if (!std.mem.eql(u8, event.scope, input.scope)) return false;
    if (!std.mem.eql(u8, event.permissions_json, input.permissions_json)) return false;
    if (event.actor_id == null or !std.mem.eql(u8, event.actor_id.?, input.actor_id)) return false;
    if (!std.mem.eql(u8, event.causality_json, input.causality_json)) return false;
    if (!std.mem.eql(u8, event.payload_json, input.payload_json)) return false;
    return true;
}

pub fn eventScope(allocator: std.mem.Allocator, obj: std.json.ObjectMap, object_type: []const u8, payload_json: []const u8, event_actor_id: []const u8) ![]const u8 {
    if (json.stringField(obj, "scope")) |scope| return allocator.dupe(u8, scope);
    const payload = try std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{});
    defer payload.deinit();
    if (payload.value == .object) {
        if (json.stringField(payload.value.object, "scope")) |scope| return allocator.dupe(u8, scope);
        if (std.mem.eql(u8, object_type, "policy_scope")) {
            if (json.stringField(obj, "object_id")) |scope| return allocator.dupe(u8, scope);
        }
        if (isAgentSessionObject(object_type)) {
            const session_id = json.stringField(payload.value.object, "session_id") orelse {
                if (json.boolField(payload.value.object, "delete_autosaved") orelse json.boolField(payload.value.object, "autosave_only") orelse false) return allocator.dupe(u8, "session:*");
                return error.InvalidPayload;
            };
            return std.fmt.allocPrint(allocator, "session:{s}", .{session_id});
        }
    }
    if (!std.mem.eql(u8, object_type, "agent_memory")) return allocator.dupe(u8, "workspace");
    return domain.defaultAgentMemoryScope(allocator, event_actor_id);
}

pub fn eventPermissions(allocator: std.mem.Allocator, obj: std.json.ObjectMap, object_type: []const u8, payload_json: []const u8, event_actor_id: []const u8) ![]const u8 {
    if (obj.get("permissions")) |value| {
        if (value == .null) return allocator.dupe(u8, "[]");
        return try json.jsonFromValue(allocator, value);
    }
    const payload = try std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{});
    defer payload.deinit();
    if (payload.value == .object) {
        if (payload.value.object.get("permissions")) |value| {
            if (value == .null) return allocator.dupe(u8, "[]");
            return try json.jsonFromValue(allocator, value);
        }
    }
    if (isAgentSessionObject(object_type)) return domain.actorGrantJson(allocator, event_actor_id);
    return allocator.dupe(u8, "[]");
}

pub fn parseOriginDedupeKey(dedupe_key: []const u8) ?OriginIdentity {
    const prefix = "origin:";
    if (!std.mem.startsWith(u8, dedupe_key, prefix)) return null;
    const value = dedupe_key[prefix.len..];
    const split = std.mem.lastIndexOfScalar(u8, value, ':') orelse return null;
    if (split == 0 or split + 1 >= value.len) return null;
    const sequence = std.fmt.parseInt(i64, value[split + 1 ..], 10) catch return null;
    if (sequence < 0) return null;
    return .{ .instance_id = value[0..split], .sequence = sequence };
}

pub fn timestampMsFromCausality(allocator: std.mem.Allocator, causality_json: []const u8, fallback_ms: i64) !i64 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, causality_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return fallback_ms,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return fallback_ms;
    return json.intField(parsed.value.object, "origin_timestamp_ms") orelse
        json.intField(parsed.value.object, "timestamp_ms") orelse
        fallback_ms;
}

pub fn wireOperation(object_type: []const u8, operation: []const u8, nullclaw_agent_memory_mode: bool) []const u8 {
    if (nullclaw_agent_memory_mode and std.mem.eql(u8, object_type, "agent_memory")) {
        if (std.mem.eql(u8, operation, "delete") or std.mem.eql(u8, operation, "forget")) return "delete_scoped";
    }
    return operation;
}

pub fn referenceObjectType(value: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, value, "src_")) return "source";
    if (std.mem.startsWith(u8, value, "art_")) return "artifact";
    if (std.mem.startsWith(u8, value, "mem_")) return "memory_atom";
    if (std.mem.startsWith(u8, value, "ent_")) return "entity";
    if (std.mem.startsWith(u8, value, "rel_")) return "relation";
    if (std.mem.startsWith(u8, value, "ctx_")) return "context_pack";
    if (std.mem.startsWith(u8, value, "spc_")) return "space";
    return null;
}

pub fn agentMemoryPayloadIsInternal(allocator: std.mem.Allocator, payload_json: []const u8) !bool {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const key = json.stringField(parsed.value.object, "key") orelse "";
    const content = json.stringField(parsed.value.object, "content") orelse
        json.stringField(parsed.value.object, "text") orelse
        json.stringField(parsed.value.object, "value") orelse "";
    return domain.isInternalMemoryEntryKeyOrContent(key, content);
}

pub fn agentSessionMessagePayloadIsInternal(allocator: std.mem.Allocator, payload_json: []const u8) !bool {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const role = json.stringField(parsed.value.object, "role") orelse return false;
    return domain.isRuntimeCommandRole(role);
}

pub fn redactedPayload() []const u8 {
    return "{\"redacted\":true,\"reason\":\"inaccessible_payload_reference\"}";
}

pub fn payloadIsRedacted(allocator: std.mem.Allocator, payload_json: []const u8) !bool {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    return json.boolField(parsed.value.object, "redacted") orelse false;
}

pub fn payloadReferencesVisible(allocator: std.mem.Allocator, payload_json: []const u8, context: anytype, comptime referenceVisible: anytype) !bool {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return true,
    };
    defer parsed.deinit();
    return try valueReferencesVisible(parsed.value, context, referenceVisible);
}

fn valueReferencesVisible(value: std.json.Value, context: anytype, comptime referenceVisible: anytype) !bool {
    return switch (value) {
        .string => |s| blk: {
            const object_type = referenceObjectType(s) orelse break :blk true;
            break :blk try referenceVisible(context, object_type, s);
        },
        .array => |arr| {
            for (arr.items) |item| {
                if (!try valueReferencesVisible(item, context, referenceVisible)) return false;
            }
            return true;
        },
        .object => |obj| {
            var iterator = obj.iterator();
            while (iterator.next()) |entry| {
                if (!try valueReferencesVisible(entry.value_ptr.*, context, referenceVisible)) return false;
            }
            return true;
        },
        else => true,
    };
}

pub fn appendAgentMemoryCompatFields(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), object_type: []const u8, object_id: []const u8, payload_json: []const u8, wire_operation: []const u8) !void {
    if (!std.mem.eql(u8, object_type, "agent_memory")) return;
    if (try payloadIsRedacted(allocator, payload_json)) return appendNullAgentMemoryCompatFields(allocator, out);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{}) catch return appendNullAgentMemoryCompatFields(allocator, out);
    defer parsed.deinit();
    if (parsed.value != .object) return appendNullAgentMemoryCompatFields(allocator, out);

    const payload_obj = parsed.value.object;
    try out.appendSlice(allocator, ",\"key\":");
    if (json.stringField(payload_obj, "key")) |key| {
        try json.appendString(out, allocator, key);
    } else {
        try json.appendString(out, allocator, object_id);
    }
    try out.appendSlice(allocator, ",\"session_id\":");
    try json.appendNullableString(out, allocator, json.nullableStringField(payload_obj, "session_id"));
    try out.appendSlice(allocator, ",\"category\":");
    try json.appendNullableString(out, allocator, json.nullableStringField(payload_obj, "category"));
    try out.appendSlice(allocator, ",\"value_kind\":");
    try json.appendNullableString(out, allocator, agentMemoryCompatValueKind(payload_obj, wire_operation));
    try out.appendSlice(allocator, ",\"content\":");
    try appendAgentMemoryCompatContent(allocator, out, payload_obj, wire_operation);
}

fn appendNullAgentMemoryCompatFields(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    try out.appendSlice(allocator, ",\"key\":null,\"session_id\":null,\"category\":null,\"value_kind\":null,\"content\":null");
}

fn agentMemoryCompatValueKind(payload_obj: std.json.ObjectMap, operation: []const u8) ?[]const u8 {
    if (json.stringField(payload_obj, "value_kind")) |value_kind| return value_kind;
    if (std.mem.eql(u8, operation, "merge_string_set")) return "string_set";
    if (std.mem.eql(u8, operation, "merge_object")) return "json_object";
    return null;
}

fn appendAgentMemoryCompatContent(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), payload_obj: std.json.ObjectMap, operation: []const u8) !void {
    if (std.mem.eql(u8, operation, "merge_string_set")) {
        if (payload_obj.get("values")) |values| return appendJsonValueAsString(allocator, out, values);
        if (payload_obj.get("value")) |value| return appendJsonValueAsString(allocator, out, value);
    } else if (std.mem.eql(u8, operation, "merge_object")) {
        if (payload_obj.get("object")) |object| return appendJsonValueAsString(allocator, out, object);
        if (payload_obj.get("value")) |value| return appendJsonValueAsString(allocator, out, value);
    } else {
        if (json.stringField(payload_obj, "content")) |content| return json.appendString(out, allocator, content);
        if (json.stringField(payload_obj, "text")) |text| return json.appendString(out, allocator, text);
        if (payload_obj.get("value")) |value| return appendJsonValueAsString(allocator, out, value);
    }
    try out.appendSlice(allocator, "null");
}

fn appendJsonValueAsString(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), value: std.json.Value) !void {
    const text = try json.jsonFromValue(allocator, value);
    defer allocator.free(text);
    try json.appendString(out, allocator, text);
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

test "feed object and reference classification is centralized" {
    try std.testing.expect(objectTypeHasVisibleBackingRecord("source"));
    try std.testing.expect(objectTypeHasVisibleBackingRecord("context_pack"));
    try std.testing.expect(objectTypeHasVisibleBackingRecord("agent_memory"));
    try std.testing.expect(!objectTypeHasVisibleBackingRecord("space"));
    try std.testing.expect(objectTypeSupported("agent_session_message"));
    try std.testing.expect(objectTypeSupported("policy_scope"));
    try std.testing.expect(!objectTypeSupported("unknown"));
    try std.testing.expect(isAgentSessionObject("agent_session_usage"));
    try std.testing.expect(objectTypeUsesAgentMemoryStorageRoute("agent_memory"));
    try std.testing.expect(objectTypeUsesAgentMemoryStorageRoute("agent_session_message"));
    try std.testing.expect(objectTypeUsesKnowledgeStorageRoute("memory_atom"));
    try std.testing.expect(objectTypeUsesKnowledgeStorageRoute("context_pack"));
    try std.testing.expect(lifecycleUsesOverlay("policy_scope"));
    try std.testing.expect(!lifecycleUsesOverlay("artifact"));
    try std.testing.expectEqualStrings("source", referenceObjectType("src_123").?);
    try std.testing.expectEqualStrings("artifact", referenceObjectType("art_123").?);
    try std.testing.expectEqualStrings("memory_atom", referenceObjectType("mem_123").?);
    try std.testing.expectEqualStrings("entity", referenceObjectType("ent_123").?);
    try std.testing.expectEqualStrings("relation", referenceObjectType("rel_123").?);
    try std.testing.expectEqualStrings("context_pack", referenceObjectType("ctx_123").?);
    try std.testing.expectEqualStrings("space", referenceObjectType("spc_123").?);
    try std.testing.expect(referenceObjectType("unknown_123") == null);
}

test "feed operation inference and lifecycle status are centralized" {
    try std.testing.expectEqualStrings("delete_all", operationFromEventType("agent_memory.delete_all"));
    try std.testing.expectEqualStrings("delete_scoped", operationFromEventType("agent_memory_delete_scoped"));
    try std.testing.expectEqualStrings("delete", operationFromEventType("memory_atom.forget"));
    try std.testing.expectEqualStrings("verify", operationFromEventType("agent_memory.verify"));
    try std.testing.expectEqualStrings("mark_stale", operationFromEventType("agent_memory_mark_stale"));
    try std.testing.expectEqualStrings("stale", operationFromEventType("agent_memory.stale"));
    try std.testing.expectEqualStrings("supersede", operationFromEventType("agent_memory_supersede"));
    try std.testing.expectEqualStrings("delete_autosaved", operationFromEventType("session.clear_autosaved"));
    try std.testing.expectEqualStrings("merge_object", operationFromEventType("agent_memory.merge_object"));
    try std.testing.expectEqualStrings("merge_string_set", operationFromEventType("agent_memory_merge_string_set"));
    try std.testing.expectEqualStrings("put", operationFromEventType("memory_atom.upsert"));
    try std.testing.expect(isLifecycleOperation("verify"));
    try std.testing.expect(isLifecycleOperation("supersede"));
    try std.testing.expect(!isLifecycleOperation("merge_object"));

    const allocator = std.testing.allocator;
    var empty = try std.json.parseFromSlice(std.json.Value, allocator, "{}", .{});
    defer empty.deinit();
    try std.testing.expectEqualStrings("verified", statusFromLifecycleOperation("verify", empty.value.object));
    try std.testing.expectEqualStrings("stale", statusFromLifecycleOperation("mark_stale", empty.value.object));
    try std.testing.expectEqualStrings("superseded", statusFromLifecycleOperation("supersede", empty.value.object));
    try std.testing.expectEqualStrings("deprecated", statusFromLifecycleOperation("forget", empty.value.object));
    try std.testing.expectEqualStrings("proposed", statusFromLifecycleOperation("put", empty.value.object));

    var override = try std.json.parseFromSlice(std.json.Value, allocator, "{\"status\":\"accepted\"}", .{});
    defer override.deinit();
    try std.testing.expectEqualStrings("accepted", statusFromLifecycleOperation("verify", override.value.object));
}

test "feed wire metadata helpers are centralized" {
    const parsed = parseOriginDedupeKey("origin:agent:a:42").?;
    try std.testing.expectEqualStrings("agent:a", parsed.instance_id);
    try std.testing.expectEqual(@as(i64, 42), parsed.sequence);
    try std.testing.expect(parseOriginDedupeKey("origin::42") == null);
    try std.testing.expect(parseOriginDedupeKey("origin:agent:-1") == null);
    try std.testing.expect(parseOriginDedupeKey("direct:feed:42") == null);

    const fallback = originIdentity(null, "local", 7);
    try std.testing.expectEqualStrings("local", fallback.instance_id);
    try std.testing.expectEqual(@as(i64, 7), fallback.sequence);

    const replay = originIdentity("origin:remote:99", "local", 7);
    try std.testing.expectEqualStrings("remote", replay.instance_id);
    try std.testing.expectEqual(@as(i64, 99), replay.sequence);

    const allocator = std.testing.allocator;
    try std.testing.expectEqual(@as(i64, 123), try timestampMsFromCausality(allocator, "{\"origin_timestamp_ms\":123,\"timestamp_ms\":456}", 9));
    try std.testing.expectEqual(@as(i64, 456), try timestampMsFromCausality(allocator, "{\"timestamp_ms\":456}", 9));
    try std.testing.expectEqual(@as(i64, 9), try timestampMsFromCausality(allocator, "not json", 9));

    try std.testing.expectEqualStrings("delete_scoped", wireOperation("agent_memory", "delete", true));
    try std.testing.expectEqualStrings("delete_scoped", wireOperation("agent_memory", "forget", true));
    try std.testing.expectEqualStrings("delete", wireOperation("agent_memory", "delete", false));
    try std.testing.expectEqualStrings("delete", wireOperation("memory_atom", "delete", true));
}

const TestFeedEvent = struct {
    event_type: []const u8 = "memory_atom.upsert",
    operation: []const u8 = "put",
    object_type: []const u8 = "memory_atom",
    object_id: []const u8 = "mem_1",
    scope: []const u8 = "public",
    permissions_json: []const u8 = "[]",
    actor_id: ?[]const u8 = "agent:a",
    causality_json: []const u8 = "{}",
    payload_json: []const u8 = "{\"text\":\"hello\"}",
    dedupe_key: ?[]const u8 = "direct:event:1",
};

fn testDedupeInput() DedupeMatchInput {
    return .{
        .event_type = "memory_atom.upsert",
        .operation = "put",
        .object_type = "memory_atom",
        .object_id = "mem_1",
        .scope = "public",
        .permissions_json = "[]",
        .actor_id = "agent:a",
        .causality_json = "{}",
        .payload_json = "{\"text\":\"hello\"}",
    };
}

test "feed dedupe key and match semantics are centralized" {
    const allocator = std.testing.allocator;

    var explicit = try std.json.parseFromSlice(std.json.Value, allocator, "{\"dedupe_key\":\"evt-1\",\"origin_instance_id\":\"ignored\",\"origin_sequence\":2}", .{});
    defer explicit.deinit();
    try std.testing.expectEqualStrings("evt-1", (try dedupeKeyFromObject(allocator, explicit.value.object)).?);

    var origin = try std.json.parseFromSlice(std.json.Value, allocator, "{\"origin_instance_id\":\"agent:a\",\"origin_sequence\":42}", .{});
    defer origin.deinit();
    const origin_key = (try dedupeKeyFromObject(allocator, origin.value.object)).?;
    defer allocator.free(origin_key);
    try std.testing.expectEqualStrings("origin:agent:a:42", origin_key);

    var source_alias = try std.json.parseFromSlice(std.json.Value, allocator, "{\"source_instance_id\":\"agent:b\",\"sequence\":7}", .{});
    defer source_alias.deinit();
    const alias_key = (try dedupeKeyFromObject(allocator, source_alias.value.object)).?;
    defer allocator.free(alias_key);
    try std.testing.expectEqualStrings("origin:agent:b:7", alias_key);

    var missing = try std.json.parseFromSlice(std.json.Value, allocator, "{\"event_type\":\"memory_atom.upsert\"}", .{});
    defer missing.deinit();
    try std.testing.expect((try dedupeKeyFromObject(allocator, missing.value.object)) == null);

    try std.testing.expect(dedupeMatches(TestFeedEvent{}, testDedupeInput()));
    var changed_object = testDedupeInput();
    changed_object.object_id = "mem_2";
    try std.testing.expect(!dedupeMatches(TestFeedEvent{}, changed_object));
    try std.testing.expect(dedupeMatches(TestFeedEvent{ .dedupe_key = "origin:remote:1" }, changed_object));
    var changed_payload = testDedupeInput();
    changed_payload.payload_json = "{\"text\":\"changed\"}";
    try std.testing.expect(!dedupeMatches(TestFeedEvent{}, changed_payload));
    try std.testing.expect(!dedupeMatches(TestFeedEvent{ .actor_id = null }, testDedupeInput()));
}

test "feed event scope and permissions defaults are centralized" {
    const allocator = std.testing.allocator;

    var explicit = try std.json.parseFromSlice(std.json.Value, allocator, "{\"scope\":\"team:null\",\"permissions\":[\"team:null\"]}", .{});
    defer explicit.deinit();
    const explicit_scope = try eventScope(allocator, explicit.value.object, "memory_atom", "{}", "agent:a");
    defer allocator.free(explicit_scope);
    try std.testing.expectEqualStrings("team:null", explicit_scope);
    const explicit_permissions = try eventPermissions(allocator, explicit.value.object, "memory_atom", "{}", "agent:a");
    defer allocator.free(explicit_permissions);
    try std.testing.expectEqualStrings("[\"team:null\"]", explicit_permissions);

    var empty = try std.json.parseFromSlice(std.json.Value, allocator, "{}", .{});
    defer empty.deinit();
    const source_scope = try eventScope(allocator, empty.value.object, "source", "{}", "agent:a");
    defer allocator.free(source_scope);
    try std.testing.expectEqualStrings("workspace", source_scope);
    const agent_scope = try eventScope(allocator, empty.value.object, "agent_memory", "{}", "agent:a");
    defer allocator.free(agent_scope);
    try std.testing.expectEqualStrings("agent:agent:a", agent_scope);

    const session_scope = try eventScope(allocator, empty.value.object, "agent_session_message", "{\"session_id\":\"s1\"}", "agent:a");
    defer allocator.free(session_scope);
    try std.testing.expectEqualStrings("session:s1", session_scope);
    const autosave_scope = try eventScope(allocator, empty.value.object, "agent_session_message", "{\"delete_autosaved\":true}", "agent:a");
    defer allocator.free(autosave_scope);
    try std.testing.expectEqualStrings("session:*", autosave_scope);
    try std.testing.expectError(error.InvalidPayload, eventScope(allocator, empty.value.object, "agent_session_message", "{\"content\":\"missing session\"}", "agent:a"));

    var policy = try std.json.parseFromSlice(std.json.Value, allocator, "{\"object_id\":\"project:null\"}", .{});
    defer policy.deinit();
    const policy_scope = try eventScope(allocator, policy.value.object, "policy_scope", "{}", "agent:a");
    defer allocator.free(policy_scope);
    try std.testing.expectEqualStrings("project:null", policy_scope);

    const session_permissions = try eventPermissions(allocator, empty.value.object, "agent_session_usage", "{}", "agent:a");
    defer allocator.free(session_permissions);
    try std.testing.expectEqualStrings("[\"actor:agent:a\"]", session_permissions);
    const source_permissions = try eventPermissions(allocator, empty.value.object, "source", "{}", "agent:a");
    defer allocator.free(source_permissions);
    try std.testing.expectEqualStrings("[]", source_permissions);
}

test "agent memory payload internal detection covers feed payload variants" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try agentMemoryPayloadIsInternal(allocator, "{\"key\":\"autosave_user_1\"}"));
    try std.testing.expect(try agentMemoryPayloadIsInternal(allocator, "{\"content\":\"**autosave_assistant_1**: internal\"}"));
    try std.testing.expect(try agentMemoryPayloadIsInternal(allocator, "{\"text\":\"**last_hygiene_at**: 123\"}"));
    try std.testing.expect(try agentMemoryPayloadIsInternal(allocator, "{\"value\":\"**autosave_user_2**: internal\"}"));
    try std.testing.expect(!try agentMemoryPayloadIsInternal(allocator, "{\"key\":\"preference\",\"content\":\"Use concise docs\"}"));
    try std.testing.expect(!try agentMemoryPayloadIsInternal(allocator, "not json"));
}

test "agent session message payload internal detection is centralized" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try agentSessionMessagePayloadIsInternal(allocator, "{\"role\":\"__runtime_command__\",\"content\":\"sync\"}"));
    try std.testing.expect(!try agentSessionMessagePayloadIsInternal(allocator, "{\"role\":\"user\",\"content\":\"normal message\"}"));
    try std.testing.expect(!try agentSessionMessagePayloadIsInternal(allocator, "{\"content\":\"missing role\"}"));
    try std.testing.expect(!try agentSessionMessagePayloadIsInternal(allocator, "not json"));
}

test "feed redaction marker is a top-level contract" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try payloadIsRedacted(allocator, redactedPayload()));
    try std.testing.expect(!try payloadIsRedacted(allocator, "{\"metadata\":{\"redacted\":true},\"content\":\"visible\"}"));
    try std.testing.expect(!try payloadIsRedacted(allocator, "{\"content\":\"\\\"redacted\\\":true\"}"));
    try std.testing.expect(!try payloadIsRedacted(allocator, "not json"));
}

const TestReferenceVisibility = struct {
    hidden_type: []const u8,
};

fn testReferenceVisible(input: TestReferenceVisibility, object_type: []const u8, value: []const u8) !bool {
    _ = value;
    return !std.mem.eql(u8, object_type, input.hidden_type);
}

test "payload reference traversal is centralized" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try payloadReferencesVisible(allocator, "{\"refs\":[\"src_1\",{\"nested\":\"mem_1\"}],\"unknown\":\"note_1\"}", TestReferenceVisibility{ .hidden_type = "artifact" }, testReferenceVisible));
    try std.testing.expect(!try payloadReferencesVisible(allocator, "{\"refs\":[\"src_1\",{\"nested\":\"art_1\"}]}", TestReferenceVisibility{ .hidden_type = "artifact" }, testReferenceVisible));
    try std.testing.expect(try payloadReferencesVisible(allocator, "not json", TestReferenceVisibility{ .hidden_type = "source" }, testReferenceVisible));
}

test "agent memory compat fields are emitted by feed contract" {
    const allocator = std.testing.allocator;

    var non_agent: std.ArrayListUnmanaged(u8) = .empty;
    defer non_agent.deinit(allocator);
    try appendAgentMemoryCompatFields(allocator, &non_agent, "memory_atom", "mem_1", "{}", "put");
    try std.testing.expectEqual(@as(usize, 0), non_agent.items.len);

    var redacted: std.ArrayListUnmanaged(u8) = .empty;
    defer redacted.deinit(allocator);
    try appendAgentMemoryCompatFields(allocator, &redacted, "agent_memory", "ami_1", redactedPayload(), "put");
    try std.testing.expect(std.mem.indexOf(u8, redacted.items, "\"key\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, redacted.items, "\"content\":null") != null);

    var put: std.ArrayListUnmanaged(u8) = .empty;
    defer put.deinit(allocator);
    try appendAgentMemoryCompatFields(allocator, &put, "agent_memory", "ami_fallback", "{\"session_id\":\"s1\",\"category\":\"core\",\"content\":\"hello\"}", "put");
    try std.testing.expect(std.mem.indexOf(u8, put.items, "\"key\":\"ami_fallback\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, put.items, "\"session_id\":\"s1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, put.items, "\"category\":\"core\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, put.items, "\"value_kind\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, put.items, "\"content\":\"hello\"") != null);

    var merge_set: std.ArrayListUnmanaged(u8) = .empty;
    defer merge_set.deinit(allocator);
    try appendAgentMemoryCompatFields(allocator, &merge_set, "agent_memory", "ami_tags", "{\"key\":\"api.tags\",\"values\":[\"zig\"]}", "merge_string_set");
    try std.testing.expect(std.mem.indexOf(u8, merge_set.items, "\"key\":\"api.tags\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, merge_set.items, "\"value_kind\":\"string_set\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, merge_set.items, "\"content\":\"[\\\"zig\\\"]\"") != null);

    var merge_object: std.ArrayListUnmanaged(u8) = .empty;
    defer merge_object.deinit(allocator);
    try appendAgentMemoryCompatFields(allocator, &merge_object, "agent_memory", "ami_profile", "{\"object\":{\"theme\":\"dark\"}}", "merge_object");
    try std.testing.expect(std.mem.indexOf(u8, merge_object.items, "\"value_kind\":\"json_object\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, merge_object.items, "\"content\":\"{\\\"theme\\\":\\\"dark\\\"}\"") != null);
}
