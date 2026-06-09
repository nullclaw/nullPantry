const std = @import("std");
const build_options = @import("build_options");

const api_responses = @import("api_responses.zig");
const api_types = @import("api_types.zig");
const json = @import("json_util.zig");

pub const Context = api_types.Context;
pub const HttpResponse = api_types.HttpResponse;

pub fn list(ctx: *Context) HttpResponse {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var first = true;
    out.appendSlice(ctx.allocator, "{\"connectors\":[") catch return api_responses.serverError(ctx);
    appendConnectorJson(ctx, &out, &first, "{\"name\":\"manual\",\"status\":\"built_in\",\"source_types\":[\"manual\",\"text\"],\"ingest\":\"POST /v1/connectors/manual/ingest\",\"cursor\":\"GET|POST /v1/connectors/manual/cursor\"}") catch return api_responses.serverError(ctx);
    if (build_options.enable_engine_markdown) {
        appendConnectorJson(ctx, &out, &first, "{\"name\":\"markdown\",\"status\":\"built_in_filesystem_import_export\",\"source_types\":[\"markdown\",\"md\"],\"ingest\":\"POST /v1/connectors/markdown/ingest\",\"import\":\"POST /v1/markdown/import\",\"import_directory\":\"POST /v1/markdown/import-directory\",\"export\":\"POST /v1/markdown/export\",\"export_directory\":\"POST /v1/markdown/export-directory\",\"cursor\":\"GET|POST /v1/connectors/markdown/cursor\"}") catch return api_responses.serverError(ctx);
    }
    if (build_options.enable_engine_qmd) {
        appendConnectorJson(ctx, &out, &first, "{\"name\":\"qmd\",\"status\":\"built_in_qmd_json_ingest_session_export\",\"source_types\":[\"qmd\",\"markdown\",\"session_export\"],\"ingest\":\"POST /v1/connectors/qmd/ingest\",\"export_sessions\":\"POST /v1/connectors/qmd/export-sessions\",\"prune_sessions\":\"POST /v1/connectors/qmd/prune-sessions\",\"cursor\":\"GET|POST /v1/connectors/qmd/cursor\",\"note\":\"Accepts qmd search JSON results as canonical Sources and exports permission-checked agent sessions into a QMD markdown corpus.\"}") catch return api_responses.serverError(ctx);
    }
    appendConnectorJson(ctx, &out, &first, "{\"name\":\"brain_db\",\"status\":\"built_in_nullclaw_memory_import\",\"source_types\":[\"nullclaw_brain_db\",\"sqlite\"],\"import\":\"POST /v1/lifecycle/import-brain-db\",\"note\":\"Imports legacy NullClaw brain.db memories into routed, actor-scoped NullPantry agent memory.\"}") catch return api_responses.serverError(ctx);
    appendConnectorJson(ctx, &out, &first, "{\"name\":\"transcript\",\"status\":\"built_in\",\"source_types\":[\"transcript\",\"chat\"],\"ingest\":\"POST /v1/connectors/transcript/ingest\",\"cursor\":\"GET|POST /v1/connectors/transcript/cursor\"}") catch return api_responses.serverError(ctx);
    appendConnectorJson(ctx, &out, &first, "{\"name\":\"ticket\",\"status\":\"built_in_push\",\"source_types\":[\"ticket\",\"issue\"],\"ingest\":\"POST /v1/connectors/ticket/ingest\",\"cursor\":\"GET|POST /v1/connectors/ticket/cursor\"}") catch return api_responses.serverError(ctx);
    appendConnectorJson(ctx, &out, &first, "{\"name\":\"git\",\"status\":\"built_in_push\",\"source_types\":[\"pr\",\"commit\",\"repo\"],\"ingest\":\"POST /v1/connectors/git/ingest\",\"cursor\":\"GET|POST /v1/connectors/git/cursor\"}") catch return api_responses.serverError(ctx);
    appendConnectorJson(ctx, &out, &first, "{\"name\":\"incident\",\"status\":\"built_in_push\",\"source_types\":[\"incident\"],\"ingest\":\"POST /v1/connectors/incident/ingest\",\"cursor\":\"GET|POST /v1/connectors/incident/cursor\"}") catch return api_responses.serverError(ctx);
    appendConnectorJson(ctx, &out, &first, "{\"name\":\"nulltickets\",\"status\":\"built_in_push\",\"source_types\":[\"ticket\",\"issue\"],\"ingest\":\"POST /v1/connectors/nulltickets/ingest\",\"cursor\":\"GET|POST /v1/connectors/nulltickets/cursor\"}") catch return api_responses.serverError(ctx);
    appendConnectorJson(ctx, &out, &first, "{\"name\":\"nullwatch\",\"status\":\"built_in_push\",\"source_types\":[\"incident\"],\"ingest\":\"POST /v1/connectors/nullwatch/ingest\",\"cursor\":\"GET|POST /v1/connectors/nullwatch/cursor\"}") catch return api_responses.serverError(ctx);
    appendConnectorJson(ctx, &out, &first, "{\"name\":\"nullhub\",\"status\":\"consumer\"}") catch return api_responses.serverError(ctx);
    out.appendSlice(ctx.allocator, "]}") catch return api_responses.serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return api_responses.serverError(ctx) };
}

