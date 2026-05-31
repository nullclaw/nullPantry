const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat.zig");
const json = @import("json_util.zig");
const ids = @import("ids.zig");
const net_security = @import("net_security.zig");

pub const max_vector_backend_response_bytes: usize = 8 * 1024 * 1024;

pub const BackendKind = enum {
    local,
    qdrant,
    lancedb,
    lancedb_http,

    pub fn parse(raw: []const u8) BackendKind {
        if (std.ascii.eqlIgnoreCase(raw, "qdrant")) return .qdrant;
        if (std.ascii.eqlIgnoreCase(raw, "lancedb")) return .lancedb;
        if (std.ascii.eqlIgnoreCase(raw, "lancedb_http")) return .lancedb_http;
        if (std.ascii.eqlIgnoreCase(raw, "lancedb-compatible")) return .lancedb_http;
        return .local;
    }

    pub fn name(self: BackendKind) []const u8 {
        return switch (self) {
            .local => "local",
            .qdrant => "qdrant",
            .lancedb => "lancedb",
            .lancedb_http => "lancedb_http",
        };
    }
};

pub const Config = struct {
    backend: BackendKind = .local,
    base_url: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    collection: []const u8 = "nullpantry_vectors",
    lancedb_uri: ?[]const u8 = null,
    lancedb_command: []const u8 = "python3",
    timeout_secs: u32 = 30,
    allow_insecure_http: bool = false,
    circuit_breaker_enabled: bool = true,
    circuit_breaker_threshold: u32 = 3,
    circuit_breaker_cooldown_ms: u64 = 30_000,

    pub fn externalEnabled(self: Config) bool {
        if (self.collection.len == 0) return false;
        return switch (self.backend) {
            .local => false,
            .qdrant, .lancedb_http => self.base_url != null,
            .lancedb => self.lancedb_uri != null and self.lancedb_command.len > 0,
        };
    }
};

pub const CircuitState = enum {
    closed,
    open,
    half_open,
};

pub const CircuitBreaker = struct {
    enabled: bool = true,
    state: CircuitState = .closed,
    failure_count: u32 = 0,
    threshold: u32 = 3,
    cooldown_ms: u64 = 30_000,
    opened_at_ms: i64 = 0,
    half_open_probe_sent: bool = false,

    pub fn init(cfg: Config) CircuitBreaker {
        return .{
            .enabled = cfg.circuit_breaker_enabled,
            .threshold = cfg.circuit_breaker_threshold,
            .cooldown_ms = cfg.circuit_breaker_cooldown_ms,
        };
    }

    pub fn allow(self: *CircuitBreaker) bool {
        if (!self.enabled) return true;
        switch (self.state) {
            .closed => return true,
            .open => {
                const now = ids.nowMs();
                if (self.cooldown_ms == 0 or now - self.opened_at_ms >= @as(i64, @intCast(self.cooldown_ms))) {
                    self.state = .half_open;
                    self.half_open_probe_sent = true;
                    return true;
                }
                return false;
            },
            .half_open => {
                if (self.half_open_probe_sent) return false;
                self.half_open_probe_sent = true;
                return true;
            },
        }
    }

    pub fn recordSuccess(self: *CircuitBreaker) void {
        if (!self.enabled) return;
        self.state = .closed;
        self.failure_count = 0;
        self.opened_at_ms = 0;
        self.half_open_probe_sent = false;
    }

    pub fn recordFailure(self: *CircuitBreaker) void {
        if (!self.enabled) return;
        self.failure_count +|= 1;
        if (self.state == .half_open or self.failure_count >= self.threshold) {
            self.state = .open;
            self.opened_at_ms = ids.nowMs();
            self.half_open_probe_sent = false;
        }
    }
};

