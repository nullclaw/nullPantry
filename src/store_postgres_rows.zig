const std = @import("std");

const context_pack = @import("context_pack.zig");
const domain = @import("domain.zig");
const json = @import("json_util.zig");
const store_conflict = @import("store_conflict.zig");
const store_connector_cursor = @import("store_connector_cursor.zig");
const store_context_pack = @import("store_context_pack.zig");
const store_feed = @import("store_feed.zig");
const store_job = @import("store_job.zig");
const store_types = @import("store_types.zig");
const store_vector = @import("store_vector.zig");

pub fn dupStringField(allocator: std.mem.Allocator, obj: std.json.ObjectMap, name: []const u8, fallback: []const u8) ![]u8 {
    return allocator.dupe(u8, json.stringField(obj, name) orelse fallback);
}

pub fn dupNullableStringField(allocator: std.mem.Allocator, obj: std.json.ObjectMap, name: []const u8) !?[]u8 {
    const value = obj.get(name) orelse return null;
    return switch (value) {
        .string => |s| try allocator.dupe(u8, s),
        .null => null,
        else => null,
    };
}

pub fn rawJsonField(allocator: std.mem.Allocator, obj: std.json.ObjectMap, name: []const u8, fallback: []const u8) ![]u8 {
    const value = obj.get(name) orelse return json.rawJsonFieldFallback(allocator, name, fallback);
    const raw = try json.rawJsonFieldValue(allocator, name, value, fallback);
    errdefer allocator.free(raw);
    if (expectedRootFromFallback(fallback)) |root| {
        if (!json.rawJsonRootIs(allocator, raw, root)) return error.InvalidRawJson;
    }
    return raw;
}

fn expectedRootFromFallback(fallback: []const u8) ?json.RawJsonRoot {
    const trimmed = std.mem.trim(u8, fallback, " \t\r\n");
    if (trimmed.len == 0) return null;
    return switch (trimmed[0]) {
        '[' => .array,
        '{' => .object,
        else => null,
    };
}

pub fn optionalIntField(obj: std.json.ObjectMap, name: []const u8) ?i64 {
    const value = obj.get(name) orelse return null;
    if (value == .null) return null;
    return json.intField(obj, name);
}

