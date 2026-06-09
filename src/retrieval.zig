const std = @import("std");
const json = @import("json_util.zig");
const query_expansion = @import("query_expansion.zig");
const time_math = @import("time_math.zig");
const vector = @import("vector.zig");

pub const Language = query_expansion.Language;
pub const ExpandedQuery = query_expansion.ExpandedQuery;
pub const extractKeywords = query_expansion.extractKeywords;

pub const RankedItem = struct {
    id: []const u8,
    score: f64,
    created_at_ms: i64 = 0,
    confidence: f64 = 0.5,
};

pub const MmrCandidate = struct {
    id: []const u8,
    score: f64,
    embedding: []const f32,
};

pub const RetrievalStrategy = enum {
    keyword_only,
    vector_only,
    hybrid,

    pub fn name(self: RetrievalStrategy) []const u8 {
        return switch (self) {
            .keyword_only => "keyword_only",
            .vector_only => "vector_only",
            .hybrid => "hybrid",
        };
    }
};

pub const AdaptiveConfig = struct {
    enabled: bool = true,
    keyword_max_tokens: u32 = 3,
    vector_min_tokens: u32 = 6,
};

pub const default_adaptive_keyword_max_tokens: u32 = 3;
pub const default_adaptive_vector_min_tokens: u32 = 6;
pub const max_adaptive_token_threshold: u32 = 1024;

pub const default_rrf_k: f64 = 60;
pub const default_rrf_weight: f64 = 0.85;
pub const default_rrf_raw_score_weight: f64 = 0.15;
pub const default_rrf_window_multiplier: usize = 4;
pub const max_rrf_k: f64 = 10_000;
pub const max_rrf_window_multiplier: usize = 64;
pub const default_mmr_lambda: f64 = 0.72;
pub const default_mmr_candidate_multiplier: usize = 4;
pub const max_mmr_candidate_multiplier: usize = 64;
pub const default_rerank_candidate_limit: u32 = 24;
pub const max_rerank_candidate_limit: u32 = 128;
const mmr_semantic_relevance_weight: f64 = 0.72;

pub const RrfConfig = struct {
    k: f64 = default_rrf_k,
    rrf_weight: f64 = default_rrf_weight,
    raw_score_weight: f64 = default_rrf_raw_score_weight,
    window_multiplier: usize = default_rrf_window_multiplier,
};

pub fn normalizeAdaptiveKeywordMaxTokens(value: u32) u32 {
    return @min(value, max_adaptive_token_threshold);
}

pub fn normalizeAdaptiveVectorMinTokens(value: u32) u32 {
    return @max(@as(u32, 1), @min(value, max_adaptive_token_threshold));
}

pub fn normalizeAdaptiveConfig(config: AdaptiveConfig) AdaptiveConfig {
    return .{
        .enabled = config.enabled,
        .keyword_max_tokens = normalizeAdaptiveKeywordMaxTokens(config.keyword_max_tokens),
        .vector_min_tokens = normalizeAdaptiveVectorMinTokens(config.vector_min_tokens),
    };
}

pub fn normalizeRrfK(value: f64) f64 {
    if (!std.math.isFinite(value) or value <= 0) return default_rrf_k;
    return @max(1.0, @min(max_rrf_k, value));
}

pub fn normalizeRrfWeight(value: f64, default_value: f64) f64 {
    if (!std.math.isFinite(value) or value < 0) return default_value;
    return @max(0.0, @min(1.0, value));
}

pub fn normalizeRrfWindowMultiplier(value: usize) usize {
    return @max(@as(usize, 1), @min(value, max_rrf_window_multiplier));
}

pub fn normalizeRrfConfig(config: RrfConfig) RrfConfig {
    var out = RrfConfig{
        .k = normalizeRrfK(config.k),
        .rrf_weight = normalizeRrfWeight(config.rrf_weight, default_rrf_weight),
        .raw_score_weight = normalizeRrfWeight(config.raw_score_weight, default_rrf_raw_score_weight),
        .window_multiplier = normalizeRrfWindowMultiplier(config.window_multiplier),
    };
    if (out.rrf_weight == 0 and out.raw_score_weight == 0) {
        out.rrf_weight = default_rrf_weight;
        out.raw_score_weight = default_rrf_raw_score_weight;
    }
    return out;
}

pub fn normalizeMmrLambda(value: f64) f64 {
    if (!std.math.isFinite(value)) return default_mmr_lambda;
    return @max(0.0, @min(1.0, value));
}

pub fn normalizeMmrCandidateMultiplier(value: usize) usize {
    return @max(@as(usize, 1), @min(value, max_mmr_candidate_multiplier));
}

pub fn normalizeRerankCandidateLimit(value: u32) u32 {
    return @max(@as(u32, 1), @min(value, max_rerank_candidate_limit));
}

pub const QueryAnalysis = struct {
    token_count: u32,
    has_special_chars: bool,
    is_question: bool,
    avg_token_length: f32,
    recommended_strategy: RetrievalStrategy,
};

pub const RetrievalPlan = struct {
    use_keyword: bool,
    use_vector: bool,
    use_graph: bool,
    use_reranker: bool,
    adaptive_enabled: bool,
    adaptive_keyword_max_tokens: u32,
    adaptive_vector_min_tokens: u32,
    strategy: RetrievalStrategy,
    token_count: u32,
    has_special_chars: bool,
    is_question: bool,
    avg_token_length: f32,
    min_relevance: f64,
    rrf_k: f64,
    rrf_weight: f64,
    raw_score_weight: f64,
    rrf_window_multiplier: usize,
    mmr_lambda: f64,
    mmr_candidate_multiplier: usize,
    expanded_query: []const u8,
    keyword_query: []const u8,
    websearch_query: []const u8,
    expansion_terms_json: []const u8,
    expansion_reasons_json: []const u8,
    intent_hints_json: []const u8,
    query_expanded: bool,

    pub fn deinit(self: *RetrievalPlan, allocator: std.mem.Allocator) void {
        allocator.free(self.expanded_query);
        allocator.free(self.keyword_query);
        allocator.free(self.websearch_query);
        allocator.free(self.expansion_terms_json);
        allocator.free(self.expansion_reasons_json);
        allocator.free(self.intent_hints_json);
        self.* = undefined;
    }
};

const search_token_delimiters = " \t\r\n.,;:/\\-_*\"'()[]{}<>!?|&+=#@$%^`~";
const max_backend_search_terms = 64;
const max_lexical_score_token_bytes = 256;

pub fn reciprocalRankFusion(allocator: std.mem.Allocator, lists: []const []const RankedItem, k: f64, limit: usize) ![]RankedItem {
    if (limit == 0) return allocator.alloc(RankedItem, 0);
    var fused: std.ArrayListUnmanaged(RankedItem) = .empty;
    errdefer fused.deinit(allocator);
    for (lists) |list| {
        for (list, 0..) |item, rank| {
            const contribution = 1.0 / (k + @as(f64, @floatFromInt(rank + 1)));
            if (findItem(fused.items, item.id)) |idx| {
                fused.items[idx].score += contribution;
                fused.items[idx].created_at_ms = @max(fused.items[idx].created_at_ms, item.created_at_ms);
                fused.items[idx].confidence = @max(fused.items[idx].confidence, item.confidence);
            } else {
                try fused.append(allocator, .{
                    .id = item.id,
                    .score = contribution,
                    .created_at_ms = item.created_at_ms,
                    .confidence = item.confidence,
                });
            }
        }
    }
    sortRanked(fused.items);
    if (fused.items.len > limit) fused.shrinkRetainingCapacity(limit);
    return fused.toOwnedSlice(allocator);
}

fn findItem(items: []const RankedItem, id: []const u8) ?usize {
    for (items, 0..) |item, i| {
        if (std.mem.eql(u8, item.id, id)) return i;
    }
    return null;
}

