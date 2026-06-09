const std = @import("std");

const digest = @import("digest.zig");
const json = @import("json_util.zig");
const store_mod = @import("store.zig");
const storage_routes = @import("storage_route.zig");

pub const RequestSalt = struct {
    actor_id: []const u8,
    actor_capabilities_json: []const u8,
    revision: []const u8,
    embedding_provider: []const u8,
    embedding_model: ?[]const u8 = null,
    embedding_base_url: ?[]const u8 = null,
    embedding_dimensions: usize,
    embedding_send_dimensions: bool,
    embedding_route_count: usize = 0,
    embedding_fallback_count: usize = 0,
    llm_model: ?[]const u8 = null,
    llm_base_url: ?[]const u8 = null,
};

pub const ResponseKeyInput = struct {
    allocator: std.mem.Allocator,
    namespace: []const u8,
    body: []const u8,
    search: store_mod.SearchInput,
    salt: RequestSalt,
};

pub const SemanticPrefixInput = struct {
    allocator: std.mem.Allocator,
    namespace: []const u8,
    search: store_mod.SearchInput,
    salt: RequestSalt,
    include_conflicts: bool,
    use_llm: bool,
    graph_cache_salt: []const u8,
};

pub fn responseKey(input: ResponseKeyInput) ![]u8 {
    const allocator = input.allocator;
    var route_json: std.ArrayListUnmanaged(u8) = .empty;
    defer route_json.deinit(allocator);
    try storage_routes.appendRouteJson(allocator, &route_json, input.search.agent_memory_route);
    const canonical_body = try canonicalResponseBody(allocator, input.body);
    defer allocator.free(canonical_body);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(input.namespace);
    hasher.update("\n");
    hasher.update(input.salt.actor_id);
    hasher.update("\n");
    hasher.update(input.search.scopes_json);
    hasher.update("\n");
    hasher.update(input.salt.actor_capabilities_json);
    hasher.update("\n");
    hasher.update(route_json.items);
    hasher.update("\n");
    hasher.update("query=");
    hasher.update(input.search.query);
    hasher.update("\n");
    hasher.update(if (input.search.use_vector) "use_vector=1" else "use_vector=0");
    hasher.update("\n");
    const paging_text = try std.fmt.allocPrint(allocator, "limit={d};offset={d}", .{ input.search.limit, input.search.offset });
    defer allocator.free(paging_text);
    hasher.update(paging_text);
    hasher.update("\n");
    hasher.update(if (input.search.include_sessions) "include_sessions=1" else "include_sessions=0");
    hasher.update("\n");
    if (input.search.session_id) |session_id| hasher.update(session_id);
    hasher.update("\n");
    hasher.update(if (input.search.include_deprecated) "include_deprecated=1" else "include_deprecated=0");
    hasher.update("\n");
    const adaptive_text = try std.fmt.allocPrint(allocator, "adaptive={s};adaptive_keyword_max_tokens={d};adaptive_vector_min_tokens={d}", .{ if (input.search.adaptive_retrieval) "1" else "0", input.search.adaptive_keyword_max_tokens, input.search.adaptive_vector_min_tokens });
    defer allocator.free(adaptive_text);
    hasher.update(adaptive_text);
    hasher.update("\n");
    hasher.update(if (input.search.strict_vector) "strict_vector=1" else "strict_vector=0");
    hasher.update("\n");
    hasher.update(if (input.search.use_temporal_decay) "temporal=1" else "temporal=0");
    hasher.update("\n");
    hasher.update(if (input.search.use_mmr) "mmr=1" else "mmr=0");
    hasher.update("\n");
    const mmr_text = try std.fmt.allocPrint(allocator, "mmr_lambda={d:.12};mmr_candidate_multiplier={d}", .{ input.search.mmr_lambda, input.search.mmr_candidate_multiplier });
    defer allocator.free(mmr_text);
    hasher.update(mmr_text);
    hasher.update("\n");
    const rrf_text = try std.fmt.allocPrint(allocator, "rrf_k={d:.12};rrf_weight={d:.12};raw_score_weight={d:.12};rrf_window_multiplier={d}", .{ input.search.rrf_k, input.search.rrf_weight, input.search.raw_score_weight, input.search.rrf_window_multiplier });
    defer allocator.free(rrf_text);
    hasher.update(rrf_text);
    hasher.update("\n");
    const relevance_text = try std.fmt.allocPrint(allocator, "min_relevance={d:.12};half_life_days={d:.12}", .{ input.search.min_relevance, input.search.half_life_days });
    defer allocator.free(relevance_text);
    hasher.update(relevance_text);
    hasher.update("\n");
    try appendRerankSalt(allocator, &hasher, input.search, input.salt);
    hasher.update("\n");
    const embedding_text = try std.fmt.allocPrint(allocator, "embedding_provider={s};embedding_dimensions={d}", .{ input.search.query_embedding_provider, input.search.embedding_dimensions });
    defer allocator.free(embedding_text);
    hasher.update(embedding_text);
    hasher.update("\n");
    try appendEmbeddingSalt(allocator, &hasher, input.salt);
    hasher.update("\n");
    hasher.update(input.search.rollout_mode.name());
    hasher.update("\n");
    hasher.update(input.search.rollout_decision.name());
    hasher.update("\n");
    hasher.update(input.search.rollout_reason);
    hasher.update("\n");
    const rollout_bucket = try std.fmt.allocPrint(allocator, "rollout_bucket={d}", .{input.search.rollout_bucket});
    defer allocator.free(rollout_bucket);
    hasher.update(rollout_bucket);
    hasher.update("\n");
    hasher.update(if (input.search.rollout_vector_requested) "rollout_vector_requested=1" else "rollout_vector_requested=0");
    hasher.update("\n");
    hasher.update(if (input.search.rollout_shadow_vector) "rollout_shadow_vector=1" else "rollout_shadow_vector=0");
    hasher.update("\n");
    hasher.update(input.salt.revision);
    hasher.update("\n");
    hasher.update(canonical_body);

    const hex = digest.finalSha256Hex(&hasher);
    return std.fmt.allocPrint(allocator, "auto:{s}:sha256:{s}", .{ input.namespace, hex[0..] });
}

