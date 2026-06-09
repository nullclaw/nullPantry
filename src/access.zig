const std = @import("std");
const domain = @import("domain.zig");
const json = @import("json_util.zig");

pub fn sessionVisibleForScopes(allocator: std.mem.Allocator, session_id: []const u8, scopes_json: []const u8) bool {
    if (domain.hasActorScope(scopes_json, "admin")) return true;
    const scope = std.fmt.allocPrint(allocator, "session:{s}", .{session_id}) catch return false;
    defer allocator.free(scope);
    return domain.scopeVisible(scope, scopes_json);
}

pub fn scopeCoversTarget(container_scope: []const u8, target_scope: []const u8) bool {
    if (std.mem.eql(u8, container_scope, "public")) return true;
    return std.mem.eql(u8, container_scope, target_scope);
}

pub fn permissionsOpen(permissions_json: []const u8) bool {
    return domain.permissionsAreOpen(permissions_json);
}

pub fn permissionsVisibleForActor(allocator: std.mem.Allocator, permissions_json: []const u8, actor_scopes_json: []const u8, actor_id: ?[]const u8) bool {
    if (domain.permissionsVisible(permissions_json, actor_scopes_json)) return true;
    if (actor_id) |actor| return domain.permissionsContainActorGrant(allocator, permissions_json, actor);
    return false;
}

pub fn permissionsCoverTarget(allocator: std.mem.Allocator, container_permissions_json: []const u8, target_permissions_json: []const u8) bool {
    if (domain.permissionsArePublicReadable(container_permissions_json)) return true;
    if (domain.permissionsArePublicReadable(target_permissions_json)) return false;
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
        if (!domain.hasJsonString(container_permissions_json, permission)) return false;
        saw = true;
    }
    return saw;
}

pub fn aclCoversTarget(
    allocator: std.mem.Allocator,
    container_scope: []const u8,
    container_permissions_json: []const u8,
    target_scope: []const u8,
    target_permissions_json: []const u8,
) bool {
    return scopeCoversTarget(container_scope, target_scope) and
        permissionsCoverTarget(allocator, container_permissions_json, target_permissions_json);
}

pub fn requiredScopesVisible(required_scopes_json: []const u8, actor_scopes_json: []const u8) bool {
    const trimmed = std.mem.trim(u8, required_scopes_json, " \t\r\n");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "[]")) return true;
    return domain.scopeListVisible(trimmed, actor_scopes_json);
}

pub const malformed_permissions_required_gate = "__nullpantry_malformed_permissions_json__";
pub const malformed_required_access_gate = "__nullpantry_malformed_required_access_json__";
pub const malformed_required_scopes_gate = "__nullpantry_malformed_required_scopes_json__";

pub fn scopeFromRequiredScopesJson(allocator: std.mem.Allocator, required_scopes_json: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, required_scopes_json, " \t\r\n");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "[]")) return allocator.dupe(u8, "public");

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch return allocator.dupe(u8, malformed_required_scopes_gate);
    defer parsed.deinit();
    if (parsed.value != .array) return allocator.dupe(u8, malformed_required_scopes_gate);

    var selected_scope: ?[]const u8 = null;
    for (parsed.value.array.items) |item| {
        if (item != .string) return allocator.dupe(u8, malformed_required_scopes_gate);
        if (std.mem.trim(u8, item.string, " \t\r\n").len == 0) return allocator.dupe(u8, malformed_required_scopes_gate);
        if (std.mem.eql(u8, item.string, "public")) continue;
        if (selected_scope == null) selected_scope = item.string;
    }
    return allocator.dupe(u8, selected_scope orelse "public");
}

fn appendUniqueJsonString(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), count: *usize, value: []const u8) !void {
    const needle = try json.stringLiteral(allocator, value);
    defer allocator.free(needle);
    if (std.mem.indexOf(u8, out.items, needle) != null) return;
    if (count.* > 0) try out.append(allocator, ',');
    try json.appendString(out, allocator, value);
    count.* += 1;
}

fn appendMalformedPermissionsGate(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), count: *usize) !void {
    try appendUniqueJsonString(allocator, out, count, malformed_permissions_required_gate);
}

fn appendMalformedRequiredAccessGate(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), count: *usize) !void {
    try appendUniqueJsonString(allocator, out, count, malformed_required_access_gate);
}

