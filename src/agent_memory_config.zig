const std = @import("std");
const bounded_int = @import("bounded_int.zig");
const redis_config = @import("redis_config.zig");
const holographic_config = @import("agent_memory_holographic_config.zig");
const api_profiles = @import("agent_memory_api_profiles.zig");
const clickhouse_contracts = @import("clickhouse_contracts.zig");
const json_string_array = @import("json_string_array.zig");
const net_security = @import("net_security.zig");
const runtime_limits = @import("runtime_limits.zig");

pub const RedisConfig = redis_config.Config;
pub const HolographicConfig = holographic_config.Config;
pub const max_remote_timeout_secs: u32 = runtime_limits.max_timeout_secs;
pub const max_remote_response_bytes: usize = runtime_limits.max_response_bytes;
pub const max_markdown_file_bytes: usize = 16 * 1024 * 1024;

pub const BackendKind = enum {
    none,
    native,
    markdown,
    memory_lru,
    redis,
    clickhouse,
    api,
    supermemory,
    openviking,
    honcho,
    mem0,
    hindsight,
    retaindb,
    byterover,
    holographic,
    zep,
    falkordb,

    pub fn parse(raw: []const u8) !BackendKind {
        if (std.ascii.eqlIgnoreCase(raw, "none")) return .none;
        if (std.ascii.eqlIgnoreCase(raw, "native")) return .native;
        if (std.ascii.eqlIgnoreCase(raw, "sqlite")) return .native;
        if (std.ascii.eqlIgnoreCase(raw, "markdown")) return .markdown;
        if (std.ascii.eqlIgnoreCase(raw, "md")) return .markdown;
        if (std.ascii.eqlIgnoreCase(raw, "filesystem")) return .markdown;
        if (std.ascii.eqlIgnoreCase(raw, "memory")) return .memory_lru;
        if (std.ascii.eqlIgnoreCase(raw, "memory_lru")) return .memory_lru;
        if (std.ascii.eqlIgnoreCase(raw, "in_memory")) return .memory_lru;
        if (std.ascii.eqlIgnoreCase(raw, "redis")) return .redis;
        if (std.ascii.eqlIgnoreCase(raw, "clickhouse")) return .clickhouse;
        if (std.ascii.eqlIgnoreCase(raw, "api")) return .api;
        if (std.ascii.eqlIgnoreCase(raw, "http")) return .api;
        if (std.ascii.eqlIgnoreCase(raw, "nullpantry_api")) return .api;
        if (std.ascii.eqlIgnoreCase(raw, "supermemory")) return .supermemory;
        if (std.ascii.eqlIgnoreCase(raw, "supermemory_api")) return .supermemory;
        if (std.ascii.eqlIgnoreCase(raw, "openviking")) return .openviking;
        if (std.ascii.eqlIgnoreCase(raw, "openviking_api")) return .openviking;
        if (std.ascii.eqlIgnoreCase(raw, "honcho")) return .honcho;
        if (std.ascii.eqlIgnoreCase(raw, "honcho_api")) return .honcho;
        if (std.ascii.eqlIgnoreCase(raw, "mem0")) return .mem0;
        if (std.ascii.eqlIgnoreCase(raw, "mem0_api")) return .mem0;
        if (std.ascii.eqlIgnoreCase(raw, "hindsight")) return .hindsight;
        if (std.ascii.eqlIgnoreCase(raw, "hindsight_api")) return .hindsight;
        if (std.ascii.eqlIgnoreCase(raw, "retaindb")) return .retaindb;
        if (std.ascii.eqlIgnoreCase(raw, "retaindb_api")) return .retaindb;
        if (std.ascii.eqlIgnoreCase(raw, "retain_db")) return .retaindb;
        if (std.ascii.eqlIgnoreCase(raw, "byterover")) return .byterover;
        if (std.ascii.eqlIgnoreCase(raw, "byterover_cli")) return .byterover;
        if (std.ascii.eqlIgnoreCase(raw, "brv")) return .byterover;
        if (std.ascii.eqlIgnoreCase(raw, "holographic")) return .holographic;
        if (std.ascii.eqlIgnoreCase(raw, "holographic_sqlite")) return .holographic;
        if (std.ascii.eqlIgnoreCase(raw, "zep")) return .zep;
        if (std.ascii.eqlIgnoreCase(raw, "zep_api")) return .zep;
        if (std.ascii.eqlIgnoreCase(raw, "falkordb")) return .falkordb;
        if (std.ascii.eqlIgnoreCase(raw, "falkor")) return .falkordb;
        if (std.ascii.eqlIgnoreCase(raw, "falkordb_graph")) return .falkordb;
        return error.InvalidAgentMemoryBackend;
    }

    pub fn name(self: BackendKind) []const u8 {
        return switch (self) {
            .none => "none",
            .native => "native",
            .markdown => "markdown",
            .memory_lru => "memory_lru",
            .redis => "redis",
            .clickhouse => "clickhouse",
            .api => "api",
            .supermemory => "supermemory",
            .openviking => "openviking",
            .honcho => "honcho",
            .mem0 => "mem0",
            .hindsight => "hindsight",
            .retaindb => "retaindb",
            .byterover => "byterover",
            .holographic => "holographic",
            .zep => "zep",
            .falkordb => "falkordb",
        };
    }
};

