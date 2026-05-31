const std = @import("std");
const store_mod = @import("store.zig");
const domain = @import("domain.zig");
const extraction = @import("extraction.zig");
const providers = @import("providers.zig");
const vector = @import("vector.zig");
const vector_text = @import("vector_text.zig");
const json = @import("json_util.zig");
const ids = @import("ids.zig");
const compat = @import("compat.zig");

pub const RunOptions = struct {
    scopes_json: []const u8 = "[\"admin\"]",
    capabilities_json: []const u8 = "[\"read\",\"write\",\"propose\",\"verify\",\"delete\",\"export\",\"feed_apply\"]",
    job_limit: usize = 25,
    outbox_limit: usize = 100,
    embedding_base_url: ?[]const u8 = null,
    embedding_api_key: ?[]const u8 = null,
    embedding_model: ?[]const u8 = null,
    embedding_provider: providers.EmbeddingProviderKind = .openai_compatible,
    embedding_fallbacks: []const providers.EmbeddingEndpointConfig = &.{},
    embedding_dimensions: usize = 64,
    embedding_allow_insecure_http: bool = false,
    llm_base_url: ?[]const u8 = null,
    llm_api_key: ?[]const u8 = null,
    llm_model: ?[]const u8 = null,
    llm_allow_insecure_http: bool = false,
    provider_timeout_secs: u32 = 30,
    provider_runtime: ?*providers.ProviderRuntime = null,
    actor_id: []const u8 = "system:worker",
};

pub const RunResult = struct {
    jobs_checked: usize = 0,
    jobs_succeeded: usize = 0,
    jobs_failed: usize = 0,
    vector_outbox_processed: usize = 0,
    vector_outbox_failed: usize = 0,
    lucid_projection_processed: usize = 0,
    lucid_projection_failed: usize = 0,
};

pub fn runOnce(allocator: std.mem.Allocator, store: *store_mod.Store, options: RunOptions) !RunResult {
    var result = RunResult{};
    const outbox = try runVectorOutboxOnce(allocator, store, options);
    result.vector_outbox_processed += outbox.processed;
    result.vector_outbox_failed += outbox.failed;

    const jobs = try store.listJobs(allocator, .{
        .status = "queued",
        .scopes_json = options.scopes_json,
        .limit = options.job_limit,
    });
    result.jobs_checked = jobs.len;
    for (jobs) |job| {
        if (!(try store.claimJob(job.id))) continue;
        if (runClaimedJob(allocator, store, job, options)) |summary_json| {
            _ = try store.finishJob(job.id, "succeeded", summary_json, null);
            result.jobs_succeeded += 1;
            if (std.mem.eql(u8, job.job_type, "lucid_projection")) result.lucid_projection_processed += 1;
        } else |err| {
            const error_text = @errorName(err);
            _ = try store.finishJob(job.id, "failed", "{}", error_text);
            result.jobs_failed += 1;
            if (std.mem.eql(u8, job.job_type, "lucid_projection")) result.lucid_projection_failed += 1;
        }
    }
    return result;
}

pub fn runJobById(allocator: std.mem.Allocator, store: *store_mod.Store, id: []const u8, options: RunOptions) !store_mod.Job {
    const job = (try store.getJob(allocator, id)) orelse return error.JobNotFound;
    if (!try store.claimJob(job.id)) return error.JobNotQueued;
    if (runClaimedJob(allocator, store, job, options)) |summary_json| {
        _ = try store.finishJob(job.id, "succeeded", summary_json, null);
    } else |err| {
        _ = try store.finishJob(job.id, "failed", "{}", @errorName(err));
    }
    return (try store.getJob(allocator, id)) orelse job;
}

