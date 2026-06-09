const std = @import("std");
const json = @import("json_util.zig");
const domain = @import("domain.zig");
const lifecycle_mod = @import("lifecycle.zig");
const retrieval_mod = @import("retrieval.zig");
const semantic_cache_policy = @import("semantic_cache_policy.zig");
const storage_routes = @import("storage_route.zig");
const store_connector_cursor = @import("store_connector_cursor.zig");
const store_agent_memory = @import("store_agent_memory.zig");
const store_job = @import("store_job.zig");

pub const AgentMemoryStorageRoute = storage_routes.Route;

pub const AgentMemoryReadAccess = enum {
    exact_owner,
    visible,
    any_visible,
};

pub const AgentMemoryGetInput = struct {
    key: []const u8,
    session_id: ?[]const u8 = null,
    actor_id: ?[]const u8 = null,
    scopes_json: []const u8 = "[]",
    capabilities_json: ?[]const u8 = null,
    route: AgentMemoryStorageRoute = .{},
    access: AgentMemoryReadAccess = .visible,
};

pub const AgentMemoryListInput = struct {
    category: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    actor_id: ?[]const u8 = null,
    scopes_json: []const u8 = "[]",
    capabilities_json: ?[]const u8 = null,
    route: AgentMemoryStorageRoute = .{},
    access: AgentMemoryReadAccess = .visible,
    limit: ?usize = null,
    offset: usize = 0,
};

pub const AgentMemorySearchInput = struct {
    query: []const u8,
    session_id: ?[]const u8 = null,
    actor_id: ?[]const u8 = null,
    scopes_json: []const u8 = "[]",
    capabilities_json: ?[]const u8 = null,
    route: AgentMemoryStorageRoute = .{},
    access: AgentMemoryReadAccess = .visible,
    limit: usize = 10,
};

pub const AgentMemoryCountInput = struct {
    actor_id: ?[]const u8 = null,
    scopes_json: []const u8 = "[]",
    capabilities_json: ?[]const u8 = null,
    route: AgentMemoryStorageRoute = .{},
};

pub const AgentMemoryDeleteInput = struct {
    key: []const u8,
    session_id: ?[]const u8 = null,
    actor_id: ?[]const u8 = null,
    writer_actor_id: ?[]const u8 = null,
    actor_scopes_json: ?[]const u8 = null,
    actor_capabilities_json: ?[]const u8 = null,
    route: AgentMemoryStorageRoute = .{},
    all_owners: bool = false,
    suppress_feed: bool = false,
    event_order: ?store_agent_memory.EventOrder = null,
};

pub const SourceInput = struct {
    id: ?[]const u8 = null,
    source_type: []const u8 = "manual",
    title: []const u8,
    raw_content_uri: ?[]const u8 = null,
    content: []const u8 = "",
    author: ?[]const u8 = null,
    participants_json: []const u8 = "[]",
    permissions_json: []const u8 = "[]",
    scope: []const u8 = "workspace",
    checksum: ?[]const u8 = null,
    language: ?[]const u8 = null,
    related_entities_json: []const u8 = "[]",
    metadata_json: []const u8 = "{}",
    actor_id: ?[]const u8 = null,
    storage_route: AgentMemoryStorageRoute = .{},
    suppress_feed: bool = false,
};

pub const SpaceInput = struct {
    id: ?[]const u8 = null,
    name: []const u8,
    title: []const u8,
    description: ?[]const u8 = null,
    scope: []const u8 = "workspace",
    permissions_json: []const u8 = "[]",
    metadata_json: []const u8 = "{}",
    actor_id: ?[]const u8 = null,
    suppress_feed: bool = false,
};