pub fn applyTemporalDecay(score: f64, age_ms: i64, half_life_days: f64) f64 {
    if (age_ms <= 0 or half_life_days <= 0) return score;
    const age_days = @as(f64, @floatFromInt(age_ms)) / (1000.0 * 60.0 * 60.0 * 24.0);
    return score * std.math.pow(f64, 0.5, age_days / half_life_days);
}

fn temporalDecayAgeMs(now_ms: i64, created_at_ms: i64) i64 {
    if (created_at_ms <= 0) return 0;
    return time_math.elapsedSinceMs(now_ms, created_at_ms);
}

pub fn rerankByTemporalDecay(allocator: std.mem.Allocator, items: []const RankedItem, now_ms: i64, half_life_days: f64, limit: usize) ![]RankedItem {
    var out = try allocator.alloc(RankedItem, items.len);
    errdefer allocator.free(out);
    for (items, 0..) |item, i| {
        const age = temporalDecayAgeMs(now_ms, item.created_at_ms);
        out[i] = item;
        out[i].score = applyTemporalDecay(item.score, age, half_life_days);
    }
    sortRanked(out);
    if (out.len > limit) return allocator.realloc(out, limit);
    return out;
}

pub fn mmrSelect(allocator: std.mem.Allocator, query_embedding: []const f32, candidates: []const MmrCandidate, lambda: f64, limit: usize) ![]RankedItem {
    if (limit == 0 or candidates.len == 0) return allocator.alloc(RankedItem, 0);
    const result_limit = @min(limit, candidates.len);
    const clamped_lambda = normalizeMmrLambda(lambda);

    const relevance_scores = try mmrRelevanceScores(allocator, query_embedding, candidates);
    defer allocator.free(relevance_scores);

    var selected_indices: std.ArrayListUnmanaged(usize) = .empty;
    defer selected_indices.deinit(allocator);
    var selected_scores: std.ArrayListUnmanaged(f64) = .empty;
    defer selected_scores.deinit(allocator);
    var used = try allocator.alloc(bool, candidates.len);
    defer allocator.free(used);
    @memset(used, false);

    while (selected_indices.items.len < result_limit) {
        var best_idx: ?usize = null;
        var best_score: f64 = -std.math.inf(f64);
        for (candidates, 0..) |candidate, i| {
            if (used[i]) continue;
            var max_selected_similarity: f64 = 0;
            for (selected_indices.items) |selected_idx| {
                max_selected_similarity = @max(max_selected_similarity, vector.cosine(candidate.embedding, candidates[selected_idx].embedding));
            }
            const mmr_score = clamped_lambda * relevance_scores[i] - (1.0 - clamped_lambda) * max_selected_similarity;
            if (best_idx == null or betterMmrCandidate(mmr_score, candidate, best_score, candidates[best_idx.?])) {
                best_idx = i;
                best_score = mmr_score;
            }
        }
        const idx = best_idx orelse break;
        used[idx] = true;
        try selected_indices.append(allocator, idx);
        try selected_scores.append(allocator, best_score);
    }

    var out = try allocator.alloc(RankedItem, selected_indices.items.len);
    for (selected_indices.items, 0..) |idx, i| {
        out[i] = .{ .id = candidates[idx].id, .score = selected_scores.items[i] };
    }
    return out;
}

fn mmrRelevanceScores(allocator: std.mem.Allocator, query_embedding: []const f32, candidates: []const MmrCandidate) ![]f64 {
    var min_score: f64 = std.math.inf(f64);
    var max_score: f64 = -std.math.inf(f64);
    for (candidates) |candidate| {
        if (!std.math.isFinite(candidate.score)) continue;
        min_score = @min(min_score, candidate.score);
        max_score = @max(max_score, candidate.score);
    }
    const has_finite_scores = std.math.isFinite(min_score) and std.math.isFinite(max_score);
    const score_range = if (has_finite_scores) max_score - min_score else 0;

    const out = try allocator.alloc(f64, candidates.len);
    errdefer allocator.free(out);
    for (candidates, 0..) |candidate, i| {
        const normalized_score = if (has_finite_scores and score_range > 0 and std.math.isFinite(candidate.score))
            (candidate.score - min_score) / score_range
        else if (std.math.isFinite(candidate.score))
            @as(f64, 1.0)
        else
            @as(f64, 0.0);
        const semantic_relevance = if (query_embedding.len > 0 and candidate.embedding.len == query_embedding.len)
            @as(f64, vector.cosine(query_embedding, candidate.embedding))
        else
            normalized_score;
        out[i] = (mmr_semantic_relevance_weight * semantic_relevance) + ((1.0 - mmr_semantic_relevance_weight) * normalized_score);
    }
    return out;
}

fn betterMmrCandidate(candidate_mmr: f64, candidate: MmrCandidate, best_mmr: f64, best: MmrCandidate) bool {
    if (candidate_mmr > best_mmr) return true;
    if (candidate_mmr < best_mmr) return false;
    if (candidate.score > best.score) return true;
    if (candidate.score < best.score) return false;
    return std.mem.order(u8, candidate.id, best.id) == .lt;
}

const QueryExpansion = struct {
    expanded_query: []const u8,
    keyword_query: []const u8,
    websearch_query: []const u8,
    terms_json: []const u8,
    reasons_json: []const u8,
    intents_json: []const u8,
    changed: bool,

    fn deinit(self: *QueryExpansion, allocator: std.mem.Allocator) void {
        allocator.free(self.expanded_query);
        allocator.free(self.keyword_query);
        allocator.free(self.websearch_query);
        allocator.free(self.terms_json);
        allocator.free(self.reasons_json);
        allocator.free(self.intents_json);
        self.* = undefined;
    }
};

pub fn expandQuery(allocator: std.mem.Allocator, query: []const u8) !ExpandedQuery {
    return query_expansion.expandQuery(allocator, query);
}

pub fn expandQueryText(allocator: std.mem.Allocator, query: []const u8) ![]u8 {
    const expansion = try expandQueryDetailed(allocator, query);
    allocator.free(expansion.keyword_query);
    allocator.free(expansion.websearch_query);
    allocator.free(expansion.terms_json);
    allocator.free(expansion.reasons_json);
    allocator.free(expansion.intents_json);
    return @constCast(expansion.expanded_query);
}

pub fn buildFts5Query(allocator: std.mem.Allocator, query: []const u8) ![]u8 {
    var terms: std.ArrayListUnmanaged([]const u8) = .empty;
    defer freeOwnedSearchTerms(allocator, &terms);
    try collectSearchTerms(allocator, query, &terms);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    for (terms.items, 0..) |term, i| {
        if (i > 0) try out.appendSlice(allocator, " OR ");
        try out.appendSlice(allocator, term);
        try out.append(allocator, '*');
    }
    return out.toOwnedSlice(allocator);
}

pub fn buildPlan(allocator: std.mem.Allocator, query: []const u8, has_vector_index: bool, allow_reranker: bool) !RetrievalPlan {
    return buildPlanWithAdaptive(allocator, query, has_vector_index, allow_reranker, .{});
}

