const std = @import("std");
const store_mod = @import("store.zig");
const vector_mod = @import("vector.zig");

const AgentMemoryStorageRoute = store_mod.AgentMemoryStorageRoute;
const Store = store_mod.Store;

test "sqlite response cache revision tracks named runtime feed status" {
    var store = try Store.initSQLiteWithOptions(std.testing.allocator, ":memory:", .{
        .agent_memory_stores = &.{.{ .name = "scratch", .config = .{ .backend = .memory_lru } }},
    });
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const route = AgentMemoryStorageRoute.parse("scratch");

    const before = try store.responseCacheRevision(alloc, .{
        .query = "named runtime cache revision",
        .scopes_json = "[\"public\"]",
        .use_vector = false,
        .actor_id = "agent:cache",
        .agent_memory_route = route,
    });
    try std.testing.expect(std.mem.indexOf(u8, before, "|runtime:scratch:memory_lru") != null);

    _ = try store.agentMemoryStoreRouted(alloc, .{
        .key = "cache.revision.named",
        .content = "named runtime cache revision",
        .scope = "public",
        .actor_id = "agent:cache",
        .actor_scopes_json = "[\"public\"]",
    }, route);
    const after = try store.responseCacheRevision(alloc, .{
        .query = "named runtime cache revision",
        .scopes_json = "[\"public\"]",
        .use_vector = false,
        .actor_id = "agent:cache",
        .agent_memory_route = route,
    });
    try std.testing.expect(!std.mem.eql(u8, before, after));
    try std.testing.expect(std.mem.indexOf(u8, after, "visible=1") != null);

    const kg = try store.responseCacheRevision(alloc, .{
        .query = "kg runtime cache revision",
        .use_vector = false,
        .agent_memory_route = AgentMemoryStorageRoute.parse("kg"),
    });
    try std.testing.expect(std.mem.indexOf(u8, kg, "|runtime:kg:") == null);
}

test "sqlite lifecycle cache semantic cache and hygiene are persistent" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try store.putResponseCache(.{ .cache_key = "prompt:a", .response_json = "{\"answer\":\"cached\"}", .ttl_ms = 1000, .now_ms = 100, .token_count = 50 });
    const response_stats = try store.responseCacheStats(.{ .actor_id = "", .now_ms = 200 });
    try std.testing.expectEqual(@as(usize, 1), response_stats.entries);
    try std.testing.expectEqual(@as(usize, 0), response_stats.expired_entries);
    try std.testing.expectEqual(@as(i64, 0), response_stats.hits);
    const response_expired_stats = try store.responseCacheStats(.{ .actor_id = "", .now_ms = 1200 });
    try std.testing.expectEqual(@as(usize, 1), response_expired_stats.expired_entries);
    const cache_hit = (try store.getResponseCache(alloc, "prompt:a", 200)).?;
    try std.testing.expectEqualStrings("{\"answer\":\"cached\"}", cache_hit.response_json);
    try std.testing.expectEqual(@as(i64, 1), cache_hit.hit_count);
    try std.testing.expectEqual(@as(i64, 50), cache_hit.token_count);
    try std.testing.expectEqual(@as(i64, 200), cache_hit.accessed_at_ms);
    const response_hit_stats = try store.responseCacheStats(.{ .actor_id = "", .now_ms = 200 });
    try std.testing.expectEqual(@as(i64, 1), response_hit_stats.hits);
    try std.testing.expectEqual(@as(i64, 50), response_hit_stats.tokens_saved);
    try std.testing.expect((try store.getResponseCache(alloc, "prompt:a", 1200)) == null);

    const embedding = try vector_mod.embeddingToJson(alloc, &[_]f32{ 1, 0 });
    try store.putSemanticCache(.{ .cache_key = "semantic:a", .query = "release", .response_json = "{\"answer\":\"semantic\"}", .embedding_json = embedding, .ttl_ms = 1000, .now_ms = 100, .token_count = 40 });
    const semantic_stats = try store.semanticCacheStats(.{ .actor_id = "", .now_ms = 200 });
    try std.testing.expectEqual(@as(usize, 1), semantic_stats.entries);
    try std.testing.expectEqual(@as(usize, 0), semantic_stats.expired_entries);
    try std.testing.expectEqual(@as(usize, 1), semantic_stats.embedding_entries);
    const semantic_hit = (try store.searchSemanticCache(alloc, .{ .embedding_json = embedding, .min_score = 0.9, .now_ms = 200 })).?;
    try std.testing.expectEqualStrings("semantic:a", semantic_hit.cache_key);
    try std.testing.expectEqual(@as(i64, 1), semantic_hit.hit_count);
    try std.testing.expectEqual(@as(i64, 40), semantic_hit.token_count);
    try std.testing.expectEqual(@as(i64, 200), semantic_hit.accessed_at_ms);
    const semantic_hit_stats = try store.semanticCacheStats(.{ .actor_id = "", .now_ms = 200 });
    try std.testing.expectEqual(@as(i64, 1), semantic_hit_stats.hits);
    try std.testing.expectEqual(@as(i64, 40), semantic_hit_stats.tokens_saved);
    try std.testing.expectEqual(@as(usize, 1), try store.clearSemanticCache(.{ .actor_id = "", .cache_key = "semantic:a" }));
    try std.testing.expect((try store.searchSemanticCache(alloc, .{ .embedding_json = embedding, .min_score = 0.9, .now_ms = 200 })) == null);

    const atom = try store.createMemoryAtom(alloc, .{ .text = "old memory", .scope = "public", .created_by = "human" });
    const hygiene = try store.runHygiene(.{
        .stale_after_ms = 1,
        .archive_after_ms = 10,
        .purge_after_ms = 0,
        .now_ms = atom.created_at_ms + 2,
    });
    try std.testing.expectEqual(@as(usize, 1), hygiene.checked);
    try std.testing.expectEqual(@as(usize, 1), hygiene.marked_stale);
    const stale = (try store.getMemoryAtom(alloc, atom.id)).?;
    try std.testing.expectEqualStrings("stale", stale.status);
}

