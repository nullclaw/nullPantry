const std = @import("std");

const access = @import("access.zig");
const domain = @import("domain.zig");
const json = @import("json_util.zig");
const vendor = @import("agent_memory_vendor.zig");
const api_profiles = @import("agent_memory_api_profiles.zig");

pub const is_compiled = true;

pub const default_command = api_profiles.byterover_default_command;
const store_name = "byterover";

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

pub fn agentMemoryFromWriteInput(allocator: std.mem.Allocator, input: WriteInput) !domain.AgentMemory {
    const scope = try access.agentMemoryScope(allocator, input.owner_actor_id, input.session_id, input.requested_scope);
    defer allocator.free(scope);
    const permissions = try access.agentMemoryPermissions(allocator, input.owner_actor_id, input.requested_scope, input.requested_permissions_json);
    defer allocator.free(permissions);

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

    entry.id = try memoryId(allocator, input.owner_actor_id, input.session_id, input.key, input.timestamp_ms);
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

pub fn curateText(allocator: std.mem.Allocator, input: WriteInput) ![]u8 {
    var object: std.ArrayListUnmanaged(u8) = .empty;
    defer object.deinit(allocator);
    try appendMemoryObject(&object, allocator, input);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "NullPantry agent memory entry. Preserve the fenced JSON object exactly for future retrieval.\n\n```json\n");
    try out.appendSlice(allocator, object.items);
    try out.appendSlice(allocator, "\n```\n");
    return out.toOwnedSlice(allocator);
}

pub fn queryPrompt(allocator: std.mem.Allocator, query_text: []const u8, owner_actor_id: ?[]const u8, session_id: ?[]const u8, include_sessions: bool, exact_key: ?[]const u8, category: ?[]const u8, limit: usize) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "Search ByteRover context tree for NullPantry agent memory JSON blocks. Return matching raw JSON objects only, no prose.\n");
    try out.appendSlice(allocator, "Required fields: nullpantry_backend=\"byterover\", nullpantry_type=\"agent_memory\".\n");
    try out.appendSlice(allocator, "Filters: ");
    if (owner_actor_id) |owner| {
        try out.appendSlice(allocator, "owner_actor_id=");
        try json.appendString(&out, allocator, owner);
        try out.appendSlice(allocator, " ");
    } else {
        try out.appendSlice(allocator, "owner_actor_id=visible_to_request ");
    }
    if (session_id) |sid| {
        try out.appendSlice(allocator, "session_id=");
        try json.appendString(&out, allocator, sid);
        try out.appendSlice(allocator, " ");
    } else if (!include_sessions) {
        try out.appendSlice(allocator, "session_id=null ");
    } else {
        try out.appendSlice(allocator, "include_sessions=true ");
    }
    if (exact_key) |key| {
        try out.appendSlice(allocator, "key=");
        try json.appendString(&out, allocator, key);
        try out.appendSlice(allocator, " ");
    }
    if (category) |cat| {
        try out.appendSlice(allocator, "category=");
        try json.appendString(&out, allocator, cat);
        try out.appendSlice(allocator, " ");
    }
    try out.print(allocator, "limit={d}.\n", .{@max(limit, 1)});
    try out.appendSlice(allocator, "Query: ");
    try json.appendString(&out, allocator, if (query_text.len > 0) query_text else "nullpantry agent memory");
    return out.toOwnedSlice(allocator);
}

