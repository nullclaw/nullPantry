const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat.zig");
const ids = @import("ids.zig");
const json = @import("json_util.zig");
const net_security = @import("net_security.zig");
const vector = @import("vector.zig");

pub const max_provider_response_bytes: usize = 8 * 1024 * 1024;

pub const EmbeddingProviderKind = enum {
    local_deterministic,
    openai_compatible,
    gemini,
    ollama,
    voyage,

    pub fn parse(raw: []const u8) EmbeddingProviderKind {
        if (std.ascii.eqlIgnoreCase(raw, "local") or
            std.ascii.eqlIgnoreCase(raw, "deterministic") or
            std.ascii.eqlIgnoreCase(raw, "local-deterministic"))
        {
            return .local_deterministic;
        }
        if (std.ascii.eqlIgnoreCase(raw, "gemini") or
            std.ascii.eqlIgnoreCase(raw, "google") or
            std.ascii.eqlIgnoreCase(raw, "google-gemini"))
        {
            return .gemini;
        }
        if (std.ascii.eqlIgnoreCase(raw, "ollama") or
            std.ascii.eqlIgnoreCase(raw, "ollama-api") or
            std.ascii.eqlIgnoreCase(raw, "ollama-native"))
        {
            return .ollama;
        }
        if (std.ascii.eqlIgnoreCase(raw, "voyage") or
            std.ascii.eqlIgnoreCase(raw, "voyageai") or
            std.ascii.eqlIgnoreCase(raw, "voyage-ai"))
        {
            return .voyage;
        }
        return .openai_compatible;
    }

    pub fn name(self: EmbeddingProviderKind) []const u8 {
        return switch (self) {
            .local_deterministic => "local-deterministic",
            .openai_compatible => "openai-compatible",
            .gemini => "gemini",
            .ollama => "ollama",
            .voyage => "voyage",
        };
    }
};

pub const EmbeddingEndpointConfig = struct {
    provider: EmbeddingProviderKind = .openai_compatible,
    base_url: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    model: ?[]const u8 = null,
    dimensions: usize = 64,
    timeout_secs: u32 = 30,
    allow_insecure_http: bool = false,

    pub fn enabled(self: EmbeddingEndpointConfig) bool {
        return switch (self.provider) {
            .local_deterministic => false,
            .openai_compatible => self.base_url != null and self.model != null,
            .ollama => true,
            .gemini, .voyage => self.api_key != null,
        };
    }
};

pub const EmbeddingConfig = struct {
    provider: EmbeddingProviderKind = .openai_compatible,
    base_url: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    model: ?[]const u8 = null,
    dimensions: usize = 64,
    timeout_secs: u32 = 30,
    allow_insecure_http: bool = false,
    fallbacks: []const EmbeddingEndpointConfig = &.{},
    runtime: ?*ProviderRuntime = null,

    pub fn enabled(self: EmbeddingConfig) bool {
        return self.primaryEndpoint().enabled();
    }

    fn primaryEndpoint(self: EmbeddingConfig) EmbeddingEndpointConfig {
        return .{
            .provider = self.provider,
            .base_url = self.base_url,
            .api_key = self.api_key,
            .model = self.model,
            .dimensions = self.dimensions,
            .timeout_secs = self.timeout_secs,
            .allow_insecure_http = self.allow_insecure_http,
        };
    }
};

pub const CompletionConfig = struct {
    base_url: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    model: ?[]const u8 = null,
    timeout_secs: u32 = 45,
    allow_insecure_http: bool = false,
    runtime: ?*ProviderRuntime = null,

    pub fn enabled(self: CompletionConfig) bool {
        return self.base_url != null and self.model != null;
    }
};

pub const CircuitState = enum {
    closed,
    open,
    half_open,

    pub fn name(self: CircuitState) []const u8 {
        return switch (self) {
            .closed => "closed",
            .open => "open",
            .half_open => "half_open",
        };
    }
};

pub const CircuitOptions = struct {
    failure_threshold: u32 = 3,
    cooldown_ms: i64 = 30_000,
};

