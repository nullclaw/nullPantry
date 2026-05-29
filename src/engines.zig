const std = @import("std");

pub const EngineKind = enum {
    sqlite,
    markdown,
    memory_lru,
    lucid,
    postgres,
    redis,
    clickhouse,
    lancedb,
    kg,

    pub fn name(self: EngineKind) []const u8 {
        return switch (self) {
            .sqlite => "sqlite",
            .markdown => "markdown",
            .memory_lru => "memory_lru",
            .lucid => "lucid",
            .postgres => "postgres",
            .redis => "redis",
            .clickhouse => "clickhouse",
            .lancedb => "lancedb",
            .kg => "kg",
        };
    }
};

pub const EngineDescriptor = struct {
    kind: EngineKind,
    role: []const u8,
    durability: []const u8,
    planes_json: []const u8,
    primary_for: []const u8,
    nullpantry_strategy: []const u8,
    nullclaw_boundary: []const u8,
    runtime_supported: bool,
    remote_primary_supported: bool,
};

pub const descriptors = [_]EngineDescriptor{
    .{ .kind = .sqlite, .role = "local-dev relational memory", .durability = "durable", .planes_json = "[\"record\",\"agent_memory\",\"session\",\"vector\",\"cache\",\"lifecycle\",\"feed\"]", .primary_for = "record,agent_memory,session,vector,cache,lifecycle,feed", .nullpantry_strategy = "native SQLite service backend with FTS5 and local vector search", .nullclaw_boundary = "NullClaw baseline local engine; NullPantry local/dev system-of-record", .runtime_supported = true, .remote_primary_supported = true },
    .{ .kind = .markdown, .role = "workspace bootstrap files", .durability = "filesystem", .planes_json = "[\"import_export\",\"snapshot\"]", .primary_for = "import_export", .nullpantry_strategy = "source/artifact import-export adapter for bootstrap and snapshots", .nullclaw_boundary = "NullClaw baseline local file engine; NullPantry import/export plane", .runtime_supported = true, .remote_primary_supported = false },
    .{ .kind = .memory_lru, .role = "ephemeral process memory", .durability = "ephemeral", .planes_json = "[\"cache\",\"test\"]", .primary_for = "cache,test", .nullpantry_strategy = "in-process cache/test plane; not used as durable shared memory", .nullclaw_boundary = "NullClaw baseline in-process engine; NullPantry cache/test plane only", .runtime_supported = true, .remote_primary_supported = false },
    .{ .kind = .lucid, .role = "local semantic memory projection", .durability = "durable", .planes_json = "[\"projection\",\"vector\"]", .primary_for = "projection", .nullpantry_strategy = "projection plane is modeled, but no concrete NullPantry runtime adapter is wired yet", .nullclaw_boundary = "advanced semantic memory belongs in NullPantry, not NullClaw core", .runtime_supported = false, .remote_primary_supported = false },
    .{ .kind = .postgres, .role = "durable relational memory target", .durability = "durable", .planes_json = "[\"record\",\"agent_memory\",\"session\",\"vector\",\"cache\",\"lifecycle\",\"feed\"]", .primary_for = "record,agent_memory,session,vector,cache,lifecycle,feed", .nullpantry_strategy = "native libpq runtime adapter with pgvector schema", .nullclaw_boundary = "shared durable memory belongs in NullPantry service", .runtime_supported = true, .remote_primary_supported = true },
    .{ .kind = .redis, .role = "low-latency shared agent memory", .durability = "configurable", .planes_json = "[\"agent_memory\",\"session\",\"usage\"]", .primary_for = "agent_memory,session,usage", .nullpantry_strategy = "native RESP runtime backend for shared/isolated agent memory and sessions", .nullclaw_boundary = "shared remote agent memory belongs in NullPantry service", .runtime_supported = true, .remote_primary_supported = true },
    .{ .kind = .clickhouse, .role = "analytics and high-volume history", .durability = "durable", .planes_json = "[\"analytics\",\"audit_export\",\"event_history\"]", .primary_for = "analytics,audit_export", .nullpantry_strategy = "analytics/export plane is modeled, but no concrete ClickHouse runtime adapter is wired yet", .nullclaw_boundary = "analytics/history belongs in NullPantry service", .runtime_supported = false, .remote_primary_supported = false },
    .{ .kind = .lancedb, .role = "ANN vector database", .durability = "durable", .planes_json = "[\"vector\"]", .primary_for = "vector", .nullpantry_strategy = "vector plane is modeled through vector outbox, but no concrete LanceDB runtime adapter is wired yet", .nullclaw_boundary = "ANN/vector index belongs in NullPantry service", .runtime_supported = false, .remote_primary_supported = false },
    .{ .kind = .kg, .role = "knowledge graph memory", .durability = "durable", .planes_json = "[\"graph\",\"retrieval_expansion\"]", .primary_for = "graph,retrieval_expansion", .nullpantry_strategy = "entity/relation graph native model", .nullclaw_boundary = "knowledge graph belongs in NullPantry service", .runtime_supported = true, .remote_primary_supported = true },
};