test "sqlite cache ttl expiration saturates on overflow" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const near_max = std.math.maxInt(i64) - 10;
    try store.putResponseCache(.{
        .cache_key = "overflow:response",
        .response_json = "{\"answer\":\"cached\"}",
        .ttl_ms = 100,
        .now_ms = near_max,
    });
    const response_hit = (try store.getResponseCache(alloc, "overflow:response", std.math.maxInt(i64) - 1)).?;
    try std.testing.expectEqual(std.math.maxInt(i64), response_hit.expires_at_ms);

    const embedding = try vector_mod.embeddingToJson(alloc, &[_]f32{ 1, 0 });
    try store.putSemanticCache(.{
        .cache_key = "overflow:semantic",
        .query = "overflow",
        .response_json = "{\"answer\":\"semantic\"}",
        .embedding_json = embedding,
        .ttl_ms = 100,
        .now_ms = near_max,
    });
    const semantic_hit = (try store.searchSemanticCache(alloc, .{
        .embedding_json = embedding,
        .min_score = 0.9,
        .now_ms = std.math.maxInt(i64) - 1,
    })).?;
    try std.testing.expectEqual(std.math.maxInt(i64), semantic_hit.expires_at_ms);
}

test "sqlite lifecycle caches are isolated by actor id" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try store.putResponseCache(.{ .cache_key = "shared:response", .response_json = "{\"answer\":\"actor-a\"}", .scopes_json = "[\"public\"]", .actor_id = "agent:a", .ttl_ms = 1000, .now_ms = 100 });
    try store.putResponseCache(.{ .cache_key = "shared:response", .response_json = "{\"answer\":\"actor-b\"}", .scopes_json = "[\"public\"]", .actor_id = "agent:b", .ttl_ms = 1000, .now_ms = 100 });

    const a_hit = (try store.getResponseCacheForScopes(alloc, "shared:response", 200, "[\"public\"]", "agent:a")).?;
    try std.testing.expectEqualStrings("{\"answer\":\"actor-a\"}", a_hit.response_json);
    const b_hit = (try store.getResponseCacheForScopes(alloc, "shared:response", 200, "[\"public\"]", "agent:b")).?;
    try std.testing.expectEqualStrings("{\"answer\":\"actor-b\"}", b_hit.response_json);
    try std.testing.expect((try store.getResponseCacheForScopes(alloc, "shared:response", 200, "[\"public\"]", "agent:c")) == null);
    try std.testing.expect((try store.getResponseCache(alloc, "shared:response", 200)) == null);
    const response_stats_a = try store.responseCacheStats(.{ .actor_id = "agent:a", .now_ms = 200 });
    const response_stats_b = try store.responseCacheStats(.{ .actor_id = "agent:b", .now_ms = 200 });
    try std.testing.expectEqual(@as(usize, 1), response_stats_a.entries);
    try std.testing.expectEqual(@as(usize, 1), response_stats_b.entries);
    try std.testing.expectEqual(@as(usize, 0), try store.clearResponseCache(.{ .actor_id = "agent:c", .cache_key = "shared:response" }));
    try std.testing.expectEqual(@as(usize, 1), try store.clearResponseCache(.{ .actor_id = "agent:a", .cache_key = "shared:response" }));
    try std.testing.expect((try store.getResponseCacheForScopes(alloc, "shared:response", 200, "[\"public\"]", "agent:a")) == null);
    try std.testing.expect((try store.getResponseCacheForScopes(alloc, "shared:response", 200, "[\"public\"]", "agent:b")) != null);

    const embedding = try vector_mod.embeddingToJson(alloc, &[_]f32{ 1, 0, 0 });
    try store.putSemanticCache(.{ .cache_key = "shared:semantic", .query = "release", .response_json = "{\"answer\":\"semantic-a\"}", .embedding_json = embedding, .scopes_json = "[\"public\"]", .actor_id = "agent:a", .ttl_ms = 1000, .now_ms = 100 });
    try store.putSemanticCache(.{ .cache_key = "shared:semantic", .query = "release", .response_json = "{\"answer\":\"semantic-b\"}", .embedding_json = embedding, .scopes_json = "[\"public\"]", .actor_id = "agent:b", .ttl_ms = 1000, .now_ms = 100 });

    const semantic_a = (try store.searchSemanticCache(alloc, .{ .embedding_json = embedding, .scopes_json = "[\"public\"]", .actor_id = "agent:a", .min_score = 0.9, .now_ms = 200 })).?;
    try std.testing.expectEqualStrings("{\"answer\":\"semantic-a\"}", semantic_a.response_json);
    const semantic_b = (try store.searchSemanticCache(alloc, .{ .embedding_json = embedding, .scopes_json = "[\"public\"]", .actor_id = "agent:b", .min_score = 0.9, .now_ms = 200 })).?;
    try std.testing.expectEqualStrings("{\"answer\":\"semantic-b\"}", semantic_b.response_json);
    try std.testing.expect((try store.searchSemanticCache(alloc, .{ .embedding_json = embedding, .scopes_json = "[\"public\"]", .actor_id = "agent:c", .min_score = 0.9, .now_ms = 200 })) == null);
    try std.testing.expect((try store.searchSemanticCache(alloc, .{ .embedding_json = embedding, .scopes_json = "[\"admin\"]", .min_score = 0.9, .now_ms = 200 })) == null);
    const semantic_stats_a = try store.semanticCacheStats(.{ .actor_id = "agent:a", .now_ms = 200 });
    const semantic_stats_b = try store.semanticCacheStats(.{ .actor_id = "agent:b", .now_ms = 200 });
    try std.testing.expectEqual(@as(usize, 1), semantic_stats_a.entries);
    try std.testing.expectEqual(@as(usize, 1), semantic_stats_b.entries);
    try std.testing.expectEqual(@as(usize, 1), try store.clearSemanticCache(.{ .actor_id = "agent:a", .cache_key = "shared:semantic" }));
    try std.testing.expect((try store.searchSemanticCache(alloc, .{ .embedding_json = embedding, .scopes_json = "[\"public\"]", .actor_id = "agent:a", .min_score = 0.9, .now_ms = 200 })) == null);
    try std.testing.expect((try store.searchSemanticCache(alloc, .{ .embedding_json = embedding, .scopes_json = "[\"public\"]", .actor_id = "agent:b", .min_score = 0.9, .now_ms = 200 })) != null);
}

