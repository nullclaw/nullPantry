const std = @import("std");
const domain = @import("domain.zig");
const store_context_pack = @import("store_context_pack.zig");
const store_types = @import("store_types.zig");

pub fn deinitSource(allocator: std.mem.Allocator, source: *domain.Source) void {
    allocator.free(source.id);
    allocator.free(source.source_type);
    allocator.free(source.title);
    if (source.raw_content_uri) |value| allocator.free(value);
    allocator.free(source.content);
    if (source.author) |value| allocator.free(value);
    allocator.free(source.participants_json);
    allocator.free(source.permissions_json);
    allocator.free(source.scope);
    if (source.checksum) |value| allocator.free(value);
    if (source.language) |value| allocator.free(value);
    allocator.free(source.related_entities_json);
    allocator.free(source.metadata_json);
    source.* = undefined;
}

pub fn freeLoadedSource(allocator: std.mem.Allocator, source: *domain.Source) void {
    deinitSource(allocator, source);
}

pub fn deinitArtifact(allocator: std.mem.Allocator, artifact: *domain.Artifact) void {
    allocator.free(artifact.id);
    allocator.free(artifact.artifact_type);
    allocator.free(artifact.title);
    allocator.free(artifact.body);
    allocator.free(artifact.status);
    if (artifact.owner) |value| allocator.free(value);
    if (artifact.space_id) |value| allocator.free(value);
    allocator.free(artifact.scope);
    allocator.free(artifact.source_ids_json);
    allocator.free(artifact.related_entities_json);
    allocator.free(artifact.permissions_json);
    allocator.free(artifact.fields_json);
    if (artifact.summary) |value| allocator.free(value);
    if (artifact.agent_summary) |value| allocator.free(value);
    artifact.* = undefined;
}

pub fn deinitMemoryAtom(allocator: std.mem.Allocator, atom: *domain.MemoryAtom) void {
    allocator.free(atom.id);
    if (atom.subject_entity_id) |value| allocator.free(value);
    allocator.free(atom.predicate);
    allocator.free(atom.object);
    allocator.free(atom.text);
    allocator.free(atom.scope);
    allocator.free(atom.status);
    allocator.free(atom.source_ids_json);
    allocator.free(atom.evidence_ranges_json);
    allocator.free(atom.created_by);
    if (atom.owner) |value| allocator.free(value);
    allocator.free(atom.permissions_json);
    allocator.free(atom.tags_json);
    atom.* = undefined;
}

pub fn deinitEntity(allocator: std.mem.Allocator, entity: *domain.Entity) void {
    allocator.free(entity.id);
    allocator.free(entity.entity_type);
    allocator.free(entity.name);
    allocator.free(entity.aliases_json);
    if (entity.description) |value| allocator.free(value);
    if (entity.canonical_artifact_id) |value| allocator.free(value);
    allocator.free(entity.scope);
    allocator.free(entity.permissions_json);
    allocator.free(entity.metadata_json);
    entity.* = undefined;
}

pub fn deinitRelation(allocator: std.mem.Allocator, relation: *domain.Relation) void {
    allocator.free(relation.id);
    allocator.free(relation.from_entity_id);
    allocator.free(relation.relation_type);
    allocator.free(relation.to_entity_id);
    allocator.free(relation.source_ids_json);
    allocator.free(relation.scope);
    allocator.free(relation.permissions_json);
    allocator.free(relation.status);
    relation.* = undefined;
}

pub fn deinitSpace(allocator: std.mem.Allocator, space: *store_types.Space) void {
    allocator.free(space.id);
    allocator.free(space.name);
    allocator.free(space.title);
    if (space.description) |value| allocator.free(value);
    allocator.free(space.scope);
    allocator.free(space.permissions_json);
    allocator.free(space.metadata_json);
    space.* = undefined;
}

