const std = @import("std");

pub const EngineKind = enum {
    none,
    sqlite,
    markdown,
    memory_lru,
    lucid,
    postgres,
    redis,
    clickhouse,
    qdrant,
    lancedb,
    kg,

    pub fn name(self: EngineKind) []const u8 {
        return switch (self) {
            .none => "none",
            .sqlite => "sqlite",
            .markdown => "markdown",
            .memory_lru => "memory_lru",
            .lucid => "lucid",
            .postgres => "postgres",
            .redis => "redis",
            .clickhouse => "clickhouse",
            .qdrant => "qdrant",
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
    .{ .kind = .none, .role = "disabled memory plane", .durability = "none", .planes_json = "[\"agent_memory\",\"session\",\"usage\"]", .primary_for = "agent_memory,session,usage", .nullpantry_strategy = "explicit no-op runtime plane for parity with NullClaw none mode and controlled memory-disabled deployments", .nullclaw_boundary = "NullClaw baseline disabled memory mode; NullPantry can expose the same mode centrally", .runtime_supported = true, .remote_primary_supported = false },
    .{ .kind = .sqlite, .role = "local-dev relational memory", .durability = "durable", .planes_json = "[\"record\",\"agent_memory\",\"session\",\"vector\",\"cache\",\"lifecycle\",\"feed\"]", .primary_for = "record,agent_memory,session,vector,cache,lifecycle,feed", .nullpantry_strategy = "native SQLite service backend with FTS5 and local vector search", .nullclaw_boundary = "NullClaw baseline local engine; NullPantry local/dev system-of-record", .runtime_supported = true, .remote_primary_supported = true },
    .{ .kind = .markdown, .role = "filesystem knowledge documents", .durability = "filesystem", .planes_json = "[\"record\",\"filesystem\",\"import_export\",\"snapshot\"]", .primary_for = "source,artifact,filesystem_import_export", .nullpantry_strategy = "recursive Markdown directory import/export with frontmatter, path identity, permissions, checksum metadata, and source/artifact projection", .nullclaw_boundary = "NullClaw baseline local file engine can be replaced by NullPantry Markdown filesystem ingestion for shared knowledge documents", .runtime_supported = true, .remote_primary_supported = false },
    .{ .kind = .memory_lru, .role = "ephemeral process memory", .durability = "ephemeral", .planes_json = "[\"agent_memory\",\"session\",\"usage\",\"cache\",\"test\"]", .primary_for = "agent_memory,session,usage,cache,test", .nullpantry_strategy = "in-process runtime plane for tests, single-process agents, and named scratch stores; not durable shared memory", .nullclaw_boundary = "NullClaw baseline in-process engine; NullPantry can expose it centrally for parity and scratch stores", .runtime_supported = true, .remote_primary_supported = false },
    .{ .kind = .lucid, .role = "local semantic memory projection", .durability = "durable", .planes_json = "[\"projection\",\"semantic_context\"]", .primary_for = "projection", .nullpantry_strategy = "optional Lucid CLI projection adapter backed by durable projection jobs, lifecycle retractions, status, and rebuild; NullPantry remains source of truth and ACL gate", .nullclaw_boundary = "advanced semantic memory projection belongs in NullPantry, not NullClaw core", .runtime_supported = true, .remote_primary_supported = false },
    .{ .kind = .postgres, .role = "durable relational memory target", .durability = "durable", .planes_json = "[\"record\",\"agent_memory\",\"session\",\"vector\",\"cache\",\"lifecycle\",\"feed\"]", .primary_for = "record,agent_memory,session,vector,cache,lifecycle,feed", .nullpantry_strategy = "native libpq runtime adapter with pgvector schema", .nullclaw_boundary = "shared durable memory belongs in NullPantry service", .runtime_supported = true, .remote_primary_supported = true },
    .{ .kind = .redis, .role = "low-latency shared agent memory", .durability = "configurable", .planes_json = "[\"agent_memory\",\"session\",\"usage\"]", .primary_for = "agent_memory,session,usage", .nullpantry_strategy = "native RESP runtime backend for shared/isolated agent memory and sessions", .nullclaw_boundary = "shared remote agent memory belongs in NullPantry service", .runtime_supported = true, .remote_primary_supported = true },
    .{ .kind = .clickhouse, .role = "analytics and high-volume history", .durability = "durable", .planes_json = "[\"analytics\",\"audit_export\",\"event_history\"]", .primary_for = "analytics,audit_export", .nullpantry_strategy = "native ClickHouse HTTP runtime adapter for audit/feed event export", .nullclaw_boundary = "analytics/history belongs in NullPantry service", .runtime_supported = true, .remote_primary_supported = true },
    .{ .kind = .qdrant, .role = "ANN vector database", .durability = "durable", .planes_json = "[\"vector\"]", .primary_for = "vector", .nullpantry_strategy = "native Qdrant HTTP runtime adapter for vector upsert/search/delete/reset plus canonical reconcile/rebuild through NullPantry", .nullclaw_boundary = "ANN/vector index belongs in NullPantry service", .runtime_supported = true, .remote_primary_supported = true },
    .{ .kind = .lancedb, .role = "ANN vector database", .durability = "durable", .planes_json = "[\"vector\"]", .primary_for = "vector", .nullpantry_strategy = "native LanceDB SDK runtime adapter for vector upsert/search/delete/reset plus canonical reconcile/rebuild, with explicit lancedb_http compatibility mode for adapter services", .nullclaw_boundary = "ANN/vector index belongs in NullPantry service", .runtime_supported = true, .remote_primary_supported = true },
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
    try std.testing.expect(parse("none") == .none);
    try std.testing.expect(parse("sqlite") == .sqlite);
    try std.testing.expect(parse("markdown") == .markdown);
    try std.testing.expect(parse("memory_lru") == .memory_lru);
    try std.testing.expect(parse("lucid") == .lucid);
    try std.testing.expect(parse("postgres") == .postgres);
    try std.testing.expect(parse("redis") == .redis);
    try std.testing.expect(parse("clickhouse") == .clickhouse);
    try std.testing.expect(parse("qdrant") == .qdrant);
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

test "advanced external planes are advertised only after runtime wiring" {
    try std.testing.expect(descriptors[@intFromEnum(EngineKind.lucid)].runtime_supported);
    try std.testing.expect(descriptors[@intFromEnum(EngineKind.clickhouse)].runtime_supported);
    try std.testing.expect(descriptors[@intFromEnum(EngineKind.qdrant)].runtime_supported);
    try std.testing.expect(descriptors[@intFromEnum(EngineKind.lancedb)].runtime_supported);
}