pub const Space = struct {
    id: []const u8,
    name: []const u8,
    title: []const u8,
    description: ?[]const u8,
    scope: []const u8,
    permissions_json: []const u8,
    metadata_json: []const u8,
    created_at_ms: i64,
    updated_at_ms: i64,

    pub fn writeJson(self: Space, allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
        try out.appendSlice(allocator, "{\"id\":");
        try json.appendString(out, allocator, self.id);
        try out.appendSlice(allocator, ",\"name\":");
        try json.appendString(out, allocator, self.name);
        try out.appendSlice(allocator, ",\"title\":");
        try json.appendString(out, allocator, self.title);
        try out.appendSlice(allocator, ",\"description\":");
        try json.appendNullableString(out, allocator, self.description);
        try out.appendSlice(allocator, ",\"scope\":");
        try json.appendString(out, allocator, self.scope);
        try out.appendSlice(allocator, ",\"permissions\":");
        try json.appendRawJsonArray(out, allocator, self.permissions_json);
        try out.appendSlice(allocator, ",\"metadata\":");
        try json.appendRawJsonObject(out, allocator, self.metadata_json);
        try out.print(allocator, ",\"created_at_ms\":{d},\"updated_at_ms\":{d}}}", .{ self.created_at_ms, self.updated_at_ms });
    }
};

pub const PolicyScopeInput = struct {
    scope: []const u8,
    visibility: []const u8 = "workspace",
    permissions_json: []const u8 = "[]",
    owner: ?[]const u8 = null,
    ttl_ms: ?i64 = null,
    review_after_ms: ?i64 = null,
    metadata_json: []const u8 = "{}",
    actor_id: ?[]const u8 = null,
    suppress_feed: bool = false,
};

pub const PolicyScope = struct {
    scope: []const u8,
    visibility: []const u8,
    permissions_json: []const u8,
    owner: ?[]const u8,
    ttl_ms: ?i64,
    review_after_ms: ?i64,
    metadata_json: []const u8,
    created_at_ms: i64,
    updated_at_ms: i64,

    pub fn writeJson(self: PolicyScope, allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
        try out.appendSlice(allocator, "{\"scope\":");
        try json.appendString(out, allocator, self.scope);
        try out.appendSlice(allocator, ",\"visibility\":");
        try json.appendString(out, allocator, self.visibility);
        try out.appendSlice(allocator, ",\"permissions\":");
        try json.appendRawJsonArray(out, allocator, self.permissions_json);
        try out.appendSlice(allocator, ",\"owner\":");
        try json.appendNullableString(out, allocator, self.owner);
        try out.appendSlice(allocator, ",\"ttl_ms\":");
        if (self.ttl_ms) |v| try out.print(allocator, "{d}", .{v}) else try out.appendSlice(allocator, "null");
        try out.appendSlice(allocator, ",\"review_after_ms\":");
        if (self.review_after_ms) |v| try out.print(allocator, "{d}", .{v}) else try out.appendSlice(allocator, "null");
        try out.appendSlice(allocator, ",\"metadata\":");
        try json.appendRawJsonObject(out, allocator, self.metadata_json);
        try out.print(allocator, ",\"created_at_ms\":{d},\"updated_at_ms\":{d}}}", .{ self.created_at_ms, self.updated_at_ms });
    }
};

pub const ArtifactInput = struct {
    id: ?[]const u8 = null,
    artifact_type: []const u8 = "page",
    title: []const u8,
    body: []const u8 = "",
    status: []const u8 = "draft",
    owner: ?[]const u8 = null,
    space_id: ?[]const u8 = null,
    scope: []const u8 = "workspace",
    source_ids_json: []const u8 = "[]",
    related_entities_json: []const u8 = "[]",
    permissions_json: []const u8 = "[]",
    fields_json: []const u8 = "{}",
    summary: ?[]const u8 = null,
    agent_summary: ?[]const u8 = null,
    actor_id: ?[]const u8 = null,
    storage_route: AgentMemoryStorageRoute = .{},
    suppress_feed: bool = false,
};

