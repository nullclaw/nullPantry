const std = @import("std");
const json = @import("json_util.zig");

pub const Source = struct {
    id: []const u8,
    source_type: []const u8,
    title: []const u8,
    raw_content_uri: ?[]const u8 = null,
    content: []const u8 = "",
    author: ?[]const u8 = null,
    participants_json: []const u8 = "[]",
    permissions_json: []const u8 = "[]",
    scope: []const u8 = "workspace",
    created_at_ms: i64,
    imported_at_ms: i64,
    checksum: ?[]const u8 = null,
    language: ?[]const u8 = null,
    related_entities_json: []const u8 = "[]",
    metadata_json: []const u8 = "{}",

    pub fn writeJson(self: Source, allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
        try out.appendSlice(allocator, "{\"id\":");
        try json.appendString(out, allocator, self.id);
        try out.appendSlice(allocator, ",\"type\":");
        try json.appendString(out, allocator, self.source_type);
        try out.appendSlice(allocator, ",\"title\":");
        try json.appendString(out, allocator, self.title);
        try out.appendSlice(allocator, ",\"raw_content_uri\":");
        try json.appendNullableString(out, allocator, self.raw_content_uri);
        try out.appendSlice(allocator, ",\"content\":");
        try json.appendString(out, allocator, self.content);
        try out.appendSlice(allocator, ",\"author\":");
        try json.appendNullableString(out, allocator, self.author);
        try out.appendSlice(allocator, ",\"participants\":");
        try json.appendRawJsonOr(out, allocator, self.participants_json, "[]");
        try out.appendSlice(allocator, ",\"permissions\":");
        try json.appendRawJsonOr(out, allocator, self.permissions_json, "[]");
        try out.appendSlice(allocator, ",\"scope\":");
        try json.appendString(out, allocator, self.scope);
        try out.print(allocator, ",\"created_at_ms\":{d},\"imported_at_ms\":{d}", .{ self.created_at_ms, self.imported_at_ms });
        try out.appendSlice(allocator, ",\"checksum\":");
        try json.appendNullableString(out, allocator, self.checksum);
        try out.appendSlice(allocator, ",\"language\":");
        try json.appendNullableString(out, allocator, self.language);
        try out.appendSlice(allocator, ",\"related_entities\":");
        try json.appendRawJsonOr(out, allocator, self.related_entities_json, "[]");
        try out.appendSlice(allocator, ",\"metadata\":");
        try json.appendRawJsonOr(out, allocator, self.metadata_json, "{}");
        try out.append(allocator, '}');
    }
};

pub const Artifact = struct {
    id: []const u8,
    artifact_type: []const u8,
    title: []const u8,
    body: []const u8,
    status: []const u8,
    owner: ?[]const u8,
    space_id: ?[]const u8,
    version: i64,
    created_at_ms: i64,
    updated_at_ms: i64,
    last_verified_at_ms: ?i64,
    scope: []const u8,
    source_ids_json: []const u8,
    related_entities_json: []const u8,
    permissions_json: []const u8,
    summary: ?[]const u8,
    agent_summary: ?[]const u8,

    pub fn writeJson(self: Artifact, allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
        try out.appendSlice(allocator, "{\"id\":");
        try json.appendString(out, allocator, self.id);
        try out.appendSlice(allocator, ",\"type\":");
        try json.appendString(out, allocator, self.artifact_type);
        try out.appendSlice(allocator, ",\"title\":");
        try json.appendString(out, allocator, self.title);
        try out.appendSlice(allocator, ",\"body\":");
        try json.appendString(out, allocator, self.body);
        try out.appendSlice(allocator, ",\"status\":");
        try json.appendString(out, allocator, self.status);
        try out.appendSlice(allocator, ",\"owner\":");
        try json.appendNullableString(out, allocator, self.owner);
        try out.appendSlice(allocator, ",\"space_id\":");
        try json.appendNullableString(out, allocator, self.space_id);
        try out.print(allocator, ",\"version\":{d},\"created_at_ms\":{d},\"updated_at_ms\":{d}", .{ self.version, self.created_at_ms, self.updated_at_ms });
        try out.appendSlice(allocator, ",\"last_verified_at_ms\":");
        if (self.last_verified_at_ms) |v| try out.print(allocator, "{d}", .{v}) else try out.appendSlice(allocator, "null");
        try out.appendSlice(allocator, ",\"scope\":");
        try json.appendString(out, allocator, self.scope);
        try out.appendSlice(allocator, ",\"source_ids\":");
        try json.appendRawJsonOr(out, allocator, self.source_ids_json, "[]");
        try out.appendSlice(allocator, ",\"related_entities\":");
        try json.appendRawJsonOr(out, allocator, self.related_entities_json, "[]");
        try out.appendSlice(allocator, ",\"permissions\":");
        try json.appendRawJsonOr(out, allocator, self.permissions_json, "[]");
        try out.appendSlice(allocator, ",\"summary\":");
        try json.appendNullableString(out, allocator, self.summary);
        try out.appendSlice(allocator, ",\"agent_summary\":");
        try json.appendNullableString(out, allocator, self.agent_summary);
        try out.append(allocator, '}');
    }
};

