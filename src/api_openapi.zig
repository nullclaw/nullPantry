const std = @import("std");
const api_routes = @import("api_routes.zig");
const json = @import("json_util.zig");
const storage_routes = @import("storage_route.zig");

pub fn buildDocument(allocator: std.mem.Allocator) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator,
        \\{"openapi":"3.1.0","info":{"title":"NullPantry API","version":"v1","description":"Headless agent-native knowledge base and central memory service for the Null ecosystem."},"servers":[{"url":"/v1"}],"security":[{"bearerAuth":[]}],"components":{"securitySchemes":{"bearerAuth":{"type":"http","scheme":"bearer"}},"schemas":{"Error":{"type":"object","required":["error"],"properties":{"error":{"type":"string"},"message":{"type":"string"}}},"SourceCreate":{"type":"object","required":["title"],"properties":{"type":{"type":"string","default":"manual"},"title":{"type":"string"},"content":{"type":"string"},"scope":{"type":"string","default":"workspace"},"permissions":{"type":"array","items":{"type":"string"}},"metadata":{"type":"object"}}},"MemoryAtomCreate":{"type":"object","required":["text"],"properties":{"text":{"type":"string"},"scope":{"type":"string"},"confidence":{"type":"number"},"status":{"enum":["proposed","verified","rejected","stale","deprecated","superseded"]},"source_ids":{"type":"array","items":{"type":"string"}},"evidence_ranges":{"type":"array","items":{"type":"object"}}}},"AgentMemoryEntry":{"type":"object","required":["key","content","actor_id","owner_id","created_by_actor_id","scope"],"properties":{"key":{"type":"string"},"content":{"type":"string"},"category":{"type":"string"},"session_id":{"type":["string","null"]},"actor_id":{"type":"string","description":"Logical memory owner; shared scoped rows use shared:<scope>."},"owner_id":{"type":"string"},"created_by_actor_id":{"type":"string","description":"Actual actor that last wrote this memory row."},"scope":{"type":"string"},"permissions":{"type":"array","items":{"type":"string"}},"timestamp":{"type":"string"},"score":{"type":"number"}}},"SearchRequest":{"type":"object","properties":{"query":{"type":"string"},"limit":{"type":"integer","minimum":0,"maximum":500},"scopes":{"type":"array","items":{"type":"string"}},"include_deprecated":{"type":"boolean"},"use_vector":{"type":"boolean"},"strict_vector":{"type":"boolean"},"adaptive_retrieval":{"type":"boolean","default":true},"adaptive_keyword_max_tokens":{"type":"integer","minimum":0},"adaptive_vector_min_tokens":{"type":"integer","minimum":1},"use_temporal_decay":{"type":"boolean","default":true},"use_mmr":{"type":"boolean","default":true},"mmr_lambda":{"type":"number","minimum":0,"maximum":1,"default":0.72},"mmr_candidate_multiplier":{"type":"integer","minimum":1,"maximum":64,"default":4},"mmr_window_multiplier":{"type":"integer","minimum":1,"maximum":64,"default":4},"half_life_days":{"type":"number","minimum":0},"allow_reranker":{"type":"boolean"},"rerank_candidate_limit":{"type":"integer","minimum":1,"maximum":128,"default":24},"strict_reranker":{"type":"boolean","default":false},"min_relevance":{"type":"number","minimum":0},"min_score":{"type":"number","minimum":0},"rrf_k":{"type":"number","minimum":1,"default":60},"rrf_weight":{"type":"number","minimum":0,"maximum":1,"default":0.85},"raw_score_weight":{"type":"number","minimum":0,"maximum":1,"default":0.15},"rrf_window_multiplier":{"type":"integer","minimum":1,"maximum":64,"default":4}}},"ConnectorCursor":{"type":"object","required":["connector","scope","cursor"],"properties":{"connector":{"type":"string"},"scope":{"type":"string"},"cursor":{"type":"string"},"config":{"type":"object"},"permissions":{"type":"array","items":{"type":"string"}},"updated_at_ms":{"type":"integer"}}},"ConnectorIngestRequest":{"type":"object","properties":{"items":{"type":"array","items":{"$ref":"#/components/schemas/SourceCreate"}},"run_now":{"type":"boolean"},"scope":{"type":"string"},"permissions":{"type":"array","items":{"type":"string"}},"next_cursor":{"type":"string"},"cursor":{"type":"string"},"config":{"type":"object"}}}}},"paths":{
    );
    for (api_routes.routes, 0..) |path, i| {
        if (i > 0) try out.append(allocator, ',');
        try appendPath(allocator, &out, path);
    }
    try out.appendSlice(allocator, "}}");
    return out.toOwnedSlice(allocator);
}

