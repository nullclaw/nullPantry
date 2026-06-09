const std = @import("std");
const access = @import("access.zig");
const agent_memory_runtime = @import("agent_memory_runtime.zig");
const agent_memory_test_helpers = @import("agent_memory_test_helpers.zig");
const bounded_int = @import("bounded_int.zig");
const digest = @import("digest.zig");
const domain = @import("domain.zig");
const ids = @import("ids.zig");
const json = @import("json_util.zig");
const retrieval = @import("retrieval.zig");

pub const Input = struct {
    key: []const u8,
    content: []const u8,
    category: []const u8 = "core",
    session_id: ?[]const u8 = null,
    scope: ?[]const u8 = null,
    permissions_json: []const u8 = "[]",
    metadata_json: []const u8 = "{}",
    actor_id: ?[]const u8 = null,
    writer_actor_id: ?[]const u8 = null,
    actor_scopes_json: ?[]const u8 = null,
    actor_capabilities_json: ?[]const u8 = null,
    operation: domain.AgentMemoryOperation = .put,
    suppress_feed: bool = false,
    suppress_runtime_feed: bool = false,
    event_order: ?EventOrder = null,
};

pub const EventOrder = struct {
    timestamp_ms: i64,
    origin_instance_id: []const u8,
    origin_sequence: i64,
};

pub fn normalizeInput(input: Input) Input {
    var out = input;
    out.session_id = access.normalizeSessionId(input.session_id);
    return out;
}

pub fn runtimeEventOrder(event_order: ?EventOrder) ?agent_memory_runtime.EventOrder {
    const order = event_order orelse return null;
    return .{
        .timestamp_ms = order.timestamp_ms,
        .origin_instance_id = order.origin_instance_id,
        .origin_sequence = order.origin_sequence,
    };
}

pub fn eventMetadataJson(allocator: std.mem.Allocator, event_order: EventOrder, user_metadata_json: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"_feed_event\":{\"timestamp_ms\":");
    try out.print(allocator, "{d}", .{event_order.timestamp_ms});
    try out.appendSlice(allocator, ",\"origin_instance_id\":");
    try json.appendString(&out, allocator, event_order.origin_instance_id);
    try out.appendSlice(allocator, ",\"origin_sequence\":");
    try out.print(allocator, "{d}", .{event_order.origin_sequence});
    try out.appendSlice(allocator, "},\"user\":");
    try json.appendRawJsonObject(&out, allocator, user_metadata_json);
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

pub fn storedMetadataJson(allocator: std.mem.Allocator, input: Input) ![]u8 {
    const event_order = input.event_order orelse return allocator.dupe(u8, input.metadata_json);
    return eventMetadataJson(allocator, event_order, input.metadata_json);
}

pub fn metadataJsonWithEventOrder(allocator: std.mem.Allocator, event_order: EventOrder, existing_metadata_json: []const u8) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, existing_metadata_json, .{}) catch null;
    defer if (parsed) |*value| value.deinit();
    const user_metadata_json = blk: {
        if (parsed) |metadata| {
            if (metadata.value == .object) {
                if (metadata.value.object.get("user")) |user_value| {
                    break :blk try json.jsonFromValue(allocator, user_value);
                }
            }
        }
        break :blk try allocator.dupe(u8, existing_metadata_json);
    };
    defer allocator.free(user_metadata_json);
    return eventMetadataJson(allocator, event_order, user_metadata_json);
}

pub fn compareEventOrder(input: EventOrder, existing_timestamp_ms: i64, existing_origin_instance_id: []const u8, existing_origin_sequence: i64) i8 {
    if (input.timestamp_ms < existing_timestamp_ms) return -1;
    if (input.timestamp_ms > existing_timestamp_ms) return 1;
    return switch (std.mem.order(u8, input.origin_instance_id, existing_origin_instance_id)) {
        .lt => -1,
        .gt => 1,
        .eq => if (input.origin_sequence < existing_origin_sequence) -1 else if (input.origin_sequence > existing_origin_sequence) 1 else 0,
    };
}

