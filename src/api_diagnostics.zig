const std = @import("std");
const build_options = @import("build_options");

const compat = @import("compat.zig");
const domain = @import("domain.zig");
const engines = @import("engines.zig");
const json = @import("json_util.zig");
const lifecycle = @import("lifecycle.zig");
const migrations = @import("migrations.zig");
const providers = @import("providers.zig");
const retrieval = @import("retrieval.zig");
const store_mod = @import("store.zig");
const api_access = @import("api_access.zig");
const api_responses = @import("api_responses.zig");
const api_rollout = @import("api_rollout.zig");
const api_types = @import("api_types.zig");
const vector_runtime_summary = @import("vector_runtime_summary.zig");

pub const Context = api_types.Context;
pub const HttpResponse = api_types.HttpResponse;

const DiagnosticsRuntimeStatus = struct {
    record_store_healthy: bool,
    vector_circuit_degraded: bool,
    provider_circuit_degraded: bool,
    full_detail: bool,
    overall: []const u8,
};

pub fn lifecycleDiagnostics(ctx: *Context) HttpResponse {
    if (!api_access.hasCapability(ctx, "read")) return api_responses.forbidden(ctx);
    const store_diag = ctx.store.lifecycleDiagnostics() catch return api_responses.serverError(ctx);
    const schema_version = ctx.store.schemaVersion() catch -1;
    const schema_ok = schema_version >= migrations.expected_schema_version;
    const diagnostics = lifecycle.Diagnostics{
        .total_memory_atoms = store_diag.total_memory_atoms,
        .stale_memory_atoms = store_diag.stale_memory_atoms,
        .vector_outbox_pending = store_diag.vector_outbox_pending,
        .vector_outbox_running = store_diag.vector_outbox_running,
        .vector_outbox_failed = store_diag.vector_outbox_failed,
        .vector_outbox_expired_running = store_diag.vector_outbox_expired_running,
        .lucid_projection_pending = store_diag.lucid_projection_pending,
        .lucid_projection_failed = store_diag.lucid_projection_failed,
        .graph_projection_pending = store_diag.graph_projection_pending,
        .graph_projection_failed = store_diag.graph_projection_failed,
        .cache_entries = store_diag.cache_entries,
        .response_cache_entries = store_diag.response_cache_entries,
        .semantic_cache_entries = store_diag.semantic_cache_entries,
        .embedding_cache_entries = store_diag.embedding_cache_entries,
        .expired_response_cache_entries = store_diag.expired_response_cache_entries,
        .expired_semantic_cache_entries = store_diag.expired_semantic_cache_entries,
        .queued_jobs = store_diag.queued_jobs,
        .running_jobs = store_diag.running_jobs,
        .failed_jobs = store_diag.failed_jobs,
        .expired_running_jobs = store_diag.expired_running_jobs,
        .pending_feed_events = store_diag.pending_feed_events,
        .applying_feed_events = store_diag.applying_feed_events,
        .open_conflicts = store_diag.open_conflicts,
        .agent_memories = store_diag.agent_memories,
        .sessions = store_diag.sessions,
    };
    const full_detail = diagnosticsFullDetail(ctx);
    const record_store_healthy = ctx.store.health();
    const vector_circuit_degraded = vectorCircuitDegraded(ctx);
    const provider_circuit_degraded = providerRuntimeCircuitDegraded(ctx);
    const runtime_status = DiagnosticsRuntimeStatus{
        .record_store_healthy = record_store_healthy,
        .vector_circuit_degraded = vector_circuit_degraded,
        .provider_circuit_degraded = provider_circuit_degraded,
        .full_detail = full_detail,
        .overall = diagnosticsHealth(diagnostics.health(), schema_ok, record_store_healthy, vector_circuit_degraded, provider_circuit_degraded),
    };
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.print(
        ctx.allocator,
        "{{\"diagnostics\":{{\"health\":\"{s}\",\"total_memory_atoms\":{d},\"stale_memory_atoms\":{d},\"vector_outbox_pending\":{d},\"vector_outbox_running\":{d},\"vector_outbox_failed\":{d},\"vector_outbox_expired_running\":{d},\"lucid_projection_pending\":{d},\"lucid_projection_failed\":{d},\"graph_projection_pending\":{d},\"graph_projection_failed\":{d},\"cache_entries\":{d},\"response_cache_entries\":{d},\"semantic_cache_entries\":{d},\"embedding_cache_entries\":{d},\"expired_response_cache_entries\":{d},\"expired_semantic_cache_entries\":{d},\"queued_jobs\":{d},\"running_jobs\":{d},\"failed_jobs\":{d},\"expired_running_jobs\":{d},\"pending_feed_events\":{d},\"applying_feed_events\":{d},\"open_conflicts\":{d},\"agent_memories\":{d},\"sessions\":{d},\"runtime\":",
        .{ runtime_status.overall, diagnostics.total_memory_atoms, diagnostics.stale_memory_atoms, diagnostics.vector_outbox_pending, diagnostics.vector_outbox_running, diagnostics.vector_outbox_failed, diagnostics.vector_outbox_expired_running, diagnostics.lucid_projection_pending, diagnostics.lucid_projection_failed, diagnostics.graph_projection_pending, diagnostics.graph_projection_failed, diagnostics.cache_entries, diagnostics.response_cache_entries, diagnostics.semantic_cache_entries, diagnostics.embedding_cache_entries, diagnostics.expired_response_cache_entries, diagnostics.expired_semantic_cache_entries, diagnostics.queued_jobs, diagnostics.running_jobs, diagnostics.failed_jobs, diagnostics.expired_running_jobs, diagnostics.pending_feed_events, diagnostics.applying_feed_events, diagnostics.open_conflicts, diagnostics.agent_memories, diagnostics.sessions },
    ) catch return api_responses.serverError(ctx);
    appendRuntimeDiagnostics(ctx, &out, schema_version, schema_ok, store_diag, runtime_status) catch return api_responses.serverError(ctx);
    if (ctx.provider.runtime()) |runtime| {
        out.appendSlice(ctx.allocator, ",\"providers\":") catch return api_responses.serverError(ctx);
        if (runtime_status.full_detail) {
            runtime.appendStatusJson(ctx.allocator, &out) catch return api_responses.serverError(ctx);
        } else {
            appendProviderRuntimeSummaryJson(ctx, &out, runtime) catch return api_responses.serverError(ctx);
        }
    }
    out.appendSlice(ctx.allocator, "}}") catch return api_responses.serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return api_responses.serverError(ctx) };
}