fn appendPath(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), path: api_routes.RouteDescriptor) !void {
    try json.appendString(out, allocator, path.path);
    try out.appendSlice(allocator, ":{");
    var count: usize = 0;
    for (api_routes.http_methods) |method| {
        try appendOperation(allocator, out, &count, method, path.operationFor(method));
    }
    try out.append(allocator, '}');
}

fn appendOperation(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), count: *usize, method: api_routes.HttpMethod, operation_id: ?api_routes.Operation) !void {
    const op = operation_id orelse return;
    if (count.* > 0) try out.append(allocator, ',');
    try json.appendString(out, allocator, method.openApiName());
    try out.appendSlice(allocator, ":{\"operationId\":");
    const op_id = api_routes.operationId(op);
    try json.appendString(out, allocator, op_id);
    try appendOperationContract(allocator, out, api_routes.operationOpenApiContract(op));
    count.* += 1;
}

fn appendOperationContract(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), contract: api_routes.OpenApiContract) !void {
    return switch (contract) {
        .ok => out.appendSlice(allocator, ",\"responses\":{\"200\":{\"description\":\"OK\"}}}"),
        .agent_memory_count => appendAgentMemoryCountContract(allocator, out),
        .agent_memory_delete => appendAgentMemoryDeleteContract(allocator, out),
        .agent_memory_entry => appendAgentMemoryEntryContract(allocator, out),
        .agent_memory_list => appendAgentMemoryListContract(allocator, out),
        .agent_memory_search => appendAgentMemorySearchContract(allocator, out),
        .agent_memory_store => appendAgentMemoryStoreContract(allocator, out),
        .artifact_create => appendArtifactCreateContract(allocator, out),
        .context_pack_create => appendContextPackCreateContract(allocator, out),
        .memory_atom_create => appendMemoryAtomCreateContract(allocator, out),
        .search => appendSearchContract(allocator, out),
        .source_create => appendSourceCreateContract(allocator, out),
        .summarize => appendSummarizeContract(allocator, out),
    };
}

fn appendAgentMemoryEntryResponse(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    try out.appendSlice(allocator, "\"responses\":{\"200\":{\"description\":\"OK\",\"content\":{\"application/json\":{\"schema\":{\"type\":\"object\",\"required\":[\"memory\"],\"properties\":{\"memory\":{\"$ref\":\"#/components/schemas/AgentMemoryEntry\"}}}}}}}");
}

fn appendAgentMemoryEntriesResponse(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    try out.appendSlice(allocator, "\"responses\":{\"200\":{\"description\":\"OK\",\"content\":{\"application/json\":{\"schema\":{\"type\":\"object\",\"required\":[\"memories\"],\"properties\":{\"memories\":{\"type\":\"array\",\"items\":{\"$ref\":\"#/components/schemas/AgentMemoryEntry\"}}}}}}}}");
}

fn appendAgentMemoryReadQueryParameters(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    try out.appendSlice(allocator, ",\"parameters\":[");
    try appendQueryParameter(allocator, out, "session_id", "{\"type\":\"string\"}");
    try out.append(allocator, ',');
    try appendQueryParameter(allocator, out, "session", "{\"type\":\"string\"}");
    try out.append(allocator, ',');
    try appendQueryParameter(allocator, out, "scope", "{\"type\":\"string\"}");
    try out.append(allocator, ',');
    try appendAgentMemoryRouteQueryParameters(allocator, out);
    try out.append(allocator, ']');
}