pub fn engineUnavailable(ctx: *Context, connector: []const u8) ?HttpResponse {
    if (std.mem.eql(u8, connector, "qmd") and !build_options.enable_engine_qmd) return api_responses.engineNotCompiled(ctx, "qmd");
    if (std.mem.eql(u8, connector, "markdown") and !build_options.enable_engine_markdown) return api_responses.engineNotCompiled(ctx, "markdown");
    return null;
}

pub fn defaultSourceType(connector: []const u8) []const u8 {
    if (std.mem.eql(u8, connector, "ticket") or std.mem.eql(u8, connector, "nulltickets")) return "ticket";
    if (std.mem.eql(u8, connector, "git")) return "pr";
    if (std.mem.eql(u8, connector, "incident") or std.mem.eql(u8, connector, "nullwatch")) return "incident";
    if (std.mem.eql(u8, connector, "transcript")) return "transcript";
    if (std.mem.eql(u8, connector, "markdown")) return "markdown";
    if (std.mem.eql(u8, connector, "qmd")) return "qmd";
    return "manual";
}

pub fn metadataJson(allocator: std.mem.Allocator, connector: []const u8, metadata_json: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"connector\":");
    try json.appendString(&out, allocator, connector);
    try out.appendSlice(allocator, ",\"metadata\":");
    try json.appendRawJsonObject(&out, allocator, metadata_json);
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

fn appendConnectorJson(ctx: *Context, out: *std.ArrayListUnmanaged(u8), first: *bool, raw_json: []const u8) !void {
    if (!first.*) try out.append(ctx.allocator, ',');
    first.* = false;
    try out.appendSlice(ctx.allocator, raw_json);
}

test "api connectors catalog reflects compiled connector engines" {
    var ctx = Context{
        .allocator = std.testing.allocator,
        .store = undefined,
    };
    const response = list(&ctx);
    defer std.testing.allocator.free(response.body);
    try std.testing.expectEqualStrings("200 OK", response.status);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"name\":\"manual\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"name\":\"brain_db\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"name\":\"nullwatch\"") != null);
    try std.testing.expectEqual(
        build_options.enable_engine_markdown,
        std.mem.indexOf(u8, response.body, "\"name\":\"markdown\"") != null,
    );
    try std.testing.expectEqual(
        build_options.enable_engine_qmd,
        std.mem.indexOf(u8, response.body, "\"name\":\"qmd\"") != null,
    );
}

test "api connector contracts centralize engine gates source types and metadata" {
    var ctx = Context{
        .allocator = std.testing.allocator,
        .store = undefined,
    };
    const qmd_unavailable = engineUnavailable(&ctx, "qmd");
    if (build_options.enable_engine_qmd) {
        try std.testing.expect(qmd_unavailable == null);
    } else {
        try std.testing.expect(qmd_unavailable != null);
        defer std.testing.allocator.free(qmd_unavailable.?.body);
        try std.testing.expectEqualStrings("501 Not Implemented", qmd_unavailable.?.status);
    }

    const markdown_unavailable = engineUnavailable(&ctx, "markdown");
    if (build_options.enable_engine_markdown) {
        try std.testing.expect(markdown_unavailable == null);
    } else {
        try std.testing.expect(markdown_unavailable != null);
        defer std.testing.allocator.free(markdown_unavailable.?.body);
        try std.testing.expectEqualStrings("501 Not Implemented", markdown_unavailable.?.status);
    }

    try std.testing.expectEqualStrings("ticket", defaultSourceType("nulltickets"));
    try std.testing.expectEqualStrings("incident", defaultSourceType("nullwatch"));
    try std.testing.expectEqualStrings("pr", defaultSourceType("git"));
    try std.testing.expectEqualStrings("manual", defaultSourceType("unknown"));

    const payload = try metadataJson(std.testing.allocator, "ticket", "{\"project\":\"NP\"}");
    defer std.testing.allocator.free(payload);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("ticket", parsed.value.object.get("connector").?.string);
    try std.testing.expectEqualStrings("NP", parsed.value.object.get("metadata").?.object.get("project").?.string);

    try std.testing.expectError(error.InvalidRawJson, metadataJson(std.testing.allocator, "manual", "not-json"));
}