pub fn compareInputToStoredMetadata(allocator: std.mem.Allocator, input_order: EventOrder, stored_timestamp_ms: i64, stored_metadata_json: []const u8) !i8 {
    var existing_timestamp_ms = stored_timestamp_ms;
    var existing_origin_instance_id: []const u8 = "";
    var existing_origin_sequence: i64 = 0;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, stored_metadata_json, .{}) catch null;
    defer if (parsed) |*value| value.deinit();
    if (parsed) |metadata| {
        if (metadata.value == .object) {
            if (metadata.value.object.get("_feed_event")) |feed_value| {
                if (feed_value == .object) {
                    existing_timestamp_ms = json.intField(feed_value.object, "timestamp_ms") orelse existing_timestamp_ms;
                    existing_origin_instance_id = json.stringField(feed_value.object, "origin_instance_id") orelse existing_origin_instance_id;
                    existing_origin_sequence = json.intField(feed_value.object, "origin_sequence") orelse existing_origin_sequence;
                }
            }
        }
    }

    return compareEventOrder(input_order, existing_timestamp_ms, existing_origin_instance_id, existing_origin_sequence);
}

pub fn tombstoneSessionKey(session_id: ?[]const u8) []const u8 {
    return session_id orelse "__global__";
}

pub fn projectionId(allocator: std.mem.Allocator, actor_id: []const u8, session_id: ?[]const u8, key: []const u8) ![]u8 {
    const hex = digest.sha256PartsHex(&.{ actor_id, session_id orelse "", key });
    return std.fmt.allocPrint(allocator, "agm_{s}", .{hex[0..]});
}

pub fn ignoredProjection(allocator: std.mem.Allocator, input: Input, owner_actor_id: []const u8, writer_actor_id: []const u8) !domain.AgentMemory {
    const scope = try access.agentMemoryScope(allocator, owner_actor_id, input.session_id, input.scope);
    defer allocator.free(scope);
    const permissions = try access.agentMemoryPermissions(allocator, owner_actor_id, input.scope, input.permissions_json);
    defer allocator.free(permissions);
    const timestamp_ms = if (input.event_order) |event_order| event_order.timestamp_ms else ids.nowMs();
    return .{
        .id = try projectionId(allocator, owner_actor_id, input.session_id, input.key),
        .key = try allocator.dupe(u8, input.key),
        .content = try allocator.dupe(u8, input.content),
        .category = try allocator.dupe(u8, input.category),
        .timestamp = try std.fmt.allocPrint(allocator, "{d}", .{timestamp_ms}),
        .session_id = if (input.session_id) |sid| try allocator.dupe(u8, sid) else null,
        .actor_id = try allocator.dupe(u8, owner_actor_id),
        .writer_actor_id = try allocator.dupe(u8, writer_actor_id),
        .scope = try allocator.dupe(u8, scope),
        .permissions_json = try allocator.dupe(u8, permissions),
        .status = try allocator.dupe(u8, "ignored"),
    };
}

pub fn appendSlice(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(domain.AgentMemory), entries: []domain.AgentMemory) !void {
    for (entries) |*entry| {
        try out.append(allocator, entry.*);
        detachResult(entry);
    }
}

pub fn tagStore(allocator: std.mem.Allocator, entry: *domain.AgentMemory, store_name: []const u8) !void {
    if (entry.store.len > 0) allocator.free(entry.store);
    entry.store = try allocator.dupe(u8, store_name);
}

pub fn tagSliceStore(allocator: std.mem.Allocator, entries: []domain.AgentMemory, store_name: []const u8) !void {
    for (entries) |*entry| try tagStore(allocator, entry, store_name);
}

