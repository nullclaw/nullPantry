const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat.zig");
const ids = @import("ids.zig");
const json = @import("json_util.zig");
const net_security = @import("net_security.zig");

pub const max_analytics_response_bytes: usize = 8 * 1024 * 1024;

pub const BackendKind = enum {
    none,
    clickhouse,

    pub fn parse(raw: []const u8) BackendKind {
        if (std.ascii.eqlIgnoreCase(raw, "clickhouse")) return .clickhouse;
        return .none;
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
        return self.backend == .clickhouse and self.base_url != null and self.table.len > 0;
    }
};

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
    if (!cfg.enabled()) return error.AnalyticsBackendNotConfigured;
    if (events.len == 0) return .{};
    return switch (cfg.backend) {
        .none => error.AnalyticsBackendNotConfigured,
        .clickhouse => clickhouseInsert(allocator, cfg, events),
    };
}

pub fn status(allocator: std.mem.Allocator, cfg: Config) !Status {
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
    return parseStatus(body);
}

pub fn queryEventsJson(allocator: std.mem.Allocator, cfg: Config, input: QueryInput) ![]u8 {
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
    return jsonEachRowsToArray(allocator, body);
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
        try appendSqlString(allocator, &tuples, event.event_source);
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
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const source = line[0..tab];
        const event_id = std.fmt.parseInt(i64, std.mem.trim(u8, line[tab + 1 ..], " \t\r\n"), 10) catch continue;
        try keys.append(allocator, .{
            .event_source = try allocator.dupe(u8, source),
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

fn parseStatus(body: []const u8) Status {
    const line = std.mem.trim(u8, body, " \t\r\n");
    if (line.len == 0) return .{};
    var columns = std.mem.splitScalar(u8, line, '\t');
    return .{
        .rows = parseUsize(columns.next() orelse "0"),
        .audit_max_id = parseI64(columns.next() orelse "0"),
        .feed_max_id = parseI64(columns.next() orelse "0"),
        .latest_created_at_ms = parseI64(columns.next() orelse "0"),
    };
}

fn parseUsize(raw: []const u8) usize {
    return std.fmt.parseInt(usize, std.mem.trim(u8, raw, " \t\r\n"), 10) catch 0;
}

fn parseI64(raw: []const u8) i64 {
    return std.fmt.parseInt(i64, std.mem.trim(u8, raw, " \t\r\n"), 10) catch 0;
}

fn appendOptionalFilter(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), column: []const u8, value: ?[]const u8) !void {
    const actual = value orelse return;
    try out.appendSlice(allocator, " AND ");
    try out.appendSlice(allocator, column);
    try out.appendSlice(allocator, " = ");
    try appendSqlString(allocator, out, actual);
}

fn appendSqlString(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), value: []const u8) !void {
    try out.append(allocator, '\'');
    for (value) |ch| {
        if (ch == '\'') {
            try out.appendSlice(allocator, "''");
        } else if (ch == '\\') {
            try out.appendSlice(allocator, "\\\\");
        } else {
            try out.append(allocator, ch);
        }
    }
    try out.append(allocator, '\'');
}

fn jsonEachRowsToArray(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '[');
    var first = true;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;
        if (!(std.json.validate(allocator, line) catch false)) continue;
        if (!first) try out.append(allocator, ',');
        try out.appendSlice(allocator, line);
        first = false;
    }
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
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
    if (raw.len == 0) return error.InvalidAnalyticsTable;
    for (raw) |ch| {
        const ok = std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '.';
        if (!ok) return error.InvalidAnalyticsTable;
    }
    return allocator.dupe(u8, raw);
}

