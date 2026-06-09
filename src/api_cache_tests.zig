const std = @import("std");
const build_options = @import("build_options");
const api = @import("api.zig");
const api_cache_keys = @import("api_cache_keys.zig");
const providers = @import("providers.zig");
const store_mod = @import("store.zig");
const storage_routes = @import("storage_route.zig");
const vector_mod = @import("vector.zig");

const Context = api.Context;
const Store = store_mod.Store;
const handleRequest = api.handleRequest;

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

test "api cache endpoints reject malformed raw JSON roots" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ctx = Context{
        .allocator = alloc,
        .store = &store,
        .actor_scopes_json = "[\"public\",\"write:public\"]",
        .actor_capabilities_json = "[\"read\",\"write\"]",
    };

    const bad_response_cache = handleRequest(&ctx, "POST", "/v1/lifecycle/cache/put", "{\"key\":\"bad:response\",\"response\":[]}", "");
    try std.testing.expectEqualStrings("400 Bad Request", bad_response_cache.status);
    const missing_response_cache = handleRequest(&ctx, "POST", "/v1/lifecycle/cache/get", "{\"key\":\"bad:response\"}", "");
    try std.testing.expectEqualStrings("200 OK", missing_response_cache.status);
    try std.testing.expect(std.mem.indexOf(u8, missing_response_cache.body, "\"hit\":false") != null);

    const bad_semantic_response = handleRequest(&ctx, "POST", "/v1/lifecycle/semantic-cache/put", "{\"key\":\"bad:semantic-response\",\"query\":\"cache raw roots\",\"embedding\":[1,0],\"response\":[]}", "");
    try std.testing.expectEqualStrings("400 Bad Request", bad_semantic_response.status);

    const bad_semantic_embedding = handleRequest(&ctx, "POST", "/v1/lifecycle/semantic-cache/put", "{\"key\":\"bad:semantic-embedding\",\"query\":\"cache raw roots\",\"embedding\":{\"x\":1},\"response\":{\"answer\":\"bad\"}}", "");
    try std.testing.expectEqualStrings("400 Bad Request", bad_semantic_embedding.status);

    const bad_search_embedding = handleRequest(&ctx, "POST", "/v1/lifecycle/semantic-cache/search", "{\"embedding\":{\"x\":1}}", "");
    try std.testing.expectEqualStrings("400 Bad Request", bad_search_embedding.status);

    const accepted_response_cache = handleRequest(&ctx, "POST", "/v1/lifecycle/cache/put", "{\"key\":\"good:response\",\"response\":{\"answer\":\"cached\"}}", "");
    try std.testing.expectEqualStrings("200 OK", accepted_response_cache.status);
    const accepted_semantic = handleRequest(&ctx, "POST", "/v1/lifecycle/semantic-cache/put", "{\"key\":\"good:semantic\",\"query\":\"cache raw roots\",\"embedding\":[1,0],\"response\":{\"answer\":\"semantic cached\"}}", "");
    try std.testing.expectEqualStrings("200 OK", accepted_semantic.status);
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

test "api response cache canonicalizes cache controls and json field order" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = Context{ .allocator = alloc, .store = &store, .actor_id = "agent:cache-canonical", .actor_scopes_json = "[\"public\",\"write:public\",\"verify:public\"]" };

    const memory = handleRequest(&ctx, "POST", "/v1/memory-atoms", "{\"text\":\"canonical response cache needle\",\"scope\":\"public\",\"created_by\":\"human\",\"status\":\"verified\"}", "");
    try std.testing.expectEqualStrings("200 OK", memory.status);

    const first = handleRequest(&ctx, "POST", "/v1/search", "{\"query\":\"canonical response cache needle\",\"scopes\":[\"public\"],\"limit\":5,\"use_vector\":false,\"adaptive_retrieval\":false,\"cache_ttl_ms\":10000,\"cache_max_entries\":50,\"use_cache\":true}", "");
    try std.testing.expectEqualStrings("200 OK", first.status);
    try std.testing.expect(std.mem.indexOf(u8, first.body, "canonical response cache needle") != null);

    const second = handleRequest(&ctx, "POST", "/v1/search", "{\"use_cache\":true,\"adaptive_retrieval\":false,\"use_vector\":false,\"limit\":5,\"scopes\":[\"public\"],\"query\":\"canonical response cache needle\",\"cache_ttl_ms\":5000}", "");
    try std.testing.expectEqualStrings("200 OK", second.status);
    const stats = handleRequest(&ctx, "GET", "/v1/lifecycle/cache/stats", "", "");
    try std.testing.expectEqualStrings("200 OK", stats.status);
    try std.testing.expect(std.mem.indexOf(u8, stats.body, "\"hits\":1") != null);
}

