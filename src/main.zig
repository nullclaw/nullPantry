const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const compat = @import("compat.zig");
const api = @import("api.zig");
const ids = @import("ids.zig");
const store_mod = @import("store.zig");
const worker = @import("worker.zig");

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
    embedding_dimensions: usize = 64,
    llm_base_url: ?[]const u8 = null,
    llm_api_key: ?[]const u8 = null,
    llm_model: ?[]const u8 = null,
    provider_timeout_secs: u32 = 30,
    worker_interval_ms: u64 = 5000,
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

    var store = switch (cfg.backend) {
        .sqlite => try store_mod.Store.initSQLite(allocator, cfg.db_path),
        .postgres => try store_mod.Store.initPostgres(allocator, cfg.postgres_url orelse return error.MissingPostgresUrl),
    };
    defer store.deinit();

    const addr = try std.Io.net.IpAddress.resolve(compat.io(), cfg.host, cfg.port);
    var server = try addr.listen(compat.io(), .{ .reuse_address = true });
    defer server.deinit(compat.io());

    std.debug.print("nullpantry v{s}\n", .{build_options.version});
    std.debug.print("listening on http://{s}:{d}\n", .{ cfg.host, cfg.port });
    std.debug.print("storage backend: {s}\n", .{@tagName(cfg.backend)});

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
        .embedding_dimensions = state.cfg.embedding_dimensions,
        .llm_base_url = state.cfg.llm_base_url,
        .llm_api_key = state.cfg.llm_api_key,
        .llm_model = state.cfg.llm_model,
        .provider_timeout_secs = state.cfg.provider_timeout_secs,
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
            .embedding_dimensions = state.cfg.embedding_dimensions,
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
        }
    }
    return cfg;
}

fn printUsage() void {
    std.debug.print(
        \\Usage: nullpantry [--host HOST] [--port PORT] [--db PATH] [--token TOKEN] [--token-principals JSON] [--actor-scopes JSON] [--actor-capabilities JSON] [--worker-scopes JSON] [--worker-capabilities JSON]
        \\       nullpantry --backend postgres --postgres-url URL [--token TOKEN|--token-principals JSON]
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
        \\  NULLPANTRY_EMBEDDING_DIMENSIONS
        \\  NULLPANTRY_LLM_BASE_URL
        \\  NULLPANTRY_LLM_API_KEY
        \\  NULLPANTRY_LLM_MODEL
        \\  NULLPANTRY_PROVIDER_TIMEOUT_SECS
        \\  NULLPANTRY_WORKER_INTERVAL_MS
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

    const header_text = buffer.items;
    var content_length: usize = 0;
    var lines = std.mem.splitSequence(u8, header_text, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        if (std.ascii.eqlIgnoreCase(key, "Content-Length")) {
            const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
            content_length = std.fmt.parseInt(usize, value, 10) catch 0;
        }
    }
    if (buffer.items.len + content_length > max_bytes) return error.RequestTooLarge;
    if (content_length > 0) {
        const body = try allocator.alloc(u8, content_length);
        try reader.interface.readSliceAll(body);
        try buffer.appendSlice(allocator, body);
    }
    return try buffer.toOwnedSlice(allocator);
}

test {
    _ = @import("ids.zig");
    _ = @import("json_util.zig");
    _ = @import("domain.zig");
    _ = @import("engines.zig");
    _ = @import("vector.zig");
    _ = @import("retrieval.zig");
    _ = @import("lifecycle.zig");
    _ = @import("providers.zig");
    _ = @import("artifacts.zig");
    _ = @import("extraction.zig");
    _ = @import("worker.zig");
    _ = @import("store.zig");
    _ = @import("api.zig");
}
