const std = @import("std");
const build_options = @import("build_options");
const agent_memory_runtime = @import("agent_memory_runtime.zig");
const compat = @import("compat.zig");
const domain = @import("domain.zig");
const ids = @import("ids.zig");
const redis_config = @import("redis_config.zig");
const store_agent_memory = @import("store_agent_memory.zig");
const store_feed = @import("store_feed.zig");
const store_mod = @import("store.zig");
const store_types = @import("store_types.zig");

const Allocator = std.mem.Allocator;
const Runtime = agent_memory_runtime.Runtime;
const Store = store_mod.Store;
const Route = store_types.AgentMemoryStorageRoute;
const ReadAccess = store_types.AgentMemoryReadAccess;

const Order = struct {
    timestamp_ms: i64,
    origin_instance_id: []const u8,
    origin_sequence: i64,
};

const WriteInput = struct {
    key: []const u8,
    content: []const u8,
    category: []const u8 = "contract",
    session_id: ?[]const u8 = null,
    scope: ?[]const u8 = null,
    permissions_json: []const u8 = "[]",
    actor_id: []const u8,
    writer_actor_id: ?[]const u8 = null,
    operation: domain.AgentMemoryOperation = .put,
    event_order: ?Order = null,
};

const ContractBackend = union(enum) {
    runtime: *Runtime,
    store: struct {
        value: *Store,
        route: Route = .{ .target = .native },
    },

    fn put(self: ContractBackend, allocator: Allocator, input: WriteInput) !domain.AgentMemory {
        return switch (self) {
            .runtime => |runtime| runtime.store(allocator, .{
                .key = input.key,
                .content = input.content,
                .category = input.category,
                .session_id = input.session_id,
                .scope = input.scope,
                .permissions_json = input.permissions_json,
                .actor_id = input.actor_id,
                .writer_actor_id = input.writer_actor_id,
                .operation = input.operation,
                .event_order = toRuntimeOrder(input.event_order),
            }),
            .store => |ctx| ctx.value.agentMemoryStoreRouted(allocator, .{
                .key = input.key,
                .content = input.content,
                .category = input.category,
                .session_id = input.session_id,
                .scope = input.scope,
                .permissions_json = input.permissions_json,
                .actor_id = input.actor_id,
                .writer_actor_id = input.writer_actor_id,
                .operation = input.operation,
                .event_order = toStoreOrder(input.event_order),
            }, ctx.route),
        };
    }

    fn get(self: ContractBackend, allocator: Allocator, key: []const u8, session_id: ?[]const u8, actor_id: []const u8, scopes_json: []const u8, access: ReadAccess) !?domain.AgentMemory {
        return switch (self) {
            .runtime => |runtime| runtime.getByInput(allocator, .{
                .key = key,
                .session_id = if (access == .any_visible) null else session_id,
                .actor_id = actor_id,
                .scopes_json = if (access == .exact_owner) null else scopes_json,
                .any_session = access == .any_visible,
            }),
            .store => |ctx| ctx.value.agentMemoryGetByInput(allocator, .{
                .key = key,
                .session_id = session_id,
                .actor_id = actor_id,
                .scopes_json = scopes_json,
                .route = ctx.route,
                .access = access,
            }),
        };
    }

    fn list(self: ContractBackend, allocator: Allocator, category: ?[]const u8, session_id: ?[]const u8, actor_id: []const u8, scopes_json: []const u8, access: ReadAccess, limit: ?usize, offset: usize) ![]domain.AgentMemory {
        return switch (self) {
            .runtime => |runtime| runtime.listByInput(allocator, .{
                .category = category,
                .session_id = if (access == .any_visible) null else session_id,
                .actor_id = actor_id,
                .scopes_json = if (access == .exact_owner) null else scopes_json,
                .any_session = access == .any_visible,
                .limit = limit,
                .offset = offset,
            }),
            .store => |ctx| ctx.value.agentMemoryListByInput(allocator, .{
                .category = category,
                .session_id = session_id,
                .actor_id = actor_id,
                .scopes_json = scopes_json,
                .route = ctx.route,
                .access = access,
                .limit = limit,
                .offset = offset,
            }),
        };
    }

    fn search(self: ContractBackend, allocator: Allocator, query: []const u8, session_id: ?[]const u8, actor_id: []const u8, scopes_json: []const u8, access: ReadAccess, limit: usize) ![]domain.AgentMemory {
        return switch (self) {
            .runtime => |runtime| runtime.searchByInput(allocator, .{
                .query = query,
                .limit = limit,
                .session_id = if (access == .any_visible) null else session_id,
                .actor_id = actor_id,
                .scopes_json = scopes_json,
                .any_session = access == .any_visible,
            }),
            .store => |ctx| ctx.value.agentMemorySearchByInput(allocator, .{
                .query = query,
                .limit = limit,
                .session_id = session_id,
                .actor_id = actor_id,
                .scopes_json = scopes_json,
                .route = ctx.route,
                .access = access,
            }),
        };
    }

    fn count(self: ContractBackend, actor_id: []const u8, scopes_json: []const u8) !usize {
        return switch (self) {
            .runtime => |runtime| runtime.countByInput(.{ .actor_id = actor_id, .scopes_json = scopes_json }),
            .store => |ctx| ctx.value.agentMemoryCountByInput(.{ .actor_id = actor_id, .scopes_json = scopes_json, .route = ctx.route }),
        };
    }

    fn delete(self: ContractBackend, key: []const u8, session_id: ?[]const u8, actor_id: []const u8, writer_actor_id: []const u8, order: ?Order) !bool {
        return switch (self) {
            .runtime => |runtime| runtime.deleteByInput(.{
                .key = key,
                .session_id = session_id,
                .actor_id = actor_id,
                .writer_actor_id = writer_actor_id,
                .event_order = toRuntimeOrder(order),
            }),
            .store => |ctx| ctx.value.agentMemoryDeleteByInput(.{
                .key = key,
                .session_id = session_id,
                .actor_id = actor_id,
                .writer_actor_id = writer_actor_id,
                .route = ctx.route,
                .event_order = toStoreOrder(order),
            }),
        };
    }

    fn applyRemotePut(self: ContractBackend, allocator: Allocator, key: []const u8, content: []const u8, actor_id: []const u8, order: Order) !void {
        return switch (self) {
            .runtime => |runtime| {
                const event_json = try std.fmt.allocPrint(
                    allocator,
                    "{{\"origin_instance_id\":\"{s}\",\"origin_sequence\":{d},\"timestamp_ms\":{d},\"event_type\":\"agent_memory.put\",\"operation\":\"put\",\"object_type\":\"agent_memory\",\"object_id\":\"{s}\",\"actor_id\":\"{s}\",\"scope\":\"public\",\"permissions\":[\"public\"],\"payload\":{{\"key\":\"{s}\",\"content\":\"{s}\",\"category\":\"contract\",\"scope\":\"public\",\"permissions\":[\"public\"],\"owner_id\":\"{s}\"}}}}",
                    .{ order.origin_instance_id, order.origin_sequence, order.timestamp_ms, key, actor_id, key, content, actor_id },
                );
                defer allocator.free(event_json);
                try runtime.applyFeedEventByInput(allocator, .{ .event_json = event_json, .actor_id = actor_id, .scopes_json = "[\"public\"]" });
            },
            .store => |ctx| {
                const payload_json = try std.fmt.allocPrint(
                    allocator,
                    "{{\"key\":\"{s}\",\"content\":\"{s}\",\"category\":\"contract\",\"scope\":\"public\",\"permissions\":[\"public\"],\"owner_id\":\"{s}\"}}",
                    .{ key, content, actor_id },
                );
                defer allocator.free(payload_json);
                const result = try ctx.value.applyFeedAgentMemoryRouted(allocator, .{
                    .event = .{
                        .event_type = "agent_memory.put",
                        .operation = "put",
                        .object_type = "agent_memory",
                        .object_id = key,
                        .scope = "public",
                        .permissions_json = "[\"public\"]",
                        .actor_id = actor_id,
                        .payload_json = payload_json,
                        .status = "applied",
                    },
                    .input = .{
                        .key = key,
                        .content = content,
                        .category = "contract",
                        .scope = "public",
                        .permissions_json = "[\"public\"]",
                        .actor_id = actor_id,
                        .suppress_feed = true,
                        .event_order = toStoreOrder(order),
                    },
                    .writer_actor_id = actor_id,
                    .event_order = toStoreOrder(order),
                }, ctx.route);
                if (result.entry) |entry| {
                    var copy = entry;
                    agent_memory_runtime.freeAgentMemory(allocator, &copy);
                }
            },
        };
    }

    fn feedIds(self: ContractBackend, allocator: Allocator, actor_id: []const u8, scopes_json: []const u8) ![]i64 {
        var ids_out: std.ArrayListUnmanaged(i64) = .empty;
        errdefer ids_out.deinit(allocator);
        switch (self) {
            .runtime => |runtime| {
                var status = try runtime.feedStatusByInput(allocator, .{ .actor_id = actor_id, .scopes_json = scopes_json });
                defer status.deinit(allocator);
                const events = try runtime.listFeedEventsByInput(allocator, .{ .since_id = 0, .limit = 100, .actor_id = actor_id, .scopes_json = scopes_json });
                defer {
                    for (events) |*event| event.deinit(allocator);
                    allocator.free(events);
                }
                try std.testing.expect(status.max_event_id >= if (events.len == 0) 0 else events[events.len - 1].id);
                for (events) |event| try ids_out.append(allocator, event.id);
            },
            .store => |ctx| {
                const status = try ctx.value.feedStatus(allocator, .{ .actor_id = actor_id, .scopes_json = scopes_json });
                const events = try ctx.value.listFeedEvents(allocator, .{ .since_id = 0, .limit = 100, .actor_id = actor_id, .scopes_json = scopes_json });
                defer store_feed.freeFeedEvents(allocator, events);
                try std.testing.expect(status.max_event_id >= if (events.len == 0) 0 else events[events.len - 1].id);
                for (events) |event| try ids_out.append(allocator, event.id);
            },
        }
        return ids_out.toOwnedSlice(allocator);
    }
};

