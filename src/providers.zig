const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat.zig");
const json = @import("json_util.zig");
const vector = @import("vector.zig");

pub const max_provider_response_bytes: usize = 8 * 1024 * 1024;

pub const EmbeddingConfig = struct {
    base_url: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    model: ?[]const u8 = null,
    dimensions: usize = 64,
    timeout_secs: u32 = 30,

    pub fn enabled(self: EmbeddingConfig) bool {
        return self.base_url != null and self.model != null;
    }
};

pub const CompletionConfig = struct {
    base_url: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    model: ?[]const u8 = null,
    timeout_secs: u32 = 45,

    pub fn enabled(self: CompletionConfig) bool {
        return self.base_url != null and self.model != null;
    }
};

pub const EmbeddingResult = struct {
    provider: []const u8,
    model: []const u8,
    embedding: []f32,
};

pub const CompletionResult = struct {
    provider: []const u8,
    model: []const u8,
    content: []const u8,
};

pub const ProviderDescriptor = struct {
    name: []const u8,
    role: []const u8,
    status: []const u8,
    protocol: []const u8,
    env_prefix: []const u8,
};

pub const provider_descriptors = [_]ProviderDescriptor{
    .{ .name = "local-deterministic", .role = "offline deterministic embeddings and fallback retrieval", .status = "built_in", .protocol = "none", .env_prefix = "" },
    .{ .name = "openai-compatible-embeddings", .role = "query and chunk embeddings", .status = "built_in", .protocol = "POST /embeddings", .env_prefix = "NULLPANTRY_EMBEDDING_" },
    .{ .name = "openai-compatible-chat", .role = "ask synthesis and optional reranking", .status = "built_in", .protocol = "POST /chat/completions", .env_prefix = "NULLPANTRY_LLM_" },
    .{ .name = "ollama", .role = "local provider via OpenAI-compatible endpoint", .status = "compatible", .protocol = "configure Ollama OpenAI compatibility base URL", .env_prefix = "NULLPANTRY_EMBEDDING_|NULLPANTRY_LLM_" },
    .{ .name = "voyage", .role = "embedding provider via OpenAI-compatible response shape", .status = "compatible", .protocol = "POST /embeddings", .env_prefix = "NULLPANTRY_EMBEDDING_" },
    .{ .name = "gemini", .role = "external model provider adapter target", .status = "contract", .protocol = "provider adapter", .env_prefix = "NULLPANTRY_PROVIDER_" },
};

pub fn appendProvidersJson(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    try out.append(allocator, '[');
    for (provider_descriptors, 0..) |descriptor, i| {
        if (i > 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, "{\"name\":");
        try json.appendString(out, allocator, descriptor.name);
        try out.appendSlice(allocator, ",\"role\":");
        try json.appendString(out, allocator, descriptor.role);
        try out.appendSlice(allocator, ",\"status\":");
        try json.appendString(out, allocator, descriptor.status);
        try out.appendSlice(allocator, ",\"protocol\":");
        try json.appendString(out, allocator, descriptor.protocol);
        try out.appendSlice(allocator, ",\"env_prefix\":");
        try json.appendString(out, allocator, descriptor.env_prefix);
        try out.append(allocator, '}');
    }
    try out.append(allocator, ']');
}

pub fn embedText(allocator: std.mem.Allocator, cfg: EmbeddingConfig, text: []const u8, fallback_dimensions: usize) !EmbeddingResult {
    if (cfg.enabled()) {
        const embedding = try callOpenAICompatibleEmbedding(allocator, cfg, text);
        return .{
            .provider = "openai-compatible",
            .model = cfg.model orelse "unknown",
            .embedding = embedding,
        };
    }

    return .{
        .provider = "local-deterministic",
        .model = "local-deterministic",
        .embedding = try vector.deterministicEmbedding(allocator, text, fallback_dimensions),
    };
}

pub fn completeAnswer(allocator: std.mem.Allocator, cfg: CompletionConfig, prompt: []const u8) !CompletionResult {
    if (!cfg.enabled()) return error.ProviderUnavailable;
    return .{
        .provider = "openai-compatible",
        .model = cfg.model orelse "unknown",
        .content = try callOpenAICompatibleChat(allocator, cfg, prompt),
    };
}

