const std = @import("std");

const access = @import("access.zig");
const bounded_int = @import("bounded_int.zig");
const domain = @import("domain.zig");
const ids = @import("ids.zig");
const json = @import("json_util.zig");
const vendor = @import("agent_memory_vendor.zig");
const api_profiles = @import("agent_memory_api_profiles.zig");

pub const is_compiled = true;

pub const default_base_url = api_profiles.hindsight_default_base_url;
pub const default_bank_id = "nullpantry";
const store_name = "hindsight";
const recall_token_budget_min: usize = 1024;
const recall_token_budget_max: usize = 16_384;
const recall_token_budget_per_result: usize = 1024;
const list_query_limit_max: usize = 200;
const page_fetch_size_max: usize = 200;
const page_fetch_page_cap: usize = 25;
const page_fetch_lookahead_pages: usize = 5;

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

pub fn bankId(configured: ?[]const u8) []const u8 {
    if (configured) |id| {
        const trimmed = std.mem.trim(u8, id, " \t\r\n");
        if (trimmed.len > 0) return trimmed;
    }
    return default_bank_id;
}

pub fn apiUrl(allocator: std.mem.Allocator, base_url: []const u8, bank_id: []const u8, path: []const u8, query: []const u8, allow_insecure_http: bool) ![]u8 {
    const bank = try vendor.percentEncode(allocator, bank_id);
    defer allocator.free(bank);
    const prefix = try std.fmt.allocPrint(allocator, "/default/banks/{s}", .{bank});
    defer allocator.free(prefix);
    const separator = if (path.len > 0 and path[0] == '/') "" else "/";
    const full_path = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ prefix, separator, path });
    defer allocator.free(full_path);
    return vendor.httpUrl(allocator, base_url, full_path, query, .{
        .version_prefix = "/v1",
        .allow_insecure_http = allow_insecure_http,
    });
}

pub fn retainPayload(allocator: std.mem.Allocator, input: WriteInput) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    const context = try memoryContext(allocator, input);
    defer allocator.free(context);

    try out.appendSlice(allocator, "{\"items\":[{\"content\":");
    try json.appendString(&out, allocator, input.content);
    try out.appendSlice(allocator, ",\"context\":");
    try json.appendString(&out, allocator, context);
    try out.appendSlice(allocator, ",\"metadata\":");
    try appendMetadataObject(&out, allocator, input);
    try out.appendSlice(allocator, ",\"tags\":");
    try appendTagsArray(&out, allocator, input.owner_actor_id, input.session_id, input.key, input.category, input.requested_scope, input.status);
    try out.appendSlice(allocator, "}],\"async\":false}");
    return out.toOwnedSlice(allocator);
}

pub fn recallPayload(allocator: std.mem.Allocator, query_text: []const u8, owner_actor_id: ?[]const u8, session_id: ?[]const u8, include_sessions: bool, exact_key: ?[]const u8, limit: usize) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"query\":");
    try json.appendString(&out, allocator, if (query_text.len > 0) query_text else "nullpantry agent memory");
    try out.appendSlice(allocator, ",\"budget\":\"low\",\"max_tokens\":");
    try out.print(allocator, "{d}", .{recallTokenBudget(limit)});
    try out.appendSlice(allocator, ",\"types\":[\"world\",\"experience\",\"observation\"],\"tags\":");
    try appendFilterTagsArray(&out, allocator, owner_actor_id, session_id, include_sessions, exact_key);
    try out.appendSlice(allocator, ",\"tags_match\":\"all_strict\"}");
    return out.toOwnedSlice(allocator);
}

pub fn listQuery(allocator: std.mem.Allocator, q: ?[]const u8, limit: usize, offset: usize) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var first = true;
    try appendQueryUsize(allocator, &out, &first, "limit", listQueryLimit(limit));
    try appendQueryUsize(allocator, &out, &first, "offset", offset);
    if (q) |value| {
        if (value.len > 0) try appendQueryString(allocator, &out, &first, "q", value);
    }
    return out.toOwnedSlice(allocator);
}

