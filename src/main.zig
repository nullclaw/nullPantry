const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const compat = @import("compat.zig");
const api = @import("api.zig");
const ids = @import("ids.zig");
const store_mod = @import("store.zig");
const worker = @import("worker.zig");
const agent_memory_runtime = @import("agent_memory_runtime.zig");
const redis_mod = @import("redis.zig");
const vector_runtime = @import("vector_runtime.zig");
const analytics_runtime = @import("analytics_runtime.zig");
const lucid_runtime = @import("lucid_runtime.zig");
const providers = @import("providers.zig");

const default_port: u16 = 8765;
const max_request_size: usize = 2 * 1024 * 1024;
const max_header_bytes: usize = 64 * 1024;
const max_header_lines: usize = 128;
const read_chunk_size: usize = 4096;
const socket_timeout_secs: i64 = 30;
const max_active_connections: usize = 128;

const RuntimeConfig = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = default_port,
    db_path: [:0]const u8 = ".nullpantry/nullpantry.db",
    backend: store_mod.BackendKind = .sqlite,
    postgres_url: ?[]const u8 = null,
    token: ?[]const u8 = null,
    token_principals_json: ?[]const u8 = null,
    actor_scopes_json: []const u8 = "[\"admin\"]",
    actor_capabilities_json: []const u8 = "[\"read\",\"write\",\"propose\",\"verify\",\"delete\",\"export\",\"feed_apply\"]",
    worker_scopes_json: []const u8 = "[\"admin\"]",
    worker_capabilities_json: []const u8 = "[\"read\",\"write\",\"propose\",\"verify\",\"delete\",\"export\",\"feed_apply\"]",
    embedding_base_url: ?[]const u8 = null,
    embedding_api_key: ?[]const u8 = null,
    embedding_model: ?[]const u8 = null,
    embedding_provider: providers.EmbeddingProviderKind = .openai_compatible,
    embedding_dimensions: usize = 64,
    llm_base_url: ?[]const u8 = null,
    llm_api_key: ?[]const u8 = null,
    llm_model: ?[]const u8 = null,
    provider_timeout_secs: u32 = 30,
    worker_interval_ms: u64 = 5000,
    trust_actor_headers: bool = false,
    agent_memory_backend: agent_memory_runtime.BackendKind = .native,
    memory_config: agent_memory_runtime.MemoryConfig = .{},
    redis_config: redis_mod.Config = .{},
    api_agent_memory_config: agent_memory_runtime.ApiConfig = .{},
    agent_memory_store_configs: []const agent_memory_runtime.NamedConfig = &.{},
    vector_backend: vector_runtime.Config = .{},
    analytics_backend: analytics_runtime.Config = .{},
    lucid_projection: lucid_runtime.Config = .{},
};

const ServerState = struct {
    allocator: std.mem.Allocator,
    store: *store_mod.Store,
    cfg: RuntimeConfig,
    active_connections: std.atomic.Value(usize) = .init(0),
};

