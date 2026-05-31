const std = @import("std");
const json = @import("json_util.zig");

pub const Direction = enum {
    both,
    outbound,
    inbound,
};

pub const CommandKind = enum {
    traverse,
    path,
    relations,
};

pub const Command = struct {
    kind: CommandKind,
    entity_id: ?[]u8 = null,
    from_entity_id: ?[]u8 = null,
    to_entity_id: ?[]u8 = null,
    max_depth: usize = 1,

    pub fn deinit(self: *Command, allocator: std.mem.Allocator) void {
        if (self.entity_id) |value| allocator.free(value);
        if (self.from_entity_id) |value| allocator.free(value);
        if (self.to_entity_id) |value| allocator.free(value);
        self.* = .{ .kind = .traverse };
    }
};

pub const RelationTypeSpec = struct {
    name: []const u8,
    directed: bool = true,
    from_types: []const []const u8 = &[_][]const u8{},
    to_types: []const []const u8 = &[_][]const u8{},
    description: []const u8 = "",
};

pub const relation_type_specs = [_]RelationTypeSpec{
    .{ .name = "related_to", .directed = false, .description = "Generic symmetric relation for weak or unknown links." },
    .{ .name = "depends_on", .description = "The source entity requires the target entity." },
    .{ .name = "implements", .from_types = &[_][]const u8{ "ticket", "feature", "pr", "commit", "repo", "service", "agent", "task" }, .to_types = &[_][]const u8{ "decision", "spec", "feature", "api", "service", "concept" }, .description = "The source entity implements the target decision, spec, feature, or API." },
    .{ .name = "produced", .from_types = &[_][]const u8{ "meeting", "incident", "event", "agent", "task" }, .to_types = &[_][]const u8{ "decision", "ticket", "artifact", "memory_atom", "concept" }, .description = "The source entity produced the target knowledge object." },
    .{ .name = "supersedes", .from_types = &[_][]const u8{ "decision", "artifact", "memory_atom", "relation", "entity", "spec", "runbook" }, .to_types = &[_][]const u8{ "decision", "artifact", "memory_atom", "relation", "entity", "spec", "runbook" }, .description = "The source entity replaces the target entity." },
    .{ .name = "documents", .from_types = &[_][]const u8{ "document", "page", "artifact", "runbook", "recipe", "spec", "repo", "project", "service" }, .to_types = &[_][]const u8{ "service", "project", "api", "feature", "concept", "team" }, .description = "The source entity documents the target entity." },
    .{ .name = "affected", .from_types = &[_][]const u8{ "decision", "incident", "event", "change", "release" }, .to_types = &[_][]const u8{ "service", "api", "project", "feature", "customer", "repo" }, .description = "The source event, decision, or change affected the target entity." },
    .{ .name = "fixes", .from_types = &[_][]const u8{ "pr", "commit", "ticket", "change" }, .to_types = &[_][]const u8{ "ticket", "incident", "bug", "issue", "service" }, .description = "The source entity fixes the target entity." },
    .{ .name = "belongs_to", .from_types = &[_][]const u8{ "runbook", "recipe", "service", "repo", "api", "feature", "ticket" }, .to_types = &[_][]const u8{ "service", "project", "team", "organization" }, .description = "The source entity belongs to the target entity." },
    .{ .name = "owns", .from_types = &[_][]const u8{ "person", "team", "agent" }, .to_types = &[_][]const u8{ "project", "service", "ticket", "decision", "feature", "runbook", "repo", "api" }, .description = "The source actor owns the target entity." },
    .{ .name = "used_context_pack", .from_types = &[_][]const u8{ "agent", "task", "ticket", "workflow" }, .to_types = &[_][]const u8{"context_pack"}, .description = "The source entity used the target context pack." },
};

pub fn parseDirection(value: ?[]const u8) !Direction {
    const raw = value orelse return .both;
    if (std.ascii.eqlIgnoreCase(raw, "both") or std.ascii.eqlIgnoreCase(raw, "any")) return .both;
    if (std.ascii.eqlIgnoreCase(raw, "outbound") or std.ascii.eqlIgnoreCase(raw, "out") or std.ascii.eqlIgnoreCase(raw, "forward")) return .outbound;
    if (std.ascii.eqlIgnoreCase(raw, "inbound") or std.ascii.eqlIgnoreCase(raw, "in") or std.ascii.eqlIgnoreCase(raw, "reverse")) return .inbound;
    return error.InvalidGraphDirection;
}

pub fn directionName(direction: Direction) []const u8 {
    return switch (direction) {
        .both => "both",
        .outbound => "outbound",
        .inbound => "inbound",
    };
}

