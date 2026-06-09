const std = @import("std");
const access = @import("access.zig");
const json = @import("json_util.zig");
const vector = @import("vector.zig");
const vector_key_codec = @import("vector_key_codec.zig");
const vector_runtime = @import("vector_runtime.zig");
const store_types = @import("store_types.zig");

pub const ChunkInput = store_types.VectorChunkInput;
pub const Chunk = store_types.VectorChunk;
pub const SearchInput = store_types.VectorSearchInput;
pub const OutboxInput = store_types.VectorOutboxInput;
pub const OutboxListInput = store_types.VectorOutboxListInput;
pub const MaintenanceInput = store_types.VectorMaintenanceInput;

pub fn makeChunkId(allocator: std.mem.Allocator, object_type: []const u8, object_id: []const u8, chunk_ordinal: i64) ![]u8 {
    return vector_key_codec.encodeChunkId(allocator, object_type, object_id, chunk_ordinal);
}

pub fn makeCanonicalChunkId(allocator: std.mem.Allocator, object_type: []const u8, object_id: []const u8, chunk_ordinal: i64) ![]u8 {
    return makeChunkId(allocator, object_type, object_id, chunk_ordinal);
}

pub const SQLiteAnnStats = struct {
    enabled: bool = false,
    candidate_multiplier: u32 = vector_runtime.default_sqlite_ann_candidate_multiplier,
    min_candidates: u32 = vector_runtime.default_sqlite_ann_min_candidates,
    indexed_chunks: usize = 0,
    missing_chunks: usize = 0,
    stale_chunks: usize = 0,
    orphan_rows: usize = 0,
};

pub const ObjectAcl = struct {
    scope: []const u8,
    permissions_json: []const u8,
};

pub fn freeObjectAcl(allocator: std.mem.Allocator, acl: *ObjectAcl) void {
    allocator.free(acl.scope);
    allocator.free(acl.permissions_json);
    acl.* = undefined;
}

pub fn copyObjectAcl(allocator: std.mem.Allocator, scope: []const u8, permissions_json: []const u8) !ObjectAcl {
    const scope_copy = try allocator.dupe(u8, scope);
    errdefer allocator.free(scope_copy);
    const permissions_copy = try allocator.dupe(u8, permissions_json);
    return .{ .scope = scope_copy, .permissions_json = permissions_copy };
}

pub const acl_fail_closed_gate = "__nullpantry_vector_acl_requires_canonical_hydrate__";

pub fn failClosedObjectAcl(allocator: std.mem.Allocator) !ObjectAcl {
    return copyObjectAcl(allocator, acl_fail_closed_gate, "[]");
}

pub fn objectAclFromRequiredAccessJson(allocator: std.mem.Allocator, required_access_json: []const u8) !ObjectAcl {
    const scope = try access.scopeFromRequiredScopesJson(allocator, required_access_json);
    if (std.mem.eql(u8, scope, access.malformed_required_scopes_gate)) {
        allocator.free(scope);
        return failClosedObjectAcl(allocator);
    }
    errdefer allocator.free(scope);

    const permissions_json = try access.permissionsJsonFromRequiredAccessJson(allocator, scope, required_access_json);
    errdefer allocator.free(permissions_json);
    return .{ .scope = scope, .permissions_json = permissions_json };
}

pub const OutboxEntry = struct {
    id: i64,
    action: []const u8,
    object_type: []const u8,
    object_id: []const u8,
    status: []const u8,
    attempts: i64,
    payload_json: []const u8,
    created_at_ms: i64,
    updated_at_ms: i64,
    locked_until_ms: ?i64 = null,
    worker_id: ?[]const u8 = null,
};

pub fn freeOutboxEntry(allocator: std.mem.Allocator, entry: *OutboxEntry) void {
    if (entry.action.len > 0) allocator.free(entry.action);
    if (entry.object_type.len > 0) allocator.free(entry.object_type);
    if (entry.object_id.len > 0) allocator.free(entry.object_id);
    if (entry.status.len > 0) allocator.free(entry.status);
    if (entry.payload_json.len > 0) allocator.free(entry.payload_json);
    if (entry.worker_id) |value| allocator.free(value);
    entry.* = .{
        .id = 0,
        .action = "",
        .object_type = "",
        .object_id = "",
        .status = "",
        .attempts = 0,
        .payload_json = "",
        .created_at_ms = 0,
        .updated_at_ms = 0,
        .locked_until_ms = null,
        .worker_id = null,
    };
}

