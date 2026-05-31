const std = @import("std");
const json = @import("json_util.zig");
const vector = @import("vector.zig");

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
    strategy: RetrievalStrategy,
    token_count: u32,
    has_special_chars: bool,
    is_question: bool,
    avg_token_length: f32,
    min_relevance: f64,
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

pub fn reciprocalRankFusion(allocator: std.mem.Allocator, lists: []const []const RankedItem, k: f64, limit: usize) ![]RankedItem {
    var fused: std.ArrayListUnmanaged(RankedItem) = .empty;
    errdefer fused.deinit(allocator);
    for (lists) |list| {
        for (list, 0..) |item, rank| {
            const contribution = 1.0 / (k + @as(f64, @floatFromInt(rank + 1)));
            if (findItem(fused.items, item.id)) |idx| {
                fused.items[idx].score += contribution;
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

pub fn rerankByQuality(allocator: std.mem.Allocator, items: []const RankedItem, now_ms: i64, half_life_days: f64, limit: usize) ![]RankedItem {
    var out = try allocator.alloc(RankedItem, items.len);
    errdefer allocator.free(out);
    for (items, 0..) |item, i| {
        const age = if (item.created_at_ms > 0 and now_ms > item.created_at_ms) now_ms - item.created_at_ms else 0;
        out[i] = item;
        out[i].score = applyTemporalDecay(item.score, age, half_life_days) + item.confidence;
    }
    sortRanked(out);
    if (out.len > limit) return allocator.realloc(out, limit);
    return out;
}

pub fn mmrSelect(allocator: std.mem.Allocator, query_embedding: []const f32, candidates: []const MmrCandidate, lambda: f64, limit: usize) ![]RankedItem {
    var selected_indices: std.ArrayListUnmanaged(usize) = .empty;
    defer selected_indices.deinit(allocator);
    var used = try allocator.alloc(bool, candidates.len);
    defer allocator.free(used);
    @memset(used, false);

    while (selected_indices.items.len < limit and selected_indices.items.len < candidates.len) {
        var best_idx: ?usize = null;
        var best_score: f64 = -999999;
        for (candidates, 0..) |candidate, i| {
            if (used[i]) continue;
            var max_selected_similarity: f64 = 0;
            for (selected_indices.items) |selected_idx| {
                max_selected_similarity = @max(max_selected_similarity, vector.cosine(candidate.embedding, candidates[selected_idx].embedding));
            }
            const relevance = @as(f64, vector.cosine(query_embedding, candidate.embedding));
            const mmr_score = lambda * relevance + (1.0 - lambda) * candidate.score - (1.0 - lambda) * max_selected_similarity;
            if (best_idx == null or mmr_score > best_score) {
                best_idx = i;
                best_score = mmr_score;
            }
        }
        const idx = best_idx orelse break;
        used[idx] = true;
        try selected_indices.append(allocator, idx);
    }

    var out = try allocator.alloc(RankedItem, selected_indices.items.len);
    for (selected_indices.items, 0..) |idx, i| {
        out[i] = .{ .id = candidates[idx].id, .score = candidates[idx].score };
    }
    return out;
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

pub fn expandQuery(allocator: std.mem.Allocator, query: []const u8) ![]u8 {
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
    const analysis = analyzeQuery(query, adaptive);
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
        .use_reranker = allow_reranker,
        .adaptive_enabled = adaptive.enabled,
        .strategy = analysis.recommended_strategy,
        .token_count = analysis.token_count,
        .has_special_chars = analysis.has_special_chars,
        .is_question = analysis.is_question,
        .avg_token_length = analysis.avg_token_length,
        .min_relevance = 0,
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

    for (raw) |ch| {
        if (ch < 0x80) {
            if (std.ascii.isAlphanumeric(ch)) try token.append(allocator, std.ascii.toLower(ch));
        } else {
            try token.append(allocator, ch);
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
    .{"где"},
    .{"для"},
    .{"зачем"},
    .{"или"},
    .{"и"},
    .{"когда"},
    .{"кто"},
    .{"на"},
    .{"не"},
    .{"о"},
    .{"об"},
    .{"от"},
    .{"по"},
    .{"почему"},
    .{"про"},
    .{"с"},
    .{"что"},
    .{"это"},
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
            if (items[j].score > items[best].score) best = j;
        }
        if (best != i) std.mem.swap(RankedItem, &items[i], &items[best]);
    }
}

test "retrieval RRF promotes consensus results" {
    const a = [_]RankedItem{ .{ .id = "a", .score = 10 }, .{ .id = "b", .score = 9 } };
    const b = [_]RankedItem{ .{ .id = "c", .score = 10 }, .{ .id = "a", .score = 9 } };
    const lists = [_][]const RankedItem{ &a, &b };
    const fused = try reciprocalRankFusion(std.testing.allocator, &lists, 60, 10);
    defer std.testing.allocator.free(fused);
    try std.testing.expectEqualStrings("a", fused[0].id);
}

test "retrieval temporal decay lowers old scores" {
    const fresh = applyTemporalDecay(1.0, 0, 7);
    const old = applyTemporalDecay(1.0, 14 * 24 * 60 * 60 * 1000, 7);
    try std.testing.expect(fresh > old);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), old, 0.0001);
}

test "retrieval MMR diversifies selections" {
    const candidates = [_]MmrCandidate{
        .{ .id = "a", .score = 1, .embedding = &[_]f32{ 1, 0 } },
        .{ .id = "b", .score = 0.9, .embedding = &[_]f32{ 1, 0 } },
        .{ .id = "c", .score = 0.8, .embedding = &[_]f32{ 0, 1 } },
    };
    const selected = try mmrSelect(std.testing.allocator, &[_]f32{ 1, 0 }, &candidates, 0.5, 2);
    defer std.testing.allocator.free(selected);
    try std.testing.expectEqual(@as(usize, 2), selected.len);
    try std.testing.expectEqualStrings("a", selected[0].id);
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

test "retrieval plan disables backend retrieval for empty sanitized queries" {
    var plan = try buildPlan(std.testing.allocator, "??? OR AND the", true, true);
    defer plan.deinit(std.testing.allocator);

    try std.testing.expect(!plan.use_keyword);
    try std.testing.expect(!plan.use_vector);
    try std.testing.expect(!plan.use_graph);
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