fn callOpenAICompatibleEmbedding(allocator: std.mem.Allocator, cfg: EmbeddingConfig, text: []const u8) ![]f32 {
    const url = try providerUrl(allocator, cfg.base_url.?, "/embeddings");
    defer allocator.free(url);

    var payload: std.ArrayListUnmanaged(u8) = .empty;
    errdefer payload.deinit(allocator);
    try payload.appendSlice(allocator, "{\"model\":");
    try json.appendString(&payload, allocator, cfg.model.?);
    try payload.appendSlice(allocator, ",\"input\":");
    try json.appendString(&payload, allocator, text);
    if (cfg.dimensions > 0) {
        try payload.print(allocator, ",\"dimensions\":{d}", .{cfg.dimensions});
    }
    try payload.append(allocator, '}');
    const body = try payload.toOwnedSlice(allocator);
    defer allocator.free(body);

    const response = try postJson(allocator, url, cfg.api_key, cfg.timeout_secs, body);
    defer allocator.free(response);
    return parseEmbeddingResponse(allocator, response);
}

fn callOpenAICompatibleChat(allocator: std.mem.Allocator, cfg: CompletionConfig, prompt: []const u8) ![]const u8 {
    const url = try providerUrl(allocator, cfg.base_url.?, "/chat/completions");
    defer allocator.free(url);

    var payload: std.ArrayListUnmanaged(u8) = .empty;
    errdefer payload.deinit(allocator);
    try payload.appendSlice(allocator, "{\"model\":");
    try json.appendString(&payload, allocator, cfg.model.?);
    try payload.appendSlice(allocator, ",\"temperature\":0,\"messages\":[{\"role\":\"system\",\"content\":\"Answer only from the supplied context. Include no facts that are not supported by cited context. Say I don't know when evidence is insufficient.\"},{\"role\":\"user\",\"content\":");
    try json.appendString(&payload, allocator, prompt);
    try payload.appendSlice(allocator, "}]}");
    const body = try payload.toOwnedSlice(allocator);
    defer allocator.free(body);

    const response = try postJson(allocator, url, cfg.api_key, cfg.timeout_secs, body);
    defer allocator.free(response);
    return parseChatResponse(allocator, response);
}

fn providerUrl(allocator: std.mem.Allocator, base_url: []const u8, suffix: []const u8) ![]u8 {
    var end = base_url.len;
    while (end > 0 and base_url[end - 1] == '/') : (end -= 1) {}
    const trimmed = base_url[0..end];
    if (std.mem.endsWith(u8, trimmed, suffix)) return allocator.dupe(u8, trimmed);
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ trimmed, suffix });
}

fn postJson(allocator: std.mem.Allocator, url: []const u8, api_key: ?[]const u8, timeout_secs: u32, payload: []const u8) ![]u8 {
    var auth_header: ?[]u8 = null;
    defer if (auth_header) |h| allocator.free(h);

    var extra_headers_buf: [1]std.http.Header = undefined;
    var header_count: usize = 0;

    if (api_key) |key| {
        auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{key});
        extra_headers_buf[header_count] = .{ .name = "Authorization", .value = auth_header.? };
        header_count += 1;
    }

    var client: std.http.Client = .{ .allocator = allocator, .io = compat.io() };
    defer client.deinit();

    const uri = std.Uri.parse(url) catch return error.ProviderUnavailable;
    var req = client.request(.POST, uri, .{
        .redirect_behavior = .unhandled,
        .keep_alive = false,
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .accept_encoding = .omit,
            .connection = .{ .override = "close" },
        },
        .extra_headers = extra_headers_buf[0..header_count],
    }) catch return error.ProviderUnavailable;
    defer req.deinit();

    applyProviderSocketTimeout(req.connection, timeout_secs);

    req.transfer_encoding = .{ .content_length = payload.len };
    var body_writer = req.sendBodyUnflushed(&.{}) catch return error.ProviderUnavailable;
    body_writer.writer.writeAll(payload) catch return error.ProviderUnavailable;
    body_writer.end() catch return error.ProviderUnavailable;
    req.connection.?.flush() catch return error.ProviderUnavailable;

    var response = req.receiveHead(&.{}) catch return error.ProviderUnavailable;
    if (response.head.status != .ok) return error.ProviderHttpError;

    const reader = response.reader(&.{});
    return readLimitedProviderResponse(allocator, reader, max_provider_response_bytes) catch |err| switch (err) {
        error.StreamTooLong => error.ProviderResponseTooLarge,
        error.ReadFailed => error.ProviderUnavailable,
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn readLimitedProviderResponse(allocator: std.mem.Allocator, reader: *std.Io.Reader, limit: usize) ![]u8 {
    const read_limit = if (limit == std.math.maxInt(usize)) limit else limit + 1;
    const body = try reader.allocRemaining(allocator, .limited(read_limit));
    if (body.len > limit) {
        allocator.free(body);
        return error.StreamTooLong;
    }
    return body;
}

fn applyProviderSocketTimeout(connection: ?*std.http.Client.Connection, timeout_secs: u32) void {
    if (timeout_secs == 0) return;
    switch (builtin.target.os.tag) {
        .windows => {},
        else => {
            const timeout = std.posix.timeval{ .sec = @intCast(@max(timeout_secs, 1)), .usec = 0 };
            if (connection) |conn| {
                const handle = conn.stream_reader.stream.socket.handle;
                std.posix.setsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {};
                std.posix.setsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&timeout)) catch {};
            }
        },
    }
}

