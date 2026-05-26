const std = @import("std");
const Store = @import("store.zig").Store;
const store_mod = @import("store.zig");
const domain = @import("domain.zig");
const json = @import("json_util.zig");
const engines = @import("engines.zig");
const retrieval = @import("retrieval.zig");
const lifecycle = @import("lifecycle.zig");
const vector_mod = @import("vector.zig");
const ids = @import("ids.zig");
const extraction = @import("extraction.zig");
const providers = @import("providers.zig");
const worker = @import("worker.zig");
const artifacts = @import("artifacts.zig");

pub const Context = struct {
    allocator: std.mem.Allocator,
    store: *Store,
    required_token: ?[]const u8 = null,
    actor_id: []const u8 = "local",
    actor_scopes_json: []const u8 = "[\"admin\"]",
    actor_capabilities_json: []const u8 = "[\"read\",\"write\",\"propose\",\"verify\",\"delete\",\"export\",\"feed_apply\"]",
    embedding_base_url: ?[]const u8 = null,
    embedding_api_key: ?[]const u8 = null,
    embedding_model: ?[]const u8 = null,
    embedding_dimensions: usize = 64,
    llm_base_url: ?[]const u8 = null,
    llm_api_key: ?[]const u8 = null,
    llm_model: ?[]const u8 = null,
    provider_timeout_secs: u32 = 30,
};

pub const HttpResponse = json.HttpResponse;

