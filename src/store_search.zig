const std = @import("std");

const ids = @import("ids.zig");
const bounded_int = @import("bounded_int.zig");
const domain = @import("domain.zig");
const retrieval_mod = @import("retrieval.zig");
const vector_mod = @import("vector.zig");
const store_types = @import("store_types.zig");

const SearchInput = store_types.SearchInput;
const VectorSearchInput = store_types.VectorSearchInput;

pub const search_page_limit_max: usize = 500;
pub const search_retrieval_window_max: usize = 1000;
pub const primitive_list_limit_max: usize = 5000;

const SearchResultWindow = struct {
    start: usize,
    len: usize,
    end: usize,
};

pub fn searchRequestedLimit(input: SearchInput) usize {
    if (input.limit == 0) return 0;
    return @min(input.limit, search_page_limit_max);
}

pub fn searchCandidateWindowLimit(input: SearchInput) usize {
    const requested = searchRequestedLimit(input);
    if (requested == 0) return 0;
    const available_offset = search_retrieval_window_max - requested;
    const offset = @min(input.offset, available_offset);
    const multiplier = if (input.use_mmr) retrieval_mod.normalizeMmrCandidateMultiplier(input.mmr_candidate_multiplier) else @as(usize, 1);
    const mmr_window = if (requested > search_retrieval_window_max / multiplier)
        search_retrieval_window_max
    else
        requested * multiplier;
    const rerank_window = if (input.allow_reranker) @as(usize, retrieval_mod.normalizeRerankCandidateLimit(input.rerank_candidate_limit)) else requested;
    const page_window = @min(search_retrieval_window_max, offset + mmr_window);
    return @min(search_retrieval_window_max, @max(page_window, rerank_window));
}

pub fn searchRetrievalWindowInput(input: SearchInput) SearchInput {
    var out = input;
    out.limit = searchCandidateWindowLimit(input);
    out.offset = 0;
    return out;
}

pub fn adaptiveConfigFromSearchInput(input: SearchInput) retrieval_mod.AdaptiveConfig {
    return retrieval_mod.normalizeAdaptiveConfig(.{
        .enabled = input.adaptive_retrieval,
        .keyword_max_tokens = input.adaptive_keyword_max_tokens,
        .vector_min_tokens = input.adaptive_vector_min_tokens,
    });
}

pub fn finalizeSearchResultLists(allocator: std.mem.Allocator, input: SearchInput, result_lists: []const []const domain.SearchResult) ![]domain.SearchResult {
    const window_limit = searchCandidateWindowLimit(input);
    if (window_limit == 0) return allocator.alloc(domain.SearchResult, 0);
    return fuseRankedSearchResultListSet(allocator, input, result_lists, window_limit);
}

pub fn searchResultListItemCount(result_lists: []const []const domain.SearchResult) usize {
    var total: usize = 0;
    for (result_lists) |list| total = saturatedSearchResultItemCount(total, list.len);
    return total;
}

pub fn vectorSearchResultLimit(raw_limit: usize) usize {
    return @max(@as(usize, 1), @min(raw_limit, search_retrieval_window_max));
}

pub fn agentMemorySearchResultLimit(raw_limit: usize) usize {
    return @max(@as(usize, 1), @min(raw_limit, primitive_list_limit_max));
}

pub fn vectorScoreAllowedByMinScore(score: f32, input: VectorSearchInput) bool {
    return vectorScoreAllowed(score, normalizedVectorMinScore(input.min_score));
}

pub fn normalizedVectorMinScore(raw: f32) f32 {
    if (!std.math.isFinite(raw) or raw <= 0) return 0;
    return @min(raw, 1.0);
}

pub fn vectorScoreAllowed(score: f32, min_score: f32) bool {
    if (min_score <= 0) return true;
    return std.math.isFinite(score) and score >= min_score;
}

pub fn fuseRankedSearchResultLists(allocator: std.mem.Allocator, input: SearchInput, keyword_results: []const domain.SearchResult, vector_results: []const domain.SearchResult, limit: usize) ![]domain.SearchResult {
    const lists = [_][]const domain.SearchResult{ keyword_results, vector_results };
    return fuseRankedSearchResultListSet(allocator, input, &lists, limit);
}