fn appendAgentMemoryListQueryParameters(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    try out.appendSlice(allocator, ",\"parameters\":[");
    try appendQueryParameter(allocator, out, "category", "{\"type\":\"string\"}");
    try out.append(allocator, ',');
    try appendQueryParameter(allocator, out, "session_id", "{\"type\":\"string\"}");
    try out.append(allocator, ',');
    try appendQueryParameter(allocator, out, "session", "{\"type\":\"string\"}");
    try out.append(allocator, ',');
    try appendQueryParameter(allocator, out, "scope", "{\"type\":\"string\"}");
    try out.append(allocator, ',');
    try appendQueryParameter(allocator, out, "limit", "{\"type\":\"integer\",\"minimum\":0}");
    try out.append(allocator, ',');
    try appendQueryParameter(allocator, out, "offset", "{\"type\":\"integer\",\"minimum\":0}");
    try out.append(allocator, ',');
    try appendQueryParameter(allocator, out, "include_global", "{\"type\":\"boolean\"}");
    try out.append(allocator, ',');
    try appendQueryParameter(allocator, out, "include_sessions", "{\"type\":\"boolean\"}");
    try out.append(allocator, ',');
    try appendQueryParameter(allocator, out, "include_internal", "{\"type\":\"boolean\"}");
    try out.append(allocator, ',');
    try appendQueryParameter(allocator, out, "include_content", "{\"type\":\"boolean\"}");
    try out.append(allocator, ',');
    try appendAgentMemoryRouteQueryParameters(allocator, out);
    try out.append(allocator, ']');
}

fn appendAgentMemoryRouteQueryParameters(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    try appendQueryParameter(allocator, out, storage_routes.store_field, "{\"type\":\"string\"}");
    try out.append(allocator, ',');
    try appendQueryParameter(allocator, out, storage_routes.stores_field, "{\"oneOf\":[{\"type\":\"string\"},{\"type\":\"array\",\"items\":{\"type\":\"string\"}}]}");
}

fn appendQueryParameter(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), name: []const u8, schema_json: []const u8) !void {
    try out.appendSlice(allocator, "{\"name\":");
    try json.appendString(out, allocator, name);
    try out.appendSlice(allocator, ",\"in\":\"query\",\"required\":false,\"schema\":");
    try out.appendSlice(allocator, schema_json);
    try out.append(allocator, '}');
}

fn appendAgentMemoryStoreRequestBody(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    try out.appendSlice(allocator, "\"requestBody\":{\"required\":true,\"content\":{\"application/json\":{\"schema\":{\"type\":\"object\",\"properties\":{");
    try out.appendSlice(allocator, "\"key\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"},\"text\":{\"type\":\"string\"},\"category\":{\"type\":\"string\"},");
    try out.appendSlice(allocator, "\"session_id\":{\"type\":[\"string\",\"null\"]},\"session\":{\"type\":[\"string\",\"null\"]},\"scope\":{\"type\":\"string\"},");
    try out.appendSlice(allocator, "\"permissions\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}},\"metadata\":{\"type\":\"object\"},");
    try out.appendSlice(allocator, "\"operation\":{\"type\":\"string\",\"enum\":[\"put\",\"merge_string_set\",\"merge_object\"]},\"storage\":{\"type\":\"string\"},\"store\":{\"type\":\"string\"}");
    try out.appendSlice(allocator, "}}}}}");
}