pub fn handleRequest(ctx: *Context, method: []const u8, target: []const u8, body: []const u8, raw_request: []const u8) HttpResponse {
    const parsed = json.parsePath(target);
    const path = parsed.path;
    const seg0 = decodeSegment(ctx.allocator, json.segment(path, 0)) catch return serverError(ctx);
    const seg1 = decodeSegment(ctx.allocator, json.segment(path, 1)) catch return serverError(ctx);
    const seg2 = decodeSegment(ctx.allocator, json.segment(path, 2)) catch return serverError(ctx);
    const seg3 = decodeSegment(ctx.allocator, json.segment(path, 3)) catch return serverError(ctx);
    const seg4 = decodeSegment(ctx.allocator, json.segment(path, 4)) catch return serverError(ctx);

    const is_get = std.mem.eql(u8, method, "GET");
    const is_post = std.mem.eql(u8, method, "POST");
    const is_put = std.mem.eql(u8, method, "PUT");
    const is_patch = std.mem.eql(u8, method, "PATCH");

    const is_health = (is_get and eql(seg0, "health") and seg1 == null) or
        (is_get and eql(seg0, "v1") and eql(seg1, "nullclaw") and eql(seg2, "health"));
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

    if (eql(seg0, "v1") and eql(seg1, "nullclaw")) {
        return handleNullClaw(ctx, method, parsed.query, seg2, seg3, seg4, body);
    }

    if (!eql(seg0, "v1")) return json.errorResponse(ctx.allocator, 404, "not_found", "Not found");

    if (eql(seg1, "engines") and is_get) {
        return engineRegistry(ctx);
    } else if (eql(seg1, "capabilities") and is_get) {
        return capabilities(ctx);
    } else if (eql(seg1, "connectors") and is_get) {
        return connectors(ctx);
    } else if (eql(seg1, "artifact-types") and is_get) {
        return artifactTypes(ctx);
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
    } else if (eql(seg1, "sources")) {
        if (is_post and seg2 == null) return createSource(ctx, body);
        if (is_get and seg2 != null and seg3 == null) return getSource(ctx, seg2.?);
    } else if (eql(seg1, "artifacts")) {
        if (is_post and seg2 == null) return createArtifact(ctx, body);
        if (is_get and seg2 != null and seg3 == null) return getArtifact(ctx, seg2.?);
    } else if (eql(seg1, "memory-atoms")) {
        if (is_post and seg2 == null) return createMemoryAtom(ctx, body);
        if ((is_patch or is_put or is_post) and seg2 != null and seg3 == null) return patchMemoryAtom(ctx, seg2.?, body);
    } else if (eql(seg1, "entities") and eql(seg2, "resolve") and is_post) {
        return resolveEntity(ctx, body);
    } else if (eql(seg1, "relations") and is_post and seg2 == null) {
        return createRelation(ctx, body);
    } else if (eql(seg1, "search") and is_post) {
        return search(ctx, body);
    } else if (eql(seg1, "vector") and eql(seg2, "embed") and is_post) {
        return vectorEmbed(ctx, body);
    } else if (eql(seg1, "vector") and eql(seg2, "upsert") and is_post) {
        return vectorUpsert(ctx, body);
    } else if (eql(seg1, "vector") and eql(seg2, "search") and is_post) {
        return vectorSearch(ctx, body);
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
    } else if (eql(seg1, "memory") and eql(seg2, "feed") and is_get) {
        return memoryFeed(ctx, parsed.query);
    } else if (eql(seg1, "memory") and eql(seg2, "feed") and is_post) {
        return appendMemoryFeed(ctx, body);
    } else if (eql(seg1, "memory") and eql(seg2, "apply") and is_post) {
        return applyMemoryEvent(ctx, body);
    } else if (eql(seg1, "lifecycle") and eql(seg2, "diagnostics") and is_get) {
        return lifecycleDiagnostics(ctx);
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

fn handleNullClaw(ctx: *Context, method: []const u8, query: []const u8, seg2: ?[]u8, seg3: ?[]u8, seg4: ?[]u8, body: []const u8) HttpResponse {
    if (!domain.hasActorScope(ctx.actor_scopes_json, "admin") and !domain.hasActorScope(ctx.actor_scopes_json, "agent:nullclaw")) {
        return json.errorResponse(ctx.allocator, 403, "forbidden", "Missing agent:nullclaw scope");
    }

    const is_get = std.mem.eql(u8, method, "GET");
    const is_post = std.mem.eql(u8, method, "POST");
    const is_put = std.mem.eql(u8, method, "PUT");
    const is_delete = std.mem.eql(u8, method, "DELETE");

    if (eql(seg2, "memories") and eql(seg3, "search") and is_post) return compatSearch(ctx, body);
    if (eql(seg2, "memories") and eql(seg3, "count") and is_get) return compatCount(ctx);
    if (eql(seg2, "memories")) {
        if (is_put and seg3 != null) return compatStore(ctx, seg3.?, body);
        if (is_get and seg3 != null) return compatGet(ctx, seg3.?, query);
        if (is_delete and seg3 != null) return compatDelete(ctx, seg3.?, query);
        if (is_get and seg3 == null) return compatList(ctx, query);
    }

    if (eql(seg2, "sessions") and eql(seg3, "auto-saved") and is_delete) {
        const session_id = json.queryParamDecoded(ctx.allocator, query, "session_id") catch return serverError(ctx);
        ctx.store.clearAutoSaved(session_id) catch return serverError(ctx);
        return ok(ctx, "{\"ok\":true}");
    }
    if (eql(seg2, "sessions") and seg3 != null and eql(seg4, "messages")) {
        if (is_post) return saveMessage(ctx, seg3.?, body);
        if (is_get) return loadMessages(ctx, seg3.?);
        if (is_delete) {
            ctx.store.clearMessages(seg3.?) catch return serverError(ctx);
            return ok(ctx, "{\"ok\":true}");
        }
    }
    if (eql(seg2, "sessions") and seg3 != null and eql(seg4, "usage")) {
        if (is_put) return saveUsage(ctx, seg3.?, body);
        if (is_get) return loadUsage(ctx, seg3.?);
        if (is_delete) {
            _ = ctx.store.deleteUsage(seg3.?) catch return serverError(ctx);
            return ok(ctx, "{\"ok\":true}");
        }
    }
    if (eql(seg2, "history") and seg3 == null and is_get) {
        const limit = parseLimit(json.queryParam(query, "limit"), 50);
        const offset = parseLimit(json.queryParam(query, "offset"), 0);
        const result = ctx.store.listSessions(ctx.allocator, limit, offset) catch return serverError(ctx);
        return writeHistoryList(ctx, result, limit, offset);
    }
    if (eql(seg2, "history") and seg3 != null and is_get) {
        const limit = parseLimit(json.queryParam(query, "limit"), 100);
        const offset = parseLimit(json.queryParam(query, "offset"), 0);
        const result = ctx.store.history(ctx.allocator, seg3.?, limit, offset) catch return serverError(ctx);
        return writeHistoryShow(ctx, seg3.?, result, limit, offset);
    }

    return json.errorResponse(ctx.allocator, 404, "not_found", "Not found");
}

fn authorized(ctx: *Context, raw_request: []const u8) bool {
    const required = ctx.required_token orelse return true;
    if (required.len == 0) return true;
    const token = json.bearerToken(raw_request) orelse return false;
    return std.mem.eql(u8, token, required);
}

fn applyRequestPrincipal(ctx: *Context, raw_request: []const u8) !void {
    if (json.extractHeader(raw_request, "X-NullPantry-Actor-Id")) |actor_id| {
        ctx.actor_id = std.mem.trim(u8, actor_id, " \t\r\n");
    }

    if (json.extractHeader(raw_request, "X-NullPantry-Actor-Scopes")) |raw_scopes| {
        const scopes = std.mem.trim(u8, raw_scopes, " \t\r\n");
        ctx.actor_scopes_json = try domain.intersectJsonStringLists(ctx.allocator, scopes, ctx.actor_scopes_json);
    }

    if (json.extractHeader(raw_request, "X-NullPantry-Actor-Capabilities")) |raw_caps| {
        const caps = std.mem.trim(u8, raw_caps, " \t\r\n");
        ctx.actor_capabilities_json = try domain.intersectJsonStringLists(ctx.allocator, caps, ctx.actor_capabilities_json);
    }
}

fn health(ctx: *Context) HttpResponse {
    if (!ctx.store.health()) return json.errorResponse(ctx.allocator, 500, "unhealthy", "Storage backend is unavailable");
    return ok(ctx, "{\"ok\":true,\"service\":\"nullpantry\"}");
}

fn createSource(ctx: *Context, body: []const u8) HttpResponse {
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const title = json.stringField(obj, "title") orelse return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing title");
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
    };
    if (!canWriteRecord(ctx, input.scope, input.permissions_json)) return forbidden(ctx);
    const source = ctx.store.createSource(ctx.allocator, input) catch return serverError(ctx);
    return objectResponse(ctx, "source", source);
}

fn getSource(ctx: *Context, id: []const u8) HttpResponse {
    const source = ctx.store.getSource(ctx.allocator, id) catch return serverError(ctx);
    if (source == null) return json.errorResponse(ctx.allocator, 404, "not_found", "Source not found");
    if (!domain.recordVisible(source.?.scope, source.?.permissions_json, ctx.actor_scopes_json)) return json.errorResponse(ctx.allocator, 404, "not_found", "Source not found");
    return objectResponse(ctx, "source", source.?);
}

fn createArtifact(ctx: *Context, body: []const u8) HttpResponse {
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const title = json.stringField(obj, "title") orelse return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing title");
    const permissions_json = rawField(ctx.allocator, obj, "permissions", "[]") catch return serverError(ctx);
    if (!canWritePermissions(ctx, permissions_json)) return forbidden(ctx);
    const artifact_type = json.stringField(obj, "type") orelse "page";
    const status = json.stringField(obj, "status") orelse if (std.mem.eql(u8, artifact_type, "decision")) "proposed" else "draft";
    if (!artifacts.validStatus(artifact_type, status)) {
        return json.errorResponse(ctx.allocator, 400, "bad_request", "Invalid artifact status for this artifact type");
    }
    const artifact = ctx.store.createArtifact(ctx.allocator, .{
        .artifact_type = artifact_type,
        .title = title,
        .body = json.stringField(obj, "body") orelse "",
        .status = status,
        .owner = json.nullableStringField(obj, "owner"),
        .space_id = json.nullableStringField(obj, "space_id"),
        .source_ids_json = rawField(ctx.allocator, obj, "source_ids", "[]") catch return serverError(ctx),
        .related_entities_json = rawField(ctx.allocator, obj, "related_entities", "[]") catch return serverError(ctx),
        .permissions_json = permissions_json,
        .summary = json.nullableStringField(obj, "summary"),
        .agent_summary = json.nullableStringField(obj, "agent_summary"),
    }) catch return serverError(ctx);
    return objectResponse(ctx, "artifact", artifact);
}

fn getArtifact(ctx: *Context, id: []const u8) HttpResponse {
    const artifact = ctx.store.getArtifact(ctx.allocator, id) catch return serverError(ctx);
    if (artifact == null) return json.errorResponse(ctx.allocator, 404, "not_found", "Artifact not found");
    if (!domain.permissionsVisible(artifact.?.permissions_json, ctx.actor_scopes_json)) return json.errorResponse(ctx.allocator, 404, "not_found", "Artifact not found");
    return objectResponse(ctx, "artifact", artifact.?);
}

fn resolveEntity(ctx: *Context, body: []const u8) HttpResponse {
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const name = json.stringField(obj, "name") orelse return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing name");
    const entity = ctx.store.resolveEntity(ctx.allocator, .{
        .entity_type = json.stringField(obj, "type") orelse "concept",
        .name = name,
        .aliases_json = rawField(ctx.allocator, obj, "aliases", "[]") catch return serverError(ctx),
        .description = json.nullableStringField(obj, "description"),
        .canonical_artifact_id = json.nullableStringField(obj, "canonical_artifact_id"),
        .metadata_json = rawField(ctx.allocator, obj, "metadata", "{}") catch return serverError(ctx),
    }) catch return serverError(ctx);
    return objectResponse(ctx, "entity", entity);
}

fn createRelation(ctx: *Context, body: []const u8) HttpResponse {
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const from_entity_id = json.stringField(obj, "from_entity_id") orelse return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing from_entity_id");
    const to_entity_id = json.stringField(obj, "to_entity_id") orelse return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing to_entity_id");
    const relation = ctx.store.createRelation(ctx.allocator, .{
        .from_entity_id = from_entity_id,
        .relation_type = json.stringField(obj, "relation_type") orelse "related_to",
        .to_entity_id = to_entity_id,
        .source_ids_json = rawField(ctx.allocator, obj, "source_ids", "[]") catch return serverError(ctx),
        .confidence = json.floatField(obj, "confidence") orelse 0.5,
        .status = json.stringField(obj, "status") orelse "proposed",
    }) catch |err| switch (err) {
        error.EntityNotFound => return json.errorResponse(ctx.allocator, 400, "bad_request", "Relation endpoints must reference existing entities"),
        else => return serverError(ctx),
    };
    return objectResponse(ctx, "relation", relation);
}

fn engineRegistry(ctx: *Context) HttpResponse {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ctx.allocator, "{\"engines\":") catch return serverError(ctx);
    engines.appendDescriptorsJson(ctx.allocator, &out) catch return serverError(ctx);
    out.append(ctx.allocator, '}') catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn capabilities(ctx: *Context) HttpResponse {
    return ok(ctx,
        \\{"service":"nullpantry","headless":true,"storage":["sqlite","postgres-psql-runtime"],"apis":["remember","search","ask","get_context_pack","create_source","extract_memory","create_decision","link","forget","verify","mark_stale","ingest","jobs","workers","conflicts"],"providers":["local-deterministic","openai-compatible-embeddings","openai-compatible-chat"],"retrieval":["acl","fts","vector","entity_graph","rrf","temporal_decay","citations","conflict_warnings"],"compatibility":["nullclaw-api-memory","session-history","cross-memory-feed"],"permissions":["read","write","propose","verify","delete","export","feed_apply"]}
    );
}

fn connectors(ctx: *Context) HttpResponse {
    return ok(ctx,
        \\{"connectors":[{"name":"manual","status":"built_in","source_types":["manual","text"]},{"name":"transcript","status":"built_in","source_types":["transcript","chat"]},{"name":"ticket","status":"contract","source_types":["ticket","issue"]},{"name":"git","status":"contract","source_types":["pr","commit","repo"]},{"name":"incident","status":"contract","source_types":["incident"]},{"name":"nullclaw","status":"built_in","api":"/v1/nullclaw"},{"name":"nulltickets","status":"contract"},{"name":"nullwatch","status":"contract"},{"name":"nullhub","status":"consumer"}]}
    );
}

fn artifactTypes(ctx: *Context) HttpResponse {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ctx.allocator, "{\"artifact_types\":") catch return serverError(ctx);
    artifacts.appendTypesJson(ctx.allocator, &out) catch return serverError(ctx);
    out.append(ctx.allocator, '}') catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn sdkManifest(ctx: *Context) HttpResponse {
    return ok(ctx,
        \\{"name":"nullpantry","version":"v1","base_path":"/v1","methods":{"remember":"POST /v1/remember","search":"POST /v1/search","ask":"POST /v1/ask","get_context_pack":"POST /v1/context-packs","create_source":"POST /v1/sources","extract_memory":"POST /v1/extract-memory","create_decision":"POST /v1/artifacts type=decision","link":"POST /v1/relations","forget":"POST /v1/forget","verify":"POST /v1/verify","mark_stale":"POST /v1/mark-stale","ingest":"POST /v1/ingest","feed":"GET|POST /v1/memory/feed","apply":"POST /v1/memory/apply","worker_run":"POST /v1/workers/run","vector_outbox_run":"POST /v1/vector/outbox/run"},"headers":{"actor_id":"X-NullPantry-Actor-Id","actor_scopes":"X-NullPantry-Actor-Scopes","actor_capabilities":"X-NullPantry-Actor-Capabilities"}}
    );
}

const ExtractionOutput = struct {
    artifact: ?domain.Artifact = null,
    atoms: []domain.MemoryAtom,
    entities: []domain.Entity,
    vector_chunks: usize = 0,
};

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
    }) catch return serverError(ctx);
    const job = ctx.store.createJob(ctx.allocator, .{
        .job_type = "ingest",
        .scope = scope,
        .object_type = "source",
        .object_id = source.id,
        .input_json = body,
    }) catch return serverError(ctx);

    const output = runExtraction(ctx, source, json.boolField(obj, "create_artifact") orelse true, json.boolField(obj, "extract_memory") orelse true) catch return serverError(ctx);
    const result_json = std.fmt.allocPrint(ctx.allocator, "{{\"source_id\":\"{s}\",\"artifact_count\":{d},\"memory_atom_count\":{d},\"entity_count\":{d},\"vector_chunk_count\":{d}}}", .{ source.id, if (output.artifact == null) @as(usize, 0) else 1, output.atoms.len, output.entities.len, output.vector_chunks }) catch return serverError(ctx);
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
    if (!domain.recordVisible(source.scope, source.permissions_json, ctx.actor_scopes_json)) return json.errorResponse(ctx.allocator, 404, "not_found", "Source not found");
    if (!canProposeRecord(ctx, source.scope, source.permissions_json)) return forbidden(ctx);

    const job = ctx.store.createJob(ctx.allocator, .{
        .job_type = "extract_memory",
        .scope = source.scope,
        .object_type = "source",
        .object_id = source.id,
        .input_json = body,
    }) catch return serverError(ctx);
    const output = runExtraction(ctx, source, json.boolField(obj, "create_artifact") orelse true, true) catch return serverError(ctx);
    const result_json = std.fmt.allocPrint(ctx.allocator, "{{\"source_id\":\"{s}\",\"artifact_count\":{d},\"memory_atom_count\":{d},\"entity_count\":{d},\"vector_chunk_count\":{d}}}", .{ source.id, if (output.artifact == null) @as(usize, 0) else 1, output.atoms.len, output.entities.len, output.vector_chunks }) catch return serverError(ctx);
    _ = ctx.store.finishJob(job.id, "succeeded", result_json, null) catch return serverError(ctx);
    const finished = (ctx.store.getJob(ctx.allocator, job.id) catch return serverError(ctx)) orelse job;
    return extractionResponse(ctx, finished, source, output);
}

