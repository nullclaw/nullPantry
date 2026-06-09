const std = @import("std");
const compat = @import("compat.zig");
const ids = @import("ids.zig");
const json = @import("json_util.zig");
const clickhouse_contracts = @import("clickhouse_contracts.zig");
const net_security = @import("net_security.zig");
const runtime_limits = @import("runtime_limits.zig");

pub const max_analytics_response_bytes: usize = 8 * 1024 * 1024;

pub const BackendKind = enum {
    none,
    clickhouse,

    pub fn parse(raw: []const u8) !BackendKind {
        if (std.ascii.eqlIgnoreCase(raw, "none")) return .none;
        if (std.ascii.eqlIgnoreCase(raw, "clickhouse")) return .clickhouse;
        return error.InvalidAnalyticsBackend;
    }

    pub fn name(self: BackendKind) []const u8 {
        return switch (self) {
            .none => "none",
            .clickhouse => "clickhouse",
        };
    }
};

pub const Config = struct {
    backend: BackendKind = .none,
    base_url: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    table: []const u8 = "nullpantry_events",
    timeout_secs: u32 = 30,
    allow_insecure_http: bool = false,

    pub fn enabled(self: Config) bool {
        return self.backend == .clickhouse and nonEmptyOptional(self.base_url) and nonEmptyString(self.table);
    }

    pub fn validateUsable(self: Config) !void {
        if (self.api_key) |key| try net_security.validateHttpHeaderValue(key);
        switch (self.backend) {
            .none => {},
            .clickhouse => {
                const base_url = self.base_url orelse return error.MissingAnalyticsBaseUrl;
                if (!nonEmptyString(base_url)) return error.MissingAnalyticsBaseUrl;
                if (!runtime_limits.validTimeoutSecs(self.timeout_secs)) return error.InvalidAnalyticsBackend;
                try net_security.validateHttpBaseUrl(base_url, self.allow_insecure_http);
                if (!clickhouse_contracts.validTableName(self.table)) return error.InvalidAnalyticsTable;
            },
        }
    }
};

fn nonEmptyOptional(value: ?[]const u8) bool {
    return if (value) |text| nonEmptyString(text) else false;
}

fn nonEmptyString(value: []const u8) bool {
    return std.mem.trim(u8, value, " \t\r\n").len > 0;
}

pub const Event = struct {
    event_source: []const u8,
    event_id: i64,
    event_type: []const u8,
    operation: ?[]const u8 = null,
    actor_id: ?[]const u8 = null,
    object_type: []const u8,
    object_id: []const u8,
    scope: ?[]const u8 = null,
    permissions_json: []const u8 = "[]",
    status: ?[]const u8 = null,
    payload_json: []const u8 = "{}",
    causality_json: []const u8 = "{}",
    created_at_ms: i64,
};

pub const ExportResult = struct {
    attempted: usize = 0,
    inserted: usize = 0,
    skipped_existing: usize = 0,
};

pub const Status = struct {
    rows: usize = 0,
    audit_max_id: i64 = 0,
    feed_max_id: i64 = 0,
    latest_created_at_ms: i64 = 0,
};

pub const QueryInput = struct {
    event_source: ?[]const u8 = null,
    object_type: ?[]const u8 = null,
    object_id: ?[]const u8 = null,
    actor_id: ?[]const u8 = null,
    since_id: i64 = 0,
    limit: usize = 100,
    newest_first: bool = true,
};

const EventKey = struct {
    event_source: []const u8,
    event_id: i64,
};

pub fn exportEvents(allocator: std.mem.Allocator, cfg: Config, events: []const Event) !ExportResult {
    try cfg.validateUsable();
    if (!cfg.enabled()) return error.AnalyticsBackendNotConfigured;
    if (events.len == 0) return .{};
    return switch (cfg.backend) {
        .none => error.AnalyticsBackendNotConfigured,
        .clickhouse => clickhouseInsert(allocator, cfg, events),
    };
}

