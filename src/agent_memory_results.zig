const std = @import("std");
const json = @import("json_util.zig");
const feed_contract = @import("feed_contract.zig");

pub const Message = struct {
    role: []const u8,
    content: []const u8,
    created_at_ms: i64,
};

pub fn sortMessages(entries: []Message) void {
    std.mem.sort(Message, entries, {}, struct {
        fn lessThan(_: void, a: Message, b: Message) bool {
            if (a.created_at_ms != b.created_at_ms) return a.created_at_ms < b.created_at_ms;
            const role_order = std.mem.order(u8, a.role, b.role);
            if (role_order != .eq) return role_order == .lt;
            return std.mem.order(u8, a.content, b.content) == .lt;
        }
    }.lessThan);
}

pub const SessionInfo = struct {
    session_id: []const u8,
    message_count: u64,
    first_message_at: i64,
    last_message_at: i64,
};

pub const HistoryList = struct {
    total: u64,
    sessions: []SessionInfo,
};

pub const HistoryShow = struct {
    total: u64,
    messages: []Message,
};

pub const FeedEvent = struct {
    id: i64,
    sequence: i64,
    event_type: []const u8,
    origin_instance_id: []const u8,
    origin_sequence: i64,
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

    pub fn deinit(self: *FeedEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.event_type);
        allocator.free(self.origin_instance_id);
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
    }

    pub fn clone(self: FeedEvent, allocator: std.mem.Allocator) !FeedEvent {
        var out = FeedEvent{
            .id = self.id,
            .sequence = self.sequence,
            .event_type = try allocator.dupe(u8, self.event_type),
            .origin_instance_id = try allocator.dupe(u8, self.origin_instance_id),
            .origin_sequence = self.origin_sequence,
            .operation = try allocator.dupe(u8, self.operation),
            .object_type = try allocator.dupe(u8, self.object_type),
            .object_id = try allocator.dupe(u8, self.object_id),
            .scope = try allocator.dupe(u8, self.scope),
            .permissions_json = try allocator.dupe(u8, self.permissions_json),
            .actor_id = if (self.actor_id) |value| try allocator.dupe(u8, value) else null,
            .dedupe_key = if (self.dedupe_key) |value| try allocator.dupe(u8, value) else null,
            .causality_json = try allocator.dupe(u8, self.causality_json),
            .payload_json = try allocator.dupe(u8, self.payload_json),
            .status = try allocator.dupe(u8, self.status),
            .created_at_ms = self.created_at_ms,
            .applied_at_ms = self.applied_at_ms,
            .compacted_at_ms = self.compacted_at_ms,
        };
        errdefer out.deinit(allocator);
        return out;
    }

    pub fn writeJson(self: FeedEvent, allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
        const wire_operation = feed_contract.wireOperation(self.object_type, self.operation, true);
        try out.print(allocator, "{{\"id\":{d},\"event_type\":", .{self.id});
        try json.appendString(out, allocator, self.event_type);
        try out.print(allocator, ",\"sequence\":{d},\"origin_instance_id\":", .{self.sequence});
        try json.appendString(out, allocator, self.origin_instance_id);
        try out.print(allocator, ",\"origin_sequence\":{d}", .{self.origin_sequence});
        try out.print(allocator, ",\"schema_version\":1,\"timestamp_ms\":{d}", .{self.created_at_ms});
        try out.appendSlice(allocator, ",\"operation\":");
        try json.appendString(out, allocator, wire_operation);
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
        try feed_contract.appendAgentMemoryCompatFields(allocator, out, self.object_type, self.object_id, self.payload_json, wire_operation);
        try out.appendSlice(allocator, ",\"status\":");
        try json.appendString(out, allocator, self.status);
        try out.print(allocator, ",\"created_at_ms\":{d},\"applied_at_ms\":", .{self.created_at_ms});
        if (self.applied_at_ms) |v| try out.print(allocator, "{d}", .{v}) else try out.appendSlice(allocator, "null");
        try out.appendSlice(allocator, ",\"compacted_at_ms\":");
        if (self.compacted_at_ms) |v| try out.print(allocator, "{d}", .{v}) else try out.appendSlice(allocator, "null");
        try out.append(allocator, '}');
    }
};

