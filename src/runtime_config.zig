const std = @import("std");
const providers = @import("providers.zig");
const retrieval = @import("retrieval.zig");
const lifecycle = @import("lifecycle.zig");
const vector = @import("vector.zig");
const store_config = @import("store_config.zig");
const agent_memory_config = @import("agent_memory_config.zig");
const vector_runtime = @import("vector_runtime.zig");
const analytics_runtime = @import("analytics_runtime.zig");
const lucid_runtime = @import("lucid_runtime.zig");
const graph_runtime = @import("graph_runtime.zig");
const json_string_array = @import("json_string_array.zig");

pub const admin_scopes_json = "[\"admin\"]";
pub const admin_capabilities_json = "[\"read\",\"write\",\"propose\",\"verify\",\"delete\",\"export\",\"feed_apply\"]";
pub const public_read_scopes_json = "[\"public\"]";
pub const public_read_capabilities_json = "[\"read\"]";
pub const local_actor_id = "local";
pub const worker_actor_id = "system:worker";
pub const default_filesystem_root = ".";

pub const AuthConfig = struct {
    required_token: ?[]const u8 = null,
    token_principals_json: ?[]const u8 = null,
    trust_actor_headers: bool = false,
    allow_no_auth_non_loopback: bool = false,
};

pub const PrincipalConfig = struct {
    actor_id: []const u8 = local_actor_id,
    scopes_json: []const u8 = admin_scopes_json,
    capabilities_json: []const u8 = admin_capabilities_json,

    pub fn validateUsable(self: PrincipalConfig) !void {
        if (std.mem.trim(u8, self.actor_id, " \t\r\n").len == 0) return error.InvalidPrincipalConfig;
        if (!json_string_array.itemsNonBlank(self.scopes_json)) return error.InvalidPrincipalConfig;
        if (!json_string_array.itemsNonBlank(self.capabilities_json)) return error.InvalidPrincipalConfig;
    }
};

pub const local_admin_principal: PrincipalConfig = .{};
pub const worker_principal: PrincipalConfig = .{ .actor_id = worker_actor_id };

pub const ProviderConfig = struct {
    embedding: providers.EmbeddingConfig = .{},
    completion: providers.CompletionConfig = .{ .timeout_secs = 30 },
    default_max_response_bytes: usize = providers.max_provider_response_bytes,
    embedding_max_response_bytes: ?usize = null,
    completion_max_response_bytes: ?usize = null,
    circuit_failure_threshold: u32 = 3,
    circuit_cooldown_ms: i64 = 30_000,

    pub fn embeddingConfig(self: ProviderConfig) providers.EmbeddingConfig {
        var out = self.embedding;
        out.timeout_secs = providers.boundedProviderTimeoutSecs(null, out.timeout_secs);
        out.max_response_bytes = providers.boundedProviderResponseBytes(null, self.embedding_max_response_bytes orelse self.default_max_response_bytes);
        return out;
    }

    pub fn completionConfig(self: ProviderConfig) providers.CompletionConfig {
        var out = self.completion;
        out.timeout_secs = providers.boundedProviderTimeoutSecs(null, out.timeout_secs);
        out.max_response_bytes = providers.boundedProviderResponseBytes(null, self.completion_max_response_bytes orelse self.default_max_response_bytes);
        return out;
    }

    pub fn withRuntime(self: ProviderConfig, provider_runtime: ?*providers.ProviderRuntime) ProviderConfig {
        var out = self;
        out.embedding.runtime = provider_runtime;
        out.completion.runtime = provider_runtime;
        return out;
    }

    pub fn runtime(self: ProviderConfig) ?*providers.ProviderRuntime {
        return self.embedding.runtime orelse self.completion.runtime;
    }

    pub fn embeddingWithDimensions(self: ProviderConfig, dimensions: usize) providers.EmbeddingConfig {
        var out = self.embedding;
        out.dimensions = vector.boundedEmbeddingDimensions(null, dimensions);
        return out;
    }

    pub fn validateUsable(self: ProviderConfig) !void {
        try self.embedding.validateUsable();
        try self.completion.validateUsable();
    }
};

pub const RetrievalConfig = struct {
    adaptive_keyword_max_tokens: u32 = retrieval.default_adaptive_keyword_max_tokens,
    adaptive_vector_min_tokens: u32 = retrieval.default_adaptive_vector_min_tokens,
    rollout_policy: lifecycle.RolloutPolicy = .{ .mode = .on, .salt = "retrieval" },
    chunker: vector.ChunkerConfig = .{},
};

pub const FilesystemConfig = struct {
    root: []const u8 = default_filesystem_root,
};

pub const RuntimeStoresConfig = struct {
    records_backend: store_config.BackendKind = .sqlite,
    postgres_url: ?[]const u8 = null,
    agent_memory_backend: agent_memory_config.BackendKind = .native,
    memory: agent_memory_config.MemoryConfig = .{},
    markdown_agent_memory: agent_memory_config.MarkdownConfig = .{},
    redis: agent_memory_config.RedisConfig = .{},
    clickhouse_agent_memory: agent_memory_config.ClickHouseConfig = .{},
    api_agent_memory: agent_memory_config.ApiConfig = .{},
    holographic_agent_memory: agent_memory_config.HolographicConfig = .{},
    agent_memory_stores: []const agent_memory_config.NamedConfig = &.{},
    vector_backend: vector_runtime.Config = .{},
    vector_stores: []const vector_runtime.NamedConfig = &.{},
    graph_projection: graph_runtime.Config = .{},
    analytics_backend: analytics_runtime.Config = .{},
    lucid_projection: lucid_runtime.Config = .{},
};

