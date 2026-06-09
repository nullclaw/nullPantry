const std = @import("std");
const build_options = @import("build_options");
const feed_contract = @import("feed_contract.zig");
const json = @import("json_util.zig");

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
    supermemory,
    openviking,
    honcho,
    mem0,
    hindsight,
    retaindb,
    byterover,
    holographic,
    zep,
    falkordb,
    clickhouse,
    qdrant,
    lancedb,
    lancedb_http,
    weaviate,
    chroma,
    opensearch,
    neo4j,
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
            .supermemory => "supermemory",
            .openviking => "openviking",
            .honcho => "honcho",
            .mem0 => "mem0",
            .hindsight => "hindsight",
            .retaindb => "retaindb",
            .byterover => "byterover",
            .holographic => "holographic",
            .zep => "zep",
            .falkordb => "falkordb",
            .clickhouse => "clickhouse",
            .qdrant => "qdrant",
            .lancedb => "lancedb",
            .lancedb_http => "lancedb_http",
            .weaviate => "weaviate",
            .chroma => "chroma",
            .opensearch => "opensearch",
            .neo4j => "neo4j",
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

pub const EngineRole = enum {
    records,
    agent_memory,
    vectors,
    search,
    retrieval,
    files,
    projection,
    graph_projection,
    analytics,

    pub fn name(self: EngineRole) []const u8 {
        return switch (self) {
            .records => "records",
            .agent_memory => "agent_memory",
            .vectors => "vectors",
            .search => "search",
            .retrieval => "retrieval",
            .files => "files",
            .projection => "projection",
            .graph_projection => "graph_projection",
            .analytics => "analytics",
        };
    }
};

pub const EngineCapabilities = struct {
    record_store: bool = false,
    agent_memory_store: bool = false,
    session_history: bool = false,
    usage_store: bool = false,
    keyword_rank: bool = false,
    session_store: bool = false,
    transactions: bool = false,
    outbox: bool = false,
    feed: bool = false,
    feed_peer: bool = false,
    vector: bool = false,
    vector_index: bool = false,
    search: bool = false,
    search_index: bool = false,
    graph: bool = false,
    graph_index: bool = false,
    graph_projection: bool = false,
    graph_projection_index: bool = false,
    analytics: bool = false,
    analytics_export: bool = false,
    import_export: bool = false,
    filesystem_import_export: bool = false,
    composition_profile: bool = false,
    projection: bool = false,
    projection_index: bool = false,
    cache: bool = false,
    lifecycle: bool = false,
    lifecycle_reducer: bool = false,
    remote_api_proxy: bool = false,
};

pub const EngineRequirements = struct {
    db_path: bool = false,
    workspace: bool = false,
};

