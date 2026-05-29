const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat.zig");
const ids = @import("ids.zig");
const json = @import("json_util.zig");

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

pub fn exportEvents(allocator: std.mem.Allocator, cfg: Config, events: []const Event) !usize {
    if (!cfg.enabled()) return error.AnalyticsBackendNotConfigured;
    if (events.len == 0) return 0;
    return switch (cfg.backend) {
        .none => error.AnalyticsBackendNotConfigured,
        .clickhouse => clickhouseInsert(allocator, cfg, events),
    };
}

fn clickhouseInsert(allocator: std.mem.Allocator, cfg: Config, events: []const Event) !usize {
    const table = try safeIdentifier(allocator, cfg.table);
    defer allocator.free(table);
    try clickhouseEnsureTable(allocator, cfg, table);
    const query = try std.fmt.allocPrint(allocator, "INSERT INTO {s} FORMAT JSONEachRow", .{table});
    defer allocator.free(query);
    const url = try clickhouseQueryUrl(allocator, cfg.base_url.?, query);
    defer allocator.free(url);
    const body = try eventsJsonEachRow(allocator, events);
    defer allocator.free(body);
    const response = try post(allocator, url, cfg.api_key, cfg.timeout_secs, "application/x-ndjson", body);
    defer allocator.free(response);
    return events.len;
}

fn clickhouseEnsureTable(allocator: std.mem.Allocator, cfg: Config, table: []const u8) !void {
    const query = try std.fmt.allocPrint(
        allocator,
        "CREATE TABLE IF NOT EXISTS {s} (event_source String, event_id Int64, event_type String, operation Nullable(String), actor_id Nullable(String), object_type String, object_id String, scope Nullable(String), permissions_json String, status Nullable(String), payload_json String, causality_json String, created_at_ms Int64) ENGINE = MergeTree ORDER BY (event_source, event_id)",
        .{table},
    );
    defer allocator.free(query);
    const url = try clickhouseQueryUrl(allocator, cfg.base_url.?, query);
    defer allocator.free(url);
    const response = try post(allocator, url, cfg.api_key, cfg.timeout_secs, "text/plain", "");
    defer allocator.free(response);
}

fn clickhouseQuery(allocator: std.mem.Allocator, cfg: Config, query: []const u8) ![]u8 {
    if (!cfg.enabled()) return error.AnalyticsBackendNotConfigured;
    const url = try clickhouseQueryUrl(allocator, cfg.base_url.?, query);
    defer allocator.free(url);
    return post(allocator, url, cfg.api_key, cfg.timeout_secs, "text/plain", "");
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

fn clickhouseQueryUrl(allocator: std.mem.Allocator, base_url: []const u8, query: []const u8) ![]u8 {
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
}

test "clickhouse query URL percent-encodes SQL" {
    const url = try clickhouseQueryUrl(std.testing.allocator, "http://127.0.0.1:8123", "SELECT count() FROM np.events");
    defer std.testing.allocator.free(url);
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
    try std.testing.expectEqual(@as(usize, 1), try exportEvents(std.testing.allocator, cfg, &events));
    const select_query = try std.fmt.allocPrint(std.testing.allocator, "SELECT count() FROM {s} WHERE event_id = {d}", .{ table, event_id });
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
