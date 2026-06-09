const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat.zig");
const json = @import("json_util.zig");
const ids = @import("ids.zig");
const time_math = @import("time_math.zig");
const net_security = @import("net_security.zig");
const runtime_limits = @import("runtime_limits.zig");
const postgres_transport = @import("postgres.zig");
const circuit_breaker = @import("circuit_breaker.zig");

pub const max_vector_backend_response_bytes: usize = 8 * 1024 * 1024;
const external_vector_search_limit_max: usize = 1000;
const vector_setup_cache_size: usize = 16;
pub const default_sqlite_ann_candidate_multiplier: u32 = 12;
pub const default_sqlite_ann_min_candidates: u32 = 64;
pub const max_sqlite_ann_candidate_multiplier: u32 = 10_000;
pub const max_sqlite_ann_min_candidates: u32 = 1_000_000;

pub fn externalVectorSearchLimit(limit: usize) usize {
    return @max(@as(usize, 1), @min(limit, external_vector_search_limit_max));
}

pub const BackendKind = enum {
    local,
    pgvector,
    qdrant,
    lancedb,
    lancedb_http,
    weaviate,
    chroma,
    opensearch,

    pub fn parse(raw: []const u8) !BackendKind {
        if (std.ascii.eqlIgnoreCase(raw, "local")) return .local;
        if (std.ascii.eqlIgnoreCase(raw, "pgvector")) return .pgvector;
        if (std.ascii.eqlIgnoreCase(raw, "postgres-vector")) return .pgvector;
        if (std.ascii.eqlIgnoreCase(raw, "qdrant")) return .qdrant;
        if (std.ascii.eqlIgnoreCase(raw, "lancedb")) return .lancedb;
        if (std.ascii.eqlIgnoreCase(raw, "lancedb_http")) return .lancedb_http;
        if (std.ascii.eqlIgnoreCase(raw, "lancedb-http")) return .lancedb_http;
        if (std.ascii.eqlIgnoreCase(raw, "lancedb-compatible")) return .lancedb_http;
        if (std.ascii.eqlIgnoreCase(raw, "weaviate")) return .weaviate;
        if (std.ascii.eqlIgnoreCase(raw, "chroma")) return .chroma;
        if (std.ascii.eqlIgnoreCase(raw, "opensearch")) return .opensearch;
        if (std.ascii.eqlIgnoreCase(raw, "open_search")) return .opensearch;
        return error.InvalidVectorBackend;
    }

    pub fn name(self: BackendKind) []const u8 {
        return switch (self) {
            .local => "local",
            .pgvector => "pgvector",
            .qdrant => "qdrant",
            .lancedb => "lancedb",
            .lancedb_http => "lancedb_http",
            .weaviate => "weaviate",
            .chroma => "chroma",
            .opensearch => "opensearch",
        };
    }
};

pub const Config = struct {
    backend: BackendKind = .local,
    base_url: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    api_key_header: []const u8 = "",
    collection: []const u8 = "nullpantry_vectors",
    chroma_tenant: []const u8 = "default_tenant",
    chroma_database: []const u8 = "default_database",
    postgres_url: ?[]const u8 = null,
    lancedb_uri: ?[]const u8 = null,
    lancedb_command: []const u8 = "python3",
    timeout_secs: u32 = 30,
    allow_insecure_http: bool = false,
    circuit_breaker_enabled: bool = true,
    circuit_breaker_threshold: u32 = 3,
    circuit_breaker_cooldown_ms: u64 = 30_000,
    sqlite_ann_candidate_multiplier: u32 = default_sqlite_ann_candidate_multiplier,
    sqlite_ann_min_candidates: u32 = default_sqlite_ann_min_candidates,

    pub fn externalEnabled(self: Config) bool {
        if (!nonEmptyString(self.collection)) return false;
        return switch (self.backend) {
            .local => false,
            .pgvector => nonEmptyOptional(self.postgres_url),
            .qdrant, .lancedb_http, .weaviate, .opensearch => nonEmptyOptional(self.base_url),
            .chroma => nonEmptyOptional(self.base_url) and nonEmptyString(self.chroma_tenant) and nonEmptyString(self.chroma_database),
            .lancedb => nonEmptyOptional(self.lancedb_uri) and nonEmptyString(self.lancedb_command),
        };
    }

    pub fn validateUsable(self: Config) !void {
        if (self.api_key_header.len > 0) try net_security.validateHttpHeaderName(self.api_key_header);
        if (self.api_key) |key| try net_security.validateHttpHeaderValue(key);
        if (self.backend == .local) return;
        if (!runtime_limits.validTimeoutSecs(self.timeout_secs)) return error.InvalidVectorBackend;
        if (!circuit_breaker.validFailureThreshold(self.circuit_breaker_threshold)) return error.InvalidVectorBackend;
        if (!circuit_breaker.validCooldownMsU64(self.circuit_breaker_cooldown_ms)) return error.InvalidVectorBackend;
        if (!nonEmptyString(self.collection)) return error.InvalidVectorBackend;
        return switch (self.backend) {
            .local => {},
            .pgvector => {
                _ = self.postgres_url orelse return error.InvalidVectorBackend;
                if (!nonEmptyString(self.postgres_url.?)) return error.InvalidVectorBackend;
                _ = try pgvectorTableName(self);
            },
            .qdrant, .lancedb_http, .weaviate, .chroma, .opensearch => {
                const base_url = self.base_url orelse return error.InvalidVectorBackend;
                if (!nonEmptyString(base_url)) return error.InvalidVectorBackend;
                try net_security.validateHttpBaseUrl(base_url, self.allow_insecure_http);
                if (self.backend == .weaviate) try validateWeaviateCollectionName(self.collection);
                if (self.backend == .opensearch) try validateOpenSearchIndexName(self.collection);
                if (self.backend == .chroma) {
                    if (!nonEmptyString(self.chroma_tenant) or !nonEmptyString(self.chroma_database)) return error.InvalidVectorBackend;
                }
            },
            .lancedb => {
                if (!nonEmptyOptional(self.lancedb_uri)) return error.InvalidVectorBackend;
                if (!nonEmptyString(self.lancedb_command)) return error.InvalidVectorBackend;
            },
        };
    }

    pub fn sqliteAnnCandidateMultiplier(self: Config) u32 {
        return normalizeSqliteAnnCandidateMultiplier(self.sqlite_ann_candidate_multiplier);
    }

    pub fn sqliteAnnMinCandidates(self: Config) u32 {
        return normalizeSqliteAnnMinCandidates(self.sqlite_ann_min_candidates);
    }
};

fn nonEmptyOptional(value: ?[]const u8) bool {
    return if (value) |text| nonEmptyString(text) else false;
}

fn nonEmptyString(value: []const u8) bool {
    return std.mem.trim(u8, value, " \t\r\n").len > 0;
}

pub const NamedConfig = struct {
    name: []const u8,
    config: Config,
};

pub const NamedRuntime = struct {
    name: []const u8,
    config: Config,
    runtime: Runtime,
};

pub const RuntimeRegistry = struct {
    allocator: std.mem.Allocator,
    stores: std.ArrayListUnmanaged(NamedRuntime) = .empty,

    pub fn init(allocator: std.mem.Allocator, configs: []const NamedConfig) !RuntimeRegistry {
        var registry = RuntimeRegistry{ .allocator = allocator };
        errdefer registry.deinit();
        for (configs) |config| {
            const name = std.mem.trim(u8, config.name, " \t\r\n");
            if (!isValidNamedStoreName(name)) return error.InvalidVectorStoreName;
            try config.config.validateUsable();
            if (!config.config.externalEnabled()) return error.InvalidVectorStoreBackend;
            if (registry.get(name) != null) return error.DuplicateVectorStoreName;
            const owned_name = try allocator.dupe(u8, name);
            errdefer allocator.free(owned_name);
            try registry.stores.append(allocator, .{
                .name = owned_name,
                .config = config.config,
                .runtime = try Runtime.init(config.config),
            });
        }
        return registry;
    }

    pub fn deinit(self: *RuntimeRegistry) void {
        const allocator = self.allocator;
        for (self.stores.items) |*store| {
            allocator.free(store.name);
            store.runtime.deinit();
        }
        self.stores.deinit(allocator);
        self.* = .{ .allocator = allocator };
    }

    pub fn get(self: *RuntimeRegistry, name: []const u8) ?*NamedRuntime {
        for (self.stores.items) |*store| {
            if (std.mem.eql(u8, store.name, name)) return store;
        }
        return null;
    }

    pub fn count(self: *const RuntimeRegistry) usize {
        return self.stores.items.len;
    }

    pub fn externalEnabled(self: *const RuntimeRegistry) bool {
        for (self.stores.items) |store| {
            if (store.config.externalEnabled()) return true;
        }
        return false;
    }
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
        std.ascii.eqlIgnoreCase(name, "local");
}

pub fn normalizeSqliteAnnCandidateMultiplier(value: u32) u32 {
    return @max(@as(u32, 1), @min(value, max_sqlite_ann_candidate_multiplier));
}

pub fn normalizeSqliteAnnMinCandidates(value: u32) u32 {
    return @max(@as(u32, 1), @min(value, max_sqlite_ann_min_candidates));
}

fn cooldownMsForCircuit(value: u64) i64 {
    const max_cooldown: u64 = @intCast(std.math.maxInt(i64));
    return @intCast(@min(value, max_cooldown));
}

pub const CircuitState = circuit_breaker.State;

pub const CircuitBreaker = struct {
    circuit: circuit_breaker.Runtime = .{},

    pub fn init(cfg: Config) CircuitBreaker {
        return .{
            .circuit = circuit_breaker.Runtime.init(.{
                .enabled = cfg.circuit_breaker_enabled,
                .failure_threshold = cfg.circuit_breaker_threshold,
                .cooldown_ms = cooldownMsForCircuit(cfg.circuit_breaker_cooldown_ms),
            }),
        };
    }

    pub fn allow(self: *CircuitBreaker) bool {
        return self.circuit.allowAt(ids.nowMs());
    }

    pub fn recordSuccess(self: *CircuitBreaker) void {
        self.circuit.recordSuccess();
    }

    pub fn recordFailure(self: *CircuitBreaker) void {
        self.circuit.recordFailureAt(ids.nowMs());
    }
};

pub const Runtime = struct {
    mutex: std.Io.Mutex = .init,
    pgvector_transport_mutex: std.Io.Mutex = .init,
    circuit_breaker: CircuitBreaker = .{},
    pgvector_transport: ?postgres_transport.QueryTransport = null,
    pgvector_url_hash: u64 = 0,
    pgvector_schema_hashes: [vector_setup_cache_size]u64 = [_]u64{0} ** vector_setup_cache_size,
    pgvector_schema_next_slot: usize = 0,
    qdrant_collection_hashes: [vector_setup_cache_size]u64 = [_]u64{0} ** vector_setup_cache_size,
    qdrant_collection_next_slot: usize = 0,

    pub fn init(cfg: Config) !Runtime {
        try cfg.validateUsable();
        return .{ .circuit_breaker = CircuitBreaker.init(cfg) };
    }

    pub fn deinit(self: *Runtime) void {
        self.pgvector_transport_mutex.lockUncancelable(compat.io());
        defer self.pgvector_transport_mutex.unlock(compat.io());
        self.mutex.lockUncancelable(compat.io());
        defer self.mutex.unlock(compat.io());
        if (self.pgvector_transport) |*transport| transport.deinit();
        self.pgvector_transport = null;
        self.pgvector_url_hash = 0;
        self.clearPgvectorSchemaCache();
        self.clearQdrantCollectionCache();
    }

    pub fn allow(self: *Runtime) bool {
        self.mutex.lockUncancelable(compat.io());
        defer self.mutex.unlock(compat.io());
        return self.allowUnlocked();
    }

    pub fn recordSuccess(self: *Runtime) void {
        self.mutex.lockUncancelable(compat.io());
        defer self.mutex.unlock(compat.io());
        self.recordSuccessUnlocked();
    }

    pub fn recordFailure(self: *Runtime) void {
        self.mutex.lockUncancelable(compat.io());
        defer self.mutex.unlock(compat.io());
        self.recordFailureUnlocked();
    }

    pub fn stateName(self: *Runtime) []const u8 {
        self.mutex.lockUncancelable(compat.io());
        defer self.mutex.unlock(compat.io());
        return self.circuit_breaker.circuit.state.name();
    }

    fn allowUnlocked(self: *Runtime) bool {
        return self.circuit_breaker.allow();
    }

    fn recordSuccessUnlocked(self: *Runtime) void {
        self.circuit_breaker.recordSuccess();
    }

    fn recordFailureUnlocked(self: *Runtime) void {
        self.circuit_breaker.recordFailure();
    }

    fn pgvectorTransport(self: *Runtime, allocator: std.mem.Allocator, cfg: Config) !*postgres_transport.QueryTransport {
        self.mutex.lockUncancelable(compat.io());
        defer self.mutex.unlock(compat.io());
        const raw_url = cfg.postgres_url orelse return error.VectorBackendUnavailable;
        const url_hash = std.hash.Wyhash.hash(0, raw_url);
        if (self.pgvector_transport) |*transport| {
            if (self.pgvector_url_hash == url_hash) return transport;
            transport.deinit();
            self.pgvector_transport = null;
            self.pgvector_url_hash = 0;
            self.clearPgvectorSchemaCache();
        }

        const url = try postgres_transport.withConnectTimeout(allocator, raw_url);
        defer allocator.free(url);
        self.pgvector_transport = try postgres_transport.QueryTransport.init(allocator, url);
        self.pgvector_url_hash = url_hash;
        return &self.pgvector_transport.?;
    }

    fn pgvectorSchemaCachedLocked(self: *Runtime, cfg: Config, table: []const u8, dimensions: i64) bool {
        self.mutex.lockUncancelable(compat.io());
        defer self.mutex.unlock(compat.io());
        return self.pgvectorSchemaCached(cfg, table, dimensions);
    }

    fn pgvectorSchemaCached(self: *Runtime, cfg: Config, table: []const u8, dimensions: i64) bool {
        const key = pgvectorSchemaKey(cfg, table, dimensions);
        for (self.pgvector_schema_hashes) |cached| {
            if (cached == key) return true;
        }
        return false;
    }

    fn rememberPgvectorSchemaLocked(self: *Runtime, cfg: Config, table: []const u8, dimensions: i64) void {
        self.mutex.lockUncancelable(compat.io());
        defer self.mutex.unlock(compat.io());
        self.rememberPgvectorSchema(cfg, table, dimensions);
    }

    fn rememberPgvectorSchema(self: *Runtime, cfg: Config, table: []const u8, dimensions: i64) void {
        self.pgvector_schema_hashes[self.pgvector_schema_next_slot] = pgvectorSchemaKey(cfg, table, dimensions);
        self.pgvector_schema_next_slot = (self.pgvector_schema_next_slot + 1) % vector_setup_cache_size;
    }

    fn clearPgvectorSchemaCacheLocked(self: *Runtime) void {
        self.mutex.lockUncancelable(compat.io());
        defer self.mutex.unlock(compat.io());
        self.clearPgvectorSchemaCache();
    }

    fn clearPgvectorSchemaCache(self: *Runtime) void {
        @memset(self.pgvector_schema_hashes[0..], 0);
        self.pgvector_schema_next_slot = 0;
    }

    fn qdrantCollectionCachedLocked(self: *Runtime, cfg: Config, dimensions: i64) bool {
        self.mutex.lockUncancelable(compat.io());
        defer self.mutex.unlock(compat.io());
        return self.qdrantCollectionCached(cfg, dimensions);
    }

    fn qdrantCollectionCached(self: *Runtime, cfg: Config, dimensions: i64) bool {
        const key = qdrantCollectionKey(cfg, dimensions);
        for (self.qdrant_collection_hashes) |cached| {
            if (cached == key) return true;
        }
        return false;
    }

    fn rememberQdrantCollectionLocked(self: *Runtime, cfg: Config, dimensions: i64) void {
        self.mutex.lockUncancelable(compat.io());
        defer self.mutex.unlock(compat.io());
        self.rememberQdrantCollection(cfg, dimensions);
    }

    fn rememberQdrantCollection(self: *Runtime, cfg: Config, dimensions: i64) void {
        self.qdrant_collection_hashes[self.qdrant_collection_next_slot] = qdrantCollectionKey(cfg, dimensions);
        self.qdrant_collection_next_slot = (self.qdrant_collection_next_slot + 1) % vector_setup_cache_size;
    }

    fn clearQdrantCollectionCacheLocked(self: *Runtime) void {
        self.mutex.lockUncancelable(compat.io());
        defer self.mutex.unlock(compat.io());
        self.clearQdrantCollectionCache();
    }

    fn clearQdrantCollectionCache(self: *Runtime) void {
        @memset(self.qdrant_collection_hashes[0..], 0);
        self.qdrant_collection_next_slot = 0;
    }
};

pub const UpsertInput = struct {
    id: []const u8,
    object_type: []const u8,
    object_id: []const u8,
    chunk_ordinal: i64,
    text: []const u8,
    scope: []const u8,
    permissions_json: []const u8,
    heading_path_json: []const u8 = "[]",
    start_byte: i64 = 0,
    end_byte: i64 = 0,
    content_hash: []const u8 = "",
    chunk_strategy: []const u8 = "plain",
    estimated_tokens: i64 = 0,
    transcript_timestamp: ?[]const u8 = null,
    transcript_speaker: ?[]const u8 = null,
    embedding_json: []const u8,
    model: ?[]const u8,
    dimensions: i64,
};