pub const ApiProfile = enum {
    nullpantry,
    supermemory,
    openviking,
    honcho,
    mem0,
    hindsight,
    retaindb,
    byterover,
    zep,
    falkordb,

    pub fn parse(raw: []const u8) !ApiProfile {
        if (std.ascii.eqlIgnoreCase(raw, "nullpantry")) return .nullpantry;
        if (std.ascii.eqlIgnoreCase(raw, "nullpantry_api")) return .nullpantry;
        if (std.ascii.eqlIgnoreCase(raw, "api")) return .nullpantry;
        if (std.ascii.eqlIgnoreCase(raw, "supermemory")) return .supermemory;
        if (std.ascii.eqlIgnoreCase(raw, "supermemory_api")) return .supermemory;
        if (std.ascii.eqlIgnoreCase(raw, "openviking")) return .openviking;
        if (std.ascii.eqlIgnoreCase(raw, "openviking_api")) return .openviking;
        if (std.ascii.eqlIgnoreCase(raw, "honcho")) return .honcho;
        if (std.ascii.eqlIgnoreCase(raw, "honcho_api")) return .honcho;
        if (std.ascii.eqlIgnoreCase(raw, "mem0")) return .mem0;
        if (std.ascii.eqlIgnoreCase(raw, "mem0_api")) return .mem0;
        if (std.ascii.eqlIgnoreCase(raw, "hindsight")) return .hindsight;
        if (std.ascii.eqlIgnoreCase(raw, "hindsight_api")) return .hindsight;
        if (std.ascii.eqlIgnoreCase(raw, "retaindb")) return .retaindb;
        if (std.ascii.eqlIgnoreCase(raw, "retaindb_api")) return .retaindb;
        if (std.ascii.eqlIgnoreCase(raw, "retain_db")) return .retaindb;
        if (std.ascii.eqlIgnoreCase(raw, "byterover")) return .byterover;
        if (std.ascii.eqlIgnoreCase(raw, "byterover_cli")) return .byterover;
        if (std.ascii.eqlIgnoreCase(raw, "brv")) return .byterover;
        if (std.ascii.eqlIgnoreCase(raw, "zep")) return .zep;
        if (std.ascii.eqlIgnoreCase(raw, "zep_api")) return .zep;
        if (std.ascii.eqlIgnoreCase(raw, "falkordb")) return .falkordb;
        if (std.ascii.eqlIgnoreCase(raw, "falkor")) return .falkordb;
        if (std.ascii.eqlIgnoreCase(raw, "falkordb_graph")) return .falkordb;
        return error.InvalidAgentMemoryApiProfile;
    }

    pub fn name(self: ApiProfile) []const u8 {
        return switch (self) {
            .nullpantry => "nullpantry",
            .supermemory => "supermemory",
            .openviking => "openviking",
            .honcho => "honcho",
            .mem0 => "mem0",
            .hindsight => "hindsight",
            .retaindb => "retaindb",
            .byterover => "byterover",
            .zep => "zep",
            .falkordb => "falkordb",
        };
    }

    pub fn defaultBaseUrl(self: ApiProfile) ?[]const u8 {
        return switch (self) {
            .nullpantry => null,
            .supermemory => api_profiles.supermemory_default_base_url,
            .openviking => api_profiles.openviking_default_base_url,
            .honcho => api_profiles.honcho_default_base_url,
            .mem0 => api_profiles.mem0_default_base_url,
            .hindsight => api_profiles.hindsight_default_base_url,
            .retaindb => api_profiles.retaindb_default_base_url,
            .byterover => null,
            .zep => api_profiles.zep_default_base_url,
            .falkordb => api_profiles.falkordb_default_base_url,
        };
    }

    pub fn supportsNullPantryRuntimeApi(self: ApiProfile) bool {
        return self == .nullpantry;
    }

    pub fn authScheme(self: ApiProfile) ApiAuthScheme {
        return switch (self) {
            .openviking => .x_api_key,
            .mem0 => .token,
            else => .bearer,
        };
    }
};

