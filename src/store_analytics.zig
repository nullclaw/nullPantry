const std = @import("std");
const json = @import("json_util.zig");
const store_types = @import("store_types.zig");

pub const AuditEvent = struct {
    id: i64,
    event_type: []const u8,
    actor: ?[]const u8,
    object_type: []const u8,
    object_id: []const u8,
    payload_json: []const u8,
    created_at_ms: i64,
};

pub const ExportInput = store_types.AnalyticsExportInput;

pub const ExportResult = struct {
    audit_events: usize = 0,
    feed_events: usize = 0,
    attempted: usize = 0,
    exported: usize = 0,
    skipped_existing: usize = 0,
    audit_since_id: i64 = 0,
    feed_since_id: i64 = 0,
    next_audit_id: i64 = 0,
    next_feed_id: i64 = 0,
    cursor_advanced: bool = false,
};

pub const Cursor = struct {
    audit_since_id: i64 = 0,
    feed_since_id: i64 = 0,
};

pub fn parseCursor(allocator: std.mem.Allocator, raw: []const u8) !Cursor {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return .{};
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch {
        const single = std.fmt.parseInt(i64, trimmed, 10) catch 0;
        return .{ .audit_since_id = single, .feed_since_id = single };
    };
    defer parsed.deinit();
    if (parsed.value != .object) return .{};
    return .{
        .audit_since_id = json.intField(parsed.value.object, "audit") orelse json.intField(parsed.value.object, "audit_since_id") orelse 0,
        .feed_since_id = json.intField(parsed.value.object, "memory_feed") orelse json.intField(parsed.value.object, "feed_since_id") orelse 0,
    };
}

pub fn cursorJson(allocator: std.mem.Allocator, cursor: Cursor) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"audit\":{d},\"memory_feed\":{d}}}",
        .{ cursor.audit_since_id, cursor.feed_since_id },
    );
}

test "store analytics cursor keeps audit and feed offsets independent" {
    const cursor_json = try cursorJson(std.testing.allocator, .{ .audit_since_id = 42, .feed_since_id = 7 });
    defer std.testing.allocator.free(cursor_json);
    const cursor = try parseCursor(std.testing.allocator, cursor_json);
    try std.testing.expectEqual(@as(i64, 42), cursor.audit_since_id);
    try std.testing.expectEqual(@as(i64, 7), cursor.feed_since_id);
}

test "store analytics scalar json cursor resets both streams" {
    const cursor = try parseCursor(std.testing.allocator, "42");
    try std.testing.expectEqual(@as(i64, 0), cursor.audit_since_id);
    try std.testing.expectEqual(@as(i64, 0), cursor.feed_since_id);
}
