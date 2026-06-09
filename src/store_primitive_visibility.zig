const std = @import("std");
const bounded_int = @import("bounded_int.zig");
const domain = @import("domain.zig");
const store_context_pack = @import("store_context_pack.zig");
const store_ownership = @import("store_ownership.zig");
const store_primitive_runtime = @import("store_primitive_runtime.zig");
const store_search = @import("store_search.zig");
const store_types = @import("store_types.zig");

pub const PrimitiveListInput = store_types.PrimitiveListInput;
pub const ContextPackResult = store_context_pack.Result;

pub fn limit(raw_limit: usize) usize {
    return @min(raw_limit, store_search.primitive_list_limit_max);
}

const primitive_list_scan_multiplier: usize = 5;

pub fn scanLimit(raw_limit: usize) usize {
    const capped_limit = limit(raw_limit);
    if (capped_limit == 0) return 0;
    const expanded = bounded_int.saturatingUsizeMul(capped_limit, primitive_list_scan_multiplier);
    return @max(capped_limit, @min(expanded, store_search.primitive_list_limit_max));
}

fn shouldGrowScan(visible_count: usize, capped: usize, fetched: usize, scan_limit: usize) bool {
    if (visible_count >= capped) return false;
    if (fetched < scan_limit) return false;
    return scan_limit < store_search.primitive_list_limit_max;
}

fn growScanLimit(current: usize) usize {
    if (current == 0) return 0;
    if (current >= store_search.primitive_list_limit_max) return store_search.primitive_list_limit_max;
    const expanded = bounded_int.saturatingUsizeMul(current, primitive_list_scan_multiplier);
    return @min(store_search.primitive_list_limit_max, @max(current + 1, expanded));
}

fn deinitSources(allocator: std.mem.Allocator, sources: []domain.Source) void {
    for (sources) |*source| store_ownership.deinitSource(allocator, source);
}

fn deinitArtifacts(allocator: std.mem.Allocator, artifacts: []domain.Artifact) void {
    for (artifacts) |*artifact| store_ownership.deinitArtifact(allocator, artifact);
}

fn deinitEntities(allocator: std.mem.Allocator, entities: []domain.Entity) void {
    for (entities) |*entity| store_ownership.deinitEntity(allocator, entity);
}

fn deinitRelations(allocator: std.mem.Allocator, relations: []domain.Relation) void {
    for (relations) |*relation| store_ownership.deinitRelation(allocator, relation);
}

fn deinitContextPacks(allocator: std.mem.Allocator, packs: []ContextPackResult) void {
    for (packs) |*pack| store_ownership.deinitContextPackResult(allocator, pack);
}

pub fn listSourcesVisible(store: anytype, allocator: std.mem.Allocator, input: PrimitiveListInput) ![]domain.Source {
    if (input.scope_filter_empty) return try allocator.alloc(domain.Source, 0);
    const capped = limit(input.limit);
    if (capped == 0) return try allocator.alloc(domain.Source, 0);

    var out: std.ArrayListUnmanaged(domain.Source) = .empty;
    errdefer {
        deinitSources(allocator, out.items);
        out.deinit(allocator);
    }

    var scan_limit = scanLimit(capped);
    while (true) {
        const candidates = try store.listSources(allocator, scan_limit);
        defer allocator.free(candidates);

        for (candidates) |*source| {
            errdefer store_ownership.deinitSource(allocator, source);
            if (out.items.len >= capped or store_primitive_runtime.isAgentMemorySourceMetadata(source.metadata_json)) {
                store_ownership.deinitSource(allocator, source);
                continue;
            }
            const status = try store.primitiveLifecycleStatus(allocator, "source", source.id);
            if (!input.include_deprecated and !domain.isDefaultVisibleStatus(status)) {
                store_ownership.deinitSource(allocator, source);
                continue;
            }
            if (!try store.recordVisibleWithPolicyForActor(allocator, source.scope, source.permissions_json, input.scopes_json, input.actor_id)) {
                store_ownership.deinitSource(allocator, source);
                continue;
            }
            try out.ensureUnusedCapacity(allocator, 1);
            out.appendAssumeCapacity(source.*);
            source.* = undefined;
        }

        if (!shouldGrowScan(out.items.len, capped, candidates.len, scan_limit)) break;
        deinitSources(allocator, out.items);
        out.clearRetainingCapacity();
        scan_limit = growScanLimit(scan_limit);
    }
    return out.toOwnedSlice(allocator);
}