test "api response cache revision changes after knowledge writes" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = Context{ .allocator = alloc, .store = &store, .actor_id = "agent:cache-revision", .actor_scopes_json = "[\"public\",\"write:public\",\"verify:public\"]" };

    const first_memory = handleRequest(&ctx, "POST", "/v1/memory-atoms", "{\"text\":\"revision cache needle first-only\",\"scope\":\"public\",\"created_by\":\"human\",\"status\":\"verified\"}", "");
    try std.testing.expectEqualStrings("200 OK", first_memory.status);
    const first = handleRequest(&ctx, "POST", "/v1/search", "{\"query\":\"revision cache needle\",\"scopes\":[\"public\"],\"limit\":10,\"use_vector\":false,\"adaptive_retrieval\":false,\"cache_ttl_ms\":10000}", "");
    try std.testing.expectEqualStrings("200 OK", first.status);
    try std.testing.expect(std.mem.indexOf(u8, first.body, "first-only") != null);

    const second_memory = handleRequest(&ctx, "POST", "/v1/memory-atoms", "{\"text\":\"revision cache needle second-only\",\"scope\":\"public\",\"created_by\":\"human\",\"status\":\"verified\"}", "");
    try std.testing.expectEqualStrings("200 OK", second_memory.status);
    const second = handleRequest(&ctx, "POST", "/v1/search", "{\"adaptive_retrieval\":false,\"use_vector\":false,\"limit\":10,\"scopes\":[\"public\"],\"query\":\"revision cache needle\"}", "");
    try std.testing.expectEqualStrings("200 OK", second.status);
    try std.testing.expect(std.mem.indexOf(u8, second.body, "first-only") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.body, "second-only") != null);
    const stats = handleRequest(&ctx, "GET", "/v1/lifecycle/cache/stats", "", "");
    try std.testing.expectEqualStrings("200 OK", stats.status);
    try std.testing.expect(std.mem.indexOf(u8, stats.body, "\"hits\":0") != null);
}

test "api ask semantic cache is isolated by storage route" {
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
        \\{"agent-route-cache":{"actor_id":"agent:route-cache","scopes":["public","write:public"],"capabilities":["read","write"]}}
    ;
    var ctx = Context{ .allocator = alloc, .store = &store, .token_principals_json = principals };
    const put_raw = "PUT /v1/agent-memory/route.semantic HTTP/1.1\r\nAuthorization: Bearer agent-route-cache\r\n\r\n{}";
    const ask_raw = "POST /v1/ask HTTP/1.1\r\nAuthorization: Bearer agent-route-cache\r\n\r\n{}";

    const scratch_put = handleRequest(&ctx, "PUT", "/v1/agent-memory/route.semantic", "{\"content\":\"Route semantic cache scratch only\",\"scope\":\"public\",\"store\":\"scratch\"}", put_raw);
    try std.testing.expectEqualStrings("200 OK", scratch_put.status);
    const archive_put = handleRequest(&ctx, "PUT", "/v1/agent-memory/route.semantic", "{\"content\":\"Route semantic cache archive only\",\"scope\":\"public\",\"store\":\"archive\"}", put_raw);
    try std.testing.expectEqualStrings("200 OK", archive_put.status);

    const scratch_ask = handleRequest(&ctx, "POST", "/v1/ask", "{\"query\":\"Route semantic cache\",\"scope\":\"public\",\"store\":\"scratch\",\"use_semantic_cache\":true,\"cache_ttl_ms\":10000,\"adaptive_retrieval\":false}", ask_raw);
    try std.testing.expectEqualStrings("200 OK", scratch_ask.status);
    try std.testing.expect(std.mem.indexOf(u8, scratch_ask.body, "scratch only") != null);
    try std.testing.expect(std.mem.indexOf(u8, scratch_ask.body, "archive only") == null);

    const archive_ask = handleRequest(&ctx, "POST", "/v1/ask", "{\"query\":\"Route semantic cache\",\"scope\":\"public\",\"store\":\"archive\",\"use_semantic_cache\":true,\"adaptive_retrieval\":false}", ask_raw);
    try std.testing.expectEqualStrings("200 OK", archive_ask.status);
    try std.testing.expect(std.mem.indexOf(u8, archive_ask.body, "archive only") != null);
    try std.testing.expect(std.mem.indexOf(u8, archive_ask.body, "scratch only") == null);
}