pub fn freeOutboxEntries(allocator: std.mem.Allocator, entries: []OutboxEntry) void {
    for (entries) |*entry| freeOutboxEntry(allocator, entry);
    allocator.free(entries);
}

pub const OutboxRunResult = struct {
    processed: usize = 0,
    failed: usize = 0,
};

pub const MaintenanceResult = struct {
    canonical_chunks: usize = 0,
    enqueued_upserts: usize = 0,
    requeued_failed: usize = 0,
    external_enabled: bool = false,
};

pub fn upsertPayloadJson(allocator: std.mem.Allocator, vector_id: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"vector_id\":");
    try json.appendString(&out, allocator, vector_id);
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

pub fn idFromOutboxPayload(allocator: std.mem.Allocator, payload_json: []const u8) ![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{}) catch return error.InvalidVectorOutboxPayload;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidVectorOutboxPayload;
    const vector_id = json.stringField(parsed.value.object, "vector_id") orelse return error.InvalidVectorOutboxPayload;
    return allocator.dupe(u8, vector_id);
}

pub fn matchedText(match: vector.VectorMatch, fallback: []const u8) []const u8 {
    return if (match.text.len > 0) match.text else fallback;
}

pub fn matchedTextOwned(allocator: std.mem.Allocator, match: vector.VectorMatch, fallback: []const u8) ![]const u8 {
    return allocator.dupe(u8, matchedText(match, fallback));
}

pub fn headingPathJsonOwned(allocator: std.mem.Allocator, match: vector.VectorMatch) ![]const u8 {
    return allocator.dupe(u8, match.heading_path_json);
}

pub fn deinitRecord(allocator: std.mem.Allocator, record: *vector.VectorRecord) void {
    allocator.free(record.id);
    allocator.free(record.object_id);
    allocator.free(record.object_type);
    allocator.free(record.text);
    allocator.free(record.scope);
    allocator.free(record.heading_path_json);
    allocator.free(record.content_hash);
    allocator.free(record.chunk_strategy);
    if (record.transcript_timestamp) |value| allocator.free(value);
    if (record.transcript_speaker) |value| allocator.free(value);
    allocator.free(record.embedding);
    record.* = undefined;
}

pub fn deinitRecords(allocator: std.mem.Allocator, records: []vector.VectorRecord) void {
    for (records) |*record| deinitRecord(allocator, record);
}

pub fn sqliteAnnCandidateLimit(limit: usize, candidate_multiplier: u32, min_candidates: u32) usize {
    if (limit == 0) return 0;
    const multiplier: usize = vector_runtime.normalizeSqliteAnnCandidateMultiplier(candidate_multiplier);
    const minimum: usize = vector_runtime.normalizeSqliteAnnMinCandidates(min_candidates);
    return @max(limit, @max(minimum, limit *| multiplier));
}

pub fn deinitChunk(allocator: std.mem.Allocator, chunk: *Chunk) void {
    allocator.free(chunk.id);
    allocator.free(chunk.object_type);
    allocator.free(chunk.object_id);
    allocator.free(chunk.text);
    allocator.free(chunk.scope);
    allocator.free(chunk.permissions_json);
    allocator.free(chunk.heading_path_json);
    allocator.free(chunk.content_hash);
    allocator.free(chunk.chunk_strategy);
    if (chunk.transcript_timestamp) |value| allocator.free(value);
    if (chunk.transcript_speaker) |value| allocator.free(value);
    allocator.free(chunk.embedding_json);
    if (chunk.model) |model| allocator.free(model);
    chunk.* = undefined;
}

