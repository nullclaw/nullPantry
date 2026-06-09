const std = @import("std");
const api_types = @import("api_types.zig");
const json = @import("json_util.zig");

pub const Context = api_types.Context;

pub fn parse(ctx: *Context, body: []const u8) !std.json.Parsed(std.json.Value) {
    const parsed = try std.json.parseFromSlice(std.json.Value, ctx.allocator, if (body.len == 0) "{}" else body, .{});
    if (parsed.value != .object) {
        parsed.deinit();
        return error.InvalidJsonObject;
    }
    return parsed;
}

pub fn rawField(allocator: std.mem.Allocator, obj: std.json.ObjectMap, name: []const u8, fallback: []const u8) ![]const u8 {
    const value = obj.get(name) orelse return json.rawJsonFieldFallback(allocator, name, fallback);
    return try rawJsonFieldValue(allocator, name, value, fallback);
}

pub fn rawArrayField(allocator: std.mem.Allocator, obj: std.json.ObjectMap, name: []const u8, fallback: []const u8) ![]const u8 {
    return try rawFieldWithRoot(allocator, obj, name, fallback, .array);
}

pub fn rawObjectField(allocator: std.mem.Allocator, obj: std.json.ObjectMap, name: []const u8, fallback: []const u8) ![]const u8 {
    return try rawFieldWithRoot(allocator, obj, name, fallback, .object);
}

pub fn rawArrayFieldAny(allocator: std.mem.Allocator, obj: std.json.ObjectMap, names: []const []const u8, fallback: []const u8) ![]const u8 {
    return try rawFieldAnyWithRoot(allocator, obj, names, fallback, .array);
}

pub fn rawObjectFieldAny(allocator: std.mem.Allocator, obj: std.json.ObjectMap, names: []const []const u8, fallback: []const u8) ![]const u8 {
    return try rawFieldAnyWithRoot(allocator, obj, names, fallback, .object);
}

pub fn rawJsonFieldValue(allocator: std.mem.Allocator, name: []const u8, value: std.json.Value, fallback: []const u8) ![]const u8 {
    return try json.rawJsonFieldValue(allocator, name, value, fallback);
}

fn rawFieldAnyWithRoot(allocator: std.mem.Allocator, obj: std.json.ObjectMap, names: []const []const u8, fallback: []const u8, root: json.RawJsonRoot) ![]const u8 {
    for (names) |name| {
        if (obj.get(name)) |value| {
            if (value == .null) continue;
            return try rawFieldWithRoot(allocator, obj, name, fallback, root);
        }
    }
    return try rawFallbackWithRoot(allocator, fallback, root);
}

fn rawFieldWithRoot(allocator: std.mem.Allocator, obj: std.json.ObjectMap, name: []const u8, fallback: []const u8, root: json.RawJsonRoot) ![]const u8 {
    const value = obj.get(name) orelse return try rawFallbackWithRoot(allocator, fallback, root);
    const raw = try rawJsonFieldValue(allocator, name, value, fallback);
    errdefer allocator.free(raw);
    if (!json.rawJsonRootIs(allocator, raw, root)) return error.InvalidRawJson;
    return raw;
}

fn rawFallbackWithRoot(allocator: std.mem.Allocator, fallback: []const u8, root: json.RawJsonRoot) ![]const u8 {
    const raw = try json.rawJsonRootOrError(allocator, null, fallback, root);
    return allocator.dupe(u8, raw);
}

test "API body parser accepts empty object body and rejects non-objects" {
    var ctx = Context{
        .allocator = std.testing.allocator,
        .store = undefined,
    };

    var empty = try parse(&ctx, "");
    defer empty.deinit();
    try std.testing.expect(empty.value == .object);

    try std.testing.expectError(error.InvalidJsonObject, parse(&ctx, "[]"));
}

