const std = @import("std");
const domain = @import("domain.zig");
const json = @import("json_util.zig");

pub fn sessionVisibleForScopes(allocator: std.mem.Allocator, session_id: []const u8, scopes_json: []const u8) bool {
    if (domain.hasActorScope(scopes_json, "admin")) return true;
    const scope = std.fmt.allocPrint(allocator, "session:{s}", .{session_id}) catch return false;
    defer allocator.free(scope);
    return domain.scopeVisible(scope, scopes_json);
}

pub fn scopeNoBroader(source_scope: []const u8, target_scope: []const u8) bool {
    if (std.mem.eql(u8, source_scope, "public")) return true;
    return std.mem.eql(u8, source_scope, target_scope);
}

pub fn permissionsOpen(permissions_json: []const u8) bool {
    const trimmed = std.mem.trim(u8, permissions_json, " \t\r\n");
    return trimmed.len == 0 or std.mem.eql(u8, trimmed, "[]") or domain.hasJsonString(trimmed, "public");
}

pub fn permissionsVisibleForActor(allocator: std.mem.Allocator, permissions_json: []const u8, actor_scopes_json: []const u8, actor_id: ?[]const u8) bool {
    if (domain.permissionsVisible(permissions_json, actor_scopes_json)) return true;
    if (actor_id) |actor| return domain.permissionsContainActorGrant(allocator, permissions_json, actor);
    return false;
}

pub fn permissionsNoBroader(allocator: std.mem.Allocator, source_permissions_json: []const u8, target_permissions_json: []const u8) bool {
    if (permissionsOpen(source_permissions_json)) return true;
    if (permissionsOpen(target_permissions_json)) return false;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, target_permissions_json, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .array) return false;
    var saw = false;
    for (parsed.value.array.items) |item| {
        const permission = switch (item) {
            .string => |s| s,
            else => return false,
        };
        if (std.mem.eql(u8, permission, "public")) return false;
        if (!domain.hasJsonString(source_permissions_json, permission)) return false;
        saw = true;
    }
    return saw;
}

pub fn aclCoversTarget(allocator: std.mem.Allocator, source_scope: []const u8, source_permissions_json: []const u8, target_scope: []const u8, target_permissions_json: []const u8) bool {
    return scopeNoBroader(source_scope, target_scope) and permissionsNoBroader(allocator, source_permissions_json, target_permissions_json);
}

pub fn requiredScopesVisible(required_scopes_json: []const u8, actor_scopes_json: []const u8) bool {
    const trimmed = std.mem.trim(u8, required_scopes_json, " \t\r\n");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "[]")) return true;
    return domain.scopeListVisible(trimmed, actor_scopes_json);
}

pub fn actorMatches(request_actor_id: ?[]const u8, row_actor_id: ?[]const u8) bool {
    const request = request_actor_id orelse return false;
    const row = row_actor_id orelse return false;
    if (request.len == 0 or row.len == 0) return false;
    return std.mem.eql(u8, row, request);
}

pub fn isSharedAgentMemoryOwner(actor_id: []const u8) bool {
    return std.mem.startsWith(u8, actor_id, "shared:");
}

pub fn sharedAgentMemoryOwner(allocator: std.mem.Allocator, scope: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "shared:{s}", .{scope});
}

pub fn agentMemoryOwner(allocator: std.mem.Allocator, actor_id: []const u8, requested_scope: ?[]const u8) ![]const u8 {
    if (requested_scope) |scope| {
        if (scope.len > 0 and !domain.isActorOwnedAgentMemoryScope(scope, actor_id)) {
            return sharedAgentMemoryOwner(allocator, scope);
        }
    }
    return allocator.dupe(u8, actor_id);
}

pub fn cacheActorVisible(request_actor_id: []const u8, row_actor_id: []const u8) bool {
    if (request_actor_id.len == 0) return row_actor_id.len == 0;
    if (row_actor_id.len == 0) return false;
    return std.mem.eql(u8, request_actor_id, row_actor_id);
}

