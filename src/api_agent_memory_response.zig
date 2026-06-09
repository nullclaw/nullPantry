const std = @import("std");
const domain = @import("domain.zig");
const api_responses = @import("api_responses.zig");
const api_types = @import("api_types.zig");

pub const Context = api_types.Context;
pub const HttpResponse = api_types.HttpResponse;

pub fn entryResponse(ctx: *Context, entry: domain.AgentMemory) HttpResponse {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ctx.allocator, "{\"entry\":") catch return api_responses.serverError(ctx);
    appendEntry(ctx, &out, entry) catch return api_responses.serverError(ctx);
    out.append(ctx.allocator, '}') catch return api_responses.serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return api_responses.serverError(ctx) };
}

pub fn entriesResponse(
    ctx: *Context,
    entries: []const domain.AgentMemory,
    include_internal: bool,
    limit: usize,
    offset: usize,
    comptime entryVisible: anytype,
) HttpResponse {
    return entriesResponseWithContent(ctx, entries, include_internal, true, limit, offset, entryVisible);
}

pub fn entriesResponseWithContent(
    ctx: *Context,
    entries: []const domain.AgentMemory,
    include_internal: bool,
    include_content: bool,
    limit: usize,
    offset: usize,
    comptime entryVisible: anytype,
) HttpResponse {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ctx.allocator, "{\"entries\":[") catch return api_responses.serverError(ctx);
    var visible_seen: usize = 0;
    var written: usize = 0;
    for (entries) |entry| {
        if (!entryVisible(ctx, entry)) continue;
        if (!include_internal and domain.isInternalMemoryEntryKeyOrContent(entry.key, entry.content)) continue;
        if (visible_seen < offset) {
            visible_seen += 1;
            continue;
        }
        visible_seen += 1;
        if (written >= limit) continue;
        if (written > 0) out.append(ctx.allocator, ',') catch return api_responses.serverError(ctx);
        appendEntryWithContent(ctx, &out, entry, include_content) catch return api_responses.serverError(ctx);
        written += 1;
    }
    out.appendSlice(ctx.allocator, "]}") catch return api_responses.serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return api_responses.serverError(ctx) };
}

pub fn appendEntry(ctx: *Context, out: *std.ArrayListUnmanaged(u8), entry: domain.AgentMemory) !void {
    return appendEntryWithContent(ctx, out, entry, true);
}

pub fn appendEntryWithContent(ctx: *Context, out: *std.ArrayListUnmanaged(u8), entry: domain.AgentMemory, include_content: bool) !void {
    return entry.writeJsonWithOptions(ctx.allocator, out, .{ .include_content = include_content });
}

fn testVisible(_: *Context, _: domain.AgentMemory) bool {
    return true;
}

fn testHidden(_: *Context, entry: domain.AgentMemory) bool {
    return !std.mem.eql(u8, entry.key, "hidden");
}

fn testEntry(key: []const u8, content: []const u8) domain.AgentMemory {
    return .{
        .id = key,
        .key = key,
        .content = content,
        .category = "core",
        .session_id = null,
        .timestamp = "10",
        .actor_id = "agent:test",
        .writer_actor_id = "agent:test",
        .scope = "public",
        .permissions_json = "[]",
    };
}

test "api agent memory response writes single entry envelope" {
    var ctx = Context{
        .allocator = std.testing.allocator,
        .store = undefined,
    };
    const response = entryResponse(&ctx, testEntry("pref", "value"));
    defer std.testing.allocator.free(response.body);

    try std.testing.expectEqualStrings("200 OK", response.status);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"entry\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"key\":\"pref\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"content\":\"value\"") != null);
}

test "api agent memory response filters visibility internals and pages" {
    var ctx = Context{
        .allocator = std.testing.allocator,
        .store = undefined,
    };
    const entries = [_]domain.AgentMemory{
        testEntry("visible-a", "first"),
        testEntry("autosave_user_1", "internal"),
        testEntry("hidden", "hidden value"),
        testEntry("visible-b", "second"),
    };
    const response = entriesResponseWithContent(&ctx, entries[0..], false, false, 1, 1, testHidden);
    defer std.testing.allocator.free(response.body);

    try std.testing.expectEqualStrings("200 OK", response.status);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"key\":\"visible-b\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"content\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "autosave_user_1") == null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "hidden") == null);
}
