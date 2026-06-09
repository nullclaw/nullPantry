const std = @import("std");
const domain = @import("domain.zig");
const storage_routes = @import("storage_route.zig");

pub const FeedPut = struct {
    actor_id: ?[]const u8,
    route: storage_routes.Route,
};

pub const LucidPut = struct {
    object_type: []const u8,
    object_id: []const u8,
    title: []const u8,
    text: []const u8,
    scope: []const u8,
    permissions_json: []const u8,
    actor_id: ?[]const u8,
};

pub const MirrorJob = struct {
    object_type: []const u8,
    object_id: []const u8,
    scope: []const u8,
    permissions_json: []const u8,
    actor_id: ?[]const u8,
    route: storage_routes.Route,
};

pub const PutEffects = struct {
    feed: ?FeedPut,
    lucid: LucidPut,
    mirror: ?MirrorJob,
};

pub fn sourcePut(source: domain.Source, input: anytype) PutEffects {
    return .{
        .feed = feedPut(input.suppress_feed, input.actor_id, input.storage_route),
        .lucid = .{
            .object_type = "source",
            .object_id = source.id,
            .title = source.title,
            .text = source.content,
            .scope = source.scope,
            .permissions_json = source.permissions_json,
            .actor_id = input.actor_id,
        },
        .mirror = mirrorJob("source", source.id, source.scope, source.permissions_json, input.actor_id, input.storage_route),
    };
}

pub fn artifactPut(artifact: domain.Artifact, input: anytype) PutEffects {
    return .{
        .feed = feedPut(input.suppress_feed, input.actor_id, input.storage_route),
        .lucid = .{
            .object_type = "artifact",
            .object_id = artifact.id,
            .title = artifact.artifact_type,
            .text = artifact.body,
            .scope = artifact.scope,
            .permissions_json = artifact.permissions_json,
            .actor_id = input.actor_id,
        },
        .mirror = mirrorJob("artifact", artifact.id, artifact.scope, artifact.permissions_json, input.actor_id, input.storage_route),
    };
}

pub fn entityPut(entity: domain.Entity, input: anytype) PutEffects {
    return .{
        .feed = feedPut(input.suppress_feed, input.actor_id, input.storage_route),
        .lucid = .{
            .object_type = "entity",
            .object_id = entity.id,
            .title = entity.name,
            .text = entity.description orelse entity.name,
            .scope = entity.scope,
            .permissions_json = entity.permissions_json,
            .actor_id = input.actor_id,
        },
        .mirror = mirrorJob("entity", entity.id, entity.scope, entity.permissions_json, input.actor_id, input.storage_route),
    };
}

pub fn relationPut(relation: domain.Relation, relation_text: []const u8, input: anytype) PutEffects {
    return .{
        .feed = feedPut(input.suppress_feed, input.actor_id, input.storage_route),
        .lucid = .{
            .object_type = "relation",
            .object_id = relation.id,
            .title = relation.relation_type,
            .text = relation_text,
            .scope = relation.scope,
            .permissions_json = relation.permissions_json,
            .actor_id = input.actor_id,
        },
        .mirror = mirrorJob("relation", relation.id, relation.scope, relation.permissions_json, input.actor_id, input.storage_route),
    };
}

pub fn memoryAtomPut(atom: domain.MemoryAtom, input: anytype) PutEffects {
    const mirrors_runtime_route = input.storage_route.target != .primary;
    const is_agent_memory_atom = std.mem.eql(u8, atom.predicate, "agent.memory");
    return .{
        .feed = if (is_agent_memory_atom) null else feedPut(input.suppress_feed, input.actor_id, input.storage_route),
        .lucid = .{
            .object_type = "memory_atom",
            .object_id = atom.id,
            .title = atom.predicate,
            .text = atom.text,
            .scope = atom.scope,
            .permissions_json = atom.permissions_json,
            .actor_id = input.actor_id,
        },
        .mirror = if (mirrors_runtime_route and !is_agent_memory_atom)
            mirrorJob("memory_atom", atom.id, atom.scope, atom.permissions_json, input.actor_id, input.storage_route)
        else
            null,
    };
}

pub fn relationText(allocator: std.mem.Allocator, relation: domain.Relation) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s} {s} {s}", .{
        relation.from_entity_id,
        relation.relation_type,
        relation.to_entity_id,
    });
}

fn feedPut(suppress_feed: bool, actor_id: ?[]const u8, route: storage_routes.Route) ?FeedPut {
    if (suppress_feed) return null;
    return .{
        .actor_id = actor_id,
        .route = route,
    };
}

fn mirrorJob(
    object_type: []const u8,
    object_id: []const u8,
    scope: []const u8,
    permissions_json: []const u8,
    actor_id: ?[]const u8,
    route: storage_routes.Route,
) MirrorJob {
    return .{
        .object_type = object_type,
        .object_id = object_id,
        .scope = scope,
        .permissions_json = permissions_json,
        .actor_id = actor_id,
        .route = route,
    };
}

test "knowledge write effect plans keep primitive side effects explicit" {
    const source = domain.Source{
        .id = "src_1",
        .source_type = "manual",
        .title = "Title",
        .content = "Body",
        .scope = "workspace",
        .permissions_json = "[]",
        .metadata_json = "{}",
        .related_entities_json = "[]",
        .created_at_ms = 1,
        .imported_at_ms = 1,
    };
    const input = .{
        .suppress_feed = false,
        .actor_id = "actor",
        .storage_route = storage_routes.Route{ .target = .runtime },
    };
    const effects = sourcePut(source, input);
    try std.testing.expect(effects.feed != null);
    try std.testing.expectEqualStrings("source", effects.lucid.object_type);
    try std.testing.expect(effects.mirror != null);
}
