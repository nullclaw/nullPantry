const std = @import("std");
const json = @import("json_util.zig");
const feed_contract = @import("feed_contract.zig");
const store_types = @import("store_types.zig");

pub const FeedEventInput = struct {
    event_type: []const u8,
    operation: []const u8 = "put",
    object_type: []const u8,
    object_id: []const u8,
    scope: []const u8 = "workspace",
    permissions_json: []const u8 = "[]",
    actor_id: ?[]const u8 = null,
    dedupe_key: ?[]const u8 = null,
    causality_json: []const u8 = "{}",
    payload_json: []const u8 = "{}",
    status: []const u8 = "pending",
};

pub const FeedListInput = store_types.FeedListInput;

pub const FeedStatusInput = struct {
    scopes_json: []const u8 = "[\"admin\"]",
    actor_id: ?[]const u8 = null,
};

pub const FeedEvent = struct {
    id: i64,
    event_type: []const u8,
    operation: []const u8,
    object_type: []const u8,
    object_id: []const u8,
    scope: []const u8,
    permissions_json: []const u8,
    actor_id: ?[]const u8,
    dedupe_key: ?[]const u8,
    causality_json: []const u8,
    payload_json: []const u8,
    status: []const u8,
    created_at_ms: i64,
    applied_at_ms: ?i64,
    compacted_at_ms: ?i64,

    pub fn writeJson(self: FeedEvent, allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
        return self.writeJsonWithInstance(allocator, out, "nullpantry");
    }

    pub fn writeJsonWithInstance(self: FeedEvent, allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), instance_id: []const u8) !void {
        try out.print(allocator, "{{\"id\":{d},\"event_type\":", .{self.id});
        try json.appendString(out, allocator, self.event_type);
        try out.print(allocator, ",\"sequence\":{d},\"origin_instance_id\":", .{self.id});
        try json.appendString(out, allocator, instance_id);
        try out.print(allocator, ",\"origin_sequence\":{d}", .{self.id});
        try out.appendSlice(allocator, ",\"operation\":");
        try json.appendString(out, allocator, self.operation);
        try out.appendSlice(allocator, ",\"object_type\":");
        try json.appendString(out, allocator, self.object_type);
        try out.appendSlice(allocator, ",\"object_id\":");
        try json.appendString(out, allocator, self.object_id);
        try out.appendSlice(allocator, ",\"scope\":");
        try json.appendString(out, allocator, self.scope);
        try out.appendSlice(allocator, ",\"permissions\":");
        try json.appendRawJsonArray(out, allocator, self.permissions_json);
        try out.appendSlice(allocator, ",\"actor_id\":");
        try json.appendNullableString(out, allocator, self.actor_id);
        try out.appendSlice(allocator, ",\"dedupe_key\":");
        try json.appendNullableString(out, allocator, self.dedupe_key);
        try out.appendSlice(allocator, ",\"causality\":");
        try json.appendRawJsonObject(out, allocator, self.causality_json);
        try out.appendSlice(allocator, ",\"payload\":");
        try json.appendRawJsonObject(out, allocator, self.payload_json);
        try out.appendSlice(allocator, ",\"status\":");
        try json.appendString(out, allocator, self.status);
        try out.print(allocator, ",\"created_at_ms\":{d},\"applied_at_ms\":", .{self.created_at_ms});
        if (self.applied_at_ms) |v| try out.print(allocator, "{d}", .{v}) else try out.appendSlice(allocator, "null");
        try out.appendSlice(allocator, ",\"compacted_at_ms\":");
        if (self.compacted_at_ms) |v| try out.print(allocator, "{d}", .{v}) else try out.appendSlice(allocator, "null");
        try out.append(allocator, '}');
    }

    pub fn clone(self: FeedEvent, allocator: std.mem.Allocator) !FeedEvent {
        const event_type = try allocator.dupe(u8, self.event_type);
        errdefer allocator.free(event_type);
        const operation = try allocator.dupe(u8, self.operation);
        errdefer allocator.free(operation);
        const object_type = try allocator.dupe(u8, self.object_type);
        errdefer allocator.free(object_type);
        const object_id = try allocator.dupe(u8, self.object_id);
        errdefer allocator.free(object_id);
        const scope = try allocator.dupe(u8, self.scope);
        errdefer allocator.free(scope);
        const permissions_json = try allocator.dupe(u8, self.permissions_json);
        errdefer allocator.free(permissions_json);
        const actor_id = if (self.actor_id) |value| try allocator.dupe(u8, value) else null;
        errdefer if (actor_id) |value| allocator.free(value);
        const dedupe_key = if (self.dedupe_key) |value| try allocator.dupe(u8, value) else null;
        errdefer if (dedupe_key) |value| allocator.free(value);
        const causality_json = try allocator.dupe(u8, self.causality_json);
        errdefer allocator.free(causality_json);
        const payload_json = try allocator.dupe(u8, self.payload_json);
        errdefer allocator.free(payload_json);
        const status = try allocator.dupe(u8, self.status);
        errdefer allocator.free(status);

        return .{
            .id = self.id,
            .event_type = event_type,
            .operation = operation,
            .object_type = object_type,
            .object_id = object_id,
            .scope = scope,
            .permissions_json = permissions_json,
            .actor_id = actor_id,
            .dedupe_key = dedupe_key,
            .causality_json = causality_json,
            .payload_json = payload_json,
            .status = status,
            .created_at_ms = self.created_at_ms,
            .applied_at_ms = self.applied_at_ms,
            .compacted_at_ms = self.compacted_at_ms,
        };
    }

    pub fn deinit(self: *FeedEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.event_type);
        allocator.free(self.operation);
        allocator.free(self.object_type);
        allocator.free(self.object_id);
        allocator.free(self.scope);
        allocator.free(self.permissions_json);
        if (self.actor_id) |value| allocator.free(value);
        if (self.dedupe_key) |value| allocator.free(value);
        allocator.free(self.causality_json);
        allocator.free(self.payload_json);
        allocator.free(self.status);
        self.* = undefined;
    }
};

