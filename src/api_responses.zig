const std = @import("std");
const json = @import("json_util.zig");
const api_types = @import("api_types.zig");

pub const Context = api_types.Context;
pub const HttpResponse = api_types.HttpResponse;

pub fn ok(ctx: *Context, body: []const u8) HttpResponse {
    return .{ .status = "200 OK", .body = ctx.allocator.dupe(u8, body) catch body };
}

pub fn serverError(ctx: *Context) HttpResponse {
    return json.errorResponse(ctx.allocator, 500, "internal_error", "Internal server error");
}

pub fn engineNotCompiled(ctx: *Context, engine: []const u8) HttpResponse {
    const message = std.fmt.allocPrint(ctx.allocator, "Engine '{s}' is not compiled into this NullPantry binary", .{engine}) catch return serverError(ctx);
    defer ctx.allocator.free(message);
    return json.errorResponse(ctx.allocator, 501, "engine_not_compiled", message);
}

pub fn agentMemoryStorageUnavailable(ctx: *Context) HttpResponse {
    return json.errorResponse(ctx.allocator, 400, "storage_unavailable", "Requested agent memory storage is not configured");
}

pub fn forbidden(ctx: *Context) HttpResponse {
    return json.errorResponse(ctx.allocator, 403, "forbidden", "Actor is not allowed to write this scope or permission set");
}

pub fn badJson(ctx: *Context) HttpResponse {
    return json.errorResponse(ctx.allocator, 400, "invalid_json", "Expected JSON object body");
}

test "api response helpers return expected status classes" {
    var ctx = Context{
        .allocator = std.testing.allocator,
        .store = undefined,
    };
    const forbidden_response = forbidden(&ctx);
    defer std.testing.allocator.free(forbidden_response.body);
    try std.testing.expectEqualStrings("403 Forbidden", forbidden_response.status);
}