pub fn runClaimedJob(allocator: std.mem.Allocator, store: *store_mod.Store, job: store_mod.Job, options: RunOptions) ![]const u8 {
    if (std.mem.eql(u8, job.job_type, "vector_outbox")) {
        var job_options = options;
        job_options.outbox_limit = @max(job_options.outbox_limit, 1000);
        const outbox = try runVectorOutboxOnce(allocator, store, job_options);
        return try std.fmt.allocPrint(allocator, "{{\"vector_outbox_processed\":{d},\"vector_outbox_failed\":{d}}}", .{ outbox.processed, outbox.failed });
    }
    if (std.mem.eql(u8, job.job_type, "hygiene")) {
        const hygiene = try store.runHygiene(.{
            .scopes_json = options.scopes_json,
            .capabilities_json = options.capabilities_json,
        });
        return try std.fmt.allocPrint(allocator, "{{\"checked\":{d},\"marked_stale\":{d},\"archived\":{d},\"purged\":{d},\"expired_cache_entries\":{d}}}", .{ hygiene.checked, hygiene.marked_stale, hygiene.archived, hygiene.purged, hygiene.expired_cache_entries });
    }
    if (std.mem.eql(u8, job.job_type, "scan_conflicts")) {
        const scopes_json = try jobExecutionScopesJson(allocator, job);
        const conflicts = try store.scanConflicts(allocator, .{ .scopes_json = scopes_json, .limit = 100 });
        return try std.fmt.allocPrint(allocator, "{{\"conflict_count\":{d}}}", .{conflicts.len});
    }
    if (std.mem.eql(u8, job.job_type, "lucid_projection")) {
        return try store.runLucidProjectionJob(allocator, job);
    }
    if (std.mem.eql(u8, job.job_type, "extract_memory") or std.mem.eql(u8, job.job_type, "ingest_source") or std.mem.eql(u8, job.job_type, "ingest")) {
        if (job.object_id.len == 0 or !std.mem.eql(u8, job.object_type, "source")) return error.UnsupportedJob;
        const source = (try store.getSource(allocator, job.object_id)) orelse return error.SourceNotFound;
        const job_options = ExtractionJobOptions{
            .create_artifact = jobBoolOption(allocator, job.input_json, "create_artifact", true),
            .extract_memory = if (std.mem.eql(u8, job.job_type, "extract_memory")) true else jobBoolOption(allocator, job.input_json, "extract_memory", true),
            .use_llm_extraction = jobBoolOption(allocator, job.input_json, "use_llm_extraction", false) or jobBoolOption(allocator, job.input_json, "structured_extraction", false),
            .strict_llm_extraction = jobBoolOption(allocator, job.input_json, "strict_llm_extraction", false),
            .storage_route = try jobStorageRouteOption(allocator, job.input_json),
        };
        const extracted = try extractSource(allocator, store, source, options, job_options);
        return try std.fmt.allocPrint(allocator, "{{\"source_id\":\"{s}\",\"artifact_count\":{d},\"memory_atom_count\":{d},\"entity_count\":{d},\"relation_count\":{d},\"vector_chunk_count\":{d},\"extraction_provider\":\"{s}\",\"extraction_fallback\":{s}}}", .{ source.id, extracted.artifact_count, extracted.memory_atom_count, extracted.entity_count, extracted.relation_count, extracted.vector_chunk_count, extracted.extraction_provider, if (extracted.extraction_fallback) "true" else "false" });
    }
    return error.UnsupportedJob;
}

pub fn runVectorOutboxOnce(allocator: std.mem.Allocator, store: *store_mod.Store, options: RunOptions) !store_mod.VectorOutboxRunResult {
    var result = store_mod.VectorOutboxRunResult{};
    const embedded = try runEmbeddingOutbox(allocator, store, options);
    result.processed += embedded.processed;
    result.failed += embedded.failed;
    const indexed = try store.runVectorOutbox(options.outbox_limit);
    result.processed += indexed.processed;
    result.failed += indexed.failed;
    return result;
}

fn jobExecutionScopesJson(allocator: std.mem.Allocator, job: store_mod.Job) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.append(allocator, '[');
    var count: usize = 0;
    try appendUniqueScope(allocator, &out, &count, job.scope);
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, job.permissions_json, .{}) catch {
        try out.append(allocator, ']');
        return out.toOwnedSlice(allocator);
    };
    defer parsed.deinit();
    if (parsed.value == .array) {
        for (parsed.value.array.items) |item| {
            if (item == .string) try appendUniqueScope(allocator, &out, &count, item.string);
        }
    }
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

