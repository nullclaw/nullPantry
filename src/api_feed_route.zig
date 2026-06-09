const std = @import("std");
const storage_routes = @import("storage_route.zig");
const store_feed = @import("store_feed.zig");

pub const FeedEvent = store_feed.FeedEvent;
pub const Route = storage_routes.Route;

pub fn matchesStorageRoute(allocator: std.mem.Allocator, event: FeedEvent, route: Route) bool {
    return switch (route.target) {
        .primary, .all => true,
        .native => matchesStoreName(allocator, event, "native", true),
        .runtime => matchesStoreName(allocator, event, "runtime", false),
        .named => blk: {
            const name = route.name orelse break :blk false;
            break :blk matchesStoreName(allocator, event, name, false);
        },
        .subset => blk: {
            for (route.stores) |store_name| {
                if (matchesStoreName(allocator, event, store_name, std.ascii.eqlIgnoreCase(store_name, "native"))) break :blk true;
            }
            break :blk false;
        },
    };
}

fn matchesStoreName(allocator: std.mem.Allocator, event: FeedEvent, store_name: []const u8, include_unrouted_native: bool) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, event.payload_json, .{}) catch return include_unrouted_native;
    defer parsed.deinit();
    if (parsed.value != .object) return include_unrouted_native;
    const obj = parsed.value.object;
    if (!storage_routes.objectHasSelector(obj)) return include_unrouted_native;
    const route = storage_routes.fromObject(allocator, obj) catch return include_unrouted_native;
    defer route.deinit(allocator);
    return routeMatchesStoreName(route, store_name, include_unrouted_native);
}

fn routeMatchesStoreName(route: Route, store_name: []const u8, include_unrouted_native: bool) bool {
    return switch (route.target) {
        .primary => include_unrouted_native,
        .all => true,
        .native => std.ascii.eqlIgnoreCase(store_name, "native"),
        .runtime => std.ascii.eqlIgnoreCase(store_name, "runtime"),
        .named => if (route.name) |name| std.ascii.eqlIgnoreCase(name, store_name) else false,
        .subset => blk: {
            for (route.stores) |candidate| {
                if (routeMatchesStoreName(Route.parse(candidate), store_name, false)) break :blk true;
            }
            break :blk false;
        },
    };
}

fn testEvent(payload_json: []const u8) FeedEvent {
    return .{
        .id = 1,
        .event_type = "agent_memory.put",
        .operation = "put",
        .object_type = "agent_memory",
        .object_id = "key",
        .scope = "public",
        .permissions_json = "[]",
        .actor_id = null,
        .dedupe_key = null,
        .causality_json = "{}",
        .payload_json = payload_json,
        .status = "applied",
        .created_at_ms = 1,
        .applied_at_ms = 1,
        .compacted_at_ms = null,
    };
}

test "api feed route treats unrouted payloads as native only" {
    const event = testEvent("{\"key\":\"pref\",\"content\":\"plain\"}");

    try std.testing.expect(matchesStorageRoute(std.testing.allocator, event, Route.parse("native")));
    try std.testing.expect(matchesStorageRoute(std.testing.allocator, event, Route.parse("all")));
    try std.testing.expect(!matchesStorageRoute(std.testing.allocator, event, Route.parse("runtime")));
    try std.testing.expect(!matchesStorageRoute(std.testing.allocator, event, Route.parse("scratch")));
}

test "api feed route matches explicit payload store selectors" {
    const runtime_event = testEvent("{\"key\":\"pref\",\"store\":\"runtime\"}");
    const named_event = testEvent("{\"key\":\"pref\",\"store\":\"scratch\"}");
    const native_event = testEvent("{\"key\":\"pref\",\"storage\":\"native\"}");

    try std.testing.expect(matchesStorageRoute(std.testing.allocator, runtime_event, Route.parse("runtime")));
    try std.testing.expect(!matchesStorageRoute(std.testing.allocator, runtime_event, Route.parse("native")));
    try std.testing.expect(matchesStorageRoute(std.testing.allocator, named_event, Route.parse("scratch")));
    try std.testing.expect(matchesStorageRoute(std.testing.allocator, native_event, Route.parse("native")));
}

test "api feed route matches subset selectors recursively" {
    const event = testEvent("{\"key\":\"pref\",\"stores\":[\"scratch\",\"archive\"]}");

    try std.testing.expect(matchesStorageRoute(std.testing.allocator, event, Route.parse("scratch")));
    try std.testing.expect(matchesStorageRoute(std.testing.allocator, event, Route{ .target = .subset, .stores = &.{ "native", "archive" } }));
    try std.testing.expect(!matchesStorageRoute(std.testing.allocator, event, Route.parse("runtime")));
}

test "api feed route uses fallback for malformed payloads" {
    const event = testEvent("not-json");

    try std.testing.expect(matchesStorageRoute(std.testing.allocator, event, Route.parse("native")));
    try std.testing.expect(!matchesStorageRoute(std.testing.allocator, event, Route.parse("runtime")));
}
