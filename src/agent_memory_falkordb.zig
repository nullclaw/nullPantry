const std = @import("std");

const access = @import("access.zig");
const domain = @import("domain.zig");
const ids = @import("ids.zig");
const json = @import("json_util.zig");
const vendor = @import("agent_memory_vendor.zig");
const api_profiles = @import("agent_memory_api_profiles.zig");

pub const is_compiled = true;

pub const default_base_url = api_profiles.falkordb_default_base_url;
pub const default_graph = "nullpantry";
const store_name = "falkordb";

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

pub fn graphName(configured: ?[]const u8) []const u8 {
    if (configured) |value| {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (trimmed.len > 0) return trimmed;
    }
    return default_graph;
}

pub fn apiUrl(allocator: std.mem.Allocator, base_url: []const u8, graph: []const u8, query_text: []const u8, timeout_ms: u32, allow_insecure_http: bool) ![]u8 {
    const graph_segment = try vendor.percentEncode(allocator, graph);
    defer allocator.free(graph_segment);
    const query = try percentEncodeQuery(allocator, query_text);
    defer allocator.free(query);
    const path = try std.fmt.allocPrint(allocator, "/api/graph/{s}", .{graph_segment});
    defer allocator.free(path);
    const query_string = try std.fmt.allocPrint(allocator, "query={s}&timeout={d}", .{ query, @max(timeout_ms, 1) });
    defer allocator.free(query_string);
    return vendor.httpUrl(allocator, base_url, path, query_string, .{
        .allow_insecure_http = allow_insecure_http,
    });
}

pub fn upsertQuery(allocator: std.mem.Allocator, input: WriteInput) ![]u8 {
    const id = try memoryId(allocator, input.owner_actor_id, input.session_id, input.key);
    defer allocator.free(id);
    const scope = try access.agentMemoryScope(allocator, input.owner_actor_id, input.session_id, input.requested_scope);
    defer allocator.free(scope);
    const permissions = try access.agentMemoryPermissions(allocator, input.owner_actor_id, input.requested_scope, input.requested_permissions_json);
    defer allocator.free(permissions);
    const metadata = try json.rawJsonObjectOrError(allocator, input.metadata_json, "{}");
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "MERGE (m:NullPantryAgentMemory {id:");
    try appendCypherString(allocator, &out, id);
    try out.appendSlice(allocator, "}) SET m.nullpantry_backend='falkordb', m.nullpantry_type='agent_memory', m.key=");
    try appendCypherString(allocator, &out, input.key);
    try out.appendSlice(allocator, ", m.content=");
    try appendCypherString(allocator, &out, input.content);
    try out.appendSlice(allocator, ", m.category=");
    try appendCypherString(allocator, &out, input.category);
    try out.appendSlice(allocator, ", m.session_id=");
    try appendCypherNullableString(allocator, &out, input.session_id);
    try out.appendSlice(allocator, ", m.actor_id=");
    try appendCypherString(allocator, &out, input.owner_actor_id);
    try out.appendSlice(allocator, ", m.writer_actor_id=");
    try appendCypherString(allocator, &out, input.writer_actor_id);
    try out.appendSlice(allocator, ", m.scope=");
    try appendCypherString(allocator, &out, scope);
    try out.appendSlice(allocator, ", m.permissions_json=");
    try appendCypherString(allocator, &out, permissions);
    try out.appendSlice(allocator, ", m.metadata_json=");
    try appendCypherString(allocator, &out, metadata);
    try out.print(allocator, ", m.timestamp_ms={d}, m.status=", .{input.timestamp_ms});
    try appendCypherString(allocator, &out, input.status);
    try out.appendSlice(allocator, " RETURN m");
    return out.toOwnedSlice(allocator);
}

