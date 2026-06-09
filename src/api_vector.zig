const std = @import("std");
const api_access = @import("api_access.zig");
const api_body = @import("api_body.zig");
const api_responses = @import("api_responses.zig");
const api_types = @import("api_types.zig");
const bounded_int = @import("bounded_int.zig");
const embedding_cache = @import("embedding_cache.zig");
const domain = @import("domain.zig");
const json = @import("json_util.zig");
const store_mod = @import("store.zig");
const vector_runtime_summary = @import("vector_runtime_summary.zig");
const worker = @import("worker.zig");

const Context = api_types.Context;
const HttpResponse = api_types.HttpResponse;
const badJson = api_responses.badJson;
const forbidden = api_responses.forbidden;
const serverError = api_responses.serverError;
const parseBody = api_body.parse;
pub const default_maintenance_limit: usize = 500;
pub const max_maintenance_limit: usize = 500;

pub fn status(ctx: *Context) HttpResponse {
    if (!api_access.hasCapability(ctx, "read")) return forbidden(ctx);
    const pending = ctx.store.countVectorOutbox("pending") catch return serverError(ctx);
    const running = ctx.store.countVectorOutbox("running") catch return serverError(ctx);
    const failed_embedding = ctx.store.countVectorOutbox("failed_embedding") catch return serverError(ctx);
    const failed_external_index = ctx.store.countVectorOutbox("failed_external_index") catch return serverError(ctx);
    const failed_external_delete = ctx.store.countVectorOutbox("failed_external_delete") catch return serverError(ctx);
    const total_chunks = ctx.store.countVectorChunks() catch return serverError(ctx);
    const ann_stats = ctx.store.sqliteVectorAnnStats() catch return serverError(ctx);
    const cfg = ctx.store.vector_backend;
    const external_sinks = ctx.store.vectorExternalSinksJson(ctx.allocator) catch return serverError(ctx);
    defer ctx.allocator.free(external_sinks);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ctx.allocator, "{\"vector\":{\"backend\":") catch return serverError(ctx);
    json.appendString(&out, ctx.allocator, ctx.store.vectorBackendName()) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"local_engine\":") catch return serverError(ctx);
    json.appendString(&out, ctx.allocator, ctx.store.localVectorEngineName()) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"search_engine\":") catch return serverError(ctx);
    json.appendString(&out, ctx.allocator, ctx.store.effectiveVectorSearchEngineName()) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"collection\":") catch return serverError(ctx);
    json.appendString(&out, ctx.allocator, cfg.collection) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"external_enabled\":") catch return serverError(ctx);
    out.appendSlice(ctx.allocator, if (ctx.store.hasExternalVectorStores()) "true" else "false") catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"external_sink_count\":") catch return serverError(ctx);
    out.print(ctx.allocator, "{d}", .{ctx.store.vectorExternalSinkCount()}) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"external_sinks\":") catch return serverError(ctx);
    out.appendSlice(ctx.allocator, external_sinks) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"mode\":") catch return serverError(ctx);
    json.appendString(&out, ctx.allocator, switch (cfg.backend) {
        .local => "local",
        .pgvector => "postgres_pgvector",
        .qdrant => "http",
        .lancedb => "sdk_process",
        .lancedb_http => "http_adapter",
        .weaviate => "http_weaviate",
        .chroma => "http_chroma",
        .opensearch => "http_opensearch",
    }) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"base_url_configured\":") catch return serverError(ctx);
    out.appendSlice(ctx.allocator, if (cfg.base_url != null) "true" else "false") catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"postgres_url_configured\":") catch return serverError(ctx);
    out.appendSlice(ctx.allocator, if (cfg.postgres_url != null) "true" else "false") catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"lancedb_uri_configured\":") catch return serverError(ctx);
    out.appendSlice(ctx.allocator, if (cfg.lancedb_uri != null) "true" else "false") catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"command_configured\":") catch return serverError(ctx);
    out.appendSlice(ctx.allocator, if (cfg.lancedb_command.len > 0) "true" else "false") catch return serverError(ctx);
    out.print(ctx.allocator, ",\"chunker\":{{\"strategy\":", .{}) catch return serverError(ctx);
    json.appendString(&out, ctx.allocator, ctx.chunker.strategy.name()) catch return serverError(ctx);
    out.print(ctx.allocator, ",\"max_chars\":{d},\"overlap_chars\":{d},\"max_tokens\":", .{ ctx.chunker.max_chars, ctx.chunker.overlap_chars }) catch return serverError(ctx);
    if (ctx.chunker.max_tokens) |max_tokens| {
        out.print(ctx.allocator, "{d}", .{max_tokens}) catch return serverError(ctx);
    } else {
        out.appendSlice(ctx.allocator, "null") catch return serverError(ctx);
    }
    out.appendSlice(ctx.allocator, "}") catch return serverError(ctx);
    out.print(ctx.allocator, ",\"sqlite_ann\":{{\"enabled\":{s},\"candidate_multiplier\":{d},\"min_candidates\":{d},\"indexed_chunks\":{d},\"missing_chunks\":{d},\"stale_chunks\":{d},\"orphan_rows\":{d}}}", .{
        if (ann_stats.enabled) "true" else "false",
        ann_stats.candidate_multiplier,
        ann_stats.min_candidates,
        ann_stats.indexed_chunks,
        ann_stats.missing_chunks,
        ann_stats.stale_chunks,
        ann_stats.orphan_rows,
    }) catch return serverError(ctx);
    out.print(ctx.allocator, ",\"canonical_chunks\":{d},\"outbox\":{{\"pending\":{d},\"running\":{d},\"failed_embedding\":{d},\"failed_external_index\":{d},\"failed_external_delete\":{d}", .{ total_chunks, pending, running, failed_embedding, failed_external_index, failed_external_delete }) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, "}}}") catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