pub fn agentMemoryArrayFromCliOutput(allocator: std.mem.Allocator, body: []const u8, actor_id: []const u8, scopes_json: []const u8, exact_key: ?[]const u8, session_id: ?[]const u8, include_sessions: bool) ![]domain.AgentMemory {
    var out: std.ArrayListUnmanaged(domain.AgentMemory) = .empty;
    errdefer {
        for (out.items) |*entry| vendor.freeAgentMemory(allocator, entry);
        out.deinit(allocator);
    }

    parseWholeJson(allocator, &out, body, actor_id, scopes_json, exact_key, session_id, include_sessions) catch {};
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) continue;
        parseWholeJson(allocator, &out, line, actor_id, scopes_json, exact_key, session_id, include_sessions) catch {};
    }
    try appendJsonObjectsFromText(allocator, &out, body, actor_id, scopes_json, exact_key, session_id, include_sessions);

    const owned = try out.toOwnedSlice(allocator);
    sortAgentMemory(owned);
    return activeAgentMemoryPage(allocator, owned, std.math.maxInt(usize), 0);
}

pub fn cliOutputSucceeded(allocator: std.mem.Allocator, body: []const u8) bool {
    var saw_success = false;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        if (boolField(parsed.value.object, "success")) |success| {
            if (!success) return false;
            saw_success = true;
        }
        const event = vendor.stringishField(parsed.value.object, &.{"event"}) orelse dataEvent(parsed.value.object);
        if (event) |value| {
            if (std.mem.eql(u8, value, "error")) return false;
            if (std.mem.eql(u8, value, "completed")) saw_success = true;
        }
    }
    return saw_success or std.mem.trim(u8, body, " \t\r\n").len == 0;
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

pub fn activeAgentMemoryPage(allocator: std.mem.Allocator, entries: []domain.AgentMemory, limit: usize, offset: usize) ![]domain.AgentMemory {
    const owned = entries;
    errdefer {
        for (owned) |*entry| vendor.freeAgentMemory(allocator, entry);
        allocator.free(owned);
    }

    if (limit == 0) {
        const empty = try allocator.alloc(domain.AgentMemory, 0);
        for (owned) |*entry| vendor.freeAgentMemory(allocator, entry);
        allocator.free(owned);
        return empty;
    }

    var active: std.ArrayListUnmanaged(domain.AgentMemory) = .empty;
    errdefer {
        for (active.items) |*entry| vendor.freeAgentMemory(allocator, entry);
        active.deinit(allocator);
    }
    var skipped: usize = 0;
    for (owned) |*entry| {
        if (isDeletedAgentMemory(entry.*)) {
            vendor.freeAgentMemory(allocator, entry);
            continue;
        }
        if (skipped < offset) {
            skipped += 1;
            vendor.freeAgentMemory(allocator, entry);
            continue;
        }
        if (active.items.len < limit) {
            try active.append(allocator, entry.*);
            vendor.detachAgentMemory(entry);
        } else {
            vendor.freeAgentMemory(allocator, entry);
        }
    }

    const page = try active.toOwnedSlice(allocator);
    allocator.free(owned);
    return page;
}

pub fn appendAgentMemoryPage(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(domain.AgentMemory), body: []const u8, actor_id: []const u8, scopes_json: []const u8, exact_key: ?[]const u8, session_id: ?[]const u8, include_sessions: bool) !usize {
    const parsed = try agentMemoryArrayFromCliOutput(allocator, body, actor_id, scopes_json, exact_key, session_id, include_sessions);
    defer {
        for (parsed) |*entry| vendor.freeAgentMemory(allocator, entry);
        allocator.free(parsed);
    }
    for (parsed) |*entry| {
        try appendLatestAgentMemory(allocator, out, entry.*);
        vendor.detachAgentMemory(entry);
    }
    return parsed.len;
}

fn parseWholeJson(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(domain.AgentMemory), text: []const u8, actor_id: []const u8, scopes_json: []const u8, exact_key: ?[]const u8, session_id: ?[]const u8, include_sessions: bool) anyerror!void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    defer parsed.deinit();
    try appendAgentMemoriesFromValue(allocator, out, parsed.value, actor_id, scopes_json, exact_key, session_id, include_sessions);
}