fn runExtraction(ctx: *Context, source: domain.Source, create_artifact: bool, extract_memory: bool) !ExtractionOutput {
    var vector_chunks: usize = 0;
    try upsertAutoVector(ctx, "source", source.id, source.content, source.scope, source.permissions_json);
    vector_chunks += 1;

    const source_ids_json = try extraction.sourceIdsJson(ctx.allocator, source.id);
    const entity_names_json = try extraction.extractEntityNamesJson(ctx.allocator, source.content);
    const entities = try resolveExtractedEntities(ctx, entity_names_json);

    var artifact: ?domain.Artifact = null;
    if (create_artifact) {
        const artifact_title = try extraction.sourceTitleForArtifact(ctx.allocator, source.title, source.source_type);
        const summary = try extraction.summarize(ctx.allocator, source.content, 512);
        const agent_summary = try extraction.summarize(ctx.allocator, source.content, 1024);
        artifact = try ctx.store.createArtifact(ctx.allocator, .{
            .artifact_type = extraction.artifactTypeForSource(source.source_type),
            .title = artifact_title,
            .body = source.content,
            .status = "verified",
            .owner = source.author,
            .source_ids_json = source_ids_json,
            .related_entities_json = entity_names_json,
            .permissions_json = source.permissions_json,
            .summary = summary,
            .agent_summary = agent_summary,
        });
        try upsertAutoVector(ctx, "artifact", artifact.?.id, source.content, source.scope, source.permissions_json);
        vector_chunks += 1;
    }

    var atoms: std.ArrayListUnmanaged(domain.MemoryAtom) = .empty;
    if (extract_memory) {
        var lines = std.mem.splitScalar(u8, source.content, '\n');
        while (lines.next()) |line| {
            const parsed = extraction.parseMemoryLine(line) orelse continue;
            const atom = try ctx.store.createMemoryAtom(ctx.allocator, .{
                .subject_entity_id = if (entities.len > 0) entities[0].id else null,
                .predicate = parsed.predicate,
                .object = parsed.object,
                .text = parsed.text,
                .scope = source.scope,
                .confidence = parsed.confidence,
                .source_ids_json = source_ids_json,
                .evidence_ranges_json = "[]",
                .created_by = "agent",
                .permissions_json = source.permissions_json,
                .tags_json = parsed.tags_json,
            });
            try atoms.append(ctx.allocator, atom);
            try upsertAutoVector(ctx, "memory_atom", atom.id, atom.text, atom.scope, atom.permissions_json);
            vector_chunks += 1;
        }
    }

    return .{ .artifact = artifact, .atoms = try atoms.toOwnedSlice(ctx.allocator), .entities = entities, .vector_chunks = vector_chunks };
}

fn resolveExtractedEntities(ctx: *Context, names_json: []const u8) ![]domain.Entity {
    const parsed = try std.json.parseFromSlice(std.json.Value, ctx.allocator, names_json, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return ctx.allocator.alloc(domain.Entity, 0);
    var out: std.ArrayListUnmanaged(domain.Entity) = .empty;
    for (parsed.value.array.items) |item| {
        const name = switch (item) {
            .string => |s| s,
            else => continue,
        };
        try out.append(ctx.allocator, try ctx.store.resolveEntity(ctx.allocator, .{ .entity_type = "project", .name = name }));
    }
    return out.toOwnedSlice(ctx.allocator);
}

fn upsertAutoVector(ctx: *Context, object_type: []const u8, object_id: []const u8, text: []const u8, scope: []const u8, permissions_json: []const u8) !void {
    const embedding_result = try providers.embedText(ctx.allocator, .{
        .base_url = ctx.embedding_base_url,
        .api_key = ctx.embedding_api_key,
        .model = ctx.embedding_model,
        .dimensions = ctx.embedding_dimensions,
        .timeout_secs = ctx.provider_timeout_secs,
    }, text, ctx.embedding_dimensions);
    const embedding_json = try vector_mod.embeddingToJson(ctx.allocator, embedding_result.embedding);
    _ = try ctx.store.upsertVectorChunk(ctx.allocator, .{
        .object_type = object_type,
        .object_id = object_id,
        .text = text,
        .scope = scope,
        .permissions_json = permissions_json,
        .embedding_json = embedding_json,
        .model = embedding_result.model,
        .dimensions = @intCast(embedding_result.embedding.len),
    });
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
    out.print(ctx.allocator, "],\"vector_chunk_count\":{d}}}", .{output.vector_chunks}) catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn createJob(ctx: *Context, body: []const u8) HttpResponse {
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const scope = json.stringField(obj, "scope") orelse "workspace";
    if (!canProposeRecord(ctx, scope, "[]")) return forbidden(ctx);
    const job = ctx.store.createJob(ctx.allocator, .{
        .job_type = json.stringField(obj, "type") orelse json.stringField(obj, "job_type") orelse return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing job type"),
        .scope = scope,
        .object_type = json.stringField(obj, "object_type") orelse "",
        .object_id = json.stringField(obj, "object_id") orelse "",
        .input_json = rawField(ctx.allocator, obj, "input", "{}") catch return serverError(ctx),
    }) catch return serverError(ctx);
    return objectResponse(ctx, "job", job);
}

fn listJobs(ctx: *Context, query: []const u8) HttpResponse {
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
    if (!domain.scopeVisible(job.scope, ctx.actor_scopes_json)) return json.errorResponse(ctx.allocator, 404, "not_found", "Job not found");
    if (!canProposeRecord(ctx, job.scope, "[]")) return forbidden(ctx);
    _ = ctx.store.finishJob(id, "succeeded", "{\"manual_run\":true}", null) catch return serverError(ctx);
    const finished = (ctx.store.getJob(ctx.allocator, id) catch return serverError(ctx)) orelse job;
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

fn listConflicts(ctx: *Context, query: []const u8) HttpResponse {
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
    const input = parseMemoryAtomInput(ctx, body) catch return badJson(ctx);
    if (!canCreateMemoryAtom(ctx, input)) return forbidden(ctx);
    const atom = ctx.store.createMemoryAtom(ctx.allocator, input) catch return serverError(ctx);
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
    const changed = ctx.store.patchMemoryAtomStatus(id, status, std.mem.eql(u8, status, "verified")) catch return serverError(ctx);
    if (!changed) return json.errorResponse(ctx.allocator, 404, "not_found", "Memory atom not found");
    const atom = ctx.store.getMemoryAtom(ctx.allocator, id) catch return serverError(ctx);
    return objectResponse(ctx, "memory_atom", atom.?);
}

fn statusAction(ctx: *Context, body: []const u8, status: []const u8, verified: bool, response_key: []const u8) HttpResponse {
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const id = json.stringField(parsed.value.object, "id") orelse json.stringField(parsed.value.object, "memory_atom_id") orelse return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing id");
    if (!canChangeMemoryStatus(ctx, id, status)) return json.errorResponse(ctx.allocator, 404, "not_found", "Memory atom not found");
    const changed = ctx.store.patchMemoryAtomStatus(id, status, verified) catch return serverError(ctx);
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
    };
}

fn search(ctx: *Context, body: []const u8) HttpResponse {
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const results = ctx.store.search(ctx.allocator, .{
        .query = json.stringField(obj, "query") orelse json.stringField(obj, "q") orelse "",
        .limit = positiveLimit(json.intField(obj, "limit"), 10),
        .scopes_json = effectiveScopes(ctx, obj) catch return serverError(ctx),
        .include_deprecated = json.boolField(obj, "include_deprecated") orelse false,
        .include_sessions = json.boolField(obj, "include_sessions") orelse false,
        .use_vector = json.boolField(obj, "use_vector") orelse true,
    }) catch return serverError(ctx);
    return searchResponse(ctx, results);
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
    }) catch return serverError(ctx);
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
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const text = json.stringField(obj, "text") orelse return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing text");
    const dimensions: usize = @intCast(@max(json.intField(obj, "dimensions") orelse 64, 1));
    const cfg = providers.EmbeddingConfig{
        .base_url = json.nullableStringField(obj, "base_url") orelse ctx.embedding_base_url,
        .api_key = json.nullableStringField(obj, "api_key") orelse ctx.embedding_api_key,
        .model = json.nullableStringField(obj, "model") orelse ctx.embedding_model,
        .dimensions = @min(dimensions, 4096),
        .timeout_secs = @intCast(@max(json.intField(obj, "timeout_secs") orelse ctx.provider_timeout_secs, 1)),
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

fn vectorSearch(ctx: *Context, body: []const u8) HttpResponse {
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const embedding_json = rawField(ctx.allocator, obj, "embedding", "[]") catch return serverError(ctx);
    const matches = ctx.store.vectorSearch(ctx.allocator, .{
        .embedding_json = embedding_json,
        .scopes_json = effectiveScopes(ctx, obj) catch return serverError(ctx),
        .limit = positiveLimit(json.intField(obj, "limit"), 10),
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

fn vectorOutboxStatus(ctx: *Context) HttpResponse {
    const pending = ctx.store.countVectorOutbox("pending") catch return serverError(ctx);
    const total = ctx.store.countVectorOutbox(null) catch return serverError(ctx);
    const body = std.fmt.allocPrint(ctx.allocator, "{{\"outbox\":{{\"pending\":{d},\"total\":{d}}}}}", .{ pending, total }) catch return serverError(ctx);
    return .{ .status = "200 OK", .body = body };
}

fn vectorOutboxRun(ctx: *Context, body: []const u8) HttpResponse {
    if (!hasCapability(ctx, "write")) return forbidden(ctx);
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const limit = positiveLimit(json.intField(parsed.value.object, "limit"), 100);
    const result = ctx.store.runVectorOutbox(limit) catch return serverError(ctx);
    const pending = ctx.store.countVectorOutbox("pending") catch return serverError(ctx);
    const response = std.fmt.allocPrint(ctx.allocator, "{{\"outbox_run\":{{\"processed\":{d},\"failed\":{d},\"pending\":{d}}}}}", .{ result.processed, result.failed, pending }) catch return serverError(ctx);
    return .{ .status = "200 OK", .body = response };
}

fn retrievalPlan(ctx: *Context, body: []const u8) HttpResponse {
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const query = json.stringField(obj, "query") orelse return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing query");
    const plan = retrieval.buildPlan(ctx.allocator, query, json.boolField(obj, "has_vector_index") orelse true, json.boolField(obj, "allow_reranker") orelse false) catch return serverError(ctx);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ctx.allocator, "{\"plan\":{\"use_keyword\":") catch return serverError(ctx);
    out.appendSlice(ctx.allocator, if (plan.use_keyword) "true" else "false") catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"use_vector\":") catch return serverError(ctx);
    out.appendSlice(ctx.allocator, if (plan.use_vector) "true" else "false") catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"use_graph\":") catch return serverError(ctx);
    out.appendSlice(ctx.allocator, if (plan.use_graph) "true" else "false") catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"use_reranker\":") catch return serverError(ctx);
    out.appendSlice(ctx.allocator, if (plan.use_reranker) "true" else "false") catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"expanded_query\":") catch return serverError(ctx);
    json.appendString(&out, ctx.allocator, plan.expanded_query) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, "}}") catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn retrievalSearch(ctx: *Context, body: []const u8) HttpResponse {
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const query = json.stringField(obj, "query") orelse json.stringField(obj, "q") orelse return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing query");
    const limit = positiveLimit(json.intField(obj, "limit"), 10);
    const scopes_json = effectiveScopes(ctx, obj) catch return serverError(ctx);
    const include_deprecated = json.boolField(obj, "include_deprecated") orelse false;
    const use_vector = json.boolField(obj, "use_vector") orelse true;
    const allow_reranker = json.boolField(obj, "allow_reranker") orelse true;
    const plan = retrieval.buildPlan(ctx.allocator, query, use_vector, allow_reranker) catch return serverError(ctx);
    const results = ctx.store.search(ctx.allocator, .{
        .query = query,
        .limit = limit,
        .scopes_json = scopes_json,
        .include_deprecated = include_deprecated,
        .include_sessions = json.boolField(obj, "include_sessions") orelse false,
        .use_vector = use_vector,
    }) catch return serverError(ctx);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ctx.allocator, "{\"plan\":{\"use_keyword\":") catch return serverError(ctx);
    out.appendSlice(ctx.allocator, if (plan.use_keyword) "true" else "false") catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"use_vector\":") catch return serverError(ctx);
    out.appendSlice(ctx.allocator, if (plan.use_vector) "true" else "false") catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"use_graph\":") catch return serverError(ctx);
    out.appendSlice(ctx.allocator, if (plan.use_graph) "true" else "false") catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"use_reranker\":") catch return serverError(ctx);
    out.appendSlice(ctx.allocator, if (plan.use_reranker) "true" else "false") catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"expanded_query\":") catch return serverError(ctx);
    json.appendString(&out, ctx.allocator, plan.expanded_query) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"stages\":[\"query_expansion\",\"keyword\",\"vector_ann\",\"rrf\",\"temporal_decay\"]},\"results\":") catch return serverError(ctx);
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
        .job_limit = positiveLimit(json.intField(parsed.value.object, "job_limit"), 25),
        .outbox_limit = positiveLimit(json.intField(parsed.value.object, "outbox_limit"), 100),
    }) catch return serverError(ctx);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.print(ctx.allocator, "{{\"worker_run\":{{\"jobs_checked\":{d},\"jobs_succeeded\":{d},\"jobs_failed\":{d},\"vector_outbox_processed\":{d},\"vector_outbox_failed\":{d}}}}}", .{ result.jobs_checked, result.jobs_succeeded, result.jobs_failed, result.vector_outbox_processed, result.vector_outbox_failed }) catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn memoryFeed(ctx: *Context, query: []const u8) HttpResponse {
    const since_id = if (json.queryParam(query, "since_id")) |raw| std.fmt.parseInt(i64, raw, 10) catch 0 else 0;
    const limit = parseLimit(json.queryParam(query, "limit"), 100);
    const events = ctx.store.listFeedEvents(ctx.allocator, .{ .since_id = since_id, .limit = limit, .scopes_json = ctx.actor_scopes_json }) catch return serverError(ctx);
    return feedEventsResponse(ctx, events);
}