pub fn agentMemoryFromWriteInput(allocator: std.mem.Allocator, input: WriteInput) !domain.AgentMemory {
    const scope = try access.agentMemoryScope(allocator, input.owner_actor_id, input.session_id, input.requested_scope);
    defer allocator.free(scope);
    const permissions = try access.agentMemoryPermissions(allocator, input.owner_actor_id, input.requested_scope, input.requested_permissions_json);
    defer allocator.free(permissions);
    const fallback_id = try memoryId(allocator, input.owner_actor_id, input.session_id, input.key, input.timestamp_ms);
    errdefer allocator.free(fallback_id);
    return .{
        .id = fallback_id,
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
    const events = try agentMemoryEventArrayFromBody(allocator, body, actor_id, scopes_json, exact_key, session_id, include_sessions);
    return activeAgentMemoryPage(allocator, events, std.math.maxInt(usize), 0);
}

pub fn agentMemoryEventArrayFromBody(allocator: std.mem.Allocator, body: []const u8, actor_id: []const u8, scopes_json: []const u8, exact_key: ?[]const u8, session_id: ?[]const u8, include_sessions: bool) ![]domain.AgentMemory {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.AgentMemoryStorageUnavailable;
    defer parsed.deinit();
    var latest: std.ArrayListUnmanaged(domain.AgentMemory) = .empty;
    errdefer {
        for (latest.items) |*entry| vendor.freeAgentMemory(allocator, entry);
        latest.deinit(allocator);
    }
    try appendAgentMemoriesFromValue(allocator, &latest, parsed.value, actor_id, scopes_json, exact_key, session_id, include_sessions);
    return latest.toOwnedSlice(allocator);
}

pub fn rawMemoryItemCountFromBody(allocator: std.mem.Allocator, body: []const u8) !usize {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return 0;
    defer parsed.deinit();
    return rawMemoryItemCountFromValue(parsed.value);
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
            continue;
        }
        vendor.freeAgentMemory(allocator, entry);
    }

    const page = try active.toOwnedSlice(allocator);
    allocator.free(owned);
    return page;
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

pub fn appendAgentMemoryPage(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(domain.AgentMemory), body: []const u8, actor_id: []const u8, scopes_json: []const u8, exact_key: ?[]const u8, session_id: ?[]const u8, include_sessions: bool) !usize {
    const raw_count = try rawMemoryItemCountFromBody(allocator, body);
    const parsed = try agentMemoryEventArrayFromBody(allocator, body, actor_id, scopes_json, exact_key, session_id, include_sessions);
    defer allocator.free(parsed);
    for (parsed) |entry| try appendLatestAgentMemory(allocator, out, entry);
    return raw_count;
}

pub const PageFetchPlan = struct {
    page_size: usize,
    max_pages: usize,
};

pub fn pageFetchPlan(limit: usize) PageFetchPlan {
    const target = positiveRequestLimit(limit);
    return .{
        .page_size = @min(target, page_fetch_size_max),
        .max_pages = pageFetchMaxPages(limit),
    };
}

pub fn shouldContinuePages(parsed_count: usize, requested_size: usize) bool {
    return parsed_count != 0 and parsed_count >= requested_size;
}

fn recallTokenBudget(limit: usize) usize {
    const requested = bounded_int.saturatingUsizeMul(positiveRequestLimit(limit), recall_token_budget_per_result);
    return @max(recall_token_budget_min, @min(requested, recall_token_budget_max));
}

fn listQueryLimit(limit: usize) usize {
    return @max(@as(usize, 1), @min(limit, list_query_limit_max));
}

fn positiveRequestLimit(limit: usize) usize {
    return @max(limit, 1);
}

fn pageFetchMaxPages(limit: usize) usize {
    const rounded_page_count = bounded_int.saturatingUsizeAdd(positiveRequestLimit(limit), page_fetch_size_max - 1) / page_fetch_size_max;
    const requested_pages = bounded_int.saturatingUsizeAdd(rounded_page_count, page_fetch_lookahead_pages);
    return @min(page_fetch_page_cap, requested_pages);
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
            if (obj.get("results")) |items| try appendAgentMemoriesFromValue(allocator, out, items, actor_id, scopes_json, exact_key, session_id, include_sessions);
            if (obj.get("items")) |items| try appendAgentMemoriesFromValue(allocator, out, items, actor_id, scopes_json, exact_key, session_id, include_sessions);
            if (obj.get("memories")) |items| try appendAgentMemoriesFromValue(allocator, out, items, actor_id, scopes_json, exact_key, session_id, include_sessions);
            if (obj.get("memory_units")) |items| try appendAgentMemoriesFromValue(allocator, out, items, actor_id, scopes_json, exact_key, session_id, include_sessions);
            if (obj.get("data")) |items| try appendAgentMemoriesFromValue(allocator, out, items, actor_id, scopes_json, exact_key, session_id, include_sessions);
        },
        else => {},
    }
}

