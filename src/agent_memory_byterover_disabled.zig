const std = @import("std");
const domain = @import("domain.zig");
const disabled = @import("agent_memory_vendor_disabled.zig");

pub const is_compiled = false;
pub const WriteInput = disabled.WriteInput;
pub const VisibleOwners = disabled.VisibleOwners;

pub fn visibleOwners(allocator: std.mem.Allocator, actor_id: []const u8, scopes_json: []const u8) !VisibleOwners {
    _ = actor_id;
    _ = scopes_json;
    return disabled.disabledVisibleOwners(allocator);
}

pub fn agentMemoryFromWriteInput(allocator: std.mem.Allocator, input: WriteInput) !domain.AgentMemory {
    _ = input;
    return disabled.disabledMemory(allocator);
}

pub fn curateText(allocator: std.mem.Allocator, input: WriteInput) ![]u8 {
    _ = input;
    return disabled.disabledString(allocator);
}

pub fn queryPrompt(allocator: std.mem.Allocator, query_text: []const u8, owner_actor_id: ?[]const u8, session_id: ?[]const u8, include_sessions: bool, exact_key: ?[]const u8, category: ?[]const u8, limit: usize) ![]u8 {
    _ = query_text;
    _ = owner_actor_id;
    _ = session_id;
    _ = include_sessions;
    _ = exact_key;
    _ = category;
    _ = limit;
    return disabled.disabledString(allocator);
}

pub fn agentMemoryArrayFromCliOutput(allocator: std.mem.Allocator, body: []const u8, actor_id: []const u8, scopes_json: []const u8, exact_key: ?[]const u8, session_id: ?[]const u8, include_sessions: bool) ![]domain.AgentMemory {
    _ = body;
    _ = actor_id;
    _ = scopes_json;
    _ = exact_key;
    _ = session_id;
    _ = include_sessions;
    return disabled.disabledMemorySlice(allocator);
}

pub fn cliOutputSucceeded(allocator: std.mem.Allocator, body: []const u8) bool {
    _ = allocator;
    _ = body;
    return false;
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