pub const MemoryAtom = struct {
    id: []const u8,
    subject_entity_id: ?[]const u8,
    predicate: []const u8,
    object: []const u8,
    text: []const u8,
    scope: []const u8,
    confidence: f64,
    status: []const u8,
    source_ids_json: []const u8,
    evidence_ranges_json: []const u8,
    created_by: []const u8,
    created_at_ms: i64,
    valid_from_ms: ?i64,
    valid_until_ms: ?i64,
    last_verified_at_ms: ?i64,
    owner: ?[]const u8,
    permissions_json: []const u8,
    tags_json: []const u8,

    pub fn writeJson(self: MemoryAtom, allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
        try out.appendSlice(allocator, "{\"id\":");
        try json.appendString(out, allocator, self.id);
        try out.appendSlice(allocator, ",\"subject_entity_id\":");
        try json.appendNullableString(out, allocator, self.subject_entity_id);
        try out.appendSlice(allocator, ",\"predicate\":");
        try json.appendString(out, allocator, self.predicate);
        try out.appendSlice(allocator, ",\"object\":");
        try json.appendString(out, allocator, self.object);
        try out.appendSlice(allocator, ",\"text\":");
        try json.appendString(out, allocator, self.text);
        try out.appendSlice(allocator, ",\"scope\":");
        try json.appendString(out, allocator, self.scope);
        try out.print(allocator, ",\"confidence\":{d}", .{self.confidence});
        try out.appendSlice(allocator, ",\"status\":");
        try json.appendString(out, allocator, self.status);
        try out.appendSlice(allocator, ",\"source_ids\":");
        try json.appendRawJsonOr(out, allocator, self.source_ids_json, "[]");
        try out.appendSlice(allocator, ",\"evidence_ranges\":");
        try json.appendRawJsonOr(out, allocator, self.evidence_ranges_json, "[]");
        try out.appendSlice(allocator, ",\"created_by\":");
        try json.appendString(out, allocator, self.created_by);
        try out.print(allocator, ",\"created_at_ms\":{d}", .{self.created_at_ms});
        try appendOptionalInt(allocator, out, "valid_from_ms", self.valid_from_ms);
        try appendOptionalInt(allocator, out, "valid_until_ms", self.valid_until_ms);
        try appendOptionalInt(allocator, out, "last_verified_at_ms", self.last_verified_at_ms);
        try out.appendSlice(allocator, ",\"owner\":");
        try json.appendNullableString(out, allocator, self.owner);
        try out.appendSlice(allocator, ",\"permissions\":");
        try json.appendRawJsonOr(out, allocator, self.permissions_json, "[]");
        try out.appendSlice(allocator, ",\"tags\":");
        try json.appendRawJsonOr(out, allocator, self.tags_json, "[]");
        try out.append(allocator, '}');
    }
};