fn appendUniqueScope(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), count: *usize, scope: []const u8) !void {
    const needle = try std.fmt.allocPrint(allocator, "\"{s}\"", .{scope});
    defer allocator.free(needle);
    if (std.mem.indexOf(u8, out.items, needle) != null) return;
    if (count.* > 0) try out.append(allocator, ',');
    try @import("json_util.zig").appendString(out, allocator, scope);
    count.* += 1;
}

const ExtractionCounts = struct {
    artifact_count: usize = 0,
    memory_atom_count: usize = 0,
    entity_count: usize = 0,
    relation_count: usize = 0,
    vector_chunk_count: usize = 0,
    extraction_provider: []const u8 = "heuristic",
    extraction_fallback: bool = false,
};

const ExtractionJobOptions = struct {
    create_artifact: bool = true,
    extract_memory: bool = true,
    use_llm_extraction: bool = false,
    strict_llm_extraction: bool = false,
    storage_route: store_mod.AgentMemoryStorageRoute = .{},
};

fn jobBoolOption(allocator: std.mem.Allocator, input_json: []const u8, name: []const u8, fallback: bool) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, input_json, .{}) catch return fallback;
    defer parsed.deinit();
    if (parsed.value != .object) return fallback;
    const value = parsed.value.object.get(name) orelse return fallback;
    return switch (value) {
        .bool => |b| b,
        else => fallback,
    };
}

fn jobStorageRouteOption(allocator: std.mem.Allocator, input_json: []const u8) !store_mod.AgentMemoryStorageRoute {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, input_json, .{}) catch return .{};
    defer parsed.deinit();
    if (parsed.value != .object) return .{};
    const obj = parsed.value.object;
    if (json.stringField(obj, "storage")) |value| return store_mod.AgentMemoryStorageRoute.parse(value);
    if (json.stringField(obj, "store")) |value| return store_mod.AgentMemoryStorageRoute.parse(value);
    if (json.stringField(obj, "target_store")) |value| return store_mod.AgentMemoryStorageRoute.parse(value);
    const value = obj.get("stores") orelse return .{};
    return switch (value) {
        .string => |s| store_mod.AgentMemoryStorageRoute.parse(s),
        .array => |items| blk: {
            var stores = try allocator.alloc([]const u8, items.items.len);
            var count: usize = 0;
            for (items.items) |item| {
                if (item != .string) continue;
                stores[count] = item.string;
                count += 1;
            }
            break :blk store_mod.AgentMemoryStorageRoute.fromStores(stores[0..count]);
        },
        else => .{},
    };
}