test "api retrieval surfaces honor query storage selectors and cache by route" {
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
        \\{"agent-route-query":{"actor_id":"agent:route-query","scopes":["public","write:public"],"capabilities":["read","write","export"]}}
    ;
    var ctx = Context{ .allocator = alloc, .store = &store, .token_principals_json = principals };
    const raw = "PUT /v1/agent-memory/route.query HTTP/1.1\r\nAuthorization: Bearer agent-route-query\r\n\r\n{}";

    const scratch_put = handleRequest(&ctx, "PUT", "/v1/agent-memory/route.query", "{\"content\":\"Route query selector scratch only\",\"scope\":\"public\",\"store\":\"scratch\"}", raw);
    try std.testing.expectEqualStrings("200 OK", scratch_put.status);
    const archive_put = handleRequest(&ctx, "PUT", "/v1/agent-memory/route.query", "{\"content\":\"Route query selector archive only\",\"scope\":\"public\",\"store\":\"archive\"}", raw);
    try std.testing.expectEqualStrings("200 OK", archive_put.status);

    const search_body = "{\"query\":\"Route query selector\",\"scope\":\"public\",\"use_vector\":false,\"use_temporal_decay\":false,\"use_mmr\":false,\"adaptive_retrieval\":false,\"cache_ttl_ms\":10000,\"limit\":10}";
    const scratch_search = handleRequest(&ctx, "POST", "/v1/search?store=scratch", search_body, "POST /v1/search?store=scratch HTTP/1.1\r\nAuthorization: Bearer agent-route-query\r\n\r\n{}");
    try std.testing.expectEqualStrings("200 OK", scratch_search.status);
    try std.testing.expect(std.mem.indexOf(u8, scratch_search.body, "scratch only") != null);
    try std.testing.expect(std.mem.indexOf(u8, scratch_search.body, "archive only") == null);
    const archive_search = handleRequest(&ctx, "POST", "/v1/search?store=archive", search_body, "POST /v1/search?store=archive HTTP/1.1\r\nAuthorization: Bearer agent-route-query\r\n\r\n{}");
    try std.testing.expectEqualStrings("200 OK", archive_search.status);
    try std.testing.expect(std.mem.indexOf(u8, archive_search.body, "archive only") != null);
    try std.testing.expect(std.mem.indexOf(u8, archive_search.body, "scratch only") == null);

    const scratch_retrieval = handleRequest(&ctx, "POST", "/v1/retrieval/search?store=scratch", search_body, "POST /v1/retrieval/search?store=scratch HTTP/1.1\r\nAuthorization: Bearer agent-route-query\r\n\r\n{}");
    try std.testing.expectEqualStrings("200 OK", scratch_retrieval.status);
    try std.testing.expect(std.mem.indexOf(u8, scratch_retrieval.body, "scratch only") != null);
    try std.testing.expect(std.mem.indexOf(u8, scratch_retrieval.body, "archive only") == null);

    const ask_body = "{\"query\":\"Route query selector\",\"scope\":\"public\",\"use_vector\":false,\"use_temporal_decay\":false,\"use_mmr\":false,\"adaptive_retrieval\":false,\"cache_ttl_ms\":10000}";
    const scratch_ask = handleRequest(&ctx, "POST", "/v1/ask?store=scratch", ask_body, "POST /v1/ask?store=scratch HTTP/1.1\r\nAuthorization: Bearer agent-route-query\r\n\r\n{}");
    try std.testing.expectEqualStrings("200 OK", scratch_ask.status);
    try std.testing.expect(std.mem.indexOf(u8, scratch_ask.body, "scratch only") != null);
    try std.testing.expect(std.mem.indexOf(u8, scratch_ask.body, "archive only") == null);
    const archive_ask = handleRequest(&ctx, "POST", "/v1/ask?store=archive", ask_body, "POST /v1/ask?store=archive HTTP/1.1\r\nAuthorization: Bearer agent-route-query\r\n\r\n{}");
    try std.testing.expectEqualStrings("200 OK", archive_ask.status);
    try std.testing.expect(std.mem.indexOf(u8, archive_ask.body, "archive only") != null);
    try std.testing.expect(std.mem.indexOf(u8, archive_ask.body, "scratch only") == null);

    const context_body = "{\"task\":\"Route query selector\",\"scope\":\"public\",\"use_vector\":false,\"use_temporal_decay\":false,\"use_mmr\":false,\"adaptive_retrieval\":false,\"persist\":false,\"limit\":10}";
    const archive_context = handleRequest(&ctx, "POST", "/v1/context-packs?store=archive", context_body, "POST /v1/context-packs?store=archive HTTP/1.1\r\nAuthorization: Bearer agent-route-query\r\n\r\n{}");
    try std.testing.expectEqualStrings("200 OK", archive_context.status);
    try std.testing.expect(std.mem.indexOf(u8, archive_context.body, "archive only") != null);
    try std.testing.expect(std.mem.indexOf(u8, archive_context.body, "scratch only") == null);

    const snapshot_body = "{\"query\":\"Route query selector\",\"scope\":\"public\",\"use_vector\":false,\"limit\":10,\"persist\":false}";
    const archive_snapshot = handleRequest(&ctx, "POST", "/v1/lifecycle/snapshot/export?store=archive", snapshot_body, "POST /v1/lifecycle/snapshot/export?store=archive HTTP/1.1\r\nAuthorization: Bearer agent-route-query\r\n\r\n{}");
    try std.testing.expectEqualStrings("200 OK", archive_snapshot.status);
    try std.testing.expect(std.mem.indexOf(u8, archive_snapshot.body, "archive only") != null);
    try std.testing.expect(std.mem.indexOf(u8, archive_snapshot.body, "scratch only") == null);
}

