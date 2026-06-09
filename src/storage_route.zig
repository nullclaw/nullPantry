const std = @import("std");
const json = @import("json_util.zig");

pub const store_field = "store";
pub const stores_field = "stores";
pub const legacy_storage_field = "storage";
pub const legacy_target_store_field = "target_store";

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
    owned_backing: ?[]const u8 = null,

    pub fn parse(raw: ?[]const u8) Route {
        const value = std.mem.trim(u8, raw orelse return .{}, " \t\r\n");
        if (value.len == 0) return .{};
        if (std.ascii.eqlIgnoreCase(value, "primary")) return .{ .target = .primary };
        if (std.ascii.eqlIgnoreCase(value, "default")) return .{ .target = .primary };
        if (std.ascii.eqlIgnoreCase(value, "native")) return .{ .target = .native };
        if (std.ascii.eqlIgnoreCase(value, "canonical")) return .{ .target = .native };
        if (std.ascii.eqlIgnoreCase(value, "sqlite")) return .{ .target = .native };
        if (std.ascii.eqlIgnoreCase(value, "postgres")) return .{ .target = .native };
        if (std.ascii.eqlIgnoreCase(value, "runtime")) return .{ .target = .runtime };
        if (std.ascii.eqlIgnoreCase(value, "external")) return .{ .target = .runtime };
        if (std.ascii.eqlIgnoreCase(value, "none")) return .{ .target = .runtime };
        if (std.ascii.eqlIgnoreCase(value, "memory")) return .{ .target = .runtime };
        if (std.ascii.eqlIgnoreCase(value, "memory_lru")) return .{ .target = .runtime };
        if (std.ascii.eqlIgnoreCase(value, "in_memory")) return .{ .target = .runtime };
        if (std.ascii.eqlIgnoreCase(value, "markdown")) return .{ .target = .runtime };
        if (std.ascii.eqlIgnoreCase(value, "md")) return .{ .target = .runtime };
        if (std.ascii.eqlIgnoreCase(value, "filesystem")) return .{ .target = .runtime };
        if (std.ascii.eqlIgnoreCase(value, "redis")) return .{ .target = .runtime };
        if (std.ascii.eqlIgnoreCase(value, "all")) return .{ .target = .all };
        if (std.ascii.eqlIgnoreCase(value, "federated")) return .{ .target = .all };
        if (std.ascii.eqlIgnoreCase(value, "clickhouse")) return .{ .target = .runtime };
        if (std.ascii.eqlIgnoreCase(value, "api")) return .{ .target = .runtime };
        if (std.ascii.eqlIgnoreCase(value, "http")) return .{ .target = .runtime };
        if (std.ascii.eqlIgnoreCase(value, "nullpantry_api")) return .{ .target = .runtime };
        return .{ .target = .named, .name = value };
    }

    pub fn fromStores(stores: []const []const u8) Route {
        if (stores.len == 0) return .{};
        if (stores.len == 1) return parse(stores[0]);
        return .{ .target = .subset, .stores = stores };
    }

    pub fn deinit(self: Route, allocator: std.mem.Allocator) void {
        if (self.target == .subset and self.stores.len > 0) allocator.free(self.stores);
        if (self.owned_backing) |value| allocator.free(value);
    }
};

fn parseExplicitSelector(raw: []const u8) !Route {
    const value = std.mem.trim(u8, raw, " \t\r\n");
    if (value.len == 0) return error.InvalidStorageSelector;
    return Route.parse(value);
}