fn appendAgentMemorySearchRequestBody(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    try out.appendSlice(allocator, "\"requestBody\":{\"required\":true,\"content\":{\"application/json\":{\"schema\":{\"type\":\"object\",\"properties\":{");
    try out.appendSlice(allocator, "\"query\":{\"type\":\"string\"},\"q\":{\"type\":\"string\"},\"session_id\":{\"type\":[\"string\",\"null\"]},\"session\":{\"type\":[\"string\",\"null\"]},");
    try out.appendSlice(allocator, "\"scopes\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}},\"scope\":{\"type\":\"string\"},\"limit\":{\"type\":\"integer\",\"minimum\":0},\"offset\":{\"type\":\"integer\",\"minimum\":0},");
    try out.appendSlice(allocator, "\"include_global\":{\"type\":\"boolean\"},\"include_sessions\":{\"type\":\"boolean\"},\"include_internal\":{\"type\":\"boolean\"},\"include_content\":{\"type\":\"boolean\"},");
    try out.appendSlice(allocator, "\"storage\":{\"type\":\"string\"},\"store\":{\"type\":\"string\"}");
    try out.appendSlice(allocator, "}}}}}");
}

fn appendAgentMemoryEntryContract(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    try appendAgentMemoryReadQueryParameters(allocator, out);
    try out.append(allocator, ',');
    try appendAgentMemoryEntryResponse(allocator, out);
    try out.append(allocator, '}');
}

fn appendAgentMemoryStoreContract(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    try out.append(allocator, ',');
    try appendAgentMemoryStoreRequestBody(allocator, out);
    try out.append(allocator, ',');
    try appendAgentMemoryEntryResponse(allocator, out);
    try out.append(allocator, '}');
}

fn appendAgentMemoryListContract(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    try appendAgentMemoryListQueryParameters(allocator, out);
    try out.append(allocator, ',');
    try appendAgentMemoryEntriesResponse(allocator, out);
    try out.append(allocator, '}');
}

fn appendAgentMemorySearchContract(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    try out.append(allocator, ',');
    try appendAgentMemorySearchRequestBody(allocator, out);
    try out.append(allocator, ',');
    try appendAgentMemoryEntriesResponse(allocator, out);
    try out.append(allocator, '}');
}

fn appendAgentMemoryCountContract(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    try appendAgentMemoryListQueryParameters(allocator, out);
    try out.appendSlice(allocator, ",\"responses\":{\"200\":{\"description\":\"OK\",\"content\":{\"application/json\":{\"schema\":{\"type\":\"object\",\"required\":[\"count\"],\"properties\":{\"count\":{\"type\":\"integer\",\"minimum\":0}}}}}}}}");
}

fn appendAgentMemoryDeleteContract(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    try appendAgentMemoryReadQueryParameters(allocator, out);
    try out.appendSlice(allocator, ",\"responses\":{\"200\":{\"description\":\"OK\",\"content\":{\"application/json\":{\"schema\":{\"type\":\"object\",\"required\":[\"ok\"],\"properties\":{\"ok\":{\"type\":\"boolean\"}}}}}}}}");
}

fn appendSourceCreateContract(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    try out.appendSlice(allocator, ",\"requestBody\":{\"required\":true,\"content\":{\"application/json\":{\"schema\":{\"$ref\":\"#/components/schemas/SourceCreate\"}}}},");
    try out.appendSlice(allocator, "\"responses\":{\"200\":{\"description\":\"OK\",\"content\":{\"application/json\":{\"schema\":{\"type\":\"object\",\"required\":[\"source\"],\"properties\":{\"source\":{\"type\":\"object\"}}}}}}}}");
}

fn appendArtifactCreateContract(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    try out.appendSlice(allocator, ",\"requestBody\":{\"required\":true,\"content\":{\"application/json\":{\"schema\":{\"type\":\"object\",\"required\":[\"title\"],\"properties\":{");
    try out.appendSlice(allocator, "\"type\":{\"type\":\"string\"},\"artifact_type\":{\"type\":\"string\"},\"title\":{\"type\":\"string\"},\"body\":{\"type\":\"string\"},\"status\":{\"type\":\"string\"},\"scope\":{\"type\":\"string\"},\"permissions\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}},\"source_ids\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}},\"metadata\":{\"type\":\"object\"}");
    try out.appendSlice(allocator, "}}}}},\"responses\":{\"200\":{\"description\":\"OK\",\"content\":{\"application/json\":{\"schema\":{\"type\":\"object\",\"required\":[\"artifact\"],\"properties\":{\"artifact\":{\"type\":\"object\"}}}}}}}}");
}

