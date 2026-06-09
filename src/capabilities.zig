const std = @import("std");
const build_options = @import("build_options");
const engines = @import("engines.zig");
const json = @import("json_util.zig");

fn appendStringField(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), name: []const u8, value: []const u8) !void {
    try out.append(allocator, ',');
    try json.appendString(out, allocator, name);
    try out.append(allocator, ':');
    try json.appendString(out, allocator, value);
}

fn appendArrayStart(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), name: []const u8) !bool {
    try out.append(allocator, ',');
    try json.appendString(out, allocator, name);
    try out.appendSlice(allocator, ":[");
    return true;
}

fn appendArrayItem(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), first: *bool, value: []const u8) !void {
    if (!first.*) try out.append(allocator, ',');
    first.* = false;
    try json.appendString(out, allocator, value);
}

fn appendArrayField(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), name: []const u8, values: []const []const u8) !void {
    var first = try appendArrayStart(allocator, out, name);
    for (values) |value| try appendArrayItem(allocator, out, &first, value);
    try out.append(allocator, ']');
}

fn appendStorage(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    var first = try appendArrayStart(allocator, out, "storage");
    if (build_options.enable_engine_sqlite) try appendArrayItem(allocator, out, &first, "sqlite");
    if (build_options.enable_engine_postgres) try appendArrayItem(allocator, out, &first, "postgres-libpq-runtime");
    if (build_options.enable_engine_hybrid) try appendArrayItem(allocator, out, &first, "hybrid-sqlite-markdown");
    try out.append(allocator, ']');
}

fn appendAgentMemoryStores(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    var first = try appendArrayStart(allocator, out, "agent_memory_stores");
    if (build_options.enable_engine_none) try appendArrayItem(allocator, out, &first, "none");
    try appendArrayItem(allocator, out, &first, "native");
    if (build_options.enable_engine_memory_lru) {
        try appendArrayItem(allocator, out, &first, "memory");
        try appendArrayItem(allocator, out, &first, "memory_lru");
    }
    if (build_options.enable_engine_redis) try appendArrayItem(allocator, out, &first, "redis-resp-runtime");
    if (build_options.enable_engine_clickhouse) try appendArrayItem(allocator, out, &first, "clickhouse-http-runtime");
    if (build_options.enable_engine_api) try appendArrayItem(allocator, out, &first, "api-http-runtime");
    if (build_options.enable_engine_supermemory) try appendArrayItem(allocator, out, &first, "supermemory-http-runtime");
    if (build_options.enable_engine_openviking) try appendArrayItem(allocator, out, &first, "openviking-http-runtime");
    if (build_options.enable_engine_honcho) try appendArrayItem(allocator, out, &first, "honcho-http-runtime");
    if (build_options.enable_engine_mem0) try appendArrayItem(allocator, out, &first, "mem0-http-runtime");
    if (build_options.enable_engine_hindsight) try appendArrayItem(allocator, out, &first, "hindsight-http-runtime");
    if (build_options.enable_engine_retaindb) try appendArrayItem(allocator, out, &first, "retaindb-http-runtime");
    if (build_options.enable_engine_byterover) try appendArrayItem(allocator, out, &first, "byterover-cli-runtime");
    if (build_options.enable_engine_holographic) try appendArrayItem(allocator, out, &first, "holographic-sqlite-runtime");
    if (build_options.enable_engine_zep) try appendArrayItem(allocator, out, &first, "zep-graph-http-runtime");
    if (build_options.enable_engine_falkordb) try appendArrayItem(allocator, out, &first, "falkordb-graph-http-runtime");
    try out.append(allocator, ']');
}

fn appendVectorStores(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    var first = try appendArrayStart(allocator, out, "vector_stores");
    try appendArrayItem(allocator, out, &first, "local");
    if (build_options.enable_engine_pgvector) try appendArrayItem(allocator, out, &first, "postgres-pgvector");
    if (build_options.enable_engine_qdrant) try appendArrayItem(allocator, out, &first, "qdrant-http-runtime");
    if (build_options.enable_engine_lancedb) try appendArrayItem(allocator, out, &first, "lancedb-sdk-runtime");
    if (build_options.enable_engine_lancedb_http) try appendArrayItem(allocator, out, &first, "lancedb-http-runtime");
    if (build_options.enable_engine_weaviate) try appendArrayItem(allocator, out, &first, "weaviate-http-runtime");
    if (build_options.enable_engine_chroma) try appendArrayItem(allocator, out, &first, "chroma-http-runtime");
    if (build_options.enable_engine_opensearch) try appendArrayItem(allocator, out, &first, "opensearch-http-runtime");
    try out.append(allocator, ']');
}

