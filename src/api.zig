const std = @import("std");
const Store = @import("store.zig").Store;
const store_mod = @import("store.zig");
const domain = @import("domain.zig");
const json = @import("json_util.zig");

pub const Context = struct {
    allocator: std.mem.Allocator,
    store: *Store,
    required_token: ?[]const u8 = null,
    actor_id: []const u8 = "local",
    actor_scopes_json: []const u8 = "[\"admin\"]",
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

    if (eql(seg0, "v1") and eql(seg1, "nullclaw")) {
        return handleNullClaw(ctx, method, parsed.query, seg2, seg3, seg4, body);
    }

    if (!eql(seg0, "v1")) return json.errorResponse(ctx.allocator, 404, "not_found", "Not found");

    if (eql(seg1, "sources")) {
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
            ctx.store.saveUsage(seg3.?, 0) catch return serverError(ctx);
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
    if (!domain.permissionsWritable(permissions_json, ctx.actor_scopes_json)) return forbidden(ctx);
    const artifact = ctx.store.createArtifact(ctx.allocator, .{
        .artifact_type = json.stringField(obj, "type") orelse "page",
        .title = title,
        .body = json.stringField(obj, "body") orelse "",
        .status = json.stringField(obj, "status") orelse "draft",
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

fn createMemoryAtom(ctx: *Context, body: []const u8) HttpResponse {
    const input = parseMemoryAtomInput(ctx, body) catch return badJson(ctx);
    if (!canWriteRecord(ctx, input.scope, input.permissions_json)) return forbidden(ctx);
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
    if (!memoryAtomWritable(ctx, id)) return json.errorResponse(ctx.allocator, 404, "not_found", "Memory atom not found");
    const changed = ctx.store.patchMemoryAtomStatus(id, status, std.mem.eql(u8, status, "verified")) catch return serverError(ctx);
    if (!changed) return json.errorResponse(ctx.allocator, 404, "not_found", "Memory atom not found");
    const atom = ctx.store.getMemoryAtom(ctx.allocator, id) catch return serverError(ctx);
    return objectResponse(ctx, "memory_atom", atom.?);
}

fn statusAction(ctx: *Context, body: []const u8, status: []const u8, verified: bool, response_key: []const u8) HttpResponse {
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const id = json.stringField(parsed.value.object, "id") orelse json.stringField(parsed.value.object, "memory_atom_id") orelse return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing id");
    if (!memoryAtomWritable(ctx, id)) return json.errorResponse(ctx.allocator, 404, "not_found", "Memory atom not found");
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
        .subject_entity_id = json.nullableStringField(obj, "subject_entity_id"),
        .predicate = json.stringField(obj, "predicate") orelse "states",
        .object = json.stringField(obj, "object") orelse "",
        .text = text,
        .scope = json.stringField(obj, "scope") orelse "workspace",
        .confidence = json.floatField(obj, "confidence") orelse 0.5,
        .status = json.nullableStringField(obj, "status"),
        .source_ids_json = try rawField(ctx.allocator, obj, "source_ids", "[]"),
        .evidence_ranges_json = try rawField(ctx.allocator, obj, "evidence_ranges", "[]"),
        .created_by = json.stringField(obj, "created_by") orelse "human",
        .valid_from_ms = json.intField(obj, "valid_from_ms"),
        .valid_until_ms = json.intField(obj, "valid_until_ms"),
        .owner = json.nullableStringField(obj, "owner"),
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
    }) catch return serverError(ctx);
    return searchResponse(ctx, results);
}

fn ask(ctx: *Context, body: []const u8) HttpResponse {
    var parsed = parseBody(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const query = json.stringField(obj, "query") orelse json.stringField(obj, "question") orelse "";
    const results = ctx.store.search(ctx.allocator, .{
        .query = query,
        .limit = 6,
        .scopes_json = effectiveScopes(ctx, obj) catch return serverError(ctx),
    }) catch return serverError(ctx);

    var answer: std.ArrayListUnmanaged(u8) = .empty;
    if (results.len == 0) {
        answer.appendSlice(ctx.allocator, "I don't know based on the accessible NullPantry knowledge.") catch return serverError(ctx);
    } else {
        answer.appendSlice(ctx.allocator, "Based on accessible memory: ") catch return serverError(ctx);
        for (results, 0..) |result, i| {
            if (i > 0) answer.appendSlice(ctx.allocator, " ") catch return serverError(ctx);
            answer.appendSlice(ctx.allocator, result.text) catch return serverError(ctx);
        }
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ctx.allocator, "{\"answer\":") catch return serverError(ctx);
    json.appendString(&out, ctx.allocator, answer.items) catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"confidence\":") catch return serverError(ctx);
    out.appendSlice(ctx.allocator, if (results.len == 0) "0" else "0.7") catch return serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"results\":") catch return serverError(ctx);
    appendSearchArray(ctx, &out, results) catch return serverError(ctx);
    out.append(ctx.allocator, '}') catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
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

fn effectiveScopes(ctx: *Context, obj: std.json.ObjectMap) ![]const u8 {
    const requested = try rawField(ctx.allocator, obj, "scopes", "[]");
    if (domain.hasActorScope(ctx.actor_scopes_json, "admin") and !std.mem.eql(u8, requested, "[]")) return requested;
    return ctx.actor_scopes_json;
}

fn canWriteRecord(ctx: *Context, scope: []const u8, permissions_json: []const u8) bool {
    return domain.scopeWritable(scope, ctx.actor_scopes_json) and domain.permissionsWritable(permissions_json, ctx.actor_scopes_json);
}

fn memoryAtomWritable(ctx: *Context, id: []const u8) bool {
    const atom = ctx.store.getMemoryAtom(ctx.allocator, id) catch return false;
    const existing = atom orelse return false;
    return canWriteRecord(ctx, existing.scope, existing.permissions_json);
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
    try std.testing.expectEqualStrings("200 OK", get_session_without_filter.status);
    try std.testing.expect(std.mem.indexOf(u8, get_session_without_filter.body, "\"session_id\":\"sess_1\"") != null);

    const get_session_encoded = handleRequest(&ctx, "GET", "/v1/nullclaw/memories/session.pref?session_id=sess_1", "", "");
    try std.testing.expectEqualStrings("200 OK", get_session_encoded.status);

    const put_colon_session = handleRequest(&ctx, "PUT", "/v1/nullclaw/memories/colon.pref", "{\"content\":\"Colon session memory\",\"category\":\"core\",\"session_id\":\"agent:coder\"}", "");
    try std.testing.expectEqualStrings("200 OK", put_colon_session.status);
    const get_colon_session = handleRequest(&ctx, "GET", "/v1/nullclaw/memories/colon.pref?session_id=agent%3Acoder", "", "");
    try std.testing.expectEqualStrings("200 OK", get_colon_session.status);
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
