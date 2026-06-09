const std = @import("std");

const access = @import("access.zig");
const bounded_int = @import("bounded_int.zig");
const domain = @import("domain.zig");
const ids = @import("ids.zig");
const json = @import("json_util.zig");
const vendor = @import("agent_memory_vendor.zig");
const api_profiles = @import("agent_memory_api_profiles.zig");

pub const is_compiled = true;

pub const default_base_url = api_profiles.mem0_default_base_url;
pub const app_id = "nullpantry";
const store_name = "mem0";
const global_run_id = "__nullpantry_global__";
const request_result_limit_max: usize = 5000;
const list_page_size_max: usize = 200;
const page_fetch_lookahead_pages: usize = 1;

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

pub fn runId(session_id: ?[]const u8) []const u8 {
    return session_id orelse global_run_id;
}

pub fn apiUrl(allocator: std.mem.Allocator, base_url: []const u8, path: []const u8, query: []const u8, allow_insecure_http: bool) ![]u8 {
    return vendor.httpUrl(allocator, base_url, path, query, .{
        .strip_base_suffixes = &.{ "/v3", "/v1" },
        .allow_insecure_http = allow_insecure_http,
    });
}

pub fn addPayload(allocator: std.mem.Allocator, input: WriteInput) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"messages\":[{\"role\":\"user\",\"content\":");
    try json.appendString(&out, allocator, input.content);
    try out.appendSlice(allocator, "}],\"agent_id\":");
    try json.appendString(&out, allocator, input.owner_actor_id);
    try out.appendSlice(allocator, ",\"app_id\":");
    try json.appendString(&out, allocator, app_id);
    try out.appendSlice(allocator, ",\"run_id\":");
    try json.appendString(&out, allocator, runId(input.session_id));
    try out.appendSlice(allocator, ",\"metadata\":");
    try appendMetadataObject(&out, allocator, input);
    try out.appendSlice(allocator, ",\"infer\":false}");
    return out.toOwnedSlice(allocator);
}

pub fn updatePayload(allocator: std.mem.Allocator, input: WriteInput) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"text\":");
    try json.appendString(&out, allocator, input.content);
    try out.appendSlice(allocator, ",\"metadata\":");
    try appendMetadataObject(&out, allocator, input);
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

pub fn searchPayload(allocator: std.mem.Allocator, query_text: []const u8, limit: usize, owner_actor_id: ?[]const u8, session_id: ?[]const u8, include_sessions: bool, exact_key: ?[]const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"query\":");
    try json.appendString(&out, allocator, if (query_text.len > 0) query_text else "nullpantry agent memory");
    try out.appendSlice(allocator, ",\"filters\":");
    try appendFiltersObject(&out, allocator, owner_actor_id, session_id, include_sessions, exact_key, null);
    try out.print(allocator, ",\"top_k\":{d},\"threshold\":0.0,\"rerank\":false}}", .{requestResultLimit(limit)});
    return out.toOwnedSlice(allocator);
}

pub fn listPayload(allocator: std.mem.Allocator, owner_actor_id: ?[]const u8, session_id: ?[]const u8, include_sessions: bool, exact_key: ?[]const u8, category: ?[]const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"filters\":");
    try appendFiltersObject(&out, allocator, owner_actor_id, session_id, include_sessions, exact_key, category);
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

pub fn listQuery(allocator: std.mem.Allocator, page: usize, page_size: usize) ![]u8 {
    return std.fmt.allocPrint(allocator, "page={d}&page_size={d}", .{ positiveRequestLimit(page), listPageSize(page_size) });
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

pub fn agentMemoryArrayFromBody(allocator: std.mem.Allocator, body: []const u8, actor_id: []const u8, scopes_json: []const u8, exact_key: ?[]const u8, session_id: ?[]const u8, include_sessions: bool) ![]domain.AgentMemory {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.AgentMemoryStorageUnavailable;
    defer parsed.deinit();
    var out: std.ArrayListUnmanaged(domain.AgentMemory) = .empty;
    errdefer {
        for (out.items) |*entry| vendor.freeAgentMemory(allocator, entry);
        out.deinit(allocator);
    }
    try appendAgentMemoriesFromValue(allocator, &out, parsed.value, actor_id, scopes_json, exact_key, session_id, include_sessions);
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
            } else {
                vendor.freeAgentMemory(allocator, &candidate);
            }
            return;
        }
    }
    try out.append(allocator, candidate);
}