pub const EntityInput = struct {
    id: ?[]const u8 = null,
    entity_type: []const u8 = "concept",
    name: []const u8,
    aliases_json: []const u8 = "[]",
    description: ?[]const u8 = null,
    canonical_artifact_id: ?[]const u8 = null,
    scope: []const u8 = "workspace",
    permissions_json: []const u8 = "[]",
    metadata_json: []const u8 = "{}",
    actor_id: ?[]const u8 = null,
    storage_route: AgentMemoryStorageRoute = .{},
    suppress_feed: bool = false,
};

pub const RelationInput = struct {
    id: ?[]const u8 = null,
    from_entity_id: []const u8,
    relation_type: []const u8,
    to_entity_id: []const u8,
    source_ids_json: []const u8 = "[]",
    scope: []const u8 = "workspace",
    permissions_json: []const u8 = "[]",
    confidence: f64 = 0.5,
    status: []const u8 = "proposed",
    actor_id: ?[]const u8 = null,
    storage_route: AgentMemoryStorageRoute = .{},
    suppress_feed: bool = false,
};

pub const PrimitiveLifecycleTarget = struct {
    object_id: []const u8,
    scope: []const u8,
    permissions_json: []const u8,
};

pub const MemoryAtomInput = struct {
    id: ?[]const u8 = null,
    subject_entity_id: ?[]const u8 = null,
    predicate: []const u8 = "states",
    object: []const u8 = "",
    text: []const u8,
    scope: []const u8 = "workspace",
    confidence: f64 = 0.5,
    status: ?[]const u8 = null,
    source_ids_json: []const u8 = "[]",
    evidence_ranges_json: []const u8 = "[]",
    created_by: []const u8 = "human",
    valid_from_ms: ?i64 = null,
    valid_until_ms: ?i64 = null,
    owner: ?[]const u8 = null,
    permissions_json: []const u8 = "[]",
    tags_json: []const u8 = "[]",
    actor_id: ?[]const u8 = null,
    storage_route: AgentMemoryStorageRoute = .{},
    suppress_feed: bool = false,
};

pub const SearchInput = struct {
    query: []const u8,
    limit: usize = 10,
    offset: usize = 0,
    scopes_json: []const u8 = "[\"admin\"]",
    include_deprecated: bool = false,
    include_sessions: bool = false,
    session_id: ?[]const u8 = null,
    use_vector: bool = true,
    adaptive_retrieval: bool = false,
    adaptive_keyword_max_tokens: u32 = retrieval_mod.default_adaptive_keyword_max_tokens,
    adaptive_vector_min_tokens: u32 = retrieval_mod.default_adaptive_vector_min_tokens,
    strict_vector: bool = false,
    use_temporal_decay: bool = true,
    use_mmr: bool = true,
    mmr_lambda: f64 = retrieval_mod.default_mmr_lambda,
    mmr_candidate_multiplier: usize = retrieval_mod.default_mmr_candidate_multiplier,
    allow_reranker: bool = false,
    rerank_candidate_limit: u32 = retrieval_mod.default_rerank_candidate_limit,
    strict_reranker: bool = false,
    min_relevance: f64 = 0,
    half_life_days: f64 = 30,
    rrf_k: f64 = retrieval_mod.default_rrf_k,
    rrf_weight: f64 = retrieval_mod.default_rrf_weight,
    raw_score_weight: f64 = retrieval_mod.default_rrf_raw_score_weight,
    rrf_window_multiplier: usize = retrieval_mod.default_rrf_window_multiplier,
    query_embedding_json: ?[]const u8 = null,
    query_embedding_provider: []const u8 = "none",
    embedding_dimensions: usize = 64,
    actor_id: ?[]const u8 = null,
    actor_capabilities_json: ?[]const u8 = null,
    agent_memory_route: AgentMemoryStorageRoute = .{},
    rollout_mode: lifecycle_mod.RolloutMode = .on,
    rollout_decision: lifecycle_mod.RolloutDecision = .enabled,
    rollout_reason: []const u8 = "mode_on",
    rollout_bucket: u8 = 0,
    rollout_vector_requested: bool = true,
    rollout_shadow_vector: bool = false,
};

