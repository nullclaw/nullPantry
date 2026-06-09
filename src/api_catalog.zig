const std = @import("std");
const api_routes = @import("api_routes.zig");
const json = @import("json_util.zig");

pub const Decision = union(enum) {
    operation: api_routes.Operation,
    reject: json.HttpResponse,
};

pub const DispatchInput = struct {
    operation: api_routes.Operation,
    method: []const u8,
    query: []const u8 = "",
    body: []const u8 = "",
    seg2: ?[]u8 = null,
    seg3: ?[]u8 = null,
    seg4: ?[]u8 = null,
};

pub fn decision(allocator: std.mem.Allocator, method: []const u8, path: []const u8) Decision {
    return switch (api_routes.matchRequest(method, path)) {
        .operation => |operation| .{ .operation = operation },
        .method_not_allowed => .{ .reject = json.errorResponse(allocator, 405, "method_not_allowed", "Method not allowed") },
        .not_found => .{ .reject = json.errorResponse(allocator, 404, "not_found", "Not found") },
    };
}

test "catalog decision reports operation method rejection and miss" {
    const allocator = std.testing.allocator;

    const hit = decision(allocator, "GET", "/v1/capabilities");
    try std.testing.expect(hit == .operation);

    const method_miss = decision(allocator, "PATCH", "/v1/capabilities");
    try std.testing.expect(method_miss == .reject);
    allocator.free(method_miss.reject.body);

    const path_miss = decision(allocator, "GET", "/v1/does-not-exist");
    try std.testing.expect(path_miss == .reject);
    allocator.free(path_miss.reject.body);
}
