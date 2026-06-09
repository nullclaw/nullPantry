const std = @import("std");

const access = @import("access.zig");
const domain = @import("domain.zig");
const json = @import("json_util.zig");
const net_security = @import("net_security.zig");

pub const VisibleOwners = struct {
    owners: std.ArrayListUnmanaged([]u8) = .empty,
    requires_global_scan: bool = false,

    pub fn deinit(self: *VisibleOwners, allocator: std.mem.Allocator) void {
        for (self.owners.items) |owner| allocator.free(owner);
        self.owners.deinit(allocator);
    }

    fn appendOwned(self: *VisibleOwners, allocator: std.mem.Allocator, owner: []const u8) !void {
        for (self.owners.items) |existing| {
            if (std.mem.eql(u8, existing, owner)) return;
        }
        try self.owners.append(allocator, try allocator.dupe(u8, owner));
    }

    fn appendSharedScope(self: *VisibleOwners, allocator: std.mem.Allocator, scope: []const u8) !void {
        const owner = try access.sharedAgentMemoryOwner(allocator, scope);
        defer allocator.free(owner);
        try self.appendOwned(allocator, owner);
    }
};

pub fn visibleOwners(allocator: std.mem.Allocator, actor_id: []const u8, scopes_json: []const u8) !VisibleOwners {
    var result = VisibleOwners{};
    errdefer result.deinit(allocator);
    try result.appendOwned(allocator, actor_id);
    try result.appendSharedScope(allocator, "public");
    if (domain.hasActorScope(scopes_json, "admin")) {
        result.requires_global_scan = true;
        return result;
    }

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, scopes_json, .{}) catch {
        result.requires_global_scan = true;
        return result;
    };
    defer parsed.deinit();
    if (parsed.value != .array) return result;
    for (parsed.value.array.items) |item| {
        if (item != .string) continue;
        const scope = item.string;
        if (scope.len == 0) continue;
        if (std.mem.eql(u8, scope, "admin") or std.mem.eql(u8, scope, "*") or std.mem.endsWith(u8, scope, ":*")) {
            result.requires_global_scan = true;
            return result;
        }
        if (std.mem.startsWith(u8, scope, "write:") or
            std.mem.startsWith(u8, scope, "verify:") or
            std.mem.startsWith(u8, scope, "delete:") or
            std.mem.startsWith(u8, scope, "actor:") or
            domain.isActorOwnedAgentMemoryScope(scope, actor_id))
        {
            continue;
        }
        try result.appendSharedScope(allocator, scope);
    }
    return result;
}

pub fn entryVisible(allocator: std.mem.Allocator, entry: domain.AgentMemory, actor_id: []const u8, scopes_json: []const u8) !bool {
    const record_visible = domain.scopeVisible(entry.scope, scopes_json) and
        access.permissionsVisibleForActor(allocator, entry.permissions_json, scopes_json, actor_id);
    return access.agentMemoryVisible(allocator, .{
        .owner_actor_id = entry.actor_id,
        .scope = entry.scope,
        .permissions_json = entry.permissions_json,
        .session_id = entry.session_id,
        .request_actor_id = actor_id,
        .request_scopes_json = scopes_json,
        .record_visible = record_visible,
        .session_visible = if (entry.session_id) |sid| access.sessionVisibleForScopes(allocator, sid, scopes_json) else true,
    });
}

pub fn sharedScopeFromOwner(owner_actor_id: []const u8) ?[]const u8 {
    const prefix = "shared:";
    if (!std.mem.startsWith(u8, owner_actor_id, prefix)) return null;
    return owner_actor_id[prefix.len..];
}

pub fn stringishField(obj: std.json.ObjectMap, names: []const []const u8) ?[]const u8 {
    for (names) |name| {
        const value = obj.get(name) orelse continue;
        switch (value) {
            .string => |s| return s,
            else => continue,
        }
    }
    return null;
}

pub fn nullableStringishField(obj: std.json.ObjectMap, names: []const []const u8) ?[]const u8 {
    for (names) |name| {
        const value = obj.get(name) orelse continue;
        switch (value) {
            .string => |s| return s,
            .null => return null,
            else => continue,
        }
    }
    return null;
}

pub fn objectField(obj: std.json.ObjectMap, names: []const []const u8) ?std.json.ObjectMap {
    for (names) |name| {
        const value = obj.get(name) orelse continue;
        if (value == .object) return value.object;
    }
    return null;
}

pub fn hasNonNullField(obj: std.json.ObjectMap, names: []const []const u8) bool {
    for (names) |name| {
        const value = obj.get(name) orelse continue;
        if (value != .null) return true;
    }
    return false;
}

pub fn rawJsonField(allocator: std.mem.Allocator, obj: std.json.ObjectMap, names: []const []const u8, fallback: []const u8) ![]u8 {
    for (names) |name| {
        const value = obj.get(name) orelse continue;
        if (value == .null) continue;
        return try json.rawJsonFieldValue(allocator, name, value, fallback);
    }
    return json.rawJsonFieldFallback(allocator, if (names.len > 0) names[0] else "", fallback);
}

