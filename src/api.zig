const std = @import("std");
const Store = @import("store.zig").Store;
const store_mod = @import("store.zig");
const domain = @import("domain.zig");
const json = @import("json_util.zig");
const engines = @import("engines.zig");
const retrieval = @import("retrieval.zig");
const lifecycle = @import("lifecycle.zig");
const vector_mod = @import("vector.zig");
const vector_text = @import("vector_text.zig");
const analytics_runtime = @import("analytics_runtime.zig");
const ids = @import("ids.zig");
const extraction = @import("extraction.zig");
const providers = @import("providers.zig");
const worker = @import("worker.zig");
const artifacts = @import("artifacts.zig");
const migrations = @import("migrations.zig");
const access = @import("access.zig");
const auth = @import("auth.zig");
const markdown_adapter = @import("markdown_adapter.zig");
const markdown_filesystem = @import("markdown_filesystem.zig");
const compat = @import("compat.zig");
const graph_mod = @import("graph.zig");
const agent_memory_reducer = @import("agent_memory_reducer.zig");
const agent_memory_runtime = @import("agent_memory_runtime.zig");

pub const Context = struct {
    allocator: std.mem.Allocator,
    store: *Store,
    required_token: ?[]const u8 = null,
    token_principals_json: ?[]const u8 = null,
    actor_id: []const u8 = "local",
    actor_scopes_json: []const u8 = "[\"admin\"]",
    actor_capabilities_json: []const u8 = "[\"read\",\"write\",\"propose\",\"verify\",\"delete\",\"export\",\"feed_apply\"]",
    embedding_base_url: ?[]const u8 = null,
    embedding_api_key: ?[]const u8 = null,
    embedding_model: ?[]const u8 = null,
    embedding_provider: providers.EmbeddingProviderKind = .openai_compatible,
    embedding_fallbacks: []const providers.EmbeddingEndpointConfig = &.{},
    embedding_dimensions: usize = 64,
    llm_base_url: ?[]const u8 = null,
    llm_api_key: ?[]const u8 = null,
    llm_model: ?[]const u8 = null,
    provider_timeout_secs: u32 = 30,
    trust_actor_headers: bool = false,
};

pub const HttpResponse = json.HttpResponse;

pub fn handleRequest(ctx: *Context, method: []const u8, target: []const u8, body: []const u8, raw_request: []const u8) HttpResponse {
    const parsed = json.parsePath(target);
    const path = parsed.path;
    const seg0 = decodeSegment(ctx.allocator, json.segment(path, 0)) catch return serverError(ctx);
    const seg1 = decodeSegment(ctx.allocator, json.segment(path, 1)) catch return serverError(ctx);
    const seg2 = decodeSegment(ctx.allocator, json.segment(path, 2)) catch return serverError(ctx);
    const seg3 = decodeSegment(ctx.allocator, json.segment(path, 3)) catch return serverError(ctx);

    const is_get = std.mem.eql(u8, method, "GET");
    const is_post = std.mem.eql(u8, method, "POST");
    const is_put = std.mem.eql(u8, method, "PUT");
    const is_patch = std.mem.eql(u8, method, "PATCH");
    const is_delete = std.mem.eql(u8, method, "DELETE");

    const is_health = is_get and ((eql(seg0, "health") and seg1 == null) or (eql(seg0, "v1") and eql(seg1, "health") and seg2 == null));
    if (!is_health and !authorized(ctx, raw_request)) {
        return json.errorResponse(ctx.allocator, 401, "unauthorized", "Missing or invalid Authorization header");
    }
    if (is_health) return health(ctx);

    const original_actor_id = ctx.actor_id;
    const original_scopes = ctx.actor_scopes_json;
    const original_capabilities = ctx.actor_capabilities_json;
    applyRequestPrincipal(ctx, raw_request) catch return json.errorResponse(ctx.allocator, 400, "bad_request", "Invalid actor scope or capability headers");
    defer {
        ctx.actor_id = original_actor_id;
        ctx.actor_scopes_json = original_scopes;
        ctx.actor_capabilities_json = original_capabilities;
    }

    if (!eql(seg0, "v1")) return json.errorResponse(ctx.allocator, 404, "not_found", "Not found");

    if (eql(seg1, "engines") and is_get) {
        return engineRegistry(ctx);
    } else if ((eql(seg1, "openapi.json") or eql(seg1, "openapi")) and is_get) {
        return openApiDocument(ctx);
    } else if (eql(seg1, "capabilities") and is_get) {
        return capabilities(ctx);
    } else if (eql(seg1, "providers") and is_get) {
        return providerRegistry(ctx);
    } else if (eql(seg1, "connectors")) {
        if (is_get and seg2 == null) return connectors(ctx);
        if (is_get and seg2 != null and eql(seg3, "cursor")) return connectorCursorGet(ctx, seg2.?, parsed.query);
        if (is_post and seg2 != null and eql(seg3, "cursor")) return connectorCursorUpsert(ctx, seg2.?, body);
        if (is_post and seg2 != null and eql(seg3, "ingest")) return connectorIngest(ctx, seg2.?, body);
    } else if (eql(seg1, "markdown")) {
        if (is_post and eql(seg2, "import")) return markdownImport(ctx, body);
        if (is_post and eql(seg2, "import-directory")) return markdownImportDirectory(ctx, body);
        if (is_post and eql(seg2, "export")) return markdownExport(ctx, body);
        if (is_post and eql(seg2, "export-directory")) return markdownExportDirectory(ctx, body);
    } else if (eql(seg1, "artifact-types") and is_get) {
        return artifactTypes(ctx);
    } else if (eql(seg1, "spaces")) {
        if (is_post and seg2 == null) return createSpace(ctx, body);
        if (is_get and seg2 == null) return listSpaces(ctx, parsed.query);
        if (is_get and seg2 != null and seg3 == null) return getSpace(ctx, seg2.?);
    } else if (eql(seg1, "policy-scopes")) {
        if (is_post and seg2 == null) return upsertPolicyScope(ctx, body);
        if (is_get and seg2 == null) return listPolicyScopes(ctx, parsed.query);
        if (is_get and seg2 != null and seg3 == null) return getPolicyScope(ctx, seg2.?);
    } else if (eql(seg1, "sdk") and eql(seg2, "manifest") and is_get) {
        return sdkManifest(ctx);
    } else if (eql(seg1, "ingest") and is_post) {
        return ingest(ctx, body);
    } else if (eql(seg1, "extract-memory") and is_post) {
        return extractMemory(ctx, body);
    } else if (eql(seg1, "jobs")) {
        if (is_post and seg2 == null) return createJob(ctx, body);
        if (is_get and seg2 == null) return listJobs(ctx, parsed.query);
        if (is_post and seg2 != null and eql(seg3, "run")) return runJob(ctx, seg2.?);
    } else if (eql(seg1, "conflicts")) {
        if (is_get and seg2 == null) return listConflicts(ctx, parsed.query);
        if (is_post and eql(seg2, "scan")) return scanConflicts(ctx, body);
    } else if (eql(seg1, "agent-memory")) {
        if (is_post and eql(seg2, "search")) return agentMemorySearch(ctx, body);
        if (is_get and eql(seg2, "count")) return agentMemoryCount(ctx, parsed.query);
        if (is_post and seg2 == null) return agentMemoryStoreBody(ctx, body);
        if ((is_put or is_post) and seg2 != null and seg3 == null) return agentMemoryStoreKey(ctx, seg2.?, body);
        if (is_get and seg2 == null) return agentMemoryList(ctx, parsed.query);
        if (is_get and seg2 != null and seg3 == null) return agentMemoryGet(ctx, seg2.?, parsed.query);
        if (is_delete and seg2 != null and seg3 == null) return agentMemoryDelete(ctx, seg2.?, parsed.query);
    } else if (eql(seg1, "agent-sessions")) {
        return handleAgentSessions(ctx, method, parsed.query, seg2, seg3, body);
    } else if (eql(seg1, "sources")) {
        if (is_post and seg2 == null) return createSource(ctx, body);
        if (is_get and seg2 != null and seg3 == null) return getSource(ctx, seg2.?);
    } else if (eql(seg1, "artifacts")) {
        if (is_post and seg2 == null) return createArtifact(ctx, body);
        if (is_get and seg2 != null and seg3 == null) return getArtifact(ctx, seg2.?);
    } else if (eql(seg1, "memory-atoms")) {
        if (is_post and seg2 == null) return createMemoryAtom(ctx, body);
        if ((is_patch or is_put or is_post) and seg2 != null and seg3 == null) return patchMemoryAtom(ctx, seg2.?, body);
    } else if (eql(seg1, "entities")) {
        if (eql(seg2, "resolve") and is_post) return resolveEntity(ctx, body);
        if (is_get and seg2 != null and seg3 == null) return getEntity(ctx, seg2.?);
        if ((is_patch or is_put or is_post) and seg2 != null and seg3 == null) return patchEntity(ctx, seg2.?, body);
        if (is_delete and seg2 != null and seg3 == null) return deleteEntity(ctx, seg2.?);
    } else if (eql(seg1, "relations")) {
        if (is_post and seg2 == null) return createRelation(ctx, body);
        if (is_get and seg2 != null and seg3 == null) return getRelation(ctx, seg2.?);
        if ((is_patch or is_put) and seg2 != null and seg3 == null) return patchRelation(ctx, seg2.?, body);
        if (is_delete and seg2 != null and seg3 == null) return deleteRelation(ctx, seg2.?);
    } else if (eql(seg1, "graph")) {
        if (eql(seg2, "schema") and is_get) return graphSchema(ctx);
        if (eql(seg2, "query") and is_post) return graphQuery(ctx, body);
        if (eql(seg2, "neighbors") and is_post) return graphNeighbors(ctx, body);
        if (eql(seg2, "path") and is_post) return graphPath(ctx, body);
    } else if (eql(seg1, "search") and is_post) {
        return search(ctx, body);
    } else if (eql(seg1, "vector") and eql(seg2, "status") and is_get) {
        return vectorStatus(ctx);
    } else if (eql(seg1, "vector") and eql(seg2, "embed") and is_post) {
        return vectorEmbed(ctx, body);
    } else if (eql(seg1, "vector") and eql(seg2, "upsert") and is_post) {
        return vectorUpsert(ctx, body);
    } else if (eql(seg1, "vector") and eql(seg2, "search") and is_post) {
        return vectorSearch(ctx, body);
    } else if (eql(seg1, "vector") and eql(seg2, "delete") and is_post) {
        return vectorDelete(ctx, body);
    } else if (eql(seg1, "vector") and eql(seg2, "rebuild") and is_post) {
        return vectorRebuild(ctx, body);
    } else if (eql(seg1, "vector") and eql(seg2, "reconcile") and is_post) {
        return vectorReconcile(ctx, body);
    } else if (eql(seg1, "vector") and eql(seg2, "outbox") and is_get) {
        return vectorOutboxStatus(ctx);
    } else if (eql(seg1, "vector") and eql(seg2, "outbox") and eql(seg3, "run") and is_post) {
        return vectorOutboxRun(ctx, body);
    } else if (eql(seg1, "retrieval") and eql(seg2, "plan") and is_post) {
        return retrievalPlan(ctx, body);
    } else if (eql(seg1, "retrieval") and eql(seg2, "search") and is_post) {
        return retrievalSearch(ctx, body);
    } else if (eql(seg1, "workers") and eql(seg2, "run") and is_post) {
        return workersRun(ctx, body);
    } else if (eql(seg1, "memory") and (eql(seg2, "feed") or eql(seg2, "events")) and is_get) {
        return memoryFeed(ctx, parsed.query);
    } else if (eql(seg1, "memory") and (eql(seg2, "feed") or eql(seg2, "events")) and is_post) {
        return appendMemoryFeed(ctx, body);
    } else if (eql(seg1, "memory") and eql(seg2, "status") and is_get) {
        return memoryFeedStatus(ctx);
    } else if (eql(seg1, "memory") and eql(seg2, "compact") and is_post) {
        return memoryFeedCompact(ctx, body);
    } else if (eql(seg1, "memory") and eql(seg2, "checkpoint") and is_get) {
        return memoryFeedCheckpoint(ctx, parsed.query);
    } else if (eql(seg1, "memory") and eql(seg2, "checkpoint") and is_post) {
        return memoryFeedCheckpointRestore(ctx, body);
    } else if (eql(seg1, "memory") and eql(seg2, "apply") and is_post) {
        return applyMemoryEvent(ctx, body);
    } else if (eql(seg1, "lifecycle") and eql(seg2, "lucid") and eql(seg3, "status") and is_get) {
        return lifecycleLucidStatus(ctx);
    } else if (eql(seg1, "lifecycle") and eql(seg2, "lucid") and eql(seg3, "rebuild") and is_post) {
        return lifecycleLucidRebuild(ctx, body);
    } else if (eql(seg1, "lifecycle") and eql(seg2, "analytics") and eql(seg3, "status") and is_get) {
        return lifecycleAnalyticsStatus(ctx);
    } else if (eql(seg1, "lifecycle") and eql(seg2, "analytics") and eql(seg3, "query") and is_post) {
        return lifecycleAnalyticsQuery(ctx, body);
    } else if (eql(seg1, "lifecycle") and eql(seg2, "analytics") and eql(seg3, "export") and is_post) {
        return lifecycleAnalyticsExport(ctx, body);
    } else if (eql(seg1, "lifecycle") and eql(seg2, "diagnostics") and is_get) {
        return lifecycleDiagnostics(ctx);
    } else if (eql(seg1, "lifecycle") and eql(seg2, "snapshot") and eql(seg3, "export") and is_post) {
        return lifecycleSnapshotExport(ctx, body);
    } else if (eql(seg1, "lifecycle") and eql(seg2, "snapshot") and eql(seg3, "import") and is_post) {
        return lifecycleSnapshotImport(ctx, body);
    } else if (eql(seg1, "lifecycle") and eql(seg2, "snapshot") and is_post) {
        return lifecycleSnapshot(ctx, body);
    } else if (eql(seg1, "lifecycle") and eql(seg2, "cache") and eql(seg3, "put") and is_post) {
        return responseCachePut(ctx, body);
    } else if (eql(seg1, "lifecycle") and eql(seg2, "cache") and eql(seg3, "get") and is_post) {
        return responseCacheGet(ctx, body);
    } else if (eql(seg1, "lifecycle") and eql(seg2, "semantic-cache") and eql(seg3, "put") and is_post) {
        return semanticCachePut(ctx, body);
    } else if (eql(seg1, "lifecycle") and eql(seg2, "semantic-cache") and eql(seg3, "search") and is_post) {
        return semanticCacheSearch(ctx, body);
    } else if (eql(seg1, "lifecycle") and eql(seg2, "hygiene") and is_post) {
        return lifecycleHygiene(ctx, body);
    } else if (eql(seg1, "lifecycle") and eql(seg2, "summarize") and is_post) {
        return lifecycleSummarize(ctx, body);
    } else if (eql(seg1, "lifecycle") and eql(seg2, "rollout") and is_post) {
        return lifecycleRollout(ctx, body);
    } else if (eql(seg1, "ask") and is_post) {
        return ask(ctx, body);
    } else if (eql(seg1, "context-packs") and is_post) {
        return contextPack(ctx, body);
    } else if (eql(seg1, "remember") and is_post) {
        return remember(ctx, body);
    } else if (eql(seg1, "forget") and is_post) {
        return statusAction(ctx, body, "deprecated", false, "forgotten");
    } else if (eql(seg1, "verify") and is_post) {
        return statusAction(ctx, body, "verified", true, "verified");
    } else if (eql(seg1, "mark-stale") and is_post) {
        return statusAction(ctx, body, "stale", false, "stale");
    }

    return json.errorResponse(ctx.allocator, 404, "not_found", "Not found");
}

fn handleAgentSessions(ctx: *Context, method: []const u8, query: []const u8, seg2: ?[]u8, seg3: ?[]u8, body: []const u8) HttpResponse {
    const is_get = std.mem.eql(u8, method, "GET");
    const is_post = std.mem.eql(u8, method, "POST");
    const is_put = std.mem.eql(u8, method, "PUT");
    const is_delete = std.mem.eql(u8, method, "DELETE");

    if (seg2 == null and is_get) {
        if (!allAgentSessionsReadAllowed(ctx)) return forbidden(ctx);
        const limit = parseLimit(json.queryParam(query, "limit"), 50);
        const offset = parseLimit(json.queryParam(query, "offset"), 0);
        const storage_target = agentMemoryStorageTargetFromQuery(ctx.allocator, query) catch return serverError(ctx);
        const result = ctx.store.listSessionsRouted(ctx.allocator, limit, offset, actorFilter(ctx), storage_target) catch |err| switch (err) {
            error.AgentMemoryStorageUnavailable => return agentMemoryStorageUnavailable(ctx),
            else => return serverError(ctx),
        };
        return writeHistoryList(ctx, result, limit, offset);
    }

    if (eql(seg2, "auto-saved") and seg3 == null and is_delete) {
        const session_id = json.queryParamDecoded(ctx.allocator, query, "session_id") catch return serverError(ctx);
        if (session_id) |sid| {
            if (!agentSessionWriteAllowed(ctx, sid)) return forbidden(ctx);
        } else if (!allAgentSessionsWriteAllowed(ctx)) {
            return forbidden(ctx);
        }
        const storage_target = agentMemoryStorageTargetFromQuery(ctx.allocator, query) catch return serverError(ctx);
        ctx.store.clearAutoSavedRouted(session_id, actorFilter(ctx), storage_target) catch |err| switch (err) {
            error.AgentMemoryStorageUnavailable => return agentMemoryStorageUnavailable(ctx),
            else => return serverError(ctx),
        };
        return ok(ctx, "{\"ok\":true}");
    }

    if (seg2 != null and seg3 == null and is_get) {
        if (!agentSessionReadAllowed(ctx, seg2.?)) return forbidden(ctx);
        const limit = parseLimit(json.queryParam(query, "limit"), 100);
        const offset = parseLimit(json.queryParam(query, "offset"), 0);
        const storage_target = agentMemoryStorageTargetFromQuery(ctx.allocator, query) catch return serverError(ctx);
        const result = ctx.store.historyRouted(ctx.allocator, seg2.?, limit, offset, actorFilter(ctx), storage_target) catch |err| switch (err) {
            error.AgentMemoryStorageUnavailable => return agentMemoryStorageUnavailable(ctx),
            else => return serverError(ctx),
        };
        return writeHistoryShow(ctx, seg2.?, result, limit, offset);
    }

    if (seg2 != null and eql(seg3, "messages")) {
        if ((is_post or is_delete) and !agentSessionWriteAllowed(ctx, seg2.?)) return forbidden(ctx);
        if (is_get and !agentSessionReadAllowed(ctx, seg2.?)) return forbidden(ctx);
        if (is_post) return saveMessage(ctx, seg2.?, body, query);
        if (is_get) return loadMessages(ctx, seg2.?, query);
        if (is_delete) {
            const storage_target = agentMemoryStorageTargetFromQuery(ctx.allocator, query) catch return serverError(ctx);
            ctx.store.clearMessagesRouted(seg2.?, actorFilter(ctx), storage_target) catch |err| switch (err) {
                error.AgentMemoryStorageUnavailable => return agentMemoryStorageUnavailable(ctx),
                else => return serverError(ctx),
            };
            return ok(ctx, "{\"ok\":true}");
        }
    }

    if (seg2 != null and eql(seg3, "usage")) {
        if ((is_put or is_delete) and !agentSessionWriteAllowed(ctx, seg2.?)) return forbidden(ctx);
        if (is_get and !agentSessionReadAllowed(ctx, seg2.?)) return forbidden(ctx);
        if (is_put) return saveUsage(ctx, seg2.?, body, query);
        if (is_get) return loadUsage(ctx, seg2.?, query);
        if (is_delete) {
            const storage_target = agentMemoryStorageTargetFromQuery(ctx.allocator, query) catch return serverError(ctx);
            _ = ctx.store.deleteUsageRouted(seg2.?, actorFilter(ctx), storage_target) catch |err| switch (err) {
                error.AgentMemoryStorageUnavailable => return agentMemoryStorageUnavailable(ctx),
                else => return serverError(ctx),
            };
            return ok(ctx, "{\"ok\":true}");
        }
    }

    return json.errorResponse(ctx.allocator, 404, "not_found", "Not found");
}

fn agentSessionReadAllowed(ctx: *Context, session_id: []const u8) bool {
    if (domain.hasActorScope(ctx.actor_scopes_json, "admin")) return true;
    if (!hasCapability(ctx, "read")) return false;
    const scope = std.fmt.allocPrint(ctx.allocator, "session:{s}", .{session_id}) catch return false;
    return domain.scopeVisible(scope, ctx.actor_scopes_json);
}

fn agentSessionWriteAllowed(ctx: *Context, session_id: []const u8) bool {
    if (domain.hasActorScope(ctx.actor_scopes_json, "admin")) return true;
    if (!hasCapability(ctx, "write")) return false;
    const scope = std.fmt.allocPrint(ctx.allocator, "session:{s}", .{session_id}) catch return false;
    return domain.scopeWritable(scope, ctx.actor_scopes_json);
}

fn allAgentSessionsReadAllowed(ctx: *Context) bool {
    if (domain.hasActorScope(ctx.actor_scopes_json, "admin")) return true;
    if (!hasCapability(ctx, "read")) return false;
    return domain.scopeVisible("session:", ctx.actor_scopes_json);
}

fn allAgentSessionsWriteAllowed(ctx: *Context) bool {
    if (domain.hasActorScope(ctx.actor_scopes_json, "admin")) return true;
    if (!hasCapability(ctx, "write")) return false;
    return domain.scopeWritable("session:", ctx.actor_scopes_json);
}

fn authorized(ctx: *Context, raw_request: []const u8) bool {
    return auth.authorized(ctx.allocator, ctx.required_token, ctx.token_principals_json, raw_request);
}

fn applyRequestPrincipal(ctx: *Context, raw_request: []const u8) !void {
    const applied = try auth.applyRequestPrincipal(.{
        .allocator = ctx.allocator,
        .required_token = ctx.required_token,
        .token_principals_json = ctx.token_principals_json,
        .trust_actor_headers = ctx.trust_actor_headers,
        .actor_id = ctx.actor_id,
        .actor_scopes_json = ctx.actor_scopes_json,
        .actor_capabilities_json = ctx.actor_capabilities_json,
    }, raw_request);
    ctx.actor_id = applied.actor_id;
    ctx.actor_scopes_json = applied.actor_scopes_json;
    ctx.actor_capabilities_json = applied.actor_capabilities_json;
}

fn health(ctx: *Context) HttpResponse {
    if (!ctx.store.health()) return json.errorResponse(ctx.allocator, 500, "unhealthy", "Storage backend is unavailable");
    const schema_version = ctx.store.schemaVersion() catch return json.errorResponse(ctx.allocator, 500, "unhealthy", "Schema version cannot be read");
    const schema_ok = schema_version >= migrations.expected_schema_version;
    if (!schema_ok) return json.errorResponse(ctx.allocator, 500, "unhealthy", "Schema version is behind the runtime");
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.print(ctx.allocator, "{{\"ok\":true,\"service\":\"nullpantry\",\"backend\":\"{s}\",\"agent_memory_backend\":\"{s}\",\"schema_version\":{d},\"expected_schema_version\":{d},\"schema_ok\":true}}", .{ ctx.store.backendName(), ctx.store.agentMemoryBackendName(), schema_version, migrations.expected_schema_version }) catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn createSource(ctx: *Context, body: []const u8) HttpResponse {
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const title = json.stringField(obj, "title") orelse return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing title");
    const storage_route = agentMemoryStorageTargetFromObject(ctx.allocator, obj) catch return serverError(ctx);
    const input = store_mod.SourceInput{
        .source_type = json.stringField(obj, "type") orelse "manual",
        .title = title,
        .raw_content_uri = json.nullableStringField(obj, "raw_content_uri"),
        .content = json.stringField(obj, "content") orelse "",
        .author = json.nullableStringField(obj, "author"),
        .participants_json = rawField(ctx.allocator, obj, "participants", "[]") catch return serverError(ctx),
        .permissions_json = rawField(ctx.allocator, obj, "permissions", "[]") catch return serverError(ctx),
        .scope = json.stringField(obj, "scope") orelse "workspace",
        .checksum = json.nullableStringField(obj, "checksum"),
        .language = json.nullableStringField(obj, "language"),
        .related_entities_json = rawField(ctx.allocator, obj, "related_entities", "[]") catch return serverError(ctx),
        .metadata_json = rawField(ctx.allocator, obj, "metadata", "{}") catch return serverError(ctx),
        .actor_id = ctx.actor_id,
        .storage_route = storage_route,
    };
    if (!canWriteRecord(ctx, input.scope, input.permissions_json)) return forbidden(ctx);
    const source = ctx.store.createSource(ctx.allocator, input) catch |err| switch (err) {
        error.AgentMemoryStorageUnavailable => return agentMemoryStorageUnavailable(ctx),
        else => return serverError(ctx),
    };
    _ = upsertAutoVector(ctx, "source", source.id, source.content, source.scope, source.permissions_json) catch 0;
    return objectResponse(ctx, "source", source);
}

fn getSource(ctx: *Context, id: []const u8) HttpResponse {
    if (!hasCapability(ctx, "read")) return forbidden(ctx);
    const source = ctx.store.getSource(ctx.allocator, id) catch return serverError(ctx);
    if (source == null) return json.errorResponse(ctx.allocator, 404, "not_found", "Source not found");
    if (!recordVisibleToActor(ctx, source.?.scope, source.?.permissions_json)) return json.errorResponse(ctx.allocator, 404, "not_found", "Source not found");
    return objectResponse(ctx, "source", source.?);
}

fn createArtifact(ctx: *Context, body: []const u8) HttpResponse {
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const title = json.stringField(obj, "title") orelse return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing title");
    const scope = json.stringField(obj, "scope") orelse "workspace";
    const permissions_json = rawField(ctx.allocator, obj, "permissions", "[]") catch return serverError(ctx);
    const storage_route = agentMemoryStorageTargetFromObject(ctx.allocator, obj) catch return serverError(ctx);
    if (!canWriteRecord(ctx, scope, permissions_json)) return forbidden(ctx);
    const artifact_type = json.stringField(obj, "type") orelse json.stringField(obj, "artifact_type") orelse "page";
    const status = json.stringField(obj, "status") orelse if (std.mem.eql(u8, artifact_type, "decision")) "proposed" else "draft";
    if (!artifacts.validStatus(artifact_type, status)) {
        return json.errorResponse(ctx.allocator, 400, "bad_request", "Invalid artifact status for this artifact type");
    }
    const fields_json = normalizeArtifactFieldsJson(ctx, obj, artifact_type) catch |err| switch (err) {
        error.MissingRequiredField => return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing required artifact field"),
        error.InvalidPayload => return json.errorResponse(ctx.allocator, 400, "bad_request", "Artifact fields must be a JSON object"),
        else => return serverError(ctx),
    };
    const source_ids_json = rawField(ctx.allocator, obj, "source_ids", "[]") catch return serverError(ctx);
    if (!sourceIdsCanBackRecord(ctx, source_ids_json, scope, permissions_json)) return forbidden(ctx);
    const artifact = ctx.store.createArtifact(ctx.allocator, .{
        .artifact_type = artifact_type,
        .title = title,
        .body = json.stringField(obj, "body") orelse "",
        .status = status,
        .owner = json.nullableStringField(obj, "owner"),
        .space_id = json.nullableStringField(obj, "space_id"),
        .scope = scope,
        .source_ids_json = source_ids_json,
        .related_entities_json = rawField(ctx.allocator, obj, "related_entities", "[]") catch return serverError(ctx),
        .permissions_json = permissions_json,
        .fields_json = fields_json,
        .summary = json.nullableStringField(obj, "summary"),
        .agent_summary = json.nullableStringField(obj, "agent_summary"),
        .actor_id = ctx.actor_id,
        .storage_route = storage_route,
    }) catch |err| switch (err) {
        error.AgentMemoryStorageUnavailable => return agentMemoryStorageUnavailable(ctx),
        else => return serverError(ctx),
    };
    _ = upsertAutoVector(ctx, "artifact", artifact.id, artifact.body, artifact.scope, artifact.permissions_json) catch 0;
    return artifactResponse(ctx, artifact);
}

fn getArtifact(ctx: *Context, id: []const u8) HttpResponse {
    if (!hasCapability(ctx, "read")) return forbidden(ctx);
    const artifact = ctx.store.getArtifact(ctx.allocator, id) catch return serverError(ctx);
    if (artifact == null) return json.errorResponse(ctx.allocator, 404, "not_found", "Artifact not found");
    if (!recordVisibleToActor(ctx, artifact.?.scope, artifact.?.permissions_json)) return json.errorResponse(ctx.allocator, 404, "not_found", "Artifact not found");
    return artifactResponse(ctx, artifact.?);
}

fn resolveEntity(ctx: *Context, body: []const u8) HttpResponse {
    if (!hasCapability(ctx, "write") and !hasCapability(ctx, "propose")) return forbidden(ctx);
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const name = json.stringField(obj, "name") orelse return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing name");
    const scope = json.stringField(obj, "scope") orelse "workspace";
    const permissions_json = rawField(ctx.allocator, obj, "permissions", "[]") catch return serverError(ctx);
    const storage_route = agentMemoryStorageTargetFromObject(ctx.allocator, obj) catch return serverError(ctx);
    if (!canWriteRecord(ctx, scope, permissions_json)) return forbidden(ctx);
    const entity = ctx.store.resolveEntity(ctx.allocator, .{
        .entity_type = json.stringField(obj, "type") orelse "concept",
        .name = name,
        .aliases_json = rawField(ctx.allocator, obj, "aliases", "[]") catch return serverError(ctx),
        .description = json.nullableStringField(obj, "description"),
        .canonical_artifact_id = json.nullableStringField(obj, "canonical_artifact_id"),
        .scope = scope,
        .permissions_json = permissions_json,
        .metadata_json = rawField(ctx.allocator, obj, "metadata", "{}") catch return serverError(ctx),
        .actor_id = ctx.actor_id,
        .storage_route = storage_route,
    }) catch |err| switch (err) {
        error.AgentMemoryStorageUnavailable => return agentMemoryStorageUnavailable(ctx),
        else => return serverError(ctx),
    };
    const text = vector_text.entity(ctx.allocator, entity) catch return serverError(ctx);
    _ = upsertAutoVector(ctx, "entity", entity.id, text, entity.scope, entity.permissions_json) catch 0;
    return objectResponse(ctx, "entity", entity);
}

fn createRelation(ctx: *Context, body: []const u8) HttpResponse {
    if (!hasCapability(ctx, "write") and !hasCapability(ctx, "propose")) return forbidden(ctx);
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const from_entity_id = json.stringField(obj, "from_entity_id") orelse return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing from_entity_id");
    const to_entity_id = json.stringField(obj, "to_entity_id") orelse return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing to_entity_id");
    const source_ids_json = rawField(ctx.allocator, obj, "source_ids", "[]") catch return serverError(ctx);
    const scope = json.stringField(obj, "scope") orelse "workspace";
    const permissions_json = rawField(ctx.allocator, obj, "permissions", "[]") catch return serverError(ctx);
    const storage_route = agentMemoryStorageTargetFromObject(ctx.allocator, obj) catch return serverError(ctx);
    if (!canWriteRecord(ctx, scope, permissions_json)) return forbidden(ctx);
    if (!sourceIdsCanBackRecord(ctx, source_ids_json, scope, permissions_json)) return forbidden(ctx);
    if (!entityCanBackRecord(ctx, from_entity_id, scope, permissions_json)) return forbidden(ctx);
    if (!entityCanBackRecord(ctx, to_entity_id, scope, permissions_json)) return forbidden(ctx);
    const relation = ctx.store.createRelation(ctx.allocator, .{
        .from_entity_id = from_entity_id,
        .relation_type = json.stringField(obj, "relation_type") orelse "related_to",
        .to_entity_id = to_entity_id,
        .source_ids_json = source_ids_json,
        .scope = scope,
        .permissions_json = permissions_json,
        .confidence = json.floatField(obj, "confidence") orelse 0.5,
        .status = json.stringField(obj, "status") orelse "proposed",
        .actor_id = ctx.actor_id,
        .storage_route = storage_route,
    }) catch |err| switch (err) {
        error.EntityNotFound => return json.errorResponse(ctx.allocator, 400, "bad_request", "Relation endpoints must reference existing entities"),
        error.RelationAclBroaderThanEntity => return json.errorResponse(ctx.allocator, 400, "bad_request", "Relation ACL cannot be broader than endpoint entity ACL"),
        error.InvalidRelationSchema => return json.errorResponse(ctx.allocator, 400, "bad_request", "Relation type is not valid for the endpoint entity types"),
        error.AgentMemoryStorageUnavailable => return agentMemoryStorageUnavailable(ctx),
        else => return serverError(ctx),
    };
    const text = vector_text.relation(ctx.allocator, relation) catch return serverError(ctx);
    _ = upsertAutoVector(ctx, "relation", relation.id, text, relation.scope, relation.permissions_json) catch 0;
    return objectResponse(ctx, "relation", relation);
}

fn getEntity(ctx: *Context, id: []const u8) HttpResponse {
    if (!hasCapability(ctx, "read")) return forbidden(ctx);
    const entity = (ctx.store.getEntity(ctx.allocator, id) catch return serverError(ctx)) orelse return json.errorResponse(ctx.allocator, 404, "not_found", "Entity not found");
    if (!recordVisibleToActor(ctx, entity.scope, entity.permissions_json)) return json.errorResponse(ctx.allocator, 404, "not_found", "Entity not found");
    return entityResponse(ctx, entity);
}

fn patchEntity(ctx: *Context, id: []const u8, body: []const u8) HttpResponse {
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const status = json.stringField(parsed.value.object, "status") orelse return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing status");
    const entity = (ctx.store.getEntity(ctx.allocator, id) catch return serverError(ctx)) orelse return json.errorResponse(ctx.allocator, 404, "not_found", "Entity not found");
    if (!recordVisibleToActor(ctx, entity.scope, entity.permissions_json)) return json.errorResponse(ctx.allocator, 404, "not_found", "Entity not found");
    if (!canChangeGraphPrimitiveStatus(ctx, entity.scope, entity.permissions_json, status)) return forbidden(ctx);
    const payload_json = rawField(ctx.allocator, parsed.value.object, "payload", "{}") catch return badJson(ctx);
    const changed = ctx.store.patchPrimitiveLifecycleActor(ctx.allocator, "entity", id, status, ctx.actor_id, payload_json) catch return serverError(ctx);
    if (!changed) return json.errorResponse(ctx.allocator, 404, "not_found", "Entity not found");
    return entityResponse(ctx, entity);
}

fn deleteEntity(ctx: *Context, id: []const u8) HttpResponse {
    if (!hasCapability(ctx, "delete")) return forbidden(ctx);
    const entity = (ctx.store.getEntity(ctx.allocator, id) catch return serverError(ctx)) orelse return json.errorResponse(ctx.allocator, 404, "not_found", "Entity not found");
    if (!recordVisibleToActor(ctx, entity.scope, entity.permissions_json)) return json.errorResponse(ctx.allocator, 404, "not_found", "Entity not found");
    if (!canChangeGraphPrimitiveStatus(ctx, entity.scope, entity.permissions_json, "deprecated")) return forbidden(ctx);
    const changed = ctx.store.patchPrimitiveLifecycleActor(ctx.allocator, "entity", id, "deprecated", ctx.actor_id, "{\"deleted\":true}") catch return serverError(ctx);
    if (!changed) return json.errorResponse(ctx.allocator, 404, "not_found", "Entity not found");
    return ok(ctx, "{\"ok\":true,\"status\":\"deprecated\"}");
}

fn getRelation(ctx: *Context, id: []const u8) HttpResponse {
    if (!hasCapability(ctx, "read")) return forbidden(ctx);
    const relation = (ctx.store.getRelation(ctx.allocator, id) catch return serverError(ctx)) orelse return json.errorResponse(ctx.allocator, 404, "not_found", "Relation not found");
    const visible = visibleGraphRelation(ctx, relation, true) catch return serverError(ctx);
    if (visible == null) return json.errorResponse(ctx.allocator, 404, "not_found", "Relation not found");
    return relationResponse(ctx, visible.?.relation);
}

fn patchRelation(ctx: *Context, id: []const u8, body: []const u8) HttpResponse {
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const status = json.stringField(parsed.value.object, "status") orelse return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing status");
    const relation = (ctx.store.getRelation(ctx.allocator, id) catch return serverError(ctx)) orelse return json.errorResponse(ctx.allocator, 404, "not_found", "Relation not found");
    const visible = visibleGraphRelation(ctx, relation, true) catch return serverError(ctx);
    if (visible == null) return json.errorResponse(ctx.allocator, 404, "not_found", "Relation not found");
    if (!canChangeGraphPrimitiveStatus(ctx, relation.scope, relation.permissions_json, status)) return forbidden(ctx);
    const changed = ctx.store.patchRelationStatusActor(id, status, ctx.actor_id) catch return serverError(ctx);
    if (!changed) return json.errorResponse(ctx.allocator, 404, "not_found", "Relation not found");
    const updated = (ctx.store.getRelation(ctx.allocator, id) catch return serverError(ctx)) orelse return json.errorResponse(ctx.allocator, 404, "not_found", "Relation not found");
    return relationResponse(ctx, updated);
}

fn deleteRelation(ctx: *Context, id: []const u8) HttpResponse {
    if (!hasCapability(ctx, "delete")) return forbidden(ctx);
    const relation = (ctx.store.getRelation(ctx.allocator, id) catch return serverError(ctx)) orelse return json.errorResponse(ctx.allocator, 404, "not_found", "Relation not found");
    const visible = visibleGraphRelation(ctx, relation, true) catch return serverError(ctx);
    if (visible == null) return json.errorResponse(ctx.allocator, 404, "not_found", "Relation not found");
    if (!canChangeGraphPrimitiveStatus(ctx, relation.scope, relation.permissions_json, "deprecated")) return forbidden(ctx);
    const changed = ctx.store.patchRelationStatusActor(id, "deprecated", ctx.actor_id) catch return serverError(ctx);
    if (!changed) return json.errorResponse(ctx.allocator, 404, "not_found", "Relation not found");
    return ok(ctx, "{\"ok\":true,\"status\":\"deprecated\"}");
}

fn graphSchema(ctx: *Context) HttpResponse {
    if (!hasCapability(ctx, "read")) return forbidden(ctx);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    graph_mod.appendSchemaJson(ctx.allocator, &out) catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn graphNeighbors(ctx: *Context, body: []const u8) HttpResponse {
    if (!hasCapability(ctx, "read")) return forbidden(ctx);
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const entity_id = json.stringField(obj, "entity_id") orelse return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing entity_id");
    const options = graphTraversalOptions(ctx, obj) catch |err| switch (err) {
        error.InvalidGraphDirection, error.InvalidGraphFilter => return badJson(ctx),
        else => return serverError(ctx),
    };
    const depth = graphDepth(json.intField(obj, "depth"));
    const limit = positiveLimit(json.intField(obj, "limit"), 50);
    const root = (ctx.store.getEntity(ctx.allocator, entity_id) catch return serverError(ctx)) orelse return json.errorResponse(ctx.allocator, 404, "not_found", "Entity not found");
    const root_visible = visibleGraphEntity(ctx, root, options.include_deprecated) catch return serverError(ctx);
    if (!root_visible) return json.errorResponse(ctx.allocator, 404, "not_found", "Entity not found");

    var entities: std.ArrayListUnmanaged(domain.Entity) = .empty;
    var relations: std.ArrayListUnmanaged(domain.Relation) = .empty;
    var frontier: std.ArrayListUnmanaged([]const u8) = .empty;
    entities.append(ctx.allocator, root) catch return serverError(ctx);
    frontier.append(ctx.allocator, root.id) catch return serverError(ctx);

    var current_depth: usize = 0;
    while (current_depth < depth and frontier.items.len > 0 and relations.items.len < limit) : (current_depth += 1) {
        var next: std.ArrayListUnmanaged([]const u8) = .empty;
        for (frontier.items) |current_entity_id| {
            const raw_relations = ctx.store.listEntityRelations(ctx.allocator, current_entity_id, limit) catch return serverError(ctx);
            for (raw_relations) |relation| {
                const visible = visibleGraphRelation(ctx, relation, options.include_deprecated) catch return serverError(ctx);
                if (visible == null) continue;
                if (!graphRelationAllowed(visible.?.relation, options)) continue;
                if (relationInList(relations.items, relation.id)) continue;
                const other = otherEntityForTraversal(visible.?, current_entity_id, options) orelse continue;
                relations.append(ctx.allocator, visible.?.relation) catch return serverError(ctx);
                if (!entityInList(entities.items, other.id)) {
                    entities.append(ctx.allocator, other) catch return serverError(ctx);
                    if (!stringInList(next.items, other.id)) next.append(ctx.allocator, other.id) catch return serverError(ctx);
                }
                if (relations.items.len >= limit) break;
            }
            if (relations.items.len >= limit) break;
        }
        frontier = next;
    }

    return graphNeighborsResponse(ctx, root, entities.items, relations.items, depth, limit);
}

fn graphQuery(ctx: *Context, body: []const u8) HttpResponse {
    if (!hasCapability(ctx, "read")) return forbidden(ctx);
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const root_ids = graphRootEntityIds(ctx, obj) catch return badJson(ctx);
    if (root_ids.len == 0) return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing entity_id or entity_ids");
    const options = graphTraversalOptions(ctx, obj) catch |err| switch (err) {
        error.InvalidGraphDirection, error.InvalidGraphFilter => return badJson(ctx),
        else => return serverError(ctx),
    };
    const depth = graphDepth(json.intField(obj, "depth"));
    const limit = positiveLimit(json.intField(obj, "limit"), 50);

    var roots: std.ArrayListUnmanaged(domain.Entity) = .empty;
    var entities: std.ArrayListUnmanaged(domain.Entity) = .empty;
    var relations: std.ArrayListUnmanaged(domain.Relation) = .empty;
    var frontier: std.ArrayListUnmanaged([]const u8) = .empty;
    for (root_ids) |entity_id| {
        const entity = (ctx.store.getEntity(ctx.allocator, entity_id) catch return serverError(ctx)) orelse continue;
        const entity_visible = visibleGraphEntity(ctx, entity, options.include_deprecated) catch return serverError(ctx);
        if (!entity_visible) continue;
        if (!graph_mod.entityMatchesTypeFilter(entity.entity_type, options.entity_types)) continue;
        if (!entityInList(entities.items, entity.id)) entities.append(ctx.allocator, entity) catch return serverError(ctx);
        if (!entityInList(roots.items, entity.id)) roots.append(ctx.allocator, entity) catch return serverError(ctx);
        if (!stringInList(frontier.items, entity.id)) frontier.append(ctx.allocator, entity.id) catch return serverError(ctx);
    }
    if (roots.items.len == 0) return json.errorResponse(ctx.allocator, 404, "not_found", "No visible root entities found");

    var current_depth: usize = 0;
    while (current_depth < depth and frontier.items.len > 0 and relations.items.len < limit) : (current_depth += 1) {
        var next: std.ArrayListUnmanaged([]const u8) = .empty;
        for (frontier.items) |current_entity_id| {
            const raw_relations = ctx.store.listEntityRelations(ctx.allocator, current_entity_id, limit) catch return serverError(ctx);
            for (raw_relations) |relation| {
                const visible = visibleGraphRelation(ctx, relation, options.include_deprecated) catch return serverError(ctx);
                if (visible == null) continue;
                if (!graphRelationAllowed(visible.?.relation, options)) continue;
                if (relationInList(relations.items, relation.id)) continue;
                const other = otherEntityForTraversal(visible.?, current_entity_id, options) orelse continue;
                relations.append(ctx.allocator, visible.?.relation) catch return serverError(ctx);
                if (!entityInList(entities.items, other.id)) {
                    entities.append(ctx.allocator, other) catch return serverError(ctx);
                    if (!stringInList(next.items, other.id)) next.append(ctx.allocator, other.id) catch return serverError(ctx);
                }
                if (relations.items.len >= limit) break;
            }
            if (relations.items.len >= limit) break;
        }
        frontier = next;
    }

    return graphQueryResponse(ctx, roots.items, entities.items, relations.items, options, depth, limit);
}

fn graphPath(ctx: *Context, body: []const u8) HttpResponse {
    if (!hasCapability(ctx, "read")) return forbidden(ctx);
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const from_entity_id = json.stringField(obj, "from_entity_id") orelse return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing from_entity_id");
    const to_entity_id = json.stringField(obj, "to_entity_id") orelse return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing to_entity_id");
    const options = graphTraversalOptions(ctx, obj) catch |err| switch (err) {
        error.InvalidGraphDirection, error.InvalidGraphFilter => return badJson(ctx),
        else => return serverError(ctx),
    };
    const max_depth = graphDepth(json.intField(obj, "max_depth"));
    const limit = positiveLimit(json.intField(obj, "limit"), 100);

    const from = (ctx.store.getEntity(ctx.allocator, from_entity_id) catch return serverError(ctx)) orelse return json.errorResponse(ctx.allocator, 404, "not_found", "From entity not found");
    const to = (ctx.store.getEntity(ctx.allocator, to_entity_id) catch return serverError(ctx)) orelse return json.errorResponse(ctx.allocator, 404, "not_found", "To entity not found");
    const from_visible = visibleGraphEntity(ctx, from, options.include_deprecated) catch return serverError(ctx);
    const to_visible = visibleGraphEntity(ctx, to, options.include_deprecated) catch return serverError(ctx);
    if (!from_visible) return json.errorResponse(ctx.allocator, 404, "not_found", "From entity not found");
    if (!to_visible) return json.errorResponse(ctx.allocator, 404, "not_found", "To entity not found");
    if (!graph_mod.entityMatchesTypeFilter(from.entity_type, options.entity_types) or !graph_mod.entityMatchesTypeFilter(to.entity_type, options.entity_types)) return graphPathNotFoundResponse(ctx, from.id, to.id, max_depth);

    var parents: std.ArrayListUnmanaged(GraphParent) = .empty;
    var frontier: std.ArrayListUnmanaged([]const u8) = .empty;
    parents.append(ctx.allocator, .{ .entity_id = from.id }) catch return serverError(ctx);
    frontier.append(ctx.allocator, from.id) catch return serverError(ctx);
    var found = std.mem.eql(u8, from.id, to.id);

    search: for (0..max_depth) |_| {
        if (found or frontier.items.len == 0 or parents.items.len >= limit) break;
        var next: std.ArrayListUnmanaged([]const u8) = .empty;
        for (frontier.items) |current_entity_id| {
            const raw_relations = ctx.store.listEntityRelations(ctx.allocator, current_entity_id, limit) catch return serverError(ctx);
            for (raw_relations) |relation| {
                const visible = visibleGraphRelation(ctx, relation, options.include_deprecated) catch return serverError(ctx);
                if (visible == null) continue;
                if (!graphRelationAllowed(visible.?.relation, options)) continue;
                const other = otherEntityForTraversal(visible.?, current_entity_id, options) orelse continue;
                if (parentIndex(parents.items, other.id) != null) continue;
                parents.append(ctx.allocator, .{ .entity_id = other.id, .previous_entity_id = current_entity_id, .relation_id = visible.?.relation.id }) catch return serverError(ctx);
                if (std.mem.eql(u8, other.id, to.id)) {
                    found = true;
                    break :search;
                }
                next.append(ctx.allocator, other.id) catch return serverError(ctx);
                if (parents.items.len >= limit) break :search;
            }
        }
        frontier = next;
    }

    if (!found) return graphPathNotFoundResponse(ctx, from.id, to.id, max_depth);
    return graphPathFoundResponse(ctx, parents.items, from.id, to.id, max_depth);
}

const VisibleGraphRelation = struct {
    relation: domain.Relation,
    from: domain.Entity,
    to: domain.Entity,
};

const GraphParent = struct {
    entity_id: []const u8,
    previous_entity_id: ?[]const u8 = null,
    relation_id: ?[]const u8 = null,
};

const GraphTraversalOptions = struct {
    direction: graph_mod.Direction = .both,
    relation_types: []const []const u8 = &[_][]const u8{},
    entity_types: []const []const u8 = &[_][]const u8{},
    min_confidence: f64 = 0,
    include_deprecated: bool = false,
};

fn graphTraversalOptions(ctx: *Context, obj: std.json.ObjectMap) !GraphTraversalOptions {
    return .{
        .direction = try graph_mod.parseDirection(json.stringField(obj, "direction")),
        .relation_types = try graphStringListField(ctx.allocator, obj, "relation_types", "relation_type"),
        .entity_types = try graphStringListField(ctx.allocator, obj, "entity_types", "entity_type"),
        .min_confidence = json.floatField(obj, "min_confidence") orelse 0,
        .include_deprecated = json.boolField(obj, "include_deprecated") orelse false,
    };
}

fn graphRootEntityIds(ctx: *Context, obj: std.json.ObjectMap) ![]const []const u8 {
    if (json.stringField(obj, "entity_id")) |entity_id| {
        const out = try ctx.allocator.alloc([]const u8, 1);
        out[0] = entity_id;
        return out;
    }
    return graphStringListField(ctx.allocator, obj, "entity_ids", "ids");
}

fn graphStringListField(allocator: std.mem.Allocator, obj: std.json.ObjectMap, array_name: []const u8, singular_name: []const u8) ![]const []const u8 {
    if (obj.get(array_name)) |value| return graphStringListFromValue(allocator, value);
    if (json.stringField(obj, singular_name)) |single| {
        const out = try allocator.alloc([]const u8, 1);
        out[0] = single;
        return out;
    }
    return &[_][]const u8{};
}

fn graphStringListFromValue(allocator: std.mem.Allocator, value: std.json.Value) ![]const []const u8 {
    return switch (value) {
        .string => |single| blk: {
            const out = try allocator.alloc([]const u8, 1);
            out[0] = single;
            break :blk out;
        },
        .array => |items| blk: {
            var out = try allocator.alloc([]const u8, items.items.len);
            var count: usize = 0;
            for (items.items) |item| {
                if (item != .string) return error.InvalidGraphFilter;
                out[count] = item.string;
                count += 1;
            }
            break :blk out[0..count];
        },
        else => error.InvalidGraphFilter,
    };
}

fn graphRelationAllowed(relation: domain.Relation, options: GraphTraversalOptions) bool {
    if (relation.confidence < options.min_confidence) return false;
    return graph_mod.relationMatchesTypeFilter(relation.relation_type, options.relation_types);
}

fn visibleGraphEntity(ctx: *Context, entity: domain.Entity, include_deprecated: bool) !bool {
    if (!recordVisibleToActor(ctx, entity.scope, entity.permissions_json)) return false;
    if (include_deprecated) return true;
    const status = try ctx.store.primitiveLifecycleStatus(ctx.allocator, "entity", entity.id);
    return domain.isDefaultVisibleStatus(status);
}

fn visibleGraphRelation(ctx: *Context, relation: domain.Relation, include_deprecated: bool) !?VisibleGraphRelation {
    if (!include_deprecated and !domain.isDefaultVisibleStatus(relation.status)) return null;
    if (!recordVisibleToActor(ctx, relation.scope, relation.permissions_json)) return null;
    const from = (try ctx.store.getEntity(ctx.allocator, relation.from_entity_id)) orelse return null;
    const to = (try ctx.store.getEntity(ctx.allocator, relation.to_entity_id)) orelse return null;
    if (!try visibleGraphEntity(ctx, from, include_deprecated)) return null;
    if (!try visibleGraphEntity(ctx, to, include_deprecated)) return null;
    return .{ .relation = relation, .from = from, .to = to };
}

fn otherEntityForTraversal(visible: VisibleGraphRelation, current_entity_id: []const u8, options: GraphTraversalOptions) ?domain.Entity {
    const direction = if (graph_mod.relationTypeSpec(visible.relation.relation_type)) |spec|
        if (spec.directed) options.direction else graph_mod.Direction.both
    else
        options.direction;
    const other_id = graph_mod.otherEntityIdForDirection(visible.relation.from_entity_id, visible.relation.to_entity_id, current_entity_id, direction) orelse return null;
    const other = if (std.mem.eql(u8, visible.from.id, other_id)) visible.from else if (std.mem.eql(u8, visible.to.id, other_id)) visible.to else return null;
    if (!graph_mod.entityMatchesTypeFilter(other.entity_type, options.entity_types)) return null;
    return other;
}

fn graphDepth(value: ?i64) usize {
    const raw = value orelse return 1;
    if (raw <= 0) return 1;
    return @intCast(@min(raw, 6));
}

fn entityInList(items: []const domain.Entity, id: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item.id, id)) return true;
    }
    return false;
}

fn relationInList(items: []const domain.Relation, id: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item.id, id)) return true;
    }
    return false;
}

fn stringInList(items: []const []const u8, id: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item, id)) return true;
    }
    return false;
}

fn parentIndex(items: []const GraphParent, id: []const u8) ?usize {
    for (items, 0..) |item, i| {
        if (std.mem.eql(u8, item.entity_id, id)) return i;
    }
    return null;
}

fn graphNeighborsResponse(ctx: *Context, root: domain.Entity, entities: []const domain.Entity, relations: []const domain.Relation, depth: usize, limit: usize) HttpResponse {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ctx.allocator, "{\"root\":") catch return serverError(ctx);
    root.writeJson(ctx.allocator, &out) catch return serverError(ctx);
    out.print(ctx.allocator, ",\"depth\":{d},\"limit\":{d},\"entities\":[", .{ depth, limit }) catch return serverError(ctx);
    appendGraphEntities(ctx, &out, entities) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, "],\"relations\":[") catch return serverError(ctx);
    appendGraphRelations(ctx, &out, relations) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, "]}") catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn graphQueryResponse(ctx: *Context, roots: []const domain.Entity, entities: []const domain.Entity, relations: []const domain.Relation, options: GraphTraversalOptions, depth: usize, limit: usize) HttpResponse {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ctx.allocator, "{\"roots\":[") catch return serverError(ctx);
    appendGraphEntities(ctx, &out, roots) catch return serverError(ctx);
    out.print(ctx.allocator, "],\"depth\":{d},\"limit\":{d},\"direction\":", .{ depth, limit }) catch return serverError(ctx);
    json.appendString(&out, ctx.allocator, graph_mod.directionName(options.direction)) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"relation_types\":[") catch return serverError(ctx);
    appendStringList(ctx, &out, options.relation_types) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, "],\"entity_types\":[") catch return serverError(ctx);
    appendStringList(ctx, &out, options.entity_types) catch return serverError(ctx);
    out.print(ctx.allocator, "],\"min_confidence\":{d},\"entities\":[", .{options.min_confidence}) catch return serverError(ctx);
    appendGraphEntities(ctx, &out, entities) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, "],\"relations\":[") catch return serverError(ctx);
    appendGraphRelations(ctx, &out, relations) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, "]}") catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn appendStringList(ctx: *Context, out: *std.ArrayListUnmanaged(u8), values: []const []const u8) !void {
    for (values, 0..) |value, i| {
        if (i > 0) try out.append(ctx.allocator, ',');
        try json.appendString(out, ctx.allocator, value);
    }
}

fn graphPathNotFoundResponse(ctx: *Context, from_entity_id: []const u8, to_entity_id: []const u8, max_depth: usize) HttpResponse {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ctx.allocator, "{\"found\":false,\"from_entity_id\":") catch return serverError(ctx);
    json.appendString(&out, ctx.allocator, from_entity_id) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"to_entity_id\":") catch return serverError(ctx);
    json.appendString(&out, ctx.allocator, to_entity_id) catch return serverError(ctx);
    out.print(ctx.allocator, ",\"max_depth\":{d}}}", .{max_depth}) catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn graphPathFoundResponse(ctx: *Context, parents: []const GraphParent, from_entity_id: []const u8, to_entity_id: []const u8, max_depth: usize) HttpResponse {
    var entity_ids_rev: std.ArrayListUnmanaged([]const u8) = .empty;
    var relation_ids_rev: std.ArrayListUnmanaged([]const u8) = .empty;
    var current = to_entity_id;
    while (true) {
        entity_ids_rev.append(ctx.allocator, current) catch return serverError(ctx);
        const idx = parentIndex(parents, current) orelse break;
        const parent = parents[idx];
        if (parent.previous_entity_id == null) break;
        if (parent.relation_id) |relation_id| relation_ids_rev.append(ctx.allocator, relation_id) catch return serverError(ctx);
        current = parent.previous_entity_id.?;
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ctx.allocator, "{\"found\":true,\"from_entity_id\":") catch return serverError(ctx);
    json.appendString(&out, ctx.allocator, from_entity_id) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"to_entity_id\":") catch return serverError(ctx);
    json.appendString(&out, ctx.allocator, to_entity_id) catch return serverError(ctx);
    out.print(ctx.allocator, ",\"max_depth\":{d},\"entity_ids\":[", .{max_depth}) catch return serverError(ctx);
    appendReversedStringIds(ctx, &out, entity_ids_rev.items) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, "],\"relation_ids\":[") catch return serverError(ctx);
    appendReversedStringIds(ctx, &out, relation_ids_rev.items) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, "],\"entities\":[") catch return serverError(ctx);
    appendPathEntities(ctx, &out, entity_ids_rev.items) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, "],\"relations\":[") catch return serverError(ctx);
    appendPathRelations(ctx, &out, relation_ids_rev.items) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, "]}") catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn appendGraphEntities(ctx: *Context, out: *std.ArrayListUnmanaged(u8), entities: []const domain.Entity) !void {
    for (entities, 0..) |entity, i| {
        if (i > 0) try out.append(ctx.allocator, ',');
        try entity.writeJson(ctx.allocator, out);
    }
}

fn appendGraphRelations(ctx: *Context, out: *std.ArrayListUnmanaged(u8), relations: []const domain.Relation) !void {
    for (relations, 0..) |relation, i| {
        if (i > 0) try out.append(ctx.allocator, ',');
        try appendRelationForActor(ctx, out, relation);
    }
}

fn appendRelationForActor(ctx: *Context, out: *std.ArrayListUnmanaged(u8), relation: domain.Relation) !void {
    var copy = relation;
    copy.source_ids_json = try sanitizeSourceIdsForActor(ctx, relation.source_ids_json);
    try copy.writeJson(ctx.allocator, out);
}

fn appendReversedStringIds(ctx: *Context, out: *std.ArrayListUnmanaged(u8), ids_list: []const []const u8) !void {
    var first = true;
    var i = ids_list.len;
    while (i > 0) {
        i -= 1;
        if (!first) try out.append(ctx.allocator, ',');
        first = false;
        try json.appendString(out, ctx.allocator, ids_list[i]);
    }
}

fn appendPathEntities(ctx: *Context, out: *std.ArrayListUnmanaged(u8), entity_ids_rev: []const []const u8) !void {
    var first = true;
    var i = entity_ids_rev.len;
    while (i > 0) {
        i -= 1;
        const entity = (try ctx.store.getEntity(ctx.allocator, entity_ids_rev[i])) orelse continue;
        if (!recordVisibleToActor(ctx, entity.scope, entity.permissions_json)) continue;
        if (!first) try out.append(ctx.allocator, ',');
        first = false;
        try entity.writeJson(ctx.allocator, out);
    }
}

fn appendPathRelations(ctx: *Context, out: *std.ArrayListUnmanaged(u8), relation_ids_rev: []const []const u8) !void {
    var first = true;
    var i = relation_ids_rev.len;
    while (i > 0) {
        i -= 1;
        const relation = (try ctx.store.getRelation(ctx.allocator, relation_ids_rev[i])) orelse continue;
        const visible = try visibleGraphRelation(ctx, relation, true);
        if (visible == null) continue;
        if (!first) try out.append(ctx.allocator, ',');
        first = false;
        try appendRelationForActor(ctx, out, visible.?.relation);
    }
}

fn relationResponse(ctx: *Context, relation: domain.Relation) HttpResponse {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ctx.allocator, "{\"relation\":") catch return serverError(ctx);
    appendRelationForActor(ctx, &out, relation) catch return serverError(ctx);
    out.append(ctx.allocator, '}') catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn entityResponse(ctx: *Context, entity: domain.Entity) HttpResponse {
    const status = ctx.store.primitiveLifecycleStatus(ctx.allocator, "entity", entity.id) catch return serverError(ctx);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ctx.allocator, "{\"entity\":") catch return serverError(ctx);
    entity.writeJson(ctx.allocator, &out) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"status\":") catch return serverError(ctx);
    json.appendString(&out, ctx.allocator, status) catch return serverError(ctx);
    out.append(ctx.allocator, '}') catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn engineRegistry(ctx: *Context) HttpResponse {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ctx.allocator, "{\"engines\":") catch return serverError(ctx);
    engines.appendDescriptorsJson(ctx.allocator, &out) catch return serverError(ctx);
    out.append(ctx.allocator, '}') catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

const OpenApiPath = struct {
    path: []const u8,
    get: ?[]const u8 = null,
    post: ?[]const u8 = null,
    put: ?[]const u8 = null,
    patch: ?[]const u8 = null,
    delete: ?[]const u8 = null,
};

fn openApiDocument(ctx: *Context) HttpResponse {
    const paths = [_]OpenApiPath{
        .{ .path = "/engines", .get = "listEngines" },
        .{ .path = "/providers", .get = "listProviders" },
        .{ .path = "/connectors", .get = "listConnectors" },
        .{ .path = "/connectors/{name}/cursor", .get = "connectorGetCursor", .post = "connectorUpsertCursor" },
        .{ .path = "/connectors/{name}/ingest", .post = "connectorIngest" },
        .{ .path = "/markdown/import", .post = "importMarkdown" },
        .{ .path = "/markdown/import-directory", .post = "importMarkdownDirectory" },
        .{ .path = "/markdown/export", .post = "exportMarkdown" },
        .{ .path = "/markdown/export-directory", .post = "exportMarkdownDirectory" },
        .{ .path = "/artifact-types", .get = "listArtifactTypes" },
        .{ .path = "/sdk/manifest", .get = "sdkManifest" },
        .{ .path = "/spaces", .get = "listSpaces", .post = "createSpace" },
        .{ .path = "/spaces/{id}", .get = "getSpace" },
        .{ .path = "/policy-scopes", .get = "listPolicyScopes", .post = "upsertPolicyScope" },
        .{ .path = "/policy-scopes/{scope}", .get = "getPolicyScope" },
        .{ .path = "/agent-memory", .get = "listAgentMemory", .post = "putAgentMemory" },
        .{ .path = "/agent-memory/{key}", .get = "getAgentMemory", .put = "putAgentMemoryByKey", .post = "putAgentMemoryByKey", .delete = "deleteAgentMemory" },
        .{ .path = "/agent-memory/search", .post = "searchAgentMemory" },
        .{ .path = "/agent-memory/count", .get = "countAgentMemory" },
        .{ .path = "/agent-sessions", .get = "listAgentSessions" },
        .{ .path = "/agent-sessions/{id}", .get = "getAgentSessionHistory" },
        .{ .path = "/agent-sessions/{id}/messages", .get = "loadAgentSessionMessages", .post = "saveAgentSessionMessage", .delete = "clearAgentSessionMessages" },
        .{ .path = "/agent-sessions/{id}/usage", .get = "loadAgentSessionUsage", .put = "saveAgentSessionUsage", .delete = "deleteAgentSessionUsage" },
        .{ .path = "/agent-sessions/auto-saved", .delete = "clearAgentAutoSavedMessages" },
        .{ .path = "/sources", .post = "createSource" },
        .{ .path = "/sources/{id}", .get = "getSource" },
        .{ .path = "/artifacts", .post = "createArtifact" },
        .{ .path = "/artifacts/{id}", .get = "getArtifact" },
        .{ .path = "/memory-atoms", .post = "createMemoryAtom" },
        .{ .path = "/memory-atoms/{id}", .patch = "patchMemoryAtom" },
        .{ .path = "/entities/resolve", .post = "resolveEntity" },
        .{ .path = "/entities/{id}", .get = "getEntity", .patch = "patchEntity", .delete = "deleteEntity" },
        .{ .path = "/relations", .post = "createRelation" },
        .{ .path = "/relations/{id}", .get = "getRelation", .patch = "patchRelation", .delete = "deleteRelation" },
        .{ .path = "/graph/schema", .get = "graphSchema" },
        .{ .path = "/graph/query", .post = "graphQuery" },
        .{ .path = "/graph/neighbors", .post = "graphNeighbors" },
        .{ .path = "/graph/path", .post = "graphPath" },
        .{ .path = "/ingest", .post = "ingest" },
        .{ .path = "/extract-memory", .post = "extractMemory" },
        .{ .path = "/search", .post = "search" },
        .{ .path = "/ask", .post = "ask" },
        .{ .path = "/context-packs", .post = "createContextPack" },
        .{ .path = "/remember", .post = "remember" },
        .{ .path = "/forget", .post = "forget" },
        .{ .path = "/verify", .post = "verify" },
        .{ .path = "/mark-stale", .post = "markStale" },
        .{ .path = "/jobs", .get = "listJobs", .post = "createJob" },
        .{ .path = "/jobs/{id}/run", .post = "runJob" },
        .{ .path = "/workers/run", .post = "runWorkers" },
        .{ .path = "/memory/feed", .get = "listFeed", .post = "appendFeed" },
        .{ .path = "/memory/events", .get = "listFeedEvents", .post = "appendFeedEvent" },
        .{ .path = "/memory/status", .get = "feedStatus" },
        .{ .path = "/memory/compact", .post = "compactFeed" },
        .{ .path = "/memory/checkpoint", .get = "exportFeedCheckpoint", .post = "restoreFeedCheckpoint" },
        .{ .path = "/memory/apply", .post = "applyFeedEvent" },
        .{ .path = "/vector/status", .get = "vectorStatus" },
        .{ .path = "/vector/embed", .post = "embed" },
        .{ .path = "/vector/upsert", .post = "upsertVectorChunk" },
        .{ .path = "/vector/search", .post = "vectorSearch" },
        .{ .path = "/vector/delete", .post = "deleteVectorChunk" },
        .{ .path = "/vector/rebuild", .post = "rebuildVectorIndex" },
        .{ .path = "/vector/reconcile", .post = "reconcileVectorIndex" },
        .{ .path = "/vector/outbox", .get = "vectorOutboxStatus" },
        .{ .path = "/vector/outbox/run", .post = "runVectorOutbox" },
        .{ .path = "/retrieval/plan", .post = "retrievalPlan" },
        .{ .path = "/retrieval/search", .post = "retrievalSearch" },
        .{ .path = "/conflicts", .get = "listConflicts" },
        .{ .path = "/conflicts/scan", .post = "scanConflicts" },
        .{ .path = "/lifecycle/diagnostics", .get = "diagnostics" },
        .{ .path = "/lifecycle/snapshot", .post = "createSnapshot" },
        .{ .path = "/lifecycle/snapshot/export", .post = "exportSnapshot" },
        .{ .path = "/lifecycle/snapshot/import", .post = "importSnapshot" },
        .{ .path = "/lifecycle/lucid/status", .get = "lucidProjectionStatus" },
        .{ .path = "/lifecycle/lucid/rebuild", .post = "rebuildLucidProjection" },
        .{ .path = "/lifecycle/analytics/status", .get = "analyticsStatus" },
        .{ .path = "/lifecycle/analytics/query", .post = "queryAnalytics" },
        .{ .path = "/lifecycle/analytics/export", .post = "exportAnalytics" },
        .{ .path = "/lifecycle/cache/put", .post = "putResponseCache" },
        .{ .path = "/lifecycle/cache/get", .post = "getResponseCache" },
        .{ .path = "/lifecycle/semantic-cache/put", .post = "putSemanticCache" },
        .{ .path = "/lifecycle/semantic-cache/search", .post = "searchSemanticCache" },
        .{ .path = "/lifecycle/hygiene", .post = "runHygiene" },
        .{ .path = "/lifecycle/summarize", .post = "summarize" },
        .{ .path = "/lifecycle/rollout", .post = "rollout" },
    };

    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ctx.allocator,
        \\{"openapi":"3.1.0","info":{"title":"NullPantry API","version":"v1","description":"Headless agent-native knowledge base and central memory service for the Null ecosystem."},"servers":[{"url":"/v1"}],"security":[{"bearerAuth":[]}],"components":{"securitySchemes":{"bearerAuth":{"type":"http","scheme":"bearer"}},"schemas":{"Error":{"type":"object","required":["error"],"properties":{"error":{"type":"string"},"message":{"type":"string"}}},"SourceCreate":{"type":"object","required":["title"],"properties":{"type":{"type":"string","default":"manual"},"title":{"type":"string"},"content":{"type":"string"},"scope":{"type":"string","default":"workspace"},"permissions":{"type":"array","items":{"type":"string"}},"metadata":{"type":"object"}}},"MemoryAtomCreate":{"type":"object","required":["text"],"properties":{"text":{"type":"string"},"scope":{"type":"string"},"confidence":{"type":"number"},"status":{"enum":["proposed","verified","rejected","stale","deprecated","superseded"]},"source_ids":{"type":"array","items":{"type":"string"}},"evidence_ranges":{"type":"array","items":{"type":"object"}}}},"AgentMemoryEntry":{"type":"object","required":["key","content","actor_id","owner_id","created_by_actor_id","scope"],"properties":{"key":{"type":"string"},"content":{"type":"string"},"category":{"type":"string"},"session_id":{"type":["string","null"]},"actor_id":{"type":"string","description":"Logical memory owner; shared scoped rows use shared:<scope>."},"owner_id":{"type":"string"},"created_by_actor_id":{"type":"string","description":"Actual actor that last wrote this memory row."},"scope":{"type":"string"},"permissions":{"type":"array","items":{"type":"string"}},"timestamp":{"type":"string"},"score":{"type":"number"}}},"SearchRequest":{"type":"object","properties":{"query":{"type":"string"},"limit":{"type":"integer","minimum":1,"maximum":100},"scopes":{"type":"array","items":{"type":"string"}},"include_deprecated":{"type":"boolean"},"use_vector":{"type":"boolean"},"allow_reranker":{"type":"boolean"}}},"ConnectorCursor":{"type":"object","required":["connector","scope","cursor"],"properties":{"connector":{"type":"string"},"scope":{"type":"string"},"cursor":{"type":"string"},"config":{"type":"object"},"permissions":{"type":"array","items":{"type":"string"}},"updated_at_ms":{"type":"integer"}}},"ConnectorIngestRequest":{"type":"object","properties":{"items":{"type":"array","items":{"$ref":"#/components/schemas/SourceCreate"}},"run_now":{"type":"boolean"},"scope":{"type":"string"},"permissions":{"type":"array","items":{"type":"string"}},"next_cursor":{"type":"string"},"cursor":{"type":"string"},"config":{"type":"object"}}}}},"paths":{
    ) catch return serverError(ctx);
    for (paths, 0..) |path, i| {
        if (i > 0) out.append(ctx.allocator, ',') catch return serverError(ctx);
        appendOpenApiPath(ctx.allocator, &out, path) catch return serverError(ctx);
    }
    out.appendSlice(ctx.allocator, "}}") catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn appendOpenApiPath(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), path: OpenApiPath) !void {
    try json.appendString(out, allocator, path.path);
    try out.appendSlice(allocator, ":{");
    var count: usize = 0;
    try appendOpenApiOperation(allocator, out, &count, "get", path.get);
    try appendOpenApiOperation(allocator, out, &count, "post", path.post);
    try appendOpenApiOperation(allocator, out, &count, "put", path.put);
    try appendOpenApiOperation(allocator, out, &count, "patch", path.patch);
    try appendOpenApiOperation(allocator, out, &count, "delete", path.delete);
    try out.append(allocator, '}');
}

fn appendOpenApiOperation(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), count: *usize, method: []const u8, operation_id: ?[]const u8) !void {
    const op = operation_id orelse return;
    if (count.* > 0) try out.append(allocator, ',');
    try json.appendString(out, allocator, method);
    try out.appendSlice(allocator, ":{\"operationId\":");
    try json.appendString(out, allocator, op);
    try out.appendSlice(allocator, ",\"responses\":{\"200\":{\"description\":\"OK\"}}}");
    count.* += 1;
}

fn capabilities(ctx: *Context) HttpResponse {
    return ok(ctx,
        \\{"service":"nullpantry","headless":true,"product":["knowledge_base","long_term_memory","rag","knowledge_graph","context_serving_api"],"consumers":["agents","nullhub","nulldesk"],"primitives":["source","artifact","memory_atom","entity","relation","context_pack","agent_memory","space","policy_scope"],"content_types":["page","spec","decision","runbook","recipe","meeting_note","research","incident_report","memory_item"],"storage":["sqlite","postgres-libpq-runtime"],"agent_memory_backends":["none","native","memory_lru","redis-resp-runtime","api-http-runtime"],"agent_memory_routing":["primary","native","runtime","named","subset","all"],"knowledge_storage_routing":["canonical","runtime_mirror","named","subset","all"],"vector_backends":["local","postgres-pgvector","qdrant-http-runtime","lancedb-sdk-runtime","lancedb-http-runtime"],"projection_backends":["lucid-cli-runtime"],"analytics_backends":["clickhouse-http-runtime"],"apis":["agent_memory","agent_sessions","named_agent_memory_stores","remember","search","ask","get_context_pack","create_source","create_space","upsert_policy_scope","extract_memory","create_decision","link","forget","verify","mark_stale","ingest","connector_ingest","connector_cursor","markdown_import","markdown_import_directory","markdown_export","markdown_export_directory","graph_schema","graph_query","graph_neighbors","graph_path","jobs","workers","conflicts","memory_feed","memory_status","memory_compact","memory_checkpoint","vector_status","vector_embed","vector_upsert","vector_search","vector_delete","vector_rebuild","vector_reconcile","vector_outbox","snapshot_export","snapshot_import","lucid_projection_status","lucid_projection_rebuild","analytics_export","analytics_status","analytics_query"],"providers":["local-deterministic","openai-compatible-embeddings","gemini-embeddings","voyage-embeddings","embedding-fallback-chain","openai-compatible-chat","ollama-compatible"],"retrieval":["acl","fts","vector","entity_graph","graph_schema","graph_query","graph_neighbors","graph_path","named_runtime_memory","lucid_projection","rrf","temporal_decay","quality_rerank","embedding_mmr","llm_rerank","citations","conflict_warnings"],"permissions":["read","write","propose","verify","delete","export","feed_apply"],"auth":["single_bearer_token","token_principal_registry","request_scope_narrowing"]}
    );
}

fn providerRegistry(ctx: *Context) HttpResponse {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ctx.allocator, "{\"providers\":") catch return serverError(ctx);
    providers.appendProvidersJson(ctx.allocator, &out) catch return serverError(ctx);
    out.append(ctx.allocator, '}') catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn connectors(ctx: *Context) HttpResponse {
    return ok(ctx,
        \\{"connectors":[{"name":"manual","status":"built_in","source_types":["manual","text"],"ingest":"POST /v1/connectors/manual/ingest","cursor":"GET|POST /v1/connectors/manual/cursor"},{"name":"markdown","status":"built_in_filesystem_import_export","source_types":["markdown","md"],"ingest":"POST /v1/connectors/markdown/ingest","import":"POST /v1/markdown/import","import_directory":"POST /v1/markdown/import-directory","export":"POST /v1/markdown/export","export_directory":"POST /v1/markdown/export-directory","cursor":"GET|POST /v1/connectors/markdown/cursor"},{"name":"transcript","status":"built_in","source_types":["transcript","chat"],"ingest":"POST /v1/connectors/transcript/ingest","cursor":"GET|POST /v1/connectors/transcript/cursor"},{"name":"ticket","status":"built_in_push","source_types":["ticket","issue"],"ingest":"POST /v1/connectors/ticket/ingest","cursor":"GET|POST /v1/connectors/ticket/cursor"},{"name":"git","status":"built_in_push","source_types":["pr","commit","repo"],"ingest":"POST /v1/connectors/git/ingest","cursor":"GET|POST /v1/connectors/git/cursor"},{"name":"incident","status":"built_in_push","source_types":["incident"],"ingest":"POST /v1/connectors/incident/ingest","cursor":"GET|POST /v1/connectors/incident/cursor"},{"name":"nulltickets","status":"built_in_push","source_types":["ticket","issue"],"ingest":"POST /v1/connectors/nulltickets/ingest","cursor":"GET|POST /v1/connectors/nulltickets/cursor"},{"name":"nullwatch","status":"built_in_push","source_types":["incident"],"ingest":"POST /v1/connectors/nullwatch/ingest","cursor":"GET|POST /v1/connectors/nullwatch/cursor"},{"name":"nullhub","status":"consumer"}]}
    );
}

fn connectorCursorGet(ctx: *Context, connector: []const u8, query: []const u8) HttpResponse {
    const decoded_scope = json.queryParamDecoded(ctx.allocator, query, "scope") catch return serverError(ctx);
    const scope = if (decoded_scope) |value| value else "workspace";
    const cursor = ctx.store.getConnectorCursor(ctx.allocator, connector, scope) catch return serverError(ctx);
    const loaded = cursor orelse return json.errorResponse(ctx.allocator, 404, "not_found", "Connector cursor not found");
    if (!recordVisibleToActor(ctx, loaded.scope, loaded.permissions_json)) return forbidden(ctx);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ctx.allocator, "{\"cursor\":") catch return serverError(ctx);
    loaded.writeJson(ctx.allocator, &out) catch return serverError(ctx);
    out.append(ctx.allocator, '}') catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn connectorCursorUpsert(ctx: *Context, connector: []const u8, body: []const u8) HttpResponse {
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const scope = json.stringField(obj, "scope") orelse "workspace";
    const permissions_json = rawField(ctx.allocator, obj, "permissions", "[]") catch return badJson(ctx);
    if (!canWriteRecord(ctx, scope, permissions_json)) return forbidden(ctx);
    const cursor_value = json.stringField(obj, "cursor") orelse json.stringField(obj, "next_cursor") orelse "";
    const config_json = rawField(ctx.allocator, obj, "config", "{}") catch return badJson(ctx);
    const cursor = ctx.store.upsertConnectorCursor(ctx.allocator, .{
        .connector = connector,
        .scope = scope,
        .cursor = cursor_value,
        .config_json = config_json,
        .permissions_json = permissions_json,
        .actor_id = ctx.actor_id,
    }) catch return serverError(ctx);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ctx.allocator, "{\"cursor\":") catch return serverError(ctx);
    cursor.writeJson(ctx.allocator, &out) catch return serverError(ctx);
    out.append(ctx.allocator, '}') catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn connectorIngest(ctx: *Context, connector: []const u8, body: []const u8) HttpResponse {
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const default_scope = json.stringField(obj, "scope") orelse "workspace";
    const default_permissions = rawField(ctx.allocator, obj, "permissions", "[]") catch return serverError(ctx);
    const run_now = json.boolField(obj, "run_now") orelse false;
    const cursor_input = connectorCursorInputFromIngest(ctx, connector, obj, default_scope, default_permissions) catch |err| switch (err) {
        error.Forbidden => return forbidden(ctx),
        error.InvalidPayload => return badJson(ctx),
    };

    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ctx.allocator, "{\"connector\":") catch return serverError(ctx);
    json.appendString(&out, ctx.allocator, connector) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"sources\":[") catch return serverError(ctx);

    var count: usize = 0;
    if (obj.get("items")) |items_value| {
        if (items_value != .array) return json.errorResponse(ctx.allocator, 400, "bad_request", "items must be an array");
        for (items_value.array.items) |item| {
            if (item != .object) return json.errorResponse(ctx.allocator, 400, "bad_request", "connector item must be an object");
            const source = connectorIngestOne(ctx, connector, item.object, default_scope, default_permissions) catch |err| switch (err) {
                error.Forbidden => return forbidden(ctx),
                error.InvalidPayload => return badJson(ctx),
                else => return serverError(ctx),
            };
            if (count > 0) out.append(ctx.allocator, ',') catch return serverError(ctx);
            source.writeJson(ctx.allocator, &out) catch return serverError(ctx);
            if (run_now) {
                _ = runExtraction(ctx, source, extractionOptionsFromObject(ctx, item.object, true, true) catch return serverError(ctx)) catch return serverError(ctx);
            } else {
                _ = ctx.store.createJob(ctx.allocator, .{ .job_type = "ingest", .scope = source.scope, .permissions_json = source.permissions_json, .object_type = "source", .object_id = source.id, .input_json = body, .actor_id = ctx.actor_id }) catch return serverError(ctx);
            }
            count += 1;
        }
    } else {
        const source = connectorIngestOne(ctx, connector, obj, default_scope, default_permissions) catch |err| switch (err) {
            error.Forbidden => return forbidden(ctx),
            error.InvalidPayload => return badJson(ctx),
            else => return serverError(ctx),
        };
        source.writeJson(ctx.allocator, &out) catch return serverError(ctx);
        if (run_now) {
            _ = runExtraction(ctx, source, extractionOptionsFromObject(ctx, obj, true, true) catch return serverError(ctx)) catch return serverError(ctx);
        } else {
            _ = ctx.store.createJob(ctx.allocator, .{ .job_type = "ingest", .scope = source.scope, .permissions_json = source.permissions_json, .object_type = "source", .object_id = source.id, .input_json = body, .actor_id = ctx.actor_id }) catch return serverError(ctx);
        }
        count = 1;
    }

    out.print(ctx.allocator, "],\"count\":{d},\"run_now\":", .{count}) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, if (run_now) "true" else "false") catch return serverError(ctx);
    if (cursor_input) |input| {
        const cursor = ctx.store.upsertConnectorCursor(ctx.allocator, input) catch return serverError(ctx);
        out.appendSlice(ctx.allocator, ",\"cursor\":") catch return serverError(ctx);
        cursor.writeJson(ctx.allocator, &out) catch return serverError(ctx);
    }
    out.append(ctx.allocator, '}') catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn connectorCursorInputFromIngest(ctx: *Context, connector: []const u8, obj: std.json.ObjectMap, default_scope: []const u8, default_permissions: []const u8) !?store_mod.ConnectorCursorInput {
    const cursor_value = json.stringField(obj, "next_cursor") orelse json.stringField(obj, "cursor") orelse return null;
    const scope = json.stringField(obj, "cursor_scope") orelse default_scope;
    const permissions_json = rawField(ctx.allocator, obj, "cursor_permissions", default_permissions) catch return error.InvalidPayload;
    if (!canWriteRecord(ctx, scope, permissions_json)) return error.Forbidden;
    return .{
        .connector = connector,
        .scope = scope,
        .cursor = cursor_value,
        .config_json = rawField(ctx.allocator, obj, "config", "{}") catch return error.InvalidPayload,
        .permissions_json = permissions_json,
        .actor_id = ctx.actor_id,
    };
}

fn connectorIngestOne(ctx: *Context, connector: []const u8, obj: std.json.ObjectMap, default_scope: []const u8, default_permissions: []const u8) !domain.Source {
    const scope = json.stringField(obj, "scope") orelse default_scope;
    const permissions_json = rawField(ctx.allocator, obj, "permissions", default_permissions) catch return error.InvalidPayload;
    if (!canProposeRecord(ctx, scope, permissions_json)) return error.Forbidden;
    const title = json.stringField(obj, "title") orelse json.stringField(obj, "key") orelse connector;
    const metadata_json = rawField(ctx.allocator, obj, "metadata", "{}") catch return error.InvalidPayload;
    return try ctx.store.createSource(ctx.allocator, .{
        .source_type = json.stringField(obj, "type") orelse connectorDefaultSourceType(connector),
        .title = title,
        .raw_content_uri = json.nullableStringField(obj, "raw_content_uri"),
        .content = json.stringField(obj, "content") orelse json.stringField(obj, "body") orelse "",
        .author = json.nullableStringField(obj, "author"),
        .participants_json = rawField(ctx.allocator, obj, "participants", "[]") catch return error.InvalidPayload,
        .permissions_json = permissions_json,
        .scope = scope,
        .checksum = json.nullableStringField(obj, "checksum"),
        .language = json.nullableStringField(obj, "language"),
        .related_entities_json = rawField(ctx.allocator, obj, "related_entities", "[]") catch return error.InvalidPayload,
        .metadata_json = try connectorMetadataJson(ctx.allocator, connector, metadata_json),
        .actor_id = ctx.actor_id,
        .storage_route = try agentMemoryStorageTargetFromObject(ctx.allocator, obj),
    });
}

fn connectorDefaultSourceType(connector: []const u8) []const u8 {
    if (std.mem.eql(u8, connector, "ticket") or std.mem.eql(u8, connector, "nulltickets")) return "ticket";
    if (std.mem.eql(u8, connector, "git")) return "pr";
    if (std.mem.eql(u8, connector, "incident") or std.mem.eql(u8, connector, "nullwatch")) return "incident";
    if (std.mem.eql(u8, connector, "transcript")) return "transcript";
    if (std.mem.eql(u8, connector, "markdown")) return "markdown";
    return "manual";
}

fn connectorMetadataJson(allocator: std.mem.Allocator, connector: []const u8, metadata_json: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.appendSlice(allocator, "{\"connector\":");
    try json.appendString(&out, allocator, connector);
    try out.appendSlice(allocator, ",\"metadata\":");
    try json.appendRawJsonOr(&out, allocator, metadata_json, "{}");
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

fn markdownImport(ctx: *Context, body: []const u8) HttpResponse {
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const content = json.stringField(obj, "content") orelse return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing content");
    const default_scope = json.stringField(obj, "scope") orelse "workspace";
    const default_permissions = rawField(ctx.allocator, obj, "permissions", "[]") catch return serverError(ctx);
    const fallback_title = json.stringField(obj, "title") orelse "Markdown import";

    const imported = markdown_adapter.parseImport(ctx.allocator, content, fallback_title, default_scope, default_permissions) catch return badJson(ctx);
    defer imported.deinit(ctx.allocator);
    const created = createMarkdownObjects(ctx, obj, imported, content, imported.path, firstNonNullString(json.nullableStringField(obj, "checksum"), imported.checksum)) catch |err| switch (err) {
        error.InvalidArtifactStatus => return json.errorResponse(ctx.allocator, 400, "bad_request", "Invalid artifact status for this artifact type"),
        error.Forbidden => return forbidden(ctx),
        error.AgentMemoryStorageUnavailable => return agentMemoryStorageUnavailable(ctx),
        else => return serverError(ctx),
    };
    const source = created.source;
    const artifact = created.artifact;

    const run_now = json.boolField(obj, "run_now") orelse false;
    if (!run_now) {
        const job_input = markdownExtractionJobInputJson(ctx.allocator, json.boolField(obj, "extract_memory") orelse true, json.boolField(obj, "use_llm_extraction") orelse json.boolField(obj, "structured_extraction") orelse false, json.boolField(obj, "strict_llm_extraction") orelse false, agentMemoryStorageTargetFromObject(ctx.allocator, obj) catch return agentMemoryStorageUnavailable(ctx)) catch return serverError(ctx);
        const job = ctx.store.createJob(ctx.allocator, .{
            .job_type = "extract_memory",
            .scope = source.scope,
            .permissions_json = source.permissions_json,
            .object_type = "source",
            .object_id = source.id,
            .input_json = job_input,
            .actor_id = ctx.actor_id,
        }) catch return serverError(ctx);
        return markdownImportQueuedResponse(ctx, job, source, artifact);
    }

    var output = runExtraction(ctx, source, extractionOptionsFromObject(ctx, obj, false, json.boolField(obj, "extract_memory") orelse true) catch return serverError(ctx)) catch |err| {
        return json.errorResponse(ctx.allocator, 500, "internal_error", @errorName(err));
    };
    output.artifact = artifact;
    output.vector_chunks += upsertAutoVector(ctx, "artifact", artifact.id, artifact.body, artifact.scope, artifact.permissions_json) catch 0;
    return markdownImportResponse(ctx, source, artifact, output);
}

fn markdownExport(ctx: *Context, body: []const u8) HttpResponse {
    if (!hasCapability(ctx, "export")) return forbidden(ctx);
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    if (json.stringField(obj, "artifact_id")) |artifact_id| {
        const artifact = (ctx.store.getArtifact(ctx.allocator, artifact_id) catch return serverError(ctx)) orelse return json.errorResponse(ctx.allocator, 404, "not_found", "Artifact not found");
        if (!recordVisibleToActor(ctx, artifact.scope, artifact.permissions_json)) return forbidden(ctx);
        var markdown: std.ArrayListUnmanaged(u8) = .empty;
        markdown_adapter.appendArtifactMarkdown(ctx.allocator, &markdown, artifact) catch return serverError(ctx);
        out.appendSlice(ctx.allocator, "{\"object_type\":\"artifact\",\"object_id\":") catch return serverError(ctx);
        json.appendString(&out, ctx.allocator, artifact.id) catch return serverError(ctx);
        out.appendSlice(ctx.allocator, ",\"markdown\":") catch return serverError(ctx);
        json.appendString(&out, ctx.allocator, markdown.items) catch return serverError(ctx);
        out.append(ctx.allocator, '}') catch return serverError(ctx);
        return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
    }

    if (json.stringField(obj, "source_id")) |source_id| {
        const source = (ctx.store.getSource(ctx.allocator, source_id) catch return serverError(ctx)) orelse return json.errorResponse(ctx.allocator, 404, "not_found", "Source not found");
        if (!recordVisibleToActor(ctx, source.scope, source.permissions_json)) return forbidden(ctx);
        var markdown: std.ArrayListUnmanaged(u8) = .empty;
        markdown_adapter.appendSourceMarkdown(ctx.allocator, &markdown, source) catch return serverError(ctx);
        out.appendSlice(ctx.allocator, "{\"object_type\":\"source\",\"object_id\":") catch return serverError(ctx);
        json.appendString(&out, ctx.allocator, source.id) catch return serverError(ctx);
        out.appendSlice(ctx.allocator, ",\"markdown\":") catch return serverError(ctx);
        json.appendString(&out, ctx.allocator, markdown.items) catch return serverError(ctx);
        out.append(ctx.allocator, '}') catch return serverError(ctx);
        return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
    }

    return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing artifact_id or source_id");
}

fn markdownImportDirectory(ctx: *Context, body: []const u8) HttpResponse {
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const root_path = json.stringField(obj, "path") orelse json.stringField(obj, "directory") orelse return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing path");
    if (root_path.len == 0) return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing path");

    const default_scope = json.stringField(obj, "scope") orelse "workspace";
    const default_permissions = rawField(ctx.allocator, obj, "permissions", "[]") catch return serverError(ctx);
    const max_files = positiveBounded(json.intField(obj, "max_files"), 1000, 10000);
    const max_file_bytes = positiveBounded(json.intField(obj, "max_file_bytes"), 20 * 1024 * 1024, 100 * 1024 * 1024);
    const queue_extraction = json.boolField(obj, "queue_extraction") orelse true;
    const run_now = json.boolField(obj, "run_now") orelse false;
    const extract_memory = json.boolField(obj, "extract_memory") orelse true;
    const skip_unchanged = json.boolField(obj, "skip_unchanged") orelse true;

    const discovered = markdown_filesystem.readDirectory(ctx.allocator, root_path, max_files, max_file_bytes) catch |err| switch (err) {
        error.FileNotFound => return json.errorResponse(ctx.allocator, 404, "not_found", "Markdown directory not found"),
        error.NotDir => return json.errorResponse(ctx.allocator, 400, "bad_request", "Path is not a directory"),
        error.StreamTooLong => return json.errorResponse(ctx.allocator, 413, "payload_too_large", "Markdown file exceeds max_file_bytes"),
        else => return serverError(ctx),
    };
    defer markdown_filesystem.deinitDirectoryReadResult(ctx.allocator, discovered);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ctx.allocator, "{\"path\":") catch return serverError(ctx);
    json.appendString(&out, ctx.allocator, root_path) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"files\":[") catch return serverError(ctx);

    var imported_count: usize = 0;
    const skipped_count: usize = discovered.skipped;
    var jobs_queued: usize = 0;
    var atoms_extracted: usize = 0;
    var vector_chunks: usize = 0;
    var unchanged_count: usize = 0;
    var first_file = true;
    for (discovered.files) |file| {
        const imported = markdown_adapter.parseImport(ctx.allocator, file.content, file.fallback_title, default_scope, default_permissions) catch return badJson(ctx);
        defer imported.deinit(ctx.allocator);

        if (skip_unchanged) {
            if (ctx.store.findSourceByRawContentUri(ctx.allocator, file.path, imported.scope) catch return serverError(ctx)) |existing| {
                if (stringMatchesOptional(existing.checksum, file.checksum)) {
                    unchanged_count += 1;
                    continue;
                }
            }
        }

        const created = createMarkdownObjects(ctx, obj, imported, file.content, file.path, file.checksum) catch |err| switch (err) {
            error.InvalidArtifactStatus => return json.errorResponse(ctx.allocator, 400, "bad_request", "Invalid artifact status for this artifact type"),
            error.Forbidden => return forbidden(ctx),
            error.AgentMemoryStorageUnavailable => return agentMemoryStorageUnavailable(ctx),
            else => return serverError(ctx),
        };

        var file_atoms: usize = 0;
        var file_vector_chunks: usize = 0;
        var queued = false;
        if (run_now) {
            var output = runExtraction(ctx, created.source, extractionOptionsFromObject(ctx, obj, false, extract_memory) catch return serverError(ctx)) catch |err| {
                return json.errorResponse(ctx.allocator, 500, "internal_error", @errorName(err));
            };
            output.artifact = created.artifact;
            file_atoms = output.atoms.len;
            file_vector_chunks = upsertAutoVector(ctx, "artifact", created.artifact.id, created.artifact.body, created.artifact.scope, created.artifact.permissions_json) catch 0;
            atoms_extracted += file_atoms;
            vector_chunks += file_vector_chunks;
        } else if (queue_extraction and extract_memory) {
            queueMarkdownExtractionJob(ctx, obj, created.source) catch return serverError(ctx);
            jobs_queued += 1;
            queued = true;
        }

        if (!first_file) out.append(ctx.allocator, ',') catch return serverError(ctx);
        first_file = false;
        appendMarkdownDirectoryImportFile(ctx, &out, file.path, created.source, created.artifact, queued, file_atoms, file_vector_chunks) catch return serverError(ctx);
        imported_count += 1;
    }

    out.print(ctx.allocator, "],\"imported\":{d},\"unchanged\":{d},\"skipped\":{d},\"jobs_queued\":{d},\"atoms_extracted\":{d},\"vector_chunks\":{d}}}", .{ imported_count, unchanged_count, skipped_count, jobs_queued, atoms_extracted, vector_chunks }) catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn markdownExportDirectory(ctx: *Context, body: []const u8) HttpResponse {
    if (!hasCapability(ctx, "export")) return forbidden(ctx);
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const root_path = json.stringField(obj, "path") orelse json.stringField(obj, "directory") orelse return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing path");
    if (root_path.len == 0) return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing path");
    const overwrite = json.boolField(obj, "overwrite") orelse false;

    std.Io.Dir.cwd().createDirPath(compat.io(), root_path) catch return serverError(ctx);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ctx.allocator, "{\"path\":") catch return serverError(ctx);
    json.appendString(&out, ctx.allocator, root_path) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"files\":[") catch return serverError(ctx);

    var exported_count: usize = 0;
    var first_file = true;
    if (obj.get("artifact_ids")) |value| {
        if (value != .array) return json.errorResponse(ctx.allocator, 400, "bad_request", "artifact_ids must be an array");
        for (value.array.items) |id_value| {
            if (id_value != .string) continue;
            const artifact = (ctx.store.getArtifact(ctx.allocator, id_value.string) catch return serverError(ctx)) orelse return json.errorResponse(ctx.allocator, 404, "not_found", "Artifact not found");
            if (!recordVisibleToActor(ctx, artifact.scope, artifact.permissions_json)) return forbidden(ctx);
            var markdown: std.ArrayListUnmanaged(u8) = .empty;
            markdown_adapter.appendArtifactMarkdown(ctx.allocator, &markdown, artifact) catch return serverError(ctx);
            const filename = markdown_adapter.exportFileName(ctx.allocator, artifact.title, artifact.id, "artifact") catch return serverError(ctx);
            const file_path = std.fs.path.join(ctx.allocator, &.{ root_path, filename }) catch return serverError(ctx);
            markdown_filesystem.writeFile(file_path, markdown.items, overwrite) catch |err| switch (err) {
                error.PathAlreadyExists => return json.errorResponse(ctx.allocator, 409, "conflict", "Markdown export target already exists"),
                else => return serverError(ctx),
            };
            if (!first_file) out.append(ctx.allocator, ',') catch return serverError(ctx);
            first_file = false;
            appendMarkdownDirectoryExportFile(ctx, &out, file_path, "artifact", artifact.id) catch return serverError(ctx);
            exported_count += 1;
        }
    }

    if (obj.get("source_ids")) |value| {
        if (value != .array) return json.errorResponse(ctx.allocator, 400, "bad_request", "source_ids must be an array");
        for (value.array.items) |id_value| {
            if (id_value != .string) continue;
            const source = (ctx.store.getSource(ctx.allocator, id_value.string) catch return serverError(ctx)) orelse return json.errorResponse(ctx.allocator, 404, "not_found", "Source not found");
            if (!recordVisibleToActor(ctx, source.scope, source.permissions_json)) return forbidden(ctx);
            var markdown: std.ArrayListUnmanaged(u8) = .empty;
            markdown_adapter.appendSourceMarkdown(ctx.allocator, &markdown, source) catch return serverError(ctx);
            const filename = markdown_adapter.exportFileName(ctx.allocator, source.title, source.id, "source") catch return serverError(ctx);
            const file_path = std.fs.path.join(ctx.allocator, &.{ root_path, filename }) catch return serverError(ctx);
            markdown_filesystem.writeFile(file_path, markdown.items, overwrite) catch |err| switch (err) {
                error.PathAlreadyExists => return json.errorResponse(ctx.allocator, 409, "conflict", "Markdown export target already exists"),
                else => return serverError(ctx),
            };
            if (!first_file) out.append(ctx.allocator, ',') catch return serverError(ctx);
            first_file = false;
            appendMarkdownDirectoryExportFile(ctx, &out, file_path, "source", source.id) catch return serverError(ctx);
            exported_count += 1;
        }
    }

    if (exported_count == 0) return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing artifact_ids or source_ids");
    out.print(ctx.allocator, "],\"exported\":{d},\"overwrite\":{s}}}", .{ exported_count, if (overwrite) "true" else "false" }) catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

const MarkdownCreated = struct {
    source: domain.Source,
    artifact: domain.Artifact,
};

fn createMarkdownObjects(
    ctx: *Context,
    obj: std.json.ObjectMap,
    imported: markdown_adapter.ParsedMarkdown,
    content: []const u8,
    file_path: ?[]const u8,
    checksum: ?[]const u8,
) !MarkdownCreated {
    if (!artifacts.validStatus(imported.artifact_type, imported.status)) return error.InvalidArtifactStatus;
    if (!canProposeRecord(ctx, imported.scope, imported.permissions_json)) return error.Forbidden;
    if (!markdownStatusCanBeProposed(imported.status) and !canWriteRecord(ctx, imported.scope, imported.permissions_json)) return error.Forbidden;

    const storage_route = try agentMemoryStorageTargetFromObject(ctx.allocator, obj);
    const related_entities_json = if (jsonArrayIsEmpty(imported.related_entities_json))
        try extraction.extractEntityNamesJson(ctx.allocator, imported.body)
    else
        imported.related_entities_json;
    const source_checksum = firstNonNullString(checksum, imported.checksum);
    const source_path = firstNonNullString(file_path, imported.path);
    const metadata_json = try markdownImportMetadataJson(ctx.allocator, imported.metadata_json, source_path, source_checksum);

    const source = try ctx.store.createSource(ctx.allocator, .{
        .source_type = imported.source_type,
        .title = imported.title,
        .raw_content_uri = firstNonNullString(source_path, firstNonNullString(imported.raw_content_uri, json.nullableStringField(obj, "raw_content_uri"))),
        .content = content,
        .author = firstNonNullString(imported.author, json.nullableStringField(obj, "author")),
        .participants_json = try rawField(ctx.allocator, obj, "participants", "[]"),
        .permissions_json = imported.permissions_json,
        .scope = imported.scope,
        .checksum = source_checksum,
        .language = json.nullableStringField(obj, "language") orelse "markdown",
        .related_entities_json = related_entities_json,
        .metadata_json = metadata_json,
        .actor_id = ctx.actor_id,
        .storage_route = storage_route,
    });

    const actual_source_ids_json = try extraction.sourceIdsJson(ctx.allocator, source.id);
    const artifact = try ctx.store.createArtifact(ctx.allocator, .{
        .artifact_type = imported.artifact_type,
        .title = imported.title,
        .body = imported.body,
        .status = imported.status,
        .owner = firstNonNullString(imported.owner, firstNonNullString(imported.author, firstNonNullString(json.nullableStringField(obj, "owner"), json.nullableStringField(obj, "author")))),
        .space_id = firstNonNullString(imported.space_id, json.nullableStringField(obj, "space_id")),
        .scope = imported.scope,
        .source_ids_json = actual_source_ids_json,
        .related_entities_json = related_entities_json,
        .permissions_json = imported.permissions_json,
        .fields_json = imported.fields_json,
        .summary = try extraction.summarize(ctx.allocator, imported.body, 512),
        .agent_summary = try extraction.summarize(ctx.allocator, imported.body, 1024),
        .actor_id = ctx.actor_id,
        .storage_route = storage_route,
    });

    return .{ .source = source, .artifact = artifact };
}

fn markdownStatusCanBeProposed(status: []const u8) bool {
    return std.mem.eql(u8, status, "draft") or std.mem.eql(u8, status, "proposed");
}

fn firstNonNullString(primary: ?[]const u8, fallback: ?[]const u8) ?[]const u8 {
    if (primary) |value| return value;
    return fallback;
}

fn stringMatchesOptional(value: ?[]const u8, expected: []const u8) bool {
    return if (value) |actual| std.mem.eql(u8, actual, expected) else false;
}

fn markdownImportMetadataJson(allocator: std.mem.Allocator, metadata_json: []const u8, file_path: ?[]const u8, checksum: ?[]const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.appendSlice(allocator, "{\"connector\":\"markdown\",\"metadata\":");
    try json.appendRawJsonOr(&out, allocator, metadata_json, "{}");
    if (file_path) |value| {
        try out.appendSlice(allocator, ",\"path\":");
        try json.appendString(&out, allocator, value);
    }
    if (checksum) |value| {
        try out.appendSlice(allocator, ",\"checksum\":");
        try json.appendString(&out, allocator, value);
    }
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

fn jsonArrayIsEmpty(raw: []const u8) bool {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    return trimmed.len == 0 or std.mem.eql(u8, trimmed, "[]");
}

fn appendMarkdownDirectoryImportFile(
    ctx: *Context,
    out: *std.ArrayListUnmanaged(u8),
    path: []const u8,
    source: domain.Source,
    artifact: domain.Artifact,
    job_queued: bool,
    atoms_extracted: usize,
    vector_chunks: usize,
) !void {
    try out.appendSlice(ctx.allocator, "{\"path\":");
    try json.appendString(out, ctx.allocator, path);
    try out.appendSlice(ctx.allocator, ",\"source_id\":");
    try json.appendString(out, ctx.allocator, source.id);
    try out.appendSlice(ctx.allocator, ",\"artifact_id\":");
    try json.appendString(out, ctx.allocator, artifact.id);
    try out.appendSlice(ctx.allocator, ",\"artifact_type\":");
    try json.appendString(out, ctx.allocator, artifact.artifact_type);
    try out.appendSlice(ctx.allocator, ",\"scope\":");
    try json.appendString(out, ctx.allocator, artifact.scope);
    try out.print(ctx.allocator, ",\"job_queued\":{s},\"atoms_extracted\":{d},\"vector_chunks\":{d}}}", .{ if (job_queued) "true" else "false", atoms_extracted, vector_chunks });
}

fn appendMarkdownDirectoryExportFile(
    ctx: *Context,
    out: *std.ArrayListUnmanaged(u8),
    path: []const u8,
    object_type: []const u8,
    object_id: []const u8,
) !void {
    try out.appendSlice(ctx.allocator, "{\"path\":");
    try json.appendString(out, ctx.allocator, path);
    try out.appendSlice(ctx.allocator, ",\"object_type\":");
    try json.appendString(out, ctx.allocator, object_type);
    try out.appendSlice(ctx.allocator, ",\"object_id\":");
    try json.appendString(out, ctx.allocator, object_id);
    try out.append(ctx.allocator, '}');
}

fn queueMarkdownExtractionJob(ctx: *Context, obj: std.json.ObjectMap, source: domain.Source) !void {
    const job_input = try markdownExtractionJobInputJson(
        ctx.allocator,
        json.boolField(obj, "extract_memory") orelse true,
        json.boolField(obj, "use_llm_extraction") orelse json.boolField(obj, "structured_extraction") orelse false,
        json.boolField(obj, "strict_llm_extraction") orelse false,
        try agentMemoryStorageTargetFromObject(ctx.allocator, obj),
    );
    _ = try ctx.store.createJob(ctx.allocator, .{
        .job_type = "extract_memory",
        .scope = source.scope,
        .permissions_json = source.permissions_json,
        .object_type = "source",
        .object_id = source.id,
        .input_json = job_input,
        .actor_id = ctx.actor_id,
    });
}

fn positiveBounded(value: ?i64, default_value: usize, max_value: usize) usize {
    const raw = value orelse return default_value;
    if (raw <= 0) return default_value;
    return @intCast(@min(raw, @as(i64, @intCast(max_value))));
}

fn markdownExtractionJobInputJson(allocator: std.mem.Allocator, extract_memory: bool, use_llm_extraction: bool, strict_llm_extraction: bool, route: store_mod.AgentMemoryStorageRoute) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"create_artifact\":false,\"extract_memory\":");
    try out.appendSlice(allocator, if (extract_memory) "true" else "false");
    try out.appendSlice(allocator, ",\"use_llm_extraction\":");
    try out.appendSlice(allocator, if (use_llm_extraction) "true" else "false");
    try out.appendSlice(allocator, ",\"strict_llm_extraction\":");
    try out.appendSlice(allocator, if (strict_llm_extraction) "true" else "false");
    if (route.target != .primary) {
        try appendExtractionStorageRouteJson(allocator, &out, route);
    }
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

fn appendExtractionStorageRouteJson(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), route: store_mod.AgentMemoryStorageRoute) !void {
    switch (route.target) {
        .primary => {},
        .native => try out.appendSlice(allocator, ",\"storage\":\"native\""),
        .runtime => try out.appendSlice(allocator, ",\"store\":\"runtime\""),
        .named => {
            try out.appendSlice(allocator, ",\"store\":");
            try json.appendString(out, allocator, route.name orelse "runtime");
        },
        .all => try out.appendSlice(allocator, ",\"storage\":\"all\""),
        .subset => {
            try out.appendSlice(allocator, ",\"stores\":[");
            for (route.stores, 0..) |store_name, i| {
                if (i > 0) try out.append(allocator, ',');
                try json.appendString(out, allocator, store_name);
            }
            try out.append(allocator, ']');
        },
    }
}

fn markdownImportQueuedResponse(ctx: *Context, job: store_mod.Job, source: domain.Source, artifact: domain.Artifact) HttpResponse {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ctx.allocator, "{\"queued\":true,\"job\":") catch return serverError(ctx);
    job.writeJson(ctx.allocator, &out) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"source\":") catch return serverError(ctx);
    source.writeJson(ctx.allocator, &out) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"artifact\":") catch return serverError(ctx);
    artifact.writeJson(ctx.allocator, &out) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"run_endpoint\":\"/v1/workers/run\"}") catch return serverError(ctx);
    return .{ .status = "202 Accepted", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn markdownImportResponse(ctx: *Context, source: domain.Source, artifact: domain.Artifact, output: ExtractionOutput) HttpResponse {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ctx.allocator, "{\"source\":") catch return serverError(ctx);
    source.writeJson(ctx.allocator, &out) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"artifact\":") catch return serverError(ctx);
    artifact.writeJson(ctx.allocator, &out) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"memory_atoms\":[") catch return serverError(ctx);
    for (output.atoms, 0..) |atom, i| {
        if (i > 0) out.append(ctx.allocator, ',') catch return serverError(ctx);
        atom.writeJson(ctx.allocator, &out) catch return serverError(ctx);
    }
    out.appendSlice(ctx.allocator, "],\"entities\":[") catch return serverError(ctx);
    for (output.entities, 0..) |entity, i| {
        if (i > 0) out.append(ctx.allocator, ',') catch return serverError(ctx);
        entity.writeJson(ctx.allocator, &out) catch return serverError(ctx);
    }
    out.appendSlice(ctx.allocator, "],\"relations\":[") catch return serverError(ctx);
    for (output.relations, 0..) |relation, i| {
        if (i > 0) out.append(ctx.allocator, ',') catch return serverError(ctx);
        relation.writeJson(ctx.allocator, &out) catch return serverError(ctx);
    }
    out.print(ctx.allocator, "],\"vector_chunk_count\":{d},\"extraction_provider\":", .{output.vector_chunks}) catch return serverError(ctx);
    json.appendString(&out, ctx.allocator, output.extraction_provider) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"extraction_fallback\":") catch return serverError(ctx);
    out.appendSlice(ctx.allocator, if (output.extraction_fallback) "true}" else "false}") catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn artifactTypes(ctx: *Context) HttpResponse {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ctx.allocator, "{\"artifact_types\":") catch return serverError(ctx);
    artifacts.appendTypesJson(ctx.allocator, &out) catch return serverError(ctx);
    out.append(ctx.allocator, '}') catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn createSpace(ctx: *Context, body: []const u8) HttpResponse {
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const name = json.stringField(obj, "name") orelse return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing name");
    const title = json.stringField(obj, "title") orelse name;
    const scope = json.stringField(obj, "scope") orelse "workspace";
    const permissions_json = rawField(ctx.allocator, obj, "permissions", "[]") catch return serverError(ctx);
    if (!canWriteRecord(ctx, scope, permissions_json)) return forbidden(ctx);
    const space = ctx.store.createSpace(ctx.allocator, .{
        .name = name,
        .title = title,
        .description = json.nullableStringField(obj, "description"),
        .scope = scope,
        .permissions_json = permissions_json,
        .metadata_json = rawField(ctx.allocator, obj, "metadata", "{}") catch return serverError(ctx),
        .actor_id = ctx.actor_id,
    }) catch return serverError(ctx);
    const text = vector_text.space(ctx.allocator, space) catch return serverError(ctx);
    _ = upsertAutoVector(ctx, "space", space.id, text, space.scope, space.permissions_json) catch 0;
    return objectResponse(ctx, "space", space);
}

fn getSpace(ctx: *Context, id: []const u8) HttpResponse {
    if (!hasCapability(ctx, "read")) return forbidden(ctx);
    const space = ctx.store.getSpace(ctx.allocator, id) catch return serverError(ctx);
    if (space == null) return json.errorResponse(ctx.allocator, 404, "not_found", "Space not found");
    if (!recordVisibleToActor(ctx, space.?.scope, space.?.permissions_json)) return forbidden(ctx);
    return objectResponse(ctx, "space", space.?);
}

fn listSpaces(ctx: *Context, query: []const u8) HttpResponse {
    if (!hasCapability(ctx, "read")) return forbidden(ctx);
    const limit = parseLimit(json.queryParam(query, "limit"), 100);
    const spaces = ctx.store.listSpaces(ctx.allocator, ctx.actor_scopes_json, limit) catch return serverError(ctx);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ctx.allocator, "{\"spaces\":[") catch return serverError(ctx);
    for (spaces, 0..) |space, i| {
        if (i > 0) out.append(ctx.allocator, ',') catch return serverError(ctx);
        space.writeJson(ctx.allocator, &out) catch return serverError(ctx);
    }
    out.appendSlice(ctx.allocator, "]}") catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn upsertPolicyScope(ctx: *Context, body: []const u8) HttpResponse {
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const scope = json.stringField(obj, "scope") orelse return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing scope");
    const permissions_json = rawField(ctx.allocator, obj, "permissions", "[]") catch return serverError(ctx);
    if (!canWriteRecord(ctx, scope, permissions_json)) return forbidden(ctx);
    const policy = ctx.store.upsertPolicyScope(ctx.allocator, .{
        .scope = scope,
        .visibility = json.stringField(obj, "visibility") orelse "workspace",
        .permissions_json = permissions_json,
        .owner = json.nullableStringField(obj, "owner"),
        .ttl_ms = json.intField(obj, "ttl_ms"),
        .review_after_ms = json.intField(obj, "review_after_ms"),
        .metadata_json = rawField(ctx.allocator, obj, "metadata", "{}") catch return serverError(ctx),
        .actor_id = ctx.actor_id,
    }) catch return serverError(ctx);
    const text = vector_text.policyScope(ctx.allocator, policy) catch return serverError(ctx);
    _ = upsertAutoVector(ctx, "policy_scope", policy.scope, text, policy.scope, policy.permissions_json) catch 0;
    return objectResponse(ctx, "policy_scope", policy);
}

fn getPolicyScope(ctx: *Context, scope: []const u8) HttpResponse {
    if (!hasCapability(ctx, "read")) return forbidden(ctx);
    const policy = ctx.store.getPolicyScope(ctx.allocator, scope) catch return serverError(ctx);
    if (policy == null) return json.errorResponse(ctx.allocator, 404, "not_found", "Policy scope not found");
    if (!recordVisibleToActor(ctx, policy.?.scope, policy.?.permissions_json)) return forbidden(ctx);
    return objectResponse(ctx, "policy_scope", policy.?);
}

fn listPolicyScopes(ctx: *Context, query: []const u8) HttpResponse {
    if (!hasCapability(ctx, "read")) return forbidden(ctx);
    const limit = parseLimit(json.queryParam(query, "limit"), 100);
    const policies = ctx.store.listPolicyScopes(ctx.allocator, ctx.actor_scopes_json, limit) catch return serverError(ctx);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ctx.allocator, "{\"policy_scopes\":[") catch return serverError(ctx);
    for (policies, 0..) |policy, i| {
        if (i > 0) out.append(ctx.allocator, ',') catch return serverError(ctx);
        policy.writeJson(ctx.allocator, &out) catch return serverError(ctx);
    }
    out.appendSlice(ctx.allocator, "]}") catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn sdkManifest(ctx: *Context) HttpResponse {
    return ok(ctx,
        \\{"name":"nullpantry","version":"v1","base_path":"/v1","methods":{"agent_memory_put":"PUT /v1/agent-memory/{key}","agent_memory_get":"GET /v1/agent-memory/{key}","agent_memory_list":"GET /v1/agent-memory","agent_memory_search":"POST /v1/agent-memory/search","agent_memory_delete":"DELETE /v1/agent-memory/{key}","agent_memory_count":"GET /v1/agent-memory/count","agent_sessions_list":"GET /v1/agent-sessions","agent_session_history":"GET /v1/agent-sessions/{id}","agent_session_messages_get":"GET /v1/agent-sessions/{id}/messages","agent_session_messages_post":"POST /v1/agent-sessions/{id}/messages","agent_session_messages_delete":"DELETE /v1/agent-sessions/{id}/messages","agent_session_usage_get":"GET /v1/agent-sessions/{id}/usage","agent_session_usage_put":"PUT /v1/agent-sessions/{id}/usage","agent_session_usage_delete":"DELETE /v1/agent-sessions/{id}/usage","agent_session_auto_saved_delete":"DELETE /v1/agent-sessions/auto-saved?session_id={id}","remember":"POST /v1/remember","search":"POST /v1/search","ask":"POST /v1/ask","get_context_pack":"POST /v1/context-packs","create_source":"POST /v1/sources","create_space":"POST /v1/spaces","upsert_policy_scope":"POST /v1/policy-scopes","extract_memory":"POST /v1/extract-memory","create_decision":"POST /v1/artifacts type=decision","link":"POST /v1/relations","forget":"POST /v1/forget","verify":"POST /v1/verify","mark_stale":"POST /v1/mark-stale","ingest":"POST /v1/ingest","connector_ingest":"POST /v1/connectors/{name}/ingest","connector_cursor":"GET|POST /v1/connectors/{name}/cursor","markdown_import":"POST /v1/markdown/import","markdown_import_directory":"POST /v1/markdown/import-directory","markdown_export":"POST /v1/markdown/export","markdown_export_directory":"POST /v1/markdown/export-directory","graph_schema":"GET /v1/graph/schema","graph_query":"POST /v1/graph/query","graph_neighbors":"POST /v1/graph/neighbors","graph_path":"POST /v1/graph/path","providers":"GET /v1/providers","feed":"GET|POST /v1/memory/feed","events":"GET|POST /v1/memory/events","feed_status":"GET /v1/memory/status","feed_compact":"POST /v1/memory/compact","checkpoint_export":"GET /v1/memory/checkpoint","checkpoint_restore":"POST /v1/memory/checkpoint","apply":"POST /v1/memory/apply","worker_run":"POST /v1/workers/run","vector_status":"GET /v1/vector/status","vector_embed":"POST /v1/vector/embed","vector_upsert":"POST /v1/vector/upsert","vector_search":"POST /v1/vector/search","vector_delete":"POST /v1/vector/delete","vector_rebuild":"POST /v1/vector/rebuild","vector_reconcile":"POST /v1/vector/reconcile","vector_outbox":"GET /v1/vector/outbox","vector_outbox_run":"POST /v1/vector/outbox/run","lucid_projection_status":"GET /v1/lifecycle/lucid/status","lucid_projection_rebuild":"POST /v1/lifecycle/lucid/rebuild","analytics_status":"GET /v1/lifecycle/analytics/status","analytics_query":"POST /v1/lifecycle/analytics/query","analytics_export":"POST /v1/lifecycle/analytics/export","snapshot_export":"POST /v1/lifecycle/snapshot/export","snapshot_import":"POST /v1/lifecycle/snapshot/import"},"headers":{"actor_id":"X-NullPantry-Actor-Id","actor_scopes":"X-NullPantry-Actor-Scopes","actor_capabilities":"X-NullPantry-Actor-Capabilities"},"auth":{"token_principals_env":"NULLPANTRY_TOKEN_PRINCIPALS","note":"token principal scopes/capabilities are authoritative; request headers can only narrow them"}}
    );
}

const ExtractionOutput = struct {
    artifact: ?domain.Artifact = null,
    atoms: []domain.MemoryAtom,
    entities: []domain.Entity,
    relations: []domain.Relation = &.{},
    vector_chunks: usize = 0,
    extraction_provider: []const u8 = "heuristic",
    extraction_fallback: bool = false,
};

const ExtractionOptions = struct {
    create_artifact: bool = true,
    extract_memory: bool = true,
    use_llm_extraction: bool = false,
    strict_llm_extraction: bool = false,
    storage_route: store_mod.AgentMemoryStorageRoute = .{},
};

fn extractionOptionsFromObject(ctx: *Context, obj: std.json.ObjectMap, create_artifact_default: bool, extract_memory_default: bool) !ExtractionOptions {
    return .{
        .create_artifact = json.boolField(obj, "create_artifact") orelse create_artifact_default,
        .extract_memory = json.boolField(obj, "extract_memory") orelse extract_memory_default,
        .use_llm_extraction = json.boolField(obj, "use_llm_extraction") orelse json.boolField(obj, "structured_extraction") orelse false,
        .strict_llm_extraction = json.boolField(obj, "strict_llm_extraction") orelse false,
        .storage_route = try agentMemoryStorageTargetFromObject(ctx.allocator, obj),
    };
}

fn ingest(ctx: *Context, body: []const u8) HttpResponse {
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const title = json.stringField(obj, "title") orelse return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing title");
    const scope = json.stringField(obj, "scope") orelse "workspace";
    const permissions_json = rawField(ctx.allocator, obj, "permissions", "[]") catch return serverError(ctx);
    if (!canProposeRecord(ctx, scope, permissions_json)) return forbidden(ctx);

    const source = ctx.store.createSource(ctx.allocator, .{
        .source_type = json.stringField(obj, "type") orelse "manual",
        .title = title,
        .raw_content_uri = json.nullableStringField(obj, "raw_content_uri"),
        .content = json.stringField(obj, "content") orelse "",
        .author = json.nullableStringField(obj, "author"),
        .participants_json = rawField(ctx.allocator, obj, "participants", "[]") catch return serverError(ctx),
        .permissions_json = permissions_json,
        .scope = scope,
        .checksum = json.nullableStringField(obj, "checksum"),
        .language = json.nullableStringField(obj, "language"),
        .related_entities_json = rawField(ctx.allocator, obj, "related_entities", "[]") catch return serverError(ctx),
        .metadata_json = rawField(ctx.allocator, obj, "metadata", "{}") catch return serverError(ctx),
        .actor_id = ctx.actor_id,
    }) catch return serverError(ctx);
    const job = ctx.store.createJob(ctx.allocator, .{
        .job_type = "ingest",
        .scope = scope,
        .permissions_json = permissions_json,
        .object_type = "source",
        .object_id = source.id,
        .input_json = body,
        .actor_id = ctx.actor_id,
    }) catch return serverError(ctx);

    if (!(json.boolField(obj, "run_now") orelse false)) {
        return queuedExtractionResponse(ctx, job, source);
    }

    const output = runExtraction(ctx, source, extractionOptionsFromObject(ctx, obj, true, true) catch return serverError(ctx)) catch |err| {
        _ = ctx.store.finishJob(job.id, "failed", "{}", @errorName(err)) catch {};
        return serverError(ctx);
    };
    const result_json = std.fmt.allocPrint(ctx.allocator, "{{\"source_id\":\"{s}\",\"artifact_count\":{d},\"memory_atom_count\":{d},\"entity_count\":{d},\"relation_count\":{d},\"vector_chunk_count\":{d},\"extraction_provider\":\"{s}\",\"extraction_fallback\":{s}}}", .{ source.id, if (output.artifact == null) @as(usize, 0) else 1, output.atoms.len, output.entities.len, output.relations.len, output.vector_chunks, output.extraction_provider, if (output.extraction_fallback) "true" else "false" }) catch return serverError(ctx);
    _ = ctx.store.finishJob(job.id, "succeeded", result_json, null) catch return serverError(ctx);
    const finished = (ctx.store.getJob(ctx.allocator, job.id) catch return serverError(ctx)) orelse job;
    return extractionResponse(ctx, finished, source, output);
}

fn extractMemory(ctx: *Context, body: []const u8) HttpResponse {
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const source_id = json.stringField(obj, "source_id") orelse return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing source_id");
    const source = (ctx.store.getSource(ctx.allocator, source_id) catch return serverError(ctx)) orelse return json.errorResponse(ctx.allocator, 404, "not_found", "Source not found");
    if (!recordVisibleToActor(ctx, source.scope, source.permissions_json)) return json.errorResponse(ctx.allocator, 404, "not_found", "Source not found");
    if (!canProposeRecord(ctx, source.scope, source.permissions_json)) return forbidden(ctx);

    const job = ctx.store.createJob(ctx.allocator, .{
        .job_type = "extract_memory",
        .scope = source.scope,
        .permissions_json = source.permissions_json,
        .object_type = "source",
        .object_id = source.id,
        .input_json = body,
        .actor_id = ctx.actor_id,
    }) catch return serverError(ctx);
    if (!(json.boolField(obj, "run_now") orelse false)) {
        return queuedExtractionResponse(ctx, job, source);
    }

    const output = runExtraction(ctx, source, extractionOptionsFromObject(ctx, obj, true, true) catch return serverError(ctx)) catch |err| {
        _ = ctx.store.finishJob(job.id, "failed", "{}", @errorName(err)) catch {};
        return serverError(ctx);
    };
    const result_json = std.fmt.allocPrint(ctx.allocator, "{{\"source_id\":\"{s}\",\"artifact_count\":{d},\"memory_atom_count\":{d},\"entity_count\":{d},\"relation_count\":{d},\"vector_chunk_count\":{d},\"extraction_provider\":\"{s}\",\"extraction_fallback\":{s}}}", .{ source.id, if (output.artifact == null) @as(usize, 0) else 1, output.atoms.len, output.entities.len, output.relations.len, output.vector_chunks, output.extraction_provider, if (output.extraction_fallback) "true" else "false" }) catch return serverError(ctx);
    _ = ctx.store.finishJob(job.id, "succeeded", result_json, null) catch return serverError(ctx);
    const finished = (ctx.store.getJob(ctx.allocator, job.id) catch return serverError(ctx)) orelse job;
    return extractionResponse(ctx, finished, source, output);
}

fn runExtraction(ctx: *Context, source: domain.Source, options: ExtractionOptions) !ExtractionOutput {
    const source_ids_json = try extraction.sourceIdsJson(ctx.allocator, source.id);
    const entity_names_json = try extraction.extractEntityNamesJson(ctx.allocator, source.content);

    var artifact_input: ?store_mod.ArtifactInput = null;
    if (options.create_artifact) {
        const artifact_title = try extraction.sourceTitleForArtifact(ctx.allocator, source.title, source.source_type);
        const summary = try extraction.summarize(ctx.allocator, source.content, 512);
        const agent_summary = try extraction.summarize(ctx.allocator, source.content, 1024);
        artifact_input = .{
            .artifact_type = extraction.artifactTypeForSource(source.source_type),
            .title = artifact_title,
            .body = source.content,
            .status = "draft",
            .owner = source.author,
            .scope = source.scope,
            .source_ids_json = source_ids_json,
            .related_entities_json = entity_names_json,
            .permissions_json = source.permissions_json,
            .summary = summary,
            .agent_summary = agent_summary,
            .actor_id = ctx.actor_id,
            .storage_route = options.storage_route,
        };
    }

    var atom_inputs: std.ArrayListUnmanaged(store_mod.MemoryAtomInput) = .empty;
    var relation_inputs: std.ArrayListUnmanaged(store_mod.ExtractedRelationInput) = .empty;
    var extraction_provider: []const u8 = "heuristic";
    var extraction_fallback = false;
    if (options.extract_memory) {
        var structured_done = false;
        if (options.use_llm_extraction) {
            const prompt = try extraction.memoryExtractionPrompt(ctx.allocator, source.title, source.source_type, source.content);
            const completion: ?providers.CompletionResult = blk: {
                const result = providers.completeWithSystem(ctx.allocator, .{
                    .base_url = ctx.llm_base_url,
                    .api_key = ctx.llm_api_key,
                    .model = ctx.llm_model,
                    .timeout_secs = ctx.provider_timeout_secs,
                }, "Return only valid JSON for the requested NullPantry extraction schema. Do not include markdown fences unless the model cannot avoid them. Extract only source-grounded memory atoms and relations.", prompt) catch |err| {
                    if (options.strict_llm_extraction) return err;
                    extraction_fallback = true;
                    break :blk null;
                };
                break :blk result;
            };
            if (completion) |result| {
                const parsed_memories: ?[]extraction.ParsedMemory = blk: {
                    const memories = extraction.parseStructuredMemoryResponse(ctx.allocator, result.content) catch |err| {
                        if (options.strict_llm_extraction) return err;
                        extraction_fallback = true;
                        break :blk null;
                    };
                    break :blk memories;
                };
                if (parsed_memories) |memories| {
                    structured_done = true;
                    extraction_provider = result.provider;
                    for (memories) |parsed| {
                        const evidence_ranges_json = try extraction.evidenceRangeForText(ctx.allocator, source.id, source.content, parsed.evidence orelse parsed.text);
                        try atom_inputs.append(ctx.allocator, .{
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
                            .actor_id = ctx.actor_id,
                            .storage_route = options.storage_route,
                        });
                    }
                    const parsed_relations = extraction.parseStructuredRelationsResponse(ctx.allocator, result.content) catch &.{};
                    for (parsed_relations) |parsed| {
                        try relation_inputs.append(ctx.allocator, .{
                            .from_entity_name = parsed.from_name,
                            .relation_type = parsed.relation_type,
                            .to_entity_name = parsed.to_name,
                            .source_ids_json = source_ids_json,
                            .scope = source.scope,
                            .permissions_json = source.permissions_json,
                            .confidence = parsed.confidence,
                            .status = "proposed",
                            .actor_id = ctx.actor_id,
                        });
                    }
                }
            }
        }
        if (!structured_done) {
            extraction_provider = "heuristic";
            var lines = std.mem.splitScalar(u8, source.content, '\n');
            var offset: usize = 0;
            var line_no: usize = 1;
            while (lines.next()) |line| : ({
                offset += line.len + 1;
                line_no += 1;
            }) {
                if (extraction.parseMemoryLine(line)) |parsed| {
                    const evidence_ranges_json = try extraction.evidenceRangeJson(ctx.allocator, source.id, offset, offset + line.len, line_no);
                    try atom_inputs.append(ctx.allocator, .{
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
                        .actor_id = ctx.actor_id,
                        .storage_route = options.storage_route,
                    });
                }
                if (extraction.parseRelationLine(line)) |relation| {
                    try relation_inputs.append(ctx.allocator, .{
                        .from_entity_name = relation.from_name,
                        .relation_type = relation.relation_type,
                        .to_entity_name = relation.to_name,
                        .source_ids_json = source_ids_json,
                        .scope = source.scope,
                        .permissions_json = source.permissions_json,
                        .confidence = relation.confidence,
                        .status = "proposed",
                        .actor_id = ctx.actor_id,
                    });
                }
            }
        }
    }

    const applied = try ctx.store.applyExtractedKnowledge(ctx.allocator, .{
        .source = source,
        .source_ids_json = source_ids_json,
        .entity_names_json = entity_names_json,
        .artifact = artifact_input,
        .atoms = atom_inputs.items,
        .relations = relation_inputs.items,
        .actor_id = ctx.actor_id,
    });

    var vector_chunks: usize = 0;
    vector_chunks += try upsertAutoVector(ctx, "source", source.id, source.content, source.scope, source.permissions_json);
    if (applied.artifact) |artifact| {
        vector_chunks += try upsertAutoVector(ctx, "artifact", artifact.id, artifact.body, artifact.scope, artifact.permissions_json);
    }
    for (applied.entities) |entity| {
        const text = try vector_text.entity(ctx.allocator, entity);
        vector_chunks += try upsertAutoVector(ctx, "entity", entity.id, text, entity.scope, entity.permissions_json);
    }
    for (applied.relations) |relation| {
        const text = try vector_text.relation(ctx.allocator, relation);
        vector_chunks += try upsertAutoVector(ctx, "relation", relation.id, text, relation.scope, relation.permissions_json);
    }
    for (applied.atoms) |atom| {
        vector_chunks += try upsertAutoVector(ctx, "memory_atom", atom.id, atom.text, atom.scope, atom.permissions_json);
    }

    return .{ .artifact = applied.artifact, .atoms = applied.atoms, .entities = applied.entities, .relations = applied.relations, .vector_chunks = vector_chunks, .extraction_provider = extraction_provider, .extraction_fallback = extraction_fallback };
}

fn resolveExtractedEntities(ctx: *Context, names_json: []const u8, scope: []const u8, permissions_json: []const u8) ![]domain.Entity {
    const parsed = try std.json.parseFromSlice(std.json.Value, ctx.allocator, names_json, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return ctx.allocator.alloc(domain.Entity, 0);
    var out: std.ArrayListUnmanaged(domain.Entity) = .empty;
    for (parsed.value.array.items) |item| {
        const name = switch (item) {
            .string => |s| s,
            else => continue,
        };
        try out.append(ctx.allocator, try ctx.store.resolveEntity(ctx.allocator, .{ .entity_type = "project", .name = name, .scope = scope, .permissions_json = permissions_json, .actor_id = ctx.actor_id }));
    }
    return out.toOwnedSlice(ctx.allocator);
}

fn upsertAutoVector(ctx: *Context, object_type: []const u8, object_id: []const u8, text: []const u8, scope: []const u8, permissions_json: []const u8) !usize {
    if (text.len == 0) return 0;
    var count: usize = 0;
    var start: usize = 0;
    while (start < text.len) {
        const end = vectorChunkEnd(text, start);
        const chunk_text = std.mem.trim(u8, text[start..end], " \t\r\n");
        if (chunk_text.len > 0) {
            const payload = try store_mod.vectorEmbedPayloadJson(ctx.allocator, @intCast(count), chunk_text, scope, permissions_json, ctx.embedding_model, ctx.embedding_dimensions);
            const outbox_id = try ctx.store.enqueueVectorOutbox(.{ .action = "embed", .object_type = object_type, .object_id = object_id, .payload_json = payload });
            const embedding_result = providers.embedText(ctx.allocator, .{
                .provider = ctx.embedding_provider,
                .base_url = ctx.embedding_base_url,
                .api_key = ctx.embedding_api_key,
                .model = ctx.embedding_model,
                .dimensions = ctx.embedding_dimensions,
                .timeout_secs = ctx.provider_timeout_secs,
                .fallbacks = ctx.embedding_fallbacks,
            }, chunk_text, ctx.embedding_dimensions) catch return count;
            const embedding_json = try vector_mod.embeddingToJson(ctx.allocator, embedding_result.embedding);
            _ = try ctx.store.upsertVectorChunk(ctx.allocator, .{
                .object_type = object_type,
                .object_id = object_id,
                .chunk_ordinal = @intCast(count),
                .text = chunk_text,
                .scope = scope,
                .permissions_json = permissions_json,
                .embedding_json = embedding_json,
                .model = embedding_result.model,
                .dimensions = @intCast(embedding_result.embedding.len),
                .actor_id = ctx.actor_id,
            });
            _ = try ctx.store.finishVectorOutbox(outbox_id, "embedded");
            count += 1;
        }
        start = end;
    }
    return count;
}

fn vectorChunkEnd(text: []const u8, start: usize) usize {
    const max_chars: usize = 1800;
    const min_chars: usize = 600;
    const end = @min(text.len, start + max_chars);
    if (end == text.len) return end;
    var scan = end;
    while (scan > start + min_chars) : (scan -= 1) {
        if (text[scan - 1] == '\n') return scan;
    }
    return end;
}

fn extractionResponse(ctx: *Context, job: store_mod.Job, source: domain.Source, output: ExtractionOutput) HttpResponse {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ctx.allocator, "{\"job\":") catch return serverError(ctx);
    job.writeJson(ctx.allocator, &out) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"source\":") catch return serverError(ctx);
    source.writeJson(ctx.allocator, &out) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"artifact\":") catch return serverError(ctx);
    if (output.artifact) |artifact| artifact.writeJson(ctx.allocator, &out) catch return serverError(ctx) else out.appendSlice(ctx.allocator, "null") catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"memory_atoms\":[") catch return serverError(ctx);
    for (output.atoms, 0..) |atom, i| {
        if (i > 0) out.append(ctx.allocator, ',') catch return serverError(ctx);
        atom.writeJson(ctx.allocator, &out) catch return serverError(ctx);
    }
    out.appendSlice(ctx.allocator, "],\"entities\":[") catch return serverError(ctx);
    for (output.entities, 0..) |entity, i| {
        if (i > 0) out.append(ctx.allocator, ',') catch return serverError(ctx);
        entity.writeJson(ctx.allocator, &out) catch return serverError(ctx);
    }
    out.appendSlice(ctx.allocator, "],\"relations\":[") catch return serverError(ctx);
    for (output.relations, 0..) |relation, i| {
        if (i > 0) out.append(ctx.allocator, ',') catch return serverError(ctx);
        relation.writeJson(ctx.allocator, &out) catch return serverError(ctx);
    }
    out.print(ctx.allocator, "],\"vector_chunk_count\":{d},\"extraction_provider\":", .{output.vector_chunks}) catch return serverError(ctx);
    json.appendString(&out, ctx.allocator, output.extraction_provider) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"extraction_fallback\":") catch return serverError(ctx);
    out.appendSlice(ctx.allocator, if (output.extraction_fallback) "true}" else "false}") catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn createJob(ctx: *Context, body: []const u8) HttpResponse {
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const scope = json.stringField(obj, "scope") orelse "workspace";
    const permissions_json = rawField(ctx.allocator, obj, "permissions", "[]") catch return serverError(ctx);
    if (!canProposeRecord(ctx, scope, permissions_json)) return forbidden(ctx);
    const job = ctx.store.createJob(ctx.allocator, .{
        .job_type = json.stringField(obj, "type") orelse json.stringField(obj, "job_type") orelse return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing job type"),
        .scope = scope,
        .permissions_json = permissions_json,
        .object_type = json.stringField(obj, "object_type") orelse "",
        .object_id = json.stringField(obj, "object_id") orelse "",
        .input_json = rawField(ctx.allocator, obj, "input", "{}") catch return serverError(ctx),
        .actor_id = ctx.actor_id,
    }) catch return serverError(ctx);
    return objectResponse(ctx, "job", job);
}

fn listJobs(ctx: *Context, query: []const u8) HttpResponse {
    if (!hasCapability(ctx, "read")) return forbidden(ctx);
    const status = json.queryParamDecoded(ctx.allocator, query, "status") catch return serverError(ctx);
    const effective_status = if (status != null and std.mem.eql(u8, status.?, "all")) null else status;
    const jobs = ctx.store.listJobs(ctx.allocator, .{
        .scopes_json = ctx.actor_scopes_json,
        .status = effective_status,
        .limit = parseLimit(json.queryParam(query, "limit"), 100),
    }) catch return serverError(ctx);
    return jobsResponse(ctx, jobs);
}

fn runJob(ctx: *Context, id: []const u8) HttpResponse {
    const job = (ctx.store.getJob(ctx.allocator, id) catch return serverError(ctx)) orelse return json.errorResponse(ctx.allocator, 404, "not_found", "Job not found");
    if (!recordVisibleToActor(ctx, job.scope, job.permissions_json)) return json.errorResponse(ctx.allocator, 404, "not_found", "Job not found");
    if (!canProposeRecord(ctx, job.scope, job.permissions_json)) return forbidden(ctx);
    const finished = worker.runJobById(ctx.allocator, ctx.store, id, .{
        .scopes_json = ctx.actor_scopes_json,
        .capabilities_json = ctx.actor_capabilities_json,
        .embedding_base_url = ctx.embedding_base_url,
        .embedding_api_key = ctx.embedding_api_key,
        .embedding_model = ctx.embedding_model,
        .embedding_provider = ctx.embedding_provider,
        .embedding_fallbacks = ctx.embedding_fallbacks,
        .embedding_dimensions = ctx.embedding_dimensions,
        .llm_base_url = ctx.llm_base_url,
        .llm_api_key = ctx.llm_api_key,
        .llm_model = ctx.llm_model,
        .provider_timeout_secs = ctx.provider_timeout_secs,
    }) catch |err| switch (err) {
        error.JobNotQueued => return json.errorResponse(ctx.allocator, 409, "conflict", "Job is not queued"),
        else => return serverError(ctx),
    };
    return objectResponse(ctx, "job", finished);
}

fn jobsResponse(ctx: *Context, jobs: []store_mod.Job) HttpResponse {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ctx.allocator, "{\"jobs\":[") catch return serverError(ctx);
    for (jobs, 0..) |job, i| {
        if (i > 0) out.append(ctx.allocator, ',') catch return serverError(ctx);
        job.writeJson(ctx.allocator, &out) catch return serverError(ctx);
    }
    out.appendSlice(ctx.allocator, "]}") catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn queuedExtractionResponse(ctx: *Context, job: store_mod.Job, source: domain.Source) HttpResponse {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ctx.allocator, "{\"queued\":true,\"job\":") catch return serverError(ctx);
    job.writeJson(ctx.allocator, &out) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"source\":") catch return serverError(ctx);
    source.writeJson(ctx.allocator, &out) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"run_endpoint\":\"/v1/workers/run\"}") catch return serverError(ctx);
    return .{ .status = "202 Accepted", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn listConflicts(ctx: *Context, query: []const u8) HttpResponse {
    if (!hasCapability(ctx, "read")) return forbidden(ctx);
    const status = json.queryParamDecoded(ctx.allocator, query, "status") catch return serverError(ctx);
    const effective_status = if (status != null and std.mem.eql(u8, status.?, "all")) null else (status orelse "open");
    const conflicts = ctx.store.listConflicts(ctx.allocator, .{
        .scopes_json = ctx.actor_scopes_json,
        .status = effective_status,
        .limit = parseLimit(json.queryParam(query, "limit"), 100),
    }) catch return serverError(ctx);
    return conflictsResponse(ctx, conflicts);
}

fn scanConflicts(ctx: *Context, body: []const u8) HttpResponse {
    if (!hasCapability(ctx, "verify") and !hasCapability(ctx, "write")) return forbidden(ctx);
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const conflicts = ctx.store.scanConflicts(ctx.allocator, .{
        .scopes_json = effectiveScopes(ctx, obj) catch return serverError(ctx),
        .status = json.nullableStringField(obj, "status") orelse "open",
        .limit = positiveLimit(json.intField(obj, "limit"), 100),
    }) catch return serverError(ctx);
    return conflictsResponse(ctx, conflicts);
}

fn conflictsResponse(ctx: *Context, conflicts: []store_mod.KnowledgeConflict) HttpResponse {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ctx.allocator, "{\"conflicts\":[") catch return serverError(ctx);
    for (conflicts, 0..) |conflict, i| {
        if (i > 0) out.append(ctx.allocator, ',') catch return serverError(ctx);
        conflict.writeJson(ctx.allocator, &out) catch return serverError(ctx);
    }
    out.appendSlice(ctx.allocator, "]}") catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn createMemoryAtom(ctx: *Context, body: []const u8) HttpResponse {
    const parsed_input = parseMemoryAtomInput(ctx, body) catch return badJson(ctx);
    var input = parsed_input;
    input.actor_id = ctx.actor_id;
    if (!canCreateMemoryAtom(ctx, input)) return forbidden(ctx);
    input = ensureMemoryProvenance(ctx, input) catch |err| switch (err) {
        error.Forbidden => return forbidden(ctx),
        else => return serverError(ctx),
    };
    const atom = ctx.store.createMemoryAtom(ctx.allocator, input) catch |err| switch (err) {
        error.AgentMemoryStorageUnavailable => return agentMemoryStorageUnavailable(ctx),
        else => return serverError(ctx),
    };
    _ = upsertAutoVector(ctx, "memory_atom", atom.id, atom.text, atom.scope, atom.permissions_json) catch 0;
    return objectResponse(ctx, "memory_atom", atom);
}

fn remember(ctx: *Context, body: []const u8) HttpResponse {
    return createMemoryAtom(ctx, body);
}

fn patchMemoryAtom(ctx: *Context, id: []const u8, body: []const u8) HttpResponse {
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const status = json.stringField(parsed.value.object, "status") orelse return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing status");
    if (!canChangeMemoryStatus(ctx, id, status)) return json.errorResponse(ctx.allocator, 404, "not_found", "Memory atom not found");
    const changed = ctx.store.patchMemoryAtomStatusActor(id, status, std.mem.eql(u8, status, "verified"), ctx.actor_id) catch return serverError(ctx);
    if (!changed) return json.errorResponse(ctx.allocator, 404, "not_found", "Memory atom not found");
    const atom = ctx.store.getMemoryAtom(ctx.allocator, id) catch return serverError(ctx);
    return objectResponse(ctx, "memory_atom", atom.?);
}

fn statusAction(ctx: *Context, body: []const u8, status: []const u8, verified: bool, response_key: []const u8) HttpResponse {
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const id = json.stringField(parsed.value.object, "id") orelse json.stringField(parsed.value.object, "memory_atom_id") orelse return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing id");
    if (!canChangeMemoryStatus(ctx, id, status)) return json.errorResponse(ctx.allocator, 404, "not_found", "Memory atom not found");
    const changed = ctx.store.patchMemoryAtomStatusActor(id, status, verified, ctx.actor_id) catch return serverError(ctx);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.print(ctx.allocator, "{{\"{s}\":{s},\"id\":", .{ response_key, if (changed) "true" else "false" }) catch return serverError(ctx);
    json.appendString(&out, ctx.allocator, id) catch return serverError(ctx);
    out.append(ctx.allocator, '}') catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn parseMemoryAtomInput(ctx: *Context, body: []const u8) !store_mod.MemoryAtomInput {
    var parsed = try parseBody(ctx, body);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const text = json.stringField(obj, "text") orelse json.stringField(obj, "content") orelse return error.MissingText;
    return .{
        .subject_entity_id = try dupOptional(ctx.allocator, json.nullableStringField(obj, "subject_entity_id")),
        .predicate = try ctx.allocator.dupe(u8, json.stringField(obj, "predicate") orelse "states"),
        .object = try ctx.allocator.dupe(u8, json.stringField(obj, "object") orelse ""),
        .text = try ctx.allocator.dupe(u8, text),
        .scope = try ctx.allocator.dupe(u8, json.stringField(obj, "scope") orelse "workspace"),
        .confidence = json.floatField(obj, "confidence") orelse 0.5,
        .status = try dupOptional(ctx.allocator, json.nullableStringField(obj, "status")),
        .source_ids_json = try rawField(ctx.allocator, obj, "source_ids", "[]"),
        .evidence_ranges_json = try rawField(ctx.allocator, obj, "evidence_ranges", "[]"),
        .created_by = try ctx.allocator.dupe(u8, json.stringField(obj, "created_by") orelse "human"),
        .valid_from_ms = json.intField(obj, "valid_from_ms"),
        .valid_until_ms = json.intField(obj, "valid_until_ms"),
        .owner = try dupOptional(ctx.allocator, json.nullableStringField(obj, "owner")),
        .permissions_json = try rawField(ctx.allocator, obj, "permissions", "[]"),
        .tags_json = try rawField(ctx.allocator, obj, "tags", "[]"),
        .storage_route = try agentMemoryStorageTargetFromObject(ctx.allocator, obj),
    };
}

fn search(ctx: *Context, body: []const u8) HttpResponse {
    if (!hasCapability(ctx, "read")) return forbidden(ctx);
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const query = json.stringField(obj, "query") orelse json.stringField(obj, "q") orelse "";
    const input = buildSearchInput(ctx, obj, query, positiveLimit(json.intField(obj, "limit"), 10), false) catch return serverError(ctx);
    const use_cache = json.boolField(obj, "use_cache") orelse true;
    const cache_ttl_ms = json.intField(obj, "cache_ttl_ms") orelse 0;
    const cache_key = automaticCacheKey(ctx.allocator, "search", ctx.actor_id, input.scopes_json, body) catch return serverError(ctx);
    if (use_cache) {
        if (ctx.store.getResponseCacheForScopes(ctx.allocator, cache_key, ids.nowMs(), input.scopes_json, ctx.actor_id) catch return serverError(ctx)) |hit| {
            return .{ .status = "200 OK", .body = hit.response_json };
        }
    }
    var results = ctx.store.search(ctx.allocator, input) catch |err| switch (err) {
        error.AgentMemoryStorageUnavailable => return agentMemoryStorageUnavailable(ctx),
        else => return serverError(ctx),
    };
    results = maybeLlmRerankResults(ctx, query, results, input.allow_reranker) catch results;
    const response = searchResponse(ctx, results);
    if (cache_ttl_ms > 0 and hasCapability(ctx, "write")) {
        ctx.store.putResponseCache(.{ .cache_key = cache_key, .response_json = response.body, .scopes_json = input.scopes_json, .actor_id = ctx.actor_id, .ttl_ms = cache_ttl_ms }) catch return serverError(ctx);
    }
    return response;
}

fn vectorUpsert(ctx: *Context, body: []const u8) HttpResponse {
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const object_id = json.stringField(obj, "object_id") orelse return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing object_id");
    const object_type = json.stringField(obj, "object_type") orelse "memory_atom";
    const requested_scope = json.stringField(obj, "scope") orelse "workspace";
    const requested_permissions = rawField(ctx.allocator, obj, "permissions", "[]") catch return serverError(ctx);
    const acl = resolveVectorAcl(ctx, object_type, object_id, requested_scope, requested_permissions) catch |err| switch (err) {
        error.NotFound => return json.errorResponse(ctx.allocator, 404, "not_found", "Vector target object not found"),
        error.Forbidden => return forbidden(ctx),
        else => return serverError(ctx),
    };
    const embedding_json = rawField(ctx.allocator, obj, "embedding", "[]") catch return serverError(ctx);
    const dims = json.intField(obj, "dimensions") orelse blk: {
        const parsed_embedding = @import("vector.zig").embeddingFromJson(ctx.allocator, embedding_json) catch return badJson(ctx);
        break :blk @as(i64, @intCast(parsed_embedding.len));
    };
    const chunk = ctx.store.upsertVectorChunk(ctx.allocator, .{
        .object_type = object_type,
        .object_id = object_id,
        .chunk_ordinal = json.intField(obj, "chunk_ordinal") orelse 0,
        .text = json.stringField(obj, "text") orelse "",
        .scope = acl.scope,
        .permissions_json = acl.permissions_json,
        .embedding_json = embedding_json,
        .model = json.nullableStringField(obj, "model"),
        .dimensions = dims,
        .actor_id = ctx.actor_id,
    }) catch |err| switch (err) {
        error.InvalidVectorTarget => return json.errorResponse(ctx.allocator, 404, "not_found", "Vector target object not found"),
        else => return serverError(ctx),
    };
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ctx.allocator, "{\"vector_chunk\":{\"id\":") catch return serverError(ctx);
    json.appendString(&out, ctx.allocator, chunk.id) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"object_id\":") catch return serverError(ctx);
    json.appendString(&out, ctx.allocator, chunk.object_id) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"scope\":") catch return serverError(ctx);
    json.appendString(&out, ctx.allocator, chunk.scope) catch return serverError(ctx);
    out.print(ctx.allocator, ",\"dimensions\":{d}}}", .{chunk.dimensions}) catch return serverError(ctx);
    out.append(ctx.allocator, '}') catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn vectorEmbed(ctx: *Context, body: []const u8) HttpResponse {
    if (!hasCapability(ctx, "read")) return forbidden(ctx);
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    if (obj.get("base_url") != null or obj.get("api_key") != null or obj.get("model") != null or obj.get("provider") != null or obj.get("timeout_secs") != null) {
        return json.errorResponse(ctx.allocator, 400, "bad_request", "Provider overrides are not allowed; configure providers on the server");
    }
    const text = json.stringField(obj, "text") orelse return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing text");
    const dimensions: usize = @intCast(@max(json.intField(obj, "dimensions") orelse @as(i64, @intCast(ctx.embedding_dimensions)), 1));
    const cfg = providers.EmbeddingConfig{
        .provider = ctx.embedding_provider,
        .base_url = ctx.embedding_base_url,
        .api_key = ctx.embedding_api_key,
        .model = ctx.embedding_model,
        .dimensions = @min(dimensions, 4096),
        .timeout_secs = ctx.provider_timeout_secs,
        .fallbacks = ctx.embedding_fallbacks,
    };
    const result = providers.embedText(ctx.allocator, cfg, text, @min(dimensions, 4096)) catch return serverError(ctx);
    const embedding_json = @import("vector.zig").embeddingToJson(ctx.allocator, result.embedding) catch return serverError(ctx);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ctx.allocator, "{\"provider\":") catch return serverError(ctx);
    json.appendString(&out, ctx.allocator, result.provider) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"model\":") catch return serverError(ctx);
    json.appendString(&out, ctx.allocator, result.model) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"dimensions\":") catch return serverError(ctx);
    out.print(ctx.allocator, "{d},\"embedding\":", .{result.embedding.len}) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, embedding_json) catch return serverError(ctx);
    out.append(ctx.allocator, '}') catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn vectorStatus(ctx: *Context) HttpResponse {
    if (!hasCapability(ctx, "read")) return forbidden(ctx);
    const pending = ctx.store.countVectorOutbox("pending") catch return serverError(ctx);
    const running = ctx.store.countVectorOutbox("running") catch return serverError(ctx);
    const failed_embedding = ctx.store.countVectorOutbox("failed_embedding") catch return serverError(ctx);
    const failed_external_index = ctx.store.countVectorOutbox("failed_external_index") catch return serverError(ctx);
    const failed_external_delete = ctx.store.countVectorOutbox("failed_external_delete") catch return serverError(ctx);
    const total_chunks = ctx.store.countVectorChunks() catch return serverError(ctx);
    const cfg = ctx.store.vector_backend;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ctx.allocator, "{\"vector\":{\"backend\":") catch return serverError(ctx);
    json.appendString(&out, ctx.allocator, ctx.store.vectorBackendName()) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"collection\":") catch return serverError(ctx);
    json.appendString(&out, ctx.allocator, cfg.collection) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"external_enabled\":") catch return serverError(ctx);
    out.appendSlice(ctx.allocator, if (cfg.externalEnabled()) "true" else "false") catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"mode\":") catch return serverError(ctx);
    json.appendString(&out, ctx.allocator, switch (cfg.backend) {
        .local => "local",
        .qdrant => "http",
        .lancedb => "sdk_process",
        .lancedb_http => "http_adapter",
    }) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"base_url_configured\":") catch return serverError(ctx);
    out.appendSlice(ctx.allocator, if (cfg.base_url != null) "true" else "false") catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"lancedb_uri_configured\":") catch return serverError(ctx);
    out.appendSlice(ctx.allocator, if (cfg.lancedb_uri != null) "true" else "false") catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"command_configured\":") catch return serverError(ctx);
    out.appendSlice(ctx.allocator, if (cfg.lancedb_command.len > 0) "true" else "false") catch return serverError(ctx);
    out.print(ctx.allocator, ",\"canonical_chunks\":{d},\"outbox\":{{\"pending\":{d},\"running\":{d},\"failed_embedding\":{d},\"failed_external_index\":{d},\"failed_external_delete\":{d}", .{ total_chunks, pending, running, failed_embedding, failed_external_index, failed_external_delete }) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, "}}}") catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn vectorSearch(ctx: *Context, body: []const u8) HttpResponse {
    if (!hasCapability(ctx, "read")) return forbidden(ctx);
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const embedding_json = rawField(ctx.allocator, obj, "embedding", "[]") catch return serverError(ctx);
    const matches = ctx.store.vectorSearch(ctx.allocator, .{
        .embedding_json = embedding_json,
        .scopes_json = effectiveScopes(ctx, obj) catch return serverError(ctx),
        .limit = positiveLimit(json.intField(obj, "limit"), 10),
        .include_deprecated = json.boolField(obj, "include_deprecated") orelse false,
        .strict_external = json.boolField(obj, "strict_external") orelse json.boolField(obj, "strict_vector") orelse false,
        .actor_id = ctx.actor_id,
    }) catch return serverError(ctx);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ctx.allocator, "{\"matches\":[") catch return serverError(ctx);
    for (matches, 0..) |match, i| {
        if (i > 0) out.append(ctx.allocator, ',') catch return serverError(ctx);
        match.writeJson(ctx.allocator, &out) catch return serverError(ctx);
    }
    out.appendSlice(ctx.allocator, "]}") catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn vectorDelete(ctx: *Context, body: []const u8) HttpResponse {
    if (!hasCapability(ctx, "delete")) return forbidden(ctx);
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const vector_id = json.stringField(obj, "vector_id") orelse json.stringField(obj, "id") orelse return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing vector_id");
    const deleted = ctx.store.deleteVectorChunk(ctx.allocator, vector_id, ctx.actor_id) catch return serverError(ctx);
    if (!deleted) return json.errorResponse(ctx.allocator, 404, "not_found", "Vector chunk not found");
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ctx.allocator, "{\"vector_delete\":{\"vector_id\":") catch return serverError(ctx);
    json.appendString(&out, ctx.allocator, vector_id) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"deleted\":true,\"external_delete_enqueued\":true}}") catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn vectorRebuild(ctx: *Context, body: []const u8) HttpResponse {
    if (!hasCapability(ctx, "write")) return forbidden(ctx);
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const result = ctx.store.rebuildVectorIndex(ctx.allocator, .{
        .limit = positiveLimit(json.intField(obj, "limit"), 1000),
        .reset_external = json.boolField(obj, "reset_external") orelse false,
        .retry_failed = json.boolField(obj, "retry_failed") orelse false,
    }) catch return serverError(ctx);
    return vectorMaintenanceResponse(ctx, "vector_rebuild", result);
}

fn vectorReconcile(ctx: *Context, body: []const u8) HttpResponse {
    if (!hasCapability(ctx, "write")) return forbidden(ctx);
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const result = ctx.store.reconcileVectorIndex(ctx.allocator, .{
        .limit = positiveLimit(json.intField(parsed.value.object, "limit"), 1000),
        .reset_external = false,
        .retry_failed = json.boolField(parsed.value.object, "retry_failed") orelse false,
    }) catch return serverError(ctx);
    return vectorMaintenanceResponse(ctx, "vector_reconcile", result);
}

fn vectorMaintenanceResponse(ctx: *Context, key: []const u8, result: store_mod.VectorMaintenanceResult) HttpResponse {
    const body = std.fmt.allocPrint(
        ctx.allocator,
        "{{\"{s}\":{{\"canonical_chunks\":{d},\"enqueued_upserts\":{d},\"requeued_failed\":{d},\"external_enabled\":{s},\"active_sink\":\"{s}\",\"external_sinks\":{s}}}}}",
        .{
            key,
            result.canonical_chunks,
            result.enqueued_upserts,
            result.requeued_failed,
            if (result.external_enabled) "true" else "false",
            ctx.store.vectorBackendName(),
            ctx.store.vectorExternalSinksJson(),
        },
    ) catch return serverError(ctx);
    return .{ .status = "200 OK", .body = body };
}

fn vectorOutboxStatus(ctx: *Context) HttpResponse {
    if (!hasCapability(ctx, "read")) return forbidden(ctx);
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
    const body = std.fmt.allocPrint(ctx.allocator, "{{\"outbox\":{{\"pending\":{d},\"running\":{d},\"embedded\":{d},\"failed_embedding\":{d},\"indexed_local\":{d},\"indexed_external\":{d},\"deleted_external\":{d},\"failed_external_index\":{d},\"failed_external_delete\":{d},\"active_sink\":\"{s}\",\"external_sinks\":{s},\"total\":{d}}}}}", .{ pending, running, embedded, failed_embedding, indexed_local, indexed_external, deleted_external, failed_external_index, failed_external_delete, ctx.store.vectorBackendName(), ctx.store.vectorExternalSinksJson(), total }) catch return serverError(ctx);
    return .{ .status = "200 OK", .body = body };
}

fn vectorOutboxRun(ctx: *Context, body: []const u8) HttpResponse {
    if (!hasCapability(ctx, "write")) return forbidden(ctx);
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const limit = positiveLimit(json.intField(parsed.value.object, "limit"), 100);
    const result = worker.runVectorOutboxOnce(ctx.allocator, ctx.store, .{
        .scopes_json = ctx.actor_scopes_json,
        .capabilities_json = ctx.actor_capabilities_json,
        .outbox_limit = limit,
        .embedding_base_url = ctx.embedding_base_url,
        .embedding_api_key = ctx.embedding_api_key,
        .embedding_model = ctx.embedding_model,
        .embedding_provider = ctx.embedding_provider,
        .embedding_fallbacks = ctx.embedding_fallbacks,
        .embedding_dimensions = ctx.embedding_dimensions,
        .llm_base_url = ctx.llm_base_url,
        .llm_api_key = ctx.llm_api_key,
        .llm_model = ctx.llm_model,
        .provider_timeout_secs = ctx.provider_timeout_secs,
    }) catch return serverError(ctx);
    const pending = ctx.store.countVectorOutbox("pending") catch return serverError(ctx);
    const embedded = ctx.store.countVectorOutbox("embedded") catch return serverError(ctx);
    const indexed_local = ctx.store.countVectorOutbox("indexed_local") catch return serverError(ctx);
    const indexed_external = ctx.store.countVectorOutbox("indexed_external") catch return serverError(ctx);
    const deleted_external = ctx.store.countVectorOutbox("deleted_external") catch return serverError(ctx);
    const response = std.fmt.allocPrint(ctx.allocator, "{{\"outbox_run\":{{\"processed\":{d},\"failed\":{d},\"pending\":{d},\"embedded\":{d},\"indexed_local\":{d},\"indexed_external\":{d},\"deleted_external\":{d},\"active_sink\":\"{s}\",\"external_sinks\":{s}}}}}", .{ result.processed, result.failed, pending, embedded, indexed_local, indexed_external, deleted_external, ctx.store.vectorBackendName(), ctx.store.vectorExternalSinksJson() }) catch return serverError(ctx);
    return .{ .status = "200 OK", .body = response };
}

fn retrievalPlan(ctx: *Context, body: []const u8) HttpResponse {
    if (!hasCapability(ctx, "read")) return forbidden(ctx);
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const query = json.stringField(obj, "query") orelse return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing query");
    const has_vector_index = (ctx.store.countVectorChunks() catch 0) > 0;
    const allow_reranker = (json.boolField(obj, "allow_reranker") orelse false) and ctx.llm_base_url != null and ctx.llm_model != null;
    var plan = retrieval.buildPlan(ctx.allocator, query, has_vector_index, allow_reranker) catch return serverError(ctx);
    defer plan.deinit(ctx.allocator);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ctx.allocator, "{\"plan\":{") catch return serverError(ctx);
    appendRetrievalPlanFields(ctx, &out, plan) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, "}}") catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn appendRetrievalPlanFields(ctx: *Context, out: *std.ArrayListUnmanaged(u8), plan: retrieval.RetrievalPlan) !void {
    try out.appendSlice(ctx.allocator, "\"use_keyword\":");
    try out.appendSlice(ctx.allocator, if (plan.use_keyword) "true" else "false");
    try out.appendSlice(ctx.allocator, ",\"use_vector\":");
    try out.appendSlice(ctx.allocator, if (plan.use_vector) "true" else "false");
    try out.appendSlice(ctx.allocator, ",\"use_graph\":");
    try out.appendSlice(ctx.allocator, if (plan.use_graph) "true" else "false");
    try out.appendSlice(ctx.allocator, ",\"use_reranker\":");
    try out.appendSlice(ctx.allocator, if (plan.use_reranker) "true" else "false");
    try out.appendSlice(ctx.allocator, ",\"query_expanded\":");
    try out.appendSlice(ctx.allocator, if (plan.query_expanded) "true" else "false");
    try out.appendSlice(ctx.allocator, ",\"expanded_query\":");
    try json.appendString(out, ctx.allocator, plan.expanded_query);
    try out.appendSlice(ctx.allocator, ",\"keyword_query\":");
    try json.appendString(out, ctx.allocator, plan.keyword_query);
    try out.appendSlice(ctx.allocator, ",\"websearch_query\":");
    try json.appendString(out, ctx.allocator, plan.websearch_query);
    try out.appendSlice(ctx.allocator, ",\"expansion_terms\":");
    try out.appendSlice(ctx.allocator, plan.expansion_terms_json);
    try out.appendSlice(ctx.allocator, ",\"expansion_reasons\":");
    try out.appendSlice(ctx.allocator, plan.expansion_reasons_json);
    try out.appendSlice(ctx.allocator, ",\"intent_hints\":");
    try out.appendSlice(ctx.allocator, plan.intent_hints_json);
}

fn appendRetrievalStages(ctx: *Context, out: *std.ArrayListUnmanaged(u8), input: store_mod.SearchInput, plan: retrieval.RetrievalPlan, llm_rerank_effective: bool) !void {
    try out.appendSlice(ctx.allocator, ",\"stages\":[");
    var first = true;
    try appendStage(ctx, out, &first, "acl_filter");
    if (plan.query_expanded) try appendStage(ctx, out, &first, "query_expansion");
    if (plan.use_keyword) try appendStage(ctx, out, &first, "keyword");
    if (input.use_vector and input.query_embedding_json != null and plan.use_vector) {
        try appendStage(ctx, out, &first, "vector_ann");
        try appendStage(ctx, out, &first, "rrf");
    }
    if (plan.use_graph) try appendStage(ctx, out, &first, "graph_expansion");
    if (input.use_temporal_decay) try appendStage(ctx, out, &first, "temporal_decay");
    try appendStage(ctx, out, &first, "quality_rerank");
    if (input.use_mmr) try appendStage(ctx, out, &first, "mmr");
    if (llm_rerank_effective) try appendStage(ctx, out, &first, "llm_rerank");
    try appendStage(ctx, out, &first, "citation_assembly");
    try out.append(ctx.allocator, ']');
}

fn appendStage(ctx: *Context, out: *std.ArrayListUnmanaged(u8), first: *bool, stage: []const u8) !void {
    if (!first.*) try out.append(ctx.allocator, ',');
    first.* = false;
    try json.appendString(out, ctx.allocator, stage);
}

fn retrievalSearch(ctx: *Context, body: []const u8) HttpResponse {
    if (!hasCapability(ctx, "read")) return forbidden(ctx);
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const query = json.stringField(obj, "query") orelse json.stringField(obj, "q") orelse return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing query");
    const limit = positiveLimit(json.intField(obj, "limit"), 10);
    const scopes_json = effectiveScopes(ctx, obj) catch return serverError(ctx);
    const include_deprecated = json.boolField(obj, "include_deprecated") orelse false;
    const use_vector = json.boolField(obj, "use_vector") orelse true;
    const allow_reranker = json.boolField(obj, "allow_reranker") orelse true;
    var input = buildSearchInput(ctx, obj, query, limit, false) catch return serverError(ctx);
    const has_vector_index = (ctx.store.countVectorChunks() catch 0) > 0;
    input.scopes_json = scopes_json;
    input.include_deprecated = include_deprecated;
    input.use_vector = input.use_vector and use_vector and has_vector_index;
    input.allow_reranker = allow_reranker;
    const llm_rerank_effective = allow_reranker and ctx.llm_base_url != null and ctx.llm_model != null;
    var plan = retrieval.buildPlan(ctx.allocator, query, input.use_vector, llm_rerank_effective) catch return serverError(ctx);
    defer plan.deinit(ctx.allocator);
    var results = ctx.store.search(ctx.allocator, input) catch |err| switch (err) {
        error.AgentMemoryStorageUnavailable => return agentMemoryStorageUnavailable(ctx),
        else => return serverError(ctx),
    };
    results = maybeLlmRerankResults(ctx, query, results, allow_reranker) catch results;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ctx.allocator, "{\"plan\":{") catch return serverError(ctx);
    appendRetrievalPlanFields(ctx, &out, plan) catch return serverError(ctx);
    appendRetrievalStages(ctx, &out, input, plan, llm_rerank_effective) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, "},\"results\":") catch return serverError(ctx);
    appendSearchArray(ctx, &out, results) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"groups\":") catch return serverError(ctx);
    appendSearchGroups(ctx, &out, results) catch return serverError(ctx);
    out.append(ctx.allocator, '}') catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn workersRun(ctx: *Context, body: []const u8) HttpResponse {
    if (!hasCapability(ctx, "write") and !hasCapability(ctx, "verify")) return forbidden(ctx);
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const result = worker.runOnce(ctx.allocator, ctx.store, .{
        .scopes_json = ctx.actor_scopes_json,
        .capabilities_json = ctx.actor_capabilities_json,
        .job_limit = positiveLimit(json.intField(parsed.value.object, "job_limit"), 25),
        .outbox_limit = positiveLimit(json.intField(parsed.value.object, "outbox_limit"), 100),
        .embedding_base_url = ctx.embedding_base_url,
        .embedding_api_key = ctx.embedding_api_key,
        .embedding_model = ctx.embedding_model,
        .embedding_provider = ctx.embedding_provider,
        .embedding_fallbacks = ctx.embedding_fallbacks,
        .embedding_dimensions = ctx.embedding_dimensions,
        .llm_base_url = ctx.llm_base_url,
        .llm_api_key = ctx.llm_api_key,
        .llm_model = ctx.llm_model,
        .provider_timeout_secs = ctx.provider_timeout_secs,
    }) catch return serverError(ctx);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.print(ctx.allocator, "{{\"worker_run\":{{\"jobs_checked\":{d},\"jobs_succeeded\":{d},\"jobs_failed\":{d},\"vector_outbox_processed\":{d},\"vector_outbox_failed\":{d},\"lucid_projection_processed\":{d},\"lucid_projection_failed\":{d}}}}}", .{ result.jobs_checked, result.jobs_succeeded, result.jobs_failed, result.vector_outbox_processed, result.vector_outbox_failed, result.lucid_projection_processed, result.lucid_projection_failed }) catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn memoryFeed(ctx: *Context, query: []const u8) HttpResponse {
    if (!hasCapability(ctx, "read")) return forbidden(ctx);
    const since_id = if (json.queryParam(query, "since_id")) |raw| std.fmt.parseInt(i64, raw, 10) catch 0 else 0;
    const limit = parseLimit(json.queryParam(query, "limit"), 100);
    const feed_scopes = feedScopesJson(ctx) catch return serverError(ctx);
    const events = ctx.store.listFeedEvents(ctx.allocator, .{ .since_id = since_id, .limit = limit, .scopes_json = feed_scopes }) catch |err| switch (err) {
        error.CursorExpired => return json.errorResponse(ctx.allocator, 410, "cursor_expired", "Feed cursor is older than the compacted cursor floor; request a checkpoint"),
        else => return serverError(ctx),
    };
    return feedEventsResponse(ctx, events);
}

fn memoryFeedStatus(ctx: *Context) HttpResponse {
    if (!hasCapability(ctx, "read")) return forbidden(ctx);
    const feed_scopes = feedScopesJson(ctx) catch return serverError(ctx);
    const status = ctx.store.feedStatus(ctx.allocator, feed_scopes) catch return serverError(ctx);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    status.writeJson(ctx.allocator, &out) catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn memoryFeedCompact(ctx: *Context, body: []const u8) HttpResponse {
    if (!(hasCapability(ctx, "feed_apply") and (hasCapability(ctx, "export") or hasCapability(ctx, "delete")))) return forbidden(ctx);
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const before_id = json.intField(parsed.value.object, "before_id") orelse json.intField(parsed.value.object, "before_event_id") orelse return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing before_id");
    const result = ctx.store.compactFeed(before_id, ctx.actor_id) catch return serverError(ctx);
    const response = std.fmt.allocPrint(ctx.allocator, "{{\"cursor_floor\":{d},\"max_event_id\":{d},\"compacted_events\":{d}}}", .{ result.cursor_floor, result.max_event_id, result.compacted_events }) catch return serverError(ctx);
    return .{ .status = "200 OK", .body = response };
}

fn memoryFeedCheckpoint(ctx: *Context, query: []const u8) HttpResponse {
    if (!(hasCapability(ctx, "read") and hasCapability(ctx, "export"))) return forbidden(ctx);
    const feed_scopes = feedScopesJson(ctx) catch return serverError(ctx);
    const status = ctx.store.feedStatus(ctx.allocator, feed_scopes) catch return serverError(ctx);
    const since_id = if (json.queryParam(query, "since_id")) |raw| std.fmt.parseInt(i64, raw, 10) catch 0 else 0;
    const limit = parseLimit(json.queryParam(query, "limit"), 500);
    const events = ctx.store.listFeedEvents(ctx.allocator, .{ .since_id = since_id, .limit = limit, .scopes_json = feed_scopes, .ignore_cursor_floor = true }) catch |err| switch (err) {
        error.CursorExpired => return json.errorResponse(ctx.allocator, 410, "cursor_expired", "Feed cursor is older than the compacted cursor floor"),
        else => return serverError(ctx),
    };
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.print(ctx.allocator, "{{\"cursor_floor\":{d},\"max_event_id\":{d},\"events\":[", .{ status.cursor_floor, status.max_event_id }) catch return serverError(ctx);
    _ = appendFeedEventsForActor(ctx, &out, events) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, "]}") catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn memoryFeedCheckpointRestore(ctx: *Context, body: []const u8) HttpResponse {
    if (!canApplyFeed(ctx)) return forbidden(ctx);
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const events_value = checkpointEventsValue(parsed.value.object) orelse return json.errorResponse(ctx.allocator, 400, "bad_request", "Checkpoint restore requires an events array");
    if (events_value != .array) return json.errorResponse(ctx.allocator, 400, "bad_request", "Checkpoint restore requires an events array");

    var restored: usize = 0;
    var applied: usize = 0;
    var queued: usize = 0;
    var skipped: usize = 0;
    for (events_value.array.items) |event_value| {
        if (event_value != .object) return json.errorResponse(ctx.allocator, 400, "bad_request", "Checkpoint events must be JSON objects");
        const event_obj = event_value.object;
        const status = json.stringField(event_obj, "status") orelse "applied";
        if (std.mem.eql(u8, status, "pending")) {
            restorePendingCheckpointEvent(ctx, event_obj) catch |err| switch (err) {
                error.Forbidden => return forbidden(ctx),
                error.UnsupportedObjectType => return json.errorResponse(ctx.allocator, 400, "bad_request", "Unsupported feed object_type"),
                error.InvalidPayload => return json.errorResponse(ctx.allocator, 400, "bad_request", "Invalid checkpoint event"),
                else => return serverError(ctx),
            };
            queued += 1;
        } else if (std.mem.eql(u8, status, "applied") or std.mem.eql(u8, status, "applying")) {
            const event_body = json.jsonFromValue(ctx.allocator, event_value) catch return serverError(ctx);
            const response = applyMemoryEvent(ctx, event_body);
            if (!std.mem.eql(u8, response.status, "200 OK")) return response;
            applied += 1;
        } else {
            skipped += 1;
        }
        restored += 1;
    }

    const response = std.fmt.allocPrint(ctx.allocator, "{{\"restored_events\":{d},\"applied_events\":{d},\"queued_events\":{d},\"skipped_events\":{d}}}", .{ restored, applied, queued, skipped }) catch return serverError(ctx);
    return .{ .status = "200 OK", .body = response };
}

fn checkpointEventsValue(obj: std.json.ObjectMap) ?std.json.Value {
    if (obj.get("events")) |events| return events;
    if (obj.get("checkpoint")) |checkpoint| {
        if (checkpoint == .object) return checkpoint.object.get("events");
    }
    return null;
}

fn restorePendingCheckpointEvent(ctx: *Context, obj: std.json.ObjectMap) !void {
    const event_type = json.stringField(obj, "event_type") orelse return error.InvalidPayload;
    const operation = json.stringField(obj, "operation") orelse operationFromEventType(event_type);
    const object_type = json.stringField(obj, "object_type") orelse "memory_atom";
    if (!feedObjectTypeSupported(object_type)) return error.UnsupportedObjectType;
    const object_id = json.stringField(obj, "object_id") orelse return error.InvalidPayload;
    const event_actor_id = json.stringField(obj, "actor_id") orelse ctx.actor_id;
    if (!canApplyAsActor(ctx, event_actor_id)) return error.Forbidden;
    const payload_json = rawField(ctx.allocator, obj, "payload", "{}") catch return error.InvalidPayload;
    const scope = feedEventScope(ctx, obj, object_type, payload_json, event_actor_id) catch return error.InvalidPayload;
    const permissions_json = rawField(ctx.allocator, obj, "permissions", "[]") catch return error.InvalidPayload;
    if (std.mem.eql(u8, object_type, "agent_memory")) {
        if (!canApplyAgentMemoryScope(ctx, event_actor_id, scope, permissions_json)) return error.Forbidden;
    } else if (!canWriteRecord(ctx, scope, permissions_json)) return error.Forbidden;

    _ = try ctx.store.appendFeedEvent(.{
        .event_type = event_type,
        .operation = operation,
        .object_type = object_type,
        .object_id = object_id,
        .scope = scope,
        .permissions_json = permissions_json,
        .actor_id = event_actor_id,
        .dedupe_key = json.nullableStringField(obj, "dedupe_key"),
        .causality_json = rawField(ctx.allocator, obj, "causality", "{}") catch "{}",
        .payload_json = payload_json,
        .status = "pending",
    });
}

fn appendMemoryFeed(ctx: *Context, body: []const u8) HttpResponse {
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const scope = json.stringField(obj, "scope") orelse "workspace";
    const permissions_json = rawField(ctx.allocator, obj, "permissions", "[]") catch return serverError(ctx);
    if (!canProposeRecord(ctx, scope, permissions_json)) return forbidden(ctx);
    const id = ctx.store.appendFeedEvent(.{
        .event_type = json.stringField(obj, "event_type") orelse return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing event_type"),
        .operation = json.stringField(obj, "operation") orelse "put",
        .object_type = json.stringField(obj, "object_type") orelse "memory_atom",
        .object_id = json.stringField(obj, "object_id") orelse return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing object_id"),
        .scope = scope,
        .permissions_json = permissions_json,
        .actor_id = ctx.actor_id,
        .dedupe_key = json.nullableStringField(obj, "dedupe_key"),
        .causality_json = rawField(ctx.allocator, obj, "causality", "{}") catch return serverError(ctx),
        .payload_json = rawField(ctx.allocator, obj, "payload", "{}") catch return serverError(ctx),
        .status = "pending",
    }) catch return serverError(ctx);
    const response = std.fmt.allocPrint(ctx.allocator, "{{\"event_id\":{d},\"queued\":true}}", .{id}) catch return serverError(ctx);
    return .{ .status = "200 OK", .body = response };
}

fn applyMemoryEvent(ctx: *Context, body: []const u8) HttpResponse {
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    if (!canApplyFeed(ctx)) return forbidden(ctx);
    const event_type = json.stringField(obj, "event_type") orelse "memory_atom.upsert";
    const operation = json.stringField(obj, "operation") orelse operationFromEventType(event_type);
    const object_type = json.stringField(obj, "object_type") orelse "memory_atom";
    const event_object_id = json.nullableStringField(obj, "object_id");
    if (!feedObjectTypeSupported(object_type)) {
        return json.errorResponse(ctx.allocator, 400, "bad_request", "Unsupported feed object_type");
    }
    const event_actor_id = json.stringField(obj, "actor_id") orelse ctx.actor_id;
    if (!canApplyAsActor(ctx, event_actor_id)) return forbidden(ctx);
    const payload_json = rawField(ctx.allocator, obj, "payload", "{}") catch return serverError(ctx);
    const causality_json = rawField(ctx.allocator, obj, "causality", "{}") catch return serverError(ctx);
    if (isLifecycleFeedOperation(operation) and !std.mem.eql(u8, object_type, "agent_memory")) {
        return applyFeedLifecycleMutation(ctx, obj, event_type, operation, object_type, event_actor_id, payload_json, causality_json);
    }
    const scope = feedEventScope(ctx, obj, object_type, payload_json, event_actor_id) catch return serverError(ctx);
    const event_permissions_json = rawField(ctx.allocator, obj, "permissions", "[]") catch return serverError(ctx);
    if (std.mem.eql(u8, object_type, "agent_memory")) {
        if (!canApplyAgentMemoryScope(ctx, event_actor_id, scope, event_permissions_json)) return forbidden(ctx);
    } else if (!canWriteRecord(ctx, scope, event_permissions_json)) return forbidden(ctx);
    var memory_input: ?store_mod.MemoryAtomInput = null;
    if (std.mem.eql(u8, object_type, "memory_atom")) {
        memory_input = buildAppliedMemoryAtomInput(ctx, payload_json, scope, event_object_id) catch |err| switch (err) {
            error.Forbidden => return forbidden(ctx),
            error.MissingText, error.InvalidPayload => return json.errorResponse(ctx.allocator, 400, "bad_request", "Memory apply payload must include text/content"),
            else => return serverError(ctx),
        };
    }
    var agent_memory_input: ?store_mod.AgentMemoryInput = null;
    var agent_memory_delete_key: ?[]const u8 = null;
    var agent_memory_delete_session_id: ?[]const u8 = null;
    var agent_memory_delete_actor_id: ?[]const u8 = null;
    var agent_memory_route: store_mod.AgentMemoryStorageRoute = .{};
    if (std.mem.eql(u8, object_type, "agent_memory")) {
        const prepared = buildAppliedAgentMemoryInput(ctx, operation, payload_json, event_object_id, event_actor_id) catch |err| switch (err) {
            error.Forbidden => return forbidden(ctx),
            error.MissingKey, error.InvalidPayload => return json.errorResponse(ctx.allocator, 400, "bad_request", "Agent memory apply payload must include key/object_id and valid merge content"),
            else => return serverError(ctx),
        };
        agent_memory_route = prepared.route;
        if (prepared.delete_key) |key| {
            agent_memory_delete_key = key;
            agent_memory_delete_session_id = prepared.delete_session_id;
            agent_memory_delete_actor_id = prepared.delete_actor_id;
        } else {
            agent_memory_input = prepared.input;
        }
    }
    var reserved_event_id: ?i64 = null;
    if (json.nullableStringField(obj, "dedupe_key")) |dedupe_key| {
        if (ctx.store.getFeedEventByDedupeKey(ctx.allocator, dedupe_key) catch return serverError(ctx)) |event| {
            if (!recordVisibleToActor(ctx, event.scope, event.permissions_json)) return forbidden(ctx);
            if (!std.mem.eql(u8, event.status, "applied")) {
                const stale_apply_ms: i64 = 5 * 60 * 1000;
                if (std.mem.eql(u8, event.status, "applying") and ids.nowMs() - event.created_at_ms > stale_apply_ms) {
                    _ = ctx.store.releaseFeedEventReservation(event.id) catch return serverError(ctx);
                } else {
                    return json.errorResponse(ctx.allocator, 409, "conflict", "Feed event with this dedupe key is already queued or applying");
                }
            } else {
                return appliedFeedObjectResponse(ctx, event.id, event.object_type, event.object_id, if (std.mem.eql(u8, event.object_type, "memory_atom")) event.object_id else null);
            }
        }
        const reservation_id = ids.make(ctx.allocator, "apply_") catch return serverError(ctx);
        reserved_event_id = ctx.store.appendFeedEvent(.{
            .event_type = event_type,
            .operation = operation,
            .object_type = object_type,
            .object_id = reservation_id,
            .scope = scope,
            .permissions_json = event_permissions_json,
            .actor_id = event_actor_id,
            .dedupe_key = dedupe_key,
            .causality_json = causality_json,
            .payload_json = payload_json,
            .status = "applying",
        }) catch return serverError(ctx);
        const reservation = (ctx.store.getFeedEventByDedupeKey(ctx.allocator, dedupe_key) catch return serverError(ctx)) orelse return serverError(ctx);
        if (reservation.id != reserved_event_id.? or !std.mem.eql(u8, reservation.status, "applying") or !std.mem.eql(u8, reservation.object_id, reservation_id)) {
            if (std.mem.eql(u8, reservation.status, "applied")) return appliedFeedObjectResponse(ctx, reservation.id, reservation.object_type, reservation.object_id, if (std.mem.eql(u8, reservation.object_type, "memory_atom")) reservation.object_id else null);
            return json.errorResponse(ctx.allocator, 409, "conflict", "Feed event with this dedupe key is already queued or applying");
        }
    }
    const memory_atom_id: ?[]const u8 = null;
    if (memory_input) |input| {
        var prepared = prepareAppliedMemoryProvenance(ctx, input) catch |err| switch (err) {
            error.Forbidden => return forbidden(ctx),
            else => return serverError(ctx),
        };
        prepared.atom.actor_id = event_actor_id;
        if (prepared.generated_source) |source_input| {
            var auditable_source = source_input;
            auditable_source.actor_id = event_actor_id;
            prepared.generated_source = auditable_source;
        }
        const applied = ctx.store.applyFeedMemoryAtomAtomic(ctx.allocator, .{
            .reserved_event_id = reserved_event_id,
            .event = .{
                .event_type = event_type,
                .operation = operation,
                .object_type = object_type,
                .object_id = "pending",
                .scope = scope,
                .permissions_json = event_permissions_json,
                .actor_id = event_actor_id,
                .dedupe_key = json.nullableStringField(obj, "dedupe_key"),
                .causality_json = causality_json,
                .payload_json = payload_json,
                .status = "applied",
            },
            .prepared = prepared,
        }) catch |err| {
            if (reserved_event_id) |event_id| {
                _ = ctx.store.releaseFeedEventReservation(event_id) catch {};
            }
            return switch (err) {
                error.FeedReservationConsumed => json.errorResponse(ctx.allocator, 409, "conflict", "Feed event reservation was already consumed"),
                error.AgentMemoryStorageUnavailable => agentMemoryStorageUnavailable(ctx),
                else => serverError(ctx),
            };
        };
        return appliedFeedResponse(ctx, applied.event_id, applied.atom.id);
    }
    if (agent_memory_input) |input| {
        const applied = ctx.store.applyFeedAgentMemoryRouted(ctx.allocator, .{
            .reserved_event_id = reserved_event_id,
            .event = .{
                .event_type = event_type,
                .operation = operation,
                .object_type = object_type,
                .object_id = "pending",
                .scope = scope,
                .permissions_json = event_permissions_json,
                .actor_id = event_actor_id,
                .dedupe_key = json.nullableStringField(obj, "dedupe_key"),
                .causality_json = causality_json,
                .payload_json = payload_json,
                .status = "applied",
            },
            .input = input,
            .writer_actor_id = event_actor_id,
        }, agent_memory_route) catch |err| {
            if (reserved_event_id) |event_id| {
                _ = ctx.store.releaseFeedEventReservation(event_id) catch {};
            }
            return switch (err) {
                error.MissingActorId => json.errorResponse(ctx.allocator, 400, "bad_request", "Agent memory events require an actor"),
                error.AgentMemoryStorageUnavailable => agentMemoryStorageUnavailable(ctx),
                error.FeedReservationConsumed => json.errorResponse(ctx.allocator, 409, "conflict", "Feed event reservation was already consumed"),
                else => serverError(ctx),
            };
        };
        return appliedFeedObjectResponse(ctx, applied.event_id, object_type, applied.object_id, null);
    }
    if (agent_memory_delete_key) |delete_key| {
        const applied = ctx.store.applyFeedAgentMemoryRouted(ctx.allocator, .{
            .reserved_event_id = reserved_event_id,
            .event = .{
                .event_type = event_type,
                .operation = operation,
                .object_type = object_type,
                .object_id = delete_key,
                .scope = scope,
                .permissions_json = event_permissions_json,
                .actor_id = event_actor_id,
                .dedupe_key = json.nullableStringField(obj, "dedupe_key"),
                .causality_json = causality_json,
                .payload_json = payload_json,
                .status = "applied",
            },
            .delete_key = delete_key,
            .delete_session_id = agent_memory_delete_session_id,
            .delete_owner_actor_id = agent_memory_delete_actor_id orelse event_actor_id,
            .writer_actor_id = event_actor_id,
        }, agent_memory_route) catch |err| {
            if (reserved_event_id) |event_id| {
                _ = ctx.store.releaseFeedEventReservation(event_id) catch {};
            }
            return switch (err) {
                error.AgentMemoryStorageUnavailable => agentMemoryStorageUnavailable(ctx),
                error.FeedReservationConsumed => json.errorResponse(ctx.allocator, 409, "conflict", "Feed event reservation was already consumed"),
                else => serverError(ctx),
            };
        };
        return appliedFeedObjectResponse(ctx, applied.event_id, object_type, applied.object_id, null);
    }
    if (!std.mem.eql(u8, object_type, "memory_atom") and !std.mem.eql(u8, object_type, "agent_memory")) {
        const object_id = applyFeedObjectPut(ctx, object_type, payload_json, scope, event_permissions_json, event_actor_id, event_object_id) catch |err| switch (err) {
            error.Forbidden => return forbidden(ctx),
            error.InvalidPayload, error.MissingRequiredField => return json.errorResponse(ctx.allocator, 400, "bad_request", "Invalid feed payload for object_type"),
            error.AgentMemoryStorageUnavailable => return agentMemoryStorageUnavailable(ctx),
            else => return serverError(ctx),
        };
        const event_id = if (reserved_event_id) |event_id| blk: {
            if (!(ctx.store.markFeedEventApplied(event_id, object_type, object_id, payload_json) catch return serverError(ctx))) {
                return json.errorResponse(ctx.allocator, 409, "conflict", "Feed event reservation was already consumed");
            }
            break :blk event_id;
        } else ctx.store.appendFeedEvent(.{
            .event_type = event_type,
            .operation = operation,
            .object_type = object_type,
            .object_id = object_id,
            .scope = scope,
            .permissions_json = event_permissions_json,
            .actor_id = event_actor_id,
            .dedupe_key = json.nullableStringField(obj, "dedupe_key"),
            .causality_json = causality_json,
            .payload_json = payload_json,
            .status = "applied",
        }) catch return serverError(ctx);
        return appliedFeedObjectResponse(ctx, event_id, object_type, object_id, null);
    }
    if (reserved_event_id) |event_id| {
        const object_id = memory_atom_id orelse (event_object_id orelse "unknown");
        if (!(ctx.store.markFeedEventApplied(event_id, object_type, object_id, payload_json) catch return serverError(ctx))) {
            return json.errorResponse(ctx.allocator, 409, "conflict", "Feed event reservation was already consumed");
        }
        return appliedFeedResponse(ctx, event_id, memory_atom_id);
    }
    const id = ctx.store.appendFeedEvent(.{
        .event_type = event_type,
        .operation = operation,
        .object_type = object_type,
        .object_id = memory_atom_id orelse (event_object_id orelse "unknown"),
        .scope = scope,
        .permissions_json = event_permissions_json,
        .actor_id = event_actor_id,
        .dedupe_key = json.nullableStringField(obj, "dedupe_key"),
        .causality_json = causality_json,
        .payload_json = payload_json,
        .status = "applied",
    }) catch return serverError(ctx);
    return appliedFeedResponse(ctx, id, memory_atom_id);
}

fn feedIdOverride(obj: std.json.ObjectMap, event_object_id: ?[]const u8, prefix: []const u8) !?[]const u8 {
    if (json.stringField(obj, "id")) |id| {
        if (std.mem.startsWith(u8, id, prefix) and id.len > prefix.len) return id;
        return error.InvalidPayload;
    }
    if (event_object_id) |id| {
        if (std.mem.startsWith(u8, id, prefix) and id.len > prefix.len) return id;
    }
    return null;
}

fn buildAppliedMemoryAtomInput(ctx: *Context, payload_json: []const u8, fallback_scope: []const u8, event_object_id: ?[]const u8) !store_mod.MemoryAtomInput {
    const payload = try std.json.parseFromSlice(std.json.Value, ctx.allocator, payload_json, .{});
    // Returned input fields borrow slices from this request-arena parse tree.
    if (payload.value != .object) return error.InvalidPayload;
    const obj = payload.value.object;
    const text = json.stringField(obj, "text") orelse json.stringField(obj, "content") orelse return error.MissingText;
    const atom_scope = json.stringField(obj, "scope") orelse fallback_scope;
    const permissions_json = rawField(ctx.allocator, obj, "permissions", "[]") catch return error.InvalidPayload;
    const input = store_mod.MemoryAtomInput{
        .id = try feedIdOverride(obj, event_object_id, "mem_"),
        .subject_entity_id = json.nullableStringField(obj, "subject_entity_id"),
        .text = text,
        .scope = atom_scope,
        .predicate = json.stringField(obj, "predicate") orelse "states",
        .object = json.stringField(obj, "object") orelse "",
        .confidence = json.floatField(obj, "confidence") orelse 0.7,
        .status = json.nullableStringField(obj, "status"),
        .source_ids_json = rawField(ctx.allocator, obj, "source_ids", "[]") catch "[]",
        .evidence_ranges_json = rawField(ctx.allocator, obj, "evidence_ranges", "[]") catch "[]",
        .created_by = json.stringField(obj, "created_by") orelse "agent",
        .valid_from_ms = json.intField(obj, "valid_from_ms"),
        .valid_until_ms = json.intField(obj, "valid_until_ms"),
        .owner = json.nullableStringField(obj, "owner"),
        .permissions_json = permissions_json,
        .tags_json = rawField(ctx.allocator, obj, "tags", "[\"feed\"]") catch "[\"feed\"]",
        .storage_route = try agentMemoryStorageTargetFromObject(ctx.allocator, obj),
        .suppress_feed = true,
    };
    if (!canCreateMemoryAtom(ctx, input)) return error.Forbidden;
    return input;
}

const AgentMemoryApplyInput = struct {
    input: ?store_mod.AgentMemoryInput = null,
    delete_key: ?[]const u8 = null,
    delete_session_id: ?[]const u8 = null,
    delete_actor_id: ?[]const u8 = null,
    route: store_mod.AgentMemoryStorageRoute = .{},
};

fn operationFromEventType(event_type: []const u8) []const u8 {
    if (std.mem.endsWith(u8, event_type, ".delete") or std.mem.endsWith(u8, event_type, ".forget")) return "delete";
    if (std.mem.endsWith(u8, event_type, ".merge_object")) return "merge_object";
    if (std.mem.endsWith(u8, event_type, ".merge_string_set")) return "merge_string_set";
    return "put";
}

fn feedEventScope(ctx: *Context, obj: std.json.ObjectMap, object_type: []const u8, payload_json: []const u8, event_actor_id: []const u8) ![]const u8 {
    if (json.stringField(obj, "scope")) |scope| return scope;
    const payload = try std.json.parseFromSlice(std.json.Value, ctx.allocator, payload_json, .{});
    // The returned scope may borrow from this request-arena parse tree.
    if (payload.value == .object) {
        if (json.stringField(payload.value.object, "scope")) |scope| return scope;
    }
    if (!std.mem.eql(u8, object_type, "agent_memory")) return "workspace";
    return domain.defaultAgentMemoryScope(ctx.allocator, event_actor_id);
}

fn canApplyAsActor(ctx: *Context, event_actor_id: []const u8) bool {
    return std.mem.eql(u8, event_actor_id, ctx.actor_id) or domain.hasActorScope(ctx.actor_scopes_json, "admin");
}

fn canApplyAgentMemoryScope(ctx: *Context, event_actor_id: []const u8, scope: []const u8, permissions_json: []const u8) bool {
    if (canWriteRecord(ctx, scope, permissions_json)) return true;
    if (!domain.isActorOwnedAgentMemoryScope(scope, event_actor_id)) return false;
    return (hasCapability(ctx, "write") or hasCapability(ctx, "propose")) and
        access.permissionsVisibleForActor(ctx.allocator, permissions_json, ctx.actor_scopes_json, event_actor_id);
}

fn buildAppliedAgentMemoryInput(ctx: *Context, operation: []const u8, payload_json: []const u8, object_id: ?[]const u8, event_actor_id: []const u8) !AgentMemoryApplyInput {
    const payload = try std.json.parseFromSlice(std.json.Value, ctx.allocator, payload_json, .{});
    // Returned input fields borrow slices from this request-arena parse tree.
    if (payload.value != .object) return error.InvalidPayload;
    const obj = payload.value.object;
    const key = json.stringField(obj, "key") orelse object_id orelse return error.MissingKey;
    const session_id = json.nullableStringField(obj, "session_id");
    if (session_id) |sid| {
        if (!agentSessionWriteAllowed(ctx, sid)) return error.Forbidden;
    }
    const route = try agentMemoryStorageTargetFromObject(ctx.allocator, obj);
    const scope = json.nullableStringField(obj, "scope");
    const computed_owner_id = try access.agentMemoryOwner(ctx.allocator, event_actor_id, scope);
    const owner_actor_id = json.stringField(obj, "owner_id") orelse computed_owner_id;
    if (!std.mem.eql(u8, owner_actor_id, computed_owner_id) and !domain.hasActorScope(ctx.actor_scopes_json, "admin")) return error.Forbidden;
    if (std.mem.eql(u8, operation, "delete") or std.mem.eql(u8, operation, "forget")) {
        return .{ .delete_key = key, .delete_session_id = session_id, .delete_actor_id = owner_actor_id, .route = route };
    }
    const permissions_json = rawField(ctx.allocator, obj, "permissions", "[]") catch return error.InvalidPayload;
    if (scope) |requested_scope| {
        const probe_content = json.stringField(obj, "content") orelse json.stringField(obj, "text") orelse "";
        if (!canCreateMemoryAtom(ctx, .{ .text = probe_content, .scope = requested_scope, .permissions_json = permissions_json, .created_by = "agent", .actor_id = event_actor_id })) return error.Forbidden;
    } else if (!domain.permissionsAreOpen(permissions_json) and !domain.permissionsWritable(permissions_json, ctx.actor_scopes_json)) {
        return error.Forbidden;
    }

    const memory_operation = domain.AgentMemoryOperation.parse(operation);
    const content = switch (memory_operation) {
        .put => json.stringField(obj, "content") orelse json.stringField(obj, "text") orelse try rawField(ctx.allocator, obj, "value", "{}"),
        .merge_string_set => try agent_memory_reducer.stringSetPatchFromObject(ctx.allocator, obj),
        .merge_object => try agent_memory_reducer.objectPatchFromObject(ctx.allocator, obj),
    };

    return .{ .input = .{
        .key = key,
        .content = content,
        .category = json.stringField(obj, "category") orelse "core",
        .session_id = session_id,
        .scope = scope,
        .permissions_json = permissions_json,
        .metadata_json = rawField(ctx.allocator, obj, "metadata", "{}") catch "{}",
        .actor_id = owner_actor_id,
        .writer_actor_id = event_actor_id,
        .operation = memory_operation,
    }, .route = route };
}

fn lifecycleDiagnostics(ctx: *Context) HttpResponse {
    if (!hasCapability(ctx, "read")) return forbidden(ctx);
    const store_diag = ctx.store.lifecycleDiagnostics() catch return serverError(ctx);
    const diagnostics = lifecycle.Diagnostics{
        .total_memory_atoms = store_diag.total_memory_atoms,
        .stale_memory_atoms = store_diag.stale_memory_atoms,
        .vector_outbox_pending = store_diag.vector_outbox_pending,
        .lucid_projection_pending = store_diag.lucid_projection_pending,
        .lucid_projection_failed = store_diag.lucid_projection_failed,
        .cache_entries = store_diag.cache_entries,
        .queued_jobs = store_diag.queued_jobs,
        .running_jobs = store_diag.running_jobs,
        .failed_jobs = store_diag.failed_jobs,
        .pending_feed_events = store_diag.pending_feed_events,
        .open_conflicts = store_diag.open_conflicts,
        .agent_memories = store_diag.agent_memories,
        .sessions = store_diag.sessions,
    };
    const body = std.fmt.allocPrint(
        ctx.allocator,
        "{{\"diagnostics\":{{\"health\":\"{s}\",\"total_memory_atoms\":{d},\"stale_memory_atoms\":{d},\"vector_outbox_pending\":{d},\"lucid_projection_pending\":{d},\"lucid_projection_failed\":{d},\"cache_entries\":{d},\"queued_jobs\":{d},\"running_jobs\":{d},\"failed_jobs\":{d},\"pending_feed_events\":{d},\"open_conflicts\":{d},\"agent_memories\":{d},\"sessions\":{d}}}}}",
        .{ diagnostics.health(), diagnostics.total_memory_atoms, diagnostics.stale_memory_atoms, diagnostics.vector_outbox_pending, diagnostics.lucid_projection_pending, diagnostics.lucid_projection_failed, diagnostics.cache_entries, diagnostics.queued_jobs, diagnostics.running_jobs, diagnostics.failed_jobs, diagnostics.pending_feed_events, diagnostics.open_conflicts, diagnostics.agent_memories, diagnostics.sessions },
    ) catch return serverError(ctx);
    return .{ .status = "200 OK", .body = body };
}

fn lifecycleLucidStatus(ctx: *Context) HttpResponse {
    if (!hasCapability(ctx, "read")) return forbidden(ctx);
    const diag = ctx.store.lifecycleDiagnostics() catch return serverError(ctx);
    const body = std.fmt.allocPrint(
        ctx.allocator,
        "{{\"lucid\":{{\"enabled\":{s},\"backend\":\"{s}\",\"pending\":{d},\"failed\":{d},\"cooldown_until_ms\":{d}}}}}",
        .{ if (ctx.store.lucid_projection.isEnabled()) "true" else "false", ctx.store.lucidBackendName(), diag.lucid_projection_pending, diag.lucid_projection_failed, ctx.store.lucid_projection.cooldown_until_ms },
    ) catch return serverError(ctx);
    return .{ .status = "200 OK", .body = body };
}

fn lifecycleLucidRebuild(ctx: *Context, body: []const u8) HttpResponse {
    if (!hasCapability(ctx, "write") and !hasCapability(ctx, "verify")) return forbidden(ctx);
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const limit = @as(usize, @intCast(@max(@as(i64, 1), @min(json.intField(parsed.value.object, "limit") orelse 1000, 5000))));
    const result = ctx.store.rebuildLucidProjection(ctx.allocator, .{
        .scopes_json = ctx.actor_scopes_json,
        .actor_id = ctx.actor_id,
        .limit = limit,
    }) catch return serverError(ctx);
    const body_out = std.fmt.allocPrint(
        ctx.allocator,
        "{{\"lucid_rebuild\":{{\"enabled\":{s},\"scanned\":{d},\"enqueued\":{d}}}}}",
        .{ if (result.enabled) "true" else "false", result.scanned, result.enqueued },
    ) catch return serverError(ctx);
    return .{ .status = "200 OK", .body = body_out };
}

fn analyticsAllowed(ctx: *Context) bool {
    return hasCapability(ctx, "export") and domain.hasActorScope(ctx.actor_scopes_json, "admin");
}

fn analyticsError(ctx: *Context, err: anyerror) HttpResponse {
    return switch (err) {
        error.AnalyticsBackendNotConfigured => json.errorResponse(ctx.allocator, 400, "bad_request", "Analytics backend is not configured"),
        error.AnalyticsBackendUnavailable => json.errorResponse(ctx.allocator, 500, "analytics_unavailable", "Analytics backend is unavailable"),
        error.AnalyticsBackendHttpError => json.errorResponse(ctx.allocator, 500, "analytics_error", "Analytics backend rejected the request"),
        error.AnalyticsBackendResponseTooLarge => json.errorResponse(ctx.allocator, 500, "analytics_response_too_large", "Analytics backend response exceeded the configured safety limit"),
        else => serverError(ctx),
    };
}

fn lifecycleAnalyticsStatus(ctx: *Context) HttpResponse {
    if (!analyticsAllowed(ctx)) return forbidden(ctx);
    const status = ctx.store.analyticsStatus(ctx.allocator) catch |err| return analyticsError(ctx, err);
    const cursor = ctx.store.getConnectorCursor(ctx.allocator, "clickhouse_analytics", "admin") catch null;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.print(
        ctx.allocator,
        "{{\"analytics_status\":{{\"backend\":\"{s}\",\"rows\":{d},\"audit_max_id\":{d},\"feed_max_id\":{d},\"latest_created_at_ms\":{d},\"cursor\":",
        .{ ctx.store.analyticsBackendName(), status.rows, status.audit_max_id, status.feed_max_id, status.latest_created_at_ms },
    ) catch return serverError(ctx);
    if (cursor) |loaded| {
        loaded.writeJson(ctx.allocator, &out) catch return serverError(ctx);
    } else {
        out.appendSlice(ctx.allocator, "null") catch return serverError(ctx);
    }
    out.appendSlice(ctx.allocator, "}}") catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn lifecycleAnalyticsQuery(ctx: *Context, body: []const u8) HttpResponse {
    if (!analyticsAllowed(ctx)) return forbidden(ctx);
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const events_json = ctx.store.queryAnalyticsEventsJson(ctx.allocator, .{
        .event_source = json.stringField(obj, "event_source"),
        .object_type = json.stringField(obj, "object_type"),
        .object_id = json.stringField(obj, "object_id"),
        .actor_id = json.stringField(obj, "actor_id"),
        .since_id = json.intField(obj, "since_id") orelse 0,
        .limit = positiveLimit(json.intField(obj, "limit"), 100),
        .newest_first = json.boolField(obj, "newest_first") orelse true,
    }) catch |err| return analyticsError(ctx, err);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ctx.allocator, "{\"analytics_events\":") catch return serverError(ctx);
    out.appendSlice(ctx.allocator, events_json) catch return serverError(ctx);
    out.append(ctx.allocator, '}') catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn lifecycleAnalyticsExport(ctx: *Context, body: []const u8) HttpResponse {
    if (!analyticsAllowed(ctx)) return forbidden(ctx);
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const since_id = json.intField(obj, "since_id") orelse 0;
    const result = ctx.store.exportAnalytics(ctx.allocator, .{
        .audit_since_id = json.intField(obj, "audit_since_id") orelse since_id,
        .feed_since_id = json.intField(obj, "feed_since_id") orelse since_id,
        .limit = positiveLimit(json.intField(obj, "limit"), 1000),
        .scopes_json = effectiveScopes(ctx, obj) catch return serverError(ctx),
        .use_cursor = json.boolField(obj, "use_cursor") orelse false,
        .advance_cursor = json.boolField(obj, "advance_cursor") orelse false,
        .cursor_name = json.stringField(obj, "cursor_name") orelse "clickhouse_analytics",
        .cursor_scope = json.stringField(obj, "cursor_scope") orelse "admin",
        .cursor_permissions_json = rawField(ctx.allocator, obj, "cursor_permissions", "[\"admin\"]") catch return badJson(ctx),
        .actor_id = ctx.actor_id,
    }) catch |err| return analyticsError(ctx, err);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.print(
        ctx.allocator,
        "{{\"analytics_export\":{{\"backend\":\"{s}\",\"audit_events\":{d},\"feed_events\":{d},\"attempted\":{d},\"exported\":{d},\"skipped_existing\":{d},\"audit_since_id\":{d},\"feed_since_id\":{d},\"next_audit_id\":{d},\"next_feed_id\":{d},\"cursor_advanced\":",
        .{ ctx.store.analyticsBackendName(), result.audit_events, result.feed_events, result.attempted, result.exported, result.skipped_existing, result.audit_since_id, result.feed_since_id, result.next_audit_id, result.next_feed_id },
    ) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, if (result.cursor_advanced) "true" else "false") catch return serverError(ctx);
    out.appendSlice(ctx.allocator, "}}") catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn lifecycleSnapshot(ctx: *Context, body: []const u8) HttpResponse {
    if (!hasCapability(ctx, "write") and !hasCapability(ctx, "propose")) return forbidden(ctx);
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const summary_json = rawField(ctx.allocator, obj, "summary", "{}") catch return serverError(ctx);
    const snapshot = ctx.store.createLifecycleSnapshot(ctx.allocator, json.stringField(obj, "type") orelse "manual", summary_json) catch return serverError(ctx);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ctx.allocator, "{\"snapshot\":{\"id\":") catch return serverError(ctx);
    json.appendString(&out, ctx.allocator, snapshot.id) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"type\":") catch return serverError(ctx);
    json.appendString(&out, ctx.allocator, snapshot.snapshot_type) catch return serverError(ctx);
    out.print(ctx.allocator, ",\"created_at_ms\":{d}}}", .{snapshot.created_at_ms}) catch return serverError(ctx);
    out.append(ctx.allocator, '}') catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn lifecycleSnapshotExport(ctx: *Context, body: []const u8) HttpResponse {
    if (!hasCapability(ctx, "read") or !hasCapability(ctx, "export")) return forbidden(ctx);
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const persist_snapshot = json.boolField(obj, "persist") orelse json.boolField(obj, "record_snapshot") orelse (hasCapability(ctx, "write") or hasCapability(ctx, "propose"));
    if (persist_snapshot and !hasCapability(ctx, "write") and !hasCapability(ctx, "propose")) return forbidden(ctx);
    const query = json.stringField(obj, "query") orelse "";
    var input = buildSearchInput(ctx, obj, query, positiveLimit(json.intField(obj, "limit"), 100), true) catch return serverError(ctx);
    input.include_deprecated = json.boolField(obj, "include_deprecated") orelse true;
    input.use_vector = json.boolField(obj, "use_vector") orelse false;
    const results = ctx.store.search(ctx.allocator, input) catch |err| switch (err) {
        error.AgentMemoryStorageUnavailable => return agentMemoryStorageUnavailable(ctx),
        else => return serverError(ctx),
    };
    const summary_json = snapshotSummaryJson(ctx, input.scopes_json, query, results) catch return serverError(ctx);
    const snapshot_type = json.stringField(obj, "type") orelse "export";
    const snapshot = if (persist_snapshot)
        ctx.store.createLifecycleSnapshot(ctx.allocator, snapshot_type, summary_json) catch return serverError(ctx)
    else
        store_mod.LifecycleSnapshot{ .id = ids.make(ctx.allocator, "snap_preview_") catch return serverError(ctx), .snapshot_type = snapshot_type, .summary_json = summary_json, .created_at_ms = ids.nowMs() };

    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ctx.allocator, "{\"snapshot\":{\"id\":") catch return serverError(ctx);
    json.appendString(&out, ctx.allocator, snapshot.id) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"type\":") catch return serverError(ctx);
    json.appendString(&out, ctx.allocator, snapshot.snapshot_type) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"scopes\":") catch return serverError(ctx);
    json.appendRawJsonOr(&out, ctx.allocator, input.scopes_json, "[]") catch return serverError(ctx);
    out.print(ctx.allocator, ",\"persisted\":{s},\"created_at_ms\":{d},\"object_count\":{d},\"summary\":", .{ if (persist_snapshot) "true" else "false", snapshot.created_at_ms, results.len }) catch return serverError(ctx);
    json.appendRawJsonOr(&out, ctx.allocator, summary_json, "{}") catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"objects\":") catch return serverError(ctx);
    appendSearchArray(ctx, &out, results) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, "}}") catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn lifecycleSnapshotImport(ctx: *Context, body: []const u8) HttpResponse {
    if (!hasCapability(ctx, "write") and !hasCapability(ctx, "propose")) return forbidden(ctx);
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const objects_value = obj.get("objects") orelse return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing objects");
    const objects = switch (objects_value) {
        .array => |a| a,
        else => return badJson(ctx),
    };
    const default_scope = json.stringField(obj, "default_scope") orelse "workspace";
    const default_permissions = rawField(ctx.allocator, obj, "default_permissions", "[]") catch return serverError(ctx);
    const created_by = json.stringField(obj, "created_by") orelse "agent";

    var prepared: std.ArrayListUnmanaged(store_mod.PreparedMemoryImport) = .empty;
    errdefer prepared.deinit(ctx.allocator);
    for (objects.items) |item| {
        if (item != .object) continue;
        const source_obj = item.object;
        const text = json.stringField(source_obj, "text") orelse continue;
        const title = json.stringField(source_obj, "title") orelse json.stringField(source_obj, "id") orelse "snapshot object";
        const result_type = json.stringField(source_obj, "type") orelse json.stringField(source_obj, "result_type") orelse "snapshot";
        const scope = json.stringField(source_obj, "scope") orelse default_scope;
        const permissions_json = rawField(ctx.allocator, source_obj, "permissions", default_permissions) catch return serverError(ctx);
        var source_ids_json = rawField(ctx.allocator, source_obj, "citations", "[]") catch return serverError(ctx);
        const has_valid_sources = jsonArrayHasStringItems(ctx.allocator, source_ids_json) and sourceIdsCanBackRecord(ctx, source_ids_json, scope, permissions_json);
        if (!has_valid_sources) source_ids_json = "[]";
        const status = normalizedImportedMemoryStatus(json.stringField(source_obj, "status"));
        const predicate = std.fmt.allocPrint(ctx.allocator, "imported:{s}", .{result_type}) catch return serverError(ctx);
        var input = store_mod.MemoryAtomInput{
            .predicate = predicate,
            .object = title,
            .text = text,
            .scope = scope,
            .confidence = json.floatField(source_obj, "confidence") orelse 0.55,
            .status = status,
            .source_ids_json = source_ids_json,
            .created_by = created_by,
            .permissions_json = permissions_json,
            .tags_json = "[\"snapshot_import\"]",
        };
        var generated_source: ?store_mod.SourceInput = null;
        if (has_valid_sources) {
            if (!jsonArrayHasStringItems(ctx.allocator, input.evidence_ranges_json) and !jsonArrayHasObjectItems(ctx.allocator, input.evidence_ranges_json)) {
                const first_source = firstJsonStringDup(ctx.allocator, input.source_ids_json) catch return serverError(ctx);
                input.evidence_ranges_json = evidenceJson(ctx.allocator, first_source orelse "", input.text.len, "snapshot_import") catch return serverError(ctx);
            }
        } else {
            generated_source = .{
                .source_type = "snapshot_import",
                .title = title,
                .content = text,
                .author = json.nullableStringField(source_obj, "owner"),
                .permissions_json = permissions_json,
                .scope = scope,
                .metadata_json = "{\"generated_for\":\"snapshot_import\"}",
            };
        }
        if (!canCreateMemoryAtom(ctx, input)) return forbidden(ctx);
        prepared.append(ctx.allocator, .{ .atom = input, .generated_source = generated_source }) catch return serverError(ctx);
    }
    const atoms = ctx.store.importMemoryAtomsAtomic(ctx.allocator, prepared.items) catch return serverError(ctx);
    var imported_ids: std.ArrayListUnmanaged(u8) = .empty;
    imported_ids.append(ctx.allocator, '[') catch return serverError(ctx);
    for (atoms, 0..) |atom, i| {
        if (i > 0) imported_ids.append(ctx.allocator, ',') catch return serverError(ctx);
        json.appendString(&imported_ids, ctx.allocator, atom.id) catch return serverError(ctx);
    }
    imported_ids.append(ctx.allocator, ']') catch return serverError(ctx);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.print(ctx.allocator, "{{\"imported\":{d},\"atomic\":true,\"memory_atom_ids\":", .{atoms.len}) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, imported_ids.items) catch return serverError(ctx);
    out.append(ctx.allocator, '}') catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn normalizedImportedMemoryStatus(status: ?[]const u8) ?[]const u8 {
    const value = status orelse return null;
    if (std.mem.eql(u8, value, "accepted")) return "verified";
    if (std.mem.eql(u8, value, "verified") or
        std.mem.eql(u8, value, "proposed") or
        std.mem.eql(u8, value, "stale") or
        std.mem.eql(u8, value, "deprecated") or
        std.mem.eql(u8, value, "rejected") or
        std.mem.eql(u8, value, "superseded"))
    {
        return value;
    }
    return null;
}

fn snapshotSummaryJson(ctx: *Context, scopes_json: []const u8, query: []const u8, results: []const domain.SearchResult) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.appendSlice(ctx.allocator, "{\"query\":");
    try json.appendString(&out, ctx.allocator, query);
    try out.appendSlice(ctx.allocator, ",\"scopes\":");
    try json.appendRawJsonOr(&out, ctx.allocator, scopes_json, "[]");
    try out.print(ctx.allocator, ",\"object_count\":{d},\"counts\":{{", .{results.len});
    const types = [_][]const u8{ "memory_atom", "space", "policy_scope", "source", "artifact", "entity", "relation", "context_pack", "feed_event", "session_message" };
    for (types, 0..) |kind, i| {
        if (i > 0) try out.append(ctx.allocator, ',');
        try json.appendString(&out, ctx.allocator, kind);
        try out.append(ctx.allocator, ':');
        try out.print(ctx.allocator, "{d}", .{countSearchResultsOfType(results, kind)});
    }
    try out.appendSlice(ctx.allocator, "}}");
    return out.toOwnedSlice(ctx.allocator);
}

fn countSearchResultsOfType(results: []const domain.SearchResult, result_type: []const u8) usize {
    var count: usize = 0;
    for (results) |result| {
        if (std.mem.eql(u8, result.result_type, result_type)) count += 1;
    }
    return count;
}

fn responseCachePut(ctx: *Context, body: []const u8) HttpResponse {
    if (!hasCapability(ctx, "write")) return forbidden(ctx);
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const cache_key = json.stringField(obj, "key") orelse json.stringField(obj, "cache_key") orelse return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing cache key");
    const response_json = rawField(ctx.allocator, obj, "response", "{}") catch return serverError(ctx);
    ctx.store.putResponseCache(.{
        .cache_key = cache_key,
        .response_json = response_json,
        .scopes_json = effectiveScopes(ctx, obj) catch return serverError(ctx),
        .actor_id = ctx.actor_id,
        .ttl_ms = json.intField(obj, "ttl_ms") orelse 0,
    }) catch return serverError(ctx);
    return ok(ctx, "{\"ok\":true,\"cached\":true}");
}

fn responseCacheGet(ctx: *Context, body: []const u8) HttpResponse {
    if (!hasCapability(ctx, "read")) return forbidden(ctx);
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const cache_key = json.stringField(obj, "key") orelse json.stringField(obj, "cache_key") orelse return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing cache key");
    const entry = ctx.store.getResponseCacheForScopes(ctx.allocator, cache_key, ids.nowMs(), effectiveScopes(ctx, obj) catch return serverError(ctx), ctx.actor_id) catch return serverError(ctx);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ctx.allocator, "{\"hit\":") catch return serverError(ctx);
    if (entry) |hit| {
        out.appendSlice(ctx.allocator, "true,\"cache_key\":") catch return serverError(ctx);
        json.appendString(&out, ctx.allocator, hit.cache_key) catch return serverError(ctx);
        out.appendSlice(ctx.allocator, ",\"scopes\":") catch return serverError(ctx);
        json.appendRawJsonOr(&out, ctx.allocator, hit.scopes_json, "[]") catch return serverError(ctx);
        out.appendSlice(ctx.allocator, ",\"response\":") catch return serverError(ctx);
        json.appendRawJsonOr(&out, ctx.allocator, hit.response_json, "{}") catch return serverError(ctx);
        out.print(ctx.allocator, ",\"created_at_ms\":{d},\"expires_at_ms\":{d}", .{ hit.created_at_ms, hit.expires_at_ms }) catch return serverError(ctx);
    } else {
        out.appendSlice(ctx.allocator, "false") catch return serverError(ctx);
    }
    out.append(ctx.allocator, '}') catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn semanticCachePut(ctx: *Context, body: []const u8) HttpResponse {
    if (!hasCapability(ctx, "write")) return forbidden(ctx);
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const cache_key = json.stringField(obj, "key") orelse json.stringField(obj, "cache_key") orelse return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing cache key");
    const query = json.stringField(obj, "query") orelse "";
    const response_json = rawField(ctx.allocator, obj, "response", "{}") catch return serverError(ctx);
    const embedding_json = if (obj.get("embedding") != null)
        rawField(ctx.allocator, obj, "embedding", "[]") catch return serverError(ctx)
    else blk: {
        const embedding = vector_mod.deterministicEmbedding(ctx.allocator, query, 64) catch return serverError(ctx);
        break :blk vector_mod.embeddingToJson(ctx.allocator, embedding) catch return serverError(ctx);
    };
    ctx.store.putSemanticCache(.{
        .cache_key = cache_key,
        .query = query,
        .response_json = response_json,
        .embedding_json = embedding_json,
        .scopes_json = effectiveScopes(ctx, obj) catch return serverError(ctx),
        .actor_id = ctx.actor_id,
        .ttl_ms = json.intField(obj, "ttl_ms") orelse 0,
    }) catch return serverError(ctx);
    return ok(ctx, "{\"ok\":true,\"cached\":true}");
}

fn semanticCacheSearch(ctx: *Context, body: []const u8) HttpResponse {
    if (!hasCapability(ctx, "read")) return forbidden(ctx);
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const embedding_json = if (obj.get("embedding") != null)
        rawField(ctx.allocator, obj, "embedding", "[]") catch return serverError(ctx)
    else blk: {
        const query = json.stringField(obj, "query") orelse return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing query or embedding");
        const embedding = vector_mod.deterministicEmbedding(ctx.allocator, query, 64) catch return serverError(ctx);
        break :blk vector_mod.embeddingToJson(ctx.allocator, embedding) catch return serverError(ctx);
    };
    const match = ctx.store.searchSemanticCache(ctx.allocator, .{
        .embedding_json = embedding_json,
        .scopes_json = effectiveScopes(ctx, obj) catch return serverError(ctx),
        .actor_id = ctx.actor_id,
        .min_score = @floatCast(json.floatField(obj, "min_score") orelse 0.82),
    }) catch return serverError(ctx);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ctx.allocator, "{\"hit\":") catch return serverError(ctx);
    if (match) |hit| {
        out.appendSlice(ctx.allocator, "true,\"cache_key\":") catch return serverError(ctx);
        json.appendString(&out, ctx.allocator, hit.cache_key) catch return serverError(ctx);
        out.appendSlice(ctx.allocator, ",\"query\":") catch return serverError(ctx);
        json.appendString(&out, ctx.allocator, hit.query) catch return serverError(ctx);
        out.appendSlice(ctx.allocator, ",\"scopes\":") catch return serverError(ctx);
        json.appendRawJsonOr(&out, ctx.allocator, hit.scopes_json, "[]") catch return serverError(ctx);
        out.appendSlice(ctx.allocator, ",\"response\":") catch return serverError(ctx);
        json.appendRawJsonOr(&out, ctx.allocator, hit.response_json, "{}") catch return serverError(ctx);
        out.print(ctx.allocator, ",\"score\":{d},\"created_at_ms\":{d},\"expires_at_ms\":{d}", .{ hit.score, hit.created_at_ms, hit.expires_at_ms }) catch return serverError(ctx);
    } else {
        out.appendSlice(ctx.allocator, "false") catch return serverError(ctx);
    }
    out.append(ctx.allocator, '}') catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn lifecycleHygiene(ctx: *Context, body: []const u8) HttpResponse {
    if (!hasCapability(ctx, "verify") and !hasCapability(ctx, "delete")) return forbidden(ctx);
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const result = ctx.store.runHygiene(.{
        .stale_after_ms = json.intField(obj, "stale_after_ms") orelse 30 * 24 * 60 * 60 * 1000,
        .archive_after_ms = json.intField(obj, "archive_after_ms") orelse 90 * 24 * 60 * 60 * 1000,
        .purge_after_ms = json.intField(obj, "purge_after_ms") orelse 0,
        .hard_delete = json.boolField(obj, "hard_delete") orelse false,
        .scopes_json = ctx.actor_scopes_json,
        .capabilities_json = ctx.actor_capabilities_json,
    }) catch return serverError(ctx);
    const response = std.fmt.allocPrint(
        ctx.allocator,
        "{{\"hygiene\":{{\"checked\":{d},\"marked_stale\":{d},\"archived\":{d},\"purged\":{d},\"expired_cache_entries\":{d}}}}}",
        .{ result.checked, result.marked_stale, result.archived, result.purged, result.expired_cache_entries },
    ) catch return serverError(ctx);
    return .{ .status = "200 OK", .body = response };
}

fn lifecycleSummarize(ctx: *Context, body: []const u8) HttpResponse {
    if (!hasCapability(ctx, "read")) return forbidden(ctx);
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const messages_value = obj.get("messages") orelse return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing messages");
    const arr = switch (messages_value) {
        .array => |a| a,
        else => return badJson(ctx),
    };
    var messages: std.ArrayListUnmanaged([]const u8) = .empty;
    for (arr.items) |item| {
        switch (item) {
            .string => |s| messages.append(ctx.allocator, s) catch return serverError(ctx),
            .object => |message_obj| if (json.stringField(message_obj, "content")) |content| messages.append(ctx.allocator, content) catch return serverError(ctx),
            else => {},
        }
    }
    const max_chars: usize = @intCast(@max(json.intField(obj, "max_chars") orelse 4000, 1));
    const summary = lifecycle.summarizeMessages(ctx.allocator, messages.items, max_chars) catch return serverError(ctx);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ctx.allocator, "{\"summary\":") catch return serverError(ctx);
    json.appendString(&out, ctx.allocator, summary) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"message_count\":") catch return serverError(ctx);
    out.print(ctx.allocator, "{d}}}", .{messages.items.len}) catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn lifecycleRollout(ctx: *Context, body: []const u8) HttpResponse {
    if (!hasCapability(ctx, "read")) return forbidden(ctx);
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const key = json.stringField(obj, "key") orelse return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing key");
    const percent_raw = json.intField(obj, "percent") orelse 0;
    const percent: u8 = @intCast(@max(@as(i64, 0), @min(@as(i64, 100), percent_raw)));
    const enabled = lifecycle.rolloutEnabled(key, percent);
    const response = std.fmt.allocPrint(ctx.allocator, "{{\"enabled\":{s},\"percent\":{d}}}", .{ if (enabled) "true" else "false", percent }) catch return serverError(ctx);
    return .{ .status = "200 OK", .body = response };
}

fn ask(ctx: *Context, body: []const u8) HttpResponse {
    if (!hasCapability(ctx, "read")) return forbidden(ctx);
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    if (obj.get("llm_base_url") != null or obj.get("llm_api_key") != null or obj.get("llm_model") != null or obj.get("timeout_secs") != null) {
        return json.errorResponse(ctx.allocator, 400, "bad_request", "Provider overrides are not allowed; configure providers on the server");
    }
    const query = json.stringField(obj, "query") orelse json.stringField(obj, "question") orelse "";
    const scopes_json = effectiveScopes(ctx, obj) catch return serverError(ctx);
    var input = buildSearchInput(ctx, obj, query, 6, false) catch return serverError(ctx);
    input.scopes_json = scopes_json;
    const include_conflicts = json.boolField(obj, "include_conflicts") orelse true;
    const scan_conflicts = json.boolField(obj, "scan_conflicts") orelse false;
    if (scan_conflicts and !hasCapability(ctx, "verify") and !hasCapability(ctx, "write")) return forbidden(ctx);
    const use_cache = json.boolField(obj, "use_cache") orelse true;
    const use_semantic_cache = json.boolField(obj, "use_semantic_cache") orelse false;
    const cache_ttl_ms = json.intField(obj, "cache_ttl_ms") orelse 0;
    const cache_key = automaticCacheKey(ctx.allocator, "ask", ctx.actor_id, scopes_json, body) catch return serverError(ctx);
    if (use_cache and !scan_conflicts) {
        if (ctx.store.getResponseCacheForScopes(ctx.allocator, cache_key, ids.nowMs(), scopes_json, ctx.actor_id) catch return serverError(ctx)) |hit| {
            return .{ .status = "200 OK", .body = hit.response_json };
        }
        if (use_semantic_cache) {
            if (input.query_embedding_json) |embedding_json| {
                if (ctx.store.searchSemanticCache(ctx.allocator, .{ .embedding_json = embedding_json, .scopes_json = scopes_json, .actor_id = ctx.actor_id, .min_score = @floatCast(json.floatField(obj, "semantic_cache_min_score") orelse 0.94) }) catch return serverError(ctx)) |hit| {
                    return .{ .status = "200 OK", .body = hit.response_json };
                }
            }
        }
    }
    var results = ctx.store.search(ctx.allocator, input) catch |err| switch (err) {
        error.AgentMemoryStorageUnavailable => return agentMemoryStorageUnavailable(ctx),
        else => return serverError(ctx),
    };
    results = maybeLlmRerankResults(ctx, query, results, input.allow_reranker) catch results;
    const conflicts = if (include_conflicts)
        (if (scan_conflicts)
            ctx.store.scanConflicts(ctx.allocator, .{ .scopes_json = scopes_json, .status = "open", .limit = 10 }) catch return serverError(ctx)
        else
            ctx.store.listConflicts(ctx.allocator, .{ .scopes_json = scopes_json, .status = "open", .limit = 10 }) catch return serverError(ctx))
    else
        ctx.allocator.alloc(store_mod.KnowledgeConflict, 0) catch return serverError(ctx);

    var answer: std.ArrayListUnmanaged(u8) = .empty;
    var answer_provider: []const u8 = "extractive";
    if (results.len == 0) {
        if (conflicts.len == 0) {
            answer.appendSlice(ctx.allocator, "I don't know based on the accessible NullPantry knowledge.") catch return serverError(ctx);
        } else {
            answer.appendSlice(ctx.allocator, "Accessible NullPantry knowledge contains potential conflicts: ") catch return serverError(ctx);
            for (conflicts, 0..) |conflict, i| {
                if (i > 0) answer.appendSlice(ctx.allocator, " ") catch return serverError(ctx);
                answer.appendSlice(ctx.allocator, conflict.summary) catch return serverError(ctx);
                answer.appendSlice(ctx.allocator, " [") catch return serverError(ctx);
                answer.appendSlice(ctx.allocator, conflict.id) catch return serverError(ctx);
                answer.appendSlice(ctx.allocator, "]") catch return serverError(ctx);
            }
        }
    } else {
        const use_llm = json.boolField(obj, "use_llm") orelse false;
        if (use_llm) {
            const prompt = buildAskPrompt(ctx, query, results) catch return serverError(ctx);
            if (providers.completeAnswer(ctx.allocator, .{
                .base_url = ctx.llm_base_url,
                .api_key = ctx.llm_api_key,
                .model = ctx.llm_model,
                .timeout_secs = ctx.provider_timeout_secs,
            }, prompt)) |completion| {
                if (answerCitationsValid(ctx, completion.content, results) catch false) {
                    answer_provider = completion.provider;
                    answer.appendSlice(ctx.allocator, completion.content) catch return serverError(ctx);
                } else {
                    answer_provider = "extractive_citation_guard";
                    writeExtractiveAnswer(ctx, &answer, results) catch return serverError(ctx);
                }
            } else |_| {
                writeExtractiveAnswer(ctx, &answer, results) catch return serverError(ctx);
            }
        } else {
            writeExtractiveAnswer(ctx, &answer, results) catch return serverError(ctx);
        }
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ctx.allocator, "{\"answer\":") catch return serverError(ctx);
    json.appendString(&out, ctx.allocator, answer.items) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"answer_provider\":") catch return serverError(ctx);
    json.appendString(&out, ctx.allocator, answer_provider) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"confidence\":") catch return serverError(ctx);
    out.appendSlice(ctx.allocator, if (results.len == 0 and conflicts.len == 0) "0" else if (results.len == 0) "0.3" else "0.7") catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"warnings\":") catch return serverError(ctx);
    appendAskWarnings(ctx, &out, results, conflicts) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"results\":") catch return serverError(ctx);
    appendSearchArray(ctx, &out, results) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"conflicts\":") catch return serverError(ctx);
    appendConflictsArray(ctx, &out, conflicts) catch return serverError(ctx);
    out.append(ctx.allocator, '}') catch return serverError(ctx);
    const response_body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx);
    if (cache_ttl_ms > 0 and hasCapability(ctx, "write") and !scan_conflicts) {
        ctx.store.putResponseCache(.{ .cache_key = cache_key, .response_json = response_body, .scopes_json = scopes_json, .actor_id = ctx.actor_id, .ttl_ms = cache_ttl_ms }) catch return serverError(ctx);
        if (use_semantic_cache) {
            if (input.query_embedding_json) |embedding_json| {
                ctx.store.putSemanticCache(.{ .cache_key = cache_key, .query = query, .response_json = response_body, .embedding_json = embedding_json, .scopes_json = scopes_json, .actor_id = ctx.actor_id, .ttl_ms = cache_ttl_ms }) catch return serverError(ctx);
            }
        }
    }
    return .{ .status = "200 OK", .body = response_body };
}

fn writeExtractiveAnswer(ctx: *Context, out: *std.ArrayListUnmanaged(u8), results: []domain.SearchResult) !void {
    try out.appendSlice(ctx.allocator, "Based on accessible NullPantry evidence: ");
    for (results, 0..) |result, i| {
        if (i > 0) try out.appendSlice(ctx.allocator, " ");
        try out.appendSlice(ctx.allocator, result.text);
        try out.appendSlice(ctx.allocator, " [");
        try out.appendSlice(ctx.allocator, try citationLabel(ctx, result));
        try out.appendSlice(ctx.allocator, "]");
    }
}

fn buildAskPrompt(ctx: *Context, query: []const u8, results: []domain.SearchResult) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(ctx.allocator);
    try out.appendSlice(ctx.allocator, "Question:\n");
    try out.appendSlice(ctx.allocator, query);
    try out.appendSlice(ctx.allocator, "\n\nAccessible context with citations:\n");
    for (results) |result| {
        try out.appendSlice(ctx.allocator, "- [");
        try out.appendSlice(ctx.allocator, try citationLabel(ctx, result));
        try out.appendSlice(ctx.allocator, "] ");
        try out.appendSlice(ctx.allocator, result.result_type);
        try out.appendSlice(ctx.allocator, " status=");
        try out.appendSlice(ctx.allocator, result.status);
        try out.appendSlice(ctx.allocator, " title=");
        try out.appendSlice(ctx.allocator, result.title);
        try out.appendSlice(ctx.allocator, "\n  ");
        try out.appendSlice(ctx.allocator, result.text);
        try out.appendSlice(ctx.allocator, "\n");
    }
    try out.appendSlice(ctx.allocator, "\nAnswer with citations in square brackets.");
    return out.toOwnedSlice(ctx.allocator);
}

fn maybeLlmRerankResults(ctx: *Context, query: []const u8, results: []domain.SearchResult, enabled: bool) ![]domain.SearchResult {
    if (!enabled or results.len <= 1 or ctx.llm_base_url == null or ctx.llm_model == null) return results;
    const prompt = try buildRerankPrompt(ctx.allocator, query, results);
    const completion = providers.completeAnswer(ctx.allocator, .{
        .base_url = ctx.llm_base_url,
        .api_key = ctx.llm_api_key,
        .model = ctx.llm_model,
        .timeout_secs = ctx.provider_timeout_secs,
    }, prompt) catch return results;
    return parseRerankOrder(ctx.allocator, completion.content, results) catch results;
}

fn buildRerankPrompt(allocator: std.mem.Allocator, query: []const u8, results: []domain.SearchResult) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "Rerank these retrieval candidates for the query. Return only a JSON array of candidate ids, best first.\nQuery: ");
    try out.appendSlice(allocator, query);
    try out.appendSlice(allocator, "\nCandidates:\n");
    const max_candidates = @min(results.len, @as(usize, 24));
    for (results[0..max_candidates]) |result| {
        try out.appendSlice(allocator, "- id=");
        try out.appendSlice(allocator, result.id);
        try out.appendSlice(allocator, " type=");
        try out.appendSlice(allocator, result.result_type);
        try out.appendSlice(allocator, " status=");
        try out.appendSlice(allocator, result.status);
        try out.appendSlice(allocator, " title=");
        try out.appendSlice(allocator, result.title);
        try out.appendSlice(allocator, "\n  ");
        try out.appendSlice(allocator, result.text[0..@min(result.text.len, 512)]);
        try out.appendSlice(allocator, "\n");
    }
    return out.toOwnedSlice(allocator);
}

fn parseRerankOrder(allocator: std.mem.Allocator, llm_output: []const u8, results: []const domain.SearchResult) ![]domain.SearchResult {
    const selected = try allocator.alloc(bool, results.len);
    errdefer allocator.free(selected);
    @memset(selected, false);
    var out: std.ArrayListUnmanaged(domain.SearchResult) = .empty;
    errdefer out.deinit(allocator);

    if (std.json.parseFromSlice(std.json.Value, allocator, llm_output, .{})) |parsed| {
        defer parsed.deinit();
        if (parsed.value == .array) {
            for (parsed.value.array.items) |item| {
                const id_text = switch (item) {
                    .string => |s| s,
                    else => continue,
                };
                try appendRerankedResult(allocator, &out, results, selected, id_text);
            }
        }
    } else |_| {
        var it = std.mem.tokenizeAny(u8, llm_output, " \t\r\n,;[]{}()\"'");
        while (it.next()) |token| {
            try appendRerankedResult(allocator, &out, results, selected, token);
        }
    }

    for (results, 0..) |result, i| {
        if (selected[i]) continue;
        try out.append(allocator, result);
    }
    allocator.free(selected);
    return out.toOwnedSlice(allocator);
}

fn appendRerankedResult(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(domain.SearchResult),
    results: []const domain.SearchResult,
    selected: []bool,
    id_text: []const u8,
) !void {
    for (results, 0..) |result, i| {
        if (selected[i]) continue;
        if (!std.mem.eql(u8, result.id, id_text)) continue;
        selected[i] = true;
        try out.append(allocator, result);
        return;
    }
}

fn citationLabel(ctx: *Context, result: domain.SearchResult) ![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, result.source_ids_json, .{}) catch return result.id;
    defer parsed.deinit();
    if (parsed.value != .array) return result.id;
    for (parsed.value.array.items) |item| {
        if (item == .string and item.string.len > 0) return try ctx.allocator.dupe(u8, item.string);
    }
    return result.id;
}

fn answerCitationsValid(ctx: *Context, answer: []const u8, results: []const domain.SearchResult) !bool {
    var saw_citation = false;
    var start: usize = 0;
    while (std.mem.indexOfScalarPos(u8, answer, start, '[')) |open| {
        const close = std.mem.indexOfScalarPos(u8, answer, open + 1, ']') orelse return false;
        const body = std.mem.trim(u8, answer[open + 1 .. close], " \t\r\n");
        if (body.len == 0) {
            start = close + 1;
            continue;
        }
        var tokens = std.mem.tokenizeAny(u8, body, ",; \t\r\n");
        var token_count: usize = 0;
        var citation_token_count: usize = 0;
        while (tokens.next()) |token| {
            token_count += 1;
            if (!looksLikeCitationToken(token)) continue;
            citation_token_count += 1;
            if (!(try citationTokenAllowed(ctx, token, results))) return false;
            saw_citation = true;
        }
        if (token_count == 0 or citation_token_count == 0) {
            start = close + 1;
            continue;
        }
        start = close + 1;
    }
    return saw_citation;
}

fn looksLikeCitationToken(token: []const u8) bool {
    const prefixes = [_][]const u8{ "src_", "art_", "mem_", "ent_", "rel_", "ctx_", "spc_", "pol_", "agm_", "policy:", "feed:", "session:" };
    inline for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, token, prefix)) return true;
    }
    return false;
}

fn citationTokenAllowed(ctx: *Context, token: []const u8, results: []const domain.SearchResult) !bool {
    for (results) |result| {
        if (std.mem.eql(u8, token, result.id)) return true;
        const label = try citationLabel(ctx, result);
        if (std.mem.eql(u8, token, label)) return true;
    }
    return false;
}

fn appendAskWarnings(ctx: *Context, out: *std.ArrayListUnmanaged(u8), results: []domain.SearchResult, conflicts: []store_mod.KnowledgeConflict) !void {
    try out.append(ctx.allocator, '[');
    var first = true;
    for (results) |result| {
        if (std.mem.eql(u8, result.status, "stale") or std.mem.eql(u8, result.status, "deprecated") or std.mem.eql(u8, result.status, "superseded")) {
            if (!first) try out.append(ctx.allocator, ',');
            first = false;
            try out.appendSlice(ctx.allocator, "{\"type\":\"stale_or_deprecated\",\"object_id\":");
            try json.appendString(out, ctx.allocator, result.id);
            try out.appendSlice(ctx.allocator, ",\"status\":");
            try json.appendString(out, ctx.allocator, result.status);
            try out.append(ctx.allocator, '}');
        }
    }
    if (conflicts.len > 0) {
        if (!first) try out.append(ctx.allocator, ',');
        try out.appendSlice(ctx.allocator, "{\"type\":\"potential_conflicts\",\"count\":");
        try out.print(ctx.allocator, "{d}", .{conflicts.len});
        try out.append(ctx.allocator, '}');
    }
    try out.append(ctx.allocator, ']');
}

fn appendConflictsArray(ctx: *Context, out: *std.ArrayListUnmanaged(u8), conflicts: []store_mod.KnowledgeConflict) !void {
    try out.append(ctx.allocator, '[');
    for (conflicts, 0..) |conflict, i| {
        if (i > 0) try out.append(ctx.allocator, ',');
        try conflict.writeJson(ctx.allocator, out);
    }
    try out.append(ctx.allocator, ']');
}

fn contextPack(ctx: *Context, body: []const u8) HttpResponse {
    if (!hasCapability(ctx, "read")) return forbidden(ctx);
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const query = json.stringField(obj, "query") orelse json.stringField(obj, "task") orelse return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing query");
    const persist = json.boolField(obj, "persist") orelse (hasCapability(ctx, "write") or hasCapability(ctx, "propose"));
    if (persist and !hasCapability(ctx, "write") and !hasCapability(ctx, "propose")) return forbidden(ctx);
    const search_input = buildSearchInput(ctx, obj, query, positiveLimit(json.intField(obj, "limit"), 40), false) catch return serverError(ctx);
    const pack = ctx.store.createContextPack(ctx.allocator, .{
        .purpose = json.stringField(obj, "purpose") orelse "task",
        .target = json.stringField(obj, "target") orelse "agent",
        .query = query,
        .token_budget = json.intField(obj, "token_budget") orelse 12000,
        .scopes_json = search_input.scopes_json,
        .query_embedding_json = search_input.query_embedding_json,
        .query_embedding_provider = search_input.query_embedding_provider,
        .embedding_dimensions = search_input.embedding_dimensions,
        .persist = persist,
        .include_sessions = search_input.include_sessions,
        .session_id = search_input.session_id,
        .retrieval_limit = search_input.limit,
        .include_deprecated = search_input.include_deprecated,
        .use_vector = search_input.use_vector,
        .use_temporal_decay = search_input.use_temporal_decay,
        .use_mmr = search_input.use_mmr,
        .allow_reranker = search_input.allow_reranker,
        .actor_id = ctx.actor_id,
        .agent_memory_route = search_input.agent_memory_route,
    }) catch |err| switch (err) {
        error.AgentMemoryStorageUnavailable => return agentMemoryStorageUnavailable(ctx),
        else => return serverError(ctx),
    };
    if (pack.persisted) {
        if (ctx.store.vectorObjectAcl(ctx.allocator, "context_pack", pack.id, ctx.actor_id) catch null) |acl| {
            const text = vector_text.contextPack(ctx.allocator, pack) catch return serverError(ctx);
            _ = upsertAutoVector(ctx, "context_pack", pack.id, text, acl.scope, acl.permissions_json) catch 0;
        }
    }
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ctx.allocator, "{\"context_pack\":{\"id\":") catch return serverError(ctx);
    json.appendString(&out, ctx.allocator, pack.id) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"purpose\":") catch return serverError(ctx);
    json.appendString(&out, ctx.allocator, pack.purpose) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"target\":") catch return serverError(ctx);
    json.appendString(&out, ctx.allocator, pack.target) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"query\":") catch return serverError(ctx);
    json.appendString(&out, ctx.allocator, pack.query) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"persisted\":") catch return serverError(ctx);
    out.appendSlice(ctx.allocator, if (pack.persisted) "true" else "false") catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"included_sources\":") catch return serverError(ctx);
    out.appendSlice(ctx.allocator, pack.included_sources_json) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"included_artifacts\":") catch return serverError(ctx);
    out.appendSlice(ctx.allocator, pack.included_artifacts_json) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"included_memory_atoms\":") catch return serverError(ctx);
    out.appendSlice(ctx.allocator, pack.included_memory_atoms_json) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"included_result_refs\":") catch return serverError(ctx);
    json.appendRawJsonOr(&out, ctx.allocator, pack.included_result_refs_json, "[]") catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"generated_summary\":") catch return serverError(ctx);
    json.appendString(&out, ctx.allocator, pack.generated_summary) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"sections\":") catch return serverError(ctx);
    json.appendRawJsonOr(&out, ctx.allocator, pack.sections_json, "{}") catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"citations\":") catch return serverError(ctx);
    json.appendRawJsonOr(&out, ctx.allocator, pack.citations_json, "[]") catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"forbidden_assumptions\":") catch return serverError(ctx);
    json.appendRawJsonOr(&out, ctx.allocator, pack.forbidden_assumptions_json, "[]") catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"suggested_next_steps\":") catch return serverError(ctx);
    json.appendRawJsonOr(&out, ctx.allocator, pack.suggested_next_steps_json, "[]") catch return serverError(ctx);
    out.print(ctx.allocator, ",\"token_budget\":{d},\"created_at_ms\":{d}}}", .{ pack.token_budget, pack.created_at_ms }) catch return serverError(ctx);
    out.append(ctx.allocator, '}') catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn agentMemoryStoreBody(ctx: *Context, body: []const u8) HttpResponse {
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const key = json.stringField(parsed.value.object, "key") orelse return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing key");
    return agentMemoryStoreParsed(ctx, key, parsed.value.object);
}

fn agentMemoryStoreKey(ctx: *Context, key: []const u8, body: []const u8) HttpResponse {
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    return agentMemoryStoreParsed(ctx, key, parsed.value.object);
}

fn agentMemoryStoreParsed(ctx: *Context, key: []const u8, obj: std.json.ObjectMap) HttpResponse {
    if (!(hasCapability(ctx, "write") or hasCapability(ctx, "propose"))) return forbidden(ctx);
    const operation = domain.AgentMemoryOperation.parse(json.stringField(obj, "operation") orelse "put");
    const content = switch (operation) {
        .put => json.stringField(obj, "content") orelse json.stringField(obj, "text") orelse return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing content"),
        .merge_string_set => agent_memory_reducer.stringSetPatchFromObject(ctx.allocator, obj) catch return json.errorResponse(ctx.allocator, 400, "bad_request", "Invalid string-set merge payload"),
        .merge_object => agent_memory_reducer.objectPatchFromObject(ctx.allocator, obj) catch return json.errorResponse(ctx.allocator, 400, "bad_request", "Invalid object merge payload"),
    };
    const session_id = json.nullableStringField(obj, "session_id");
    if (session_id) |sid| {
        if (!agentSessionWriteAllowed(ctx, sid)) return forbidden(ctx);
    }
    const permissions = rawField(ctx.allocator, obj, "permissions", "[]") catch return serverError(ctx);
    const scope = json.nullableStringField(obj, "scope");
    if (scope) |requested_scope| {
        if (!canCreateMemoryAtom(ctx, .{ .text = content, .scope = requested_scope, .permissions_json = permissions, .created_by = "agent", .actor_id = ctx.actor_id })) return forbidden(ctx);
    } else if (!domain.permissionsAreOpen(permissions) and !domain.permissionsWritable(permissions, ctx.actor_scopes_json)) {
        return forbidden(ctx);
    }
    const storage_target = agentMemoryStorageTargetFromObject(ctx.allocator, obj) catch return serverError(ctx);
    const owner_actor_id = access.agentMemoryOwner(ctx.allocator, ctx.actor_id, scope) catch return serverError(ctx);
    const entry = ctx.store.agentMemoryStoreRouted(ctx.allocator, .{
        .key = key,
        .content = content,
        .category = json.stringField(obj, "category") orelse "core",
        .session_id = session_id,
        .scope = scope,
        .permissions_json = permissions,
        .metadata_json = rawField(ctx.allocator, obj, "metadata", "{}") catch return serverError(ctx),
        .actor_id = owner_actor_id,
        .writer_actor_id = ctx.actor_id,
        .operation = operation,
    }, storage_target) catch |err| switch (err) {
        error.AgentMemoryStorageUnavailable => return agentMemoryStorageUnavailable(ctx),
        else => return serverError(ctx),
    };
    _ = upsertAutoVector(ctx, "agent_memory", entry.id, entry.content, entry.scope, entry.permissions_json) catch 0;
    return agentMemoryEntryResponse(ctx, "memory", entry);
}

fn agentMemoryGet(ctx: *Context, key: []const u8, query: []const u8) HttpResponse {
    if (!hasCapability(ctx, "read")) return forbidden(ctx);
    const session_id = json.queryParamDecoded(ctx.allocator, query, "session_id") catch return serverError(ctx);
    const requested_scope = json.queryParamDecoded(ctx.allocator, query, "scope") catch return serverError(ctx);
    if (session_id) |sid| {
        if (!agentSessionReadAllowed(ctx, sid)) return forbidden(ctx);
    }
    const storage_target = agentMemoryStorageTargetFromQuery(ctx.allocator, query) catch return serverError(ctx);
    const entry = if (requested_scope) |scope| blk: {
        const owner_actor_id = access.agentMemoryOwner(ctx.allocator, ctx.actor_id, scope) catch return serverError(ctx);
        break :blk ctx.store.agentMemoryGetRouted(ctx.allocator, key, session_id, owner_actor_id, storage_target) catch |err| switch (err) {
            error.AgentMemoryStorageUnavailable => return agentMemoryStorageUnavailable(ctx),
            else => return serverError(ctx),
        };
    } else ctx.store.agentMemoryGetVisibleRouted(ctx.allocator, key, session_id, ctx.actor_id, ctx.actor_scopes_json, storage_target) catch |err| switch (err) {
        error.AgentMemoryStorageUnavailable => return agentMemoryStorageUnavailable(ctx),
        else => return serverError(ctx),
    };
    if (entry == null) return json.errorResponse(ctx.allocator, 404, "not_found", "Agent memory not found");
    if (!agentMemoryEntryVisible(ctx, entry.?)) return json.errorResponse(ctx.allocator, 404, "not_found", "Agent memory not found");
    return agentMemoryEntryResponse(ctx, "memory", entry.?);
}

fn agentMemoryList(ctx: *Context, query: []const u8) HttpResponse {
    if (!hasCapability(ctx, "read")) return forbidden(ctx);
    const category = json.queryParamDecoded(ctx.allocator, query, "category") catch return serverError(ctx);
    const session_id = json.queryParamDecoded(ctx.allocator, query, "session_id") catch return serverError(ctx);
    if (session_id) |sid| {
        if (!agentSessionReadAllowed(ctx, sid)) return forbidden(ctx);
    }
    const include_global = queryBool(query, "include_global", false);
    const include_internal = queryBool(query, "include_internal", false);
    const limit = parseLimit(json.queryParam(query, "limit"), 100);
    const offset = parseLimit(json.queryParam(query, "offset"), 0);
    const storage_target = agentMemoryStorageTargetFromQuery(ctx.allocator, query) catch return serverError(ctx);
    var entries: std.ArrayListUnmanaged(domain.AgentMemory) = .empty;
    const primary = ctx.store.agentMemoryListVisibleRouted(ctx.allocator, category, session_id, ctx.actor_id, ctx.actor_scopes_json, storage_target) catch |err| switch (err) {
        error.AgentMemoryStorageUnavailable => return agentMemoryStorageUnavailable(ctx),
        else => return serverError(ctx),
    };
    appendAgentMemoryEntries(ctx.allocator, &entries, primary) catch return serverError(ctx);
    if (include_global and session_id != null) {
        const global = ctx.store.agentMemoryListVisibleRouted(ctx.allocator, category, null, ctx.actor_id, ctx.actor_scopes_json, storage_target) catch |err| switch (err) {
            error.AgentMemoryStorageUnavailable => return agentMemoryStorageUnavailable(ctx),
            else => return serverError(ctx),
        };
        appendMissingAgentMemoryEntries(ctx.allocator, &entries, global) catch return serverError(ctx);
    }
    dedupeAgentMemoryEntries(ctx.allocator, &entries);
    return agentMemoryEntriesResponseFiltered(ctx, entries.items, include_internal, limit, offset);
}

fn agentMemorySearch(ctx: *Context, body: []const u8) HttpResponse {
    if (!hasCapability(ctx, "read")) return forbidden(ctx);
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const session_id = json.nullableStringField(obj, "session_id");
    if (session_id) |sid| {
        if (!agentSessionReadAllowed(ctx, sid)) return forbidden(ctx);
    }
    const query = json.stringField(obj, "query") orelse json.stringField(obj, "q") orelse "";
    const scopes_json = effectiveScopes(ctx, obj) catch return serverError(ctx);
    const limit = positiveLimit(json.intField(obj, "limit"), 10);
    const include_global = json.boolField(obj, "include_global") orelse false;
    const include_internal = json.boolField(obj, "include_internal") orelse false;
    const storage_target = agentMemoryStorageTargetFromObject(ctx.allocator, obj) catch return serverError(ctx);
    var entries: std.ArrayListUnmanaged(domain.AgentMemory) = .empty;
    const primary = ctx.store.agentMemorySearchRouted(ctx.allocator, query, limit, session_id, scopes_json, ctx.actor_id, storage_target) catch |err| switch (err) {
        error.AgentMemoryStorageUnavailable => return agentMemoryStorageUnavailable(ctx),
        else => return serverError(ctx),
    };
    appendAgentMemoryEntries(ctx.allocator, &entries, primary) catch return serverError(ctx);
    if (include_global and session_id != null) {
        const global = ctx.store.agentMemorySearchRouted(ctx.allocator, query, limit, null, scopes_json, ctx.actor_id, storage_target) catch |err| switch (err) {
            error.AgentMemoryStorageUnavailable => return agentMemoryStorageUnavailable(ctx),
            else => return serverError(ctx),
        };
        appendMissingAgentMemoryEntries(ctx.allocator, &entries, global) catch return serverError(ctx);
    }
    dedupeAgentMemoryEntries(ctx.allocator, &entries);
    return agentMemoryEntriesResponseFiltered(ctx, entries.items, include_internal, limit, 0);
}

fn agentMemoryDelete(ctx: *Context, key: []const u8, query: []const u8) HttpResponse {
    if (!hasCapability(ctx, "delete")) return forbidden(ctx);
    const session_id = json.queryParamDecoded(ctx.allocator, query, "session_id") catch return serverError(ctx);
    const requested_scope = json.queryParamDecoded(ctx.allocator, query, "scope") catch return serverError(ctx);
    if (session_id) |sid| {
        if (!agentSessionWriteAllowed(ctx, sid)) return forbidden(ctx);
    }
    const owner_actor_id = if (requested_scope) |scope|
        access.agentMemoryOwner(ctx.allocator, ctx.actor_id, scope) catch return serverError(ctx)
    else
        ctx.actor_id;
    const storage_target = agentMemoryStorageTargetFromQuery(ctx.allocator, query) catch return serverError(ctx);
    const entry = ctx.store.agentMemoryGetRouted(ctx.allocator, key, session_id, owner_actor_id, storage_target) catch |err| switch (err) {
        error.AgentMemoryStorageUnavailable => return agentMemoryStorageUnavailable(ctx),
        else => return serverError(ctx),
    };
    if (entry == null) return json.errorResponse(ctx.allocator, 404, "not_found", "Agent memory not found");
    if (!agentMemoryEntryVisible(ctx, entry.?)) return json.errorResponse(ctx.allocator, 404, "not_found", "Agent memory not found");
    if (!agentMemoryEntryDeletable(ctx, entry.?)) return forbidden(ctx);
    const deleted = ctx.store.agentMemoryDeleteRouted(key, session_id, owner_actor_id, ctx.actor_id, storage_target) catch |err| switch (err) {
        error.AgentMemoryStorageUnavailable => return agentMemoryStorageUnavailable(ctx),
        else => return serverError(ctx),
    };
    if (!deleted) return json.errorResponse(ctx.allocator, 404, "not_found", "Agent memory not found");
    return ok(ctx, "{\"ok\":true}");
}

fn agentMemoryCount(ctx: *Context, query: []const u8) HttpResponse {
    if (!hasCapability(ctx, "read")) return forbidden(ctx);
    const storage_target = agentMemoryStorageTargetFromQuery(ctx.allocator, query) catch return serverError(ctx);
    const entries = ctx.store.agentMemoryListVisibleRouted(ctx.allocator, null, null, ctx.actor_id, ctx.actor_scopes_json, storage_target) catch |err| switch (err) {
        error.AgentMemoryStorageUnavailable => return agentMemoryStorageUnavailable(ctx),
        else => return serverError(ctx),
    };
    var list: std.ArrayListUnmanaged(domain.AgentMemory) = .empty;
    appendAgentMemoryEntries(ctx.allocator, &list, entries) catch return serverError(ctx);
    dedupeAgentMemoryEntries(ctx.allocator, &list);
    const count = list.items.len;
    const body = std.fmt.allocPrint(ctx.allocator, "{{\"count\":{d}}}", .{count}) catch return serverError(ctx);
    return .{ .status = "200 OK", .body = body };
}

fn appendAgentMemoryEntries(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(domain.AgentMemory), entries: []domain.AgentMemory) !void {
    for (entries) |entry| try out.append(allocator, entry);
}

fn appendMissingAgentMemoryEntries(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(domain.AgentMemory), entries: []domain.AgentMemory) !void {
    for (entries) |entry| {
        if (agentMemoryContains(out.items, entry)) {
            var skipped = entry;
            agent_memory_runtime.freeAgentMemory(allocator, &skipped);
            continue;
        }
        try out.append(allocator, entry);
    }
}

fn dedupeAgentMemoryEntries(allocator: std.mem.Allocator, entries: *std.ArrayListUnmanaged(domain.AgentMemory)) void {
    var write: usize = 0;
    for (entries.items, 0..) |entry, read| {
        if (agentMemoryContains(entries.items[0..write], entry)) {
            var duplicate = entry;
            agent_memory_runtime.freeAgentMemory(allocator, &duplicate);
            continue;
        }
        if (write != read) entries.items[write] = entry;
        write += 1;
    }
    entries.shrinkRetainingCapacity(write);
}

fn agentMemoryContains(entries: []const domain.AgentMemory, needle: domain.AgentMemory) bool {
    for (entries) |entry| {
        if (!std.mem.eql(u8, entry.key, needle.key)) continue;
        if (!std.mem.eql(u8, entry.actor_id, needle.actor_id)) continue;
        if (!optionalStringEql(entry.session_id, needle.session_id)) continue;
        if (!std.mem.eql(u8, entry.scope, needle.scope)) continue;
        if (!std.mem.eql(u8, entry.store, needle.store)) continue;
        return true;
    }
    return false;
}

fn optionalStringEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

fn agentMemoryStorageTargetFromObject(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !store_mod.AgentMemoryStorageRoute {
    if (json.stringField(obj, "storage")) |value| return store_mod.AgentMemoryStorageRoute.parse(value);
    if (json.stringField(obj, "store")) |value| return store_mod.AgentMemoryStorageRoute.parse(value);
    if (json.stringField(obj, "target_store")) |value| return store_mod.AgentMemoryStorageRoute.parse(value);
    if (obj.get("stores")) |value| return agentMemoryStorageTargetFromValue(allocator, value);
    return .{};
}

fn agentMemoryStorageTargetFromObjectOrQuery(allocator: std.mem.Allocator, obj: std.json.ObjectMap, query: []const u8) !store_mod.AgentMemoryStorageRoute {
    if (json.stringField(obj, "storage") != null or
        json.stringField(obj, "store") != null or
        json.stringField(obj, "target_store") != null or
        obj.get("stores") != null)
    {
        return agentMemoryStorageTargetFromObject(allocator, obj);
    }
    return agentMemoryStorageTargetFromQuery(allocator, query);
}

fn agentMemoryStorageTargetFromQuery(allocator: std.mem.Allocator, query: []const u8) !store_mod.AgentMemoryStorageRoute {
    if (json.queryParam(query, "storage")) |value| return store_mod.AgentMemoryStorageRoute.parse(value);
    if (json.queryParam(query, "store")) |value| return store_mod.AgentMemoryStorageRoute.parse(value);
    if (json.queryParam(query, "target_store")) |value| return store_mod.AgentMemoryStorageRoute.parse(value);
    if (json.queryParam(query, "stores")) |value| return agentMemoryStorageTargetFromCsv(allocator, value);
    return .{};
}

fn agentMemoryStorageTargetFromCsv(allocator: std.mem.Allocator, value: []const u8) !store_mod.AgentMemoryStorageRoute {
    var count: usize = 1;
    for (value) |ch| {
        if (ch == ',') count += 1;
    }
    var stores = try allocator.alloc([]const u8, count);
    var used: usize = 0;
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t\r\n");
        if (trimmed.len == 0) continue;
        stores[used] = trimmed;
        used += 1;
    }
    return store_mod.AgentMemoryStorageRoute.fromStores(stores[0..used]);
}

fn agentMemoryStorageTargetFromValue(allocator: std.mem.Allocator, value: std.json.Value) !store_mod.AgentMemoryStorageRoute {
    return switch (value) {
        .string => |s| store_mod.AgentMemoryStorageRoute.parse(s),
        .array => |items| blk: {
            var stores = try allocator.alloc([]const u8, items.items.len);
            var count: usize = 0;
            for (items.items) |item| {
                if (item != .string) continue;
                stores[count] = item.string;
                count += 1;
            }
            break :blk store_mod.AgentMemoryStorageRoute.fromStores(stores[0..count]);
        },
        else => .{},
    };
}

fn agentMemoryEntryVisible(ctx: *Context, entry: domain.AgentMemory) bool {
    return access.agentMemoryVisible(ctx.allocator, .{
        .owner_actor_id = entry.actor_id,
        .scope = entry.scope,
        .permissions_json = entry.permissions_json,
        .session_id = entry.session_id,
        .request_actor_id = ctx.actor_id,
        .request_scopes_json = ctx.actor_scopes_json,
        .record_visible = recordVisibleToActor(ctx, entry.scope, entry.permissions_json),
        .session_visible = if (entry.session_id) |sid| agentSessionReadAllowed(ctx, sid) else true,
    });
}

fn agentMemoryEntryDeletable(ctx: *Context, entry: domain.AgentMemory) bool {
    const actor_owned = std.mem.eql(u8, entry.actor_id, ctx.actor_id) and
        domain.isActorOwnedAgentMemoryScope(entry.scope, ctx.actor_id) and
        access.permissionsVisibleForActor(ctx.allocator, entry.permissions_json, ctx.actor_scopes_json, ctx.actor_id);
    if (actor_owned) return true;
    if (entry.session_id) |sid| {
        const session_scope = std.fmt.allocPrint(ctx.allocator, "session:{s}", .{sid}) catch return false;
        defer ctx.allocator.free(session_scope);
        if (std.mem.eql(u8, entry.scope, session_scope) and access.permissionsVisibleForActor(ctx.allocator, entry.permissions_json, ctx.actor_scopes_json, ctx.actor_id)) {
            return agentSessionWriteAllowed(ctx, sid);
        }
    }
    return domain.scopeDeletable(entry.scope, ctx.actor_scopes_json) and domain.permissionsWritable(entry.permissions_json, ctx.actor_scopes_json);
}

fn actorFilter(ctx: *Context) ?[]const u8 {
    return if (domain.hasActorScope(ctx.actor_scopes_json, "admin")) null else ctx.actor_id;
}

fn saveMessage(ctx: *Context, session_id: []const u8, body: []const u8, query: []const u8) HttpResponse {
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const role = json.stringField(obj, "role") orelse return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing role");
    const content = json.stringField(obj, "content") orelse return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing content");
    const storage_target = agentMemoryStorageTargetFromObjectOrQuery(ctx.allocator, obj, query) catch return serverError(ctx);
    ctx.store.saveMessageRouted(session_id, role, content, ctx.actor_id, storage_target) catch |err| switch (err) {
        error.AgentMemoryStorageUnavailable => return agentMemoryStorageUnavailable(ctx),
        else => return serverError(ctx),
    };
    return ok(ctx, "{\"ok\":true}");
}

fn loadMessages(ctx: *Context, session_id: []const u8, query: []const u8) HttpResponse {
    const storage_target = agentMemoryStorageTargetFromQuery(ctx.allocator, query) catch return serverError(ctx);
    const messages = ctx.store.loadMessagesRouted(ctx.allocator, session_id, actorFilter(ctx), storage_target) catch |err| switch (err) {
        error.AgentMemoryStorageUnavailable => return agentMemoryStorageUnavailable(ctx),
        else => return serverError(ctx),
    };
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ctx.allocator, "{\"messages\":[") catch return serverError(ctx);
    for (messages, 0..) |msg, i| {
        if (i > 0) out.append(ctx.allocator, ',') catch return serverError(ctx);
        appendMessage(ctx, &out, msg, false) catch return serverError(ctx);
    }
    out.appendSlice(ctx.allocator, "]}") catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn saveUsage(ctx: *Context, session_id: []const u8, body: []const u8, query: []const u8) HttpResponse {
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const total = json.intField(obj, "total_tokens") orelse 0;
    const storage_target = agentMemoryStorageTargetFromObjectOrQuery(ctx.allocator, obj, query) catch return serverError(ctx);
    ctx.store.saveUsageRouted(session_id, @intCast(@max(total, 0)), ctx.actor_id, storage_target) catch |err| switch (err) {
        error.AgentMemoryStorageUnavailable => return agentMemoryStorageUnavailable(ctx),
        else => return serverError(ctx),
    };
    return ok(ctx, "{\"ok\":true}");
}

fn loadUsage(ctx: *Context, session_id: []const u8, query: []const u8) HttpResponse {
    const storage_target = agentMemoryStorageTargetFromQuery(ctx.allocator, query) catch return serverError(ctx);
    const total_opt = ctx.store.loadUsageRouted(session_id, actorFilter(ctx), storage_target) catch |err| switch (err) {
        error.AgentMemoryStorageUnavailable => return agentMemoryStorageUnavailable(ctx),
        else => return serverError(ctx),
    };
    const total = total_opt orelse return json.errorResponse(ctx.allocator, 404, "not_found", "No usage for session");
    const body = std.fmt.allocPrint(ctx.allocator, "{{\"total_tokens\":{d}}}", .{total}) catch return serverError(ctx);
    return .{ .status = "200 OK", .body = body };
}

fn writeHistoryList(ctx: *Context, result: store_mod.HistoryList, limit: usize, offset: usize) HttpResponse {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.print(ctx.allocator, "{{\"total\":{d},\"limit\":{d},\"offset\":{d},\"sessions\":[", .{ result.total, limit, offset }) catch return serverError(ctx);
    for (result.sessions, 0..) |session, i| {
        if (i > 0) out.append(ctx.allocator, ',') catch return serverError(ctx);
        out.appendSlice(ctx.allocator, "{\"session_id\":") catch return serverError(ctx);
        json.appendString(&out, ctx.allocator, session.session_id) catch return serverError(ctx);
        out.print(ctx.allocator, ",\"message_count\":{d},\"first_message_at\":\"{d}\",\"last_message_at\":\"{d}\"}}", .{ session.message_count, session.first_message_at, session.last_message_at }) catch return serverError(ctx);
    }
    out.appendSlice(ctx.allocator, "]}") catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn writeHistoryShow(ctx: *Context, session_id: []const u8, result: store_mod.HistoryShow, limit: usize, offset: usize) HttpResponse {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ctx.allocator, "{\"session_id\":") catch return serverError(ctx);
    json.appendString(&out, ctx.allocator, session_id) catch return serverError(ctx);
    out.print(ctx.allocator, ",\"total\":{d},\"limit\":{d},\"offset\":{d},\"messages\":[", .{ result.total, limit, offset }) catch return serverError(ctx);
    for (result.messages, 0..) |msg, i| {
        if (i > 0) out.append(ctx.allocator, ',') catch return serverError(ctx);
        appendMessage(ctx, &out, msg, true) catch return serverError(ctx);
    }
    out.appendSlice(ctx.allocator, "]}") catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn objectResponse(ctx: *Context, name: []const u8, value: anytype) HttpResponse {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.append(ctx.allocator, '{') catch return serverError(ctx);
    json.appendString(&out, ctx.allocator, name) catch return serverError(ctx);
    out.append(ctx.allocator, ':') catch return serverError(ctx);
    value.writeJson(ctx.allocator, &out) catch return serverError(ctx);
    out.append(ctx.allocator, '}') catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn artifactResponse(ctx: *Context, artifact: domain.Artifact) HttpResponse {
    var copy = artifact;
    copy.source_ids_json = sanitizeSourceIdsForActor(ctx, artifact.source_ids_json) catch return serverError(ctx);
    return objectResponse(ctx, "artifact", copy);
}

fn searchResponse(ctx: *Context, results: []domain.SearchResult) HttpResponse {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ctx.allocator, "{\"results\":") catch return serverError(ctx);
    appendSearchArray(ctx, &out, results) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"groups\":") catch return serverError(ctx);
    appendSearchGroups(ctx, &out, results) catch return serverError(ctx);
    out.append(ctx.allocator, '}') catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn appendSearchArray(ctx: *Context, out: *std.ArrayListUnmanaged(u8), results: []domain.SearchResult) !void {
    try out.append(ctx.allocator, '[');
    for (results, 0..) |result, i| {
        if (i > 0) try out.append(ctx.allocator, ',');
        try result.writeJson(ctx.allocator, out);
    }
    try out.append(ctx.allocator, ']');
}

fn appendSearchGroups(ctx: *Context, out: *std.ArrayListUnmanaged(u8), results: []domain.SearchResult) !void {
    const types = [_][]const u8{
        "memory_atom",
        "space",
        "policy_scope",
        "source",
        "artifact",
        "entity",
        "relation",
        "context_pack",
        "feed_event",
        "agent_memory",
        "session_message",
    };
    const names = [_][]const u8{
        "memory_atoms",
        "spaces",
        "policy_scopes",
        "sources",
        "artifacts",
        "entities",
        "relations",
        "context_packs",
        "feed_events",
        "agent_memory",
        "session_messages",
    };
    try out.append(ctx.allocator, '{');
    inline for (types, 0..) |result_type, i| {
        if (i > 0) try out.append(ctx.allocator, ',');
        try json.appendString(out, ctx.allocator, names[i]);
        try out.append(ctx.allocator, ':');
        try out.append(ctx.allocator, '[');
        var first = true;
        for (results) |result| {
            if (!std.mem.eql(u8, result.result_type, result_type)) continue;
            if (!first) try out.append(ctx.allocator, ',');
            first = false;
            try result.writeJson(ctx.allocator, out);
        }
        try out.append(ctx.allocator, ']');
    }
    try out.append(ctx.allocator, '}');
}

fn agentMemoryEntryResponse(ctx: *Context, name: []const u8, entry: domain.AgentMemory) HttpResponse {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.append(ctx.allocator, '{') catch return serverError(ctx);
    json.appendString(&out, ctx.allocator, name) catch return serverError(ctx);
    out.append(ctx.allocator, ':') catch return serverError(ctx);
    entry.writeJson(ctx.allocator, &out) catch return serverError(ctx);
    out.append(ctx.allocator, '}') catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn agentMemoryEntriesResponse(ctx: *Context, entries: []domain.AgentMemory) HttpResponse {
    return agentMemoryEntriesResponseFiltered(ctx, entries, true, entries.len, 0);
}

fn agentMemoryEntriesResponseFiltered(ctx: *Context, entries: []domain.AgentMemory, include_internal: bool, limit: usize, offset: usize) HttpResponse {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ctx.allocator, "{\"memories\":[") catch return serverError(ctx);
    var visible_seen: usize = 0;
    var written: usize = 0;
    for (entries) |entry| {
        if (!agentMemoryEntryVisible(ctx, entry)) continue;
        if (!include_internal and domain.isInternalMemoryEntryKeyOrContent(entry.key, entry.content)) continue;
        if (visible_seen < offset) {
            visible_seen += 1;
            continue;
        }
        visible_seen += 1;
        if (written >= limit) continue;
        if (written > 0) out.append(ctx.allocator, ',') catch return serverError(ctx);
        entry.writeJson(ctx.allocator, &out) catch return serverError(ctx);
        written += 1;
    }
    out.appendSlice(ctx.allocator, "]}") catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn feedEventsResponse(ctx: *Context, events: []store_mod.FeedEvent) HttpResponse {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ctx.allocator, "{\"events\":[") catch return serverError(ctx);
    _ = appendFeedEventsForActor(ctx, &out, events) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, "]}") catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn appendFeedEventsForActor(ctx: *Context, out: *std.ArrayListUnmanaged(u8), events: []store_mod.FeedEvent) !usize {
    var written: usize = 0;
    for (events) |event| {
        if (!feedRecordVisibleToActor(ctx, event.scope, event.permissions_json)) continue;
        if (written > 0) try out.append(ctx.allocator, ',');
        try appendFeedEventForActor(ctx, out, event);
        written += 1;
    }
    return written;
}

fn appendFeedEventForActor(ctx: *Context, out: *std.ArrayListUnmanaged(u8), event: store_mod.FeedEvent) !void {
    const payload_json = try feedPayloadForActor(ctx, event);
    try out.print(ctx.allocator, "{{\"id\":{d},\"event_type\":", .{event.id});
    try json.appendString(out, ctx.allocator, event.event_type);
    try out.appendSlice(ctx.allocator, ",\"operation\":");
    try json.appendString(out, ctx.allocator, event.operation);
    try out.appendSlice(ctx.allocator, ",\"object_type\":");
    try json.appendString(out, ctx.allocator, event.object_type);
    try out.appendSlice(ctx.allocator, ",\"object_id\":");
    try json.appendString(out, ctx.allocator, event.object_id);
    try out.appendSlice(ctx.allocator, ",\"scope\":");
    try json.appendString(out, ctx.allocator, event.scope);
    try out.appendSlice(ctx.allocator, ",\"permissions\":");
    try json.appendRawJsonOr(out, ctx.allocator, event.permissions_json, "[]");
    try out.appendSlice(ctx.allocator, ",\"actor_id\":");
    try json.appendNullableString(out, ctx.allocator, event.actor_id);
    try out.appendSlice(ctx.allocator, ",\"dedupe_key\":");
    try json.appendNullableString(out, ctx.allocator, event.dedupe_key);
    try out.appendSlice(ctx.allocator, ",\"causality\":");
    try json.appendRawJsonOr(out, ctx.allocator, event.causality_json, "{}");
    try out.appendSlice(ctx.allocator, ",\"payload\":");
    try json.appendRawJsonOr(out, ctx.allocator, payload_json, "{}");
    try out.appendSlice(ctx.allocator, ",\"status\":");
    try json.appendString(out, ctx.allocator, event.status);
    try out.print(ctx.allocator, ",\"created_at_ms\":{d},\"applied_at_ms\":", .{event.created_at_ms});
    if (event.applied_at_ms) |v| try out.print(ctx.allocator, "{d}", .{v}) else try out.appendSlice(ctx.allocator, "null");
    try out.appendSlice(ctx.allocator, ",\"compacted_at_ms\":");
    if (event.compacted_at_ms) |v| try out.print(ctx.allocator, "{d}", .{v}) else try out.appendSlice(ctx.allocator, "null");
    try out.append(ctx.allocator, '}');
}

fn feedPayloadForActor(ctx: *Context, event: store_mod.FeedEvent) ![]const u8 {
    if (!feedEventObjectVisibleToActor(ctx, event)) return redactedFeedPayload();
    if (!try feedReferencedObjectsVisible(ctx, event.payload_json)) return redactedFeedPayload();
    return event.payload_json;
}

fn redactedFeedPayload() []const u8 {
    return "{\"redacted\":true,\"reason\":\"inaccessible_payload_reference\"}";
}

fn feedEventObjectVisibleToActor(ctx: *Context, event: store_mod.FeedEvent) bool {
    if (!std.mem.eql(u8, event.status, "applied")) return true;
    if (std.mem.eql(u8, event.object_type, "memory_atom")) {
        const atom = (ctx.store.getMemoryAtom(ctx.allocator, event.object_id) catch return false) orelse return true;
        return recordVisibleToActor(ctx, atom.scope, atom.permissions_json);
    }
    if (std.mem.eql(u8, event.object_type, "source")) {
        const source = (ctx.store.getSource(ctx.allocator, event.object_id) catch return false) orelse return true;
        return recordVisibleToActor(ctx, source.scope, source.permissions_json);
    }
    if (std.mem.eql(u8, event.object_type, "artifact")) {
        const artifact = (ctx.store.getArtifact(ctx.allocator, event.object_id) catch return false) orelse return true;
        return recordVisibleToActor(ctx, artifact.scope, artifact.permissions_json);
    }
    if (std.mem.eql(u8, event.object_type, "entity")) {
        const entity = (ctx.store.getEntity(ctx.allocator, event.object_id) catch return false) orelse return true;
        return recordVisibleToActor(ctx, entity.scope, entity.permissions_json);
    }
    if (std.mem.eql(u8, event.object_type, "relation")) {
        const relation = (ctx.store.getRelation(ctx.allocator, event.object_id) catch return false) orelse return true;
        return recordVisibleToActor(ctx, relation.scope, relation.permissions_json);
    }
    if (std.mem.eql(u8, event.object_type, "context_pack")) {
        _ = (ctx.store.contextPackLifecycleTarget(ctx.allocator, event.object_id, ctx.actor_id, ctx.actor_scopes_json) catch return false) orelse return true;
        return true;
    }
    if (std.mem.eql(u8, event.object_type, "agent_memory")) {
        return feedRecordVisibleToActor(ctx, event.scope, event.permissions_json);
    }
    return true;
}

fn feedReferencedObjectsVisible(ctx: *Context, payload_json: []const u8) !bool {
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, payload_json, .{}) catch return true;
    defer parsed.deinit();
    return feedValueReferencesVisible(ctx, parsed.value);
}

fn feedValueReferencesVisible(ctx: *Context, value: std.json.Value) bool {
    return switch (value) {
        .string => |s| feedReferenceStringVisible(ctx, s),
        .array => |arr| {
            for (arr.items) |item| {
                if (!feedValueReferencesVisible(ctx, item)) return false;
            }
            return true;
        },
        .object => |obj| {
            var iterator = obj.iterator();
            while (iterator.next()) |entry| {
                if (!feedValueReferencesVisible(ctx, entry.value_ptr.*)) return false;
            }
            return true;
        },
        else => true,
    };
}

fn feedReferenceStringVisible(ctx: *Context, value: []const u8) bool {
    if (std.mem.startsWith(u8, value, "src_")) {
        const source = (ctx.store.getSource(ctx.allocator, value) catch return false) orelse return false;
        return recordVisibleToActor(ctx, source.scope, source.permissions_json);
    }
    if (std.mem.startsWith(u8, value, "art_")) {
        const artifact = (ctx.store.getArtifact(ctx.allocator, value) catch return false) orelse return false;
        return recordVisibleToActor(ctx, artifact.scope, artifact.permissions_json);
    }
    if (std.mem.startsWith(u8, value, "mem_")) {
        const atom = (ctx.store.getMemoryAtom(ctx.allocator, value) catch return false) orelse return false;
        return recordVisibleToActor(ctx, atom.scope, atom.permissions_json);
    }
    if (std.mem.startsWith(u8, value, "ent_")) {
        const entity = (ctx.store.getEntity(ctx.allocator, value) catch return false) orelse return false;
        return recordVisibleToActor(ctx, entity.scope, entity.permissions_json);
    }
    if (std.mem.startsWith(u8, value, "rel_")) {
        const relation = (ctx.store.getRelation(ctx.allocator, value) catch return false) orelse return false;
        return recordVisibleToActor(ctx, relation.scope, relation.permissions_json);
    }
    if (std.mem.startsWith(u8, value, "ctx_")) {
        _ = (ctx.store.contextPackLifecycleTarget(ctx.allocator, value, ctx.actor_id, ctx.actor_scopes_json) catch return false) orelse return false;
        return true;
    }
    return true;
}

fn appliedFeedResponse(ctx: *Context, event_id: i64, memory_atom_id: ?[]const u8) HttpResponse {
    return appliedFeedObjectResponse(ctx, event_id, if (memory_atom_id != null) "memory_atom" else "unknown", memory_atom_id orelse "unknown", memory_atom_id);
}

fn appliedFeedObjectResponse(ctx: *Context, event_id: i64, object_type: []const u8, object_id: []const u8, memory_atom_id: ?[]const u8) HttpResponse {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.print(ctx.allocator, "{{\"event_id\":{d},\"applied\":true,\"object_type\":", .{event_id}) catch return serverError(ctx);
    json.appendString(&out, ctx.allocator, object_type) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"object_id\":") catch return serverError(ctx);
    json.appendString(&out, ctx.allocator, object_id) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"memory_atom_id\":") catch return serverError(ctx);
    json.appendNullableString(&out, ctx.allocator, memory_atom_id) catch return serverError(ctx);
    out.append(ctx.allocator, '}') catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn feedObjectTypeSupported(object_type: []const u8) bool {
    return std.mem.eql(u8, object_type, "memory_atom") or
        std.mem.eql(u8, object_type, "source") or
        std.mem.eql(u8, object_type, "artifact") or
        std.mem.eql(u8, object_type, "entity") or
        std.mem.eql(u8, object_type, "relation") or
        std.mem.eql(u8, object_type, "agent_memory") or
        std.mem.eql(u8, object_type, "context_pack");
}

fn feedLifecycleUsesOverlay(object_type: []const u8) bool {
    return std.mem.eql(u8, object_type, "source") or
        std.mem.eql(u8, object_type, "entity") or
        std.mem.eql(u8, object_type, "context_pack");
}

fn isLifecycleFeedOperation(operation: []const u8) bool {
    return std.mem.eql(u8, operation, "delete") or
        std.mem.eql(u8, operation, "forget") or
        std.mem.eql(u8, operation, "verify") or
        std.mem.eql(u8, operation, "mark_stale") or
        std.mem.eql(u8, operation, "stale") or
        std.mem.eql(u8, operation, "supersede");
}

fn statusFromLifecycleOperation(operation: []const u8, payload_obj: std.json.ObjectMap) []const u8 {
    if (json.stringField(payload_obj, "status")) |status| return status;
    if (std.mem.eql(u8, operation, "verify")) return "verified";
    if (std.mem.eql(u8, operation, "mark_stale") or std.mem.eql(u8, operation, "stale")) return "stale";
    if (std.mem.eql(u8, operation, "supersede")) return "superseded";
    if (std.mem.eql(u8, operation, "delete") or std.mem.eql(u8, operation, "forget")) return "deprecated";
    return "proposed";
}

const FeedMutationTarget = struct {
    object_id: []const u8,
    scope: []const u8,
    permissions_json: []const u8,
};

fn applyFeedLifecycleMutation(ctx: *Context, obj: std.json.ObjectMap, event_type: []const u8, operation: []const u8, object_type: []const u8, event_actor_id: []const u8, payload_json: []const u8, causality_json: []const u8) HttpResponse {
    const payload = std.json.parseFromSlice(std.json.Value, ctx.allocator, payload_json, .{}) catch return badJson(ctx);
    defer payload.deinit();
    if (payload.value != .object) return json.errorResponse(ctx.allocator, 400, "bad_request", "Lifecycle feed event payload must be an object");
    const payload_obj = payload.value.object;
    const target = resolveFeedMutationTarget(ctx, obj, payload_obj, object_type) catch |err| switch (err) {
        error.NotFound => return json.errorResponse(ctx.allocator, 404, "not_found", "Feed target not found"),
        error.MissingRequiredField => return json.errorResponse(ctx.allocator, 400, "bad_request", "Lifecycle feed event requires object_id or payload.id"),
        else => return serverError(ctx),
    };
    if (!feedLifecycleMutationAllowed(ctx, operation, target.scope, target.permissions_json)) return forbidden(ctx);

    const status = statusFromLifecycleOperation(operation, payload_obj);
    if (std.mem.eql(u8, object_type, "memory_atom")) {
        if (!(ctx.store.patchMemoryAtomStatusActor(target.object_id, status, std.mem.eql(u8, status, "verified"), event_actor_id) catch return serverError(ctx))) return json.errorResponse(ctx.allocator, 404, "not_found", "Memory atom not found");
    } else if (std.mem.eql(u8, object_type, "artifact")) {
        if (!(ctx.store.patchArtifactStatusActor(target.object_id, status, event_actor_id) catch return serverError(ctx))) return json.errorResponse(ctx.allocator, 404, "not_found", "Artifact not found");
    } else if (std.mem.eql(u8, object_type, "relation")) {
        if (!(ctx.store.patchRelationStatusActor(target.object_id, status, event_actor_id) catch return serverError(ctx))) return json.errorResponse(ctx.allocator, 404, "not_found", "Relation not found");
    } else if (feedLifecycleUsesOverlay(object_type)) {
        if (!(ctx.store.patchPrimitiveLifecycleActor(ctx.allocator, object_type, target.object_id, status, event_actor_id, payload_json) catch return serverError(ctx))) return json.errorResponse(ctx.allocator, 404, "not_found", "Feed target not found");
    }

    const event_id = applyOrAppendFeedEventRecord(ctx, obj, event_type, operation, object_type, target.object_id, target.scope, target.permissions_json, event_actor_id, causality_json, payload_json) catch |err| switch (err) {
        error.FeedConflict => return json.errorResponse(ctx.allocator, 409, "conflict", "Feed event with this dedupe key is already queued or applying"),
        else => return serverError(ctx),
    };
    return appliedFeedObjectResponse(ctx, event_id, object_type, target.object_id, null);
}

fn resolveFeedMutationTarget(ctx: *Context, obj: std.json.ObjectMap, payload_obj: std.json.ObjectMap, object_type: []const u8) !FeedMutationTarget {
    const object_id = json.stringField(obj, "object_id") orelse json.stringField(payload_obj, "id") orelse json.stringField(payload_obj, "object_id") orelse return error.MissingRequiredField;
    if (std.mem.eql(u8, object_type, "memory_atom")) {
        const atom = (try ctx.store.getMemoryAtom(ctx.allocator, object_id)) orelse return error.NotFound;
        if (!recordVisibleToActor(ctx, atom.scope, atom.permissions_json)) return error.NotFound;
        return .{ .object_id = object_id, .scope = atom.scope, .permissions_json = atom.permissions_json };
    }
    if (std.mem.eql(u8, object_type, "source")) {
        const source = (try ctx.store.getSource(ctx.allocator, object_id)) orelse return error.NotFound;
        if (!recordVisibleToActor(ctx, source.scope, source.permissions_json)) return error.NotFound;
        return .{ .object_id = object_id, .scope = source.scope, .permissions_json = source.permissions_json };
    }
    if (std.mem.eql(u8, object_type, "artifact")) {
        const artifact = (try ctx.store.getArtifact(ctx.allocator, object_id)) orelse return error.NotFound;
        if (!recordVisibleToActor(ctx, artifact.scope, artifact.permissions_json)) return error.NotFound;
        return .{ .object_id = object_id, .scope = artifact.scope, .permissions_json = artifact.permissions_json };
    }
    if (std.mem.eql(u8, object_type, "entity")) {
        const entity = (try ctx.store.getEntity(ctx.allocator, object_id)) orelse return error.NotFound;
        if (!recordVisibleToActor(ctx, entity.scope, entity.permissions_json)) return error.NotFound;
        return .{ .object_id = object_id, .scope = entity.scope, .permissions_json = entity.permissions_json };
    }
    if (std.mem.eql(u8, object_type, "relation")) {
        const relation = (try ctx.store.getRelation(ctx.allocator, object_id)) orelse return error.NotFound;
        if (!recordVisibleToActor(ctx, relation.scope, relation.permissions_json)) return error.NotFound;
        return .{ .object_id = object_id, .scope = relation.scope, .permissions_json = relation.permissions_json };
    }
    if (std.mem.eql(u8, object_type, "context_pack")) {
        const target = (try ctx.store.contextPackLifecycleTarget(ctx.allocator, object_id, ctx.actor_id, ctx.actor_scopes_json)) orelse return error.NotFound;
        return .{ .object_id = target.object_id, .scope = target.scope, .permissions_json = target.permissions_json };
    }
    const scope = json.stringField(obj, "scope") orelse json.stringField(payload_obj, "scope") orelse "workspace";
    const permissions_json = rawField(ctx.allocator, obj, "permissions", rawField(ctx.allocator, payload_obj, "permissions", "[]") catch "[]") catch "[]";
    return .{ .object_id = object_id, .scope = scope, .permissions_json = permissions_json };
}

fn feedLifecycleMutationAllowed(ctx: *Context, operation: []const u8, scope: []const u8, permissions_json: []const u8) bool {
    if (!recordVisibleToActor(ctx, scope, permissions_json)) return false;
    if (std.mem.eql(u8, operation, "delete") or std.mem.eql(u8, operation, "forget")) {
        return hasCapability(ctx, "delete") and domain.scopeDeletable(scope, ctx.actor_scopes_json) and domain.permissionsWritable(permissions_json, ctx.actor_scopes_json);
    }
    if (std.mem.eql(u8, operation, "verify") or std.mem.eql(u8, operation, "mark_stale") or std.mem.eql(u8, operation, "stale") or std.mem.eql(u8, operation, "supersede")) {
        return hasCapability(ctx, "verify") and domain.scopeVerifiable(scope, ctx.actor_scopes_json) and domain.permissionsWritable(permissions_json, ctx.actor_scopes_json);
    }
    return canWriteRecord(ctx, scope, permissions_json);
}

fn applyOrAppendFeedEventRecord(ctx: *Context, obj: std.json.ObjectMap, event_type: []const u8, operation: []const u8, object_type: []const u8, object_id: []const u8, scope: []const u8, permissions_json: []const u8, event_actor_id: []const u8, causality_json: []const u8, payload_json: []const u8) !i64 {
    if (json.nullableStringField(obj, "dedupe_key")) |dedupe_key| {
        if (ctx.store.getFeedEventByDedupeKey(ctx.allocator, dedupe_key) catch return error.StoreFailure) |event| {
            if (!recordVisibleToActor(ctx, event.scope, event.permissions_json)) return error.Forbidden;
            if (std.mem.eql(u8, event.status, "applied")) return event.id;
            return error.FeedConflict;
        }
        const reservation_id = try ids.make(ctx.allocator, "apply_");
        const reserved = try ctx.store.appendFeedEvent(.{
            .event_type = event_type,
            .operation = operation,
            .object_type = object_type,
            .object_id = reservation_id,
            .scope = scope,
            .permissions_json = permissions_json,
            .actor_id = event_actor_id,
            .dedupe_key = dedupe_key,
            .causality_json = causality_json,
            .payload_json = payload_json,
            .status = "applying",
        });
        if (!(try ctx.store.markFeedEventApplied(reserved, object_type, object_id, payload_json))) return error.FeedConflict;
        return reserved;
    }
    return ctx.store.appendFeedEvent(.{
        .event_type = event_type,
        .operation = operation,
        .object_type = object_type,
        .object_id = object_id,
        .scope = scope,
        .permissions_json = permissions_json,
        .actor_id = event_actor_id,
        .dedupe_key = null,
        .causality_json = causality_json,
        .payload_json = payload_json,
        .status = "applied",
    });
}

fn applyFeedObjectPut(ctx: *Context, object_type: []const u8, payload_json: []const u8, fallback_scope: []const u8, fallback_permissions_json: []const u8, event_actor_id: []const u8, event_object_id: ?[]const u8) ![]const u8 {
    const payload = try std.json.parseFromSlice(std.json.Value, ctx.allocator, payload_json, .{});
    defer payload.deinit();
    if (payload.value != .object) return error.InvalidPayload;
    const obj = payload.value.object;
    if (std.mem.eql(u8, object_type, "source")) {
        const input = try buildAppliedSourceInput(ctx, obj, fallback_scope, fallback_permissions_json, event_actor_id, event_object_id);
        const source = try ctx.store.createSource(ctx.allocator, input);
        return source.id;
    }
    if (std.mem.eql(u8, object_type, "artifact")) {
        const input = try buildAppliedArtifactInput(ctx, obj, fallback_scope, fallback_permissions_json, event_actor_id, event_object_id);
        const artifact = try ctx.store.createArtifact(ctx.allocator, input);
        return artifact.id;
    }
    if (std.mem.eql(u8, object_type, "entity")) {
        const input = try buildAppliedEntityInput(ctx, obj, fallback_scope, fallback_permissions_json, event_actor_id, event_object_id);
        const entity = try ctx.store.resolveEntity(ctx.allocator, input);
        return entity.id;
    }
    if (std.mem.eql(u8, object_type, "relation")) {
        const input = try buildAppliedRelationInput(ctx, obj, fallback_scope, fallback_permissions_json, event_actor_id, event_object_id);
        const relation = try ctx.store.createRelation(ctx.allocator, input);
        return relation.id;
    }
    if (std.mem.eql(u8, object_type, "context_pack")) {
        const input = try buildAppliedContextPackInput(ctx, obj, event_actor_id, event_object_id);
        const context = try ctx.store.createContextPack(ctx.allocator, input);
        return context.id;
    }
    return error.InvalidPayload;
}

fn payloadScope(obj: std.json.ObjectMap, fallback_scope: []const u8) []const u8 {
    return json.stringField(obj, "scope") orelse fallback_scope;
}

fn payloadPermissions(ctx: *Context, obj: std.json.ObjectMap, fallback_permissions_json: []const u8) ![]const u8 {
    return rawField(ctx.allocator, obj, "permissions", fallback_permissions_json);
}

fn buildAppliedSourceInput(ctx: *Context, obj: std.json.ObjectMap, fallback_scope: []const u8, fallback_permissions_json: []const u8, event_actor_id: []const u8, event_object_id: ?[]const u8) !store_mod.SourceInput {
    const scope = payloadScope(obj, fallback_scope);
    const permissions_json = try payloadPermissions(ctx, obj, fallback_permissions_json);
    if (!canWriteRecord(ctx, scope, permissions_json)) return error.Forbidden;
    return .{
        .id = try feedIdOverride(obj, event_object_id, "src_"),
        .source_type = json.stringField(obj, "type") orelse json.stringField(obj, "source_type") orelse "manual",
        .title = json.stringField(obj, "title") orelse return error.MissingRequiredField,
        .raw_content_uri = json.nullableStringField(obj, "raw_content_uri"),
        .content = json.stringField(obj, "content") orelse "",
        .author = json.nullableStringField(obj, "author"),
        .participants_json = rawField(ctx.allocator, obj, "participants", "[]") catch "[]",
        .permissions_json = permissions_json,
        .scope = scope,
        .checksum = json.nullableStringField(obj, "checksum"),
        .language = json.nullableStringField(obj, "language"),
        .related_entities_json = rawField(ctx.allocator, obj, "related_entities", "[]") catch "[]",
        .metadata_json = rawField(ctx.allocator, obj, "metadata", "{}") catch "{}",
        .actor_id = event_actor_id,
        .storage_route = try agentMemoryStorageTargetFromObject(ctx.allocator, obj),
        .suppress_feed = true,
    };
}

fn buildAppliedArtifactInput(ctx: *Context, obj: std.json.ObjectMap, fallback_scope: []const u8, fallback_permissions_json: []const u8, event_actor_id: []const u8, event_object_id: ?[]const u8) !store_mod.ArtifactInput {
    const scope = payloadScope(obj, fallback_scope);
    const permissions_json = try payloadPermissions(ctx, obj, fallback_permissions_json);
    if (!canWriteRecord(ctx, scope, permissions_json)) return error.Forbidden;
    const artifact_type = json.stringField(obj, "type") orelse json.stringField(obj, "artifact_type") orelse "page";
    const status = json.stringField(obj, "status") orelse if (std.mem.eql(u8, artifact_type, "decision")) "proposed" else "draft";
    const source_ids_json = rawField(ctx.allocator, obj, "source_ids", "[]") catch "[]";
    if (!artifacts.validStatus(artifact_type, status)) return error.InvalidPayload;
    const fields_json = try normalizeArtifactFieldsJson(ctx, obj, artifact_type);
    if (!sourceIdsCanBackRecord(ctx, source_ids_json, scope, permissions_json)) return error.Forbidden;
    return .{
        .id = try feedIdOverride(obj, event_object_id, "art_"),
        .artifact_type = artifact_type,
        .title = json.stringField(obj, "title") orelse return error.MissingRequiredField,
        .body = json.stringField(obj, "body") orelse json.stringField(obj, "content") orelse "",
        .status = status,
        .owner = json.nullableStringField(obj, "owner"),
        .space_id = json.nullableStringField(obj, "space_id"),
        .scope = scope,
        .source_ids_json = source_ids_json,
        .related_entities_json = rawField(ctx.allocator, obj, "related_entities", "[]") catch "[]",
        .permissions_json = permissions_json,
        .fields_json = fields_json,
        .summary = json.nullableStringField(obj, "summary"),
        .agent_summary = json.nullableStringField(obj, "agent_summary"),
        .actor_id = event_actor_id,
        .storage_route = try agentMemoryStorageTargetFromObject(ctx.allocator, obj),
        .suppress_feed = true,
    };
}

fn buildAppliedEntityInput(ctx: *Context, obj: std.json.ObjectMap, fallback_scope: []const u8, fallback_permissions_json: []const u8, event_actor_id: []const u8, event_object_id: ?[]const u8) !store_mod.EntityInput {
    const scope = payloadScope(obj, fallback_scope);
    const permissions_json = try payloadPermissions(ctx, obj, fallback_permissions_json);
    if (!canWriteRecord(ctx, scope, permissions_json)) return error.Forbidden;
    return .{
        .id = try feedIdOverride(obj, event_object_id, "ent_"),
        .entity_type = json.stringField(obj, "type") orelse json.stringField(obj, "entity_type") orelse "concept",
        .name = json.stringField(obj, "name") orelse return error.MissingRequiredField,
        .aliases_json = rawField(ctx.allocator, obj, "aliases", "[]") catch "[]",
        .description = json.nullableStringField(obj, "description"),
        .canonical_artifact_id = json.nullableStringField(obj, "canonical_artifact_id"),
        .scope = scope,
        .permissions_json = permissions_json,
        .metadata_json = rawField(ctx.allocator, obj, "metadata", "{}") catch "{}",
        .actor_id = event_actor_id,
        .storage_route = try agentMemoryStorageTargetFromObject(ctx.allocator, obj),
        .suppress_feed = true,
    };
}

fn buildAppliedRelationInput(ctx: *Context, obj: std.json.ObjectMap, fallback_scope: []const u8, fallback_permissions_json: []const u8, event_actor_id: []const u8, event_object_id: ?[]const u8) !store_mod.RelationInput {
    const scope = payloadScope(obj, fallback_scope);
    const permissions_json = try payloadPermissions(ctx, obj, fallback_permissions_json);
    if (!canWriteRecord(ctx, scope, permissions_json)) return error.Forbidden;
    const from_entity_id = json.stringField(obj, "from_entity_id") orelse return error.MissingRequiredField;
    const to_entity_id = json.stringField(obj, "to_entity_id") orelse return error.MissingRequiredField;
    const source_ids_json = rawField(ctx.allocator, obj, "source_ids", "[]") catch "[]";
    if (!sourceIdsCanBackRecord(ctx, source_ids_json, scope, permissions_json)) return error.Forbidden;
    if (!entityCanBackRecord(ctx, from_entity_id, scope, permissions_json)) return error.Forbidden;
    if (!entityCanBackRecord(ctx, to_entity_id, scope, permissions_json)) return error.Forbidden;
    return .{
        .id = try feedIdOverride(obj, event_object_id, "rel_"),
        .from_entity_id = from_entity_id,
        .relation_type = json.stringField(obj, "relation_type") orelse json.stringField(obj, "type") orelse return error.MissingRequiredField,
        .to_entity_id = to_entity_id,
        .source_ids_json = source_ids_json,
        .scope = scope,
        .permissions_json = permissions_json,
        .confidence = json.floatField(obj, "confidence") orelse 0.5,
        .status = json.stringField(obj, "status") orelse "proposed",
        .actor_id = event_actor_id,
        .storage_route = try agentMemoryStorageTargetFromObject(ctx.allocator, obj),
        .suppress_feed = true,
    };
}

fn buildAppliedContextPackInput(ctx: *Context, obj: std.json.ObjectMap, event_actor_id: []const u8, event_object_id: ?[]const u8) !store_mod.ContextPackInput {
    const query = json.stringField(obj, "query") orelse json.stringField(obj, "task") orelse return error.MissingRequiredField;
    return .{
        .id = try feedIdOverride(obj, event_object_id, "ctx_"),
        .purpose = json.stringField(obj, "purpose") orelse "task",
        .target = json.stringField(obj, "target") orelse "agent",
        .query = query,
        .token_budget = json.intField(obj, "token_budget") orelse 12000,
        .scopes_json = try effectiveScopes(ctx, obj),
        .persist = true,
        .include_sessions = json.boolField(obj, "include_sessions") orelse false,
        .session_id = json.nullableStringField(obj, "session_id"),
        .retrieval_limit = positiveLimit(json.intField(obj, "retrieval_limit"), 40),
        .include_deprecated = json.boolField(obj, "include_deprecated") orelse false,
        .use_vector = json.boolField(obj, "use_vector") orelse true,
        .use_temporal_decay = json.boolField(obj, "use_temporal_decay") orelse true,
        .use_mmr = json.boolField(obj, "use_mmr") orelse true,
        .allow_reranker = json.boolField(obj, "allow_reranker") orelse false,
        .actor_id = event_actor_id,
        .agent_memory_route = try agentMemoryStorageTargetFromObject(ctx.allocator, obj),
        .suppress_feed = true,
    };
}

fn appendMessage(ctx: *Context, out: *std.ArrayListUnmanaged(u8), msg: store_mod.Message, include_created: bool) !void {
    try out.appendSlice(ctx.allocator, "{\"role\":");
    try json.appendString(out, ctx.allocator, msg.role);
    try out.appendSlice(ctx.allocator, ",\"content\":");
    try json.appendString(out, ctx.allocator, msg.content);
    if (include_created) {
        try out.print(ctx.allocator, ",\"created_at\":\"{d}\"", .{msg.created_at_ms});
    }
    try out.append(ctx.allocator, '}');
}

fn parseBody(ctx: *Context, body: []const u8) !std.json.Parsed(std.json.Value) {
    const parsed = try std.json.parseFromSlice(std.json.Value, ctx.allocator, if (body.len == 0) "{}" else body, .{});
    if (parsed.value != .object) return error.InvalidJsonObject;
    return parsed;
}

fn rawField(allocator: std.mem.Allocator, obj: std.json.ObjectMap, name: []const u8, fallback: []const u8) ![]const u8 {
    const value = obj.get(name) orelse return fallback;
    return try json.jsonFromValue(allocator, value);
}

fn normalizeArtifactFieldsJson(ctx: *Context, obj: std.json.ObjectMap, artifact_type: []const u8) ![]const u8 {
    const fields_obj = try artifactFieldsObject(obj);
    const required = artifacts.requiredFields(artifact_type);
    for (required) |field| {
        const value = artifactFieldValue(obj, fields_obj, field) orelse return error.MissingRequiredField;
        if (!artifactFieldUsable(value)) return error.MissingRequiredField;
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(ctx.allocator);
    try out.append(ctx.allocator, '{');
    var first = true;
    if (fields_obj) |fields| {
        var iterator = fields.iterator();
        while (iterator.next()) |entry| {
            if (!first) try out.append(ctx.allocator, ',');
            first = false;
            try json.appendString(&out, ctx.allocator, entry.key_ptr.*);
            try out.append(ctx.allocator, ':');
            try appendJsonValue(ctx.allocator, &out, entry.value_ptr.*);
        }
    }
    for (required) |field| {
        if (fields_obj != null and objectHasField(fields_obj.?, field)) continue;
        const value = obj.get(field) orelse continue;
        if (!first) try out.append(ctx.allocator, ',');
        first = false;
        try json.appendString(&out, ctx.allocator, field);
        try out.append(ctx.allocator, ':');
        try appendJsonValue(ctx.allocator, &out, value);
    }
    try out.append(ctx.allocator, '}');
    return out.toOwnedSlice(ctx.allocator);
}

fn artifactFieldsObject(obj: std.json.ObjectMap) !?std.json.ObjectMap {
    const value = obj.get("fields") orelse return null;
    return switch (value) {
        .object => |fields| fields,
        .null => null,
        else => error.InvalidPayload,
    };
}

fn artifactFieldValue(obj: std.json.ObjectMap, fields_obj: ?std.json.ObjectMap, name: []const u8) ?std.json.Value {
    if (fields_obj) |fields| {
        if (fields.get(name)) |value| return value;
    }
    return obj.get(name);
}

fn artifactFieldUsable(value: std.json.Value) bool {
    return switch (value) {
        .null => false,
        .string => |text| std.mem.trim(u8, text, " \t\r\n").len > 0,
        else => true,
    };
}

fn objectHasField(obj: std.json.ObjectMap, name: []const u8) bool {
    return obj.get(name) != null;
}

fn appendJsonValue(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), value: std.json.Value) !void {
    const encoded = try json.jsonFromValue(allocator, value);
    defer allocator.free(encoded);
    try out.appendSlice(allocator, encoded);
}

fn dupOptional(allocator: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    return if (value) |v| try allocator.dupe(u8, v) else null;
}

fn effectiveScopes(ctx: *Context, obj: std.json.ObjectMap) ![]const u8 {
    const requested = try rawField(ctx.allocator, obj, "scopes", "[]");
    if (!std.mem.eql(u8, requested, "[]")) return try domain.intersectJsonStringLists(ctx.allocator, requested, ctx.actor_scopes_json);
    return ctx.actor_scopes_json;
}

fn feedScopesJson(ctx: *Context) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(ctx.allocator);
    try out.append(ctx.allocator, '[');
    var first = true;
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, ctx.actor_scopes_json, .{}) catch null;
    if (parsed) |p| {
        defer p.deinit();
        if (p.value == .array) {
            for (p.value.array.items) |item| {
                const scope = switch (item) {
                    .string => |s| s,
                    else => continue,
                };
                if (!first) try out.append(ctx.allocator, ',');
                first = false;
                try json.appendString(&out, ctx.allocator, scope);
            }
        }
    }
    const own_agent_scope = try domain.defaultAgentMemoryScope(ctx.allocator, ctx.actor_id);
    if (!domain.hasJsonString(ctx.actor_scopes_json, own_agent_scope)) {
        if (!first) try out.append(ctx.allocator, ',');
        first = false;
        try json.appendString(&out, ctx.allocator, own_agent_scope);
    }
    const own_actor_grant = try domain.actorGrant(ctx.allocator, ctx.actor_id);
    if (!domain.hasJsonString(ctx.actor_scopes_json, own_actor_grant)) {
        if (!first) try out.append(ctx.allocator, ',');
        try json.appendString(&out, ctx.allocator, own_actor_grant);
    }
    try out.append(ctx.allocator, ']');
    return out.toOwnedSlice(ctx.allocator);
}

fn automaticCacheKey(allocator: std.mem.Allocator, namespace: []const u8, actor_id: []const u8, scopes_json: []const u8, body: []const u8) ![]u8 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(namespace);
    hasher.update("\n");
    hasher.update(actor_id);
    hasher.update("\n");
    hasher.update(scopes_json);
    hasher.update("\n");
    hasher.update(body);
    return std.fmt.allocPrint(allocator, "auto:{s}:{d}", .{ namespace, hasher.final() });
}

fn buildSearchInput(ctx: *Context, obj: std.json.ObjectMap, query: []const u8, limit: usize, include_sessions_default: bool) !store_mod.SearchInput {
    var use_vector = json.boolField(obj, "use_vector") orelse true;
    const strict_vector = json.boolField(obj, "strict_vector") orelse false;
    const agent_memory_route = try agentMemoryStorageTargetFromObject(ctx.allocator, obj);
    var query_embedding_json: ?[]const u8 = null;
    var query_embedding_provider: []const u8 = "none";
    var embedding_dimensions: usize = @max(@as(usize, 1), @min(ctx.embedding_dimensions, @as(usize, 4096)));
    if (use_vector and query.len > 0) {
        const embedding_result = providers.embedText(ctx.allocator, .{
            .provider = ctx.embedding_provider,
            .base_url = ctx.embedding_base_url,
            .api_key = ctx.embedding_api_key,
            .model = ctx.embedding_model,
            .dimensions = embedding_dimensions,
            .timeout_secs = ctx.provider_timeout_secs,
            .fallbacks = ctx.embedding_fallbacks,
        }, query, embedding_dimensions) catch |err| {
            if (strict_vector) return err;
            use_vector = false;
            query_embedding_provider = "unavailable";
            query_embedding_json = null;
            return .{
                .query = query,
                .limit = limit,
                .scopes_json = try effectiveScopes(ctx, obj),
                .include_deprecated = json.boolField(obj, "include_deprecated") orelse false,
                .include_sessions = json.boolField(obj, "include_sessions") orelse include_sessions_default,
                .session_id = json.nullableStringField(obj, "session_id"),
                .use_vector = false,
                .strict_vector = false,
                .use_temporal_decay = json.boolField(obj, "use_temporal_decay") orelse true,
                .use_mmr = json.boolField(obj, "use_mmr") orelse true,
                .allow_reranker = json.boolField(obj, "allow_reranker") orelse false,
                .half_life_days = json.floatField(obj, "half_life_days") orelse 30,
                .query_embedding_json = null,
                .query_embedding_provider = query_embedding_provider,
                .embedding_dimensions = embedding_dimensions,
                .actor_id = ctx.actor_id,
                .agent_memory_route = agent_memory_route,
            };
        };
        query_embedding_json = try vector_mod.embeddingToJson(ctx.allocator, embedding_result.embedding);
        query_embedding_provider = embedding_result.provider;
        embedding_dimensions = embedding_result.embedding.len;
    }
    return .{
        .query = query,
        .limit = limit,
        .scopes_json = try effectiveScopes(ctx, obj),
        .include_deprecated = json.boolField(obj, "include_deprecated") orelse false,
        .include_sessions = json.boolField(obj, "include_sessions") orelse include_sessions_default,
        .session_id = json.nullableStringField(obj, "session_id"),
        .use_vector = use_vector,
        .strict_vector = strict_vector,
        .use_temporal_decay = json.boolField(obj, "use_temporal_decay") orelse true,
        .use_mmr = json.boolField(obj, "use_mmr") orelse true,
        .allow_reranker = json.boolField(obj, "allow_reranker") orelse false,
        .half_life_days = json.floatField(obj, "half_life_days") orelse 30,
        .query_embedding_json = query_embedding_json,
        .query_embedding_provider = query_embedding_provider,
        .embedding_dimensions = embedding_dimensions,
        .actor_id = ctx.actor_id,
        .agent_memory_route = agent_memory_route,
    };
}

fn ensureMemoryProvenance(ctx: *Context, input: store_mod.MemoryAtomInput) !store_mod.MemoryAtomInput {
    var out = input;
    const has_source = jsonArrayHasStringItems(ctx.allocator, out.source_ids_json);
    if (has_source) {
        if (!sourceIdsCanBackRecord(ctx, out.source_ids_json, out.scope, out.permissions_json)) return error.Forbidden;
        if (!jsonArrayHasStringItems(ctx.allocator, out.evidence_ranges_json) and !jsonArrayHasObjectItems(ctx.allocator, out.evidence_ranges_json)) {
            const first_source = try firstJsonStringDup(ctx.allocator, out.source_ids_json);
            out.evidence_ranges_json = try evidenceJson(ctx.allocator, first_source orelse "", out.text.len, "provided_source");
        }
        return out;
    }

    const source_type: []const u8 = if (std.mem.eql(u8, input.created_by, "agent")) "agent_observation" else "manual";
    const title = try memorySourceTitle(ctx.allocator, input.text);
    const source = try ctx.store.createSource(ctx.allocator, .{
        .source_type = source_type,
        .title = title,
        .content = input.text,
        .author = input.owner,
        .permissions_json = input.permissions_json,
        .scope = input.scope,
        .metadata_json = "{\"generated_for\":\"memory_atom\"}",
        .actor_id = ctx.actor_id,
        .storage_route = input.storage_route,
    });
    out.source_ids_json = try singleStringArrayJson(ctx.allocator, source.id);
    out.evidence_ranges_json = try evidenceJson(ctx.allocator, source.id, input.text.len, "generated_source");
    return out;
}

fn prepareAppliedMemoryProvenance(ctx: *Context, input: store_mod.MemoryAtomInput) !store_mod.PreparedMemoryImport {
    var out = input;
    const has_source = jsonArrayHasStringItems(ctx.allocator, out.source_ids_json);
    if (has_source) {
        if (!sourceIdsCanBackRecord(ctx, out.source_ids_json, out.scope, out.permissions_json)) return error.Forbidden;
        if (!jsonArrayHasStringItems(ctx.allocator, out.evidence_ranges_json) and !jsonArrayHasObjectItems(ctx.allocator, out.evidence_ranges_json)) {
            const first_source = try firstJsonStringDup(ctx.allocator, out.source_ids_json);
            out.evidence_ranges_json = try evidenceJson(ctx.allocator, first_source orelse "", out.text.len, "provided_source");
        }
        return .{ .atom = out };
    }

    const source_type: []const u8 = if (std.mem.eql(u8, input.created_by, "agent")) "agent_observation" else "manual";
    return .{
        .atom = out,
        .generated_source = .{
            .source_type = source_type,
            .title = try memorySourceTitle(ctx.allocator, input.text),
            .content = input.text,
            .author = input.owner,
            .permissions_json = input.permissions_json,
            .scope = input.scope,
            .metadata_json = "{\"generated_for\":\"memory_feed_apply\"}",
            .actor_id = ctx.actor_id,
            .storage_route = input.storage_route,
        },
    };
}

fn jsonArrayHasStringItems(allocator: std.mem.Allocator, value: []const u8) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, value, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .array) return false;
    for (parsed.value.array.items) |item| {
        if (item == .string) return true;
    }
    return false;
}

fn jsonArrayHasObjectItems(allocator: std.mem.Allocator, value: []const u8) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, value, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .array) return false;
    for (parsed.value.array.items) |item| {
        if (item == .object) return true;
    }
    return false;
}

fn firstJsonStringDup(allocator: std.mem.Allocator, value: []const u8) !?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, value, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .array) return null;
    for (parsed.value.array.items) |item| {
        if (item == .string) return try allocator.dupe(u8, item.string);
    }
    return null;
}

fn singleStringArrayJson(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.append(allocator, '[');
    try json.appendString(&out, allocator, value);
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

fn evidenceJson(allocator: std.mem.Allocator, source_id: []const u8, text_len: usize, kind: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.appendSlice(allocator, "[{\"source_id\":");
    try json.appendString(&out, allocator, source_id);
    try out.appendSlice(allocator, ",\"start\":0,\"end\":");
    try out.print(allocator, "{d}", .{text_len});
    try out.appendSlice(allocator, ",\"kind\":");
    try json.appendString(&out, allocator, kind);
    try out.appendSlice(allocator, "}]");
    return out.toOwnedSlice(allocator);
}

fn memorySourceTitle(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const max_len = @min(trimmed.len, @as(usize, 72));
    if (max_len == 0) return allocator.dupe(u8, "Memory source");
    return try std.fmt.allocPrint(allocator, "Memory source: {s}", .{trimmed[0..max_len]});
}

fn sourceIdsVisible(ctx: *Context, source_ids_json: []const u8) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, source_ids_json, .{}) catch return false;
    defer parsed.deinit();
    const arr = switch (parsed.value) {
        .array => |a| a,
        else => return false,
    };
    for (arr.items) |item| {
        const source_id = switch (item) {
            .string => |s| s,
            else => return false,
        };
        const source = (ctx.store.getSource(ctx.allocator, source_id) catch return false) orelse return false;
        if (!recordVisibleToActor(ctx, source.scope, source.permissions_json)) return false;
    }
    return true;
}

fn sourceIdsCanBackRecord(ctx: *Context, source_ids_json: []const u8, target_scope: []const u8, target_permissions_json: []const u8) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, source_ids_json, .{}) catch return false;
    defer parsed.deinit();
    const arr = switch (parsed.value) {
        .array => |a| a,
        else => return false,
    };
    for (arr.items) |item| {
        const source_id = switch (item) {
            .string => |s| s,
            else => return false,
        };
        const source = (ctx.store.getSource(ctx.allocator, source_id) catch return false) orelse return false;
        if (!recordVisibleToActor(ctx, source.scope, source.permissions_json)) return false;
        if (!sourceAclCoversTarget(ctx.allocator, source.scope, source.permissions_json, target_scope, target_permissions_json)) return false;
    }
    return true;
}

fn entityCanBackRecord(ctx: *Context, entity_id: []const u8, target_scope: []const u8, target_permissions_json: []const u8) bool {
    const entity = (ctx.store.getEntity(ctx.allocator, entity_id) catch return false) orelse return false;
    if (!recordVisibleToActor(ctx, entity.scope, entity.permissions_json)) return false;
    return sourceAclCoversTarget(ctx.allocator, entity.scope, entity.permissions_json, target_scope, target_permissions_json);
}

const sourceAclCoversTarget = access.aclCoversTarget;
const permissionsOpen = access.permissionsOpen;

fn sanitizeSourceIdsForActor(ctx: *Context, source_ids_json: []const u8) ![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, source_ids_json, .{}) catch return try ctx.allocator.dupe(u8, "[]");
    defer parsed.deinit();
    const arr = switch (parsed.value) {
        .array => |a| a,
        else => return try ctx.allocator.dupe(u8, "[]"),
    };
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(ctx.allocator);
    try out.append(ctx.allocator, '[');
    var first = true;
    for (arr.items) |item| {
        const source_id = switch (item) {
            .string => |s| s,
            else => continue,
        };
        const source = (try ctx.store.getSource(ctx.allocator, source_id)) orelse continue;
        if (!recordVisibleToActor(ctx, source.scope, source.permissions_json)) continue;
        if (!first) try out.append(ctx.allocator, ',');
        first = false;
        try json.appendString(&out, ctx.allocator, source_id);
    }
    try out.append(ctx.allocator, ']');
    return out.toOwnedSlice(ctx.allocator);
}

fn hasCapability(ctx: *Context, capability: []const u8) bool {
    return domain.hasCapability(ctx.actor_scopes_json, ctx.actor_capabilities_json, capability);
}

fn canWritePermissions(ctx: *Context, permissions_json: []const u8) bool {
    return hasCapability(ctx, "write") and domain.permissionsWritable(permissions_json, ctx.actor_scopes_json);
}

fn canWriteRecord(ctx: *Context, scope: []const u8, permissions_json: []const u8) bool {
    if (!canWritePermissions(ctx, permissions_json) or !domain.scopeWritable(scope, ctx.actor_scopes_json)) return false;
    const policy = ctx.store.getPolicyScope(ctx.allocator, scope) catch return false;
    if (policy) |p| {
        if (!domain.permissionsWritable(p.permissions_json, ctx.actor_scopes_json)) return false;
    }
    return true;
}

fn canProposeRecord(ctx: *Context, scope: []const u8, permissions_json: []const u8) bool {
    if (!((hasCapability(ctx, "propose") or hasCapability(ctx, "write")) and
        domain.scopeVisible(scope, ctx.actor_scopes_json) and
        domain.permissionsWritable(permissions_json, ctx.actor_scopes_json))) return false;
    const policy = ctx.store.getPolicyScope(ctx.allocator, scope) catch return false;
    if (policy) |p| return domain.permissionsWritable(p.permissions_json, ctx.actor_scopes_json);
    return true;
}

fn recordVisibleToActor(ctx: *Context, scope: []const u8, permissions_json: []const u8) bool {
    if (!domain.recordVisible(scope, permissions_json, ctx.actor_scopes_json)) return false;
    const policy = ctx.store.getPolicyScope(ctx.allocator, scope) catch return false;
    if (policy) |p| return domain.recordVisible(p.scope, p.permissions_json, ctx.actor_scopes_json);
    return true;
}

fn feedRecordVisibleToActor(ctx: *Context, scope: []const u8, permissions_json: []const u8) bool {
    if (recordVisibleToActor(ctx, scope, permissions_json)) return true;
    if (!domain.isActorOwnedAgentMemoryScope(scope, ctx.actor_id)) return false;
    const policy = ctx.store.getPolicyScope(ctx.allocator, scope) catch return false;
    if (policy) |p| {
        if (!domain.recordVisible(p.scope, p.permissions_json, tryFeedScopesJson(ctx))) return false;
    }
    return access.permissionsVisibleForActor(ctx.allocator, permissions_json, ctx.actor_scopes_json, ctx.actor_id);
}

fn tryFeedScopesJson(ctx: *Context) []const u8 {
    return feedScopesJson(ctx) catch ctx.actor_scopes_json;
}

fn canCreateMemoryAtom(ctx: *Context, input: store_mod.MemoryAtomInput) bool {
    const status = input.status orelse domain.defaultMemoryStatus(input.created_by, input.scope);
    if (std.mem.eql(u8, status, "proposed")) return canProposeRecord(ctx, input.scope, input.permissions_json);
    if (std.mem.eql(u8, status, "verified")) {
        return hasCapability(ctx, "verify") and
            domain.scopeVerifiable(input.scope, ctx.actor_scopes_json) and
            canWriteRecord(ctx, input.scope, input.permissions_json);
    }
    return canWriteRecord(ctx, input.scope, input.permissions_json);
}

fn memoryAtomWritable(ctx: *Context, id: []const u8) bool {
    const atom = ctx.store.getMemoryAtom(ctx.allocator, id) catch return false;
    const existing = atom orelse return false;
    return canWriteRecord(ctx, existing.scope, existing.permissions_json);
}

fn canChangeMemoryStatus(ctx: *Context, id: []const u8, status: []const u8) bool {
    const atom = ctx.store.getMemoryAtom(ctx.allocator, id) catch return false;
    const existing = atom orelse return false;
    if (!recordVisibleToActor(ctx, existing.scope, existing.permissions_json)) return false;
    const policy = ctx.store.getPolicyScope(ctx.allocator, existing.scope) catch return false;
    if (policy) |p| {
        if (!domain.permissionsWritable(p.permissions_json, ctx.actor_scopes_json)) return false;
    }
    if (std.mem.eql(u8, status, "verified")) return hasCapability(ctx, "verify") and domain.scopeVerifiable(existing.scope, ctx.actor_scopes_json) and domain.permissionsWritable(existing.permissions_json, ctx.actor_scopes_json);
    if (std.mem.eql(u8, status, "deprecated") or std.mem.eql(u8, status, "rejected")) return hasCapability(ctx, "delete") and domain.scopeDeletable(existing.scope, ctx.actor_scopes_json) and domain.permissionsWritable(existing.permissions_json, ctx.actor_scopes_json);
    if (std.mem.eql(u8, status, "stale") or std.mem.eql(u8, status, "superseded")) return hasCapability(ctx, "verify") and domain.scopeVerifiable(existing.scope, ctx.actor_scopes_json) and domain.permissionsWritable(existing.permissions_json, ctx.actor_scopes_json);
    return memoryAtomWritable(ctx, id);
}

fn canChangeGraphPrimitiveStatus(ctx: *Context, scope: []const u8, permissions_json: []const u8, status: []const u8) bool {
    const policy = ctx.store.getPolicyScope(ctx.allocator, scope) catch return false;
    if (policy) |p| {
        if (!domain.permissionsWritable(p.permissions_json, ctx.actor_scopes_json)) return false;
    }
    if (std.mem.eql(u8, status, "verified") or std.mem.eql(u8, status, "accepted")) {
        return hasCapability(ctx, "verify") and domain.scopeVerifiable(scope, ctx.actor_scopes_json) and domain.permissionsWritable(permissions_json, ctx.actor_scopes_json);
    }
    if (std.mem.eql(u8, status, "deprecated") or std.mem.eql(u8, status, "rejected")) {
        return hasCapability(ctx, "delete") and domain.scopeDeletable(scope, ctx.actor_scopes_json) and domain.permissionsWritable(permissions_json, ctx.actor_scopes_json);
    }
    if (std.mem.eql(u8, status, "stale") or std.mem.eql(u8, status, "superseded")) {
        return hasCapability(ctx, "verify") and domain.scopeVerifiable(scope, ctx.actor_scopes_json) and domain.permissionsWritable(permissions_json, ctx.actor_scopes_json);
    }
    return hasCapability(ctx, "write") and domain.scopeWritable(scope, ctx.actor_scopes_json) and domain.permissionsWritable(permissions_json, ctx.actor_scopes_json);
}

fn canApplyFeed(ctx: *Context) bool {
    return hasCapability(ctx, "feed_apply") or hasCapability(ctx, "write");
}

const VectorAcl = struct {
    scope: []const u8,
    permissions_json: []const u8,
};

fn resolveVectorAcl(ctx: *Context, object_type: []const u8, object_id: []const u8, requested_scope: []const u8, requested_permissions: []const u8) !VectorAcl {
    _ = requested_scope;
    _ = requested_permissions;
    const acl = (try ctx.store.vectorObjectAcl(ctx.allocator, object_type, object_id, ctx.actor_id)) orelse return error.NotFound;
    if (!canWriteRecord(ctx, acl.scope, acl.permissions_json)) return error.Forbidden;
    return .{ .scope = acl.scope, .permissions_json = acl.permissions_json };
}

fn positiveLimit(value: ?i64, default_value: usize) usize {
    const raw = value orelse return default_value;
    if (raw <= 0) return default_value;
    return @intCast(@min(raw, 500));
}

fn parseLimit(value: ?[]const u8, default_value: usize) usize {
    const raw = value orelse return default_value;
    const parsed = std.fmt.parseInt(usize, raw, 10) catch return default_value;
    return @min(parsed, 500);
}

fn queryBool(query: []const u8, name: []const u8, default_value: bool) bool {
    const raw = json.queryParam(query, name) orelse return default_value;
    return std.ascii.eqlIgnoreCase(raw, "true") or
        std.mem.eql(u8, raw, "1") or
        std.ascii.eqlIgnoreCase(raw, "yes") or
        std.ascii.eqlIgnoreCase(raw, "on");
}

fn ok(ctx: *Context, body: []const u8) HttpResponse {
    return .{ .status = "200 OK", .body = ctx.allocator.dupe(u8, body) catch body };
}

fn serverError(ctx: *Context) HttpResponse {
    return json.errorResponse(ctx.allocator, 500, "internal_error", "Internal server error");
}

fn agentMemoryStorageUnavailable(ctx: *Context) HttpResponse {
    return json.errorResponse(ctx.allocator, 400, "storage_unavailable", "Requested agent memory storage is not configured");
}

fn forbidden(ctx: *Context) HttpResponse {
    return json.errorResponse(ctx.allocator, 403, "forbidden", "Actor is not allowed to write this scope or permission set");
}

fn badJson(ctx: *Context) HttpResponse {
    return json.errorResponse(ctx.allocator, 400, "invalid_json", "Expected JSON object body");
}

fn eql(value: ?[]const u8, expected: []const u8) bool {
    return if (value) |v| std.mem.eql(u8, v, expected) else false;
}

fn decodeSegment(allocator: std.mem.Allocator, value: ?[]const u8) !?[]u8 {
    const src = value orelse return null;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < src.len) : (i += 1) {
        if (src[i] == '%' and i + 2 < src.len) {
            const byte = std.fmt.parseInt(u8, src[i + 1 .. i + 3], 16) catch {
                try out.append(allocator, src[i]);
                continue;
            };
            try out.append(allocator, byte);
            i += 2;
        } else if (src[i] == '+') {
            try out.append(allocator, ' ');
        } else {
            try out.append(allocator, src[i]);
        }
    }
    const owned = try out.toOwnedSlice(allocator);
    return owned;
}

fn extractJsonString(allocator: std.mem.Allocator, body: []const u8, marker: []const u8) ![]const u8 {
    const start_marker = std.mem.indexOf(u8, body, marker) orelse return error.MissingMarker;
    const start = start_marker + marker.len;
    const end_rel = std.mem.indexOfScalar(u8, body[start..], '"') orelse return error.MissingMarker;
    return allocator.dupe(u8, body[start .. start + end_rel]);
}

test "api creates source" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = Context{ .allocator = arena.allocator(), .store = &store };
    const resp = handleRequest(&ctx, "POST", "/v1/sources", "{\"title\":\"Meeting\",\"type\":\"transcript\",\"content\":\"hello\"}", "");
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"src_") != null);
}

test "api requires bearer token except health" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = Context{ .allocator = arena.allocator(), .store = &store, .required_token = "secret" };

    const health_resp = handleRequest(&ctx, "GET", "/health", "", "");
    try std.testing.expectEqualStrings("200 OK", health_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, health_resp.body, "\"schema_ok\":true") != null);
    const expected_schema = try std.fmt.allocPrint(arena.allocator(), "\"expected_schema_version\":{d}", .{migrations.expected_schema_version});
    try std.testing.expect(std.mem.indexOf(u8, health_resp.body, expected_schema) != null);
    const v1_health_resp = handleRequest(&ctx, "GET", "/v1/health", "", "");
    try std.testing.expectEqualStrings("200 OK", v1_health_resp.status);

    const missing = handleRequest(&ctx, "POST", "/v1/search", "{\"query\":\"x\"}", "");
    try std.testing.expectEqualStrings("401 Unauthorized", missing.status);

    const authed = handleRequest(&ctx, "POST", "/v1/search", "{\"query\":\"x\"}", "POST /v1/search HTTP/1.1\r\nAuthorization: Bearer secret\r\n\r\n{\"query\":\"x\"}");
    try std.testing.expectEqualStrings("200 OK", authed.status);
}

test "api token principal registry maps per-token scopes and capabilities" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const principals =
        \\{"reader-token":{"actor_id":"reader","scopes":["public"],"capabilities":["read"]},"writer-token":{"actor_id":"writer","scopes":["public","write:public"],"capabilities":["read","write","propose"]}}
    ;
    var ctx = Context{ .allocator = arena.allocator(), .store = &store, .token_principals_json = principals };

    const reader_raw = "POST /v1/sources HTTP/1.1\r\nAuthorization: Bearer reader-token\r\nX-NullPantry-Actor-Scopes: [\"admin\"]\r\nX-NullPantry-Actor-Capabilities: [\"write\"]\r\n\r\n{}";
    const reader_write = handleRequest(&ctx, "POST", "/v1/sources", "{\"title\":\"nope\",\"scope\":\"public\"}", reader_raw);
    try std.testing.expectEqualStrings("403 Forbidden", reader_write.status);

    const writer_raw = "POST /v1/sources HTTP/1.1\r\nAuthorization: Bearer writer-token\r\n\r\n{}";
    const writer_write = handleRequest(&ctx, "POST", "/v1/sources", "{\"title\":\"ok\",\"scope\":\"public\",\"content\":\"visible\"}", writer_raw);
    try std.testing.expectEqualStrings("200 OK", writer_write.status);

    const unknown_raw = "POST /v1/search HTTP/1.1\r\nAuthorization: Bearer missing-token\r\n\r\n{}";
    const unknown = handleRequest(&ctx, "POST", "/v1/search", "{\"query\":\"visible\"}", unknown_raw);
    try std.testing.expectEqualStrings("401 Unauthorized", unknown.status);
}

test "api token principal actor cannot be spoofed by actor header" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const principals =
        \\{"real-token":{"actor_id":"agent:real","scopes":["session:*","write:session:*"],"capabilities":["read","write","delete"]}}
    ;
    var ctx = Context{ .allocator = alloc, .store = &store, .token_principals_json = principals };

    const raw = "PUT /v1/agent-memory/spoof.test HTTP/1.1\r\nAuthorization: Bearer real-token\r\nX-NullPantry-Actor-Id: agent:spoof\r\n\r\n{}";
    const put = handleRequest(&ctx, "PUT", "/v1/agent-memory/spoof.test", "{\"content\":\"header must not own this memory\"}", raw);
    try std.testing.expectEqualStrings("200 OK", put.status);

    try std.testing.expect((try store.agentMemoryGet(alloc, "spoof.test", null, "agent:spoof")) == null);
    const real = (try store.agentMemoryGet(alloc, "spoof.test", null, "agent:real")).?;
    try std.testing.expectEqualStrings("header must not own this memory", real.content);
}

test "api native agent memory is actor isolated" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const principals =
        \\{"agent-a":{"actor_id":"agent:a","scopes":["session:*","session:sess_api","write:session:*","write:session:sess_api"],"capabilities":["read","write","delete"]},"agent-b":{"actor_id":"agent:b","scopes":["session:*","write:session:*"],"capabilities":["read","write","delete"]}}
    ;
    var ctx = Context{ .allocator = alloc, .store = &store, .token_principals_json = principals };

    const raw_a = "PUT /v1/agent-memory/shared.pref HTTP/1.1\r\nAuthorization: Bearer agent-a\r\n\r\n{}";
    const raw_b = "PUT /v1/agent-memory/shared.pref HTTP/1.1\r\nAuthorization: Bearer agent-b\r\n\r\n{}";
    const put_a = handleRequest(&ctx, "PUT", "/v1/agent-memory/shared.pref", "{\"content\":\"Agent A native API value\"}", raw_a);
    try std.testing.expectEqualStrings("200 OK", put_a.status);
    const put_b = handleRequest(&ctx, "PUT", "/v1/agent-memory/shared.pref", "{\"content\":\"Agent B native API value\"}", raw_b);
    try std.testing.expectEqualStrings("200 OK", put_b.status);

    const get_a = handleRequest(&ctx, "GET", "/v1/agent-memory/shared.pref", "", raw_a);
    try std.testing.expectEqualStrings("200 OK", get_a.status);
    try std.testing.expect(std.mem.indexOf(u8, get_a.body, "Agent A native API value") != null);
    try std.testing.expect(std.mem.indexOf(u8, get_a.body, "Agent B native API value") == null);

    const search_a = handleRequest(&ctx, "POST", "/v1/agent-memory/search", "{\"query\":\"Agent B\",\"limit\":10}", "POST /v1/agent-memory/search HTTP/1.1\r\nAuthorization: Bearer agent-a\r\n\r\n{}");
    try std.testing.expectEqualStrings("200 OK", search_a.status);
    try std.testing.expect(std.mem.indexOf(u8, search_a.body, "Agent B native API value") == null);

    const session_put = handleRequest(&ctx, "PUT", "/v1/agent-memory/session.pref", "{\"content\":\"Agent A session API value\",\"session_id\":\"sess_api\"}", raw_a);
    try std.testing.expectEqualStrings("200 OK", session_put.status);
    const session_get = handleRequest(&ctx, "GET", "/v1/agent-memory/session.pref?session_id=sess_api", "", raw_a);
    try std.testing.expectEqualStrings("200 OK", session_get.status);
    try std.testing.expect(std.mem.indexOf(u8, session_get.body, "Agent A session API value") != null);
}

test "api agent memory supports explicit storage routing" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const principals =
        \\{"agent-route":{"actor_id":"agent:route","scopes":["public"],"capabilities":["read","write","delete"]}}
    ;
    var ctx = Context{ .allocator = alloc, .store = &store, .token_principals_json = principals };
    const raw = "PUT /v1/agent-memory/routed.native HTTP/1.1\r\nAuthorization: Bearer agent-route\r\n\r\n{}";

    const native_put = handleRequest(&ctx, "PUT", "/v1/agent-memory/routed.native", "{\"content\":\"Native routed value\",\"storage\":\"native\"}", raw);
    try std.testing.expectEqualStrings("200 OK", native_put.status);
    const native_get = handleRequest(&ctx, "GET", "/v1/agent-memory/routed.native?storage=native", "", "GET /v1/agent-memory/routed.native?storage=native HTTP/1.1\r\nAuthorization: Bearer agent-route\r\n\r\n");
    try std.testing.expectEqualStrings("200 OK", native_get.status);
    try std.testing.expect(std.mem.indexOf(u8, native_get.body, "Native routed value") != null);

    const runtime_get = handleRequest(&ctx, "GET", "/v1/agent-memory/routed.native?storage=redis", "", "GET /v1/agent-memory/routed.native?storage=redis HTTP/1.1\r\nAuthorization: Bearer agent-route\r\n\r\n");
    try std.testing.expectEqualStrings("400 Bad Request", runtime_get.status);
    try std.testing.expect(std.mem.indexOf(u8, runtime_get.body, "storage_unavailable") != null);

    const runtime_put = handleRequest(&ctx, "PUT", "/v1/agent-memory/routed.runtime", "{\"content\":\"Runtime requested value\",\"storage\":\"runtime\"}", raw);
    try std.testing.expectEqualStrings("400 Bad Request", runtime_put.status);
    try std.testing.expect(std.mem.indexOf(u8, runtime_put.body, "storage_unavailable") != null);

    const all_put = handleRequest(&ctx, "PUT", "/v1/agent-memory/routed.all", "{\"content\":\"All routed value\",\"storage\":\"all\"}", raw);
    try std.testing.expectEqualStrings("200 OK", all_put.status);
    const all_search = handleRequest(&ctx, "POST", "/v1/agent-memory/search", "{\"query\":\"routed value\",\"storage\":\"all\",\"limit\":10}", "POST /v1/agent-memory/search HTTP/1.1\r\nAuthorization: Bearer agent-route\r\n\r\n{}");
    try std.testing.expectEqualStrings("200 OK", all_search.status);
    try std.testing.expect(std.mem.indexOf(u8, all_search.body, "Native routed value") != null);
    try std.testing.expect(std.mem.indexOf(u8, all_search.body, "All routed value") != null);

    const all_count = handleRequest(&ctx, "GET", "/v1/agent-memory/count?storage=all", "", "GET /v1/agent-memory/count?storage=all HTTP/1.1\r\nAuthorization: Bearer agent-route\r\n\r\n");
    try std.testing.expectEqualStrings("200 OK", all_count.status);
    try std.testing.expect(std.mem.indexOf(u8, all_count.body, "\"count\":2") != null);
}

test "api agent memory supports named stores and federated runtime reads" {
    var store = try Store.initSQLiteWithOptions(std.testing.allocator, ":memory:", .{
        .agent_memory = .{ .backend = .memory_lru },
        .agent_memory_stores = &.{
            .{ .name = "scratch", .config = .{ .backend = .memory_lru } },
            .{ .name = "archive", .config = .{ .backend = .memory_lru } },
        },
    });
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const principals =
        \\{"agent-route":{"actor_id":"agent:route","scopes":["public","write:public","session:*","write:session:*"],"capabilities":["read","write","delete"]}}
    ;
    var ctx = Context{ .allocator = alloc, .store = &store, .token_principals_json = principals };
    const raw = "PUT /v1/agent-memory/named.scratch HTTP/1.1\r\nAuthorization: Bearer agent-route\r\n\r\n{}";

    const scratch_put = handleRequest(&ctx, "PUT", "/v1/agent-memory/named.scratch", "{\"content\":\"Named Scratch Unique\",\"store\":\"scratch\"}", raw);
    try std.testing.expectEqualStrings("200 OK", scratch_put.status);
    const archive_put = handleRequest(&ctx, "PUT", "/v1/agent-memory/named.archive", "{\"content\":\"Named Archive Unique\",\"store\":\"archive\"}", raw);
    try std.testing.expectEqualStrings("200 OK", archive_put.status);
    const runtime_put = handleRequest(&ctx, "PUT", "/v1/agent-memory/named.runtime", "{\"content\":\"Named Default Runtime Unique\",\"store\":\"runtime\"}", raw);
    try std.testing.expectEqualStrings("200 OK", runtime_put.status);
    const native_put = handleRequest(&ctx, "PUT", "/v1/agent-memory/named.native", "{\"content\":\"Named Native Unique\",\"store\":\"native\"}", raw);
    try std.testing.expectEqualStrings("200 OK", native_put.status);

    const scratch_get = handleRequest(&ctx, "GET", "/v1/agent-memory/named.scratch?store=scratch", "", "GET /v1/agent-memory/named.scratch?store=scratch HTTP/1.1\r\nAuthorization: Bearer agent-route\r\n\r\n");
    try std.testing.expectEqualStrings("200 OK", scratch_get.status);
    try std.testing.expect(std.mem.indexOf(u8, scratch_get.body, "Named Scratch Unique") != null);

    const wrong_store_get = handleRequest(&ctx, "GET", "/v1/agent-memory/named.scratch?store=archive", "", "GET /v1/agent-memory/named.scratch?store=archive HTTP/1.1\r\nAuthorization: Bearer agent-route\r\n\r\n");
    try std.testing.expectEqualStrings("404 Not Found", wrong_store_get.status);

    const named_search = handleRequest(&ctx, "POST", "/v1/agent-memory/search", "{\"query\":\"Named Scratch Unique\",\"store\":\"scratch\",\"limit\":10}", "POST /v1/agent-memory/search HTTP/1.1\r\nAuthorization: Bearer agent-route\r\n\r\n{}");
    try std.testing.expectEqualStrings("200 OK", named_search.status);
    try std.testing.expect(std.mem.indexOf(u8, named_search.body, "Named Scratch Unique") != null);
    try std.testing.expect(std.mem.indexOf(u8, named_search.body, "Named Archive Unique") == null);

    const subset_put = handleRequest(&ctx, "PUT", "/v1/agent-memory/named.subset", "{\"content\":\"Named Exact Subset Unique\",\"stores\":[\"scratch\",\"archive\"]}", raw);
    try std.testing.expectEqualStrings("200 OK", subset_put.status);
    const subset_scratch = handleRequest(&ctx, "GET", "/v1/agent-memory/named.subset?store=scratch", "", "GET /v1/agent-memory/named.subset?store=scratch HTTP/1.1\r\nAuthorization: Bearer agent-route\r\n\r\n");
    try std.testing.expectEqualStrings("200 OK", subset_scratch.status);
    const subset_archive = handleRequest(&ctx, "GET", "/v1/agent-memory/named.subset?store=archive", "", "GET /v1/agent-memory/named.subset?store=archive HTTP/1.1\r\nAuthorization: Bearer agent-route\r\n\r\n");
    try std.testing.expectEqualStrings("200 OK", subset_archive.status);
    const subset_runtime = handleRequest(&ctx, "GET", "/v1/agent-memory/named.subset?store=runtime", "", "GET /v1/agent-memory/named.subset?store=runtime HTTP/1.1\r\nAuthorization: Bearer agent-route\r\n\r\n");
    try std.testing.expectEqualStrings("404 Not Found", subset_runtime.status);
    const subset_native = handleRequest(&ctx, "GET", "/v1/agent-memory/named.subset?store=native", "", "GET /v1/agent-memory/named.subset?store=native HTTP/1.1\r\nAuthorization: Bearer agent-route\r\n\r\n");
    try std.testing.expectEqualStrings("404 Not Found", subset_native.status);

    const subset_search = handleRequest(&ctx, "POST", "/v1/agent-memory/search", "{\"query\":\"Named\",\"stores\":[\"scratch\",\"archive\"],\"limit\":10}", "POST /v1/agent-memory/search HTTP/1.1\r\nAuthorization: Bearer agent-route\r\n\r\n{}");
    try std.testing.expectEqualStrings("200 OK", subset_search.status);
    try std.testing.expect(std.mem.indexOf(u8, subset_search.body, "Named Scratch Unique") != null);
    try std.testing.expect(std.mem.indexOf(u8, subset_search.body, "Named Archive Unique") != null);
    try std.testing.expect(std.mem.indexOf(u8, subset_search.body, "Named Exact Subset Unique") != null);
    try std.testing.expect(std.mem.indexOf(u8, subset_search.body, "Named Default Runtime Unique") == null);
    try std.testing.expect(std.mem.indexOf(u8, subset_search.body, "Named Native Unique") == null);

    const subset_query_list = handleRequest(&ctx, "GET", "/v1/agent-memory?stores=scratch,archive", "", "GET /v1/agent-memory?stores=scratch,archive HTTP/1.1\r\nAuthorization: Bearer agent-route\r\n\r\n");
    try std.testing.expectEqualStrings("200 OK", subset_query_list.status);
    try std.testing.expect(std.mem.indexOf(u8, subset_query_list.body, "Named Exact Subset Unique") != null);
    try std.testing.expect(std.mem.indexOf(u8, subset_query_list.body, "Named Default Runtime Unique") == null);

    const global_search = handleRequest(&ctx, "POST", "/v1/search", "{\"query\":\"Named Archive Unique\",\"use_vector\":false,\"limit\":10}", "POST /v1/search HTTP/1.1\r\nAuthorization: Bearer agent-route\r\n\r\n{}");
    try std.testing.expectEqualStrings("200 OK", global_search.status);
    try std.testing.expect(std.mem.indexOf(u8, global_search.body, "Named Archive Unique") != null);

    const routed_scratch_search = handleRequest(&ctx, "POST", "/v1/search", "{\"query\":\"Named\",\"store\":\"scratch\",\"use_vector\":false,\"limit\":10}", "POST /v1/search HTTP/1.1\r\nAuthorization: Bearer agent-route\r\n\r\n{}");
    try std.testing.expectEqualStrings("200 OK", routed_scratch_search.status);
    try std.testing.expect(std.mem.indexOf(u8, routed_scratch_search.body, "Named Scratch Unique") != null);
    try std.testing.expect(std.mem.indexOf(u8, routed_scratch_search.body, "Named Archive Unique") == null);
    try std.testing.expect(std.mem.indexOf(u8, routed_scratch_search.body, "Named Native Unique") == null);

    const routed_subset_search = handleRequest(&ctx, "POST", "/v1/retrieval/search", "{\"query\":\"Named\",\"stores\":[\"scratch\",\"archive\"],\"use_vector\":false,\"limit\":10}", "POST /v1/retrieval/search HTTP/1.1\r\nAuthorization: Bearer agent-route\r\n\r\n{}");
    try std.testing.expectEqualStrings("200 OK", routed_subset_search.status);
    try std.testing.expect(std.mem.indexOf(u8, routed_subset_search.body, "Named Scratch Unique") != null);
    try std.testing.expect(std.mem.indexOf(u8, routed_subset_search.body, "Named Archive Unique") != null);
    try std.testing.expect(std.mem.indexOf(u8, routed_subset_search.body, "Named Default Runtime Unique") == null);
    try std.testing.expect(std.mem.indexOf(u8, routed_subset_search.body, "Named Native Unique") == null);

    const routed_native_search = handleRequest(&ctx, "POST", "/v1/search", "{\"query\":\"Named\",\"storage\":\"native\",\"use_vector\":false,\"limit\":10}", "POST /v1/search HTTP/1.1\r\nAuthorization: Bearer agent-route\r\n\r\n{}");
    try std.testing.expectEqualStrings("200 OK", routed_native_search.status);
    try std.testing.expect(std.mem.indexOf(u8, routed_native_search.body, "Named Native Unique") != null);
    try std.testing.expect(std.mem.indexOf(u8, routed_native_search.body, "Named Scratch Unique") == null);
    try std.testing.expect(std.mem.indexOf(u8, routed_native_search.body, "Named Archive Unique") == null);

    const scratch_source = handleRequest(&ctx, "POST", "/v1/sources", "{\"title\":\"Primitive Scratch Source\",\"content\":\"Primitive scratch source body\",\"scope\":\"public\",\"store\":\"scratch\"}", "POST /v1/sources HTTP/1.1\r\nAuthorization: Bearer agent-route\r\n\r\n{}");
    try std.testing.expectEqualStrings("200 OK", scratch_source.status);
    const scratch_source_search = handleRequest(&ctx, "POST", "/v1/search", "{\"query\":\"Primitive scratch source body\",\"store\":\"scratch\",\"use_vector\":false,\"limit\":10}", "POST /v1/search HTTP/1.1\r\nAuthorization: Bearer agent-route\r\n\r\n{}");
    try std.testing.expectEqualStrings("200 OK", scratch_source_search.status);
    try std.testing.expect(std.mem.indexOf(u8, scratch_source_search.body, "Primitive Scratch Source") != null);
    const archive_source_search = handleRequest(&ctx, "POST", "/v1/search", "{\"query\":\"Primitive scratch source body\",\"store\":\"archive\",\"use_vector\":false,\"limit\":10}", "POST /v1/search HTTP/1.1\r\nAuthorization: Bearer agent-route\r\n\r\n{}");
    try std.testing.expectEqualStrings("200 OK", archive_source_search.status);
    try std.testing.expect(std.mem.indexOf(u8, archive_source_search.body, "Primitive Scratch Source") == null);
    const native_source_search = handleRequest(&ctx, "POST", "/v1/search", "{\"query\":\"Primitive scratch source body\",\"storage\":\"native\",\"use_vector\":false,\"limit\":10}", "POST /v1/search HTTP/1.1\r\nAuthorization: Bearer agent-route\r\n\r\n{}");
    try std.testing.expectEqualStrings("200 OK", native_source_search.status);
    try std.testing.expect(std.mem.indexOf(u8, native_source_search.body, "Primitive Scratch Source") != null);

    const archive_artifact = handleRequest(&ctx, "POST", "/v1/artifacts", "{\"type\":\"page\",\"title\":\"Primitive Archive Artifact\",\"body\":\"Primitive archive artifact body\",\"scope\":\"public\",\"store\":\"archive\"}", "POST /v1/artifacts HTTP/1.1\r\nAuthorization: Bearer agent-route\r\n\r\n{}");
    try std.testing.expectEqualStrings("200 OK", archive_artifact.status);
    const archive_artifact_search = handleRequest(&ctx, "POST", "/v1/search", "{\"query\":\"Primitive archive artifact body\",\"store\":\"archive\",\"use_vector\":false,\"limit\":10}", "POST /v1/search HTTP/1.1\r\nAuthorization: Bearer agent-route\r\n\r\n{}");
    try std.testing.expectEqualStrings("200 OK", archive_artifact_search.status);
    try std.testing.expect(std.mem.indexOf(u8, archive_artifact_search.body, "Primitive Archive Artifact") != null);
    const scratch_artifact_search = handleRequest(&ctx, "POST", "/v1/search", "{\"query\":\"Primitive archive artifact body\",\"store\":\"scratch\",\"use_vector\":false,\"limit\":10}", "POST /v1/search HTTP/1.1\r\nAuthorization: Bearer agent-route\r\n\r\n{}");
    try std.testing.expectEqualStrings("200 OK", scratch_artifact_search.status);
    try std.testing.expect(std.mem.indexOf(u8, scratch_artifact_search.body, "Primitive Archive Artifact") == null);

    const scratch_atom = handleRequest(&ctx, "POST", "/v1/memory-atoms", "{\"text\":\"Primitive scratch atom body\",\"scope\":\"public\",\"created_by\":\"agent\",\"store\":\"scratch\"}", "POST /v1/memory-atoms HTTP/1.1\r\nAuthorization: Bearer agent-route\r\n\r\n{}");
    try std.testing.expectEqualStrings("200 OK", scratch_atom.status);
    const scratch_atom_search = handleRequest(&ctx, "POST", "/v1/search", "{\"query\":\"Primitive scratch atom body\",\"store\":\"scratch\",\"use_vector\":false,\"limit\":10}", "POST /v1/search HTTP/1.1\r\nAuthorization: Bearer agent-route\r\n\r\n{}");
    try std.testing.expectEqualStrings("200 OK", scratch_atom_search.status);
    try std.testing.expect(std.mem.indexOf(u8, scratch_atom_search.body, "Primitive scratch atom body") != null);

    const native_source = handleRequest(&ctx, "POST", "/v1/sources", "{\"title\":\"Primitive Native Only Source\",\"content\":\"Primitive native only body\",\"scope\":\"public\",\"storage\":\"native\"}", "POST /v1/sources HTTP/1.1\r\nAuthorization: Bearer agent-route\r\n\r\n{}");
    try std.testing.expectEqualStrings("200 OK", native_source.status);
    const runtime_native_source_search = handleRequest(&ctx, "POST", "/v1/search", "{\"query\":\"Primitive native only body\",\"store\":\"runtime\",\"use_vector\":false,\"limit\":10}", "POST /v1/search HTTP/1.1\r\nAuthorization: Bearer agent-route\r\n\r\n{}");
    try std.testing.expectEqualStrings("200 OK", runtime_native_source_search.status);
    try std.testing.expect(std.mem.indexOf(u8, runtime_native_source_search.body, "Primitive Native Only Source") == null);

    const missing_source_store = handleRequest(&ctx, "POST", "/v1/sources", "{\"title\":\"Primitive Missing Store\",\"content\":\"must not fall back\",\"scope\":\"public\",\"store\":\"missing\"}", "POST /v1/sources HTTP/1.1\r\nAuthorization: Bearer agent-route\r\n\r\n{}");
    try std.testing.expectEqualStrings("400 Bad Request", missing_source_store.status);
    try std.testing.expect(std.mem.indexOf(u8, missing_source_store.body, "storage_unavailable") != null);

    const routed_context_pack = handleRequest(&ctx, "POST", "/v1/context-packs", "{\"task\":\"Named Archive Unique\",\"store\":\"archive\",\"use_vector\":false,\"limit\":10,\"persist\":false}", "POST /v1/context-packs HTTP/1.1\r\nAuthorization: Bearer agent-route\r\n\r\n{}");
    try std.testing.expectEqualStrings("200 OK", routed_context_pack.status);
    try std.testing.expect(std.mem.indexOf(u8, routed_context_pack.body, "Named Archive Unique") != null);
    try std.testing.expect(std.mem.indexOf(u8, routed_context_pack.body, "Named Scratch Unique") == null);

    const routed_ask = handleRequest(&ctx, "POST", "/v1/ask", "{\"query\":\"Named Scratch Unique\",\"store\":\"scratch\",\"use_vector\":false}", "POST /v1/ask HTTP/1.1\r\nAuthorization: Bearer agent-route\r\n\r\n{}");
    try std.testing.expectEqualStrings("200 OK", routed_ask.status);
    try std.testing.expect(std.mem.indexOf(u8, routed_ask.body, "Named Scratch Unique") != null);
    try std.testing.expect(std.mem.indexOf(u8, routed_ask.body, "Named Archive Unique") == null);

    const feed_resp = handleRequest(&ctx, "GET", "/v1/memory/feed?limit=100", "", "GET /v1/memory/feed?limit=100 HTTP/1.1\r\nAuthorization: Bearer agent-route\r\n\r\n");
    try std.testing.expectEqualStrings("200 OK", feed_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, feed_resp.body, "agent_memory.runtime_put") != null);
    try std.testing.expect(std.mem.indexOf(u8, feed_resp.body, "\"store\":\"archive\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, feed_resp.body, "Named Archive Unique") != null);
    try std.testing.expect(std.mem.indexOf(u8, feed_resp.body, "agent_memory.put") != null);

    const session_put = handleRequest(&ctx, "POST", "/v1/agent-sessions/named-session/messages", "{\"role\":\"assistant\",\"content\":\"Named scratch session message\",\"store\":\"scratch\"}", "POST /v1/agent-sessions/named-session/messages HTTP/1.1\r\nAuthorization: Bearer agent-route\r\n\r\n{}");
    try std.testing.expectEqualStrings("200 OK", session_put.status);
    const session_subset_put = handleRequest(&ctx, "POST", "/v1/agent-sessions/named-session/messages", "{\"role\":\"assistant\",\"content\":\"Named exact subset session message\",\"stores\":[\"scratch\",\"archive\"]}", "POST /v1/agent-sessions/named-session/messages HTTP/1.1\r\nAuthorization: Bearer agent-route\r\n\r\n{}");
    try std.testing.expectEqualStrings("200 OK", session_subset_put.status);
    const session_scratch = handleRequest(&ctx, "GET", "/v1/agent-sessions/named-session/messages?store=scratch", "", "GET /v1/agent-sessions/named-session/messages?store=scratch HTTP/1.1\r\nAuthorization: Bearer agent-route\r\n\r\n");
    try std.testing.expect(std.mem.indexOf(u8, session_scratch.body, "Named scratch session message") != null);
    try std.testing.expect(std.mem.indexOf(u8, session_scratch.body, "Named exact subset session message") != null);
    const session_archive = handleRequest(&ctx, "GET", "/v1/agent-sessions/named-session/messages?store=archive", "", "GET /v1/agent-sessions/named-session/messages?store=archive HTTP/1.1\r\nAuthorization: Bearer agent-route\r\n\r\n");
    try std.testing.expect(std.mem.indexOf(u8, session_archive.body, "Named scratch session message") == null);
    try std.testing.expect(std.mem.indexOf(u8, session_archive.body, "Named exact subset session message") != null);
    const session_runtime = handleRequest(&ctx, "GET", "/v1/agent-sessions/named-session/messages?store=runtime", "", "GET /v1/agent-sessions/named-session/messages?store=runtime HTTP/1.1\r\nAuthorization: Bearer agent-route\r\n\r\n");
    try std.testing.expect(std.mem.indexOf(u8, session_runtime.body, "Named exact subset session message") == null);

    const usage_subset_put = handleRequest(&ctx, "PUT", "/v1/agent-sessions/named-session/usage", "{\"total_tokens\":77,\"stores\":[\"scratch\",\"archive\"]}", "PUT /v1/agent-sessions/named-session/usage HTTP/1.1\r\nAuthorization: Bearer agent-route\r\n\r\n{}");
    try std.testing.expectEqualStrings("200 OK", usage_subset_put.status);
    const usage_subset_get = handleRequest(&ctx, "GET", "/v1/agent-sessions/named-session/usage?stores=scratch,archive", "", "GET /v1/agent-sessions/named-session/usage?stores=scratch,archive HTTP/1.1\r\nAuthorization: Bearer agent-route\r\n\r\n");
    try std.testing.expectEqualStrings("200 OK", usage_subset_get.status);
    try std.testing.expect(std.mem.indexOf(u8, usage_subset_get.body, "\"total_tokens\":77") != null);
    const usage_runtime_get = handleRequest(&ctx, "GET", "/v1/agent-sessions/named-session/usage?store=runtime", "", "GET /v1/agent-sessions/named-session/usage?store=runtime HTTP/1.1\r\nAuthorization: Bearer agent-route\r\n\r\n");
    try std.testing.expectEqualStrings("404 Not Found", usage_runtime_get.status);

    const missing = handleRequest(&ctx, "PUT", "/v1/agent-memory/named.missing", "{\"content\":\"must not fall back\",\"store\":\"missing\"}", raw);
    try std.testing.expectEqualStrings("400 Bad Request", missing.status);
    try std.testing.expect(std.mem.indexOf(u8, missing.body, "storage_unavailable") != null);
}

test "api memory checkpoint restore preserves named runtime storage plane" {
    var source_store = try Store.initSQLiteWithOptions(std.testing.allocator, ":memory:", .{
        .agent_memory_stores = &.{
            .{ .name = "archive", .config = .{ .backend = .memory_lru } },
        },
    });
    defer source_store.deinit();
    var target_store = try Store.initSQLiteWithOptions(std.testing.allocator, ":memory:", .{
        .agent_memory_stores = &.{
            .{ .name = "archive", .config = .{ .backend = .memory_lru } },
        },
    });
    defer target_store.deinit();

    var source_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer source_arena.deinit();
    var target_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer target_arena.deinit();
    const principals =
        \\{"agent-route":{"actor_id":"agent:route","scopes":["public","write:public","actor:agent:route"],"capabilities":["read","write","export","feed_apply"]}}
    ;
    var source_ctx = Context{ .allocator = source_arena.allocator(), .store = &source_store, .token_principals_json = principals };
    var target_ctx = Context{ .allocator = target_arena.allocator(), .store = &target_store, .token_principals_json = principals };
    const raw = "PUT /v1/agent-memory/checkpoint.named HTTP/1.1\r\nAuthorization: Bearer agent-route\r\n\r\n{}";

    const put = handleRequest(&source_ctx, "PUT", "/v1/agent-memory/checkpoint.named", "{\"content\":\"Checkpoint Named Archive Unique\",\"store\":\"archive\",\"scope\":\"public\"}", raw);
    try std.testing.expectEqualStrings("200 OK", put.status);

    const checkpoint = handleRequest(&source_ctx, "GET", "/v1/memory/checkpoint?limit=100", "", "GET /v1/memory/checkpoint?limit=100 HTTP/1.1\r\nAuthorization: Bearer agent-route\r\n\r\n");
    try std.testing.expectEqualStrings("200 OK", checkpoint.status);
    try std.testing.expect(std.mem.indexOf(u8, checkpoint.body, "\"store\":\"archive\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, checkpoint.body, "\"scope\":\"public\"") != null);

    const restore = handleRequest(&target_ctx, "POST", "/v1/memory/checkpoint", checkpoint.body, "POST /v1/memory/checkpoint HTTP/1.1\r\nAuthorization: Bearer agent-route\r\n\r\n");
    try std.testing.expectEqualStrings("200 OK", restore.status);

    const archive_get = handleRequest(&target_ctx, "GET", "/v1/agent-memory/checkpoint.named?store=archive", "", "GET /v1/agent-memory/checkpoint.named?store=archive HTTP/1.1\r\nAuthorization: Bearer agent-route\r\n\r\n");
    try std.testing.expectEqualStrings("200 OK", archive_get.status);
    try std.testing.expect(std.mem.indexOf(u8, archive_get.body, "Checkpoint Named Archive Unique") != null);

    const native_get = handleRequest(&target_ctx, "GET", "/v1/agent-memory/checkpoint.named?store=native", "", "GET /v1/agent-memory/checkpoint.named?store=native HTTP/1.1\r\nAuthorization: Bearer agent-route\r\n\r\n");
    try std.testing.expectEqualStrings("404 Not Found", native_get.status);
}

test "api memory checkpoint restore preserves primitive named runtime mirrors" {
    var source_store = try Store.initSQLiteWithOptions(std.testing.allocator, ":memory:", .{
        .agent_memory = .{ .backend = .memory_lru },
        .agent_memory_stores = &.{
            .{ .name = "scratch", .config = .{ .backend = .memory_lru } },
            .{ .name = "archive", .config = .{ .backend = .memory_lru } },
        },
    });
    defer source_store.deinit();
    var target_store = try Store.initSQLiteWithOptions(std.testing.allocator, ":memory:", .{
        .agent_memory = .{ .backend = .memory_lru },
        .agent_memory_stores = &.{
            .{ .name = "scratch", .config = .{ .backend = .memory_lru } },
            .{ .name = "archive", .config = .{ .backend = .memory_lru } },
        },
    });
    defer target_store.deinit();

    var source_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer source_arena.deinit();
    var target_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer target_arena.deinit();
    const principals =
        \\{"agent-route":{"actor_id":"agent:route","scopes":["public","write:public"],"capabilities":["read","write","export","feed_apply"]}}
    ;
    var source_ctx = Context{ .allocator = source_arena.allocator(), .store = &source_store, .token_principals_json = principals };
    var target_ctx = Context{ .allocator = target_arena.allocator(), .store = &target_store, .token_principals_json = principals };

    const source = handleRequest(&source_ctx, "POST", "/v1/sources", "{\"title\":\"Checkpoint Scratch Source\",\"content\":\"Checkpoint scratch primitive body\",\"scope\":\"public\",\"store\":\"scratch\"}", "POST /v1/sources HTTP/1.1\r\nAuthorization: Bearer agent-route\r\n\r\n");
    try std.testing.expectEqualStrings("200 OK", source.status);
    const atom = handleRequest(&source_ctx, "POST", "/v1/memory-atoms", "{\"text\":\"Checkpoint archive atom body\",\"scope\":\"public\",\"created_by\":\"agent\",\"store\":\"archive\"}", "POST /v1/memory-atoms HTTP/1.1\r\nAuthorization: Bearer agent-route\r\n\r\n");
    try std.testing.expectEqualStrings("200 OK", atom.status);

    const checkpoint = handleRequest(&source_ctx, "GET", "/v1/memory/checkpoint?limit=100", "", "GET /v1/memory/checkpoint?limit=100 HTTP/1.1\r\nAuthorization: Bearer agent-route\r\n\r\n");
    try std.testing.expectEqualStrings("200 OK", checkpoint.status);
    try std.testing.expect(std.mem.indexOf(u8, checkpoint.body, "\"store\":\"scratch\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, checkpoint.body, "\"store\":\"archive\"") != null);

    const restore = handleRequest(&target_ctx, "POST", "/v1/memory/checkpoint", checkpoint.body, "POST /v1/memory/checkpoint HTTP/1.1\r\nAuthorization: Bearer agent-route\r\n\r\n");
    try std.testing.expectEqualStrings("200 OK", restore.status);
    try std.testing.expect(std.mem.indexOf(u8, restore.body, "\"applied_events\"") != null);

    const scratch_source = handleRequest(&target_ctx, "POST", "/v1/search", "{\"query\":\"Checkpoint scratch primitive body\",\"store\":\"scratch\",\"use_vector\":false,\"limit\":10}", "POST /v1/search HTTP/1.1\r\nAuthorization: Bearer agent-route\r\n\r\n");
    try std.testing.expectEqualStrings("200 OK", scratch_source.status);
    try std.testing.expect(std.mem.indexOf(u8, scratch_source.body, "Checkpoint Scratch Source") != null);
    const archive_source = handleRequest(&target_ctx, "POST", "/v1/search", "{\"query\":\"Checkpoint scratch primitive body\",\"store\":\"archive\",\"use_vector\":false,\"limit\":10}", "POST /v1/search HTTP/1.1\r\nAuthorization: Bearer agent-route\r\n\r\n");
    try std.testing.expectEqualStrings("200 OK", archive_source.status);
    try std.testing.expect(std.mem.indexOf(u8, archive_source.body, "Checkpoint Scratch Source") == null);

    const archive_atom = handleRequest(&target_ctx, "POST", "/v1/search", "{\"query\":\"Checkpoint archive atom body\",\"store\":\"archive\",\"use_vector\":false,\"limit\":10}", "POST /v1/search HTTP/1.1\r\nAuthorization: Bearer agent-route\r\n\r\n");
    try std.testing.expectEqualStrings("200 OK", archive_atom.status);
    try std.testing.expect(std.mem.indexOf(u8, archive_atom.body, "Checkpoint archive atom body") != null);
    const scratch_atom = handleRequest(&target_ctx, "POST", "/v1/search", "{\"query\":\"Checkpoint archive atom body\",\"store\":\"scratch\",\"use_vector\":false,\"limit\":10}", "POST /v1/search HTTP/1.1\r\nAuthorization: Bearer agent-route\r\n\r\n");
    try std.testing.expectEqualStrings("200 OK", scratch_atom.status);
    try std.testing.expect(std.mem.indexOf(u8, scratch_atom.body, "Checkpoint archive atom body") == null);
}

test "api runtime primitive mirrors honor canonical memory atom lifecycle" {
    var store = try Store.initSQLiteWithOptions(std.testing.allocator, ":memory:", .{
        .agent_memory = .{ .backend = .memory_lru },
        .agent_memory_stores = &.{.{ .name = "scratch", .config = .{ .backend = .memory_lru } }},
    });
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const principals =
        \\{"agent-route":{"actor_id":"agent:route","scopes":["public","write:public","delete:public"],"capabilities":["read","write","delete"]}}
    ;
    var ctx = Context{ .allocator = alloc, .store = &store, .token_principals_json = principals };
    const raw = "POST /v1/memory-atoms HTTP/1.1\r\nAuthorization: Bearer agent-route\r\n\r\n";

    const evidence = handleRequest(&ctx, "POST", "/v1/sources", "{\"title\":\"Lifecycle Evidence\",\"content\":\"evidence only\",\"scope\":\"public\",\"storage\":\"native\"}", "POST /v1/sources HTTP/1.1\r\nAuthorization: Bearer agent-route\r\n\r\n");
    try std.testing.expectEqualStrings("200 OK", evidence.status);
    const source_id = try extractJsonString(alloc, evidence.body, "\"id\":\"");
    const atom_body = try std.fmt.allocPrint(alloc, "{{\"text\":\"Lifecycle mirror unique atom\",\"scope\":\"public\",\"created_by\":\"agent\",\"source_ids\":[\"{s}\"],\"store\":\"scratch\"}}", .{source_id});
    const atom = handleRequest(&ctx, "POST", "/v1/memory-atoms", atom_body, raw);
    try std.testing.expectEqualStrings("200 OK", atom.status);
    const atom_id = try extractJsonString(alloc, atom.body, "\"id\":\"");

    const before = handleRequest(&ctx, "POST", "/v1/search", "{\"query\":\"Lifecycle mirror unique atom\",\"store\":\"scratch\",\"use_vector\":false,\"limit\":10}", "POST /v1/search HTTP/1.1\r\nAuthorization: Bearer agent-route\r\n\r\n");
    try std.testing.expectEqualStrings("200 OK", before.status);
    try std.testing.expect(std.mem.indexOf(u8, before.body, "Lifecycle mirror unique atom") != null);

    const patch_body = try std.fmt.allocPrint(alloc, "{{\"status\":\"deprecated\"}}", .{});
    const patch_path = try std.fmt.allocPrint(alloc, "/v1/memory-atoms/{s}", .{atom_id});
    const patch = handleRequest(&ctx, "PATCH", patch_path, patch_body, "PATCH /v1/memory-atoms HTTP/1.1\r\nAuthorization: Bearer agent-route\r\n\r\n");
    try std.testing.expectEqualStrings("200 OK", patch.status);

    const after = handleRequest(&ctx, "POST", "/v1/search", "{\"query\":\"Lifecycle mirror unique atom\",\"store\":\"scratch\",\"use_vector\":false,\"limit\":10}", "POST /v1/search HTTP/1.1\r\nAuthorization: Bearer agent-route\r\n\r\n");
    try std.testing.expectEqualStrings("200 OK", after.status);
    try std.testing.expect(std.mem.indexOf(u8, after.body, "Lifecycle mirror unique atom") == null);
    const with_deprecated = handleRequest(&ctx, "POST", "/v1/search", "{\"query\":\"Lifecycle mirror unique atom\",\"store\":\"scratch\",\"use_vector\":false,\"include_deprecated\":true,\"limit\":10}", "POST /v1/search HTTP/1.1\r\nAuthorization: Bearer agent-route\r\n\r\n");
    try std.testing.expectEqualStrings("200 OK", with_deprecated.status);
    try std.testing.expect(std.mem.indexOf(u8, with_deprecated.body, "Lifecycle mirror unique atom") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_deprecated.body, "\"status\":\"deprecated\"") != null);
}

test "api native agent memory project writes stay proposed without verify rights" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const principals =
        \\{"agent-project":{"actor_id":"agent:project","scopes":["project:nullpantry","write:project:nullpantry"],"capabilities":["read","write","propose"]}}
    ;
    var ctx = Context{ .allocator = alloc, .store = &store, .token_principals_json = principals };
    const raw = "PUT /v1/agent-memory/project.pref HTTP/1.1\r\nAuthorization: Bearer agent-project\r\n\r\n{}";

    const put = handleRequest(&ctx, "PUT", "/v1/agent-memory/project.pref", "{\"content\":\"Agent-created project API memory is proposed\",\"scope\":\"project:nullpantry\"}", raw);
    try std.testing.expectEqualStrings("200 OK", put.status);

    const search_resp = handleRequest(
        &ctx,
        "POST",
        "/v1/search",
        "{\"query\":\"project API memory\",\"scopes\":[\"project:nullpantry\"],\"limit\":10,\"use_vector\":false}",
        "POST /v1/search HTTP/1.1\r\nAuthorization: Bearer agent-project\r\n\r\n{}",
    );
    try std.testing.expectEqualStrings("200 OK", search_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, search_resp.body, "Agent-created project API memory is proposed") != null);
    try std.testing.expect(std.mem.indexOf(u8, search_resp.body, "\"status\":\"proposed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, search_resp.body, "\"status\":\"verified\"") == null);
}

test "api native agent memory applies ACL after actor isolation" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const principals =
        \\{"agent-acl":{"actor_id":"agent:acl","scopes":["public","team:private","project:secret","write:project:secret","session:*","write:session:*"],"capabilities":["read","write","propose","delete"]}}
    ;
    var ctx = Context{ .allocator = alloc, .store = &store, .token_principals_json = principals };
    const raw = "PUT /v1/agent-memory/secret.pref HTTP/1.1\r\nAuthorization: Bearer agent-acl\r\n\r\n{}";
    const narrowed = "GET /v1/agent-memory/secret.pref HTTP/1.1\r\nAuthorization: Bearer agent-acl\r\nX-NullPantry-Actor-Scopes: [\"public\"]\r\n\r\n";

    const global_put = handleRequest(&ctx, "PUT", "/v1/agent-memory/personal.pref", "{\"content\":\"Personal API memory\"}", raw);
    try std.testing.expectEqualStrings("200 OK", global_put.status);
    const restricted_personal_put = handleRequest(&ctx, "PUT", "/v1/agent-memory/personal.restricted", "{\"content\":\"Restricted personal API memory\",\"permissions\":[\"team:private\"]}", raw);
    try std.testing.expectEqualStrings("200 OK", restricted_personal_put.status);
    const secret_put = handleRequest(&ctx, "PUT", "/v1/agent-memory/secret.pref", "{\"content\":\"Secret API memory\",\"scope\":\"project:secret\"}", raw);
    try std.testing.expectEqualStrings("200 OK", secret_put.status);
    const session_secret_put = handleRequest(&ctx, "PUT", "/v1/agent-memory/session.secret.pref", "{\"content\":\"Session secret API memory\",\"scope\":\"project:secret\",\"session_id\":\"sess_secret\"}", raw);
    try std.testing.expectEqualStrings("200 OK", session_secret_put.status);

    const allowed_get = handleRequest(&ctx, "GET", "/v1/agent-memory/secret.pref", "", "GET /v1/agent-memory/secret.pref HTTP/1.1\r\nAuthorization: Bearer agent-acl\r\n\r\n");
    try std.testing.expectEqualStrings("200 OK", allowed_get.status);
    try std.testing.expect(std.mem.indexOf(u8, allowed_get.body, "Secret API memory") != null);
    const allowed_restricted_personal_get = handleRequest(&ctx, "GET", "/v1/agent-memory/personal.restricted", "", "GET /v1/agent-memory/personal.restricted HTTP/1.1\r\nAuthorization: Bearer agent-acl\r\n\r\n");
    try std.testing.expectEqualStrings("200 OK", allowed_restricted_personal_get.status);
    try std.testing.expect(std.mem.indexOf(u8, allowed_restricted_personal_get.body, "Restricted personal API memory") != null);
    const allowed_session_get = handleRequest(&ctx, "GET", "/v1/agent-memory/session.secret.pref?session_id=sess_secret", "", "GET /v1/agent-memory/session.secret.pref HTTP/1.1\r\nAuthorization: Bearer agent-acl\r\n\r\n");
    try std.testing.expectEqualStrings("200 OK", allowed_session_get.status);
    try std.testing.expect(std.mem.indexOf(u8, allowed_session_get.body, "Session secret API memory") != null);

    const denied_get = handleRequest(&ctx, "GET", "/v1/agent-memory/secret.pref", "", narrowed);
    try std.testing.expectEqualStrings("404 Not Found", denied_get.status);
    const session_only_no_project = "GET /v1/agent-memory/session.secret.pref?session_id=sess_secret HTTP/1.1\r\nAuthorization: Bearer agent-acl\r\nX-NullPantry-Actor-Scopes: [\"public\",\"session:*\"]\r\n\r\n";
    const denied_session_get = handleRequest(&ctx, "GET", "/v1/agent-memory/session.secret.pref?session_id=sess_secret", "", session_only_no_project);
    try std.testing.expectEqualStrings("404 Not Found", denied_session_get.status);

    const denied_search = handleRequest(&ctx, "POST", "/v1/agent-memory/search", "{\"query\":\"Secret API memory\",\"limit\":10}", "POST /v1/agent-memory/search HTTP/1.1\r\nAuthorization: Bearer agent-acl\r\nX-NullPantry-Actor-Scopes: [\"public\"]\r\n\r\n");
    try std.testing.expectEqualStrings("200 OK", denied_search.status);
    try std.testing.expect(std.mem.indexOf(u8, denied_search.body, "Secret API memory") == null);
    const denied_restricted_personal_search = handleRequest(&ctx, "POST", "/v1/agent-memory/search", "{\"query\":\"Restricted personal API memory\",\"limit\":10}", "POST /v1/agent-memory/search HTTP/1.1\r\nAuthorization: Bearer agent-acl\r\nX-NullPantry-Actor-Scopes: [\"public\"]\r\n\r\n");
    try std.testing.expectEqualStrings("200 OK", denied_restricted_personal_search.status);
    try std.testing.expect(std.mem.indexOf(u8, denied_restricted_personal_search.body, "Restricted personal API memory") == null);
    const denied_session_search = handleRequest(&ctx, "POST", "/v1/agent-memory/search", "{\"query\":\"Session secret API memory\",\"session_id\":\"sess_secret\",\"limit\":10}", "POST /v1/agent-memory/search HTTP/1.1\r\nAuthorization: Bearer agent-acl\r\nX-NullPantry-Actor-Scopes: [\"public\",\"session:*\"]\r\n\r\n");
    try std.testing.expectEqualStrings("200 OK", denied_session_search.status);
    try std.testing.expect(std.mem.indexOf(u8, denied_session_search.body, "Session secret API memory") == null);

    const narrowed_list = handleRequest(&ctx, "GET", "/v1/agent-memory?limit=10", "", "GET /v1/agent-memory HTTP/1.1\r\nAuthorization: Bearer agent-acl\r\nX-NullPantry-Actor-Scopes: [\"public\"]\r\n\r\n");
    try std.testing.expectEqualStrings("200 OK", narrowed_list.status);
    try std.testing.expect(std.mem.indexOf(u8, narrowed_list.body, "Personal API memory") != null);
    try std.testing.expect(std.mem.indexOf(u8, narrowed_list.body, "Secret API memory") == null);

    const narrowed_count = handleRequest(&ctx, "GET", "/v1/agent-memory/count", "", "GET /v1/agent-memory/count HTTP/1.1\r\nAuthorization: Bearer agent-acl\r\nX-NullPantry-Actor-Scopes: [\"public\"]\r\n\r\n");
    try std.testing.expectEqualStrings("200 OK", narrowed_count.status);
    try std.testing.expect(std.mem.indexOf(u8, narrowed_count.body, "\"count\":1") != null);

    const denied_project_delete = handleRequest(&ctx, "DELETE", "/v1/agent-memory/secret.pref?scope=project:secret", "", "DELETE /v1/agent-memory/secret.pref?scope=project:secret HTTP/1.1\r\nAuthorization: Bearer agent-acl\r\n\r\n");
    try std.testing.expectEqualStrings("403 Forbidden", denied_project_delete.status);
    const denied_session_project_delete = handleRequest(&ctx, "DELETE", "/v1/agent-memory/session.secret.pref?session_id=sess_secret&scope=project:secret", "", "DELETE /v1/agent-memory/session.secret.pref?session_id=sess_secret&scope=project:secret HTTP/1.1\r\nAuthorization: Bearer agent-acl\r\n\r\n");
    try std.testing.expectEqualStrings("403 Forbidden", denied_session_project_delete.status);

    const allowed_personal_delete = handleRequest(&ctx, "DELETE", "/v1/agent-memory/personal.pref", "", "DELETE /v1/agent-memory/personal.pref HTTP/1.1\r\nAuthorization: Bearer agent-acl\r\n\r\n");
    try std.testing.expectEqualStrings("200 OK", allowed_personal_delete.status);
    const deleted_personal_get = handleRequest(&ctx, "GET", "/v1/agent-memory/personal.pref", "", "GET /v1/agent-memory/personal.pref HTTP/1.1\r\nAuthorization: Bearer agent-acl\r\n\r\n");
    try std.testing.expectEqualStrings("404 Not Found", deleted_personal_get.status);
    const allowed_restricted_personal_delete = handleRequest(&ctx, "DELETE", "/v1/agent-memory/personal.restricted", "", "DELETE /v1/agent-memory/personal.restricted HTTP/1.1\r\nAuthorization: Bearer agent-acl\r\n\r\n");
    try std.testing.expectEqualStrings("200 OK", allowed_restricted_personal_delete.status);
}

test "api native agent memory supports private and shared team ownership" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const principals =
        \\{"agent-a":{"actor_id":"agent:a","scopes":["public","team:alpha","write:team:alpha","delete:team:alpha"],"capabilities":["read","write","propose","delete"]},"agent-b":{"actor_id":"agent:b","scopes":["public","team:alpha","write:team:alpha","delete:team:alpha"],"capabilities":["read","write","propose","delete"]},"agent-c":{"actor_id":"agent:c","scopes":["public"],"capabilities":["read","write","propose","delete"]}}
    ;
    var ctx = Context{ .allocator = alloc, .store = &store, .token_principals_json = principals };
    const raw_a = "PUT /v1/agent-memory/team.pref HTTP/1.1\r\nAuthorization: Bearer agent-a\r\n\r\n";
    const raw_b = "PUT /v1/agent-memory/team.pref HTTP/1.1\r\nAuthorization: Bearer agent-b\r\n\r\n";
    const raw_c = "GET /v1/agent-memory/team.pref HTTP/1.1\r\nAuthorization: Bearer agent-c\r\n\r\n";

    const private_a = handleRequest(&ctx, "PUT", "/v1/agent-memory/private.pref", "{\"content\":\"agent a private value\"}", raw_a);
    try std.testing.expectEqualStrings("200 OK", private_a.status);
    const private_b_get = handleRequest(&ctx, "GET", "/v1/agent-memory/private.pref", "", "GET /v1/agent-memory/private.pref HTTP/1.1\r\nAuthorization: Bearer agent-b\r\n\r\n");
    try std.testing.expectEqualStrings("404 Not Found", private_b_get.status);

    const team_a = handleRequest(&ctx, "PUT", "/v1/agent-memory/team.pref", "{\"content\":\"team alpha value v1\",\"scope\":\"team:alpha\"}", raw_a);
    try std.testing.expectEqualStrings("200 OK", team_a.status);
    try std.testing.expect(std.mem.indexOf(u8, team_a.body, "\"actor_id\":\"shared:team:alpha\"") != null);

    const team_b_get = handleRequest(&ctx, "GET", "/v1/agent-memory/team.pref?scope=team:alpha", "", "GET /v1/agent-memory/team.pref?scope=team:alpha HTTP/1.1\r\nAuthorization: Bearer agent-b\r\n\r\n");
    try std.testing.expectEqualStrings("200 OK", team_b_get.status);
    try std.testing.expect(std.mem.indexOf(u8, team_b_get.body, "team alpha value v1") != null);

    const team_b_update = handleRequest(&ctx, "PUT", "/v1/agent-memory/team.pref", "{\"content\":\"team alpha value v2\",\"scope\":\"team:alpha\"}", raw_b);
    try std.testing.expectEqualStrings("200 OK", team_b_update.status);
    const team_a_get = handleRequest(&ctx, "GET", "/v1/agent-memory/team.pref?scope=team:alpha", "", "GET /v1/agent-memory/team.pref?scope=team:alpha HTTP/1.1\r\nAuthorization: Bearer agent-a\r\n\r\n");
    try std.testing.expectEqualStrings("200 OK", team_a_get.status);
    try std.testing.expect(std.mem.indexOf(u8, team_a_get.body, "team alpha value v2") != null);
    try std.testing.expect(std.mem.indexOf(u8, team_a_get.body, "team alpha value v1") == null);

    const team_c_get = handleRequest(&ctx, "GET", "/v1/agent-memory/team.pref?scope=team:alpha", "", raw_c);
    try std.testing.expectEqualStrings("404 Not Found", team_c_get.status);
    const team_b_delete = handleRequest(&ctx, "DELETE", "/v1/agent-memory/team.pref?scope=team:alpha", "", "DELETE /v1/agent-memory/team.pref?scope=team:alpha HTTP/1.1\r\nAuthorization: Bearer agent-b\r\n\r\n");
    try std.testing.expectEqualStrings("200 OK", team_b_delete.status);
    const deleted_team = handleRequest(&ctx, "GET", "/v1/agent-memory/team.pref?scope=team:alpha", "", "GET /v1/agent-memory/team.pref?scope=team:alpha HTTP/1.1\r\nAuthorization: Bearer agent-a\r\n\r\n");
    try std.testing.expectEqualStrings("404 Not Found", deleted_team.status);

    const private_a_get = handleRequest(&ctx, "GET", "/v1/agent-memory/private.pref", "", "GET /v1/agent-memory/private.pref HTTP/1.1\r\nAuthorization: Bearer agent-a\r\n\r\n");
    try std.testing.expectEqualStrings("200 OK", private_a_get.status);
    try std.testing.expect(std.mem.indexOf(u8, private_a_get.body, "agent a private value") != null);
}

test "api memory feed merges shared team agent memory deterministically" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const principals =
        \\{"agent-a":{"actor_id":"agent:a","scopes":["public","team:alpha","write:team:alpha"],"capabilities":["read","write","feed_apply"]},"agent-b":{"actor_id":"agent:b","scopes":["public","team:alpha","write:team:alpha"],"capabilities":["read","write","feed_apply"]}}
    ;
    var ctx = Context{ .allocator = alloc, .store = &store, .token_principals_json = principals };

    const merge_a = handleRequest(&ctx, "POST", "/v1/memory/apply", "{\"event_type\":\"agent_memory.merge_string_set\",\"operation\":\"merge_string_set\",\"object_type\":\"agent_memory\",\"payload\":{\"key\":\"team.tools\",\"values\":[\"zig\"],\"scope\":\"team:alpha\"}}", "POST /v1/memory/apply HTTP/1.1\r\nAuthorization: Bearer agent-a\r\n\r\n");
    try std.testing.expectEqualStrings("200 OK", merge_a.status);
    const merge_b = handleRequest(&ctx, "POST", "/v1/memory/apply", "{\"event_type\":\"agent_memory.merge_string_set\",\"operation\":\"merge_string_set\",\"object_type\":\"agent_memory\",\"payload\":{\"key\":\"team.tools\",\"values\":[\"postgres\",\"zig\"],\"scope\":\"team:alpha\"}}", "POST /v1/memory/apply HTTP/1.1\r\nAuthorization: Bearer agent-b\r\n\r\n");
    try std.testing.expectEqualStrings("200 OK", merge_b.status);

    const shared_a = handleRequest(&ctx, "GET", "/v1/agent-memory/team.tools?scope=team:alpha", "", "GET /v1/agent-memory/team.tools?scope=team:alpha HTTP/1.1\r\nAuthorization: Bearer agent-a\r\n\r\n");
    try std.testing.expectEqualStrings("200 OK", shared_a.status);
    try std.testing.expect(std.mem.indexOf(u8, shared_a.body, "[\\\"postgres\\\",\\\"zig\\\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, shared_a.body, "\"actor_id\":\"shared:team:alpha\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, shared_a.body, "\"owner_id\":\"shared:team:alpha\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, shared_a.body, "\"created_by_actor_id\":\"agent:b\"") != null);

    const private_b = handleRequest(&ctx, "PUT", "/v1/agent-memory/team.tools", "{\"content\":\"agent b private tools\"}", "PUT /v1/agent-memory/team.tools HTTP/1.1\r\nAuthorization: Bearer agent-b\r\n\r\n");
    try std.testing.expectEqualStrings("200 OK", private_b.status);
    const default_b = handleRequest(&ctx, "GET", "/v1/agent-memory/team.tools", "", "GET /v1/agent-memory/team.tools HTTP/1.1\r\nAuthorization: Bearer agent-b\r\n\r\n");
    try std.testing.expectEqualStrings("200 OK", default_b.status);
    try std.testing.expect(std.mem.indexOf(u8, default_b.body, "agent b private tools") != null);
    try std.testing.expect(std.mem.indexOf(u8, default_b.body, "\"created_by_actor_id\":\"agent:b\"") != null);
    const list_b = handleRequest(&ctx, "GET", "/v1/agent-memory", "", "GET /v1/agent-memory HTTP/1.1\r\nAuthorization: Bearer agent-b\r\n\r\n");
    try std.testing.expectEqualStrings("200 OK", list_b.status);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, list_b.body, "\"key\":\"team.tools\""));
    try std.testing.expect(std.mem.indexOf(u8, list_b.body, "agent b private tools") != null);
    try std.testing.expect(std.mem.indexOf(u8, list_b.body, "[\\\"postgres\\\",\\\"zig\\\"]") != null);
    const scoped_b = handleRequest(&ctx, "GET", "/v1/agent-memory/team.tools?scope=team:alpha", "", "GET /v1/agent-memory/team.tools?scope=team:alpha HTTP/1.1\r\nAuthorization: Bearer agent-b\r\n\r\n");
    try std.testing.expectEqualStrings("200 OK", scoped_b.status);
    try std.testing.expect(std.mem.indexOf(u8, scoped_b.body, "[\\\"postgres\\\",\\\"zig\\\"]") != null);
}

test "api native agent memory supports session plus global recall and filters internals" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const principals =
        \\{"agent-a":{"actor_id":"agent:a","scopes":["session:*","write:session:*"],"capabilities":["read","write","propose","delete"]}}
    ;
    var ctx = Context{ .allocator = alloc, .store = &store, .token_principals_json = principals };
    const raw = "PUT /v1/agent-memory/global.pref HTTP/1.1\r\nAuthorization: Bearer agent-a\r\n\r\n{}";

    const global_put = handleRequest(&ctx, "PUT", "/v1/agent-memory/global.pref", "{\"content\":\"Global recall value\"}", raw);
    try std.testing.expectEqualStrings("200 OK", global_put.status);
    const session_put = handleRequest(&ctx, "PUT", "/v1/agent-memory/session.pref", "{\"content\":\"Session recall value\",\"session_id\":\"sess_api\"}", raw);
    try std.testing.expectEqualStrings("200 OK", session_put.status);
    const internal_put = handleRequest(&ctx, "PUT", "/v1/agent-memory/autosave_user_1", "{\"content\":\"internal autosave value\"}", raw);
    try std.testing.expectEqualStrings("200 OK", internal_put.status);

    const session_only = handleRequest(&ctx, "POST", "/v1/agent-memory/search", "{\"query\":\"recall value\",\"session_id\":\"sess_api\",\"limit\":10}", "POST /v1/agent-memory/search HTTP/1.1\r\nAuthorization: Bearer agent-a\r\n\r\n{}");
    try std.testing.expectEqualStrings("200 OK", session_only.status);
    try std.testing.expect(std.mem.indexOf(u8, session_only.body, "Session recall value") != null);
    try std.testing.expect(std.mem.indexOf(u8, session_only.body, "Global recall value") == null);

    const session_plus_global = handleRequest(&ctx, "POST", "/v1/agent-memory/search", "{\"query\":\"recall value\",\"session_id\":\"sess_api\",\"include_global\":true,\"limit\":10}", "POST /v1/agent-memory/search HTTP/1.1\r\nAuthorization: Bearer agent-a\r\n\r\n{}");
    try std.testing.expectEqualStrings("200 OK", session_plus_global.status);
    try std.testing.expect(std.mem.indexOf(u8, session_plus_global.body, "Session recall value") != null);
    try std.testing.expect(std.mem.indexOf(u8, session_plus_global.body, "Global recall value") != null);

    const list_default = handleRequest(&ctx, "GET", "/v1/agent-memory?limit=10", "", "GET /v1/agent-memory HTTP/1.1\r\nAuthorization: Bearer agent-a\r\n\r\n{}");
    try std.testing.expectEqualStrings("200 OK", list_default.status);
    try std.testing.expect(std.mem.indexOf(u8, list_default.body, "autosave_user_1") == null);
    const list_internal = handleRequest(&ctx, "GET", "/v1/agent-memory?limit=10&include_internal=true", "", "GET /v1/agent-memory HTTP/1.1\r\nAuthorization: Bearer agent-a\r\n\r\n{}");
    try std.testing.expectEqualStrings("200 OK", list_internal.status);
    try std.testing.expect(std.mem.indexOf(u8, list_internal.body, "autosave_user_1") != null);
}

test "api native agent sessions are actor isolated and scope gated" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const principals =
        \\{"agent-a":{"actor_id":"agent:a","scopes":["session:*","write:session:*"],"capabilities":["read","write","delete"]},"agent-b":{"actor_id":"agent:b","scopes":["session:*","write:session:*"],"capabilities":["read","write","delete"]},"reader":{"actor_id":"agent:reader","scopes":["session:*"],"capabilities":["read"]}}
    ;
    var ctx = Context{ .allocator = alloc, .store = &store, .token_principals_json = principals };
    const raw_a = "POST /v1/agent-sessions/shared/messages HTTP/1.1\r\nAuthorization: Bearer agent-a\r\n\r\n{}";
    const raw_b = "POST /v1/agent-sessions/shared/messages HTTP/1.1\r\nAuthorization: Bearer agent-b\r\n\r\n{}";
    const raw_reader = "POST /v1/agent-sessions/shared/messages HTTP/1.1\r\nAuthorization: Bearer reader\r\n\r\n{}";

    const save_a = handleRequest(&ctx, "POST", "/v1/agent-sessions/shared/messages", "{\"role\":\"user\",\"content\":\"Agent A session note\"}", raw_a);
    try std.testing.expectEqualStrings("200 OK", save_a.status);
    const save_b = handleRequest(&ctx, "POST", "/v1/agent-sessions/shared/messages", "{\"role\":\"user\",\"content\":\"Agent B session note\"}", raw_b);
    try std.testing.expectEqualStrings("200 OK", save_b.status);
    const save_all = handleRequest(&ctx, "POST", "/v1/agent-sessions/shared/messages", "{\"role\":\"assistant\",\"content\":\"Agent A routed all session note\",\"storage\":\"all\"}", raw_a);
    try std.testing.expectEqualStrings("200 OK", save_all.status);
    const denied_write = handleRequest(&ctx, "POST", "/v1/agent-sessions/shared/messages", "{\"role\":\"user\",\"content\":\"reader write\"}", raw_reader);
    try std.testing.expectEqualStrings("403 Forbidden", denied_write.status);

    const usage_a = handleRequest(&ctx, "PUT", "/v1/agent-sessions/shared/usage", "{\"total_tokens\":17}", "PUT /v1/agent-sessions/shared/usage HTTP/1.1\r\nAuthorization: Bearer agent-a\r\n\r\n{}");
    try std.testing.expectEqualStrings("200 OK", usage_a.status);
    const usage_b = handleRequest(&ctx, "PUT", "/v1/agent-sessions/shared/usage", "{\"total_tokens\":29}", "PUT /v1/agent-sessions/shared/usage HTTP/1.1\r\nAuthorization: Bearer agent-b\r\n\r\n{}");
    try std.testing.expectEqualStrings("200 OK", usage_b.status);

    const get_a = handleRequest(&ctx, "GET", "/v1/agent-sessions/shared/messages", "", "GET /v1/agent-sessions/shared/messages HTTP/1.1\r\nAuthorization: Bearer agent-a\r\n\r\n");
    try std.testing.expectEqualStrings("200 OK", get_a.status);
    try std.testing.expect(std.mem.indexOf(u8, get_a.body, "Agent A session note") != null);
    try std.testing.expect(std.mem.indexOf(u8, get_a.body, "Agent A routed all session note") != null);
    try std.testing.expect(std.mem.indexOf(u8, get_a.body, "Agent B session note") == null);
    const get_a_all = handleRequest(&ctx, "GET", "/v1/agent-sessions/shared/messages?storage=all", "", "GET /v1/agent-sessions/shared/messages?storage=all HTTP/1.1\r\nAuthorization: Bearer agent-a\r\n\r\n");
    try std.testing.expectEqualStrings("200 OK", get_a_all.status);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, get_a_all.body, "Agent A routed all session note"));
    const get_a_runtime = handleRequest(&ctx, "GET", "/v1/agent-sessions/shared/messages?storage=redis", "", "GET /v1/agent-sessions/shared/messages?storage=redis HTTP/1.1\r\nAuthorization: Bearer agent-a\r\n\r\n");
    try std.testing.expectEqualStrings("400 Bad Request", get_a_runtime.status);
    try std.testing.expect(std.mem.indexOf(u8, get_a_runtime.body, "storage_unavailable") != null);

    const get_b = handleRequest(&ctx, "GET", "/v1/agent-sessions/shared/messages", "", "GET /v1/agent-sessions/shared/messages HTTP/1.1\r\nAuthorization: Bearer agent-b\r\n\r\n");
    try std.testing.expectEqualStrings("200 OK", get_b.status);
    try std.testing.expect(std.mem.indexOf(u8, get_b.body, "Agent B session note") != null);
    try std.testing.expect(std.mem.indexOf(u8, get_b.body, "Agent A session note") == null);

    const usage_get_a = handleRequest(&ctx, "GET", "/v1/agent-sessions/shared/usage", "", "GET /v1/agent-sessions/shared/usage HTTP/1.1\r\nAuthorization: Bearer agent-a\r\n\r\n");
    try std.testing.expectEqualStrings("200 OK", usage_get_a.status);
    try std.testing.expect(std.mem.indexOf(u8, usage_get_a.body, "\"total_tokens\":17") != null);
    const usage_get_b = handleRequest(&ctx, "GET", "/v1/agent-sessions/shared/usage", "", "GET /v1/agent-sessions/shared/usage HTTP/1.1\r\nAuthorization: Bearer agent-b\r\n\r\n");
    try std.testing.expectEqualStrings("200 OK", usage_get_b.status);
    try std.testing.expect(std.mem.indexOf(u8, usage_get_b.body, "\"total_tokens\":29") != null);

    const list_a = handleRequest(&ctx, "GET", "/v1/agent-sessions?limit=10", "", "GET /v1/agent-sessions HTTP/1.1\r\nAuthorization: Bearer agent-a\r\n\r\n");
    try std.testing.expectEqualStrings("200 OK", list_a.status);
    try std.testing.expect(std.mem.indexOf(u8, list_a.body, "\"total\":1") != null);
    const list_a_all = handleRequest(&ctx, "GET", "/v1/agent-sessions?limit=10&storage=all", "", "GET /v1/agent-sessions?limit=10&storage=all HTTP/1.1\r\nAuthorization: Bearer agent-a\r\n\r\n");
    try std.testing.expectEqualStrings("200 OK", list_a_all.status);
    try std.testing.expect(std.mem.indexOf(u8, list_a_all.body, "\"total\":1") != null);

    const session_search_a = handleRequest(&ctx, "POST", "/v1/search", "{\"query\":\"Agent B session\",\"scopes\":[\"session:shared\"],\"include_sessions\":true}", "POST /v1/search HTTP/1.1\r\nAuthorization: Bearer agent-a\r\n\r\n{}");
    try std.testing.expectEqualStrings("200 OK", session_search_a.status);
    try std.testing.expect(std.mem.indexOf(u8, session_search_a.body, "Agent B session note") == null);
    const session_search_b = handleRequest(&ctx, "POST", "/v1/search", "{\"query\":\"Agent B session\",\"scopes\":[\"session:shared\"],\"include_sessions\":true}", "POST /v1/search HTTP/1.1\r\nAuthorization: Bearer agent-b\r\n\r\n{}");
    try std.testing.expectEqualStrings("200 OK", session_search_b.status);
    try std.testing.expect(std.mem.indexOf(u8, session_search_b.body, "Agent B session note") != null);
    try std.testing.expect(std.mem.indexOf(u8, session_search_b.body, "\"scope\":\"session:shared\"") != null);
}

test "api single bearer token ignores actor header unless explicitly trusted" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const raw = "PUT /v1/agent-memory/header.actor HTTP/1.1\r\nAuthorization: Bearer gateway-token\r\nX-NullPantry-Actor-Id: agent:spoofed\r\n\r\n{}";
    var default_ctx = Context{ .allocator = alloc, .store = &store, .required_token = "gateway-token" };
    const ignored = handleRequest(&default_ctx, "PUT", "/v1/agent-memory/header.actor", "{\"content\":\"default token actor\"}", raw);
    try std.testing.expectEqualStrings("200 OK", ignored.status);
    try std.testing.expect((try store.agentMemoryGet(alloc, "header.actor", null, "agent:spoofed")) == null);
    const local = (try store.agentMemoryGet(alloc, "header.actor", null, "local")).?;
    try std.testing.expectEqualStrings("default token actor", local.content);

    var trusted_ctx = Context{ .allocator = alloc, .store = &store, .required_token = "gateway-token", .trust_actor_headers = true };
    const trusted = handleRequest(&trusted_ctx, "PUT", "/v1/agent-memory/header.actor.trusted", "{\"content\":\"trusted gateway actor\"}", raw);
    try std.testing.expectEqualStrings("200 OK", trusted.status);
    const spoofed = (try store.agentMemoryGet(alloc, "header.actor.trusted", null, "agent:spoofed")).?;
    try std.testing.expectEqualStrings("trusted gateway actor", spoofed.content);
}

test "api rejects writes outside actor scope or permissions" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = Context{ .allocator = alloc, .store = &store, .actor_scopes_json = "[\"public\"]" };

    const source_resp = handleRequest(&ctx, "POST", "/v1/sources", "{\"title\":\"Private source\",\"scope\":\"public\",\"permissions\":[\"project:secret\"],\"content\":\"hidden\"}", "");
    try std.testing.expectEqualStrings("403 Forbidden", source_resp.status);

    const artifact_resp = handleRequest(&ctx, "POST", "/v1/artifacts", "{\"title\":\"Private artifact\",\"permissions\":[\"project:secret\"],\"body\":\"hidden\"}", "");
    try std.testing.expectEqualStrings("403 Forbidden", artifact_resp.status);
}

test "api direct artifact reads enforce permissions" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const artifact = try store.createArtifact(alloc, .{
        .title = "Secret spec",
        .body = "Hidden artifact body",
        .permissions_json = "[\"project:secret\"]",
    });
    const path = try std.fmt.allocPrint(alloc, "/v1/artifacts/{s}", .{artifact.id});
    var ctx = Context{ .allocator = alloc, .store = &store, .actor_scopes_json = "[\"public\"]" };
    const resp = handleRequest(&ctx, "GET", path, "", "");
    try std.testing.expectEqualStrings("404 Not Found", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "Hidden artifact body") == null);
}

test "api artifact citations are permission sanitized" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const public_source = try store.createSource(alloc, .{ .title = "Public source", .content = "visible", .scope = "public" });
    const secret_source = try store.createSource(alloc, .{ .title = "Secret source", .content = "hidden", .scope = "project:secret", .permissions_json = "[\"project:secret\"]" });
    const source_ids = try std.fmt.allocPrint(alloc, "[\"{s}\",\"{s}\"]", .{ public_source.id, secret_source.id });
    const artifact = try store.createArtifact(alloc, .{ .title = "Mixed artifact", .body = "body", .scope = "public", .source_ids_json = source_ids });
    const path = try std.fmt.allocPrint(alloc, "/v1/artifacts/{s}", .{artifact.id});

    var public_ctx = Context{ .allocator = alloc, .store = &store, .actor_scopes_json = "[\"public\",\"write:public\"]" };
    const read_resp = handleRequest(&public_ctx, "GET", path, "", "");
    try std.testing.expectEqualStrings("200 OK", read_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, read_resp.body, public_source.id) != null);
    try std.testing.expect(std.mem.indexOf(u8, read_resp.body, secret_source.id) == null);

    const create_body = try std.fmt.allocPrint(alloc, "{{\"title\":\"Bad citations\",\"body\":\"x\",\"source_ids\":[\"{s}\"]}}", .{secret_source.id});
    const create_resp = handleRequest(&public_ctx, "POST", "/v1/artifacts", create_body, "");
    try std.testing.expectEqualStrings("403 Forbidden", create_resp.status);
}

test "api artifacts require and index structured fields" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = Context{ .allocator = alloc, .store = &store, .actor_scopes_json = "[\"public\",\"write:public\"]" };

    const missing = handleRequest(&ctx, "POST", "/v1/artifacts", "{\"type\":\"decision\",\"title\":\"Missing fields\",\"body\":\"x\",\"status\":\"proposed\",\"scope\":\"public\"}", "");
    try std.testing.expectEqualStrings("400 Bad Request", missing.status);
    try std.testing.expect(std.mem.indexOf(u8, missing.body, "Missing required artifact field") != null);

    const create_body =
        \\{"type":"decision","title":"Structured Decision","body":"Decision body","status":"proposed","scope":"public","fields":{"context":"structured context","decision":"choose structured artifacts","alternatives":"plain pages only","consequences":"agent-readable fields","owner":"NullPantry","review_date":"2026-06-30"}}
    ;
    const created = handleRequest(&ctx, "POST", "/v1/artifacts", create_body, "");
    try std.testing.expectEqualStrings("200 OK", created.status);
    try std.testing.expect(std.mem.indexOf(u8, created.body, "\"fields\":{\"context\":\"structured context\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, created.body, "\"decision\":\"choose structured artifacts\"") != null);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, created.body, .{});
    defer parsed.deinit();
    const artifact_obj = parsed.value.object.get("artifact").?.object;
    const artifact_id = json.stringField(artifact_obj, "id").?;
    const path = try std.fmt.allocPrint(alloc, "/v1/artifacts/{s}", .{artifact_id});
    const loaded = handleRequest(&ctx, "GET", path, "", "");
    try std.testing.expectEqualStrings("200 OK", loaded.status);
    try std.testing.expect(std.mem.indexOf(u8, loaded.body, "\"fields\":{\"context\":\"structured context\"") != null);

    const search_resp = handleRequest(&ctx, "POST", "/v1/search", "{\"query\":\"agent-readable fields\",\"scopes\":[\"public\"],\"use_vector\":false}", "");
    try std.testing.expectEqualStrings("200 OK", search_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, search_resp.body, "Structured Decision") != null);
    try std.testing.expect(std.mem.indexOf(u8, search_resp.body, "agent-readable fields") != null);
}

test "api memory atom response preserves request string lifetimes" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = Context{ .allocator = arena.allocator(), .store = &store };

    const resp = handleRequest(&ctx, "POST", "/v1/memory-atoms", "{\"text\":\"NullPantry stores trusted context.\",\"scope\":\"public\",\"predicate\":\"states\",\"object\":\"trusted context\",\"created_by\":\"human\",\"status\":\"verified\"}", "");
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"text\":\"NullPantry stores trusted context.\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"created_by\":\"human\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"source_ids\":[\"src_") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"evidence_ranges\":[{") != null);
}

test "api refuses memory provenance that is broader than its source acl" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const secret_source = try store.createSource(alloc, .{
        .title = "Secret source",
        .content = "secret evidence",
        .scope = "project:secret",
        .permissions_json = "[\"project:secret\"]",
    });
    var ctx = Context{ .allocator = alloc, .store = &store };

    const bad_body = try std.fmt.allocPrint(alloc, "{{\"text\":\"Secret evidence as public memory\",\"scope\":\"public\",\"status\":\"verified\",\"source_ids\":[\"{s}\"]}}", .{secret_source.id});
    const bad = handleRequest(&ctx, "POST", "/v1/memory-atoms", bad_body, "");
    try std.testing.expectEqualStrings("403 Forbidden", bad.status);

    const good_body = try std.fmt.allocPrint(alloc, "{{\"text\":\"Secret evidence remains secret\",\"scope\":\"project:secret\",\"permissions\":[\"project:secret\"],\"status\":\"verified\",\"source_ids\":[\"{s}\"]}}", .{secret_source.id});
    const good = handleRequest(&ctx, "POST", "/v1/memory-atoms", good_body, "");
    try std.testing.expectEqualStrings("200 OK", good.status);
}

test "api feed events are permission filtered in feed and search" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var admin_ctx = Context{ .allocator = alloc, .store = &store };
    const append = handleRequest(&admin_ctx, "POST", "/v1/memory/feed", "{\"event_type\":\"memory.note\",\"object_type\":\"memory_atom\",\"object_id\":\"mem_secret\",\"scope\":\"public\",\"permissions\":[\"team:secret\"],\"payload\":{\"text\":\"feed-secret-payload\"}}", "");
    try std.testing.expectEqualStrings("200 OK", append.status);

    var public_ctx = Context{ .allocator = alloc, .store = &store, .actor_scopes_json = "[\"public\"]" };
    const public_feed = handleRequest(&public_ctx, "GET", "/v1/memory/feed", "", "");
    try std.testing.expectEqualStrings("200 OK", public_feed.status);
    try std.testing.expect(std.mem.indexOf(u8, public_feed.body, "feed-secret-payload") == null);
    const public_search = handleRequest(&public_ctx, "POST", "/v1/search", "{\"query\":\"feed-secret-payload\",\"scopes\":[\"public\"]}", "");
    try std.testing.expectEqualStrings("200 OK", public_search.status);
    try std.testing.expect(std.mem.indexOf(u8, public_search.body, "feed-secret-payload") == null);

    var secret_ctx = Context{ .allocator = alloc, .store = &store, .actor_scopes_json = "[\"public\",\"team:secret\"]" };
    const secret_feed = handleRequest(&secret_ctx, "GET", "/v1/memory/feed", "", "");
    try std.testing.expectEqualStrings("200 OK", secret_feed.status);
    try std.testing.expect(std.mem.indexOf(u8, secret_feed.body, "feed-secret-payload") != null);
}

test "api exposes engine registry retrieval plan vector and lifecycle endpoints" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = Context{ .allocator = arena.allocator(), .store = &store };

    const engines_resp = handleRequest(&ctx, "GET", "/v1/engines", "", "");
    try std.testing.expectEqualStrings("200 OK", engines_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, engines_resp.body, "\"name\":\"none\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, engines_resp.body, "\"name\":\"memory_lru\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, engines_resp.body, "\"name\":\"qdrant\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, engines_resp.body, "\"name\":\"lancedb\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, engines_resp.body, "\"name\":\"lucid\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, engines_resp.body, "\"name\":\"kg\"") != null);
    const openapi_resp = handleRequest(&ctx, "GET", "/v1/openapi.json", "", "");
    try std.testing.expectEqualStrings("200 OK", openapi_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, openapi_resp.body, "\"operationId\":\"ask\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, openapi_resp.body, "\"operationId\":\"createArtifact\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, openapi_resp.body, "\"operationId\":\"runVectorOutbox\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, openapi_resp.body, "\"operationId\":\"vectorStatus\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, openapi_resp.body, "\"operationId\":\"deleteVectorChunk\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, openapi_resp.body, "\"operationId\":\"rebuildVectorIndex\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, openapi_resp.body, "\"operationId\":\"reconcileVectorIndex\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, openapi_resp.body, "\"operationId\":\"putAgentMemoryByKey\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, openapi_resp.body, "created_by_actor_id") != null);
    try std.testing.expect(std.mem.indexOf(u8, openapi_resp.body, "\"operationId\":\"loadAgentSessionMessages\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, openapi_resp.body, "/nullclaw") == null);

    const capabilities_resp = handleRequest(&ctx, "GET", "/v1/capabilities", "", "");
    try std.testing.expectEqualStrings("200 OK", capabilities_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, capabilities_resp.body, "\"vector_rebuild\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, capabilities_resp.body, "\"vector_reconcile\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, capabilities_resp.body, "\"vector_status\"") != null);

    const artifact_types = handleRequest(&ctx, "GET", "/v1/artifact-types", "", "");
    try std.testing.expectEqualStrings("200 OK", artifact_types.status);
    try std.testing.expect(std.mem.indexOf(u8, artifact_types.body, "\"type\":\"decision\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact_types.body, "\"type\":\"memory_item\"") != null);
    const providers_resp = handleRequest(&ctx, "GET", "/v1/providers", "", "");
    try std.testing.expectEqualStrings("200 OK", providers_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, providers_resp.body, "openai-compatible-embeddings") != null);
    try std.testing.expect(std.mem.indexOf(u8, providers_resp.body, "ollama") != null);
    const invalid_decision = handleRequest(&ctx, "POST", "/v1/artifacts", "{\"type\":\"decision\",\"title\":\"ADR\",\"status\":\"verified\",\"body\":\"x\"}", "");
    try std.testing.expectEqualStrings("400 Bad Request", invalid_decision.status);

    const plan_resp = handleRequest(&ctx, "POST", "/v1/retrieval/plan", "{\"query\":\"NullPantry decision\",\"allow_reranker\":true}", "");
    try std.testing.expectEqualStrings("200 OK", plan_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, plan_resp.body, "\"use_vector\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan_resp.body, "\"use_graph\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan_resp.body, "\"use_reranker\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan_resp.body, "\"query_expanded\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan_resp.body, "\"expansion_terms\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan_resp.body, "\"adr\"") != null);

    const embed_resp = handleRequest(&ctx, "POST", "/v1/vector/embed", "{\"text\":\"agent memory\",\"dimensions\":4}", "");
    try std.testing.expectEqualStrings("200 OK", embed_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, embed_resp.body, "\"provider\":\"local-deterministic\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, embed_resp.body, "\"dimensions\":4") != null);
    const embed_override = handleRequest(&ctx, "POST", "/v1/vector/embed", "{\"text\":\"agent memory\",\"base_url\":\"http://127.0.0.1:9\",\"model\":\"x\"}", "");
    try std.testing.expectEqualStrings("400 Bad Request", embed_override.status);
    const vector_status = handleRequest(&ctx, "GET", "/v1/vector/status", "", "");
    try std.testing.expectEqualStrings("200 OK", vector_status.status);
    try std.testing.expect(std.mem.indexOf(u8, vector_status.body, "\"backend\":\"local\"") != null);

    const atom_resp = handleRequest(&ctx, "POST", "/v1/memory-atoms", "{\"text\":\"agent memory\",\"scope\":\"public\",\"created_by\":\"agent\"}", "");
    try std.testing.expectEqualStrings("200 OK", atom_resp.status);
    const created_atom_id = try extractJsonString(arena.allocator(), atom_resp.body, "\"id\":\"");
    const vector_body = try std.fmt.allocPrint(arena.allocator(), "{{\"object_id\":\"{s}\",\"text\":\"agent memory\",\"scope\":\"public\",\"embedding\":[1,0],\"dimensions\":2}}", .{created_atom_id});
    const upsert_resp = handleRequest(&ctx, "POST", "/v1/vector/upsert", vector_body, "");
    try std.testing.expectEqualStrings("200 OK", upsert_resp.status);
    const vector_id = try extractJsonString(arena.allocator(), upsert_resp.body, "\"id\":\"");
    const indexed_plan_resp = handleRequest(&ctx, "POST", "/v1/retrieval/plan", "{\"query\":\"NullPantry decision\",\"allow_reranker\":true}", "");
    try std.testing.expectEqualStrings("200 OK", indexed_plan_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, indexed_plan_resp.body, "\"use_vector\":true") != null);
    const orphan_upsert = handleRequest(&ctx, "POST", "/v1/vector/upsert", "{\"object_id\":\"mem_missing\",\"text\":\"orphan\",\"scope\":\"public\",\"embedding\":[1,0],\"dimensions\":2}", "");
    try std.testing.expectEqualStrings("404 Not Found", orphan_upsert.status);
    const vector_resp = handleRequest(&ctx, "POST", "/v1/vector/search", "{\"embedding\":[1,0],\"scopes\":[\"public\"],\"limit\":5}", "");
    try std.testing.expectEqualStrings("200 OK", vector_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, vector_resp.body, "vec_mem_") != null);
    const outbox_resp = handleRequest(&ctx, "GET", "/v1/vector/outbox", "", "");
    try std.testing.expectEqualStrings("200 OK", outbox_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, outbox_resp.body, "\"pending\":2") != null);
    const outbox_run = handleRequest(&ctx, "POST", "/v1/vector/outbox/run", "{\"limit\":10}", "");
    try std.testing.expectEqualStrings("200 OK", outbox_run.status);
    try std.testing.expect(std.mem.indexOf(u8, outbox_run.body, "\"processed\":2") != null);

    const embed_payload = try store_mod.vectorEmbedPayloadJson(arena.allocator(), 1, "agent memory replay", "public", "[]", null, 4);
    _ = try store.enqueueVectorOutbox(.{ .action = "embed", .object_type = "memory_atom", .object_id = created_atom_id, .payload_json = embed_payload });
    const embed_outbox_run = handleRequest(&ctx, "POST", "/v1/vector/outbox/run", "{\"limit\":10}", "");
    try std.testing.expectEqualStrings("200 OK", embed_outbox_run.status);
    try std.testing.expect(std.mem.indexOf(u8, embed_outbox_run.body, "\"embedded\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, embed_outbox_run.body, "\"indexed_local\":3") != null);

    const reconcile = handleRequest(&ctx, "POST", "/v1/vector/reconcile", "{\"limit\":10}", "");
    try std.testing.expectEqualStrings("200 OK", reconcile.status);
    try std.testing.expect(std.mem.indexOf(u8, reconcile.body, "\"canonical_chunks\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, reconcile.body, "\"enqueued_upserts\":2") != null);
    const delete_body = try std.fmt.allocPrint(arena.allocator(), "{{\"vector_id\":\"{s}\"}}", .{vector_id});
    const vector_delete = handleRequest(&ctx, "POST", "/v1/vector/delete", delete_body, "");
    try std.testing.expectEqualStrings("200 OK", vector_delete.status);
    try std.testing.expect(std.mem.indexOf(u8, vector_delete.body, "\"external_delete_enqueued\":true") != null);
    const vector_after_delete = handleRequest(&ctx, "POST", "/v1/vector/search", "{\"embedding\":[1,0],\"scopes\":[\"public\"],\"limit\":10}", "");
    try std.testing.expectEqualStrings("200 OK", vector_after_delete.status);
    try std.testing.expect(std.mem.indexOf(u8, vector_after_delete.body, vector_id) == null);
    const rebuild = handleRequest(&ctx, "POST", "/v1/vector/rebuild", "{\"limit\":10}", "");
    try std.testing.expectEqualStrings("200 OK", rebuild.status);
    try std.testing.expect(std.mem.indexOf(u8, rebuild.body, "\"canonical_chunks\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, rebuild.body, "\"enqueued_upserts\":1") != null);

    const diagnostics = handleRequest(&ctx, "GET", "/v1/lifecycle/diagnostics", "", "");
    try std.testing.expectEqualStrings("200 OK", diagnostics.status);
    try std.testing.expect(std.mem.indexOf(u8, diagnostics.body, "\"health\":\"ok\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostics.body, "\"queued_jobs\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostics.body, "\"pending_feed_events\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostics.body, "\"agent_memories\"") != null);
    const analytics_status = handleRequest(&ctx, "GET", "/v1/lifecycle/analytics/status", "", "");
    try std.testing.expectEqualStrings("400 Bad Request", analytics_status.status);
    const analytics_query = handleRequest(&ctx, "POST", "/v1/lifecycle/analytics/query", "{\"limit\":10}", "");
    try std.testing.expectEqualStrings("400 Bad Request", analytics_query.status);
    const analytics_export = handleRequest(&ctx, "POST", "/v1/lifecycle/analytics/export", "{\"limit\":10}", "");
    try std.testing.expectEqualStrings("400 Bad Request", analytics_export.status);
    const snapshot = handleRequest(&ctx, "POST", "/v1/lifecycle/snapshot", "{\"type\":\"manual\",\"summary\":{\"memory_atoms\":1}}", "");
    try std.testing.expectEqualStrings("200 OK", snapshot.status);
    try std.testing.expect(std.mem.indexOf(u8, snapshot.body, "\"snap_") != null);
}

test "api lifecycle snapshot export and import are permission aware" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var admin_ctx = Context{ .allocator = alloc, .store = &store };
    const public_source = try store.createSource(alloc, .{ .title = "Public source", .content = "visible source", .scope = "public" });
    const public_citation = try std.fmt.allocPrint(alloc, "[\"{s}\"]", .{public_source.id});
    _ = try store.createMemoryAtom(alloc, .{ .text = "exportable memory", .scope = "public", .created_by = "human", .status = "verified", .source_ids_json = public_citation });
    _ = try store.createMemoryAtom(alloc, .{ .text = "secret memory", .scope = "project:secret", .permissions_json = "[\"project:secret\"]", .created_by = "human", .status = "verified" });

    const export_resp = handleRequest(&admin_ctx, "POST", "/v1/lifecycle/snapshot/export", "{\"query\":\"memory\",\"scopes\":[\"public\"],\"limit\":20}", "");
    try std.testing.expectEqualStrings("200 OK", export_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, export_resp.body, "exportable memory") != null);
    try std.testing.expect(std.mem.indexOf(u8, export_resp.body, "secret memory") == null);
    try std.testing.expect(std.mem.indexOf(u8, export_resp.body, "\"object_count\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, export_resp.body, "\"persisted\":true") != null);

    var export_only_ctx = Context{ .allocator = alloc, .store = &store, .actor_scopes_json = "[\"public\"]", .actor_capabilities_json = "[\"read\",\"export\"]" };
    const preview_export = handleRequest(&export_only_ctx, "POST", "/v1/lifecycle/snapshot/export", "{\"query\":\"memory\",\"scopes\":[\"public\"],\"limit\":20}", "");
    try std.testing.expectEqualStrings("200 OK", preview_export.status);
    try std.testing.expect(std.mem.indexOf(u8, preview_export.body, "\"persisted\":false") != null);
    const denied_persist_export = handleRequest(&export_only_ctx, "POST", "/v1/lifecycle/snapshot/export", "{\"query\":\"memory\",\"persist\":true}", "");
    try std.testing.expectEqualStrings("403 Forbidden", denied_persist_export.status);

    var writer_ctx = Context{ .allocator = alloc, .store = &store, .actor_scopes_json = "[\"public\",\"write:public\",\"verify:public\"]", .actor_capabilities_json = "[\"read\",\"write\",\"propose\",\"verify\"]" };
    const import_resp = handleRequest(&writer_ctx, "POST", "/v1/lifecycle/snapshot/import", "{\"objects\":[{\"type\":\"memory_atom\",\"title\":\"Imported\",\"text\":\"imported snapshot memory\",\"scope\":\"public\",\"status\":\"verified\"}]}", "");
    try std.testing.expectEqualStrings("200 OK", import_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, import_resp.body, "\"imported\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, import_resp.body, "\"atomic\":true") != null);

    const search_resp = handleRequest(&writer_ctx, "POST", "/v1/search", "{\"query\":\"imported snapshot memory\",\"scopes\":[\"public\"]}", "");
    try std.testing.expectEqualStrings("200 OK", search_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, search_resp.body, "imported snapshot memory") != null);
}

test "api retrieval search fuses keyword and vector results" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = Context{ .allocator = alloc, .store = &store };

    const keyword_atom = try store.createMemoryAtom(alloc, .{ .text = "hybrid keyword decision", .scope = "public", .created_by = "human" });
    _ = keyword_atom;
    const vector_atom = try store.createMemoryAtom(alloc, .{ .text = "semantic only context", .scope = "public", .created_by = "human" });
    const embedding = try vector_mod.deterministicEmbedding(alloc, "hybrid vector", 64);
    const embedding_json = try vector_mod.embeddingToJson(alloc, embedding);
    _ = try store.upsertVectorChunk(alloc, .{
        .object_id = vector_atom.id,
        .text = "hybrid vector context",
        .scope = "public",
        .embedding_json = embedding_json,
        .dimensions = 64,
    });

    const resp = handleRequest(&ctx, "POST", "/v1/retrieval/search", "{\"query\":\"hybrid vector\",\"scopes\":[\"public\"],\"limit\":5}", "");
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"vector_ann\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"rrf\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"citation_assembly\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"llm_rerank\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "semantic only context") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"groups\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, vector_atom.id) != null);
}

test "api search falls back to keyword when embedding provider fails" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    _ = try store.createMemoryAtom(alloc, .{ .text = "provider fallback keyword memory", .scope = "public", .created_by = "human" });
    var ctx = Context{
        .allocator = alloc,
        .store = &store,
        .embedding_base_url = "://bad-provider-url",
        .embedding_model = "bad-model",
        .provider_timeout_secs = 1,
    };
    const resp = handleRequest(&ctx, "POST", "/v1/search", "{\"query\":\"provider fallback\",\"scopes\":[\"public\"],\"use_vector\":true}", "");
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "provider fallback keyword memory") != null);

    const strict = handleRequest(&ctx, "POST", "/v1/search", "{\"query\":\"provider fallback\",\"scopes\":[\"public\"],\"use_vector\":true,\"strict_vector\":true}", "");
    try std.testing.expectEqualStrings("500 Internal Server Error", strict.status);
}

test "api vector embed uses configured embedding fallback chain and rejects provider override" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const fallbacks = [_]providers.EmbeddingEndpointConfig{.{ .provider = .local_deterministic, .dimensions = 5 }};
    var ctx = Context{
        .allocator = alloc,
        .store = &store,
        .embedding_base_url = "://bad-provider-url",
        .embedding_model = "bad-model",
        .embedding_dimensions = 5,
        .embedding_fallbacks = &fallbacks,
        .provider_timeout_secs = 1,
    };

    const resp = handleRequest(&ctx, "POST", "/v1/vector/embed", "{\"text\":\"fallback provider vector\"}", "");
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"provider\":\"local-deterministic\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"dimensions\":5") != null);

    const override = handleRequest(&ctx, "POST", "/v1/vector/embed", "{\"text\":\"x\",\"provider\":\"gemini\"}", "");
    try std.testing.expectEqualStrings("400 Bad Request", override.status);
}

test "api search and ask do not return unrelated fallback evidence on zero hit" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    _ = try store.createMemoryAtom(alloc, .{ .text = "alpha pantry memory", .scope = "public", .created_by = "human", .status = "verified" });
    var ctx = Context{ .allocator = alloc, .store = &store };

    const search_resp = handleRequest(&ctx, "POST", "/v1/search", "{\"query\":\"zzzznomatch\",\"scopes\":[\"public\"],\"use_vector\":false}", "");
    try std.testing.expectEqualStrings("200 OK", search_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, search_resp.body, "\"results\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, search_resp.body, "alpha pantry memory") == null);

    const ask_resp = handleRequest(&ctx, "POST", "/v1/ask", "{\"query\":\"zzzznomatch\",\"scopes\":[\"public\"],\"use_vector\":false}", "");
    try std.testing.expectEqualStrings("200 OK", ask_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, ask_resp.body, "I don't know") != null);
    try std.testing.expect(std.mem.indexOf(u8, ask_resp.body, "alpha pantry memory") == null);
}

test "api ask returns citation ids and conflict warnings" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = Context{ .allocator = alloc, .store = &store };

    const entity = try store.resolveEntity(alloc, .{ .entity_type = "project", .name = "NullPantry" });
    _ = try store.createMemoryAtom(alloc, .{ .subject_entity_id = entity.id, .predicate = "uses_database", .object = "sqlite", .text = "NullPantry uses SQLite for local development.", .scope = "public", .created_by = "human", .status = "verified" });
    _ = try store.createMemoryAtom(alloc, .{ .subject_entity_id = entity.id, .predicate = "uses_database", .object = "postgres", .text = "NullPantry uses Postgres for production.", .scope = "public", .created_by = "human", .status = "verified" });

    const scan = handleRequest(&ctx, "POST", "/v1/conflicts/scan", "{\"scopes\":[\"public\"]}", "");
    try std.testing.expectEqualStrings("200 OK", scan.status);
    const resp = handleRequest(&ctx, "POST", "/v1/ask", "{\"query\":\"What database does NullPantry use?\",\"scopes\":[\"public\"],\"include_conflicts\":true}", "");
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"answer_provider\":\"extractive\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "mem_") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"potential_conflicts\"") != null);
}

test "api ask citation guard rejects uncited or unknown LLM citations" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = Context{ .allocator = alloc, .store = &store };
    const results = [_]domain.SearchResult{
        .{ .id = "mem_1", .result_type = "memory_atom", .title = "Decision", .text = "Decision: cite evidence.", .scope = "public", .status = "verified", .score = 1, .source_ids_json = "[\"src_1\"]" },
    };

    try std.testing.expect(try answerCitationsValid(&ctx, "Use the cited decision [src_1].", &results));
    try std.testing.expect(try answerCitationsValid(&ctx, "Use the cited decision [mem_1].", &results));
    try std.testing.expect(!try answerCitationsValid(&ctx, "Use the cited decision.", &results));
    try std.testing.expect(!try answerCitationsValid(&ctx, "Use the hidden decision [src_secret].", &results));
}

test "api ask scans visible conflicts when requested and rejects provider overrides" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = Context{ .allocator = alloc, .store = &store };

    const entity = try store.resolveEntity(alloc, .{ .entity_type = "project", .name = "NullPantry" });
    _ = try store.createMemoryAtom(alloc, .{ .subject_entity_id = entity.id, .predicate = "uses_database", .object = "sqlite", .text = "NullPantry uses SQLite.", .scope = "public", .created_by = "human", .status = "verified" });
    _ = try store.createMemoryAtom(alloc, .{ .subject_entity_id = entity.id, .predicate = "uses_database", .object = "postgres", .text = "NullPantry uses Postgres.", .scope = "public", .created_by = "human", .status = "verified" });

    const ask_resp = handleRequest(&ctx, "POST", "/v1/ask", "{\"query\":\"NullPantry database\",\"scopes\":[\"public\"],\"scan_conflicts\":true}", "");
    try std.testing.expectEqualStrings("200 OK", ask_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, ask_resp.body, "\"potential_conflicts\"") != null);
    const conflicts = try store.listConflicts(alloc, .{ .scopes_json = "[\"public\"]" });
    try std.testing.expect(conflicts.len > 0);

    const override_resp = handleRequest(&ctx, "POST", "/v1/ask", "{\"query\":\"x\",\"llm_base_url\":\"http://127.0.0.1:9\",\"llm_model\":\"x\"}", "");
    try std.testing.expectEqualStrings("400 Bad Request", override_resp.status);
}

test "api ask does not write conflict records unless scan is requested" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = Context{ .allocator = alloc, .store = &store };

    const entity = try store.resolveEntity(alloc, .{ .entity_type = "project", .name = "NullPantry", .scope = "public" });
    _ = try store.createMemoryAtom(alloc, .{ .subject_entity_id = entity.id, .predicate = "uses_database", .object = "sqlite", .text = "NullPantry uses SQLite.", .scope = "public", .created_by = "human", .status = "verified" });
    _ = try store.createMemoryAtom(alloc, .{ .subject_entity_id = entity.id, .predicate = "uses_database", .object = "postgres", .text = "NullPantry uses Postgres.", .scope = "public", .created_by = "human", .status = "verified" });

    const ask_resp = handleRequest(&ctx, "POST", "/v1/ask", "{\"query\":\"NullPantry database\",\"scopes\":[\"public\"]}", "");
    try std.testing.expectEqualStrings("200 OK", ask_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, ask_resp.body, "\"potential_conflicts\"") == null);
    const conflicts = try store.listConflicts(alloc, .{ .scopes_json = "[\"public\"]" });
    try std.testing.expectEqual(@as(usize, 0), conflicts.len);
}

test "api lifecycle cache semantic cache summarize rollout and hygiene endpoints" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = Context{ .allocator = arena.allocator(), .store = &store };

    const put_cache = handleRequest(&ctx, "POST", "/v1/lifecycle/cache/put", "{\"key\":\"prompt:a\",\"response\":{\"answer\":\"cached\"},\"ttl_ms\":10000}", "");
    try std.testing.expectEqualStrings("200 OK", put_cache.status);
    const get_cache = handleRequest(&ctx, "POST", "/v1/lifecycle/cache/get", "{\"key\":\"prompt:a\"}", "");
    try std.testing.expectEqualStrings("200 OK", get_cache.status);
    try std.testing.expect(std.mem.indexOf(u8, get_cache.body, "\"hit\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, get_cache.body, "\"answer\":\"cached\"") != null);

    const put_semantic = handleRequest(&ctx, "POST", "/v1/lifecycle/semantic-cache/put", "{\"key\":\"semantic:a\",\"query\":\"release checklist\",\"response\":{\"answer\":\"semantic cached\"},\"ttl_ms\":10000}", "");
    try std.testing.expectEqualStrings("200 OK", put_semantic.status);
    const search_semantic = handleRequest(&ctx, "POST", "/v1/lifecycle/semantic-cache/search", "{\"query\":\"release checklist\",\"min_score\":0.8}", "");
    try std.testing.expectEqualStrings("200 OK", search_semantic.status);
    try std.testing.expect(std.mem.indexOf(u8, search_semantic.body, "\"hit\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, search_semantic.body, "semantic cached") != null);

    const memory = handleRequest(&ctx, "POST", "/v1/memory-atoms", "{\"text\":\"cached retrieval memory\",\"scope\":\"public\",\"created_by\":\"human\",\"status\":\"verified\"}", "");
    try std.testing.expectEqualStrings("200 OK", memory.status);
    const cached_search = handleRequest(&ctx, "POST", "/v1/search", "{\"query\":\"cached retrieval\",\"scopes\":[\"public\"],\"cache_ttl_ms\":10000}", "");
    try std.testing.expectEqualStrings("200 OK", cached_search.status);
    const cached_ask = handleRequest(&ctx, "POST", "/v1/ask", "{\"query\":\"cached retrieval\",\"scopes\":[\"public\"],\"cache_ttl_ms\":10000,\"use_semantic_cache\":true}", "");
    try std.testing.expectEqualStrings("200 OK", cached_ask.status);

    const summary = handleRequest(&ctx, "POST", "/v1/lifecycle/summarize", "{\"messages\":[{\"content\":\"hello\"},{\"content\":\"world\"}],\"max_chars\":8}", "");
    try std.testing.expectEqualStrings("200 OK", summary.status);
    try std.testing.expect(std.mem.indexOf(u8, summary.body, "hello\\nwo") != null);

    const rollout = handleRequest(&ctx, "POST", "/v1/lifecycle/rollout", "{\"key\":\"agent:a\",\"percent\":100}", "");
    try std.testing.expectEqualStrings("200 OK", rollout.status);
    try std.testing.expect(std.mem.indexOf(u8, rollout.body, "\"enabled\":true") != null);

    const hygiene = handleRequest(&ctx, "POST", "/v1/lifecycle/hygiene", "{\"stale_after_ms\":1,\"archive_after_ms\":2}", "");
    try std.testing.expectEqualStrings("200 OK", hygiene.status);
    try std.testing.expect(std.mem.indexOf(u8, hygiene.body, "\"hygiene\"") != null);

    const manual_job = handleRequest(&ctx, "POST", "/v1/jobs", "{\"type\":\"hygiene\",\"scope\":\"workspace\",\"input\":{}}", "");
    try std.testing.expectEqualStrings("200 OK", manual_job.status);
    const manual_job_id = try extractJsonString(arena.allocator(), manual_job.body, "\"id\":\"");
    const manual_path = try std.fmt.allocPrint(arena.allocator(), "/v1/jobs/{s}/run", .{manual_job_id});
    const manual_run = handleRequest(&ctx, "POST", manual_path, "", "");
    try std.testing.expectEqualStrings("200 OK", manual_run.status);
    try std.testing.expect(std.mem.indexOf(u8, manual_run.body, "\"status\":\"succeeded\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manual_run.body, "\"checked\"") != null);

    const job = handleRequest(&ctx, "POST", "/v1/jobs", "{\"type\":\"hygiene\",\"scope\":\"workspace\",\"input\":{}}", "");
    try std.testing.expectEqualStrings("200 OK", job.status);
    const worker_run = handleRequest(&ctx, "POST", "/v1/workers/run", "{\"job_limit\":5,\"outbox_limit\":5}", "");
    try std.testing.expectEqualStrings("200 OK", worker_run.status);
    try std.testing.expect(std.mem.indexOf(u8, worker_run.body, "\"jobs_succeeded\":1") != null);
}

test "api response and semantic caches are scoped" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var secret_ctx = Context{
        .allocator = alloc,
        .store = &store,
        .actor_scopes_json = "[\"project:secret\"]",
        .actor_capabilities_json = "[\"read\",\"write\"]",
    };
    var public_ctx = Context{
        .allocator = alloc,
        .store = &store,
        .actor_scopes_json = "[\"public\"]",
        .actor_capabilities_json = "[\"read\"]",
    };

    const put_cache = handleRequest(&secret_ctx, "POST", "/v1/lifecycle/cache/put", "{\"key\":\"shared:key\",\"response\":{\"answer\":\"secret cached answer\"},\"ttl_ms\":10000}", "");
    try std.testing.expectEqualStrings("200 OK", put_cache.status);
    const public_cache = handleRequest(&public_ctx, "POST", "/v1/lifecycle/cache/get", "{\"key\":\"shared:key\"}", "");
    try std.testing.expectEqualStrings("200 OK", public_cache.status);
    try std.testing.expect(std.mem.indexOf(u8, public_cache.body, "\"hit\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, public_cache.body, "secret cached answer") == null);
    const secret_cache = handleRequest(&secret_ctx, "POST", "/v1/lifecycle/cache/get", "{\"key\":\"shared:key\"}", "");
    try std.testing.expect(std.mem.indexOf(u8, secret_cache.body, "\"hit\":true") != null);

    _ = try store.createMemoryAtom(alloc, .{ .text = "secret semantic cached memory", .scope = "project:secret", .created_by = "human", .status = "verified" });
    const secret_ask = handleRequest(&secret_ctx, "POST", "/v1/ask", "{\"query\":\"secret semantic cached memory\",\"scopes\":[\"project:secret\"],\"cache_ttl_ms\":10000,\"use_semantic_cache\":true}", "");
    try std.testing.expectEqualStrings("200 OK", secret_ask.status);
    try std.testing.expect(std.mem.indexOf(u8, secret_ask.body, "secret semantic cached memory") != null);

    const public_ask = handleRequest(&public_ctx, "POST", "/v1/ask", "{\"query\":\"secret semantic cached memory\",\"scopes\":[\"public\"],\"use_semantic_cache\":true}", "");
    try std.testing.expectEqualStrings("200 OK", public_ask.status);
    try std.testing.expect(std.mem.indexOf(u8, public_ask.body, "secret semantic cached memory") == null);
    try std.testing.expect(std.mem.indexOf(u8, public_ask.body, "I don't know") != null);
}

test "api lifecycle response cache is isolated by token principal actor" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const principals =
        \\{"a-token":{"actor_id":"agent:a","scopes":["public","write:public"],"capabilities":["read","write"]},"b-token":{"actor_id":"agent:b","scopes":["public","write:public"],"capabilities":["read","write"]}}
    ;
    var ctx = Context{ .allocator = alloc, .store = &store, .token_principals_json = principals };

    const raw_a = "POST /v1/lifecycle/cache/put HTTP/1.1\r\nAuthorization: Bearer a-token\r\n\r\n{}";
    const raw_b = "POST /v1/lifecycle/cache/get HTTP/1.1\r\nAuthorization: Bearer b-token\r\n\r\n{}";
    const put_a = handleRequest(&ctx, "POST", "/v1/lifecycle/cache/put", "{\"key\":\"shared:key\",\"scopes\":[\"public\"],\"response\":{\"answer\":\"actor-a\"},\"ttl_ms\":10000}", raw_a);
    try std.testing.expectEqualStrings("200 OK", put_a.status);

    const get_b_before = handleRequest(&ctx, "POST", "/v1/lifecycle/cache/get", "{\"key\":\"shared:key\",\"scopes\":[\"public\"]}", raw_b);
    try std.testing.expectEqualStrings("200 OK", get_b_before.status);
    try std.testing.expect(std.mem.indexOf(u8, get_b_before.body, "\"hit\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, get_b_before.body, "actor-a") == null);

    const put_b = handleRequest(&ctx, "POST", "/v1/lifecycle/cache/put", "{\"key\":\"shared:key\",\"scopes\":[\"public\"],\"response\":{\"answer\":\"actor-b\"},\"ttl_ms\":10000}", "POST /v1/lifecycle/cache/put HTTP/1.1\r\nAuthorization: Bearer b-token\r\n\r\n{}");
    try std.testing.expectEqualStrings("200 OK", put_b.status);

    const get_a = handleRequest(&ctx, "POST", "/v1/lifecycle/cache/get", "{\"key\":\"shared:key\",\"scopes\":[\"public\"]}", "POST /v1/lifecycle/cache/get HTTP/1.1\r\nAuthorization: Bearer a-token\r\n\r\n{}");
    try std.testing.expect(std.mem.indexOf(u8, get_a.body, "actor-a") != null);
    try std.testing.expect(std.mem.indexOf(u8, get_a.body, "actor-b") == null);
    const get_b = handleRequest(&ctx, "POST", "/v1/lifecycle/cache/get", "{\"key\":\"shared:key\",\"scopes\":[\"public\"]}", raw_b);
    try std.testing.expect(std.mem.indexOf(u8, get_b.body, "actor-b") != null);
    try std.testing.expect(std.mem.indexOf(u8, get_b.body, "actor-a") == null);
}

test "api memory feed and apply are permission aware" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var public_ctx = Context{ .allocator = alloc, .store = &store, .actor_scopes_json = "[\"public\",\"write:public\"]" };

    const append_resp = handleRequest(&public_ctx, "POST", "/v1/memory/feed", "{\"event_type\":\"memory_atom.upsert\",\"object_type\":\"memory_atom\",\"object_id\":\"mem_public\",\"scope\":\"public\",\"payload\":{\"text\":\"public memory\"}}", "");
    try std.testing.expectEqualStrings("200 OK", append_resp.status);
    const queued_dedupe = handleRequest(&public_ctx, "POST", "/v1/memory/feed", "{\"event_type\":\"memory_atom.upsert\",\"object_type\":\"memory_atom\",\"object_id\":\"mem_queued\",\"scope\":\"public\",\"dedupe_key\":\"evt-queued\",\"payload\":{\"text\":\"queued memory\"}}", "");
    try std.testing.expectEqualStrings("200 OK", queued_dedupe.status);
    const apply_queued_dedupe = handleRequest(&public_ctx, "POST", "/v1/memory/apply", "{\"event_type\":\"memory_atom.upsert\",\"object_type\":\"memory_atom\",\"scope\":\"public\",\"dedupe_key\":\"evt-queued\",\"payload\":{\"text\":\"queued memory\"}}", "");
    try std.testing.expectEqualStrings("409 Conflict", apply_queued_dedupe.status);
    const forbidden_resp = handleRequest(&public_ctx, "POST", "/v1/memory/feed", "{\"event_type\":\"memory_atom.upsert\",\"object_id\":\"mem_secret\",\"scope\":\"project:secret\",\"payload\":{\"text\":\"secret\"}}", "");
    try std.testing.expectEqualStrings("403 Forbidden", forbidden_resp.status);

    var admin_ctx = Context{ .allocator = alloc, .store = &store };
    _ = handleRequest(&admin_ctx, "POST", "/v1/memory/feed", "{\"event_type\":\"memory_atom.upsert\",\"object_id\":\"mem_secret\",\"scope\":\"project:secret\",\"payload\":{\"text\":\"secret\"}}", "");

    const public_feed = handleRequest(&public_ctx, "GET", "/v1/memory/feed?limit=10", "", "");
    try std.testing.expectEqualStrings("200 OK", public_feed.status);
    try std.testing.expect(std.mem.indexOf(u8, public_feed.body, "mem_public") != null);
    try std.testing.expect(std.mem.indexOf(u8, public_feed.body, "mem_secret") == null);

    const apply_resp = handleRequest(&public_ctx, "POST", "/v1/memory/apply", "{\"event_type\":\"memory_atom.upsert\",\"object_type\":\"memory_atom\",\"scope\":\"public\",\"payload\":{\"text\":\"applied memory\",\"created_by\":\"agent\"}}", "");
    try std.testing.expectEqualStrings("200 OK", apply_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, apply_resp.body, "\"applied\":true") != null);
    const search_resp = handleRequest(&public_ctx, "POST", "/v1/search", "{\"query\":\"applied\",\"scopes\":[\"public\"]}", "");
    try std.testing.expect(std.mem.indexOf(u8, search_resp.body, "applied memory") != null);
    try std.testing.expect(std.mem.indexOf(u8, search_resp.body, "\"citations\":[\"src_") != null);

    const payload_scope_escalation = handleRequest(&public_ctx, "POST", "/v1/memory/apply", "{\"event_type\":\"memory_atom.upsert\",\"object_type\":\"memory_atom\",\"scope\":\"public\",\"payload\":{\"text\":\"secret from payload\",\"scope\":\"project:secret\"}}", "");
    try std.testing.expectEqualStrings("403 Forbidden", payload_scope_escalation.status);

    const first_apply = handleRequest(&public_ctx, "POST", "/v1/memory/apply", "{\"event_type\":\"memory_atom.upsert\",\"object_type\":\"memory_atom\",\"scope\":\"public\",\"dedupe_key\":\"evt-public-1\",\"payload\":{\"text\":\"dedupe memory\",\"created_by\":\"agent\"}}", "");
    try std.testing.expectEqualStrings("200 OK", first_apply.status);
    const second_apply = handleRequest(&public_ctx, "POST", "/v1/memory/apply", "{\"event_type\":\"memory_atom.upsert\",\"object_type\":\"memory_atom\",\"scope\":\"public\",\"dedupe_key\":\"evt-public-1\",\"payload\":{\"text\":\"dedupe memory duplicate\",\"created_by\":\"agent\"}}", "");
    try std.testing.expectEqualStrings("200 OK", second_apply.status);
    const duplicate_search = handleRequest(&public_ctx, "POST", "/v1/search", "{\"query\":\"duplicate\",\"scopes\":[\"public\"]}", "");
    try std.testing.expectEqualStrings("200 OK", duplicate_search.status);
    try std.testing.expect(std.mem.indexOf(u8, duplicate_search.body, "dedupe memory duplicate") == null);
    const events = try store.listFeedEvents(alloc, .{ .scopes_json = "[\"admin\"]", .limit = 100 });
    var dedupe_count: usize = 0;
    for (events) |event| {
        if (event.dedupe_key != null and std.mem.eql(u8, event.dedupe_key.?, "evt-public-1")) dedupe_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), dedupe_count);
}

test "api memory feed lifecycle exposes status checkpoint compaction and cursor floor" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = Context{ .allocator = alloc, .store = &store, .actor_scopes_json = "[\"public\",\"write:public\"]" };

    const first = handleRequest(&ctx, "POST", "/v1/memory/events", "{\"event_type\":\"memory.note\",\"operation\":\"put\",\"object_type\":\"memory_atom\",\"object_id\":\"mem_one\",\"scope\":\"public\",\"payload\":{\"text\":\"one\"}}", "");
    try std.testing.expectEqualStrings("200 OK", first.status);
    const second = handleRequest(&ctx, "POST", "/v1/memory/events", "{\"event_type\":\"memory.note\",\"operation\":\"put\",\"object_type\":\"memory_atom\",\"object_id\":\"mem_two\",\"scope\":\"public\",\"payload\":{\"text\":\"two\"}}", "");
    try std.testing.expectEqualStrings("200 OK", second.status);

    const status = handleRequest(&ctx, "GET", "/v1/memory/status", "", "");
    try std.testing.expectEqualStrings("200 OK", status.status);
    try std.testing.expect(std.mem.indexOf(u8, status.body, "\"visible_events\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, status.body, "\"pending_events\":2") != null);

    const checkpoint = handleRequest(&ctx, "GET", "/v1/memory/checkpoint?limit=10", "", "");
    try std.testing.expectEqualStrings("200 OK", checkpoint.status);
    try std.testing.expect(std.mem.indexOf(u8, checkpoint.body, "\"events\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, checkpoint.body, "\"operation\":\"put\"") != null);

    const compact = handleRequest(&ctx, "POST", "/v1/memory/compact", "{\"before_id\":1}", "");
    try std.testing.expectEqualStrings("200 OK", compact.status);
    try std.testing.expect(std.mem.indexOf(u8, compact.body, "\"cursor_floor\":1") != null);

    const expired = handleRequest(&ctx, "GET", "/v1/memory/events?since_id=0", "", "");
    try std.testing.expectEqualStrings("410 Gone", expired.status);
    try std.testing.expect(std.mem.indexOf(u8, expired.body, "cursor_expired") != null);

    const recovery_checkpoint = handleRequest(&ctx, "GET", "/v1/memory/checkpoint?since_id=0&limit=10", "", "");
    try std.testing.expectEqualStrings("200 OK", recovery_checkpoint.status);
    try std.testing.expect(std.mem.indexOf(u8, recovery_checkpoint.body, "mem_one") != null);
    try std.testing.expect(std.mem.indexOf(u8, recovery_checkpoint.body, "mem_two") != null);

    const after_floor = handleRequest(&ctx, "GET", "/v1/memory/events?since_id=1", "", "");
    try std.testing.expectEqualStrings("200 OK", after_floor.status);
    try std.testing.expect(std.mem.indexOf(u8, after_floor.body, "mem_two") != null);
    try std.testing.expect(std.mem.indexOf(u8, after_floor.body, "mem_one") == null);
}

test "api memory checkpoint restore preserves actors and session deletes" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var admin_ctx = Context{ .allocator = alloc, .store = &store };

    const restore_body =
        \\{"events":[
        \\{"event_type":"agent_memory.put","operation":"put","object_type":"agent_memory","actor_id":"agent:restored","dedupe_key":"restore-agent-1","payload":{"key":"restored.pref","content":"restored owner value"}},
        \\{"event_type":"agent_memory.put","operation":"put","object_type":"agent_memory","actor_id":"agent:restored","dedupe_key":"restore-agent-pending","object_id":"restored.pending","status":"pending","payload":{"key":"restored.pending","content":"queued value"}}
        \\]}
    ;
    const restore = handleRequest(&admin_ctx, "POST", "/v1/memory/checkpoint", restore_body, "");
    try std.testing.expectEqualStrings("200 OK", restore.status);
    try std.testing.expect(std.mem.indexOf(u8, restore.body, "\"applied_events\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, restore.body, "\"queued_events\":1") != null);

    const restored = (try store.agentMemoryGet(alloc, "restored.pref", null, "agent:restored")).?;
    try std.testing.expectEqualStrings("restored owner value", restored.content);
    try std.testing.expect((try store.agentMemoryGet(alloc, "restored.pref", null, "local")) == null);

    const retry = handleRequest(&admin_ctx, "POST", "/v1/memory/checkpoint", restore_body, "");
    try std.testing.expectEqualStrings("200 OK", retry.status);
    const events = try store.listFeedEvents(alloc, .{ .scopes_json = "[\"admin\"]", .limit = 100 });
    var dedupe_count: usize = 0;
    for (events) |event| {
        if (event.dedupe_key != null and std.mem.eql(u8, event.dedupe_key.?, "restore-agent-1")) dedupe_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), dedupe_count);

    var actor_ctx = Context{ .allocator = alloc, .store = &store, .actor_id = "agent:restored", .actor_scopes_json = "[\"session:s1\",\"write:session:s1\"]" };
    const session_put = handleRequest(&actor_ctx, "POST", "/v1/memory/apply", "{\"event_type\":\"agent_memory.put\",\"object_type\":\"agent_memory\",\"payload\":{\"key\":\"session.pref\",\"content\":\"session value\",\"session_id\":\"s1\"}}", "");
    try std.testing.expectEqualStrings("200 OK", session_put.status);
    const session_delete = handleRequest(&actor_ctx, "POST", "/v1/memory/apply", "{\"event_type\":\"agent_memory.delete\",\"object_type\":\"agent_memory\",\"payload\":{\"key\":\"session.pref\",\"session_id\":\"s1\"}}", "");
    try std.testing.expectEqualStrings("200 OK", session_delete.status);
    try std.testing.expect((try store.agentMemoryGet(alloc, "session.pref", "s1", "agent:restored")) == null);

    var agent_a_ctx = Context{ .allocator = alloc, .store = &store, .actor_id = "agent:a", .actor_scopes_json = "[]" };
    const spoof = handleRequest(&agent_a_ctx, "POST", "/v1/memory/apply", "{\"event_type\":\"agent_memory.put\",\"object_type\":\"agent_memory\",\"actor_id\":\"agent:b\",\"payload\":{\"key\":\"spoof\",\"content\":\"blocked\"}}", "");
    try std.testing.expectEqualStrings("403 Forbidden", spoof.status);

    const source_apply = handleRequest(&admin_ctx, "POST", "/v1/memory/apply", "{\"event_type\":\"source.put\",\"object_type\":\"source\",\"scope\":\"public\",\"payload\":{\"title\":\"restored source\",\"content\":\"source feed content\"}}", "");
    try std.testing.expectEqualStrings("200 OK", source_apply.status);
    try std.testing.expect(std.mem.indexOf(u8, source_apply.body, "\"object_type\":\"source\"") != null);
}

test "api memory checkpoint restore preserves primitive ids and links" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var admin_ctx = Context{ .allocator = alloc, .store = &store };

    const restore_body =
        \\{"events":[
        \\{"event_type":"source.put","operation":"put","object_type":"source","object_id":"src_restore_fixed","scope":"public","permissions":["public"],"payload":{"id":"src_restore_fixed","type":"transcript","title":"Fixed Restore Source","content":"restore stable source content","scope":"public","permissions":["public"]}},
        \\{"event_type":"artifact.put","operation":"put","object_type":"artifact","object_id":"art_restore_fixed","scope":"public","permissions":["public"],"payload":{"id":"art_restore_fixed","type":"decision","title":"Fixed Restore Decision","body":"restore stable decision body","status":"proposed","scope":"public","permissions":["public"],"source_ids":["src_restore_fixed"],"fields":{"context":"restore context","decision":"restore stable decision","alternatives":"none","consequences":"stable ids","owner":"NullPantry","review_date":"2026-06-30"}}},
        \\{"event_type":"entity.put","operation":"put","object_type":"entity","object_id":"ent_restore_a","scope":"public","permissions":["public"],"payload":{"id":"ent_restore_a","type":"project","name":"Restore Project","scope":"public","permissions":["public"]}},
        \\{"event_type":"entity.put","operation":"put","object_type":"entity","object_id":"ent_restore_b","scope":"public","permissions":["public"],"payload":{"id":"ent_restore_b","type":"service","name":"Restore Service","scope":"public","permissions":["public"]}},
        \\{"event_type":"relation.put","operation":"put","object_type":"relation","object_id":"rel_restore_fixed","scope":"public","permissions":["public"],"payload":{"id":"rel_restore_fixed","from_entity_id":"ent_restore_a","relation_type":"restore_links_to","to_entity_id":"ent_restore_b","scope":"public","permissions":["public"],"source_ids":["src_restore_fixed"]}},
        \\{"event_type":"memory_atom.put","operation":"put","object_type":"memory_atom","object_id":"mem_restore_fixed","scope":"public","permissions":["public"],"payload":{"id":"mem_restore_fixed","subject_entity_id":"ent_restore_a","predicate":"states","object":"stable restore","text":"Restore memory atom keeps fixed ids","scope":"public","permissions":["public"],"status":"verified","source_ids":["src_restore_fixed"]}},
        \\{"event_type":"context_pack.put","operation":"put","object_type":"context_pack","object_id":"ctx_restore_fixed","scope":"public","permissions":["public"],"payload":{"id":"ctx_restore_fixed","purpose":"task","target":"agent","query":"restore stable source content","scopes":["public"],"use_vector":false}}
        \\]}
    ;
    const restore = handleRequest(&admin_ctx, "POST", "/v1/memory/checkpoint", restore_body, "");
    try std.testing.expectEqualStrings("200 OK", restore.status);
    try std.testing.expect(std.mem.indexOf(u8, restore.body, "\"applied_events\":7") != null);

    const source = (try store.getSource(alloc, "src_restore_fixed")).?;
    try std.testing.expectEqualStrings("Fixed Restore Source", source.title);
    const artifact = (try store.getArtifact(alloc, "art_restore_fixed")).?;
    try std.testing.expect(std.mem.indexOf(u8, artifact.source_ids_json, "src_restore_fixed") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.fields_json, "\"decision\":\"restore stable decision\"") != null);
    const entity = (try store.getEntity(alloc, "ent_restore_a")).?;
    try std.testing.expectEqualStrings("Restore Project", entity.name);
    const atom = (try store.getMemoryAtom(alloc, "mem_restore_fixed")).?;
    try std.testing.expectEqualStrings("ent_restore_a", atom.subject_entity_id.?);
    try std.testing.expect(std.mem.indexOf(u8, atom.source_ids_json, "src_restore_fixed") != null);

    const relation_results = try store.search(alloc, .{ .query = "restore_links_to", .scopes_json = "[\"public\"]", .limit = 20, .use_vector = false });
    var saw_relation = false;
    for (relation_results) |result| {
        if (std.mem.eql(u8, result.id, "rel_restore_fixed")) saw_relation = true;
    }
    try std.testing.expect(saw_relation);

    const context_results = try store.search(alloc, .{ .query = "restore stable source content", .scopes_json = "[\"public\"]", .limit = 20, .use_vector = false });
    var saw_context_pack = false;
    for (context_results) |result| {
        if (std.mem.eql(u8, result.id, "ctx_restore_fixed")) saw_context_pack = true;
    }
    try std.testing.expect(saw_context_pack);
}

test "api memory apply covers pantry primitives and lifecycle reducers" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = Context{ .allocator = alloc, .store = &store, .actor_scopes_json = "[\"public\",\"write:public\",\"verify:public\",\"delete:public\"]" };

    const source_apply = handleRequest(&ctx, "POST", "/v1/memory/apply", "{\"event_type\":\"source.put\",\"object_type\":\"source\",\"scope\":\"public\",\"dedupe_key\":\"primitive-source-1\",\"payload\":{\"title\":\"Primitive source\",\"content\":\"source evidence\"}}", "");
    try std.testing.expectEqualStrings("200 OK", source_apply.status);
    var source_parsed = try std.json.parseFromSlice(std.json.Value, alloc, source_apply.body, .{});
    defer source_parsed.deinit();
    const source_id = json.stringField(source_parsed.value.object, "object_id").?;

    const artifact_body = try std.fmt.allocPrint(alloc, "{{\"event_type\":\"artifact.put\",\"object_type\":\"artifact\",\"scope\":\"public\",\"dedupe_key\":\"primitive-artifact-1\",\"payload\":{{\"type\":\"decision\",\"title\":\"Primitive decision\",\"body\":\"accepted decision body\",\"status\":\"proposed\",\"source_ids\":[\"{s}\"],\"fields\":{{\"context\":\"primitive context\",\"decision\":\"accepted decision body\",\"alternatives\":\"none\",\"consequences\":\"feed coverage\",\"owner\":\"NullPantry\",\"review_date\":\"2026-06-30\"}}}}}}", .{source_id});
    const artifact_apply = handleRequest(&ctx, "POST", "/v1/memory/apply", artifact_body, "");
    try std.testing.expectEqualStrings("200 OK", artifact_apply.status);
    var artifact_parsed = try std.json.parseFromSlice(std.json.Value, alloc, artifact_apply.body, .{});
    defer artifact_parsed.deinit();
    const artifact_id = json.stringField(artifact_parsed.value.object, "object_id").?;
    const artifact_loaded = (try store.getArtifact(alloc, artifact_id)).?;
    try std.testing.expect(std.mem.indexOf(u8, artifact_loaded.fields_json, "\"decision\":\"accepted decision body\"") != null);

    const invalid_artifact = handleRequest(&ctx, "POST", "/v1/memory/apply", "{\"event_type\":\"artifact.put\",\"object_type\":\"artifact\",\"scope\":\"public\",\"payload\":{\"type\":\"decision\",\"title\":\"Invalid decision\",\"body\":\"missing structured fields\",\"status\":\"proposed\"}}", "");
    try std.testing.expectEqualStrings("400 Bad Request", invalid_artifact.status);

    const entity_a = handleRequest(&ctx, "POST", "/v1/memory/apply", "{\"event_type\":\"entity.put\",\"object_type\":\"entity\",\"scope\":\"public\",\"dedupe_key\":\"primitive-entity-a\",\"payload\":{\"type\":\"project\",\"name\":\"NullPantry Feed Entity\"}}", "");
    try std.testing.expectEqualStrings("200 OK", entity_a.status);
    var entity_a_parsed = try std.json.parseFromSlice(std.json.Value, alloc, entity_a.body, .{});
    defer entity_a_parsed.deinit();
    const entity_a_id = json.stringField(entity_a_parsed.value.object, "object_id").?;

    const entity_b = handleRequest(&ctx, "POST", "/v1/memory/apply", "{\"event_type\":\"entity.put\",\"object_type\":\"entity\",\"scope\":\"public\",\"dedupe_key\":\"primitive-entity-b\",\"payload\":{\"type\":\"service\",\"name\":\"NullClaw Feed Entity\"}}", "");
    try std.testing.expectEqualStrings("200 OK", entity_b.status);
    var entity_b_parsed = try std.json.parseFromSlice(std.json.Value, alloc, entity_b.body, .{});
    defer entity_b_parsed.deinit();
    const entity_b_id = json.stringField(entity_b_parsed.value.object, "object_id").?;

    const relation_body = try std.fmt.allocPrint(alloc, "{{\"event_type\":\"relation.put\",\"object_type\":\"relation\",\"scope\":\"public\",\"dedupe_key\":\"primitive-relation-1\",\"payload\":{{\"from_entity_id\":\"{s}\",\"relation_type\":\"integrates_with\",\"to_entity_id\":\"{s}\",\"source_ids\":[\"{s}\"]}}}}", .{ entity_a_id, entity_b_id, source_id });
    const relation_apply = handleRequest(&ctx, "POST", "/v1/memory/apply", relation_body, "");
    try std.testing.expectEqualStrings("200 OK", relation_apply.status);
    var relation_parsed = try std.json.parseFromSlice(std.json.Value, alloc, relation_apply.body, .{});
    defer relation_parsed.deinit();
    const relation_id = json.stringField(relation_parsed.value.object, "object_id").?;

    const context_apply = handleRequest(&ctx, "POST", "/v1/memory/apply", "{\"event_type\":\"context_pack.put\",\"object_type\":\"context_pack\",\"scope\":\"public\",\"payload\":{\"query\":\"Primitive decision\",\"scopes\":[\"public\"],\"use_vector\":false}}", "");
    try std.testing.expectEqualStrings("200 OK", context_apply.status);
    try std.testing.expect(std.mem.indexOf(u8, context_apply.body, "\"object_type\":\"context_pack\"") != null);

    const verify_body = try std.fmt.allocPrint(alloc, "{{\"event_type\":\"artifact.verify\",\"operation\":\"verify\",\"object_type\":\"artifact\",\"object_id\":\"{s}\",\"payload\":{{\"status\":\"accepted\"}}}}", .{artifact_id});
    const verify = handleRequest(&ctx, "POST", "/v1/memory/apply", verify_body, "");
    try std.testing.expectEqualStrings("200 OK", verify.status);
    const artifact = (try store.getArtifact(alloc, artifact_id)).?;
    try std.testing.expectEqualStrings("accepted", artifact.status);

    const stale_relation_body = try std.fmt.allocPrint(alloc, "{{\"event_type\":\"relation.mark_stale\",\"operation\":\"mark_stale\",\"object_type\":\"relation\",\"object_id\":\"{s}\",\"scope\":\"public\",\"payload\":{{\"scope\":\"public\"}}}}", .{relation_id});
    const stale_relation = handleRequest(&ctx, "POST", "/v1/memory/apply", stale_relation_body, "");
    try std.testing.expectEqualStrings("200 OK", stale_relation.status);

    const duplicate_source = handleRequest(&ctx, "POST", "/v1/memory/apply", "{\"event_type\":\"source.put\",\"object_type\":\"source\",\"scope\":\"public\",\"dedupe_key\":\"primitive-source-1\",\"payload\":{\"title\":\"duplicate source\",\"content\":\"should not create\"}}", "");
    try std.testing.expectEqualStrings("200 OK", duplicate_source.status);
    const events = try store.listFeedEvents(alloc, .{ .scopes_json = "[\"admin\"]", .limit = 100 });
    var source_dedupe_count: usize = 0;
    for (events) |event| {
        if (event.dedupe_key != null and std.mem.eql(u8, event.dedupe_key.?, "primitive-source-1")) source_dedupe_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), source_dedupe_count);
}

test "api lifecycle overlay hides source entity and context pack by default" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = Context{
        .allocator = alloc,
        .store = &store,
        .actor_scopes_json = "[\"public\",\"write:public\",\"verify:public\",\"delete:public\"]",
    };

    const source_apply = handleRequest(&ctx, "POST", "/v1/memory/apply", "{\"event_type\":\"source.put\",\"object_type\":\"source\",\"scope\":\"public\",\"payload\":{\"title\":\"Overlay Source Unique\",\"content\":\"overlay source lifecycle body\"}}", "");
    try std.testing.expectEqualStrings("200 OK", source_apply.status);
    const source_id = try extractJsonString(alloc, source_apply.body, "\"object_id\":\"");
    const source_before = handleRequest(&ctx, "POST", "/v1/search", "{\"query\":\"overlay source lifecycle body\",\"use_vector\":false}", "");
    try std.testing.expect(std.mem.indexOf(u8, source_before.body, "Overlay Source Unique") != null);
    const source_supersede_body = try std.fmt.allocPrint(alloc, "{{\"event_type\":\"source.supersede\",\"operation\":\"supersede\",\"object_type\":\"source\",\"object_id\":\"{s}\",\"payload\":{{\"reason\":\"test\"}}}}", .{source_id});
    const source_supersede = handleRequest(&ctx, "POST", "/v1/memory/apply", source_supersede_body, "");
    try std.testing.expectEqualStrings("200 OK", source_supersede.status);
    const source_after = handleRequest(&ctx, "POST", "/v1/search", "{\"query\":\"overlay source lifecycle body\",\"use_vector\":false}", "");
    try std.testing.expect(std.mem.indexOf(u8, source_after.body, "\"sources\":[]") != null);
    const source_with_deprecated = handleRequest(&ctx, "POST", "/v1/search", "{\"query\":\"overlay source lifecycle body\",\"use_vector\":false,\"include_deprecated\":true}", "");
    try std.testing.expect(std.mem.indexOf(u8, source_with_deprecated.body, "\"status\":\"superseded\"") != null);

    const entity_apply = handleRequest(&ctx, "POST", "/v1/memory/apply", "{\"event_type\":\"entity.put\",\"object_type\":\"entity\",\"scope\":\"public\",\"payload\":{\"type\":\"project\",\"name\":\"Overlay Entity Unique\"}}", "");
    try std.testing.expectEqualStrings("200 OK", entity_apply.status);
    const entity_id = try extractJsonString(alloc, entity_apply.body, "\"object_id\":\"");
    const entity_before = handleRequest(&ctx, "POST", "/v1/search", "{\"query\":\"Overlay Entity Unique\",\"use_vector\":false}", "");
    try std.testing.expect(std.mem.indexOf(u8, entity_before.body, "Overlay Entity Unique") != null);
    const entity_supersede_body = try std.fmt.allocPrint(alloc, "{{\"event_type\":\"entity.supersede\",\"operation\":\"supersede\",\"object_type\":\"entity\",\"object_id\":\"{s}\",\"payload\":{{\"reason\":\"test\"}}}}", .{entity_id});
    const entity_supersede = handleRequest(&ctx, "POST", "/v1/memory/apply", entity_supersede_body, "");
    try std.testing.expectEqualStrings("200 OK", entity_supersede.status);
    const entity_after = handleRequest(&ctx, "POST", "/v1/search", "{\"query\":\"Overlay Entity Unique\",\"use_vector\":false}", "");
    try std.testing.expect(std.mem.indexOf(u8, entity_after.body, "\"entities\":[]") != null);
    const entity_with_deprecated = handleRequest(&ctx, "POST", "/v1/search", "{\"query\":\"Overlay Entity Unique\",\"use_vector\":false,\"include_deprecated\":true}", "");
    try std.testing.expect(std.mem.indexOf(u8, entity_with_deprecated.body, "\"status\":\"superseded\"") != null);

    const context_apply = handleRequest(&ctx, "POST", "/v1/memory/apply", "{\"event_type\":\"context_pack.put\",\"object_type\":\"context_pack\",\"scope\":\"public\",\"payload\":{\"query\":\"Overlay Context Unique\",\"scopes\":[\"public\"],\"use_vector\":false}}", "");
    try std.testing.expectEqualStrings("200 OK", context_apply.status);
    const context_id = try extractJsonString(alloc, context_apply.body, "\"object_id\":\"");
    const context_before = handleRequest(&ctx, "POST", "/v1/search", "{\"query\":\"Overlay Context Unique\",\"use_vector\":false}", "");
    try std.testing.expect(std.mem.indexOf(u8, context_before.body, "\"type\":\"context_pack\"") != null);
    const context_supersede_body = try std.fmt.allocPrint(alloc, "{{\"event_type\":\"context_pack.supersede\",\"operation\":\"supersede\",\"object_type\":\"context_pack\",\"object_id\":\"{s}\",\"payload\":{{\"reason\":\"test\"}}}}", .{context_id});
    const context_supersede = handleRequest(&ctx, "POST", "/v1/memory/apply", context_supersede_body, "");
    try std.testing.expectEqualStrings("200 OK", context_supersede.status);
    const context_after = handleRequest(&ctx, "POST", "/v1/search", "{\"query\":\"Overlay Context Unique\",\"use_vector\":false}", "");
    try std.testing.expect(std.mem.indexOf(u8, context_after.body, "\"context_packs\":[]") != null);
    const context_with_deprecated = handleRequest(&ctx, "POST", "/v1/search", "{\"query\":\"Overlay Context Unique\",\"use_vector\":false,\"include_deprecated\":true}", "");
    try std.testing.expect(std.mem.indexOf(u8, context_with_deprecated.body, "\"status\":\"superseded\"") != null);
}

test "api memory feed redacts payload references hidden from actor" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const secret_source = try store.createSource(alloc, .{ .title = "Secret source", .content = "classified source text", .scope = "project:secret", .permissions_json = "[\"team:secret\"]" });
    var admin_ctx = Context{ .allocator = alloc, .store = &store };
    const event_body = try std.fmt.allocPrint(alloc, "{{\"event_type\":\"artifact.put\",\"object_type\":\"artifact\",\"object_id\":\"art_pending\",\"scope\":\"public\",\"payload\":{{\"title\":\"public shell\",\"summary\":\"classified summary\",\"source_ids\":[\"{s}\"]}}}}", .{secret_source.id});
    const append = handleRequest(&admin_ctx, "POST", "/v1/memory/feed", event_body, "");
    try std.testing.expectEqualStrings("200 OK", append.status);

    var public_ctx = Context{ .allocator = alloc, .store = &store, .actor_scopes_json = "[\"public\"]" };
    const public_feed = handleRequest(&public_ctx, "GET", "/v1/memory/events", "", "");
    try std.testing.expectEqualStrings("200 OK", public_feed.status);
    try std.testing.expect(std.mem.indexOf(u8, public_feed.body, "\"redacted\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, public_feed.body, "classified summary") == null);
    try std.testing.expect(std.mem.indexOf(u8, public_feed.body, secret_source.id) == null);

    var secret_ctx = Context{ .allocator = alloc, .store = &store, .actor_scopes_json = "[\"public\",\"project:secret\",\"team:secret\"]" };
    const secret_feed = handleRequest(&secret_ctx, "GET", "/v1/memory/events", "", "");
    try std.testing.expectEqualStrings("200 OK", secret_feed.status);
    try std.testing.expect(std.mem.indexOf(u8, secret_feed.body, "classified summary") != null);
    try std.testing.expect(std.mem.indexOf(u8, secret_feed.body, secret_source.id) != null);
}

test "api memory apply supports deterministic agent memory merge reducers" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = Context{ .allocator = alloc, .store = &store, .actor_id = "agent:a", .actor_scopes_json = "[\"public\",\"write:public\"]" };

    const first_set = handleRequest(&ctx, "POST", "/v1/memory/apply", "{\"event_type\":\"agent_memory.merge_string_set\",\"operation\":\"merge_string_set\",\"object_type\":\"agent_memory\",\"scope\":\"public\",\"payload\":{\"key\":\"prefs.tools\",\"values\":[\"zig\",\"sqlite\"],\"scope\":\"public\"}}", "");
    try std.testing.expectEqualStrings("200 OK", first_set.status);
    const second_set = handleRequest(&ctx, "POST", "/v1/memory/apply", "{\"event_type\":\"agent_memory.merge_string_set\",\"operation\":\"merge_string_set\",\"object_type\":\"agent_memory\",\"scope\":\"public\",\"payload\":{\"key\":\"prefs.tools\",\"values\":[\"postgres\",\"zig\"],\"scope\":\"public\"}}", "");
    try std.testing.expectEqualStrings("200 OK", second_set.status);
    const merged_set = handleRequest(&ctx, "GET", "/v1/agent-memory/prefs.tools", "", "");
    try std.testing.expectEqualStrings("200 OK", merged_set.status);
    try std.testing.expect(std.mem.indexOf(u8, merged_set.body, "[\\\"postgres\\\",\\\"sqlite\\\",\\\"zig\\\"]") != null);

    const first_object = handleRequest(&ctx, "POST", "/v1/memory/apply", "{\"event_type\":\"agent_memory.merge_object\",\"operation\":\"merge_object\",\"object_type\":\"agent_memory\",\"scope\":\"public\",\"payload\":{\"key\":\"prefs.profile\",\"object\":{\"language\":\"zig\",\"style\":\"concise\"},\"scope\":\"public\"}}", "");
    try std.testing.expectEqualStrings("200 OK", first_object.status);
    const second_object = handleRequest(&ctx, "POST", "/v1/memory/apply", "{\"event_type\":\"agent_memory.merge_object\",\"operation\":\"merge_object\",\"object_type\":\"agent_memory\",\"scope\":\"public\",\"payload\":{\"key\":\"prefs.profile\",\"object\":{\"database\":\"postgres\",\"style\":\"detailed\"},\"scope\":\"public\"}}", "");
    try std.testing.expectEqualStrings("200 OK", second_object.status);
    const merged_object = handleRequest(&ctx, "GET", "/v1/agent-memory/prefs.profile", "", "");
    try std.testing.expectEqualStrings("200 OK", merged_object.status);
    try std.testing.expect(std.mem.indexOf(u8, merged_object.body, "\\\"database\\\":\\\"postgres\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, merged_object.body, "\\\"language\\\":\\\"zig\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, merged_object.body, "\\\"style\\\":\\\"detailed\\\"") != null);

    var agent_b_ctx = Context{ .allocator = alloc, .store = &store, .actor_id = "agent:b", .actor_scopes_json = "[]" };
    const private_apply = handleRequest(&agent_b_ctx, "POST", "/v1/memory/apply", "{\"event_type\":\"agent_memory.put\",\"object_type\":\"agent_memory\",\"payload\":{\"key\":\"private.note\",\"content\":\"agent b only\"}}", "");
    try std.testing.expectEqualStrings("200 OK", private_apply.status);
    const hidden_from_a = handleRequest(&ctx, "GET", "/v1/agent-memory/private.note", "", "");
    try std.testing.expectEqualStrings("404 Not Found", hidden_from_a.status);
    const visible_to_b = handleRequest(&agent_b_ctx, "GET", "/v1/agent-memory/private.note", "", "");
    try std.testing.expectEqualStrings("200 OK", visible_to_b.status);
    try std.testing.expect(std.mem.indexOf(u8, visible_to_b.body, "agent b only") != null);
}

test "api graph and conflict mutations require write-like capabilities" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var read_ctx = Context{ .allocator = alloc, .store = &store, .actor_scopes_json = "[\"public\"]", .actor_capabilities_json = "[\"read\"]" };

    const entity_resp = handleRequest(&read_ctx, "POST", "/v1/entities/resolve", "{\"name\":\"NullPantry\",\"type\":\"project\"}", "");
    try std.testing.expectEqualStrings("403 Forbidden", entity_resp.status);

    const scan_resp = handleRequest(&read_ctx, "POST", "/v1/conflicts/scan", "{\"scopes\":[\"public\"]}", "");
    try std.testing.expectEqualStrings("403 Forbidden", scan_resp.status);
}

test "api relation creation cannot publish private endpoint names" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const secret = try store.resolveEntity(alloc, .{ .entity_type = "service", .name = "PrivateEndpoint", .scope = "project:secret", .permissions_json = "[\"team:secret\"]" });
    const public = try store.resolveEntity(alloc, .{ .entity_type = "project", .name = "PublicEndpoint", .scope = "public" });
    var ctx = Context{ .allocator = alloc, .store = &store, .actor_scopes_json = "[\"project:secret\",\"write:project:secret\",\"team:secret\"]" };

    const body = try std.fmt.allocPrint(alloc, "{{\"from_entity_id\":\"{s}\",\"to_entity_id\":\"{s}\",\"relation_type\":\"mentions\",\"scope\":\"public\"}}", .{ secret.id, public.id });
    const resp = handleRequest(&ctx, "POST", "/v1/relations", body, "");
    try std.testing.expectEqualStrings("403 Forbidden", resp.status);
}

test "api read endpoints require read capability" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    _ = try store.createMemoryAtom(alloc, .{ .text = "Public read capability memory", .scope = "public", .created_by = "human" });
    var ctx = Context{ .allocator = alloc, .store = &store, .actor_scopes_json = "[\"public\"]", .actor_capabilities_json = "[\"write\"]" };

    const search_resp = handleRequest(&ctx, "POST", "/v1/search", "{\"query\":\"Public read\"}", "");
    try std.testing.expectEqualStrings("403 Forbidden", search_resp.status);

    const ask_resp = handleRequest(&ctx, "POST", "/v1/ask", "{\"query\":\"Public read\"}", "");
    try std.testing.expectEqualStrings("403 Forbidden", ask_resp.status);

    const pack_resp = handleRequest(&ctx, "POST", "/v1/context-packs", "{\"task\":\"Public read\"}", "");
    try std.testing.expectEqualStrings("403 Forbidden", pack_resp.status);

    const embed_resp = handleRequest(&ctx, "POST", "/v1/vector/embed", "{\"text\":\"Public read\"}", "");
    try std.testing.expectEqualStrings("403 Forbidden", embed_resp.status);

    const outbox_resp = handleRequest(&ctx, "GET", "/v1/vector/outbox", "", "");
    try std.testing.expectEqualStrings("403 Forbidden", outbox_resp.status);

    const summarize_resp = handleRequest(&ctx, "POST", "/v1/lifecycle/summarize", "{\"messages\":[\"Public read\"]}", "");
    try std.testing.expectEqualStrings("403 Forbidden", summarize_resp.status);

    const rollout_resp = handleRequest(&ctx, "POST", "/v1/lifecycle/rollout", "{\"key\":\"public-read\",\"percent\":100}", "");
    try std.testing.expectEqualStrings("403 Forbidden", rollout_resp.status);

    var read_ctx = Context{ .allocator = alloc, .store = &store, .actor_scopes_json = "[\"public\"]", .actor_capabilities_json = "[\"read\"]" };
    const snapshot_resp = handleRequest(&read_ctx, "POST", "/v1/lifecycle/snapshot", "{\"summary\":{\"object_count\":0}}", "");
    try std.testing.expectEqualStrings("403 Forbidden", snapshot_resp.status);
}

test "api request principal headers can only narrow non-admin scopes" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    _ = try store.createMemoryAtom(alloc, .{ .text = "Secret header context", .scope = "project:secret", .created_by = "human" });
    var ctx = Context{ .allocator = alloc, .store = &store, .actor_scopes_json = "[\"public\"]" };
    const raw = "POST /v1/search HTTP/1.1\r\nX-NullPantry-Actor-Scopes: [\"project:secret\"]\r\n\r\n";
    const resp = handleRequest(&ctx, "POST", "/v1/search", "{\"query\":\"header\",\"scopes\":[\"project:secret\"]}", raw);
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "Secret header context") == null);
}

test "api capability model separates propose and verify" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ctx = Context{
        .allocator = alloc,
        .store = &store,
        .actor_scopes_json = "[\"public\"]",
        .actor_capabilities_json = "[\"propose\"]",
    };
    const proposed = handleRequest(&ctx, "POST", "/v1/memory-atoms", "{\"text\":\"draft memory\",\"scope\":\"public\",\"created_by\":\"agent\"}", "");
    try std.testing.expectEqualStrings("200 OK", proposed.status);
    const verified = handleRequest(&ctx, "POST", "/v1/memory-atoms", "{\"text\":\"verified memory\",\"scope\":\"public\",\"created_by\":\"human\"}", "");
    try std.testing.expectEqualStrings("403 Forbidden", verified.status);
}

test "api vector upsert cannot publish private object text" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const private_atom = try store.createMemoryAtom(alloc, .{ .text = "secret vector atom", .scope = "project:secret", .created_by = "human", .permissions_json = "[\"project:secret\"]" });
    const body = try std.fmt.allocPrint(alloc, "{{\"object_id\":\"{s}\",\"text\":\"secret vector leak\",\"scope\":\"public\",\"embedding\":[1,0],\"dimensions\":2}}", .{private_atom.id});
    var public_ctx = Context{ .allocator = alloc, .store = &store, .actor_scopes_json = "[\"public\"]" };
    const denied = handleRequest(&public_ctx, "POST", "/v1/vector/upsert", body, "");
    try std.testing.expectEqualStrings("403 Forbidden", denied.status);

    var admin_ctx = Context{ .allocator = alloc, .store = &store };
    const inserted = handleRequest(&admin_ctx, "POST", "/v1/vector/upsert", body, "");
    try std.testing.expectEqualStrings("200 OK", inserted.status);
    const vector_search_resp = handleRequest(&public_ctx, "POST", "/v1/vector/search", "{\"embedding\":[1,0],\"scopes\":[\"public\"]}", "");
    try std.testing.expectEqualStrings("200 OK", vector_search_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, vector_search_resp.body, "secret vector leak") == null);
}

test "api vector upsert inherits artifact acl instead of requested scope" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const artifact = try store.createArtifact(alloc, .{ .title = "Secret artifact", .body = "secret artifact body", .scope = "project:secret", .permissions_json = "[\"project:secret\"]" });
    const body = try std.fmt.allocPrint(alloc, "{{\"object_type\":\"artifact\",\"object_id\":\"{s}\",\"text\":\"artifact vector leak\",\"scope\":\"public\",\"embedding\":[1,0],\"dimensions\":2}}", .{artifact.id});

    var admin_ctx = Context{ .allocator = alloc, .store = &store };
    const inserted = handleRequest(&admin_ctx, "POST", "/v1/vector/upsert", body, "");
    try std.testing.expectEqualStrings("200 OK", inserted.status);
    try std.testing.expect(std.mem.indexOf(u8, inserted.body, "\"scope\":\"project:secret\"") != null);

    var public_ctx = Context{ .allocator = alloc, .store = &store, .actor_scopes_json = "[\"public\"]" };
    const public_search = handleRequest(&public_ctx, "POST", "/v1/vector/search", "{\"embedding\":[1,0],\"scopes\":[\"public\"]}", "");
    try std.testing.expectEqualStrings("200 OK", public_search.status);
    try std.testing.expect(std.mem.indexOf(u8, public_search.body, "artifact vector leak") == null);
}

test "api vector search excludes deprecated artifacts unless requested" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const artifact = try store.createArtifact(alloc, .{ .title = "Deprecated API artifact", .body = "deprecated vector artifact body", .status = "deprecated", .scope = "public" });
    const body = try std.fmt.allocPrint(alloc, "{{\"object_type\":\"artifact\",\"object_id\":\"{s}\",\"text\":\"deprecated vector artifact body\",\"scope\":\"public\",\"embedding\":[1,0],\"dimensions\":2}}", .{artifact.id});
    var ctx = Context{ .allocator = alloc, .store = &store };
    const inserted = handleRequest(&ctx, "POST", "/v1/vector/upsert", body, "");
    try std.testing.expectEqualStrings("200 OK", inserted.status);

    const default_search = handleRequest(&ctx, "POST", "/v1/vector/search", "{\"embedding\":[1,0],\"scopes\":[\"public\"]}", "");
    try std.testing.expectEqualStrings("200 OK", default_search.status);
    try std.testing.expect(std.mem.indexOf(u8, default_search.body, "deprecated vector artifact body") == null);

    const explicit_search = handleRequest(&ctx, "POST", "/v1/vector/search", "{\"embedding\":[1,0],\"scopes\":[\"public\"],\"include_deprecated\":true}", "");
    try std.testing.expectEqualStrings("200 OK", explicit_search.status);
    try std.testing.expect(std.mem.indexOf(u8, explicit_search.body, "deprecated vector artifact body") != null);
}

test "api vector upsert requires a backed primitive object" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ctx = Context{ .allocator = alloc, .store = &store };
    const missing = handleRequest(&ctx, "POST", "/v1/vector/upsert", "{\"object_type\":\"raw\",\"object_id\":\"raw_1\",\"scope\":\"public\",\"embedding\":[1,0],\"text\":\"orphan vector text\"}", "");
    try std.testing.expectEqualStrings("404 Not Found", missing.status);

    const search_resp = handleRequest(&ctx, "POST", "/v1/vector/search", "{\"embedding\":[1,0],\"scopes\":[\"public\"]}", "");
    try std.testing.expectEqualStrings("200 OK", search_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, search_resp.body, "orphan vector text") == null);
}

test "api search does not trust requested scopes from body" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    _ = try store.createMemoryAtom(alloc, .{ .text = "Secret launch context", .scope = "project:secret", .created_by = "human" });
    var ctx = Context{ .allocator = alloc, .store = &store, .actor_scopes_json = "[\"public\"]" };
    const resp = handleRequest(&ctx, "POST", "/v1/search", "{\"query\":\"secret\",\"scopes\":[\"project:secret\"]}", "");
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "Secret launch context") == null);
}

test "api ask and context pack do not leak requested inaccessible scopes" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    _ = try store.createMemoryAtom(alloc, .{ .text = "Secret incident detail", .scope = "project:secret", .created_by = "human" });
    var ctx = Context{ .allocator = alloc, .store = &store, .actor_scopes_json = "[\"public\"]" };

    const ask_resp = handleRequest(&ctx, "POST", "/v1/ask", "{\"query\":\"secret\",\"scopes\":[\"project:secret\"]}", "");
    try std.testing.expectEqualStrings("200 OK", ask_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, ask_resp.body, "Secret incident detail") == null);

    const ctx_resp = handleRequest(&ctx, "POST", "/v1/context-packs", "{\"task\":\"secret\",\"scopes\":[\"project:secret\"]}", "");
    try std.testing.expectEqualStrings("200 OK", ctx_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, ctx_resp.body, "Secret incident detail") == null);
    try std.testing.expect(std.mem.indexOf(u8, ctx_resp.body, "\"sections\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, ctx_resp.body, "\"forbidden_assumptions\":") != null);
    var parsed_ctx = try std.json.parseFromSlice(std.json.Value, alloc, ctx_resp.body, .{});
    defer parsed_ctx.deinit();
    try std.testing.expect(parsed_ctx.value.object.get("context_pack") != null);
}

test "api context pack read preview does not persist without write capability" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var read_ctx = Context{ .allocator = alloc, .store = &store, .actor_scopes_json = "[\"public\"]", .actor_capabilities_json = "[\"read\"]" };
    const preview = handleRequest(&read_ctx, "POST", "/v1/context-packs", "{\"task\":\"Ephemeral Pack Unique\",\"scopes\":[\"public\"]}", "");
    try std.testing.expectEqualStrings("200 OK", preview.status);
    try std.testing.expect(std.mem.indexOf(u8, preview.body, "\"persisted\":false") != null);

    const denied = handleRequest(&read_ctx, "POST", "/v1/context-packs", "{\"task\":\"Ephemeral Pack Unique\",\"persist\":true}", "");
    try std.testing.expectEqualStrings("403 Forbidden", denied.status);

    var write_ctx = Context{ .allocator = alloc, .store = &store, .actor_scopes_json = "[\"public\",\"write:public\"]", .actor_capabilities_json = "[\"read\",\"write\"]" };
    const persisted = handleRequest(&write_ctx, "POST", "/v1/context-packs", "{\"task\":\"Persistent Pack Unique\",\"scopes\":[\"public\"],\"persist\":true}", "");
    try std.testing.expectEqualStrings("200 OK", persisted.status);
    try std.testing.expect(std.mem.indexOf(u8, persisted.body, "\"persisted\":true") != null);

    const search_resp = handleRequest(&write_ctx, "POST", "/v1/search", "{\"query\":\"Persistent Pack Unique\",\"scopes\":[\"public\"],\"use_vector\":false}", "");
    try std.testing.expectEqualStrings("200 OK", search_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, search_resp.body, "\"type\":\"context_pack\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, search_resp.body, "Ephemeral Pack Unique") == null);
}

test "api rerank parser reorders by returned ids and keeps omitted results" {
    const alloc = std.testing.allocator;
    const results = [_]domain.SearchResult{
        .{ .id = "mem_a", .result_type = "memory_atom", .title = "A", .text = "alpha", .scope = "public", .status = "verified", .score = 0.4, .source_ids_json = "[]", .created_at_ms = 1, .confidence = 0.5 },
        .{ .id = "mem_b", .result_type = "memory_atom", .title = "B", .text = "beta", .scope = "public", .status = "verified", .score = 0.9, .source_ids_json = "[]", .created_at_ms = 2, .confidence = 0.5 },
        .{ .id = "mem_c", .result_type = "memory_atom", .title = "C", .text = "gamma", .scope = "public", .status = "verified", .score = 0.1, .source_ids_json = "[]", .created_at_ms = 3, .confidence = 0.5 },
    };
    const reranked = try parseRerankOrder(alloc, "[\"mem_b\",\"mem_a\"]", results[0..]);
    defer alloc.free(reranked);
    try std.testing.expectEqualStrings("mem_b", reranked[0].id);
    try std.testing.expectEqualStrings("mem_a", reranked[1].id);
    try std.testing.expectEqualStrings("mem_c", reranked[2].id);
}

test "api markdown import creates source artifact and extracted memory" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = Context{
        .allocator = alloc,
        .store = &store,
        .actor_scopes_json = "[\"project:nullpantry\",\"write:project:nullpantry\"]",
        .actor_capabilities_json = "[\"read\",\"write\",\"propose\",\"export\"]",
    };

    const body =
        "{\"content\":\"---\\ntitle: NullPantry ADR\\nartifact_type: decision\\nstatus: accepted\\nscope: project:nullpantry\\npermissions: [\\\"project:nullpantry\\\"]\\nfields: {\\\"context\\\":\\\"Need shared memory\\\",\\\"decision\\\":\\\"Use NullPantry\\\"}\\n---\\n\\n# Body\\n\\nDecision: centralize complex agent memory in NullPantry.\\n\",\"run_now\":true}";
    const resp = handleRequest(&ctx, "POST", "/v1/markdown/import", body, "");
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"type\":\"decision\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"status\":\"accepted\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"predicate\":\"decision\"") != null);
}

test "api markdown export emits permission-aware artifact markdown" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const artifact = try store.createArtifact(alloc, .{
        .artifact_type = "runbook",
        .title = "Release NullPantry",
        .body = "Step 1\nStep 2",
        .status = "verified",
        .scope = "project:nullpantry",
        .permissions_json = "[\"project:nullpantry\"]",
        .fields_json = "{\"procedure\":\"release\"}",
    });

    var ctx = Context{
        .allocator = alloc,
        .store = &store,
        .actor_scopes_json = "[\"project:nullpantry\"]",
        .actor_capabilities_json = "[\"read\",\"export\"]",
    };
    const export_body = try std.fmt.allocPrint(alloc, "{{\"artifact_id\":\"{s}\"}}", .{artifact.id});
    const resp = handleRequest(&ctx, "POST", "/v1/markdown/export", export_body, "");
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "artifact_type: \\\"runbook\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "Step 2") != null);
}

test "api markdown import directory recursively creates source artifacts" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const root_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/markdown-import", .{tmp.sub_path});
    const nested_path = try std.fs.path.join(alloc, &.{ root_path, "ops" });
    try std.Io.Dir.cwd().createDirPath(compat.io(), nested_path);
    const adr_path = try std.fs.path.join(alloc, &.{ root_path, "adr.md" });
    const runbook_path = try std.fs.path.join(alloc, &.{ nested_path, "runbook.markdown" });
    const ignored_path = try std.fs.path.join(alloc, &.{ root_path, "ignore.txt" });
    try std.Io.Dir.cwd().writeFile(compat.io(), .{ .sub_path = adr_path, .data = "---\ntitle: Directory ADR\nartifact_type: decision\nstatus: accepted\nrelated_entities: NullPantry, NullClaw\n---\n\n# Directory ADR\n\nDecision: import markdown directories.\n" });
    try std.Io.Dir.cwd().writeFile(compat.io(), .{ .sub_path = runbook_path, .data = "# Release Runbook\n\nStep 1\n" });
    try std.Io.Dir.cwd().writeFile(compat.io(), .{ .sub_path = ignored_path, .data = "ignore" });

    var ctx = Context{
        .allocator = alloc,
        .store = &store,
        .actor_scopes_json = "[\"project:nullpantry\",\"write:project:nullpantry\"]",
        .actor_capabilities_json = "[\"read\",\"write\",\"propose\",\"export\"]",
    };
    const body = try std.fmt.allocPrint(alloc, "{{\"path\":\"{s}\",\"scope\":\"project:nullpantry\",\"permissions\":[\"project:nullpantry\"],\"queue_extraction\":false}}", .{root_path});
    const resp = handleRequest(&ctx, "POST", "/v1/markdown/import-directory", body, "");
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"imported\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "adr.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "runbook.markdown") != null);

    const second_resp = handleRequest(&ctx, "POST", "/v1/markdown/import-directory", body, "");
    try std.testing.expectEqualStrings("200 OK", second_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, second_resp.body, "\"imported\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, second_resp.body, "\"unchanged\":2") != null);

    const search_resp = handleRequest(&ctx, "POST", "/v1/search", "{\"query\":\"markdown directories\",\"scopes\":[\"project:nullpantry\"],\"use_vector\":false}", "");
    try std.testing.expectEqualStrings("200 OK", search_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, search_resp.body, "Directory ADR") != null);
}

test "api markdown export directory writes artifact files" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const artifact = try store.createArtifact(alloc, .{
        .artifact_type = "runbook",
        .title = "Release NullPantry",
        .body = "Step 1\nStep 2",
        .status = "verified",
        .scope = "project:nullpantry",
        .permissions_json = "[\"project:nullpantry\"]",
        .fields_json = "{\"procedure\":\"release\"}",
    });

    var ctx = Context{
        .allocator = alloc,
        .store = &store,
        .actor_scopes_json = "[\"project:nullpantry\"]",
        .actor_capabilities_json = "[\"read\",\"export\"]",
    };
    const root_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/markdown-export", .{tmp.sub_path});
    const body = try std.fmt.allocPrint(alloc, "{{\"path\":\"{s}\",\"artifact_ids\":[\"{s}\"],\"overwrite\":true}}", .{ root_path, artifact.id });
    const resp = handleRequest(&ctx, "POST", "/v1/markdown/export-directory", body, "");
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"exported\":1") != null);

    const exported_name = try markdown_adapter.exportFileName(alloc, artifact.title, artifact.id, "artifact");
    const exported_path = try std.fs.path.join(alloc, &.{ root_path, exported_name });
    const exported = try std.Io.Dir.cwd().readFileAlloc(compat.io(), exported_path, alloc, .limited(64 * 1024));
    try std.testing.expect(std.mem.indexOf(u8, exported, "artifact_type: \"runbook\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, exported, "Step 2") != null);
}

test "api graph neighbors and path are acl aware" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const a = try store.resolveEntity(alloc, .{ .entity_type = "project", .name = "Graph A", .scope = "public" });
    const b = try store.resolveEntity(alloc, .{ .entity_type = "service", .name = "Graph B", .scope = "public" });
    const c = try store.resolveEntity(alloc, .{ .entity_type = "feature", .name = "Graph C", .scope = "public" });
    const d = try store.resolveEntity(alloc, .{ .entity_type = "concept", .name = "Graph D", .scope = "public" });
    const e = try store.resolveEntity(alloc, .{ .entity_type = "concept", .name = "Graph E", .scope = "public" });
    const secret = try store.resolveEntity(alloc, .{ .entity_type = "service", .name = "Secret Graph Service", .scope = "project:secret", .permissions_json = "[\"team:secret\"]" });
    const secret_source = try store.createSource(alloc, .{ .title = "Secret relation evidence", .scope = "project:secret", .permissions_json = "[\"team:secret\"]", .content = "hidden citation" });
    const secret_source_ids = try std.fmt.allocPrint(alloc, "[\"{s}\"]", .{secret_source.id});

    _ = try store.createRelation(alloc, .{ .from_entity_id = a.id, .relation_type = "depends_on", .to_entity_id = b.id, .scope = "public", .source_ids_json = secret_source_ids });
    const bc = try store.createRelation(alloc, .{ .from_entity_id = b.id, .relation_type = "implements", .to_entity_id = c.id, .scope = "public" });
    _ = try store.createRelation(alloc, .{ .from_entity_id = d.id, .relation_type = "related_to", .to_entity_id = e.id, .scope = "public" });
    _ = try store.createRelation(alloc, .{ .from_entity_id = b.id, .relation_type = "touches_secret", .to_entity_id = secret.id, .scope = "project:secret", .permissions_json = "[\"team:secret\"]" });

    var ctx = Context{ .allocator = alloc, .store = &store, .actor_scopes_json = "[\"public\"]", .actor_capabilities_json = "[\"read\"]" };
    const schema = handleRequest(&ctx, "GET", "/v1/graph/schema", "", "");
    try std.testing.expectEqualStrings("200 OK", schema.status);
    try std.testing.expect(std.mem.indexOf(u8, schema.body, "supersedes") != null);

    const neighbors_body = try std.fmt.allocPrint(alloc, "{{\"entity_id\":\"{s}\",\"depth\":2,\"limit\":20}}", .{a.id});
    const neighbors = handleRequest(&ctx, "POST", "/v1/graph/neighbors", neighbors_body, "");
    try std.testing.expectEqualStrings("200 OK", neighbors.status);
    try std.testing.expect(std.mem.indexOf(u8, neighbors.body, "Graph A") != null);
    try std.testing.expect(std.mem.indexOf(u8, neighbors.body, "Graph B") != null);
    try std.testing.expect(std.mem.indexOf(u8, neighbors.body, "Graph C") != null);
    try std.testing.expect(std.mem.indexOf(u8, neighbors.body, "Secret Graph Service") == null);
    try std.testing.expect(std.mem.indexOf(u8, neighbors.body, secret_source.id) == null);

    const path_body = try std.fmt.allocPrint(alloc, "{{\"from_entity_id\":\"{s}\",\"to_entity_id\":\"{s}\",\"max_depth\":3}}", .{ a.id, c.id });
    const path = handleRequest(&ctx, "POST", "/v1/graph/path", path_body, "");
    try std.testing.expectEqualStrings("200 OK", path.status);
    try std.testing.expect(std.mem.indexOf(u8, path.body, "\"found\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, path.body, "depends_on") != null);
    try std.testing.expect(std.mem.indexOf(u8, path.body, "implements") != null);

    const reverse_outbound_body = try std.fmt.allocPrint(alloc, "{{\"from_entity_id\":\"{s}\",\"to_entity_id\":\"{s}\",\"max_depth\":3,\"direction\":\"outbound\"}}", .{ c.id, a.id });
    const reverse_outbound = handleRequest(&ctx, "POST", "/v1/graph/path", reverse_outbound_body, "");
    try std.testing.expectEqualStrings("200 OK", reverse_outbound.status);
    try std.testing.expect(std.mem.indexOf(u8, reverse_outbound.body, "\"found\":false") != null);

    const symmetric_outbound_body = try std.fmt.allocPrint(alloc, "{{\"from_entity_id\":\"{s}\",\"to_entity_id\":\"{s}\",\"max_depth\":1,\"direction\":\"outbound\"}}", .{ e.id, d.id });
    const symmetric_outbound = handleRequest(&ctx, "POST", "/v1/graph/path", symmetric_outbound_body, "");
    try std.testing.expectEqualStrings("200 OK", symmetric_outbound.status);
    try std.testing.expect(std.mem.indexOf(u8, symmetric_outbound.body, "\"found\":true") != null);

    const filtered_query_body = try std.fmt.allocPrint(alloc, "{{\"entity_id\":\"{s}\",\"depth\":2,\"direction\":\"outbound\",\"relation_types\":[\"depends_on\"],\"limit\":20}}", .{a.id});
    const filtered_query = handleRequest(&ctx, "POST", "/v1/graph/query", filtered_query_body, "");
    try std.testing.expectEqualStrings("200 OK", filtered_query.status);
    try std.testing.expect(std.mem.indexOf(u8, filtered_query.body, "Graph B") != null);
    try std.testing.expect(std.mem.indexOf(u8, filtered_query.body, "Graph C") == null);

    const secret_path_body = try std.fmt.allocPrint(alloc, "{{\"from_entity_id\":\"{s}\",\"to_entity_id\":\"{s}\",\"max_depth\":3}}", .{ a.id, secret.id });
    const secret_path = handleRequest(&ctx, "POST", "/v1/graph/path", secret_path_body, "");
    try std.testing.expectEqualStrings("404 Not Found", secret_path.status);

    var admin_ctx = Context{ .allocator = alloc, .store = &store };
    const decision = try store.resolveEntity(alloc, .{ .entity_type = "decision", .name = "Invalid Implementer", .scope = "public" });
    const ticket = try store.resolveEntity(alloc, .{ .entity_type = "ticket", .name = "Invalid Target", .scope = "public" });
    const invalid_body = try std.fmt.allocPrint(alloc, "{{\"from_entity_id\":\"{s}\",\"relation_type\":\"implements\",\"to_entity_id\":\"{s}\",\"scope\":\"public\"}}", .{ decision.id, ticket.id });
    const invalid = handleRequest(&admin_ctx, "POST", "/v1/relations", invalid_body, "");
    try std.testing.expectEqualStrings("400 Bad Request", invalid.status);

    const patch_entity_path = try std.fmt.allocPrint(alloc, "/v1/entities/{s}", .{a.id});
    const patched_entity = handleRequest(&admin_ctx, "PATCH", patch_entity_path, "{\"status\":\"stale\"}", "");
    try std.testing.expectEqualStrings("200 OK", patched_entity.status);
    try std.testing.expect(std.mem.indexOf(u8, patched_entity.body, "\"status\":\"stale\"") != null);

    const delete_relation_path = try std.fmt.allocPrint(alloc, "/v1/relations/{s}", .{bc.id});
    const deleted_relation = handleRequest(&admin_ctx, "DELETE", delete_relation_path, "", "");
    try std.testing.expectEqualStrings("200 OK", deleted_relation.status);
    const after_delete_path = handleRequest(&ctx, "POST", "/v1/graph/path", path_body, "");
    try std.testing.expectEqualStrings("200 OK", after_delete_path.status);
    try std.testing.expect(std.mem.indexOf(u8, after_delete_path.body, "\"found\":false") != null);

    const delete_entity_path = try std.fmt.allocPrint(alloc, "/v1/entities/{s}", .{b.id});
    const deleted_entity = handleRequest(&admin_ctx, "DELETE", delete_entity_path, "", "");
    try std.testing.expectEqualStrings("200 OK", deleted_entity.status);
    const after_entity_delete = handleRequest(&ctx, "POST", "/v1/graph/neighbors", neighbors_body, "");
    try std.testing.expectEqualStrings("200 OK", after_entity_delete.status);
    try std.testing.expect(std.mem.indexOf(u8, after_entity_delete.body, "Graph B") == null);
    const include_deleted_body = try std.fmt.allocPrint(alloc, "{{\"entity_id\":\"{s}\",\"depth\":1,\"limit\":20,\"include_deprecated\":true}}", .{a.id});
    const include_deleted = handleRequest(&ctx, "POST", "/v1/graph/neighbors", include_deleted_body, "");
    try std.testing.expectEqualStrings("200 OK", include_deleted.status);
    try std.testing.expect(std.mem.indexOf(u8, include_deleted.body, "Graph B") != null);
}

test "api get source enforces server-side scope" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = try store.createSource(alloc, .{ .title = "Private transcript", .scope = "project:secret", .content = "sensitive" });
    const path = try std.fmt.allocPrint(alloc, "/v1/sources/{s}", .{source.id});
    var ctx = Context{ .allocator = alloc, .store = &store, .actor_scopes_json = "[\"public\"]" };
    const resp = handleRequest(&ctx, "GET", path, "", "");
    try std.testing.expectEqualStrings("404 Not Found", resp.status);
}

test "api create memory rejects unauthorized scope" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ctx = Context{ .allocator = alloc, .store = &store, .actor_scopes_json = "[\"project:allowed\"]" };
    const resp = handleRequest(&ctx, "POST", "/v1/memory-atoms", "{\"text\":\"Hidden context\",\"scope\":\"project:secret\",\"created_by\":\"agent\"}", "");
    try std.testing.expectEqualStrings("403 Forbidden", resp.status);
}

test "api write mutations require explicit write scope" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var read_scope_ctx = Context{
        .allocator = alloc,
        .store = &store,
        .actor_scopes_json = "[\"project:nullpantry\"]",
        .actor_capabilities_json = "[\"read\",\"write\",\"propose\"]",
    };
    const denied = handleRequest(&read_scope_ctx, "POST", "/v1/sources", "{\"title\":\"Spec\",\"scope\":\"project:nullpantry\",\"content\":\"body\"}", "");
    try std.testing.expectEqualStrings("403 Forbidden", denied.status);

    var write_scope_ctx = Context{
        .allocator = alloc,
        .store = &store,
        .actor_scopes_json = "[\"project:nullpantry\",\"write:project:nullpantry\"]",
        .actor_capabilities_json = "[\"read\",\"write\",\"propose\"]",
    };
    const allowed = handleRequest(&write_scope_ctx, "POST", "/v1/sources", "{\"title\":\"Spec\",\"scope\":\"project:nullpantry\",\"content\":\"body\"}", "");
    try std.testing.expectEqualStrings("200 OK", allowed.status);
}

test "api verified memory creation requires scoped verify right" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const body = "{\"text\":\"Verified decision\",\"scope\":\"project:nullpantry\",\"created_by\":\"human\",\"status\":\"verified\"}";
    var writer_only = Context{
        .allocator = alloc,
        .store = &store,
        .actor_scopes_json = "[\"project:nullpantry\",\"write:project:nullpantry\"]",
        .actor_capabilities_json = "[\"read\",\"write\",\"verify\"]",
    };
    const denied = handleRequest(&writer_only, "POST", "/v1/memory-atoms", body, "");
    try std.testing.expectEqualStrings("403 Forbidden", denied.status);

    var verifier = Context{
        .allocator = alloc,
        .store = &store,
        .actor_scopes_json = "[\"project:nullpantry\",\"write:project:nullpantry\",\"verify:project:nullpantry\"]",
        .actor_capabilities_json = "[\"read\",\"write\",\"verify\"]",
    };
    const allowed = handleRequest(&verifier, "POST", "/v1/memory-atoms", body, "");
    try std.testing.expectEqualStrings("200 OK", allowed.status);
}

test "ask citation validator ignores non-citation brackets but rejects inaccessible ids" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = Context{ .allocator = alloc, .store = &store };
    const results = [_]domain.SearchResult{
        .{ .id = "mem_known", .result_type = "memory_atom", .title = "Known", .text = "Known cited fact", .scope = "public", .status = "verified", .score = 1.0, .source_ids_json = "[\"src_known\"]" },
    };

    try std.testing.expect(try answerCitationsValid(&ctx, "This answer has [notes] and one citation [src_known].", &results));
    try std.testing.expect(!(try answerCitationsValid(&ctx, "This answer cites hidden data [src_secret].", &results)));
}

test "api status changes cannot target invisible memory" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const atom = try store.createMemoryAtom(alloc, .{ .text = "Secret context", .scope = "project:secret", .created_by = "human" });
    const body = try std.fmt.allocPrint(alloc, "{{\"id\":\"{s}\"}}", .{atom.id});
    var ctx = Context{ .allocator = alloc, .store = &store, .actor_scopes_json = "[\"project:allowed\"]" };
    const resp = handleRequest(&ctx, "POST", "/v1/mark-stale", body, "");
    try std.testing.expectEqualStrings("404 Not Found", resp.status);

    const unchanged = (try store.getMemoryAtom(alloc, atom.id)).?;
    try std.testing.expectEqualStrings("verified", unchanged.status);
}

test "api ingest creates source artifact extracted memory entities vectors and job" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = Context{ .allocator = alloc, .store = &store, .actor_scopes_json = "[\"project:nullpantry\"]" };

    const body =
        \\{"title":"Planning","type":"transcript","scope":"project:nullpantry","content":"Decision: NullPantry uses ingestion jobs\nConstraint: every atom has citations\nNullPantry depends on NullClaw\nRisk: stale memory"}
    ;
    const resp = handleRequest(&ctx, "POST", "/v1/ingest", body, "");
    try std.testing.expectEqualStrings("202 Accepted", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"queued\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"job\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"scope\":\"project:nullpantry\"") != null);

    const worker_resp = handleRequest(&ctx, "POST", "/v1/workers/run", "{\"job_limit\":5,\"outbox_limit\":5}", "");
    try std.testing.expectEqualStrings("200 OK", worker_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, worker_resp.body, "\"jobs_succeeded\":1") != null);

    const search_resp = handleRequest(&ctx, "POST", "/v1/search", "{\"query\":\"ingestion jobs\",\"scopes\":[\"project:nullpantry\"]}", "");
    try std.testing.expectEqualStrings("200 OK", search_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, search_resp.body, "NullPantry uses ingestion jobs") != null);
    try std.testing.expect(std.mem.indexOf(u8, search_resp.body, "\"type\":\"artifact\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, search_resp.body, "\"status\":\"draft\"") != null);

    const relation_resp = handleRequest(&ctx, "POST", "/v1/search", "{\"query\":\"depends_on\",\"scopes\":[\"project:nullpantry\"]}", "");
    try std.testing.expectEqualStrings("200 OK", relation_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, relation_resp.body, "\"type\":\"relation\"") != null);

    const jobs = handleRequest(&ctx, "GET", "/v1/jobs?status=succeeded", "", "");
    try std.testing.expectEqualStrings("200 OK", jobs.status);
    try std.testing.expect(std.mem.indexOf(u8, jobs.body, "\"type\":\"ingest\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, jobs.body, "\"relation_count\":1") != null);
}

test "api run_now llm extraction falls back to heuristic unless strict" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = Context{ .allocator = alloc, .store = &store, .actor_scopes_json = "[\"public\"]" };

    const fallback = handleRequest(&ctx, "POST", "/v1/ingest",
        \\{"title":"LLM fallback","type":"transcript","scope":"public","content":"Decision: API fallback uses heuristic extraction","run_now":true,"use_llm_extraction":true}
    , "");
    try std.testing.expectEqualStrings("200 OK", fallback.status);
    try std.testing.expect(std.mem.indexOf(u8, fallback.body, "\"extraction_provider\":\"heuristic\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fallback.body, "\"extraction_fallback\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, fallback.body, "\"predicate\":\"decision\"") != null);

    const strict = handleRequest(&ctx, "POST", "/v1/ingest",
        \\{"title":"LLM strict","type":"transcript","scope":"public","content":"Decision: strict extraction must fail without a provider","run_now":true,"use_llm_extraction":true,"strict_llm_extraction":true}
    , "");
    try std.testing.expectEqualStrings("500 Internal Server Error", strict.status);
}

test "api queued worker llm extraction preserves fallback and strict failure" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = Context{ .allocator = alloc, .store = &store, .actor_scopes_json = "[\"public\"]" };

    const queued = handleRequest(&ctx, "POST", "/v1/ingest",
        \\{"title":"Queued LLM fallback","type":"transcript","scope":"public","content":"Decision: queued worker fallback uses heuristic extraction","use_llm_extraction":true}
    , "");
    try std.testing.expectEqualStrings("202 Accepted", queued.status);
    const worker_ok = handleRequest(&ctx, "POST", "/v1/workers/run", "{\"job_limit\":5,\"outbox_limit\":5}", "");
    try std.testing.expectEqualStrings("200 OK", worker_ok.status);
    try std.testing.expect(std.mem.indexOf(u8, worker_ok.body, "\"jobs_succeeded\":1") != null);
    const succeeded_jobs = handleRequest(&ctx, "GET", "/v1/jobs?status=succeeded&limit=10", "", "");
    try std.testing.expectEqualStrings("200 OK", succeeded_jobs.status);
    try std.testing.expect(std.mem.indexOf(u8, succeeded_jobs.body, "\"extraction_provider\":\"heuristic\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, succeeded_jobs.body, "\"extraction_fallback\":true") != null);

    const strict = handleRequest(&ctx, "POST", "/v1/ingest",
        \\{"title":"Queued LLM strict","type":"transcript","scope":"public","content":"Decision: queued strict extraction fails without provider","use_llm_extraction":true,"strict_llm_extraction":true}
    , "");
    try std.testing.expectEqualStrings("202 Accepted", strict.status);
    const worker_fail = handleRequest(&ctx, "POST", "/v1/workers/run", "{\"job_limit\":5,\"outbox_limit\":5}", "");
    try std.testing.expectEqualStrings("200 OK", worker_fail.status);
    try std.testing.expect(std.mem.indexOf(u8, worker_fail.body, "\"jobs_failed\":1") != null);
    const failed_jobs = handleRequest(&ctx, "GET", "/v1/jobs?status=failed&limit=10", "", "");
    try std.testing.expectEqualStrings("200 OK", failed_jobs.status);
    try std.testing.expect(std.mem.indexOf(u8, failed_jobs.body, "ProviderUnavailable") != null);
}

test "api conflict scanner detects contradictory memory objects without leaking scopes" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    _ = try store.createMemoryAtom(alloc, .{ .predicate = "decision.database", .object = "sqlite", .text = "Decision: database sqlite", .scope = "project:nullpantry", .created_by = "human" });
    _ = try store.createMemoryAtom(alloc, .{ .predicate = "decision.database", .object = "postgres", .text = "Decision: database postgres", .scope = "project:nullpantry", .created_by = "human" });
    _ = try store.createMemoryAtom(alloc, .{ .predicate = "decision.database", .object = "secret", .text = "Decision: secret", .scope = "project:secret", .created_by = "human" });

    var ctx = Context{ .allocator = alloc, .store = &store, .actor_scopes_json = "[\"project:nullpantry\"]" };
    const scan = handleRequest(&ctx, "POST", "/v1/conflicts/scan", "{\"scopes\":[\"project:nullpantry\"],\"limit\":20}", "");
    try std.testing.expectEqualStrings("200 OK", scan.status);
    try std.testing.expect(std.mem.indexOf(u8, scan.body, "\"conflicts\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.body, "sqlite") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.body, "postgres") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.body, "secret") == null);

    const list = handleRequest(&ctx, "GET", "/v1/conflicts?limit=20", "", "");
    try std.testing.expectEqualStrings("200 OK", list.status);
    try std.testing.expect(std.mem.indexOf(u8, list.body, "memory_atom_conflict") != null);
}

test "api manifest and connector endpoints describe headless service contracts" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = Context{ .allocator = arena.allocator(), .store = &store };

    const caps = handleRequest(&ctx, "GET", "/v1/capabilities", "", "");
    try std.testing.expectEqualStrings("200 OK", caps.status);
    try std.testing.expect(std.mem.indexOf(u8, caps.body, "\"headless\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, caps.body, "knowledge_graph") != null);
    try std.testing.expect(std.mem.indexOf(u8, caps.body, "context_serving_api") != null);
    try std.testing.expect(std.mem.indexOf(u8, caps.body, "agent_memory") != null);
    try std.testing.expect(std.mem.indexOf(u8, caps.body, "agent_sessions") != null);
    try std.testing.expect(std.mem.indexOf(u8, caps.body, "get_context_pack") != null);
    try std.testing.expect(std.mem.indexOf(u8, caps.body, "legacy_adapters") == null);

    const connector_resp = handleRequest(&ctx, "GET", "/v1/connectors", "", "");
    try std.testing.expectEqualStrings("200 OK", connector_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, connector_resp.body, "\"name\":\"nullclaw\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, connector_resp.body, "\"name\":\"nullwatch\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, connector_resp.body, "\"built_in_push\"") != null);

    const connector_ingest = handleRequest(&ctx, "POST", "/v1/connectors/ticket/ingest",
        \\{"title":"NP-42 Transcript ingestion","content":"Decision: ticket connectors should create first-class sources","scope":"public","next_cursor":"ticket-42","config":{"project":"NP"}}
    , "");
    try std.testing.expectEqualStrings("200 OK", connector_ingest.status);
    try std.testing.expect(std.mem.indexOf(u8, connector_ingest.body, "\"count\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, connector_ingest.body, "\"type\":\"ticket\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, connector_ingest.body, "\"cursor\":\"ticket-42\"") != null);

    const cursor_get = handleRequest(&ctx, "GET", "/v1/connectors/ticket/cursor?scope=public", "", "");
    try std.testing.expectEqualStrings("200 OK", cursor_get.status);
    try std.testing.expect(std.mem.indexOf(u8, cursor_get.body, "\"connector\":\"ticket\"") != null);

    const cursor_post = handleRequest(&ctx, "POST", "/v1/connectors/nullwatch/cursor",
        \\{"scope":"public","cursor":"incident-9","config":{"stream":"incidents"}}
    , "");
    try std.testing.expectEqualStrings("200 OK", cursor_post.status);
    try std.testing.expect(std.mem.indexOf(u8, cursor_post.body, "\"incident-9\"") != null);

    const openapi = handleRequest(&ctx, "GET", "/v1/openapi.json", "", "");
    try std.testing.expectEqualStrings("200 OK", openapi.status);
    try std.testing.expect(std.mem.indexOf(u8, openapi.body, "ConnectorIngestRequest") != null);
    try std.testing.expect(std.mem.indexOf(u8, openapi.body, "connectorIngest") != null);
    try std.testing.expect(std.mem.indexOf(u8, openapi.body, "connectorUpsertCursor") != null);

    const manifest = handleRequest(&ctx, "GET", "/v1/sdk/manifest", "", "");
    try std.testing.expectEqualStrings("200 OK", manifest.status);
    try std.testing.expect(std.mem.indexOf(u8, manifest.body, "X-NullPantry-Actor-Scopes") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest.body, "POST /v1/remember") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest.body, "GET /v1/agent-sessions") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest.body, "POST /v1/vector/rebuild") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest.body, "POST /v1/vector/reconcile") != null);
}

test "api connector ingest only advances cursor after all items succeed" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = Context{ .allocator = arena.allocator(), .store = &store };

    const failed = handleRequest(&ctx, "POST", "/v1/connectors/ticket/ingest",
        \\{"scope":"public","next_cursor":"ticket-bad","items":[{"title":"ok","content":"ok"},1]}
    , "");
    try std.testing.expectEqualStrings("400 Bad Request", failed.status);

    const cursor_get = handleRequest(&ctx, "GET", "/v1/connectors/ticket/cursor?scope=public", "", "");
    try std.testing.expectEqualStrings("404 Not Found", cursor_get.status);

    const ok_ingest = handleRequest(&ctx, "POST", "/v1/connectors/ticket/ingest",
        \\{"scope":"public","next_cursor":"ticket-good","items":[{"title":"ok","content":"ok"}]}
    , "");
    try std.testing.expectEqualStrings("200 OK", ok_ingest.status);
    const ok_cursor = handleRequest(&ctx, "GET", "/v1/connectors/ticket/cursor?scope=public", "", "");
    try std.testing.expectEqualStrings("200 OK", ok_cursor.status);
    try std.testing.expect(std.mem.indexOf(u8, ok_cursor.body, "\"ticket-good\"") != null);
}

test "api spaces and policy scopes are first-class permission-filtered records" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var project_ctx = Context{ .allocator = alloc, .store = &store, .actor_scopes_json = "[\"project:nullpantry\",\"write:project:nullpantry\"]", .actor_capabilities_json = "[\"read\",\"write\"]" };
    var public_ctx = Context{ .allocator = alloc, .store = &store, .actor_scopes_json = "[\"public\"]", .actor_capabilities_json = "[\"read\"]" };

    const create_space_resp = handleRequest(&project_ctx, "POST", "/v1/spaces", "{\"name\":\"nullpantry\",\"title\":\"NullPantry\",\"scope\":\"project:nullpantry\",\"permissions\":[\"project:nullpantry\"],\"metadata\":{\"kind\":\"shelf\"}}", "");
    try std.testing.expectEqualStrings("200 OK", create_space_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, create_space_resp.body, "\"space\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, create_space_resp.body, "\"name\":\"nullpantry\"") != null);

    const hidden_spaces = handleRequest(&public_ctx, "GET", "/v1/spaces", "", "");
    try std.testing.expectEqualStrings("200 OK", hidden_spaces.status);
    try std.testing.expect(std.mem.indexOf(u8, hidden_spaces.body, "\"spaces\":[]") != null);

    const visible_spaces = handleRequest(&project_ctx, "GET", "/v1/spaces", "", "");
    try std.testing.expectEqualStrings("200 OK", visible_spaces.status);
    try std.testing.expect(std.mem.indexOf(u8, visible_spaces.body, "\"name\":\"nullpantry\"") != null);

    const policy_resp = handleRequest(&project_ctx, "POST", "/v1/policy-scopes", "{\"scope\":\"project:nullpantry\",\"visibility\":\"project\",\"permissions\":[\"project:nullpantry\"],\"owner\":\"agent:nullpantry\",\"ttl_ms\":86400000,\"review_after_ms\":604800000}", "");
    try std.testing.expectEqualStrings("200 OK", policy_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, policy_resp.body, "\"policy_scope\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, policy_resp.body, "\"ttl_ms\":86400000") != null);

    const hidden_policy = handleRequest(&public_ctx, "GET", "/v1/policy-scopes", "", "");
    try std.testing.expectEqualStrings("200 OK", hidden_policy.status);
    try std.testing.expect(std.mem.indexOf(u8, hidden_policy.body, "\"policy_scopes\":[]") != null);

    const search_resp = handleRequest(&project_ctx, "POST", "/v1/search", "{\"query\":\"nullpantry\",\"scopes\":[\"project:nullpantry\"],\"use_vector\":false}", "");
    try std.testing.expectEqualStrings("200 OK", search_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, search_resp.body, "\"spaces\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, search_resp.body, "\"policy_scopes\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, search_resp.body, "\"type\":\"space\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, search_resp.body, "\"type\":\"policy_scope\"") != null);
}
