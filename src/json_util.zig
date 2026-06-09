const std = @import("std");

const max_precise_float_integer: f64 = 9_007_199_254_740_991.0;

pub const ParsedPath = struct {
    path: []const u8,
    query: []const u8 = "",
};

pub fn parsePath(target: []const u8) ParsedPath {
    const q = std.mem.indexOfScalar(u8, target, '?') orelse return .{ .path = target };
    return .{ .path = target[0..q], .query = target[q + 1 ..] };
}

pub fn segment(path: []const u8, index: usize) ?[]const u8 {
    var it = std.mem.splitScalar(u8, path, '/');
    var seen: usize = 0;
    while (it.next()) |part| {
        if (part.len == 0) continue;
        if (seen == index) return part;
        seen += 1;
    }
    return null;
}

pub fn queryParam(query: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, part, '=') orelse continue;
        if (std.mem.eql(u8, part[0..eq], name)) return part[eq + 1 ..];
    }
    return null;
}

pub fn queryParamDecoded(allocator: std.mem.Allocator, query: []const u8, name: []const u8) !?[]u8 {
    const raw = queryParam(query, name) orelse return null;
    return try percentDecode(allocator, raw);
}

pub fn percentDecode(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        if (value[i] == '%' and i + 2 < value.len) {
            const byte = std.fmt.parseInt(u8, value[i + 1 .. i + 3], 16) catch {
                try out.append(allocator, value[i]);
                continue;
            };
            try out.append(allocator, byte);
            i += 2;
        } else if (value[i] == '+') {
            try out.append(allocator, ' ');
        } else {
            try out.append(allocator, value[i]);
        }
    }
    return out.toOwnedSlice(allocator);
}

pub fn extractBody(raw: []const u8) []const u8 {
    const idx = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return "";
    return raw[idx + 4 ..];
}

