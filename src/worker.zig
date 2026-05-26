const std = @import("std");
const store_mod = @import("store.zig");
const domain = @import("domain.zig");
const extraction = @import("extraction.zig");
const providers = @import("providers.zig");
const vector = @import("vector.zig");

pub const RunOptions = struct {
    scopes_json: []const u8 = "[\"admin\"]",
    capabilities_json: []const u8 = "[\"read\",\"write\",\"propose\",\"verify\",\"delete\",\"export\",\"feed_apply\"]",
    job_limit: usize = 25,
    outbox_limit: usize = 100,
    embedding_base_url: ?[]const u8 = null,
    embedding_api_key: ?[]const u8 = null,
    embedding_model: ?[]const u8 = null,
    embedding_dimensions: usize = 64,
    provider_timeout_secs: u32 = 30,
};

pub const RunResult = struct {
    jobs_checked: usize = 0,
    jobs_succeeded: usize = 0,
    jobs_failed: usize = 0,
    vector_outbox_processed: usize = 0,
    vector_outbox_failed: usize = 0,
};

pub fn runOnce(allocator: std.mem.Allocator, store: *store_mod.Store, options: RunOptions) !RunResult {
    var result = RunResult{};
    const outbox = try store.runVectorOutbox(options.outbox_limit);
    result.vector_outbox_processed = outbox.processed;
    result.vector_outbox_failed = outbox.failed;

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
        } else |err| {
            const error_text = @errorName(err);
            _ = try store.finishJob(job.id, "failed", "{}", error_text);
            result.jobs_failed += 1;
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
        const outbox = try store.runVectorOutbox(1000);
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
    if (std.mem.eql(u8, job.job_type, "extract_memory") or std.mem.eql(u8, job.job_type, "ingest_source") or std.mem.eql(u8, job.job_type, "ingest")) {
        if (job.object_id.len == 0 or !std.mem.eql(u8, job.object_type, "source")) return error.UnsupportedJob;
        const source = (try store.getSource(allocator, job.object_id)) orelse return error.SourceNotFound;
        const job_options = ExtractionJobOptions{
            .create_artifact = jobBoolOption(allocator, job.input_json, "create_artifact", true),
            .extract_memory = if (std.mem.eql(u8, job.job_type, "extract_memory")) true else jobBoolOption(allocator, job.input_json, "extract_memory", true),
        };
        const extracted = try extractSource(allocator, store, source, options, job_options);
        return try std.fmt.allocPrint(allocator, "{{\"source_id\":\"{s}\",\"artifact_count\":{d},\"memory_atom_count\":{d},\"entity_count\":{d},\"vector_chunk_count\":{d}}}", .{ source.id, extracted.artifact_count, extracted.memory_atom_count, extracted.entity_count, extracted.vector_chunk_count });
    }
    return error.UnsupportedJob;
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
    vector_chunk_count: usize = 0,
};

const ExtractionJobOptions = struct {
    create_artifact: bool = true,
    extract_memory: bool = true,
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

fn extractSource(allocator: std.mem.Allocator, store: *store_mod.Store, source: domain.Source, options: RunOptions, job_options: ExtractionJobOptions) !ExtractionCounts {
    var counts = ExtractionCounts{};
    counts.vector_chunk_count += try upsertVector(allocator, store, options, "source", source.id, source.content, source.scope, source.permissions_json);

    const source_ids_json = try extraction.sourceIdsJson(allocator, source.id);
    const entity_names_json = try extraction.extractEntityNamesJson(allocator, source.content);
    const entities = try resolveEntities(allocator, store, entity_names_json, source.scope, source.permissions_json);
    counts.entity_count = entities.len;

    if (job_options.create_artifact) {
        const artifact_title = try extraction.sourceTitleForArtifact(allocator, source.title, source.source_type);
        const summary = try extraction.summarize(allocator, source.content, 512);
        const agent_summary = try extraction.summarize(allocator, source.content, 1024);
        const artifact = try store.createArtifact(allocator, .{
            .artifact_type = extraction.artifactTypeForSource(source.source_type),
            .title = artifact_title,
            .body = source.content,
            .status = "verified",
            .owner = source.author,
            .scope = source.scope,
            .source_ids_json = source_ids_json,
            .related_entities_json = entity_names_json,
            .permissions_json = source.permissions_json,
            .summary = summary,
            .agent_summary = agent_summary,
        });
        counts.artifact_count = 1;
        counts.vector_chunk_count += try upsertVector(allocator, store, options, "artifact", artifact.id, source.content, source.scope, source.permissions_json);
    }

    if (!job_options.extract_memory) return counts;
    var lines = std.mem.splitScalar(u8, source.content, '\n');
    var offset: usize = 0;
    var line_no: usize = 1;
    while (lines.next()) |line| : ({
        offset += line.len + 1;
        line_no += 1;
    }) {
        const parsed = extraction.parseMemoryLine(line) orelse continue;
        const evidence_ranges_json = try extraction.evidenceRangeJson(allocator, source.id, offset, offset + line.len, line_no);
        const atom = try store.createMemoryAtom(allocator, .{
            .subject_entity_id = if (entities.len > 0) entities[0].id else null,
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
        });
        counts.vector_chunk_count += try upsertVector(allocator, store, options, "memory_atom", atom.id, atom.text, atom.scope, atom.permissions_json);
        counts.memory_atom_count += 1;
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
        try out.append(allocator, try store.resolveEntity(allocator, .{ .entity_type = "project", .name = name, .scope = scope, .permissions_json = permissions_json }));
    }
    return out.toOwnedSlice(allocator);
}

fn upsertVector(allocator: std.mem.Allocator, store: *store_mod.Store, options: RunOptions, object_type: []const u8, object_id: []const u8, text: []const u8, scope: []const u8, permissions_json: []const u8) !usize {
    if (text.len == 0) return 0;
    var count: usize = 0;
    var start: usize = 0;
    while (start < text.len) {
        const end = vectorChunkEnd(text, start);
        const chunk_text = std.mem.trim(u8, text[start..end], " \t\r\n");
        if (chunk_text.len > 0) {
            const embedding_result = try providers.embedText(allocator, .{
                .base_url = options.embedding_base_url,
                .api_key = options.embedding_api_key,
                .model = options.embedding_model,
                .dimensions = options.embedding_dimensions,
                .timeout_secs = options.provider_timeout_secs,
            }, chunk_text, options.embedding_dimensions);
            const embedding_json = try vector.embeddingToJson(allocator, embedding_result.embedding);
            _ = try store.upsertVectorChunk(allocator, .{
                .object_type = object_type,
                .object_id = object_id,
                .chunk_ordinal = @intCast(count),
                .text = chunk_text,
                .scope = scope,
                .permissions_json = permissions_json,
                .embedding_json = embedding_json,
                .model = embedding_result.model,
                .dimensions = @intCast(embedding_result.embedding.len),
            });
            count += 1;
        }
        start = end;
    }
    return count;
}

fn vectorChunkEnd(text: []const u8, start: usize) usize {
    const max_chars: usize = 1800;
    const min_chars: usize = 600;
    const end = @min(text.len, start + max_chars);
    if (end == text.len) return end;
    var scan = end;
    while (scan > start + min_chars) : (scan -= 1) {
        if (text[scan - 1] == '\n') return scan;
    }
    return end;
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
