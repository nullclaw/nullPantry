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
    nullpantry_strategy: []const u8,
    remote_primary_supported: bool,
};

pub const descriptors = [_]EngineDescriptor{
    .{ .kind = .sqlite, .role = "local-dev relational memory", .durability = "durable", .nullpantry_strategy = "native sqlite backend", .remote_primary_supported = true },
    .{ .kind = .markdown, .role = "workspace bootstrap files", .durability = "filesystem", .nullpantry_strategy = "source/artifact import-export adapter", .remote_primary_supported = false },
    .{ .kind = .memory_lru, .role = "ephemeral process memory", .durability = "ephemeral", .nullpantry_strategy = "in-memory cache and tests only", .remote_primary_supported = false },
    .{ .kind = .lucid, .role = "local semantic memory engine", .durability = "durable", .nullpantry_strategy = "vector-capable projection adapter contract", .remote_primary_supported = false },
    .{ .kind = .postgres, .role = "production relational memory target", .durability = "durable", .nullpantry_strategy = "psql-backed runtime adapter with pgvector schema; native client can replace transport later", .remote_primary_supported = true },
    .{ .kind = .redis, .role = "low-latency network memory", .durability = "configurable", .nullpantry_strategy = "external cache/backend adapter contract", .remote_primary_supported = false },
    .{ .kind = .clickhouse, .role = "analytics and high-volume history", .durability = "durable", .nullpantry_strategy = "event/audit export target contract", .remote_primary_supported = false },
    .{ .kind = .lancedb, .role = "local ANN vector database", .durability = "durable", .nullpantry_strategy = "vector index adapter contract", .remote_primary_supported = false },
    .{ .kind = .kg, .role = "knowledge graph memory", .durability = "durable", .nullpantry_strategy = "entity/relation graph native model", .remote_primary_supported = true },
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
            "{{\"name\":\"{s}\",\"role\":\"{s}\",\"durability\":\"{s}\",\"nullpantry_strategy\":\"{s}\",\"remote_primary_supported\":{s}}}",
            .{
                descriptor.kind.name(),
                descriptor.role,
                descriptor.durability,
                descriptor.nullpantry_strategy,
                if (descriptor.remote_primary_supported) "true" else "false",
            },
        );
    }
    try out.append(allocator, ']');
}

test "engine registry includes NullClaw memory engines" {
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