pub fn fromObject(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !Route {
    if (objectSelectorCount(obj) > 1) return error.InvalidStorageSelector;
    if (obj.get(legacy_storage_field)) |value| return parseExplicitSelector(try selectorString(value));
    if (obj.get(store_field)) |value| return parseExplicitSelector(try selectorString(value));
    if (obj.get(legacy_target_store_field)) |value| return parseExplicitSelector(try selectorString(value));
    if (obj.get(stores_field)) |value| return fromValue(allocator, value);
    return .{};
}

pub fn fromObjectOwned(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !Route {
    if (objectSelectorCount(obj) > 1) return error.InvalidStorageSelector;
    if (obj.get(legacy_storage_field)) |value| return try fromOwnedSelector(allocator, try allocator.dupe(u8, try selectorString(value)));
    if (obj.get(store_field)) |value| return try fromOwnedSelector(allocator, try allocator.dupe(u8, try selectorString(value)));
    if (obj.get(legacy_target_store_field)) |value| return try fromOwnedSelector(allocator, try allocator.dupe(u8, try selectorString(value)));
    if (obj.get(stores_field)) |value| return fromValueOwned(allocator, value);
    return .{};
}

fn selectorString(value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |s| s,
        else => error.InvalidStorageSelector,
    };
}

fn objectSelectorCount(obj: std.json.ObjectMap) usize {
    var count: usize = 0;
    if (obj.get(legacy_storage_field) != null) count += 1;
    if (obj.get(store_field) != null) count += 1;
    if (obj.get(legacy_target_store_field) != null) count += 1;
    if (obj.get(stores_field) != null) count += 1;
    return count;
}

pub fn objectHasSelector(obj: std.json.ObjectMap) bool {
    return objectSelectorCount(obj) > 0;
}

pub fn queryHasSelector(query: []const u8) bool {
    return querySelectorCount(query) > 0;
}

pub fn fromObjectOrFallback(allocator: std.mem.Allocator, obj: std.json.ObjectMap, fallback: Route) !Route {
    if (objectHasSelector(obj)) return fromObject(allocator, obj);
    return fallback;
}

pub fn fromObjectOrQuery(allocator: std.mem.Allocator, obj: std.json.ObjectMap, query: []const u8) !Route {
    if (queryHasSelector(query)) return fromQuery(allocator, query);
    if (objectHasSelector(obj)) return fromObject(allocator, obj);
    return fromQuery(allocator, query);
}

pub fn fromQuery(allocator: std.mem.Allocator, query: []const u8) !Route {
    if (querySelectorCount(query) > 1) return error.InvalidStorageSelector;
    if (try queryParamRoute(allocator, query, legacy_storage_field)) |route| return route;
    if (try queryParamRoute(allocator, query, store_field)) |route| return route;
    if (try queryParamRoute(allocator, query, legacy_target_store_field)) |route| return route;
    if (try queryParamCsvRoute(allocator, query, stores_field)) |route| return route;
    return .{};
}

fn querySelectorCount(query: []const u8) usize {
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, part, '=') orelse part.len;
        const name = part[0..eq];
        if (isSelectorField(name)) {
            count += 1;
        }
    }
    return count;
}

fn queryParamRoute(allocator: std.mem.Allocator, query: []const u8, name: []const u8) !?Route {
    const raw = json.queryParam(query, name) orelse return null;
    if (!needsPercentDecode(raw)) return try parseExplicitSelector(raw);
    const decoded = try json.percentDecode(allocator, raw);
    return try fromOwnedSelector(allocator, decoded);
}

fn queryParamCsvRoute(allocator: std.mem.Allocator, query: []const u8, name: []const u8) !?Route {
    const raw = json.queryParam(query, name) orelse return null;
    if (!needsPercentDecode(raw)) return try fromCsv(allocator, raw);
    const decoded = try json.percentDecode(allocator, raw);
    return try fromOwnedCsv(allocator, decoded);
}

fn needsPercentDecode(raw: []const u8) bool {
    for (raw) |ch| {
        if (ch == '%' or ch == '+') return true;
    }
    return false;
}

pub fn fromOwnedSelector(allocator: std.mem.Allocator, value: []const u8) !Route {
    errdefer allocator.free(value);
    var route = try parseExplicitSelector(value);
    if (route.target == .named) {
        route.owned_backing = value;
    } else {
        allocator.free(value);
    }
    return route;
}

pub fn fromOwnedCsv(allocator: std.mem.Allocator, value: []const u8) !Route {
    errdefer allocator.free(value);
    var route = try fromCsv(allocator, value);
    if (route.target == .named or route.target == .subset) {
        route.owned_backing = value;
    } else {
        allocator.free(value);
    }
    return route;
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
    return routeFromOwnedStoreNames(allocator, stores, used);
}

pub fn fromValue(allocator: std.mem.Allocator, value: std.json.Value) !Route {
    return switch (value) {
        .string => |s| try fromCsv(allocator, s),
        .array => |items| blk: {
            var stores = try allocator.alloc([]const u8, items.items.len);
            errdefer allocator.free(stores);
            var count: usize = 0;
            for (items.items) |item| {
                if (item != .string) return error.InvalidStorageSelector;
                if (std.mem.trim(u8, item.string, " \t\r\n").len == 0) return error.InvalidStorageSelector;
                stores[count] = item.string;
                count += 1;
            }
            break :blk try routeFromOwnedStoreNames(allocator, stores, count);
        },
        else => error.InvalidStorageSelector,
    };
}