pub fn semanticPrefix(input: SemanticPrefixInput) ![]u8 {
    const allocator = input.allocator;
    var route_json: std.ArrayListUnmanaged(u8) = .empty;
    defer route_json.deinit(allocator);
    try storage_routes.appendRouteJson(allocator, &route_json, input.search.agent_memory_route);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(input.namespace);
    hasher.update("\n");
    hasher.update(input.salt.actor_id);
    hasher.update("\n");
    hasher.update(input.search.scopes_json);
    hasher.update("\n");
    hasher.update(input.salt.actor_capabilities_json);
    hasher.update("\n");
    hasher.update(route_json.items);
    hasher.update("\n");
    const limit_text = try std.fmt.allocPrint(allocator, "limit={d};offset={d}", .{ input.search.limit, input.search.offset });
    defer allocator.free(limit_text);
    hasher.update(limit_text);
    hasher.update("\n");
    hasher.update(if (input.search.include_sessions) "include_sessions=1" else "include_sessions=0");
    hasher.update("\n");
    hasher.update(if (input.search.include_deprecated) "include_deprecated=1" else "include_deprecated=0");
    hasher.update("\n");
    hasher.update(if (input.search.adaptive_retrieval) "adaptive=1" else "adaptive=0");
    hasher.update("\n");
    const adaptive_text = try std.fmt.allocPrint(allocator, "adaptive_keyword_max_tokens={d};adaptive_vector_min_tokens={d}", .{ input.search.adaptive_keyword_max_tokens, input.search.adaptive_vector_min_tokens });
    defer allocator.free(adaptive_text);
    hasher.update(adaptive_text);
    hasher.update("\n");
    hasher.update(if (input.search.strict_vector) "strict_vector=1" else "strict_vector=0");
    hasher.update("\n");
    hasher.update(if (input.search.use_vector) "use_vector=1" else "use_vector=0");
    hasher.update("\n");
    hasher.update(input.search.rollout_mode.name());
    hasher.update("\n");
    hasher.update(input.search.rollout_decision.name());
    hasher.update("\n");
    hasher.update(input.search.rollout_reason);
    hasher.update("\n");
    const rollout_bucket = try std.fmt.allocPrint(allocator, "rollout_bucket={d}", .{input.search.rollout_bucket});
    defer allocator.free(rollout_bucket);
    hasher.update(rollout_bucket);
    hasher.update("\n");
    hasher.update(if (input.search.rollout_vector_requested) "rollout_vector_requested=1" else "rollout_vector_requested=0");
    hasher.update("\n");
    hasher.update(if (input.search.rollout_shadow_vector) "rollout_shadow_vector=1" else "rollout_shadow_vector=0");
    hasher.update("\n");
    hasher.update(if (input.search.use_temporal_decay) "temporal=1" else "temporal=0");
    hasher.update("\n");
    hasher.update(if (input.search.use_mmr) "mmr=1" else "mmr=0");
    hasher.update("\n");
    const mmr_text = try std.fmt.allocPrint(allocator, "mmr_lambda={d:.12};mmr_candidate_multiplier={d}", .{ input.search.mmr_lambda, input.search.mmr_candidate_multiplier });
    defer allocator.free(mmr_text);
    hasher.update(mmr_text);
    hasher.update("\n");
    try appendRerankSalt(allocator, &hasher, input.search, input.salt);
    hasher.update("\n");
    hasher.update(if (input.include_conflicts) "conflicts=1" else "conflicts=0");
    hasher.update("\n");
    hasher.update(if (input.use_llm) "llm=1" else "llm=0");
    hasher.update("\n");
    const relevance_text = try std.fmt.allocPrint(allocator, "min_relevance={d:.12}", .{input.search.min_relevance});
    defer allocator.free(relevance_text);
    hasher.update(relevance_text);
    hasher.update("\n");
    const half_life_text = try std.fmt.allocPrint(allocator, "half_life_days={d:.12}", .{input.search.half_life_days});
    defer allocator.free(half_life_text);
    hasher.update(half_life_text);
    hasher.update("\n");
    const rrf_text = try std.fmt.allocPrint(allocator, "rrf_k={d:.12};rrf_weight={d:.12};raw_score_weight={d:.12};rrf_window_multiplier={d}", .{ input.search.rrf_k, input.search.rrf_weight, input.search.raw_score_weight, input.search.rrf_window_multiplier });
    defer allocator.free(rrf_text);
    hasher.update(rrf_text);
    hasher.update("\n");
    const dimensions_text = try std.fmt.allocPrint(allocator, "embedding_dimensions={d}", .{input.search.embedding_dimensions});
    defer allocator.free(dimensions_text);
    hasher.update(dimensions_text);
    hasher.update("\n");
    hasher.update("embedding_provider=");
    hasher.update(input.search.query_embedding_provider);
    hasher.update("\n");
    try appendEmbeddingSalt(allocator, &hasher, input.salt);
    hasher.update("\n");
    hasher.update("graph=");
    hasher.update(input.graph_cache_salt);
    hasher.update("\n");
    hasher.update("revision=");
    hasher.update(input.salt.revision);
    hasher.update("\n");
    if (input.search.session_id) |session_id| hasher.update(session_id);
    const hex = digest.finalSha256Hex(&hasher);
    return std.fmt.allocPrint(allocator, "semantic:{s}:sha256:{s}:", .{ input.namespace, hex[0..] });
}

