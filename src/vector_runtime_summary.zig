const std = @import("std");

const json = @import("json_util.zig");

pub const Summary = struct {
    active_sink: []const u8,
    local_engine: []const u8,
    search_engine: []const u8,
    external_sinks_json: []const u8,
};

pub fn appendFields(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), summary: Summary) !void {
    try out.appendSlice(allocator, ",\"active_sink\":");
    try json.appendString(out, allocator, summary.active_sink);
    try out.appendSlice(allocator, ",\"local_engine\":");
    try json.appendString(out, allocator, summary.local_engine);
    try out.appendSlice(allocator, ",\"search_engine\":");
    try json.appendString(out, allocator, summary.search_engine);
    try out.appendSlice(allocator, ",\"external_sinks\":");
    try appendExternalSinks(allocator, out, summary.external_sinks_json);
}

pub fn appendExternalSinks(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), external_sinks_json: []const u8) !void {
    try json.appendRawJsonArray(out, allocator, external_sinks_json);
}

test "vector runtime summary appends escaped labels and strict external sinks" {
    const allocator = std.testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"ok\":true");
    try appendFields(allocator, &out, .{
        .active_sink = "sink\"quoted",
        .local_engine = "local\\engine",
        .search_engine = "search\nengine",
        .external_sinks_json = "[{\"name\":\"ann\"}]",
    });
    try out.append(allocator, '}');

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, out.items, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("sink\"quoted", root.get("active_sink").?.string);
    try std.testing.expectEqualStrings("local\\engine", root.get("local_engine").?.string);
    try std.testing.expectEqualStrings("search\nengine", root.get("search_engine").?.string);
    try std.testing.expectEqual(@as(usize, 1), root.get("external_sinks").?.array.items.len);

    var bad_out: std.ArrayListUnmanaged(u8) = .empty;
    defer bad_out.deinit(allocator);
    try std.testing.expectError(error.InvalidRawJson, appendFields(allocator, &bad_out, .{
        .active_sink = "none",
        .local_engine = "sqlite",
        .search_engine = "local",
        .external_sinks_json = "{\"name\":\"ann\"}",
    }));
}
