const std = @import("std");
const json = @import("json_util.zig");
const json_string_array = @import("json_string_array.zig");
const bootstrap_prompts = @import("bootstrap_prompts.zig");

pub const runtime_command_role = "__runtime_command__";

pub fn isRuntimeCommandRole(role: []const u8) bool {
    return std.mem.eql(u8, role, runtime_command_role);
}

pub fn sessionMessageVisibleInHistory(role: []const u8) bool {
    return !isRuntimeCommandRole(role);
}

pub fn isAutosaveSessionRole(role: []const u8) bool {
    return std.mem.eql(u8, role, "autosave_user") or std.mem.eql(u8, role, "autosave_assistant");
}

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
        try json.appendRawJsonArray(out, allocator, self.participants_json);
        try out.appendSlice(allocator, ",\"permissions\":");
        try json.appendRawJsonArray(out, allocator, self.permissions_json);
        try out.appendSlice(allocator, ",\"scope\":");
        try json.appendString(out, allocator, self.scope);
        try out.print(allocator, ",\"created_at_ms\":{d},\"imported_at_ms\":{d}", .{ self.created_at_ms, self.imported_at_ms });
        try out.appendSlice(allocator, ",\"checksum\":");
        try json.appendNullableString(out, allocator, self.checksum);
        try out.appendSlice(allocator, ",\"language\":");
        try json.appendNullableString(out, allocator, self.language);
        try out.appendSlice(allocator, ",\"related_entities\":");
        try json.appendRawJsonArray(out, allocator, self.related_entities_json);
        try out.appendSlice(allocator, ",\"metadata\":");
        try json.appendRawJsonObject(out, allocator, self.metadata_json);
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
    fields_json: []const u8 = "{}",
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
        try json.appendRawJsonArray(out, allocator, self.source_ids_json);
        try out.appendSlice(allocator, ",\"related_entities\":");
        try json.appendRawJsonArray(out, allocator, self.related_entities_json);
        try out.appendSlice(allocator, ",\"permissions\":");
        try json.appendRawJsonArray(out, allocator, self.permissions_json);
        try out.appendSlice(allocator, ",\"fields\":");
        try json.appendRawJsonObject(out, allocator, self.fields_json);
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
        try json.appendRawJsonArray(out, allocator, self.source_ids_json);
        try out.appendSlice(allocator, ",\"evidence_ranges\":");
        try json.appendRawJsonArray(out, allocator, self.evidence_ranges_json);
        try out.appendSlice(allocator, ",\"created_by\":");
        try json.appendString(out, allocator, self.created_by);
        try out.print(allocator, ",\"created_at_ms\":{d}", .{self.created_at_ms});
        try appendOptionalInt(allocator, out, "valid_from_ms", self.valid_from_ms);
        try appendOptionalInt(allocator, out, "valid_until_ms", self.valid_until_ms);
        try appendOptionalInt(allocator, out, "last_verified_at_ms", self.last_verified_at_ms);
        try out.appendSlice(allocator, ",\"owner\":");
        try json.appendNullableString(out, allocator, self.owner);
        try out.appendSlice(allocator, ",\"permissions\":");
        try json.appendRawJsonArray(out, allocator, self.permissions_json);
        try out.appendSlice(allocator, ",\"tags\":");
        try json.appendRawJsonArray(out, allocator, self.tags_json);
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
        try json.appendRawJsonArray(out, allocator, self.aliases_json);
        try out.appendSlice(allocator, ",\"description\":");
        try json.appendNullableString(out, allocator, self.description);
        try out.appendSlice(allocator, ",\"canonical_artifact_id\":");
        try json.appendNullableString(out, allocator, self.canonical_artifact_id);
        try out.appendSlice(allocator, ",\"scope\":");
        try json.appendString(out, allocator, self.scope);
        try out.appendSlice(allocator, ",\"permissions\":");
        try json.appendRawJsonArray(out, allocator, self.permissions_json);
        try out.appendSlice(allocator, ",\"metadata\":");
        try json.appendRawJsonObject(out, allocator, self.metadata_json);
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
        try json.appendRawJsonArray(out, allocator, self.source_ids_json);
        try out.appendSlice(allocator, ",\"scope\":");
        try json.appendString(out, allocator, self.scope);
        try out.appendSlice(allocator, ",\"permissions\":");
        try json.appendRawJsonArray(out, allocator, self.permissions_json);
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
    heading_path_json: []const u8 = "[]",
    required_scopes_json: []const u8 = "",
    actor_isolated: bool = false,
    created_at_ms: i64 = 0,
    confidence: f64 = 0.5,
    store: []const u8 = "",
    session_id: ?[]const u8 = null,

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
        if (self.store.len > 0) {
            try out.appendSlice(allocator, ",\"store\":");
            try json.appendString(out, allocator, self.store);
            try out.appendSlice(allocator, ",\"storage\":");
            try json.appendString(out, allocator, self.store);
        }
        if (self.session_id) |session_id| {
            try out.appendSlice(allocator, ",\"session_id\":");
            try json.appendString(out, allocator, session_id);
        }
        try out.print(allocator, ",\"score\":{d},\"created_at_ms\":{d},\"confidence\":{d},\"actor_isolated\":{s},\"required_scopes\":", .{ self.score, self.created_at_ms, self.confidence, if (self.actor_isolated) "true" else "false" });
        try json.appendOptionalRawJsonArray(out, allocator, self.required_scopes_json);
        try out.appendSlice(allocator, ",\"citations\":");
        try json.appendRawJsonArray(out, allocator, self.source_ids_json);
        try out.appendSlice(allocator, ",\"heading_path\":");
        try json.appendRawJsonArray(out, allocator, self.heading_path_json);
        try out.append(allocator, '}');
    }
};