pub fn searchQuery(allocator: std.mem.Allocator, query_text: []const u8, owner_actor_id: ?[]const u8, session_id: ?[]const u8, include_sessions: bool, exact_key: ?[]const u8, category: ?[]const u8, limit: usize) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "MATCH (m:NullPantryAgentMemory) WHERE m.nullpantry_backend = 'falkordb' AND m.nullpantry_type = 'agent_memory'");
    try out.appendSlice(allocator, " AND coalesce(m.status, 'proposed') <> 'deleted'");
    if (owner_actor_id) |owner| {
        try out.appendSlice(allocator, " AND m.actor_id = ");
        try appendCypherString(allocator, &out, owner);
    }
    if (exact_key) |key| {
        try out.appendSlice(allocator, " AND m.key = ");
        try appendCypherString(allocator, &out, key);
    } else if (query_text.len > 0) {
        try out.appendSlice(allocator, " AND (toLower(m.content) CONTAINS toLower(");
        try appendCypherString(allocator, &out, query_text);
        try out.appendSlice(allocator, ") OR toLower(m.key) CONTAINS toLower(");
        try appendCypherString(allocator, &out, query_text);
        try out.appendSlice(allocator, "))");
    }
    if (category) |cat| {
        try out.appendSlice(allocator, " AND m.category = ");
        try appendCypherString(allocator, &out, cat);
    }
    if (session_id) |sid| {
        try out.appendSlice(allocator, " AND m.session_id = ");
        try appendCypherString(allocator, &out, sid);
    } else if (!include_sessions) {
        try out.appendSlice(allocator, " AND m.session_id IS NULL");
    }
    try out.print(allocator, " RETURN m ORDER BY m.timestamp_ms DESC LIMIT {d}", .{@max(@as(usize, 1), @min(limit, @as(usize, 500)))});
    return out.toOwnedSlice(allocator);
}

pub fn agentMemoryFromWriteInput(allocator: std.mem.Allocator, input: WriteInput) !domain.AgentMemory {
    const scope = try access.agentMemoryScope(allocator, input.owner_actor_id, input.session_id, input.requested_scope);
    defer allocator.free(scope);
    const permissions = try access.agentMemoryPermissions(allocator, input.owner_actor_id, input.requested_scope, input.requested_permissions_json);
    defer allocator.free(permissions);
    const id = try memoryId(allocator, input.owner_actor_id, input.session_id, input.key);
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
    var out: std.ArrayListUnmanaged(domain.AgentMemory) = .empty;
    errdefer {
        for (out.items) |*entry| vendor.freeAgentMemory(allocator, entry);
        out.deinit(allocator);
    }
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        const data = if (std.mem.startsWith(u8, line, "data:")) std.mem.trim(u8, line["data:".len..], " \t\r\n") else line;
        if (data.len == 0 or data[0] != '{') continue;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch continue;
        defer parsed.deinit();
        try appendAgentMemoriesFromValue(allocator, &out, parsed.value, actor_id, scopes_json, exact_key, session_id_filter, include_sessions);
    }
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

fn appendAgentMemoriesFromValue(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(domain.AgentMemory), value: std.json.Value, actor_id: []const u8, scopes_json: []const u8, exact_key: ?[]const u8, session_id_filter: ?[]const u8, include_sessions: bool) !void {
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
        else => {},
    }
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
    const permissions_json = try vendor.rawJsonArrayField(allocator, obj, &.{ "permissions", "permissions_json" }, "[]");
    errdefer allocator.free(permissions_json);
    const timestamp_ms = vendor.i64Field(obj, "timestamp_ms", ids.nowMs());
    const entry = domain.AgentMemory{
        .id = try allocator.dupe(u8, vendor.stringishField(obj, &.{"id"}) orelse key),
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

fn appendCypherNullableString(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), value: ?[]const u8) !void {
    if (value) |text| return appendCypherString(allocator, out, text);
    try out.appendSlice(allocator, "NULL");
}

fn appendCypherString(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), value: []const u8) !void {
    try out.append(allocator, '\'');
    for (value) |ch| {
        if (ch == '\'') {
            try out.appendSlice(allocator, "\\'");
        } else if (ch == '\\') {
            try out.appendSlice(allocator, "\\\\");
        } else {
            try out.append(allocator, ch);
        }
    }
    try out.append(allocator, '\'');
}

fn percentEncodeQuery(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    const hex = "0123456789ABCDEF";
    for (raw) |ch| {
        const unreserved = std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~';
        if (unreserved) {
            try out.append(allocator, ch);
        } else {
            try out.append(allocator, '%');
            try out.append(allocator, hex[ch >> 4]);
            try out.append(allocator, hex[ch & 0x0f]);
        }
    }
    return out.toOwnedSlice(allocator);
}

