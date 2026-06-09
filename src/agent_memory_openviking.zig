const std = @import("std");

const access = @import("access.zig");
const domain = @import("domain.zig");
const ids = @import("ids.zig");
const json = @import("json_util.zig");
const vendor = @import("agent_memory_vendor.zig");
const api_profiles = @import("agent_memory_api_profiles.zig");

pub const is_compiled = true;

pub const default_base_url = api_profiles.openviking_default_base_url;
pub const agent_memory_root_uri = "viking://resources/nullpantry/agent-memory";
const store_name = "openviking";

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
};

pub const SearchHit = struct {
    uri: []u8,
    score: ?f64 = null,

    pub fn deinit(self: *SearchHit, allocator: std.mem.Allocator) void {
        allocator.free(self.uri);
    }
};

pub fn memoryUri(allocator: std.mem.Allocator, owner_actor_id: []const u8, session_id: ?[]const u8, key: []const u8) ![]u8 {
    const root = try rootUriForOwner(allocator, owner_actor_id);
    defer allocator.free(root);
    const session_segment = try vendor.sanitizeSegment(allocator, session_id orelse "global", 120, "default");
    defer allocator.free(session_segment);
    const key_id = try keyId(allocator, key);
    defer allocator.free(key_id);
    return std.fmt.allocPrint(allocator, "{s}/{s}/{s}.json", .{ root, session_segment, key_id });
}

pub fn rootUriForOwner(allocator: std.mem.Allocator, owner_actor_id: []const u8) ![]u8 {
    if (vendor.sharedScopeFromOwner(owner_actor_id)) |scope| {
        const safe = try vendor.sanitizeSegment(allocator, scope, 120, "default");
        defer allocator.free(safe);
        return std.fmt.allocPrint(allocator, "{s}/shared/{s}", .{ agent_memory_root_uri, safe });
    }
    const safe = try vendor.sanitizeSegment(allocator, owner_actor_id, 120, "default");
    defer allocator.free(safe);
    return std.fmt.allocPrint(allocator, "{s}/actors/{s}", .{ agent_memory_root_uri, safe });
}

pub fn visibleTargetUris(allocator: std.mem.Allocator, actor_id: []const u8, scopes_json: []const u8) !std.ArrayListUnmanaged([]u8) {
    var out: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (out.items) |uri| allocator.free(uri);
        out.deinit(allocator);
    }

    var candidates = try vendor.visibleOwners(allocator, actor_id, scopes_json);
    defer candidates.deinit(allocator);
    if (candidates.requires_global_scan) {
        try out.append(allocator, try allocator.dupe(u8, agent_memory_root_uri));
        return out;
    }
    for (candidates.owners.items) |owner| {
        const uri = try rootUriForOwner(allocator, owner);
        for (out.items) |existing| {
            if (std.mem.eql(u8, existing, uri)) {
                allocator.free(uri);
                break;
            }
        } else {
            try out.append(allocator, uri);
        }
    }
    return out;
}

pub fn contentPayload(allocator: std.mem.Allocator, input: WriteInput, uri: []const u8) ![]u8 {
    const scope = try access.agentMemoryScope(allocator, input.owner_actor_id, input.session_id, input.requested_scope);
    defer allocator.free(scope);
    const permissions = try access.agentMemoryPermissions(allocator, input.owner_actor_id, input.requested_scope, input.requested_permissions_json);
    defer allocator.free(permissions);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"nullpantry_backend\":\"openviking\",\"nullpantry_type\":\"agent_memory\",\"uri\":");
    try json.appendString(&out, allocator, uri);
    try out.appendSlice(allocator, ",\"key\":");
    try json.appendString(&out, allocator, input.key);
    try out.appendSlice(allocator, ",\"content\":");
    try json.appendString(&out, allocator, input.content);
    try out.appendSlice(allocator, ",\"category\":");
    try json.appendString(&out, allocator, input.category);
    try out.appendSlice(allocator, ",\"session_id\":");
    try json.appendNullableString(&out, allocator, input.session_id);
    try out.appendSlice(allocator, ",\"actor_id\":");
    try json.appendString(&out, allocator, input.owner_actor_id);
    try out.appendSlice(allocator, ",\"writer_actor_id\":");
    try json.appendString(&out, allocator, input.writer_actor_id);
    try out.appendSlice(allocator, ",\"scope\":");
    try json.appendString(&out, allocator, scope);
    try out.appendSlice(allocator, ",\"permissions\":");
    try json.appendRawJsonArray(&out, allocator, permissions);
    try out.appendSlice(allocator, ",\"permissions_json\":");
    try json.appendString(&out, allocator, permissions);
    try out.print(allocator, ",\"timestamp_ms\":{d}", .{input.timestamp_ms});
    try out.appendSlice(allocator, ",\"status\":");
    try json.appendString(&out, allocator, input.status);
    try out.appendSlice(allocator, ",\"metadata\":");
    try json.appendRawJsonObject(&out, allocator, input.metadata_json);
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

