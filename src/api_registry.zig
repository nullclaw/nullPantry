const std = @import("std");
const engines = @import("engines.zig");
const providers = @import("providers.zig");
const capabilities_mod = @import("capabilities.zig");
const artifacts = @import("artifacts.zig");
const api_openapi = @import("api_openapi.zig");
const api_manifest = @import("api_manifest.zig");
const api_types = @import("api_types.zig");
const api_responses = @import("api_responses.zig");

pub const Context = api_types.Context;
pub const HttpResponse = api_types.HttpResponse;

pub fn engineRegistry(ctx: *Context) HttpResponse {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ctx.allocator, "{\"engine_roles\":") catch return api_responses.serverError(ctx);
    engines.appendEngineRolesJson(ctx.allocator, &out) catch return api_responses.serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"retrieval\":") catch return api_responses.serverError(ctx);
    engines.appendRetrievalJson(ctx.allocator, &out) catch return api_responses.serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"engines\":") catch return api_responses.serverError(ctx);
    engines.appendDescriptorsJson(ctx.allocator, &out) catch return api_responses.serverError(ctx);
    out.appendSlice(ctx.allocator, ",\"future_candidates\":") catch return api_responses.serverError(ctx);
    engines.appendFutureCandidatesJson(ctx.allocator, &out) catch return api_responses.serverError(ctx);
    out.append(ctx.allocator, '}') catch return api_responses.serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return api_responses.serverError(ctx) };
}

pub fn openApiDocument(ctx: *Context) HttpResponse {
    return .{ .status = "200 OK", .body = api_openapi.buildDocument(ctx.allocator) catch return api_responses.serverError(ctx) };
}

pub fn capabilities(ctx: *Context) HttpResponse {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    capabilities_mod.writeJson(ctx.allocator, &out) catch return api_responses.serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return api_responses.serverError(ctx) };
}

pub fn nullClawMemoryParity(ctx: *Context) HttpResponse {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    engines.appendNullClawMemoryParityJson(ctx.allocator, &out) catch return api_responses.serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return api_responses.serverError(ctx) };
}

pub fn providerRegistry(ctx: *Context) HttpResponse {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ctx.allocator, "{\"providers\":") catch return api_responses.serverError(ctx);
    providers.appendProvidersJson(ctx.allocator, &out) catch return api_responses.serverError(ctx);
    out.append(ctx.allocator, '}') catch return api_responses.serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return api_responses.serverError(ctx) };
}

pub fn artifactTypes(ctx: *Context) HttpResponse {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ctx.allocator, "{\"artifact_types\":") catch return api_responses.serverError(ctx);
    artifacts.appendTypesJson(ctx.allocator, &out) catch return api_responses.serverError(ctx);
    out.append(ctx.allocator, '}') catch return api_responses.serverError(ctx);
    return .{ .status = "200 OK", .body = out.toOwnedSlice(ctx.allocator) catch return api_responses.serverError(ctx) };
}

pub fn sdkManifest(ctx: *Context) HttpResponse {
    return .{ .status = "200 OK", .body = api_manifest.buildManifest(ctx.allocator) catch return api_responses.serverError(ctx) };
}

test "registry handlers expose service metadata documents" {
    var ctx = Context{
        .allocator = std.testing.allocator,
        .store = undefined,
    };
    const providers_response = providerRegistry(&ctx);
    defer std.testing.allocator.free(providers_response.body);
    try std.testing.expectEqualStrings("200 OK", providers_response.status);
    try std.testing.expect(std.mem.indexOf(u8, providers_response.body, "\"providers\"") != null);
}
