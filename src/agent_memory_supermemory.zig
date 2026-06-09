const std = @import("std");

const access = @import("access.zig");
const domain = @import("domain.zig");
const ids = @import("ids.zig");
const json = @import("json_util.zig");
const vendor = @import("agent_memory_vendor.zig");
const api_profiles = @import("agent_memory_api_profiles.zig");

pub const is_compiled = true;

pub const default_base_url = api_profiles.supermemory_default_base_url;

const store_name = "supermemory";

pub const WriteInput = struct {
    key: []const u8,
    content: []const u8,
    category: []const u8 = "core",
    session_id: ?[]const u8 = null,
    owner_actor_id: []const u8,
    writer_actor_id: []const u8,
    requested_scope: ?[]const u8 = null,
    requested_permissions_json: []const u8 = "[]",
    metadata_json: ?[]const u8 = null,
    timestamp_ms: i64,
    status: []const u8 = "proposed",
    remote_id: ?[]const u8 = null,
};

pub const VisibleContainerTags = struct {
    tags: std.ArrayListUnmanaged([]u8) = .empty,
    use_global_scan: bool = false,

    pub fn deinit(self: *VisibleContainerTags, allocator: std.mem.Allocator) void {
        for (self.tags.items) |tag| allocator.free(tag);
        self.tags.deinit(allocator);
    }
};

pub fn documentPayload(allocator: std.mem.Allocator, input: WriteInput) ![]u8 {
    const scope = try access.agentMemoryScope(allocator, input.owner_actor_id, input.session_id, input.requested_scope);
    defer allocator.free(scope);
    const tag = try containerTag(allocator, scope, input.owner_actor_id);
    defer allocator.free(tag);
    const id = try customId(allocator, input.owner_actor_id, input.session_id, input.key);
    defer allocator.free(id);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"content\":");
    try json.appendString(&out, allocator, input.content);
    try out.appendSlice(allocator, ",\"customId\":");
    try json.appendString(&out, allocator, id);
    try out.appendSlice(allocator, ",\"containerTag\":");
    try json.appendString(&out, allocator, tag);
    try out.appendSlice(allocator, ",\"metadata\":");
    try appendMetadataObject(&out, allocator, input);
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

pub fn searchPayload(allocator: std.mem.Allocator, query_text: []const u8, limit: usize, container_tag: ?[]const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"q\":");
    try json.appendString(&out, allocator, if (query_text.len > 0) query_text else "nullpantry");
    try out.print(allocator, ",\"searchMode\":\"hybrid\",\"limit\":{d}", .{@max(limit, 1)});
    if (container_tag) |tag| {
        try out.appendSlice(allocator, ",\"containerTag\":");
        try json.appendString(&out, allocator, tag);
    }
    try out.appendSlice(allocator, ",\"filters\":{\"AND\":[{\"key\":\"nullpantry_backend\",\"value\":\"supermemory\"},{\"key\":\"nullpantry_type\",\"value\":\"agent_memory\"}]}}");
    return out.toOwnedSlice(allocator);
}

pub fn documentPath(allocator: std.mem.Allocator, id: []const u8) ![]u8 {
    const encoded = try vendor.percentEncode(allocator, id);
    defer allocator.free(encoded);
    return std.fmt.allocPrint(allocator, "/v3/documents/{s}", .{encoded});
}

pub fn agentMemoryFromWriteInput(allocator: std.mem.Allocator, input: WriteInput, response_body: []const u8) !domain.AgentMemory {
    const scope = try access.agentMemoryScope(allocator, input.owner_actor_id, input.session_id, input.requested_scope);
    defer allocator.free(scope);
    const permissions = try access.agentMemoryPermissions(allocator, input.owner_actor_id, input.requested_scope, input.requested_permissions_json);
    defer allocator.free(permissions);
    const fallback_id = try customId(allocator, input.owner_actor_id, input.session_id, input.key);
    defer allocator.free(fallback_id);
    const parsed_remote_id = try responseId(allocator, response_body);
    defer if (parsed_remote_id) |remote_id| allocator.free(remote_id);
    const remote_id = input.remote_id orelse parsed_remote_id orelse fallback_id;

    var entry = domain.AgentMemory{
        .id = "",
        .key = "",
        .content = "",
        .category = "",
        .timestamp = "",
        .session_id = null,
        .actor_id = "",
        .scope = "",
    };
    errdefer vendor.freeAgentMemory(allocator, &entry);

    entry.id = try allocator.dupe(u8, remote_id);
    entry.key = try allocator.dupe(u8, input.key);
    entry.content = try allocator.dupe(u8, input.content);
    entry.category = try allocator.dupe(u8, input.category);
    entry.timestamp = try std.fmt.allocPrint(allocator, "{d}", .{input.timestamp_ms});
    entry.session_id = if (input.session_id) |sid| try allocator.dupe(u8, sid) else null;
    entry.actor_id = try allocator.dupe(u8, input.owner_actor_id);
    entry.writer_actor_id = try allocator.dupe(u8, input.writer_actor_id);
    entry.scope = try allocator.dupe(u8, scope);
    entry.permissions_json = try allocator.dupe(u8, permissions);
    entry.status = try allocator.dupe(u8, input.status);
    entry.store = try allocator.dupe(u8, store_name);
    return entry;
}

