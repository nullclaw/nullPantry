const std = @import("std");
const agent_memory_test_helpers = @import("agent_memory_test_helpers.zig");
const domain = @import("domain.zig");
const store_agent_memory = @import("store_agent_memory.zig");
const store_types = @import("store_types.zig");

pub const Route = store_types.AgentMemoryStorageRoute;

pub fn routeForStoreName(name: []const u8) Route {
    return Route.parse(name);
}

pub fn requireStores(route: Route) anyerror![]const []const u8 {
    if (route.stores.len == 0) return error.AgentMemoryStorageUnavailable;
    return route.stores;
}

pub const GetInput = store_types.AgentMemoryGetInput;
pub const ListInput = store_types.AgentMemoryListInput;
pub const SearchInput = store_types.AgentMemorySearchInput;
pub const CountInput = store_types.AgentMemoryCountInput;

fn appendFanInEntries(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(domain.AgentMemory), entries: []domain.AgentMemory) !void {
    if (out.items.len == 0) {
        try store_agent_memory.appendSlice(allocator, out, entries);
    } else {
        try store_agent_memory.appendMissingSlice(allocator, out, entries);
    }
}

pub fn getByInput(store: anytype, allocator: std.mem.Allocator, input: GetInput) anyerror!?domain.AgentMemory {
    const stores = try requireStores(input.route);
    for (stores) |store_name| {
        var store_input = input;
        store_input.route = routeForStoreName(store_name);
        if (try store.agentMemoryGetByInput(allocator, store_input)) |entry| return entry;
    }
    return null;
}

pub fn listByInput(store: anytype, allocator: std.mem.Allocator, input: ListInput) anyerror![]domain.AgentMemory {
    if (input.limit) |limit| {
        if (limit == 0) return allocator.alloc(domain.AgentMemory, 0);
        return listWindowByInput(store, allocator, input, limit);
    }

    const stores = try requireStores(input.route);
    var out: std.ArrayListUnmanaged(domain.AgentMemory) = .empty;
    errdefer store_agent_memory.freeArrayList(allocator, &out);
    for (stores) |store_name| {
        var store_input = input;
        store_input.route = routeForStoreName(store_name);
        const entries = try store.agentMemoryListByInput(allocator, store_input);
        defer store_agent_memory.freeSlice(allocator, entries);
        try appendFanInEntries(allocator, &out, entries);
    }
    return out.toOwnedSlice(allocator);
}

fn listWindowByInput(store: anytype, allocator: std.mem.Allocator, input: ListInput, limit: usize) anyerror![]domain.AgentMemory {
    const stores = try requireStores(input.route);
    const fetch_limit = store_agent_memory.windowPrefetchLimit(limit, input.offset);
    var out: std.ArrayListUnmanaged(domain.AgentMemory) = .empty;
    errdefer store_agent_memory.freeArrayList(allocator, &out);
    for (stores) |store_name| {
        var store_input = input;
        store_input.route = routeForStoreName(store_name);
        store_input.limit = fetch_limit;
        store_input.offset = 0;
        const entries = try store.agentMemoryListByInput(allocator, store_input);
        defer store_agent_memory.freeSlice(allocator, entries);
        try appendFanInEntries(allocator, &out, entries);
    }
    return store_agent_memory.pageArrayList(allocator, &out, limit, input.offset);
}

pub fn searchByInput(store: anytype, allocator: std.mem.Allocator, input: SearchInput) anyerror![]domain.AgentMemory {
    const stores = try requireStores(input.route);
    var out: std.ArrayListUnmanaged(domain.AgentMemory) = .empty;
    errdefer store_agent_memory.freeArrayList(allocator, &out);
    for (stores) |store_name| {
        var store_input = input;
        store_input.route = routeForStoreName(store_name);
        const entries = try store.agentMemorySearchByInput(allocator, store_input);
        defer store_agent_memory.freeSlice(allocator, entries);
        try appendFanInEntries(allocator, &out, entries);
    }
    store_agent_memory.sortResults(out.items);
    store_agent_memory.trimResults(allocator, &out, input.limit);
    return out.toOwnedSlice(allocator);
}

