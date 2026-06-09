const std = @import("std");
const domain = @import("domain.zig");
const json = @import("json_util.zig");

pub fn category(allocator: std.mem.Allocator, result_type: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "primitive:{s}", .{result_type});
}

pub fn key(allocator: std.mem.Allocator, result_type: []const u8, id: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "primitive:{s}:{s}", .{ result_type, id });
}

pub fn content(allocator: std.mem.Allocator, title_value: []const u8, text: []const u8) ![]u8 {
    if (title_value.len == 0) return allocator.dupe(u8, text);
    if (text.len == 0 or std.mem.eql(u8, title_value, text)) return allocator.dupe(u8, title_value);
    return std.fmt.allocPrint(allocator, "{s}\n{s}", .{ title_value, text });
}

pub fn typeFromAgentCategory(agent_category: []const u8) ?[]const u8 {
    const prefix = "primitive:";
    if (!std.mem.startsWith(u8, agent_category, prefix)) return null;
    const value = agent_category[prefix.len..];
    if (std.mem.eql(u8, value, "source") or
        std.mem.eql(u8, value, "artifact") or
        std.mem.eql(u8, value, "memory_atom") or
        std.mem.eql(u8, value, "entity") or
        std.mem.eql(u8, value, "relation") or
        std.mem.eql(u8, value, "context_pack"))
    {
        return value;
    }
    return null;
}

pub fn isLucidProjectableObjectType(object_type: []const u8) bool {
    return std.mem.eql(u8, object_type, "source") or
        std.mem.eql(u8, object_type, "artifact") or
        std.mem.eql(u8, object_type, "memory_atom") or
        std.mem.eql(u8, object_type, "entity") or
        std.mem.eql(u8, object_type, "relation") or
        std.mem.eql(u8, object_type, "context_pack") or
        std.mem.eql(u8, object_type, "agent_memory");
}

pub fn objectId(allocator: std.mem.Allocator, runtime_key: []const u8, fallback: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, runtime_key, "primitive:")) {
        var parts = std.mem.splitScalar(u8, runtime_key, ':');
        _ = parts.next();
        _ = parts.next();
        if (parts.rest().len > 0) return allocator.dupe(u8, parts.rest());
    }
    return allocator.dupe(u8, fallback);
}

pub fn title(allocator: std.mem.Allocator, result_type: []const u8, runtime_key: []const u8) ![]u8 {
    const id = try objectId(allocator, runtime_key, runtime_key);
    defer allocator.free(id);
    return std.fmt.allocPrint(allocator, "{s}:{s}", .{ result_type, id });
}

pub fn citations(allocator: std.mem.Allocator, result_type: ?[]const u8, id: []const u8) ![]const u8 {
    if (result_type) |kind| {
        if (std.mem.eql(u8, kind, "source")) return singleJsonString(allocator, id);
    }
    return allocator.dupe(u8, "[]");
}

pub fn agentMemoryMetadataJson(allocator: std.mem.Allocator, store_name: []const u8, entry: domain.AgentMemory) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"native\":\"agent_memory_runtime\",\"store\":");
    try json.appendString(&out, allocator, store_name);
    try out.appendSlice(allocator, ",\"key\":");
    try json.appendString(&out, allocator, entry.key);
    try out.appendSlice(allocator, ",\"category\":");
    try json.appendString(&out, allocator, entry.category);
    try out.appendSlice(allocator, ",\"session_id\":");
    try json.appendNullableString(&out, allocator, entry.session_id);
    try out.appendSlice(allocator, ",\"scope\":");
    try json.appendString(&out, allocator, entry.scope);
    try out.appendSlice(allocator, ",\"permissions\":");
    try json.appendRawJsonArray(&out, allocator, entry.permissions_json);
    try out.appendSlice(allocator, ",\"owner_id\":");
    try json.appendString(&out, allocator, entry.actor_id);
    try out.appendSlice(allocator, ",\"writer_actor_id\":");
    try json.appendString(&out, allocator, if (entry.writer_actor_id.len > 0) entry.writer_actor_id else entry.actor_id);
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

pub fn isAgentMemorySourceMetadata(metadata_json: []const u8) bool {
    return std.mem.indexOf(u8, metadata_json, "\"native\":\"agent_memory\"") != null or
        std.mem.indexOf(u8, metadata_json, "\"native\":\"agent_memory_runtime\"") != null;
}

fn singleJsonString(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '[');
    try json.appendString(&out, allocator, value);
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

test "primitive runtime helpers format stable mirrored metadata" {
    const allocator = std.testing.allocator;

    const runtime_key = try key(allocator, "source", "src:1");
    defer allocator.free(runtime_key);
    try std.testing.expectEqualStrings("primitive:source:src:1", runtime_key);

    const category_name = try category(allocator, "source");
    defer allocator.free(category_name);
    try std.testing.expectEqualStrings("primitive:source", category_name);
    try std.testing.expectEqualStrings("source", typeFromAgentCategory(category_name).?);

    const joined_content = try content(allocator, "Title", "Body");
    defer allocator.free(joined_content);
    try std.testing.expectEqualStrings("Title\nBody", joined_content);

    const object_id = try objectId(allocator, runtime_key, "fallback");
    defer allocator.free(object_id);
    try std.testing.expectEqualStrings("src:1", object_id);

    const citation_json = try citations(allocator, "source", "src:1");
    defer allocator.free(citation_json);
    try std.testing.expectEqualStrings("[\"src:1\"]", citation_json);

    const metadata = try agentMemoryMetadataJson(allocator, "scratch", .{
        .id = "row",
        .key = "pref.lang",
        .content = "zig",
        .category = "core",
        .timestamp = "2026-01-01T00:00:00Z",
        .session_id = null,
        .actor_id = "agent:a",
        .writer_actor_id = "agent:b",
        .scope = "team:alpha",
        .permissions_json = "[\"team:alpha\"]",
    });
    defer allocator.free(metadata);
    try std.testing.expect(isAgentMemorySourceMetadata(metadata));
    try std.testing.expect(std.mem.indexOf(u8, metadata, "\"store\":\"scratch\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, metadata, "\"writer_actor_id\":\"agent:b\"") != null);
}

test "primitive runtime metadata enforces permissions array root" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidRawJson, agentMemoryMetadataJson(allocator, "scratch", .{
        .id = "row",
        .key = "pref.lang",
        .content = "zig",
        .category = "core",
        .timestamp = "2026-01-01T00:00:00Z",
        .session_id = null,
        .actor_id = "agent:a",
        .scope = "team:alpha",
        .permissions_json = "{\"scope\":\"team:alpha\"}",
    }));
}