test "sqlite semantic cache lookup is prefix bounded instead of actor-wide recency capped" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const embedding = try vector_mod.embeddingToJson(alloc, &[_]f32{ 1, 0 });
    try store.putSemanticCache(.{
        .cache_key = "semantic:target:old",
        .query = "target",
        .response_json = "{\"answer\":\"target\"}",
        .embedding_json = embedding,
        .embedding_provider = "local-deterministic",
        .embedding_model = "local",
        .scopes_json = "[\"public\"]",
        .actor_id = "agent:semantic-prefix",
        .now_ms = 1,
    });

    for (0..1100) |i| {
        const key = try std.fmt.allocPrint(alloc, "semantic:noise:{d}", .{i});
        try store.putSemanticCache(.{
            .cache_key = key,
            .query = "noise",
            .response_json = "{\"answer\":\"noise\"}",
            .embedding_json = embedding,
            .embedding_provider = "local-deterministic",
            .embedding_model = "local",
            .scopes_json = "[\"public\"]",
            .actor_id = "agent:semantic-prefix",
            .now_ms = @intCast(100 + i),
        });
    }

    const hit = (try store.searchSemanticCache(alloc, .{
        .embedding_json = embedding,
        .embedding_provider = "local-deterministic",
        .embedding_model = "local",
        .embedding_dimensions = 2,
        .scopes_json = "[\"public\"]",
        .actor_id = "agent:semantic-prefix",
        .cache_key_prefix = "semantic:target:",
        .min_score = 0.99,
        .candidate_limit = 10,
    })).?;
    try std.testing.expectEqualStrings("semantic:target:old", hit.cache_key);
    try std.testing.expectEqualStrings("{\"answer\":\"target\"}", hit.response_json);
}