pub const ApiAuthScheme = enum { bearer, x_api_key, token };

pub const MemoryConfig = struct {
    max_entries: usize = 4096,
    max_messages: usize = 4096,
    max_usage_entries: usize = 4096,
    max_bytes: usize = 0,
    ttl_seconds: ?u32 = null,
};

pub const MarkdownConfig = struct {
    workspace_dir: []const u8 = ".",
    max_file_bytes: usize = 1024 * 1024,
    default_scope: []const u8 = "public",
    permissions_json: []const u8 = "[\"public\"]",

    pub fn validateUsable(self: MarkdownConfig) !void {
        if (!nonEmptyString(self.workspace_dir)) return error.MissingMarkdownWorkspace;
        if (self.max_file_bytes == 0 or self.max_file_bytes > max_markdown_file_bytes) return error.InvalidAgentMemoryBackend;
        if (!nonEmptyString(self.default_scope)) return error.InvalidAgentMemoryBackend;
    }
};

pub fn boundedMarkdownFileBytes(value: ?i64, fallback: usize) usize {
    if (value) |raw| {
        return @max(@as(usize, 1), bounded_int.positiveI64ToUsizeBounded(raw, max_markdown_file_bytes));
    }
    return @max(@as(usize, 1), @min(fallback, max_markdown_file_bytes));
}

pub fn boundedRemoteTimeoutSecs(value: ?i64, fallback: u32) u32 {
    return runtime_limits.boundedTimeoutSecs(value, fallback);
}

pub fn boundedRemoteResponseBytes(value: ?i64, fallback: usize) usize {
    return runtime_limits.boundedResponseBytes(value, fallback);
}

pub const ApiConfig = struct {
    profile: ApiProfile = .nullpantry,
    base_url: ?[]const u8 = null,
    token: ?[]const u8 = null,
    remote_storage: ?[]const u8 = null,
    workspace_id: ?[]const u8 = null,
    actor_scopes_json: []const u8 = "[\"public\"]",
    actor_capabilities_json: []const u8 = "[\"read\"]",
    timeout_secs: u32 = 30,
    max_response_bytes: usize = 2 * 1024 * 1024,
    allow_insecure_http: bool = false,
    byterover_command: []const u8 = api_profiles.byterover_default_command,
    byterover_project_dir: ?[]const u8 = null,
    byterover_use_swarm: bool = false,
};

pub const ClickHouseConfig = struct {
    base_url: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    table: []const u8 = "nullpantry_agent_memory",
    timeout_secs: u32 = 30,
    allow_insecure_http: bool = false,
    max_response_bytes: usize = 8 * 1024 * 1024,

    pub fn enabled(self: ClickHouseConfig) bool {
        return nonEmptyOptional(self.base_url) and nonEmptyString(self.table);
    }
};

pub const Config = struct {
    backend: BackendKind = .native,
    memory: MemoryConfig = .{},
    markdown: MarkdownConfig = .{},
    redis: RedisConfig = .{},
    clickhouse: ClickHouseConfig = .{},
    api: ApiConfig = .{},
    holographic: HolographicConfig = .{},

    pub fn validateUsable(self: Config) !void {
        switch (self.backend) {
            .none, .native, .memory_lru, .redis, .holographic => {},
            .markdown => try self.markdown.validateUsable(),
            .clickhouse => {
                const base_url = self.clickhouse.base_url orelse return error.MissingClickHouseAgentMemoryUrl;
                if (!nonEmptyString(base_url)) return error.MissingClickHouseAgentMemoryUrl;
                try net_security.validateHttpBaseUrl(base_url, self.clickhouse.allow_insecure_http);
                if (self.clickhouse.api_key) |key| try net_security.validateHttpHeaderValue(key);
                if (!clickhouse_contracts.validTableName(self.clickhouse.table)) return error.InvalidAgentMemoryBackend;
                try validateRemoteRuntimeLimits(self.clickhouse.timeout_secs, self.clickhouse.max_response_bytes);
            },
            .api => {
                const base_url = self.api.base_url orelse return error.MissingApiBackendUrl;
                if (!nonEmptyString(base_url)) return error.MissingApiBackendUrl;
                try net_security.validateHttpBaseUrl(base_url, self.api.allow_insecure_http);
                try validateApiHeaderValues(self.api);
                try validateApiRuntimeLimits(self.api);
            },
            .supermemory, .openviking, .honcho, .mem0, .hindsight, .retaindb, .zep, .falkordb => {
                try validateApiHeaderValues(self.api);
                if (self.api.base_url) |base_url| {
                    if (!nonEmptyString(base_url)) return error.MissingApiBackendUrl;
                    try net_security.validateHttpBaseUrl(base_url, self.api.allow_insecure_http);
                }
                try validateApiRuntimeLimits(self.api);
            },
            .byterover => {
                if (!nonEmptyString(self.api.byterover_command)) return error.MissingByteRoverCommand;
                try validateApiRuntimeLimits(self.api);
            },
        }
    }
};

