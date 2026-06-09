const std = @import("std");
const compat = @import("compat.zig");
const domain = @import("domain.zig");
const json = @import("json_util.zig");
const ids = @import("ids.zig");
const net_security = @import("net_security.zig");
const runtime_limits = @import("runtime_limits.zig");
const time_math = @import("time_math.zig");

pub const max_graph_backend_response_bytes: usize = 4 * 1024 * 1024;

pub const BackendKind = enum {
    none,
    neo4j,
    falkordb,

    pub fn parse(raw: []const u8) !BackendKind {
        if (std.ascii.eqlIgnoreCase(raw, "none")) return .none;
        if (std.ascii.eqlIgnoreCase(raw, "neo4j")) return .neo4j;
        if (std.ascii.eqlIgnoreCase(raw, "neo4j_query_api")) return .neo4j;
        if (std.ascii.eqlIgnoreCase(raw, "falkordb")) return .falkordb;
        if (std.ascii.eqlIgnoreCase(raw, "falkor")) return .falkordb;
        if (std.ascii.eqlIgnoreCase(raw, "falkordb_graph")) return .falkordb;
        return error.InvalidGraphBackend;
    }

    pub fn name(self: BackendKind) []const u8 {
        return switch (self) {
            .none => "none",
            .neo4j => "neo4j",
            .falkordb => "falkordb",
        };
    }
};

pub const Config = struct {
    backend: BackendKind = .none,
    base_url: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    database: []const u8 = "neo4j",
    graph: []const u8 = "nullpantry",
    timeout_secs: u32 = 30,
    allow_insecure_http: bool = false,
    project_scopes_json: []const u8 = "[\"public\"]",

    pub fn isEnabled(self: Config) bool {
        return switch (self.backend) {
            .none => false,
            .neo4j => nonEmptyOptional(self.base_url) and nonEmptyString(self.database),
            .falkordb => nonEmptyOptional(self.base_url) and nonEmptyString(self.graph),
        };
    }

    pub fn validateUsable(self: Config) !void {
        if (self.api_key) |key| try net_security.validateHttpHeaderValue(key);
        switch (self.backend) {
            .none => {},
            .neo4j => {
                const base_url = self.base_url orelse return error.MissingGraphBackendUrl;
                if (!nonEmptyString(base_url) or !nonEmptyString(self.database)) return error.InvalidGraphBackend;
                try net_security.validateHttpBaseUrl(base_url, self.allow_insecure_http);
                try validatePathSegment(self.database);
            },
            .falkordb => {
                const base_url = self.base_url orelse return error.MissingGraphBackendUrl;
                if (!nonEmptyString(base_url) or !nonEmptyString(self.graph)) return error.InvalidGraphBackend;
                try net_security.validateHttpBaseUrl(base_url, self.allow_insecure_http);
                try validatePathSegment(self.graph);
            },
        }
        if (!runtime_limits.validTimeoutSecs(self.timeout_secs)) return error.InvalidGraphBackend;
        if (!domain.jsonStringArrayItemsNonBlank(self.project_scopes_json)) return error.InvalidGraphBackend;
    }
};

pub const ProjectionInput = struct {
    action: []const u8 = "put",
    object_type: []const u8,
    object_id: []const u8,
    title: []const u8 = "",
    text: []const u8 = "",
    scope: []const u8 = "public",
    permissions_json: []const u8 = "[]",
    from_entity_id: ?[]const u8 = null,
    relation_type: ?[]const u8 = null,
    to_entity_id: ?[]const u8 = null,
};

pub const Runtime = struct {
    config: Config = .{},

    pub fn init(config: Config) !Runtime {
        try config.validateUsable();
        return .{ .config = config };
    }

    pub fn backendName(self: *const Runtime) []const u8 {
        return if (self.config.isEnabled()) self.config.backend.name() else "none";
    }

    pub fn isEnabled(self: *const Runtime) bool {
        return self.config.isEnabled();
    }

    pub fn canProject(self: *const Runtime, scope: []const u8, permissions_json: []const u8) bool {
        if (!self.config.isEnabled()) return false;
        return domain.recordVisible(scope, permissions_json, self.config.project_scopes_json);
    }

    pub fn project(self: *Runtime, allocator: std.mem.Allocator, input: ProjectionInput) !bool {
        if (!self.canProject(input.scope, input.permissions_json)) return false;
        const query = try projectionQuery(allocator, input);
        defer allocator.free(query);
        switch (self.config.backend) {
            .none => return false,
            .neo4j => {
                const path = try neo4jQueryPath(allocator, self.config);
                defer allocator.free(path);
                const url = try backendUrl(allocator, self.config, path);
                defer allocator.free(url);
                const payload = try neo4jStatementPayload(allocator, query);
                defer allocator.free(payload);
                const response = try requestJson(allocator, .POST, url, self.config, payload);
                defer allocator.free(response);
            },
            .falkordb => {
                const path = try falkordbQueryPath(allocator, self.config, query);
                defer allocator.free(path);
                const url = try backendUrl(allocator, self.config, path);
                defer allocator.free(url);
                const response = try requestJson(allocator, .GET, url, self.config, "");
                defer allocator.free(response);
            },
        }
        return true;
    }
};