pub const AgentMemory = struct {
    id: []const u8,
    key: []const u8,
    content: []const u8,
    category: []const u8,
    timestamp: []const u8,
    session_id: ?[]const u8,
    actor_id: []const u8,
    writer_actor_id: []const u8 = "",
    scope: []const u8,
    permissions_json: []const u8 = "[]",
    status: []const u8 = "",
    store: []const u8 = "",
    score: ?f64 = null,

    pub fn writeJson(self: AgentMemory, allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
        return self.writeJsonWithOptions(allocator, out, .{});
    }

    pub fn writeJsonWithOptions(self: AgentMemory, allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), options: AgentMemoryJsonOptions) !void {
        try out.appendSlice(allocator, "{\"id\":");
        try json.appendString(out, allocator, self.id);
        try out.appendSlice(allocator, ",\"key\":");
        try json.appendString(out, allocator, self.key);
        if (options.include_content) {
            try out.appendSlice(allocator, ",\"content\":");
            try json.appendString(out, allocator, options.content_override orelse self.content);
        }
        try out.appendSlice(allocator, ",\"category\":");
        try json.appendString(out, allocator, self.category);
        try out.appendSlice(allocator, ",\"timestamp\":");
        try json.appendString(out, allocator, self.timestamp);
        try out.appendSlice(allocator, ",\"session_id\":");
        try json.appendNullableString(out, allocator, self.session_id);
        try out.appendSlice(allocator, ",\"actor_id\":");
        try json.appendString(out, allocator, self.actor_id);
        try out.appendSlice(allocator, ",\"owner_id\":");
        try json.appendString(out, allocator, self.actor_id);
        try out.appendSlice(allocator, ",\"created_by_actor_id\":");
        try json.appendString(out, allocator, if (self.writer_actor_id.len > 0) self.writer_actor_id else self.actor_id);
        try out.appendSlice(allocator, ",\"scope\":");
        try json.appendString(out, allocator, self.scope);
        try out.appendSlice(allocator, ",\"permissions\":");
        try json.appendRawJsonArray(out, allocator, self.permissions_json);
        if (options.include_status) {
            try out.appendSlice(allocator, ",\"status\":");
            try json.appendString(out, allocator, if (self.status.len > 0) self.status else "proposed");
        }
        if (self.store.len > 0) {
            try out.appendSlice(allocator, ",\"store\":");
            try json.appendString(out, allocator, self.store);
            if (options.include_storage_alias) {
                try out.appendSlice(allocator, ",\"storage\":");
                try json.appendString(out, allocator, self.store);
            }
        }
        try out.appendSlice(allocator, ",\"score\":");
        if (self.score) |s| try out.print(allocator, "{d}", .{s}) else try out.appendSlice(allocator, "null");
        try out.append(allocator, '}');
    }
};