pub const Candidate = struct {
    vector_id: []const u8,
    score: f32,
};

const VectorHttpResponse = struct {
    status: std.http.Status,
    body: []u8,
};

pub fn freeCandidates(allocator: std.mem.Allocator, candidates: []Candidate) void {
    for (candidates) |candidate| allocator.free(candidate.vector_id);
    allocator.free(candidates);
}

pub fn upsert(allocator: std.mem.Allocator, cfg: Config, input: UpsertInput) !void {
    try cfg.validateUsable();
    if (!cfg.externalEnabled()) return;
    try validateUpsertInput(allocator, input);
    return switch (cfg.backend) {
        .local => {},
        .pgvector => try pgvectorUpsert(allocator, cfg, null, input),
        .qdrant => try qdrantUpsert(allocator, cfg, null, input),
        .lancedb => try lancedbSdkUpsert(allocator, cfg, input),
        .lancedb_http => try lancedbHttpUpsert(allocator, cfg, input),
        .weaviate => try weaviateUpsert(allocator, cfg, input),
        .chroma => try chromaUpsert(allocator, cfg, input),
        .opensearch => try opensearchUpsert(allocator, cfg, input),
    };
}

pub fn upsertWithRuntime(allocator: std.mem.Allocator, cfg: Config, runtime: ?*Runtime, input: UpsertInput) !void {
    try cfg.validateUsable();
    if (!cfg.externalEnabled()) return;
    try validateUpsertInput(allocator, input);
    try validateBackendConfig(cfg);
    if (runtime) |rt| {
        if (!rt.allow()) return error.VectorBackendCircuitOpen;
        upsertWithRuntimeTransport(allocator, cfg, rt, input) catch |err| {
            rt.recordFailure();
            return err;
        };
        rt.recordSuccess();
        return;
    }
    return upsert(allocator, cfg, input);
}

fn upsertWithRuntimeTransport(allocator: std.mem.Allocator, cfg: Config, runtime: *Runtime, input: UpsertInput) !void {
    return switch (cfg.backend) {
        .pgvector => try pgvectorUpsert(allocator, cfg, runtime, input),
        .qdrant => try qdrantUpsert(allocator, cfg, runtime, input),
        else => try upsert(allocator, cfg, input),
    };
}

pub fn search(allocator: std.mem.Allocator, cfg: Config, embedding_json: []const u8, limit: usize) ![]Candidate {
    try cfg.validateUsable();
    if (!cfg.externalEnabled()) return allocator.alloc(Candidate, 0);
    if (limit == 0) return allocator.alloc(Candidate, 0);
    try validateSearchInput(allocator, embedding_json);
    return switch (cfg.backend) {
        .local => allocator.alloc(Candidate, 0),
        .pgvector => pgvectorSearch(allocator, cfg, null, embedding_json, limit),
        .qdrant => qdrantSearch(allocator, cfg, embedding_json, limit),
        .lancedb => lancedbSdkSearch(allocator, cfg, embedding_json, limit),
        .lancedb_http => lancedbHttpSearch(allocator, cfg, embedding_json, limit),
        .weaviate => weaviateSearch(allocator, cfg, embedding_json, limit),
        .chroma => chromaSearch(allocator, cfg, embedding_json, limit),
        .opensearch => opensearchSearch(allocator, cfg, embedding_json, limit),
    };
}

pub fn searchWithRuntime(allocator: std.mem.Allocator, cfg: Config, runtime: ?*Runtime, embedding_json: []const u8, limit: usize) ![]Candidate {
    try cfg.validateUsable();
    if (!cfg.externalEnabled()) return allocator.alloc(Candidate, 0);
    if (limit == 0) return allocator.alloc(Candidate, 0);
    try validateSearchInput(allocator, embedding_json);
    try validateBackendConfig(cfg);
    if (runtime) |rt| {
        if (!rt.allow()) return error.VectorBackendCircuitOpen;
        const candidates = searchWithRuntimeTransport(allocator, cfg, rt, embedding_json, limit) catch |err| {
            rt.recordFailure();
            return err;
        };
        rt.recordSuccess();
        return candidates;
    }
    return search(allocator, cfg, embedding_json, limit);
}

fn searchWithRuntimeTransport(allocator: std.mem.Allocator, cfg: Config, runtime: *Runtime, embedding_json: []const u8, limit: usize) ![]Candidate {
    return switch (cfg.backend) {
        .pgvector => pgvectorSearch(allocator, cfg, runtime, embedding_json, limit),
        else => search(allocator, cfg, embedding_json, limit),
    };
}

pub fn delete(allocator: std.mem.Allocator, cfg: Config, vector_id: []const u8) !void {
    try cfg.validateUsable();
    if (!cfg.externalEnabled()) return;
    try validateVectorId(vector_id);
    return switch (cfg.backend) {
        .local => {},
        .pgvector => try pgvectorDelete(allocator, cfg, null, vector_id),
        .qdrant => try qdrantDelete(allocator, cfg, vector_id),
        .lancedb => try lancedbSdkDelete(allocator, cfg, vector_id),
        .lancedb_http => try lancedbHttpDelete(allocator, cfg, vector_id),
        .weaviate => try weaviateDelete(allocator, cfg, vector_id),
        .chroma => try chromaDelete(allocator, cfg, vector_id),
        .opensearch => try opensearchDelete(allocator, cfg, vector_id),
    };
}

pub fn deleteWithRuntime(allocator: std.mem.Allocator, cfg: Config, runtime: ?*Runtime, vector_id: []const u8) !void {
    try cfg.validateUsable();
    if (!cfg.externalEnabled()) return;
    try validateVectorId(vector_id);
    try validateBackendConfig(cfg);
    if (runtime) |rt| {
        if (!rt.allow()) return error.VectorBackendCircuitOpen;
        deleteWithRuntimeTransport(allocator, cfg, rt, vector_id) catch |err| {
            rt.recordFailure();
            return err;
        };
        rt.recordSuccess();
        return;
    }
    return delete(allocator, cfg, vector_id);
}

fn deleteWithRuntimeTransport(allocator: std.mem.Allocator, cfg: Config, runtime: *Runtime, vector_id: []const u8) !void {
    return switch (cfg.backend) {
        .pgvector => try pgvectorDelete(allocator, cfg, runtime, vector_id),
        else => try delete(allocator, cfg, vector_id),
    };
}

pub fn reset(allocator: std.mem.Allocator, cfg: Config) !void {
    try cfg.validateUsable();
    if (!cfg.externalEnabled()) return;
    return switch (cfg.backend) {
        .local => {},
        .pgvector => try pgvectorReset(allocator, cfg, null),
        .qdrant => try qdrantReset(allocator, cfg, null),
        .lancedb => try lancedbSdkReset(allocator, cfg),
        .lancedb_http => try lancedbHttpReset(allocator, cfg),
        .weaviate => try weaviateReset(allocator, cfg),
        .chroma => try chromaReset(allocator, cfg),
        .opensearch => try opensearchReset(allocator, cfg),
    };
}

pub fn resetWithRuntime(allocator: std.mem.Allocator, cfg: Config, runtime: ?*Runtime) !void {
    try cfg.validateUsable();
    if (!cfg.externalEnabled()) return;
    try validateBackendConfig(cfg);
    if (runtime) |rt| {
        if (!rt.allow()) return error.VectorBackendCircuitOpen;
        resetWithRuntimeTransport(allocator, cfg, rt) catch |err| {
            rt.recordFailure();
            return err;
        };
        rt.recordSuccess();
        return;
    }
    return reset(allocator, cfg);
}

fn resetWithRuntimeTransport(allocator: std.mem.Allocator, cfg: Config, runtime: *Runtime) !void {
    return switch (cfg.backend) {
        .pgvector => try pgvectorReset(allocator, cfg, runtime),
        .qdrant => try qdrantReset(allocator, cfg, runtime),
        else => try reset(allocator, cfg),
    };
}

fn qdrantUpsert(allocator: std.mem.Allocator, cfg: Config, runtime: ?*Runtime, input: UpsertInput) !void {
    try qdrantEnsureCollection(allocator, cfg, runtime, input.dimensions);
    const path = try qdrantCollectionPath(allocator, cfg, "/points?wait=true");
    defer allocator.free(path);
    const url = try backendUrl(allocator, cfg, path);
    defer allocator.free(url);
    const payload = try qdrantUpsertPayload(allocator, input);
    defer allocator.free(payload);
    const response = try requestJson(allocator, .PUT, url, cfg, payload);
    defer allocator.free(response);
    try ensureBackendOk(allocator, response);
}

fn pgvectorUpsert(allocator: std.mem.Allocator, cfg: Config, runtime: ?*Runtime, input: UpsertInput) !void {
    try pgvectorEnsureSchema(allocator, cfg, runtime, input.dimensions);
    const table = try pgvectorTableName(cfg);
    const now_text = try std.fmt.allocPrint(allocator, "{d}", .{ids.nowMs()});
    defer allocator.free(now_text);
    const chunk_ordinal = try std.fmt.allocPrint(allocator, "{d}", .{input.chunk_ordinal});
    defer allocator.free(chunk_ordinal);
    const dimensions = try std.fmt.allocPrint(allocator, "{d}", .{input.dimensions});
    defer allocator.free(dimensions);
    const start_byte = try std.fmt.allocPrint(allocator, "{d}", .{input.start_byte});
    defer allocator.free(start_byte);
    const end_byte = try std.fmt.allocPrint(allocator, "{d}", .{input.end_byte});
    defer allocator.free(end_byte);
    const estimated_tokens = try std.fmt.allocPrint(allocator, "{d}", .{input.estimated_tokens});
    defer allocator.free(estimated_tokens);
    const sql = try std.fmt.allocPrint(
        allocator,
        "INSERT INTO {s} (id,vector_id,embedding,object_type,object_id,chunk_ordinal,text,scope,permissions_json,heading_path_json,start_byte,end_byte,content_hash,chunk_strategy,estimated_tokens,transcript_timestamp,transcript_speaker,model,dimensions,updated_at_ms) " ++
            "VALUES ($1,$1,$2::vector,$3,$4,$5::bigint,$6,$7,$8::jsonb,$9::jsonb,$10::bigint,$11::bigint,$12,$13,$14::bigint,$15,$16,$17,$18::bigint,$19::bigint) " ++
            "ON CONFLICT(id) DO UPDATE SET vector_id=excluded.vector_id, embedding=excluded.embedding, object_type=excluded.object_type, object_id=excluded.object_id, chunk_ordinal=excluded.chunk_ordinal, text=excluded.text, scope=excluded.scope, permissions_json=excluded.permissions_json, heading_path_json=excluded.heading_path_json, start_byte=excluded.start_byte, end_byte=excluded.end_byte, content_hash=excluded.content_hash, chunk_strategy=excluded.chunk_strategy, estimated_tokens=excluded.estimated_tokens, transcript_timestamp=excluded.transcript_timestamp, transcript_speaker=excluded.transcript_speaker, model=excluded.model, dimensions=excluded.dimensions, updated_at_ms=excluded.updated_at_ms",
        .{table},
    );
    defer allocator.free(sql);
    try pgvectorRunParams(allocator, cfg, runtime, sql, &.{
        input.id,
        input.embedding_json,
        input.object_type,
        input.object_id,
        chunk_ordinal,
        input.text,
        input.scope,
        input.permissions_json,
        input.heading_path_json,
        start_byte,
        end_byte,
        input.content_hash,
        input.chunk_strategy,
        estimated_tokens,
        input.transcript_timestamp,
        input.transcript_speaker,
        input.model,
        dimensions,
        now_text,
    });
}

fn pgvectorSearch(allocator: std.mem.Allocator, cfg: Config, runtime: ?*Runtime, embedding_json: []const u8, limit: usize) ![]Candidate {
    const dimensions = try embeddingDimensionsFromJson(allocator, embedding_json);
    if (dimensions == 0 or limit == 0) return allocator.alloc(Candidate, 0);
    try pgvectorEnsureSchema(allocator, cfg, runtime, @intCast(dimensions));
    const table = try pgvectorTableName(cfg);
    const dimensions_text = try std.fmt.allocPrint(allocator, "{d}", .{dimensions});
    defer allocator.free(dimensions_text);
    const limit_text = try std.fmt.allocPrint(allocator, "{d}", .{externalVectorSearchLimit(limit)});
    defer allocator.free(limit_text);
    const sql = try std.fmt.allocPrint(
        allocator,
        "SELECT jsonb_build_object('matches', COALESCE(jsonb_agg(jsonb_build_object('id', t.id, 'vector_id', t.vector_id, 'score', t.score)), '[]'::jsonb))::text " ++
            "FROM (SELECT id, vector_id, GREATEST(0, LEAST(1, 1 - ((embedding::vector({d})) <=> ($1::vector({d}))))) AS score " ++
            "FROM {s} WHERE dimensions = $2::bigint ORDER BY (embedding::vector({d})) <=> ($1::vector({d})) LIMIT $3::bigint) t",
        .{ dimensions, dimensions, table, dimensions, dimensions },
    );
    defer allocator.free(sql);
    const response = try pgvectorQueryParams(allocator, cfg, runtime, sql, &.{ embedding_json, dimensions_text, limit_text });
    defer allocator.free(response);
    return parseCandidates(allocator, response);
}

fn pgvectorDelete(allocator: std.mem.Allocator, cfg: Config, runtime: ?*Runtime, vector_id: []const u8) !void {
    try validateVectorId(vector_id);
    const table = try pgvectorTableName(cfg);
    const sql = try std.fmt.allocPrint(allocator, "DELETE FROM {s} WHERE id = $1 OR vector_id = $1", .{table});
    defer allocator.free(sql);
    try pgvectorRunParams(allocator, cfg, runtime, sql, &.{vector_id});
}

fn pgvectorReset(allocator: std.mem.Allocator, cfg: Config, runtime: ?*Runtime) !void {
    const table = try pgvectorTableName(cfg);
    const sql = try std.fmt.allocPrint(allocator, "DROP TABLE IF EXISTS {s}", .{table});
    defer allocator.free(sql);
    try pgvectorRunParams(allocator, cfg, runtime, sql, &.{});
    if (runtime) |rt| rt.clearPgvectorSchemaCacheLocked();
}

fn pgvectorEnsureSchema(allocator: std.mem.Allocator, cfg: Config, runtime: ?*Runtime, dimensions: i64) !void {
    if (dimensions <= 0) return error.InvalidVectorDimensions;
    const table = try pgvectorTableName(cfg);
    if (runtime) |rt| {
        if (rt.pgvectorSchemaCachedLocked(cfg, table, dimensions)) return;
    }
    const sql = try std.fmt.allocPrint(allocator,
        \\CREATE EXTENSION IF NOT EXISTS vector;
        \\CREATE TABLE IF NOT EXISTS {s} (
        \\  id text PRIMARY KEY,
        \\  vector_id text NOT NULL,
        \\  embedding vector NOT NULL,
        \\  object_type text NOT NULL,
        \\  object_id text NOT NULL,
        \\  chunk_ordinal bigint NOT NULL,
        \\  text text NOT NULL,
        \\  scope text NOT NULL,
        \\  permissions_json jsonb NOT NULL DEFAULT '[]'::jsonb,
        \\  heading_path_json jsonb NOT NULL DEFAULT '[]'::jsonb,
        \\  start_byte bigint NOT NULL DEFAULT 0,
        \\  end_byte bigint NOT NULL DEFAULT 0,
        \\  content_hash text NOT NULL DEFAULT '',
        \\  chunk_strategy text NOT NULL DEFAULT 'plain',
        \\  estimated_tokens bigint NOT NULL DEFAULT 0,
        \\  transcript_timestamp text,
        \\  transcript_speaker text,
        \\  model text,
        \\  dimensions bigint NOT NULL,
        \\  updated_at_ms bigint NOT NULL
        \\);
        \\ALTER TABLE {s} ALTER COLUMN embedding TYPE vector;
        \\ALTER TABLE {s} ADD COLUMN IF NOT EXISTS start_byte bigint NOT NULL DEFAULT 0;
        \\ALTER TABLE {s} ADD COLUMN IF NOT EXISTS end_byte bigint NOT NULL DEFAULT 0;
        \\ALTER TABLE {s} ADD COLUMN IF NOT EXISTS content_hash text NOT NULL DEFAULT '';
        \\ALTER TABLE {s} ADD COLUMN IF NOT EXISTS chunk_strategy text NOT NULL DEFAULT 'plain';
        \\ALTER TABLE {s} ADD COLUMN IF NOT EXISTS estimated_tokens bigint NOT NULL DEFAULT 0;
        \\ALTER TABLE {s} ADD COLUMN IF NOT EXISTS transcript_timestamp text;
        \\ALTER TABLE {s} ADD COLUMN IF NOT EXISTS transcript_speaker text;
        \\CREATE INDEX IF NOT EXISTS {s}_dimensions_idx ON {s}(dimensions);
        \\CREATE INDEX IF NOT EXISTS {s}_content_hash_idx ON {s}(object_type, object_id, content_hash);
        \\CREATE INDEX IF NOT EXISTS {s}_embedding_{d}_idx ON {s} USING ivfflat ((embedding::vector({d})) vector_cosine_ops) WHERE dimensions = {d};
    , .{ table, table, table, table, table, table, table, table, table, table, table, table, table, table, dimensions, table, dimensions, dimensions });
    defer allocator.free(sql);
    try pgvectorRunParams(allocator, cfg, runtime, sql, &.{});
    if (runtime) |rt| rt.rememberPgvectorSchemaLocked(cfg, table, dimensions);
}

