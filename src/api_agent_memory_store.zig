const std = @import("std");
const access = @import("access.zig");
const api_types = @import("api_types.zig");
const domain = @import("domain.zig");
const store_mod = @import("store.zig");
const api_access = @import("api_access.zig");
const api_session_access = @import("api_session_access.zig");

const Context = api_types.Context;
const Route = store_mod.AgentMemoryStorageRoute;
const ReadAccess = store_mod.AgentMemoryReadAccess;

pub const Auth = struct {
    actor_id: []const u8,
    scopes_json: []const u8,
    capabilities_json: ?[]const u8,
};

pub const DeleteInput = struct {
    key: []const u8,
    session_id: ?[]const u8 = null,
    owner_actor_id: ?[]const u8 = null,
    route: Route,
    all_owners: bool = false,
    suppress_feed: bool = false,
};

pub const GetInput = struct {
    key: []const u8,
    route: Route,
    session_id: ?[]const u8 = null,
    owner_actor_id: ?[]const u8 = null,
    auth: ?Auth = null,
    access: ReadAccess = .visible,
};

pub const ListInput = struct {
    route: Route,
    category: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    owner_actor_id: ?[]const u8 = null,
    auth: ?Auth = null,
    access: ReadAccess = .visible,
    limit: ?usize = null,
    offset: usize = 0,
};

pub const SearchInput = struct {
    query: []const u8,
    route: Route,
    limit: usize = 10,
    session_id: ?[]const u8 = null,
    owner_actor_id: ?[]const u8 = null,
    auth: ?Auth = null,
    access: ReadAccess = .visible,
};

pub fn contextAuth(ctx: *const Context) Auth {
    return .{
        .actor_id = ctx.actor_id,
        .scopes_json = ctx.actor_scopes_json,
        .capabilities_json = ctx.actor_capabilities_json,
    };
}

pub fn scopedAuth(ctx: *const Context, scopes_json: []const u8) Auth {
    return .{
        .actor_id = ctx.actor_id,
        .scopes_json = scopes_json,
        .capabilities_json = ctx.actor_capabilities_json,
    };
}

fn readAuth(ctx: *const Context, auth: ?Auth) Auth {
    return auth orelse contextAuth(ctx);
}

fn readActorId(access_mode: ReadAccess, auth: Auth, owner_actor_id: ?[]const u8) ?[]const u8 {
    return switch (access_mode) {
        .exact_owner => owner_actor_id,
        .visible, .any_visible => auth.actor_id,
    };
}

fn readScopesJson(access_mode: ReadAccess, auth: Auth) []const u8 {
    return switch (access_mode) {
        .exact_owner => "[]",
        .visible, .any_visible => auth.scopes_json,
    };
}

pub fn getByInput(ctx: *Context, input: GetInput) !?domain.AgentMemory {
    const auth = readAuth(ctx, input.auth);
    return ctx.store.agentMemoryGetByInput(ctx.allocator, .{
        .key = input.key,
        .session_id = input.session_id,
        .actor_id = readActorId(input.access, auth, input.owner_actor_id),
        .scopes_json = readScopesJson(input.access, auth),
        .capabilities_json = auth.capabilities_json,
        .route = input.route,
        .access = input.access,
    });
}

pub fn listByInput(ctx: *Context, input: ListInput) ![]domain.AgentMemory {
    const auth = readAuth(ctx, input.auth);
    return ctx.store.agentMemoryListByInput(ctx.allocator, .{
        .category = input.category,
        .session_id = input.session_id,
        .actor_id = readActorId(input.access, auth, input.owner_actor_id),
        .scopes_json = readScopesJson(input.access, auth),
        .capabilities_json = auth.capabilities_json,
        .route = input.route,
        .access = input.access,
        .limit = input.limit,
        .offset = input.offset,
    });
}

pub fn searchByInput(ctx: *Context, input: SearchInput) ![]domain.AgentMemory {
    const auth = readAuth(ctx, input.auth);
    return ctx.store.agentMemorySearchByInput(ctx.allocator, .{
        .query = input.query,
        .limit = input.limit,
        .session_id = input.session_id,
        .actor_id = readActorId(input.access, auth, input.owner_actor_id),
        .scopes_json = readScopesJson(input.access, auth),
        .capabilities_json = auth.capabilities_json,
        .route = input.route,
        .access = input.access,
    });
}

pub fn delete(ctx: *Context, input: DeleteInput) !bool {
    return ctx.store.agentMemoryDeleteByInput(.{
        .key = input.key,
        .session_id = input.session_id,
        .actor_id = input.owner_actor_id,
        .writer_actor_id = ctx.actor_id,
        .actor_scopes_json = ctx.actor_scopes_json,
        .actor_capabilities_json = ctx.actor_capabilities_json,
        .route = input.route,
        .all_owners = input.all_owners,
        .suppress_feed = input.suppress_feed,
    });
}

pub fn requestedScopeReadable(ctx: *Context, requested_scope: ?[]const u8) bool {
    const scope = requested_scope orelse return true;
    if (scope.len == 0) return true;
    if (domain.isActorOwnedAgentMemoryScope(scope, ctx.actor_id)) return true;
    return api_access.recordVisibleToActor(ctx, scope, "[]");
}