pub fn extractHeader(raw: []const u8, name: []const u8) ?[]const u8 {
    const header_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse raw.len;
    var lines = std.mem.splitSequence(u8, raw[0..header_end], "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(key, name)) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

pub fn bearerToken(raw: []const u8) ?[]const u8 {
    const header = extractHeader(raw, "Authorization") orelse return null;
    if (!std.ascii.startsWithIgnoreCase(header, "Bearer ")) return null;
    return std.mem.trim(u8, header["Bearer ".len..], " \t");
}

pub fn appendString(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    var w: std.Io.Writer.Allocating = .fromArrayList(allocator, buf);
    errdefer buf.* = w.toArrayList();
    try std.json.Stringify.value(value, .{}, &w.writer);
    buf.* = w.toArrayList();
}

pub fn stringLiteral(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendString(&out, allocator, value);
    return out.toOwnedSlice(allocator);
}

pub fn appendNullableString(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: ?[]const u8) !void {
    if (value) |v| {
        try appendString(buf, allocator, v);
    } else {
        try buf.appendSlice(allocator, "null");
    }
}

pub const RawJsonRoot = enum { array, object };

pub fn rawJsonRootOrError(allocator: std.mem.Allocator, raw: ?[]const u8, fallback: []const u8, root: RawJsonRoot) ![]const u8 {
    const text = std.mem.trim(u8, raw orelse fallback, " \t\r\n");
    if (!rawJsonRootIs(allocator, text, root)) return error.InvalidRawJson;
    return text;
}

pub fn rawJsonObjectOrError(allocator: std.mem.Allocator, raw: ?[]const u8, fallback: []const u8) ![]const u8 {
    return rawJsonRootOrError(allocator, raw, fallback, .object);
}

pub fn rawJsonArrayOrError(allocator: std.mem.Allocator, raw: ?[]const u8, fallback: []const u8) ![]const u8 {
    return rawJsonRootOrError(allocator, raw, fallback, .array);
}

pub fn appendRawJsonArray(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, raw: ?[]const u8) !void {
    const text = try rawJsonArrayOrError(allocator, raw, "[]");
    try buf.appendSlice(allocator, text);
}

pub fn appendOptionalRawJsonArray(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, raw: []const u8) !void {
    const text = std.mem.trim(u8, raw, " \t\r\n");
    if (text.len == 0) {
        try buf.appendSlice(allocator, "[]");
        return;
    }
    try appendRawJsonArray(buf, allocator, text);
}

pub fn appendRawJsonObject(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, raw: ?[]const u8) !void {
    const text = try rawJsonObjectOrError(allocator, raw, "{}");
    try buf.appendSlice(allocator, text);
}

pub fn rawJsonRootIs(allocator: std.mem.Allocator, raw: ?[]const u8, root: RawJsonRoot) bool {
    const text = std.mem.trim(u8, raw orelse return false, " \t\r\n");
    if (text.len == 0) return false;
    const expected_root: u8 = switch (root) {
        .array => '[',
        .object => '{',
    };
    if (text[0] != expected_root) return false;
    return std.json.validate(allocator, text) catch false;
}

pub fn rawJsonAliasRequiresJson(name: []const u8) bool {
    return rawJsonFieldNameRequiresJson(name);
}

pub fn rawJsonFieldNameAcceptsEncodedString(name: []const u8) bool {
    return rawJsonFieldNameRequiresJson(name) or
        std.mem.eql(u8, name, "payload") or
        std.mem.eql(u8, name, "causality") or
        std.mem.eql(u8, name, "permissions");
}

pub fn rawJsonFieldNameRequiresJson(name: []const u8) bool {
    return std.mem.endsWith(u8, name, "_json");
}

pub fn rawJsonFieldFallback(allocator: std.mem.Allocator, name: []const u8, fallback: []const u8) ![]u8 {
    if (!rawJsonFieldNameRequiresJson(name)) return allocator.dupe(u8, fallback);
    const trimmed = std.mem.trim(u8, fallback, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidRawJson;
    if (!(std.json.validate(allocator, trimmed) catch false)) return error.InvalidRawJson;
    return allocator.dupe(u8, trimmed);
}

pub fn rawJsonFieldValue(allocator: std.mem.Allocator, name: []const u8, value: std.json.Value, fallback: []const u8) ![]u8 {
    if (value == .null) return rawJsonFieldFallback(allocator, name, fallback);
    if (value == .string and rawJsonFieldNameAcceptsEncodedString(name)) {
        const trimmed = std.mem.trim(u8, value.string, " \t\r\n");
        if (trimmed.len == 0) return rawJsonFieldFallback(allocator, name, fallback);
        if (std.json.validate(allocator, trimmed) catch false) return allocator.dupe(u8, trimmed);
        if (rawJsonFieldNameRequiresJson(name)) return error.InvalidRawJson;
    }
    return try jsonFromValue(allocator, value);
}

pub fn jsonFromValue(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
}

pub fn stringField(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = obj.get(name) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

pub fn nullableStringField(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = obj.get(name) orelse return null;
    return switch (value) {
        .string => |s| s,
        .null => null,
        else => null,
    };
}

pub fn intField(obj: std.json.ObjectMap, name: []const u8) ?i64 {
    const value = obj.get(name) orelse return null;
    return switch (value) {
        .integer => |n| n,
        .float => |f| safeFloatToI64(f),
        else => null,
    };
}

pub fn safeFloatToI64(value: f64) ?i64 {
    if (!std.math.isFinite(value)) return null;
    if (@floor(value) != value) return null;
    if (value < -max_precise_float_integer or value > max_precise_float_integer) return null;
    if (value < @as(f64, @floatFromInt(std.math.minInt(i64)))) return null;
    if (value >= @as(f64, @floatFromInt(std.math.maxInt(i64)))) return null;
    return @intFromFloat(value);
}

pub fn safeFloatToU64(value: f64) ?u64 {
    if (!std.math.isFinite(value)) return null;
    if (@floor(value) != value) return null;
    if (value < 0) return null;
    if (value > max_precise_float_integer) return null;
    if (value >= @as(f64, @floatFromInt(std.math.maxInt(u64)))) return null;
    return @intFromFloat(value);
}

pub fn floatField(obj: std.json.ObjectMap, name: []const u8) ?f64 {
    const value = obj.get(name) orelse return null;
    return switch (value) {
        .float => |f| f,
        .integer => |n| @floatFromInt(n),
        else => null,
    };
}

pub fn boolField(obj: std.json.ObjectMap, name: []const u8) ?bool {
    const value = obj.get(name) orelse return null;
    return switch (value) {
        .bool => |b| b,
        else => null,
    };
}

pub fn valueJsonField(allocator: std.mem.Allocator, obj: std.json.ObjectMap, name: []const u8, fallback: []const u8) ![]u8 {
    const value = obj.get(name) orelse return allocator.dupe(u8, fallback);
    return jsonFromValue(allocator, value);
}

pub fn response(allocator: std.mem.Allocator, status: []const u8, body: []const u8) !HttpResponse {
    return .{ .status = status, .body = try allocator.dupe(u8, body) };
}

pub const HttpResponse = struct {
    status: []const u8,
    body: []const u8,
};

pub fn errorResponse(allocator: std.mem.Allocator, code: u16, code_text: []const u8, message: []const u8) HttpResponse {
    const status = switch (code) {
        400 => "400 Bad Request",
        401 => "401 Unauthorized",
        403 => "403 Forbidden",
        404 => "404 Not Found",
        405 => "405 Method Not Allowed",
        410 => "410 Gone",
        409 => "409 Conflict",
        413 => "413 Payload Too Large",
        502 => "502 Bad Gateway",
        500 => "500 Internal Server Error",
        501 => "501 Not Implemented",
        else => "400 Bad Request",
    };
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(allocator, "{\"error\":") catch return fallbackErrorResponse(status);
    appendString(&out, allocator, code_text) catch {
        out.deinit(allocator);
        return fallbackErrorResponse(status);
    };
    out.appendSlice(allocator, ",\"message\":") catch {
        out.deinit(allocator);
        return fallbackErrorResponse(status);
    };
    appendString(&out, allocator, message) catch {
        out.deinit(allocator);
        return fallbackErrorResponse(status);
    };
    out.append(allocator, '}') catch {
        out.deinit(allocator);
        return fallbackErrorResponse(status);
    };
    const body = out.toOwnedSlice(allocator) catch {
        out.deinit(allocator);
        return fallbackErrorResponse(status);
    };
    return .{ .status = status, .body = body };
}

fn fallbackErrorResponse(status: []const u8) HttpResponse {
    return .{ .status = status, .body = "{\"error\":\"internal\"}" };
}

test "json string literal uses canonical escaping" {
    const literal = try stringLiteral(std.testing.allocator, "team:\"alpha\"");
    defer std.testing.allocator.free(literal);
    try std.testing.expectEqualStrings("\"team:\\\"alpha\\\"\"", literal);
}

test "json error response escapes code and message" {
    const resp = errorResponse(std.testing.allocator, 501, "engine\"bad", "Message \"quoted\"\nline");
    defer std.testing.allocator.free(resp.body);

    try std.testing.expectEqualStrings("501 Not Implemented", resp.status);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, resp.body, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("engine\"bad", obj.get("error").?.string);
    try std.testing.expectEqualStrings("Message \"quoted\"\nline", obj.get("message").?.string);
}

test "json error response maps payload too large status" {
    const resp = errorResponse(std.testing.allocator, 413, "payload_too_large", "Too large");
    defer std.testing.allocator.free(resp.body);

    try std.testing.expectEqualStrings("413 Payload Too Large", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"payload_too_large\"") != null);
}

test "json raw append helpers preserve valid root containers" {
    var array_out: std.ArrayListUnmanaged(u8) = .empty;
    defer array_out.deinit(std.testing.allocator);
    try appendRawJsonArray(&array_out, std.testing.allocator, " [\"public\"] ");
    try std.testing.expectEqualStrings("[\"public\"]", array_out.items);

    var object_out: std.ArrayListUnmanaged(u8) = .empty;
    defer object_out.deinit(std.testing.allocator);
    try appendRawJsonObject(&object_out, std.testing.allocator, " {\"ok\":true} ");
    try std.testing.expectEqualStrings("{\"ok\":true}", object_out.items);
}

test "json raw append helpers use typed defaults for absent values" {
    var default_object: std.ArrayListUnmanaged(u8) = .empty;
    defer default_object.deinit(std.testing.allocator);
    try appendRawJsonObject(&default_object, std.testing.allocator, null);
    try std.testing.expectEqualStrings("{}", default_object.items);

    var default_array: std.ArrayListUnmanaged(u8) = .empty;
    defer default_array.deinit(std.testing.allocator);
    try appendRawJsonArray(&default_array, std.testing.allocator, null);
    try std.testing.expectEqualStrings("[]", default_array.items);
}

test "json raw append helpers reject wrong roots and malformed payloads" {
    var array_out: std.ArrayListUnmanaged(u8) = .empty;
    defer array_out.deinit(std.testing.allocator);

    var object_out: std.ArrayListUnmanaged(u8) = .empty;
    defer object_out.deinit(std.testing.allocator);

    try std.testing.expectError(error.InvalidRawJson, appendRawJsonArray(&array_out, std.testing.allocator, "{\"ok\":true}"));
    try std.testing.expectError(error.InvalidRawJson, appendRawJsonArray(&array_out, std.testing.allocator, "[\"broken\","));
    try std.testing.expectError(error.InvalidRawJson, appendRawJsonObject(&object_out, std.testing.allocator, "[\"ok\"]"));
    try std.testing.expectError(error.InvalidRawJson, appendRawJsonObject(&object_out, std.testing.allocator, "{\"broken\":"));
}

test "json raw root defaults must match the requested container type" {
    try std.testing.expectError(error.InvalidRawJson, rawJsonArrayOrError(std.testing.allocator, null, "{}"));
    try std.testing.expectError(error.InvalidRawJson, rawJsonObjectOrError(std.testing.allocator, null, "[]"));
}

test "optional raw json array treats blank input as the array default" {
    var optional_array: std.ArrayListUnmanaged(u8) = .empty;
    defer optional_array.deinit(std.testing.allocator);
    try appendOptionalRawJsonArray(&optional_array, std.testing.allocator, " \t ");
    try std.testing.expectEqualStrings("[]", optional_array.items);
    try std.testing.expectError(error.InvalidRawJson, appendOptionalRawJsonArray(&optional_array, std.testing.allocator, "{\"ok\":true}"));
}

test "raw json field fallback is strict for json suffix aliases" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"blank\":\" \\t \",\"nullish\":null}",
        .{},
    );
    defer parsed.deinit();
    const obj = parsed.value.object;

    try std.testing.expectError(error.InvalidRawJson, rawJsonFieldFallback(std.testing.allocator, "metadata_json", "{\"broken\":"));
    try std.testing.expectError(error.InvalidRawJson, rawJsonFieldValue(std.testing.allocator, "metadata_json", obj.get("blank").?, "{\"broken\":"));
    try std.testing.expectError(error.InvalidRawJson, rawJsonFieldValue(std.testing.allocator, "metadata_json", obj.get("nullish").?, "{\"broken\":"));

    const fallback = try rawJsonFieldFallback(std.testing.allocator, "metadata_json", " {\"ok\":true} ");
    defer std.testing.allocator.free(fallback);
    try std.testing.expectEqualStrings("{\"ok\":true}", fallback);

    const compatibility = try rawJsonFieldValue(std.testing.allocator, "payload", obj.get("blank").?, "{\"broken\":");
    defer std.testing.allocator.free(compatibility);
    try std.testing.expectEqualStrings("{\"broken\":", compatibility);
}

test "json integer fields reject unsafe floats instead of trapping" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"exact\":42.0,\"fractional\":42.5,\"huge\":1e100,\"imprecise\":9007199254740992.0,\"integer\":7}",
        .{},
    );
    defer parsed.deinit();

    try std.testing.expectEqual(@as(?i64, 42), intField(parsed.value.object, "exact"));
    try std.testing.expectEqual(@as(?i64, 7), intField(parsed.value.object, "integer"));
    try std.testing.expect(intField(parsed.value.object, "fractional") == null);
    try std.testing.expect(intField(parsed.value.object, "huge") == null);
    try std.testing.expect(intField(parsed.value.object, "imprecise") == null);
    try std.testing.expectEqual(@as(?u64, 42), safeFloatToU64(parsed.value.object.get("exact").?.float));
    try std.testing.expect(safeFloatToU64(parsed.value.object.get("fractional").?.float) == null);
    try std.testing.expect(safeFloatToU64(parsed.value.object.get("huge").?.float) == null);
    try std.testing.expect(safeFloatToU64(parsed.value.object.get("imprecise").?.float) == null);
    try std.testing.expect(safeFloatToU64(-1.0) == null);
}