fn rawMemoryItemCountFromValue(value: std.json.Value) usize {
    switch (value) {
        .array => |items| return items.items.len,
        .object => |obj| {
            if (isAgentMemoryObject(obj)) return 1;
            inline for ([_][]const u8{ "results", "items", "memories", "memory_units", "data" }) |name| {
                if (obj.get(name)) |child| {
                    const count = rawMemoryItemCountFromValue(child);
                    if (count > 0) return count;
                }
            }
            return 0;
        },
        else => return 0,
    }
}

fn isAgentMemoryObject(obj: std.json.ObjectMap) bool {
    const metadata = vendor.objectField(obj, &.{ "metadata", "meta" }) orelse return false;
    return std.mem.eql(u8, vendor.stringishField(metadata, &.{"nullpantry_backend"}) orelse "", store_name) and
        std.mem.eql(u8, vendor.stringishField(metadata, &.{"nullpantry_type"}) orelse "", "agent_memory");
}

fn isDeletedAgentMemory(entry: domain.AgentMemory) bool {
    return std.ascii.eqlIgnoreCase(entry.status, "deleted");
}

fn agentMemoryFromObject(allocator: std.mem.Allocator, obj: std.json.ObjectMap, actor_id: []const u8, scopes_json: []const u8, exact_key: ?[]const u8, session_id: ?[]const u8, include_sessions: bool) !?domain.AgentMemory {
    const metadata = vendor.objectField(obj, &.{ "metadata", "meta" }) orelse return null;
    if (!std.mem.eql(u8, vendor.stringishField(metadata, &.{"nullpantry_backend"}) orelse "", store_name)) return null;
    if (!std.mem.eql(u8, vendor.stringishField(metadata, &.{"nullpantry_type"}) orelse "", "agent_memory")) return null;

    const key = vendor.stringishField(metadata, &.{ "nullpantry_key", "key" }) orelse return null;
    if (exact_key) |needle| {
        if (!std.mem.eql(u8, key, needle)) return null;
    }
    const candidate_session_id = optionalMetadataString(metadata, &.{ "nullpantry_session_id", "session_id" });
    if (session_id) |sid| {
        if (candidate_session_id == null or !std.mem.eql(u8, candidate_session_id.?, sid)) return null;
    } else if (!include_sessions and candidate_session_id != null) {
        return null;
    }

    const content = vendor.stringishField(metadata, &.{"nullpantry_content"}) orelse vendor.stringishField(obj, &.{ "text", "content", "memory", "data" }) orelse return null;
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
    const entry = domain.AgentMemory{
        .id = try allocator.dupe(u8, vendor.stringishField(obj, &.{ "id", "memory_id", "chunk_id" }) orelse vendor.stringishField(metadata, &.{"nullpantry_remote_id"}) orelse key),
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
    try out.appendSlice(allocator, "{\"nullpantry_backend\":\"hindsight\",\"nullpantry_type\":\"agent_memory\"");
    try appendStringField(out, allocator, "nullpantry_key", input.key);
    try appendStringField(out, allocator, "nullpantry_content", input.content);
    try appendStringField(out, allocator, "nullpantry_category", input.category);
    if (input.session_id) |sid| try appendStringField(out, allocator, "nullpantry_session_id", sid);
    try appendStringField(out, allocator, "nullpantry_actor_id", input.owner_actor_id);
    try appendStringField(out, allocator, "nullpantry_writer_actor_id", input.writer_actor_id);
    try appendStringField(out, allocator, "nullpantry_scope", scope);
    try appendStringField(out, allocator, "nullpantry_permissions_json", permissions);
    try appendI64StringField(out, allocator, "nullpantry_timestamp_ms", input.timestamp_ms);
    try appendStringField(out, allocator, "nullpantry_status", input.status);
    if (input.metadata_json) |metadata_json| {
        const validated_metadata = try json.rawJsonObjectOrError(allocator, metadata_json, "{}");
        try appendStringField(out, allocator, "nullpantry_metadata_json", validated_metadata);
    }
    try out.append(allocator, '}');
}

fn appendStringField(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, name: []const u8, value: []const u8) !void {
    try out.append(allocator, ',');
    try json.appendString(out, allocator, name);
    try out.append(allocator, ':');
    try json.appendString(out, allocator, value);
}

fn appendI64StringField(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, name: []const u8, value: i64) !void {
    var buf: [32]u8 = undefined;
    const raw = try std.fmt.bufPrint(&buf, "{d}", .{value});
    try appendStringField(out, allocator, name, raw);
}

fn appendTagsArray(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, owner_actor_id: []const u8, session_id: ?[]const u8, key: []const u8, category: []const u8, scope: ?[]const u8, status: []const u8) !void {
    try out.append(allocator, '[');
    var first = true;
    try appendTag(out, allocator, &first, "nullpantry");
    try appendTag(out, allocator, &first, "nullpantry-agent-memory");
    try appendHashedTag(out, allocator, &first, "np-owner", owner_actor_id);
    try appendHashedTag(out, allocator, &first, "np-key", key);
    try appendHashedTag(out, allocator, &first, "np-session", session_id orelse "__global__");
    try appendSanitizedTag(out, allocator, &first, "np-category", category);
    try appendSanitizedTag(out, allocator, &first, "np-status", status);
    if (scope) |s| try appendHashedTag(out, allocator, &first, "np-scope", s);
    try out.append(allocator, ']');
}

fn appendFilterTagsArray(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, owner_actor_id: ?[]const u8, session_id: ?[]const u8, include_sessions: bool, exact_key: ?[]const u8) !void {
    try out.append(allocator, '[');
    var first = true;
    try appendTag(out, allocator, &first, "nullpantry");
    try appendTag(out, allocator, &first, "nullpantry-agent-memory");
    if (owner_actor_id) |owner| try appendHashedTag(out, allocator, &first, "np-owner", owner);
    if (!include_sessions) try appendHashedTag(out, allocator, &first, "np-session", session_id orelse "__global__");
    if (exact_key) |key| try appendHashedTag(out, allocator, &first, "np-key", key);
    try out.append(allocator, ']');
}

fn appendTag(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, first: *bool, value: []const u8) !void {
    if (!first.*) try out.append(allocator, ',');
    first.* = false;
    try json.appendString(out, allocator, value);
}

fn appendHashedTag(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, first: *bool, prefix: []const u8, value: []const u8) !void {
    const tag = try std.fmt.allocPrint(allocator, "{s}-{x}", .{ prefix, std.hash.Wyhash.hash(0x98f6_2d8e_6c7b_4d11, value) });
    defer allocator.free(tag);
    try appendTag(out, allocator, first, tag);
}

fn appendSanitizedTag(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, first: *bool, prefix: []const u8, value: []const u8) !void {
    const safe = try vendor.sanitizeSegment(allocator, value, 80, "default");
    defer allocator.free(safe);
    const tag = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ prefix, safe });
    defer allocator.free(tag);
    try appendTag(out, allocator, first, tag);
}