pub const Runtime = struct {
    circuit_breaker: CircuitBreaker = .{},

    pub fn init(cfg: Config) Runtime {
        return .{ .circuit_breaker = CircuitBreaker.init(cfg) };
    }

    pub fn allow(self: *Runtime) bool {
        return self.circuit_breaker.allow();
    }

    pub fn recordSuccess(self: *Runtime) void {
        self.circuit_breaker.recordSuccess();
    }

    pub fn recordFailure(self: *Runtime) void {
        self.circuit_breaker.recordFailure();
    }

    pub fn stateName(self: Runtime) []const u8 {
        return @tagName(self.circuit_breaker.state);
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
    embedding_json: []const u8,
    model: ?[]const u8,
    dimensions: i64,
};

pub const Candidate = struct {
    vector_id: []const u8,
    score: f32,
};

pub fn freeCandidates(allocator: std.mem.Allocator, candidates: []Candidate) void {
    for (candidates) |candidate| allocator.free(candidate.vector_id);
    allocator.free(candidates);
}

pub fn upsert(allocator: std.mem.Allocator, cfg: Config, input: UpsertInput) !void {
    if (!cfg.externalEnabled()) return;
    return switch (cfg.backend) {
        .local => {},
        .qdrant => try qdrantUpsert(allocator, cfg, input),
        .lancedb => try lancedbSdkUpsert(allocator, cfg, input),
        .lancedb_http => try lancedbHttpUpsert(allocator, cfg, input),
    };
}

pub fn upsertWithRuntime(allocator: std.mem.Allocator, cfg: Config, runtime: ?*Runtime, input: UpsertInput) !void {
    if (!cfg.externalEnabled()) return;
    if (runtime) |rt| {
        if (!rt.allow()) return error.VectorBackendCircuitOpen;
        upsert(allocator, cfg, input) catch |err| {
            rt.recordFailure();
            return err;
        };
        rt.recordSuccess();
        return;
    }
    return upsert(allocator, cfg, input);
}

pub fn search(allocator: std.mem.Allocator, cfg: Config, embedding_json: []const u8, limit: usize) ![]Candidate {
    if (!cfg.externalEnabled()) return allocator.alloc(Candidate, 0);
    return switch (cfg.backend) {
        .local => allocator.alloc(Candidate, 0),
        .qdrant => qdrantSearch(allocator, cfg, embedding_json, limit),
        .lancedb => lancedbSdkSearch(allocator, cfg, embedding_json, limit),
        .lancedb_http => lancedbHttpSearch(allocator, cfg, embedding_json, limit),
    };
}

pub fn searchWithRuntime(allocator: std.mem.Allocator, cfg: Config, runtime: ?*Runtime, embedding_json: []const u8, limit: usize) ![]Candidate {
    if (!cfg.externalEnabled()) return allocator.alloc(Candidate, 0);
    if (runtime) |rt| {
        if (!rt.allow()) return error.VectorBackendCircuitOpen;
        const candidates = search(allocator, cfg, embedding_json, limit) catch |err| {
            rt.recordFailure();
            return err;
        };
        rt.recordSuccess();
        return candidates;
    }
    return search(allocator, cfg, embedding_json, limit);
}

pub fn delete(allocator: std.mem.Allocator, cfg: Config, vector_id: []const u8) !void {
    if (!cfg.externalEnabled()) return;
    if (vector_id.len == 0) return error.InvalidVectorId;
    return switch (cfg.backend) {
        .local => {},
        .qdrant => try qdrantDelete(allocator, cfg, vector_id),
        .lancedb => try lancedbSdkDelete(allocator, cfg, vector_id),
        .lancedb_http => try lancedbHttpDelete(allocator, cfg, vector_id),
    };
}

pub fn deleteWithRuntime(allocator: std.mem.Allocator, cfg: Config, runtime: ?*Runtime, vector_id: []const u8) !void {
    if (!cfg.externalEnabled()) return;
    if (runtime) |rt| {
        if (!rt.allow()) return error.VectorBackendCircuitOpen;
        delete(allocator, cfg, vector_id) catch |err| {
            rt.recordFailure();
            return err;
        };
        rt.recordSuccess();
        return;
    }
    return delete(allocator, cfg, vector_id);
}

pub fn reset(allocator: std.mem.Allocator, cfg: Config) !void {
    if (!cfg.externalEnabled()) return;
    return switch (cfg.backend) {
        .local => {},
        .qdrant => try qdrantReset(allocator, cfg),
        .lancedb => try lancedbSdkReset(allocator, cfg),
        .lancedb_http => try lancedbHttpReset(allocator, cfg),
    };
}

pub fn resetWithRuntime(allocator: std.mem.Allocator, cfg: Config, runtime: ?*Runtime) !void {
    if (!cfg.externalEnabled()) return;
    if (runtime) |rt| {
        if (!rt.allow()) return error.VectorBackendCircuitOpen;
        reset(allocator, cfg) catch |err| {
            rt.recordFailure();
            return err;
        };
        rt.recordSuccess();
        return;
    }
    return reset(allocator, cfg);
}

fn qdrantUpsert(allocator: std.mem.Allocator, cfg: Config, input: UpsertInput) !void {
    try qdrantEnsureCollection(allocator, cfg, input.dimensions);
    const path = try std.fmt.allocPrint(allocator, "/collections/{s}/points?wait=true", .{cfg.collection});
    defer allocator.free(path);
    const url = try backendUrl(allocator, cfg, path);
    defer allocator.free(url);
    const payload = try qdrantUpsertPayload(allocator, input);
    defer allocator.free(payload);
    const response = try requestJson(allocator, .PUT, url, cfg.api_key, cfg.timeout_secs, payload);
    defer allocator.free(response);
    try ensureBackendOk(response);
}

fn qdrantEnsureCollection(allocator: std.mem.Allocator, cfg: Config, dimensions: i64) !void {
    if (dimensions <= 0) return error.InvalidVectorDimensions;
    const path = try std.fmt.allocPrint(allocator, "/collections/{s}", .{cfg.collection});
    defer allocator.free(path);
    const url = try backendUrl(allocator, cfg, path);
    defer allocator.free(url);
    const body = try std.fmt.allocPrint(allocator, "{{\"vectors\":{{\"size\":{d},\"distance\":\"Cosine\"}}}}", .{dimensions});
    defer allocator.free(body);
    const response = requestJson(allocator, .PUT, url, cfg.api_key, cfg.timeout_secs, body) catch |err| switch (err) {
        error.VectorBackendHttpError => return,
        else => return err,
    };
    defer allocator.free(response);
    try ensureBackendOk(response);
}

fn qdrantSearch(allocator: std.mem.Allocator, cfg: Config, embedding_json: []const u8, limit: usize) ![]Candidate {
    const path = try std.fmt.allocPrint(allocator, "/collections/{s}/points/search", .{cfg.collection});
    defer allocator.free(path);
    const url = try backendUrl(allocator, cfg, path);
    defer allocator.free(url);
    const payload = try searchPayload(allocator, embedding_json, limit, true);
    defer allocator.free(payload);
    const response = try requestJson(allocator, .POST, url, cfg.api_key, cfg.timeout_secs, payload);
    defer allocator.free(response);
    return parseCandidates(allocator, response);
}

fn qdrantDelete(allocator: std.mem.Allocator, cfg: Config, vector_id: []const u8) !void {
    const path = try std.fmt.allocPrint(allocator, "/collections/{s}/points/delete?wait=true", .{cfg.collection});
    defer allocator.free(path);
    const url = try backendUrl(allocator, cfg, path);
    defer allocator.free(url);
    const payload = try std.fmt.allocPrint(allocator, "{{\"points\":[{d}]}}", .{pointId(vector_id)});
    defer allocator.free(payload);
    const response = try requestJson(allocator, .POST, url, cfg.api_key, cfg.timeout_secs, payload);
    defer allocator.free(response);
    try ensureBackendOk(response);
}

fn qdrantReset(allocator: std.mem.Allocator, cfg: Config) !void {
    const path = try std.fmt.allocPrint(allocator, "/collections/{s}", .{cfg.collection});
    defer allocator.free(path);
    const url = try backendUrl(allocator, cfg, path);
    defer allocator.free(url);
    const response = requestJson(allocator, .DELETE, url, cfg.api_key, cfg.timeout_secs, "{}") catch |err| switch (err) {
        error.VectorBackendHttpError => return,
        else => return err,
    };
    defer allocator.free(response);
    try ensureBackendOk(response);
}

fn lancedbHttpUpsert(allocator: std.mem.Allocator, cfg: Config, input: UpsertInput) !void {
    const path = try std.fmt.allocPrint(allocator, "/v1/tables/{s}/vectors/upsert", .{cfg.collection});
    defer allocator.free(path);
    const url = try backendUrl(allocator, cfg, path);
    defer allocator.free(url);
    const payload = try lancedbUpsertPayload(allocator, input);
    defer allocator.free(payload);
    const response = try requestJson(allocator, .POST, url, cfg.api_key, cfg.timeout_secs, payload);
    defer allocator.free(response);
    try ensureBackendOk(response);
}

fn lancedbHttpSearch(allocator: std.mem.Allocator, cfg: Config, embedding_json: []const u8, limit: usize) ![]Candidate {
    const path = try std.fmt.allocPrint(allocator, "/v1/tables/{s}/vectors/search", .{cfg.collection});
    defer allocator.free(path);
    const url = try backendUrl(allocator, cfg, path);
    defer allocator.free(url);
    const payload = try searchPayload(allocator, embedding_json, limit, false);
    defer allocator.free(payload);
    const response = try requestJson(allocator, .POST, url, cfg.api_key, cfg.timeout_secs, payload);
    defer allocator.free(response);
    return parseCandidates(allocator, response);
}

fn lancedbHttpDelete(allocator: std.mem.Allocator, cfg: Config, vector_id: []const u8) !void {
    const path = try std.fmt.allocPrint(allocator, "/v1/tables/{s}/vectors/delete", .{cfg.collection});
    defer allocator.free(path);
    const url = try backendUrl(allocator, cfg, path);
    defer allocator.free(url);
    const payload = try vectorDeletePayload(allocator, vector_id);
    defer allocator.free(payload);
    const response = try requestJson(allocator, .POST, url, cfg.api_key, cfg.timeout_secs, payload);
    defer allocator.free(response);
    try ensureBackendOk(response);
}

fn lancedbHttpReset(allocator: std.mem.Allocator, cfg: Config) !void {
    const path = try std.fmt.allocPrint(allocator, "/v1/tables/{s}/vectors/reset", .{cfg.collection});
    defer allocator.free(path);
    const url = try backendUrl(allocator, cfg, path);
    defer allocator.free(url);
    const response = try requestJson(allocator, .POST, url, cfg.api_key, cfg.timeout_secs, "{}");
    defer allocator.free(response);
    try ensureBackendOk(response);
}

fn lancedbSdkUpsert(allocator: std.mem.Allocator, cfg: Config, input: UpsertInput) !void {
    const payload = try lancedbUpsertPayload(allocator, input);
    defer allocator.free(payload);
    const response = try runLanceDbCommand(allocator, cfg, "upsert", payload, null);
    defer allocator.free(response);
    try ensureBackendOk(response);
}

fn lancedbSdkSearch(allocator: std.mem.Allocator, cfg: Config, embedding_json: []const u8, limit: usize) ![]Candidate {
    const limit_text = try std.fmt.allocPrint(allocator, "{d}", .{@max(@as(usize, 1), @min(limit, 1000))});
    defer allocator.free(limit_text);
    const response = try runLanceDbCommand(allocator, cfg, "search", embedding_json, limit_text);
    defer allocator.free(response);
    return parseCandidates(allocator, response);
}

fn lancedbSdkDelete(allocator: std.mem.Allocator, cfg: Config, vector_id: []const u8) !void {
    const payload = try vectorDeletePayload(allocator, vector_id);
    defer allocator.free(payload);
    const response = try runLanceDbCommand(allocator, cfg, "delete", payload, null);
    defer allocator.free(response);
    try ensureBackendOk(response);
}

fn lancedbSdkReset(allocator: std.mem.Allocator, cfg: Config) !void {
    const response = try runLanceDbCommand(allocator, cfg, "reset", "{}", null);
    defer allocator.free(response);
    try ensureBackendOk(response);
}

fn runLanceDbCommand(allocator: std.mem.Allocator, cfg: Config, op: []const u8, payload: []const u8, maybe_limit: ?[]const u8) ![]u8 {
    const uri = cfg.lancedb_uri orelse return error.VectorBackendUnavailable;
    const command = cfg.lancedb_command;
    const timeout_ms = @as(u64, @max(cfg.timeout_secs, 1)) * std.time.ms_per_s;
    const use_python_sdk = commandLooksLikePython(command);

    if (use_python_sdk) {
        if (maybe_limit) |limit| {
            const argv = [_][]const u8{ command, "-c", lancedb_python_sdk, op, uri, cfg.collection, limit };
            return runVectorProcessWithStdin(allocator, &argv, payload, timeout_ms);
        }
        const argv = [_][]const u8{ command, "-c", lancedb_python_sdk, op, uri, cfg.collection };
        return runVectorProcessWithStdin(allocator, &argv, payload, timeout_ms);
    }

    if (maybe_limit) |limit| {
        const argv = [_][]const u8{ command, op, uri, cfg.collection, limit };
        return runVectorProcessWithStdin(allocator, &argv, payload, timeout_ms);
    }
    const argv = [_][]const u8{ command, op, uri, cfg.collection };
    return runVectorProcessWithStdin(allocator, &argv, payload, timeout_ms);
}

fn runVectorProcessWithStdin(allocator: std.mem.Allocator, argv: []const []const u8, payload: []const u8, timeout_ms: u64) ![]u8 {
    const io = compat.io();
    var child = try std.process.spawn(io, .{
        .argv = argv,
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
        .raw = std.Io.Duration.fromMilliseconds(@intCast(timeout_ms)),
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
    try out.print(allocator, "{{\"points\":[{{\"id\":{d},\"vector\":", .{pointId(input.id)});
    try json.appendRawJsonOr(&out, allocator, input.embedding_json, "[]");
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
    try json.appendRawJsonOr(out, allocator, input.permissions_json, "[]");
    try out.appendSlice(allocator, ",\"heading_path\":");
    try json.appendRawJsonOr(out, allocator, input.heading_path_json, "[]");
    try out.appendSlice(allocator, ",\"model\":");
    try json.appendNullableString(out, allocator, input.model);
    try out.appendSlice(allocator, ",\"dimensions\":");
    try out.print(allocator, "{d}", .{input.dimensions});
    try out.appendSlice(allocator, ",\"vector\":");
    try json.appendRawJsonOr(out, allocator, input.embedding_json, "[]");
    try out.append(allocator, '}');
}

fn searchPayload(allocator: std.mem.Allocator, embedding_json: []const u8, limit: usize, qdrant: bool) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"vector\":");
    try json.appendRawJsonOr(&out, allocator, embedding_json, "[]");
    try out.print(allocator, ",\"limit\":{d}", .{@max(@as(usize, 1), @min(limit, 1000))});
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
    return allocator.alloc(Candidate, 0);
}

fn parseCandidateArray(allocator: std.mem.Allocator, items: []const std.json.Value) ![]Candidate {
    var out: std.ArrayListUnmanaged(Candidate) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| {
        if (item != .object) continue;
        const obj = item.object;
        const id = candidateVectorId(obj) orelse continue;
        const score = candidateScore(obj);
        try out.append(allocator, .{ .vector_id = try allocator.dupe(u8, id), .score = score });
    }
    return out.toOwnedSlice(allocator);
}

fn candidateVectorId(obj: std.json.ObjectMap) ?[]const u8 {
    if (json.stringField(obj, "vector_id")) |id| return id;
    if (json.stringField(obj, "id")) |id| return id;
    if (obj.get("payload")) |payload| {
        if (payload == .object) {
            if (json.stringField(payload.object, "vector_id")) |id| return id;
            if (json.stringField(payload.object, "id")) |id| return id;
        }
    }
    return null;
}

fn candidateScore(obj: std.json.ObjectMap) f32 {
    if (json.floatField(obj, "score")) |score| return @floatCast(@max(0, @min(score, 1)));
    if (json.floatField(obj, "_score")) |score| return @floatCast(@max(0, @min(score, 1)));
    if (json.floatField(obj, "distance")) |distance| return @floatCast(@max(0, @min(1, 1 - distance)));
    if (json.floatField(obj, "_distance")) |distance| return @floatCast(@max(0, @min(1, 1 - distance)));
    return 0;
}

fn ensureBackendOk(body: []const u8) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, body, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    if (json.stringField(parsed.value.object, "status")) |status| {
        if (std.ascii.eqlIgnoreCase(status, "ok")) return;
        if (std.ascii.eqlIgnoreCase(status, "success")) return;
        return error.VectorBackendRejected;
    }
}