pub fn rawJsonArrayField(allocator: std.mem.Allocator, obj: std.json.ObjectMap, names: []const []const u8, fallback: []const u8) ![]u8 {
    return rawJsonFieldWithRoot(allocator, obj, names, fallback, .array);
}

fn rawJsonFieldWithRoot(allocator: std.mem.Allocator, obj: std.json.ObjectMap, names: []const []const u8, fallback: []const u8, root: json.RawJsonRoot) ![]u8 {
    const raw = try rawJsonField(allocator, obj, names, fallback);
    errdefer allocator.free(raw);
    if (!json.rawJsonRootIs(allocator, raw, root)) return error.InvalidRawJson;
    return raw;
}

pub fn permissionsJsonField(allocator: std.mem.Allocator, obj: std.json.ObjectMap, fallback: []const u8) ![]u8 {
    return rawJsonArrayField(allocator, obj, &.{ "nullpantry_permissions_json", "permissions_json", "nullpantry_permissions", "permissions" }, fallback);
}

pub fn optionalI64Field(obj: std.json.ObjectMap, name: []const u8) ?i64 {
    const value = obj.get(name) orelse return null;
    return switch (value) {
        .integer => |n| n,
        .float => |f| json.safeFloatToI64(f),
        .string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

pub fn i64Field(obj: std.json.ObjectMap, name: []const u8, fallback: i64) i64 {
    return optionalI64Field(obj, name) orelse fallback;
}

pub fn valueAsF64(value: std.json.Value) ?f64 {
    return switch (value) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => null,
    };
}

pub fn sameOptionalString(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

pub fn sanitizeSegment(allocator: std.mem.Allocator, raw: []const u8, max_len: usize, fallback: []const u8) ![]u8 {
    if (raw.len == 0) return allocator.dupe(u8, fallback);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    const capped = @max(max_len, 1);
    for (raw) |ch| {
        if (out.items.len >= capped) break;
        try out.append(allocator, if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-') ch else '_');
    }
    if (out.items.len == 0) {
        out.deinit(allocator);
        return allocator.dupe(u8, fallback);
    }
    return out.toOwnedSlice(allocator);
}

pub fn percentEncode(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    return net_security.percentEncodePathSegment(allocator, raw);
}

pub const HttpUrlOptions = struct {
    version_prefix: ?[]const u8 = null,
    strip_base_suffixes: []const []const u8 = &.{},
    allow_insecure_http: bool = false,
};

pub fn httpUrl(allocator: std.mem.Allocator, base_url: []const u8, path: []const u8, query: []const u8, options: HttpUrlOptions) ![]u8 {
    try net_security.validateHttpBaseUrl(base_url, options.allow_insecure_http);
    var end = base_url.len;
    while (end > 0 and base_url[end - 1] == '/') : (end -= 1) {}
    var trimmed = base_url[0..end];
    for (options.strip_base_suffixes) |suffix| {
        if (suffix.len > 0 and std.mem.endsWith(u8, trimmed, suffix)) {
            trimmed = trimmed[0 .. trimmed.len - suffix.len];
            break;
        }
    }

    const prefix = if (options.version_prefix) |version| if (std.mem.endsWith(u8, trimmed, version)) "" else version else "";
    const separator = if (path.len > 0 and path[0] == '/') "" else "/";
    var suffix: std.ArrayListUnmanaged(u8) = .empty;
    defer suffix.deinit(allocator);
    try suffix.appendSlice(allocator, prefix);
    try suffix.appendSlice(allocator, separator);
    try suffix.appendSlice(allocator, path);
    if (query.len > 0) {
        try suffix.append(allocator, '?');
        try suffix.appendSlice(allocator, query);
    }
    return net_security.joinHttpBaseUrl(allocator, trimmed, suffix.items, options.allow_insecure_http);
}

pub fn detachAgentMemory(entry: *domain.AgentMemory) void {
    entry.id = "";
    entry.key = "";
    entry.content = "";
    entry.category = "";
    entry.timestamp = "";
    entry.session_id = null;
    entry.actor_id = "";
    entry.writer_actor_id = "";
    entry.scope = "";
    entry.permissions_json = "";
    entry.status = "";
    entry.store = "";
}

pub fn freeAgentMemory(allocator: std.mem.Allocator, entry: *domain.AgentMemory) void {
    if (entry.id.len > 0) allocator.free(entry.id);
    if (entry.key.len > 0) allocator.free(entry.key);
    if (entry.content.len > 0) allocator.free(entry.content);
    if (entry.category.len > 0) allocator.free(entry.category);
    if (entry.timestamp.len > 0) allocator.free(entry.timestamp);
    if (entry.session_id) |sid| allocator.free(sid);
    if (entry.actor_id.len > 0) allocator.free(entry.actor_id);
    if (entry.writer_actor_id.len > 0) allocator.free(entry.writer_actor_id);
    if (entry.scope.len > 0) allocator.free(entry.scope);
    if (entry.permissions_json.len > 0) allocator.free(entry.permissions_json);
    if (entry.status.len > 0) allocator.free(entry.status);
    if (entry.store.len > 0) allocator.free(entry.store);
    detachAgentMemory(entry);
}

test "vendor visible owners keeps private actor and shared scopes separate" {
    var owners = try visibleOwners(std.testing.allocator, "agent:a", "[\"agent:agent:a\",\"team:alpha\",\"project:nullpantry\",\"write:team:alpha\"]");
    defer owners.deinit(std.testing.allocator);

    try std.testing.expect(!owners.requires_global_scan);
    try std.testing.expectEqual(@as(usize, 4), owners.owners.items.len);
    try std.testing.expectEqualStrings("agent:a", owners.owners.items[0]);
    try std.testing.expectEqualStrings("shared:public", owners.owners.items[1]);
    try std.testing.expectEqualStrings("shared:team:alpha", owners.owners.items[2]);
    try std.testing.expectEqualStrings("shared:project:nullpantry", owners.owners.items[3]);
}

test "vendor integer fields reject unsafe floats" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"exact\":42.0,\"fractional\":42.5,\"huge\":1e100,\"integer\":7,\"text\":\"9\"}",
        .{},
    );
    defer parsed.deinit();

    try std.testing.expectEqual(@as(?i64, 42), optionalI64Field(parsed.value.object, "exact"));
    try std.testing.expectEqual(@as(?i64, 7), optionalI64Field(parsed.value.object, "integer"));
    try std.testing.expectEqual(@as(?i64, 9), optionalI64Field(parsed.value.object, "text"));
    try std.testing.expect(optionalI64Field(parsed.value.object, "fractional") == null);
    try std.testing.expect(optionalI64Field(parsed.value.object, "huge") == null);
}

test "vendor raw JSON aliases reject invalid permissions strings" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"nullpantry_permissions\":null,\"permissions_json\":\"[\\\"public\\\"]\",\"nullpantry_permissions_json\":\"[\\\"team:alpha\\\",]\",\"permissions\":[\"fallback\"],\"bad_permissions\":{\"scope\":\"public\"}}",
        .{},
    );
    defer parsed.deinit();
    const obj = parsed.value.object;

    try std.testing.expect(!hasNonNullField(obj, &.{"nullpantry_permissions"}));
    try std.testing.expect(hasNonNullField(obj, &.{"permissions_json"}));

    try std.testing.expectError(error.InvalidRawJson, rawJsonField(std.testing.allocator, obj, &.{"nullpantry_permissions_json"}, "[]"));

    const permissions = try rawJsonArrayField(std.testing.allocator, obj, &.{ "nullpantry_permissions", "permissions_json" }, "[]");
    defer std.testing.allocator.free(permissions);
    try std.testing.expectEqualStrings("[\"public\"]", permissions);

    try std.testing.expectError(error.InvalidRawJson, rawJsonArrayField(std.testing.allocator, obj, &.{ "nullpantry_permissions", "nullpantry_permissions_json" }, "[]"));
    try std.testing.expectError(error.InvalidRawJson, rawJsonArrayField(std.testing.allocator, obj, &.{"bad_permissions"}, "[]"));
    try std.testing.expectError(error.InvalidRawJson, permissionsJsonField(std.testing.allocator, obj, "[]"));
}