fn memoryContext(allocator: std.mem.Allocator, input: WriteInput) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "NullPantry agent memory\nkey: ");
    try out.appendSlice(allocator, input.key);
    try out.appendSlice(allocator, "\ncategory: ");
    try out.appendSlice(allocator, input.category);
    try out.appendSlice(allocator, "\nowner: ");
    try out.appendSlice(allocator, input.owner_actor_id);
    if (input.session_id) |sid| {
        try out.appendSlice(allocator, "\nsession: ");
        try out.appendSlice(allocator, sid);
    }
    try out.appendSlice(allocator, "\nstatus: ");
    try out.appendSlice(allocator, input.status);
    return out.toOwnedSlice(allocator);
}

fn optionalMetadataString(obj: std.json.ObjectMap, names: []const []const u8) ?[]const u8 {
    const value = vendor.nullableStringishField(obj, names) orelse return null;
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "null")) return null;
    return trimmed;
}

fn permissionsJson(allocator: std.mem.Allocator, metadata: std.json.ObjectMap) ![]u8 {
    return vendor.permissionsJsonField(allocator, metadata, "[]");
}

fn timestampString(allocator: std.mem.Allocator, metadata: std.json.ObjectMap, obj: std.json.ObjectMap) ![]u8 {
    if (vendor.stringishField(metadata, &.{"nullpantry_timestamp"})) |timestamp| return allocator.dupe(u8, timestamp);
    if (vendor.stringishField(metadata, &.{"nullpantry_timestamp_ms"})) |timestamp_ms| return allocator.dupe(u8, timestamp_ms);
    if (vendor.optionalI64Field(metadata, "nullpantry_timestamp_ms")) |timestamp_ms| return std.fmt.allocPrint(allocator, "{d}", .{timestamp_ms});
    if (vendor.stringishField(obj, &.{ "mentioned_at", "occurred_start", "created_at", "updated_at" })) |timestamp| return allocator.dupe(u8, timestamp);
    return std.fmt.allocPrint(allocator, "{d}", .{ids.nowMs()});
}

