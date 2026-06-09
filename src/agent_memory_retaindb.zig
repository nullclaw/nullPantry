const std = @import("std");

const access = @import("access.zig");
const domain = @import("domain.zig");
const ids = @import("ids.zig");
const json = @import("json_util.zig");
const vendor = @import("agent_memory_vendor.zig");
const api_profiles = @import("agent_memory_api_profiles.zig");

pub const is_compiled = true;

pub const default_base_url = api_profiles.retaindb_default_base_url;
pub const default_project = "nullpantry";
const store_name = "retaindb";
const global_session_id = "__nullpantry_global__";

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

pub const VisibleOwners = vendor.VisibleOwners;

pub fn visibleOwners(allocator: std.mem.Allocator, actor_id: []const u8, scopes_json: []const u8) !VisibleOwners {
    return vendor.visibleOwners(allocator, actor_id, scopes_json);
}

pub fn projectId(configured: ?[]const u8) []const u8 {
    if (configured) |id| {
        const trimmed = std.mem.trim(u8, id, " \t\r\n");
        if (trimmed.len > 0) return trimmed;
    }
    return default_project;
}

pub fn sessionId(session_id: ?[]const u8) []const u8 {
    return session_id orelse global_session_id;
}

pub fn apiUrl(allocator: std.mem.Allocator, base_url: []const u8, path: []const u8, query: []const u8, allow_insecure_http: bool) ![]u8 {
    return vendor.httpUrl(allocator, base_url, path, query, .{
        .version_prefix = "/v1",
        .allow_insecure_http = allow_insecure_http,
    });
}

pub fn createPayload(allocator: std.mem.Allocator, project: []const u8, input: WriteInput) ![]u8 {
    return writePayload(allocator, project, input, false);
}

pub fn updatePayload(allocator: std.mem.Allocator, project: []const u8, input: WriteInput) ![]u8 {
    return writePayload(allocator, project, input, true);
}

pub fn searchPayload(allocator: std.mem.Allocator, project: []const u8, query_text: []const u8, owner_actor_id: ?[]const u8, session_id_filter: ?[]const u8, include_sessions: bool, exact_key: ?[]const u8, limit: usize) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"project\":");
    try json.appendString(&out, allocator, project);
    try out.appendSlice(allocator, ",\"query\":");
    try json.appendString(&out, allocator, if (query_text.len > 0) query_text else "nullpantry agent memory");
    if (owner_actor_id) |owner| {
        try out.appendSlice(allocator, ",\"user_id\":");
        try json.appendString(&out, allocator, owner);
    }
    if (!include_sessions) {
        try out.appendSlice(allocator, ",\"session_id\":");
        try json.appendString(&out, allocator, sessionId(session_id_filter));
    }
    if (exact_key) |key| {
        try out.appendSlice(allocator, ",\"task_id\":");
        try json.appendString(&out, allocator, key);
    }
    try out.print(allocator, ",\"top_k\":{d},\"include_pending\":true}}", .{@max(limit, 1)});
    return out.toOwnedSlice(allocator);
}