pub fn status(allocator: std.mem.Allocator, cfg: Config) !Status {
    try cfg.validateUsable();
    if (!cfg.enabled()) return error.AnalyticsBackendNotConfigured;
    const table = try safeIdentifier(allocator, cfg.table);
    defer allocator.free(table);
    try clickhouseEnsureTable(allocator, cfg, table);
    const query = try std.fmt.allocPrint(
        allocator,
        "SELECT count(), maxIf(event_id, event_source = 'audit'), maxIf(event_id, event_source = 'memory_feed'), toInt64(ifNull(max(created_at_ms), 0)) FROM {s} FINAL FORMAT TSV",
        .{table},
    );
    defer allocator.free(query);
    const body = try clickhouseQuery(allocator, cfg, query);
    defer allocator.free(body);
    return try parseStatus(body);
}

pub fn queryEventsJson(allocator: std.mem.Allocator, cfg: Config, input: QueryInput) ![]u8 {
    try cfg.validateUsable();
    if (!cfg.enabled()) return error.AnalyticsBackendNotConfigured;
    const table = try safeIdentifier(allocator, cfg.table);
    defer allocator.free(table);
    try clickhouseEnsureTable(allocator, cfg, table);

    var where_clause: std.ArrayListUnmanaged(u8) = .empty;
    defer where_clause.deinit(allocator);
    try where_clause.print(allocator, "event_id > {d}", .{input.since_id});
    try appendOptionalFilter(allocator, &where_clause, "event_source", input.event_source);
    try appendOptionalFilter(allocator, &where_clause, "object_type", input.object_type);
    try appendOptionalFilter(allocator, &where_clause, "object_id", input.object_id);
    try appendOptionalFilter(allocator, &where_clause, "actor_id", input.actor_id);

    const order = if (input.newest_first) "created_at_ms DESC, event_source ASC, event_id DESC" else "event_source ASC, event_id ASC";
    const limit = @max(@as(usize, 1), @min(input.limit, 1000));
    const query = try std.fmt.allocPrint(
        allocator,
        "SELECT event_source,event_id,event_type,operation,actor_id,object_type,object_id,scope,permissions_json,status,payload_json,causality_json,created_at_ms FROM {s} FINAL WHERE {s} ORDER BY {s} LIMIT {d} FORMAT JSONEachRow",
        .{ table, where_clause.items, order, limit },
    );
    defer allocator.free(query);
    const body = try clickhouseQuery(allocator, cfg, query);
    defer allocator.free(body);
    return clickhouse_contracts.jsonEachRowsToArray(allocator, body);
}

fn clickhouseInsert(allocator: std.mem.Allocator, cfg: Config, events: []const Event) !ExportResult {
    const table = try safeIdentifier(allocator, cfg.table);
    defer allocator.free(table);
    try clickhouseEnsureTable(allocator, cfg, table);

    const existing = try queryExistingEventKeys(allocator, cfg, table, events);
    defer freeEventKeys(allocator, existing);

    var missing: std.ArrayListUnmanaged(Event) = .empty;
    defer missing.deinit(allocator);
    for (events) |event| {
        if (!eventKeyExists(existing, event)) try missing.append(allocator, event);
    }
    if (missing.items.len == 0) {
        return .{ .attempted = events.len, .inserted = 0, .skipped_existing = events.len };
    }

    const query = try std.fmt.allocPrint(allocator, "INSERT INTO {s} FORMAT JSONEachRow", .{table});
    defer allocator.free(query);
    const url = try clickhouseQueryUrl(allocator, cfg, query);
    defer allocator.free(url);
    const body = try eventsJsonEachRow(allocator, missing.items);
    defer allocator.free(body);
    const response = try post(allocator, url, cfg.api_key, cfg.timeout_secs, "application/x-ndjson", body);
    defer allocator.free(response);
    return .{
        .attempted = events.len,
        .inserted = missing.items.len,
        .skipped_existing = events.len - missing.items.len,
    };
}