fn appendMemoryFeed(ctx: *Context, body: []const u8) HttpResponse {
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const scope = json.stringField(obj, "scope") orelse "workspace";
    if (!canProposeRecord(ctx, scope, "[]")) return forbidden(ctx);
    const id = ctx.store.appendFeedEvent(.{
        .event_type = json.stringField(obj, "event_type") orelse return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing event_type"),
        .object_type = json.stringField(obj, "object_type") orelse "memory_atom",
        .object_id = json.stringField(obj, "object_id") orelse return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing object_id"),
        .scope = scope,
        .dedupe_key = json.nullableStringField(obj, "dedupe_key"),
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
    const scope = json.stringField(obj, "scope") orelse "workspace";
    if (!canWriteRecord(ctx, scope, "[]")) return forbidden(ctx);
    if (json.nullableStringField(obj, "dedupe_key")) |dedupe_key| {
        if (ctx.store.getFeedEventByDedupeKey(ctx.allocator, dedupe_key) catch return serverError(ctx)) |event| {
            if (!domain.scopeVisible(event.scope, ctx.actor_scopes_json)) return forbidden(ctx);
            if (!std.mem.eql(u8, event.status, "applied")) {
                return json.errorResponse(ctx.allocator, 409, "conflict", "Feed event with this dedupe key is queued but not applied");
            }
            return appliedFeedResponse(ctx, event.id, if (std.mem.eql(u8, event.object_type, "memory_atom")) event.object_id else null);
        }
    }
    const payload_json = rawField(ctx.allocator, obj, "payload", "{}") catch return serverError(ctx);
    var memory_atom_id: ?[]const u8 = null;
    if (std.mem.eql(u8, json.stringField(obj, "object_type") orelse "memory_atom", "memory_atom")) {
        const atom = parseAppliedMemoryAtom(ctx, payload_json, scope) catch |err| switch (err) {
            error.Forbidden => return forbidden(ctx),
            error.MissingText, error.InvalidPayload => return json.errorResponse(ctx.allocator, 400, "bad_request", "Memory apply payload must include text/content"),
            else => return serverError(ctx),
        };
        memory_atom_id = atom.id;
    }
    const id = ctx.store.appendFeedEvent(.{
        .event_type = json.stringField(obj, "event_type") orelse "memory_atom.upsert",
        .object_type = json.stringField(obj, "object_type") orelse "memory_atom",
        .object_id = memory_atom_id orelse (json.stringField(obj, "object_id") orelse "unknown"),
        .scope = scope,
        .dedupe_key = json.nullableStringField(obj, "dedupe_key"),
        .payload_json = payload_json,
        .status = "applied",
    }) catch return serverError(ctx);
    return appliedFeedResponse(ctx, id, memory_atom_id);
}

fn parseAppliedMemoryAtom(ctx: *Context, payload_json: []const u8, fallback_scope: []const u8) !domain.MemoryAtom {
    const payload = try std.json.parseFromSlice(std.json.Value, ctx.allocator, payload_json, .{});
    defer payload.deinit();
    if (payload.value != .object) return error.InvalidPayload;
    const obj = payload.value.object;
    const text = json.stringField(obj, "text") orelse json.stringField(obj, "content") orelse return error.MissingText;
    const atom_scope = json.stringField(obj, "scope") orelse fallback_scope;
    const permissions_json = rawField(ctx.allocator, obj, "permissions", "[]") catch return error.InvalidPayload;
    const input = store_mod.MemoryAtomInput{
        .text = text,
        .scope = atom_scope,
        .predicate = json.stringField(obj, "predicate") orelse "states",
        .object = json.stringField(obj, "object") orelse "",
        .confidence = json.floatField(obj, "confidence") orelse 0.7,
        .status = json.nullableStringField(obj, "status"),
        .source_ids_json = rawField(ctx.allocator, obj, "source_ids", "[]") catch "[]",
        .evidence_ranges_json = rawField(ctx.allocator, obj, "evidence_ranges", "[]") catch "[]",
        .created_by = json.stringField(obj, "created_by") orelse "agent",
        .permissions_json = permissions_json,
        .tags_json = rawField(ctx.allocator, obj, "tags", "[\"feed\"]") catch "[\"feed\"]",
    };
    if (!canCreateMemoryAtom(ctx, input)) return error.Forbidden;
    return try ctx.store.createMemoryAtom(ctx.allocator, input);
}

fn lifecycleDiagnostics(ctx: *Context) HttpResponse {
    const store_diag = ctx.store.lifecycleDiagnostics() catch return serverError(ctx);
    const diagnostics = lifecycle.Diagnostics{
        .total_memory_atoms = store_diag.total_memory_atoms,
        .stale_memory_atoms = store_diag.stale_memory_atoms,
        .vector_outbox_pending = store_diag.vector_outbox_pending,
        .cache_entries = store_diag.cache_entries,
    };
    const body = std.fmt.allocPrint(
        ctx.allocator,
        "{{\"diagnostics\":{{\"health\":\"{s}\",\"total_memory_atoms\":{d},\"stale_memory_atoms\":{d},\"vector_outbox_pending\":{d},\"cache_entries\":{d}}}}}",
        .{ diagnostics.health(), diagnostics.total_memory_atoms, diagnostics.stale_memory_atoms, diagnostics.vector_outbox_pending, diagnostics.cache_entries },
    ) catch return serverError(ctx);
    return .{ .status = "200 OK", .body = body };
}

fn lifecycleSnapshot(ctx: *Context, body: []const u8) HttpResponse {
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
        .ttl_ms = json.intField(obj, "ttl_ms") orelse 0,
    }) catch return serverError(ctx);
    return ok(ctx, "{\"ok\":true,\"cached\":true}");
}