pub const ProviderCircuit = struct {
    provider: []const u8,
    state: CircuitState = .closed,
    failure_count: u32 = 0,
    failure_threshold: u32 = 3,
    cooldown_ms: i64 = 30_000,
    last_failure_ms: i64 = 0,
    half_open_probe_sent: bool = false,
    attempts: u64 = 0,
    successes: u64 = 0,
    failures: u64 = 0,
    skipped: u64 = 0,

    pub fn init(provider: []const u8, options: CircuitOptions) ProviderCircuit {
        return .{
            .provider = provider,
            .failure_threshold = options.failure_threshold,
            .cooldown_ms = options.cooldown_ms,
        };
    }

    pub fn allow(self: *ProviderCircuit, now_ms: i64) bool {
        switch (self.state) {
            .closed => {
                self.attempts += 1;
                return true;
            },
            .open => {
                if (self.cooldown_ms <= 0 or now_ms - self.last_failure_ms >= self.cooldown_ms) {
                    self.state = .half_open;
                    self.half_open_probe_sent = true;
                    self.attempts += 1;
                    return true;
                }
                self.skipped += 1;
                return false;
            },
            .half_open => {
                if (!self.half_open_probe_sent) {
                    self.half_open_probe_sent = true;
                    self.attempts += 1;
                    return true;
                }
                self.skipped += 1;
                return false;
            },
        }
    }

    pub fn recordSuccess(self: *ProviderCircuit) void {
        self.state = .closed;
        self.failure_count = 0;
        self.half_open_probe_sent = false;
        self.successes += 1;
    }

    pub fn recordFailure(self: *ProviderCircuit, now_ms: i64) void {
        self.failure_count +|= 1;
        self.failures += 1;
        self.last_failure_ms = now_ms;
        if (self.state == .half_open or self.failure_count >= self.failure_threshold) {
            self.state = .open;
            self.half_open_probe_sent = false;
        }
    }

    pub fn appendJson(self: ProviderCircuit, allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
        try out.appendSlice(allocator, "{\"provider\":");
        try json.appendString(out, allocator, self.provider);
        try out.appendSlice(allocator, ",\"state\":");
        try json.appendString(out, allocator, self.state.name());
        try out.print(
            allocator,
            ",\"failure_count\":{d},\"failure_threshold\":{d},\"cooldown_ms\":{d},\"last_failure_ms\":{d},\"attempts\":{d},\"successes\":{d},\"failures\":{d},\"skipped\":{d}}}",
            .{ self.failure_count, self.failure_threshold, self.cooldown_ms, self.last_failure_ms, self.attempts, self.successes, self.failures, self.skipped },
        );
    }
};

pub const ProviderTarget = union(enum) {
    embedding_primary,
    embedding_fallback: usize,
    completion,
};