pub fn matchFromChunk(allocator: std.mem.Allocator, chunk: Chunk, score: f32) !vector.VectorMatch {
    var match = vector.VectorMatch{
        .id = try allocator.dupe(u8, chunk.id),
        .object_id = "",
        .object_type = "",
        .text = "",
        .scope = "",
        .heading_path_json = "",
        .content_hash = "",
        .chunk_strategy = "",
        .score = score,
    };
    errdefer vector.deinitMatch(allocator, &match);
    match.object_id = try allocator.dupe(u8, chunk.object_id);
    match.object_type = try allocator.dupe(u8, chunk.object_type);
    match.text = try allocator.dupe(u8, chunk.text);
    match.scope = try allocator.dupe(u8, chunk.scope);
    match.heading_path_json = try allocator.dupe(u8, chunk.heading_path_json);
    match.start_byte = chunk.start_byte;
    match.end_byte = chunk.end_byte;
    match.content_hash = try allocator.dupe(u8, chunk.content_hash);
    match.chunk_strategy = try allocator.dupe(u8, chunk.chunk_strategy);
    match.estimated_tokens = chunk.estimated_tokens;
    match.transcript_timestamp = if (chunk.transcript_timestamp) |value| try allocator.dupe(u8, value) else null;
    match.transcript_speaker = if (chunk.transcript_speaker) |value| try allocator.dupe(u8, value) else null;
    return match;
}

pub fn upsertInputFromChunk(chunk: Chunk) vector_runtime.UpsertInput {
    return .{
        .id = chunk.id,
        .object_type = chunk.object_type,
        .object_id = chunk.object_id,
        .chunk_ordinal = chunk.chunk_ordinal,
        .text = chunk.text,
        .scope = chunk.scope,
        .permissions_json = chunk.permissions_json,
        .heading_path_json = chunk.heading_path_json,
        .start_byte = chunk.start_byte,
        .end_byte = chunk.end_byte,
        .content_hash = chunk.content_hash,
        .chunk_strategy = chunk.chunk_strategy,
        .estimated_tokens = chunk.estimated_tokens,
        .transcript_timestamp = chunk.transcript_timestamp,
        .transcript_speaker = chunk.transcript_speaker,
        .embedding_json = chunk.embedding_json,
        .model = chunk.model,
        .dimensions = chunk.dimensions,
    };
}

test "store vector required access acl projection is exact or fail closed" {
    const allocator = std.testing.allocator;

    var public_acl = try objectAclFromRequiredAccessJson(allocator, "[]");
    defer freeObjectAcl(allocator, &public_acl);
    try std.testing.expectEqualStrings("public", public_acl.scope);
    try std.testing.expectEqualStrings("[]", public_acl.permissions_json);

    var scoped_acl = try objectAclFromRequiredAccessJson(allocator, "[\"project:acl\"]");
    defer freeObjectAcl(allocator, &scoped_acl);
    try std.testing.expectEqualStrings("project:acl", scoped_acl.scope);
    try std.testing.expectEqualStrings("[]", scoped_acl.permissions_json);

    var gated_acl = try objectAclFromRequiredAccessJson(allocator, "[\"project:acl\",\"team:acl\",\"team:acl\"]");
    defer freeObjectAcl(allocator, &gated_acl);
    try std.testing.expectEqualStrings("project:acl", gated_acl.scope);
    try std.testing.expectEqualStrings("[\"team:acl\"]", gated_acl.permissions_json);

    var complex_acl = try objectAclFromRequiredAccessJson(allocator, "[\"project:acl\",\"team:acl\",\"env:prod\"]");
    defer freeObjectAcl(allocator, &complex_acl);
    try std.testing.expectEqualStrings("project:acl", complex_acl.scope);
    try std.testing.expectEqualStrings("[\"team:acl\",\"env:prod\"]", complex_acl.permissions_json);

    var malformed_acl = try objectAclFromRequiredAccessJson(allocator, "{\"scope\":\"project:acl\"}");
    defer freeObjectAcl(allocator, &malformed_acl);
    try std.testing.expectEqualStrings(acl_fail_closed_gate, malformed_acl.scope);
    try std.testing.expectEqualStrings("[]", malformed_acl.permissions_json);

    var trailing_malformed_acl = try objectAclFromRequiredAccessJson(allocator, "[\"project:acl\",42]");
    defer freeObjectAcl(allocator, &trailing_malformed_acl);
    try std.testing.expectEqualStrings(acl_fail_closed_gate, trailing_malformed_acl.scope);
    try std.testing.expectEqualStrings("[]", trailing_malformed_acl.permissions_json);

    var empty_gate_acl = try objectAclFromRequiredAccessJson(allocator, "[\"\"]");
    defer freeObjectAcl(allocator, &empty_gate_acl);
    try std.testing.expectEqualStrings(acl_fail_closed_gate, empty_gate_acl.scope);
    try std.testing.expectEqualStrings("[]", empty_gate_acl.permissions_json);
}

