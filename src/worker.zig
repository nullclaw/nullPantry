const std = @import("std");
const build_options = @import("build_options");
const store_mod = @import("store.zig");
const storage_routes = @import("storage_route.zig");
const domain = @import("domain.zig");
const extraction = @import("extraction.zig");
const providers = @import("providers.zig");
const vector = @import("vector.zig");
const vector_text = @import("vector_text.zig");
const json = @import("json_util.zig");
const job_types = @import("job_types.zig");
const ids = @import("ids.zig");
const compat = @import("compat.zig");
const embedding_cache = @import("embedding_cache.zig");
const summarizer = @import("summarizer.zig");
const access = @import("access.zig");
const bounded_int = @import("bounded_int.zig");
const runtime_config = @import("runtime_config.zig");
const vector_runtime_summary = @import("vector_runtime_summary.zig");

fn localVectorOutboxTestsEnabled() bool {
    return !build_options.enable_engine_pgvector and
        !build_options.enable_engine_qdrant and
        !build_options.enable_engine_lancedb and
        !build_options.enable_engine_lancedb_http and
        !build_options.enable_engine_weaviate and
        !build_options.enable_engine_chroma and
        !build_options.enable_engine_opensearch;
}

pub const default_run_job_limit: usize = 25;
pub const default_run_outbox_limit: usize = 100;
pub const max_run_request_job_limit: usize = 500;
pub const max_run_request_outbox_limit: usize = 500;
const max_job_usize_option: usize = 20_000;

pub const RunOptions = struct {
    scopes_json: []const u8 = runtime_config.admin_scopes_json,
    capabilities_json: []const u8 = runtime_config.admin_capabilities_json,
    job_limit: usize = default_run_job_limit,
    outbox_limit: usize = default_run_outbox_limit,
    provider: runtime_config.ProviderConfig = .{},
    use_embedding_cache: bool = true,
    embedding_cache_max_entries: usize = embedding_cache.default_max_entries,
    chunker: vector.ChunkerConfig = .{},
    actor_id: []const u8 = runtime_config.worker_actor_id,
    worker_id: ?[]const u8 = null,

    pub fn validateUsable(self: RunOptions) !void {
        (runtime_config.PrincipalConfig{
            .actor_id = self.actor_id,
            .scopes_json = self.scopes_json,
            .capabilities_json = self.capabilities_json,
        }).validateUsable() catch return error.InvalidWorkerRunOptions;
        if (self.worker_id) |worker_id| {
            if (std.mem.trim(u8, worker_id, " \t\r\n").len == 0) return error.InvalidWorkerRunOptions;
        }
    }
};

pub fn requestJobLimit(raw: ?i64) usize {
    return positiveRequestLimit(raw, default_run_job_limit, max_run_request_job_limit);
}

pub fn requestOutboxLimit(raw: ?i64) usize {
    return positiveRequestLimit(raw, default_run_outbox_limit, max_run_request_outbox_limit);
}

fn positiveRequestLimit(raw: ?i64, fallback: usize, max_value: usize) usize {
    const value = raw orelse return fallback;
    if (value <= 0) return fallback;
    return bounded_int.positiveI64ToUsizeBounded(value, max_value);
}

fn normalizeRunOptions(options: *RunOptions) void {
    options.job_limit = @min(options.job_limit, max_job_usize_option);
    options.outbox_limit = @min(options.outbox_limit, max_job_usize_option);
}

fn prepareRunOptions(options: *RunOptions) !void {
    try options.validateUsable();
    normalizeRunOptions(options);
}

pub const RunResult = struct {
    jobs_checked: usize = 0,
    jobs_succeeded: usize = 0,
    jobs_failed: usize = 0,
    vector_outbox_processed: usize = 0,
    vector_outbox_failed: usize = 0,
    lucid_projection_processed: usize = 0,
    lucid_projection_failed: usize = 0,
    graph_projection_processed: usize = 0,
    graph_projection_failed: usize = 0,
};

pub fn runOnce(allocator: std.mem.Allocator, store: *store_mod.Store, run_options: RunOptions) !RunResult {
    var options = run_options;
    try prepareRunOptions(&options);
    const generated_worker_id = try ensureWorkerLeaseId(allocator, &options);
    defer if (generated_worker_id) |value| allocator.free(value);

    var result = RunResult{};
    if (domain.hasActorScope(options.scopes_json, "admin")) {
        const outbox = try runVectorOutboxOnce(allocator, store, options);
        result.vector_outbox_processed += outbox.processed;
        result.vector_outbox_failed += outbox.failed;
    }

    const jobs = try store.listJobs(allocator, .{
        .status = "queued",
        .scopes_json = options.scopes_json,
        .limit = options.job_limit,
        .include_expired_running = true,
    });
    defer store_mod.freeLoadedJobs(allocator, jobs);
    result.jobs_checked = jobs.len;
    for (jobs) |job| {
        if (!(try store.claimJobAs(job.id, leaseWorkerId(options)))) continue;
        try heartbeatClaimedJob(store, job.id, options);
        if (runClaimedJob(allocator, store, job, options)) |summary_json| {
            defer allocator.free(summary_json);
            if (try store.finishJobAs(job.id, "succeeded", summary_json, null, leaseWorkerId(options))) {
                result.jobs_succeeded += 1;
                if (std.mem.eql(u8, job.job_type, "lucid_projection")) result.lucid_projection_processed += 1;
                if (job_types.isGraphProjection(job.job_type)) result.graph_projection_processed += 1;
            } else {
                result.jobs_failed += 1;
                if (std.mem.eql(u8, job.job_type, "lucid_projection")) result.lucid_projection_failed += 1;
                if (job_types.isGraphProjection(job.job_type)) result.graph_projection_failed += 1;
            }
        } else |err| {
            const error_text = @errorName(err);
            _ = try store.finishJobAs(job.id, "failed", "{}", error_text, leaseWorkerId(options));
            result.jobs_failed += 1;
            if (std.mem.eql(u8, job.job_type, "lucid_projection")) result.lucid_projection_failed += 1;
            if (job_types.isGraphProjection(job.job_type)) result.graph_projection_failed += 1;
        }
    }
    return result;
}

pub fn runJobById(allocator: std.mem.Allocator, store: *store_mod.Store, id: []const u8, run_options: RunOptions) !store_mod.Job {
    var options = run_options;
    try prepareRunOptions(&options);
    const generated_worker_id = try ensureWorkerLeaseId(allocator, &options);
    defer if (generated_worker_id) |value| allocator.free(value);

    var job = (try store.getJob(allocator, id)) orelse return error.JobNotFound;
    errdefer store_mod.freeLoadedJob(allocator, &job);
    if (!try store.claimJobAs(job.id, leaseWorkerId(options))) return error.JobNotQueued;
    try heartbeatClaimedJob(store, job.id, options);
    if (runClaimedJob(allocator, store, job, options)) |summary_json| {
        defer allocator.free(summary_json);
        if (!try store.finishJobAs(job.id, "succeeded", summary_json, null, leaseWorkerId(options))) return error.JobLeaseLost;
    } else |err| {
        _ = try store.finishJobAs(job.id, "failed", "{}", @errorName(err), leaseWorkerId(options));
    }
    if (try store.getJob(allocator, id)) |finished| {
        store_mod.freeLoadedJob(allocator, &job);
        return finished;
    }
    return job;
}

pub fn runClaimedJob(allocator: std.mem.Allocator, store: *store_mod.Store, job: store_mod.Job, run_options: RunOptions) ![]const u8 {
    var options = run_options;
    try prepareRunOptions(&options);
    try heartbeatClaimedJob(store, job.id, options);
    if (job_types.isVectorOutbox(job.job_type)) {
        try requireAdminVectorMaintenanceJob(job, options);
        var job_options = options;
        job_options.outbox_limit = @max(job_options.outbox_limit, jobUsizeOption(allocator, job.input_json, "limit", 1000));
        const outbox = try runVectorOutboxOnce(allocator, store, job_options);
        return try std.fmt.allocPrint(allocator, "{{\"vector_outbox_processed\":{d},\"vector_outbox_failed\":{d}}}", .{ outbox.processed, outbox.failed });
    }
    if (job_types.isMemoryDrainOutbox(job.job_type)) {
        try requireAdminVectorMaintenanceJob(job, options);
        return try runMemoryDrainOutboxJob(allocator, store, job, options);
    }
    if (job_types.isMemoryReindex(job.job_type)) {
        try requireAdminVectorMaintenanceJob(job, options);
        return try runMemoryReindexJob(allocator, store, job);
    }
    if (job_types.isVectorRebuild(job.job_type)) {
        try requireAdminVectorMaintenanceJob(job, options);
        return try runVectorMaintenanceJob(allocator, store, job, "vector_rebuild", .rebuild);
    }
    if (job_types.isVectorReconcile(job.job_type)) {
        try requireAdminVectorMaintenanceJob(job, options);
        return try runVectorMaintenanceJob(allocator, store, job, "vector_reconcile", .reconcile);
    }
    if (job_types.isHygiene(job.job_type)) {
        const hard_delete = jobBoolOption(allocator, job.input_json, "hard_delete", false);
        const hygiene_scopes = try jobHygieneScopesJson(allocator, job, options, hard_delete);
        defer allocator.free(hygiene_scopes);
        const dedupe_agent_memory = jobBoolOption(allocator, job.input_json, "dedupe_agent_memory", false);
        const storage_route = try jobStorageRouteOption(allocator, job.input_json);
        defer storage_route.deinit(allocator);
        const dedupe_normalized = jobBoolOption(allocator, job.input_json, "dedupe_normalized", true);
        const dedupe_limit = jobUsizeOption(allocator, job.input_json, "dedupe_limit", 5000);
        var hygiene = try store.runHygiene(.{
            .stale_after_ms = jobIntOption(allocator, job.input_json, "stale_after_ms", 30 * 24 * 60 * 60 * 1000),
            .archive_after_ms = jobIntOption(allocator, job.input_json, "archive_after_ms", 90 * 24 * 60 * 60 * 1000),
            .purge_after_ms = jobIntOption(allocator, job.input_json, "purge_after_ms", 0),
            .hard_delete = hard_delete,
            .dedupe_memory_atoms = jobBoolOption(allocator, job.input_json, "dedupe_memory_atoms", jobBoolOption(allocator, job.input_json, "dedupe", false)),
            .dedupe_agent_memory = dedupe_agent_memory and store.agentMemoryRouteIncludesNative(storage_route),
            .dedupe_normalized = dedupe_normalized,
            .dedupe_limit = dedupe_limit,
            .now_ms = jobOptionalIntOption(allocator, job.input_json, "now_ms"),
            .actor_id = options.actor_id,
            .scopes_json = hygiene_scopes,
            .capabilities_json = options.capabilities_json,
        });
        if (dedupe_agent_memory) {
            try heartbeatClaimedJob(store, job.id, options);
            const category = try jobStringOption(allocator, job.input_json, "category");
            defer if (category) |value| allocator.free(value);
            var session_id = try jobStringOption(allocator, job.input_json, "session_id");
            if (session_id == null) session_id = try jobStringOption(allocator, job.input_json, "session");
            defer if (session_id) |value| allocator.free(value);
            try store.runRoutedAgentMemoryDedupe(allocator, .{
                .hard_delete = hard_delete,
                .dedupe_normalized = dedupe_normalized,
                .dedupe_limit = dedupe_limit,
                .actor_id = options.actor_id,
                .scopes_json = hygiene_scopes,
                .capabilities_json = options.capabilities_json,
            }, storage_route, .{
                .category = category,
                .session_id = session_id,
                .include_internal = jobBoolOption(allocator, job.input_json, "include_internal", false),
            }, &hygiene);
        }
        return try std.fmt.allocPrint(allocator, "{{\"checked\":{d},\"marked_stale\":{d},\"archived\":{d},\"purged\":{d},\"expired_cache_entries\":{d},\"dedupe_checked\":{d},\"dedupe_groups\":{d},\"dedupe_deprecated\":{d},\"dedupe_purged\":{d},\"agent_memory_dedupe_checked\":{d},\"agent_memory_dedupe_groups\":{d},\"agent_memory_dedupe_deprecated\":{d},\"agent_memory_dedupe_purged\":{d}}}", .{ hygiene.checked, hygiene.marked_stale, hygiene.archived, hygiene.purged, hygiene.expired_cache_entries, hygiene.dedupe_checked, hygiene.dedupe_groups, hygiene.dedupe_deprecated, hygiene.dedupe_purged, hygiene.agent_memory_dedupe_checked, hygiene.agent_memory_dedupe_groups, hygiene.agent_memory_dedupe_deprecated, hygiene.agent_memory_dedupe_purged });
    }
    if (job_types.isScanConflicts(job.job_type)) {
        try heartbeatClaimedJob(store, job.id, options);
        const scopes_json = try jobExecutionScopesJson(allocator, job);
        defer allocator.free(scopes_json);
        const conflicts = try store.scanConflicts(allocator, .{ .scopes_json = scopes_json, .limit = 100 });
        defer store_mod.freeKnowledgeConflicts(allocator, conflicts);
        return try std.fmt.allocPrint(allocator, "{{\"conflict_count\":{d}}}", .{conflicts.len});
    }
    if (job_types.isSummarize(job.job_type)) {
        return try runSummarizeJob(allocator, store, job, options);
    }
    if (job_types.isLucidProjection(job.job_type)) {
        return try store.runLucidProjectionJob(allocator, job);
    }
    if (job_types.isGraphProjection(job.job_type)) {
        return try store.runGraphProjectionJob(allocator, job);
    }
    if (job_types.isAgentMemoryMirror(job.job_type)) {
        const mirror_actor_id = try jobStringOption(allocator, job.input_json, "actor_id");
        defer if (mirror_actor_id) |value| allocator.free(value);
        try requireClaimedJobObjectTarget(allocator, store, job, options, mirror_actor_id);
        return try store.runAgentMemoryMirrorJob(allocator, job);
    }
    if (job_types.isIngest(job.job_type)) {
        if (job.object_id.len == 0 or !std.mem.eql(u8, job.object_type, "source")) return error.UnsupportedJob;
        try heartbeatClaimedJob(store, job.id, options);
        var source = (try store.getSource(allocator, job.object_id)) orelse return error.SourceNotFound;
        defer store_mod.freeLoadedSource(allocator, &source);
        try requireClaimedJobTargetAcl(allocator, job, options, source.scope, source.permissions_json);
        var job_options = ExtractionJobOptions{
            .create_artifact = jobBoolOption(allocator, job.input_json, "create_artifact", true),
            .extract_memory = if (std.mem.eql(u8, job.job_type, "extract_memory")) true else jobBoolOption(allocator, job.input_json, "extract_memory", true),
            .use_llm_extraction = jobBoolOption(allocator, job.input_json, "use_llm_extraction", false) or jobBoolOption(allocator, job.input_json, "structured_extraction", false),
            .strict_llm_extraction = jobBoolOption(allocator, job.input_json, "strict_llm_extraction", false),
            .storage_route = try jobStorageRouteOption(allocator, job.input_json),
        };
        defer job_options.storage_route.deinit(allocator);
        const extracted = try extractSource(allocator, store, source, options, job_options);
        return try extraction.resultJson(
            allocator,
            source.id,
            .{
                .artifact_count = extracted.artifact_count,
                .memory_atom_count = extracted.memory_atom_count,
                .entity_count = extracted.entity_count,
                .relation_count = extracted.relation_count,
                .vector_chunk_count = extracted.vector_chunk_count,
            },
            extracted.extraction_provider,
            extracted.extraction_fallback,
        );
    }
    return error.UnsupportedJob;
}

