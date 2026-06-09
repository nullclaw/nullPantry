const std = @import("std");

const access = @import("access.zig");
const domain = @import("domain.zig");
const ids = @import("ids.zig");
const json = @import("json_util.zig");
const vendor = @import("agent_memory_vendor.zig");
const api_profiles = @import("agent_memory_api_profiles.zig");

pub const is_compiled = true;

pub const default_base_url = api_profiles.zep_default_base_url;
const store_name = "zep";
const shared_owner_prefix = "shared:";

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

pub const VisibleOwners = vendor.VisibleOwners;

pub fn visibleOwners(allocator: std.mem.Allocator, actor_id: []const u8, scopes_json: []const u8) !VisibleOwners {
    return vendor.visibleOwners(allocator, actor_id, scopes_json);
}

pub fn apiUrl(allocator: std.mem.Allocator, base_url: []const u8, path: []const u8, query: []const u8, allow_insecure_http: bool) ![]u8 {
    return vendor.httpUrl(allocator, base_url, path, query, .{
        .version_prefix = "/api/v2",
        .allow_insecure_http = allow_insecure_http,
    });
}

pub fn addDataPayload(allocator: std.mem.Allocator, input: WriteInput) ![]u8 {
    const data = try envelopeJson(allocator, input);
    defer allocator.free(data);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"data\":");
    try json.appendString(&out, allocator, data);
    try out.appendSlice(allocator, ",\"type\":\"json\",\"source_description\":\"nullpantry agent memory\"");
    try appendGraphSelector(allocator, &out, input.owner_actor_id);
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

pub fn searchPayload(allocator: std.mem.Allocator, query_text: []const u8, owner_actor_id: ?[]const u8, limit: usize) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"query\":");
    try json.appendString(&out, allocator, if (query_text.len > 0) query_text else "nullpantry agent memory");
    try out.appendSlice(allocator, ",\"scope\":\"edges\",\"limit\":");
    try out.print(allocator, "{d}", .{@max(@as(usize, 1), @min(limit, @as(usize, 50)))});
    if (owner_actor_id) |owner| try appendGraphSelector(allocator, &out, owner);
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