pub fn responseId(allocator: std.mem.Allocator, body: []const u8) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const remote_id = vendor.stringishField(parsed.value.object, &.{ "id", "documentId", "memoryId", "customId" }) orelse return null;
    return try allocator.dupe(u8, remote_id);
}

pub fn agentMemoryFromBody(allocator: std.mem.Allocator, body: []const u8, actor_id: []const u8, scopes_json: []const u8, exact_key: ?[]const u8, session_id_filter: ?[]const u8, include_sessions: bool) !?domain.AgentMemory {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.AgentMemoryStorageUnavailable;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    if (parsed.value.object.get("document")) |document| return agentMemoryFromValue(allocator, document, actor_id, scopes_json, exact_key, session_id_filter, include_sessions);
    if (parsed.value.object.get("memory")) |memory| {
        if (memory == .object) return agentMemoryFromValue(allocator, memory, actor_id, scopes_json, exact_key, session_id_filter, include_sessions);
    }
    return agentMemoryFromValue(allocator, parsed.value, actor_id, scopes_json, exact_key, session_id_filter, include_sessions);
}

pub fn agentMemoryArrayFromBody(allocator: std.mem.Allocator, body: []const u8, actor_id: []const u8, scopes_json: []const u8, exact_key: ?[]const u8, session_id_filter: ?[]const u8, include_sessions: bool) ![]domain.AgentMemory {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.AgentMemoryStorageUnavailable;
    defer parsed.deinit();
    var out: std.ArrayListUnmanaged(domain.AgentMemory) = .empty;
    errdefer {
        for (out.items) |*entry| vendor.freeAgentMemory(allocator, entry);
        out.deinit(allocator);
    }
    try appendAgentMemoriesFromValue(allocator, &out, parsed.value, actor_id, scopes_json, exact_key, session_id_filter, include_sessions);
    retainActiveAgentMemories(allocator, &out);
    return out.toOwnedSlice(allocator);
}

pub fn appendUniqueAgentMemory(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(domain.AgentMemory), entry: domain.AgentMemory) !void {
    var candidate = entry;
    errdefer vendor.freeAgentMemory(allocator, &candidate);
    for (out.items) |*existing| {
        if (std.mem.eql(u8, existing.id, candidate.id) or sameLogicalMemory(existing.*, candidate)) {
            if (timestampRank(candidate) >= timestampRank(existing.*)) {
                vendor.freeAgentMemory(allocator, existing);
                existing.* = candidate;
                vendor.detachAgentMemory(&candidate);
            } else {
                vendor.freeAgentMemory(allocator, &candidate);
            }
            return;
        }
    }
    try out.append(allocator, candidate);
    vendor.detachAgentMemory(&candidate);
}

pub fn customId(allocator: std.mem.Allocator, owner_actor_id: []const u8, session_id: ?[]const u8, key: []const u8) ![]u8 {
    var hash_value = std.hash.Wyhash.hash(0x9fb4_2d73_7d36_4e1b, owner_actor_id);
    hash_value = std.hash.Wyhash.hash(hash_value, session_id orelse "");
    hash_value = std.hash.Wyhash.hash(hash_value, key);
    return std.fmt.allocPrint(allocator, "np-{x}", .{hash_value});
}