pub fn deinitPolicyScope(allocator: std.mem.Allocator, policy: *store_types.PolicyScope) void {
    allocator.free(policy.scope);
    allocator.free(policy.visibility);
    allocator.free(policy.permissions_json);
    if (policy.owner) |value| allocator.free(value);
    allocator.free(policy.metadata_json);
    policy.* = undefined;
}

pub fn deinitPrimitiveLifecycleTarget(allocator: std.mem.Allocator, target: *store_types.PrimitiveLifecycleTarget) void {
    allocator.free(target.object_id);
    allocator.free(target.scope);
    allocator.free(target.permissions_json);
    target.* = undefined;
}

pub fn deinitContextPackResult(allocator: std.mem.Allocator, pack: *store_context_pack.Result) void {
    allocator.free(pack.id);
    allocator.free(pack.purpose);
    allocator.free(pack.target);
    allocator.free(pack.query);
    allocator.free(pack.generated_summary);
    allocator.free(pack.sections_json);
    allocator.free(pack.citations_json);
    allocator.free(pack.forbidden_assumptions_json);
    allocator.free(pack.suggested_next_steps_json);
    allocator.free(pack.included_sources_json);
    allocator.free(pack.included_artifacts_json);
    allocator.free(pack.included_memory_atoms_json);
    allocator.free(pack.included_result_refs_json);
    allocator.free(pack.required_scopes_json);
    if (pack.actor_id) |actor_id| allocator.free(actor_id);
    pack.* = undefined;
}

fn dupe(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    return allocator.dupe(u8, value);
}

test "store ownership releases loaded source fields" {
    const allocator = std.testing.allocator;
    var source = domain.Source{
        .id = try dupe(allocator, "src_1"),
        .source_type = try dupe(allocator, "manual"),
        .title = try dupe(allocator, "Title"),
        .raw_content_uri = try dupe(allocator, "file:///tmp/source.md"),
        .content = try dupe(allocator, "body"),
        .author = try dupe(allocator, "agent"),
        .participants_json = try dupe(allocator, "[]"),
        .permissions_json = try dupe(allocator, "[]"),
        .scope = try dupe(allocator, "public"),
        .checksum = try dupe(allocator, "abc"),
        .language = try dupe(allocator, "en"),
        .related_entities_json = try dupe(allocator, "[]"),
        .metadata_json = try dupe(allocator, "{}"),
        .created_at_ms = 1,
        .imported_at_ms = 2,
    };
    freeLoadedSource(allocator, &source);
}

test "store ownership releases lifecycle and context pack records" {
    const allocator = std.testing.allocator;
    var target = store_types.PrimitiveLifecycleTarget{
        .object_id = try dupe(allocator, "obj"),
        .scope = try dupe(allocator, "public"),
        .permissions_json = try dupe(allocator, "[]"),
    };
    deinitPrimitiveLifecycleTarget(allocator, &target);

    var pack = store_context_pack.Result{
        .id = try dupe(allocator, "ctx_1"),
        .purpose = try dupe(allocator, "answer"),
        .target = try dupe(allocator, "agent"),
        .query = try dupe(allocator, "query"),
        .generated_summary = try dupe(allocator, "summary"),
        .sections_json = try dupe(allocator, "{}"),
        .citations_json = try dupe(allocator, "[]"),
        .forbidden_assumptions_json = try dupe(allocator, "[]"),
        .suggested_next_steps_json = try dupe(allocator, "[]"),
        .included_sources_json = try dupe(allocator, "[]"),
        .included_artifacts_json = try dupe(allocator, "[]"),
        .included_memory_atoms_json = try dupe(allocator, "[]"),
        .included_result_refs_json = try dupe(allocator, "[]"),
        .required_scopes_json = try dupe(allocator, "[\"public\"]"),
        .actor_id = try dupe(allocator, "agent:a"),
        .actor_isolated = true,
        .token_budget = 100,
        .created_at_ms = 1,
        .persisted = true,
    };
    deinitContextPackResult(allocator, &pack);
}
