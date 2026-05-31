const std = @import("std");

pub fn validateHttpBaseUrl(url: []const u8, allow_insecure_http: bool) !void {
    const trimmed = std.mem.trim(u8, url, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len != url.len) return error.InvalidRuntimeUrl;
    _ = std.Uri.parse(trimmed) catch return error.InvalidRuntimeUrl;

    if (startsWithIgnoreCase(trimmed, "https://")) return;
    if (!startsWithIgnoreCase(trimmed, "http://")) return error.InvalidRuntimeUrl;
    if (allow_insecure_http) return;

    const host = extractHost(trimmed) orelse return error.InvalidRuntimeUrl;
    if (!isLocalHost(host)) return error.InsecureRuntimeUrl;
}

pub fn extractHost(url: []const u8) ?[]const u8 {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return null;
    var authority = url[scheme_end + 3 ..];
    if (authority.len == 0) return null;

    var end: usize = 0;
    while (end < authority.len and authority[end] != '/' and authority[end] != '?' and authority[end] != '#') : (end += 1) {}
    authority = authority[0..end];
    if (authority.len == 0) return null;

    if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| {
        authority = authority[at + 1 ..];
        if (authority.len == 0) return null;
    }

    if (authority[0] == '[') {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return null;
        if (close == 1) return null;
        return authority[1..close];
    }

    const port_start = std.mem.indexOfScalar(u8, authority, ':') orelse authority.len;
    if (port_start == 0) return null;
    return authority[0..port_start];
}

pub fn isLocalHost(host: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(host, "localhost") or std.ascii.eqlIgnoreCase(host, "localhost.")) return true;
    if (std.mem.eql(u8, host, "::1")) return true;
    if (std.mem.eql(u8, host, "0:0:0:0:0:0:0:1")) return true;
    if (std.mem.eql(u8, host, "0.0.0.0")) return true;
    if (std.mem.eql(u8, host, "127.0.0.1")) return true;
    return std.mem.startsWith(u8, host, "127.");
}

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    return value.len >= prefix.len and std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

test "validates https and local http runtime urls" {
    try validateHttpBaseUrl("https://pantry.example/v1", false);
    try validateHttpBaseUrl("http://localhost:8765", false);
    try validateHttpBaseUrl("http://127.0.0.1:8765", false);
    try validateHttpBaseUrl("http://[::1]:8765", false);
}

test "rejects non-local plain http unless explicitly allowed" {
    try std.testing.expectError(error.InsecureRuntimeUrl, validateHttpBaseUrl("http://pantry.internal:8765", false));
    try validateHttpBaseUrl("http://pantry.internal:8765", true);
}

test "rejects malformed runtime urls" {
    try std.testing.expectError(error.InvalidRuntimeUrl, validateHttpBaseUrl("://bad", false));
    try std.testing.expectError(error.InvalidRuntimeUrl, validateHttpBaseUrl("ftp://pantry.example", false));
    try std.testing.expectError(error.InvalidRuntimeUrl, validateHttpBaseUrl(" https://pantry.example", false));
}

test "extracts authority hosts" {
    try std.testing.expectEqualStrings("pantry.example", extractHost("https://token@pantry.example:8765/v1").?);
    try std.testing.expectEqualStrings("::1", extractHost("http://[::1]:8765/v1").?);
}