pub const NamedConfig = struct {
    name: []const u8,
    config: Config,
};

pub fn isValidNamedStoreName(name: []const u8) bool {
    if (name.len == 0 or isReservedStoreName(name)) return false;
    if (!std.ascii.isAlphanumeric(name[0])) return false;
    for (name[1..]) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-' or ch == '.' or ch == ':') continue;
        return false;
    }
    return true;
}

pub fn isReservedStoreName(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "primary") or
        std.ascii.eqlIgnoreCase(name, "default") or
        std.ascii.eqlIgnoreCase(name, "native") or
        std.ascii.eqlIgnoreCase(name, "canonical") or
        std.ascii.eqlIgnoreCase(name, "sqlite") or
        std.ascii.eqlIgnoreCase(name, "postgres") or
        std.ascii.eqlIgnoreCase(name, "runtime") or
        std.ascii.eqlIgnoreCase(name, "external") or
        std.ascii.eqlIgnoreCase(name, "none") or
        std.ascii.eqlIgnoreCase(name, "memory") or
        std.ascii.eqlIgnoreCase(name, "memory_lru") or
        std.ascii.eqlIgnoreCase(name, "in_memory") or
        std.ascii.eqlIgnoreCase(name, "redis") or
        std.ascii.eqlIgnoreCase(name, "clickhouse") or
        std.ascii.eqlIgnoreCase(name, "api") or
        std.ascii.eqlIgnoreCase(name, "http") or
        std.ascii.eqlIgnoreCase(name, "nullpantry_api") or
        std.ascii.eqlIgnoreCase(name, "zep") or
        std.ascii.eqlIgnoreCase(name, "zep_api") or
        std.ascii.eqlIgnoreCase(name, "falkordb") or
        std.ascii.eqlIgnoreCase(name, "falkor") or
        std.ascii.eqlIgnoreCase(name, "falkordb_graph") or
        std.ascii.eqlIgnoreCase(name, "kg") or
        std.ascii.eqlIgnoreCase(name, "all") or
        std.ascii.eqlIgnoreCase(name, "federated");
}

test "agent memory config validates named store names" {
    try std.testing.expect(!isValidNamedStoreName(""));
    try std.testing.expect(!isValidNamedStoreName("memory_lru"));
    try std.testing.expect(!isValidNamedStoreName("api"));
    try std.testing.expect(!isValidNamedStoreName("zep"));
    try std.testing.expect(!isValidNamedStoreName("falkordb"));
    try std.testing.expect(!isValidNamedStoreName("kg"));
    try std.testing.expect(!isValidNamedStoreName(".hidden"));
    try std.testing.expect(!isValidNamedStoreName("bad,name"));
    try std.testing.expect(isValidNamedStoreName("mem0"));
    try std.testing.expect(isValidNamedStoreName("team:alpha"));
    try std.testing.expect(isValidNamedStoreName("scratch-1.archive"));
}

fn nonEmptyOptional(value: ?[]const u8) bool {
    return if (value) |text| nonEmptyString(text) else false;
}

fn nonEmptyString(value: []const u8) bool {
    return std.mem.trim(u8, value, " \t\r\n").len > 0;
}

fn validateApiHeaderValues(config: ApiConfig) !void {
    if (config.token) |token| try net_security.validateHttpHeaderValue(token);
    try net_security.validateHttpHeaderValue(config.actor_scopes_json);
    try net_security.validateHttpHeaderValue(config.actor_capabilities_json);
    try validateApiActorAccess(config);
}