test "vendor HTTP URLs share runtime base URL policy" {
    const versioned = try httpUrl(std.testing.allocator, "https://api.example/v1///", "/memory/search", "limit=1", .{
        .version_prefix = "/v1",
    });
    defer std.testing.allocator.free(versioned);
    try std.testing.expectEqualStrings("https://api.example/v1/memory/search?limit=1", versioned);

    const stripped = try httpUrl(std.testing.allocator, "https://api.example/v3/", "/v1/memories", "", .{
        .strip_base_suffixes = &.{ "/v3", "/v1" },
    });
    defer std.testing.allocator.free(stripped);
    try std.testing.expectEqualStrings("https://api.example/v1/memories", stripped);

    try std.testing.expectError(error.InvalidRuntimeUrl, httpUrl(std.testing.allocator, "https://token@api.example", "/memory/search", "", .{}));
    try std.testing.expectError(error.InvalidRuntimeUrl, httpUrl(std.testing.allocator, "https://api.example?token=x", "/memory/search", "", .{}));
    try std.testing.expectError(error.InsecureRuntimeUrl, httpUrl(std.testing.allocator, "http://api.internal", "/memory/search", "", .{}));

    const insecure = try httpUrl(std.testing.allocator, "http://api.internal", "/memory/search", "", .{
        .allow_insecure_http = true,
    });
    defer std.testing.allocator.free(insecure);
    try std.testing.expectEqualStrings("http://api.internal/memory/search", insecure);
}