pub fn contentPayloadFromEntry(allocator: std.mem.Allocator, entry: domain.AgentMemory, uri: []const u8, status: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"nullpantry_backend\":\"openviking\",\"nullpantry_type\":\"agent_memory\",\"uri\":");
    try json.appendString(&out, allocator, uri);
    try out.appendSlice(allocator, ",\"key\":");
    try json.appendString(&out, allocator, entry.key);
    try out.appendSlice(allocator, ",\"content\":");
    try json.appendString(&out, allocator, entry.content);
    try out.appendSlice(allocator, ",\"category\":");
    try json.appendString(&out, allocator, entry.category);
    try out.appendSlice(allocator, ",\"session_id\":");
    try json.appendNullableString(&out, allocator, entry.session_id);
    try out.appendSlice(allocator, ",\"actor_id\":");
    try json.appendString(&out, allocator, entry.actor_id);
    try out.appendSlice(allocator, ",\"writer_actor_id\":");
    try json.appendString(&out, allocator, entry.writer_actor_id);
    try out.appendSlice(allocator, ",\"scope\":");
    try json.appendString(&out, allocator, entry.scope);
    try out.appendSlice(allocator, ",\"permissions\":");
    try json.appendRawJsonArray(&out, allocator, entry.permissions_json);
    try out.appendSlice(allocator, ",\"permissions_json\":");
    try json.appendString(&out, allocator, entry.permissions_json);
    try out.appendSlice(allocator, ",\"timestamp\":");
    try json.appendString(&out, allocator, entry.timestamp);
    try out.appendSlice(allocator, ",\"status\":");
    try json.appendString(&out, allocator, status);
    try out.appendSlice(allocator, ",\"metadata\":{}}");
    return out.toOwnedSlice(allocator);
}

pub fn writePayload(allocator: std.mem.Allocator, uri: []const u8, content: []const u8, mode: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"uri\":");
    try json.appendString(&out, allocator, uri);
    try out.appendSlice(allocator, ",\"content\":");
    try json.appendString(&out, allocator, content);
    try out.appendSlice(allocator, ",\"mode\":");
    try json.appendString(&out, allocator, mode);
    try out.appendSlice(allocator, ",\"wait\":true}");
    return out.toOwnedSlice(allocator);
}

pub fn searchPayload(allocator: std.mem.Allocator, query_text: []const u8, limit: usize, target_uri: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"query\":");
    try json.appendString(&out, allocator, if (query_text.len > 0) query_text else "nullpantry");
    try out.print(allocator, ",\"limit\":{d},\"node_limit\":{d},\"target_uri\":", .{ @max(limit, 1), @max(limit, 1) });
    try json.appendString(&out, allocator, target_uri);
    try out.appendSlice(allocator, ",\"level\":\"2\",\"include_provenance\":false}");
    return out.toOwnedSlice(allocator);
}