pub fn agentMemoryFromWriteInput(allocator: std.mem.Allocator, input: WriteInput) !domain.AgentMemory {
    const scope = try access.agentMemoryScope(allocator, input.owner_actor_id, input.session_id, input.requested_scope);
    defer allocator.free(scope);
    const permissions = try access.agentMemoryPermissions(allocator, input.owner_actor_id, input.requested_scope, input.requested_permissions_json);
    defer allocator.free(permissions);
    const fallback_id = try memoryId(allocator, input.owner_actor_id, input.session_id, input.key);
    defer allocator.free(fallback_id);
    return .{
        .id = try allocator.dupe(u8, input.remote_id orelse fallback_id),
        .key = try allocator.dupe(u8, input.key),
        .content = try allocator.dupe(u8, input.content),
        .category = try allocator.dupe(u8, input.category),
        .timestamp = try std.fmt.allocPrint(allocator, "{d}", .{input.timestamp_ms}),
        .session_id = if (input.session_id) |sid| try allocator.dupe(u8, sid) else null,
        .actor_id = try allocator.dupe(u8, input.owner_actor_id),
        .writer_actor_id = try allocator.dupe(u8, input.writer_actor_id),
        .scope = try allocator.dupe(u8, scope),
        .permissions_json = try allocator.dupe(u8, permissions),
        .status = try allocator.dupe(u8, input.status),
        .store = try allocator.dupe(u8, store_name),
    };
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

pub fn appendLatestAgentMemory(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(domain.AgentMemory), entry: domain.AgentMemory) !void {
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

pub fn appendAgentMemoryPage(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(domain.AgentMemory), body: []const u8, actor_id: []const u8, scopes_json: []const u8, exact_key: ?[]const u8, session_id_filter: ?[]const u8, include_sessions: bool) !usize {
    const parsed = try agentMemoryArrayFromBody(allocator, body, actor_id, scopes_json, exact_key, session_id_filter, include_sessions);
    defer allocator.free(parsed);
    for (parsed) |entry| try appendLatestAgentMemory(allocator, out, entry);
    return parsed.len;
}

fn writePayload(allocator: std.mem.Allocator, project: []const u8, input: WriteInput, include_remote_id: bool) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"project\":");
    try json.appendString(&out, allocator, project);
    try out.appendSlice(allocator, ",\"user_id\":");
    try json.appendString(&out, allocator, input.owner_actor_id);
    try out.appendSlice(allocator, ",\"agent_id\":");
    try json.appendString(&out, allocator, input.writer_actor_id);
    try out.appendSlice(allocator, ",\"session_id\":");
    try json.appendString(&out, allocator, sessionId(input.session_id));
    try out.appendSlice(allocator, ",\"task_id\":");
    try json.appendString(&out, allocator, input.key);
    try out.appendSlice(allocator, ",\"memory_type\":");
    try json.appendString(&out, allocator, input.category);
    try out.appendSlice(allocator, ",\"content\":");
    try json.appendString(&out, allocator, input.content);
    try out.appendSlice(allocator, ",\"write_mode\":\"sync\",\"metadata\":");
    try appendMetadataObject(&out, allocator, input);
    if (include_remote_id) {
        if (input.remote_id) |remote_id| {
            try out.appendSlice(allocator, ",\"id\":");
            try json.appendString(&out, allocator, remote_id);
        }
    }
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

fn appendAgentMemoriesFromValue(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(domain.AgentMemory), value: std.json.Value, actor_id: []const u8, scopes_json: []const u8, exact_key: ?[]const u8, session_id_filter: ?[]const u8, include_sessions: bool) !void {
    switch (value) {
        .array => |items| {
            for (items.items) |item| try appendAgentMemoriesFromValue(allocator, out, item, actor_id, scopes_json, exact_key, session_id_filter, include_sessions);
        },
        .object => |obj| {
            if (try agentMemoryFromObject(allocator, obj, actor_id, scopes_json, exact_key, session_id_filter, include_sessions)) |entry| {
                try appendLatestAgentMemory(allocator, out, entry);
                return;
            }
            inline for ([_][]const u8{ "results", "memories", "data", "items", "memory", "record", "result" }) |name| {
                if (obj.get(name)) |child| try appendAgentMemoriesFromValue(allocator, out, child, actor_id, scopes_json, exact_key, session_id_filter, include_sessions);
            }
        },
        else => {},
    }
}

fn agentMemoryFromObject(allocator: std.mem.Allocator, obj: std.json.ObjectMap, actor_id: []const u8, scopes_json: []const u8, exact_key: ?[]const u8, session_id_filter: ?[]const u8, include_sessions: bool) !?domain.AgentMemory {
    const metadata = vendor.objectField(obj, &.{ "metadata", "meta" }) orelse return null;
    if (!std.mem.eql(u8, vendor.stringishField(metadata, &.{"nullpantry_backend"}) orelse "", store_name)) return null;
    if (!std.mem.eql(u8, vendor.stringishField(metadata, &.{"nullpantry_type"}) orelse "", "agent_memory")) return null;

    const status = vendor.stringishField(metadata, &.{ "nullpantry_status", "status" }) orelse vendor.stringishField(obj, &.{"status"}) orelse "proposed";

    const key = vendor.stringishField(metadata, &.{ "nullpantry_key", "key" }) orelse vendor.stringishField(obj, &.{ "task_id", "key" }) orelse return null;
    if (exact_key) |needle| {
        if (!std.mem.eql(u8, key, needle)) return null;
    }
    const candidate_session_id = optionalMetadataString(metadata, &.{"nullpantry_session_id"}) orelse optionalObjectSessionId(obj);
    if (session_id_filter) |sid| {
        if (candidate_session_id == null or !std.mem.eql(u8, candidate_session_id.?, sid)) return null;
    } else if (!include_sessions and candidate_session_id != null) {
        return null;
    }

    const content = vendor.stringishField(metadata, &.{"nullpantry_content"}) orelse vendor.stringishField(obj, &.{ "content", "text", "memory", "data" }) orelse return null;
    const owner = vendor.stringishField(metadata, &.{ "nullpantry_actor_id", "actor_id" }) orelse vendor.stringishField(obj, &.{ "user_id", "actor_id" }) orelse actor_id;
    const writer = vendor.stringishField(metadata, &.{ "nullpantry_writer_actor_id", "writer_actor_id" }) orelse vendor.stringishField(obj, &.{ "agent_id", "writer_actor_id" }) orelse owner;
    var owned_scope: ?[]const u8 = null;
    defer if (owned_scope) |scope| allocator.free(scope);
    const scope = vendor.stringishField(metadata, &.{ "nullpantry_scope", "scope" }) orelse blk: {
        owned_scope = try domain.defaultAgentMemoryScope(allocator, owner);
        break :blk owned_scope.?;
    };
    const permissions_json = try permissionsJson(allocator, metadata);
    errdefer allocator.free(permissions_json);
    const timestamp = try timestampString(allocator, metadata, obj);
    errdefer allocator.free(timestamp);
    const entry = domain.AgentMemory{
        .id = try allocator.dupe(u8, vendor.stringishField(obj, &.{ "id", "memory_id" }) orelse vendor.stringishField(metadata, &.{"nullpantry_remote_id"}) orelse key),
        .key = try allocator.dupe(u8, key),
        .content = try allocator.dupe(u8, content),
        .category = try allocator.dupe(u8, vendor.stringishField(metadata, &.{ "nullpantry_category", "category" }) orelse vendor.stringishField(obj, &.{"memory_type"}) orelse "core"),
        .timestamp = timestamp,
        .session_id = if (candidate_session_id) |sid| try allocator.dupe(u8, sid) else null,
        .actor_id = try allocator.dupe(u8, owner),
        .writer_actor_id = try allocator.dupe(u8, writer),
        .scope = try allocator.dupe(u8, scope),
        .permissions_json = permissions_json,
        .status = try allocator.dupe(u8, status),
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

fn appendMetadataObject(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, input: WriteInput) !void {
    const scope = try access.agentMemoryScope(allocator, input.owner_actor_id, input.session_id, input.requested_scope);
    defer allocator.free(scope);
    const permissions = try access.agentMemoryPermissions(allocator, input.owner_actor_id, input.requested_scope, input.requested_permissions_json);
    defer allocator.free(permissions);
    try out.appendSlice(allocator, "{\"nullpantry_backend\":\"retaindb\",\"nullpantry_type\":\"agent_memory\",\"nullpantry_key\":");
    try json.appendString(out, allocator, input.key);
    try out.appendSlice(allocator, ",\"nullpantry_content\":");
    try json.appendString(out, allocator, input.content);
    try out.appendSlice(allocator, ",\"nullpantry_category\":");
    try json.appendString(out, allocator, input.category);
    try out.appendSlice(allocator, ",\"nullpantry_session_id\":");
    try json.appendNullableString(out, allocator, input.session_id);
    try out.appendSlice(allocator, ",\"nullpantry_actor_id\":");
    try json.appendString(out, allocator, input.owner_actor_id);
    try out.appendSlice(allocator, ",\"nullpantry_writer_actor_id\":");
    try json.appendString(out, allocator, input.writer_actor_id);
    try out.appendSlice(allocator, ",\"nullpantry_scope\":");
    try json.appendString(out, allocator, scope);
    try out.appendSlice(allocator, ",\"nullpantry_permissions\":");
    try json.appendRawJsonArray(out, allocator, permissions);
    try out.appendSlice(allocator, ",\"nullpantry_permissions_json\":");
    try json.appendString(out, allocator, permissions);
    try out.print(allocator, ",\"nullpantry_timestamp_ms\":{d}", .{input.timestamp_ms});
    try out.appendSlice(allocator, ",\"nullpantry_status\":");
    try json.appendString(out, allocator, input.status);
    if (input.remote_id) |remote_id| {
        try out.appendSlice(allocator, ",\"nullpantry_remote_id\":");
        try json.appendString(out, allocator, remote_id);
    }
    try out.appendSlice(allocator, ",\"nullpantry_metadata\":");
    try json.appendRawJsonObject(out, allocator, input.metadata_json);
    try out.append(allocator, '}');
}

fn permissionsJson(allocator: std.mem.Allocator, metadata: std.json.ObjectMap) ![]u8 {
    return vendor.permissionsJsonField(allocator, metadata, "[]");
}

fn timestampString(allocator: std.mem.Allocator, metadata: std.json.ObjectMap, obj: std.json.ObjectMap) ![]u8 {
    if (vendor.stringishField(metadata, &.{"nullpantry_timestamp"})) |timestamp| return allocator.dupe(u8, timestamp);
    if (vendor.optionalI64Field(metadata, "nullpantry_timestamp_ms")) |timestamp_ms| return std.fmt.allocPrint(allocator, "{d}", .{timestamp_ms});
    if (vendor.stringishField(obj, &.{ "updated_at", "created_at" })) |timestamp| return allocator.dupe(u8, timestamp);
    return std.fmt.allocPrint(allocator, "{d}", .{ids.nowMs()});
}

fn optionalMetadataString(obj: std.json.ObjectMap, names: []const []const u8) ?[]const u8 {
    const value = vendor.nullableStringishField(obj, names) orelse return null;
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "null") or std.mem.eql(u8, trimmed, global_session_id)) return null;
    return trimmed;
}

fn optionalObjectSessionId(obj: std.json.ObjectMap) ?[]const u8 {
    const sid = vendor.nullableStringishField(obj, &.{"session_id"}) orelse return null;
    if (std.mem.eql(u8, sid, global_session_id)) return null;
    return sid;
}

fn scoreFromObject(obj: std.json.ObjectMap) ?f64 {
    for ([_][]const u8{ "score", "similarity", "relevance" }) |name| {
        const value = obj.get(name) orelse continue;
        return vendor.valueAsF64(value);
    }
    return null;
}

fn sameLogicalMemory(left: domain.AgentMemory, right: domain.AgentMemory) bool {
    return std.mem.eql(u8, left.key, right.key) and
        std.mem.eql(u8, left.actor_id, right.actor_id) and
        vendor.sameOptionalString(left.session_id, right.session_id);
}

fn retainActiveAgentMemories(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(domain.AgentMemory)) void {
    var write_index: usize = 0;
    for (out.items, 0..) |*entry, read_index| {
        if (std.ascii.eqlIgnoreCase(entry.status, "deleted")) {
            vendor.freeAgentMemory(allocator, entry);
            continue;
        }
        if (write_index != read_index) out.items[write_index] = entry.*;
        write_index += 1;
    }
    out.shrinkRetainingCapacity(write_index);
}

fn timestampRank(entry: domain.AgentMemory) i64 {
    return std.fmt.parseInt(i64, entry.timestamp, 10) catch 0;
}

fn memoryId(allocator: std.mem.Allocator, owner_actor_id: []const u8, session_id_filter: ?[]const u8, key: []const u8) ![]u8 {
    var h = std.hash.Wyhash.init(0x0a8d_7db8_0c5f_6a31);
    h.update(owner_actor_id);
    h.update("\x00");
    h.update(sessionId(session_id_filter));
    h.update("\x00");
    h.update(key);
    return std.fmt.allocPrint(allocator, "retaindb_pending_{x}", .{h.final()});
}

test "retaindb mapping builds v1 memory payloads and filters" {
    const payload = try createPayload(std.testing.allocator, "nullpantry-test", .{
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
    });
    defer std.testing.allocator.free(payload);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"project\":\"nullpantry-test\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"user_id\":\"shared:team:alpha\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"agent_id\":\"agent:a\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"session_id\":\"session-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"task_id\":\"pref.language\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"memory_type\":\"preference\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"write_mode\":\"sync\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"nullpantry_backend\":\"retaindb\"") != null);
    var parsed_payload = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed_payload.deinit();
    try std.testing.expectEqualStrings("retaindb", parsed_payload.value.object.get("metadata").?.object.get("nullpantry_backend").?.string);

    const search = try searchPayload(std.testing.allocator, "nullpantry-test", "Zig", "shared:team:alpha", null, false, "pref.language", 10);
    defer std.testing.allocator.free(search);
    try std.testing.expect(std.mem.indexOf(u8, search, "\"project\":\"nullpantry-test\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, search, "\"query\":\"Zig\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, search, "\"session_id\":\"__nullpantry_global__\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, search, "\"task_id\":\"pref.language\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, search, "\"top_k\":10") != null);
    try std.testing.expect(std.mem.indexOf(u8, search, "\"include_pending\":true") != null);
    var parsed_search = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, search, .{});
    defer parsed_search.deinit();
    try std.testing.expectEqualStrings("pref.language", parsed_search.value.object.get("task_id").?.string);

    const url = try apiUrl(std.testing.allocator, "https://api.retaindb.com/v1/", "/memory/search", "", false);
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://api.retaindb.com/v1/memory/search", url);
}

