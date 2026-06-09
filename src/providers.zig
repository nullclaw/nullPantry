const std = @import("std");
const compat = @import("compat.zig");
const ids = @import("ids.zig");
const json = @import("json_util.zig");
const net_security = @import("net_security.zig");
const vector = @import("vector.zig");
const circuit_breaker = @import("circuit_breaker.zig");
const bounded_int = @import("bounded_int.zig");

pub const max_provider_response_bytes: usize = 8 * 1024 * 1024;
pub const max_configured_provider_response_bytes: usize = 64 * 1024 * 1024;
pub const max_provider_timeout_secs: u32 = 3600;

const openai_embeddings_endpoint_path = "/embeddings";
const gemini_embeddings_endpoint_prefix = "/v1beta/";
const voyage_embeddings_endpoint_path = "/v1/embeddings";
const ollama_embeddings_endpoint_path = "/api/embed";
const openai_chat_endpoint_path = "/chat/completions";

pub const EmbeddingProviderKind = enum {
    local_deterministic,
    openai_compatible,
    gemini,
    ollama,
    voyage,

    pub fn parse(raw: []const u8) !EmbeddingProviderKind {
        if (std.ascii.eqlIgnoreCase(raw, "local") or
            std.ascii.eqlIgnoreCase(raw, "deterministic") or
            std.ascii.eqlIgnoreCase(raw, "local-deterministic"))
        {
            return .local_deterministic;
        }
        if (std.ascii.eqlIgnoreCase(raw, "openai") or
            std.ascii.eqlIgnoreCase(raw, "openai-compatible") or
            std.ascii.eqlIgnoreCase(raw, "openai_compatible"))
        {
            return .openai_compatible;
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
        return error.InvalidEmbeddingProvider;
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

pub const EmbeddingPurpose = enum {
    generic,
    query,
    document,

    pub fn parse(raw: []const u8) !EmbeddingPurpose {
        if (std.ascii.eqlIgnoreCase(raw, "generic") or
            std.ascii.eqlIgnoreCase(raw, "unspecified") or
            std.ascii.eqlIgnoreCase(raw, "default"))
        {
            return .generic;
        }
        if (std.ascii.eqlIgnoreCase(raw, "query") or
            std.ascii.eqlIgnoreCase(raw, "retrieval_query") or
            std.ascii.eqlIgnoreCase(raw, "retrieval-query"))
        {
            return .query;
        }
        if (std.ascii.eqlIgnoreCase(raw, "document") or
            std.ascii.eqlIgnoreCase(raw, "doc") or
            std.ascii.eqlIgnoreCase(raw, "retrieval_document") or
            std.ascii.eqlIgnoreCase(raw, "retrieval-document"))
        {
            return .document;
        }
        return error.InvalidEmbeddingPurpose;
    }

    pub fn name(self: EmbeddingPurpose) []const u8 {
        return switch (self) {
            .generic => "generic",
            .query => "query",
            .document => "document",
        };
    }

    fn voyageInputType(self: EmbeddingPurpose) ?[]const u8 {
        return switch (self) {
            .generic => null,
            .query => "query",
            .document => "document",
        };
    }

    fn geminiTaskType(self: EmbeddingPurpose) ?[]const u8 {
        return switch (self) {
            .generic => null,
            .query => "RETRIEVAL_QUERY",
            .document => "RETRIEVAL_DOCUMENT",
        };
    }
};

pub const EmbeddingEndpointConfig = struct {
    provider: EmbeddingProviderKind = .openai_compatible,
    base_url: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    model: ?[]const u8 = null,
    dimensions: usize = 64,
    send_dimensions: bool = false,
    timeout_secs: u32 = 30,
    max_response_bytes: usize = max_provider_response_bytes,
    allow_insecure_http: bool = false,
    prefer_endpoint_dimensions: bool = false,

    pub fn enabled(self: EmbeddingEndpointConfig) bool {
        return switch (self.provider) {
            .local_deterministic => false,
            .openai_compatible => nonEmptyOptional(self.base_url) and nonEmptyOptional(self.model),
            .ollama => true,
            .gemini, .voyage => nonEmptyOptional(self.api_key),
        };
    }

    pub fn validateUsable(self: EmbeddingEndpointConfig) !void {
        if (self.dimensions == 0) return error.InvalidEmbeddingProviderConfig;
        if (self.dimensions > vector.max_embedding_dimensions) return error.InvalidEmbeddingProviderConfig;
        if (self.timeout_secs == 0) return error.InvalidEmbeddingProviderConfig;
        if (self.timeout_secs > max_provider_timeout_secs) return error.InvalidEmbeddingProviderConfig;
        if (self.max_response_bytes == 0) return error.InvalidEmbeddingProviderConfig;
        if (self.max_response_bytes > max_configured_provider_response_bytes) return error.InvalidEmbeddingProviderConfig;
        return switch (self.provider) {
            .local_deterministic => {},
            .openai_compatible => {
                const configured = self.base_url != null or self.model != null or self.api_key != null;
                if (!configured) return;
                const base_url = self.base_url orelse return error.MissingEmbeddingProviderUrl;
                const model = self.model orelse return error.MissingEmbeddingProviderModel;
                if (!nonEmptyString(base_url)) return error.MissingEmbeddingProviderUrl;
                if (!nonEmptyString(model)) return error.MissingEmbeddingProviderModel;
                try validateProviderEndpointBaseUrl(base_url, openai_embeddings_endpoint_path, self.allow_insecure_http);
                try validateOptionalNonBlank(self.api_key, error.InvalidEmbeddingProviderConfig);
                if (self.api_key) |api_key| try net_security.validateHttpHeaderValue(api_key);
            },
            .ollama => {
                if (self.base_url) |base_url| {
                    if (!nonEmptyString(base_url)) return error.MissingEmbeddingProviderUrl;
                    try validateProviderEndpointBaseUrl(base_url, ollama_embeddings_endpoint_path, self.allow_insecure_http);
                } else {
                    try net_security.validateHttpBaseUrl("http://localhost:11434", self.allow_insecure_http);
                }
                try validateOptionalNonBlank(self.model, error.MissingEmbeddingProviderModel);
                try validateOptionalNonBlank(self.api_key, error.InvalidEmbeddingProviderConfig);
                if (self.api_key) |api_key| try net_security.validateHttpHeaderValue(api_key);
            },
            .gemini => {
                const api_key = self.api_key orelse return error.MissingEmbeddingProviderApiKey;
                if (!nonEmptyString(api_key)) return error.MissingEmbeddingProviderApiKey;
                try net_security.validateHttpHeaderValue(api_key);
                if (self.base_url) |base_url| {
                    if (!nonEmptyString(base_url)) return error.MissingEmbeddingProviderUrl;
                    try net_security.validateHttpBaseUrl(base_url, self.allow_insecure_http);
                }
                try validateOptionalNonBlank(self.model, error.MissingEmbeddingProviderModel);
            },
            .voyage => {
                const api_key = self.api_key orelse return error.MissingEmbeddingProviderApiKey;
                if (!nonEmptyString(api_key)) return error.MissingEmbeddingProviderApiKey;
                try net_security.validateHttpHeaderValue(api_key);
                if (self.base_url) |base_url| {
                    if (!nonEmptyString(base_url)) return error.MissingEmbeddingProviderUrl;
                    try validateProviderEndpointBaseUrl(base_url, voyage_embeddings_endpoint_path, self.allow_insecure_http);
                }
                try validateOptionalNonBlank(self.model, error.MissingEmbeddingProviderModel);
            },
        };
    }
};

fn nonEmptyOptional(value: ?[]const u8) bool {
    return if (value) |text| nonEmptyString(text) else false;
}

fn nonEmptyString(value: []const u8) bool {
    return std.mem.trim(u8, value, " \t\r\n").len > 0;
}

fn validateOptionalNonBlank(value: ?[]const u8, err: anyerror) !void {
    if (value) |text| {
        if (!nonEmptyString(text)) return err;
    }
}

pub const EmbeddingRouteConfig = struct {
    hint: []const u8,
    endpoint: EmbeddingEndpointConfig,
};

pub const EmbeddingConfig = struct {
    provider: EmbeddingProviderKind = .openai_compatible,
    base_url: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    model: ?[]const u8 = null,
    dimensions: usize = 64,
    send_dimensions: bool = false,
    timeout_secs: u32 = 30,
    max_response_bytes: usize = max_provider_response_bytes,
    allow_insecure_http: bool = false,
    fallbacks: []const EmbeddingEndpointConfig = &.{},
    routes: []const EmbeddingRouteConfig = &.{},
    runtime: ?*ProviderRuntime = null,

    pub fn enabled(self: EmbeddingConfig) bool {
        return resolveEmbeddingRoute(self, self.primaryEndpoint()).enabled();
    }

    pub fn validateUsable(self: EmbeddingConfig) !void {
        try resolveEmbeddingRoute(self, self.primaryEndpoint()).validateUsable();
        for (self.fallbacks) |fallback| try fallback.validateUsable();
        for (self.routes) |route| {
            if (!nonEmptyString(route.hint)) return error.InvalidEmbeddingRoutes;
            try route.endpoint.validateUsable();
        }
    }

    pub fn primaryEndpoint(self: EmbeddingConfig) EmbeddingEndpointConfig {
        return .{
            .provider = self.provider,
            .base_url = self.base_url,
            .api_key = self.api_key,
            .model = self.model,
            .dimensions = vector.boundedEmbeddingDimensions(null, self.dimensions),
            .send_dimensions = self.send_dimensions,
            .timeout_secs = boundedProviderTimeoutSecs(null, self.timeout_secs),
            .max_response_bytes = boundedProviderResponseBytes(null, self.max_response_bytes),
            .allow_insecure_http = self.allow_insecure_http,
        };
    }
};

pub fn boundedProviderResponseBytes(value: ?i64, fallback: usize) usize {
    if (value) |raw| {
        return @max(@as(usize, 1), bounded_int.positiveI64ToUsizeBounded(raw, max_configured_provider_response_bytes));
    }
    return @max(@as(usize, 1), @min(fallback, max_configured_provider_response_bytes));
}

pub fn boundedProviderTimeoutSecs(value: ?i64, fallback: u32) u32 {
    if (value) |raw| {
        return @max(@as(u32, 1), bounded_int.positiveI64ToU32Bounded(raw, max_provider_timeout_secs));
    }
    return @max(@as(u32, 1), @min(fallback, max_provider_timeout_secs));
}

fn boundedEmbeddingEndpoint(endpoint: EmbeddingEndpointConfig) EmbeddingEndpointConfig {
    var out = endpoint;
    out.dimensions = vector.boundedEmbeddingDimensions(null, out.dimensions);
    out.timeout_secs = boundedProviderTimeoutSecs(null, out.timeout_secs);
    out.max_response_bytes = boundedProviderResponseBytes(null, out.max_response_bytes);
    return out;
}

pub const CompletionConfig = struct {
    base_url: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    model: ?[]const u8 = null,
    timeout_secs: u32 = 45,
    max_response_bytes: usize = max_provider_response_bytes,
    allow_insecure_http: bool = false,
    runtime: ?*ProviderRuntime = null,

    pub fn enabled(self: CompletionConfig) bool {
        return nonEmptyOptional(self.base_url) and nonEmptyOptional(self.model);
    }

    pub fn validateUsable(self: CompletionConfig) !void {
        if (self.timeout_secs == 0) return error.InvalidCompletionProviderConfig;
        if (self.timeout_secs > max_provider_timeout_secs) return error.InvalidCompletionProviderConfig;
        if (self.max_response_bytes == 0) return error.InvalidCompletionProviderConfig;
        if (self.max_response_bytes > max_configured_provider_response_bytes) return error.InvalidCompletionProviderConfig;
        try validateOptionalNonBlank(self.api_key, error.InvalidCompletionProviderConfig);
        if (self.api_key) |api_key| try net_security.validateHttpHeaderValue(api_key);
        const configured = self.base_url != null or self.model != null or self.api_key != null;
        if (!configured) return;
        const base_url = self.base_url orelse return error.MissingCompletionProviderUrl;
        const model = self.model orelse return error.MissingCompletionProviderModel;
        if (!nonEmptyString(base_url)) return error.MissingCompletionProviderUrl;
        if (!nonEmptyString(model)) return error.MissingCompletionProviderModel;
        try validateProviderEndpointBaseUrl(base_url, openai_chat_endpoint_path, self.allow_insecure_http);
    }
};

pub const CircuitState = circuit_breaker.State;
pub const CircuitOptions = circuit_breaker.Options;

pub const ProviderCircuit = struct {
    provider: []const u8,
    circuit: circuit_breaker.Runtime,

    pub fn init(provider: []const u8, options: CircuitOptions) ProviderCircuit {
        return .{
            .provider = provider,
            .circuit = circuit_breaker.Runtime.init(options),
        };
    }

    pub fn allow(self: *ProviderCircuit, now_ms: i64) bool {
        return self.circuit.allowAt(now_ms);
    }

    pub fn recordSuccess(self: *ProviderCircuit) void {
        self.circuit.recordSuccess();
    }

    pub fn recordFailure(self: *ProviderCircuit, now_ms: i64) void {
        self.circuit.recordFailureAt(now_ms);
    }

    pub fn appendJson(self: ProviderCircuit, allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
        try out.appendSlice(allocator, "{\"provider\":");
        try json.appendString(out, allocator, self.provider);
        try out.appendSlice(allocator, ",\"state\":");
        try json.appendString(out, allocator, self.circuit.state.name());
        try out.print(
            allocator,
            ",\"failure_count\":{d},\"failure_threshold\":{d},\"cooldown_ms\":{d},\"last_failure_ms\":{d},\"attempts\":{d},\"successes\":{d},\"failures\":{d},\"skipped\":{d}}}",
            .{
                self.circuit.failure_count,
                self.circuit.failure_threshold,
                self.circuit.cooldown_ms,
                self.circuit.last_failure_ms,
                self.circuit.attempts,
                self.circuit.successes,
                self.circuit.failures,
                self.circuit.skipped,
            },
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
        try embedding.validateUsable();
        try completion.validateUsable();
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
    owns_provider: bool = false,
    owns_model: bool = false,

    pub fn deinit(self: *EmbeddingResult, allocator: std.mem.Allocator) void {
        if (self.owns_provider and self.provider.len > 0) allocator.free(self.provider);
        if (self.owns_model and self.model.len > 0) allocator.free(self.model);
        if (self.embedding.len > 0) allocator.free(self.embedding);
        self.* = undefined;
    }
};

pub const EmbeddingBatchResult = struct {
    provider: []const u8,
    model: []const u8,
    embeddings: [][]f32,
    owns_provider: bool = false,
    owns_model: bool = false,

    pub fn deinit(self: *EmbeddingBatchResult, allocator: std.mem.Allocator) void {
        if (self.owns_provider and self.provider.len > 0) allocator.free(self.provider);
        if (self.owns_model and self.model.len > 0) allocator.free(self.model);
        for (self.embeddings) |embedding| {
            if (embedding.len > 0) allocator.free(embedding);
        }
        allocator.free(self.embeddings);
        self.* = undefined;
    }
};

pub const CompletionResult = struct {
    provider: []const u8,
    model: []const u8,
    content: []const u8,
};

pub fn freeCompletionResult(allocator: std.mem.Allocator, result: *CompletionResult) void {
    allocator.free(result.content);
    result.* = undefined;
}

pub const ProviderDescriptor = struct {
    name: []const u8,
    role: []const u8,
    status: []const u8,
    protocol: []const u8,
    env_prefix: []const u8,
    config_json: []const u8 = "{}",
};

pub const provider_descriptors = [_]ProviderDescriptor{
    .{ .name = "local-deterministic", .role = "offline deterministic embeddings and fallback retrieval", .status = "built_in", .protocol = "none", .env_prefix = "" },
    .{ .name = "openai-compatible-embeddings", .role = "query and chunk embeddings", .status = "built_in", .protocol = "POST /embeddings", .env_prefix = "NULLPANTRY_EMBEDDING_", .config_json = embedding_provider_config_json },
    .{ .name = "gemini", .role = "query and chunk embeddings", .status = "built_in", .protocol = "POST /v1beta/models/{model}:embedContent", .env_prefix = "NULLPANTRY_EMBEDDING_", .config_json = embedding_provider_config_json },
    .{ .name = "voyage", .role = "query and chunk embeddings", .status = "built_in", .protocol = "POST /v1/embeddings", .env_prefix = "NULLPANTRY_EMBEDDING_", .config_json = embedding_provider_config_json },
    .{ .name = "ollama", .role = "local query and chunk embeddings", .status = "built_in", .protocol = "POST /api/embed", .env_prefix = "NULLPANTRY_EMBEDDING_", .config_json = embedding_provider_config_json },
    .{ .name = "embedding-fallback-chain", .role = "server-side embedding failover between configured providers", .status = "built_in", .protocol = "NULLPANTRY_EMBEDDING_FALLBACKS string or JSON", .env_prefix = "NULLPANTRY_EMBEDDING_", .config_json = embedding_endpoint_list_config_json },
    .{ .name = "embedding-route-hints", .role = "server-side hint: route selection for embedding providers", .status = "built_in", .protocol = "NULLPANTRY_EMBEDDING_ROUTES JSON", .env_prefix = "NULLPANTRY_EMBEDDING_", .config_json = embedding_endpoint_list_config_json },
    .{ .name = "provider-circuit-breaker", .role = "shared runtime provider health, cooldown, and half-open probing", .status = "built_in", .protocol = "diagnostics.providers", .env_prefix = "NULLPANTRY_PROVIDER_", .config_json = provider_circuit_config_json },
    .{ .name = "openai-compatible-chat", .role = "ask synthesis, structured extraction, and optional reranking", .status = "built_in", .protocol = "POST /chat/completions", .env_prefix = "NULLPANTRY_LLM_", .config_json = completion_provider_config_json },
    .{ .name = "ollama-openai-compatible", .role = "local chat or embedding provider through Ollama's OpenAI-compatible endpoint", .status = "compatible", .protocol = "configure Ollama OpenAI compatibility base URL", .env_prefix = "NULLPANTRY_EMBEDDING_|NULLPANTRY_LLM_", .config_json = compatible_ollama_config_json },
};

const embedding_provider_config_json =
    \\{"fields":["provider","base_url","api_key","model","dimensions","send_dimensions","timeout_secs","max_response_bytes","allow_insecure_http"],"purpose":["generic","query","document"],"batch":true,"max_response_bytes":{"env":["NULLPANTRY_PROVIDER_MAX_RESPONSE_BYTES","NULLPANTRY_EMBEDDING_MAX_RESPONSE_BYTES"],"cli":["--provider-max-response-bytes","--embedding-max-response-bytes"],"json_fields":["max_response_bytes","response_max_bytes"]}}
;

const completion_provider_config_json =
    \\{"fields":["base_url","api_key","model","timeout_secs","max_response_bytes","allow_insecure_http"],"max_response_bytes":{"env":["NULLPANTRY_PROVIDER_MAX_RESPONSE_BYTES","NULLPANTRY_LLM_MAX_RESPONSE_BYTES"],"cli":["--provider-max-response-bytes","--llm-max-response-bytes"]}}
;

const embedding_endpoint_list_config_json =
    \\{"fields":["provider","base_url","api_key","model","dimensions","send_dimensions","timeout_secs","max_response_bytes","allow_insecure_http"],"json_fields":["max_response_bytes","response_max_bytes","send_dimensions"],"server_env":["NULLPANTRY_EMBEDDING_FALLBACKS","NULLPANTRY_EMBEDDING_ROUTES"]}
;

const provider_circuit_config_json =
    \\{"fields":["failure_threshold","cooldown_ms"],"env":["NULLPANTRY_PROVIDER_CIRCUIT_FAILURE_THRESHOLD","NULLPANTRY_PROVIDER_CIRCUIT_COOLDOWN_MS"],"cli":["--provider-circuit-failure-threshold","--provider-circuit-cooldown-ms"]}
;

const compatible_ollama_config_json =
    \\{"embedding":["NULLPANTRY_EMBEDDING_PROVIDER=ollama","NULLPANTRY_EMBEDDING_BASE_URL"],"completion":["NULLPANTRY_LLM_BASE_URL","NULLPANTRY_LLM_MODEL"],"max_response_bytes":["NULLPANTRY_EMBEDDING_MAX_RESPONSE_BYTES","NULLPANTRY_LLM_MAX_RESPONSE_BYTES"],"embedding_purpose":["generic","query","document"]}
;

pub fn appendProvidersJson(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    try out.append(allocator, '[');
    for (provider_descriptors, 0..) |descriptor, i| {
        if (i > 0) try out.append(allocator, ',');
        try appendProviderDescriptorJson(allocator, out, descriptor);
    }
    try out.append(allocator, ']');
}

fn appendProviderDescriptorJson(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), descriptor: ProviderDescriptor) !void {
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
    try out.appendSlice(allocator, ",\"config\":");
    try json.appendRawJsonObject(out, allocator, descriptor.config_json);
    try out.append(allocator, '}');
}

pub fn embedText(allocator: std.mem.Allocator, cfg: EmbeddingConfig, text: []const u8, fallback_dimensions: usize) !EmbeddingResult {
    return embedTextForPurpose(allocator, cfg, text, fallback_dimensions, .generic);
}

pub fn embedTextForPurpose(allocator: std.mem.Allocator, cfg: EmbeddingConfig, text: []const u8, fallback_dimensions: usize, purpose: EmbeddingPurpose) !EmbeddingResult {
    const texts = [_][]const u8{text};
    var batch = try embedTextsForPurpose(allocator, cfg, &texts, fallback_dimensions, purpose);
    errdefer batch.deinit(allocator);
    if (batch.embeddings.len != 1) return error.ProviderInvalidResponse;
    const embedding = batch.embeddings[0];
    const owns_provider = batch.owns_provider;
    const owns_model = batch.owns_model;
    const provider = if (owns_provider) try allocator.dupe(u8, batch.provider) else batch.provider;
    errdefer if (owns_provider) allocator.free(provider);
    const model = if (owns_model) try allocator.dupe(u8, batch.model) else batch.model;
    errdefer if (owns_model) allocator.free(model);
    batch.embeddings[0] = &[_]f32{};
    batch.deinit(allocator);
    return .{
        .provider = provider,
        .model = model,
        .embedding = embedding,
        .owns_provider = owns_provider,
        .owns_model = owns_model,
    };
}

pub fn embedTextsForPurpose(allocator: std.mem.Allocator, cfg: EmbeddingConfig, texts: []const []const u8, fallback_dimensions: usize, purpose: EmbeddingPurpose) !EmbeddingBatchResult {
    if (texts.len == 0) {
        return .{
            .provider = "local-deterministic",
            .model = "local-deterministic",
            .embeddings = try allocator.alloc([]f32, 0),
        };
    }
    const safe_fallback_dimensions = vector.boundedEmbeddingDimensions(null, fallback_dimensions);
    const primary = resolveEmbeddingRoute(cfg, cfg.primaryEndpoint());
    var first_err: ?anyerror = null;
    var skipped_by_circuit = false;
    if (primary.enabled() or primary.provider == .local_deterministic) {
        if (providerAllowed(cfg.runtime, .embedding_primary)) {
            if (embedBatchWithEndpoint(allocator, primary, texts, safe_fallback_dimensions, purpose)) |result| {
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
        const routed_fallback = resolveEmbeddingRoute(cfg, fallback);
        if (!routed_fallback.enabled() and routed_fallback.provider != .local_deterministic) continue;
        const target = ProviderTarget{ .embedding_fallback = i };
        if (!providerAllowed(cfg.runtime, target)) {
            skipped_by_circuit = true;
            continue;
        }
        if (embedBatchWithEndpoint(allocator, routed_fallback, texts, safe_fallback_dimensions, purpose)) |result| {
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

    const embeddings = try deterministicEmbeddingBatch(allocator, texts, safe_fallback_dimensions);
    return .{
        .provider = "local-deterministic",
        .model = "local-deterministic",
        .embeddings = embeddings,
    };
}

fn embedBatchWithEndpoint(allocator: std.mem.Allocator, cfg: EmbeddingEndpointConfig, texts: []const []const u8, fallback_dimensions: usize, purpose: EmbeddingPurpose) !EmbeddingBatchResult {
    const embeddings = switch (cfg.provider) {
        .local_deterministic => blk: {
            const dimensions = if (cfg.prefer_endpoint_dimensions and cfg.dimensions > 0) vector.boundedEmbeddingDimensions(null, cfg.dimensions) else fallback_dimensions;
            break :blk try deterministicEmbeddingBatch(allocator, texts, dimensions);
        },
        .openai_compatible => try callOpenAICompatibleEmbeddings(allocator, cfg, texts),
        .gemini => try callGeminiEmbeddings(allocator, cfg, texts, purpose),
        .ollama => try callOllamaEmbeddings(allocator, cfg, texts),
        .voyage => try callVoyageEmbeddings(allocator, cfg, texts, purpose),
    };
    return .{
        .provider = cfg.provider.name(),
        .model = embeddingModel(cfg),
        .embeddings = embeddings,
    };
}

fn deterministicEmbeddingBatch(allocator: std.mem.Allocator, texts: []const []const u8, dimensions: usize) ![][]f32 {
    var out = try allocator.alloc([]f32, texts.len);
    for (out) |*slot| slot.* = &[_]f32{};
    errdefer {
        for (out) |embedding| {
            if (embedding.len > 0) allocator.free(embedding);
        }
        allocator.free(out);
    }
    for (texts, 0..) |text, i| {
        out[i] = try vector.deterministicEmbedding(allocator, text, dimensions);
    }
    return out;
}

pub fn extractEmbeddingHint(model: ?[]const u8) ?[]const u8 {
    const value = model orelse return null;
    const prefix = "hint:";
    if (!std.mem.startsWith(u8, value, prefix)) return null;
    return value[prefix.len..];
}

pub fn resolveEmbeddingRoute(cfg: EmbeddingConfig, endpoint: EmbeddingEndpointConfig) EmbeddingEndpointConfig {
    const base_endpoint = boundedEmbeddingEndpoint(endpoint);
    const hint = extractEmbeddingHint(base_endpoint.model) orelse return base_endpoint;
    for (cfg.routes) |route| {
        if (std.mem.eql(u8, route.hint, hint)) return boundedEmbeddingEndpoint(route.endpoint);
    }
    return base_endpoint;
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

pub fn parseEmbeddingRoutes(allocator: std.mem.Allocator, raw: []const u8, base: EmbeddingConfig) ![]EmbeddingRouteConfig {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return allocator.alloc(EmbeddingRouteConfig, 0);
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch return error.InvalidEmbeddingRoutes;
    defer parsed.deinit();

    var out: std.ArrayListUnmanaged(EmbeddingRouteConfig) = .empty;
    errdefer out.deinit(allocator);
    switch (parsed.value) {
        .array => |arr| for (arr.items) |item| {
            const obj = switch (item) {
                .object => |value| value,
                else => return error.InvalidEmbeddingRoutes,
            };
            try out.append(allocator, try embeddingRouteFromObject(allocator, null, obj, base));
        },
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                const route_obj = switch (entry.value_ptr.*) {
                    .object => |value| value,
                    else => return error.InvalidEmbeddingRoutes,
                };
                try out.append(allocator, try embeddingRouteFromObject(allocator, entry.key_ptr.*, route_obj, base));
            }
        },
        else => return error.InvalidEmbeddingRoutes,
    }
    return out.toOwnedSlice(allocator);
}

fn parseEmbeddingFallbacksList(allocator: std.mem.Allocator, raw: []const u8, base: EmbeddingConfig) ![]EmbeddingEndpointConfig {
    var out: std.ArrayListUnmanaged(EmbeddingEndpointConfig) = .empty;
    errdefer out.deinit(allocator);
    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |item| {
        const provider_name = std.mem.trim(u8, item, " \t\r\n");
        if (provider_name.len == 0) continue;
        try out.append(allocator, fallbackFromProvider(base, try EmbeddingProviderKind.parse(provider_name)));
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
            .string => |name| try out.append(allocator, fallbackFromProvider(base, try EmbeddingProviderKind.parse(name))),
            .object => |obj| {
                const provider = try EmbeddingProviderKind.parse(json.stringField(obj, "provider") orelse json.stringField(obj, "name") orelse "openai-compatible");
                const dimensions_present = json.intField(obj, "dimensions") != null;
                const send_dimensions = json.boolField(obj, "send_dimensions") orelse json.boolField(obj, "send_dimensions_to_provider") orelse dimensions_present;
                try out.append(allocator, .{
                    .provider = provider,
                    .base_url = try dupOptional(allocator, json.nullableStringField(obj, "base_url")),
                    .api_key = try dupOptional(allocator, json.nullableStringField(obj, "api_key")),
                    .model = try dupOptional(allocator, json.nullableStringField(obj, "model")),
                    .dimensions = vector.boundedEmbeddingDimensions(json.intField(obj, "dimensions"), base.dimensions),
                    .send_dimensions = send_dimensions,
                    .timeout_secs = boundedProviderTimeoutSecs(json.intField(obj, "timeout_secs"), base.timeout_secs),
                    .max_response_bytes = parseMaxResponseBytes(obj, base.max_response_bytes),
                    .allow_insecure_http = json.boolField(obj, "allow_insecure_http") orelse json.boolField(obj, "insecure_http") orelse base.allow_insecure_http,
                });
            },
            else => return error.InvalidEmbeddingFallbacks,
        }
    }
    return out.toOwnedSlice(allocator);
}

fn embeddingRouteFromObject(allocator: std.mem.Allocator, key_hint: ?[]const u8, obj: std.json.ObjectMap, base: EmbeddingConfig) !EmbeddingRouteConfig {
    const hint = key_hint orelse
        json.stringField(obj, "hint") orelse
        json.stringField(obj, "route") orelse
        json.stringField(obj, "name") orelse
        return error.InvalidEmbeddingRoutes;
    if (hint.len == 0) return error.InvalidEmbeddingRoutes;

    var endpoint = base.primaryEndpoint();
    if (json.stringField(obj, "provider") orelse json.stringField(obj, "provider_name")) |provider| {
        endpoint.provider = try EmbeddingProviderKind.parse(provider);
    }
    if (json.nullableStringField(obj, "base_url")) |base_url| endpoint.base_url = try allocator.dupe(u8, base_url);
    if (json.nullableStringField(obj, "api_key")) |api_key| endpoint.api_key = try allocator.dupe(u8, api_key);
    if (json.nullableStringField(obj, "model")) |model| endpoint.model = try allocator.dupe(u8, model);
    if (json.intField(obj, "dimensions")) |dimensions| {
        endpoint.dimensions = vector.boundedEmbeddingDimensions(dimensions, endpoint.dimensions);
        endpoint.send_dimensions = true;
    }
    if (json.boolField(obj, "send_dimensions") orelse json.boolField(obj, "send_dimensions_to_provider")) |send| endpoint.send_dimensions = send;
    if (json.intField(obj, "timeout_secs")) |timeout_secs| endpoint.timeout_secs = boundedProviderTimeoutSecs(timeout_secs, endpoint.timeout_secs);
    endpoint.max_response_bytes = parseMaxResponseBytes(obj, endpoint.max_response_bytes);
    if (json.boolField(obj, "allow_insecure_http") orelse json.boolField(obj, "insecure_http")) |allow| endpoint.allow_insecure_http = allow;
    endpoint.prefer_endpoint_dimensions = true;

    return .{
        .hint = try allocator.dupe(u8, hint),
        .endpoint = endpoint,
    };
}

fn fallbackFromProvider(base: EmbeddingConfig, provider: EmbeddingProviderKind) EmbeddingEndpointConfig {
    return .{
        .provider = provider,
        .base_url = base.base_url,
        .api_key = base.api_key,
        .model = base.model,
        .dimensions = vector.boundedEmbeddingDimensions(null, base.dimensions),
        .send_dimensions = base.send_dimensions,
        .timeout_secs = boundedProviderTimeoutSecs(null, base.timeout_secs),
        .max_response_bytes = boundedProviderResponseBytes(null, base.max_response_bytes),
        .allow_insecure_http = base.allow_insecure_http,
    };
}

fn parseMaxResponseBytes(obj: std.json.ObjectMap, fallback: usize) usize {
    return boundedProviderResponseBytes(json.intField(obj, "max_response_bytes") orelse json.intField(obj, "response_max_bytes"), fallback);
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

fn callOpenAICompatibleEmbeddings(allocator: std.mem.Allocator, cfg: EmbeddingEndpointConfig, texts: []const []const u8) ![][]f32 {
    const url = try providerUrl(allocator, cfg.base_url.?, openai_embeddings_endpoint_path, cfg.allow_insecure_http);
    defer allocator.free(url);

    var payload: std.ArrayListUnmanaged(u8) = .empty;
    errdefer payload.deinit(allocator);
    try payload.appendSlice(allocator, "{\"model\":");
    try json.appendString(&payload, allocator, cfg.model.?);
    try payload.appendSlice(allocator, ",\"input\":");
    try appendJsonStringArray(allocator, &payload, texts);
    if (shouldSendDimensions(cfg)) {
        try payload.print(allocator, ",\"dimensions\":{d}", .{cfg.dimensions});
    }
    try payload.append(allocator, '}');
    const body = try payload.toOwnedSlice(allocator);
    defer allocator.free(body);

    const response = try postJson(allocator, url, cfg.api_key, cfg.timeout_secs, cfg.max_response_bytes, body);
    defer allocator.free(response);
    return parseEmbeddingBatchResponse(allocator, response);
}

fn callGeminiEmbeddings(allocator: std.mem.Allocator, cfg: EmbeddingEndpointConfig, texts: []const []const u8, purpose: EmbeddingPurpose) ![][]f32 {
    const base_url = cfg.base_url orelse "https://generativelanguage.googleapis.com";
    const model = cfg.model orelse "text-embedding-004";
    const key = cfg.api_key orelse return error.ProviderUnavailable;
    const model_resource = try geminiModelResource(allocator, model);
    defer allocator.free(model_resource);
    const model_resource_path = try geminiModelResourcePath(allocator, model_resource);
    defer allocator.free(model_resource_path);
    const suffix = try std.fmt.allocPrint(allocator, "{s}{s}:embedContent", .{ gemini_embeddings_endpoint_prefix, model_resource_path });
    defer allocator.free(suffix);
    const url = try providerUrl(allocator, base_url, suffix, cfg.allow_insecure_http);
    defer allocator.free(url);

    var out = try allocator.alloc([]f32, texts.len);
    for (out) |*slot| slot.* = &[_]f32{};
    errdefer {
        for (out) |embedding| {
            if (embedding.len > 0) allocator.free(embedding);
        }
        allocator.free(out);
    }
    for (texts, 0..) |text, i| {
        if (text.len == 0) {
            out[i] = try allocator.alloc(f32, 0);
            continue;
        }
        const body = try geminiEmbeddingPayload(allocator, model_resource, text, purpose, cfg);
        defer allocator.free(body);
        const response = try postJsonWithGoogleApiKey(allocator, url, key, cfg.timeout_secs, cfg.max_response_bytes, body);
        defer allocator.free(response);
        out[i] = try parseGeminiEmbeddingResponse(allocator, response);
    }
    return out;
}

fn callVoyageEmbeddings(allocator: std.mem.Allocator, cfg: EmbeddingEndpointConfig, texts: []const []const u8, purpose: EmbeddingPurpose) ![][]f32 {
    const base_url = cfg.base_url orelse "https://api.voyageai.com";
    const model = cfg.model orelse "voyage-3-lite";
    const url = try providerUrl(allocator, base_url, voyage_embeddings_endpoint_path, cfg.allow_insecure_http);
    defer allocator.free(url);

    const body = try voyageEmbeddingPayload(allocator, model, texts, purpose, cfg);
    defer allocator.free(body);
    const response = try postJson(allocator, url, cfg.api_key, cfg.timeout_secs, cfg.max_response_bytes, body);
    defer allocator.free(response);
    return parseEmbeddingBatchResponse(allocator, response);
}

fn callOllamaEmbeddings(allocator: std.mem.Allocator, cfg: EmbeddingEndpointConfig, texts: []const []const u8) ![][]f32 {
    const base_url = cfg.base_url orelse "http://localhost:11434";
    const model = cfg.model orelse "nomic-embed-text";
    const url = try providerUrl(allocator, base_url, ollama_embeddings_endpoint_path, cfg.allow_insecure_http);
    defer allocator.free(url);

    const body = try ollamaEmbeddingPayload(allocator, model, texts);
    defer allocator.free(body);
    const response = try postJson(allocator, url, cfg.api_key, cfg.timeout_secs, cfg.max_response_bytes, body);
    defer allocator.free(response);
    return parseOllamaEmbeddingBatchResponse(allocator, response);
}

fn geminiEmbeddingPayload(allocator: std.mem.Allocator, model_resource: []const u8, text: []const u8, purpose: EmbeddingPurpose, cfg: EmbeddingEndpointConfig) ![]u8 {
    var payload: std.ArrayListUnmanaged(u8) = .empty;
    errdefer payload.deinit(allocator);
    try payload.appendSlice(allocator, "{\"model\":");
    try json.appendString(&payload, allocator, model_resource);
    try payload.appendSlice(allocator, ",\"content\":{\"parts\":[{\"text\":");
    try json.appendString(&payload, allocator, text);
    try payload.appendSlice(allocator, "}]}");
    if (purpose.geminiTaskType()) |task_type| {
        try payload.appendSlice(allocator, ",\"taskType\":");
        try json.appendString(&payload, allocator, task_type);
    }
    if (shouldSendDimensions(cfg)) {
        try payload.print(allocator, ",\"outputDimensionality\":{d}", .{cfg.dimensions});
    }
    try payload.append(allocator, '}');
    return payload.toOwnedSlice(allocator);
}

fn ollamaEmbeddingPayload(allocator: std.mem.Allocator, model: []const u8, texts: []const []const u8) ![]u8 {
    var payload: std.ArrayListUnmanaged(u8) = .empty;
    errdefer payload.deinit(allocator);
    try payload.appendSlice(allocator, "{\"model\":");
    try json.appendString(&payload, allocator, model);
    try payload.appendSlice(allocator, ",\"input\":");
    if (texts.len == 1) {
        try json.appendString(&payload, allocator, texts[0]);
    } else {
        try appendJsonStringArray(allocator, &payload, texts);
    }
    try payload.append(allocator, '}');
    return payload.toOwnedSlice(allocator);
}

fn voyageEmbeddingPayload(allocator: std.mem.Allocator, model: []const u8, texts: []const []const u8, purpose: EmbeddingPurpose, cfg: EmbeddingEndpointConfig) ![]u8 {
    var payload: std.ArrayListUnmanaged(u8) = .empty;
    errdefer payload.deinit(allocator);
    try payload.appendSlice(allocator, "{\"model\":");
    try json.appendString(&payload, allocator, model);
    try payload.appendSlice(allocator, ",\"input\":");
    try appendJsonStringArray(allocator, &payload, texts);
    if (purpose.voyageInputType()) |input_type| {
        try payload.appendSlice(allocator, ",\"input_type\":");
        try json.appendString(&payload, allocator, input_type);
    }
    if (shouldSendDimensions(cfg)) {
        try payload.print(allocator, ",\"output_dimension\":{d}", .{cfg.dimensions});
    }
    try payload.append(allocator, '}');
    return payload.toOwnedSlice(allocator);
}

fn appendJsonStringArray(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), values: []const []const u8) !void {
    try out.append(allocator, '[');
    for (values, 0..) |value, i| {
        if (i > 0) try out.append(allocator, ',');
        try json.appendString(out, allocator, value);
    }
    try out.append(allocator, ']');
}

fn shouldSendDimensions(cfg: EmbeddingEndpointConfig) bool {
    return cfg.send_dimensions and cfg.dimensions > 0;
}

fn geminiModelResource(allocator: std.mem.Allocator, model: []const u8) ![]u8 {
    const prefix = if (std.mem.startsWith(u8, model, "models/"))
        "models"
    else if (std.mem.startsWith(u8, model, "tunedModels/"))
        "tunedModels"
    else
        "models";
    const id = if (std.mem.startsWith(u8, model, "models/"))
        model["models/".len..]
    else if (std.mem.startsWith(u8, model, "tunedModels/"))
        model["tunedModels/".len..]
    else
        model;
    try validateGeminiModelId(id);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, id });
}

fn geminiModelResourcePath(allocator: std.mem.Allocator, model_resource: []const u8) ![]u8 {
    const separator = std.mem.indexOfScalar(u8, model_resource, '/') orelse return error.InvalidEmbeddingProviderConfig;
    const prefix = model_resource[0..separator];
    const id = model_resource[separator + 1 ..];
    try validateGeminiModelPrefix(prefix);
    try validateGeminiModelId(id);

    const encoded_id = try net_security.percentEncodePathSegment(allocator, id);
    defer allocator.free(encoded_id);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, encoded_id });
}

fn validateGeminiModelPrefix(prefix: []const u8) !void {
    if (std.mem.eql(u8, prefix, "models") or std.mem.eql(u8, prefix, "tunedModels")) return;
    return error.InvalidEmbeddingProviderConfig;
}

fn validateGeminiModelId(id: []const u8) !void {
    if (id.len == 0 or std.mem.trim(u8, id, " \t\r\n").len != id.len) return error.InvalidEmbeddingProviderConfig;
    if (std.mem.indexOfScalar(u8, id, '/') != null) return error.InvalidEmbeddingProviderConfig;
}

fn callOpenAICompatibleChat(allocator: std.mem.Allocator, cfg: CompletionConfig, system_prompt: []const u8, prompt: []const u8) ![]const u8 {
    const url = try providerUrl(allocator, cfg.base_url.?, openai_chat_endpoint_path, cfg.allow_insecure_http);
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

    const response = try postJson(allocator, url, cfg.api_key, cfg.timeout_secs, cfg.max_response_bytes, body);
    defer allocator.free(response);
    return parseChatResponse(allocator, response);
}

fn providerUrl(allocator: std.mem.Allocator, base_url: []const u8, suffix: []const u8, allow_insecure_http: bool) ![]u8 {
    try validateProviderEndpointBaseUrl(base_url, suffix, allow_insecure_http);
    return net_security.joinHttpBaseUrl(allocator, base_url, suffix, allow_insecure_http);
}

fn validateProviderEndpointBaseUrl(base_url: []const u8, endpoint_path: []const u8, allow_insecure_http: bool) !void {
    try net_security.validateHttpBaseUrl(base_url, allow_insecure_http);
    if (std.mem.endsWith(u8, trimTrailingSlashes(base_url), endpoint_path)) return error.InvalidRuntimeUrl;
}

fn trimTrailingSlashes(value: []const u8) []const u8 {
    var end = value.len;
    while (end > 0 and value[end - 1] == '/') : (end -= 1) {}
    return value[0..end];
}

fn postJson(allocator: std.mem.Allocator, url: []const u8, api_key: ?[]const u8, timeout_secs: u32, max_response_bytes: usize, payload: []const u8) ![]u8 {
    return postJsonWithAuth(allocator, url, api_key, null, timeout_secs, max_response_bytes, payload);
}

fn postJsonWithGoogleApiKey(allocator: std.mem.Allocator, url: []const u8, api_key: []const u8, timeout_secs: u32, max_response_bytes: usize, payload: []const u8) ![]u8 {
    return postJsonWithAuth(allocator, url, null, api_key, timeout_secs, max_response_bytes, payload);
}

fn postJsonWithAuth(allocator: std.mem.Allocator, url: []const u8, bearer_api_key: ?[]const u8, google_api_key: ?[]const u8, timeout_secs: u32, max_response_bytes: usize, payload: []const u8) ![]u8 {
    var auth_header: ?[]u8 = null;
    defer if (auth_header) |h| allocator.free(h);

    var extra_headers_buf: [2]std.http.Header = undefined;
    var header_count: usize = 0;

    if (bearer_api_key) |key| {
        try net_security.validateHttpHeaderValue(key);
        auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{key});
        extra_headers_buf[header_count] = .{ .name = "Authorization", .value = auth_header.? };
        header_count += 1;
    }
    if (google_api_key) |key| {
        try net_security.validateHttpHeaderValue(key);
        extra_headers_buf[header_count] = .{ .name = "x-goog-api-key", .value = key };
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

    net_security.applyHttpSocketTimeout(req.connection, timeout_secs);

    req.transfer_encoding = .{ .content_length = payload.len };
    var body_writer = req.sendBodyUnflushed(&.{}) catch return error.ProviderUnavailable;
    body_writer.writer.writeAll(payload) catch return error.ProviderUnavailable;
    body_writer.end() catch return error.ProviderUnavailable;
    net_security.flushHttpConnection(req.connection) catch return error.ProviderUnavailable;

    var response = req.receiveHead(&.{}) catch return error.ProviderUnavailable;
    if (response.head.status != .ok) return error.ProviderHttpError;

    const reader = response.reader(&.{});
    return readLimitedProviderResponse(allocator, reader, boundedProviderResponseBytes(null, max_response_bytes)) catch |err| switch (err) {
        error.StreamTooLong => error.ProviderResponseTooLarge,
        error.ReadFailed => error.ProviderUnavailable,
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn readLimitedProviderResponse(allocator: std.mem.Allocator, reader: *std.Io.Reader, limit: usize) ![]u8 {
    return net_security.readBoundedResponse(allocator, reader, limit);
}

fn parseEmbeddingResponse(allocator: std.mem.Allocator, body: []const u8) ![]f32 {
    var batch = try parseEmbeddingBatchResponse(allocator, body);
    errdefer {
        for (batch) |embedding| {
            if (embedding.len > 0) allocator.free(embedding);
        }
        allocator.free(batch);
    }
    if (batch.len != 1) return error.ProviderInvalidResponse;
    const embedding = batch[0];
    batch[0] = &[_]f32{};
    allocator.free(batch);
    return embedding;
}

fn parseEmbeddingBatchResponse(allocator: std.mem.Allocator, body: []const u8) ![][]f32 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.ProviderInvalidResponse;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return error.ProviderInvalidResponse,
    };
    if (root.get("embedding")) |embedding_value| {
        var out = try allocator.alloc([]f32, 1);
        errdefer allocator.free(out);
        out[0] = try embeddingFromValue(allocator, embedding_value);
        return out;
    }
    const data = switch (root.get("data") orelse return error.ProviderInvalidResponse) {
        .array => |a| a,
        else => return error.ProviderInvalidResponse,
    };
    if (data.items.len == 0) return error.ProviderInvalidResponse;
    var out = try allocator.alloc([]f32, data.items.len);
    for (out) |*slot| slot.* = &[_]f32{};
    errdefer {
        for (out) |embedding| {
            if (embedding.len > 0) allocator.free(embedding);
        }
        allocator.free(out);
    }
    for (data.items, 0..) |item_value, i| {
        const item = switch (item_value) {
            .object => |o| o,
            else => return error.ProviderInvalidResponse,
        };
        out[i] = try embeddingFromValue(allocator, item.get("embedding") orelse return error.ProviderInvalidResponse);
    }
    return out;
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
    var batch = try parseOllamaEmbeddingBatchResponse(allocator, body);
    errdefer {
        for (batch) |embedding| {
            if (embedding.len > 0) allocator.free(embedding);
        }
        allocator.free(batch);
    }
    if (batch.len != 1) return error.ProviderInvalidResponse;
    const embedding = batch[0];
    batch[0] = &[_]f32{};
    allocator.free(batch);
    return embedding;
}

fn parseOllamaEmbeddingBatchResponse(allocator: std.mem.Allocator, body: []const u8) ![][]f32 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.ProviderInvalidResponse;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return error.ProviderInvalidResponse,
    };
    if (root.get("embedding")) |embedding| {
        var out = try allocator.alloc([]f32, 1);
        errdefer allocator.free(out);
        out[0] = try embeddingFromValue(allocator, embedding);
        return out;
    }
    const embeddings = switch (root.get("embeddings") orelse return error.ProviderInvalidResponse) {
        .array => |a| a,
        else => return error.ProviderInvalidResponse,
    };
    if (embeddings.items.len == 0) return error.ProviderInvalidResponse;
    var out = try allocator.alloc([]f32, embeddings.items.len);
    for (out) |*slot| slot.* = &[_]f32{};
    errdefer {
        for (out) |embedding| {
            if (embedding.len > 0) allocator.free(embedding);
        }
        allocator.free(out);
    }
    for (embeddings.items, 0..) |embedding, i| {
        out[i] = try embeddingFromValue(allocator, embedding);
    }
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

test "providers parse batched openai-compatible embedding response" {
    const body = "{\"data\":[{\"embedding\":[1,0,0]},{\"embedding\":[0,3,4]}]}";
    const embeddings = try parseEmbeddingBatchResponse(std.testing.allocator, body);
    defer {
        for (embeddings) |embedding| std.testing.allocator.free(embedding);
        std.testing.allocator.free(embeddings);
    }
    try std.testing.expectEqual(@as(usize, 2), embeddings.len);
    try std.testing.expectEqual(@as(usize, 3), embeddings[0].len);
    try std.testing.expectApproxEqAbs(@as(f32, 1), embeddings[0][0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), embeddings[1][1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), embeddings[1][2], 0.0001);
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
    const gemini = try geminiEmbeddingPayload(std.testing.allocator, "models/text-embedding-004", "hello \"world\"", .document, .{ .dimensions = 768, .send_dimensions = true });
    defer std.testing.allocator.free(gemini);
    try std.testing.expect(std.mem.indexOf(u8, gemini, "\"model\":\"models/text-embedding-004\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, gemini, "hello \\\"world\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, gemini, "\"taskType\":\"RETRIEVAL_DOCUMENT\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, gemini, "\"outputDimensionality\":768") != null);

    const voyage_texts = [_][]const u8{"document text"};
    const voyage = try voyageEmbeddingPayload(std.testing.allocator, "voyage-3-lite", &voyage_texts, .document, .{ .dimensions = 512, .send_dimensions = true });
    defer std.testing.allocator.free(voyage);
    try std.testing.expect(std.mem.indexOf(u8, voyage, "\"model\":\"voyage-3-lite\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, voyage, "\"input\":[\"document text\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, voyage, "\"input_type\":\"document\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, voyage, "\"output_dimension\":512") != null);

    const ollama_texts = [_][]const u8{"hello \"local\""};
    const ollama = try ollamaEmbeddingPayload(std.testing.allocator, "nomic-embed-text", &ollama_texts);
    defer std.testing.allocator.free(ollama);
    try std.testing.expect(std.mem.indexOf(u8, ollama, "\"model\":\"nomic-embed-text\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ollama, "hello \\\"local\\\"") != null);
}

test "embedding provider kind parsing and defaults" {
    try std.testing.expectEqual(EmbeddingProviderKind.openai_compatible, try EmbeddingProviderKind.parse("openai-compatible"));
    try std.testing.expectEqual(EmbeddingProviderKind.openai_compatible, try EmbeddingProviderKind.parse("openai_compatible"));
    try std.testing.expectEqual(EmbeddingProviderKind.gemini, try EmbeddingProviderKind.parse("google-gemini"));
    try std.testing.expectEqual(EmbeddingProviderKind.ollama, try EmbeddingProviderKind.parse("ollama-native"));
    try std.testing.expectEqual(EmbeddingProviderKind.voyage, try EmbeddingProviderKind.parse("voyage-ai"));
    try std.testing.expectEqual(EmbeddingProviderKind.local_deterministic, try EmbeddingProviderKind.parse("deterministic"));
    try std.testing.expectError(error.InvalidEmbeddingProvider, EmbeddingProviderKind.parse("unknown"));
    try std.testing.expectEqual(EmbeddingPurpose.generic, try EmbeddingPurpose.parse("default"));
    try std.testing.expectEqual(EmbeddingPurpose.query, try EmbeddingPurpose.parse("retrieval_query"));
    try std.testing.expectEqual(EmbeddingPurpose.document, try EmbeddingPurpose.parse("doc"));
    try std.testing.expectError(error.InvalidEmbeddingPurpose, EmbeddingPurpose.parse("wrong-purpose"));
    try std.testing.expect((EmbeddingConfig{ .provider = .gemini, .api_key = "key" }).enabled());
    try std.testing.expect((EmbeddingConfig{ .provider = .ollama }).enabled());
    try std.testing.expect((EmbeddingConfig{ .provider = .voyage, .api_key = "key" }).enabled());
    try std.testing.expect(!(EmbeddingConfig{ .provider = .gemini }).enabled());
}

test "gemini model resources keep body names separate from escaped URL paths" {
    const default_resource = try geminiModelResource(std.testing.allocator, "text-embedding-004");
    defer std.testing.allocator.free(default_resource);
    try std.testing.expectEqualStrings("models/text-embedding-004", default_resource);

    const explicit_resource = try geminiModelResource(std.testing.allocator, "models/gemini-embedding-exp");
    defer std.testing.allocator.free(explicit_resource);
    try std.testing.expectEqualStrings("models/gemini-embedding-exp", explicit_resource);

    const special_resource = try geminiModelResource(std.testing.allocator, "models/text embedding?#");
    defer std.testing.allocator.free(special_resource);
    try std.testing.expectEqualStrings("models/text embedding?#", special_resource);

    const escaped_path = try geminiModelResourcePath(std.testing.allocator, special_resource);
    defer std.testing.allocator.free(escaped_path);
    try std.testing.expectEqualStrings("models/text%20embedding%3F%23", escaped_path);

    try std.testing.expectError(error.InvalidEmbeddingProviderConfig, geminiModelResource(std.testing.allocator, "models/../../bad"));
    try std.testing.expectError(error.InvalidEmbeddingProviderConfig, geminiModelResourcePath(std.testing.allocator, "publishers/google/models/text-embedding-004"));
}

test "embedding provider config validates usable external setup" {
    try (EmbeddingConfig{}).validateUsable();
    try (EmbeddingConfig{ .provider = .local_deterministic }).validateUsable();
    try (EmbeddingConfig{ .provider = .ollama }).validateUsable();

    try std.testing.expect(!(EmbeddingConfig{ .provider = .openai_compatible, .base_url = " ", .model = "text-embedding-3-small" }).enabled());
    try std.testing.expectError(error.MissingEmbeddingProviderUrl, (EmbeddingConfig{ .provider = .openai_compatible, .base_url = " ", .model = "text-embedding-3-small" }).validateUsable());
    try std.testing.expectError(error.MissingEmbeddingProviderModel, (EmbeddingConfig{ .provider = .openai_compatible, .base_url = "https://api.example/v1", .model = " " }).validateUsable());
    try std.testing.expectError(error.InsecureRuntimeUrl, (EmbeddingConfig{ .provider = .openai_compatible, .base_url = "http://api.example/v1", .model = "text-embedding-3-small" }).validateUsable());
    try std.testing.expectError(error.InvalidRuntimeUrl, (EmbeddingConfig{ .provider = .openai_compatible, .base_url = "https://api.example/v1/embeddings", .model = "text-embedding-3-small" }).validateUsable());
    try std.testing.expectError(error.InvalidHttpHeaderValue, (EmbeddingConfig{ .provider = .openai_compatible, .base_url = "https://api.example/v1", .model = "text-embedding-3-small", .api_key = "bad\r\nX: y" }).validateUsable());
    try (EmbeddingConfig{ .provider = .openai_compatible, .base_url = "https://api.example/v1", .model = "text-embedding-3-small" }).validateUsable();

    try std.testing.expectError(error.MissingEmbeddingProviderApiKey, (EmbeddingConfig{ .provider = .gemini }).validateUsable());
    try std.testing.expectError(error.MissingEmbeddingProviderApiKey, (EmbeddingConfig{ .provider = .voyage, .api_key = " " }).validateUsable());
    try std.testing.expectError(error.InvalidHttpHeaderValue, (EmbeddingConfig{ .provider = .gemini, .api_key = "bad\x7f" }).validateUsable());
    try std.testing.expectError(error.InvalidRuntimeUrl, (EmbeddingConfig{ .provider = .voyage, .api_key = "key", .base_url = "https://api.voyageai.com/v1/embeddings" }).validateUsable());
    try std.testing.expectError(error.InvalidRuntimeUrl, (EmbeddingConfig{ .provider = .ollama, .base_url = "http://localhost:11434/api/embed" }).validateUsable());
    try (EmbeddingConfig{ .provider = .gemini, .api_key = "key" }).validateUsable();
    try (EmbeddingConfig{ .provider = .voyage, .api_key = "key" }).validateUsable();

    const invalid_fallbacks = [_]EmbeddingEndpointConfig{.{ .provider = .voyage }};
    try std.testing.expectError(error.MissingEmbeddingProviderApiKey, (EmbeddingConfig{ .fallbacks = &invalid_fallbacks }).validateUsable());

    var runtime = try ProviderRuntime.init(std.testing.allocator, .{ .provider = .ollama }, .{}, .{});
    runtime.deinit(std.testing.allocator);
    try std.testing.expectError(error.MissingEmbeddingProviderApiKey, ProviderRuntime.init(std.testing.allocator, .{ .provider = .gemini }, .{}, .{}));
}

test "completion provider config validates usable external setup" {
    try (CompletionConfig{}).validateUsable();
    try std.testing.expect(!(CompletionConfig{ .base_url = " ", .model = "gpt" }).enabled());
    try std.testing.expectError(error.MissingCompletionProviderUrl, (CompletionConfig{ .base_url = " ", .model = "gpt" }).validateUsable());
    try std.testing.expectError(error.MissingCompletionProviderModel, (CompletionConfig{ .base_url = "https://api.example/v1", .model = " " }).validateUsable());
    try std.testing.expectError(error.InsecureRuntimeUrl, (CompletionConfig{ .base_url = "http://api.example/v1", .model = "gpt" }).validateUsable());
    try std.testing.expectError(error.InvalidRuntimeUrl, (CompletionConfig{ .base_url = "https://api.example/v1/chat/completions", .model = "gpt" }).validateUsable());
    try std.testing.expectError(error.InvalidHttpHeaderValue, (CompletionConfig{ .base_url = "https://api.example/v1", .model = "gpt", .api_key = "bad\tkey" }).validateUsable());
    try (CompletionConfig{ .base_url = "https://api.example/v1", .model = "gpt" }).validateUsable();
}

test "embedding dimensions are bounded at provider boundaries" {
    try std.testing.expectError(error.InvalidEmbeddingProviderConfig, (EmbeddingEndpointConfig{ .provider = .local_deterministic, .dimensions = vector.max_embedding_dimensions + 1 }).validateUsable());

    const oversized_base = EmbeddingConfig{ .base_url = "https://example.test/v1", .api_key = "key", .model = "base", .dimensions = vector.max_embedding_dimensions + 10 };
    try std.testing.expectEqual(vector.max_embedding_dimensions, oversized_base.primaryEndpoint().dimensions);
    const csv = try parseEmbeddingFallbacks(std.testing.allocator, "local-deterministic", oversized_base);
    defer std.testing.allocator.free(csv);
    try std.testing.expectEqual(vector.max_embedding_dimensions, csv[0].dimensions);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const fallbacks = try parseEmbeddingFallbacks(arena.allocator(),
        \\[{"provider":"local-deterministic","dimensions":9223372036854775807},{"provider":"local-deterministic","dimensions":0}]
    , .{});
    try std.testing.expectEqual(vector.max_embedding_dimensions, fallbacks[0].dimensions);
    try std.testing.expectEqual(@as(usize, 1), fallbacks[1].dimensions);

    const routes = try parseEmbeddingRoutes(arena.allocator(),
        \\{"huge":{"provider":"local-deterministic","dimensions":9223372036854775807},"low":{"provider":"local-deterministic","dimensions":0}}
    , .{});
    try std.testing.expectEqual(vector.max_embedding_dimensions, routes[0].endpoint.dimensions);
    try std.testing.expectEqual(@as(usize, 1), routes[1].endpoint.dimensions);
}

test "provider response byte limits are bounded at provider boundaries" {
    try std.testing.expectEqual(@as(usize, 1), boundedProviderResponseBytes(-1, max_provider_response_bytes));
    try std.testing.expectEqual(@as(usize, 1), boundedProviderResponseBytes(0, max_provider_response_bytes));
    try std.testing.expectEqual(@as(usize, 12345), boundedProviderResponseBytes(12345, max_provider_response_bytes));
    try std.testing.expectEqual(max_configured_provider_response_bytes, boundedProviderResponseBytes(9223372036854775807, max_provider_response_bytes));
    try std.testing.expectEqual(max_configured_provider_response_bytes, boundedProviderResponseBytes(null, max_configured_provider_response_bytes + 1));
    try std.testing.expectError(error.InvalidEmbeddingProviderConfig, (EmbeddingEndpointConfig{ .provider = .local_deterministic, .max_response_bytes = max_configured_provider_response_bytes + 1 }).validateUsable());
    try std.testing.expectError(error.InvalidCompletionProviderConfig, (CompletionConfig{ .max_response_bytes = max_configured_provider_response_bytes + 1 }).validateUsable());

    const oversized_base = EmbeddingConfig{ .base_url = "https://example.test/v1", .api_key = "key", .model = "base", .max_response_bytes = max_configured_provider_response_bytes + 10 };
    try std.testing.expectEqual(max_configured_provider_response_bytes, oversized_base.primaryEndpoint().max_response_bytes);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const fallbacks = try parseEmbeddingFallbacks(arena.allocator(),
        \\[{"provider":"local-deterministic","max_response_bytes":9223372036854775807},{"provider":"local-deterministic","max_response_bytes":0}]
    , .{});
    try std.testing.expectEqual(max_configured_provider_response_bytes, fallbacks[0].max_response_bytes);
    try std.testing.expectEqual(@as(usize, 1), fallbacks[1].max_response_bytes);

    const routes = try parseEmbeddingRoutes(arena.allocator(),
        \\{"huge":{"provider":"local-deterministic","max_response_bytes":9223372036854775807},"low":{"provider":"local-deterministic","max_response_bytes":0}}
    , .{});
    try std.testing.expectEqual(max_configured_provider_response_bytes, routes[0].endpoint.max_response_bytes);
    try std.testing.expectEqual(@as(usize, 1), routes[1].endpoint.max_response_bytes);
}

test "provider timeout seconds are bounded at provider boundaries" {
    try std.testing.expectEqual(@as(u32, 1), boundedProviderTimeoutSecs(-1, 30));
    try std.testing.expectEqual(@as(u32, 1), boundedProviderTimeoutSecs(0, 30));
    try std.testing.expectEqual(@as(u32, 42), boundedProviderTimeoutSecs(42, 30));
    try std.testing.expectEqual(max_provider_timeout_secs, boundedProviderTimeoutSecs(9223372036854775807, 30));
    try std.testing.expectEqual(max_provider_timeout_secs, boundedProviderTimeoutSecs(null, max_provider_timeout_secs + 1));
    try std.testing.expectError(error.InvalidEmbeddingProviderConfig, (EmbeddingEndpointConfig{ .provider = .local_deterministic, .timeout_secs = max_provider_timeout_secs + 1 }).validateUsable());
    try std.testing.expectError(error.InvalidCompletionProviderConfig, (CompletionConfig{ .timeout_secs = max_provider_timeout_secs + 1 }).validateUsable());

    const oversized_base = EmbeddingConfig{ .base_url = "https://example.test/v1", .api_key = "key", .model = "base", .timeout_secs = max_provider_timeout_secs + 10 };
    try std.testing.expectEqual(max_provider_timeout_secs, oversized_base.primaryEndpoint().timeout_secs);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const fallbacks = try parseEmbeddingFallbacks(arena.allocator(),
        \\[{"provider":"local-deterministic","timeout_secs":9223372036854775807},{"provider":"local-deterministic","timeout_secs":0}]
    , .{});
    try std.testing.expectEqual(max_provider_timeout_secs, fallbacks[0].timeout_secs);
    try std.testing.expectEqual(@as(u32, 1), fallbacks[1].timeout_secs);

    const routes = try parseEmbeddingRoutes(arena.allocator(),
        \\{"huge":{"provider":"local-deterministic","timeout_secs":9223372036854775807},"low":{"provider":"local-deterministic","timeout_secs":0}}
    , .{});
    try std.testing.expectEqual(max_provider_timeout_secs, routes[0].endpoint.timeout_secs);
    try std.testing.expectEqual(@as(u32, 1), routes[1].endpoint.timeout_secs);
}

test "embedding fallback parsing supports csv and json endpoint specs" {
    const base = EmbeddingConfig{ .base_url = "https://example.test/v1", .api_key = "key", .model = "model", .dimensions = 42, .timeout_secs = 7, .max_response_bytes = 12345, .allow_insecure_http = true };
    const csv = try parseEmbeddingFallbacks(std.testing.allocator, "voyage, ollama, local-deterministic", base);
    defer std.testing.allocator.free(csv);
    try std.testing.expectEqual(@as(usize, 3), csv.len);
    try std.testing.expectEqual(EmbeddingProviderKind.voyage, csv[0].provider);
    try std.testing.expectEqualStrings("key", csv[0].api_key.?);
    try std.testing.expectEqual(@as(usize, 12345), csv[0].max_response_bytes);
    try std.testing.expect(csv[0].allow_insecure_http);
    try std.testing.expectEqual(EmbeddingProviderKind.ollama, csv[1].provider);
    try std.testing.expectEqual(EmbeddingProviderKind.local_deterministic, csv[2].provider);
    try std.testing.expectError(error.InvalidEmbeddingProvider, parseEmbeddingFallbacks(std.testing.allocator, "voyage, typo-provider", base));

    const json_spec =
        \\[{"provider":"gemini","api_key":"g","model":"text-embedding-004","dimensions":768,"max_response_bytes":2048},{"provider":"ollama","base_url":"http://localhost:11434","model":"nomic-embed-text","allow_insecure_http":false},{"provider":"local-deterministic"}]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try parseEmbeddingFallbacks(arena.allocator(), json_spec, base);
    try std.testing.expectEqual(@as(usize, 3), parsed.len);
    try std.testing.expectEqual(EmbeddingProviderKind.gemini, parsed[0].provider);
    try std.testing.expectEqualStrings("g", parsed[0].api_key.?);
    try std.testing.expectEqual(@as(usize, 768), parsed[0].dimensions);
    try std.testing.expect(parsed[0].send_dimensions);
    try std.testing.expectEqual(@as(usize, 2048), parsed[0].max_response_bytes);
    try std.testing.expectEqual(EmbeddingProviderKind.ollama, parsed[1].provider);
    try std.testing.expectEqualStrings("http://localhost:11434", parsed[1].base_url.?);
    try std.testing.expectEqualStrings("nomic-embed-text", parsed[1].model.?);
    try std.testing.expectEqual(@as(usize, 12345), parsed[1].max_response_bytes);
    try std.testing.expect(!parsed[1].allow_insecure_http);
    try std.testing.expectEqual(EmbeddingProviderKind.local_deterministic, parsed[2].provider);
    try std.testing.expectError(error.InvalidEmbeddingProvider, parseEmbeddingFallbacks(arena.allocator(),
        \\[{"provider":"typo-provider"}]
    , base));
}

test "embedding routes parse object and array specs" {
    const base = EmbeddingConfig{ .base_url = "https://example.test/v1", .api_key = "key", .model = "base-model", .dimensions = 42, .timeout_secs = 7, .max_response_bytes = 9999, .allow_insecure_http = true };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const object_routes = try parseEmbeddingRoutes(arena.allocator(),
        \\{"semantic":{"provider":"voyage","api_key":"voyage-key","model":"voyage-3-large","dimensions":1024,"max_response_bytes":4096},"local":{"provider":"local-deterministic","dimensions":5}}
    , base);
    try std.testing.expectEqual(@as(usize, 2), object_routes.len);
    try std.testing.expectEqualStrings("semantic", object_routes[0].hint);
    try std.testing.expectEqual(EmbeddingProviderKind.voyage, object_routes[0].endpoint.provider);
    try std.testing.expectEqualStrings("voyage-key", object_routes[0].endpoint.api_key.?);
    try std.testing.expectEqualStrings("voyage-3-large", object_routes[0].endpoint.model.?);
    try std.testing.expectEqual(@as(usize, 1024), object_routes[0].endpoint.dimensions);
    try std.testing.expect(object_routes[0].endpoint.send_dimensions);
    try std.testing.expectEqual(@as(usize, 4096), object_routes[0].endpoint.max_response_bytes);
    try std.testing.expectEqualStrings("local", object_routes[1].hint);
    try std.testing.expectEqual(EmbeddingProviderKind.local_deterministic, object_routes[1].endpoint.provider);
    try std.testing.expectEqual(@as(usize, 5), object_routes[1].endpoint.dimensions);
    try std.testing.expectEqual(@as(usize, 9999), object_routes[1].endpoint.max_response_bytes);

    const array_routes = try parseEmbeddingRoutes(arena.allocator(),
        \\[{"hint":"code","provider":"ollama","base_url":"http://localhost:11434","model":"nomic-embed-text","allow_insecure_http":false}]
    , base);
    try std.testing.expectEqual(@as(usize, 1), array_routes.len);
    try std.testing.expectEqualStrings("code", array_routes[0].hint);
    try std.testing.expectEqual(EmbeddingProviderKind.ollama, array_routes[0].endpoint.provider);
    try std.testing.expectEqualStrings("http://localhost:11434", array_routes[0].endpoint.base_url.?);
    try std.testing.expect(!array_routes[0].endpoint.allow_insecure_http);
    try std.testing.expectError(error.InvalidEmbeddingProvider, parseEmbeddingRoutes(arena.allocator(),
        \\{"bad":{"provider":"typo-provider"}}
    , base));
}

test "embedding hint routes resolve before provider fallback" {
    const routes = [_]EmbeddingRouteConfig{.{
        .hint = "semantic",
        .endpoint = .{ .provider = .local_deterministic, .dimensions = 3, .prefer_endpoint_dimensions = true },
    }};
    const result = try embedText(std.testing.allocator, .{
        .provider = .openai_compatible,
        .base_url = "://bad-provider-url",
        .model = "hint:semantic",
        .dimensions = 99,
        .timeout_secs = 1,
        .routes = &routes,
    }, "routed semantic memory", 99);
    defer std.testing.allocator.free(result.embedding);
    try std.testing.expectEqualStrings("local-deterministic", result.provider);
    try std.testing.expectEqual(@as(usize, 3), result.embedding.len);
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

test "providers parse batched ollama embedding response" {
    const embeddings = try parseOllamaEmbeddingBatchResponse(std.testing.allocator, "{\"embeddings\":[[1,0,0],[0,3,4]]}");
    defer {
        for (embeddings) |embedding| std.testing.allocator.free(embedding);
        std.testing.allocator.free(embeddings);
    }
    try std.testing.expectEqual(@as(usize, 2), embeddings.len);
    try std.testing.expectApproxEqAbs(@as(f32, 1), embeddings[0][0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), embeddings[1][1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), embeddings[1][2], 0.0001);
}

test "local deterministic embeddings support batch purpose API" {
    const texts = [_][]const u8{ "alpha", "beta" };
    var result = try embedTextsForPurpose(std.testing.allocator, .{ .provider = .local_deterministic }, &texts, 6, .document);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), result.embeddings.len);
    try std.testing.expectEqual(@as(usize, 6), result.embeddings[0].len);
    try std.testing.expectEqual(@as(usize, 6), result.embeddings[1].len);
}