fn clickhouseEnsureTable(allocator: std.mem.Allocator, cfg: Config, table: []const u8) !void {
    const query = try std.fmt.allocPrint(
        allocator,
        "CREATE TABLE IF NOT EXISTS {s} (event_source String, event_id Int64, event_type String, operation Nullable(String), actor_id Nullable(String), object_type String, object_id String, scope Nullable(String), permissions_json String, status Nullable(String), payload_json String, causality_json String, created_at_ms Int64) ENGINE = ReplacingMergeTree(created_at_ms) ORDER BY (event_source, event_id)",
        .{table},
    );
    defer allocator.free(query);
    const url = try clickhouseQueryUrl(allocator, cfg, query);
    defer allocator.free(url);
    const response = try post(allocator, url, cfg.api_key, cfg.timeout_secs, "text/plain", "");
    defer allocator.free(response);
}

fn clickhouseQuery(allocator: std.mem.Allocator, cfg: Config, query: []const u8) ![]u8 {
    try cfg.validateUsable();
    if (!cfg.enabled()) return error.AnalyticsBackendNotConfigured;
    const url = try clickhouseQueryUrl(allocator, cfg, query);
    defer allocator.free(url);
    return post(allocator, url, cfg.api_key, cfg.timeout_secs, "text/plain", "");
}

fn queryExistingEventKeys(allocator: std.mem.Allocator, cfg: Config, table: []const u8, events: []const Event) ![]EventKey {
    if (events.len == 0) return allocator.dupe(EventKey, &.{});
    var tuples: std.ArrayListUnmanaged(u8) = .empty;
    defer tuples.deinit(allocator);
    for (events, 0..) |event, i| {
        if (i > 0) try tuples.append(allocator, ',');
        try tuples.append(allocator, '(');
        try clickhouse_contracts.appendStringLiteral(allocator, &tuples, event.event_source);
        try tuples.print(allocator, ",{d})", .{event.event_id});
    }
    const query = try std.fmt.allocPrint(
        allocator,
        "SELECT event_source,event_id FROM {s} FINAL WHERE (event_source,event_id) IN ({s}) FORMAT TSV",
        .{ table, tuples.items },
    );
    defer allocator.free(query);
    const body = try clickhouseQuery(allocator, cfg, query);
    defer allocator.free(body);
    return parseEventKeys(allocator, body);
}

fn parseEventKeys(allocator: std.mem.Allocator, body: []const u8) ![]EventKey {
    var keys: std.ArrayListUnmanaged(EventKey) = .empty;
    errdefer freeEventKeys(allocator, keys.items);
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;
        var columns = std.mem.splitScalar(u8, line, '\t');
        const source = columns.next() orelse return error.InvalidClickHouseTsvEventKey;
        const event_id_raw = columns.next() orelse return error.InvalidClickHouseTsvEventKey;
        if (columns.next() != null) return error.InvalidClickHouseTsvEventKey;
        const event_id = try clickhouse_contracts.parseTsvI64(event_id_raw);
        const source_copy = try allocator.dupe(u8, source);
        errdefer allocator.free(source_copy);
        try keys.append(allocator, .{
            .event_source = source_copy,
            .event_id = event_id,
        });
    }
    return keys.toOwnedSlice(allocator);
}

fn freeEventKeys(allocator: std.mem.Allocator, keys: []const EventKey) void {
    for (keys) |key| allocator.free(key.event_source);
    allocator.free(keys);
}

fn eventKeyExists(keys: []const EventKey, event: Event) bool {
    for (keys) |key| {
        if (key.event_id == event.event_id and std.mem.eql(u8, key.event_source, event.event_source)) return true;
    }
    return false;
}

fn parseStatus(body: []const u8) !Status {
    const line = std.mem.trim(u8, body, " \t\r\n");
    if (line.len == 0) return error.InvalidClickHouseTsvStatus;
    var columns = std.mem.splitScalar(u8, line, '\t');
    const rows_raw = columns.next() orelse return error.InvalidClickHouseTsvStatus;
    const audit_max_id_raw = columns.next() orelse return error.InvalidClickHouseTsvStatus;
    const feed_max_id_raw = columns.next() orelse return error.InvalidClickHouseTsvStatus;
    const latest_created_at_ms_raw = columns.next() orelse return error.InvalidClickHouseTsvStatus;
    if (columns.next() != null) return error.InvalidClickHouseTsvStatus;
    return .{
        .rows = try clickhouse_contracts.parseTsvUsize(rows_raw),
        .audit_max_id = try clickhouse_contracts.parseTsvI64(audit_max_id_raw),
        .feed_max_id = try clickhouse_contracts.parseTsvI64(feed_max_id_raw),
        .latest_created_at_ms = try clickhouse_contracts.parseTsvI64(latest_created_at_ms_raw),
    };
}

