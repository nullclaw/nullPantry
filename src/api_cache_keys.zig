const std = @import("std");

const api_types = @import("api_types.zig");
const cache_keys = @import("cache_keys.zig");
const store_mod = @import("store.zig");

const Context = api_types.Context;

pub fn requestSalt(ctx: *Context, revision: []const u8) cache_keys.RequestSalt {
    return .{
        .actor_id = ctx.actor_id,
        .actor_capabilities_json = ctx.actor_capabilities_json,
        .revision = revision,
        .embedding_provider = ctx.provider.embedding.provider.name(),
        .embedding_model = ctx.provider.embedding.model,
        .embedding_base_url = ctx.provider.embedding.base_url,
        .embedding_dimensions = ctx.provider.embedding.dimensions,
        .embedding_send_dimensions = ctx.provider.embedding.send_dimensions,
        .embedding_route_count = ctx.provider.embedding.routes.len,
        .embedding_fallback_count = ctx.provider.embedding.fallbacks.len,
        .llm_model = ctx.provider.completion.model,
        .llm_base_url = ctx.provider.completion.base_url,
    };
}

pub fn responseKey(ctx: *Context, namespace: []const u8, body: []const u8, input: store_mod.SearchInput) ![]u8 {
    const allocator = ctx.allocator;
    const revision = try ctx.store.responseCacheRevision(allocator, input);
    defer allocator.free(revision);
    return cache_keys.responseKey(.{
        .allocator = allocator,
        .namespace = namespace,
        .body = body,
        .search = input,
        .salt = requestSalt(ctx, revision),
    });
}

pub fn semanticPrefix(ctx: *Context, namespace: []const u8, input: store_mod.SearchInput, include_conflicts: bool, use_llm: bool, graph_cache_salt: []const u8) ![]u8 {
    const allocator = ctx.allocator;
    const revision = try ctx.store.responseCacheRevision(allocator, input);
    defer allocator.free(revision);
    return cache_keys.semanticPrefix(.{
        .allocator = allocator,
        .namespace = namespace,
        .search = input,
        .salt = requestSalt(ctx, revision),
        .include_conflicts = include_conflicts,
        .use_llm = use_llm,
        .graph_cache_salt = graph_cache_salt,
    });
}