fn parseEmbeddingResponse(allocator: std.mem.Allocator, body: []const u8) ![]f32 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.ProviderInvalidResponse;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return error.ProviderInvalidResponse,
    };
    if (root.get("embedding")) |embedding_value| return embeddingFromValue(allocator, embedding_value);
    const data = switch (root.get("data") orelse return error.ProviderInvalidResponse) {
        .array => |a| a,
        else => return error.ProviderInvalidResponse,
    };
    if (data.items.len == 0) return error.ProviderInvalidResponse;
    const item = switch (data.items[0]) {
        .object => |o| o,
        else => return error.ProviderInvalidResponse,
    };
    return embeddingFromValue(allocator, item.get("embedding") orelse return error.ProviderInvalidResponse);
}

fn embeddingFromValue(allocator: std.mem.Allocator, value: std.json.Value) ![]f32 {
    const arr = switch (value) {
        .array => |a| a,
        else => return error.ProviderInvalidResponse,
    };
    var out = try allocator.alloc(f32, arr.items.len);
    errdefer allocator.free(out);
    for (arr.items, 0..) |item, i| {
        out[i] = switch (item) {
            .float => |f| @floatCast(f),
            .integer => |n| @floatFromInt(n),
            else => return error.ProviderInvalidResponse,
        };
        if (!std.math.isFinite(out[i])) return error.ProviderInvalidResponse;
    }
    vector.normalize(out);
    return out;
}

fn parseChatResponse(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.ProviderInvalidResponse;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return error.ProviderInvalidResponse,
    };
    if (json.stringField(root, "content")) |content| return allocator.dupe(u8, content);
    const choices = switch (root.get("choices") orelse return error.ProviderInvalidResponse) {
        .array => |a| a,
        else => return error.ProviderInvalidResponse,
    };
    if (choices.items.len == 0) return error.ProviderInvalidResponse;
    const choice = switch (choices.items[0]) {
        .object => |o| o,
        else => return error.ProviderInvalidResponse,
    };
    const message = switch (choice.get("message") orelse return error.ProviderInvalidResponse) {
        .object => |o| o,
        else => return error.ProviderInvalidResponse,
    };
    return allocator.dupe(u8, json.stringField(message, "content") orelse return error.ProviderInvalidResponse);
}

test "providers parse openai-compatible embedding response" {
    const body = "{\"data\":[{\"embedding\":[1,0,0]}]}";
    const embedding = try parseEmbeddingResponse(std.testing.allocator, body);
    defer std.testing.allocator.free(embedding);
    try std.testing.expectEqual(@as(usize, 3), embedding.len);
    try std.testing.expectApproxEqAbs(@as(f32, 1), embedding[0], 0.0001);
}

test "providers parse openai-compatible chat response" {
    const body = "{\"choices\":[{\"message\":{\"content\":\"answer\"}}]}";
    const content = try parseChatResponse(std.testing.allocator, body);
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("answer", content);
}

test "providers append endpoint suffixes safely" {
    const a = try providerUrl(std.testing.allocator, "https://example.test/v1", "/embeddings");
    defer std.testing.allocator.free(a);
    try std.testing.expectEqualStrings("https://example.test/v1/embeddings", a);
    const b = try providerUrl(std.testing.allocator, "https://example.test/v1/embeddings", "/embeddings");
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualStrings("https://example.test/v1/embeddings", b);
}

test "providers manifest includes concrete and compatible providers" {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try appendProvidersJson(std.testing.allocator, &out);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "openai-compatible-embeddings") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "ollama") != null);
}

test "provider response reader enforces byte cap" {
    var ok_reader: std.Io.Reader = .fixed("abcdef");
    const ok = try readLimitedProviderResponse(std.testing.allocator, &ok_reader, 6);
    defer std.testing.allocator.free(ok);
    try std.testing.expectEqualStrings("abcdef", ok);

    var too_large_reader: std.Io.Reader = .fixed("abcdefg");
    try std.testing.expectError(error.StreamTooLong, readLimitedProviderResponse(std.testing.allocator, &too_large_reader, 6));
}