fn appendAgentMemoriesFromValue(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(domain.AgentMemory), value: std.json.Value, actor_id: []const u8, scopes_json: []const u8, exact_key: ?[]const u8, session_id: ?[]const u8, include_sessions: bool) anyerror!void {
    switch (value) {
        .array => |items| {
            for (items.items) |item| try appendAgentMemoriesFromValue(allocator, out, item, actor_id, scopes_json, exact_key, session_id, include_sessions);
        },
        .object => |obj| {
            if (try agentMemoryFromObject(allocator, obj, actor_id, scopes_json, exact_key, session_id, include_sessions)) |entry| {
                try appendLatestAgentMemory(allocator, out, entry);
                return;
            }
            inline for ([_][]const u8{ "data", "result", "results", "response", "items", "memories", "memory", "record", "toolResult", "tool_result" }) |name| {
                if (obj.get(name)) |child| try appendAgentMemoriesFromValue(allocator, out, child, actor_id, scopes_json, exact_key, session_id, include_sessions);
            }
            inline for ([_][]const u8{ "content", "text", "message", "answer", "output" }) |name| {
                if (obj.get(name)) |child| {
                    if (child == .string) try appendJsonObjectsFromText(allocator, out, child.string, actor_id, scopes_json, exact_key, session_id, include_sessions);
                }
            }
        },
        .string => |text| try appendJsonObjectsFromText(allocator, out, text, actor_id, scopes_json, exact_key, session_id, include_sessions),
        else => {},
    }
}

fn appendJsonObjectsFromText(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(domain.AgentMemory), text: []const u8, actor_id: []const u8, scopes_json: []const u8, exact_key: ?[]const u8, session_id: ?[]const u8, include_sessions: bool) anyerror!void {
    var start: ?usize = null;
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    for (text, 0..) |ch, i| {
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (ch == '\\') {
                escaped = true;
            } else if (ch == '"') {
                in_string = false;
            }
            continue;
        }
        if (ch == '"') {
            in_string = true;
            continue;
        }
        if (ch == '{') {
            if (depth == 0) start = i;
            depth += 1;
            continue;
        }
        if (ch == '}') {
            if (depth == 0) continue;
            depth -= 1;
            if (depth == 0) {
                const begin = start orelse continue;
                parseWholeJson(allocator, out, text[begin .. i + 1], actor_id, scopes_json, exact_key, session_id, include_sessions) catch {};
                start = null;
            }
        }
    }
}