pub fn canonicalResponseBody(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return allocator.dupe(u8, body);
    defer parsed.deinit();
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    switch (parsed.value) {
        .object => |object| try appendCanonicalResponseCacheObject(&out, allocator, object),
        else => try appendCanonicalResponseCacheJsonValue(&out, allocator, parsed.value),
    }
    return out.toOwnedSlice(allocator);
}

fn responseCacheControlField(name: []const u8) bool {
    const controls = [_][]const u8{
        "use_cache",
        "cache_ttl_ms",
        "cache_max_entries",
        "ttl_ms",
        "max_entries",
        "cache_key",
        "use_semantic_cache",
        "semantic_cache_min_score",
        "semantic_cache_candidate_limit",
        "use_embedding_cache",
        "embedding_cache_max_entries",
        "embedding_max_entries",
    };
    for (controls) |field| {
        if (std.mem.eql(u8, name, field)) return true;
    }
    return false;
}

fn responseCacheNormalizedSearchField(name: []const u8) bool {
    if (storage_routes.isSelectorField(name)) return true;
    const normalized = [_][]const u8{
        "query",
        "q",
        "question",
        "scope",
        "scopes",
        "permissions",
        "limit",
        "offset",
        "include_deprecated",
        "include_sessions",
        "session_id",
        "use_vector",
        "strict_vector",
        "adaptive_retrieval",
        "adaptive_keyword_max_tokens",
        "adaptive_vector_min_tokens",
        "use_temporal_decay",
        "use_mmr",
        "mmr_lambda",
        "mmr_candidate_multiplier",
        "allow_reranker",
        "rerank_candidate_limit",
        "strict_reranker",
        "min_relevance",
        "half_life_days",
        "rrf_k",
        "rrf_weight",
        "raw_score_weight",
        "rrf_window_multiplier",
        "embedding_dimensions",
    };
    for (normalized) |field| {
        if (std.mem.eql(u8, name, field)) return true;
    }
    return false;
}