pub const AgentMemoryJsonOptions = struct {
    include_content: bool = true,
    content_override: ?[]const u8 = null,
    include_status: bool = true,
    include_storage_alias: bool = true,
};

pub const AgentMemoryOperation = enum {
    put,
    merge_object,
    merge_string_set,

    pub fn parse(raw: []const u8) AgentMemoryOperation {
        if (std.mem.eql(u8, raw, "merge_object")) return .merge_object;
        if (std.mem.eql(u8, raw, "merge_string_set")) return .merge_string_set;
        return .put;
    }

    pub fn name(self: AgentMemoryOperation) []const u8 {
        return switch (self) {
            .put => "put",
            .merge_object => "merge_object",
            .merge_string_set => "merge_string_set",
        };
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

pub fn defaultAgentMemoryScope(allocator: std.mem.Allocator, actor_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "agent:{s}", .{actor_id});
}

pub fn actorGrant(allocator: std.mem.Allocator, actor_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "actor:{s}", .{actor_id});
}

pub fn actorGrantJson(allocator: std.mem.Allocator, actor_id: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '[');
    const grant = try actorGrant(allocator, actor_id);
    defer allocator.free(grant);
    try json.appendString(&out, allocator, grant);
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

pub fn permissionsContainActorGrant(allocator: std.mem.Allocator, permissions_json: []const u8, actor_id: []const u8) bool {
    const grant = actorGrant(allocator, actor_id) catch return false;
    defer allocator.free(grant);
    return hasJsonString(permissions_json, grant);
}

pub fn isActorOwnedAgentMemoryScope(scope: []const u8, actor_id: []const u8) bool {
    if (std.mem.eql(u8, scope, actor_id)) return true;
    if (std.mem.startsWith(u8, scope, "agent:")) {
        return std.mem.eql(u8, scope["agent:".len..], actor_id);
    }
    return false;
}

pub fn permissionsAreOpen(permissions_json: []const u8) bool {
    const trimmed = std.mem.trim(u8, permissions_json, " \t\r\n");
    return trimmed.len == 0 or std.mem.eql(u8, trimmed, "[]") or jsonStringArrayIsSingleValue(trimmed, "public");
}

pub fn permissionsArePublicReadable(permissions_json: []const u8) bool {
    const trimmed = std.mem.trim(u8, permissions_json, " \t\r\n");
    return permissionsAreOpen(trimmed) or hasJsonString(trimmed, "public");
}

pub fn isDefaultVisibleStatus(status: []const u8) bool {
    return !(std.mem.eql(u8, status, "rejected") or
        std.mem.eql(u8, status, "deprecated") or
        std.mem.eql(u8, status, "superseded"));
}

pub const last_hygiene_key = "last_hygiene_at";
pub const prompt_bootstrap_key_prefix = bootstrap_prompts.key_prefix;
pub const PromptBootstrapDoc = bootstrap_prompts.Doc;
pub const prompt_bootstrap_docs = bootstrap_prompts.docs;

pub fn promptBootstrapMemoryKey(filename: []const u8) ?[]const u8 {
    return bootstrap_prompts.memoryKey(filename);
}

pub fn usesWorkspaceBootstrapFiles(memory_backend: ?[]const u8) bool {
    return bootstrap_prompts.usesWorkspaceFiles(memory_backend);
}

pub fn isInternalMemoryKey(key: []const u8) bool {
    return isAutosaveMemoryKey(key) or
        std.mem.eql(u8, key, last_hygiene_key) or
        std.mem.startsWith(u8, key, prompt_bootstrap_key_prefix);
}

pub fn isAutosaveMemoryKey(key: []const u8) bool {
    return std.mem.startsWith(u8, key, "autosave_");
}

pub fn extractMarkdownMemoryKey(content: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "**")) return null;
    const rest = trimmed[2..];
    const suffix = std.mem.indexOf(u8, rest, "**:") orelse return null;
    if (suffix == 0) return null;
    return rest[0..suffix];
}

pub fn isInternalMemoryEntryKeyOrContent(key: []const u8, content: []const u8) bool {
    if (isInternalMemoryKey(key)) return true;
    if (extractMarkdownMemoryKey(content)) |extracted| {
        if (isInternalMemoryKey(extracted)) return true;
    }
    return false;
}

