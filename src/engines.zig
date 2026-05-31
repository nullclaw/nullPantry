const std = @import("std");

pub const EngineKind = enum {
    none,
    sqlite,
    markdown,
    hybrid,
    qmd,
    memory_lru,
    lucid,
    postgres,
    pgvector,
    redis,
    api,
    clickhouse,
    qdrant,
    lancedb,
    kg,

    pub fn name(self: EngineKind) []const u8 {
        return switch (self) {
            .none => "none",
            .sqlite => "sqlite",
            .markdown => "markdown",
            .hybrid => "hybrid",
            .qmd => "qmd",
            .memory_lru => "memory_lru",
            .lucid => "lucid",
            .postgres => "postgres",
            .pgvector => "pgvector",
            .redis => "redis",
            .api => "api",
            .clickhouse => "clickhouse",
            .qdrant => "qdrant",
            .lancedb => "lancedb",
            .kg => "kg",
        };
    }

    pub fn nullclawEngineToken(self: EngineKind) []const u8 {
        return switch (self) {
            .hybrid => "sqlite",
            .memory_lru => "memory",
            else => self.name(),
        };
    }
};

pub const EngineCapabilities = struct {
    keyword_rank: bool = false,
    session_store: bool = false,
    transactions: bool = false,
    outbox: bool = false,
};

pub const EngineRequirements = struct {
    db_path: bool = false,
    workspace: bool = false,
};

pub const EngineDescriptor = struct {
    kind: EngineKind,
    role: []const u8,
    durability: []const u8,
    planes_json: []const u8,
    primary_for: []const u8,
    nullpantry_strategy: []const u8,
    nullclaw_boundary: []const u8,
    aliases_json: []const u8 = "[]",
    auto_save_default: bool = false,
    capabilities: EngineCapabilities = .{},
    requirements: EngineRequirements = .{},
    runtime_supported: bool = true,
    remote_primary_supported: bool = false,

    pub fn nullclawEngineToken(self: EngineDescriptor) []const u8 {
        return self.kind.nullclawEngineToken();
    }
};

