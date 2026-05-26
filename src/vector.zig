const std = @import("std");
const json = @import("json_util.zig");

pub const VectorRecord = struct {
    id: []const u8,
    object_type: []const u8 = "memory_atom",
    text: []const u8 = "",
    scope: []const u8 = "workspace",
    embedding: []const f32,
};

pub const VectorMatch = struct {
    id: []const u8,
    object_type: []const u8,
    text: []const u8,
    scope: []const u8,
    score: f32,

    pub fn writeJson(self: VectorMatch, allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
        try out.appendSlice(allocator, "{\"id\":");
        try json.appendString(out, allocator, self.id);
        try out.appendSlice(allocator, ",\"object_type\":");
        try json.appendString(out, allocator, self.object_type);
        try out.appendSlice(allocator, ",\"text\":");
        try json.appendString(out, allocator, self.text);
        try out.appendSlice(allocator, ",\"scope\":");
        try json.appendString(out, allocator, self.scope);
        try out.print(allocator, ",\"score\":{d}}}", .{self.score});
    }
};

pub fn cosine(a: []const f32, b: []const f32) f32 {
    if (a.len == 0 or b.len == 0 or a.len != b.len) return 0;
    var dot: f64 = 0;
    var norm_a: f64 = 0;
    var norm_b: f64 = 0;
    for (a, b) |av, bv| {
        if (!std.math.isFinite(av) or !std.math.isFinite(bv)) return 0;
        dot += @as(f64, av) * @as(f64, bv);
        norm_a += @as(f64, av) * @as(f64, av);
        norm_b += @as(f64, bv) * @as(f64, bv);
    }
    if (norm_a <= 0 or norm_b <= 0) return 0;
    const raw = dot / (@sqrt(norm_a) * @sqrt(norm_b));
    if (!std.math.isFinite(raw)) return 0;
    return @floatCast(@max(0, @min(1, raw)));
}

pub fn embeddingFromJson(allocator: std.mem.Allocator, raw: []const u8) ![]f32 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch return error.InvalidEmbeddingJson;
    defer parsed.deinit();
    const arr = switch (parsed.value) {
        .array => |a| a,
        else => return error.InvalidEmbeddingJson,
    };
    var values = try allocator.alloc(f32, arr.items.len);
    errdefer allocator.free(values);
    for (arr.items, 0..) |item, i| {
        values[i] = switch (item) {
            .float => |f| @floatCast(f),
            .integer => |n| @floatFromInt(n),
            else => return error.InvalidEmbeddingJson,
        };
        if (!std.math.isFinite(values[i])) return error.InvalidEmbeddingJson;
    }
    return values;
}

pub fn embeddingToJson(allocator: std.mem.Allocator, values: []const f32) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '[');
    for (values, 0..) |value, i| {
        if (i > 0) try out.append(allocator, ',');
        try out.print(allocator, "{d}", .{value});
    }
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

pub fn deterministicEmbedding(allocator: std.mem.Allocator, text: []const u8, dimensions: usize) ![]f32 {
    if (dimensions == 0) return error.InvalidDimensions;
    var values = try allocator.alloc(f32, dimensions);
    @memset(values, 0);
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n.,;:/\\-_*\"'()[]{}<>!?");
    while (it.next()) |token| {
        const hash = std.hash.Wyhash.hash(0, token);
        const idx: usize = @intCast(hash % dimensions);
        values[idx] += 1;
    }
    normalize(values);
    return values;
}

pub fn normalize(values: []f32) void {
    var norm: f64 = 0;
    for (values) |value| norm += @as(f64, value) * @as(f64, value);
    if (norm <= 0) return;
    const divisor: f32 = @floatCast(@sqrt(norm));
    for (values) |*value| value.* /= divisor;
}

pub fn bruteForceSearch(allocator: std.mem.Allocator, query: []const f32, records: []const VectorRecord, limit: usize) ![]VectorMatch {
    var matches: std.ArrayListUnmanaged(VectorMatch) = .empty;
    errdefer matches.deinit(allocator);
    for (records) |record| {
        const score = cosine(query, record.embedding);
        if (score <= 0) continue;
        try matches.append(allocator, .{
            .id = record.id,
            .object_type = record.object_type,
            .text = record.text,
            .scope = record.scope,
            .score = score,
        });
    }
    sortMatches(matches.items);
    if (matches.items.len > limit) matches.shrinkRetainingCapacity(limit);
    return matches.toOwnedSlice(allocator);
}

fn sortMatches(items: []VectorMatch) void {
    var i: usize = 0;
    while (i < items.len) : (i += 1) {
        var best = i;
        var j = i + 1;
        while (j < items.len) : (j += 1) {
            if (items[j].score > items[best].score) best = j;
        }
        if (best != i) std.mem.swap(VectorMatch, &items[i], &items[best]);
    }
}

pub const Chunk = struct {
    text: []const u8,
    ordinal: usize,
};

pub fn chunkText(allocator: std.mem.Allocator, text: []const u8, max_chars: usize, overlap: usize) ![]Chunk {
    if (max_chars == 0 or overlap >= max_chars) return error.InvalidChunkConfig;
    var chunks: std.ArrayListUnmanaged(Chunk) = .empty;
    errdefer chunks.deinit(allocator);
    var start: usize = 0;
    var ordinal: usize = 0;
    while (start < text.len) : (ordinal += 1) {
        const end = @min(text.len, start + max_chars);
        try chunks.append(allocator, .{ .text = text[start..end], .ordinal = ordinal });
        if (end == text.len) break;
        start = end - overlap;
    }
    return chunks.toOwnedSlice(allocator);
}

test "vector cosine handles common edge cases" {
    const a = [_]f32{ 1, 0, 0 };
    const b = [_]f32{ 1, 0, 0 };
    const c = [_]f32{ 0, 1, 0 };
    try std.testing.expectApproxEqAbs(@as(f32, 1), cosine(&a, &b), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), cosine(&a, &c), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), cosine(&a, &[_]f32{ 0, 0 }), 0.0001);
}

test "vector json round-trips embeddings" {
    const alloc = std.testing.allocator;
    const raw = try embeddingToJson(alloc, &[_]f32{ 0.25, 0.5, 1.0 });
    defer alloc.free(raw);
    const parsed = try embeddingFromJson(alloc, raw);
    defer alloc.free(parsed);
    try std.testing.expectEqual(@as(usize, 3), parsed.len);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), parsed[1], 0.0001);
}

test "vector brute force search ranks by cosine" {
    const alloc = std.testing.allocator;
    const records = [_]VectorRecord{
        .{ .id = "a", .embedding = &[_]f32{ 1, 0 }, .text = "alpha" },
        .{ .id = "b", .embedding = &[_]f32{ 0, 1 }, .text = "beta" },
    };
    const matches = try bruteForceSearch(alloc, &[_]f32{ 1, 0 }, &records, 10);
    defer alloc.free(matches);
    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expectEqualStrings("a", matches[0].id);
}

test "vector chunker uses overlap" {
    const chunks = try chunkText(std.testing.allocator, "abcdefghij", 4, 1);
    defer std.testing.allocator.free(chunks);
    try std.testing.expectEqual(@as(usize, 3), chunks.len);
    try std.testing.expectEqualStrings("abcd", chunks[0].text);
    try std.testing.expectEqualStrings("defg", chunks[1].text);
}