fn validateApiActorAccess(config: ApiConfig) !void {
    if (!json_string_array.itemsNonBlank(config.actor_scopes_json)) return error.InvalidAgentMemoryBackend;
    if (!json_string_array.itemsNonBlank(config.actor_capabilities_json)) return error.InvalidAgentMemoryBackend;
}

fn validateApiRuntimeLimits(config: ApiConfig) !void {
    try validateRemoteRuntimeLimits(config.timeout_secs, config.max_response_bytes);
}

fn validateRemoteRuntimeLimits(timeout_secs: u32, max_response_bytes: usize) !void {
    if (!runtime_limits.validTimeoutSecs(timeout_secs)) return error.InvalidAgentMemoryBackend;
    if (!runtime_limits.validResponseBytes(max_response_bytes)) return error.InvalidAgentMemoryBackend;
}

test "agent memory config parses backend names" {
    try std.testing.expectEqual(BackendKind.none, try BackendKind.parse("none"));
    try std.testing.expectEqual(BackendKind.native, try BackendKind.parse("native"));
    try std.testing.expectEqual(BackendKind.memory_lru, try BackendKind.parse("memory"));
    try std.testing.expectEqual(BackendKind.memory_lru, try BackendKind.parse("memory_lru"));
    try std.testing.expectEqual(BackendKind.redis, try BackendKind.parse("redis"));
    try std.testing.expectEqual(BackendKind.clickhouse, try BackendKind.parse("clickhouse"));
    try std.testing.expectEqual(BackendKind.api, try BackendKind.parse("api"));
    try std.testing.expectEqual(BackendKind.api, try BackendKind.parse("http"));
    try std.testing.expectEqual(BackendKind.supermemory, try BackendKind.parse("supermemory"));
    try std.testing.expectEqual(BackendKind.supermemory, try BackendKind.parse("supermemory_api"));
    try std.testing.expectEqual(BackendKind.openviking, try BackendKind.parse("openviking"));
    try std.testing.expectEqual(BackendKind.openviking, try BackendKind.parse("openviking_api"));
    try std.testing.expectEqual(BackendKind.honcho, try BackendKind.parse("honcho"));
    try std.testing.expectEqual(BackendKind.honcho, try BackendKind.parse("honcho_api"));
    try std.testing.expectEqual(BackendKind.mem0, try BackendKind.parse("mem0"));
    try std.testing.expectEqual(BackendKind.mem0, try BackendKind.parse("mem0_api"));
    try std.testing.expectEqual(BackendKind.hindsight, try BackendKind.parse("hindsight"));
    try std.testing.expectEqual(BackendKind.hindsight, try BackendKind.parse("hindsight_api"));
    try std.testing.expectEqual(BackendKind.retaindb, try BackendKind.parse("retaindb"));
    try std.testing.expectEqual(BackendKind.retaindb, try BackendKind.parse("retaindb_api"));
    try std.testing.expectEqual(BackendKind.retaindb, try BackendKind.parse("retain_db"));
    try std.testing.expectEqual(BackendKind.byterover, try BackendKind.parse("byterover"));
    try std.testing.expectEqual(BackendKind.byterover, try BackendKind.parse("byterover_cli"));
    try std.testing.expectEqual(BackendKind.byterover, try BackendKind.parse("brv"));
    try std.testing.expectEqual(BackendKind.holographic, try BackendKind.parse("holographic"));
    try std.testing.expectEqual(BackendKind.holographic, try BackendKind.parse("holographic_sqlite"));
    try std.testing.expectEqual(BackendKind.zep, try BackendKind.parse("zep"));
    try std.testing.expectEqual(BackendKind.zep, try BackendKind.parse("zep_api"));
    try std.testing.expectEqual(BackendKind.falkordb, try BackendKind.parse("falkordb"));
    try std.testing.expectEqual(BackendKind.falkordb, try BackendKind.parse("falkor"));
    try std.testing.expectEqual(BackendKind.falkordb, try BackendKind.parse("falkordb_graph"));
    try std.testing.expectEqual(BackendKind.native, try BackendKind.parse("sqlite"));
    try std.testing.expectError(error.InvalidAgentMemoryBackend, BackendKind.parse("unknown"));
}

