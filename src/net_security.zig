const std = @import("std");
const builtin = @import("builtin");

pub fn validateHttpBaseUrl(url: []const u8, allow_insecure_http: bool) !void {
    const trimmed = std.mem.trim(u8, url, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len != url.len) return error.InvalidRuntimeUrl;
    if (hasAsciiControlOrSpace(trimmed)) return error.InvalidRuntimeUrl;
    if (std.mem.indexOfScalar(u8, trimmed, '?') != null or
        std.mem.indexOfScalar(u8, trimmed, '#') != null)
    {
        return error.InvalidRuntimeUrl;
    }
    _ = std.Uri.parse(trimmed) catch return error.InvalidRuntimeUrl;
    const authority = extractAuthority(trimmed) orelse return error.InvalidRuntimeUrl;
    const host = hostFromAuthority(authority) orelse return error.InvalidRuntimeUrl;

    if (startsWithIgnoreCase(trimmed, "https://")) return;
    if (!startsWithIgnoreCase(trimmed, "http://")) return error.InvalidRuntimeUrl;
    if (allow_insecure_http) return;

    if (!isLocalHost(host)) return error.InsecureRuntimeUrl;
}

pub fn extractHost(url: []const u8) ?[]const u8 {
    const authority = extractAuthority(url) orelse return null;
    return hostFromAuthority(authority);
}

pub fn joinHttpBaseUrl(allocator: std.mem.Allocator, base_url: []const u8, suffix: []const u8, allow_insecure_http: bool) ![]u8 {
    try validateHttpBaseUrl(base_url, allow_insecure_http);
    return joinValidatedBaseUrl(allocator, base_url, suffix);
}

fn joinValidatedBaseUrl(allocator: std.mem.Allocator, base_url: []const u8, suffix: []const u8) ![]u8 {
    var end = base_url.len;
    while (end > 0 and base_url[end - 1] == '/') : (end -= 1) {}
    if (suffix.len > 0 and suffix[0] == '?') return std.fmt.allocPrint(allocator, "{s}/{s}", .{ base_url[0..end], suffix });
    if (suffix.len > 0 and suffix[0] == '/') return std.fmt.allocPrint(allocator, "{s}{s}", .{ base_url[0..end], suffix });
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ base_url[0..end], suffix });
}

fn extractAuthority(url: []const u8) ?[]const u8 {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return null;
    var authority = url[scheme_end + 3 ..];
    if (authority.len == 0) return null;

    var end: usize = 0;
    while (end < authority.len and authority[end] != '/' and authority[end] != '?' and authority[end] != '#') : (end += 1) {}
    authority = authority[0..end];
    if (authority.len == 0) return null;

    return authority;
}

fn hostFromAuthority(authority: []const u8) ?[]const u8 {
    if (authority.len == 0) return null;
    if (std.mem.indexOfScalar(u8, authority, '@') != null) return null;

    if (authority[0] == '[') {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return null;
        if (close == 1) return null;
        if (!validAuthorityPortSuffix(authority[close + 1 ..])) return null;
        return authority[1..close];
    }

    const port_start = std.mem.indexOfScalar(u8, authority, ':') orelse authority.len;
    if (port_start == 0) return null;
    if (!validAuthorityPortSuffix(authority[port_start..])) return null;
    return authority[0..port_start];
}

pub fn isLocalHost(host: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(host, "localhost") or std.ascii.eqlIgnoreCase(host, "localhost.")) return true;
    if (std.mem.eql(u8, host, "::1")) return true;
    if (std.mem.eql(u8, host, "0:0:0:0:0:0:0:1")) return true;
    const ipv4 = parseDottedIpv4(host) orelse return false;
    return ipv4[0] == 127;
}

pub fn percentEncodePathSegment(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    const digits = "0123456789ABCDEF";
    for (raw) |ch| {
        if (isUnreservedPathByte(ch)) {
            try out.append(allocator, ch);
            continue;
        }

        try out.append(allocator, '%');
        try out.append(allocator, digits[ch >> 4]);
        try out.append(allocator, digits[ch & 0x0f]);
    }

    return out.toOwnedSlice(allocator);
}

pub fn boundedResponseReadLimit(max_response_bytes: usize) usize {
    if (max_response_bytes == std.math.maxInt(usize)) return max_response_bytes;
    return max_response_bytes + 1;
}