pub fn agentMemoryFromWriteInput(allocator: std.mem.Allocator, input: WriteInput) !domain.AgentMemory {
    const scope = try access.agentMemoryScope(allocator, input.owner_actor_id, input.session_id, input.requested_scope);
    defer allocator.free(scope);
    const permissions = try access.agentMemoryPermissions(allocator, input.owner_actor_id, input.requested_scope, input.requested_permissions_json);
    defer allocator.free(permissions);
    const id = try memoryId(allocator, input.owner_actor_id, input.session_id, input.key, input.timestamp_ms);
    errdefer allocator.free(id);
    return .{
        .id = id,
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
    return activeAgentMemoryPage(allocator, try out.toOwnedSlice(allocator), std.math.maxInt(usize), 0);
}

pub fn appendLatestAgentMemory(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(domain.AgentMemory), entry: domain.AgentMemory) !void {
    var candidate = entry;
    errdefer vendor.freeAgentMemory(allocator, &candidate);
    for (out.items) |*existing| {
        if (sameLogicalMemory(existing.*, candidate)) {
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

pub fn activeAgentMemoryPage(allocator: std.mem.Allocator, entries: []domain.AgentMemory, limit: usize, offset: usize) ![]domain.AgentMemory {
    errdefer {
        for (entries) |*entry| vendor.freeAgentMemory(allocator, entry);
        allocator.free(entries);
    }
    var out: std.ArrayListUnmanaged(domain.AgentMemory) = .empty;
    errdefer {
        for (out.items) |*entry| vendor.freeAgentMemory(allocator, entry);
        out.deinit(allocator);
    }
    var skipped: usize = 0;
    for (entries) |*entry| {
        if (std.mem.eql(u8, entry.status, "deleted")) {
            vendor.freeAgentMemory(allocator, entry);
            continue;
        }
        if (skipped < offset) {
            skipped += 1;
            vendor.freeAgentMemory(allocator, entry);
            continue;
        }
        if (out.items.len < limit) {
            try out.append(allocator, entry.*);
            vendor.detachAgentMemory(entry);
            continue;
        }
        vendor.freeAgentMemory(allocator, entry);
    }
    const page = try out.toOwnedSlice(allocator);
    allocator.free(entries);
    return page;
}

fn envelopeJson(allocator: std.mem.Allocator, input: WriteInput) ![]u8 {
    const scope = try access.agentMemoryScope(allocator, input.owner_actor_id, input.session_id, input.requested_scope);
    defer allocator.free(scope);
    const permissions = try access.agentMemoryPermissions(allocator, input.owner_actor_id, input.requested_scope, input.requested_permissions_json);
    defer allocator.free(permissions);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"nullpantry_backend\":\"zep\",\"nullpantry_type\":\"agent_memory\",\"key\":");
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
    try out.appendSlice(allocator, permissions);
    try out.appendSlice(allocator, ",\"timestamp_ms\":");
    try out.print(allocator, "{d}", .{input.timestamp_ms});
    try out.appendSlice(allocator, ",\"status\":");
    try json.appendString(&out, allocator, input.status);
    try out.appendSlice(allocator, ",\"metadata\":");
    try json.appendRawJsonObject(&out, allocator, input.metadata_json);
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

fn appendGraphSelector(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), owner_actor_id: []const u8) !void {
    if (std.mem.startsWith(u8, owner_actor_id, shared_owner_prefix)) {
        const graph_id = try graphIdForOwner(allocator, owner_actor_id);
        defer allocator.free(graph_id);
        try out.appendSlice(allocator, ",\"graph_id\":");
        try json.appendString(out, allocator, graph_id);
        return;
    }
    try out.appendSlice(allocator, ",\"user_id\":");
    try json.appendString(out, allocator, owner_actor_id);
}

fn graphIdForOwner(allocator: std.mem.Allocator, owner_actor_id: []const u8) ![]u8 {
    const scope = if (std.mem.startsWith(u8, owner_actor_id, shared_owner_prefix)) owner_actor_id[shared_owner_prefix.len..] else owner_actor_id;
    const segment = try vendor.sanitizeSegment(allocator, scope, 120, "shared");
    defer allocator.free(segment);
    return std.fmt.allocPrint(allocator, "nullpantry_{s}", .{segment});
}

fn appendAgentMemoriesFromValue(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(domain.AgentMemory), value: std.json.Value, actor_id: []const u8, scopes_json: []const u8, exact_key: ?[]const u8, session_id_filter: ?[]const u8, include_sessions: bool) anyerror!void {
    switch (value) {
        .array => |items| for (items.items) |item| try appendAgentMemoriesFromValue(allocator, out, item, actor_id, scopes_json, exact_key, session_id_filter, include_sessions),
        .object => |obj| {
            if (try agentMemoryFromObject(allocator, obj, actor_id, scopes_json, exact_key, session_id_filter, include_sessions)) |entry| {
                try appendLatestAgentMemory(allocator, out, entry);
                return;
            }
            var it = obj.iterator();
            while (it.next()) |kv| try appendAgentMemoriesFromValue(allocator, out, kv.value_ptr.*, actor_id, scopes_json, exact_key, session_id_filter, include_sessions);
        },
        .string => |text| try appendAgentMemoriesFromString(allocator, out, text, actor_id, scopes_json, exact_key, session_id_filter, include_sessions),
        else => {},
    }
}

fn appendAgentMemoriesFromString(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(domain.AgentMemory), text: []const u8, actor_id: []const u8, scopes_json: []const u8, exact_key: ?[]const u8, session_id_filter: ?[]const u8, include_sessions: bool) anyerror!void {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] != '{') return;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch return;
    defer parsed.deinit();
    try appendAgentMemoriesFromValue(allocator, out, parsed.value, actor_id, scopes_json, exact_key, session_id_filter, include_sessions);
}

fn agentMemoryFromObject(allocator: std.mem.Allocator, obj: std.json.ObjectMap, actor_id: []const u8, scopes_json: []const u8, exact_key: ?[]const u8, session_id_filter: ?[]const u8, include_sessions: bool) !?domain.AgentMemory {
    if (!std.mem.eql(u8, vendor.stringishField(obj, &.{"nullpantry_backend"}) orelse "", store_name)) return null;
    if (!std.mem.eql(u8, vendor.stringishField(obj, &.{"nullpantry_type"}) orelse "", "agent_memory")) return null;
    const key = vendor.stringishField(obj, &.{"key"}) orelse return null;
    if (exact_key) |needle| if (!std.mem.eql(u8, key, needle)) return null;
    const session_id = vendor.nullableStringishField(obj, &.{"session_id"});
    if (session_id_filter) |sid| {
        if (session_id == null or !std.mem.eql(u8, session_id.?, sid)) return null;
    } else if (!include_sessions and session_id != null) return null;

    const owner = vendor.stringishField(obj, &.{ "actor_id", "owner_actor_id" }) orelse actor_id;
    const writer = vendor.stringishField(obj, &.{ "writer_actor_id", "created_by_actor_id" }) orelse owner;
    const timestamp_ms = vendor.i64Field(obj, "timestamp_ms", ids.nowMs());
    const permissions_json = try vendor.rawJsonArrayField(allocator, obj, &.{ "permissions", "permissions_json" }, "[]");
    errdefer allocator.free(permissions_json);
    const entry = domain.AgentMemory{
        .id = try allocator.dupe(u8, vendor.stringishField(obj, &.{ "id", "uuid" }) orelse key),
        .key = try allocator.dupe(u8, key),
        .content = try allocator.dupe(u8, vendor.stringishField(obj, &.{"content"}) orelse ""),
        .category = try allocator.dupe(u8, vendor.stringishField(obj, &.{"category"}) orelse "core"),
        .timestamp = try std.fmt.allocPrint(allocator, "{d}", .{timestamp_ms}),
        .session_id = if (session_id) |sid| try allocator.dupe(u8, sid) else null,
        .actor_id = try allocator.dupe(u8, owner),
        .writer_actor_id = try allocator.dupe(u8, writer),
        .scope = try allocator.dupe(u8, vendor.stringishField(obj, &.{"scope"}) orelse ""),
        .permissions_json = permissions_json,
        .status = try allocator.dupe(u8, vendor.stringishField(obj, &.{"status"}) orelse "proposed"),
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

fn scoreFromObject(obj: std.json.ObjectMap) ?f64 {
    if (obj.get("score")) |value| if (vendor.valueAsF64(value)) |score| return @min(@max(score, 0), 1);
    if (obj.get("relevance")) |value| if (vendor.valueAsF64(value)) |score| return @min(@max(score, 0), 1);
    return null;
}

fn sameLogicalMemory(a: domain.AgentMemory, b: domain.AgentMemory) bool {
    return std.mem.eql(u8, a.key, b.key) and std.mem.eql(u8, a.actor_id, b.actor_id) and vendor.sameOptionalString(a.session_id, b.session_id);
}

fn timestampRank(entry: domain.AgentMemory) i64 {
    return std.fmt.parseInt(i64, entry.timestamp, 10) catch 0;
}

fn memoryId(allocator: std.mem.Allocator, owner: []const u8, session_id: ?[]const u8, key: []const u8, timestamp_ms: i64) ![]u8 {
    var hash_value = std.hash.Wyhash.hash(0, owner);
    if (session_id) |sid| hash_value = std.hash.Wyhash.hash(hash_value, sid);
    hash_value = std.hash.Wyhash.hash(hash_value, key);
    var buf: [32]u8 = undefined;
    const ts = try std.fmt.bufPrint(&buf, "{d}", .{timestamp_ms});
    hash_value = std.hash.Wyhash.hash(hash_value, ts);
    return std.fmt.allocPrint(allocator, "zep_{x}", .{hash_value});
}

test "zep payloads use graph api and hydrate nullpantry envelope" {
    const payload = try addDataPayload(std.testing.allocator, .{
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
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"type\":\"json\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"graph_id\":\"nullpantry_team_alpha\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\\\"nullpantry_backend\\\":\\\"zep\\\"") != null);

    const search = try searchPayload(std.testing.allocator, "Zig", "agent:a", 10);
    defer std.testing.allocator.free(search);
    try std.testing.expect(std.mem.indexOf(u8, search, "\"scope\":\"edges\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, search, "\"user_id\":\"agent:a\"") != null);

    const body =
        \\{"edges":[{"fact":"{\"nullpantry_backend\":\"zep\",\"nullpantry_type\":\"agent_memory\",\"key\":\"pref.language\",\"content\":\"Prefer Zig examples\",\"category\":\"preference\",\"session_id\":\"session-1\",\"actor_id\":\"shared:team:alpha\",\"writer_actor_id\":\"agent:a\",\"scope\":\"team:alpha\",\"permissions\":[\"team:alpha\"],\"timestamp_ms\":42,\"status\":\"proposed\"}","score":0.9}]}
    ;
    const items = try agentMemoryArrayFromBody(std.testing.allocator, body, "agent:a", "[\"team:alpha\",\"session:session-1\"]", "pref.language", "session-1", true);
    defer {
        for (items) |*entry| vendor.freeAgentMemory(std.testing.allocator, entry);
        std.testing.allocator.free(items);
    }
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("zep", items[0].store);
    try std.testing.expectEqualStrings("Prefer Zig examples", items[0].content);
}
