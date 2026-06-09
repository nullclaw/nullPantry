const std = @import("std");
const ids = @import("ids.zig");
const requests = @import("agent_memory_requests.zig");

pub const EventOrder = requests.EventOrder;
pub const Input = requests.Input;

pub fn timestampMs(input: Input) i64 {
    return if (input.event_order) |order| order.timestamp_ms else ids.nowMs();
}

pub fn compare(input: EventOrder, existing_timestamp_ms: i64, existing_origin_instance_id: []const u8, existing_origin_sequence: i64) i8 {
    if (input.timestamp_ms < existing_timestamp_ms) return -1;
    if (input.timestamp_ms > existing_timestamp_ms) return 1;
    return switch (std.mem.order(u8, input.origin_instance_id, existing_origin_instance_id)) {
        .lt => -1,
        .gt => 1,
        .eq => if (input.origin_sequence < existing_origin_sequence) -1 else if (input.origin_sequence > existing_origin_sequence) 1 else 0,
    };
}

pub fn clone(allocator: std.mem.Allocator, order: EventOrder) !EventOrder {
    return .{
        .timestamp_ms = order.timestamp_ms,
        .origin_instance_id = try allocator.dupe(u8, order.origin_instance_id),
        .origin_sequence = order.origin_sequence,
    };
}

pub fn free(allocator: std.mem.Allocator, order: *EventOrder) void {
    allocator.free(order.origin_instance_id);
}

test "agent memory event order compares timestamp origin and sequence" {
    const order: EventOrder = .{
        .timestamp_ms = 10,
        .origin_instance_id = "writer-b",
        .origin_sequence = 5,
    };

    try std.testing.expectEqual(@as(i8, -1), compare(order, 11, "writer-b", 5));
    try std.testing.expectEqual(@as(i8, 1), compare(order, 9, "writer-b", 5));
    try std.testing.expectEqual(@as(i8, -1), compare(order, 10, "writer-c", 5));
    try std.testing.expectEqual(@as(i8, 1), compare(order, 10, "writer-a", 5));
    try std.testing.expectEqual(@as(i8, -1), compare(order, 10, "writer-b", 6));
    try std.testing.expectEqual(@as(i8, 1), compare(order, 10, "writer-b", 4));
    try std.testing.expectEqual(@as(i8, 0), compare(order, 10, "writer-b", 5));
}

test "agent memory event order comparison is monotonic" {
    const ordered = [_]EventOrder{
        .{ .timestamp_ms = 10, .origin_instance_id = "writer-a", .origin_sequence = 1 },
        .{ .timestamp_ms = 10, .origin_instance_id = "writer-a", .origin_sequence = 2 },
        .{ .timestamp_ms = 10, .origin_instance_id = "writer-b", .origin_sequence = 1 },
        .{ .timestamp_ms = 11, .origin_instance_id = "writer-a", .origin_sequence = 1 },
    };

    for (ordered, 0..) |candidate, i| {
        for (ordered, 0..) |existing, j| {
            const result = compare(candidate, existing.timestamp_ms, existing.origin_instance_id, existing.origin_sequence);
            if (i < j) try std.testing.expect(result < 0);
            if (i == j) try std.testing.expectEqual(@as(i8, 0), result);
            if (i > j) try std.testing.expect(result > 0);
        }
    }
}

test "agent memory event order tombstone boundary is monotonic" {
    const tombstone: EventOrder = .{ .timestamp_ms = 20, .origin_instance_id = "writer-b", .origin_sequence = 3 };
    const cases = [_]struct {
        order: EventOrder,
        blocks: bool,
    }{
        .{ .order = .{ .timestamp_ms = 19, .origin_instance_id = "writer-z", .origin_sequence = 99 }, .blocks = true },
        .{ .order = .{ .timestamp_ms = 20, .origin_instance_id = "writer-a", .origin_sequence = 99 }, .blocks = true },
        .{ .order = .{ .timestamp_ms = 20, .origin_instance_id = "writer-b", .origin_sequence = 3 }, .blocks = true },
        .{ .order = .{ .timestamp_ms = 20, .origin_instance_id = "writer-b", .origin_sequence = 4 }, .blocks = false },
        .{ .order = .{ .timestamp_ms = 20, .origin_instance_id = "writer-c", .origin_sequence = 1 }, .blocks = false },
        .{ .order = .{ .timestamp_ms = 21, .origin_instance_id = "writer-a", .origin_sequence = 1 }, .blocks = false },
    };

    for (cases) |case| {
        const blocked = compare(case.order, tombstone.timestamp_ms, tombstone.origin_instance_id, tombstone.origin_sequence) <= 0;
        try std.testing.expectEqual(case.blocks, blocked);
    }
}

test "agent memory event order timestamp prefers explicit order" {
    const input: Input = .{
        .key = "profile:name",
        .content = "Ada",
        .event_order = .{
            .timestamp_ms = 42,
            .origin_instance_id = "writer-a",
            .origin_sequence = 7,
        },
    };

    try std.testing.expectEqual(@as(i64, 42), timestampMs(input));
}

test "agent memory event order clone owns origin instance id" {
    const allocator = std.testing.allocator;
    const order: EventOrder = .{
        .timestamp_ms = 10,
        .origin_instance_id = "writer-a",
        .origin_sequence = 1,
    };
    var cloned = try clone(allocator, order);
    defer free(allocator, &cloned);

    try std.testing.expectEqual(order.timestamp_ms, cloned.timestamp_ms);
    try std.testing.expectEqualStrings(order.origin_instance_id, cloned.origin_instance_id);
    try std.testing.expectEqual(order.origin_sequence, cloned.origin_sequence);
    try std.testing.expect(order.origin_instance_id.ptr != cloned.origin_instance_id.ptr);
}
