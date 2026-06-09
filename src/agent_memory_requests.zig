const std = @import("std");
const domain = @import("domain.zig");

pub const EventOrder = struct {
    timestamp_ms: i64,
    origin_instance_id: []const u8,
    origin_sequence: i64,
};

pub const Input = struct {
    key: []const u8,
    content: []const u8,
    category: []const u8 = "core",
    session_id: ?[]const u8 = null,
    scope: ?[]const u8 = null,
    permissions_json: []const u8 = "[]",
    metadata_json: []const u8 = "{}",
    actor_id: ?[]const u8 = null,
    writer_actor_id: ?[]const u8 = null,
    actor_scopes_json: ?[]const u8 = null,
    actor_capabilities_json: ?[]const u8 = null,
    operation: domain.AgentMemoryOperation = .put,
    suppress_feed: bool = false,
    event_order: ?EventOrder = null,
};

pub const GetInput = struct {
    key: []const u8,
    session_id: ?[]const u8 = null,
    actor_id: ?[]const u8 = null,
    scopes_json: ?[]const u8 = null,
    capabilities_json: ?[]const u8 = null,
    any_session: bool = false,
};

pub const ListInput = struct {
    category: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    actor_id: ?[]const u8 = null,
    scopes_json: ?[]const u8 = null,
    capabilities_json: ?[]const u8 = null,
    any_session: bool = false,
    limit: ?usize = null,
    offset: usize = 0,
};

pub const SearchInput = struct {
    query: []const u8,
    limit: usize,
    session_id: ?[]const u8 = null,
    scopes_json: []const u8,
    actor_id: ?[]const u8 = null,
    capabilities_json: ?[]const u8 = null,
    any_session: bool = false,
};

pub const DeleteInput = struct {
    key: []const u8,
    session_id: ?[]const u8 = null,
    actor_id: ?[]const u8 = null,
    writer_actor_id: ?[]const u8 = null,
    actor_scopes_json: ?[]const u8 = null,
    actor_capabilities_json: ?[]const u8 = null,
    event_order: ?EventOrder = null,
    all_owners: bool = false,
    suppress_feed: bool = false,
};

pub const PatchStatusInput = struct {
    key: []const u8,
    status: []const u8,
    session_id: ?[]const u8 = null,
    actor_id: ?[]const u8 = null,
    writer_actor_id: ?[]const u8 = null,
    actor_scopes_json: ?[]const u8 = null,
    actor_capabilities_json: ?[]const u8 = null,
    event_order: ?EventOrder = null,
};

pub const CountInput = struct {
    scopes_json: []const u8,
    actor_id: ?[]const u8 = null,
    capabilities_json: ?[]const u8 = null,
};

pub const SaveMessageInput = struct {
    session_id: []const u8,
    role: []const u8,
    content: []const u8,
    created_at_ms: i64,
    actor_id: ?[]const u8 = null,
    capabilities_json: ?[]const u8 = null,
    event_order: ?EventOrder = null,
    suppress_feed: bool = false,
};

pub const LoadMessagesInput = struct {
    session_id: []const u8,
    actor_id: ?[]const u8 = null,
    capabilities_json: ?[]const u8 = null,
};

pub const ClearMessagesInput = struct {
    session_id: []const u8,
    actor_id: ?[]const u8 = null,
    capabilities_json: ?[]const u8 = null,
    event_order: ?EventOrder = null,
    suppress_feed: bool = false,
};

pub const ClearAutoSavedInput = struct {
    session_id: ?[]const u8 = null,
    actor_id: ?[]const u8 = null,
    capabilities_json: ?[]const u8 = null,
    suppress_feed: bool = false,
};

pub const SaveUsageInput = struct {
    session_id: []const u8,
    total_tokens: u64,
    actor_id: ?[]const u8 = null,
    capabilities_json: ?[]const u8 = null,
    event_order: ?EventOrder = null,
    suppress_feed: bool = false,
};

pub const DeleteUsageInput = struct {
    session_id: []const u8,
    actor_id: ?[]const u8 = null,
    capabilities_json: ?[]const u8 = null,
    event_order: ?EventOrder = null,
    suppress_feed: bool = false,
};

pub const LoadUsageInput = struct {
    session_id: []const u8,
    actor_id: ?[]const u8 = null,
    capabilities_json: ?[]const u8 = null,
};