pub fn requiredAccessJsonForActor(allocator: std.mem.Allocator, scope: []const u8, permissions_json: []const u8, actor_id: ?[]const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '[');
    var count: usize = 0;

    const actor = actor_id orelse "";
    const has_current_actor_grant = actor.len > 0 and domain.permissionsContainActorGrant(allocator, permissions_json, actor);
    const actor_grant = if (actor.len > 0 and !has_current_actor_grant) try domain.actorGrant(allocator, actor) else null;
    defer if (actor_grant) |grant| allocator.free(grant);

    if (scope.len > 0 and !std.mem.eql(u8, scope, "public") and !(actor.len > 0 and domain.isActorOwnedAgentMemoryScope(scope, actor))) {
        try appendUniqueJsonString(allocator, &out, &count, scope);
    }

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, permissions_json, .{}) catch {
        try appendMalformedPermissionsGate(allocator, &out, &count);
        try out.append(allocator, ']');
        return out.toOwnedSlice(allocator);
    };
    defer parsed.deinit();
    if (parsed.value != .array) {
        try appendMalformedPermissionsGate(allocator, &out, &count);
        try out.append(allocator, ']');
        return out.toOwnedSlice(allocator);
    }

    for (parsed.value.array.items) |item| {
        if (item != .string) {
            try appendMalformedPermissionsGate(allocator, &out, &count);
            break;
        }
        const permission = item.string;
        if (permission.len == 0) {
            try appendMalformedPermissionsGate(allocator, &out, &count);
            break;
        }
        if (std.mem.eql(u8, permission, "public")) continue;
        if (has_current_actor_grant and std.mem.startsWith(u8, permission, "actor:")) continue;
        if (actor_grant) |grant| if (std.mem.eql(u8, permission, grant)) continue;
        try appendUniqueJsonString(allocator, &out, &count, permission);
    }

    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

pub fn permissionsJsonFromRequiredAccessJson(allocator: std.mem.Allocator, scope: []const u8, required_access_json: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, required_access_json, " \t\r\n");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "[]")) return allocator.dupe(u8, "[]");

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '[');
    var count: usize = 0;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch {
        try appendMalformedRequiredAccessGate(allocator, &out, &count);
        try out.append(allocator, ']');
        return out.toOwnedSlice(allocator);
    };
    defer parsed.deinit();
    if (parsed.value != .array) {
        try appendMalformedRequiredAccessGate(allocator, &out, &count);
        try out.append(allocator, ']');
        return out.toOwnedSlice(allocator);
    }

    for (parsed.value.array.items) |item| {
        if (item != .string) {
            try appendMalformedRequiredAccessGate(allocator, &out, &count);
            break;
        }
        const gate = item.string;
        if (gate.len == 0) {
            try appendMalformedRequiredAccessGate(allocator, &out, &count);
            break;
        }
        if (std.mem.eql(u8, gate, "public")) continue;
        if (scope.len > 0 and std.mem.eql(u8, gate, scope)) continue;
        try appendUniqueJsonString(allocator, &out, &count, gate);
    }

    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
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
    if (requested_scope != null) return agentMemoryPermissionsJson(allocator, requested_permissions_json);
    if (!permissionsOpen(requested_permissions_json)) return agentMemoryPermissionsJson(allocator, requested_permissions_json);
    return domain.actorGrantJson(allocator, actor_id);
}

fn agentMemoryPermissionsJson(allocator: std.mem.Allocator, requested_permissions_json: []const u8) ![]const u8 {
    return canonicalPermissionsJson(allocator, requested_permissions_json) catch |err| switch (err) {
        error.InvalidPermissionsJson => error.InvalidRawJson,
        else => err,
    };
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
    const a_open = permissionsOpen(a_json);
    const b_open = permissionsOpen(b_json);
    if (a_open and b_open) return allocator.dupe(u8, "[]");
    if (a_open) return canonicalPermissionsJson(allocator, b_json);
    if (b_open) return canonicalPermissionsJson(allocator, a_json);

    return combinedRestrictedPermissionsJson(allocator, a_json, b_json);
}

fn canonicalPermissionsJson(allocator: std.mem.Allocator, permissions_json: []const u8) ![]const u8 {
    if (permissionsOpen(permissions_json)) return allocator.dupe(u8, "[]");

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, permissions_json, .{}) catch return error.InvalidPermissionsJson;
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidPermissionsJson;

    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '[');
    var count: usize = 0;
    try appendPermissionJsonItems(allocator, &out, &count, &seen, parsed.value.array.items);
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

fn combinedRestrictedPermissionsJson(allocator: std.mem.Allocator, a_json: []const u8, b_json: []const u8) ![]const u8 {
    var parsed_a = std.json.parseFromSlice(std.json.Value, allocator, a_json, .{}) catch return error.InvalidPermissionsJson;
    defer parsed_a.deinit();
    if (parsed_a.value != .array) return error.InvalidPermissionsJson;

    var parsed_b = std.json.parseFromSlice(std.json.Value, allocator, b_json, .{}) catch return error.InvalidPermissionsJson;
    defer parsed_b.deinit();
    if (parsed_b.value != .array) return error.InvalidPermissionsJson;

    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '[');
    var count: usize = 0;
    try appendPermissionJsonItems(allocator, &out, &count, &seen, parsed_a.value.array.items);
    try appendPermissionJsonItems(allocator, &out, &count, &seen, parsed_b.value.array.items);
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

