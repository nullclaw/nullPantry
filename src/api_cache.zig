const std = @import("std");
const api_access = @import("api_access.zig");
const api_body = @import("api_body.zig");
const api_embedding = @import("api_embedding.zig");
const api_responses = @import("api_responses.zig");
const api_scopes = @import("api_scopes.zig");
const api_types = @import("api_types.zig");
const bounded_int = @import("bounded_int.zig");
const ids = @import("ids.zig");
const json = @import("json_util.zig");
const semantic_cache_policy = @import("semantic_cache_policy.zig");
const store_mod = @import("store.zig");
const vector_mod = @import("vector.zig");

const Context = api_types.Context;
const HttpResponse = api_types.HttpResponse;
const badJson = api_responses.badJson;
const forbidden = api_responses.forbidden;
const ok = api_responses.ok;
const serverError = api_responses.serverError;
const max_cache_entries: usize = 1_000_000;

pub fn responsePut(ctx: *Context, body: []const u8) HttpResponse {
    if (!api_access.hasCapability(ctx, "write")) return forbidden(ctx);
    var parsed = api_body.parse(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const cache_key = json.stringField(obj, "key") orelse json.stringField(obj, "cache_key") orelse return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing cache key");
    const scopes_json = api_scopes.effective(ctx, obj) catch |err| return cacheRawJsonRequestError(ctx, err);
    const response_json = cacheResponseJson(ctx, obj) catch |err| return cacheRawJsonRequestError(ctx, err);
    ctx.store.putResponseCache(.{
        .cache_key = cache_key,
        .response_json = response_json,
        .scopes_json = scopes_json,
        .actor_id = ctx.actor_id,
        .ttl_ms = json.intField(obj, "ttl_ms") orelse 0,
        .token_count = tokenCount(obj, response_json),
        .max_entries = maxEntries(obj, "max_entries"),
    }) catch return serverError(ctx);
    return ok(ctx, "{\"ok\":true,\"cached\":true}");
}

pub fn responseGet(ctx: *Context, body: []const u8) HttpResponse {
    if (!api_access.hasCapability(ctx, "read")) return forbidden(ctx);
    var parsed = api_body.parse(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const cache_key = json.stringField(obj, "key") orelse json.stringField(obj, "cache_key") orelse return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing cache key");
    const scopes_json = api_scopes.effective(ctx, obj) catch |err| return cacheRawJsonRequestError(ctx, err);
    const entry = ctx.store.getResponseCacheForScopes(ctx.allocator, cache_key, ids.nowMs(), scopes_json, ctx.actor_id) catch return serverError(ctx);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ctx.allocator, "{\"hit\":") catch return serverError(ctx);
    if (entry) |hit| {
        appendResponseCacheHit(ctx, &out, hit) catch return serverError(ctx);
    } else {
        out.appendSlice(ctx.allocator, "false") catch return serverError(ctx);
    }
    out.append(ctx.allocator, '}') catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

pub fn responseStats(ctx: *Context) HttpResponse {
    if (!api_access.hasCapability(ctx, "read")) return forbidden(ctx);
    const stats = ctx.store.responseCacheStats(.{ .actor_id = ctx.actor_id }) catch return serverError(ctx);
    return statsJson(ctx, "response", stats);
}

pub fn responseClear(ctx: *Context, body: []const u8) HttpResponse {
    if (!api_access.hasCapability(ctx, "delete")) return forbidden(ctx);
    var parsed = api_body.parse(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const cache_key = json.nullableStringField(obj, "key") orelse json.nullableStringField(obj, "cache_key");
    const cleared = ctx.store.clearResponseCache(.{
        .actor_id = ctx.actor_id,
        .cache_key = cache_key,
        .expired_only = json.boolField(obj, "expired_only") orelse false,
        .now_ms = json.intField(obj, "now_ms"),
    }) catch return serverError(ctx);
    return clearJson(ctx, "response", cleared);
}

pub fn semanticPut(ctx: *Context, body: []const u8) HttpResponse {
    if (!api_access.hasCapability(ctx, "write")) return forbidden(ctx);
    var parsed = api_body.parse(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const cache_key = json.stringField(obj, "key") orelse json.stringField(obj, "cache_key") orelse return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing cache key");
    const query = json.stringField(obj, "query") orelse "";
    const scopes_json = api_scopes.effective(ctx, obj) catch |err| return cacheRawJsonRequestError(ctx, err);
    const response_json = cacheResponseJson(ctx, obj) catch |err| return cacheRawJsonRequestError(ctx, err);
    const embedding = semanticEmbedding(ctx, obj, null) catch |err| switch (err) {
        error.InvalidEmbeddingJson, error.InvalidRawJson => return badJson(ctx),
        error.MissingSemanticCacheQuery => return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing query or embedding"),
        else => return serverError(ctx),
    };
    ctx.store.putSemanticCache(.{
        .cache_key = cache_key,
        .query = query,
        .response_json = response_json,
        .embedding_json = embedding.embedding_json,
        .embedding_provider = embedding.provider,
        .embedding_model = embedding.model,
        .embedding_dimensions = embedding.dimensions,
        .scopes_json = scopes_json,
        .actor_id = ctx.actor_id,
        .ttl_ms = json.intField(obj, "ttl_ms") orelse 0,
        .token_count = tokenCount(obj, response_json),
        .max_entries = maxEntries(obj, "max_entries"),
    }) catch return serverError(ctx);
    return ok(ctx, "{\"ok\":true,\"cached\":true}");
}

pub fn semanticSearch(ctx: *Context, body: []const u8) HttpResponse {
    if (!api_access.hasCapability(ctx, "read")) return forbidden(ctx);
    var parsed = api_body.parse(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const scopes_json = api_scopes.effective(ctx, obj) catch |err| return cacheRawJsonRequestError(ctx, err);
    var embedding = semanticEmbedding(ctx, obj, null) catch |err| switch (err) {
        error.InvalidEmbeddingJson, error.InvalidRawJson => return badJson(ctx),
        error.MissingSemanticCacheQuery => return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing query or embedding"),
        else => return serverError(ctx),
    };
    if (obj.get("embedding") != null and
        obj.get("embedding_provider") == null and
        obj.get("provider") == null)
    {
        embedding.provider = "";
        embedding.model = "";
    }
    const match = ctx.store.searchSemanticCache(ctx.allocator, .{
        .embedding_json = embedding.embedding_json,
        .embedding_provider = embedding.provider,
        .embedding_model = embedding.model,
        .embedding_dimensions = embedding.dimensions,
        .scopes_json = scopes_json,
        .actor_id = ctx.actor_id,
        .min_score = @floatCast(json.floatField(obj, "min_score") orelse 0.82),
        .candidate_limit = semanticCacheCandidateLimit(obj, "candidate_limit"),
    }) catch return serverError(ctx);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ctx.allocator, "{\"hit\":") catch return serverError(ctx);
    if (match) |hit| {
        appendSemanticCacheHit(ctx, &out, hit) catch return serverError(ctx);
    } else {
        out.appendSlice(ctx.allocator, "false") catch return serverError(ctx);
    }
    out.append(ctx.allocator, '}') catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

fn appendResponseCacheHit(ctx: *Context, out: *std.ArrayListUnmanaged(u8), hit: store_mod.ResponseCacheEntry) !void {
    try out.appendSlice(ctx.allocator, "true,\"cache_key\":");
    try json.appendString(out, ctx.allocator, hit.cache_key);
    try appendCachePayload(ctx, out, hit.scopes_json, hit.response_json);
    try out.print(ctx.allocator, ",\"created_at_ms\":{d},\"accessed_at_ms\":{d},\"expires_at_ms\":{d},\"hit_count\":{d},\"token_count\":{d}", .{ hit.created_at_ms, hit.accessed_at_ms, hit.expires_at_ms, hit.hit_count, hit.token_count });
}

fn appendSemanticCacheHit(ctx: *Context, out: *std.ArrayListUnmanaged(u8), hit: store_mod.SemanticCacheMatch) !void {
    try out.appendSlice(ctx.allocator, "true,\"cache_key\":");
    try json.appendString(out, ctx.allocator, hit.cache_key);
    try out.appendSlice(ctx.allocator, ",\"query\":");
    try json.appendString(out, ctx.allocator, hit.query);
    try out.appendSlice(ctx.allocator, ",\"embedding_provider\":");
    try json.appendString(out, ctx.allocator, hit.embedding_provider);
    try out.appendSlice(ctx.allocator, ",\"embedding_model\":");
    try json.appendString(out, ctx.allocator, hit.embedding_model);
    try out.print(ctx.allocator, ",\"embedding_dimensions\":{d}", .{hit.embedding_dimensions});
    try appendCachePayload(ctx, out, hit.scopes_json, hit.response_json);
    try out.print(ctx.allocator, ",\"score\":{d},\"created_at_ms\":{d},\"accessed_at_ms\":{d},\"expires_at_ms\":{d},\"hit_count\":{d},\"token_count\":{d}", .{ hit.score, hit.created_at_ms, hit.accessed_at_ms, hit.expires_at_ms, hit.hit_count, hit.token_count });
}

fn appendCachePayload(ctx: *Context, out: *std.ArrayListUnmanaged(u8), scopes_json: []const u8, response_json: []const u8) !void {
    try out.appendSlice(ctx.allocator, ",\"scopes\":");
    try json.appendRawJsonArray(out, ctx.allocator, scopes_json);
    try out.appendSlice(ctx.allocator, ",\"response\":");
    try json.appendRawJsonObject(out, ctx.allocator, response_json);
}

pub fn semanticStats(ctx: *Context) HttpResponse {
    if (!api_access.hasCapability(ctx, "read")) return forbidden(ctx);
    const stats = ctx.store.semanticCacheStats(.{ .actor_id = ctx.actor_id }) catch return serverError(ctx);
    return statsJson(ctx, "semantic", stats);
}

pub fn semanticClear(ctx: *Context, body: []const u8) HttpResponse {
    if (!api_access.hasCapability(ctx, "delete")) return forbidden(ctx);
    var parsed = api_body.parse(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const cache_key = json.nullableStringField(obj, "key") orelse json.nullableStringField(obj, "cache_key");
    const cleared = ctx.store.clearSemanticCache(.{
        .actor_id = ctx.actor_id,
        .cache_key = cache_key,
        .expired_only = json.boolField(obj, "expired_only") orelse false,
        .now_ms = json.intField(obj, "now_ms"),
    }) catch return serverError(ctx);
    return clearJson(ctx, "semantic", cleared);
}

pub fn embeddingStats(ctx: *Context) HttpResponse {
    if (!api_access.hasCapability(ctx, "read")) return forbidden(ctx);
    const stats = ctx.store.embeddingCacheStats() catch return serverError(ctx);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.print(ctx.allocator, "{{\"cache\":\"embedding\",\"entries\":{d},\"hits\":{d}}}", .{ stats.entries, stats.hits }) catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

pub fn embeddingClear(ctx: *Context, body: []const u8) HttpResponse {
    if (!api_access.hasCapability(ctx, "delete")) return forbidden(ctx);
    var parsed = api_body.parse(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const cache_key = json.nullableStringField(obj, "key") orelse json.nullableStringField(obj, "cache_key");
    const cleared = ctx.store.clearEmbeddingCache(.{ .cache_key = cache_key }) catch return serverError(ctx);
    return clearJson(ctx, "embedding", cleared);
}

pub const SemanticEmbedding = struct {
    embedding_json: []const u8,
    provider: []const u8,
    model: []const u8,
    dimensions: usize,
};

pub fn semanticEmbedding(ctx: *Context, obj: std.json.ObjectMap, fallback_query: ?[]const u8) !SemanticEmbedding {
    if (obj.get("embedding") != null) {
        const embedding_json = try cacheEmbeddingJson(ctx, obj);
        const parsed_embedding = try vector_mod.embeddingFromJson(ctx.allocator, embedding_json);
        defer ctx.allocator.free(parsed_embedding);
        return .{
            .embedding_json = embedding_json,
            .provider = json.stringField(obj, "embedding_provider") orelse json.stringField(obj, "provider") orelse "provided",
            .model = json.stringField(obj, "embedding_model") orelse json.stringField(obj, "model") orelse "",
            .dimensions = parsed_embedding.len,
        };
    }
    const query = json.stringField(obj, "query") orelse fallback_query orelse return error.MissingSemanticCacheQuery;
    return semanticEmbeddingForQuery(ctx, obj, query);
}

pub fn optionalSemanticEmbedding(ctx: *Context, obj: std.json.ObjectMap, query: []const u8) ?SemanticEmbedding {
    if (query.len == 0) return null;
    return semanticEmbeddingForQuery(ctx, obj, query) catch null;
}

fn semanticEmbeddingForQuery(ctx: *Context, obj: std.json.ObjectMap, query: []const u8) !SemanticEmbedding {
    if (query.len == 0) return error.MissingSemanticCacheQuery;
    const dimensions = vector_mod.boundedEmbeddingDimensions(json.intField(obj, "dimensions"), ctx.provider.embedding.dimensions);
    var result = try api_embedding.embedTextCachedForPurpose(ctx, api_embedding.configFromContext(ctx, dimensions), query, dimensions, json.boolField(obj, "use_embedding_cache") orelse json.boolField(obj, "use_cache") orelse true, api_embedding.cacheMaxEntries(obj), .query);
    defer result.deinit(ctx.allocator);
    return .{
        .embedding_json = try vector_mod.embeddingToJson(ctx.allocator, result.embedding),
        .provider = try ctx.allocator.dupe(u8, result.provider),
        .model = try ctx.allocator.dupe(u8, result.model),
        .dimensions = result.embedding.len,
    };
}

fn cacheResponseJson(ctx: *Context, obj: std.json.ObjectMap) ![]const u8 {
    return api_body.rawObjectField(ctx.allocator, obj, "response", "{}");
}

fn cacheEmbeddingJson(ctx: *Context, obj: std.json.ObjectMap) ![]const u8 {
    return api_body.rawArrayField(ctx.allocator, obj, "embedding", "[]");
}

fn cacheRawJsonRequestError(ctx: *Context, err: anyerror) HttpResponse {
    return switch (err) {
        error.InvalidRawJson => badJson(ctx),
        else => serverError(ctx),
    };
}

pub fn statsJson(ctx: *Context, cache_name: []const u8, stats: store_mod.CacheEntryStats) HttpResponse {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ctx.allocator, "{\"cache\":") catch return serverError(ctx);
    json.appendString(&out, ctx.allocator, cache_name) catch return serverError(ctx);
    out.print(ctx.allocator, ",\"entries\":{d},\"expired_entries\":{d},\"hits\":{d},\"tokens_saved\":{d},\"embedding_entries\":{d},\"actor_id\":", .{ stats.entries, stats.expired_entries, stats.hits, stats.tokens_saved, stats.embedding_entries }) catch return serverError(ctx);
    json.appendString(&out, ctx.allocator, ctx.actor_id) catch return serverError(ctx);
    out.append(ctx.allocator, '}') catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

pub fn clearJson(ctx: *Context, cache_name: []const u8, cleared: usize) HttpResponse {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ctx.allocator, "{\"ok\":true,\"cache\":") catch return serverError(ctx);
    json.appendString(&out, ctx.allocator, cache_name) catch return serverError(ctx);
    out.print(ctx.allocator, ",\"cleared\":{d}}}", .{cleared}) catch return serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return serverError(ctx) };
}

pub fn tokenCount(obj: std.json.ObjectMap, fallback_text: []const u8) i64 {
    if (json.intField(obj, "token_count")) |value| return @max(value, 0);
    return estimateTokenCount(fallback_text);
}

pub fn maxEntries(obj: std.json.ObjectMap, field_name: []const u8) usize {
    const raw = json.intField(obj, field_name) orelse return 0;
    if (raw <= 0) return 0;
    return bounded_int.positiveI64ToUsizeBounded(raw, max_cache_entries);
}

pub fn semanticCacheCandidateLimit(obj: std.json.ObjectMap, field_name: []const u8) usize {
    return semantic_cache_policy.requestCandidateLimit(json.intField(obj, field_name));
}

pub fn estimateTokenCount(text: []const u8) i64 {
    var count: i64 = 0;
    var tokens = std.mem.tokenizeAny(u8, text, " \t\r\n,.;:()[]{}<>!?\"'");
    while (tokens.next()) |_| count += 1;
    return count;
}

test "cache helper bounds explicit limits and estimates fallback token count" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"max_entries\":2000000,\"token_count\":-1,\"candidate_limit\":9223372036854775807}", .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    try std.testing.expectEqual(max_cache_entries, maxEntries(obj, "max_entries"));
    try std.testing.expectEqual(@as(i64, 0), tokenCount(obj, "ignored text"));
    try std.testing.expectEqual(semantic_cache_policy.max_candidate_limit, semanticCacheCandidateLimit(obj, "candidate_limit"));
    try std.testing.expectEqual(@as(i64, 3), estimateTokenCount("one, two three"));
}

test "cache helper defaults and floors semantic candidate limits" {
    var default_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{}", .{});
    defer default_parsed.deinit();
    try std.testing.expectEqual(semantic_cache_policy.default_candidate_limit, semanticCacheCandidateLimit(default_parsed.value.object, "candidate_limit"));

    var floor_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"candidate_limit\":0}", .{});
    defer floor_parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), semanticCacheCandidateLimit(floor_parsed.value.object, "candidate_limit"));
}

test "cache endpoints reject malformed scope filters before store access" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = Context{
        .allocator = arena.allocator(),
        .store = undefined,
    };

    const put_response = responsePut(&ctx, "{\"key\":\"k\",\"response\":{},\"scopes\":[\"public\",42]}");
    try std.testing.expectEqualStrings("400 Bad Request", put_response.status);
    try std.testing.expect(std.mem.indexOf(u8, put_response.body, "\"invalid_json\"") != null);

    const search_response = semanticSearch(&ctx, "{\"query\":\"release\",\"scopes\":[false]}");
    try std.testing.expectEqualStrings("400 Bad Request", search_response.status);
    try std.testing.expect(std.mem.indexOf(u8, search_response.body, "\"invalid_json\"") != null);
}

fn responseCacheHitBodyForTest(hit: store_mod.ResponseCacheEntry) ![]u8 {
    var ctx = Context{
        .allocator = std.testing.allocator,
        .store = undefined,
    };
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(std.testing.allocator);
    try out.appendSlice(std.testing.allocator, "{\"hit\":");
    try appendResponseCacheHit(&ctx, &out, hit);
    try out.append(std.testing.allocator, '}');
    return out.toOwnedSlice(std.testing.allocator);
}

fn semanticCacheHitBodyForTest(hit: store_mod.SemanticCacheMatch) ![]u8 {
    var ctx = Context{
        .allocator = std.testing.allocator,
        .store = undefined,
    };
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(std.testing.allocator);
    try out.appendSlice(std.testing.allocator, "{\"hit\":");
    try appendSemanticCacheHit(&ctx, &out, hit);
    try out.append(std.testing.allocator, '}');
    return out.toOwnedSlice(std.testing.allocator);
}

test "response cache hit writer preserves strict raw fields" {
    const body = try responseCacheHitBodyForTest(.{
        .cache_key = "cache:response",
        .response_json = "{\"answer\":\"cached\"}",
        .scopes_json = "[\"team:alpha\"]",
        .actor_id = "agent:alpha",
        .created_at_ms = 100,
        .accessed_at_ms = 120,
        .expires_at_ms = 200,
        .hit_count = 2,
        .token_count = 42,
    });
    defer std.testing.allocator.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expect(root.get("hit").?.bool);
    try std.testing.expectEqualStrings("cache:response", root.get("cache_key").?.string);
    try std.testing.expectEqualStrings("team:alpha", root.get("scopes").?.array.items[0].string);
    try std.testing.expectEqualStrings("cached", root.get("response").?.object.get("answer").?.string);
    try std.testing.expectEqual(@as(i64, 2), root.get("hit_count").?.integer);
    try std.testing.expectEqual(@as(i64, 42), root.get("token_count").?.integer);
}

test "semantic cache hit writer preserves strict raw fields" {
    const body = try semanticCacheHitBodyForTest(.{
        .cache_key = "cache:semantic",
        .query = "release notes",
        .response_json = "{\"answer\":\"semantic\"}",
        .embedding_provider = "local",
        .embedding_model = "unit",
        .embedding_dimensions = 2,
        .scopes_json = "[\"team:beta\"]",
        .actor_id = "agent:beta",
        .score = 0.9375,
        .created_at_ms = 100,
        .accessed_at_ms = 120,
        .expires_at_ms = 200,
        .hit_count = 3,
        .token_count = 64,
    });
    defer std.testing.allocator.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expect(root.get("hit").?.bool);
    try std.testing.expectEqualStrings("cache:semantic", root.get("cache_key").?.string);
    try std.testing.expectEqualStrings("release notes", root.get("query").?.string);
    try std.testing.expectEqualStrings("local", root.get("embedding_provider").?.string);
    try std.testing.expectEqual(@as(i64, 2), root.get("embedding_dimensions").?.integer);
    try std.testing.expectEqualStrings("team:beta", root.get("scopes").?.array.items[0].string);
    try std.testing.expectEqualStrings("semantic", root.get("response").?.object.get("answer").?.string);
    try std.testing.expectEqual(@as(i64, 3), root.get("hit_count").?.integer);
}

test "cache hit payload rejects invalid raw field roots" {
    var ctx = Context{
        .allocator = std.testing.allocator,
        .store = undefined,
    };

    var bad_scopes: std.ArrayListUnmanaged(u8) = .empty;
    defer bad_scopes.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidRawJson, appendCachePayload(&ctx, &bad_scopes, "{\"scope\":\"team\"}", "{\"answer\":\"cached\"}"));

    var bad_response: std.ArrayListUnmanaged(u8) = .empty;
    defer bad_response.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidRawJson, appendCachePayload(&ctx, &bad_response, "[\"team\"]", "[\"not\",\"an\",\"object\"]"));
}
