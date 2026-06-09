const std = @import("std");

const access = @import("access.zig");
const domain = @import("domain.zig");
const ids = @import("ids.zig");
const json = @import("json_util.zig");
const vendor = @import("agent_memory_vendor.zig");
const api_profiles = @import("agent_memory_api_profiles.zig");

pub const is_compiled = true;

pub const default_base_url = api_profiles.honcho_default_base_url;
pub const default_workspace_id = "nullpantry";
const store_name = "honcho";
const content_marker = "content:\n";

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

pub fn workspaceId(configured: ?[]const u8) []const u8 {
    if (configured) |id| {
        const trimmed = std.mem.trim(u8, id, " \t\r\n");
        if (trimmed.len > 0) return trimmed;
    }
    return default_workspace_id;
}

pub fn peerId(allocator: std.mem.Allocator, owner_actor_id: []const u8) ![]u8 {
    const safe = try vendor.sanitizeSegment(allocator, owner_actor_id, 80, "default");
    defer allocator.free(safe);
    const hash_value = std.hash.Wyhash.hash(0x68d4_690c_4d5b_0ad1, owner_actor_id);
    return std.fmt.allocPrint(allocator, "np_peer_{s}_{x}", .{ safe, hash_value });
}

pub fn sessionId(allocator: std.mem.Allocator, owner_actor_id: []const u8, session_id: ?[]const u8) ![]u8 {
    var h = std.hash.Wyhash.init(0x2b7e_1516_28ae_d2a6);
    h.update(owner_actor_id);
    h.update("\x00");
    h.update(session_id orelse "global");
    const safe = try vendor.sanitizeSegment(allocator, session_id orelse "global", 80, "default");
    defer allocator.free(safe);
    return std.fmt.allocPrint(allocator, "np_session_{s}_{x}", .{ safe, h.final() });
}

pub fn messageId(allocator: std.mem.Allocator, input: WriteInput) ![]u8 {
    var h = std.hash.Wyhash.init(0x9e37_79b9_7f4a_7c15);
    h.update(input.owner_actor_id);
    h.update("\x00");
    h.update(input.session_id orelse "");
    h.update("\x00");
    h.update(input.key);
    h.update("\x00");
    h.update(input.status);
    h.update("\x00");
    var ts_buf: [32]u8 = undefined;
    const ts = try std.fmt.bufPrint(&ts_buf, "{d}", .{input.timestamp_ms});
    h.update(ts);
    return std.fmt.allocPrint(allocator, "np_msg_{x}", .{h.final()});
}

pub fn visibleOwners(allocator: std.mem.Allocator, actor_id: []const u8, scopes_json: []const u8) !VisibleOwners {
    return vendor.visibleOwners(allocator, actor_id, scopes_json);
}

pub fn peerPath(allocator: std.mem.Allocator, workspace_id: []const u8, peer_id: []const u8) ![]u8 {
    const ws = try vendor.percentEncode(allocator, workspace_id);
    defer allocator.free(ws);
    const peer = try vendor.percentEncode(allocator, peer_id);
    defer allocator.free(peer);
    return std.fmt.allocPrint(allocator, "/workspaces/{s}/peers/{s}", .{ ws, peer });
}

pub fn peerSearchPath(allocator: std.mem.Allocator, workspace_id: []const u8, peer_id: []const u8) ![]u8 {
    const base = try peerPath(allocator, workspace_id, peer_id);
    defer allocator.free(base);
    return std.fmt.allocPrint(allocator, "{s}/search", .{base});
}

pub fn sessionPath(allocator: std.mem.Allocator, workspace_id: []const u8, session_id: []const u8) ![]u8 {
    const ws = try vendor.percentEncode(allocator, workspace_id);
    defer allocator.free(ws);
    const session = try vendor.percentEncode(allocator, session_id);
    defer allocator.free(session);
    return std.fmt.allocPrint(allocator, "/workspaces/{s}/sessions/{s}", .{ ws, session });
}

pub fn sessionSearchPath(allocator: std.mem.Allocator, workspace_id: []const u8, session_id: []const u8) ![]u8 {
    const base = try sessionPath(allocator, workspace_id, session_id);
    defer allocator.free(base);
    return std.fmt.allocPrint(allocator, "{s}/search", .{base});
}