pub fn requiredActorId(actor_id: ?[]const u8) ![]const u8 {
    const actor = actor_id orelse return error.MissingActorId;
    if (actor.len == 0) return error.MissingActorId;
    return actor;
}

pub fn normalizeSessionId(session_id: ?[]const u8) ?[]const u8 {
    const sid = session_id orelse return null;
    if (sid.len == 0) return null;
    return sid;
}

pub fn agentMemoryScope(allocator: std.mem.Allocator, actor_id: []const u8, session_id: ?[]const u8, requested_scope: ?[]const u8) ![]const u8 {
    if (requested_scope) |scope| {
        if (scope.len > 0) return allocator.dupe(u8, scope);
    }
    if (normalizeSessionId(session_id)) |sid| return std.fmt.allocPrint(allocator, "session:{s}", .{sid});
    return domain.defaultAgentMemoryScope(allocator, actor_id);
}

pub fn agentMemoryPermissions(allocator: std.mem.Allocator, actor_id: []const u8, requested_scope: ?[]const u8, requested_permissions_json: []const u8) ![]const u8 {
    if (requested_scope != null or !permissionsOpen(requested_permissions_json)) {
        return allocator.dupe(u8, requested_permissions_json);
    }
    return domain.actorGrantJson(allocator, actor_id);
}

pub const AgentMemoryVisibility = struct {
    owner_actor_id: []const u8,
    scope: []const u8,
    permissions_json: []const u8,
    session_id: ?[]const u8,
    request_actor_id: ?[]const u8,
    request_scopes_json: []const u8,
    record_visible: bool,
    session_visible: bool,
};

pub fn agentMemoryVisible(allocator: std.mem.Allocator, input: AgentMemoryVisibility) bool {
    const actor = input.request_actor_id orelse return false;
    const same_owner = std.mem.eql(u8, input.owner_actor_id, actor);
    const actor_private_scope = same_owner and (domain.isActorOwnedAgentMemoryScope(input.scope, actor) or
        (input.session_id != null and std.mem.startsWith(u8, input.scope, "session:")));
    const visible = input.record_visible or
        (actor_private_scope and permissionsVisibleForActor(allocator, input.permissions_json, input.request_scopes_json, actor));
    if (!visible) return false;
    if (input.session_id != null) return input.session_visible;
    return true;
}

pub fn combinedPermissionsJson(allocator: std.mem.Allocator, a_json: []const u8, b_json: []const u8) ![]const u8 {
    if (permissionsOpen(a_json)) return allocator.dupe(u8, b_json);
    if (permissionsOpen(b_json)) return allocator.dupe(u8, a_json);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '[');
    var count: usize = 0;
    try appendPermissionJsonItems(allocator, &out, &count, a_json);
    try appendPermissionJsonItems(allocator, &out, &count, b_json);
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

fn appendPermissionJsonItems(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), count: *usize, permissions_json: []const u8) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, permissions_json, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .array) return;
    for (parsed.value.array.items) |item| {
        if (item != .string) continue;
        const needle = try std.fmt.allocPrint(allocator, "\"{s}\"", .{item.string});
        defer allocator.free(needle);
        if (std.mem.indexOf(u8, out.items, needle) != null) continue;
        if (count.* > 0) try out.append(allocator, ',');
        try json.appendString(out, allocator, item.string);
        count.* += 1;
    }
}

test "access actor matching is fail closed" {
    try std.testing.expect(actorMatches("agent:a", "agent:a"));
    try std.testing.expect(!actorMatches("agent:a", "agent:b"));
    try std.testing.expect(!actorMatches(null, "agent:a"));
    try std.testing.expect(!actorMatches("agent:a", null));
    try std.testing.expect(!actorMatches("", "agent:a"));
}