pub fn appendMissingSlice(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(domain.AgentMemory), entries: []domain.AgentMemory) !void {
    for (entries) |*entry| {
        if (sliceContains(out.items, entry.*)) {
            agent_memory_runtime.freeAgentMemory(allocator, entry);
            continue;
        }
        try out.append(allocator, entry.*);
        detachResult(entry);
    }
}

pub fn freeArrayList(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(domain.AgentMemory)) void {
    for (out.items) |*entry| agent_memory_runtime.freeAgentMemory(allocator, entry);
    out.deinit(allocator);
}

pub fn freeSlice(allocator: std.mem.Allocator, entries: []domain.AgentMemory) void {
    for (entries) |*entry| agent_memory_runtime.freeAgentMemory(allocator, entry);
    allocator.free(entries);
}

pub fn pageArrayList(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(domain.AgentMemory), limit: usize, offset: usize) ![]domain.AgentMemory {
    const merged = try out.toOwnedSlice(allocator);
    out.* = .empty;
    return agent_memory_runtime.pageAgentMemorySlice(allocator, merged, limit, offset);
}

pub fn windowPrefetchLimit(limit: usize, offset: usize) usize {
    if (limit == 0) return 0;
    return bounded_int.saturatingUsizeAdd(offset, limit);
}

pub fn backendWindowFetchLimit(limit: usize) usize {
    if (limit == 0) return 0;
    if (limit == std.math.maxInt(usize)) return 1000;
    return @min(@as(usize, 1000), @max(@as(usize, 128), limit));
}

pub fn backendWindowOffsetAfterFetch(offset: usize, fetched: usize) usize {
    return bounded_int.saturatingUsizeAdd(offset, fetched);
}

pub fn backendWindowOffsetI64(offset: usize) i64 {
    return bounded_int.usizeToI64Saturating(offset);
}

pub fn sortResults(items: []domain.AgentMemory) void {
    std.mem.sort(domain.AgentMemory, items, {}, struct {
        fn lessThan(_: void, a: domain.AgentMemory, b: domain.AgentMemory) bool {
            const a_score = a.score orelse 0;
            const b_score = b.score orelse 0;
            if (a_score != b_score) return a_score > b_score;
            const a_ts = std.fmt.parseInt(i64, a.timestamp, 10) catch 0;
            const b_ts = std.fmt.parseInt(i64, b.timestamp, 10) catch 0;
            if (a_ts != b_ts) return a_ts > b_ts;
            return std.mem.order(u8, a.store, b.store) == .lt;
        }
    }.lessThan);
}

pub fn trimResults(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(domain.AgentMemory), limit: usize) void {
    if (out.items.len <= limit) return;
    for (out.items[limit..]) |*entry| agent_memory_runtime.freeAgentMemory(allocator, entry);
    out.shrinkRetainingCapacity(limit);
}

pub fn scoreOwnedList(allocator: std.mem.Allocator, query: []const u8, limit: usize, entries: []domain.AgentMemory) ![]domain.AgentMemory {
    var out: std.ArrayListUnmanaged(domain.AgentMemory) = .empty;
    errdefer {
        for (out.items) |*entry| agent_memory_runtime.freeAgentMemory(allocator, entry);
        out.deinit(allocator);
    }
    defer {
        for (entries) |*entry| agent_memory_runtime.freeAgentMemory(allocator, entry);
        allocator.free(entries);
    }
    for (entries) |*entry| {
        const score = retrieval.lexicalScore(query, entry.key) + retrieval.lexicalScore(query, entry.content);
        if (score <= 0 and query.len > 0) continue;
        entry.score = score + 0.5;
        try out.append(allocator, entry.*);
        detachResult(entry);
    }
    sortResults(out.items);
    trimResults(allocator, &out, limit);
    return out.toOwnedSlice(allocator);
}