pub fn visibleContainerTags(allocator: std.mem.Allocator, actor_id: []const u8, scopes_json: []const u8) !VisibleContainerTags {
    var owners = try vendor.visibleOwners(allocator, actor_id, scopes_json);
    defer owners.deinit(allocator);
    var out = VisibleContainerTags{ .use_global_scan = owners.requires_global_scan };
    errdefer out.deinit(allocator);
    if (owners.requires_global_scan) return out;
    for (owners.owners.items) |owner| {
        const scope = vendor.sharedScopeFromOwner(owner) orelse owner;
        const tag = try sanitizeTag(allocator, scope);
        var duplicate = false;
        for (out.tags.items) |existing| {
            if (std.mem.eql(u8, existing, tag)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) {
            allocator.free(tag);
        } else {
            try out.tags.append(allocator, tag);
        }
    }
    return out;
}

fn appendMetadataObject(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, input: WriteInput) !void {
    const scope = try access.agentMemoryScope(allocator, input.owner_actor_id, input.session_id, input.requested_scope);
    defer allocator.free(scope);
    const permissions = try access.agentMemoryPermissions(allocator, input.owner_actor_id, input.requested_scope, input.requested_permissions_json);
    defer allocator.free(permissions);

    try out.appendSlice(allocator, "{\"nullpantry_backend\":\"supermemory\",\"nullpantry_type\":\"agent_memory\",\"nullpantry_key\":");
    try json.appendString(out, allocator, input.key);
    try out.appendSlice(allocator, ",\"nullpantry_content\":");
    try json.appendString(out, allocator, input.content);
    try out.appendSlice(allocator, ",\"nullpantry_category\":");
    try json.appendString(out, allocator, input.category);
    if (input.session_id) |sid| {
        try out.appendSlice(allocator, ",\"nullpantry_session_id\":");
        try json.appendString(out, allocator, sid);
    }
    try out.appendSlice(allocator, ",\"nullpantry_actor_id\":");
    try json.appendString(out, allocator, input.owner_actor_id);
    try out.appendSlice(allocator, ",\"nullpantry_writer_actor_id\":");
    try json.appendString(out, allocator, input.writer_actor_id);
    try out.appendSlice(allocator, ",\"nullpantry_scope\":");
    try json.appendString(out, allocator, scope);
    try out.appendSlice(allocator, ",\"nullpantry_permissions_json\":");
    try json.appendString(out, allocator, permissions);
    try out.appendSlice(allocator, ",\"nullpantry_status\":");
    try json.appendString(out, allocator, input.status);
    try out.print(allocator, ",\"nullpantry_timestamp_ms\":{d}", .{input.timestamp_ms});
    try out.appendSlice(allocator, ",\"nullpantry_metadata_json\":");
    const validated_metadata = try json.rawJsonObjectOrError(allocator, input.metadata_json, "{}");
    try json.appendString(out, allocator, validated_metadata);
    if (input.remote_id) |remote_id| {
        try out.appendSlice(allocator, ",\"nullpantry_remote_id\":");
        try json.appendString(out, allocator, remote_id);
    }
    try out.append(allocator, '}');
}

fn appendAgentMemoriesFromValue(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(domain.AgentMemory), value: std.json.Value, actor_id: []const u8, scopes_json: []const u8, exact_key: ?[]const u8, session_id_filter: ?[]const u8, include_sessions: bool) !void {
    switch (value) {
        .array => |items| {
            for (items.items) |item| try appendAgentMemoriesFromValue(allocator, out, item, actor_id, scopes_json, exact_key, session_id_filter, include_sessions);
        },
        .object => |obj| {
            if (try agentMemoryFromValue(allocator, value, actor_id, scopes_json, exact_key, session_id_filter, include_sessions)) |entry| {
                try appendUniqueAgentMemory(allocator, out, entry);
                return;
            }
            inline for ([_][]const u8{ "results", "memories", "documents", "data", "items", "memory", "document", "chunk", "result" }) |name| {
                if (obj.get(name)) |child| try appendAgentMemoriesFromValue(allocator, out, child, actor_id, scopes_json, exact_key, session_id_filter, include_sessions);
            }
        },
        else => {},
    }
}

fn agentMemoryFromValue(allocator: std.mem.Allocator, value: std.json.Value, actor_id: []const u8, scopes_json: []const u8, exact_key: ?[]const u8, session_id_filter: ?[]const u8, include_sessions: bool) !?domain.AgentMemory {
    if (value != .object) return null;
    const obj = value.object;
    const metadata_obj = metadataObject(obj) orelse return null;
    if (!std.mem.eql(u8, vendor.stringishField(metadata_obj, &.{"nullpantry_backend"}) orelse "", store_name)) return null;
    if (!std.mem.eql(u8, vendor.stringishField(metadata_obj, &.{"nullpantry_type"}) orelse "", "agent_memory")) return null;

    const key = vendor.stringishField(metadata_obj, &.{ "nullpantry_key", "key" }) orelse vendor.stringishField(obj, &.{ "customId", "id", "documentId", "memoryId" }) orelse return null;
    if (exact_key) |needle| {
        if (!std.mem.eql(u8, key, needle)) return null;
    }

    const candidate_session_id = optionalStringishField(metadata_obj, &.{"nullpantry_session_id"});
    if (session_id_filter) |sid| {
        if (candidate_session_id == null or !std.mem.eql(u8, candidate_session_id.?, sid)) return null;
    } else if (!include_sessions and candidate_session_id != null) {
        return null;
    }

    const content = vendor.stringishField(metadata_obj, &.{"nullpantry_content"}) orelse contentFromObject(obj) orelse return null;
    const owner = vendor.stringishField(metadata_obj, &.{ "nullpantry_actor_id", "actor_id", "owner_id" }) orelse actor_id;
    const writer = vendor.stringishField(metadata_obj, &.{ "nullpantry_writer_actor_id", "writer_actor_id", "created_by_actor_id" }) orelse owner;
    var owned_scope: ?[]const u8 = null;
    defer if (owned_scope) |scope| allocator.free(scope);
    const scope = vendor.stringishField(metadata_obj, &.{ "nullpantry_scope", "scope" }) orelse blk: {
        owned_scope = try domain.defaultAgentMemoryScope(allocator, owner);
        break :blk owned_scope.?;
    };
    const permissions_json = try permissionsJson(allocator, metadata_obj);
    errdefer allocator.free(permissions_json);
    const timestamp = try timestampString(allocator, obj, metadata_obj);
    errdefer allocator.free(timestamp);

    const entry = domain.AgentMemory{
        .id = try allocator.dupe(u8, vendor.stringishField(obj, &.{ "id", "documentId", "memoryId", "customId" }) orelse vendor.stringishField(metadata_obj, &.{"nullpantry_remote_id"}) orelse key),
        .key = try allocator.dupe(u8, key),
        .content = try allocator.dupe(u8, content),
        .category = try allocator.dupe(u8, vendor.stringishField(metadata_obj, &.{ "nullpantry_category", "category" }) orelse "core"),
        .timestamp = timestamp,
        .session_id = if (candidate_session_id) |sid| try allocator.dupe(u8, sid) else null,
        .actor_id = try allocator.dupe(u8, owner),
        .writer_actor_id = try allocator.dupe(u8, writer),
        .scope = try allocator.dupe(u8, scope),
        .permissions_json = permissions_json,
        .status = try allocator.dupe(u8, vendor.stringishField(metadata_obj, &.{ "nullpantry_status", "status" }) orelse "proposed"),
        .store = try allocator.dupe(u8, store_name),
        .score = scoreFromObject(obj),
    };
    errdefer {
        var cleanup = entry;
        vendor.freeAgentMemory(allocator, &cleanup);
    }
    if (!try vendor.entryVisible(allocator, entry, actor_id, scopes_json)) {
        var cleanup = entry;
        vendor.freeAgentMemory(allocator, &cleanup);
        return null;
    }
    return entry;
}

fn metadataObject(obj: std.json.ObjectMap) ?std.json.ObjectMap {
    if (vendor.objectField(obj, &.{"metadata"})) |metadata| return metadata;
    inline for ([_][]const u8{ "document", "memory", "chunk", "result" }) |name| {
        if (obj.get(name)) |child| {
            if (child == .object) {
                if (metadataObject(child.object)) |metadata| return metadata;
            }
        }
    }
    return null;
}

fn contentFromObject(obj: std.json.ObjectMap) ?[]const u8 {
    if (vendor.stringishField(obj, &.{ "content", "memory", "text", "chunk", "summary" })) |content| return content;
    inline for ([_][]const u8{ "document", "memory", "chunk", "result" }) |name| {
        if (obj.get(name)) |child| {
            if (child == .object) {
                if (contentFromObject(child.object)) |content| return content;
            } else if (child == .string) {
                return child.string;
            }
        }
    }
    if (obj.get("chunks")) |chunks| {
        if (chunks == .array and chunks.array.items.len > 0) {
            const first = chunks.array.items[0];
            if (first == .object) return contentFromObject(first.object);
            if (first == .string) return first.string;
        }
    }
    return null;
}

fn permissionsJson(allocator: std.mem.Allocator, metadata_obj: std.json.ObjectMap) ![]u8 {
    return vendor.permissionsJsonField(allocator, metadata_obj, "[]");
}

fn timestampString(allocator: std.mem.Allocator, obj: std.json.ObjectMap, metadata_obj: std.json.ObjectMap) ![]u8 {
    if (optionalI64Field(metadata_obj, "nullpantry_timestamp_ms")) |value| {
        return std.fmt.allocPrint(allocator, "{d}", .{value});
    }
    if (optionalI64Field(obj, "created_at_ms")) |value| {
        return std.fmt.allocPrint(allocator, "{d}", .{value});
    }
    if (optionalI64Field(obj, "updated_at_ms")) |value| {
        return std.fmt.allocPrint(allocator, "{d}", .{value});
    }
    return std.fmt.allocPrint(allocator, "{d}", .{ids.nowMs()});
}

fn optionalI64Field(obj: std.json.ObjectMap, name: []const u8) ?i64 {
    return vendor.optionalI64Field(obj, name);
}

fn optionalStringishField(obj: std.json.ObjectMap, names: []const []const u8) ?[]const u8 {
    const value = vendor.nullableStringishField(obj, names) orelse return null;
    if (value.len == 0) return null;
    return value;
}

fn scoreFromObject(obj: std.json.ObjectMap) ?f64 {
    inline for ([_][]const u8{ "score", "similarity", "relevance" }) |name| {
        if (obj.get(name)) |value| {
            if (vendor.valueAsF64(value)) |score| return score;
        }
    }
    inline for ([_][]const u8{ "memory", "chunk", "document", "result" }) |name| {
        if (obj.get(name)) |child| {
            if (child == .object) {
                if (scoreFromObject(child.object)) |score| return score;
            }
        }
    }
    return null;
}

fn containerTag(allocator: std.mem.Allocator, scope: []const u8, owner_actor_id: []const u8) ![]u8 {
    const raw = if (std.mem.startsWith(u8, scope, "session:"))
        owner_actor_id
    else if (vendor.sharedScopeFromOwner(owner_actor_id)) |shared|
        shared
    else if (std.mem.startsWith(u8, scope, "agent:"))
        owner_actor_id
    else
        scope;
    return sanitizeTag(allocator, raw);
}

fn sanitizeTag(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    if (raw.len == 0) return allocator.dupe(u8, "nullpantry");
    var buf: [100]u8 = undefined;
    var len: usize = 0;
    for (raw) |ch| {
        if (len >= buf.len) break;
        buf[len] = if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch == ':' or ch == '-') ch else '_';
        len += 1;
    }
    if (len == 0) return allocator.dupe(u8, "nullpantry");
    return allocator.dupe(u8, buf[0..len]);
}