pub fn fromValueOwned(allocator: std.mem.Allocator, value: std.json.Value) !Route {
    return switch (value) {
        .string => |s| try fromOwnedCsv(allocator, try allocator.dupe(u8, s)),
        .array => |items| blk: {
            var csv: std.ArrayListUnmanaged(u8) = .empty;
            errdefer csv.deinit(allocator);
            var count: usize = 0;
            for (items.items) |item| {
                if (item != .string) return error.InvalidStorageSelector;
                if (std.mem.trim(u8, item.string, " \t\r\n").len == 0) return error.InvalidStorageSelector;
                if (count > 0) try csv.append(allocator, ',');
                try csv.appendSlice(allocator, item.string);
                count += 1;
            }
            if (count == 0) return error.InvalidStorageSelector;
            break :blk try fromOwnedCsv(allocator, try csv.toOwnedSlice(allocator));
        },
        else => error.InvalidStorageSelector,
    };
}

fn routeFromOwnedStoreNames(allocator: std.mem.Allocator, stores: [][]const u8, used: usize) !Route {
    if (used == 0) {
        allocator.free(stores);
        return error.InvalidStorageSelector;
    }

    var unique: usize = 0;
    for (stores[0..used]) |store_name| {
        const canonical = canonicalStoreSelectorName(store_name);
        if (std.mem.eql(u8, canonical, "all")) {
            allocator.free(stores);
            return .{ .target = .all };
        }
        if (storeNameSeen(stores[0..unique], canonical)) continue;
        stores[unique] = canonical;
        unique += 1;
    }

    if (unique == 1) {
        const route = Route.parse(stores[0]);
        allocator.free(stores);
        return route;
    }
    if (unique == stores.len) return Route.fromStores(stores);

    errdefer allocator.free(stores);
    const compact = try allocator.dupe([]const u8, stores[0..unique]);
    allocator.free(stores);
    return Route.fromStores(compact);
}

fn storeNameSeen(stores: []const []const u8, name: []const u8) bool {
    for (stores) |store_name| {
        if (std.mem.eql(u8, store_name, name)) return true;
    }
    return false;
}

fn canonicalStoreSelectorName(name: []const u8) []const u8 {
    const route = Route.parse(name);
    return switch (route.target) {
        .primary => "primary",
        .native => "native",
        .runtime => "runtime",
        .named => route.name orelse name,
        .all => "all",
        .subset => name,
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

pub fn isSelectorField(name: []const u8) bool {
    return std.mem.eql(u8, name, store_field) or
        std.mem.eql(u8, name, legacy_storage_field) or
        std.mem.eql(u8, name, legacy_target_store_field) or
        std.mem.eql(u8, name, stores_field);
}

pub fn canonicalQueryFieldForValue(value: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, value, ',') != null) stores_field else store_field;
}

pub fn appendCanonicalObjectFields(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), route: anytype, first: *bool) !void {
    if (route.target == .primary) return;
    if (!first.*) try out.append(allocator, ',');
    first.* = false;
    switch (route.target) {
        .primary => {},
        .native => try out.appendSlice(allocator, "\"" ++ store_field ++ "\":\"native\""),
        .runtime => try out.appendSlice(allocator, "\"" ++ store_field ++ "\":\"runtime\""),
        .named => {
            try out.appendSlice(allocator, "\"" ++ store_field ++ "\":");
            try json.appendString(out, allocator, route.name orelse "runtime");
        },
        .all => try out.appendSlice(allocator, "\"" ++ store_field ++ "\":\"all\""),
        .subset => {
            try out.appendSlice(allocator, "\"" ++ stores_field ++ "\":[");
            for (route.stores, 0..) |store_name, i| {
                if (i > 0) try out.append(allocator, ',');
                try json.appendString(out, allocator, store_name);
            }
            try out.append(allocator, ']');
        },
    }
}

