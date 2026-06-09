const std = @import("std");
const api_body = @import("api_body.zig");
const api_types = @import("api_types.zig");
const domain = @import("domain.zig");

pub const Context = api_types.Context;

pub fn effective(ctx: *Context, obj: std.json.ObjectMap) ![]const u8 {
    const default_scopes_json = "[]";
    const requested = try api_body.rawArrayField(ctx.allocator, obj, "scopes", default_scopes_json);
    defer ctx.allocator.free(requested);
    if (!std.mem.eql(u8, requested, "[]")) return try domain.intersectJsonStringLists(ctx.allocator, requested, ctx.actor_scopes_json);
    return ctx.actor_scopes_json;
}

test "effective scopes default to actor scopes and narrow requested scopes" {
    var ctx = Context{
        .allocator = std.testing.allocator,
        .store = undefined,
        .actor_scopes_json = "[\"public\",\"team\",\"private\"]",
    };

    var empty = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{}", .{});
    defer empty.deinit();
    const default_scopes = try effective(&ctx, empty.value.object);
    try std.testing.expectEqualStrings(ctx.actor_scopes_json, default_scopes);

    var requested = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"scopes\":[\"team\",\"missing\"]}", .{});
    defer requested.deinit();
    const narrowed = try effective(&ctx, requested.value.object);
    defer std.testing.allocator.free(narrowed);
    try std.testing.expectEqualStrings("[\"team\"]", narrowed);

    var invalid = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"scopes\":{\"scope\":\"team\"}}", .{});
    defer invalid.deinit();
    try std.testing.expectError(error.InvalidRawJson, effective(&ctx, invalid.value.object));

    var mixed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"scopes\":[\"team\",42]}", .{});
    defer mixed.deinit();
    try std.testing.expectError(error.InvalidRawJson, effective(&ctx, mixed.value.object));
}