test "raw JSON fields preserve JSON string compatibility fields" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"permissions\":\"[\\\"public\\\"]\",\"metadata\":{\"a\":1}}", .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    const permissions = try rawField(std.testing.allocator, obj, "permissions", "[]");
    defer std.testing.allocator.free(permissions);
    try std.testing.expectEqualStrings("[\"public\"]", permissions);

    const metadata = try rawField(std.testing.allocator, obj, "metadata", "{}");
    defer std.testing.allocator.free(metadata);
    try std.testing.expectEqualStrings("{\"a\":1}", metadata);
}

test "typed raw JSON fields enforce root container type" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"permissions\":\"[\\\"public\\\"]\",\"metadata\":{\"a\":1},\"bad_permissions\":{\"scope\":\"public\"},\"bad_metadata\":[\"x\"]}",
        .{},
    );
    defer parsed.deinit();
    const obj = parsed.value.object;

    const permissions = try rawArrayField(std.testing.allocator, obj, "permissions", "[]");
    defer std.testing.allocator.free(permissions);
    try std.testing.expectEqualStrings("[\"public\"]", permissions);

    const metadata = try rawObjectField(std.testing.allocator, obj, "metadata", "{}");
    defer std.testing.allocator.free(metadata);
    try std.testing.expectEqualStrings("{\"a\":1}", metadata);

    try std.testing.expectError(error.InvalidRawJson, rawArrayField(std.testing.allocator, obj, "bad_permissions", "[]"));
    try std.testing.expectError(error.InvalidRawJson, rawObjectField(std.testing.allocator, obj, "bad_metadata", "{}"));
}

test "single raw JSON helpers return owned fallback values" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{}", .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    const field_fallback = "{}";
    const field = try rawField(std.testing.allocator, obj, "missing", field_fallback);
    defer std.testing.allocator.free(field);
    try std.testing.expectEqualStrings(field_fallback, field);
    try std.testing.expect(field.ptr != field_fallback.ptr);

    const array_fallback = "[]";
    const array = try rawArrayField(std.testing.allocator, obj, "missing_array", array_fallback);
    defer std.testing.allocator.free(array);
    try std.testing.expectEqualStrings(array_fallback, array);
    try std.testing.expect(array.ptr != array_fallback.ptr);

    const object_fallback = "{}";
    const object = try rawObjectField(std.testing.allocator, obj, "missing_object", object_fallback);
    defer std.testing.allocator.free(object);
    try std.testing.expectEqualStrings(object_fallback, object);
    try std.testing.expect(object.ptr != object_fallback.ptr);
}

test "raw JSON suffix fields validate missing fallback values" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{}", .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    try std.testing.expectError(error.InvalidRawJson, rawField(std.testing.allocator, obj, "metadata_json", "{\"broken\":"));

    const metadata = try rawField(std.testing.allocator, obj, "metadata_json", " {\"ok\":true} ");
    defer std.testing.allocator.free(metadata);
    try std.testing.expectEqualStrings("{\"ok\":true}", metadata);
}

test "typed raw JSON fields validate fallback roots" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"nullable\":null}", .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    try std.testing.expectError(error.InvalidRawJson, rawArrayField(std.testing.allocator, obj, "missing", "{}"));
    try std.testing.expectError(error.InvalidRawJson, rawObjectField(std.testing.allocator, obj, "missing", "[]"));
    try std.testing.expectError(error.InvalidRawJson, rawArrayField(std.testing.allocator, obj, "nullable", "{}"));
    try std.testing.expectError(error.InvalidRawJson, rawObjectField(std.testing.allocator, obj, "nullable", "[]"));
}