pub fn countByInput(store: anytype, input: CountInput) anyerror!usize {
    const stores = try requireStores(input.route);
    var count: usize = 0;
    for (stores) |store_name| {
        var store_input = input;
        store_input.route = routeForStoreName(store_name);
        count += try store.agentMemoryCountByInput(store_input);
    }
    return count;
}

test "agent memory subset read surface is input based" {
    const self = @This();
    try std.testing.expect(@hasDecl(self, "getByInput"));
    try std.testing.expect(@hasDecl(self, "listByInput"));
    try std.testing.expect(@hasDecl(self, "searchByInput"));
    try std.testing.expect(@hasDecl(self, "countByInput"));
    try std.testing.expect(@hasField(GetInput, "access"));
    try std.testing.expect(@hasField(ListInput, "limit"));
    try std.testing.expect(@hasField(SearchInput, "route"));
    try std.testing.expect(@hasField(CountInput, "capabilities_json"));
    const forbidden_suffix = "Routed" ++ "WithAuth";
    try std.testing.expect(std.mem.indexOf(u8, @embedFile("store_agent_memory_subset.zig"), forbidden_suffix) == null);
    try std.testing.expect(!@hasDecl(self, "getVisibleWithAuth"));
    try std.testing.expect(!@hasDecl(self, "listAnyVisibleWindowWithAuth"));
    try std.testing.expect(!@hasDecl(self, "searchAnyVisibleWithAuth"));
}

const TestingSubsetStore = struct {
    list_scratch_calls: usize = 0,
    list_archive_calls: usize = 0,
    search_scratch_calls: usize = 0,
    search_archive_calls: usize = 0,

    fn routeName(input_route: Route) ![]const u8 {
        return input_route.name orelse error.TestExpectedEqual;
    }

    pub fn agentMemoryGetByInput(_: *TestingSubsetStore, _: std.mem.Allocator, _: GetInput) !?domain.AgentMemory {
        return null;
    }

    pub fn agentMemoryListByInput(self: *TestingSubsetStore, allocator: std.mem.Allocator, input: ListInput) ![]domain.AgentMemory {
        try std.testing.expectEqual(@as(?usize, 3), input.limit);
        try std.testing.expectEqual(@as(usize, 0), input.offset);

        const name = try routeName(input.route);
        var entries = try allocator.alloc(domain.AgentMemory, 2);
        for (entries) |*entry| entry.* = agent_memory_test_helpers.emptyAgentMemory();
        errdefer store_agent_memory.freeSlice(allocator, entries);
        if (std.mem.eql(u8, name, "scratch")) {
            self.list_scratch_calls += 1;
            entries[0] = try agent_memory_test_helpers.ownedAgentMemory(allocator, "scratch.first", "scratch first", .{ .category = "prefs", .store = "scratch", .timestamp = "300" });
            entries[1] = try agent_memory_test_helpers.ownedAgentMemory(allocator, "scratch.second", "scratch second", .{ .category = "prefs", .store = "scratch", .timestamp = "200" });
        } else if (std.mem.eql(u8, name, "archive")) {
            self.list_archive_calls += 1;
            entries[0] = try agent_memory_test_helpers.ownedAgentMemory(allocator, "archive.first", "archive first", .{ .category = "prefs", .store = "archive", .timestamp = "100" });
            entries[1] = try agent_memory_test_helpers.ownedAgentMemory(allocator, "archive.second", "archive second", .{ .category = "prefs", .store = "archive", .timestamp = "50" });
        } else {
            return error.TestExpectedEqual;
        }
        return entries;
    }

    pub fn agentMemorySearchByInput(self: *TestingSubsetStore, allocator: std.mem.Allocator, input: SearchInput) ![]domain.AgentMemory {
        try std.testing.expectEqual(@as(usize, 2), input.limit);
        try std.testing.expectEqualStrings("pref", input.query);

        const name = try routeName(input.route);
        var entries = try allocator.alloc(domain.AgentMemory, 2);
        for (entries) |*entry| entry.* = agent_memory_test_helpers.emptyAgentMemory();
        errdefer store_agent_memory.freeSlice(allocator, entries);
        if (std.mem.eql(u8, name, "scratch")) {
            self.search_scratch_calls += 1;
            entries[0] = try agent_memory_test_helpers.ownedAgentMemory(allocator, "pref.same", "scratch same", .{ .category = "prefs", .store = "scratch", .timestamp = "100", .score = 1.0 });
            entries[1] = try agent_memory_test_helpers.ownedAgentMemory(allocator, "pref.low", "scratch low", .{ .category = "prefs", .store = "scratch", .timestamp = "400", .score = 0.2 });
        } else if (std.mem.eql(u8, name, "archive")) {
            self.search_archive_calls += 1;
            entries[0] = try agent_memory_test_helpers.ownedAgentMemory(allocator, "pref.same", "archive same", .{ .category = "prefs", .store = "archive", .timestamp = "300", .score = 1.0 });
            entries[1] = try agent_memory_test_helpers.ownedAgentMemory(allocator, "pref.lower", "archive lower", .{ .category = "prefs", .store = "archive", .timestamp = "500", .score = 0.1 });
        } else {
            return error.TestExpectedEqual;
        }
        return entries;
    }

    pub fn agentMemoryCountByInput(_: *TestingSubsetStore, input: CountInput) !usize {
        const name = try routeName(input.route);
        if (std.mem.eql(u8, name, "scratch")) return 2;
        if (std.mem.eql(u8, name, "archive")) return 3;
        return error.TestExpectedEqual;
    }
};