pub fn fuseRankedSearchResultListSet(allocator: std.mem.Allocator, input: SearchInput, result_lists: []const []const domain.SearchResult, limit: usize) ![]domain.SearchResult {
    var active_count: usize = 0;
    var single_active: ?[]const domain.SearchResult = null;
    for (result_lists) |list| {
        if (list.len == 0) continue;
        active_count += 1;
        single_active = list;
    }
    if (active_count == 0) return allocator.alloc(domain.SearchResult, 0);
    if (active_count == 1) return finalizeSearchResults(allocator, input, single_active.?, limit);

    var ranked_lists = try allocator.alloc(RankedSearchResults, active_count);
    defer allocator.free(ranked_lists);
    var ranked_items = try allocator.alloc([]const retrieval_mod.RankedItem, active_count);
    defer allocator.free(ranked_items);
    var initialized: usize = 0;
    defer {
        var i: usize = 0;
        while (i < initialized) : (i += 1) ranked_lists[i].deinit(allocator);
    }

    for (result_lists) |list| {
        if (list.len == 0) continue;
        ranked_lists[initialized] = try rankUniqueSearchResultsByIdentity(allocator, list);
        ranked_items[initialized] = ranked_lists[initialized].ranked;
        initialized += 1;
    }

    const rrf_config = rrfConfigFromSearchInput(input);
    const expanded_limit = if (limit > search_retrieval_window_max / rrf_config.window_multiplier)
        search_retrieval_window_max
    else
        limit * rrf_config.window_multiplier;
    const fusion_window_limit = @max(limit, @min(expanded_limit, search_retrieval_window_max));
    const fused = try retrieval_mod.reciprocalRankFusion(allocator, ranked_items, rrf_config.k, fusion_window_limit);
    defer allocator.free(fused);
    const max_rrf_score = @as(f64, @floatFromInt(active_count)) / (rrf_config.k + 1.0);
    const max_raw_score = maxSearchResultScore(result_lists);
    const score_weight_total = rrf_config.rrf_weight + rrf_config.raw_score_weight;

    var out: std.ArrayListUnmanaged(domain.SearchResult) = .empty;
    defer out.deinit(allocator);
    for (fused) |ranked| {
        if (findFusedSearchResultRepresentation(ranked_lists[0..initialized], ranked.id)) |result| {
            var copy = result;
            const rrf_score = if (max_rrf_score > 0) ranked.score / max_rrf_score else ranked.score;
            const raw_score = normalizedRawSearchResultScore(result.score, max_raw_score);
            copy.score = ((rrf_config.rrf_weight * rrf_score) + (rrf_config.raw_score_weight * raw_score)) / score_weight_total;
            try out.append(allocator, copy);
        }
    }
    return finalizeSearchResults(allocator, input, out.items, fusion_window_limit);
}

pub fn finalizeSearchResults(allocator: std.mem.Allocator, input: SearchInput, candidates: []const domain.SearchResult, limit_raw: usize) ![]domain.SearchResult {
    const limit = searchRequestedLimit(input);
    const window_limit = @min(limit_raw, search_retrieval_window_max);
    if (limit == 0 or window_limit == 0) return allocator.alloc(domain.SearchResult, 0);
    if (candidates.len == 0) return allocator.alloc(domain.SearchResult, 0);

    var unique: std.ArrayListUnmanaged(domain.SearchResult) = .empty;
    errdefer unique.deinit(allocator);
    for (candidates) |candidate| {
        if (!searchResultAllowedForSession(input, candidate)) continue;
        if (findSearchResultIndex(unique.items, candidate)) |idx| {
            if (candidate.score > unique.items[idx].score) unique.items[idx] = candidate;
        } else {
            try unique.append(allocator, candidate);
        }
    }

    var ordered = try unique.toOwnedSlice(allocator);
    ordered = try filterSearchResultsByMinRelevance(allocator, ordered, input.min_relevance);
    if (ordered.len == 0) return ordered;
    if (input.use_temporal_decay) {
        var ranked = try rankSearchResultsByIdentity(allocator, ordered);
        defer ranked.deinit(allocator);
        const quality = try retrieval_mod.rerankByTemporalDecay(allocator, ranked.ranked, ids.nowMs(), input.half_life_days, ordered.len);
        defer allocator.free(quality);
        var reranked: std.ArrayListUnmanaged(domain.SearchResult) = .empty;
        errdefer reranked.deinit(allocator);
        for (quality) |item| {
            if (findSearchResultByRankKey(ranked, item.id)) |result| {
                var copy = result;
                copy.score = item.score;
                try reranked.append(allocator, copy);
            }
        }
        allocator.free(ordered);
        ordered = try reranked.toOwnedSlice(allocator);
    } else {
        sortSearchResults(ordered);
    }
    applyExactQueryBoost(input.query, ordered);

    if (input.use_mmr and ordered.len > 1 and std.mem.eql(u8, input.query_embedding_provider, "local-deterministic")) {
        const diversified = diversifySearchResultsWithMmr(allocator, input, ordered, window_limit) catch try diversifySearchResults(allocator, ordered, window_limit);
        allocator.free(ordered);
        return trimSearchResultsToWindow(allocator, diversified, input.offset, limit);
    }
    if (input.use_mmr and ordered.len > 1 and !std.mem.eql(u8, input.query_embedding_provider, "local-deterministic")) {
        const diversified = try diversifySearchResults(allocator, ordered, window_limit);
        allocator.free(ordered);
        return trimSearchResultsToWindow(allocator, diversified, input.offset, limit);
    }
    return trimSearchResultsToWindow(allocator, ordered, input.offset, limit);
}