pub fn rebuild(ctx: *Context, body: []const u8) HttpResponse {
    if (!domain.hasActorScope(ctx.actor_scopes_json, "admin")) return forbidden(ctx);
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const result = ctx.store.rebuildVectorIndex(ctx.allocator, .{
        .limit = maintenanceLimit(json.intField(obj, "limit")),
        .reset_external = json.boolField(obj, "reset_external") orelse false,
        .retry_failed = json.boolField(obj, "retry_failed") orelse false,
    }) catch return serverError(ctx);
    return maintenanceResponse(ctx, "vector_rebuild", result);
}

pub fn reconcile(ctx: *Context, body: []const u8) HttpResponse {
    if (!domain.hasActorScope(ctx.actor_scopes_json, "admin")) return forbidden(ctx);
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const result = ctx.store.reconcileVectorIndex(ctx.allocator, .{
        .limit = maintenanceLimit(json.intField(parsed.value.object, "limit")),
        .reset_external = false,
        .retry_failed = json.boolField(parsed.value.object, "retry_failed") orelse false,
    }) catch return serverError(ctx);
    return maintenanceResponse(ctx, "vector_reconcile", result);
}

pub fn outboxStatus(ctx: *Context) HttpResponse {
    if (!api_access.hasCapability(ctx, "read")) return forbidden(ctx);
    const pending = ctx.store.countVectorOutbox("pending") catch return serverError(ctx);
    const running = ctx.store.countVectorOutbox("running") catch return serverError(ctx);
    const embedded = ctx.store.countVectorOutbox("embedded") catch return serverError(ctx);
    const failed_embedding = ctx.store.countVectorOutbox("failed_embedding") catch return serverError(ctx);
    const indexed_local = ctx.store.countVectorOutbox("indexed_local") catch return serverError(ctx);
    const indexed_external = ctx.store.countVectorOutbox("indexed_external") catch return serverError(ctx);
    const deleted_external = ctx.store.countVectorOutbox("deleted_external") catch return serverError(ctx);
    const failed_external_index = ctx.store.countVectorOutbox("failed_external_index") catch return serverError(ctx);
    const failed_external_delete = ctx.store.countVectorOutbox("failed_external_delete") catch return serverError(ctx);
    const total = ctx.store.countVectorOutbox(null) catch return serverError(ctx);
    const external_sinks = ctx.store.vectorExternalSinksJson(ctx.allocator) catch return serverError(ctx);
    defer ctx.allocator.free(external_sinks);
    const body = outboxStatusJson(ctx.allocator, .{
        .pending = pending,
        .running = running,
        .embedded = embedded,
        .indexed_local = indexed_local,
        .indexed_external = indexed_external,
        .deleted_external = deleted_external,
        .failed_embedding = failed_embedding,
        .failed_external_index = failed_external_index,
        .failed_external_delete = failed_external_delete,
    }, runtimeSummary(ctx, external_sinks), total) catch return serverError(ctx);
    return .{ .status = "200 OK", .body = body };
}