fn appendOptionalFilter(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), column: []const u8, value: ?[]const u8) !void {
    const actual = value orelse return;
    try out.appendSlice(allocator, " AND ");
    try out.appendSlice(allocator, column);
    try out.appendSlice(allocator, " = ");
    try clickhouse_contracts.appendStringLiteral(allocator, out, actual);
}

fn eventsJsonEachRow(allocator: std.mem.Allocator, events: []const Event) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    for (events) |event| {
        try appendEventJson(allocator, &out, event);
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

fn appendEventJson(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), event: Event) !void {
    try out.appendSlice(allocator, "{\"event_source\":");
    try json.appendString(out, allocator, event.event_source);
    try out.appendSlice(allocator, ",\"event_id\":");
    try out.print(allocator, "{d}", .{event.event_id});
    try out.appendSlice(allocator, ",\"event_type\":");
    try json.appendString(out, allocator, event.event_type);
    try out.appendSlice(allocator, ",\"operation\":");
    try json.appendNullableString(out, allocator, event.operation);
    try out.appendSlice(allocator, ",\"actor_id\":");
    try json.appendNullableString(out, allocator, event.actor_id);
    try out.appendSlice(allocator, ",\"object_type\":");
    try json.appendString(out, allocator, event.object_type);
    try out.appendSlice(allocator, ",\"object_id\":");
    try json.appendString(out, allocator, event.object_id);
    try out.appendSlice(allocator, ",\"scope\":");
    try json.appendNullableString(out, allocator, event.scope);
    try out.appendSlice(allocator, ",\"permissions_json\":");
    try json.appendString(out, allocator, event.permissions_json);
    try out.appendSlice(allocator, ",\"status\":");
    try json.appendNullableString(out, allocator, event.status);
    try out.appendSlice(allocator, ",\"payload_json\":");
    try json.appendString(out, allocator, event.payload_json);
    try out.appendSlice(allocator, ",\"causality_json\":");
    try json.appendString(out, allocator, event.causality_json);
    try out.appendSlice(allocator, ",\"created_at_ms\":");
    try out.print(allocator, "{d}", .{event.created_at_ms});
    try out.append(allocator, '}');
}

fn safeIdentifier(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    if (!clickhouse_contracts.validTableName(raw)) return error.InvalidAnalyticsTable;
    return allocator.dupe(u8, raw);
}

fn clickhouseQueryUrl(allocator: std.mem.Allocator, cfg: Config, query: []const u8) ![]u8 {
    try cfg.validateUsable();
    const base_url = cfg.base_url orelse return error.AnalyticsBackendNotConfigured;
    return clickhouse_contracts.queryUrl(allocator, base_url, query, cfg.allow_insecure_http);
}

