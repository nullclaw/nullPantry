const std = @import("std");
const domain = @import("domain.zig");
const disabled = @import("agent_memory_vendor_disabled.zig");

pub const is_compiled = false;
pub const WriteInput = disabled.WriteInput;
pub const VisibleOwners = disabled.VisibleOwners;
pub const default_workspace_id = "nullpantry";

pub fn workspaceId(configured: ?[]const u8) []const u8 {
    return configured orelse default_workspace_id;
}

pub fn peerId(allocator: std.mem.Allocator, owner_actor_id: []const u8) ![]u8 {
    _ = owner_actor_id;
    return disabled.disabledString(allocator);
}

pub fn sessionId(allocator: std.mem.Allocator, owner_actor_id: []const u8, session_id: ?[]const u8) ![]u8 {
    _ = owner_actor_id;
    _ = session_id;
    return disabled.disabledString(allocator);
}

pub fn visibleOwners(allocator: std.mem.Allocator, actor_id: []const u8, scopes_json: []const u8) !VisibleOwners {
    _ = actor_id;
    _ = scopes_json;
    return disabled.disabledVisibleOwners(allocator);
}

pub fn peerPath(allocator: std.mem.Allocator, workspace_id: []const u8, peer_id: []const u8) ![]u8 {
    _ = workspace_id;
    _ = peer_id;
    return disabled.disabledString(allocator);
}

pub fn peerSearchPath(allocator: std.mem.Allocator, workspace_id: []const u8, peer_id: []const u8) ![]u8 {
    _ = workspace_id;
    _ = peer_id;
    return disabled.disabledString(allocator);
}

pub fn sessionPath(allocator: std.mem.Allocator, workspace_id: []const u8, session_id: []const u8) ![]u8 {
    _ = workspace_id;
    _ = session_id;
    return disabled.disabledString(allocator);
}

pub fn sessionSearchPath(allocator: std.mem.Allocator, workspace_id: []const u8, session_id: []const u8) ![]u8 {
    _ = workspace_id;
    _ = session_id;
    return disabled.disabledString(allocator);
}

pub fn sessionPeersPath(allocator: std.mem.Allocator, workspace_id: []const u8, session_id: []const u8) ![]u8 {
    _ = workspace_id;
    _ = session_id;
    return disabled.disabledString(allocator);
}

pub fn sessionMessagesPath(allocator: std.mem.Allocator, workspace_id: []const u8, session_id: []const u8) ![]u8 {
    _ = workspace_id;
    _ = session_id;
    return disabled.disabledString(allocator);
}

pub fn workspaceSearchPath(allocator: std.mem.Allocator, workspace_id: []const u8) ![]u8 {
    _ = workspace_id;
    return disabled.disabledString(allocator);
}

pub fn apiUrl(allocator: std.mem.Allocator, base_url: []const u8, path: []const u8, query: []const u8, allow_insecure_http: bool) ![]u8 {
    _ = base_url;
    _ = path;
    _ = query;
    _ = allow_insecure_http;
    return disabled.disabledString(allocator);
}

pub fn peerPayload(allocator: std.mem.Allocator, peer_id: []const u8, owner_actor_id: []const u8) ![]u8 {
    _ = peer_id;
    _ = owner_actor_id;
    return disabled.disabledString(allocator);
}

pub fn sessionPayload(allocator: std.mem.Allocator, session_id: []const u8, owner_actor_id: []const u8, original_session_id: ?[]const u8) ![]u8 {
    _ = session_id;
    _ = owner_actor_id;
    _ = original_session_id;
    return disabled.disabledString(allocator);
}

pub fn sessionPeerPayload(allocator: std.mem.Allocator, peer_id: []const u8) ![]u8 {
    _ = peer_id;
    return disabled.disabledString(allocator);
}

pub fn messagePayload(allocator: std.mem.Allocator, input: WriteInput, peer_id: []const u8) ![]u8 {
    _ = input;
    _ = peer_id;
    return disabled.disabledString(allocator);
}

pub fn searchPayload(allocator: std.mem.Allocator, query_text: []const u8, limit: usize) ![]u8 {
    _ = query_text;
    _ = limit;
    return disabled.disabledString(allocator);
}

pub fn agentMemoryFromWriteInput(allocator: std.mem.Allocator, input: WriteInput) !domain.AgentMemory {
    _ = input;
    return disabled.disabledMemory(allocator);
}

pub fn agentMemoryArrayFromBody(allocator: std.mem.Allocator, body: []const u8, actor_id: []const u8, scopes_json: []const u8, exact_key: ?[]const u8, session_id: ?[]const u8) ![]domain.AgentMemory {
    _ = body;
    _ = actor_id;
    _ = scopes_json;
    _ = exact_key;
    _ = session_id;
    return disabled.disabledMemorySlice(allocator);
}

pub fn appendLatestAgentMemory(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(domain.AgentMemory), entry: domain.AgentMemory) !void {
    return disabled.disabledAppendMemory(allocator, out, entry);
}