test "embedding fallback chain can recover to deterministic local embeddings" {
    const fallbacks = [_]EmbeddingEndpointConfig{.{ .provider = .local_deterministic, .dimensions = 3 }};
    const result = try embedText(std.testing.allocator, .{
        .provider = .openai_compatible,
        .base_url = "http://127.0.0.1:1",
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
        .base_url = "http://127.0.0.1:1",
        .model = "broken",
        .dimensions = 3,
        .timeout_secs = 1,
        .fallbacks = &fallbacks,
    }, .{}, .{ .failure_threshold = 1, .cooldown_ms = 60_000 });
    defer runtime.deinit(std.testing.allocator);

    const first = try embedText(std.testing.allocator, .{
        .provider = .openai_compatible,
        .base_url = "http://127.0.0.1:1",
        .model = "broken",
        .dimensions = 3,
        .timeout_secs = 1,
        .fallbacks = &fallbacks,
        .runtime = &runtime,
    }, "fallback memory", 3);
    defer std.testing.allocator.free(first.embedding);
    try std.testing.expectEqualStrings("local-deterministic", first.provider);
    try std.testing.expectEqual(CircuitState.open, runtime.embedding_primary.circuit.state);

    const second = try embedText(std.testing.allocator, .{
        .provider = .openai_compatible,
        .base_url = "http://127.0.0.1:1",
        .model = "broken",
        .dimensions = 3,
        .timeout_secs = 1,
        .fallbacks = &fallbacks,
        .runtime = &runtime,
    }, "fallback memory again", 3);
    defer std.testing.allocator.free(second.embedding);
    try std.testing.expectEqualStrings("local-deterministic", second.provider);
    try std.testing.expectEqual(@as(u64, 1), runtime.embedding_primary.circuit.skipped);
}

