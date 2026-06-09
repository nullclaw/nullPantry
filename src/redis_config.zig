const std = @import("std");

const redis_scheme = "redis://";
const default_host = "127.0.0.1";
const default_port: u16 = 6379;

pub const Config = struct {
    host: []const u8 = default_host,
    port: u16 = default_port,
    password: ?[]const u8 = null,
    db_index: u8 = 0,
    key_prefix: []const u8 = "nullpantry",
    ttl_seconds: ?u32 = null,
};

pub fn parseUrl(allocator: std.mem.Allocator, raw_url: []const u8) !Config {
    if (raw_url.len == 0) return Config{};
    const url = std.mem.trim(u8, raw_url, " \t\r\n");
    if (url.len != raw_url.len or hasAsciiControlOrSpace(url)) return error.InvalidRedisUrl;
    if (!std.mem.startsWith(u8, url, redis_scheme)) return error.InvalidRedisUrl;
    const rest = url[redis_scheme.len..];
    if (std.mem.indexOfAny(u8, rest, "?#") != null) return error.InvalidRedisUrl;

    var cfg = Config{};
    var host_allocated = false;
    var password_allocated = false;
    errdefer {
        if (host_allocated) allocator.free(cfg.host);
        if (password_allocated) if (cfg.password) |password| allocator.free(password);
    }

    const parts = try parseAuthorityAndDb(rest);
    const authority = parts.authority;
    const db_part = parts.db_part;
    if (db_part.len > 0) cfg.db_index = std.fmt.parseInt(u8, db_part, 10) catch return error.InvalidRedisUrl;

    var host_port = authority;
    if (std.mem.lastIndexOfScalar(u8, authority, '@')) |idx| {
        const auth = try redisPasswordFromUserInfo(authority[0..idx]);
        host_port = authority[idx + 1 ..];
        if (host_port.len == 0) return error.InvalidRedisUrl;
        cfg.password = try allocator.dupe(u8, auth);
        password_allocated = true;
    }

    const endpoint = try parseRedisHostPort(host_port);
    cfg.host = try allocator.dupe(u8, endpoint.host);
    host_allocated = true;
    cfg.port = endpoint.port;
    return cfg;
}

const RedisAuthorityAndDb = struct {
    authority: []const u8,
    db_part: []const u8,
};

const RedisEndpoint = struct {
    host: []const u8,
    port: u16,
};

fn parseAuthorityAndDb(rest: []const u8) !RedisAuthorityAndDb {
    const slash_index = std.mem.indexOfScalar(u8, rest, '/');
    const authority = if (slash_index) |idx| rest[0..idx] else rest;
    const db_part = if (slash_index) |idx| rest[idx + 1 ..] else "";
    if (authority.len == 0) return error.InvalidRedisUrl;
    if (std.mem.indexOfScalar(u8, db_part, '/') != null) return error.InvalidRedisUrl;
    return .{ .authority = authority, .db_part = db_part };
}

fn redisPasswordFromUserInfo(raw: []const u8) ![]const u8 {
    if (raw.len == 0 or std.mem.indexOfScalar(u8, raw, '@') != null) return error.InvalidRedisUrl;
    const password = if (raw[0] == ':')
        raw[1..]
    else if (std.mem.indexOfScalar(u8, raw, ':')) |colon|
        raw[colon + 1 ..]
    else
        return error.InvalidRedisUrl;
    if (password.len == 0) return error.InvalidRedisUrl;
    return password;
}

fn parseRedisHostPort(host_port: []const u8) !RedisEndpoint {
    if (host_port.len == 0) return error.InvalidRedisUrl;
    if (host_port[0] == '[') {
        const close = std.mem.indexOfScalar(u8, host_port, ']') orelse return error.InvalidRedisUrl;
        if (close == 1) return error.InvalidRedisUrl;
        const suffix = host_port[close + 1 ..];
        return .{
            .host = host_port[1..close],
            .port = try parseRedisPortSuffix(suffix),
        };
    }
    if (std.mem.indexOfAny(u8, host_port, "[]") != null) return error.InvalidRedisUrl;
    const first_colon = std.mem.indexOfScalar(u8, host_port, ':');
    if (first_colon) |colon| {
        if (std.mem.indexOfScalar(u8, host_port[colon + 1 ..], ':') != null) return error.InvalidRedisUrl;
        if (colon == 0) return error.InvalidRedisUrl;
        return .{
            .host = host_port[0..colon],
            .port = try parseRedisPortSuffix(host_port[colon..]),
        };
    }
    return .{ .host = host_port, .port = default_port };
}

