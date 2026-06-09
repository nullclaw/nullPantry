const std = @import("std");
const domain = @import("domain.zig");
const json = @import("json_util.zig");
const store = @import("store.zig");

pub const MessageRenderOptions = struct {
    hide_internal: bool = true,
};

pub fn renderMessages(allocator: std.mem.Allocator, messages: []const store.Message, options: MessageRenderOptions) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"messages\":[");
    var written: usize = 0;
    for (messages) |msg| {
        if (options.hide_internal and !domain.sessionMessageVisibleInHistory(msg.role)) continue;
        if (written > 0) try out.append(allocator, ',');
        try appendMessage(allocator, &out, msg);
        written += 1;
    }
    try out.appendSlice(allocator, "]}");
    return out.toOwnedSlice(allocator);
}

pub fn renderHistoryList(allocator: std.mem.Allocator, result: store.HistoryList, limit: usize, offset: usize) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.print(allocator, "{{\"total\":{d},\"limit\":{d},\"offset\":{d},\"sessions\":[", .{ result.total, limit, offset });
    for (result.sessions, 0..) |session, i| {
        if (i > 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, "{\"session_id\":");
        try json.appendString(&out, allocator, session.session_id);
        try out.print(allocator, ",\"message_count\":{d},\"first_message_at\":{d},\"last_message_at\":{d}}}", .{ session.message_count, session.first_message_at, session.last_message_at });
    }
    try out.appendSlice(allocator, "]}");
    return out.toOwnedSlice(allocator);
}

pub fn renderHistoryShow(allocator: std.mem.Allocator, session_id: []const u8, result: store.HistoryShow, limit: usize, offset: usize) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"session_id\":");
    try json.appendString(&out, allocator, session_id);
    try out.print(allocator, ",\"total\":{d},\"limit\":{d},\"offset\":{d},\"messages\":[", .{ result.total, limit, offset });
    for (result.messages, 0..) |msg, i| {
        if (i > 0) try out.append(allocator, ',');
        try appendMessage(allocator, &out, msg);
    }
    try out.appendSlice(allocator, "]}");
    return out.toOwnedSlice(allocator);
}

fn appendMessage(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), msg: store.Message) !void {
    try out.appendSlice(allocator, "{\"role\":");
    try json.appendString(out, allocator, msg.role);
    try out.appendSlice(allocator, ",\"content\":");
    try json.appendString(out, allocator, msg.content);
    try out.print(allocator, ",\"created_at_ms\":{d}", .{msg.created_at_ms});
    try out.append(allocator, '}');
}

test "session response messages hide internal runtime roles" {
    const messages = [_]store.Message{
        .{ .role = "user", .content = "visible", .created_at_ms = 10 },
        .{ .role = domain.runtime_command_role, .content = "hidden", .created_at_ms = 20 },
        .{ .role = "assistant", .content = "also visible", .created_at_ms = 30 },
    };
    const body = try renderMessages(std.testing.allocator, &messages, .{});
    defer std.testing.allocator.free(body);

    try std.testing.expectEqualStrings("{\"messages\":[{\"role\":\"user\",\"content\":\"visible\",\"created_at_ms\":10},{\"role\":\"assistant\",\"content\":\"also visible\",\"created_at_ms\":30}]}", body);
    try std.testing.expect(std.mem.indexOf(u8, body, "hidden") == null);
}

test "session response history list matches nullclaw parser contract" {
    var sessions = [_]store.SessionInfo{
        .{ .session_id = "sess-1", .message_count = 2, .first_message_at = 101, .last_message_at = 303 },
    };
    const body = try renderHistoryList(std.testing.allocator, .{ .total = 1, .sessions = sessions[0..] }, 10, 0);
    defer std.testing.allocator.free(body);

    try std.testing.expectEqualStrings("{\"total\":1,\"limit\":10,\"offset\":0,\"sessions\":[{\"session_id\":\"sess-1\",\"message_count\":2,\"first_message_at\":101,\"last_message_at\":303}]}", body);
}

test "session response history show includes detailed message timestamps" {
    var messages = [_]store.Message{
        .{ .role = "user", .content = "hello", .created_at_ms = 1234 },
    };
    const body = try renderHistoryShow(std.testing.allocator, "sess-1", .{ .total = 1, .messages = messages[0..] }, 25, 5);
    defer std.testing.allocator.free(body);

    try std.testing.expectEqualStrings("{\"session_id\":\"sess-1\",\"total\":1,\"limit\":25,\"offset\":5,\"messages\":[{\"role\":\"user\",\"content\":\"hello\",\"created_at_ms\":1234}]}", body);
}