test "typed raw JSON alias fields enforce root container type" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"required_scopes\":[\"public\"],\"sections\":{\"memory\":[]},\"nullable_required_scopes\":null,\"fallback_required_scopes\":[\"team\"],\"nullable_sections\":null,\"fallback_sections\":{\"summary\":true},\"bad_required_scopes\":{\"scope\":\"public\"},\"bad_sections\":[\"x\"],\"null_then_bad\":null,\"bad_after_null\":{\"scope\":\"public\"}}",
        .{},
    );
    defer parsed.deinit();
    const obj = parsed.value.object;

    const required_scopes = try rawArrayFieldAny(std.testing.allocator, obj, &.{ "missing_required_scopes", "required_scopes" }, "[]");
    defer std.testing.allocator.free(required_scopes);
    try std.testing.expectEqualStrings("[\"public\"]", required_scopes);

    const sections = try rawObjectFieldAny(std.testing.allocator, obj, &.{ "missing_sections", "sections" }, "{}");
    defer std.testing.allocator.free(sections);
    try std.testing.expectEqualStrings("{\"memory\":[]}", sections);

    const nullable_required_scopes = try rawArrayFieldAny(std.testing.allocator, obj, &.{ "nullable_required_scopes", "fallback_required_scopes" }, "[]");
    defer std.testing.allocator.free(nullable_required_scopes);
    try std.testing.expectEqualStrings("[\"team\"]", nullable_required_scopes);

    const nullable_sections = try rawObjectFieldAny(std.testing.allocator, obj, &.{ "nullable_sections", "fallback_sections" }, "{}");
    defer std.testing.allocator.free(nullable_sections);
    try std.testing.expectEqualStrings("{\"summary\":true}", nullable_sections);

    const fallback_array = try rawArrayFieldAny(std.testing.allocator, obj, &.{"absent_required_scopes"}, "[]");
    defer std.testing.allocator.free(fallback_array);
    try std.testing.expectEqualStrings("[]", fallback_array);

    const fallback_object = try rawObjectFieldAny(std.testing.allocator, obj, &.{"absent_sections"}, "{}");
    defer std.testing.allocator.free(fallback_object);
    try std.testing.expectEqualStrings("{}", fallback_object);

    try std.testing.expectError(error.InvalidRawJson, rawArrayFieldAny(std.testing.allocator, obj, &.{"bad_required_scopes"}, "[]"));
    try std.testing.expectError(error.InvalidRawJson, rawObjectFieldAny(std.testing.allocator, obj, &.{"bad_sections"}, "{}"));
    try std.testing.expectError(error.InvalidRawJson, rawArrayFieldAny(std.testing.allocator, obj, &.{ "null_then_bad", "bad_after_null" }, "[]"));
    try std.testing.expectError(error.InvalidRawJson, rawArrayFieldAny(std.testing.allocator, obj, &.{"absent_required_scopes"}, "{}"));
    try std.testing.expectError(error.InvalidRawJson, rawObjectFieldAny(std.testing.allocator, obj, &.{"absent_sections"}, "[]"));
    try std.testing.expectError(error.InvalidRawJson, rawArrayFieldAny(std.testing.allocator, obj, &.{"nullable_required_scopes"}, "{}"));
}

test "raw JSON aliases reject invalid encoded JSON strings" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"payload_json\":\"{\\\"broken\\\":\",\"permissions_json\":\"[\\\"public\\\",]\",\"causality_json\":\"{\\\"also_broken\\\":\"}",
        .{},
    );
    defer parsed.deinit();
    const obj = parsed.value.object;

    try std.testing.expectError(error.InvalidRawJson, rawField(std.testing.allocator, obj, "payload_json", "{}"));
    try std.testing.expectError(error.InvalidRawJson, rawField(std.testing.allocator, obj, "permissions_json", "[]"));
    try std.testing.expectError(error.InvalidRawJson, rawField(std.testing.allocator, obj, "causality_json", "{}"));
}

test "raw JSON suffix aliases are strict for all encoded JSON fields" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"metadata_json\":\"{\\\"broken\\\":\",\"metadata\":\"{\\\"broken\\\":\"}",
        .{},
    );
    defer parsed.deinit();
    const obj = parsed.value.object;

    try std.testing.expectError(error.InvalidRawJson, rawField(std.testing.allocator, obj, "metadata_json", "{}"));

    const compatibility = try rawField(std.testing.allocator, obj, "metadata", "{}");
    defer std.testing.allocator.free(compatibility);
    try std.testing.expectEqualStrings("\"{\\\"broken\\\":\"", compatibility);
}