fn pgvectorSchemaKey(cfg: Config, table: []const u8, dimensions: i64) u64 {
    var dimension_value = dimensions;
    var key = std.hash.Wyhash.hash(0, cfg.postgres_url orelse "");
    key = std.hash.Wyhash.hash(key, table);
    key = std.hash.Wyhash.hash(key, std.mem.asBytes(&dimension_value));
    return if (key == 0) 1 else key;
}

fn qdrantCollectionKey(cfg: Config, dimensions: i64) u64 {
    var dimension_value = dimensions;
    var key = std.hash.Wyhash.hash(0, cfg.base_url orelse "");
    key = std.hash.Wyhash.hash(key, cfg.api_key orelse "");
    key = std.hash.Wyhash.hash(key, cfg.collection);
    key = std.hash.Wyhash.hash(key, std.mem.asBytes(&dimension_value));
    return if (key == 0) 1 else key;
}

fn pgvectorRunParams(allocator: std.mem.Allocator, cfg: Config, runtime: ?*Runtime, sql: []const u8, params: []const ?[]const u8) !void {
    const out = try pgvectorQueryParams(allocator, cfg, runtime, sql, params);
    allocator.free(out);
}

fn pgvectorQueryParams(allocator: std.mem.Allocator, cfg: Config, runtime: ?*Runtime, sql: []const u8, params: []const ?[]const u8) ![]u8 {
    if (runtime) |rt| {
        rt.pgvector_transport_mutex.lockUncancelable(compat.io());
        defer rt.pgvector_transport_mutex.unlock(compat.io());
        const transport = try rt.pgvectorTransport(allocator, cfg);
        return try transport.queryParamsRaw(allocator, sql, params);
    }
    const raw_url = cfg.postgres_url orelse return error.VectorBackendUnavailable;
    const url = try postgres_transport.withConnectTimeout(allocator, raw_url);
    defer allocator.free(url);
    var transport = try postgres_transport.QueryTransport.init(allocator, url);
    defer transport.deinit();
    return try transport.queryParamsRaw(allocator, sql, params);
}

fn pgvectorTableName(cfg: Config) ![]const u8 {
    try validatePgIdentifier(cfg.collection);
    return cfg.collection;
}

fn validatePgIdentifier(value: []const u8) !void {
    if (value.len == 0 or value.len > 48) return error.InvalidVectorCollection;
    if (!std.ascii.isAlphabetic(value[0]) and value[0] != '_') return error.InvalidVectorCollection;
    for (value[1..]) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_') return error.InvalidVectorCollection;
    }
}

fn embeddingDimensionsFromJson(allocator: std.mem.Allocator, embedding_json: []const u8) !usize {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, embedding_json, .{}) catch return error.InvalidEmbeddingJson;
    defer parsed.deinit();
    const arr = switch (parsed.value) {
        .array => |value| value,
        else => return error.InvalidEmbeddingJson,
    };
    for (arr.items) |item| {
        switch (item) {
            .float => |value| if (!std.math.isFinite(value)) return error.InvalidEmbeddingJson,
            .integer => {},
            else => return error.InvalidEmbeddingJson,
        }
    }
    return arr.items.len;
}

fn validateUpsertInput(allocator: std.mem.Allocator, input: UpsertInput) !void {
    try validateVectorId(input.id);
    const actual_dimensions = try embeddingDimensionsFromJson(allocator, input.embedding_json);
    if (actual_dimensions == 0 or input.dimensions != @as(i64, @intCast(actual_dimensions))) return error.InvalidVectorDimensions;
    _ = try json.rawJsonArrayOrError(allocator, input.permissions_json, "[]");
    _ = try json.rawJsonArrayOrError(allocator, input.heading_path_json, "[]");
}

fn validateSearchInput(allocator: std.mem.Allocator, embedding_json: []const u8) !void {
    if (try embeddingDimensionsFromJson(allocator, embedding_json) == 0) return error.InvalidVectorDimensions;
}

fn validateVectorId(vector_id: []const u8) !void {
    if (vector_id.len == 0) return error.InvalidVectorId;
}

fn validateBackendConfig(cfg: Config) !void {
    return switch (cfg.backend) {
        .local => {},
        .pgvector => {
            _ = cfg.postgres_url orelse return error.VectorBackendUnavailable;
            _ = try pgvectorTableName(cfg);
        },
        .qdrant, .lancedb_http, .weaviate, .chroma, .opensearch => {
            const base_url = cfg.base_url orelse return error.VectorBackendUnavailable;
            try net_security.validateHttpBaseUrl(base_url, cfg.allow_insecure_http);
            if (cfg.backend == .weaviate) try validateWeaviateCollectionName(cfg.collection);
            if (cfg.backend == .opensearch) try validateOpenSearchIndexName(cfg.collection);
            if (cfg.backend == .chroma) {
                if (!nonEmptyString(cfg.chroma_tenant) or !nonEmptyString(cfg.chroma_database)) return error.VectorBackendUnavailable;
            }
        },
        .lancedb => {
            _ = cfg.lancedb_uri orelse return error.VectorBackendUnavailable;
            if (cfg.lancedb_command.len == 0) return error.VectorBackendUnavailable;
        },
    };
}

fn qdrantEnsureCollection(allocator: std.mem.Allocator, cfg: Config, runtime: ?*Runtime, dimensions: i64) !void {
    if (dimensions <= 0) return error.InvalidVectorDimensions;
    if (runtime) |rt| {
        if (rt.qdrantCollectionCachedLocked(cfg, dimensions)) return;
    }
    const path = try qdrantCollectionPath(allocator, cfg, "");
    defer allocator.free(path);
    const url = try backendUrl(allocator, cfg, path);
    defer allocator.free(url);
    const body = try std.fmt.allocPrint(allocator, "{{\"vectors\":{{\"size\":{d},\"distance\":\"Cosine\"}}}}", .{dimensions});
    defer allocator.free(body);
    const response = try requestJsonResponse(allocator, .PUT, url, cfg, body);
    defer allocator.free(response.body);
    if (response.status == .ok) {
        try ensureBackendOk(allocator, response.body);
    } else if (!qdrantCollectionAlreadyExists(response.status, response.body)) {
        return error.VectorBackendHttpError;
    }
    if (runtime) |rt| rt.rememberQdrantCollectionLocked(cfg, dimensions);
}

fn qdrantSearch(allocator: std.mem.Allocator, cfg: Config, embedding_json: []const u8, limit: usize) ![]Candidate {
    const path = try qdrantCollectionPath(allocator, cfg, "/points/search");
    defer allocator.free(path);
    const url = try backendUrl(allocator, cfg, path);
    defer allocator.free(url);
    const payload = try searchPayload(allocator, embedding_json, limit, true);
    defer allocator.free(payload);
    const response = try requestJson(allocator, .POST, url, cfg, payload);
    defer allocator.free(response);
    return parseCandidates(allocator, response);
}

fn qdrantDelete(allocator: std.mem.Allocator, cfg: Config, vector_id: []const u8) !void {
    try validateVectorId(vector_id);
    const path = try qdrantCollectionPath(allocator, cfg, "/points/delete?wait=true");
    defer allocator.free(path);
    const url = try backendUrl(allocator, cfg, path);
    defer allocator.free(url);
    const payload = try qdrantDeletePayload(allocator, vector_id);
    defer allocator.free(payload);
    const response = try requestJson(allocator, .POST, url, cfg, payload);
    defer allocator.free(response);
    try ensureBackendOk(allocator, response);
}

fn qdrantReset(allocator: std.mem.Allocator, cfg: Config, runtime: ?*Runtime) !void {
    const path = try qdrantCollectionPath(allocator, cfg, "");
    defer allocator.free(path);
    const url = try backendUrl(allocator, cfg, path);
    defer allocator.free(url);
    const response = try requestJsonResponse(allocator, .DELETE, url, cfg, "{}");
    defer allocator.free(response.body);
    if (response.status == .ok) {
        try ensureBackendOk(allocator, response.body);
    } else if (response.status != .not_found) {
        return error.VectorBackendHttpError;
    }
    if (runtime) |rt| rt.clearQdrantCollectionCacheLocked();
}

fn lancedbHttpUpsert(allocator: std.mem.Allocator, cfg: Config, input: UpsertInput) !void {
    const path = try lancedbTablePath(allocator, cfg, "/vectors/upsert");
    defer allocator.free(path);
    const url = try backendUrl(allocator, cfg, path);
    defer allocator.free(url);
    const payload = try lancedbUpsertPayload(allocator, input);
    defer allocator.free(payload);
    const response = try requestJson(allocator, .POST, url, cfg, payload);
    defer allocator.free(response);
    try ensureBackendOk(allocator, response);
}

fn lancedbHttpSearch(allocator: std.mem.Allocator, cfg: Config, embedding_json: []const u8, limit: usize) ![]Candidate {
    const path = try lancedbTablePath(allocator, cfg, "/vectors/search");
    defer allocator.free(path);
    const url = try backendUrl(allocator, cfg, path);
    defer allocator.free(url);
    const payload = try searchPayload(allocator, embedding_json, limit, false);
    defer allocator.free(payload);
    const response = try requestJson(allocator, .POST, url, cfg, payload);
    defer allocator.free(response);
    return parseCandidates(allocator, response);
}

fn lancedbHttpDelete(allocator: std.mem.Allocator, cfg: Config, vector_id: []const u8) !void {
    try validateVectorId(vector_id);
    const path = try lancedbTablePath(allocator, cfg, "/vectors/delete");
    defer allocator.free(path);
    const url = try backendUrl(allocator, cfg, path);
    defer allocator.free(url);
    const payload = try vectorDeletePayload(allocator, vector_id);
    defer allocator.free(payload);
    const response = try requestJson(allocator, .POST, url, cfg, payload);
    defer allocator.free(response);
    try ensureBackendOk(allocator, response);
}

fn lancedbHttpReset(allocator: std.mem.Allocator, cfg: Config) !void {
    const path = try lancedbTablePath(allocator, cfg, "/vectors/reset");
    defer allocator.free(path);
    const url = try backendUrl(allocator, cfg, path);
    defer allocator.free(url);
    const response = try requestJson(allocator, .POST, url, cfg, "{}");
    defer allocator.free(response);
    try ensureBackendOk(allocator, response);
}

fn weaviateUpsert(allocator: std.mem.Allocator, cfg: Config, input: UpsertInput) !void {
    const object_id = try weaviateObjectId(allocator, input.id);
    defer allocator.free(object_id);
    const path = try weaviateObjectPath(allocator, cfg, object_id);
    defer allocator.free(path);
    const url = try backendUrl(allocator, cfg, path);
    defer allocator.free(url);
    const payload = try weaviateUpsertPayload(allocator, cfg, object_id, input);
    defer allocator.free(payload);
    const response = try requestJsonResponse(allocator, .PUT, url, cfg, payload);
    defer allocator.free(response.body);
    if (response.status != .ok and response.status != .created) return error.VectorBackendHttpError;
    try ensureBackendOk(allocator, response.body);
}

fn weaviateSearch(allocator: std.mem.Allocator, cfg: Config, embedding_json: []const u8, limit: usize) ![]Candidate {
    const url = try backendUrl(allocator, cfg, "/v1/graphql");
    defer allocator.free(url);
    const payload = try weaviateSearchPayload(allocator, cfg, embedding_json, limit);
    defer allocator.free(payload);
    const response = try requestJson(allocator, .POST, url, cfg, payload);
    defer allocator.free(response);
    return parseCandidates(allocator, response);
}

fn weaviateDelete(allocator: std.mem.Allocator, cfg: Config, vector_id: []const u8) !void {
    const object_id = try weaviateObjectId(allocator, vector_id);
    defer allocator.free(object_id);
    const path = try weaviateObjectPath(allocator, cfg, object_id);
    defer allocator.free(path);
    const url = try backendUrl(allocator, cfg, path);
    defer allocator.free(url);
    const response = try requestJsonResponse(allocator, .DELETE, url, cfg, "{}");
    defer allocator.free(response.body);
    if (response.status != .ok and response.status != .no_content and response.status != .not_found) return error.VectorBackendHttpError;
}

fn weaviateReset(allocator: std.mem.Allocator, cfg: Config) !void {
    const path = try weaviateSchemaPath(allocator, cfg);
    defer allocator.free(path);
    const url = try backendUrl(allocator, cfg, path);
    defer allocator.free(url);
    const response = try requestJsonResponse(allocator, .DELETE, url, cfg, "{}");
    defer allocator.free(response.body);
    if (response.status != .ok and response.status != .no_content and response.status != .not_found) return error.VectorBackendHttpError;
}

fn chromaUpsert(allocator: std.mem.Allocator, cfg: Config, input: UpsertInput) !void {
    const path = try chromaCollectionPath(allocator, cfg, "/upsert");
    defer allocator.free(path);
    const url = try backendUrl(allocator, cfg, path);
    defer allocator.free(url);
    const payload = try chromaUpsertPayload(allocator, input);
    defer allocator.free(payload);
    const response = try requestJsonResponse(allocator, .POST, url, cfg, payload);
    defer allocator.free(response.body);
    if (response.status != .ok and response.status != .created) return error.VectorBackendHttpError;
    try ensureBackendOk(allocator, response.body);
}

fn chromaSearch(allocator: std.mem.Allocator, cfg: Config, embedding_json: []const u8, limit: usize) ![]Candidate {
    const path = try chromaCollectionPath(allocator, cfg, "/query");
    defer allocator.free(path);
    const url = try backendUrl(allocator, cfg, path);
    defer allocator.free(url);
    const payload = try chromaSearchPayload(allocator, embedding_json, limit);
    defer allocator.free(payload);
    const response = try requestJson(allocator, .POST, url, cfg, payload);
    defer allocator.free(response);
    return parseChromaCandidates(allocator, response);
}

fn chromaDelete(allocator: std.mem.Allocator, cfg: Config, vector_id: []const u8) !void {
    const path = try chromaCollectionPath(allocator, cfg, "/delete");
    defer allocator.free(path);
    const url = try backendUrl(allocator, cfg, path);
    defer allocator.free(url);
    const payload = try chromaDeletePayload(allocator, vector_id);
    defer allocator.free(payload);
    const response = try requestJsonResponse(allocator, .POST, url, cfg, payload);
    defer allocator.free(response.body);
    if (response.status != .ok and response.status != .not_found) return error.VectorBackendHttpError;
}

fn chromaReset(allocator: std.mem.Allocator, cfg: Config) !void {
    const path = try chromaCollectionPath(allocator, cfg, "");
    defer allocator.free(path);
    const url = try backendUrl(allocator, cfg, path);
    defer allocator.free(url);
    const response = try requestJsonResponse(allocator, .DELETE, url, cfg, "{}");
    defer allocator.free(response.body);
    if (response.status != .ok and response.status != .no_content and response.status != .not_found) return error.VectorBackendHttpError;
}

fn opensearchUpsert(allocator: std.mem.Allocator, cfg: Config, input: UpsertInput) !void {
    try opensearchEnsureIndex(allocator, cfg, input.dimensions);
    const path = try opensearchDocumentPath(allocator, cfg, input.id);
    defer allocator.free(path);
    const url = try backendUrl(allocator, cfg, path);
    defer allocator.free(url);
    const payload = try opensearchUpsertPayload(allocator, input);
    defer allocator.free(payload);
    const response = try requestJsonResponse(allocator, .PUT, url, cfg, payload);
    defer allocator.free(response.body);
    if (response.status != .ok and response.status != .created) return error.VectorBackendHttpError;
    try ensureBackendOk(allocator, response.body);
}

fn opensearchSearch(allocator: std.mem.Allocator, cfg: Config, embedding_json: []const u8, limit: usize) ![]Candidate {
    const path = try opensearchIndexPath(allocator, cfg, "/_search");
    defer allocator.free(path);
    const url = try backendUrl(allocator, cfg, path);
    defer allocator.free(url);
    const payload = try opensearchSearchPayload(allocator, embedding_json, limit);
    defer allocator.free(payload);
    const response = try requestJson(allocator, .POST, url, cfg, payload);
    defer allocator.free(response);
    return parseCandidates(allocator, response);
}

fn opensearchDelete(allocator: std.mem.Allocator, cfg: Config, vector_id: []const u8) !void {
    const path = try opensearchDocumentPath(allocator, cfg, vector_id);
    defer allocator.free(path);
    const url = try backendUrl(allocator, cfg, path);
    defer allocator.free(url);
    const response = try requestJsonResponse(allocator, .DELETE, url, cfg, "{}");
    defer allocator.free(response.body);
    if (response.status != .ok and response.status != .not_found) return error.VectorBackendHttpError;
}

fn opensearchReset(allocator: std.mem.Allocator, cfg: Config) !void {
    const path = try opensearchIndexPath(allocator, cfg, "");
    defer allocator.free(path);
    const url = try backendUrl(allocator, cfg, path);
    defer allocator.free(url);
    const response = try requestJsonResponse(allocator, .DELETE, url, cfg, "{}");
    defer allocator.free(response.body);
    if (response.status != .ok and response.status != .not_found) return error.VectorBackendHttpError;
}

