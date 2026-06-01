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

pub fn entityToAgentMemory(allocator: std.mem.Allocator, entity: domain.Entity, actor_id: []const u8) !domain.AgentMemory {
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
        .store = try allocator.dupe(u8, "kg"),
        .score = null,
    };
}