test "providers parse openai-compatible chat response" {
    const body = "{\"choices\":[{\"message\":{\"content\":\"answer\"}}]}";
    const content = try parseChatResponse(std.testing.allocator, body);
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("answer", content);
}

test "providers build endpoint URLs through shared base URL policy" {
    const a = try providerUrl(std.testing.allocator, "https://example.test/v1", openai_embeddings_endpoint_path, false);
    defer std.testing.allocator.free(a);
    try std.testing.expectEqualStrings("https://example.test/v1/embeddings", a);
    try std.testing.expectError(error.InvalidRuntimeUrl, providerUrl(std.testing.allocator, "https://example.test/v1/embeddings", openai_embeddings_endpoint_path, false));
    const local = try providerUrl(std.testing.allocator, "http://localhost:11434", ollama_embeddings_endpoint_path, false);
    defer std.testing.allocator.free(local);
    try std.testing.expectEqualStrings("http://localhost:11434/api/embed", local);
    try std.testing.expectError(error.InsecureRuntimeUrl, providerUrl(std.testing.allocator, "http://provider.internal/v1", openai_embeddings_endpoint_path, false));
    const insecure = try providerUrl(std.testing.allocator, "http://provider.internal/v1", openai_embeddings_endpoint_path, true);
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
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"config\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "NULLPANTRY_PROVIDER_MAX_RESPONSE_BYTES") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "NULLPANTRY_EMBEDDING_MAX_RESPONSE_BYTES") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "NULLPANTRY_LLM_MAX_RESPONSE_BYTES") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"json_fields\":[\"max_response_bytes\",\"response_max_bytes\"]") != null);
}