test "agent memory config parses api profiles" {
    try std.testing.expectEqual(ApiProfile.supermemory, try ApiProfile.parse("supermemory"));
    try std.testing.expectEqual(ApiProfile.openviking, try ApiProfile.parse("openviking"));
    try std.testing.expectEqual(ApiProfile.honcho, try ApiProfile.parse("honcho"));
    try std.testing.expectEqual(ApiProfile.mem0, try ApiProfile.parse("mem0"));
    try std.testing.expectEqual(ApiProfile.hindsight, try ApiProfile.parse("hindsight"));
    try std.testing.expectEqual(ApiProfile.retaindb, try ApiProfile.parse("retaindb"));
    try std.testing.expectEqual(ApiProfile.retaindb, try ApiProfile.parse("retaindb_api"));
    try std.testing.expectEqual(ApiProfile.retaindb, try ApiProfile.parse("retain_db"));
    try std.testing.expectEqual(ApiProfile.byterover, try ApiProfile.parse("byterover"));
    try std.testing.expectEqual(ApiProfile.byterover, try ApiProfile.parse("byterover_cli"));
    try std.testing.expectEqual(ApiProfile.byterover, try ApiProfile.parse("brv"));
    try std.testing.expectEqual(ApiProfile.zep, try ApiProfile.parse("zep"));
    try std.testing.expectEqual(ApiProfile.zep, try ApiProfile.parse("zep_api"));
    try std.testing.expectEqual(ApiProfile.falkordb, try ApiProfile.parse("falkordb"));
    try std.testing.expectEqual(ApiProfile.falkordb, try ApiProfile.parse("falkor"));
    try std.testing.expectEqualStrings(api_profiles.zep_default_base_url, ApiProfile.zep.defaultBaseUrl().?);
    try std.testing.expectEqualStrings(api_profiles.falkordb_default_base_url, ApiProfile.falkordb.defaultBaseUrl().?);
    try std.testing.expectEqual(ApiAuthScheme.bearer, ApiProfile.supermemory.authScheme());
    try std.testing.expectEqual(ApiAuthScheme.x_api_key, ApiProfile.openviking.authScheme());
    try std.testing.expectEqual(ApiAuthScheme.token, ApiProfile.mem0.authScheme());
    try std.testing.expectError(error.InvalidAgentMemoryApiProfile, ApiProfile.parse("unknown"));
}