fn appendProjectionBackends(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    var first = try appendArrayStart(allocator, out, "projection_backends");
    if (build_options.enable_engine_neo4j) try appendArrayItem(allocator, out, &first, "neo4j-query-http-runtime");
    if (build_options.enable_engine_falkordb) try appendArrayItem(allocator, out, &first, "falkordb-cypher-http-runtime");
    if (build_options.enable_engine_lucid) try appendArrayItem(allocator, out, &first, "lucid-cli-runtime");
    try out.append(allocator, ']');
}

fn appendAnalyticsBackends(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    var first = try appendArrayStart(allocator, out, "analytics_backends");
    if (build_options.enable_engine_clickhouse) try appendArrayItem(allocator, out, &first, "clickhouse-http-runtime");
    try out.append(allocator, ']');
}

const base_apis = [_][]const u8{
    "agent_memory",
    "agent_sessions",
    "agent_session_terminate",
    "agent_session_compact",
    "bootstrap_prompts",
    "named_agent_memory_stores",
    "remember",
    "search",
    "ask",
    "retrieval_plan",
    "retrieval_search",
    "create_context_pack",
    "list_context_packs",
    "get_context_pack",
    "patch_context_pack",
    "delete_context_pack",
    "list_sources",
    "create_source",
    "get_source",
    "patch_source",
    "delete_source",
    "list_artifacts",
    "create_artifact",
    "get_artifact",
    "patch_artifact",
    "delete_artifact",
    "list_memory_atoms",
    "create_memory_atom",
    "get_memory_atom",
    "patch_memory_atom",
    "delete_memory_atom",
    "list_entities",
    "resolve_entity",
    "get_entity",
    "patch_entity",
    "delete_entity",
    "list_relations",
    "create_relation",
    "get_relation",
    "patch_relation",
    "delete_relation",
    "list_spaces",
    "create_space",
    "get_space",
    "patch_space",
    "delete_space",
    "list_policy_scopes",
    "upsert_policy_scope",
    "get_policy_scope",
    "patch_policy_scope",
    "delete_policy_scope",
    "extract_memory",
    "create_decision",
    "link",
    "forget",
    "verify",
    "mark_stale",
    "supersede",
    "ingest",
    "connector_ingest",
    "connector_cursor",
    "jobs",
    "workers",
    "conflicts",
    "native_feed",
    "native_feed_events",
    "native_feed_status",
    "native_feed_compact",
    "native_feed_checkpoint",
    "native_feed_apply",
    "memory_feed",
    "memory_status",
    "memory_stats",
    "memory_count",
    "memory_context_block",
    "memory_list",
    "memory_prefetch",
    "memory_provider_config_schema",
    "memory_provider_registry",
    "memory_provider_tools",
    "memory_search",
    "memory_get",
    "memory_store",
    "memory_update",
    "memory_delete",
    "memory_export_jsonl",
    "memory_hygiene",
    "memory_hygiene_report",
    "memory_reindex",
    "memory_drain_outbox",
    "memory_compact",
    "memory_checkpoint",
    "vector_status",
    "vector_embed",
    "vector_upsert",
    "vector_search",
    "vector_delete",
    "vector_rebuild",
    "vector_reconcile",
    "vector_outbox",
    "snapshot_export",
    "snapshot_import",
    "snapshot_hydrate",
    "lifecycle_hydrate",
    "jsonl_export",
    "jsonl_import",
    "hygiene_report",
    "lifecycle_hygiene",
    "cache_put",
    "cache_get",
    "cache_stats",
    "cache_clear",
    "semantic_cache_put",
    "semantic_cache_search",
    "semantic_cache_stats",
    "semantic_cache_clear",
    "embedding_cache_stats",
    "embedding_cache_clear",
    "lifecycle_diagnostics",
    "lifecycle_stats",
    "lifecycle_migrate",
    "brain_db_import",
    "lifecycle_summarize",
    "lifecycle_compact_session",
    "lifecycle_rollout",
};

const base_retrieval = [_][]const u8{
    "acl",
    "fts",
    "vector",
    "adaptive_retrieval",
    "named_runtime_memory",
    "rrf",
    "min_relevance",
    "temporal_decay",
    "embedding_mmr",
    "mmr_lambda",
    "mmr_candidate_window",
    "llm_rerank",
    "candidate_id_rerank",
    "quality_rerank",
    "rerank_candidate_limit",
    "strict_reranker",
    "limit",
    "citations",
    "conflict_warnings",
};

