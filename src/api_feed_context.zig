const std = @import("std");
const json = @import("json_util.zig");
const domain = @import("domain.zig");
const api_types = @import("api_types.zig");

pub const Context = api_types.Context;

pub fn scopesJson(ctx: *Context) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(ctx.allocator);
    try out.append(ctx.allocator, '[');
    var first = true;
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, ctx.actor_scopes_json, .{}) catch null;
    if (parsed) |p| {
        defer p.deinit();
        if (p.value == .array) {
            for (p.value.array.items) |item| {
                const scope = switch (item) {
                    .string => |s| s,
                    else => continue,
                };
                if (!first) try out.append(ctx.allocator, ',');
                first = false;
                try json.appendString(&out, ctx.allocator, scope);
            }
        }
    }
    const own_agent_scope = try domain.defaultAgentMemoryScope(ctx.allocator, ctx.actor_id);
    defer ctx.allocator.free(own_agent_scope);
    if (!domain.hasJsonString(ctx.actor_scopes_json, own_agent_scope)) {
        if (!first) try out.append(ctx.allocator, ',');
        first = false;
        try json.appendString(&out, ctx.allocator, own_agent_scope);
    }
    const own_actor_grant = try domain.actorGrant(ctx.allocator, ctx.actor_id);
    defer ctx.allocator.free(own_actor_grant);
    if (!domain.hasJsonString(ctx.actor_scopes_json, own_actor_grant)) {
        if (!first) try out.append(ctx.allocator, ',');
        try json.appendString(&out, ctx.allocator, own_actor_grant);
    }
    try out.append(ctx.allocator, ']');
    return out.toOwnedSlice(ctx.allocator);
}

test "feed scopes include requested scopes and actor-owned grants" {
    var ctx = Context{
        .allocator = std.testing.allocator,
        .store = undefined,
        .actor_id = "agent:a",
        .actor_scopes_json = "[\"public\"]",
    };
    const scopes = try scopesJson(&ctx);
    defer std.testing.allocator.free(scopes);
    try std.testing.expect(domain.hasJsonString(scopes, "public"));
    try std.testing.expect(domain.hasJsonString(scopes, "agent:agent:a"));
    try std.testing.expect(domain.hasJsonString(scopes, "actor:agent:a"));
}