pub fn freeFeedEvents(allocator: std.mem.Allocator, events: []FeedEvent) void {
    for (events) |*event| event.deinit(allocator);
    allocator.free(events);
}

pub fn feedSequenceAfter(sequence: i64) i64 {
    return feed_contract.feedSequenceAfter(sequence);
}

pub fn feedNextLocalOriginSequence(configured_next: i64, max_event_id: i64) i64 {
    return feed_contract.feedNextLocalOriginSequence(configured_next, max_event_id);
}

pub const FeedStatus = struct {
    cursor_floor: i64,
    max_event_id: i64,
    next_local_origin_sequence: i64 = 0,
    visible_events: usize,
    pending_events: usize,
    applying_events: usize,
    applied_events: usize,

    pub fn writeJson(self: FeedStatus, allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
        return self.writeJsonWithInstance(allocator, out, "nullpantry");
    }

    pub fn writeJsonWithInstance(self: FeedStatus, allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), instance_id: []const u8) !void {
        try out.appendSlice(allocator, "{\"instance_id\":");
        try json.appendString(out, allocator, instance_id);
        const oldest_available_sequence = feedSequenceAfter(self.cursor_floor);
        const next_local_origin_sequence = feedNextLocalOriginSequence(self.next_local_origin_sequence, self.max_event_id);
        try out.print(
            allocator,
            ",\"storage_kind\":\"native\",\"supports_compaction\":true,\"feed_object_types\":{s},\"lifecycle_object_types\":{s},\"journal_path\":null,\"checkpoint_path\":null,\"cursor_floor\":{d},\"compacted_through_sequence\":{d},\"oldest_available_sequence\":{d},\"max_event_id\":{d},\"last_sequence\":{d},\"next_local_origin_sequence\":{d},\"visible_events\":{d},\"pending_events\":{d},\"applying_events\":{d},\"applied_events\":{d}}}",
            .{ feed_contract.supported_object_types_json, feed_contract.lifecycle_object_types_json, self.cursor_floor, self.cursor_floor, oldest_available_sequence, self.max_event_id, self.max_event_id, next_local_origin_sequence, self.visible_events, self.pending_events, self.applying_events, self.applied_events },
        );
    }
};

pub const FeedOriginFrontier = struct {
    projection: []const u8,
    origin_instance_id: []const u8,
    origin_sequence: i64,
    updated_at_ms: i64,

    pub fn deinit(self: *FeedOriginFrontier, allocator: std.mem.Allocator) void {
        allocator.free(self.projection);
        allocator.free(self.origin_instance_id);
        self.* = undefined;
    }
};

pub fn freeFeedOriginFrontiers(allocator: std.mem.Allocator, frontiers: []FeedOriginFrontier) void {
    for (frontiers) |*frontier| frontier.deinit(allocator);
    allocator.free(frontiers);
}