fn sameLogicalMemory(a: domain.AgentMemory, b: domain.AgentMemory) bool {
    return std.mem.eql(u8, a.key, b.key) and
        std.mem.eql(u8, a.actor_id, b.actor_id) and
        vendor.sameOptionalString(a.session_id, b.session_id);
}

fn timestampRank(entry: domain.AgentMemory) i64 {
    return std.fmt.parseInt(i64, entry.timestamp, 10) catch 0;
}

fn retainActiveAgentMemories(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(domain.AgentMemory)) void {
    var write_index: usize = 0;
    for (out.items, 0..) |*entry, read_index| {
        if (isDeletedStatus(entry.status)) {
            vendor.freeAgentMemory(allocator, entry);
            continue;
        }
        if (write_index != read_index) {
            out.items[write_index] = entry.*;
            vendor.detachAgentMemory(entry);
        }
        write_index += 1;
    }
    out.shrinkRetainingCapacity(write_index);
}

fn isDeletedStatus(status: []const u8) bool {
    return std.mem.eql(u8, status, "deleted") or
        std.mem.eql(u8, status, "rejected") or
        std.mem.eql(u8, status, "deprecated");
}

test "supermemory document payload uses flat metadata and custom id" {
    const payload = try documentPayload(std.testing.allocator, .{
        .key = "pref.language",
        .content = "Prefer Zig examples",
        .category = "preference",
        .session_id = "session-1",
        .owner_actor_id = "shared:team:alpha",
        .writer_actor_id = "agent:a",
        .requested_scope = "team:alpha",
        .requested_permissions_json = "[\"team:alpha\"]",
        .metadata_json = "{\"source\":\"test\"}",
        .timestamp_ms = 42,
        .status = "verified",
    });
    defer std.testing.allocator.free(payload);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"customId\":\"np-") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"containerTag\":\"team:alpha\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"nullpantry_metadata_json\":\"{\\\"source\\\":\\\"test\\\"}\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"nullpantry_status\":\"verified\"") != null);
}