fn scoreFromObject(obj: std.json.ObjectMap) ?f64 {
    const value = obj.get("score") orelse return null;
    if (vendor.valueAsF64(value)) |score| return @min(@max(score, 0), 1);
    return null;
}

fn sameLogicalMemory(a: domain.AgentMemory, b: domain.AgentMemory) bool {
    return std.mem.eql(u8, a.key, b.key) and std.mem.eql(u8, a.actor_id, b.actor_id) and vendor.sameOptionalString(a.session_id, b.session_id);
}

fn timestampRank(entry: domain.AgentMemory) i64 {
    return std.fmt.parseInt(i64, entry.timestamp, 10) catch 0;
}

fn memoryId(allocator: std.mem.Allocator, owner: []const u8, session_id: ?[]const u8, key: []const u8) ![]u8 {
    var hash_value = std.hash.Wyhash.hash(0, owner);
    if (session_id) |sid| hash_value = std.hash.Wyhash.hash(hash_value, sid);
    hash_value = std.hash.Wyhash.hash(hash_value, key);
    return std.fmt.allocPrint(allocator, "falkordb_{x}", .{hash_value});
}

test "falkordb cypher helpers escape payloads and parse visible records" {
    const input = WriteInput{
        .key = "pref.language",
        .content = "Prefer Zig's examples",
        .category = "preference",
        .session_id = "session-1",
        .owner_actor_id = "shared:team:alpha",
        .writer_actor_id = "agent:a",
        .requested_scope = "team:alpha",
        .requested_permissions_json = "[\"team:alpha\"]",
        .metadata_json = "{\"source\":\"test\"}",
        .timestamp_ms = 42,
    };
    const query = try upsertQuery(std.testing.allocator, input);
    defer std.testing.allocator.free(query);
    try std.testing.expect(std.mem.indexOf(u8, query, "MERGE (m:NullPantryAgentMemory") != null);
    try std.testing.expect(std.mem.indexOf(u8, query, "Prefer Zig\\'s examples") != null);
    try std.testing.expect(std.mem.indexOf(u8, query, "m.permissions_json='[\"team:alpha\"]'") != null);
    try std.testing.expect(std.mem.indexOf(u8, query, "m.metadata_json='{\"source\":\"test\"}'") != null);

    var invalid_metadata = input;
    invalid_metadata.metadata_json = "[\"not-object\"]";
    try std.testing.expectError(error.InvalidRawJson, upsertQuery(std.testing.allocator, invalid_metadata));

    const search = try searchQuery(std.testing.allocator, "Zig", "shared:team:alpha", "session-1", false, "pref.language", null, 10);
    defer std.testing.allocator.free(search);
    try std.testing.expect(std.mem.indexOf(u8, search, "m.actor_id = 'shared:team:alpha'") != null);
    try std.testing.expect(std.mem.indexOf(u8, search, "m.key = 'pref.language'") != null);

    const url = try apiUrl(std.testing.allocator, "http://localhost:3000/", "team graph", "MATCH (m) RETURN m", 30000, false);
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("http://localhost:3000/api/graph/team%20graph?query=MATCH%20%28m%29%20RETURN%20m&timeout=30000", url);

    const body =
        \\data: {"data":[{"m":{"nullpantry_backend":"falkordb","nullpantry_type":"agent_memory","id":"mem-1","key":"pref.language","content":"Prefer Zig examples","category":"preference","session_id":"session-1","actor_id":"shared:team:alpha","writer_actor_id":"agent:a","scope":"team:alpha","permissions":["team:alpha"],"timestamp_ms":42,"status":"proposed","score":0.8}}]}
    ;
    const items = try agentMemoryArrayFromBody(std.testing.allocator, body, "agent:a", "[\"team:alpha\",\"session:session-1\"]", "pref.language", "session-1", true);
    defer {
        for (items) |*entry| vendor.freeAgentMemory(std.testing.allocator, entry);
        std.testing.allocator.free(items);
    }
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("falkordb", items[0].store);
    try std.testing.expectEqualStrings("Prefer Zig examples", items[0].content);
}