pub fn entryVisible(ctx: *Context, entry: domain.AgentMemory) bool {
    return access.agentMemoryVisible(ctx.allocator, .{
        .owner_actor_id = entry.actor_id,
        .scope = entry.scope,
        .permissions_json = entry.permissions_json,
        .session_id = entry.session_id,
        .request_actor_id = ctx.actor_id,
        .request_scopes_json = ctx.actor_scopes_json,
        .record_visible = api_access.recordVisibleToActor(ctx, entry.scope, entry.permissions_json),
        .session_visible = if (entry.session_id) |sid| api_session_access.readAllowed(ctx, sid) else true,
    });
}

pub fn entryDeletable(ctx: *Context, entry: domain.AgentMemory) bool {
    if (entryActorOwnedAndVisible(ctx, entry)) return true;
    if (entrySessionWriteAllowed(ctx, entry)) return true;
    return domain.scopeDeletable(entry.scope, ctx.actor_scopes_json) and domain.permissionsWritable(entry.permissions_json, ctx.actor_scopes_json);
}

pub fn entryMigratable(ctx: *Context, entry: domain.AgentMemory) bool {
    if (entryActorOwnedAndVisible(ctx, entry)) return true;
    if (entrySessionWriteAllowed(ctx, entry)) return true;
    return api_access.canWriteRecord(ctx, entry.scope, entry.permissions_json);
}

fn entryActorOwnedAndVisible(ctx: *Context, entry: domain.AgentMemory) bool {
    return std.mem.eql(u8, entry.actor_id, ctx.actor_id) and
        domain.isActorOwnedAgentMemoryScope(entry.scope, ctx.actor_id) and
        access.permissionsVisibleForActor(ctx.allocator, entry.permissions_json, ctx.actor_scopes_json, ctx.actor_id);
}

fn entrySessionWriteAllowed(ctx: *Context, entry: domain.AgentMemory) bool {
    const sid = entry.session_id orelse return false;
    const session_scope = std.fmt.allocPrint(ctx.allocator, "session:{s}", .{sid}) catch return false;
    defer ctx.allocator.free(session_scope);
    if (!std.mem.eql(u8, entry.scope, session_scope)) return false;
    if (!access.permissionsVisibleForActor(ctx.allocator, entry.permissions_json, ctx.actor_scopes_json, ctx.actor_id)) return false;
    return api_session_access.writeAllowed(ctx, sid);
}

fn testEntry(input: struct {
    key: []const u8 = "pref",
    session_id: ?[]const u8 = null,
    actor_id: []const u8 = "agent:test",
    scope: []const u8 = "agent:agent:test",
    permissions_json: []const u8 = "[]",
}) domain.AgentMemory {
    return .{
        .id = input.key,
        .key = input.key,
        .content = "value",
        .category = "core",
        .session_id = input.session_id,
        .timestamp = "10",
        .actor_id = input.actor_id,
        .writer_actor_id = input.actor_id,
        .scope = input.scope,
        .permissions_json = input.permissions_json,
    };
}

test "agent memory API store auth mirrors request context" {
    const ctx = Context{
        .allocator = undefined,
        .store = undefined,
        .actor_id = "agent:reader",
        .actor_scopes_json = "[\"public\"]",
        .actor_capabilities_json = "[\"read\"]",
    };
    const auth = contextAuth(&ctx);
    try std.testing.expectEqualStrings("agent:reader", auth.actor_id);
    try std.testing.expectEqualStrings("[\"public\"]", auth.scopes_json);
    try std.testing.expectEqualStrings("[\"read\"]", auth.capabilities_json.?);
}

test "agent memory API store read surface is input based" {
    const self = @This();
    try std.testing.expect(@hasDecl(self, "getByInput"));
    try std.testing.expect(@hasDecl(self, "listByInput"));
    try std.testing.expect(@hasDecl(self, "searchByInput"));
    try std.testing.expect(@hasField(GetInput, "access"));
    try std.testing.expect(@hasField(ListInput, "limit"));
    try std.testing.expect(@hasField(SearchInput, "auth"));
    try std.testing.expect(!@hasDecl(self, "getVisible"));
    try std.testing.expect(!@hasDecl(self, "listAnyVisibleWindow"));
    try std.testing.expect(!@hasDecl(self, "searchAnyVisible"));
}

test "agent memory API store owns entry access predicates" {
    var store = try store_mod.Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var ctx = Context{
        .allocator = std.testing.allocator,
        .store = &store,
        .actor_id = "agent:test",
        .actor_scopes_json = "[\"public\",\"write:public\",\"delete:public\",\"session:s-1\",\"write:session:s-1\"]",
        .actor_capabilities_json = "[\"read\",\"write\",\"delete\"]",
    };

    try std.testing.expect(requestedScopeReadable(&ctx, "public"));
    try std.testing.expect(!requestedScopeReadable(&ctx, "private"));
    try std.testing.expect(entryVisible(&ctx, testEntry(.{})));
    try std.testing.expect(entryDeletable(&ctx, testEntry(.{})));
    try std.testing.expect(entryMigratable(&ctx, testEntry(.{})));

    const session_entry = testEntry(.{
        .key = "session.pref",
        .session_id = "s-1",
        .scope = "session:s-1",
        .permissions_json = "[]",
    });
    try std.testing.expect(entryVisible(&ctx, session_entry));
    try std.testing.expect(entryDeletable(&ctx, session_entry));
    try std.testing.expect(entryMigratable(&ctx, session_entry));
}