fn scoreFromObject(obj: std.json.ObjectMap) ?f64 {
    for ([_][]const u8{ "score", "similarity", "relevance" }) |name| {
        const value = obj.get(name) orelse continue;
        return vendor.valueAsF64(value);
    }
    return null;
}

fn timestampRank(entry: domain.AgentMemory) i64 {
    return std.fmt.parseInt(i64, entry.timestamp, 10) catch 0;
}

fn memoryId(allocator: std.mem.Allocator, owner_actor_id: []const u8, session_id: ?[]const u8, key: []const u8, timestamp_ms: i64) ![]u8 {
    var h = std.hash.Wyhash.init(0x1b64_f8bb_4dd7_c0b1);
    h.update(owner_actor_id);
    h.update("\x00");
    h.update(session_id orelse "");
    h.update("\x00");
    h.update(key);
    h.update("\x00");
    var buf: [32]u8 = undefined;
    const timestamp = try std.fmt.bufPrint(&buf, "{d}", .{timestamp_ms});
    h.update(timestamp);
    return std.fmt.allocPrint(allocator, "hindsight_pending_{x}", .{h.final()});
}

fn appendQueryUsize(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), first: *bool, name: []const u8, value: usize) !void {
    if (!first.*) try out.append(allocator, '&');
    first.* = false;
    try out.print(allocator, "{s}={d}", .{ name, value });
}

fn appendQueryString(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), first: *bool, name: []const u8, value: []const u8) !void {
    const encoded = try vendor.percentEncode(allocator, value);
    defer allocator.free(encoded);
    if (!first.*) try out.append(allocator, '&');
    first.* = false;
    try out.appendSlice(allocator, name);
    try out.append(allocator, '=');
    try out.appendSlice(allocator, encoded);
}

test "hindsight query windows are bounded without overflow" {
    try std.testing.expectEqual(recall_token_budget_min, recallTokenBudget(0));
    try std.testing.expectEqual(recall_token_budget_min, recallTokenBudget(1));
    try std.testing.expectEqual(@as(usize, 4096), recallTokenBudget(4));
    try std.testing.expectEqual(recall_token_budget_max, recallTokenBudget(100));
    try std.testing.expectEqual(recall_token_budget_max, recallTokenBudget(std.math.maxInt(usize)));

    try std.testing.expectEqual(@as(usize, 1), listQueryLimit(0));
    try std.testing.expectEqual(@as(usize, 42), listQueryLimit(42));
    try std.testing.expectEqual(list_query_limit_max, listQueryLimit(std.math.maxInt(usize)));
}