fn responseCacheGet(ctx: *Context, body: []const u8) HttpResponse {
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const cache_key = json.stringField(obj, "key") orelse json.stringField(obj, "cache_key") orelse return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing cache key");
    const entry = ctx.store.getResponseCache(ctx.allocator, cache_key, ids.nowMs()) catch return serverError(ctx);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ctx.allocator, "{\"hit\":") catch return serverError(ctx);
    if (entry) |hit| {
        out.appendSlice(ctx.allocator, "true,\"cache_key\":") catch return serverError(ctx);
        json.appendString(&out, ctx.allocator, hit.cache_key) catch return serverError(ctx);
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
        .ttl_ms = json.intField(obj, "ttl_ms") orelse 0,
    }) catch return serverError(ctx);
    return ok(ctx, "{\"ok\":true,\"cached\":true}");
}

fn semanticCacheSearch(ctx: *Context, body: []const u8) HttpResponse {
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
        .min_score = @floatCast(json.floatField(obj, "min_score") orelse 0.82),
    }) catch return serverError(ctx);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ctx.allocator, "{\"hit\":") catch return serverError(ctx);
    if (match) |hit| {
        out.appendSlice(ctx.allocator, "true,\"cache_key\":") catch return serverError(ctx);
        json.appendString(&out, ctx.allocator, hit.cache_key) catch return serverError(ctx);
        out.appendSlice(ctx.allocator, ",\"query\":") catch return serverError(ctx);
        json.appendString(&out, ctx.allocator, hit.query) catch return serverError(ctx);
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
    }) catch return serverError(ctx);
    const response = std.fmt.allocPrint(
        ctx.allocator,
        "{{\"hygiene\":{{\"checked\":{d},\"marked_stale\":{d},\"archived\":{d},\"purged\":{d},\"expired_cache_entries\":{d}}}}}",
        .{ result.checked, result.marked_stale, result.archived, result.purged, result.expired_cache_entries },
    ) catch return serverError(ctx);
    return .{ .status = "200 OK", .body = response };
}

fn lifecycleSummarize(ctx: *Context, body: []const u8) HttpResponse {
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
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const query = json.stringField(obj, "query") orelse json.stringField(obj, "question") orelse "";
    const scopes_json = effectiveScopes(ctx, obj) catch return serverError(ctx);
    const results = ctx.store.search(ctx.allocator, .{
        .query = query,
        .limit = 6,
        .scopes_json = scopes_json,
    }) catch return serverError(ctx);
    const conflicts = if (json.boolField(obj, "include_conflicts") orelse true)
        (ctx.store.scanConflicts(ctx.allocator, .{ .scopes_json = scopes_json, .limit = 10 }) catch return serverError(ctx))
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
        const use_llm = json.boolField(obj, "use_llm") orelse (ctx.llm_base_url != null and ctx.llm_model != null);
        if (use_llm) {
            const prompt = buildAskPrompt(ctx, query, results) catch return serverError(ctx);
            if (providers.completeAnswer(ctx.allocator, .{
                .base_url = json.nullableStringField(obj, "llm_base_url") orelse ctx.llm_base_url,
                .api_key = json.nullableStringField(obj, "llm_api_key") orelse ctx.llm_api_key,
                .model = json.nullableStringField(obj, "llm_model") orelse ctx.llm_model,
                .timeout_secs = @intCast(@max(json.intField(obj, "timeout_secs") orelse ctx.provider_timeout_secs, 1)),
            }, prompt)) |completion| {
                answer_provider = completion.provider;
                answer.appendSlice(ctx.allocator, completion.content) catch return serverError(ctx);
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
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn writeExtractiveAnswer(ctx: *Context, out: *std.ArrayListUnmanaged(u8), results: []domain.SearchResult) !void {
    try out.appendSlice(ctx.allocator, "Based on accessible NullPantry evidence: ");
    for (results, 0..) |result, i| {
        if (i > 0) try out.appendSlice(ctx.allocator, " ");
        try out.appendSlice(ctx.allocator, result.text);
        try out.appendSlice(ctx.allocator, " [");
        try out.appendSlice(ctx.allocator, result.id);
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
        try out.appendSlice(ctx.allocator, result.id);
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
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const query = json.stringField(obj, "query") orelse json.stringField(obj, "task") orelse return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing query");
    const pack = ctx.store.createContextPack(ctx.allocator, .{
        .purpose = json.stringField(obj, "purpose") orelse "task",
        .target = json.stringField(obj, "target") orelse "agent",
        .query = query,
        .token_budget = json.intField(obj, "token_budget") orelse 12000,
        .scopes_json = effectiveScopes(ctx, obj) catch return serverError(ctx),
    }) catch return serverError(ctx);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ctx.allocator, "{\"context_pack\":{\"id\":") catch return serverError(ctx);
    json.appendString(&out, ctx.allocator, pack.id) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"purpose\":") catch return serverError(ctx);
    json.appendString(&out, ctx.allocator, pack.purpose) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"target\":") catch return serverError(ctx);
    json.appendString(&out, ctx.allocator, pack.target) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"query\":") catch return serverError(ctx);
    json.appendString(&out, ctx.allocator, pack.query) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"included_sources\":") catch return serverError(ctx);
    out.appendSlice(ctx.allocator, pack.included_sources_json) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"included_artifacts\":") catch return serverError(ctx);
    out.appendSlice(ctx.allocator, pack.included_artifacts_json) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"included_memory_atoms\":") catch return serverError(ctx);
    out.appendSlice(ctx.allocator, pack.included_memory_atoms_json) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"generated_summary\":") catch return serverError(ctx);
    json.appendString(&out, ctx.allocator, pack.generated_summary) catch return serverError(ctx);
    out.print(ctx.allocator, ",\"token_budget\":{d},\"created_at_ms\":{d}}}", .{ pack.token_budget, pack.created_at_ms }) catch return serverError(ctx);
    out.append(ctx.allocator, '}') catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn compatStore(ctx: *Context, key: []const u8, body: []const u8) HttpResponse {
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const content = json.stringField(obj, "content") orelse return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing content");
    ctx.store.compatStore(ctx.allocator, .{
        .key = key,
        .content = content,
        .category = json.stringField(obj, "category") orelse "core",
        .session_id = json.nullableStringField(obj, "session_id"),
    }) catch return serverError(ctx);
    return ok(ctx, "{\"ok\":true}");
}

fn compatGet(ctx: *Context, key: []const u8, query: []const u8) HttpResponse {
    const session_id = json.queryParamDecoded(ctx.allocator, query, "session_id") catch return serverError(ctx);
    const entry = ctx.store.compatGet(ctx.allocator, key, session_id) catch return serverError(ctx);
    if (entry == null) return json.errorResponse(ctx.allocator, 404, "not_found", "Memory entry not found");
    return compatEntryResponse(ctx, "entry", entry.?);
}

fn compatList(ctx: *Context, query: []const u8) HttpResponse {
    const category = json.queryParamDecoded(ctx.allocator, query, "category") catch return serverError(ctx);
    const session_id = json.queryParamDecoded(ctx.allocator, query, "session_id") catch return serverError(ctx);
    const entries = ctx.store.compatList(ctx.allocator, category, session_id) catch return serverError(ctx);
    return compatEntriesResponse(ctx, entries);
}

fn compatSearch(ctx: *Context, body: []const u8) HttpResponse {
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const query = json.stringField(obj, "query") orelse "";
    const entries = ctx.store.compatSearch(ctx.allocator, query, positiveLimit(json.intField(obj, "limit"), 5), json.nullableStringField(obj, "session_id")) catch return serverError(ctx);
    return compatEntriesResponse(ctx, entries);
}

fn compatDelete(ctx: *Context, key: []const u8, query: []const u8) HttpResponse {
    const session_id = json.queryParamDecoded(ctx.allocator, query, "session_id") catch return serverError(ctx);
    const deleted = ctx.store.compatDelete(key, session_id) catch return serverError(ctx);
    if (!deleted) return json.errorResponse(ctx.allocator, 404, "not_found", "Memory entry not found");
    return ok(ctx, "{\"ok\":true}");
}

fn compatCount(ctx: *Context) HttpResponse {
    const count = ctx.store.compatCount() catch return serverError(ctx);
    const body = std.fmt.allocPrint(ctx.allocator, "{{\"count\":{d}}}", .{count}) catch return serverError(ctx);
    return .{ .status = "200 OK", .body = body };
}

fn saveMessage(ctx: *Context, session_id: []const u8, body: []const u8) HttpResponse {
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const role = json.stringField(obj, "role") orelse return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing role");
    const content = json.stringField(obj, "content") orelse return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing content");
    ctx.store.saveMessage(session_id, role, content) catch return serverError(ctx);
    return ok(ctx, "{\"ok\":true}");
}