test "providers manifest rejects invalid descriptor config JSON" {
    const valid = ProviderDescriptor{
        .name = "valid-provider",
        .role = "test provider",
        .status = "test",
        .protocol = "none",
        .env_prefix = "TEST_",
        .config_json = "{\"fields\":[\"model\"]}",
    };
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try appendProviderDescriptorJson(std.testing.allocator, &out, valid);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"config\":{\"fields\":[\"model\"]}") != null);

    var bad_array = valid;
    bad_array.config_json = "[\"not-object\"]";
    var bad_array_out: std.ArrayListUnmanaged(u8) = .empty;
    defer bad_array_out.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidRawJson, appendProviderDescriptorJson(std.testing.allocator, &bad_array_out, bad_array));

    var bad_json = valid;
    bad_json.config_json = "{\"fields\":";
    var bad_json_out: std.ArrayListUnmanaged(u8) = .empty;
    defer bad_json_out.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidRawJson, appendProviderDescriptorJson(std.testing.allocator, &bad_json_out, bad_json));
}

test "provider response reader enforces byte cap" {
    var ok_reader: std.Io.Reader = .fixed("abcdef");
    const ok = try readLimitedProviderResponse(std.testing.allocator, &ok_reader, 6);
    defer std.testing.allocator.free(ok);
    try std.testing.expectEqualStrings("abcdef", ok);

    var too_large_reader: std.Io.Reader = .fixed("abcdefg");
    try std.testing.expectError(error.StreamTooLong, readLimitedProviderResponse(std.testing.allocator, &too_large_reader, 6));

    var max_reader: std.Io.Reader = .fixed("ok");
    const max = try readLimitedProviderResponse(std.testing.allocator, &max_reader, std.math.maxInt(usize));
    defer std.testing.allocator.free(max);
    try std.testing.expectEqualStrings("ok", max);
}
