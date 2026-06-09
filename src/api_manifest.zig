const std = @import("std");
const api_routes = @import("api_routes.zig");
const json = @import("json_util.zig");

pub fn buildManifest(allocator: std.mem.Allocator) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"name\":\"nullpantry\",\"version\":\"v1\",\"base_path\":\"/v1\",\"methods\":{");
    var first = true;
    for (api_routes.routes) |route| {
        for (api_routes.http_methods) |method| {
            try appendOperation(allocator, &out, &first, route, method, route.operationFor(method));
        }
    }
    try out.appendSlice(allocator, "},\"headers\":{\"actor_id\":\"X-NullPantry-Actor-Id\",\"actor_scopes\":\"X-NullPantry-Actor-Scopes\",\"actor_capabilities\":\"X-NullPantry-Actor-Capabilities\"},\"auth\":{\"token_principals_env\":\"NULLPANTRY_TOKEN_PRINCIPALS\",\"note\":\"token principal scopes/capabilities are authoritative; request headers can only narrow them\"}}");
    return out.toOwnedSlice(allocator);
}

fn appendOperation(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    first: *bool,
    route: api_routes.RouteDescriptor,
    method: api_routes.HttpMethod,
    operation: ?api_routes.Operation,
) !void {
    const op = operation orelse return;
    if (!first.*) try out.append(allocator, ',');
    first.* = false;

    try json.appendString(out, allocator, api_routes.operationId(op));
    try out.append(allocator, ':');
    const endpoint = try routeEndpoint(allocator, method, route.path);
    defer allocator.free(endpoint);
    try json.appendString(out, allocator, endpoint);
}

fn routeEndpoint(allocator: std.mem.Allocator, method: api_routes.HttpMethod, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s} /v1{s}", .{ method.wireName(), path });
}

fn expectOperation(methods: std.json.ObjectMap, route: api_routes.RouteDescriptor, method: api_routes.HttpMethod, operation: ?api_routes.Operation) !void {
    const op = operation orelse return;
    const operation_id = api_routes.operationId(op);
    const manifest_value = methods.get(operation_id) orelse return error.MissingManifestOperation;
    try std.testing.expect(manifest_value == .string);

    const expected = try routeEndpoint(std.testing.allocator, method, route.path);
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, manifest_value.string);
}

test "SDK manifest is generated from the route catalog" {
    const body = try buildManifest(std.testing.allocator);
    defer std.testing.allocator.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);

    const root = parsed.value.object;
    try std.testing.expectEqualStrings("nullpantry", root.get("name").?.string);
    try std.testing.expectEqualStrings("v1", root.get("version").?.string);
    try std.testing.expectEqualStrings("/v1", root.get("base_path").?.string);

    const methods_value = root.get("methods") orelse return error.MissingManifestMethods;
    try std.testing.expect(methods_value == .object);
    const methods = methods_value.object;
    for (api_routes.routes) |route| {
        for (api_routes.http_methods) |method| {
            try expectOperation(methods, route, method, route.operationFor(method));
        }
    }

    const headers = root.get("headers").?.object;
    try std.testing.expectEqualStrings("X-NullPantry-Actor-Scopes", headers.get("actor_scopes").?.string);
    const auth = root.get("auth").?.object;
    try std.testing.expectEqualStrings("NULLPANTRY_TOKEN_PRINCIPALS", auth.get("token_principals_env").?.string);
}