pub fn listArtifactsVisible(store: anytype, allocator: std.mem.Allocator, input: PrimitiveListInput) ![]domain.Artifact {
    if (input.scope_filter_empty) return try allocator.alloc(domain.Artifact, 0);
    const capped = limit(input.limit);
    if (capped == 0) return try allocator.alloc(domain.Artifact, 0);

    var out: std.ArrayListUnmanaged(domain.Artifact) = .empty;
    errdefer {
        deinitArtifacts(allocator, out.items);
        out.deinit(allocator);
    }

    var scan_limit = scanLimit(capped);
    while (true) {
        const candidates = try store.listArtifacts(allocator, scan_limit);
        defer allocator.free(candidates);

        for (candidates) |*artifact| {
            errdefer store_ownership.deinitArtifact(allocator, artifact);
            if (out.items.len >= capped or (!input.include_deprecated and !domain.isDefaultVisibleStatus(artifact.status))) {
                store_ownership.deinitArtifact(allocator, artifact);
                continue;
            }
            if (!try store.recordVisibleWithPolicyForActor(allocator, artifact.scope, artifact.permissions_json, input.scopes_json, input.actor_id)) {
                store_ownership.deinitArtifact(allocator, artifact);
                continue;
            }
            try out.ensureUnusedCapacity(allocator, 1);
            out.appendAssumeCapacity(artifact.*);
            artifact.* = undefined;
        }

        if (!shouldGrowScan(out.items.len, capped, candidates.len, scan_limit)) break;
        deinitArtifacts(allocator, out.items);
        out.clearRetainingCapacity();
        scan_limit = growScanLimit(scan_limit);
    }
    return out.toOwnedSlice(allocator);
}

pub fn listEntitiesVisible(store: anytype, allocator: std.mem.Allocator, input: PrimitiveListInput) ![]domain.Entity {
    if (input.scope_filter_empty) return try allocator.alloc(domain.Entity, 0);
    const capped = limit(input.limit);
    if (capped == 0) return try allocator.alloc(domain.Entity, 0);

    var out: std.ArrayListUnmanaged(domain.Entity) = .empty;
    errdefer {
        deinitEntities(allocator, out.items);
        out.deinit(allocator);
    }

    var scan_limit = scanLimit(capped);
    while (true) {
        const candidates = try store.listEntities(allocator, scan_limit);
        defer allocator.free(candidates);

        for (candidates) |*entity| {
            errdefer store_ownership.deinitEntity(allocator, entity);
            if (out.items.len >= capped) {
                store_ownership.deinitEntity(allocator, entity);
                continue;
            }
            const status = try store.primitiveLifecycleStatus(allocator, "entity", entity.id);
            if (!input.include_deprecated and !domain.isDefaultVisibleStatus(status)) {
                store_ownership.deinitEntity(allocator, entity);
                continue;
            }
            if (!try store.recordVisibleWithPolicyForActor(allocator, entity.scope, entity.permissions_json, input.scopes_json, input.actor_id)) {
                store_ownership.deinitEntity(allocator, entity);
                continue;
            }
            try out.ensureUnusedCapacity(allocator, 1);
            out.appendAssumeCapacity(entity.*);
            entity.* = undefined;
        }

        if (!shouldGrowScan(out.items.len, capped, candidates.len, scan_limit)) break;
        deinitEntities(allocator, out.items);
        out.clearRetainingCapacity();
        scan_limit = growScanLimit(scan_limit);
    }
    return out.toOwnedSlice(allocator);
}

pub fn listRelationsVisible(store: anytype, allocator: std.mem.Allocator, input: PrimitiveListInput) ![]domain.Relation {
    if (input.scope_filter_empty) return try allocator.alloc(domain.Relation, 0);
    const capped = limit(input.limit);
    if (capped == 0) return try allocator.alloc(domain.Relation, 0);

    var out: std.ArrayListUnmanaged(domain.Relation) = .empty;
    errdefer {
        deinitRelations(allocator, out.items);
        out.deinit(allocator);
    }

    var scan_limit = scanLimit(capped);
    while (true) {
        const candidates = try store.listRelations(allocator, scan_limit);
        defer allocator.free(candidates);

        for (candidates) |*relation| {
            errdefer store_ownership.deinitRelation(allocator, relation);
            if (out.items.len >= capped or !try relationVisibleForActor(store, allocator, relation.*, input)) {
                store_ownership.deinitRelation(allocator, relation);
                continue;
            }
            try out.ensureUnusedCapacity(allocator, 1);
            out.appendAssumeCapacity(relation.*);
            relation.* = undefined;
        }

        if (!shouldGrowScan(out.items.len, capped, candidates.len, scan_limit)) break;
        deinitRelations(allocator, out.items);
        out.clearRetainingCapacity();
        scan_limit = growScanLimit(scan_limit);
    }
    return out.toOwnedSlice(allocator);
}