fn pointId(vector_id: []const u8) u64 {
    const hash = std.hash.Wyhash.hash(0, vector_id);
    return if (hash == 0) 1 else hash;
}

fn backendUrl(allocator: std.mem.Allocator, cfg: Config, suffix: []const u8) ![]u8 {
    const base_url = cfg.base_url orelse return error.VectorBackendUnavailable;
    try net_security.validateHttpBaseUrl(base_url, cfg.allow_insecure_http);
    return joinUrl(allocator, base_url, suffix);
}

fn joinUrl(allocator: std.mem.Allocator, base_url: []const u8, suffix: []const u8) ![]u8 {
    var end = base_url.len;
    while (end > 0 and base_url[end - 1] == '/') : (end -= 1) {}
    if (suffix.len > 0 and suffix[0] == '/') return std.fmt.allocPrint(allocator, "{s}{s}", .{ base_url[0..end], suffix });
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ base_url[0..end], suffix });
}

fn requestJson(allocator: std.mem.Allocator, method: std.http.Method, url: []const u8, api_key: ?[]const u8, timeout_secs: u32, payload: []const u8) ![]u8 {
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

    applySocketTimeout(req.connection, timeout_secs);

    req.transfer_encoding = .{ .content_length = payload.len };
    var body_writer = req.sendBodyUnflushed(&.{}) catch return error.VectorBackendUnavailable;
    body_writer.writer.writeAll(payload) catch return error.VectorBackendUnavailable;
    body_writer.end() catch return error.VectorBackendUnavailable;
    req.connection.?.flush() catch return error.VectorBackendUnavailable;

    var response = req.receiveHead(&.{}) catch return error.VectorBackendUnavailable;
    if (response.head.status != .ok) return error.VectorBackendHttpError;

    const reader = response.reader(&.{});
    const read_limit = max_vector_backend_response_bytes + 1;
    const body = reader.allocRemaining(allocator, .limited(read_limit)) catch return error.VectorBackendUnavailable;
    if (body.len > max_vector_backend_response_bytes) {
        allocator.free(body);
        return error.VectorBackendResponseTooLarge;
    }
    return body;
}