pub fn embeddingProviderConfigured(ctx: *Context) bool {
    return switch (ctx.provider.embedding.provider) {
        .local_deterministic => false,
        .openai_compatible => ctx.provider.embedding.base_url != null and ctx.provider.embedding.model != null,
        .ollama => true,
        .gemini, .voyage => ctx.provider.embedding.api_key != null,
    };
}

pub fn llmRerankConfigured(ctx: *Context) bool {
    return ctx.provider.completion.base_url != null and ctx.provider.completion.model != null;
}

fn diagnosticsFullDetail(ctx: *Context) bool {
    return api_access.hasCapability(ctx, "export") and domain.hasActorScope(ctx.actor_scopes_json, "admin");
}

fn providerRuntimeCircuitDegraded(ctx: *Context) bool {
    const runtime = ctx.provider.runtime() orelse return false;
    runtime.mutex.lockUncancelable(compat.io());
    defer runtime.mutex.unlock(compat.io());
    if (runtime.embedding_primary.circuit.state != .closed) return true;
    for (runtime.embedding_fallbacks) |fallback| {
        if (fallback.circuit.state != .closed) return true;
    }
    return runtime.completion.circuit.state != .closed;
}

fn appendProviderRuntimeSummaryJson(ctx: *Context, out: *std.ArrayListUnmanaged(u8), runtime: *providers.ProviderRuntime) !void {
    runtime.mutex.lockUncancelable(compat.io());
    defer runtime.mutex.unlock(compat.io());

    const circuit_count: usize = 2 + runtime.embedding_fallbacks.len;
    var degraded_count: usize = 0;
    if (runtime.embedding_primary.circuit.state != .closed) degraded_count += 1;
    if (runtime.completion.circuit.state != .closed) degraded_count += 1;
    for (runtime.embedding_fallbacks) |fallback| {
        if (fallback.circuit.state != .closed) degraded_count += 1;
    }
    try out.print(ctx.allocator, "{{\"redacted\":true,\"circuit_count\":{d},\"degraded_circuit_count\":{d}}}", .{ circuit_count, degraded_count });
}

