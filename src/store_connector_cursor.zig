const std = @import("std");
const json = @import("json_util.zig");

pub const Input = struct {
    connector: []const u8,
    scope: []const u8 = "workspace",
    cursor: []const u8 = "",
    config_json: []const u8 = "{}",
    permissions_json: []const u8 = "[]",
    actor_id: ?[]const u8 = null,
};

pub const ListInput = struct {
    connector: ?[]const u8 = null,
    scopes_json: []const u8 = "[\"admin\"]",
    limit: usize = 100,
};

pub const Cursor = struct {
    connector: []const u8,
    scope: []const u8,
    cursor: []const u8,
    config_json: []const u8,
    permissions_json: []const u8,
    updated_at_ms: i64,

    pub fn writeJson(self: Cursor, allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
        try out.appendSlice(allocator, "{\"connector\":");
        try json.appendString(out, allocator, self.connector);
        try out.appendSlice(allocator, ",\"scope\":");
        try json.appendString(out, allocator, self.scope);
        try out.appendSlice(allocator, ",\"cursor\":");
        try json.appendString(out, allocator, self.cursor);
        try out.appendSlice(allocator, ",\"config\":");
        try json.appendRawJsonObject(out, allocator, self.config_json);
        try out.appendSlice(allocator, ",\"permissions\":");
        try json.appendRawJsonArray(out, allocator, self.permissions_json);
        try out.print(allocator, ",\"updated_at_ms\":{d}}}", .{self.updated_at_ms});
    }
};

pub fn freeCursor(allocator: std.mem.Allocator, cursor: *Cursor) void {
    if (cursor.connector.len > 0) allocator.free(cursor.connector);
    if (cursor.scope.len > 0) allocator.free(cursor.scope);
    if (cursor.cursor.len > 0) allocator.free(cursor.cursor);
    if (cursor.config_json.len > 0) allocator.free(cursor.config_json);
    if (cursor.permissions_json.len > 0) allocator.free(cursor.permissions_json);
    cursor.* = .{
        .connector = "",
        .scope = "",
        .cursor = "",
        .config_json = "",
        .permissions_json = "",
        .updated_at_ms = 0,
    };
}

pub fn freeCursors(allocator: std.mem.Allocator, cursors: []Cursor) void {
    for (cursors) |*cursor| freeCursor(allocator, cursor);
    allocator.free(cursors);
}

test "store connector cursor contract writes stable json" {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(std.testing.allocator);

    try (Cursor{
        .connector = "ticket",
        .scope = "project:nullpantry",
        .cursor = "ticket-42",
        .config_json = "{\"project\":\"NP\"}",
        .permissions_json = "[\"team:platform\"]",
        .updated_at_ms = 42,
    }).writeJson(std.testing.allocator, &out);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.items, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("ticket", parsed.value.object.get("connector").?.string);
    try std.testing.expectEqualStrings("NP", parsed.value.object.get("config").?.object.get("project").?.string);
    try std.testing.expectEqual(@as(i64, 42), parsed.value.object.get("updated_at_ms").?.integer);
}

test "store connector cursor contract enforces raw container root types" {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(std.testing.allocator);

    try std.testing.expectError(error.InvalidRawJson, (Cursor{
        .connector = "ticket",
        .scope = "project:nullpantry",
        .cursor = "ticket-42",
        .config_json = "[\"wrong-root\"]",
        .permissions_json = "{\"scope\":\"project:nullpantry\"}",
        .updated_at_ms = 42,
    }).writeJson(std.testing.allocator, &out));
}

test "store connector cursor list input keeps admin default" {
    const input = ListInput{};
    try std.testing.expectEqualStrings("[\"admin\"]", input.scopes_json);
    try std.testing.expectEqual(@as(usize, 100), input.limit);
}