pub const ProviderRuntime = struct {
    mutex: std.Io.Mutex = .init,
    embedding_primary: ProviderCircuit,
    embedding_fallbacks: []ProviderCircuit,
    completion: ProviderCircuit,

    pub fn init(allocator: std.mem.Allocator, embedding: EmbeddingConfig, completion: CompletionConfig, options: CircuitOptions) !ProviderRuntime {
        var fallbacks = try allocator.alloc(ProviderCircuit, embedding.fallbacks.len);
        errdefer allocator.free(fallbacks);
        for (embedding.fallbacks, 0..) |fallback, i| {
            fallbacks[i] = ProviderCircuit.init(fallback.provider.name(), options);
        }
        return .{
            .embedding_primary = ProviderCircuit.init(embedding.provider.name(), options),
            .embedding_fallbacks = fallbacks,
            .completion = ProviderCircuit.init(if (completion.model != null) "openai-compatible-chat" else "none", options),
        };
    }

    pub fn deinit(self: *ProviderRuntime, allocator: std.mem.Allocator) void {
        allocator.free(self.embedding_fallbacks);
        self.embedding_fallbacks = &.{};
    }

    pub fn allow(self: *ProviderRuntime, target: ProviderTarget) bool {
        self.mutex.lockUncancelable(compat.io());
        defer self.mutex.unlock(compat.io());
        const circuit = self.circuitFor(target) orelse return true;
        return circuit.allow(ids.nowMs());
    }

    pub fn recordSuccess(self: *ProviderRuntime, target: ProviderTarget) void {
        self.mutex.lockUncancelable(compat.io());
        defer self.mutex.unlock(compat.io());
        if (self.circuitFor(target)) |circuit| circuit.recordSuccess();
    }

    pub fn recordFailure(self: *ProviderRuntime, target: ProviderTarget) void {
        self.mutex.lockUncancelable(compat.io());
        defer self.mutex.unlock(compat.io());
        if (self.circuitFor(target)) |circuit| circuit.recordFailure(ids.nowMs());
    }

    pub fn appendStatusJson(self: *ProviderRuntime, allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
        self.mutex.lockUncancelable(compat.io());
        defer self.mutex.unlock(compat.io());
        try out.appendSlice(allocator, "{\"embedding\":{\"primary\":");
        try self.embedding_primary.appendJson(allocator, out);
        try out.appendSlice(allocator, ",\"fallbacks\":[");
        for (self.embedding_fallbacks, 0..) |fallback, i| {
            if (i > 0) try out.append(allocator, ',');
            try fallback.appendJson(allocator, out);
        }
        try out.appendSlice(allocator, "]},\"completion\":");
        try self.completion.appendJson(allocator, out);
        try out.append(allocator, '}');
    }

    fn circuitFor(self: *ProviderRuntime, target: ProviderTarget) ?*ProviderCircuit {
        return switch (target) {
            .embedding_primary => &self.embedding_primary,
            .embedding_fallback => |i| if (i < self.embedding_fallbacks.len) &self.embedding_fallbacks[i] else null,
            .completion => &self.completion,
        };
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
    .{ .name = "gemini", .role = "query and chunk embeddings", .status = "built_in", .protocol = "POST /v1beta/models/{model}:embedContent", .env_prefix = "NULLPANTRY_EMBEDDING_" },
    .{ .name = "voyage", .role = "query and chunk embeddings", .status = "built_in", .protocol = "POST /v1/embeddings", .env_prefix = "NULLPANTRY_EMBEDDING_" },
    .{ .name = "ollama", .role = "local query and chunk embeddings", .status = "built_in", .protocol = "POST /api/embed", .env_prefix = "NULLPANTRY_EMBEDDING_" },
    .{ .name = "embedding-fallback-chain", .role = "server-side embedding failover between configured providers", .status = "built_in", .protocol = "NULLPANTRY_EMBEDDING_FALLBACKS string or JSON", .env_prefix = "NULLPANTRY_EMBEDDING_" },
    .{ .name = "provider-circuit-breaker", .role = "shared runtime provider health, cooldown, and half-open probing", .status = "built_in", .protocol = "diagnostics.providers", .env_prefix = "NULLPANTRY_PROVIDER_" },
    .{ .name = "openai-compatible-chat", .role = "ask synthesis, structured extraction, and optional reranking", .status = "built_in", .protocol = "POST /chat/completions", .env_prefix = "NULLPANTRY_LLM_" },
    .{ .name = "ollama-openai-compatible", .role = "local chat or embedding provider through Ollama's OpenAI-compatible endpoint", .status = "compatible", .protocol = "configure Ollama OpenAI compatibility base URL", .env_prefix = "NULLPANTRY_EMBEDDING_|NULLPANTRY_LLM_" },
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
    const primary = cfg.primaryEndpoint();
    var first_err: ?anyerror = null;
    var skipped_by_circuit = false;
    if (primary.enabled() or primary.provider == .local_deterministic) {
        if (providerAllowed(cfg.runtime, .embedding_primary)) {
            if (embedWithEndpoint(allocator, primary, text, fallback_dimensions)) |result| {
                providerSucceeded(cfg.runtime, .embedding_primary);
                return result;
            } else |primary_err| {
                providerFailed(cfg.runtime, .embedding_primary);
                first_err = primary_err;
            }
        } else {
            skipped_by_circuit = true;
        }
    }
    for (cfg.fallbacks, 0..) |fallback, i| {
        if (!fallback.enabled() and fallback.provider != .local_deterministic) continue;
        const target = ProviderTarget{ .embedding_fallback = i };
        if (!providerAllowed(cfg.runtime, target)) {
            skipped_by_circuit = true;
            continue;
        }
        if (embedWithEndpoint(allocator, fallback, text, fallback_dimensions)) |result| {
            providerSucceeded(cfg.runtime, target);
            return result;
        } else |fallback_err| {
            providerFailed(cfg.runtime, target);
            if (first_err == null) first_err = fallback_err;
            continue;
        }
    }
    if (primary.enabled() or cfg.fallbacks.len > 0) {
        if (first_err) |err| return err;
        if (skipped_by_circuit) return error.ProviderCircuitOpen;
    }

    return .{
        .provider = "local-deterministic",
        .model = "local-deterministic",
        .embedding = try vector.deterministicEmbedding(allocator, text, fallback_dimensions),
    };
}

fn embedWithEndpoint(allocator: std.mem.Allocator, cfg: EmbeddingEndpointConfig, text: []const u8, fallback_dimensions: usize) !EmbeddingResult {
    if (cfg.provider == .local_deterministic) {
        return .{
            .provider = "local-deterministic",
            .model = "local-deterministic",
            .embedding = try vector.deterministicEmbedding(allocator, text, fallback_dimensions),
        };
    }
    const embedding = switch (cfg.provider) {
        .local_deterministic => unreachable,
        .openai_compatible => try callOpenAICompatibleEmbedding(allocator, cfg, text),
        .gemini => try callGeminiEmbedding(allocator, cfg, text),
        .ollama => try callOllamaEmbedding(allocator, cfg, text),
        .voyage => try callVoyageEmbedding(allocator, cfg, text),
    };
    return .{
        .provider = cfg.provider.name(),
        .model = embeddingModel(cfg),
        .embedding = embedding,
    };
}

fn embeddingModel(cfg: EmbeddingEndpointConfig) []const u8 {
    return cfg.model orelse switch (cfg.provider) {
        .local_deterministic => "local-deterministic",
        .openai_compatible => "unknown",
        .gemini => "text-embedding-004",
        .ollama => "nomic-embed-text",
        .voyage => "voyage-3-lite",
    };
}

pub fn parseEmbeddingFallbacks(allocator: std.mem.Allocator, raw: []const u8, base: EmbeddingConfig) ![]EmbeddingEndpointConfig {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return allocator.alloc(EmbeddingEndpointConfig, 0);
    if (trimmed[0] == '[') return parseEmbeddingFallbacksJson(allocator, trimmed, base);
    return parseEmbeddingFallbacksList(allocator, trimmed, base);
}

fn parseEmbeddingFallbacksList(allocator: std.mem.Allocator, raw: []const u8, base: EmbeddingConfig) ![]EmbeddingEndpointConfig {
    var out: std.ArrayListUnmanaged(EmbeddingEndpointConfig) = .empty;
    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |item| {
        const provider_name = std.mem.trim(u8, item, " \t\r\n");
        if (provider_name.len == 0) continue;
        try out.append(allocator, fallbackFromProvider(base, EmbeddingProviderKind.parse(provider_name)));
    }
    return out.toOwnedSlice(allocator);
}

fn parseEmbeddingFallbacksJson(allocator: std.mem.Allocator, raw: []const u8, base: EmbeddingConfig) ![]EmbeddingEndpointConfig {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch return error.InvalidEmbeddingFallbacks;
    defer parsed.deinit();
    const arr = switch (parsed.value) {
        .array => |a| a,
        else => return error.InvalidEmbeddingFallbacks,
    };
    var out: std.ArrayListUnmanaged(EmbeddingEndpointConfig) = .empty;
    errdefer out.deinit(allocator);
    for (arr.items) |item| {
        switch (item) {
            .string => |name| try out.append(allocator, fallbackFromProvider(base, EmbeddingProviderKind.parse(name))),
            .object => |obj| {
                const provider = EmbeddingProviderKind.parse(json.stringField(obj, "provider") orelse json.stringField(obj, "name") orelse "openai-compatible");
                try out.append(allocator, .{
                    .provider = provider,
                    .base_url = try dupOptional(allocator, json.nullableStringField(obj, "base_url")),
                    .api_key = try dupOptional(allocator, json.nullableStringField(obj, "api_key")),
                    .model = try dupOptional(allocator, json.nullableStringField(obj, "model")),
                    .dimensions = @intCast(@max(@as(i64, 1), json.intField(obj, "dimensions") orelse @as(i64, @intCast(base.dimensions)))),
                    .timeout_secs = @intCast(@max(@as(i64, 1), json.intField(obj, "timeout_secs") orelse @as(i64, @intCast(base.timeout_secs)))),
                    .allow_insecure_http = json.boolField(obj, "allow_insecure_http") orelse json.boolField(obj, "insecure_http") orelse base.allow_insecure_http,
                });
            },
            else => return error.InvalidEmbeddingFallbacks,
        }
    }
    return out.toOwnedSlice(allocator);
}

fn fallbackFromProvider(base: EmbeddingConfig, provider: EmbeddingProviderKind) EmbeddingEndpointConfig {
    return .{
        .provider = provider,
        .base_url = base.base_url,
        .api_key = base.api_key,
        .model = base.model,
        .dimensions = base.dimensions,
        .timeout_secs = base.timeout_secs,
        .allow_insecure_http = base.allow_insecure_http,
    };
}

fn dupOptional(allocator: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    if (value) |text| return try allocator.dupe(u8, text);
    return null;
}

pub fn completeAnswer(allocator: std.mem.Allocator, cfg: CompletionConfig, prompt: []const u8) !CompletionResult {
    return completeWithSystem(allocator, cfg, "Answer only from the supplied context. Include no facts that are not supported by cited context. Say I don't know when evidence is insufficient.", prompt);
}

pub fn completeWithSystem(allocator: std.mem.Allocator, cfg: CompletionConfig, system_prompt: []const u8, prompt: []const u8) !CompletionResult {
    if (!cfg.enabled()) return error.ProviderUnavailable;
    if (!providerAllowed(cfg.runtime, .completion)) return error.ProviderCircuitOpen;
    const content = callOpenAICompatibleChat(allocator, cfg, system_prompt, prompt) catch |err| {
        providerFailed(cfg.runtime, .completion);
        return err;
    };
    providerSucceeded(cfg.runtime, .completion);
    return .{
        .provider = "openai-compatible",
        .model = cfg.model orelse "unknown",
        .content = content,
    };
}

fn providerAllowed(runtime: ?*ProviderRuntime, target: ProviderTarget) bool {
    if (runtime) |rt| return rt.allow(target);
    return true;
}

fn providerSucceeded(runtime: ?*ProviderRuntime, target: ProviderTarget) void {
    if (runtime) |rt| rt.recordSuccess(target);
}

fn providerFailed(runtime: ?*ProviderRuntime, target: ProviderTarget) void {
    if (runtime) |rt| rt.recordFailure(target);
}

fn callOpenAICompatibleEmbedding(allocator: std.mem.Allocator, cfg: EmbeddingEndpointConfig, text: []const u8) ![]f32 {
    const url = try providerUrl(allocator, cfg.base_url.?, "/embeddings", cfg.allow_insecure_http);
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

fn callGeminiEmbedding(allocator: std.mem.Allocator, cfg: EmbeddingEndpointConfig, text: []const u8) ![]f32 {
    if (text.len == 0) return allocator.alloc(f32, 0);
    const base_url = cfg.base_url orelse "https://generativelanguage.googleapis.com";
    const model = cfg.model orelse "text-embedding-004";
    const key = cfg.api_key orelse return error.ProviderUnavailable;
    const suffix = try std.fmt.allocPrint(allocator, "/v1beta/models/{s}:embedContent?key={s}", .{ model, key });
    defer allocator.free(suffix);
    const url = try providerUrl(allocator, base_url, suffix, cfg.allow_insecure_http);
    defer allocator.free(url);

    const body = try geminiEmbeddingPayload(allocator, model, text);
    defer allocator.free(body);
    const response = try postJson(allocator, url, null, cfg.timeout_secs, body);
    defer allocator.free(response);
    return parseGeminiEmbeddingResponse(allocator, response);
}

fn callVoyageEmbedding(allocator: std.mem.Allocator, cfg: EmbeddingEndpointConfig, text: []const u8) ![]f32 {
    if (text.len == 0) return allocator.alloc(f32, 0);
    const base_url = cfg.base_url orelse "https://api.voyageai.com";
    const model = cfg.model orelse "voyage-3-lite";
    const url = try providerUrl(allocator, base_url, "/v1/embeddings", cfg.allow_insecure_http);
    defer allocator.free(url);

    const body = try voyageEmbeddingPayload(allocator, model, text, "query");
    defer allocator.free(body);
    const response = try postJson(allocator, url, cfg.api_key, cfg.timeout_secs, body);
    defer allocator.free(response);
    return parseEmbeddingResponse(allocator, response);
}

fn callOllamaEmbedding(allocator: std.mem.Allocator, cfg: EmbeddingEndpointConfig, text: []const u8) ![]f32 {
    if (text.len == 0) return allocator.alloc(f32, 0);
    const base_url = cfg.base_url orelse "http://localhost:11434";
    const model = cfg.model orelse "nomic-embed-text";
    const url = try providerUrl(allocator, base_url, "/api/embed", cfg.allow_insecure_http);
    defer allocator.free(url);

    const body = try ollamaEmbeddingPayload(allocator, model, text);
    defer allocator.free(body);
    const response = try postJson(allocator, url, cfg.api_key, cfg.timeout_secs, body);
    defer allocator.free(response);
    return parseOllamaEmbeddingResponse(allocator, response);
}

fn geminiEmbeddingPayload(allocator: std.mem.Allocator, model: []const u8, text: []const u8) ![]u8 {
    var payload: std.ArrayListUnmanaged(u8) = .empty;
    errdefer payload.deinit(allocator);
    const model_ref = try std.fmt.allocPrint(allocator, "models/{s}", .{model});
    defer allocator.free(model_ref);
    try payload.appendSlice(allocator, "{\"model\":");
    try json.appendString(&payload, allocator, model_ref);
    try payload.appendSlice(allocator, ",\"content\":{\"parts\":[{\"text\":");
    try json.appendString(&payload, allocator, text);
    try payload.appendSlice(allocator, "}]}}");
    return payload.toOwnedSlice(allocator);
}

fn ollamaEmbeddingPayload(allocator: std.mem.Allocator, model: []const u8, text: []const u8) ![]u8 {
    var payload: std.ArrayListUnmanaged(u8) = .empty;
    errdefer payload.deinit(allocator);
    try payload.appendSlice(allocator, "{\"model\":");
    try json.appendString(&payload, allocator, model);
    try payload.appendSlice(allocator, ",\"input\":");
    try json.appendString(&payload, allocator, text);
    try payload.append(allocator, '}');
    return payload.toOwnedSlice(allocator);
}

fn voyageEmbeddingPayload(allocator: std.mem.Allocator, model: []const u8, text: []const u8, input_type: []const u8) ![]u8 {
    var payload: std.ArrayListUnmanaged(u8) = .empty;
    errdefer payload.deinit(allocator);
    try payload.appendSlice(allocator, "{\"model\":");
    try json.appendString(&payload, allocator, model);
    try payload.appendSlice(allocator, ",\"input\":[");
    try json.appendString(&payload, allocator, text);
    try payload.appendSlice(allocator, "],\"input_type\":");
    try json.appendString(&payload, allocator, input_type);
    try payload.append(allocator, '}');
    return payload.toOwnedSlice(allocator);
}

fn callOpenAICompatibleChat(allocator: std.mem.Allocator, cfg: CompletionConfig, system_prompt: []const u8, prompt: []const u8) ![]const u8 {
    const url = try providerUrl(allocator, cfg.base_url.?, "/chat/completions", cfg.allow_insecure_http);
    defer allocator.free(url);

    var payload: std.ArrayListUnmanaged(u8) = .empty;
    errdefer payload.deinit(allocator);
    try payload.appendSlice(allocator, "{\"model\":");
    try json.appendString(&payload, allocator, cfg.model.?);
    try payload.appendSlice(allocator, ",\"temperature\":0,\"messages\":[{\"role\":\"system\",\"content\":");
    try json.appendString(&payload, allocator, system_prompt);
    try payload.appendSlice(allocator, "},{\"role\":\"user\",\"content\":");
    try json.appendString(&payload, allocator, prompt);
    try payload.appendSlice(allocator, "}]}");
    const body = try payload.toOwnedSlice(allocator);
    defer allocator.free(body);

    const response = try postJson(allocator, url, cfg.api_key, cfg.timeout_secs, body);
    defer allocator.free(response);
    return parseChatResponse(allocator, response);
}

fn providerUrl(allocator: std.mem.Allocator, base_url: []const u8, suffix: []const u8, allow_insecure_http: bool) ![]u8 {
    try net_security.validateHttpBaseUrl(base_url, allow_insecure_http);
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

fn parseGeminiEmbeddingResponse(allocator: std.mem.Allocator, body: []const u8) ![]f32 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.ProviderInvalidResponse;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return error.ProviderInvalidResponse,
    };
    const embedding = switch (root.get("embedding") orelse return error.ProviderInvalidResponse) {
        .object => |o| o,
        else => return error.ProviderInvalidResponse,
    };
    return embeddingFromValue(allocator, embedding.get("values") orelse return error.ProviderInvalidResponse);
}

fn parseOllamaEmbeddingResponse(allocator: std.mem.Allocator, body: []const u8) ![]f32 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.ProviderInvalidResponse;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return error.ProviderInvalidResponse,
    };
    if (root.get("embedding")) |embedding| return embeddingFromValue(allocator, embedding);
    const embeddings = switch (root.get("embeddings") orelse return error.ProviderInvalidResponse) {
        .array => |a| a,
        else => return error.ProviderInvalidResponse,
    };
    if (embeddings.items.len == 0) return error.ProviderInvalidResponse;
    return embeddingFromValue(allocator, embeddings.items[0]);
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