fn appendMemoryAtomCreateContract(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    try out.appendSlice(allocator, ",\"requestBody\":{\"required\":true,\"content\":{\"application/json\":{\"schema\":{\"$ref\":\"#/components/schemas/MemoryAtomCreate\"}}}},");
    try out.appendSlice(allocator, "\"responses\":{\"200\":{\"description\":\"OK\",\"content\":{\"application/json\":{\"schema\":{\"type\":\"object\",\"required\":[\"memory_atom\"],\"properties\":{\"memory_atom\":{\"type\":\"object\"}}}}}}}}");
}

fn appendSearchContract(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    try out.appendSlice(allocator, ",\"requestBody\":{\"required\":true,\"content\":{\"application/json\":{\"schema\":{\"$ref\":\"#/components/schemas/SearchRequest\"}}}},");
    try out.appendSlice(allocator, "\"responses\":{\"200\":{\"description\":\"OK\",\"content\":{\"application/json\":{\"schema\":{\"type\":\"object\",\"required\":[\"results\"],\"properties\":{\"results\":{\"type\":\"array\",\"items\":{\"type\":\"object\"}},\"query\":{\"type\":\"string\"}}}}}}}}");
}

fn appendContextPackCreateContract(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    try out.appendSlice(allocator, ",\"requestBody\":{\"required\":true,\"content\":{\"application/json\":{\"schema\":{\"type\":\"object\",\"required\":[\"query\"],\"properties\":{");
    try out.appendSlice(allocator, "\"query\":{\"type\":\"string\"},\"purpose\":{\"type\":\"string\"},\"target\":{\"type\":\"string\"},\"scopes\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}},\"token_budget\":{\"type\":\"integer\",\"minimum\":1},\"persist\":{\"type\":\"boolean\"},\"include_sessions\":{\"type\":\"boolean\"},\"use_vector\":{\"type\":\"boolean\"}");
    try out.appendSlice(allocator, "}}}}},\"responses\":{\"200\":{\"description\":\"OK\",\"content\":{\"application/json\":{\"schema\":{\"type\":\"object\",\"required\":[\"context_pack\"],\"properties\":{\"context_pack\":{\"type\":\"object\"}}}}}}}}");
}

fn appendSummarizeContract(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    try out.appendSlice(allocator, ",\"requestBody\":{\"required\":true,\"content\":{\"application/json\":{\"schema\":{\"type\":\"object\",\"properties\":{");
    try out.appendSlice(allocator, "\"messages\":{\"type\":\"array\",\"items\":{\"type\":\"object\",\"required\":[\"content\"],\"properties\":{\"content\":{\"type\":\"string\"},\"role\":{\"type\":\"string\"},\"speaker\":{\"type\":\"string\"},\"timestamp\":{\"type\":\"string\"}}}},");
    try out.appendSlice(allocator, "\"text\":{\"type\":\"string\"},\"session_id\":{\"type\":\"string\"},\"max_chars\":{\"type\":\"integer\",\"minimum\":1},\"max_items_per_section\":{\"type\":\"integer\",\"minimum\":1},");
    try out.appendSlice(allocator, "\"summary_profile\":{\"type\":\"string\",\"enum\":[\"generic\",\"meeting\",\"decision\",\"incident\",\"research\",\"runbook\"]},\"window_size_tokens\":{\"type\":\"integer\",\"minimum\":1},");
    try out.appendSlice(allocator, "\"use_llm\":{\"type\":\"boolean\"},\"strict_llm\":{\"type\":\"boolean\"},\"persist\":{\"type\":\"boolean\"},\"key\":{\"type\":\"string\"},\"category\":{\"type\":\"string\"},\"scope\":{\"type\":\"string\"},");
    try out.appendSlice(allocator, "\"permissions\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}},\"extract_semantic_facts\":{\"type\":\"boolean\"}");
    try out.appendSlice(allocator, "}}}}},\"responses\":{\"200\":{\"description\":\"OK\",\"content\":{\"application/json\":{\"schema\":{\"type\":\"object\",\"required\":[\"summary\",\"sections\",\"quality\"],\"properties\":{");
    try out.appendSlice(allocator, "\"summary\":{\"type\":\"string\"},\"summary_strategy\":{\"type\":\"string\"},\"summary_profile\":{\"type\":\"string\"},\"sections\":{\"type\":\"object\"},\"quality\":{\"type\":\"object\"},");
    try out.appendSlice(allocator, "\"messages_summarized\":{\"type\":\"integer\"},\"semantic_fact_count\":{\"type\":\"integer\"},\"persisted\":{\"type\":\"boolean\"},\"memory\":{\"$ref\":\"#/components/schemas/AgentMemoryEntry\"}");
    try out.appendSlice(allocator, "}}}}}}}");
}