fn post(allocator: std.mem.Allocator, url: []const u8, api_key: ?[]const u8, timeout_secs: u32, content_type: []const u8, body: []const u8) ![]u8 {
    var auth_header: ?[]u8 = null;
    defer if (auth_header) |h| allocator.free(h);

    var extra_headers_buf: [1]std.http.Header = undefined;
    var header_count: usize = 0;
    if (api_key) |key| {
        try net_security.validateHttpHeaderValue(key);
        auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{key});
        extra_headers_buf[header_count] = .{ .name = "Authorization", .value = auth_header.? };
        header_count += 1;
    }

    var client: std.http.Client = .{ .allocator = allocator, .io = compat.io() };
    defer client.deinit();

    const uri = std.Uri.parse(url) catch return error.AnalyticsBackendUnavailable;
    var req = client.request(.POST, uri, .{
        .redirect_behavior = .unhandled,
        .keep_alive = false,
        .headers = .{
            .content_type = .{ .override = content_type },
            .accept_encoding = .omit,
            .connection = .{ .override = "close" },
        },
        .extra_headers = extra_headers_buf[0..header_count],
    }) catch return error.AnalyticsBackendUnavailable;
    defer req.deinit();

    net_security.applyHttpSocketTimeout(req.connection, timeout_secs);

    req.transfer_encoding = .{ .content_length = body.len };
    var body_writer = req.sendBodyUnflushed(&.{}) catch return error.AnalyticsBackendUnavailable;
    body_writer.writer.writeAll(body) catch return error.AnalyticsBackendUnavailable;
    body_writer.end() catch return error.AnalyticsBackendUnavailable;
    net_security.flushHttpConnection(req.connection) catch return error.AnalyticsBackendUnavailable;

    var response = req.receiveHead(&.{}) catch return error.AnalyticsBackendUnavailable;
    if (response.head.status != .ok) return error.AnalyticsBackendHttpError;

    const reader = response.reader(&.{});
    const response_body = net_security.readBoundedResponse(allocator, reader, max_analytics_response_bytes) catch |err| switch (err) {
        error.StreamTooLong => return error.AnalyticsBackendResponseTooLarge,
        else => return error.AnalyticsBackendUnavailable,
    };
    return response_body;
}

test "clickhouse analytics export serializes audit and feed rows" {
    const events = [_]Event{
        .{
            .event_source = "audit",
            .event_id = 1,
            .event_type = "source.created",
            .actor_id = "agent:a",
            .object_type = "source",
            .object_id = "src_a",
            .payload_json = "{\"ok\":true}",
            .created_at_ms = 10,
        },
        .{
            .event_source = "memory_feed",
            .event_id = 2,
            .event_type = "memory.put",
            .operation = "put",
            .object_type = "memory_atom",
            .object_id = "mem_a",
            .scope = "project:nullpantry",
            .permissions_json = "[\"project:nullpantry\"]",
            .status = "pending",
            .created_at_ms = 11,
        },
    };
    const body = try eventsJsonEachRow(std.testing.allocator, &events);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"event_source\":\"audit\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"event_source\":\"memory_feed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"permissions_json\":\"[\\\"project:nullpantry\\\"]\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"payload_json\":\"{\\\"ok\\\":true}\"") != null);
}

test "clickhouse analytics status parses TSV strictly" {
    const parsed = try parseStatus("12\t9\t3\t42\n");
    try std.testing.expectEqual(@as(usize, 12), parsed.rows);
    try std.testing.expectEqual(@as(i64, 9), parsed.audit_max_id);
    try std.testing.expectEqual(@as(i64, 3), parsed.feed_max_id);
    try std.testing.expectEqual(@as(i64, 42), parsed.latest_created_at_ms);

    try std.testing.expectError(error.InvalidClickHouseTsvStatus, parseStatus(""));
    try std.testing.expectError(error.InvalidClickHouseTsvStatus, parseStatus("12\t9\t3\n"));
    try std.testing.expectError(error.InvalidClickHouseTsvStatus, parseStatus("12\t9\t3\t42\textra\n"));
    try std.testing.expectError(error.InvalidClickHouseTsvNumber, parseStatus("12\tbad\t3\t42\n"));
}

test "clickhouse analytics existing event keys parse TSV strictly" {
    const keys = try parseEventKeys(std.testing.allocator, "audit\t1\nmemory_feed\t-2\n\n");
    defer freeEventKeys(std.testing.allocator, keys);
    try std.testing.expectEqual(@as(usize, 2), keys.len);
    try std.testing.expectEqualStrings("audit", keys[0].event_source);
    try std.testing.expectEqual(@as(i64, 1), keys[0].event_id);
    try std.testing.expectEqualStrings("memory_feed", keys[1].event_source);
    try std.testing.expectEqual(@as(i64, -2), keys[1].event_id);

    try std.testing.expectError(error.InvalidClickHouseTsvEventKey, parseEventKeys(std.testing.allocator, "audit\n"));
    try std.testing.expectError(error.InvalidClickHouseTsvEventKey, parseEventKeys(std.testing.allocator, "audit\t1\textra\n"));
    try std.testing.expectError(error.InvalidClickHouseTsvNumber, parseEventKeys(std.testing.allocator, "audit\tbad\n"));
}

