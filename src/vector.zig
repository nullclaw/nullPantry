const std = @import("std");
const json = @import("json_util.zig");

pub const VectorRecord = struct {
    id: []const u8,
    object_id: []const u8,
    object_type: []const u8 = "memory_atom",
    text: []const u8 = "",
    scope: []const u8 = "workspace",
    heading_path_json: []const u8 = "[]",
    embedding: []const f32,
};

pub const VectorMatch = struct {
    id: []const u8,
    object_id: []const u8,
    object_type: []const u8,
    text: []const u8,
    scope: []const u8,
    heading_path_json: []const u8 = "[]",
    score: f32,

    pub fn writeJson(self: VectorMatch, allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
        try out.appendSlice(allocator, "{\"id\":");
        try json.appendString(out, allocator, self.id);
        try out.appendSlice(allocator, ",\"object_id\":");
        try json.appendString(out, allocator, self.object_id);
        try out.appendSlice(allocator, ",\"object_type\":");
        try json.appendString(out, allocator, self.object_type);
        try out.appendSlice(allocator, ",\"text\":");
        try json.appendString(out, allocator, self.text);
        try out.appendSlice(allocator, ",\"scope\":");
        try json.appendString(out, allocator, self.scope);
        try out.appendSlice(allocator, ",\"heading_path\":");
        try json.appendRawJsonOr(out, allocator, self.heading_path_json, "[]");
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
            .object_id = record.object_id,
            .object_type = record.object_type,
            .text = record.text,
            .scope = record.scope,
            .heading_path_json = record.heading_path_json,
            .score = score,
        });
    }
    sortMatches(matches.items);
    if (matches.items.len > limit) matches.shrinkRetainingCapacity(limit);
    return matches.toOwnedSlice(allocator);
}

pub fn annSearch(allocator: std.mem.Allocator, query: []const f32, records: []const VectorRecord, candidate_limit: usize, limit: usize) ![]VectorMatch {
    if (records.len <= candidate_limit or query.len == 0) {
        return bruteForceSearch(allocator, query, records, limit);
    }

    var candidates: std.ArrayListUnmanaged(VectorRecord) = .empty;
    defer candidates.deinit(allocator);
    const query_sig = signature(query);
    const max_hamming: u6 = if (records.len > 1024) 12 else 16;
    for (records) |record| {
        const record_sig = signature(record.embedding);
        if (@popCount(query_sig ^ record_sig) <= max_hamming) {
            try candidates.append(allocator, record);
            if (candidates.items.len >= candidate_limit) break;
        }
    }

    if (candidates.items.len < @min(limit, records.len)) {
        return bruteForceSearch(allocator, query, records, limit);
    }
    return bruteForceSearch(allocator, query, candidates.items, limit);
}

fn signature(values: []const f32) u64 {
    var sig: u64 = 0;
    const dims = @min(values.len, 64);
    for (values[0..dims], 0..) |value, i| {
        if (value > 0) sig |= (@as(u64, 1) << @intCast(i));
    }
    return sig;
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
    start: usize,
    end: usize,
    heading: ?[]const u8 = null,
};

pub fn chunkText(allocator: std.mem.Allocator, text: []const u8, max_chars: usize, overlap: usize) ![]Chunk {
    if (max_chars == 0 or overlap >= max_chars) return error.InvalidChunkConfig;
    var chunks: std.ArrayListUnmanaged(Chunk) = .empty;
    errdefer chunks.deinit(allocator);

    const debommed_start: usize = if (text.len >= 3 and text[0] == 0xEF and text[1] == 0xBB and text[2] == 0xBF) 3 else 0;
    var start = skipWhitespaceForward(text, debommed_start, text.len);
    while (start < text.len) {
        const end = chunkEnd(text, start, max_chars);
        const trimmed_start = skipWhitespaceForward(text, start, end);
        const trimmed_end = trimWhitespaceBackward(text, trimmed_start, end);
        if (trimmed_start < trimmed_end) {
            try chunks.append(allocator, .{
                .text = text[trimmed_start..trimmed_end],
                .ordinal = chunks.items.len,
                .start = trimmed_start,
                .end = trimmed_end,
                .heading = headingAt(text, trimmed_start),
            });
        }
        if (end == text.len) break;
        start = if (overlap > 0 and end > overlap) previousUtf8Boundary(text, end - overlap, 0) else end;
        start = skipWhitespaceForward(text, start, text.len);
    }
    return chunks.toOwnedSlice(allocator);
}