pub fn sessionPeersPath(allocator: std.mem.Allocator, workspace_id: []const u8, session_id: []const u8) ![]u8 {
    const base = try sessionPath(allocator, workspace_id, session_id);
    defer allocator.free(base);
    return std.fmt.allocPrint(allocator, "{s}/peers", .{base});
}

pub fn sessionMessagesPath(allocator: std.mem.Allocator, workspace_id: []const u8, session_id: []const u8) ![]u8 {
    const base = try sessionPath(allocator, workspace_id, session_id);
    defer allocator.free(base);
    return std.fmt.allocPrint(allocator, "{s}/messages", .{base});
}

pub fn workspaceSearchPath(allocator: std.mem.Allocator, workspace_id: []const u8) ![]u8 {
    const ws = try vendor.percentEncode(allocator, workspace_id);
    defer allocator.free(ws);
    return std.fmt.allocPrint(allocator, "/workspaces/{s}/search", .{ws});
}

pub fn apiUrl(allocator: std.mem.Allocator, base_url: []const u8, path: []const u8, query: []const u8, allow_insecure_http: bool) ![]u8 {
    return vendor.httpUrl(allocator, base_url, path, query, .{
        .version_prefix = "/v3",
        .allow_insecure_http = allow_insecure_http,
    });
}

pub fn peerPayload(allocator: std.mem.Allocator, peer_id: []const u8, owner_actor_id: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"id\":");
    try json.appendString(&out, allocator, peer_id);
    try out.appendSlice(allocator, ",\"metadata\":{\"nullpantry_backend\":\"honcho\",\"nullpantry_type\":\"agent_memory_peer\",\"nullpantry_actor_id\":");
    try json.appendString(&out, allocator, owner_actor_id);
    try out.appendSlice(allocator, "}}");
    return out.toOwnedSlice(allocator);
}

pub fn sessionPayload(allocator: std.mem.Allocator, session_id: []const u8, owner_actor_id: []const u8, original_session_id: ?[]const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"id\":");
    try json.appendString(&out, allocator, session_id);
    try out.appendSlice(allocator, ",\"metadata\":{\"nullpantry_backend\":\"honcho\",\"nullpantry_type\":\"agent_memory_session\",\"nullpantry_actor_id\":");
    try json.appendString(&out, allocator, owner_actor_id);
    try out.appendSlice(allocator, ",\"nullpantry_session_id\":");
    try json.appendNullableString(&out, allocator, original_session_id);
    try out.appendSlice(allocator, "}}");
    return out.toOwnedSlice(allocator);
}

pub fn sessionPeerPayload(allocator: std.mem.Allocator, peer_id: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"peer_ids\":[");
    try json.appendString(&out, allocator, peer_id);
    try out.appendSlice(allocator, "],\"peers\":[");
    try json.appendString(&out, allocator, peer_id);
    try out.appendSlice(allocator, "]}");
    return out.toOwnedSlice(allocator);
}

pub fn messagePayload(allocator: std.mem.Allocator, input: WriteInput, peer_id: []const u8) ![]u8 {
    const memory_id = try messageId(allocator, input);
    defer allocator.free(memory_id);
    const content = try messageContent(allocator, input);
    defer allocator.free(content);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"messages\":[{\"id\":");
    try json.appendString(&out, allocator, memory_id);
    try out.appendSlice(allocator, ",\"peer_id\":");
    try json.appendString(&out, allocator, peer_id);
    try out.appendSlice(allocator, ",\"role\":\"user\",\"content\":");
    try json.appendString(&out, allocator, content);
    try out.appendSlice(allocator, ",\"metadata\":");
    try appendMetadataObject(&out, allocator, input, memory_id);
    try out.appendSlice(allocator, "}]}");
    return out.toOwnedSlice(allocator);
}

pub fn searchPayload(allocator: std.mem.Allocator, query_text: []const u8, limit: usize) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"query\":");
    try json.appendString(&out, allocator, if (query_text.len > 0) query_text else "nullpantry agent memory");
    try out.print(allocator, ",\"limit\":{d},\"max_results\":{d}}}", .{ @max(limit, 1), @max(limit, 1) });
    return out.toOwnedSlice(allocator);
}