test "supermemory search payload supports scoped and global scans" {
    const scoped = try searchPayload(std.testing.allocator, "Zig", 10, "team:alpha");
    defer std.testing.allocator.free(scoped);
    try std.testing.expect(std.mem.indexOf(u8, scoped, "\"containerTag\":\"team:alpha\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, scoped, "\"filters\"") != null);

    const global = try searchPayload(std.testing.allocator, "Zig", 10, null);
    defer std.testing.allocator.free(global);
    try std.testing.expect(std.mem.indexOf(u8, global, "\"containerTag\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, global, "\"filters\"") != null);
}

test "supermemory visible container tags distinguish scoped and global scans" {
    var scoped = try visibleContainerTags(std.testing.allocator, "agent:a", "[\"team:alpha\",\"project:nullpantry\"]");
    defer scoped.deinit(std.testing.allocator);
    try std.testing.expect(!scoped.use_global_scan);
    try std.testing.expectEqual(@as(usize, 4), scoped.tags.items.len);
    try std.testing.expectEqualStrings("agent:a", scoped.tags.items[0]);
    try std.testing.expectEqualStrings("public", scoped.tags.items[1]);
    try std.testing.expectEqualStrings("team:alpha", scoped.tags.items[2]);
    try std.testing.expectEqualStrings("project:nullpantry", scoped.tags.items[3]);

    var global = try visibleContainerTags(std.testing.allocator, "agent:a", "[\"admin\"]");
    defer global.deinit(std.testing.allocator);
    try std.testing.expect(global.use_global_scan);
    try std.testing.expectEqual(@as(usize, 0), global.tags.items.len);
}