fn rrfConfigFromSearchInput(input: SearchInput) retrieval_mod.RrfConfig {
    return retrieval_mod.normalizeRrfConfig(.{
        .k = input.rrf_k,
        .rrf_weight = input.rrf_weight,
        .raw_score_weight = input.raw_score_weight,
        .window_multiplier = input.rrf_window_multiplier,
    });
}

fn sortSearchResults(items: []domain.SearchResult) void {
    var i: usize = 0;
    while (i < items.len) : (i += 1) {
        var best = i;
        var j = i + 1;
        while (j < items.len) : (j += 1) {
            if (items[j].score > items[best].score) best = j;
        }
        if (best != i) std.mem.swap(domain.SearchResult, &items[i], &items[best]);
    }
}

const RankedSearchResults = struct {
    ranked: []retrieval_mod.RankedItem,
    keys: [][]u8,
    representatives: []domain.SearchResult,

    fn deinit(self: *RankedSearchResults, allocator: std.mem.Allocator) void {
        for (self.keys) |key| allocator.free(key);
        allocator.free(self.keys);
        allocator.free(self.ranked);
        allocator.free(self.representatives);
        self.* = undefined;
    }
};

fn rankSearchResultsByIdentity(allocator: std.mem.Allocator, results: []const domain.SearchResult) !RankedSearchResults {
    return rankSearchResultsByIdentityMode(allocator, results, false);
}

fn rankUniqueSearchResultsByIdentity(allocator: std.mem.Allocator, results: []const domain.SearchResult) !RankedSearchResults {
    return rankSearchResultsByIdentityMode(allocator, results, true);
}

fn rankSearchResultsByIdentityMode(allocator: std.mem.Allocator, results: []const domain.SearchResult, dedupe: bool) !RankedSearchResults {
    var ranked = try allocator.alloc(retrieval_mod.RankedItem, results.len);
    errdefer allocator.free(ranked);
    var keys = try allocator.alloc([]u8, results.len);
    errdefer allocator.free(keys);
    var representatives = try allocator.alloc(domain.SearchResult, results.len);
    errdefer allocator.free(representatives);
    var initialized: usize = 0;
    errdefer for (keys[0..initialized]) |key| allocator.free(key);

    for (results) |result| {
        const key = try searchResultIdentityKey(allocator, result);
        if (dedupe) {
            if (findRankKeyIndex(keys[0..initialized], key)) |existing| {
                representatives[existing] = chooseSearchResultRepresentation(representatives[existing], result);
                ranked[existing].created_at_ms = @max(ranked[existing].created_at_ms, result.created_at_ms);
                ranked[existing].confidence = @max(ranked[existing].confidence, result.confidence);
                allocator.free(key);
                continue;
            }
        }
        keys[initialized] = key;
        ranked[initialized] = .{
            .id = key,
            .score = result.score,
            .created_at_ms = result.created_at_ms,
            .confidence = result.confidence,
        };
        representatives[initialized] = result;
        initialized += 1;
    }

    ranked = try allocator.realloc(ranked, initialized);
    keys = try allocator.realloc(keys, initialized);
    representatives = try allocator.realloc(representatives, initialized);
    return .{ .ranked = ranked, .keys = keys, .representatives = representatives };
}

