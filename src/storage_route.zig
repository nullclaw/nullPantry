const std = @import("std");
const json = @import("json_util.zig");

pub const Target = enum {
    primary,
    native,
    runtime,
    named,
    subset,
    all,
};

pub const Route = struct {
    target: Target = .primary,
    name: ?[]const u8 = null,
    stores: []const []const u8 = &.{},

    pub fn parse(raw: ?[]const u8) Route {
        const value = raw orelse return .{};
        if (std.ascii.eqlIgnoreCase(value, "primary")) return .{ .target = .primary };
        if (std.ascii.eqlIgnoreCase(value, "default")) return .{ .target = .primary };
        if (std.ascii.eqlIgnoreCase(value, "native")) return .{ .target = .native };
        if (std.ascii.eqlIgnoreCase(value, "canonical")) return .{ .target = .native };
        if (std.ascii.eqlIgnoreCase(value, "sqlite")) return .{ .target = .native };
        if (std.ascii.eqlIgnoreCase(value, "postgres")) return .{ .target = .native };
        if (std.ascii.eqlIgnoreCase(value, "runtime")) return .{ .target = .runtime };
        if (std.ascii.eqlIgnoreCase(value, "external")) return .{ .target = .runtime };
        if (std.ascii.eqlIgnoreCase(value, "redis")) return .{ .target = .runtime };
        if (std.ascii.eqlIgnoreCase(value, "all")) return .{ .target = .all };
        if (std.ascii.eqlIgnoreCase(value, "federated")) return .{ .target = .all };
        return .{ .target = .named, .name = value };
    }

    pub fn fromStores(stores: []const []const u8) Route {
        if (stores.len == 0) return .{};
        if (stores.len == 1) return parse(stores[0]);
        return .{ .target = .subset, .stores = stores };
    }

    pub fn deinit(self: Route, allocator: std.mem.Allocator) void {
        if (self.target == .subset and self.stores.len > 0) allocator.free(self.stores);
    }
};

pub fn fromObject(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !Route {
    if (json.stringField(obj, "storage")) |value| return Route.parse(value);
    if (json.stringField(obj, "store")) |value| return Route.parse(value);
    if (json.stringField(obj, "target_store")) |value| return Route.parse(value);
    if (obj.get("stores")) |value| return fromValue(allocator, value);
    return .{};
}

pub fn objectHasSelector(obj: std.json.ObjectMap) bool {
    return json.stringField(obj, "storage") != null or
        json.stringField(obj, "store") != null or
        json.stringField(obj, "target_store") != null or
        obj.get("stores") != null;
}

pub fn fromObjectOrFallback(allocator: std.mem.Allocator, obj: std.json.ObjectMap, fallback: Route) !Route {
    if (objectHasSelector(obj)) return fromObject(allocator, obj);
    return fallback;
}

pub fn fromObjectOrQuery(allocator: std.mem.Allocator, obj: std.json.ObjectMap, query: []const u8) !Route {
    if (objectHasSelector(obj)) return fromObject(allocator, obj);
    return fromQuery(allocator, query);
}

pub fn fromQuery(allocator: std.mem.Allocator, query: []const u8) !Route {
    if (json.queryParam(query, "storage")) |value| return Route.parse(value);
    if (json.queryParam(query, "store")) |value| return Route.parse(value);
    if (json.queryParam(query, "target_store")) |value| return Route.parse(value);
    if (json.queryParam(query, "stores")) |value| return fromCsv(allocator, value);
    return .{};
}

pub fn fromCsv(allocator: std.mem.Allocator, value: []const u8) !Route {
    var count: usize = 1;
    for (value) |ch| {
        if (ch == ',') count += 1;
    }
    var stores = try allocator.alloc([]const u8, count);
    var used: usize = 0;
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t\r\n");
        if (trimmed.len == 0) continue;
        stores[used] = trimmed;
        used += 1;
    }
    if (used == 0) {
        allocator.free(stores);
        return .{};
    }
    if (used == 1) {
        const route = Route.parse(stores[0]);
        allocator.free(stores);
        return route;
    }
    return Route.fromStores(stores[0..used]);
}

pub fn fromValue(allocator: std.mem.Allocator, value: std.json.Value) !Route {
    return switch (value) {
        .string => |s| Route.parse(s),
        .array => |items| blk: {
            var stores = try allocator.alloc([]const u8, items.items.len);
            var count: usize = 0;
            for (items.items) |item| {
                if (item != .string) continue;
                stores[count] = item.string;
                count += 1;
            }
            if (count == 0) {
                allocator.free(stores);
                break :blk Route{};
            }
            if (count == 1) {
                const route = Route.parse(stores[0]);
                allocator.free(stores);
                break :blk route;
            }
            break :blk Route.fromStores(stores[0..count]);
        },
        else => .{},
    };
}

