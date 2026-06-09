const std = @import("std");
const domain = @import("domain.zig");
const disabled = @import("agent_memory_vendor_disabled.zig");

pub const is_compiled = false;
pub const WriteInput = disabled.WriteInput;
pub const VisibleContainerTags = disabled.VisibleContainerTags;

pub fn documentPayload(allocator: std.mem.Allocator, input: WriteInput) ![]u8 {
    _ = input;
    return disabled.disabledString(allocator);
}

pub fn searchPayload(allocator: std.mem.Allocator, query_text: []const u8, limit: usize, container_tag: ?[]const u8) ![]u8 {
    _ = query_text;
    _ = limit;
    _ = container_tag;
    return disabled.disabledString(allocator);
}

pub fn documentPath(allocator: std.mem.Allocator, id: []const u8) ![]u8 {
    _ = id;
    return disabled.disabledString(allocator);
}

pub fn agentMemoryFromWriteInput(allocator: std.mem.Allocator, input: WriteInput, response_body: []const u8) !domain.AgentMemory {
    _ = input;
    _ = response_body;
    return disabled.disabledMemory(allocator);
}

pub fn agentMemoryFromBody(allocator: std.mem.Allocator, body: []const u8, actor_id: []const u8, scopes_json: []const u8, exact_key: ?[]const u8, session_id_filter: ?[]const u8, include_sessions: bool) !?domain.AgentMemory {
    _ = body;
    _ = actor_id;
    _ = scopes_json;
    _ = exact_key;
    _ = session_id_filter;
    _ = include_sessions;
    return disabled.disabledMaybeMemory(allocator);
}

pub fn agentMemoryArrayFromBody(allocator: std.mem.Allocator, body: []const u8, actor_id: []const u8, scopes_json: []const u8, exact_key: ?[]const u8, session_id_filter: ?[]const u8, include_sessions: bool) ![]domain.AgentMemory {
    _ = body;
    _ = actor_id;
    _ = scopes_json;
    _ = exact_key;
    _ = session_id_filter;
    _ = include_sessions;
    return disabled.disabledMemorySlice(allocator);
}

pub fn appendUniqueAgentMemory(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(domain.AgentMemory), entry: domain.AgentMemory) !void {
    return disabled.disabledAppendMemory(allocator, out, entry);
}

pub fn customId(allocator: std.mem.Allocator, owner_actor_id: []const u8, session_id: ?[]const u8, key: []const u8) ![]u8 {
    _ = owner_actor_id;
    _ = session_id;
    _ = key;
    return disabled.disabledString(allocator);
}

pub fn visibleContainerTags(allocator: std.mem.Allocator, actor_id: []const u8, scopes_json: []const u8) !VisibleContainerTags {
    _ = actor_id;
    _ = scopes_json;
    return disabled.disabledContainerTags(allocator);
}