fn heartbeatClaimedJob(store: *store_mod.Store, id: []const u8, options: RunOptions) !void {
    if (!try store.heartbeatJobAs(id, leaseWorkerId(options))) return error.JobLeaseLost;
}

fn requireAdminVectorMaintenanceJob(job: store_mod.Job, options: RunOptions) !void {
    if (!domain.hasActorScope(options.scopes_json, "admin")) return error.Forbidden;
    if (!std.mem.eql(u8, job.scope, "admin")) return error.Forbidden;
    if (!domain.permissionsWritable(job.permissions_json, options.scopes_json)) return error.Forbidden;
}

fn requireClaimedJobObjectTarget(
    allocator: std.mem.Allocator,
    store: *store_mod.Store,
    job: store_mod.Job,
    options: RunOptions,
    actor_id: ?[]const u8,
) !void {
    var acl = (try store.vectorObjectAcl(allocator, job.object_type, job.object_id, actor_id)) orelse return error.JobTargetNotFound;
    defer store_mod.freeVectorObjectAcl(allocator, &acl);
    try requireClaimedJobTargetAcl(allocator, job, options, acl.scope, acl.permissions_json);
}

fn requireClaimedJobTargetAcl(
    allocator: std.mem.Allocator,
    job: store_mod.Job,
    options: RunOptions,
    target_scope: []const u8,
    target_permissions_json: []const u8,
) !void {
    if (!domain.recordVisible(target_scope, target_permissions_json, options.scopes_json)) return error.Forbidden;
    if (!access.aclCoversTarget(allocator, target_scope, target_permissions_json, job.scope, job.permissions_json)) return error.Forbidden;
}

pub fn runVectorOutboxOnce(allocator: std.mem.Allocator, store: *store_mod.Store, run_options: RunOptions) !store_mod.VectorOutboxRunResult {
    var options = run_options;
    try prepareRunOptions(&options);
    const generated_worker_id = try ensureWorkerLeaseId(allocator, &options);
    defer if (generated_worker_id) |value| allocator.free(value);
    if (!domain.hasActorScope(options.scopes_json, "admin")) return error.Forbidden;

    var result = store_mod.VectorOutboxRunResult{};
    const embedded = try runEmbeddingOutbox(allocator, store, options);
    result.processed += embedded.processed;
    result.failed += embedded.failed;
    const indexed = try store.runVectorOutboxAs(options.outbox_limit, leaseWorkerId(options));
    result.processed += indexed.processed;
    result.failed += indexed.failed;
    return result;
}

pub fn makeWorkerLeaseId(allocator: std.mem.Allocator) ![]u8 {
    return ids.make(allocator, "worker_lease_");
}

fn ensureWorkerLeaseId(allocator: std.mem.Allocator, options: *RunOptions) !?[]u8 {
    if (options.worker_id) |worker_id| {
        if (worker_id.len > 0) return null;
    }
    const generated = try makeWorkerLeaseId(allocator);
    options.worker_id = generated;
    return generated;
}

fn leaseWorkerId(options: RunOptions) []const u8 {
    if (options.worker_id) |worker_id| {
        if (worker_id.len > 0) return worker_id;
    }
    return options.actor_id;
}

fn runMemoryDrainOutboxJob(allocator: std.mem.Allocator, store: *store_mod.Store, job: store_mod.Job, options: RunOptions) ![]const u8 {
    var job_options = options;
    job_options.outbox_limit = jobUsizeOption(allocator, job.input_json, "limit", 100);
    job_options.use_embedding_cache = jobBoolOption(allocator, job.input_json, "use_embedding_cache", jobBoolOption(allocator, job.input_json, "use_cache", options.use_embedding_cache));
    job_options.embedding_cache_max_entries = jobUsizeOption(allocator, job.input_json, "embedding_cache_max_entries", options.embedding_cache_max_entries);
    const result = try runVectorOutboxOnce(allocator, store, job_options);
    const pending = try store.countVectorOutbox("pending");
    const embedded = try store.countVectorOutbox("embedded");
    const indexed_local = try store.countVectorOutbox("indexed_local");
    const indexed_external = try store.countVectorOutbox("indexed_external");
    const deleted_external = try store.countVectorOutbox("deleted_external");
    const external_sinks = try store.vectorExternalSinksJson(allocator);
    defer allocator.free(external_sinks);
    return memoryDrainOutboxJobResultJson(
        allocator,
        result,
        .{
            .pending = pending,
            .embedded = embedded,
            .indexed_local = indexed_local,
            .indexed_external = indexed_external,
            .deleted_external = deleted_external,
        },
        .{
            .active_sink = store.vectorBackendName(),
            .local_engine = store.localVectorEngineName(),
            .search_engine = store.effectiveVectorSearchEngineName(),
            .external_sinks_json = external_sinks,
        },
    );
}

fn runMemoryReindexJob(allocator: std.mem.Allocator, store: *store_mod.Store, job: store_mod.Job) ![]const u8 {
    const result = try store.rebuildVectorIndex(allocator, vectorMaintenanceInputFromJob(allocator, job));
    const external_sinks = try store.vectorExternalSinksJson(allocator);
    defer allocator.free(external_sinks);
    return vectorReindexJobResultJson(
        allocator,
        result,
        .{
            .active_sink = store.vectorBackendName(),
            .local_engine = store.localVectorEngineName(),
            .search_engine = store.effectiveVectorSearchEngineName(),
            .external_sinks_json = external_sinks,
        },
    );
}

const VectorMaintenanceKind = enum { rebuild, reconcile };

fn runVectorMaintenanceJob(allocator: std.mem.Allocator, store: *store_mod.Store, job: store_mod.Job, response_key: []const u8, kind: VectorMaintenanceKind) ![]const u8 {
    const input = vectorMaintenanceInputFromJob(allocator, job);
    const result = switch (kind) {
        .rebuild => try store.rebuildVectorIndex(allocator, input),
        .reconcile => try store.reconcileVectorIndex(allocator, input),
    };
    const external_sinks = try store.vectorExternalSinksJson(allocator);
    defer allocator.free(external_sinks);
    return vectorMaintenanceJobResultJson(
        allocator,
        response_key,
        result,
        .{
            .active_sink = store.vectorBackendName(),
            .local_engine = store.localVectorEngineName(),
            .search_engine = store.effectiveVectorSearchEngineName(),
            .external_sinks_json = external_sinks,
        },
    );
}

const VectorOutboxCounts = struct {
    pending: usize = 0,
    embedded: usize = 0,
    indexed_local: usize = 0,
    indexed_external: usize = 0,
    deleted_external: usize = 0,
};

const VectorRuntimeSummary = vector_runtime_summary.Summary;

fn memoryDrainOutboxJobResultJson(
    allocator: std.mem.Allocator,
    result: store_mod.VectorOutboxRunResult,
    counts: VectorOutboxCounts,
    runtime: VectorRuntimeSummary,
) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.print(
        allocator,
        "{{\"drained\":{d},\"failed\":{d},\"memory_outbox\":{{\"processed\":{d},\"pending\":{d},\"embedded\":{d},\"indexed_local\":{d},\"indexed_external\":{d},\"deleted_external\":{d}",
        .{ result.processed, result.failed, result.processed, counts.pending, counts.embedded, counts.indexed_local, counts.indexed_external, counts.deleted_external },
    );
    try vector_runtime_summary.appendFields(allocator, &out, runtime);
    try out.appendSlice(allocator, "}}");
    return out.toOwnedSlice(allocator);
}

fn vectorReindexJobResultJson(
    allocator: std.mem.Allocator,
    result: store_mod.VectorMaintenanceResult,
    runtime: VectorRuntimeSummary,
) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.print(
        allocator,
        "{{\"reindexed\":{d},\"skipped\":false,\"memory_reindex\":{{\"canonical_chunks\":{d},\"enqueued_upserts\":{d},\"requeued_failed\":{d},\"external_enabled\":{s}",
        .{ result.enqueued_upserts, result.canonical_chunks, result.enqueued_upserts, result.requeued_failed, if (result.external_enabled) "true" else "false" },
    );
    try vector_runtime_summary.appendFields(allocator, &out, runtime);
    try out.appendSlice(allocator, "}}");
    return out.toOwnedSlice(allocator);
}

fn vectorMaintenanceJobResultJson(
    allocator: std.mem.Allocator,
    response_key: []const u8,
    result: store_mod.VectorMaintenanceResult,
    runtime: VectorRuntimeSummary,
) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '{');
    try json.appendString(&out, allocator, response_key);
    try out.print(
        allocator,
        ":{{\"canonical_chunks\":{d},\"enqueued_upserts\":{d},\"requeued_failed\":{d},\"external_enabled\":{s}",
        .{ result.canonical_chunks, result.enqueued_upserts, result.requeued_failed, if (result.external_enabled) "true" else "false" },
    );
    try vector_runtime_summary.appendFields(allocator, &out, runtime);
    try out.appendSlice(allocator, "}}");
    return out.toOwnedSlice(allocator);
}

fn vectorMaintenanceInputFromJob(allocator: std.mem.Allocator, job: store_mod.Job) store_mod.VectorMaintenanceInput {
    return .{
        .limit = jobUsizeOption(allocator, job.input_json, "limit", 1000),
        .reset_external = jobBoolOption(allocator, job.input_json, "reset_external", false),
        .retry_failed = jobBoolOption(allocator, job.input_json, "retry_failed", false),
    };
}

fn jobExecutionScopesJson(allocator: std.mem.Allocator, job: store_mod.Job) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.append(allocator, '[');
    var count: usize = 0;
    try appendUniqueScope(allocator, &out, &count, job.scope);
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, job.permissions_json, .{}) catch {
        try out.append(allocator, ']');
        return out.toOwnedSlice(allocator);
    };
    defer parsed.deinit();
    if (parsed.value == .array) {
        for (parsed.value.array.items) |item| {
            if (item == .string) try appendUniqueScope(allocator, &out, &count, item.string);
        }
    }
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

fn jobHygieneScopesJson(allocator: std.mem.Allocator, job: store_mod.Job, options: RunOptions, hard_delete: bool) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '[');
    var count: usize = 0;
    try appendUniqueScope(allocator, &out, &count, job.scope);
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, job.permissions_json, .{}) catch {
        try appendHygieneMutationScopes(allocator, &out, &count, job.scope, options, hard_delete);
        try appendHygieneSessionScope(allocator, &out, &count, job.input_json, options);
        try out.append(allocator, ']');
        return out.toOwnedSlice(allocator);
    };
    defer parsed.deinit();
    if (parsed.value == .array) {
        for (parsed.value.array.items) |item| {
            if (item == .string) try appendUniqueScope(allocator, &out, &count, item.string);
        }
    }
    try appendHygieneMutationScopes(allocator, &out, &count, job.scope, options, hard_delete);
    try appendHygieneSessionScope(allocator, &out, &count, job.input_json, options);
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

fn appendHygieneMutationScopes(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), count: *usize, scope: []const u8, options: RunOptions, hard_delete: bool) !void {
    if (domain.hasCapability(options.scopes_json, options.capabilities_json, "verify") and domain.scopeVerifiable(scope, options.scopes_json)) {
        const verify_scope = try std.fmt.allocPrint(allocator, "verify:{s}", .{scope});
        defer allocator.free(verify_scope);
        try appendUniqueScope(allocator, out, count, verify_scope);
    }
    if (hard_delete and domain.hasCapability(options.scopes_json, options.capabilities_json, "delete") and domain.scopeDeletable(scope, options.scopes_json)) {
        const delete_scope = try std.fmt.allocPrint(allocator, "delete:{s}", .{scope});
        defer allocator.free(delete_scope);
        try appendUniqueScope(allocator, out, count, delete_scope);
    }
}

fn appendHygieneSessionScope(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), count: *usize, input_json: []const u8, options: RunOptions) !void {
    var session_id = try jobStringOption(allocator, input_json, "session_id");
    if (session_id == null) session_id = try jobStringOption(allocator, input_json, "session");
    defer if (session_id) |value| allocator.free(value);
    const sid = session_id orelse return;
    const session_scope = try std.fmt.allocPrint(allocator, "session:{s}", .{sid});
    defer allocator.free(session_scope);
    if (!domain.scopeVisible(session_scope, options.scopes_json)) return;
    try appendUniqueScope(allocator, out, count, session_scope);
}

fn appendUniqueScope(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), count: *usize, scope: []const u8) !void {
    const needle = try json.stringLiteral(allocator, scope);
    defer allocator.free(needle);
    if (std.mem.indexOf(u8, out.items, needle) != null) return;
    if (count.* > 0) try out.append(allocator, ',');
    try json.appendString(out, allocator, scope);
    count.* += 1;
}

const ExtractionCounts = struct {
    artifact_count: usize = 0,
    memory_atom_count: usize = 0,
    entity_count: usize = 0,
    relation_count: usize = 0,
    vector_chunk_count: usize = 0,
    extraction_provider: []const u8 = "heuristic",
    extraction_fallback: bool = false,

    fn addVectorChunks(self: *ExtractionCounts, delta: usize) void {
        self.vector_chunk_count = bounded_int.saturatingUsizeAdd(self.vector_chunk_count, delta);
    }
};

const ExtractionJobOptions = struct {
    create_artifact: bool = true,
    extract_memory: bool = true,
    use_llm_extraction: bool = false,
    strict_llm_extraction: bool = false,
    storage_route: store_mod.AgentMemoryStorageRoute = .{},
};

const default_job_summary_max_chars: usize = 4000;
const max_job_summary_chars: usize = 100_000;
const max_job_summary_items_per_section: usize = 100;
const max_job_summary_window_tokens: usize = 1_000_000;

fn freeExtractionAtomInputs(allocator: std.mem.Allocator, inputs: []const store_mod.MemoryAtomInput) void {
    for (inputs) |input| allocator.free(input.evidence_ranges_json);
}

fn jobBoolOption(allocator: std.mem.Allocator, input_json: []const u8, name: []const u8, fallback: bool) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, input_json, .{}) catch return fallback;
    defer parsed.deinit();
    if (parsed.value != .object) return fallback;
    const value = parsed.value.object.get(name) orelse return fallback;
    return switch (value) {
        .bool => |b| b,
        else => fallback,
    };
}

fn jobIntOption(allocator: std.mem.Allocator, input_json: []const u8, name: []const u8, fallback: i64) i64 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, input_json, .{}) catch return fallback;
    defer parsed.deinit();
    if (parsed.value != .object) return fallback;
    return json.intField(parsed.value.object, name) orelse fallback;
}

fn jobOptionalIntOption(allocator: std.mem.Allocator, input_json: []const u8, name: []const u8) ?i64 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, input_json, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    return json.intField(parsed.value.object, name);
}