pub const ListSessionsInput = struct {
    limit: usize,
    offset: usize = 0,
    actor_id: ?[]const u8 = null,
    capabilities_json: ?[]const u8 = null,
};

pub const HistoryInput = struct {
    session_id: []const u8,
    limit: usize,
    offset: usize = 0,
    actor_id: ?[]const u8 = null,
    capabilities_json: ?[]const u8 = null,
};

pub const ListFeedEventsInput = struct {
    since_id: i64,
    limit: usize,
    scopes_json: []const u8,
    actor_id: ?[]const u8 = null,
    capabilities_json: ?[]const u8 = null,
};

pub const FeedStatusInput = struct {
    scopes_json: []const u8,
    actor_id: ?[]const u8 = null,
    capabilities_json: ?[]const u8 = null,
};

pub const CompactFeedInput = struct {
    scopes_json: []const u8,
    before_id: ?i64 = null,
    actor_id: ?[]const u8 = null,
    capabilities_json: ?[]const u8 = null,
};

pub const ExportFeedCheckpointInput = struct {
    scopes_json: []const u8,
    since_id: ?i64 = null,
    limit: ?usize = null,
    actor_id: ?[]const u8 = null,
    capabilities_json: ?[]const u8 = null,
};

pub const RestoreFeedCheckpointInput = struct {
    checkpoint_json: []const u8,
    scopes_json: []const u8,
    actor_id: ?[]const u8 = null,
    capabilities_json: ?[]const u8 = null,
};

pub const ApplyFeedEventInput = struct {
    event_json: []const u8,
    scopes_json: []const u8,
    actor_id: ?[]const u8 = null,
    capabilities_json: ?[]const u8 = null,
};

pub const TombstoneBlocksReplayInput = struct {
    key: []const u8,
    session_id: ?[]const u8 = null,
    actor_id: ?[]const u8 = null,
    event_order: EventOrder,
};

test "agent memory request input defaults are stable" {
    const input: Input = .{
        .key = "profile:name",
        .content = "Ada",
    };

    try std.testing.expectEqualStrings("profile:name", input.key);
    try std.testing.expectEqualStrings("Ada", input.content);
    try std.testing.expectEqualStrings("core", input.category);
    try std.testing.expectEqualStrings("[]", input.permissions_json);
    try std.testing.expectEqualStrings("{}", input.metadata_json);
    try std.testing.expectEqual(domain.AgentMemoryOperation.put, input.operation);
    try std.testing.expect(!input.suppress_feed);
    try std.testing.expect(input.session_id == null);
    try std.testing.expect(input.event_order == null);
}

test "agent memory request mutation contracts carry feed ordering" {
    const order: EventOrder = .{
        .timestamp_ms = 42,
        .origin_instance_id = "writer-a",
        .origin_sequence = 7,
    };
    const delete_input: DeleteInput = .{
        .key = "profile:name",
        .writer_actor_id = "writer",
        .event_order = order,
        .all_owners = true,
    };
    const message_input: SaveMessageInput = .{
        .session_id = "session-a",
        .role = "assistant",
        .content = "done",
        .created_at_ms = 123,
        .event_order = order,
        .suppress_feed = true,
    };
    const replay_input: TombstoneBlocksReplayInput = .{
        .key = "profile:name",
        .actor_id = "agent:a",
        .event_order = order,
    };

    try std.testing.expectEqualStrings("profile:name", delete_input.key);
    try std.testing.expectEqualStrings("writer", delete_input.writer_actor_id.?);
    try std.testing.expect(delete_input.all_owners);
    try std.testing.expectEqual(@as(i64, 7), delete_input.event_order.?.origin_sequence);
    try std.testing.expectEqualStrings("session-a", message_input.session_id);
    try std.testing.expectEqualStrings("assistant", message_input.role);
    try std.testing.expect(message_input.suppress_feed);
    try std.testing.expectEqual(@as(i64, 42), message_input.event_order.?.timestamp_ms);
    try std.testing.expectEqualStrings("profile:name", replay_input.key);
    try std.testing.expect(replay_input.session_id == null);
    try std.testing.expectEqualStrings("agent:a", replay_input.actor_id.?);
    try std.testing.expectEqual(@as(i64, 7), replay_input.event_order.origin_sequence);
}