fn findRankKeyIndex(keys: []const []const u8, rank_key: []const u8) ?usize {
    for (keys, 0..) |key, i| {
        if (std.mem.eql(u8, key, rank_key)) return i;
    }
    return null;
}

fn searchResultIdentityKey(allocator: std.mem.Allocator, result: domain.SearchResult) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{d}:{s}:{d}:{s}:{d}:{s}",
        .{ result.result_type.len, result.result_type, result.store.len, result.store, result.id.len, result.id },
    );
}

fn findSearchResultByRankKey(ranked: RankedSearchResults, rank_key: []const u8) ?domain.SearchResult {
    for (ranked.keys, 0..) |key, i| {
        if (std.mem.eql(u8, key, rank_key)) return ranked.representatives[i];
    }
    return null;
}

fn maxSearchResultScore(result_lists: []const []const domain.SearchResult) f64 {
    var max_score: f64 = 0;
    for (result_lists) |list| {
        for (list) |result| {
            if (std.math.isFinite(result.score)) max_score = @max(max_score, result.score);
        }
    }
    return max_score;
}

fn normalizedRawSearchResultScore(score: f64, max_score: f64) f64 {
    if (!std.math.isFinite(score) or max_score <= 0) return 0;
    return @max(0, @min(1, score / max_score));
}

fn applyExactQueryBoost(query: []const u8, ordered: []domain.SearchResult) void {
    const trimmed = std.mem.trim(u8, query, " \t\r\n");
    if (trimmed.len < 3) return;
    if (std.mem.indexOfAny(u8, trimmed, " \t\r\n") == null) return;
    var changed = false;
    for (ordered) |*result| {
        if (containsAsciiIgnoreCase(result.title, trimmed) or containsAsciiIgnoreCase(result.text, trimmed)) {
            result.score += 0.35;
            changed = true;
        }
    }
    if (changed) sortSearchResults(ordered);
}

fn containsAsciiIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

pub fn trimSearchResultsToWindow(allocator: std.mem.Allocator, ordered: []domain.SearchResult, offset: usize, limit: usize) ![]domain.SearchResult {
    const window = searchResultWindow(ordered.len, offset, limit);
    if (window.len == 0) {
        allocator.free(ordered);
        return allocator.alloc(domain.SearchResult, 0);
    }
    if (window.start > 0) std.mem.copyForwards(domain.SearchResult, ordered[0..window.len], ordered[window.start..window.end]);
    if (ordered.len > window.len) return allocator.realloc(ordered, window.len);
    return ordered;
}

fn searchResultWindow(total: usize, offset: usize, limit: usize) SearchResultWindow {
    const start = @min(offset, total);
    const len = if (limit == 0) @as(usize, 0) else @min(limit, total - start);
    return .{
        .start = start,
        .len = len,
        .end = bounded_int.saturatingUsizeAdd(start, len),
    };
}

fn filterSearchResultsByMinRelevance(allocator: std.mem.Allocator, ordered: []domain.SearchResult, min_relevance_raw: f64) ![]domain.SearchResult {
    const min_relevance = if (std.math.isNan(min_relevance_raw) or min_relevance_raw < 0) 0 else min_relevance_raw;
    const threshold_active = min_relevance > 0;
    var keep: usize = 0;
    var changed = false;
    for (ordered, 0..) |result, i| {
        const allowed = !std.math.isNan(result.score) and (!threshold_active or result.score >= min_relevance);
        if (allowed) {
            if (keep != i) {
                ordered[keep] = result;
                changed = true;
            }
            keep += 1;
        } else {
            changed = true;
        }
    }
    if (!changed) return ordered;
    if (keep == 0) {
        allocator.free(ordered);
        return allocator.alloc(domain.SearchResult, 0);
    }
    return allocator.realloc(ordered, keep);
}

pub fn agentMemorySessionAllowedForSearch(search_session_id: ?[]const u8, include_sessions: bool, entry_session_id: ?[]const u8) bool {
    if (search_session_id) |expected| {
        const actual = entry_session_id orelse return false;
        return std.mem.eql(u8, actual, expected);
    }
    return include_sessions or entry_session_id == null;
}