fn opensearchEnsureIndex(allocator: std.mem.Allocator, cfg: Config, dimensions: i64) !void {
    if (dimensions <= 0) return error.InvalidVectorDimensions;
    const path = try opensearchIndexPath(allocator, cfg, "");
    defer allocator.free(path);
    const url = try backendUrl(allocator, cfg, path);
    defer allocator.free(url);
    const payload = try opensearchIndexPayload(allocator, dimensions);
    defer allocator.free(payload);
    const response = try requestJsonResponse(allocator, .PUT, url, cfg, payload);
    defer allocator.free(response.body);
    if (response.status == .ok or response.status == .created) return;
    if (response.status == .bad_request and std.ascii.indexOfIgnoreCase(response.body, "already_exists") != null) return;
    return error.VectorBackendHttpError;
}

fn lancedbSdkUpsert(allocator: std.mem.Allocator, cfg: Config, input: UpsertInput) !void {
    const payload = try lancedbUpsertPayload(allocator, input);
    defer allocator.free(payload);
    const response = try runLanceDbCommand(allocator, cfg, "upsert", payload, null);
    defer allocator.free(response);
    try ensureBackendOk(allocator, response);
}

fn lancedbSdkSearch(allocator: std.mem.Allocator, cfg: Config, embedding_json: []const u8, limit: usize) ![]Candidate {
    const limit_text = try std.fmt.allocPrint(allocator, "{d}", .{externalVectorSearchLimit(limit)});
    defer allocator.free(limit_text);
    const response = try runLanceDbCommand(allocator, cfg, "search", embedding_json, limit_text);
    defer allocator.free(response);
    return parseCandidates(allocator, response);
}

fn lancedbSdkDelete(allocator: std.mem.Allocator, cfg: Config, vector_id: []const u8) !void {
    try validateVectorId(vector_id);
    const payload = try vectorDeletePayload(allocator, vector_id);
    defer allocator.free(payload);
    const response = try runLanceDbCommand(allocator, cfg, "delete", payload, null);
    defer allocator.free(response);
    try ensureBackendOk(allocator, response);
}

fn lancedbSdkReset(allocator: std.mem.Allocator, cfg: Config) !void {
    const response = try runLanceDbCommand(allocator, cfg, "reset", "{}", null);
    defer allocator.free(response);
    try ensureBackendOk(allocator, response);
}

fn runLanceDbCommand(allocator: std.mem.Allocator, cfg: Config, op: []const u8, payload: []const u8, maybe_limit: ?[]const u8) ![]u8 {
    const timeout_ms = time_math.secondsToMs(@max(cfg.timeout_secs, 1));
    const argv = try lancedbCommandArgv(allocator, cfg, op, maybe_limit);
    defer allocator.free(argv);
    return runVectorProcessWithStdin(allocator, argv, payload, timeout_ms);
}

fn lancedbCommandArgv(allocator: std.mem.Allocator, cfg: Config, op: []const u8, maybe_limit: ?[]const u8) ![][]const u8 {
    const uri = cfg.lancedb_uri orelse return error.VectorBackendUnavailable;
    const command = cfg.lancedb_command;
    if (command.len == 0) return error.VectorBackendUnavailable;

    const use_python_sdk = commandLooksLikePython(command);
    const argc: usize = if (use_python_sdk)
        if (maybe_limit != null) 7 else 6
    else if (maybe_limit != null) 5 else 4;
    const argv = try allocator.alloc([]const u8, argc);
    errdefer allocator.free(argv);

    if (use_python_sdk) {
        argv[0] = command;
        argv[1] = "-c";
        argv[2] = lancedb_python_sdk;
        argv[3] = op;
        argv[4] = uri;
        argv[5] = cfg.collection;
        if (maybe_limit) |limit| argv[6] = limit;
    } else {
        argv[0] = command;
        argv[1] = op;
        argv[2] = uri;
        argv[3] = cfg.collection;
        if (maybe_limit) |limit| argv[4] = limit;
    }
    return argv;
}

fn runVectorProcessWithStdin(allocator: std.mem.Allocator, argv: []const []const u8, payload: []const u8, timeout_ms: i64) ![]u8 {
    var process_io = compat.process.childProcessIo(allocator);
    defer process_io.deinit();
    const io = process_io.io();
    var child_env = try compat.process.sanitizedChildEnv(allocator);
    defer child_env.deinit();
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .environ_map = &child_env,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);

    child.stdin.?.writeStreamingAll(io, payload) catch return error.VectorBackendUnavailable;
    child.stdin.?.close(io);
    child.stdin = null;

    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(allocator, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);
    const timeout = std.Io.Timeout{ .duration = .{
        .raw = std.Io.Duration.fromMilliseconds(timeout_ms),
        .clock = .awake,
    } };

    while (multi_reader.fill(64, timeout)) |_| {
        if (stdout_reader.buffered().len > max_vector_backend_response_bytes) return error.VectorBackendUnavailable;
        if (stderr_reader.buffered().len > 64 * 1024) return error.VectorBackendUnavailable;
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => return error.VectorBackendUnavailable,
    }

    multi_reader.checkAnyError() catch return error.VectorBackendUnavailable;
    const term = child.wait(io) catch return error.VectorBackendUnavailable;

    const stdout = multi_reader.toOwnedSlice(0) catch return error.VectorBackendUnavailable;
    errdefer allocator.free(stdout);
    const stderr = multi_reader.toOwnedSlice(1) catch return error.VectorBackendUnavailable;
    defer allocator.free(stderr);

    switch (term) {
        .exited => |code| if (code == 0) return stdout,
        else => {},
    }
    return error.VectorBackendUnavailable;
}

fn commandLooksLikePython(command: []const u8) bool {
    const base = std.fs.path.basename(command);
    return std.mem.eql(u8, base, "python") or
        std.mem.eql(u8, base, "python3") or
        std.mem.startsWith(u8, base, "python3.");
}

const lancedb_python_sdk =
    \\import json
    \\import sys
    \\import lancedb
    \\
    \\op = sys.argv[1]
    \\uri = sys.argv[2]
    \\table_name = sys.argv[3]
    \\payload = sys.stdin.read()
    \\db = lancedb.connect(uri)
    \\
    \\def open_or_none():
    \\    try:
    \\        return db.open_table(table_name)
    \\    except Exception:
    \\        return None
    \\
    \\if op == "upsert":
    \\    loaded = json.loads(payload)
    \\    row = loaded.get("rows", [loaded])[0] if isinstance(loaded, dict) else loaded[0]
    \\    table = open_or_none()
    \\    if table is None:
    \\        db.create_table(table_name, [row])
    \\    else:
    \\        value = str(row.get("id", "")).replace("'", "''")
    \\        if value:
    \\            try:
    \\                table.delete("id = '%s'" % value)
    \\            except Exception:
    \\                pass
    \\        table.add([row])
    \\    print(json.dumps({"status": "ok"}))
    \\elif op == "delete":
    \\    loaded = json.loads(payload) if payload else {}
    \\    ids = loaded.get("ids") or [loaded.get("vector_id") or loaded.get("id")]
    \\    table = open_or_none()
    \\    if table is not None:
    \\        for raw in ids:
    \\            value = str(raw or "").replace("'", "''")
    \\            if value:
    \\                try:
    \\                    table.delete("id = '%s'" % value)
    \\                except Exception:
    \\                    pass
    \\    print(json.dumps({"status": "ok"}))
    \\elif op == "reset":
    \\    try:
    \\        db.drop_table(table_name)
    \\    except Exception:
    \\        pass
    \\    print(json.dumps({"status": "ok"}))
    \\elif op == "search":
    \\    vector = json.loads(payload)
    \\    limit = int(sys.argv[4])
    \\    table = open_or_none()
    \\    if table is None:
    \\        print(json.dumps({"matches": []}))
    \\    else:
    \\        rows = table.search(vector).limit(limit).to_list()
    \\        matches = []
    \\        for row in rows:
    \\            vector_id = row.get("vector_id") or row.get("id")
    \\            distance = row.get("_distance")
    \\            score = row.get("_score")
    \\            if score is None and distance is not None:
    \\                score = max(0.0, min(1.0, 1.0 - float(distance)))
    \\            matches.append({"id": vector_id, "score": score if score is not None else 0.0, "_distance": distance})
    \\        print(json.dumps({"matches": matches}))
    \\else:
    \\    raise SystemExit(2)
;

fn qdrantUpsertPayload(allocator: std.mem.Allocator, input: UpsertInput) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"points\":[{\"id\":");
    try appendQdrantPointId(allocator, &out, input.id);
    try out.appendSlice(allocator, ",\"vector\":");
    try json.appendRawJsonArray(&out, allocator, input.embedding_json);
    try out.appendSlice(allocator, ",\"payload\":");
    try appendPayloadObject(allocator, &out, input);
    try out.appendSlice(allocator, "}]}");
    return out.toOwnedSlice(allocator);
}

fn lancedbUpsertPayload(allocator: std.mem.Allocator, input: UpsertInput) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"rows\":[");
    try appendPayloadObject(allocator, &out, input);
    try out.appendSlice(allocator, "]}");
    return out.toOwnedSlice(allocator);
}

fn weaviateUpsertPayload(allocator: std.mem.Allocator, cfg: Config, object_id: []const u8, input: UpsertInput) ![]u8 {
    try validateWeaviateCollectionName(cfg.collection);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"class\":");
    try json.appendString(&out, allocator, cfg.collection);
    try out.appendSlice(allocator, ",\"id\":");
    try json.appendString(&out, allocator, object_id);
    try out.appendSlice(allocator, ",\"properties\":");
    try appendFlatMetadataObject(allocator, &out, input);
    try out.appendSlice(allocator, ",\"vector\":");
    try json.appendRawJsonArray(&out, allocator, input.embedding_json);
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

fn weaviateSearchPayload(allocator: std.mem.Allocator, cfg: Config, embedding_json: []const u8, limit: usize) ![]u8 {
    try validateWeaviateCollectionName(cfg.collection);
    var query: std.ArrayListUnmanaged(u8) = .empty;
    defer query.deinit(allocator);
    try query.appendSlice(allocator, "{ Get { ");
    try query.appendSlice(allocator, cfg.collection);
    try query.appendSlice(allocator, "(nearVector:{vector:");
    try json.appendRawJsonArray(&query, allocator, embedding_json);
    try query.appendSlice(allocator, "} limit:");
    try query.print(allocator, "{d}", .{externalVectorSearchLimit(limit)});
    try query.appendSlice(allocator, ") { vector_id _additional { id distance certainty score } } } }");

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"query\":");
    try json.appendString(&out, allocator, query.items);
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

fn chromaUpsertPayload(allocator: std.mem.Allocator, input: UpsertInput) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"ids\":[");
    try json.appendString(&out, allocator, input.id);
    try out.appendSlice(allocator, "],\"embeddings\":[");
    try json.appendRawJsonArray(&out, allocator, input.embedding_json);
    try out.appendSlice(allocator, "],\"documents\":[");
    try json.appendString(&out, allocator, input.text);
    try out.appendSlice(allocator, "],\"metadatas\":[");
    try appendFlatMetadataObject(allocator, &out, input);
    try out.appendSlice(allocator, "]}");
    return out.toOwnedSlice(allocator);
}

fn chromaSearchPayload(allocator: std.mem.Allocator, embedding_json: []const u8, limit: usize) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"query_embeddings\":[");
    try json.appendRawJsonArray(&out, allocator, embedding_json);
    try out.print(allocator, "],\"n_results\":{d},\"include\":[\"distances\",\"metadatas\"]}}", .{externalVectorSearchLimit(limit)});
    return out.toOwnedSlice(allocator);
}

fn chromaDeletePayload(allocator: std.mem.Allocator, vector_id: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"ids\":[");
    try json.appendString(&out, allocator, vector_id);
    try out.appendSlice(allocator, "]}");
    return out.toOwnedSlice(allocator);
}

fn opensearchUpsertPayload(allocator: std.mem.Allocator, input: UpsertInput) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendPayloadObject(allocator, &out, input);
    return out.toOwnedSlice(allocator);
}

fn opensearchSearchPayload(allocator: std.mem.Allocator, embedding_json: []const u8, limit: usize) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    const capped_limit = externalVectorSearchLimit(limit);
    try out.print(allocator, "{{\"size\":{d},\"query\":{{\"knn\":{{\"vector\":{{\"vector\":", .{capped_limit});
    try json.appendRawJsonArray(&out, allocator, embedding_json);
    try out.print(allocator, ",\"k\":{d}}}}}}},\"_source\":[\"vector_id\"]}}", .{capped_limit});
    return out.toOwnedSlice(allocator);
}

fn opensearchIndexPayload(allocator: std.mem.Allocator, dimensions: i64) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"settings\":{{\"index\":{{\"knn\":true}}}},\"mappings\":{{\"properties\":{{\"vector\":{{\"type\":\"knn_vector\",\"dimension\":{d},\"space_type\":\"cosinesimil\"}},\"vector_id\":{{\"type\":\"keyword\"}},\"object_type\":{{\"type\":\"keyword\"}},\"object_id\":{{\"type\":\"keyword\"}},\"scope\":{{\"type\":\"keyword\"}},\"content_hash\":{{\"type\":\"keyword\"}},\"text\":{{\"type\":\"text\"}}}}}}}}",
        .{dimensions},
    );
}

fn vectorDeletePayload(allocator: std.mem.Allocator, vector_id: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"vector_id\":");
    try json.appendString(&out, allocator, vector_id);
    try out.appendSlice(allocator, ",\"ids\":[");
    try json.appendString(&out, allocator, vector_id);
    try out.appendSlice(allocator, "]}");
    return out.toOwnedSlice(allocator);
}

fn qdrantDeletePayload(allocator: std.mem.Allocator, vector_id: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"points\":[");
    try appendQdrantPointId(allocator, &out, vector_id);
    try out.appendSlice(allocator, "]}");
    return out.toOwnedSlice(allocator);
}

fn appendQdrantPointId(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), vector_id: []const u8) !void {
    const point_id = try qdrantPointId(allocator, vector_id);
    defer allocator.free(point_id);
    try json.appendString(out, allocator, point_id);
}

fn qdrantPointId(allocator: std.mem.Allocator, vector_id: []const u8) ![]u8 {
    try validateVectorId(vector_id);

    var bytes: [16]u8 = undefined;
    writeBigEndianU64(bytes[0..8], std.hash.Wyhash.hash(0x9e3779b97f4a7c15, vector_id));
    writeBigEndianU64(bytes[8..16], std.hash.Wyhash.hash(0xc2b2ae3d27d4eb4f, vector_id));
    bytes[6] = (bytes[6] & 0x0f) | 0x50;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    const hex = std.fmt.bytesToHex(bytes, .lower);
    return std.fmt.allocPrint(allocator, "{s}-{s}-{s}-{s}-{s}", .{
        hex[0..8],
        hex[8..12],
        hex[12..16],
        hex[16..20],
        hex[20..32],
    });
}

fn writeBigEndianU64(out: []u8, value: u64) void {
    std.debug.assert(out.len >= 8);
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const shift: u6 = @intCast((7 - i) * 8);
        out[i] = @intCast((value >> shift) & 0xff);
    }
}

fn appendPayloadObject(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), input: UpsertInput) !void {
    try out.appendSlice(allocator, "{\"id\":");
    try json.appendString(out, allocator, input.id);
    try out.appendSlice(allocator, ",\"vector_id\":");
    try json.appendString(out, allocator, input.id);
    try out.appendSlice(allocator, ",\"object_type\":");
    try json.appendString(out, allocator, input.object_type);
    try out.appendSlice(allocator, ",\"object_id\":");
    try json.appendString(out, allocator, input.object_id);
    try out.appendSlice(allocator, ",\"chunk_ordinal\":");
    try out.print(allocator, "{d}", .{input.chunk_ordinal});
    try out.appendSlice(allocator, ",\"text\":");
    try json.appendString(out, allocator, input.text);
    try out.appendSlice(allocator, ",\"scope\":");
    try json.appendString(out, allocator, input.scope);
    try out.appendSlice(allocator, ",\"permissions\":");
    try json.appendRawJsonArray(out, allocator, input.permissions_json);
    try out.appendSlice(allocator, ",\"heading_path\":");
    try json.appendRawJsonArray(out, allocator, input.heading_path_json);
    try out.print(allocator, ",\"start_byte\":{d},\"end_byte\":{d},\"content_hash\":", .{ input.start_byte, input.end_byte });
    try json.appendString(out, allocator, input.content_hash);
    try out.appendSlice(allocator, ",\"chunk_strategy\":");
    try json.appendString(out, allocator, input.chunk_strategy);
    try out.print(allocator, ",\"estimated_tokens\":{d},\"transcript_timestamp\":", .{input.estimated_tokens});
    try json.appendNullableString(out, allocator, input.transcript_timestamp);
    try out.appendSlice(allocator, ",\"transcript_speaker\":");
    try json.appendNullableString(out, allocator, input.transcript_speaker);
    try out.appendSlice(allocator, ",\"model\":");
    try json.appendNullableString(out, allocator, input.model);
    try out.appendSlice(allocator, ",\"dimensions\":");
    try out.print(allocator, "{d}", .{input.dimensions});
    try out.appendSlice(allocator, ",\"vector\":");
    try json.appendRawJsonArray(out, allocator, input.embedding_json);
    try out.append(allocator, '}');
}