pub fn exceedsByteLimit(current: usize, addition: usize, max_bytes: usize) bool {
    if (current > max_bytes) return true;
    return addition > max_bytes - current;
}

pub fn readBoundedResponse(allocator: std.mem.Allocator, reader: *std.Io.Reader, max_response_bytes: usize) ![]u8 {
    const read_limit = boundedResponseReadLimit(max_response_bytes);
    const body = try reader.allocRemaining(allocator, .limited(read_limit));
    if (body.len > max_response_bytes) {
        allocator.free(body);
        return error.StreamTooLong;
    }
    return body;
}

pub fn validateHttpHeaderName(name: []const u8) !void {
    if (name.len == 0) return error.InvalidHttpHeaderName;
    for (name) |ch| {
        if (!isHttpHeaderTokenByte(ch)) return error.InvalidHttpHeaderName;
    }
}

pub fn validateHttpHeaderValue(value: []const u8) !void {
    for (value) |ch| {
        if (ch < ' ' or ch == 0x7f) return error.InvalidHttpHeaderValue;
    }
}

pub fn applyHttpSocketTimeout(connection: ?*std.http.Client.Connection, timeout_secs: u32) void {
    if (timeout_secs == 0) return;
    switch (builtin.target.os.tag) {
        .windows => {},
        else => {
            if (connection) |conn| {
                const timeout = std.posix.timeval{ .sec = @intCast(@max(timeout_secs, 1)), .usec = 0 };
                const handle = conn.stream_reader.stream.socket.handle;
                std.posix.setsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {};
                std.posix.setsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&timeout)) catch {};
            }
        },
    }
}

pub fn flushHttpConnection(connection: ?*std.http.Client.Connection) !void {
    const conn = connection orelse return error.HttpConnectionUnavailable;
    try conn.flush();
}

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    return value.len >= prefix.len and std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

fn hasAsciiControlOrSpace(value: []const u8) bool {
    for (value) |ch| {
        if (ch <= ' ' or ch == 0x7f) return true;
    }
    return false;
}

fn isUnreservedPathByte(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or
        (ch >= 'A' and ch <= 'Z') or
        (ch >= '0' and ch <= '9') or
        ch == '-' or ch == '_' or ch == '.' or ch == '~';
}

fn isHttpHeaderTokenByte(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or
        (ch >= 'A' and ch <= 'Z') or
        (ch >= '0' and ch <= '9') or
        ch == '!' or ch == '#' or ch == '$' or ch == '%' or
        ch == '&' or ch == '\'' or ch == '*' or ch == '+' or
        ch == '-' or ch == '.' or ch == '^' or ch == '_' or
        ch == '`' or ch == '|' or ch == '~';
}

fn validAuthorityPortSuffix(suffix: []const u8) bool {
    if (suffix.len == 0) return true;
    if (suffix[0] != ':') return false;
    if (suffix.len == 1) return false;
    for (suffix[1..]) |ch| {
        if (ch < '0' or ch > '9') return false;
    }
    const port = std.fmt.parseInt(u32, suffix[1..], 10) catch return false;
    return port <= 65535;
}

fn parseDottedIpv4(host: []const u8) ?[4]u8 {
    var octets: [4]u8 = undefined;
    var octet_index: usize = 0;
    var parts = std.mem.splitScalar(u8, host, '.');
    while (parts.next()) |part| {
        if (octet_index >= octets.len) return null;
        if (part.len == 0) return null;
        if (part.len > 1 and part[0] == '0') return null;
        var value: u16 = 0;
        for (part) |ch| {
            if (ch < '0' or ch > '9') return null;
            value = value * 10 + (ch - '0');
            if (value > 255) return null;
        }
        octets[octet_index] = @intCast(value);
        octet_index += 1;
    }
    if (octet_index != octets.len) return null;
    return octets;
}

test "validates https and local http runtime urls" {
    try validateHttpBaseUrl("https://pantry.example/v1", false);
    try validateHttpBaseUrl("http://localhost:8765", false);
    try validateHttpBaseUrl("http://127.0.0.1:8765", false);
    try validateHttpBaseUrl("http://127.42.0.9:8765", false);
    try validateHttpBaseUrl("http://[::1]:8765", false);
}