pub fn uriQuery(allocator: std.mem.Allocator, uri: []const u8, raw: bool) ![]u8 {
    const encoded = try vendor.percentEncode(allocator, uri);
    defer allocator.free(encoded);
    if (raw) return std.fmt.allocPrint(allocator, "uri={s}&raw=true", .{encoded});
    return std.fmt.allocPrint(allocator, "uri={s}", .{encoded});
}

pub fn apiUrl(allocator: std.mem.Allocator, base_url: []const u8, path: []const u8, query: []const u8, allow_insecure_http: bool) ![]u8 {
    return vendor.httpUrl(allocator, base_url, path, query, .{
        .version_prefix = "/api/v1",
        .allow_insecure_http = allow_insecure_http,
    });
}

pub fn agentMemoryFromWriteInput(allocator: std.mem.Allocator, input: WriteInput, uri: []const u8) !domain.AgentMemory {
    const scope = try access.agentMemoryScope(allocator, input.owner_actor_id, input.session_id, input.requested_scope);
    defer allocator.free(scope);
    const permissions = try access.agentMemoryPermissions(allocator, input.owner_actor_id, input.requested_scope, input.requested_permissions_json);
    defer allocator.free(permissions);
    const timestamp = try std.fmt.allocPrint(allocator, "{d}", .{input.timestamp_ms});
    errdefer allocator.free(timestamp);
    return .{
        .id = try allocator.dupe(u8, uri),
        .key = try allocator.dupe(u8, input.key),
        .content = try allocator.dupe(u8, input.content),
        .category = try allocator.dupe(u8, input.category),
        .timestamp = timestamp,
        .session_id = if (input.session_id) |sid| try allocator.dupe(u8, sid) else null,
        .actor_id = try allocator.dupe(u8, input.owner_actor_id),
        .writer_actor_id = try allocator.dupe(u8, input.writer_actor_id),
        .scope = try allocator.dupe(u8, scope),
        .permissions_json = try allocator.dupe(u8, permissions),
        .status = try allocator.dupe(u8, input.status),
        .store = try allocator.dupe(u8, store_name),
    };
}

pub fn agentMemoryFromReadBody(allocator: std.mem.Allocator, body: []const u8, actor_id: []const u8, scopes_json: []const u8, exact_key: ?[]const u8, session_id: ?[]const u8) !?domain.AgentMemory {
    const content = try readContentFromBody(allocator, body);
    defer if (content) |value| allocator.free(value);
    return try agentMemoryFromContent(allocator, content orelse return null, actor_id, scopes_json, exact_key, session_id);
}

pub fn searchHitsFromBody(allocator: std.mem.Allocator, body: []const u8) ![]SearchHit {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.AgentMemoryStorageUnavailable;
    defer parsed.deinit();
    var out: std.ArrayListUnmanaged(SearchHit) = .empty;
    errdefer {
        for (out.items) |*hit| hit.deinit(allocator);
        out.deinit(allocator);
    }
    if (parsed.value == .array) {
        try appendSearchHits(allocator, &out, parsed.value);
    } else if (parsed.value == .object) {
        if (parsed.value.object.get("result")) |result| {
            if (result == .object) {
                if (result.object.get("resources")) |resources| try appendSearchHits(allocator, &out, resources);
                if (result.object.get("memories")) |memories| try appendSearchHits(allocator, &out, memories);
            } else {
                try appendSearchHits(allocator, &out, result);
            }
        }
        if (parsed.value.object.get("resources")) |resources| try appendSearchHits(allocator, &out, resources);
        if (parsed.value.object.get("memories")) |memories| try appendSearchHits(allocator, &out, memories);
        if (parsed.value.object.get("results")) |results| try appendSearchHits(allocator, &out, results);
    }
    return out.toOwnedSlice(allocator);
}

