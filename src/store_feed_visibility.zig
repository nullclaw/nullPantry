const std = @import("std");
const feed_contract = @import("feed_contract.zig");
const store_feed = @import("store_feed.zig");
const store_ownership = @import("store_ownership.zig");

pub const FeedEvent = store_feed.FeedEvent;
pub const FeedListInput = store_feed.FeedListInput;

pub fn ReferenceVisibilityContext(comptime Owner: type) type {
    return struct {
        owner: Owner,
        allocator: std.mem.Allocator,
        input: FeedListInput,
    };
}

pub fn redactEventsForActor(
    allocator: std.mem.Allocator,
    events: []FeedEvent,
    input: FeedListInput,
    owner: anytype,
    comptime payloadVisible: anytype,
) !void {
    var scratch_arena = std.heap.ArenaAllocator.init(allocator);
    defer scratch_arena.deinit();
    for (events) |*event| {
        _ = scratch_arena.reset(.retain_capacity);
        const scratch = scratch_arena.allocator();
        const visible = payloadVisible(owner, scratch, event.*, input) catch false;
        if (!visible) {
            const redacted = try allocator.dupe(u8, feed_contract.redactedPayload());
            allocator.free(event.payload_json);
            event.payload_json = redacted;
        }
    }
}

pub fn payloadVisibleForActor(
    owner: anytype,
    allocator: std.mem.Allocator,
    event: FeedEvent,
    input: FeedListInput,
    comptime eventObjectVisibleForActor: anytype,
    comptime referenceVisibleForActor: anytype,
) !bool {
    if (!try eventObjectVisibleForActor(owner, allocator, event, input)) return false;
    if (!try feed_contract.payloadReferencesVisible(
        allocator,
        event.payload_json,
        ReferenceVisibilityContext(@TypeOf(owner)){ .owner = owner, .allocator = allocator, .input = input },
        referenceVisibleForActor,
    )) return false;
    if (std.mem.eql(u8, event.object_type, "agent_memory") and try feed_contract.agentMemoryPayloadIsInternal(allocator, event.payload_json)) return false;
    if (feed_contract.isAgentSessionObject(event.object_type) and try feed_contract.agentSessionMessagePayloadIsInternal(allocator, event.payload_json)) return false;
    return true;
}

pub fn payloadVisibleForStore(
    store: anytype,
    allocator: std.mem.Allocator,
    event: FeedEvent,
    input: FeedListInput,
) !bool {
    return payloadVisibleForActor(store, allocator, event, input, eventObjectVisibleForStore, referenceVisibleForStore);
}

fn eventObjectVisibleForStore(store: anytype, allocator: std.mem.Allocator, event: FeedEvent, input: FeedListInput) !bool {
    if (!std.mem.eql(u8, event.status, "applied")) return true;
    return backingObjectVisibleForStore(store, allocator, event.object_type, event.object_id, input);
}

fn referenceVisibleForStore(context: anytype, object_type: []const u8, value: []const u8) !bool {
    return backingObjectVisibleForStore(context.owner, context.allocator, object_type, value, context.input);
}

fn backingObjectVisibleForStore(store: anytype, allocator: std.mem.Allocator, object_type: []const u8, object_id: []const u8, input: FeedListInput) !bool {
    if (std.mem.eql(u8, object_type, "memory_atom")) {
        var atom = (try store.getMemoryAtom(allocator, object_id)) orelse return false;
        defer store_ownership.deinitMemoryAtom(allocator, &atom);
        return store.recordVisibleWithPolicyForActor(allocator, atom.scope, atom.permissions_json, input.scopes_json, input.actor_id);
    }
    if (std.mem.eql(u8, object_type, "source")) {
        var source = (try store.getSource(allocator, object_id)) orelse return false;
        defer store_ownership.deinitSource(allocator, &source);
        return store.recordVisibleWithPolicyForActor(allocator, source.scope, source.permissions_json, input.scopes_json, input.actor_id);
    }
    if (std.mem.eql(u8, object_type, "artifact")) {
        var artifact = (try store.getArtifact(allocator, object_id)) orelse return false;
        defer store_ownership.deinitArtifact(allocator, &artifact);
        return store.recordVisibleWithPolicyForActor(allocator, artifact.scope, artifact.permissions_json, input.scopes_json, input.actor_id);
    }
    if (std.mem.eql(u8, object_type, "entity")) {
        var entity = (try store.getEntity(allocator, object_id)) orelse return false;
        defer store_ownership.deinitEntity(allocator, &entity);
        return store.recordVisibleWithPolicyForActor(allocator, entity.scope, entity.permissions_json, input.scopes_json, input.actor_id);
    }
    if (std.mem.eql(u8, object_type, "relation")) {
        var relation = (try store.getRelation(allocator, object_id)) orelse return false;
        defer store_ownership.deinitRelation(allocator, &relation);
        return store.recordVisibleWithPolicyForActor(allocator, relation.scope, relation.permissions_json, input.scopes_json, input.actor_id);
    }
    if (std.mem.eql(u8, object_type, "context_pack")) {
        var target = (try store.contextPackLifecycleTarget(allocator, object_id, input.actor_id, input.scopes_json)) orelse return false;
        defer store_ownership.deinitPrimitiveLifecycleTarget(allocator, &target);
        return true;
    }
    if (std.mem.eql(u8, object_type, "space")) {
        var space = (try store.getSpace(allocator, object_id)) orelse return false;
        defer store_ownership.deinitSpace(allocator, &space);
        return store.recordVisibleWithPolicyForActor(allocator, space.scope, space.permissions_json, input.scopes_json, input.actor_id);
    }
    if (std.mem.eql(u8, object_type, "policy_scope")) {
        var policy = (try store.getPolicyScope(allocator, object_id)) orelse return false;
        defer store_ownership.deinitPolicyScope(allocator, &policy);
        return store.recordVisibleWithPolicyForActor(allocator, policy.scope, policy.permissions_json, input.scopes_json, input.actor_id);
    }
    return true;
}