test "agent memory subset list windows prefetch per store before global page" {
    var store = TestingSubsetStore{};
    const stores = [_][]const u8{ "scratch", "archive" };
    const result = try listByInput(&store, std.testing.allocator, .{
        .category = "prefs",
        .actor_id = "agent:a",
        .route = Route.fromStores(&stores),
        .limit = 2,
        .offset = 1,
    });
    defer store_agent_memory.freeSlice(std.testing.allocator, result);

    try std.testing.expectEqual(@as(usize, 1), store.list_scratch_calls);
    try std.testing.expectEqual(@as(usize, 1), store.list_archive_calls);
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("scratch.second", result[0].key);
    try std.testing.expectEqualStrings("archive.first", result[1].key);
}

test "agent memory subset search preserves per-store same-key memories and trims globally" {
    var store = TestingSubsetStore{};
    const stores = [_][]const u8{ "scratch", "archive" };
    const result = try searchByInput(&store, std.testing.allocator, .{
        .query = "pref",
        .actor_id = "agent:a",
        .route = Route.fromStores(&stores),
        .limit = 2,
    });
    defer store_agent_memory.freeSlice(std.testing.allocator, result);

    try std.testing.expectEqual(@as(usize, 1), store.search_scratch_calls);
    try std.testing.expectEqual(@as(usize, 1), store.search_archive_calls);
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("archive", result[0].store);
    try std.testing.expectEqualStrings("scratch", result[1].store);
    try std.testing.expectEqualStrings("pref.same", result[0].key);
    try std.testing.expectEqualStrings("pref.same", result[1].key);
}

test "agent memory subset count sums requested stores and rejects empty routes" {
    var store = TestingSubsetStore{};
    const stores = [_][]const u8{ "scratch", "archive" };

    try std.testing.expectEqual(@as(usize, 5), try countByInput(&store, .{ .route = Route.fromStores(&stores) }));
    try std.testing.expectError(error.AgentMemoryStorageUnavailable, countByInput(&store, .{}));
}