test "access cache actor matching is fail closed" {
    try std.testing.expect(cacheActorVisible("agent:a", "agent:a"));
    try std.testing.expect(!cacheActorVisible("agent:a", "agent:b"));
    try std.testing.expect(!cacheActorVisible("agent:a", ""));
    try std.testing.expect(cacheActorVisible("", ""));
    try std.testing.expect(!cacheActorVisible("", "agent:a"));
}

test "access session scopes require explicit session visibility" {
    const alloc = std.testing.allocator;
    try std.testing.expect(sessionVisibleForScopes(alloc, "sess_a", "[\"session:sess_a\"]"));
    try std.testing.expect(sessionVisibleForScopes(alloc, "sess_a", "[\"session:*\"]"));
    try std.testing.expect(!sessionVisibleForScopes(alloc, "sess_a", "[\"public\"]"));
}

test "access normalizes empty session ids to global memory" {
    try std.testing.expect(normalizeSessionId(null) == null);
    try std.testing.expect(normalizeSessionId("") == null);
    try std.testing.expectEqualStrings("sess", normalizeSessionId("sess").?);
}

test "access acl coverage prevents publishing narrower source content wider" {
    const alloc = std.testing.allocator;
    try std.testing.expect(aclCoversTarget(alloc, "public", "[]", "project:nullpantry", "[]"));
    try std.testing.expect(!aclCoversTarget(alloc, "project:secret", "[\"team:secret\"]", "public", "[]"));
    try std.testing.expect(!aclCoversTarget(alloc, "project:secret", "[\"team:secret\"]", "project:secret", "[\"public\"]"));
    try std.testing.expect(aclCoversTarget(alloc, "project:secret", "[\"team:secret\",\"team:platform\"]", "project:secret", "[\"team:secret\"]"));
}

test "access empty required scopes are visible for already-public context packs" {
    try std.testing.expect(requiredScopesVisible("[]", "[\"public\"]"));
    try std.testing.expect(requiredScopesVisible("", "[\"public\"]"));
}

test "access actor grants are actor-specific read permissions" {
    const alloc = std.testing.allocator;
    const permissions = try domain.actorGrantJson(alloc, "agent:a");
    defer alloc.free(permissions);
    try std.testing.expect(permissionsVisibleForActor(alloc, permissions, "[]", "agent:a"));
    try std.testing.expect(!permissionsVisibleForActor(alloc, permissions, "[]", "agent:b"));
}

test "access default native agent memory permissions are actor private" {
    const alloc = std.testing.allocator;
    const private = try agentMemoryPermissions(alloc, "agent:a", null, "[]");
    defer alloc.free(private);
    try std.testing.expect(std.mem.indexOf(u8, private, "actor:agent:a") != null);

    const explicit_scope = try agentMemoryPermissions(alloc, "agent:a", "project:nullpantry", "[]");
    defer alloc.free(explicit_scope);
    try std.testing.expectEqualStrings("[]", explicit_scope);
}

test "access native agent memory owner distinguishes private and shared scopes" {
    const alloc = std.testing.allocator;
    const private = try agentMemoryOwner(alloc, "agent:a", null);
    defer alloc.free(private);
    try std.testing.expectEqualStrings("agent:a", private);

    const actor_owned = try agentMemoryOwner(alloc, "agent:a", "agent:agent:a");
    defer alloc.free(actor_owned);
    try std.testing.expectEqualStrings("agent:a", actor_owned);

    const shared = try agentMemoryOwner(alloc, "agent:a", "team:alpha");
    defer alloc.free(shared);
    try std.testing.expectEqualStrings("shared:team:alpha", shared);
    try std.testing.expect(isSharedAgentMemoryOwner(shared));
}

test "access combines permissions without duplicates" {
    const combined = try combinedPermissionsJson(std.testing.allocator, "[\"team:a\",\"team:b\"]", "[\"team:b\",\"team:c\"]");
    defer std.testing.allocator.free(combined);
    try std.testing.expectEqualStrings("[\"team:a\",\"team:b\",\"team:c\"]", combined);
}