fn loadMessages(ctx: *Context, session_id: []const u8) HttpResponse {
    const messages = ctx.store.loadMessages(ctx.allocator, session_id) catch return serverError(ctx);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ctx.allocator, "{\"messages\":[") catch return serverError(ctx);
    for (messages, 0..) |msg, i| {
        if (i > 0) out.append(ctx.allocator, ',') catch return serverError(ctx);
        appendMessage(ctx, &out, msg, false) catch return serverError(ctx);
    }
    out.appendSlice(ctx.allocator, "]}") catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn saveUsage(ctx: *Context, session_id: []const u8, body: []const u8) HttpResponse {
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const total = json.intField(parsed.value.object, "total_tokens") orelse 0;
    ctx.store.saveUsage(session_id, @intCast(@max(total, 0))) catch return serverError(ctx);
    return ok(ctx, "{\"ok\":true}");
}

fn loadUsage(ctx: *Context, session_id: []const u8) HttpResponse {
    const total_opt = ctx.store.loadUsage(session_id) catch return serverError(ctx);
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
        "source",
        "artifact",
        "entity",
        "relation",
        "context_pack",
        "feed_event",
        "compat_memory",
        "session_message",
    };
    const names = [_][]const u8{
        "memory_atoms",
        "sources",
        "artifacts",
        "entities",
        "relations",
        "context_packs",
        "feed_events",
        "compat_memories",
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

fn compatEntryResponse(ctx: *Context, name: []const u8, entry: domain.CompatMemory) HttpResponse {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.append(ctx.allocator, '{') catch return serverError(ctx);
    json.appendString(&out, ctx.allocator, name) catch return serverError(ctx);
    out.append(ctx.allocator, ':') catch return serverError(ctx);
    entry.writeJson(ctx.allocator, &out) catch return serverError(ctx);
    out.append(ctx.allocator, '}') catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn compatEntriesResponse(ctx: *Context, entries: []domain.CompatMemory) HttpResponse {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ctx.allocator, "{\"entries\":[") catch return serverError(ctx);
    for (entries, 0..) |entry, i| {
        if (i > 0) out.append(ctx.allocator, ',') catch return serverError(ctx);
        entry.writeJson(ctx.allocator, &out) catch return serverError(ctx);
    }
    out.appendSlice(ctx.allocator, "]}") catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn feedEventsResponse(ctx: *Context, events: []store_mod.FeedEvent) HttpResponse {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ctx.allocator, "{\"events\":[") catch return serverError(ctx);
    for (events, 0..) |event, i| {
        if (i > 0) out.append(ctx.allocator, ',') catch return serverError(ctx);
        event.writeJson(ctx.allocator, &out) catch return serverError(ctx);
    }
    out.appendSlice(ctx.allocator, "]}") catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn appliedFeedResponse(ctx: *Context, event_id: i64, memory_atom_id: ?[]const u8) HttpResponse {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.print(ctx.allocator, "{{\"event_id\":{d},\"applied\":true,\"memory_atom_id\":", .{event_id}) catch return serverError(ctx);
    json.appendNullableString(&out, ctx.allocator, memory_atom_id) catch return serverError(ctx);
    out.append(ctx.allocator, '}') catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
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

fn dupOptional(allocator: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    return if (value) |v| try allocator.dupe(u8, v) else null;
}

fn effectiveScopes(ctx: *Context, obj: std.json.ObjectMap) ![]const u8 {
    const requested = try rawField(ctx.allocator, obj, "scopes", "[]");
    if (!std.mem.eql(u8, requested, "[]")) return try domain.intersectJsonStringLists(ctx.allocator, requested, ctx.actor_scopes_json);
    return ctx.actor_scopes_json;
}

fn hasCapability(ctx: *Context, capability: []const u8) bool {
    return domain.hasCapability(ctx.actor_scopes_json, ctx.actor_capabilities_json, capability);
}

fn canWritePermissions(ctx: *Context, permissions_json: []const u8) bool {
    return hasCapability(ctx, "write") and domain.permissionsWritable(permissions_json, ctx.actor_scopes_json);
}

fn canWriteRecord(ctx: *Context, scope: []const u8, permissions_json: []const u8) bool {
    return canWritePermissions(ctx, permissions_json) and domain.scopeWritable(scope, ctx.actor_scopes_json);
}

fn canProposeRecord(ctx: *Context, scope: []const u8, permissions_json: []const u8) bool {
    return (hasCapability(ctx, "propose") or hasCapability(ctx, "write")) and
        domain.scopeWritable(scope, ctx.actor_scopes_json) and
        domain.permissionsWritable(permissions_json, ctx.actor_scopes_json);
}

fn canCreateMemoryAtom(ctx: *Context, input: store_mod.MemoryAtomInput) bool {
    const status = input.status orelse domain.defaultMemoryStatus(input.created_by, input.scope);
    if (std.mem.eql(u8, status, "verified") and !hasCapability(ctx, "verify")) return false;
    if (std.mem.eql(u8, status, "proposed")) return canProposeRecord(ctx, input.scope, input.permissions_json);
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
    if (!domain.recordVisible(existing.scope, existing.permissions_json, ctx.actor_scopes_json)) return false;
    if (std.mem.eql(u8, status, "verified")) return hasCapability(ctx, "verify") and domain.permissionsWritable(existing.permissions_json, ctx.actor_scopes_json);
    if (std.mem.eql(u8, status, "deprecated") or std.mem.eql(u8, status, "rejected")) return hasCapability(ctx, "delete") and domain.permissionsWritable(existing.permissions_json, ctx.actor_scopes_json);
    if (std.mem.eql(u8, status, "stale") or std.mem.eql(u8, status, "superseded")) return hasCapability(ctx, "verify") and domain.permissionsWritable(existing.permissions_json, ctx.actor_scopes_json);
    return memoryAtomWritable(ctx, id);
}

fn canApplyFeed(ctx: *Context) bool {
    return hasCapability(ctx, "feed_apply") or hasCapability(ctx, "write");
}

const VectorAcl = struct {
    scope: []const u8,
    permissions_json: []const u8,
};

fn resolveVectorAcl(ctx: *Context, object_type: []const u8, object_id: []const u8, requested_scope: []const u8, requested_permissions: []const u8) !VectorAcl {
    if (std.mem.eql(u8, object_type, "memory_atom")) {
        const atom = (try ctx.store.getMemoryAtom(ctx.allocator, object_id)) orelse return error.NotFound;
        if (!canWriteRecord(ctx, atom.scope, atom.permissions_json)) return error.Forbidden;
        return .{ .scope = atom.scope, .permissions_json = atom.permissions_json };
    }
    if (std.mem.eql(u8, object_type, "source")) {
        const source = (try ctx.store.getSource(ctx.allocator, object_id)) orelse return error.NotFound;
        if (!canWriteRecord(ctx, source.scope, source.permissions_json)) return error.Forbidden;
        return .{ .scope = source.scope, .permissions_json = source.permissions_json };
    }
    if (std.mem.eql(u8, object_type, "artifact")) {
        const artifact = (try ctx.store.getArtifact(ctx.allocator, object_id)) orelse return error.NotFound;
        if (!canWritePermissions(ctx, artifact.permissions_json)) return error.Forbidden;
        return .{ .scope = requested_scope, .permissions_json = artifact.permissions_json };
    }
    if (!canWriteRecord(ctx, requested_scope, requested_permissions)) return error.Forbidden;
    return .{ .scope = requested_scope, .permissions_json = requested_permissions };
}

fn positiveLimit(value: ?i64, default_value: usize) usize {
    const raw = value orelse return default_value;
    if (raw <= 0) return default_value;
    return @intCast(@min(raw, 100));
}

fn parseLimit(value: ?[]const u8, default_value: usize) usize {
    const raw = value orelse return default_value;
    const parsed = std.fmt.parseInt(usize, raw, 10) catch return default_value;
    return @min(parsed, 500);
}

fn ok(ctx: *Context, body: []const u8) HttpResponse {
    return .{ .status = "200 OK", .body = ctx.allocator.dupe(u8, body) catch body };
}

fn serverError(ctx: *Context) HttpResponse {
    return json.errorResponse(ctx.allocator, 500, "internal_error", "Internal server error");
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

    const missing = handleRequest(&ctx, "POST", "/v1/search", "{\"query\":\"x\"}", "");
    try std.testing.expectEqualStrings("401 Unauthorized", missing.status);

    const authed = handleRequest(&ctx, "POST", "/v1/search", "{\"query\":\"x\"}", "POST /v1/search HTTP/1.1\r\nAuthorization: Bearer secret\r\n\r\n{\"query\":\"x\"}");
    try std.testing.expectEqualStrings("200 OK", authed.status);
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
}

test "api nullclaw compatibility protocol" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = Context{ .allocator = arena.allocator(), .store = &store };
    const put = handleRequest(&ctx, "PUT", "/v1/nullclaw/memories/pref.lang", "{\"content\":\"Zig\",\"category\":\"core\",\"session_id\":null}", "");
    try std.testing.expectEqualStrings("200 OK", put.status);
    const get = handleRequest(&ctx, "GET", "/v1/nullclaw/memories/pref.lang", "", "");
    try std.testing.expectEqualStrings("200 OK", get.status);
    try std.testing.expect(std.mem.indexOf(u8, get.body, "\"entry\"") != null);

    const put_session = handleRequest(&ctx, "PUT", "/v1/nullclaw/memories/session.pref", "{\"content\":\"Session memory\",\"category\":\"core\",\"session_id\":\"sess_1\"}", "");
    try std.testing.expectEqualStrings("200 OK", put_session.status);
    const get_session_without_filter = handleRequest(&ctx, "GET", "/v1/nullclaw/memories/session.pref", "", "");
    try std.testing.expectEqualStrings("404 Not Found", get_session_without_filter.status);

    const get_session_encoded = handleRequest(&ctx, "GET", "/v1/nullclaw/memories/session.pref?session_id=sess_1", "", "");
    try std.testing.expectEqualStrings("200 OK", get_session_encoded.status);

    const put_colon_session = handleRequest(&ctx, "PUT", "/v1/nullclaw/memories/colon.pref", "{\"content\":\"Colon session memory\",\"category\":\"core\",\"session_id\":\"agent:coder\"}", "");
    try std.testing.expectEqualStrings("200 OK", put_colon_session.status);
    const get_colon_session = handleRequest(&ctx, "GET", "/v1/nullclaw/memories/colon.pref?session_id=agent%3Acoder", "", "");
    try std.testing.expectEqualStrings("200 OK", get_colon_session.status);
}

test "api nullclaw current ApiMemory contract shapes" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = Context{ .allocator = arena.allocator(), .store = &store };

    const health_resp = handleRequest(&ctx, "GET", "/v1/nullclaw/health", "", "");
    try std.testing.expectEqualStrings("200 OK", health_resp.status);

    const put_global = handleRequest(&ctx, "PUT", "/v1/nullclaw/memories/key%20with%20spaces", "{\"content\":\"Global remote memory\",\"category\":\"custom.cat\",\"session_id\":null}", "");
    try std.testing.expectEqualStrings("200 OK", put_global.status);
    const put_scoped = handleRequest(&ctx, "PUT", "/v1/nullclaw/memories/key%20with%20spaces", "{\"content\":\"Scoped remote memory\",\"category\":\"custom.cat\",\"session_id\":\"sess id=1\"}", "");
    try std.testing.expectEqualStrings("200 OK", put_scoped.status);

    const get_global = handleRequest(&ctx, "GET", "/v1/nullclaw/memories/key%20with%20spaces", "", "");
    try std.testing.expectEqualStrings("200 OK", get_global.status);
    try std.testing.expect(std.mem.indexOf(u8, get_global.body, "\"entry\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, get_global.body, "\"key\":\"key with spaces\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, get_global.body, "\"content\":\"Global remote memory\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, get_global.body, "\"category\":\"custom.cat\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, get_global.body, "\"session_id\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, get_global.body, "\"timestamp\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, get_global.body, "\"score\":") != null);

    const get_scoped = handleRequest(&ctx, "GET", "/v1/nullclaw/memories/key%20with%20spaces?session_id=sess%20id%3D1", "", "");
    try std.testing.expectEqualStrings("200 OK", get_scoped.status);
    try std.testing.expect(std.mem.indexOf(u8, get_scoped.body, "\"content\":\"Scoped remote memory\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, get_scoped.body, "\"session_id\":\"sess id=1\"") != null);

    const list_scoped = handleRequest(&ctx, "GET", "/v1/nullclaw/memories?category=custom.cat&session_id=sess%20id%3D1", "", "");
    try std.testing.expectEqualStrings("200 OK", list_scoped.status);
    try std.testing.expect(std.mem.indexOf(u8, list_scoped.body, "\"entries\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, list_scoped.body, "\"content\":\"Scoped remote memory\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, list_scoped.body, "\"content\":\"Global remote memory\"") == null);

    const search_scoped = handleRequest(&ctx, "POST", "/v1/nullclaw/memories/search", "{\"query\":\"Scoped remote\",\"limit\":10,\"session_id\":\"sess id=1\"}", "");
    try std.testing.expectEqualStrings("200 OK", search_scoped.status);
    try std.testing.expect(std.mem.indexOf(u8, search_scoped.body, "\"entries\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, search_scoped.body, "\"content\":\"Scoped remote memory\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, search_scoped.body, "\"content\":\"Global remote memory\"") == null);

    const count = handleRequest(&ctx, "GET", "/v1/nullclaw/memories/count", "", "");
    try std.testing.expectEqualStrings("200 OK", count.status);
    try std.testing.expect(std.mem.indexOf(u8, count.body, "\"count\":2") != null);

    const delete_scoped = handleRequest(&ctx, "DELETE", "/v1/nullclaw/memories/key%20with%20spaces?session_id=sess%20id%3D1", "", "");
    try std.testing.expectEqualStrings("200 OK", delete_scoped.status);
    const missing_scoped = handleRequest(&ctx, "GET", "/v1/nullclaw/memories/key%20with%20spaces?session_id=sess%20id%3D1", "", "");
    try std.testing.expectEqualStrings("404 Not Found", missing_scoped.status);
    const still_global = handleRequest(&ctx, "GET", "/v1/nullclaw/memories/key%20with%20spaces", "", "");
    try std.testing.expectEqualStrings("200 OK", still_global.status);

    const delete_global = handleRequest(&ctx, "DELETE", "/v1/nullclaw/memories/key%20with%20spaces", "", "");
    try std.testing.expectEqualStrings("200 OK", delete_global.status);
    const missing_global = handleRequest(&ctx, "GET", "/v1/nullclaw/memories/key%20with%20spaces", "", "");
    try std.testing.expectEqualStrings("404 Not Found", missing_global.status);
}

test "api nullclaw compatibility requires agent scope" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = Context{ .allocator = arena.allocator(), .store = &store, .actor_scopes_json = "[\"project:nullpantry\"]" };

    const resp = handleRequest(&ctx, "GET", "/v1/nullclaw/memories/count", "", "");
    try std.testing.expectEqualStrings("403 Forbidden", resp.status);
}