pub fn parseCommand(allocator: std.mem.Allocator, raw: []const u8) !?Command {
    const query = std.mem.trim(u8, raw, " \t\r\n");
    if (commandPayload(query, "kg:traverse:") orelse commandPayload(query, "graph:traverse:")) |payload| {
        return try parseTraverseCommand(allocator, payload);
    }
    if (commandPayload(query, "kg:path:") orelse commandPayload(query, "graph:path:")) |payload| {
        return try parsePathCommand(allocator, payload);
    }
    if (commandPayload(query, "kg:relations:") orelse commandPayload(query, "graph:relations:")) |payload| {
        return try parseRelationsCommand(allocator, payload);
    }
    return null;
}

fn commandPayload(query: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, query, prefix)) return null;
    return query[prefix.len..];
}

fn parseTraverseCommand(allocator: std.mem.Allocator, payload: []const u8) !Command {
    const depth_sep = std.mem.lastIndexOfScalar(u8, payload, ':') orelse return error.InvalidGraphCommand;
    if (depth_sep == 0 or depth_sep + 1 >= payload.len) return error.InvalidGraphCommand;
    return .{
        .kind = .traverse,
        .entity_id = try decodeCommandSegment(allocator, payload[0..depth_sep]),
        .max_depth = try parseCommandDepth(payload[depth_sep + 1 ..]),
    };
}

fn parsePathCommand(allocator: std.mem.Allocator, payload: []const u8) !Command {
    var it = std.mem.splitScalar(u8, payload, ':');
    const from_raw = it.next() orelse return error.InvalidGraphCommand;
    const to_raw = it.next() orelse return error.InvalidGraphCommand;
    const depth_raw = it.next() orelse return error.InvalidGraphCommand;
    if (it.next() != null or from_raw.len == 0 or to_raw.len == 0 or depth_raw.len == 0) return error.InvalidGraphCommand;
    return .{
        .kind = .path,
        .from_entity_id = try decodeCommandSegment(allocator, from_raw),
        .to_entity_id = try decodeCommandSegment(allocator, to_raw),
        .max_depth = try parseCommandDepth(depth_raw),
    };
}

fn parseRelationsCommand(allocator: std.mem.Allocator, payload: []const u8) !Command {
    if (payload.len == 0 or std.mem.indexOfScalar(u8, payload, ':') != null) return error.InvalidGraphCommand;
    return .{
        .kind = .relations,
        .entity_id = try decodeCommandSegment(allocator, payload),
        .max_depth = 1,
    };
}

fn decodeCommandSegment(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    const decoded = try json.percentDecode(allocator, value);
    errdefer allocator.free(decoded);
    if (decoded.len == 0) return error.InvalidGraphCommand;
    return decoded;
}

fn parseCommandDepth(value: []const u8) !usize {
    const parsed = std.fmt.parseInt(usize, value, 10) catch return error.InvalidGraphCommand;
    if (parsed == 0) return error.InvalidGraphCommand;
    return parsed;
}

pub fn canonicalRelationType(value: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(value, "related") or std.ascii.eqlIgnoreCase(value, "relates_to") or std.ascii.eqlIgnoreCase(value, "touches")) return "related_to";
    if (std.ascii.eqlIgnoreCase(value, "depends") or std.ascii.eqlIgnoreCase(value, "requires") or std.ascii.eqlIgnoreCase(value, "uses")) return "depends_on";
    if (std.ascii.eqlIgnoreCase(value, "created") or std.ascii.eqlIgnoreCase(value, "creates") or std.ascii.eqlIgnoreCase(value, "generated")) return "produced";
    if (std.ascii.eqlIgnoreCase(value, "replaces") or std.ascii.eqlIgnoreCase(value, "supersede")) return "supersedes";
    if (std.ascii.eqlIgnoreCase(value, "doc") or std.ascii.eqlIgnoreCase(value, "describes")) return "documents";
    if (std.ascii.eqlIgnoreCase(value, "affects") or std.ascii.eqlIgnoreCase(value, "impacts") or std.ascii.eqlIgnoreCase(value, "impacted")) return "affected";
    if (std.ascii.eqlIgnoreCase(value, "fixed")) return "fixes";
    if (std.ascii.eqlIgnoreCase(value, "part_of")) return "belongs_to";
    return value;
}

pub fn relationTypeSpec(relation_type: []const u8) ?RelationTypeSpec {
    const canonical = canonicalRelationType(relation_type);
    for (relation_type_specs) |spec| {
        if (std.ascii.eqlIgnoreCase(spec.name, canonical)) return spec;
    }
    return null;
}

pub fn validateRelationShape(relation_type: []const u8, from_type: []const u8, to_type: []const u8) !void {
    const spec = relationTypeSpec(relation_type) orelse return;
    if (!typeAllowed(spec.from_types, from_type) or !typeAllowed(spec.to_types, to_type)) return error.InvalidRelationSchema;
}

pub fn relationMatchesTypeFilter(relation_type: []const u8, allowed: []const []const u8) bool {
    if (allowed.len == 0) return true;
    const canonical = canonicalRelationType(relation_type);
    for (allowed) |item| {
        if (std.ascii.eqlIgnoreCase(canonical, canonicalRelationType(item))) return true;
    }
    return false;
}

