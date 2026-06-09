const std = @import("std");
const domain = @import("domain.zig");
const json = @import("json_util.zig");

pub const entity_store_prefix = "__kg:entity:";
pub const relation_store_prefix = "__kg:rel:";
pub const relation_category = "__kg:relation";

pub const ParsedRelationKey = struct {
    id: []const u8,
    subject_id: []u8,
    predicate: []u8,
    object_id: []u8,

    pub fn deinit(self: ParsedRelationKey, allocator: std.mem.Allocator) void {
        allocator.free(self.subject_id);
        allocator.free(self.predicate);
        allocator.free(self.object_id);
    }
};

pub fn isEntityKey(key: []const u8) bool {
    return std.mem.startsWith(u8, key, entity_store_prefix);
}

pub fn isRelationKey(key: []const u8) bool {
    return std.mem.startsWith(u8, key, relation_store_prefix);
}

pub fn isKgKey(key: []const u8) bool {
    return isEntityKey(key) or isRelationKey(key);
}

pub fn entityIdForKey(key: []const u8) []const u8 {
    if (isEntityKey(key)) return key[entity_store_prefix.len..];
    return key;
}

pub fn relationIdForKey(key: []const u8) []const u8 {
    if (isRelationKey(key)) return key[relation_store_prefix.len..];
    return key;
}

pub fn parseRelationKey(allocator: std.mem.Allocator, key: []const u8) !ParsedRelationKey {
    if (!isRelationKey(key)) return error.InvalidRelationKey;

    const id = relationIdForKey(key);
    var it = std.mem.splitScalar(u8, id, ':');
    const subject_id_enc = it.next() orelse return error.InvalidRelationKey;
    const predicate_enc = it.next() orelse return error.InvalidRelationKey;
    const object_id_enc = it.next() orelse return error.InvalidRelationKey;
    if (it.next() != null) return error.InvalidRelationKey;

    const subject_id = try json.percentDecode(allocator, subject_id_enc);
    errdefer allocator.free(subject_id);
    const predicate = try json.percentDecode(allocator, predicate_enc);
    errdefer allocator.free(predicate);
    const object_id = try json.percentDecode(allocator, object_id_enc);
    errdefer allocator.free(object_id);

    if (subject_id.len == 0 or predicate.len == 0 or object_id.len == 0) return error.InvalidRelationKey;
    return .{
        .id = id,
        .subject_id = subject_id,
        .predicate = predicate,
        .object_id = object_id,
    };
}

pub fn relationStoreKey(allocator: std.mem.Allocator, subject_id: []const u8, predicate: []const u8, object_id: []const u8) ![]u8 {
    const subject_id_enc = try percentEncodeSegment(allocator, subject_id);
    defer allocator.free(subject_id_enc);
    const predicate_enc = try percentEncodeSegment(allocator, predicate);
    defer allocator.free(predicate_enc);
    const object_id_enc = try percentEncodeSegment(allocator, object_id);
    defer allocator.free(object_id_enc);

    return try std.fmt.allocPrint(allocator, relation_store_prefix ++ "{s}:{s}:{s}", .{
        subject_id_enc,
        predicate_enc,
        object_id_enc,
    });
}

pub fn keyPathSegment(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    return try percentEncodeSegment(allocator, key);
}

pub fn traverseQuery(allocator: std.mem.Allocator, entity_id: []const u8, max_depth: usize) ![]u8 {
    const entity_id_enc = try percentEncodeSegment(allocator, entity_id);
    defer allocator.free(entity_id_enc);
    return try std.fmt.allocPrint(allocator, "kg:traverse:{s}:{d}", .{ entity_id_enc, max_depth });
}

pub fn pathQuery(allocator: std.mem.Allocator, from_entity_id: []const u8, to_entity_id: []const u8, max_depth: usize) ![]u8 {
    const from_enc = try percentEncodeSegment(allocator, from_entity_id);
    defer allocator.free(from_enc);
    const to_enc = try percentEncodeSegment(allocator, to_entity_id);
    defer allocator.free(to_enc);
    return try std.fmt.allocPrint(allocator, "kg:path:{s}:{s}:{d}", .{ from_enc, to_enc, max_depth });
}

pub fn relationsQuery(allocator: std.mem.Allocator, entity_id: []const u8) ![]u8 {
    const entity_id_enc = try percentEncodeSegment(allocator, entity_id);
    defer allocator.free(entity_id_enc);
    return try std.fmt.allocPrint(allocator, "kg:relations:{s}", .{entity_id_enc});
}