fn appendCanonicalResponseCacheJsonValue(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: std.json.Value) anyerror!void {
    switch (value) {
        .null => try out.appendSlice(allocator, "null"),
        .bool => |inner| try out.appendSlice(allocator, if (inner) "true" else "false"),
        .integer => |inner| try out.print(allocator, "{d}", .{inner}),
        .float => |inner| try out.print(allocator, "{d}", .{inner}),
        .number_string => |inner| try out.appendSlice(allocator, inner),
        .string => |inner| try json.appendString(out, allocator, inner),
        .array => |inner| {
            try out.append(allocator, '[');
            for (inner.items, 0..) |item, i| {
                if (i > 0) try out.append(allocator, ',');
                try appendCanonicalResponseCacheJsonValue(out, allocator, item);
            }
            try out.append(allocator, ']');
        },
        .object => |inner| try appendCanonicalJsonObject(out, allocator, inner, false),
    }
}

fn appendCanonicalResponseCacheObject(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, object: std.json.ObjectMap) anyerror!void {
    return appendCanonicalJsonObject(out, allocator, object, true);
}

fn appendCanonicalJsonObject(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, object: std.json.ObjectMap, skip_cache_controls: bool) anyerror!void {
    var keys: std.ArrayListUnmanaged([]const u8) = .empty;
    defer keys.deinit(allocator);
    var it = object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (skip_cache_controls and (responseCacheControlField(key) or responseCacheNormalizedSearchField(key))) continue;
        try keys.append(allocator, key);
    }
    std.mem.sort([]const u8, keys.items, {}, cacheJsonKeyLessThan);

    try out.append(allocator, '{');
    for (keys.items, 0..) |key, i| {
        if (i > 0) try out.append(allocator, ',');
        try json.appendString(out, allocator, key);
        try out.append(allocator, ':');
        try appendCanonicalResponseCacheJsonValue(out, allocator, object.get(key).?);
    }
    try out.append(allocator, '}');
}

fn cacheJsonKeyLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn appendRerankSalt(allocator: std.mem.Allocator, hasher: anytype, search: store_mod.SearchInput, salt: RequestSalt) !void {
    const rerank_text = try std.fmt.allocPrint(
        allocator,
        "reranker={s};rerank_candidate_limit={d};strict_reranker={s}",
        .{
            if (search.allow_reranker) "1" else "0",
            search.rerank_candidate_limit,
            if (search.strict_reranker) "1" else "0",
        },
    );
    defer allocator.free(rerank_text);
    hasher.update(rerank_text);
    if (!search.allow_reranker) return;
    hasher.update(";llm_model=");
    if (salt.llm_model) |model| hasher.update(model) else hasher.update("none");
    hasher.update(";llm_base_url=");
    if (salt.llm_base_url) |base_url| hasher.update(base_url) else hasher.update("none");
}

fn appendEmbeddingSalt(allocator: std.mem.Allocator, hasher: anytype, salt: RequestSalt) !void {
    const text = try std.fmt.allocPrint(
        allocator,
        "embedding_provider={s};embedding_model={s};embedding_base_url={s};embedding_dimensions={d};embedding_send_dimensions={s};embedding_routes={d};embedding_fallbacks={d}",
        .{
            salt.embedding_provider,
            salt.embedding_model orelse "none",
            salt.embedding_base_url orelse "none",
            salt.embedding_dimensions,
            if (salt.embedding_send_dimensions) "1" else "0",
            salt.embedding_route_count,
            salt.embedding_fallback_count,
        },
    );
    defer allocator.free(text);
    hasher.update(text);
}

fn testSalt() RequestSalt {
    return .{
        .actor_id = "agent:a",
        .actor_capabilities_json = "[\"read\"]",
        .revision = "rev:1",
        .embedding_provider = "openai_compatible",
        .embedding_model = "embed-a",
        .embedding_base_url = "https://embed.example.test",
        .embedding_dimensions = 64,
        .embedding_send_dimensions = false,
    };
}