pub fn appendScoredCandidate(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(domain.AgentMemory), query: []const u8, limit: usize, entry: domain.AgentMemory, score: f64) !void {
    var candidate = entry;
    var candidate_owned = true;
    errdefer if (candidate_owned) agent_memory_runtime.freeAgentMemory(allocator, &candidate);
    if (score <= 0 and query.len > 0) {
        agent_memory_runtime.freeAgentMemory(allocator, &candidate);
        candidate_owned = false;
        return;
    }
    candidate.score = score + 0.5;
    try out.append(allocator, candidate);
    candidate_owned = false;
    sortResults(out.items);
    trimResults(allocator, out, limit);
}

pub fn detachResult(entry: *domain.AgentMemory) void {
    entry.id = "";
    entry.key = "";
    entry.content = "";
    entry.category = "";
    entry.timestamp = "";
    entry.session_id = null;
    entry.actor_id = "";
    entry.writer_actor_id = "";
    entry.scope = "";
    entry.permissions_json = "";
    entry.status = "";
    entry.store = "";
}

pub fn sliceContains(entries: []const domain.AgentMemory, needle: domain.AgentMemory) bool {
    for (entries) |entry| {
        if (!std.mem.eql(u8, entry.key, needle.key)) continue;
        if (!std.mem.eql(u8, entry.actor_id, needle.actor_id)) continue;
        if (!optionalStringEql(entry.session_id, needle.session_id)) continue;
        if (!std.mem.eql(u8, entry.scope, needle.scope)) continue;
        if (!std.mem.eql(u8, entry.store, needle.store)) continue;
        return true;
    }
    return false;
}

pub fn optionalStringEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

pub fn maxUsageTotal(current: ?u64, candidate: ?u64) ?u64 {
    const value = candidate orelse return current;
    const existing = current orelse return value;
    return @max(existing, value);
}

test "store agent memory projection id uses stable sha256 digest" {
    const id = try projectionId(std.testing.allocator, "agent:one", "session-a", "preference");
    defer std.testing.allocator.free(id);
    try std.testing.expect(std.mem.startsWith(u8, id, "agm_"));
    try std.testing.expectEqual(@as(usize, "agm_".len + 64), id.len);
}

test "store agent memory event metadata preserves user payload and order" {
    const allocator = std.testing.allocator;
    const order = EventOrder{
        .timestamp_ms = 42,
        .origin_instance_id = "origin-a",
        .origin_sequence = 7,
    };
    const metadata = try eventMetadataJson(allocator, order, "{\"color\":\"blue\"}");
    defer allocator.free(metadata);
    try std.testing.expect(std.mem.indexOf(u8, metadata, "\"_feed_event\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, metadata, "\"origin_instance_id\":\"origin-a\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, metadata, "\"user\":{\"color\":\"blue\"}") != null);

    try std.testing.expectEqual(@as(i8, 0), try compareInputToStoredMetadata(allocator, order, 0, metadata));
    try std.testing.expectEqual(@as(i8, 1), try compareInputToStoredMetadata(allocator, .{
        .timestamp_ms = 43,
        .origin_instance_id = "origin-a",
        .origin_sequence = 1,
    }, 0, metadata));

    try std.testing.expectError(error.InvalidRawJson, eventMetadataJson(allocator, order, "[\"not-object\"]"));
}

test "store agent memory window limits bound fan-in work" {
    try std.testing.expectEqual(@as(usize, 0), windowPrefetchLimit(0, 10));
    try std.testing.expectEqual(@as(usize, 15), windowPrefetchLimit(5, 10));
    try std.testing.expectEqual(std.math.maxInt(usize), windowPrefetchLimit(2, std.math.maxInt(usize)));
    try std.testing.expectEqual(std.math.maxInt(usize), windowPrefetchLimit(std.math.maxInt(usize), 1));
    try std.testing.expectEqual(@as(usize, 0), backendWindowFetchLimit(0));
    try std.testing.expectEqual(@as(usize, 128), backendWindowFetchLimit(1));
    try std.testing.expectEqual(@as(usize, 1000), backendWindowFetchLimit(std.math.maxInt(usize)));
    try std.testing.expectEqual(@as(usize, 15), backendWindowOffsetAfterFetch(10, 5));
    try std.testing.expectEqual(std.math.maxInt(usize), backendWindowOffsetAfterFetch(std.math.maxInt(usize) - 1, 4));
    try std.testing.expectEqual(@as(i64, 42), backendWindowOffsetI64(42));
    try std.testing.expectEqual(bounded_int.usizeToI64Saturating(std.math.maxInt(usize)), backendWindowOffsetI64(std.math.maxInt(usize)));
}

