const std = @import("std");
const build_options = @import("build_options");

const api = @import("api.zig");
const api_routes = @import("api_routes.zig");
const store_mod = @import("store.zig");

const Context = api.Context;
const Store = store_mod.Store;
const handleRequest = api.handleRequest;

test "api dispatches simple registry routes from the route catalog" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = Context{ .allocator = arena.allocator(), .store = &store };

    const cases = [_]struct {
        path: []const u8,
        operation: api_routes.Operation,
        marker: []const u8,
    }{
        .{ .path = "/v1/openapi.json", .operation = .openApiDocument, .marker = "\"openapi\":\"3.1.0\"" },
        .{ .path = "/v1/openapi", .operation = .openApiDocumentAlias, .marker = "\"openapi\":\"3.1.0\"" },
        .{ .path = "/v1/engines", .operation = .listEngines, .marker = "\"engine_roles\"" },
        .{ .path = "/v1/providers", .operation = .listProviders, .marker = "\"providers\"" },
        .{ .path = "/v1/connectors", .operation = .listConnectors, .marker = "\"connectors\"" },
        .{ .path = "/v1/artifact-types", .operation = .listArtifactTypes, .marker = "\"artifact_types\"" },
        .{ .path = "/v1/sdk/manifest", .operation = .sdkManifest, .marker = "\"base_path\":\"/v1\"" },
    };

    for (cases) |case| {
        const operation = switch (api_routes.matchRequest("GET", case.path)) {
            .operation => |id| id,
            else => return error.MissingCatalogOperation,
        };
        try std.testing.expectEqual(case.operation, operation);
        const response = handleRequest(&ctx, "GET", case.path, "", "");
        try std.testing.expectEqualStrings("200 OK", response.status);
        try std.testing.expect(std.mem.indexOf(u8, response.body, case.marker) != null);
    }
}

test "api dispatches connector routes from the route catalog" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = Context{ .allocator = arena.allocator(), .store = &store };

    const cases = [_]struct {
        method: []const u8,
        path: []const u8,
        operation: api_routes.Operation,
    }{
        .{ .method = "GET", .path = "/v1/connectors/manual/cursor", .operation = .connectorGetCursor },
        .{ .method = "POST", .path = "/v1/connectors/manual/cursor", .operation = .connectorUpsertCursor },
        .{ .method = "POST", .path = "/v1/connectors/manual/ingest", .operation = .connectorIngest },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.operation, switch (api_routes.matchRequest(case.method, case.path)) {
            .operation => |operation| operation,
            else => return error.MissingCatalogOperation,
        });
    }

    const cursor_post = handleRequest(&ctx, "POST", "/v1/connectors/manual/cursor", "{\"scope\":\"admin\",\"permissions\":[\"admin\"],\"cursor\":\"cursor-1\"}", "");
    try std.testing.expectEqualStrings("200 OK", cursor_post.status);
    try std.testing.expect(std.mem.indexOf(u8, cursor_post.body, "\"cursor\":\"cursor-1\"") != null);

    const cursor_get = handleRequest(&ctx, "GET", "/v1/connectors/manual/cursor?scope=admin", "", "");
    try std.testing.expectEqualStrings("200 OK", cursor_get.status);
    try std.testing.expect(std.mem.indexOf(u8, cursor_get.body, "\"connector\":\"manual\"") != null);

    const ingest_resp = handleRequest(&ctx, "POST", "/v1/connectors/manual/ingest", "{\"title\":\"Connector Source\",\"content\":\"from connector\",\"scope\":\"admin\",\"permissions\":[\"admin\"],\"run_now\":false}", "");
    try std.testing.expectEqualStrings("200 OK", ingest_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, ingest_resp.body, "\"connector\":\"manual\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ingest_resp.body, "\"count\":1") != null);
}

