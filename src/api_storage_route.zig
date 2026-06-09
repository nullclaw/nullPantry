const std = @import("std");
const kg_compat = @import("kg_compat.zig");
const storage_routes = @import("storage_route.zig");

pub const Route = storage_routes.Route;

pub fn targetsKg(route: Route) bool {
    if (route.target != .named) return false;
    const name = route.name orelse return false;
    return nameIsKg(name);
}

fn nameIsKg(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "kg");
}

pub fn includesKg(route: Route) bool {
    if (targetsKg(route)) return true;
    if (route.target == .subset) {
        for (route.stores) |store_name| {
            if (nameIsKg(store_name)) return true;
        }
    }
    return false;
}

pub fn withoutKg(allocator: std.mem.Allocator, route: Route) !?Route {
    if (targetsKg(route)) return null;
    if (route.target != .subset) return route;

    var count: usize = 0;
    var single_store: ?[]const u8 = null;
    for (route.stores) |store_name| {
        if (nameIsKg(store_name)) continue;
        count += 1;
        if (single_store == null) single_store = store_name;
    }
    if (count == 0) return null;
    if (count == 1) {
        return Route.parse(single_store orelse return null);
    }

    var stores = try allocator.alloc([]const u8, count);
    var used: usize = 0;
    for (route.stores) |store_name| {
        if (nameIsKg(store_name)) continue;
        stores[used] = store_name;
        used += 1;
    }
    return Route.fromStores(stores);
}

pub fn withoutKgOrNative(allocator: std.mem.Allocator, route: Route) !Route {
    const non_kg = try withoutKg(allocator, route);
    return non_kg orelse Route{ .target = .native };
}

pub fn kgMemoryRequest(key: []const u8, route: Route) bool {
    return kg_compat.isKgKey(key) or targetsKg(route);
}

test "api storage route detects kg targets and subsets" {
    try std.testing.expect(targetsKg(Route.parse("kg")));
    try std.testing.expect(targetsKg(Route.parse("KG")));
    try std.testing.expect(!targetsKg(Route.parse("native")));
    try std.testing.expect(includesKg(Route{ .target = .subset, .stores = &.{ "native", "kg" } }));
    try std.testing.expect(!includesKg(Route{ .target = .subset, .stores = &.{ "native", "scratch" } }));
}

test "api storage route strips kg from subset routes" {
    const allocator = std.testing.allocator;
    var stripped = (try withoutKg(allocator, Route{ .target = .subset, .stores = &.{ "native", "kg", "scratch" } })) orelse return error.TestExpectedEqual;
    defer stripped.deinit(allocator);

    try std.testing.expectEqual(Route{ .target = .subset, .stores = stripped.stores }, stripped);
    try std.testing.expectEqual(@as(usize, 2), stripped.stores.len);
    try std.testing.expectEqualStrings("native", stripped.stores[0]);
    try std.testing.expectEqualStrings("scratch", stripped.stores[1]);
}

test "api storage route collapses all-kg and single non-kg subsets" {
    const allocator = std.testing.allocator;
    try std.testing.expect((try withoutKg(allocator, Route.parse("kg"))) == null);
    try std.testing.expect((try withoutKg(allocator, Route{ .target = .subset, .stores = &.{"kg"} })) == null);

    const native = (try withoutKg(allocator, Route{ .target = .subset, .stores = &.{ "kg", "native" } })) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(Route{ .target = .native }, native);

    const fallback = try withoutKgOrNative(allocator, Route.parse("kg"));
    try std.testing.expectEqual(Route{ .target = .native }, fallback);
}

test "api storage route treats kg keys as kg memory requests" {
    try std.testing.expect(kgMemoryRequest(kg_compat.entity_store_prefix ++ "entity-a", Route.parse("native")));
    try std.testing.expect(kgMemoryRequest("plain-key", Route.parse("kg")));
    try std.testing.expect(!kgMemoryRequest("plain-key", Route.parse("native")));
}