test "provider config carries runtime into embedding and completion configs" {
    var runtime = try providers.ProviderRuntime.init(std.testing.allocator, .{}, .{}, .{});
    defer runtime.deinit(std.testing.allocator);

    const cfg = (ProviderConfig{}).withRuntime(&runtime);
    try std.testing.expect(cfg.runtime() == &runtime);
    try std.testing.expect(cfg.embedding.runtime == &runtime);
    try std.testing.expect(cfg.completion.runtime == &runtime);
}

test "principal defaults centralize local admin and worker identities" {
    try local_admin_principal.validateUsable();
    try worker_principal.validateUsable();
    try std.testing.expectEqualStrings(local_actor_id, local_admin_principal.actor_id);
    try std.testing.expectEqualStrings(admin_scopes_json, local_admin_principal.scopes_json);
    try std.testing.expectEqualStrings(admin_capabilities_json, local_admin_principal.capabilities_json);
    try std.testing.expectEqualStrings(worker_actor_id, worker_principal.actor_id);
    try std.testing.expectEqualStrings(admin_scopes_json, worker_principal.scopes_json);
    try std.testing.expectEqualStrings(admin_capabilities_json, worker_principal.capabilities_json);
}

test "principal config validates actor access lists" {
    try (PrincipalConfig{ .actor_id = "agent:a", .scopes_json = "[\"public\",\"team:\\u0041\"]", .capabilities_json = "[\"read\",\"write\"]" }).validateUsable();
    try std.testing.expectError(error.InvalidPrincipalConfig, (PrincipalConfig{ .actor_id = " ", .scopes_json = "[\"public\"]", .capabilities_json = "[\"read\"]" }).validateUsable());
    try std.testing.expectError(error.InvalidPrincipalConfig, (PrincipalConfig{ .actor_id = "agent:a", .scopes_json = "public", .capabilities_json = "[\"read\"]" }).validateUsable());
    try std.testing.expectError(error.InvalidPrincipalConfig, (PrincipalConfig{ .actor_id = "agent:a", .scopes_json = "[\"public\",]", .capabilities_json = "[\"read\"]" }).validateUsable());
    try std.testing.expectError(error.InvalidPrincipalConfig, (PrincipalConfig{ .actor_id = "agent:a", .scopes_json = "[\"\"]", .capabilities_json = "[\"read\"]" }).validateUsable());
    try std.testing.expectError(error.InvalidPrincipalConfig, (PrincipalConfig{ .actor_id = "agent:a", .scopes_json = "[\"public\"]", .capabilities_json = "[1]" }).validateUsable());
    try std.testing.expectError(error.InvalidPrincipalConfig, (PrincipalConfig{ .actor_id = "agent:a", .scopes_json = "[\"public\"]", .capabilities_json = "[\"read\",\"  \"]" }).validateUsable());
}

test "provider config materializes endpoint response limits" {
    const cfg = ProviderConfig{
        .default_max_response_bytes = 4096,
        .embedding_max_response_bytes = 8192,
        .completion = .{ .timeout_secs = 45 },
    };

    const embedding = cfg.embeddingConfig();
    const completion = cfg.completionConfig();

    try std.testing.expectEqual(@as(usize, 8192), embedding.max_response_bytes);
    try std.testing.expectEqual(@as(usize, 4096), completion.max_response_bytes);
    try std.testing.expectEqual(@as(u32, 45), completion.timeout_secs);
}

test "provider config bounds materialized response limits" {
    const cfg = ProviderConfig{
        .default_max_response_bytes = providers.max_configured_provider_response_bytes + 1,
        .embedding_max_response_bytes = providers.max_configured_provider_response_bytes + 2,
        .completion_max_response_bytes = providers.max_configured_provider_response_bytes + 3,
    };

    try std.testing.expectEqual(providers.max_configured_provider_response_bytes, cfg.embeddingConfig().max_response_bytes);
    try std.testing.expectEqual(providers.max_configured_provider_response_bytes, cfg.completionConfig().max_response_bytes);
}

test "provider config bounds materialized timeout seconds" {
    const cfg = ProviderConfig{
        .embedding = .{ .timeout_secs = providers.max_provider_timeout_secs + 1 },
        .completion = .{ .timeout_secs = providers.max_provider_timeout_secs + 2 },
    };

    try std.testing.expectEqual(providers.max_provider_timeout_secs, cfg.embeddingConfig().timeout_secs);
    try std.testing.expectEqual(providers.max_provider_timeout_secs, cfg.completionConfig().timeout_secs);
}

test "provider config bounds materialized embedding dimensions" {
    const cfg = ProviderConfig{};
    const embedding = cfg.embeddingWithDimensions(vector.max_embedding_dimensions + 1);
    try std.testing.expectEqual(vector.max_embedding_dimensions, embedding.dimensions);
}