pub fn buildPlanWithAdaptive(allocator: std.mem.Allocator, query: []const u8, has_vector_index: bool, allow_reranker: bool, adaptive: AdaptiveConfig) !RetrievalPlan {
    var expansion = try expandQueryDetailed(allocator, query);
    errdefer expansion.deinit(allocator);
    const adaptive_config = normalizeAdaptiveConfig(adaptive);
    const analysis = analyzeQuery(query, adaptive_config);
    const has_backend_terms = expansion.websearch_query.len > 0;
    const vector_available = has_backend_terms and has_vectorIndexWorthy(expansion.websearch_query) and has_vector_index;
    const use_vector = if (!has_backend_terms)
        false
    else switch (analysis.recommended_strategy) {
        .keyword_only => false,
        .vector_only, .hybrid => vector_available,
    };
    const use_keyword = if (!has_backend_terms)
        false
    else switch (analysis.recommended_strategy) {
        .vector_only => !use_vector,
        .keyword_only, .hybrid => true,
    };
    return .{
        .use_keyword = use_keyword,
        .use_vector = use_vector,
        .use_graph = has_backend_terms and queryHasEntityHint(query),
        .use_reranker = allow_reranker and has_backend_terms,
        .adaptive_enabled = adaptive_config.enabled,
        .adaptive_keyword_max_tokens = adaptive_config.keyword_max_tokens,
        .adaptive_vector_min_tokens = adaptive_config.vector_min_tokens,
        .strategy = analysis.recommended_strategy,
        .token_count = analysis.token_count,
        .has_special_chars = analysis.has_special_chars,
        .is_question = analysis.is_question,
        .avg_token_length = analysis.avg_token_length,
        .min_relevance = 0,
        .rrf_k = default_rrf_k,
        .rrf_weight = default_rrf_weight,
        .raw_score_weight = default_rrf_raw_score_weight,
        .rrf_window_multiplier = default_rrf_window_multiplier,
        .mmr_lambda = default_mmr_lambda,
        .mmr_candidate_multiplier = default_mmr_candidate_multiplier,
        .expanded_query = expansion.expanded_query,
        .keyword_query = expansion.keyword_query,
        .websearch_query = expansion.websearch_query,
        .expansion_terms_json = expansion.terms_json,
        .expansion_reasons_json = expansion.reasons_json,
        .intent_hints_json = expansion.intents_json,
        .query_expanded = expansion.changed,
    };
}

pub fn analyzeQuery(query: []const u8, config: AdaptiveConfig) QueryAnalysis {
    var token_count: u32 = 0;
    var total_char_len: u32 = 0;
    var has_special_chars = false;
    var it = std.mem.tokenizeAny(u8, query, " \t\r\n");
    while (it.next()) |token| {
        token_count += 1;
        total_char_len += @intCast(token.len);
        if (!has_special_chars) {
            for (token) |ch| {
                if (ch == '_' or ch == '.' or ch == '/' or ch == '\\' or ch == ':' or ch == '-') {
                    has_special_chars = true;
                    break;
                }
            }
        }
    }

    if (token_count == 0) {
        return .{
            .token_count = 0,
            .has_special_chars = false,
            .is_question = false,
            .avg_token_length = 0,
            .recommended_strategy = .keyword_only,
        };
    }

    const avg_token_length = @as(f32, @floatFromInt(total_char_len)) / @as(f32, @floatFromInt(token_count));
    const is_question = isQuestionQuery(query);
    const strategy: RetrievalStrategy = if (!config.enabled)
        .hybrid
    else if (has_special_chars)
        .keyword_only
    else if (token_count <= config.keyword_max_tokens)
        .keyword_only
    else if (is_question and token_count >= config.vector_min_tokens)
        .vector_only
    else
        .hybrid;

    return .{
        .token_count = token_count,
        .has_special_chars = has_special_chars,
        .is_question = is_question,
        .avg_token_length = avg_token_length,
        .recommended_strategy = strategy,
    };
}

fn isQuestionQuery(query: []const u8) bool {
    const trimmed = std.mem.trim(u8, query, " \t\r\n");
    const prefixes = [_][]const u8{
        "what ", "how ", "why ", "when ", "where ", "who ", "which ", "can ", "could ", "does ", "do ", "is ", "are ",
    };
    for (prefixes) |prefix| {
        if (startsWithAsciiIgnoreCase(trimmed, prefix)) return true;
    }
    return std.mem.startsWith(u8, trimmed, "почему ") or
        std.mem.startsWith(u8, trimmed, "как ") or
        std.mem.startsWith(u8, trimmed, "что ") or
        std.mem.startsWith(u8, trimmed, "когда ") or
        std.mem.startsWith(u8, trimmed, "где ");
}

fn expandQueryDetailed(allocator: std.mem.Allocator, query: []const u8) !QueryExpansion {
    const lower = try std.ascii.allocLowerString(allocator, query);
    defer allocator.free(lower);

    var terms: std.ArrayListUnmanaged([]const u8) = .empty;
    defer terms.deinit(allocator);
    defer freeStringList(allocator, terms.items);

    var reasons: std.ArrayListUnmanaged([]const u8) = .empty;
    defer reasons.deinit(allocator);
    defer freeStringList(allocator, reasons.items);

    var intents: std.ArrayListUnmanaged([]const u8) = .empty;
    defer intents.deinit(allocator);
    defer freeStringList(allocator, intents.items);

    try appendDomainExpansions(allocator, lower, &terms, &reasons, &intents);
    try appendIdentifierExpansions(allocator, query, &terms, &reasons, &intents);

    const expanded_query = try buildExpandedQuery(allocator, query, terms.items);
    errdefer allocator.free(expanded_query);
    const keyword_query = try allocator.dupe(u8, expanded_query);
    errdefer allocator.free(keyword_query);
    const websearch_query = try buildWebsearchQuery(allocator, query, terms.items);
    errdefer allocator.free(websearch_query);
    const terms_json = try buildStringArrayJson(allocator, terms.items);
    errdefer allocator.free(terms_json);
    const reasons_json = try buildReasonArrayJson(allocator, terms.items, reasons.items);
    errdefer allocator.free(reasons_json);
    const intents_json = try buildStringArrayJson(allocator, intents.items);
    errdefer allocator.free(intents_json);

    return .{
        .expanded_query = expanded_query,
        .keyword_query = keyword_query,
        .websearch_query = websearch_query,
        .terms_json = terms_json,
        .reasons_json = reasons_json,
        .intents_json = intents_json,
        .changed = terms.items.len > 0,
    };
}

fn appendDomainExpansions(
    allocator: std.mem.Allocator,
    lower_query: []const u8,
    terms: *std.ArrayListUnmanaged([]const u8),
    reasons: *std.ArrayListUnmanaged([]const u8),
    intents: *std.ArrayListUnmanaged([]const u8),
) !void {
    if (containsAny(lower_query, &[_][]const u8{ "pantry", "confluence", "wiki", "rag", "knowledge base", "база знаний", "память" })) {
        try appendIntent(allocator, intents, "knowledge_context");
        try appendTerms(allocator, terms, reasons, &[_][]const u8{ "memory", "knowledge", "context", "source", "artifact", "citation", "retrieval" }, "nullpantry_knowledge");
    }
    if (containsAny(lower_query, &[_][]const u8{ "decision", "adr", "rfc", "architecture decision", "решени" })) {
        try appendIntent(allocator, intents, "decision");
        try appendTerms(allocator, terms, reasons, &[_][]const u8{ "decision", "adr", "rationale", "alternative", "consequence", "accepted", "rejected", "superseded" }, "decision");
    }
    if (containsAny(lower_query, &[_][]const u8{ "incident", "outage", "postmortem", "инцидент", "авари" })) {
        try appendIntent(allocator, intents, "incident");
        try appendTerms(allocator, terms, reasons, &[_][]const u8{ "incident", "event", "outage", "postmortem", "root cause", "mitigation", "timeline", "runbook" }, "incident");
    }
    if (containsAny(lower_query, &[_][]const u8{ "runbook", "recipe", "playbook", "procedure", "ранбук", "рецепт" })) {
        try appendIntent(allocator, intents, "runbook");
        try appendTerms(allocator, terms, reasons, &[_][]const u8{ "runbook", "recipe", "playbook", "procedure", "checklist", "operations" }, "runbook");
    }
    if (containsAny(lower_query, &[_][]const u8{ "meeting", "transcript", "call", "встреч", "транскрипт" })) {
        try appendIntent(allocator, intents, "meeting");
        try appendTerms(allocator, terms, reasons, &[_][]const u8{ "meeting", "transcript", "notes", "summary", "action item", "participant", "decision" }, "meeting");
    }
    if (containsAny(lower_query, &[_][]const u8{ "ticket", "issue", "task", "jira", "тикет", "задач" })) {
        try appendIntent(allocator, intents, "ticket");
        try appendTerms(allocator, terms, reasons, &[_][]const u8{ "ticket", "issue", "task", "requirement", "implementation", "owner" }, "ticket");
    }
    if (containsAny(lower_query, &[_][]const u8{ "fresh", "stale", "deprecated", "superseded", "conflict", "verify", "актуаль", "устар" })) {
        try appendIntent(allocator, intents, "lifecycle");
        try appendTerms(allocator, terms, reasons, &[_][]const u8{ "fresh", "stale", "deprecated", "superseded", "conflict", "verified", "review" }, "lifecycle");
    }
    if (containsAny(lower_query, &[_][]const u8{ "api", "service", "repo", "repository", "owner", "endpoint", "сервис", "репозитор" })) {
        try appendIntent(allocator, intents, "entity_lookup");
        try appendTerms(allocator, terms, reasons, &[_][]const u8{ "api", "service", "endpoint", "contract", "repo", "repository", "owner", "maintainer" }, "entity_lookup");
    }
}

