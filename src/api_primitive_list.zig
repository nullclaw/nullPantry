const std = @import("std");
const domain = @import("domain.zig");
const json = @import("json_util.zig");
const api_query = @import("api_query.zig");
const api_responses = @import("api_responses.zig");
const api_types = @import("api_types.zig");
const store_mod = @import("store.zig");

pub const Context = api_types.Context;
pub const HttpResponse = api_types.HttpResponse;

pub const ScopeFilter = struct {
    scopes_json: []const u8,
    empty: bool = false,
};

pub fn inputFromQuery(ctx: *Context, query: []const u8) !store_mod.PrimitiveListInput {
    const scope_filter = try effectiveScopesFromQuery(ctx, query);
    return .{
        .limit = api_query.parseLimit(json.queryParam(query, "limit"), 100),
        .scopes_json = scope_filter.scopes_json,
        .scope_filter_empty = scope_filter.empty,
        .actor_id = ctx.actor_id,
        .include_deprecated = api_query.queryBool(query, "include_deprecated", false),
    };
}

pub fn effectiveScopesFromQuery(ctx: *Context, query: []const u8) !ScopeFilter {
    if (try json.queryParamDecoded(ctx.allocator, query, "scopes")) |requested| {
        defer ctx.allocator.free(requested);
        const trimmed = std.mem.trim(u8, requested, " \t\r\n");
        if (trimmed.len == 0) return .{ .scopes_json = ctx.actor_scopes_json };

        var requested_json_owned: ?[]const u8 = null;
        defer if (requested_json_owned) |owned| ctx.allocator.free(owned);
        const requested_json = if (trimmed[0] == '[')
            trimmed
        else blk: {
            requested_json_owned = try singleQueryScopeJson(ctx.allocator, trimmed);
            break :blk requested_json_owned.?;
        };
        const filtered = try domain.intersectJsonStringLists(ctx.allocator, requested_json, ctx.actor_scopes_json);
        return .{ .scopes_json = filtered, .empty = jsonStringListIsEmpty(filtered) };
    }
    if (try json.queryParamDecoded(ctx.allocator, query, "scope")) |scope| {
        defer ctx.allocator.free(scope);
        const trimmed = std.mem.trim(u8, scope, " \t\r\n");
        if (trimmed.len == 0) return .{ .scopes_json = ctx.actor_scopes_json };
        const requested_json = try singleQueryScopeJson(ctx.allocator, trimmed);
        defer ctx.allocator.free(requested_json);
        const filtered = try domain.intersectJsonStringLists(ctx.allocator, requested_json, ctx.actor_scopes_json);
        return .{ .scopes_json = filtered, .empty = jsonStringListIsEmpty(filtered) };
    }
    return .{ .scopes_json = ctx.actor_scopes_json };
}

pub fn jsonStringListIsEmpty(list_json: []const u8) bool {
    const trimmed = std.mem.trim(u8, list_json, " \t\r\n");
    return trimmed.len == 0 or std.mem.eql(u8, trimmed, "[]");
}

fn singleQueryScopeJson(allocator: std.mem.Allocator, scope: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '[');
    try json.appendString(&out, allocator, scope);
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

pub fn appendMeta(ctx: *Context, out: *std.ArrayListUnmanaged(u8), object_type: []const u8, count: usize, input: store_mod.PrimitiveListInput) !void {
    try out.appendSlice(ctx.allocator, "],\"object_type\":");
    try json.appendString(out, ctx.allocator, object_type);
    try out.print(ctx.allocator, ",\"count\":{d},\"limit\":{d},\"include_deprecated\":", .{ count, input.limit });
    try out.appendSlice(ctx.allocator, if (input.include_deprecated) "true" else "false");
    try out.appendSlice(ctx.allocator, ",\"scopes\":");
    try json.appendRawJsonArray(out, ctx.allocator, input.scopes_json);
    try out.append(ctx.allocator, '}');
}

pub fn emptyResponse(ctx: *Context, list_field: []const u8, object_type: []const u8, input: store_mod.PrimitiveListInput) HttpResponse {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.append(ctx.allocator, '{') catch return api_responses.serverError(ctx);
    json.appendString(&out, ctx.allocator, list_field) catch return api_responses.serverError(ctx);
    out.appendSlice(ctx.allocator, ":[") catch return api_responses.serverError(ctx);
    appendMeta(ctx, &out, object_type, 0, input) catch return api_responses.serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return api_responses.serverError(ctx) };
}

test "primitive list scope query intersects actor scopes" {
    var ctx = Context{
        .allocator = std.testing.allocator,
        .store = undefined,
        .actor_scopes_json = "[\"alpha\",\"beta\"]",
    };

    const filter = try effectiveScopesFromQuery(&ctx, "scopes=%5B%22beta%22%2C%22gamma%22%5D");
    defer std.testing.allocator.free(filter.scopes_json);

    try std.testing.expect(!filter.empty);
    try std.testing.expectEqualStrings("[\"beta\"]", filter.scopes_json);
}

test "primitive list empty scope filter marks empty intersection" {
    var ctx = Context{
        .allocator = std.testing.allocator,
        .store = undefined,
        .actor_scopes_json = "[\"alpha\"]",
    };

    const filter = try effectiveScopesFromQuery(&ctx, "scope=beta");
    defer std.testing.allocator.free(filter.scopes_json);

    try std.testing.expect(filter.empty);
    try std.testing.expectEqualStrings("[]", filter.scopes_json);
}

test "primitive list scope query rejects malformed scope arrays" {
    var ctx = Context{
        .allocator = std.testing.allocator,
        .store = undefined,
        .actor_scopes_json = "[\"alpha\",\"beta\"]",
    };

    try std.testing.expectError(error.InvalidRawJson, effectiveScopesFromQuery(&ctx, "scopes=%5B%22beta%22%2C%5D"));
    try std.testing.expectError(error.InvalidRawJson, effectiveScopesFromQuery(&ctx, "scopes=%5B%22beta%22%2C42%5D"));
}

fn primitiveListResponseMetaForTest(ctx: *Context, input: store_mod.PrimitiveListInput) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(ctx.allocator);
    try out.appendSlice(ctx.allocator, "{\"items\":[");
    try appendMeta(ctx, &out, "memory_atom", 2, input);
    return out.toOwnedSlice(ctx.allocator);
}

test "primitive list meta writes scopes array" {
    var ctx = Context{
        .allocator = std.testing.allocator,
        .store = undefined,
    };

    const body = try primitiveListResponseMetaForTest(&ctx, .{
        .limit = 25,
        .scopes_json = "[\"alpha\",\"beta\"]",
        .include_deprecated = true,
    });
    defer std.testing.allocator.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqual(@as(usize, 0), root.get("items").?.array.items.len);
    try std.testing.expectEqualStrings("memory_atom", root.get("object_type").?.string);
    try std.testing.expectEqual(@as(i64, 2), root.get("count").?.integer);
    try std.testing.expectEqual(@as(i64, 25), root.get("limit").?.integer);
    try std.testing.expect(root.get("include_deprecated").?.bool);

    const scopes = root.get("scopes").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), scopes.len);
    try std.testing.expectEqualStrings("alpha", scopes[0].string);
    try std.testing.expectEqualStrings("beta", scopes[1].string);
}

test "primitive list meta rejects non-array scopes json" {
    var ctx = Context{
        .allocator = std.testing.allocator,
        .store = undefined,
    };

    try std.testing.expectError(error.InvalidRawJson, primitiveListResponseMetaForTest(&ctx, .{
        .scopes_json = "{\"scope\":\"alpha\"}",
    }));
}
