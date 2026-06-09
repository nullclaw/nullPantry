const std = @import("std");
const json = @import("json_util.zig");
const net_security = @import("net_security.zig");

pub fn validTableName(raw: []const u8) bool {
    if (raw.len == 0) return false;
    if (std.mem.trim(u8, raw, " \t\r\n").len != raw.len) return false;
    var previous_dot = true;
    for (raw) |ch| {
        if (ch == '.') {
            if (previous_dot) return false;
            previous_dot = true;
            continue;
        }
        if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
        previous_dot = false;
    }
    return !previous_dot;
}

pub fn appendStringLiteral(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), value: []const u8) !void {
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

pub fn queryUrl(allocator: std.mem.Allocator, base_url: []const u8, sql: []const u8, allow_insecure_http: bool) ![]u8 {
    const encoded = try net_security.percentEncodePathSegment(allocator, sql);
    defer allocator.free(encoded);
    const suffix = try std.fmt.allocPrint(allocator, "?query={s}", .{encoded});
    defer allocator.free(suffix);
    return net_security.joinHttpBaseUrl(allocator, base_url, suffix, allow_insecure_http);
}

pub fn jsonEachRowsToArray(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '[');
    var first = true;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;
        if (!(try std.json.validate(allocator, line))) return error.InvalidClickHouseJsonEachRow;
        if (!first) try out.append(allocator, ',');
        try out.appendSlice(allocator, line);
        first = false;
    }
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

pub fn parseTsvUsize(raw: []const u8) !usize {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidClickHouseTsvNumber;
    return std.fmt.parseInt(usize, trimmed, 10) catch return error.InvalidClickHouseTsvNumber;
}

pub fn parseTsvU64(raw: []const u8) !u64 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidClickHouseTsvNumber;
    return std.fmt.parseInt(u64, trimmed, 10) catch return error.InvalidClickHouseTsvNumber;
}

pub fn parseTsvI64(raw: []const u8) !i64 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidClickHouseTsvNumber;
    return std.fmt.parseInt(i64, trimmed, 10) catch return error.InvalidClickHouseTsvNumber;
}

pub fn jsonRequiredStringField(obj: std.json.ObjectMap, name: []const u8) ![]const u8 {
    const value = obj.get(name) orelse return error.InvalidClickHouseJsonField;
    return switch (value) {
        .string => |s| s,
        else => return error.InvalidClickHouseJsonField,
    };
}

pub fn jsonRequiredNullableStringField(obj: std.json.ObjectMap, name: []const u8) !?[]const u8 {
    const value = obj.get(name) orelse return error.InvalidClickHouseJsonField;
    return switch (value) {
        .null => null,
        .string => |s| s,
        else => return error.InvalidClickHouseJsonField,
    };
}

pub fn jsonRequiredU64Field(obj: std.json.ObjectMap, name: []const u8) !u64 {
    const value = obj.get(name) orelse return error.InvalidClickHouseJsonField;
    return switch (value) {
        .integer => |n| if (n >= 0) @intCast(n) else return error.InvalidClickHouseJsonField,
        .float => |f| json.safeFloatToU64(f) orelse return error.InvalidClickHouseJsonField,
        .string => |s| parseJsonU64String(s),
        else => return error.InvalidClickHouseJsonField,
    };
}

pub fn jsonRequiredI64Field(obj: std.json.ObjectMap, name: []const u8) !i64 {
    const value = obj.get(name) orelse return error.InvalidClickHouseJsonField;
    return switch (value) {
        .integer => |n| n,
        .float => |f| json.safeFloatToI64(f) orelse return error.InvalidClickHouseJsonField,
        .string => |s| parseJsonI64String(s),
        else => return error.InvalidClickHouseJsonField,
    };
}

pub fn jsonRequiredNullableI64Field(obj: std.json.ObjectMap, name: []const u8) !?i64 {
    const value = obj.get(name) orelse return error.InvalidClickHouseJsonField;
    return switch (value) {
        .null => null,
        .integer => |n| n,
        .float => |f| json.safeFloatToI64(f) orelse return error.InvalidClickHouseJsonField,
        .string => |s| try parseJsonI64String(s),
        else => return error.InvalidClickHouseJsonField,
    };
}

fn parseJsonU64String(raw: []const u8) !u64 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidClickHouseJsonField;
    return std.fmt.parseInt(u64, trimmed, 10) catch return error.InvalidClickHouseJsonField;
}

fn parseJsonI64String(raw: []const u8) !i64 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidClickHouseJsonField;
    return std.fmt.parseInt(i64, trimmed, 10) catch return error.InvalidClickHouseJsonField;
}