pub const FeedStatus = struct {
    instance_id: []const u8,
    storage_kind: []const u8,
    supports_compaction: bool,
    cursor_floor: i64,
    compacted_through_sequence: i64,
    oldest_available_sequence: i64,
    max_event_id: i64,
    last_sequence: i64,
    next_local_origin_sequence: i64,
    visible_events: usize,
    pending_events: usize,
    applying_events: usize,
    applied_events: usize,

    pub fn deinit(self: *FeedStatus, allocator: std.mem.Allocator) void {
        allocator.free(self.instance_id);
        allocator.free(self.storage_kind);
    }
};

pub const FeedCompactResult = struct {
    cursor_floor: i64,
    compacted_through_sequence: i64,
    max_event_id: i64,
    compacted_events: usize,
};

test "agent memory results sort messages deterministically" {
    var messages = [_]Message{
        .{ .role = "assistant", .content = "b", .created_at_ms = 20 },
        .{ .role = "user", .content = "z", .created_at_ms = 10 },
        .{ .role = "assistant", .content = "a", .created_at_ms = 20 },
    };

    sortMessages(messages[0..]);

    try std.testing.expectEqualStrings("user", messages[0].role);
    try std.testing.expectEqual(@as(i64, 10), messages[0].created_at_ms);
    try std.testing.expectEqualStrings("assistant", messages[1].role);
    try std.testing.expectEqualStrings("a", messages[1].content);
    try std.testing.expectEqualStrings("b", messages[2].content);
}

test "agent memory results write runtime feed event json" {
    const allocator = std.testing.allocator;
    const event: FeedEvent = .{
        .id = 1,
        .sequence = 2,
        .event_type = "agent_memory.delete",
        .origin_instance_id = "runtime-a",
        .origin_sequence = 3,
        .operation = "delete",
        .object_type = "agent_memory",
        .object_id = "owner:global:key",
        .scope = "actor:owner",
        .permissions_json = "[]",
        .actor_id = "owner",
        .dedupe_key = null,
        .causality_json = "{}",
        .payload_json = "{\"key\":\"profile:name\"}",
        .status = "applied",
        .created_at_ms = 123,
        .applied_at_ms = 124,
        .compacted_at_ms = null,
    };
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    try event.writeJson(allocator, &out);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, out.items, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("delete_scoped", obj.get("operation").?.string);
    try std.testing.expectEqualStrings("agent_memory", obj.get("object_type").?.string);
    try std.testing.expectEqual(@as(i64, 123), obj.get("timestamp_ms").?.integer);
    try std.testing.expectEqualStrings("profile:name", obj.get("key").?.string);
    try std.testing.expect(obj.get("permissions").? == .array);
}

test "agent memory results feed event enforces raw container root types" {
    const allocator = std.testing.allocator;
    const event: FeedEvent = .{
        .id = 4,
        .sequence = 5,
        .event_type = "agent_memory.put",
        .origin_instance_id = "runtime-a",
        .origin_sequence = 6,
        .operation = "put",
        .object_type = "agent_memory",
        .object_id = "owner:global:key",
        .scope = "actor:owner",
        .permissions_json = "{\"scope\":\"actor:owner\"}",
        .actor_id = "owner",
        .dedupe_key = null,
        .causality_json = "[\"wrong-root\"]",
        .payload_json = "[\"wrong-root\"]",
        .status = "applied",
        .created_at_ms = 123,
        .applied_at_ms = 124,
        .compacted_at_ms = null,
    };
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    try std.testing.expectError(error.InvalidRawJson, event.writeJson(allocator, &out));
}
