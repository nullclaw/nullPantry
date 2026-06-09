const std = @import("std");
const build_options = @import("build_options");

pub fn importProfileSmokeSuite() void {
    importProfileCoreModules();
    importProfileAgentMemoryContracts();
    importProfileRuntimeAndRouteContracts();
    importProfileOptionalModules();
}

pub fn importFullImportSuite() void {
    importCoreModules();
    importRuntimeModules();
    importRetrievalModules();
    importAgentMemoryModules();
    importStoreModules();
    importOptionalConnectorModules();
    importWorkerAndFacadeModules();
    importApiModules();
}

fn importProfileCoreModules() void {
    _ = @import("cache_time.zig");
    _ = @import("time_math.zig");
    _ = @import("ids.zig");
    _ = @import("json_util.zig");
    _ = @import("domain.zig");
    _ = @import("feed_contract.zig");
    _ = @import("semantic_cache_policy.zig");
    _ = @import("engines.zig");
    _ = @import("vector_key_codec.zig");
}

fn importProfileAgentMemoryContracts() void {
    _ = @import("agent_memory_config.zig");
    _ = @import("agent_memory_requests.zig");
    _ = @import("agent_memory_results.zig");
    _ = @import("agent_memory_event_order.zig");
    _ = @import("agent_memory_test_helpers.zig");
}

fn importProfileRuntimeAndRouteContracts() void {
    _ = @import("runtime_config.zig");
    _ = @import("http_request.zig");
    _ = @import("api_catalog.zig");
    _ = @import("api_filesystem.zig");
    _ = @import("api_routes.zig");
    _ = @import("api_manifest.zig");
    _ = @import("api_openapi.zig");
}

fn importProfileOptionalModules() void {
    if (build_options.enable_engine_redis) _ = @import("redis.zig");
    if (build_options.enable_engine_markdown) {
        _ = @import("markdown_adapter.zig");
        _ = @import("markdown_filesystem.zig");
    }
    if (build_options.enable_engine_qmd) _ = @import("qmd_adapter.zig");
    if (build_options.enable_engine_holographic) {
        _ = @import("agent_memory_holographic.zig");
    } else {
        _ = @import("agent_memory_holographic_disabled.zig");
    }
    if (build_options.enable_engine_zep) {
        _ = @import("agent_memory_zep.zig");
    } else {
        _ = @import("agent_memory_zep_disabled.zig");
    }
    if (build_options.enable_engine_falkordb) {
        _ = @import("agent_memory_falkordb.zig");
    } else {
        _ = @import("agent_memory_falkordb_disabled.zig");
    }
}

fn importCoreModules() void {
    _ = @import("cache_time.zig");
    _ = @import("time_math.zig");
    _ = @import("ids.zig");
    _ = @import("json_util.zig");
    _ = @import("domain.zig");
    _ = @import("semantic_cache_policy.zig");
    _ = @import("engines.zig");
    _ = @import("vector.zig");
    _ = @import("vector_key_codec.zig");
}

fn importRetrievalModules() void {
    _ = @import("query_expansion.zig");
    _ = @import("retrieval.zig");
    _ = @import("retrieval_engine.zig");
    _ = @import("llm_reranker.zig");
    _ = @import("lifecycle.zig");
    _ = @import("providers.zig");
}

fn importRuntimeModules() void {
    _ = @import("vector_runtime.zig");
    _ = @import("analytics_runtime.zig");
    _ = @import("graph_runtime.zig");
    _ = @import("lucid_runtime.zig");
}

fn importAgentMemoryModules() void {
    _ = @import("agent_memory_config.zig");
    _ = @import("agent_memory_requests.zig");
    _ = @import("agent_memory_results.zig");
    _ = @import("agent_memory_event_order.zig");
    _ = @import("agent_memory_runtime.zig");
    _ = @import("agent_memory_reducer.zig");
    _ = @import("agent_memory_providers.zig");
    _ = @import("agent_memory_contract_tests.zig");
}