fn toRuntimeOrder(order: ?Order) ?agent_memory_runtime.EventOrder {
    const value = order orelse return null;
    return .{ .timestamp_ms = value.timestamp_ms, .origin_instance_id = value.origin_instance_id, .origin_sequence = value.origin_sequence };
}

fn toStoreOrder(order: ?Order) ?store_agent_memory.EventOrder {
    const value = order orelse return null;
    return .{ .timestamp_ms = value.timestamp_ms, .origin_instance_id = value.origin_instance_id, .origin_sequence = value.origin_sequence };
}

fn freeOptionalAgentMemory(allocator: Allocator, entry: ?domain.AgentMemory) void {
    if (entry) |value| {
        var copy = value;
        agent_memory_runtime.freeAgentMemory(allocator, &copy);
    }
}

fn freeAgentMemorySlice(allocator: Allocator, entries: []domain.AgentMemory) void {
    for (entries) |*entry| agent_memory_runtime.freeAgentMemory(allocator, entry);
    allocator.free(entries);
}

fn expectNoEntry(allocator: Allocator, entry: ?domain.AgentMemory) !void {
    if (entry) |value| {
        var copy = value;
        defer agent_memory_runtime.freeAgentMemory(allocator, &copy);
        return error.TestExpectedEqual;
    }
}