test "cache key canonical body ignores cache controls and normalized search fields" {
    const allocator = std.testing.allocator;
    const body_a = try canonicalResponseBody(allocator, "{\"query\":\"alpha\",\"use_cache\":true,\"limit\":20,\"custom\":{\"b\":2,\"a\":1}}");
    defer allocator.free(body_a);
    const body_b = try canonicalResponseBody(allocator, "{\"cache_ttl_ms\":10,\"custom\":{\"a\":1,\"b\":2},\"q\":\"beta\",\"offset\":5}");
    defer allocator.free(body_b);
    try std.testing.expectEqualStrings("{\"custom\":{\"a\":1,\"b\":2}}", body_a);
    try std.testing.expectEqualStrings(body_a, body_b);
}

test "response key changes with actor capabilities and storage route" {
    const allocator = std.testing.allocator;
    const search = store_mod.SearchInput{ .query = "cache", .scopes_json = "[\"public\"]" };
    var salt = testSalt();

    const base = try responseKey(.{
        .allocator = allocator,
        .namespace = "search",
        .body = "{\"query\":\"cache\"}",
        .search = search,
        .salt = salt,
    });
    defer allocator.free(base);

    salt.actor_capabilities_json = "[\"read\",\"verify\"]";
    const with_capability = try responseKey(.{
        .allocator = allocator,
        .namespace = "search",
        .body = "{\"query\":\"cache\"}",
        .search = search,
        .salt = salt,
    });
    defer allocator.free(with_capability);
    try std.testing.expect(!std.mem.eql(u8, base, with_capability));

    salt.actor_capabilities_json = "[\"read\"]";
    var routed = search;
    routed.agent_memory_route = storage_routes.Route.parse("native");
    const with_route = try responseKey(.{
        .allocator = allocator,
        .namespace = "search",
        .body = "{\"query\":\"cache\"}",
        .search = routed,
        .salt = salt,
    });
    defer allocator.free(with_route);
    try std.testing.expect(!std.mem.eql(u8, base, with_route));
}

test "semantic prefix changes with rollout and runtime salt" {
    const allocator = std.testing.allocator;
    var search = store_mod.SearchInput{ .query = "cache", .scopes_json = "[\"public\"]" };
    var salt = testSalt();

    const base = try semanticPrefix(.{
        .allocator = allocator,
        .namespace = "ask",
        .search = search,
        .salt = salt,
        .include_conflicts = false,
        .use_llm = false,
        .graph_cache_salt = "none",
    });
    defer allocator.free(base);

    search.rollout_shadow_vector = true;
    const with_rollout = try semanticPrefix(.{
        .allocator = allocator,
        .namespace = "ask",
        .search = search,
        .salt = salt,
        .include_conflicts = false,
        .use_llm = false,
        .graph_cache_salt = "none",
    });
    defer allocator.free(with_rollout);
    try std.testing.expect(!std.mem.eql(u8, base, with_rollout));

    search.rollout_shadow_vector = false;
    salt.revision = "rev:2";
    const with_revision = try semanticPrefix(.{
        .allocator = allocator,
        .namespace = "ask",
        .search = search,
        .salt = salt,
        .include_conflicts = false,
        .use_llm = false,
        .graph_cache_salt = "none",
    });
    defer allocator.free(with_revision);
    try std.testing.expect(!std.mem.eql(u8, base, with_revision));
}

test "semantic prefix uses sha256 namespace and fixed digest width" {
    const allocator = std.testing.allocator;
    const search = store_mod.SearchInput{ .query = "cache", .scopes_json = "[\"public\"]" };
    const prefix = try semanticPrefix(.{
        .allocator = allocator,
        .namespace = "search",
        .search = search,
        .salt = testSalt(),
        .include_conflicts = false,
        .use_llm = false,
        .graph_cache_salt = "none",
    });
    defer allocator.free(prefix);

    try std.testing.expect(std.mem.startsWith(u8, prefix, "semantic:search:sha256:"));
    try std.testing.expectEqual(@as(usize, "semantic:search:sha256:".len + 64 + 1), prefix.len);
    try std.testing.expectEqual(@as(u8, ':'), prefix[prefix.len - 1]);
}
