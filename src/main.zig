const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const compat = @import("compat.zig");
const api = @import("api.zig");
const auth = @import("auth.zig");
const ids = @import("ids.zig");
const store_mod = @import("store.zig");
const store_config = @import("store_config.zig");
const worker = @import("worker.zig");
const agent_memory_config = @import("agent_memory_config.zig");
const redis_config = @import("redis_config.zig");
const vector_runtime = @import("vector_runtime.zig");
const vector_mod = @import("vector.zig");
const analytics_runtime = @import("analytics_runtime.zig");
const lucid_runtime = @import("lucid_runtime.zig");
const graph_runtime = @import("graph_runtime.zig");
const providers = @import("providers.zig");
const lifecycle = @import("lifecycle.zig");
const retrieval = @import("retrieval.zig");
const json_util = @import("json_util.zig");
const net_security = @import("net_security.zig");
const http_request = @import("http_request.zig");
const runtime_config = @import("runtime_config.zig");
const runtime_limits = @import("runtime_limits.zig");
const bounded_int = @import("bounded_int.zig");
const circuit_breaker = @import("circuit_breaker.zig");

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;
extern "c" fn fstat(fd: std.c.fd_t, buf: *std.c.Stat) c_int;
extern "c" fn geteuid() std.c.uid_t;

const default_port: u16 = 8765;
const max_request_size: usize = 2 * 1024 * 1024;
const max_header_bytes: usize = 64 * 1024;
const max_header_lines: usize = 128;
const socket_timeout_secs: i64 = 30;
const max_active_connections: usize = 128;
const request_limits = http_request.Limits{
    .max_request_bytes = max_request_size,
    .max_header_bytes = max_header_bytes,
    .max_header_lines = max_header_lines,
};

const RuntimeConfig = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = default_port,
    instance_id: []const u8 = "nullpantry",
    db_path: [:0]const u8 = ".nullpantry/nullpantry.db",
    auth: runtime_config.AuthConfig = .{},
    actor: runtime_config.PrincipalConfig = .{},
    worker: runtime_config.PrincipalConfig = runtime_config.worker_principal,
    provider: runtime_config.ProviderConfig = .{},
    retrieval: runtime_config.RetrievalConfig = .{},
    filesystem: runtime_config.FilesystemConfig = .{},
    stores: runtime_config.RuntimeStoresConfig = .{},
    worker_interval_ms: u64 = 5000,
    run_legacy_compat_cleanup: bool = false,
    home_defaults: RuntimeHomeDefaults = .{},

    fn deinit(self: *RuntimeConfig, allocator: std.mem.Allocator) void {
        self.home_defaults.deinit(allocator);
        self.* = .{};
    }
};

const RuntimeHomeDefaults = struct {
    home_root: ?[]u8 = null,
    db_path: ?[:0]u8 = null,
    filesystem_root: ?[]u8 = null,
    markdown_workspace: ?[]u8 = null,
    holographic_db_path: ?[]u8 = null,
    lancedb_uri: ?[]u8 = null,
    lucid_workspace: ?[]u8 = null,

    fn deinit(self: *RuntimeHomeDefaults, allocator: std.mem.Allocator) void {
        if (self.home_root) |path| allocator.free(path);
        if (self.db_path) |path| allocator.free(path);
        if (self.filesystem_root) |path| allocator.free(path);
        if (self.markdown_workspace) |path| allocator.free(path);
        if (self.holographic_db_path) |path| allocator.free(path);
        if (self.lancedb_uri) |path| allocator.free(path);
        if (self.lucid_workspace) |path| allocator.free(path);
        self.* = .{};
    }
};

const ServerState = struct {
    allocator: std.mem.Allocator,
    store: *store_mod.Store,
    cfg: RuntimeConfig,
    provider_runtime: *providers.ProviderRuntime,
    active_connections: std.atomic.Value(usize) = .init(0),
};

pub fn main(init: std.process.Init) !void {
    compat.initProcess(init);
    const allocator = std.heap.smp_allocator;

    const args = try compat.process.argsAlloc(allocator);
    defer compat.process.argsFree(allocator, args);

    const cfg = try parseArgs(allocator, args);
    try validateCompiledEngineProfile(allocator, cfg);
    if (cfg.home_defaults.home_root) |home_root| try ensureRuntimeHomeRoot(home_root);
    if (cfg.stores.records_backend == .sqlite) try ensureParentDirForFile(cfg.db_path);

    const store_options = store_config.StoreOptions{
        .agent_memory = .{
            .backend = cfg.stores.agent_memory_backend,
            .memory = cfg.stores.memory,
            .markdown = cfg.stores.markdown_agent_memory,
            .redis = cfg.stores.redis,
            .clickhouse = cfg.stores.clickhouse_agent_memory,
            .api = cfg.stores.api_agent_memory,
            .holographic = cfg.stores.holographic_agent_memory,
        },
        .agent_memory_stores = cfg.stores.agent_memory_stores,
        .vector_backend = cfg.stores.vector_backend,
        .vector_stores = cfg.stores.vector_stores,
        .graph_projection = cfg.stores.graph_projection,
        .analytics_backend = cfg.stores.analytics_backend,
        .lucid_projection = cfg.stores.lucid_projection,
        .run_legacy_compat_cleanup = cfg.run_legacy_compat_cleanup,
    };
    var store = switch (cfg.stores.records_backend) {
        .sqlite => try store_mod.Store.initSQLiteWithOptions(allocator, cfg.db_path, store_options),
        .postgres => try store_mod.Store.initPostgresWithOptions(allocator, cfg.stores.postgres_url orelse return error.MissingPostgresUrl, store_options),
    };
    defer store.deinit();

    const addr = try std.Io.net.IpAddress.resolve(compat.io(), cfg.host, cfg.port);
    var server = try addr.listen(compat.io(), .{ .reuse_address = true });
    defer server.deinit(compat.io());

    std.debug.print("nullpantry v{s}\n", .{build_options.version});
    std.debug.print("listening on http://{s}:{d}\n", .{ cfg.host, cfg.port });
    std.debug.print("instance id: {s}\n", .{cfg.instance_id});
    std.debug.print("storage backend: {s}\n", .{@tagName(cfg.stores.records_backend)});
    std.debug.print("agent memory store: {s}\n", .{cfg.stores.agent_memory_backend.name()});
    std.debug.print("named agent memory stores: {d}\n", .{cfg.stores.agent_memory_stores.len});
    std.debug.print("vector index: {s}\n", .{cfg.stores.vector_backend.backend.name()});
    std.debug.print("named vector stores: {d}\n", .{cfg.stores.vector_stores.len});
    std.debug.print("chunker: strategy={s} max_chars={d} overlap_chars={d}\n", .{ cfg.retrieval.chunker.strategy.name(), cfg.retrieval.chunker.max_chars, cfg.retrieval.chunker.overlap_chars });
    std.debug.print("graph projection: {s}\n", .{cfg.stores.graph_projection.backend.name()});
    std.debug.print("analytics backend: {s}\n", .{cfg.stores.analytics_backend.backend.name()});
    std.debug.print("lucid projection: {s}\n", .{if (cfg.stores.lucid_projection.isEnabled()) "enabled" else "disabled"});

    var provider_runtime = try providers.ProviderRuntime.init(allocator, embeddingConfigFromRuntime(cfg), completionConfigFromRuntime(cfg), .{
        .failure_threshold = cfg.provider.circuit_failure_threshold,
        .cooldown_ms = cfg.provider.circuit_cooldown_ms,
    });
    defer provider_runtime.deinit(allocator);

    var state = ServerState{ .allocator = allocator, .store = &store, .cfg = cfg, .provider_runtime = &provider_runtime };
    if (cfg.worker_interval_ms > 0) {
        const worker_thread = try std.Thread.spawn(.{}, workerLoop, .{&state});
        worker_thread.detach();
        std.debug.print("worker interval: {d}ms\n", .{cfg.worker_interval_ms});
    }
    while (true) {
        const conn = server.accept(compat.io()) catch |err| {
            std.debug.print("accept error: {}\n", .{err});
            continue;
        };
        const active = state.active_connections.fetchAdd(1, .acq_rel);
        if (active >= max_active_connections) {
            _ = state.active_connections.fetchSub(1, .acq_rel);
            var close_conn = conn;
            close_conn.close(compat.io());
            std.debug.print("event=connection_rejected reason=max_active_connections limit={d}\n", .{max_active_connections});
            continue;
        }
        const thread = std.Thread.spawn(.{}, handleConnection, .{ &state, conn }) catch |err| {
            _ = state.active_connections.fetchSub(1, .acq_rel);
            var close_conn = conn;
            close_conn.close(compat.io());
            std.debug.print("spawn error: {}\n", .{err});
            continue;
        };
        thread.detach();
    }
}

fn handleConnection(state: *ServerState, conn_value: std.Io.net.Stream) void {
    var conn = conn_value;
    defer conn.close(compat.io());
    defer _ = state.active_connections.fetchSub(1, .acq_rel);
    setSocketTimeouts(&conn);

    var arena = std.heap.ArenaAllocator.init(state.allocator);
    defer arena.deinit();
    const req_alloc = arena.allocator();
    const request_id = ids.make(req_alloc, "req_") catch "req_error";

    const raw = http_request.read(req_alloc, &conn, request_limits) catch |err| {
        std.debug.print("request_id={s} event=request_read_error error={}\n", .{ request_id, err });
        return;
    } orelse return;

    const first_line_end = std.mem.indexOf(u8, raw, "\r\n") orelse return;
    const first_line = raw[0..first_line_end];
    var parts = std.mem.splitScalar(u8, first_line, ' ');
    const method = parts.next() orelse return;
    const target = parts.next() orelse return;
    const body = json_util.extractBody(raw);

    var ctx = api.Context{
        .allocator = req_alloc,
        .store = state.store,
        .feed_instance_id = state.cfg.instance_id,
        .required_token = state.cfg.auth.required_token,
        .token_principals_json = state.cfg.auth.token_principals_json,
        .actor_scopes_json = state.cfg.actor.scopes_json,
        .actor_capabilities_json = state.cfg.actor.capabilities_json,
        .provider = providerConfigFromRuntime(state.cfg).withRuntime(state.provider_runtime),
        .filesystem_root = state.cfg.filesystem.root,
        .trust_actor_headers = state.cfg.auth.trust_actor_headers,
        .adaptive_keyword_max_tokens = state.cfg.retrieval.adaptive_keyword_max_tokens,
        .adaptive_vector_min_tokens = state.cfg.retrieval.adaptive_vector_min_tokens,
        .retrieval_rollout_policy = state.cfg.retrieval.rollout_policy,
        .chunker = state.cfg.retrieval.chunker,
    };
    const response = api.handleRequest(&ctx, method, target, body, raw);

    const log_target_path = http_request.logTargetPath(target);
    const log_target_suffix = http_request.logTargetSuffix(target);
    std.debug.print("request_id={s} method={s} target={s}{s} status=\"{s}\"\n", .{ request_id, method, log_target_path, log_target_suffix, response.status });

    var header_buf: [1024]u8 = undefined;
    const header = std.fmt.bufPrint(
        &header_buf,
        "HTTP/1.1 {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nX-Request-Id: {s}\r\nConnection: close\r\n\r\n",
        .{ response.status, response.body.len, request_id },
    ) catch return;
    var write_buffer: [4096]u8 = undefined;
    var writer = conn.writer(compat.io(), &write_buffer);
    writer.interface.writeAll(header) catch return;
    writer.interface.writeAll(response.body) catch return;
    writer.interface.flush() catch return;
}

fn workerLoop(state: *ServerState) void {
    while (true) {
        std.Io.sleep(compat.io(), workerIntervalDuration(state.cfg.worker_interval_ms), .awake) catch {};
        var arena = std.heap.ArenaAllocator.init(state.allocator);
        const result = worker.runOnce(arena.allocator(), state.store, .{
            .scopes_json = state.cfg.worker.scopes_json,
            .capabilities_json = state.cfg.worker.capabilities_json,
            .job_limit = 25,
            .outbox_limit = 250,
            .provider = providerConfigFromRuntime(state.cfg).withRuntime(state.provider_runtime),
            .chunker = state.cfg.retrieval.chunker,
        }) catch |err| {
            arena.deinit();
            std.debug.print("event=worker_error error={}\n", .{err});
            continue;
        };
        arena.deinit();
        if (result.jobs_checked > 0 or result.vector_outbox_processed > 0 or result.vector_outbox_failed > 0) {
            std.debug.print("event=worker_run jobs_checked={d} jobs_succeeded={d} jobs_failed={d} vector_outbox_processed={d} vector_outbox_failed={d}\n", .{ result.jobs_checked, result.jobs_succeeded, result.jobs_failed, result.vector_outbox_processed, result.vector_outbox_failed });
        }
    }
}

fn workerIntervalDuration(interval_ms: u64) std.Io.Duration {
    const max_ms: u64 = @intCast(std.math.maxInt(i64));
    return .fromMilliseconds(@intCast(@min(interval_ms, max_ms)));
}

fn setSocketTimeouts(conn: *std.Io.net.Stream) void {
    switch (builtin.target.os.tag) {
        .windows => {},
        else => {
            const timeout = std.posix.timeval{ .sec = socket_timeout_secs, .usec = 0 };
            std.posix.setsockopt(conn.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {};
            std.posix.setsockopt(conn.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&timeout)) catch {};
        },
    }
}

const max_runtime_config_file_bytes: usize = 1024 * 1024;
const home_default_config_file = "nullpantry.json";
const home_default_db_file = "nullpantry.db";
const home_default_filesystem_dir = "files";
const home_default_markdown_dir = "markdown";
const home_default_holographic_db_file = "holographic_memory.db";
const home_default_lancedb_dir = "lancedb";
const home_default_lucid_dir = "lucid";

fn isRuntimeConfigEnvName(name: []const u8) bool {
    return runtime_config_env_names.has(name);
}

const runtime_config_env_names = std.StaticStringMap(void).initComptime(.{
    .{"NULLPANTRY_ADAPTIVE_KEYWORD_MAX_TOKENS"},
    .{"NULLPANTRY_ADAPTIVE_VECTOR_MIN_TOKENS"},
    .{"NULLPANTRY_AGENT_MEMORY_API_ALLOW_INSECURE_HTTP"},
    .{"NULLPANTRY_AGENT_MEMORY_API_CAPABILITIES"},
    .{"NULLPANTRY_AGENT_MEMORY_API_MAX_RESPONSE_BYTES"},
    .{"NULLPANTRY_AGENT_MEMORY_API_PROFILE"},
    .{"NULLPANTRY_AGENT_MEMORY_API_SCOPES"},
    .{"NULLPANTRY_AGENT_MEMORY_API_STORAGE"},
    .{"NULLPANTRY_AGENT_MEMORY_API_TIMEOUT_SECS"},
    .{"NULLPANTRY_AGENT_MEMORY_API_TOKEN"},
    .{"NULLPANTRY_AGENT_MEMORY_API_URL"},
    .{"NULLPANTRY_AGENT_MEMORY_BACKEND"},
    .{"NULLPANTRY_AGENT_MEMORY_BYTEROVER_COMMAND"},
    .{"NULLPANTRY_AGENT_MEMORY_BYTEROVER_PROJECT_DIR"},
    .{"NULLPANTRY_AGENT_MEMORY_BYTEROVER_USE_SWARM"},
    .{"NULLPANTRY_AGENT_MEMORY_CLICKHOUSE_ALLOW_INSECURE_HTTP"},
    .{"NULLPANTRY_AGENT_MEMORY_CLICKHOUSE_API_KEY"},
    .{"NULLPANTRY_AGENT_MEMORY_CLICKHOUSE_MAX_RESPONSE_BYTES"},
    .{"NULLPANTRY_AGENT_MEMORY_CLICKHOUSE_TABLE"},
    .{"NULLPANTRY_AGENT_MEMORY_CLICKHOUSE_TIMEOUT_SECS"},
    .{"NULLPANTRY_AGENT_MEMORY_CLICKHOUSE_URL"},
    .{"NULLPANTRY_AGENT_MEMORY_FALKORDB_API_KEY"},
    .{"NULLPANTRY_AGENT_MEMORY_FALKORDB_GRAPH"},
    .{"NULLPANTRY_AGENT_MEMORY_FALKORDB_URL"},
    .{"NULLPANTRY_AGENT_MEMORY_HINDSIGHT_API_KEY"},
    .{"NULLPANTRY_AGENT_MEMORY_HINDSIGHT_BANK_ID"},
    .{"NULLPANTRY_AGENT_MEMORY_HINDSIGHT_URL"},
    .{"NULLPANTRY_AGENT_MEMORY_HOLOGRAPHIC_DB_PATH"},
    .{"NULLPANTRY_AGENT_MEMORY_HONCHO_API_KEY"},
    .{"NULLPANTRY_AGENT_MEMORY_HONCHO_URL"},
    .{"NULLPANTRY_AGENT_MEMORY_HONCHO_WORKSPACE_ID"},
    .{"NULLPANTRY_AGENT_MEMORY_MARKDOWN_MAX_FILE_BYTES"},
    .{"NULLPANTRY_AGENT_MEMORY_MARKDOWN_WORKSPACE"},
    .{"NULLPANTRY_AGENT_MEMORY_MEM0_API_KEY"},
    .{"NULLPANTRY_AGENT_MEMORY_MEM0_URL"},
    .{"NULLPANTRY_AGENT_MEMORY_OPENVIKING_API_KEY"},
    .{"NULLPANTRY_AGENT_MEMORY_OPENVIKING_URL"},
    .{"NULLPANTRY_AGENT_MEMORY_RETAINDB_API_KEY"},
    .{"NULLPANTRY_AGENT_MEMORY_RETAINDB_PROJECT"},
    .{"NULLPANTRY_AGENT_MEMORY_RETAINDB_URL"},
    .{"NULLPANTRY_AGENT_MEMORY_STORES"},
    .{"NULLPANTRY_AGENT_MEMORY_SUPERMEMORY_API_KEY"},
    .{"NULLPANTRY_AGENT_MEMORY_SUPERMEMORY_URL"},
    .{"NULLPANTRY_AGENT_MEMORY_ZEP_API_KEY"},
    .{"NULLPANTRY_AGENT_MEMORY_ZEP_GRAPH_ID"},
    .{"NULLPANTRY_AGENT_MEMORY_ZEP_URL"},
    .{"NULLPANTRY_ALLOW_NO_AUTH_NON_LOOPBACK"},
    .{"NULLPANTRY_ANALYTICS_ALLOW_INSECURE_HTTP"},
    .{"NULLPANTRY_ANALYTICS_API_KEY"},
    .{"NULLPANTRY_ANALYTICS_BACKEND"},
    .{"NULLPANTRY_ANALYTICS_BASE_URL"},
    .{"NULLPANTRY_ANALYTICS_TABLE"},
    .{"NULLPANTRY_ANALYTICS_TIMEOUT_SECS"},
    .{"NULLPANTRY_BACKEND"},
    .{"NULLPANTRY_BYTEROVER_COMMAND"},
    .{"NULLPANTRY_BYTEROVER_PROJECT_DIR"},
    .{"NULLPANTRY_BYTEROVER_USE_SWARM"},
    .{"NULLPANTRY_CAPABILITIES"},
    .{"NULLPANTRY_CHROMA_COLLECTION"},
    .{"NULLPANTRY_CHROMA_COLLECTION_ID"},
    .{"NULLPANTRY_CHROMA_DATABASE"},
    .{"NULLPANTRY_CHROMA_TENANT"},
    .{"NULLPANTRY_CHROMA_TOKEN"},
    .{"NULLPANTRY_CHROMA_URL"},
    .{"NULLPANTRY_CHUNK_MAX_CHARS"},
    .{"NULLPANTRY_CHUNK_MAX_TOKENS"},
    .{"NULLPANTRY_CHUNK_OVERLAP_CHARS"},
    .{"NULLPANTRY_CHUNK_STRATEGY"},
    .{"NULLPANTRY_CLICKHOUSE_AGENT_MEMORY_URL"},
    .{"NULLPANTRY_CLICKHOUSE_ALLOW_INSECURE_HTTP"},
    .{"NULLPANTRY_CLICKHOUSE_API_KEY"},
    .{"NULLPANTRY_CLICKHOUSE_TABLE"},
    .{"NULLPANTRY_CLICKHOUSE_URL"},
    .{"NULLPANTRY_DATABASE_URL"},
    .{"NULLPANTRY_DB_PATH"},
    .{"NULLPANTRY_EMBEDDING_ALLOW_INSECURE_HTTP"},
    .{"NULLPANTRY_EMBEDDING_API_KEY"},
    .{"NULLPANTRY_EMBEDDING_BASE_URL"},
    .{"NULLPANTRY_EMBEDDING_DIMENSIONS"},
    .{"NULLPANTRY_EMBEDDING_FALLBACKS"},
    .{"NULLPANTRY_EMBEDDING_MAX_RESPONSE_BYTES"},
    .{"NULLPANTRY_EMBEDDING_MODEL"},
    .{"NULLPANTRY_EMBEDDING_PROVIDER"},
    .{"NULLPANTRY_EMBEDDING_ROUTES"},
    .{"NULLPANTRY_EMBEDDING_SEND_DIMENSIONS"},
    .{"NULLPANTRY_FALKORDB_API_KEY"},
    .{"NULLPANTRY_FALKORDB_GRAPH"},
    .{"NULLPANTRY_FALKORDB_URL"},
    .{"NULLPANTRY_FEED_INSTANCE_ID"},
    .{"NULLPANTRY_FILESYSTEM_ROOT"},
    .{"NULLPANTRY_GRAPH_ALLOW_INSECURE_HTTP"},
    .{"NULLPANTRY_GRAPH_API_KEY"},
    .{"NULLPANTRY_GRAPH_BACKEND"},
    .{"NULLPANTRY_GRAPH_BASE_URL"},
    .{"NULLPANTRY_GRAPH_DATABASE"},
    .{"NULLPANTRY_GRAPH_FALKORDB_API_KEY"},
    .{"NULLPANTRY_GRAPH_FALKORDB_NAME"},
    .{"NULLPANTRY_GRAPH_FALKORDB_URL"},
    .{"NULLPANTRY_GRAPH_NAME"},
    .{"NULLPANTRY_GRAPH_PROJECT_SCOPES"},
    .{"NULLPANTRY_GRAPH_TIMEOUT_SECS"},
    .{"NULLPANTRY_HINDSIGHT_API_KEY"},
    .{"NULLPANTRY_HINDSIGHT_BANK_ID"},
    .{"NULLPANTRY_HINDSIGHT_URL"},
    .{"NULLPANTRY_HOLOGRAPHIC_DB_PATH"},
    .{"NULLPANTRY_HOLOGRAPHIC_DEFAULT_TRUST"},
    .{"NULLPANTRY_HOLOGRAPHIC_TRUST_PENALTY"},
    .{"NULLPANTRY_HOLOGRAPHIC_TRUST_REWARD"},
    .{"NULLPANTRY_HONCHO_API_KEY"},
    .{"NULLPANTRY_HONCHO_URL"},
    .{"NULLPANTRY_HONCHO_WORKSPACE_ID"},
    .{"NULLPANTRY_HOST"},
    .{"NULLPANTRY_INSTANCE_ID"},
    .{"NULLPANTRY_LANCEDB_ALLOW_INSECURE_HTTP"},
    .{"NULLPANTRY_LANCEDB_API_KEY"},
    .{"NULLPANTRY_LANCEDB_COMMAND"},
    .{"NULLPANTRY_LANCEDB_TABLE"},
    .{"NULLPANTRY_LANCEDB_URI"},
    .{"NULLPANTRY_LANCEDB_URL"},
    .{"NULLPANTRY_LLM_ALLOW_INSECURE_HTTP"},
    .{"NULLPANTRY_LLM_API_KEY"},
    .{"NULLPANTRY_LLM_BASE_URL"},
    .{"NULLPANTRY_LLM_MAX_RESPONSE_BYTES"},
    .{"NULLPANTRY_LLM_MODEL"},
    .{"NULLPANTRY_LUCID_COMMAND"},
    .{"NULLPANTRY_LUCID_ENABLED"},
    .{"NULLPANTRY_LUCID_LOCAL_HIT_THRESHOLD"},
    .{"NULLPANTRY_LUCID_PERMISSIONS"},
    .{"NULLPANTRY_LUCID_PROJECT_SCOPES"},
    .{"NULLPANTRY_LUCID_RESULT_SCOPE"},
    .{"NULLPANTRY_LUCID_TOKEN_BUDGET"},
    .{"NULLPANTRY_LUCID_WORKSPACE"},
    .{"NULLPANTRY_MARKDOWN_WORKSPACE"},
    .{"NULLPANTRY_MEM0_API_KEY"},
    .{"NULLPANTRY_MEM0_URL"},
    .{"NULLPANTRY_MEMORY_LRU_MAX_BYTES"},
    .{"NULLPANTRY_MEMORY_LRU_MAX_ENTRIES"},
    .{"NULLPANTRY_MEMORY_LRU_MAX_MESSAGES"},
    .{"NULLPANTRY_MEMORY_LRU_MAX_USAGE_ENTRIES"},
    .{"NULLPANTRY_MEMORY_LRU_TTL_SECONDS"},
    .{"NULLPANTRY_NEO4J_API_KEY"},
    .{"NULLPANTRY_NEO4J_DATABASE"},
    .{"NULLPANTRY_NEO4J_URL"},
    .{"NULLPANTRY_OPENSEARCH_API_KEY"},
    .{"NULLPANTRY_OPENSEARCH_INDEX"},
    .{"NULLPANTRY_OPENSEARCH_URL"},
    .{"NULLPANTRY_OPENVIKING_API_KEY"},
    .{"NULLPANTRY_OPENVIKING_URL"},
    .{"NULLPANTRY_PGVECTOR_TABLE"},
    .{"NULLPANTRY_PGVECTOR_URL"},
    .{"NULLPANTRY_PORT"},
    .{"NULLPANTRY_PROVIDER_ALLOW_INSECURE_HTTP"},
    .{"NULLPANTRY_PROVIDER_CIRCUIT_COOLDOWN_MS"},
    .{"NULLPANTRY_PROVIDER_CIRCUIT_FAILURE_THRESHOLD"},
    .{"NULLPANTRY_PROVIDER_MAX_RESPONSE_BYTES"},
    .{"NULLPANTRY_PROVIDER_TIMEOUT_SECS"},
    .{"NULLPANTRY_QDRANT_ALLOW_INSECURE_HTTP"},
    .{"NULLPANTRY_QDRANT_API_KEY"},
    .{"NULLPANTRY_QDRANT_API_KEY_HEADER"},
    .{"NULLPANTRY_QDRANT_COLLECTION"},
    .{"NULLPANTRY_QDRANT_URL"},
    .{"NULLPANTRY_RECORDS_BACKEND"},
    .{"NULLPANTRY_REDIS_KEY_PREFIX"},
    .{"NULLPANTRY_REDIS_TTL_SECONDS"},
    .{"NULLPANTRY_REDIS_URL"},
    .{"NULLPANTRY_RETAINDB_API_KEY"},
    .{"NULLPANTRY_RETAINDB_PROJECT"},
    .{"NULLPANTRY_RETAINDB_URL"},
    .{"NULLPANTRY_RETRIEVAL_CANARY_PERCENT"},
    .{"NULLPANTRY_RETRIEVAL_ROLLOUT_BLOCKED_CAPABILITIES"},
    .{"NULLPANTRY_RETRIEVAL_ROLLOUT_BLOCKED_SCOPES"},
    .{"NULLPANTRY_RETRIEVAL_ROLLOUT_DISABLED"},
    .{"NULLPANTRY_RETRIEVAL_ROLLOUT_MODE"},
    .{"NULLPANTRY_RETRIEVAL_ROLLOUT_PERCENT"},
    .{"NULLPANTRY_RETRIEVAL_ROLLOUT_REQUIRED_CAPABILITIES"},
    .{"NULLPANTRY_RETRIEVAL_ROLLOUT_REQUIRED_SCOPES"},
    .{"NULLPANTRY_RETRIEVAL_ROLLOUT_SALT"},
    .{"NULLPANTRY_RETRIEVAL_ROLLOUT_TARGET_SCOPES"},
    .{"NULLPANTRY_RETRIEVAL_SHADOW_PERCENT"},
    .{"NULLPANTRY_RUN_LEGACY_COMPAT_CLEANUP"},
    .{"NULLPANTRY_SCOPES"},
    .{"NULLPANTRY_SUPERMEMORY_API_KEY"},
    .{"NULLPANTRY_SUPERMEMORY_URL"},
    .{"NULLPANTRY_TOKEN"},
    .{"NULLPANTRY_TOKEN_PRINCIPALS"},
    .{"NULLPANTRY_TRUST_ACTOR_HEADERS"},
    .{"NULLPANTRY_VECTOR_ALLOW_INSECURE_HTTP"},
    .{"NULLPANTRY_VECTOR_API_KEY"},
    .{"NULLPANTRY_VECTOR_API_KEY_HEADER"},
    .{"NULLPANTRY_VECTOR_BACKEND"},
    .{"NULLPANTRY_VECTOR_BASE_URL"},
    .{"NULLPANTRY_VECTOR_CIRCUIT_BREAKER_COOLDOWN_MS"},
    .{"NULLPANTRY_VECTOR_CIRCUIT_BREAKER_ENABLED"},
    .{"NULLPANTRY_VECTOR_CIRCUIT_BREAKER_THRESHOLD"},
    .{"NULLPANTRY_VECTOR_COLLECTION"},
    .{"NULLPANTRY_VECTOR_POSTGRES_URL"},
    .{"NULLPANTRY_VECTOR_SQLITE_ANN_CANDIDATE_MULTIPLIER"},
    .{"NULLPANTRY_VECTOR_SQLITE_ANN_MIN_CANDIDATES"},
    .{"NULLPANTRY_VECTOR_STORES"},
    .{"NULLPANTRY_VECTOR_TIMEOUT_SECS"},
    .{"NULLPANTRY_WEAVIATE_API_KEY"},
    .{"NULLPANTRY_WEAVIATE_COLLECTION"},
    .{"NULLPANTRY_WEAVIATE_URL"},
    .{"NULLPANTRY_WORKER_CAPABILITIES"},
    .{"NULLPANTRY_WORKER_INTERVAL_MS"},
    .{"NULLPANTRY_WORKER_SCOPES"},
    .{"NULLPANTRY_ZEP_API_KEY"},
    .{"NULLPANTRY_ZEP_GRAPH_ID"},
    .{"NULLPANTRY_ZEP_URL"},
});

const ConfigFileEnv = struct {
    allocator: std.mem.Allocator,
    values: std.StringHashMapUnmanaged([]const u8) = .empty,

    fn init(allocator: std.mem.Allocator) ConfigFileEnv {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *ConfigFileEnv) void {
        var it = self.values.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.values.deinit(self.allocator);
        self.* = .{ .allocator = self.allocator };
    }

    fn putOwned(self: *ConfigFileEnv, name: []const u8, value: []const u8) !void {
        if (!isRuntimeConfigEnvName(name)) return error.InvalidRuntimeConfig;
        const key = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(key);
        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value);
        const result = try self.values.getOrPut(self.allocator, key);
        if (result.found_existing) {
            self.allocator.free(key);
            self.allocator.free(result.value_ptr.*);
        } else {
            result.key_ptr.* = key;
        }
        result.value_ptr.* = owned_value;
    }

    fn putValue(self: *ConfigFileEnv, name: []const u8, value: std.json.Value) !void {
        if (value == .null) return;
        const text = try configValueToString(self.allocator, value);
        defer self.allocator.free(text);
        try self.putOwned(name, text);
    }
};

const RuntimeConfigEnv = union(enum) {
    file: *const ConfigFileEnv,
    process,

    fn get(self: RuntimeConfigEnv, allocator: std.mem.Allocator, name: []const u8) ![]u8 {
        return switch (self) {
            .file => |file| blk: {
                const value = file.values.get(name) orelse return error.EnvironmentVariableNotFound;
                break :blk try allocator.dupe(u8, value);
            },
            .process => compat.process.getEnvVarOwned(allocator, name),
        };
    }

    fn getZ(self: RuntimeConfigEnv, allocator: std.mem.Allocator, name: []const u8) ![:0]u8 {
        const value = try self.get(allocator, name);
        defer allocator.free(value);
        return try allocator.dupeZ(u8, value);
    }
};

const RuntimeConfigParseState = struct {
    retrieval_rollout_mode_configured: bool = false,
    embedding_fallbacks_raw: ?[]const u8 = null,
    embedding_fallbacks_owned: ?[]const u8 = null,
    embedding_routes_raw: ?[]const u8 = null,
    embedding_routes_owned: ?[]const u8 = null,

    fn deinit(self: *RuntimeConfigParseState, allocator: std.mem.Allocator) void {
        if (self.embedding_fallbacks_owned) |raw| allocator.free(raw);
        if (self.embedding_routes_owned) |raw| allocator.free(raw);
        self.* = .{};
    }

    fn setEmbeddingFallbacks(self: *RuntimeConfigParseState, allocator: std.mem.Allocator, raw: []const u8, owned: bool) void {
        if (self.embedding_fallbacks_owned) |old| allocator.free(old);
        self.embedding_fallbacks_raw = raw;
        self.embedding_fallbacks_owned = if (owned) raw else null;
    }

    fn setEmbeddingRoutes(self: *RuntimeConfigParseState, allocator: std.mem.Allocator, raw: []const u8, owned: bool) void {
        if (self.embedding_routes_owned) |old| allocator.free(old);
        self.embedding_routes_raw = raw;
        self.embedding_routes_owned = if (owned) raw else null;
    }
};

fn loadConfigFileEnv(allocator: std.mem.Allocator, args: []const [:0]const u8, home_path: ?[]const u8) !ConfigFileEnv {
    var out = ConfigFileEnv.init(allocator);
    errdefer out.deinit();
    if (argsContain(args, "--help") or argsContain(args, "--version")) return out;

    if (configPathFromArgs(args)) |path| {
        try loadConfigFilePath(&out, path);
        return out;
    }

    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_CONFIG")) |env_path| {
        defer allocator.free(env_path);
        if (std.mem.trim(u8, env_path, " \t\r\n").len > 0) {
            try loadConfigFilePath(&out, env_path);
            return out;
        }
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => {},
        else => |e| return e,
    }

    if (home_path) |home| {
        const trimmed = std.mem.trim(u8, home, " \t\r\n");
        if (trimmed.len == 0) return out;
        const default_config_path = try std.fs.path.join(allocator, &.{ trimmed, home_default_config_file });
        defer allocator.free(default_config_path);
        try loadImplicitHomeConfigFile(&out, default_config_path);
    }
    return out;
}

fn argsContain(args: []const [:0]const u8, needle: []const u8) bool {
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, needle)) return true;
    }
    return false;
}

fn configPathFromArgs(args: []const [:0]const u8) ?[]const u8 {
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if ((std.mem.eql(u8, arg, "--config") or std.mem.eql(u8, arg, "-c")) and i + 1 < args.len) return args[i + 1];
        if (std.mem.startsWith(u8, arg, "--config=")) return arg["--config=".len..];
    }
    return null;
}

fn homePathFromArgs(args: []const [:0]const u8) ?[]const u8 {
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--home") and i + 1 < args.len) return args[i + 1];
        if (std.mem.startsWith(u8, arg, "--home=")) return arg["--home=".len..];
    }
    return null;
}

fn homePathFromEnv(allocator: std.mem.Allocator) !?[]u8 {
    const env_path = compat.process.getEnvVarOwned(allocator, "NULLPANTRY_HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return null,
        else => |e| return e,
    };
    if (std.mem.trim(u8, env_path, " \t\r\n").len == 0) {
        allocator.free(env_path);
        return null;
    }
    return env_path;
}

fn loadConfigFilePath(out: *ConfigFileEnv, path: []const u8) !void {
    const content = try std.Io.Dir.cwd().readFileAlloc(compat.io(), path, out.allocator, .limited(max_runtime_config_file_bytes));
    defer out.allocator.free(content);

    const parsed = try std.json.parseFromSlice(std.json.Value, out.allocator, content, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidRuntimeConfig;
    try flattenRuntimeConfigObject(out, parsed.value.object);
}

fn loadConfigFileHandle(out: *ConfigFileEnv, file: std.Io.File) !void {
    var file_reader = file.reader(compat.io(), &.{});
    const content = file_reader.interface.allocRemaining(out.allocator, .limited(max_runtime_config_file_bytes)) catch |err| switch (err) {
        error.ReadFailed => return file_reader.err.?,
        error.OutOfMemory, error.StreamTooLong => |e| return e,
    };
    defer out.allocator.free(content);

    const parsed = try std.json.parseFromSlice(std.json.Value, out.allocator, content, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidRuntimeConfig;
    try flattenRuntimeConfigObject(out, parsed.value.object);
}

fn permissionsGroupOrWorldWritable(permissions: std.Io.File.Permissions) bool {
    if (comptime @hasDecl(std.Io.File.Permissions, "toMode")) {
        return permissions.toMode() & 0o022 != 0;
    }
    return false;
}

fn supportsPosixOwnerCheck() bool {
    return builtin.link_libc and switch (builtin.os.tag) {
        .windows, .wasi, .emscripten, .freestanding, .other => false,
        else => true,
    };
}

fn validateOpenHandleTrust(handle: std.posix.fd_t, permissions: std.Io.File.Permissions) !void {
    if (permissionsGroupOrWorldWritable(permissions)) return error.UntrustedRuntimeConfig;
    if (comptime supportsPosixOwnerCheck()) {
        var stat_buf: std.c.Stat = undefined;
        if (fstat(@intCast(handle), &stat_buf) != 0) return error.UntrustedRuntimeConfig;
        if (stat_buf.uid != geteuid()) return error.UntrustedRuntimeConfig;
    }
}

fn validateExistingHomeRootTrust(home_path: []const u8) !bool {
    var home_dir = std.Io.Dir.cwd().openDir(compat.io(), home_path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        error.SymLinkLoop => return error.UntrustedRuntimeConfig,
        else => |e| return e,
    };
    defer home_dir.close(compat.io());

    const home_stat = try home_dir.stat(compat.io());
    if (home_stat.kind != .directory) return error.InvalidRuntimeConfig;
    try validateOpenHandleTrust(home_dir.handle, home_stat.permissions);
    return true;
}

fn loadImplicitHomeConfigFile(out: *ConfigFileEnv, config_path: []const u8) !void {
    var file = std.Io.Dir.cwd().openFile(compat.io(), config_path, .{
        .allow_directory = false,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return,
        error.SymLinkLoop => return error.UntrustedRuntimeConfig,
        else => |e| return e,
    };
    defer file.close(compat.io());

    const config_stat = try file.stat(compat.io());
    if (config_stat.kind != .file) return error.InvalidRuntimeConfig;
    try validateOpenHandleTrust(file.handle, config_stat.permissions);
    try loadConfigFileHandle(out, file);
}

fn ensureRuntimeHomeRoot(home_path: []const u8) !void {
    const trimmed = std.mem.trim(u8, home_path, " \t\r\n");
    if (trimmed.len == 0) return;
    const permissions: std.Io.Dir.Permissions = if (comptime @hasDecl(std.Io.Dir.Permissions, "fromMode"))
        .fromMode(0o700)
    else
        .default_dir;
    _ = try std.Io.Dir.cwd().createDirPathStatus(compat.io(), trimmed, permissions);
    _ = try validateExistingHomeRootTrust(trimmed);
}

fn applyHomeDefaults(allocator: std.mem.Allocator, cfg: *RuntimeConfig, home_path: ?[]const u8) !void {
    const raw_home = home_path orelse return;
    const home = std.mem.trim(u8, raw_home, " \t\r\n");
    if (home.len == 0) return;

    cfg.home_defaults.deinit(allocator);
    errdefer cfg.home_defaults.deinit(allocator);

    _ = try validateExistingHomeRootTrust(home);
    cfg.home_defaults.home_root = try allocator.dupe(u8, home);
    cfg.home_defaults.db_path = try std.fs.path.joinZ(allocator, &.{ home, home_default_db_file });
    cfg.db_path = cfg.home_defaults.db_path.?;
    cfg.home_defaults.filesystem_root = try std.fs.path.join(allocator, &.{ home, home_default_filesystem_dir });
    cfg.filesystem.root = cfg.home_defaults.filesystem_root.?;
    cfg.home_defaults.markdown_workspace = try std.fs.path.join(allocator, &.{ home, home_default_markdown_dir });
    cfg.stores.markdown_agent_memory.workspace_dir = cfg.home_defaults.markdown_workspace.?;
    cfg.home_defaults.holographic_db_path = try std.fs.path.join(allocator, &.{ home, home_default_holographic_db_file });
    cfg.stores.holographic_agent_memory.db_path = cfg.home_defaults.holographic_db_path.?;
    cfg.home_defaults.lancedb_uri = try std.fs.path.join(allocator, &.{ home, home_default_lancedb_dir });
    cfg.stores.vector_backend.lancedb_uri = cfg.home_defaults.lancedb_uri.?;
    cfg.home_defaults.lucid_workspace = try std.fs.path.join(allocator, &.{ home, home_default_lucid_dir });
    cfg.stores.lucid_projection.workspace_dir = cfg.home_defaults.lucid_workspace.?;
}

fn configValueToString(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |s| try allocator.dupe(u8, s),
        .number_string => |s| try allocator.dupe(u8, s),
        .bool => |b| try allocator.dupe(u8, if (b) "true" else "false"),
        .integer, .float, .array, .object => try std.json.Stringify.valueAlloc(allocator, value, .{}),
        .null => try allocator.dupe(u8, ""),
    };
}

fn flattenRuntimeConfigObject(out: *ConfigFileEnv, root: std.json.ObjectMap) !void {
    try validateConfigFields(root, &.{
        "host",
        "port",
        "instance_id",
        "feed_instance_id",
        "db_path",
        "database_url",
        "postgres_url",
        "backend",
        "records_backend",
        "worker_interval_ms",
        "run_legacy_compat_cleanup",
        "filesystem_root",
        "server",
        "records",
        "auth",
        "actor",
        "worker",
        "filesystem",
        "provider",
        "embedding",
        "llm",
        "completion",
        "retrieval",
        "chunker",
        "agent_memory",
        "vector",
        "graph",
        "analytics",
        "lucid",
        "env",
    });
    try putConfigField(out, root, "host", "NULLPANTRY_HOST");
    try putConfigField(out, root, "port", "NULLPANTRY_PORT");
    try putConfigField(out, root, "instance_id", "NULLPANTRY_INSTANCE_ID");
    try putConfigField(out, root, "feed_instance_id", "NULLPANTRY_FEED_INSTANCE_ID");
    try putConfigField(out, root, "db_path", "NULLPANTRY_DB_PATH");
    try putConfigField(out, root, "database_url", "NULLPANTRY_DATABASE_URL");
    try putConfigField(out, root, "postgres_url", "NULLPANTRY_DATABASE_URL");
    try putConfigField(out, root, "backend", "NULLPANTRY_RECORDS_BACKEND");
    try putConfigField(out, root, "records_backend", "NULLPANTRY_RECORDS_BACKEND");
    try putConfigField(out, root, "worker_interval_ms", "NULLPANTRY_WORKER_INTERVAL_MS");
    try putConfigField(out, root, "run_legacy_compat_cleanup", "NULLPANTRY_RUN_LEGACY_COMPAT_CLEANUP");
    try putConfigField(out, root, "filesystem_root", "NULLPANTRY_FILESYSTEM_ROOT");

    if (try jsonObjectField(root, "server")) |obj| {
        try validateConfigFields(obj, &.{ "host", "port", "instance_id", "feed_instance_id" });
        try putConfigField(out, obj, "host", "NULLPANTRY_HOST");
        try putConfigField(out, obj, "port", "NULLPANTRY_PORT");
        try putConfigField(out, obj, "instance_id", "NULLPANTRY_INSTANCE_ID");
        try putConfigField(out, obj, "feed_instance_id", "NULLPANTRY_FEED_INSTANCE_ID");
    }
    if (try jsonObjectField(root, "records")) |obj| {
        try validateConfigFields(obj, &.{ "backend", "db_path", "database_url", "postgres_url", "run_legacy_compat_cleanup" });
        try putConfigField(out, obj, "backend", "NULLPANTRY_RECORDS_BACKEND");
        try putConfigField(out, obj, "db_path", "NULLPANTRY_DB_PATH");
        try putConfigField(out, obj, "database_url", "NULLPANTRY_DATABASE_URL");
        try putConfigField(out, obj, "postgres_url", "NULLPANTRY_DATABASE_URL");
        try putConfigField(out, obj, "run_legacy_compat_cleanup", "NULLPANTRY_RUN_LEGACY_COMPAT_CLEANUP");
    }
    if (try jsonObjectField(root, "auth")) |obj| {
        try validateConfigFields(obj, &.{ "token", "required_token", "token_principals", "token_principals_json", "allow_no_auth_non_loopback", "trust_actor_headers" });
        try putConfigField(out, obj, "token", "NULLPANTRY_TOKEN");
        try putConfigField(out, obj, "required_token", "NULLPANTRY_TOKEN");
        try putConfigField(out, obj, "token_principals", "NULLPANTRY_TOKEN_PRINCIPALS");
        try putConfigField(out, obj, "token_principals_json", "NULLPANTRY_TOKEN_PRINCIPALS");
        try putConfigField(out, obj, "allow_no_auth_non_loopback", "NULLPANTRY_ALLOW_NO_AUTH_NON_LOOPBACK");
        try putConfigField(out, obj, "trust_actor_headers", "NULLPANTRY_TRUST_ACTOR_HEADERS");
    }
    if (try jsonObjectField(root, "actor")) |obj| {
        try validateConfigFields(obj, &.{ "scopes", "scopes_json", "capabilities", "capabilities_json" });
        try putConfigField(out, obj, "scopes", "NULLPANTRY_SCOPES");
        try putConfigField(out, obj, "scopes_json", "NULLPANTRY_SCOPES");
        try putConfigField(out, obj, "capabilities", "NULLPANTRY_CAPABILITIES");
        try putConfigField(out, obj, "capabilities_json", "NULLPANTRY_CAPABILITIES");
    }
    if (try jsonObjectField(root, "worker")) |obj| {
        try validateConfigFields(obj, &.{ "interval_ms", "scopes", "scopes_json", "capabilities", "capabilities_json" });
        try putConfigField(out, obj, "interval_ms", "NULLPANTRY_WORKER_INTERVAL_MS");
        try putConfigField(out, obj, "scopes", "NULLPANTRY_WORKER_SCOPES");
        try putConfigField(out, obj, "scopes_json", "NULLPANTRY_WORKER_SCOPES");
        try putConfigField(out, obj, "capabilities", "NULLPANTRY_WORKER_CAPABILITIES");
        try putConfigField(out, obj, "capabilities_json", "NULLPANTRY_WORKER_CAPABILITIES");
    }
    if (try jsonObjectField(root, "filesystem")) |obj| {
        try validateConfigFields(obj, &.{"root"});
        try putConfigField(out, obj, "root", "NULLPANTRY_FILESYSTEM_ROOT");
    }

    if (try jsonObjectField(root, "provider")) |obj| try flattenProviderConfig(out, obj);
    if (try jsonObjectField(root, "embedding")) |obj| try flattenEmbeddingConfig(out, obj);
    if (try jsonObjectField(root, "llm")) |obj| try flattenLlmConfig(out, obj);
    if (try jsonObjectField(root, "completion")) |obj| try flattenLlmConfig(out, obj);
    if (try jsonObjectField(root, "retrieval")) |obj| try flattenRetrievalConfig(out, obj);
    if (try jsonObjectField(root, "chunker")) |obj| try flattenChunkerConfig(out, obj);
    if (try jsonObjectField(root, "agent_memory")) |obj| try flattenAgentMemoryConfig(out, obj);
    if (try jsonObjectField(root, "vector")) |obj| try flattenVectorConfig(out, obj);
    if (try jsonObjectField(root, "graph")) |obj| try flattenGraphConfig(out, obj);
    if (try jsonObjectField(root, "analytics")) |obj| try flattenAnalyticsConfig(out, obj);
    if (try jsonObjectField(root, "lucid")) |obj| try flattenLucidConfig(out, obj);
    if (try jsonObjectField(root, "env")) |obj| try flattenEnvConfig(out, obj);
}

fn flattenProviderConfig(out: *ConfigFileEnv, obj: std.json.ObjectMap) !void {
    try validateConfigFields(obj, &.{ "allow_insecure_http", "timeout_secs", "max_response_bytes", "circuit_failure_threshold", "circuit_cooldown_ms", "embedding", "llm", "completion" });
    try putConfigField(out, obj, "allow_insecure_http", "NULLPANTRY_PROVIDER_ALLOW_INSECURE_HTTP");
    try putConfigField(out, obj, "timeout_secs", "NULLPANTRY_PROVIDER_TIMEOUT_SECS");
    try putConfigField(out, obj, "max_response_bytes", "NULLPANTRY_PROVIDER_MAX_RESPONSE_BYTES");
    try putConfigField(out, obj, "circuit_failure_threshold", "NULLPANTRY_PROVIDER_CIRCUIT_FAILURE_THRESHOLD");
    try putConfigField(out, obj, "circuit_cooldown_ms", "NULLPANTRY_PROVIDER_CIRCUIT_COOLDOWN_MS");
    if (try jsonObjectField(obj, "embedding")) |embedding| try flattenEmbeddingConfig(out, embedding);
    if (try jsonObjectField(obj, "llm")) |llm| try flattenLlmConfig(out, llm);
    if (try jsonObjectField(obj, "completion")) |completion| try flattenLlmConfig(out, completion);
}

fn flattenEmbeddingConfig(out: *ConfigFileEnv, obj: std.json.ObjectMap) !void {
    try validateConfigFields(obj, &.{ "provider", "base_url", "api_key", "model", "dimensions", "send_dimensions", "allow_insecure_http", "max_response_bytes", "fallbacks", "routes" });
    try putConfigField(out, obj, "provider", "NULLPANTRY_EMBEDDING_PROVIDER");
    try putConfigField(out, obj, "base_url", "NULLPANTRY_EMBEDDING_BASE_URL");
    try putConfigField(out, obj, "api_key", "NULLPANTRY_EMBEDDING_API_KEY");
    try putConfigField(out, obj, "model", "NULLPANTRY_EMBEDDING_MODEL");
    try putConfigField(out, obj, "dimensions", "NULLPANTRY_EMBEDDING_DIMENSIONS");
    try putConfigField(out, obj, "send_dimensions", "NULLPANTRY_EMBEDDING_SEND_DIMENSIONS");
    try putConfigField(out, obj, "allow_insecure_http", "NULLPANTRY_EMBEDDING_ALLOW_INSECURE_HTTP");
    try putConfigField(out, obj, "max_response_bytes", "NULLPANTRY_EMBEDDING_MAX_RESPONSE_BYTES");
    try putConfigField(out, obj, "fallbacks", "NULLPANTRY_EMBEDDING_FALLBACKS");
    try putConfigField(out, obj, "routes", "NULLPANTRY_EMBEDDING_ROUTES");
}

fn flattenLlmConfig(out: *ConfigFileEnv, obj: std.json.ObjectMap) !void {
    try validateConfigFields(obj, &.{ "base_url", "api_key", "model", "allow_insecure_http", "max_response_bytes" });
    try putConfigField(out, obj, "base_url", "NULLPANTRY_LLM_BASE_URL");
    try putConfigField(out, obj, "api_key", "NULLPANTRY_LLM_API_KEY");
    try putConfigField(out, obj, "model", "NULLPANTRY_LLM_MODEL");
    try putConfigField(out, obj, "allow_insecure_http", "NULLPANTRY_LLM_ALLOW_INSECURE_HTTP");
    try putConfigField(out, obj, "max_response_bytes", "NULLPANTRY_LLM_MAX_RESPONSE_BYTES");
}

fn flattenRetrievalConfig(out: *ConfigFileEnv, obj: std.json.ObjectMap) !void {
    try validateConfigFields(obj, &.{
        "adaptive_keyword_max_tokens",
        "adaptive_vector_min_tokens",
        "rollout_mode",
        "rollout_percent",
        "canary_percent",
        "shadow_percent",
        "rollout_salt",
        "rollout_disabled",
        "required_scopes",
        "blocked_scopes",
        "target_scopes",
        "required_capabilities",
        "blocked_capabilities",
        "chunker",
    });
    try putConfigField(out, obj, "adaptive_keyword_max_tokens", "NULLPANTRY_ADAPTIVE_KEYWORD_MAX_TOKENS");
    try putConfigField(out, obj, "adaptive_vector_min_tokens", "NULLPANTRY_ADAPTIVE_VECTOR_MIN_TOKENS");
    try putConfigField(out, obj, "rollout_mode", "NULLPANTRY_RETRIEVAL_ROLLOUT_MODE");
    try putConfigField(out, obj, "rollout_percent", "NULLPANTRY_RETRIEVAL_ROLLOUT_PERCENT");
    try putConfigField(out, obj, "canary_percent", "NULLPANTRY_RETRIEVAL_CANARY_PERCENT");
    try putConfigField(out, obj, "shadow_percent", "NULLPANTRY_RETRIEVAL_SHADOW_PERCENT");
    try putConfigField(out, obj, "rollout_salt", "NULLPANTRY_RETRIEVAL_ROLLOUT_SALT");
    try putConfigField(out, obj, "rollout_disabled", "NULLPANTRY_RETRIEVAL_ROLLOUT_DISABLED");
    try putConfigField(out, obj, "required_scopes", "NULLPANTRY_RETRIEVAL_ROLLOUT_REQUIRED_SCOPES");
    try putConfigField(out, obj, "blocked_scopes", "NULLPANTRY_RETRIEVAL_ROLLOUT_BLOCKED_SCOPES");
    try putConfigField(out, obj, "target_scopes", "NULLPANTRY_RETRIEVAL_ROLLOUT_TARGET_SCOPES");
    try putConfigField(out, obj, "required_capabilities", "NULLPANTRY_RETRIEVAL_ROLLOUT_REQUIRED_CAPABILITIES");
    try putConfigField(out, obj, "blocked_capabilities", "NULLPANTRY_RETRIEVAL_ROLLOUT_BLOCKED_CAPABILITIES");
    if (try jsonObjectField(obj, "chunker")) |chunker| try flattenChunkerConfig(out, chunker);
}

fn flattenChunkerConfig(out: *ConfigFileEnv, obj: std.json.ObjectMap) !void {
    try validateConfigFields(obj, &.{ "max_chars", "overlap_chars", "max_tokens", "strategy" });
    try putConfigField(out, obj, "max_chars", "NULLPANTRY_CHUNK_MAX_CHARS");
    try putConfigField(out, obj, "overlap_chars", "NULLPANTRY_CHUNK_OVERLAP_CHARS");
    try putConfigField(out, obj, "max_tokens", "NULLPANTRY_CHUNK_MAX_TOKENS");
    try putConfigField(out, obj, "strategy", "NULLPANTRY_CHUNK_STRATEGY");
}

fn flattenAgentMemoryConfig(out: *ConfigFileEnv, obj: std.json.ObjectMap) !void {
    try validateConfigFields(obj, &.{
        "backend",
        "stores",
        "markdown_workspace",
        "markdown_max_file_bytes",
        "api_url",
        "api_token",
        "api_storage",
        "api_scopes",
        "api_capabilities",
        "api_timeout_secs",
        "api_max_response_bytes",
        "api_allow_insecure_http",
        "api_profile",
        "redis_url",
        "redis_key_prefix",
        "redis_ttl_seconds",
        "memory_lru_max_entries",
        "memory_lru_max_messages",
        "memory_lru_max_usage_entries",
        "memory_lru_max_bytes",
        "memory_lru_ttl_seconds",
        "clickhouse_url",
        "clickhouse_api_key",
        "clickhouse_table",
        "clickhouse_timeout_secs",
        "clickhouse_max_response_bytes",
        "clickhouse_allow_insecure_http",
        "holographic_db_path",
        "holographic_default_trust",
        "holographic_trust_reward",
        "holographic_trust_penalty",
        "supermemory_url",
        "supermemory_api_key",
        "openviking_url",
        "openviking_api_key",
        "honcho_url",
        "honcho_api_key",
        "honcho_workspace_id",
        "mem0_url",
        "mem0_api_key",
        "hindsight_url",
        "hindsight_api_key",
        "hindsight_bank_id",
        "retaindb_url",
        "retaindb_api_key",
        "retaindb_project",
        "byterover_command",
        "byterover_project_dir",
        "byterover_use_swarm",
        "zep_url",
        "zep_api_key",
        "zep_graph_id",
        "falkordb_url",
        "falkordb_api_key",
        "falkordb_graph",
        "markdown",
        "redis",
        "api",
        "clickhouse",
        "holographic",
    });
    try putConfigField(out, obj, "backend", "NULLPANTRY_AGENT_MEMORY_BACKEND");
    try putConfigField(out, obj, "stores", "NULLPANTRY_AGENT_MEMORY_STORES");
    try putConfigField(out, obj, "markdown_workspace", "NULLPANTRY_AGENT_MEMORY_MARKDOWN_WORKSPACE");
    try putConfigField(out, obj, "markdown_max_file_bytes", "NULLPANTRY_AGENT_MEMORY_MARKDOWN_MAX_FILE_BYTES");
    try putConfigField(out, obj, "api_url", "NULLPANTRY_AGENT_MEMORY_API_URL");
    try putConfigField(out, obj, "api_token", "NULLPANTRY_AGENT_MEMORY_API_TOKEN");
    try putConfigField(out, obj, "api_storage", "NULLPANTRY_AGENT_MEMORY_API_STORAGE");
    try putConfigField(out, obj, "api_scopes", "NULLPANTRY_AGENT_MEMORY_API_SCOPES");
    try putConfigField(out, obj, "api_capabilities", "NULLPANTRY_AGENT_MEMORY_API_CAPABILITIES");
    try putConfigField(out, obj, "api_timeout_secs", "NULLPANTRY_AGENT_MEMORY_API_TIMEOUT_SECS");
    try putConfigField(out, obj, "api_max_response_bytes", "NULLPANTRY_AGENT_MEMORY_API_MAX_RESPONSE_BYTES");
    try putConfigField(out, obj, "api_allow_insecure_http", "NULLPANTRY_AGENT_MEMORY_API_ALLOW_INSECURE_HTTP");
    try putConfigField(out, obj, "api_profile", "NULLPANTRY_AGENT_MEMORY_API_PROFILE");
    try putConfigField(out, obj, "redis_url", "NULLPANTRY_REDIS_URL");
    try putConfigField(out, obj, "redis_key_prefix", "NULLPANTRY_REDIS_KEY_PREFIX");
    try putConfigField(out, obj, "redis_ttl_seconds", "NULLPANTRY_REDIS_TTL_SECONDS");
    try putConfigField(out, obj, "memory_lru_max_entries", "NULLPANTRY_MEMORY_LRU_MAX_ENTRIES");
    try putConfigField(out, obj, "memory_lru_max_messages", "NULLPANTRY_MEMORY_LRU_MAX_MESSAGES");
    try putConfigField(out, obj, "memory_lru_max_usage_entries", "NULLPANTRY_MEMORY_LRU_MAX_USAGE_ENTRIES");
    try putConfigField(out, obj, "memory_lru_max_bytes", "NULLPANTRY_MEMORY_LRU_MAX_BYTES");
    try putConfigField(out, obj, "memory_lru_ttl_seconds", "NULLPANTRY_MEMORY_LRU_TTL_SECONDS");
    try putConfigField(out, obj, "clickhouse_url", "NULLPANTRY_AGENT_MEMORY_CLICKHOUSE_URL");
    try putConfigField(out, obj, "clickhouse_api_key", "NULLPANTRY_AGENT_MEMORY_CLICKHOUSE_API_KEY");
    try putConfigField(out, obj, "clickhouse_table", "NULLPANTRY_AGENT_MEMORY_CLICKHOUSE_TABLE");
    try putConfigField(out, obj, "clickhouse_timeout_secs", "NULLPANTRY_AGENT_MEMORY_CLICKHOUSE_TIMEOUT_SECS");
    try putConfigField(out, obj, "clickhouse_max_response_bytes", "NULLPANTRY_AGENT_MEMORY_CLICKHOUSE_MAX_RESPONSE_BYTES");
    try putConfigField(out, obj, "clickhouse_allow_insecure_http", "NULLPANTRY_AGENT_MEMORY_CLICKHOUSE_ALLOW_INSECURE_HTTP");
    try putConfigField(out, obj, "holographic_db_path", "NULLPANTRY_AGENT_MEMORY_HOLOGRAPHIC_DB_PATH");
    try putConfigField(out, obj, "holographic_default_trust", "NULLPANTRY_HOLOGRAPHIC_DEFAULT_TRUST");
    try putConfigField(out, obj, "holographic_trust_reward", "NULLPANTRY_HOLOGRAPHIC_TRUST_REWARD");
    try putConfigField(out, obj, "holographic_trust_penalty", "NULLPANTRY_HOLOGRAPHIC_TRUST_PENALTY");
    try putConfigField(out, obj, "supermemory_url", "NULLPANTRY_SUPERMEMORY_URL");
    try putConfigField(out, obj, "supermemory_api_key", "NULLPANTRY_SUPERMEMORY_API_KEY");
    try putConfigField(out, obj, "openviking_url", "NULLPANTRY_OPENVIKING_URL");
    try putConfigField(out, obj, "openviking_api_key", "NULLPANTRY_OPENVIKING_API_KEY");
    try putConfigField(out, obj, "honcho_url", "NULLPANTRY_HONCHO_URL");
    try putConfigField(out, obj, "honcho_api_key", "NULLPANTRY_HONCHO_API_KEY");
    try putConfigField(out, obj, "honcho_workspace_id", "NULLPANTRY_HONCHO_WORKSPACE_ID");
    try putConfigField(out, obj, "mem0_url", "NULLPANTRY_MEM0_URL");
    try putConfigField(out, obj, "mem0_api_key", "NULLPANTRY_MEM0_API_KEY");
    try putConfigField(out, obj, "hindsight_url", "NULLPANTRY_HINDSIGHT_URL");
    try putConfigField(out, obj, "hindsight_api_key", "NULLPANTRY_HINDSIGHT_API_KEY");
    try putConfigField(out, obj, "hindsight_bank_id", "NULLPANTRY_HINDSIGHT_BANK_ID");
    try putConfigField(out, obj, "retaindb_url", "NULLPANTRY_RETAINDB_URL");
    try putConfigField(out, obj, "retaindb_api_key", "NULLPANTRY_RETAINDB_API_KEY");
    try putConfigField(out, obj, "retaindb_project", "NULLPANTRY_RETAINDB_PROJECT");
    try putConfigField(out, obj, "byterover_command", "NULLPANTRY_BYTEROVER_COMMAND");
    try putConfigField(out, obj, "byterover_project_dir", "NULLPANTRY_BYTEROVER_PROJECT_DIR");
    try putConfigField(out, obj, "byterover_use_swarm", "NULLPANTRY_BYTEROVER_USE_SWARM");
    try putConfigField(out, obj, "zep_url", "NULLPANTRY_ZEP_URL");
    try putConfigField(out, obj, "zep_api_key", "NULLPANTRY_ZEP_API_KEY");
    try putConfigField(out, obj, "zep_graph_id", "NULLPANTRY_ZEP_GRAPH_ID");
    try putConfigField(out, obj, "falkordb_url", "NULLPANTRY_FALKORDB_URL");
    try putConfigField(out, obj, "falkordb_api_key", "NULLPANTRY_FALKORDB_API_KEY");
    try putConfigField(out, obj, "falkordb_graph", "NULLPANTRY_FALKORDB_GRAPH");

    if (try jsonObjectField(obj, "markdown")) |markdown| {
        try validateConfigFields(markdown, &.{ "workspace", "workspace_dir", "max_file_bytes" });
        try putConfigField(out, markdown, "workspace", "NULLPANTRY_AGENT_MEMORY_MARKDOWN_WORKSPACE");
        try putConfigField(out, markdown, "workspace_dir", "NULLPANTRY_AGENT_MEMORY_MARKDOWN_WORKSPACE");
        try putConfigField(out, markdown, "max_file_bytes", "NULLPANTRY_AGENT_MEMORY_MARKDOWN_MAX_FILE_BYTES");
    }
    if (try jsonObjectField(obj, "redis")) |redis| {
        try validateConfigFields(redis, &.{ "url", "key_prefix", "ttl_seconds" });
        try putConfigField(out, redis, "url", "NULLPANTRY_REDIS_URL");
        try putConfigField(out, redis, "key_prefix", "NULLPANTRY_REDIS_KEY_PREFIX");
        try putConfigField(out, redis, "ttl_seconds", "NULLPANTRY_REDIS_TTL_SECONDS");
    }
    if (try jsonObjectField(obj, "api")) |api_obj| {
        try validateConfigFields(api_obj, &.{ "url", "base_url", "token", "storage", "scopes", "capabilities", "timeout_secs", "max_response_bytes", "allow_insecure_http", "profile" });
        try putConfigField(out, api_obj, "url", "NULLPANTRY_AGENT_MEMORY_API_URL");
        try putConfigField(out, api_obj, "base_url", "NULLPANTRY_AGENT_MEMORY_API_URL");
        try putConfigField(out, api_obj, "token", "NULLPANTRY_AGENT_MEMORY_API_TOKEN");
        try putConfigField(out, api_obj, "storage", "NULLPANTRY_AGENT_MEMORY_API_STORAGE");
        try putConfigField(out, api_obj, "scopes", "NULLPANTRY_AGENT_MEMORY_API_SCOPES");
        try putConfigField(out, api_obj, "capabilities", "NULLPANTRY_AGENT_MEMORY_API_CAPABILITIES");
        try putConfigField(out, api_obj, "timeout_secs", "NULLPANTRY_AGENT_MEMORY_API_TIMEOUT_SECS");
        try putConfigField(out, api_obj, "max_response_bytes", "NULLPANTRY_AGENT_MEMORY_API_MAX_RESPONSE_BYTES");
        try putConfigField(out, api_obj, "allow_insecure_http", "NULLPANTRY_AGENT_MEMORY_API_ALLOW_INSECURE_HTTP");
        try putConfigField(out, api_obj, "profile", "NULLPANTRY_AGENT_MEMORY_API_PROFILE");
    }
    if (try jsonObjectField(obj, "clickhouse")) |clickhouse| {
        try validateConfigFields(clickhouse, &.{ "url", "base_url", "api_key", "table", "timeout_secs", "max_response_bytes", "allow_insecure_http" });
        try putConfigField(out, clickhouse, "url", "NULLPANTRY_AGENT_MEMORY_CLICKHOUSE_URL");
        try putConfigField(out, clickhouse, "base_url", "NULLPANTRY_AGENT_MEMORY_CLICKHOUSE_URL");
        try putConfigField(out, clickhouse, "api_key", "NULLPANTRY_AGENT_MEMORY_CLICKHOUSE_API_KEY");
        try putConfigField(out, clickhouse, "table", "NULLPANTRY_AGENT_MEMORY_CLICKHOUSE_TABLE");
        try putConfigField(out, clickhouse, "timeout_secs", "NULLPANTRY_AGENT_MEMORY_CLICKHOUSE_TIMEOUT_SECS");
        try putConfigField(out, clickhouse, "max_response_bytes", "NULLPANTRY_AGENT_MEMORY_CLICKHOUSE_MAX_RESPONSE_BYTES");
        try putConfigField(out, clickhouse, "allow_insecure_http", "NULLPANTRY_AGENT_MEMORY_CLICKHOUSE_ALLOW_INSECURE_HTTP");
    }
    if (try jsonObjectField(obj, "holographic")) |holographic| {
        try validateConfigFields(holographic, &.{ "db_path", "default_trust", "trust_reward", "trust_penalty" });
        try putConfigField(out, holographic, "db_path", "NULLPANTRY_AGENT_MEMORY_HOLOGRAPHIC_DB_PATH");
        try putConfigField(out, holographic, "default_trust", "NULLPANTRY_HOLOGRAPHIC_DEFAULT_TRUST");
        try putConfigField(out, holographic, "trust_reward", "NULLPANTRY_HOLOGRAPHIC_TRUST_REWARD");
        try putConfigField(out, holographic, "trust_penalty", "NULLPANTRY_HOLOGRAPHIC_TRUST_PENALTY");
    }
}

fn flattenVectorConfig(out: *ConfigFileEnv, obj: std.json.ObjectMap) !void {
    try validateConfigFields(obj, &.{
        "backend",
        "base_url",
        "url",
        "api_key",
        "api_key_header",
        "collection",
        "postgres_url",
        "timeout_secs",
        "sqlite_ann_candidate_multiplier",
        "sqlite_ann_min_candidates",
        "allow_insecure_http",
        "circuit_breaker_enabled",
        "circuit_breaker_threshold",
        "circuit_breaker_cooldown_ms",
        "stores",
        "pgvector_url",
        "pgvector_table",
        "qdrant_url",
        "qdrant_api_key",
        "qdrant_api_key_header",
        "qdrant_collection",
        "qdrant_allow_insecure_http",
        "lancedb_uri",
        "lancedb_command",
        "lancedb_url",
        "lancedb_api_key",
        "lancedb_table",
        "lancedb_allow_insecure_http",
        "weaviate_url",
        "weaviate_api_key",
        "weaviate_collection",
        "chroma_url",
        "chroma_token",
        "chroma_tenant",
        "chroma_database",
        "chroma_collection",
        "chroma_collection_id",
        "opensearch_url",
        "opensearch_api_key",
        "opensearch_index",
        "pgvector",
        "qdrant",
        "lancedb",
        "weaviate",
        "chroma",
        "opensearch",
    });
    try putConfigField(out, obj, "backend", "NULLPANTRY_VECTOR_BACKEND");
    try putConfigField(out, obj, "base_url", "NULLPANTRY_VECTOR_BASE_URL");
    try putConfigField(out, obj, "url", "NULLPANTRY_VECTOR_BASE_URL");
    try putConfigField(out, obj, "api_key", "NULLPANTRY_VECTOR_API_KEY");
    try putConfigField(out, obj, "api_key_header", "NULLPANTRY_VECTOR_API_KEY_HEADER");
    try putConfigField(out, obj, "collection", "NULLPANTRY_VECTOR_COLLECTION");
    try putConfigField(out, obj, "postgres_url", "NULLPANTRY_VECTOR_POSTGRES_URL");
    try putConfigField(out, obj, "timeout_secs", "NULLPANTRY_VECTOR_TIMEOUT_SECS");
    try putConfigField(out, obj, "sqlite_ann_candidate_multiplier", "NULLPANTRY_VECTOR_SQLITE_ANN_CANDIDATE_MULTIPLIER");
    try putConfigField(out, obj, "sqlite_ann_min_candidates", "NULLPANTRY_VECTOR_SQLITE_ANN_MIN_CANDIDATES");
    try putConfigField(out, obj, "allow_insecure_http", "NULLPANTRY_VECTOR_ALLOW_INSECURE_HTTP");
    try putConfigField(out, obj, "circuit_breaker_enabled", "NULLPANTRY_VECTOR_CIRCUIT_BREAKER_ENABLED");
    try putConfigField(out, obj, "circuit_breaker_threshold", "NULLPANTRY_VECTOR_CIRCUIT_BREAKER_THRESHOLD");
    try putConfigField(out, obj, "circuit_breaker_cooldown_ms", "NULLPANTRY_VECTOR_CIRCUIT_BREAKER_COOLDOWN_MS");
    try putConfigField(out, obj, "stores", "NULLPANTRY_VECTOR_STORES");
    try putConfigField(out, obj, "pgvector_url", "NULLPANTRY_PGVECTOR_URL");
    try putConfigField(out, obj, "pgvector_table", "NULLPANTRY_PGVECTOR_TABLE");
    try putConfigField(out, obj, "qdrant_url", "NULLPANTRY_QDRANT_URL");
    try putConfigField(out, obj, "qdrant_api_key", "NULLPANTRY_QDRANT_API_KEY");
    try putConfigField(out, obj, "qdrant_api_key_header", "NULLPANTRY_QDRANT_API_KEY_HEADER");
    try putConfigField(out, obj, "qdrant_collection", "NULLPANTRY_QDRANT_COLLECTION");
    try putConfigField(out, obj, "qdrant_allow_insecure_http", "NULLPANTRY_QDRANT_ALLOW_INSECURE_HTTP");
    try putConfigField(out, obj, "lancedb_uri", "NULLPANTRY_LANCEDB_URI");
    try putConfigField(out, obj, "lancedb_command", "NULLPANTRY_LANCEDB_COMMAND");
    try putConfigField(out, obj, "lancedb_url", "NULLPANTRY_LANCEDB_URL");
    try putConfigField(out, obj, "lancedb_api_key", "NULLPANTRY_LANCEDB_API_KEY");
    try putConfigField(out, obj, "lancedb_table", "NULLPANTRY_LANCEDB_TABLE");
    try putConfigField(out, obj, "lancedb_allow_insecure_http", "NULLPANTRY_LANCEDB_ALLOW_INSECURE_HTTP");
    try putConfigField(out, obj, "weaviate_url", "NULLPANTRY_WEAVIATE_URL");
    try putConfigField(out, obj, "weaviate_api_key", "NULLPANTRY_WEAVIATE_API_KEY");
    try putConfigField(out, obj, "weaviate_collection", "NULLPANTRY_WEAVIATE_COLLECTION");
    try putConfigField(out, obj, "chroma_url", "NULLPANTRY_CHROMA_URL");
    try putConfigField(out, obj, "chroma_token", "NULLPANTRY_CHROMA_TOKEN");
    try putConfigField(out, obj, "chroma_tenant", "NULLPANTRY_CHROMA_TENANT");
    try putConfigField(out, obj, "chroma_database", "NULLPANTRY_CHROMA_DATABASE");
    try putConfigField(out, obj, "chroma_collection", "NULLPANTRY_CHROMA_COLLECTION");
    try putConfigField(out, obj, "chroma_collection_id", "NULLPANTRY_CHROMA_COLLECTION_ID");
    try putConfigField(out, obj, "opensearch_url", "NULLPANTRY_OPENSEARCH_URL");
    try putConfigField(out, obj, "opensearch_api_key", "NULLPANTRY_OPENSEARCH_API_KEY");
    try putConfigField(out, obj, "opensearch_index", "NULLPANTRY_OPENSEARCH_INDEX");

    if (try jsonObjectField(obj, "pgvector")) |pg| {
        try validateConfigFields(pg, &.{ "url", "postgres_url", "table", "collection" });
        try putConfigField(out, pg, "url", "NULLPANTRY_PGVECTOR_URL");
        try putConfigField(out, pg, "postgres_url", "NULLPANTRY_PGVECTOR_URL");
        try putConfigField(out, pg, "table", "NULLPANTRY_PGVECTOR_TABLE");
        try putConfigField(out, pg, "collection", "NULLPANTRY_PGVECTOR_TABLE");
    }
    if (try jsonObjectField(obj, "qdrant")) |qdrant| {
        try validateConfigFields(qdrant, &.{ "url", "base_url", "api_key", "api_key_header", "collection", "allow_insecure_http" });
        try putConfigField(out, qdrant, "url", "NULLPANTRY_QDRANT_URL");
        try putConfigField(out, qdrant, "base_url", "NULLPANTRY_QDRANT_URL");
        try putConfigField(out, qdrant, "api_key", "NULLPANTRY_QDRANT_API_KEY");
        try putConfigField(out, qdrant, "api_key_header", "NULLPANTRY_QDRANT_API_KEY_HEADER");
        try putConfigField(out, qdrant, "collection", "NULLPANTRY_QDRANT_COLLECTION");
        try putConfigField(out, qdrant, "allow_insecure_http", "NULLPANTRY_QDRANT_ALLOW_INSECURE_HTTP");
    }
    if (try jsonObjectField(obj, "lancedb")) |lancedb| {
        try validateConfigFields(lancedb, &.{ "uri", "command", "url", "api_key", "table", "collection", "allow_insecure_http" });
        try putConfigField(out, lancedb, "uri", "NULLPANTRY_LANCEDB_URI");
        try putConfigField(out, lancedb, "command", "NULLPANTRY_LANCEDB_COMMAND");
        try putConfigField(out, lancedb, "url", "NULLPANTRY_LANCEDB_URL");
        try putConfigField(out, lancedb, "api_key", "NULLPANTRY_LANCEDB_API_KEY");
        try putConfigField(out, lancedb, "table", "NULLPANTRY_LANCEDB_TABLE");
        try putConfigField(out, lancedb, "collection", "NULLPANTRY_LANCEDB_TABLE");
        try putConfigField(out, lancedb, "allow_insecure_http", "NULLPANTRY_LANCEDB_ALLOW_INSECURE_HTTP");
    }
    if (try jsonObjectField(obj, "weaviate")) |weaviate| {
        try validateConfigFields(weaviate, &.{ "url", "base_url", "api_key", "collection" });
        try putConfigField(out, weaviate, "url", "NULLPANTRY_WEAVIATE_URL");
        try putConfigField(out, weaviate, "base_url", "NULLPANTRY_WEAVIATE_URL");
        try putConfigField(out, weaviate, "api_key", "NULLPANTRY_WEAVIATE_API_KEY");
        try putConfigField(out, weaviate, "collection", "NULLPANTRY_WEAVIATE_COLLECTION");
    }
    if (try jsonObjectField(obj, "chroma")) |chroma| {
        try validateConfigFields(chroma, &.{ "url", "base_url", "token", "tenant", "database", "collection", "collection_id" });
        try putConfigField(out, chroma, "url", "NULLPANTRY_CHROMA_URL");
        try putConfigField(out, chroma, "base_url", "NULLPANTRY_CHROMA_URL");
        try putConfigField(out, chroma, "token", "NULLPANTRY_CHROMA_TOKEN");
        try putConfigField(out, chroma, "tenant", "NULLPANTRY_CHROMA_TENANT");
        try putConfigField(out, chroma, "database", "NULLPANTRY_CHROMA_DATABASE");
        try putConfigField(out, chroma, "collection", "NULLPANTRY_CHROMA_COLLECTION");
        try putConfigField(out, chroma, "collection_id", "NULLPANTRY_CHROMA_COLLECTION_ID");
    }
    if (try jsonObjectField(obj, "opensearch")) |opensearch| {
        try validateConfigFields(opensearch, &.{ "url", "base_url", "api_key", "index" });
        try putConfigField(out, opensearch, "url", "NULLPANTRY_OPENSEARCH_URL");
        try putConfigField(out, opensearch, "base_url", "NULLPANTRY_OPENSEARCH_URL");
        try putConfigField(out, opensearch, "api_key", "NULLPANTRY_OPENSEARCH_API_KEY");
        try putConfigField(out, opensearch, "index", "NULLPANTRY_OPENSEARCH_INDEX");
    }
}

fn flattenGraphConfig(out: *ConfigFileEnv, obj: std.json.ObjectMap) !void {
    try validateConfigFields(obj, &.{ "backend", "base_url", "url", "api_key", "database", "name", "timeout_secs", "allow_insecure_http", "project_scopes", "neo4j_url", "neo4j_api_key", "neo4j_database", "falkordb_url", "falkordb_api_key", "falkordb_name" });
    try putConfigField(out, obj, "backend", "NULLPANTRY_GRAPH_BACKEND");
    try putConfigField(out, obj, "base_url", "NULLPANTRY_GRAPH_BASE_URL");
    try putConfigField(out, obj, "url", "NULLPANTRY_GRAPH_BASE_URL");
    try putConfigField(out, obj, "api_key", "NULLPANTRY_GRAPH_API_KEY");
    try putConfigField(out, obj, "database", "NULLPANTRY_GRAPH_DATABASE");
    try putConfigField(out, obj, "name", "NULLPANTRY_GRAPH_NAME");
    try putConfigField(out, obj, "timeout_secs", "NULLPANTRY_GRAPH_TIMEOUT_SECS");
    try putConfigField(out, obj, "allow_insecure_http", "NULLPANTRY_GRAPH_ALLOW_INSECURE_HTTP");
    try putConfigField(out, obj, "project_scopes", "NULLPANTRY_GRAPH_PROJECT_SCOPES");
    try putConfigField(out, obj, "neo4j_url", "NULLPANTRY_NEO4J_URL");
    try putConfigField(out, obj, "neo4j_api_key", "NULLPANTRY_NEO4J_API_KEY");
    try putConfigField(out, obj, "neo4j_database", "NULLPANTRY_NEO4J_DATABASE");
    try putConfigField(out, obj, "falkordb_url", "NULLPANTRY_GRAPH_FALKORDB_URL");
    try putConfigField(out, obj, "falkordb_api_key", "NULLPANTRY_GRAPH_FALKORDB_API_KEY");
    try putConfigField(out, obj, "falkordb_name", "NULLPANTRY_GRAPH_FALKORDB_NAME");
}

fn flattenAnalyticsConfig(out: *ConfigFileEnv, obj: std.json.ObjectMap) !void {
    try validateConfigFields(obj, &.{ "backend", "base_url", "url", "api_key", "table", "timeout_secs", "allow_insecure_http", "clickhouse_url", "clickhouse_api_key", "clickhouse_table", "clickhouse_allow_insecure_http" });
    try putConfigField(out, obj, "backend", "NULLPANTRY_ANALYTICS_BACKEND");
    try putConfigField(out, obj, "base_url", "NULLPANTRY_ANALYTICS_BASE_URL");
    try putConfigField(out, obj, "url", "NULLPANTRY_ANALYTICS_BASE_URL");
    try putConfigField(out, obj, "api_key", "NULLPANTRY_ANALYTICS_API_KEY");
    try putConfigField(out, obj, "table", "NULLPANTRY_ANALYTICS_TABLE");
    try putConfigField(out, obj, "timeout_secs", "NULLPANTRY_ANALYTICS_TIMEOUT_SECS");
    try putConfigField(out, obj, "allow_insecure_http", "NULLPANTRY_ANALYTICS_ALLOW_INSECURE_HTTP");
    try putConfigField(out, obj, "clickhouse_url", "NULLPANTRY_CLICKHOUSE_URL");
    try putConfigField(out, obj, "clickhouse_api_key", "NULLPANTRY_CLICKHOUSE_API_KEY");
    try putConfigField(out, obj, "clickhouse_table", "NULLPANTRY_CLICKHOUSE_TABLE");
    try putConfigField(out, obj, "clickhouse_allow_insecure_http", "NULLPANTRY_CLICKHOUSE_ALLOW_INSECURE_HTTP");
}

fn flattenLucidConfig(out: *ConfigFileEnv, obj: std.json.ObjectMap) !void {
    try validateConfigFields(obj, &.{ "enabled", "command", "workspace", "workspace_dir", "token_budget", "local_hit_threshold", "project_scopes", "result_scope", "permissions" });
    try putConfigField(out, obj, "enabled", "NULLPANTRY_LUCID_ENABLED");
    try putConfigField(out, obj, "command", "NULLPANTRY_LUCID_COMMAND");
    try putConfigField(out, obj, "workspace", "NULLPANTRY_LUCID_WORKSPACE");
    try putConfigField(out, obj, "workspace_dir", "NULLPANTRY_LUCID_WORKSPACE");
    try putConfigField(out, obj, "token_budget", "NULLPANTRY_LUCID_TOKEN_BUDGET");
    try putConfigField(out, obj, "local_hit_threshold", "NULLPANTRY_LUCID_LOCAL_HIT_THRESHOLD");
    try putConfigField(out, obj, "project_scopes", "NULLPANTRY_LUCID_PROJECT_SCOPES");
    try putConfigField(out, obj, "result_scope", "NULLPANTRY_LUCID_RESULT_SCOPE");
    try putConfigField(out, obj, "permissions", "NULLPANTRY_LUCID_PERMISSIONS");
}

fn flattenEnvConfig(out: *ConfigFileEnv, obj: std.json.ObjectMap) !void {
    var it = obj.iterator();
    while (it.next()) |entry| {
        try out.putValue(entry.key_ptr.*, entry.value_ptr.*);
    }
}

fn putConfigField(out: *ConfigFileEnv, obj: std.json.ObjectMap, field: []const u8, env_name: []const u8) !void {
    if (obj.get(field)) |value| try out.putValue(env_name, value);
}

fn validateConfigFields(obj: std.json.ObjectMap, comptime allowed_fields: []const []const u8) !void {
    var it = obj.iterator();
    outer: while (it.next()) |entry| {
        inline for (allowed_fields) |field| {
            if (std.mem.eql(u8, entry.key_ptr.*, field)) continue :outer;
        }
        return error.InvalidRuntimeConfig;
    }
}

fn jsonObjectField(obj: std.json.ObjectMap, name: []const u8) !?std.json.ObjectMap {
    const value = obj.get(name) orelse return null;
    return switch (value) {
        .object => |child| child,
        else => error.InvalidRuntimeConfig,
    };
}

fn applyRuntimeEnv(allocator: std.mem.Allocator, cfg: *RuntimeConfig, env: RuntimeConfigEnv, state: *RuntimeConfigParseState) !void {
    if (env.get(allocator, "NULLPANTRY_HOST")) |host| {
        cfg.host = host;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_PORT")) |port| {
        defer allocator.free(port);
        cfg.port = try std.fmt.parseInt(u16, port, 10);
    } else |_| {}
    if (env.getZ(allocator, "NULLPANTRY_DB_PATH")) |db_path| {
        cfg.db_path = db_path;
        cfg.stores.records_backend = .sqlite;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_RECORDS_BACKEND")) |backend| {
        defer allocator.free(backend);
        cfg.stores.records_backend = try store_config.BackendKind.parse(backend);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_BACKEND")) |backend| {
        defer allocator.free(backend);
        cfg.stores.records_backend = try store_config.BackendKind.parse(backend);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_INSTANCE_ID")) |instance_id| {
        cfg.instance_id = instance_id;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_FEED_INSTANCE_ID")) |instance_id| {
        cfg.instance_id = instance_id;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_TOKEN")) |token| {
        cfg.auth.required_token = token;
        cfg.actor.scopes_json = "[\"public\"]";
        cfg.actor.capabilities_json = "[\"read\"]";
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_TOKEN_PRINCIPALS")) |principals| {
        cfg.auth.token_principals_json = principals;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_ALLOW_NO_AUTH_NON_LOOPBACK")) |value| {
        defer allocator.free(value);
        cfg.auth.allow_no_auth_non_loopback = try parseBool(value);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_FILESYSTEM_ROOT")) |root| {
        cfg.filesystem.root = root;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_DATABASE_URL")) |url| {
        cfg.stores.records_backend = .postgres;
        cfg.stores.postgres_url = url;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_RUN_LEGACY_COMPAT_CLEANUP")) |value| {
        defer allocator.free(value);
        cfg.run_legacy_compat_cleanup = try parseBool(value);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_SCOPES")) |scopes| {
        cfg.actor.scopes_json = scopes;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_CAPABILITIES")) |caps| {
        cfg.actor.capabilities_json = caps;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_WORKER_SCOPES")) |scopes| {
        cfg.worker.scopes_json = scopes;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_WORKER_CAPABILITIES")) |caps| {
        cfg.worker.capabilities_json = caps;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_EMBEDDING_BASE_URL")) |url| {
        cfg.provider.embedding.base_url = url;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_EMBEDDING_API_KEY")) |key| {
        cfg.provider.embedding.api_key = key;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_EMBEDDING_MODEL")) |model| {
        cfg.provider.embedding.model = model;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_EMBEDDING_PROVIDER")) |provider| {
        defer allocator.free(provider);
        cfg.provider.embedding.provider = try providers.EmbeddingProviderKind.parse(provider);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_EMBEDDING_DIMENSIONS")) |dims| {
        defer allocator.free(dims);
        cfg.provider.embedding.dimensions = vector_mod.boundedEmbeddingDimensions(null, try std.fmt.parseInt(usize, dims, 10));
        cfg.provider.embedding.send_dimensions = true;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_EMBEDDING_SEND_DIMENSIONS")) |value| {
        defer allocator.free(value);
        cfg.provider.embedding.send_dimensions = try parseBool(value);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_LLM_BASE_URL")) |url| {
        cfg.provider.completion.base_url = url;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_LLM_API_KEY")) |key| {
        cfg.provider.completion.api_key = key;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_LLM_MODEL")) |model| {
        cfg.provider.completion.model = model;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_PROVIDER_ALLOW_INSECURE_HTTP")) |value| {
        defer allocator.free(value);
        const allow = try parseBool(value);
        cfg.provider.embedding.allow_insecure_http = allow;
        cfg.provider.completion.allow_insecure_http = allow;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_EMBEDDING_ALLOW_INSECURE_HTTP")) |value| {
        defer allocator.free(value);
        cfg.provider.embedding.allow_insecure_http = try parseBool(value);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_LLM_ALLOW_INSECURE_HTTP")) |value| {
        defer allocator.free(value);
        cfg.provider.completion.allow_insecure_http = try parseBool(value);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_PROVIDER_TIMEOUT_SECS")) |secs| {
        defer allocator.free(secs);
        const timeout_secs = try parseProviderTimeoutSecs(secs);
        cfg.provider.embedding.timeout_secs = timeout_secs;
        cfg.provider.completion.timeout_secs = timeout_secs;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_PROVIDER_MAX_RESPONSE_BYTES")) |bytes| {
        defer allocator.free(bytes);
        cfg.provider.default_max_response_bytes = try parseProviderResponseBytes(bytes);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_EMBEDDING_MAX_RESPONSE_BYTES")) |bytes| {
        defer allocator.free(bytes);
        cfg.provider.embedding_max_response_bytes = try parseProviderResponseBytes(bytes);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_LLM_MAX_RESPONSE_BYTES")) |bytes| {
        defer allocator.free(bytes);
        cfg.provider.completion_max_response_bytes = try parseProviderResponseBytes(bytes);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_PROVIDER_CIRCUIT_FAILURE_THRESHOLD")) |threshold| {
        defer allocator.free(threshold);
        cfg.provider.circuit_failure_threshold = try parseCircuitFailureThreshold(threshold, cfg.provider.circuit_failure_threshold);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_PROVIDER_CIRCUIT_COOLDOWN_MS")) |cooldown| {
        defer allocator.free(cooldown);
        cfg.provider.circuit_cooldown_ms = try parseCircuitCooldownMs(cooldown, cfg.provider.circuit_cooldown_ms);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_EMBEDDING_FALLBACKS")) |fallbacks| {
        state.setEmbeddingFallbacks(allocator, fallbacks, true);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_EMBEDDING_ROUTES")) |routes| {
        state.setEmbeddingRoutes(allocator, routes, true);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_WORKER_INTERVAL_MS")) |interval| {
        defer allocator.free(interval);
        cfg.worker_interval_ms = try std.fmt.parseInt(u64, interval, 10);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_TRUST_ACTOR_HEADERS")) |value| {
        defer allocator.free(value);
        cfg.auth.trust_actor_headers = try parseBool(value);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_ADAPTIVE_KEYWORD_MAX_TOKENS")) |value| {
        defer allocator.free(value);
        const parsed = try std.fmt.parseInt(u32, value, 10);
        cfg.retrieval.adaptive_keyword_max_tokens = retrieval.normalizeAdaptiveKeywordMaxTokens(parsed);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_ADAPTIVE_VECTOR_MIN_TOKENS")) |value| {
        defer allocator.free(value);
        const parsed = try std.fmt.parseInt(u32, value, 10);
        cfg.retrieval.adaptive_vector_min_tokens = retrieval.normalizeAdaptiveVectorMinTokens(parsed);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_RETRIEVAL_ROLLOUT_MODE")) |value| {
        defer allocator.free(value);
        cfg.retrieval.rollout_policy.mode = try lifecycle.RolloutMode.parse(value, false);
        state.retrieval_rollout_mode_configured = true;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_RETRIEVAL_ROLLOUT_PERCENT")) |value| {
        defer allocator.free(value);
        cfg.retrieval.rollout_policy.percent = try parsePercent(value);
        if (!state.retrieval_rollout_mode_configured) cfg.retrieval.rollout_policy.mode = .canary;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_RETRIEVAL_CANARY_PERCENT")) |value| {
        defer allocator.free(value);
        cfg.retrieval.rollout_policy.percent = try parsePercent(value);
        if (!state.retrieval_rollout_mode_configured) cfg.retrieval.rollout_policy.mode = .canary;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_RETRIEVAL_SHADOW_PERCENT")) |value| {
        defer allocator.free(value);
        cfg.retrieval.rollout_policy.shadow_percent = try parsePercent(value);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_RETRIEVAL_ROLLOUT_SALT")) |value| {
        cfg.retrieval.rollout_policy.salt = value;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_RETRIEVAL_ROLLOUT_DISABLED")) |value| {
        defer allocator.free(value);
        cfg.retrieval.rollout_policy.disabled = try parseBool(value);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_RETRIEVAL_ROLLOUT_REQUIRED_SCOPES")) |value| {
        cfg.retrieval.rollout_policy.required_scopes_json = value;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_RETRIEVAL_ROLLOUT_BLOCKED_SCOPES")) |value| {
        cfg.retrieval.rollout_policy.blocked_scopes_json = value;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_RETRIEVAL_ROLLOUT_TARGET_SCOPES")) |value| {
        cfg.retrieval.rollout_policy.target_scopes_json = value;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_RETRIEVAL_ROLLOUT_REQUIRED_CAPABILITIES")) |value| {
        cfg.retrieval.rollout_policy.required_capabilities_json = value;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_RETRIEVAL_ROLLOUT_BLOCKED_CAPABILITIES")) |value| {
        cfg.retrieval.rollout_policy.blocked_capabilities_json = value;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_AGENT_MEMORY_BACKEND")) |backend| {
        defer allocator.free(backend);
        cfg.stores.agent_memory_backend = try agent_memory_config.BackendKind.parse(backend);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_AGENT_MEMORY_MARKDOWN_WORKSPACE")) |workspace| {
        cfg.stores.markdown_agent_memory.workspace_dir = workspace;
        cfg.stores.agent_memory_backend = .markdown;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_MARKDOWN_WORKSPACE")) |workspace| {
        cfg.stores.markdown_agent_memory.workspace_dir = workspace;
        cfg.stores.agent_memory_backend = .markdown;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_AGENT_MEMORY_MARKDOWN_MAX_FILE_BYTES")) |bytes| {
        defer allocator.free(bytes);
        cfg.stores.markdown_agent_memory.max_file_bytes = try parseMarkdownFileBytes(bytes, cfg.stores.markdown_agent_memory.max_file_bytes);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_AGENT_MEMORY_API_URL")) |url| {
        cfg.stores.api_agent_memory.base_url = url;
        cfg.stores.agent_memory_backend = .api;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_AGENT_MEMORY_API_TOKEN")) |token| {
        cfg.stores.api_agent_memory.token = token;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_AGENT_MEMORY_API_STORAGE")) |storage| {
        cfg.stores.api_agent_memory.remote_storage = storage;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_AGENT_MEMORY_API_SCOPES")) |scopes| {
        cfg.stores.api_agent_memory.actor_scopes_json = scopes;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_AGENT_MEMORY_API_CAPABILITIES")) |capabilities| {
        cfg.stores.api_agent_memory.actor_capabilities_json = capabilities;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_AGENT_MEMORY_API_TIMEOUT_SECS")) |secs| {
        defer allocator.free(secs);
        cfg.stores.api_agent_memory.timeout_secs = try parseRuntimeTimeoutSecs(secs, cfg.stores.api_agent_memory.timeout_secs);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_AGENT_MEMORY_API_MAX_RESPONSE_BYTES")) |bytes| {
        defer allocator.free(bytes);
        cfg.stores.api_agent_memory.max_response_bytes = agent_memory_config.boundedRemoteResponseBytes(try std.fmt.parseInt(i64, bytes, 10), cfg.stores.api_agent_memory.max_response_bytes);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_AGENT_MEMORY_API_ALLOW_INSECURE_HTTP")) |value| {
        defer allocator.free(value);
        cfg.stores.api_agent_memory.allow_insecure_http = try parseBool(value);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_AGENT_MEMORY_API_PROFILE")) |profile| {
        defer allocator.free(profile);
        applyRuntimeAgentMemoryApiProfile(cfg, try agent_memory_config.ApiProfile.parse(profile));
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_AGENT_MEMORY_SUPERMEMORY_URL")) |url| {
        applyRuntimeAgentMemoryApiProfile(cfg, .supermemory);
        cfg.stores.api_agent_memory.base_url = url;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_SUPERMEMORY_URL")) |url| {
        applyRuntimeAgentMemoryApiProfile(cfg, .supermemory);
        cfg.stores.api_agent_memory.base_url = url;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_AGENT_MEMORY_SUPERMEMORY_API_KEY")) |token| {
        applyRuntimeAgentMemoryApiProfile(cfg, .supermemory);
        cfg.stores.api_agent_memory.token = token;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_SUPERMEMORY_API_KEY")) |token| {
        applyRuntimeAgentMemoryApiProfile(cfg, .supermemory);
        cfg.stores.api_agent_memory.token = token;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_AGENT_MEMORY_OPENVIKING_URL")) |url| {
        applyRuntimeAgentMemoryApiProfile(cfg, .openviking);
        cfg.stores.api_agent_memory.base_url = url;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_OPENVIKING_URL")) |url| {
        applyRuntimeAgentMemoryApiProfile(cfg, .openviking);
        cfg.stores.api_agent_memory.base_url = url;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_AGENT_MEMORY_OPENVIKING_API_KEY")) |token| {
        applyRuntimeAgentMemoryApiProfile(cfg, .openviking);
        cfg.stores.api_agent_memory.token = token;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_OPENVIKING_API_KEY")) |token| {
        applyRuntimeAgentMemoryApiProfile(cfg, .openviking);
        cfg.stores.api_agent_memory.token = token;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_AGENT_MEMORY_HONCHO_URL")) |url| {
        applyRuntimeAgentMemoryApiProfile(cfg, .honcho);
        cfg.stores.api_agent_memory.base_url = url;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_HONCHO_URL")) |url| {
        applyRuntimeAgentMemoryApiProfile(cfg, .honcho);
        cfg.stores.api_agent_memory.base_url = url;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_AGENT_MEMORY_HONCHO_API_KEY")) |token| {
        applyRuntimeAgentMemoryApiProfile(cfg, .honcho);
        cfg.stores.api_agent_memory.token = token;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_HONCHO_API_KEY")) |token| {
        applyRuntimeAgentMemoryApiProfile(cfg, .honcho);
        cfg.stores.api_agent_memory.token = token;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_AGENT_MEMORY_HONCHO_WORKSPACE_ID")) |workspace_id| {
        applyRuntimeAgentMemoryApiProfile(cfg, .honcho);
        cfg.stores.api_agent_memory.workspace_id = workspace_id;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_HONCHO_WORKSPACE_ID")) |workspace_id| {
        applyRuntimeAgentMemoryApiProfile(cfg, .honcho);
        cfg.stores.api_agent_memory.workspace_id = workspace_id;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_AGENT_MEMORY_MEM0_URL")) |url| {
        applyRuntimeAgentMemoryApiProfile(cfg, .mem0);
        cfg.stores.api_agent_memory.base_url = url;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_MEM0_URL")) |url| {
        applyRuntimeAgentMemoryApiProfile(cfg, .mem0);
        cfg.stores.api_agent_memory.base_url = url;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_AGENT_MEMORY_MEM0_API_KEY")) |token| {
        applyRuntimeAgentMemoryApiProfile(cfg, .mem0);
        cfg.stores.api_agent_memory.token = token;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_MEM0_API_KEY")) |token| {
        applyRuntimeAgentMemoryApiProfile(cfg, .mem0);
        cfg.stores.api_agent_memory.token = token;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_AGENT_MEMORY_HINDSIGHT_URL")) |url| {
        applyRuntimeAgentMemoryApiProfile(cfg, .hindsight);
        cfg.stores.api_agent_memory.base_url = url;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_HINDSIGHT_URL")) |url| {
        applyRuntimeAgentMemoryApiProfile(cfg, .hindsight);
        cfg.stores.api_agent_memory.base_url = url;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_AGENT_MEMORY_HINDSIGHT_API_KEY")) |token| {
        applyRuntimeAgentMemoryApiProfile(cfg, .hindsight);
        cfg.stores.api_agent_memory.token = token;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_HINDSIGHT_API_KEY")) |token| {
        applyRuntimeAgentMemoryApiProfile(cfg, .hindsight);
        cfg.stores.api_agent_memory.token = token;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_AGENT_MEMORY_HINDSIGHT_BANK_ID")) |bank_id| {
        applyRuntimeAgentMemoryApiProfile(cfg, .hindsight);
        cfg.stores.api_agent_memory.workspace_id = bank_id;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_HINDSIGHT_BANK_ID")) |bank_id| {
        applyRuntimeAgentMemoryApiProfile(cfg, .hindsight);
        cfg.stores.api_agent_memory.workspace_id = bank_id;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_AGENT_MEMORY_RETAINDB_URL")) |url| {
        applyRuntimeAgentMemoryApiProfile(cfg, .retaindb);
        cfg.stores.api_agent_memory.base_url = url;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_RETAINDB_URL")) |url| {
        applyRuntimeAgentMemoryApiProfile(cfg, .retaindb);
        cfg.stores.api_agent_memory.base_url = url;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_AGENT_MEMORY_RETAINDB_API_KEY")) |token| {
        applyRuntimeAgentMemoryApiProfile(cfg, .retaindb);
        cfg.stores.api_agent_memory.token = token;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_RETAINDB_API_KEY")) |token| {
        applyRuntimeAgentMemoryApiProfile(cfg, .retaindb);
        cfg.stores.api_agent_memory.token = token;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_AGENT_MEMORY_RETAINDB_PROJECT")) |project| {
        applyRuntimeAgentMemoryApiProfile(cfg, .retaindb);
        cfg.stores.api_agent_memory.workspace_id = project;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_RETAINDB_PROJECT")) |project| {
        applyRuntimeAgentMemoryApiProfile(cfg, .retaindb);
        cfg.stores.api_agent_memory.workspace_id = project;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_AGENT_MEMORY_BYTEROVER_COMMAND")) |command| {
        applyRuntimeAgentMemoryApiProfile(cfg, .byterover);
        cfg.stores.api_agent_memory.byterover_command = command;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_BYTEROVER_COMMAND")) |command| {
        applyRuntimeAgentMemoryApiProfile(cfg, .byterover);
        cfg.stores.api_agent_memory.byterover_command = command;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_AGENT_MEMORY_BYTEROVER_PROJECT_DIR")) |project_dir| {
        applyRuntimeAgentMemoryApiProfile(cfg, .byterover);
        cfg.stores.api_agent_memory.byterover_project_dir = project_dir;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_BYTEROVER_PROJECT_DIR")) |project_dir| {
        applyRuntimeAgentMemoryApiProfile(cfg, .byterover);
        cfg.stores.api_agent_memory.byterover_project_dir = project_dir;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_AGENT_MEMORY_BYTEROVER_USE_SWARM")) |value| {
        defer allocator.free(value);
        applyRuntimeAgentMemoryApiProfile(cfg, .byterover);
        cfg.stores.api_agent_memory.byterover_use_swarm = try parseBool(value);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_BYTEROVER_USE_SWARM")) |value| {
        defer allocator.free(value);
        applyRuntimeAgentMemoryApiProfile(cfg, .byterover);
        cfg.stores.api_agent_memory.byterover_use_swarm = try parseBool(value);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_AGENT_MEMORY_ZEP_URL")) |url| {
        applyRuntimeAgentMemoryApiProfile(cfg, .zep);
        cfg.stores.api_agent_memory.base_url = url;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_ZEP_URL")) |url| {
        applyRuntimeAgentMemoryApiProfile(cfg, .zep);
        cfg.stores.api_agent_memory.base_url = url;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_AGENT_MEMORY_ZEP_API_KEY")) |token| {
        applyRuntimeAgentMemoryApiProfile(cfg, .zep);
        cfg.stores.api_agent_memory.token = token;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_ZEP_API_KEY")) |token| {
        applyRuntimeAgentMemoryApiProfile(cfg, .zep);
        cfg.stores.api_agent_memory.token = token;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_AGENT_MEMORY_ZEP_GRAPH_ID")) |graph_id| {
        applyRuntimeAgentMemoryApiProfile(cfg, .zep);
        cfg.stores.api_agent_memory.workspace_id = graph_id;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_ZEP_GRAPH_ID")) |graph_id| {
        applyRuntimeAgentMemoryApiProfile(cfg, .zep);
        cfg.stores.api_agent_memory.workspace_id = graph_id;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_AGENT_MEMORY_FALKORDB_URL")) |url| {
        applyRuntimeAgentMemoryApiProfile(cfg, .falkordb);
        cfg.stores.api_agent_memory.base_url = url;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_FALKORDB_URL")) |url| {
        applyRuntimeAgentMemoryApiProfile(cfg, .falkordb);
        cfg.stores.api_agent_memory.base_url = url;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_AGENT_MEMORY_FALKORDB_API_KEY")) |token| {
        applyRuntimeAgentMemoryApiProfile(cfg, .falkordb);
        cfg.stores.api_agent_memory.token = token;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_FALKORDB_API_KEY")) |token| {
        applyRuntimeAgentMemoryApiProfile(cfg, .falkordb);
        cfg.stores.api_agent_memory.token = token;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_AGENT_MEMORY_FALKORDB_GRAPH")) |graph| {
        applyRuntimeAgentMemoryApiProfile(cfg, .falkordb);
        cfg.stores.api_agent_memory.workspace_id = graph;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_FALKORDB_GRAPH")) |graph| {
        applyRuntimeAgentMemoryApiProfile(cfg, .falkordb);
        cfg.stores.api_agent_memory.workspace_id = graph;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_AGENT_MEMORY_HOLOGRAPHIC_DB_PATH")) |path| {
        cfg.stores.agent_memory_backend = .holographic;
        cfg.stores.holographic_agent_memory.db_path = path;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_HOLOGRAPHIC_DB_PATH")) |path| {
        cfg.stores.agent_memory_backend = .holographic;
        cfg.stores.holographic_agent_memory.db_path = path;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_HOLOGRAPHIC_DEFAULT_TRUST")) |value| {
        defer allocator.free(value);
        cfg.stores.holographic_agent_memory.default_trust = try std.fmt.parseFloat(f64, value);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_HOLOGRAPHIC_TRUST_REWARD")) |value| {
        defer allocator.free(value);
        cfg.stores.holographic_agent_memory.trust_reward = try std.fmt.parseFloat(f64, value);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_HOLOGRAPHIC_TRUST_PENALTY")) |value| {
        defer allocator.free(value);
        cfg.stores.holographic_agent_memory.trust_penalty = try std.fmt.parseFloat(f64, value);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_MEMORY_LRU_MAX_ENTRIES")) |max_entries| {
        defer allocator.free(max_entries);
        cfg.stores.memory.max_entries = try std.fmt.parseInt(usize, max_entries, 10);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_MEMORY_LRU_MAX_MESSAGES")) |max_messages| {
        defer allocator.free(max_messages);
        cfg.stores.memory.max_messages = try std.fmt.parseInt(usize, max_messages, 10);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_MEMORY_LRU_MAX_USAGE_ENTRIES")) |max_usage_entries| {
        defer allocator.free(max_usage_entries);
        cfg.stores.memory.max_usage_entries = try std.fmt.parseInt(usize, max_usage_entries, 10);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_MEMORY_LRU_MAX_BYTES")) |max_bytes| {
        defer allocator.free(max_bytes);
        cfg.stores.memory.max_bytes = try std.fmt.parseInt(usize, max_bytes, 10);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_MEMORY_LRU_TTL_SECONDS")) |ttl| {
        defer allocator.free(ttl);
        cfg.stores.memory.ttl_seconds = try std.fmt.parseInt(u32, ttl, 10);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_REDIS_URL")) |url| {
        cfg.stores.redis = try redis_config.parseUrl(allocator, url);
        cfg.stores.agent_memory_backend = .redis;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_REDIS_KEY_PREFIX")) |prefix| {
        cfg.stores.redis.key_prefix = prefix;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_REDIS_TTL_SECONDS")) |ttl| {
        defer allocator.free(ttl);
        cfg.stores.redis.ttl_seconds = try std.fmt.parseInt(u32, ttl, 10);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_AGENT_MEMORY_CLICKHOUSE_URL")) |url| {
        cfg.stores.clickhouse_agent_memory.base_url = url;
        cfg.stores.agent_memory_backend = .clickhouse;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_CLICKHOUSE_AGENT_MEMORY_URL")) |url| {
        cfg.stores.clickhouse_agent_memory.base_url = url;
        cfg.stores.agent_memory_backend = .clickhouse;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_AGENT_MEMORY_CLICKHOUSE_API_KEY")) |key| {
        cfg.stores.clickhouse_agent_memory.api_key = key;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_AGENT_MEMORY_CLICKHOUSE_TABLE")) |table| {
        cfg.stores.clickhouse_agent_memory.table = table;
        cfg.stores.agent_memory_backend = .clickhouse;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_AGENT_MEMORY_CLICKHOUSE_TIMEOUT_SECS")) |secs| {
        defer allocator.free(secs);
        cfg.stores.clickhouse_agent_memory.timeout_secs = try parseRuntimeTimeoutSecs(secs, cfg.stores.clickhouse_agent_memory.timeout_secs);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_AGENT_MEMORY_CLICKHOUSE_MAX_RESPONSE_BYTES")) |bytes| {
        defer allocator.free(bytes);
        cfg.stores.clickhouse_agent_memory.max_response_bytes = agent_memory_config.boundedRemoteResponseBytes(try std.fmt.parseInt(i64, bytes, 10), cfg.stores.clickhouse_agent_memory.max_response_bytes);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_AGENT_MEMORY_CLICKHOUSE_ALLOW_INSECURE_HTTP")) |value| {
        defer allocator.free(value);
        cfg.stores.clickhouse_agent_memory.allow_insecure_http = try parseBool(value);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_AGENT_MEMORY_STORES")) |raw| {
        defer allocator.free(raw);
        cfg.stores.agent_memory_stores = try parseAgentMemoryStoreConfigsJson(allocator, raw);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_VECTOR_STORES")) |raw| {
        defer allocator.free(raw);
        cfg.stores.vector_stores = try parseVectorStoreConfigsJson(allocator, raw);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_CHUNK_MAX_CHARS")) |value| {
        defer allocator.free(value);
        cfg.retrieval.chunker.max_chars = try parsePositiveUsize(value);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_CHUNK_OVERLAP_CHARS")) |value| {
        defer allocator.free(value);
        cfg.retrieval.chunker.overlap_chars = try std.fmt.parseInt(usize, value, 10);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_CHUNK_MAX_TOKENS")) |value| {
        defer allocator.free(value);
        cfg.retrieval.chunker.max_tokens = try parsePositiveUsize(value);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_CHUNK_STRATEGY")) |value| {
        defer allocator.free(value);
        cfg.retrieval.chunker.strategy = try vector_mod.ChunkStrategy.parse(value);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_VECTOR_BACKEND")) |backend| {
        defer allocator.free(backend);
        cfg.stores.vector_backend.backend = try vector_runtime.BackendKind.parse(backend);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_VECTOR_BASE_URL")) |url| {
        cfg.stores.vector_backend.base_url = url;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_VECTOR_API_KEY")) |key| {
        cfg.stores.vector_backend.api_key = key;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_VECTOR_API_KEY_HEADER")) |header| {
        cfg.stores.vector_backend.api_key_header = header;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_VECTOR_COLLECTION")) |collection| {
        cfg.stores.vector_backend.collection = collection;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_VECTOR_POSTGRES_URL")) |url| {
        cfg.stores.vector_backend.backend = .pgvector;
        cfg.stores.vector_backend.postgres_url = url;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_VECTOR_TIMEOUT_SECS")) |secs| {
        defer allocator.free(secs);
        cfg.stores.vector_backend.timeout_secs = try parseRuntimeTimeoutSecs(secs, cfg.stores.vector_backend.timeout_secs);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_VECTOR_SQLITE_ANN_CANDIDATE_MULTIPLIER")) |value| {
        defer allocator.free(value);
        const parsed = try std.fmt.parseInt(u32, value, 10);
        cfg.stores.vector_backend.sqlite_ann_candidate_multiplier = vector_runtime.normalizeSqliteAnnCandidateMultiplier(parsed);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_VECTOR_SQLITE_ANN_MIN_CANDIDATES")) |value| {
        defer allocator.free(value);
        const parsed = try std.fmt.parseInt(u32, value, 10);
        cfg.stores.vector_backend.sqlite_ann_min_candidates = vector_runtime.normalizeSqliteAnnMinCandidates(parsed);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_VECTOR_ALLOW_INSECURE_HTTP")) |value| {
        defer allocator.free(value);
        cfg.stores.vector_backend.allow_insecure_http = try parseBool(value);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_VECTOR_CIRCUIT_BREAKER_ENABLED")) |value| {
        defer allocator.free(value);
        cfg.stores.vector_backend.circuit_breaker_enabled = try parseBool(value);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_VECTOR_CIRCUIT_BREAKER_THRESHOLD")) |value| {
        defer allocator.free(value);
        cfg.stores.vector_backend.circuit_breaker_threshold = try parseCircuitFailureThreshold(value, cfg.stores.vector_backend.circuit_breaker_threshold);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_VECTOR_CIRCUIT_BREAKER_COOLDOWN_MS")) |value| {
        defer allocator.free(value);
        cfg.stores.vector_backend.circuit_breaker_cooldown_ms = try parseCircuitCooldownMsU64(value, cfg.stores.vector_backend.circuit_breaker_cooldown_ms);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_QDRANT_URL")) |url| {
        cfg.stores.vector_backend.backend = .qdrant;
        cfg.stores.vector_backend.base_url = url;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_QDRANT_API_KEY")) |key| {
        cfg.stores.vector_backend.api_key = key;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_QDRANT_API_KEY_HEADER")) |header| {
        cfg.stores.vector_backend.backend = .qdrant;
        cfg.stores.vector_backend.api_key_header = header;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_QDRANT_COLLECTION")) |collection| {
        cfg.stores.vector_backend.backend = .qdrant;
        cfg.stores.vector_backend.collection = collection;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_QDRANT_ALLOW_INSECURE_HTTP")) |value| {
        defer allocator.free(value);
        cfg.stores.vector_backend.backend = .qdrant;
        cfg.stores.vector_backend.allow_insecure_http = try parseBool(value);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_PGVECTOR_URL")) |url| {
        cfg.stores.vector_backend.backend = .pgvector;
        cfg.stores.vector_backend.postgres_url = url;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_PGVECTOR_TABLE")) |table| {
        cfg.stores.vector_backend.backend = .pgvector;
        cfg.stores.vector_backend.collection = table;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_LANCEDB_URI")) |uri| {
        cfg.stores.vector_backend.backend = .lancedb;
        cfg.stores.vector_backend.lancedb_uri = uri;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_LANCEDB_COMMAND")) |command| {
        cfg.stores.vector_backend.backend = .lancedb;
        cfg.stores.vector_backend.lancedb_command = command;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_LANCEDB_URL")) |url| {
        if (cfg.stores.vector_backend.lancedb_uri == null) cfg.stores.vector_backend.backend = .lancedb_http;
        cfg.stores.vector_backend.base_url = url;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_LANCEDB_API_KEY")) |key| {
        cfg.stores.vector_backend.api_key = key;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_LANCEDB_TABLE")) |table| {
        cfg.stores.vector_backend.collection = table;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_LANCEDB_ALLOW_INSECURE_HTTP")) |value| {
        defer allocator.free(value);
        cfg.stores.vector_backend.allow_insecure_http = try parseBool(value);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_WEAVIATE_URL")) |url| {
        cfg.stores.vector_backend.backend = .weaviate;
        cfg.stores.vector_backend.base_url = url;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_WEAVIATE_API_KEY")) |key| {
        cfg.stores.vector_backend.api_key = key;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_WEAVIATE_COLLECTION")) |collection| {
        cfg.stores.vector_backend.backend = .weaviate;
        cfg.stores.vector_backend.collection = collection;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_CHROMA_URL")) |url| {
        cfg.stores.vector_backend.backend = .chroma;
        cfg.stores.vector_backend.base_url = url;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_CHROMA_TOKEN")) |token| {
        cfg.stores.vector_backend.api_key = token;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_CHROMA_TENANT")) |tenant| {
        cfg.stores.vector_backend.backend = .chroma;
        cfg.stores.vector_backend.chroma_tenant = tenant;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_CHROMA_DATABASE")) |database| {
        cfg.stores.vector_backend.backend = .chroma;
        cfg.stores.vector_backend.chroma_database = database;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_CHROMA_COLLECTION")) |collection| {
        cfg.stores.vector_backend.backend = .chroma;
        cfg.stores.vector_backend.collection = collection;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_CHROMA_COLLECTION_ID")) |collection| {
        cfg.stores.vector_backend.backend = .chroma;
        cfg.stores.vector_backend.collection = collection;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_OPENSEARCH_URL")) |url| {
        cfg.stores.vector_backend.backend = .opensearch;
        cfg.stores.vector_backend.base_url = url;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_OPENSEARCH_API_KEY")) |key| {
        cfg.stores.vector_backend.api_key = key;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_OPENSEARCH_INDEX")) |index| {
        cfg.stores.vector_backend.backend = .opensearch;
        cfg.stores.vector_backend.collection = index;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_GRAPH_BACKEND")) |backend| {
        defer allocator.free(backend);
        cfg.stores.graph_projection.backend = try graph_runtime.BackendKind.parse(backend);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_GRAPH_BASE_URL")) |url| {
        cfg.stores.graph_projection.base_url = url;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_GRAPH_API_KEY")) |key| {
        cfg.stores.graph_projection.api_key = key;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_GRAPH_DATABASE")) |database| {
        cfg.stores.graph_projection.database = database;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_GRAPH_NAME")) |graph| {
        cfg.stores.graph_projection.graph = graph;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_GRAPH_TIMEOUT_SECS")) |secs| {
        defer allocator.free(secs);
        cfg.stores.graph_projection.timeout_secs = try parseRuntimeTimeoutSecs(secs, cfg.stores.graph_projection.timeout_secs);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_GRAPH_ALLOW_INSECURE_HTTP")) |value| {
        defer allocator.free(value);
        cfg.stores.graph_projection.allow_insecure_http = try parseBool(value);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_GRAPH_PROJECT_SCOPES")) |scopes| {
        cfg.stores.graph_projection.project_scopes_json = scopes;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_NEO4J_URL")) |url| {
        cfg.stores.graph_projection.backend = .neo4j;
        cfg.stores.graph_projection.base_url = url;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_NEO4J_API_KEY")) |key| {
        cfg.stores.graph_projection.api_key = key;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_NEO4J_DATABASE")) |database| {
        cfg.stores.graph_projection.backend = .neo4j;
        cfg.stores.graph_projection.database = database;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_GRAPH_FALKORDB_URL")) |url| {
        cfg.stores.graph_projection.backend = .falkordb;
        cfg.stores.graph_projection.base_url = url;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_GRAPH_FALKORDB_API_KEY")) |key| {
        cfg.stores.graph_projection.api_key = key;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_GRAPH_FALKORDB_NAME")) |graph| {
        cfg.stores.graph_projection.backend = .falkordb;
        cfg.stores.graph_projection.graph = graph;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_ANALYTICS_BACKEND")) |backend| {
        defer allocator.free(backend);
        cfg.stores.analytics_backend.backend = try analytics_runtime.BackendKind.parse(backend);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_ANALYTICS_BASE_URL")) |url| {
        cfg.stores.analytics_backend.base_url = url;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_ANALYTICS_API_KEY")) |key| {
        cfg.stores.analytics_backend.api_key = key;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_ANALYTICS_TABLE")) |table| {
        cfg.stores.analytics_backend.table = table;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_ANALYTICS_TIMEOUT_SECS")) |secs| {
        defer allocator.free(secs);
        cfg.stores.analytics_backend.timeout_secs = try parseRuntimeTimeoutSecs(secs, cfg.stores.analytics_backend.timeout_secs);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_ANALYTICS_ALLOW_INSECURE_HTTP")) |value| {
        defer allocator.free(value);
        cfg.stores.analytics_backend.allow_insecure_http = try parseBool(value);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_CLICKHOUSE_URL")) |url| {
        cfg.stores.analytics_backend.backend = .clickhouse;
        cfg.stores.analytics_backend.base_url = url;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_CLICKHOUSE_API_KEY")) |key| {
        cfg.stores.analytics_backend.api_key = key;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_CLICKHOUSE_TABLE")) |table| {
        cfg.stores.analytics_backend.backend = .clickhouse;
        cfg.stores.analytics_backend.table = table;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_CLICKHOUSE_ALLOW_INSECURE_HTTP")) |value| {
        defer allocator.free(value);
        cfg.stores.analytics_backend.backend = .clickhouse;
        cfg.stores.analytics_backend.allow_insecure_http = try parseBool(value);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_LUCID_ENABLED")) |value| {
        defer allocator.free(value);
        cfg.stores.lucid_projection.enabled = try parseBool(value);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_LUCID_COMMAND")) |command| {
        cfg.stores.lucid_projection.command = command;
        cfg.stores.lucid_projection.enabled = true;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_LUCID_WORKSPACE")) |workspace| {
        cfg.stores.lucid_projection.workspace_dir = workspace;
        cfg.stores.lucid_projection.enabled = true;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_LUCID_TOKEN_BUDGET")) |budget| {
        defer allocator.free(budget);
        cfg.stores.lucid_projection.token_budget = try parseLucidTokenBudget(budget, cfg.stores.lucid_projection.token_budget);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_LUCID_LOCAL_HIT_THRESHOLD")) |threshold| {
        defer allocator.free(threshold);
        cfg.stores.lucid_projection.local_hit_threshold = try parseLucidLocalHitThreshold(threshold, cfg.stores.lucid_projection.local_hit_threshold);
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_LUCID_PROJECT_SCOPES")) |scopes| {
        cfg.stores.lucid_projection.project_scopes_json = scopes;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_LUCID_RESULT_SCOPE")) |scope| {
        cfg.stores.lucid_projection.result_scope = scope;
    } else |_| {}
    if (env.get(allocator, "NULLPANTRY_LUCID_PERMISSIONS")) |permissions| {
        cfg.stores.lucid_projection.permissions_json = permissions;
    } else |_| {}
}

fn cliOptionTakesValue(arg: []const u8) bool {
    const options = [_][]const u8{
        "-c",
        "--home",
        "--config",
        "--host",
        "--port",
        "--instance-id",
        "--db",
        "--db-path",
        "--backend",
        "--records-backend",
        "--postgres-url",
        "--token",
        "--token-principals",
        "--filesystem-root",
        "--actor-scopes",
        "--actor-capabilities",
        "--worker-scopes",
        "--worker-capabilities",
        "--embedding-base-url",
        "--embedding-api-key",
        "--embedding-model",
        "--embedding-provider",
        "--embedding-fallbacks",
        "--embedding-routes",
        "--embedding-dimensions",
        "--llm-base-url",
        "--llm-api-key",
        "--llm-model",
        "--provider-timeout-secs",
        "--provider-max-response-bytes",
        "--embedding-max-response-bytes",
        "--llm-max-response-bytes",
        "--provider-circuit-failure-threshold",
        "--provider-circuit-cooldown-ms",
        "--worker-interval-ms",
        "--adaptive-keyword-max-tokens",
        "--adaptive-vector-min-tokens",
        "--retrieval-rollout-mode",
        "--retrieval-rollout-percent",
        "--retrieval-canary-percent",
        "--retrieval-shadow-percent",
        "--retrieval-rollout-salt",
        "--retrieval-rollout-required-scopes",
        "--retrieval-rollout-blocked-scopes",
        "--retrieval-rollout-target-scopes",
        "--retrieval-rollout-required-capabilities",
        "--retrieval-rollout-blocked-capabilities",
        "--agent-memory-backend",
        "--agent-memory-markdown-workspace",
        "--markdown-workspace",
        "--agent-memory-markdown-max-file-bytes",
        "--agent-memory-api-url",
        "--agent-memory-api-token",
        "--agent-memory-api-storage",
        "--agent-memory-api-scopes",
        "--agent-memory-api-capabilities",
        "--agent-memory-api-timeout-secs",
        "--agent-memory-api-max-response-bytes",
        "--agent-memory-api-profile",
        "--agent-memory-supermemory-url",
        "--supermemory-url",
        "--agent-memory-supermemory-api-key",
        "--supermemory-api-key",
        "--agent-memory-openviking-url",
        "--openviking-url",
        "--agent-memory-openviking-api-key",
        "--openviking-api-key",
        "--agent-memory-honcho-url",
        "--honcho-url",
        "--agent-memory-honcho-api-key",
        "--honcho-api-key",
        "--agent-memory-honcho-workspace-id",
        "--honcho-workspace-id",
        "--agent-memory-mem0-url",
        "--mem0-url",
        "--agent-memory-mem0-api-key",
        "--mem0-api-key",
        "--agent-memory-hindsight-url",
        "--hindsight-url",
        "--agent-memory-hindsight-api-key",
        "--hindsight-api-key",
        "--agent-memory-hindsight-bank-id",
        "--hindsight-bank-id",
        "--agent-memory-retaindb-url",
        "--retaindb-url",
        "--agent-memory-retaindb-api-key",
        "--retaindb-api-key",
        "--agent-memory-retaindb-project",
        "--retaindb-project",
        "--agent-memory-byterover-command",
        "--byterover-command",
        "--agent-memory-byterover-project-dir",
        "--byterover-project-dir",
        "--agent-memory-zep-url",
        "--zep-url",
        "--agent-memory-zep-api-key",
        "--zep-api-key",
        "--agent-memory-zep-graph-id",
        "--zep-graph-id",
        "--agent-memory-falkordb-url",
        "--falkordb-url",
        "--agent-memory-falkordb-api-key",
        "--falkordb-api-key",
        "--agent-memory-falkordb-graph",
        "--falkordb-graph",
        "--agent-memory-holographic-db-path",
        "--holographic-db-path",
        "--holographic-default-trust",
        "--holographic-trust-reward",
        "--holographic-trust-penalty",
        "--memory-lru-max-entries",
        "--memory-lru-max-messages",
        "--memory-lru-max-usage-entries",
        "--memory-lru-max-bytes",
        "--memory-lru-ttl-seconds",
        "--redis-url",
        "--redis-key-prefix",
        "--redis-ttl-seconds",
        "--agent-memory-clickhouse-url",
        "--agent-memory-clickhouse-api-key",
        "--agent-memory-clickhouse-table",
        "--agent-memory-clickhouse-timeout-secs",
        "--agent-memory-clickhouse-max-response-bytes",
        "--agent-memory-store",
        "--vector-store",
        "--chunk-max-chars",
        "--chunk-overlap-chars",
        "--chunk-max-tokens",
        "--chunk-strategy",
        "--vector-backend",
        "--vector-base-url",
        "--vector-api-key",
        "--vector-api-key-header",
        "--vector-collection",
        "--vector-postgres-url",
        "--vector-timeout-secs",
        "--vector-sqlite-ann-candidate-multiplier",
        "--vector-sqlite-ann-min-candidates",
        "--vector-circuit-breaker-threshold",
        "--vector-circuit-breaker-cooldown-ms",
        "--lancedb-uri",
        "--lancedb-command",
        "--lancedb-table",
        "--lancedb-url",
        "--pgvector-url",
        "--pgvector-table",
        "--weaviate-url",
        "--weaviate-api-key",
        "--weaviate-collection",
        "--chroma-url",
        "--chroma-token",
        "--chroma-tenant",
        "--chroma-database",
        "--chroma-collection",
        "--chroma-collection-id",
        "--opensearch-url",
        "--opensearch-api-key",
        "--opensearch-index",
        "--graph-backend",
        "--graph-base-url",
        "--graph-api-key",
        "--graph-database",
        "--graph-name",
        "--graph-timeout-secs",
        "--graph-project-scopes",
        "--neo4j-url",
        "--neo4j-api-key",
        "--neo4j-database",
        "--graph-falkordb-url",
        "--graph-falkordb-api-key",
        "--graph-falkordb-name",
        "--analytics-backend",
        "--analytics-base-url",
        "--analytics-api-key",
        "--analytics-table",
        "--analytics-timeout-secs",
        "--lucid-command",
        "--lucid-workspace",
        "--lucid-token-budget",
        "--lucid-local-hit-threshold",
        "--lucid-project-scopes",
        "--lucid-result-scope",
        "--lucid-permissions",
    };
    for (options) |option| {
        if (std.mem.eql(u8, arg, option)) return true;
    }
    return false;
}

fn cliValueLooksLikeOption(value: []const u8) bool {
    return std.mem.startsWith(u8, value, "--") or std.mem.eql(u8, value, "-c");
}

fn validateCliArgumentShape(args: []const [:0]const u8) !void {
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.startsWith(u8, arg, "--home=")) {
            if (arg["--home=".len..].len == 0) return error.MissingArgumentValue;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--config=")) {
            if (arg["--config=".len..].len == 0) return error.MissingArgumentValue;
            continue;
        }
        if (!cliOptionTakesValue(arg)) continue;
        if (i + 1 >= args.len or cliValueLooksLikeOption(args[i + 1])) return error.MissingArgumentValue;
        i += 1;
    }
}

fn parseArgs(allocator: std.mem.Allocator, args: []const [:0]const u8) !RuntimeConfig {
    if (!argsContain(args, "--help") and !argsContain(args, "--version")) try validateCliArgumentShape(args);

    const env_home_path = try homePathFromEnv(allocator);
    defer if (env_home_path) |path| allocator.free(path);
    const home_path: ?[]const u8 = if (homePathFromArgs(args)) |path| path else env_home_path;

    var cfg = RuntimeConfig{};
    try applyHomeDefaults(allocator, &cfg, home_path);
    errdefer cfg.deinit(allocator);
    var config_file_env = try loadConfigFileEnv(allocator, args, home_path);
    defer config_file_env.deinit();
    var state = RuntimeConfigParseState{};
    defer state.deinit(allocator);

    try applyRuntimeEnv(allocator, &cfg, .{ .file = &config_file_env }, &state);
    try applyRuntimeEnv(allocator, &cfg, .process, &state);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--version")) {
            std.debug.print("nullpantry v{s}\n", .{build_options.version});
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--help")) {
            printUsage();
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--home") and i + 1 < args.len) {
            i += 1;
        } else if (std.mem.startsWith(u8, arg, "--home=")) {} else if ((std.mem.eql(u8, arg, "--config") or std.mem.eql(u8, arg, "-c")) and i + 1 < args.len) {
            i += 1;
        } else if (std.mem.startsWith(u8, arg, "--config=")) {} else if (std.mem.eql(u8, arg, "--host") and i + 1 < args.len) {
            i += 1;
            cfg.host = args[i];
        } else if (std.mem.eql(u8, arg, "--port") and i + 1 < args.len) {
            i += 1;
            cfg.port = try std.fmt.parseInt(u16, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--instance-id") and i + 1 < args.len) {
            i += 1;
            cfg.instance_id = args[i];
        } else if ((std.mem.eql(u8, arg, "--db") or std.mem.eql(u8, arg, "--db-path")) and i + 1 < args.len) {
            i += 1;
            cfg.db_path = args[i];
            cfg.stores.records_backend = .sqlite;
        } else if ((std.mem.eql(u8, arg, "--backend") or std.mem.eql(u8, arg, "--records-backend")) and i + 1 < args.len) {
            i += 1;
            cfg.stores.records_backend = try store_config.BackendKind.parse(args[i]);
        } else if (std.mem.eql(u8, arg, "--postgres-url") and i + 1 < args.len) {
            i += 1;
            cfg.stores.postgres_url = args[i];
            cfg.stores.records_backend = .postgres;
        } else if (std.mem.eql(u8, arg, "--run-legacy-compat-cleanup")) {
            cfg.run_legacy_compat_cleanup = true;
        } else if (std.mem.eql(u8, arg, "--token") and i + 1 < args.len) {
            i += 1;
            cfg.auth.required_token = args[i];
            cfg.actor.scopes_json = "[\"public\"]";
            cfg.actor.capabilities_json = "[\"read\"]";
        } else if (std.mem.eql(u8, arg, "--token-principals") and i + 1 < args.len) {
            i += 1;
            cfg.auth.token_principals_json = args[i];
        } else if (std.mem.eql(u8, arg, "--allow-no-auth-non-loopback")) {
            cfg.auth.allow_no_auth_non_loopback = true;
        } else if (std.mem.eql(u8, arg, "--filesystem-root") and i + 1 < args.len) {
            i += 1;
            cfg.filesystem.root = args[i];
        } else if (std.mem.eql(u8, arg, "--actor-scopes") and i + 1 < args.len) {
            i += 1;
            cfg.actor.scopes_json = args[i];
        } else if (std.mem.eql(u8, arg, "--actor-capabilities") and i + 1 < args.len) {
            i += 1;
            cfg.actor.capabilities_json = args[i];
        } else if (std.mem.eql(u8, arg, "--worker-scopes") and i + 1 < args.len) {
            i += 1;
            cfg.worker.scopes_json = args[i];
        } else if (std.mem.eql(u8, arg, "--worker-capabilities") and i + 1 < args.len) {
            i += 1;
            cfg.worker.capabilities_json = args[i];
        } else if (std.mem.eql(u8, arg, "--embedding-base-url") and i + 1 < args.len) {
            i += 1;
            cfg.provider.embedding.base_url = args[i];
        } else if (std.mem.eql(u8, arg, "--embedding-api-key") and i + 1 < args.len) {
            i += 1;
            cfg.provider.embedding.api_key = args[i];
        } else if (std.mem.eql(u8, arg, "--embedding-model") and i + 1 < args.len) {
            i += 1;
            cfg.provider.embedding.model = args[i];
        } else if (std.mem.eql(u8, arg, "--embedding-provider") and i + 1 < args.len) {
            i += 1;
            cfg.provider.embedding.provider = try providers.EmbeddingProviderKind.parse(args[i]);
        } else if (std.mem.eql(u8, arg, "--embedding-fallbacks") and i + 1 < args.len) {
            i += 1;
            state.setEmbeddingFallbacks(allocator, args[i], false);
        } else if (std.mem.eql(u8, arg, "--embedding-routes") and i + 1 < args.len) {
            i += 1;
            state.setEmbeddingRoutes(allocator, args[i], false);
        } else if (std.mem.eql(u8, arg, "--embedding-dimensions") and i + 1 < args.len) {
            i += 1;
            cfg.provider.embedding.dimensions = vector_mod.boundedEmbeddingDimensions(null, try std.fmt.parseInt(usize, args[i], 10));
            cfg.provider.embedding.send_dimensions = true;
        } else if (std.mem.eql(u8, arg, "--embedding-send-dimensions")) {
            cfg.provider.embedding.send_dimensions = true;
        } else if (std.mem.eql(u8, arg, "--no-embedding-send-dimensions")) {
            cfg.provider.embedding.send_dimensions = false;
        } else if (std.mem.eql(u8, arg, "--embedding-allow-insecure-http")) {
            cfg.provider.embedding.allow_insecure_http = true;
        } else if (std.mem.eql(u8, arg, "--llm-base-url") and i + 1 < args.len) {
            i += 1;
            cfg.provider.completion.base_url = args[i];
        } else if (std.mem.eql(u8, arg, "--llm-api-key") and i + 1 < args.len) {
            i += 1;
            cfg.provider.completion.api_key = args[i];
        } else if (std.mem.eql(u8, arg, "--llm-model") and i + 1 < args.len) {
            i += 1;
            cfg.provider.completion.model = args[i];
        } else if (std.mem.eql(u8, arg, "--llm-allow-insecure-http")) {
            cfg.provider.completion.allow_insecure_http = true;
        } else if (std.mem.eql(u8, arg, "--provider-allow-insecure-http")) {
            cfg.provider.embedding.allow_insecure_http = true;
            cfg.provider.completion.allow_insecure_http = true;
        } else if (std.mem.eql(u8, arg, "--provider-timeout-secs") and i + 1 < args.len) {
            i += 1;
            const timeout_secs = try parseProviderTimeoutSecs(args[i]);
            cfg.provider.embedding.timeout_secs = timeout_secs;
            cfg.provider.completion.timeout_secs = timeout_secs;
        } else if (std.mem.eql(u8, arg, "--provider-max-response-bytes") and i + 1 < args.len) {
            i += 1;
            cfg.provider.default_max_response_bytes = try parseProviderResponseBytes(args[i]);
        } else if (std.mem.eql(u8, arg, "--embedding-max-response-bytes") and i + 1 < args.len) {
            i += 1;
            cfg.provider.embedding_max_response_bytes = try parseProviderResponseBytes(args[i]);
        } else if (std.mem.eql(u8, arg, "--llm-max-response-bytes") and i + 1 < args.len) {
            i += 1;
            cfg.provider.completion_max_response_bytes = try parseProviderResponseBytes(args[i]);
        } else if (std.mem.eql(u8, arg, "--provider-circuit-failure-threshold") and i + 1 < args.len) {
            i += 1;
            cfg.provider.circuit_failure_threshold = try parseCircuitFailureThreshold(args[i], cfg.provider.circuit_failure_threshold);
        } else if (std.mem.eql(u8, arg, "--provider-circuit-cooldown-ms") and i + 1 < args.len) {
            i += 1;
            cfg.provider.circuit_cooldown_ms = try parseCircuitCooldownMs(args[i], cfg.provider.circuit_cooldown_ms);
        } else if (std.mem.eql(u8, arg, "--worker-interval-ms") and i + 1 < args.len) {
            i += 1;
            cfg.worker_interval_ms = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--trust-actor-headers")) {
            cfg.auth.trust_actor_headers = true;
        } else if (std.mem.eql(u8, arg, "--adaptive-keyword-max-tokens") and i + 1 < args.len) {
            i += 1;
            cfg.retrieval.adaptive_keyword_max_tokens = retrieval.normalizeAdaptiveKeywordMaxTokens(try std.fmt.parseInt(u32, args[i], 10));
        } else if (std.mem.eql(u8, arg, "--adaptive-vector-min-tokens") and i + 1 < args.len) {
            i += 1;
            cfg.retrieval.adaptive_vector_min_tokens = retrieval.normalizeAdaptiveVectorMinTokens(try std.fmt.parseInt(u32, args[i], 10));
        } else if (std.mem.eql(u8, arg, "--retrieval-rollout-mode") and i + 1 < args.len) {
            i += 1;
            cfg.retrieval.rollout_policy.mode = try lifecycle.RolloutMode.parse(args[i], false);
            state.retrieval_rollout_mode_configured = true;
        } else if ((std.mem.eql(u8, arg, "--retrieval-rollout-percent") or std.mem.eql(u8, arg, "--retrieval-canary-percent")) and i + 1 < args.len) {
            i += 1;
            cfg.retrieval.rollout_policy.percent = try parsePercent(args[i]);
            if (!state.retrieval_rollout_mode_configured) cfg.retrieval.rollout_policy.mode = .canary;
        } else if (std.mem.eql(u8, arg, "--retrieval-shadow-percent") and i + 1 < args.len) {
            i += 1;
            cfg.retrieval.rollout_policy.shadow_percent = try parsePercent(args[i]);
        } else if (std.mem.eql(u8, arg, "--retrieval-rollout-salt") and i + 1 < args.len) {
            i += 1;
            cfg.retrieval.rollout_policy.salt = args[i];
        } else if (std.mem.eql(u8, arg, "--retrieval-rollout-disabled")) {
            cfg.retrieval.rollout_policy.disabled = true;
        } else if (std.mem.eql(u8, arg, "--retrieval-rollout-required-scopes") and i + 1 < args.len) {
            i += 1;
            cfg.retrieval.rollout_policy.required_scopes_json = args[i];
        } else if (std.mem.eql(u8, arg, "--retrieval-rollout-blocked-scopes") and i + 1 < args.len) {
            i += 1;
            cfg.retrieval.rollout_policy.blocked_scopes_json = args[i];
        } else if (std.mem.eql(u8, arg, "--retrieval-rollout-target-scopes") and i + 1 < args.len) {
            i += 1;
            cfg.retrieval.rollout_policy.target_scopes_json = args[i];
        } else if (std.mem.eql(u8, arg, "--retrieval-rollout-required-capabilities") and i + 1 < args.len) {
            i += 1;
            cfg.retrieval.rollout_policy.required_capabilities_json = args[i];
        } else if (std.mem.eql(u8, arg, "--retrieval-rollout-blocked-capabilities") and i + 1 < args.len) {
            i += 1;
            cfg.retrieval.rollout_policy.blocked_capabilities_json = args[i];
        } else if (std.mem.eql(u8, arg, "--agent-memory-backend") and i + 1 < args.len) {
            i += 1;
            cfg.stores.agent_memory_backend = try agent_memory_config.BackendKind.parse(args[i]);
        } else if ((std.mem.eql(u8, arg, "--agent-memory-markdown-workspace") or std.mem.eql(u8, arg, "--markdown-workspace")) and i + 1 < args.len) {
            i += 1;
            cfg.stores.markdown_agent_memory.workspace_dir = args[i];
            cfg.stores.agent_memory_backend = .markdown;
        } else if (std.mem.eql(u8, arg, "--agent-memory-markdown-max-file-bytes") and i + 1 < args.len) {
            i += 1;
            cfg.stores.markdown_agent_memory.max_file_bytes = try parseMarkdownFileBytes(args[i], cfg.stores.markdown_agent_memory.max_file_bytes);
        } else if (std.mem.eql(u8, arg, "--agent-memory-api-url") and i + 1 < args.len) {
            i += 1;
            cfg.stores.api_agent_memory.base_url = args[i];
            cfg.stores.agent_memory_backend = .api;
        } else if (std.mem.eql(u8, arg, "--agent-memory-api-token") and i + 1 < args.len) {
            i += 1;
            cfg.stores.api_agent_memory.token = args[i];
        } else if (std.mem.eql(u8, arg, "--agent-memory-api-storage") and i + 1 < args.len) {
            i += 1;
            cfg.stores.api_agent_memory.remote_storage = args[i];
        } else if (std.mem.eql(u8, arg, "--agent-memory-api-scopes") and i + 1 < args.len) {
            i += 1;
            cfg.stores.api_agent_memory.actor_scopes_json = args[i];
        } else if (std.mem.eql(u8, arg, "--agent-memory-api-capabilities") and i + 1 < args.len) {
            i += 1;
            cfg.stores.api_agent_memory.actor_capabilities_json = args[i];
        } else if (std.mem.eql(u8, arg, "--agent-memory-api-timeout-secs") and i + 1 < args.len) {
            i += 1;
            cfg.stores.api_agent_memory.timeout_secs = try parseRuntimeTimeoutSecs(args[i], cfg.stores.api_agent_memory.timeout_secs);
        } else if (std.mem.eql(u8, arg, "--agent-memory-api-max-response-bytes") and i + 1 < args.len) {
            i += 1;
            cfg.stores.api_agent_memory.max_response_bytes = agent_memory_config.boundedRemoteResponseBytes(try std.fmt.parseInt(i64, args[i], 10), cfg.stores.api_agent_memory.max_response_bytes);
        } else if (std.mem.eql(u8, arg, "--agent-memory-api-allow-insecure-http")) {
            cfg.stores.api_agent_memory.allow_insecure_http = true;
        } else if (std.mem.eql(u8, arg, "--agent-memory-api-profile") and i + 1 < args.len) {
            i += 1;
            applyRuntimeAgentMemoryApiProfile(&cfg, try agent_memory_config.ApiProfile.parse(args[i]));
        } else if ((std.mem.eql(u8, arg, "--agent-memory-supermemory-url") or std.mem.eql(u8, arg, "--supermemory-url")) and i + 1 < args.len) {
            i += 1;
            applyRuntimeAgentMemoryApiProfile(&cfg, .supermemory);
            cfg.stores.api_agent_memory.base_url = args[i];
        } else if ((std.mem.eql(u8, arg, "--agent-memory-supermemory-api-key") or std.mem.eql(u8, arg, "--supermemory-api-key")) and i + 1 < args.len) {
            i += 1;
            applyRuntimeAgentMemoryApiProfile(&cfg, .supermemory);
            cfg.stores.api_agent_memory.token = args[i];
        } else if ((std.mem.eql(u8, arg, "--agent-memory-openviking-url") or std.mem.eql(u8, arg, "--openviking-url")) and i + 1 < args.len) {
            i += 1;
            applyRuntimeAgentMemoryApiProfile(&cfg, .openviking);
            cfg.stores.api_agent_memory.base_url = args[i];
        } else if ((std.mem.eql(u8, arg, "--agent-memory-openviking-api-key") or std.mem.eql(u8, arg, "--openviking-api-key")) and i + 1 < args.len) {
            i += 1;
            applyRuntimeAgentMemoryApiProfile(&cfg, .openviking);
            cfg.stores.api_agent_memory.token = args[i];
        } else if ((std.mem.eql(u8, arg, "--agent-memory-honcho-url") or std.mem.eql(u8, arg, "--honcho-url")) and i + 1 < args.len) {
            i += 1;
            applyRuntimeAgentMemoryApiProfile(&cfg, .honcho);
            cfg.stores.api_agent_memory.base_url = args[i];
        } else if ((std.mem.eql(u8, arg, "--agent-memory-honcho-api-key") or std.mem.eql(u8, arg, "--honcho-api-key")) and i + 1 < args.len) {
            i += 1;
            applyRuntimeAgentMemoryApiProfile(&cfg, .honcho);
            cfg.stores.api_agent_memory.token = args[i];
        } else if ((std.mem.eql(u8, arg, "--agent-memory-honcho-workspace-id") or std.mem.eql(u8, arg, "--honcho-workspace-id")) and i + 1 < args.len) {
            i += 1;
            applyRuntimeAgentMemoryApiProfile(&cfg, .honcho);
            cfg.stores.api_agent_memory.workspace_id = args[i];
        } else if ((std.mem.eql(u8, arg, "--agent-memory-mem0-url") or std.mem.eql(u8, arg, "--mem0-url")) and i + 1 < args.len) {
            i += 1;
            applyRuntimeAgentMemoryApiProfile(&cfg, .mem0);
            cfg.stores.api_agent_memory.base_url = args[i];
        } else if ((std.mem.eql(u8, arg, "--agent-memory-mem0-api-key") or std.mem.eql(u8, arg, "--mem0-api-key")) and i + 1 < args.len) {
            i += 1;
            applyRuntimeAgentMemoryApiProfile(&cfg, .mem0);
            cfg.stores.api_agent_memory.token = args[i];
        } else if ((std.mem.eql(u8, arg, "--agent-memory-hindsight-url") or std.mem.eql(u8, arg, "--hindsight-url")) and i + 1 < args.len) {
            i += 1;
            applyRuntimeAgentMemoryApiProfile(&cfg, .hindsight);
            cfg.stores.api_agent_memory.base_url = args[i];
        } else if ((std.mem.eql(u8, arg, "--agent-memory-hindsight-api-key") or std.mem.eql(u8, arg, "--hindsight-api-key")) and i + 1 < args.len) {
            i += 1;
            applyRuntimeAgentMemoryApiProfile(&cfg, .hindsight);
            cfg.stores.api_agent_memory.token = args[i];
        } else if ((std.mem.eql(u8, arg, "--agent-memory-hindsight-bank-id") or std.mem.eql(u8, arg, "--hindsight-bank-id")) and i + 1 < args.len) {
            i += 1;
            applyRuntimeAgentMemoryApiProfile(&cfg, .hindsight);
            cfg.stores.api_agent_memory.workspace_id = args[i];
        } else if ((std.mem.eql(u8, arg, "--agent-memory-retaindb-url") or std.mem.eql(u8, arg, "--retaindb-url")) and i + 1 < args.len) {
            i += 1;
            applyRuntimeAgentMemoryApiProfile(&cfg, .retaindb);
            cfg.stores.api_agent_memory.base_url = args[i];
        } else if ((std.mem.eql(u8, arg, "--agent-memory-retaindb-api-key") or std.mem.eql(u8, arg, "--retaindb-api-key")) and i + 1 < args.len) {
            i += 1;
            applyRuntimeAgentMemoryApiProfile(&cfg, .retaindb);
            cfg.stores.api_agent_memory.token = args[i];
        } else if ((std.mem.eql(u8, arg, "--agent-memory-retaindb-project") or std.mem.eql(u8, arg, "--retaindb-project")) and i + 1 < args.len) {
            i += 1;
            applyRuntimeAgentMemoryApiProfile(&cfg, .retaindb);
            cfg.stores.api_agent_memory.workspace_id = args[i];
        } else if ((std.mem.eql(u8, arg, "--agent-memory-byterover-command") or std.mem.eql(u8, arg, "--byterover-command")) and i + 1 < args.len) {
            i += 1;
            applyRuntimeAgentMemoryApiProfile(&cfg, .byterover);
            cfg.stores.api_agent_memory.byterover_command = args[i];
        } else if ((std.mem.eql(u8, arg, "--agent-memory-byterover-project-dir") or std.mem.eql(u8, arg, "--byterover-project-dir")) and i + 1 < args.len) {
            i += 1;
            applyRuntimeAgentMemoryApiProfile(&cfg, .byterover);
            cfg.stores.api_agent_memory.byterover_project_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--agent-memory-byterover-use-swarm") or std.mem.eql(u8, arg, "--byterover-use-swarm")) {
            applyRuntimeAgentMemoryApiProfile(&cfg, .byterover);
            cfg.stores.api_agent_memory.byterover_use_swarm = true;
        } else if ((std.mem.eql(u8, arg, "--agent-memory-zep-url") or std.mem.eql(u8, arg, "--zep-url")) and i + 1 < args.len) {
            i += 1;
            applyRuntimeAgentMemoryApiProfile(&cfg, .zep);
            cfg.stores.api_agent_memory.base_url = args[i];
        } else if ((std.mem.eql(u8, arg, "--agent-memory-zep-api-key") or std.mem.eql(u8, arg, "--zep-api-key")) and i + 1 < args.len) {
            i += 1;
            applyRuntimeAgentMemoryApiProfile(&cfg, .zep);
            cfg.stores.api_agent_memory.token = args[i];
        } else if ((std.mem.eql(u8, arg, "--agent-memory-zep-graph-id") or std.mem.eql(u8, arg, "--zep-graph-id")) and i + 1 < args.len) {
            i += 1;
            applyRuntimeAgentMemoryApiProfile(&cfg, .zep);
            cfg.stores.api_agent_memory.workspace_id = args[i];
        } else if ((std.mem.eql(u8, arg, "--agent-memory-falkordb-url") or std.mem.eql(u8, arg, "--falkordb-url")) and i + 1 < args.len) {
            i += 1;
            applyRuntimeAgentMemoryApiProfile(&cfg, .falkordb);
            cfg.stores.api_agent_memory.base_url = args[i];
        } else if ((std.mem.eql(u8, arg, "--agent-memory-falkordb-api-key") or std.mem.eql(u8, arg, "--falkordb-api-key")) and i + 1 < args.len) {
            i += 1;
            applyRuntimeAgentMemoryApiProfile(&cfg, .falkordb);
            cfg.stores.api_agent_memory.token = args[i];
        } else if ((std.mem.eql(u8, arg, "--agent-memory-falkordb-graph") or std.mem.eql(u8, arg, "--falkordb-graph")) and i + 1 < args.len) {
            i += 1;
            applyRuntimeAgentMemoryApiProfile(&cfg, .falkordb);
            cfg.stores.api_agent_memory.workspace_id = args[i];
        } else if ((std.mem.eql(u8, arg, "--agent-memory-holographic-db-path") or std.mem.eql(u8, arg, "--holographic-db-path")) and i + 1 < args.len) {
            i += 1;
            cfg.stores.agent_memory_backend = .holographic;
            cfg.stores.holographic_agent_memory.db_path = args[i];
        } else if (std.mem.eql(u8, arg, "--holographic-default-trust") and i + 1 < args.len) {
            i += 1;
            cfg.stores.holographic_agent_memory.default_trust = try std.fmt.parseFloat(f64, args[i]);
        } else if (std.mem.eql(u8, arg, "--holographic-trust-reward") and i + 1 < args.len) {
            i += 1;
            cfg.stores.holographic_agent_memory.trust_reward = try std.fmt.parseFloat(f64, args[i]);
        } else if (std.mem.eql(u8, arg, "--holographic-trust-penalty") and i + 1 < args.len) {
            i += 1;
            cfg.stores.holographic_agent_memory.trust_penalty = try std.fmt.parseFloat(f64, args[i]);
        } else if (std.mem.eql(u8, arg, "--memory-lru-max-entries") and i + 1 < args.len) {
            i += 1;
            cfg.stores.memory.max_entries = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--memory-lru-max-messages") and i + 1 < args.len) {
            i += 1;
            cfg.stores.memory.max_messages = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--memory-lru-max-usage-entries") and i + 1 < args.len) {
            i += 1;
            cfg.stores.memory.max_usage_entries = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--memory-lru-max-bytes") and i + 1 < args.len) {
            i += 1;
            cfg.stores.memory.max_bytes = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--memory-lru-ttl-seconds") and i + 1 < args.len) {
            i += 1;
            cfg.stores.memory.ttl_seconds = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--redis-url") and i + 1 < args.len) {
            i += 1;
            cfg.stores.redis = try redis_config.parseUrl(allocator, args[i]);
            cfg.stores.agent_memory_backend = .redis;
        } else if (std.mem.eql(u8, arg, "--redis-key-prefix") and i + 1 < args.len) {
            i += 1;
            cfg.stores.redis.key_prefix = args[i];
        } else if (std.mem.eql(u8, arg, "--redis-ttl-seconds") and i + 1 < args.len) {
            i += 1;
            cfg.stores.redis.ttl_seconds = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--agent-memory-clickhouse-url") and i + 1 < args.len) {
            i += 1;
            cfg.stores.clickhouse_agent_memory.base_url = args[i];
            cfg.stores.agent_memory_backend = .clickhouse;
        } else if (std.mem.eql(u8, arg, "--agent-memory-clickhouse-api-key") and i + 1 < args.len) {
            i += 1;
            cfg.stores.clickhouse_agent_memory.api_key = args[i];
        } else if (std.mem.eql(u8, arg, "--agent-memory-clickhouse-table") and i + 1 < args.len) {
            i += 1;
            cfg.stores.clickhouse_agent_memory.table = args[i];
            cfg.stores.agent_memory_backend = .clickhouse;
        } else if (std.mem.eql(u8, arg, "--agent-memory-clickhouse-timeout-secs") and i + 1 < args.len) {
            i += 1;
            cfg.stores.clickhouse_agent_memory.timeout_secs = try parseRuntimeTimeoutSecs(args[i], cfg.stores.clickhouse_agent_memory.timeout_secs);
        } else if (std.mem.eql(u8, arg, "--agent-memory-clickhouse-max-response-bytes") and i + 1 < args.len) {
            i += 1;
            cfg.stores.clickhouse_agent_memory.max_response_bytes = agent_memory_config.boundedRemoteResponseBytes(try std.fmt.parseInt(i64, args[i], 10), cfg.stores.clickhouse_agent_memory.max_response_bytes);
        } else if (std.mem.eql(u8, arg, "--agent-memory-clickhouse-allow-insecure-http")) {
            cfg.stores.clickhouse_agent_memory.allow_insecure_http = true;
        } else if (std.mem.eql(u8, arg, "--agent-memory-store") and i + 1 < args.len) {
            i += 1;
            const named = try parseAgentMemoryStoreSpec(allocator, args[i]);
            try appendAgentMemoryStoreConfig(allocator, &cfg, named);
        } else if (std.mem.eql(u8, arg, "--vector-store") and i + 1 < args.len) {
            i += 1;
            const named = try parseVectorStoreSpec(allocator, args[i]);
            try appendVectorStoreConfig(allocator, &cfg, named);
        } else if (std.mem.eql(u8, arg, "--chunk-max-chars") and i + 1 < args.len) {
            i += 1;
            cfg.retrieval.chunker.max_chars = try parsePositiveUsize(args[i]);
        } else if (std.mem.eql(u8, arg, "--chunk-overlap-chars") and i + 1 < args.len) {
            i += 1;
            cfg.retrieval.chunker.overlap_chars = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--chunk-max-tokens") and i + 1 < args.len) {
            i += 1;
            cfg.retrieval.chunker.max_tokens = try parsePositiveUsize(args[i]);
        } else if (std.mem.eql(u8, arg, "--chunk-strategy") and i + 1 < args.len) {
            i += 1;
            cfg.retrieval.chunker.strategy = try vector_mod.ChunkStrategy.parse(args[i]);
        } else if (std.mem.eql(u8, arg, "--vector-backend") and i + 1 < args.len) {
            i += 1;
            cfg.stores.vector_backend.backend = try vector_runtime.BackendKind.parse(args[i]);
        } else if (std.mem.eql(u8, arg, "--vector-base-url") and i + 1 < args.len) {
            i += 1;
            cfg.stores.vector_backend.base_url = args[i];
        } else if (std.mem.eql(u8, arg, "--vector-api-key") and i + 1 < args.len) {
            i += 1;
            cfg.stores.vector_backend.api_key = args[i];
        } else if (std.mem.eql(u8, arg, "--vector-api-key-header") and i + 1 < args.len) {
            i += 1;
            cfg.stores.vector_backend.api_key_header = args[i];
        } else if (std.mem.eql(u8, arg, "--vector-collection") and i + 1 < args.len) {
            i += 1;
            cfg.stores.vector_backend.collection = args[i];
        } else if (std.mem.eql(u8, arg, "--vector-postgres-url") and i + 1 < args.len) {
            i += 1;
            cfg.stores.vector_backend.backend = .pgvector;
            cfg.stores.vector_backend.postgres_url = args[i];
        } else if (std.mem.eql(u8, arg, "--vector-timeout-secs") and i + 1 < args.len) {
            i += 1;
            cfg.stores.vector_backend.timeout_secs = try parseRuntimeTimeoutSecs(args[i], cfg.stores.vector_backend.timeout_secs);
        } else if (std.mem.eql(u8, arg, "--vector-sqlite-ann-candidate-multiplier") and i + 1 < args.len) {
            i += 1;
            cfg.stores.vector_backend.sqlite_ann_candidate_multiplier = vector_runtime.normalizeSqliteAnnCandidateMultiplier(try std.fmt.parseInt(u32, args[i], 10));
        } else if (std.mem.eql(u8, arg, "--vector-sqlite-ann-min-candidates") and i + 1 < args.len) {
            i += 1;
            cfg.stores.vector_backend.sqlite_ann_min_candidates = vector_runtime.normalizeSqliteAnnMinCandidates(try std.fmt.parseInt(u32, args[i], 10));
        } else if (std.mem.eql(u8, arg, "--vector-allow-insecure-http")) {
            cfg.stores.vector_backend.allow_insecure_http = true;
        } else if (std.mem.eql(u8, arg, "--vector-disable-circuit-breaker")) {
            cfg.stores.vector_backend.circuit_breaker_enabled = false;
        } else if (std.mem.eql(u8, arg, "--vector-circuit-breaker-threshold") and i + 1 < args.len) {
            i += 1;
            cfg.stores.vector_backend.circuit_breaker_threshold = try parseCircuitFailureThreshold(args[i], cfg.stores.vector_backend.circuit_breaker_threshold);
        } else if (std.mem.eql(u8, arg, "--vector-circuit-breaker-cooldown-ms") and i + 1 < args.len) {
            i += 1;
            cfg.stores.vector_backend.circuit_breaker_cooldown_ms = try parseCircuitCooldownMsU64(args[i], cfg.stores.vector_backend.circuit_breaker_cooldown_ms);
        } else if (std.mem.eql(u8, arg, "--lancedb-uri") and i + 1 < args.len) {
            i += 1;
            cfg.stores.vector_backend.backend = .lancedb;
            cfg.stores.vector_backend.lancedb_uri = args[i];
        } else if (std.mem.eql(u8, arg, "--lancedb-command") and i + 1 < args.len) {
            i += 1;
            cfg.stores.vector_backend.backend = .lancedb;
            cfg.stores.vector_backend.lancedb_command = args[i];
        } else if (std.mem.eql(u8, arg, "--lancedb-table") and i + 1 < args.len) {
            i += 1;
            cfg.stores.vector_backend.collection = args[i];
        } else if (std.mem.eql(u8, arg, "--lancedb-url") and i + 1 < args.len) {
            i += 1;
            cfg.stores.vector_backend.backend = .lancedb_http;
            cfg.stores.vector_backend.base_url = args[i];
        } else if (std.mem.eql(u8, arg, "--pgvector-url") and i + 1 < args.len) {
            i += 1;
            cfg.stores.vector_backend.backend = .pgvector;
            cfg.stores.vector_backend.postgres_url = args[i];
        } else if (std.mem.eql(u8, arg, "--pgvector-table") and i + 1 < args.len) {
            i += 1;
            cfg.stores.vector_backend.backend = .pgvector;
            cfg.stores.vector_backend.collection = args[i];
        } else if (std.mem.eql(u8, arg, "--weaviate-url") and i + 1 < args.len) {
            i += 1;
            cfg.stores.vector_backend.backend = .weaviate;
            cfg.stores.vector_backend.base_url = args[i];
        } else if (std.mem.eql(u8, arg, "--weaviate-api-key") and i + 1 < args.len) {
            i += 1;
            cfg.stores.vector_backend.api_key = args[i];
        } else if (std.mem.eql(u8, arg, "--weaviate-collection") and i + 1 < args.len) {
            i += 1;
            cfg.stores.vector_backend.backend = .weaviate;
            cfg.stores.vector_backend.collection = args[i];
        } else if (std.mem.eql(u8, arg, "--chroma-url") and i + 1 < args.len) {
            i += 1;
            cfg.stores.vector_backend.backend = .chroma;
            cfg.stores.vector_backend.base_url = args[i];
        } else if (std.mem.eql(u8, arg, "--chroma-token") and i + 1 < args.len) {
            i += 1;
            cfg.stores.vector_backend.api_key = args[i];
        } else if (std.mem.eql(u8, arg, "--chroma-tenant") and i + 1 < args.len) {
            i += 1;
            cfg.stores.vector_backend.backend = .chroma;
            cfg.stores.vector_backend.chroma_tenant = args[i];
        } else if (std.mem.eql(u8, arg, "--chroma-database") and i + 1 < args.len) {
            i += 1;
            cfg.stores.vector_backend.backend = .chroma;
            cfg.stores.vector_backend.chroma_database = args[i];
        } else if ((std.mem.eql(u8, arg, "--chroma-collection") or std.mem.eql(u8, arg, "--chroma-collection-id")) and i + 1 < args.len) {
            i += 1;
            cfg.stores.vector_backend.backend = .chroma;
            cfg.stores.vector_backend.collection = args[i];
        } else if (std.mem.eql(u8, arg, "--opensearch-url") and i + 1 < args.len) {
            i += 1;
            cfg.stores.vector_backend.backend = .opensearch;
            cfg.stores.vector_backend.base_url = args[i];
        } else if (std.mem.eql(u8, arg, "--opensearch-api-key") and i + 1 < args.len) {
            i += 1;
            cfg.stores.vector_backend.api_key = args[i];
        } else if (std.mem.eql(u8, arg, "--opensearch-index") and i + 1 < args.len) {
            i += 1;
            cfg.stores.vector_backend.backend = .opensearch;
            cfg.stores.vector_backend.collection = args[i];
        } else if (std.mem.eql(u8, arg, "--graph-backend") and i + 1 < args.len) {
            i += 1;
            cfg.stores.graph_projection.backend = try graph_runtime.BackendKind.parse(args[i]);
        } else if (std.mem.eql(u8, arg, "--graph-base-url") and i + 1 < args.len) {
            i += 1;
            cfg.stores.graph_projection.base_url = args[i];
        } else if (std.mem.eql(u8, arg, "--graph-api-key") and i + 1 < args.len) {
            i += 1;
            cfg.stores.graph_projection.api_key = args[i];
        } else if (std.mem.eql(u8, arg, "--graph-database") and i + 1 < args.len) {
            i += 1;
            cfg.stores.graph_projection.database = args[i];
        } else if (std.mem.eql(u8, arg, "--graph-name") and i + 1 < args.len) {
            i += 1;
            cfg.stores.graph_projection.graph = args[i];
        } else if (std.mem.eql(u8, arg, "--graph-timeout-secs") and i + 1 < args.len) {
            i += 1;
            cfg.stores.graph_projection.timeout_secs = try parseRuntimeTimeoutSecs(args[i], cfg.stores.graph_projection.timeout_secs);
        } else if (std.mem.eql(u8, arg, "--graph-project-scopes") and i + 1 < args.len) {
            i += 1;
            cfg.stores.graph_projection.project_scopes_json = args[i];
        } else if (std.mem.eql(u8, arg, "--graph-allow-insecure-http")) {
            cfg.stores.graph_projection.allow_insecure_http = true;
        } else if (std.mem.eql(u8, arg, "--neo4j-url") and i + 1 < args.len) {
            i += 1;
            cfg.stores.graph_projection.backend = .neo4j;
            cfg.stores.graph_projection.base_url = args[i];
        } else if (std.mem.eql(u8, arg, "--neo4j-api-key") and i + 1 < args.len) {
            i += 1;
            cfg.stores.graph_projection.api_key = args[i];
        } else if (std.mem.eql(u8, arg, "--neo4j-database") and i + 1 < args.len) {
            i += 1;
            cfg.stores.graph_projection.backend = .neo4j;
            cfg.stores.graph_projection.database = args[i];
        } else if (std.mem.eql(u8, arg, "--graph-falkordb-url") and i + 1 < args.len) {
            i += 1;
            cfg.stores.graph_projection.backend = .falkordb;
            cfg.stores.graph_projection.base_url = args[i];
        } else if (std.mem.eql(u8, arg, "--graph-falkordb-api-key") and i + 1 < args.len) {
            i += 1;
            cfg.stores.graph_projection.api_key = args[i];
        } else if (std.mem.eql(u8, arg, "--graph-falkordb-name") and i + 1 < args.len) {
            i += 1;
            cfg.stores.graph_projection.backend = .falkordb;
            cfg.stores.graph_projection.graph = args[i];
        } else if (std.mem.eql(u8, arg, "--analytics-backend") and i + 1 < args.len) {
            i += 1;
            cfg.stores.analytics_backend.backend = try analytics_runtime.BackendKind.parse(args[i]);
        } else if (std.mem.eql(u8, arg, "--analytics-base-url") and i + 1 < args.len) {
            i += 1;
            cfg.stores.analytics_backend.base_url = args[i];
        } else if (std.mem.eql(u8, arg, "--analytics-api-key") and i + 1 < args.len) {
            i += 1;
            cfg.stores.analytics_backend.api_key = args[i];
        } else if (std.mem.eql(u8, arg, "--analytics-table") and i + 1 < args.len) {
            i += 1;
            cfg.stores.analytics_backend.table = args[i];
        } else if (std.mem.eql(u8, arg, "--analytics-timeout-secs") and i + 1 < args.len) {
            i += 1;
            cfg.stores.analytics_backend.timeout_secs = try parseRuntimeTimeoutSecs(args[i], cfg.stores.analytics_backend.timeout_secs);
        } else if (std.mem.eql(u8, arg, "--analytics-allow-insecure-http")) {
            cfg.stores.analytics_backend.allow_insecure_http = true;
        } else if (std.mem.eql(u8, arg, "--lucid-enabled")) {
            cfg.stores.lucid_projection.enabled = true;
        } else if (std.mem.eql(u8, arg, "--lucid-command") and i + 1 < args.len) {
            i += 1;
            cfg.stores.lucid_projection.command = args[i];
            cfg.stores.lucid_projection.enabled = true;
        } else if (std.mem.eql(u8, arg, "--lucid-workspace") and i + 1 < args.len) {
            i += 1;
            cfg.stores.lucid_projection.workspace_dir = args[i];
            cfg.stores.lucid_projection.enabled = true;
        } else if (std.mem.eql(u8, arg, "--lucid-token-budget") and i + 1 < args.len) {
            i += 1;
            cfg.stores.lucid_projection.token_budget = try parseLucidTokenBudget(args[i], cfg.stores.lucid_projection.token_budget);
        } else if (std.mem.eql(u8, arg, "--lucid-local-hit-threshold") and i + 1 < args.len) {
            i += 1;
            cfg.stores.lucid_projection.local_hit_threshold = try parseLucidLocalHitThreshold(args[i], cfg.stores.lucid_projection.local_hit_threshold);
        } else if (std.mem.eql(u8, arg, "--lucid-project-scopes") and i + 1 < args.len) {
            i += 1;
            cfg.stores.lucid_projection.project_scopes_json = args[i];
        } else if (std.mem.eql(u8, arg, "--lucid-result-scope") and i + 1 < args.len) {
            i += 1;
            cfg.stores.lucid_projection.result_scope = args[i];
        } else if (std.mem.eql(u8, arg, "--lucid-permissions") and i + 1 < args.len) {
            i += 1;
            cfg.stores.lucid_projection.permissions_json = args[i];
        } else if (cliOptionTakesValue(arg)) {
            return error.MissingArgumentValue;
        } else {
            return error.UnknownArgument;
        }
    }
    if (state.embedding_fallbacks_raw) |raw| {
        cfg.provider.embedding.fallbacks = try providers.parseEmbeddingFallbacks(allocator, raw, embeddingConfigFromRuntime(cfg));
    }
    if (state.embedding_routes_raw) |raw| {
        cfg.provider.embedding.routes = try providers.parseEmbeddingRoutes(allocator, raw, embeddingConfigFromRuntime(cfg));
    }
    cfg.retrieval.chunker = try cfg.retrieval.chunker.normalized();
    return cfg;
}

fn validateCompiledEngineProfile(allocator: std.mem.Allocator, cfg: RuntimeConfig) !void {
    try validateAuthConfig(allocator, cfg.auth);
    try cfg.actor.validateUsable();
    try cfg.worker.validateUsable();
    try validateFilesystemConfig(cfg.filesystem);
    try validateNoAuthBindSafety(cfg);
    switch (cfg.stores.records_backend) {
        .sqlite => if (!build_options.enable_engine_sqlite) return error.EngineNotCompiled,
        .postgres => if (!build_options.enable_engine_postgres) return error.EngineNotCompiled,
    }
    try validateRuntimeAgentMemoryBackendConfigured(cfg);
    try validateCompiledAgentMemoryBackend(cfg.stores.agent_memory_backend);
    for (cfg.stores.agent_memory_stores) |named| {
        try named.config.validateUsable();
        try validateCompiledAgentMemoryBackend(named.config.backend);
    }
    try validateVectorBackendConfigured(cfg.stores.vector_backend);
    try validateCompiledVectorBackend(cfg.stores.vector_backend.backend);
    for (cfg.stores.vector_stores) |named| {
        try validateVectorBackendConfigured(named.config);
        try validateCompiledVectorBackend(named.config.backend);
    }
    try validateAnalyticsBackendConfigured(cfg.stores.analytics_backend);
    switch (cfg.stores.analytics_backend.backend) {
        .none => {},
        .clickhouse => if (!build_options.enable_engine_clickhouse) return error.EngineNotCompiled,
    }
    try validateGraphProjectionConfigured(cfg.stores.graph_projection);
    switch (cfg.stores.graph_projection.backend) {
        .none => {},
        .neo4j => if (!build_options.enable_engine_neo4j) return error.EngineNotCompiled,
        .falkordb => if (!build_options.enable_engine_falkordb) return error.EngineNotCompiled,
    }
    try validateLucidProjectionConfigured(cfg.stores.lucid_projection);
    if (cfg.stores.lucid_projection.isEnabled() and !build_options.enable_engine_lucid) return error.EngineNotCompiled;
    try validateProviderRuntimeConfigured(cfg);
    try validateRolloutPolicyConfigured(cfg.retrieval.rollout_policy);
}

fn validateNoAuthBindSafety(cfg: RuntimeConfig) !void {
    if (optionalNonBlank(cfg.auth.required_token) or optionalNonBlank(cfg.auth.token_principals_json)) return;
    if (cfg.auth.allow_no_auth_non_loopback) return;
    if (net_security.isLocalHost(cfg.host)) return;
    return error.InsecureNoAuthBind;
}

fn validateAuthConfig(allocator: std.mem.Allocator, config: runtime_config.AuthConfig) !void {
    if (config.required_token) |token| {
        if (std.mem.trim(u8, token, " \t\r\n").len == 0) return error.InvalidAuthToken;
    }
    if (config.token_principals_json) |principals| {
        if (std.mem.trim(u8, principals, " \t\r\n").len == 0) return error.InvalidPrincipalRegistry;
        try auth.validatePrincipalRegistry(allocator, principals);
    }
}

fn validateFilesystemConfig(config: runtime_config.FilesystemConfig) !void {
    if (std.mem.trim(u8, config.root, " \t\r\n").len == 0) return error.InvalidFilesystemRoot;
}

fn optionalNonBlank(value: ?[]const u8) bool {
    return if (value) |text| std.mem.trim(u8, text, " \t\r\n").len > 0 else false;
}

fn validateRuntimeAgentMemoryBackendConfigured(cfg: RuntimeConfig) !void {
    return (agent_memory_config.Config{
        .backend = cfg.stores.agent_memory_backend,
        .memory = cfg.stores.memory,
        .markdown = cfg.stores.markdown_agent_memory,
        .redis = cfg.stores.redis,
        .clickhouse = cfg.stores.clickhouse_agent_memory,
        .api = cfg.stores.api_agent_memory,
        .holographic = cfg.stores.holographic_agent_memory,
    }).validateUsable();
}

fn validateVectorBackendConfigured(config: vector_runtime.Config) !void {
    try config.validateUsable();
}

fn validateAnalyticsBackendConfigured(config: analytics_runtime.Config) !void {
    try config.validateUsable();
}

fn validateGraphProjectionConfigured(config: graph_runtime.Config) !void {
    try config.validateUsable();
}

fn validateLucidProjectionConfigured(config: lucid_runtime.Config) !void {
    try config.validateUsable();
}

fn validateProviderRuntimeConfigured(cfg: RuntimeConfig) !void {
    if (!circuit_breaker.validFailureThreshold(cfg.provider.circuit_failure_threshold)) return error.InvalidProviderCircuitConfig;
    if (!circuit_breaker.validCooldownMs(cfg.provider.circuit_cooldown_ms)) return error.InvalidProviderCircuitConfig;
    try embeddingConfigFromRuntime(cfg).validateUsable();
    try completionConfigFromRuntime(cfg).validateUsable();
}

fn validateRolloutPolicyConfigured(policy: lifecycle.RolloutPolicy) !void {
    try policy.validateUsable();
}

fn validateCompiledVectorBackend(backend: vector_runtime.BackendKind) !void {
    switch (backend) {
        .local => {},
        .pgvector => if (!build_options.enable_engine_pgvector) return error.EngineNotCompiled,
        .qdrant => if (!build_options.enable_engine_qdrant) return error.EngineNotCompiled,
        .lancedb => if (!build_options.enable_engine_lancedb) return error.EngineNotCompiled,
        .lancedb_http => if (!build_options.enable_engine_lancedb_http) return error.EngineNotCompiled,
        .weaviate => if (!build_options.enable_engine_weaviate) return error.EngineNotCompiled,
        .chroma => if (!build_options.enable_engine_chroma) return error.EngineNotCompiled,
        .opensearch => if (!build_options.enable_engine_opensearch) return error.EngineNotCompiled,
    }
}

fn validateCompiledAgentMemoryBackend(backend: agent_memory_config.BackendKind) !void {
    switch (backend) {
        .none => if (!build_options.enable_engine_none) return error.EngineNotCompiled,
        .native => {},
        .markdown => if (!build_options.enable_engine_markdown) return error.EngineNotCompiled,
        .memory_lru => if (!build_options.enable_engine_memory_lru) return error.EngineNotCompiled,
        .redis => if (!build_options.enable_engine_redis) return error.EngineNotCompiled,
        .clickhouse => if (!build_options.enable_engine_clickhouse) return error.EngineNotCompiled,
        .api => if (!build_options.enable_engine_api) return error.EngineNotCompiled,
        .supermemory => if (!build_options.enable_engine_supermemory) return error.EngineNotCompiled,
        .openviking => if (!build_options.enable_engine_openviking) return error.EngineNotCompiled,
        .honcho => if (!build_options.enable_engine_honcho) return error.EngineNotCompiled,
        .mem0 => if (!build_options.enable_engine_mem0) return error.EngineNotCompiled,
        .hindsight => if (!build_options.enable_engine_hindsight) return error.EngineNotCompiled,
        .retaindb => if (!build_options.enable_engine_retaindb) return error.EngineNotCompiled,
        .byterover => if (!build_options.enable_engine_byterover) return error.EngineNotCompiled,
        .holographic => if (!build_options.enable_engine_holographic) return error.EngineNotCompiled,
        .zep => if (!build_options.enable_engine_zep) return error.EngineNotCompiled,
        .falkordb => if (!build_options.enable_engine_falkordb) return error.EngineNotCompiled,
    }
}

fn embeddingConfigFromRuntime(cfg: RuntimeConfig) providers.EmbeddingConfig {
    return cfg.provider.embeddingConfig();
}

fn completionConfigFromRuntime(cfg: RuntimeConfig) providers.CompletionConfig {
    return cfg.provider.completionConfig();
}

fn providerConfigFromRuntime(cfg: RuntimeConfig) runtime_config.ProviderConfig {
    var out = cfg.provider;
    out.embedding = embeddingConfigFromRuntime(cfg);
    out.completion = completionConfigFromRuntime(cfg);
    return out;
}

fn providerMaxResponseBytes(cfg: RuntimeConfig) usize {
    return cfg.provider.default_max_response_bytes;
}

fn embeddingMaxResponseBytes(cfg: RuntimeConfig) usize {
    return cfg.provider.embedding_max_response_bytes orelse cfg.provider.default_max_response_bytes;
}

fn llmMaxResponseBytes(cfg: RuntimeConfig) usize {
    return cfg.provider.completion_max_response_bytes orelse cfg.provider.default_max_response_bytes;
}

fn agentMemoryBackendForApiProfile(profile: agent_memory_config.ApiProfile) ?agent_memory_config.BackendKind {
    return switch (profile) {
        .nullpantry => null,
        .supermemory => .supermemory,
        .openviking => .openviking,
        .honcho => .honcho,
        .mem0 => .mem0,
        .hindsight => .hindsight,
        .retaindb => .retaindb,
        .byterover => .byterover,
        .zep => .zep,
        .falkordb => .falkordb,
    };
}

fn applyRuntimeAgentMemoryApiProfile(cfg: *RuntimeConfig, profile: agent_memory_config.ApiProfile) void {
    cfg.stores.api_agent_memory.profile = profile;
    if (agentMemoryBackendForApiProfile(profile)) |backend| cfg.stores.agent_memory_backend = backend;
}

fn applyNamedAgentMemoryApiProfile(config: *agent_memory_config.Config, profile: agent_memory_config.ApiProfile) void {
    config.api.profile = profile;
    if (agentMemoryBackendForApiProfile(profile)) |backend| config.backend = backend;
}

fn replaceOwnedOptionalString(allocator: std.mem.Allocator, slot: *?[]const u8, value: []const u8) !void {
    const owned = try allocator.dupe(u8, value);
    if (slot.*) |previous| allocator.free(previous);
    slot.* = owned;
}

fn replaceOwnedStringIfOwned(allocator: std.mem.Allocator, slot: *[]const u8, default_value: []const u8, value: []const u8) !void {
    const owned = try allocator.dupe(u8, value);
    if (slot.*.ptr != default_value.ptr) allocator.free(slot.*);
    slot.* = owned;
}

fn setNamedAgentMemoryApiDefaultUrl(allocator: std.mem.Allocator, config: *agent_memory_config.Config, profile: agent_memory_config.ApiProfile) !void {
    const default_url = profile.defaultBaseUrl() orelse return error.InvalidAgentMemoryApiProfile;
    try replaceOwnedOptionalString(allocator, &config.api.base_url, default_url);
}

fn parseAgentMemoryStoreConfigsJson(allocator: std.mem.Allocator, raw: []const u8) ![]agent_memory_config.NamedConfig {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidAgentMemoryStores;
    const items = parsed.value.array.items;
    var configs = try allocator.alloc(agent_memory_config.NamedConfig, items.len);
    var initialized: usize = 0;
    errdefer {
        freeParsedNamedAgentMemoryConfigEntries(allocator, configs[0..initialized]);
        allocator.free(configs);
    }
    for (items, 0..) |item, i| {
        if (item != .object) return error.InvalidAgentMemoryStores;
        const name = jsonStringField(item.object, "name") orelse return error.InvalidAgentMemoryStores;
        if (!agent_memory_config.isValidNamedStoreName(name)) return error.InvalidAgentMemoryStores;
        const backend = jsonStringField(item.object, "backend") orelse "memory_lru";
        var config = agent_memory_config.Config{ .backend = try parseNamedAgentMemoryBackend(backend) };
        switch (config.backend) {
            .supermemory => applyNamedAgentMemoryApiProfile(&config, .supermemory),
            .openviking => applyNamedAgentMemoryApiProfile(&config, .openviking),
            .honcho => applyNamedAgentMemoryApiProfile(&config, .honcho),
            .mem0 => applyNamedAgentMemoryApiProfile(&config, .mem0),
            .hindsight => applyNamedAgentMemoryApiProfile(&config, .hindsight),
            .retaindb => applyNamedAgentMemoryApiProfile(&config, .retaindb),
            .byterover => applyNamedAgentMemoryApiProfile(&config, .byterover),
            .zep => applyNamedAgentMemoryApiProfile(&config, .zep),
            .falkordb => applyNamedAgentMemoryApiProfile(&config, .falkordb),
            .markdown => {},
            .holographic => {},
            else => {},
        }
        var config_owned = true;
        errdefer if (config_owned) freeParsedAgentMemoryConfig(allocator, &config);
        if (jsonStringField(item.object, "redis_url")) |url| {
            freeParsedAgentMemoryConfig(allocator, &config);
            config.redis = try redis_config.parseUrl(allocator, url);
            config.backend = .redis;
        }
        if (jsonStringField(item.object, "clickhouse_url") orelse jsonStringField(item.object, "clickhouse_base_url")) |url| {
            config.clickhouse.base_url = try allocator.dupe(u8, url);
            config.backend = .clickhouse;
        }
        if (jsonStringField(item.object, "clickhouse_api_key")) |key| {
            config.clickhouse.api_key = try allocator.dupe(u8, key);
        }
        if (jsonStringField(item.object, "clickhouse_table")) |table| {
            try replaceOwnedStringIfOwned(allocator, &config.clickhouse.table, (agent_memory_config.ClickHouseConfig{}).table, table);
        }
        if (jsonIntField(item.object, "clickhouse_timeout_secs")) |secs| {
            config.clickhouse.timeout_secs = agent_memory_config.boundedRemoteTimeoutSecs(secs, config.clickhouse.timeout_secs);
        }
        if (jsonIntField(item.object, "clickhouse_max_response_bytes")) |bytes| {
            config.clickhouse.max_response_bytes = agent_memory_config.boundedRemoteResponseBytes(bytes, config.clickhouse.max_response_bytes);
        }
        if (jsonBoolField(item.object, "clickhouse_allow_insecure_http")) |allow| {
            config.clickhouse.allow_insecure_http = allow;
        }
        if (jsonStringField(item.object, "api_url") orelse jsonStringField(item.object, "base_url") orelse jsonStringField(item.object, "url")) |url| {
            if (std.mem.startsWith(u8, url, "supermemory://")) {
                applyNamedAgentMemoryApiProfile(&config, .supermemory);
                try setNamedAgentMemoryApiDefaultUrl(allocator, &config, .supermemory);
                try replaceOwnedOptionalString(allocator, &config.api.token, url["supermemory://".len..]);
            } else if (std.mem.startsWith(u8, url, "openviking://")) {
                applyNamedAgentMemoryApiProfile(&config, .openviking);
                try setNamedAgentMemoryApiDefaultUrl(allocator, &config, .openviking);
                try replaceOwnedOptionalString(allocator, &config.api.token, url["openviking://".len..]);
            } else if (std.mem.startsWith(u8, url, "honcho://")) {
                applyNamedAgentMemoryApiProfile(&config, .honcho);
                try setNamedAgentMemoryApiDefaultUrl(allocator, &config, .honcho);
                try replaceOwnedOptionalString(allocator, &config.api.token, url["honcho://".len..]);
            } else if (std.mem.startsWith(u8, url, "mem0://")) {
                applyNamedAgentMemoryApiProfile(&config, .mem0);
                try setNamedAgentMemoryApiDefaultUrl(allocator, &config, .mem0);
                try replaceOwnedOptionalString(allocator, &config.api.token, url["mem0://".len..]);
            } else if (std.mem.startsWith(u8, url, "hindsight://")) {
                applyNamedAgentMemoryApiProfile(&config, .hindsight);
                try setNamedAgentMemoryApiDefaultUrl(allocator, &config, .hindsight);
                try replaceOwnedOptionalString(allocator, &config.api.token, url["hindsight://".len..]);
            } else if (std.mem.startsWith(u8, url, "retaindb://")) {
                applyNamedAgentMemoryApiProfile(&config, .retaindb);
                try setNamedAgentMemoryApiDefaultUrl(allocator, &config, .retaindb);
                try replaceOwnedOptionalString(allocator, &config.api.token, url["retaindb://".len..]);
            } else if (std.mem.startsWith(u8, url, "byterover://")) {
                applyNamedAgentMemoryApiProfile(&config, .byterover);
                const project_dir = url["byterover://".len..];
                if (project_dir.len > 0) try replaceOwnedOptionalString(allocator, &config.api.byterover_project_dir, project_dir);
            } else if (std.mem.startsWith(u8, url, "zep://")) {
                applyNamedAgentMemoryApiProfile(&config, .zep);
                try setNamedAgentMemoryApiDefaultUrl(allocator, &config, .zep);
                try replaceOwnedOptionalString(allocator, &config.api.token, url["zep://".len..]);
            } else if (std.mem.startsWith(u8, url, "falkordb://")) {
                applyNamedAgentMemoryApiProfile(&config, .falkordb);
                try setNamedAgentMemoryApiDefaultUrl(allocator, &config, .falkordb);
                const graph = url["falkordb://".len..];
                if (graph.len > 0) try replaceOwnedOptionalString(allocator, &config.api.workspace_id, graph);
            } else if (std.mem.startsWith(u8, url, "markdown://")) {
                config.backend = .markdown;
                const workspace = url["markdown://".len..];
                if (workspace.len > 0) try replaceOwnedStringIfOwned(allocator, &config.markdown.workspace_dir, (agent_memory_config.MarkdownConfig{}).workspace_dir, workspace);
            } else if (std.mem.startsWith(u8, url, "md://")) {
                config.backend = .markdown;
                const workspace = url["md://".len..];
                if (workspace.len > 0) try replaceOwnedStringIfOwned(allocator, &config.markdown.workspace_dir, (agent_memory_config.MarkdownConfig{}).workspace_dir, workspace);
            } else if (config.backend == .markdown) {
                try replaceOwnedStringIfOwned(allocator, &config.markdown.workspace_dir, (agent_memory_config.MarkdownConfig{}).workspace_dir, url);
            } else {
                try replaceOwnedOptionalString(allocator, &config.api.base_url, url);
                if (config.backend != .supermemory and config.backend != .openviking and config.backend != .honcho and config.backend != .mem0 and config.backend != .hindsight and config.backend != .retaindb and config.backend != .byterover and config.backend != .zep and config.backend != .falkordb and config.backend != .markdown and config.backend != .holographic) config.backend = .api;
            }
        }
        if (jsonStringField(item.object, "api_profile") orelse jsonStringField(item.object, "profile")) |profile| {
            applyNamedAgentMemoryApiProfile(&config, try agent_memory_config.ApiProfile.parse(profile));
        }
        if (jsonStringField(item.object, "supermemory_url") orelse jsonStringField(item.object, "supermemory_base_url")) |url| {
            applyNamedAgentMemoryApiProfile(&config, .supermemory);
            try replaceOwnedOptionalString(allocator, &config.api.base_url, url);
        }
        if (jsonStringField(item.object, "api_token") orelse jsonStringField(item.object, "token")) |token| {
            try replaceOwnedOptionalString(allocator, &config.api.token, token);
        }
        if (jsonStringField(item.object, "supermemory_api_key") orelse jsonStringField(item.object, "supermemory_token")) |token| {
            applyNamedAgentMemoryApiProfile(&config, .supermemory);
            try replaceOwnedOptionalString(allocator, &config.api.token, token);
        }
        if (jsonStringField(item.object, "openviking_url") orelse jsonStringField(item.object, "openviking_base_url")) |url| {
            applyNamedAgentMemoryApiProfile(&config, .openviking);
            try replaceOwnedOptionalString(allocator, &config.api.base_url, url);
        }
        if (jsonStringField(item.object, "openviking_api_key") orelse jsonStringField(item.object, "openviking_token")) |token| {
            applyNamedAgentMemoryApiProfile(&config, .openviking);
            try replaceOwnedOptionalString(allocator, &config.api.token, token);
        }
        if (jsonStringField(item.object, "honcho_url") orelse jsonStringField(item.object, "honcho_base_url")) |url| {
            applyNamedAgentMemoryApiProfile(&config, .honcho);
            try replaceOwnedOptionalString(allocator, &config.api.base_url, url);
        }
        if (jsonStringField(item.object, "honcho_api_key") orelse jsonStringField(item.object, "honcho_token")) |token| {
            applyNamedAgentMemoryApiProfile(&config, .honcho);
            try replaceOwnedOptionalString(allocator, &config.api.token, token);
        }
        if (jsonStringField(item.object, "honcho_workspace_id") orelse jsonStringField(item.object, "workspace_id")) |workspace_id| {
            applyNamedAgentMemoryApiProfile(&config, .honcho);
            try replaceOwnedOptionalString(allocator, &config.api.workspace_id, workspace_id);
        }
        if (jsonStringField(item.object, "mem0_url") orelse jsonStringField(item.object, "mem0_base_url")) |url| {
            applyNamedAgentMemoryApiProfile(&config, .mem0);
            try replaceOwnedOptionalString(allocator, &config.api.base_url, url);
        }
        if (jsonStringField(item.object, "mem0_api_key") orelse jsonStringField(item.object, "mem0_token")) |token| {
            applyNamedAgentMemoryApiProfile(&config, .mem0);
            try replaceOwnedOptionalString(allocator, &config.api.token, token);
        }
        if (jsonStringField(item.object, "hindsight_url") orelse jsonStringField(item.object, "hindsight_base_url")) |url| {
            applyNamedAgentMemoryApiProfile(&config, .hindsight);
            try replaceOwnedOptionalString(allocator, &config.api.base_url, url);
        }
        if (jsonStringField(item.object, "hindsight_api_key") orelse jsonStringField(item.object, "hindsight_token")) |token| {
            applyNamedAgentMemoryApiProfile(&config, .hindsight);
            try replaceOwnedOptionalString(allocator, &config.api.token, token);
        }
        if (jsonStringField(item.object, "hindsight_bank_id") orelse jsonStringField(item.object, "bank_id")) |bank_id| {
            applyNamedAgentMemoryApiProfile(&config, .hindsight);
            try replaceOwnedOptionalString(allocator, &config.api.workspace_id, bank_id);
        }
        if (jsonStringField(item.object, "retaindb_url") orelse jsonStringField(item.object, "retaindb_base_url")) |url| {
            applyNamedAgentMemoryApiProfile(&config, .retaindb);
            try replaceOwnedOptionalString(allocator, &config.api.base_url, url);
        }
        if (jsonStringField(item.object, "retaindb_api_key") orelse jsonStringField(item.object, "retaindb_token")) |token| {
            applyNamedAgentMemoryApiProfile(&config, .retaindb);
            try replaceOwnedOptionalString(allocator, &config.api.token, token);
        }
        if (jsonStringField(item.object, "retaindb_project") orelse jsonStringField(item.object, "retaindb_project_id")) |project| {
            applyNamedAgentMemoryApiProfile(&config, .retaindb);
            try replaceOwnedOptionalString(allocator, &config.api.workspace_id, project);
        }
        if (jsonStringField(item.object, "byterover_command") orelse jsonStringField(item.object, "brv_command")) |command| {
            applyNamedAgentMemoryApiProfile(&config, .byterover);
            try replaceOwnedStringIfOwned(allocator, &config.api.byterover_command, (agent_memory_config.ApiConfig{}).byterover_command, command);
        }
        if (jsonStringField(item.object, "byterover_project_dir") orelse jsonStringField(item.object, "byterover_workspace") orelse jsonStringField(item.object, "project_dir")) |project_dir| {
            applyNamedAgentMemoryApiProfile(&config, .byterover);
            try replaceOwnedOptionalString(allocator, &config.api.byterover_project_dir, project_dir);
        }
        if (jsonBoolField(item.object, "byterover_use_swarm") orelse jsonBoolField(item.object, "brv_use_swarm")) |enabled| {
            applyNamedAgentMemoryApiProfile(&config, .byterover);
            config.api.byterover_use_swarm = enabled;
        }
        if (jsonStringField(item.object, "zep_url") orelse jsonStringField(item.object, "zep_base_url")) |url| {
            applyNamedAgentMemoryApiProfile(&config, .zep);
            try replaceOwnedOptionalString(allocator, &config.api.base_url, url);
        }
        if (jsonStringField(item.object, "zep_api_key") orelse jsonStringField(item.object, "zep_token")) |token| {
            applyNamedAgentMemoryApiProfile(&config, .zep);
            try replaceOwnedOptionalString(allocator, &config.api.token, token);
        }
        if (jsonStringField(item.object, "zep_graph_id")) |graph_id| {
            applyNamedAgentMemoryApiProfile(&config, .zep);
            try replaceOwnedOptionalString(allocator, &config.api.workspace_id, graph_id);
        }
        if (jsonStringField(item.object, "falkordb_url") orelse jsonStringField(item.object, "falkordb_base_url")) |url| {
            applyNamedAgentMemoryApiProfile(&config, .falkordb);
            try replaceOwnedOptionalString(allocator, &config.api.base_url, url);
        }
        if (jsonStringField(item.object, "falkordb_api_key") orelse jsonStringField(item.object, "falkordb_token")) |token| {
            applyNamedAgentMemoryApiProfile(&config, .falkordb);
            try replaceOwnedOptionalString(allocator, &config.api.token, token);
        }
        if (jsonStringField(item.object, "falkordb_graph") orelse jsonStringField(item.object, "falkordb_graph_id")) |graph| {
            applyNamedAgentMemoryApiProfile(&config, .falkordb);
            try replaceOwnedOptionalString(allocator, &config.api.workspace_id, graph);
        }
        if (jsonStringField(item.object, "markdown_workspace") orelse jsonStringField(item.object, "markdown_workspace_dir")) |workspace| {
            config.backend = .markdown;
            try replaceOwnedStringIfOwned(allocator, &config.markdown.workspace_dir, (agent_memory_config.MarkdownConfig{}).workspace_dir, workspace);
        }
        if (config.backend == .markdown) {
            if (jsonStringField(item.object, "workspace") orelse jsonStringField(item.object, "workspace_dir") orelse jsonStringField(item.object, "path") orelse jsonStringField(item.object, "directory")) |workspace| {
                try replaceOwnedStringIfOwned(allocator, &config.markdown.workspace_dir, (agent_memory_config.MarkdownConfig{}).workspace_dir, workspace);
            }
            if (jsonIntField(item.object, "markdown_max_file_bytes") orelse jsonIntField(item.object, "max_file_bytes")) |bytes| {
                config.markdown.max_file_bytes = agent_memory_config.boundedMarkdownFileBytes(bytes, config.markdown.max_file_bytes);
            }
        }
        if (jsonStringField(item.object, "holographic_db_path") orelse jsonStringField(item.object, "db_path")) |path| {
            config.backend = .holographic;
            try replaceOwnedOptionalString(allocator, &config.holographic.db_path, path);
        }
        if (jsonFloatField(item.object, "holographic_default_trust")) |value| {
            config.holographic.default_trust = value;
        }
        if (jsonFloatField(item.object, "holographic_trust_reward")) |value| {
            config.holographic.trust_reward = value;
        }
        if (jsonFloatField(item.object, "holographic_trust_penalty")) |value| {
            config.holographic.trust_penalty = value;
        }
        if (jsonStringField(item.object, "api_storage") orelse jsonStringField(item.object, "remote_storage") orelse jsonStringField(item.object, "api_store") orelse jsonStringField(item.object, "remote_store")) |storage| {
            try replaceOwnedOptionalString(allocator, &config.api.remote_storage, storage);
        }
        if (jsonStringField(item.object, "api_scopes") orelse jsonStringField(item.object, "actor_scopes")) |scopes| {
            try replaceOwnedStringIfOwned(allocator, &config.api.actor_scopes_json, (agent_memory_config.ApiConfig{}).actor_scopes_json, scopes);
        }
        if (jsonStringField(item.object, "api_capabilities") orelse jsonStringField(item.object, "actor_capabilities")) |capabilities| {
            try replaceOwnedStringIfOwned(allocator, &config.api.actor_capabilities_json, (agent_memory_config.ApiConfig{}).actor_capabilities_json, capabilities);
        }
        if (jsonIntField(item.object, "api_timeout_secs") orelse jsonIntField(item.object, "timeout_secs")) |secs| {
            if (isApiLikeAgentMemoryBackend(config.backend)) config.api.timeout_secs = agent_memory_config.boundedRemoteTimeoutSecs(secs, config.api.timeout_secs);
        }
        if (jsonIntField(item.object, "api_max_response_bytes") orelse jsonIntField(item.object, "max_response_bytes")) |bytes| {
            if (isApiLikeAgentMemoryBackend(config.backend)) config.api.max_response_bytes = agent_memory_config.boundedRemoteResponseBytes(bytes, config.api.max_response_bytes);
        }
        if (jsonBoolField(item.object, "api_allow_insecure_http") orelse jsonBoolField(item.object, "allow_insecure_http")) |allow| {
            if (isApiLikeAgentMemoryBackend(config.backend)) config.api.allow_insecure_http = allow;
        }
        if (jsonStringField(item.object, "redis_key_prefix")) |prefix| {
            try replaceOwnedStringIfOwned(allocator, &config.redis.key_prefix, (redis_config.Config{}).key_prefix, prefix);
        } else if (jsonStringField(item.object, "key_prefix")) |prefix| {
            try replaceOwnedStringIfOwned(allocator, &config.redis.key_prefix, (redis_config.Config{}).key_prefix, prefix);
        }
        if (config.backend == .memory_lru) {
            if (jsonIntField(item.object, "memory_max_entries") orelse jsonIntField(item.object, "max_entries")) |value| {
                config.memory.max_entries = bounded_int.nonNegativeI64ToUsize(value);
            }
            if (jsonIntField(item.object, "memory_max_messages") orelse jsonIntField(item.object, "max_messages")) |value| {
                config.memory.max_messages = bounded_int.nonNegativeI64ToUsize(value);
            }
            if (jsonIntField(item.object, "memory_max_usage_entries") orelse jsonIntField(item.object, "max_usage_entries")) |value| {
                config.memory.max_usage_entries = bounded_int.nonNegativeI64ToUsize(value);
            }
            if (jsonIntField(item.object, "memory_max_bytes") orelse jsonIntField(item.object, "max_bytes")) |value| {
                config.memory.max_bytes = bounded_int.nonNegativeI64ToUsize(value);
            }
            if (jsonIntField(item.object, "memory_ttl_seconds")) |ttl| {
                config.memory.ttl_seconds = bounded_int.nonNegativeI64ToU32(ttl);
            }
        }
        if (jsonIntField(item.object, "redis_ttl_seconds")) |ttl| {
            config.redis.ttl_seconds = bounded_int.nonNegativeI64ToU32(ttl);
        } else if (jsonIntField(item.object, "ttl_seconds")) |ttl| {
            if (config.backend == .redis) {
                config.redis.ttl_seconds = bounded_int.nonNegativeI64ToU32(ttl);
            } else if (config.backend == .memory_lru) {
                config.memory.ttl_seconds = bounded_int.nonNegativeI64ToU32(ttl);
            }
        }
        configs[i] = .{ .name = try allocator.dupe(u8, name), .config = config };
        config_owned = false;
        initialized = i + 1;
    }
    return configs;
}

fn parseVectorStoreConfigsJson(allocator: std.mem.Allocator, raw: []const u8) ![]vector_runtime.NamedConfig {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidVectorStores;
    const items = parsed.value.array.items;
    var configs = try allocator.alloc(vector_runtime.NamedConfig, items.len);
    var initialized: usize = 0;
    errdefer {
        freeParsedNamedVectorConfigEntries(allocator, configs[0..initialized]);
        allocator.free(configs);
    }
    for (items, 0..) |item, i| {
        if (item != .object) return error.InvalidVectorStores;
        const name = jsonStringField(item.object, "name") orelse return error.InvalidVectorStores;
        if (!vector_runtime.isValidNamedStoreName(name)) return error.InvalidVectorStores;
        var config = vector_runtime.Config{};
        var config_owned = true;
        errdefer if (config_owned) freeParsedVectorConfig(allocator, &config);
        if (jsonStringField(item.object, "backend")) |backend| {
            config.backend = try vector_runtime.BackendKind.parse(backend);
        }
        if (jsonStringField(item.object, "base_url") orelse jsonStringField(item.object, "url") orelse jsonStringField(item.object, "qdrant_url")) |url| {
            try replaceOwnedOptionalString(allocator, &config.base_url, url);
            if (config.backend == .local) config.backend = .qdrant;
        }
        if (jsonStringField(item.object, "lancedb_url")) |url| {
            try replaceOwnedOptionalString(allocator, &config.base_url, url);
            config.backend = .lancedb_http;
        }
        if (jsonStringField(item.object, "weaviate_url") orelse jsonStringField(item.object, "chroma_url") orelse jsonStringField(item.object, "opensearch_url")) |url| {
            try replaceOwnedOptionalString(allocator, &config.base_url, url);
            if (jsonStringField(item.object, "weaviate_url") != null) {
                config.backend = .weaviate;
            } else if (jsonStringField(item.object, "chroma_url") != null) {
                config.backend = .chroma;
            } else {
                config.backend = .opensearch;
            }
        }
        if (jsonStringField(item.object, "postgres_url") orelse jsonStringField(item.object, "pgvector_url")) |url| {
            try replaceOwnedOptionalString(allocator, &config.postgres_url, url);
            config.backend = .pgvector;
        }
        if (jsonStringField(item.object, "api_key") orelse jsonStringField(item.object, "token")) |key| {
            try replaceOwnedOptionalString(allocator, &config.api_key, key);
        }
        if (jsonStringField(item.object, "api_key_header")) |header| {
            try replaceOwnedStringIfOwned(allocator, &config.api_key_header, (vector_runtime.Config{}).api_key_header, header);
        }
        if (jsonStringField(item.object, "collection") orelse jsonStringField(item.object, "table")) |collection| {
            try replaceOwnedStringIfOwned(allocator, &config.collection, (vector_runtime.Config{}).collection, collection);
        }
        if (jsonStringField(item.object, "weaviate_collection")) |collection| {
            config.backend = .weaviate;
            try replaceOwnedStringIfOwned(allocator, &config.collection, (vector_runtime.Config{}).collection, collection);
        }
        if (jsonStringField(item.object, "chroma_collection") orelse jsonStringField(item.object, "chroma_collection_id")) |collection| {
            config.backend = .chroma;
            try replaceOwnedStringIfOwned(allocator, &config.collection, (vector_runtime.Config{}).collection, collection);
        }
        if (jsonStringField(item.object, "chroma_tenant")) |tenant| {
            config.backend = .chroma;
            try replaceOwnedStringIfOwned(allocator, &config.chroma_tenant, (vector_runtime.Config{}).chroma_tenant, tenant);
        }
        if (jsonStringField(item.object, "chroma_database")) |database| {
            config.backend = .chroma;
            try replaceOwnedStringIfOwned(allocator, &config.chroma_database, (vector_runtime.Config{}).chroma_database, database);
        }
        if (jsonStringField(item.object, "opensearch_index")) |index| {
            config.backend = .opensearch;
            try replaceOwnedStringIfOwned(allocator, &config.collection, (vector_runtime.Config{}).collection, index);
        }
        if (jsonStringField(item.object, "lancedb_uri") orelse jsonStringField(item.object, "uri")) |uri| {
            try replaceOwnedOptionalString(allocator, &config.lancedb_uri, uri);
            config.backend = .lancedb;
        }
        if (jsonStringField(item.object, "lancedb_command") orelse jsonStringField(item.object, "command")) |command| {
            try replaceOwnedStringIfOwned(allocator, &config.lancedb_command, (vector_runtime.Config{}).lancedb_command, command);
            if (config.backend == .local) config.backend = .lancedb;
        }
        if (jsonIntField(item.object, "timeout_secs")) |secs| {
            config.timeout_secs = runtime_limits.boundedTimeoutSecs(secs, config.timeout_secs);
        }
        if (jsonBoolField(item.object, "allow_insecure_http")) |allow| {
            config.allow_insecure_http = allow;
        }
        if (jsonBoolField(item.object, "circuit_breaker_enabled")) |enabled| {
            config.circuit_breaker_enabled = enabled;
        }
        if (jsonIntField(item.object, "circuit_breaker_threshold")) |threshold| {
            config.circuit_breaker_threshold = circuit_breaker.boundedFailureThreshold(threshold, config.circuit_breaker_threshold);
        }
        if (jsonIntField(item.object, "circuit_breaker_cooldown_ms")) |cooldown| {
            config.circuit_breaker_cooldown_ms = circuit_breaker.boundedCooldownMsU64(cooldown, config.circuit_breaker_cooldown_ms);
        }
        if (!config.externalEnabled()) return error.InvalidVectorStores;
        configs[i] = .{ .name = try allocator.dupe(u8, name), .config = config };
        config_owned = false;
        initialized = i + 1;
    }
    return configs;
}

fn parseAgentMemoryStoreSpec(allocator: std.mem.Allocator, raw: []const u8) !agent_memory_config.NamedConfig {
    const eq = std.mem.indexOfScalar(u8, raw, '=') orelse return error.InvalidAgentMemoryStore;
    const name = std.mem.trim(u8, raw[0..eq], " \t\r\n");
    const value = std.mem.trim(u8, raw[eq + 1 ..], " \t\r\n");
    if (name.len == 0 or value.len == 0) return error.InvalidAgentMemoryStore;
    if (!agent_memory_config.isValidNamedStoreName(name)) return error.InvalidAgentMemoryStore;
    var config = agent_memory_config.Config{};
    errdefer freeParsedAgentMemoryConfig(allocator, &config);
    if (std.mem.startsWith(u8, value, "redis://")) {
        config.redis = try redis_config.parseUrl(allocator, value);
        config.backend = .redis;
    } else if (std.mem.startsWith(u8, value, "http://") or std.mem.startsWith(u8, value, "https://")) {
        try replaceOwnedOptionalString(allocator, &config.api.base_url, value);
        config.backend = .api;
    } else if (std.mem.startsWith(u8, value, "supermemory://")) {
        applyNamedAgentMemoryApiProfile(&config, .supermemory);
        try setNamedAgentMemoryApiDefaultUrl(allocator, &config, .supermemory);
        try replaceOwnedOptionalString(allocator, &config.api.token, value["supermemory://".len..]);
    } else if (std.mem.startsWith(u8, value, "openviking://")) {
        applyNamedAgentMemoryApiProfile(&config, .openviking);
        try setNamedAgentMemoryApiDefaultUrl(allocator, &config, .openviking);
        try replaceOwnedOptionalString(allocator, &config.api.token, value["openviking://".len..]);
    } else if (std.mem.startsWith(u8, value, "honcho://")) {
        applyNamedAgentMemoryApiProfile(&config, .honcho);
        try setNamedAgentMemoryApiDefaultUrl(allocator, &config, .honcho);
        try replaceOwnedOptionalString(allocator, &config.api.token, value["honcho://".len..]);
    } else if (std.mem.startsWith(u8, value, "mem0://")) {
        applyNamedAgentMemoryApiProfile(&config, .mem0);
        try setNamedAgentMemoryApiDefaultUrl(allocator, &config, .mem0);
        try replaceOwnedOptionalString(allocator, &config.api.token, value["mem0://".len..]);
    } else if (std.mem.startsWith(u8, value, "hindsight://")) {
        applyNamedAgentMemoryApiProfile(&config, .hindsight);
        try setNamedAgentMemoryApiDefaultUrl(allocator, &config, .hindsight);
        try replaceOwnedOptionalString(allocator, &config.api.token, value["hindsight://".len..]);
    } else if (std.mem.startsWith(u8, value, "retaindb://")) {
        applyNamedAgentMemoryApiProfile(&config, .retaindb);
        try setNamedAgentMemoryApiDefaultUrl(allocator, &config, .retaindb);
        try replaceOwnedOptionalString(allocator, &config.api.token, value["retaindb://".len..]);
    } else if (std.mem.startsWith(u8, value, "byterover://")) {
        applyNamedAgentMemoryApiProfile(&config, .byterover);
        const project_dir = value["byterover://".len..];
        if (project_dir.len > 0) try replaceOwnedOptionalString(allocator, &config.api.byterover_project_dir, project_dir);
    } else if (std.mem.startsWith(u8, value, "zep://")) {
        applyNamedAgentMemoryApiProfile(&config, .zep);
        try setNamedAgentMemoryApiDefaultUrl(allocator, &config, .zep);
        try replaceOwnedOptionalString(allocator, &config.api.token, value["zep://".len..]);
    } else if (std.mem.startsWith(u8, value, "falkordb://")) {
        applyNamedAgentMemoryApiProfile(&config, .falkordb);
        try setNamedAgentMemoryApiDefaultUrl(allocator, &config, .falkordb);
        const graph = value["falkordb://".len..];
        if (graph.len > 0) try replaceOwnedOptionalString(allocator, &config.api.workspace_id, graph);
    } else if (std.mem.startsWith(u8, value, "markdown://")) {
        config.backend = .markdown;
        const workspace = value["markdown://".len..];
        if (workspace.len > 0) try replaceOwnedStringIfOwned(allocator, &config.markdown.workspace_dir, (agent_memory_config.MarkdownConfig{}).workspace_dir, workspace);
    } else if (std.mem.startsWith(u8, value, "md://")) {
        config.backend = .markdown;
        const workspace = value["md://".len..];
        if (workspace.len > 0) try replaceOwnedStringIfOwned(allocator, &config.markdown.workspace_dir, (agent_memory_config.MarkdownConfig{}).workspace_dir, workspace);
    } else if (std.mem.startsWith(u8, value, "holographic://")) {
        config.backend = .holographic;
        try replaceOwnedOptionalString(allocator, &config.holographic.db_path, value["holographic://".len..]);
    } else {
        config.backend = try parseNamedAgentMemoryBackend(value);
    }
    const owned_name = try allocator.dupe(u8, name);
    return .{ .name = owned_name, .config = config };
}

fn parseVectorStoreSpec(allocator: std.mem.Allocator, raw: []const u8) !vector_runtime.NamedConfig {
    const eq = std.mem.indexOfScalar(u8, raw, '=') orelse return error.InvalidVectorStore;
    const name = std.mem.trim(u8, raw[0..eq], " \t\r\n");
    const value = std.mem.trim(u8, raw[eq + 1 ..], " \t\r\n");
    if (name.len == 0 or value.len == 0) return error.InvalidVectorStore;
    if (!vector_runtime.isValidNamedStoreName(name)) return error.InvalidVectorStore;
    var config = vector_runtime.Config{};
    var parts = std.mem.splitScalar(u8, value, ',');
    var saw_part = false;
    while (parts.next()) |raw_part| {
        const part = std.mem.trim(u8, raw_part, " \t\r\n");
        if (part.len == 0) continue;
        saw_part = true;
        if (std.mem.indexOfScalar(u8, part, '=')) |part_eq| {
            const key = std.mem.trim(u8, part[0..part_eq], " \t\r\n");
            const part_value = std.mem.trim(u8, part[part_eq + 1 ..], " \t\r\n");
            try applyVectorStoreSpecOption(&config, key, part_value);
        } else if (std.mem.startsWith(u8, part, "postgres://") or std.mem.startsWith(u8, part, "postgresql://")) {
            config.backend = .pgvector;
            config.postgres_url = part;
        } else if (std.mem.startsWith(u8, part, "http://") or std.mem.startsWith(u8, part, "https://")) {
            if (config.backend == .lancedb_http) {
                config.base_url = part;
            } else {
                config.backend = .qdrant;
                config.base_url = part;
            }
        } else {
            config.backend = try vector_runtime.BackendKind.parse(part);
        }
    }
    if (!saw_part or !config.externalEnabled()) return error.InvalidVectorStore;
    return .{ .name = try allocator.dupe(u8, name), .config = config };
}

fn applyVectorStoreSpecOption(config: *vector_runtime.Config, key: []const u8, value: []const u8) !void {
    if (value.len == 0) return error.InvalidVectorStore;
    if (std.ascii.eqlIgnoreCase(key, "backend")) {
        config.backend = try vector_runtime.BackendKind.parse(value);
    } else if (std.ascii.eqlIgnoreCase(key, "url") or std.ascii.eqlIgnoreCase(key, "base_url") or std.ascii.eqlIgnoreCase(key, "qdrant_url")) {
        config.base_url = value;
        if (config.backend == .local) config.backend = .qdrant;
    } else if (std.ascii.eqlIgnoreCase(key, "lancedb_url")) {
        config.base_url = value;
        config.backend = .lancedb_http;
    } else if (std.ascii.eqlIgnoreCase(key, "weaviate_url")) {
        config.backend = .weaviate;
        config.base_url = value;
    } else if (std.ascii.eqlIgnoreCase(key, "chroma_url")) {
        config.backend = .chroma;
        config.base_url = value;
    } else if (std.ascii.eqlIgnoreCase(key, "opensearch_url")) {
        config.backend = .opensearch;
        config.base_url = value;
    } else if (std.ascii.eqlIgnoreCase(key, "postgres_url") or std.ascii.eqlIgnoreCase(key, "pgvector_url")) {
        config.backend = .pgvector;
        config.postgres_url = value;
    } else if (std.ascii.eqlIgnoreCase(key, "collection") or std.ascii.eqlIgnoreCase(key, "table")) {
        config.collection = value;
    } else if (std.ascii.eqlIgnoreCase(key, "weaviate_collection")) {
        config.backend = .weaviate;
        config.collection = value;
    } else if (std.ascii.eqlIgnoreCase(key, "chroma_collection") or std.ascii.eqlIgnoreCase(key, "chroma_collection_id")) {
        config.backend = .chroma;
        config.collection = value;
    } else if (std.ascii.eqlIgnoreCase(key, "chroma_tenant")) {
        config.backend = .chroma;
        config.chroma_tenant = value;
    } else if (std.ascii.eqlIgnoreCase(key, "chroma_database")) {
        config.backend = .chroma;
        config.chroma_database = value;
    } else if (std.ascii.eqlIgnoreCase(key, "opensearch_index")) {
        config.backend = .opensearch;
        config.collection = value;
    } else if (std.ascii.eqlIgnoreCase(key, "api_key") or std.ascii.eqlIgnoreCase(key, "token")) {
        config.api_key = value;
    } else if (std.ascii.eqlIgnoreCase(key, "api_key_header")) {
        config.api_key_header = value;
    } else if (std.ascii.eqlIgnoreCase(key, "lancedb_uri") or std.ascii.eqlIgnoreCase(key, "uri")) {
        config.backend = .lancedb;
        config.lancedb_uri = value;
    } else if (std.ascii.eqlIgnoreCase(key, "lancedb_command") or std.ascii.eqlIgnoreCase(key, "command")) {
        if (config.backend == .local) config.backend = .lancedb;
        config.lancedb_command = value;
    } else if (std.ascii.eqlIgnoreCase(key, "timeout_secs")) {
        config.timeout_secs = try parseRuntimeTimeoutSecs(value, config.timeout_secs);
    } else if (std.ascii.eqlIgnoreCase(key, "allow_insecure_http")) {
        config.allow_insecure_http = try parseBool(value);
    } else if (std.ascii.eqlIgnoreCase(key, "circuit_breaker_enabled")) {
        config.circuit_breaker_enabled = try parseBool(value);
    } else if (std.ascii.eqlIgnoreCase(key, "circuit_breaker_threshold")) {
        config.circuit_breaker_threshold = try parseCircuitFailureThreshold(value, config.circuit_breaker_threshold);
    } else if (std.ascii.eqlIgnoreCase(key, "circuit_breaker_cooldown_ms")) {
        config.circuit_breaker_cooldown_ms = try parseCircuitCooldownMsU64(value, config.circuit_breaker_cooldown_ms);
    } else {
        return error.InvalidVectorStore;
    }
}

fn parseNamedAgentMemoryBackend(raw: []const u8) !agent_memory_config.BackendKind {
    if (std.ascii.eqlIgnoreCase(raw, "none")) return .none;
    if (std.ascii.eqlIgnoreCase(raw, "memory")) return .memory_lru;
    if (std.ascii.eqlIgnoreCase(raw, "memory_lru")) return .memory_lru;
    if (std.ascii.eqlIgnoreCase(raw, "in_memory")) return .memory_lru;
    if (std.ascii.eqlIgnoreCase(raw, "markdown")) return .markdown;
    if (std.ascii.eqlIgnoreCase(raw, "md")) return .markdown;
    if (std.ascii.eqlIgnoreCase(raw, "filesystem")) return .markdown;
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
    return error.InvalidAgentMemoryStore;
}

fn isApiLikeAgentMemoryBackend(kind: agent_memory_config.BackendKind) bool {
    return switch (kind) {
        .api, .supermemory, .openviking, .honcho, .mem0, .hindsight, .retaindb, .byterover, .zep, .falkordb => true,
        else => false,
    };
}

fn configAppendLen(current_len: usize) !usize {
    return std.math.add(usize, current_len, 1) catch error.OutOfMemory;
}

fn appendAgentMemoryStoreConfig(allocator: std.mem.Allocator, cfg: *RuntimeConfig, named: agent_memory_config.NamedConfig) !void {
    var owned_named = named;
    errdefer freeParsedNamedAgentMemoryConfig(allocator, &owned_named);
    const previous = cfg.stores.agent_memory_stores;
    var next = try allocator.alloc(agent_memory_config.NamedConfig, try configAppendLen(previous.len));
    for (previous, 0..) |existing, i| next[i] = existing;
    next[previous.len] = owned_named;
    cfg.stores.agent_memory_stores = next;
    if (previous.len > 0) allocator.free(previous);
}

fn appendVectorStoreConfig(allocator: std.mem.Allocator, cfg: *RuntimeConfig, named: vector_runtime.NamedConfig) !void {
    const previous = cfg.stores.vector_stores;
    var next = try allocator.alloc(vector_runtime.NamedConfig, try configAppendLen(previous.len));
    for (previous, 0..) |existing, i| next[i] = existing;
    next[previous.len] = named;
    cfg.stores.vector_stores = next;
    if (previous.len > 0) allocator.free(previous);
}

fn freeParsedAgentMemoryConfig(allocator: std.mem.Allocator, config: *agent_memory_config.Config) void {
    const default_redis = redis_config.Config{};
    const default_markdown = agent_memory_config.MarkdownConfig{};
    const default_clickhouse = agent_memory_config.ClickHouseConfig{};
    const default_api = agent_memory_config.ApiConfig{};
    const default_holographic = agent_memory_config.HolographicConfig{};

    if (config.redis.host.ptr != default_redis.host.ptr) allocator.free(config.redis.host);
    if (config.redis.password) |password| allocator.free(password);
    if (config.redis.key_prefix.ptr != default_redis.key_prefix.ptr) allocator.free(config.redis.key_prefix);

    if (config.markdown.workspace_dir.ptr != default_markdown.workspace_dir.ptr) allocator.free(config.markdown.workspace_dir);
    if (config.markdown.default_scope.ptr != default_markdown.default_scope.ptr) allocator.free(config.markdown.default_scope);
    if (config.markdown.permissions_json.ptr != default_markdown.permissions_json.ptr) allocator.free(config.markdown.permissions_json);

    if (config.clickhouse.base_url) |url| allocator.free(url);
    if (config.clickhouse.api_key) |key| allocator.free(key);
    if (config.clickhouse.table.ptr != default_clickhouse.table.ptr) allocator.free(config.clickhouse.table);

    if (config.api.base_url) |url| allocator.free(url);
    if (config.api.token) |token| allocator.free(token);
    if (config.api.remote_storage) |storage| allocator.free(storage);
    if (config.api.workspace_id) |workspace_id| allocator.free(workspace_id);
    if (config.api.actor_scopes_json.ptr != default_api.actor_scopes_json.ptr) allocator.free(config.api.actor_scopes_json);
    if (config.api.actor_capabilities_json.ptr != default_api.actor_capabilities_json.ptr) allocator.free(config.api.actor_capabilities_json);
    if (config.api.byterover_command.ptr != default_api.byterover_command.ptr) allocator.free(config.api.byterover_command);
    if (config.api.byterover_project_dir) |project_dir| allocator.free(project_dir);
    if (config.holographic.db_path) |path| {
        if (default_holographic.db_path == null or path.ptr != default_holographic.db_path.?.ptr) allocator.free(path);
    }

    config.* = .{};
}

fn freeParsedVectorConfig(allocator: std.mem.Allocator, config: *vector_runtime.Config) void {
    const default_config = vector_runtime.Config{};
    if (config.base_url) |url| allocator.free(url);
    if (config.api_key) |key| allocator.free(key);
    if (config.api_key_header.len > 0 and config.api_key_header.ptr != default_config.api_key_header.ptr) allocator.free(config.api_key_header);
    if (config.collection.ptr != default_config.collection.ptr) allocator.free(config.collection);
    if (config.chroma_tenant.ptr != default_config.chroma_tenant.ptr) allocator.free(config.chroma_tenant);
    if (config.chroma_database.ptr != default_config.chroma_database.ptr) allocator.free(config.chroma_database);
    if (config.postgres_url) |url| allocator.free(url);
    if (config.lancedb_uri) |uri| allocator.free(uri);
    if (config.lancedb_command.ptr != default_config.lancedb_command.ptr) allocator.free(config.lancedb_command);
    config.* = .{};
}

fn freeParsedNamedAgentMemoryConfig(allocator: std.mem.Allocator, named: *agent_memory_config.NamedConfig) void {
    allocator.free(named.name);
    freeParsedAgentMemoryConfig(allocator, &named.config);
    named.* = .{ .name = "", .config = .{} };
}

fn freeParsedNamedVectorConfig(allocator: std.mem.Allocator, named: *vector_runtime.NamedConfig) void {
    allocator.free(named.name);
    freeParsedVectorConfig(allocator, &named.config);
    named.* = .{ .name = "", .config = .{} };
}

fn freeParsedNamedAgentMemoryConfigs(allocator: std.mem.Allocator, configs: []agent_memory_config.NamedConfig) void {
    freeParsedNamedAgentMemoryConfigEntries(allocator, configs);
    allocator.free(configs);
}

fn freeParsedNamedVectorConfigs(allocator: std.mem.Allocator, configs: []vector_runtime.NamedConfig) void {
    freeParsedNamedVectorConfigEntries(allocator, configs);
    allocator.free(configs);
}

fn freeParsedNamedAgentMemoryConfigEntries(allocator: std.mem.Allocator, configs: []agent_memory_config.NamedConfig) void {
    for (configs) |*config| freeParsedNamedAgentMemoryConfig(allocator, config);
}

fn freeParsedNamedVectorConfigEntries(allocator: std.mem.Allocator, configs: []vector_runtime.NamedConfig) void {
    for (configs) |*config| freeParsedNamedVectorConfig(allocator, config);
}

fn jsonStringField(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = obj.get(name) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn jsonIntField(obj: std.json.ObjectMap, name: []const u8) ?i64 {
    const value = obj.get(name) orelse return null;
    return switch (value) {
        .integer => |n| n,
        .float => |f| json_util.safeFloatToI64(f),
        else => null,
    };
}

fn jsonFloatField(obj: std.json.ObjectMap, name: []const u8) ?f64 {
    const value = obj.get(name) orelse return null;
    return switch (value) {
        .integer => |n| @floatFromInt(n),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        .string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

fn jsonBoolField(obj: std.json.ObjectMap, name: []const u8) ?bool {
    const value = obj.get(name) orelse return null;
    return switch (value) {
        .bool => |b| b,
        .string => |s| parseBool(s) catch null,
        else => null,
    };
}

fn parseBool(raw: []const u8) !bool {
    const value = std.mem.trim(u8, raw, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(value, "1") or
        std.ascii.eqlIgnoreCase(value, "true") or
        std.ascii.eqlIgnoreCase(value, "yes") or
        std.ascii.eqlIgnoreCase(value, "on"))
    {
        return true;
    }
    if (std.ascii.eqlIgnoreCase(value, "0") or
        std.ascii.eqlIgnoreCase(value, "false") or
        std.ascii.eqlIgnoreCase(value, "no") or
        std.ascii.eqlIgnoreCase(value, "off"))
    {
        return false;
    }
    return error.InvalidBoolConfig;
}

fn parsePercent(raw: []const u8) !u8 {
    const parsed = try std.fmt.parseInt(i64, std.mem.trim(u8, raw, " \t\r\n"), 10);
    return @intCast(@max(@as(i64, 0), @min(@as(i64, 100), parsed)));
}

fn parsePositiveUsize(raw: []const u8) !usize {
    const parsed = try std.fmt.parseInt(i64, std.mem.trim(u8, raw, " \t\r\n"), 10);
    if (parsed <= 0) return error.InvalidPositiveInteger;
    return @intCast(parsed);
}

fn parseProviderResponseBytes(raw: []const u8) !usize {
    const parsed = try std.fmt.parseInt(i64, std.mem.trim(u8, raw, " \t\r\n"), 10);
    if (parsed <= 0) return error.InvalidPositiveInteger;
    return providers.boundedProviderResponseBytes(parsed, providers.max_provider_response_bytes);
}

fn parseProviderTimeoutSecs(raw: []const u8) !u32 {
    const parsed = try std.fmt.parseInt(i64, std.mem.trim(u8, raw, " \t\r\n"), 10);
    if (parsed <= 0) return error.InvalidPositiveInteger;
    return providers.boundedProviderTimeoutSecs(parsed, 30);
}

fn parseRuntimeTimeoutSecs(raw: []const u8, fallback: u32) !u32 {
    const parsed = try std.fmt.parseInt(i64, std.mem.trim(u8, raw, " \t\r\n"), 10);
    return runtime_limits.boundedTimeoutSecs(parsed, fallback);
}

fn parseMarkdownFileBytes(raw: []const u8, fallback: usize) !usize {
    const parsed = try std.fmt.parseInt(i64, std.mem.trim(u8, raw, " \t\r\n"), 10);
    return agent_memory_config.boundedMarkdownFileBytes(parsed, fallback);
}

fn parseLucidTokenBudget(raw: []const u8, fallback: usize) !usize {
    const parsed = try std.fmt.parseInt(i64, std.mem.trim(u8, raw, " \t\r\n"), 10);
    return lucid_runtime.boundedTokenBudget(parsed, fallback);
}

fn parseLucidLocalHitThreshold(raw: []const u8, fallback: usize) !usize {
    const parsed = try std.fmt.parseInt(i64, std.mem.trim(u8, raw, " \t\r\n"), 10);
    return lucid_runtime.boundedLocalHitThreshold(parsed, fallback);
}

fn parseCircuitFailureThreshold(raw: []const u8, fallback: u32) !u32 {
    const parsed = try std.fmt.parseInt(i64, std.mem.trim(u8, raw, " \t\r\n"), 10);
    return circuit_breaker.boundedFailureThreshold(parsed, fallback);
}

fn parseCircuitCooldownMs(raw: []const u8, fallback: i64) !i64 {
    const parsed = try std.fmt.parseInt(i64, std.mem.trim(u8, raw, " \t\r\n"), 10);
    return circuit_breaker.boundedCooldownMs(parsed, fallback);
}

fn parseCircuitCooldownMsU64(raw: []const u8, fallback: u64) !u64 {
    const parsed = try std.fmt.parseInt(i64, std.mem.trim(u8, raw, " \t\r\n"), 10);
    return circuit_breaker.boundedCooldownMsU64(parsed, fallback);
}

test "bool config parser accepts explicit values and rejects typos" {
    try std.testing.expect(try parseBool("true"));
    try std.testing.expect(try parseBool("YES"));
    try std.testing.expect(try parseBool("on"));
    try std.testing.expect(try parseBool("1"));
    try std.testing.expect(!(try parseBool("false")));
    try std.testing.expect(!(try parseBool("NO")));
    try std.testing.expect(!(try parseBool("off")));
    try std.testing.expect(!(try parseBool("0")));
    try std.testing.expectError(error.InvalidBoolConfig, parseBool(""));
    try std.testing.expectError(error.InvalidBoolConfig, parseBool("treu"));
}

test "percent config parser clamps explicit numbers and rejects typos" {
    try std.testing.expectEqual(@as(u8, 0), try parsePercent("-4"));
    try std.testing.expectEqual(@as(u8, 42), try parsePercent("42"));
    try std.testing.expectEqual(@as(u8, 100), try parsePercent("140"));
    try std.testing.expectError(error.InvalidCharacter, parsePercent("forty"));
}

test "positive usize config parser rejects disabled limits" {
    try std.testing.expectEqual(@as(usize, 42), try parsePositiveUsize("42"));
    try std.testing.expectEqual(@as(usize, 7), try parsePositiveUsize(" 7 "));
    try std.testing.expectError(error.InvalidPositiveInteger, parsePositiveUsize("0"));
    try std.testing.expectError(error.InvalidPositiveInteger, parsePositiveUsize("-1"));
}

test "provider response byte parser caps oversized values" {
    try std.testing.expectEqual(@as(usize, 42), try parseProviderResponseBytes("42"));
    try std.testing.expectEqual(providers.max_configured_provider_response_bytes, try parseProviderResponseBytes("9223372036854775807"));
    try std.testing.expectError(error.InvalidPositiveInteger, parseProviderResponseBytes("0"));
}

test "provider timeout parser caps oversized values" {
    try std.testing.expectEqual(@as(u32, 42), try parseProviderTimeoutSecs("42"));
    try std.testing.expectEqual(providers.max_provider_timeout_secs, try parseProviderTimeoutSecs("9223372036854775807"));
    try std.testing.expectError(error.InvalidPositiveInteger, parseProviderTimeoutSecs("0"));
}

test "named store config append length checks allocation size" {
    try std.testing.expectEqual(@as(usize, 1), try configAppendLen(0));
    try std.testing.expectEqual(@as(usize, 42), try configAppendLen(41));
    try std.testing.expectError(error.OutOfMemory, configAppendLen(std.math.maxInt(usize)));
}

const TestingEnvVar = struct {
    name: [:0]const u8,
    original: ?[:0]u8 = null,

    fn capture(allocator: std.mem.Allocator, name: [:0]const u8) !TestingEnvVar {
        var out = TestingEnvVar{ .name = name };
        const value = compat.process.getEnvVarOwned(allocator, name) catch |err| switch (err) {
            error.EnvironmentVariableNotFound => return out,
            else => |e| return e,
        };
        defer allocator.free(value);
        out.original = try allocator.dupeZ(u8, value);
        return out;
    }

    fn set(self: TestingEnvVar, value: [:0]const u8) !void {
        if (setenv(self.name.ptr, value.ptr, 1) != 0) return error.SetEnvironmentFailed;
    }

    fn unset(self: TestingEnvVar) !void {
        if (unsetenv(self.name.ptr) != 0) return error.UnsetEnvironmentFailed;
    }

    fn restore(self: *TestingEnvVar, allocator: std.mem.Allocator) void {
        if (self.original) |value| {
            _ = setenv(self.name.ptr, value.ptr, 1);
            allocator.free(value);
        } else {
            _ = unsetenv(self.name.ptr);
        }
        self.original = null;
    }
};

test "runtime config file maps structured sections into runtime config" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const config_path = try std.fmt.allocPrintSentinel(allocator, ".zig-cache/tmp/{s}/runtime-config.json", .{tmp.sub_path}, 0);
    try std.Io.Dir.cwd().writeFile(compat.io(), .{
        .sub_path = config_path,
        .data =
        \\{
        \\  "server": {"host": "127.0.0.2", "port": 9876, "instance_id": "cfg-instance"},
        \\  "records": {"backend": "sqlite", "db_path": ".nullpantry/configured.db"},
        \\  "auth": {"token": "config-token", "trust_actor_headers": true},
        \\  "actor": {"scopes": ["project:nullpantry"], "capabilities": ["read", "write"]},
        \\  "worker": {"interval_ms": 0, "scopes": ["admin"], "capabilities": ["read", "write", "verify"]},
        \\  "filesystem": {"root": ".nullpantry/files"},
        \\  "provider": {
        \\    "embedding": {"provider": "local-deterministic", "model": "semantic", "dimensions": 128},
        \\    "llm": {"base_url": "https://llm.example/v1", "model": "chat", "api_key": "llm-key", "max_response_bytes": 4096}
        \\  },
        \\  "retrieval": {"chunker": {"max_chars": 2048, "overlap_chars": 128, "strategy": "markdown"}},
        \\  "agent_memory": {
        \\    "backend": "redis",
        \\    "redis": {"url": "redis://127.0.0.1:6379/2", "key_prefix": "cfg", "ttl_seconds": 30},
        \\    "stores": [{"name": "scratch", "backend": "memory_lru", "max_entries": 12}]
        \\  },
        \\  "vector": {
        \\    "backend": "pgvector",
        \\    "pgvector": {"url": "postgres://user:pass@127.0.0.1:5432/nullpantry_vectors", "table": "np_vectors"}
        \\  }
        \\}
        ,
    });

    const args = [_][:0]const u8{ "nullpantry", "--config", config_path };
    const cfg = try parseArgs(allocator, &args);
    const embedding = embeddingConfigFromRuntime(cfg);
    const completion = completionConfigFromRuntime(cfg);

    try std.testing.expectEqualStrings("127.0.0.2", cfg.host);
    try std.testing.expectEqual(@as(u16, 9876), cfg.port);
    try std.testing.expectEqualStrings("cfg-instance", cfg.instance_id);
    try std.testing.expectEqualStrings(".nullpantry/configured.db", cfg.db_path);
    try std.testing.expectEqual(store_config.BackendKind.sqlite, cfg.stores.records_backend);
    try std.testing.expectEqualStrings("config-token", cfg.auth.required_token.?);
    try std.testing.expect(cfg.auth.trust_actor_headers);
    try std.testing.expectEqualStrings("[\"project:nullpantry\"]", cfg.actor.scopes_json);
    try std.testing.expectEqualStrings("[\"read\",\"write\"]", cfg.actor.capabilities_json);
    try std.testing.expectEqual(@as(u64, 0), cfg.worker_interval_ms);
    try std.testing.expectEqualStrings("[\"admin\"]", cfg.worker.scopes_json);
    try std.testing.expectEqualStrings("[\"read\",\"write\",\"verify\"]", cfg.worker.capabilities_json);
    try std.testing.expectEqualStrings(".nullpantry/files", cfg.filesystem.root);
    try std.testing.expectEqual(providers.EmbeddingProviderKind.local_deterministic, embedding.provider);
    try std.testing.expectEqualStrings("semantic", embedding.model.?);
    try std.testing.expectEqual(@as(usize, 128), embedding.dimensions);
    try std.testing.expect(embedding.send_dimensions);
    try std.testing.expectEqualStrings("https://llm.example/v1", completion.base_url.?);
    try std.testing.expectEqualStrings("chat", completion.model.?);
    try std.testing.expectEqualStrings("llm-key", completion.api_key.?);
    try std.testing.expectEqual(@as(usize, 4096), completion.max_response_bytes);
    try std.testing.expectEqual(@as(usize, 2048), cfg.retrieval.chunker.max_chars);
    try std.testing.expectEqual(@as(usize, 128), cfg.retrieval.chunker.overlap_chars);
    try std.testing.expectEqual(vector_mod.ChunkStrategy.markdown, cfg.retrieval.chunker.strategy);
    try std.testing.expectEqual(agent_memory_config.BackendKind.redis, cfg.stores.agent_memory_backend);
    try std.testing.expectEqualStrings("127.0.0.1", cfg.stores.redis.host);
    try std.testing.expectEqual(@as(u8, 2), cfg.stores.redis.db_index);
    try std.testing.expectEqualStrings("cfg", cfg.stores.redis.key_prefix);
    try std.testing.expectEqual(@as(u32, 30), cfg.stores.redis.ttl_seconds.?);
    try std.testing.expectEqual(@as(usize, 1), cfg.stores.agent_memory_stores.len);
    try std.testing.expectEqualStrings("scratch", cfg.stores.agent_memory_stores[0].name);
    try std.testing.expectEqual(agent_memory_config.BackendKind.memory_lru, cfg.stores.agent_memory_stores[0].config.backend);
    try std.testing.expectEqual(@as(usize, 12), cfg.stores.agent_memory_stores[0].config.memory.max_entries);
    try std.testing.expectEqual(vector_runtime.BackendKind.pgvector, cfg.stores.vector_backend.backend);
    try std.testing.expectEqualStrings("postgres://user:pass@127.0.0.1:5432/nullpantry_vectors", cfg.stores.vector_backend.postgres_url.?);
    try std.testing.expectEqualStrings("np_vectors", cfg.stores.vector_backend.collection);
}

test "runtime home applies path defaults and auto-loads home config" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var config_env = try TestingEnvVar.capture(allocator, "NULLPANTRY_CONFIG");
    defer config_env.restore(allocator);
    try config_env.unset();
    var home_env = try TestingEnvVar.capture(allocator, "NULLPANTRY_HOME");
    defer home_env.restore(allocator);
    try home_env.unset();

    const home_path = try std.fmt.allocPrintSentinel(allocator, ".zig-cache/tmp/{s}/home", .{tmp.sub_path}, 0);
    try std.Io.Dir.cwd().createDirPath(compat.io(), home_path);
    const config_path = try std.fs.path.join(allocator, &.{ home_path, home_default_config_file });
    try std.Io.Dir.cwd().writeFile(compat.io(), .{
        .sub_path = config_path,
        .data =
        \\{
        \\  "server": {"host": "127.0.0.7"},
        \\  "records": {"backend": "sqlite", "db_path": "configured.db"}
        \\}
        ,
    });

    const args = [_][:0]const u8{ "nullpantry", "--home", home_path };
    const cfg = try parseArgs(allocator, &args);

    const expected_files = try std.fs.path.join(allocator, &.{ home_path, home_default_filesystem_dir });
    const expected_markdown = try std.fs.path.join(allocator, &.{ home_path, home_default_markdown_dir });
    const expected_holographic = try std.fs.path.join(allocator, &.{ home_path, home_default_holographic_db_file });
    const expected_lancedb = try std.fs.path.join(allocator, &.{ home_path, home_default_lancedb_dir });
    const expected_lucid = try std.fs.path.join(allocator, &.{ home_path, home_default_lucid_dir });

    try std.testing.expectEqualStrings("127.0.0.7", cfg.host);
    try std.testing.expectEqualStrings("configured.db", cfg.db_path);
    try std.testing.expectEqualStrings(expected_files, cfg.filesystem.root);
    try std.testing.expectEqualStrings(expected_markdown, cfg.stores.markdown_agent_memory.workspace_dir);
    try std.testing.expectEqualStrings(expected_holographic, cfg.stores.holographic_agent_memory.db_path.?);
    try std.testing.expectEqualStrings(expected_lancedb, cfg.stores.vector_backend.lancedb_uri.?);
    try std.testing.expectEqualStrings(expected_lucid, cfg.stores.lucid_projection.workspace_dir);
}

test "runtime home precedence keeps env and cli stronger" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var config_env = try TestingEnvVar.capture(allocator, "NULLPANTRY_CONFIG");
    defer config_env.restore(allocator);
    try config_env.unset();
    var home_env = try TestingEnvVar.capture(allocator, "NULLPANTRY_HOME");
    defer home_env.restore(allocator);
    var db_path_env = try TestingEnvVar.capture(allocator, "NULLPANTRY_DB_PATH");
    defer db_path_env.restore(allocator);
    var filesystem_root_env = try TestingEnvVar.capture(allocator, "NULLPANTRY_FILESYSTEM_ROOT");
    defer filesystem_root_env.restore(allocator);

    const env_home_path = try std.fmt.allocPrintSentinel(allocator, ".zig-cache/tmp/{s}/env-home", .{tmp.sub_path}, 0);
    const cli_home_path = try std.fmt.allocPrintSentinel(allocator, ".zig-cache/tmp/{s}/cli-home", .{tmp.sub_path}, 0);
    try home_env.set(env_home_path);
    try db_path_env.set("env.db");
    try filesystem_root_env.set("env-files");

    const args = [_][:0]const u8{
        "nullpantry",
        "--home",
        cli_home_path,
        "--db",
        "cli.db",
    };
    const cfg = try parseArgs(allocator, &args);
    const expected_markdown = try std.fs.path.join(allocator, &.{ cli_home_path, home_default_markdown_dir });

    try std.testing.expectEqualStrings("cli.db", cfg.db_path);
    try std.testing.expectEqualStrings("env-files", cfg.filesystem.root);
    try std.testing.expectEqualStrings(expected_markdown, cfg.stores.markdown_agent_memory.workspace_dir);
}

test "runtime home env owns defaults for explicit cleanup" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var config_env = try TestingEnvVar.capture(allocator, "NULLPANTRY_CONFIG");
    defer config_env.restore(allocator);
    try config_env.unset();
    var home_env = try TestingEnvVar.capture(allocator, "NULLPANTRY_HOME");
    defer home_env.restore(allocator);

    const home_path = try std.fmt.allocPrintSentinel(allocator, ".zig-cache/tmp/{s}/env-cleanup-home", .{tmp.sub_path}, 0);
    try home_env.set(home_path);

    const args = [_][:0]const u8{ "nullpantry", "--token", "test-token" };
    var cfg = try parseArgs(std.testing.allocator, &args);
    defer cfg.deinit(std.testing.allocator);

    const expected_db = try std.fs.path.joinZ(allocator, &.{ home_path, home_default_db_file });
    try std.testing.expectEqualStrings(expected_db, cfg.db_path);
    try std.testing.expectEqualStrings("[\"public\"]", cfg.actor.scopes_json);
}

test "runtime explicit config suppresses home config autoload" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var config_env = try TestingEnvVar.capture(allocator, "NULLPANTRY_CONFIG");
    defer config_env.restore(allocator);
    try config_env.unset();
    var home_env = try TestingEnvVar.capture(allocator, "NULLPANTRY_HOME");
    defer home_env.restore(allocator);
    try home_env.unset();

    const home_path = try std.fmt.allocPrintSentinel(allocator, ".zig-cache/tmp/{s}/config-suppressed-home", .{tmp.sub_path}, 0);
    try std.Io.Dir.cwd().createDirPath(compat.io(), home_path);
    const home_config_path = try std.fs.path.join(allocator, &.{ home_path, home_default_config_file });
    try std.Io.Dir.cwd().writeFile(compat.io(), .{
        .sub_path = home_config_path,
        .data =
        \\{
        \\  "server": {"host": "127.0.0.8"}
        \\}
        ,
    });

    const explicit_config_path = try std.fmt.allocPrintSentinel(allocator, ".zig-cache/tmp/{s}/explicit-nullpantry.json", .{tmp.sub_path}, 0);
    try std.Io.Dir.cwd().writeFile(compat.io(), .{
        .sub_path = explicit_config_path,
        .data =
        \\{
        \\  "server": {"host": "127.0.0.9"}
        \\}
        ,
    });

    const args = [_][:0]const u8{ "nullpantry", "--home", home_path, "--config", explicit_config_path };
    const cfg = try parseArgs(allocator, &args);

    try std.testing.expectEqualStrings("127.0.0.9", cfg.host);
}

test "runtime config env suppresses home config autoload" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var config_env = try TestingEnvVar.capture(allocator, "NULLPANTRY_CONFIG");
    defer config_env.restore(allocator);
    var home_env = try TestingEnvVar.capture(allocator, "NULLPANTRY_HOME");
    defer home_env.restore(allocator);
    try home_env.unset();

    const home_path = try std.fmt.allocPrintSentinel(allocator, ".zig-cache/tmp/{s}/config-env-suppressed-home", .{tmp.sub_path}, 0);
    try std.Io.Dir.cwd().createDirPath(compat.io(), home_path);
    const home_config_path = try std.fs.path.join(allocator, &.{ home_path, home_default_config_file });
    try std.Io.Dir.cwd().writeFile(compat.io(), .{
        .sub_path = home_config_path,
        .data =
        \\{
        \\  "server": {"host": "127.0.0.8"}
        \\}
        ,
    });

    const explicit_config_path = try std.fmt.allocPrintSentinel(allocator, ".zig-cache/tmp/{s}/env-nullpantry.json", .{tmp.sub_path}, 0);
    try std.Io.Dir.cwd().writeFile(compat.io(), .{
        .sub_path = explicit_config_path,
        .data =
        \\{
        \\  "server": {"host": "127.0.0.10"}
        \\}
        ,
    });
    try config_env.set(explicit_config_path);

    const args = [_][:0]const u8{ "nullpantry", "--home", home_path };
    const cfg = try parseArgs(allocator, &args);

    try std.testing.expectEqualStrings("127.0.0.10", cfg.host);
}

test "runtime home config autoload rejects group or world writable paths" {
    if (!@hasDecl(std.Io.File.Permissions, "fromMode")) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var config_env = try TestingEnvVar.capture(allocator, "NULLPANTRY_CONFIG");
    defer config_env.restore(allocator);
    try config_env.unset();
    var home_env = try TestingEnvVar.capture(allocator, "NULLPANTRY_HOME");
    defer home_env.restore(allocator);
    try home_env.unset();

    const home_path = try std.fmt.allocPrintSentinel(allocator, ".zig-cache/tmp/{s}/untrusted-home", .{tmp.sub_path}, 0);
    try std.Io.Dir.cwd().createDirPath(compat.io(), home_path);
    defer std.Io.Dir.cwd().setFilePermissions(compat.io(), home_path, .fromMode(0o700), .{}) catch {};

    const home_config_path = try std.fs.path.join(allocator, &.{ home_path, home_default_config_file });
    try std.Io.Dir.cwd().writeFile(compat.io(), .{
        .sub_path = home_config_path,
        .data =
        \\{
        \\  "server": {"host": "127.0.0.8"}
        \\}
        ,
    });
    defer std.Io.Dir.cwd().setFilePermissions(compat.io(), home_config_path, .fromMode(0o600), .{}) catch {};

    try std.Io.Dir.cwd().setFilePermissions(compat.io(), home_path, .fromMode(0o777), .{});
    const args = [_][:0]const u8{ "nullpantry", "--home", home_path };
    try std.testing.expectError(error.UntrustedRuntimeConfig, parseArgs(allocator, &args));

    try std.Io.Dir.cwd().setFilePermissions(compat.io(), home_path, .fromMode(0o700), .{});
    try std.Io.Dir.cwd().setFilePermissions(compat.io(), home_config_path, .fromMode(0o666), .{});
    try std.testing.expectError(error.UntrustedRuntimeConfig, parseArgs(allocator, &args));
}

test "runtime home config autoload rejects symlink config" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var config_env = try TestingEnvVar.capture(allocator, "NULLPANTRY_CONFIG");
    defer config_env.restore(allocator);
    try config_env.unset();
    var home_env = try TestingEnvVar.capture(allocator, "NULLPANTRY_HOME");
    defer home_env.restore(allocator);
    try home_env.unset();

    const home_path = try std.fmt.allocPrintSentinel(allocator, ".zig-cache/tmp/{s}/symlink-home", .{tmp.sub_path}, 0);
    try std.Io.Dir.cwd().createDirPath(compat.io(), home_path);
    const real_config_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/real-nullpantry.json", .{tmp.sub_path});
    try std.Io.Dir.cwd().writeFile(compat.io(), .{
        .sub_path = real_config_path,
        .data =
        \\{
        \\  "server": {"host": "127.0.0.8"}
        \\}
        ,
    });
    const home_config_path = try std.fs.path.join(allocator, &.{ home_path, home_default_config_file });
    try std.Io.Dir.cwd().symLink(compat.io(), real_config_path, home_config_path, .{});

    const args = [_][:0]const u8{ "nullpantry", "--home", home_path };
    try std.testing.expectError(error.UntrustedRuntimeConfig, parseArgs(allocator, &args));
}

test "runtime home rejects group or world writable root without config" {
    if (!@hasDecl(std.Io.File.Permissions, "fromMode")) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var config_env = try TestingEnvVar.capture(allocator, "NULLPANTRY_CONFIG");
    defer config_env.restore(allocator);
    try config_env.unset();
    var home_env = try TestingEnvVar.capture(allocator, "NULLPANTRY_HOME");
    defer home_env.restore(allocator);
    try home_env.unset();

    const home_path = try std.fmt.allocPrintSentinel(allocator, ".zig-cache/tmp/{s}/untrusted-home-no-config", .{tmp.sub_path}, 0);
    try std.Io.Dir.cwd().createDirPath(compat.io(), home_path);
    defer std.Io.Dir.cwd().setFilePermissions(compat.io(), home_path, .fromMode(0o700), .{}) catch {};
    try std.Io.Dir.cwd().setFilePermissions(compat.io(), home_path, .fromMode(0o777), .{});

    const args = [_][:0]const u8{ "nullpantry", "--home", home_path };
    try std.testing.expectError(error.UntrustedRuntimeConfig, parseArgs(allocator, &args));
}

test "runtime explicit config does not bypass untrusted home root" {
    if (!@hasDecl(std.Io.File.Permissions, "fromMode")) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var config_env = try TestingEnvVar.capture(allocator, "NULLPANTRY_CONFIG");
    defer config_env.restore(allocator);
    try config_env.unset();
    var home_env = try TestingEnvVar.capture(allocator, "NULLPANTRY_HOME");
    defer home_env.restore(allocator);
    try home_env.unset();

    const home_path = try std.fmt.allocPrintSentinel(allocator, ".zig-cache/tmp/{s}/untrusted-home-explicit-config", .{tmp.sub_path}, 0);
    try std.Io.Dir.cwd().createDirPath(compat.io(), home_path);
    defer std.Io.Dir.cwd().setFilePermissions(compat.io(), home_path, .fromMode(0o700), .{}) catch {};
    try std.Io.Dir.cwd().setFilePermissions(compat.io(), home_path, .fromMode(0o777), .{});

    const explicit_config_path = try std.fmt.allocPrintSentinel(allocator, ".zig-cache/tmp/{s}/safe-nullpantry.json", .{tmp.sub_path}, 0);
    try std.Io.Dir.cwd().writeFile(compat.io(), .{
        .sub_path = explicit_config_path,
        .data =
        \\{
        \\  "server": {"host": "127.0.0.9"}
        \\}
        ,
    });

    const args = [_][:0]const u8{ "nullpantry", "--home", home_path, "--config", explicit_config_path };
    try std.testing.expectError(error.UntrustedRuntimeConfig, parseArgs(allocator, &args));
}

test "runtime home root creation uses private permissions" {
    if (!@hasDecl(std.Io.File.Permissions, "fromMode")) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const home_path = try std.fmt.allocPrintSentinel(allocator, ".zig-cache/tmp/{s}/new-private-home", .{tmp.sub_path}, 0);
    try ensureRuntimeHomeRoot(home_path);

    const home_stat = try std.Io.Dir.cwd().statFile(compat.io(), home_path, .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o700), home_stat.permissions.toMode() & 0o777);
}

test "process environment overrides runtime config file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const config_path = try std.fmt.allocPrintSentinel(allocator, ".zig-cache/tmp/{s}/runtime-env-override.json", .{tmp.sub_path}, 0);
    try std.Io.Dir.cwd().writeFile(compat.io(), .{
        .sub_path = config_path,
        .data =
        \\{
        \\  "server": {"host": "127.0.0.2"},
        \\  "records": {"backend": "postgres", "postgres_url": "postgres://config/nullpantry"},
        \\  "vector": {
        \\    "backend": "pgvector",
        \\    "pgvector": {"url": "postgres://config/nullpantry_vectors", "table": "cfg_vectors"}
        \\  }
        \\}
        ,
    });

    var host_env = try TestingEnvVar.capture(allocator, "NULLPANTRY_HOST");
    defer host_env.restore(allocator);
    var records_backend_env = try TestingEnvVar.capture(allocator, "NULLPANTRY_RECORDS_BACKEND");
    defer records_backend_env.restore(allocator);
    var database_url_env = try TestingEnvVar.capture(allocator, "NULLPANTRY_DATABASE_URL");
    defer database_url_env.restore(allocator);
    var vector_backend_env = try TestingEnvVar.capture(allocator, "NULLPANTRY_VECTOR_BACKEND");
    defer vector_backend_env.restore(allocator);
    var pgvector_url_env = try TestingEnvVar.capture(allocator, "NULLPANTRY_PGVECTOR_URL");
    defer pgvector_url_env.restore(allocator);
    var vector_postgres_url_env = try TestingEnvVar.capture(allocator, "NULLPANTRY_VECTOR_POSTGRES_URL");
    defer vector_postgres_url_env.restore(allocator);
    var pgvector_table_env = try TestingEnvVar.capture(allocator, "NULLPANTRY_PGVECTOR_TABLE");
    defer pgvector_table_env.restore(allocator);

    try host_env.set("127.0.0.9");
    try records_backend_env.set("sqlite");
    try database_url_env.unset();
    try vector_backend_env.set("local");
    try pgvector_url_env.unset();
    try vector_postgres_url_env.unset();
    try pgvector_table_env.unset();

    const args = [_][:0]const u8{ "nullpantry", "--config", config_path };
    const cfg = try parseArgs(allocator, &args);

    try std.testing.expectEqualStrings("127.0.0.9", cfg.host);
    try std.testing.expectEqual(store_config.BackendKind.sqlite, cfg.stores.records_backend);
    try std.testing.expectEqual(vector_runtime.BackendKind.local, cfg.stores.vector_backend.backend);
}

test "runtime config env block supports exact nullpantry keys and cli override" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const config_path = try std.fmt.allocPrintSentinel(allocator, ".zig-cache/tmp/{s}/runtime-env-config.json", .{tmp.sub_path}, 0);
    try std.Io.Dir.cwd().writeFile(compat.io(), .{
        .sub_path = config_path,
        .data =
        \\{
        \\  "env": {
        \\    "NULLPANTRY_VECTOR_BACKEND": "qdrant",
        \\    "NULLPANTRY_QDRANT_URL": "http://127.0.0.1:6333",
        \\    "NULLPANTRY_QDRANT_COLLECTION": "cfg_vectors",
        \\    "NULLPANTRY_VECTOR_ALLOW_INSECURE_HTTP": true,
        \\    "NULLPANTRY_AGENT_MEMORY_BACKEND": "memory_lru",
        \\    "NULLPANTRY_MEMORY_LRU_MAX_ENTRIES": 12
        \\  }
        \\}
        ,
    });

    const args = [_][:0]const u8{
        "nullpantry",
        "--config",
        config_path,
        "--vector-backend",
        "lancedb",
        "--lancedb-uri",
        ".nullpantry/lancedb",
        "--lancedb-table",
        "cli_vectors",
    };
    const cfg = try parseArgs(allocator, &args);

    try std.testing.expectEqual(agent_memory_config.BackendKind.memory_lru, cfg.stores.agent_memory_backend);
    try std.testing.expectEqual(@as(usize, 12), cfg.stores.memory.max_entries);
    try std.testing.expect(cfg.stores.vector_backend.allow_insecure_http);
    try std.testing.expectEqual(vector_runtime.BackendKind.lancedb, cfg.stores.vector_backend.backend);
    try std.testing.expectEqualStrings(".nullpantry/lancedb", cfg.stores.vector_backend.lancedb_uri.?);
    try std.testing.expectEqualStrings("cli_vectors", cfg.stores.vector_backend.collection);
}

test "runtime config env block rejects unknown env keys" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const config_path = try std.fmt.allocPrintSentinel(allocator, ".zig-cache/tmp/{s}/invalid-runtime-config.json", .{tmp.sub_path}, 0);
    try std.Io.Dir.cwd().writeFile(compat.io(), .{
        .sub_path = config_path,
        .data =
        \\{
        \\  "env": {
        \\    "DATABASE_URL": "postgres://example"
        \\  }
        \\}
        ,
    });

    const args = [_][:0]const u8{ "nullpantry", "--config", config_path };
    try std.testing.expectError(error.InvalidRuntimeConfig, parseArgs(allocator, &args));

    const typo_path = try std.fmt.allocPrintSentinel(allocator, ".zig-cache/tmp/{s}/invalid-runtime-config-typo-env.json", .{tmp.sub_path}, 0);
    try std.Io.Dir.cwd().writeFile(compat.io(), .{
        .sub_path = typo_path,
        .data =
        \\{
        \\  "env": {
        \\    "NULLPANTRY_TOKN": "secret"
        \\  }
        \\}
        ,
    });

    const typo_args = [_][:0]const u8{ "nullpantry", "--config", typo_path };
    try std.testing.expectError(error.InvalidRuntimeConfig, parseArgs(allocator, &typo_args));
}

test "runtime config rejects unknown structured fields and non object sections" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const typo_path = try std.fmt.allocPrintSentinel(allocator, ".zig-cache/tmp/{s}/runtime-config-typo.json", .{tmp.sub_path}, 0);
    try std.Io.Dir.cwd().writeFile(compat.io(), .{
        .sub_path = typo_path,
        .data =
        \\{
        \\  "vector": {
        \\    "bakend": "pgvector"
        \\  }
        \\}
        ,
    });
    const typo_args = [_][:0]const u8{ "nullpantry", "--config", typo_path };
    try std.testing.expectError(error.InvalidRuntimeConfig, parseArgs(allocator, &typo_args));

    const wrong_type_path = try std.fmt.allocPrintSentinel(allocator, ".zig-cache/tmp/{s}/runtime-config-section-type.json", .{tmp.sub_path}, 0);
    try std.Io.Dir.cwd().writeFile(compat.io(), .{
        .sub_path = wrong_type_path,
        .data =
        \\{
        \\  "vector": "pgvector"
        \\}
        ,
    });
    const wrong_type_args = [_][:0]const u8{ "nullpantry", "--config", wrong_type_path };
    try std.testing.expectError(error.InvalidRuntimeConfig, parseArgs(allocator, &wrong_type_args));
}

test "cli config rejects unknown and missing value arguments" {
    const unknown = [_][:0]const u8{
        "nullpantry",
        "--porrt",
        "9999",
    };
    try std.testing.expectError(error.UnknownArgument, parseArgs(std.testing.allocator, &unknown));

    const missing_value = [_][:0]const u8{
        "nullpantry",
        "--port",
    };
    try std.testing.expectError(error.MissingArgumentValue, parseArgs(std.testing.allocator, &missing_value));

    const missing_config_path = [_][:0]const u8{
        "nullpantry",
        "--config",
    };
    try std.testing.expectError(error.MissingArgumentValue, parseArgs(std.testing.allocator, &missing_config_path));

    const missing_host_before_flag = [_][:0]const u8{
        "nullpantry",
        "--host",
        "--allow-no-auth-non-loopback",
    };
    try std.testing.expectError(error.MissingArgumentValue, parseArgs(std.testing.allocator, &missing_host_before_flag));

    const missing_config_before_flag = [_][:0]const u8{
        "nullpantry",
        "--config",
        "--host",
        "127.0.0.1",
    };
    try std.testing.expectError(error.MissingArgumentValue, parseArgs(std.testing.allocator, &missing_config_before_flag));

    const empty_config_path = [_][:0]const u8{
        "nullpantry",
        "--config=",
    };
    try std.testing.expectError(error.MissingArgumentValue, parseArgs(std.testing.allocator, &empty_config_path));

    const missing_home_path = [_][:0]const u8{
        "nullpantry",
        "--home",
    };
    try std.testing.expectError(error.MissingArgumentValue, parseArgs(std.testing.allocator, &missing_home_path));

    const empty_home_path = [_][:0]const u8{
        "nullpantry",
        "--home=",
    };
    try std.testing.expectError(error.MissingArgumentValue, parseArgs(std.testing.allocator, &empty_home_path));
}

fn printUsage() void {
    std.debug.print(
        \\Usage: nullpantry [--home PATH] [--config PATH] [--host HOST] [--port PORT] [--instance-id ID] [--db PATH] [--token TOKEN] [--token-principals JSON] [--allow-no-auth-non-loopback] [--filesystem-root PATH] [--actor-scopes JSON] [--actor-capabilities JSON] [--worker-scopes JSON] [--worker-capabilities JSON] [--trust-actor-headers]
        \\       nullpantry --home ~/nullhub/nullpantry
        \\       nullpantry --config nullpantry.json
        \\       nullpantry --backend postgres --postgres-url URL [--token TOKEN|--token-principals JSON]
        \\       nullpantry --backend postgres --postgres-url URL --run-legacy-compat-cleanup
        \\       nullpantry --agent-memory-backend markdown --markdown-workspace /path/to/workspace
        \\       nullpantry --agent-memory-backend redis --redis-url redis://:pass@host:6379/0
        \\       nullpantry --agent-memory-backend clickhouse --agent-memory-clickhouse-url http://127.0.0.1:8123 --agent-memory-clickhouse-table nullpantry_agent_memory
        \\       nullpantry --agent-memory-backend api --agent-memory-api-url https://pantry.internal --agent-memory-api-token TOKEN
        \\       nullpantry --agent-memory-backend zep --zep-url https://api.getzep.com/api/v2 --zep-api-key TOKEN --zep-graph-id nullpantry
        \\       nullpantry --agent-memory-backend falkordb --falkordb-url http://127.0.0.1:3000 --falkordb-api-key TOKEN --falkordb-graph nullpantry
        \\       nullpantry --agent-memory-backend retaindb --retaindb-api-key TOKEN --retaindb-project nullpantry
        \\       nullpantry --agent-memory-backend byterover --byterover-command brv --byterover-project-dir /path/to/project
        \\       nullpantry --agent-memory-backend holographic --holographic-db-path .nullpantry/holographic_memory.db
        \\       nullpantry --vector-backend pgvector --pgvector-url postgres://user:pass@127.0.0.1:5432/nullpantry --pgvector-table nullpantry_vectors
        \\       nullpantry --vector-backend qdrant --vector-base-url http://127.0.0.1:6333 --vector-collection nullpantry_vectors
        \\       nullpantry --vector-backend lancedb --lancedb-uri .nullpantry/lancedb --lancedb-table nullpantry_vectors
        \\       nullpantry --vector-backend weaviate --weaviate-url http://127.0.0.1:8080 --weaviate-collection NullPantryVector
        \\       nullpantry --vector-backend chroma --chroma-url http://127.0.0.1:8000 --chroma-tenant default_tenant --chroma-database default_database --chroma-collection nullpantry_vectors
        \\       nullpantry --vector-backend opensearch --opensearch-url http://127.0.0.1:9200 --opensearch-index nullpantry_vectors
        \\       nullpantry --graph-backend neo4j --neo4j-url http://127.0.0.1:7474 --neo4j-database neo4j
        \\       nullpantry --graph-backend falkordb --graph-falkordb-url http://127.0.0.1:3000 --graph-falkordb-name nullpantry
        \\       nullpantry --analytics-backend clickhouse --analytics-base-url http://127.0.0.1:8123 --analytics-table nullpantry_events
        \\       nullpantry --lucid-enabled --lucid-workspace /path/to/workspace
        \\
        \\Config file:
        \\  --home PATH, --home=PATH, or NULLPANTRY_HOME=PATH
        \\  Sets base dir for default local files. If no explicit config is supplied, PATH/nullpantry.json is loaded when present.
        \\  --config PATH, --config=PATH, -c PATH, or NULLPANTRY_CONFIG=PATH
        \\  Precedence: defaults < home defaults < config file < environment < CLI flags
        \\
        \\Environment:
        \\  NULLPANTRY_HOME
        \\  NULLPANTRY_CONFIG
        \\  NULLPANTRY_HOST
        \\  NULLPANTRY_PORT
        \\  NULLPANTRY_DB_PATH
        \\  NULLPANTRY_RECORDS_BACKEND
        \\  NULLPANTRY_BACKEND
        \\  NULLPANTRY_INSTANCE_ID
        \\  NULLPANTRY_FEED_INSTANCE_ID
        \\  NULLPANTRY_TOKEN
        \\  NULLPANTRY_TOKEN_PRINCIPALS
        \\  NULLPANTRY_ALLOW_NO_AUTH_NON_LOOPBACK
        \\  NULLPANTRY_FILESYSTEM_ROOT
        \\  NULLPANTRY_DATABASE_URL
        \\  NULLPANTRY_SCOPES
        \\  NULLPANTRY_CAPABILITIES
        \\  NULLPANTRY_WORKER_SCOPES
        \\  NULLPANTRY_WORKER_CAPABILITIES
        \\  NULLPANTRY_EMBEDDING_BASE_URL
        \\  NULLPANTRY_EMBEDDING_API_KEY
        \\  NULLPANTRY_EMBEDDING_MODEL
        \\  NULLPANTRY_EMBEDDING_PROVIDER
        \\  NULLPANTRY_EMBEDDING_FALLBACKS
        \\  NULLPANTRY_EMBEDDING_ROUTES
        \\  NULLPANTRY_EMBEDDING_DIMENSIONS
        \\  NULLPANTRY_EMBEDDING_ALLOW_INSECURE_HTTP
        \\  NULLPANTRY_LLM_BASE_URL
        \\  NULLPANTRY_LLM_API_KEY
        \\  NULLPANTRY_LLM_MODEL
        \\  NULLPANTRY_LLM_ALLOW_INSECURE_HTTP
        \\  NULLPANTRY_PROVIDER_ALLOW_INSECURE_HTTP
        \\  NULLPANTRY_PROVIDER_TIMEOUT_SECS
        \\  NULLPANTRY_PROVIDER_MAX_RESPONSE_BYTES
        \\  NULLPANTRY_EMBEDDING_MAX_RESPONSE_BYTES
        \\  NULLPANTRY_LLM_MAX_RESPONSE_BYTES
        \\  NULLPANTRY_WORKER_INTERVAL_MS
        \\  NULLPANTRY_TRUST_ACTOR_HEADERS
        \\  NULLPANTRY_RETRIEVAL_ROLLOUT_MODE
        \\  NULLPANTRY_RETRIEVAL_ROLLOUT_PERCENT
        \\  NULLPANTRY_RETRIEVAL_CANARY_PERCENT
        \\  NULLPANTRY_RETRIEVAL_SHADOW_PERCENT
        \\  NULLPANTRY_RETRIEVAL_ROLLOUT_SALT
        \\  NULLPANTRY_RETRIEVAL_ROLLOUT_DISABLED
        \\  NULLPANTRY_RETRIEVAL_ROLLOUT_REQUIRED_SCOPES
        \\  NULLPANTRY_RETRIEVAL_ROLLOUT_BLOCKED_SCOPES
        \\  NULLPANTRY_RETRIEVAL_ROLLOUT_REQUIRED_CAPABILITIES
        \\  NULLPANTRY_RETRIEVAL_ROLLOUT_BLOCKED_CAPABILITIES
        \\  NULLPANTRY_AGENT_MEMORY_BACKEND
        \\  NULLPANTRY_AGENT_MEMORY_MARKDOWN_WORKSPACE
        \\  NULLPANTRY_MARKDOWN_WORKSPACE
        \\  NULLPANTRY_AGENT_MEMORY_MARKDOWN_MAX_FILE_BYTES
        \\  NULLPANTRY_AGENT_MEMORY_API_URL
        \\  NULLPANTRY_AGENT_MEMORY_API_TOKEN
        \\  NULLPANTRY_AGENT_MEMORY_API_STORAGE
        \\  NULLPANTRY_AGENT_MEMORY_API_SCOPES
        \\  NULLPANTRY_AGENT_MEMORY_API_CAPABILITIES
        \\  NULLPANTRY_AGENT_MEMORY_API_TIMEOUT_SECS
        \\  NULLPANTRY_AGENT_MEMORY_API_MAX_RESPONSE_BYTES
        \\  NULLPANTRY_AGENT_MEMORY_API_ALLOW_INSECURE_HTTP
        \\  NULLPANTRY_AGENT_MEMORY_MEM0_URL
        \\  NULLPANTRY_AGENT_MEMORY_MEM0_API_KEY
        \\  NULLPANTRY_MEM0_URL
        \\  NULLPANTRY_MEM0_API_KEY
        \\  NULLPANTRY_AGENT_MEMORY_ZEP_URL
        \\  NULLPANTRY_AGENT_MEMORY_ZEP_API_KEY
        \\  NULLPANTRY_AGENT_MEMORY_ZEP_GRAPH_ID
        \\  NULLPANTRY_ZEP_URL
        \\  NULLPANTRY_ZEP_API_KEY
        \\  NULLPANTRY_ZEP_GRAPH_ID
        \\  NULLPANTRY_AGENT_MEMORY_FALKORDB_URL
        \\  NULLPANTRY_AGENT_MEMORY_FALKORDB_API_KEY
        \\  NULLPANTRY_AGENT_MEMORY_FALKORDB_GRAPH
        \\  NULLPANTRY_FALKORDB_URL
        \\  NULLPANTRY_FALKORDB_API_KEY
        \\  NULLPANTRY_FALKORDB_GRAPH
        \\  NULLPANTRY_AGENT_MEMORY_RETAINDB_URL
        \\  NULLPANTRY_AGENT_MEMORY_RETAINDB_API_KEY
        \\  NULLPANTRY_AGENT_MEMORY_RETAINDB_PROJECT
        \\  NULLPANTRY_RETAINDB_URL
        \\  NULLPANTRY_RETAINDB_API_KEY
        \\  NULLPANTRY_RETAINDB_PROJECT
        \\  NULLPANTRY_AGENT_MEMORY_BYTEROVER_COMMAND
        \\  NULLPANTRY_AGENT_MEMORY_BYTEROVER_PROJECT_DIR
        \\  NULLPANTRY_AGENT_MEMORY_BYTEROVER_USE_SWARM
        \\  NULLPANTRY_BYTEROVER_COMMAND
        \\  NULLPANTRY_BYTEROVER_PROJECT_DIR
        \\  NULLPANTRY_BYTEROVER_USE_SWARM
        \\  NULLPANTRY_AGENT_MEMORY_STORES
        \\  NULLPANTRY_MEMORY_LRU_MAX_ENTRIES
        \\  NULLPANTRY_MEMORY_LRU_MAX_MESSAGES
        \\  NULLPANTRY_MEMORY_LRU_MAX_USAGE_ENTRIES
        \\  NULLPANTRY_MEMORY_LRU_MAX_BYTES
        \\  NULLPANTRY_MEMORY_LRU_TTL_SECONDS
        \\  NULLPANTRY_REDIS_URL
        \\  NULLPANTRY_REDIS_KEY_PREFIX
        \\  NULLPANTRY_REDIS_TTL_SECONDS
        \\  NULLPANTRY_AGENT_MEMORY_CLICKHOUSE_URL
        \\  NULLPANTRY_CLICKHOUSE_AGENT_MEMORY_URL
        \\  NULLPANTRY_AGENT_MEMORY_CLICKHOUSE_API_KEY
        \\  NULLPANTRY_AGENT_MEMORY_CLICKHOUSE_TABLE
        \\  NULLPANTRY_AGENT_MEMORY_CLICKHOUSE_TIMEOUT_SECS
        \\  NULLPANTRY_AGENT_MEMORY_CLICKHOUSE_MAX_RESPONSE_BYTES
        \\  NULLPANTRY_AGENT_MEMORY_CLICKHOUSE_ALLOW_INSECURE_HTTP
        \\  NULLPANTRY_AGENT_MEMORY_HOLOGRAPHIC_DB_PATH
        \\  NULLPANTRY_HOLOGRAPHIC_DB_PATH
        \\  NULLPANTRY_HOLOGRAPHIC_DEFAULT_TRUST
        \\  NULLPANTRY_HOLOGRAPHIC_TRUST_REWARD
        \\  NULLPANTRY_HOLOGRAPHIC_TRUST_PENALTY
        \\  NULLPANTRY_VECTOR_BACKEND
        \\  NULLPANTRY_VECTOR_BASE_URL
        \\  NULLPANTRY_VECTOR_API_KEY
        \\  NULLPANTRY_VECTOR_COLLECTION
        \\  NULLPANTRY_VECTOR_POSTGRES_URL
        \\  NULLPANTRY_VECTOR_TIMEOUT_SECS
        \\  NULLPANTRY_VECTOR_ALLOW_INSECURE_HTTP
        \\  NULLPANTRY_VECTOR_CIRCUIT_BREAKER_ENABLED
        \\  NULLPANTRY_VECTOR_CIRCUIT_BREAKER_THRESHOLD
        \\  NULLPANTRY_VECTOR_CIRCUIT_BREAKER_COOLDOWN_MS
        \\  NULLPANTRY_QDRANT_URL
        \\  NULLPANTRY_QDRANT_API_KEY
        \\  NULLPANTRY_QDRANT_COLLECTION
        \\  NULLPANTRY_QDRANT_ALLOW_INSECURE_HTTP
        \\  NULLPANTRY_PGVECTOR_URL
        \\  NULLPANTRY_PGVECTOR_TABLE
        \\  NULLPANTRY_LANCEDB_URI
        \\  NULLPANTRY_LANCEDB_COMMAND
        \\  NULLPANTRY_LANCEDB_URL
        \\  NULLPANTRY_LANCEDB_API_KEY
        \\  NULLPANTRY_LANCEDB_TABLE
        \\  NULLPANTRY_LANCEDB_ALLOW_INSECURE_HTTP
        \\  NULLPANTRY_WEAVIATE_URL
        \\  NULLPANTRY_WEAVIATE_API_KEY
        \\  NULLPANTRY_WEAVIATE_COLLECTION
        \\  NULLPANTRY_CHROMA_URL
        \\  NULLPANTRY_CHROMA_TOKEN
        \\  NULLPANTRY_CHROMA_TENANT
        \\  NULLPANTRY_CHROMA_DATABASE
        \\  NULLPANTRY_CHROMA_COLLECTION
        \\  NULLPANTRY_CHROMA_COLLECTION_ID
        \\  NULLPANTRY_OPENSEARCH_URL
        \\  NULLPANTRY_OPENSEARCH_API_KEY
        \\  NULLPANTRY_OPENSEARCH_INDEX
        \\  NULLPANTRY_GRAPH_BACKEND
        \\  NULLPANTRY_GRAPH_BASE_URL
        \\  NULLPANTRY_GRAPH_API_KEY
        \\  NULLPANTRY_GRAPH_DATABASE
        \\  NULLPANTRY_GRAPH_NAME
        \\  NULLPANTRY_GRAPH_TIMEOUT_SECS
        \\  NULLPANTRY_GRAPH_ALLOW_INSECURE_HTTP
        \\  NULLPANTRY_GRAPH_PROJECT_SCOPES
        \\  NULLPANTRY_NEO4J_URL
        \\  NULLPANTRY_NEO4J_API_KEY
        \\  NULLPANTRY_NEO4J_DATABASE
        \\  NULLPANTRY_GRAPH_FALKORDB_URL
        \\  NULLPANTRY_GRAPH_FALKORDB_API_KEY
        \\  NULLPANTRY_GRAPH_FALKORDB_NAME
        \\  NULLPANTRY_ANALYTICS_BACKEND
        \\  NULLPANTRY_ANALYTICS_BASE_URL
        \\  NULLPANTRY_ANALYTICS_API_KEY
        \\  NULLPANTRY_ANALYTICS_TABLE
        \\  NULLPANTRY_ANALYTICS_TIMEOUT_SECS
        \\  NULLPANTRY_ANALYTICS_ALLOW_INSECURE_HTTP
        \\  NULLPANTRY_CLICKHOUSE_URL
        \\  NULLPANTRY_CLICKHOUSE_API_KEY
        \\  NULLPANTRY_CLICKHOUSE_TABLE
        \\  NULLPANTRY_CLICKHOUSE_ALLOW_INSECURE_HTTP
        \\  NULLPANTRY_LUCID_ENABLED
        \\  NULLPANTRY_LUCID_COMMAND
        \\  NULLPANTRY_LUCID_WORKSPACE
        \\  NULLPANTRY_LUCID_TOKEN_BUDGET
        \\  NULLPANTRY_LUCID_LOCAL_HIT_THRESHOLD
        \\  NULLPANTRY_LUCID_PROJECT_SCOPES
        \\  NULLPANTRY_LUCID_RESULT_SCOPE
        \\  NULLPANTRY_LUCID_PERMISSIONS
        \\
    , .{});
}

fn ensureParentDirForFile(path: []const u8) !void {
    if (path.len == 0 or std.mem.eql(u8, path, ":memory:")) return;
    const parent = std.fs.path.dirname(path) orelse return;
    if (parent.len == 0) return;
    if (std.Io.Dir.cwd().statFile(compat.io(), parent, .{})) |stat| {
        if (stat.kind == .directory) return;
        return error.NotDir;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    try std.Io.Dir.cwd().createDirPath(compat.io(), parent);
}

test "worker interval duration is bounded before sleeping" {
    try std.testing.expectEqual(@as(i96, 5 * std.time.ns_per_s), workerIntervalDuration(5_000).nanoseconds);
    try std.testing.expectEqual(std.Io.Duration.zero.nanoseconds, workerIntervalDuration(0).nanoseconds);
    try std.testing.expectEqual(std.Io.Duration.fromMilliseconds(std.math.maxInt(i64)).nanoseconds, workerIntervalDuration(std.math.maxInt(u64)).nanoseconds);
}

test "token auth does not downgrade background worker principal" {
    const args = [_][:0]const u8{ "nullpantry", "--token", "test-token" };
    var cfg = try parseArgs(std.testing.allocator, &args);
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("[\"public\"]", cfg.actor.scopes_json);
    try std.testing.expectEqualStrings("[\"read\"]", cfg.actor.capabilities_json);
    try std.testing.expectEqualStrings("[\"admin\"]", cfg.worker.scopes_json);
    try std.testing.expect(std.mem.indexOf(u8, cfg.worker.capabilities_json, "\"write\"") != null);
}

test "worker principal can be narrowed explicitly" {
    const args = [_][:0]const u8{
        "nullpantry",
        "--worker-scopes",
        "[\"project:nullpantry\"]",
        "--worker-capabilities",
        "[\"read\",\"write\",\"verify\"]",
    };
    var cfg = try parseArgs(std.testing.allocator, &args);
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("[\"project:nullpantry\"]", cfg.worker.scopes_json);
    try std.testing.expectEqualStrings("[\"read\",\"write\",\"verify\"]", cfg.worker.capabilities_json);
}

test "actor and worker principal config fail closed" {
    try std.testing.expectError(error.InvalidPrincipalConfig, validateCompiledEngineProfile(std.testing.allocator, .{ .actor = .{ .scopes_json = "[\"public\",]" } }));
    try std.testing.expectError(error.InvalidPrincipalConfig, validateCompiledEngineProfile(std.testing.allocator, .{ .actor = .{ .capabilities_json = "[1]" } }));
    try std.testing.expectError(error.InvalidPrincipalConfig, validateCompiledEngineProfile(std.testing.allocator, .{ .worker = .{ .actor_id = " " } }));
    try std.testing.expectError(error.InvalidPrincipalConfig, validateCompiledEngineProfile(std.testing.allocator, .{ .worker = .{ .capabilities_json = "[\"read\",\"\"]" } }));

    const args = [_][:0]const u8{
        "nullpantry",
        "--actor-scopes",
        "[\"public\",]",
    };
    var cfg = try parseArgs(std.testing.allocator, &args);
    defer cfg.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidPrincipalConfig, validateCompiledEngineProfile(std.testing.allocator, cfg));
}

test "no-auth bind is limited to loopback unless explicitly allowed" {
    try validateNoAuthBindSafety(.{});
    try validateNoAuthBindSafety(.{ .host = "localhost" });
    try std.testing.expectError(error.InsecureNoAuthBind, validateNoAuthBindSafety(.{ .host = "0.0.0.0" }));
    try std.testing.expectError(error.InsecureNoAuthBind, validateNoAuthBindSafety(.{ .host = "::" }));
    try validateNoAuthBindSafety(.{ .host = "0.0.0.0", .auth = .{ .required_token = "secret" } });
    try validateNoAuthBindSafety(.{ .host = "0.0.0.0", .auth = .{ .token_principals_json = "{}" } });
    try validateNoAuthBindSafety(.{ .host = "0.0.0.0", .auth = .{ .allow_no_auth_non_loopback = true } });
}

test "blank auth and filesystem root config fail closed" {
    try std.testing.expectError(error.InvalidAuthToken, validateAuthConfig(std.testing.allocator, .{ .required_token = "" }));
    try std.testing.expectError(error.InvalidAuthToken, validateAuthConfig(std.testing.allocator, .{ .required_token = " \t\r\n" }));
    try std.testing.expectError(error.InvalidPrincipalRegistry, validateAuthConfig(std.testing.allocator, .{ .token_principals_json = " \n" }));
    try std.testing.expectError(error.InvalidPrincipalRegistry, validateAuthConfig(std.testing.allocator, .{ .token_principals_json = "[]" }));
    try std.testing.expectError(error.InvalidPrincipalRegistry, validateAuthConfig(std.testing.allocator, .{ .token_principals_json = "{\"agent-a\":{\"scopes\":[1]}}" }));
    try std.testing.expectError(error.InvalidFilesystemRoot, validateFilesystemConfig(.{ .root = "" }));
    try std.testing.expectError(error.InvalidFilesystemRoot, validateFilesystemConfig(.{ .root = " \t" }));
    try std.testing.expectError(error.InsecureNoAuthBind, validateNoAuthBindSafety(.{ .host = "0.0.0.0", .auth = .{ .required_token = "" } }));
    try std.testing.expectError(error.InsecureNoAuthBind, validateNoAuthBindSafety(.{ .host = "0.0.0.0", .auth = .{ .token_principals_json = " \n" } }));
}

test "no-auth non-loopback override is explicit cli config" {
    const args = [_][:0]const u8{
        "nullpantry",
        "--host",
        "0.0.0.0",
        "--allow-no-auth-non-loopback",
    };
    var cfg = try parseArgs(std.testing.allocator, &args);
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expect(cfg.auth.allow_no_auth_non_loopback);
    try validateNoAuthBindSafety(cfg);
}

test "filesystem root can be configured explicitly" {
    const args = [_][:0]const u8{ "nullpantry", "--filesystem-root", ".zig-cache/nullpantry-files" };
    var cfg = try parseArgs(std.testing.allocator, &args);
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(".zig-cache/nullpantry-files", cfg.filesystem.root);
    try validateFilesystemConfig(cfg.filesystem);
}

test "instance id can be configured for feed origin identity" {
    const args = [_][:0]const u8{ "nullpantry", "--instance-id", "pantry-test-a" };
    var cfg = try parseArgs(std.testing.allocator, &args);
    defer cfg.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("pantry-test-a", cfg.instance_id);
}

test "provider insecure http opt-in is explicit for embeddings fallbacks and llm" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const args = [_][:0]const u8{
        "nullpantry",
        "--embedding-base-url",
        "http://provider.internal/v1",
        "--embedding-model",
        "embed-model",
        "--embedding-allow-insecure-http",
        "--provider-max-response-bytes",
        "12000000",
        "--embedding-max-response-bytes",
        "3400000",
        "--embedding-fallbacks",
        "[{\"provider\":\"ollama\",\"base_url\":\"http://ollama.internal:11434\",\"model\":\"nomic\",\"allow_insecure_http\":true,\"max_response_bytes\":5600000}]",
        "--llm-base-url",
        "http://llm.internal/v1",
        "--llm-model",
        "chat-model",
        "--llm-max-response-bytes",
        "7800000",
        "--llm-allow-insecure-http",
    };
    const cfg = try parseArgs(allocator, &args);
    const embedding = embeddingConfigFromRuntime(cfg);
    const completion = completionConfigFromRuntime(cfg);

    try std.testing.expect(embedding.allow_insecure_http);
    try std.testing.expectEqual(@as(usize, 3_400_000), embedding.max_response_bytes);
    try std.testing.expectEqual(@as(usize, 1), embedding.fallbacks.len);
    try std.testing.expect(embedding.fallbacks[0].allow_insecure_http);
    try std.testing.expectEqual(@as(usize, 5_600_000), embedding.fallbacks[0].max_response_bytes);
    try std.testing.expect(completion.allow_insecure_http);
    try std.testing.expectEqual(@as(usize, 7_800_000), completion.max_response_bytes);
}

test "json config integer fields reject unsafe floats instead of trapping" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"exact\":12.0,\"fractional\":12.5,\"huge\":1e100,\"integer\":4}",
        .{},
    );
    defer parsed.deinit();

    try std.testing.expectEqual(@as(?i64, 12), jsonIntField(parsed.value.object, "exact"));
    try std.testing.expectEqual(@as(?i64, 4), jsonIntField(parsed.value.object, "integer"));
    try std.testing.expect(jsonIntField(parsed.value.object, "fractional") == null);
    try std.testing.expect(jsonIntField(parsed.value.object, "huge") == null);
}

test "provider runtime selection requires usable configuration" {
    try validateProviderRuntimeConfigured(.{});
    try std.testing.expectError(error.InvalidProviderCircuitConfig, validateProviderRuntimeConfigured(.{
        .provider = .{ .circuit_failure_threshold = 0 },
    }));
    try std.testing.expectError(error.InvalidProviderCircuitConfig, validateProviderRuntimeConfigured(.{
        .provider = .{ .circuit_cooldown_ms = 0 },
    }));
    try validateProviderRuntimeConfigured(.{
        .provider = .{ .embedding = .{ .provider = .ollama } },
    });
    try std.testing.expectError(error.MissingEmbeddingProviderUrl, validateProviderRuntimeConfigured(.{
        .provider = .{ .embedding = .{ .base_url = " ", .model = "embed-model" } },
    }));
    try std.testing.expectError(error.MissingEmbeddingProviderModel, validateProviderRuntimeConfigured(.{
        .provider = .{ .embedding = .{ .base_url = "https://provider.example/v1", .model = " " } },
    }));
    try std.testing.expectError(error.MissingEmbeddingProviderApiKey, validateProviderRuntimeConfigured(.{
        .provider = .{ .embedding = .{ .provider = .gemini } },
    }));
    try std.testing.expectError(error.MissingCompletionProviderUrl, validateProviderRuntimeConfigured(.{
        .provider = .{ .completion = .{ .base_url = " ", .model = "chat-model" } },
    }));
    try std.testing.expectError(error.MissingCompletionProviderModel, validateProviderRuntimeConfigured(.{
        .provider = .{ .completion = .{ .base_url = "https://llm.example/v1", .model = " " } },
    }));
    try validateProviderRuntimeConfigured(.{
        .provider = .{
            .embedding = .{ .base_url = "https://provider.example/v1", .model = "embed-model" },
            .completion = .{ .base_url = "https://llm.example/v1", .model = "chat-model" },
        },
    });
}

test "embedding routes are parsed from cli config" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const args = [_][:0]const u8{
        "nullpantry",
        "--embedding-model",
        "hint:semantic",
        "--provider-max-response-bytes",
        "2000000",
        "--embedding-routes",
        "{\"semantic\":{\"provider\":\"local-deterministic\",\"dimensions\":7,\"max_response_bytes\":1234}}",
    };
    const cfg = try parseArgs(allocator, &args);
    const embedding = embeddingConfigFromRuntime(cfg);

    try std.testing.expectEqualStrings("hint:semantic", embedding.model.?);
    try std.testing.expectEqual(@as(usize, 1), embedding.routes.len);
    try std.testing.expectEqualStrings("semantic", embedding.routes[0].hint);
    try std.testing.expectEqual(providers.EmbeddingProviderKind.local_deterministic, embedding.routes[0].endpoint.provider);
    try std.testing.expectEqual(@as(usize, 7), embedding.routes[0].endpoint.dimensions);
    try std.testing.expectEqual(@as(usize, 1234), embedding.routes[0].endpoint.max_response_bytes);
}

test "embedding fallback and route inheritance is independent of cli flag order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const args = [_][:0]const u8{
        "nullpantry",
        "--embedding-fallbacks",
        "ollama",
        "--embedding-routes",
        "{\"semantic\":{\"provider\":\"local-deterministic\"}}",
        "--embedding-model",
        "hint:semantic",
        "--embedding-dimensions",
        "77",
        "--no-embedding-send-dimensions",
        "--provider-timeout-secs",
        "12",
        "--embedding-max-response-bytes",
        "2222",
        "--embedding-allow-insecure-http",
    };
    const cfg = try parseArgs(allocator, &args);
    const embedding = embeddingConfigFromRuntime(cfg);

    try std.testing.expectEqual(@as(usize, 1), embedding.fallbacks.len);
    try std.testing.expectEqual(providers.EmbeddingProviderKind.ollama, embedding.fallbacks[0].provider);
    try std.testing.expectEqualStrings("hint:semantic", embedding.fallbacks[0].model.?);
    try std.testing.expectEqual(@as(usize, 77), embedding.fallbacks[0].dimensions);
    try std.testing.expect(!embedding.fallbacks[0].send_dimensions);
    try std.testing.expectEqual(@as(u32, 12), embedding.fallbacks[0].timeout_secs);
    try std.testing.expectEqual(@as(usize, 2222), embedding.fallbacks[0].max_response_bytes);
    try std.testing.expect(embedding.fallbacks[0].allow_insecure_http);

    try std.testing.expectEqual(@as(usize, 1), embedding.routes.len);
    try std.testing.expectEqualStrings("semantic", embedding.routes[0].hint);
    try std.testing.expectEqual(providers.EmbeddingProviderKind.local_deterministic, embedding.routes[0].endpoint.provider);
    try std.testing.expectEqualStrings("hint:semantic", embedding.routes[0].endpoint.model.?);
    try std.testing.expectEqual(@as(usize, 77), embedding.routes[0].endpoint.dimensions);
    try std.testing.expect(!embedding.routes[0].endpoint.send_dimensions);
    try std.testing.expectEqual(@as(u32, 12), embedding.routes[0].endpoint.timeout_secs);
    try std.testing.expectEqual(@as(usize, 2222), embedding.routes[0].endpoint.max_response_bytes);
    try std.testing.expect(embedding.routes[0].endpoint.allow_insecure_http);
}

test "embedding dimension override is explicit and can be disabled" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const args = [_][:0]const u8{
        "nullpantry",
        "--embedding-dimensions",
        "768",
        "--no-embedding-send-dimensions",
    };
    const cfg = try parseArgs(allocator, &args);
    const embedding = embeddingConfigFromRuntime(cfg);
    try std.testing.expectEqual(@as(usize, 768), embedding.dimensions);
    try std.testing.expect(!embedding.send_dimensions);
}

test "embedding dimension override is capped at provider limit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const args = [_][:0]const u8{
        "nullpantry",
        "--embedding-dimensions",
        "999999",
    };
    const cfg = try parseArgs(allocator, &args);
    const embedding = embeddingConfigFromRuntime(cfg);
    try std.testing.expectEqual(vector_mod.max_embedding_dimensions, embedding.dimensions);
    try std.testing.expect(embedding.send_dimensions);
}

test "agent memory redis backend can be configured from args" {
    const args = [_][:0]const u8{
        "nullpantry",
        "--agent-memory-backend",
        "redis",
        "--redis-url",
        "redis://127.0.0.1:6379/2",
        "--redis-key-prefix",
        "np-test",
        "--redis-ttl-seconds",
        "60",
    };
    var cfg = try parseArgs(std.testing.allocator, &args);
    defer cfg.deinit(std.testing.allocator);
    defer std.testing.allocator.free(cfg.stores.redis.host);

    try std.testing.expectEqual(agent_memory_config.BackendKind.redis, cfg.stores.agent_memory_backend);
    try std.testing.expectEqualStrings("127.0.0.1", cfg.stores.redis.host);
    try std.testing.expectEqual(@as(u8, 2), cfg.stores.redis.db_index);
    try std.testing.expectEqualStrings("np-test", cfg.stores.redis.key_prefix);
    try std.testing.expectEqual(@as(u32, 60), cfg.stores.redis.ttl_seconds.?);
}

test "agent memory memory_lru backend can be bounded from args" {
    const args = [_][:0]const u8{
        "nullpantry",
        "--agent-memory-backend",
        "memory_lru",
        "--memory-lru-max-entries",
        "64",
        "--memory-lru-max-messages",
        "128",
        "--memory-lru-max-usage-entries",
        "16",
        "--memory-lru-max-bytes",
        "4096",
        "--memory-lru-ttl-seconds",
        "300",
    };
    var cfg = try parseArgs(std.testing.allocator, &args);
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqual(agent_memory_config.BackendKind.memory_lru, cfg.stores.agent_memory_backend);
    try std.testing.expectEqual(@as(usize, 64), cfg.stores.memory.max_entries);
    try std.testing.expectEqual(@as(usize, 128), cfg.stores.memory.max_messages);
    try std.testing.expectEqual(@as(usize, 16), cfg.stores.memory.max_usage_entries);
    try std.testing.expectEqual(@as(usize, 4096), cfg.stores.memory.max_bytes);
    try std.testing.expectEqual(@as(u32, 300), cfg.stores.memory.ttl_seconds.?);
}

test "agent memory markdown backend can be configured from args and named stores" {
    const args = [_][:0]const u8{
        "nullpantry",
        "--agent-memory-backend",
        "markdown",
        "--markdown-workspace",
        "/work/nullclaw",
        "--agent-memory-markdown-max-file-bytes",
        "65536",
    };
    var cfg = try parseArgs(std.testing.allocator, &args);
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqual(agent_memory_config.BackendKind.markdown, cfg.stores.agent_memory_backend);
    try std.testing.expectEqualStrings("/work/nullclaw", cfg.stores.markdown_agent_memory.workspace_dir);
    try std.testing.expectEqual(@as(usize, 65536), cfg.stores.markdown_agent_memory.max_file_bytes);

    const parsed = try parseAgentMemoryStoreConfigsJson(std.testing.allocator,
        \\[
        \\  {"name":"notes","backend":"markdown","workspace":"/work/notes","max_file_bytes":32768}
        \\]
    );
    defer freeParsedNamedAgentMemoryConfigs(std.testing.allocator, parsed);

    try std.testing.expectEqual(@as(usize, 1), parsed.len);
    try std.testing.expectEqualStrings("notes", parsed[0].name);
    try std.testing.expectEqual(agent_memory_config.BackendKind.markdown, parsed[0].config.backend);
    try std.testing.expectEqualStrings("/work/notes", parsed[0].config.markdown.workspace_dir);
    try std.testing.expectEqual(@as(usize, 32768), parsed[0].config.markdown.max_file_bytes);

    const scheme = try parseAgentMemoryStoreSpec(std.testing.allocator, "claw=markdown:///work/nullclaw");
    defer {
        var mutable = scheme;
        freeParsedNamedAgentMemoryConfig(std.testing.allocator, &mutable);
    }
    try std.testing.expectEqualStrings("claw", scheme.name);
    try std.testing.expectEqual(agent_memory_config.BackendKind.markdown, scheme.config.backend);
    try std.testing.expectEqualStrings("/work/nullclaw", scheme.config.markdown.workspace_dir);
}

test "agent memory markdown file byte limits clamp from args" {
    const args = [_][:0]const u8{
        "nullpantry",
        "--agent-memory-backend",
        "markdown",
        "--markdown-workspace",
        "/work/nullclaw",
        "--agent-memory-markdown-max-file-bytes",
        "9223372036854775807",
    };
    var cfg = try parseArgs(std.testing.allocator, &args);
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqual(agent_memory_config.BackendKind.markdown, cfg.stores.agent_memory_backend);
    try std.testing.expectEqual(agent_memory_config.max_markdown_file_bytes, cfg.stores.markdown_agent_memory.max_file_bytes);
    try validateRuntimeAgentMemoryBackendConfigured(cfg);
}

test "agent memory backend selection requires usable configuration" {
    try validateRuntimeAgentMemoryBackendConfigured(.{});
    try validateRuntimeAgentMemoryBackendConfigured(.{ .stores = .{ .agent_memory_backend = .none } });
    try validateRuntimeAgentMemoryBackendConfigured(.{ .stores = .{ .agent_memory_backend = .markdown } });
    try validateRuntimeAgentMemoryBackendConfigured(.{ .stores = .{ .agent_memory_backend = .memory_lru } });
    try validateRuntimeAgentMemoryBackendConfigured(.{ .stores = .{ .agent_memory_backend = .redis } });
    try validateRuntimeAgentMemoryBackendConfigured(.{ .stores = .{ .agent_memory_backend = .holographic } });
    try validateRuntimeAgentMemoryBackendConfigured(.{ .stores = .{ .agent_memory_backend = .byterover, .api_agent_memory = .{ .profile = .byterover } } });

    try std.testing.expectError(error.MissingApiBackendUrl, validateRuntimeAgentMemoryBackendConfigured(.{ .stores = .{ .agent_memory_backend = .api } }));
    try std.testing.expectError(error.MissingApiBackendUrl, validateRuntimeAgentMemoryBackendConfigured(.{
        .stores = .{ .agent_memory_backend = .api, .api_agent_memory = .{ .base_url = " \t\r\n" } },
    }));
    try validateRuntimeAgentMemoryBackendConfigured(.{
        .stores = .{ .agent_memory_backend = .api, .api_agent_memory = .{ .base_url = "https://pantry.example/v1" } },
    });

    try std.testing.expectError(error.MissingClickHouseAgentMemoryUrl, validateRuntimeAgentMemoryBackendConfigured(.{ .stores = .{ .agent_memory_backend = .clickhouse } }));
    try std.testing.expectError(error.InvalidAgentMemoryBackend, validateRuntimeAgentMemoryBackendConfigured(.{
        .stores = .{ .agent_memory_backend = .clickhouse, .clickhouse_agent_memory = .{ .base_url = "https://clickhouse.example", .table = " \t" } },
    }));
    try validateRuntimeAgentMemoryBackendConfigured(.{
        .stores = .{ .agent_memory_backend = .clickhouse, .clickhouse_agent_memory = .{ .base_url = "https://clickhouse.example", .table = "nullpantry_agent_memory" } },
    });

    try validateRuntimeAgentMemoryBackendConfigured(.{ .stores = .{ .agent_memory_backend = .supermemory } });
    try std.testing.expectError(error.MissingApiBackendUrl, validateRuntimeAgentMemoryBackendConfigured(.{
        .stores = .{ .agent_memory_backend = .supermemory, .api_agent_memory = .{ .profile = .supermemory, .base_url = " " } },
    }));
    try std.testing.expectError(error.MissingByteRoverCommand, validateRuntimeAgentMemoryBackendConfigured(.{
        .stores = .{ .agent_memory_backend = .byterover, .api_agent_memory = .{ .profile = .byterover, .byterover_command = " " } },
    }));

    try std.testing.expectError(error.MissingApiBackendUrl, (agent_memory_config.Config{ .backend = .api }).validateUsable());
    try (agent_memory_config.Config{ .backend = .api, .api = .{ .base_url = "https://pantry.example/v1" } }).validateUsable();
}

test "agent memory api backend can be configured from args" {
    const args = [_][:0]const u8{
        "nullpantry",
        "--agent-memory-backend",
        "api",
        "--agent-memory-api-url",
        "https://pantry.example/v1",
        "--agent-memory-api-token",
        "gateway-token",
        "--agent-memory-api-storage",
        "team:alpha",
        "--agent-memory-api-scopes",
        "[\"project:nullpantry\"]",
        "--agent-memory-api-capabilities",
        "[\"read\",\"write\"]",
        "--agent-memory-api-timeout-secs",
        "9",
        "--agent-memory-api-max-response-bytes",
        "123456",
        "--agent-memory-api-allow-insecure-http",
    };
    var cfg = try parseArgs(std.testing.allocator, &args);
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqual(agent_memory_config.BackendKind.api, cfg.stores.agent_memory_backend);
    try std.testing.expectEqualStrings("https://pantry.example/v1", cfg.stores.api_agent_memory.base_url.?);
    try std.testing.expectEqualStrings("gateway-token", cfg.stores.api_agent_memory.token.?);
    try std.testing.expectEqualStrings("team:alpha", cfg.stores.api_agent_memory.remote_storage.?);
    try std.testing.expectEqualStrings("[\"project:nullpantry\"]", cfg.stores.api_agent_memory.actor_scopes_json);
    try std.testing.expectEqualStrings("[\"read\",\"write\"]", cfg.stores.api_agent_memory.actor_capabilities_json);
    try std.testing.expectEqual(@as(u32, 9), cfg.stores.api_agent_memory.timeout_secs);
    try std.testing.expectEqual(@as(usize, 123456), cfg.stores.api_agent_memory.max_response_bytes);
    try std.testing.expect(cfg.stores.api_agent_memory.allow_insecure_http);
}

test "agent memory supermemory backend can be configured from args and named stores" {
    const args = [_][:0]const u8{
        "nullpantry",
        "--agent-memory-backend",
        "supermemory",
        "--supermemory-url",
        "https://api.supermemory.ai",
        "--supermemory-api-key",
        "sm-token",
        "--agent-memory-api-timeout-secs",
        "7",
    };
    var cfg = try parseArgs(std.testing.allocator, &args);
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqual(agent_memory_config.BackendKind.supermemory, cfg.stores.agent_memory_backend);
    try std.testing.expectEqual(agent_memory_config.ApiProfile.supermemory, cfg.stores.api_agent_memory.profile);
    try std.testing.expectEqualStrings("https://api.supermemory.ai", cfg.stores.api_agent_memory.base_url.?);
    try std.testing.expectEqualStrings("sm-token", cfg.stores.api_agent_memory.token.?);
    try std.testing.expectEqual(@as(u32, 7), cfg.stores.api_agent_memory.timeout_secs);

    const parsed = try parseAgentMemoryStoreConfigsJson(std.testing.allocator,
        \\[
        \\  {"name":"vendor","backend":"supermemory","supermemory_api_key":"store-token","supermemory_url":"https://api.supermemory.ai"}
        \\]
    );
    defer freeParsedNamedAgentMemoryConfigs(std.testing.allocator, parsed);

    try std.testing.expectEqual(@as(usize, 1), parsed.len);
    try std.testing.expectEqualStrings("vendor", parsed[0].name);
    try std.testing.expectEqual(agent_memory_config.BackendKind.supermemory, parsed[0].config.backend);
    try std.testing.expectEqual(agent_memory_config.ApiProfile.supermemory, parsed[0].config.api.profile);
    try std.testing.expectEqualStrings("store-token", parsed[0].config.api.token.?);
    try std.testing.expectEqualStrings("https://api.supermemory.ai", parsed[0].config.api.base_url.?);
}

test "agent memory openviking backend can be configured from args and named stores" {
    const args = [_][:0]const u8{
        "nullpantry",
        "--agent-memory-backend",
        "openviking",
        "--openviking-url",
        "http://localhost:1933",
        "--openviking-api-key",
        "ov-token",
        "--agent-memory-api-timeout-secs",
        "9",
        "--agent-memory-api-allow-insecure-http",
    };
    var cfg = try parseArgs(std.testing.allocator, &args);
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqual(agent_memory_config.BackendKind.openviking, cfg.stores.agent_memory_backend);
    try std.testing.expectEqual(agent_memory_config.ApiProfile.openviking, cfg.stores.api_agent_memory.profile);
    try std.testing.expectEqualStrings("http://localhost:1933", cfg.stores.api_agent_memory.base_url.?);
    try std.testing.expectEqualStrings("ov-token", cfg.stores.api_agent_memory.token.?);
    try std.testing.expectEqual(@as(u32, 9), cfg.stores.api_agent_memory.timeout_secs);
    try std.testing.expect(cfg.stores.api_agent_memory.allow_insecure_http);

    const parsed = try parseAgentMemoryStoreConfigsJson(std.testing.allocator,
        \\[
        \\  {"name":"viking","backend":"openviking","openviking_api_key":"store-token","openviking_url":"http://localhost:1933","api_allow_insecure_http":true}
        \\]
    );
    defer freeParsedNamedAgentMemoryConfigs(std.testing.allocator, parsed);

    try std.testing.expectEqual(@as(usize, 1), parsed.len);
    try std.testing.expectEqualStrings("viking", parsed[0].name);
    try std.testing.expectEqual(agent_memory_config.BackendKind.openviking, parsed[0].config.backend);
    try std.testing.expectEqual(agent_memory_config.ApiProfile.openviking, parsed[0].config.api.profile);
    try std.testing.expectEqualStrings("store-token", parsed[0].config.api.token.?);
    try std.testing.expectEqualStrings("http://localhost:1933", parsed[0].config.api.base_url.?);
    try std.testing.expect(parsed[0].config.api.allow_insecure_http);

    const scheme_parsed = try parseAgentMemoryStoreConfigsJson(std.testing.allocator,
        \\[
        \\  {"name":"local-viking","url":"openviking://scheme-token"}
        \\]
    );
    defer freeParsedNamedAgentMemoryConfigs(std.testing.allocator, scheme_parsed);
    try std.testing.expectEqual(@as(usize, 1), scheme_parsed.len);
    try std.testing.expectEqual(agent_memory_config.BackendKind.openviking, scheme_parsed[0].config.backend);
    try std.testing.expectEqual(agent_memory_config.ApiProfile.openviking, scheme_parsed[0].config.api.profile);
    try std.testing.expectEqualStrings("scheme-token", scheme_parsed[0].config.api.token.?);
}

test "agent memory honcho backend can be configured from args and named stores" {
    const args = [_][:0]const u8{
        "nullpantry",
        "--agent-memory-backend",
        "honcho",
        "--honcho-url",
        "https://api.honcho.dev/v3",
        "--honcho-api-key",
        "honcho-token",
        "--honcho-workspace-id",
        "nullpantry-test",
        "--agent-memory-api-timeout-secs",
        "11",
    };
    var cfg = try parseArgs(std.testing.allocator, &args);
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqual(agent_memory_config.BackendKind.honcho, cfg.stores.agent_memory_backend);
    try std.testing.expectEqual(agent_memory_config.ApiProfile.honcho, cfg.stores.api_agent_memory.profile);
    try std.testing.expectEqualStrings("https://api.honcho.dev/v3", cfg.stores.api_agent_memory.base_url.?);
    try std.testing.expectEqualStrings("honcho-token", cfg.stores.api_agent_memory.token.?);
    try std.testing.expectEqualStrings("nullpantry-test", cfg.stores.api_agent_memory.workspace_id.?);
    try std.testing.expectEqual(@as(u32, 11), cfg.stores.api_agent_memory.timeout_secs);

    const parsed = try parseAgentMemoryStoreConfigsJson(std.testing.allocator,
        \\[
        \\  {"name":"honcho-team","backend":"honcho","honcho_api_key":"store-token","honcho_url":"https://api.honcho.dev/v3","honcho_workspace_id":"team-memory"}
        \\]
    );
    defer freeParsedNamedAgentMemoryConfigs(std.testing.allocator, parsed);

    try std.testing.expectEqual(@as(usize, 1), parsed.len);
    try std.testing.expectEqualStrings("honcho-team", parsed[0].name);
    try std.testing.expectEqual(agent_memory_config.BackendKind.honcho, parsed[0].config.backend);
    try std.testing.expectEqual(agent_memory_config.ApiProfile.honcho, parsed[0].config.api.profile);
    try std.testing.expectEqualStrings("store-token", parsed[0].config.api.token.?);
    try std.testing.expectEqualStrings("https://api.honcho.dev/v3", parsed[0].config.api.base_url.?);
    try std.testing.expectEqualStrings("team-memory", parsed[0].config.api.workspace_id.?);

    const scheme_parsed = try parseAgentMemoryStoreConfigsJson(std.testing.allocator,
        \\[
        \\  {"name":"honcho-scheme","url":"honcho://scheme-token","honcho_workspace_id":"scheme-workspace"}
        \\]
    );
    defer freeParsedNamedAgentMemoryConfigs(std.testing.allocator, scheme_parsed);
    try std.testing.expectEqual(@as(usize, 1), scheme_parsed.len);
    try std.testing.expectEqual(agent_memory_config.BackendKind.honcho, scheme_parsed[0].config.backend);
    try std.testing.expectEqual(agent_memory_config.ApiProfile.honcho, scheme_parsed[0].config.api.profile);
    try std.testing.expectEqualStrings("scheme-token", scheme_parsed[0].config.api.token.?);
    try std.testing.expectEqualStrings("scheme-workspace", scheme_parsed[0].config.api.workspace_id.?);
}

test "agent memory mem0 backend can be configured from args and named stores" {
    const args = [_][:0]const u8{
        "nullpantry",
        "--agent-memory-backend",
        "mem0",
        "--mem0-url",
        "https://api.mem0.ai",
        "--mem0-api-key",
        "mem0-token",
        "--agent-memory-api-timeout-secs",
        "13",
    };
    var cfg = try parseArgs(std.testing.allocator, &args);
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqual(agent_memory_config.BackendKind.mem0, cfg.stores.agent_memory_backend);
    try std.testing.expectEqual(agent_memory_config.ApiProfile.mem0, cfg.stores.api_agent_memory.profile);
    try std.testing.expectEqualStrings("https://api.mem0.ai", cfg.stores.api_agent_memory.base_url.?);
    try std.testing.expectEqualStrings("mem0-token", cfg.stores.api_agent_memory.token.?);
    try std.testing.expectEqual(@as(u32, 13), cfg.stores.api_agent_memory.timeout_secs);

    const parsed = try parseAgentMemoryStoreConfigsJson(std.testing.allocator,
        \\[
        \\  {"name":"mem0-team","backend":"mem0","mem0_api_key":"store-token","mem0_url":"https://api.mem0.ai"}
        \\]
    );
    defer freeParsedNamedAgentMemoryConfigs(std.testing.allocator, parsed);

    try std.testing.expectEqual(@as(usize, 1), parsed.len);
    try std.testing.expectEqualStrings("mem0-team", parsed[0].name);
    try std.testing.expectEqual(agent_memory_config.BackendKind.mem0, parsed[0].config.backend);
    try std.testing.expectEqual(agent_memory_config.ApiProfile.mem0, parsed[0].config.api.profile);
    try std.testing.expectEqualStrings("store-token", parsed[0].config.api.token.?);
    try std.testing.expectEqualStrings("https://api.mem0.ai", parsed[0].config.api.base_url.?);

    const scheme_parsed = try parseAgentMemoryStoreConfigsJson(std.testing.allocator,
        \\[
        \\  {"name":"mem0-scheme","url":"mem0://scheme-token"}
        \\]
    );
    defer freeParsedNamedAgentMemoryConfigs(std.testing.allocator, scheme_parsed);
    try std.testing.expectEqual(@as(usize, 1), scheme_parsed.len);
    try std.testing.expectEqual(agent_memory_config.BackendKind.mem0, scheme_parsed[0].config.backend);
    try std.testing.expectEqual(agent_memory_config.ApiProfile.mem0, scheme_parsed[0].config.api.profile);
    try std.testing.expectEqualStrings("scheme-token", scheme_parsed[0].config.api.token.?);
    try std.testing.expectEqualStrings("https://api.mem0.ai", scheme_parsed[0].config.api.base_url.?);
}

test "agent memory hindsight backend can be configured from args and named stores" {
    const args = [_][:0]const u8{
        "nullpantry",
        "--agent-memory-backend",
        "hindsight",
        "--hindsight-url",
        "https://api.hindsight.vectorize.io",
        "--hindsight-api-key",
        "hindsight-token",
        "--hindsight-bank-id",
        "team-bank",
        "--agent-memory-api-timeout-secs",
        "17",
    };
    var cfg = try parseArgs(std.testing.allocator, &args);
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqual(agent_memory_config.BackendKind.hindsight, cfg.stores.agent_memory_backend);
    try std.testing.expectEqual(agent_memory_config.ApiProfile.hindsight, cfg.stores.api_agent_memory.profile);
    try std.testing.expectEqualStrings("https://api.hindsight.vectorize.io", cfg.stores.api_agent_memory.base_url.?);
    try std.testing.expectEqualStrings("hindsight-token", cfg.stores.api_agent_memory.token.?);
    try std.testing.expectEqualStrings("team-bank", cfg.stores.api_agent_memory.workspace_id.?);
    try std.testing.expectEqual(@as(u32, 17), cfg.stores.api_agent_memory.timeout_secs);

    const parsed = try parseAgentMemoryStoreConfigsJson(std.testing.allocator,
        \\[
        \\  {"name":"hindsight-team","backend":"hindsight","hindsight_api_key":"store-token","hindsight_url":"https://api.hindsight.vectorize.io","hindsight_bank_id":"team-memory"}
        \\]
    );
    defer freeParsedNamedAgentMemoryConfigs(std.testing.allocator, parsed);

    try std.testing.expectEqual(@as(usize, 1), parsed.len);
    try std.testing.expectEqualStrings("hindsight-team", parsed[0].name);
    try std.testing.expectEqual(agent_memory_config.BackendKind.hindsight, parsed[0].config.backend);
    try std.testing.expectEqual(agent_memory_config.ApiProfile.hindsight, parsed[0].config.api.profile);
    try std.testing.expectEqualStrings("store-token", parsed[0].config.api.token.?);
    try std.testing.expectEqualStrings("https://api.hindsight.vectorize.io", parsed[0].config.api.base_url.?);
    try std.testing.expectEqualStrings("team-memory", parsed[0].config.api.workspace_id.?);

    const scheme_parsed = try parseAgentMemoryStoreConfigsJson(std.testing.allocator,
        \\[
        \\  {"name":"hindsight-scheme","url":"hindsight://scheme-token","hindsight_bank_id":"scheme-bank"}
        \\]
    );
    defer freeParsedNamedAgentMemoryConfigs(std.testing.allocator, scheme_parsed);
    try std.testing.expectEqual(@as(usize, 1), scheme_parsed.len);
    try std.testing.expectEqual(agent_memory_config.BackendKind.hindsight, scheme_parsed[0].config.backend);
    try std.testing.expectEqual(agent_memory_config.ApiProfile.hindsight, scheme_parsed[0].config.api.profile);
    try std.testing.expectEqualStrings("scheme-token", scheme_parsed[0].config.api.token.?);
    try std.testing.expectEqualStrings("scheme-bank", scheme_parsed[0].config.api.workspace_id.?);
    try std.testing.expectEqualStrings("https://api.hindsight.vectorize.io", scheme_parsed[0].config.api.base_url.?);
}

test "agent memory retaindb backend can be configured from args and named stores" {
    const args = [_][:0]const u8{
        "nullpantry",
        "--agent-memory-backend",
        "retaindb",
        "--retaindb-url",
        "https://api.retaindb.com",
        "--retaindb-api-key",
        "retaindb-token",
        "--retaindb-project",
        "team-project",
        "--agent-memory-api-timeout-secs",
        "19",
    };
    var cfg = try parseArgs(std.testing.allocator, &args);
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqual(agent_memory_config.BackendKind.retaindb, cfg.stores.agent_memory_backend);
    try std.testing.expectEqual(agent_memory_config.ApiProfile.retaindb, cfg.stores.api_agent_memory.profile);
    try std.testing.expectEqualStrings("https://api.retaindb.com", cfg.stores.api_agent_memory.base_url.?);
    try std.testing.expectEqualStrings("retaindb-token", cfg.stores.api_agent_memory.token.?);
    try std.testing.expectEqualStrings("team-project", cfg.stores.api_agent_memory.workspace_id.?);
    try std.testing.expectEqual(@as(u32, 19), cfg.stores.api_agent_memory.timeout_secs);

    const parsed = try parseAgentMemoryStoreConfigsJson(std.testing.allocator,
        \\[
        \\  {"name":"retaindb-team","backend":"retaindb","retaindb_api_key":"store-token","retaindb_url":"https://api.retaindb.com","retaindb_project":"team-memory"}
        \\]
    );
    defer freeParsedNamedAgentMemoryConfigs(std.testing.allocator, parsed);

    try std.testing.expectEqual(@as(usize, 1), parsed.len);
    try std.testing.expectEqualStrings("retaindb-team", parsed[0].name);
    try std.testing.expectEqual(agent_memory_config.BackendKind.retaindb, parsed[0].config.backend);
    try std.testing.expectEqual(agent_memory_config.ApiProfile.retaindb, parsed[0].config.api.profile);
    try std.testing.expectEqualStrings("store-token", parsed[0].config.api.token.?);
    try std.testing.expectEqualStrings("https://api.retaindb.com", parsed[0].config.api.base_url.?);
    try std.testing.expectEqualStrings("team-memory", parsed[0].config.api.workspace_id.?);

    const scheme_parsed = try parseAgentMemoryStoreConfigsJson(std.testing.allocator,
        \\[
        \\  {"name":"retaindb-scheme","url":"retaindb://scheme-token","retaindb_project":"scheme-project"}
        \\]
    );
    defer freeParsedNamedAgentMemoryConfigs(std.testing.allocator, scheme_parsed);
    try std.testing.expectEqual(@as(usize, 1), scheme_parsed.len);
    try std.testing.expectEqual(agent_memory_config.BackendKind.retaindb, scheme_parsed[0].config.backend);
    try std.testing.expectEqual(agent_memory_config.ApiProfile.retaindb, scheme_parsed[0].config.api.profile);
    try std.testing.expectEqualStrings("scheme-token", scheme_parsed[0].config.api.token.?);
    try std.testing.expectEqualStrings("scheme-project", scheme_parsed[0].config.api.workspace_id.?);
    try std.testing.expectEqualStrings("https://api.retaindb.com", scheme_parsed[0].config.api.base_url.?);
}

test "agent memory byterover backend can be configured from args and named stores" {
    const args = [_][:0]const u8{
        "nullpantry",
        "--agent-memory-backend",
        "byterover",
        "--byterover-command",
        "brv-test",
        "--byterover-project-dir",
        "/tmp/nullpantry-project",
        "--byterover-use-swarm",
        "--agent-memory-api-timeout-secs",
        "23",
        "--agent-memory-api-max-response-bytes",
        "131072",
    };
    var cfg = try parseArgs(std.testing.allocator, &args);
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqual(agent_memory_config.BackendKind.byterover, cfg.stores.agent_memory_backend);
    try std.testing.expectEqual(agent_memory_config.ApiProfile.byterover, cfg.stores.api_agent_memory.profile);
    try std.testing.expectEqualStrings("brv-test", cfg.stores.api_agent_memory.byterover_command);
    try std.testing.expectEqualStrings("/tmp/nullpantry-project", cfg.stores.api_agent_memory.byterover_project_dir.?);
    try std.testing.expect(cfg.stores.api_agent_memory.byterover_use_swarm);
    try std.testing.expectEqual(@as(u32, 23), cfg.stores.api_agent_memory.timeout_secs);
    try std.testing.expectEqual(@as(usize, 131072), cfg.stores.api_agent_memory.max_response_bytes);

    const parsed = try parseAgentMemoryStoreConfigsJson(std.testing.allocator,
        \\[
        \\  {"name":"byterover-team","backend":"byterover","byterover_command":"brv-store","byterover_project_dir":"/work/team","byterover_use_swarm":true}
        \\]
    );
    defer freeParsedNamedAgentMemoryConfigs(std.testing.allocator, parsed);

    try std.testing.expectEqual(@as(usize, 1), parsed.len);
    try std.testing.expectEqualStrings("byterover-team", parsed[0].name);
    try std.testing.expectEqual(agent_memory_config.BackendKind.byterover, parsed[0].config.backend);
    try std.testing.expectEqual(agent_memory_config.ApiProfile.byterover, parsed[0].config.api.profile);
    try std.testing.expectEqualStrings("brv-store", parsed[0].config.api.byterover_command);
    try std.testing.expectEqualStrings("/work/team", parsed[0].config.api.byterover_project_dir.?);
    try std.testing.expect(parsed[0].config.api.byterover_use_swarm);

    const scheme = try parseAgentMemoryStoreSpec(std.testing.allocator, "team-brv=byterover:///work/project");
    defer {
        var mutable = scheme;
        freeParsedNamedAgentMemoryConfig(std.testing.allocator, &mutable);
    }
    try std.testing.expectEqualStrings("team-brv", scheme.name);
    try std.testing.expectEqual(agent_memory_config.BackendKind.byterover, scheme.config.backend);
    try std.testing.expectEqual(agent_memory_config.ApiProfile.byterover, scheme.config.api.profile);
    try std.testing.expectEqualStrings("/work/project", scheme.config.api.byterover_project_dir.?);
}

test "agent memory holographic backend can be configured from args and named stores" {
    const args = [_][:0]const u8{
        "nullpantry",
        "--agent-memory-backend",
        "holographic",
        "--holographic-db-path",
        ".nullpantry/holographic-test.db",
        "--holographic-default-trust",
        "0.7",
        "--holographic-trust-reward",
        "0.2",
        "--holographic-trust-penalty",
        "0.3",
    };
    var cfg = try parseArgs(std.testing.allocator, &args);
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqual(agent_memory_config.BackendKind.holographic, cfg.stores.agent_memory_backend);
    try std.testing.expectEqualStrings(".nullpantry/holographic-test.db", cfg.stores.holographic_agent_memory.db_path.?);
    try std.testing.expectEqual(@as(f64, 0.7), cfg.stores.holographic_agent_memory.default_trust);
    try std.testing.expectEqual(@as(f64, 0.2), cfg.stores.holographic_agent_memory.trust_reward);
    try std.testing.expectEqual(@as(f64, 0.3), cfg.stores.holographic_agent_memory.trust_penalty);

    const parsed = try parseAgentMemoryStoreConfigsJson(std.testing.allocator,
        \\[
        \\  {"name":"local-holographic","backend":"holographic","holographic_db_path":".nullpantry/team-holographic.db"}
        \\]
    );
    defer freeParsedNamedAgentMemoryConfigs(std.testing.allocator, parsed);

    try std.testing.expectEqual(@as(usize, 1), parsed.len);
    try std.testing.expectEqualStrings("local-holographic", parsed[0].name);
    try std.testing.expectEqual(agent_memory_config.BackendKind.holographic, parsed[0].config.backend);
    try std.testing.expectEqualStrings(".nullpantry/team-holographic.db", parsed[0].config.holographic.db_path.?);

    const scheme = try parseAgentMemoryStoreSpec(std.testing.allocator, "assoc=holographic://.nullpantry/assoc.db");
    defer {
        var mutable = scheme;
        freeParsedNamedAgentMemoryConfig(std.testing.allocator, &mutable);
    }
    try std.testing.expectEqualStrings("assoc", scheme.name);
    try std.testing.expectEqual(agent_memory_config.BackendKind.holographic, scheme.config.backend);
    try std.testing.expectEqualStrings(".nullpantry/assoc.db", scheme.config.holographic.db_path.?);
}

test "agent memory zep and falkordb backends can be configured from args and named stores" {
    const zep_args = [_][:0]const u8{
        "nullpantry",
        "--agent-memory-backend",
        "zep",
        "--zep-url",
        "https://zep.example/api/v2",
        "--zep-api-key",
        "zep-token",
        "--zep-graph-id",
        "nullpantry-team",
    };
    var zep_cfg = try parseArgs(std.testing.allocator, &zep_args);
    defer zep_cfg.deinit(std.testing.allocator);

    try std.testing.expectEqual(agent_memory_config.BackendKind.zep, zep_cfg.stores.agent_memory_backend);
    try std.testing.expectEqual(agent_memory_config.ApiProfile.zep, zep_cfg.stores.api_agent_memory.profile);
    try std.testing.expectEqualStrings("https://zep.example/api/v2", zep_cfg.stores.api_agent_memory.base_url.?);
    try std.testing.expectEqualStrings("zep-token", zep_cfg.stores.api_agent_memory.token.?);
    try std.testing.expectEqualStrings("nullpantry-team", zep_cfg.stores.api_agent_memory.workspace_id.?);

    const falkor_args = [_][:0]const u8{
        "nullpantry",
        "--agent-memory-backend",
        "falkordb",
        "--falkordb-url",
        "http://127.0.0.1:3000",
        "--falkordb-api-key",
        "falkor-token",
        "--falkordb-graph",
        "agent_memory",
    };
    var falkor_cfg = try parseArgs(std.testing.allocator, &falkor_args);
    defer falkor_cfg.deinit(std.testing.allocator);

    try std.testing.expectEqual(agent_memory_config.BackendKind.falkordb, falkor_cfg.stores.agent_memory_backend);
    try std.testing.expectEqual(agent_memory_config.ApiProfile.falkordb, falkor_cfg.stores.api_agent_memory.profile);
    try std.testing.expectEqualStrings("http://127.0.0.1:3000", falkor_cfg.stores.api_agent_memory.base_url.?);
    try std.testing.expectEqualStrings("falkor-token", falkor_cfg.stores.api_agent_memory.token.?);
    try std.testing.expectEqualStrings("agent_memory", falkor_cfg.stores.api_agent_memory.workspace_id.?);

    const named_cfg = try parseAgentMemoryStoreConfigsJson(std.testing.allocator,
        \\[
        \\  {"name":"team-zep","backend":"zep","zep_url":"https://zep.example/api/v2","zep_api_key":"z","zep_graph_id":"team"},
        \\  {"name":"team-falkor","backend":"falkordb","falkordb_url":"http://127.0.0.1:3000","falkordb_token":"f","falkordb_graph":"mem"}
        \\]
    );
    defer freeParsedNamedAgentMemoryConfigs(std.testing.allocator, named_cfg);

    try std.testing.expectEqual(@as(usize, 2), named_cfg.len);
    try std.testing.expectEqualStrings("team-zep", named_cfg[0].name);
    try std.testing.expectEqual(agent_memory_config.BackendKind.zep, named_cfg[0].config.backend);
    try std.testing.expectEqual(agent_memory_config.ApiProfile.zep, named_cfg[0].config.api.profile);
    try std.testing.expectEqualStrings("https://zep.example/api/v2", named_cfg[0].config.api.base_url.?);
    try std.testing.expectEqualStrings("z", named_cfg[0].config.api.token.?);
    try std.testing.expectEqualStrings("team", named_cfg[0].config.api.workspace_id.?);
    try std.testing.expectEqualStrings("team-falkor", named_cfg[1].name);
    try std.testing.expectEqual(agent_memory_config.BackendKind.falkordb, named_cfg[1].config.backend);
    try std.testing.expectEqual(agent_memory_config.ApiProfile.falkordb, named_cfg[1].config.api.profile);
    try std.testing.expectEqualStrings("http://127.0.0.1:3000", named_cfg[1].config.api.base_url.?);
    try std.testing.expectEqualStrings("f", named_cfg[1].config.api.token.?);
    try std.testing.expectEqualStrings("mem", named_cfg[1].config.api.workspace_id.?);

    const zep_scheme = try parseAgentMemoryStoreSpec(std.testing.allocator, "remote-zep=zep://scheme-token");
    defer {
        var mutable = zep_scheme;
        freeParsedNamedAgentMemoryConfig(std.testing.allocator, &mutable);
    }
    try std.testing.expectEqualStrings("remote-zep", zep_scheme.name);
    try std.testing.expectEqual(agent_memory_config.BackendKind.zep, zep_scheme.config.backend);
    try std.testing.expectEqual(agent_memory_config.ApiProfile.zep, zep_scheme.config.api.profile);
    try std.testing.expectEqualStrings("https://api.getzep.com/api/v2", zep_scheme.config.api.base_url.?);
    try std.testing.expectEqualStrings("scheme-token", zep_scheme.config.api.token.?);

    const falkor_scheme = try parseAgentMemoryStoreSpec(std.testing.allocator, "remote-falkor=falkordb://project_graph");
    defer {
        var mutable = falkor_scheme;
        freeParsedNamedAgentMemoryConfig(std.testing.allocator, &mutable);
    }
    try std.testing.expectEqualStrings("remote-falkor", falkor_scheme.name);
    try std.testing.expectEqual(agent_memory_config.BackendKind.falkordb, falkor_scheme.config.backend);
    try std.testing.expectEqual(agent_memory_config.ApiProfile.falkordb, falkor_scheme.config.api.profile);
    try std.testing.expectEqualStrings("http://localhost:3000", falkor_scheme.config.api.base_url.?);
    try std.testing.expectEqualStrings("project_graph", falkor_scheme.config.api.workspace_id.?);
}

test "agent memory clickhouse backend can be configured from args" {
    const args = [_][:0]const u8{
        "nullpantry",
        "--agent-memory-backend",
        "clickhouse",
        "--agent-memory-clickhouse-url",
        "http://127.0.0.1:8123",
        "--agent-memory-clickhouse-api-key",
        "ch-token",
        "--agent-memory-clickhouse-table",
        "np.agent_memory",
        "--agent-memory-clickhouse-timeout-secs",
        "12",
        "--agent-memory-clickhouse-max-response-bytes",
        "654321",
        "--agent-memory-clickhouse-allow-insecure-http",
    };
    var cfg = try parseArgs(std.testing.allocator, &args);
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqual(agent_memory_config.BackendKind.clickhouse, cfg.stores.agent_memory_backend);
    try std.testing.expectEqualStrings("http://127.0.0.1:8123", cfg.stores.clickhouse_agent_memory.base_url.?);
    try std.testing.expectEqualStrings("ch-token", cfg.stores.clickhouse_agent_memory.api_key.?);
    try std.testing.expectEqualStrings("np.agent_memory", cfg.stores.clickhouse_agent_memory.table);
    try std.testing.expectEqual(@as(u32, 12), cfg.stores.clickhouse_agent_memory.timeout_secs);
    try std.testing.expectEqual(@as(usize, 654321), cfg.stores.clickhouse_agent_memory.max_response_bytes);
    try std.testing.expect(cfg.stores.clickhouse_agent_memory.allow_insecure_http);
}

test "named agent memory stores can be configured from args and json" {
    const args = [_][:0]const u8{
        "nullpantry",
        "--agent-memory-store",
        "scratch=memory_lru",
        "--agent-memory-store",
        "shared=redis://127.0.0.1:6379/4",
        "--agent-memory-store",
        "remote=https://pantry.example",
        "--agent-memory-store",
        "mem0=mem0://mem0-token",
    };
    var cfg = try parseArgs(std.testing.allocator, &args);
    defer cfg.deinit(std.testing.allocator);
    defer freeParsedNamedAgentMemoryConfigs(std.testing.allocator, @constCast(cfg.stores.agent_memory_stores));

    try std.testing.expectEqual(@as(usize, 4), cfg.stores.agent_memory_stores.len);
    try std.testing.expectEqualStrings("scratch", cfg.stores.agent_memory_stores[0].name);
    try std.testing.expectEqual(agent_memory_config.BackendKind.memory_lru, cfg.stores.agent_memory_stores[0].config.backend);
    try std.testing.expectEqualStrings("shared", cfg.stores.agent_memory_stores[1].name);
    try std.testing.expectEqual(agent_memory_config.BackendKind.redis, cfg.stores.agent_memory_stores[1].config.backend);
    try std.testing.expectEqual(@as(u8, 4), cfg.stores.agent_memory_stores[1].config.redis.db_index);
    try std.testing.expectEqualStrings("remote", cfg.stores.agent_memory_stores[2].name);
    try std.testing.expectEqual(agent_memory_config.BackendKind.api, cfg.stores.agent_memory_stores[2].config.backend);
    try std.testing.expectEqualStrings("https://pantry.example", cfg.stores.agent_memory_stores[2].config.api.base_url.?);
    try std.testing.expectEqualStrings("mem0", cfg.stores.agent_memory_stores[3].name);
    try std.testing.expectEqual(agent_memory_config.BackendKind.mem0, cfg.stores.agent_memory_stores[3].config.backend);
    try std.testing.expectEqualStrings("mem0-token", cfg.stores.agent_memory_stores[3].config.api.token.?);

    const parsed = try parseAgentMemoryStoreConfigsJson(std.testing.allocator,
        \\[
        \\  {"name":"fast","backend":"memory_lru","max_entries":32,"max_messages":64,"max_usage_entries":8,"max_bytes":2048,"ttl_seconds":120},
        \\  {"name":"team","redis_url":"redis://127.0.0.1:6379/5","key_prefix":"team-memory","ttl_seconds":30},
        \\  {"name":"remote","api_url":"https://pantry.example/v1","api_token":"gateway","api_storage":"archive,team","api_timeout_secs":11,"api_max_response_bytes":65536,"api_allow_insecure_http":true},
        \\  {"name":"warehouse","backend":"clickhouse","clickhouse_url":"http://127.0.0.1:8123","clickhouse_table":"np.agent_runtime","clickhouse_api_key":"ch","clickhouse_timeout_secs":13,"clickhouse_max_response_bytes":131072,"clickhouse_allow_insecure_http":true}
        \\]
    );
    defer freeParsedNamedAgentMemoryConfigs(std.testing.allocator, parsed);

    try std.testing.expectEqual(@as(usize, 4), parsed.len);
    try std.testing.expectEqualStrings("fast", parsed[0].name);
    try std.testing.expectEqual(agent_memory_config.BackendKind.memory_lru, parsed[0].config.backend);
    try std.testing.expectEqual(@as(usize, 32), parsed[0].config.memory.max_entries);
    try std.testing.expectEqual(@as(usize, 64), parsed[0].config.memory.max_messages);
    try std.testing.expectEqual(@as(usize, 8), parsed[0].config.memory.max_usage_entries);
    try std.testing.expectEqual(@as(usize, 2048), parsed[0].config.memory.max_bytes);
    try std.testing.expectEqual(@as(u32, 120), parsed[0].config.memory.ttl_seconds.?);
    try std.testing.expectEqualStrings("team", parsed[1].name);
    try std.testing.expectEqual(agent_memory_config.BackendKind.redis, parsed[1].config.backend);
    try std.testing.expectEqualStrings("team-memory", parsed[1].config.redis.key_prefix);
    try std.testing.expectEqual(@as(u32, 30), parsed[1].config.redis.ttl_seconds.?);
    try std.testing.expectEqualStrings("remote", parsed[2].name);
    try std.testing.expectEqual(agent_memory_config.BackendKind.api, parsed[2].config.backend);
    try std.testing.expectEqualStrings("https://pantry.example/v1", parsed[2].config.api.base_url.?);
    try std.testing.expect(parsed[2].config.api.allow_insecure_http);
    try std.testing.expectEqualStrings("gateway", parsed[2].config.api.token.?);
    try std.testing.expectEqualStrings("archive,team", parsed[2].config.api.remote_storage.?);
    try std.testing.expectEqual(@as(u32, 11), parsed[2].config.api.timeout_secs);
    try std.testing.expectEqual(@as(usize, 65536), parsed[2].config.api.max_response_bytes);
    try std.testing.expectEqualStrings("warehouse", parsed[3].name);
    try std.testing.expectEqual(agent_memory_config.BackendKind.clickhouse, parsed[3].config.backend);
    try std.testing.expectEqualStrings("http://127.0.0.1:8123", parsed[3].config.clickhouse.base_url.?);
    try std.testing.expectEqualStrings("np.agent_runtime", parsed[3].config.clickhouse.table);
    try std.testing.expectEqualStrings("ch", parsed[3].config.clickhouse.api_key.?);
    try std.testing.expectEqual(@as(u32, 13), parsed[3].config.clickhouse.timeout_secs);
    try std.testing.expectEqual(@as(usize, 131072), parsed[3].config.clickhouse.max_response_bytes);
    try std.testing.expect(parsed[3].config.clickhouse.allow_insecure_http);

    try std.testing.expectError(error.InvalidAgentMemoryStore, parseAgentMemoryStoreSpec(std.testing.allocator, "bad=native"));
    try std.testing.expectError(error.InvalidAgentMemoryStore, parseAgentMemoryStoreSpec(std.testing.allocator, "bad=typo"));
    try std.testing.expectError(error.InvalidAgentMemoryStore, parseAgentMemoryStoreSpec(std.testing.allocator, "bad,name=memory_lru"));
    try std.testing.expectError(error.InvalidAgentMemoryStore, parseAgentMemoryStoreSpec(std.testing.allocator, "bad store=memory_lru"));
    try std.testing.expectError(error.InvalidRedisUrl, parseAgentMemoryStoreSpec(std.testing.allocator, "bad=redis://127.0.0.1:not-a-port"));
    try std.testing.expectError(error.InvalidAgentMemoryStores, parseAgentMemoryStoreConfigsJson(std.testing.allocator,
        \\[
        \\  {"name":"bad,name","backend":"memory_lru"}
        \\]
    ));
    try std.testing.expectError(error.InvalidAgentMemoryStores, parseAgentMemoryStoreConfigsJson(std.testing.allocator,
        \\[
        \\  {"name":"team","redis_url":"redis://:secret@127.0.0.1:6379/5","key_prefix":"team-memory"},
        \\  {"name":"bad store","api_url":"https://pantry.example/v1","api_token":"gateway"}
        \\]
    ));
}

test "named agent memory store json numeric limits saturate instead of trapping" {
    const parsed = try parseAgentMemoryStoreConfigsJson(std.testing.allocator,
        \\[
        \\  {"name":"fast","backend":"memory_lru","max_entries":9223372036854775807,"max_messages":9223372036854775807,"max_usage_entries":9223372036854775807,"max_bytes":9223372036854775807,"ttl_seconds":9223372036854775807},
        \\  {"name":"disabled","backend":"memory_lru","max_entries":-1,"max_messages":-1,"max_usage_entries":-1,"max_bytes":-1,"ttl_seconds":-1},
        \\  {"name":"remote","api_url":"https://pantry.example/v1","api_timeout_secs":9223372036854775807,"api_max_response_bytes":9223372036854775807},
        \\  {"name":"warehouse","backend":"clickhouse","clickhouse_url":"http://127.0.0.1:8123","clickhouse_timeout_secs":9223372036854775807,"clickhouse_max_response_bytes":9223372036854775807},
        \\  {"name":"notes","backend":"markdown","workspace":"/work/notes","max_file_bytes":9223372036854775807},
        \\  {"name":"cache","redis_url":"redis://127.0.0.1:6379/0","ttl_seconds":9223372036854775807}
        \\]
    );
    defer freeParsedNamedAgentMemoryConfigs(std.testing.allocator, parsed);

    const max_usize = bounded_int.nonNegativeI64ToUsize(std.math.maxInt(i64));
    try std.testing.expectEqual(@as(usize, 6), parsed.len);
    try std.testing.expectEqual(max_usize, parsed[0].config.memory.max_entries);
    try std.testing.expectEqual(max_usize, parsed[0].config.memory.max_messages);
    try std.testing.expectEqual(max_usize, parsed[0].config.memory.max_usage_entries);
    try std.testing.expectEqual(max_usize, parsed[0].config.memory.max_bytes);
    try std.testing.expectEqual(std.math.maxInt(u32), parsed[0].config.memory.ttl_seconds.?);
    try std.testing.expectEqual(@as(usize, 0), parsed[1].config.memory.max_entries);
    try std.testing.expectEqual(@as(usize, 0), parsed[1].config.memory.max_messages);
    try std.testing.expectEqual(@as(usize, 0), parsed[1].config.memory.max_usage_entries);
    try std.testing.expectEqual(@as(usize, 0), parsed[1].config.memory.max_bytes);
    try std.testing.expectEqual(@as(u32, 0), parsed[1].config.memory.ttl_seconds.?);
    try std.testing.expectEqual(agent_memory_config.max_remote_timeout_secs, parsed[2].config.api.timeout_secs);
    try std.testing.expectEqual(agent_memory_config.max_remote_response_bytes, parsed[2].config.api.max_response_bytes);
    try std.testing.expectEqual(agent_memory_config.max_remote_timeout_secs, parsed[3].config.clickhouse.timeout_secs);
    try std.testing.expectEqual(agent_memory_config.max_remote_response_bytes, parsed[3].config.clickhouse.max_response_bytes);
    try std.testing.expectEqual(agent_memory_config.max_markdown_file_bytes, parsed[4].config.markdown.max_file_bytes);
    try std.testing.expectEqual(std.math.maxInt(u32), parsed[5].config.redis.ttl_seconds.?);
}

test "agent memory remote runtime limits clamp from args" {
    const api_args = [_][:0]const u8{
        "nullpantry",
        "--agent-memory-backend",
        "api",
        "--agent-memory-api-url",
        "https://pantry.example/v1",
        "--agent-memory-api-timeout-secs",
        "0",
        "--agent-memory-api-max-response-bytes",
        "9223372036854775807",
    };
    var api_cfg = try parseArgs(std.testing.allocator, &api_args);
    defer api_cfg.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 1), api_cfg.stores.api_agent_memory.timeout_secs);
    try std.testing.expectEqual(agent_memory_config.max_remote_response_bytes, api_cfg.stores.api_agent_memory.max_response_bytes);

    const clickhouse_args = [_][:0]const u8{
        "nullpantry",
        "--agent-memory-backend",
        "clickhouse",
        "--agent-memory-clickhouse-url",
        "https://clickhouse.example",
        "--agent-memory-clickhouse-timeout-secs",
        "9223372036854775807",
        "--agent-memory-clickhouse-max-response-bytes",
        "0",
    };
    var clickhouse_cfg = try parseArgs(std.testing.allocator, &clickhouse_args);
    defer clickhouse_cfg.deinit(std.testing.allocator);
    try std.testing.expectEqual(agent_memory_config.max_remote_timeout_secs, clickhouse_cfg.stores.clickhouse_agent_memory.timeout_secs);
    try std.testing.expectEqual(@as(usize, 1), clickhouse_cfg.stores.clickhouse_agent_memory.max_response_bytes);
}

test "external vector index can be configured from args" {
    const args = [_][:0]const u8{
        "nullpantry",
        "--vector-backend",
        "qdrant",
        "--vector-base-url",
        "http://127.0.0.1:6333",
        "--vector-collection",
        "np_vectors",
        "--vector-timeout-secs",
        "7",
        "--vector-sqlite-ann-candidate-multiplier",
        "9",
        "--vector-sqlite-ann-min-candidates",
        "77",
        "--vector-allow-insecure-http",
        "--vector-circuit-breaker-threshold",
        "5",
        "--vector-circuit-breaker-cooldown-ms",
        "12000",
    };
    var cfg = try parseArgs(std.testing.allocator, &args);
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqual(vector_runtime.BackendKind.qdrant, cfg.stores.vector_backend.backend);
    try std.testing.expectEqualStrings("http://127.0.0.1:6333", cfg.stores.vector_backend.base_url.?);
    try std.testing.expectEqualStrings("np_vectors", cfg.stores.vector_backend.collection);
    try std.testing.expectEqual(@as(u32, 7), cfg.stores.vector_backend.timeout_secs);
    try std.testing.expectEqual(@as(u32, 9), cfg.stores.vector_backend.sqlite_ann_candidate_multiplier);
    try std.testing.expectEqual(@as(u32, 77), cfg.stores.vector_backend.sqlite_ann_min_candidates);
    try std.testing.expect(cfg.stores.vector_backend.allow_insecure_http);
    try std.testing.expectEqual(@as(u32, 5), cfg.stores.vector_backend.circuit_breaker_threshold);
    try std.testing.expectEqual(@as(u64, 12_000), cfg.stores.vector_backend.circuit_breaker_cooldown_ms);
}

test "circuit breaker runtime config limits clamp from args" {
    const provider_args = [_][:0]const u8{
        "nullpantry",
        "--provider-circuit-failure-threshold",
        "0",
        "--provider-circuit-cooldown-ms",
        "9223372036854775807",
    };
    var provider_cfg = try parseArgs(std.testing.allocator, &provider_args);
    defer provider_cfg.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 1), provider_cfg.provider.circuit_failure_threshold);
    try std.testing.expectEqual(circuit_breaker.max_cooldown_ms, provider_cfg.provider.circuit_cooldown_ms);
    try validateProviderRuntimeConfigured(provider_cfg);

    const vector_args = [_][:0]const u8{
        "nullpantry",
        "--vector-backend",
        "qdrant",
        "--vector-base-url",
        "http://127.0.0.1:6333",
        "--vector-circuit-breaker-threshold",
        "9223372036854775807",
        "--vector-circuit-breaker-cooldown-ms",
        "0",
    };
    var vector_cfg = try parseArgs(std.testing.allocator, &vector_args);
    defer vector_cfg.deinit(std.testing.allocator);
    try std.testing.expectEqual(circuit_breaker.max_failure_threshold, vector_cfg.stores.vector_backend.circuit_breaker_threshold);
    try std.testing.expectEqual(@as(u64, 1), vector_cfg.stores.vector_backend.circuit_breaker_cooldown_ms);
    try validateVectorBackendConfigured(vector_cfg.stores.vector_backend);
}

test "runtime backend timeout limits clamp from args" {
    const vector_args = [_][:0]const u8{
        "nullpantry",
        "--vector-backend",
        "qdrant",
        "--vector-base-url",
        "http://127.0.0.1:6333",
        "--vector-timeout-secs",
        "0",
    };
    var vector_cfg = try parseArgs(std.testing.allocator, &vector_args);
    defer vector_cfg.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 1), vector_cfg.stores.vector_backend.timeout_secs);
    try validateVectorBackendConfigured(vector_cfg.stores.vector_backend);

    const graph_args = [_][:0]const u8{
        "nullpantry",
        "--graph-backend",
        "falkordb",
        "--graph-base-url",
        "http://127.0.0.1:3000",
        "--graph-timeout-secs",
        "9223372036854775807",
    };
    var graph_cfg = try parseArgs(std.testing.allocator, &graph_args);
    defer graph_cfg.deinit(std.testing.allocator);
    try std.testing.expectEqual(runtime_limits.max_timeout_secs, graph_cfg.stores.graph_projection.timeout_secs);
    try validateGraphProjectionConfigured(graph_cfg.stores.graph_projection);

    const analytics_args = [_][:0]const u8{
        "nullpantry",
        "--analytics-backend",
        "clickhouse",
        "--analytics-base-url",
        "http://127.0.0.1:8123",
        "--analytics-timeout-secs",
        "0",
    };
    var analytics_cfg = try parseArgs(std.testing.allocator, &analytics_args);
    defer analytics_cfg.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 1), analytics_cfg.stores.analytics_backend.timeout_secs);
    try validateAnalyticsBackendConfigured(analytics_cfg.stores.analytics_backend);
}

test "weaviate chroma and opensearch vector indexes can be configured from args" {
    const weaviate_args = [_][:0]const u8{
        "nullpantry",
        "--vector-backend",
        "weaviate",
        "--weaviate-url",
        "http://127.0.0.1:8080",
        "--weaviate-api-key",
        "weaviate-key",
        "--weaviate-collection",
        "NullPantryVector",
    };
    var weaviate_cfg = try parseArgs(std.testing.allocator, &weaviate_args);
    defer weaviate_cfg.deinit(std.testing.allocator);

    try std.testing.expectEqual(vector_runtime.BackendKind.weaviate, weaviate_cfg.stores.vector_backend.backend);
    try std.testing.expectEqualStrings("http://127.0.0.1:8080", weaviate_cfg.stores.vector_backend.base_url.?);
    try std.testing.expectEqualStrings("weaviate-key", weaviate_cfg.stores.vector_backend.api_key.?);
    try std.testing.expectEqualStrings("NullPantryVector", weaviate_cfg.stores.vector_backend.collection);

    const chroma_args = [_][:0]const u8{
        "nullpantry",
        "--chroma-url",
        "http://127.0.0.1:8000",
        "--chroma-token",
        "chroma-token",
        "--chroma-tenant",
        "team-alpha",
        "--chroma-database",
        "main",
        "--chroma-collection-id",
        "np_chroma",
    };
    var chroma_cfg = try parseArgs(std.testing.allocator, &chroma_args);
    defer chroma_cfg.deinit(std.testing.allocator);

    try std.testing.expectEqual(vector_runtime.BackendKind.chroma, chroma_cfg.stores.vector_backend.backend);
    try std.testing.expectEqualStrings("http://127.0.0.1:8000", chroma_cfg.stores.vector_backend.base_url.?);
    try std.testing.expectEqualStrings("chroma-token", chroma_cfg.stores.vector_backend.api_key.?);
    try std.testing.expectEqualStrings("team-alpha", chroma_cfg.stores.vector_backend.chroma_tenant);
    try std.testing.expectEqualStrings("main", chroma_cfg.stores.vector_backend.chroma_database);
    try std.testing.expectEqualStrings("np_chroma", chroma_cfg.stores.vector_backend.collection);

    const opensearch_args = [_][:0]const u8{
        "nullpantry",
        "--opensearch-url",
        "http://127.0.0.1:9200",
        "--opensearch-api-key",
        "os-key",
        "--opensearch-index",
        "np_vectors",
    };
    var opensearch_cfg = try parseArgs(std.testing.allocator, &opensearch_args);
    defer opensearch_cfg.deinit(std.testing.allocator);

    try std.testing.expectEqual(vector_runtime.BackendKind.opensearch, opensearch_cfg.stores.vector_backend.backend);
    try std.testing.expectEqualStrings("http://127.0.0.1:9200", opensearch_cfg.stores.vector_backend.base_url.?);
    try std.testing.expectEqualStrings("os-key", opensearch_cfg.stores.vector_backend.api_key.?);
    try std.testing.expectEqualStrings("np_vectors", opensearch_cfg.stores.vector_backend.collection);
}

test "retrieval rollout policy can be configured from args" {
    const args = [_][:0]const u8{
        "nullpantry",
        "--retrieval-canary-percent",
        "25",
        "--retrieval-shadow-percent",
        "40",
        "--retrieval-rollout-salt",
        "retrieval-v2",
        "--adaptive-keyword-max-tokens",
        "1",
        "--adaptive-vector-min-tokens",
        "4",
        "--retrieval-rollout-required-scopes",
        "[\"project:nullpantry\"]",
        "--retrieval-rollout-target-scopes",
        "[\"project:nullpantry\",\"team:agents\"]",
        "--retrieval-rollout-blocked-capabilities",
        "[\"export\"]",
    };
    var cfg = try parseArgs(std.testing.allocator, &args);
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqual(lifecycle.RolloutMode.canary, cfg.retrieval.rollout_policy.mode);
    try std.testing.expectEqual(@as(u8, 25), cfg.retrieval.rollout_policy.percent);
    try std.testing.expectEqual(@as(u8, 40), cfg.retrieval.rollout_policy.shadow_percent);
    try std.testing.expectEqualStrings("retrieval-v2", cfg.retrieval.rollout_policy.salt);
    try std.testing.expectEqual(@as(u32, 1), cfg.retrieval.adaptive_keyword_max_tokens);
    try std.testing.expectEqual(@as(u32, 4), cfg.retrieval.adaptive_vector_min_tokens);
    try std.testing.expectEqualStrings("[\"project:nullpantry\"]", cfg.retrieval.rollout_policy.required_scopes_json);
    try std.testing.expectEqualStrings("[\"project:nullpantry\",\"team:agents\"]", cfg.retrieval.rollout_policy.target_scopes_json);
    try std.testing.expectEqualStrings("[\"export\"]", cfg.retrieval.rollout_policy.blocked_capabilities_json);

    const explicit_args = [_][:0]const u8{
        "nullpantry",
        "--retrieval-rollout-mode",
        "shadow",
        "--retrieval-canary-percent",
        "100",
        "--retrieval-rollout-disabled",
    };
    var explicit_cfg = try parseArgs(std.testing.allocator, &explicit_args);
    defer explicit_cfg.deinit(std.testing.allocator);
    try std.testing.expectEqual(lifecycle.RolloutMode.shadow, explicit_cfg.retrieval.rollout_policy.mode);
    try std.testing.expectEqual(@as(u8, 100), explicit_cfg.retrieval.rollout_policy.percent);
    try std.testing.expect(explicit_cfg.retrieval.rollout_policy.disabled);
}

test "retrieval rollout policy selection requires usable configuration" {
    try validateRolloutPolicyConfigured(.{ .mode = .on, .required_scopes_json = "[\"project:nullpantry\"]" });
    try std.testing.expectError(error.InvalidRolloutPolicy, validateRolloutPolicyConfigured(.{ .required_scopes_json = "not-json" }));
    try std.testing.expectError(error.InvalidRolloutPolicy, validateRolloutPolicyConfigured(.{ .required_scopes_json = "{}" }));
    try std.testing.expectError(error.InvalidRolloutPolicy, validateRolloutPolicyConfigured(.{ .blocked_capabilities_json = "[1]" }));

    const args = [_][:0]const u8{
        "nullpantry",
        "--retrieval-rollout-required-scopes",
        "not-json",
    };
    var cfg = try parseArgs(std.testing.allocator, &args);
    defer cfg.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidRolloutPolicy, validateRolloutPolicyConfigured(cfg.retrieval.rollout_policy));
}

test "lancedb sdk vector index can be configured from args" {
    const args = [_][:0]const u8{
        "nullpantry",
        "--vector-backend",
        "lancedb",
        "--lancedb-uri",
        ".nullpantry/lancedb",
        "--lancedb-command",
        "python3",
        "--lancedb-table",
        "np_vectors",
    };
    var cfg = try parseArgs(std.testing.allocator, &args);
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqual(vector_runtime.BackendKind.lancedb, cfg.stores.vector_backend.backend);
    try std.testing.expectEqualStrings(".nullpantry/lancedb", cfg.stores.vector_backend.lancedb_uri.?);
    try std.testing.expectEqualStrings("python3", cfg.stores.vector_backend.lancedb_command);
    try std.testing.expectEqualStrings("np_vectors", cfg.stores.vector_backend.collection);
}

test "lancedb http vector index alias can be configured from args" {
    const args = [_][:0]const u8{
        "nullpantry",
        "--vector-backend",
        "lancedb-http",
        "--vector-base-url",
        "http://127.0.0.1:9000",
        "--vector-collection",
        "np_lancedb_http_vectors",
    };
    var cfg = try parseArgs(std.testing.allocator, &args);
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqual(vector_runtime.BackendKind.lancedb_http, cfg.stores.vector_backend.backend);
    try std.testing.expectEqualStrings("http://127.0.0.1:9000", cfg.stores.vector_backend.base_url.?);
    try std.testing.expectEqualStrings("np_lancedb_http_vectors", cfg.stores.vector_backend.collection);
}

test "invalid vector index config fails closed" {
    const args = [_][:0]const u8{
        "nullpantry",
        "--vector-backend",
        "lancedb-typo",
    };

    try std.testing.expectError(error.InvalidVectorBackend, parseArgs(std.testing.allocator, &args));
}

test "invalid configured backend names fail closed" {
    const store_args = [_][:0]const u8{
        "nullpantry",
        "--backend",
        "sqlite-typo",
    };
    try std.testing.expectError(error.InvalidStoreBackend, parseArgs(std.testing.allocator, &store_args));

    const agent_memory_args = [_][:0]const u8{
        "nullpantry",
        "--agent-memory-backend",
        "redis-typo",
    };
    try std.testing.expectError(error.InvalidAgentMemoryBackend, parseArgs(std.testing.allocator, &agent_memory_args));

    const analytics_args = [_][:0]const u8{
        "nullpantry",
        "--analytics-backend",
        "clickhouse-typo",
    };
    try std.testing.expectError(error.InvalidAnalyticsBackend, parseArgs(std.testing.allocator, &analytics_args));

    const embedding_provider_args = [_][:0]const u8{
        "nullpantry",
        "--embedding-provider",
        "voyage-typo",
    };
    try std.testing.expectError(error.InvalidEmbeddingProvider, parseArgs(std.testing.allocator, &embedding_provider_args));

    const rollout_mode_args = [_][:0]const u8{
        "nullpantry",
        "--retrieval-rollout-mode",
        "canray",
    };
    try std.testing.expectError(error.InvalidRolloutMode, parseArgs(std.testing.allocator, &rollout_mode_args));
}

test "pgvector runtime backend can be configured from args" {
    const args = [_][:0]const u8{
        "nullpantry",
        "--vector-backend",
        "pgvector",
        "--pgvector-url",
        "postgres://nullpantry@127.0.0.1:5432/nullpantry",
        "--pgvector-table",
        "np_vectors",
    };
    var cfg = try parseArgs(std.testing.allocator, &args);
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqual(vector_runtime.BackendKind.pgvector, cfg.stores.vector_backend.backend);
    try std.testing.expectEqualStrings("postgres://nullpantry@127.0.0.1:5432/nullpantry", cfg.stores.vector_backend.postgres_url.?);
    try std.testing.expectEqualStrings("np_vectors", cfg.stores.vector_backend.collection);
}

test "external vector index selection requires usable configuration" {
    try validateVectorBackendConfigured(.{ .backend = .local });
    try std.testing.expectError(error.InvalidVectorBackend, validateVectorBackendConfigured(.{ .backend = .qdrant }));
    try std.testing.expectError(error.InvalidVectorBackend, validateVectorBackendConfigured(.{ .backend = .pgvector }));
    try std.testing.expectError(error.InvalidVectorBackend, validateVectorBackendConfigured(.{ .backend = .lancedb }));
    try std.testing.expectError(error.InvalidVectorBackend, validateVectorBackendConfigured(.{ .backend = .lancedb_http }));
    try std.testing.expectError(error.InvalidVectorBackend, validateVectorBackendConfigured(.{ .backend = .weaviate }));
    try std.testing.expectError(error.InvalidVectorBackend, validateVectorBackendConfigured(.{ .backend = .chroma }));
    try std.testing.expectError(error.InvalidVectorBackend, validateVectorBackendConfigured(.{ .backend = .opensearch }));

    try validateVectorBackendConfigured(.{ .backend = .qdrant, .base_url = "http://127.0.0.1:6333" });
    try validateVectorBackendConfigured(.{ .backend = .pgvector, .postgres_url = "postgres://nullpantry@127.0.0.1:5432/nullpantry" });
    try validateVectorBackendConfigured(.{ .backend = .lancedb, .lancedb_uri = ".nullpantry/lancedb" });
    try validateVectorBackendConfigured(.{ .backend = .lancedb_http, .base_url = "http://127.0.0.1:9000" });
    try validateVectorBackendConfigured(.{ .backend = .weaviate, .base_url = "http://127.0.0.1:8080", .collection = "NullPantryVector" });
    try validateVectorBackendConfigured(.{ .backend = .chroma, .base_url = "http://127.0.0.1:8000", .collection = "np_chroma" });
    try validateVectorBackendConfigured(.{ .backend = .opensearch, .base_url = "http://127.0.0.1:9200", .collection = "np_vectors" });
    try std.testing.expectError(error.InvalidHttpHeaderName, validateVectorBackendConfigured(.{
        .backend = .qdrant,
        .base_url = "http://127.0.0.1:6333",
        .api_key_header = "Bad Header",
    }));
}

test "named vector stores can be configured from args" {
    const args = [_][:0]const u8{
        "nullpantry",
        "--vector-store",
        "ann=qdrant,url=http://127.0.0.1:6333,collection=np_qdrant,allow_insecure_http=true,api_key_header=api-key",
        "--vector-store",
        "pg=pgvector,postgres_url=postgres://nullpantry@127.0.0.1:5432/nullpantry,table=np_pg_vectors",
    };
    var cfg = try parseArgs(std.testing.allocator, &args);
    defer cfg.deinit(std.testing.allocator);
    defer {
        for (cfg.stores.vector_stores) |named| std.testing.allocator.free(named.name);
        std.testing.allocator.free(cfg.stores.vector_stores);
    }

    try std.testing.expectEqual(@as(usize, 2), cfg.stores.vector_stores.len);
    try std.testing.expectEqualStrings("ann", cfg.stores.vector_stores[0].name);
    try std.testing.expectEqual(vector_runtime.BackendKind.qdrant, cfg.stores.vector_stores[0].config.backend);
    try std.testing.expectEqualStrings("http://127.0.0.1:6333", cfg.stores.vector_stores[0].config.base_url.?);
    try std.testing.expectEqualStrings("np_qdrant", cfg.stores.vector_stores[0].config.collection);
    try std.testing.expect(cfg.stores.vector_stores[0].config.allow_insecure_http);
    try std.testing.expectEqualStrings("api-key", cfg.stores.vector_stores[0].config.api_key_header);
    try std.testing.expectEqualStrings("pg", cfg.stores.vector_stores[1].name);
    try std.testing.expectEqual(vector_runtime.BackendKind.pgvector, cfg.stores.vector_stores[1].config.backend);
    try std.testing.expectEqualStrings("postgres://nullpantry@127.0.0.1:5432/nullpantry", cfg.stores.vector_stores[1].config.postgres_url.?);
    try std.testing.expectEqualStrings("np_pg_vectors", cfg.stores.vector_stores[1].config.collection);
}

test "named weaviate chroma and opensearch vector stores can be configured from args and json" {
    const args = [_][:0]const u8{
        "nullpantry",
        "--vector-store",
        "weav=weaviate,weaviate_url=http://127.0.0.1:8080,weaviate_collection=NullPantryVector,api_key=wk",
        "--vector-store",
        "chroma-dev=chroma,chroma_url=http://127.0.0.1:8000,chroma_tenant=team,chroma_database=main,chroma_collection=np_chroma,token=ct",
        "--vector-store",
        "os=opensearch,opensearch_url=http://127.0.0.1:9200,opensearch_index=np_os,api_key=ok",
    };
    var cfg = try parseArgs(std.testing.allocator, &args);
    defer cfg.deinit(std.testing.allocator);
    defer {
        for (cfg.stores.vector_stores) |named| std.testing.allocator.free(named.name);
        std.testing.allocator.free(cfg.stores.vector_stores);
    }

    try std.testing.expectEqual(@as(usize, 3), cfg.stores.vector_stores.len);
    try std.testing.expectEqualStrings("weav", cfg.stores.vector_stores[0].name);
    try std.testing.expectEqual(vector_runtime.BackendKind.weaviate, cfg.stores.vector_stores[0].config.backend);
    try std.testing.expectEqualStrings("http://127.0.0.1:8080", cfg.stores.vector_stores[0].config.base_url.?);
    try std.testing.expectEqualStrings("NullPantryVector", cfg.stores.vector_stores[0].config.collection);
    try std.testing.expectEqualStrings("wk", cfg.stores.vector_stores[0].config.api_key.?);
    try std.testing.expectEqualStrings("chroma-dev", cfg.stores.vector_stores[1].name);
    try std.testing.expectEqual(vector_runtime.BackendKind.chroma, cfg.stores.vector_stores[1].config.backend);
    try std.testing.expectEqualStrings("http://127.0.0.1:8000", cfg.stores.vector_stores[1].config.base_url.?);
    try std.testing.expectEqualStrings("team", cfg.stores.vector_stores[1].config.chroma_tenant);
    try std.testing.expectEqualStrings("main", cfg.stores.vector_stores[1].config.chroma_database);
    try std.testing.expectEqualStrings("np_chroma", cfg.stores.vector_stores[1].config.collection);
    try std.testing.expectEqualStrings("ct", cfg.stores.vector_stores[1].config.api_key.?);
    try std.testing.expectEqualStrings("os", cfg.stores.vector_stores[2].name);
    try std.testing.expectEqual(vector_runtime.BackendKind.opensearch, cfg.stores.vector_stores[2].config.backend);
    try std.testing.expectEqualStrings("http://127.0.0.1:9200", cfg.stores.vector_stores[2].config.base_url.?);
    try std.testing.expectEqualStrings("np_os", cfg.stores.vector_stores[2].config.collection);
    try std.testing.expectEqualStrings("ok", cfg.stores.vector_stores[2].config.api_key.?);

    const parsed = try parseVectorStoreConfigsJson(std.testing.allocator,
        \\[
        \\ {"name":"weav","weaviate_url":"http://weaviate.local","weaviate_collection":"NullPantryVector"},
        \\ {"name":"chroma","chroma_url":"http://chroma.local","chroma_tenant":"tenant","chroma_database":"db","chroma_collection_id":"collection-id"},
        \\ {"name":"os","opensearch_url":"http://opensearch.local","opensearch_index":"np_vectors","token":"os-token"}
        \\]
    );
    defer freeParsedNamedVectorConfigs(std.testing.allocator, parsed);

    try std.testing.expectEqual(@as(usize, 3), parsed.len);
    try std.testing.expectEqual(vector_runtime.BackendKind.weaviate, parsed[0].config.backend);
    try std.testing.expectEqualStrings("http://weaviate.local", parsed[0].config.base_url.?);
    try std.testing.expectEqualStrings("NullPantryVector", parsed[0].config.collection);
    try std.testing.expectEqual(vector_runtime.BackendKind.chroma, parsed[1].config.backend);
    try std.testing.expectEqualStrings("http://chroma.local", parsed[1].config.base_url.?);
    try std.testing.expectEqualStrings("tenant", parsed[1].config.chroma_tenant);
    try std.testing.expectEqualStrings("db", parsed[1].config.chroma_database);
    try std.testing.expectEqualStrings("collection-id", parsed[1].config.collection);
    try std.testing.expectEqual(vector_runtime.BackendKind.opensearch, parsed[2].config.backend);
    try std.testing.expectEqualStrings("http://opensearch.local", parsed[2].config.base_url.?);
    try std.testing.expectEqualStrings("np_vectors", parsed[2].config.collection);
    try std.testing.expectEqualStrings("os-token", parsed[2].config.api_key.?);
}

test "chunker can be configured from args" {
    const args = [_][:0]const u8{
        "nullpantry",
        "--chunk-max-chars",
        "2048",
        "--chunk-overlap-chars",
        "128",
        "--chunk-strategy",
        "markdown",
    };
    var cfg = try parseArgs(std.testing.allocator, &args);
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2048), cfg.retrieval.chunker.max_chars);
    try std.testing.expectEqual(@as(usize, 128), cfg.retrieval.chunker.overlap_chars);
    try std.testing.expectEqual(vector_mod.ChunkStrategy.markdown, cfg.retrieval.chunker.strategy);

    const invalid = [_][:0]const u8{
        "nullpantry",
        "--chunk-max-chars",
        "128",
        "--chunk-overlap-chars",
        "128",
    };
    try std.testing.expectError(error.InvalidChunkConfig, parseArgs(std.testing.allocator, &invalid));
}

test "named vector stores can be configured from json" {
    const parsed = try parseVectorStoreConfigsJson(std.testing.allocator,
        \\[
        \\ {"name":"ann","backend":"qdrant","url":"http://127.0.0.1:6333","collection":"np_qdrant","allow_insecure_http":true},
        \\ {"name":"lance","backend":"lancedb","lancedb_uri":".nullpantry/lance","lancedb_command":"python3","table":"np_lance"},
        \\ {"name":"lance-http","url":"http://qdrant.invalid","lancedb_url":"http://lancedb.example","collection":"np_lance_http"}
        \\]
    );
    defer freeParsedNamedVectorConfigs(std.testing.allocator, parsed);

    try std.testing.expectEqual(@as(usize, 3), parsed.len);
    try std.testing.expectEqualStrings("ann", parsed[0].name);
    try std.testing.expectEqual(vector_runtime.BackendKind.qdrant, parsed[0].config.backend);
    try std.testing.expectEqualStrings("np_qdrant", parsed[0].config.collection);
    try std.testing.expectEqualStrings("lance", parsed[1].name);
    try std.testing.expectEqual(vector_runtime.BackendKind.lancedb, parsed[1].config.backend);
    try std.testing.expectEqualStrings(".nullpantry/lance", parsed[1].config.lancedb_uri.?);
    try std.testing.expectEqualStrings("lance-http", parsed[2].name);
    try std.testing.expectEqual(vector_runtime.BackendKind.lancedb_http, parsed[2].config.backend);
    try std.testing.expectEqualStrings("http://lancedb.example", parsed[2].config.base_url.?);
    try std.testing.expectEqualStrings("np_lance_http", parsed[2].config.collection);

    const spec = try parseVectorStoreSpec(std.testing.allocator, "mixed=url=http://qdrant.invalid,lancedb_url=http://lancedb.local,collection=np_mixed");
    defer std.testing.allocator.free(spec.name);
    try std.testing.expectEqual(vector_runtime.BackendKind.lancedb_http, spec.config.backend);
    try std.testing.expectEqualStrings("http://lancedb.local", spec.config.base_url.?);
    try std.testing.expectEqualStrings("np_mixed", spec.config.collection);
}

test "named vector store json numeric limits saturate instead of trapping" {
    const parsed = try parseVectorStoreConfigsJson(std.testing.allocator,
        \\[
        \\ {"name":"ann","backend":"qdrant","url":"http://127.0.0.1:6333","timeout_secs":9223372036854775807,"circuit_breaker_threshold":9223372036854775807,"circuit_breaker_cooldown_ms":9223372036854775807},
        \\ {"name":"disabled","backend":"qdrant","url":"http://127.0.0.1:6334","timeout_secs":-1,"circuit_breaker_threshold":-1,"circuit_breaker_cooldown_ms":-1}
        \\]
    );
    defer freeParsedNamedVectorConfigs(std.testing.allocator, parsed);

    try std.testing.expectEqual(@as(usize, 2), parsed.len);
    try std.testing.expectEqual(runtime_limits.max_timeout_secs, parsed[0].config.timeout_secs);
    try std.testing.expectEqual(circuit_breaker.max_failure_threshold, parsed[0].config.circuit_breaker_threshold);
    try std.testing.expectEqual(@as(u64, @intCast(circuit_breaker.max_cooldown_ms)), parsed[0].config.circuit_breaker_cooldown_ms);
    try std.testing.expectEqual(@as(u32, 1), parsed[1].config.timeout_secs);
    try std.testing.expectEqual(@as(u32, 1), parsed[1].config.circuit_breaker_threshold);
    try std.testing.expectEqual(@as(u64, 1), parsed[1].config.circuit_breaker_cooldown_ms);
}

test "clickhouse analytics backend can be configured from args" {
    const args = [_][:0]const u8{
        "nullpantry",
        "--analytics-backend",
        "clickhouse",
        "--analytics-base-url",
        "http://127.0.0.1:8123",
        "--analytics-table",
        "np_events",
        "--analytics-timeout-secs",
        "9",
        "--analytics-allow-insecure-http",
    };
    var cfg = try parseArgs(std.testing.allocator, &args);
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqual(analytics_runtime.BackendKind.clickhouse, cfg.stores.analytics_backend.backend);
    try std.testing.expectEqualStrings("http://127.0.0.1:8123", cfg.stores.analytics_backend.base_url.?);
    try std.testing.expectEqualStrings("np_events", cfg.stores.analytics_backend.table);
    try std.testing.expectEqual(@as(u32, 9), cfg.stores.analytics_backend.timeout_secs);
    try std.testing.expect(cfg.stores.analytics_backend.allow_insecure_http);
}

test "analytics backend selection requires usable configuration" {
    try validateAnalyticsBackendConfigured(.{});
    try validateAnalyticsBackendConfigured(.{ .backend = .none });

    try std.testing.expectError(error.MissingAnalyticsBaseUrl, validateAnalyticsBackendConfigured(.{
        .backend = .clickhouse,
    }));
    try std.testing.expectError(error.MissingAnalyticsBaseUrl, validateAnalyticsBackendConfigured(.{
        .backend = .clickhouse,
        .base_url = " \t\r\n",
    }));
    try std.testing.expectError(error.InvalidAnalyticsTable, validateAnalyticsBackendConfigured(.{
        .backend = .clickhouse,
        .base_url = "http://127.0.0.1:8123",
        .table = "bad table",
    }));
    try validateAnalyticsBackendConfigured(.{
        .backend = .clickhouse,
        .base_url = "http://127.0.0.1:8123",
        .table = "np_events",
    });
}

test "lucid projection can be configured from args" {
    const args = [_][:0]const u8{
        "nullpantry",
        "--lucid-enabled",
        "--lucid-command",
        "lucid-test",
        "--lucid-workspace",
        "/tmp/nullpantry",
        "--lucid-token-budget",
        "512",
        "--lucid-local-hit-threshold",
        "2",
        "--lucid-project-scopes",
        "[\"admin\"]",
        "--lucid-result-scope",
        "project:nullpantry",
        "--lucid-permissions",
        "[\"team:platform\"]",
    };
    var cfg = try parseArgs(std.testing.allocator, &args);
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expect(cfg.stores.lucid_projection.isEnabled());
    try std.testing.expectEqualStrings("lucid-test", cfg.stores.lucid_projection.command);
    try std.testing.expectEqualStrings("/tmp/nullpantry", cfg.stores.lucid_projection.workspace_dir);
    try std.testing.expectEqual(@as(usize, 512), cfg.stores.lucid_projection.token_budget);
    try std.testing.expectEqual(@as(usize, 2), cfg.stores.lucid_projection.local_hit_threshold);
    try std.testing.expectEqualStrings("[\"admin\"]", cfg.stores.lucid_projection.project_scopes_json);
    try std.testing.expectEqualStrings("project:nullpantry", cfg.stores.lucid_projection.result_scope);
    try std.testing.expectEqualStrings("[\"team:platform\"]", cfg.stores.lucid_projection.permissions_json);
}

test "lucid numeric config limits clamp from args" {
    const args = [_][:0]const u8{
        "nullpantry",
        "--lucid-enabled",
        "--lucid-workspace",
        "/tmp/nullpantry",
        "--lucid-token-budget",
        "9223372036854775807",
        "--lucid-local-hit-threshold",
        "0",
    };
    var cfg = try parseArgs(std.testing.allocator, &args);
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqual(lucid_runtime.max_token_budget, cfg.stores.lucid_projection.token_budget);
    try std.testing.expectEqual(@as(usize, 1), cfg.stores.lucid_projection.local_hit_threshold);
    try validateLucidProjectionConfigured(cfg.stores.lucid_projection);
}

test "neo4j and falkordb graph projection can be configured from args" {
    const neo4j_args = [_][:0]const u8{
        "nullpantry",
        "--neo4j-url",
        "http://127.0.0.1:7474",
        "--neo4j-api-key",
        "neo4j-key",
        "--neo4j-database",
        "neo4j_team",
        "--graph-timeout-secs",
        "9",
        "--graph-project-scopes",
        "[\"admin\",\"team:alpha\"]",
    };
    var neo4j_cfg = try parseArgs(std.testing.allocator, &neo4j_args);
    defer neo4j_cfg.deinit(std.testing.allocator);

    try std.testing.expectEqual(graph_runtime.BackendKind.neo4j, neo4j_cfg.stores.graph_projection.backend);
    try std.testing.expectEqualStrings("http://127.0.0.1:7474", neo4j_cfg.stores.graph_projection.base_url.?);
    try std.testing.expectEqualStrings("neo4j-key", neo4j_cfg.stores.graph_projection.api_key.?);
    try std.testing.expectEqualStrings("neo4j_team", neo4j_cfg.stores.graph_projection.database);
    try std.testing.expectEqual(@as(u32, 9), neo4j_cfg.stores.graph_projection.timeout_secs);
    try std.testing.expectEqualStrings("[\"admin\",\"team:alpha\"]", neo4j_cfg.stores.graph_projection.project_scopes_json);
    try validateGraphProjectionConfigured(neo4j_cfg.stores.graph_projection);

    const falkor_args = [_][:0]const u8{
        "nullpantry",
        "--graph-backend",
        "falkordb",
        "--graph-falkordb-url",
        "http://127.0.0.1:3000",
        "--graph-falkordb-api-key",
        "falkor-key",
        "--graph-falkordb-name",
        "agent_memory",
    };
    var falkor_cfg = try parseArgs(std.testing.allocator, &falkor_args);
    defer falkor_cfg.deinit(std.testing.allocator);

    try std.testing.expectEqual(graph_runtime.BackendKind.falkordb, falkor_cfg.stores.graph_projection.backend);
    try std.testing.expectEqualStrings("http://127.0.0.1:3000", falkor_cfg.stores.graph_projection.base_url.?);
    try std.testing.expectEqualStrings("falkor-key", falkor_cfg.stores.graph_projection.api_key.?);
    try std.testing.expectEqualStrings("agent_memory", falkor_cfg.stores.graph_projection.graph);
    try validateGraphProjectionConfigured(falkor_cfg.stores.graph_projection);
}

test "graph projection selection requires usable configuration" {
    try validateGraphProjectionConfigured(.{});
    try std.testing.expectError(error.MissingGraphBackendUrl, validateGraphProjectionConfigured(.{ .backend = .neo4j }));
    try std.testing.expectError(error.MissingGraphBackendUrl, validateGraphProjectionConfigured(.{ .backend = .falkordb }));
    try std.testing.expectError(error.InvalidGraphBackend, validateGraphProjectionConfigured(.{
        .backend = .neo4j,
        .base_url = "http://127.0.0.1:7474",
        .database = "bad/database",
    }));
    try std.testing.expectError(error.InvalidGraphBackend, validateGraphProjectionConfigured(.{
        .backend = .falkordb,
        .base_url = "http://127.0.0.1:3000",
        .graph = "bad graph",
    }));
    try std.testing.expectError(error.InvalidGraphBackend, validateGraphProjectionConfigured(.{
        .backend = .neo4j,
        .base_url = "http://127.0.0.1:7474",
        .timeout_secs = 0,
    }));
    try std.testing.expectError(error.InvalidGraphBackend, validateGraphProjectionConfigured(.{
        .backend = .neo4j,
        .base_url = "http://127.0.0.1:7474",
        .timeout_secs = runtime_limits.max_timeout_secs + 1,
    }));
    try validateGraphProjectionConfigured(.{ .backend = .neo4j, .base_url = "http://127.0.0.1:7474" });
    try validateGraphProjectionConfigured(.{ .backend = .falkordb, .base_url = "http://127.0.0.1:3000" });
}

test "lucid projection selection requires usable configuration" {
    try validateLucidProjectionConfigured(.{});
    try validateLucidProjectionConfigured(.{ .enabled = false, .command = " " });
    try std.testing.expectError(error.InvalidLucidCommand, validateLucidProjectionConfigured(.{
        .enabled = true,
        .command = " ",
    }));
    try std.testing.expectError(error.InvalidLucidWorkspace, validateLucidProjectionConfigured(.{
        .enabled = true,
        .workspace_dir = " ",
    }));
    try std.testing.expectError(error.InvalidLucidTimeout, validateLucidProjectionConfigured(.{
        .enabled = true,
        .recall_timeout_ms = 0,
    }));
    try validateLucidProjectionConfigured(.{
        .enabled = true,
        .command = "lucid",
        .workspace_dir = ".",
    });
}

test {
    _ = @import("agent_memory_contract_tests.zig");
}