pub fn chunkHeadingPathJson(allocator: std.mem.Allocator, text: []const u8, chunk: Chunk) ![]u8 {
    return headingPathJsonAt(allocator, text, chunk.start);
}

fn headingAt(text: []const u8, pos: usize) ?[]const u8 {
    var path: [6]?[]const u8 = .{ null, null, null, null, null, null };
    scanHeadingPath(text, pos, &path);
    var level: usize = path.len;
    while (level > 0) : (level -= 1) {
        if (path[level - 1]) |heading| return heading;
    }
    return null;
}

fn headingPathJsonAt(allocator: std.mem.Allocator, text: []const u8, pos: usize) ![]u8 {
    var path: [6]?[]const u8 = .{ null, null, null, null, null, null };
    scanHeadingPath(text, pos, &path);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '[');
    var wrote = false;
    for (path) |maybe_heading| {
        const heading = maybe_heading orelse continue;
        if (wrote) try out.append(allocator, ',');
        try json.appendString(&out, allocator, heading);
        wrote = true;
    }
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

fn scanHeadingPath(text: []const u8, pos: usize, path: *[6]?[]const u8) void {
    const limit = @min(pos, text.len);
    var line_start: usize = 0;
    while (line_start < text.len and line_start <= limit) {
        const line_end = std.mem.indexOfScalarPos(u8, text, line_start, '\n') orelse text.len;
        if (markdownHeadingLevelAt(text, line_start)) |level| {
            const idx = level - 1;
            path[idx] = std.mem.trim(u8, text[line_start..line_end], " \t\r\n");
            var clear_idx = idx + 1;
            while (clear_idx < path.len) : (clear_idx += 1) path[clear_idx] = null;
        }
        if (line_end == text.len) break;
        line_start = line_end + 1;
    }
}

fn chunkEnd(text: []const u8, start: usize, max_chars: usize) usize {
    const hard_end = previousUtf8Boundary(text, @min(text.len, start + max_chars), start + 1);
    if (findNextMarkdownHeading(text, start + 1, hard_end)) |heading_start| return heading_start;
    if (hard_end >= text.len) return text.len;
    const min_split = @min(hard_end, start + @min(max_chars / 3, 600));
    if (findPreviousParagraphBreak(text, min_split, hard_end)) |paragraph_end| return paragraph_end;
    if (findPreviousLineBreak(text, min_split, hard_end)) |line_end| return line_end;
    if (findPreviousWhitespace(text, min_split, hard_end)) |space_end| return space_end;
    return hard_end;
}

fn findNextMarkdownHeading(text: []const u8, start: usize, end: usize) ?usize {
    var pos = start;
    while (pos < end) : (pos += 1) {
        if (text[pos] != '\n') continue;
        const line_start = pos + 1;
        if (line_start < end and isMarkdownHeadingAt(text, line_start)) return line_start;
    }
    return null;
}

fn isMarkdownHeadingAt(text: []const u8, pos: usize) bool {
    return markdownHeadingLevelAt(text, pos) != null;
}

fn markdownHeadingLevelAt(text: []const u8, pos: usize) ?usize {
    if (pos > 0 and text[pos - 1] != '\n') return null;
    var i = pos;
    var hashes: usize = 0;
    while (i < text.len and text[i] == '#' and hashes < 6) : ({
        i += 1;
        hashes += 1;
    }) {}
    if (hashes == 0) return null;
    if (i >= text.len) return hashes;
    if (text[i] == ' ' or text[i] == '\t') return hashes;
    return null;
}

fn findPreviousParagraphBreak(text: []const u8, min_pos: usize, end: usize) ?usize {
    if (end < 2) return null;
    var pos = end;
    while (pos > min_pos + 1) : (pos -= 1) {
        if (text[pos - 1] == '\n' and text[pos - 2] == '\n') return pos;
    }
    return null;
}

fn findPreviousLineBreak(text: []const u8, min_pos: usize, end: usize) ?usize {
    var pos = end;
    while (pos > min_pos) : (pos -= 1) {
        if (text[pos - 1] == '\n') return pos;
    }
    return null;
}

fn findPreviousWhitespace(text: []const u8, min_pos: usize, end: usize) ?usize {
    var pos = end;
    while (pos > min_pos) : (pos -= 1) {
        if (std.ascii.isWhitespace(text[pos - 1])) return pos;
    }
    return null;
}

