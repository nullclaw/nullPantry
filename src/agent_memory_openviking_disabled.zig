const std = @import("std");
const domain = @import("domain.zig");
const disabled = @import("agent_memory_vendor_disabled.zig");

pub const is_compiled = false;
pub const WriteInput = disabled.WriteInput;
pub const SearchHit = disabled.SearchHit;

pub fn memoryUri(allocator: std.mem.Allocator, owner_actor_id: []const u8, session_id: ?[]const u8, key: []const u8) ![]u8 {
    _ = owner_actor_id;
    _ = session_id;
    _ = key;
    return disabled.disabledString(allocator);
}

pub fn visibleTargetUris(allocator: std.mem.Allocator, actor_id: []const u8, scopes_json: []const u8) !std.ArrayListUnmanaged([]u8) {
    _ = actor_id;
    _ = scopes_json;
    _ = allocator;
    return error.EngineNotCompiled;
}

pub fn contentPayload(allocator: std.mem.Allocator, input: WriteInput, uri: []const u8) ![]u8 {
    _ = input;
    _ = uri;
    return disabled.disabledString(allocator);
}

pub fn contentPayloadFromEntry(allocator: std.mem.Allocator, entry: domain.AgentMemory, uri: []const u8, status: []const u8) ![]u8 {
    _ = entry;
    _ = uri;
    _ = status;
    return disabled.disabledString(allocator);
}

pub fn writePayload(allocator: std.mem.Allocator, uri: []const u8, content: []const u8, mode: []const u8) ![]u8 {
    _ = uri;
    _ = content;
    _ = mode;
    return disabled.disabledString(allocator);
}

pub fn searchPayload(allocator: std.mem.Allocator, query_text: []const u8, limit: usize, target_uri: []const u8) ![]u8 {
    _ = query_text;
    _ = limit;
    _ = target_uri;
    return disabled.disabledString(allocator);
}

pub fn uriQuery(allocator: std.mem.Allocator, uri: []const u8, raw: bool) ![]u8 {
    _ = uri;
    _ = raw;
    return disabled.disabledString(allocator);
}

pub fn apiUrl(allocator: std.mem.Allocator, base_url: []const u8, path: []const u8, query: []const u8, allow_insecure_http: bool) ![]u8 {
    _ = base_url;
    _ = path;
    _ = query;
    _ = allow_insecure_http;
    return disabled.disabledString(allocator);
}

pub fn agentMemoryFromWriteInput(allocator: std.mem.Allocator, input: WriteInput, uri: []const u8) !domain.AgentMemory {
    _ = input;
    _ = uri;
    return disabled.disabledMemory(allocator);
}

pub fn agentMemoryFromReadBody(allocator: std.mem.Allocator, body: []const u8, actor_id: []const u8, scopes_json: []const u8, exact_key: ?[]const u8, session_id: ?[]const u8) !?domain.AgentMemory {
    _ = body;
    _ = actor_id;
    _ = scopes_json;
    _ = exact_key;
    _ = session_id;
    return disabled.disabledMaybeMemory(allocator);
}

pub fn searchHitsFromBody(allocator: std.mem.Allocator, body: []const u8) ![]SearchHit {
    _ = body;
    return disabled.disabledHitSlice(allocator);
}

pub fn appendUniqueAgentMemory(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(domain.AgentMemory), entry: domain.AgentMemory) !void {
    return disabled.disabledAppendMemory(allocator, out, entry);
}