pub fn appendUniqueAgentMemory(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(domain.AgentMemory), entry: domain.AgentMemory) !void {
    var candidate = entry;
    errdefer vendor.freeAgentMemory(allocator, &candidate);
    for (out.items) |existing| {
        if (std.mem.eql(u8, existing.id, candidate.id) or
            (std.mem.eql(u8, existing.key, candidate.key) and std.mem.eql(u8, existing.actor_id, candidate.actor_id) and vendor.sameOptionalString(existing.session_id, candidate.session_id)))
        {
            vendor.freeAgentMemory(allocator, &candidate);
            return;
        }
    }
    try out.append(allocator, candidate);
}

fn readContentFromBody(allocator: std.mem.Allocator, body: []const u8) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.AgentMemoryStorageUnavailable;
    defer parsed.deinit();
    if (parsed.value == .string) return try allocator.dupe(u8, parsed.value.string);
    if (parsed.value != .object) return null;
    if (parsed.value.object.get("result")) |result| {
        if (result == .string) return try allocator.dupe(u8, result.string);
        if (result == .object) {
            if (vendor.stringishField(result.object, &.{ "content", "text", "body" })) |content| return try allocator.dupe(u8, content);
        }
    }
    if (vendor.stringishField(parsed.value.object, &.{ "content", "text", "body" })) |content| return try allocator.dupe(u8, content);
    return null;
}