test "rejects non-local plain http unless explicitly allowed" {
    try std.testing.expectError(error.InsecureRuntimeUrl, validateHttpBaseUrl("http://pantry.internal:8765", false));
    try std.testing.expectError(error.InsecureRuntimeUrl, validateHttpBaseUrl("http://127.evil.example:8765", false));
    try std.testing.expectError(error.InsecureRuntimeUrl, validateHttpBaseUrl("http://127.0.0.1.example:8765", false));
    try std.testing.expectError(error.InsecureRuntimeUrl, validateHttpBaseUrl("http://0.0.0.0:8765", false));
    try validateHttpBaseUrl("http://pantry.internal:8765", true);
}

test "rejects malformed runtime urls" {
    try std.testing.expectError(error.InvalidRuntimeUrl, validateHttpBaseUrl("://bad", false));
    try std.testing.expectError(error.InvalidRuntimeUrl, validateHttpBaseUrl("ftp://pantry.example", false));
    try std.testing.expectError(error.InvalidRuntimeUrl, validateHttpBaseUrl(" https://pantry.example", false));
    try std.testing.expectError(error.InvalidRuntimeUrl, validateHttpBaseUrl("https://pantry.example/path with space", false));
    try std.testing.expectError(error.InvalidRuntimeUrl, validateHttpBaseUrl("https://token@pantry.example", false));
    try std.testing.expectError(error.InvalidRuntimeUrl, validateHttpBaseUrl("https://pantry.example?token=x", false));
    try std.testing.expectError(error.InvalidRuntimeUrl, validateHttpBaseUrl("https://pantry.example/path#fragment", false));
    try std.testing.expectError(error.InvalidRuntimeUrl, validateHttpBaseUrl("http://localhost:bad", false));
    try std.testing.expectError(error.InvalidRuntimeUrl, validateHttpBaseUrl("http://localhost:", false));
    try std.testing.expectError(error.InvalidRuntimeUrl, validateHttpBaseUrl("http://localhost:65536", false));
    try std.testing.expectError(error.InvalidRuntimeUrl, validateHttpBaseUrl("http://[::1]evil.example", false));
    try std.testing.expectError(error.InvalidRuntimeUrl, validateHttpBaseUrl("https://[::1]evil.example", false));
}

test "extracts authority hosts" {
    try std.testing.expectEqualStrings("pantry.example", extractHost("https://pantry.example:8765/v1").?);
    try std.testing.expectEqualStrings("::1", extractHost("http://[::1]:8765/v1").?);
    try std.testing.expect(extractHost("https://token@pantry.example:8765/v1") == null);
}

test "local host only accepts loopback literals and localhost names" {
    try std.testing.expect(isLocalHost("localhost"));
    try std.testing.expect(isLocalHost("localhost."));
    try std.testing.expect(isLocalHost("127.0.0.1"));
    try std.testing.expect(isLocalHost("127.255.255.255"));
    try std.testing.expect(isLocalHost("::1"));
    try std.testing.expect(!isLocalHost("127.evil.example"));
    try std.testing.expect(!isLocalHost("127.0.0.1.example"));
    try std.testing.expect(!isLocalHost("127.0.0"));
    try std.testing.expect(!isLocalHost("127.0.0.01"));
    try std.testing.expect(!isLocalHost("127.0.0.256"));
    try std.testing.expect(!isLocalHost("0.0.0.0"));
}

test "percent-encodes URL path segments" {
    const encoded = try percentEncodePathSegment(std.testing.allocator, "team/vector 1?#");
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("team%2Fvector%201%3F%23", encoded);

    const unreserved = try percentEncodePathSegment(std.testing.allocator, "azAZ09-_.~");
    defer std.testing.allocator.free(unreserved);
    try std.testing.expectEqualStrings("azAZ09-_.~", unreserved);
}

test "computes overflow-safe bounded response read limits" {
    try std.testing.expectEqual(@as(usize, 1), boundedResponseReadLimit(0));
    try std.testing.expectEqual(@as(usize, 1025), boundedResponseReadLimit(1024));
    try std.testing.expectEqual(std.math.maxInt(usize), boundedResponseReadLimit(std.math.maxInt(usize)));
}