pub const EngineDescriptor = struct {
    kind: EngineKind,
    primary_role: EngineRole,
    description: []const u8,
    durability: []const u8,
    provides_json: []const u8,
    primary_for: []const u8,
    nullpantry_strategy: []const u8,
    nullclaw_boundary: []const u8,
    nullclaw_replacement_json: []const u8 = "{}",
    runtime_config_json: []const u8 = "{\"selectable_as\":[],\"required\":[],\"env\":[],\"cli\":[]}",
    aliases_json: []const u8 = "[]",
    feed_object_types_json: []const u8 = "[]",
    lifecycle_object_types_json: []const u8 = "[]",
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
    .{ .kind = .none, .primary_role = .agent_memory, .description = "disabled memory backend", .durability = "none", .provides_json = "[\"agent_memory\",\"session\",\"usage\"]", .primary_for = "agent_memory,session,usage", .nullpantry_strategy = "explicit no-op runtime backend for parity with NullClaw none mode and controlled memory-disabled deployments", .nullclaw_boundary = "NullClaw baseline disabled memory mode; NullPantry can expose the same mode centrally", .runtime_config_json = "{\"selectable_as\":[\"agent_memory\",\"named_agent_memory\"],\"required\":[],\"env\":[\"NULLPANTRY_AGENT_MEMORY_BACKEND=none\"],\"cli\":[\"--agent-memory-backend none\"]}" },
    .{ .kind = .sqlite, .primary_role = .records, .description = "local-dev relational memory", .durability = "durable", .provides_json = "[\"record\",\"agent_memory\",\"session\",\"vector\",\"cache\",\"lifecycle\",\"feed\"]", .primary_for = "record,agent_memory,session,vector,cache,lifecycle,feed", .nullpantry_strategy = "native SQLite service backend with FTS5 and local vector search", .nullclaw_boundary = "NullClaw baseline local engine; NullPantry local/dev system-of-record", .runtime_config_json = "{\"selectable_as\":[\"records\"],\"required\":[\"db_path\"],\"env\":[\"NULLPANTRY_DB_PATH\"],\"cli\":[\"--backend sqlite\",\"--db-path\"]}", .feed_object_types_json = feed_contract.supported_object_types_json, .lifecycle_object_types_json = feed_contract.lifecycle_object_types_json, .auto_save_default = true, .capabilities = .{ .record_store = true, .agent_memory_store = true, .session_history = true, .usage_store = true, .keyword_rank = true, .session_store = true, .transactions = true, .outbox = true, .feed = true, .feed_peer = true, .vector = true, .vector_index = true, .cache = true, .lifecycle = true, .lifecycle_reducer = true }, .requirements = .{ .db_path = true }, .remote_primary_supported = true },
    .{ .kind = .markdown, .primary_role = .agent_memory, .description = "live Markdown workspace memory", .durability = "filesystem", .provides_json = "[\"agent_memory\",\"filesystem\",\"import_export\",\"snapshot\"]", .primary_for = "agent_memory,filesystem_import_export,markdown_corpus", .nullpantry_strategy = "NullClaw-compatible live Markdown workspace backend that reads MEMORY.md, memory.md, and memory/*.md on each agent-memory request, appends stores back to Markdown, and still supports governed directory import/export into canonical SQLite/Postgres records", .nullclaw_boundary = "NullClaw baseline local Markdown engine maps to a NullPantry runtime agent-memory backend for file-backed local usage; Markdown remains non-canonical for shared record storage, feed, lifecycle, sessions, usage, and vectors", .runtime_config_json = "{\"selectable_as\":[\"agent_memory\",\"named_agent_memory\",\"filesystem_import_export\"],\"required\":[\"markdown_workspace\"],\"env\":[\"NULLPANTRY_AGENT_MEMORY_BACKEND=markdown\",\"NULLPANTRY_AGENT_MEMORY_MARKDOWN_WORKSPACE\",\"NULLPANTRY_MARKDOWN_WORKSPACE\"],\"cli\":[\"--agent-memory-backend markdown\",\"--markdown-workspace\",\"--agent-memory-store notes=markdown:///path/to/workspace\"]}", .aliases_json = "[\"md\",\"filesystem\"]", .auto_save_default = true, .capabilities = .{ .agent_memory_store = true, .import_export = true, .filesystem_import_export = true }, .requirements = .{ .workspace = true } },
    .{ .kind = .hybrid, .primary_role = .files, .description = "canonical record plus governed Markdown composition", .durability = "profile", .provides_json = "[\"compatibility_profile\",\"filesystem\",\"import_export\"]", .primary_for = "markdown_import_export,compatibility_composition", .nullpantry_strategy = "composition profile for SQLite/Postgres canonical storage plus Markdown import/export jobs; the selected record store owns records, feed, lifecycle, cache, vectors, and agent memory", .nullclaw_boundary = "NullClaw hybrid backend maps to NullPantry native record storage with governed Markdown filesystem ingestion/export", .nullclaw_replacement_json = "{\"records\":\"sqlite_or_postgres\",\"files\":\"markdown\",\"state_backend\":\"canonical_records\",\"profile\":\"hybrid\",\"notes\":[\"hybrid is a compatibility profile, not a third record store\",\"store records, agent memory, feed, lifecycle, and cache in the selected canonical store\",\"use Markdown only through governed import/export jobs\"]}", .runtime_config_json = "{\"selectable_as\":[\"compatibility_profile\",\"filesystem_import_export\"],\"required\":[\"records\",\"request_path_or_workspace\"],\"env\":[\"NULLPANTRY_DB_PATH\",\"NULLPANTRY_DATABASE_URL\"],\"cli\":[\"--backend sqlite|postgres\",\"--db-path\",\"--postgres-url\"]}", .aliases_json = "[\"sqlite_markdown\"]", .capabilities = .{ .import_export = true, .filesystem_import_export = true, .composition_profile = true }, .requirements = .{ .workspace = true } },
    .{ .kind = .qmd, .primary_role = .files, .description = "QMD-compatible markdown/session result ingestion and export", .durability = "canonicalized", .provides_json = "[\"connector\",\"retrieval_source\",\"import_export\"]", .primary_for = "qmd_search_results,agent_session_exports,markdown_corpus", .nullpantry_strategy = "normalize qmd JSON results into canonical Sources and export permission-checked agent sessions into a QMD markdown corpus with provenance, ACL, extraction, vectors, feed, and lifecycle instead of serving them as an ungoverned sidecar", .nullclaw_boundary = "NullClaw QMD retrieval and session export move to NullPantry connectors so agents query governed central knowledge", .runtime_config_json = "{\"selectable_as\":[\"connector\",\"retrieval_source\",\"filesystem_import_export\"],\"required\":[\"request_qmd_results_or_workspace\"],\"env\":[],\"cli\":[]}", .capabilities = .{ .import_export = true, .filesystem_import_export = true } },
    .{ .kind = .memory_lru, .primary_role = .agent_memory, .description = "ephemeral process memory", .durability = "ephemeral", .provides_json = "[\"agent_memory\",\"session\",\"usage\",\"feed\",\"lifecycle\",\"test\"]", .primary_for = "agent_memory,session,usage,feed,lifecycle,test", .nullpantry_strategy = "in-process runtime backend for tests, single-process agents, and named scratch stores; not durable shared memory", .nullclaw_boundary = "NullClaw baseline in-process engine; NullPantry can expose it centrally for parity and scratch stores", .runtime_config_json = "{\"selectable_as\":[\"agent_memory\",\"named_agent_memory\"],\"required\":[],\"env\":[\"NULLPANTRY_AGENT_MEMORY_BACKEND=memory_lru\",\"NULLPANTRY_MEMORY_LRU_*\"],\"cli\":[\"--agent-memory-backend memory_lru\",\"--memory-lru-*\"]}", .aliases_json = "[\"memory\",\"in_memory\"]", .feed_object_types_json = feed_contract.runtime_object_types_json, .lifecycle_object_types_json = feed_contract.runtime_lifecycle_object_types_json, .capabilities = .{ .agent_memory_store = true, .session_history = true, .usage_store = true, .session_store = true, .feed = true, .feed_peer = true, .lifecycle = true, .lifecycle_reducer = true } },
    .{ .kind = .lucid, .primary_role = .projection, .description = "local semantic memory projection", .durability = "durable", .provides_json = "[\"projection\",\"semantic_context\"]", .primary_for = "projection", .nullpantry_strategy = "optional Lucid CLI projection adapter backed by durable projection jobs, lifecycle retractions, status, and rebuild; NullPantry remains source of truth and ACL gate", .nullclaw_boundary = "advanced semantic memory projection belongs in NullPantry, not NullClaw core", .runtime_config_json = "{\"selectable_as\":[\"projection\"],\"required\":[\"lucid_enabled\",\"lucid_workspace\"],\"env\":[\"NULLPANTRY_LUCID_ENABLED\",\"NULLPANTRY_LUCID_WORKSPACE\"],\"cli\":[\"--lucid-enabled\",\"--lucid-workspace\"]}", .capabilities = .{ .projection = true, .projection_index = true }, .requirements = .{ .workspace = true } },
    .{ .kind = .postgres, .primary_role = .records, .description = "durable relational memory target", .durability = "durable", .provides_json = "[\"record\",\"agent_memory\",\"session\",\"cache\",\"lifecycle\",\"feed\"]", .primary_for = "record,agent_memory,session,cache,lifecycle,feed", .nullpantry_strategy = "native libpq runtime adapter for canonical primitives, lifecycle, cache, feed, jobs, sessions, and agent memory", .nullclaw_boundary = "shared durable memory belongs in NullPantry service", .runtime_config_json = "{\"selectable_as\":[\"records\"],\"required\":[\"postgres_url\"],\"env\":[\"NULLPANTRY_DATABASE_URL\"],\"cli\":[\"--backend postgres\",\"--postgres-url\"]}", .feed_object_types_json = feed_contract.supported_object_types_json, .lifecycle_object_types_json = feed_contract.lifecycle_object_types_json, .auto_save_default = true, .capabilities = .{ .record_store = true, .agent_memory_store = true, .session_history = true, .usage_store = true, .keyword_rank = true, .session_store = true, .transactions = true, .outbox = true, .feed = true, .feed_peer = true, .vector = true, .vector_index = true, .cache = true, .lifecycle = true, .lifecycle_reducer = true }, .remote_primary_supported = true },
    .{ .kind = .pgvector, .primary_role = .vectors, .description = "Postgres pgvector index", .durability = "durable", .provides_json = "[\"vector\",\"record_coupled\",\"runtime_sink\"]", .primary_for = "vector", .nullpantry_strategy = "pgvector-backed vector chunks either inside the Postgres record store or as an independent vector runtime sink for SQLite/other record stores, with dynamic dimensions, ACL hydration, reconcile, rebuild, and retrieval fallback through NullPantry", .nullclaw_boundary = "pgvector/vector database complexity belongs in NullPantry service, not NullClaw core", .runtime_config_json = "{\"selectable_as\":[\"vectors\"],\"required\":[\"pgvector_url\"],\"env\":[\"NULLPANTRY_VECTOR_BACKEND=pgvector\",\"NULLPANTRY_PGVECTOR_URL\",\"NULLPANTRY_VECTOR_POSTGRES_URL\"],\"cli\":[\"--vector-backend pgvector\",\"--pgvector-url\"]}", .capabilities = .{ .outbox = true, .vector = true, .vector_index = true }, .remote_primary_supported = true },
    .{ .kind = .redis, .primary_role = .agent_memory, .description = "low-latency shared agent memory", .durability = "configurable", .provides_json = "[\"agent_memory\",\"session\",\"usage\",\"feed\",\"lifecycle\"]", .primary_for = "agent_memory,session,usage,feed,lifecycle", .nullpantry_strategy = "native RESP runtime backend for shared/isolated agent memory, sessions, usage, lifecycle reducers, and deterministic feed/checkpoint sync", .nullclaw_boundary = "shared remote agent memory belongs in NullPantry service", .runtime_config_json = "{\"selectable_as\":[\"agent_memory\",\"named_agent_memory\"],\"required\":[\"redis_url\"],\"env\":[\"NULLPANTRY_AGENT_MEMORY_BACKEND=redis\",\"NULLPANTRY_REDIS_URL\"],\"cli\":[\"--agent-memory-backend redis\",\"--redis-url\"]}", .feed_object_types_json = feed_contract.runtime_object_types_json, .lifecycle_object_types_json = feed_contract.runtime_lifecycle_object_types_json, .auto_save_default = true, .capabilities = .{ .agent_memory_store = true, .session_history = true, .usage_store = true, .session_store = true, .transactions = true, .feed = true, .feed_peer = true, .lifecycle = true, .lifecycle_reducer = true }, .remote_primary_supported = true },
    .{ .kind = .api, .primary_role = .agent_memory, .description = "remote NullPantry-compatible agent memory API", .durability = "remote", .provides_json = "[\"agent_memory\",\"session\",\"usage\",\"feed\",\"lifecycle\"]", .primary_for = "agent_memory,session,usage,feed,lifecycle", .nullpantry_strategy = "HTTP runtime backend that proxies agent memory, sessions, usage, lifecycle reducers, and deterministic feed peer operations to another NullPantry-compatible /v1 API with actor/scope/capability forwarding and remote lifecycle target resolution", .nullclaw_boundary = "remote agent memory belongs behind NullPantry API rather than NullClaw core", .runtime_config_json = "{\"selectable_as\":[\"agent_memory\",\"named_agent_memory\"],\"required\":[\"api_url\"],\"env\":[\"NULLPANTRY_AGENT_MEMORY_BACKEND=api\",\"NULLPANTRY_AGENT_MEMORY_API_URL\"],\"cli\":[\"--agent-memory-backend api\",\"--agent-memory-api-url\"]}", .feed_object_types_json = feed_contract.runtime_object_types_json, .lifecycle_object_types_json = feed_contract.runtime_lifecycle_object_types_json, .auto_save_default = true, .capabilities = .{ .agent_memory_store = true, .session_history = true, .usage_store = true, .session_store = true, .feed = true, .feed_peer = true, .lifecycle = true, .lifecycle_reducer = true, .remote_api_proxy = true }, .remote_primary_supported = true },
    .{ .kind = .supermemory, .primary_role = .agent_memory, .description = "Supermemory external memory runtime", .durability = "remote", .provides_json = "[\"agent_memory\",\"semantic_search\",\"vendor_projection\"]", .primary_for = "agent_memory,semantic_search", .nullpantry_strategy = "Supermemory API profile that maps NullPantry actor/session/key memory into deterministic document customIds, containerTag-isolated private/team/project scopes, metadata-backed ACL hydration, and v4 semantic search while keeping canonical knowledge primitives, feed, lifecycle, and context packs in NullPantry", .nullclaw_boundary = "vendor memory services are runtime backends behind NullPantry; NullClaw talks to NullPantry instead of integrating vendor SDKs directly", .runtime_config_json = "{\"selectable_as\":[\"agent_memory\",\"named_agent_memory\"],\"required\":[\"supermemory_api_key\"],\"env\":[\"NULLPANTRY_AGENT_MEMORY_BACKEND=supermemory\",\"NULLPANTRY_SUPERMEMORY_API_KEY\",\"NULLPANTRY_SUPERMEMORY_URL\"],\"cli\":[\"--agent-memory-backend supermemory\",\"--supermemory-api-key\",\"--supermemory-url\"]}", .aliases_json = "[\"supermemory_api\"]", .auto_save_default = true, .capabilities = .{ .agent_memory_store = true, .keyword_rank = true, .remote_api_proxy = true }, .remote_primary_supported = true },
    .{ .kind = .openviking, .primary_role = .agent_memory, .description = "OpenViking external context memory runtime", .durability = "remote", .provides_json = "[\"agent_memory\",\"semantic_search\",\"filesystem_projection\",\"vendor_projection\"]", .primary_for = "agent_memory,semantic_search", .nullpantry_strategy = "OpenViking API profile that stores NullPantry actor/session/key memory as deterministic Viking resource files, uses X-API-Key authenticated content/read/write/delete plus search/find retrieval, hydrates full file content back into NullPantry metadata, and applies actor/scope visibility after vendor retrieval while keeping canonical knowledge primitives, feed, lifecycle, and context packs in NullPantry", .nullclaw_boundary = "vendor context databases are runtime backends behind NullPantry; NullClaw talks to NullPantry instead of integrating vendor SDKs directly", .runtime_config_json = "{\"selectable_as\":[\"agent_memory\",\"named_agent_memory\"],\"required\":[\"openviking_api_key\"],\"env\":[\"NULLPANTRY_AGENT_MEMORY_BACKEND=openviking\",\"NULLPANTRY_OPENVIKING_API_KEY\",\"NULLPANTRY_OPENVIKING_URL\"],\"cli\":[\"--agent-memory-backend openviking\",\"--openviking-api-key\",\"--openviking-url\"]}", .aliases_json = "[\"openviking_api\"]", .auto_save_default = true, .capabilities = .{ .agent_memory_store = true, .keyword_rank = true, .remote_api_proxy = true, .filesystem_import_export = true }, .remote_primary_supported = true },
    .{ .kind = .honcho, .primary_role = .agent_memory, .description = "Honcho external agent context runtime", .durability = "remote", .provides_json = "[\"agent_memory\",\"semantic_search\",\"vendor_projection\"]", .primary_for = "agent_memory,semantic_search", .nullpantry_strategy = "Honcho API profile that maps NullPantry actor/session/key memory into Honcho Workspace, Peer, Session, and Message primitives with NullPantry metadata, append-only tombstones/status events, ACL-aware hydration, and semantic retrieval while keeping canonical knowledge primitives, feed, lifecycle, and context packs in NullPantry", .nullclaw_boundary = "vendor context databases are runtime backends behind NullPantry; NullClaw talks to NullPantry instead of integrating vendor SDKs directly", .runtime_config_json = "{\"selectable_as\":[\"agent_memory\",\"named_agent_memory\"],\"required\":[\"honcho_api_key\"],\"env\":[\"NULLPANTRY_AGENT_MEMORY_BACKEND=honcho\",\"NULLPANTRY_HONCHO_API_KEY\",\"NULLPANTRY_HONCHO_URL\",\"NULLPANTRY_HONCHO_WORKSPACE_ID\"],\"cli\":[\"--agent-memory-backend honcho\",\"--honcho-api-key\",\"--honcho-url\",\"--honcho-workspace-id\"]}", .aliases_json = "[\"honcho_api\"]", .auto_save_default = true, .capabilities = .{ .agent_memory_store = true, .keyword_rank = true, .remote_api_proxy = true }, .remote_primary_supported = true },
    .{ .kind = .mem0, .primary_role = .agent_memory, .description = "Mem0 external agent memory runtime", .durability = "remote", .provides_json = "[\"agent_memory\",\"semantic_search\",\"vendor_projection\"]", .primary_for = "agent_memory,semantic_search", .nullpantry_strategy = "Mem0 API profile that maps NullPantry actor/session/key memory into Mem0 v3 memories with agent_id/app_id/run_id filters, NullPantry metadata-backed ACL hydration, typed reducer updates, and semantic search while keeping canonical knowledge primitives, feed, lifecycle, and context packs in NullPantry", .nullclaw_boundary = "vendor memory services are runtime backends behind NullPantry; NullClaw talks to NullPantry instead of integrating vendor SDKs directly", .runtime_config_json = "{\"selectable_as\":[\"agent_memory\",\"named_agent_memory\"],\"required\":[\"mem0_api_key\"],\"env\":[\"NULLPANTRY_AGENT_MEMORY_BACKEND=mem0\",\"NULLPANTRY_MEM0_API_KEY\",\"NULLPANTRY_MEM0_URL\"],\"cli\":[\"--agent-memory-backend mem0\",\"--mem0-api-key\",\"--mem0-url\"]}", .aliases_json = "[\"mem0_api\"]", .auto_save_default = true, .capabilities = .{ .agent_memory_store = true, .keyword_rank = true, .remote_api_proxy = true }, .remote_primary_supported = true },
    .{ .kind = .hindsight, .primary_role = .agent_memory, .description = "Hindsight external agent memory runtime", .durability = "remote", .provides_json = "[\"agent_memory\",\"semantic_search\",\"vendor_projection\"]", .primary_for = "agent_memory,semantic_search", .nullpantry_strategy = "Hindsight API profile that maps NullPantry actor/session/key memory into Hindsight bank-scoped retain/recall memory units with NullPantry metadata, Hindsight tags for vendor-side narrowing, append-only tombstone/status events, and ACL-aware hydration while keeping canonical knowledge primitives, feed, lifecycle, and context packs in NullPantry", .nullclaw_boundary = "vendor memory services are runtime backends behind NullPantry; NullClaw talks to NullPantry instead of integrating vendor SDKs directly", .runtime_config_json = "{\"selectable_as\":[\"agent_memory\",\"named_agent_memory\"],\"required\":[\"hindsight_api_key\",\"hindsight_bank_id\"],\"env\":[\"NULLPANTRY_AGENT_MEMORY_BACKEND=hindsight\",\"NULLPANTRY_HINDSIGHT_API_KEY\",\"NULLPANTRY_HINDSIGHT_BANK_ID\",\"NULLPANTRY_HINDSIGHT_URL\"],\"cli\":[\"--agent-memory-backend hindsight\",\"--hindsight-api-key\",\"--hindsight-bank-id\",\"--hindsight-url\"]}", .aliases_json = "[\"hindsight_api\"]", .auto_save_default = true, .capabilities = .{ .agent_memory_store = true, .keyword_rank = true, .remote_api_proxy = true }, .remote_primary_supported = true },
    .{ .kind = .retaindb, .primary_role = .agent_memory, .description = "RetainDB external agent memory runtime", .durability = "remote", .provides_json = "[\"agent_memory\",\"semantic_search\",\"vendor_projection\"]", .primary_for = "agent_memory,semantic_search", .nullpantry_strategy = "RetainDB API profile that maps NullPantry actor/session/key memory into RetainDB Memory API project, user_id, session_id, agent_id, and task_id fields with NullPantry metadata-backed ACL hydration, typed reducer updates, and semantic search while keeping canonical knowledge primitives, feed, lifecycle, and context packs in NullPantry", .nullclaw_boundary = "vendor memory services are runtime backends behind NullPantry; NullClaw talks to NullPantry instead of integrating vendor SDKs directly", .runtime_config_json = "{\"selectable_as\":[\"agent_memory\",\"named_agent_memory\"],\"required\":[\"retaindb_api_key\"],\"env\":[\"NULLPANTRY_AGENT_MEMORY_BACKEND=retaindb\",\"NULLPANTRY_RETAINDB_API_KEY\",\"NULLPANTRY_RETAINDB_URL\",\"NULLPANTRY_RETAINDB_PROJECT\"],\"cli\":[\"--agent-memory-backend retaindb\",\"--retaindb-api-key\",\"--retaindb-url\",\"--retaindb-project\"]}", .aliases_json = "[\"retaindb_api\",\"retain_db\"]", .auto_save_default = true, .capabilities = .{ .agent_memory_store = true, .keyword_rank = true, .remote_api_proxy = true }, .remote_primary_supported = true },
    .{ .kind = .byterover, .primary_role = .agent_memory, .description = "ByteRover CLI context-tree agent memory runtime", .durability = "local+optional-cloud", .provides_json = "[\"agent_memory\",\"semantic_search\",\"cli_projection\",\"context_tree\"]", .primary_for = "agent_memory,semantic_search", .nullpantry_strategy = "ByteRover headless CLI profile that stores NullPantry actor/session/key memory as fenced JSON blocks through brv curate --format json, retrieves through brv query --format json or brv swarm query, hydrates metadata back into AgentMemory rows, and re-filters every result by NullPantry owner/scope/permissions while keeping canonical knowledge primitives, feed, lifecycle, and context packs in NullPantry", .nullclaw_boundary = "agent memory engines and external context trees live behind NullPantry; NullClaw talks to NullPantry instead of integrating ByteRover CLI directly", .runtime_config_json = "{\"selectable_as\":[\"agent_memory\",\"named_agent_memory\"],\"required\":[\"byterover_cli\"],\"env\":[\"NULLPANTRY_AGENT_MEMORY_BACKEND=byterover\",\"NULLPANTRY_BYTEROVER_COMMAND\",\"NULLPANTRY_BYTEROVER_PROJECT_DIR\",\"NULLPANTRY_BYTEROVER_USE_SWARM\"],\"cli\":[\"--agent-memory-backend byterover\",\"--byterover-command\",\"--byterover-project-dir\",\"--byterover-use-swarm\"]}", .aliases_json = "[\"byterover_cli\",\"brv\"]", .auto_save_default = true, .capabilities = .{ .agent_memory_store = true, .keyword_rank = true, .projection = true, .projection_index = true }, .requirements = .{ .workspace = true }, .remote_primary_supported = true },
    .{ .kind = .holographic, .primary_role = .agent_memory, .description = "Holographic local associative agent memory runtime", .durability = "durable", .provides_json = "[\"agent_memory\",\"semantic_search\",\"local_projection\"]", .primary_for = "agent_memory,semantic_search", .nullpantry_strategy = "local SQLite/FTS5 agent-memory runtime with NullPantry actor/scope ACLs, deterministic reducers, trust scoring, and lightweight HRR-style associative ranking; it is a runtime projection, not a central feed authority or Confluence replacement by itself", .nullclaw_boundary = "advanced local associative memory belongs behind NullPantry's runtime boundary; NullClaw can select NullPantry instead of embedding a separate Holographic provider", .runtime_config_json = "{\"selectable_as\":[\"agent_memory\",\"named_agent_memory\"],\"required\":[\"holographic_db_path\"],\"env\":[\"NULLPANTRY_AGENT_MEMORY_BACKEND=holographic\",\"NULLPANTRY_AGENT_MEMORY_HOLOGRAPHIC_DB_PATH\",\"NULLPANTRY_HOLOGRAPHIC_DB_PATH\"],\"cli\":[\"--agent-memory-backend holographic\",\"--holographic-db-path\"]}", .aliases_json = "[\"holographic_sqlite\"]", .auto_save_default = true, .capabilities = .{ .agent_memory_store = true, .keyword_rank = true }, .requirements = .{ .db_path = true } },
    .{ .kind = .zep, .primary_role = .agent_memory, .description = "Zep temporal knowledge graph agent-memory runtime", .durability = "remote", .provides_json = "[\"agent_memory\",\"temporal_graph\",\"semantic_search\",\"bm25\",\"context_block\"]", .primary_for = "agent_memory,temporal_graph,semantic_search", .nullpantry_strategy = "Zep API profile that stores NullPantry actor/session/key memory as graph episodes, searches across temporal graph scopes, and rehydrates exact NullPantry ACL/status/session metadata before returning context; canonical Source/MemoryAtom/Entity/Relation records remain in NullPantry", .nullclaw_boundary = "temporal graph memory services are runtime projections behind NullPantry; NullClaw talks to NullPantry instead of integrating Zep SDKs directly", .runtime_config_json = "{\"selectable_as\":[\"agent_memory\",\"named_agent_memory\",\"graph_projection\"],\"required\":[\"zep_api_key\"],\"env\":[\"NULLPANTRY_AGENT_MEMORY_BACKEND=zep\",\"NULLPANTRY_ZEP_API_KEY\",\"NULLPANTRY_ZEP_URL\",\"NULLPANTRY_ZEP_GRAPH_ID\"],\"cli\":[\"--agent-memory-backend zep\",\"--zep-api-key\",\"--zep-url\",\"--zep-graph-id\"]}", .aliases_json = "[\"zep_api\"]", .auto_save_default = true, .capabilities = .{ .agent_memory_store = true, .keyword_rank = true, .search = true, .search_index = true, .graph = true, .graph_index = true, .graph_projection = true, .graph_projection_index = true, .remote_api_proxy = true }, .remote_primary_supported = true },
    .{ .kind = .falkordb, .primary_role = .agent_memory, .description = "FalkorDB graph-backed agent-memory runtime", .durability = "durable", .provides_json = "[\"agent_memory\",\"graph_projection\",\"cypher\",\"full_text\",\"vector\"]", .primary_for = "agent_memory,graph_projection,semantic_search", .nullpantry_strategy = "FalkorDB profile that stores NullPantry memory as Cypher-addressable graph nodes with full-text/vector retrieval metadata while treating NullPantry canonical records, ACLs, lifecycle, and feed as authoritative", .nullclaw_boundary = "low-latency graph memory is an external runtime behind NullPantry, not a direct NullClaw dependency", .runtime_config_json = "{\"selectable_as\":[\"agent_memory\",\"named_agent_memory\",\"graph_projection\"],\"required\":[\"falkordb_url\"],\"env\":[\"NULLPANTRY_AGENT_MEMORY_BACKEND=falkordb\",\"NULLPANTRY_FALKORDB_URL\",\"NULLPANTRY_FALKORDB_GRAPH\"],\"cli\":[\"--agent-memory-backend falkordb\",\"--falkordb-url\",\"--falkordb-graph\"]}", .aliases_json = "[\"falkor\",\"falkordb_graph\"]", .auto_save_default = true, .capabilities = .{ .agent_memory_store = true, .keyword_rank = true, .search = true, .search_index = true, .graph = true, .graph_index = true, .graph_projection = true, .graph_projection_index = true, .remote_api_proxy = true }, .remote_primary_supported = true },
    .{ .kind = .clickhouse, .primary_role = .agent_memory, .description = "durable columnar agent memory and high-volume history", .durability = "durable", .provides_json = "[\"agent_memory\",\"session\",\"usage\",\"feed\",\"lifecycle\",\"analytics\",\"audit_export\",\"event_history\"]", .primary_for = "agent_memory,session,usage,feed,lifecycle,analytics,audit_export", .nullpantry_strategy = "native ClickHouse HTTP runtime adapter for durable actor-scoped agent memory, session messages, usage counters, lifecycle reducers, deterministic feed/checkpoint sync, cursor-floor compaction, and audit/feed event export", .nullclaw_boundary = "ClickHouse memory, lifecycle, feed, and analytics complexity belongs in NullPantry service, not NullClaw core", .runtime_config_json = "{\"selectable_as\":[\"agent_memory\",\"named_agent_memory\",\"analytics\"],\"required\":[\"clickhouse_url\"],\"env\":[\"NULLPANTRY_AGENT_MEMORY_BACKEND=clickhouse\",\"NULLPANTRY_AGENT_MEMORY_CLICKHOUSE_URL\",\"NULLPANTRY_ANALYTICS_BACKEND=clickhouse\",\"NULLPANTRY_ANALYTICS_BASE_URL\"],\"cli\":[\"--agent-memory-backend clickhouse\",\"--agent-memory-clickhouse-url\",\"--analytics-backend clickhouse\",\"--analytics-base-url\"]}", .feed_object_types_json = feed_contract.runtime_object_types_json, .lifecycle_object_types_json = feed_contract.runtime_lifecycle_object_types_json, .auto_save_default = true, .capabilities = .{ .agent_memory_store = true, .session_history = true, .usage_store = true, .session_store = true, .feed = true, .feed_peer = true, .lifecycle = true, .lifecycle_reducer = true, .analytics = true, .analytics_export = true }, .remote_primary_supported = true },
    .{ .kind = .qdrant, .primary_role = .vectors, .description = "ANN vector database", .durability = "durable", .provides_json = "[\"vector\"]", .primary_for = "vector", .nullpantry_strategy = "native Qdrant HTTP runtime adapter for vector upsert/search/delete/reset plus canonical reconcile/rebuild through NullPantry", .nullclaw_boundary = "ANN/vector index belongs in NullPantry service", .runtime_config_json = "{\"selectable_as\":[\"vectors\"],\"required\":[\"vector_base_url\",\"vector_collection\"],\"env\":[\"NULLPANTRY_VECTOR_BACKEND=qdrant\",\"NULLPANTRY_VECTOR_BASE_URL\",\"NULLPANTRY_QDRANT_URL\",\"NULLPANTRY_VECTOR_COLLECTION\"],\"cli\":[\"--vector-backend qdrant\",\"--vector-base-url\",\"--vector-collection\"]}", .capabilities = .{ .outbox = true, .vector = true, .vector_index = true }, .remote_primary_supported = true },
    .{ .kind = .lancedb, .primary_role = .vectors, .description = "ANN vector database SDK adapter", .durability = "durable", .provides_json = "[\"vector\",\"sdk_process\"]", .primary_for = "vector", .nullpantry_strategy = "native LanceDB SDK process adapter for vector upsert/search/delete/reset plus canonical reconcile/rebuild", .nullclaw_boundary = "NullClaw lancedb memory state maps to NullPantry canonical agent memory plus LanceDB vector projection; LanceDB is not the source-of-truth memory store", .nullclaw_replacement_json = "{\"agent_memory\":\"native\",\"records\":\"sqlite_or_postgres\",\"vectors\":\"lancedb\",\"state_backend\":\"canonical_records\",\"vector_index_backend\":\"lancedb\",\"notes\":[\"store exact agent memory in the canonical NullPantry backend\",\"configure NULLPANTRY_VECTOR_BACKEND=lancedb for ANN recall\",\"hydrate vector hits through canonical ACL/provenance before returning text\"]}", .runtime_config_json = "{\"selectable_as\":[\"vectors\"],\"required\":[\"lancedb_uri\"],\"env\":[\"NULLPANTRY_VECTOR_BACKEND=lancedb\",\"NULLPANTRY_LANCEDB_URI\",\"NULLPANTRY_LANCEDB_COMMAND\"],\"cli\":[\"--vector-backend lancedb\",\"--lancedb-uri\",\"--lancedb-command\"]}", .capabilities = .{ .outbox = true, .vector = true, .vector_index = true }, .remote_primary_supported = true },
    .{ .kind = .lancedb_http, .primary_role = .vectors, .description = "LanceDB-compatible HTTP vector adapter service", .durability = "remote", .provides_json = "[\"vector\",\"adapter_service\"]", .primary_for = "vector", .nullpantry_strategy = "explicit HTTP adapter-service contract for LanceDB-compatible upsert/search/delete/reset when the SDK process adapter is not used; canonical ACL, provenance, text, and lifecycle remain in NullPantry", .nullclaw_boundary = "HTTP vector adapter service belongs behind NullPantry vector runtime, not in NullClaw core", .runtime_config_json = "{\"selectable_as\":[\"vectors\"],\"required\":[\"lancedb_url_or_vector_base_url\"],\"env\":[\"NULLPANTRY_VECTOR_BACKEND=lancedb_http\",\"NULLPANTRY_LANCEDB_URL\",\"NULLPANTRY_VECTOR_BASE_URL\"],\"cli\":[\"--vector-backend lancedb-http\",\"--lancedb-url\",\"--vector-base-url\"]}", .aliases_json = "[\"lancedb-http\",\"lancedb-compatible\"]", .capabilities = .{ .outbox = true, .vector = true, .vector_index = true }, .remote_primary_supported = true },
    .{ .kind = .weaviate, .primary_role = .vectors, .description = "Weaviate vector and hybrid search projection", .durability = "durable", .provides_json = "[\"vector\",\"bm25\",\"hybrid_search\",\"metadata_filters\"]", .primary_for = "vector,search", .nullpantry_strategy = "Weaviate REST/GraphQL runtime adapter for object upsert, vector search, and rebuildable hybrid search projections; canonical text, ACL, provenance, lifecycle, and source records remain in NullPantry", .nullclaw_boundary = "vector and hybrid search engines belong behind NullPantry retrieval hydration, not as direct NullClaw memory state", .runtime_config_json = "{\"selectable_as\":[\"vectors\",\"search\"],\"required\":[\"weaviate_url\",\"weaviate_collection\"],\"env\":[\"NULLPANTRY_VECTOR_BACKEND=weaviate\",\"NULLPANTRY_WEAVIATE_URL\",\"NULLPANTRY_WEAVIATE_API_KEY\",\"NULLPANTRY_WEAVIATE_COLLECTION\"],\"cli\":[\"--vector-backend weaviate\",\"--weaviate-url\",\"--weaviate-api-key\",\"--weaviate-collection\"]}", .capabilities = .{ .outbox = true, .vector = true, .vector_index = true, .search = true, .search_index = true }, .remote_primary_supported = true },
    .{ .kind = .chroma, .primary_role = .vectors, .description = "Chroma developer-friendly vector/search projection", .durability = "durable", .provides_json = "[\"vector\",\"metadata_filters\",\"full_text_filters\",\"hybrid_search\"]", .primary_for = "vector,search", .nullpantry_strategy = "Chroma v2 HTTP runtime adapter for collection record upsert/query/delete against a configured tenant/database/collection id; it is a rebuildable projection hydrated through canonical NullPantry ACLs", .nullclaw_boundary = "Chroma is a vector/search projection behind NullPantry, not a canonical memory store for NullClaw", .runtime_config_json = "{\"selectable_as\":[\"vectors\",\"search\"],\"required\":[\"chroma_url\",\"chroma_collection_id\"],\"env\":[\"NULLPANTRY_VECTOR_BACKEND=chroma\",\"NULLPANTRY_CHROMA_URL\",\"NULLPANTRY_CHROMA_TOKEN\",\"NULLPANTRY_CHROMA_TENANT\",\"NULLPANTRY_CHROMA_DATABASE\",\"NULLPANTRY_CHROMA_COLLECTION_ID\"],\"cli\":[\"--vector-backend chroma\",\"--chroma-url\",\"--chroma-token\",\"--chroma-tenant\",\"--chroma-database\",\"--chroma-collection-id\"]}", .capabilities = .{ .outbox = true, .vector = true, .vector_index = true, .search = true, .search_index = true }, .remote_primary_supported = true },
    .{ .kind = .opensearch, .primary_role = .search, .description = "OpenSearch keyword/vector/hybrid search projection", .durability = "durable", .provides_json = "[\"search\",\"vector\",\"knn\",\"hybrid_search\"]", .primary_for = "search,vector", .nullpantry_strategy = "OpenSearch REST runtime adapter for index upsert/delete/reset and k-NN search; enterprise search infrastructure remains a derived projection and NullPantry owns canonical records, ACL, provenance, lifecycle, and rebuilds", .nullclaw_boundary = "enterprise search indexes belong behind NullPantry retrieval, not in NullClaw core state", .runtime_config_json = "{\"selectable_as\":[\"vectors\",\"search\"],\"required\":[\"opensearch_url\",\"opensearch_index\"],\"env\":[\"NULLPANTRY_VECTOR_BACKEND=opensearch\",\"NULLPANTRY_OPENSEARCH_URL\",\"NULLPANTRY_OPENSEARCH_API_KEY\",\"NULLPANTRY_OPENSEARCH_INDEX\"],\"cli\":[\"--vector-backend opensearch\",\"--opensearch-url\",\"--opensearch-api-key\",\"--opensearch-index\"]}", .aliases_json = "[\"open_search\"]", .capabilities = .{ .outbox = true, .vector = true, .vector_index = true, .search = true, .search_index = true }, .remote_primary_supported = true },
    .{ .kind = .neo4j, .primary_role = .graph_projection, .description = "Neo4j external GraphRAG projection", .durability = "durable", .provides_json = "[\"graph_projection\",\"cypher\",\"vector_search\"]", .primary_for = "graph_projection,graphrag", .nullpantry_strategy = "Neo4j HTTP Query/transaction adapter projects canonical Entity/Relation primitives into an enterprise Cypher graph; all writes are parameterized and the native NullPantry graph remains authoritative", .nullclaw_boundary = "external enterprise graph interoperability belongs behind NullPantry's graph projection boundary", .runtime_config_json = "{\"selectable_as\":[\"graph_projection\"],\"required\":[\"neo4j_url\"],\"env\":[\"NULLPANTRY_GRAPH_BACKEND=neo4j\",\"NULLPANTRY_NEO4J_URL\",\"NULLPANTRY_NEO4J_DATABASE\",\"NULLPANTRY_NEO4J_API_KEY\"],\"cli\":[\"--graph-backend neo4j\",\"--neo4j-url\",\"--neo4j-database\",\"--neo4j-api-key\"]}", .capabilities = .{ .graph = true, .graph_index = true, .graph_projection = true, .graph_projection_index = true, .vector = true, .vector_index = true }, .remote_primary_supported = true },
    .{ .kind = .kg, .primary_role = .retrieval, .description = "knowledge graph memory", .durability = "durable", .provides_json = "[\"graph\",\"retrieval_expansion\"]", .primary_for = "graph,retrieval_expansion", .nullpantry_strategy = "native Entity/Relation graph with ACL-aware traversal, graph command retrieval, lifecycle status, and NullClaw kg key compatibility", .nullclaw_boundary = "NullClaw kg backend maps to NullPantry canonical Entity/Relation primitives instead of a separate agent-memory store", .nullclaw_replacement_json = "{\"records\":\"sqlite_or_postgres\",\"graph_backend\":\"native\",\"state_backend\":\"entity_relation_graph\",\"notes\":[\"store graph facts as canonical Entity and Relation objects\",\"use store=kg or __kg:* keys for NullClaw-compatible agent memory commands\",\"graph hits are hydrated through canonical ACL/provenance before returning text\"]}", .runtime_config_json = "{\"selectable_as\":[\"graph_retrieval\"],\"required\":[\"records\"],\"env\":[],\"cli\":[]}", .capabilities = .{ .keyword_rank = true, .transactions = true, .graph = true, .graph_index = true }, .remote_primary_supported = true },
};