fn parseRedisPortSuffix(suffix: []const u8) !u16 {
    if (suffix.len == 0) return default_port;
    if (suffix[0] != ':' or suffix.len == 1) return error.InvalidRedisUrl;
    return std.fmt.parseInt(u16, suffix[1..], 10) catch return error.InvalidRedisUrl;
}

fn hasAsciiControlOrSpace(value: []const u8) bool {
    for (value) |ch| {
        if (ch <= ' ' or ch == 0x7f) return true;
    }
    return false;
}

test "redis config parses url without importing redis client" {
    const cfg = try parseUrl(std.testing.allocator, "redis://:secret@127.0.0.1:6380/2");
    defer std.testing.allocator.free(cfg.host);
    defer if (cfg.password) |password| std.testing.allocator.free(password);

    try std.testing.expectEqualStrings("127.0.0.1", cfg.host);
    try std.testing.expectEqual(@as(u16, 6380), cfg.port);
    try std.testing.expectEqual(@as(u8, 2), cfg.db_index);
    try std.testing.expectEqualStrings("secret", cfg.password.?);
}

test "redis config parses explicit password and bracketed IPv6 endpoints" {
    const named = try parseUrl(std.testing.allocator, "redis://default:secret@redis.internal/15");
    defer std.testing.allocator.free(named.host);
    defer if (named.password) |password| std.testing.allocator.free(password);
    try std.testing.expectEqualStrings("redis.internal", named.host);
    try std.testing.expectEqual(@as(u16, 6379), named.port);
    try std.testing.expectEqual(@as(u8, 15), named.db_index);
    try std.testing.expectEqualStrings("secret", named.password.?);

    const ipv6 = try parseUrl(std.testing.allocator, "redis://[::1]:6381");
    defer std.testing.allocator.free(ipv6.host);
    try std.testing.expectEqualStrings("::1", ipv6.host);
    try std.testing.expectEqual(@as(u16, 6381), ipv6.port);
    try std.testing.expect(ipv6.password == null);
}

test "redis config rejects ambiguous or unsafe URLs" {
    try std.testing.expectError(error.InvalidRedisUrl, parseUrl(std.testing.allocator, " redis://127.0.0.1"));
    try std.testing.expectError(error.InvalidRedisUrl, parseUrl(std.testing.allocator, "redis://127.0.0.1\r\n"));
    try std.testing.expectError(error.InvalidRedisUrl, parseUrl(std.testing.allocator, "redis://127.0.0.1?db=1"));
    try std.testing.expectError(error.InvalidRedisUrl, parseUrl(std.testing.allocator, "redis://127.0.0.1#fragment"));
    try std.testing.expectError(error.InvalidRedisUrl, parseUrl(std.testing.allocator, "redis://secret@127.0.0.1"));
    try std.testing.expectError(error.InvalidRedisUrl, parseUrl(std.testing.allocator, "redis://:secret@"));
    try std.testing.expectError(error.InvalidRedisUrl, parseUrl(std.testing.allocator, "redis://:secret@127.0.0.1:"));
    try std.testing.expectError(error.InvalidRedisUrl, parseUrl(std.testing.allocator, "redis://:secret@127.0.0.1:65536"));
    try std.testing.expectError(error.InvalidRedisUrl, parseUrl(std.testing.allocator, "redis://[::1]evil:6379"));
    try std.testing.expectError(error.InvalidRedisUrl, parseUrl(std.testing.allocator, "redis://::1:6379"));
    try std.testing.expectError(error.InvalidRedisUrl, parseUrl(std.testing.allocator, "redis://127.0.0.1/1/2"));
}