fn expectContainsKey(entries: []const domain.AgentMemory, key: []const u8) !void {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.key, key)) return;
    }
    return error.TestExpectedEqual;
}

fn expectIncreasingIds(ids_slice: []const i64) !void {
    try std.testing.expect(ids_slice.len >= 2);
    for (ids_slice[1..], 1..) |id, index| {
        try std.testing.expect(id > ids_slice[index - 1]);
    }
}

fn runAgentMemoryBackendContract(backend: ContractBackend) !void {
    const allocator = std.testing.allocator;
    const actor_a = "agent:contract-a";
    const actor_b = "agent:contract-b";
    const team_scopes = "[\"team:contract\"]";

    var private_a = try backend.put(allocator, .{ .key = "contract.pref", .content = "needle private a", .actor_id = actor_a });
    defer agent_memory_runtime.freeAgentMemory(allocator, &private_a);
    var private_b = try backend.put(allocator, .{ .key = "contract.pref", .content = "needle private b", .actor_id = actor_b });
    defer agent_memory_runtime.freeAgentMemory(allocator, &private_b);
    var session_a = try backend.put(allocator, .{ .key = "contract.session", .content = "session only", .session_id = "sess-contract", .actor_id = actor_a });
    defer agent_memory_runtime.freeAgentMemory(allocator, &session_a);
    var shared = try backend.put(allocator, .{ .key = "contract.shared", .content = "team visible", .scope = "team:contract", .actor_id = actor_a });
    defer agent_memory_runtime.freeAgentMemory(allocator, &shared);

    var exact_a = (try backend.get(allocator, "contract.pref", null, actor_a, "[]", .exact_owner)).?;
    defer agent_memory_runtime.freeAgentMemory(allocator, &exact_a);
    try std.testing.expectEqualStrings("needle private a", exact_a.content);
    try expectNoEntry(allocator, try backend.get(allocator, "contract.shared", null, actor_b, "[]", .visible));
    var team_visible = (try backend.get(allocator, "contract.shared", null, actor_b, team_scopes, .visible)).?;
    defer agent_memory_runtime.freeAgentMemory(allocator, &team_visible);
    try std.testing.expectEqualStrings("team visible", team_visible.content);

    try expectNoEntry(allocator, try backend.get(allocator, "contract.session", null, actor_a, "[]", .exact_owner));
    var session_exact = (try backend.get(allocator, "contract.session", "sess-contract", actor_a, "[]", .exact_owner)).?;
    defer agent_memory_runtime.freeAgentMemory(allocator, &session_exact);
    try std.testing.expectEqualStrings("session only", session_exact.content);

    const listed = try backend.list(allocator, "contract", null, actor_a, team_scopes, .any_visible, 10, 0);
    defer freeAgentMemorySlice(allocator, listed);
    try expectContainsKey(listed, "contract.pref");
    try expectContainsKey(listed, "contract.shared");

    const searched = try backend.search(allocator, "needle", null, actor_a, "[]", .visible, 10);
    defer freeAgentMemorySlice(allocator, searched);
    try std.testing.expectEqual(@as(usize, 1), searched.len);
    try std.testing.expectEqualStrings("contract.pref", searched[0].key);
    try std.testing.expectEqualStrings("needle private a", searched[0].content);
    try std.testing.expect(try backend.count(actor_a, team_scopes) >= 2);

    try std.testing.expect(try backend.delete("contract.pref", null, actor_a, actor_a, null));
    try expectNoEntry(allocator, try backend.get(allocator, "contract.pref", null, actor_a, "[]", .exact_owner));
    var still_b = (try backend.get(allocator, "contract.pref", null, actor_b, "[]", .exact_owner)).?;
    defer agent_memory_runtime.freeAgentMemory(allocator, &still_b);
    try std.testing.expectEqualStrings("needle private b", still_b.content);

    var ordered = try backend.put(allocator, .{
        .key = "contract.ordered",
        .content = "{\"version\":\"one\"}",
        .actor_id = actor_a,
        .operation = .merge_object,
        .event_order = .{ .timestamp_ms = 100, .origin_instance_id = "contract-local", .origin_sequence = 1 },
    });
    defer agent_memory_runtime.freeAgentMemory(allocator, &ordered);
    try std.testing.expect(try backend.delete("contract.ordered", null, actor_a, actor_a, .{ .timestamp_ms = 200, .origin_instance_id = "contract-local", .origin_sequence = 2 }));
    var stale = try backend.put(allocator, .{
        .key = "contract.ordered",
        .content = "stale replay",
        .actor_id = actor_a,
        .event_order = .{ .timestamp_ms = 150, .origin_instance_id = "contract-local", .origin_sequence = 3 },
    });
    defer agent_memory_runtime.freeAgentMemory(allocator, &stale);
    try expectNoEntry(allocator, try backend.get(allocator, "contract.ordered", null, actor_a, "[]", .exact_owner));
    var fresh = try backend.put(allocator, .{
        .key = "contract.ordered",
        .content = "fresh replay",
        .actor_id = actor_a,
        .event_order = .{ .timestamp_ms = 300, .origin_instance_id = "contract-local", .origin_sequence = 4 },
    });
    defer agent_memory_runtime.freeAgentMemory(allocator, &fresh);
    var fresh_read = (try backend.get(allocator, "contract.ordered", null, actor_a, "[]", .exact_owner)).?;
    defer agent_memory_runtime.freeAgentMemory(allocator, &fresh_read);
    try std.testing.expectEqualStrings("fresh replay", fresh_read.content);

    try backend.applyRemotePut(allocator, "contract.replayed", "remote feed replay", actor_a, .{
        .timestamp_ms = 900,
        .origin_instance_id = "contract-remote",
        .origin_sequence = 9,
    });
    var replayed = (try backend.get(allocator, "contract.replayed", null, actor_a, "[\"public\"]", .visible)).?;
    defer agent_memory_runtime.freeAgentMemory(allocator, &replayed);
    try std.testing.expectEqualStrings("remote feed replay", replayed.content);

    const feed_ids = try backend.feedIds(allocator, actor_a, "[\"public\",\"team:contract\",\"agent:agent:contract-a\",\"session:sess-contract\"]");
    defer allocator.free(feed_ids);
    try expectIncreasingIds(feed_ids);
}