test "agent memory config validates usable backend setup" {
    try (Config{}).validateUsable();
    try (Config{ .backend = .none }).validateUsable();
    try (Config{ .backend = .markdown }).validateUsable();
    try std.testing.expectError(error.MissingMarkdownWorkspace, (Config{ .backend = .markdown, .markdown = .{ .workspace_dir = " " } }).validateUsable());
    try std.testing.expectError(error.InvalidAgentMemoryBackend, (Config{ .backend = .markdown, .markdown = .{ .max_file_bytes = 0 } }).validateUsable());
    try std.testing.expectError(error.InvalidAgentMemoryBackend, (Config{ .backend = .markdown, .markdown = .{ .max_file_bytes = max_markdown_file_bytes + 1 } }).validateUsable());
    try (Config{ .backend = .memory_lru }).validateUsable();
    try (Config{ .backend = .redis }).validateUsable();
    try (Config{ .backend = .holographic }).validateUsable();
    try (Config{ .backend = .byterover, .api = .{ .profile = .byterover } }).validateUsable();

    try std.testing.expectError(error.MissingApiBackendUrl, (Config{ .backend = .api }).validateUsable());
    try std.testing.expectError(error.MissingApiBackendUrl, (Config{ .backend = .api, .api = .{ .base_url = " " } }).validateUsable());
    try std.testing.expectError(error.InvalidRuntimeUrl, (Config{ .backend = .api, .api = .{ .base_url = "https://token@pantry.example/v1" } }).validateUsable());
    try std.testing.expectError(error.InsecureRuntimeUrl, (Config{ .backend = .api, .api = .{ .base_url = "http://pantry.internal:8765" } }).validateUsable());
    try std.testing.expectError(error.InvalidHttpHeaderValue, (Config{ .backend = .api, .api = .{ .base_url = "https://pantry.example/v1", .token = "bad\r\nX: y" } }).validateUsable());
    try std.testing.expectError(error.InvalidHttpHeaderValue, (Config{ .backend = .api, .api = .{ .base_url = "https://pantry.example/v1", .actor_scopes_json = "[\"public\"]\x7f" } }).validateUsable());
    try std.testing.expectError(error.InvalidAgentMemoryBackend, (Config{ .backend = .api, .api = .{ .base_url = "https://pantry.example/v1", .actor_scopes_json = "public" } }).validateUsable());
    try std.testing.expectError(error.InvalidAgentMemoryBackend, (Config{ .backend = .api, .api = .{ .base_url = "https://pantry.example/v1", .actor_scopes_json = "[\"public\",]" } }).validateUsable());
    try std.testing.expectError(error.InvalidAgentMemoryBackend, (Config{ .backend = .api, .api = .{ .base_url = "https://pantry.example/v1", .actor_scopes_json = "[\"\"]" } }).validateUsable());
    try std.testing.expectError(error.InvalidAgentMemoryBackend, (Config{ .backend = .api, .api = .{ .base_url = "https://pantry.example/v1", .actor_capabilities_json = "[1]" } }).validateUsable());
    try std.testing.expectError(error.InvalidAgentMemoryBackend, (Config{ .backend = .api, .api = .{ .base_url = "https://pantry.example/v1", .actor_capabilities_json = "[\"read\",\"  \"]" } }).validateUsable());
    try std.testing.expectError(error.InvalidAgentMemoryBackend, (Config{ .backend = .api, .api = .{ .base_url = "https://pantry.example/v1", .timeout_secs = 0 } }).validateUsable());
    try std.testing.expectError(error.InvalidAgentMemoryBackend, (Config{ .backend = .api, .api = .{ .base_url = "https://pantry.example/v1", .timeout_secs = max_remote_timeout_secs + 1 } }).validateUsable());
    try std.testing.expectError(error.InvalidAgentMemoryBackend, (Config{ .backend = .api, .api = .{ .base_url = "https://pantry.example/v1", .max_response_bytes = 0 } }).validateUsable());
    try std.testing.expectError(error.InvalidAgentMemoryBackend, (Config{ .backend = .api, .api = .{ .base_url = "https://pantry.example/v1", .max_response_bytes = max_remote_response_bytes + 1 } }).validateUsable());
    try (Config{ .backend = .api, .api = .{ .base_url = "https://pantry.example/v1" } }).validateUsable();
    try (Config{ .backend = .api, .api = .{ .base_url = "https://pantry.example/v1", .actor_scopes_json = "[\"public\",\"team:\\u0041\"]", .actor_capabilities_json = "[\"read\",\"write\"]" } }).validateUsable();
    try (Config{ .backend = .api, .api = .{ .base_url = "http://pantry.internal:8765", .allow_insecure_http = true } }).validateUsable();

    try std.testing.expectError(error.MissingClickHouseAgentMemoryUrl, (Config{ .backend = .clickhouse }).validateUsable());
    try std.testing.expectError(error.InvalidAgentMemoryBackend, (Config{ .backend = .clickhouse, .clickhouse = .{ .base_url = "https://clickhouse.example", .table = " " } }).validateUsable());
    try std.testing.expectError(error.InvalidAgentMemoryBackend, (Config{ .backend = .clickhouse, .clickhouse = .{ .base_url = "https://clickhouse.example", .table = "bad table" } }).validateUsable());
    try std.testing.expectError(error.InvalidAgentMemoryBackend, (Config{ .backend = .clickhouse, .clickhouse = .{ .base_url = "https://clickhouse.example", .table = ".agent_memory" } }).validateUsable());
    try std.testing.expectError(error.InvalidAgentMemoryBackend, (Config{ .backend = .clickhouse, .clickhouse = .{ .base_url = "https://clickhouse.example", .table = "np..agent_memory" } }).validateUsable());
    try std.testing.expectError(error.InvalidAgentMemoryBackend, (Config{ .backend = .clickhouse, .clickhouse = .{ .base_url = "https://clickhouse.example", .table = "agent_memory." } }).validateUsable());
    try std.testing.expectError(error.InvalidRuntimeUrl, (Config{ .backend = .clickhouse, .clickhouse = .{ .base_url = "https://clickhouse.example?token=x", .table = "agent_memory" } }).validateUsable());
    try std.testing.expectError(error.InsecureRuntimeUrl, (Config{ .backend = .clickhouse, .clickhouse = .{ .base_url = "http://clickhouse.internal:8123", .table = "agent_memory" } }).validateUsable());
    try std.testing.expectError(error.InvalidHttpHeaderValue, (Config{ .backend = .clickhouse, .clickhouse = .{ .base_url = "https://clickhouse.example", .api_key = "bad\tkey", .table = "agent_memory" } }).validateUsable());
    try std.testing.expectError(error.InvalidAgentMemoryBackend, (Config{ .backend = .clickhouse, .clickhouse = .{ .base_url = "https://clickhouse.example", .table = "agent_memory", .timeout_secs = 0 } }).validateUsable());
    try std.testing.expectError(error.InvalidAgentMemoryBackend, (Config{ .backend = .clickhouse, .clickhouse = .{ .base_url = "https://clickhouse.example", .table = "agent_memory", .max_response_bytes = max_remote_response_bytes + 1 } }).validateUsable());
    try (Config{ .backend = .clickhouse, .clickhouse = .{ .base_url = "https://clickhouse.example", .table = "agent_memory" } }).validateUsable();

    try (Config{ .backend = .supermemory }).validateUsable();
    try std.testing.expectError(error.InvalidAgentMemoryBackend, (Config{ .backend = .supermemory, .api = .{ .profile = .supermemory, .timeout_secs = 0 } }).validateUsable());
    try std.testing.expectError(error.InvalidHttpHeaderValue, (Config{ .backend = .supermemory, .api = .{ .profile = .supermemory, .token = "bad\r\nX: y" } }).validateUsable());
    try std.testing.expectError(error.MissingApiBackendUrl, (Config{ .backend = .supermemory, .api = .{ .profile = .supermemory, .base_url = " " } }).validateUsable());
    try std.testing.expectError(error.InvalidRuntimeUrl, (Config{ .backend = .supermemory, .api = .{ .profile = .supermemory, .base_url = "https://token@api.supermemory.ai" } }).validateUsable());
    try std.testing.expectError(error.InsecureRuntimeUrl, (Config{ .backend = .supermemory, .api = .{ .profile = .supermemory, .base_url = "http://supermemory.internal" } }).validateUsable());
    try (Config{ .backend = .zep, .api = .{ .profile = .zep } }).validateUsable();
    try std.testing.expectError(error.MissingApiBackendUrl, (Config{ .backend = .zep, .api = .{ .profile = .zep, .base_url = " " } }).validateUsable());
    try (Config{ .backend = .falkordb, .api = .{ .profile = .falkordb } }).validateUsable();
    try std.testing.expectError(error.MissingApiBackendUrl, (Config{ .backend = .falkordb, .api = .{ .profile = .falkordb, .base_url = " " } }).validateUsable());
    try std.testing.expectError(error.MissingByteRoverCommand, (Config{ .backend = .byterover, .api = .{ .profile = .byterover, .byterover_command = " " } }).validateUsable());
}

