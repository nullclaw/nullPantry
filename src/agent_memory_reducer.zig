const std = @import("std");
const domain = @import("domain.zig");
const json = @import("json_util.zig");

pub fn reduceContent(
    allocator: std.mem.Allocator,
    operation: domain.AgentMemoryOperation,
    existing_content: ?[]const u8,
    update_content: []const u8,
) ![]u8 {
    return switch (operation) {
        .put => allocator.dupe(u8, update_content),
        .merge_string_set => reduceStringSet(allocator, existing_content, update_content),
        .merge_object => reduceObject(allocator, existing_content, update_content),
    };
}

pub fn stringSetPatchFromObject(allocator: std.mem.Allocator, obj: std.json.ObjectMap) ![]u8 {
    var values: std.ArrayListUnmanaged([]const u8) = .empty;
    defer freeStringList(allocator, &values);

    if (obj.get("values")) |value| {
        try appendStringValue(allocator, &values, value);
    } else if (obj.get("value")) |value| {
        try appendStringValue(allocator, &values, value);
    } else if (json.stringField(obj, "content")) |content| {
        try appendUniqueString(allocator, &values, content);
    } else if (json.stringField(obj, "text")) |text| {
        try appendUniqueString(allocator, &values, text);
    } else {
        return error.InvalidPayload;
    }

    return stringSetJson(allocator, values.items);
}

pub fn objectPatchFromObject(allocator: std.mem.Allocator, obj: std.json.ObjectMap) ![]u8 {
    const patch_value = obj.get("object") orelse obj.get("value") orelse return error.InvalidPayload;
    if (patch_value != .object) return error.InvalidPayload;
    return json.jsonFromValue(allocator, patch_value);
}

fn reduceStringSet(allocator: std.mem.Allocator, existing_content: ?[]const u8, update_content: []const u8) ![]u8 {
    var values: std.ArrayListUnmanaged([]const u8) = .empty;
    defer freeStringList(allocator, &values);

    if (existing_content) |content| try appendStringSetValues(allocator, &values, content);
    try appendStringSetValues(allocator, &values, update_content);

    return stringSetJson(allocator, values.items);
}

fn reduceObject(allocator: std.mem.Allocator, existing_content: ?[]const u8, update_content: []const u8) ![]u8 {
    var existing_parsed: ?std.json.Parsed(std.json.Value) = null;
    defer if (existing_parsed) |*parsed| parsed.deinit();
    var existing_obj: ?std.json.ObjectMap = null;
    if (existing_content) |content| {
        existing_parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
        if (existing_parsed.?.value != .object) return error.InvalidPayload;
        existing_obj = existing_parsed.?.value.object;
    }

    const patch_parsed = try std.json.parseFromSlice(std.json.Value, allocator, update_content, .{});
    defer patch_parsed.deinit();
    if (patch_parsed.value != .object) return error.InvalidPayload;
    const patch_obj = patch_parsed.value.object;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendMergedObjectCanonical(&out, allocator, existing_obj, patch_obj);
    return out.toOwnedSlice(allocator);
}

fn appendCanonicalJsonValue(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: std.json.Value) anyerror!void {
    switch (value) {
        .null => try out.appendSlice(allocator, "null"),
        .bool => |inner| try out.appendSlice(allocator, if (inner) "true" else "false"),
        .integer => |inner| try out.print(allocator, "{d}", .{inner}),
        .float => |inner| try out.print(allocator, "{d}", .{inner}),
        .number_string => |inner| try out.appendSlice(allocator, inner),
        .string => |inner| try json.appendString(out, allocator, inner),
        .array => |inner| {
            try out.append(allocator, '[');
            for (inner.items, 0..) |item, i| {
                if (i > 0) try out.append(allocator, ',');
                try appendCanonicalJsonValue(out, allocator, item);
            }
            try out.append(allocator, ']');
        },
        .object => |inner| try appendObjectCanonical(out, allocator, inner),
    }
}

fn appendObjectCanonical(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, object: std.json.ObjectMap) anyerror!void {
    var keys: std.ArrayListUnmanaged([]const u8) = .empty;
    defer freeStringList(allocator, &keys);
    var it = object.iterator();
    while (it.next()) |entry| try appendUniqueString(allocator, &keys, entry.key_ptr.*);
    std.mem.sort([]const u8, keys.items, {}, stringLessThan);

    try out.append(allocator, '{');
    for (keys.items, 0..) |item_key, i| {
        if (i > 0) try out.append(allocator, ',');
        try json.appendString(out, allocator, item_key);
        try out.append(allocator, ':');
        try appendCanonicalJsonValue(out, allocator, object.get(item_key).?);
    }
    try out.append(allocator, '}');
}