fn quotedStringContains(list_json: []const u8, value: []const u8) bool {
    if (!jsonStringArrayWellFormed(list_json)) return false;
    var it = json_string_array.Iterator.init(list_json);
    while (it.next()) |item| {
        if (jsonStringLiteralEquals(item, value)) return true;
    }
    return false;
}

pub fn hasJsonString(list_json: []const u8, value: []const u8) bool {
    return quotedStringContains(list_json, value);
}

fn jsonStringArrayIsSingleValue(list_json: []const u8, value: []const u8) bool {
    if (!jsonStringArrayWellFormed(list_json)) return false;
    var it = json_string_array.Iterator.init(list_json);
    const first = it.next() orelse return false;
    if (!jsonStringLiteralEquals(first, value)) return false;
    return it.next() == null and !it.invalid;
}

fn parseJsonStringListStrict(allocator: std.mem.Allocator, list_json: []const u8) !std.json.Parsed(std.json.Value) {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, list_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidRawJson,
    };
    errdefer parsed.deinit();

    if (parsed.value != .array) return error.InvalidRawJson;
    for (parsed.value.array.items) |item_value| {
        if (item_value != .string) return error.InvalidRawJson;
    }
    return parsed;
}

pub fn intersectJsonStringLists(allocator: std.mem.Allocator, requested_json: []const u8, allowed_json: []const u8) ![]const u8 {
    const requested = std.mem.trim(u8, requested_json, " \t\r\n");
    if (requested.len == 0 or std.mem.eql(u8, requested, "[]")) return allocator.dupe(u8, "[]");

    var parsed = try parseJsonStringListStrict(allocator, requested);
    defer parsed.deinit();

    const allowed_is_admin = quotedStringContains(allowed_json, "admin");

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '[');
    var first = true;
    for (parsed.value.array.items) |item_value| {
        const item = item_value.string;
        if (!allowed_is_admin and !std.mem.eql(u8, item, "public") and !scopeGrantedByList(allowed_json, item)) continue;
        if (!first) try out.append(allocator, ',');
        first = false;
        try json.appendString(&out, allocator, item);
    }
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

fn quotedStringContainsEncoded(list_json: []const u8, encoded_value: []const u8) bool {
    if (!jsonStringArrayWellFormed(list_json)) return false;
    var it = json_string_array.Iterator.init(list_json);
    while (it.next()) |item| {
        if (jsonStringLiteralsEqual(item, encoded_value)) return true;
    }
    return false;
}

fn jsonStringLiteralEquals(encoded: []const u8, value: []const u8) bool {
    var reader = json_string_array.ByteReader.init(encoded);
    var value_index: usize = 0;
    while (reader.next()) |decoded| {
        if (value_index >= value.len or value[value_index] != decoded) return false;
        value_index += 1;
    }
    return !reader.failed and value_index == value.len;
}

fn jsonStringLiteralsEqual(left: []const u8, right: []const u8) bool {
    var left_reader = json_string_array.ByteReader.init(left);
    var right_reader = json_string_array.ByteReader.init(right);
    while (true) {
        const left_byte = left_reader.next();
        const right_byte = right_reader.next();
        if (left_reader.failed or right_reader.failed) return false;
        if (left_byte == null or right_byte == null) return left_byte == null and right_byte == null;
        if (left_byte.? != right_byte.?) return false;
    }
}

fn jsonStringLiteralPrefixOfRaw(encoded_prefix: []const u8, value: []const u8) bool {
    var reader = json_string_array.ByteReader.init(encoded_prefix);
    var value_index: usize = 0;
    while (reader.next()) |decoded| {
        if (value_index >= value.len or value[value_index] != decoded) return false;
        value_index += 1;
    }
    return !reader.failed;
}

fn jsonStringLiteralPrefixOfEncoded(encoded_prefix: []const u8, encoded_value: []const u8) bool {
    var prefix_reader = json_string_array.ByteReader.init(encoded_prefix);
    var value_reader = json_string_array.ByteReader.init(encoded_value);
    while (prefix_reader.next()) |prefix_byte| {
        const value_byte = value_reader.next() orelse return false;
        if (prefix_byte != value_byte) return false;
    }
    return !prefix_reader.failed and !value_reader.failed;
}

fn jsonStringArrayWellFormed(raw: []const u8) bool {
    return json_string_array.wellFormed(raw);
}

pub fn jsonStringArrayItemsNonBlank(raw: []const u8) bool {
    return json_string_array.itemsNonBlank(raw);
}

