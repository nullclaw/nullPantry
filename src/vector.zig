const std = @import("std");
const json = @import("json_util.zig");
const bounded_int = @import("bounded_int.zig");

pub const ann_signature_bits: u32 = 64;
pub const ann_band_bits: u32 = 16;
pub const ann_band_count: u32 = ann_signature_bits / ann_band_bits;
pub const max_embedding_dimensions: usize = 4096;

pub fn boundedEmbeddingDimensions(value: ?i64, fallback: usize) usize {
    if (value) |raw| {
        return @max(@as(usize, 1), bounded_int.positiveI64ToUsizeBounded(raw, max_embedding_dimensions));
    }
    return @max(@as(usize, 1), @min(fallback, max_embedding_dimensions));
}

pub fn chunkOrdinalFromIndex(index: usize) i64 {
    return bounded_int.usizeToI64Saturating(index);
}

pub fn embeddingDimensionsFromLength(length: usize) i64 {
    return bounded_int.usizeToI64Saturating(length);
}

test "vector embedding dimensions are bounded for runtime allocation" {
    try std.testing.expectEqual(@as(usize, 1), boundedEmbeddingDimensions(null, 0));
    try std.testing.expectEqual(@as(usize, 64), boundedEmbeddingDimensions(null, 64));
    try std.testing.expectEqual(@as(usize, 1), boundedEmbeddingDimensions(0, 64));
    try std.testing.expectEqual(@as(usize, 1), boundedEmbeddingDimensions(1, 64));
    try std.testing.expectEqual(@as(usize, 1), boundedEmbeddingDimensions(-5, 64));
    try std.testing.expectEqual(max_embedding_dimensions, boundedEmbeddingDimensions(9223372036854775807, 64));
    try std.testing.expectEqual(max_embedding_dimensions, boundedEmbeddingDimensions(null, max_embedding_dimensions + 1));
}

test "vector chunk ordinal conversion saturates indexes" {
    try std.testing.expectEqual(@as(i64, 0), chunkOrdinalFromIndex(0));
    try std.testing.expectEqual(@as(i64, 42), chunkOrdinalFromIndex(42));
    try std.testing.expectEqual(std.math.maxInt(i64), chunkOrdinalFromIndex(std.math.maxInt(usize)));
}

test "vector embedding dimension length conversion saturates" {
    try std.testing.expectEqual(@as(i64, 0), embeddingDimensionsFromLength(0));
    try std.testing.expectEqual(@as(i64, 1536), embeddingDimensionsFromLength(1536));
    try std.testing.expectEqual(std.math.maxInt(i64), embeddingDimensionsFromLength(std.math.maxInt(usize)));
}

pub const VectorRecord = struct {
    id: []const u8,
    object_id: []const u8,
    object_type: []const u8 = "memory_atom",
    text: []const u8 = "",
    scope: []const u8 = "workspace",
    heading_path_json: []const u8 = "[]",
    start_byte: i64 = 0,
    end_byte: i64 = 0,
    content_hash: []const u8 = "",
    chunk_strategy: []const u8 = "plain",
    estimated_tokens: i64 = 0,
    transcript_timestamp: ?[]const u8 = null,
    transcript_speaker: ?[]const u8 = null,
    embedding: []const f32,
};

pub const VectorMatch = struct {
    id: []const u8,
    object_id: []const u8,
    object_type: []const u8,
    text: []const u8,
    scope: []const u8,
    heading_path_json: []const u8 = "[]",
    start_byte: i64 = 0,
    end_byte: i64 = 0,
    content_hash: []const u8 = "",
    chunk_strategy: []const u8 = "plain",
    estimated_tokens: i64 = 0,
    transcript_timestamp: ?[]const u8 = null,
    transcript_speaker: ?[]const u8 = null,
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
        try json.appendRawJsonArray(out, allocator, self.heading_path_json);
        try out.print(allocator, ",\"start_byte\":{d},\"end_byte\":{d},\"content_hash\":", .{ self.start_byte, self.end_byte });
        try json.appendString(out, allocator, self.content_hash);
        try out.appendSlice(allocator, ",\"chunk_strategy\":");
        try json.appendString(out, allocator, self.chunk_strategy);
        try out.print(allocator, ",\"estimated_tokens\":{d},\"transcript_timestamp\":", .{self.estimated_tokens});
        try json.appendNullableString(out, allocator, self.transcript_timestamp);
        try out.appendSlice(allocator, ",\"transcript_speaker\":");
        try json.appendNullableString(out, allocator, self.transcript_speaker);
        try out.print(allocator, ",\"score\":{d}}}", .{self.score});
    }
};

