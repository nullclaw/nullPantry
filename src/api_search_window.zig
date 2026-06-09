const std = @import("std");
const bounded_int = @import("bounded_int.zig");
const domain = @import("domain.zig");
const retrieval = @import("retrieval.zig");
const runtime_config = @import("runtime_config.zig");
const store_search = @import("store_search.zig");
const store_types = @import("store_types.zig");

pub fn mergeWindowLimit(input: store_types.SearchInput) usize {
    return store_search.searchCandidateWindowLimit(input);
}

pub fn inputForMergeWindow(input: store_types.SearchInput, route: store_types.AgentMemoryStorageRoute) store_types.SearchInput {
    var out = input;
    out.agent_memory_route = route;
    out.limit = mergeWindowLimit(input);
    out.offset = 0;
    return out;
}

pub fn llmRerankEffective(provider: runtime_config.ProviderConfig, input: store_types.SearchInput) bool {
    return input.allow_reranker and provider.completion.base_url != null and provider.completion.model != null;
}

pub fn finalPageLimit(input: store_types.SearchInput) usize {
    if (input.limit == 0) return 0;
    return @min(input.limit, store_search.search_page_limit_max);
}

pub fn boundedWindowEnd(limit: usize, offset: usize, max_window: usize) usize {
    if (limit == 0) return 0;
    if (max_window == 0) return 0;
    const capped_limit = @min(limit, max_window);
    const bounded_offset = @min(offset, max_window - capped_limit);
    const end = bounded_int.saturatingUsizeAdd(bounded_offset, limit);
    return @min(max_window, end);
}

pub fn finalPageEnd(input: store_types.SearchInput) usize {
    return boundedWindowEnd(finalPageLimit(input), input.offset, store_search.search_retrieval_window_max);
}

pub fn llmRerankWindowLimit(input: store_types.SearchInput) usize {
    const page_end = finalPageEnd(input);
    if (page_end == 0) return 0;
    const rerank_limit = @as(usize, retrieval.normalizeRerankCandidateLimit(input.rerank_candidate_limit));
    return @min(store_search.search_retrieval_window_max, @max(page_end, rerank_limit));
}

pub fn inputForLlmRerankWindow(input: store_types.SearchInput) store_types.SearchInput {
    var out = input;
    out.limit = llmRerankWindowLimit(input);
    out.offset = 0;
    return out;
}

pub fn trimResultsToFinalPageAlloc(allocator: std.mem.Allocator, results: []domain.SearchResult, input: store_types.SearchInput) ![]domain.SearchResult {
    const limit = finalPageLimit(input);
    return trimResultsToWindowAlloc(allocator, results, input.offset, limit);
}

pub fn trimResultsToWindowAlloc(allocator: std.mem.Allocator, results: []domain.SearchResult, offset: usize, limit: usize) ![]domain.SearchResult {
    return store_search.trimSearchResultsToWindow(allocator, results, offset, limit);
}

test "api search window expands before final limit for LLM rerank" {
    const base = store_types.SearchInput{
        .query = "rank",
        .scopes_json = "[\"public\"]",
        .limit = 1,
        .offset = 0,
        .use_vector = false,
        .use_temporal_decay = false,
        .use_mmr = false,
        .allow_reranker = true,
        .rerank_candidate_limit = 24,
    };
    const expanded = inputForLlmRerankWindow(base);
    try std.testing.expectEqual(@as(usize, 24), expanded.limit);
    try std.testing.expectEqual(@as(usize, 0), expanded.offset);

    var paged = base;
    paged.limit = 2;
    paged.offset = 7;
    paged.rerank_candidate_limit = 3;
    const page_window = inputForLlmRerankWindow(paged);
    try std.testing.expectEqual(@as(usize, 9), page_window.limit);
    try std.testing.expectEqual(@as(usize, 0), page_window.offset);

    var zero = base;
    zero.limit = 0;
    const zero_window = inputForLlmRerankWindow(zero);
    try std.testing.expectEqual(@as(usize, 0), zero_window.limit);
}

test "api search window end is bounded without overflow" {
    try std.testing.expectEqual(@as(usize, 0), boundedWindowEnd(0, 10, 100));
    try std.testing.expectEqual(@as(usize, 0), boundedWindowEnd(10, 10, 0));
    try std.testing.expectEqual(@as(usize, 9), boundedWindowEnd(2, 7, 100));
    try std.testing.expectEqual(@as(usize, 500), boundedWindowEnd(100, 450, 500));
    try std.testing.expectEqual(@as(usize, 100), boundedWindowEnd(2, std.math.maxInt(usize), 100));
    try std.testing.expectEqual(@as(usize, 100), boundedWindowEnd(std.math.maxInt(usize), std.math.maxInt(usize), 100));
}

test "api search window trims final page after rerank order" {
    const alloc = std.testing.allocator;
    var results = try alloc.alloc(domain.SearchResult, 4);
    results[0] = .{ .id = "reranked-first", .result_type = "memory_atom", .title = "First", .text = "first", .scope = "public", .status = "verified", .score = 1.0, .source_ids_json = "[]" };
    results[1] = .{ .id = "reranked-second", .result_type = "memory_atom", .title = "Second", .text = "second", .scope = "public", .status = "verified", .score = 0.9, .source_ids_json = "[]" };
    results[2] = .{ .id = "reranked-third", .result_type = "memory_atom", .title = "Third", .text = "third", .scope = "public", .status = "verified", .score = 0.8, .source_ids_json = "[]" };
    results[3] = .{ .id = "reranked-fourth", .result_type = "memory_atom", .title = "Fourth", .text = "fourth", .scope = "public", .status = "verified", .score = 0.7, .source_ids_json = "[]" };

    const trimmed = try trimResultsToFinalPageAlloc(alloc, results, .{
        .query = "rank",
        .scopes_json = "[\"public\"]",
        .limit = 2,
        .offset = 1,
        .use_vector = false,
        .use_temporal_decay = false,
        .use_mmr = false,
    });
    defer alloc.free(trimmed);
    try std.testing.expectEqual(@as(usize, 2), trimmed.len);
    try std.testing.expectEqualStrings("reranked-second", trimmed[0].id);
    try std.testing.expectEqualStrings("reranked-third", trimmed[1].id);
}

test "api search window requires reranker config and input flag" {
    var input = store_types.SearchInput{
        .query = "rank",
        .scopes_json = "[\"public\"]",
        .allow_reranker = true,
    };
    const configured = runtime_config.ProviderConfig{
        .completion = .{
            .base_url = "https://llm.example.test",
            .model = "ranker-a",
        },
    };

    try std.testing.expect(llmRerankEffective(configured, input));
    input.allow_reranker = false;
    try std.testing.expect(!llmRerankEffective(configured, input));
    input.allow_reranker = true;
    try std.testing.expect(!llmRerankEffective(.{}, input));
}
