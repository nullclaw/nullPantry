const std = @import("std");

const json = @import("json_util.zig");
const lifecycle = @import("lifecycle.zig");
const api_types = @import("api_types.zig");

pub const Context = api_types.Context;

pub fn appendPolicyJson(ctx: *Context, out: *std.ArrayListUnmanaged(u8), policy: lifecycle.RolloutPolicy) !void {
    try out.append(ctx.allocator, '{');
    try appendPolicyJsonFields(ctx, out, policy);
    try out.append(ctx.allocator, '}');
}

pub fn appendPolicyJsonFields(ctx: *Context, out: *std.ArrayListUnmanaged(u8), policy: lifecycle.RolloutPolicy) !void {
    try out.appendSlice(ctx.allocator, "\"mode\":");
    try json.appendString(out, ctx.allocator, policy.mode.name());
    try out.print(ctx.allocator, ",\"percent\":{d},\"shadow_percent\":{d},\"disabled\":{s},\"salt\":", .{ policy.percent, policy.shadow_percent, if (policy.disabled) "true" else "false" });
    try json.appendString(out, ctx.allocator, policy.salt);
    try out.appendSlice(ctx.allocator, ",\"required_scopes\":");
    try json.appendRawJsonArray(out, ctx.allocator, policy.required_scopes_json);
    try out.appendSlice(ctx.allocator, ",\"target_scopes\":");
    try json.appendRawJsonArray(out, ctx.allocator, policy.target_scopes_json);
    try out.appendSlice(ctx.allocator, ",\"blocked_scopes\":");
    try json.appendRawJsonArray(out, ctx.allocator, policy.blocked_scopes_json);
    try out.appendSlice(ctx.allocator, ",\"required_capabilities\":");
    try json.appendRawJsonArray(out, ctx.allocator, policy.required_capabilities_json);
    try out.appendSlice(ctx.allocator, ",\"blocked_capabilities\":");
    try json.appendRawJsonArray(out, ctx.allocator, policy.blocked_capabilities_json);
}

test "rollout policy JSON includes gates" {
    var ctx = Context{
        .allocator = std.testing.allocator,
        .store = undefined,
    };
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try appendPolicyJson(&ctx, &out, .{
        .mode = .shadow,
        .percent = 25,
        .shadow_percent = 40,
        .salt = "test",
        .required_scopes_json = "[\"public\"]",
    });
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"mode\":\"shadow\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"required_scopes\":[\"public\"]") != null);
}

test "rollout policy JSON rejects invalid array roots for gates" {
    var ctx = Context{
        .allocator = std.testing.allocator,
        .store = undefined,
    };
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidRawJson, appendPolicyJson(&ctx, &out, .{
        .required_scopes_json = "{\"scope\":\"public\"}",
        .target_scopes_json = "{\"scope\":\"beta\"}",
        .blocked_scopes_json = "{\"scope\":\"blocked\"}",
        .required_capabilities_json = "{\"capability\":\"read\"}",
        .blocked_capabilities_json = "{\"capability\":\"export\"}",
    }));
}

test "rollout policy JSON fields can be embedded" {
    var ctx = Context{
        .allocator = std.testing.allocator,
        .store = undefined,
    };
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(std.testing.allocator);

    try out.appendSlice(std.testing.allocator, "{\"policy\":{");
    try appendPolicyJsonFields(&ctx, &out, .{
        .mode = .canary,
        .percent = 15,
        .salt = "embedded",
        .required_capabilities_json = "[\"read\"]",
    });
    try out.appendSlice(std.testing.allocator, "}}");

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.items, .{});
    defer parsed.deinit();

    const policy = parsed.value.object.get("policy").?.object;
    try std.testing.expectEqualStrings("canary", policy.get("mode").?.string);
    try std.testing.expectEqual(@as(i64, 15), policy.get("percent").?.integer);
    try std.testing.expectEqualStrings("read", policy.get("required_capabilities").?.array.items[0].string);
}