pub const descriptors = [_]EngineDescriptor{
    .{ .kind = .none, .role = "disabled memory plane", .durability = "none", .planes_json = "[\"agent_memory\",\"session\",\"usage\"]", .primary_for = "agent_memory,session,usage", .nullpantry_strategy = "explicit no-op runtime plane for parity with NullClaw none mode and controlled memory-disabled deployments", .nullclaw_boundary = "NullClaw baseline disabled memory mode; NullPantry can expose the same mode centrally" },
    .{ .kind = .sqlite, .role = "local-dev relational memory", .durability = "durable", .planes_json = "[\"record\",\"agent_memory\",\"session\",\"vector\",\"cache\",\"lifecycle\",\"feed\"]", .primary_for = "record,agent_memory,session,vector,cache,lifecycle,feed", .nullpantry_strategy = "native SQLite service backend with FTS5 and local vector search", .nullclaw_boundary = "NullClaw baseline local engine; NullPantry local/dev system-of-record", .auto_save_default = true, .capabilities = .{ .keyword_rank = true, .session_store = true, .transactions = true, .outbox = true }, .requirements = .{ .db_path = true }, .remote_primary_supported = true },
    .{ .kind = .markdown, .role = "filesystem knowledge documents", .durability = "filesystem", .planes_json = "[\"record\",\"filesystem\",\"import_export\",\"snapshot\"]", .primary_for = "source,artifact,filesystem_import_export", .nullpantry_strategy = "recursive Markdown directory import/export with frontmatter, path identity, permissions, checksum metadata, and source/artifact projection", .nullclaw_boundary = "NullClaw baseline local file engine can be replaced by NullPantry Markdown filesystem ingestion for shared knowledge documents", .auto_save_default = true, .requirements = .{ .workspace = true } },
    .{ .kind = .hybrid, .role = "SQLite plus governed Markdown projection", .durability = "durable+filesystem", .planes_json = "[\"record\",\"agent_memory\",\"session\",\"vector\",\"filesystem\",\"import_export\",\"feed\"]", .primary_for = "record,agent_memory,session,markdown_import_export", .nullpantry_strategy = "composition of native SQLite/Postgres canonical storage plus Markdown import/export jobs; NullPantry keeps ACL/provenance/indexing as source of truth instead of treating Markdown as a second ungoverned primary", .nullclaw_boundary = "NullClaw hybrid backend maps to NullPantry native record storage with governed Markdown filesystem ingestion/export", .aliases_json = "[\"sqlite_markdown\"]", .auto_save_default = true, .capabilities = .{ .keyword_rank = true, .session_store = true, .transactions = true, .outbox = true }, .requirements = .{ .db_path = true, .workspace = true }, .remote_primary_supported = true },
    .{ .kind = .qmd, .role = "QMD-compatible markdown/session result ingestion and export", .durability = "canonicalized", .planes_json = "[\"connector\",\"retrieval_source\",\"import_export\"]", .primary_for = "qmd_search_results,agent_session_exports,markdown_corpus", .nullpantry_strategy = "normalize qmd JSON results into canonical Sources and export permission-checked agent sessions into a QMD markdown corpus with provenance, ACL, extraction, vectors, feed, and lifecycle instead of serving them as an ungoverned sidecar", .nullclaw_boundary = "NullClaw QMD retrieval and session export move to NullPantry connectors so agents query governed central knowledge" },
    .{ .kind = .memory_lru, .role = "ephemeral process memory", .durability = "ephemeral", .planes_json = "[\"agent_memory\",\"session\",\"usage\",\"cache\",\"test\"]", .primary_for = "agent_memory,session,usage,cache,test", .nullpantry_strategy = "in-process runtime plane for tests, single-process agents, and named scratch stores; not durable shared memory", .nullclaw_boundary = "NullClaw baseline in-process engine; NullPantry can expose it centrally for parity and scratch stores", .aliases_json = "[\"memory\",\"in_memory\"]", .capabilities = .{ .session_store = true } },
    .{ .kind = .lucid, .role = "local semantic memory projection", .durability = "durable", .planes_json = "[\"projection\",\"semantic_context\"]", .primary_for = "projection", .nullpantry_strategy = "optional Lucid CLI projection adapter backed by durable projection jobs, lifecycle retractions, status, and rebuild; NullPantry remains source of truth and ACL gate", .nullclaw_boundary = "advanced semantic memory projection belongs in NullPantry, not NullClaw core", .auto_save_default = true, .capabilities = .{ .keyword_rank = true, .session_store = true, .transactions = true, .outbox = true }, .requirements = .{ .db_path = true, .workspace = true } },
    .{ .kind = .postgres, .role = "durable relational memory target", .durability = "durable", .planes_json = "[\"record\",\"agent_memory\",\"session\",\"cache\",\"lifecycle\",\"feed\"]", .primary_for = "record,agent_memory,session,cache,lifecycle,feed", .nullpantry_strategy = "native libpq runtime adapter for canonical primitives, lifecycle, cache, feed, jobs, sessions, and agent memory", .nullclaw_boundary = "shared durable memory belongs in NullPantry service", .auto_save_default = true, .capabilities = .{ .keyword_rank = true, .session_store = true, .transactions = true, .outbox = true }, .remote_primary_supported = true },
    .{ .kind = .pgvector, .role = "Postgres-coupled vector index", .durability = "durable", .planes_json = "[\"vector\",\"record_coupled\"]", .primary_for = "vector", .nullpantry_strategy = "pgvector-backed vector chunks inside the Postgres system-of-record backend with dynamic dimensions, ACL hydration, reconcile, rebuild, and retrieval fallback through NullPantry", .nullclaw_boundary = "pgvector/vector database complexity belongs in NullPantry service, not NullClaw core", .capabilities = .{ .outbox = true }, .remote_primary_supported = true },
    .{ .kind = .redis, .role = "low-latency shared agent memory", .durability = "configurable", .planes_json = "[\"agent_memory\",\"session\",\"usage\"]", .primary_for = "agent_memory,session,usage", .nullpantry_strategy = "native RESP runtime backend for shared/isolated agent memory and sessions", .nullclaw_boundary = "shared remote agent memory belongs in NullPantry service", .auto_save_default = true, .capabilities = .{ .session_store = true, .transactions = true }, .remote_primary_supported = true },
    .{ .kind = .api, .role = "remote NullPantry-compatible agent memory API", .durability = "remote", .planes_json = "[\"agent_memory\",\"session\",\"usage\",\"feed\"]", .primary_for = "agent_memory,session,usage,feed", .nullpantry_strategy = "HTTP runtime backend that proxies agent memory, sessions, usage, and deterministic feed peer operations to another NullPantry-compatible /v1 API with actor/scope/capability forwarding", .nullclaw_boundary = "remote agent memory belongs behind NullPantry API rather than NullClaw core", .auto_save_default = true, .capabilities = .{ .session_store = true }, .remote_primary_supported = true },
    .{ .kind = .clickhouse, .role = "analytics and high-volume history", .durability = "durable", .planes_json = "[\"analytics\",\"audit_export\",\"event_history\"]", .primary_for = "analytics,audit_export", .nullpantry_strategy = "native ClickHouse HTTP runtime adapter for audit/feed event export", .nullclaw_boundary = "analytics/history belongs in NullPantry service", .remote_primary_supported = true },
    .{ .kind = .qdrant, .role = "ANN vector database", .durability = "durable", .planes_json = "[\"vector\"]", .primary_for = "vector", .nullpantry_strategy = "native Qdrant HTTP runtime adapter for vector upsert/search/delete/reset plus canonical reconcile/rebuild through NullPantry", .nullclaw_boundary = "ANN/vector index belongs in NullPantry service", .capabilities = .{ .outbox = true }, .remote_primary_supported = true },
    .{ .kind = .lancedb, .role = "ANN vector database", .durability = "durable", .planes_json = "[\"vector\"]", .primary_for = "vector", .nullpantry_strategy = "native LanceDB SDK runtime adapter for vector upsert/search/delete/reset plus canonical reconcile/rebuild, with explicit lancedb_http compatibility mode for adapter services", .nullclaw_boundary = "ANN/vector index belongs in NullPantry service", .capabilities = .{ .outbox = true }, .remote_primary_supported = true },
    .{ .kind = .kg, .role = "knowledge graph memory", .durability = "durable", .planes_json = "[\"graph\",\"retrieval_expansion\"]", .primary_for = "graph,retrieval_expansion", .nullpantry_strategy = "entity/relation graph native model", .nullclaw_boundary = "knowledge graph belongs in NullPantry service", .capabilities = .{ .keyword_rank = true, .transactions = true }, .remote_primary_supported = true },
};