test "clickhouse table names use a shared safe unquoted identifier subset" {
    try std.testing.expect(validTableName("nullpantry_events"));
    try std.testing.expect(validTableName("np.agent_memory"));
    try std.testing.expect(validTableName("_scratch_01"));

    try std.testing.expect(!validTableName(""));
    try std.testing.expect(!validTableName(" events"));
    try std.testing.expect(!validTableName("events "));
    try std.testing.expect(!validTableName(".events"));
    try std.testing.expect(!validTableName("np..events"));
    try std.testing.expect(!validTableName("events."));
    try std.testing.expect(!validTableName("bad table"));
    try std.testing.expect(!validTableName("events;drop table memory_atoms"));
}

test "clickhouse string literals escape quotes and backslashes" {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(std.testing.allocator);

    try appendStringLiteral(std.testing.allocator, &out, "agent's\\memory");
    try std.testing.expectEqualStrings("'agent''s\\\\memory'", out.items);
}

test "clickhouse query URLs percent-encode SQL query parameters" {
    const url = try queryUrl(std.testing.allocator, "http://127.0.0.1:8123///", "SELECT count() FROM np.events WHERE actor = 'agent:a'", false);
    defer std.testing.allocator.free(url);

    try std.testing.expectEqualStrings("http://127.0.0.1:8123/?query=SELECT%20count%28%29%20FROM%20np.events%20WHERE%20actor%20%3D%20%27agent%3Aa%27", url);
}

test "clickhouse JSONEachRow output is wrapped as a JSON array" {
    const body = "{\"event_source\":\"audit\",\"event_id\":1}\n\n{\"event_source\":\"memory_feed\",\"event_id\":2}\n";
    const array = try jsonEachRowsToArray(std.testing.allocator, body);
    defer std.testing.allocator.free(array);

    try std.testing.expectEqualStrings("[{\"event_source\":\"audit\",\"event_id\":1},{\"event_source\":\"memory_feed\",\"event_id\":2}]", array);
    try std.testing.expectError(error.InvalidClickHouseJsonEachRow, jsonEachRowsToArray(std.testing.allocator, "{\"event_source\":\"audit\"}\nnot-json\n"));
}

test "clickhouse TSV numeric fields are parsed strictly" {
    try std.testing.expectEqual(@as(usize, 42), try parseTsvUsize(" 42\n"));
    try std.testing.expectEqual(@as(u64, 42), try parseTsvU64(" 42\n"));
    try std.testing.expectEqual(@as(i64, -7), try parseTsvI64("\t-7\r\n"));

    try std.testing.expectError(error.InvalidClickHouseTsvNumber, parseTsvUsize(""));
    try std.testing.expectError(error.InvalidClickHouseTsvNumber, parseTsvUsize("bad"));
    try std.testing.expectError(error.InvalidClickHouseTsvNumber, parseTsvUsize("-1"));
    try std.testing.expectError(error.InvalidClickHouseTsvNumber, parseTsvU64("-1"));
    try std.testing.expectError(error.InvalidClickHouseTsvNumber, parseTsvI64("1.5"));
}

test "clickhouse JSON scalar fields are required and strict" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"session_id\":\"sess-a\",\"nullable\":null,\"count\":\"9\",\"first\":3,\"last\":4.0,\"bad_float\":4.5,\"negative\":-1}",
        .{},
    );
    defer parsed.deinit();
    const obj = parsed.value.object;

    try std.testing.expectEqualStrings("sess-a", try jsonRequiredStringField(obj, "session_id"));
    try std.testing.expect((try jsonRequiredNullableStringField(obj, "nullable")) == null);
    try std.testing.expectEqual(@as(u64, 9), try jsonRequiredU64Field(obj, "count"));
    try std.testing.expectEqual(@as(i64, 3), try jsonRequiredI64Field(obj, "first"));
    try std.testing.expectEqual(@as(i64, 4), try jsonRequiredI64Field(obj, "last"));
    try std.testing.expect((try jsonRequiredNullableI64Field(obj, "nullable")) == null);

    try std.testing.expectError(error.InvalidClickHouseJsonField, jsonRequiredStringField(obj, "missing"));
    try std.testing.expectError(error.InvalidClickHouseJsonField, jsonRequiredNullableStringField(obj, "first"));
    try std.testing.expectError(error.InvalidClickHouseJsonField, jsonRequiredU64Field(obj, "negative"));
    try std.testing.expectError(error.InvalidClickHouseJsonField, jsonRequiredI64Field(obj, "bad_float"));
    try std.testing.expectError(error.InvalidClickHouseJsonField, jsonRequiredNullableI64Field(obj, "bad_float"));
}