fn jobUsizeOption(allocator: std.mem.Allocator, input_json: []const u8, name: []const u8, fallback: usize) usize {
    const raw = jobOptionalIntOption(allocator, input_json, name) orelse return fallback;
    if (raw <= 0) return fallback;
    return bounded_int.positiveI64ToUsizeBounded(raw, max_job_usize_option);
}

fn jobPositiveBoundedOption(raw: ?i64, fallback: usize, max_value: usize) usize {
    const value = raw orelse return fallback;
    if (value <= 0) return 1;
    return bounded_int.positiveI64ToUsizeBounded(value, max_value);
}

fn jobNonNegativeBoundedOption(raw: ?i64, max_value: usize) usize {
    const value = raw orelse return 0;
    if (value <= 0) return 0;
    return bounded_int.positiveI64ToUsizeBounded(value, max_value);
}

fn jobStringOption(allocator: std.mem.Allocator, input_json: []const u8, name: []const u8) !?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, input_json, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    return if (json.stringField(parsed.value.object, name)) |value| try allocator.dupe(u8, value) else null;
}

fn jobStorageRouteOption(allocator: std.mem.Allocator, input_json: []const u8) !store_mod.AgentMemoryStorageRoute {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, input_json, .{}) catch return .{};
    defer parsed.deinit();
    if (parsed.value != .object) return .{};
    return storage_routes.fromObjectOwned(allocator, parsed.value.object);
}

fn runSummarizeJob(allocator: std.mem.Allocator, store: *store_mod.Store, job: store_mod.Job, options: RunOptions) ![]const u8 {
    if (!domain.hasCapability(options.scopes_json, options.capabilities_json, "read")) return error.Forbidden;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const parsed = std.json.parseFromSlice(std.json.Value, scratch, job.input_json, .{}) catch return error.BadRequest;
    if (parsed.value != .object) return error.BadRequest;
    const obj = parsed.value.object;
    if (jobSummarizeHasProviderOverride(obj)) return error.ProviderOverrideNotAllowed;

    const subject_actor_id = try jobSummarizeSubjectActorId(scratch, obj, options);
    const storage_route = try jobStorageRouteOption(scratch, job.input_json);
    const messages = try jobSummarizeMessages(scratch, store, job, obj, options, subject_actor_id, storage_route);
    const max_chars = jobPositiveBoundedOption(json.intField(obj, "max_chars"), default_job_summary_max_chars, max_job_summary_chars);
    const selected = jobSummarizeWindow(obj, messages);

    try heartbeatClaimedJob(store, job.id, options);
    const summary_options = jobSummaryOptions(obj, max_chars);
    const summary = try summarizer.summarizeMessages(scratch, selected.messages, summary_options);
    var summary_text = summary.text;
    var summary_provider = summary.provider;
    var sections_json = summary.sections_json;
    var quality_json = summary.quality_json;
    var strategy = summary.strategy;
    const segment_count = summary.segment_count;
    var truncated = summary.truncated;

    if (json.boolField(obj, "use_llm") orelse false) {
        try heartbeatClaimedJob(store, job.id, options);
        const prompt = try summarizer.buildLlmPrompt(scratch, selected.messages, max_chars, summary_options.profile);
        const system =
            "Summarize only the supplied NullPantry messages. Preserve decisions, constraints, risks, action items, open questions, and durable facts. Cite message indexes as [message:N]. Say I don't know when the messages do not support a claim.";
        if (providers.completeWithSystem(scratch, .{
            .base_url = options.provider.completion.base_url,
            .api_key = options.provider.completion.api_key,
            .model = options.provider.completion.model,
            .timeout_secs = options.provider.completion.timeout_secs,
            .max_response_bytes = options.provider.completion.max_response_bytes,
            .allow_insecure_http = options.provider.completion.allow_insecure_http,
            .runtime = options.provider.runtime(),
        }, system, prompt)) |completion_result| {
            var completion = completion_result;
            defer providers.freeCompletionResult(scratch, &completion);
            const grounded = try summarizer.groundedLlmSummaryAgainstMessages(scratch, completion.content, max_chars, selected.messages);
            if (grounded) |trimmed| {
                summary_text = trimmed.text;
                summary_provider = completion.provider;
                sections_json = try summarizer.sectionsFromGroundedSummary(scratch, trimmed.text, selected.messages, summary_options.max_items_per_section);
                strategy = "llm_grounded";
                const grounded_lines = summarizer.countGroundedSummaryLines(trimmed.text, selected.messages.len);
                quality_json = try summarizer.buildQualityJson(scratch, .{
                    .profile = summary_options.profile,
                    .strategy = strategy,
                    .message_count = selected.messages.len,
                    .segment_count = segment_count,
                    .item_count = grounded_lines,
                    .cited_item_count = grounded_lines,
                    .truncated = trimmed.truncated,
                });
                truncated = trimmed.truncated;
            } else if (json.boolField(obj, "strict_llm") orelse false) {
                return error.UngroundedLlmSummary;
            }
        } else |err| {
            if (json.boolField(obj, "strict_llm") orelse false) return err;
        }
    }

    const persist = (json.boolField(obj, "persist") orelse false) or (json.boolField(obj, "remember") orelse false);
    if (persist) try heartbeatClaimedJob(store, job.id, options);
    const persisted_entry = if (persist)
        try jobPersistSummary(scratch, store, job, obj, options, subject_actor_id, storage_route, summary_text, summary_provider, selected.messages_summarized, sections_json, quality_json, summary.profile, strategy, segment_count)
    else
        null;
    const semantic_facts = if (persist)
        try jobPersistSemanticFacts(scratch, store, job, obj, options, subject_actor_id, storage_route, summary_text, summary_provider)
    else
        &[_]domain.AgentMemory{};

    return try jobSummaryResultJson(allocator, .{
        .summary_text = summary_text,
        .summary_provider = summary_provider,
        .profile = summary.profile,
        .strategy = strategy,
        .message_count = summary.message_count,
        .segment_count = segment_count,
        .messages_summarized = selected.messages_summarized,
        .messages_kept = selected.messages_kept,
        .truncated = truncated,
        .sections_json = sections_json,
        .quality_json = quality_json,
        .persisted_entry = persisted_entry,
        .semantic_facts = semantic_facts,
    });
}

const JobSummaryResult = struct {
    summary_text: []const u8,
    summary_provider: []const u8,
    profile: summarizer.Profile,
    strategy: []const u8,
    message_count: usize,
    segment_count: usize,
    messages_summarized: usize,
    messages_kept: usize,
    truncated: bool,
    sections_json: []const u8,
    quality_json: []const u8,
    persisted_entry: ?domain.AgentMemory = null,
    semantic_facts: []const domain.AgentMemory = &.{},
};

fn jobSummaryResultJson(allocator: std.mem.Allocator, result: JobSummaryResult) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"summary\":");
    try json.appendString(&out, allocator, result.summary_text);
    try out.appendSlice(allocator, ",\"summary_provider\":");
    try json.appendString(&out, allocator, result.summary_provider);
    try out.appendSlice(allocator, ",\"profile\":");
    try json.appendString(&out, allocator, result.profile.name());
    try out.appendSlice(allocator, ",\"summary_strategy\":");
    try json.appendString(&out, allocator, result.strategy);
    try out.print(allocator, ",\"message_count\":{d},\"segment_count\":{d}", .{ result.message_count, result.segment_count });
    try out.print(allocator, ",\"messages_summarized\":{d},\"messages_kept\":{d}", .{ result.messages_summarized, result.messages_kept });
    try out.appendSlice(allocator, ",\"truncated\":");
    try out.appendSlice(allocator, if (result.truncated) "true" else "false");
    try out.appendSlice(allocator, ",\"sections\":");
    try json.appendRawJsonObject(&out, allocator, result.sections_json);
    try out.appendSlice(allocator, ",\"quality\":");
    try json.appendRawJsonObject(&out, allocator, result.quality_json);
    try out.appendSlice(allocator, ",\"persisted\":");
    try out.appendSlice(allocator, if (result.persisted_entry != null) "true" else "false");
    try out.appendSlice(allocator, ",\"semantic_fact_count\":");
    try out.print(allocator, "{d}", .{result.semantic_facts.len});
    try out.appendSlice(allocator, ",\"semantic_facts\":[");
    for (result.semantic_facts, 0..) |fact, i| {
        if (i > 0) try out.append(allocator, ',');
        try fact.writeJson(allocator, &out);
    }
    try out.append(allocator, ']');
    if (result.persisted_entry) |memory| {
        try out.appendSlice(allocator, ",\"memory\":");
        try memory.writeJson(allocator, &out);
    }
    try out.append(allocator, '}');
    return try out.toOwnedSlice(allocator);
}

const SummarizeWindow = struct {
    messages: []const summarizer.Message,
    messages_summarized: usize,
    messages_kept: usize,
};

fn jobSummarizeWindow(obj: std.json.ObjectMap, messages: []const summarizer.Message) SummarizeWindow {
    const window_size_raw = json.intField(obj, "window_size_tokens") orelse json.intField(obj, "window_tokens");
    const window_size_value = window_size_raw orelse return .{
        .messages = messages,
        .messages_summarized = messages.len,
        .messages_kept = 0,
    };
    const window_size = jobPositiveBoundedOption(window_size_value, 1, max_job_summary_window_tokens);
    if (!summarizer.shouldSummarize(messages, window_size)) {
        return .{ .messages = messages, .messages_summarized = messages.len, .messages_kept = 0 };
    }
    const partition = summarizer.partitionMessages(messages, window_size);
    if (partition.to_summarize == 0) return .{ .messages = messages, .messages_summarized = messages.len, .messages_kept = 0 };
    return .{
        .messages = messages[0..partition.to_summarize],
        .messages_summarized = partition.to_summarize,
        .messages_kept = partition.to_keep,
    };
}

fn jobSummaryOptions(obj: std.json.ObjectMap, max_chars: usize) summarizer.Options {
    const profile = summarizer.Profile.parse(jobStringFieldAny(obj, &.{ "summary_profile", "profile", "summary_type", "type" }));
    const raw_items = json.intField(obj, "max_items_per_section") orelse json.intField(obj, "summary_max_items_per_section") orelse 8;
    const max_items_per_section = jobPositiveBoundedOption(raw_items, 8, max_job_summary_items_per_section);
    const map_reduce = (json.boolField(obj, "map_reduce") orelse false) or (json.boolField(obj, "recursive") orelse false);
    var raw_window = json.intField(obj, "summary_window_tokens");
    if (raw_window == null) raw_window = json.intField(obj, "map_reduce_window_tokens");
    if (raw_window == null and map_reduce) {
        raw_window = json.intField(obj, "window_size_tokens");
        if (raw_window == null) raw_window = json.intField(obj, "window_tokens");
    }
    const window_size_tokens = jobNonNegativeBoundedOption(raw_window, max_job_summary_window_tokens);
    return .{
        .max_chars = max_chars,
        .profile = profile,
        .window_size_tokens = window_size_tokens,
        .max_items_per_section = max_items_per_section,
    };
}

fn jobStringFieldAny(obj: std.json.ObjectMap, names: []const []const u8) ?[]const u8 {
    for (names) |name| {
        if (json.stringField(obj, name)) |value| return value;
    }
    return null;
}

fn jobSummarizeHasProviderOverride(obj: std.json.ObjectMap) bool {
    return obj.get("llm_base_url") != null or
        obj.get("llm_api_key") != null or
        obj.get("llm_model") != null or
        obj.get("timeout_secs") != null or
        obj.get("llm_allow_insecure_http") != null or
        obj.get("allow_insecure_http") != null;
}

fn jobSummarizeSubjectActorId(allocator: std.mem.Allocator, obj: std.json.ObjectMap, options: RunOptions) ![]const u8 {
    const requested = json.stringField(obj, "target_actor_id") orelse
        json.stringField(obj, "subject_actor_id") orelse
        json.stringField(obj, "actor_id");
    const actor = requested orelse options.actor_id;
    if (actor.len == 0) return error.MissingActorId;
    if (requested != null and !domain.hasActorScope(options.scopes_json, "admin") and !std.mem.eql(u8, actor, options.actor_id)) return error.Forbidden;
    return try allocator.dupe(u8, actor);
}

fn jobSummarizeMessages(allocator: std.mem.Allocator, store: *store_mod.Store, job: store_mod.Job, obj: std.json.ObjectMap, options: RunOptions, subject_actor_id: []const u8, route: store_mod.AgentMemoryStorageRoute) ![]summarizer.Message {
    var messages: std.ArrayListUnmanaged(summarizer.Message) = .empty;
    errdefer messages.deinit(allocator);

    if (obj.get("messages")) |messages_value| {
        if (messages_value != .array) return error.BadRequest;
        for (messages_value.array.items) |item| {
            switch (item) {
                .string => |content| try messages.append(allocator, .{ .content = content }),
                .object => |message_obj| if (json.stringField(message_obj, "content")) |content| {
                    try messages.append(allocator, .{
                        .role = json.stringField(message_obj, "role") orelse "",
                        .speaker = json.stringField(message_obj, "speaker") orelse json.stringField(message_obj, "author") orelse "",
                        .content = content,
                    });
                },
                else => {},
            }
        }
        return try messages.toOwnedSlice(allocator);
    }

    const session_id = json.stringField(obj, "session_id") orelse json.stringField(obj, "session") orelse return error.MissingMessages;
    if (!try jobSessionReadAllowed(allocator, session_id, options)) return error.Forbidden;
    const message_limit = @min(jobUsizeOption(allocator, job.input_json, "message_limit", jobUsizeOption(allocator, job.input_json, "limit", 500)), 5000);
    const history = try store.historyRouted(allocator, session_id, message_limit, 0, subject_actor_id, route);
    for (history.messages) |message| {
        try messages.append(allocator, .{ .role = message.role, .content = message.content });
    }
    return try messages.toOwnedSlice(allocator);
}

fn jobSessionReadAllowed(allocator: std.mem.Allocator, session_id: []const u8, options: RunOptions) !bool {
    if (domain.hasActorScope(options.scopes_json, "admin")) return true;
    if (!domain.hasCapability(options.scopes_json, options.capabilities_json, "read")) return false;
    const scope = try std.fmt.allocPrint(allocator, "session:{s}", .{session_id});
    return domain.scopeVisible(scope, options.scopes_json);
}

fn jobSessionWriteAllowed(allocator: std.mem.Allocator, session_id: []const u8, options: RunOptions) !bool {
    if (domain.hasActorScope(options.scopes_json, "admin")) return true;
    if (!domain.hasCapability(options.scopes_json, options.capabilities_json, "write")) return false;
    const scope = try std.fmt.allocPrint(allocator, "session:{s}", .{session_id});
    return domain.scopeWritable(scope, options.scopes_json);
}

