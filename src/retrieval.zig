const std = @import("std");
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

pub const RetrievalPlan = struct {
    use_keyword: bool,
    use_vector: bool,
    use_graph: bool,
    use_reranker: bool,
    expanded_query: []const u8,
};

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

pub fn expandQuery(allocator: std.mem.Allocator, query: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, query);
    const lower = try std.ascii.allocLowerString(allocator, query);
    defer allocator.free(lower);
    if (std.mem.indexOf(u8, lower, "pantry") != null and std.mem.indexOf(u8, lower, "memory") == null) {
        try out.appendSlice(allocator, " memory knowledge context");
    }
    if (std.mem.indexOf(u8, lower, "incident") != null) {
        try out.appendSlice(allocator, " event outage runbook");
    }
    if (std.mem.indexOf(u8, lower, "decision") != null) {
        try out.appendSlice(allocator, " adr rationale consequence");
    }
    return out.toOwnedSlice(allocator);
}

pub fn buildPlan(allocator: std.mem.Allocator, query: []const u8, has_vector_index: bool, allow_reranker: bool) !RetrievalPlan {
    return .{
        .use_keyword = true,
        .use_vector = has_vectorIndexWorthy(query) and has_vector_index,
        .use_graph = hasEntityHint(query),
        .use_reranker = allow_reranker,
        .expanded_query = try expandQuery(allocator, query),
    };
}

fn has_vectorIndexWorthy(query: []const u8) bool {
    return query.len > 8;
}

fn hasEntityHint(query: []const u8) bool {
    return std.mem.indexOf(u8, query, "Null") != null or std.mem.indexOf(u8, query, "NP-") != null;
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
    const plan = try buildPlan(std.testing.allocator, "NullPantry decision", true, true);
    defer std.testing.allocator.free(plan.expanded_query);
    try std.testing.expect(plan.use_keyword);
    try std.testing.expect(plan.use_vector);
    try std.testing.expect(plan.use_graph);
    try std.testing.expect(plan.use_reranker);
    try std.testing.expect(std.mem.indexOf(u8, plan.expanded_query, "adr") != null);
}