fn agentMemoryFromContent(allocator: std.mem.Allocator, content_json: []const u8, actor_id: []const u8, scopes_json: []const u8, exact_key: ?[]const u8, session_id: ?[]const u8) !?domain.AgentMemory {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content_json, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const obj = parsed.value.object;
    const key = vendor.stringishField(obj, &.{ "key", "nullpantry_key" }) orelse return null;
    if (exact_key) |needle| {
        if (!std.mem.eql(u8, key, needle)) return null;
    }
    const candidate_session_id = vendor.stringishField(obj, &.{"session_id"});
    if (session_id) |sid| {
        if (candidate_session_id == null or !std.mem.eql(u8, candidate_session_id.?, sid)) return null;
    }
    const content = vendor.stringishField(obj, &.{ "content", "text" }) orelse return null;
    const owner = vendor.stringishField(obj, &.{ "actor_id", "owner_id", "nullpantry_actor_id" }) orelse actor_id;
    const writer = vendor.stringishField(obj, &.{ "writer_actor_id", "created_by_actor_id", "nullpantry_writer_actor_id" }) orelse owner;
    var owned_scope: ?[]const u8 = null;
    defer if (owned_scope) |scope| allocator.free(scope);
    const scope = vendor.stringishField(obj, &.{ "scope", "nullpantry_scope" }) orelse blk: {
        owned_scope = try domain.defaultAgentMemoryScope(allocator, owner);
        break :blk owned_scope.?;
    };
    const permissions_json = try permissionsJson(allocator, obj);
    errdefer allocator.free(permissions_json);
    const timestamp = try timestampString(allocator, obj);
    errdefer allocator.free(timestamp);
    const entry = domain.AgentMemory{
        .id = try allocator.dupe(u8, vendor.stringishField(obj, &.{ "id", "uri" }) orelse key),
        .key = try allocator.dupe(u8, key),
        .content = try allocator.dupe(u8, content),
        .category = try allocator.dupe(u8, vendor.stringishField(obj, &.{"category"}) orelse "core"),
        .timestamp = timestamp,
        .session_id = if (candidate_session_id) |sid| try allocator.dupe(u8, sid) else null,
        .actor_id = try allocator.dupe(u8, owner),
        .writer_actor_id = try allocator.dupe(u8, writer),
        .scope = try allocator.dupe(u8, scope),
        .permissions_json = permissions_json,
        .status = try allocator.dupe(u8, vendor.stringishField(obj, &.{"status"}) orelse "proposed"),
        .store = try allocator.dupe(u8, store_name),
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

fn appendSearchHits(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(SearchHit), value: std.json.Value) !void {
    if (value != .array) return;
    for (value.array.items) |item| {
        if (item != .object) continue;
        const uri = vendor.stringishField(item.object, &.{ "uri", "path", "resource_uri" }) orelse continue;
        if (!std.mem.startsWith(u8, uri, agent_memory_root_uri ++ "/")) continue;
        for (out.items) |existing| {
            if (std.mem.eql(u8, existing.uri, uri)) break;
        } else {
            try out.append(allocator, .{
                .uri = try allocator.dupe(u8, uri),
                .score = if (item.object.get("score")) |score| vendor.valueAsF64(score) else null,
            });
        }
    }
}

fn permissionsJson(allocator: std.mem.Allocator, obj: std.json.ObjectMap) ![]u8 {
    return vendor.permissionsJsonField(allocator, obj, "[]");
}

fn timestampString(allocator: std.mem.Allocator, obj: std.json.ObjectMap) ![]u8 {
    if (vendor.stringishField(obj, &.{"timestamp"})) |timestamp| return allocator.dupe(u8, timestamp);
    const timestamp_ms = vendor.i64Field(obj, "timestamp_ms", ids.nowMs());
    return std.fmt.allocPrint(allocator, "{d}", .{timestamp_ms});
}

fn keyId(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    const hash_value = std.hash.Wyhash.hash(0x2b42_d1a5_07c9_e001, key);
    return std.fmt.allocPrint(allocator, "np-{x}", .{hash_value});
}

test "openviking mapping builds deterministic resource payloads" {
    const uri = try memoryUri(std.testing.allocator, "shared:team:alpha", null, "pref.language");
    defer std.testing.allocator.free(uri);
    try std.testing.expect(std.mem.startsWith(u8, uri, "viking://resources/nullpantry/agent-memory/shared/team_alpha/global/np-"));
    try std.testing.expect(std.mem.endsWith(u8, uri, ".json"));

    const payload = try contentPayload(std.testing.allocator, .{
        .key = "pref.language",
        .content = "Prefer Zig examples",
        .category = "preference",
        .owner_actor_id = "shared:team:alpha",
        .writer_actor_id = "agent:a",
        .requested_scope = "team:alpha",
        .requested_permissions_json = "[\"team:alpha\"]",
        .metadata_json = "{\"source\":\"test\"}",
        .timestamp_ms = 42,
    }, uri);
    defer std.testing.allocator.free(payload);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"nullpantry_backend\":\"openviking\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"permissions\":[\"team:alpha\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"metadata\":{\"source\":\"test\"}") != null);

    try std.testing.expectError(error.InvalidRawJson, contentPayload(std.testing.allocator, .{
        .key = "pref.language",
        .content = "Prefer Zig examples",
        .category = "preference",
        .owner_actor_id = "shared:team:alpha",
        .writer_actor_id = "agent:a",
        .requested_scope = "team:alpha",
        .requested_permissions_json = "[\"team:alpha\"]",
        .metadata_json = "[\"not-object\"]",
        .timestamp_ms = 42,
    }, uri));
}

test "openviking parser hydrates and filters agent memory" {
    const read_body =
        \\{"status":"ok","result":"{\"nullpantry_backend\":\"openviking\",\"nullpantry_type\":\"agent_memory\",\"uri\":\"viking://resources/nullpantry/agent-memory/actors/agent_a/global/np-1.json\",\"key\":\"pref.language\",\"content\":\"Prefer Zig examples\",\"category\":\"preference\",\"session_id\":null,\"actor_id\":\"agent:a\",\"writer_actor_id\":\"agent:a\",\"scope\":\"agent:agent:a\",\"permissions\":[\"actor:agent:a\"],\"timestamp_ms\":42,\"status\":\"proposed\"}"}
    ;
    var visible = (try agentMemoryFromReadBody(std.testing.allocator, read_body, "agent:a", "[\"agent:agent:a\"]", null, null)).?;
    defer vendor.freeAgentMemory(std.testing.allocator, &visible);
    try std.testing.expectEqualStrings(store_name, visible.store);
    try std.testing.expectEqualStrings("pref.language", visible.key);

    const isolated = try agentMemoryFromReadBody(std.testing.allocator, read_body, "agent:b", "[\"agent:agent:b\"]", null, null);
    try std.testing.expect(isolated == null);
}