test "api manifest and connector endpoints describe headless service contracts" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = Context{ .allocator = arena.allocator(), .store = &store };

    const caps = handleRequest(&ctx, "GET", "/v1/capabilities", "", "");
    try std.testing.expectEqualStrings("200 OK", caps.status);
    try std.testing.expect(std.mem.indexOf(u8, caps.body, "\"headless\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, caps.body, "knowledge_graph") != null);
    try std.testing.expect(std.mem.indexOf(u8, caps.body, "context_serving_api") != null);
    try std.testing.expect(std.mem.indexOf(u8, caps.body, "agent_memory") != null);
    try std.testing.expect(std.mem.indexOf(u8, caps.body, "agent_sessions") != null);
    try std.testing.expect(std.mem.indexOf(u8, caps.body, "nullclaw_api_root_adapter") != null);
    try std.testing.expect(std.mem.indexOf(u8, caps.body, "native_feed") != null);
    try std.testing.expect(std.mem.indexOf(u8, caps.body, "brain_db_import") != null);
    try std.testing.expect(std.mem.indexOf(u8, caps.body, "retrieval_plan") != null);
    try std.testing.expect(std.mem.indexOf(u8, caps.body, "retrieval_search") != null);
    try std.testing.expect(std.mem.indexOf(u8, caps.body, "lifecycle_diagnostics") != null);
    try std.testing.expect(std.mem.indexOf(u8, caps.body, "lifecycle_summarize") != null);
    try std.testing.expect(std.mem.indexOf(u8, caps.body, "cache_put") != null);
    try std.testing.expect(std.mem.indexOf(u8, caps.body, "semantic_cache_search") != null);
    try std.testing.expect(std.mem.indexOf(u8, caps.body, "get_context_pack") != null);
    try std.testing.expect(std.mem.indexOf(u8, caps.body, "legacy_adapters") == null);

    const connector_resp = handleRequest(&ctx, "GET", "/v1/connectors", "", "");
    try std.testing.expectEqualStrings("200 OK", connector_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, connector_resp.body, "\"name\":\"nullclaw\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, connector_resp.body, "\"name\":\"nullwatch\"") != null);
    if (build_options.enable_engine_qmd) {
        try std.testing.expect(std.mem.indexOf(u8, connector_resp.body, "\"name\":\"qmd\"") != null);
    } else {
        try std.testing.expect(std.mem.indexOf(u8, connector_resp.body, "\"name\":\"qmd\"") == null);
    }
    try std.testing.expect(std.mem.indexOf(u8, connector_resp.body, "\"name\":\"brain_db\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, connector_resp.body, "\"built_in_push\"") != null);

    const connector_ingest = handleRequest(&ctx, "POST", "/v1/connectors/ticket/ingest",
        \\{"title":"NP-42 Transcript ingestion","content":"Decision: ticket connectors should create first-class sources","scope":"public","next_cursor":"ticket-42","config":{"project":"NP"}}
    , "");
    try std.testing.expectEqualStrings("200 OK", connector_ingest.status);
    try std.testing.expect(std.mem.indexOf(u8, connector_ingest.body, "\"count\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, connector_ingest.body, "\"type\":\"ticket\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, connector_ingest.body, "\"cursor\":\"ticket-42\"") != null);

    const cursor_get = handleRequest(&ctx, "GET", "/v1/connectors/ticket/cursor?scope=public", "", "");
    try std.testing.expectEqualStrings("200 OK", cursor_get.status);
    try std.testing.expect(std.mem.indexOf(u8, cursor_get.body, "\"connector\":\"ticket\"") != null);

    const cursor_post = handleRequest(&ctx, "POST", "/v1/connectors/nullwatch/cursor",
        \\{"scope":"public","cursor":"incident-9","config":{"stream":"incidents"}}
    , "");
    try std.testing.expectEqualStrings("200 OK", cursor_post.status);
    try std.testing.expect(std.mem.indexOf(u8, cursor_post.body, "\"incident-9\"") != null);

    const openapi = handleRequest(&ctx, "GET", "/v1/openapi.json", "", "");
    try std.testing.expectEqualStrings("200 OK", openapi.status);
    try std.testing.expect(std.mem.indexOf(u8, openapi.body, "ConnectorIngestRequest") != null);
    try std.testing.expect(std.mem.indexOf(u8, openapi.body, "connectorIngest") != null);
    try std.testing.expect(std.mem.indexOf(u8, openapi.body, "connectorUpsertCursor") != null);
    try std.testing.expect(std.mem.indexOf(u8, openapi.body, "/feed/events") != null);
    try std.testing.expect(std.mem.indexOf(u8, openapi.body, "\"operationId\":\"nativeFeedStatus\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, openapi.body, "/agent/memory/events") != null);
    try std.testing.expect(std.mem.indexOf(u8, openapi.body, "\"operationId\":\"nullClawAgentApiFeedEvents\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, openapi.body, "/agent/memory/checkpoint") != null);
    try std.testing.expect(std.mem.indexOf(u8, openapi.body, "\"operationId\":\"nullClawAgentApiApplyFeedEvent\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, openapi.body, "/agent/memories/{key}") != null);
    try std.testing.expect(std.mem.indexOf(u8, openapi.body, "/agent/sessions/{id}/messages") != null);
    try std.testing.expect(std.mem.indexOf(u8, openapi.body, "/memories/{key}") != null);
    try std.testing.expect(std.mem.indexOf(u8, openapi.body, "/sessions/{id}/messages") != null);
    try std.testing.expect(std.mem.indexOf(u8, openapi.body, "/lifecycle/import-brain-db") != null);
    try std.testing.expect(std.mem.indexOf(u8, openapi.body, "/lifecycle/import-jsonl") != null);
    try std.testing.expect(std.mem.indexOf(u8, openapi.body, "/lifecycle/snapshot/import-jsonl") != null);
    try std.testing.expect(std.mem.indexOf(u8, openapi.body, "\"operationId\":\"importJsonlDataset\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, openapi.body, "\"operationId\":\"importJsonlSnapshot\"") != null);

    const manifest = handleRequest(&ctx, "GET", "/v1/sdk/manifest", "", "");
    try std.testing.expectEqualStrings("200 OK", manifest.status);
    var manifest_json = try std.json.parseFromSlice(std.json.Value, arena.allocator(), manifest.body, .{});
    defer manifest_json.deinit();
    const manifest_obj = manifest_json.value.object;
    try std.testing.expectEqualStrings("nullpantry", manifest_obj.get("name").?.string);
    try std.testing.expectEqualStrings("/v1", manifest_obj.get("base_path").?.string);
    try std.testing.expectEqualStrings("X-NullPantry-Actor-Scopes", manifest_obj.get("headers").?.object.get("actor_scopes").?.string);

    const manifest_methods = manifest_obj.get("methods").?.object;
    try std.testing.expectEqualStrings("POST /v1/remember", manifest_methods.get(api_routes.operationId(.remember)).?.string);
    try std.testing.expectEqualStrings("GET /v1/context-packs", manifest_methods.get(api_routes.operationId(.listContextPacks)).?.string);
    try std.testing.expectEqualStrings("POST /v1/feed/events", manifest_methods.get(api_routes.operationId(.appendNativeFeedEvent)).?.string);
    try std.testing.expectEqualStrings("GET /v1/feed/checkpoint", manifest_methods.get(api_routes.operationId(.exportNativeFeedCheckpoint)).?.string);
    try std.testing.expectEqualStrings("POST /v1/lifecycle/import-brain-db", manifest_methods.get(api_routes.operationId(.importNullClawBrainDb)).?.string);
    try std.testing.expectEqualStrings("GET /v1/agent/health", manifest_methods.get(api_routes.operationId(.nullClawAgentApiHealth)).?.string);
    try std.testing.expectEqualStrings("GET /v1/memory/parity", manifest_methods.get(api_routes.operationId(.nullClawMemoryParity)).?.string);
    try std.testing.expectEqualStrings("POST /v1/lifecycle/migrate", manifest_methods.get(api_routes.operationId(.migrateLifecycleStorage)).?.string);
}