const TestVisibility = struct {
    object_visible: bool = true,
    hidden_reference_type: ?[]const u8 = null,
};

fn testObjectVisible(rules: TestVisibility, allocator: std.mem.Allocator, event: FeedEvent, input: FeedListInput) !bool {
    _ = allocator;
    _ = event;
    _ = input;
    return rules.object_visible;
}

fn testReferenceVisible(context: ReferenceVisibilityContext(TestVisibility), object_type: []const u8, value: []const u8) !bool {
    _ = value;
    if (context.owner.hidden_reference_type) |hidden| return !std.mem.eql(u8, hidden, object_type);
    return true;
}

fn testPayloadVisible(rules: TestVisibility, allocator: std.mem.Allocator, event: FeedEvent, input: FeedListInput) !bool {
    return payloadVisibleForActor(rules, allocator, event, input, testObjectVisible, testReferenceVisible);
}

fn makeTestEvent(allocator: std.mem.Allocator, object_type: []const u8, payload_json: []const u8) !FeedEvent {
    const template: FeedEvent = .{
        .id = 1,
        .event_type = "test.put",
        .operation = "put",
        .object_type = object_type,
        .object_id = "obj_1",
        .scope = "public",
        .permissions_json = "[]",
        .actor_id = "agent:test",
        .dedupe_key = null,
        .causality_json = "{}",
        .payload_json = payload_json,
        .status = "applied",
        .created_at_ms = 10,
        .applied_at_ms = 11,
        .compacted_at_ms = null,
    };
    return template.clone(allocator);
}

test "store feed visibility leaves accessible payloads intact" {
    const allocator = std.testing.allocator;
    var events = [_]FeedEvent{try makeTestEvent(allocator, "memory_atom", "{\"source\":\"src_1\"}")};
    defer events[0].deinit(allocator);

    try redactEventsForActor(allocator, events[0..], .{}, TestVisibility{}, testPayloadVisible);

    try std.testing.expectEqualStrings("{\"source\":\"src_1\"}", events[0].payload_json);
}

test "store feed visibility redacts hidden backing objects" {
    const allocator = std.testing.allocator;
    var events = [_]FeedEvent{try makeTestEvent(allocator, "memory_atom", "{\"source\":\"src_1\"}")};
    defer events[0].deinit(allocator);

    try redactEventsForActor(allocator, events[0..], .{}, TestVisibility{ .object_visible = false }, testPayloadVisible);

    try std.testing.expect(try feed_contract.payloadIsRedacted(allocator, events[0].payload_json));
}

test "store feed visibility redacts hidden payload references" {
    const allocator = std.testing.allocator;
    var events = [_]FeedEvent{try makeTestEvent(allocator, "memory_atom", "{\"source\":\"src_1\"}")};
    defer events[0].deinit(allocator);

    try redactEventsForActor(allocator, events[0..], .{}, TestVisibility{ .hidden_reference_type = "source" }, testPayloadVisible);

    try std.testing.expect(try feed_contract.payloadIsRedacted(allocator, events[0].payload_json));
}

test "store feed visibility redacts internal agent memory payloads" {
    const allocator = std.testing.allocator;
    var events = [_]FeedEvent{try makeTestEvent(allocator, "agent_memory", "{\"key\":\"autosave_user_1\",\"content\":\"internal\"}")};
    defer events[0].deinit(allocator);

    try redactEventsForActor(allocator, events[0..], .{}, TestVisibility{}, testPayloadVisible);

    try std.testing.expect(try feed_contract.payloadIsRedacted(allocator, events[0].payload_json));
}