pub fn main(init: std.process.Init) !void {
    compat.initProcess(init);
    const allocator = std.heap.smp_allocator;

    const args = try compat.process.argsAlloc(allocator);
    defer compat.process.argsFree(allocator, args);

    const cfg = try parseArgs(allocator, args);
    if (cfg.backend == .sqlite) try ensureParentDirForFile(cfg.db_path);

    const store_options = store_mod.StoreOptions{
        .agent_memory = .{
            .backend = cfg.agent_memory_backend,
            .memory = cfg.memory_config,
            .redis = cfg.redis_config,
            .api = cfg.api_agent_memory_config,
        },
        .agent_memory_stores = cfg.agent_memory_store_configs,
        .vector_backend = cfg.vector_backend,
        .analytics_backend = cfg.analytics_backend,
        .lucid_projection = cfg.lucid_projection,
    };
    var store = switch (cfg.backend) {
        .sqlite => try store_mod.Store.initSQLiteWithOptions(allocator, cfg.db_path, store_options),
        .postgres => try store_mod.Store.initPostgresWithOptions(allocator, cfg.postgres_url orelse return error.MissingPostgresUrl, store_options),
    };
    defer store.deinit();

    const addr = try std.Io.net.IpAddress.resolve(compat.io(), cfg.host, cfg.port);
    var server = try addr.listen(compat.io(), .{ .reuse_address = true });
    defer server.deinit(compat.io());

    std.debug.print("nullpantry v{s}\n", .{build_options.version});
    std.debug.print("listening on http://{s}:{d}\n", .{ cfg.host, cfg.port });
    std.debug.print("storage backend: {s}\n", .{@tagName(cfg.backend)});
    std.debug.print("agent memory backend: {s}\n", .{cfg.agent_memory_backend.name()});
    std.debug.print("named agent memory stores: {d}\n", .{cfg.agent_memory_store_configs.len});
    std.debug.print("vector backend: {s}\n", .{cfg.vector_backend.backend.name()});
    std.debug.print("analytics backend: {s}\n", .{cfg.analytics_backend.backend.name()});
    std.debug.print("lucid projection: {s}\n", .{if (cfg.lucid_projection.isEnabled()) "enabled" else "disabled"});

    var state = ServerState{ .allocator = allocator, .store = &store, .cfg = cfg };
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

    const raw = readHttpRequest(req_alloc, &conn, max_request_size) catch |err| {
        std.debug.print("request_id={s} event=request_read_error error={}\n", .{ request_id, err });
        return;
    } orelse return;

    const first_line_end = std.mem.indexOf(u8, raw, "\r\n") orelse return;
    const first_line = raw[0..first_line_end];
    var parts = std.mem.splitScalar(u8, first_line, ' ');
    const method = parts.next() orelse return;
    const target = parts.next() orelse return;
    const body = @import("json_util.zig").extractBody(raw);

    var ctx = api.Context{
        .allocator = req_alloc,
        .store = state.store,
        .required_token = state.cfg.token,
        .token_principals_json = state.cfg.token_principals_json,
        .actor_scopes_json = state.cfg.actor_scopes_json,
        .actor_capabilities_json = state.cfg.actor_capabilities_json,
        .embedding_base_url = state.cfg.embedding_base_url,
        .embedding_api_key = state.cfg.embedding_api_key,
        .embedding_model = state.cfg.embedding_model,
        .embedding_provider = state.cfg.embedding_provider,
        .embedding_dimensions = state.cfg.embedding_dimensions,
        .llm_base_url = state.cfg.llm_base_url,
        .llm_api_key = state.cfg.llm_api_key,
        .llm_model = state.cfg.llm_model,
        .provider_timeout_secs = state.cfg.provider_timeout_secs,
        .trust_actor_headers = state.cfg.trust_actor_headers,
    };
    const response = api.handleRequest(&ctx, method, target, body, raw);

    std.debug.print("request_id={s} method={s} target={s} status=\"{s}\"\n", .{ request_id, method, target, response.status });

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
        std.Io.sleep(compat.io(), .fromNanoseconds(@intCast(state.cfg.worker_interval_ms * std.time.ns_per_ms)), .awake) catch {};
        var arena = std.heap.ArenaAllocator.init(state.allocator);
        const result = worker.runOnce(arena.allocator(), state.store, .{
            .scopes_json = state.cfg.worker_scopes_json,
            .capabilities_json = state.cfg.worker_capabilities_json,
            .job_limit = 25,
            .outbox_limit = 250,
            .embedding_base_url = state.cfg.embedding_base_url,
            .embedding_api_key = state.cfg.embedding_api_key,
            .embedding_model = state.cfg.embedding_model,
            .embedding_provider = state.cfg.embedding_provider,
            .embedding_dimensions = state.cfg.embedding_dimensions,
            .llm_base_url = state.cfg.llm_base_url,
            .llm_api_key = state.cfg.llm_api_key,
            .llm_model = state.cfg.llm_model,
            .provider_timeout_secs = state.cfg.provider_timeout_secs,
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

fn parseArgs(allocator: std.mem.Allocator, args: []const [:0]const u8) !RuntimeConfig {
    var cfg = RuntimeConfig{};
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_TOKEN")) |token| {
        cfg.token = token;
        cfg.actor_scopes_json = "[\"public\"]";
        cfg.actor_capabilities_json = "[\"read\"]";
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_TOKEN_PRINCIPALS")) |principals| {
        cfg.token_principals_json = principals;
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_DATABASE_URL")) |url| {
        cfg.backend = .postgres;
        cfg.postgres_url = url;
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_SCOPES")) |scopes| {
        cfg.actor_scopes_json = scopes;
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_CAPABILITIES")) |caps| {
        cfg.actor_capabilities_json = caps;
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_WORKER_SCOPES")) |scopes| {
        cfg.worker_scopes_json = scopes;
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_WORKER_CAPABILITIES")) |caps| {
        cfg.worker_capabilities_json = caps;
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_EMBEDDING_BASE_URL")) |url| {
        cfg.embedding_base_url = url;
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_EMBEDDING_API_KEY")) |key| {
        cfg.embedding_api_key = key;
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_EMBEDDING_MODEL")) |model| {
        cfg.embedding_model = model;
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_EMBEDDING_PROVIDER")) |provider| {
        defer allocator.free(provider);
        cfg.embedding_provider = providers.EmbeddingProviderKind.parse(provider);
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_EMBEDDING_DIMENSIONS")) |dims| {
        cfg.embedding_dimensions = std.fmt.parseInt(usize, dims, 10) catch cfg.embedding_dimensions;
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_LLM_BASE_URL")) |url| {
        cfg.llm_base_url = url;
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_LLM_API_KEY")) |key| {
        cfg.llm_api_key = key;
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_LLM_MODEL")) |model| {
        cfg.llm_model = model;
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_PROVIDER_TIMEOUT_SECS")) |secs| {
        cfg.provider_timeout_secs = std.fmt.parseInt(u32, secs, 10) catch cfg.provider_timeout_secs;
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_WORKER_INTERVAL_MS")) |interval| {
        cfg.worker_interval_ms = std.fmt.parseInt(u64, interval, 10) catch cfg.worker_interval_ms;
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_TRUST_ACTOR_HEADERS")) |value| {
        defer allocator.free(value);
        cfg.trust_actor_headers = parseBool(value);
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_AGENT_MEMORY_BACKEND")) |backend| {
        cfg.agent_memory_backend = agent_memory_runtime.BackendKind.parse(backend);
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_AGENT_MEMORY_API_URL")) |url| {
        cfg.api_agent_memory_config.base_url = url;
        cfg.agent_memory_backend = .api;
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_AGENT_MEMORY_API_TOKEN")) |token| {
        cfg.api_agent_memory_config.token = token;
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_AGENT_MEMORY_API_SCOPES")) |scopes| {
        cfg.api_agent_memory_config.actor_scopes_json = scopes;
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_AGENT_MEMORY_API_CAPABILITIES")) |capabilities| {
        cfg.api_agent_memory_config.actor_capabilities_json = capabilities;
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_AGENT_MEMORY_API_TIMEOUT_SECS")) |secs| {
        defer allocator.free(secs);
        cfg.api_agent_memory_config.timeout_secs = std.fmt.parseInt(u32, secs, 10) catch cfg.api_agent_memory_config.timeout_secs;
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_AGENT_MEMORY_API_MAX_RESPONSE_BYTES")) |bytes| {
        defer allocator.free(bytes);
        cfg.api_agent_memory_config.max_response_bytes = std.fmt.parseInt(usize, bytes, 10) catch cfg.api_agent_memory_config.max_response_bytes;
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_MEMORY_LRU_MAX_ENTRIES")) |max_entries| {
        defer allocator.free(max_entries);
        cfg.memory_config.max_entries = std.fmt.parseInt(usize, max_entries, 10) catch cfg.memory_config.max_entries;
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_MEMORY_LRU_MAX_MESSAGES")) |max_messages| {
        defer allocator.free(max_messages);
        cfg.memory_config.max_messages = std.fmt.parseInt(usize, max_messages, 10) catch cfg.memory_config.max_messages;
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_MEMORY_LRU_MAX_USAGE_ENTRIES")) |max_usage_entries| {
        defer allocator.free(max_usage_entries);
        cfg.memory_config.max_usage_entries = std.fmt.parseInt(usize, max_usage_entries, 10) catch cfg.memory_config.max_usage_entries;
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_MEMORY_LRU_MAX_BYTES")) |max_bytes| {
        defer allocator.free(max_bytes);
        cfg.memory_config.max_bytes = std.fmt.parseInt(usize, max_bytes, 10) catch cfg.memory_config.max_bytes;
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_MEMORY_LRU_TTL_SECONDS")) |ttl| {
        defer allocator.free(ttl);
        cfg.memory_config.ttl_seconds = std.fmt.parseInt(u32, ttl, 10) catch cfg.memory_config.ttl_seconds;
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_REDIS_URL")) |url| {
        cfg.redis_config = try redis_mod.parseUrl(allocator, url);
        cfg.agent_memory_backend = .redis;
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_REDIS_KEY_PREFIX")) |prefix| {
        cfg.redis_config.key_prefix = prefix;
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_REDIS_TTL_SECONDS")) |ttl| {
        cfg.redis_config.ttl_seconds = std.fmt.parseInt(u32, ttl, 10) catch cfg.redis_config.ttl_seconds;
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_AGENT_MEMORY_STORES")) |raw| {
        defer allocator.free(raw);
        cfg.agent_memory_store_configs = try parseAgentMemoryStoreConfigsJson(allocator, raw);
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_VECTOR_BACKEND")) |backend| {
        cfg.vector_backend.backend = vector_runtime.BackendKind.parse(backend);
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_VECTOR_BASE_URL")) |url| {
        cfg.vector_backend.base_url = url;
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_VECTOR_API_KEY")) |key| {
        cfg.vector_backend.api_key = key;
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_VECTOR_COLLECTION")) |collection| {
        cfg.vector_backend.collection = collection;
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_VECTOR_TIMEOUT_SECS")) |secs| {
        cfg.vector_backend.timeout_secs = std.fmt.parseInt(u32, secs, 10) catch cfg.vector_backend.timeout_secs;
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_QDRANT_URL")) |url| {
        cfg.vector_backend.backend = .qdrant;
        cfg.vector_backend.base_url = url;
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_QDRANT_API_KEY")) |key| {
        cfg.vector_backend.api_key = key;
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_QDRANT_COLLECTION")) |collection| {
        cfg.vector_backend.backend = .qdrant;
        cfg.vector_backend.collection = collection;
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_LANCEDB_URI")) |uri| {
        cfg.vector_backend.backend = .lancedb;
        cfg.vector_backend.lancedb_uri = uri;
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_LANCEDB_COMMAND")) |command| {
        cfg.vector_backend.backend = .lancedb;
        cfg.vector_backend.lancedb_command = command;
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_LANCEDB_URL")) |url| {
        if (cfg.vector_backend.lancedb_uri == null) cfg.vector_backend.backend = .lancedb_http;
        cfg.vector_backend.base_url = url;
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_LANCEDB_API_KEY")) |key| {
        cfg.vector_backend.api_key = key;
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_LANCEDB_TABLE")) |table| {
        cfg.vector_backend.collection = table;
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_ANALYTICS_BACKEND")) |backend| {
        cfg.analytics_backend.backend = analytics_runtime.BackendKind.parse(backend);
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_ANALYTICS_BASE_URL")) |url| {
        cfg.analytics_backend.base_url = url;
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_ANALYTICS_API_KEY")) |key| {
        cfg.analytics_backend.api_key = key;
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_ANALYTICS_TABLE")) |table| {
        cfg.analytics_backend.table = table;
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_ANALYTICS_TIMEOUT_SECS")) |secs| {
        cfg.analytics_backend.timeout_secs = std.fmt.parseInt(u32, secs, 10) catch cfg.analytics_backend.timeout_secs;
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_CLICKHOUSE_URL")) |url| {
        cfg.analytics_backend.backend = .clickhouse;
        cfg.analytics_backend.base_url = url;
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_CLICKHOUSE_API_KEY")) |key| {
        cfg.analytics_backend.api_key = key;
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_CLICKHOUSE_TABLE")) |table| {
        cfg.analytics_backend.backend = .clickhouse;
        cfg.analytics_backend.table = table;
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_LUCID_ENABLED")) |value| {
        defer allocator.free(value);
        cfg.lucid_projection.enabled = parseBool(value);
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_LUCID_COMMAND")) |command| {
        cfg.lucid_projection.command = command;
        cfg.lucid_projection.enabled = true;
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_LUCID_WORKSPACE")) |workspace| {
        cfg.lucid_projection.workspace_dir = workspace;
        cfg.lucid_projection.enabled = true;
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_LUCID_TOKEN_BUDGET")) |budget| {
        cfg.lucid_projection.token_budget = std.fmt.parseInt(usize, budget, 10) catch cfg.lucid_projection.token_budget;
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_LUCID_LOCAL_HIT_THRESHOLD")) |threshold| {
        cfg.lucid_projection.local_hit_threshold = std.fmt.parseInt(usize, threshold, 10) catch cfg.lucid_projection.local_hit_threshold;
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_LUCID_PROJECT_SCOPES")) |scopes| {
        cfg.lucid_projection.project_scopes_json = scopes;
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_LUCID_RESULT_SCOPE")) |scope| {
        cfg.lucid_projection.result_scope = scope;
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_LUCID_PERMISSIONS")) |permissions| {
        cfg.lucid_projection.permissions_json = permissions;
    } else |_| {}

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--version")) {
            std.debug.print("nullpantry v{s}\n", .{build_options.version});
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--help")) {
            printUsage();
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--host") and i + 1 < args.len) {
            i += 1;
            cfg.host = args[i];
        } else if (std.mem.eql(u8, arg, "--port") and i + 1 < args.len) {
            i += 1;
            cfg.port = try std.fmt.parseInt(u16, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--db") and i + 1 < args.len) {
            i += 1;
            cfg.db_path = args[i];
            cfg.backend = .sqlite;
        } else if (std.mem.eql(u8, arg, "--backend") and i + 1 < args.len) {
            i += 1;
            cfg.backend = store_mod.BackendKind.parse(args[i]);
        } else if (std.mem.eql(u8, arg, "--postgres-url") and i + 1 < args.len) {
            i += 1;
            cfg.postgres_url = args[i];
            cfg.backend = .postgres;
        } else if (std.mem.eql(u8, arg, "--token") and i + 1 < args.len) {
            i += 1;
            cfg.token = args[i];
            cfg.actor_scopes_json = "[\"public\"]";
            cfg.actor_capabilities_json = "[\"read\"]";
        } else if (std.mem.eql(u8, arg, "--token-principals") and i + 1 < args.len) {
            i += 1;
            cfg.token_principals_json = args[i];
        } else if (std.mem.eql(u8, arg, "--actor-scopes") and i + 1 < args.len) {
            i += 1;
            cfg.actor_scopes_json = args[i];
        } else if (std.mem.eql(u8, arg, "--actor-capabilities") and i + 1 < args.len) {
            i += 1;
            cfg.actor_capabilities_json = args[i];
        } else if (std.mem.eql(u8, arg, "--worker-scopes") and i + 1 < args.len) {
            i += 1;
            cfg.worker_scopes_json = args[i];
        } else if (std.mem.eql(u8, arg, "--worker-capabilities") and i + 1 < args.len) {
            i += 1;
            cfg.worker_capabilities_json = args[i];
        } else if (std.mem.eql(u8, arg, "--embedding-base-url") and i + 1 < args.len) {
            i += 1;
            cfg.embedding_base_url = args[i];
        } else if (std.mem.eql(u8, arg, "--embedding-api-key") and i + 1 < args.len) {
            i += 1;
            cfg.embedding_api_key = args[i];
        } else if (std.mem.eql(u8, arg, "--embedding-model") and i + 1 < args.len) {
            i += 1;
            cfg.embedding_model = args[i];
        } else if (std.mem.eql(u8, arg, "--embedding-provider") and i + 1 < args.len) {
            i += 1;
            cfg.embedding_provider = providers.EmbeddingProviderKind.parse(args[i]);
        } else if (std.mem.eql(u8, arg, "--embedding-dimensions") and i + 1 < args.len) {
            i += 1;
            cfg.embedding_dimensions = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--llm-base-url") and i + 1 < args.len) {
            i += 1;
            cfg.llm_base_url = args[i];
        } else if (std.mem.eql(u8, arg, "--llm-api-key") and i + 1 < args.len) {
            i += 1;
            cfg.llm_api_key = args[i];
        } else if (std.mem.eql(u8, arg, "--llm-model") and i + 1 < args.len) {
            i += 1;
            cfg.llm_model = args[i];
        } else if (std.mem.eql(u8, arg, "--provider-timeout-secs") and i + 1 < args.len) {
            i += 1;
            cfg.provider_timeout_secs = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--worker-interval-ms") and i + 1 < args.len) {
            i += 1;
            cfg.worker_interval_ms = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--trust-actor-headers")) {
            cfg.trust_actor_headers = true;
        } else if (std.mem.eql(u8, arg, "--agent-memory-backend") and i + 1 < args.len) {
            i += 1;
            cfg.agent_memory_backend = agent_memory_runtime.BackendKind.parse(args[i]);
        } else if (std.mem.eql(u8, arg, "--agent-memory-api-url") and i + 1 < args.len) {
            i += 1;
            cfg.api_agent_memory_config.base_url = args[i];
            cfg.agent_memory_backend = .api;
        } else if (std.mem.eql(u8, arg, "--agent-memory-api-token") and i + 1 < args.len) {
            i += 1;
            cfg.api_agent_memory_config.token = args[i];
        } else if (std.mem.eql(u8, arg, "--agent-memory-api-scopes") and i + 1 < args.len) {
            i += 1;
            cfg.api_agent_memory_config.actor_scopes_json = args[i];
        } else if (std.mem.eql(u8, arg, "--agent-memory-api-capabilities") and i + 1 < args.len) {
            i += 1;
            cfg.api_agent_memory_config.actor_capabilities_json = args[i];
        } else if (std.mem.eql(u8, arg, "--agent-memory-api-timeout-secs") and i + 1 < args.len) {
            i += 1;
            cfg.api_agent_memory_config.timeout_secs = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--agent-memory-api-max-response-bytes") and i + 1 < args.len) {
            i += 1;
            cfg.api_agent_memory_config.max_response_bytes = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--memory-lru-max-entries") and i + 1 < args.len) {
            i += 1;
            cfg.memory_config.max_entries = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--memory-lru-max-messages") and i + 1 < args.len) {
            i += 1;
            cfg.memory_config.max_messages = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--memory-lru-max-usage-entries") and i + 1 < args.len) {
            i += 1;
            cfg.memory_config.max_usage_entries = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--memory-lru-max-bytes") and i + 1 < args.len) {
            i += 1;
            cfg.memory_config.max_bytes = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--memory-lru-ttl-seconds") and i + 1 < args.len) {
            i += 1;
            cfg.memory_config.ttl_seconds = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--redis-url") and i + 1 < args.len) {
            i += 1;
            cfg.redis_config = try redis_mod.parseUrl(allocator, args[i]);
            cfg.agent_memory_backend = .redis;
        } else if (std.mem.eql(u8, arg, "--redis-key-prefix") and i + 1 < args.len) {
            i += 1;
            cfg.redis_config.key_prefix = args[i];
        } else if (std.mem.eql(u8, arg, "--redis-ttl-seconds") and i + 1 < args.len) {
            i += 1;
            cfg.redis_config.ttl_seconds = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--agent-memory-store") and i + 1 < args.len) {
            i += 1;
            const named = try parseAgentMemoryStoreSpec(allocator, args[i]);
            try appendAgentMemoryStoreConfig(allocator, &cfg, named);
        } else if (std.mem.eql(u8, arg, "--vector-backend") and i + 1 < args.len) {
            i += 1;
            cfg.vector_backend.backend = vector_runtime.BackendKind.parse(args[i]);
        } else if (std.mem.eql(u8, arg, "--vector-base-url") and i + 1 < args.len) {
            i += 1;
            cfg.vector_backend.base_url = args[i];
        } else if (std.mem.eql(u8, arg, "--vector-api-key") and i + 1 < args.len) {
            i += 1;
            cfg.vector_backend.api_key = args[i];
        } else if (std.mem.eql(u8, arg, "--vector-collection") and i + 1 < args.len) {
            i += 1;
            cfg.vector_backend.collection = args[i];
        } else if (std.mem.eql(u8, arg, "--vector-timeout-secs") and i + 1 < args.len) {
            i += 1;
            cfg.vector_backend.timeout_secs = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--lancedb-uri") and i + 1 < args.len) {
            i += 1;
            cfg.vector_backend.backend = .lancedb;
            cfg.vector_backend.lancedb_uri = args[i];
        } else if (std.mem.eql(u8, arg, "--lancedb-command") and i + 1 < args.len) {
            i += 1;
            cfg.vector_backend.backend = .lancedb;
            cfg.vector_backend.lancedb_command = args[i];
        } else if (std.mem.eql(u8, arg, "--lancedb-table") and i + 1 < args.len) {
            i += 1;
            cfg.vector_backend.collection = args[i];
        } else if (std.mem.eql(u8, arg, "--lancedb-url") and i + 1 < args.len) {
            i += 1;
            cfg.vector_backend.backend = .lancedb_http;
            cfg.vector_backend.base_url = args[i];
        } else if (std.mem.eql(u8, arg, "--analytics-backend") and i + 1 < args.len) {
            i += 1;
            cfg.analytics_backend.backend = analytics_runtime.BackendKind.parse(args[i]);
        } else if (std.mem.eql(u8, arg, "--analytics-base-url") and i + 1 < args.len) {
            i += 1;
            cfg.analytics_backend.base_url = args[i];
        } else if (std.mem.eql(u8, arg, "--analytics-api-key") and i + 1 < args.len) {
            i += 1;
            cfg.analytics_backend.api_key = args[i];
        } else if (std.mem.eql(u8, arg, "--analytics-table") and i + 1 < args.len) {
            i += 1;
            cfg.analytics_backend.table = args[i];
        } else if (std.mem.eql(u8, arg, "--analytics-timeout-secs") and i + 1 < args.len) {
            i += 1;
            cfg.analytics_backend.timeout_secs = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--lucid-enabled")) {
            cfg.lucid_projection.enabled = true;
        } else if (std.mem.eql(u8, arg, "--lucid-command") and i + 1 < args.len) {
            i += 1;
            cfg.lucid_projection.command = args[i];
            cfg.lucid_projection.enabled = true;
        } else if (std.mem.eql(u8, arg, "--lucid-workspace") and i + 1 < args.len) {
            i += 1;
            cfg.lucid_projection.workspace_dir = args[i];
            cfg.lucid_projection.enabled = true;
        } else if (std.mem.eql(u8, arg, "--lucid-token-budget") and i + 1 < args.len) {
            i += 1;
            cfg.lucid_projection.token_budget = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--lucid-local-hit-threshold") and i + 1 < args.len) {
            i += 1;
            cfg.lucid_projection.local_hit_threshold = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--lucid-project-scopes") and i + 1 < args.len) {
            i += 1;
            cfg.lucid_projection.project_scopes_json = args[i];
        } else if (std.mem.eql(u8, arg, "--lucid-result-scope") and i + 1 < args.len) {
            i += 1;
            cfg.lucid_projection.result_scope = args[i];
        } else if (std.mem.eql(u8, arg, "--lucid-permissions") and i + 1 < args.len) {
            i += 1;
            cfg.lucid_projection.permissions_json = args[i];
        }
    }
    return cfg;
}

fn parseAgentMemoryStoreConfigsJson(allocator: std.mem.Allocator, raw: []const u8) ![]agent_memory_runtime.NamedConfig {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidAgentMemoryStores;
    const items = parsed.value.array.items;
    var configs = try allocator.alloc(agent_memory_runtime.NamedConfig, items.len);
    errdefer allocator.free(configs);
    for (items, 0..) |item, i| {
        if (item != .object) return error.InvalidAgentMemoryStores;
        const name = jsonStringField(item.object, "name") orelse return error.InvalidAgentMemoryStores;
        const backend = jsonStringField(item.object, "backend") orelse "memory_lru";
        var config = agent_memory_runtime.Config{ .backend = try parseNamedAgentMemoryBackend(backend) };
        if (jsonStringField(item.object, "redis_url")) |url| {
            config.redis = try redis_mod.parseUrl(allocator, url);
            config.backend = .redis;
        }
        if (jsonStringField(item.object, "api_url") orelse jsonStringField(item.object, "base_url") orelse jsonStringField(item.object, "url")) |url| {
            config.api.base_url = try allocator.dupe(u8, url);
            config.backend = .api;
        }
        if (jsonStringField(item.object, "api_token") orelse jsonStringField(item.object, "token")) |token| {
            config.api.token = try allocator.dupe(u8, token);
        }
        if (jsonStringField(item.object, "api_scopes") orelse jsonStringField(item.object, "actor_scopes")) |scopes| {
            config.api.actor_scopes_json = try allocator.dupe(u8, scopes);
        }
        if (jsonStringField(item.object, "api_capabilities") orelse jsonStringField(item.object, "actor_capabilities")) |capabilities| {
            config.api.actor_capabilities_json = try allocator.dupe(u8, capabilities);
        }
        if (jsonIntField(item.object, "api_timeout_secs") orelse jsonIntField(item.object, "timeout_secs")) |secs| {
            if (config.backend == .api) config.api.timeout_secs = @intCast(@max(secs, 0));
        }
        if (jsonIntField(item.object, "api_max_response_bytes") orelse jsonIntField(item.object, "max_response_bytes")) |bytes| {
            if (config.backend == .api) config.api.max_response_bytes = @intCast(@max(bytes, 0));
        }
        if (jsonStringField(item.object, "redis_key_prefix")) |prefix| {
            config.redis.key_prefix = try allocator.dupe(u8, prefix);
        } else if (jsonStringField(item.object, "key_prefix")) |prefix| {
            config.redis.key_prefix = try allocator.dupe(u8, prefix);
        }
        if (config.backend == .memory_lru) {
            if (jsonIntField(item.object, "memory_max_entries") orelse jsonIntField(item.object, "max_entries")) |value| {
                config.memory.max_entries = @intCast(@max(value, 0));
            }
            if (jsonIntField(item.object, "memory_max_messages") orelse jsonIntField(item.object, "max_messages")) |value| {
                config.memory.max_messages = @intCast(@max(value, 0));
            }
            if (jsonIntField(item.object, "memory_max_usage_entries") orelse jsonIntField(item.object, "max_usage_entries")) |value| {
                config.memory.max_usage_entries = @intCast(@max(value, 0));
            }
            if (jsonIntField(item.object, "memory_max_bytes") orelse jsonIntField(item.object, "max_bytes")) |value| {
                config.memory.max_bytes = @intCast(@max(value, 0));
            }
            if (jsonIntField(item.object, "memory_ttl_seconds")) |ttl| {
                config.memory.ttl_seconds = @intCast(@max(ttl, 0));
            }
        }
        if (jsonIntField(item.object, "redis_ttl_seconds")) |ttl| {
            config.redis.ttl_seconds = @intCast(@max(ttl, 0));
        } else if (jsonIntField(item.object, "ttl_seconds")) |ttl| {
            if (config.backend == .redis) {
                config.redis.ttl_seconds = @intCast(@max(ttl, 0));
            } else if (config.backend == .memory_lru) {
                config.memory.ttl_seconds = @intCast(@max(ttl, 0));
            }
        }
        configs[i] = .{ .name = try allocator.dupe(u8, name), .config = config };
    }
    return configs;
}

fn parseAgentMemoryStoreSpec(allocator: std.mem.Allocator, raw: []const u8) !agent_memory_runtime.NamedConfig {
    const eq = std.mem.indexOfScalar(u8, raw, '=') orelse return error.InvalidAgentMemoryStore;
    const name = std.mem.trim(u8, raw[0..eq], " \t\r\n");
    const value = std.mem.trim(u8, raw[eq + 1 ..], " \t\r\n");
    if (name.len == 0 or value.len == 0) return error.InvalidAgentMemoryStore;
    var config = agent_memory_runtime.Config{ .backend = undefined };
    if (std.mem.startsWith(u8, value, "redis://")) {
        config.redis = try redis_mod.parseUrl(allocator, value);
        config.backend = .redis;
    } else if (std.mem.startsWith(u8, value, "http://") or std.mem.startsWith(u8, value, "https://")) {
        config.api.base_url = try allocator.dupe(u8, value);
        config.backend = .api;
    } else {
        config.backend = try parseNamedAgentMemoryBackend(value);
    }
    return .{ .name = try allocator.dupe(u8, name), .config = config };
}

fn parseNamedAgentMemoryBackend(raw: []const u8) !agent_memory_runtime.BackendKind {
    if (std.ascii.eqlIgnoreCase(raw, "none")) return .none;
    if (std.ascii.eqlIgnoreCase(raw, "memory")) return .memory_lru;
    if (std.ascii.eqlIgnoreCase(raw, "memory_lru")) return .memory_lru;
    if (std.ascii.eqlIgnoreCase(raw, "in_memory")) return .memory_lru;
    if (std.ascii.eqlIgnoreCase(raw, "redis")) return .redis;
    if (std.ascii.eqlIgnoreCase(raw, "api")) return .api;
    if (std.ascii.eqlIgnoreCase(raw, "http")) return .api;
    if (std.ascii.eqlIgnoreCase(raw, "nullpantry_api")) return .api;
    return error.InvalidAgentMemoryStore;
}

fn appendAgentMemoryStoreConfig(allocator: std.mem.Allocator, cfg: *RuntimeConfig, named: agent_memory_runtime.NamedConfig) !void {
    const previous = cfg.agent_memory_store_configs;
    var next = try allocator.alloc(agent_memory_runtime.NamedConfig, previous.len + 1);
    for (previous, 0..) |existing, i| next[i] = existing;
    next[previous.len] = named;
    cfg.agent_memory_store_configs = next;
    if (previous.len > 0) allocator.free(previous);
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
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

fn parseBool(raw: []const u8) bool {
    const value = std.mem.trim(u8, raw, " \t\r\n");
    return std.ascii.eqlIgnoreCase(value, "1") or
        std.ascii.eqlIgnoreCase(value, "true") or
        std.ascii.eqlIgnoreCase(value, "yes") or
        std.ascii.eqlIgnoreCase(value, "on");
}

fn printUsage() void {
    std.debug.print(
        \\Usage: nullpantry [--host HOST] [--port PORT] [--db PATH] [--token TOKEN] [--token-principals JSON] [--actor-scopes JSON] [--actor-capabilities JSON] [--worker-scopes JSON] [--worker-capabilities JSON] [--trust-actor-headers]
        \\       nullpantry --backend postgres --postgres-url URL [--token TOKEN|--token-principals JSON]
        \\       nullpantry --agent-memory-backend redis --redis-url redis://:pass@host:6379/0
        \\       nullpantry --agent-memory-backend api --agent-memory-api-url https://pantry.internal --agent-memory-api-token TOKEN
        \\       nullpantry --vector-backend qdrant --vector-base-url http://127.0.0.1:6333 --vector-collection nullpantry_vectors
        \\       nullpantry --vector-backend lancedb --lancedb-uri .nullpantry/lancedb --lancedb-table nullpantry_vectors
        \\       nullpantry --analytics-backend clickhouse --analytics-base-url http://127.0.0.1:8123 --analytics-table nullpantry_events
        \\       nullpantry --lucid-enabled --lucid-workspace /path/to/workspace
        \\
        \\Environment:
        \\  NULLPANTRY_TOKEN
        \\  NULLPANTRY_TOKEN_PRINCIPALS
        \\  NULLPANTRY_DATABASE_URL
        \\  NULLPANTRY_SCOPES
        \\  NULLPANTRY_CAPABILITIES
        \\  NULLPANTRY_WORKER_SCOPES
        \\  NULLPANTRY_WORKER_CAPABILITIES
        \\  NULLPANTRY_EMBEDDING_BASE_URL
        \\  NULLPANTRY_EMBEDDING_API_KEY
        \\  NULLPANTRY_EMBEDDING_MODEL
        \\  NULLPANTRY_EMBEDDING_PROVIDER
        \\  NULLPANTRY_EMBEDDING_DIMENSIONS
        \\  NULLPANTRY_LLM_BASE_URL
        \\  NULLPANTRY_LLM_API_KEY
        \\  NULLPANTRY_LLM_MODEL
        \\  NULLPANTRY_PROVIDER_TIMEOUT_SECS
        \\  NULLPANTRY_WORKER_INTERVAL_MS
        \\  NULLPANTRY_TRUST_ACTOR_HEADERS
        \\  NULLPANTRY_AGENT_MEMORY_BACKEND
        \\  NULLPANTRY_AGENT_MEMORY_API_URL
        \\  NULLPANTRY_AGENT_MEMORY_API_TOKEN
        \\  NULLPANTRY_AGENT_MEMORY_API_SCOPES
        \\  NULLPANTRY_AGENT_MEMORY_API_CAPABILITIES
        \\  NULLPANTRY_AGENT_MEMORY_API_TIMEOUT_SECS
        \\  NULLPANTRY_AGENT_MEMORY_API_MAX_RESPONSE_BYTES
        \\  NULLPANTRY_AGENT_MEMORY_STORES
        \\  NULLPANTRY_MEMORY_LRU_MAX_ENTRIES
        \\  NULLPANTRY_MEMORY_LRU_MAX_MESSAGES
        \\  NULLPANTRY_MEMORY_LRU_MAX_USAGE_ENTRIES
        \\  NULLPANTRY_MEMORY_LRU_MAX_BYTES
        \\  NULLPANTRY_MEMORY_LRU_TTL_SECONDS
        \\  NULLPANTRY_REDIS_URL
        \\  NULLPANTRY_REDIS_KEY_PREFIX
        \\  NULLPANTRY_REDIS_TTL_SECONDS
        \\  NULLPANTRY_VECTOR_BACKEND
        \\  NULLPANTRY_VECTOR_BASE_URL
        \\  NULLPANTRY_VECTOR_API_KEY
        \\  NULLPANTRY_VECTOR_COLLECTION
        \\  NULLPANTRY_VECTOR_TIMEOUT_SECS
        \\  NULLPANTRY_QDRANT_URL
        \\  NULLPANTRY_QDRANT_API_KEY
        \\  NULLPANTRY_QDRANT_COLLECTION
        \\  NULLPANTRY_LANCEDB_URI
        \\  NULLPANTRY_LANCEDB_COMMAND
        \\  NULLPANTRY_LANCEDB_URL
        \\  NULLPANTRY_LANCEDB_API_KEY
        \\  NULLPANTRY_LANCEDB_TABLE
        \\  NULLPANTRY_ANALYTICS_BACKEND
        \\  NULLPANTRY_ANALYTICS_BASE_URL
        \\  NULLPANTRY_ANALYTICS_API_KEY
        \\  NULLPANTRY_ANALYTICS_TABLE
        \\  NULLPANTRY_ANALYTICS_TIMEOUT_SECS
        \\  NULLPANTRY_CLICKHOUSE_URL
        \\  NULLPANTRY_CLICKHOUSE_API_KEY
        \\  NULLPANTRY_CLICKHOUSE_TABLE
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

test "token auth does not downgrade background worker principal" {
    const args = [_][:0]const u8{ "nullpantry", "--token", "test-token" };
    const cfg = try parseArgs(std.testing.allocator, &args);

    try std.testing.expectEqualStrings("[\"public\"]", cfg.actor_scopes_json);
    try std.testing.expectEqualStrings("[\"read\"]", cfg.actor_capabilities_json);
    try std.testing.expectEqualStrings("[\"admin\"]", cfg.worker_scopes_json);
    try std.testing.expect(std.mem.indexOf(u8, cfg.worker_capabilities_json, "\"write\"") != null);
}

test "worker principal can be narrowed explicitly" {
    const args = [_][:0]const u8{
        "nullpantry",
        "--worker-scopes",
        "[\"project:nullpantry\"]",
        "--worker-capabilities",
        "[\"read\",\"write\",\"verify\"]",
    };
    const cfg = try parseArgs(std.testing.allocator, &args);

    try std.testing.expectEqualStrings("[\"project:nullpantry\"]", cfg.worker_scopes_json);
    try std.testing.expectEqualStrings("[\"read\",\"write\",\"verify\"]", cfg.worker_capabilities_json);
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
    const cfg = try parseArgs(std.testing.allocator, &args);
    defer std.testing.allocator.free(cfg.redis_config.host);

    try std.testing.expectEqual(agent_memory_runtime.BackendKind.redis, cfg.agent_memory_backend);
    try std.testing.expectEqualStrings("127.0.0.1", cfg.redis_config.host);
    try std.testing.expectEqual(@as(u8, 2), cfg.redis_config.db_index);
    try std.testing.expectEqualStrings("np-test", cfg.redis_config.key_prefix);
    try std.testing.expectEqual(@as(u32, 60), cfg.redis_config.ttl_seconds.?);
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
    const cfg = try parseArgs(std.testing.allocator, &args);

    try std.testing.expectEqual(agent_memory_runtime.BackendKind.memory_lru, cfg.agent_memory_backend);
    try std.testing.expectEqual(@as(usize, 64), cfg.memory_config.max_entries);
    try std.testing.expectEqual(@as(usize, 128), cfg.memory_config.max_messages);
    try std.testing.expectEqual(@as(usize, 16), cfg.memory_config.max_usage_entries);
    try std.testing.expectEqual(@as(usize, 4096), cfg.memory_config.max_bytes);
    try std.testing.expectEqual(@as(u32, 300), cfg.memory_config.ttl_seconds.?);
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
        "--agent-memory-api-scopes",
        "[\"project:nullpantry\"]",
        "--agent-memory-api-capabilities",
        "[\"read\",\"write\"]",
        "--agent-memory-api-timeout-secs",
        "9",
        "--agent-memory-api-max-response-bytes",
        "123456",
    };
    const cfg = try parseArgs(std.testing.allocator, &args);

    try std.testing.expectEqual(agent_memory_runtime.BackendKind.api, cfg.agent_memory_backend);
    try std.testing.expectEqualStrings("https://pantry.example/v1", cfg.api_agent_memory_config.base_url.?);
    try std.testing.expectEqualStrings("gateway-token", cfg.api_agent_memory_config.token.?);
    try std.testing.expectEqualStrings("[\"project:nullpantry\"]", cfg.api_agent_memory_config.actor_scopes_json);
    try std.testing.expectEqualStrings("[\"read\",\"write\"]", cfg.api_agent_memory_config.actor_capabilities_json);
    try std.testing.expectEqual(@as(u32, 9), cfg.api_agent_memory_config.timeout_secs);
    try std.testing.expectEqual(@as(usize, 123456), cfg.api_agent_memory_config.max_response_bytes);
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
    };
    const cfg = try parseArgs(std.testing.allocator, &args);
    defer std.testing.allocator.free(cfg.agent_memory_store_configs);
    defer std.testing.allocator.free(cfg.agent_memory_store_configs[0].name);
    defer std.testing.allocator.free(cfg.agent_memory_store_configs[1].name);
    defer std.testing.allocator.free(cfg.agent_memory_store_configs[1].config.redis.host);
    defer std.testing.allocator.free(cfg.agent_memory_store_configs[2].name);
    defer std.testing.allocator.free(cfg.agent_memory_store_configs[2].config.api.base_url.?);

    try std.testing.expectEqual(@as(usize, 3), cfg.agent_memory_store_configs.len);
    try std.testing.expectEqualStrings("scratch", cfg.agent_memory_store_configs[0].name);
    try std.testing.expectEqual(agent_memory_runtime.BackendKind.memory_lru, cfg.agent_memory_store_configs[0].config.backend);
    try std.testing.expectEqualStrings("shared", cfg.agent_memory_store_configs[1].name);
    try std.testing.expectEqual(agent_memory_runtime.BackendKind.redis, cfg.agent_memory_store_configs[1].config.backend);
    try std.testing.expectEqual(@as(u8, 4), cfg.agent_memory_store_configs[1].config.redis.db_index);
    try std.testing.expectEqualStrings("remote", cfg.agent_memory_store_configs[2].name);
    try std.testing.expectEqual(agent_memory_runtime.BackendKind.api, cfg.agent_memory_store_configs[2].config.backend);
    try std.testing.expectEqualStrings("https://pantry.example", cfg.agent_memory_store_configs[2].config.api.base_url.?);

    const parsed = try parseAgentMemoryStoreConfigsJson(std.testing.allocator,
        \\[
        \\  {"name":"fast","backend":"memory_lru","max_entries":32,"max_messages":64,"max_usage_entries":8,"max_bytes":2048,"ttl_seconds":120},
        \\  {"name":"team","redis_url":"redis://127.0.0.1:6379/5","key_prefix":"team-memory","ttl_seconds":30},
        \\  {"name":"remote","api_url":"https://pantry.example/v1","api_token":"gateway","api_timeout_secs":11,"api_max_response_bytes":65536}
        \\]
    );
    defer std.testing.allocator.free(parsed);
    defer std.testing.allocator.free(parsed[0].name);
    defer std.testing.allocator.free(parsed[1].name);
    defer std.testing.allocator.free(parsed[1].config.redis.host);
    defer std.testing.allocator.free(parsed[1].config.redis.key_prefix);
    defer std.testing.allocator.free(parsed[2].name);
    defer std.testing.allocator.free(parsed[2].config.api.base_url.?);
    defer std.testing.allocator.free(parsed[2].config.api.token.?);

    try std.testing.expectEqual(@as(usize, 3), parsed.len);
    try std.testing.expectEqualStrings("fast", parsed[0].name);
    try std.testing.expectEqual(agent_memory_runtime.BackendKind.memory_lru, parsed[0].config.backend);
    try std.testing.expectEqual(@as(usize, 32), parsed[0].config.memory.max_entries);
    try std.testing.expectEqual(@as(usize, 64), parsed[0].config.memory.max_messages);
    try std.testing.expectEqual(@as(usize, 8), parsed[0].config.memory.max_usage_entries);
    try std.testing.expectEqual(@as(usize, 2048), parsed[0].config.memory.max_bytes);
    try std.testing.expectEqual(@as(u32, 120), parsed[0].config.memory.ttl_seconds.?);
    try std.testing.expectEqualStrings("team", parsed[1].name);
    try std.testing.expectEqual(agent_memory_runtime.BackendKind.redis, parsed[1].config.backend);
    try std.testing.expectEqualStrings("team-memory", parsed[1].config.redis.key_prefix);
    try std.testing.expectEqual(@as(u32, 30), parsed[1].config.redis.ttl_seconds.?);
    try std.testing.expectEqualStrings("remote", parsed[2].name);
    try std.testing.expectEqual(agent_memory_runtime.BackendKind.api, parsed[2].config.backend);
    try std.testing.expectEqualStrings("https://pantry.example/v1", parsed[2].config.api.base_url.?);
    try std.testing.expectEqualStrings("gateway", parsed[2].config.api.token.?);
    try std.testing.expectEqual(@as(u32, 11), parsed[2].config.api.timeout_secs);
    try std.testing.expectEqual(@as(usize, 65536), parsed[2].config.api.max_response_bytes);

    try std.testing.expectError(error.InvalidAgentMemoryStore, parseAgentMemoryStoreSpec(std.testing.allocator, "bad=native"));
    try std.testing.expectError(error.InvalidAgentMemoryStore, parseAgentMemoryStoreSpec(std.testing.allocator, "bad=typo"));
}

test "external vector backend can be configured from args" {
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
    };
    const cfg = try parseArgs(std.testing.allocator, &args);

    try std.testing.expectEqual(vector_runtime.BackendKind.qdrant, cfg.vector_backend.backend);
    try std.testing.expectEqualStrings("http://127.0.0.1:6333", cfg.vector_backend.base_url.?);
    try std.testing.expectEqualStrings("np_vectors", cfg.vector_backend.collection);
    try std.testing.expectEqual(@as(u32, 7), cfg.vector_backend.timeout_secs);
}

test "lancedb sdk vector backend can be configured from args" {
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
    const cfg = try parseArgs(std.testing.allocator, &args);

    try std.testing.expectEqual(vector_runtime.BackendKind.lancedb, cfg.vector_backend.backend);
    try std.testing.expectEqualStrings(".nullpantry/lancedb", cfg.vector_backend.lancedb_uri.?);
    try std.testing.expectEqualStrings("python3", cfg.vector_backend.lancedb_command);
    try std.testing.expectEqualStrings("np_vectors", cfg.vector_backend.collection);
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
    };
    const cfg = try parseArgs(std.testing.allocator, &args);

    try std.testing.expectEqual(analytics_runtime.BackendKind.clickhouse, cfg.analytics_backend.backend);
    try std.testing.expectEqualStrings("http://127.0.0.1:8123", cfg.analytics_backend.base_url.?);
    try std.testing.expectEqualStrings("np_events", cfg.analytics_backend.table);
    try std.testing.expectEqual(@as(u32, 9), cfg.analytics_backend.timeout_secs);
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
    const cfg = try parseArgs(std.testing.allocator, &args);

    try std.testing.expect(cfg.lucid_projection.isEnabled());
    try std.testing.expectEqualStrings("lucid-test", cfg.lucid_projection.command);
    try std.testing.expectEqualStrings("/tmp/nullpantry", cfg.lucid_projection.workspace_dir);
    try std.testing.expectEqual(@as(usize, 512), cfg.lucid_projection.token_budget);
    try std.testing.expectEqual(@as(usize, 2), cfg.lucid_projection.local_hit_threshold);
    try std.testing.expectEqualStrings("[\"admin\"]", cfg.lucid_projection.project_scopes_json);
    try std.testing.expectEqualStrings("project:nullpantry", cfg.lucid_projection.result_scope);
    try std.testing.expectEqualStrings("[\"team:platform\"]", cfg.lucid_projection.permissions_json);
}