fn vectorCircuitDegraded(ctx: *Context) bool {
    const circuit = ctx.store.vector_runtime.circuit_breaker.circuit;
    return circuit.enabled and circuit.state != .closed;
}

fn diagnosticsHealth(base_health: []const u8, schema_ok: bool, record_store_healthy: bool, vector_circuit_degraded: bool, provider_circuit_degraded: bool) []const u8 {
    if (!record_store_healthy) return "unhealthy";
    if (!schema_ok) return "degraded";
    if (vector_circuit_degraded) return "degraded";
    if (provider_circuit_degraded) return "degraded";
    return base_health;
}

fn appendDiagnosticIssues(ctx: *Context, out: *std.ArrayListUnmanaged(u8), schema_ok: bool, store_diag: store_mod.LifecycleDiagnostics, runtime_status: DiagnosticsRuntimeStatus) !void {
    var first = true;
    if (!runtime_status.record_store_healthy) try appendDiagnosticIssue(ctx, out, &first, "record_store_unhealthy");
    if (!schema_ok) try appendDiagnosticIssue(ctx, out, &first, "schema_outdated");
    if (runtime_status.vector_circuit_degraded) try appendDiagnosticIssue(ctx, out, &first, "vector_circuit_degraded");
    if (runtime_status.provider_circuit_degraded) try appendDiagnosticIssue(ctx, out, &first, "provider_circuit_degraded");
    if (store_diag.failed_jobs > 0) try appendDiagnosticIssue(ctx, out, &first, "failed_jobs");
    if (store_diag.expired_running_jobs > 0) try appendDiagnosticIssue(ctx, out, &first, "expired_running_job_leases");
    if (store_diag.vector_outbox_failed > 0) try appendDiagnosticIssue(ctx, out, &first, "vector_outbox_failed");
    if (store_diag.vector_outbox_expired_running > 0) try appendDiagnosticIssue(ctx, out, &first, "expired_vector_outbox_leases");
    if (store_diag.lucid_projection_failed > 0) try appendDiagnosticIssue(ctx, out, &first, "lucid_projection_failed");
    if (store_diag.graph_projection_failed > 0) try appendDiagnosticIssue(ctx, out, &first, "graph_projection_failed");
    if (lifecycle.memoryStalenessNeedsReview(store_diag.stale_memory_atoms, store_diag.total_memory_atoms)) try appendDiagnosticIssue(ctx, out, &first, "memory_staleness_needs_review");
    if (store_diag.queued_jobs > 1000) try appendDiagnosticIssue(ctx, out, &first, "job_queue_backlog");
    if (store_diag.pending_feed_events > 1000 or store_diag.applying_feed_events > 1000) try appendDiagnosticIssue(ctx, out, &first, "feed_backlog");
}

fn appendDiagnosticIssue(ctx: *Context, out: *std.ArrayListUnmanaged(u8), first: *bool, issue: []const u8) !void {
    if (!first.*) try out.append(ctx.allocator, ',');
    first.* = false;
    try json.appendString(out, ctx.allocator, issue);
}