test "providers parse gemini embedding response" {
    const body = "{\"embedding\":{\"values\":[0,3,4]}}";
    const embedding = try parseGeminiEmbeddingResponse(std.testing.allocator, body);
    defer std.testing.allocator.free(embedding);
    try std.testing.expectEqual(@as(usize, 3), embedding.len);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), embedding[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), embedding[2], 0.0001);
}

test "providers build native embedding payloads" {
    const gemini = try geminiEmbeddingPayload(std.testing.allocator, "text-embedding-004", "hello \"world\"");
    defer std.testing.allocator.free(gemini);
    try std.testing.expect(std.mem.indexOf(u8, gemini, "\"model\":\"models/text-embedding-004\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, gemini, "hello \\\"world\\\"") != null);

    const voyage = try voyageEmbeddingPayload(std.testing.allocator, "voyage-3-lite", "document text", "document");
    defer std.testing.allocator.free(voyage);
    try std.testing.expect(std.mem.indexOf(u8, voyage, "\"model\":\"voyage-3-lite\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, voyage, "\"input_type\":\"document\"") != null);

    const ollama = try ollamaEmbeddingPayload(std.testing.allocator, "nomic-embed-text", "hello \"local\"");
    defer std.testing.allocator.free(ollama);
    try std.testing.expect(std.mem.indexOf(u8, ollama, "\"model\":\"nomic-embed-text\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ollama, "hello \\\"local\\\"") != null);
}