pub fn kindEnabled(kind: EngineKind) bool {
    return switch (kind) {
        .none => build_options.enable_engine_none,
        .sqlite => build_options.enable_engine_sqlite,
        .markdown => build_options.enable_engine_markdown,
        .hybrid => build_options.enable_engine_hybrid,
        .qmd => build_options.enable_engine_qmd,
        .memory_lru => build_options.enable_engine_memory_lru,
        .lucid => build_options.enable_engine_lucid,
        .postgres => build_options.enable_engine_postgres,
        .pgvector => build_options.enable_engine_pgvector,
        .redis => build_options.enable_engine_redis,
        .api => build_options.enable_engine_api,
        .supermemory => build_options.enable_engine_supermemory,
        .openviking => build_options.enable_engine_openviking,
        .honcho => build_options.enable_engine_honcho,
        .mem0 => build_options.enable_engine_mem0,
        .hindsight => build_options.enable_engine_hindsight,
        .retaindb => build_options.enable_engine_retaindb,
        .byterover => build_options.enable_engine_byterover,
        .holographic => build_options.enable_engine_holographic,
        .zep => build_options.enable_engine_zep,
        .falkordb => build_options.enable_engine_falkordb,
        .clickhouse => build_options.enable_engine_clickhouse,
        .qdrant => build_options.enable_engine_qdrant,
        .lancedb => build_options.enable_engine_lancedb,
        .lancedb_http => build_options.enable_engine_lancedb_http,
        .weaviate => build_options.enable_engine_weaviate,
        .chroma => build_options.enable_engine_chroma,
        .opensearch => build_options.enable_engine_opensearch,
        .neo4j => build_options.enable_engine_neo4j,
        .kg => build_options.enable_engine_kg,
    };
}

