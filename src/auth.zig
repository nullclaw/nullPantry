const std = @import("std");
const domain = @import("domain.zig");
const json = @import("json_util.zig");

pub const PrincipalInput = struct {
    allocator: std.mem.Allocator,
    required_token: ?[]const u8 = null,
    token_principals_json: ?[]const u8 = null,
    trust_actor_headers: bool = false,
    actor_id: []const u8,
    actor_scopes_json: []const u8,
    actor_capabilities_json: []const u8,
};

pub const AppliedPrincipal = struct {
    actor_id: []const u8,
    actor_scopes_json: []const u8,
    actor_capabilities_json: []const u8,
};

pub fn authorized(allocator: std.mem.Allocator, required_token: ?[]const u8, token_principals_json: ?[]const u8, raw_request: []const u8) bool {
    if (required_token == null and token_principals_json == null) return true;
    if (token_principals_json == null) {
        if (required_token) |required| {
            if (std.mem.trim(u8, required, " \t\r\n").len == 0) return false;
        }
    }
    const token = (bearerTokenStrict(raw_request) catch return false) orelse return false;
    if (token_principals_json) |registry| {
        return principalRegistryHasToken(allocator, registry, token);
    }
    const required = required_token orelse return false;
    if (std.mem.trim(u8, required, " \t\r\n").len == 0) return false;
    return tokenEql(token, required);
}

pub fn validatePrincipalRegistry(allocator: std.mem.Allocator, registry_json: []const u8) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, registry_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidPrincipalRegistry,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidPrincipalRegistry;
    var iterator = parsed.value.object.iterator();
    while (iterator.next()) |entry| {
        if (std.mem.trim(u8, entry.key_ptr.*, " \t\r\n").len == 0) return error.InvalidPrincipalRegistry;
        try validatePrincipalValue(entry.value_ptr.*);
    }
}

pub fn applyRequestPrincipal(input: PrincipalInput, raw_request: []const u8) !AppliedPrincipal {
    var applied = AppliedPrincipal{
        .actor_id = input.actor_id,
        .actor_scopes_json = input.actor_scopes_json,
        .actor_capabilities_json = input.actor_capabilities_json,
    };
    const principal_locked = try applyBearerPrincipal(input.allocator, input.token_principals_json, raw_request, &applied);
    if (!principal_locked and actorHeadersAllowed(input)) {
        if (try extractHeaderStrict(raw_request, "X-NullPantry-Actor-Id")) |actor_id| {
            const trimmed_actor_id = std.mem.trim(u8, actor_id, " \t\r\n");
            if (trimmed_actor_id.len == 0) return error.InvalidActorHeader;
            applied.actor_id = trimmed_actor_id;
        }
    }

    if (try extractHeaderStrict(raw_request, "X-NullPantry-Actor-Scopes")) |raw_scopes| {
        const scopes = std.mem.trim(u8, raw_scopes, " \t\r\n");
        applied.actor_scopes_json = try domain.intersectJsonStringLists(input.allocator, scopes, applied.actor_scopes_json);
    }

    if (try extractHeaderStrict(raw_request, "X-NullPantry-Actor-Capabilities")) |raw_caps| {
        const caps = std.mem.trim(u8, raw_caps, " \t\r\n");
        applied.actor_capabilities_json = try domain.intersectJsonStringLists(input.allocator, caps, applied.actor_capabilities_json);
    }
    return applied;
}

fn actorHeadersAllowed(input: PrincipalInput) bool {
    if (input.trust_actor_headers) return true;
    return input.required_token == null and input.token_principals_json == null;
}

fn principalRegistryHasToken(allocator: std.mem.Allocator, registry_json: []const u8, token: []const u8) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, registry_json, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    var iterator = parsed.value.object.iterator();
    var matched = false;
    while (iterator.next()) |entry| {
        if (std.mem.trim(u8, entry.key_ptr.*, " \t\r\n").len == 0) return false;
        if (!principalValueValid(entry.value_ptr.*)) return false;
        if (tokenEql(token, entry.key_ptr.*)) matched = true;
    }
    return matched;
}

