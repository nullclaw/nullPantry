const std = @import("std");
const domain = @import("domain.zig");
const disabled = @import("agent_memory_vendor_disabled.zig");

pub const is_compiled = false;
pub const WriteInput = disabled.WriteInput;
pub const VisibleOwners = disabled.VisibleOwners;
pub const default_base_url = "https://api.getzep.com/api/v2";

pub fn visibleOwners(allocator: std.mem.Allocator, actor_id: []const u8, scopes_json: []const u8) !VisibleOwners {
    _ = actor_id;
    _ = scopes_json;
    return disabled.disabledVisibleOwners(allocator);
}

pub fn apiUrl(allocator: std.mem.Allocator, base_url: []const u8, path: []const u8, query: []const u8, allow_insecure_http: bool) ![]u8 {
    _ = base_url;
    _ = path;
    _ = query;
    _ = allow_insecure_http;
    return disabled.disabledString(allocator);
}

pub fn addDataPayload(allocator: std.mem.Allocator, input: WriteInput) ![]u8 {
    _ = input;
    return disabled.disabledString(allocator);
}

pub fn searchPayload(allocator: std.mem.Allocator, query_text: []const u8, owner_actor_id: ?[]const u8, limit: usize) ![]u8 {
    _ = query_text;
    _ = owner_actor_id;
    _ = limit;
    return disabled.disabledString(allocator);
}

pub fn agentMemoryFromWriteInput(allocator: std.mem.Allocator, input: WriteInput) !domain.AgentMemory {
    _ = input;
    return disabled.disabledMemory(allocator);
}

pub fn agentMemoryArrayFromBody(allocator: std.mem.Allocator, body: []const u8, actor_id: []const u8, scopes_json: []const u8, exact_key: ?[]const u8, session_id: ?[]const u8, include_sessions: bool) ![]domain.AgentMemory {
    _ = body;
    _ = actor_id;
    _ = scopes_json;
    _ = exact_key;
    _ = session_id;
    _ = include_sessions;
    return disabled.disabledMemorySlice(allocator);
}

pub fn appendLatestAgentMemory(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(domain.AgentMemory), entry: domain.AgentMemory) !void {
    return disabled.disabledAppendMemory(allocator, out, entry);
}

pub fn activeAgentMemoryPage(allocator: std.mem.Allocator, entries: []domain.AgentMemory, limit: usize, offset: usize) ![]domain.AgentMemory {
    _ = entries;
    _ = limit;
    _ = offset;
    return disabled.disabledMemorySlice(allocator);
}
