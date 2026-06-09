const std = @import("std");
const compat = @import("compat.zig");
const net_security = @import("net_security.zig");

const read_chunk_size: usize = 4096;

pub const Limits = struct {
    max_request_bytes: usize,
    max_header_bytes: usize,
    max_header_lines: usize,
};

pub fn read(allocator: std.mem.Allocator, stream: *std.Io.net.Stream, limits: Limits) !?[]u8 {
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
        if (net_security.exceedsByteLimit(buffer.items.len, line.len, limits.max_request_bytes)) return error.RequestTooLarge;
        if (net_security.exceedsByteLimit(buffer.items.len, line.len, limits.max_header_bytes)) return error.RequestHeaderTooLarge;
        header_lines += 1;
        if (header_lines > limits.max_header_lines) return error.TooManyHeaders;
        try buffer.appendSlice(allocator, line);
        if (std.mem.endsWith(u8, buffer.items, "\r\n\r\n")) break;
    }

    const content_length = try parseContentLength(buffer.items);
    if (net_security.exceedsByteLimit(buffer.items.len, content_length, limits.max_request_bytes)) return error.RequestTooLarge;
    if (content_length > 0) {
        const body_start = buffer.items.len;
        try buffer.resize(allocator, body_start + content_length);
        try reader.interface.readSliceAll(buffer.items[body_start..]);
    }
    return try buffer.toOwnedSlice(allocator);
}

pub fn parseContentLength(header_text: []const u8) !usize {
    var content_length: usize = 0;
    var saw_content_length = false;
    var lines = std.mem.splitSequence(u8, header_text, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(key, "Content-Length")) {
            if (saw_content_length) return error.DuplicateContentLength;
            content_length = try parseDecimalContentLength(value);
            saw_content_length = true;
        } else if (std.ascii.eqlIgnoreCase(key, "Transfer-Encoding")) {
            if (!std.ascii.eqlIgnoreCase(value, "identity")) return error.UnsupportedTransferEncoding;
        }
    }
    return content_length;
}

pub fn logTargetPath(target: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, target, "?#") orelse target.len;
    return target[0..end];
}

pub fn logTargetSuffix(target: []const u8) []const u8 {
    const query = std.mem.indexOfScalar(u8, target, '?');
    const fragment = std.mem.indexOfScalar(u8, target, '#');
    if (query != null and (fragment == null or query.? < fragment.?)) return "?<redacted>";
    if (fragment != null) return "#<redacted>";
    return "";
}

fn parseDecimalContentLength(value: []const u8) !usize {
    if (value.len == 0) return error.InvalidContentLength;
    for (value) |ch| {
        if (ch < '0' or ch > '9') return error.InvalidContentLength;
    }
    return std.fmt.parseInt(usize, value, 10) catch return error.InvalidContentLength;
}

test "http header parser rejects ambiguous body framing" {
    try std.testing.expectEqual(@as(usize, 5), try parseContentLength("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\n"));
    try std.testing.expectError(error.InvalidContentLength, parseContentLength("POST / HTTP/1.1\r\nContent-Length: nope\r\n\r\n"));
    try std.testing.expectError(error.InvalidContentLength, parseContentLength("POST / HTTP/1.1\r\nContent-Length: +5\r\n\r\n"));
    try std.testing.expectError(error.DuplicateContentLength, parseContentLength("POST / HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\n"));
    try std.testing.expectError(error.UnsupportedTransferEncoding, parseContentLength("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"));
}

test "http access log target redacts query strings and fragments" {
    try std.testing.expectEqualStrings("/v1/search", logTargetPath("/v1/search?q=token"));
    try std.testing.expectEqualStrings("?<redacted>", logTargetSuffix("/v1/search?q=token"));
    try std.testing.expectEqualStrings("/v1/search", logTargetPath("/v1/search#secret"));
    try std.testing.expectEqualStrings("#<redacted>", logTargetSuffix("/v1/search#secret"));
    try std.testing.expectEqualStrings("/v1/search", logTargetPath("/v1/search"));
    try std.testing.expectEqualStrings("", logTargetSuffix("/v1/search"));
}