fn joinUrl(allocator: std.mem.Allocator, base_url: []const u8, suffix: []const u8) ![]u8 {
    var end = base_url.len;
    while (end > 0 and base_url[end - 1] == '/') : (end -= 1) {}
    if (suffix.len > 0 and suffix[0] == '?') return std.fmt.allocPrint(allocator, "{s}/{s}", .{ base_url[0..end], suffix });
    if (suffix.len > 0 and suffix[0] == '/') return std.fmt.allocPrint(allocator, "{s}{s}", .{ base_url[0..end], suffix });
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ base_url[0..end], suffix });
}

fn clickhouseQueryUrl(allocator: std.mem.Allocator, cfg: Config, query: []const u8) ![]u8 {
    const base_url = cfg.base_url orelse return error.AnalyticsBackendNotConfigured;
    try net_security.validateHttpBaseUrl(base_url, cfg.allow_insecure_http);
    const encoded = try percentEncode(allocator, query);
    defer allocator.free(encoded);
    const suffix = try std.fmt.allocPrint(allocator, "?query={s}", .{encoded});
    defer allocator.free(suffix);
    return joinUrl(allocator, base_url, suffix);
}

fn percentEncode(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    const hex_digits = "0123456789ABCDEF";
    for (raw) |ch| {
        const unreserved = std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~';
        if (unreserved) {
            try out.append(allocator, ch);
        } else {
            try out.append(allocator, '%');
            try out.append(allocator, hex_digits[ch >> 4]);
            try out.append(allocator, hex_digits[ch & 0x0f]);
        }
    }
    return out.toOwnedSlice(allocator);
}

fn post(allocator: std.mem.Allocator, url: []const u8, api_key: ?[]const u8, timeout_secs: u32, content_type: []const u8, body: []const u8) ![]u8 {
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

    applySocketTimeout(req.connection, timeout_secs);

    req.transfer_encoding = .{ .content_length = body.len };
    var body_writer = req.sendBodyUnflushed(&.{}) catch return error.AnalyticsBackendUnavailable;
    body_writer.writer.writeAll(body) catch return error.AnalyticsBackendUnavailable;
    body_writer.end() catch return error.AnalyticsBackendUnavailable;
    req.connection.?.flush() catch return error.AnalyticsBackendUnavailable;

    var response = req.receiveHead(&.{}) catch return error.AnalyticsBackendUnavailable;
    if (response.head.status != .ok) return error.AnalyticsBackendHttpError;

    const reader = response.reader(&.{});
    const read_limit = max_analytics_response_bytes + 1;
    const response_body = reader.allocRemaining(allocator, .limited(read_limit)) catch return error.AnalyticsBackendUnavailable;
    if (response_body.len > max_analytics_response_bytes) {
        allocator.free(response_body);
        return error.AnalyticsBackendResponseTooLarge;
    }
    return response_body;
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

test "clickhouse analytics config gates runtime" {
    try std.testing.expect(!(Config{}).enabled());
    try std.testing.expect((Config{ .backend = .clickhouse, .base_url = "http://127.0.0.1:8123" }).enabled());
    try std.testing.expect(BackendKind.parse("clickhouse") == .clickhouse);
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

test "clickhouse query URL percent-encodes SQL" {
    const url = try clickhouseQueryUrl(std.testing.allocator, .{ .backend = .clickhouse, .base_url = "http://127.0.0.1:8123" }, "SELECT count() FROM np.events");
    defer std.testing.allocator.free(url);
    try std.testing.expect(std.mem.indexOf(u8, url, "SELECT%20count%28%29%20FROM%20np.events") != null);
}

test "clickhouse json each row output is wrapped as a JSON array" {
    const body = "{\"event_source\":\"audit\",\"event_id\":1}\nnot-json\n{\"event_source\":\"memory_feed\",\"event_id\":2}\n";
    const array = try jsonEachRowsToArray(std.testing.allocator, body);
    defer std.testing.allocator.free(array);
    try std.testing.expectEqualStrings("[{\"event_source\":\"audit\",\"event_id\":1},{\"event_source\":\"memory_feed\",\"event_id\":2}]", array);
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