test "api nullclaw session history protocol shapes" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = Context{ .allocator = arena.allocator(), .store = &store };

    const save_user = handleRequest(&ctx, "POST", "/v1/nullclaw/sessions/agent%3Acoder/messages", "{\"role\":\"user\",\"content\":\"hello\"}", "");
    try std.testing.expectEqualStrings("200 OK", save_user.status);
    const save_autosave = handleRequest(&ctx, "POST", "/v1/nullclaw/sessions/agent%3Acoder/messages", "{\"role\":\"autosave_user\",\"content\":\"draft\"}", "");
    try std.testing.expectEqualStrings("200 OK", save_autosave.status);
    const save_assistant = handleRequest(&ctx, "POST", "/v1/nullclaw/sessions/agent%3Acoder/messages", "{\"role\":\"assistant\",\"content\":\"world\"}", "");
    try std.testing.expectEqualStrings("200 OK", save_assistant.status);

    const messages = handleRequest(&ctx, "GET", "/v1/nullclaw/sessions/agent%3Acoder/messages", "", "");
    try std.testing.expectEqualStrings("200 OK", messages.status);
    try std.testing.expect(std.mem.indexOf(u8, messages.body, "\"messages\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, messages.body, "\"role\":\"user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, messages.body, "\"content\":\"hello\"") != null);

    const usage_put = handleRequest(&ctx, "PUT", "/v1/nullclaw/sessions/agent%3Acoder/usage", "{\"total_tokens\":321}", "");
    try std.testing.expectEqualStrings("200 OK", usage_put.status);
    const usage_get = handleRequest(&ctx, "GET", "/v1/nullclaw/sessions/agent%3Acoder/usage", "", "");
    try std.testing.expectEqualStrings("200 OK", usage_get.status);
    try std.testing.expect(std.mem.indexOf(u8, usage_get.body, "\"total_tokens\":321") != null);
    const usage_delete = handleRequest(&ctx, "DELETE", "/v1/nullclaw/sessions/agent%3Acoder/usage", "", "");
    try std.testing.expectEqualStrings("200 OK", usage_delete.status);
    const missing_deleted_usage = handleRequest(&ctx, "GET", "/v1/nullclaw/sessions/agent%3Acoder/usage", "", "");
    try std.testing.expectEqualStrings("404 Not Found", missing_deleted_usage.status);
    const usage_put_again = handleRequest(&ctx, "PUT", "/v1/nullclaw/sessions/agent%3Acoder/usage", "{\"total_tokens\":321}", "");
    try std.testing.expectEqualStrings("200 OK", usage_put_again.status);

    const history = handleRequest(&ctx, "GET", "/v1/nullclaw/history?limit=10&offset=0", "", "");
    try std.testing.expectEqualStrings("200 OK", history.status);
    try std.testing.expect(std.mem.indexOf(u8, history.body, "\"total\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, history.body, "\"session_id\":\"agent:coder\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, history.body, "\"message_count\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, history.body, "\"first_message_at\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, history.body, "\"last_message_at\":\"") != null);

    const detail = handleRequest(&ctx, "GET", "/v1/nullclaw/history/agent%3Acoder?limit=10&offset=0", "", "");
    try std.testing.expectEqualStrings("200 OK", detail.status);
    try std.testing.expect(std.mem.indexOf(u8, detail.body, "\"session_id\":\"agent:coder\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail.body, "\"created_at\":\"") != null);

    const clear_autosave = handleRequest(&ctx, "DELETE", "/v1/nullclaw/sessions/auto-saved?session_id=agent%3Acoder", "", "");
    try std.testing.expectEqualStrings("200 OK", clear_autosave.status);
    const after_autosave_clear = handleRequest(&ctx, "GET", "/v1/nullclaw/sessions/agent%3Acoder/messages", "", "");
    try std.testing.expectEqualStrings("200 OK", after_autosave_clear.status);
    try std.testing.expect(std.mem.indexOf(u8, after_autosave_clear.body, "draft") == null);
    try std.testing.expect(std.mem.indexOf(u8, after_autosave_clear.body, "hello") != null);

    const clear_messages = handleRequest(&ctx, "DELETE", "/v1/nullclaw/sessions/agent%3Acoder/messages", "", "");
    try std.testing.expectEqualStrings("200 OK", clear_messages.status);
    const empty_messages = handleRequest(&ctx, "GET", "/v1/nullclaw/sessions/agent%3Acoder/messages", "", "");
    try std.testing.expectEqualStrings("200 OK", empty_messages.status);
    try std.testing.expect(std.mem.indexOf(u8, empty_messages.body, "\"messages\":[]") != null);

    const missing_usage = handleRequest(&ctx, "GET", "/v1/nullclaw/sessions/agent%3Acoder/usage", "", "");
    try std.testing.expectEqualStrings("404 Not Found", missing_usage.status);
}

