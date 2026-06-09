const std = @import("std");
const bounded_int = @import("bounded_int.zig");
const domain = @import("domain.zig");
const json = @import("json_util.zig");
const store_types = @import("store_types.zig");

pub const ListInput = store_types.ConflictListInput;
const list_limit_max: usize = 500;
const scan_atom_limit_min: usize = 50;
const scan_atom_limit_max: usize = 1000;
const scan_atom_limit_multiplier: usize = 10;

pub const Conflict = struct {
    id: []const u8,
    conflict_type: []const u8,
    object_a_type: []const u8,
    object_a_id: []const u8,
    object_b_type: []const u8,
    object_b_id: []const u8,
    scope: []const u8,
    permissions_json: []const u8,
    status: []const u8,
    summary: []const u8,
    created_at_ms: i64,
    resolved_at_ms: ?i64,

    pub fn writeJson(self: Conflict, allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
        try out.appendSlice(allocator, "{\"id\":");
        try json.appendString(out, allocator, self.id);
        try out.appendSlice(allocator, ",\"type\":");
        try json.appendString(out, allocator, self.conflict_type);
        try out.appendSlice(allocator, ",\"object_a_type\":");
        try json.appendString(out, allocator, self.object_a_type);
        try out.appendSlice(allocator, ",\"object_a_id\":");
        try json.appendString(out, allocator, self.object_a_id);
        try out.appendSlice(allocator, ",\"object_b_type\":");
        try json.appendString(out, allocator, self.object_b_type);
        try out.appendSlice(allocator, ",\"object_b_id\":");
        try json.appendString(out, allocator, self.object_b_id);
        try out.appendSlice(allocator, ",\"scope\":");
        try json.appendString(out, allocator, self.scope);
        try out.appendSlice(allocator, ",\"permissions\":");
        try json.appendRawJsonArray(out, allocator, self.permissions_json);
        try out.appendSlice(allocator, ",\"status\":");
        try json.appendString(out, allocator, self.status);
        try out.appendSlice(allocator, ",\"summary\":");
        try json.appendString(out, allocator, self.summary);
        try out.print(allocator, ",\"created_at_ms\":{d},\"resolved_at_ms\":", .{self.created_at_ms});
        if (self.resolved_at_ms) |v| try out.print(allocator, "{d}", .{v}) else try out.appendSlice(allocator, "null");
        try out.append(allocator, '}');
    }
};

pub fn freeConflict(allocator: std.mem.Allocator, conflict: *Conflict) void {
    if (conflict.id.len > 0) allocator.free(conflict.id);
    if (conflict.conflict_type.len > 0) allocator.free(conflict.conflict_type);
    if (conflict.object_a_type.len > 0) allocator.free(conflict.object_a_type);
    if (conflict.object_a_id.len > 0) allocator.free(conflict.object_a_id);
    if (conflict.object_b_type.len > 0) allocator.free(conflict.object_b_type);
    if (conflict.object_b_id.len > 0) allocator.free(conflict.object_b_id);
    if (conflict.scope.len > 0) allocator.free(conflict.scope);
    if (conflict.permissions_json.len > 0) allocator.free(conflict.permissions_json);
    if (conflict.status.len > 0) allocator.free(conflict.status);
    if (conflict.summary.len > 0) allocator.free(conflict.summary);
    conflict.* = .{
        .id = "",
        .conflict_type = "",
        .object_a_type = "",
        .object_a_id = "",
        .object_b_type = "",
        .object_b_id = "",
        .scope = "",
        .permissions_json = "",
        .status = "",
        .summary = "",
        .created_at_ms = 0,
        .resolved_at_ms = null,
    };
}

pub fn freeConflicts(allocator: std.mem.Allocator, conflicts: []Conflict) void {
    for (conflicts) |*conflict| freeConflict(allocator, conflict);
    allocator.free(conflicts);
}