pub fn projectionJobInputJson(allocator: std.mem.Allocator, action: []const u8, input: ProjectionInput) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"action\":");
    try json.appendString(&out, allocator, action);
    try out.appendSlice(allocator, ",\"object_type\":");
    try json.appendString(&out, allocator, input.object_type);
    try out.appendSlice(allocator, ",\"object_id\":");
    try json.appendString(&out, allocator, input.object_id);
    try out.appendSlice(allocator, ",\"title\":");
    try json.appendString(&out, allocator, input.title);
    try out.appendSlice(allocator, ",\"text\":");
    try json.appendString(&out, allocator, input.text);
    try out.appendSlice(allocator, ",\"scope\":");
    try json.appendString(&out, allocator, input.scope);
    try out.appendSlice(allocator, ",\"permissions_json\":");
    try json.appendString(&out, allocator, input.permissions_json);
    if (input.from_entity_id) |from| {
        try out.appendSlice(allocator, ",\"from_entity_id\":");
        try json.appendString(&out, allocator, from);
    }
    if (input.relation_type) |rel| {
        try out.appendSlice(allocator, ",\"relation_type\":");
        try json.appendString(&out, allocator, rel);
    }
    if (input.to_entity_id) |to| {
        try out.appendSlice(allocator, ",\"to_entity_id\":");
        try json.appendString(&out, allocator, to);
    }
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

pub fn projectionInputFromJson(value: std.json.Value) !ProjectionInput {
    if (value != .object) return error.InvalidPayload;
    const obj = value.object;
    const scope = json.stringField(obj, "scope") orelse return error.InvalidPayload;
    if (!nonEmptyString(scope)) return error.InvalidPayload;
    const permissions_json = json.stringField(obj, "permissions_json") orelse return error.InvalidPayload;
    if (!domain.jsonStringArrayItemsNonBlank(permissions_json)) return error.InvalidPayload;
    return .{
        .action = json.stringField(obj, "action") orelse "put",
        .object_type = json.stringField(obj, "object_type") orelse return error.InvalidPayload,
        .object_id = json.stringField(obj, "object_id") orelse return error.InvalidPayload,
        .title = json.stringField(obj, "title") orelse "",
        .text = json.stringField(obj, "text") orelse "",
        .scope = scope,
        .permissions_json = permissions_json,
        .from_entity_id = json.stringField(obj, "from_entity_id"),
        .relation_type = json.stringField(obj, "relation_type"),
        .to_entity_id = json.stringField(obj, "to_entity_id"),
    };
}

pub fn projectionQuery(allocator: std.mem.Allocator, input: ProjectionInput) ![]u8 {
    if (isDeleteAction(input.action)) return deleteObjectQuery(allocator, input.object_id);
    if (std.mem.eql(u8, input.object_type, "relation") and input.from_entity_id != null and input.to_entity_id != null) return relationUpsertQuery(allocator, input);
    return objectUpsertQuery(allocator, input);
}

pub fn neo4jQueryPath(allocator: std.mem.Allocator, cfg: Config) ![]u8 {
    try validatePathSegment(cfg.database);
    const database = try net_security.percentEncodePathSegment(allocator, cfg.database);
    defer allocator.free(database);
    return std.fmt.allocPrint(allocator, "/db/{s}/query/v2", .{database});
}

pub fn falkordbQueryPath(allocator: std.mem.Allocator, cfg: Config, query: []const u8) ![]u8 {
    try validatePathSegment(cfg.graph);
    const graph = try net_security.percentEncodePathSegment(allocator, cfg.graph);
    defer allocator.free(graph);
    const encoded_query = try net_security.percentEncodePathSegment(allocator, query);
    defer allocator.free(encoded_query);
    const timeout_ms = time_math.secondsToMs(@max(cfg.timeout_secs, 1));
    return std.fmt.allocPrint(allocator, "/api/graph/{s}?query={s}&timeout={d}", .{ graph, encoded_query, timeout_ms });
}