fn sameLogicalMemory(left: domain.AgentMemory, right: domain.AgentMemory) bool {
    return std.mem.eql(u8, left.key, right.key) and
        std.mem.eql(u8, left.actor_id, right.actor_id) and
        vendor.sameOptionalString(left.session_id, right.session_id);
}

fn timestampRank(entry: domain.AgentMemory) i64 {
    return std.fmt.parseInt(i64, entry.timestamp, 10) catch 0;
}

pub fn appendUniqueAgentMemory(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(domain.AgentMemory), entry: domain.AgentMemory) !void {
    return appendLatestAgentMemory(allocator, out, entry);
}

pub fn appendAgentMemoryPage(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(domain.AgentMemory), body: []const u8, actor_id: []const u8, scopes_json: []const u8, exact_key: ?[]const u8, session_id: ?[]const u8, include_sessions: bool) !usize {
    const parsed = try agentMemoryArrayFromBody(allocator, body, actor_id, scopes_json, exact_key, session_id, include_sessions);
    defer allocator.free(parsed);
    for (parsed) |entry| try appendLatestAgentMemory(allocator, out, entry);
    return parsed.len;
}

pub const PageFetchPlan = struct {
    page_size: usize,
    max_pages: usize,
};

pub fn pageFetchPlan(limit: usize) PageFetchPlan {
    const target = requestResultLimit(limit);
    const page_size = listPageSize(target);
    return .{
        .page_size = page_size,
        .max_pages = pageFetchMaxPages(target, page_size),
    };
}

pub fn shouldContinuePages(parsed_count: usize, page_size: usize) bool {
    return parsed_count != 0 and parsed_count >= page_size;
}

fn requestResultLimit(limit: usize) usize {
    return @min(positiveRequestLimit(limit), request_result_limit_max);
}

fn listPageSize(page_size: usize) usize {
    return @min(positiveRequestLimit(page_size), list_page_size_max);
}

fn positiveRequestLimit(limit: usize) usize {
    return @max(limit, 1);
}

fn pageFetchMaxPages(target: usize, page_size: usize) usize {
    const rounded_page_count = bounded_int.saturatingUsizeAdd(target, page_size - 1) / page_size;
    return bounded_int.saturatingUsizeAdd(rounded_page_count, page_fetch_lookahead_pages);
}

fn appendAgentMemoriesFromValue(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(domain.AgentMemory), value: std.json.Value, actor_id: []const u8, scopes_json: []const u8, exact_key: ?[]const u8, session_id: ?[]const u8, include_sessions: bool) !void {
    switch (value) {
        .array => |items| {
            for (items.items) |item| try appendAgentMemoriesFromValue(allocator, out, item, actor_id, scopes_json, exact_key, session_id, include_sessions);
        },
        .object => |obj| {
            if (try agentMemoryFromObject(allocator, obj, actor_id, scopes_json, exact_key, session_id, include_sessions)) |entry| {
                try appendLatestAgentMemory(allocator, out, entry);
                return;
            }
            if (obj.get("results")) |results| try appendAgentMemoriesFromValue(allocator, out, results, actor_id, scopes_json, exact_key, session_id, include_sessions);
            if (obj.get("memories")) |memories| try appendAgentMemoriesFromValue(allocator, out, memories, actor_id, scopes_json, exact_key, session_id, include_sessions);
            if (obj.get("data")) |data| try appendAgentMemoriesFromValue(allocator, out, data, actor_id, scopes_json, exact_key, session_id, include_sessions);
        },
        else => {},
    }
}

