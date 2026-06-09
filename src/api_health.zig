const std = @import("std");

const json = @import("json_util.zig");
const migrations = @import("migrations.zig");
const api_types = @import("api_types.zig");
const api_responses = @import("api_responses.zig");

pub fn health(ctx: *api_types.Context) api_types.HttpResponse {
    if (!ctx.store.health()) return json.errorResponse(ctx.allocator, 500, "unhealthy", "Storage backend is unavailable");
    const schema_version = ctx.store.schemaVersion() catch return json.errorResponse(ctx.allocator, 500, "unhealthy", "Schema version cannot be read");
    const schema_ok = schema_version >= migrations.expected_schema_version;
    if (!schema_ok) return json.errorResponse(ctx.allocator, 500, "unhealthy", "Schema version is behind the runtime");
    const body = healthJson(ctx.allocator, .{
        .record_store = ctx.store.backendName(),
        .agent_memory_store = ctx.store.agentMemoryBackendName(),
        .schema_version = schema_version,
        .expected_schema_version = migrations.expected_schema_version,
    }) catch return api_responses.serverError(ctx);
    return .{ .status = "200 OK", .body = body };
}

const HealthSummary = struct {
    record_store: []const u8,
    agent_memory_store: []const u8,
    schema_version: i64,
    expected_schema_version: i64,
};

fn healthJson(allocator: std.mem.Allocator, summary: HealthSummary) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"ok\":true,\"service\":\"nullpantry\",\"record_store\":");
    try json.appendString(&out, allocator, summary.record_store);
    try out.appendSlice(allocator, ",\"agent_memory_store\":");
    try json.appendString(&out, allocator, summary.agent_memory_store);
    try out.print(
        allocator,
        ",\"schema_version\":{d},\"expected_schema_version\":{d},\"schema_ok\":true}}",
        .{ summary.schema_version, summary.expected_schema_version },
    );
    return out.toOwnedSlice(allocator);
}

test "health json escapes backend labels" {
    const allocator = std.testing.allocator;
    const body = try healthJson(allocator, .{
        .record_store = "sqlite\"quoted",
        .agent_memory_store = "memory\\store\nlabel",
        .schema_version = 7,
        .expected_schema_version = 6,
    });
    defer allocator.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    try std.testing.expect(obj.get("ok").?.bool);
    try std.testing.expectEqualStrings("nullpantry", obj.get("service").?.string);
    try std.testing.expectEqualStrings("sqlite\"quoted", obj.get("record_store").?.string);
    try std.testing.expectEqualStrings("memory\\store\nlabel", obj.get("agent_memory_store").?.string);
    try std.testing.expectEqual(@as(i64, 7), obj.get("schema_version").?.integer);
    try std.testing.expectEqual(@as(i64, 6), obj.get("expected_schema_version").?.integer);
    try std.testing.expect(obj.get("schema_ok").?.bool);
}