pub fn outboxRun(ctx: *Context, body: []const u8) HttpResponse {
    if (!domain.hasActorScope(ctx.actor_scopes_json, "admin")) return forbidden(ctx);
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const limit = worker.requestOutboxLimit(json.intField(parsed.value.object, "limit"));
    const result = worker.runVectorOutboxOnce(ctx.allocator, ctx.store, .{
        .scopes_json = ctx.actor_scopes_json,
        .capabilities_json = ctx.actor_capabilities_json,
        .outbox_limit = limit,
        .provider = ctx.provider,
        .use_embedding_cache = json.boolField(parsed.value.object, "use_embedding_cache") orelse json.boolField(parsed.value.object, "use_cache") orelse true,
        .embedding_cache_max_entries = embedding_cache.maxEntriesFromObject(parsed.value.object),
        .actor_id = ctx.actor_id,
    }) catch return serverError(ctx);
    const pending = ctx.store.countVectorOutbox("pending") catch return serverError(ctx);
    const embedded = ctx.store.countVectorOutbox("embedded") catch return serverError(ctx);
    const indexed_local = ctx.store.countVectorOutbox("indexed_local") catch return serverError(ctx);
    const indexed_external = ctx.store.countVectorOutbox("indexed_external") catch return serverError(ctx);
    const deleted_external = ctx.store.countVectorOutbox("deleted_external") catch return serverError(ctx);
    const external_sinks = ctx.store.vectorExternalSinksJson(ctx.allocator) catch return serverError(ctx);
    defer ctx.allocator.free(external_sinks);
    const response = outboxRunJson(ctx.allocator, result, .{
        .pending = pending,
        .embedded = embedded,
        .indexed_local = indexed_local,
        .indexed_external = indexed_external,
        .deleted_external = deleted_external,
    }, runtimeSummary(ctx, external_sinks)) catch return serverError(ctx);
    return .{ .status = "200 OK", .body = response };
}

fn maintenanceResponse(ctx: *Context, key: []const u8, result: store_mod.VectorMaintenanceResult) HttpResponse {
    const external_sinks = ctx.store.vectorExternalSinksJson(ctx.allocator) catch return serverError(ctx);
    defer ctx.allocator.free(external_sinks);
    const body = maintenanceResponseJson(ctx.allocator, key, result, runtimeSummary(ctx, external_sinks)) catch return serverError(ctx);
    return .{ .status = "200 OK", .body = body };
}

const VectorOutboxCounts = struct {
    pending: usize = 0,
    running: usize = 0,
    embedded: usize = 0,
    indexed_local: usize = 0,
    indexed_external: usize = 0,
    deleted_external: usize = 0,
    failed_embedding: usize = 0,
    failed_external_index: usize = 0,
    failed_external_delete: usize = 0,
};

const VectorRuntimeSummary = vector_runtime_summary.Summary;

fn runtimeSummary(ctx: *Context, external_sinks_json: []const u8) VectorRuntimeSummary {
    return .{
        .active_sink = ctx.store.vectorBackendName(),
        .local_engine = ctx.store.localVectorEngineName(),
        .search_engine = ctx.store.effectiveVectorSearchEngineName(),
        .external_sinks_json = external_sinks_json,
    };
}