test "embedding provider kind parsing and defaults" {
    try std.testing.expectEqual(EmbeddingProviderKind.gemini, EmbeddingProviderKind.parse("google-gemini"));
    try std.testing.expectEqual(EmbeddingProviderKind.ollama, EmbeddingProviderKind.parse("ollama-native"));
    try std.testing.expectEqual(EmbeddingProviderKind.voyage, EmbeddingProviderKind.parse("voyage-ai"));
    try std.testing.expectEqual(EmbeddingProviderKind.local_deterministic, EmbeddingProviderKind.parse("deterministic"));
    try std.testing.expectEqual(EmbeddingProviderKind.openai_compatible, EmbeddingProviderKind.parse("unknown"));
    try std.testing.expect((EmbeddingConfig{ .provider = .gemini, .api_key = "key" }).enabled());
    try std.testing.expect((EmbeddingConfig{ .provider = .ollama }).enabled());
    try std.testing.expect((EmbeddingConfig{ .provider = .voyage, .api_key = "key" }).enabled());
    try std.testing.expect(!(EmbeddingConfig{ .provider = .gemini }).enabled());
}

test "embedding fallback parsing supports csv and json endpoint specs" {
    const base = EmbeddingConfig{ .base_url = "https://example.test/v1", .api_key = "key", .model = "model", .dimensions = 42, .timeout_secs = 7, .allow_insecure_http = true };
    const csv = try parseEmbeddingFallbacks(std.testing.allocator, "voyage, ollama, local-deterministic", base);
    defer std.testing.allocator.free(csv);
    try std.testing.expectEqual(@as(usize, 3), csv.len);
    try std.testing.expectEqual(EmbeddingProviderKind.voyage, csv[0].provider);
    try std.testing.expectEqualStrings("key", csv[0].api_key.?);
    try std.testing.expect(csv[0].allow_insecure_http);
    try std.testing.expectEqual(EmbeddingProviderKind.ollama, csv[1].provider);
    try std.testing.expectEqual(EmbeddingProviderKind.local_deterministic, csv[2].provider);

    const json_spec =
        \\[{"provider":"gemini","api_key":"g","model":"text-embedding-004","dimensions":768},{"provider":"ollama","base_url":"http://localhost:11434","model":"nomic-embed-text","allow_insecure_http":false},{"provider":"local-deterministic"}]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try parseEmbeddingFallbacks(arena.allocator(), json_spec, base);
    try std.testing.expectEqual(@as(usize, 3), parsed.len);
    try std.testing.expectEqual(EmbeddingProviderKind.gemini, parsed[0].provider);
    try std.testing.expectEqualStrings("g", parsed[0].api_key.?);
    try std.testing.expectEqual(@as(usize, 768), parsed[0].dimensions);
    try std.testing.expectEqual(EmbeddingProviderKind.ollama, parsed[1].provider);
    try std.testing.expectEqualStrings("http://localhost:11434", parsed[1].base_url.?);
    try std.testing.expectEqualStrings("nomic-embed-text", parsed[1].model.?);
    try std.testing.expect(!parsed[1].allow_insecure_http);
    try std.testing.expectEqual(EmbeddingProviderKind.local_deterministic, parsed[2].provider);
}