pub fn entityMatchesTypeFilter(entity_type: []const u8, allowed: []const []const u8) bool {
    if (allowed.len == 0) return true;
    for (allowed) |item| {
        if (std.ascii.eqlIgnoreCase(entity_type, item)) return true;
    }
    return false;
}

pub fn otherEntityIdForDirection(from_entity_id: []const u8, to_entity_id: []const u8, current_entity_id: []const u8, direction: Direction) ?[]const u8 {
    return switch (direction) {
        .outbound => if (std.mem.eql(u8, from_entity_id, current_entity_id)) to_entity_id else null,
        .inbound => if (std.mem.eql(u8, to_entity_id, current_entity_id)) from_entity_id else null,
        .both => blk: {
            if (std.mem.eql(u8, from_entity_id, current_entity_id)) break :blk to_entity_id;
            if (std.mem.eql(u8, to_entity_id, current_entity_id)) break :blk from_entity_id;
            break :blk null;
        },
    };
}

pub fn appendSchemaJson(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    try out.appendSlice(allocator, "{\"relation_types\":[");
    for (relation_type_specs, 0..) |spec, i| {
        if (i > 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, "{\"name\":");
        try json.appendString(out, allocator, spec.name);
        try out.appendSlice(allocator, ",\"directed\":");
        try out.appendSlice(allocator, if (spec.directed) "true" else "false");
        try out.appendSlice(allocator, ",\"from_types\":");
        try appendStringArray(allocator, out, spec.from_types);
        try out.appendSlice(allocator, ",\"to_types\":");
        try appendStringArray(allocator, out, spec.to_types);
        try out.appendSlice(allocator, ",\"description\":");
        try json.appendString(out, allocator, spec.description);
        try out.append(allocator, '}');
    }
    try out.appendSlice(allocator, "],\"directions\":[\"both\",\"outbound\",\"inbound\"],\"unknown_relation_types\":\"allowed_without_shape_validation\"}");
}

fn appendStringArray(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), values: []const []const u8) !void {
    try out.append(allocator, '[');
    for (values, 0..) |value, i| {
        if (i > 0) try out.append(allocator, ',');
        try json.appendString(out, allocator, value);
    }
    try out.append(allocator, ']');
}

fn typeAllowed(allowed: []const []const u8, actual: []const u8) bool {
    if (allowed.len == 0) return true;
    for (allowed) |item| {
        if (std.ascii.eqlIgnoreCase(item, actual)) return true;
    }
    return false;
}

test "graph direction and relation schema helpers" {
    try std.testing.expectEqual(Direction.outbound, try parseDirection("out"));
    try std.testing.expectEqualStrings("affected", canonicalRelationType("affects"));
    try std.testing.expectEqualStrings("depends_on", canonicalRelationType("requires"));
    try validateRelationShape("implements", "ticket", "decision");
    try std.testing.expectError(error.InvalidRelationSchema, validateRelationShape("implements", "decision", "ticket"));
    try std.testing.expectEqualStrings("b", otherEntityIdForDirection("a", "b", "a", .outbound).?);
    try std.testing.expect(otherEntityIdForDirection("a", "b", "a", .inbound) == null);
}

test "graph command parser supports traverse path and relations" {
    var traverse = (try parseCommand(std.testing.allocator, "kg:traverse:project%3ANullPantry:3")).?;
    defer traverse.deinit(std.testing.allocator);
    try std.testing.expectEqual(CommandKind.traverse, traverse.kind);
    try std.testing.expectEqualStrings("project:NullPantry", traverse.entity_id.?);
    try std.testing.expectEqual(@as(usize, 3), traverse.max_depth);

    var path = (try parseCommand(std.testing.allocator, "graph:path:a%2F1:b%2F2:4")).?;
    defer path.deinit(std.testing.allocator);
    try std.testing.expectEqual(CommandKind.path, path.kind);
    try std.testing.expectEqualStrings("a/1", path.from_entity_id.?);
    try std.testing.expectEqualStrings("b/2", path.to_entity_id.?);
    try std.testing.expectEqual(@as(usize, 4), path.max_depth);

    var relations = (try parseCommand(std.testing.allocator, "kg:relations:agent%3Aalpha")).?;
    defer relations.deinit(std.testing.allocator);
    try std.testing.expectEqual(CommandKind.relations, relations.kind);
    try std.testing.expectEqualStrings("agent:alpha", relations.entity_id.?);
    try std.testing.expectEqual(@as(usize, 1), relations.max_depth);

    try std.testing.expect((try parseCommand(std.testing.allocator, "ordinary search")) == null);
    try std.testing.expectError(error.InvalidGraphCommand, parseCommand(std.testing.allocator, "kg:path:a:b"));
}