fn relationVisibleForActor(store: anytype, allocator: std.mem.Allocator, relation: domain.Relation, input: PrimitiveListInput) !bool {
    if (!input.include_deprecated and !domain.isDefaultVisibleStatus(relation.status)) return false;
    if (!try store.recordVisibleWithPolicyForActor(allocator, relation.scope, relation.permissions_json, input.scopes_json, input.actor_id)) return false;

    var from_entity = (try store.getEntity(allocator, relation.from_entity_id)) orelse return false;
    defer store_ownership.deinitEntity(allocator, &from_entity);
    var to_entity = (try store.getEntity(allocator, relation.to_entity_id)) orelse return false;
    defer store_ownership.deinitEntity(allocator, &to_entity);

    if (!input.include_deprecated) {
        const from_status = try store.primitiveLifecycleStatus(allocator, "entity", from_entity.id);
        if (!domain.isDefaultVisibleStatus(from_status)) return false;
        const to_status = try store.primitiveLifecycleStatus(allocator, "entity", to_entity.id);
        if (!domain.isDefaultVisibleStatus(to_status)) return false;
    }
    return (try store.recordVisibleWithPolicyForActor(allocator, from_entity.scope, from_entity.permissions_json, input.scopes_json, input.actor_id)) and
        (try store.recordVisibleWithPolicyForActor(allocator, to_entity.scope, to_entity.permissions_json, input.scopes_json, input.actor_id));
}

pub fn listContextPacksVisible(store: anytype, allocator: std.mem.Allocator, input: PrimitiveListInput) ![]ContextPackResult {
    if (input.scope_filter_empty) return try allocator.alloc(ContextPackResult, 0);
    const capped = limit(input.limit);
    if (capped == 0) return try allocator.alloc(ContextPackResult, 0);

    var out: std.ArrayListUnmanaged(ContextPackResult) = .empty;
    errdefer {
        deinitContextPacks(allocator, out.items);
        out.deinit(allocator);
    }

    var scan_limit = scanLimit(capped);
    while (true) {
        const candidates = try store.listContextPacks(allocator, scan_limit);
        defer allocator.free(candidates);

        for (candidates) |*pack| {
            errdefer store_ownership.deinitContextPackResult(allocator, pack);
            if (out.items.len >= capped) {
                store_ownership.deinitContextPackResult(allocator, pack);
                continue;
            }
            const status = try store.primitiveLifecycleStatus(allocator, "context_pack", pack.id);
            if (!input.include_deprecated and !domain.isDefaultVisibleStatus(status)) {
                store_ownership.deinitContextPackResult(allocator, pack);
                continue;
            }
            var target = (try store.contextPackVisibleTarget(allocator, pack.id, input.actor_id, input.scopes_json, input.include_deprecated)) orelse {
                store_ownership.deinitContextPackResult(allocator, pack);
                continue;
            };
            store_ownership.deinitPrimitiveLifecycleTarget(allocator, &target);
            try out.ensureUnusedCapacity(allocator, 1);
            out.appendAssumeCapacity(pack.*);
            pack.* = undefined;
        }

        if (!shouldGrowScan(out.items.len, capped, candidates.len, scan_limit)) break;
        deinitContextPacks(allocator, out.items);
        out.clearRetainingCapacity();
        scan_limit = growScanLimit(scan_limit);
    }
    return out.toOwnedSlice(allocator);
}

test "primitive visibility caps scan windows" {
    try std.testing.expectEqual(@as(usize, 0), limit(0));
    try std.testing.expectEqual(store_search.primitive_list_limit_max, limit(store_search.primitive_list_limit_max + 1));
    try std.testing.expectEqual(@as(usize, 0), scanLimit(0));
    try std.testing.expectEqual(@as(usize, 50), scanLimit(10));
    try std.testing.expectEqual(@as(usize, 5000), scanLimit(store_search.primitive_list_limit_max));
    try std.testing.expectEqual(@as(usize, 5000), scanLimit(store_search.primitive_list_limit_max + 1));
    try std.testing.expectEqual(@as(usize, 5000), scanLimit(std.math.maxInt(usize)));
    try std.testing.expect(!shouldGrowScan(10, 10, 50, 50));
    try std.testing.expect(!shouldGrowScan(0, 10, 49, 50));
    try std.testing.expect(shouldGrowScan(0, 10, 50, 50));
    try std.testing.expectEqual(@as(usize, 250), growScanLimit(50));
    try std.testing.expectEqual(store_search.primitive_list_limit_max, growScanLimit(store_search.primitive_list_limit_max));
}
