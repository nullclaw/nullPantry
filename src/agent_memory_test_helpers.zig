const std = @import("std");
const domain = @import("domain.zig");
const agent_memory_runtime = @import("agent_memory_runtime.zig");

pub const EntryOptions = struct {
    id: ?[]const u8 = null,
    category: []const u8 = "core",
    timestamp: []const u8 = "0",
    session_id: ?[]const u8 = null,
    actor_id: []const u8 = "agent:a",
    writer_actor_id: ?[]const u8 = null,
    scope: ?[]const u8 = null,
    permissions_json: []const u8 = "[]",
    status: []const u8 = "verified",
    store: []const u8 = "",
    score: ?f64 = null,
};

pub fn emptyAgentMemory() domain.AgentMemory {
    return .{
        .id = "",
        .key = "",
        .content = "",
        .category = "",
        .timestamp = "",
        .session_id = null,
        .actor_id = "",
        .scope = "",
    };
}

pub fn ownedAgentMemory(
    allocator: std.mem.Allocator,
    key: []const u8,
    content: []const u8,
    options: EntryOptions,
) !domain.AgentMemory {
    var entry = emptyAgentMemory();
    errdefer freeAgentMemory(allocator, &entry);

    const writer_actor_id = options.writer_actor_id orelse options.actor_id;
    entry.id = if (options.id) |id|
        try allocator.dupe(u8, id)
    else if (options.store.len > 0)
        try std.fmt.allocPrint(allocator, "{s}:{s}:{s}:{s}", .{ options.store, options.actor_id, options.session_id orelse "__global__", key })
    else
        try std.fmt.allocPrint(allocator, "{s}:{s}:{s}", .{ options.actor_id, options.session_id orelse "__global__", key });
    entry.key = try allocator.dupe(u8, key);
    entry.content = try allocator.dupe(u8, content);
    entry.category = try allocator.dupe(u8, options.category);
    entry.timestamp = try allocator.dupe(u8, options.timestamp);
    entry.session_id = if (options.session_id) |sid| try allocator.dupe(u8, sid) else null;
    entry.actor_id = try allocator.dupe(u8, options.actor_id);
    entry.writer_actor_id = try allocator.dupe(u8, writer_actor_id);
    entry.scope = if (options.scope) |scope| try allocator.dupe(u8, scope) else try domain.defaultAgentMemoryScope(allocator, options.actor_id);
    entry.permissions_json = try allocator.dupe(u8, options.permissions_json);
    entry.status = try allocator.dupe(u8, options.status);
    entry.store = try allocator.dupe(u8, options.store);
    entry.score = options.score;
    return entry;
}

pub fn freeAgentMemory(allocator: std.mem.Allocator, entry: *domain.AgentMemory) void {
    agent_memory_runtime.freeAgentMemory(allocator, entry);
}

pub fn freeSlice(allocator: std.mem.Allocator, entries: []domain.AgentMemory) void {
    for (entries) |*entry| freeAgentMemory(allocator, entry);
    allocator.free(entries);
}

test "owned agent memory helper owns optional fields" {
    const allocator = std.testing.allocator;
    var entry = try ownedAgentMemory(allocator, "pref.theme", "dark", .{
        .session_id = "sess-1",
        .actor_id = "agent:test",
        .store = "scratch",
        .timestamp = "42",
        .score = 0.8,
    });
    defer freeAgentMemory(allocator, &entry);

    try std.testing.expectEqualStrings("pref.theme", entry.key);
    try std.testing.expectEqualStrings("dark", entry.content);
    try std.testing.expectEqualStrings("sess-1", entry.session_id.?);
    try std.testing.expectEqualStrings("agent:test", entry.actor_id);
    try std.testing.expectEqualStrings("agent:agent:test", entry.scope);
    try std.testing.expectEqualStrings("scratch", entry.store);
    try std.testing.expectEqual(@as(?f64, 0.8), entry.score);
}