pub fn parse(name: []const u8) ?EngineKind {
    for (descriptors) |descriptor| {
        if (std.mem.eql(u8, descriptor.kind.name(), name)) return descriptor.kind;
    }
    return null;
}

pub fn appendDescriptorsJson(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    try out.append(allocator, '[');
    for (descriptors, 0..) |descriptor, i| {
        if (i > 0) try out.append(allocator, ',');
        try out.print(
            allocator,
            "{{\"name\":\"{s}\",\"role\":\"{s}\",\"durability\":\"{s}\",\"planes\":{s},\"primary_for\":\"{s}\",\"nullpantry_strategy\":\"{s}\",\"nullclaw_boundary\":\"{s}\",\"runtime_supported\":{s},\"remote_primary_supported\":{s}}}",
            .{
                descriptor.kind.name(),
                descriptor.role,
                descriptor.durability,
                descriptor.planes_json,
                descriptor.primary_for,
                descriptor.nullpantry_strategy,
                descriptor.nullclaw_boundary,
                if (descriptor.runtime_supported) "true" else "false",
                if (descriptor.remote_primary_supported) "true" else "false",
            },
        );
    }
    try out.append(allocator, ']');
}

test "engine registry includes storage and adapter contracts" {
    try std.testing.expect(parse("sqlite") == .sqlite);
    try std.testing.expect(parse("markdown") == .markdown);
    try std.testing.expect(parse("memory_lru") == .memory_lru);
    try std.testing.expect(parse("lucid") == .lucid);
    try std.testing.expect(parse("postgres") == .postgres);
    try std.testing.expect(parse("redis") == .redis);
    try std.testing.expect(parse("clickhouse") == .clickhouse);
    try std.testing.expect(parse("lancedb") == .lancedb);
    try std.testing.expect(parse("kg") == .kg);
    try std.testing.expect(parse("unknown") == null);
}

test "redis is a real remote agent memory plane" {
    const redis_descriptor = descriptors[@intFromEnum(EngineKind.redis)];
    try std.testing.expect(redis_descriptor.runtime_supported);
    try std.testing.expect(redis_descriptor.remote_primary_supported);
    try std.testing.expect(std.mem.indexOf(u8, redis_descriptor.planes_json, "agent_memory") != null);
    try std.testing.expect(std.mem.indexOf(u8, redis_descriptor.nullpantry_strategy, "RESP") != null);
    try std.testing.expect(std.mem.indexOf(u8, redis_descriptor.nullclaw_boundary, "NullPantry") != null);
}

test "unwired external planes are not advertised as runtime backends" {
    try std.testing.expect(!descriptors[@intFromEnum(EngineKind.lucid)].runtime_supported);
    try std.testing.expect(!descriptors[@intFromEnum(EngineKind.clickhouse)].runtime_supported);
    try std.testing.expect(!descriptors[@intFromEnum(EngineKind.lancedb)].runtime_supported);
}