fn searchResultAllowedForSession(input: SearchInput, candidate: domain.SearchResult) bool {
    if (!searchResultCarriesSessionIdentity(candidate.result_type)) return true;
    return agentMemorySessionAllowedForSearch(input.session_id, input.include_sessions, candidate.session_id);
}

fn searchResultCarriesSessionIdentity(result_type: []const u8) bool {
    return std.mem.eql(u8, result_type, "agent_memory") or std.mem.eql(u8, result_type, "session_message");
}

fn findSearchResultIndex(results: []const domain.SearchResult, candidate: domain.SearchResult) ?usize {
    for (results, 0..) |result, i| {
        if (sameSearchResultIdentity(result, candidate)) return i;
    }
    return null;
}

fn sameSearchResultIdentity(a: domain.SearchResult, b: domain.SearchResult) bool {
    if (!std.mem.eql(u8, a.id, b.id)) return false;
    if (!std.mem.eql(u8, a.result_type, b.result_type)) return false;
    if (std.mem.eql(u8, a.result_type, "agent_memory") or a.store.len > 0 or b.store.len > 0) {
        return std.mem.eql(u8, a.store, b.store);
    }
    return true;
}

fn findFusedSearchResultRepresentation(ranked_lists: []const RankedSearchResults, rank_key: []const u8) ?domain.SearchResult {
    var chosen: ?domain.SearchResult = null;
    for (ranked_lists) |ranked| {
        if (findSearchResultByRankKey(ranked, rank_key)) |result| {
            chosen = if (chosen) |current| chooseSearchResultRepresentation(current, result) else result;
        }
    }
    return chosen;
}

fn chooseSearchResultRepresentation(current: domain.SearchResult, candidate: domain.SearchResult) domain.SearchResult {
    const current_has_heading = headingPathJsonHasItems(current.heading_path_json);
    const candidate_has_heading = headingPathJsonHasItems(candidate.heading_path_json);
    if (candidate_has_heading and !current_has_heading) return candidate;
    if (!candidate_has_heading and current_has_heading) return current;
    if (candidate.score > current.score) return candidate;
    if (candidate.score < current.score) return current;
    if (candidate.confidence > current.confidence) return candidate;
    if (candidate.confidence < current.confidence) return current;
    if (candidate.created_at_ms > current.created_at_ms) return candidate;
    if (candidate.created_at_ms < current.created_at_ms) return current;
    if (std.mem.order(u8, candidate.result_type, current.result_type) == .lt) return candidate;
    if (std.mem.order(u8, candidate.result_type, current.result_type) == .gt) return current;
    if (std.mem.order(u8, candidate.store, current.store) == .lt) return candidate;
    if (std.mem.order(u8, candidate.store, current.store) == .gt) return current;
    if (std.mem.order(u8, candidate.id, current.id) == .lt) return candidate;
    return current;
}

fn headingPathJsonHasItems(raw: []const u8) bool {
    return std.mem.indexOfScalar(u8, raw, '"') != null;
}

fn saturatedSearchResultItemCount(total: usize, next_len: usize) usize {
    return bounded_int.saturatingUsizeAdd(total, next_len);
}

fn diversifySearchResultsWithMmr(allocator: std.mem.Allocator, input: SearchInput, ordered: []const domain.SearchResult, limit: usize) ![]domain.SearchResult {
    const raw_query_embedding = input.query_embedding_json orelse return error.MissingQueryEmbedding;
    const query_embedding = try vector_mod.embeddingFromJson(allocator, raw_query_embedding);
    defer allocator.free(query_embedding);
    if (query_embedding.len == 0) return error.MissingQueryEmbedding;

    var ranked = try rankSearchResultsByIdentity(allocator, ordered);
    defer ranked.deinit(allocator);
    const candidates = try allocator.alloc(retrieval_mod.MmrCandidate, ordered.len);
    defer allocator.free(candidates);
    const embeddings = try allocator.alloc(?[]f32, ordered.len);
    defer {
        for (embeddings) |embedding| if (embedding) |value| allocator.free(value);
        allocator.free(embeddings);
    }
    @memset(embeddings, null);

    for (ordered, 0..) |result, i| {
        embeddings[i] = try vector_mod.deterministicEmbedding(allocator, result.text, query_embedding.len);
        candidates[i] = .{
            .id = ranked.keys[i],
            .score = result.score,
            .embedding = embeddings[i].?,
        };
    }

    const selected = try retrieval_mod.mmrSelect(allocator, query_embedding, candidates, input.mmr_lambda, limit);
    defer allocator.free(selected);
    var out: std.ArrayListUnmanaged(domain.SearchResult) = .empty;
    errdefer out.deinit(allocator);
    for (selected) |item| {
        if (findSearchResultByRankKey(ranked, item.id)) |result| {
            var copy = result;
            copy.score = item.score;
            try out.append(allocator, copy);
        }
    }
    return out.toOwnedSlice(allocator);
}