const nullclaw_adapter_apis = [_][]const u8{ "nullclaw_memory_parity", "nullclaw_api_memory_parity", "nullclaw_api_health", "nullclaw_api_memory_adapter", "nullclaw_api_root_adapter" };
const qmd_apis = [_][]const u8{ "qmd_connector", "qmd_session_export", "qmd_session_prune" };
const markdown_apis = [_][]const u8{ "markdown_import", "markdown_import_directory", "markdown_export", "markdown_export_directory" };
const graph_apis = [_][]const u8{ "graph_schema", "graph_query", "graph_neighbors", "graph_path" };
const lucid_apis = [_][]const u8{ "lucid_projection_status", "lucid_projection_rebuild" };
const analytics_apis = [_][]const u8{ "analytics_export", "analytics_status", "analytics_query" };
const graph_retrieval = [_][]const u8{ "entity_graph", "graph_schema", "graph_query", "graph_neighbors", "graph_path" };
const qmd_retrieval = [_][]const u8{ "qmd_canonical_ingest", "qmd_agent_session_export" };

fn appendApis(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    var first = try appendArrayStart(allocator, out, "apis");
    for (base_apis) |api| try appendArrayItem(allocator, out, &first, api);
    if (build_options.enable_nullclaw_adapter) for (nullclaw_adapter_apis) |api| try appendArrayItem(allocator, out, &first, api);
    if (build_options.enable_engine_qmd) for (qmd_apis) |api| try appendArrayItem(allocator, out, &first, api);
    if (build_options.enable_engine_markdown) for (markdown_apis) |api| try appendArrayItem(allocator, out, &first, api);
    if (build_options.enable_engine_kg) for (graph_apis) |api| try appendArrayItem(allocator, out, &first, api);
    if (build_options.enable_engine_lucid) for (lucid_apis) |api| try appendArrayItem(allocator, out, &first, api);
    if (build_options.enable_engine_clickhouse) for (analytics_apis) |api| try appendArrayItem(allocator, out, &first, api);
    try out.append(allocator, ']');
}

fn appendRetrieval(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    var first = try appendArrayStart(allocator, out, "retrieval_features");
    for (base_retrieval) |name| try appendArrayItem(allocator, out, &first, name);
    if (build_options.enable_engine_kg) for (graph_retrieval) |name| try appendArrayItem(allocator, out, &first, name);
    if (build_options.enable_engine_qmd) for (qmd_retrieval) |name| try appendArrayItem(allocator, out, &first, name);
    if (build_options.enable_engine_lucid) try appendArrayItem(allocator, out, &first, "lucid_projection");
    try out.append(allocator, ']');
}

pub fn writeJson(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    try out.appendSlice(allocator, "{\"service\":\"nullpantry\",\"headless\":true");
    try appendStringField(allocator, out, "engine_profile", build_options.engine_profile);
    try appendStringField(allocator, out, "engine_selection", build_options.engine_selection);
    try appendArrayField(allocator, out, "product", &.{ "knowledge_base", "long_term_memory", "rag", "knowledge_graph", "context_serving_api" });
    try appendArrayField(allocator, out, "consumers", &.{ "agents", "nullhub", "nulldesk" });
    try appendArrayField(allocator, out, "primitives", &.{ "source", "artifact", "memory_atom", "entity", "relation", "context_pack", "agent_memory", "space", "policy_scope" });
    try appendArrayField(allocator, out, "content_types", &.{ "page", "spec", "decision", "runbook", "recipe", "meeting_note", "research", "incident_report", "memory_item" });
    try appendStorage(allocator, out);
    try appendAgentMemoryStores(allocator, out);
    try appendArrayField(allocator, out, "agent_memory_routing", &.{ "primary", "native", "runtime", "named", "subset", "all" });
    try appendArrayField(allocator, out, "knowledge_storage_routing", &.{ "canonical", "runtime_mirror", "named", "subset", "all" });
    try appendVectorStores(allocator, out);
    try appendProjectionBackends(allocator, out);
    try appendAnalyticsBackends(allocator, out);
    try appendApis(allocator, out);
    try appendArrayField(allocator, out, "providers", &.{ "local-deterministic", "openai-compatible-embeddings", "gemini-embeddings", "voyage-embeddings", "ollama-embeddings", "embedding-fallback-chain", "openai-compatible-chat", "ollama-compatible" });
    try appendRetrieval(allocator, out);
    try appendArrayField(allocator, out, "permissions", &.{ "read", "write", "propose", "verify", "delete", "export", "feed_apply" });
    try appendArrayField(allocator, out, "auth", &.{ "single_bearer_token", "token_principal_registry", "request_scope_narrowing" });
    try out.appendSlice(allocator, ",\"engine_registry\":");
    try engines.appendDescriptorsJson(allocator, out);
    try out.appendSlice(allocator, ",\"engine_roles\":");
    try engines.appendEngineRolesJson(allocator, out);
    try out.appendSlice(allocator, ",\"retrieval\":");
    try engines.appendRetrievalJson(allocator, out);
    try out.appendSlice(allocator, ",\"engine_candidates\":");
    try engines.appendFutureCandidatesJson(allocator, out);
    try out.append(allocator, '}');
}