fn appendMetadataFilter(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
    try out.appendSlice(allocator, ",{\"metadata.");
    try out.appendSlice(allocator, key);
    try out.appendSlice(allocator, "\":");
    try json.appendString(out, allocator, value);
    try out.append(allocator, '}');
}

fn appendFiltersObject(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, owner_actor_id: ?[]const u8, session_id: ?[]const u8, include_sessions: bool, exact_key: ?[]const u8, category: ?[]const u8) !void {
    try out.appendSlice(allocator, "{\"AND\":[{\"app_id\":");
    try json.appendString(out, allocator, app_id);
    try out.append(allocator, '}');
    try appendMetadataFilter(out, allocator, "nullpantry_backend", store_name);
    try appendMetadataFilter(out, allocator, "nullpantry_type", "agent_memory");
    if (owner_actor_id) |owner| {
        try out.appendSlice(allocator, ",{\"agent_id\":");
        try json.appendString(out, allocator, owner);
        try out.append(allocator, '}');
    }
    if (!include_sessions) {
        try out.appendSlice(allocator, ",{\"run_id\":");
        try json.appendString(out, allocator, runId(session_id));
        try out.append(allocator, '}');
    }
    if (exact_key) |key| {
        try appendMetadataFilter(out, allocator, "nullpantry_key", key);
    }
    if (category) |cat| {
        try appendMetadataFilter(out, allocator, "nullpantry_category", cat);
    }
    try out.appendSlice(allocator, "]}");
}