fn appendIdentifierExpansions(
    allocator: std.mem.Allocator,
    query: []const u8,
    terms: *std.ArrayListUnmanaged([]const u8),
    reasons: *std.ArrayListUnmanaged([]const u8),
    intents: *std.ArrayListUnmanaged([]const u8),
) !void {
    var it = std.mem.tokenizeAny(u8, query, " \t\r\n.,;()[]{}<>!?\"'");
    while (it.next()) |token| {
        if (token.len < 2) continue;
        if (ticketLike(token)) {
            try appendIntent(allocator, intents, "ticket");
            try appendTerm(allocator, terms, reasons, token, "ticket_id");
            try appendTerms(allocator, terms, reasons, &[_][]const u8{ "ticket", "issue", "task" }, "ticket_id");
        }
        if (camelOrAcronymLike(token)) {
            try appendIntent(allocator, intents, "entity_lookup");
            try appendIdentifierParts(allocator, token, terms, reasons, "identifier_parts");
        }
        if (std.mem.indexOfScalar(u8, token, ':')) |colon| {
            if (colon > 0 and colon + 1 < token.len) {
                try appendIntent(allocator, intents, "scoped_lookup");
                try appendTerm(allocator, terms, reasons, token[0..colon], "scope_prefix");
                try appendIdentifierParts(allocator, token[colon + 1 ..], terms, reasons, "scope_value");
            }
        }
        if (std.mem.indexOfScalar(u8, token, '/')) |_| {
            try appendIntent(allocator, intents, "repository");
            try appendTerms(allocator, terms, reasons, &[_][]const u8{ "repo", "repository" }, "path_like_identifier");
            var part_it = std.mem.splitScalar(u8, token, '/');
            while (part_it.next()) |part| try appendIdentifierParts(allocator, part, terms, reasons, "path_part");
        }
    }
}

fn appendIdentifierParts(
    allocator: std.mem.Allocator,
    token: []const u8,
    terms: *std.ArrayListUnmanaged([]const u8),
    reasons: *std.ArrayListUnmanaged([]const u8),
    reason: []const u8,
) !void {
    if (token.len == 0) return;
    var start: usize = 0;
    var i: usize = 1;
    while (i < token.len) : (i += 1) {
        const prev = token[i - 1];
        const ch = token[i];
        const next = if (i + 1 < token.len) token[i + 1] else 0;
        const boundary = (std.ascii.isLower(prev) and std.ascii.isUpper(ch)) or
            (std.ascii.isAlphabetic(prev) and std.ascii.isDigit(ch)) or
            (std.ascii.isDigit(prev) and std.ascii.isAlphabetic(ch)) or
            (std.ascii.isUpper(prev) and std.ascii.isUpper(ch) and next != 0 and std.ascii.isLower(next));
        if (!boundary) continue;
        try appendTerm(allocator, terms, reasons, token[start..i], reason);
        start = i;
    }
    try appendTerm(allocator, terms, reasons, token[start..], reason);
}

fn appendTerms(
    allocator: std.mem.Allocator,
    terms: *std.ArrayListUnmanaged([]const u8),
    reasons: *std.ArrayListUnmanaged([]const u8),
    values: []const []const u8,
    reason: []const u8,
) !void {
    for (values) |value| try appendTerm(allocator, terms, reasons, value, reason);
}

fn appendTerm(
    allocator: std.mem.Allocator,
    terms: *std.ArrayListUnmanaged([]const u8),
    reasons: *std.ArrayListUnmanaged([]const u8),
    raw_term: []const u8,
    reason: []const u8,
) !void {
    if (terms.items.len >= 64) return;
    const trimmed = std.mem.trim(u8, raw_term, " \t\r\n.,;:/\\-_*\"'()[]{}<>!?");
    if (trimmed.len < 2 or trimmed.len > 80) return;
    for (terms.items) |existing| {
        if (std.ascii.eqlIgnoreCase(existing, trimmed)) return;
    }
    const owned_term = try normalizeTerm(allocator, trimmed);
    errdefer allocator.free(owned_term);
    const owned_reason = try allocator.dupe(u8, reason);
    errdefer allocator.free(owned_reason);
    try terms.append(allocator, owned_term);
    errdefer _ = terms.pop();
    try reasons.append(allocator, owned_reason);
}

fn appendIntent(allocator: std.mem.Allocator, intents: *std.ArrayListUnmanaged([]const u8), raw_intent: []const u8) !void {
    for (intents.items) |existing| {
        if (std.mem.eql(u8, existing, raw_intent)) return;
    }
    try intents.append(allocator, try allocator.dupe(u8, raw_intent));
}

fn normalizeTerm(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out = try allocator.alloc(u8, raw.len);
    for (raw, 0..) |ch, i| {
        out[i] = if (ch < 0x80) std.ascii.toLower(ch) else ch;
    }
    return out;
}

fn buildExpandedQuery(allocator: std.mem.Allocator, query: []const u8, terms: []const []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, query);
    for (terms) |term| {
        if (term.len == 0) continue;
        if (out.items.len > 0) try out.append(allocator, ' ');
        try out.appendSlice(allocator, term);
    }
    return out.toOwnedSlice(allocator);
}

fn buildWebsearchQuery(allocator: std.mem.Allocator, query: []const u8, terms: []const []const u8) ![]u8 {
    var clauses: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (clauses.items) |clause| allocator.free(clause);
        clauses.deinit(allocator);
    }

    var query_terms: std.ArrayListUnmanaged([]const u8) = .empty;
    defer freeOwnedSearchTerms(allocator, &query_terms);
    try collectSearchTerms(allocator, query, &query_terms);
    if (query_terms.items.len > 0) {
        const clause = try buildWebsearchClause(allocator, query_terms.items, false);
        try appendUniqueClause(allocator, &clauses, clause);
    }

    for (terms) |term| {
        var term_tokens: std.ArrayListUnmanaged([]const u8) = .empty;
        defer freeOwnedSearchTerms(allocator, &term_tokens);
        try collectSearchTerms(allocator, term, &term_tokens);
        if (term_tokens.items.len == 0) continue;
        if (allSearchTermsPresent(query_terms.items, term_tokens.items)) continue;

        const phrase = hasWhitespace(term) and term_tokens.items.len > 1;
        const clause = try buildWebsearchClause(allocator, term_tokens.items, phrase);
        try appendUniqueClause(allocator, &clauses, clause);
    }

    return joinWebsearchClauses(allocator, clauses.items);
}

pub fn buildExactWebsearchQuery(allocator: std.mem.Allocator, query: []const u8) ![]u8 {
    return buildWebsearchQuery(allocator, query, &.{});
}