pub const FeedCompactResult = struct {
    cursor_floor: i64,
    max_event_id: i64,
    compacted_events: usize,
};

test "store feed event writes stable json" {
    const allocator = std.testing.allocator;
    const event: FeedEvent = .{
        .id = 7,
        .event_type = "memory_atom.put",
        .operation = "put",
        .object_type = "memory_atom",
        .object_id = "mem-a",
        .scope = "team:alpha",
        .permissions_json = "[\"team:alpha\"]",
        .actor_id = "agent:a",
        .dedupe_key = "dedupe-a",
        .causality_json = "{}",
        .payload_json = "{\"text\":\"hello\"}",
        .status = "applied",
        .created_at_ms = 123,
        .applied_at_ms = 124,
        .compacted_at_ms = null,
    };
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    try event.writeJsonWithInstance(allocator, &out, "native-a");

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, out.items, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 7), obj.get("id").?.integer);
    try std.testing.expectEqualStrings("native-a", obj.get("origin_instance_id").?.string);
    try std.testing.expectEqualStrings("memory_atom", obj.get("object_type").?.string);
    try std.testing.expect(obj.get("permissions").? == .array);
    try std.testing.expectEqualStrings("hello", obj.get("payload").?.object.get("text").?.string);
}

test "store feed event enforces raw container root types" {
    const allocator = std.testing.allocator;
    const event: FeedEvent = .{
        .id = 8,
        .event_type = "memory_atom.put",
        .operation = "put",
        .object_type = "memory_atom",
        .object_id = "mem-bad-raw",
        .scope = "team:alpha",
        .permissions_json = "{\"scope\":\"team:alpha\"}",
        .actor_id = "agent:a",
        .dedupe_key = null,
        .causality_json = "[\"wrong-root\"]",
        .payload_json = "[\"wrong-root\"]",
        .status = "pending",
        .created_at_ms = 123,
        .applied_at_ms = null,
        .compacted_at_ms = null,
    };
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    try std.testing.expectError(error.InvalidRawJson, event.writeJsonWithInstance(allocator, &out, "native-a"));
}

test "store feed event clone owns string fields" {
    const allocator = std.testing.allocator;
    const event: FeedEvent = .{
        .id = 1,
        .event_type = "source.put",
        .operation = "put",
        .object_type = "source",
        .object_id = "src-a",
        .scope = "public",
        .permissions_json = "[]",
        .actor_id = "agent:a",
        .dedupe_key = null,
        .causality_json = "{}",
        .payload_json = "{}",
        .status = "pending",
        .created_at_ms = 10,
        .applied_at_ms = null,
        .compacted_at_ms = null,
    };
    var cloned = try event.clone(allocator);
    defer cloned.deinit(allocator);

    try std.testing.expectEqualStrings(event.object_id, cloned.object_id);
    try std.testing.expect(event.object_id.ptr != cloned.object_id.ptr);
    try std.testing.expectEqualStrings(event.actor_id.?, cloned.actor_id.?);
    try std.testing.expect(event.actor_id.?.ptr != cloned.actor_id.?.ptr);
}

test "store feed status writes frontier values" {
    const allocator = std.testing.allocator;
    const status: FeedStatus = .{
        .cursor_floor = 3,
        .max_event_id = 10,
        .visible_events = 4,
        .pending_events = 1,
        .applying_events = 2,
        .applied_events = 3,
    };
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    try status.writeJsonWithInstance(allocator, &out, "native-a");

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, out.items, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("native-a", obj.get("instance_id").?.string);
    try std.testing.expectEqual(@as(i64, 3), obj.get("cursor_floor").?.integer);
    try std.testing.expectEqual(@as(i64, 11), obj.get("next_local_origin_sequence").?.integer);
    try std.testing.expectEqual(@as(i64, 4), obj.get("visible_events").?.integer);
}

test "store feed status writes saturated frontier values" {
    const max = std.math.maxInt(i64);
    const status: FeedStatus = .{
        .cursor_floor = max,
        .max_event_id = max,
        .visible_events = 0,
        .pending_events = 0,
        .applying_events = 0,
        .applied_events = 0,
    };
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try status.writeJsonWithInstance(std.testing.allocator, &out, "native-max");

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.items, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqual(max, obj.get("oldest_available_sequence").?.integer);
    try std.testing.expectEqual(max, obj.get("next_local_origin_sequence").?.integer);
}