fn skipWhitespaceForward(text: []const u8, start: usize, end: usize) usize {
    var pos = start;
    while (pos < end and std.ascii.isWhitespace(text[pos])) : (pos += 1) {}
    return pos;
}

fn trimWhitespaceBackward(text: []const u8, start: usize, end: usize) usize {
    var pos = end;
    while (pos > start and std.ascii.isWhitespace(text[pos - 1])) : (pos -= 1) {}
    return pos;
}

fn previousUtf8Boundary(text: []const u8, pos: usize, min_pos: usize) usize {
    var out = @min(pos, text.len);
    while (out > min_pos and out < text.len and (text[out] & 0b1100_0000) == 0b1000_0000) : (out -= 1) {}
    return out;
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
        .{ .id = "vec_a", .object_id = "a", .embedding = &[_]f32{ 1, 0 }, .text = "alpha" },
        .{ .id = "vec_b", .object_id = "b", .embedding = &[_]f32{ 0, 1 }, .text = "beta" },
    };
    const matches = try bruteForceSearch(alloc, &[_]f32{ 1, 0 }, &records, 10);
    defer alloc.free(matches);
    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expectEqualStrings("a", matches[0].object_id);
}

test "vector ANN prefilter falls back safely" {
    const alloc = std.testing.allocator;
    const records = [_]VectorRecord{
        .{ .id = "vec_a", .object_id = "a", .embedding = &[_]f32{ 1, 0 }, .text = "alpha" },
        .{ .id = "vec_b", .object_id = "b", .embedding = &[_]f32{ 0, 1 }, .text = "beta" },
    };
    const matches = try annSearch(alloc, &[_]f32{ 1, 0 }, &records, 1, 1);
    defer alloc.free(matches);
    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expectEqualStrings("a", matches[0].object_id);
}

test "vector chunker uses overlap" {
    const chunks = try chunkText(std.testing.allocator, "abcdefghij", 4, 1);
    defer std.testing.allocator.free(chunks);
    try std.testing.expectEqual(@as(usize, 3), chunks.len);
    try std.testing.expectEqualStrings("abcd", chunks[0].text);
    try std.testing.expectEqualStrings("defg", chunks[1].text);
}

test "vector chunker respects markdown heading boundaries" {
    const text = "# First\nAlpha\n## Second\nBeta\n## Third\nGamma";
    const chunks = try chunkText(std.testing.allocator, text, 64, 0);
    defer std.testing.allocator.free(chunks);
    try std.testing.expectEqual(@as(usize, 3), chunks.len);
    try std.testing.expect(std.mem.startsWith(u8, chunks[0].text, "# First"));
    try std.testing.expect(std.mem.startsWith(u8, chunks[1].text, "## Second"));
    try std.testing.expect(std.mem.startsWith(u8, chunks[2].text, "## Third"));
    try std.testing.expectEqualStrings("# First", chunks[0].heading.?);
    try std.testing.expectEqualStrings("## Second", chunks[1].heading.?);
    try std.testing.expectEqualStrings("## Third", chunks[2].heading.?);
}

test "vector chunker serializes heading path metadata" {
    const text = "# Product\nIntro\n## Architecture\nDetails\n### Storage\nPostgres and SQLite";
    const chunks = try chunkText(std.testing.allocator, text, 512, 0);
    defer std.testing.allocator.free(chunks);
    try std.testing.expectEqual(@as(usize, 3), chunks.len);
    const path = try chunkHeadingPathJson(std.testing.allocator, text, chunks[2]);
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("[\"# Product\",\"## Architecture\",\"### Storage\"]", path);
}

test "vector chunker preserves utf8 boundaries" {
    const text = "Знание Знание Знание Знание Знание";
    const chunks = try chunkText(std.testing.allocator, text, 10, 0);
    defer std.testing.allocator.free(chunks);
    try std.testing.expect(chunks.len > 1);
    for (chunks) |chunk| try std.testing.expect(std.unicode.utf8ValidateSlice(chunk.text));
}

test "vector chunker strips bom and whitespace" {
    const chunks = try chunkText(std.testing.allocator, "\xEF\xBB\xBF  # Title\nBody  \n", 64, 0);
    defer std.testing.allocator.free(chunks);
    try std.testing.expectEqual(@as(usize, 1), chunks.len);
    try std.testing.expectEqualStrings("# Title\nBody", chunks[0].text);
}