fn agentMemoryFromObject(allocator: std.mem.Allocator, obj: std.json.ObjectMap, actor_id: []const u8, scopes_json: []const u8, exact_key: ?[]const u8, session_id_filter: ?[]const u8, include_sessions: bool) !?domain.AgentMemory {
    const metadata = vendor.objectField(obj, &.{ "metadata", "meta" });
    if (!std.mem.eql(u8, stringField(obj, metadata, &.{"nullpantry_backend"}) orelse "", store_name)) return null;
    if (!std.mem.eql(u8, stringField(obj, metadata, &.{"nullpantry_type"}) orelse "", "agent_memory")) return null;

    const key = stringField(obj, metadata, &.{ "nullpantry_key", "key" }) orelse return null;
    if (exact_key) |needle| {
        if (!std.mem.eql(u8, key, needle)) return null;
    }

    const candidate_session_id = nullableStringField(obj, metadata, &.{ "nullpantry_session_id", "session_id", "session" });
    if (session_id_filter) |sid| {
        if (candidate_session_id == null or !std.mem.eql(u8, candidate_session_id.?, sid)) return null;
    } else if (!include_sessions and candidate_session_id != null) {
        return null;
    }

    const content = stringField(obj, metadata, &.{ "nullpantry_content", "content", "text", "memory" }) orelse return null;
    const owner = stringField(obj, metadata, &.{ "nullpantry_actor_id", "owner_actor_id", "actor_id", "owner_id" }) orelse actor_id;
    const writer = stringField(obj, metadata, &.{ "nullpantry_writer_actor_id", "writer_actor_id", "created_by_actor_id" }) orelse owner;
    var owned_scope: ?[]const u8 = null;
    defer if (owned_scope) |scope| allocator.free(scope);
    const scope = stringField(obj, metadata, &.{ "nullpantry_scope", "scope" }) orelse blk: {
        owned_scope = try domain.defaultAgentMemoryScope(allocator, owner);
        break :blk owned_scope.?;
    };
    const permissions = try permissionsJson(allocator, obj, metadata);
    errdefer allocator.free(permissions);
    const timestamp = try timestampString(allocator, obj, metadata);
    errdefer allocator.free(timestamp);

    const entry = domain.AgentMemory{
        .id = try allocator.dupe(u8, stringField(obj, metadata, &.{ "nullpantry_id", "id", "memory_id" }) orelse key),
        .key = try allocator.dupe(u8, key),
        .content = try allocator.dupe(u8, content),
        .category = try allocator.dupe(u8, stringField(obj, metadata, &.{ "nullpantry_category", "category", "memory_type" }) orelse "core"),
        .timestamp = timestamp,
        .session_id = if (candidate_session_id) |sid| try allocator.dupe(u8, sid) else null,
        .actor_id = try allocator.dupe(u8, owner),
        .writer_actor_id = try allocator.dupe(u8, writer),
        .scope = try allocator.dupe(u8, scope),
        .permissions_json = permissions,
        .status = try allocator.dupe(u8, stringField(obj, metadata, &.{ "nullpantry_status", "status" }) orelse "proposed"),
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

fn appendMemoryObject(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, input: WriteInput) !void {
    const scope = try access.agentMemoryScope(allocator, input.owner_actor_id, input.session_id, input.requested_scope);
    defer allocator.free(scope);
    const permissions = try access.agentMemoryPermissions(allocator, input.owner_actor_id, input.requested_scope, input.requested_permissions_json);
    defer allocator.free(permissions);
    const id = try memoryId(allocator, input.owner_actor_id, input.session_id, input.key, input.timestamp_ms);
    defer allocator.free(id);

    try out.appendSlice(allocator, "{\"nullpantry_backend\":\"byterover\",\"nullpantry_type\":\"agent_memory\",\"nullpantry_id\":");
    try json.appendString(out, allocator, id);
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
    try out.appendSlice(allocator, ",\"nullpantry_permissions_json\":");
    try json.appendString(out, allocator, permissions);
    try out.appendSlice(allocator, ",\"nullpantry_status\":");
    try json.appendString(out, allocator, input.status);
    try out.print(allocator, ",\"nullpantry_timestamp_ms\":{d}", .{input.timestamp_ms});
    if (input.metadata_json) |metadata| {
        try out.appendSlice(allocator, ",\"nullpantry_metadata\":");
        try json.appendRawJsonObject(out, allocator, metadata);
    }
    try out.append(allocator, '}');
}

fn stringField(obj: std.json.ObjectMap, metadata: ?std.json.ObjectMap, names: []const []const u8) ?[]const u8 {
    if (vendor.stringishField(obj, names)) |value| return value;
    if (metadata) |meta| {
        if (vendor.stringishField(meta, names)) |value| return value;
    }
    return null;
}

fn nullableStringField(obj: std.json.ObjectMap, metadata: ?std.json.ObjectMap, names: []const []const u8) ?[]const u8 {
    if (vendor.nullableStringishField(obj, names)) |value| return value;
    if (metadata) |meta| {
        if (vendor.nullableStringishField(meta, names)) |value| return value;
    }
    return null;
}

fn permissionsJson(allocator: std.mem.Allocator, obj: std.json.ObjectMap, metadata: ?std.json.ObjectMap) ![]u8 {
    const permission_fields = &.{ "nullpantry_permissions_json", "permissions_json", "permissions" };
    if (vendor.hasNonNullField(obj, permission_fields)) {
        return vendor.rawJsonArrayField(allocator, obj, permission_fields, "[]");
    }
    if (metadata) |meta| {
        if (vendor.hasNonNullField(meta, permission_fields)) return vendor.rawJsonArrayField(allocator, meta, permission_fields, "[]");
    }
    return allocator.dupe(u8, "[]");
}

fn timestampString(allocator: std.mem.Allocator, obj: std.json.ObjectMap, metadata: ?std.json.ObjectMap) ![]u8 {
    if (stringField(obj, metadata, &.{ "nullpantry_timestamp", "timestamp", "created_at" })) |value| {
        return allocator.dupe(u8, value);
    }
    if (optionalI64(obj, metadata, "nullpantry_timestamp_ms")) |value| {
        return std.fmt.allocPrint(allocator, "{d}", .{value});
    }
    if (optionalI64(obj, metadata, "timestamp_ms")) |value| {
        return std.fmt.allocPrint(allocator, "{d}", .{value});
    }
    return allocator.dupe(u8, "0");
}

fn optionalI64(obj: std.json.ObjectMap, metadata: ?std.json.ObjectMap, name: []const u8) ?i64 {
    if (vendor.optionalI64Field(obj, name)) |value| return value;
    if (metadata) |meta| {
        if (vendor.optionalI64Field(meta, name)) |value| return value;
    }
    return null;
}

fn scoreFromObject(obj: std.json.ObjectMap) ?f64 {
    inline for ([_][]const u8{ "score", "relevance", "similarity", "confidence" }) |name| {
        if (obj.get(name)) |value| {
            if (vendor.valueAsF64(value)) |score| return score;
        }
    }
    return null;
}

fn boolField(obj: std.json.ObjectMap, name: []const u8) ?bool {
    const value = obj.get(name) orelse return null;
    return switch (value) {
        .bool => |b| b,
        else => null,
    };
}

fn dataEvent(obj: std.json.ObjectMap) ?[]const u8 {
    const data = vendor.objectField(obj, &.{"data"}) orelse return null;
    return vendor.stringishField(data, &.{"event"});
}

fn sortAgentMemory(items: []domain.AgentMemory) void {
    std.mem.sort(domain.AgentMemory, items, {}, compareAgentMemoryDesc);
}

fn compareAgentMemoryDesc(_: void, a: domain.AgentMemory, b: domain.AgentMemory) bool {
    const at = timestampRank(a);
    const bt = timestampRank(b);
    if (at != bt) return at > bt;
    const actor_cmp = std.mem.order(u8, a.actor_id, b.actor_id);
    if (actor_cmp != .eq) return actor_cmp == .lt;
    return std.mem.order(u8, a.key, b.key) == .lt;
}

fn timestampRank(entry: domain.AgentMemory) i64 {
    return std.fmt.parseInt(i64, entry.timestamp, 10) catch 0;
}

fn isDeletedAgentMemory(entry: domain.AgentMemory) bool {
    return std.mem.eql(u8, entry.status, "deleted") or
        std.mem.eql(u8, entry.status, "rejected") or
        std.mem.eql(u8, entry.status, "deprecated");
}

fn memoryId(allocator: std.mem.Allocator, owner_actor_id: []const u8, session_id: ?[]const u8, key: []const u8, timestamp_ms: i64) ![]u8 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(owner_actor_id);
    hasher.update("\x00");
    hasher.update(session_id orelse "");
    hasher.update("\x00");
    hasher.update(key);
    hasher.update("\x00");
    var timestamp_buf: [32]u8 = undefined;
    const timestamp_text = try std.fmt.bufPrint(&timestamp_buf, "{d}", .{timestamp_ms});
    hasher.update(timestamp_text);
    return std.fmt.allocPrint(allocator, "brv:{x}", .{hasher.final()});
}

test "byterover builds curate text and parses cli json lines" {
    const payload = try curateText(std.testing.allocator, .{
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
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"nullpantry_backend\":\"byterover\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"nullpantry_key\":\"pref.language\"") != null);

    const output =
        \\{"command":"query","data":{"event":"response","content":"```json\n{\"nullpantry_backend\":\"byterover\",\"nullpantry_type\":\"agent_memory\",\"nullpantry_key\":\"pref.language\",\"nullpantry_content\":\"Old\",\"nullpantry_category\":\"preference\",\"nullpantry_session_id\":\"session-1\",\"nullpantry_actor_id\":\"shared:team:alpha\",\"nullpantry_writer_actor_id\":\"agent:b\",\"nullpantry_scope\":\"team:alpha\",\"nullpantry_permissions_json\":\"[\\\"team:alpha\\\"]\",\"nullpantry_status\":\"proposed\",\"nullpantry_timestamp_ms\":1}\n```\n```json\n{\"nullpantry_backend\":\"byterover\",\"nullpantry_type\":\"agent_memory\",\"nullpantry_key\":\"pref.language\",\"nullpantry_content\":\"Prefer Zig examples\",\"nullpantry_category\":\"preference\",\"nullpantry_session_id\":\"session-1\",\"nullpantry_actor_id\":\"shared:team:alpha\",\"nullpantry_writer_actor_id\":\"agent:a\",\"nullpantry_scope\":\"team:alpha\",\"nullpantry_permissions_json\":\"[\\\"team:alpha\\\"]\",\"nullpantry_status\":\"verified\",\"nullpantry_timestamp_ms\":42}\n```"},"success":true}
        \\{"command":"query","data":{"event":"response","content":"{\"nullpantry_backend\":\"byterover\",\"nullpantry_type\":\"agent_memory\",\"nullpantry_key\":\"secret\",\"nullpantry_content\":\"Hidden\",\"nullpantry_actor_id\":\"agent:b\",\"nullpantry_scope\":\"agent:agent:b\",\"nullpantry_permissions_json\":\"[\\\"agent:agent:b\\\"]\",\"nullpantry_status\":\"verified\",\"nullpantry_timestamp_ms\":50}"},"success":true}
    ;
    const parsed = try agentMemoryArrayFromCliOutput(std.testing.allocator, output, "agent:a", "[\"team:alpha\",\"agent:agent:a\",\"session:session-1\"]", "pref.language", "session-1", false);
    defer {
        for (parsed) |*entry| vendor.freeAgentMemory(std.testing.allocator, entry);
        std.testing.allocator.free(parsed);
    }
    try std.testing.expectEqual(@as(usize, 1), parsed.len);
    try std.testing.expectEqualStrings("Prefer Zig examples", parsed[0].content);
    try std.testing.expectEqualStrings("verified", parsed[0].status);

    var merged: std.ArrayListUnmanaged(domain.AgentMemory) = .empty;
    defer {
        for (merged.items) |*entry| vendor.freeAgentMemory(std.testing.allocator, entry);
        merged.deinit(std.testing.allocator);
    }
    const appended = try appendAgentMemoryPage(std.testing.allocator, &merged, output, "agent:a", "[\"team:alpha\",\"agent:agent:a\",\"session:session-1\"]", "pref.language", "session-1", false);
    try std.testing.expectEqual(@as(usize, 1), appended);
    try std.testing.expectEqual(@as(usize, 1), merged.items.len);
    try std.testing.expectEqualStrings("Prefer Zig examples", merged.items[0].content);
}

test "byterover query prompt carries isolation filters" {
    const prompt = try queryPrompt(std.testing.allocator, "Zig", "shared:team:alpha", "session-1", false, "pref.language", "preference", 10);
    defer std.testing.allocator.free(prompt);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "owner_actor_id=\"shared:team:alpha\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "session_id=\"session-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "key=\"pref.language\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "category=\"preference\"") != null);
}