pub fn lexicalScore(query: []const u8, text: []const u8) f64 {
    if (query.len == 0 or text.len == 0) return 0.0;
    var seen_terms: [max_backend_search_terms][max_lexical_score_token_bytes]u8 = undefined;
    var seen_lens: [max_backend_search_terms]usize = undefined;
    var seen_count: usize = 0;
    var score: f64 = 0.0;

    var it = std.mem.tokenizeAny(u8, query, search_token_delimiters);
    while (it.next()) |raw| {
        if (seen_count >= max_backend_search_terms) break;
        var token_buf: [max_lexical_score_token_bytes]u8 = undefined;
        const token = normalizeLexicalScoreToken(raw, &token_buf) orelse continue;
        if (isFtsStopword(token)) continue;
        if (containsSeenLexicalTerm(&seen_terms, &seen_lens, seen_count, token)) continue;
        @memcpy(seen_terms[seen_count][0..token.len], token);
        seen_lens[seen_count] = token.len;
        seen_count += 1;
        if (searchTextContainsToken(text, token)) score += 1.0;
    }

    return score;
}

fn normalizeLexicalScoreToken(raw: []const u8, buf: *[max_lexical_score_token_bytes]u8) ?[]const u8 {
    var len: usize = 0;
    var i: usize = 0;
    while (i < raw.len) {
        const ch = raw[i];
        if (ch < 0x80) {
            i += 1;
            if (!std.ascii.isAlphanumeric(ch)) continue;
            if (len >= buf.len) return null;
            buf[len] = std.ascii.toLower(ch);
            len += 1;
        } else {
            const cp_len = std.unicode.utf8ByteSequenceLength(ch) catch {
                if (len >= buf.len) return null;
                buf[len] = ch;
                len += 1;
                i += 1;
                continue;
            };
            if (i + cp_len > raw.len) return null;
            const cp = std.unicode.utf8Decode(raw[i..][0..cp_len]) catch return null;
            const written = appendLowerUtf8CodepointToBuffer(buf[len..], cp) orelse return null;
            len += written;
            i += cp_len;
        }
    }
    if (len == 0) return null;
    return buf[0..len];
}

fn searchTextContainsToken(text: []const u8, token: []const u8) bool {
    if (text.len == 0 or token.len == 0) return false;
    var start: usize = 0;
    while (start < text.len) {
        if (searchTextStartsWithToken(text[start..], token)) return true;
        const ch = text[start];
        const cp_len = if (ch < 0x80) 1 else std.unicode.utf8ByteSequenceLength(ch) catch 1;
        start += if (start + cp_len <= text.len) cp_len else 1;
    }
    return false;
}

fn searchTextStartsWithToken(text: []const u8, token: []const u8) bool {
    var text_i: usize = 0;
    var token_i: usize = 0;
    while (token_i < token.len) {
        if (text_i >= text.len) return false;
        var lower_buf: [4]u8 = undefined;
        const lower_len = lowerSearchTextCodepoint(text[text_i..], &lower_buf) orelse return false;
        if (token_i + lower_len > token.len) return false;
        if (!std.mem.eql(u8, lower_buf[0..lower_len], token[token_i .. token_i + lower_len])) return false;
        token_i += lower_len;

        const ch = text[text_i];
        const cp_len = if (ch < 0x80) 1 else std.unicode.utf8ByteSequenceLength(ch) catch 1;
        text_i += if (text_i + cp_len <= text.len) cp_len else 1;
    }
    return true;
}

fn lowerSearchTextCodepoint(text: []const u8, out: *[4]u8) ?usize {
    if (text.len == 0) return null;
    const ch = text[0];
    if (ch < 0x80) {
        out[0] = std.ascii.toLower(ch);
        return 1;
    }
    const cp_len = std.unicode.utf8ByteSequenceLength(ch) catch {
        out[0] = ch;
        return 1;
    };
    if (cp_len > text.len) return null;
    const cp = std.unicode.utf8Decode(text[0..cp_len]) catch return null;
    return appendLowerUtf8CodepointToBuffer(out[0..], cp);
}

fn containsSeenLexicalTerm(
    seen_terms: *const [max_backend_search_terms][max_lexical_score_token_bytes]u8,
    seen_lens: *const [max_backend_search_terms]usize,
    seen_count: usize,
    token: []const u8,
) bool {
    for (0..seen_count) |i| {
        if (seen_lens[i] == token.len and std.mem.eql(u8, seen_terms[i][0..seen_lens[i]], token)) return true;
    }
    return false;
}

fn collectSearchTerms(allocator: std.mem.Allocator, text: []const u8, out: *std.ArrayListUnmanaged([]const u8)) !void {
    var it = std.mem.tokenizeAny(u8, text, search_token_delimiters);
    while (it.next()) |raw| {
        if (out.items.len >= max_backend_search_terms) return;
        try appendSearchTerm(allocator, out, raw);
    }
}

fn appendSearchTerm(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged([]const u8), raw: []const u8) !void {
    var token: std.ArrayListUnmanaged(u8) = .empty;
    defer token.deinit(allocator);

    var i: usize = 0;
    while (i < raw.len) {
        const ch = raw[i];
        if (ch < 0x80) {
            if (std.ascii.isAlphanumeric(ch)) try token.append(allocator, std.ascii.toLower(ch));
            i += 1;
        } else {
            const cp_len = std.unicode.utf8ByteSequenceLength(ch) catch {
                try token.append(allocator, ch);
                i += 1;
                continue;
            };
            if (i + cp_len > raw.len) {
                try token.appendSlice(allocator, raw[i..]);
                break;
            }
            const cp = std.unicode.utf8Decode(raw[i..][0..cp_len]) catch {
                try token.appendSlice(allocator, raw[i..][0..cp_len]);
                i += cp_len;
                continue;
            };
            try appendLowerUtf8Codepoint(allocator, &token, cp);
            i += cp_len;
        }
    }

    if (token.items.len == 0) return;
    if (isFtsStopword(token.items)) return;
    for (out.items) |existing| {
        if (std.mem.eql(u8, existing, token.items)) return;
    }

    const owned = try token.toOwnedSlice(allocator);
    errdefer allocator.free(owned);
    try out.append(allocator, owned);
}

fn lowercaseSearchCodepoint(cp: u21) u21 {
    if (cp >= 0x0410 and cp <= 0x042F) return cp + 0x20;
    if (cp == 0x0401) return 0x0451;
    return cp;
}

fn appendLowerUtf8Codepoint(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), cp: u21) !void {
    const lowered = lowercaseSearchCodepoint(cp);
    if (lowered <= 0x7F) {
        try out.append(allocator, @intCast(lowered));
    } else if (lowered <= 0x7FF) {
        try out.append(allocator, @intCast(0xC0 | (lowered >> 6)));
        try out.append(allocator, @intCast(0x80 | (lowered & 0x3F)));
    } else if (lowered <= 0xFFFF) {
        try out.append(allocator, @intCast(0xE0 | (lowered >> 12)));
        try out.append(allocator, @intCast(0x80 | ((lowered >> 6) & 0x3F)));
        try out.append(allocator, @intCast(0x80 | (lowered & 0x3F)));
    } else {
        try out.append(allocator, @intCast(0xF0 | (lowered >> 18)));
        try out.append(allocator, @intCast(0x80 | ((lowered >> 12) & 0x3F)));
        try out.append(allocator, @intCast(0x80 | ((lowered >> 6) & 0x3F)));
        try out.append(allocator, @intCast(0x80 | (lowered & 0x3F)));
    }
}

fn appendLowerUtf8CodepointToBuffer(buf: []u8, cp: u21) ?usize {
    const lowered = lowercaseSearchCodepoint(cp);
    if (lowered <= 0x7F) {
        if (buf.len < 1) return null;
        buf[0] = @intCast(lowered);
        return 1;
    } else if (lowered <= 0x7FF) {
        if (buf.len < 2) return null;
        buf[0] = @intCast(0xC0 | (lowered >> 6));
        buf[1] = @intCast(0x80 | (lowered & 0x3F));
        return 2;
    } else if (lowered <= 0xFFFF) {
        if (buf.len < 3) return null;
        buf[0] = @intCast(0xE0 | (lowered >> 12));
        buf[1] = @intCast(0x80 | ((lowered >> 6) & 0x3F));
        buf[2] = @intCast(0x80 | (lowered & 0x3F));
        return 3;
    } else {
        if (buf.len < 4) return null;
        buf[0] = @intCast(0xF0 | (lowered >> 18));
        buf[1] = @intCast(0x80 | ((lowered >> 12) & 0x3F));
        buf[2] = @intCast(0x80 | ((lowered >> 6) & 0x3F));
        buf[3] = @intCast(0x80 | (lowered & 0x3F));
        return 4;
    }
}