test "agent memory backend contract covers memory_lru runtime and native sqlite" {
    var runtime = try Runtime.init(std.testing.allocator, .{ .backend = .memory_lru });
    defer runtime.deinit();
    try runAgentMemoryBackendContract(.{ .runtime = &runtime });

    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    try runAgentMemoryBackendContract(.{ .store = .{ .value = &store, .route = .{ .target = .native } } });
}

test "agent memory backend contract covers redis runtime when configured" {
    if (!build_options.enable_engine_redis) return error.SkipZigTest;
    const url = compat.process.getEnvVarOwned(std.testing.allocator, "NULLPANTRY_TEST_REDIS_URL") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer std.testing.allocator.free(url);

    var cfg = try redis_config.parseUrl(std.testing.allocator, url);
    defer {
        std.testing.allocator.free(cfg.host);
        if (cfg.password) |password| std.testing.allocator.free(password);
    }
    cfg.key_prefix = try std.fmt.allocPrint(std.testing.allocator, "np-contract:{d}", .{ids.nowMs()});
    defer std.testing.allocator.free(cfg.key_prefix);
    cfg.ttl_seconds = 60;

    var runtime = try Runtime.init(std.testing.allocator, .{ .backend = .redis, .redis = cfg });
    defer runtime.deinit();
    try runAgentMemoryBackendContract(.{ .runtime = &runtime });
}

test "agent memory backend contract covers clickhouse runtime when configured" {
    if (!build_options.enable_engine_clickhouse) return error.SkipZigTest;
    const base_url = compat.process.getEnvVarOwned(std.testing.allocator, "NULLPANTRY_TEST_CLICKHOUSE_URL") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer std.testing.allocator.free(base_url);

    const table = try ids.make(std.testing.allocator, "np_agent_memory_contract_common_");
    defer std.testing.allocator.free(table);
    var runtime = try Runtime.init(std.testing.allocator, .{
        .backend = .clickhouse,
        .clickhouse = .{ .base_url = base_url, .table = table, .timeout_secs = 10 },
    });
    defer runtime.deinit();
    try runAgentMemoryBackendContract(.{ .runtime = &runtime });
}