test "supermemory parses v4 search output with ACL and session filtering" {
    const body =
        \\{"results":[
        \\  {"id":"doc-1","memory":"Prefer Zig examples","similarity":0.91,"metadata":{"nullpantry_backend":"supermemory","nullpantry_type":"agent_memory","nullpantry_key":"pref.language","nullpantry_content":"Prefer Zig examples","nullpantry_category":"preference","nullpantry_session_id":"session-1","nullpantry_actor_id":"shared:team:alpha","nullpantry_writer_actor_id":"agent:a","nullpantry_scope":"team:alpha","nullpantry_permissions_json":"[\"team:alpha\"]","nullpantry_status":"verified","nullpantry_timestamp_ms":42}},
        \\  {"id":"doc-2","memory":"Hidden","similarity":0.8,"metadata":{"nullpantry_backend":"supermemory","nullpantry_type":"agent_memory","nullpantry_key":"secret","nullpantry_content":"Hidden","nullpantry_actor_id":"agent:b","nullpantry_scope":"agent:agent:b","nullpantry_permissions_json":"[\"agent:agent:b\"]","nullpantry_status":"verified","nullpantry_timestamp_ms":43}}
        \\]}
    ;
    const parsed = try agentMemoryArrayFromBody(std.testing.allocator, body, "agent:a", "[\"team:alpha\",\"agent:agent:a\",\"session:session-1\"]", "pref.language", "session-1", false);
    defer {
        for (parsed) |*entry| vendor.freeAgentMemory(std.testing.allocator, entry);
        std.testing.allocator.free(parsed);
    }
    try std.testing.expectEqual(@as(usize, 1), parsed.len);
    try std.testing.expectEqualStrings("Prefer Zig examples", parsed[0].content);
    try std.testing.expectEqualStrings("verified", parsed[0].status);

    const global_only = try agentMemoryArrayFromBody(std.testing.allocator, body, "agent:a", "[\"team:alpha\",\"agent:agent:a\",\"session:session-1\"]", null, null, false);
    defer {
        for (global_only) |*entry| vendor.freeAgentMemory(std.testing.allocator, entry);
        std.testing.allocator.free(global_only);
    }
    try std.testing.expectEqual(@as(usize, 0), global_only.len);
}