test "vector match json enforces heading path array root" {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(std.testing.allocator);

    try std.testing.expectError(error.InvalidRawJson, (VectorMatch{
        .id = "vec_1",
        .object_id = "atom_1",
        .object_type = "memory_atom",
        .text = "hello",
        .scope = "public",
        .heading_path_json = "{\"heading\":\"Intro\"}",
        .score = 0.9,
    }).writeJson(std.testing.allocator, &out));
}

pub fn deinitMatch(allocator: std.mem.Allocator, match: *VectorMatch) void {
    allocator.free(match.id);
    allocator.free(match.object_id);
    allocator.free(match.object_type);
    allocator.free(match.text);
    allocator.free(match.scope);
    allocator.free(match.heading_path_json);
    allocator.free(match.content_hash);
    allocator.free(match.chunk_strategy);
    if (match.transcript_timestamp) |value| allocator.free(value);
    if (match.transcript_speaker) |value| allocator.free(value);
    match.* = undefined;
}

pub fn deinitMatches(allocator: std.mem.Allocator, matches: []VectorMatch) void {
    for (matches) |*match| deinitMatch(allocator, match);
}

pub fn freeMatches(allocator: std.mem.Allocator, matches: []VectorMatch) void {
    deinitMatches(allocator, matches);
    allocator.free(matches);
}

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

pub const cosineSimilarity = cosine;

pub fn vecToBytes(allocator: std.mem.Allocator, values: []const f32) ![]u8 {
    const bytes = try allocator.alloc(u8, values.len * @sizeOf(f32));
    for (values, 0..) |value, i| {
        const raw: [4]u8 = @bitCast(value);
        @memcpy(bytes[i * 4 ..][0..4], &raw);
    }
    return bytes;
}

pub fn bytesToVec(allocator: std.mem.Allocator, bytes: []const u8) ![]f32 {
    const count = bytes.len / @sizeOf(f32);
    const values = try allocator.alloc(f32, count);
    for (values, 0..) |*value, i| {
        const raw = bytes[i * 4 ..][0..4];
        value.* = @bitCast(raw.*);
    }
    return values;
}

pub const ScoredResult = struct {
    id: []const u8,
    vector_score: ?f32 = null,
    keyword_score: ?f32 = null,
    final_score: f32 = 0,
};

pub const IdScore = struct {
    id: []const u8,
    score: f32,
};

pub fn hybridMerge(
    allocator: std.mem.Allocator,
    vector_results: []const IdScore,
    keyword_results: []const IdScore,
    vector_weight: f32,
    keyword_weight: f32,
    limit: usize,
) ![]ScoredResult {
    var ids: std.ArrayListUnmanaged([]const u8) = .empty;
    defer ids.deinit(allocator);

    var vector_scores = std.StringHashMap(f32).init(allocator);
    defer vector_scores.deinit();
    var keyword_scores = std.StringHashMap(f32).init(allocator);
    defer keyword_scores.deinit();

    for (vector_results) |result| {
        const entry = try vector_scores.getOrPut(result.id);
        if (!entry.found_existing) {
            entry.value_ptr.* = result.score;
            try ids.append(allocator, result.id);
        } else {
            entry.value_ptr.* = @max(entry.value_ptr.*, result.score);
        }
    }

    var max_keyword: f32 = 0;
    for (keyword_results) |result| max_keyword = @max(max_keyword, result.score);
    if (max_keyword < std.math.floatEps(f32)) max_keyword = 1;

    for (keyword_results) |result| {
        const normalized = result.score / max_keyword;
        const entry = try keyword_scores.getOrPut(result.id);
        if (!entry.found_existing) {
            entry.value_ptr.* = normalized;
            if (!vector_scores.contains(result.id)) try ids.append(allocator, result.id);
        } else {
            entry.value_ptr.* = @max(entry.value_ptr.*, normalized);
        }
    }

    var results: std.ArrayListUnmanaged(ScoredResult) = .empty;
    defer results.deinit(allocator);
    for (ids.items) |id| {
        const vector_score = vector_scores.get(id);
        const keyword_score = keyword_scores.get(id);
        const vector_value = vector_score orelse 0;
        const keyword_value = keyword_score orelse 0;
        try results.append(allocator, .{
            .id = id,
            .vector_score = vector_score,
            .keyword_score = keyword_score,
            .final_score = vector_weight * vector_value + keyword_weight * keyword_value,
        });
    }

    std.mem.sortUnstable(ScoredResult, results.items, {}, struct {
        fn lessThan(_: void, left: ScoredResult, right: ScoredResult) bool {
            return left.final_score > right.final_score;
        }
    }.lessThan);

    return allocator.dupe(ScoredResult, results.items[0..@min(limit, results.items.len)]);
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
    errdefer {
        deinitMatches(allocator, matches.items);
        matches.deinit(allocator);
    }
    for (records) |record| {
        const score = cosine(query, record.embedding);
        if (score <= 0) continue;
        try matches.append(allocator, try matchFromRecord(allocator, record, score));
    }
    sortMatches(matches.items);
    if (matches.items.len > limit) matches.shrinkRetainingCapacity(limit);
    return matches.toOwnedSlice(allocator);
}