test "api ask semantic cache is isolated by retrieval controls" {
    var store = try Store.initSQLiteWithOptions(std.testing.allocator, ":memory:", .{
        .agent_memory = .{ .backend = .memory_lru },
    });
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const principals =
        \\{"agent-retrieval-cache":{"actor_id":"agent:retrieval-cache","scopes":["public","write:public"],"capabilities":["read","write"]}}
    ;
    var ctx = Context{ .allocator = alloc, .store = &store, .token_principals_json = principals };
    const put_raw = "PUT /v1/agent-memory/retrieval.semantic HTTP/1.1\r\nAuthorization: Bearer agent-retrieval-cache\r\n\r\n{}";
    const ask_raw = "POST /v1/ask HTTP/1.1\r\nAuthorization: Bearer agent-retrieval-cache\r\n\r\n{}";

    const put = handleRequest(&ctx, "PUT", "/v1/agent-memory/retrieval.semantic", "{\"content\":\"Retrieval semantic cache visible result\",\"scope\":\"public\"}", put_raw);
    try std.testing.expectEqualStrings("200 OK", put.status);

    const cached_low_relevance = handleRequest(&ctx, "POST", "/v1/ask", "{\"query\":\"Retrieval semantic cache\",\"scope\":\"public\",\"use_semantic_cache\":true,\"cache_ttl_ms\":10000,\"adaptive_retrieval\":false,\"min_relevance\":0}", ask_raw);
    try std.testing.expectEqualStrings("200 OK", cached_low_relevance.status);
    try std.testing.expect(std.mem.indexOf(u8, cached_low_relevance.body, "visible result") != null);

    const strict_relevance = handleRequest(&ctx, "POST", "/v1/ask", "{\"query\":\"Retrieval semantic cache\",\"scope\":\"public\",\"use_semantic_cache\":true,\"adaptive_retrieval\":false,\"min_relevance\":999}", ask_raw);
    try std.testing.expectEqualStrings("200 OK", strict_relevance.status);
    try std.testing.expect(std.mem.indexOf(u8, strict_relevance.body, "visible result") == null);
    try std.testing.expect(std.mem.indexOf(u8, strict_relevance.body, "I don't know") != null);
}