fn appendFlatMetadataObject(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), input: UpsertInput) !void {
    const permissions_json = try json.rawJsonArrayOrError(allocator, input.permissions_json, "[]");
    const heading_path_json = try json.rawJsonArrayOrError(allocator, input.heading_path_json, "[]");

    try out.appendSlice(allocator, "{\"vector_id\":");
    try json.appendString(out, allocator, input.id);
    try out.appendSlice(allocator, ",\"object_type\":");
    try json.appendString(out, allocator, input.object_type);
    try out.appendSlice(allocator, ",\"object_id\":");
    try json.appendString(out, allocator, input.object_id);
    try out.print(allocator, ",\"chunk_ordinal\":{d},\"text\":", .{input.chunk_ordinal});
    try json.appendString(out, allocator, input.text);
    try out.appendSlice(allocator, ",\"scope\":");
    try json.appendString(out, allocator, input.scope);
    try out.appendSlice(allocator, ",\"permissions_json\":");
    try json.appendString(out, allocator, permissions_json);
    try out.appendSlice(allocator, ",\"heading_path_json\":");
    try json.appendString(out, allocator, heading_path_json);
    try out.print(allocator, ",\"start_byte\":{d},\"end_byte\":{d},\"content_hash\":", .{ input.start_byte, input.end_byte });
    try json.appendString(out, allocator, input.content_hash);
    try out.appendSlice(allocator, ",\"chunk_strategy\":");
    try json.appendString(out, allocator, input.chunk_strategy);
    try out.print(allocator, ",\"estimated_tokens\":{d},\"transcript_timestamp\":", .{input.estimated_tokens});
    try json.appendNullableString(out, allocator, input.transcript_timestamp);
    try out.appendSlice(allocator, ",\"transcript_speaker\":");
    try json.appendNullableString(out, allocator, input.transcript_speaker);
    try out.appendSlice(allocator, ",\"model\":");
    try json.appendNullableString(out, allocator, input.model);
    try out.print(allocator, ",\"dimensions\":{d}}}", .{input.dimensions});
}

fn searchPayload(allocator: std.mem.Allocator, embedding_json: []const u8, limit: usize, qdrant: bool) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"vector\":");
    try json.appendRawJsonArray(&out, allocator, embedding_json);
    try out.print(allocator, ",\"limit\":{d}", .{externalVectorSearchLimit(limit)});
    if (qdrant) try out.appendSlice(allocator, ",\"with_payload\":true");
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

fn parseCandidates(allocator: std.mem.Allocator, body: []const u8) ![]Candidate {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.VectorBackendInvalidResponse;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return error.VectorBackendInvalidResponse,
    };
    if (root.get("result")) |result| {
        if (result == .array) return parseCandidateArray(allocator, result.array.items);
        if (result == .object) {
            if (result.object.get("points")) |points| {
                if (points == .array) return parseCandidateArray(allocator, points.array.items);
            }
        }
    }
    if (root.get("matches")) |matches| {
        if (matches == .array) return parseCandidateArray(allocator, matches.array.items);
    }
    if (root.get("results")) |results| {
        if (results == .array) return parseCandidateArray(allocator, results.array.items);
    }
    if (root.get("hits")) |hits| {
        if (hits == .object) {
            if (hits.object.get("hits")) |items| {
                if (items == .array) return parseCandidateArray(allocator, items.array.items);
            }
        }
    }
    if (root.get("data")) |data| {
        if (data == .object) {
            if (data.object.get("Get")) |get| {
                if (get == .object) {
                    var iter = get.object.iterator();
                    while (iter.next()) |entry| {
                        if (entry.value_ptr.* == .array) return parseCandidateArray(allocator, entry.value_ptr.array.items);
                    }
                }
            }
        }
    }
    return allocator.alloc(Candidate, 0);
}

fn parseChromaCandidates(allocator: std.mem.Allocator, body: []const u8) ![]Candidate {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.VectorBackendInvalidResponse;
    defer parsed.deinit();
    if (parsed.value != .object) return error.VectorBackendInvalidResponse;
    const ids_root = parsed.value.object.get("ids") orelse return allocator.alloc(Candidate, 0);
    if (ids_root != .array or ids_root.array.items.len == 0) return allocator.alloc(Candidate, 0);
    const first_ids = ids_root.array.items[0];
    if (first_ids != .array) return allocator.alloc(Candidate, 0);
    const distances_root = parsed.value.object.get("distances");
    const first_distances: ?std.json.Array = if (distances_root) |distances|
        if (distances == .array and distances.array.items.len > 0 and distances.array.items[0] == .array) distances.array.items[0].array else null
    else
        null;

    var out: std.ArrayListUnmanaged(Candidate) = .empty;
    errdefer {
        for (out.items) |candidate| allocator.free(candidate.vector_id);
        out.deinit(allocator);
    }
    for (first_ids.array.items, 0..) |item, i| {
        if (item != .string or item.string.len == 0) continue;
        const score = blk: {
            if (first_distances) |distances| {
                if (i < distances.items.len) {
                    if (valueAsF64(distances.items[i])) |distance| break :blk positiveScore(1 - distance) orelse continue;
                }
            }
            break :blk @as(f32, 1);
        };
        try out.append(allocator, .{ .vector_id = try allocator.dupe(u8, item.string), .score = score });
    }
    return out.toOwnedSlice(allocator);
}

fn parseCandidateArray(allocator: std.mem.Allocator, items: []const std.json.Value) ![]Candidate {
    var out: std.ArrayListUnmanaged(Candidate) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| {
        if (item != .object) continue;
        const obj = item.object;
        const id = candidateVectorId(obj) orelse continue;
        const score = candidateScore(obj) orelse continue;
        try out.append(allocator, .{ .vector_id = try allocator.dupe(u8, id), .score = score });
    }
    return out.toOwnedSlice(allocator);
}

fn candidateVectorId(obj: std.json.ObjectMap) ?[]const u8 {
    if (json.stringField(obj, "vector_id")) |id| if (id.len > 0) return id;
    if (json.stringField(obj, "id")) |id| if (id.len > 0) return id;
    if (obj.get("payload")) |payload| {
        if (payload == .object) {
            if (json.stringField(payload.object, "vector_id")) |id| if (id.len > 0) return id;
            if (json.stringField(payload.object, "id")) |id| if (id.len > 0) return id;
        }
    }
    if (obj.get("_source")) |source| {
        if (source == .object) {
            if (json.stringField(source.object, "vector_id")) |id| if (id.len > 0) return id;
            if (json.stringField(source.object, "id")) |id| if (id.len > 0) return id;
        }
    }
    if (obj.get("_additional")) |additional| {
        if (additional == .object) {
            if (json.stringField(additional.object, "vector_id")) |id| if (id.len > 0) return id;
            if (json.stringField(additional.object, "id")) |id| if (id.len > 0) return id;
        }
    }
    if (json.stringField(obj, "_id")) |id| if (id.len > 0) return id;
    return null;
}

fn candidateScore(obj: std.json.ObjectMap) ?f32 {
    if (json.floatField(obj, "score")) |score| return positiveScore(score);
    if (json.floatField(obj, "_score")) |score| return positiveScore(score);
    if (json.floatField(obj, "distance")) |distance| return positiveScore(1 - distance);
    if (json.floatField(obj, "_distance")) |distance| return positiveScore(1 - distance);
    if (obj.get("_additional")) |additional| {
        if (additional == .object) {
            if (json.floatField(additional.object, "certainty")) |certainty| return positiveScore(certainty);
            if (json.floatField(additional.object, "score")) |score| return positiveScore(score);
            if (json.floatField(additional.object, "distance")) |distance| return positiveScore(1 - distance);
        }
    }
    return null;
}

fn valueAsF64(value: std.json.Value) ?f64 {
    return switch (value) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => null,
    };
}

fn positiveScore(score: f64) ?f32 {
    if (!std.math.isFinite(score) or score <= 0) return null;
    return @floatCast(@min(score, 1));
}

fn ensureBackendOk(allocator: std.mem.Allocator, body: []const u8) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    if (json.stringField(parsed.value.object, "status")) |status| {
        if (std.ascii.eqlIgnoreCase(status, "ok")) return;
        if (std.ascii.eqlIgnoreCase(status, "success")) return;
        return error.VectorBackendRejected;
    }
}

fn qdrantCollectionAlreadyExists(status: std.http.Status, body: []const u8) bool {
    if (status == .conflict) return true;
    if (status != .bad_request) return false;
    return std.ascii.indexOfIgnoreCase(body, "already exists") != null or
        std.ascii.indexOfIgnoreCase(body, "collection exists") != null;
}

fn backendUrl(allocator: std.mem.Allocator, cfg: Config, suffix: []const u8) ![]u8 {
    const base_url = cfg.base_url orelse return error.VectorBackendUnavailable;
    return net_security.joinHttpBaseUrl(allocator, base_url, suffix, cfg.allow_insecure_http);
}

fn qdrantCollectionPath(allocator: std.mem.Allocator, cfg: Config, suffix: []const u8) ![]u8 {
    const collection = try net_security.percentEncodePathSegment(allocator, cfg.collection);
    defer allocator.free(collection);
    return std.fmt.allocPrint(allocator, "/collections/{s}{s}", .{ collection, suffix });
}

fn lancedbTablePath(allocator: std.mem.Allocator, cfg: Config, suffix: []const u8) ![]u8 {
    const table = try net_security.percentEncodePathSegment(allocator, cfg.collection);
    defer allocator.free(table);
    return std.fmt.allocPrint(allocator, "/v1/tables/{s}{s}", .{ table, suffix });
}

fn weaviateObjectId(allocator: std.mem.Allocator, vector_id: []const u8) ![]u8 {
    return qdrantPointId(allocator, vector_id);
}

fn weaviateObjectPath(allocator: std.mem.Allocator, cfg: Config, object_id: []const u8) ![]u8 {
    try validateWeaviateCollectionName(cfg.collection);
    const collection = try net_security.percentEncodePathSegment(allocator, cfg.collection);
    defer allocator.free(collection);
    const id = try net_security.percentEncodePathSegment(allocator, object_id);
    defer allocator.free(id);
    return std.fmt.allocPrint(allocator, "/v1/objects/{s}/{s}", .{ collection, id });
}

fn weaviateSchemaPath(allocator: std.mem.Allocator, cfg: Config) ![]u8 {
    try validateWeaviateCollectionName(cfg.collection);
    const collection = try net_security.percentEncodePathSegment(allocator, cfg.collection);
    defer allocator.free(collection);
    return std.fmt.allocPrint(allocator, "/v1/schema/{s}", .{collection});
}

fn chromaCollectionPath(allocator: std.mem.Allocator, cfg: Config, suffix: []const u8) ![]u8 {
    const tenant = try net_security.percentEncodePathSegment(allocator, cfg.chroma_tenant);
    defer allocator.free(tenant);
    const database = try net_security.percentEncodePathSegment(allocator, cfg.chroma_database);
    defer allocator.free(database);
    const collection = try net_security.percentEncodePathSegment(allocator, cfg.collection);
    defer allocator.free(collection);
    return std.fmt.allocPrint(allocator, "/api/v2/tenants/{s}/databases/{s}/collections/{s}{s}", .{ tenant, database, collection, suffix });
}

fn opensearchIndexPath(allocator: std.mem.Allocator, cfg: Config, suffix: []const u8) ![]u8 {
    const index = try net_security.percentEncodePathSegment(allocator, cfg.collection);
    defer allocator.free(index);
    return std.fmt.allocPrint(allocator, "/{s}{s}", .{ index, suffix });
}

fn opensearchDocumentPath(allocator: std.mem.Allocator, cfg: Config, vector_id: []const u8) ![]u8 {
    const id = try net_security.percentEncodePathSegment(allocator, vector_id);
    defer allocator.free(id);
    const suffix = try std.fmt.allocPrint(allocator, "/_doc/{s}", .{id});
    defer allocator.free(suffix);
    return opensearchIndexPath(allocator, cfg, suffix);
}

fn validateWeaviateCollectionName(value: []const u8) !void {
    if (value.len == 0 or value.len > 128) return error.InvalidVectorCollection;
    if (!std.ascii.isAlphabetic(value[0]) and value[0] != '_') return error.InvalidVectorCollection;
    for (value[1..]) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '_') continue;
        return error.InvalidVectorCollection;
    }
}

fn validateOpenSearchIndexName(value: []const u8) !void {
    if (value.len == 0) return error.InvalidVectorCollection;
    if (value[0] == '_' or value[0] == '-') return error.InvalidVectorCollection;
    for (value) |ch| {
        if (std.ascii.isUpper(ch) or ch == ' ' or ch == ',') return error.InvalidVectorCollection;
        switch (ch) {
            ':', '"', '*', '+', '/', '\\', '|', '?', '#', '>', '<' => return error.InvalidVectorCollection,
            else => {},
        }
    }
}

fn requestJson(allocator: std.mem.Allocator, method: std.http.Method, url: []const u8, cfg: Config, payload: []const u8) ![]u8 {
    const response = try requestJsonResponse(allocator, method, url, cfg, payload);
    if (response.status != .ok) {
        allocator.free(response.body);
        return error.VectorBackendHttpError;
    }
    return response.body;
}

fn requestJsonResponse(allocator: std.mem.Allocator, method: std.http.Method, url: []const u8, cfg: Config, payload: []const u8) !VectorHttpResponse {
    var auth_header: ?[]u8 = null;
    defer if (auth_header) |h| allocator.free(h);

    var extra_headers_buf: [1]std.http.Header = undefined;
    var header_count: usize = 0;
    if (cfg.api_key) |key| {
        const header_name = try apiKeyHeaderName(cfg);
        const header_value = try apiKeyHeaderValue(allocator, header_name, key);
        auth_header = header_value;
        extra_headers_buf[header_count] = .{ .name = header_name, .value = header_value };
        header_count += 1;
    }

    var client: std.http.Client = .{ .allocator = allocator, .io = compat.io() };
    defer client.deinit();

    const uri = std.Uri.parse(url) catch return error.VectorBackendUnavailable;
    var req = client.request(method, uri, .{
        .redirect_behavior = .unhandled,
        .keep_alive = false,
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .accept_encoding = .omit,
            .connection = .{ .override = "close" },
        },
        .extra_headers = extra_headers_buf[0..header_count],
    }) catch return error.VectorBackendUnavailable;
    defer req.deinit();

    net_security.applyHttpSocketTimeout(req.connection, cfg.timeout_secs);

    req.transfer_encoding = .{ .content_length = payload.len };
    var body_writer = req.sendBodyUnflushed(&.{}) catch return error.VectorBackendUnavailable;
    body_writer.writer.writeAll(payload) catch return error.VectorBackendUnavailable;
    body_writer.end() catch return error.VectorBackendUnavailable;
    net_security.flushHttpConnection(req.connection) catch return error.VectorBackendUnavailable;

    var response = req.receiveHead(&.{}) catch return error.VectorBackendUnavailable;
    const reader = response.reader(&.{});
    const body = net_security.readBoundedResponse(allocator, reader, max_vector_backend_response_bytes) catch |err| switch (err) {
        error.StreamTooLong => return error.VectorBackendResponseTooLarge,
        else => return error.VectorBackendUnavailable,
    };
    return .{ .status = response.head.status, .body = body };
}

fn apiKeyHeaderName(cfg: Config) ![]const u8 {
    const header_name = if (cfg.api_key_header.len > 0) cfg.api_key_header else switch (cfg.backend) {
        .qdrant => "api-key",
        .chroma => "x-chroma-token",
        else => "Authorization",
    };
    try net_security.validateHttpHeaderName(header_name);
    return header_name;
}

fn apiKeyHeaderValue(allocator: std.mem.Allocator, header_name: []const u8, key: []const u8) ![]u8 {
    try net_security.validateHttpHeaderValue(key);
    if (!std.ascii.eqlIgnoreCase(header_name, "Authorization")) return allocator.dupe(u8, key);
    if (std.ascii.startsWithIgnoreCase(key, "Bearer ") or
        std.ascii.startsWithIgnoreCase(key, "Basic ") or
        std.ascii.startsWithIgnoreCase(key, "Token "))
    {
        return allocator.dupe(u8, key);
    }
    return std.fmt.allocPrint(allocator, "Bearer {s}", .{key});
}

test "vector external search limit preserves protocol bounds" {
    try std.testing.expectEqual(@as(usize, 1), externalVectorSearchLimit(0));
    try std.testing.expectEqual(@as(usize, 42), externalVectorSearchLimit(42));
    try std.testing.expectEqual(@as(usize, external_vector_search_limit_max), externalVectorSearchLimit(external_vector_search_limit_max + 1));
    try std.testing.expectEqual(@as(usize, external_vector_search_limit_max), externalVectorSearchLimit(std.math.maxInt(usize)));
}

test "qdrant payload preserves vector id and ACL metadata" {
    const point_id = try qdrantPointId(std.testing.allocator, "vec_atom_0");
    defer std.testing.allocator.free(point_id);

    const payload = try qdrantUpsertPayload(std.testing.allocator, .{
        .id = "vec_atom_0",
        .object_type = "memory_atom",
        .object_id = "atom",
        .chunk_ordinal = 0,
        .text = "hello",
        .scope = "project:nullpantry",
        .permissions_json = "[\"team:agents\"]",
        .heading_path_json = "[\"# NullPantry\",\"## Memory\"]",
        .embedding_json = "[1,0]",
        .model = "test",
        .dimensions = 2,
    });
    defer std.testing.allocator.free(payload);
    const expected_id = try std.fmt.allocPrint(std.testing.allocator, "\"id\":\"{s}\"", .{point_id});
    defer std.testing.allocator.free(expected_id);
    try std.testing.expect(std.mem.indexOf(u8, payload, expected_id) != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"vector_id\":\"vec_atom_0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"permissions\":[\"team:agents\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"heading_path\":[\"# NullPantry\",\"## Memory\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"vector\":[1,0]") != null);
}