pub fn hasActorScope(actor_scopes_json: []const u8, scope: []const u8) bool {
    return quotedStringContains(actor_scopes_json, scope);
}

fn scopeGrantedByList(actor_scopes_json: []const u8, scope: []const u8) bool {
    if (quotedStringContains(actor_scopes_json, scope)) return true;
    if (!jsonStringArrayWellFormed(actor_scopes_json)) return false;
    var it = json_string_array.Iterator.init(actor_scopes_json);
    while (it.next()) |actor_scope| {
        if (actor_scope.len < 2 or actor_scope[actor_scope.len - 1] != '*') continue;
        const prefix = actor_scope[0 .. actor_scope.len - 1];
        if (jsonStringLiteralPrefixOfRaw(prefix, scope)) return true;
    }
    return false;
}

fn scopeGrantedByListEncoded(actor_scopes_json: []const u8, encoded_scope: []const u8) bool {
    if (quotedStringContainsEncoded(actor_scopes_json, encoded_scope)) return true;
    if (!jsonStringArrayWellFormed(actor_scopes_json)) return false;
    var it = json_string_array.Iterator.init(actor_scopes_json);
    while (it.next()) |actor_scope| {
        if (actor_scope.len < 2 or actor_scope[actor_scope.len - 1] != '*') continue;
        const prefix = actor_scope[0 .. actor_scope.len - 1];
        if (jsonStringLiteralPrefixOfEncoded(prefix, encoded_scope)) return true;
    }
    return false;
}

fn hasPrefixedActorScope(actor_scopes_json: []const u8, prefix: []const u8, scope: []const u8) bool {
    if (!jsonStringArrayWellFormed(actor_scopes_json)) return false;
    var it = json_string_array.Iterator.init(actor_scopes_json);
    while (it.next()) |actor_scope| {
        if (actor_scope.len == prefix.len + 1 and std.mem.startsWith(u8, actor_scope, prefix) and actor_scope[actor_scope.len - 1] == '*') return true;
        if (!std.mem.startsWith(u8, actor_scope, prefix)) continue;
        const granted = actor_scope[prefix.len..];
        if (granted.len > 0 and granted[granted.len - 1] == '*') {
            if (jsonStringLiteralPrefixOfRaw(granted[0 .. granted.len - 1], scope)) return true;
            continue;
        }
        if (jsonStringLiteralEquals(granted, scope)) return true;
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
    if (!jsonStringArrayWellFormed(trimmed)) return false;

    var permissions = json_string_array.Iterator.init(trimmed);
    while (permissions.next()) |permission| {
        if (jsonStringLiteralEquals(permission, "public")) return true;
        if (quotedStringContainsEncoded(actor_scopes_json, permission)) return true;
    }
    return false;
}

pub fn scopeListVisible(required_scopes_json: []const u8, actor_scopes_json: []const u8) bool {
    const trimmed = std.mem.trim(u8, required_scopes_json, " \t\r\n");
    if (hasActorScope(actor_scopes_json, "admin")) return true;
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "[]")) return false;
    if (!jsonStringArrayWellFormed(trimmed)) return false;

    var required = json_string_array.Iterator.init(trimmed);
    var saw_scope = false;
    while (required.next()) |scope| {
        saw_scope = true;
        if (jsonStringLiteralEquals(scope, "public")) continue;
        if (!scopeGrantedByListEncoded(actor_scopes_json, scope)) return false;
    }
    return saw_scope and !required.invalid;
}

pub fn permissionsWritable(permissions_json: []const u8, actor_scopes_json: []const u8) bool {
    const trimmed = std.mem.trim(u8, permissions_json, " \t\r\n");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "[]")) return true;
    if (hasActorScope(actor_scopes_json, "admin")) return true;
    if (!jsonStringArrayWellFormed(trimmed)) return false;

    var permissions = json_string_array.Iterator.init(trimmed);
    var saw_scope = false;
    while (permissions.next()) |scope| {
        saw_scope = true;
        if (jsonStringLiteralEquals(scope, "public")) continue;
        if (!quotedStringContainsEncoded(actor_scopes_json, scope)) return false;
    }
    return saw_scope and !permissions.invalid;
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
    return hasPrefixedActorScope(actor_scopes_json, "verify:", scope);
}