fn applyBearerPrincipal(allocator: std.mem.Allocator, token_principals_json: ?[]const u8, raw_request: []const u8, out: *AppliedPrincipal) !bool {
    const raw = token_principals_json orelse return false;
    const token = (try bearerTokenStrict(raw_request)) orelse return false;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidPrincipalRegistry;
    const value = blk: {
        var iterator = parsed.value.object.iterator();
        while (iterator.next()) |entry| {
            if (tokenEql(token, entry.key_ptr.*)) break :blk entry.value_ptr.*;
        }
        return false;
    };
    try validatePrincipalValue(value);
    std.debug.assert(value == .object);
    const principal = value.object;
    if (json.stringField(principal, "actor_id")) |actor_id| out.actor_id = try allocator.dupe(u8, actor_id);
    if (principal.get("scopes")) |scopes| {
        out.actor_scopes_json = try json.jsonFromValue(allocator, scopes);
    }
    if (principal.get("capabilities")) |caps| {
        out.actor_capabilities_json = try json.jsonFromValue(allocator, caps);
    }
    return true;
}

fn principalValueValid(value: std.json.Value) bool {
    validatePrincipalValue(value) catch return false;
    return true;
}

fn validatePrincipalValue(value: std.json.Value) !void {
    if (value != .object) return error.InvalidPrincipalRegistry;
    const principal = value.object;
    if (principal.get("actor_id")) |actor_id| {
        if (actor_id != .string) return error.InvalidPrincipalRegistry;
        if (std.mem.trim(u8, actor_id.string, " \t\r\n").len == 0) return error.InvalidPrincipalRegistry;
    }
    if (principal.get("scopes")) |scopes| try validatePrincipalStringList(scopes);
    if (principal.get("capabilities")) |caps| try validatePrincipalStringList(caps);
}

fn validatePrincipalStringList(value: std.json.Value) !void {
    if (value != .array) return error.InvalidPrincipalRegistry;
    for (value.array.items) |item| {
        if (item != .string) return error.InvalidPrincipalRegistry;
        if (std.mem.trim(u8, item.string, " \t\r\n").len == 0) return error.InvalidPrincipalRegistry;
    }
}

fn bearerTokenStrict(raw: []const u8) !?[]const u8 {
    const header = try extractHeaderStrict(raw, "Authorization") orelse return null;
    if (!std.ascii.startsWithIgnoreCase(header, "Bearer ")) return null;
    const token = std.mem.trim(u8, header["Bearer ".len..], " \t");
    if (token.len == 0) return null;
    return token;
}

fn extractHeaderStrict(raw: []const u8, name: []const u8) !?[]const u8 {
    const header_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse raw.len;
    var lines = std.mem.splitSequence(u8, raw[0..header_end], "\r\n");
    _ = lines.next();
    var found: ?[]const u8 = null;
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(key, name)) continue;
        if (found != null) return error.DuplicateHeader;
        found = std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return found;
}

fn tokenEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |a_byte, b_byte| {
        diff |= a_byte ^ b_byte;
    }
    return diff == 0;
}

test "auth token equality is exact" {
    try std.testing.expect(tokenEql("secret-token", "secret-token"));
    try std.testing.expect(!tokenEql("secret-token", "secret-tokem"));
    try std.testing.expect(!tokenEql("secret-token", "secret"));
    try std.testing.expect(!tokenEql("secret", "secret-token"));
}

test "empty required token never authorizes" {
    try std.testing.expect(!authorized(std.testing.allocator, "", null, "GET / HTTP/1.1\r\n\r\n"));
    try std.testing.expect(!authorized(std.testing.allocator, "", null, "GET / HTTP/1.1\r\nAuthorization: Bearer anything\r\n\r\n"));
}

test "empty bearer token never authorizes" {
    try std.testing.expect(!authorized(std.testing.allocator, "secret", null, "GET / HTTP/1.1\r\nAuthorization: Bearer \r\n\r\n"));
    try std.testing.expect(!authorized(std.testing.allocator, null, "{\"\":{\"actor_id\":\"empty\"}}", "GET / HTTP/1.1\r\nAuthorization: Bearer \t\r\n\r\n"));
}