pub fn neo4jStatementPayload(allocator: std.mem.Allocator, statement: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"statement\":");
    try json.appendString(&out, allocator, statement);
    try out.appendSlice(allocator, ",\"parameters\":{}}");
    return out.toOwnedSlice(allocator);
}

fn objectUpsertQuery(allocator: std.mem.Allocator, input: ProjectionInput) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "MERGE (n:NullPantryObject {id:");
    try appendCypherString(allocator, &out, input.object_id);
    try out.appendSlice(allocator, "}) SET n.object_type=");
    try appendCypherString(allocator, &out, input.object_type);
    try out.appendSlice(allocator, ", n.title=");
    try appendCypherString(allocator, &out, input.title);
    try out.appendSlice(allocator, ", n.text=");
    try appendCypherString(allocator, &out, input.text);
    try out.appendSlice(allocator, ", n.scope=");
    try appendCypherString(allocator, &out, input.scope);
    try out.appendSlice(allocator, ", n.permissions_json=");
    try appendCypherString(allocator, &out, input.permissions_json);
    try out.appendSlice(allocator, ", n.updated_at_ms=");
    try out.print(allocator, "{d}", .{ids.nowMs()});
    return out.toOwnedSlice(allocator);
}

fn relationUpsertQuery(allocator: std.mem.Allocator, input: ProjectionInput) ![]u8 {
    const from = input.from_entity_id orelse return error.InvalidPayload;
    const rel_type = input.relation_type orelse input.title;
    const to = input.to_entity_id orelse return error.InvalidPayload;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "MERGE (from:NullPantryObject {id:");
    try appendCypherString(allocator, &out, from);
    try out.appendSlice(allocator, "}) SET from.object_type='entity' MERGE (to:NullPantryObject {id:");
    try appendCypherString(allocator, &out, to);
    try out.appendSlice(allocator, "}) SET to.object_type='entity' MERGE (from)-[r:NULLPANTRY_RELATION {id:");
    try appendCypherString(allocator, &out, input.object_id);
    try out.appendSlice(allocator, "}]->(to) SET r.relation_type=");
    try appendCypherString(allocator, &out, rel_type);
    try out.appendSlice(allocator, ", r.text=");
    try appendCypherString(allocator, &out, input.text);
    try out.appendSlice(allocator, ", r.scope=");
    try appendCypherString(allocator, &out, input.scope);
    try out.appendSlice(allocator, ", r.permissions_json=");
    try appendCypherString(allocator, &out, input.permissions_json);
    try out.appendSlice(allocator, ", r.updated_at_ms=");
    try out.print(allocator, "{d}", .{ids.nowMs()});
    return out.toOwnedSlice(allocator);
}

fn deleteObjectQuery(allocator: std.mem.Allocator, object_id: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "MATCH (n:NullPantryObject {id:");
    try appendCypherString(allocator, &out, object_id);
    try out.appendSlice(allocator, "}) DETACH DELETE n");
    return out.toOwnedSlice(allocator);
}

fn appendCypherString(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), raw: []const u8) !void {
    try out.append(allocator, '\'');
    for (raw) |ch| {
        if (ch == '\'' or ch == '\\') try out.append(allocator, '\\');
        try out.append(allocator, ch);
    }
    try out.append(allocator, '\'');
}

fn backendUrl(allocator: std.mem.Allocator, cfg: Config, suffix: []const u8) ![]u8 {
    const base_url = cfg.base_url orelse return error.MissingGraphBackendUrl;
    return net_security.joinHttpBaseUrl(allocator, base_url, suffix, cfg.allow_insecure_http);
}