fn freeOwnedSearchTerms(allocator: std.mem.Allocator, terms: *std.ArrayListUnmanaged([]const u8)) void {
    for (terms.items) |term| allocator.free(term);
    terms.deinit(allocator);
}

fn allSearchTermsPresent(existing: []const []const u8, terms: []const []const u8) bool {
    if (existing.len == 0 or terms.len == 0) return false;
    for (terms) |term| {
        var found = false;
        for (existing) |candidate| {
            if (std.mem.eql(u8, candidate, term)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

fn buildWebsearchClause(allocator: std.mem.Allocator, terms: []const []const u8, phrase: bool) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    if (phrase) try out.append(allocator, '"');
    for (terms, 0..) |term, i| {
        if (i > 0) try out.append(allocator, ' ');
        try out.appendSlice(allocator, term);
    }
    if (phrase) try out.append(allocator, '"');
    return out.toOwnedSlice(allocator);
}

fn appendUniqueClause(allocator: std.mem.Allocator, clauses: *std.ArrayListUnmanaged([]const u8), owned_clause: []const u8) !void {
    if (owned_clause.len == 0) {
        allocator.free(owned_clause);
        return;
    }
    for (clauses.items) |existing| {
        if (std.mem.eql(u8, existing, owned_clause)) {
            allocator.free(owned_clause);
            return;
        }
    }
    errdefer allocator.free(owned_clause);
    try clauses.append(allocator, owned_clause);
}

fn joinWebsearchClauses(allocator: std.mem.Allocator, clauses: []const []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    for (clauses, 0..) |clause, i| {
        if (i > 0) try out.appendSlice(allocator, " OR ");
        try out.appendSlice(allocator, clause);
    }
    return out.toOwnedSlice(allocator);
}

fn hasWhitespace(text: []const u8) bool {
    for (text) |ch| {
        if (std.ascii.isWhitespace(ch)) return true;
    }
    return false;
}

fn buildStringArrayJson(allocator: std.mem.Allocator, values: []const []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '[');
    for (values, 0..) |value, i| {
        if (i > 0) try out.append(allocator, ',');
        try json.appendString(&out, allocator, value);
    }
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

fn buildReasonArrayJson(allocator: std.mem.Allocator, terms: []const []const u8, reasons: []const []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '[');
    for (terms, 0..) |term, i| {
        if (i > 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, "{\"term\":");
        try json.appendString(&out, allocator, term);
        try out.appendSlice(allocator, ",\"reason\":");
        try json.appendString(&out, allocator, if (i < reasons.len) reasons[i] else "query_expansion");
        try out.append(allocator, '}');
    }
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

fn freeStringList(allocator: std.mem.Allocator, list: []const []const u8) void {
    for (list) |item| allocator.free(item);
}

fn containsAny(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (std.mem.indexOf(u8, haystack, needle) != null) return true;
    }
    return false;
}

fn isFtsStopword(token: []const u8) bool {
    return fts_stopwords.has(token);
}

const fts_stopwords = std.StaticStringMap(void).initComptime(.{
    .{"a"},     .{"an"},    .{"and"},  .{"are"},   .{"as"},   .{"at"},
    .{"be"},    .{"by"},    .{"can"},  .{"could"}, .{"do"},   .{"does"},
    .{"for"},   .{"from"},  .{"get"},  .{"give"},  .{"has"},  .{"have"},
    .{"help"},  .{"how"},   .{"i"},    .{"in"},    .{"is"},   .{"it"},
    .{"its"},   .{"me"},    .{"my"},   .{"not"},   .{"of"},   .{"on"},
    .{"or"},    .{"our"},   .{"show"}, .{"that"},  .{"the"},  .{"this"},
    .{"to"},    .{"was"},   .{"we"},   .{"were"},  .{"what"}, .{"when"},
    .{"where"}, .{"which"}, .{"who"},  .{"why"},   .{"with"}, .{"would"},
    .{"you"},   .{"your"},
    .{"как"},
    .{"мы"},
    .{"где"},
    .{"делать"},
    .{"для"},
    .{"до"},
    .{"зачем"},
    .{"или"},
    .{"им"},
    .{"их"},
    .{"и"},
    .{"когда"},
    .{"кто"},
    .{"ли"},
    .{"на"},
    .{"нам"},
    .{"нас"},
    .{"над"},
    .{"не"},
    .{"но"},
    .{"о"},
    .{"об"},
    .{"он"},
    .{"она"},
    .{"они"},
    .{"оно"},
    .{"от"},
    .{"по"},
    .{"под"},
    .{"почему"},
    .{"при"},
    .{"про"},
    .{"с"},
    .{"со"},
    .{"так"},
    .{"то"},
    .{"у"},
    .{"чем"},
    .{"что"},
    .{"чтобы"},
    .{"это"},
    .{"этот"},
    .{"эта"},
    .{"эти"},
    .{"бы"},
    .{"был"},
    .{"была"},
    .{"были"},
    .{"быть"},
    .{"сделать"},
});

fn has_vectorIndexWorthy(query: []const u8) bool {
    return query.len > 8;
}

pub fn queryHasEntityHint(query: []const u8) bool {
    var tokens = std.mem.tokenizeAny(u8, query, " \t\r\n.,;()[]{}<>!?\"'");
    while (tokens.next()) |token| {
        if (token.len < 3) continue;
        if (std.mem.indexOfScalar(u8, token, ':') != null or std.mem.indexOfScalar(u8, token, '/') != null) return true;
        if (ticketLike(token) or camelOrAcronymLike(token)) return true;
    }
    return containsAsciiIgnoreCase(query, "service") or
        containsAsciiIgnoreCase(query, "repo") or
        containsAsciiIgnoreCase(query, "ticket") or
        containsAsciiIgnoreCase(query, "incident") or
        containsAsciiIgnoreCase(query, "owner") or
        containsAsciiIgnoreCase(query, "api");
}

fn containsAsciiIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn startsWithAsciiIgnoreCase(haystack: []const u8, prefix: []const u8) bool {
    if (prefix.len > haystack.len) return false;
    for (prefix, 0..) |ch, i| {
        if (std.ascii.toLower(haystack[i]) != std.ascii.toLower(ch)) return false;
    }
    return true;
}

fn ticketLike(token: []const u8) bool {
    const dash = std.mem.indexOfScalar(u8, token, '-') orelse return false;
    if (dash == 0 or dash + 1 >= token.len) return false;
    var saw_alpha = false;
    for (token[0..dash]) |ch| {
        if (!std.ascii.isAlphabetic(ch)) return false;
        saw_alpha = true;
    }
    var saw_digit = false;
    for (token[dash + 1 ..]) |ch| {
        if (!std.ascii.isDigit(ch)) return false;
        saw_digit = true;
    }
    return saw_alpha and saw_digit;
}

fn camelOrAcronymLike(token: []const u8) bool {
    var upper: usize = 0;
    var lower: usize = 0;
    var digit: usize = 0;
    for (token) |ch| {
        if (std.ascii.isUpper(ch)) upper += 1 else if (std.ascii.isLower(ch)) lower += 1 else if (std.ascii.isDigit(ch)) digit += 1 else return false;
    }
    return (upper >= 2 and lower > 0) or (upper >= 2 and digit > 0) or (upper >= 3 and token.len <= 12);
}

fn sortRanked(items: []RankedItem) void {
    var i: usize = 0;
    while (i < items.len) : (i += 1) {
        var best = i;
        var j = i + 1;
        while (j < items.len) : (j += 1) {
            if (rankedItemBetter(items[j], items[best])) best = j;
        }
        if (best != i) std.mem.swap(RankedItem, &items[i], &items[best]);
    }
}

fn rankedItemBetter(candidate: RankedItem, best: RankedItem) bool {
    if (candidate.score > best.score) return true;
    if (candidate.score < best.score) return false;
    if (candidate.confidence > best.confidence) return true;
    if (candidate.confidence < best.confidence) return false;
    if (candidate.created_at_ms > best.created_at_ms) return true;
    if (candidate.created_at_ms < best.created_at_ms) return false;
    return std.mem.order(u8, candidate.id, best.id) == .lt;
}

test "retrieval RRF promotes consensus results" {
    const a = [_]RankedItem{ .{ .id = "a", .score = 10 }, .{ .id = "b", .score = 9 } };
    const b = [_]RankedItem{ .{ .id = "c", .score = 10 }, .{ .id = "a", .score = 9 } };
    const lists = [_][]const RankedItem{ &a, &b };
    const fused = try reciprocalRankFusion(std.testing.allocator, &lists, 60, 10);
    defer std.testing.allocator.free(fused);
    try std.testing.expectEqualStrings("a", fused[0].id);
}

test "retrieval RRF has deterministic tie ordering" {
    const b = [_]RankedItem{.{ .id = "b", .score = 1 }};
    const a = [_]RankedItem{.{ .id = "a", .score = 1 }};
    const lists = [_][]const RankedItem{ &b, &a };
    const fused = try reciprocalRankFusion(std.testing.allocator, &lists, 60, 10);
    defer std.testing.allocator.free(fused);
    try std.testing.expectEqual(@as(usize, 2), fused.len);
    try std.testing.expectEqualStrings("a", fused[0].id);
    try std.testing.expectEqualStrings("b", fused[1].id);
}

test "retrieval RRF retains strongest duplicate metadata" {
    const old = [_]RankedItem{.{ .id = "memory", .score = 1, .created_at_ms = 10, .confidence = 0.2 }};
    const fresh = [_]RankedItem{.{ .id = "memory", .score = 1, .created_at_ms = 20, .confidence = 0.9 }};
    const lists = [_][]const RankedItem{ &old, &fresh };
    const fused = try reciprocalRankFusion(std.testing.allocator, &lists, 60, 10);
    defer std.testing.allocator.free(fused);
    try std.testing.expectEqual(@as(usize, 1), fused.len);
    try std.testing.expectEqual(@as(i64, 20), fused[0].created_at_ms);
    try std.testing.expectApproxEqAbs(@as(f64, 0.9), fused[0].confidence, 0.000001);
}

test "retrieval temporal decay lowers old scores" {
    const fresh = applyTemporalDecay(1.0, 0, 7);
    const old = applyTemporalDecay(1.0, 14 * 24 * 60 * 60 * 1000, 7);
    try std.testing.expect(fresh > old);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), old, 0.0001);
}