fn appendMergedObjectCanonical(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, existing_obj: ?std.json.ObjectMap, patch_obj: std.json.ObjectMap) anyerror!void {
    var keys: std.ArrayListUnmanaged([]const u8) = .empty;
    defer freeStringList(allocator, &keys);
    if (existing_obj) |map| {
        var existing_it = map.iterator();
        while (existing_it.next()) |entry| try appendUniqueString(allocator, &keys, entry.key_ptr.*);
    }
    var patch_it = patch_obj.iterator();
    while (patch_it.next()) |entry| try appendUniqueString(allocator, &keys, entry.key_ptr.*);
    std.mem.sort([]const u8, keys.items, {}, stringLessThan);

    try out.append(allocator, '{');
    for (keys.items, 0..) |item_key, i| {
        if (i > 0) try out.append(allocator, ',');
        try json.appendString(out, allocator, item_key);
        try out.append(allocator, ':');

        const patch_value = patch_obj.get(item_key);
        const existing_value = if (existing_obj) |map| map.get(item_key) else null;
        if (patch_value) |value| {
            if (existing_value) |existing| {
                if (existing == .object and value == .object) {
                    try appendMergedObjectCanonical(out, allocator, existing.object, value.object);
                    continue;
                }
            }
            try appendCanonicalJsonValue(out, allocator, value);
        } else if (existing_value) |value| {
            try appendCanonicalJsonValue(out, allocator, value);
        } else {
            return error.InvalidPayload;
        }
    }
    try out.append(allocator, '}');
}

fn appendStringSetValues(allocator: std.mem.Allocator, values: *std.ArrayListUnmanaged([]const u8), content: []const u8) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch {
        if (content.len > 0) try appendUniqueString(allocator, values, content);
        return;
    };
    defer parsed.deinit();
    try appendStringValue(allocator, values, parsed.value);
}

fn appendStringValue(allocator: std.mem.Allocator, values: *std.ArrayListUnmanaged([]const u8), value: std.json.Value) !void {
    switch (value) {
        .string => |s| try appendUniqueString(allocator, values, s),
        .array => |items| for (items.items) |item| {
            if (item == .string) try appendUniqueString(allocator, values, item.string);
        },
        else => return error.InvalidPayload,
    }
}

fn appendUniqueString(allocator: std.mem.Allocator, values: *std.ArrayListUnmanaged([]const u8), value: []const u8) !void {
    for (values.items) |existing| {
        if (std.mem.eql(u8, existing, value)) return;
    }
    try values.append(allocator, try allocator.dupe(u8, value));
}

fn freeStringList(allocator: std.mem.Allocator, values: *std.ArrayListUnmanaged([]const u8)) void {
    for (values.items) |value| allocator.free(value);
    values.deinit(allocator);
}

fn stringSetJson(allocator: std.mem.Allocator, values: [][]const u8) ![]u8 {
    std.mem.sort([]const u8, values, {}, stringLessThan);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '[');
    var last: ?[]const u8 = null;
    var written: usize = 0;
    for (values) |value| {
        if (last != null and std.mem.eql(u8, last.?, value)) continue;
        if (written > 0) try out.append(allocator, ',');
        try json.appendString(&out, allocator, value);
        last = value;
        written += 1;
    }
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

fn stringLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

test "agent memory reducer converges string sets" {
    const first = try reduceContent(std.testing.allocator, .merge_string_set, null, "[\"zig\",\"sqlite\"]");
    defer std.testing.allocator.free(first);
    const second = try reduceContent(std.testing.allocator, .merge_string_set, first, "[\"postgres\",\"zig\"]");
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings("[\"postgres\",\"sqlite\",\"zig\"]", second);
}

test "agent memory reducer merges objects with patch precedence" {
    const merged = try reduceContent(std.testing.allocator, .merge_object, "{\"language\":\"zig\",\"style\":\"concise\"}", "{\"database\":\"postgres\",\"style\":\"detailed\"}");
    defer std.testing.allocator.free(merged);
    try std.testing.expectEqualStrings("{\"database\":\"postgres\",\"language\":\"zig\",\"style\":\"detailed\"}", merged);
}

test "agent memory reducer deep merges objects deterministically" {
    const first = try reduceContent(std.testing.allocator, .merge_object, null, "{\"profile\":{\"style\":\"concise\",\"language\":\"zig\"},\"tools\":[{\"name\":\"sqlite\",\"rank\":2}],\"z\":true}");
    defer std.testing.allocator.free(first);
    try std.testing.expectEqualStrings("{\"profile\":{\"language\":\"zig\",\"style\":\"concise\"},\"tools\":[{\"name\":\"sqlite\",\"rank\":2}],\"z\":true}", first);

    const second = try reduceContent(std.testing.allocator, .merge_object, first, "{\"profile\":{\"database\":\"postgres\",\"style\":\"detailed\"},\"a\":1}");
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings("{\"a\":1,\"profile\":{\"database\":\"postgres\",\"language\":\"zig\",\"style\":\"detailed\"},\"tools\":[{\"name\":\"sqlite\",\"rank\":2}],\"z\":true}", second);
}