fn agentMemoryFromObject(allocator: std.mem.Allocator, obj: std.json.ObjectMap, actor_id: []const u8, scopes_json: []const u8, exact_key: ?[]const u8, session_id: ?[]const u8, include_sessions: bool) !?domain.AgentMemory {
    const metadata = vendor.objectField(obj, &.{ "metadata", "meta" }) orelse return null;
    if (!std.mem.eql(u8, vendor.stringishField(metadata, &.{"nullpantry_backend"}) orelse "", "mem0")) return null;
    if (!std.mem.eql(u8, vendor.stringishField(metadata, &.{"nullpantry_type"}) orelse "", "agent_memory")) return null;
    const status = vendor.stringishField(metadata, &.{ "nullpantry_status", "status" }) orelse "proposed";
    if (std.ascii.eqlIgnoreCase(status, "deleted")) return null;

    const key = vendor.stringishField(metadata, &.{ "nullpantry_key", "key" }) orelse return null;
    if (exact_key) |needle| {
        if (!std.mem.eql(u8, key, needle)) return null;
    }
    const candidate_session_id = vendor.nullableStringishField(metadata, &.{ "nullpantry_session_id", "session_id" });
    if (session_id) |sid| {
        if (candidate_session_id == null or !std.mem.eql(u8, candidate_session_id.?, sid)) return null;
    } else if (!include_sessions and candidate_session_id != null) {
        return null;
    }

    const content = vendor.stringishField(metadata, &.{"nullpantry_content"}) orelse vendor.stringishField(obj, &.{ "memory", "text", "data" }) orelse return null;
    const owner = vendor.stringishField(metadata, &.{ "nullpantry_actor_id", "actor_id" }) orelse vendor.stringishField(obj, &.{"agent_id"}) orelse actor_id;
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
    const entry = domain.AgentMemory{
        .id = try allocator.dupe(u8, vendor.stringishField(obj, &.{ "id", "memory_id" }) orelse vendor.stringishField(metadata, &.{"nullpantry_remote_id"}) orelse key),
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

fn appendMetadataObject(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, input: WriteInput) !void {
    const scope = try access.agentMemoryScope(allocator, input.owner_actor_id, input.session_id, input.requested_scope);
    defer allocator.free(scope);
    const permissions = try access.agentMemoryPermissions(allocator, input.owner_actor_id, input.requested_scope, input.requested_permissions_json);
    defer allocator.free(permissions);
    try out.appendSlice(allocator, "{\"nullpantry_backend\":\"mem0\",\"nullpantry_type\":\"agent_memory\",\"nullpantry_key\":");
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

fn scoreFromObject(obj: std.json.ObjectMap) ?f64 {
    for ([_][]const u8{ "score", "similarity", "relevance" }) |name| {
        const value = obj.get(name) orelse continue;
        return vendor.valueAsF64(value);
    }
    return null;
}

fn memoryId(allocator: std.mem.Allocator, owner_actor_id: []const u8, session_id: ?[]const u8, key: []const u8) ![]u8 {
    var h = std.hash.Wyhash.init(0xd1b5_4a32_0577_aa19);
    h.update(owner_actor_id);
    h.update("\x00");
    h.update(runId(session_id));
    h.update("\x00");
    h.update(key);
    return std.fmt.allocPrint(allocator, "mem0_pending_{x}", .{h.final()});
}

test "mem0 request windows are bounded without overflow" {
    try std.testing.expectEqual(@as(usize, 1), requestResultLimit(0));
    try std.testing.expectEqual(@as(usize, 42), requestResultLimit(42));
    try std.testing.expectEqual(request_result_limit_max, requestResultLimit(std.math.maxInt(usize)));

    try std.testing.expectEqual(@as(usize, 1), listPageSize(0));
    try std.testing.expectEqual(@as(usize, 42), listPageSize(42));
    try std.testing.expectEqual(list_page_size_max, listPageSize(std.math.maxInt(usize)));

    const query = try listQuery(std.testing.allocator, 0, std.math.maxInt(usize));
    defer std.testing.allocator.free(query);
    try std.testing.expectEqualStrings("page=1&page_size=200", query);

    const search = try searchPayload(std.testing.allocator, "Zig", std.math.maxInt(usize), null, null, true, null);
    defer std.testing.allocator.free(search);
    try std.testing.expect(std.mem.indexOf(u8, search, "\"top_k\":5000") != null);
}

test "mem0 page fetch plan is bounded without overflow" {
    const minimum = pageFetchPlan(0);
    try std.testing.expectEqual(@as(usize, 1), minimum.page_size);
    try std.testing.expectEqual(@as(usize, 2), minimum.max_pages);

    const multi_page = pageFetchPlan(450);
    try std.testing.expectEqual(list_page_size_max, multi_page.page_size);
    try std.testing.expectEqual(@as(usize, 4), multi_page.max_pages);

    const capped = pageFetchPlan(std.math.maxInt(usize));
    try std.testing.expectEqual(list_page_size_max, capped.page_size);
    try std.testing.expectEqual(@as(usize, 26), capped.max_pages);
}

test "mem0 mapping builds v3 payloads and filters" {
    const add = try addPayload(std.testing.allocator, .{
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
    defer std.testing.allocator.free(add);
    try std.testing.expect(std.mem.indexOf(u8, add, "\"agent_id\":\"shared:team:alpha\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, add, "\"app_id\":\"nullpantry\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, add, "\"run_id\":\"session-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, add, "\"infer\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, add, "\"nullpantry_backend\":\"mem0\"") != null);

    const search = try searchPayload(std.testing.allocator, "Zig", 10, "shared:team:alpha", null, false, "pref.language");
    defer std.testing.allocator.free(search);
    try std.testing.expect(std.mem.indexOf(u8, search, "\"run_id\":\"__nullpantry_global__\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, search, "\"metadata.nullpantry_backend\":\"mem0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, search, "\"metadata.nullpantry_type\":\"agent_memory\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, search, "\"metadata.nullpantry_key\":\"pref.language\"") != null);

    const url = try apiUrl(std.testing.allocator, "https://api.mem0.ai/v3/", "/v1/memories/abc", "", false);
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://api.mem0.ai/v1/memories/abc", url);
}

test "mem0 parser hydrates metadata and enforces nullpantry visibility" {
    const body =
        \\{"results":[
        \\  {"id":"mem-a","memory":"Prefer Zig examples","score":0.91,"metadata":{"nullpantry_backend":"mem0","nullpantry_type":"agent_memory","nullpantry_key":"pref.language","nullpantry_content":"Prefer Zig examples","nullpantry_category":"preference","nullpantry_session_id":null,"nullpantry_actor_id":"agent:a","nullpantry_writer_actor_id":"agent:a","nullpantry_scope":"agent:agent:a","nullpantry_permissions":["actor:agent:a"],"nullpantry_timestamp_ms":42,"nullpantry_status":"verified"}},
        \\  {"id":"mem-b","memory":"Team fact","metadata":{"nullpantry_backend":"mem0","nullpantry_type":"agent_memory","nullpantry_key":"team.fact","nullpantry_content":"Team fact","nullpantry_category":"core","nullpantry_session_id":null,"nullpantry_actor_id":"shared:team:alpha","nullpantry_writer_actor_id":"agent:a","nullpantry_scope":"team:alpha","nullpantry_permissions":["team:alpha"],"nullpantry_timestamp_ms":43,"nullpantry_status":"proposed"}}
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
    try std.testing.expect(visible[0].score.? > 0.9);

    const isolated = try agentMemoryArrayFromBody(std.testing.allocator, body, "agent:b", "[\"agent:agent:b\"]", null, null, false);
    defer {
        for (isolated) |*entry| vendor.freeAgentMemory(std.testing.allocator, entry);
        std.testing.allocator.free(isolated);
    }
    try std.testing.expectEqual(@as(usize, 0), isolated.len);
}

test "mem0 parser keeps latest logical memory and plans bounded pagination" {
    const body =
        \\{"results":[
        \\  {"id":"old","memory":"Old","metadata":{"nullpantry_backend":"mem0","nullpantry_type":"agent_memory","nullpantry_key":"pref.language","nullpantry_content":"Old","nullpantry_category":"preference","nullpantry_session_id":null,"nullpantry_actor_id":"agent:a","nullpantry_writer_actor_id":"agent:a","nullpantry_scope":"agent:agent:a","nullpantry_permissions":["actor:agent:a"],"nullpantry_timestamp_ms":1,"nullpantry_status":"proposed"}},
        \\  {"id":"new","memory":"New","metadata":{"nullpantry_backend":"mem0","nullpantry_type":"agent_memory","nullpantry_key":"pref.language","nullpantry_content":"New","nullpantry_category":"preference","nullpantry_session_id":null,"nullpantry_actor_id":"agent:a","nullpantry_writer_actor_id":"agent:a","nullpantry_scope":"agent:agent:a","nullpantry_permissions":["actor:agent:a"],"nullpantry_timestamp_ms":2,"nullpantry_status":"verified"}}
        \\]}
    ;
    const visible = try agentMemoryArrayFromBody(std.testing.allocator, body, "agent:a", "[\"agent:agent:a\"]", null, null, false);
    defer {
        for (visible) |*entry| vendor.freeAgentMemory(std.testing.allocator, entry);
        std.testing.allocator.free(visible);
    }
    try std.testing.expectEqual(@as(usize, 1), visible.len);
    try std.testing.expectEqualStrings("new", visible[0].id);
    try std.testing.expectEqualStrings("New", visible[0].content);
    try std.testing.expectEqualStrings("verified", visible[0].status);

    const plan = pageFetchPlan(450);
    try std.testing.expectEqual(@as(usize, 200), plan.page_size);
    try std.testing.expectEqual(@as(usize, 4), plan.max_pages);
    try std.testing.expect(shouldContinuePages(200, 200));
    try std.testing.expect(!shouldContinuePages(0, 200));
    try std.testing.expect(!shouldContinuePages(37, 200));
}