pub const VectorChunkInput = struct {
    object_type: []const u8 = "memory_atom",
    object_id: []const u8,
    chunk_ordinal: i64 = 0,
    text: []const u8 = "",
    scope: []const u8 = "workspace",
    permissions_json: []const u8 = "[]",
    heading_path_json: []const u8 = "[]",
    start_byte: i64 = 0,
    end_byte: i64 = 0,
    content_hash: []const u8 = "",
    chunk_strategy: []const u8 = "plain",
    estimated_tokens: i64 = 0,
    transcript_timestamp: ?[]const u8 = null,
    transcript_speaker: ?[]const u8 = null,
    embedding_json: []const u8,
    model: ?[]const u8 = null,
    dimensions: i64,
    actor_id: ?[]const u8 = null,
};

pub const VectorChunk = struct {
    id: []const u8,
    object_type: []const u8,
    object_id: []const u8,
    chunk_ordinal: i64,
    text: []const u8,
    scope: []const u8,
    permissions_json: []const u8,
    heading_path_json: []const u8 = "[]",
    start_byte: i64 = 0,
    end_byte: i64 = 0,
    content_hash: []const u8 = "",
    chunk_strategy: []const u8 = "plain",
    estimated_tokens: i64 = 0,
    transcript_timestamp: ?[]const u8 = null,
    transcript_speaker: ?[]const u8 = null,
    embedding_json: []const u8,
    model: ?[]const u8,
    dimensions: i64,
    created_at_ms: i64,
    updated_at_ms: i64,
};

pub const VectorSearchInput = struct {
    embedding_json: []const u8,
    scopes_json: []const u8 = "[\"admin\"]",
    limit: usize = 10,
    min_score: f32 = 0,
    include_deprecated: bool = false,
    include_sessions: bool = true,
    session_id: ?[]const u8 = null,
    strict_external: bool = false,
    actor_id: ?[]const u8 = null,
};

pub const VectorOutboxListInput = struct {
    action: ?[]const u8 = null,
    status: ?[]const u8 = null,
    limit: usize = 100,
};

pub const VectorOutboxInput = struct {
    action: []const u8,
    object_type: []const u8,
    object_id: []const u8,
    status: []const u8 = "pending",
    payload_json: []const u8 = "{}",
};

pub const VectorMaintenanceInput = struct {
    limit: usize = 1000,
    reset_external: bool = false,
    retry_failed: bool = false,
};

pub const AnalyticsExportInput = struct {
    audit_since_id: i64 = 0,
    feed_since_id: i64 = 0,
    limit: usize = 1000,
    scopes_json: []const u8 = "[\"admin\"]",
    use_cursor: bool = false,
    advance_cursor: bool = false,
    cursor_name: []const u8 = "clickhouse_analytics",
    cursor_scope: []const u8 = "admin",
    cursor_permissions_json: []const u8 = "[\"admin\"]",
    actor_id: ?[]const u8 = null,
};

pub const FeedListInput = struct {
    since_id: i64 = 0,
    limit: usize = 100,
    scopes_json: []const u8 = "[\"admin\"]",
    ignore_cursor_floor: bool = false,
    actor_id: ?[]const u8 = null,
};

pub const SemanticCacheSearchInput = struct {
    embedding_json: []const u8,
    embedding_provider: []const u8 = "provided",
    embedding_model: []const u8 = "",
    embedding_dimensions: usize = 0,
    scopes_json: []const u8 = "[\"admin\"]",
    actor_id: []const u8 = "",
    cache_key_prefix: ?[]const u8 = null,
    min_score: f32 = 0.82,
    now_ms: ?i64 = null,
    candidate_limit: usize = semantic_cache_policy.default_candidate_limit,
};