fn appendRuntimeDiagnostics(ctx: *Context, out: *std.ArrayListUnmanaged(u8), schema_version: i64, schema_ok: bool, store_diag: store_mod.LifecycleDiagnostics, runtime_status: DiagnosticsRuntimeStatus) !void {
    try out.appendSlice(ctx.allocator, "{\"record_store\":");
    try json.appendString(out, ctx.allocator, ctx.store.backendName());
    try out.appendSlice(ctx.allocator, ",\"record_store_healthy\":");
    try out.appendSlice(ctx.allocator, if (runtime_status.record_store_healthy) "true" else "false");
    try out.print(ctx.allocator, ",\"schema_version\":{d},\"expected_schema_version\":{d},\"schema_ok\":{s},\"detail\":", .{ schema_version, migrations.expected_schema_version, if (schema_ok) "true" else "false" });
    try json.appendString(out, ctx.allocator, if (runtime_status.full_detail) "full" else "summary");
    try out.appendSlice(ctx.allocator, ",\"redacted\":");
    try out.appendSlice(ctx.allocator, if (runtime_status.full_detail) "false" else "true");
    try out.appendSlice(ctx.allocator, ",\"health\":");
    try appendRuntimeHealthDiagnostics(ctx, out, schema_ok, store_diag, runtime_status);
    try out.appendSlice(ctx.allocator, ",\"build\":");
    try appendBuildDiagnostics(ctx, out, runtime_status.full_detail);
    try out.appendSlice(ctx.allocator, ",\"agent_memory_store\":");
    try json.appendString(out, ctx.allocator, ctx.store.agentMemoryBackendName());
    try out.appendSlice(ctx.allocator, ",\"agent_memory\":");
    try appendAgentMemoryRuntimeDiagnostics(ctx, out, runtime_status.full_detail);
    try out.appendSlice(ctx.allocator, ",\"vector\":{\"index\":");
    try json.appendString(out, ctx.allocator, ctx.store.vectorBackendName());
    try out.appendSlice(ctx.allocator, ",\"local_engine\":");
    try json.appendString(out, ctx.allocator, ctx.store.localVectorEngineName());
    try out.appendSlice(ctx.allocator, ",\"search_engine\":");
    try json.appendString(out, ctx.allocator, ctx.store.effectiveVectorSearchEngineName());
    try out.appendSlice(ctx.allocator, ",\"external_enabled\":");
    try out.appendSlice(ctx.allocator, if (ctx.store.hasExternalVectorStores()) "true" else "false");
    try out.print(ctx.allocator, ",\"external_sink_count\":{d}", .{ctx.store.vectorExternalSinkCount()});
    if (runtime_status.full_detail) {
        const external_sinks = try ctx.store.vectorExternalSinksJson(ctx.allocator);
        defer ctx.allocator.free(external_sinks);
        try out.appendSlice(ctx.allocator, ",\"external_sinks\":");
        try vector_runtime_summary.appendExternalSinks(ctx.allocator, out, external_sinks);
    } else {
        try out.appendSlice(ctx.allocator, ",\"external_sinks_redacted\":true");
    }
    const vector_breaker = ctx.store.vector_runtime.circuit_breaker.circuit;
    try out.appendSlice(ctx.allocator, ",\"circuit_breaker\":{\"enabled\":");
    try out.appendSlice(ctx.allocator, if (vector_breaker.enabled) "true" else "false");
    try out.appendSlice(ctx.allocator, ",\"state\":");
    try json.appendString(out, ctx.allocator, ctx.store.vector_runtime.stateName());
    try out.print(
        ctx.allocator,
        ",\"failure_count\":{d},\"threshold\":{d},\"cooldown_ms\":{d},\"last_failure_ms\":{d},\"attempts\":{d},\"successes\":{d},\"failures\":{d},\"skipped\":{d}}}",
        .{
            vector_breaker.failure_count,
            vector_breaker.failure_threshold,
            vector_breaker.cooldown_ms,
            vector_breaker.last_failure_ms,
            vector_breaker.attempts,
            vector_breaker.successes,
            vector_breaker.failures,
            vector_breaker.skipped,
        },
    );
    try out.print(ctx.allocator, ",\"outbox_active\":true,\"outbox_pending\":{d},\"outbox_running\":{d},\"outbox_failed\":{d},\"outbox_expired_running\":{d}}}", .{ store_diag.vector_outbox_pending, store_diag.vector_outbox_running, store_diag.vector_outbox_failed, store_diag.vector_outbox_expired_running });
    try out.appendSlice(ctx.allocator, ",\"lucid\":{\"backend\":");
    try json.appendString(out, ctx.allocator, ctx.store.lucidBackendName());
    try out.appendSlice(ctx.allocator, ",\"enabled\":");
    try out.appendSlice(ctx.allocator, if (ctx.store.lucid_projection.isEnabled()) "true" else "false");
    try out.print(ctx.allocator, ",\"pending\":{d},\"failed\":{d}}}", .{ store_diag.lucid_projection_pending, store_diag.lucid_projection_failed });
    try out.appendSlice(ctx.allocator, ",\"graph_projection\":{\"backend\":");
    try json.appendString(out, ctx.allocator, ctx.store.graphProjectionBackendName());
    try out.appendSlice(ctx.allocator, ",\"enabled\":");
    try out.appendSlice(ctx.allocator, if (ctx.store.graph_projection.isEnabled()) "true" else "false");
    try out.print(ctx.allocator, ",\"pending\":{d},\"failed\":{d}}}", .{ store_diag.graph_projection_pending, store_diag.graph_projection_failed });
    try out.appendSlice(ctx.allocator, ",\"analytics\":{\"backend\":");
    try json.appendString(out, ctx.allocator, ctx.store.analyticsBackendName());
    try out.appendSlice(ctx.allocator, "},\"cache\":{\"response_cache_active\":true,\"semantic_cache_active\":true,\"embedding_cache_active\":true");
    try out.print(
        ctx.allocator,
        ",\"entries\":{d},\"response_entries\":{d},\"semantic_entries\":{d},\"embedding_entries\":{d},\"expired_response_entries\":{d},\"expired_semantic_entries\":{d}",
        .{ store_diag.cache_entries, store_diag.response_cache_entries, store_diag.semantic_cache_entries, store_diag.embedding_cache_entries, store_diag.expired_response_cache_entries, store_diag.expired_semantic_cache_entries },
    );
    try out.appendSlice(ctx.allocator, "},\"jobs\":{");
    try out.print(ctx.allocator, "\"queued\":{d},\"running\":{d},\"failed\":{d},\"expired_running\":{d},\"lease_model\":\"locked_until_ms\",\"reclaim_on_claim\":true", .{ store_diag.queued_jobs, store_diag.running_jobs, store_diag.failed_jobs, store_diag.expired_running_jobs });
    try out.appendSlice(ctx.allocator, "},\"feed\":{");
    try out.print(ctx.allocator, "\"pending\":{d},\"applying\":{d}", .{ store_diag.pending_feed_events, store_diag.applying_feed_events });
    const llm_rerank_configured = llmRerankConfigured(ctx);
    try out.appendSlice(ctx.allocator, "},\"retrieval\":{\"keyword\":true,\"vector\":true,\"adaptive_retrieval\":true,\"graph\":");
    try out.appendSlice(ctx.allocator, if (build_options.enable_engine_kg) "true" else "false");
    try out.appendSlice(ctx.allocator, ",\"query_expansion\":true,\"rrf\":true,\"min_relevance\":true,\"temporal_decay\":true,\"mmr\":true,\"mmr_lambda\":true,\"mmr_candidate_window\":true,\"llm_rerank\":true,\"candidate_id_rerank\":true,\"quality_rerank\":true,\"rerank_candidate_limit\":true,\"strict_reranker\":true,\"limit\":true,\"llm_rerank_configured\":");
    try out.appendSlice(ctx.allocator, if (llm_rerank_configured) "true" else "false");
    try out.appendSlice(ctx.allocator, ",\"quality_rerank_configured\":");
    try out.appendSlice(ctx.allocator, if (llm_rerank_configured) "true" else "false");
    try out.print(ctx.allocator, ",\"rerank_candidate_limit_default\":{d},\"rerank_candidate_limit_max\":{d}", .{ retrieval.default_rerank_candidate_limit, retrieval.max_rerank_candidate_limit });
    try out.appendSlice(ctx.allocator, ",\"summarizer\":true,\"rollout\":");
    try api_rollout.appendPolicyJson(ctx, out, ctx.retrieval_rollout_policy);
    try out.appendSlice(ctx.allocator, "},\"embedding_provider\":{\"provider\":");
    try json.appendString(out, ctx.allocator, ctx.provider.embedding.provider.name());
    try out.appendSlice(ctx.allocator, ",\"external_configured\":");
    try out.appendSlice(ctx.allocator, if (embeddingProviderConfigured(ctx)) "true" else "false");
    try out.print(ctx.allocator, ",\"fallback_count\":{d},\"route_count\":{d},\"dimensions\":{d},\"max_response_bytes\":{d}}}", .{ ctx.provider.embedding.fallbacks.len, ctx.provider.embedding.routes.len, ctx.provider.embedding.dimensions, ctx.provider.embedding.max_response_bytes });
    try out.appendSlice(ctx.allocator, ",\"completion_provider\":{\"configured\":");
    try out.appendSlice(ctx.allocator, if (ctx.provider.completion.base_url != null and ctx.provider.completion.model != null) "true" else "false");
    try out.print(ctx.allocator, ",\"max_response_bytes\":{d}}}", .{ctx.provider.completion.max_response_bytes});
    try out.appendSlice(ctx.allocator, "}");
}