pub const Entity = struct {
    id: []const u8,
    entity_type: []const u8,
    name: []const u8,
    aliases_json: []const u8,
    description: ?[]const u8,
    canonical_artifact_id: ?[]const u8,
    scope: []const u8,
    permissions_json: []const u8,
    metadata_json: []const u8,
    created_at_ms: i64,
    updated_at_ms: i64,

    pub fn writeJson(self: Entity, allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
        try out.appendSlice(allocator, "{\"id\":");
        try json.appendString(out, allocator, self.id);
        try out.appendSlice(allocator, ",\"type\":");
        try json.appendString(out, allocator, self.entity_type);
        try out.appendSlice(allocator, ",\"name\":");
        try json.appendString(out, allocator, self.name);
        try out.appendSlice(allocator, ",\"aliases\":");
        try json.appendRawJsonOr(out, allocator, self.aliases_json, "[]");
        try out.appendSlice(allocator, ",\"description\":");
        try json.appendNullableString(out, allocator, self.description);
        try out.appendSlice(allocator, ",\"canonical_artifact_id\":");
        try json.appendNullableString(out, allocator, self.canonical_artifact_id);
        try out.appendSlice(allocator, ",\"scope\":");
        try json.appendString(out, allocator, self.scope);
        try out.appendSlice(allocator, ",\"permissions\":");
        try json.appendRawJsonOr(out, allocator, self.permissions_json, "[]");
        try out.appendSlice(allocator, ",\"metadata\":");
        try json.appendRawJsonOr(out, allocator, self.metadata_json, "{}");
        try out.print(allocator, ",\"created_at_ms\":{d},\"updated_at_ms\":{d}}}", .{ self.created_at_ms, self.updated_at_ms });
    }
};

pub const Relation = struct {
    id: []const u8,
    from_entity_id: []const u8,
    relation_type: []const u8,
    to_entity_id: []const u8,
    source_ids_json: []const u8,
    scope: []const u8,
    permissions_json: []const u8,
    confidence: f64,
    status: []const u8,
    created_at_ms: i64,

    pub fn writeJson(self: Relation, allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
        try out.appendSlice(allocator, "{\"id\":");
        try json.appendString(out, allocator, self.id);
        try out.appendSlice(allocator, ",\"from_entity_id\":");
        try json.appendString(out, allocator, self.from_entity_id);
        try out.appendSlice(allocator, ",\"relation_type\":");
        try json.appendString(out, allocator, self.relation_type);
        try out.appendSlice(allocator, ",\"to_entity_id\":");
        try json.appendString(out, allocator, self.to_entity_id);
        try out.appendSlice(allocator, ",\"source_ids\":");
        try json.appendRawJsonOr(out, allocator, self.source_ids_json, "[]");
        try out.appendSlice(allocator, ",\"scope\":");
        try json.appendString(out, allocator, self.scope);
        try out.appendSlice(allocator, ",\"permissions\":");
        try json.appendRawJsonOr(out, allocator, self.permissions_json, "[]");
        try out.print(allocator, ",\"confidence\":{d}", .{self.confidence});
        try out.appendSlice(allocator, ",\"status\":");
        try json.appendString(out, allocator, self.status);
        try out.print(allocator, ",\"created_at_ms\":{d}}}", .{self.created_at_ms});
    }
};

pub const SearchResult = struct {
    id: []const u8,
    result_type: []const u8,
    title: []const u8,
    text: []const u8,
    scope: []const u8,
    status: []const u8,
    score: f64,
    source_ids_json: []const u8,
    created_at_ms: i64 = 0,
    confidence: f64 = 0.5,

    pub fn writeJson(self: SearchResult, allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
        try out.appendSlice(allocator, "{\"id\":");
        try json.appendString(out, allocator, self.id);
        try out.appendSlice(allocator, ",\"type\":");
        try json.appendString(out, allocator, self.result_type);
        try out.appendSlice(allocator, ",\"title\":");
        try json.appendString(out, allocator, self.title);
        try out.appendSlice(allocator, ",\"text\":");
        try json.appendString(out, allocator, self.text);
        try out.appendSlice(allocator, ",\"scope\":");
        try json.appendString(out, allocator, self.scope);
        try out.appendSlice(allocator, ",\"status\":");
        try json.appendString(out, allocator, self.status);
        try out.print(allocator, ",\"score\":{d},\"created_at_ms\":{d},\"confidence\":{d},\"citations\":", .{ self.score, self.created_at_ms, self.confidence });
        try json.appendRawJsonOr(out, allocator, self.source_ids_json, "[]");
        try out.append(allocator, '}');
    }
};