test "sqlite semantic cache isolates embedding provider model and dimensions" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const local_embedding = try vector_mod.embeddingToJson(alloc, &[_]f32{ 1, 0 });
    const other_embedding = try vector_mod.embeddingToJson(alloc, &[_]f32{ 0, 1 });
    const three_dimensional = try vector_mod.embeddingToJson(alloc, &[_]f32{ 1, 0, 0 });
    try store.putSemanticCache(.{ .cache_key = "semantic:local", .query = "local", .response_json = "{\"answer\":\"local\"}", .embedding_json = local_embedding, .embedding_provider = "local-deterministic", .embedding_model = "local", .scopes_json = "[\"public\"]", .actor_id = "agent:semantic-metadata" });
    try store.putSemanticCache(.{ .cache_key = "semantic:gemini", .query = "gemini", .response_json = "{\"answer\":\"gemini\"}", .embedding_json = other_embedding, .embedding_provider = "gemini", .embedding_model = "gemini-embedding-001", .scopes_json = "[\"public\"]", .actor_id = "agent:semantic-metadata" });

    const local_hit = (try store.searchSemanticCache(alloc, .{ .embedding_json = local_embedding, .embedding_provider = "local-deterministic", .embedding_model = "local", .embedding_dimensions = 2, .scopes_json = "[\"public\"]", .actor_id = "agent:semantic-metadata", .min_score = 0.99 })).?;
    try std.testing.expectEqualStrings("semantic:local", local_hit.cache_key);
    try std.testing.expect((try store.searchSemanticCache(alloc, .{ .embedding_json = local_embedding, .embedding_provider = "voyage", .embedding_model = "voyage-3", .embedding_dimensions = 2, .scopes_json = "[\"public\"]", .actor_id = "agent:semantic-metadata", .min_score = 0.0 })) == null);
    try std.testing.expect((try store.searchSemanticCache(alloc, .{ .embedding_json = three_dimensional, .embedding_provider = "local-deterministic", .embedding_model = "local", .embedding_dimensions = 3, .scopes_json = "[\"public\"]", .actor_id = "agent:semantic-metadata", .min_score = 0.0 })) == null);
    const wildcard = (try store.searchSemanticCache(alloc, .{ .embedding_json = other_embedding, .embedding_provider = "", .embedding_dimensions = 2, .scopes_json = "[\"public\"]", .actor_id = "agent:semantic-metadata", .min_score = 0.99 })).?;
    try std.testing.expectEqualStrings("semantic:gemini", wildcard.cache_key);
}