fn appendRuntimeHealthDiagnostics(ctx: *Context, out: *std.ArrayListUnmanaged(u8), schema_ok: bool, store_diag: store_mod.LifecycleDiagnostics, runtime_status: DiagnosticsRuntimeStatus) !void {
    try out.appendSlice(ctx.allocator, "{\"status\":");
    try json.appendString(out, ctx.allocator, runtime_status.overall);
    try out.appendSlice(ctx.allocator, ",\"record_store\":");
    try json.appendString(out, ctx.allocator, if (runtime_status.record_store_healthy) "ok" else "unhealthy");
    try out.appendSlice(ctx.allocator, ",\"schema\":");
    try json.appendString(out, ctx.allocator, if (schema_ok) "ok" else "degraded");
    try out.appendSlice(ctx.allocator, ",\"vector\":");
    try json.appendString(out, ctx.allocator, if (runtime_status.vector_circuit_degraded or store_diag.vector_outbox_failed > 0 or store_diag.vector_outbox_expired_running > 0) "degraded" else "ok");
    try out.appendSlice(ctx.allocator, ",\"providers\":");
    try json.appendString(out, ctx.allocator, if (runtime_status.provider_circuit_degraded) "degraded" else "ok");
    try out.appendSlice(ctx.allocator, ",\"jobs\":");
    try json.appendString(out, ctx.allocator, if (store_diag.failed_jobs > 0 or store_diag.expired_running_jobs > 0) "degraded" else "ok");
    try out.appendSlice(ctx.allocator, ",\"lucid\":");
    try json.appendString(out, ctx.allocator, if (store_diag.lucid_projection_failed > 0) "degraded" else "ok");
    try out.appendSlice(ctx.allocator, ",\"graph_projection\":");
    try json.appendString(out, ctx.allocator, if (store_diag.graph_projection_failed > 0) "degraded" else "ok");
    try out.appendSlice(ctx.allocator, ",\"issues\":[");
    try appendDiagnosticIssues(ctx, out, schema_ok, store_diag, runtime_status);
    try out.appendSlice(ctx.allocator, "]}");
}