test "providers parse ollama embedding response" {
    const current = try parseOllamaEmbeddingResponse(std.testing.allocator, "{\"embeddings\":[[0,3,4]]}");
    defer std.testing.allocator.free(current);
    try std.testing.expectEqual(@as(usize, 3), current.len);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), current[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), current[2], 0.0001);

    const legacy = try parseOllamaEmbeddingResponse(std.testing.allocator, "{\"embedding\":[1,0,0]}");
    defer std.testing.allocator.free(legacy);
    try std.testing.expectEqual(@as(usize, 3), legacy.len);
    try std.testing.expectApproxEqAbs(@as(f32, 1), legacy[0], 0.0001);
}

test "embedding fallback chain can recover to deterministic local embeddings" {
    const fallbacks = [_]EmbeddingEndpointConfig{.{ .provider = .local_deterministic, .dimensions = 3 }};
    const result = try embedText(std.testing.allocator, .{
        .provider = .openai_compatible,
        .base_url = "://bad-provider-url",
        .model = "broken",
        .dimensions = 3,
        .timeout_secs = 1,
        .fallbacks = &fallbacks,
    }, "fallback memory", 3);
    defer std.testing.allocator.free(result.embedding);
    try std.testing.expectEqualStrings("local-deterministic", result.provider);
    try std.testing.expectEqual(@as(usize, 3), result.embedding.len);
}