fn diversifySearchResults(allocator: std.mem.Allocator, ordered: []const domain.SearchResult, limit: usize) ![]domain.SearchResult {
    var used = try allocator.alloc(bool, ordered.len);
    defer allocator.free(used);
    @memset(used, false);

    var out: std.ArrayListUnmanaged(domain.SearchResult) = .empty;
    errdefer out.deinit(allocator);
    while (out.items.len < limit and out.items.len < ordered.len) {
        var best_idx: ?usize = null;
        var best_score: f64 = -1.0e9;
        for (ordered, 0..) |candidate, i| {
            if (used[i]) continue;
            var max_overlap: f64 = 0;
            var same_type_count: usize = 0;
            for (out.items) |selected| {
                max_overlap = @max(max_overlap, tokenOverlap(candidate.text, selected.text));
                if (std.mem.eql(u8, candidate.result_type, selected.result_type)) same_type_count += 1;
            }
            const adjusted = candidate.score - (0.35 * max_overlap) - (0.03 * @as(f64, @floatFromInt(same_type_count)));
            if (best_idx == null or adjusted > best_score) {
                best_idx = i;
                best_score = adjusted;
            }
        }
        const idx = best_idx orelse break;
        used[idx] = true;
        var copy = ordered[idx];
        copy.score = best_score;
        try out.append(allocator, copy);
    }
    return out.toOwnedSlice(allocator);
}

fn tokenOverlap(a: []const u8, b: []const u8) f64 {
    if (a.len == 0 or b.len == 0) return 0;
    var matched: usize = 0;
    var total: usize = 0;
    var it = std.mem.tokenizeAny(u8, a, " \t\r\n.,;:/\\-_*\"'()[]{}<>!?");
    while (it.next()) |token| {
        if (token.len < 3) continue;
        total += 1;
        if (std.ascii.indexOfIgnoreCase(b, token) != null) matched += 1;
        if (total >= 64) break;
    }
    if (total == 0) return 0;
    return @as(f64, @floatFromInt(matched)) / @as(f64, @floatFromInt(total));
}

