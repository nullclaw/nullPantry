const std = @import("std");
const api_access = @import("api_access.zig");
const api_body = @import("api_body.zig");
const api_responses = @import("api_responses.zig");
const api_types = @import("api_types.zig");
const embedding_cache = @import("embedding_cache.zig");
const json = @import("json_util.zig");
const providers = @import("providers.zig");
const vector_mod = @import("vector.zig");

pub const Context = api_types.Context;
pub const HttpResponse = api_types.HttpResponse;
pub const default_cache_max_entries = embedding_cache.default_max_entries;

const badJson = api_responses.badJson;
const forbidden = api_responses.forbidden;
const serverError = api_responses.serverError;

pub fn embed(ctx: *Context, body: []const u8) HttpResponse {
    if (!api_access.hasCapability(ctx, "read")) return forbidden(ctx);
    var parsed = api_body.parse(ctx, body) catch return badJson(ctx);
    defer parsed.deinit();
    const obj = parsed.value.object;
    if (obj.get("base_url") != null or obj.get("api_key") != null or obj.get("model") != null or obj.get("provider") != null or obj.get("timeout_secs") != null or obj.get("embedding_allow_insecure_http") != null or obj.get("allow_insecure_http") != null) {
        return json.errorResponse(ctx.allocator, 400, "bad_request", "Provider overrides are not allowed; configure providers on the server");
    }
    const text = json.stringField(obj, "text") orelse return json.errorResponse(ctx.allocator, 400, "bad_request", "Missing text");
    const bounded_dimensions = vector_mod.boundedEmbeddingDimensions(json.intField(obj, "dimensions"), ctx.provider.embedding.dimensions);
    const cfg = configFromContext(ctx, bounded_dimensions);
    const use_cache = json.boolField(obj, "use_embedding_cache") orelse json.boolField(obj, "use_cache") orelse true;
    const purpose = purposeFromObject(obj) catch return json.errorResponse(ctx.allocator, 400, "bad_request", "Invalid embedding purpose");
    var result = embedTextCachedForPurpose(ctx, cfg, text, bounded_dimensions, use_cache, cacheMaxEntries(obj), purpose) catch return serverError(ctx);
    defer result.deinit(ctx.allocator);
    const embedding_json = vector_mod.embeddingToJson(ctx.allocator, result.embedding) catch return serverError(ctx);
    defer ctx.allocator.free(embedding_json);
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

pub fn configFromContext(ctx: *Context, dimensions: usize) providers.EmbeddingConfig {
    return .{
        .provider = ctx.provider.embedding.provider,
        .base_url = ctx.provider.embedding.base_url,
        .api_key = ctx.provider.embedding.api_key,
        .model = ctx.provider.embedding.model,
        .dimensions = vector_mod.boundedEmbeddingDimensions(null, dimensions),
        .send_dimensions = ctx.provider.embedding.send_dimensions,
        .timeout_secs = ctx.provider.embedding.timeout_secs,
        .max_response_bytes = ctx.provider.embedding.max_response_bytes,
        .allow_insecure_http = ctx.provider.embedding.allow_insecure_http,
        .fallbacks = ctx.provider.embedding.fallbacks,
        .routes = ctx.provider.embedding.routes,
        .runtime = ctx.provider.runtime(),
    };
}

pub fn embedTextCached(ctx: *Context, cfg: providers.EmbeddingConfig, text: []const u8, fallback_dimensions: usize, use_cache: bool, max_entries: usize) !providers.EmbeddingResult {
    return embedding_cache.embedTextCached(ctx.allocator, ctx.store, cfg, text, fallback_dimensions, use_cache, max_entries);
}

pub fn embedTextCachedForPurpose(ctx: *Context, cfg: providers.EmbeddingConfig, text: []const u8, fallback_dimensions: usize, use_cache: bool, max_entries: usize, purpose: providers.EmbeddingPurpose) !providers.EmbeddingResult {
    return embedding_cache.embedTextCachedForPurpose(ctx.allocator, ctx.store, cfg, text, fallback_dimensions, use_cache, max_entries, purpose);
}

pub fn purposeFromObject(obj: std.json.ObjectMap) !providers.EmbeddingPurpose {
    const raw = json.stringField(obj, "purpose") orelse json.stringField(obj, "embedding_purpose") orelse return .generic;
    return providers.EmbeddingPurpose.parse(raw);
}

pub fn cacheMaxEntries(obj: std.json.ObjectMap) usize {
    return embedding_cache.maxEntriesFromObject(obj);
}

test "embedding request helpers parse purpose and cache limits" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"purpose\":\"query\",\"embedding_cache_max_entries\":2000000}", .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    try std.testing.expectEqual(providers.EmbeddingPurpose.query, try purposeFromObject(obj));
    try std.testing.expectEqual(@as(usize, 1_000_000), cacheMaxEntries(obj));
}