fn applySocketTimeout(connection: ?*std.http.Client.Connection, timeout_secs: u32) void {
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

test "qdrant payload preserves vector id and ACL metadata" {
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
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"vector_id\":\"vec_atom_0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"permissions\":[\"team:agents\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"heading_path\":[\"# NullPantry\",\"## Memory\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"vector\":[1,0]") != null);
}

test "vector delete payload preserves canonical vector id" {
    const payload = try vectorDeletePayload(std.testing.allocator, "vec_atom_0");
    defer std.testing.allocator.free(payload);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"vector_id\":\"vec_atom_0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"ids\":[\"vec_atom_0\"]") != null);
}

test "vector backend parses qdrant and lancedb candidate shapes" {
    const qdrant = "{\"result\":[{\"score\":0.93,\"payload\":{\"vector_id\":\"vec_a\"}}]}";
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
}

test "vector backend config gates external runtime" {
    try std.testing.expect(!(Config{}).externalEnabled());
    try std.testing.expect((Config{ .backend = .qdrant, .base_url = "http://127.0.0.1:6333" }).externalEnabled());
    try std.testing.expect((Config{ .backend = .lancedb, .lancedb_uri = ".nullpantry/lancedb" }).externalEnabled());
    try std.testing.expect((Config{ .backend = .lancedb_http, .base_url = "http://127.0.0.1:9000" }).externalEnabled());
    try std.testing.expect(BackendKind.parse("lancedb") == .lancedb);
    try std.testing.expect(BackendKind.parse("lancedb_http") == .lancedb_http);
    try std.testing.expectError(error.InsecureRuntimeUrl, backendUrl(std.testing.allocator, .{
        .backend = .qdrant,
        .base_url = "http://qdrant.internal:6333",
    }, "/collections/nullpantry_vectors"));

    const url = try backendUrl(std.testing.allocator, .{
        .backend = .qdrant,
        .base_url = "http://qdrant.internal:6333",
        .allow_insecure_http = true,
    }, "/collections/nullpantry_vectors");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("http://qdrant.internal:6333/collections/nullpantry_vectors", url);
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
    try std.testing.expectEqual(CircuitState.closed, breaker.state);
    breaker.recordFailure();
    try std.testing.expectEqual(CircuitState.open, breaker.state);
    try std.testing.expect(!breaker.allow());

    breaker.opened_at_ms = ids.nowMs() - 10_000;
    try std.testing.expect(breaker.allow());
    try std.testing.expectEqual(CircuitState.half_open, breaker.state);
    try std.testing.expect(!breaker.allow());

    breaker.recordSuccess();
    try std.testing.expectEqual(CircuitState.closed, breaker.state);
    try std.testing.expectEqual(@as(u32, 0), breaker.failure_count);
}