pub const nullclaw_known_backend_names = [_][]const u8{
    "hybrid",
    "none",
    "markdown",
    "memory",
    "api",
    "sqlite",
    "lucid",
    "redis",
    "lancedb",
    "postgres",
    "clickhouse",
    "kg",
};

const nullclaw_memory_operation_coverage_json =
    \\[{"operation":"health_check","status":"covered","surface":"GET /v1/agent/health | GET /v1/health | GET /v1/memory/status"},
    \\{"operation":"store","status":"covered","surface":"PUT /v1/agent/memories/{key} | POST|PUT /v1/memory/store/{key}"},
    \\{"operation":"get","status":"covered","surface":"GET /v1/agent/memories/{key} | GET /v1/memory/get/{key}"},
    \\{"operation":"get_scoped","status":"covered","surface":"GET /v1/agent/memories/{key}?session_id=..."},
    \\{"operation":"list","status":"covered","surface":"GET /v1/agent/memories | GET /v1/memory/list"},
    \\{"operation":"list_paged","status":"covered","surface":"GET /v1/agent/memories?limit=...&offset=... | GET /v1/memory/list?limit=...&offset=..."},
    \\{"operation":"recall_search","status":"covered","surface":"POST /v1/agent/memories/search | POST /v1/search | POST /v1/retrieval/search"},
    \\{"operation":"delete","status":"covered","surface":"DELETE /v1/agent/memories/{key} | POST /v1/memory/delete"},
    \\{"operation":"delete_scoped","status":"covered","surface":"DELETE /v1/agent/memories/{key}?session_id=..."},
    \\{"operation":"count","status":"covered","surface":"GET /v1/agent/memories/count | GET /v1/memory/count"},
    \\{"operation":"session_messages","status":"covered","surface":"GET|POST|DELETE /v1/agent/sessions/{id}/messages"},
    \\{"operation":"session_usage","status":"covered","surface":"GET|PUT|DELETE /v1/agent/sessions/{id}/usage"},
    \\{"operation":"session_history","status":"covered","surface":"GET /v1/agent/history | GET /v1/agent/history/{id}"},
    \\{"operation":"session_compact","status":"covered","surface":"POST /v1/agent/sessions/{id}/compact | POST /v1/agent-sessions/{id}/compact | POST /v1/lifecycle/compact-session"},
    \\{"operation":"count_sessions","status":"covered","surface":"GET /v1/agent/history?limit=0 returns total"},
    \\{"operation":"list_sessions_paged","status":"covered","surface":"GET /v1/agent/history?limit=...&offset=... returns total, limit, offset, sessions"},
    \\{"operation":"count_detailed_messages","status":"covered","surface":"GET /v1/agent/history/{id}?limit=0 returns total"},
    \\{"operation":"load_messages_detailed","status":"covered","surface":"GET /v1/agent/history/{id}?limit=...&offset=... returns total, limit, offset, messages with created_at"},
    \\{"operation":"event_feed","status":"covered","surface":"GET /v1/agent/memory/events | GET /v1/memory/events | GET /v1/feed/events"},
    \\{"operation":"apply","status":"covered","surface":"POST /v1/agent/memory/apply | POST /v1/memory/apply | POST /v1/feed/apply"},
    \\{"operation":"status","status":"covered","surface":"GET /v1/agent/memory/status | GET /v1/memory/status | GET /v1/feed/status"},
    \\{"operation":"checkpoint_export","status":"covered","surface":"GET /v1/agent/memory/checkpoint | GET /v1/memory/checkpoint | GET /v1/feed/checkpoint"},
    \\{"operation":"checkpoint_restore","status":"covered","surface":"POST /v1/agent/memory/checkpoint | POST /v1/memory/checkpoint | POST /v1/feed/checkpoint"},
    \\{"operation":"compact","status":"covered","surface":"POST /v1/agent/memory/compact | POST /v1/memory/compact | POST /v1/feed/compact"},
    \\{"operation":"cursor_floor_expired","status":"covered","surface":"410 cursor_expired"},
    \\{"operation":"merge_object","status":"covered","surface":"feed/apply operation=merge_object"},
    \\{"operation":"merge_string_set","status":"covered","surface":"feed/apply operation=merge_string_set"},
    \\{"operation":"reindex","status":"covered","surface":"POST /v1/agent/memory/reindex | POST /v1/memory/reindex | POST /v1/vector/rebuild"},
    \\{"operation":"drain_outbox","status":"covered","surface":"POST /v1/agent/memory/drain-outbox | POST /v1/memory/drain-outbox | POST /v1/vector/outbox/run"},
    \\{"operation":"stats_diagnostics","status":"covered","surface":"GET /v1/agent/memory/stats | GET /v1/lifecycle/diagnostics"},
    \\{"operation":"hygiene","status":"covered","surface":"POST /v1/memory/hygiene | POST /v1/lifecycle/hygiene"},
    \\{"operation":"export_jsonl","status":"covered","surface":"POST /v1/memory/export-jsonl | POST /v1/lifecycle/export-jsonl"},
    \\{"operation":"brain_db_import","status":"covered","surface":"POST /v1/lifecycle/import-brain-db"},
    \\{"operation":"multi_agent_isolation","status":"covered","surface":"actor_id + owner_id + scope + token principal ACL"},
    \\{"operation":"shared_scoped_memory","status":"covered","surface":"scope=team:* | project:* | public plus write/verify/delete scopes"},
    \\{"operation":"storage_selectors","status":"covered","surface":"storage/store/stores selectors: native, runtime, named, subset, all"}]
;

pub fn appendNullClawMemoryParityJson(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    try out.appendSlice(allocator,
        \\{"contract":"nullclaw-memory-parity.v1","service":"nullpantry","audited_against":"nullclaw/nullclaw@ef297a1a0b54281f7ef10b608517c7b521f72b42","source_pr":"nullclaw/nullclaw#711@7a66c028565d0dab74715fba2ecc559fdb6f3b28","position":"NullPantry is the central platform memory and knowledge service; NullClaw should keep simple local baselines and use NullPantry for shared, remote, vector, lifecycle, graph, and governed knowledge memory.","adapter_namespace":"/v1/agent","native_memory_namespace":"/v1/memory","native_feed_namespace":"/v1/feed","known_nullclaw_backends":
    );
    try appendStringArray(allocator, out, nullclaw_known_backend_names[0..]);
    try out.appendSlice(allocator,
        \\,"operation_coverage":
    );
    try out.appendSlice(allocator, nullclaw_memory_operation_coverage_json);
    try out.appendSlice(allocator, ",\"backend_mappings\":[");
    for (nullclaw_known_backend_names, 0..) |backend_name, i| {
        if (i > 0) try out.append(allocator, ',');
        const kind = parse(backend_name) orelse return error.InvalidEngineDescriptor;
        const descriptor = descriptorFor(kind);
        try appendNullClawBackendMappingJson(allocator, out, backend_name, descriptor.*);
    }
    try out.appendSlice(allocator, "],\"nullpantry_superset_components\":[");
    var first = true;
    for (descriptors) |descriptor| {
        if (isNullClawKnownBackend(descriptor.kind.name())) continue;
        if (!first) try out.append(allocator, ',');
        first = false;
        try appendSupersetComponentJson(allocator, out, descriptor);
    }
    try out.appendSlice(allocator, "]}");
}

fn appendNullClawBackendMappingJson(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), backend_name: []const u8, descriptor: EngineDescriptor) !void {
    try out.appendSlice(allocator, "{\"nullclaw_backend\":");
    try json.appendString(out, allocator, backend_name);
    try out.appendSlice(allocator, ",\"nullpantry_engine\":");
    try json.appendString(out, allocator, descriptor.kind.name());
    try out.appendSlice(allocator, ",\"nullclaw_engine_token\":");
    try json.appendString(out, allocator, descriptor.nullclawEngineToken());
    try out.appendSlice(allocator, ",\"replacement_mode\":");
    try json.appendString(out, allocator, nullClawReplacementMode(descriptor));
    try out.appendSlice(allocator, ",\"coverage_status\":");
    try json.appendString(out, allocator, nullClawCoverageStatus(descriptor));
    try out.appendSlice(allocator, ",\"recommended_remote_namespace\":\"/v1/agent\",\"recommended_native_namespace\":\"/v1/memory\",\"auto_save_default\":");
    try out.appendSlice(allocator, jsonBool(descriptor.auto_save_default));
    try out.appendSlice(allocator, ",\"capabilities\":");
    try appendCapabilitiesJson(allocator, out, descriptor.capabilities);
    try out.print(
        allocator,
        ",\"requirements\":{{\"db_path\":{s},\"workspace\":{s}}},\"runtime_config\":{s},\"feed_object_types\":{s},\"lifecycle_object_types\":{s},\"nullclaw_replacement\":{s},\"notes\":",
        .{
            jsonBool(descriptor.requirements.db_path),
            jsonBool(descriptor.requirements.workspace),
            descriptor.runtime_config_json,
            descriptor.feed_object_types_json,
            descriptor.lifecycle_object_types_json,
            descriptor.nullclaw_replacement_json,
        },
    );
    try json.appendString(out, allocator, descriptor.nullpantry_strategy);
    try out.append(allocator, '}');
}

fn appendSupersetComponentJson(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), descriptor: EngineDescriptor) !void {
    try out.appendSlice(allocator, "{\"name\":");
    try json.appendString(out, allocator, descriptor.kind.name());
    try out.appendSlice(allocator, ",\"provides\":");
    try out.appendSlice(allocator, descriptor.provides_json);
    try out.appendSlice(allocator, ",\"primary_for\":");
    try json.appendString(out, allocator, descriptor.primary_for);
    try out.appendSlice(allocator, ",\"runtime_config\":");
    try out.appendSlice(allocator, descriptor.runtime_config_json);
    try out.appendSlice(allocator, ",\"notes\":");
    try json.appendString(out, allocator, descriptor.nullpantry_strategy);
    try out.append(allocator, '}');
}

fn nullClawReplacementMode(descriptor: EngineDescriptor) []const u8 {
    return switch (descriptor.kind) {
        .none => "disabled_runtime",
        .markdown => "governed_filesystem_import_export",
        .lucid => "projection_composition",
        .lancedb => "canonical_state_plus_vector_projection",
        .kg => "native_knowledge_graph",
        .hybrid => "canonical_record_plus_governed_filesystem",
        else => if (descriptor.capabilities.agent_memory_store)
            "direct_agent_memory_runtime"
        else if (descriptor.capabilities.record_store)
            "canonical_record_store"
        else
            "platform_component",
    };
}

fn nullClawCoverageStatus(descriptor: EngineDescriptor) []const u8 {
    return switch (descriptor.kind) {
        .markdown, .lucid, .lancedb, .hybrid => "covered_by_richer_nullpantry_composition",
        .kg => "covered_by_native_graph_primitives",
        else => "covered",
    };
}

fn isNullClawKnownBackend(name: []const u8) bool {
    for (nullclaw_known_backend_names) |known| {
        if (std.mem.eql(u8, known, name)) return true;
    }
    return false;
}

fn appendStringArray(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), values: []const []const u8) !void {
    try out.append(allocator, '[');
    for (values, 0..) |value, i| {
        if (i > 0) try out.append(allocator, ',');
        try json.appendString(out, allocator, value);
    }
    try out.append(allocator, ']');
}