fn jobPersistSummary(
    allocator: std.mem.Allocator,
    store: *store_mod.Store,
    job: store_mod.Job,
    obj: std.json.ObjectMap,
    options: RunOptions,
    subject_actor_id: []const u8,
    route: store_mod.AgentMemoryStorageRoute,
    summary_text: []const u8,
    summary_provider: []const u8,
    message_count: usize,
    sections_json: []const u8,
    quality_json: []const u8,
    profile: summarizer.Profile,
    strategy: []const u8,
    segment_count: usize,
) !?domain.AgentMemory {
    if (!(domain.hasCapability(options.scopes_json, options.capabilities_json, "write") or domain.hasCapability(options.scopes_json, options.capabilities_json, "propose"))) return error.Forbidden;
    const session_id = json.stringField(obj, "session_id") orelse json.stringField(obj, "session");
    if (session_id) |sid| {
        if (!try jobSessionWriteAllowed(allocator, sid, options)) return error.Forbidden;
    }

    const scope = json.stringField(obj, "scope");
    const permissions = try rawJsonField(allocator, obj, "permissions", job.permissions_json);
    if (scope) |requested_scope| {
        if (!try workerCanProposeRecord(allocator, store, requested_scope, permissions, options)) return error.Forbidden;
    } else if (!domain.permissionsAreOpen(permissions) and !domain.permissionsWritable(permissions, options.scopes_json)) {
        return error.Forbidden;
    }

    var owned_key: ?[]const u8 = null;
    const key = json.stringField(obj, "key") orelse
        json.stringField(obj, "memory_key") orelse
        json.stringField(obj, "summary_key") orelse blk: {
        if (session_id) |sid| {
            owned_key = try std.fmt.allocPrint(allocator, "summary.session.{s}", .{sid});
        } else {
            owned_key = try ids.make(allocator, "summary.");
        }
        break :blk owned_key.?;
    };

    const metadata_json = try jobSummaryMetadataJson(allocator, summary_provider, message_count, sections_json, quality_json, profile, strategy, segment_count);
    const owner_actor_id = try access.agentMemoryOwner(allocator, subject_actor_id, scope);

    return try store.agentMemoryStoreRouted(allocator, .{
        .key = key,
        .content = summary_text,
        .category = json.stringField(obj, "category") orelse "summary",
        .session_id = session_id,
        .scope = scope,
        .permissions_json = permissions,
        .metadata_json = metadata_json,
        .actor_id = owner_actor_id,
        .writer_actor_id = options.actor_id,
        .actor_scopes_json = options.scopes_json,
    }, route);
}

fn jobPersistSemanticFacts(
    allocator: std.mem.Allocator,
    store: *store_mod.Store,
    job: store_mod.Job,
    obj: std.json.ObjectMap,
    options: RunOptions,
    subject_actor_id: []const u8,
    route: store_mod.AgentMemoryStorageRoute,
    summary_text: []const u8,
    summary_provider: []const u8,
) ![]const domain.AgentMemory {
    if (!jobSummarizeAutoExtractSemantic(obj)) return &[_]domain.AgentMemory{};
    if (!(domain.hasCapability(options.scopes_json, options.capabilities_json, "write") or domain.hasCapability(options.scopes_json, options.capabilities_json, "propose"))) return error.Forbidden;
    const session_id = json.stringField(obj, "session_id") orelse json.stringField(obj, "session");
    if (session_id) |sid| {
        if (!try jobSessionWriteAllowed(allocator, sid, options)) return error.Forbidden;
    }

    const facts = try summarizer.extractSemanticFacts(allocator, summary_text, "fact.");
    if (facts.len == 0) return &[_]domain.AgentMemory{};

    const scope = json.stringField(obj, "scope");
    const permissions = try rawJsonField(allocator, obj, "permissions", job.permissions_json);
    if (scope) |requested_scope| {
        if (!try workerCanProposeRecord(allocator, store, requested_scope, permissions, options)) return error.Forbidden;
    } else if (!domain.permissionsAreOpen(permissions) and !domain.permissionsWritable(permissions, options.scopes_json)) {
        return error.Forbidden;
    }

    const owner_actor_id = try access.agentMemoryOwner(allocator, subject_actor_id, scope);
    const key_prefix = try jobSemanticFactKeyPrefix(allocator, obj);
    var out: std.ArrayListUnmanaged(domain.AgentMemory) = .empty;
    errdefer out.deinit(allocator);
    for (facts, 0..) |fact, i| {
        const key = try std.fmt.allocPrint(allocator, "{s}{d}", .{ key_prefix, i });
        const metadata_json = try jobSemanticFactMetadataJson(allocator, summary_provider, i);
        const entry = try store.agentMemoryStoreRouted(allocator, .{
            .key = key,
            .content = fact.content,
            .category = json.stringField(obj, "semantic_fact_category") orelse json.stringField(obj, "fact_category") orelse "core",
            .session_id = null,
            .scope = scope,
            .permissions_json = permissions,
            .metadata_json = metadata_json,
            .actor_id = owner_actor_id,
            .writer_actor_id = options.actor_id,
            .actor_scopes_json = options.scopes_json,
        }, route);
        try out.append(allocator, entry);
    }
    return out.toOwnedSlice(allocator);
}

fn jobSummarizeAutoExtractSemantic(obj: std.json.ObjectMap) bool {
    if (json.boolField(obj, "extract_semantic_facts")) |value| return value;
    if (json.boolField(obj, "auto_extract_semantic")) |value| return value;
    return true;
}

fn jobSemanticFactKeyPrefix(allocator: std.mem.Allocator, obj: std.json.ObjectMap) ![]const u8 {
    if (json.stringField(obj, "semantic_fact_key_prefix")) |prefix| return allocator.dupe(u8, prefix);
    if (json.stringField(obj, "fact_key_prefix")) |prefix| return allocator.dupe(u8, prefix);
    if (json.stringField(obj, "key") orelse json.stringField(obj, "memory_key") orelse json.stringField(obj, "summary_key")) |summary_key| {
        return std.fmt.allocPrint(allocator, "{s}.fact.", .{summary_key});
    }
    if (json.stringField(obj, "session_id") orelse json.stringField(obj, "session")) |sid| {
        return std.fmt.allocPrint(allocator, "summary.session.{s}.fact.", .{sid});
    }
    return ids.make(allocator, "summary.fact.");
}

fn jobSemanticFactMetadataJson(allocator: std.mem.Allocator, summary_provider: []const u8, index: usize) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"summary_provider\":");
    try json.appendString(&out, allocator, summary_provider);
    try out.appendSlice(allocator, ",\"semantic_fact_index\":");
    try out.print(allocator, "{d}", .{index});
    try out.appendSlice(allocator, ",\"extracted_from\":\"summary\"}");
    return out.toOwnedSlice(allocator);
}

fn workerCanProposeRecord(allocator: std.mem.Allocator, store: *store_mod.Store, scope: []const u8, permissions_json: []const u8, options: RunOptions) !bool {
    if (!((domain.hasCapability(options.scopes_json, options.capabilities_json, "propose") or domain.hasCapability(options.scopes_json, options.capabilities_json, "write")) and
        domain.scopeVisible(scope, options.scopes_json) and
        domain.permissionsWritable(permissions_json, options.scopes_json))) return false;
    const policy = try store.getPolicyScope(allocator, scope);
    if (policy) |p| return domain.permissionsWritable(p.permissions_json, options.scopes_json);
    return true;
}

fn jobSummaryMetadataJson(
    allocator: std.mem.Allocator,
    summary_provider: []const u8,
    message_count: usize,
    sections_json: []const u8,
    quality_json: []const u8,
    profile: summarizer.Profile,
    strategy: []const u8,
    segment_count: usize,
) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"summary_provider\":");
    try json.appendString(&out, allocator, summary_provider);
    try out.appendSlice(allocator, ",\"profile\":");
    try json.appendString(&out, allocator, profile.name());
    try out.appendSlice(allocator, ",\"summary_strategy\":");
    try json.appendString(&out, allocator, strategy);
    try out.appendSlice(allocator, ",\"message_count\":");
    try out.print(allocator, "{d}", .{message_count});
    try out.appendSlice(allocator, ",\"segment_count\":");
    try out.print(allocator, "{d}", .{segment_count});
    try out.appendSlice(allocator, ",\"quality\":");
    try json.appendRawJsonObject(&out, allocator, quality_json);
    try out.appendSlice(allocator, ",\"sections\":");
    try json.appendRawJsonObject(&out, allocator, sections_json);
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

fn extractSource(allocator: std.mem.Allocator, store: *store_mod.Store, source: domain.Source, options: RunOptions, job_options: ExtractionJobOptions) !ExtractionCounts {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    return extractSourceWithAllocator(arena.allocator(), store, source, options, job_options);
}

fn extractSourceWithAllocator(allocator: std.mem.Allocator, store: *store_mod.Store, source: domain.Source, options: RunOptions, job_options: ExtractionJobOptions) !ExtractionCounts {
    var counts = ExtractionCounts{};

    const source_ids_json = try extraction.sourceIdsJson(allocator, source.id);
    defer allocator.free(source_ids_json);
    const entity_names_json = try extraction.extractEntityNamesJson(allocator, source.content);
    defer allocator.free(entity_names_json);

    var artifact_input: ?store_mod.ArtifactInput = null;
    var artifact_title: ?[]u8 = null;
    var artifact_summary: ?[]u8 = null;
    var artifact_agent_summary: ?[]u8 = null;
    defer if (artifact_title) |value| allocator.free(value);
    defer if (artifact_summary) |value| allocator.free(value);
    defer if (artifact_agent_summary) |value| allocator.free(value);
    if (job_options.create_artifact) {
        artifact_title = try extraction.sourceTitleForArtifact(allocator, source.title, source.source_type);
        artifact_summary = try extraction.summarize(allocator, source.content, 512);
        artifact_agent_summary = try extraction.summarize(allocator, source.content, 1024);
        artifact_input = .{
            .artifact_type = extraction.artifactTypeForSource(source.source_type),
            .title = artifact_title.?,
            .body = source.content,
            .status = "draft",
            .owner = source.author,
            .scope = source.scope,
            .source_ids_json = source_ids_json,
            .related_entities_json = entity_names_json,
            .permissions_json = source.permissions_json,
            .summary = artifact_summary.?,
            .agent_summary = artifact_agent_summary.?,
            .actor_id = options.actor_id,
            .storage_route = job_options.storage_route,
        };
    }

    var atom_inputs: std.ArrayListUnmanaged(store_mod.MemoryAtomInput) = .empty;
    defer atom_inputs.deinit(allocator);
    defer freeExtractionAtomInputs(allocator, atom_inputs.items);
    var relation_inputs: std.ArrayListUnmanaged(store_mod.ExtractedRelationInput) = .empty;
    defer relation_inputs.deinit(allocator);
    if (job_options.extract_memory) {
        var structured_done = false;
        if (job_options.use_llm_extraction) {
            const prompt = try extraction.memoryExtractionPrompt(allocator, source.title, source.source_type, source.content);
            defer allocator.free(prompt);
            const completion: ?providers.CompletionResult = blk: {
                const result = providers.completeWithSystem(allocator, .{
                    .base_url = options.provider.completion.base_url,
                    .api_key = options.provider.completion.api_key,
                    .model = options.provider.completion.model,
                    .timeout_secs = options.provider.completion.timeout_secs,
                    .max_response_bytes = options.provider.completion.max_response_bytes,
                    .allow_insecure_http = options.provider.completion.allow_insecure_http,
                    .runtime = options.provider.runtime(),
                }, "Return only valid JSON for the requested NullPantry extraction schema. Do not include markdown fences unless the model cannot avoid them. Extract only source-grounded memory atoms and relations.", prompt) catch |err| {
                    if (job_options.strict_llm_extraction) return err;
                    counts.extraction_fallback = true;
                    break :blk null;
                };
                break :blk result;
            };
            defer if (completion) |result| {
                var owned_result = result;
                providers.freeCompletionResult(allocator, &owned_result);
            };
            if (completion) |result| {
                var maybe_grounded: ?extraction.GroundedStructuredExtraction = null;
                if (extraction.parseGroundedStructuredResponse(allocator, source.content, result.content, job_options.strict_llm_extraction)) |grounded_result| {
                    maybe_grounded = grounded_result;
                } else |err| switch (err) {
                    error.InvalidStructuredMemory => {
                        if (job_options.strict_llm_extraction) return err;
                        counts.extraction_fallback = true;
                    },
                    error.UngroundedEvidence => return err,
                    else => return err,
                }
                if (maybe_grounded) |*grounded| {
                    defer grounded.deinit(allocator);
                    if (grounded.skipped_ungrounded > 0) counts.extraction_fallback = true;
                    counts.extraction_provider = result.provider;
                    for (grounded.memories) |parsed| {
                        const evidence_ranges_json = try extraction.groundedEvidenceRangeForText(allocator, source.id, source.content, parsed.evidence orelse parsed.text);
                        errdefer allocator.free(evidence_ranges_json);
                        try atom_inputs.append(allocator, .{
                            .subject_entity_id = null,
                            .predicate = parsed.predicate,
                            .object = parsed.object,
                            .text = parsed.text,
                            .scope = source.scope,
                            .confidence = parsed.confidence,
                            .source_ids_json = source_ids_json,
                            .evidence_ranges_json = evidence_ranges_json,
                            .created_by = "agent",
                            .permissions_json = source.permissions_json,
                            .tags_json = parsed.tags_json,
                            .actor_id = options.actor_id,
                            .storage_route = job_options.storage_route,
                        });
                    }
                    for (grounded.relations) |parsed| {
                        try relation_inputs.append(allocator, .{
                            .from_entity_name = parsed.from_name,
                            .relation_type = parsed.relation_type,
                            .to_entity_name = parsed.to_name,
                            .source_ids_json = source_ids_json,
                            .scope = source.scope,
                            .permissions_json = source.permissions_json,
                            .confidence = parsed.confidence,
                            .status = "proposed",
                            .actor_id = options.actor_id,
                        });
                    }
                    structured_done = grounded.acceptedCount() > 0;
                }
            }
        }
        if (!structured_done) {
            counts.extraction_provider = "heuristic";
            var lines = extraction.sourceLineIterator(source.content);
            while (lines.next()) |line| {
                if (extraction.parseMemoryLine(line.text)) |parsed| {
                    const evidence_ranges_json = try extraction.evidenceRangeJson(allocator, source.id, line.start, line.end, line.line_no);
                    errdefer allocator.free(evidence_ranges_json);
                    try atom_inputs.append(allocator, .{
                        .subject_entity_id = null,
                        .predicate = parsed.predicate,
                        .object = parsed.object,
                        .text = parsed.text,
                        .scope = source.scope,
                        .confidence = parsed.confidence,
                        .source_ids_json = source_ids_json,
                        .evidence_ranges_json = evidence_ranges_json,
                        .created_by = "agent",
                        .permissions_json = source.permissions_json,
                        .tags_json = parsed.tags_json,
                        .actor_id = options.actor_id,
                        .storage_route = job_options.storage_route,
                    });
                }
                if (extraction.parseRelationLine(line.text)) |relation| {
                    try relation_inputs.append(allocator, .{
                        .from_entity_name = relation.from_name,
                        .relation_type = relation.relation_type,
                        .to_entity_name = relation.to_name,
                        .source_ids_json = source_ids_json,
                        .scope = source.scope,
                        .permissions_json = source.permissions_json,
                        .confidence = relation.confidence,
                        .status = "proposed",
                        .actor_id = options.actor_id,
                    });
                }
            }
        }
    }

    const applied = try store.applyExtractedKnowledge(allocator, .{
        .source = source,
        .source_ids_json = source_ids_json,
        .entity_names_json = entity_names_json,
        .artifact = artifact_input,
        .atoms = atom_inputs.items,
        .relations = relation_inputs.items,
        .actor_id = options.actor_id,
    });
    counts.entity_count = applied.entities.len;
    counts.artifact_count = if (applied.artifact != null) 1 else 0;
    counts.memory_atom_count = applied.atoms.len;
    counts.relation_count = applied.relations.len;

    counts.addVectorChunks(try upsertVector(allocator, store, options, "source", source.id, source.content, source.scope, source.permissions_json));
    if (applied.artifact) |artifact| {
        counts.addVectorChunks(try upsertVector(allocator, store, options, "artifact", artifact.id, artifact.body, artifact.scope, artifact.permissions_json));
    }
    for (applied.entities) |entity| {
        const text = try vector_text.entity(allocator, entity);
        defer allocator.free(text);
        counts.addVectorChunks(try upsertVector(allocator, store, options, "entity", entity.id, text, entity.scope, entity.permissions_json));
    }
    for (applied.relations) |relation| {
        const text = try vector_text.relation(allocator, relation);
        defer allocator.free(text);
        counts.addVectorChunks(try upsertVector(allocator, store, options, "relation", relation.id, text, relation.scope, relation.permissions_json));
    }
    for (applied.atoms) |atom| {
        counts.addVectorChunks(try upsertVector(allocator, store, options, "memory_atom", atom.id, atom.text, atom.scope, atom.permissions_json));
    }
    return counts;
}