pub const CompatMemory = struct {
    id: []const u8,
    key: []const u8,
    content: []const u8,
    category: []const u8,
    timestamp: []const u8,
    session_id: ?[]const u8,
    score: ?f64 = null,

    pub fn writeJson(self: CompatMemory, allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
        try out.appendSlice(allocator, "{\"id\":");
        try json.appendString(out, allocator, self.id);
        try out.appendSlice(allocator, ",\"key\":");
        try json.appendString(out, allocator, self.key);
        try out.appendSlice(allocator, ",\"content\":");
        try json.appendString(out, allocator, self.content);
        try out.appendSlice(allocator, ",\"category\":");
        try json.appendString(out, allocator, self.category);
        try out.appendSlice(allocator, ",\"timestamp\":");
        try json.appendString(out, allocator, self.timestamp);
        try out.appendSlice(allocator, ",\"session_id\":");
        try json.appendNullableString(out, allocator, self.session_id);
        try out.appendSlice(allocator, ",\"score\":");
        if (self.score) |s| try out.print(allocator, "{d}", .{s}) else try out.appendSlice(allocator, "null");
        try out.append(allocator, '}');
    }
};

fn appendOptionalInt(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), name: []const u8, value: ?i64) !void {
    try out.appendSlice(allocator, ",\"");
    try out.appendSlice(allocator, name);
    try out.appendSlice(allocator, "\":");
    if (value) |v| try out.print(allocator, "{d}", .{v}) else try out.appendSlice(allocator, "null");
}

pub fn defaultMemoryStatus(created_by: []const u8, scope: []const u8) []const u8 {
    if (std.mem.eql(u8, created_by, "agent") and
        (std.mem.startsWith(u8, scope, "project:") or std.mem.startsWith(u8, scope, "team:") or std.mem.startsWith(u8, scope, "org:")))
    {
        return "proposed";
    }
    if (std.mem.eql(u8, created_by, "human")) return "verified";
    return "proposed";
}

pub fn isDefaultVisibleStatus(status: []const u8) bool {
    return !(std.mem.eql(u8, status, "rejected") or
        std.mem.eql(u8, status, "deprecated") or
        std.mem.eql(u8, status, "superseded"));
}

fn quotedStringContains(list_json: []const u8, value: []const u8) bool {
    var buf: [256]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "\"{s}\"", .{value}) catch return false;
    return std.mem.indexOf(u8, list_json, needle) != null;
}

pub fn hasJsonString(list_json: []const u8, value: []const u8) bool {
    return quotedStringContains(list_json, value);
}

pub fn intersectJsonStringLists(allocator: std.mem.Allocator, requested_json: []const u8, allowed_json: []const u8) ![]const u8 {
    const requested = std.mem.trim(u8, requested_json, " \t\r\n");
    if (requested.len == 0 or std.mem.eql(u8, requested, "[]")) return allocator.dupe(u8, "[]");
    if (quotedStringContains(allowed_json, "admin")) return allocator.dupe(u8, requested);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '[');
    var first = true;
    var cursor: usize = 0;
    while (nextQuotedString(requested, &cursor)) |item| {
        if (!std.mem.eql(u8, item, "public") and !scopeGrantedByList(allowed_json, item)) continue;
        if (!first) try out.append(allocator, ',');
        first = false;
        try json.appendString(&out, allocator, item);
    }
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