test "retrieval temporal decay age keeps unknown and future timestamps fresh" {
    try std.testing.expectEqual(@as(i64, 0), temporalDecayAgeMs(1_000, 0));
    try std.testing.expectEqual(@as(i64, 0), temporalDecayAgeMs(1_000, -1));
    try std.testing.expectEqual(@as(i64, 0), temporalDecayAgeMs(1_000, 2_000));
    try std.testing.expectEqual(@as(i64, 600), temporalDecayAgeMs(1_000, 400));
    try std.testing.expectEqual(std.math.maxInt(i64) - 1, temporalDecayAgeMs(std.math.maxInt(i64), 1));
}

test "retrieval temporal decay rerank does not add confidence twice" {
    const items = [_]RankedItem{
        .{ .id = "trusted", .score = 0.8, .confidence = 0.99, .created_at_ms = 0 },
        .{ .id = "relevant", .score = 1.0, .confidence = 0.1, .created_at_ms = 0 },
    };
    const ranked = try rerankByTemporalDecay(std.testing.allocator, &items, 1000, 30, 10);
    defer std.testing.allocator.free(ranked);
    try std.testing.expectEqualStrings("relevant", ranked[0].id);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), ranked[0].score, 0.000001);
    try std.testing.expectEqualStrings("trusted", ranked[1].id);
    try std.testing.expectApproxEqAbs(@as(f64, 0.8), ranked[1].score, 0.000001);
}

test "retrieval MMR diversifies selections" {
    const candidates = [_]MmrCandidate{
        .{ .id = "a", .score = 1, .embedding = &[_]f32{ 1, 0 } },
        .{ .id = "b", .score = 0.99, .embedding = &[_]f32{ 1, 0 } },
        .{ .id = "c", .score = 0.8, .embedding = &[_]f32{ 0, 1 } },
    };
    const selected = try mmrSelect(std.testing.allocator, &[_]f32{ 1, 0 }, &candidates, 0.5, 2);
    defer std.testing.allocator.free(selected);
    try std.testing.expectEqual(@as(usize, 2), selected.len);
    try std.testing.expectEqualStrings("a", selected[0].id);
    try std.testing.expectEqualStrings("c", selected[1].id);
    try std.testing.expect(selected[0].score != candidates[0].score);
    try std.testing.expect(selected[1].score != candidates[2].score);
}

test "retrieval MMR is deterministic for score ties and zero limits" {
    const empty = try mmrSelect(std.testing.allocator, &[_]f32{ 1, 0 }, &[_]MmrCandidate{}, 0.5, 10);
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);

    const candidates = [_]MmrCandidate{
        .{ .id = "b", .score = 1, .embedding = &[_]f32{ 1, 0 } },
        .{ .id = "a", .score = 1, .embedding = &[_]f32{ 1, 0 } },
    };
    const selected = try mmrSelect(std.testing.allocator, &[_]f32{ 1, 0 }, &candidates, std.math.nan(f64), 1);
    defer std.testing.allocator.free(selected);
    try std.testing.expectEqual(@as(usize, 1), selected.len);
    try std.testing.expectEqualStrings("a", selected[0].id);
}

test "retrieval MMR lambda controls relevance diversity tradeoff" {
    const candidates = [_]MmrCandidate{
        .{ .id = "a", .score = 1, .embedding = &[_]f32{ 1, 0 } },
        .{ .id = "b", .score = 0.99, .embedding = &[_]f32{ 1, 0 } },
        .{ .id = "c", .score = 0.2, .embedding = &[_]f32{ 0, 1 } },
    };

    const relevance_first = try mmrSelect(std.testing.allocator, &[_]f32{ 1, 0 }, &candidates, 1.0, 2);
    defer std.testing.allocator.free(relevance_first);
    try std.testing.expectEqualStrings("a", relevance_first[0].id);
    try std.testing.expectEqualStrings("b", relevance_first[1].id);

    const diverse = try mmrSelect(std.testing.allocator, &[_]f32{ 1, 0 }, &candidates, 0.5, 2);
    defer std.testing.allocator.free(diverse);
    try std.testing.expectEqualStrings("a", diverse[0].id);
    try std.testing.expectEqualStrings("c", diverse[1].id);
}

test "retrieval query expansion and plan expose stages" {
    var plan = try buildPlan(std.testing.allocator, "NullPantry decision", true, true);
    defer plan.deinit(std.testing.allocator);
    try std.testing.expect(plan.use_keyword);
    try std.testing.expect(!plan.use_vector);
    try std.testing.expect(plan.use_graph);
    try std.testing.expect(plan.use_reranker);
    try std.testing.expect(plan.adaptive_enabled);
    try std.testing.expectEqual(RetrievalStrategy.keyword_only, plan.strategy);
    try std.testing.expectEqual(@as(u32, 2), plan.token_count);
    try std.testing.expect(std.mem.indexOf(u8, plan.expanded_query, "adr") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan.keyword_query, "rationale") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan.websearch_query, " OR adr") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan.expansion_terms_json, "\"adr\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan.expansion_reasons_json, "\"reason\":\"decision\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan.intent_hints_json, "\"decision\"") != null);
    try std.testing.expect(plan.query_expanded);
}