fn resolveEntities(allocator: std.mem.Allocator, store: *store_mod.Store, names_json: []const u8, scope: []const u8, permissions_json: []const u8) ![]domain.Entity {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, names_json, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return allocator.alloc(domain.Entity, 0);
    var out: std.ArrayListUnmanaged(domain.Entity) = .empty;
    for (parsed.value.array.items) |item| {
        const name = switch (item) {
            .string => |s| s,
            else => continue,
        };
        try out.append(allocator, try store.resolveEntity(allocator, .{ .entity_type = "project", .name = name, .scope = scope, .permissions_json = permissions_json, .actor_id = "system:worker" }));
    }
    return out.toOwnedSlice(allocator);
}

fn upsertVector(allocator: std.mem.Allocator, store: *store_mod.Store, options: RunOptions, object_type: []const u8, object_id: []const u8, text: []const u8, scope: []const u8, permissions_json: []const u8) !usize {
    if (text.len == 0) return 0;
    var count: usize = 0;
    const chunks = try vector.chunkTextWithConfig(allocator, text, options.chunker);
    defer allocator.free(chunks);
    if (chunks.len == 0) return 0;
    _ = try store.deleteVectorChunksForObject(allocator, object_type, object_id, options.actor_id);
    for (chunks) |chunk| {
        const chunk_text = chunk.text;
        if (chunk_text.len > 0) {
            const embedding_dimensions = vector.boundedEmbeddingDimensions(null, options.provider.embedding.dimensions);
            const heading_path_json = try vector.chunkHeadingPathJson(allocator, text, chunk);
            defer allocator.free(heading_path_json);
            const content_hash = try vector.contentHashHex(allocator, chunk_text);
            defer allocator.free(content_hash);
            const payload = try store_mod.vectorEmbedPayloadJsonEx(allocator, .{
                .chunk_ordinal = vector.chunkOrdinalFromIndex(count),
                .text = chunk_text,
                .scope = scope,
                .permissions_json = permissions_json,
                .heading_path_json = heading_path_json,
                .start_byte = @intCast(chunk.start),
                .end_byte = @intCast(chunk.end),
                .content_hash = content_hash,
                .chunk_strategy = chunk.strategy.name(),
                .estimated_tokens = @intCast(chunk.estimated_tokens),
                .transcript_timestamp = chunk.transcript_timestamp,
                .transcript_speaker = chunk.transcript_speaker,
                .model = options.provider.embedding.model,
                .dimensions = embedding_dimensions,
            });
            defer allocator.free(payload);
            const outbox_id = try store.enqueueVectorOutbox(.{ .action = "embed", .object_type = object_type, .object_id = object_id, .payload_json = payload });
            if (!try store.claimVectorOutboxAs(outbox_id, leaseWorkerId(options))) return count;
            try heartbeatVectorOutbox(store, outbox_id, options);
            var embedding_result = embedding_cache.embedTextCachedForPurpose(allocator, store, .{
                .provider = options.provider.embedding.provider,
                .base_url = options.provider.embedding.base_url,
                .api_key = options.provider.embedding.api_key,
                .model = options.provider.embedding.model,
                .dimensions = embedding_dimensions,
                .send_dimensions = options.provider.embedding.send_dimensions,
                .timeout_secs = options.provider.embedding.timeout_secs,
                .max_response_bytes = options.provider.embedding.max_response_bytes,
                .allow_insecure_http = options.provider.embedding.allow_insecure_http,
                .fallbacks = options.provider.embedding.fallbacks,
                .routes = options.provider.embedding.routes,
                .runtime = options.provider.runtime(),
            }, chunk_text, embedding_dimensions, options.use_embedding_cache, options.embedding_cache_max_entries, .document) catch {
                if (!try store.finishVectorOutboxAs(outbox_id, "pending", leaseWorkerId(options))) return error.VectorOutboxLeaseLost;
                return count;
            };
            defer embedding_result.deinit(allocator);
            try heartbeatVectorOutbox(store, outbox_id, options);
            const embedding_json = try vector.embeddingToJson(allocator, embedding_result.embedding);
            defer allocator.free(embedding_json);
            const stored_chunk = try store.upsertVectorChunk(allocator, .{
                .object_type = object_type,
                .object_id = object_id,
                .chunk_ordinal = vector.chunkOrdinalFromIndex(count),
                .text = chunk_text,
                .scope = scope,
                .permissions_json = permissions_json,
                .heading_path_json = heading_path_json,
                .start_byte = @intCast(chunk.start),
                .end_byte = @intCast(chunk.end),
                .content_hash = content_hash,
                .chunk_strategy = chunk.strategy.name(),
                .estimated_tokens = @intCast(chunk.estimated_tokens),
                .transcript_timestamp = chunk.transcript_timestamp,
                .transcript_speaker = chunk.transcript_speaker,
                .embedding_json = embedding_json,
                .model = embedding_result.model,
                .dimensions = vector.embeddingDimensionsFromLength(embedding_result.embedding.len),
                .actor_id = options.actor_id,
            });
            allocator.free(stored_chunk.id);
            if (!try store.finishVectorOutboxAs(outbox_id, "embedded", leaseWorkerId(options))) return error.VectorOutboxLeaseLost;
            count += 1;
        }
    }
    return count;
}

fn runEmbeddingOutbox(allocator: std.mem.Allocator, store: *store_mod.Store, options: RunOptions) !store_mod.VectorOutboxRunResult {
    const entries = try store.listVectorOutbox(allocator, .{ .action = "embed", .status = "pending", .limit = options.outbox_limit });
    defer store_mod.freeVectorOutboxEntries(allocator, entries);
    var result = store_mod.VectorOutboxRunResult{};
    for (entries) |entry| {
        if (!try store.claimVectorOutboxAs(entry.id, leaseWorkerId(options))) continue;
        try heartbeatVectorOutbox(store, entry.id, options);
        processEmbeddingOutboxEntry(allocator, store, options, entry) catch {
            _ = try store.finishVectorOutboxAs(entry.id, "failed_embedding", leaseWorkerId(options));
            result.failed += 1;
            continue;
        };
        if (try store.finishVectorOutboxAs(entry.id, "embedded", leaseWorkerId(options))) {
            result.processed += 1;
        } else {
            result.failed += 1;
        }
    }
    return result;
}

fn processEmbeddingOutboxEntry(allocator: std.mem.Allocator, store: *store_mod.Store, options: RunOptions, entry: store_mod.VectorOutboxEntry) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, entry.payload_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidVectorOutboxPayload;
    const obj = parsed.value.object;
    const text = json.stringField(obj, "text") orelse return error.InvalidVectorOutboxPayload;
    const scope = json.stringField(obj, "scope") orelse return error.InvalidVectorOutboxPayload;
    const permissions_json = try requiredRawJsonArrayField(allocator, obj, "permissions");
    defer allocator.free(permissions_json);
    const heading_path_json = if (obj.get("heading_path") != null)
        try rawJsonField(allocator, obj, "heading_path", "[]")
    else
        try rawJsonField(allocator, obj, "heading_path_json", "[]");
    defer allocator.free(heading_path_json);
    const chunk_ordinal = json.intField(obj, "chunk_ordinal") orelse 0;
    const start_byte = json.intField(obj, "start_byte") orelse 0;
    const end_byte = json.intField(obj, "end_byte") orelse 0;
    const content_hash = json.stringField(obj, "content_hash") orelse "";
    const chunk_strategy = json.stringField(obj, "chunk_strategy") orelse "plain";
    const estimated_tokens = json.intField(obj, "estimated_tokens") orelse 0;
    const transcript_timestamp = json.nullableStringField(obj, "transcript_timestamp");
    const transcript_speaker = json.nullableStringField(obj, "transcript_speaker");
    const dimensions = vector.boundedEmbeddingDimensions(json.intField(obj, "dimensions"), options.provider.embedding.dimensions);
    try heartbeatVectorOutbox(store, entry.id, options);
    var embedding_result = try embedding_cache.embedTextCachedForPurpose(allocator, store, .{
        .provider = options.provider.embedding.provider,
        .base_url = options.provider.embedding.base_url,
        .api_key = options.provider.embedding.api_key,
        .model = options.provider.embedding.model,
        .dimensions = dimensions,
        .send_dimensions = options.provider.embedding.send_dimensions,
        .timeout_secs = options.provider.embedding.timeout_secs,
        .max_response_bytes = options.provider.embedding.max_response_bytes,
        .allow_insecure_http = options.provider.embedding.allow_insecure_http,
        .fallbacks = options.provider.embedding.fallbacks,
        .routes = options.provider.embedding.routes,
        .runtime = options.provider.runtime(),
    }, text, dimensions, options.use_embedding_cache, options.embedding_cache_max_entries, .document);
    defer embedding_result.deinit(allocator);
    try heartbeatVectorOutbox(store, entry.id, options);
    const embedding_json = try vector.embeddingToJson(allocator, embedding_result.embedding);
    defer allocator.free(embedding_json);
    const stored_chunk = try store.upsertVectorChunk(allocator, .{
        .object_type = entry.object_type,
        .object_id = entry.object_id,
        .chunk_ordinal = chunk_ordinal,
        .text = text,
        .scope = scope,
        .permissions_json = permissions_json,
        .heading_path_json = heading_path_json,
        .start_byte = start_byte,
        .end_byte = end_byte,
        .content_hash = content_hash,
        .chunk_strategy = chunk_strategy,
        .estimated_tokens = estimated_tokens,
        .transcript_timestamp = transcript_timestamp,
        .transcript_speaker = transcript_speaker,
        .embedding_json = embedding_json,
        .model = embedding_result.model,
        .dimensions = vector.embeddingDimensionsFromLength(embedding_result.embedding.len),
        .actor_id = options.actor_id,
    });
    allocator.free(stored_chunk.id);
}

fn heartbeatVectorOutbox(store: *store_mod.Store, id: i64, options: RunOptions) !void {
    if (!try store.heartbeatVectorOutboxAs(id, leaseWorkerId(options))) return error.VectorOutboxLeaseLost;
}

fn rawJsonField(allocator: std.mem.Allocator, obj: std.json.ObjectMap, name: []const u8, fallback: []const u8) ![]const u8 {
    const value = obj.get(name) orelse return json.rawJsonFieldFallback(allocator, name, fallback);
    return try json.rawJsonFieldValue(allocator, name, value, fallback);
}

fn requiredRawJsonArrayField(allocator: std.mem.Allocator, obj: std.json.ObjectMap, name: []const u8) ![]const u8 {
    const value = obj.get(name) orelse return error.InvalidVectorOutboxPayload;
    if (value == .null) return error.InvalidVectorOutboxPayload;
    if (value == .string and json.rawJsonFieldNameAcceptsEncodedString(name)) {
        const trimmed = std.mem.trim(u8, value.string, " \t\r\n");
        if (!json.rawJsonRootIs(allocator, trimmed, .array)) return error.InvalidVectorOutboxPayload;
        return try allocator.dupe(u8, trimmed);
    }
    const raw = try json.jsonFromValue(allocator, value);
    errdefer allocator.free(raw);
    if (!json.rawJsonRootIs(allocator, raw, .array)) return error.InvalidVectorOutboxPayload;
    return raw;
}

test "worker vector job result json escapes runtime strings" {
    const allocator = std.testing.allocator;
    const body = try vectorMaintenanceJobResultJson(
        allocator,
        "vector\"rebuild",
        .{
            .canonical_chunks = 1,
            .enqueued_upserts = 2,
            .requeued_failed = 3,
            .external_enabled = true,
        },
        .{
            .active_sink = "sink\"quoted",
            .local_engine = "local\\engine",
            .search_engine = "search\nengine",
            .external_sinks_json = "[{\"name\":\"ann\"}]",
        },
    );
    defer allocator.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const result = root.get("vector\"rebuild").?.object;
    try std.testing.expectEqual(@as(i64, 1), result.get("canonical_chunks").?.integer);
    try std.testing.expectEqual(@as(i64, 2), result.get("enqueued_upserts").?.integer);
    try std.testing.expectEqual(@as(i64, 3), result.get("requeued_failed").?.integer);
    try std.testing.expect(result.get("external_enabled").?.bool);
    try std.testing.expectEqualStrings("sink\"quoted", result.get("active_sink").?.string);
    try std.testing.expectEqualStrings("local\\engine", result.get("local_engine").?.string);
    try std.testing.expectEqualStrings("search\nengine", result.get("search_engine").?.string);
    try std.testing.expectEqual(@as(usize, 1), result.get("external_sinks").?.array.items.len);
}

test "worker vector job result json rejects invalid external sinks" {
    try std.testing.expectError(error.InvalidRawJson, vectorMaintenanceJobResultJson(
        std.testing.allocator,
        "vector",
        .{},
        .{
            .active_sink = "none",
            .local_engine = "sqlite",
            .search_engine = "local",
            .external_sinks_json = "{\"name\":\"ann\"}",
        },
    ));
}

test "worker job usize options preserve fallback and cap supplied limits" {
    const allocator = std.testing.allocator;

    try std.testing.expectEqual(@as(usize, 500), jobUsizeOption(allocator, "{}", "limit", 500));
    try std.testing.expectEqual(std.math.maxInt(usize), jobUsizeOption(allocator, "{}", "limit", std.math.maxInt(usize)));
    try std.testing.expectEqual(@as(usize, 500), jobUsizeOption(allocator, "{\"limit\":-1}", "limit", 500));
    try std.testing.expectEqual(max_job_usize_option, jobUsizeOption(allocator, "{\"limit\":9223372036854775807}", "limit", 500));
}

