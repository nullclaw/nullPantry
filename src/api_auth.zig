const std = @import("std");
const auth = @import("auth.zig");
const api_types = @import("api_types.zig");

pub const Context = api_types.Context;

pub const PrincipalSnapshot = struct {
    actor_id: []const u8,
    actor_scopes_json: []const u8,
    actor_capabilities_json: []const u8,
};

pub fn authorized(ctx: *Context, raw_request: []const u8) bool {
    return auth.authorized(ctx.allocator, ctx.required_token, ctx.token_principals_json, raw_request);
}

pub fn applyRequestPrincipal(ctx: *Context, raw_request: []const u8) !PrincipalSnapshot {
    const previous = PrincipalSnapshot{
        .actor_id = ctx.actor_id,
        .actor_scopes_json = ctx.actor_scopes_json,
        .actor_capabilities_json = ctx.actor_capabilities_json,
    };
    const applied = try auth.applyRequestPrincipal(.{
        .allocator = ctx.allocator,
        .required_token = ctx.required_token,
        .token_principals_json = ctx.token_principals_json,
        .trust_actor_headers = ctx.trust_actor_headers,
        .actor_id = ctx.actor_id,
        .actor_scopes_json = ctx.actor_scopes_json,
        .actor_capabilities_json = ctx.actor_capabilities_json,
    }, raw_request);
    ctx.actor_id = applied.actor_id;
    ctx.actor_scopes_json = applied.actor_scopes_json;
    ctx.actor_capabilities_json = applied.actor_capabilities_json;
    return previous;
}

pub fn restoreRequestPrincipal(ctx: *Context, snapshot: PrincipalSnapshot) void {
    ctx.actor_id = snapshot.actor_id;
    ctx.actor_scopes_json = snapshot.actor_scopes_json;
    ctx.actor_capabilities_json = snapshot.actor_capabilities_json;
}

test "api auth principal application restores previous context" {
    var ctx = Context{
        .allocator = std.testing.allocator,
        .store = undefined,
        .trust_actor_headers = true,
    };
    const snapshot = try applyRequestPrincipal(&ctx, "GET /v1/search HTTP/1.1\r\nX-NullPantry-Actor-Id: agent:a\r\n\r\n");
    try std.testing.expectEqualStrings("agent:a", ctx.actor_id);
    restoreRequestPrincipal(&ctx, snapshot);
    try std.testing.expectEqualStrings("local", ctx.actor_id);
}
