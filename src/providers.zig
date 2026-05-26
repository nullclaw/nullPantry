const std = @import("std");
const compat = @import("compat.zig");
const json = @import("json_util.zig");
const vector = @import("vector.zig");

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

pub fn embedText(allocator: std.mem.Allocator, cfg: EmbeddingConfig, text: []const u8, fallback_dimensions: usize) !EmbeddingResult {
    if (cfg.enabled()) {
        if (callOpenAICompatibleEmbedding(allocator, cfg, text)) |embedding| {
            return .{
                .provider = "openai-compatible",
                .model = cfg.model orelse "unknown",
                .embedding = embedding,
            };
        } else |err| switch (err) {
            error.ProviderUnavailable, error.ProviderInvalidResponse, error.ProviderHttpError => {},
            else => |e| return e,
        }
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

    const response = try curlPostJson(allocator, url, cfg.api_key, cfg.timeout_secs, body);
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

    const response = try curlPostJson(allocator, url, cfg.api_key, cfg.timeout_secs, body);
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

fn curlPostJson(allocator: std.mem.Allocator, url: []const u8, api_key: ?[]const u8, timeout_secs: u32, payload: []const u8) ![]u8 {
    var auth_header: ?[]u8 = null;
    defer if (auth_header) |h| allocator.free(h);

    var timeout_buf: [16]u8 = undefined;
    const timeout_text = std.fmt.bufPrint(&timeout_buf, "{d}", .{@max(timeout_secs, 1)}) catch unreachable;

    var argv_buf: [22][]const u8 = undefined;
    var argc: usize = 0;
    argv_buf[argc] = "curl";
    argc += 1;
    argv_buf[argc] = "--silent";
    argc += 1;
    argv_buf[argc] = "--show-error";
    argc += 1;
    argv_buf[argc] = "--max-time";
    argc += 1;
    argv_buf[argc] = timeout_text;
    argc += 1;
    argv_buf[argc] = "--request";
    argc += 1;
    argv_buf[argc] = "POST";
    argc += 1;
    argv_buf[argc] = "--header";
    argc += 1;
    argv_buf[argc] = "Content-Type: application/json";
    argc += 1;
    if (api_key) |key| {
        auth_header = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{key});
        argv_buf[argc] = "--header";
        argc += 1;
        argv_buf[argc] = auth_header.?;
        argc += 1;
    }
    argv_buf[argc] = "--data";
    argc += 1;
    argv_buf[argc] = payload;
    argc += 1;
    argv_buf[argc] = "--write-out";
    argc += 1;
    argv_buf[argc] = "\n%{http_code}";
    argc += 1;
    argv_buf[argc] = url;
    argc += 1;

    const result = std.process.run(allocator, compat.io(), .{
        .argv = argv_buf[0..argc],
        .stdout_limit = .limited(32 * 1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    }) catch return error.ProviderUnavailable;
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.ProviderUnavailable,
        else => return error.ProviderUnavailable,
    }

    const sep = std.mem.lastIndexOfScalar(u8, result.stdout, '\n') orelse return error.ProviderInvalidResponse;
    const status_text = std.mem.trim(u8, result.stdout[sep + 1 ..], " \t\r\n");
    const status = std.fmt.parseInt(u16, status_text, 10) catch return error.ProviderInvalidResponse;
    if (status < 200 or status >= 300) return error.ProviderHttpError;
    return allocator.dupe(u8, result.stdout[0..sep]);
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