test "clickhouse analytics config gates runtime" {
    try std.testing.expect(!(Config{}).enabled());
    try std.testing.expect((Config{ .backend = .clickhouse, .base_url = "http://127.0.0.1:8123" }).enabled());
    try std.testing.expect(!(Config{ .backend = .clickhouse, .base_url = " " }).enabled());
    try std.testing.expect(!(Config{ .backend = .clickhouse, .base_url = "http://127.0.0.1:8123", .table = " " }).enabled());
    try std.testing.expect((try BackendKind.parse("none")) == .none);
    try std.testing.expect((try BackendKind.parse("clickhouse")) == .clickhouse);
    try std.testing.expectError(error.InvalidAnalyticsBackend, BackendKind.parse("unknown"));
    try std.testing.expectError(error.InvalidAnalyticsTable, safeIdentifier(std.testing.allocator, "bad table"));
    try std.testing.expectError(error.InsecureRuntimeUrl, clickhouseQueryUrl(std.testing.allocator, .{
        .backend = .clickhouse,
        .base_url = "http://clickhouse.internal:8123",
    }, "SELECT 1"));

    const url = try clickhouseQueryUrl(std.testing.allocator, .{
        .backend = .clickhouse,
        .base_url = "http://clickhouse.internal:8123",
        .allow_insecure_http = true,
    }, "SELECT 1");
    defer std.testing.allocator.free(url);
    try std.testing.expect(std.mem.startsWith(u8, url, "http://clickhouse.internal:8123/?query=SELECT%201"));
}

test "clickhouse analytics config validates usable setup" {
    try (Config{}).validateUsable();
    try (Config{ .backend = .none, .base_url = " " }).validateUsable();

    try std.testing.expectError(error.MissingAnalyticsBaseUrl, (Config{ .backend = .clickhouse }).validateUsable());
    try std.testing.expectError(error.MissingAnalyticsBaseUrl, (Config{ .backend = .clickhouse, .base_url = " " }).validateUsable());
    try std.testing.expectError(error.InvalidAnalyticsTable, (Config{ .backend = .clickhouse, .base_url = "http://127.0.0.1:8123", .table = "" }).validateUsable());
    try std.testing.expectError(error.InvalidAnalyticsTable, (Config{ .backend = .clickhouse, .base_url = "http://127.0.0.1:8123", .table = "bad table" }).validateUsable());
    try std.testing.expectError(error.InvalidAnalyticsTable, (Config{ .backend = .clickhouse, .base_url = "http://127.0.0.1:8123", .table = ".events" }).validateUsable());
    try std.testing.expectError(error.InvalidAnalyticsTable, (Config{ .backend = .clickhouse, .base_url = "http://127.0.0.1:8123", .table = "events." }).validateUsable());
    try std.testing.expectError(error.InvalidAnalyticsBackend, (Config{ .backend = .clickhouse, .base_url = "http://127.0.0.1:8123", .timeout_secs = 0 }).validateUsable());
    try std.testing.expectError(error.InvalidAnalyticsBackend, (Config{ .backend = .clickhouse, .base_url = "http://127.0.0.1:8123", .timeout_secs = runtime_limits.max_timeout_secs + 1 }).validateUsable());
    try std.testing.expectError(error.InvalidRuntimeUrl, (Config{ .backend = .clickhouse, .base_url = "https://token@clickhouse.example" }).validateUsable());
    try std.testing.expectError(error.InvalidRuntimeUrl, (Config{ .backend = .clickhouse, .base_url = "https://clickhouse.example?token=x" }).validateUsable());
    try std.testing.expectError(error.InsecureRuntimeUrl, (Config{ .backend = .clickhouse, .base_url = "http://clickhouse.internal:8123" }).validateUsable());
    try std.testing.expectError(error.InvalidHttpHeaderValue, (Config{ .backend = .clickhouse, .base_url = "http://127.0.0.1:8123", .api_key = "bad\r\nX: y" }).validateUsable());

    try (Config{ .backend = .clickhouse, .base_url = "http://127.0.0.1:8123", .table = "np.events" }).validateUsable();
    try (Config{ .backend = .clickhouse, .base_url = "https://clickhouse.example", .table = "np_events" }).validateUsable();
}