fn readHttpRequest(allocator: std.mem.Allocator, stream: *std.Io.net.Stream, max_bytes: usize) !?[]u8 {
    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    defer buffer.deinit(allocator);

    var read_buffer: [read_chunk_size]u8 = undefined;
    var reader = stream.reader(compat.io(), &read_buffer);
    var header_lines: usize = 0;
    while (true) {
        const line = reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => return if (buffer.items.len == 0) null else error.UnexpectedEof,
            else => |e| return e,
        };
        if (buffer.items.len + line.len > max_bytes) return error.RequestTooLarge;
        if (buffer.items.len + line.len > max_header_bytes) return error.RequestHeaderTooLarge;
        header_lines += 1;
        if (header_lines > max_header_lines) return error.TooManyHeaders;
        try buffer.appendSlice(allocator, line);
        if (std.mem.endsWith(u8, buffer.items, "\r\n\r\n")) break;
    }

    const content_length = try parseContentLength(buffer.items);
    if (buffer.items.len + content_length > max_bytes) return error.RequestTooLarge;
    if (content_length > 0) {
        const body = try allocator.alloc(u8, content_length);
        try reader.interface.readSliceAll(body);
        try buffer.appendSlice(allocator, body);
    }
    return try buffer.toOwnedSlice(allocator);
}