pub const LucidProjectionRebuildInput = struct {
    scopes_json: []const u8 = "[\"admin\"]",
    actor_id: ?[]const u8 = null,
    actor_capabilities_json: ?[]const u8 = null,
    limit: usize = 1000,
};

pub const ResponseCacheInput = struct {
    cache_key: []const u8,
    response_json: []const u8,
    scopes_json: []const u8 = "[\"admin\"]",
    actor_id: []const u8 = "",
    ttl_ms: i64 = 0,
    now_ms: ?i64 = null,
    token_count: i64 = 0,
    max_entries: usize = 0,
};

pub const CacheStatsInput = struct {
    actor_id: []const u8,
    now_ms: ?i64 = null,
};

pub const CacheClearInput = struct {
    actor_id: []const u8,
    cache_key: ?[]const u8 = null,
    expired_only: bool = false,
    now_ms: ?i64 = null,
};

pub const EmbeddingCacheInput = struct {
    cache_key: []const u8,
    provider: []const u8,
    model: []const u8 = "",
    dimensions: usize,
    embedding_json: []const u8,
    now_ms: ?i64 = null,
    max_entries: usize = 0,
};

pub const EmbeddingCacheClearInput = struct {
    cache_key: ?[]const u8 = null,
};

pub const SemanticCacheInput = struct {
    cache_key: []const u8,
    query: []const u8,
    response_json: []const u8,
    embedding_json: []const u8,
    embedding_provider: []const u8 = "provided",
    embedding_model: []const u8 = "",
    embedding_dimensions: usize = 0,
    scopes_json: []const u8 = "[\"admin\"]",
    actor_id: []const u8 = "",
    ttl_ms: i64 = 0,
    now_ms: ?i64 = null,
    token_count: i64 = 0,
    max_entries: usize = 0,
};

pub const HygieneRunInput = struct {
    stale_after_ms: i64 = 30 * 24 * 60 * 60 * 1000,
    archive_after_ms: i64 = 90 * 24 * 60 * 60 * 1000,
    purge_after_ms: i64 = 0,
    hard_delete: bool = false,
    dedupe_memory_atoms: bool = false,
    dedupe_agent_memory: bool = false,
    dedupe_normalized: bool = true,
    dedupe_limit: usize = 5000,
    now_ms: ?i64 = null,
    actor_id: ?[]const u8 = null,
    scopes_json: []const u8 = "[\"admin\"]",
    capabilities_json: []const u8 = "[\"read\",\"write\",\"propose\",\"verify\",\"delete\",\"export\",\"feed_apply\"]",
};

pub const RoutedAgentMemoryDedupeInput = struct {
    category: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    include_internal: bool = false,
};

pub const MemoryAtomListInput = struct {
    limit: usize = 1000,
    scopes_json: []const u8 = "[\"admin\"]",
    scope_filter_empty: bool = false,
    actor_id: ?[]const u8 = null,
    include_deprecated: bool = false,
};

pub const PrimitiveListInput = struct {
    limit: usize = 1000,
    scopes_json: []const u8 = "[\"admin\"]",
    scope_filter_empty: bool = false,
    actor_id: ?[]const u8 = null,
    include_deprecated: bool = false,
};