test "worker run limits preserve defaults and cap attacker supplied sizes" {
    try std.testing.expectEqual(default_run_job_limit, requestJobLimit(null));
    try std.testing.expectEqual(default_run_job_limit, requestJobLimit(-1));
    try std.testing.expectEqual(@as(usize, 42), requestJobLimit(42));
    try std.testing.expectEqual(max_run_request_job_limit, requestJobLimit(std.math.maxInt(i64)));

    try std.testing.expectEqual(default_run_outbox_limit, requestOutboxLimit(null));
    try std.testing.expectEqual(default_run_outbox_limit, requestOutboxLimit(0));
    try std.testing.expectEqual(@as(usize, 250), requestOutboxLimit(250));
    try std.testing.expectEqual(max_run_request_outbox_limit, requestOutboxLimit(std.math.maxInt(i64)));

    var options = RunOptions{
        .job_limit = std.math.maxInt(usize),
        .outbox_limit = std.math.maxInt(usize),
    };
    normalizeRunOptions(&options);
    try std.testing.expectEqual(max_job_usize_option, options.job_limit);
    try std.testing.expectEqual(max_job_usize_option, options.outbox_limit);
}

test "worker run options validate principal inputs" {
    try (RunOptions{}).validateUsable();
    try (RunOptions{
        .actor_id = "agent:a",
        .scopes_json = "[\"public\",\"team:\\u0041\"]",
        .capabilities_json = "[\"read\",\"write\"]",
        .worker_id = "worker:a",
    }).validateUsable();

    try std.testing.expectError(error.InvalidWorkerRunOptions, (RunOptions{ .actor_id = " " }).validateUsable());
    try std.testing.expectError(error.InvalidWorkerRunOptions, (RunOptions{ .scopes_json = "public" }).validateUsable());
    try std.testing.expectError(error.InvalidWorkerRunOptions, (RunOptions{ .capabilities_json = "[1]" }).validateUsable());
    try std.testing.expectError(error.InvalidWorkerRunOptions, (RunOptions{ .worker_id = " " }).validateUsable());
}

test "worker entrypoints reject invalid run options before claiming jobs" {
    var store = try store_mod.Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const job = try store.createJob(alloc, .{ .job_type = "hygiene", .scope = "public", .input_json = "{}" });

    try std.testing.expectError(error.InvalidWorkerRunOptions, runOnce(alloc, &store, .{ .scopes_json = "public" }));
    try std.testing.expectError(error.InvalidWorkerRunOptions, runVectorOutboxOnce(alloc, &store, .{ .capabilities_json = "[1]" }));
    try std.testing.expectError(error.InvalidWorkerRunOptions, runJobById(alloc, &store, job.id, .{ .actor_id = " " }));
    try std.testing.expectError(error.InvalidWorkerRunOptions, runClaimedJob(alloc, &store, job, .{ .worker_id = " " }));

    const loaded = (try store.getJob(alloc, job.id)).?;
    try std.testing.expectEqualStrings("queued", loaded.status);
    try std.testing.expect(loaded.worker_id == null);
}

test "worker summary job options clamp attacker supplied sizes" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        "{\"max_chars\":9223372036854775807,\"max_items_per_section\":10000,\"summary_window_tokens\":9223372036854775807}",
        .{},
    );
    defer parsed.deinit();
    const obj = parsed.value.object;

    const max_chars = jobPositiveBoundedOption(json.intField(obj, "max_chars"), default_job_summary_max_chars, max_job_summary_chars);
    const options = jobSummaryOptions(obj, max_chars);

    try std.testing.expectEqual(max_job_summary_chars, options.max_chars);
    try std.testing.expectEqual(max_job_summary_items_per_section, options.max_items_per_section);
    try std.testing.expectEqual(max_job_summary_window_tokens, options.window_size_tokens);

    var negative = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        "{\"max_chars\":-5,\"max_items_per_section\":-2,\"summary_window_tokens\":-1}",
        .{},
    );
    defer negative.deinit();
    const negative_obj = negative.value.object;
    const negative_max_chars = jobPositiveBoundedOption(json.intField(negative_obj, "max_chars"), default_job_summary_max_chars, max_job_summary_chars);
    const negative_options = jobSummaryOptions(negative_obj, negative_max_chars);

    try std.testing.expectEqual(@as(usize, 1), negative_options.max_chars);
    try std.testing.expectEqual(@as(usize, 1), negative_options.max_items_per_section);
    try std.testing.expectEqual(@as(usize, 0), negative_options.window_size_tokens);
}

test "worker summary result json rejects invalid raw objects" {
    const allocator = std.testing.allocator;

    const body = try jobSummaryResultJson(allocator, .{
        .summary_text = "Summary",
        .summary_provider = "extractive_structured",
        .profile = .generic,
        .strategy = "extractive_structured",
        .message_count = 2,
        .segment_count = 1,
        .messages_summarized = 2,
        .messages_kept = 0,
        .truncated = false,
        .sections_json = "{\"decisions\":[]}",
        .quality_json = "{\"citation_coverage\":100}",
    });
    defer allocator.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("Summary", root.get("summary").?.string);
    try std.testing.expect(root.get("sections").? == .object);
    try std.testing.expect(root.get("quality").? == .object);

    try std.testing.expectError(error.InvalidRawJson, jobSummaryResultJson(allocator, .{
        .summary_text = "Summary",
        .summary_provider = "extractive_structured",
        .profile = .generic,
        .strategy = "extractive_structured",
        .message_count = 1,
        .segment_count = 1,
        .messages_summarized = 1,
        .messages_kept = 0,
        .truncated = false,
        .sections_json = "[\"not-object\"]",
        .quality_json = "{}",
    }));
    try std.testing.expectError(error.InvalidRawJson, jobSummaryResultJson(allocator, .{
        .summary_text = "Summary",
        .summary_provider = "extractive_structured",
        .profile = .generic,
        .strategy = "extractive_structured",
        .message_count = 1,
        .segment_count = 1,
        .messages_summarized = 1,
        .messages_kept = 0,
        .truncated = false,
        .sections_json = "{}",
        .quality_json = "[\"not-object\"]",
    }));
}

test "worker summary metadata json rejects invalid raw objects" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(error.InvalidRawJson, jobSummaryMetadataJson(
        allocator,
        "extractive_structured",
        1,
        "[\"not-object\"]",
        "{}",
        .generic,
        "extractive_structured",
        1,
    ));
    try std.testing.expectError(error.InvalidRawJson, jobSummaryMetadataJson(
        allocator,
        "extractive_structured",
        1,
        "{}",
        "[\"not-object\"]",
        .generic,
        "extractive_structured",
        1,
    ));
}

test "worker lease ids are unique per worker run" {
    const first = try makeWorkerLeaseId(std.testing.allocator);
    defer std.testing.allocator.free(first);
    const second = try makeWorkerLeaseId(std.testing.allocator);
    defer std.testing.allocator.free(second);

    try std.testing.expect(std.mem.startsWith(u8, first, "worker_lease_"));
    try std.testing.expect(std.mem.startsWith(u8, second, "worker_lease_"));
    try std.testing.expect(!std.mem.eql(u8, first, second));
}

test "worker lease id is independent from access actor" {
    var options = RunOptions{ .actor_id = "system:worker" };
    const generated = try ensureWorkerLeaseId(std.testing.allocator, &options);
    defer if (generated) |value| std.testing.allocator.free(value);

    try std.testing.expectEqualStrings("system:worker", options.actor_id);
    try std.testing.expect(generated != null);
    try std.testing.expectEqualStrings(generated.?, leaseWorkerId(options));
    try std.testing.expect(!std.mem.eql(u8, options.actor_id, leaseWorkerId(options)));
}

test "scoped worker skips global vector outbox and processes visible jobs" {
    var store = try store_mod.Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const atom = try store.createMemoryAtom(alloc, .{ .text = "worker memory", .scope = "public" });
    const embedding = try vector.deterministicEmbedding(alloc, atom.text, 64);
    const embedding_json = try vector.embeddingToJson(alloc, embedding);
    _ = try store.upsertVectorChunk(alloc, .{ .object_id = atom.id, .text = atom.text, .scope = atom.scope, .embedding_json = embedding_json, .dimensions = 64 });
    _ = try store.createJob(alloc, .{ .job_type = "hygiene", .scope = "public", .input_json = "{}" });
    const result = try runOnce(alloc, &store, .{ .scopes_json = "[\"public\"]" });
    try std.testing.expectEqual(@as(usize, 0), result.vector_outbox_processed);
    try std.testing.expectEqual(@as(usize, 1), result.jobs_succeeded);
}

test "worker durable memory reindex job enqueues and drain job processes vector outbox" {
    var store = try store_mod.Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const atom = try store.createMemoryAtom(alloc, .{
        .id = "mem_worker_reindex_job",
        .text = "worker reindex durable vector maintenance",
        .scope = "public",
        .permissions_json = "[\"public\"]",
        .created_by = "human",
    });
    const embedding = try vector.deterministicEmbedding(alloc, atom.text, 64);
    const embedding_json = try vector.embeddingToJson(alloc, embedding);
    _ = try store.upsertVectorChunk(alloc, .{
        .object_type = "memory_atom",
        .object_id = atom.id,
        .text = atom.text,
        .scope = atom.scope,
        .permissions_json = atom.permissions_json,
        .embedding_json = embedding_json,
        .dimensions = 64,
    });
    _ = try store.runVectorOutboxAs(100, "worker:setup");

    const reindex = try store.createJob(alloc, .{
        .job_type = "memory_reindex",
        .scope = "admin",
        .input_json = "{\"limit\":10}",
    });
    const reindex_finished = try runJobById(alloc, &store, reindex.id, .{});
    try std.testing.expectEqualStrings("succeeded", reindex_finished.status);
    try std.testing.expect(std.mem.indexOf(u8, reindex_finished.result_json, "\"memory_reindex\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, reindex_finished.result_json, "\"reindexed\":1") != null);
    try std.testing.expect((try store.countVectorOutbox("pending")) >= 1);

    const drain = try store.createJob(alloc, .{
        .job_type = "memory_drain_outbox",
        .scope = "admin",
        .input_json = "{\"limit\":10}",
    });
    const drain_finished = try runJobById(alloc, &store, drain.id, .{});
    try std.testing.expectEqualStrings("succeeded", drain_finished.status);
    try std.testing.expect(std.mem.indexOf(u8, drain_finished.result_json, "\"memory_outbox\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, drain_finished.result_json, "\"drained\":") != null);
    try std.testing.expectEqual(@as(usize, 0), try store.countVectorOutbox("pending"));
}

test "worker durable vector rebuild and reconcile aliases enqueue canonical chunks" {
    var store = try store_mod.Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const atom = try store.createMemoryAtom(alloc, .{
        .id = "mem_worker_reconcile_job",
        .text = "worker reconcile durable vector maintenance",
        .scope = "public",
        .permissions_json = "[\"public\"]",
        .created_by = "human",
    });
    const embedding = try vector.deterministicEmbedding(alloc, atom.text, 64);
    const embedding_json = try vector.embeddingToJson(alloc, embedding);
    _ = try store.upsertVectorChunk(alloc, .{
        .object_type = "memory_atom",
        .object_id = atom.id,
        .text = atom.text,
        .scope = atom.scope,
        .permissions_json = atom.permissions_json,
        .embedding_json = embedding_json,
        .dimensions = 64,
    });
    _ = try store.runVectorOutboxAs(100, "worker:setup");

    const rebuild = try store.createJob(alloc, .{
        .job_type = "rebuild_vector_index",
        .scope = "admin",
        .input_json = "{\"limit\":10,\"retry_failed\":true}",
    });
    const rebuild_finished = try runJobById(alloc, &store, rebuild.id, .{});
    try std.testing.expectEqualStrings("succeeded", rebuild_finished.status);
    try std.testing.expect(std.mem.indexOf(u8, rebuild_finished.result_json, "\"vector_rebuild\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rebuild_finished.result_json, "\"enqueued_upserts\":1") != null);

    const reconcile = try store.createJob(alloc, .{
        .job_type = "reconcile_vector_index",
        .scope = "admin",
        .input_json = "{\"limit\":10}",
    });
    const reconcile_finished = try runJobById(alloc, &store, reconcile.id, .{});
    try std.testing.expectEqualStrings("succeeded", reconcile_finished.status);
    try std.testing.expect(std.mem.indexOf(u8, reconcile_finished.result_json, "\"vector_reconcile\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, reconcile_finished.result_json, "\"enqueued_upserts\":1") != null);
}

test "worker rejects non-admin scoped vector maintenance jobs" {
    var store = try store_mod.Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const job = try store.createJob(alloc, .{
        .job_type = "memory_reindex",
        .scope = "public",
        .permissions_json = "[\"public\"]",
        .input_json = "{\"limit\":10}",
    });
    const finished = try runJobById(alloc, &store, job.id, .{});
    try std.testing.expectEqualStrings("failed", finished.status);
    try std.testing.expectEqualStrings("Forbidden", finished.error_text.?);
}

test "worker rejects object-bound ingest jobs broader than target acl" {
    var store = try store_mod.Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = try store.createSource(alloc, .{
        .title = "Secret source",
        .content = "private source content",
        .scope = "project:secret",
        .permissions_json = "[\"project:secret\"]",
    });
    const job = try store.createJob(alloc, .{
        .job_type = "ingest",
        .scope = "public",
        .object_type = "source",
        .object_id = source.id,
        .input_json = "{}",
    });
    const finished = try runJobById(alloc, &store, job.id, .{});
    try std.testing.expectEqualStrings("failed", finished.status);
    try std.testing.expectEqualStrings("Forbidden", finished.error_text.?);
}

test "worker releases listed jobs and summaries on long-lived allocator" {
    var store = try store_mod.Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const setup = arena.allocator();

    _ = try store.createJob(setup, .{
        .job_type = "hygiene",
        .scope = "public",
        .permissions_json = "[\"public\"]",
        .input_json = "{}",
    });
    _ = try store.createJob(setup, .{
        .job_type = "hygiene",
        .scope = "project:secret",
        .permissions_json = "[\"team:secret\"]",
        .input_json = "{}",
    });

    const result = try runOnce(std.testing.allocator, &store, .{
        .scopes_json = "[\"public\"]",
        .job_limit = 10,
        .actor_id = "worker:leak-test",
    });
    try std.testing.expectEqual(@as(usize, 1), result.jobs_checked);
    try std.testing.expectEqual(@as(usize, 1), result.jobs_succeeded);
}

test "worker releases conflict scan results on long-lived allocator" {
    var store = try store_mod.Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const setup = arena.allocator();

    _ = try store.createMemoryAtom(setup, .{
        .predicate = "decision.database",
        .object = "sqlite",
        .text = "Decision: NullPantry uses SQLite for local tests",
        .scope = "project:nullpantry",
        .permissions_json = "[\"project:nullpantry\"]",
        .created_by = "human",
    });
    _ = try store.createMemoryAtom(setup, .{
        .predicate = "decision.database",
        .object = "postgres",
        .text = "Decision: NullPantry uses Postgres for production",
        .scope = "project:nullpantry",
        .permissions_json = "[\"project:nullpantry\"]",
        .created_by = "human",
    });
    _ = try store.createJob(setup, .{
        .job_type = "scan_conflicts",
        .scope = "project:nullpantry",
        .permissions_json = "[\"project:nullpantry\"]",
        .input_json = "{}",
    });

    const result = try runOnce(std.testing.allocator, &store, .{
        .scopes_json = "[\"project:nullpantry\"]",
        .job_limit = 10,
        .actor_id = "worker:conflict-release",
    });
    try std.testing.expectEqual(@as(usize, 1), result.jobs_succeeded);
}