test "api ask semantic cache is isolated by graph command retrieval" {
    if (!build_options.enable_engine_kg) return error.SkipZigTest;

    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    _ = try store.createMemoryAtom(alloc, .{ .text = "Plain semantic cache only result", .scope = "public", .created_by = "human", .status = "verified" });
    const a = try store.resolveEntity(alloc, .{ .entity_type = "project", .name = "Graph Cache A", .scope = "public" });
    const b = try store.resolveEntity(alloc, .{ .entity_type = "service", .name = "Graph Cache B", .scope = "public" });
    const c = try store.resolveEntity(alloc, .{ .entity_type = "feature", .name = "Graph Cache C", .scope = "public" });
    _ = try store.createRelation(alloc, .{ .from_entity_id = a.id, .relation_type = "depends_on", .to_entity_id = b.id, .scope = "public" });
    _ = try store.createRelation(alloc, .{ .from_entity_id = b.id, .relation_type = "implements", .to_entity_id = c.id, .scope = "public" });

    var ctx = Context{ .allocator = alloc, .store = &store };
    const cached_plain = handleRequest(&ctx, "POST", "/v1/ask", "{\"query\":\"Plain semantic cache only\",\"scope\":\"public\",\"use_semantic_cache\":true,\"cache_ttl_ms\":10000,\"adaptive_retrieval\":false}", "");
    try std.testing.expectEqualStrings("200 OK", cached_plain.status);
    try std.testing.expect(std.mem.indexOf(u8, cached_plain.body, "Plain semantic cache only result") != null);

    const graph_body = try std.fmt.allocPrint(alloc, "{{\"query\":\"kg:path:{s}:{s}:3\",\"scope\":\"public\",\"use_semantic_cache\":true,\"semantic_cache_min_score\":0,\"adaptive_retrieval\":false}}", .{ a.id, c.id });
    const graph_ask = handleRequest(&ctx, "POST", "/v1/ask", graph_body, "");
    try std.testing.expectEqualStrings("200 OK", graph_ask.status);
    try std.testing.expect(std.mem.indexOf(u8, graph_ask.body, "Graph Cache C") != null);
    try std.testing.expect(std.mem.indexOf(u8, graph_ask.body, "Plain semantic cache only result") == null);

    const invalid_graph = handleRequest(&ctx, "POST", "/v1/ask", "{\"query\":\"kg:path:a:b\",\"scope\":\"public\",\"use_semantic_cache\":true,\"semantic_cache_min_score\":0,\"adaptive_retrieval\":false}", "");
    try std.testing.expectEqualStrings("400 Bad Request", invalid_graph.status);
}

test "api ask semantic cache works when vector retrieval is disabled" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    _ = try store.createMemoryAtom(alloc, .{ .text = "No vector semantic cached answer", .scope = "public", .created_by = "human", .status = "verified" });
    var ctx = Context{ .allocator = alloc, .store = &store };

    const first = handleRequest(&ctx, "POST", "/v1/ask", "{\"query\":\"No vector semantic cached\",\"scope\":\"public\",\"use_vector\":false,\"use_semantic_cache\":true,\"cache_ttl_ms\":10000,\"adaptive_retrieval\":false}", "");
    try std.testing.expectEqualStrings("200 OK", first.status);
    try std.testing.expect(std.mem.indexOf(u8, first.body, "No vector semantic cached answer") != null);

    const second = handleRequest(&ctx, "POST", "/v1/ask", "{\"query\":\"Different no vector cache wording\",\"scope\":\"public\",\"use_vector\":false,\"use_semantic_cache\":true,\"semantic_cache_min_score\":0,\"adaptive_retrieval\":false}", "");
    try std.testing.expectEqualStrings("200 OK", second.status);
    try std.testing.expect(std.mem.indexOf(u8, second.body, "No vector semantic cached answer") != null);
}