test "retaindb parser hydrates metadata and enforces visibility" {
    const body =
        \\{"results":[
        \\  {"id":"mem-a","content":"Prefer Zig examples","score":0.91,"metadata":{"nullpantry_backend":"retaindb","nullpantry_type":"agent_memory","nullpantry_key":"pref.language","nullpantry_content":"Prefer Zig examples","nullpantry_category":"preference","nullpantry_session_id":null,"nullpantry_actor_id":"agent:a","nullpantry_writer_actor_id":"agent:a","nullpantry_scope":"agent:agent:a","nullpantry_permissions":["actor:agent:a"],"nullpantry_timestamp_ms":42,"nullpantry_status":"verified"}},
        \\  {"id":"mem-a-new","content":"Prefer concise Zig examples","score":0.93,"metadata":{"nullpantry_backend":"retaindb","nullpantry_type":"agent_memory","nullpantry_key":"pref.language","nullpantry_content":"Prefer concise Zig examples","nullpantry_category":"preference","nullpantry_session_id":null,"nullpantry_actor_id":"agent:a","nullpantry_writer_actor_id":"agent:a","nullpantry_scope":"agent:agent:a","nullpantry_permissions":["actor:agent:a"],"nullpantry_timestamp_ms":44,"nullpantry_status":"verified"}},
        \\  {"id":"mem-b","content":"Team fact","metadata":{"nullpantry_backend":"retaindb","nullpantry_type":"agent_memory","nullpantry_key":"team.fact","nullpantry_content":"Team fact","nullpantry_category":"core","nullpantry_session_id":null,"nullpantry_actor_id":"shared:team:alpha","nullpantry_writer_actor_id":"agent:a","nullpantry_scope":"team:alpha","nullpantry_permissions":["team:alpha"],"nullpantry_timestamp_ms":43,"nullpantry_status":"proposed"}},
        \\  {"id":"mem-c-old","content":"Deleted fact","metadata":{"nullpantry_backend":"retaindb","nullpantry_type":"agent_memory","nullpantry_key":"deleted.fact","nullpantry_content":"Deleted fact","nullpantry_category":"core","nullpantry_session_id":null,"nullpantry_actor_id":"agent:a","nullpantry_writer_actor_id":"agent:a","nullpantry_scope":"agent:agent:a","nullpantry_permissions":["actor:agent:a"],"nullpantry_timestamp_ms":40,"nullpantry_status":"verified"}},
        \\  {"id":"mem-c-delete","content":"Deleted fact","metadata":{"nullpantry_backend":"retaindb","nullpantry_type":"agent_memory","nullpantry_key":"deleted.fact","nullpantry_content":"Deleted fact","nullpantry_category":"core","nullpantry_session_id":null,"nullpantry_actor_id":"agent:a","nullpantry_writer_actor_id":"agent:a","nullpantry_scope":"agent:agent:a","nullpantry_permissions":["actor:agent:a"],"nullpantry_timestamp_ms":45,"nullpantry_status":"deleted"}}
        \\]}
    ;
    const visible = try agentMemoryArrayFromBody(std.testing.allocator, body, "agent:a", "[\"agent:agent:a\",\"team:alpha\"]", null, null, false);
    defer {
        for (visible) |*entry| vendor.freeAgentMemory(std.testing.allocator, entry);
        std.testing.allocator.free(visible);
    }
    try std.testing.expectEqual(@as(usize, 2), visible.len);
    try std.testing.expectEqualStrings(store_name, visible[0].store);
    try std.testing.expectEqualStrings("pref.language", visible[0].key);
    try std.testing.expectEqualStrings("Prefer concise Zig examples", visible[0].content);
    try std.testing.expect(visible[0].score.? > 0.92);

    const isolated = try agentMemoryArrayFromBody(std.testing.allocator, body, "agent:b", "[\"agent:agent:b\"]", null, null, false);
    defer {
        for (isolated) |*entry| vendor.freeAgentMemory(std.testing.allocator, entry);
        std.testing.allocator.free(isolated);
    }
    try std.testing.expectEqual(@as(usize, 0), isolated.len);

    const exact = try agentMemoryArrayFromBody(std.testing.allocator, body, "agent:a", "[\"agent:agent:a\",\"team:alpha\"]", "team.fact", null, false);
    defer {
        for (exact) |*entry| vendor.freeAgentMemory(std.testing.allocator, entry);
        std.testing.allocator.free(exact);
    }
    try std.testing.expectEqual(@as(usize, 1), exact.len);
    try std.testing.expectEqualStrings("team.fact", exact[0].key);
}