pub fn scopeDeletable(scope: []const u8, actor_scopes_json: []const u8) bool {
    if (hasActorScope(actor_scopes_json, "admin")) return true;
    return hasPrefixedActorScope(actor_scopes_json, "delete:", scope);
}

pub fn recordVisible(scope: []const u8, permissions_json: []const u8, actor_scopes_json: []const u8) bool {
    return scopeVisible(scope, actor_scopes_json) and permissionsVisible(permissions_json, actor_scopes_json);
}

test "json string ACL checks decode escapes and do not impose a small fixed limit" {
    try std.testing.expect(hasJsonString("[\"agent:\\\"quoted\",\"team:\\u0041\"]", "agent:\"quoted"));
    try std.testing.expect(hasJsonString("[\"agent:\\\"quoted\",\"team:\\u0041\"]", "team:A"));
    try std.testing.expect(permissionsVisible("[\"team:\\u0041\"]", "[\"team:A\"]"));
    try std.testing.expect(permissionsVisible("[\"team:A\"]", "[\"team:\\u0041\"]"));
    try std.testing.expect(hasJsonString("[\"team:\\u00e9\"]", "team:\xc3\xa9"));
    try std.testing.expect(hasJsonString("[\"music:\\uD834\\uDD1E\"]", "music:\xf0\x9d\x84\x9e"));
    try std.testing.expect(permissionsVisible("[\"team:\\u00e9\"]", "[\"team:\xc3\xa9\"]"));
    try std.testing.expect(permissionsVisible("[\"team:\xc3\xa9\"]", "[\"team:\\u00e9\"]"));
    try std.testing.expect(scopeVisible("team:\xc3\xa9-child", "[\"team:\\u00e9-*\"]"));
    try std.testing.expect(scopeWritable("team:\xc3\xa9-child", "[\"write:team:\\u00e9-*\"]"));

    var long_value_buf: [320]u8 = undefined;
    @memset(&long_value_buf, 'a');
    const long_value = long_value_buf[0..];

    var list_json: std.ArrayListUnmanaged(u8) = .empty;
    defer list_json.deinit(std.testing.allocator);
    try list_json.append(std.testing.allocator, '[');
    try json.appendString(&list_json, std.testing.allocator, long_value);
    try list_json.append(std.testing.allocator, ']');
    try std.testing.expect(hasJsonString(list_json.items, long_value));
}