test "checks byte limits without overflowing" {
    try std.testing.expect(!exceedsByteLimit(0, 0, 0));
    try std.testing.expect(!exceedsByteLimit(4, 6, 10));
    try std.testing.expect(exceedsByteLimit(4, 7, 10));
    try std.testing.expect(exceedsByteLimit(11, 0, 10));
    try std.testing.expect(exceedsByteLimit(std.math.maxInt(usize), 1, std.math.maxInt(usize)));
}

test "reads bounded HTTP responses without overflow-prone limits" {
    var ok_reader: std.Io.Reader = .fixed("abcdef");
    const ok = try readBoundedResponse(std.testing.allocator, &ok_reader, 6);
    defer std.testing.allocator.free(ok);
    try std.testing.expectEqualStrings("abcdef", ok);

    var too_large_reader: std.Io.Reader = .fixed("abcdefg");
    try std.testing.expectError(error.StreamTooLong, readBoundedResponse(std.testing.allocator, &too_large_reader, 6));

    var max_reader: std.Io.Reader = .fixed("ok");
    const max = try readBoundedResponse(std.testing.allocator, &max_reader, std.math.maxInt(usize));
    defer std.testing.allocator.free(max);
    try std.testing.expectEqualStrings("ok", max);
}

test "validates HTTP header names as token bytes" {
    try validateHttpHeaderName("Authorization");
    try validateHttpHeaderName("x-api-key");
    try validateHttpHeaderName("X.Trace_ID~1");

    try std.testing.expectError(error.InvalidHttpHeaderName, validateHttpHeaderName(""));
    try std.testing.expectError(error.InvalidHttpHeaderName, validateHttpHeaderName("Bad Header"));
    try std.testing.expectError(error.InvalidHttpHeaderName, validateHttpHeaderName("X:Bad"));
    try std.testing.expectError(error.InvalidHttpHeaderName, validateHttpHeaderName("X\r\nInjected"));
    try std.testing.expectError(error.InvalidHttpHeaderName, validateHttpHeaderName("X-API-\x7f"));
}

test "validates outbound HTTP header values" {
    try validateHttpHeaderValue("");
    try validateHttpHeaderValue("Bearer token.with spaces");
    try validateHttpHeaderValue("Basic abc123+/=");

    try std.testing.expectError(error.InvalidHttpHeaderValue, validateHttpHeaderValue("Bearer token\r\nInjected: yes"));
    try std.testing.expectError(error.InvalidHttpHeaderValue, validateHttpHeaderValue("token\twith-tab"));
    try std.testing.expectError(error.InvalidHttpHeaderValue, validateHttpHeaderValue("token\x7f"));
}

test "HTTP socket timeout helper accepts disabled and missing connections" {
    applyHttpSocketTimeout(null, 0);
    applyHttpSocketTimeout(null, 30);
}

test "HTTP connection flush helper fails closed without a connection" {
    try std.testing.expectError(error.HttpConnectionUnavailable, flushHttpConnection(null));
}

test "joins validated HTTP base URLs consistently" {
    const absolute_path = try joinHttpBaseUrl(std.testing.allocator, "https://pantry.example/v1///", "/memories", false);
    defer std.testing.allocator.free(absolute_path);
    try std.testing.expectEqualStrings("https://pantry.example/v1/memories", absolute_path);

    const relative_path = try joinHttpBaseUrl(std.testing.allocator, "https://pantry.example/v1", "memories", false);
    defer std.testing.allocator.free(relative_path);
    try std.testing.expectEqualStrings("https://pantry.example/v1/memories", relative_path);

    const query_suffix = try joinHttpBaseUrl(std.testing.allocator, "https://pantry.example/v1", "?query=SELECT%201", false);
    defer std.testing.allocator.free(query_suffix);
    try std.testing.expectEqualStrings("https://pantry.example/v1/?query=SELECT%201", query_suffix);

    try std.testing.expectError(error.InvalidRuntimeUrl, joinHttpBaseUrl(std.testing.allocator, "https://token@pantry.example", "/v1", false));
    try std.testing.expectError(error.InsecureRuntimeUrl, joinHttpBaseUrl(std.testing.allocator, "http://pantry.internal", "/v1", false));
}