pub fn appendExtractionJson(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), route: Route) !void {
    var first = false;
    try appendCanonicalObjectFields(allocator, out, route, &first);
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

fn expectTarget(expected: Target, route: Route) !void {
    try std.testing.expectEqual(expected, route.target);
}

fn expectNamed(expected: []const u8, route: Route) !void {
    try std.testing.expectEqual(Target.named, route.target);
    try std.testing.expectEqualStrings(expected, route.name.?);
}

fn expectSubset(expected: []const []const u8, route: Route) !void {
    try std.testing.expectEqual(Target.subset, route.target);
    try std.testing.expectEqual(expected.len, route.stores.len);
    for (expected, 0..) |store_name, i| {
        try std.testing.expectEqualStrings(store_name, route.stores[i]);
    }
}

fn routeFromObjectJson(allocator: std.mem.Allocator, body: []const u8) !Route {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    return fromObjectOwned(allocator, parsed.value.object);
}

test "storage route parses canonical targets and named stores" {
    try std.testing.expectEqual(Target.primary, Route.parse(null).target);
    try std.testing.expectEqual(Target.primary, Route.parse("").target);
    try std.testing.expectEqual(Target.primary, Route.parse(" \t\r\n").target);
    try expectTarget(Target.primary, Route.parse("primary"));
    try expectTarget(Target.native, Route.parse(" native "));
    try expectTarget(Target.runtime, Route.parse("runtime"));
    try expectTarget(Target.all, Route.parse("all"));

    try expectNamed("scratch", Route.parse("scratch"));
    try expectNamed("mem0", Route.parse("mem0"));
}

test "storage route owned object parsing survives parsed json deinit" {
    const allocator = std.testing.allocator;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"stores\":\" scratch , archive \"}", .{});
    const route = try fromObjectOwned(allocator, parsed.value.object);
    parsed.deinit();
    defer route.deinit(allocator);

    try std.testing.expectEqual(Target.subset, route.target);
    try std.testing.expectEqual(@as(usize, 2), route.stores.len);
    try std.testing.expectEqualStrings("scratch", route.stores[0]);
    try std.testing.expectEqualStrings("archive", route.stores[1]);
    try std.testing.expect(route.owned_backing != null);
}

test "storage route parses object and query selectors consistently" {
    const allocator = std.testing.allocator;
    const route = try routeFromObjectJson(allocator, "{\"stores\":[\"scratch\",\"archive\"],\"nested\":{\"store\":\"ignored\"}}");
    defer route.deinit(allocator);
    try expectSubset(&.{ "scratch", "archive" }, route);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"stores\":[\"scratch\",\"archive\"],\"nested\":{\"store\":\"ignored\"}}", .{});
    defer parsed.deinit();

    const query_wins = try fromObjectOrQuery(allocator, parsed.value.object, "store=runtime");
    defer query_wins.deinit(allocator);
    try expectTarget(Target.runtime, query_wins);

    const body_route = try fromObjectOrQuery(allocator, parsed.value.object, "");
    defer body_route.deinit(allocator);
    try expectSubset(&.{ "scratch", "archive" }, body_route);

    const query_route = try fromQuery(allocator, "stores=scratch,archive");
    defer query_route.deinit(allocator);
    try expectSubset(&.{ "scratch", "archive" }, query_route);
    try std.testing.expect(query_route.owned_backing == null);

    const string_route = try routeFromObjectJson(allocator, "{\"stores\":\"scratch,archive\"}");
    defer string_route.deinit(allocator);
    try expectSubset(&.{ "scratch", "archive" }, string_route);
}

test "storage route compacts sparse csv store selectors before ownership transfer" {
    const allocator = std.testing.allocator;

    const csv_route = try fromQuery(allocator, "stores=scratch,,archive,scratch,");
    defer csv_route.deinit(allocator);
    try expectSubset(&.{ "scratch", "archive" }, csv_route);
}