pub fn parse(name: []const u8) ?EngineKind {
    if (std.mem.eql(u8, name, "memory") or std.mem.eql(u8, name, "in_memory")) return .memory_lru;
    if (std.mem.eql(u8, name, "sqlite_markdown")) return .hybrid;
    if (std.mem.eql(u8, name, "lancedb-http") or std.mem.eql(u8, name, "lancedb-compatible")) return .lancedb_http;
    if (std.mem.eql(u8, name, "holographic_sqlite")) return .holographic;
    if (std.mem.eql(u8, name, "retaindb_api") or std.mem.eql(u8, name, "retain_db")) return .retaindb;
    if (std.mem.eql(u8, name, "zep_api")) return .zep;
    if (std.mem.eql(u8, name, "falkor") or std.mem.eql(u8, name, "falkordb_graph")) return .falkordb;
    if (std.mem.eql(u8, name, "open_search")) return .opensearch;
    for (descriptors) |descriptor| {
        if (std.mem.eql(u8, descriptor.kind.name(), name)) return descriptor.kind;
    }
    return null;
}

pub fn descriptorFor(kind: EngineKind) *const EngineDescriptor {
    for (&descriptors) |*descriptor| {
        if (descriptor.kind == kind) return descriptor;
    }
    unreachable;
}

pub fn nullclawEngineTokenForName(name: []const u8) ?[]const u8 {
    const kind = parse(name) orelse return null;
    return kind.nullclawEngineToken();
}

pub fn appendDescriptorsJson(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    return appendDescriptorsJsonFiltered(allocator, out, true);
}

pub fn appendAllDescriptorsJson(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    return appendDescriptorsJsonFiltered(allocator, out, false);
}

const retrieval_steps = [_][]const u8{
    "query_expansion",
    "keyword_search",
    "vector_search",
    "graph_expansion",
    "rrf_merge",
    "min_relevance",
    "temporal_decay",
    "mmr_diversity",
    "llm_rerank",
    "limit",
    "acl_hydrate",
};

const future_engine_candidates_json =
    \\[{"name":"graphiti","primary_role":"graph_projection","roles":["graph_projection","agent_memory"],"status":"future_adapter","reason":"temporal knowledge graph projection for agents; hydrate through canonical NullPantry ACLs and citations"},
    \\{"name":"letta","primary_role":"agent_memory","roles":["agent_memory"],"status":"future_adapter","reason":"MemGPT-style core/archival agent memory architecture; useful as an external runtime adapter, not as NullPantry's canonical record store"},
    \\{"name":"pinecone","primary_role":"vectors","roles":["vectors"],"status":"future_adapter","reason":"managed vector and hybrid search candidate; rebuildable projection, not source of truth"},
    \\{"name":"milvus","primary_role":"vectors","roles":["vectors"],"status":"future_adapter","reason":"large-scale vector index candidate; rebuildable projection"},
    \\{"name":"zilliz","primary_role":"vectors","roles":["vectors"],"status":"future_adapter","reason":"managed Milvus-class vector index candidate; rebuildable projection"},
    \\{"name":"elasticsearch","primary_role":"search","roles":["search","vectors"],"status":"future_adapter","reason":"hybrid keyword/vector/ranking backend candidate; not canonical record storage"},
    \\{"name":"vespa","primary_role":"search","roles":["search","vectors"],"status":"future_adapter","reason":"advanced hybrid retrieval and ranking backend candidate; not canonical record storage"}]
;

pub fn appendEngineRolesJson(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    return appendEngineRolesJsonFiltered(allocator, out, true);
}

pub fn appendAllEngineRolesJson(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    return appendEngineRolesJsonFiltered(allocator, out, false);
}

pub fn appendRetrievalJson(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    try out.appendSlice(allocator, "{\"is_backend\":false,\"source_of_truth\":false,\"derived_from\":[\"records\",\"vectors\",\"knowledge_graph\"],\"components\":");
    try appendStringArray(allocator, out, retrieval_steps[0..]);
    try out.appendSlice(allocator, ",\"candidate_sources\":[\"keyword\",\"vector\",\"entity_relation_graph\",\"agent_memory\",\"projection\"],\"final_gate\":\"acl_hydrate\",\"notes\":");
    try json.appendString(out, allocator, "Retrieval is a pipeline over canonical records and rebuildable indexes; it is not a selectable storage engine.");
    try out.append(allocator, '}');
}

pub fn appendFutureCandidatesJson(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    try out.appendSlice(allocator, future_engine_candidates_json);
}

fn appendEngineRolesJsonFiltered(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), compiled_only: bool) !void {
    try out.appendSlice(allocator, "{\"records\":");
    try appendEngineRole(allocator, out, .records, compiled_only, true, false, "canonical source of truth for Source, Artifact, MemoryAtom, Entity, Relation, ACL, lifecycle, feed, and migrations");
    try out.appendSlice(allocator, ",\"agent_memory\":");
    try appendEngineRole(allocator, out, .agent_memory, compiled_only, false, false, "runtime memory for isolated or shared agents; external services are projections behind NullPantry permissions");
    try out.appendSlice(allocator, ",\"vectors\":");
    try appendEngineRole(allocator, out, .vectors, compiled_only, false, true, "derived vector index; rebuildable from canonical records and never the source of truth");
    try out.appendSlice(allocator, ",\"retrieval\":");
    try appendRetrievalRole(allocator, out, compiled_only);
    try out.appendSlice(allocator, ",\"supporting_roles\":{\"files\":");
    try appendSupportingRole(allocator, out, compiled_only, .import_export, false, true, "filesystem and connector import/export surfaces that normalize into canonical records");
    try out.appendSlice(allocator, ",\"projection\":");
    try appendSupportingRole(allocator, out, compiled_only, .projection, false, true, "local or external context projections hydrated through canonical ACLs");
    try out.appendSlice(allocator, ",\"search\":");
    try appendSupportingRole(allocator, out, compiled_only, .search, false, true, "hybrid keyword/vector/ranking indexes such as Elasticsearch, OpenSearch, or Vespa; rebuildable and ACL-hydrated from canonical records");
    try out.appendSlice(allocator, ",\"graph_projection\":");
    try appendSupportingRole(allocator, out, compiled_only, .graph_projection, false, true, "external graph projections such as Neo4j or temporal memory graphs; canonical Entity/Relation records remain authoritative");
    try out.appendSlice(allocator, ",\"analytics\":");
    try appendSupportingRole(allocator, out, compiled_only, .analytics, false, true, "analytics and audit export backends; not canonical knowledge storage");
    try out.appendSlice(allocator, "}}");
}

fn appendEngineRole(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    role: EngineRole,
    compiled_only: bool,
    source_of_truth: bool,
    derived: bool,
    notes: []const u8,
) !void {
    try out.appendSlice(allocator, "{\"source_of_truth\":");
    try out.appendSlice(allocator, jsonBool(source_of_truth));
    try out.appendSlice(allocator, ",\"derived\":");
    try out.appendSlice(allocator, jsonBool(derived));
    try out.appendSlice(allocator, ",\"engines\":");
    try appendEngineNamesByRole(allocator, out, role, compiled_only);
    try out.appendSlice(allocator, ",\"notes\":");
    try json.appendString(out, allocator, notes);
    try out.append(allocator, '}');
}

const SupportingRole = enum {
    import_export,
    projection,
    search,
    graph_projection,
    analytics,
};

fn appendSupportingRole(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    compiled_only: bool,
    supporting_role: SupportingRole,
    source_of_truth: bool,
    derived: bool,
    notes: []const u8,
) !void {
    try out.appendSlice(allocator, "{\"source_of_truth\":");
    try out.appendSlice(allocator, jsonBool(source_of_truth));
    try out.appendSlice(allocator, ",\"derived\":");
    try out.appendSlice(allocator, jsonBool(derived));
    try out.appendSlice(allocator, ",\"engines\":");
    try appendEngineNamesByCapability(allocator, out, compiled_only, supporting_role);
    try out.appendSlice(allocator, ",\"notes\":");
    try json.appendString(out, allocator, notes);
    try out.append(allocator, '}');
}

fn appendRetrievalRole(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), compiled_only: bool) !void {
    try out.appendSlice(allocator, "{\"is_backend\":false,\"source_of_truth\":false,\"derived\":false,\"components\":");
    try appendStringArray(allocator, out, retrieval_steps[0..]);
    try out.appendSlice(allocator, ",\"native_components\":");
    try appendEngineNamesByRole(allocator, out, .retrieval, compiled_only);
    try out.appendSlice(allocator, ",\"notes\":");
    try json.appendString(out, allocator, "Pipeline logic over storage and indexes: query expansion, keyword/vector/graph candidates, RRF, temporal decay, MMR, rerank, limit, and ACL hydration.");
    try out.append(allocator, '}');
}

fn appendEngineNamesByRole(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), role: EngineRole, compiled_only: bool) !void {
    try out.append(allocator, '[');
    var written: usize = 0;
    for (descriptors) |descriptor| {
        if (descriptor.primary_role != role) continue;
        if (compiled_only and !kindEnabled(descriptor.kind)) continue;
        if (written > 0) try out.append(allocator, ',');
        try json.appendString(out, allocator, descriptor.kind.name());
        written += 1;
    }
    try out.append(allocator, ']');
}

fn appendEngineNamesByCapability(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), compiled_only: bool, supporting_group: SupportingRole) !void {
    try out.append(allocator, '[');
    var written: usize = 0;
    for (descriptors) |descriptor| {
        if (compiled_only and !kindEnabled(descriptor.kind)) continue;
        const matches = switch (supporting_group) {
            .import_export => descriptor.capabilities.import_export or descriptor.capabilities.filesystem_import_export,
            .projection => descriptor.capabilities.projection or descriptor.capabilities.projection_index,
            .search => descriptor.capabilities.search or descriptor.capabilities.search_index,
            .graph_projection => descriptor.capabilities.graph_projection or descriptor.capabilities.graph_projection_index,
            .analytics => descriptor.capabilities.analytics or descriptor.capabilities.analytics_export,
        };
        if (!matches) continue;
        if (written > 0) try out.append(allocator, ',');
        try json.appendString(out, allocator, descriptor.kind.name());
        written += 1;
    }
    try out.append(allocator, ']');
}

fn appendDescriptorsJsonFiltered(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), compiled_only: bool) !void {
    try out.append(allocator, '[');
    var written: usize = 0;
    for (descriptors) |descriptor| {
        if (compiled_only and !kindEnabled(descriptor.kind)) continue;
        if (written > 0) try out.append(allocator, ',');
        try appendDescriptorJson(allocator, out, descriptor);
        written += 1;
    }
    try out.append(allocator, ']');
}

fn appendDescriptorJson(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), descriptor: EngineDescriptor) !void {
    try out.appendSlice(allocator, "{\"name\":");
    try json.appendString(out, allocator, descriptor.kind.name());
    try out.appendSlice(allocator, ",\"primary_role\":");
    try json.appendString(out, allocator, descriptor.primary_role.name());
    try out.appendSlice(allocator, ",\"roles\":");
    try appendDescriptorRolesJson(allocator, out, descriptor);
    try out.appendSlice(allocator, ",\"aliases\":");
    try out.appendSlice(allocator, descriptor.aliases_json);
    try out.appendSlice(allocator, ",\"nullclaw_engine_token\":");
    try json.appendString(out, allocator, descriptor.nullclawEngineToken());
    try out.appendSlice(allocator, ",\"description\":");
    try json.appendString(out, allocator, descriptor.description);
    try out.appendSlice(allocator, ",\"durability\":");
    try json.appendString(out, allocator, descriptor.durability);
    try out.appendSlice(allocator, ",\"provides\":");
    try out.appendSlice(allocator, descriptor.provides_json);
    try out.appendSlice(allocator, ",\"primary_for\":");
    try json.appendString(out, allocator, descriptor.primary_for);
    try out.appendSlice(allocator, ",\"nullpantry_strategy\":");
    try json.appendString(out, allocator, descriptor.nullpantry_strategy);
    try out.appendSlice(allocator, ",\"nullclaw_boundary\":");
    try json.appendString(out, allocator, descriptor.nullclaw_boundary);
    try out.appendSlice(allocator, ",\"nullclaw_replacement\":");
    try out.appendSlice(allocator, descriptor.nullclaw_replacement_json);
    try out.appendSlice(allocator, ",\"runtime_config\":");
    try out.appendSlice(allocator, descriptor.runtime_config_json);
    try out.appendSlice(allocator, ",\"auto_save_default\":");
    try out.appendSlice(allocator, jsonBool(descriptor.auto_save_default));
    try out.appendSlice(allocator, ",\"capabilities\":");
    try appendCapabilitiesJson(allocator, out, descriptor.capabilities);
    try out.print(
        allocator,
        ",\"requirements\":{{\"db_path\":{s},\"workspace\":{s}}},\"feed_object_types\":{s},\"lifecycle_object_types\":{s},\"runtime_supported\":{s},\"remote_primary_supported\":{s}}}",
        .{
            jsonBool(descriptor.requirements.db_path),
            jsonBool(descriptor.requirements.workspace),
            descriptor.feed_object_types_json,
            descriptor.lifecycle_object_types_json,
            jsonBool(descriptor.runtime_supported),
            jsonBool(descriptor.remote_primary_supported),
        },
    );
}

fn appendDescriptorRolesJson(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), descriptor: EngineDescriptor) !void {
    try out.append(allocator, '[');
    var first = true;
    try appendDescriptorRole(allocator, out, &first, descriptor.primary_role.name());
    if (descriptor.capabilities.import_export or descriptor.capabilities.filesystem_import_export) {
        try appendDescriptorRoleIfDifferent(allocator, out, &first, descriptor.primary_role, .files);
    }
    if (descriptor.capabilities.projection or descriptor.capabilities.projection_index) {
        try appendDescriptorRoleIfDifferent(allocator, out, &first, descriptor.primary_role, .projection);
    }
    if (descriptor.capabilities.search or descriptor.capabilities.search_index) {
        try appendDescriptorRoleIfDifferent(allocator, out, &first, descriptor.primary_role, .search);
    }
    if (descriptor.capabilities.graph_projection or descriptor.capabilities.graph_projection_index) {
        try appendDescriptorRoleIfDifferent(allocator, out, &first, descriptor.primary_role, .graph_projection);
    }
    if (descriptor.capabilities.analytics or descriptor.capabilities.analytics_export) {
        try appendDescriptorRoleIfDifferent(allocator, out, &first, descriptor.primary_role, .analytics);
    }
    try out.append(allocator, ']');
}