test "worker releases ingest source on long-lived allocator" {
    var store = try store_mod.Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const setup = arena.allocator();

    const source = try store.createSource(setup, .{
        .source_type = "transcript",
        .title = "Worker ingest release",
        .content = "Decision: worker ingest keeps owned source data bounded",
        .scope = "public",
        .permissions_json = "[\"public\"]",
    });
    _ = try store.createJob(setup, .{
        .job_type = "ingest",
        .scope = "public",
        .permissions_json = "[\"public\"]",
        .object_type = "source",
        .object_id = source.id,
        .input_json = "{\"create_artifact\":false,\"extract_memory\":false}",
    });

    const result = try runOnce(std.testing.allocator, &store, .{
        .scopes_json = "[\"public\"]",
        .job_limit = 10,
        .outbox_limit = 10,
        .actor_id = "worker:ingest-release",
    });
    try std.testing.expectEqual(@as(usize, 1), result.jobs_succeeded);
}

test "worker releases vector outbox entries and embedding temporaries on long-lived allocator" {
    if (!localVectorOutboxTestsEnabled()) return error.SkipZigTest;

    var store = try store_mod.Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const setup = arena.allocator();

    _ = try store.createMemoryAtom(setup, .{
        .id = "mem_worker_vector_release",
        .text = "worker vector release text",
        .scope = "public",
        .permissions_json = "[\"public\"]",
        .created_by = "human",
    });
    const payload = try store_mod.vectorEmbedPayloadJson(setup, 0, "worker vector release text", "public", "[\"public\"]", "[]", null, 64);
    _ = try store.enqueueVectorOutbox(.{
        .action = "embed",
        .object_type = "memory_atom",
        .object_id = "mem_worker_vector_release",
        .payload_json = payload,
    });

    const result = try runOnce(std.testing.allocator, &store, .{
        .scopes_json = "[\"admin\",\"public\"]",
        .outbox_limit = 10,
        .actor_id = "worker:vector-release",
    });
    try std.testing.expect(result.vector_outbox_processed >= 1);
}

test "worker vector outbox rejects invalid acl payload fields" {
    var store = try store_mod.Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    _ = try store.createMemoryAtom(alloc, .{
        .id = "mem_worker_missing_scope",
        .text = "worker malformed missing scope",
        .scope = "public",
        .permissions_json = "[\"public\"]",
        .created_by = "human",
    });
    _ = try store.createMemoryAtom(alloc, .{
        .id = "mem_worker_missing_permissions",
        .text = "worker malformed missing permissions",
        .scope = "public",
        .permissions_json = "[\"public\"]",
        .created_by = "human",
    });
    _ = try store.createMemoryAtom(alloc, .{
        .id = "mem_worker_null_permissions",
        .text = "worker malformed null permissions",
        .scope = "public",
        .permissions_json = "[\"public\"]",
        .created_by = "human",
    });

    _ = try store.enqueueVectorOutbox(.{
        .action = "embed",
        .object_type = "memory_atom",
        .object_id = "mem_worker_missing_scope",
        .payload_json = "{\"text\":\"worker malformed missing scope\",\"permissions\":[\"public\"],\"dimensions\":64}",
    });
    _ = try store.enqueueVectorOutbox(.{
        .action = "embed",
        .object_type = "memory_atom",
        .object_id = "mem_worker_missing_permissions",
        .payload_json = "{\"text\":\"worker malformed missing permissions\",\"scope\":\"public\",\"dimensions\":64}",
    });
    _ = try store.enqueueVectorOutbox(.{
        .action = "embed",
        .object_type = "memory_atom",
        .object_id = "mem_worker_null_permissions",
        .payload_json = "{\"text\":\"worker malformed null permissions\",\"scope\":\"public\",\"permissions\":null,\"dimensions\":64}",
    });

    const result = try runVectorOutboxOnce(alloc, &store, .{
        .scopes_json = "[\"admin\"]",
        .outbox_limit = 10,
        .actor_id = "worker:vector-acl-payload",
    });
    try std.testing.expectEqual(@as(usize, 0), result.processed);
    try std.testing.expectEqual(@as(usize, 3), result.failed);
    try std.testing.expectEqual(@as(usize, 0), try store.countVectorOutbox("pending"));
    try std.testing.expectEqual(@as(usize, 3), try store.countVectorOutbox("failed_embedding"));
}

test "worker hygiene job applies input and stays scoped to job" {
    var store = try store_mod.Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    _ = try store.createMemoryAtom(alloc, .{ .id = "mem_worker_hygiene_public_a", .text = "Worker Dedup Fact", .predicate = "constraint", .object = "public", .scope = "public", .created_by = "human", .status = "verified" });
    _ = try store.createMemoryAtom(alloc, .{ .id = "mem_worker_hygiene_public_b", .text = " worker   dedup fact ", .predicate = "constraint", .object = "public", .scope = "public", .created_by = "agent", .status = "proposed" });
    _ = try store.createMemoryAtom(alloc, .{ .id = "mem_worker_hygiene_project_a", .text = "Worker Dedup Fact", .predicate = "constraint", .object = "project", .scope = "project:nullpantry", .created_by = "human", .status = "verified" });
    _ = try store.createMemoryAtom(alloc, .{ .id = "mem_worker_hygiene_project_b", .text = " worker   dedup fact ", .predicate = "constraint", .object = "project", .scope = "project:nullpantry", .created_by = "agent", .status = "proposed" });

    const job = try store.createJob(alloc, .{
        .job_type = "hygiene",
        .scope = "public",
        .permissions_json = "[\"public\"]",
        .input_json = "{\"stale_after_ms\":0,\"archive_after_ms\":0,\"dedupe_memory_atoms\":true,\"dedupe_limit\":10}",
    });

    const result = try runOnce(alloc, &store, .{ .scopes_json = "[\"admin\"]", .job_limit = 5 });
    try std.testing.expectEqual(@as(usize, 1), result.jobs_succeeded);
    const finished = (try store.getJob(alloc, job.id)).?;
    try std.testing.expect(std.mem.indexOf(u8, finished.result_json, "\"dedupe_deprecated\":1") != null);
    try std.testing.expectEqualStrings("verified", (try store.getMemoryAtom(alloc, "mem_worker_hygiene_public_a")).?.status);
    try std.testing.expectEqualStrings("deprecated", (try store.getMemoryAtom(alloc, "mem_worker_hygiene_public_b")).?.status);
    try std.testing.expectEqualStrings("verified", (try store.getMemoryAtom(alloc, "mem_worker_hygiene_project_a")).?.status);
    try std.testing.expectEqualStrings("proposed", (try store.getMemoryAtom(alloc, "mem_worker_hygiene_project_b")).?.status);
}

test "worker hygiene job dedupes routed named agent memory" {
    var store = try store_mod.Store.initSQLiteWithOptions(std.testing.allocator, ":memory:", .{
        .agent_memory = .{ .backend = .memory_lru },
        .agent_memory_stores = &.{
            .{ .name = "scratch", .config = .{ .backend = .memory_lru } },
        },
    });
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const scratch = storage_routes.Route.parse("scratch");
    const native = storage_routes.Route.parse("native");

    _ = try store.agentMemoryStoreRouted(alloc, .{ .key = "worker.scratch.a", .content = " Worker Team Fact ", .category = "prefs", .session_id = "s-1", .actor_id = "agent:hygiene", .scope = "public", .permissions_json = "[\"public\"]" }, scratch);
    _ = try store.agentMemoryStoreRouted(alloc, .{ .key = "worker.scratch.b", .content = "worker   team fact", .category = "prefs", .session_id = "s-1", .actor_id = "agent:hygiene", .scope = "public", .permissions_json = "[\"public\"]" }, scratch);
    _ = try store.agentMemoryStoreRouted(alloc, .{ .key = "worker.native.a", .content = " Native Worker Fact ", .category = "prefs", .session_id = "s-1", .actor_id = "agent:hygiene", .scope = "public", .permissions_json = "[\"public\"]" }, native);
    _ = try store.agentMemoryStoreRouted(alloc, .{ .key = "worker.native.b", .content = "native   worker fact", .category = "prefs", .session_id = "s-1", .actor_id = "agent:hygiene", .scope = "public", .permissions_json = "[\"public\"]" }, native);

    const job = try store.createJob(alloc, .{
        .job_type = "hygiene",
        .scope = "public",
        .permissions_json = "[\"public\"]",
        .input_json = "{\"stale_after_ms\":31536000000,\"archive_after_ms\":31536000000,\"dedupe_agent_memory\":true,\"store\":\"scratch\",\"category\":\"prefs\",\"session_id\":\"s-1\"}",
    });

    const result = try runOnce(alloc, &store, .{ .scopes_json = "[\"admin\"]", .job_limit = 5 });
    try std.testing.expectEqual(@as(usize, 1), result.jobs_succeeded);
    const finished = (try store.getJob(alloc, job.id)).?;
    try std.testing.expect(std.mem.indexOf(u8, finished.result_json, "\"agent_memory_dedupe_checked\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, finished.result_json, "\"agent_memory_dedupe_groups\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, finished.result_json, "\"agent_memory_dedupe_deprecated\":1") != null);

    const scratch_memories = try store.agentMemoryListByInput(alloc, .{
        .category = "prefs",
        .session_id = "s-1",
        .actor_id = "agent:hygiene",
        .scopes_json = "[\"public\",\"session:s-1\"]",
        .route = scratch,
        .access = .visible,
    });
    try std.testing.expectEqual(@as(usize, 1), scratch_memories.len);
    const native_memories = try store.agentMemoryListByInput(alloc, .{
        .category = "prefs",
        .session_id = "s-1",
        .actor_id = "agent:hygiene",
        .scopes_json = "[\"public\",\"session:s-1\"]",
        .route = native,
        .access = .visible,
    });
    try std.testing.expectEqual(@as(usize, 2), native_memories.len);
}