test "hindsight page fetch plan is bounded without overflow" {
    const minimum = pageFetchPlan(0);
    try std.testing.expectEqual(@as(usize, 1), minimum.page_size);
    try std.testing.expectEqual(@as(usize, 6), minimum.max_pages);

    const exact_page = pageFetchPlan(page_fetch_size_max);
    try std.testing.expectEqual(page_fetch_size_max, exact_page.page_size);
    try std.testing.expectEqual(@as(usize, 6), exact_page.max_pages);

    const multi_page = pageFetchPlan(1000);
    try std.testing.expectEqual(page_fetch_size_max, multi_page.page_size);
    try std.testing.expectEqual(@as(usize, 10), multi_page.max_pages);

    const huge = pageFetchPlan(std.math.maxInt(usize));
    try std.testing.expectEqual(page_fetch_size_max, huge.page_size);
    try std.testing.expectEqual(page_fetch_page_cap, huge.max_pages);
}

test "hindsight mapping builds retain payloads and filters" {
    const payload = try retainPayload(std.testing.allocator, .{
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
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"items\":[{\"content\":\"Prefer Zig examples\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"nullpantry_backend\":\"hindsight\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"nullpantry_permissions_json\":\"[\\\"team:alpha\\\"]\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"nullpantry_metadata_json\":\"{\\\"source\\\":\\\"test\\\"}\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"tags\":[\"nullpantry\",\"nullpantry-agent-memory\"") != null);

    const recall = try recallPayload(std.testing.allocator, "Zig", "shared:team:alpha", null, false, "pref.language", 10);
    defer std.testing.allocator.free(recall);
    try std.testing.expect(std.mem.indexOf(u8, recall, "\"budget\":\"low\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, recall, "\"tags_match\":\"all_strict\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, recall, "\"types\":[\"world\",\"experience\",\"observation\"]") != null);

    const list_query = try listQuery(std.testing.allocator, "pref.language", 500, 20);
    defer std.testing.allocator.free(list_query);
    try std.testing.expectEqualStrings("limit=200&offset=20&q=pref.language", list_query);

    const url = try apiUrl(std.testing.allocator, "https://api.hindsight.vectorize.io/v1/", "team bank", "/memories/list", list_query, false);
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://api.hindsight.vectorize.io/v1/default/banks/team%20bank/memories/list?limit=200&offset=20&q=pref.language", url);

    const raw_count = try rawMemoryItemCountFromBody(std.testing.allocator, "{\"items\":[{\"metadata\":{}},{\"metadata\":{}}]}");
    try std.testing.expectEqual(@as(usize, 2), raw_count);
    const single_count = try rawMemoryItemCountFromBody(
        std.testing.allocator,
        "{\"id\":\"one\",\"metadata\":{\"nullpantry_backend\":\"hindsight\",\"nullpantry_type\":\"agent_memory\"}}",
    );
    try std.testing.expectEqual(@as(usize, 1), single_count);
}