fn appendPermissionJsonItems(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), count: *usize, seen: *std.StringHashMap(void), items: []const std.json.Value) !void {
    for (items) |item| {
        if (item != .string) return error.InvalidPermissionsJson;
        const exists = try seen.getOrPut(item.string);
        if (exists.found_existing) continue;
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
    try std.testing.expect(scopeCoversTarget("public", "project:nullpantry"));
    try std.testing.expect(scopeCoversTarget("project:nullpantry", "project:nullpantry"));
    try std.testing.expect(!scopeCoversTarget("project:nullpantry", "public"));
    try std.testing.expect(!scopeCoversTarget("project:secret", "project:nullpantry"));
    try std.testing.expect(permissionsCoverTarget(alloc, "[]", "[\"team:secret\"]"));
    try std.testing.expect(permissionsCoverTarget(alloc, "[\"team:secret\",\"team:platform\"]", "[\"team:secret\"]"));
    try std.testing.expect(!permissionsCoverTarget(alloc, "[\"team:secret\"]", "[]"));
    try std.testing.expect(!permissionsCoverTarget(alloc, "[\"team:secret\"]", "[\"team:platform\"]"));
    try std.testing.expect(!permissionsOpen("[\"public\",\"team:secret\"]"));
    try std.testing.expect(permissionsCoverTarget(alloc, "[\"public\",\"team:secret\"]", "[\"team:platform\"]"));
    try std.testing.expect(!permissionsCoverTarget(alloc, "[\"team:secret\"]", "[\"public\",\"team:platform\"]"));

    try std.testing.expect(aclCoversTarget(alloc, "public", "[]", "project:nullpantry", "[]"));
    try std.testing.expect(!aclCoversTarget(alloc, "project:secret", "[\"team:secret\"]", "public", "[]"));
    try std.testing.expect(!aclCoversTarget(alloc, "project:secret", "[\"team:secret\"]", "project:secret", "[\"public\"]"));
    try std.testing.expect(aclCoversTarget(alloc, "project:secret", "[\"team:secret\",\"team:platform\"]", "project:secret", "[\"team:secret\"]"));
}

test "access empty required scopes are visible for already-public context packs" {
    try std.testing.expect(requiredScopesVisible("[]", "[\"public\"]"));
    try std.testing.expect(requiredScopesVisible("", "[\"public\"]"));
}

test "access derives scope from required scopes fail closed" {
    const allocator = std.testing.allocator;

    const empty_scope = try scopeFromRequiredScopesJson(allocator, "[]");
    defer allocator.free(empty_scope);
    try std.testing.expectEqualStrings("public", empty_scope);

    const project_scope = try scopeFromRequiredScopesJson(allocator, "[\"public\",\"project:nullpantry\"]");
    defer allocator.free(project_scope);
    try std.testing.expectEqualStrings("project:nullpantry", project_scope);

    const not_json = try scopeFromRequiredScopesJson(allocator, "not-json");
    defer allocator.free(not_json);
    try std.testing.expectEqualStrings(malformed_required_scopes_gate, not_json);

    const object_json = try scopeFromRequiredScopesJson(allocator, "{\"scope\":\"public\"}");
    defer allocator.free(object_json);
    try std.testing.expectEqualStrings(malformed_required_scopes_gate, object_json);

    const mixed_array = try scopeFromRequiredScopesJson(allocator, "[\"public\",42]");
    defer allocator.free(mixed_array);
    try std.testing.expectEqualStrings(malformed_required_scopes_gate, mixed_array);

    const trailing_malformed = try scopeFromRequiredScopesJson(allocator, "[\"project:nullpantry\",42]");
    defer allocator.free(trailing_malformed);
    try std.testing.expectEqualStrings(malformed_required_scopes_gate, trailing_malformed);

    const empty_gate = try scopeFromRequiredScopesJson(allocator, "[\"\"]");
    defer allocator.free(empty_gate);
    try std.testing.expectEqualStrings(malformed_required_scopes_gate, empty_gate);
}

test "access required gates fail closed for malformed permissions json" {
    const allocator = std.testing.allocator;

    const not_json = try requiredAccessJsonForActor(allocator, "public", "not-json", null);
    defer allocator.free(not_json);
    try std.testing.expect(std.mem.indexOf(u8, not_json, malformed_permissions_required_gate) != null);
    try std.testing.expect(!requiredScopesVisible(not_json, "[\"public\"]"));
    try std.testing.expect(requiredScopesVisible(not_json, "[\"admin\"]"));

    const object_json = try requiredAccessJsonForActor(allocator, "public", "{\"permission\":\"public\"}", null);
    defer allocator.free(object_json);
    try std.testing.expect(std.mem.indexOf(u8, object_json, malformed_permissions_required_gate) != null);
    try std.testing.expect(!requiredScopesVisible(object_json, "[\"public\"]"));

    const mixed_array = try requiredAccessJsonForActor(allocator, "public", "[\"public\",42]", null);
    defer allocator.free(mixed_array);
    try std.testing.expect(std.mem.indexOf(u8, mixed_array, malformed_permissions_required_gate) != null);
    try std.testing.expect(!requiredScopesVisible(mixed_array, "[\"public\"]"));

    const empty_gate = try requiredAccessJsonForActor(allocator, "public", "[\"\"]", null);
    defer allocator.free(empty_gate);
    try std.testing.expect(std.mem.indexOf(u8, empty_gate, malformed_permissions_required_gate) != null);
    try std.testing.expect(!requiredScopesVisible(empty_gate, "[\"public\"]"));
}

test "access required gates omit the current actor private grant" {
    const allocator = std.testing.allocator;
    const permissions = try domain.actorGrantJson(allocator, "agent:a");
    defer allocator.free(permissions);

    const required = try requiredAccessJsonForActor(allocator, "agent:agent:a", permissions, "agent:a");
    defer allocator.free(required);
    try std.testing.expectEqualStrings("[]", required);
}

test "access derives permissions from required access without duplicating scope" {
    const allocator = std.testing.allocator;

    const permissions = try permissionsJsonFromRequiredAccessJson(allocator, "project:secret", "[\"project:secret\",\"team:secret\",\"team:secret\"]");
    defer allocator.free(permissions);
    try std.testing.expectEqualStrings("[\"team:secret\"]", permissions);

    const scope_only = try permissionsJsonFromRequiredAccessJson(allocator, "project:secret", "[\"project:secret\"]");
    defer allocator.free(scope_only);
    try std.testing.expectEqualStrings("[]", scope_only);

    const malformed = try permissionsJsonFromRequiredAccessJson(allocator, "project:secret", "{\"scope\":\"project:secret\"}");
    defer allocator.free(malformed);
    try std.testing.expect(std.mem.indexOf(u8, malformed, malformed_required_access_gate) != null);
    try std.testing.expect(!permissionsVisibleForActor(allocator, malformed, "[\"project:secret\"]", null));

    const empty_gate = try permissionsJsonFromRequiredAccessJson(allocator, "project:secret", "[\"\"]");
    defer allocator.free(empty_gate);
    try std.testing.expect(std.mem.indexOf(u8, empty_gate, malformed_required_access_gate) != null);
    try std.testing.expect(!permissionsVisibleForActor(allocator, empty_gate, "[\"project:secret\"]", null));
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

    const mixed_public = try agentMemoryPermissions(alloc, "agent:a", null, "[\"public\",\"team:a\"]");
    defer alloc.free(mixed_public);
    try std.testing.expectEqualStrings("[\"public\",\"team:a\"]", mixed_public);

    try std.testing.expectError(error.InvalidRawJson, agentMemoryPermissions(alloc, "agent:a", "project:nullpantry", "{\"scope\":\"public\"}"));
    try std.testing.expectError(error.InvalidRawJson, agentMemoryPermissions(alloc, "agent:a", null, "[\"public\",]"));
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

    const open = try combinedPermissionsJson(std.testing.allocator, "[\"public\"]", "[]");
    defer std.testing.allocator.free(open);
    try std.testing.expectEqualStrings("[]", open);

    const narrowed = try combinedPermissionsJson(std.testing.allocator, "[]", "[\"team:b\",\"team:b\"]");
    defer std.testing.allocator.free(narrowed);
    try std.testing.expectEqualStrings("[\"team:b\"]", narrowed);

    const mixed_public = try combinedPermissionsJson(std.testing.allocator, "[]", "[\"public\",\"team:b\",\"team:b\"]");
    defer std.testing.allocator.free(mixed_public);
    try std.testing.expectEqualStrings("[\"public\",\"team:b\"]", mixed_public);

    const escaped = try combinedPermissionsJson(std.testing.allocator, "[\"team:\\u0041\",\"actor:agent:\\\"a\"]", "[\"team:A\",\"actor:agent:\\\"a\"]");
    defer std.testing.allocator.free(escaped);
    try std.testing.expectEqualStrings("[\"team:A\",\"actor:agent:\\\"a\"]", escaped);

    try std.testing.expectError(error.InvalidPermissionsJson, combinedPermissionsJson(std.testing.allocator, "{\"permission\":\"team:a\"}", "[\"team:a\"]"));
    try std.testing.expectError(error.InvalidPermissionsJson, combinedPermissionsJson(std.testing.allocator, "[\"team:a\",42]", "[\"team:b\"]"));
    try std.testing.expectError(error.InvalidPermissionsJson, combinedPermissionsJson(std.testing.allocator, "[]", "not-json"));
}