fn expectOperation(paths: std.json.ObjectMap, path: api_routes.RouteDescriptor, method: api_routes.HttpMethod, operation_id: ?api_routes.Operation) !void {
    const expected = operation_id orelse return;
    const path_value = paths.get(path.path) orelse return error.MissingOpenApiPath;
    try std.testing.expect(path_value == .object);
    const method_value = path_value.object.get(method.openApiName()) orelse return error.MissingOpenApiMethod;
    try std.testing.expect(method_value == .object);
    const operation_value = method_value.object.get("operationId") orelse return error.MissingOperationId;
    try std.testing.expect(operation_value == .string);
    try std.testing.expectEqualStrings(api_routes.operationId(expected), operation_value.string);
}

fn operationObject(paths: std.json.ObjectMap, path: []const u8, method: api_routes.HttpMethod) !std.json.ObjectMap {
    const path_value = paths.get(path) orelse return error.MissingOpenApiPath;
    try std.testing.expect(path_value == .object);
    const method_value = path_value.object.get(method.openApiName()) orelse return error.MissingOpenApiMethod;
    try std.testing.expect(method_value == .object);
    return method_value.object;
}

fn responseSchema(operation: std.json.ObjectMap) !std.json.Value {
    const responses = operation.get("responses") orelse return error.MissingOpenApiResponses;
    try std.testing.expect(responses == .object);
    const ok_response = responses.object.get("200") orelse return error.MissingOpenApiResponse;
    try std.testing.expect(ok_response == .object);
    const content = ok_response.object.get("content") orelse return error.MissingOpenApiContent;
    try std.testing.expect(content == .object);
    const application_json = content.object.get("application/json") orelse return error.MissingOpenApiContent;
    try std.testing.expect(application_json == .object);
    const schema = application_json.object.get("schema") orelse return error.MissingOpenApiSchema;
    try std.testing.expect(schema == .object);
    return schema;
}

fn schemaHasProperty(schema: std.json.Value, name: []const u8) !void {
    const properties = schema.object.get("properties") orelse return error.MissingOpenApiSchemaProperties;
    try std.testing.expect(properties == .object);
    _ = properties.object.get(name) orelse return error.MissingOpenApiSchemaProperty;
}

test "OpenAPI document is generated from the route catalog" {
    const allocator = std.testing.allocator;
    const body = try buildDocument(allocator);
    defer allocator.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);

    const paths_value = parsed.value.object.get("paths") orelse return error.MissingOpenApiPaths;
    try std.testing.expect(paths_value == .object);
    for (api_routes.routes) |path| {
        for (api_routes.http_methods) |method| {
            try expectOperation(paths_value.object, path, method, path.operationFor(method));
        }
    }
}