fn extractSource(allocator: std.mem.Allocator, store: *store_mod.Store, source: domain.Source, options: RunOptions, job_options: ExtractionJobOptions) !ExtractionCounts {
    var counts = ExtractionCounts{};

    const source_ids_json = try extraction.sourceIdsJson(allocator, source.id);
    const entity_names_json = try extraction.extractEntityNamesJson(allocator, source.content);

    var artifact_input: ?store_mod.ArtifactInput = null;
    if (job_options.create_artifact) {
        const artifact_title = try extraction.sourceTitleForArtifact(allocator, source.title, source.source_type);
        const summary = try extraction.summarize(allocator, source.content, 512);
        const agent_summary = try extraction.summarize(allocator, source.content, 1024);
        artifact_input = .{
            .artifact_type = extraction.artifactTypeForSource(source.source_type),
            .title = artifact_title,
            .body = source.content,
            .status = "draft",
            .owner = source.author,
            .scope = source.scope,
            .source_ids_json = source_ids_json,
            .related_entities_json = entity_names_json,
            .permissions_json = source.permissions_json,
            .summary = summary,
            .agent_summary = agent_summary,
            .actor_id = options.actor_id,
            .storage_route = job_options.storage_route,
        };
    }

    var atom_inputs: std.ArrayListUnmanaged(store_mod.MemoryAtomInput) = .empty;
    var relation_inputs: std.ArrayListUnmanaged(store_mod.ExtractedRelationInput) = .empty;
    if (job_options.extract_memory) {
        var structured_done = false;
        if (job_options.use_llm_extraction) {
            const prompt = try extraction.memoryExtractionPrompt(allocator, source.title, source.source_type, source.content);
            const completion: ?providers.CompletionResult = blk: {
                const result = providers.completeWithSystem(allocator, .{
                    .base_url = options.llm_base_url,
                    .api_key = options.llm_api_key,
                    .model = options.llm_model,
                    .timeout_secs = options.provider_timeout_secs,
                    .allow_insecure_http = options.llm_allow_insecure_http,
                    .runtime = options.provider_runtime,
                }, "Return only valid JSON for the requested NullPantry extraction schema. Do not include markdown fences unless the model cannot avoid them. Extract only source-grounded memory atoms and relations.", prompt) catch |err| {
                    if (job_options.strict_llm_extraction) return err;
                    counts.extraction_fallback = true;
                    break :blk null;
                };
                break :blk result;
            };
            if (completion) |result| {
                const parsed_memories: ?[]extraction.ParsedMemory = blk: {
                    const memories = extraction.parseStructuredMemoryResponse(allocator, result.content) catch |err| {
                        if (job_options.strict_llm_extraction) return err;
                        counts.extraction_fallback = true;
                        break :blk null;
                    };
                    break :blk memories;
                };
                if (parsed_memories) |memories| {
                    structured_done = true;
                    counts.extraction_provider = result.provider;
                    for (memories) |parsed| {
                        const evidence_ranges_json = try extraction.evidenceRangeForText(allocator, source.id, source.content, parsed.evidence orelse parsed.text);
                        try atom_inputs.append(allocator, .{
                            .subject_entity_id = null,
                            .predicate = parsed.predicate,
                            .object = parsed.object,
                            .text = parsed.text,
                            .scope = source.scope,
                            .confidence = parsed.confidence,
                            .source_ids_json = source_ids_json,
                            .evidence_ranges_json = evidence_ranges_json,
                            .created_by = "agent",
                            .permissions_json = source.permissions_json,
                            .tags_json = parsed.tags_json,
                            .actor_id = options.actor_id,
                            .storage_route = job_options.storage_route,
                        });
                    }
                    const parsed_relations = extraction.parseStructuredRelationsResponse(allocator, result.content) catch &.{};
                    for (parsed_relations) |parsed| {
                        try relation_inputs.append(allocator, .{
                            .from_entity_name = parsed.from_name,
                            .relation_type = parsed.relation_type,
                            .to_entity_name = parsed.to_name,
                            .source_ids_json = source_ids_json,
                            .scope = source.scope,
                            .permissions_json = source.permissions_json,
                            .confidence = parsed.confidence,
                            .status = "proposed",
                            .actor_id = options.actor_id,
                        });
                    }
                }
            }
        }
        if (!structured_done) {
            counts.extraction_provider = "heuristic";
            var lines = std.mem.splitScalar(u8, source.content, '\n');
            var offset: usize = 0;
            var line_no: usize = 1;
            while (lines.next()) |line| : ({
                offset += line.len + 1;
                line_no += 1;
            }) {
                if (extraction.parseMemoryLine(line)) |parsed| {
                    const evidence_ranges_json = try extraction.evidenceRangeJson(allocator, source.id, offset, offset + line.len, line_no);
                    try atom_inputs.append(allocator, .{
                        .subject_entity_id = null,
                        .predicate = parsed.predicate,
                        .object = parsed.object,
                        .text = parsed.text,
                        .scope = source.scope,
                        .confidence = parsed.confidence,
                        .source_ids_json = source_ids_json,
                        .evidence_ranges_json = evidence_ranges_json,
                        .created_by = "agent",
                        .permissions_json = source.permissions_json,
                        .tags_json = parsed.tags_json,
                        .actor_id = options.actor_id,
                        .storage_route = job_options.storage_route,
                    });
                }
                if (extraction.parseRelationLine(line)) |relation| {
                    try relation_inputs.append(allocator, .{
                        .from_entity_name = relation.from_name,
                        .relation_type = relation.relation_type,
                        .to_entity_name = relation.to_name,
                        .source_ids_json = source_ids_json,
                        .scope = source.scope,
                        .permissions_json = source.permissions_json,
                        .confidence = relation.confidence,
                        .status = "proposed",
                        .actor_id = options.actor_id,
                    });
                }
            }
        }
    }

    const applied = try store.applyExtractedKnowledge(allocator, .{
        .source = source,
        .source_ids_json = source_ids_json,
        .entity_names_json = entity_names_json,
        .artifact = artifact_input,
        .atoms = atom_inputs.items,
        .relations = relation_inputs.items,
        .actor_id = options.actor_id,
    });
    counts.entity_count = applied.entities.len;
    counts.artifact_count = if (applied.artifact != null) 1 else 0;
    counts.memory_atom_count = applied.atoms.len;
    counts.relation_count = applied.relations.len;

    counts.vector_chunk_count += try upsertVector(allocator, store, options, "source", source.id, source.content, source.scope, source.permissions_json);
    if (applied.artifact) |artifact| {
        counts.vector_chunk_count += try upsertVector(allocator, store, options, "artifact", artifact.id, artifact.body, artifact.scope, artifact.permissions_json);
    }
    for (applied.entities) |entity| {
        const text = try vector_text.entity(allocator, entity);
        counts.vector_chunk_count += try upsertVector(allocator, store, options, "entity", entity.id, text, entity.scope, entity.permissions_json);
    }
    for (applied.relations) |relation| {
        const text = try vector_text.relation(allocator, relation);
        counts.vector_chunk_count += try upsertVector(allocator, store, options, "relation", relation.id, text, relation.scope, relation.permissions_json);
    }
    for (applied.atoms) |atom| {
        counts.vector_chunk_count += try upsertVector(allocator, store, options, "memory_atom", atom.id, atom.text, atom.scope, atom.permissions_json);
    }
    return counts;
}

