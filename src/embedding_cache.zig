const std = @import("std");
const providers = @import("providers.zig");
const store_mod = @import("store.zig");
const vector = @import("vector.zig");
const json = @import("json_util.zig");
const ids = @import("ids.zig");

pub const default_max_entries: usize = 10_000;

pub fn embedTextCached(
    allocator: std.mem.Allocator,
    store: *store_mod.Store,
    cfg: providers.EmbeddingConfig,
    text: []const u8,
    fallback_dimensions: usize,
    use_cache: bool,
    max_entries: usize,
) !providers.EmbeddingResult {
    if (!use_cache) return providers.embedText(allocator, cfg, text, fallback_dimensions);
    const cache_key = try key(allocator, cfg, text, fallback_dimensions);
    const now = ids.nowMs();
    if (try store.getEmbeddingCache(allocator, cache_key, now)) |entry| {
        return .{
            .provider = entry.provider,
            .model = entry.model,
            .embedding = try vector.embeddingFromJson(allocator, entry.embedding_json),
        };
    }
    const result = try providers.embedText(allocator, cfg, text, fallback_dimensions);
    const embedding_json = try vector.embeddingToJson(allocator, result.embedding);
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

pub fn key(allocator: std.mem.Allocator, cfg: providers.EmbeddingConfig, text: []const u8, fallback_dimensions: usize) ![]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    updateEndpointHash(&hasher, cfg.provider.name(), cfg.base_url, cfg.model, cfg.dimensions);
    updateHashUsize(&hasher, fallback_dimensions);
    for (cfg.fallbacks) |fallback| {
        hasher.update("\x1f");
        updateEndpointHash(&hasher, fallback.provider.name(), fallback.base_url, fallback.model, fallback.dimensions);
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
    if (raw <= 0) return 0;
    return @intCast(@min(raw, 1_000_000));
}

fn updateEndpointHash(hasher: *std.crypto.hash.sha2.Sha256, provider: []const u8, base_url: ?[]const u8, model: ?[]const u8, dimensions: usize) void {
    hasher.update(provider);
    hasher.update("\x1e");
    hasher.update(base_url orelse "");
    hasher.update("\x1e");
    hasher.update(model orelse "");
    hasher.update("\x1e");
    updateHashUsize(hasher, dimensions);
}

fn updateHashUsize(hasher: *std.crypto.hash.sha2.Sha256, value: usize) void {
    var buf: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return;
    hasher.update(text);
}