test "provider runtime opens failed primary and skips it during cooldown" {
    const fallbacks = [_]EmbeddingEndpointConfig{.{ .provider = .local_deterministic, .dimensions = 3 }};
    var runtime = try ProviderRuntime.init(std.testing.allocator, .{
        .provider = .openai_compatible,
        .base_url = "://bad-provider-url",
        .model = "broken",
        .dimensions = 3,
        .timeout_secs = 1,
        .fallbacks = &fallbacks,
    }, .{}, .{ .failure_threshold = 1, .cooldown_ms = 60_000 });
    defer runtime.deinit(std.testing.allocator);

    const first = try embedText(std.testing.allocator, .{
        .provider = .openai_compatible,
        .base_url = "://bad-provider-url",
        .model = "broken",
        .dimensions = 3,
        .timeout_secs = 1,
        .fallbacks = &fallbacks,
        .runtime = &runtime,
    }, "fallback memory", 3);
    defer std.testing.allocator.free(first.embedding);
    try std.testing.expectEqualStrings("local-deterministic", first.provider);
    try std.testing.expectEqual(CircuitState.open, runtime.embedding_primary.state);

    const second = try embedText(std.testing.allocator, .{
        .provider = .openai_compatible,
        .base_url = "://bad-provider-url",
        .model = "broken",
        .dimensions = 3,
        .timeout_secs = 1,
        .fallbacks = &fallbacks,
        .runtime = &runtime,
    }, "fallback memory again", 3);
    defer std.testing.allocator.free(second.embedding);
    try std.testing.expectEqualStrings("local-deterministic", second.provider);
    try std.testing.expectEqual(@as(u64, 1), runtime.embedding_primary.skipped);
}