pub fn sameSubject(a: domain.MemoryAtom, b: domain.MemoryAtom) bool {
    if (!std.mem.eql(u8, a.scope, b.scope)) return false;
    if (!std.mem.eql(u8, a.predicate, b.predicate)) return false;
    if (a.subject_entity_id != null and b.subject_entity_id != null) return std.mem.eql(u8, a.subject_entity_id.?, b.subject_entity_id.?);
    return true;
}

pub fn listLimit(limit: usize) usize {
    return @max(@as(usize, 1), @min(limit, list_limit_max));
}

pub fn scanAtomLimit(limit: usize) usize {
    const expanded = bounded_int.saturatingUsizeMul(limit, scan_atom_limit_multiplier);
    return @max(scan_atom_limit_min, @min(expanded, scan_atom_limit_max));
}

test "store conflict json contract is stable" {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try (Conflict{
        .id = "cnf_1",
        .conflict_type = "memory_atom_conflict",
        .object_a_type = "memory_atom",
        .object_a_id = "a",
        .object_b_type = "memory_atom",
        .object_b_id = "b",
        .scope = "project:alpha",
        .permissions_json = "[\"project:alpha\"]",
        .status = "open",
        .summary = "Potential conflict",
        .created_at_ms = 42,
        .resolved_at_ms = null,
    }).writeJson(std.testing.allocator, &out);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"permissions\":[\"project:alpha\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"resolved_at_ms\":null") != null);
}

test "store conflict json contract enforces permissions array root" {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidRawJson, (Conflict{
        .id = "cnf_bad_raw",
        .conflict_type = "memory_atom_conflict",
        .object_a_type = "memory_atom",
        .object_a_id = "a",
        .object_b_type = "memory_atom",
        .object_b_id = "b",
        .scope = "project:alpha",
        .permissions_json = "{\"scope\":\"project:alpha\"}",
        .status = "open",
        .summary = "Potential conflict",
        .created_at_ms = 42,
        .resolved_at_ms = null,
    }).writeJson(std.testing.allocator, &out));
}

test "store conflict subject matching scopes predicate and subject ids" {
    const a: domain.MemoryAtom = .{
        .id = "a",
        .subject_entity_id = "entity:one",
        .predicate = "likes",
        .object = "zig",
        .text = "A likes Zig",
        .scope = "project:alpha",
        .confidence = 0.8,
        .status = "verified",
        .source_ids_json = "[]",
        .evidence_ranges_json = "[]",
        .created_by = "tester",
        .created_at_ms = 1,
        .valid_from_ms = null,
        .valid_until_ms = null,
        .last_verified_at_ms = null,
        .owner = null,
        .permissions_json = "[]",
        .tags_json = "[]",
    };
    var b = a;
    b.id = "b";
    b.object = "rust";
    try std.testing.expect(sameSubject(a, b));
    b.subject_entity_id = "entity:two";
    try std.testing.expect(!sameSubject(a, b));
    b.subject_entity_id = null;
    try std.testing.expect(sameSubject(a, b));
    b.predicate = "dislikes";
    try std.testing.expect(!sameSubject(a, b));
}

test "store conflict list and scan limits are bounded without overflow" {
    try std.testing.expectEqual(@as(usize, 1), listLimit(0));
    try std.testing.expectEqual(@as(usize, 42), listLimit(42));
    try std.testing.expectEqual(list_limit_max, listLimit(std.math.maxInt(usize)));

    try std.testing.expectEqual(scan_atom_limit_min, scanAtomLimit(0));
    try std.testing.expectEqual(scan_atom_limit_min, scanAtomLimit(1));
    try std.testing.expectEqual(@as(usize, 500), scanAtomLimit(50));
    try std.testing.expectEqual(scan_atom_limit_max, scanAtomLimit(200));
    try std.testing.expectEqual(scan_atom_limit_max, scanAtomLimit(std.math.maxInt(usize)));
}