fn appendDescriptorRoleIfDifferent(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    first: *bool,
    primary: EngineRole,
    role: EngineRole,
) !void {
    if (primary == role) return;
    try appendDescriptorRole(allocator, out, first, role.name());
}

fn appendDescriptorRole(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), first: *bool, role_name: []const u8) !void {
    if (!first.*) try out.append(allocator, ',');
    first.* = false;
    try json.appendString(out, allocator, role_name);
}

fn appendCapabilitiesJson(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), capabilities: EngineCapabilities) !void {
    try out.print(
        allocator,
        "{{\"keyword_rank\":{s},\"session_store\":{s},\"transactions\":{s},\"outbox\":{s},\"feed\":{s},\"vector\":{s},\"graph\":{s},\"analytics\":{s},\"import_export\":{s},\"projection\":{s},\"cache\":{s},\"lifecycle\":{s}",
        .{
            jsonBool(capabilities.keyword_rank),
            jsonBool(capabilities.session_store),
            jsonBool(capabilities.transactions),
            jsonBool(capabilities.outbox),
            jsonBool(capabilities.feed),
            jsonBool(capabilities.vector),
            jsonBool(capabilities.graph),
            jsonBool(capabilities.analytics),
            jsonBool(capabilities.import_export),
            jsonBool(capabilities.projection),
            jsonBool(capabilities.cache),
            jsonBool(capabilities.lifecycle),
        },
    );
    try out.print(
        allocator,
        ",\"record_store\":{s},\"agent_memory_store\":{s},\"session_history\":{s},\"usage_store\":{s},\"feed_peer\":{s},\"vector_index\":{s},\"search_index\":{s},\"graph_index\":{s},\"graph_projection_index\":{s},\"analytics_export\":{s},\"filesystem_import_export\":{s},\"composition_profile\":{s},\"projection_index\":{s},\"lifecycle_reducer\":{s},\"remote_api_proxy\":{s},\"search\":{s},\"graph_projection\":{s}}}",
        .{
            jsonBool(capabilities.record_store),
            jsonBool(capabilities.agent_memory_store),
            jsonBool(capabilities.session_history),
            jsonBool(capabilities.usage_store),
            jsonBool(capabilities.feed_peer),
            jsonBool(capabilities.vector_index),
            jsonBool(capabilities.search_index),
            jsonBool(capabilities.graph_index),
            jsonBool(capabilities.graph_projection_index),
            jsonBool(capabilities.analytics_export),
            jsonBool(capabilities.filesystem_import_export),
            jsonBool(capabilities.composition_profile),
            jsonBool(capabilities.projection_index),
            jsonBool(capabilities.lifecycle_reducer),
            jsonBool(capabilities.remote_api_proxy),
            jsonBool(capabilities.search),
            jsonBool(capabilities.graph_projection),
        },
    );
}

fn jsonBool(value: bool) []const u8 {
    return if (value) "true" else "false";
}

const JsonRootKind = enum {
    array,
    object,
};

fn expectJsonRoot(raw: []const u8, expected: JsonRootKind) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{});
    defer parsed.deinit();
    switch (expected) {
        .array => try std.testing.expect(parsed.value == .array),
        .object => try std.testing.expect(parsed.value == .object),
    }
}

test "engine descriptors are keyed by kind not enum order" {
    inline for (std.meta.fields(EngineKind)) |field| {
        const kind: EngineKind = @enumFromInt(field.value);
        const descriptor = descriptorFor(kind);
        try std.testing.expectEqual(kind, descriptor.kind);
        try std.testing.expectEqualStrings(kind.name(), descriptor.kind.name());
        try std.testing.expect(parse(descriptor.kind.name()).? == kind);

        var matches: usize = 0;
        for (&descriptors) |candidate| {
            if (candidate.kind == kind) matches += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), matches);
    }
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
    try std.testing.expect(parse("supermemory") == .supermemory);
    try std.testing.expect(parse("openviking") == .openviking);
    try std.testing.expect(parse("honcho") == .honcho);
    try std.testing.expect(parse("mem0") == .mem0);
    try std.testing.expect(parse("hindsight") == .hindsight);
    try std.testing.expect(parse("zep") == .zep);
    try std.testing.expect(parse("zep_api") == .zep);
    try std.testing.expect(parse("falkordb") == .falkordb);
    try std.testing.expect(parse("falkor") == .falkordb);
    try std.testing.expect(parse("clickhouse") == .clickhouse);
    try std.testing.expect(parse("qdrant") == .qdrant);
    try std.testing.expect(parse("lancedb") == .lancedb);
    try std.testing.expect(parse("lancedb_http") == .lancedb_http);
    try std.testing.expect(parse("lancedb-http") == .lancedb_http);
    try std.testing.expect(parse("lancedb-compatible") == .lancedb_http);
    try std.testing.expect(parse("weaviate") == .weaviate);
    try std.testing.expect(parse("chroma") == .chroma);
    try std.testing.expect(parse("opensearch") == .opensearch);
    try std.testing.expect(parse("open_search") == .opensearch);
    try std.testing.expect(parse("neo4j") == .neo4j);
    try std.testing.expect(parse("kg") == .kg);
    try std.testing.expect(parse("unknown") == null);
    try std.testing.expectEqualStrings("sqlite", nullclawEngineTokenForName("hybrid").?);
    try std.testing.expectEqualStrings("memory", nullclawEngineTokenForName("memory_lru").?);
    try std.testing.expectEqualStrings("memory", nullclawEngineTokenForName("memory").?);
    try std.testing.expectEqualStrings("postgres", nullclawEngineTokenForName("postgres").?);
    try std.testing.expect(nullclawEngineTokenForName("unknown") == null);
}

test "engine registry maps backends to NullPantry groups" {
    try std.testing.expectEqual(EngineRole.records, descriptorFor(.sqlite).primary_role);
    try std.testing.expectEqual(EngineRole.records, descriptorFor(.postgres).primary_role);
    try std.testing.expectEqual(EngineRole.files, descriptorFor(.hybrid).primary_role);
    try std.testing.expectEqual(EngineRole.agent_memory, descriptorFor(.markdown).primary_role);
    try std.testing.expectEqual(EngineRole.files, descriptorFor(.qmd).primary_role);
    try std.testing.expectEqual(EngineRole.agent_memory, descriptorFor(.memory_lru).primary_role);
    try std.testing.expectEqual(EngineRole.agent_memory, descriptorFor(.redis).primary_role);
    try std.testing.expectEqual(EngineRole.agent_memory, descriptorFor(.clickhouse).primary_role);
    try std.testing.expectEqual(EngineRole.agent_memory, descriptorFor(.api).primary_role);
    try std.testing.expectEqual(EngineRole.agent_memory, descriptorFor(.supermemory).primary_role);
    try std.testing.expectEqual(EngineRole.agent_memory, descriptorFor(.honcho).primary_role);
    try std.testing.expectEqual(EngineRole.agent_memory, descriptorFor(.zep).primary_role);
    try std.testing.expectEqual(EngineRole.agent_memory, descriptorFor(.falkordb).primary_role);
    try std.testing.expectEqual(EngineRole.vectors, descriptorFor(.pgvector).primary_role);
    try std.testing.expectEqual(EngineRole.vectors, descriptorFor(.qdrant).primary_role);
    try std.testing.expectEqual(EngineRole.vectors, descriptorFor(.lancedb).primary_role);
    try std.testing.expectEqual(EngineRole.vectors, descriptorFor(.weaviate).primary_role);
    try std.testing.expectEqual(EngineRole.vectors, descriptorFor(.chroma).primary_role);
    try std.testing.expectEqual(EngineRole.search, descriptorFor(.opensearch).primary_role);
    try std.testing.expectEqual(EngineRole.projection, descriptorFor(.lucid).primary_role);
    try std.testing.expectEqual(EngineRole.graph_projection, descriptorFor(.neo4j).primary_role);
    try std.testing.expectEqual(EngineRole.retrieval, descriptorFor(.kg).primary_role);
}

test "engine role json separates records runtime memory vectors and retrieval" {
    const allocator = std.testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    try appendAllEngineRolesJson(allocator, &out);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, out.items, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    const obj = parsed.value.object;
    try std.testing.expect(obj.get("records").?.object.get("source_of_truth").?.bool);
    try std.testing.expect(jsonArrayContains(obj.get("records").?.object.get("engines").?.array.items, "sqlite"));
    try std.testing.expect(jsonArrayContains(obj.get("records").?.object.get("engines").?.array.items, "postgres"));
    try std.testing.expect(!jsonArrayContains(obj.get("records").?.object.get("engines").?.array.items, "hybrid"));
    try std.testing.expect(jsonArrayContains(obj.get("agent_memory").?.object.get("engines").?.array.items, "redis"));
    try std.testing.expect(jsonArrayContains(obj.get("agent_memory").?.object.get("engines").?.array.items, "supermemory"));
    try std.testing.expect(jsonArrayContains(obj.get("agent_memory").?.object.get("engines").?.array.items, "zep"));
    try std.testing.expect(jsonArrayContains(obj.get("agent_memory").?.object.get("engines").?.array.items, "falkordb"));
    try std.testing.expect(jsonArrayContains(obj.get("vectors").?.object.get("engines").?.array.items, "qdrant"));
    try std.testing.expect(jsonArrayContains(obj.get("vectors").?.object.get("engines").?.array.items, "lancedb"));
    try std.testing.expect(jsonArrayContains(obj.get("vectors").?.object.get("engines").?.array.items, "weaviate"));
    try std.testing.expect(jsonArrayContains(obj.get("vectors").?.object.get("engines").?.array.items, "chroma"));
    const pipeline = obj.get("retrieval").?.object;
    try std.testing.expect(!pipeline.get("is_backend").?.bool);
    try std.testing.expect(!pipeline.get("source_of_truth").?.bool);
    try std.testing.expect(jsonArrayContains(pipeline.get("components").?.array.items, "rrf_merge"));
    try std.testing.expect(jsonArrayContains(pipeline.get("components").?.array.items, "acl_hydrate"));
    try std.testing.expect(jsonArrayContains(pipeline.get("native_components").?.array.items, "kg"));
    const supporting = obj.get("supporting_roles").?.object;
    try std.testing.expect(jsonArrayContains(supporting.get("files").?.object.get("engines").?.array.items, "markdown"));
    try std.testing.expect(jsonArrayContains(supporting.get("files").?.object.get("engines").?.array.items, "hybrid"));
    try std.testing.expect(jsonArrayContains(supporting.get("files").?.object.get("engines").?.array.items, "openviking"));
    try std.testing.expect(jsonArrayContains(supporting.get("projection").?.object.get("engines").?.array.items, "lucid"));
    try std.testing.expect(jsonArrayContains(supporting.get("projection").?.object.get("engines").?.array.items, "byterover"));
    try std.testing.expect(supporting.get("search").?.object.get("derived").?.bool);
    try std.testing.expect(jsonArrayContains(supporting.get("search").?.object.get("engines").?.array.items, "opensearch"));
    try std.testing.expect(supporting.get("graph_projection").?.object.get("derived").?.bool);
    try std.testing.expect(jsonArrayContains(supporting.get("graph_projection").?.object.get("engines").?.array.items, "neo4j"));
    try std.testing.expect(jsonArrayContains(supporting.get("analytics").?.object.get("engines").?.array.items, "clickhouse"));
}

test "engine future candidates use engine roles" {
    const allocator = std.testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    try appendFutureCandidatesJson(allocator, &out);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, out.items, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .array);

    try std.testing.expect(jsonObjectArrayContainsStringField(parsed.value.array.items, "name", "graphiti"));
    try std.testing.expect(jsonObjectArrayContainsStringField(parsed.value.array.items, "name", "letta"));
    try std.testing.expect(jsonObjectArrayContainsStringField(parsed.value.array.items, "name", "pinecone"));
    try std.testing.expect(jsonObjectArrayContainsStringField(parsed.value.array.items, "name", "elasticsearch"));
    try std.testing.expect(jsonObjectArrayContainsStringField(parsed.value.array.items, "name", "vespa"));
    try std.testing.expect(!jsonObjectArrayContainsStringField(parsed.value.array.items, "name", "zep"));
    try std.testing.expect(!jsonObjectArrayContainsStringField(parsed.value.array.items, "name", "chroma"));
    try std.testing.expect(!jsonObjectArrayContainsStringField(parsed.value.array.items, "name", "weaviate"));
    try std.testing.expect(!jsonObjectArrayContainsStringField(parsed.value.array.items, "name", "opensearch"));
    try std.testing.expect(!jsonObjectArrayContainsStringField(parsed.value.array.items, "name", "neo4j"));

    var saw_pinecone_vector = false;
    var saw_elastic_search = false;
    var saw_graphiti_graph_projection = false;
    for (parsed.value.array.items) |item| {
        const obj = item.object;
        const name = obj.get("name").?.string;
        const primary_role = obj.get("primary_role").?.string;
        const roles = obj.get("roles").?.array.items;
        if (std.mem.eql(u8, name, "pinecone")) {
            saw_pinecone_vector = true;
            try std.testing.expectEqualStrings("vectors", primary_role);
            try std.testing.expect(jsonArrayContains(roles, "vectors"));
        } else if (std.mem.eql(u8, name, "elasticsearch")) {
            saw_elastic_search = true;
            try std.testing.expectEqualStrings("search", primary_role);
            try std.testing.expect(jsonArrayContains(roles, "vectors"));
        } else if (std.mem.eql(u8, name, "graphiti")) {
            saw_graphiti_graph_projection = true;
            try std.testing.expectEqualStrings("graph_projection", primary_role);
            try std.testing.expect(jsonArrayContains(roles, "agent_memory"));
        }
    }
    try std.testing.expect(saw_pinecone_vector);
    try std.testing.expect(saw_elastic_search);
    try std.testing.expect(saw_graphiti_graph_projection);
}