fn importStoreModules() void {
    _ = @import("store_analytics.zig");
    _ = @import("store_types.zig");
    _ = @import("store_agent_memory.zig");
    _ = @import("store_agent_memory_subset.zig");
    _ = @import("store_knowledge_write.zig");
    _ = @import("store_ownership.zig");
    _ = @import("store_postgres_rows.zig");
    _ = @import("store_feed.zig");
    _ = @import("store_feed_visibility.zig");
    _ = @import("store_vector.zig");
    _ = @import("store_vector_payload.zig");
    _ = @import("store_config.zig");
    _ = @import("store_lifecycle.zig");
    _ = @import("store_runtime_search.zig");
    _ = @import("store_primitive_visibility.zig");
    _ = @import("store_connector_cursor.zig");
    _ = @import("store_job.zig");
    _ = @import("store_session.zig");
    _ = @import("store_hygiene.zig");
    _ = @import("store_context_pack.zig");
    _ = @import("store_conflict.zig");
}

fn importOptionalConnectorModules() void {
    if (build_options.enable_engine_redis) _ = @import("redis.zig");
    if (build_options.enable_engine_markdown) {
        _ = @import("markdown_adapter.zig");
        _ = @import("markdown_filesystem.zig");
    }
    if (build_options.enable_engine_qmd) _ = @import("qmd_adapter.zig");
    if (build_options.enable_engine_zep) {
        _ = @import("agent_memory_zep.zig");
    } else {
        _ = @import("agent_memory_zep_disabled.zig");
    }
    if (build_options.enable_engine_falkordb) {
        _ = @import("agent_memory_falkordb.zig");
    } else {
        _ = @import("agent_memory_falkordb_disabled.zig");
    }
}

fn importWorkerAndFacadeModules() void {
    _ = @import("artifacts.zig");
    _ = @import("extraction.zig");
    _ = @import("vector_runtime_summary.zig");
    _ = @import("worker.zig");
    _ = @import("store_cache.zig");
    _ = @import("store.zig");
    _ = @import("store_cache_tests.zig");
}

fn importApiModules() void {
    _ = @import("api_types.zig");
    _ = @import("api_filesystem.zig");
    _ = @import("store_search.zig");
    _ = @import("api_auth.zig");
    _ = @import("api_responses.zig");
    _ = @import("http_request.zig");
    _ = @import("api_query.zig");
    _ = @import("api_agent_memory_response.zig");
    _ = @import("api_catalog.zig");
    _ = @import("api_feed_context.zig");
    _ = @import("api_feed_route.zig");
    _ = @import("api_access.zig");
    _ = @import("api_body.zig");
    _ = @import("api_scopes.zig");
    _ = @import("api_session_access.zig");
    _ = @import("api_search_window.zig");
    _ = @import("api_agent_memory_store.zig");
    _ = @import("api_storage_route.zig");
    _ = @import("api_cache.zig");
    _ = @import("api_cache_keys.zig");
    _ = @import("api_connectors.zig");
    _ = @import("api_embedding.zig");
    _ = @import("api_dispatch.zig");
    _ = @import("api_registry.zig");
    _ = @import("api_health.zig");
    _ = @import("api_memory_providers.zig");
    _ = @import("api_rollout.zig");
    _ = @import("api_diagnostics.zig");
    _ = @import("api_vector.zig");
    _ = @import("api_primitive_list.zig");
    _ = @import("api_manifest.zig");
    _ = @import("api_openapi.zig");
    _ = @import("api.zig");
    _ = @import("api_contract_tests.zig");
    _ = @import("api_cache_tests.zig");
}

test "test import roots delegate module coverage to named suites" {
    const all_tests_source = @embedFile("all_tests.zig");
    const import_smoke_source = @embedFile("import_smoke.zig");
    const profile_tests_source = @embedFile("profile_tests.zig");

    try std.testing.expect(std.mem.indexOf(u8, all_tests_source, "test_imports.importFullImportSuite()") != null);
    try std.testing.expect(std.mem.indexOf(u8, import_smoke_source, "test_imports.importFullImportSuite()") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile_tests_source, "test_imports.importProfileSmokeSuite()") != null);
    try std.testing.expect(std.mem.indexOf(u8, all_tests_source, "@import(\"api.zig\")") == null);
    try std.testing.expect(std.mem.indexOf(u8, all_tests_source, "@import(\"store.zig\")") == null);
    try std.testing.expect(std.mem.indexOf(u8, profile_tests_source, "@import(\"api_openapi.zig\")") == null);
    try std.testing.expect(std.mem.indexOf(u8, profile_tests_source, "@import(\"agent_memory_config.zig\")") == null);
}