fn resolveEntities(allocator: std.mem.Allocator, store: *store_mod.Store, names_json: []const u8, scope: []const u8, permissions_json: []const u8) ![]domain.Entity {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, names_json, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return allocator.alloc(domain.Entity, 0);
    var out: std.ArrayListUnmanaged(domain.Entity) = .empty;
    for (parsed.value.array.items) |item| {
        const name = switch (item) {
            .string => |s| s,
            else => continue,
        };
        try out.append(allocator, try store.resolveEntity(allocator, .{ .entity_type = "project", .name = name, .scope = scope, .permissions_json = permissions_json, .actor_id = "system:worker" }));
    }
    return out.toOwnedSlice(allocator);
}

fn upsertVector(allocator: std.mem.Allocator, store: *store_mod.Store, options: RunOptions, object_type: []const u8, object_id: []const u8, text: []const u8, scope: []const u8, permissions_json: []const u8) !usize {
    if (text.len == 0) return 0;
    var count: usize = 0;
    const chunks = try vector.chunkText(allocator, text, 1800, 0);
    defer allocator.free(chunks);
    for (chunks) |chunk| {
        const chunk_text = chunk.text;
        if (chunk_text.len > 0) {
            const heading_path_json = try vector.chunkHeadingPathJson(allocator, text, chunk);
            const payload = try store_mod.vectorEmbedPayloadJson(allocator, @intCast(count), chunk_text, scope, permissions_json, heading_path_json, options.embedding_model, options.embedding_dimensions);
            const outbox_id = try store.enqueueVectorOutbox(.{ .action = "embed", .object_type = object_type, .object_id = object_id, .payload_json = payload });
            const embedding_result = providers.embedText(allocator, .{
                .provider = options.embedding_provider,
                .base_url = options.embedding_base_url,
                .api_key = options.embedding_api_key,
                .model = options.embedding_model,
                .dimensions = options.embedding_dimensions,
                .timeout_secs = options.provider_timeout_secs,
                .allow_insecure_http = options.embedding_allow_insecure_http,
                .fallbacks = options.embedding_fallbacks,
                .runtime = options.provider_runtime,
            }, chunk_text, options.embedding_dimensions) catch return count;
            const embedding_json = try vector.embeddingToJson(allocator, embedding_result.embedding);
            _ = try store.upsertVectorChunk(allocator, .{
                .object_type = object_type,
                .object_id = object_id,
                .chunk_ordinal = @intCast(count),
                .text = chunk_text,
                .scope = scope,
                .permissions_json = permissions_json,
                .heading_path_json = heading_path_json,
                .embedding_json = embedding_json,
                .model = embedding_result.model,
                .dimensions = @intCast(embedding_result.embedding.len),
                .actor_id = options.actor_id,
            });
            _ = try store.finishVectorOutbox(outbox_id, "embedded");
            count += 1;
        }
    }
    return count;
}