test "providers parse openai-compatible chat response" {
    const body = "{\"choices\":[{\"message\":{\"content\":\"answer\"}}]}";
    const content = try parseChatResponse(std.testing.allocator, body);
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("answer", content);
}

test "providers append endpoint suffixes safely" {
    const a = try providerUrl(std.testing.allocator, "https://example.test/v1", "/embeddings", false);
    defer std.testing.allocator.free(a);
    try std.testing.expectEqualStrings("https://example.test/v1/embeddings", a);
    const b = try providerUrl(std.testing.allocator, "https://example.test/v1/embeddings", "/embeddings", false);
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualStrings("https://example.test/v1/embeddings", b);
    const local = try providerUrl(std.testing.allocator, "http://localhost:11434", "/api/embed", false);
    defer std.testing.allocator.free(local);
    try std.testing.expectEqualStrings("http://localhost:11434/api/embed", local);
    try std.testing.expectError(error.InsecureRuntimeUrl, providerUrl(std.testing.allocator, "http://provider.internal/v1", "/embeddings", false));
    const insecure = try providerUrl(std.testing.allocator, "http://provider.internal/v1", "/embeddings", true);
    defer std.testing.allocator.free(insecure);
    try std.testing.expectEqualStrings("http://provider.internal/v1/embeddings", insecure);
}

test "providers manifest includes concrete and compatible providers" {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try appendProvidersJson(std.testing.allocator, &out);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "openai-compatible-embeddings") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"name\":\"gemini\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"name\":\"voyage\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "provider-circuit-breaker") != null);
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