test "vector backend payloads reject invalid raw array fields" {
    const allocator = std.testing.allocator;
    var input = UpsertInput{
        .id = "vec_bad_raw",
        .object_type = "memory_atom",
        .object_id = "atom_bad_raw",
        .chunk_ordinal = 0,
        .text = "bad raw arrays",
        .scope = "public",
        .permissions_json = "{\"scope\":\"public\"}",
        .heading_path_json = "[\"Intro\"]",
        .embedding_json = "[1,0]",
        .model = "test",
        .dimensions = 2,
    };

    try std.testing.expectError(error.InvalidRawJson, validateUpsertInput(allocator, input));
    try std.testing.expectError(error.InvalidRawJson, qdrantUpsertPayload(allocator, input));
    try std.testing.expectError(error.InvalidRawJson, chromaUpsertPayload(allocator, input));
    try std.testing.expectError(error.InvalidRawJson, opensearchUpsertPayload(allocator, input));

    const object_id = try weaviateObjectId(allocator, input.id);
    defer allocator.free(object_id);
    try std.testing.expectError(error.InvalidRawJson, weaviateUpsertPayload(allocator, .{ .backend = .weaviate, .collection = "NullPantryVector" }, object_id, input));

    input.permissions_json = "[\"public\"]";
    input.heading_path_json = "[\"Intro\"]";
    input.embedding_json = "{\"embedding\":[1,0]}";
    try std.testing.expectError(error.InvalidRawJson, qdrantUpsertPayload(allocator, input));
    try std.testing.expectError(error.InvalidRawJson, chromaUpsertPayload(allocator, input));
    try std.testing.expectError(error.InvalidRawJson, weaviateUpsertPayload(allocator, .{ .backend = .weaviate, .collection = "NullPantryVector" }, object_id, input));
    try std.testing.expectError(error.InvalidRawJson, opensearchUpsertPayload(allocator, input));
    try std.testing.expectError(error.InvalidRawJson, searchPayload(allocator, "{\"embedding\":[1,0]}", 3, true));
    try std.testing.expectError(error.InvalidRawJson, weaviateSearchPayload(allocator, .{ .backend = .weaviate, .collection = "NullPantryVector" }, "{\"embedding\":[1,0]}", 3));
    try std.testing.expectError(error.InvalidRawJson, chromaSearchPayload(allocator, "{\"embedding\":[1,0]}", 3));
    try std.testing.expectError(error.InvalidRawJson, opensearchSearchPayload(allocator, "{\"embedding\":[1,0]}", 3));
}

test "qdrant point ids are deterministic UUIDs derived from canonical vector id" {
    const first = try qdrantPointId(std.testing.allocator, "vec_atom_0");
    defer std.testing.allocator.free(first);
    const second = try qdrantPointId(std.testing.allocator, "vec_atom_0");
    defer std.testing.allocator.free(second);
    const different = try qdrantPointId(std.testing.allocator, "vec_atom_1");
    defer std.testing.allocator.free(different);

    try std.testing.expectEqualStrings(first, second);
    try std.testing.expect(!std.mem.eql(u8, first, different));
    try std.testing.expectEqual(@as(usize, 36), first.len);
    try std.testing.expect(first[8] == '-');
    try std.testing.expect(first[13] == '-');
    try std.testing.expect(first[18] == '-');
    try std.testing.expect(first[23] == '-');
    try std.testing.expect(first[14] == '5');
    try std.testing.expect(first[19] == '8' or first[19] == '9' or first[19] == 'a' or first[19] == 'b');
}

test "vector delete payload preserves canonical vector id" {
    const payload = try vectorDeletePayload(std.testing.allocator, "vec_atom_0");
    defer std.testing.allocator.free(payload);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"vector_id\":\"vec_atom_0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"ids\":[\"vec_atom_0\"]") != null);
}

test "qdrant delete payload uses deterministic point id" {
    const point_id = try qdrantPointId(std.testing.allocator, "vec_atom_0");
    defer std.testing.allocator.free(point_id);
    const payload = try qdrantDeletePayload(std.testing.allocator, "vec_atom_0");
    defer std.testing.allocator.free(payload);

    const expected = try std.fmt.allocPrint(std.testing.allocator, "{{\"points\":[\"{s}\"]}}", .{point_id});
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, payload);
    try std.testing.expect(std.mem.indexOf(u8, payload, "vec_atom_0") == null);
}

test "vector delete validates id before backend calls" {
    try std.testing.expectError(error.InvalidVectorId, delete(std.testing.allocator, .{ .backend = .qdrant, .base_url = "http://127.0.0.1:6333" }, ""));
    try std.testing.expectError(error.InvalidVectorId, delete(std.testing.allocator, .{ .backend = .lancedb, .lancedb_uri = ".zig-cache/tmp/unused-lancedb" }, ""));
    try std.testing.expectError(error.InvalidVectorId, delete(std.testing.allocator, .{ .backend = .lancedb_http, .base_url = "http://127.0.0.1:9000" }, ""));
    try std.testing.expectError(error.InvalidVectorId, delete(std.testing.allocator, .{ .backend = .weaviate, .base_url = "http://127.0.0.1:8080" }, ""));
    try std.testing.expectError(error.InvalidVectorId, delete(std.testing.allocator, .{ .backend = .chroma, .base_url = "http://127.0.0.1:8000" }, ""));
    try std.testing.expectError(error.InvalidVectorId, delete(std.testing.allocator, .{ .backend = .opensearch, .base_url = "http://127.0.0.1:9200" }, ""));
}

test "vector index parses qdrant and lancedb candidate shapes" {
    const qdrant = "{\"result\":[{\"score\":0.93,\"payload\":{\"vector_id\":\"vec_a\"}},{\"score\":0,\"payload\":{\"vector_id\":\"zero_score\"}},{\"payload\":{\"vector_id\":\"missing_score\"}},{\"score\":0.5,\"payload\":{\"vector_id\":\"\"}}]}";
    const q = try parseCandidates(std.testing.allocator, qdrant);
    defer freeCandidates(std.testing.allocator, q);
    try std.testing.expectEqual(@as(usize, 1), q.len);
    try std.testing.expectEqualStrings("vec_a", q[0].vector_id);
    try std.testing.expectApproxEqAbs(@as(f32, 0.93), q[0].score, 0.0001);

    const lancedb = "{\"matches\":[{\"id\":\"vec_b\",\"_distance\":0.25}]}";
    const l = try parseCandidates(std.testing.allocator, lancedb);
    defer freeCandidates(std.testing.allocator, l);
    try std.testing.expectEqual(@as(usize, 1), l.len);
    try std.testing.expectEqualStrings("vec_b", l[0].vector_id);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), l[0].score, 0.0001);

    const normalized = "{\"results\":[{\"vector_id\":\"clamped\",\"score\":2.5},{\"vector_id\":\"bad_distance\",\"distance\":2},{\"payload\":{\"id\":\"payload_id\"},\"_score\":0.42}]}";
    const n = try parseCandidates(std.testing.allocator, normalized);
    defer freeCandidates(std.testing.allocator, n);
    try std.testing.expectEqual(@as(usize, 2), n.len);
    try std.testing.expectEqualStrings("clamped", n[0].vector_id);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), n[0].score, 0.0001);
    try std.testing.expectEqualStrings("payload_id", n[1].vector_id);
    try std.testing.expectApproxEqAbs(@as(f32, 0.42), n[1].score, 0.0001);

    const weaviate = "{\"data\":{\"Get\":{\"NullPantryVector\":[{\"vector_id\":\"vec_w\",\"_additional\":{\"distance\":0.2}},{\"_additional\":{\"id\":\"weaviate_uuid\",\"certainty\":0.88}}]}}}";
    const w = try parseCandidates(std.testing.allocator, weaviate);
    defer freeCandidates(std.testing.allocator, w);
    try std.testing.expectEqual(@as(usize, 2), w.len);
    try std.testing.expectEqualStrings("vec_w", w[0].vector_id);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), w[0].score, 0.0001);
    try std.testing.expectEqualStrings("weaviate_uuid", w[1].vector_id);
    try std.testing.expectApproxEqAbs(@as(f32, 0.88), w[1].score, 0.0001);

    const opensearch = "{\"hits\":{\"hits\":[{\"_id\":\"doc-id\",\"_score\":0.77,\"_source\":{\"vector_id\":\"vec_os\"}}]}}";
    const os = try parseCandidates(std.testing.allocator, opensearch);
    defer freeCandidates(std.testing.allocator, os);
    try std.testing.expectEqual(@as(usize, 1), os.len);
    try std.testing.expectEqualStrings("vec_os", os[0].vector_id);
    try std.testing.expectApproxEqAbs(@as(f32, 0.77), os[0].score, 0.0001);

    const chroma = "{\"ids\":[[\"vec_c\",\"zero_distance\"]],\"distances\":[[0.25,0]]}";
    const c = try parseChromaCandidates(std.testing.allocator, chroma);
    defer freeCandidates(std.testing.allocator, c);
    try std.testing.expectEqual(@as(usize, 2), c.len);
    try std.testing.expectEqualStrings("vec_c", c[0].vector_id);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), c[0].score, 0.0001);
    try std.testing.expectEqualStrings("zero_distance", c[1].vector_id);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), c[1].score, 0.0001);

    try ensureBackendOk(std.testing.allocator, "{\"status\":\"ok\"}");
    try ensureBackendOk(std.testing.allocator, "{\"status\":\"success\"}");
    try std.testing.expectError(error.VectorBackendRejected, ensureBackendOk(std.testing.allocator, "{\"status\":\"error\"}"));
    try std.testing.expect(qdrantCollectionAlreadyExists(.conflict, "{}"));
    try std.testing.expect(qdrantCollectionAlreadyExists(.bad_request, "{\"status\":{\"error\":\"Collection already exists\"}}"));
    try std.testing.expect(!qdrantCollectionAlreadyExists(.bad_request, "{\"status\":{\"error\":\"Bad vector size\"}}"));
}

test "vector index config gates external runtime" {
    try std.testing.expect(!(Config{}).externalEnabled());
    try std.testing.expect((Config{ .backend = .pgvector, .postgres_url = "postgres://localhost/nullpantry" }).externalEnabled());
    try std.testing.expect((Config{ .backend = .qdrant, .base_url = "http://127.0.0.1:6333" }).externalEnabled());
    try std.testing.expect((Config{ .backend = .lancedb, .lancedb_uri = ".nullpantry/lancedb" }).externalEnabled());
    try std.testing.expect((Config{ .backend = .lancedb_http, .base_url = "http://127.0.0.1:9000" }).externalEnabled());
    try std.testing.expect((Config{ .backend = .weaviate, .base_url = "http://127.0.0.1:8080" }).externalEnabled());
    try std.testing.expect((Config{ .backend = .chroma, .base_url = "http://127.0.0.1:8000" }).externalEnabled());
    try std.testing.expect((Config{ .backend = .opensearch, .base_url = "http://127.0.0.1:9200" }).externalEnabled());
    try std.testing.expect((try BackendKind.parse("local")) == .local);
    try std.testing.expect((try BackendKind.parse("pgvector")) == .pgvector);
    try std.testing.expect((try BackendKind.parse("postgres-vector")) == .pgvector);
    try std.testing.expect((try BackendKind.parse("lancedb")) == .lancedb);
    try std.testing.expect((try BackendKind.parse("lancedb_http")) == .lancedb_http);
    try std.testing.expect((try BackendKind.parse("lancedb-http")) == .lancedb_http);
    try std.testing.expect((try BackendKind.parse("weaviate")) == .weaviate);
    try std.testing.expect((try BackendKind.parse("chroma")) == .chroma);
    try std.testing.expect((try BackendKind.parse("opensearch")) == .opensearch);
    try std.testing.expect((try BackendKind.parse("open_search")) == .opensearch);
    try std.testing.expectError(error.InvalidVectorBackend, BackendKind.parse("unknown"));
    try std.testing.expectError(error.InsecureRuntimeUrl, backendUrl(std.testing.allocator, .{
        .backend = .qdrant,
        .base_url = "http://qdrant.internal:6333",
    }, "/collections/nullpantry_vectors"));
    try std.testing.expectError(error.InvalidRuntimeUrl, backendUrl(std.testing.allocator, .{
        .backend = .qdrant,
        .base_url = "https://token@qdrant.example",
    }, "/collections/nullpantry_vectors"));
    try std.testing.expectError(error.InvalidRuntimeUrl, backendUrl(std.testing.allocator, .{
        .backend = .qdrant,
        .base_url = "https://qdrant.example?token=x",
    }, "/collections/nullpantry_vectors"));

    const url = try backendUrl(std.testing.allocator, .{
        .backend = .qdrant,
        .base_url = "http://qdrant.internal:6333",
        .allow_insecure_http = true,
    }, "/collections/nullpantry_vectors");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("http://qdrant.internal:6333/collections/nullpantry_vectors", url);

    const normalized_url = try backendUrl(std.testing.allocator, .{
        .backend = .qdrant,
        .base_url = "https://qdrant.example/api///",
    }, "collections/nullpantry_vectors");
    defer std.testing.allocator.free(normalized_url);
    try std.testing.expectEqualStrings("https://qdrant.example/api/collections/nullpantry_vectors", normalized_url);
}

test "vector HTTP backend paths encode configured collection segments" {
    const qdrant_path = try qdrantCollectionPath(std.testing.allocator, .{
        .backend = .qdrant,
        .collection = "team/vector 1?#",
    }, "/points/search");
    defer std.testing.allocator.free(qdrant_path);
    try std.testing.expectEqualStrings("/collections/team%2Fvector%201%3F%23/points/search", qdrant_path);

    const lancedb_path = try lancedbTablePath(std.testing.allocator, .{
        .backend = .lancedb_http,
        .collection = "table/name #1",
    }, "/vectors/upsert");
    defer std.testing.allocator.free(lancedb_path);
    try std.testing.expectEqualStrings("/v1/tables/table%2Fname%20%231/vectors/upsert", lancedb_path);

    const chroma_path = try chromaCollectionPath(std.testing.allocator, .{
        .backend = .chroma,
        .chroma_tenant = "team alpha",
        .chroma_database = "main/db",
        .collection = "collection #1",
    }, "/query");
    defer std.testing.allocator.free(chroma_path);
    try std.testing.expectEqualStrings("/api/v2/tenants/team%20alpha/databases/main%2Fdb/collections/collection%20%231/query", chroma_path);

    const weaviate_id = try weaviateObjectId(std.testing.allocator, "vec_atom_0");
    defer std.testing.allocator.free(weaviate_id);
    const weaviate_path = try weaviateObjectPath(std.testing.allocator, .{ .backend = .weaviate, .collection = "NullPantryVector" }, weaviate_id);
    defer std.testing.allocator.free(weaviate_path);
    try std.testing.expect(std.mem.startsWith(u8, weaviate_path, "/v1/objects/NullPantryVector/"));

    const opensearch_path = try opensearchDocumentPath(std.testing.allocator, .{ .backend = .opensearch, .collection = "np-index" }, "vec/atom #0");
    defer std.testing.allocator.free(opensearch_path);
    try std.testing.expectEqualStrings("/np-index/_doc/vec%2Fatom%20%230", opensearch_path);
}

test "new vector backend payloads preserve canonical ids and metadata" {
    const input = UpsertInput{
        .id = "vec_atom_0",
        .object_type = "memory_atom",
        .object_id = "atom",
        .chunk_ordinal = 7,
        .text = "hello",
        .scope = "project:nullpantry",
        .permissions_json = "[\"team:agents\"]",
        .heading_path_json = "[\"# NullPantry\"]",
        .embedding_json = "[1,0]",
        .model = "test",
        .dimensions = 2,
    };
    const object_id = try weaviateObjectId(std.testing.allocator, input.id);
    defer std.testing.allocator.free(object_id);
    const weaviate_payload = try weaviateUpsertPayload(std.testing.allocator, .{ .backend = .weaviate, .collection = "NullPantryVector" }, object_id, input);
    defer std.testing.allocator.free(weaviate_payload);
    try std.testing.expect(std.mem.indexOf(u8, weaviate_payload, "\"class\":\"NullPantryVector\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, weaviate_payload, "\"vector_id\":\"vec_atom_0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, weaviate_payload, "\"permissions_json\":\"[\\\"team:agents\\\"]\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, weaviate_payload, "\"vector\":[1,0]") != null);

    const chroma_payload = try chromaUpsertPayload(std.testing.allocator, input);
    defer std.testing.allocator.free(chroma_payload);
    try std.testing.expect(std.mem.indexOf(u8, chroma_payload, "\"ids\":[\"vec_atom_0\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, chroma_payload, "\"embeddings\":[[1,0]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, chroma_payload, "\"metadatas\":[{\"vector_id\":\"vec_atom_0\"") != null);

    const opensearch_payload = try opensearchUpsertPayload(std.testing.allocator, input);
    defer std.testing.allocator.free(opensearch_payload);
    try std.testing.expect(std.mem.indexOf(u8, opensearch_payload, "\"vector_id\":\"vec_atom_0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, opensearch_payload, "\"permissions\":[\"team:agents\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, opensearch_payload, "\"vector\":[1,0]") != null);

    const os_query = try opensearchSearchPayload(std.testing.allocator, "[1,0]", 3);
    defer std.testing.allocator.free(os_query);
    try std.testing.expect(std.mem.indexOf(u8, os_query, "\"knn\":{\"vector\":{\"vector\":[1,0],\"k\":3}}") != null);

    const chroma_delete = try chromaDeletePayload(std.testing.allocator, "vec_atom_0");
    defer std.testing.allocator.free(chroma_delete);
    try std.testing.expectEqualStrings("{\"ids\":[\"vec_atom_0\"]}", chroma_delete);

    try std.testing.expectEqualStrings("api-key", try apiKeyHeaderName(.{ .backend = .qdrant }));
    try std.testing.expectEqualStrings("x-chroma-token", try apiKeyHeaderName(.{ .backend = .chroma }));
    try std.testing.expectEqualStrings("Authorization", try apiKeyHeaderName(.{ .backend = .opensearch }));
    try std.testing.expectEqualStrings("X-API-Key", try apiKeyHeaderName(.{ .api_key_header = "X-API-Key" }));
    try std.testing.expectError(error.InvalidHttpHeaderName, apiKeyHeaderName(.{ .api_key_header = "Bad Header" }));

    const basic = try apiKeyHeaderValue(std.testing.allocator, "Authorization", "Basic abc");
    defer std.testing.allocator.free(basic);
    try std.testing.expectEqualStrings("Basic abc", basic);
    const bearer = try apiKeyHeaderValue(std.testing.allocator, "Authorization", "secret");
    defer std.testing.allocator.free(bearer);
    try std.testing.expectEqualStrings("Bearer secret", bearer);
    const chroma_header = try apiKeyHeaderValue(std.testing.allocator, "x-chroma-token", "ck");
    defer std.testing.allocator.free(chroma_header);
    try std.testing.expectEqualStrings("ck", chroma_header);
    try std.testing.expectError(error.InvalidHttpHeaderValue, apiKeyHeaderValue(std.testing.allocator, "Authorization", "bad\r\nX: y"));
    try std.testing.expectError(error.InvalidHttpHeaderValue, apiKeyHeaderValue(std.testing.allocator, "x-chroma-token", "bad\x7f"));
}