pub fn parse(name: []const u8) ?EngineKind {
    if (std.mem.eql(u8, name, "memory") or std.mem.eql(u8, name, "in_memory")) return .memory_lru;
    if (std.mem.eql(u8, name, "sqlite_markdown")) return .hybrid;
    for (descriptors) |descriptor| {
        if (std.mem.eql(u8, descriptor.kind.name(), name)) return descriptor.kind;
    }
    return null;
}

pub fn nullclawEngineTokenForName(name: []const u8) ?[]const u8 {
    const kind = parse(name) orelse return null;
    return kind.nullclawEngineToken();
}

pub fn appendDescriptorsJson(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    try out.append(allocator, '[');
    for (descriptors, 0..) |descriptor, i| {
        if (i > 0) try out.append(allocator, ',');
        try out.print(
            allocator,
            "{{\"name\":\"{s}\",\"aliases\":{s},\"nullclaw_engine_token\":\"{s}\",\"role\":\"{s}\",\"durability\":\"{s}\",\"planes\":{s},\"primary_for\":\"{s}\",\"nullpantry_strategy\":\"{s}\",\"nullclaw_boundary\":\"{s}\",\"auto_save_default\":{s},\"capabilities\":{{\"keyword_rank\":{s},\"session_store\":{s},\"transactions\":{s},\"outbox\":{s}}},\"requirements\":{{\"db_path\":{s},\"workspace\":{s}}},\"runtime_supported\":{s},\"remote_primary_supported\":{s}}}",
            .{
                descriptor.kind.name(),
                descriptor.aliases_json,
                descriptor.nullclawEngineToken(),
                descriptor.role,
                descriptor.durability,
                descriptor.planes_json,
                descriptor.primary_for,
                descriptor.nullpantry_strategy,
                descriptor.nullclaw_boundary,
                jsonBool(descriptor.auto_save_default),
                jsonBool(descriptor.capabilities.keyword_rank),
                jsonBool(descriptor.capabilities.session_store),
                jsonBool(descriptor.capabilities.transactions),
                jsonBool(descriptor.capabilities.outbox),
                jsonBool(descriptor.requirements.db_path),
                jsonBool(descriptor.requirements.workspace),
                jsonBool(descriptor.runtime_supported),
                jsonBool(descriptor.remote_primary_supported),
            },
        );
    }
    try out.append(allocator, ']');
}

fn jsonBool(value: bool) []const u8 {
    return if (value) "true" else "false";
}

test "engine registry includes storage and adapter contracts" {
    try std.testing.expect(parse("none") == .none);
    try std.testing.expect(parse("sqlite") == .sqlite);
    try std.testing.expect(parse("markdown") == .markdown);
    try std.testing.expect(parse("hybrid") == .hybrid);
    try std.testing.expect(parse("sqlite_markdown") == .hybrid);
    try std.testing.expect(parse("qmd") == .qmd);
    try std.testing.expect(parse("memory_lru") == .memory_lru);
    try std.testing.expect(parse("memory") == .memory_lru);
    try std.testing.expect(parse("in_memory") == .memory_lru);
    try std.testing.expect(parse("lucid") == .lucid);
    try std.testing.expect(parse("postgres") == .postgres);
    try std.testing.expect(parse("pgvector") == .pgvector);
    try std.testing.expect(parse("redis") == .redis);
    try std.testing.expect(parse("api") == .api);
    try std.testing.expect(parse("clickhouse") == .clickhouse);
    try std.testing.expect(parse("qdrant") == .qdrant);
    try std.testing.expect(parse("lancedb") == .lancedb);
    try std.testing.expect(parse("kg") == .kg);
    try std.testing.expect(parse("unknown") == null);
    try std.testing.expectEqualStrings("sqlite", nullclawEngineTokenForName("hybrid").?);
    try std.testing.expectEqualStrings("memory", nullclawEngineTokenForName("memory_lru").?);
    try std.testing.expectEqualStrings("memory", nullclawEngineTokenForName("memory").?);
    try std.testing.expectEqualStrings("postgres", nullclawEngineTokenForName("postgres").?);
    try std.testing.expect(nullclawEngineTokenForName("unknown") == null);
}