test "store agent memory metadata rewrite preserves user payload and advances order" {
    const allocator = std.testing.allocator;
    const older = EventOrder{ .timestamp_ms = 100, .origin_instance_id = "origin-a", .origin_sequence = 1 };
    const newer = EventOrder{ .timestamp_ms = 200, .origin_instance_id = "origin-b", .origin_sequence = 3 };

    const existing = try eventMetadataJson(allocator, older, "{\"color\":\"blue\",\"nested\":{\"n\":1}}");
    defer allocator.free(existing);
    const rewritten = try metadataJsonWithEventOrder(allocator, newer, existing);
    defer allocator.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "\"user\":{\"color\":\"blue\",\"nested\":{\"n\":1}}") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "\"origin_instance_id\":\"origin-b\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "\"origin_instance_id\":\"origin-a\"") == null);
    try std.testing.expectEqual(@as(i8, 0), try compareInputToStoredMetadata(allocator, newer, 0, rewritten));
    try std.testing.expectEqual(@as(i8, -1), try compareInputToStoredMetadata(allocator, older, 0, rewritten));
}

test "store agent memory fan-in helpers dedupe only identical ownership route identity" {
    const allocator = std.testing.allocator;
    var out: std.ArrayListUnmanaged(domain.AgentMemory) = .empty;
    defer freeArrayList(allocator, &out);

    var first = [_]domain.AgentMemory{
        try agent_memory_test_helpers.ownedAgentMemory(allocator, "pref.theme", "dark", .{ .actor_id = "agent:a", .scope = "agent:agent:a", .store = "scratch", .timestamp = "100" }),
        try agent_memory_test_helpers.ownedAgentMemory(allocator, "pref.theme", "session", .{ .session_id = "sess-1", .actor_id = "agent:a", .scope = "session:sess-1", .store = "scratch", .timestamp = "99" }),
    };
    defer for (&first) |*entry| agent_memory_runtime.freeAgentMemory(allocator, entry);
    try appendSlice(allocator, &out, first[0..]);

    var next = [_]domain.AgentMemory{
        try agent_memory_test_helpers.ownedAgentMemory(allocator, "pref.theme", "duplicate", .{ .actor_id = "agent:a", .scope = "agent:agent:a", .store = "scratch", .timestamp = "101" }),
        try agent_memory_test_helpers.ownedAgentMemory(allocator, "pref.theme", "archive copy", .{ .actor_id = "agent:a", .scope = "agent:agent:a", .store = "archive", .timestamp = "102" }),
        try agent_memory_test_helpers.ownedAgentMemory(allocator, "pref.theme", "other actor", .{ .actor_id = "agent:b", .scope = "agent:agent:b", .store = "scratch", .timestamp = "103" }),
    };
    defer for (&next) |*entry| agent_memory_runtime.freeAgentMemory(allocator, entry);
    try appendMissingSlice(allocator, &out, next[0..]);

    try std.testing.expectEqual(@as(usize, 4), out.items.len);
    try std.testing.expectEqualStrings("dark", out.items[0].content);
    try std.testing.expectEqualStrings("session", out.items[1].content);
    try std.testing.expectEqualStrings("archive copy", out.items[2].content);
    try std.testing.expectEqualStrings("other actor", out.items[3].content);
}