fn parseContentLength(header_text: []const u8) !usize {
    var content_length: usize = 0;
    var saw_content_length = false;
    var lines = std.mem.splitSequence(u8, header_text, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(key, "Content-Length")) {
            if (saw_content_length) return error.DuplicateContentLength;
            if (value.len == 0) return error.InvalidContentLength;
            content_length = std.fmt.parseInt(usize, value, 10) catch return error.InvalidContentLength;
            saw_content_length = true;
        } else if (std.ascii.eqlIgnoreCase(key, "Transfer-Encoding")) {
            if (!std.ascii.eqlIgnoreCase(value, "identity")) return error.UnsupportedTransferEncoding;
        }
    }
    return content_length;
}

test "http header parser rejects ambiguous body framing" {
    try std.testing.expectEqual(@as(usize, 5), try parseContentLength("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\n"));
    try std.testing.expectError(error.InvalidContentLength, parseContentLength("POST / HTTP/1.1\r\nContent-Length: nope\r\n\r\n"));
    try std.testing.expectError(error.DuplicateContentLength, parseContentLength("POST / HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\n"));
    try std.testing.expectError(error.UnsupportedTransferEncoding, parseContentLength("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"));
}

test {
    _ = @import("ids.zig");
    _ = @import("json_util.zig");
    _ = @import("domain.zig");
    _ = @import("engines.zig");
    _ = @import("vector.zig");
    _ = @import("vector_runtime.zig");
    _ = @import("analytics_runtime.zig");
    _ = @import("lucid_runtime.zig");
    _ = @import("retrieval.zig");
    _ = @import("lifecycle.zig");
    _ = @import("providers.zig");
    _ = @import("redis.zig");
    _ = @import("agent_memory_runtime.zig");
    _ = @import("agent_memory_reducer.zig");
    _ = @import("markdown_adapter.zig");
    _ = @import("markdown_filesystem.zig");
    _ = @import("artifacts.zig");
    _ = @import("extraction.zig");
    _ = @import("worker.zig");
    _ = @import("store.zig");
    _ = @import("api.zig");
}
