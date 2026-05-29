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
            if (required.len == 0) return true;
        }
    }
    const token = json.bearerToken(raw_request) orelse return false;
    if (token_principals_json) |registry| {
        return principalRegistryHasToken(allocator, registry, token);
    }
    const required = required_token orelse return false;
    if (required.len == 0) return true;
    return std.mem.eql(u8, token, required);
}

pub fn applyRequestPrincipal(input: PrincipalInput, raw_request: []const u8) !AppliedPrincipal {
    var applied = AppliedPrincipal{
        .actor_id = input.actor_id,
        .actor_scopes_json = input.actor_scopes_json,
        .actor_capabilities_json = input.actor_capabilities_json,
    };
    const principal_locked = try applyBearerPrincipal(input.allocator, input.token_principals_json, raw_request, &applied);
    if (!principal_locked and actorHeadersAllowed(input)) {
        if (json.extractHeader(raw_request, "X-NullPantry-Actor-Id")) |actor_id| {
            applied.actor_id = std.mem.trim(u8, actor_id, " \t\r\n");
        }
    }

    if (json.extractHeader(raw_request, "X-NullPantry-Actor-Scopes")) |raw_scopes| {
        const scopes = std.mem.trim(u8, raw_scopes, " \t\r\n");
        applied.actor_scopes_json = try domain.intersectJsonStringLists(input.allocator, scopes, applied.actor_scopes_json);
    }

    if (json.extractHeader(raw_request, "X-NullPantry-Actor-Capabilities")) |raw_caps| {
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
    return parsed.value.object.get(token) != null;
}

fn applyBearerPrincipal(allocator: std.mem.Allocator, token_principals_json: ?[]const u8, raw_request: []const u8, out: *AppliedPrincipal) !bool {
    const raw = token_principals_json orelse return false;
    const token = json.bearerToken(raw_request) orelse return false;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidPrincipalRegistry;
    const value = parsed.value.object.get(token) orelse return false;
    if (value != .object) return error.InvalidPrincipalRegistry;
    const principal = value.object;
    if (json.stringField(principal, "actor_id")) |actor_id| out.actor_id = try allocator.dupe(u8, actor_id);
    if (principal.get("scopes")) |scopes| {
        if (scopes != .array) return error.InvalidPrincipalRegistry;
        out.actor_scopes_json = try json.jsonFromValue(allocator, scopes);
    }
    if (principal.get("capabilities")) |caps| {
        if (caps != .array) return error.InvalidPrincipalRegistry;
        out.actor_capabilities_json = try json.jsonFromValue(allocator, caps);
    }
    return true;
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
