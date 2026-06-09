const std = @import("std");
const domain = @import("domain.zig");
const store_mod = @import("store.zig");

pub fn entity(allocator: std.mem.Allocator, value: domain.Entity) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s} {s} {s} {s} {s}",
        .{ value.entity_type, value.name, value.aliases_json, value.description orelse "", value.metadata_json },
    );
}

pub fn relation(allocator: std.mem.Allocator, value: domain.Relation) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s} {s} {s} {s}",
        .{ value.from_entity_id, value.relation_type, value.to_entity_id, value.source_ids_json },
    );
}

pub fn space(allocator: std.mem.Allocator, value: store_mod.Space) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s} {s} {s} {s}",
        .{ value.name, value.title, value.description orelse "", value.metadata_json },
    );
}

pub fn policyScope(allocator: std.mem.Allocator, value: store_mod.PolicyScope) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s} {s} {s} {s}",
        .{ value.scope, value.visibility, value.owner orelse "", value.metadata_json },
    );
}

pub fn contextPack(allocator: std.mem.Allocator, value: store_mod.ContextPackResult) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}\n{s}\n{s}",
        .{ value.query, value.generated_summary, value.sections_json },
    );
}