fn runEmbeddingOutbox(allocator: std.mem.Allocator, store: *store_mod.Store, options: RunOptions) !store_mod.VectorOutboxRunResult {
    const entries = try store.listVectorOutbox(allocator, .{ .action = "embed", .status = "pending", .limit = options.outbox_limit });
    var result = store_mod.VectorOutboxRunResult{};
    for (entries) |entry| {
        if (!try store.claimVectorOutbox(entry.id)) continue;
        processEmbeddingOutboxEntry(allocator, store, options, entry) catch {
            _ = try store.finishVectorOutbox(entry.id, "failed_embedding");
            result.failed += 1;
            continue;
        };
        _ = try store.finishVectorOutbox(entry.id, "embedded");
        result.processed += 1;
    }
    return result;
}

fn processEmbeddingOutboxEntry(allocator: std.mem.Allocator, store: *store_mod.Store, options: RunOptions, entry: store_mod.VectorOutboxEntry) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, entry.payload_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidVectorOutboxPayload;
    const obj = parsed.value.object;
    const text = json.stringField(obj, "text") orelse return error.InvalidVectorOutboxPayload;
    const scope = json.stringField(obj, "scope") orelse "workspace";
    const permissions_json = try rawJsonField(allocator, obj, "permissions", "[]");
    const heading_path_json = if (obj.get("heading_path") != null)
        try rawJsonField(allocator, obj, "heading_path", "[]")
    else
        try rawJsonField(allocator, obj, "heading_path_json", "[]");
    const chunk_ordinal = json.intField(obj, "chunk_ordinal") orelse 0;
    const dimensions: usize = @intCast(@max(@as(i64, 1), json.intField(obj, "dimensions") orelse @as(i64, @intCast(options.embedding_dimensions))));
    const embedding_result = try providers.embedText(allocator, .{
        .provider = options.embedding_provider,
        .base_url = options.embedding_base_url,
        .api_key = options.embedding_api_key,
        .model = options.embedding_model,
        .dimensions = dimensions,
        .timeout_secs = options.provider_timeout_secs,
        .allow_insecure_http = options.embedding_allow_insecure_http,
        .fallbacks = options.embedding_fallbacks,
        .runtime = options.provider_runtime,
    }, text, dimensions);
    const embedding_json = try vector.embeddingToJson(allocator, embedding_result.embedding);
    _ = try store.upsertVectorChunk(allocator, .{
        .object_type = entry.object_type,
        .object_id = entry.object_id,
        .chunk_ordinal = chunk_ordinal,
        .text = text,
        .scope = scope,
        .permissions_json = permissions_json,
        .heading_path_json = heading_path_json,
        .embedding_json = embedding_json,
        .model = embedding_result.model,
        .dimensions = @intCast(embedding_result.embedding.len),
        .actor_id = options.actor_id,
    });
}

fn rawJsonField(allocator: std.mem.Allocator, obj: std.json.ObjectMap, name: []const u8, fallback: []const u8) ![]const u8 {
    const value = obj.get(name) orelse return allocator.dupe(u8, fallback);
    if (value == .null) return allocator.dupe(u8, fallback);
    return try json.jsonFromValue(allocator, value);
}

test "worker processes vector outbox and queued hygiene job" {
    var store = try store_mod.Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const atom = try store.createMemoryAtom(alloc, .{ .text = "worker memory", .scope = "public" });
    const embedding = try vector.deterministicEmbedding(alloc, atom.text, 64);
    const embedding_json = try vector.embeddingToJson(alloc, embedding);
    _ = try store.upsertVectorChunk(alloc, .{ .object_id = atom.id, .text = atom.text, .scope = atom.scope, .embedding_json = embedding_json, .dimensions = 64 });
    _ = try store.createJob(alloc, .{ .job_type = "hygiene", .scope = "public", .input_json = "{}" });
    const result = try runOnce(alloc, &store, .{ .scopes_json = "[\"public\"]" });
    try std.testing.expect(result.vector_outbox_processed >= 1);
    try std.testing.expectEqual(@as(usize, 1), result.jobs_succeeded);
}