test "redis is a real remote agent memory plane" {
    const redis_descriptor = descriptors[@intFromEnum(EngineKind.redis)];
    try std.testing.expect(redis_descriptor.runtime_supported);
    try std.testing.expect(redis_descriptor.remote_primary_supported);
    try std.testing.expect(redis_descriptor.capabilities.session_store);
    try std.testing.expect(redis_descriptor.capabilities.transactions);
    try std.testing.expect(std.mem.indexOf(u8, redis_descriptor.planes_json, "agent_memory") != null);
    try std.testing.expect(std.mem.indexOf(u8, redis_descriptor.nullpantry_strategy, "RESP") != null);
    try std.testing.expect(std.mem.indexOf(u8, redis_descriptor.nullclaw_boundary, "NullPantry") != null);
}

test "hybrid and memory descriptors expose NullClaw-style discovery flags" {
    const hybrid_descriptor = descriptors[@intFromEnum(EngineKind.hybrid)];
    try std.testing.expect(hybrid_descriptor.auto_save_default);
    try std.testing.expect(hybrid_descriptor.capabilities.keyword_rank);
    try std.testing.expect(hybrid_descriptor.capabilities.session_store);
    try std.testing.expect(hybrid_descriptor.capabilities.transactions);
    try std.testing.expect(hybrid_descriptor.capabilities.outbox);
    try std.testing.expect(hybrid_descriptor.requirements.db_path);
    try std.testing.expect(hybrid_descriptor.requirements.workspace);

    const memory_descriptor = descriptors[@intFromEnum(EngineKind.memory_lru)];
    try std.testing.expect(!memory_descriptor.auto_save_default);
    try std.testing.expect(!memory_descriptor.capabilities.keyword_rank);
    try std.testing.expect(memory_descriptor.capabilities.session_store);
    try std.testing.expect(!memory_descriptor.capabilities.transactions);
    try std.testing.expect(!memory_descriptor.capabilities.outbox);
    try std.testing.expect(!memory_descriptor.requirements.db_path);
    try std.testing.expect(!memory_descriptor.requirements.workspace);
}

test "api is a remote NullPantry-compatible agent memory plane" {
    const descriptor = descriptors[@intFromEnum(EngineKind.api)];
    try std.testing.expect(descriptor.runtime_supported);
    try std.testing.expect(descriptor.remote_primary_supported);
    try std.testing.expect(std.mem.indexOf(u8, descriptor.planes_json, "agent_memory") != null);
    try std.testing.expect(std.mem.indexOf(u8, descriptor.planes_json, "feed") != null);
    try std.testing.expect(std.mem.indexOf(u8, descriptor.nullpantry_strategy, "/v1 API") != null);
}

test "advanced runtime planes are advertised only after runtime wiring" {
    try std.testing.expect(descriptors[@intFromEnum(EngineKind.lucid)].runtime_supported);
    try std.testing.expect(descriptors[@intFromEnum(EngineKind.clickhouse)].runtime_supported);
    try std.testing.expect(descriptors[@intFromEnum(EngineKind.pgvector)].runtime_supported);
    try std.testing.expect(descriptors[@intFromEnum(EngineKind.qdrant)].runtime_supported);
    try std.testing.expect(descriptors[@intFromEnum(EngineKind.lancedb)].runtime_supported);
}

test "pgvector is advertised as its own Postgres-coupled vector plane" {
    const descriptor = descriptors[@intFromEnum(EngineKind.pgvector)];
    try std.testing.expect(descriptor.runtime_supported);
    try std.testing.expect(descriptor.remote_primary_supported);
    try std.testing.expect(std.mem.indexOf(u8, descriptor.planes_json, "vector") != null);
    try std.testing.expect(std.mem.indexOf(u8, descriptor.planes_json, "record_coupled") != null);
    try std.testing.expect(std.mem.indexOf(u8, descriptor.nullpantry_strategy, "ACL hydration") != null);
    try std.testing.expect(std.mem.indexOf(u8, descriptor.nullclaw_boundary, "NullPantry service") != null);
}
