const std = @import("std");
const domain = @import("domain.zig");

pub const RetrievalStage = enum {
    query_expansion,
    keyword,
    vector,
    merge_rrf,
    min_relevance,
    temporal_decay,
    mmr,
    llm_rerank,
    limit,

    pub fn name(self: RetrievalStage) []const u8 {
        return @tagName(self);
    }
};

pub const pipeline_order = [_]RetrievalStage{
    .query_expansion,
    .keyword,
    .vector,
    .merge_rrf,
    .min_relevance,
    .temporal_decay,
    .mmr,
    .llm_rerank,
    .limit,
};

pub const SourceCapabilities = struct {
    has_keyword_rank: bool = false,
    has_vector_search: bool = false,
    is_readonly: bool = true,
};

pub const RetrievalCandidate = struct {
    id: []const u8,
    key: []const u8,
    content: []const u8,
    snippet: []const u8,
    result_type: []const u8,
    scope: []const u8,
    status: []const u8,
    source: []const u8,
    source_path: []const u8 = "",
    store: []const u8 = "",
    session_id: ?[]const u8 = null,
    keyword_rank: ?u32 = null,
    vector_score: ?f32 = null,
    final_score: f64 = 0,
    start_line: u32 = 0,
    end_line: u32 = 0,
    created_at_ms: i64 = 0,
    confidence: f64 = 0.5,

    pub fn toSearchResult(self: RetrievalCandidate) domain.SearchResult {
        return .{
            .id = self.id,
            .result_type = self.result_type,
            .title = self.key,
            .text = self.content,
            .scope = self.scope,
            .status = self.status,
            .score = self.final_score,
            .source_ids_json = "[]",
            .created_at_ms = self.created_at_ms,
            .confidence = self.confidence,
            .store = self.store,
            .session_id = self.session_id,
        };
    }
};

pub fn fromSearchResult(result: domain.SearchResult, rank: usize) RetrievalCandidate {
    return .{
        .id = result.id,
        .key = result.title,
        .content = result.text,
        .snippet = result.text,
        .result_type = result.result_type,
        .scope = result.scope,
        .status = result.status,
        .source = if (result.store.len > 0) result.store else "nullpantry",
        .store = result.store,
        .session_id = result.session_id,
        .keyword_rank = @intCast(rank + 1),
        .final_score = result.score,
        .created_at_ms = result.created_at_ms,
        .confidence = result.confidence,
    };
}

pub fn searchResultsToCandidates(allocator: std.mem.Allocator, results: []const domain.SearchResult) ![]RetrievalCandidate {
    const candidates = try allocator.alloc(RetrievalCandidate, results.len);
    for (results, 0..) |result, i| {
        candidates[i] = fromSearchResult(result, i);
    }
    return candidates;
}

pub fn freeCandidates(allocator: std.mem.Allocator, candidates: []RetrievalCandidate) void {
    allocator.free(candidates);
}

pub fn candidatesToSearchResults(allocator: std.mem.Allocator, candidates: []const RetrievalCandidate) ![]domain.SearchResult {
    const results = try allocator.alloc(domain.SearchResult, candidates.len);
    for (candidates, 0..) |candidate, i| {
        results[i] = candidate.toSearchResult();
    }
    return results;
}

pub fn reorderCandidates(allocator: std.mem.Allocator, candidates: []const RetrievalCandidate, ranking: []const usize) ![]RetrievalCandidate {
    if (candidates.len == 0) return allocator.alloc(RetrievalCandidate, 0);

    const ordered = try allocator.alloc(RetrievalCandidate, candidates.len);
    errdefer allocator.free(ordered);

    const selected = try allocator.alloc(bool, candidates.len);
    defer allocator.free(selected);
    @memset(selected, false);

    var out_idx: usize = 0;
    for (ranking) |one_based| {
        if (one_based == 0 or one_based > candidates.len) continue;
        const idx = one_based - 1;
        if (selected[idx]) continue;
        ordered[out_idx] = candidates[idx];
        selected[idx] = true;
        out_idx += 1;
    }

    for (candidates, 0..) |candidate, i| {
        if (selected[i]) continue;
        ordered[out_idx] = candidate;
        out_idx += 1;
    }

    return ordered;
}

pub fn pipelineOrderJson(allocator: std.mem.Allocator) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '[');
    for (&pipeline_order, 0..) |stage, i| {
        if (i > 0) try out.append(allocator, ',');
        try out.append(allocator, '"');
        try out.appendSlice(allocator, stage.name());
        try out.append(allocator, '"');
    }
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

test "retrieval engine exposes canonical pipeline order" {
    try std.testing.expectEqual(RetrievalStage.query_expansion, pipeline_order[0]);
    try std.testing.expectEqual(RetrievalStage.limit, pipeline_order[pipeline_order.len - 1]);

    const json = try pipelineOrderJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings("[\"query_expansion\",\"keyword\",\"vector\",\"merge_rrf\",\"min_relevance\",\"temporal_decay\",\"mmr\",\"llm_rerank\",\"limit\"]", json);
}

test "retrieval engine converts search results to candidate views" {
    const result = domain.SearchResult{
        .id = "mem_1",
        .result_type = "agent_memory",
        .title = "Preference",
        .text = "Prefer concise Zig examples",
        .scope = "project:nullpantry",
        .status = "active",
        .score = 0.75,
        .source_ids_json = "[]",
        .store = "scratch",
        .session_id = "s1",
        .created_at_ms = 42,
        .confidence = 0.9,
    };

    const candidates = try searchResultsToCandidates(std.testing.allocator, &[_]domain.SearchResult{result});
    defer freeCandidates(std.testing.allocator, candidates);
    try std.testing.expectEqualStrings("mem_1", candidates[0].id);
    try std.testing.expectEqualStrings("Preference", candidates[0].key);
    try std.testing.expectEqualStrings("scratch", candidates[0].source);
    try std.testing.expectEqual(@as(?u32, 1), candidates[0].keyword_rank);

    const roundtrip = candidates[0].toSearchResult();
    try std.testing.expectEqualStrings("agent_memory", roundtrip.result_type);
    try std.testing.expectEqualStrings("Prefer concise Zig examples", roundtrip.text);
    try std.testing.expectEqualStrings("scratch", roundtrip.store);
    try std.testing.expectEqualStrings("s1", roundtrip.session_id.?);
}

test "retrieval engine reorders candidates and appends omitted entries" {
    const candidates = [_]RetrievalCandidate{
        .{ .id = "a", .key = "A", .content = "alpha", .snippet = "alpha", .result_type = "memory_atom", .scope = "public", .status = "verified", .source = "test" },
        .{ .id = "b", .key = "B", .content = "beta", .snippet = "beta", .result_type = "memory_atom", .scope = "public", .status = "verified", .source = "test" },
        .{ .id = "c", .key = "C", .content = "gamma", .snippet = "gamma", .result_type = "memory_atom", .scope = "public", .status = "verified", .source = "test" },
    };
    const ordered = try reorderCandidates(std.testing.allocator, &candidates, &[_]usize{ 2, 1 });
    defer std.testing.allocator.free(ordered);
    try std.testing.expectEqualStrings("b", ordered[0].id);
    try std.testing.expectEqualStrings("a", ordered[1].id);
    try std.testing.expectEqualStrings("c", ordered[2].id);
}