pub fn fromAliasedObject(allocator: std.mem.Allocator, obj: std.json.ObjectMap, names: []const []const u8) !?Route {
    for (names) |name| {
        if (obj.get(name)) |value| return try fromRouteValue(allocator, value);
    }
    return null;
}

pub fn fromRouteValue(allocator: std.mem.Allocator, value: std.json.Value) !Route {
    return switch (value) {
        .object => |nested| fromObject(allocator, nested),
        else => fromValue(allocator, value),
    };
}

pub fn appendExtractionJson(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), route: Route) !void {
    switch (route.target) {
        .primary => {},
        .native => try out.appendSlice(allocator, ",\"storage\":\"native\""),
        .runtime => try out.appendSlice(allocator, ",\"store\":\"runtime\""),
        .named => {
            try out.appendSlice(allocator, ",\"store\":");
            try json.appendString(out, allocator, route.name orelse "runtime");
        },
        .all => try out.appendSlice(allocator, ",\"storage\":\"all\""),
        .subset => {
            try out.appendSlice(allocator, ",\"stores\":[");
            for (route.stores, 0..) |store_name, i| {
                if (i > 0) try out.append(allocator, ',');
                try json.appendString(out, allocator, store_name);
            }
            try out.append(allocator, ']');
        },
    }
}

pub fn appendRouteJson(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), route: Route) !void {
    try out.appendSlice(allocator, "{\"target\":");
    try json.appendString(out, allocator, @tagName(route.target));
    if (route.name) |name| {
        try out.appendSlice(allocator, ",\"name\":");
        try json.appendString(out, allocator, name);
    }
    if (route.stores.len > 0) {
        try out.appendSlice(allocator, ",\"stores\":[");
        for (route.stores, 0..) |store_name, i| {
            if (i > 0) try out.append(allocator, ',');
            try json.appendString(out, allocator, store_name);
        }
        try out.append(allocator, ']');
    }
    try out.append(allocator, '}');
}

test "storage route parses reserved aliases and named stores" {
    try std.testing.expectEqual(Target.primary, Route.parse(null).target);
    try std.testing.expectEqual(Target.primary, Route.parse("default").target);
    try std.testing.expectEqual(Target.native, Route.parse("postgres").target);
    try std.testing.expectEqual(Target.runtime, Route.parse("redis").target);
    try std.testing.expectEqual(Target.all, Route.parse("federated").target);

    const named = Route.parse("scratch");
    try std.testing.expectEqual(Target.named, named.target);
    try std.testing.expectEqualStrings("scratch", named.name.?);
}

test "storage route parses object and query selectors consistently" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"stores\":[\"scratch\",\"archive\"],\"nested\":{\"store\":\"ignored\"}}", .{});
    defer parsed.deinit();
    const route = try fromObject(allocator, parsed.value.object);
    defer route.deinit(allocator);
    try std.testing.expectEqual(Target.subset, route.target);
    try std.testing.expectEqualStrings("scratch", route.stores[0]);
    try std.testing.expectEqualStrings("archive", route.stores[1]);

    const body_wins = try fromObjectOrQuery(allocator, parsed.value.object, "store=runtime");
    defer body_wins.deinit(allocator);
    try std.testing.expectEqual(Target.subset, body_wins.target);

    const query_route = try fromQuery(allocator, "stores=scratch,archive");
    defer query_route.deinit(allocator);
    try std.testing.expectEqual(Target.subset, query_route.target);
}

test "storage route renders API and extraction JSON" {
    const allocator = std.testing.allocator;
    const route = try fromCsv(allocator, "scratch,archive");
    defer route.deinit(allocator);

    var api_out: std.ArrayListUnmanaged(u8) = .empty;
    defer api_out.deinit(allocator);
    try appendRouteJson(allocator, &api_out, route);
    try std.testing.expectEqualStrings("{\"target\":\"subset\",\"stores\":[\"scratch\",\"archive\"]}", api_out.items);

    var extraction_out: std.ArrayListUnmanaged(u8) = .empty;
    defer extraction_out.deinit(allocator);
    try appendExtractionJson(allocator, &extraction_out, route);
    try std.testing.expectEqualStrings(",\"stores\":[\"scratch\",\"archive\"]", extraction_out.items);
}
