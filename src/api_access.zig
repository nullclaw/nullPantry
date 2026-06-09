const std = @import("std");
const domain = @import("domain.zig");
const access = @import("access.zig");
const Store = @import("store.zig").Store;
const api_types = @import("api_types.zig");
const api_feed_context = @import("api_feed_context.zig");

pub const Context = api_types.Context;

pub fn hasCapability(ctx: *Context, capability: []const u8) bool {
    return domain.hasCapability(ctx.actor_scopes_json, ctx.actor_capabilities_json, capability);
}

pub fn canWritePermissions(ctx: *Context, permissions_json: []const u8) bool {
    return hasCapability(ctx, "write") and domain.permissionsWritable(permissions_json, ctx.actor_scopes_json);
}

pub fn canWriteRecord(ctx: *Context, scope: []const u8, permissions_json: []const u8) bool {
    if (!canWritePermissions(ctx, permissions_json) or !domain.scopeWritable(scope, ctx.actor_scopes_json)) return false;
    const policy = ctx.store.getPolicyScope(ctx.allocator, scope) catch return false;
    if (policy) |p| {
        if (!domain.permissionsWritable(p.permissions_json, ctx.actor_scopes_json)) return false;
    }
    return true;
}

pub fn canProposeRecord(ctx: *Context, scope: []const u8, permissions_json: []const u8) bool {
    if (!((hasCapability(ctx, "propose") or hasCapability(ctx, "write")) and
        domain.scopeVisible(scope, ctx.actor_scopes_json) and
        domain.permissionsWritable(permissions_json, ctx.actor_scopes_json))) return false;
    const policy = ctx.store.getPolicyScope(ctx.allocator, scope) catch return false;
    if (policy) |p| return domain.permissionsWritable(p.permissions_json, ctx.actor_scopes_json);
    return true;
}

pub fn recordVisibleToActor(ctx: *Context, scope: []const u8, permissions_json: []const u8) bool {
    return recordVisibleToScopes(ctx, scope, permissions_json, ctx.actor_scopes_json);
}

pub fn recordVisibleToScopes(ctx: *Context, scope: []const u8, permissions_json: []const u8, scopes_json: []const u8) bool {
    if (!domain.recordVisible(scope, permissions_json, scopes_json)) return false;
    const policy = ctx.store.getPolicyScope(ctx.allocator, scope) catch return false;
    if (policy) |p| return domain.recordVisible(p.scope, p.permissions_json, scopes_json);
    return true;
}

pub fn feedRecordVisibleToActor(ctx: *Context, scope: []const u8, permissions_json: []const u8) bool {
    if (recordVisibleToActor(ctx, scope, permissions_json)) return true;
    if (std.mem.startsWith(u8, scope, "session:")) {
        if (!domain.scopeVisible(scope, ctx.actor_scopes_json)) return false;
        return access.permissionsVisibleForActor(ctx.allocator, permissions_json, ctx.actor_scopes_json, ctx.actor_id);
    }
    if (!domain.isActorOwnedAgentMemoryScope(scope, ctx.actor_id)) return false;
    const policy = ctx.store.getPolicyScope(ctx.allocator, scope) catch return false;
    if (policy) |p| {
        const feed_scopes = api_feed_context.scopesJson(ctx) catch return false;
        defer ctx.allocator.free(feed_scopes);
        if (!domain.recordVisible(p.scope, p.permissions_json, feed_scopes)) return false;
    }
    return access.permissionsVisibleForActor(ctx.allocator, permissions_json, ctx.actor_scopes_json, ctx.actor_id);
}

test "api access gates capabilities and policy visibility" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var ctx = Context{
        .allocator = std.testing.allocator,
        .store = &store,
        .actor_scopes_json = "[\"public\",\"write:public\"]",
        .actor_capabilities_json = "[\"read\",\"write\"]",
    };
    try std.testing.expect(hasCapability(&ctx, "read"));
    try std.testing.expect(canWriteRecord(&ctx, "public", "[]"));
    try std.testing.expect(recordVisibleToActor(&ctx, "public", "[]"));
    try std.testing.expect(!recordVisibleToActor(&ctx, "private", "[]"));
}