test "engine descriptors keep filesystem backends out of canonical record storage" {
    const markdown = descriptorFor(.markdown);
    try std.testing.expect(markdown.capabilities.filesystem_import_export);
    try std.testing.expect(markdown.capabilities.import_export);
    try std.testing.expect(!markdown.capabilities.record_store);
    try std.testing.expect(markdown.capabilities.agent_memory_store);
    try std.testing.expect(std.mem.indexOf(u8, markdown.runtime_config_json, "\"records\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, markdown.provides_json, "\"record\"") == null);

    const sqlite = descriptorFor(.sqlite);
    try std.testing.expect(sqlite.capabilities.record_store);
    try std.testing.expect(std.mem.indexOf(u8, sqlite.runtime_config_json, "\"records\"") != null);

    const hybrid = descriptorFor(.hybrid);
    try std.testing.expect(!hybrid.capabilities.record_store);
    try std.testing.expect(!hybrid.capabilities.agent_memory_store);
    try std.testing.expect(!hybrid.capabilities.feed);
    try std.testing.expect(!hybrid.capabilities.vector);
    try std.testing.expect(!hybrid.capabilities.lifecycle);
    try std.testing.expect(hybrid.capabilities.composition_profile);
    try std.testing.expect(hybrid.capabilities.filesystem_import_export);
    try std.testing.expect(std.mem.indexOf(u8, hybrid.runtime_config_json, "\"selectable_as\":[\"records\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, hybrid.runtime_config_json, "\"records\"") != null);
}

test "engine descriptor json exposes NullClaw replacement contracts" {
    const allocator = std.testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    try appendAllDescriptorsJson(allocator, &out);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, out.items, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .array);

    var saw_lancedb = false;
    for (parsed.value.array.items) |item| {
        try std.testing.expect(item == .object);
        const obj = item.object;
        const primary_role = obj.get("primary_role") orelse return error.TestUnexpectedResult;
        try std.testing.expect(primary_role == .string);
        const roles = obj.get("roles") orelse return error.TestUnexpectedResult;
        try std.testing.expect(roles == .array);
        try std.testing.expect(jsonArrayContains(roles.array.items, primary_role.string));
        const replacement = obj.get("nullclaw_replacement") orelse return error.TestUnexpectedResult;
        try std.testing.expect(replacement == .object);
        const name = obj.get("name").?.string;
        if (!std.mem.eql(u8, name, "lancedb")) continue;

        saw_lancedb = true;
        const repl = replacement.object;
        try std.testing.expectEqualStrings("native", repl.get("agent_memory").?.string);
        try std.testing.expectEqualStrings("sqlite_or_postgres", repl.get("records").?.string);
        try std.testing.expectEqualStrings("lancedb", repl.get("vectors").?.string);
        try std.testing.expectEqualStrings("canonical_records", repl.get("state_backend").?.string);
        try std.testing.expectEqualStrings("lancedb", repl.get("vector_index_backend").?.string);
        try std.testing.expect(repl.get("notes").? == .array);
    }
    try std.testing.expect(saw_lancedb);
}

test "engine descriptor json escapes text fields" {
    const allocator = std.testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    try appendDescriptorJson(allocator, &out, .{
        .kind = .sqlite,
        .primary_role = .records,
        .description = "quoted \"description\"",
        .durability = "path\\durable",
        .provides_json = "[]",
        .primary_for = "record,\"feed\"",
        .nullpantry_strategy = "strategy with \"quote\"",
        .nullclaw_boundary = "boundary with \\ slash",
    });

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, out.items, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("quoted \"description\"", obj.get("description").?.string);
    try std.testing.expectEqualStrings("path\\durable", obj.get("durability").?.string);
    try std.testing.expectEqualStrings("record,\"feed\"", obj.get("primary_for").?.string);
    try std.testing.expectEqualStrings("strategy with \"quote\"", obj.get("nullpantry_strategy").?.string);
    try std.testing.expectEqualStrings("boundary with \\ slash", obj.get("nullclaw_boundary").?.string);
}

test "engine descriptor raw json fields stay valid" {
    try expectJsonRoot(nullclaw_memory_operation_coverage_json, .array);
    try expectJsonRoot(future_engine_candidates_json, .array);

    for (descriptors) |descriptor| {
        try expectJsonRoot(descriptor.provides_json, .array);
        try expectJsonRoot(descriptor.aliases_json, .array);
        try expectJsonRoot(descriptor.nullclaw_replacement_json, .object);
        try expectJsonRoot(descriptor.runtime_config_json, .object);
        try expectJsonRoot(descriptor.feed_object_types_json, .array);
        try expectJsonRoot(descriptor.lifecycle_object_types_json, .array);
    }
}

test "engine registry json writers produce valid documents" {
    const allocator = std.testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    try appendAllDescriptorsJson(allocator, &out);
    try expectJsonRoot(out.items, .array);
    out.clearRetainingCapacity();

    try appendAllEngineRolesJson(allocator, &out);
    try expectJsonRoot(out.items, .object);
    out.clearRetainingCapacity();

    try appendRetrievalJson(allocator, &out);
    try expectJsonRoot(out.items, .object);
    out.clearRetainingCapacity();

    try appendFutureCandidatesJson(allocator, &out);
    try expectJsonRoot(out.items, .array);
    out.clearRetainingCapacity();

    try appendNullClawMemoryParityJson(allocator, &out);
    try expectJsonRoot(out.items, .object);
}

test "engine descriptor json exposes secondary roles from capabilities" {
    const allocator = std.testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    try appendAllDescriptorsJson(allocator, &out);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, out.items, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .array);

    var saw_hybrid = false;
    var saw_openviking = false;
    var saw_byterover = false;
    var saw_clickhouse = false;
    for (parsed.value.array.items) |item| {
        const obj = item.object;
        const name = obj.get("name").?.string;
        const roles = obj.get("roles").?.array.items;
        if (std.mem.eql(u8, name, "hybrid")) {
            saw_hybrid = true;
            try std.testing.expect(jsonArrayContains(roles, "files"));
            try std.testing.expect(!jsonArrayContains(roles, "records"));
            try std.testing.expect(!jsonArrayContains(roles, "agent_memory"));
            try std.testing.expect(!jsonArrayContains(roles, "vectors"));
        } else if (std.mem.eql(u8, name, "openviking")) {
            saw_openviking = true;
            try std.testing.expect(jsonArrayContains(roles, "agent_memory"));
            try std.testing.expect(jsonArrayContains(roles, "files"));
        } else if (std.mem.eql(u8, name, "byterover")) {
            saw_byterover = true;
            try std.testing.expect(jsonArrayContains(roles, "agent_memory"));
            try std.testing.expect(jsonArrayContains(roles, "projection"));
        } else if (std.mem.eql(u8, name, "clickhouse")) {
            saw_clickhouse = true;
            try std.testing.expect(jsonArrayContains(roles, "agent_memory"));
            try std.testing.expect(jsonArrayContains(roles, "analytics"));
        }
    }
    try std.testing.expect(saw_hybrid);
    try std.testing.expect(saw_openviking);
    try std.testing.expect(saw_byterover);
    try std.testing.expect(saw_clickhouse);
}

test "engine descriptor json exposes runtime configuration contracts" {
    const allocator = std.testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    try appendAllDescriptorsJson(allocator, &out);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, out.items, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .array);

    var saw_postgres = false;
    var saw_redis = false;
    var saw_clickhouse = false;
    var saw_qdrant = false;
    var saw_lancedb = false;

    for (parsed.value.array.items) |item| {
        try std.testing.expect(item == .object);
        const obj = item.object;
        const config = obj.get("runtime_config") orelse return error.TestUnexpectedResult;
        try std.testing.expect(config == .object);
        try std.testing.expect(config.object.get("selectable_as").? == .array);
        try std.testing.expect(config.object.get("required").? == .array);
        try std.testing.expect(config.object.get("env").? == .array);
        try std.testing.expect(config.object.get("cli").? == .array);

        const name = obj.get("name").?.string;
        if (std.mem.eql(u8, name, "postgres")) {
            saw_postgres = true;
            try std.testing.expect(jsonArrayContains(config.object.get("selectable_as").?.array.items, "records"));
            try std.testing.expect(jsonArrayContains(config.object.get("required").?.array.items, "postgres_url"));
            try std.testing.expect(jsonArrayContains(config.object.get("env").?.array.items, "NULLPANTRY_DATABASE_URL"));
            try std.testing.expect(jsonArrayContains(config.object.get("cli").?.array.items, "--postgres-url"));
        } else if (std.mem.eql(u8, name, "redis")) {
            saw_redis = true;
            try std.testing.expect(jsonArrayContains(config.object.get("selectable_as").?.array.items, "agent_memory"));
            try std.testing.expect(jsonArrayContains(config.object.get("selectable_as").?.array.items, "named_agent_memory"));
            try std.testing.expect(jsonArrayContains(config.object.get("required").?.array.items, "redis_url"));
            try std.testing.expect(jsonArrayContains(config.object.get("env").?.array.items, "NULLPANTRY_REDIS_URL"));
            try std.testing.expect(jsonArrayContains(config.object.get("cli").?.array.items, "--redis-url"));
        } else if (std.mem.eql(u8, name, "clickhouse")) {
            saw_clickhouse = true;
            try std.testing.expect(jsonArrayContains(config.object.get("selectable_as").?.array.items, "agent_memory"));
            try std.testing.expect(jsonArrayContains(config.object.get("selectable_as").?.array.items, "analytics"));
            try std.testing.expect(jsonArrayContains(config.object.get("required").?.array.items, "clickhouse_url"));
        } else if (std.mem.eql(u8, name, "qdrant")) {
            saw_qdrant = true;
            try std.testing.expect(jsonArrayContains(config.object.get("selectable_as").?.array.items, "vectors"));
            try std.testing.expect(jsonArrayContains(config.object.get("required").?.array.items, "vector_base_url"));
            try std.testing.expect(jsonArrayContains(config.object.get("env").?.array.items, "NULLPANTRY_VECTOR_BACKEND=qdrant"));
        } else if (std.mem.eql(u8, name, "lancedb")) {
            saw_lancedb = true;
            try std.testing.expect(jsonArrayContains(config.object.get("selectable_as").?.array.items, "vectors"));
            try std.testing.expect(jsonArrayContains(config.object.get("required").?.array.items, "lancedb_uri"));
            try std.testing.expect(jsonArrayContains(config.object.get("env").?.array.items, "NULLPANTRY_VECTOR_BACKEND=lancedb"));
        }
    }

    try std.testing.expect(saw_postgres);
    try std.testing.expect(saw_redis);
    try std.testing.expect(saw_clickhouse);
    try std.testing.expect(saw_qdrant);
    try std.testing.expect(saw_lancedb);
}

test "nullclaw memory parity manifest covers PR backends and richer replacements" {
    const allocator = std.testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    try appendNullClawMemoryParityJson(allocator, &out);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.items, "\"backend_mappings\""));

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, out.items, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("nullclaw-memory-parity.v1", obj.get("contract").?.string);
    try std.testing.expectEqualStrings("/v1/agent", obj.get("adapter_namespace").?.string);
    try std.testing.expectEqualStrings("/v1/memory", obj.get("native_memory_namespace").?.string);

    const known = obj.get("known_nullclaw_backends").?.array;
    try std.testing.expectEqual(nullclaw_known_backend_names.len, known.items.len);
    try std.testing.expect(jsonArrayContains(known.items, "sqlite"));
    try std.testing.expect(jsonArrayContains(known.items, "redis"));
    try std.testing.expect(jsonArrayContains(known.items, "clickhouse"));
    try std.testing.expect(jsonArrayContains(known.items, "lancedb"));
    try std.testing.expect(jsonArrayContains(known.items, "kg"));

    const operations = obj.get("operation_coverage").?.array;
    try std.testing.expect(operations.items.len >= 20);
    try std.testing.expect(jsonObjectArrayContainsStringField(operations.items, "operation", "health_check"));
    try std.testing.expect(jsonObjectArrayContainsStringField(operations.items, "operation", "list_paged"));
    try std.testing.expect(jsonObjectArrayContainsStringField(operations.items, "operation", "session_compact"));
    try std.testing.expect(jsonObjectArrayContainsStringField(operations.items, "operation", "count_sessions"));
    try std.testing.expect(jsonObjectArrayContainsStringField(operations.items, "operation", "list_sessions_paged"));
    try std.testing.expect(jsonObjectArrayContainsStringField(operations.items, "operation", "count_detailed_messages"));
    try std.testing.expect(jsonObjectArrayContainsStringField(operations.items, "operation", "load_messages_detailed"));
    try std.testing.expect(jsonObjectArrayContainsStringField(operations.items, "operation", "merge_object"));
    try std.testing.expect(jsonObjectArrayContainsStringField(operations.items, "operation", "merge_string_set"));
    try std.testing.expect(jsonObjectArrayContainsStringField(operations.items, "operation", "checkpoint_restore"));
    try std.testing.expect(jsonObjectArrayContainsStringField(operations.items, "operation", "multi_agent_isolation"));

    const mappings = obj.get("backend_mappings").?.array;
    try std.testing.expectEqual(nullclaw_known_backend_names.len, mappings.items.len);
    try std.testing.expect(jsonObjectArrayContainsStringField(mappings.items, "nullclaw_backend", "memory"));
    try std.testing.expect(jsonObjectArrayContainsStringField(mappings.items, "nullpantry_engine", "memory_lru"));

    var saw_lancedb_replacement = false;
    var saw_markdown_composition = false;
    var saw_kg_graph_mapping = false;
    for (mappings.items) |item| {
        const mapping = item.object;
        const backend = mapping.get("nullclaw_backend").?.string;
        if (std.mem.eql(u8, backend, "lancedb")) {
            saw_lancedb_replacement = true;
            try std.testing.expectEqualStrings("canonical_state_plus_vector_projection", mapping.get("replacement_mode").?.string);
            try std.testing.expectEqualStrings("covered_by_richer_nullpantry_composition", mapping.get("coverage_status").?.string);
            try std.testing.expectEqualStrings("lancedb", mapping.get("nullclaw_replacement").?.object.get("vectors").?.string);
        } else if (std.mem.eql(u8, backend, "markdown")) {
            saw_markdown_composition = true;
            try std.testing.expectEqualStrings("governed_filesystem_import_export", mapping.get("replacement_mode").?.string);
        } else if (std.mem.eql(u8, backend, "hybrid")) {
            try std.testing.expectEqualStrings("canonical_record_plus_governed_filesystem", mapping.get("replacement_mode").?.string);
            try std.testing.expectEqualStrings("sqlite_or_postgres", mapping.get("nullclaw_replacement").?.object.get("records").?.string);
            try std.testing.expectEqualStrings("markdown", mapping.get("nullclaw_replacement").?.object.get("files").?.string);
        } else if (std.mem.eql(u8, backend, "kg")) {
            saw_kg_graph_mapping = true;
            try std.testing.expectEqualStrings("native_knowledge_graph", mapping.get("replacement_mode").?.string);
            try std.testing.expectEqualStrings("covered_by_native_graph_primitives", mapping.get("coverage_status").?.string);
            try std.testing.expectEqualStrings("native", mapping.get("nullclaw_replacement").?.object.get("graph_backend").?.string);
        }
    }
    try std.testing.expect(saw_lancedb_replacement);
    try std.testing.expect(saw_markdown_composition);
    try std.testing.expect(saw_kg_graph_mapping);

    const superset = obj.get("nullpantry_superset_components").?.array;
    try std.testing.expect(jsonObjectArrayContainsStringField(superset.items, "name", "pgvector"));
    try std.testing.expect(jsonObjectArrayContainsStringField(superset.items, "name", "qdrant"));
    try std.testing.expect(!jsonObjectArrayContainsStringField(superset.items, "name", "kg"));
}

