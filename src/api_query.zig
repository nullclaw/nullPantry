const std = @import("std");
const json = @import("json_util.zig");

pub fn feedCursorFromQuery(query: []const u8) i64 {
    if (json.queryParam(query, "since_id")) |raw| return std.fmt.parseInt(i64, raw, 10) catch 0;
    if (json.queryParam(query, "after")) |raw| return std.fmt.parseInt(i64, raw, 10) catch 0;
    if (json.queryParam(query, "after_id")) |raw| return std.fmt.parseInt(i64, raw, 10) catch 0;
    if (json.queryParam(query, "after_sequence")) |raw| return std.fmt.parseInt(i64, raw, 10) catch 0;
    return 0;
}

pub fn parseLimit(value: ?[]const u8, default_value: usize) usize {
    const raw = value orelse return default_value;
    const parsed = std.fmt.parseInt(usize, raw, 10) catch return default_value;
    return @min(parsed, 500);
}

pub fn queryBool(query: []const u8, name: []const u8, default_value: bool) bool {
    const raw = json.queryParam(query, name) orelse return default_value;
    return std.ascii.eqlIgnoreCase(raw, "true") or
        std.mem.eql(u8, raw, "1") or
        std.ascii.eqlIgnoreCase(raw, "yes") or
        std.ascii.eqlIgnoreCase(raw, "on");
}

pub fn queryInt(query: []const u8, name: []const u8) ?i64 {
    const raw = json.queryParam(query, name) orelse return null;
    return std.fmt.parseInt(i64, raw, 10) catch null;
}

pub fn optionalSegmentEquals(value: ?[]const u8, expected: []const u8) bool {
    return if (value) |v| std.mem.eql(u8, v, expected) else false;
}

pub fn decodeSegment(allocator: std.mem.Allocator, value: ?[]const u8) !?[]u8 {
    const src = value orelse return null;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < src.len) : (i += 1) {
        if (src[i] == '%' and i + 2 < src.len) {
            const byte = std.fmt.parseInt(u8, src[i + 1 .. i + 3], 16) catch {
                try out.append(allocator, src[i]);
                continue;
            };
            try out.append(allocator, byte);
            i += 2;
        } else {
            try out.append(allocator, src[i]);
        }
    }
    return try out.toOwnedSlice(allocator);
}

test "api query bool accepts common truthy spellings" {
    try std.testing.expect(queryBool("enabled=true", "enabled", false));
    try std.testing.expect(queryBool("enabled=1", "enabled", false));
    try std.testing.expect(queryBool("enabled=yes", "enabled", false));
    try std.testing.expect(!queryBool("enabled=false", "enabled", false));
}

test "api path segment decoding preserves plus as path data" {
    const decoded = (try decodeSegment(std.testing.allocator, "key+with%20space")).?;
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("key+with space", decoded);
}