test "vector index config validates usable external setup" {
    try (Config{}).validateUsable();
    try std.testing.expectError(error.InvalidHttpHeaderName, (Config{ .api_key_header = "Bad Header" }).validateUsable());
    try std.testing.expectError(error.InvalidHttpHeaderValue, (Config{ .api_key = "bad\r\nX: y" }).validateUsable());
    try std.testing.expectError(error.InvalidVectorBackend, (Config{ .backend = .qdrant }).validateUsable());
    try std.testing.expectError(error.InvalidVectorBackend, (Config{ .backend = .qdrant, .base_url = " " }).validateUsable());
    try std.testing.expectError(error.InvalidVectorBackend, (Config{ .backend = .qdrant, .base_url = "http://127.0.0.1:6333", .timeout_secs = 0 }).validateUsable());
    try std.testing.expectError(error.InvalidVectorBackend, (Config{ .backend = .qdrant, .base_url = "http://127.0.0.1:6333", .timeout_secs = runtime_limits.max_timeout_secs + 1 }).validateUsable());
    try std.testing.expectError(error.InvalidVectorBackend, (Config{ .backend = .qdrant, .base_url = "http://127.0.0.1:6333", .circuit_breaker_threshold = 0 }).validateUsable());
    try std.testing.expectError(error.InvalidVectorBackend, (Config{ .backend = .qdrant, .base_url = "http://127.0.0.1:6333", .circuit_breaker_cooldown_ms = 0 }).validateUsable());
    try std.testing.expectError(error.InsecureRuntimeUrl, (Config{ .backend = .qdrant, .base_url = "http://qdrant.internal:6333" }).validateUsable());
    try std.testing.expectError(error.InvalidHttpHeaderName, (Config{ .backend = .qdrant, .base_url = "http://127.0.0.1:6333", .api_key_header = "X\r\nInjected" }).validateUsable());
    try (Config{ .backend = .qdrant, .base_url = "http://127.0.0.1:6333", .api_key_header = "X-API-Key" }).validateUsable();
    try (Config{ .backend = .qdrant, .base_url = "http://127.0.0.1:6333" }).validateUsable();

    try std.testing.expectError(error.InvalidVectorBackend, (Config{ .backend = .pgvector }).validateUsable());
    try std.testing.expectError(error.InvalidVectorBackend, (Config{ .backend = .pgvector, .postgres_url = " " }).validateUsable());
    try std.testing.expectError(error.InvalidVectorCollection, (Config{ .backend = .pgvector, .postgres_url = "postgres://localhost/nullpantry", .collection = "bad-name" }).validateUsable());
    try (Config{ .backend = .pgvector, .postgres_url = "postgres://localhost/nullpantry" }).validateUsable();

    try std.testing.expectError(error.InvalidVectorBackend, (Config{ .backend = .lancedb }).validateUsable());
    try std.testing.expectError(error.InvalidVectorBackend, (Config{ .backend = .lancedb, .lancedb_uri = ".nullpantry/lancedb", .lancedb_command = " " }).validateUsable());
    try (Config{ .backend = .lancedb, .lancedb_uri = ".nullpantry/lancedb" }).validateUsable();
    try std.testing.expectError(error.InvalidVectorBackend, (Config{ .backend = .lancedb_http, .base_url = "http://127.0.0.1:9000", .collection = " " }).validateUsable());
    try (Config{ .backend = .weaviate, .base_url = "http://127.0.0.1:8080", .collection = "NullPantryVector" }).validateUsable();
    try std.testing.expectError(error.InvalidVectorCollection, (Config{ .backend = .weaviate, .base_url = "http://127.0.0.1:8080", .collection = "bad-name" }).validateUsable());
    try (Config{ .backend = .chroma, .base_url = "http://127.0.0.1:8000", .collection = "collection-id" }).validateUsable();
    try std.testing.expectError(error.InvalidVectorBackend, (Config{ .backend = .chroma, .base_url = "http://127.0.0.1:8000", .collection = "collection-id", .chroma_tenant = " " }).validateUsable());
    try (Config{ .backend = .opensearch, .base_url = "http://127.0.0.1:9200", .collection = "np-index" }).validateUsable();
    try std.testing.expectError(error.InvalidVectorCollection, (Config{ .backend = .opensearch, .base_url = "http://127.0.0.1:9200", .collection = "BadIndex" }).validateUsable());
    try std.testing.expectError(error.InvalidVectorCollection, (Config{ .backend = .opensearch, .base_url = "http://127.0.0.1:9200", .collection = "_hidden" }).validateUsable());
    try std.testing.expectError(error.InvalidVectorCollection, (Config{ .backend = .opensearch, .base_url = "http://127.0.0.1:9200", .collection = "bad index" }).validateUsable());
    try std.testing.expectError(error.InvalidVectorCollection, (Config{ .backend = .opensearch, .base_url = "http://127.0.0.1:9200", .collection = "bad/index" }).validateUsable());
}

test "vector upsert validates identifiers and embedding dimensions before backend calls" {
    try validatePgIdentifier("nullpantry_vectors");
    try validatePgIdentifier("_vectors_01");
    try std.testing.expectError(error.InvalidVectorCollection, validatePgIdentifier(""));
    try std.testing.expectError(error.InvalidVectorCollection, validatePgIdentifier("1vectors"));
    try std.testing.expectError(error.InvalidVectorCollection, validatePgIdentifier("vectors;drop table memory_atoms"));
    try std.testing.expectError(error.InvalidVectorCollection, validatePgIdentifier("vectors-with-dash"));
    try validateOpenSearchIndexName("np-index_01");
    try std.testing.expectError(error.InvalidVectorCollection, validateOpenSearchIndexName(""));
    try std.testing.expectError(error.InvalidVectorCollection, validateOpenSearchIndexName("-np-index"));
    try std.testing.expectError(error.InvalidVectorCollection, validateOpenSearchIndexName("NP-index"));
    try std.testing.expectError(error.InvalidVectorCollection, validateOpenSearchIndexName("np,index"));
    try std.testing.expectError(error.InvalidVectorCollection, validateOpenSearchIndexName("np+index"));

    try std.testing.expectEqual(@as(usize, 3), try embeddingDimensionsFromJson(std.testing.allocator, "[1,0.5,-2]"));
    try std.testing.expectError(error.InvalidEmbeddingJson, embeddingDimensionsFromJson(std.testing.allocator, "{\"bad\":true}"));
    try std.testing.expectError(error.InvalidEmbeddingJson, embeddingDimensionsFromJson(std.testing.allocator, "[1,\"bad\"]"));
    try std.testing.expectError(error.InvalidVectorDimensions, validateUpsertInput(std.testing.allocator, .{
        .id = "bad_dims",
        .object_type = "memory_atom",
        .object_id = "mem_bad_dims",
        .chunk_ordinal = 0,
        .text = "bad dimensions",
        .scope = "public",
        .permissions_json = "[]",
        .embedding_json = "[1,0]",
        .model = null,
        .dimensions = 3,
    }));
    try std.testing.expectError(error.InvalidVectorId, upsert(std.testing.allocator, .{ .backend = .qdrant, .base_url = "http://127.0.0.1:6333" }, .{
        .id = "",
        .object_type = "memory_atom",
        .object_id = "mem_bad_id",
        .chunk_ordinal = 0,
        .text = "bad id",
        .scope = "public",
        .permissions_json = "[]",
        .embedding_json = "[1,0]",
        .model = null,
        .dimensions = 2,
    }));
    try std.testing.expectError(error.InvalidVectorDimensions, upsert(std.testing.allocator, .{ .backend = .lancedb, .lancedb_uri = ".zig-cache/tmp/unused-lancedb" }, .{
        .id = "bad_lancedb_dims",
        .object_type = "memory_atom",
        .object_id = "mem_bad_lancedb_dims",
        .chunk_ordinal = 0,
        .text = "bad lancedb dimensions",
        .scope = "public",
        .permissions_json = "[]",
        .embedding_json = "[1,0]",
        .model = null,
        .dimensions = 3,
    }));
}

test "vector search validates query before backend calls and honors zero limit" {
    const empty = try search(std.testing.allocator, .{ .backend = .qdrant, .base_url = "http://127.0.0.1:6333" }, "[1,0]", 0);
    defer freeCandidates(std.testing.allocator, empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);

    try std.testing.expectError(error.InvalidEmbeddingJson, search(std.testing.allocator, .{ .backend = .qdrant, .base_url = "http://127.0.0.1:6333" }, "[1,\"bad\"]", 3));
    try std.testing.expectError(error.InvalidEmbeddingJson, search(std.testing.allocator, .{ .backend = .lancedb, .lancedb_uri = ".zig-cache/tmp/unused-lancedb" }, "{\"bad\":true}", 3));
    try std.testing.expectError(error.InvalidVectorDimensions, search(std.testing.allocator, .{ .backend = .lancedb_http, .base_url = "http://127.0.0.1:9000" }, "[]", 3));
}

test "vector runtime rejects invalid upserts before opening backend circuit" {
    var runtime = try Runtime.init(.{
        .backend = .pgvector,
        .postgres_url = "postgres://unused",
        .circuit_breaker_threshold = 1,
        .circuit_breaker_cooldown_ms = 60_000,
    });
    defer runtime.deinit();

    const cfg = Config{ .backend = .pgvector, .postgres_url = "postgres://unused", .circuit_breaker_threshold = 1 };
    try std.testing.expectError(error.InvalidVectorDimensions, upsertWithRuntime(std.testing.allocator, cfg, &runtime, .{
        .id = "bad_dims",
        .object_type = "memory_atom",
        .object_id = "mem_bad_dims",
        .chunk_ordinal = 0,
        .text = "bad dimensions",
        .scope = "public",
        .permissions_json = "[]",
        .embedding_json = "[1,0]",
        .model = null,
        .dimensions = 3,
    }));
    try std.testing.expectEqual(CircuitState.closed, runtime.circuit_breaker.circuit.state);
    try std.testing.expect(runtime.pgvector_transport == null);
    try std.testing.expect(!runtime.pgvectorSchemaCached(cfg, "nullpantry_vectors", 3));

    var qdrant_runtime = try Runtime.init(.{
        .backend = .qdrant,
        .base_url = "http://127.0.0.1:6333",
        .circuit_breaker_threshold = 1,
    });
    defer qdrant_runtime.deinit();
    const qdrant_cfg = Config{ .backend = .qdrant, .base_url = "http://127.0.0.1:6333", .circuit_breaker_threshold = 1 };
    try std.testing.expectError(error.InvalidVectorDimensions, upsertWithRuntime(std.testing.allocator, qdrant_cfg, &qdrant_runtime, .{
        .id = "bad_qdrant_dims",
        .object_type = "memory_atom",
        .object_id = "mem_bad_qdrant_dims",
        .chunk_ordinal = 0,
        .text = "bad qdrant dimensions",
        .scope = "public",
        .permissions_json = "[]",
        .embedding_json = "[1,0]",
        .model = null,
        .dimensions = 3,
    }));
    try std.testing.expectEqual(CircuitState.closed, qdrant_runtime.circuit_breaker.circuit.state);
    try std.testing.expect(!qdrant_runtime.qdrantCollectionCached(qdrant_cfg, 3));
}