test "clickhouse query URL percent-encodes SQL" {
    const url = try clickhouseQueryUrl(std.testing.allocator, .{ .backend = .clickhouse, .base_url = "http://127.0.0.1:8123///" }, "SELECT count() FROM np.events");
    defer std.testing.allocator.free(url);
    try std.testing.expect(std.mem.startsWith(u8, url, "http://127.0.0.1:8123/?query="));
    try std.testing.expect(std.mem.indexOf(u8, url, "SELECT%20count%28%29%20FROM%20np.events") != null);
}

test "clickhouse analytics live contract when configured" {
    const base_url = compat.process.getEnvVarOwned(std.testing.allocator, "NULLPANTRY_TEST_CLICKHOUSE_URL") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => {
            const required = compat.process.getEnvVarOwned(std.testing.allocator, "NULLPANTRY_REQUIRE_CLICKHOUSE_TEST") catch null;
            if (required) |value| {
                std.testing.allocator.free(value);
                return error.MissingClickHouseContractUrl;
            }
            return error.SkipZigTest;
        },
        else => return err,
    };
    defer std.testing.allocator.free(base_url);

    const table = try ids.make(std.testing.allocator, "nullpantry_contract_");
    defer std.testing.allocator.free(table);
    const cfg = Config{ .backend = .clickhouse, .base_url = base_url, .table = table, .timeout_secs = 10 };
    const event_id: i64 = ids.nowMs();
    const events = [_]Event{.{
        .event_source = "contract",
        .event_id = event_id,
        .event_type = "contract.insert",
        .actor_id = "agent:contract",
        .object_type = "memory_atom",
        .object_id = "mem_contract",
        .scope = "public",
        .permissions_json = "[\"public\"]",
        .payload_json = "{\"contract\":true}",
        .created_at_ms = 42,
    }};
    const first_export = try exportEvents(std.testing.allocator, cfg, &events);
    try std.testing.expectEqual(@as(usize, 1), first_export.attempted);
    try std.testing.expectEqual(@as(usize, 1), first_export.inserted);
    try std.testing.expectEqual(@as(usize, 0), first_export.skipped_existing);
    const second_export = try exportEvents(std.testing.allocator, cfg, &events);
    try std.testing.expectEqual(@as(usize, 1), second_export.attempted);
    try std.testing.expectEqual(@as(usize, 0), second_export.inserted);
    try std.testing.expectEqual(@as(usize, 1), second_export.skipped_existing);

    const ch_status = try status(std.testing.allocator, cfg);
    try std.testing.expect(ch_status.rows >= 1);

    const events_json = try queryEventsJson(std.testing.allocator, cfg, .{ .event_source = "contract", .object_id = "mem_contract", .limit = 10 });
    defer std.testing.allocator.free(events_json);
    try std.testing.expect(std.mem.indexOf(u8, events_json, "\"event_source\":\"contract\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events_json, "\"object_id\":\"mem_contract\"") != null);

    const select_query = try std.fmt.allocPrint(std.testing.allocator, "SELECT count() FROM {s} FINAL WHERE event_source = 'contract' AND event_id = {d}", .{ table, event_id });
    defer std.testing.allocator.free(select_query);
    var found = false;
    var attempt: usize = 0;
    while (attempt < 5) : (attempt += 1) {
        const count_body = try clickhouseQuery(std.testing.allocator, cfg, select_query);
        defer std.testing.allocator.free(count_body);
        const trimmed = std.mem.trim(u8, count_body, " \t\r\n");
        const count = std.fmt.parseInt(u64, trimmed, 10) catch 0;
        if (count == 1) {
            found = true;
            break;
        }
        std.Io.sleep(compat.io(), .fromNanoseconds(@intCast(100 * std.time.ns_per_ms)), .awake) catch {};
    }
    try std.testing.expect(found);
}