test "api search semantic cache works when vector retrieval is disabled" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    _ = try store.createMemoryAtom(alloc, .{ .text = "Search semantic cached source result", .scope = "public", .created_by = "human", .status = "verified" });
    var ctx = Context{ .allocator = alloc, .store = &store };

    const first = handleRequest(&ctx, "POST", "/v1/search", "{\"query\":\"Search semantic cached source\",\"scope\":\"public\",\"use_vector\":false,\"use_semantic_cache\":true,\"cache_ttl_ms\":10000,\"adaptive_retrieval\":false}", "");
    try std.testing.expectEqualStrings("200 OK", first.status);
    try std.testing.expect(std.mem.indexOf(u8, first.body, "Search semantic cached source result") != null);

    const second = handleRequest(&ctx, "POST", "/v1/search", "{\"query\":\"Different search cache wording\",\"scope\":\"public\",\"use_vector\":false,\"use_semantic_cache\":true,\"semantic_cache_min_score\":0,\"adaptive_retrieval\":false}", "");
    try std.testing.expectEqualStrings("200 OK", second.status);
    try std.testing.expect(std.mem.indexOf(u8, second.body, "Search semantic cached source result") != null);
}

test "api semantic cache put uses configured embedding route hints" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const routes = [_]providers.EmbeddingRouteConfig{.{
        .hint = "semantic",
        .endpoint = .{ .provider = .local_deterministic, .dimensions = 3, .prefer_endpoint_dimensions = true },
    }};
    var ctx = Context{
        .allocator = alloc,
        .store = &store,
        .provider = .{
            .embedding = .{
                .base_url = "://bad-provider-url",
                .model = "hint:semantic",
                .dimensions = 64,
                .routes = &routes,
                .timeout_secs = 1,
            },
        },
    };

    const query = "route hinted semantic cache";
    const put_resp = handleRequest(&ctx, "POST", "/v1/lifecycle/semantic-cache/put", "{\"key\":\"semantic:route\",\"query\":\"route hinted semantic cache\",\"response\":{\"answer\":\"route cache hit\"},\"ttl_ms\":10000}", "");
    try std.testing.expectEqualStrings("200 OK", put_resp.status);

    const embedding = try vector_mod.deterministicEmbedding(alloc, query, 3);
    const embedding_json = try vector_mod.embeddingToJson(alloc, embedding);
    const search_body = try std.fmt.allocPrint(alloc, "{{\"embedding\":{s},\"min_score\":0.99}}", .{embedding_json});
    const search_resp = handleRequest(&ctx, "POST", "/v1/lifecycle/semantic-cache/search", search_body, "");
    try std.testing.expectEqualStrings("200 OK", search_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, search_resp.body, "\"hit\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, search_resp.body, "route cache hit") != null);
}

test "api response and semantic cache salts include LLM rerank config" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ctx = Context{
        .allocator = alloc,
        .store = &store,
        .actor_id = "agent:ranker",
        .provider = .{
            .completion = .{
                .base_url = "https://llm.example.test",
                .model = "ranker-a",
            },
        },
    };
    var input = store_mod.SearchInput{
        .query = "rank context",
        .scopes_json = "[\"public\"]",
        .allow_reranker = true,
        .rerank_candidate_limit = 5,
        .strict_reranker = true,
    };

    const key_a = try api_cache_keys.responseKey(&ctx, "search", "{\"query\":\"rank context\",\"allow_reranker\":true}", input);
    defer alloc.free(key_a);
    const semantic_a = try api_cache_keys.semanticPrefix(&ctx, "ask", input, false, false, "none");
    defer alloc.free(semantic_a);

    ctx.provider.completion.model = "ranker-b";
    const key_model_b = try api_cache_keys.responseKey(&ctx, "search", "{\"query\":\"rank context\",\"allow_reranker\":true}", input);
    defer alloc.free(key_model_b);
    const semantic_model_b = try api_cache_keys.semanticPrefix(&ctx, "ask", input, false, false, "none");
    defer alloc.free(semantic_model_b);
    try std.testing.expect(!std.mem.eql(u8, key_a, key_model_b));
    try std.testing.expect(!std.mem.eql(u8, semantic_a, semantic_model_b));

    ctx.provider.completion.model = "ranker-a";
    input.rerank_candidate_limit = 6;
    const key_limit_b = try api_cache_keys.responseKey(&ctx, "search", "{\"query\":\"rank context\",\"allow_reranker\":true}", input);
    defer alloc.free(key_limit_b);
    try std.testing.expect(!std.mem.eql(u8, key_a, key_limit_b));
}