test "json string ACL lists fail closed on malformed containers" {
    try std.testing.expect(!hasJsonString("{\"scope\":\"admin\"}", "admin"));
    try std.testing.expect(!hasJsonString("[\"public\",]", "public"));
    try std.testing.expect(!hasJsonString("[\"team:\\u00zz\"]", "team:zz"));

    try std.testing.expect(jsonStringArrayItemsNonBlank("[]"));
    try std.testing.expect(jsonStringArrayItemsNonBlank("[\"public\",\"team:\\u0041\"]"));
    try std.testing.expect(!jsonStringArrayItemsNonBlank("\"public\""));
    try std.testing.expect(!jsonStringArrayItemsNonBlank("[1]"));
    try std.testing.expect(!jsonStringArrayItemsNonBlank("[\"\"]"));
    try std.testing.expect(!jsonStringArrayItemsNonBlank("[\"  \"]"));
    try std.testing.expect(!jsonStringArrayItemsNonBlank("[\"\\u0020\"]"));
    try std.testing.expect(!jsonStringArrayItemsNonBlank("[\"public\",]"));

    try std.testing.expect(!permissionsVisible("{\"permission\":\"public\"}", "[]"));
    try std.testing.expect(!permissionsVisible("[\"public\",]", "[]"));
    try std.testing.expect(!permissionsWritable("{\"permission\":\"project:a\"}", "[\"project:a\"]"));

    try std.testing.expect(!hasCapability("{\"scope\":\"admin\"}", "[]", "delete"));
    try std.testing.expect(!scopeVisible("project:a", "{\"scope\":\"project:a\"}"));
    try std.testing.expect(!scopeWritable("project:a", "{\"scope\":\"write:project:a\"}"));
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
    try std.testing.expect(scopeWritable("session:sess_1", "[\"write:session:*\"]"));
    try std.testing.expect(scopeVerifiable("project:nullpantry", "[\"verify:project:nullpantry\"]"));
    try std.testing.expect(scopeDeletable("project:nullpantry", "[\"delete:project:nullpantry\"]"));
    try std.testing.expect(recordVisible("project:nullpantry", "[\"team:platform\"]", "[\"project:nullpantry\",\"team:platform\"]"));
    try std.testing.expect(!recordVisible("project:nullpantry", "[\"team:platform\"]", "[\"project:nullpantry\"]"));
    try std.testing.expect(permissionsVisible("[\"public\"]", "[]"));
    try std.testing.expect(!permissionsWritable("[\"public\",\"project:secret\"]", "[\"public\"]"));
    try std.testing.expect(permissionsWritable("[\"public\",\"project:secret\"]", "[\"project:secret\"]"));

    try std.testing.expect(permissionsAreOpen("[]"));
    try std.testing.expect(permissionsAreOpen("[\"public\"]"));
    try std.testing.expect(permissionsAreOpen("[\"\\u0070ublic\"]"));
    try std.testing.expect(!permissionsAreOpen("[\"public\",\"project:secret\"]"));
    try std.testing.expect(permissionsArePublicReadable("[\"public\",\"project:secret\"]"));
    try std.testing.expect(!permissionsArePublicReadable("[\"public\",]"));
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

    const escaped_filtered = try intersectJsonStringLists(alloc, "[\"team:\\u0041\"]", "[\"team:A\"]");
    defer alloc.free(escaped_filtered);
    try std.testing.expectEqualStrings("[\"team:A\"]", escaped_filtered);

    const utf8_filtered = try intersectJsonStringLists(alloc, "[\"team:\\u00e9\"]", "[\"team:\xc3\xa9\"]");
    defer alloc.free(utf8_filtered);
    try std.testing.expectEqualStrings("[\"team:\xc3\xa9\"]", utf8_filtered);

    const admin_filtered = try intersectJsonStringLists(alloc, "[\"project:secret\"]", "[\"admin\"]");
    defer alloc.free(admin_filtered);
    try std.testing.expectEqualStrings("[\"project:secret\"]", admin_filtered);

    const admin_escaped = try intersectJsonStringLists(alloc, "[\"team:\\u00e9\"]", "[\"admin\"]");
    defer alloc.free(admin_escaped);
    try std.testing.expectEqualStrings("[\"team:\xc3\xa9\"]", admin_escaped);

    try std.testing.expectError(error.InvalidRawJson, intersectJsonStringLists(alloc, "not-json", "[\"admin\"]"));

    try std.testing.expectError(error.InvalidRawJson, intersectJsonStringLists(alloc, "{\"scope\":\"project:secret\"}", "[\"admin\"]"));
    try std.testing.expectError(error.InvalidRawJson, intersectJsonStringLists(alloc, "[\"project:secret\",42]", "[\"admin\"]"));
}

test "scope list visibility prevents cache scope escalation" {
    try std.testing.expect(scopeListVisible("[\"public\"]", "[\"public\"]"));
    try std.testing.expect(scopeListVisible("[\"project:a\"]", "[\"project:a\"]"));
    try std.testing.expect(scopeListVisible("[\"project:a\"]", "[\"project:*\"]"));
    try std.testing.expect(!scopeListVisible("[\"project:a\",\"project:b\"]", "[\"project:a\"]"));
    try std.testing.expect(!scopeListVisible("[\"admin\"]", "[\"public\"]"));
    try std.testing.expect(scopeListVisible("[]", "[\"admin\"]"));
    try std.testing.expect(!scopeListVisible("[]", "[\"public\"]"));
    try std.testing.expect(!scopeListVisible("{\"scope\":\"public\"}", "[\"public\"]"));
    try std.testing.expect(!scopeListVisible("[\"project:a\",]", "[\"project:a\"]"));
}

test "relation json has a single source_ids field" {
    const alloc = std.testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    try (Relation{
        .id = "rel_test",
        .from_entity_id = "ent_a",
        .relation_type = "documents",
        .to_entity_id = "ent_b",
        .source_ids_json = "[\"src_a\"]",
        .scope = "public",
        .permissions_json = "[]",
        .confidence = 0.9,
        .status = "verified",
        .created_at_ms = 1,
    }).writeJson(alloc, &out);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, out.items, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    try std.testing.expect(parsed.value.object.get("source_ids") != null);
    try std.testing.expectEqualStrings("public", parsed.value.object.get("scope").?.string);
}