test "hindsight parser hydrates latest visible agent memory and tombstones deleted entries" {
    const body =
        \\{"results":[
        \\  {"id":"old","text":"Old extracted","metadata":{"nullpantry_backend":"hindsight","nullpantry_type":"agent_memory","nullpantry_key":"pref.language","nullpantry_content":"Old","nullpantry_category":"preference","nullpantry_actor_id":"agent:a","nullpantry_writer_actor_id":"agent:a","nullpantry_scope":"agent:agent:a","nullpantry_permissions_json":"[\"actor:agent:a\"]","nullpantry_timestamp_ms":"1","nullpantry_status":"proposed"}},
        \\  {"id":"new","text":"New extracted","metadata":{"nullpantry_backend":"hindsight","nullpantry_type":"agent_memory","nullpantry_key":"pref.language","nullpantry_content":"New","nullpantry_category":"preference","nullpantry_actor_id":"agent:a","nullpantry_writer_actor_id":"agent:a","nullpantry_scope":"agent:agent:a","nullpantry_permissions_json":"[\"actor:agent:a\"]","nullpantry_timestamp_ms":"2","nullpantry_status":"verified"}},
        \\  {"id":"team","text":"Team fact","metadata":{"nullpantry_backend":"hindsight","nullpantry_type":"agent_memory","nullpantry_key":"team.fact","nullpantry_content":"Team fact","nullpantry_category":"core","nullpantry_actor_id":"shared:team:alpha","nullpantry_writer_actor_id":"agent:a","nullpantry_scope":"team:alpha","nullpantry_permissions_json":"[\"team:alpha\"]","nullpantry_timestamp_ms":"3","nullpantry_status":"proposed"}},
        \\  {"id":"gone","text":"Gone","metadata":{"nullpantry_backend":"hindsight","nullpantry_type":"agent_memory","nullpantry_key":"old.fact","nullpantry_content":"Gone","nullpantry_category":"core","nullpantry_actor_id":"agent:a","nullpantry_writer_actor_id":"agent:a","nullpantry_scope":"agent:agent:a","nullpantry_permissions_json":"[\"actor:agent:a\"]","nullpantry_timestamp_ms":"4","nullpantry_status":"deleted"}}
        \\]}
    ;
    const events = try agentMemoryEventArrayFromBody(std.testing.allocator, body, "agent:a", "[\"agent:agent:a\",\"team:alpha\"]", null, null, false);
    defer {
        for (events) |*entry| vendor.freeAgentMemory(std.testing.allocator, entry);
        std.testing.allocator.free(events);
    }
    try std.testing.expectEqual(@as(usize, 3), events.len);
    var saw_deleted = false;
    for (events) |entry| {
        if (std.mem.eql(u8, entry.key, "old.fact") and std.mem.eql(u8, entry.status, "deleted")) saw_deleted = true;
    }
    try std.testing.expect(saw_deleted);

    const visible = try agentMemoryArrayFromBody(std.testing.allocator, body, "agent:a", "[\"agent:agent:a\",\"team:alpha\"]", null, null, false);
    defer {
        for (visible) |*entry| vendor.freeAgentMemory(std.testing.allocator, entry);
        std.testing.allocator.free(visible);
    }
    try std.testing.expectEqual(@as(usize, 2), visible.len);
    try std.testing.expectEqualStrings(store_name, visible[0].store);
    try std.testing.expectEqualStrings("New", visible[0].content);
    try std.testing.expectEqualStrings("verified", visible[0].status);

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

test "hindsight tombstones survive cross-page reduction" {
    const deleted_page =
        \\{"items":[
        \\  {"id":"gone-new","text":"Gone","metadata":{"nullpantry_backend":"hindsight","nullpantry_type":"agent_memory","nullpantry_key":"old.fact","nullpantry_content":"Gone","nullpantry_category":"core","nullpantry_actor_id":"agent:a","nullpantry_writer_actor_id":"agent:a","nullpantry_scope":"agent:agent:a","nullpantry_permissions_json":"[\"actor:agent:a\"]","nullpantry_timestamp_ms":"20","nullpantry_status":"deleted"}}
        \\]}
    ;
    const stale_page =
        \\{"items":[
        \\  {"id":"old-active","text":"Old","metadata":{"nullpantry_backend":"hindsight","nullpantry_type":"agent_memory","nullpantry_key":"old.fact","nullpantry_content":"Old","nullpantry_category":"core","nullpantry_actor_id":"agent:a","nullpantry_writer_actor_id":"agent:a","nullpantry_scope":"agent:agent:a","nullpantry_permissions_json":"[\"actor:agent:a\"]","nullpantry_timestamp_ms":"10","nullpantry_status":"verified"}}
        \\]}
    ;
    var merged: std.ArrayListUnmanaged(domain.AgentMemory) = .empty;
    errdefer {
        for (merged.items) |*entry| vendor.freeAgentMemory(std.testing.allocator, entry);
        merged.deinit(std.testing.allocator);
    }

    try std.testing.expectEqual(@as(usize, 1), try appendAgentMemoryPage(std.testing.allocator, &merged, deleted_page, "agent:a", "[\"agent:agent:a\"]", null, null, false));
    try std.testing.expectEqual(@as(usize, 1), try appendAgentMemoryPage(std.testing.allocator, &merged, stale_page, "agent:a", "[\"agent:agent:a\"]", null, null, false));

    const owned = try merged.toOwnedSlice(std.testing.allocator);
    const visible = try activeAgentMemoryPage(std.testing.allocator, owned, 10, 0);
    defer {
        for (visible) |*entry| vendor.freeAgentMemory(std.testing.allocator, entry);
        std.testing.allocator.free(visible);
    }
    try std.testing.expectEqual(@as(usize, 0), visible.len);
}