test "agent memory config bounds remote runtime limits" {
    try std.testing.expectEqual(@as(u32, 1), boundedRemoteTimeoutSecs(-1, 30));
    try std.testing.expectEqual(@as(u32, 1), boundedRemoteTimeoutSecs(0, 30));
    try std.testing.expectEqual(@as(u32, 42), boundedRemoteTimeoutSecs(42, 30));
    try std.testing.expectEqual(max_remote_timeout_secs, boundedRemoteTimeoutSecs(std.math.maxInt(i64), 30));
    try std.testing.expectEqual(max_remote_timeout_secs, boundedRemoteTimeoutSecs(null, max_remote_timeout_secs + 1));

    try std.testing.expectEqual(@as(usize, 1), boundedRemoteResponseBytes(-1, 4096));
    try std.testing.expectEqual(@as(usize, 1), boundedRemoteResponseBytes(0, 4096));
    try std.testing.expectEqual(@as(usize, 4096), boundedRemoteResponseBytes(4096, 8192));
    try std.testing.expectEqual(max_remote_response_bytes, boundedRemoteResponseBytes(std.math.maxInt(i64), 8192));
    try std.testing.expectEqual(max_remote_response_bytes, boundedRemoteResponseBytes(null, max_remote_response_bytes + 1));
}

test "agent memory config bounds markdown file sizes" {
    try std.testing.expectEqual(@as(usize, 1), boundedMarkdownFileBytes(-1, 1024));
    try std.testing.expectEqual(@as(usize, 1), boundedMarkdownFileBytes(0, 1024));
    try std.testing.expectEqual(@as(usize, 4096), boundedMarkdownFileBytes(4096, 1024));
    try std.testing.expectEqual(max_markdown_file_bytes, boundedMarkdownFileBytes(std.math.maxInt(i64), 1024));
    try std.testing.expectEqual(max_markdown_file_bytes, boundedMarkdownFileBytes(null, max_markdown_file_bytes + 1));
}
