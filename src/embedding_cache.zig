const std = @import("std");
const providers = @import("providers.zig");
const redaction = @import("redaction.zig");
const store_mod = @import("store.zig");
const vector = @import("vector.zig");
const json = @import("json_util.zig");
const ids = @import("ids.zig");
const bounded_int = @import("bounded_int.zig");

pub const default_max_entries: usize = 10_000;
const max_configured_entries: usize = 1_000_000;

pub fn embedTextCached(
    allocator: std.mem.Allocator,
    store: *store_mod.Store,
    cfg: providers.EmbeddingConfig,
    text: []const u8,
    fallback_dimensions: usize,
    use_cache: bool,
    max_entries: usize,
) !providers.EmbeddingResult {
    return embedTextCachedForPurpose(allocator, store, cfg, text, fallback_dimensions, use_cache, max_entries, .generic);
}

pub fn embedTextCachedForPurpose(
    allocator: std.mem.Allocator,
    store: *store_mod.Store,
    cfg: providers.EmbeddingConfig,
    text: []const u8,
    fallback_dimensions: usize,
    use_cache: bool,
    max_entries: usize,
    purpose: providers.EmbeddingPurpose,
) !providers.EmbeddingResult {
    const safe_text = try redaction.redactForEmbedding(allocator, text);
    defer allocator.free(safe_text);
    if (!use_cache) return providers.embedTextForPurpose(allocator, cfg, safe_text, fallback_dimensions, purpose);
    const cache_key = try keyForPurpose(allocator, cfg, safe_text, fallback_dimensions, purpose);
    defer allocator.free(cache_key);
    const now = ids.nowMs();
    if (try store.getEmbeddingCache(allocator, cache_key, now)) |entry| {
        var cached = entry;
        defer store_mod.freeEmbeddingCacheEntry(allocator, &cached);
        const provider = try allocator.dupe(u8, cached.provider);
        errdefer allocator.free(provider);
        const model = try allocator.dupe(u8, cached.model);
        errdefer allocator.free(model);
        const embedding = try vector.embeddingFromJson(allocator, cached.embedding_json);
        errdefer allocator.free(embedding);
        return .{
            .provider = provider,
            .model = model,
            .embedding = embedding,
            .owns_provider = true,
            .owns_model = true,
        };
    }
    var result = try providers.embedTextForPurpose(allocator, cfg, safe_text, fallback_dimensions, purpose);
    errdefer result.deinit(allocator);
    const embedding_json = try vector.embeddingToJson(allocator, result.embedding);
    defer allocator.free(embedding_json);
    try store.putEmbeddingCache(.{
        .cache_key = cache_key,
        .provider = result.provider,
        .model = result.model,
        .dimensions = result.embedding.len,
        .embedding_json = embedding_json,
        .now_ms = now,
        .max_entries = max_entries,
    });
    return result;
}

test "embedding cache redacts text before provider and cache key" {
    const allocator = std.testing.allocator;
    var store = try store_mod.Store.initSQLite(allocator, ":memory:");
    defer store.deinit();

    const raw = "reach alice@example.com with token=abc123 and sk-live-secret";
    const safe = try redaction.redactForEmbedding(allocator, raw);
    defer allocator.free(safe);

    var result = try embedTextCached(allocator, &store, .{ .provider = .local_deterministic }, raw, 8, true, 100);
    defer result.deinit(allocator);
    const expected = try vector.deterministicEmbedding(allocator, safe, 8);
    defer allocator.free(expected);
    try std.testing.expectEqual(expected.len, result.embedding.len);
    for (expected, result.embedding) |left, right| {
        try std.testing.expectApproxEqAbs(left, right, 0.0001);
    }

    const raw_key = try key(allocator, .{ .provider = .local_deterministic }, raw, 8);
    defer allocator.free(raw_key);
    const safe_key = try key(allocator, .{ .provider = .local_deterministic }, safe, 8);
    defer allocator.free(safe_key);
    try std.testing.expect((try store.getEmbeddingCache(allocator, raw_key, ids.nowMs())) == null);
    var cached = (try store.getEmbeddingCache(allocator, safe_key, ids.nowMs())).?;
    defer store_mod.freeEmbeddingCacheEntry(allocator, &cached);
}

test "embedding cache key follows resolved route hints" {
    const allocator = std.testing.allocator;
    const route_small = [_]providers.EmbeddingRouteConfig{.{
        .hint = "semantic",
        .endpoint = .{ .provider = .local_deterministic, .dimensions = 3, .prefer_endpoint_dimensions = true },
    }};
    const route_large = [_]providers.EmbeddingRouteConfig{.{
        .hint = "semantic",
        .endpoint = .{ .provider = .local_deterministic, .dimensions = 7, .prefer_endpoint_dimensions = true },
    }};

    const small_key = try key(allocator, .{ .model = "hint:semantic", .routes = &route_small }, "same text", 64);
    defer allocator.free(small_key);
    const large_key = try key(allocator, .{ .model = "hint:semantic", .routes = &route_large }, "same text", 64);
    defer allocator.free(large_key);
    try std.testing.expect(!std.mem.eql(u8, small_key, large_key));

    const direct_key = try key(allocator, .{ .model = "direct-model", .routes = &route_small }, "same text", 64);
    defer allocator.free(direct_key);
    const direct_key_unchanged = try key(allocator, .{ .model = "direct-model", .routes = &route_large }, "same text", 64);
    defer allocator.free(direct_key_unchanged);
    try std.testing.expectEqualStrings(direct_key, direct_key_unchanged);
}