fn requestJson(allocator: std.mem.Allocator, method: std.http.Method, url: []const u8, cfg: Config, payload: []const u8) ![]u8 {
    var auth_header: ?[]u8 = null;
    defer if (auth_header) |h| allocator.free(h);

    var extra_headers_buf: [1]std.http.Header = undefined;
    var header_count: usize = 0;
    if (cfg.api_key) |key| {
        auth_header = try authHeaderValue(allocator, key);
        extra_headers_buf[header_count] = .{ .name = "Authorization", .value = auth_header.? };
        header_count += 1;
    }

    var client: std.http.Client = .{ .allocator = allocator, .io = compat.io() };
    defer client.deinit();

    const uri = std.Uri.parse(url) catch return error.GraphBackendUnavailable;
    var req = client.request(method, uri, .{
        .redirect_behavior = .unhandled,
        .keep_alive = false,
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .accept_encoding = .omit,
            .connection = .{ .override = "close" },
        },
        .extra_headers = extra_headers_buf[0..header_count],
    }) catch return error.GraphBackendUnavailable;
    defer req.deinit();

    net_security.applyHttpSocketTimeout(req.connection, cfg.timeout_secs);

    req.transfer_encoding = .{ .content_length = payload.len };
    var body_writer = req.sendBodyUnflushed(&.{}) catch return error.GraphBackendUnavailable;
    body_writer.writer.writeAll(payload) catch return error.GraphBackendUnavailable;
    body_writer.end() catch return error.GraphBackendUnavailable;
    net_security.flushHttpConnection(req.connection) catch return error.GraphBackendUnavailable;

    var response = req.receiveHead(&.{}) catch return error.GraphBackendUnavailable;
    const reader = response.reader(&.{});
    const body = net_security.readBoundedResponse(allocator, reader, max_graph_backend_response_bytes) catch |err| switch (err) {
        error.StreamTooLong => return error.GraphBackendResponseTooLarge,
        else => return error.GraphBackendUnavailable,
    };
    if (response.head.status != .ok and response.head.status != .created and response.head.status != .accepted and response.head.status != .no_content) {
        allocator.free(body);
        return error.GraphBackendHttpError;
    }
    return body;
}

fn authHeaderValue(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    try net_security.validateHttpHeaderValue(key);
    if (std.ascii.startsWithIgnoreCase(key, "Bearer ") or
        std.ascii.startsWithIgnoreCase(key, "Basic ") or
        std.ascii.startsWithIgnoreCase(key, "Token "))
    {
        return allocator.dupe(u8, key);
    }
    return std.fmt.allocPrint(allocator, "Bearer {s}", .{key});
}

fn isDeleteAction(action: []const u8) bool {
    return std.mem.eql(u8, action, "delete") or
        std.mem.eql(u8, action, "forget") or
        std.mem.eql(u8, action, "retract");
}

fn validatePathSegment(value: []const u8) !void {
    if (!nonEmptyString(value)) return error.InvalidGraphBackend;
    for (value) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-' or ch == '.') continue;
        return error.InvalidGraphBackend;
    }
}

fn nonEmptyOptional(value: ?[]const u8) bool {
    return if (value) |text| nonEmptyString(text) else false;
}

fn nonEmptyString(value: []const u8) bool {
    return std.mem.trim(u8, value, " \t\r\n").len > 0;
}

test "graph runtime validates external backend configuration" {
    try (Config{}).validateUsable();
    try std.testing.expectError(error.MissingGraphBackendUrl, (Config{ .backend = .neo4j }).validateUsable());
    try std.testing.expectError(error.InvalidGraphBackend, (Config{ .backend = .neo4j, .base_url = "http://127.0.0.1:7474", .database = "bad/db" }).validateUsable());
    try std.testing.expectError(error.InvalidRuntimeUrl, (Config{ .backend = .neo4j, .base_url = "https://token@neo4j.example" }).validateUsable());
    try std.testing.expectError(error.InvalidRuntimeUrl, (Config{ .backend = .neo4j, .base_url = "https://neo4j.example?token=x" }).validateUsable());
    try std.testing.expectError(error.InvalidHttpHeaderValue, (Config{ .backend = .neo4j, .base_url = "http://127.0.0.1:7474", .api_key = "bad\r\nX: y" }).validateUsable());
    try std.testing.expectError(error.InvalidGraphBackend, (Config{ .backend = .neo4j, .base_url = "http://127.0.0.1:7474", .timeout_secs = 0 }).validateUsable());
    try std.testing.expectError(error.InvalidGraphBackend, (Config{ .backend = .neo4j, .base_url = "http://127.0.0.1:7474", .timeout_secs = runtime_limits.max_timeout_secs + 1 }).validateUsable());
    try std.testing.expectError(error.InvalidGraphBackend, (Config{ .project_scopes_json = "not-json" }).validateUsable());
    try std.testing.expectError(error.InvalidGraphBackend, (Config{ .project_scopes_json = "[\"public\",]" }).validateUsable());
    try std.testing.expectError(error.InvalidGraphBackend, (Config{ .project_scopes_json = "[\"\"]" }).validateUsable());
    try std.testing.expectError(error.InvalidGraphBackend, (Config{ .project_scopes_json = "[\"\\u0020\"]" }).validateUsable());
    try (Config{ .backend = .neo4j, .base_url = "http://127.0.0.1:7474" }).validateUsable();
    try (Config{ .backend = .falkordb, .base_url = "http://127.0.0.1:3000" }).validateUsable();
    try (Config{ .project_scopes_json = "[\"public\",\"team:\\u0041\"]" }).validateUsable();
    try std.testing.expect((Config{ .backend = .neo4j, .base_url = "http://127.0.0.1:7474" }).isEnabled());

    try std.testing.expectError(error.InvalidHttpHeaderValue, authHeaderValue(std.testing.allocator, "bad\x7f"));

    const url = try backendUrl(std.testing.allocator, .{
        .backend = .falkordb,
        .base_url = "http://falkor.internal:3000///",
        .allow_insecure_http = true,
    }, "api/graph/nullpantry");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("http://falkor.internal:3000/api/graph/nullpantry", url);
}