fn jsonArrayContains(items: []const std.json.Value, needle: []const u8) bool {
    for (items) |item| {
        if (item == .string and std.mem.eql(u8, item.string, needle)) return true;
    }
    return false;
}

fn jsonObjectArrayContainsStringField(items: []const std.json.Value, field: []const u8, needle: []const u8) bool {
    for (items) |item| {
        if (item != .object) continue;
        const value = item.object.get(field) orelse continue;
        if (value == .string and std.mem.eql(u8, value.string, needle)) return true;
    }
    return false;
}

test "redis is a real remote agent memory backend" {
    const redis_descriptor = descriptorFor(.redis);
    try std.testing.expect(redis_descriptor.runtime_supported);
    try std.testing.expect(redis_descriptor.remote_primary_supported);
    try std.testing.expect(redis_descriptor.capabilities.agent_memory_store);
    try std.testing.expect(redis_descriptor.capabilities.session_history);
    try std.testing.expect(redis_descriptor.capabilities.usage_store);
    try std.testing.expect(redis_descriptor.capabilities.session_store);
    try std.testing.expect(redis_descriptor.capabilities.transactions);
    try std.testing.expect(redis_descriptor.capabilities.feed);
    try std.testing.expect(redis_descriptor.capabilities.feed_peer);
    try std.testing.expect(redis_descriptor.capabilities.lifecycle_reducer);
    try std.testing.expect(std.mem.indexOf(u8, redis_descriptor.provides_json, "agent_memory") != null);
    try std.testing.expect(std.mem.indexOf(u8, redis_descriptor.provides_json, "feed") != null);
    try std.testing.expect(std.mem.indexOf(u8, redis_descriptor.primary_for, "feed") != null);
    try std.testing.expect(std.mem.indexOf(u8, redis_descriptor.nullpantry_strategy, "RESP") != null);
    try std.testing.expect(std.mem.indexOf(u8, redis_descriptor.nullpantry_strategy, "checkpoint") != null);
    try std.testing.expect(std.mem.indexOf(u8, redis_descriptor.nullclaw_boundary, "NullPantry") != null);
}

test "hybrid and memory descriptors expose NullClaw-style discovery flags" {
    const hybrid_descriptor = descriptorFor(.hybrid);
    try std.testing.expect(!hybrid_descriptor.auto_save_default);
    try std.testing.expect(!hybrid_descriptor.capabilities.record_store);
    try std.testing.expect(!hybrid_descriptor.capabilities.agent_memory_store);
    try std.testing.expect(!hybrid_descriptor.capabilities.session_history);
    try std.testing.expect(!hybrid_descriptor.capabilities.usage_store);
    try std.testing.expect(hybrid_descriptor.capabilities.filesystem_import_export);
    try std.testing.expect(hybrid_descriptor.capabilities.composition_profile);
    try std.testing.expect(!hybrid_descriptor.capabilities.keyword_rank);
    try std.testing.expect(!hybrid_descriptor.capabilities.session_store);
    try std.testing.expect(!hybrid_descriptor.capabilities.transactions);
    try std.testing.expect(!hybrid_descriptor.capabilities.outbox);
    try std.testing.expect(!hybrid_descriptor.capabilities.feed);
    try std.testing.expect(!hybrid_descriptor.capabilities.vector);
    try std.testing.expect(hybrid_descriptor.capabilities.import_export);
    try std.testing.expect(!hybrid_descriptor.capabilities.cache);
    try std.testing.expect(!hybrid_descriptor.capabilities.lifecycle);
    try std.testing.expectEqualStrings("[]", hybrid_descriptor.feed_object_types_json);
    try std.testing.expectEqualStrings("[]", hybrid_descriptor.lifecycle_object_types_json);
    try std.testing.expect(!hybrid_descriptor.requirements.db_path);
    try std.testing.expect(hybrid_descriptor.requirements.workspace);

    const memory_descriptor = descriptorFor(.memory_lru);
    try std.testing.expect(!memory_descriptor.auto_save_default);
    try std.testing.expect(memory_descriptor.capabilities.agent_memory_store);
    try std.testing.expect(memory_descriptor.capabilities.session_history);
    try std.testing.expect(memory_descriptor.capabilities.usage_store);
    try std.testing.expect(!memory_descriptor.capabilities.record_store);
    try std.testing.expect(!memory_descriptor.capabilities.keyword_rank);
    try std.testing.expect(memory_descriptor.capabilities.session_store);
    try std.testing.expect(!memory_descriptor.capabilities.transactions);
    try std.testing.expect(!memory_descriptor.capabilities.outbox);
    try std.testing.expect(memory_descriptor.capabilities.feed);
    try std.testing.expect(memory_descriptor.capabilities.lifecycle);
    try std.testing.expect(std.mem.indexOf(u8, memory_descriptor.provides_json, "feed") != null);
    try std.testing.expect(std.mem.indexOf(u8, memory_descriptor.provides_json, "lifecycle") != null);
    try std.testing.expect(std.mem.indexOf(u8, memory_descriptor.feed_object_types_json, "agent_memory") != null);
    try std.testing.expect(std.mem.indexOf(u8, memory_descriptor.feed_object_types_json, "agent_session_message") != null);
    try std.testing.expect(std.mem.indexOf(u8, memory_descriptor.feed_object_types_json, "source") == null);
    try std.testing.expect(std.mem.indexOf(u8, memory_descriptor.lifecycle_object_types_json, "context_pack") == null);
    try std.testing.expect(!memory_descriptor.requirements.db_path);
    try std.testing.expect(!memory_descriptor.requirements.workspace);
}

test "api is a remote NullPantry-compatible agent memory backend" {
    const descriptor = descriptorFor(.api);
    try std.testing.expect(descriptor.runtime_supported);
    try std.testing.expect(descriptor.remote_primary_supported);
    try std.testing.expect(descriptor.capabilities.agent_memory_store);
    try std.testing.expect(descriptor.capabilities.session_history);
    try std.testing.expect(descriptor.capabilities.usage_store);
    try std.testing.expect(descriptor.capabilities.remote_api_proxy);
    try std.testing.expect(descriptor.capabilities.feed);
    try std.testing.expect(descriptor.capabilities.lifecycle);
    try std.testing.expect(std.mem.indexOf(u8, descriptor.feed_object_types_json, "agent_memory") != null);
    try std.testing.expect(std.mem.indexOf(u8, descriptor.feed_object_types_json, "context_pack") == null);
    try std.testing.expect(std.mem.indexOf(u8, descriptor.provides_json, "agent_memory") != null);
    try std.testing.expect(std.mem.indexOf(u8, descriptor.provides_json, "feed") != null);
    try std.testing.expect(std.mem.indexOf(u8, descriptor.provides_json, "lifecycle") != null);
    try std.testing.expect(std.mem.indexOf(u8, descriptor.nullpantry_strategy, "/v1 API") != null);
    try std.testing.expect(std.mem.indexOf(u8, descriptor.nullpantry_strategy, "remote lifecycle target resolution") != null);
}

test "advanced runtime backends are advertised only after runtime wiring" {
    try std.testing.expect(descriptorFor(.lucid).runtime_supported);
    try std.testing.expect(descriptorFor(.clickhouse).runtime_supported);
    try std.testing.expect(descriptorFor(.pgvector).runtime_supported);
    try std.testing.expect(descriptorFor(.qdrant).runtime_supported);
    try std.testing.expect(descriptorFor(.lancedb).runtime_supported);
    try std.testing.expect(descriptorFor(.lancedb_http).runtime_supported);
    try std.testing.expect(descriptorFor(.lucid).capabilities.projection);
    try std.testing.expect(descriptorFor(.clickhouse).capabilities.analytics);
    try std.testing.expect(descriptorFor(.pgvector).capabilities.vector);
    try std.testing.expect(descriptorFor(.qdrant).capabilities.vector);
    try std.testing.expect(descriptorFor(.lancedb).capabilities.vector);
    try std.testing.expect(descriptorFor(.lancedb_http).capabilities.vector);
    try std.testing.expect(descriptorFor(.kg).capabilities.graph);

    const lucid_descriptor = descriptorFor(.lucid);
    try std.testing.expect(lucid_descriptor.capabilities.projection_index);
    try std.testing.expect(!lucid_descriptor.capabilities.agent_memory_store);
    try std.testing.expect(!lucid_descriptor.capabilities.session_store);
    try std.testing.expect(!lucid_descriptor.capabilities.transactions);
    try std.testing.expect(!lucid_descriptor.requirements.db_path);
    try std.testing.expect(lucid_descriptor.requirements.workspace);

    const clickhouse_descriptor = descriptorFor(.clickhouse);
    try std.testing.expect(clickhouse_descriptor.capabilities.analytics_export);
    try std.testing.expect(clickhouse_descriptor.capabilities.agent_memory_store);
    try std.testing.expect(clickhouse_descriptor.capabilities.session_store);
    try std.testing.expect(clickhouse_descriptor.capabilities.session_history);
    try std.testing.expect(clickhouse_descriptor.capabilities.usage_store);
    try std.testing.expect(clickhouse_descriptor.capabilities.feed_peer);
    try std.testing.expect(clickhouse_descriptor.capabilities.lifecycle_reducer);
    try std.testing.expect(std.mem.indexOf(u8, clickhouse_descriptor.feed_object_types_json, "agent_session_usage") != null);
    try std.testing.expect(std.mem.indexOf(u8, clickhouse_descriptor.feed_object_types_json, "artifact") == null);
    try std.testing.expect(std.mem.indexOf(u8, clickhouse_descriptor.nullpantry_strategy, "actor-scoped agent memory") != null);
    try std.testing.expect(std.mem.indexOf(u8, clickhouse_descriptor.nullpantry_strategy, "deterministic feed/checkpoint sync") != null);

    const redis_descriptor = descriptorFor(.redis);
    try std.testing.expect(redis_descriptor.capabilities.lifecycle);
    try std.testing.expect(std.mem.indexOf(u8, redis_descriptor.feed_object_types_json, "agent_memory") != null);
    try std.testing.expect(std.mem.indexOf(u8, redis_descriptor.feed_object_types_json, "source") == null);
    try std.testing.expect(std.mem.indexOf(u8, redis_descriptor.provides_json, "lifecycle") != null);
}

test "pgvector is advertised as its own Postgres-coupled vector index" {
    const descriptor = descriptorFor(.pgvector);
    try std.testing.expect(descriptor.runtime_supported);
    try std.testing.expect(descriptor.remote_primary_supported);
    try std.testing.expect(descriptor.capabilities.vector_index);
    try std.testing.expect(!descriptor.capabilities.agent_memory_store);
    try std.testing.expect(std.mem.indexOf(u8, descriptor.provides_json, "vector") != null);
    try std.testing.expect(std.mem.indexOf(u8, descriptor.provides_json, "record_coupled") != null);
    try std.testing.expect(std.mem.indexOf(u8, descriptor.nullpantry_strategy, "ACL hydration") != null);
    try std.testing.expect(std.mem.indexOf(u8, descriptor.nullclaw_boundary, "NullPantry service") != null);
}

test "platform capability flags separate runtime stores from indexes and projections" {
    const sqlite_descriptor = descriptorFor(.sqlite);
    try std.testing.expect(sqlite_descriptor.capabilities.record_store);
    try std.testing.expect(sqlite_descriptor.capabilities.agent_memory_store);
    try std.testing.expect(sqlite_descriptor.capabilities.vector_index);
    try std.testing.expect(sqlite_descriptor.capabilities.lifecycle_reducer);

    const markdown_descriptor = descriptorFor(.markdown);
    try std.testing.expect(!markdown_descriptor.capabilities.record_store);
    try std.testing.expect(markdown_descriptor.capabilities.filesystem_import_export);
    try std.testing.expect(markdown_descriptor.capabilities.agent_memory_store);
    try std.testing.expect(std.mem.indexOf(u8, markdown_descriptor.provides_json, "record") == null);

    const qdrant_descriptor = descriptorFor(.qdrant);
    const lancedb_descriptor = descriptorFor(.lancedb);
    const lancedb_http_descriptor = descriptorFor(.lancedb_http);
    try std.testing.expect(qdrant_descriptor.capabilities.vector_index);
    try std.testing.expect(lancedb_descriptor.capabilities.vector_index);
    try std.testing.expect(lancedb_http_descriptor.capabilities.vector_index);
    try std.testing.expect(!qdrant_descriptor.capabilities.record_store);
    try std.testing.expect(!lancedb_descriptor.capabilities.agent_memory_store);
    try std.testing.expect(!lancedb_http_descriptor.capabilities.agent_memory_store);
    try std.testing.expect(std.mem.indexOf(u8, lancedb_descriptor.provides_json, "sdk_process") != null);
    try std.testing.expect(std.mem.indexOf(u8, lancedb_descriptor.nullclaw_boundary, "canonical agent memory") != null);
    try std.testing.expect(std.mem.indexOf(u8, lancedb_descriptor.nullclaw_replacement_json, "\"vectors\":\"lancedb\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, lancedb_descriptor.nullclaw_replacement_json, "\"state_backend\":\"canonical_records\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, lancedb_http_descriptor.provides_json, "adapter_service") != null);
    try std.testing.expect(std.mem.indexOf(u8, lancedb_http_descriptor.aliases_json, "lancedb-compatible") != null);

    const kg_descriptor = descriptorFor(.kg);
    try std.testing.expect(kg_descriptor.capabilities.graph_index);
    try std.testing.expect(!kg_descriptor.capabilities.agent_memory_store);
}