test "embedding cache key separates purpose and provider dimension policy" {
    const allocator = std.testing.allocator;
    const cfg = providers.EmbeddingConfig{ .provider = .local_deterministic, .dimensions = 8 };
    const query_key = try keyForPurpose(allocator, cfg, "same text", 8, .query);
    defer allocator.free(query_key);
    const document_key = try keyForPurpose(allocator, cfg, "same text", 8, .document);
    defer allocator.free(document_key);
    try std.testing.expect(!std.mem.eql(u8, query_key, document_key));

    const silent_dims = try keyForPurpose(allocator, .{ .provider = .openai_compatible, .base_url = "https://example.test/v1", .model = "m", .dimensions = 768 }, "same text", 768, .query);
    defer allocator.free(silent_dims);
    const sent_dims = try keyForPurpose(allocator, .{ .provider = .openai_compatible, .base_url = "https://example.test/v1", .model = "m", .dimensions = 768, .send_dimensions = true }, "same text", 768, .query);
    defer allocator.free(sent_dims);
    try std.testing.expect(!std.mem.eql(u8, silent_dims, sent_dims));
}

test "embedding cache max entries clamp request values" {
    var defaults = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{}", .{});
    defer defaults.deinit();
    try std.testing.expectEqual(default_max_entries, maxEntriesFromObject(defaults.value.object));

    var zero = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"embedding_cache_max_entries\":0}", .{});
    defer zero.deinit();
    try std.testing.expectEqual(@as(usize, 0), maxEntriesFromObject(zero.value.object));

    var negative = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"embedding_cache_max_entries\":-1}", .{});
    defer negative.deinit();
    try std.testing.expectEqual(@as(usize, 0), maxEntriesFromObject(negative.value.object));

    var alias = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"embedding_max_entries\":42}", .{});
    defer alias.deinit();
    try std.testing.expectEqual(@as(usize, 42), maxEntriesFromObject(alias.value.object));

    var oversized = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"embedding_cache_max_entries\":9223372036854775807}", .{});
    defer oversized.deinit();
    try std.testing.expectEqual(max_configured_entries, maxEntriesFromObject(oversized.value.object));
}

pub fn key(allocator: std.mem.Allocator, cfg: providers.EmbeddingConfig, text: []const u8, fallback_dimensions: usize) ![]u8 {
    return keyForPurpose(allocator, cfg, text, fallback_dimensions, .generic);
}

pub fn keyForPurpose(allocator: std.mem.Allocator, cfg: providers.EmbeddingConfig, text: []const u8, fallback_dimensions: usize, purpose: providers.EmbeddingPurpose) ![]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    const primary = providers.resolveEmbeddingRoute(cfg, cfg.primaryEndpoint());
    updateEndpointHash(&hasher, primary.provider.name(), primary.base_url, primary.model, primary.dimensions, primary.send_dimensions);
    updateHashUsize(&hasher, fallback_dimensions);
    hasher.update("\x1d");
    hasher.update(purpose.name());
    for (cfg.fallbacks) |fallback| {
        const routed = providers.resolveEmbeddingRoute(cfg, fallback);
        hasher.update("\x1f");
        updateEndpointHash(&hasher, routed.provider.name(), routed.base_url, routed.model, routed.dimensions, routed.send_dimensions);
    }
    hasher.update("\x00");
    hasher.update(text);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hex_chars = "0123456789abcdef";
    var out = try allocator.alloc(u8, 70);
    @memcpy(out[0..6], "embed:");
    for (digest, 0..) |byte, i| {
        out[6 + i * 2] = hex_chars[byte >> 4];
        out[6 + i * 2 + 1] = hex_chars[byte & 0x0f];
    }
    return out;
}

pub fn maxEntriesFromObject(obj: std.json.ObjectMap) usize {
    const raw = json.intField(obj, "embedding_cache_max_entries") orelse json.intField(obj, "embedding_max_entries") orelse return default_max_entries;
    return bounded_int.positiveI64ToUsizeBounded(raw, max_configured_entries);
}

fn updateEndpointHash(hasher: *std.crypto.hash.sha2.Sha256, provider: []const u8, base_url: ?[]const u8, model: ?[]const u8, dimensions: usize, send_dimensions: bool) void {
    hasher.update(provider);
    hasher.update("\x1e");
    hasher.update(base_url orelse "");
    hasher.update("\x1e");
    hasher.update(model orelse "");
    hasher.update("\x1e");
    updateHashUsize(hasher, dimensions);
    hasher.update(if (send_dimensions) "\x01" else "\x00");
}

fn updateHashUsize(hasher: *std.crypto.hash.sha2.Sha256, value: usize) void {
    var buf: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return;
    hasher.update(text);
}
