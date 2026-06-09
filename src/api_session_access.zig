const std = @import("std");
const domain = @import("domain.zig");
const api_access = @import("api_access.zig");
const api_types = @import("api_types.zig");

pub const Context = api_types.Context;

pub fn readAllowed(ctx: *Context, session_id: []const u8) bool {
    if (domain.hasActorScope(ctx.actor_scopes_json, "admin")) return true;
    if (!api_access.hasCapability(ctx, "read")) return false;
    const scope = sessionScope(ctx.allocator, session_id) catch return false;
    defer ctx.allocator.free(scope);
    return domain.scopeVisible(scope, ctx.actor_scopes_json);
}

pub fn writeAllowed(ctx: *Context, session_id: []const u8) bool {
    if (domain.hasActorScope(ctx.actor_scopes_json, "admin")) return true;
    if (!api_access.hasCapability(ctx, "write")) return false;
    const scope = sessionScope(ctx.allocator, session_id) catch return false;
    defer ctx.allocator.free(scope);
    return domain.scopeWritable(scope, ctx.actor_scopes_json);
}

pub fn allReadAllowed(ctx: *Context) bool {
    if (domain.hasActorScope(ctx.actor_scopes_json, "admin")) return true;
    if (!api_access.hasCapability(ctx, "read")) return false;
    return domain.scopeVisible("session:", ctx.actor_scopes_json);
}

pub fn allWriteAllowed(ctx: *Context) bool {
    if (domain.hasActorScope(ctx.actor_scopes_json, "admin")) return true;
    if (!api_access.hasCapability(ctx, "write")) return false;
    return domain.scopeWritable("session:", ctx.actor_scopes_json);
}

fn sessionScope(allocator: std.mem.Allocator, session_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "session:{s}", .{session_id});
}

test "api session access grants scoped read and write" {
    var ctx = Context{
        .allocator = std.testing.allocator,
        .store = undefined,
        .actor_scopes_json = "[\"session:alpha\",\"write:session:alpha\"]",
        .actor_capabilities_json = "[\"read\",\"write\"]",
    };

    try std.testing.expect(readAllowed(&ctx, "alpha"));
    try std.testing.expect(writeAllowed(&ctx, "alpha"));
    try std.testing.expect(!readAllowed(&ctx, "beta"));
    try std.testing.expect(!writeAllowed(&ctx, "beta"));
}

test "api session access requires capabilities before scoped grants" {
    var ctx = Context{
        .allocator = std.testing.allocator,
        .store = undefined,
        .actor_scopes_json = "[\"session:alpha\",\"write:session:alpha\"]",
        .actor_capabilities_json = "[\"read\"]",
    };

    try std.testing.expect(readAllowed(&ctx, "alpha"));
    try std.testing.expect(!writeAllowed(&ctx, "alpha"));
}

test "api session access wildcard grants all sessions" {
    var ctx = Context{
        .allocator = std.testing.allocator,
        .store = undefined,
        .actor_scopes_json = "[\"session:*\",\"write:session:*\"]",
        .actor_capabilities_json = "[\"read\",\"write\"]",
    };

    try std.testing.expect(allReadAllowed(&ctx));
    try std.testing.expect(allWriteAllowed(&ctx));
    try std.testing.expect(readAllowed(&ctx, "alpha"));
    try std.testing.expect(writeAllowed(&ctx, "beta"));
}

test "api session access admin bypasses capabilities and scopes" {
    var ctx = Context{
        .allocator = std.testing.allocator,
        .store = undefined,
        .actor_scopes_json = "[\"admin\"]",
        .actor_capabilities_json = "[]",
    };

    try std.testing.expect(readAllowed(&ctx, "alpha"));
    try std.testing.expect(writeAllowed(&ctx, "alpha"));
    try std.testing.expect(allReadAllowed(&ctx));
    try std.testing.expect(allWriteAllowed(&ctx));
}