pub fn readContextPackResult(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !store_context_pack.Result {
    const sources = try rawJsonField(allocator, obj, "included_sources_json", "[]");
    return .{
        .id = try dupStringField(allocator, obj, "id", ""),
        .purpose = try dupStringField(allocator, obj, "purpose", "context"),
        .target = try dupStringField(allocator, obj, "target", "agent"),
        .query = try dupStringField(allocator, obj, "query_text", ""),
        .generated_summary = try dupStringField(allocator, obj, "generated_summary", ""),
        .sections_json = try rawJsonField(allocator, obj, "sections_json", "{}"),
        .citations_json = try rawJsonField(allocator, obj, "citations_json", sources),
        .forbidden_assumptions_json = try rawJsonField(allocator, obj, "forbidden_assumptions_json", context_pack.forbidden_assumptions_json),
        .suggested_next_steps_json = try rawJsonField(allocator, obj, "suggested_next_steps_json", context_pack.suggested_next_steps_json),
        .included_sources_json = sources,
        .included_artifacts_json = try rawJsonField(allocator, obj, "included_artifacts_json", "[]"),
        .included_memory_atoms_json = try rawJsonField(allocator, obj, "included_memory_atoms_json", "[]"),
        .included_result_refs_json = try rawJsonField(allocator, obj, "included_result_refs_json", "[]"),
        .required_scopes_json = try rawJsonField(allocator, obj, "required_scopes_json", "[]"),
        .actor_id = try dupNullableStringField(allocator, obj, "actor_id"),
        .actor_isolated = json.boolField(obj, "actor_isolated") orelse false,
        .token_budget = json.intField(obj, "token_budget") orelse 0,
        .created_at_ms = json.intField(obj, "created_at_ms") orelse 0,
        .persisted = true,
    };
}

pub fn readVectorChunk(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !store_vector.Chunk {
    return .{
        .id = try dupStringField(allocator, obj, "id", ""),
        .object_type = try dupStringField(allocator, obj, "object_type", ""),
        .object_id = try dupStringField(allocator, obj, "object_id", ""),
        .chunk_ordinal = json.intField(obj, "chunk_ordinal") orelse 0,
        .text = try dupStringField(allocator, obj, "text", ""),
        .scope = try dupStringField(allocator, obj, "scope", "workspace"),
        .permissions_json = try rawJsonField(allocator, obj, "permissions_json", "[]"),
        .heading_path_json = try rawJsonField(allocator, obj, "heading_path_json", "[]"),
        .start_byte = json.intField(obj, "start_byte") orelse 0,
        .end_byte = json.intField(obj, "end_byte") orelse 0,
        .content_hash = try dupStringField(allocator, obj, "content_hash", ""),
        .chunk_strategy = try dupStringField(allocator, obj, "chunk_strategy", "plain"),
        .estimated_tokens = json.intField(obj, "estimated_tokens") orelse 0,
        .transcript_timestamp = try dupNullableStringField(allocator, obj, "transcript_timestamp"),
        .transcript_speaker = try dupNullableStringField(allocator, obj, "transcript_speaker"),
        .embedding_json = try rawJsonField(allocator, obj, "embedding_json", "[]"),
        .model = try dupNullableStringField(allocator, obj, "model"),
        .dimensions = json.intField(obj, "dimensions") orelse 0,
        .created_at_ms = json.intField(obj, "created_at_ms") orelse 0,
        .updated_at_ms = json.intField(obj, "updated_at_ms") orelse 0,
    };
}

pub fn readSpace(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !store_types.Space {
    return .{
        .id = try dupStringField(allocator, obj, "id", ""),
        .name = try dupStringField(allocator, obj, "name", ""),
        .title = try dupStringField(allocator, obj, "title", ""),
        .description = try dupNullableStringField(allocator, obj, "description"),
        .scope = try dupStringField(allocator, obj, "scope", "workspace"),
        .permissions_json = try rawJsonField(allocator, obj, "permissions_json", "[]"),
        .metadata_json = try rawJsonField(allocator, obj, "metadata_json", "{}"),
        .created_at_ms = json.intField(obj, "created_at_ms") orelse 0,
        .updated_at_ms = json.intField(obj, "updated_at_ms") orelse 0,
    };
}

pub fn readPolicyScope(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !store_types.PolicyScope {
    return .{
        .scope = try dupStringField(allocator, obj, "scope", "workspace"),
        .visibility = try dupStringField(allocator, obj, "visibility", "workspace"),
        .permissions_json = try rawJsonField(allocator, obj, "permissions_json", "[]"),
        .owner = try dupNullableStringField(allocator, obj, "owner"),
        .ttl_ms = optionalIntField(obj, "ttl_ms"),
        .review_after_ms = optionalIntField(obj, "review_after_ms"),
        .metadata_json = try rawJsonField(allocator, obj, "metadata_json", "{}"),
        .created_at_ms = json.intField(obj, "created_at_ms") orelse 0,
        .updated_at_ms = json.intField(obj, "updated_at_ms") orelse 0,
    };
}

pub fn readSource(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !domain.Source {
    return .{
        .id = try dupStringField(allocator, obj, "id", ""),
        .source_type = try dupStringField(allocator, obj, "type", "manual"),
        .title = try dupStringField(allocator, obj, "title", ""),
        .raw_content_uri = try dupNullableStringField(allocator, obj, "raw_content_uri"),
        .content = try dupStringField(allocator, obj, "content", ""),
        .author = try dupNullableStringField(allocator, obj, "author"),
        .participants_json = try rawJsonField(allocator, obj, "participants_json", "[]"),
        .permissions_json = try rawJsonField(allocator, obj, "permissions_json", "[]"),
        .scope = try dupStringField(allocator, obj, "scope", "workspace"),
        .created_at_ms = json.intField(obj, "created_at_ms") orelse 0,
        .imported_at_ms = json.intField(obj, "imported_at_ms") orelse 0,
        .checksum = try dupNullableStringField(allocator, obj, "checksum"),
        .language = try dupNullableStringField(allocator, obj, "language"),
        .related_entities_json = try rawJsonField(allocator, obj, "related_entities_json", "[]"),
        .metadata_json = try rawJsonField(allocator, obj, "metadata_json", "{}"),
    };
}

pub fn readArtifact(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !domain.Artifact {
    return .{
        .id = try dupStringField(allocator, obj, "id", ""),
        .artifact_type = try dupStringField(allocator, obj, "type", "page"),
        .title = try dupStringField(allocator, obj, "title", ""),
        .body = try dupStringField(allocator, obj, "body", ""),
        .status = try dupStringField(allocator, obj, "status", "draft"),
        .owner = try dupNullableStringField(allocator, obj, "owner"),
        .space_id = try dupNullableStringField(allocator, obj, "space_id"),
        .version = json.intField(obj, "version") orelse 1,
        .created_at_ms = json.intField(obj, "created_at_ms") orelse 0,
        .updated_at_ms = json.intField(obj, "updated_at_ms") orelse 0,
        .last_verified_at_ms = optionalIntField(obj, "last_verified_at_ms"),
        .scope = try dupStringField(allocator, obj, "scope", "workspace"),
        .source_ids_json = try rawJsonField(allocator, obj, "source_ids_json", "[]"),
        .related_entities_json = try rawJsonField(allocator, obj, "related_entities_json", "[]"),
        .permissions_json = try rawJsonField(allocator, obj, "permissions_json", "[]"),
        .fields_json = try rawJsonField(allocator, obj, "fields_json", "{}"),
        .summary = try dupNullableStringField(allocator, obj, "summary"),
        .agent_summary = try dupNullableStringField(allocator, obj, "agent_summary"),
    };
}

pub fn readEntity(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !domain.Entity {
    return .{
        .id = try dupStringField(allocator, obj, "id", ""),
        .entity_type = try dupStringField(allocator, obj, "type", "concept"),
        .name = try dupStringField(allocator, obj, "name", ""),
        .aliases_json = try rawJsonField(allocator, obj, "aliases_json", "[]"),
        .description = try dupNullableStringField(allocator, obj, "description"),
        .canonical_artifact_id = try dupNullableStringField(allocator, obj, "canonical_artifact_id"),
        .scope = try dupStringField(allocator, obj, "scope", "workspace"),
        .permissions_json = try rawJsonField(allocator, obj, "permissions_json", "[]"),
        .metadata_json = try rawJsonField(allocator, obj, "metadata_json", "{}"),
        .created_at_ms = json.intField(obj, "created_at_ms") orelse 0,
        .updated_at_ms = json.intField(obj, "updated_at_ms") orelse 0,
    };
}

pub fn readRelation(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !domain.Relation {
    return .{
        .id = try dupStringField(allocator, obj, "id", ""),
        .from_entity_id = try dupStringField(allocator, obj, "from_entity_id", ""),
        .relation_type = try dupStringField(allocator, obj, "relation_type", ""),
        .to_entity_id = try dupStringField(allocator, obj, "to_entity_id", ""),
        .source_ids_json = try rawJsonField(allocator, obj, "source_ids_json", "[]"),
        .scope = try dupStringField(allocator, obj, "scope", "workspace"),
        .permissions_json = try rawJsonField(allocator, obj, "permissions_json", "[]"),
        .confidence = json.floatField(obj, "confidence") orelse 0.5,
        .status = try dupStringField(allocator, obj, "status", "proposed"),
        .created_at_ms = json.intField(obj, "created_at_ms") orelse 0,
    };
}

pub fn readMemoryAtom(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !domain.MemoryAtom {
    return .{
        .id = try dupStringField(allocator, obj, "id", ""),
        .subject_entity_id = try dupNullableStringField(allocator, obj, "subject_entity_id"),
        .predicate = try dupStringField(allocator, obj, "predicate", "states"),
        .object = try dupStringField(allocator, obj, "object", ""),
        .text = try dupStringField(allocator, obj, "text", ""),
        .scope = try dupStringField(allocator, obj, "scope", "workspace"),
        .confidence = json.floatField(obj, "confidence") orelse 0.5,
        .status = try dupStringField(allocator, obj, "status", "proposed"),
        .source_ids_json = try rawJsonField(allocator, obj, "source_ids_json", "[]"),
        .evidence_ranges_json = try rawJsonField(allocator, obj, "evidence_ranges_json", "[]"),
        .created_by = try dupStringField(allocator, obj, "created_by", "human"),
        .created_at_ms = json.intField(obj, "created_at_ms") orelse 0,
        .valid_from_ms = optionalIntField(obj, "valid_from_ms"),
        .valid_until_ms = optionalIntField(obj, "valid_until_ms"),
        .last_verified_at_ms = optionalIntField(obj, "last_verified_at_ms"),
        .owner = try dupNullableStringField(allocator, obj, "owner"),
        .permissions_json = try rawJsonField(allocator, obj, "permissions_json", "[]"),
        .tags_json = try rawJsonField(allocator, obj, "tags_json", "[]"),
    };
}

pub fn readFeedEvent(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !store_feed.FeedEvent {
    return .{
        .id = json.intField(obj, "id") orelse 0,
        .event_type = try dupStringField(allocator, obj, "event_type", ""),
        .operation = try dupStringField(allocator, obj, "operation", "put"),
        .object_type = try dupStringField(allocator, obj, "object_type", ""),
        .object_id = try dupStringField(allocator, obj, "object_id", ""),
        .scope = try dupStringField(allocator, obj, "scope", "workspace"),
        .permissions_json = try rawJsonField(allocator, obj, "permissions_json", "[]"),
        .actor_id = try dupNullableStringField(allocator, obj, "actor_id"),
        .dedupe_key = try dupNullableStringField(allocator, obj, "dedupe_key"),
        .causality_json = try rawJsonField(allocator, obj, "causality_json", "{}"),
        .payload_json = try rawJsonField(allocator, obj, "payload_json", "{}"),
        .status = try dupStringField(allocator, obj, "status", "pending"),
        .created_at_ms = json.intField(obj, "created_at_ms") orelse 0,
        .applied_at_ms = optionalIntField(obj, "applied_at_ms"),
        .compacted_at_ms = optionalIntField(obj, "compacted_at_ms"),
    };
}

pub fn readAgentMemory(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !domain.AgentMemory {
    return .{
        .id = try dupStringField(allocator, obj, "id", ""),
        .key = try dupStringField(allocator, obj, "key", ""),
        .content = try dupStringField(allocator, obj, "content", ""),
        .category = try dupStringField(allocator, obj, "category", "core"),
        .timestamp = try std.fmt.allocPrint(allocator, "{d}", .{json.intField(obj, "timestamp_ms") orelse 0}),
        .session_id = try dupNullableStringField(allocator, obj, "session_id"),
        .actor_id = try dupStringField(allocator, obj, "actor_id", ""),
        .writer_actor_id = try dupStringField(allocator, obj, "writer_actor_id", json.stringField(obj, "actor_id") orelse ""),
        .scope = try dupStringField(allocator, obj, "scope", "personal"),
        .permissions_json = try rawJsonField(allocator, obj, "permissions_json", "[]"),
        .status = try dupStringField(allocator, obj, "status", "proposed"),
        .score = json.floatField(obj, "score"),
    };
}

pub fn readJob(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !store_job.Job {
    return .{
        .id = try dupStringField(allocator, obj, "id", ""),
        .job_type = try dupStringField(allocator, obj, "job_type", ""),
        .status = try dupStringField(allocator, obj, "status", "queued"),
        .scope = try dupStringField(allocator, obj, "scope", "workspace"),
        .permissions_json = try rawJsonField(allocator, obj, "permissions_json", "[]"),
        .object_type = try dupStringField(allocator, obj, "object_type", ""),
        .object_id = try dupStringField(allocator, obj, "object_id", ""),
        .input_json = try rawJsonField(allocator, obj, "input_json", "{}"),
        .result_json = try rawJsonField(allocator, obj, "result_json", "{}"),
        .error_text = try dupNullableStringField(allocator, obj, "error_text"),
        .attempts = json.intField(obj, "attempts") orelse 0,
        .created_at_ms = json.intField(obj, "created_at_ms") orelse 0,
        .updated_at_ms = json.intField(obj, "updated_at_ms") orelse 0,
        .locked_until_ms = json.intField(obj, "locked_until_ms"),
        .worker_id = try dupNullableStringField(allocator, obj, "worker_id"),
    };
}

pub fn readConnectorCursor(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !store_connector_cursor.Cursor {
    return .{
        .connector = try dupStringField(allocator, obj, "connector", ""),
        .scope = try dupStringField(allocator, obj, "scope", "workspace"),
        .cursor = try dupStringField(allocator, obj, "cursor", ""),
        .config_json = try rawJsonField(allocator, obj, "config_json", "{}"),
        .permissions_json = try rawJsonField(allocator, obj, "permissions_json", "[]"),
        .updated_at_ms = json.intField(obj, "updated_at_ms") orelse 0,
    };
}

pub fn readConflict(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !store_conflict.Conflict {
    return .{
        .id = try dupStringField(allocator, obj, "id", ""),
        .conflict_type = try dupStringField(allocator, obj, "conflict_type", ""),
        .object_a_type = try dupStringField(allocator, obj, "object_a_type", ""),
        .object_a_id = try dupStringField(allocator, obj, "object_a_id", ""),
        .object_b_type = try dupStringField(allocator, obj, "object_b_type", ""),
        .object_b_id = try dupStringField(allocator, obj, "object_b_id", ""),
        .scope = try dupStringField(allocator, obj, "scope", "workspace"),
        .permissions_json = try rawJsonField(allocator, obj, "permissions_json", "[]"),
        .status = try dupStringField(allocator, obj, "status", "open"),
        .summary = try dupStringField(allocator, obj, "summary", ""),
        .created_at_ms = json.intField(obj, "created_at_ms") orelse 0,
        .resolved_at_ms = optionalIntField(obj, "resolved_at_ms"),
    };
}

pub fn readVectorOutboxEntry(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !store_vector.OutboxEntry {
    return .{
        .id = json.intField(obj, "id") orelse 0,
        .action = try dupStringField(allocator, obj, "action", ""),
        .object_type = try dupStringField(allocator, obj, "object_type", ""),
        .object_id = try dupStringField(allocator, obj, "object_id", ""),
        .status = try dupStringField(allocator, obj, "status", ""),
        .attempts = json.intField(obj, "attempts") orelse 0,
        .payload_json = try rawJsonField(allocator, obj, "payload_json", "{}"),
        .created_at_ms = json.intField(obj, "created_at_ms") orelse 0,
        .updated_at_ms = json.intField(obj, "updated_at_ms") orelse 0,
        .locked_until_ms = optionalIntField(obj, "locked_until_ms"),
        .worker_id = try dupNullableStringField(allocator, obj, "worker_id"),
    };
}

test "postgres row readers keep nullable and raw json defaults" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"id":"src_1","title":"Spec","permissions_json":["team"],"metadata_json":null,"imported_at_ms":42}
    , .{});
    defer parsed.deinit();

    const source = try readSource(allocator, parsed.value.object);
    defer {
        allocator.free(source.id);
        allocator.free(source.source_type);
        allocator.free(source.title);
        allocator.free(source.content);
        allocator.free(source.participants_json);
        allocator.free(source.permissions_json);
        allocator.free(source.scope);
        allocator.free(source.related_entities_json);
        allocator.free(source.metadata_json);
    }

    try std.testing.expectEqualStrings("manual", source.source_type);
    try std.testing.expectEqualStrings("[\"team\"]", source.permissions_json);
    try std.testing.expectEqualStrings("{}", source.metadata_json);
    try std.testing.expectEqual(@as(i64, 42), source.imported_at_ms);
}

test "postgres row raw json fields accept encoded JSON strings and reject malformed aliases" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"permissions_json":"[\"team\"]","payload_json":"{\"key\":\"pg\"}","nullable_json":null,"blank_json":" \t ","bad_json":"{\"broken\":","bad_permissions_json":"{\"scope\":\"team\"}","bad_payload_json":["not-object"],"bad_metadata_json":"[\"not-object\"]"}
    , .{});
    defer parsed.deinit();

    const permissions = try rawJsonField(allocator, parsed.value.object, "permissions_json", "[]");
    defer allocator.free(permissions);
    try std.testing.expectEqualStrings("[\"team\"]", permissions);

    const payload = try rawJsonField(allocator, parsed.value.object, "payload_json", "{}");
    defer allocator.free(payload);
    try std.testing.expectEqualStrings("{\"key\":\"pg\"}", payload);

    try std.testing.expectError(error.InvalidRawJson, rawJsonField(allocator, parsed.value.object, "bad_json", "{}"));
    try std.testing.expectError(error.InvalidRawJson, rawJsonField(allocator, parsed.value.object, "bad_permissions_json", "[]"));
    try std.testing.expectError(error.InvalidRawJson, rawJsonField(allocator, parsed.value.object, "bad_payload_json", "{}"));
    try std.testing.expectError(error.InvalidRawJson, rawJsonField(allocator, parsed.value.object, "bad_metadata_json", "{}"));
    try std.testing.expectError(error.InvalidRawJson, rawJsonField(allocator, parsed.value.object, "missing_json", "{\"broken\":"));
    try std.testing.expectError(error.InvalidRawJson, rawJsonField(allocator, parsed.value.object, "nullable_json", "{\"broken\":"));
    try std.testing.expectError(error.InvalidRawJson, rawJsonField(allocator, parsed.value.object, "blank_json", "{\"broken\":"));
}