fn percentEncodeSegment(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    const hex_digits = "0123456789ABCDEF";
    for (raw) |ch| {
        if (isUnreserved(ch)) {
            try out.append(allocator, ch);
        } else {
            try out.append(allocator, '%');
            try out.append(allocator, hex_digits[ch >> 4]);
            try out.append(allocator, hex_digits[ch & 0x0f]);
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn isUnreserved(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~';
}

pub fn entityToAgentMemory(allocator: std.mem.Allocator, entity: domain.Entity, actor_id: []const u8) !domain.AgentMemory {
    return entityToAgentMemoryWithStatus(allocator, entity, actor_id, "active");
}

pub fn entityToAgentMemoryWithStatus(allocator: std.mem.Allocator, entity: domain.Entity, actor_id: []const u8, status: []const u8) !domain.AgentMemory {
    return .{
        .id = try allocator.dupe(u8, entity.id),
        .key = try allocator.dupe(u8, entity.id),
        .content = try allocator.dupe(u8, entity.description orelse entity.name),
        .category = try allocator.dupe(u8, entity.entity_type),
        .timestamp = try std.fmt.allocPrint(allocator, "{d}", .{entity.updated_at_ms}),
        .session_id = null,
        .actor_id = try allocator.dupe(u8, actor_id),
        .writer_actor_id = try allocator.dupe(u8, actor_id),
        .scope = try allocator.dupe(u8, entity.scope),
        .permissions_json = try allocator.dupe(u8, entity.permissions_json),
        .status = try allocator.dupe(u8, status),
        .store = try allocator.dupe(u8, "kg"),
        .score = null,
    };
}

pub fn relationToAgentMemory(allocator: std.mem.Allocator, relation: domain.Relation, actor_id: []const u8) !domain.AgentMemory {
    return .{
        .id = try allocator.dupe(u8, relation.id),
        .key = try std.fmt.allocPrint(allocator, relation_store_prefix ++ "{s}", .{relation.id}),
        .content = try std.fmt.allocPrint(allocator, "{s} --{s}--> {s}", .{ relation.from_entity_id, relation.relation_type, relation.to_entity_id }),
        .category = try allocator.dupe(u8, relation_category),
        .timestamp = try std.fmt.allocPrint(allocator, "{d}", .{relation.created_at_ms}),
        .session_id = null,
        .actor_id = try allocator.dupe(u8, actor_id),
        .writer_actor_id = try allocator.dupe(u8, actor_id),
        .scope = try allocator.dupe(u8, relation.scope),
        .permissions_json = try allocator.dupe(u8, relation.permissions_json),
        .status = try allocator.dupe(u8, relation.status),
        .store = try allocator.dupe(u8, "kg"),
        .score = null,
    };
}

test "kg compat helpers encode reserved relation and query segments" {
    const allocator = std.testing.allocator;
    const relation_key = try relationStoreKey(allocator, "alpha:1", "links:<to>", "beta/2");
    defer allocator.free(relation_key);
    try std.testing.expectEqualStrings("__kg:rel:alpha%3A1:links%3A%3Cto%3E:beta%2F2", relation_key);

    const path_segment = try keyPathSegment(allocator, relation_key);
    defer allocator.free(path_segment);
    try std.testing.expectEqualStrings("__kg%3Arel%3Aalpha%253A1%3Alinks%253A%253Cto%253E%3Abeta%252F2", path_segment);
    const decoded_path_segment = try json.percentDecode(allocator, path_segment);
    defer allocator.free(decoded_path_segment);
    try std.testing.expectEqualStrings(relation_key, decoded_path_segment);

    var parsed = try parseRelationKey(allocator, relation_key);
    defer parsed.deinit(allocator);
    try std.testing.expectEqualStrings("alpha:1", parsed.subject_id);
    try std.testing.expectEqualStrings("links:<to>", parsed.predicate);
    try std.testing.expectEqualStrings("beta/2", parsed.object_id);

    const traverse = try traverseQuery(allocator, "alpha:1", 3);
    defer allocator.free(traverse);
    try std.testing.expectEqualStrings("kg:traverse:alpha%3A1:3", traverse);

    const path = try pathQuery(allocator, "alpha:1", "beta/2", 4);
    defer allocator.free(path);
    try std.testing.expectEqualStrings("kg:path:alpha%3A1:beta%2F2:4", path);

    const relations = try relationsQuery(allocator, "alpha:1");
    defer allocator.free(relations);
    try std.testing.expectEqualStrings("kg:relations:alpha%3A1", relations);
}