pub const ContextPackInput = struct {
    id: ?[]const u8 = null,
    purpose: []const u8 = "task",
    target: []const u8 = "agent",
    query: []const u8,
    token_budget: i64 = 12000,
    scopes_json: []const u8 = "[]",
    query_embedding_json: ?[]const u8 = null,
    query_embedding_provider: []const u8 = "none",
    embedding_dimensions: usize = 64,
    persist: bool = true,
    include_sessions: bool = false,
    session_id: ?[]const u8 = null,
    retrieval_limit: usize = 40,
    include_deprecated: bool = false,
    use_vector: bool = true,
    adaptive_retrieval: bool = false,
    adaptive_keyword_max_tokens: u32 = retrieval_mod.default_adaptive_keyword_max_tokens,
    adaptive_vector_min_tokens: u32 = retrieval_mod.default_adaptive_vector_min_tokens,
    use_temporal_decay: bool = true,
    use_mmr: bool = true,
    mmr_lambda: f64 = retrieval_mod.default_mmr_lambda,
    mmr_candidate_multiplier: usize = retrieval_mod.default_mmr_candidate_multiplier,
    allow_reranker: bool = false,
    rerank_candidate_limit: u32 = retrieval_mod.default_rerank_candidate_limit,
    strict_reranker: bool = false,
    min_relevance: f64 = 0,
    rrf_k: f64 = retrieval_mod.default_rrf_k,
    rrf_weight: f64 = retrieval_mod.default_rrf_weight,
    raw_score_weight: f64 = retrieval_mod.default_rrf_raw_score_weight,
    rrf_window_multiplier: usize = retrieval_mod.default_rrf_window_multiplier,
    actor_id: ?[]const u8 = null,
    actor_capabilities_json: ?[]const u8 = null,
    agent_memory_route: AgentMemoryStorageRoute = .{},
    preselected_results: ?[]domain.SearchResult = null,
    preserve_result_order: bool = false,
    suppress_feed: bool = false,
};

pub const ConnectorCursorListInput = store_connector_cursor.ListInput;

pub const JobListInput = store_job.ListInput;

pub const ConflictListInput = struct {
    scopes_json: []const u8 = "[]",
    status: ?[]const u8 = "open",
    limit: usize = 100,
};

test "store type contracts keep expected defaults" {
    const search = SearchInput{ .query = "zig" };
    try std.testing.expectEqual(@as(usize, 10), search.limit);
    try std.testing.expectEqual(lifecycle_mod.RolloutMode.on, search.rollout_mode);
    const source = SourceInput{ .title = "Manual" };
    try std.testing.expectEqualStrings("manual", source.source_type);
    try std.testing.expectEqualStrings("workspace", source.scope);
    const pack = ContextPackInput{ .query = "architecture" };
    try std.testing.expectEqual(@as(usize, 40), pack.retrieval_limit);
    const jobs = JobListInput{};
    try std.testing.expectEqual(@as(usize, 100), jobs.limit);
    const vector_outbox = VectorOutboxInput{ .action = "upsert", .object_type = "source", .object_id = "src_1" };
    try std.testing.expectEqualStrings("pending", vector_outbox.status);
    const semantic_cache = SemanticCacheInput{
        .cache_key = "sem:1",
        .query = "zig",
        .response_json = "{}",
        .embedding_json = "[1]",
    };
    try std.testing.expectEqualStrings("provided", semantic_cache.embedding_provider);
    const hygiene = HygieneRunInput{};
    try std.testing.expectEqual(@as(usize, 5000), hygiene.dedupe_limit);
}

test "store primitive object contracts enforce raw container root types" {
    var space_out: std.ArrayListUnmanaged(u8) = .empty;
    defer space_out.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidRawJson, (Space{
        .id = "space_bad_raw",
        .name = "bad-raw",
        .title = "Bad Raw",
        .description = null,
        .scope = "team:alpha",
        .permissions_json = "{\"scope\":\"team:alpha\"}",
        .metadata_json = "[\"wrong-root\"]",
        .created_at_ms = 1,
        .updated_at_ms = 2,
    }).writeJson(std.testing.allocator, &space_out));

    var policy_out: std.ArrayListUnmanaged(u8) = .empty;
    defer policy_out.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidRawJson, (PolicyScope{
        .scope = "team:alpha",
        .visibility = "team",
        .permissions_json = "{\"scope\":\"team:alpha\"}",
        .owner = null,
        .ttl_ms = null,
        .review_after_ms = null,
        .metadata_json = "[\"wrong-root\"]",
        .created_at_ms = 3,
        .updated_at_ms = 4,
    }).writeJson(std.testing.allocator, &policy_out));
}