fn appendBuildDiagnostics(ctx: *Context, out: *std.ArrayListUnmanaged(u8), full_detail: bool) !void {
    try out.appendSlice(ctx.allocator, "{\"version\":");
    try json.appendString(out, ctx.allocator, build_options.version);
    try out.appendSlice(ctx.allocator, ",\"engine_profile\":");
    try json.appendString(out, ctx.allocator, build_options.engine_profile);
    try out.appendSlice(ctx.allocator, ",\"engine_selection\":");
    try json.appendString(out, ctx.allocator, build_options.engine_selection);
    try out.appendSlice(ctx.allocator, ",\"records_selection\":");
    try json.appendString(out, ctx.allocator, build_options.records_selection);
    try out.appendSlice(ctx.allocator, ",\"agent_memory_selection\":");
    try json.appendString(out, ctx.allocator, build_options.agent_memory_selection);
    try out.appendSlice(ctx.allocator, ",\"vectors_selection\":");
    try json.appendString(out, ctx.allocator, build_options.vectors_selection);
    if (full_detail) {
        try out.appendSlice(ctx.allocator, ",\"compiled_engines\":{");
        try out.print(
            ctx.allocator,
            "\"none\":{s},\"sqlite\":{s},\"markdown\":{s},\"hybrid\":{s},\"memory_lru\":{s},\"kg\":{s},\"postgres\":{s},\"redis\":{s},\"clickhouse\":{s},\"api\":{s},\"supermemory\":{s},\"openviking\":{s},\"honcho\":{s},\"mem0\":{s},\"hindsight\":{s},\"retaindb\":{s},\"byterover\":{s},\"holographic\":{s},\"zep\":{s},\"falkordb\":{s},\"pgvector\":{s},\"qdrant\":{s},\"lancedb\":{s},\"lancedb_http\":{s},\"weaviate\":{s},\"chroma\":{s},\"opensearch\":{s},\"neo4j\":{s},\"lucid\":{s},\"qmd\":{s}",
            .{
                if (build_options.enable_engine_none) "true" else "false",
                if (build_options.enable_engine_sqlite) "true" else "false",
                if (build_options.enable_engine_markdown) "true" else "false",
                if (build_options.enable_engine_hybrid) "true" else "false",
                if (build_options.enable_engine_memory_lru) "true" else "false",
                if (build_options.enable_engine_kg) "true" else "false",
                if (build_options.enable_engine_postgres) "true" else "false",
                if (build_options.enable_engine_redis) "true" else "false",
                if (build_options.enable_engine_clickhouse) "true" else "false",
                if (build_options.enable_engine_api) "true" else "false",
                if (build_options.enable_engine_supermemory) "true" else "false",
                if (build_options.enable_engine_openviking) "true" else "false",
                if (build_options.enable_engine_honcho) "true" else "false",
                if (build_options.enable_engine_mem0) "true" else "false",
                if (build_options.enable_engine_hindsight) "true" else "false",
                if (build_options.enable_engine_retaindb) "true" else "false",
                if (build_options.enable_engine_byterover) "true" else "false",
                if (build_options.enable_engine_holographic) "true" else "false",
                if (build_options.enable_engine_zep) "true" else "false",
                if (build_options.enable_engine_falkordb) "true" else "false",
                if (build_options.enable_engine_pgvector) "true" else "false",
                if (build_options.enable_engine_qdrant) "true" else "false",
                if (build_options.enable_engine_lancedb) "true" else "false",
                if (build_options.enable_engine_lancedb_http) "true" else "false",
                if (build_options.enable_engine_weaviate) "true" else "false",
                if (build_options.enable_engine_chroma) "true" else "false",
                if (build_options.enable_engine_opensearch) "true" else "false",
                if (build_options.enable_engine_neo4j) "true" else "false",
                if (build_options.enable_engine_lucid) "true" else "false",
                if (build_options.enable_engine_qmd) "true" else "false",
            },
        );
        try out.appendSlice(ctx.allocator, "},\"compiled_engine_roles\":");
        try engines.appendEngineRolesJson(ctx.allocator, out);
        try out.appendSlice(ctx.allocator, ",\"compiled_retrieval\":");
        try engines.appendRetrievalJson(ctx.allocator, out);
        try out.appendSlice(ctx.allocator, ",\"nullclaw_adapter\":");
        try out.appendSlice(ctx.allocator, if (build_options.enable_nullclaw_adapter) "true" else "false");
    } else {
        try out.appendSlice(ctx.allocator, ",\"compiled_engines_redacted\":true");
    }
    try out.appendSlice(ctx.allocator, "}");
}