test "api automatic cache salts include capability storage session and rollout shape" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ctx = Context{
        .allocator = alloc,
        .store = &store,
        .actor_id = "agent:cache-salt",
        .actor_scopes_json = "[\"public\"]",
        .actor_capabilities_json = "[\"read\"]",
    };
    const input = store_mod.SearchInput{
        .query = "cache salt context",
        .scopes_json = "[\"public\"]",
        .limit = 2,
        .offset = 1,
        .use_vector = false,
        .adaptive_retrieval = false,
    };

    const base_key = try api_cache_keys.responseKey(&ctx, "search", "{\"query\":\"cache salt context\"}", input);
    defer alloc.free(base_key);
    const base_semantic = try api_cache_keys.semanticPrefix(&ctx, "search", input, false, false, "none");
    defer alloc.free(base_semantic);

    ctx.actor_capabilities_json = "[\"read\",\"verify\"]";
    const capability_key = try api_cache_keys.responseKey(&ctx, "search", "{\"query\":\"cache salt context\"}", input);
    defer alloc.free(capability_key);
    const capability_semantic = try api_cache_keys.semanticPrefix(&ctx, "search", input, false, false, "none");
    defer alloc.free(capability_semantic);
    try std.testing.expect(!std.mem.eql(u8, base_key, capability_key));
    try std.testing.expect(!std.mem.eql(u8, base_semantic, capability_semantic));

    ctx.actor_capabilities_json = "[\"read\"]";
    var storage_input = input;
    storage_input.agent_memory_route = storage_routes.Route.parse("native");
    const storage_key = try api_cache_keys.responseKey(&ctx, "search", "{\"query\":\"cache salt context\"}", storage_input);
    defer alloc.free(storage_key);
    const storage_semantic = try api_cache_keys.semanticPrefix(&ctx, "search", storage_input, false, false, "none");
    defer alloc.free(storage_semantic);
    try std.testing.expect(!std.mem.eql(u8, base_key, storage_key));
    try std.testing.expect(!std.mem.eql(u8, base_semantic, storage_semantic));

    var session_input = input;
    session_input.include_sessions = true;
    session_input.session_id = "session:cache-salt";
    const session_key = try api_cache_keys.responseKey(&ctx, "search", "{\"query\":\"cache salt context\"}", session_input);
    defer alloc.free(session_key);
    const session_semantic = try api_cache_keys.semanticPrefix(&ctx, "search", session_input, false, false, "none");
    defer alloc.free(session_semantic);
    try std.testing.expect(!std.mem.eql(u8, base_key, session_key));
    try std.testing.expect(!std.mem.eql(u8, base_semantic, session_semantic));

    var rollout_input = input;
    rollout_input.rollout_vector_requested = false;
    rollout_input.rollout_shadow_vector = true;
    const rollout_key = try api_cache_keys.responseKey(&ctx, "search", "{\"query\":\"cache salt context\"}", rollout_input);
    defer alloc.free(rollout_key);
    const rollout_semantic = try api_cache_keys.semanticPrefix(&ctx, "search", rollout_input, false, false, "none");
    defer alloc.free(rollout_semantic);
    try std.testing.expect(!std.mem.eql(u8, base_key, rollout_key));
    try std.testing.expect(!std.mem.eql(u8, base_semantic, rollout_semantic));
}