test "OpenAPI operation contracts come from the route catalog" {
    try std.testing.expectEqual(api_routes.OpenApiContract.summarize, api_routes.operationOpenApiContract(.summarize));
    try std.testing.expectEqual(api_routes.OpenApiContract.search, api_routes.operationOpenApiContract(.search));
    try std.testing.expectEqual(api_routes.OpenApiContract.source_create, api_routes.operationOpenApiContract(.createSource));
    try std.testing.expectEqual(api_routes.OpenApiContract.artifact_create, api_routes.operationOpenApiContract(.createArtifact));
    try std.testing.expectEqual(api_routes.OpenApiContract.memory_atom_create, api_routes.operationOpenApiContract(.createMemoryAtom));
    try std.testing.expectEqual(api_routes.OpenApiContract.context_pack_create, api_routes.operationOpenApiContract(.createContextPack));
}

test "OpenAPI core knowledge write routes have typed contracts" {
    const allocator = std.testing.allocator;
    const body = try buildDocument(allocator);
    defer allocator.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const paths = (parsed.value.object.get("paths") orelse return error.MissingOpenApiPaths).object;

    const source_operation = try operationObject(paths, "/sources", .post);
    _ = source_operation.get("requestBody") orelse return error.MissingOpenApiRequestBody;
    try schemaHasProperty(try responseSchema(source_operation), "source");

    const artifact_operation = try operationObject(paths, "/artifacts", .post);
    _ = artifact_operation.get("requestBody") orelse return error.MissingOpenApiRequestBody;
    try schemaHasProperty(try responseSchema(artifact_operation), "artifact");

    const memory_atom_operation = try operationObject(paths, "/memory-atoms", .post);
    _ = memory_atom_operation.get("requestBody") orelse return error.MissingOpenApiRequestBody;
    try schemaHasProperty(try responseSchema(memory_atom_operation), "memory_atom");

    const search_operation = try operationObject(paths, "/search", .post);
    _ = search_operation.get("requestBody") orelse return error.MissingOpenApiRequestBody;
    try schemaHasProperty(try responseSchema(search_operation), "results");

    const context_pack_operation = try operationObject(paths, "/context-packs", .post);
    _ = context_pack_operation.get("requestBody") orelse return error.MissingOpenApiRequestBody;
    try schemaHasProperty(try responseSchema(context_pack_operation), "context_pack");
}

test "OpenAPI agent memory routes have typed contracts" {
    const allocator = std.testing.allocator;
    const body = try buildDocument(allocator);
    defer allocator.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const paths = (parsed.value.object.get("paths") orelse return error.MissingOpenApiPaths).object;

    const list_operation = try operationObject(paths, "/agent-memory", .get);
    try schemaHasProperty(try responseSchema(list_operation), "memories");

    const store_operation = try operationObject(paths, "/agent-memory/{key}", .put);
    _ = store_operation.get("requestBody") orelse return error.MissingOpenApiRequestBody;
    try schemaHasProperty(try responseSchema(store_operation), "memory");

    const search_operation = try operationObject(paths, "/agent-memory/search", .post);
    _ = search_operation.get("requestBody") orelse return error.MissingOpenApiRequestBody;
    try schemaHasProperty(try responseSchema(search_operation), "memories");

    const count_operation = try operationObject(paths, "/agent-memory/count", .get);
    try schemaHasProperty(try responseSchema(count_operation), "count");

    const delete_operation = try operationObject(paths, "/agent-memory/{key}", .delete);
    try schemaHasProperty(try responseSchema(delete_operation), "ok");

    try std.testing.expectEqual(api_routes.OpenApiContract.agent_memory_list, api_routes.operationOpenApiContract(.listAgentMemory));
    try std.testing.expectEqual(api_routes.OpenApiContract.agent_memory_store, api_routes.operationOpenApiContract(.putAgentMemoryByKey));
    try std.testing.expectEqual(api_routes.OpenApiContract.agent_memory_search, api_routes.operationOpenApiContract(.searchAgentMemory));
    try std.testing.expectEqual(api_routes.OpenApiContract.agent_memory_count, api_routes.operationOpenApiContract(.countAgentMemory));
    try std.testing.expectEqual(api_routes.OpenApiContract.agent_memory_delete, api_routes.operationOpenApiContract(.deleteAgentMemory));
}