test "duplicate auth and actor headers fail closed" {
    try std.testing.expect(!authorized(std.testing.allocator, "secret", null, "GET / HTTP/1.1\r\nAuthorization: Bearer secret\r\nAuthorization: Bearer secret\r\n\r\n"));
    try std.testing.expectError(error.DuplicateHeader, applyRequestPrincipal(.{
        .allocator = std.testing.allocator,
        .required_token = "secret",
        .actor_id = "local",
        .actor_scopes_json = "[\"public\"]",
        .actor_capabilities_json = "[\"read\"]",
    }, "GET / HTTP/1.1\r\nAuthorization: Bearer secret\r\nX-NullPantry-Actor-Scopes: [\"public\"]\r\nX-NullPantry-Actor-Scopes: [\"public\"]\r\n\r\n"));
}

test "auth accepts principal registry tokens and rejects missing tokens" {
    const registry =
        \\{"agent-a":{"actor_id":"agent:a","scopes":["public"],"capabilities":["read"]}}
    ;
    try std.testing.expect(authorized(std.testing.allocator, null, registry, "GET / HTTP/1.1\r\nAuthorization: Bearer agent-a\r\n\r\n"));
    try std.testing.expect(!authorized(std.testing.allocator, null, registry, "GET / HTTP/1.1\r\n\r\n"));
    try std.testing.expect(!authorized(std.testing.allocator, null, registry, "GET / HTTP/1.1\r\nAuthorization: Bearer wrong\r\n\r\n"));
}

test "auth principal registry disables shared token fallback" {
    const registry =
        \\{"agent-a":{"actor_id":"agent:a","scopes":["public"],"capabilities":["read"]}}
    ;
    try std.testing.expect(!authorized(std.testing.allocator, "shared-admin", registry, "GET / HTTP/1.1\r\nAuthorization: Bearer shared-admin\r\n\r\n"));
    try std.testing.expect(authorized(std.testing.allocator, "shared-admin", registry, "GET / HTTP/1.1\r\nAuthorization: Bearer agent-a\r\n\r\n"));
}

test "auth principal registry validates principal shape" {
    try validatePrincipalRegistry(std.testing.allocator,
        \\{"agent-a":{"actor_id":"agent:a","scopes":["public"],"capabilities":["read"]}}
    );
    try validatePrincipalRegistry(std.testing.allocator, "{}");
    try std.testing.expectError(error.InvalidPrincipalRegistry, validatePrincipalRegistry(std.testing.allocator, "[]"));
    try std.testing.expectError(error.InvalidPrincipalRegistry, validatePrincipalRegistry(std.testing.allocator, "{\" \":{\"scopes\":[\"public\"]}}"));
    try std.testing.expectError(error.InvalidPrincipalRegistry, validatePrincipalRegistry(std.testing.allocator, "{\"agent-a\":[]}"));
    try std.testing.expectError(error.InvalidPrincipalRegistry, validatePrincipalRegistry(std.testing.allocator, "{\"agent-a\":{\"actor_id\":\" \"}}"));
    try std.testing.expectError(error.InvalidPrincipalRegistry, validatePrincipalRegistry(std.testing.allocator, "{\"agent-a\":{\"scopes\":[1]}}"));
    try std.testing.expectError(error.InvalidPrincipalRegistry, validatePrincipalRegistry(std.testing.allocator, "{\"agent-a\":{\"scopes\":[\"\"]}}"));
    try std.testing.expectError(error.InvalidPrincipalRegistry, validatePrincipalRegistry(std.testing.allocator, "{\"agent-a\":{\"capabilities\":[\"read\",\"  \"]}}"));
}

