const std = @import("std");
const domain = @import("domain.zig");
const disabled = @import("agent_memory_vendor_disabled.zig");

pub const is_compiled = false;
pub const WriteInput = disabled.WriteInput;
pub const VisibleOwners = disabled.VisibleOwners;
pub const PageFetchPlan = disabled.PageFetchPlan;
pub const default_bank_id = "nullpantry";

pub fn visibleOwners(allocator: std.mem.Allocator, actor_id: []const u8, scopes_json: []const u8) !VisibleOwners {
    _ = actor_id;
    _ = scopes_json;
    return disabled.disabledVisibleOwners(allocator);
}

pub fn bankId(configured: ?[]const u8) []const u8 {
    return configured orelse default_bank_id;
}

pub fn apiUrl(allocator: std.mem.Allocator, base_url: []const u8, bank_id: []const u8, path: []const u8, query: []const u8, allow_insecure_http: bool) ![]u8 {
    _ = base_url;
    _ = bank_id;
    _ = path;
    _ = query;
    _ = allow_insecure_http;
    return disabled.disabledString(allocator);
}

pub fn retainPayload(allocator: std.mem.Allocator, input: WriteInput) ![]u8 {
    _ = input;
    return disabled.disabledString(allocator);
}

pub fn recallPayload(allocator: std.mem.Allocator, query_text: []const u8, owner_actor_id: ?[]const u8, session_id: ?[]const u8, include_sessions: bool, exact_key: ?[]const u8, limit: usize) ![]u8 {
    _ = query_text;
    _ = owner_actor_id;
    _ = session_id;
    _ = include_sessions;
    _ = exact_key;
    _ = limit;
    return disabled.disabledString(allocator);
}

pub fn listQuery(allocator: std.mem.Allocator, q: ?[]const u8, limit: usize, offset: usize) ![]u8 {
    _ = q;
    _ = limit;
    _ = offset;
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

pub fn agentMemoryEventArrayFromBody(allocator: std.mem.Allocator, body: []const u8, actor_id: []const u8, scopes_json: []const u8, exact_key: ?[]const u8, session_id: ?[]const u8, include_sessions: bool) ![]domain.AgentMemory {
    _ = body;
    _ = actor_id;
    _ = scopes_json;
    _ = exact_key;
    _ = session_id;
    _ = include_sessions;
    return disabled.disabledMemorySlice(allocator);
}

pub fn rawMemoryItemCountFromBody(allocator: std.mem.Allocator, body: []const u8) !usize {
    _ = allocator;
    _ = body;
    return error.EngineNotCompiled;
}

pub fn activeAgentMemoryPage(allocator: std.mem.Allocator, entries: []domain.AgentMemory, limit: usize, offset: usize) ![]domain.AgentMemory {
    _ = entries;
    _ = limit;
    _ = offset;
    return disabled.disabledMemorySlice(allocator);
}

pub fn appendLatestAgentMemory(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(domain.AgentMemory), entry: domain.AgentMemory) !void {
    return disabled.disabledAppendMemory(allocator, out, entry);
}

pub fn appendAgentMemoryPage(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(domain.AgentMemory), body: []const u8, actor_id: []const u8, scopes_json: []const u8, exact_key: ?[]const u8, session_id: ?[]const u8, include_sessions: bool) !usize {
    _ = body;
    _ = actor_id;
    _ = scopes_json;
    _ = exact_key;
    _ = session_id;
    _ = include_sessions;
    return disabled.disabledAppendPage(allocator, out);
}

pub fn pageFetchPlan(limit: usize) PageFetchPlan {
    _ = limit;
    return disabled.disabledPageFetchPlan();
}

pub fn shouldContinuePages(parsed_count: usize, requested_size: usize) bool {
    _ = parsed_count;
    _ = requested_size;
    return disabled.disabledContinuePages();
}