fn nextQuotedString(list_json: []const u8, cursor: *usize) ?[]const u8 {
    while (cursor.* < list_json.len and list_json[cursor.*] != '"') : (cursor.* += 1) {}
    if (cursor.* >= list_json.len) return null;
    const start = cursor.* + 1;
    cursor.* = start;
    while (cursor.* < list_json.len) : (cursor.* += 1) {
        if (list_json[cursor.*] == '\\') {
            cursor.* += 1;
            continue;
        }
        if (list_json[cursor.*] == '"') {
            const value = list_json[start..cursor.*];
            cursor.* += 1;
            return value;
        }
    }
    return null;
}

pub fn hasActorScope(actor_scopes_json: []const u8, scope: []const u8) bool {
    return quotedStringContains(actor_scopes_json, scope);
}

fn scopeGrantedByList(actor_scopes_json: []const u8, scope: []const u8) bool {
    if (quotedStringContains(actor_scopes_json, scope)) return true;
    var cursor: usize = 0;
    while (nextQuotedString(actor_scopes_json, &cursor)) |actor_scope| {
        if (actor_scope.len < 2 or actor_scope[actor_scope.len - 1] != '*') continue;
        const prefix = actor_scope[0 .. actor_scope.len - 1];
        if (std.mem.startsWith(u8, scope, prefix)) return true;
    }
    return false;
}

fn hasPrefixedActorScope(actor_scopes_json: []const u8, prefix: []const u8, scope: []const u8) bool {
    var cursor: usize = 0;
    while (nextQuotedString(actor_scopes_json, &cursor)) |actor_scope| {
        if (actor_scope.len == prefix.len + 1 and std.mem.startsWith(u8, actor_scope, prefix) and actor_scope[actor_scope.len - 1] == '*') return true;
        if (actor_scope.len != prefix.len + scope.len) continue;
        if (!std.mem.startsWith(u8, actor_scope, prefix)) continue;
        if (std.mem.eql(u8, actor_scope[prefix.len..], scope)) return true;
    }
    return false;
}

pub fn hasCapability(actor_scopes_json: []const u8, actor_capabilities_json: []const u8, capability: []const u8) bool {
    if (hasActorScope(actor_scopes_json, "admin")) return true;
    return quotedStringContains(actor_capabilities_json, capability);
}

pub fn permissionsVisible(permissions_json: []const u8, actor_scopes_json: []const u8) bool {
    const trimmed = std.mem.trim(u8, permissions_json, " \t\r\n");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "[]")) return true;
    if (hasActorScope(actor_scopes_json, "admin")) return true;
    if (quotedStringContains(trimmed, "public")) return true;

    var cursor: usize = 0;
    while (nextQuotedString(actor_scopes_json, &cursor)) |scope| {
        if (quotedStringContains(trimmed, scope)) return true;
    }
    return false;
}

pub fn permissionsWritable(permissions_json: []const u8, actor_scopes_json: []const u8) bool {
    const trimmed = std.mem.trim(u8, permissions_json, " \t\r\n");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "[]")) return true;
    if (hasActorScope(actor_scopes_json, "admin")) return true;

    var cursor: usize = 0;
    var saw_scope = false;
    while (nextQuotedString(trimmed, &cursor)) |scope| {
        saw_scope = true;
        if (std.mem.eql(u8, scope, "public")) continue;
        if (!hasActorScope(actor_scopes_json, scope)) return false;
    }
    return saw_scope;
}

pub fn scopeVisible(scope: []const u8, actor_scopes_json: []const u8) bool {
    if (std.mem.eql(u8, scope, "public")) return true;
    if (hasActorScope(actor_scopes_json, "admin")) return true;
    return scopeGrantedByList(actor_scopes_json, scope);
}

pub fn scopeWritable(scope: []const u8, actor_scopes_json: []const u8) bool {
    if (hasActorScope(actor_scopes_json, "admin")) return true;
    return hasPrefixedActorScope(actor_scopes_json, "write:", scope);
}