test "retrieval candidate window includes LLM rerank candidates before final limit" {
    const narrow = SearchInput{
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
    try std.testing.expectEqual(@as(usize, 24), searchCandidateWindowLimit(narrow));

    const paged = SearchInput{
        .query = "rank",
        .scopes_json = "[\"public\"]",
        .limit = 2,
        .offset = 7,
        .use_vector = false,
        .use_temporal_decay = false,
        .use_mmr = false,
        .allow_reranker = true,
        .rerank_candidate_limit = 3,
    };
    try std.testing.expectEqual(@as(usize, 9), searchCandidateWindowLimit(paged));

    const mmr_and_rerank = SearchInput{
        .query = "rank",
        .scopes_json = "[\"public\"]",
        .limit = 2,
        .offset = 0,
        .use_vector = false,
        .use_temporal_decay = false,
        .use_mmr = true,
        .mmr_candidate_multiplier = 3,
        .allow_reranker = true,
        .rerank_candidate_limit = 24,
    };
    try std.testing.expectEqual(@as(usize, 24), searchCandidateWindowLimit(mmr_and_rerank));
}

test "search result window trim centralizes bounded paging" {
    const alloc = std.testing.allocator;
    const tail_window = searchResultWindow(4, 1, 2);
    try std.testing.expectEqual(@as(usize, 1), tail_window.start);
    try std.testing.expectEqual(@as(usize, 2), tail_window.len);
    try std.testing.expectEqual(@as(usize, 3), tail_window.end);

    const empty_window = searchResultWindow(4, std.math.maxInt(usize), 2);
    try std.testing.expectEqual(@as(usize, 4), empty_window.start);
    try std.testing.expectEqual(@as(usize, 0), empty_window.len);
    try std.testing.expectEqual(@as(usize, 4), empty_window.end);

    const max_window = searchResultWindow(std.math.maxInt(usize), std.math.maxInt(usize) - 1, std.math.maxInt(usize));
    try std.testing.expectEqual(std.math.maxInt(usize) - 1, max_window.start);
    try std.testing.expectEqual(@as(usize, 1), max_window.len);
    try std.testing.expectEqual(std.math.maxInt(usize), max_window.end);

    var items = try alloc.alloc(domain.SearchResult, 4);
    items[0] = .{ .id = "a", .result_type = "memory_atom", .title = "A", .text = "first", .scope = "public", .status = "verified", .score = 1.0, .source_ids_json = "[]" };
    items[1] = .{ .id = "b", .result_type = "memory_atom", .title = "B", .text = "second", .scope = "public", .status = "verified", .score = 0.9, .source_ids_json = "[]" };
    items[2] = .{ .id = "c", .result_type = "memory_atom", .title = "C", .text = "third", .scope = "public", .status = "verified", .score = 0.8, .source_ids_json = "[]" };
    items[3] = .{ .id = "d", .result_type = "memory_atom", .title = "D", .text = "fourth", .scope = "public", .status = "verified", .score = 0.7, .source_ids_json = "[]" };

    const paged = try trimSearchResultsToWindow(alloc, items, 1, 2);
    defer alloc.free(paged);
    try std.testing.expectEqual(@as(usize, 2), paged.len);
    try std.testing.expectEqualStrings("b", paged[0].id);
    try std.testing.expectEqualStrings("c", paged[1].id);

    var zero_limit_items = try alloc.alloc(domain.SearchResult, 1);
    zero_limit_items[0] = .{ .id = "z", .result_type = "memory_atom", .title = "Z", .text = "zero", .scope = "public", .status = "verified", .score = 1.0, .source_ids_json = "[]" };
    const zero = try trimSearchResultsToWindow(alloc, zero_limit_items, 0, 0);
    defer alloc.free(zero);
    try std.testing.expectEqual(@as(usize, 0), zero.len);

    var max_offset_items = try alloc.alloc(domain.SearchResult, 1);
    max_offset_items[0] = .{ .id = "m", .result_type = "memory_atom", .title = "M", .text = "max", .scope = "public", .status = "verified", .score = 1.0, .source_ids_json = "[]" };
    const max_offset = try trimSearchResultsToWindow(alloc, max_offset_items, std.math.maxInt(usize), 1);
    defer alloc.free(max_offset);
    try std.testing.expectEqual(@as(usize, 0), max_offset.len);
}

test "retrieval result list item count sums search channels" {
    const first = [_]domain.SearchResult{
        .{
            .id = "a",
            .result_type = "memory_atom",
            .title = "A",
            .text = "first result",
            .scope = "public",
            .status = "verified",
            .score = 0.7,
            .source_ids_json = "[]",
        },
        .{
            .id = "b",
            .result_type = "memory_atom",
            .title = "B",
            .text = "second result",
            .scope = "public",
            .status = "verified",
            .score = 0.6,
            .source_ids_json = "[]",
        },
    };
    const second = [_]domain.SearchResult{
        .{
            .id = "c",
            .result_type = "artifact",
            .title = "C",
            .text = "third result",
            .scope = "public",
            .status = "active",
            .score = 0.5,
            .source_ids_json = "[]",
        },
    };
    const empty = [_]domain.SearchResult{};
    const lists = [_][]const domain.SearchResult{ &first, &empty, &second };
    try std.testing.expectEqual(@as(usize, 3), searchResultListItemCount(&lists));
}

test "retrieval result list item count saturates overflow" {
    try std.testing.expectEqual(std.math.maxInt(usize), saturatedSearchResultItemCount(std.math.maxInt(usize) - 1, 4));
    try std.testing.expectEqual(@as(usize, 9), saturatedSearchResultItemCount(4, 5));
}