test "api exposes engine registry retrieval plan vector and lifecycle endpoints" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = Context{ .allocator = arena.allocator(), .store = &store };

    const engines_resp = handleRequest(&ctx, "GET", "/v1/engines", "", "");
    try std.testing.expectEqualStrings("200 OK", engines_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, engines_resp.body, "\"name\":\"lancedb\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, engines_resp.body, "\"name\":\"kg\"") != null);

    const artifact_types = handleRequest(&ctx, "GET", "/v1/artifact-types", "", "");
    try std.testing.expectEqualStrings("200 OK", artifact_types.status);
    try std.testing.expect(std.mem.indexOf(u8, artifact_types.body, "\"type\":\"decision\"") != null);
    const invalid_decision = handleRequest(&ctx, "POST", "/v1/artifacts", "{\"type\":\"decision\",\"title\":\"ADR\",\"status\":\"verified\",\"body\":\"x\"}", "");
    try std.testing.expectEqualStrings("400 Bad Request", invalid_decision.status);

    const plan_resp = handleRequest(&ctx, "POST", "/v1/retrieval/plan", "{\"query\":\"NullPantry decision\",\"allow_reranker\":true}", "");
    try std.testing.expectEqualStrings("200 OK", plan_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, plan_resp.body, "\"use_vector\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan_resp.body, "\"use_graph\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan_resp.body, "\"use_reranker\":true") != null);

    const embed_resp = handleRequest(&ctx, "POST", "/v1/vector/embed", "{\"text\":\"agent memory\",\"dimensions\":4}", "");
    try std.testing.expectEqualStrings("200 OK", embed_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, embed_resp.body, "\"provider\":\"local-deterministic\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, embed_resp.body, "\"dimensions\":4") != null);

    const atom_resp = handleRequest(&ctx, "POST", "/v1/memory-atoms", "{\"text\":\"agent memory\",\"scope\":\"public\",\"created_by\":\"agent\"}", "");
    try std.testing.expectEqualStrings("200 OK", atom_resp.status);
    const created_atom_id = try extractJsonString(arena.allocator(), atom_resp.body, "\"id\":\"");
    const vector_body = try std.fmt.allocPrint(arena.allocator(), "{{\"object_id\":\"{s}\",\"text\":\"agent memory\",\"scope\":\"public\",\"embedding\":[1,0],\"dimensions\":2}}", .{created_atom_id});
    const upsert_resp = handleRequest(&ctx, "POST", "/v1/vector/upsert", vector_body, "");
    try std.testing.expectEqualStrings("200 OK", upsert_resp.status);
    const vector_resp = handleRequest(&ctx, "POST", "/v1/vector/search", "{\"embedding\":[1,0],\"scopes\":[\"public\"],\"limit\":5}", "");
    try std.testing.expectEqualStrings("200 OK", vector_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, vector_resp.body, "vec_mem_") != null);
    const outbox_resp = handleRequest(&ctx, "GET", "/v1/vector/outbox", "", "");
    try std.testing.expectEqualStrings("200 OK", outbox_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, outbox_resp.body, "\"pending\":1") != null);
    const outbox_run = handleRequest(&ctx, "POST", "/v1/vector/outbox/run", "{\"limit\":10}", "");
    try std.testing.expectEqualStrings("200 OK", outbox_run.status);
    try std.testing.expect(std.mem.indexOf(u8, outbox_run.body, "\"processed\":1") != null);

    const diagnostics = handleRequest(&ctx, "GET", "/v1/lifecycle/diagnostics", "", "");
    try std.testing.expectEqualStrings("200 OK", diagnostics.status);
    try std.testing.expect(std.mem.indexOf(u8, diagnostics.body, "\"health\":\"ok\"") != null);
    const snapshot = handleRequest(&ctx, "POST", "/v1/lifecycle/snapshot", "{\"type\":\"manual\",\"summary\":{\"memory_atoms\":1}}", "");
    try std.testing.expectEqualStrings("200 OK", snapshot.status);
    try std.testing.expect(std.mem.indexOf(u8, snapshot.body, "\"snap_") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"stages\":[\"query_expansion\",\"keyword\",\"vector_ann\",\"rrf\",\"temporal_decay\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "semantic only context") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"groups\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, vector_atom.id) != null);
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

    const resp = handleRequest(&ctx, "POST", "/v1/ask", "{\"query\":\"What database does NullPantry use?\",\"scopes\":[\"public\"]}", "");
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"answer_provider\":\"extractive\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "mem_") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"potential_conflicts\"") != null);
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

    const summary = handleRequest(&ctx, "POST", "/v1/lifecycle/summarize", "{\"messages\":[{\"content\":\"hello\"},{\"content\":\"world\"}],\"max_chars\":8}", "");
    try std.testing.expectEqualStrings("200 OK", summary.status);
    try std.testing.expect(std.mem.indexOf(u8, summary.body, "hello\\nwo") != null);

    const rollout = handleRequest(&ctx, "POST", "/v1/lifecycle/rollout", "{\"key\":\"agent:a\",\"percent\":100}", "");
    try std.testing.expectEqualStrings("200 OK", rollout.status);
    try std.testing.expect(std.mem.indexOf(u8, rollout.body, "\"enabled\":true") != null);

    const hygiene = handleRequest(&ctx, "POST", "/v1/lifecycle/hygiene", "{\"stale_after_ms\":1,\"archive_after_ms\":2}", "");
    try std.testing.expectEqualStrings("200 OK", hygiene.status);
    try std.testing.expect(std.mem.indexOf(u8, hygiene.body, "\"hygiene\"") != null);

    const job = handleRequest(&ctx, "POST", "/v1/jobs", "{\"type\":\"hygiene\",\"scope\":\"workspace\",\"input\":{}}", "");
    try std.testing.expectEqualStrings("200 OK", job.status);
    const worker_run = handleRequest(&ctx, "POST", "/v1/workers/run", "{\"job_limit\":5,\"outbox_limit\":5}", "");
    try std.testing.expectEqualStrings("200 OK", worker_run.status);
    try std.testing.expect(std.mem.indexOf(u8, worker_run.body, "\"jobs_succeeded\":1") != null);
}

test "api memory feed and apply are permission aware" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var public_ctx = Context{ .allocator = alloc, .store = &store, .actor_scopes_json = "[\"public\"]" };

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

    const payload_scope_escalation = handleRequest(&public_ctx, "POST", "/v1/memory/apply", "{\"event_type\":\"memory_atom.upsert\",\"object_type\":\"memory_atom\",\"scope\":\"public\",\"payload\":{\"text\":\"secret from payload\",\"scope\":\"project:secret\"}}", "");
    try std.testing.expectEqualStrings("403 Forbidden", payload_scope_escalation.status);

    const first_apply = handleRequest(&public_ctx, "POST", "/v1/memory/apply", "{\"event_type\":\"memory_atom.upsert\",\"object_type\":\"memory_atom\",\"scope\":\"public\",\"dedupe_key\":\"evt-public-1\",\"payload\":{\"text\":\"dedupe memory\",\"created_by\":\"agent\"}}", "");
    try std.testing.expectEqualStrings("200 OK", first_apply.status);
    const second_apply = handleRequest(&public_ctx, "POST", "/v1/memory/apply", "{\"event_type\":\"memory_atom.upsert\",\"object_type\":\"memory_atom\",\"scope\":\"public\",\"dedupe_key\":\"evt-public-1\",\"payload\":{\"text\":\"dedupe memory duplicate\",\"created_by\":\"agent\"}}", "");
    try std.testing.expectEqualStrings("200 OK", second_apply.status);
    const events = try store.listFeedEvents(alloc, .{ .scopes_json = "[\"admin\"]", .limit = 100 });
    var dedupe_count: usize = 0;
    for (events) |event| {
        if (event.dedupe_key != null and std.mem.eql(u8, event.dedupe_key.?, "evt-public-1")) dedupe_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), dedupe_count);
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
        \\{"title":"Planning","type":"transcript","scope":"project:nullpantry","content":"Decision: NullPantry uses ingestion jobs\nConstraint: every atom has citations\nRisk: stale memory"}
    ;
    const resp = handleRequest(&ctx, "POST", "/v1/ingest", body, "");
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"job\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"artifact\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"memory_atoms\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"predicate\":\"decision\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"name\":\"NullPantry\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"vector_chunk_count\":5") != null);

    const search_resp = handleRequest(&ctx, "POST", "/v1/search", "{\"query\":\"ingestion jobs\",\"scopes\":[\"project:nullpantry\"]}", "");
    try std.testing.expectEqualStrings("200 OK", search_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, search_resp.body, "NullPantry uses ingestion jobs") != null);

    const jobs = handleRequest(&ctx, "GET", "/v1/jobs?status=succeeded", "", "");
    try std.testing.expectEqualStrings("200 OK", jobs.status);
    try std.testing.expect(std.mem.indexOf(u8, jobs.body, "\"type\":\"ingest\"") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, caps.body, "get_context_pack") != null);

    const connector_resp = handleRequest(&ctx, "GET", "/v1/connectors", "", "");
    try std.testing.expectEqualStrings("200 OK", connector_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, connector_resp.body, "\"name\":\"nullclaw\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, connector_resp.body, "\"name\":\"nullwatch\"") != null);

    const manifest = handleRequest(&ctx, "GET", "/v1/sdk/manifest", "", "");
    try std.testing.expectEqualStrings("200 OK", manifest.status);
    try std.testing.expect(std.mem.indexOf(u8, manifest.body, "X-NullPantry-Actor-Scopes") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest.body, "POST /v1/remember") != null);
}