pub fn scopeVerifiable(scope: []const u8, actor_scopes_json: []const u8) bool {
    if (hasActorScope(actor_scopes_json, "admin")) return true;
    return hasPrefixedActorScope(actor_scopes_json, "verify:", scope) or scopeWritable(scope, actor_scopes_json);
}

pub fn scopeDeletable(scope: []const u8, actor_scopes_json: []const u8) bool {
    if (hasActorScope(actor_scopes_json, "admin")) return true;
    return hasPrefixedActorScope(actor_scopes_json, "delete:", scope);
}

pub fn recordVisible(scope: []const u8, permissions_json: []const u8, actor_scopes_json: []const u8) bool {
    return scopeVisible(scope, actor_scopes_json) and permissionsVisible(permissions_json, actor_scopes_json);
}

test "memory lifecycle defaults distinguish human and agent project memory" {
    try std.testing.expectEqualStrings("verified", defaultMemoryStatus("human", "project:nullpantry"));
    try std.testing.expectEqualStrings("proposed", defaultMemoryStatus("agent", "project:nullpantry"));
    try std.testing.expectEqualStrings("proposed", defaultMemoryStatus("agent", "team:platform"));
    try std.testing.expectEqualStrings("proposed", defaultMemoryStatus("agent", "org:null"));
    try std.testing.expectEqualStrings("proposed", defaultMemoryStatus("agent", "personal"));
}

test "scope and permission checks use exact grants" {
    try std.testing.expect(scopeVisible("project:nullpantry", "[\"project:nullpantry\"]"));
    try std.testing.expect(!scopeVisible("project:null", "[\"project:nullpantry\"]"));
    try std.testing.expect(scopeVisible("public", "[]"));
    try std.testing.expect(scopeVisible("session:sess_1", "[\"session:*\"]"));
    try std.testing.expect(!scopeWritable("project:nullpantry", "[\"project:nullpantry\"]"));
    try std.testing.expect(scopeWritable("project:nullpantry", "[\"project:nullpantry\",\"write:project:nullpantry\"]"));
    try std.testing.expect(scopeWritable("project:nullpantry", "[\"write:*\"]"));
    try std.testing.expect(scopeVerifiable("project:nullpantry", "[\"verify:project:nullpantry\"]"));
    try std.testing.expect(scopeDeletable("project:nullpantry", "[\"delete:project:nullpantry\"]"));
    try std.testing.expect(recordVisible("project:nullpantry", "[\"team:platform\"]", "[\"project:nullpantry\",\"team:platform\"]"));
    try std.testing.expect(!recordVisible("project:nullpantry", "[\"team:platform\"]", "[\"project:nullpantry\"]"));
    try std.testing.expect(permissionsVisible("[\"public\"]", "[]"));
    try std.testing.expect(!permissionsWritable("[\"public\",\"project:secret\"]", "[\"public\"]"));
    try std.testing.expect(permissionsWritable("[\"public\",\"project:secret\"]", "[\"project:secret\"]"));
}

test "json string list intersection prevents escalation" {
    const alloc = std.testing.allocator;
    const filtered = try intersectJsonStringLists(alloc, "[\"public\",\"project:secret\",\"project:nullpantry\"]", "[\"public\",\"project:nullpantry\"]");
    defer alloc.free(filtered);
    try std.testing.expect(std.mem.indexOf(u8, filtered, "project:nullpantry") != null);
    try std.testing.expect(std.mem.indexOf(u8, filtered, "project:secret") == null);

    const wildcard_filtered = try intersectJsonStringLists(alloc, "[\"session:sess_1\",\"session:sess_2\",\"project:secret\"]", "[\"session:*\"]");
    defer alloc.free(wildcard_filtered);
    try std.testing.expectEqualStrings("[\"session:sess_1\",\"session:sess_2\"]", wildcard_filtered);

    const admin_filtered = try intersectJsonStringLists(alloc, "[\"project:secret\"]", "[\"admin\"]");
    defer alloc.free(admin_filtered);
    try std.testing.expectEqualStrings("[\"project:secret\"]", admin_filtered);
}