test "domain json writers enforce raw container root types" {
    const alloc = std.testing.allocator;
    var source_out: std.ArrayListUnmanaged(u8) = .empty;
    defer source_out.deinit(alloc);
    try std.testing.expectError(error.InvalidRawJson, (Source{
        .id = "src_bad_raw",
        .source_type = "note",
        .title = "Bad raw source",
        .participants_json = "{\"agent\":\"a\"}",
        .permissions_json = "{\"scope\":\"public\"}",
        .related_entities_json = "{\"id\":\"ent\"}",
        .metadata_json = "[\"not-object\"]",
        .created_at_ms = 1,
        .imported_at_ms = 2,
    }).writeJson(alloc, &source_out));

    var search_out: std.ArrayListUnmanaged(u8) = .empty;
    defer search_out.deinit(alloc);
    try std.testing.expectError(error.InvalidRawJson, (SearchResult{
        .id = "search_bad_raw",
        .result_type = "source",
        .title = "Bad raw search",
        .text = "body",
        .scope = "public",
        .status = "verified",
        .score = 0.5,
        .source_ids_json = "{\"id\":\"src\"}",
        .heading_path_json = "{\"heading\":\"Intro\"}",
        .required_scopes_json = "{\"scope\":\"public\"}",
    }).writeJson(alloc, &search_out));
}

test "agent memory json options preserve owner contract" {
    const alloc = std.testing.allocator;
    const entry = AgentMemory{
        .id = "mem_1",
        .key = "team.pref",
        .content = "full private value",
        .category = "core",
        .timestamp = "123",
        .session_id = "sess_1",
        .actor_id = "shared:team:alpha",
        .writer_actor_id = "agent:a",
        .scope = "team:alpha",
        .permissions_json = "[\"team:alpha\"]",
        .status = "verified",
        .store = "redis",
        .score = 0.75,
    };

    var full: std.ArrayListUnmanaged(u8) = .empty;
    defer full.deinit(alloc);
    try entry.writeJson(alloc, &full);
    var full_json = try std.json.parseFromSlice(std.json.Value, alloc, full.items, .{});
    defer full_json.deinit();
    const full_obj = full_json.value.object;
    try std.testing.expectEqualStrings("shared:team:alpha", full_obj.get("actor_id").?.string);
    try std.testing.expectEqualStrings("shared:team:alpha", full_obj.get("owner_id").?.string);
    try std.testing.expectEqualStrings("agent:a", full_obj.get("created_by_actor_id").?.string);
    try std.testing.expectEqualStrings("full private value", full_obj.get("content").?.string);
    try std.testing.expectEqualStrings("verified", full_obj.get("status").?.string);
    try std.testing.expectEqualStrings("redis", full_obj.get("storage").?.string);

    var summary: std.ArrayListUnmanaged(u8) = .empty;
    defer summary.deinit(alloc);
    try entry.writeJsonWithOptions(alloc, &summary, .{
        .include_content = false,
        .content_override = "ignored when content is disabled",
        .include_status = false,
    });
    var summary_json = try std.json.parseFromSlice(std.json.Value, alloc, summary.items, .{});
    defer summary_json.deinit();
    const summary_obj = summary_json.value.object;
    try std.testing.expect(summary_obj.get("content") == null);
    try std.testing.expect(summary_obj.get("status") == null);
    try std.testing.expectEqualStrings("shared:team:alpha", summary_obj.get("owner_id").?.string);
    try std.testing.expectEqualStrings("agent:a", summary_obj.get("created_by_actor_id").?.string);
    try std.testing.expectEqualStrings("team:alpha", summary_obj.get("scope").?.string);
    try std.testing.expect(summary_obj.get("permissions") != null);

    var excerpt: std.ArrayListUnmanaged(u8) = .empty;
    defer excerpt.deinit(alloc);
    try entry.writeJsonWithOptions(alloc, &excerpt, .{
        .content_override = "short excerpt",
        .include_status = false,
    });
    var excerpt_json = try std.json.parseFromSlice(std.json.Value, alloc, excerpt.items, .{});
    defer excerpt_json.deinit();
    const excerpt_obj = excerpt_json.value.object;
    try std.testing.expectEqualStrings("short excerpt", excerpt_obj.get("content").?.string);
    try std.testing.expect(excerpt_obj.get("status") == null);
}