test "store vector outbox entry free clears owned fields" {
    const allocator = std.testing.allocator;
    var entry = OutboxEntry{
        .id = 7,
        .action = try allocator.dupe(u8, "upsert"),
        .object_type = try allocator.dupe(u8, "source"),
        .object_id = try allocator.dupe(u8, "src_1"),
        .status = try allocator.dupe(u8, "running"),
        .attempts = 2,
        .payload_json = try allocator.dupe(u8, "{}"),
        .created_at_ms = 10,
        .updated_at_ms = 20,
        .locked_until_ms = 30,
        .worker_id = try allocator.dupe(u8, "worker:one"),
    };

    freeOutboxEntry(allocator, &entry);

    try std.testing.expectEqual(@as(i64, 0), entry.id);
    try std.testing.expectEqualStrings("", entry.action);
    try std.testing.expect(entry.worker_id == null);
}

test "store vector outbox payload round trips vector id" {
    const allocator = std.testing.allocator;

    const payload = try upsertPayloadJson(allocator, "vec:1");
    defer allocator.free(payload);
    try std.testing.expectEqualStrings("{\"vector_id\":\"vec:1\"}", payload);

    const vector_id = try idFromOutboxPayload(allocator, payload);
    defer allocator.free(vector_id);
    try std.testing.expectEqualStrings("vec:1", vector_id);

    try std.testing.expectError(error.InvalidVectorOutboxPayload, idFromOutboxPayload(allocator, "[]"));
    try std.testing.expectError(error.InvalidVectorOutboxPayload, idFromOutboxPayload(allocator, "{\"vector\":\"vec:1\"}"));
}

test "store vector sqlite ann candidate limit normalizes inputs" {
    try std.testing.expectEqual(@as(usize, 0), sqliteAnnCandidateLimit(0, 12, 64));
    try std.testing.expectEqual(@as(usize, 100), sqliteAnnCandidateLimit(10, 4, 100));
    try std.testing.expectEqual(@as(usize, 40), sqliteAnnCandidateLimit(10, 4, 1));
}

test "store vector match from chunk owns borrowed chunk fields" {
    const allocator = std.testing.allocator;
    const chunk = Chunk{
        .id = "source:one:0",
        .object_type = "source",
        .object_id = "one",
        .chunk_ordinal = 0,
        .text = "body",
        .scope = "workspace",
        .permissions_json = "[]",
        .heading_path_json = "[\"Title\"]",
        .start_byte = 1,
        .end_byte = 5,
        .content_hash = "hash",
        .chunk_strategy = "paragraph",
        .estimated_tokens = 2,
        .transcript_timestamp = "00:01",
        .transcript_speaker = "speaker",
        .embedding_json = "[0.1]",
        .model = "model",
        .dimensions = 1,
        .created_at_ms = 10,
        .updated_at_ms = 20,
    };

    var match = try matchFromChunk(allocator, chunk, 0.75);
    defer vector.deinitMatch(allocator, &match);

    try std.testing.expectEqualStrings(chunk.id, match.id);
    try std.testing.expectEqualStrings(chunk.object_id, match.object_id);
    try std.testing.expectEqualStrings(chunk.heading_path_json, match.heading_path_json);
    try std.testing.expectEqual(@as(f32, 0.75), match.score);
    try std.testing.expect(match.transcript_timestamp != null);
    try std.testing.expect(match.transcript_speaker != null);
}
