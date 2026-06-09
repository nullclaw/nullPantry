const std = @import("std");
const json = @import("json_util.zig");
const api_query = @import("api_query.zig");
const api_routes = @import("api_routes.zig");

const eql = api_query.optionalSegmentEquals;

pub const Target = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
    query: []const u8,
    seg0: ?[]u8 = null,
    seg1: ?[]u8 = null,
    seg2: ?[]u8 = null,
    seg3: ?[]u8 = null,
    seg4: ?[]u8 = null,

    pub fn parse(allocator: std.mem.Allocator, raw_target: []const u8) !Target {
        const parsed = json.parsePath(raw_target);
        var out = Target{
            .allocator = allocator,
            .path = parsed.path,
            .query = parsed.query,
        };
        errdefer out.deinit();

        out.seg0 = try api_query.decodeSegment(allocator, json.segment(parsed.path, 0));
        out.seg1 = try api_query.decodeSegment(allocator, json.segment(parsed.path, 1));
        out.seg2 = try api_query.decodeSegment(allocator, json.segment(parsed.path, 2));
        out.seg3 = try api_query.decodeSegment(allocator, json.segment(parsed.path, 3));
        out.seg4 = try api_query.decodeSegment(allocator, json.segment(parsed.path, 4));
        return out;
    }

    pub fn deinit(self: *Target) void {
        if (self.seg0) |value| self.allocator.free(value);
        if (self.seg1) |value| self.allocator.free(value);
        if (self.seg2) |value| self.allocator.free(value);
        if (self.seg3) |value| self.allocator.free(value);
        if (self.seg4) |value| self.allocator.free(value);
        self.* = undefined;
    }

    pub fn isHealth(self: Target, method: []const u8) bool {
        if (!std.mem.eql(u8, method, "GET")) return false;
        return (eql(self.seg0, "health") and self.seg1 == null) or
            (eql(self.seg0, "v1") and eql(self.seg1, "health") and self.seg2 == null);
    }

    pub fn hasV1Prefix(self: Target) bool {
        return eql(self.seg0, "v1");
    }

    pub fn matchRoute(self: Target, method: []const u8) api_routes.RouteMatch {
        return api_routes.matchRequest(method, self.path);
    }
};

test "api dispatch target decodes path segments and preserves query" {
    var target = try Target.parse(std.testing.allocator, "/v1/memory/get/key%20with+plus?scope=public");
    defer target.deinit();

    try std.testing.expectEqualStrings("/v1/memory/get/key%20with+plus", target.path);
    try std.testing.expectEqualStrings("scope=public", target.query);
    try std.testing.expectEqualStrings("v1", target.seg0.?);
    try std.testing.expectEqualStrings("memory", target.seg1.?);
    try std.testing.expectEqualStrings("get", target.seg2.?);
    try std.testing.expectEqualStrings("key with+plus", target.seg3.?);
    try std.testing.expect(target.seg4 == null);
    try std.testing.expect(target.hasV1Prefix());
}

test "api dispatch target matches catalog routes without query string" {
    var target = try Target.parse(std.testing.allocator, "/v1/spaces/space-a?include=stats");
    defer target.deinit();

    try std.testing.expectEqual(api_routes.RouteMatch{ .operation = .getSpace }, target.matchRoute("GET"));
    try std.testing.expectEqual(api_routes.RouteMatch.method_not_allowed, target.matchRoute("POST"));
}

test "api dispatch target identifies health aliases" {
    var root_health = try Target.parse(std.testing.allocator, "/health");
    defer root_health.deinit();
    try std.testing.expect(root_health.isHealth("GET"));
    try std.testing.expect(!root_health.isHealth("POST"));

    var v1_health = try Target.parse(std.testing.allocator, "/v1/health");
    defer v1_health.deinit();
    try std.testing.expect(v1_health.isHealth("GET"));
}