fn appendAgentMemoryRuntimeDiagnostics(ctx: *Context, out: *std.ArrayListUnmanaged(u8), full_detail: bool) !void {
    try out.appendSlice(ctx.allocator, "{\"store\":");
    try json.appendString(out, ctx.allocator, ctx.store.agent_memory.backendName());
    try out.appendSlice(ctx.allocator, ",\"external\":");
    try out.appendSlice(ctx.allocator, if (ctx.store.agent_memory.isExternal()) "true" else "false");
    try out.appendSlice(ctx.allocator, ",\"noop\":");
    try out.appendSlice(ctx.allocator, if (ctx.store.agent_memory.isNoop()) "true" else "false");
    try out.appendSlice(ctx.allocator, ",\"supports_feed\":");
    try out.appendSlice(ctx.allocator, if (ctx.store.agent_memory.supportsFeed()) "true" else "false");
    try out.print(ctx.allocator, ",\"named_store_count\":{d}", .{ctx.store.agent_memory_stores.count()});
    if (!full_detail) {
        try out.appendSlice(ctx.allocator, ",\"named_stores_redacted\":true}");
        return;
    }
    try out.appendSlice(ctx.allocator, ",\"named_stores\":[");
    for (ctx.store.agent_memory_stores.stores.items, 0..) |*named, i| {
        if (i > 0) try out.append(ctx.allocator, ',');
        try out.appendSlice(ctx.allocator, "{\"name\":");
        try json.appendString(out, ctx.allocator, named.name);
        try out.appendSlice(ctx.allocator, ",\"store\":");
        try json.appendString(out, ctx.allocator, named.runtime.backendName());
        try out.appendSlice(ctx.allocator, ",\"external\":");
        try out.appendSlice(ctx.allocator, if (named.runtime.isExternal()) "true" else "false");
        try out.appendSlice(ctx.allocator, ",\"noop\":");
        try out.appendSlice(ctx.allocator, if (named.runtime.isNoop()) "true" else "false");
        try out.appendSlice(ctx.allocator, ",\"supports_feed\":");
        try out.appendSlice(ctx.allocator, if (named.runtime.supportsFeed()) "true" else "false");
        try out.append(ctx.allocator, '}');
    }
    try out.appendSlice(ctx.allocator, "]}");
}

test "diagnostics provider helpers distinguish configured local and remote providers" {
    var ctx = Context{
        .allocator = std.testing.allocator,
        .store = undefined,
    };
    try std.testing.expect(!embeddingProviderConfigured(&ctx));
    ctx.provider.embedding = .{
        .provider = .openai_compatible,
        .base_url = "https://example.test",
        .model = "embed",
    };
    try std.testing.expect(embeddingProviderConfigured(&ctx));
    try std.testing.expect(!llmRerankConfigured(&ctx));
    ctx.provider.completion = .{
        .base_url = "https://example.test",
        .model = "rerank",
    };
    try std.testing.expect(llmRerankConfigured(&ctx));
}