test "worker processes durable Lucid projection jobs" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const tmp_random = try ids.make(std.testing.allocator, "");
    defer std.testing.allocator.free(tmp_random);
    const tmp_name = try std.fmt.allocPrint(std.testing.allocator, "lucid_worker_{d}_{s}", .{ std.c.getpid(), tmp_random });
    defer std.testing.allocator.free(tmp_name);
    const tmp_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp_name});
    defer std.testing.allocator.free(tmp_path);
    try std.Io.Dir.cwd().createDirPath(compat.io(), tmp_path);
    defer std.Io.Dir.cwd().deleteTree(compat.io(), tmp_path) catch {};

    const script =
        \\#!/bin/sh
        \\case "$1" in
        \\  store|delete|context) exit 0 ;;
        \\esac
        \\exit 1
        \\
    ;
    const command = try std.fmt.allocPrint(std.testing.allocator, "{s}/lucid", .{tmp_path});
    defer std.testing.allocator.free(command);
    var file = try std.Io.Dir.cwd().createFile(compat.io(), command, .{ .read = true });
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.File.Writer = .init(file, compat.io(), &buffer);
    try writer.interface.writeAll(script);
    try writer.interface.flush();
    try file.setPermissions(compat.io(), .executable_file);
    file.close(compat.io());

    var store = try store_mod.Store.initSQLiteWithOptions(std.testing.allocator, ":memory:", .{
        .lucid_projection = .{
            .enabled = true,
            .command = command,
            .project_scopes_json = "[\"public\"]",
            .store_timeout_ms = 10_000,
            .failure_cooldown_ms = 0,
        },
    });
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    _ = try store.createSource(alloc, .{ .title = "Lucid projection source", .content = "Source projected into Lucid", .scope = "public" });
    const atom = try store.createMemoryAtom(alloc, .{ .text = "Decision: Lucid projection jobs are durable", .scope = "public" });
    const before = try store.lifecycleDiagnostics();
    try std.testing.expect(before.lucid_projection_pending >= 2);

    const result = try runOnce(alloc, &store, .{ .scopes_json = "[\"public\"]", .job_limit = 10 });
    try std.testing.expect(result.lucid_projection_processed >= 2);
    const after = try store.lifecycleDiagnostics();
    try std.testing.expectEqual(@as(usize, 0), after.lucid_projection_pending);

    try std.testing.expect(try store.patchMemoryAtomStatusActor(atom.id, "superseded", false, "agent:reviewer"));
    const pending_delete = try store.lifecycleDiagnostics();
    try std.testing.expectEqual(@as(usize, 1), pending_delete.lucid_projection_pending);
    const delete_result = try runOnce(alloc, &store, .{ .scopes_json = "[\"public\"]", .job_limit = 10 });
    try std.testing.expectEqual(@as(usize, 1), delete_result.lucid_projection_processed);
}

test "worker job execution scopes are unique" {
    const job = store_mod.Job{
        .id = "job_scope_unique",
        .job_type = "scan_conflicts",
        .status = "queued",
        .scope = "project:nullpantry",
        .permissions_json = "[\"project:nullpantry\",\"team:memory\"]",
        .object_type = "",
        .object_id = "",
        .input_json = "{}",
        .result_json = "{}",
        .error_text = null,
        .attempts = 0,
        .created_at_ms = 1,
        .updated_at_ms = 1,
    };
    const scopes = try jobExecutionScopesJson(std.testing.allocator, job);
    defer std.testing.allocator.free(scopes);
    try std.testing.expectEqualStrings("[\"project:nullpantry\",\"team:memory\"]", scopes);
}