test "storage route rejects invalid explicit selectors" {
    const allocator = std.testing.allocator;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"stores\":[\"scratch\",false,\"archive\",\"scratch\",42]}", .{});
    defer parsed.deinit();
    try std.testing.expectError(error.InvalidStorageSelector, fromObject(allocator, parsed.value.object));

    var empty_array = try std.json.parseFromSlice(std.json.Value, allocator, "{\"stores\":[]}", .{});
    defer empty_array.deinit();
    try std.testing.expectError(error.InvalidStorageSelector, fromObject(allocator, empty_array.value.object));

    var empty_item = try std.json.parseFromSlice(std.json.Value, allocator, "{\"stores\":[\"scratch\",\"\"]}", .{});
    defer empty_item.deinit();
    try std.testing.expectError(error.InvalidStorageSelector, fromObject(allocator, empty_item.value.object));

    var scalar = try std.json.parseFromSlice(std.json.Value, allocator, "{\"stores\":false}", .{});
    defer scalar.deinit();
    try std.testing.expectError(error.InvalidStorageSelector, fromObject(allocator, scalar.value.object));

    var empty_named = try std.json.parseFromSlice(std.json.Value, allocator, "{\"store\":\"\"}", .{});
    defer empty_named.deinit();
    try std.testing.expectError(error.InvalidStorageSelector, fromObject(allocator, empty_named.value.object));

    var wrong_named_type = try std.json.parseFromSlice(std.json.Value, allocator, "{\"store\":false}", .{});
    defer wrong_named_type.deinit();
    try std.testing.expectError(error.InvalidStorageSelector, fromObject(allocator, wrong_named_type.value.object));

    try std.testing.expectError(error.InvalidStorageSelector, fromQuery(allocator, "store="));
    try std.testing.expectError(error.InvalidStorageSelector, fromQuery(allocator, "stores=,,"));
}

test "storage route rejects ambiguous explicit selectors" {
    const allocator = std.testing.allocator;

    var body_conflict = try std.json.parseFromSlice(std.json.Value, allocator, "{\"store\":\"scratch\",\"stores\":[\"archive\"]}", .{});
    defer body_conflict.deinit();
    try std.testing.expectError(error.InvalidStorageSelector, fromObject(allocator, body_conflict.value.object));

    try std.testing.expectError(error.InvalidStorageSelector, fromQuery(allocator, "store=scratch&stores=archive"));
    try std.testing.expectError(error.InvalidStorageSelector, fromQuery(allocator, "store=scratch&store=archive"));

    var body = try std.json.parseFromSlice(std.json.Value, allocator, "{\"store\":\"scratch\"}", .{});
    defer body.deinit();
    const query_wins = try fromObjectOrQuery(allocator, body.value.object, "store=archive");
    defer query_wins.deinit(allocator);
    try std.testing.expectEqual(Target.named, query_wins.target);
    try std.testing.expectEqualStrings("archive", query_wins.name.?);
}

test "storage route canonicalizes subset selectors" {
    const allocator = std.testing.allocator;

    const runtime_route = try fromQuery(allocator, "stores=runtime,runtime");
    defer runtime_route.deinit(allocator);
    try expectTarget(Target.runtime, runtime_route);

    const mixed_route = try fromCsv(allocator, "native,native,scratch");
    defer mixed_route.deinit(allocator);
    try expectSubset(&.{ "native", "scratch" }, mixed_route);

    const all_route = try fromCsv(allocator, "scratch,all,archive");
    defer all_route.deinit(allocator);
    try expectTarget(Target.all, all_route);
}

test "storage route decodes query selectors before routing" {
    const allocator = std.testing.allocator;

    const named = try fromQuery(allocator, "store=team%3Aalpha");
    defer named.deinit(allocator);
    try std.testing.expectEqual(Target.named, named.target);
    try std.testing.expectEqualStrings("team:alpha", named.name.?);
    try std.testing.expect(named.owned_backing != null);

    const subset = try fromQuery(allocator, "stores=team%3Aalpha,archive%2Dold");
    defer subset.deinit(allocator);
    try std.testing.expectEqual(Target.subset, subset.target);
    try std.testing.expectEqualStrings("team:alpha", subset.stores[0]);
    try std.testing.expectEqualStrings("archive-old", subset.stores[1]);
    try std.testing.expect(subset.owned_backing != null);

    const canonical = try fromQuery(allocator, "store=native");
    defer canonical.deinit(allocator);
    try expectTarget(Target.native, canonical);
    try std.testing.expect(canonical.owned_backing == null);
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

    var native_out: std.ArrayListUnmanaged(u8) = .empty;
    defer native_out.deinit(allocator);
    try appendExtractionJson(allocator, &native_out, Route{ .target = .native });
    try std.testing.expectEqualStrings(",\"store\":\"native\"", native_out.items);

    var all_out: std.ArrayListUnmanaged(u8) = .empty;
    defer all_out.deinit(allocator);
    try appendExtractionJson(allocator, &all_out, Route{ .target = .all });
    try std.testing.expectEqualStrings(",\"store\":\"all\"", all_out.items);
}
