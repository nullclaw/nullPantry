const std = @import("std");

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
    try std.json.Stringify.value(value, .{}, &w.writer);
    buf.* = w.toArrayList();
}

pub fn appendNullableString(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: ?[]const u8) !void {
    if (value) |v| {
        try appendString(buf, allocator, v);
    } else {
        try buf.appendSlice(allocator, "null");
    }
}

pub fn appendRawJsonOr(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, raw: ?[]const u8, fallback: []const u8) !void {
    if (raw) |text| {
        if (std.json.validate(allocator, text) catch false) {
            try buf.appendSlice(allocator, text);
            return;
        }
    }
    try buf.appendSlice(allocator, fallback);
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
        .float => |f| @intFromFloat(f),
        else => null,
    };
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
        410 => "410 Gone",
        409 => "409 Conflict",
        500 => "500 Internal Server Error",
        else => "400 Bad Request",
    };
    const body = std.fmt.allocPrint(
        allocator,
        "{{\"error\":\"{s}\",\"message\":",
        .{code_text},
    ) catch "{\"error\":\"internal\"}";
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(allocator, body) catch return .{ .status = status, .body = "{\"error\":\"internal\"}" };
    allocator.free(body);
    appendString(&out, allocator, message) catch return .{ .status = status, .body = "{\"error\":\"internal\"}" };
    out.append(allocator, '}') catch return .{ .status = status, .body = "{\"error\":\"internal\"}" };
    return .{ .status = status, .body = out.toOwnedSlice(allocator) catch "{\"error\":\"internal\"}" };
}