test "worker persists embed outbox before provider call and replays locally" {
    var store = try store_mod.Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = try store.createSource(alloc, .{
        .source_type = "transcript",
        .title = "Provider outage transcript",
        .content = "Decision: NullPantry must preserve vector work while embedding providers are unavailable",
        .scope = "public",
    });
    const counts = try extractSource(alloc, &store, source, .{
        .embedding_base_url = "bad://embedding",
        .embedding_model = "unavailable",
        .provider_timeout_secs = 1,
    }, .{});
    try std.testing.expectEqual(@as(usize, 0), counts.vector_chunk_count);

    const pending = try store.listVectorOutbox(alloc, .{ .action = "embed", .status = "pending", .limit = 20 });
    try std.testing.expect(pending.len > 0);

    const result = try runOnce(alloc, &store, .{ .scopes_json = "[\"public\"]", .outbox_limit = 50 });
    try std.testing.expect(result.vector_outbox_processed >= pending.len);
    const still_pending = try store.listVectorOutbox(alloc, .{ .action = "embed", .status = "pending", .limit = 20 });
    try std.testing.expectEqual(@as(usize, 0), still_pending.len);
    const indexed = try store.search(alloc, .{
        .query = "embedding providers unavailable",
        .scopes_json = "[\"public\"]",
        .limit = 10,
        .use_vector = true,
    });
    var saw_source = false;
    for (indexed) |result_item| {
        if (std.mem.eql(u8, result_item.id, source.id)) saw_source = true;
    }
    try std.testing.expect(saw_source);
}

test "worker llm extraction falls back to heuristic unless strict" {
    var store = try store_mod.Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = try store.createSource(alloc, .{
        .source_type = "transcript",
        .title = "Worker LLM fallback",
        .content = "Decision: worker fallback uses heuristic extraction",
        .scope = "public",
    });
    const fallback_job = try store.createJob(alloc, .{
        .job_type = "ingest",
        .scope = "public",
        .permissions_json = "[\"public\"]",
        .object_type = "source",
        .object_id = source.id,
        .input_json = "{\"create_artifact\":false,\"use_llm_extraction\":true}",
    });

    const fallback_result = try runOnce(alloc, &store, .{ .scopes_json = "[\"public\"]", .outbox_limit = 10 });
    try std.testing.expectEqual(@as(usize, 1), fallback_result.jobs_succeeded);
    const fallback_finished = (try store.getJob(alloc, fallback_job.id)).?;
    try std.testing.expectEqualStrings("succeeded", fallback_finished.status);
    try std.testing.expect(std.mem.indexOf(u8, fallback_finished.result_json, "\"extraction_provider\":\"heuristic\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fallback_finished.result_json, "\"extraction_fallback\":true") != null);

    const search = try store.search(alloc, .{
        .query = "worker fallback heuristic",
        .scopes_json = "[\"public\"]",
        .limit = 10,
        .use_vector = false,
    });
    var saw_atom = false;
    for (search) |result_item| {
        if (std.mem.eql(u8, result_item.result_type, "memory_atom") and
            std.mem.indexOf(u8, result_item.text, "worker fallback uses heuristic extraction") != null)
        {
            saw_atom = true;
        }
    }
    try std.testing.expect(saw_atom);

    const strict_source = try store.createSource(alloc, .{
        .source_type = "transcript",
        .title = "Worker LLM strict",
        .content = "Decision: strict worker extraction fails without provider",
        .scope = "public",
    });
    const strict_job = try store.createJob(alloc, .{
        .job_type = "ingest",
        .scope = "public",
        .permissions_json = "[\"public\"]",
        .object_type = "source",
        .object_id = strict_source.id,
        .input_json = "{\"create_artifact\":false,\"use_llm_extraction\":true,\"strict_llm_extraction\":true}",
    });

    const strict_result = try runOnce(alloc, &store, .{ .scopes_json = "[\"public\"]", .outbox_limit = 10 });
    try std.testing.expectEqual(@as(usize, 1), strict_result.jobs_failed);
    const strict_finished = (try store.getJob(alloc, strict_job.id)).?;
    try std.testing.expectEqualStrings("failed", strict_finished.status);
    try std.testing.expect(std.mem.indexOf(u8, strict_finished.error_text orelse "", "ProviderUnavailable") != null);
}
