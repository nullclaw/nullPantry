const std = @import("std");
const agent_memory_runtime = @import("agent_memory_runtime.zig");
const semantic_cache_policy = @import("semantic_cache_policy.zig");
const store_agent_memory_subset = @import("store_agent_memory_subset.zig");
const store_types = @import("store_types.zig");

pub const ResponseCacheInput = store_types.ResponseCacheInput;

pub const ResponseCacheEntry = struct {
    cache_key: []const u8,
    response_json: []const u8,
    scopes_json: []const u8,
    actor_id: []const u8,
    created_at_ms: i64,
    accessed_at_ms: i64,
    expires_at_ms: i64,
    hit_count: i64 = 0,
    token_count: i64 = 0,
};

pub const CacheStatsInput = store_types.CacheStatsInput;
pub const CacheClearInput = store_types.CacheClearInput;
pub const AgentMemoryStorageRoute = store_types.AgentMemoryStorageRoute;
pub const SearchInput = store_types.SearchInput;

pub const CacheEntryStats = struct {
    entries: usize = 0,
    expired_entries: usize = 0,
    hits: i64 = 0,
    tokens_saved: i64 = 0,
    embedding_entries: usize = 0,
};

pub const EmbeddingCacheInput = store_types.EmbeddingCacheInput;

pub fn appendRuntimeRevision(
    default_runtime: *agent_memory_runtime.Runtime,
    named_runtimes: *agent_memory_runtime.RuntimeRegistry,
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    input: SearchInput,
    route: AgentMemoryStorageRoute,
) !void {
    switch (route.target) {
        .primary, .all => {
            if (default_runtime.isExternal()) try appendRuntimeRevisionSalt(allocator, out, input, default_runtime, "runtime");
            for (named_runtimes.stores.items) |*named| {
                try appendRuntimeRevisionSalt(allocator, out, input, &named.runtime, named.name);
            }
        },
        .native => {},
        .runtime => {
            if (default_runtime.isExternal()) try appendRuntimeRevisionSalt(allocator, out, input, default_runtime, "runtime");
        },
        .named => {
            if (routeNameIsKg(route.name orelse "")) return;
            const name = route.name orelse return error.AgentMemoryStorageUnavailable;
            const runtime = named_runtimes.get(name) orelse return error.AgentMemoryStorageUnavailable;
            try appendRuntimeRevisionSalt(allocator, out, input, runtime, name);
        },
        .subset => {
            const stores = try store_agent_memory_subset.requireStores(route);
            for (stores) |store_name| {
                try appendRuntimeRevision(default_runtime, named_runtimes, allocator, out, input, store_agent_memory_subset.routeForStoreName(store_name));
            }
        },
    }
}

fn routeNameIsKg(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "kg");
}

test "response cache runtime revision skips kg route aliases" {
    try std.testing.expect(routeNameIsKg("kg"));
    try std.testing.expect(routeNameIsKg("KG"));
    try std.testing.expect(!routeNameIsKg("runtime"));
}

fn appendRuntimeRevisionSalt(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    input: SearchInput,
    runtime: *agent_memory_runtime.Runtime,
    store_name: []const u8,
) !void {
    try out.appendSlice(allocator, "|runtime:");
    try out.appendSlice(allocator, store_name);
    try out.append(allocator, ':');
    try out.appendSlice(allocator, runtime.backendName());
    if (!runtime.supportsFeed()) {
        try out.appendSlice(allocator, ":nofeed");
        return;
    }
    var status = try runtime.feedStatusByInput(allocator, .{
        .scopes_json = input.scopes_json,
        .actor_id = input.actor_id,
        .capabilities_json = input.actor_capabilities_json,
    });
    defer status.deinit(allocator);
    try out.print(
        allocator,
        ":instance={s}:floor={d}:max_event={d}:last_sequence={d}:visible={d}:pending={d}:applying={d}:applied={d}",
        .{
            status.instance_id,
            status.cursor_floor,
            status.max_event_id,
            status.last_sequence,
            status.visible_events,
            status.pending_events,
            status.applying_events,
            status.applied_events,
        },
    );
}