test "vector runtime rejects invalid search before opening backend circuit" {
    var runtime = try Runtime.init(.{
        .backend = .pgvector,
        .postgres_url = "postgres://unused",
        .circuit_breaker_threshold = 1,
    });
    defer runtime.deinit();

    const cfg = Config{ .backend = .pgvector, .postgres_url = "postgres://unused", .circuit_breaker_threshold = 1 };
    try std.testing.expectError(error.InvalidEmbeddingJson, searchWithRuntime(std.testing.allocator, cfg, &runtime, "[1,\"bad\"]", 3));
    try std.testing.expectEqual(CircuitState.closed, runtime.circuit_breaker.circuit.state);
    try std.testing.expect(runtime.pgvector_transport == null);

    var qdrant_runtime = try Runtime.init(.{
        .backend = .qdrant,
        .base_url = "http://127.0.0.1:6333",
        .circuit_breaker_threshold = 1,
    });
    defer qdrant_runtime.deinit();
    const qdrant_cfg = Config{ .backend = .qdrant, .base_url = "http://127.0.0.1:6333", .circuit_breaker_threshold = 1 };

    try std.testing.expectError(error.InvalidVectorDimensions, searchWithRuntime(std.testing.allocator, qdrant_cfg, &qdrant_runtime, "[]", 3));
    try std.testing.expectEqual(CircuitState.closed, qdrant_runtime.circuit_breaker.circuit.state);
    const empty = try searchWithRuntime(std.testing.allocator, qdrant_cfg, &qdrant_runtime, "[1,0]", 0);
    defer freeCandidates(std.testing.allocator, empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    try std.testing.expectEqual(CircuitState.closed, qdrant_runtime.circuit_breaker.circuit.state);
}

test "vector runtime rejects invalid delete before opening backend circuit" {
    var runtime = try Runtime.init(.{
        .backend = .pgvector,
        .postgres_url = "postgres://unused",
        .circuit_breaker_threshold = 1,
    });
    defer runtime.deinit();

    const cfg = Config{ .backend = .pgvector, .postgres_url = "postgres://unused", .circuit_breaker_threshold = 1 };
    try std.testing.expectError(error.InvalidVectorId, deleteWithRuntime(std.testing.allocator, cfg, &runtime, ""));
    try std.testing.expectEqual(CircuitState.closed, runtime.circuit_breaker.circuit.state);
    try std.testing.expect(runtime.pgvector_transport == null);

    var qdrant_runtime = try Runtime.init(.{
        .backend = .qdrant,
        .base_url = "http://127.0.0.1:6333",
        .circuit_breaker_threshold = 1,
    });
    defer qdrant_runtime.deinit();
    const qdrant_cfg = Config{ .backend = .qdrant, .base_url = "http://127.0.0.1:6333", .circuit_breaker_threshold = 1 };
    try std.testing.expectError(error.InvalidVectorId, deleteWithRuntime(std.testing.allocator, qdrant_cfg, &qdrant_runtime, ""));
    try std.testing.expectEqual(CircuitState.closed, qdrant_runtime.circuit_breaker.circuit.state);
}

test "vector runtime rejects config errors before opening backend circuit" {
    try std.testing.expectError(error.InsecureRuntimeUrl, Runtime.init(.{
        .backend = .qdrant,
        .base_url = "http://qdrant.internal:6333",
        .circuit_breaker_threshold = 1,
    }));

    var pgvector_runtime = try Runtime.init(.{
        .backend = .pgvector,
        .postgres_url = "postgres://unused",
        .circuit_breaker_threshold = 1,
    });
    defer pgvector_runtime.deinit();
    const pgvector_cfg = Config{
        .backend = .pgvector,
        .postgres_url = "postgres://unused",
        .collection = "vectors-with-dash",
        .circuit_breaker_threshold = 1,
    };
    try std.testing.expectError(error.InvalidVectorCollection, deleteWithRuntime(std.testing.allocator, pgvector_cfg, &pgvector_runtime, "vec_config"));
    try std.testing.expectEqual(CircuitState.closed, pgvector_runtime.circuit_breaker.circuit.state);
    try std.testing.expect(pgvector_runtime.pgvector_transport == null);

    var opensearch_runtime = try Runtime.init(.{
        .backend = .opensearch,
        .base_url = "http://127.0.0.1:9200",
        .circuit_breaker_threshold = 1,
    });
    defer opensearch_runtime.deinit();
    const opensearch_cfg = Config{
        .backend = .opensearch,
        .base_url = "http://127.0.0.1:9200",
        .collection = "BadIndex",
        .circuit_breaker_threshold = 1,
    };
    try std.testing.expectError(error.InvalidVectorCollection, deleteWithRuntime(std.testing.allocator, opensearch_cfg, &opensearch_runtime, "vec_config"));
    try std.testing.expectEqual(CircuitState.closed, opensearch_runtime.circuit_breaker.circuit.state);
}

test "vector runtime wrapper updates circuit state through runtime API" {
    var runtime = try Runtime.init(.{
        .backend = .qdrant,
        .base_url = "https://vector.example",
        .circuit_breaker_threshold = 1,
        .circuit_breaker_cooldown_ms = 60_000,
    });
    defer runtime.deinit();

    try std.testing.expect(runtime.allow());
    runtime.recordFailure();
    try std.testing.expectEqual(CircuitState.open, runtime.circuit_breaker.circuit.state);
    try std.testing.expect(!runtime.allow());
}

test "pgvector runtime schema cache tracks dimensions and clears" {
    var runtime = try Runtime.init(.{
        .backend = .pgvector,
        .postgres_url = "postgres://unused",
    });
    defer runtime.deinit();

    const cfg = Config{ .backend = .pgvector, .postgres_url = "postgres://one" };
    const other_url = Config{ .backend = .pgvector, .postgres_url = "postgres://two" };

    try std.testing.expect(!runtime.pgvectorSchemaCached(cfg, "vectors", 3));
    runtime.rememberPgvectorSchema(cfg, "vectors", 3);
    try std.testing.expect(runtime.pgvectorSchemaCached(cfg, "vectors", 3));
    try std.testing.expect(!runtime.pgvectorSchemaCached(cfg, "vectors", 4));
    try std.testing.expect(!runtime.pgvectorSchemaCached(cfg, "other_vectors", 3));
    try std.testing.expect(!runtime.pgvectorSchemaCached(other_url, "vectors", 3));

    runtime.clearPgvectorSchemaCache();
    try std.testing.expect(!runtime.pgvectorSchemaCached(cfg, "vectors", 3));

    runtime.rememberPgvectorSchema(cfg, "vectors", 5);
    runtime.deinit();
    try std.testing.expect(!runtime.pgvectorSchemaCached(cfg, "vectors", 5));
}

test "qdrant runtime collection cache tracks endpoint dimensions and clears" {
    var runtime = try Runtime.init(.{
        .backend = .qdrant,
        .base_url = "http://127.0.0.1:6333",
    });
    defer runtime.deinit();

    const cfg = Config{
        .backend = .qdrant,
        .base_url = "http://127.0.0.1:6333",
        .collection = "vectors",
    };
    const other_endpoint = Config{
        .backend = .qdrant,
        .base_url = "http://127.0.0.1:6334",
        .collection = "vectors",
    };
    const other_api_key = Config{
        .backend = .qdrant,
        .base_url = "http://127.0.0.1:6333",
        .api_key = "other",
        .collection = "vectors",
    };

    try std.testing.expect(!runtime.qdrantCollectionCached(cfg, 3));
    runtime.rememberQdrantCollection(cfg, 3);
    try std.testing.expect(runtime.qdrantCollectionCached(cfg, 3));
    try std.testing.expect(!runtime.qdrantCollectionCached(cfg, 4));
    try std.testing.expect(!runtime.qdrantCollectionCached(other_endpoint, 3));
    try std.testing.expect(!runtime.qdrantCollectionCached(other_api_key, 3));

    runtime.clearQdrantCollectionCache();
    try std.testing.expect(!runtime.qdrantCollectionCached(cfg, 3));
}

test "vector runtime circuit breaker opens and recovers through half open probe" {
    var breaker = CircuitBreaker.init(.{
        .backend = .qdrant,
        .base_url = "http://127.0.0.1:6333",
        .circuit_breaker_threshold = 2,
        .circuit_breaker_cooldown_ms = 10_000,
    });
    try std.testing.expect(breaker.allow());
    breaker.recordFailure();
    try std.testing.expectEqual(CircuitState.closed, breaker.circuit.state);
    breaker.recordFailure();
    try std.testing.expectEqual(CircuitState.open, breaker.circuit.state);
    try std.testing.expect(!breaker.allow());

    breaker.circuit.last_failure_ms = ids.nowMs() - 10_000;
    try std.testing.expect(breaker.allow());
    try std.testing.expectEqual(CircuitState.half_open, breaker.circuit.state);
    try std.testing.expect(!breaker.allow());

    breaker.recordSuccess();
    try std.testing.expectEqual(CircuitState.closed, breaker.circuit.state);
    try std.testing.expectEqual(@as(u32, 0), breaker.circuit.failure_count);
}

test "vector runtime wrapper fails fast while circuit is open" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var runtime = try Runtime.init(.{
        .backend = .lancedb,
        .lancedb_uri = ".zig-cache/tmp/nullpantry-missing-lancedb",
        .lancedb_command = "/definitely/not/a/nullpantry/vector/backend",
        .circuit_breaker_threshold = 1,
        .circuit_breaker_cooldown_ms = 60_000,
    });
    const cfg = Config{
        .backend = .lancedb,
        .lancedb_uri = ".zig-cache/tmp/nullpantry-missing-lancedb",
        .lancedb_command = "/definitely/not/a/nullpantry/vector/backend",
        .circuit_breaker_threshold = 1,
        .circuit_breaker_cooldown_ms = 60_000,
    };

    const first = searchWithRuntime(std.testing.allocator, cfg, &runtime, "[1,0]", 1);
    if (first) |candidates| {
        defer freeCandidates(std.testing.allocator, candidates);
        return error.ExpectedVectorBackendFailure;
    } else |_| {}
    try std.testing.expectEqual(CircuitState.open, runtime.circuit_breaker.circuit.state);
    try std.testing.expectError(error.VectorBackendCircuitOpen, searchWithRuntime(std.testing.allocator, cfg, &runtime, "[1,0]", 1));
}

test "lancedb sdk command contract builds lifecycle argv and payloads" {
    const cfg = Config{
        .backend = .lancedb,
        .lancedb_uri = ".zig-cache/tmp/lancedb-test",
        .lancedb_command = "/usr/local/bin/nullpantry-lancedb-adapter",
        .collection = "vectors",
        .timeout_secs = 2,
    };

    const upsert_argv = try lancedbCommandArgv(std.testing.allocator, cfg, "upsert", null);
    defer std.testing.allocator.free(upsert_argv);
    try std.testing.expectEqual(@as(usize, 4), upsert_argv.len);
    try std.testing.expectEqualStrings("/usr/local/bin/nullpantry-lancedb-adapter", upsert_argv[0]);
    try std.testing.expectEqualStrings("upsert", upsert_argv[1]);
    try std.testing.expectEqualStrings(".zig-cache/tmp/lancedb-test", upsert_argv[2]);
    try std.testing.expectEqualStrings("vectors", upsert_argv[3]);

    const search_argv = try lancedbCommandArgv(std.testing.allocator, cfg, "search", "3");
    defer std.testing.allocator.free(search_argv);
    try std.testing.expectEqual(@as(usize, 5), search_argv.len);
    try std.testing.expectEqualStrings("search", search_argv[1]);
    try std.testing.expectEqualStrings("3", search_argv[4]);

    const python_cfg = Config{
        .backend = .lancedb,
        .lancedb_uri = ".zig-cache/tmp/lancedb-test",
        .lancedb_command = "python3",
        .collection = "vectors",
    };
    const python_argv = try lancedbCommandArgv(std.testing.allocator, python_cfg, "reset", null);
    defer std.testing.allocator.free(python_argv);
    try std.testing.expectEqual(@as(usize, 6), python_argv.len);
    try std.testing.expectEqualStrings("python3", python_argv[0]);
    try std.testing.expectEqualStrings("-c", python_argv[1]);
    try std.testing.expect(python_argv[2].len > 1024);
    try std.testing.expectEqualStrings("reset", python_argv[3]);
    try std.testing.expectEqualStrings(".zig-cache/tmp/lancedb-test", python_argv[4]);
    try std.testing.expectEqualStrings("vectors", python_argv[5]);

    const payload = try lancedbUpsertPayload(std.testing.allocator, .{
        .id = "vec_contract",
        .object_type = "memory_atom",
        .object_id = "mem_contract",
        .chunk_ordinal = 0,
        .text = "lancedb sdk contract vector",
        .scope = "public",
        .permissions_json = "[\"public\"]",
        .embedding_json = "[1,0,0]",
        .model = "contract",
        .dimensions = 3,
    });
    defer std.testing.allocator.free(payload);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"rows\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"id\":\"vec_contract\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"vector\":[1,0,0]") != null);

    const delete_payload = try vectorDeletePayload(std.testing.allocator, "vec_contract");
    defer std.testing.allocator.free(delete_payload);
    try std.testing.expectEqualStrings("{\"vector_id\":\"vec_contract\",\"ids\":[\"vec_contract\"]}", delete_payload);

    const candidates = try parseCandidates(std.testing.allocator, "{\"matches\":[{\"id\":\"vec_contract\",\"score\":0.99}]}");
    defer freeCandidates(std.testing.allocator, candidates);
    try std.testing.expectEqual(@as(usize, 1), candidates.len);
    try std.testing.expectEqualStrings("vec_contract", candidates[0].vector_id);
    try std.testing.expectApproxEqAbs(@as(f32, 0.99), candidates[0].score, 0.0001);
}

test "pgvector live vector contract when configured" {
    const postgres_url = compat.process.getEnvVarOwned(std.testing.allocator, "NULLPANTRY_TEST_PGVECTOR_URL") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => {
            const required = compat.process.getEnvVarOwned(std.testing.allocator, "NULLPANTRY_REQUIRE_PGVECTOR_TEST") catch null;
            if (required) |value| {
                std.testing.allocator.free(value);
                return error.MissingPgvectorContractUrl;
            }
            return error.SkipZigTest;
        },
        else => return err,
    };
    defer std.testing.allocator.free(postgres_url);

    const table = try std.fmt.allocPrint(std.testing.allocator, "nullpantry_pgvector_{d}", .{ids.nowMs()});
    defer std.testing.allocator.free(table);
    const cfg = Config{ .backend = .pgvector, .postgres_url = postgres_url, .collection = table, .timeout_secs = 10 };
    defer reset(std.testing.allocator, cfg) catch {};

    const alpha = UpsertInput{
        .id = "vec_pg_alpha",
        .object_type = "memory_atom",
        .object_id = "mem_pg_alpha",
        .chunk_ordinal = 0,
        .text = "pgvector contract alpha",
        .scope = "public",
        .permissions_json = "[\"public\"]",
        .embedding_json = "[1,0,0]",
        .model = "contract",
        .dimensions = 3,
    };
    const beta = UpsertInput{
        .id = "vec_pg_beta",
        .object_type = "memory_atom",
        .object_id = "mem_pg_beta",
        .chunk_ordinal = 0,
        .text = "pgvector contract beta",
        .scope = "public",
        .permissions_json = "[\"public\"]",
        .embedding_json = "[0,1,0]",
        .model = "contract",
        .dimensions = 3,
    };
    try upsert(std.testing.allocator, cfg, alpha);
    try upsert(std.testing.allocator, cfg, beta);

    const candidates = try search(std.testing.allocator, cfg, "[1,0,0]", 2);
    defer freeCandidates(std.testing.allocator, candidates);
    try std.testing.expect(candidates.len >= 1);
    try std.testing.expectEqualStrings(alpha.id, candidates[0].vector_id);
    try std.testing.expect(candidates[0].score > 0.99);

    try delete(std.testing.allocator, cfg, alpha.id);
    const after_delete = try search(std.testing.allocator, cfg, "[1,0,0]", 2);
    defer freeCandidates(std.testing.allocator, after_delete);
    for (after_delete) |candidate| {
        try std.testing.expect(!std.mem.eql(u8, candidate.vector_id, alpha.id));
    }

    try reset(std.testing.allocator, cfg);
    const after_reset = try search(std.testing.allocator, cfg, "[0,1,0]", 2);
    defer freeCandidates(std.testing.allocator, after_reset);
    try std.testing.expectEqual(@as(usize, 0), after_reset.len);
}

test "qdrant live vector contract when configured" {
    const base_url = compat.process.getEnvVarOwned(std.testing.allocator, "NULLPANTRY_TEST_QDRANT_URL") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => {
            const required = compat.process.getEnvVarOwned(std.testing.allocator, "NULLPANTRY_REQUIRE_QDRANT_TEST") catch null;
            if (required) |value| {
                std.testing.allocator.free(value);
                return error.MissingQdrantContractUrl;
            }
            return error.SkipZigTest;
        },
        else => return err,
    };
    defer std.testing.allocator.free(base_url);

    const collection = try std.fmt.allocPrint(std.testing.allocator, "nullpantry_contract_{d}", .{ids.nowMs()});
    defer std.testing.allocator.free(collection);
    const cfg = Config{ .backend = .qdrant, .base_url = base_url, .collection = collection, .timeout_secs = 10 };
    const input = UpsertInput{
        .id = "vec_contract",
        .object_type = "memory_atom",
        .object_id = "mem_contract",
        .chunk_ordinal = 0,
        .text = "qdrant contract vector",
        .scope = "public",
        .permissions_json = "[\"public\"]",
        .embedding_json = "[1,0,0]",
        .model = "contract",
        .dimensions = 3,
    };
    try upsert(std.testing.allocator, cfg, input);
    const candidates = try search(std.testing.allocator, cfg, "[1,0,0]", 3);
    defer freeCandidates(std.testing.allocator, candidates);
    var found = false;
    for (candidates) |candidate| {
        if (std.mem.eql(u8, candidate.vector_id, input.id)) found = true;
    }
    try std.testing.expect(found);
    try delete(std.testing.allocator, cfg, input.id);
    const after_delete = try search(std.testing.allocator, cfg, "[1,0,0]", 3);
    defer freeCandidates(std.testing.allocator, after_delete);
    for (after_delete) |candidate| {
        try std.testing.expect(!std.mem.eql(u8, candidate.vector_id, input.id));
    }
    try reset(std.testing.allocator, cfg);
    try upsert(std.testing.allocator, cfg, input);
    const after_reset = try search(std.testing.allocator, cfg, "[1,0,0]", 3);
    defer freeCandidates(std.testing.allocator, after_reset);
    var found_after_reset = false;
    for (after_reset) |candidate| {
        if (std.mem.eql(u8, candidate.vector_id, input.id)) found_after_reset = true;
    }
    try std.testing.expect(found_after_reset);
}

test "lancedb live vector contract when configured" {
    var cfg = Config{ .backend = .local, .timeout_secs = 10 };
    var configured = false;

    if (compat.process.getEnvVarOwned(std.testing.allocator, "NULLPANTRY_TEST_LANCEDB_URI")) |uri| {
        cfg.backend = .lancedb;
        cfg.lancedb_uri = uri;
        configured = true;
    } else |_| {}
    defer if (cfg.lancedb_uri) |uri| std.testing.allocator.free(uri);

    if (!configured) {
        if (compat.process.getEnvVarOwned(std.testing.allocator, "NULLPANTRY_TEST_LANCEDB_URL")) |base_url| {
            cfg.backend = .lancedb_http;
            cfg.base_url = base_url;
            configured = true;
        } else |_| {}
    }
    defer if (cfg.base_url) |base_url| std.testing.allocator.free(base_url);

    var command_owned: ?[]u8 = null;
    if (compat.process.getEnvVarOwned(std.testing.allocator, "NULLPANTRY_TEST_LANCEDB_COMMAND")) |command| {
        command_owned = command;
        cfg.lancedb_command = command;
    } else |_| {}
    defer if (command_owned) |command| std.testing.allocator.free(command);

    if (!configured) {
        const required = compat.process.getEnvVarOwned(std.testing.allocator, "NULLPANTRY_REQUIRE_LANCEDB_TEST") catch null;
        if (required) |value| {
            std.testing.allocator.free(value);
            return error.MissingLanceDbContractUrl;
        }
        return error.SkipZigTest;
    }
    const table = try std.fmt.allocPrint(std.testing.allocator, "nullpantry_contract_{d}", .{ids.nowMs()});
    defer std.testing.allocator.free(table);
    cfg.collection = table;
    const input = UpsertInput{
        .id = "vec_contract",
        .object_type = "memory_atom",
        .object_id = "mem_contract",
        .chunk_ordinal = 0,
        .text = "lancedb compatible contract vector",
        .scope = "public",
        .permissions_json = "[\"public\"]",
        .embedding_json = "[1,0,0]",
        .model = "contract",
        .dimensions = 3,
    };
    try upsert(std.testing.allocator, cfg, input);
    const candidates = try search(std.testing.allocator, cfg, "[1,0,0]", 3);
    defer freeCandidates(std.testing.allocator, candidates);
    var found = false;
    for (candidates) |candidate| {
        if (std.mem.eql(u8, candidate.vector_id, input.id)) found = true;
    }
    try std.testing.expect(found);
    try delete(std.testing.allocator, cfg, input.id);
    const after_delete = try search(std.testing.allocator, cfg, "[1,0,0]", 3);
    defer freeCandidates(std.testing.allocator, after_delete);
    for (after_delete) |candidate| {
        try std.testing.expect(!std.mem.eql(u8, candidate.vector_id, input.id));
    }
    try reset(std.testing.allocator, cfg);
    try upsert(std.testing.allocator, cfg, input);
    const after_reset = try search(std.testing.allocator, cfg, "[1,0,0]", 3);
    defer freeCandidates(std.testing.allocator, after_reset);
    var found_after_reset = false;
    for (after_reset) |candidate| {
        if (std.mem.eql(u8, candidate.vector_id, input.id)) found_after_reset = true;
    }
    try std.testing.expect(found_after_reset);
}