fn outboxStatusJson(allocator: std.mem.Allocator, counts: VectorOutboxCounts, runtime: VectorRuntimeSummary, total: usize) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.print(
        allocator,
        "{{\"outbox\":{{\"pending\":{d},\"running\":{d},\"embedded\":{d},\"failed_embedding\":{d},\"indexed_local\":{d},\"indexed_external\":{d},\"deleted_external\":{d},\"failed_external_index\":{d},\"failed_external_delete\":{d}",
        .{ counts.pending, counts.running, counts.embedded, counts.failed_embedding, counts.indexed_local, counts.indexed_external, counts.deleted_external, counts.failed_external_index, counts.failed_external_delete },
    );
    try vector_runtime_summary.appendFields(allocator, &out, runtime);
    try out.print(allocator, ",\"total\":{d}", .{total});
    try out.appendSlice(allocator, "}}");
    return out.toOwnedSlice(allocator);
}

fn outboxRunJson(allocator: std.mem.Allocator, result: store_mod.VectorOutboxRunResult, counts: VectorOutboxCounts, runtime: VectorRuntimeSummary) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.print(
        allocator,
        "{{\"outbox_run\":{{\"processed\":{d},\"failed\":{d},\"pending\":{d},\"embedded\":{d},\"indexed_local\":{d},\"indexed_external\":{d},\"deleted_external\":{d}",
        .{ result.processed, result.failed, counts.pending, counts.embedded, counts.indexed_local, counts.indexed_external, counts.deleted_external },
    );
    try vector_runtime_summary.appendFields(allocator, &out, runtime);
    try out.appendSlice(allocator, "}}");
    return out.toOwnedSlice(allocator);
}

fn maintenanceResponseJson(allocator: std.mem.Allocator, key: []const u8, result: store_mod.VectorMaintenanceResult, runtime: VectorRuntimeSummary) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '{');
    try json.appendString(&out, allocator, key);
    try out.print(
        allocator,
        ":{{\"canonical_chunks\":{d},\"enqueued_upserts\":{d},\"requeued_failed\":{d},\"external_enabled\":{s}",
        .{ result.canonical_chunks, result.enqueued_upserts, result.requeued_failed, if (result.external_enabled) "true" else "false" },
    );
    try vector_runtime_summary.appendFields(allocator, &out, runtime);
    try out.appendSlice(allocator, "}}");
    return out.toOwnedSlice(allocator);
}

pub fn maintenanceLimit(value: ?i64) usize {
    const raw = value orelse return default_maintenance_limit;
    if (raw <= 0) return default_maintenance_limit;
    return bounded_int.positiveI64ToUsizeBounded(raw, max_maintenance_limit);
}

test "api vector maintenance limits preserve defaults and cap explicit values" {
    try std.testing.expectEqual(default_maintenance_limit, maintenanceLimit(null));
    try std.testing.expectEqual(default_maintenance_limit, maintenanceLimit(-1));
    try std.testing.expectEqual(@as(usize, 42), maintenanceLimit(42));
    try std.testing.expectEqual(max_maintenance_limit, maintenanceLimit(std.math.maxInt(i64)));
}

test "api vector response json escapes runtime labels" {
    const allocator = std.testing.allocator;
    const body = try maintenanceResponseJson(
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

    const result = parsed.value.object.get("vector\"rebuild").?.object;
    try std.testing.expectEqual(@as(i64, 1), result.get("canonical_chunks").?.integer);
    try std.testing.expectEqual(@as(i64, 2), result.get("enqueued_upserts").?.integer);
    try std.testing.expectEqual(@as(i64, 3), result.get("requeued_failed").?.integer);
    try std.testing.expect(result.get("external_enabled").?.bool);
    try std.testing.expectEqualStrings("sink\"quoted", result.get("active_sink").?.string);
    try std.testing.expectEqualStrings("local\\engine", result.get("local_engine").?.string);
    try std.testing.expectEqualStrings("search\nengine", result.get("search_engine").?.string);
    try std.testing.expectEqual(@as(usize, 1), result.get("external_sinks").?.array.items.len);
}

test "api vector response json enforces external sinks array root" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidRawJson, maintenanceResponseJson(
        allocator,
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
