const std = @import("std");

const json = @import("json_util.zig");

pub const VectorEmbedPayloadInput = struct {
    chunk_ordinal: i64,
    text: []const u8,
    scope: []const u8,
    permissions_json: []const u8,
    heading_path_json: []const u8 = "[]",
    start_byte: i64 = 0,
    end_byte: i64 = 0,
    content_hash: []const u8 = "",
    chunk_strategy: []const u8 = "plain",
    estimated_tokens: i64 = 0,
    transcript_timestamp: ?[]const u8 = null,
    transcript_speaker: ?[]const u8 = null,
    model: ?[]const u8,
    dimensions: usize,
};

pub fn vectorEmbedPayloadJson(
    allocator: std.mem.Allocator,
    chunk_ordinal: i64,
    text: []const u8,
    scope: []const u8,
    permissions_json: []const u8,
    heading_path_json: []const u8,
    model: ?[]const u8,
    dimensions: usize,
) ![]u8 {
    return vectorEmbedPayloadJsonEx(allocator, .{
        .chunk_ordinal = chunk_ordinal,
        .text = text,
        .scope = scope,
        .permissions_json = permissions_json,
        .heading_path_json = heading_path_json,
        .model = model,
        .dimensions = dimensions,
    });
}

pub fn vectorEmbedPayloadJsonEx(allocator: std.mem.Allocator, input: VectorEmbedPayloadInput) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"chunk_ordinal\":");
    try out.print(allocator, "{d}", .{input.chunk_ordinal});
    try out.appendSlice(allocator, ",\"text\":");
    try json.appendString(&out, allocator, input.text);
    try out.appendSlice(allocator, ",\"scope\":");
    try json.appendString(&out, allocator, input.scope);
    try out.appendSlice(allocator, ",\"permissions\":");
    try json.appendRawJsonArray(&out, allocator, input.permissions_json);
    try out.appendSlice(allocator, ",\"heading_path\":");
    try json.appendRawJsonArray(&out, allocator, input.heading_path_json);
    try out.print(allocator, ",\"start_byte\":{d},\"end_byte\":{d},\"content_hash\":", .{ input.start_byte, input.end_byte });
    try json.appendString(&out, allocator, input.content_hash);
    try out.appendSlice(allocator, ",\"chunk_strategy\":");
    try json.appendString(&out, allocator, input.chunk_strategy);
    try out.print(allocator, ",\"estimated_tokens\":{d},\"transcript_timestamp\":", .{input.estimated_tokens});
    try json.appendNullableString(&out, allocator, input.transcript_timestamp);
    try out.appendSlice(allocator, ",\"transcript_speaker\":");
    try json.appendNullableString(&out, allocator, input.transcript_speaker);
    try out.appendSlice(allocator, ",\"model\":");
    try json.appendNullableString(&out, allocator, input.model);
    try out.appendSlice(allocator, ",\"dimensions\":");
    try out.print(allocator, "{d}", .{input.dimensions});
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

test "store vector payload serializes complete embedding metadata" {
    const allocator = std.testing.allocator;
    const payload = try vectorEmbedPayloadJsonEx(allocator, .{
        .chunk_ordinal = 7,
        .text = "body\nwith \"quotes\"",
        .scope = "workspace",
        .permissions_json = "[\"read\",\"write\"]",
        .heading_path_json = "[\"Intro\",\"Details\"]",
        .start_byte = 12,
        .end_byte = 34,
        .content_hash = "sha256:abc",
        .chunk_strategy = "markdown",
        .estimated_tokens = 42,
        .transcript_timestamp = "00:01:02",
        .transcript_speaker = "speaker-a",
        .model = "text-embedding-3-small",
        .dimensions = 1536,
    });
    defer allocator.free(payload);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 7), root.get("chunk_ordinal").?.integer);
    try std.testing.expectEqualStrings("body\nwith \"quotes\"", root.get("text").?.string);
    try std.testing.expectEqualStrings("workspace", root.get("scope").?.string);
    try std.testing.expectEqual(@as(usize, 2), root.get("permissions").?.array.items.len);
    try std.testing.expectEqualStrings("read", root.get("permissions").?.array.items[0].string);
    try std.testing.expectEqual(@as(usize, 2), root.get("heading_path").?.array.items.len);
    try std.testing.expectEqualStrings("Details", root.get("heading_path").?.array.items[1].string);
    try std.testing.expectEqual(@as(i64, 12), root.get("start_byte").?.integer);
    try std.testing.expectEqual(@as(i64, 34), root.get("end_byte").?.integer);
    try std.testing.expectEqualStrings("sha256:abc", root.get("content_hash").?.string);
    try std.testing.expectEqualStrings("markdown", root.get("chunk_strategy").?.string);
    try std.testing.expectEqual(@as(i64, 42), root.get("estimated_tokens").?.integer);
    try std.testing.expectEqualStrings("00:01:02", root.get("transcript_timestamp").?.string);
    try std.testing.expectEqualStrings("speaker-a", root.get("transcript_speaker").?.string);
    try std.testing.expectEqualStrings("text-embedding-3-small", root.get("model").?.string);
    try std.testing.expectEqual(@as(i64, 1536), root.get("dimensions").?.integer);
}

test "store vector payload rejects invalid raw array fields" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidRawJson, vectorEmbedPayloadJson(
        allocator,
        1,
        "text",
        "scope",
        "not json",
        "{\"not\":\"an array but valid raw json\"}",
        null,
        0,
    ));
}