pub const EmbeddingCacheEntry = struct {
    cache_key: []const u8,
    provider: []const u8,
    model: []const u8,
    dimensions: usize,
    embedding_json: []const u8,
    created_at_ms: i64,
    accessed_at_ms: i64,
    hit_count: i64 = 0,
};

pub fn freeEmbeddingCacheEntry(allocator: std.mem.Allocator, entry: *EmbeddingCacheEntry) void {
    if (entry.cache_key.len > 0) allocator.free(entry.cache_key);
    if (entry.provider.len > 0) allocator.free(entry.provider);
    if (entry.model.len > 0) allocator.free(entry.model);
    if (entry.embedding_json.len > 0) allocator.free(entry.embedding_json);
    entry.* = .{
        .cache_key = "",
        .provider = "",
        .model = "",
        .dimensions = 0,
        .embedding_json = "",
        .created_at_ms = 0,
        .accessed_at_ms = 0,
        .hit_count = 0,
    };
}

pub const EmbeddingCacheStats = struct {
    entries: usize = 0,
    hits: i64 = 0,
};

pub const EmbeddingCacheClearInput = store_types.EmbeddingCacheClearInput;
pub const SemanticCacheInput = store_types.SemanticCacheInput;
pub const SemanticCacheSearchInput = store_types.SemanticCacheSearchInput;
pub const default_semantic_cache_candidate_limit = semantic_cache_policy.default_candidate_limit;
pub const max_semantic_cache_candidate_limit = semantic_cache_policy.max_candidate_limit;

pub const SemanticCacheMatch = struct {
    cache_key: []const u8,
    query: []const u8,
    response_json: []const u8,
    embedding_provider: []const u8 = "provided",
    embedding_model: []const u8 = "",
    embedding_dimensions: usize = 0,
    scopes_json: []const u8,
    actor_id: []const u8,
    score: f32,
    created_at_ms: i64,
    accessed_at_ms: i64,
    expires_at_ms: i64,
    hit_count: i64 = 0,
    token_count: i64 = 0,
};

pub fn semanticCacheCandidateLimit(limit: usize) i64 {
    return semantic_cache_policy.storeCandidateLimit(limit);
}

pub fn semanticCachePrefixUpperBound(allocator: std.mem.Allocator, prefix: []const u8) !?[]u8 {
    if (prefix.len == 0) return null;
    var out = try allocator.dupe(u8, prefix);
    errdefer allocator.free(out);

    var i = out.len;
    while (i > 0) {
        i -= 1;
        if (out[i] != 0xff) {
            out[i] += 1;
            return try allocator.realloc(out, i + 1);
        }
    }
    allocator.free(out);
    return null;
}

pub fn semanticCacheModelVisible(requested_model: []const u8, stored_model: []const u8) bool {
    return requested_model.len == 0 or stored_model.len == 0 or std.mem.eql(u8, requested_model, stored_model);
}

test "semantic cache helper bounds candidate windows and prefix ranges" {
    try std.testing.expectEqual(@as(i64, default_semantic_cache_candidate_limit), semanticCacheCandidateLimit(0));
    try std.testing.expectEqual(@as(i64, 1), semanticCacheCandidateLimit(1));
    try std.testing.expectEqual(@as(i64, max_semantic_cache_candidate_limit), semanticCacheCandidateLimit(1_000_000));

    const upper = try semanticCachePrefixUpperBound(std.testing.allocator, "abc");
    defer if (upper) |value| std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("abd", upper.?);
    try std.testing.expectEqual(@as(?[]u8, null), try semanticCachePrefixUpperBound(std.testing.allocator, ""));
    try std.testing.expectEqual(@as(?[]u8, null), try semanticCachePrefixUpperBound(std.testing.allocator, "\xff\xff"));
}

test "semantic cache model visibility treats missing model as wildcard" {
    try std.testing.expect(semanticCacheModelVisible("", "model-a"));
    try std.testing.expect(semanticCacheModelVisible("model-a", ""));
    try std.testing.expect(semanticCacheModelVisible("model-a", "model-a"));
    try std.testing.expect(!semanticCacheModelVisible("model-a", "model-b"));
}