fn matchFromRecord(allocator: std.mem.Allocator, record: VectorRecord, score: f32) !VectorMatch {
    var match = VectorMatch{
        .id = try allocator.dupe(u8, record.id),
        .object_id = "",
        .object_type = "",
        .text = "",
        .scope = "",
        .heading_path_json = "",
        .content_hash = "",
        .chunk_strategy = "",
        .score = score,
    };
    errdefer deinitMatch(allocator, &match);
    match.object_id = try allocator.dupe(u8, record.object_id);
    match.object_type = try allocator.dupe(u8, record.object_type);
    match.text = try allocator.dupe(u8, record.text);
    match.scope = try allocator.dupe(u8, record.scope);
    match.heading_path_json = try allocator.dupe(u8, record.heading_path_json);
    match.start_byte = record.start_byte;
    match.end_byte = record.end_byte;
    match.content_hash = try allocator.dupe(u8, record.content_hash);
    match.chunk_strategy = try allocator.dupe(u8, record.chunk_strategy);
    match.estimated_tokens = record.estimated_tokens;
    match.transcript_timestamp = if (record.transcript_timestamp) |value| try allocator.dupe(u8, value) else null;
    match.transcript_speaker = if (record.transcript_speaker) |value| try allocator.dupe(u8, value) else null;
    return match;
}