test "vector runtime wrapper fails fast while circuit is open" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var runtime = Runtime.init(.{
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
    try std.testing.expectEqual(CircuitState.open, runtime.circuit_breaker.state);
    try std.testing.expectError(error.VectorBackendCircuitOpen, searchWithRuntime(std.testing.allocator, cfg, &runtime, "[1,0]", 1));
}

test "lancedb sdk command contract uses vector lifecycle subcommands" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const tmp_random = try ids.make(std.testing.allocator, "");
    defer std.testing.allocator.free(tmp_random);
    const tmp_name = try std.fmt.allocPrint(std.testing.allocator, "lancedbcontract{d}_{s}", .{ std.c.getpid(), tmp_random });
    defer std.testing.allocator.free(tmp_name);
    const tmp_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp_name});
    defer std.testing.allocator.free(tmp_path);
    try std.Io.Dir.cwd().createDirPath(compat.io(), tmp_path);
    defer std.Io.Dir.cwd().deleteTree(compat.io(), tmp_path) catch {};

    const script =
        \\#!/bin/sh
        \\payload="$(cat)"
        \\if [ "$1" = "upsert" ]; then
        \\  echo "$payload" | grep '"rows"' >/dev/null || exit 2
        \\  echo '{"status":"ok"}'
        \\  exit 0
        \\fi
        \\if [ "$1" = "search" ]; then
        \\  [ "$4" = "3" ] || exit 3
        \\  echo "$payload" | grep '\[1,0,0\]' >/dev/null || exit 4
        \\  echo '{"matches":[{"id":"vec_contract","score":0.99}]}'
        \\  exit 0
        \\fi
        \\if [ "$1" = "delete" ]; then
        \\  echo "$payload" | grep '"vector_id":"vec_contract"' >/dev/null || exit 5
        \\  echo '{"status":"ok"}'
        \\  exit 0
        \\fi
        \\if [ "$1" = "reset" ]; then
        \\  echo '{"status":"ok"}'
        \\  exit 0
        \\fi
        \\exit 1
        \\
    ;
    const command = try std.fmt.allocPrint(std.testing.allocator, "{s}/lancedb-adapter", .{tmp_path});
    defer std.testing.allocator.free(command);
    var file = try std.Io.Dir.cwd().createFile(compat.io(), command, .{ .read = true });
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.File.Writer = .init(file, compat.io(), &buffer);
    try writer.interface.writeAll(script);
    try writer.interface.flush();
    try file.setPermissions(compat.io(), .executable_file);
    file.close(compat.io());

    const cfg = Config{
        .backend = .lancedb,
        .lancedb_uri = ".zig-cache/tmp/lancedb-test",
        .lancedb_command = command,
        .collection = "vectors",
        .timeout_secs = 2,
    };
    try upsert(std.testing.allocator, cfg, .{
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
    const candidates = try search(std.testing.allocator, cfg, "[1,0,0]", 3);
    defer freeCandidates(std.testing.allocator, candidates);
    try std.testing.expectEqual(@as(usize, 1), candidates.len);
    try std.testing.expectEqualStrings("vec_contract", candidates[0].vector_id);
    try std.testing.expectApproxEqAbs(@as(f32, 0.99), candidates[0].score, 0.0001);
    try delete(std.testing.allocator, cfg, "vec_contract");
    try reset(std.testing.allocator, cfg);
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