test "sqlite lifecycle cache lru eviction is actor scoped" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try store.putResponseCache(.{ .cache_key = "r:old", .response_json = "{\"answer\":\"old\"}", .scopes_json = "[\"public\"]", .actor_id = "agent:a", .now_ms = 100, .max_entries = 2 });
    try store.putResponseCache(.{ .cache_key = "r:middle", .response_json = "{\"answer\":\"middle\"}", .scopes_json = "[\"public\"]", .actor_id = "agent:a", .now_ms = 200, .max_entries = 2 });
    try store.putResponseCache(.{ .cache_key = "r:other", .response_json = "{\"answer\":\"other\"}", .scopes_json = "[\"public\"]", .actor_id = "agent:b", .now_ms = 200, .max_entries = 2 });
    _ = (try store.getResponseCacheForScopes(alloc, "r:old", 300, "[\"public\"]", "agent:a")).?;
    try store.putResponseCache(.{ .cache_key = "r:new", .response_json = "{\"answer\":\"new\"}", .scopes_json = "[\"public\"]", .actor_id = "agent:a", .now_ms = 400, .max_entries = 2 });

    try std.testing.expect((try store.getResponseCacheForScopes(alloc, "r:old", 500, "[\"public\"]", "agent:a")) != null);
    try std.testing.expect((try store.getResponseCacheForScopes(alloc, "r:middle", 500, "[\"public\"]", "agent:a")) == null);
    try std.testing.expect((try store.getResponseCacheForScopes(alloc, "r:new", 500, "[\"public\"]", "agent:a")) != null);
    try std.testing.expect((try store.getResponseCacheForScopes(alloc, "r:other", 500, "[\"public\"]", "agent:b")) != null);
    const response_stats = try store.responseCacheStats(.{ .actor_id = "agent:a", .now_ms = 500 });
    try std.testing.expectEqual(@as(usize, 2), response_stats.entries);

    const e_old = try vector_mod.embeddingToJson(alloc, &[_]f32{ 1, 0 });
    const e_new = try vector_mod.embeddingToJson(alloc, &[_]f32{ 0, 1 });
    try store.putSemanticCache(.{ .cache_key = "s:old", .query = "old", .response_json = "{\"answer\":\"old\"}", .embedding_json = e_old, .scopes_json = "[\"public\"]", .actor_id = "agent:a", .now_ms = 100, .max_entries = 2 });
    try store.putSemanticCache(.{ .cache_key = "s:middle", .query = "middle", .response_json = "{\"answer\":\"middle\"}", .embedding_json = e_new, .scopes_json = "[\"public\"]", .actor_id = "agent:a", .now_ms = 200, .max_entries = 2 });
    try store.putSemanticCache(.{ .cache_key = "s:other", .query = "other", .response_json = "{\"answer\":\"other\"}", .embedding_json = e_old, .scopes_json = "[\"public\"]", .actor_id = "agent:b", .now_ms = 200, .max_entries = 2 });
    _ = (try store.searchSemanticCache(alloc, .{ .embedding_json = e_old, .scopes_json = "[\"public\"]", .actor_id = "agent:a", .min_score = 0.99, .now_ms = 300 })).?;
    try store.putSemanticCache(.{ .cache_key = "s:new", .query = "new", .response_json = "{\"answer\":\"new\"}", .embedding_json = e_new, .scopes_json = "[\"public\"]", .actor_id = "agent:a", .now_ms = 400, .max_entries = 2 });

    try std.testing.expectEqual(@as(usize, 0), try store.clearSemanticCache(.{ .actor_id = "agent:a", .cache_key = "s:middle" }));
    try std.testing.expectEqual(@as(usize, 1), try store.clearSemanticCache(.{ .actor_id = "agent:a", .cache_key = "s:old" }));
    try std.testing.expectEqual(@as(usize, 1), try store.clearSemanticCache(.{ .actor_id = "agent:a", .cache_key = "s:new" }));
    try std.testing.expectEqual(@as(usize, 1), try store.clearSemanticCache(.{ .actor_id = "agent:b", .cache_key = "s:other" }));
}

test "sqlite embedding cache tracks hits and prunes lru entries" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const e1 = try vector_mod.embeddingToJson(alloc, &[_]f32{ 1, 0 });
    const e2 = try vector_mod.embeddingToJson(alloc, &[_]f32{ 0, 1 });
    const e3 = try vector_mod.embeddingToJson(alloc, &[_]f32{ 0.5, 0.5 });

    try store.putEmbeddingCache(.{ .cache_key = "embed:a", .provider = "local-deterministic", .model = "local", .dimensions = 2, .embedding_json = e1, .now_ms = 100, .max_entries = 2 });
    try store.putEmbeddingCache(.{ .cache_key = "embed:b", .provider = "local-deterministic", .model = "local", .dimensions = 2, .embedding_json = e2, .now_ms = 200, .max_entries = 2 });
    const hit = (try store.getEmbeddingCache(alloc, "embed:a", 300)).?;
    try std.testing.expectEqualStrings("local-deterministic", hit.provider);
    try std.testing.expectEqual(@as(usize, 2), hit.dimensions);
    try std.testing.expectEqual(@as(i64, 1), hit.hit_count);
    try std.testing.expectEqual(@as(i64, 300), hit.accessed_at_ms);

    const stats = try store.embeddingCacheStats();
    try std.testing.expectEqual(@as(usize, 2), stats.entries);
    try std.testing.expectEqual(@as(i64, 1), stats.hits);

    try store.putEmbeddingCache(.{ .cache_key = "embed:c", .provider = "local-deterministic", .model = "local", .dimensions = 2, .embedding_json = e3, .now_ms = 400, .max_entries = 2 });
    try std.testing.expect((try store.getEmbeddingCache(alloc, "embed:a", 500)) != null);
    try std.testing.expect((try store.getEmbeddingCache(alloc, "embed:b", 500)) == null);
    try std.testing.expect((try store.getEmbeddingCache(alloc, "embed:c", 500)) != null);
    try std.testing.expectEqual(@as(usize, 1), try store.clearEmbeddingCache(.{ .cache_key = "embed:a" }));
    try std.testing.expectEqual(@as(usize, 1), try store.clearEmbeddingCache(.{ .cache_key = "embed:c" }));
}