pub fn agentMemoryFromWriteInput(allocator: std.mem.Allocator, input: WriteInput) !domain.AgentMemory {
    const scope = try access.agentMemoryScope(allocator, input.owner_actor_id, input.session_id, input.requested_scope);
    defer allocator.free(scope);
    const permissions = try access.agentMemoryPermissions(allocator, input.owner_actor_id, input.requested_scope, input.requested_permissions_json);
    defer allocator.free(permissions);
    const timestamp = try std.fmt.allocPrint(allocator, "{d}", .{input.timestamp_ms});
    errdefer allocator.free(timestamp);
    const id = try messageId(allocator, input);
    errdefer allocator.free(id);
    return .{
        .id = id,
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

pub fn agentMemoryArrayFromBody(allocator: std.mem.Allocator, body: []const u8, actor_id: []const u8, scopes_json: []const u8, exact_key: ?[]const u8, session_id: ?[]const u8) ![]domain.AgentMemory {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.AgentMemoryStorageUnavailable;
    defer parsed.deinit();
    var latest: std.ArrayListUnmanaged(domain.AgentMemory) = .empty;
    errdefer {
        for (latest.items) |*entry| vendor.freeAgentMemory(allocator, entry);
        latest.deinit(allocator);
    }
    try appendAgentMemoriesFromValue(allocator, &latest, parsed.value, actor_id, scopes_json, exact_key, session_id);
    var visible: std.ArrayListUnmanaged(domain.AgentMemory) = .empty;
    errdefer {
        for (visible.items) |*entry| vendor.freeAgentMemory(allocator, entry);
        visible.deinit(allocator);
    }
    for (latest.items) |*entry| {
        if (std.ascii.eqlIgnoreCase(entry.status, "deleted")) {
            vendor.freeAgentMemory(allocator, entry);
            continue;
        }
        try visible.append(allocator, entry.*);
        vendor.detachAgentMemory(entry);
    }
    latest.deinit(allocator);
    return visible.toOwnedSlice(allocator);
}

pub fn appendLatestAgentMemory(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(domain.AgentMemory), entry: domain.AgentMemory) !void {
    var candidate = entry;
    errdefer vendor.freeAgentMemory(allocator, &candidate);
    for (out.items) |*existing| {
        if (std.mem.eql(u8, existing.key, candidate.key) and
            std.mem.eql(u8, existing.actor_id, candidate.actor_id) and
            vendor.sameOptionalString(existing.session_id, candidate.session_id))
        {
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

fn appendMetadataObject(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, input: WriteInput, memory_id: []const u8) !void {
    const scope = try access.agentMemoryScope(allocator, input.owner_actor_id, input.session_id, input.requested_scope);
    defer allocator.free(scope);
    const permissions = try access.agentMemoryPermissions(allocator, input.owner_actor_id, input.requested_scope, input.requested_permissions_json);
    defer allocator.free(permissions);
    try out.appendSlice(allocator, "{\"nullpantry_backend\":\"honcho\",\"nullpantry_type\":\"agent_memory\",\"nullpantry_memory_id\":");
    try json.appendString(out, allocator, memory_id);
    try out.appendSlice(allocator, ",\"nullpantry_key\":");
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
    try out.appendSlice(allocator, ",\"nullpantry_metadata\":");
    try json.appendRawJsonObject(out, allocator, input.metadata_json);
    try out.append(allocator, '}');
}

fn messageContent(allocator: std.mem.Allocator, input: WriteInput) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "NullPantry agent memory\nkey: ");
    try out.appendSlice(allocator, input.key);
    try out.appendSlice(allocator, "\ncategory: ");
    try out.appendSlice(allocator, input.category);
    if (input.session_id) |sid| {
        try out.appendSlice(allocator, "\nsession: ");
        try out.appendSlice(allocator, sid);
    }
    try out.appendSlice(allocator, "\n");
    try out.appendSlice(allocator, content_marker);
    try out.appendSlice(allocator, input.content);
    return out.toOwnedSlice(allocator);
}

fn appendAgentMemoriesFromValue(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(domain.AgentMemory), value: std.json.Value, actor_id: []const u8, scopes_json: []const u8, exact_key: ?[]const u8, session_id: ?[]const u8) !void {
    switch (value) {
        .array => |items| {
            for (items.items) |item| try appendAgentMemoriesFromValue(allocator, out, item, actor_id, scopes_json, exact_key, session_id);
        },
        .object => |obj| {
            if (try agentMemoryFromObject(allocator, obj, actor_id, scopes_json, exact_key, session_id)) |entry| {
                try appendLatestAgentMemory(allocator, out, entry);
                return;
            }
            if (obj.get("message")) |message| try appendAgentMemoriesFromValue(allocator, out, message, actor_id, scopes_json, exact_key, session_id);
            if (obj.get("messages")) |messages| try appendAgentMemoriesFromValue(allocator, out, messages, actor_id, scopes_json, exact_key, session_id);
            if (obj.get("results")) |results| try appendAgentMemoriesFromValue(allocator, out, results, actor_id, scopes_json, exact_key, session_id);
            if (obj.get("data")) |data| try appendAgentMemoriesFromValue(allocator, out, data, actor_id, scopes_json, exact_key, session_id);
            if (obj.get("items")) |items| try appendAgentMemoriesFromValue(allocator, out, items, actor_id, scopes_json, exact_key, session_id);
        },
        else => {},
    }
}

fn agentMemoryFromObject(allocator: std.mem.Allocator, obj: std.json.ObjectMap, actor_id: []const u8, scopes_json: []const u8, exact_key: ?[]const u8, session_id: ?[]const u8) !?domain.AgentMemory {
    const metadata = vendor.objectField(obj, &.{ "metadata", "meta" }) orelse return null;
    if (!std.mem.eql(u8, vendor.stringishField(metadata, &.{"nullpantry_backend"}) orelse "", "honcho")) return null;
    if (!std.mem.eql(u8, vendor.stringishField(metadata, &.{"nullpantry_type"}) orelse "", "agent_memory")) return null;

    const key = vendor.stringishField(metadata, &.{ "nullpantry_key", "key" }) orelse return null;
    if (exact_key) |needle| {
        if (!std.mem.eql(u8, key, needle)) return null;
    }
    const candidate_session_id = vendor.nullableStringishField(metadata, &.{ "nullpantry_session_id", "session_id" });
    if (session_id) |sid| {
        if (candidate_session_id == null or !std.mem.eql(u8, candidate_session_id.?, sid)) return null;
    }
    const content = vendor.stringishField(metadata, &.{"nullpantry_content"}) orelse contentFromMessage(obj) orelse return null;
    const owner = vendor.stringishField(metadata, &.{ "nullpantry_actor_id", "actor_id" }) orelse actor_id;
    const writer = vendor.stringishField(metadata, &.{ "nullpantry_writer_actor_id", "writer_actor_id" }) orelse owner;
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
    const status = vendor.stringishField(metadata, &.{ "nullpantry_status", "status" }) orelse "proposed";
    const id = vendor.stringishField(metadata, &.{"nullpantry_memory_id"}) orelse vendor.stringishField(obj, &.{ "id", "message_id" }) orelse key;
    const entry = domain.AgentMemory{
        .id = try allocator.dupe(u8, id),
        .key = try allocator.dupe(u8, key),
        .content = try allocator.dupe(u8, content),
        .category = try allocator.dupe(u8, vendor.stringishField(metadata, &.{ "nullpantry_category", "category" }) orelse "core"),
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

fn contentFromMessage(obj: std.json.ObjectMap) ?[]const u8 {
    const raw = vendor.stringishField(obj, &.{ "content", "text" }) orelse return null;
    if (std.mem.indexOf(u8, raw, content_marker)) |idx| return raw[idx + content_marker.len ..];
    return raw;
}

fn permissionsJson(allocator: std.mem.Allocator, metadata: std.json.ObjectMap) ![]u8 {
    return vendor.permissionsJsonField(allocator, metadata, "[]");
}

fn timestampString(allocator: std.mem.Allocator, metadata: std.json.ObjectMap, message: std.json.ObjectMap) ![]u8 {
    if (vendor.stringishField(metadata, &.{"nullpantry_timestamp"})) |timestamp| return allocator.dupe(u8, timestamp);
    if (vendor.optionalI64Field(metadata, "nullpantry_timestamp_ms")) |timestamp_ms| return std.fmt.allocPrint(allocator, "{d}", .{timestamp_ms});
    if (vendor.stringishField(message, &.{ "created_at", "createdAt", "timestamp" })) |timestamp| return allocator.dupe(u8, timestamp);
    return std.fmt.allocPrint(allocator, "{d}", .{ids.nowMs()});
}

fn timestampRank(entry: domain.AgentMemory) i64 {
    return std.fmt.parseInt(i64, entry.timestamp, 10) catch 0;
}

fn scoreFromObject(obj: std.json.ObjectMap) ?f64 {
    for ([_][]const u8{ "score", "similarity", "relevance" }) |name| {
        const value = obj.get(name) orelse continue;
        return vendor.valueAsF64(value);
    }
    return null;
}

test "honcho mapping builds workspace peer session message payloads" {
    const peer = try peerId(std.testing.allocator, "shared:team:alpha");
    defer std.testing.allocator.free(peer);
    try std.testing.expect(std.mem.startsWith(u8, peer, "np_peer_shared_team_alpha_"));

    const sid = try sessionId(std.testing.allocator, "shared:team:alpha", "session-1");
    defer std.testing.allocator.free(sid);
    try std.testing.expect(std.mem.startsWith(u8, sid, "np_session_session-1_"));

    const path = try sessionMessagesPath(std.testing.allocator, "nullpantry", sid);
    defer std.testing.allocator.free(path);
    try std.testing.expect(std.mem.indexOf(u8, path, "/workspaces/nullpantry/sessions/") != null);
    try std.testing.expect(std.mem.endsWith(u8, path, "/messages"));

    const payload = try messagePayload(std.testing.allocator, .{
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
    }, peer);
    defer std.testing.allocator.free(payload);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"nullpantry_backend\":\"honcho\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"peer_id\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"nullpantry_permissions\":[\"team:alpha\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"nullpantry_metadata\":{\"source\":\"test\"}") != null);

    const url = try apiUrl(std.testing.allocator, "https://api.honcho.dev", "/workspaces/nullpantry/search", "", false);
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://api.honcho.dev/v3/workspaces/nullpantry/search", url);
}

test "honcho parser hydrates latest visible agent memory and tombstones deleted entries" {
    const body =
        \\{"results":[
        \\  {"id":"old","content":"NullPantry agent memory\nkey: pref.language\ncontent:\nOld","metadata":{"nullpantry_backend":"honcho","nullpantry_type":"agent_memory","nullpantry_key":"pref.language","nullpantry_content":"Old","nullpantry_category":"preference","nullpantry_session_id":null,"nullpantry_actor_id":"agent:a","nullpantry_writer_actor_id":"agent:a","nullpantry_scope":"agent:agent:a","nullpantry_permissions":["actor:agent:a"],"nullpantry_timestamp_ms":1,"nullpantry_status":"proposed"}},
        \\  {"id":"new","content":"NullPantry agent memory\nkey: pref.language\ncontent:\nNew","metadata":{"nullpantry_backend":"honcho","nullpantry_type":"agent_memory","nullpantry_key":"pref.language","nullpantry_content":"New","nullpantry_category":"preference","nullpantry_session_id":null,"nullpantry_actor_id":"agent:a","nullpantry_writer_actor_id":"agent:a","nullpantry_scope":"agent:agent:a","nullpantry_permissions":["actor:agent:a"],"nullpantry_timestamp_ms":2,"nullpantry_status":"verified"}},
        \\  {"id":"del","content":"NullPantry agent memory\nkey: stale\ncontent:\n","metadata":{"nullpantry_backend":"honcho","nullpantry_type":"agent_memory","nullpantry_key":"stale","nullpantry_content":"","nullpantry_category":"core","nullpantry_session_id":null,"nullpantry_actor_id":"agent:a","nullpantry_writer_actor_id":"agent:a","nullpantry_scope":"agent:agent:a","nullpantry_permissions":["actor:agent:a"],"nullpantry_timestamp_ms":3,"nullpantry_status":"deleted"}}
        \\]}
    ;
    const visible = try agentMemoryArrayFromBody(std.testing.allocator, body, "agent:a", "[\"agent:agent:a\"]", null, null);
    defer {
        for (visible) |*entry| vendor.freeAgentMemory(std.testing.allocator, entry);
        std.testing.allocator.free(visible);
    }
    try std.testing.expectEqual(@as(usize, 1), visible.len);
    try std.testing.expectEqualStrings(store_name, visible[0].store);
    try std.testing.expectEqualStrings("pref.language", visible[0].key);
    try std.testing.expectEqualStrings("New", visible[0].content);
    try std.testing.expectEqualStrings("verified", visible[0].status);

    const isolated = try agentMemoryArrayFromBody(std.testing.allocator, body, "agent:b", "[\"agent:agent:b\"]", null, null);
    defer {
        for (isolated) |*entry| vendor.freeAgentMemory(std.testing.allocator, entry);
        std.testing.allocator.free(isolated);
    }
    try std.testing.expectEqual(@as(usize, 0), isolated.len);
}