test "retrieval re-exports nullclaw compatible structured query expansion" {
    var expanded = try expandQuery(std.testing.allocator, "what is the best way to learn Zig");
    defer expanded.deinit(std.testing.allocator);

    try std.testing.expectEqual(Language.en, expanded.language);
    try std.testing.expect(std.mem.indexOf(u8, expanded.fts5_query, "zig*") != null);
    try std.testing.expect(expanded.original_tokens.len > expanded.filtered_tokens.len);

    const keywords = try extractKeywords(std.testing.allocator, "best way to learn Zig");
    defer {
        for (keywords) |keyword| std.testing.allocator.free(keyword);
        std.testing.allocator.free(keywords);
    }
    try std.testing.expectEqualStrings("best", keywords[0]);
}

test "retrieval fts5 query builder filters stopwords operators and duplicates" {
    const fts = try buildFts5Query(std.testing.allocator, "What is the API API decision OR ticket?");
    defer std.testing.allocator.free(fts);

    try std.testing.expect(std.mem.indexOf(u8, fts, "api*") != null);
    try std.testing.expect(std.mem.indexOf(u8, fts, "decision*") != null);
    try std.testing.expect(std.mem.indexOf(u8, fts, "ticket*") != null);
    try std.testing.expect(std.mem.indexOf(u8, fts, "what*") == null);
    try std.testing.expect(std.mem.indexOf(u8, fts, " or*") == null);
    try std.testing.expect(std.mem.indexOf(u8, fts, "api* OR api*") == null);
}

test "retrieval fts5 query builder preserves unicode terms and strips syntax" {
    const fts = try buildFts5Query(std.testing.allocator, "scope:project/NullPantry почему решение устарело");
    defer std.testing.allocator.free(fts);

    try std.testing.expect(std.mem.indexOf(u8, fts, "scope*") != null);
    try std.testing.expect(std.mem.indexOf(u8, fts, "project*") != null);
    try std.testing.expect(std.mem.indexOf(u8, fts, "nullpantry*") != null);
    try std.testing.expect(std.mem.indexOf(u8, fts, "почему*") == null);
    try std.testing.expect(std.mem.indexOf(u8, fts, "решение*") != null);
    try std.testing.expect(std.mem.indexOf(u8, fts, "устарело*") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, fts, ':') == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, fts, '/') == null);
}

test "retrieval fts5 query builder filters Russian question stopwords" {
    const fts = try buildFts5Query(std.testing.allocator, "Почему мы решили делать NullPantry как отдельный продукт");
    defer std.testing.allocator.free(fts);

    try std.testing.expect(std.mem.indexOf(u8, fts, "решили*") != null);
    try std.testing.expect(std.mem.indexOf(u8, fts, "nullpantry*") != null);
    try std.testing.expect(std.mem.indexOf(u8, fts, "отдельный*") != null);
    try std.testing.expect(std.mem.indexOf(u8, fts, "продукт*") != null);
    try std.testing.expect(std.mem.indexOf(u8, fts, "почему*") == null);
    try std.testing.expect(std.mem.indexOf(u8, fts, "мы*") == null);
    try std.testing.expect(std.mem.indexOf(u8, fts, "делать*") == null);
    try std.testing.expect(std.mem.indexOf(u8, fts, "как*") == null);
}

test "retrieval websearch query builder sanitizes operators and expansion terms" {
    const web = try buildWebsearchQuery(
        std.testing.allocator,
        "scope:project/NullPantry ??? OR OR decision",
        &[_][]const u8{ "adr", "decision", "root cause", "action item" },
    );
    defer std.testing.allocator.free(web);

    try std.testing.expectEqualStrings("scope project nullpantry decision OR adr OR \"root cause\" OR \"action item\"", web);
    try std.testing.expect(std.mem.indexOf(u8, web, "???") == null);
    try std.testing.expect(std.mem.indexOf(u8, web, " OR OR ") == null);
    try std.testing.expect(std.mem.indexOf(u8, web, "decision OR decision") == null);
}

test "retrieval lexical scoring uses backend search terms" {
    try std.testing.expectEqual(@as(f64, 0.0), lexicalScore("??? OR AND the", "the and or"));
    try std.testing.expectEqual(@as(f64, 1.0), lexicalScore("decision decision OR what", "ADR decision rationale"));
    try std.testing.expectEqual(@as(f64, 2.0), lexicalScore("scope:project/NullPantry", "project nullpantry docs"));
    try std.testing.expectEqual(@as(f64, 1.0), lexicalScore("почему решение", "РЕШЕНИЕ принято"));
}

test "retrieval plan disables backend retrieval for empty sanitized queries" {
    var plan = try buildPlan(std.testing.allocator, "??? OR AND the", true, true);
    defer plan.deinit(std.testing.allocator);

    try std.testing.expect(!plan.use_keyword);
    try std.testing.expect(!plan.use_vector);
    try std.testing.expect(!plan.use_graph);
    try std.testing.expect(!plan.use_reranker);
    try std.testing.expectEqualStrings("", plan.websearch_query);
}

test "retrieval adaptive strategy selects keyword vector and hybrid modes" {
    const key = analyzeQuery("src/memory/root.zig", .{});
    try std.testing.expectEqual(RetrievalStrategy.keyword_only, key.recommended_strategy);
    try std.testing.expect(key.has_special_chars);

    const question = analyzeQuery("how does the central memory retrieval system select context", .{});
    try std.testing.expectEqual(RetrievalStrategy.vector_only, question.recommended_strategy);
    try std.testing.expect(question.is_question);

    const adaptive_off = analyzeQuery("src/memory/root.zig", .{ .enabled = false });
    try std.testing.expectEqual(RetrievalStrategy.hybrid, adaptive_off.recommended_strategy);
    try std.testing.expectEqual(@as(u32, 1), adaptive_off.token_count);
    try std.testing.expect(adaptive_off.has_special_chars);

    var vector_plan = try buildPlan(std.testing.allocator, "how does the central memory retrieval system select context", true, false);
    defer vector_plan.deinit(std.testing.allocator);
    try std.testing.expect(!vector_plan.use_keyword);
    try std.testing.expect(vector_plan.use_vector);

    var no_vector_plan = try buildPlan(std.testing.allocator, "how does the central memory retrieval system select context", false, false);
    defer no_vector_plan.deinit(std.testing.allocator);
    try std.testing.expect(no_vector_plan.use_keyword);
    try std.testing.expect(!no_vector_plan.use_vector);
}

test "retrieval plan enables graph for tickets repos and service-like names" {
    var a = try buildPlan(std.testing.allocator, "ABC-123 owner", true, false);
    defer a.deinit(std.testing.allocator);
    try std.testing.expect(a.use_graph);
    try std.testing.expect(std.mem.indexOf(u8, a.expanded_query, "ticket") != null);

    var b = try buildPlan(std.testing.allocator, "AuthService incident", true, false);
    defer b.deinit(std.testing.allocator);
    try std.testing.expect(b.use_graph);
    try std.testing.expect(std.mem.indexOf(u8, b.expanded_query, "auth") != null);
    try std.testing.expect(std.mem.indexOf(u8, b.expanded_query, "outage") != null);
}

test "retrieval query expansion covers Russian product vocabulary" {
    var plan = try buildPlan(std.testing.allocator, "почему это решение устарело", false, false);
    defer plan.deinit(std.testing.allocator);
    try std.testing.expect(plan.query_expanded);
    try std.testing.expect(std.mem.indexOf(u8, plan.expanded_query, "adr") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan.expanded_query, "stale") != null);
}