test "graph runtime builds official neo4j and falkordb paths" {
    const neo4j_path = try neo4jQueryPath(std.testing.allocator, .{ .database = "neo4j" });
    defer std.testing.allocator.free(neo4j_path);
    try std.testing.expectEqualStrings("/db/neo4j/query/v2", neo4j_path);

    const falkor_path = try falkordbQueryPath(std.testing.allocator, .{ .graph = "nullpantry", .timeout_secs = 7 }, "MATCH (n) RETURN n LIMIT 1");
    defer std.testing.allocator.free(falkor_path);
    try std.testing.expectEqualStrings("/api/graph/nullpantry?query=MATCH%20%28n%29%20RETURN%20n%20LIMIT%201&timeout=7000", falkor_path);
}

test "graph runtime escapes cypher literals and keeps relation type as property" {
    const query = try projectionQuery(std.testing.allocator, .{
        .object_type = "relation",
        .object_id = "rel-1",
        .title = "ignored",
        .text = "Alice's service",
        .scope = "project:x",
        .permissions_json = "[\"team:x\"]",
        .from_entity_id = "a\\b",
        .relation_type = "x`) DETACH DELETE n //",
        .to_entity_id = "svc",
    });
    defer std.testing.allocator.free(query);

    try std.testing.expect(std.mem.indexOf(u8, query, "NULLPANTRY_RELATION") != null);
    try std.testing.expect(std.mem.indexOf(u8, query, "Alice\\'s service") != null);
    try std.testing.expect(std.mem.indexOf(u8, query, "x`) DETACH DELETE n //") != null);
    try std.testing.expect(std.mem.indexOf(u8, query, "[:x") == null);
}

test "graph runtime job payload round-trips projection fields" {
    const payload = try projectionJobInputJson(std.testing.allocator, "put", .{
        .object_type = "entity",
        .object_id = "ent-1",
        .title = "Service",
        .text = "Service description",
        .scope = "project:x",
        .permissions_json = "[\"team:x\"]",
    });
    defer std.testing.allocator.free(payload);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();
    const input = try projectionInputFromJson(parsed.value);
    try std.testing.expectEqualStrings("put", input.action);
    try std.testing.expectEqualStrings("entity", input.object_type);
    try std.testing.expectEqualStrings("ent-1", input.object_id);
    try std.testing.expectEqualStrings("[\"team:x\"]", input.permissions_json);
}

test "graph runtime projection input requires valid ACL fields" {
    try expectInvalidProjectionInput("{\"object_type\":\"entity\",\"object_id\":\"ent-1\",\"permissions_json\":\"[]\"}");
    try expectInvalidProjectionInput("{\"object_type\":\"entity\",\"object_id\":\"ent-1\",\"scope\":\"public\"}");
    try expectInvalidProjectionInput("{\"object_type\":\"entity\",\"object_id\":\"ent-1\",\"scope\":\" \",\"permissions_json\":\"[]\"}");
    try expectInvalidProjectionInput("{\"object_type\":\"entity\",\"object_id\":\"ent-1\",\"scope\":\"public\",\"permissions_json\":\"[\\\"public\\\",]\"}");
    try expectInvalidProjectionInput("{\"object_type\":\"entity\",\"object_id\":\"ent-1\",\"scope\":\"public\",\"permissions_json\":\"[\\\"\\\"]\"}");
}

fn expectInvalidProjectionInput(raw: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{});
    defer parsed.deinit();
    try std.testing.expectError(error.InvalidPayload, projectionInputFromJson(parsed.value));
}