test "auth rejects malformed matched principal before applying context" {
    const malformed =
        \\{"agent-a":{"actor_id":"agent:a","scopes":[1],"capabilities":["read"]}}
    ;
    const malformed_sibling =
        \\{"agent-a":{"scopes":["public"]},"broken":{"scopes":[1]}}
    ;
    try std.testing.expect(!authorized(std.testing.allocator, null, malformed, "GET / HTTP/1.1\r\nAuthorization: Bearer agent-a\r\n\r\n"));
    try std.testing.expect(!authorized(std.testing.allocator, null, malformed_sibling, "GET / HTTP/1.1\r\nAuthorization: Bearer agent-a\r\n\r\n"));
    try std.testing.expectError(error.InvalidPrincipalRegistry, applyRequestPrincipal(.{
        .allocator = std.testing.allocator,
        .token_principals_json = malformed,
        .actor_id = "local",
        .actor_scopes_json = "[\"admin\"]",
        .actor_capabilities_json = "[\"read\",\"write\",\"delete\"]",
    }, "GET / HTTP/1.1\r\nAuthorization: Bearer agent-a\r\n\r\n"));
}

test "auth token principal cannot be spoofed by actor header" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const registry =
        \\{"real-token":{"actor_id":"agent:real","scopes":["public","project:a"],"capabilities":["read","write"]}}
    ;
    const applied = try applyRequestPrincipal(.{
        .allocator = arena.allocator(),
        .token_principals_json = registry,
        .actor_id = "local",
        .actor_scopes_json = "[\"admin\"]",
        .actor_capabilities_json = "[\"read\",\"write\",\"delete\"]",
    }, "GET / HTTP/1.1\r\nAuthorization: Bearer real-token\r\nX-NullPantry-Actor-Id: agent:spoof\r\n\r\n");
    try std.testing.expectEqualStrings("agent:real", applied.actor_id);
    try std.testing.expectEqualStrings("[\"public\",\"project:a\"]", applied.actor_scopes_json);
}

test "auth request headers can narrow scopes and capabilities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const registry =
        \\{"agent-a":{"actor_id":"agent:a","scopes":["public","project:a"],"capabilities":["read","write"]}}
    ;
    const applied = try applyRequestPrincipal(.{
        .allocator = arena.allocator(),
        .token_principals_json = registry,
        .actor_id = "local",
        .actor_scopes_json = "[\"admin\"]",
        .actor_capabilities_json = "[\"read\",\"write\",\"delete\"]",
    }, "GET / HTTP/1.1\r\nAuthorization: Bearer agent-a\r\nX-NullPantry-Actor-Scopes: [\"project:a\",\"project:b\"]\r\nX-NullPantry-Actor-Capabilities: [\"read\",\"delete\"]\r\n\r\n");
    try std.testing.expectEqualStrings("[\"project:a\"]", applied.actor_scopes_json);
    try std.testing.expectEqualStrings("[\"read\"]", applied.actor_capabilities_json);
}

test "auth request headers reject malformed scope and capability lists" {
    try std.testing.expectError(error.InvalidRawJson, applyRequestPrincipal(.{
        .allocator = std.testing.allocator,
        .actor_id = "local",
        .actor_scopes_json = "[\"public\"]",
        .actor_capabilities_json = "[\"read\"]",
    }, "GET / HTTP/1.1\r\nX-NullPantry-Actor-Scopes: [\"public\",42]\r\n\r\n"));

    try std.testing.expectError(error.InvalidRawJson, applyRequestPrincipal(.{
        .allocator = std.testing.allocator,
        .actor_id = "local",
        .actor_scopes_json = "[\"public\"]",
        .actor_capabilities_json = "[\"read\"]",
    }, "GET / HTTP/1.1\r\nX-NullPantry-Actor-Capabilities: [\"read\",false]\r\n\r\n"));
}

test "auth request actor header rejects blank actor ids" {
    try std.testing.expectError(error.InvalidActorHeader, applyRequestPrincipal(.{
        .allocator = std.testing.allocator,
        .trust_actor_headers = true,
        .actor_id = "local",
        .actor_scopes_json = "[\"public\"]",
        .actor_capabilities_json = "[\"read\"]",
    }, "GET / HTTP/1.1\r\nX-NullPantry-Actor-Id: \t \r\n\r\n"));
}