test "worker summarize job persists explicit messages as routed agent memory" {
    var store = try store_mod.Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const job = try store.createJob(alloc, .{
        .job_type = "summarize",
        .scope = "public",
        .permissions_json = "[\"public\"]",
        .input_json =
        \\{"messages":[{"role":"user","content":"Decision: Worker summary durable jobs are part of NullPantry\nKey fact: Worker summaries can promote semantic memory"}],"persist":true,"scope":"public","permissions":["public"],"key":"summary.worker.explicit","category":"summary","max_chars":1000}
        ,
    });

    const result = try runOnce(alloc, &store, .{
        .scopes_json = "[\"public\"]",
        .capabilities_json = "[\"read\",\"write\",\"propose\"]",
        .job_limit = 5,
        .actor_id = "agent:summary-worker",
    });
    try std.testing.expectEqual(@as(usize, 1), result.jobs_succeeded);
    const finished = (try store.getJob(alloc, job.id)).?;
    try std.testing.expect(std.mem.indexOf(u8, finished.result_json, "\"persisted\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, finished.result_json, "\"profile\":\"generic\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, finished.result_json, "\"summary_strategy\":\"extractive_structured\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, finished.result_json, "\"quality\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, finished.result_json, "Worker summary durable jobs are part of NullPantry") != null);
    try std.testing.expect(std.mem.indexOf(u8, finished.result_json, "\"semantic_fact_count\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, finished.result_json, "\"key\":\"summary.worker.explicit.fact.0\"") != null);

    const memory = (try store.agentMemoryGetByInput(alloc, .{
        .key = "summary.worker.explicit",
        .actor_id = "agent:summary-worker",
        .scopes_json = "[\"public\"]",
        .access = .visible,
    })).?;
    try std.testing.expect(std.mem.indexOf(u8, memory.content, "Worker summary durable jobs are part of NullPantry") != null);
    try std.testing.expectEqualStrings("summary", memory.category);
    const semantic_fact = (try store.agentMemoryGetByInput(alloc, .{
        .key = "summary.worker.explicit.fact.0",
        .actor_id = "agent:summary-worker",
        .scopes_json = "[\"public\"]",
        .access = .visible,
    })).?;
    try std.testing.expectEqualStrings("core", semantic_fact.category);
    try std.testing.expect(std.mem.indexOf(u8, semantic_fact.content, "Worker summaries can promote semantic memory") != null);
    try std.testing.expect(std.mem.indexOf(u8, semantic_fact.content, "[message:") == null);
}

test "worker summarize session job keeps same session id isolated by target actor" {
    var store = try store_mod.Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try store.saveMessage("shared-session", "user", "Decision: Agent A stores Redis-backed shared memory", "agent:a");
    try store.saveMessage("shared-session", "user", "Decision: Agent B stores SQLite-only local memory", "agent:b");

    const job = try store.createJob(alloc, .{
        .job_type = "summarize_session",
        .scope = "session:shared-session",
        .permissions_json = "[\"session:shared-session\"]",
        .input_json =
        \\{"session_id":"shared-session","target_actor_id":"agent:a","persist":true,"scope":"public","permissions":["public"],"key":"summary.session.shared","max_chars":1000}
        ,
    });

    const result = try runOnce(alloc, &store, .{
        .scopes_json = "[\"admin\"]",
        .capabilities_json = "[\"read\",\"write\",\"propose\"]",
        .job_limit = 5,
        .actor_id = "system:worker",
    });
    try std.testing.expectEqual(@as(usize, 1), result.jobs_succeeded);
    const finished = (try store.getJob(alloc, job.id)).?;
    try std.testing.expect(std.mem.indexOf(u8, finished.result_json, "\"message_count\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, finished.result_json, "\"segment_count\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, finished.result_json, "Agent A stores Redis-backed shared memory") != null);
    try std.testing.expect(std.mem.indexOf(u8, finished.result_json, "Agent B stores SQLite-only local memory") == null);

    const memory = (try store.agentMemoryGetByInput(alloc, .{
        .key = "summary.session.shared",
        .session_id = "shared-session",
        .actor_id = "agent:a",
        .scopes_json = "[\"public\",\"session:shared-session\"]",
        .access = .visible,
    })).?;
    try std.testing.expect(std.mem.indexOf(u8, memory.content, "Agent A stores Redis-backed shared memory") != null);
    try std.testing.expect(std.mem.indexOf(u8, memory.content, "Agent B stores SQLite-only local memory") == null);
}

test "worker summarize job supports sliding window compaction metadata" {
    var store = try store_mod.Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var input: std.ArrayListUnmanaged(u8) = .empty;
    try input.appendSlice(alloc, "{\"messages\":[");
    try json.appendString(&input, alloc, "Decision: summarize old A " ++ ("a" ** 400));
    try input.append(alloc, ',');
    try json.appendString(&input, alloc, "Decision: summarize old B " ++ ("b" ** 400));
    try input.append(alloc, ',');
    try json.appendString(&input, alloc, "Decision: keep recent C");
    try input.appendSlice(alloc, "],\"window_size_tokens\":20,\"max_chars\":1000}");

    const job = try store.createJob(alloc, .{
        .job_type = "summarize",
        .scope = "public",
        .permissions_json = "[\"public\"]",
        .input_json = input.items,
    });

    const result = try runOnce(alloc, &store, .{
        .scopes_json = "[\"public\"]",
        .capabilities_json = "[\"read\",\"write\",\"propose\"]",
        .job_limit = 5,
        .actor_id = "agent:summary-window",
    });
    try std.testing.expectEqual(@as(usize, 1), result.jobs_succeeded);
    const finished = (try store.getJob(alloc, job.id)).?;
    try std.testing.expect(std.mem.indexOf(u8, finished.result_json, "\"messages_summarized\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, finished.result_json, "\"messages_kept\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, finished.result_json, "\"summary_strategy\":\"extractive_structured\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, finished.result_json, "summarize old A") != null);
    try std.testing.expect(std.mem.indexOf(u8, finished.result_json, "summarize old B") != null);
    try std.testing.expect(std.mem.indexOf(u8, finished.result_json, "keep recent C") == null);
}

test "worker summarize session job rejects non-admin target actor spoofing" {
    var store = try store_mod.Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try store.saveMessage("spoof-session", "user", "Decision: Agent B secret session fact", "agent:b");
    const job = try store.createJob(alloc, .{
        .job_type = "summarize_session",
        .scope = "session:spoof-session",
        .permissions_json = "[\"session:spoof-session\"]",
        .input_json =
        \\{"session_id":"spoof-session","target_actor_id":"agent:b","messages":[]}
        ,
    });

    const result = try runOnce(alloc, &store, .{
        .scopes_json = "[\"session:spoof-session\"]",
        .capabilities_json = "[\"read\",\"write\",\"propose\"]",
        .job_limit = 5,
        .actor_id = "agent:a",
    });
    try std.testing.expectEqual(@as(usize, 1), result.jobs_failed);
    const finished = (try store.getJob(alloc, job.id)).?;
    try std.testing.expectEqualStrings("failed", finished.status);
    try std.testing.expectEqualStrings("Forbidden", finished.error_text.?);
}

test "worker processes durable Lucid projection jobs" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const tmp_random = try ids.make(std.testing.allocator, "");
    defer std.testing.allocator.free(tmp_random);
    const tmp_name = try std.fmt.allocPrint(std.testing.allocator, "lucid_worker_{d}_{s}", .{ std.c.getpid(), tmp_random });
    defer std.testing.allocator.free(tmp_name);
    const tmp_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp_name});
    defer std.testing.allocator.free(tmp_path);
    try std.Io.Dir.cwd().createDirPath(compat.io(), tmp_path);
    defer std.Io.Dir.cwd().deleteTree(compat.io(), tmp_path) catch {};

    const script =
        \\#!/bin/sh
        \\case "$1" in
        \\  store|delete|context) exit 0 ;;
        \\esac
        \\exit 1
        \\
    ;
    const command = try std.fmt.allocPrint(std.testing.allocator, "{s}/lucid", .{tmp_path});
    defer std.testing.allocator.free(command);
    var file = try std.Io.Dir.cwd().createFile(compat.io(), command, .{ .read = true });
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.File.Writer = .init(file, compat.io(), &buffer);
    try writer.interface.writeAll(script);
    try writer.interface.flush();
    try file.setPermissions(compat.io(), .executable_file);
    file.close(compat.io());

    var store = try store_mod.Store.initSQLiteWithOptions(std.testing.allocator, ":memory:", .{
        .lucid_projection = .{
            .enabled = true,
            .command = command,
            .project_scopes_json = "[\"public\"]",
            .store_timeout_ms = 10_000,
            .failure_cooldown_ms = 0,
        },
    });
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    _ = try store.createSource(alloc, .{ .title = "Lucid projection source", .content = "Source projected into Lucid", .scope = "public" });
    const atom = try store.createMemoryAtom(alloc, .{ .text = "Decision: Lucid projection jobs are durable", .scope = "public" });
    const before = try store.lifecycleDiagnostics();
    try std.testing.expect(before.lucid_projection_pending >= 2);

    const result = try runOnce(alloc, &store, .{ .scopes_json = "[\"public\"]", .job_limit = 10 });
    try std.testing.expect(result.lucid_projection_processed >= 2);
    const after = try store.lifecycleDiagnostics();
    try std.testing.expectEqual(@as(usize, 0), after.lucid_projection_pending);

    try std.testing.expect(try store.patchMemoryAtomStatusActor(atom.id, "superseded", false, "agent:reviewer"));
    const pending_delete = try store.lifecycleDiagnostics();
    try std.testing.expectEqual(@as(usize, 1), pending_delete.lucid_projection_pending);
    const delete_result = try runOnce(alloc, &store, .{ .scopes_json = "[\"public\"]", .job_limit = 10 });
    try std.testing.expectEqual(@as(usize, 1), delete_result.lucid_projection_processed);
}

test "worker processes durable agent memory mirror jobs" {
    var store = try store_mod.Store.initSQLiteWithOptions(std.testing.allocator, ":memory:", .{
        .agent_memory = .{ .backend = .memory_lru },
    });
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    _ = try store.createSource(alloc, .{
        .title = "Worker mirrored source",
        .content = "worker should process primitive mirror jobs",
        .scope = "public",
        .actor_id = "agent:mirror-worker",
    });

    const before = try store.agentMemoryListByInput(alloc, .{
        .category = "primitive:source",
        .actor_id = "agent:mirror-reader",
        .scopes_json = "[\"public\"]",
        .route = .{ .target = .runtime },
    });
    try std.testing.expectEqual(@as(usize, 0), before.len);

    const result = try runOnce(alloc, &store, .{ .scopes_json = "[\"public\"]", .job_limit = 5 });
    try std.testing.expectEqual(@as(usize, 1), result.jobs_succeeded);
    const after = try store.agentMemoryListByInput(alloc, .{
        .category = "primitive:source",
        .actor_id = "agent:mirror-reader",
        .scopes_json = "[\"public\"]",
        .route = .{ .target = .runtime },
    });
    try std.testing.expectEqual(@as(usize, 1), after.len);
}

test "worker job execution scopes are unique" {
    const job = store_mod.Job{
        .id = "job_scope_unique",
        .job_type = "scan_conflicts",
        .status = "queued",
        .scope = "project:nullpantry",
        .permissions_json = "[\"project:nullpantry\",\"team:memory\"]",
        .object_type = "",
        .object_id = "",
        .input_json = "{}",
        .result_json = "{}",
        .error_text = null,
        .attempts = 0,
        .created_at_ms = 1,
        .updated_at_ms = 1,
    };
    const scopes = try jobExecutionScopesJson(std.testing.allocator, job);
    defer std.testing.allocator.free(scopes);
    try std.testing.expectEqualStrings("[\"project:nullpantry\",\"team:memory\"]", scopes);
}

test "worker job storage route owns parsed selectors" {
    const allocator = std.testing.allocator;

    const named = try jobStorageRouteOption(allocator, "{\"store\":\"scratch\"}");
    defer named.deinit(allocator);
    try std.testing.expectEqual(store_mod.AgentMemoryStorageTarget.named, named.target);
    try std.testing.expectEqualStrings("scratch", named.name.?);
    try std.testing.expect(named.owned_backing != null);

    const subset = try jobStorageRouteOption(allocator, "{\"stores\":[\"scratch\",\"archive\"]}");
    defer subset.deinit(allocator);
    try std.testing.expectEqual(store_mod.AgentMemoryStorageTarget.subset, subset.target);
    try std.testing.expectEqual(@as(usize, 2), subset.stores.len);
    try std.testing.expectEqualStrings("scratch", subset.stores[0]);
    try std.testing.expectEqualStrings("archive", subset.stores[1]);
    try std.testing.expect(subset.owned_backing != null);

    const csv_subset = try jobStorageRouteOption(allocator, "{\"stores\":\"scratch,archive\"}");
    defer csv_subset.deinit(allocator);
    try std.testing.expectEqual(store_mod.AgentMemoryStorageTarget.subset, csv_subset.target);
    try std.testing.expectEqual(@as(usize, 2), csv_subset.stores.len);
    try std.testing.expectEqualStrings("scratch", csv_subset.stores[0]);
    try std.testing.expectEqualStrings("archive", csv_subset.stores[1]);
    try std.testing.expect(csv_subset.owned_backing != null);

    const native = try jobStorageRouteOption(allocator, "{\"store\":\"native\"}");
    defer native.deinit(allocator);
    try std.testing.expectEqual(store_mod.AgentMemoryStorageTarget.native, native.target);
    try std.testing.expect(native.owned_backing == null);
}

test "worker extraction counts saturate vector chunks" {
    var counts = ExtractionCounts{};
    counts.addVectorChunks(4);
    try std.testing.expectEqual(@as(usize, 4), counts.vector_chunk_count);
    counts.addVectorChunks(std.math.maxInt(usize));
    try std.testing.expectEqual(std.math.maxInt(usize), counts.vector_chunk_count);
}

test "worker persists embed outbox before provider call and replays locally" {
    if (!localVectorOutboxTestsEnabled()) return error.SkipZigTest;

    var store = try store_mod.Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = try store.createSource(alloc, .{
        .source_type = "transcript",
        .title = "Provider outage transcript",
        .content = "Decision: NullPantry must preserve vector work while embedding providers are unavailable",
        .scope = "public",
    });
    const counts = try extractSource(alloc, &store, source, .{
        .provider = .{
            .embedding = .{
                .base_url = "bad://embedding",
                .model = "unavailable",
                .timeout_secs = 1,
            },
        },
    }, .{});
    try std.testing.expectEqual(@as(usize, 0), counts.vector_chunk_count);

    const pending = try store.listVectorOutbox(alloc, .{ .action = "embed", .status = "pending", .limit = 20 });
    try std.testing.expect(pending.len > 0);
    for (pending) |entry| {
        try std.testing.expect(entry.worker_id == null);
        try std.testing.expect(entry.locked_until_ms == null);
    }

    const result = try runOnce(alloc, &store, .{ .scopes_json = "[\"admin\",\"public\"]", .outbox_limit = 50 });
    try std.testing.expect(result.vector_outbox_processed >= pending.len);
    const still_pending = try store.listVectorOutbox(alloc, .{ .action = "embed", .status = "pending", .limit = 20 });
    try std.testing.expectEqual(@as(usize, 0), still_pending.len);
    const indexed = try store.search(alloc, .{
        .query = "embedding providers unavailable",
        .scopes_json = "[\"public\"]",
        .limit = 10,
        .use_vector = true,
    });
    var saw_source = false;
    for (indexed) |result_item| {
        if (std.mem.eql(u8, result_item.id, source.id)) saw_source = true;
    }
    try std.testing.expect(saw_source);
}

test "worker embedding outbox uses shared embedding cache" {
    if (!localVectorOutboxTestsEnabled()) return error.SkipZigTest;

    var store = try store_mod.Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    _ = try store.createMemoryAtom(alloc, .{ .id = "mem_worker_cache_a", .text = "cached worker embedding text", .scope = "public", .created_by = "human" });
    _ = try store.createMemoryAtom(alloc, .{ .id = "mem_worker_cache_b", .text = "cached worker embedding text", .scope = "public", .created_by = "human" });
    const payload_a = try store_mod.vectorEmbedPayloadJson(alloc, 0, "cached worker embedding text", "public", "[]", "[]", null, 64);
    const payload_b = try store_mod.vectorEmbedPayloadJson(alloc, 0, "cached worker embedding text", "public", "[]", "[]", null, 64);
    _ = try store.enqueueVectorOutbox(.{ .action = "embed", .object_type = "memory_atom", .object_id = "mem_worker_cache_a", .payload_json = payload_a });
    _ = try store.enqueueVectorOutbox(.{ .action = "embed", .object_type = "memory_atom", .object_id = "mem_worker_cache_b", .payload_json = payload_b });

    const result = try runOnce(alloc, &store, .{ .scopes_json = "[\"admin\",\"public\"]", .outbox_limit = 10 });
    try std.testing.expect(result.vector_outbox_processed >= 2);
    const stats = try store.embeddingCacheStats();
    try std.testing.expectEqual(@as(usize, 1), stats.entries);
    try std.testing.expectEqual(@as(i64, 1), stats.hits);
}

test "worker llm extraction falls back to heuristic unless strict" {
    var store = try store_mod.Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = try store.createSource(alloc, .{
        .source_type = "transcript",
        .title = "Worker LLM fallback",
        .content = "Decision: worker fallback uses heuristic extraction",
        .scope = "public",
    });
    const fallback_job = try store.createJob(alloc, .{
        .job_type = "ingest",
        .scope = "public",
        .permissions_json = "[\"public\"]",
        .object_type = "source",
        .object_id = source.id,
        .input_json = "{\"create_artifact\":false,\"use_llm_extraction\":true}",
    });

    const fallback_result = try runOnce(alloc, &store, .{ .scopes_json = "[\"public\"]", .outbox_limit = 10 });
    try std.testing.expectEqual(@as(usize, 1), fallback_result.jobs_succeeded);
    const fallback_finished = (try store.getJob(alloc, fallback_job.id)).?;
    try std.testing.expectEqualStrings("succeeded", fallback_finished.status);
    try std.testing.expect(std.mem.indexOf(u8, fallback_finished.result_json, "\"extraction_provider\":\"heuristic\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fallback_finished.result_json, "\"extraction_fallback\":true") != null);

    const search = try store.search(alloc, .{
        .query = "worker fallback heuristic",
        .scopes_json = "[\"public\"]",
        .limit = 10,
        .use_vector = false,
    });
    var saw_atom = false;
    for (search) |result_item| {
        if (std.mem.eql(u8, result_item.result_type, "memory_atom") and
            std.mem.indexOf(u8, result_item.text, "worker fallback uses heuristic extraction") != null)
        {
            saw_atom = true;
        }
    }
    try std.testing.expect(saw_atom);

    const strict_source = try store.createSource(alloc, .{
        .source_type = "transcript",
        .title = "Worker LLM strict",
        .content = "Decision: strict worker extraction fails without provider",
        .scope = "public",
    });
    const strict_job = try store.createJob(alloc, .{
        .job_type = "ingest",
        .scope = "public",
        .permissions_json = "[\"public\"]",
        .object_type = "source",
        .object_id = strict_source.id,
        .input_json = "{\"create_artifact\":false,\"use_llm_extraction\":true,\"strict_llm_extraction\":true}",
    });

    const strict_result = try runOnce(alloc, &store, .{ .scopes_json = "[\"public\"]", .outbox_limit = 10 });
    try std.testing.expectEqual(@as(usize, 1), strict_result.jobs_failed);
    const strict_finished = (try store.getJob(alloc, strict_job.id)).?;
    try std.testing.expectEqualStrings("failed", strict_finished.status);
    try std.testing.expect(std.mem.indexOf(u8, strict_finished.error_text orelse "", "ProviderUnavailable") != null);
}