pub fn annSearch(allocator: std.mem.Allocator, query: []const f32, records: []const VectorRecord, candidate_limit: usize, limit: usize) ![]VectorMatch {
    if (records.len <= candidate_limit or query.len == 0) {
        return bruteForceSearch(allocator, query, records, limit);
    }

    var candidates: std.ArrayListUnmanaged(VectorRecord) = .empty;
    defer candidates.deinit(allocator);
    const query_sig = simhashSignature(query);
    const max_hamming: u6 = if (records.len > 1024) 12 else 16;
    for (records) |record| {
        const record_sig = simhashSignature(record.embedding);
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

fn mix64(x_raw: u64) u64 {
    var x = x_raw;
    x ^= x >> 30;
    x *%= 0xbf58476d1ce4e5b9;
    x ^= x >> 27;
    x *%= 0x94d049bb133111eb;
    x ^= x >> 31;
    return x;
}

fn projectionCoeff(bit_idx: u32, dim_idx: usize) f64 {
    const seed_a = @as(u64, bit_idx) *% 0x9E3779B185EBCA87;
    const dim_u64: u64 = @intCast(dim_idx);
    const seed_b = dim_u64 *% 0xC2B2AE3D27D4EB4F;
    const hashed = mix64(seed_a ^ seed_b ^ 0xD6E8FEB86659FD93);
    const unit = @as(f64, @floatFromInt(hashed & 0xFFFF)) / 65535.0;
    return (unit * 2.0) - 1.0;
}

pub fn simhashSignature(values: []const f32) u64 {
    var sig: u64 = 0;
    var bit_idx: u32 = 0;
    while (bit_idx < ann_signature_bits) : (bit_idx += 1) {
        var dot: f64 = 0.0;
        for (values, 0..) |value_raw, dim_idx| {
            const value: f64 = @floatCast(value_raw);
            dot += value * projectionCoeff(bit_idx, dim_idx);
        }
        if (dot >= 0.0) sig |= (@as(u64, 1) << @intCast(bit_idx));
    }
    return sig;
}

pub fn signatureBands(sig: u64) [ann_band_count]u16 {
    return .{
        @intCast(sig & 0xFFFF),
        @intCast((sig >> 16) & 0xFFFF),
        @intCast((sig >> 32) & 0xFFFF),
        @intCast((sig >> 48) & 0xFFFF),
    };
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
    strategy: ChunkStrategy = .plain,
    estimated_tokens: usize = 0,
    content_hash: u64 = 0,
    transcript_timestamp: ?[]const u8 = null,
    transcript_speaker: ?[]const u8 = null,
};

pub const MarkdownChunk = struct {
    index: usize,
    content: []const u8,
    heading: ?[]const u8,
};

pub const default_chunk_max_chars: usize = 1800;
pub const default_chunk_overlap_chars: usize = 180;
pub const max_chunk_max_chars: usize = 128 * 1024;
pub const max_chunk_overlap_chars: usize = 32 * 1024;

pub const ChunkStrategy = enum {
    auto,
    plain,
    markdown,
    transcript,
    code,

    pub fn name(self: ChunkStrategy) []const u8 {
        return switch (self) {
            .auto => "auto",
            .plain => "plain",
            .markdown => "markdown",
            .transcript => "transcript",
            .code => "code",
        };
    }

    pub fn parse(raw: []const u8) !ChunkStrategy {
        if (std.ascii.eqlIgnoreCase(raw, "auto")) return .auto;
        if (std.ascii.eqlIgnoreCase(raw, "plain") or std.ascii.eqlIgnoreCase(raw, "text")) return .plain;
        if (std.ascii.eqlIgnoreCase(raw, "markdown") or std.ascii.eqlIgnoreCase(raw, "md")) return .markdown;
        if (std.ascii.eqlIgnoreCase(raw, "transcript") or std.ascii.eqlIgnoreCase(raw, "meeting")) return .transcript;
        if (std.ascii.eqlIgnoreCase(raw, "code")) return .code;
        return error.InvalidChunkStrategy;
    }
};

pub const ChunkerConfig = struct {
    max_chars: usize = default_chunk_max_chars,
    overlap_chars: usize = default_chunk_overlap_chars,
    max_tokens: ?usize = null,
    strategy: ChunkStrategy = .auto,

    pub fn normalized(self: ChunkerConfig) !ChunkerConfig {
        var cfg = self;
        if (cfg.max_tokens) |tokens| {
            if (tokens == 0) return error.InvalidChunkConfig;
            cfg.max_chars = @min(max_chunk_max_chars, @max(@as(usize, 1), tokens *| 4));
        }
        cfg.max_chars = @max(@as(usize, 1), @min(cfg.max_chars, max_chunk_max_chars));
        cfg.overlap_chars = @min(cfg.overlap_chars, max_chunk_overlap_chars);
        if (cfg.overlap_chars >= cfg.max_chars) return error.InvalidChunkConfig;
        return cfg;
    }
};

pub fn chunkMarkdown(allocator: std.mem.Allocator, text: []const u8, max_tokens: usize) ![]MarkdownChunk {
    const max_chars = if (max_tokens == 0) @max(@as(usize, 1), text.len) else max_tokens *| 4;
    const raw_chunks = try chunkTextWithConfig(allocator, text, .{ .max_chars = max_chars, .overlap_chars = 0, .strategy = .markdown });
    defer allocator.free(raw_chunks);

    var chunks: std.ArrayListUnmanaged(MarkdownChunk) = .empty;
    errdefer {
        for (chunks.items) |chunk| {
            allocator.free(chunk.content);
            if (chunk.heading) |heading| allocator.free(heading);
        }
        chunks.deinit(allocator);
    }

    for (raw_chunks) |raw| {
        const content = try allocator.dupe(u8, raw.text);
        errdefer allocator.free(content);
        const heading = if (raw.heading) |value| try allocator.dupe(u8, value) else null;
        errdefer if (heading) |value| allocator.free(value);
        try chunks.append(allocator, .{
            .index = chunks.items.len,
            .content = content,
            .heading = heading,
        });
    }

    return chunks.toOwnedSlice(allocator);
}

pub fn freeChunks(allocator: std.mem.Allocator, chunks: []MarkdownChunk) void {
    for (chunks) |chunk| {
        allocator.free(chunk.content);
        if (chunk.heading) |heading| allocator.free(heading);
    }
    allocator.free(chunks);
}

pub fn chunkText(allocator: std.mem.Allocator, text: []const u8, max_chars: usize, overlap: usize) ![]Chunk {
    return chunkTextWithConfig(allocator, text, .{ .max_chars = max_chars, .overlap_chars = overlap, .strategy = .auto });
}

pub fn chunkTextWithConfig(allocator: std.mem.Allocator, text: []const u8, input_cfg: ChunkerConfig) ![]Chunk {
    const cfg = try input_cfg.normalized();
    const resolved_strategy = resolveStrategy(text, cfg.strategy);
    var chunks: std.ArrayListUnmanaged(Chunk) = .empty;
    errdefer chunks.deinit(allocator);

    const debommed_start: usize = if (text.len >= 3 and text[0] == 0xEF and text[1] == 0xBB and text[2] == 0xBF) 3 else 0;
    var start = skipWhitespaceForward(text, debommed_start, text.len);
    while (start < text.len) {
        const end = chunkEnd(text, start, cfg.max_chars, resolved_strategy);
        const trimmed_start = skipWhitespaceForward(text, start, end);
        const trimmed_end = trimWhitespaceBackward(text, trimmed_start, end);
        if (trimmed_start < trimmed_end) {
            const chunk_text = text[trimmed_start..trimmed_end];
            const transcript = transcriptMarkerInRange(text, trimmed_start, trimmed_end);
            try chunks.append(allocator, .{
                .text = chunk_text,
                .ordinal = chunks.items.len,
                .start = trimmed_start,
                .end = trimmed_end,
                .heading = headingAt(text, trimmed_start),
                .strategy = resolved_strategy,
                .estimated_tokens = estimateTokens(chunk_text),
                .content_hash = contentHash(chunk_text),
                .transcript_timestamp = transcript.timestamp,
                .transcript_speaker = transcript.speaker,
            });
        }
        if (end == text.len) break;
        start = if (cfg.overlap_chars > 0 and end > cfg.overlap_chars) blk: {
            const overlapped = previousUtf8Boundary(text, end - cfg.overlap_chars, start);
            break :blk if (overlapped > start) overlapped else end;
        } else end;
        start = skipWhitespaceForward(text, start, text.len);
    }
    return chunks.toOwnedSlice(allocator);
}

pub fn chunkHeadingPathJson(allocator: std.mem.Allocator, text: []const u8, chunk: Chunk) ![]u8 {
    return headingPathJsonAt(allocator, text, chunk.start, chunk.end);
}

pub fn contentHash(text: []const u8) u64 {
    return std.hash.Wyhash.hash(0, text);
}

pub fn contentHashHex(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "wy64_{x:0>16}", .{contentHash(text)});
}

pub fn estimateTokens(text: []const u8) usize {
    var count: usize = 0;
    var in_token = false;
    for (text) |ch| {
        const token_char = std.ascii.isAlphanumeric(ch) or ch >= 0x80 or ch == '_' or ch == '-';
        if (token_char) {
            if (!in_token) {
                count += 1;
                in_token = true;
            }
        } else {
            in_token = false;
            if (!std.ascii.isWhitespace(ch)) count += 1;
        }
    }
    return count;
}

fn resolveStrategy(text: []const u8, requested: ChunkStrategy) ChunkStrategy {
    if (requested != .auto) return requested;
    if (transcriptMarkerInRange(text, 0, @min(text.len, 4096)).timestamp != null) return .transcript;
    if (std.mem.indexOf(u8, text, "\n```") != null or std.mem.indexOf(u8, text, "\n~~~") != null) return .markdown;
    if (std.mem.indexOfScalar(u8, text, '#') != null and hasMarkdownHeading(text)) return .markdown;
    if (looksLikeCode(text)) return .code;
    return .plain;
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

fn headingPathJsonAt(allocator: std.mem.Allocator, text: []const u8, pos: usize, end: usize) ![]u8 {
    var path: [6]?[]const u8 = .{ null, null, null, null, null, null };
    scanHeadingPath(text, pos, &path);
    const transcript = transcriptMarkerInRange(text, pos, end);

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
    if (transcript.timestamp) |timestamp| {
        if (wrote) try out.append(allocator, ',');
        try appendPrefixedJsonString(allocator, &out, "timestamp:", timestamp);
        wrote = true;
    }
    if (transcript.speaker) |speaker| {
        if (wrote) try out.append(allocator, ',');
        try appendPrefixedJsonString(allocator, &out, "speaker:", speaker);
    }
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

fn appendPrefixedJsonString(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), prefix: []const u8, value: []const u8) !void {
    const tagged = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, value });
    defer allocator.free(tagged);
    try json.appendString(out, allocator, tagged);
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

fn chunkEnd(text: []const u8, start: usize, max_chars: usize, strategy: ChunkStrategy) usize {
    const hard_end = previousUtf8Boundary(text, @min(text.len, start + max_chars), start + 1);
    if (findNextMarkdownHeading(text, start + 1, hard_end)) |heading_start| return heading_start;
    if (hard_end >= text.len) return text.len;
    const min_split = @min(hard_end, start + @min(max_chars / 3, 600));
    if (strategy == .markdown or strategy == .code) {
        if (findFenceSafeSplit(text, start, min_split, hard_end)) |fence_split| return fence_split;
    }
    if (strategy == .markdown or strategy == .transcript) {
        if (findPreviousStructuredLineBreak(text, min_split, hard_end)) |structured_end| return structured_end;
    }
    if (findPreviousParagraphBreak(text, min_split, hard_end)) |paragraph_end| return paragraph_end;
    if (findPreviousLineBreak(text, min_split, hard_end)) |line_end| return line_end;
    if (findPreviousSentenceBoundary(text, min_split, hard_end)) |sentence_end| return sentence_end;
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

fn hasMarkdownHeading(text: []const u8) bool {
    var line_start: usize = 0;
    while (line_start < text.len) {
        if (markdownHeadingLevelAt(text, line_start) != null) return true;
        const line_end = std.mem.indexOfScalarPos(u8, text, line_start, '\n') orelse return false;
        line_start = line_end + 1;
    }
    return false;
}

fn looksLikeCode(text: []const u8) bool {
    var code_signals: usize = 0;
    var line_count: usize = 0;
    var line_start: usize = 0;
    while (line_start < text.len and line_count < 80) {
        const line_end = std.mem.indexOfScalarPos(u8, text, line_start, '\n') orelse text.len;
        const line = std.mem.trim(u8, text[line_start..line_end], " \t\r\n");
        if (line.len > 0) {
            if (std.mem.startsWith(u8, line, "fn ") or
                std.mem.startsWith(u8, line, "pub fn ") or
                std.mem.startsWith(u8, line, "const ") or
                std.mem.startsWith(u8, line, "var ") or
                std.mem.startsWith(u8, line, "import ") or
                std.mem.indexOfAny(u8, line, "{}();=") != null)
            {
                code_signals += 1;
            }
            line_count += 1;
        }
        if (line_end == text.len) break;
        line_start = line_end + 1;
    }
    return line_count >= 3 and code_signals * 2 >= line_count;
}

const TranscriptMarker = struct {
    timestamp: ?[]const u8 = null,
    speaker: ?[]const u8 = null,
};

fn transcriptMarkerInRange(text: []const u8, start_raw: usize, end_raw: usize) TranscriptMarker {
    const start = @min(start_raw, text.len);
    const end = @min(@max(start, end_raw), text.len);
    var line_start = start;
    while (line_start < end) {
        const line_end = std.mem.indexOfScalarPos(u8, text, line_start, '\n') orelse end;
        const marker = transcriptMarkerFromLine(text[line_start..@min(line_end, end)]);
        if (marker.timestamp != null or marker.speaker != null) return marker;
        if (line_end >= end or line_end == text.len) break;
        line_start = line_end + 1;
    }
    return transcriptMarkerFromLine(lineAtOrBefore(text, start));
}

fn lineAtOrBefore(text: []const u8, pos: usize) []const u8 {
    if (text.len == 0) return "";
    const start = lineStartAt(text, pos);
    var end = @min(pos, text.len);
    while (end < text.len and text[end] != '\n') : (end += 1) {}
    return std.mem.trim(u8, text[start..end], " \t\r\n");
}

fn lineStartAt(text: []const u8, pos: usize) usize {
    var start = @min(pos, text.len);
    if (start == text.len and start > 0) start -= 1;
    while (start > 0 and text[start - 1] != '\n') : (start -= 1) {}
    return start;
}

fn transcriptMarkerFromLine(line: []const u8) TranscriptMarker {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return .{};
    if (trimmed[0] == '[') {
        const close = std.mem.indexOfScalar(u8, trimmed, ']') orelse return .{};
        const timestamp = std.mem.trim(u8, trimmed[1..close], " \t");
        if (!looksLikeTimestamp(timestamp)) return .{};
        const after = std.mem.trim(u8, trimmed[close + 1 ..], " \t-");
        return .{ .timestamp = timestamp, .speaker = speakerBeforeColon(after) };
    }

    const first_space = std.mem.indexOfAny(u8, trimmed, " \t") orelse return .{};
    const timestamp = trimmed[0..first_space];
    if (!looksLikeTimestamp(timestamp)) return .{};
    const after = std.mem.trim(u8, trimmed[first_space..], " \t-");
    return .{ .timestamp = timestamp, .speaker = speakerBeforeColon(after) };
}

fn looksLikeTimestamp(value: []const u8) bool {
    if (value.len < 4 or value.len > 16) return false;
    var saw_digit = false;
    var saw_colon = false;
    for (value) |ch| {
        if (std.ascii.isDigit(ch)) {
            saw_digit = true;
            continue;
        }
        if (ch == ':') {
            saw_colon = true;
            continue;
        }
        if (ch == '.' or ch == ',') continue;
        return false;
    }
    return saw_digit and saw_colon;
}

fn speakerBeforeColon(value: []const u8) ?[]const u8 {
    const colon = std.mem.indexOfScalar(u8, value, ':') orelse return null;
    const speaker = std.mem.trim(u8, value[0..colon], " \t");
    if (speaker.len == 0 or speaker.len > 80) return null;
    return speaker;
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

fn findPreviousStructuredLineBreak(text: []const u8, min_pos: usize, end: usize) ?usize {
    var pos = end;
    while (pos > min_pos) : (pos -= 1) {
        if (text[pos - 1] != '\n') continue;
        const line = lineAtOrBefore(text, pos - 1);
        if (line.len == 0) return pos;
        if (transcriptMarkerFromLine(line).timestamp != null) return pos;
        if (isMarkdownTableLine(line) or isMarkdownListLine(line)) return pos;
    }
    return null;
}

fn findPreviousSentenceBoundary(text: []const u8, min_pos: usize, end: usize) ?usize {
    var pos = end;
    while (pos > min_pos + 1) : (pos -= 1) {
        const ch = text[pos - 1];
        if (ch != '.' and ch != '!' and ch != '?') continue;
        if (pos < text.len and !std.ascii.isWhitespace(text[pos])) continue;
        return pos;
    }
    return null;
}

fn findFenceSafeSplit(text: []const u8, start: usize, min_pos: usize, end: usize) ?usize {
    var in_fence = false;
    var fence_start: ?usize = null;
    var line_start = lineStartAt(text, start);
    while (line_start < end) {
        const line_end = std.mem.indexOfScalarPos(u8, text, line_start, '\n') orelse text.len;
        const line = std.mem.trim(u8, text[line_start..@min(line_end, text.len)], " \t");
        if (std.mem.startsWith(u8, line, "```") or std.mem.startsWith(u8, line, "~~~")) {
            if (!in_fence) {
                in_fence = true;
                fence_start = line_start;
            } else {
                in_fence = false;
                fence_start = null;
            }
        }
        if (line_end >= end or line_end == text.len) break;
        line_start = line_end + 1;
    }
    if (!in_fence) return null;
    const split = fence_start orelse return null;
    if (split > min_pos) return split;
    return null;
}

fn isMarkdownTableLine(line: []const u8) bool {
    return std.mem.indexOfScalar(u8, line, '|') != null and line.len >= 3;
}

fn isMarkdownListLine(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len < 2) return false;
    if ((trimmed[0] == '-' or trimmed[0] == '*' or trimmed[0] == '+') and std.ascii.isWhitespace(trimmed[1])) return true;
    var i: usize = 0;
    while (i < trimmed.len and std.ascii.isDigit(trimmed[i])) : (i += 1) {}
    return i > 0 and i + 1 < trimmed.len and trimmed[i] == '.' and std.ascii.isWhitespace(trimmed[i + 1]);
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
    try std.testing.expectApproxEqAbs(cosine(&a, &b), cosineSimilarity(&a, &b), 0.0001);
}

test "vector nullclaw-compatible bytes helpers round-trip embeddings" {
    const original = [_]f32{ 1.0, -2.5, 3.14, 0.0 };
    const bytes = try vecToBytes(std.testing.allocator, &original);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqual(@as(usize, original.len * 4), bytes.len);

    const restored = try bytesToVec(std.testing.allocator, bytes);
    defer std.testing.allocator.free(restored);
    try std.testing.expectEqual(@as(usize, original.len), restored.len);
    for (original, restored) |expected, actual| {
        try std.testing.expectApproxEqAbs(expected, actual, 0.0001);
    }
}

test "vector nullclaw-compatible hybrid merge deduplicates and normalizes keyword scores" {
    const vector_results = [_]IdScore{
        .{ .id = "a", .score = 0.9 },
        .{ .id = "b", .score = 0.4 },
    };
    const keyword_results = [_]IdScore{
        .{ .id = "a", .score = 10 },
        .{ .id = "c", .score = 5 },
    };

    const merged = try hybridMerge(std.testing.allocator, &vector_results, &keyword_results, 0.7, 0.3, 10);
    defer std.testing.allocator.free(merged);

    try std.testing.expectEqual(@as(usize, 3), merged.len);
    try std.testing.expectEqualStrings("a", merged[0].id);
    try std.testing.expect(merged[0].vector_score != null);
    try std.testing.expect(merged[0].keyword_score != null);
    try std.testing.expect(merged[0].final_score > merged[1].final_score);
}

test "vector nullclaw-compatible hybrid merge respects zero limit" {
    const vector_results = [_]IdScore{.{ .id = "a", .score = 0.9 }};
    const merged = try hybridMerge(std.testing.allocator, &vector_results, &.{}, 1, 0, 0);
    defer std.testing.allocator.free(merged);
    try std.testing.expectEqual(@as(usize, 0), merged.len);
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
    defer freeMatches(alloc, matches);
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
    defer freeMatches(alloc, matches);
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

test "vector chunker overlap never rewinds on structural split" {
    const text =
        \\aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        \\# Next
        \\bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    ;
    const chunks = try chunkTextWithConfig(std.testing.allocator, text, .{ .max_chars = 96, .overlap_chars = 80, .strategy = .markdown });
    defer std.testing.allocator.free(chunks);

    try std.testing.expect(chunks.len >= 2);
    try std.testing.expect(chunks.len < 10);
    var previous_start: usize = chunks[0].start;
    for (chunks[1..]) |chunk| {
        try std.testing.expect(chunk.start > previous_start);
        previous_start = chunk.start;
    }
}

test "vector chunker config emits provenance metadata" {
    const text = "Alpha beta gamma delta epsilon zeta eta theta iota kappa.";
    const chunks = try chunkTextWithConfig(std.testing.allocator, text, .{ .max_chars = 24, .overlap_chars = 6, .strategy = .plain });
    defer std.testing.allocator.free(chunks);

    try std.testing.expect(chunks.len > 1);
    try std.testing.expectEqual(@as(usize, 0), chunks[0].start);
    try std.testing.expect(chunks[0].end <= text.len);
    try std.testing.expect(chunks[0].estimated_tokens > 0);
    try std.testing.expectEqual(contentHash(chunks[0].text), chunks[0].content_hash);
    try std.testing.expectEqual(ChunkStrategy.plain, chunks[0].strategy);
    try std.testing.expect(chunks[1].start < chunks[0].end);
}

test "vector markdown chunker exposes nullclaw-compatible owned chunks" {
    const text = "# First\nAlpha\n## Second\nBeta";
    const chunks = try chunkMarkdown(std.testing.allocator, text, 512);
    defer freeChunks(std.testing.allocator, chunks);

    try std.testing.expectEqual(@as(usize, 2), chunks.len);
    try std.testing.expectEqual(@as(usize, 0), chunks[0].index);
    try std.testing.expectEqual(@as(usize, 1), chunks[1].index);
    try std.testing.expectEqualStrings("# First\nAlpha", chunks[0].content);
    try std.testing.expectEqualStrings("## Second\nBeta", chunks[1].content);
    try std.testing.expectEqualStrings("# First", chunks[0].heading.?);
    try std.testing.expectEqualStrings("## Second", chunks[1].heading.?);
}

test "vector markdown chunker max tokens zero keeps nullclaw no-limit behavior" {
    const chunks = try chunkMarkdown(std.testing.allocator, "Hello world", 0);
    defer freeChunks(std.testing.allocator, chunks);

    try std.testing.expectEqual(@as(usize, 1), chunks.len);
    try std.testing.expectEqualStrings("Hello world", chunks[0].content);
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

test "vector chunker serializes transcript timestamp and speaker metadata" {
    const text = "# Meeting\n[00:01:04] Alice: Decision: Meeting Memory is a pipeline\n[00:02:10] Bob: Action: create transcript ingestion";
    const chunks = try chunkText(std.testing.allocator, text, 72, 0);
    defer std.testing.allocator.free(chunks);
    try std.testing.expect(chunks.len >= 2);

    const first_chunk = for (chunks) |chunk| {
        if (std.mem.indexOf(u8, chunk.text, "Alice") != null) break chunk;
    } else return error.MissingTranscriptChunk;
    const second_chunk = for (chunks) |chunk| {
        if (std.mem.indexOf(u8, chunk.text, "Bob") != null) break chunk;
    } else return error.MissingTranscriptChunk;

    const first_transcript_path = try chunkHeadingPathJson(std.testing.allocator, text, first_chunk);
    defer std.testing.allocator.free(first_transcript_path);
    try std.testing.expectEqualStrings("[\"# Meeting\",\"timestamp:00:01:04\",\"speaker:Alice\"]", first_transcript_path);
    try std.testing.expectEqualStrings("00:01:04", first_chunk.transcript_timestamp.?);
    try std.testing.expectEqualStrings("Alice", first_chunk.transcript_speaker.?);

    const second_transcript_path = try chunkHeadingPathJson(std.testing.allocator, text, second_chunk);
    defer std.testing.allocator.free(second_transcript_path);
    try std.testing.expectEqualStrings("[\"# Meeting\",\"timestamp:00:02:10\",\"speaker:Bob\"]", second_transcript_path);
    try std.testing.expectEqualStrings("00:02:10", second_chunk.transcript_timestamp.?);
    try std.testing.expectEqualStrings("Bob", second_chunk.transcript_speaker.?);
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

test "vector chunker avoids splitting into fenced code blocks when possible" {
    const text =
        \\Intro paragraph with enough words to place the fence after the minimum split boundary.
        \\
        \\```zig
        \\pub fn example() void {
        \\    const value = 42;
        \\    _ = value;
        \\}
        \\```
        \\Tail.
    ;
    const chunks = try chunkTextWithConfig(std.testing.allocator, text, .{ .max_chars = 105, .overlap_chars = 0, .strategy = .markdown });
    defer std.testing.allocator.free(chunks);

    try std.testing.expect(chunks.len >= 2);
    try std.testing.expect(std.mem.indexOf(u8, chunks[0].text, "```zig") == null);
    try std.testing.expect(std.mem.startsWith(u8, chunks[1].text, "```zig"));
}
