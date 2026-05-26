const std = @import("std");
const ids = @import("ids.zig");
const domain = @import("domain.zig");
const json = @import("json_util.zig");
const migrations = @import("migrations.zig");
const compat = @import("compat.zig");
const vector_mod = @import("vector.zig");
const lifecycle_mod = @import("lifecycle.zig");
const retrieval_mod = @import("retrieval.zig");

const c = @cImport({
    @cInclude("sqlite3.h");
});

const SQLITE_STATIC: c.sqlite3_destructor_type = null;

pub const BackendKind = enum {
    sqlite,
    postgres,

    pub fn parse(value: []const u8) BackendKind {
        if (std.mem.eql(u8, value, "postgres")) return .postgres;
        return .sqlite;
    }
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    backend: Backend,

    pub const Backend = union(BackendKind) {
        sqlite: SQLiteStore,
        postgres: PostgresStore,
    };

    pub fn initSQLite(allocator: std.mem.Allocator, db_path: [:0]const u8) !Store {
        return .{ .allocator = allocator, .backend = .{ .sqlite = try SQLiteStore.init(allocator, db_path) } };
    }

    pub fn initPostgres(allocator: std.mem.Allocator, url: []const u8) !Store {
        return .{ .allocator = allocator, .backend = .{ .postgres = try PostgresStore.init(allocator, url) } };
    }

    pub fn deinit(self: *Store) void {
        switch (self.backend) {
            .sqlite => |*s| s.deinit(),
            .postgres => |*p| p.deinit(),
        }
    }

    pub fn health(self: *Store) bool {
        return switch (self.backend) {
            .sqlite => |*s| s.health(),
            .postgres => |*p| p.health(),
        };
    }

    pub fn createSource(self: *Store, allocator: std.mem.Allocator, input: SourceInput) !domain.Source {
        return switch (self.backend) {
            .sqlite => |*s| s.createSource(allocator, input),
            .postgres => |*p| p.createSource(allocator, input),
        };
    }

    pub fn getSource(self: *Store, allocator: std.mem.Allocator, id: []const u8) !?domain.Source {
        return switch (self.backend) {
            .sqlite => |*s| s.getSource(allocator, id),
            .postgres => |*p| p.getSource(allocator, id),
        };
    }

    pub fn createArtifact(self: *Store, allocator: std.mem.Allocator, input: ArtifactInput) !domain.Artifact {
        return switch (self.backend) {
            .sqlite => |*s| s.createArtifact(allocator, input),
            .postgres => |*p| p.createArtifact(allocator, input),
        };
    }

    pub fn getArtifact(self: *Store, allocator: std.mem.Allocator, id: []const u8) !?domain.Artifact {
        return switch (self.backend) {
            .sqlite => |*s| s.getArtifact(allocator, id),
            .postgres => |*p| p.getArtifact(allocator, id),
        };
    }

    pub fn resolveEntity(self: *Store, allocator: std.mem.Allocator, input: EntityInput) !domain.Entity {
        return switch (self.backend) {
            .sqlite => |*s| s.resolveEntity(allocator, input),
            .postgres => |*p| p.resolveEntity(allocator, input),
        };
    }

    pub fn createRelation(self: *Store, allocator: std.mem.Allocator, input: RelationInput) !domain.Relation {
        return switch (self.backend) {
            .sqlite => |*s| s.createRelation(allocator, input),
            .postgres => |*p| p.createRelation(allocator, input),
        };
    }

    pub fn createMemoryAtom(self: *Store, allocator: std.mem.Allocator, input: MemoryAtomInput) !domain.MemoryAtom {
        return switch (self.backend) {
            .sqlite => |*s| s.createMemoryAtom(allocator, input),
            .postgres => |*p| p.createMemoryAtom(allocator, input),
        };
    }

    pub fn getMemoryAtom(self: *Store, allocator: std.mem.Allocator, id: []const u8) !?domain.MemoryAtom {
        return switch (self.backend) {
            .sqlite => |*s| s.getMemoryAtom(allocator, id),
            .postgres => |*p| p.getMemoryAtom(allocator, id),
        };
    }

    pub fn patchMemoryAtomStatus(self: *Store, id: []const u8, status: []const u8, verified: bool) !bool {
        return switch (self.backend) {
            .sqlite => |*s| s.patchMemoryAtomStatus(id, status, verified),
            .postgres => |*p| p.patchMemoryAtomStatus(id, status, verified),
        };
    }

    pub fn search(self: *Store, allocator: std.mem.Allocator, input: SearchInput) ![]domain.SearchResult {
        return switch (self.backend) {
            .sqlite => |*s| s.search(allocator, input),
            .postgres => |*p| p.search(allocator, input),
        };
    }

    pub fn upsertVectorChunk(self: *Store, allocator: std.mem.Allocator, input: VectorChunkInput) !VectorChunk {
        return switch (self.backend) {
            .sqlite => |*s| s.upsertVectorChunk(allocator, input),
            .postgres => |*p| p.upsertVectorChunk(allocator, input),
        };
    }

    pub fn vectorSearch(self: *Store, allocator: std.mem.Allocator, input: VectorSearchInput) ![]vector_mod.VectorMatch {
        return switch (self.backend) {
            .sqlite => |*s| s.vectorSearch(allocator, input),
            .postgres => |*p| p.vectorSearch(allocator, input),
        };
    }

    pub fn enqueueVectorOutbox(self: *Store, input: VectorOutboxInput) !i64 {
        return switch (self.backend) {
            .sqlite => |*s| s.enqueueVectorOutbox(input),
            .postgres => |*p| p.enqueueVectorOutbox(input),
        };
    }

    pub fn countVectorOutbox(self: *Store, status: ?[]const u8) !usize {
        return switch (self.backend) {
            .sqlite => |*s| s.countVectorOutbox(status),
            .postgres => |*p| p.countVectorOutbox(status),
        };
    }

    pub fn runVectorOutbox(self: *Store, limit: usize) !VectorOutboxRunResult {
        return switch (self.backend) {
            .sqlite => |*s| s.runVectorOutbox(limit),
            .postgres => |*p| p.runVectorOutbox(limit),
        };
    }

    pub fn appendFeedEvent(self: *Store, input: FeedEventInput) !i64 {
        return switch (self.backend) {
            .sqlite => |*s| s.appendFeedEvent(input),
            .postgres => |*p| p.appendFeedEvent(input),
        };
    }

    pub fn listFeedEvents(self: *Store, allocator: std.mem.Allocator, input: FeedListInput) ![]FeedEvent {
        return switch (self.backend) {
            .sqlite => |*s| s.listFeedEvents(allocator, input),
            .postgres => |*p| p.listFeedEvents(allocator, input),
        };
    }

    pub fn getFeedEventByDedupeKey(self: *Store, allocator: std.mem.Allocator, dedupe_key: []const u8) !?FeedEvent {
        return switch (self.backend) {
            .sqlite => |*s| s.getFeedEventByDedupeKey(allocator, dedupe_key),
            .postgres => |*p| p.getFeedEventByDedupeKey(allocator, dedupe_key),
        };
    }

    pub fn createLifecycleSnapshot(self: *Store, allocator: std.mem.Allocator, snapshot_type: []const u8, summary_json: []const u8) !LifecycleSnapshot {
        return switch (self.backend) {
            .sqlite => |*s| s.createLifecycleSnapshot(allocator, snapshot_type, summary_json),
            .postgres => |*p| p.createLifecycleSnapshot(allocator, snapshot_type, summary_json),
        };
    }

    pub fn lifecycleDiagnostics(self: *Store) !LifecycleDiagnostics {
        return switch (self.backend) {
            .sqlite => |*s| s.lifecycleDiagnostics(),
            .postgres => |*p| p.lifecycleDiagnostics(),
        };
    }

    pub fn putResponseCache(self: *Store, input: ResponseCacheInput) !void {
        return switch (self.backend) {
            .sqlite => |*s| s.putResponseCache(input),
            .postgres => |*p| p.putResponseCache(input),
        };
    }

    pub fn getResponseCache(self: *Store, allocator: std.mem.Allocator, cache_key: []const u8, now_ms: i64) !?ResponseCacheEntry {
        return switch (self.backend) {
            .sqlite => |*s| s.getResponseCache(allocator, cache_key, now_ms),
            .postgres => |*p| p.getResponseCache(allocator, cache_key, now_ms),
        };
    }

    pub fn putSemanticCache(self: *Store, input: SemanticCacheInput) !void {
        return switch (self.backend) {
            .sqlite => |*s| s.putSemanticCache(input),
            .postgres => |*p| p.putSemanticCache(input),
        };
    }

    pub fn searchSemanticCache(self: *Store, allocator: std.mem.Allocator, input: SemanticCacheSearchInput) !?SemanticCacheMatch {
        return switch (self.backend) {
            .sqlite => |*s| s.searchSemanticCache(allocator, input),
            .postgres => |*p| p.searchSemanticCache(allocator, input),
        };
    }

    pub fn runHygiene(self: *Store, input: HygieneRunInput) !HygieneRunResult {
        return switch (self.backend) {
            .sqlite => |*s| s.runHygiene(input),
            .postgres => |*p| p.runHygiene(input),
        };
    }

    pub fn createContextPack(self: *Store, allocator: std.mem.Allocator, input: ContextPackInput) !ContextPackResult {
        return switch (self.backend) {
            .sqlite => |*s| s.createContextPack(allocator, input),
            .postgres => |*p| p.createContextPack(allocator, input),
        };
    }

    pub fn compatStore(self: *Store, allocator: std.mem.Allocator, input: CompatStoreInput) !void {
        return switch (self.backend) {
            .sqlite => |*s| s.compatStore(allocator, input),
            .postgres => |*p| p.compatStore(allocator, input),
        };
    }

    pub fn compatGet(self: *Store, allocator: std.mem.Allocator, key: []const u8, session_id: ?[]const u8) !?domain.CompatMemory {
        return switch (self.backend) {
            .sqlite => |*s| s.compatGet(allocator, key, session_id),
            .postgres => |*p| p.compatGet(allocator, key, session_id),
        };
    }

    pub fn compatList(self: *Store, allocator: std.mem.Allocator, category: ?[]const u8, session_id: ?[]const u8) ![]domain.CompatMemory {
        return switch (self.backend) {
            .sqlite => |*s| s.compatList(allocator, category, session_id),
            .postgres => |*p| p.compatList(allocator, category, session_id),
        };
    }

    pub fn compatSearch(self: *Store, allocator: std.mem.Allocator, query: []const u8, limit: usize, session_id: ?[]const u8) ![]domain.CompatMemory {
        return switch (self.backend) {
            .sqlite => |*s| s.compatSearch(allocator, query, limit, session_id),
            .postgres => |*p| p.compatSearch(allocator, query, limit, session_id),
        };
    }

    pub fn compatDelete(self: *Store, key: []const u8, session_id: ?[]const u8) !bool {
        return switch (self.backend) {
            .sqlite => |*s| s.compatDelete(key, session_id),
            .postgres => |*p| p.compatDelete(key, session_id),
        };
    }

    pub fn compatCount(self: *Store) !usize {
        return switch (self.backend) {
            .sqlite => |*s| s.compatCount(),
            .postgres => |*p| p.compatCount(),
        };
    }

    pub fn saveMessage(self: *Store, session_id: []const u8, role: []const u8, content: []const u8) !void {
        return switch (self.backend) {
            .sqlite => |*s| s.saveMessage(session_id, role, content),
            .postgres => |*p| p.saveMessage(session_id, role, content),
        };
    }

    pub fn loadMessages(self: *Store, allocator: std.mem.Allocator, session_id: []const u8) ![]Message {
        return switch (self.backend) {
            .sqlite => |*s| s.loadMessages(allocator, session_id),
            .postgres => |*p| p.loadMessages(allocator, session_id),
        };
    }

    pub fn clearMessages(self: *Store, session_id: []const u8) !void {
        return switch (self.backend) {
            .sqlite => |*s| s.clearMessages(session_id),
            .postgres => |*p| p.clearMessages(session_id),
        };
    }

    pub fn clearAutoSaved(self: *Store, session_id: ?[]const u8) !void {
        return switch (self.backend) {
            .sqlite => |*s| s.clearAutoSaved(session_id),
            .postgres => |*p| p.clearAutoSaved(session_id),
        };
    }

    pub fn saveUsage(self: *Store, session_id: []const u8, total_tokens: u64) !void {
        return switch (self.backend) {
            .sqlite => |*s| s.saveUsage(session_id, total_tokens),
            .postgres => |*p| p.saveUsage(session_id, total_tokens),
        };
    }

    pub fn deleteUsage(self: *Store, session_id: []const u8) !bool {
        return switch (self.backend) {
            .sqlite => |*s| s.deleteUsage(session_id),
            .postgres => |*p| p.deleteUsage(session_id),
        };
    }

    pub fn loadUsage(self: *Store, session_id: []const u8) !?u64 {
        return switch (self.backend) {
            .sqlite => |*s| s.loadUsage(session_id),
            .postgres => |*p| p.loadUsage(session_id),
        };
    }

    pub fn listSessions(self: *Store, allocator: std.mem.Allocator, limit: usize, offset: usize) !HistoryList {
        return switch (self.backend) {
            .sqlite => |*s| s.listSessions(allocator, limit, offset),
            .postgres => |*p| p.listSessions(allocator, limit, offset),
        };
    }

    pub fn history(self: *Store, allocator: std.mem.Allocator, session_id: []const u8, limit: usize, offset: usize) !HistoryShow {
        return switch (self.backend) {
            .sqlite => |*s| s.history(allocator, session_id, limit, offset),
            .postgres => |*p| p.history(allocator, session_id, limit, offset),
        };
    }

    pub fn createJob(self: *Store, allocator: std.mem.Allocator, input: JobInput) !Job {
        return switch (self.backend) {
            .sqlite => |*s| s.createJob(allocator, input),
            .postgres => |*p| p.createJob(allocator, input),
        };
    }

    pub fn getJob(self: *Store, allocator: std.mem.Allocator, id: []const u8) !?Job {
        return switch (self.backend) {
            .sqlite => |*s| s.getJob(allocator, id),
            .postgres => |*p| p.getJob(allocator, id),
        };
    }

    pub fn listJobs(self: *Store, allocator: std.mem.Allocator, input: JobListInput) ![]Job {
        return switch (self.backend) {
            .sqlite => |*s| s.listJobs(allocator, input),
            .postgres => |*p| p.listJobs(allocator, input),
        };
    }

    pub fn finishJob(self: *Store, id: []const u8, status: []const u8, result_json: []const u8, error_text: ?[]const u8) !bool {
        return switch (self.backend) {
            .sqlite => |*s| s.finishJob(id, status, result_json, error_text),
            .postgres => |*p| p.finishJob(id, status, result_json, error_text),
        };
    }

    pub fn listConflicts(self: *Store, allocator: std.mem.Allocator, input: ConflictListInput) ![]KnowledgeConflict {
        return switch (self.backend) {
            .sqlite => |*s| s.listConflicts(allocator, input),
            .postgres => |*p| p.listConflicts(allocator, input),
        };
    }

    pub fn scanConflicts(self: *Store, allocator: std.mem.Allocator, input: ConflictListInput) ![]KnowledgeConflict {
        return switch (self.backend) {
            .sqlite => |*s| s.scanConflicts(allocator, input),
            .postgres => |*p| p.scanConflicts(allocator, input),
        };
    }
};

pub const SourceInput = struct {
    source_type: []const u8 = "manual",
    title: []const u8,
    raw_content_uri: ?[]const u8 = null,
    content: []const u8 = "",
    author: ?[]const u8 = null,
    participants_json: []const u8 = "[]",
    permissions_json: []const u8 = "[]",
    scope: []const u8 = "workspace",
    checksum: ?[]const u8 = null,
    language: ?[]const u8 = null,
    related_entities_json: []const u8 = "[]",
    metadata_json: []const u8 = "{}",
};

pub const ArtifactInput = struct {
    artifact_type: []const u8 = "page",
    title: []const u8,
    body: []const u8 = "",
    status: []const u8 = "draft",
    owner: ?[]const u8 = null,
    space_id: ?[]const u8 = null,
    source_ids_json: []const u8 = "[]",
    related_entities_json: []const u8 = "[]",
    permissions_json: []const u8 = "[]",
    summary: ?[]const u8 = null,
    agent_summary: ?[]const u8 = null,
};

pub const EntityInput = struct {
    entity_type: []const u8 = "concept",
    name: []const u8,
    aliases_json: []const u8 = "[]",
    description: ?[]const u8 = null,
    canonical_artifact_id: ?[]const u8 = null,
    metadata_json: []const u8 = "{}",
};

pub const RelationInput = struct {
    from_entity_id: []const u8,
    relation_type: []const u8,
    to_entity_id: []const u8,
    source_ids_json: []const u8 = "[]",
    confidence: f64 = 0.5,
    status: []const u8 = "proposed",
};

pub const MemoryAtomInput = struct {
    subject_entity_id: ?[]const u8 = null,
    predicate: []const u8 = "states",
    object: []const u8 = "",
    text: []const u8,
    scope: []const u8 = "workspace",
    confidence: f64 = 0.5,
    status: ?[]const u8 = null,
    source_ids_json: []const u8 = "[]",
    evidence_ranges_json: []const u8 = "[]",
    created_by: []const u8 = "human",
    valid_from_ms: ?i64 = null,
    valid_until_ms: ?i64 = null,
    owner: ?[]const u8 = null,
    permissions_json: []const u8 = "[]",
    tags_json: []const u8 = "[]",
};

pub const SearchInput = struct {
    query: []const u8,
    limit: usize = 10,
    scopes_json: []const u8 = "[]",
    include_deprecated: bool = false,
    include_sessions: bool = false,
    use_vector: bool = true,
};

pub const VectorChunkInput = struct {
    object_type: []const u8 = "memory_atom",
    object_id: []const u8,
    chunk_ordinal: i64 = 0,
    text: []const u8 = "",
    scope: []const u8 = "workspace",
    permissions_json: []const u8 = "[]",
    embedding_json: []const u8,
    model: ?[]const u8 = null,
    dimensions: i64,
};

pub const VectorChunk = struct {
    id: []const u8,
    object_type: []const u8,
    object_id: []const u8,
    chunk_ordinal: i64,
    text: []const u8,
    scope: []const u8,
    permissions_json: []const u8,
    embedding_json: []const u8,
    model: ?[]const u8,
    dimensions: i64,
    created_at_ms: i64,
    updated_at_ms: i64,
};

pub const VectorSearchInput = struct {
    embedding_json: []const u8,
    scopes_json: []const u8 = "[]",
    limit: usize = 10,
};

pub const VectorOutboxInput = struct {
    action: []const u8,
    object_type: []const u8,
    object_id: []const u8,
    payload_json: []const u8 = "{}",
};

pub const VectorOutboxRunResult = struct {
    processed: usize = 0,
    failed: usize = 0,
};

pub const FeedEventInput = struct {
    event_type: []const u8,
    object_type: []const u8,
    object_id: []const u8,
    scope: []const u8 = "workspace",
    dedupe_key: ?[]const u8 = null,
    payload_json: []const u8 = "{}",
    status: []const u8 = "pending",
};

pub const FeedListInput = struct {
    since_id: i64 = 0,
    limit: usize = 100,
    scopes_json: []const u8 = "[]",
};

pub const FeedEvent = struct {
    id: i64,
    event_type: []const u8,
    object_type: []const u8,
    object_id: []const u8,
    scope: []const u8,
    dedupe_key: ?[]const u8,
    payload_json: []const u8,
    status: []const u8,
    created_at_ms: i64,
    applied_at_ms: ?i64,

    pub fn writeJson(self: FeedEvent, allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
        try out.print(allocator, "{{\"id\":{d},\"event_type\":", .{self.id});
        try @import("json_util.zig").appendString(out, allocator, self.event_type);
        try out.appendSlice(allocator, ",\"object_type\":");
        try @import("json_util.zig").appendString(out, allocator, self.object_type);
        try out.appendSlice(allocator, ",\"object_id\":");
        try @import("json_util.zig").appendString(out, allocator, self.object_id);
        try out.appendSlice(allocator, ",\"scope\":");
        try @import("json_util.zig").appendString(out, allocator, self.scope);
        try out.appendSlice(allocator, ",\"dedupe_key\":");
        try @import("json_util.zig").appendNullableString(out, allocator, self.dedupe_key);
        try out.appendSlice(allocator, ",\"payload\":");
        try @import("json_util.zig").appendRawJsonOr(out, allocator, self.payload_json, "{}");
        try out.appendSlice(allocator, ",\"status\":");
        try @import("json_util.zig").appendString(out, allocator, self.status);
        try out.print(allocator, ",\"created_at_ms\":{d},\"applied_at_ms\":", .{self.created_at_ms});
        if (self.applied_at_ms) |v| try out.print(allocator, "{d}", .{v}) else try out.appendSlice(allocator, "null");
        try out.append(allocator, '}');
    }
};

pub const LifecycleSnapshot = struct {
    id: []const u8,
    snapshot_type: []const u8,
    summary_json: []const u8,
    created_at_ms: i64,
};

pub const LifecycleDiagnostics = struct {
    total_memory_atoms: usize,
    stale_memory_atoms: usize,
    vector_outbox_pending: usize,
    cache_entries: usize,
};

pub const ResponseCacheInput = struct {
    cache_key: []const u8,
    response_json: []const u8,
    ttl_ms: i64 = 0,
    now_ms: ?i64 = null,
};

pub const ResponseCacheEntry = struct {
    cache_key: []const u8,
    response_json: []const u8,
    created_at_ms: i64,
    expires_at_ms: i64,
};

pub const SemanticCacheInput = struct {
    cache_key: []const u8,
    query: []const u8,
    response_json: []const u8,
    embedding_json: []const u8,
    ttl_ms: i64 = 0,
    now_ms: ?i64 = null,
};

pub const SemanticCacheSearchInput = struct {
    embedding_json: []const u8,
    min_score: f32 = 0.82,
    now_ms: ?i64 = null,
};

pub const SemanticCacheMatch = struct {
    cache_key: []const u8,
    query: []const u8,
    response_json: []const u8,
    score: f32,
    created_at_ms: i64,
    expires_at_ms: i64,
};

pub const HygieneRunInput = struct {
    stale_after_ms: i64 = 30 * 24 * 60 * 60 * 1000,
    archive_after_ms: i64 = 90 * 24 * 60 * 60 * 1000,
    purge_after_ms: i64 = 0,
    hard_delete: bool = false,
    now_ms: ?i64 = null,
};

pub const HygieneRunResult = struct {
    checked: usize = 0,
    marked_stale: usize = 0,
    archived: usize = 0,
    purged: usize = 0,
    expired_cache_entries: usize = 0,
};

pub const ContextPackInput = struct {
    purpose: []const u8 = "task",
    target: []const u8 = "agent",
    query: []const u8,
    token_budget: i64 = 12000,
    scopes_json: []const u8 = "[]",
};

pub const ContextPackResult = struct {
    id: []const u8,
    purpose: []const u8,
    target: []const u8,
    query: []const u8,
    generated_summary: []const u8,
    included_sources_json: []const u8,
    included_artifacts_json: []const u8,
    included_memory_atoms_json: []const u8,
    token_budget: i64,
    created_at_ms: i64,
};

pub const CompatStoreInput = struct {
    key: []const u8,
    content: []const u8,
    category: []const u8 = "core",
    session_id: ?[]const u8 = null,
};

pub const Message = struct {
    role: []const u8,
    content: []const u8,
    created_at_ms: i64,
};

pub const SessionInfo = struct {
    session_id: []const u8,
    message_count: u64,
    first_message_at: i64,
    last_message_at: i64,
};

pub const HistoryList = struct {
    total: u64,
    sessions: []SessionInfo,
};

pub const HistoryShow = struct {
    total: u64,
    messages: []Message,
};

pub const JobInput = struct {
    job_type: []const u8,
    scope: []const u8 = "workspace",
    object_type: []const u8 = "",
    object_id: []const u8 = "",
    input_json: []const u8 = "{}",
};

pub const JobListInput = struct {
    scopes_json: []const u8 = "[]",
    status: ?[]const u8 = null,
    limit: usize = 100,
};

pub const Job = struct {
    id: []const u8,
    job_type: []const u8,
    status: []const u8,
    scope: []const u8,
    object_type: []const u8,
    object_id: []const u8,
    input_json: []const u8,
    result_json: []const u8,
    error_text: ?[]const u8,
    attempts: i64,
    created_at_ms: i64,
    updated_at_ms: i64,

    pub fn writeJson(self: Job, allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
        try out.appendSlice(allocator, "{\"id\":");
        try @import("json_util.zig").appendString(out, allocator, self.id);
        try out.appendSlice(allocator, ",\"type\":");
        try @import("json_util.zig").appendString(out, allocator, self.job_type);
        try out.appendSlice(allocator, ",\"status\":");
        try @import("json_util.zig").appendString(out, allocator, self.status);
        try out.appendSlice(allocator, ",\"scope\":");
        try @import("json_util.zig").appendString(out, allocator, self.scope);
        try out.appendSlice(allocator, ",\"object_type\":");
        try @import("json_util.zig").appendString(out, allocator, self.object_type);
        try out.appendSlice(allocator, ",\"object_id\":");
        try @import("json_util.zig").appendString(out, allocator, self.object_id);
        try out.appendSlice(allocator, ",\"input\":");
        try @import("json_util.zig").appendRawJsonOr(out, allocator, self.input_json, "{}");
        try out.appendSlice(allocator, ",\"result\":");
        try @import("json_util.zig").appendRawJsonOr(out, allocator, self.result_json, "{}");
        try out.appendSlice(allocator, ",\"error\":");
        try @import("json_util.zig").appendNullableString(out, allocator, self.error_text);
        try out.print(allocator, ",\"attempts\":{d},\"created_at_ms\":{d},\"updated_at_ms\":{d}}}", .{ self.attempts, self.created_at_ms, self.updated_at_ms });
    }
};

pub const ConflictListInput = struct {
    scopes_json: []const u8 = "[]",
    status: ?[]const u8 = "open",
    limit: usize = 100,
};

pub const KnowledgeConflict = struct {
    id: []const u8,
    conflict_type: []const u8,
    object_a_type: []const u8,
    object_a_id: []const u8,
    object_b_type: []const u8,
    object_b_id: []const u8,
    scope: []const u8,
    status: []const u8,
    summary: []const u8,
    created_at_ms: i64,
    resolved_at_ms: ?i64,

    pub fn writeJson(self: KnowledgeConflict, allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
        try out.appendSlice(allocator, "{\"id\":");
        try @import("json_util.zig").appendString(out, allocator, self.id);
        try out.appendSlice(allocator, ",\"type\":");
        try @import("json_util.zig").appendString(out, allocator, self.conflict_type);
        try out.appendSlice(allocator, ",\"object_a_type\":");
        try @import("json_util.zig").appendString(out, allocator, self.object_a_type);
        try out.appendSlice(allocator, ",\"object_a_id\":");
        try @import("json_util.zig").appendString(out, allocator, self.object_a_id);
        try out.appendSlice(allocator, ",\"object_b_type\":");
        try @import("json_util.zig").appendString(out, allocator, self.object_b_type);
        try out.appendSlice(allocator, ",\"object_b_id\":");
        try @import("json_util.zig").appendString(out, allocator, self.object_b_id);
        try out.appendSlice(allocator, ",\"scope\":");
        try @import("json_util.zig").appendString(out, allocator, self.scope);
        try out.appendSlice(allocator, ",\"status\":");
        try @import("json_util.zig").appendString(out, allocator, self.status);
        try out.appendSlice(allocator, ",\"summary\":");
        try @import("json_util.zig").appendString(out, allocator, self.summary);
        try out.print(allocator, ",\"created_at_ms\":{d},\"resolved_at_ms\":", .{self.created_at_ms});
        if (self.resolved_at_ms) |v| try out.print(allocator, "{d}", .{v}) else try out.appendSlice(allocator, "null");
        try out.append(allocator, '}');
    }
};

pub const SQLiteStore = struct {
    allocator: std.mem.Allocator,
    db: *c.sqlite3,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, db_path: [:0]const u8) !Self {
        var db: ?*c.sqlite3 = null;
        if (c.sqlite3_open(db_path.ptr, &db) != c.SQLITE_OK) {
            if (db) |handle| _ = c.sqlite3_close(handle);
            return error.OpenDatabaseFailed;
        }
        errdefer _ = c.sqlite3_close(db.?);
        _ = c.sqlite3_busy_timeout(db.?, 5000);
        var self = Self{ .allocator = allocator, .db = db.? };
        try self.exec(migrations.sqlite_schema);
        try self.applyCompatibilityMigrations();
        return self;
    }

    pub fn deinit(self: *Self) void {
        _ = c.sqlite3_close(self.db);
    }

    pub fn health(_: *Self) bool {
        return true;
    }

    fn exec(self: *Self, sql: [*:0]const u8) !void {
        var err_msg: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.db, sql, null, null, &err_msg);
        if (rc != c.SQLITE_OK) {
            std.log.err("sqlite exec failed: {s}", .{if (err_msg != null) std.mem.span(err_msg) else std.mem.span(c.sqlite3_errmsg(self.db))});
            if (err_msg) |msg| c.sqlite3_free(msg);
            return error.SqlExecFailed;
        }
    }

    fn prepare(self: *Self, sql: [*:0]const u8) !*c.sqlite3_stmt {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlPrepareFailed;
        }
        return stmt.?;
    }

    fn applyCompatibilityMigrations(self: *Self) !void {
        if (!try self.columnExists("vector_chunks", "permissions_json")) {
            try self.exec("ALTER TABLE vector_chunks ADD COLUMN permissions_json TEXT NOT NULL DEFAULT '[]'");
        }
        if (!try self.columnExists("memory_feed_events", "dedupe_key")) {
            try self.exec("ALTER TABLE memory_feed_events ADD COLUMN dedupe_key TEXT");
        }
        if (!try self.columnExists("response_cache", "response_json")) {
            try self.exec("ALTER TABLE response_cache ADD COLUMN response_json TEXT NOT NULL DEFAULT '{}'");
        }
        if (!try self.columnExists("response_cache", "expires_at_ms")) {
            try self.exec("ALTER TABLE response_cache ADD COLUMN expires_at_ms INTEGER NOT NULL DEFAULT 0");
        }
        if (!try self.columnExists("semantic_cache", "query")) {
            try self.exec("ALTER TABLE semantic_cache ADD COLUMN query TEXT NOT NULL DEFAULT ''");
        }
        if (!try self.columnExists("semantic_cache", "response_json")) {
            try self.exec("ALTER TABLE semantic_cache ADD COLUMN response_json TEXT NOT NULL DEFAULT '{}'");
        }
        if (!try self.columnExists("semantic_cache", "expires_at_ms")) {
            try self.exec("ALTER TABLE semantic_cache ADD COLUMN expires_at_ms INTEGER NOT NULL DEFAULT 0");
        }
        try self.exec("CREATE UNIQUE INDEX IF NOT EXISTS idx_memory_feed_events_dedupe_key ON memory_feed_events(dedupe_key) WHERE dedupe_key IS NOT NULL");
        try self.exec("INSERT OR IGNORE INTO schema_migrations (version, name, applied_at_ms) VALUES (2, 'security_and_retrieval_hardening', strftime('%s','now') * 1000)");
        try self.exec("INSERT OR IGNORE INTO schema_migrations (version, name, applied_at_ms) VALUES (3, 'runtime_lifecycle_cache', strftime('%s','now') * 1000)");
        try self.exec("CREATE TABLE IF NOT EXISTS jobs (id TEXT PRIMARY KEY, job_type TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'queued', scope TEXT NOT NULL DEFAULT 'workspace', object_type TEXT NOT NULL DEFAULT '', object_id TEXT NOT NULL DEFAULT '', input_json TEXT NOT NULL DEFAULT '{}', result_json TEXT NOT NULL DEFAULT '{}', error_text TEXT, attempts INTEGER NOT NULL DEFAULT 0, created_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_jobs_scope_status ON jobs(scope, status, created_at_ms)");
        try self.exec("CREATE TABLE IF NOT EXISTS knowledge_conflicts (id TEXT PRIMARY KEY, conflict_type TEXT NOT NULL, object_a_type TEXT NOT NULL, object_a_id TEXT NOT NULL, object_b_type TEXT NOT NULL, object_b_id TEXT NOT NULL, scope TEXT NOT NULL DEFAULT 'workspace', status TEXT NOT NULL DEFAULT 'open', summary TEXT NOT NULL, created_at_ms INTEGER NOT NULL, resolved_at_ms INTEGER)");
        try self.exec("CREATE UNIQUE INDEX IF NOT EXISTS idx_knowledge_conflicts_pair ON knowledge_conflicts(conflict_type, object_a_id, object_b_id)");
        try self.exec("CREATE TABLE IF NOT EXISTS connector_cursors (connector TEXT NOT NULL, scope TEXT NOT NULL, cursor TEXT NOT NULL DEFAULT '', config_json TEXT NOT NULL DEFAULT '{}', updated_at_ms INTEGER NOT NULL, PRIMARY KEY (connector, scope))");
        try self.exec("INSERT OR IGNORE INTO schema_migrations (version, name, applied_at_ms) VALUES (4, 'ingest_jobs_conflicts', strftime('%s','now') * 1000)");
    }

    fn columnExists(self: *Self, comptime table: []const u8, column: []const u8) !bool {
        const stmt = try self.prepare("PRAGMA table_info(" ++ table ++ ")");
        defer _ = c.sqlite3_finalize(stmt);
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const name = try columnText(self.allocator, stmt, 1);
            defer self.allocator.free(name);
            if (std.mem.eql(u8, name, column)) return true;
        }
        return false;
    }

    fn bindText(stmt: *c.sqlite3_stmt, index: c_int, value: []const u8) void {
        _ = c.sqlite3_bind_text(stmt, index, value.ptr, @intCast(value.len), SQLITE_STATIC);
    }

    fn bindNullableText(stmt: *c.sqlite3_stmt, index: c_int, value: ?[]const u8) void {
        if (value) |v| bindText(stmt, index, v) else _ = c.sqlite3_bind_null(stmt, index);
    }

    fn columnText(allocator: std.mem.Allocator, stmt: *c.sqlite3_stmt, index: c_int) ![]u8 {
        const ptr = c.sqlite3_column_text(stmt, index) orelse return allocator.dupe(u8, "");
        const len: usize = @intCast(c.sqlite3_column_bytes(stmt, index));
        const bytes: [*]const u8 = @ptrCast(ptr);
        return allocator.dupe(u8, bytes[0..len]);
    }

    fn columnTextNullable(allocator: std.mem.Allocator, stmt: *c.sqlite3_stmt, index: c_int) !?[]u8 {
        if (c.sqlite3_column_type(stmt, index) == c.SQLITE_NULL) return null;
        const value = try columnText(allocator, stmt, index);
        return value;
    }

    fn insertAudit(self: *Self, event_type: []const u8, object_type: []const u8, object_id: []const u8) void {
        const stmt = self.prepare("INSERT INTO audit_events (event_type, actor, object_type, object_id, payload_json, created_at_ms) VALUES (?1, NULL, ?2, ?3, '{}', ?4)") catch return;
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, event_type);
        bindText(stmt, 2, object_type);
        bindText(stmt, 3, object_id);
        _ = c.sqlite3_bind_int64(stmt, 4, ids.nowMs());
        _ = c.sqlite3_step(stmt);
    }

    pub fn createSource(self: *Self, allocator: std.mem.Allocator, input: SourceInput) !domain.Source {
        const id = try ids.make(allocator, "src_");
        const now = ids.nowMs();
        const stmt = try self.prepare("INSERT INTO sources (id,type,title,raw_content_uri,content,author,participants_json,permissions_json,scope,created_at_ms,imported_at_ms,checksum,language,related_entities_json,metadata_json) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15)");
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, id);
        bindText(stmt, 2, input.source_type);
        bindText(stmt, 3, input.title);
        bindNullableText(stmt, 4, input.raw_content_uri);
        bindText(stmt, 5, input.content);
        bindNullableText(stmt, 6, input.author);
        bindText(stmt, 7, input.participants_json);
        bindText(stmt, 8, input.permissions_json);
        bindText(stmt, 9, input.scope);
        _ = c.sqlite3_bind_int64(stmt, 10, now);
        _ = c.sqlite3_bind_int64(stmt, 11, now);
        bindNullableText(stmt, 12, input.checksum);
        bindNullableText(stmt, 13, input.language);
        bindText(stmt, 14, input.related_entities_json);
        bindText(stmt, 15, input.metadata_json);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.InsertFailed;
        try self.upsertSourceFts(id, input.title, input.content);
        self.insertAudit("source.created", "source", id);
        return .{
            .id = id,
            .source_type = input.source_type,
            .title = input.title,
            .raw_content_uri = input.raw_content_uri,
            .content = input.content,
            .author = input.author,
            .participants_json = input.participants_json,
            .permissions_json = input.permissions_json,
            .scope = input.scope,
            .created_at_ms = now,
            .imported_at_ms = now,
            .checksum = input.checksum,
            .language = input.language,
            .related_entities_json = input.related_entities_json,
            .metadata_json = input.metadata_json,
        };
    }

    fn upsertSourceFts(self: *Self, id: []const u8, title: []const u8, content: []const u8) !void {
        const del = try self.prepare("DELETE FROM sources_fts WHERE id = ?1");
        defer _ = c.sqlite3_finalize(del);
        bindText(del, 1, id);
        _ = c.sqlite3_step(del);
        const stmt = try self.prepare("INSERT INTO sources_fts (id,title,content) VALUES (?1,?2,?3)");
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, id);
        bindText(stmt, 2, title);
        bindText(stmt, 3, content);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.InsertFailed;
    }

    pub fn getSource(self: *Self, allocator: std.mem.Allocator, id: []const u8) !?domain.Source {
        const stmt = try self.prepare("SELECT id,type,title,raw_content_uri,content,author,participants_json,permissions_json,scope,created_at_ms,imported_at_ms,checksum,language,related_entities_json,metadata_json FROM sources WHERE id = ?1 LIMIT 1");
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, id);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        const row = try readSource(allocator, stmt);
        return row;
    }

    fn readSource(allocator: std.mem.Allocator, stmt: *c.sqlite3_stmt) !domain.Source {
        return .{
            .id = try columnText(allocator, stmt, 0),
            .source_type = try columnText(allocator, stmt, 1),
            .title = try columnText(allocator, stmt, 2),
            .raw_content_uri = try columnTextNullable(allocator, stmt, 3),
            .content = try columnText(allocator, stmt, 4),
            .author = try columnTextNullable(allocator, stmt, 5),
            .participants_json = try columnText(allocator, stmt, 6),
            .permissions_json = try columnText(allocator, stmt, 7),
            .scope = try columnText(allocator, stmt, 8),
            .created_at_ms = c.sqlite3_column_int64(stmt, 9),
            .imported_at_ms = c.sqlite3_column_int64(stmt, 10),
            .checksum = try columnTextNullable(allocator, stmt, 11),
            .language = try columnTextNullable(allocator, stmt, 12),
            .related_entities_json = try columnText(allocator, stmt, 13),
            .metadata_json = try columnText(allocator, stmt, 14),
        };
    }

    pub fn createArtifact(self: *Self, allocator: std.mem.Allocator, input: ArtifactInput) !domain.Artifact {
        const id = try ids.make(allocator, "art_");
        const now = ids.nowMs();
        const stmt = try self.prepare("INSERT INTO artifacts (id,type,title,body,status,owner,space_id,version,created_at_ms,updated_at_ms,last_verified_at_ms,source_ids_json,related_entities_json,permissions_json,summary,agent_summary) VALUES (?1,?2,?3,?4,?5,?6,?7,1,?8,?9,NULL,?10,?11,?12,?13,?14)");
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, id);
        bindText(stmt, 2, input.artifact_type);
        bindText(stmt, 3, input.title);
        bindText(stmt, 4, input.body);
        bindText(stmt, 5, input.status);
        bindNullableText(stmt, 6, input.owner);
        bindNullableText(stmt, 7, input.space_id);
        _ = c.sqlite3_bind_int64(stmt, 8, now);
        _ = c.sqlite3_bind_int64(stmt, 9, now);
        bindText(stmt, 10, input.source_ids_json);
        bindText(stmt, 11, input.related_entities_json);
        bindText(stmt, 12, input.permissions_json);
        bindNullableText(stmt, 13, input.summary);
        bindNullableText(stmt, 14, input.agent_summary);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.InsertFailed;
        try self.upsertArtifactFts(id, input.title, input.body);
        self.insertAudit("artifact.created", "artifact", id);
        return .{
            .id = id,
            .artifact_type = input.artifact_type,
            .title = input.title,
            .body = input.body,
            .status = input.status,
            .owner = input.owner,
            .space_id = input.space_id,
            .version = 1,
            .created_at_ms = now,
            .updated_at_ms = now,
            .last_verified_at_ms = null,
            .source_ids_json = input.source_ids_json,
            .related_entities_json = input.related_entities_json,
            .permissions_json = input.permissions_json,
            .summary = input.summary,
            .agent_summary = input.agent_summary,
        };
    }

    fn upsertArtifactFts(self: *Self, id: []const u8, title: []const u8, body: []const u8) !void {
        const del = try self.prepare("DELETE FROM artifacts_fts WHERE id = ?1");
        defer _ = c.sqlite3_finalize(del);
        bindText(del, 1, id);
        _ = c.sqlite3_step(del);
        const stmt = try self.prepare("INSERT INTO artifacts_fts (id,title,body) VALUES (?1,?2,?3)");
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, id);
        bindText(stmt, 2, title);
        bindText(stmt, 3, body);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.InsertFailed;
    }

    pub fn getArtifact(self: *Self, allocator: std.mem.Allocator, id: []const u8) !?domain.Artifact {
        const stmt = try self.prepare("SELECT id,type,title,body,status,owner,space_id,version,created_at_ms,updated_at_ms,last_verified_at_ms,source_ids_json,related_entities_json,permissions_json,summary,agent_summary FROM artifacts WHERE id = ?1 LIMIT 1");
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, id);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        const row = try readArtifact(allocator, stmt);
        return row;
    }

    fn readArtifact(allocator: std.mem.Allocator, stmt: *c.sqlite3_stmt) !domain.Artifact {
        return .{
            .id = try columnText(allocator, stmt, 0),
            .artifact_type = try columnText(allocator, stmt, 1),
            .title = try columnText(allocator, stmt, 2),
            .body = try columnText(allocator, stmt, 3),
            .status = try columnText(allocator, stmt, 4),
            .owner = try columnTextNullable(allocator, stmt, 5),
            .space_id = try columnTextNullable(allocator, stmt, 6),
            .version = c.sqlite3_column_int64(stmt, 7),
            .created_at_ms = c.sqlite3_column_int64(stmt, 8),
            .updated_at_ms = c.sqlite3_column_int64(stmt, 9),
            .last_verified_at_ms = if (c.sqlite3_column_type(stmt, 10) == c.SQLITE_NULL) null else c.sqlite3_column_int64(stmt, 10),
            .source_ids_json = try columnText(allocator, stmt, 11),
            .related_entities_json = try columnText(allocator, stmt, 12),
            .permissions_json = try columnText(allocator, stmt, 13),
            .summary = try columnTextNullable(allocator, stmt, 14),
            .agent_summary = try columnTextNullable(allocator, stmt, 15),
        };
    }

    pub fn resolveEntity(self: *Self, allocator: std.mem.Allocator, input: EntityInput) !domain.Entity {
        if (try self.findEntity(allocator, input.entity_type, input.name)) |entity| return entity;
        const id = try ids.make(allocator, "ent_");
        const now = ids.nowMs();
        const stmt = try self.prepare("INSERT INTO entities (id,type,name,aliases_json,description,canonical_artifact_id,metadata_json,created_at_ms,updated_at_ms) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9)");
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, id);
        bindText(stmt, 2, input.entity_type);
        bindText(stmt, 3, input.name);
        bindText(stmt, 4, input.aliases_json);
        bindNullableText(stmt, 5, input.description);
        bindNullableText(stmt, 6, input.canonical_artifact_id);
        bindText(stmt, 7, input.metadata_json);
        _ = c.sqlite3_bind_int64(stmt, 8, now);
        _ = c.sqlite3_bind_int64(stmt, 9, now);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.InsertFailed;
        self.insertAudit("entity.resolved", "entity", id);
        return .{ .id = id, .entity_type = input.entity_type, .name = input.name, .aliases_json = input.aliases_json, .description = input.description, .canonical_artifact_id = input.canonical_artifact_id, .metadata_json = input.metadata_json, .created_at_ms = now, .updated_at_ms = now };
    }

    fn findEntity(self: *Self, allocator: std.mem.Allocator, entity_type: []const u8, name: []const u8) !?domain.Entity {
        const stmt = try self.prepare("SELECT id,type,name,aliases_json,description,canonical_artifact_id,metadata_json,created_at_ms,updated_at_ms FROM entities WHERE type = ?1 AND lower(name) = lower(?2) LIMIT 1");
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, entity_type);
        bindText(stmt, 2, name);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        const row = try readEntity(allocator, stmt);
        return row;
    }

    fn readEntity(allocator: std.mem.Allocator, stmt: *c.sqlite3_stmt) !domain.Entity {
        return .{
            .id = try columnText(allocator, stmt, 0),
            .entity_type = try columnText(allocator, stmt, 1),
            .name = try columnText(allocator, stmt, 2),
            .aliases_json = try columnText(allocator, stmt, 3),
            .description = try columnTextNullable(allocator, stmt, 4),
            .canonical_artifact_id = try columnTextNullable(allocator, stmt, 5),
            .metadata_json = try columnText(allocator, stmt, 6),
            .created_at_ms = c.sqlite3_column_int64(stmt, 7),
            .updated_at_ms = c.sqlite3_column_int64(stmt, 8),
        };
    }

    pub fn createRelation(self: *Self, allocator: std.mem.Allocator, input: RelationInput) !domain.Relation {
        if (!try self.entityExists(input.from_entity_id) or !try self.entityExists(input.to_entity_id)) return error.EntityNotFound;
        const id = try ids.make(allocator, "rel_");
        const now = ids.nowMs();
        const stmt = try self.prepare("INSERT INTO relations (id,from_entity_id,relation_type,to_entity_id,source_ids_json,confidence,status,created_at_ms) VALUES (?1,?2,?3,?4,?5,?6,?7,?8)");
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, id);
        bindText(stmt, 2, input.from_entity_id);
        bindText(stmt, 3, input.relation_type);
        bindText(stmt, 4, input.to_entity_id);
        bindText(stmt, 5, input.source_ids_json);
        _ = c.sqlite3_bind_double(stmt, 6, input.confidence);
        bindText(stmt, 7, input.status);
        _ = c.sqlite3_bind_int64(stmt, 8, now);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.InsertFailed;
        self.insertAudit("relation.created", "relation", id);
        return .{ .id = id, .from_entity_id = input.from_entity_id, .relation_type = input.relation_type, .to_entity_id = input.to_entity_id, .source_ids_json = input.source_ids_json, .confidence = input.confidence, .status = input.status, .created_at_ms = now };
    }

    fn entityExists(self: *Self, id: []const u8) !bool {
        const stmt = try self.prepare("SELECT 1 FROM entities WHERE id = ?1 LIMIT 1");
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, id);
        return c.sqlite3_step(stmt) == c.SQLITE_ROW;
    }

    pub fn createMemoryAtom(self: *Self, allocator: std.mem.Allocator, input: MemoryAtomInput) !domain.MemoryAtom {
        const id = try ids.make(allocator, "mem_");
        const now = ids.nowMs();
        const status = input.status orelse domain.defaultMemoryStatus(input.created_by, input.scope);
        const stmt = try self.prepare("INSERT INTO memory_atoms (id,subject_entity_id,predicate,object,text,scope,confidence,status,source_ids_json,evidence_ranges_json,created_by,created_at_ms,valid_from_ms,valid_until_ms,last_verified_at_ms,owner,permissions_json,tags_json) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,NULL,?15,?16,?17)");
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, id);
        bindNullableText(stmt, 2, input.subject_entity_id);
        bindText(stmt, 3, input.predicate);
        bindText(stmt, 4, input.object);
        bindText(stmt, 5, input.text);
        bindText(stmt, 6, input.scope);
        _ = c.sqlite3_bind_double(stmt, 7, input.confidence);
        bindText(stmt, 8, status);
        bindText(stmt, 9, input.source_ids_json);
        bindText(stmt, 10, input.evidence_ranges_json);
        bindText(stmt, 11, input.created_by);
        _ = c.sqlite3_bind_int64(stmt, 12, now);
        if (input.valid_from_ms) |v| _ = c.sqlite3_bind_int64(stmt, 13, v) else _ = c.sqlite3_bind_null(stmt, 13);
        if (input.valid_until_ms) |v| _ = c.sqlite3_bind_int64(stmt, 14, v) else _ = c.sqlite3_bind_null(stmt, 14);
        bindNullableText(stmt, 15, input.owner);
        bindText(stmt, 16, input.permissions_json);
        bindText(stmt, 17, input.tags_json);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.InsertFailed;
        try self.upsertMemoryAtomFts(id, input.text, input.predicate, input.object);
        self.insertAudit("memory_atom.created", "memory_atom", id);
        return .{
            .id = id,
            .subject_entity_id = input.subject_entity_id,
            .predicate = input.predicate,
            .object = input.object,
            .text = input.text,
            .scope = input.scope,
            .confidence = input.confidence,
            .status = status,
            .source_ids_json = input.source_ids_json,
            .evidence_ranges_json = input.evidence_ranges_json,
            .created_by = input.created_by,
            .created_at_ms = now,
            .valid_from_ms = input.valid_from_ms,
            .valid_until_ms = input.valid_until_ms,
            .last_verified_at_ms = null,
            .owner = input.owner,
            .permissions_json = input.permissions_json,
            .tags_json = input.tags_json,
        };
    }

    fn upsertMemoryAtomFts(self: *Self, id: []const u8, text: []const u8, predicate: []const u8, object: []const u8) !void {
        const del = try self.prepare("DELETE FROM memory_atoms_fts WHERE id = ?1");
        defer _ = c.sqlite3_finalize(del);
        bindText(del, 1, id);
        _ = c.sqlite3_step(del);
        const stmt = try self.prepare("INSERT INTO memory_atoms_fts (id,text,predicate,object) VALUES (?1,?2,?3,?4)");
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, id);
        bindText(stmt, 2, text);
        bindText(stmt, 3, predicate);
        bindText(stmt, 4, object);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.InsertFailed;
    }

    pub fn getMemoryAtom(self: *Self, allocator: std.mem.Allocator, id: []const u8) !?domain.MemoryAtom {
        const stmt = try self.prepare("SELECT id,subject_entity_id,predicate,object,text,scope,confidence,status,source_ids_json,evidence_ranges_json,created_by,created_at_ms,valid_from_ms,valid_until_ms,last_verified_at_ms,owner,permissions_json,tags_json FROM memory_atoms WHERE id = ?1 LIMIT 1");
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, id);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        const row = try readMemoryAtom(allocator, stmt);
        return row;
    }

    fn readMemoryAtom(allocator: std.mem.Allocator, stmt: *c.sqlite3_stmt) !domain.MemoryAtom {
        return .{
            .id = try columnText(allocator, stmt, 0),
            .subject_entity_id = try columnTextNullable(allocator, stmt, 1),
            .predicate = try columnText(allocator, stmt, 2),
            .object = try columnText(allocator, stmt, 3),
            .text = try columnText(allocator, stmt, 4),
            .scope = try columnText(allocator, stmt, 5),
            .confidence = c.sqlite3_column_double(stmt, 6),
            .status = try columnText(allocator, stmt, 7),
            .source_ids_json = try columnText(allocator, stmt, 8),
            .evidence_ranges_json = try columnText(allocator, stmt, 9),
            .created_by = try columnText(allocator, stmt, 10),
            .created_at_ms = c.sqlite3_column_int64(stmt, 11),
            .valid_from_ms = if (c.sqlite3_column_type(stmt, 12) == c.SQLITE_NULL) null else c.sqlite3_column_int64(stmt, 12),
            .valid_until_ms = if (c.sqlite3_column_type(stmt, 13) == c.SQLITE_NULL) null else c.sqlite3_column_int64(stmt, 13),
            .last_verified_at_ms = if (c.sqlite3_column_type(stmt, 14) == c.SQLITE_NULL) null else c.sqlite3_column_int64(stmt, 14),
            .owner = try columnTextNullable(allocator, stmt, 15),
            .permissions_json = try columnText(allocator, stmt, 16),
            .tags_json = try columnText(allocator, stmt, 17),
        };
    }

    pub fn patchMemoryAtomStatus(self: *Self, id: []const u8, status: []const u8, verified: bool) !bool {
        const stmt = try self.prepare("UPDATE memory_atoms SET status = ?1, last_verified_at_ms = CASE WHEN ?2 THEN ?3 ELSE last_verified_at_ms END WHERE id = ?4");
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, status);
        _ = c.sqlite3_bind_int(stmt, 2, if (verified) 1 else 0);
        _ = c.sqlite3_bind_int64(stmt, 3, ids.nowMs());
        bindText(stmt, 4, id);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.UpdateFailed;
        const changed = c.sqlite3_changes(self.db) > 0;
        if (changed) self.insertAudit("memory_atom.status", "memory_atom", id);
        return changed;
    }

    pub fn search(self: *Self, allocator: std.mem.Allocator, input: SearchInput) ![]domain.SearchResult {
        const limit = @max(@as(usize, 1), @min(input.limit, 100));
        const plan = try retrieval_mod.buildPlan(allocator, input.query, input.use_vector, false);
        const fts_query = try buildFtsQuery(allocator, input.query);
        const use_fts = fts_query.len > 0;
        var keyword_results: std.ArrayListUnmanaged(domain.SearchResult) = .empty;
        errdefer keyword_results.deinit(allocator);

        try self.searchMemoryAtoms(allocator, input, fts_query, use_fts, &keyword_results);
        try self.searchSources(allocator, input, fts_query, use_fts, &keyword_results);
        try self.searchArtifacts(allocator, input, fts_query, use_fts, &keyword_results);
        try self.searchEntities(allocator, input, &keyword_results);
        try self.searchRelations(allocator, input, &keyword_results);
        try self.searchContextPacks(allocator, input, &keyword_results);
        try self.searchFeedEvents(allocator, input, &keyword_results);
        try self.searchCompatMemories(allocator, input, &keyword_results);
        if (input.include_sessions and (domain.hasActorScope(input.scopes_json, "admin") or domain.hasActorScope(input.scopes_json, "agent:nullclaw"))) {
            try self.searchSessionMessages(allocator, input, &keyword_results);
        }

        sortSearchResults(keyword_results.items);

        var vector_results: std.ArrayListUnmanaged(domain.SearchResult) = .empty;
        errdefer vector_results.deinit(allocator);
        if (plan.use_vector and input.query.len > 0) {
            try self.searchVectorCandidates(allocator, input, plan.expanded_query, &vector_results);
        }

        const final = try self.fuseSearchResults(allocator, keyword_results.items, vector_results.items, limit);
        return final;
    }

    fn searchMemoryAtoms(self: *Self, allocator: std.mem.Allocator, input: SearchInput, fts_query: []const u8, use_fts: bool, results: *std.ArrayListUnmanaged(domain.SearchResult)) !void {
        const stmt = if (use_fts)
            try self.prepare("SELECT ma.id,ma.text,ma.scope,ma.status,ma.confidence,ma.source_ids_json,ma.created_at_ms,ma.permissions_json,bm25(memory_atoms_fts) FROM memory_atoms_fts JOIN memory_atoms ma ON ma.id = memory_atoms_fts.id WHERE memory_atoms_fts MATCH ?1 ORDER BY bm25(memory_atoms_fts) LIMIT 1000")
        else
            try self.prepare("SELECT id,text,scope,status,confidence,source_ids_json,created_at_ms,permissions_json,0 FROM memory_atoms ORDER BY created_at_ms DESC LIMIT 1000");
        defer _ = c.sqlite3_finalize(stmt);
        if (use_fts) bindText(stmt, 1, fts_query);
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const id_text = try columnText(allocator, stmt, 0);
            const text = try columnText(allocator, stmt, 1);
            const scope = try columnText(allocator, stmt, 2);
            const status = try columnText(allocator, stmt, 3);
            const confidence = c.sqlite3_column_double(stmt, 4);
            const source_ids = try columnText(allocator, stmt, 5);
            const permissions = try columnText(allocator, stmt, 7);
            if (!input.include_deprecated and !domain.isDefaultVisibleStatus(status)) continue;
            if (!domain.recordVisible(scope, permissions, input.scopes_json)) continue;
            const relevance = if (use_fts) @max(0.0, 10.0 - c.sqlite3_column_double(stmt, 8)) else scoreText(input.query, text);
            if (!use_fts and relevance <= 0 and input.query.len > 0) continue;
            const citations = try self.sanitizeSourceIds(allocator, source_ids, input.scopes_json);
            try results.append(allocator, .{
                .id = id_text,
                .result_type = "memory_atom",
                .title = id_text,
                .text = text,
                .scope = scope,
                .status = status,
                .score = relevance + confidence,
                .source_ids_json = citations,
            });
        }
    }

    fn searchSources(self: *Self, allocator: std.mem.Allocator, input: SearchInput, fts_query: []const u8, use_fts: bool, results: *std.ArrayListUnmanaged(domain.SearchResult)) !void {
        const stmt = if (use_fts)
            try self.prepare("SELECT s.id,s.title,s.content,s.scope,s.permissions_json,bm25(sources_fts) FROM sources_fts JOIN sources s ON s.id = sources_fts.id WHERE sources_fts MATCH ?1 ORDER BY bm25(sources_fts) LIMIT 500")
        else
            try self.prepare("SELECT id,title,content,scope,permissions_json,0 FROM sources ORDER BY imported_at_ms DESC LIMIT 500");
        defer _ = c.sqlite3_finalize(stmt);
        if (use_fts) bindText(stmt, 1, fts_query);
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const id_text = try columnText(allocator, stmt, 0);
            const title = try columnText(allocator, stmt, 1);
            const content = try columnText(allocator, stmt, 2);
            const scope = try columnText(allocator, stmt, 3);
            const permissions = try columnText(allocator, stmt, 4);
            if (!domain.recordVisible(scope, permissions, input.scopes_json)) continue;
            const relevance = if (use_fts) @max(0.0, 9.0 - c.sqlite3_column_double(stmt, 5)) else scoreText(input.query, title) + scoreText(input.query, content);
            if (!use_fts and relevance <= 0 and input.query.len > 0) continue;
            const citations = try std.fmt.allocPrint(allocator, "[\"{s}\"]", .{id_text});
            try results.append(allocator, .{ .id = id_text, .result_type = "source", .title = title, .text = content, .scope = scope, .status = "active", .score = relevance, .source_ids_json = citations });
        }
    }

    fn searchArtifacts(self: *Self, allocator: std.mem.Allocator, input: SearchInput, fts_query: []const u8, use_fts: bool, results: *std.ArrayListUnmanaged(domain.SearchResult)) !void {
        const stmt = if (use_fts)
            try self.prepare("SELECT a.id,a.title,a.body,a.status,a.permissions_json,a.source_ids_json,bm25(artifacts_fts) FROM artifacts_fts JOIN artifacts a ON a.id = artifacts_fts.id WHERE artifacts_fts MATCH ?1 ORDER BY bm25(artifacts_fts) LIMIT 500")
        else
            try self.prepare("SELECT id,title,body,status,permissions_json,source_ids_json,0 FROM artifacts ORDER BY updated_at_ms DESC LIMIT 500");
        defer _ = c.sqlite3_finalize(stmt);
        if (use_fts) bindText(stmt, 1, fts_query);
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const id_text = try columnText(allocator, stmt, 0);
            const title = try columnText(allocator, stmt, 1);
            const body = try columnText(allocator, stmt, 2);
            const status = try columnText(allocator, stmt, 3);
            const permissions = try columnText(allocator, stmt, 4);
            const source_ids = try columnText(allocator, stmt, 5);
            if (!input.include_deprecated and !domain.isDefaultVisibleStatus(status)) continue;
            if (!domain.permissionsVisible(permissions, input.scopes_json)) continue;
            const relevance = if (use_fts) @max(0.0, 9.0 - c.sqlite3_column_double(stmt, 6)) else scoreText(input.query, title) + scoreText(input.query, body);
            if (!use_fts and relevance <= 0 and input.query.len > 0) continue;
            const citations = try self.sanitizeSourceIds(allocator, source_ids, input.scopes_json);
            try results.append(allocator, .{ .id = id_text, .result_type = "artifact", .title = title, .text = body, .scope = "artifact", .status = status, .score = relevance, .source_ids_json = citations });
        }
    }

    fn searchEntities(self: *Self, allocator: std.mem.Allocator, input: SearchInput, results: *std.ArrayListUnmanaged(domain.SearchResult)) !void {
        const stmt = try self.prepare("SELECT id,type,name,aliases_json,description FROM entities ORDER BY updated_at_ms DESC LIMIT 500");
        defer _ = c.sqlite3_finalize(stmt);
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const id_text = try columnText(allocator, stmt, 0);
            const entity_type = try columnText(allocator, stmt, 1);
            const name = try columnText(allocator, stmt, 2);
            const aliases = try columnText(allocator, stmt, 3);
            const description = try columnTextNullable(allocator, stmt, 4);
            const text = description orelse name;
            const relevance = scoreText(input.query, name) + scoreText(input.query, aliases) + scoreText(input.query, text);
            if (relevance <= 0 and input.query.len > 0) continue;
            const title = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ entity_type, name });
            try results.append(allocator, .{ .id = id_text, .result_type = "entity", .title = title, .text = text, .scope = "entity", .status = "active", .score = relevance + 0.25, .source_ids_json = "[]" });
        }
    }

    fn searchRelations(self: *Self, allocator: std.mem.Allocator, input: SearchInput, results: *std.ArrayListUnmanaged(domain.SearchResult)) !void {
        const stmt = try self.prepare(
            "SELECT r.id,r.relation_type,r.status,r.confidence,r.source_ids_json,fe.name,te.name " ++
                "FROM relations r " ++
                "LEFT JOIN entities fe ON fe.id = r.from_entity_id " ++
                "LEFT JOIN entities te ON te.id = r.to_entity_id " ++
                "ORDER BY r.created_at_ms DESC LIMIT 500",
        );
        defer _ = c.sqlite3_finalize(stmt);
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const id_text = try columnText(allocator, stmt, 0);
            const relation_type = try columnText(allocator, stmt, 1);
            const status = try columnText(allocator, stmt, 2);
            const confidence = c.sqlite3_column_double(stmt, 3);
            const source_ids = try columnText(allocator, stmt, 4);
            const from_name = try columnText(allocator, stmt, 5);
            const to_name = try columnText(allocator, stmt, 6);
            if (!input.include_deprecated and !domain.isDefaultVisibleStatus(status)) continue;
            const text = try std.fmt.allocPrint(allocator, "{s} {s} {s}", .{ from_name, relation_type, to_name });
            const relevance = scoreText(input.query, text) + scoreText(input.query, relation_type);
            if (relevance <= 0 and input.query.len > 0) continue;
            const citations = try self.sanitizeSourceIds(allocator, source_ids, input.scopes_json);
            try results.append(allocator, .{
                .id = id_text,
                .result_type = "relation",
                .title = relation_type,
                .text = text,
                .scope = "graph",
                .status = status,
                .score = relevance + confidence,
                .source_ids_json = citations,
            });
        }
    }

    fn searchContextPacks(self: *Self, allocator: std.mem.Allocator, input: SearchInput, results: *std.ArrayListUnmanaged(domain.SearchResult)) !void {
        const stmt = try self.prepare("SELECT id,purpose,target,query_text,included_sources_json,included_artifacts_json,included_memory_atoms_json,generated_summary,created_at_ms FROM context_packs ORDER BY created_at_ms DESC LIMIT 500");
        defer _ = c.sqlite3_finalize(stmt);
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const id_text = try columnText(allocator, stmt, 0);
            const purpose = try columnText(allocator, stmt, 1);
            const target = try columnText(allocator, stmt, 2);
            const query_text = try columnText(allocator, stmt, 3);
            const source_ids = try columnText(allocator, stmt, 4);
            const artifact_ids = try columnText(allocator, stmt, 5);
            const atom_ids = try columnText(allocator, stmt, 6);
            const summary = try columnText(allocator, stmt, 7);
            if (!try self.contextPackVisible(allocator, source_ids, artifact_ids, atom_ids, input.scopes_json)) continue;
            const relevance = scoreText(input.query, query_text) + scoreText(input.query, summary) + scoreText(input.query, purpose);
            if (relevance <= 0 and input.query.len > 0) continue;
            const title = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ purpose, target });
            const citations = try self.sanitizeSourceIds(allocator, source_ids, input.scopes_json);
            try results.append(allocator, .{
                .id = id_text,
                .result_type = "context_pack",
                .title = title,
                .text = summary,
                .scope = "context",
                .status = "active",
                .score = relevance + 0.4,
                .source_ids_json = citations,
            });
        }
    }

    fn searchFeedEvents(self: *Self, allocator: std.mem.Allocator, input: SearchInput, results: *std.ArrayListUnmanaged(domain.SearchResult)) !void {
        const stmt = try self.prepare("SELECT id,event_type,object_type,object_id,scope,payload_json,status FROM memory_feed_events ORDER BY id DESC LIMIT 500");
        defer _ = c.sqlite3_finalize(stmt);
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const id_num = c.sqlite3_column_int64(stmt, 0);
            const event_type = try columnText(allocator, stmt, 1);
            const object_type = try columnText(allocator, stmt, 2);
            const object_id = try columnText(allocator, stmt, 3);
            const scope = try columnText(allocator, stmt, 4);
            const payload = try columnText(allocator, stmt, 5);
            const status = try columnText(allocator, stmt, 6);
            if (!domain.scopeVisible(scope, input.scopes_json)) continue;
            if (!input.include_deprecated and std.mem.eql(u8, status, "rejected")) continue;
            const text = try std.fmt.allocPrint(allocator, "{s} {s} {s} {s}", .{ event_type, object_type, object_id, payload });
            const relevance = scoreText(input.query, text);
            if (relevance <= 0 and input.query.len > 0) continue;
            const id_text = try std.fmt.allocPrint(allocator, "feed_{d}", .{id_num});
            try results.append(allocator, .{
                .id = id_text,
                .result_type = "feed_event",
                .title = event_type,
                .text = text,
                .scope = scope,
                .status = status,
                .score = relevance + 0.2,
                .source_ids_json = "[]",
            });
        }
    }

    fn searchCompatMemories(self: *Self, allocator: std.mem.Allocator, input: SearchInput, results: *std.ArrayListUnmanaged(domain.SearchResult)) !void {
        const stmt = try self.prepare(
            "SELECT cm.key,cm.category,cm.session_id,ma.id,ma.text,ma.scope,ma.status,ma.confidence,ma.source_ids_json,ma.permissions_json " ++
                "FROM compat_memories cm JOIN memory_atoms ma ON ma.id = cm.memory_atom_id " ++
                "ORDER BY cm.timestamp_ms DESC LIMIT 500",
        );
        defer _ = c.sqlite3_finalize(stmt);
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const key = try columnText(allocator, stmt, 0);
            const category = try columnText(allocator, stmt, 1);
            const session_id = try columnTextNullable(allocator, stmt, 2);
            const atom_id = try columnText(allocator, stmt, 3);
            const text = try columnText(allocator, stmt, 4);
            const scope = try columnText(allocator, stmt, 5);
            const status = try columnText(allocator, stmt, 6);
            const confidence = c.sqlite3_column_double(stmt, 7);
            const source_ids = try columnText(allocator, stmt, 8);
            const permissions = try columnText(allocator, stmt, 9);
            if (!input.include_deprecated and !domain.isDefaultVisibleStatus(status)) continue;
            if (!domain.recordVisible(scope, permissions, input.scopes_json)) continue;
            const session_text = session_id orelse "global";
            const haystack = try std.fmt.allocPrint(allocator, "{s} {s} {s} {s}", .{ key, category, session_text, text });
            const relevance = scoreText(input.query, haystack);
            if (relevance <= 0 and input.query.len > 0) continue;
            const title = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ category, key });
            const id_text = try std.fmt.allocPrint(allocator, "compat:{s}:{s}", .{ session_text, key });
            const citations = try self.sanitizeSourceIds(allocator, source_ids, input.scopes_json);
            try results.append(allocator, .{
                .id = id_text,
                .result_type = "compat_memory",
                .title = title,
                .text = haystack,
                .scope = scope,
                .status = status,
                .score = relevance + confidence,
                .source_ids_json = citations,
            });
            _ = atom_id;
        }
    }

    fn searchSessionMessages(self: *Self, allocator: std.mem.Allocator, input: SearchInput, results: *std.ArrayListUnmanaged(domain.SearchResult)) !void {
        const stmt = try self.prepare("SELECT id,session_id,role,content,created_at_ms FROM session_messages ORDER BY id DESC LIMIT 500");
        defer _ = c.sqlite3_finalize(stmt);
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const id_num = c.sqlite3_column_int64(stmt, 0);
            const session_id = try columnText(allocator, stmt, 1);
            const role = try columnText(allocator, stmt, 2);
            const content = try columnText(allocator, stmt, 3);
            const relevance = scoreText(input.query, session_id) + scoreText(input.query, role) + scoreText(input.query, content);
            if (relevance <= 0 and input.query.len > 0) continue;
            const id_text = try std.fmt.allocPrint(allocator, "session_msg_{d}", .{id_num});
            const title = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ session_id, role });
            try results.append(allocator, .{
                .id = id_text,
                .result_type = "session_message",
                .title = title,
                .text = content,
                .scope = "agent:nullclaw",
                .status = "active",
                .score = relevance + 0.1,
                .source_ids_json = "[]",
            });
        }
    }

    fn searchVectorCandidates(self: *Self, allocator: std.mem.Allocator, input: SearchInput, expanded_query: []const u8, results: *std.ArrayListUnmanaged(domain.SearchResult)) !void {
        const embedding = try vector_mod.deterministicEmbedding(allocator, expanded_query, 64);
        const embedding_json = try vector_mod.embeddingToJson(allocator, embedding);
        const matches = try self.vectorSearch(allocator, .{ .embedding_json = embedding_json, .scopes_json = input.scopes_json, .limit = @max(@as(usize, 20), input.limit) });
        for (matches) |match| {
            const result = try self.searchResultForVectorMatch(allocator, match, input);
            if (result) |value| try results.append(allocator, value);
        }
    }

    fn searchResultForVectorMatch(self: *Self, allocator: std.mem.Allocator, match: vector_mod.VectorMatch, input: SearchInput) !?domain.SearchResult {
        if (std.mem.eql(u8, match.object_type, "memory_atom")) {
            const atom = (try self.getMemoryAtom(allocator, match.object_id)) orelse return null;
            if (!input.include_deprecated and !domain.isDefaultVisibleStatus(atom.status)) return null;
            if (!domain.recordVisible(atom.scope, atom.permissions_json, input.scopes_json)) return null;
            return .{
                .id = atom.id,
                .result_type = "memory_atom",
                .title = atom.id,
                .text = atom.text,
                .scope = atom.scope,
                .status = atom.status,
                .score = @as(f64, match.score) + atom.confidence,
                .source_ids_json = try self.sanitizeSourceIds(allocator, atom.source_ids_json, input.scopes_json),
            };
        }
        if (std.mem.eql(u8, match.object_type, "source")) {
            const source = (try self.getSource(allocator, match.object_id)) orelse return null;
            if (!domain.recordVisible(source.scope, source.permissions_json, input.scopes_json)) return null;
            return .{
                .id = source.id,
                .result_type = "source",
                .title = source.title,
                .text = source.content,
                .scope = source.scope,
                .status = "active",
                .score = match.score,
                .source_ids_json = try std.fmt.allocPrint(allocator, "[\"{s}\"]", .{source.id}),
            };
        }
        if (std.mem.eql(u8, match.object_type, "artifact")) {
            const artifact = (try self.getArtifact(allocator, match.object_id)) orelse return null;
            if (!domain.permissionsVisible(artifact.permissions_json, input.scopes_json)) return null;
            return .{
                .id = artifact.id,
                .result_type = "artifact",
                .title = artifact.title,
                .text = artifact.body,
                .scope = "artifact",
                .status = artifact.status,
                .score = match.score,
                .source_ids_json = try self.sanitizeSourceIds(allocator, artifact.source_ids_json, input.scopes_json),
            };
        }
        return .{
            .id = match.object_id,
            .result_type = match.object_type,
            .title = match.object_id,
            .text = match.text,
            .scope = match.scope,
            .status = "active",
            .score = match.score,
            .source_ids_json = "[]",
        };
    }

    fn contextPackVisible(self: *Self, allocator: std.mem.Allocator, sources_json: []const u8, artifacts_json: []const u8, atoms_json: []const u8, scopes_json: []const u8) !bool {
        return (try self.allSourcesVisible(allocator, sources_json, scopes_json)) and
            (try self.allArtifactsVisible(allocator, artifacts_json, scopes_json)) and
            (try self.allMemoryAtomsVisible(allocator, atoms_json, scopes_json));
    }

    fn allSourcesVisible(self: *Self, allocator: std.mem.Allocator, ids_json: []const u8, scopes_json: []const u8) !bool {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, ids_json, .{}) catch return false;
        defer parsed.deinit();
        if (parsed.value != .array) return false;
        for (parsed.value.array.items) |item| {
            const id_text = switch (item) {
                .string => |s| s,
                else => return false,
            };
            const source = (try self.getSource(allocator, id_text)) orelse return false;
            if (!domain.recordVisible(source.scope, source.permissions_json, scopes_json)) return false;
        }
        return true;
    }

    fn allArtifactsVisible(self: *Self, allocator: std.mem.Allocator, ids_json: []const u8, scopes_json: []const u8) !bool {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, ids_json, .{}) catch return false;
        defer parsed.deinit();
        if (parsed.value != .array) return false;
        for (parsed.value.array.items) |item| {
            const id_text = switch (item) {
                .string => |s| s,
                else => return false,
            };
            const artifact = (try self.getArtifact(allocator, id_text)) orelse return false;
            if (!domain.permissionsVisible(artifact.permissions_json, scopes_json)) return false;
        }
        return true;
    }

    fn allMemoryAtomsVisible(self: *Self, allocator: std.mem.Allocator, ids_json: []const u8, scopes_json: []const u8) !bool {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, ids_json, .{}) catch return false;
        defer parsed.deinit();
        if (parsed.value != .array) return false;
        for (parsed.value.array.items) |item| {
            const id_text = switch (item) {
                .string => |s| s,
                else => return false,
            };
            const atom = (try self.getMemoryAtom(allocator, id_text)) orelse return false;
            if (!domain.recordVisible(atom.scope, atom.permissions_json, scopes_json)) return false;
        }
        return true;
    }

    fn fuseSearchResults(self: *Self, allocator: std.mem.Allocator, keyword_results: []const domain.SearchResult, vector_results: []const domain.SearchResult, limit: usize) ![]domain.SearchResult {
        _ = self;
        if (vector_results.len == 0) {
            const out = try allocator.alloc(domain.SearchResult, @min(keyword_results.len, limit));
            @memcpy(out, keyword_results[0..out.len]);
            return out;
        }
        const keyword_ranked = try allocator.alloc(retrieval_mod.RankedItem, keyword_results.len);
        for (keyword_results, 0..) |result, i| {
            keyword_ranked[i] = .{ .id = result.id, .score = result.score, .confidence = 0.75 };
        }
        const vector_ranked = try allocator.alloc(retrieval_mod.RankedItem, vector_results.len);
        for (vector_results, 0..) |result, i| {
            vector_ranked[i] = .{ .id = result.id, .score = result.score, .confidence = 0.65 };
        }
        const lists = [_][]const retrieval_mod.RankedItem{ keyword_ranked, vector_ranked };
        const fused = try retrieval_mod.reciprocalRankFusion(allocator, &lists, 60, limit);
        var out: std.ArrayListUnmanaged(domain.SearchResult) = .empty;
        for (fused) |ranked| {
            if (findSearchResultById(keyword_results, ranked.id)) |result| {
                var copy = result;
                copy.score += ranked.score;
                try out.append(allocator, copy);
            } else if (findSearchResultById(vector_results, ranked.id)) |result| {
                var copy = result;
                copy.score += ranked.score;
                try out.append(allocator, copy);
            }
        }
        return out.toOwnedSlice(allocator);
    }

    fn findSearchResultById(results: []const domain.SearchResult, id_text: []const u8) ?domain.SearchResult {
        for (results) |result| {
            if (std.mem.eql(u8, result.id, id_text)) return result;
        }
        return null;
    }

    fn sanitizeSourceIds(self: *Self, allocator: std.mem.Allocator, source_ids_json: []const u8, scopes_json: []const u8) ![]const u8 {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, source_ids_json, .{}) catch return allocator.dupe(u8, "[]");
        defer parsed.deinit();
        const arr = switch (parsed.value) {
            .array => |a| a,
            else => return allocator.dupe(u8, "[]"),
        };
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);
        try out.append(allocator, '[');
        var first = true;
        for (arr.items) |item| {
            const source_id = switch (item) {
                .string => |s| s,
                else => continue,
            };
            const source = (try self.getSource(allocator, source_id)) orelse continue;
            if (!domain.recordVisible(source.scope, source.permissions_json, scopes_json)) continue;
            if (!first) try out.append(allocator, ',');
            first = false;
            try @import("json_util.zig").appendString(&out, allocator, source_id);
        }
        try out.append(allocator, ']');
        return out.toOwnedSlice(allocator);
    }

    fn sortSearchResults(items: []domain.SearchResult) void {
        var i: usize = 0;
        while (i < items.len) : (i += 1) {
            var best = i;
            var j = i + 1;
            while (j < items.len) : (j += 1) {
                if (items[j].score > items[best].score) best = j;
            }
            if (best != i) std.mem.swap(domain.SearchResult, &items[i], &items[best]);
        }
    }

    fn buildFtsQuery(allocator: std.mem.Allocator, query: []const u8) ![]const u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        var token_count: usize = 0;
        var it = std.mem.tokenizeAny(u8, query, " \t\r\n.,;:/\\-_*\"'()[]{}<>!?");
        while (it.next()) |raw| {
            var token: std.ArrayListUnmanaged(u8) = .empty;
            defer token.deinit(allocator);
            for (raw) |ch| {
                if (std.ascii.isAlphanumeric(ch)) try token.append(allocator, std.ascii.toLower(ch));
            }
            if (token.items.len == 0) continue;
            if (token_count > 0) try out.append(allocator, ' ');
            try out.appendSlice(allocator, token.items);
            try out.append(allocator, '*');
            token_count += 1;
        }
        return out.toOwnedSlice(allocator);
    }

    fn scoreText(query: []const u8, text: []const u8) f64 {
        if (query.len == 0) return 1.0;
        var score: f64 = 0.0;
        var it = std.mem.tokenizeAny(u8, query, " \t\r\n.,;:/\\-_*\"'");
        while (it.next()) |token| {
            if (token.len == 0) continue;
            if (std.ascii.indexOfIgnoreCase(text, token) != null) score += 1.0;
        }
        return score;
    }

    pub fn upsertVectorChunk(self: *Self, allocator: std.mem.Allocator, input: VectorChunkInput) !VectorChunk {
        _ = try vector_mod.embeddingFromJson(allocator, input.embedding_json);
        const id = try std.fmt.allocPrint(allocator, "vec_{s}_{d}", .{ input.object_id, input.chunk_ordinal });
        const now = ids.nowMs();
        const stmt = try self.prepare("INSERT INTO vector_chunks (id,object_type,object_id,chunk_ordinal,text,scope,permissions_json,embedding_json,model,dimensions,created_at_ms,updated_at_ms) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12) ON CONFLICT(id) DO UPDATE SET text=excluded.text, scope=excluded.scope, permissions_json=excluded.permissions_json, embedding_json=excluded.embedding_json, model=excluded.model, dimensions=excluded.dimensions, updated_at_ms=excluded.updated_at_ms");
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, id);
        bindText(stmt, 2, input.object_type);
        bindText(stmt, 3, input.object_id);
        _ = c.sqlite3_bind_int64(stmt, 4, input.chunk_ordinal);
        bindText(stmt, 5, input.text);
        bindText(stmt, 6, input.scope);
        bindText(stmt, 7, input.permissions_json);
        bindText(stmt, 8, input.embedding_json);
        bindNullableText(stmt, 9, input.model);
        _ = c.sqlite3_bind_int64(stmt, 10, input.dimensions);
        _ = c.sqlite3_bind_int64(stmt, 11, now);
        _ = c.sqlite3_bind_int64(stmt, 12, now);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.InsertFailed;
        _ = try self.enqueueVectorOutbox(.{ .action = "upsert", .object_type = input.object_type, .object_id = input.object_id, .payload_json = "{}" });
        self.insertAudit("vector_chunk.upserted", "vector_chunk", id);
        return .{
            .id = id,
            .object_type = input.object_type,
            .object_id = input.object_id,
            .chunk_ordinal = input.chunk_ordinal,
            .text = input.text,
            .scope = input.scope,
            .permissions_json = input.permissions_json,
            .embedding_json = input.embedding_json,
            .model = input.model,
            .dimensions = input.dimensions,
            .created_at_ms = now,
            .updated_at_ms = now,
        };
    }

    pub fn vectorSearch(self: *Self, allocator: std.mem.Allocator, input: VectorSearchInput) ![]vector_mod.VectorMatch {
        const query = try vector_mod.embeddingFromJson(allocator, input.embedding_json);
        defer allocator.free(query);
        const stmt = try self.prepare("SELECT id,object_id,object_type,text,scope,permissions_json,embedding_json FROM vector_chunks ORDER BY updated_at_ms DESC LIMIT 5000");
        defer _ = c.sqlite3_finalize(stmt);
        var records: std.ArrayListUnmanaged(vector_mod.VectorRecord) = .empty;
        defer records.deinit(allocator);
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const id_text = try columnText(allocator, stmt, 0);
            const object_id = try columnText(allocator, stmt, 1);
            const object_type = try columnText(allocator, stmt, 2);
            const text = try columnText(allocator, stmt, 3);
            const scope = try columnText(allocator, stmt, 4);
            const permissions = try columnText(allocator, stmt, 5);
            const embedding_json = try columnText(allocator, stmt, 6);
            if (!domain.recordVisible(scope, permissions, input.scopes_json)) continue;
            const embedding = vector_mod.embeddingFromJson(allocator, embedding_json) catch continue;
            try records.append(allocator, .{
                .id = id_text,
                .object_id = object_id,
                .object_type = object_type,
                .text = text,
                .scope = scope,
                .embedding = embedding,
            });
        }
        return vector_mod.annSearch(allocator, query, records.items, 512, @max(@as(usize, 1), @min(input.limit, 100)));
    }

    pub fn enqueueVectorOutbox(self: *Self, input: VectorOutboxInput) !i64 {
        const now = ids.nowMs();
        const stmt = try self.prepare("INSERT INTO vector_outbox (action,object_type,object_id,status,attempts,payload_json,created_at_ms,updated_at_ms) VALUES (?1,?2,?3,'pending',0,?4,?5,?6)");
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, input.action);
        bindText(stmt, 2, input.object_type);
        bindText(stmt, 3, input.object_id);
        bindText(stmt, 4, input.payload_json);
        _ = c.sqlite3_bind_int64(stmt, 5, now);
        _ = c.sqlite3_bind_int64(stmt, 6, now);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.InsertFailed;
        return c.sqlite3_last_insert_rowid(self.db);
    }

    pub fn countVectorOutbox(self: *Self, status: ?[]const u8) !usize {
        if (status) |s| {
            const stmt = try self.prepare("SELECT COUNT(*) FROM vector_outbox WHERE status = ?1");
            defer _ = c.sqlite3_finalize(stmt);
            bindText(stmt, 1, s);
            if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return 0;
            return @intCast(c.sqlite3_column_int64(stmt, 0));
        }
        return @intCast(try self.countSql("SELECT COUNT(*) FROM vector_outbox"));
    }

    pub fn runVectorOutbox(self: *Self, limit: usize) !VectorOutboxRunResult {
        const capped = @max(@as(usize, 1), @min(limit, 1000));
        const stmt = try self.prepare("UPDATE vector_outbox SET status = 'delivered_local', attempts = attempts + 1, updated_at_ms = ?1 WHERE id IN (SELECT id FROM vector_outbox WHERE status = 'pending' ORDER BY id LIMIT ?2)");
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int64(stmt, 1, ids.nowMs());
        _ = c.sqlite3_bind_int64(stmt, 2, @intCast(capped));
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.UpdateFailed;
        const changed: usize = @intCast(c.sqlite3_changes(self.db));
        if (changed > 0) self.insertAudit("vector_outbox.delivered_local", "vector_outbox", "batch");
        return .{ .processed = changed, .failed = 0 };
    }

    pub fn appendFeedEvent(self: *Self, input: FeedEventInput) !i64 {
        if (input.dedupe_key) |key| {
            if (try self.feedEventIdByDedupeKey(key)) |existing_id| return existing_id;
        }
        const now = ids.nowMs();
        const applied = if (std.mem.eql(u8, input.status, "applied")) now else null;
        const stmt = try self.prepare("INSERT INTO memory_feed_events (event_type,object_type,object_id,scope,dedupe_key,payload_json,status,created_at_ms,applied_at_ms) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9)");
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, input.event_type);
        bindText(stmt, 2, input.object_type);
        bindText(stmt, 3, input.object_id);
        bindText(stmt, 4, input.scope);
        bindNullableText(stmt, 5, input.dedupe_key);
        bindText(stmt, 6, input.payload_json);
        bindText(stmt, 7, input.status);
        _ = c.sqlite3_bind_int64(stmt, 8, now);
        if (applied) |v| _ = c.sqlite3_bind_int64(stmt, 9, v) else _ = c.sqlite3_bind_null(stmt, 9);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.InsertFailed;
        const id = c.sqlite3_last_insert_rowid(self.db);
        self.insertAudit("memory_feed.appended", "memory_feed_event", input.object_id);
        return id;
    }

    fn feedEventIdByDedupeKey(self: *Self, dedupe_key: []const u8) !?i64 {
        const stmt = try self.prepare("SELECT id FROM memory_feed_events WHERE dedupe_key = ?1 LIMIT 1");
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, dedupe_key);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        return c.sqlite3_column_int64(stmt, 0);
    }

    pub fn getFeedEventByDedupeKey(self: *Self, allocator: std.mem.Allocator, dedupe_key: []const u8) !?FeedEvent {
        const stmt = try self.prepare("SELECT id,event_type,object_type,object_id,scope,dedupe_key,payload_json,status,created_at_ms,applied_at_ms FROM memory_feed_events WHERE dedupe_key = ?1 LIMIT 1");
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, dedupe_key);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        return try readFeedEvent(allocator, stmt);
    }

    pub fn listFeedEvents(self: *Self, allocator: std.mem.Allocator, input: FeedListInput) ![]FeedEvent {
        const stmt = try self.prepare("SELECT id,event_type,object_type,object_id,scope,dedupe_key,payload_json,status,created_at_ms,applied_at_ms FROM memory_feed_events WHERE id > ?1 ORDER BY id ASC LIMIT ?2");
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int64(stmt, 1, input.since_id);
        _ = c.sqlite3_bind_int64(stmt, 2, @intCast(@max(@as(usize, 1), @min(input.limit, 500))));
        var out: std.ArrayListUnmanaged(FeedEvent) = .empty;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const scope = try columnText(allocator, stmt, 4);
            if (!domain.scopeVisible(scope, input.scopes_json)) continue;
            try out.append(allocator, try readFeedEventWithScope(allocator, stmt, scope));
        }
        return out.toOwnedSlice(allocator);
    }

    fn readFeedEvent(allocator: std.mem.Allocator, stmt: *c.sqlite3_stmt) !FeedEvent {
        const scope = try columnText(allocator, stmt, 4);
        return readFeedEventWithScope(allocator, stmt, scope);
    }

    fn readFeedEventWithScope(allocator: std.mem.Allocator, stmt: *c.sqlite3_stmt, scope: []const u8) !FeedEvent {
        return .{
            .id = c.sqlite3_column_int64(stmt, 0),
            .event_type = try columnText(allocator, stmt, 1),
            .object_type = try columnText(allocator, stmt, 2),
            .object_id = try columnText(allocator, stmt, 3),
            .scope = scope,
            .dedupe_key = try columnTextNullable(allocator, stmt, 5),
            .payload_json = try columnText(allocator, stmt, 6),
            .status = try columnText(allocator, stmt, 7),
            .created_at_ms = c.sqlite3_column_int64(stmt, 8),
            .applied_at_ms = if (c.sqlite3_column_type(stmt, 9) == c.SQLITE_NULL) null else c.sqlite3_column_int64(stmt, 9),
        };
    }

    pub fn createLifecycleSnapshot(self: *Self, allocator: std.mem.Allocator, snapshot_type: []const u8, summary_json: []const u8) !LifecycleSnapshot {
        const id = try ids.make(allocator, "snap_");
        const now = ids.nowMs();
        const stmt = try self.prepare("INSERT INTO lifecycle_snapshots (id,snapshot_type,summary_json,created_at_ms) VALUES (?1,?2,?3,?4)");
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, id);
        bindText(stmt, 2, snapshot_type);
        bindText(stmt, 3, summary_json);
        _ = c.sqlite3_bind_int64(stmt, 4, now);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.InsertFailed;
        self.insertAudit("lifecycle.snapshot", "lifecycle_snapshot", id);
        return .{ .id = id, .snapshot_type = snapshot_type, .summary_json = summary_json, .created_at_ms = now };
    }

    pub fn lifecycleDiagnostics(self: *Self) !LifecycleDiagnostics {
        const total = try self.countSql("SELECT COUNT(*) FROM memory_atoms");
        const stale = try self.countSql("SELECT COUNT(*) FROM memory_atoms WHERE status = 'stale'");
        const pending = try self.countVectorOutbox("pending");
        const response_cache = try self.countSql("SELECT COUNT(*) FROM response_cache");
        const semantic_cache = try self.countSql("SELECT COUNT(*) FROM semantic_cache");
        return .{
            .total_memory_atoms = @intCast(total),
            .stale_memory_atoms = @intCast(stale),
            .vector_outbox_pending = pending,
            .cache_entries = @intCast(response_cache + semantic_cache),
        };
    }

    pub fn putResponseCache(self: *Self, input: ResponseCacheInput) !void {
        const now = input.now_ms orelse ids.nowMs();
        const expires_at = if (input.ttl_ms > 0) now + input.ttl_ms else 0;
        const stmt = try self.prepare("INSERT INTO response_cache (cache_key,response_json,created_at_ms,expires_at_ms) VALUES (?1,?2,?3,?4) ON CONFLICT(cache_key) DO UPDATE SET response_json=excluded.response_json, created_at_ms=excluded.created_at_ms, expires_at_ms=excluded.expires_at_ms");
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, input.cache_key);
        bindText(stmt, 2, input.response_json);
        _ = c.sqlite3_bind_int64(stmt, 3, now);
        _ = c.sqlite3_bind_int64(stmt, 4, expires_at);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.UpdateFailed;
        self.insertAudit("cache.response.put", "response_cache", input.cache_key);
    }

    pub fn getResponseCache(self: *Self, allocator: std.mem.Allocator, cache_key: []const u8, now_ms: i64) !?ResponseCacheEntry {
        const stmt = try self.prepare("SELECT cache_key,response_json,created_at_ms,expires_at_ms FROM response_cache WHERE cache_key = ?1 LIMIT 1");
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, cache_key);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        const expires = c.sqlite3_column_int64(stmt, 3);
        if (expires > 0 and expires <= now_ms) {
            try self.deleteResponseCache(cache_key);
            return null;
        }
        return .{
            .cache_key = try columnText(allocator, stmt, 0),
            .response_json = try columnText(allocator, stmt, 1),
            .created_at_ms = c.sqlite3_column_int64(stmt, 2),
            .expires_at_ms = expires,
        };
    }

    fn deleteResponseCache(self: *Self, cache_key: []const u8) !void {
        const stmt = try self.prepare("DELETE FROM response_cache WHERE cache_key = ?1");
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, cache_key);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DeleteFailed;
    }

    pub fn putSemanticCache(self: *Self, input: SemanticCacheInput) !void {
        const parsed_embedding = try vector_mod.embeddingFromJson(self.allocator, input.embedding_json);
        defer self.allocator.free(parsed_embedding);
        const now = input.now_ms orelse ids.nowMs();
        const expires_at = if (input.ttl_ms > 0) now + input.ttl_ms else 0;
        const stmt = try self.prepare("INSERT INTO semantic_cache (cache_key,query,response_json,embedding_json,created_at_ms,expires_at_ms) VALUES (?1,?2,?3,?4,?5,?6) ON CONFLICT(cache_key) DO UPDATE SET query=excluded.query, response_json=excluded.response_json, embedding_json=excluded.embedding_json, created_at_ms=excluded.created_at_ms, expires_at_ms=excluded.expires_at_ms");
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, input.cache_key);
        bindText(stmt, 2, input.query);
        bindText(stmt, 3, input.response_json);
        bindText(stmt, 4, input.embedding_json);
        _ = c.sqlite3_bind_int64(stmt, 5, now);
        _ = c.sqlite3_bind_int64(stmt, 6, expires_at);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.UpdateFailed;
        self.insertAudit("cache.semantic.put", "semantic_cache", input.cache_key);
    }

    pub fn searchSemanticCache(self: *Self, allocator: std.mem.Allocator, input: SemanticCacheSearchInput) !?SemanticCacheMatch {
        const query = try vector_mod.embeddingFromJson(allocator, input.embedding_json);
        defer allocator.free(query);
        const now = input.now_ms orelse ids.nowMs();
        const stmt = try self.prepare("SELECT cache_key,query,response_json,embedding_json,created_at_ms,expires_at_ms FROM semantic_cache");
        defer _ = c.sqlite3_finalize(stmt);
        var best: ?SemanticCacheMatch = null;
        var best_score = input.min_score;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const expires = c.sqlite3_column_int64(stmt, 5);
            if (expires > 0 and expires <= now) continue;
            const embedding_json = try columnText(allocator, stmt, 3);
            defer allocator.free(embedding_json);
            const embedding = vector_mod.embeddingFromJson(allocator, embedding_json) catch continue;
            defer allocator.free(embedding);
            const score = vector_mod.cosine(query, embedding);
            if (score < best_score) continue;
            best_score = score;
            best = .{
                .cache_key = try columnText(allocator, stmt, 0),
                .query = try columnText(allocator, stmt, 1),
                .response_json = try columnText(allocator, stmt, 2),
                .score = score,
                .created_at_ms = c.sqlite3_column_int64(stmt, 4),
                .expires_at_ms = expires,
            };
        }
        return best;
    }

    pub fn runHygiene(self: *Self, input: HygieneRunInput) !HygieneRunResult {
        const now = input.now_ms orelse ids.nowMs();
        var result = HygieneRunResult{};
        const cache_stmt = try self.prepare("DELETE FROM response_cache WHERE expires_at_ms > 0 AND expires_at_ms <= ?1");
        defer _ = c.sqlite3_finalize(cache_stmt);
        _ = c.sqlite3_bind_int64(cache_stmt, 1, now);
        if (c.sqlite3_step(cache_stmt) != c.SQLITE_DONE) return error.DeleteFailed;
        result.expired_cache_entries += @intCast(c.sqlite3_changes(self.db));

        const semantic_stmt = try self.prepare("DELETE FROM semantic_cache WHERE expires_at_ms > 0 AND expires_at_ms <= ?1");
        defer _ = c.sqlite3_finalize(semantic_stmt);
        _ = c.sqlite3_bind_int64(semantic_stmt, 1, now);
        if (c.sqlite3_step(semantic_stmt) != c.SQLITE_DONE) return error.DeleteFailed;
        result.expired_cache_entries += @intCast(c.sqlite3_changes(self.db));

        const stmt = try self.prepare("SELECT id,status,last_verified_at_ms,created_at_ms FROM memory_atoms ORDER BY created_at_ms ASC LIMIT 5000");
        defer _ = c.sqlite3_finalize(stmt);
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            result.checked += 1;
            const id_text = try columnText(self.allocator, stmt, 0);
            defer self.allocator.free(id_text);
            const status = try columnText(self.allocator, stmt, 1);
            defer self.allocator.free(status);
            const last_verified = if (c.sqlite3_column_type(stmt, 2) == c.SQLITE_NULL) null else c.sqlite3_column_int64(stmt, 2);
            const created = c.sqlite3_column_int64(stmt, 3);
            const base_seen = last_verified orelse created;
            const decision = lifecycle_mod.hygieneDecision(status, base_seen, now, input.stale_after_ms, input.archive_after_ms, input.purge_after_ms);
            switch (decision) {
                .keep => {},
                .mark_stale => {
                    if (!std.mem.eql(u8, status, "stale")) {
                        if (try self.patchMemoryAtomStatus(id_text, "stale", false)) result.marked_stale += 1;
                    }
                },
                .archive => {
                    if (!std.mem.eql(u8, status, "deprecated")) {
                        if (try self.patchMemoryAtomStatus(id_text, "deprecated", false)) result.archived += 1;
                    }
                },
                .purge => {
                    if (input.hard_delete) {
                        if (try self.hardDeleteMemoryAtom(id_text)) result.purged += 1;
                    } else if (!std.mem.eql(u8, status, "deprecated")) {
                        if (try self.patchMemoryAtomStatus(id_text, "deprecated", false)) result.archived += 1;
                    }
                },
            }
        }
        self.insertAudit("lifecycle.hygiene", "memory_atom", "bulk");
        return result;
    }

    fn hardDeleteMemoryAtom(self: *Self, id_text: []const u8) !bool {
        const fts = try self.prepare("DELETE FROM memory_atoms_fts WHERE id = ?1");
        defer _ = c.sqlite3_finalize(fts);
        bindText(fts, 1, id_text);
        if (c.sqlite3_step(fts) != c.SQLITE_DONE) return error.DeleteFailed;

        const compat_del = try self.prepare("DELETE FROM compat_memories WHERE memory_atom_id = ?1");
        defer _ = c.sqlite3_finalize(compat_del);
        bindText(compat_del, 1, id_text);
        if (c.sqlite3_step(compat_del) != c.SQLITE_DONE) return error.DeleteFailed;

        const stmt = try self.prepare("DELETE FROM memory_atoms WHERE id = ?1");
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, id_text);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DeleteFailed;
        const changed = c.sqlite3_changes(self.db) > 0;
        if (changed) self.insertAudit("memory_atom.purged", "memory_atom", id_text);
        return changed;
    }

    pub fn createContextPack(self: *Self, allocator: std.mem.Allocator, input: ContextPackInput) !ContextPackResult {
        const search_results = try self.search(allocator, .{ .query = input.query, .limit = 8, .scopes_json = input.scopes_json });
        const id = try ids.make(allocator, "ctx_");
        const now = ids.nowMs();
        var sources_json: std.ArrayListUnmanaged(u8) = .empty;
        var artifacts_json: std.ArrayListUnmanaged(u8) = .empty;
        var atoms_json: std.ArrayListUnmanaged(u8) = .empty;
        try sources_json.append(allocator, '[');
        try artifacts_json.append(allocator, '[');
        try atoms_json.append(allocator, '[');
        var source_count: usize = 0;
        var artifact_count: usize = 0;
        var atom_count: usize = 0;
        for (search_results) |result| {
            if (std.mem.eql(u8, result.result_type, "source")) {
                try appendUniqueJsonString(allocator, &sources_json, &source_count, result.id);
            } else {
                try appendSourceCitations(allocator, &sources_json, &source_count, result.source_ids_json);
            }
            if (std.mem.eql(u8, result.result_type, "artifact")) {
                try appendUniqueJsonString(allocator, &artifacts_json, &artifact_count, result.id);
            } else if (std.mem.eql(u8, result.result_type, "memory_atom")) {
                try appendUniqueJsonString(allocator, &atoms_json, &atom_count, result.id);
            }
        }
        try sources_json.append(allocator, ']');
        try artifacts_json.append(allocator, ']');
        try atoms_json.append(allocator, ']');
        const sources = try sources_json.toOwnedSlice(allocator);
        const artifacts = try artifacts_json.toOwnedSlice(allocator);
        const atoms = try atoms_json.toOwnedSlice(allocator);
        const summary = try buildContextSummary(allocator, input.query, search_results);
        const stmt = try self.prepare("INSERT INTO context_packs (id,purpose,target,query_text,included_sources_json,included_artifacts_json,included_memory_atoms_json,generated_summary,token_budget,created_at_ms) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)");
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, id);
        bindText(stmt, 2, input.purpose);
        bindText(stmt, 3, input.target);
        bindText(stmt, 4, input.query);
        bindText(stmt, 5, sources);
        bindText(stmt, 6, artifacts);
        bindText(stmt, 7, atoms);
        bindText(stmt, 8, summary);
        _ = c.sqlite3_bind_int64(stmt, 9, input.token_budget);
        _ = c.sqlite3_bind_int64(stmt, 10, now);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.InsertFailed;
        self.insertAudit("context_pack.created", "context_pack", id);
        return .{ .id = id, .purpose = input.purpose, .target = input.target, .query = input.query, .generated_summary = summary, .included_sources_json = sources, .included_artifacts_json = artifacts, .included_memory_atoms_json = atoms, .token_budget = input.token_budget, .created_at_ms = now };
    }

    fn appendUniqueJsonString(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), count: *usize, value: []const u8) !void {
        const needle = try std.fmt.allocPrint(allocator, "\"{s}\"", .{value});
        defer allocator.free(needle);
        if (std.mem.indexOf(u8, out.items, needle) != null) return;
        if (count.* > 0) try out.append(allocator, ',');
        try @import("json_util.zig").appendString(out, allocator, value);
        count.* += 1;
    }

    fn appendSourceCitations(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), count: *usize, source_ids_json: []const u8) !void {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, source_ids_json, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value != .array) return;
        for (parsed.value.array.items) |item| {
            const source_id = switch (item) {
                .string => |s| s,
                else => continue,
            };
            try appendUniqueJsonString(allocator, out, count, source_id);
        }
    }

    fn buildContextSummary(allocator: std.mem.Allocator, query: []const u8, results: []const domain.SearchResult) ![]u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        try out.appendSlice(allocator, "Context Pack\n\nTask:\n");
        try out.appendSlice(allocator, query);
        try appendContextSection(allocator, &out, "Verified decisions", results, "memory_atom", "decision");
        try appendContextSection(allocator, &out, "Constraints", results, "memory_atom", "constraint");
        try appendContextSection(allocator, &out, "Memory atoms", results, "memory_atom", "");
        try appendContextSection(allocator, &out, "Artifacts", results, "artifact", "");
        try appendContextSection(allocator, &out, "Sources", results, "source", "");
        try appendContextSection(allocator, &out, "Graph relations", results, "relation", "");
        try appendContextSection(allocator, &out, "Open questions", results, "memory_atom", "question");
        try out.appendSlice(allocator, "\nCitations:\n");
        var citation_count: usize = 0;
        for (results) |result| {
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, result.source_ids_json, .{}) catch continue;
            defer parsed.deinit();
            if (parsed.value != .array) continue;
            for (parsed.value.array.items) |item| {
                const source_id = switch (item) {
                    .string => |s| s,
                    else => continue,
                };
                try out.appendSlice(allocator, "- ");
                try out.appendSlice(allocator, source_id);
                try out.append(allocator, '\n');
                citation_count += 1;
            }
        }
        if (citation_count == 0) try out.appendSlice(allocator, "- No source citations available.\n");
        return out.toOwnedSlice(allocator);
    }

    fn appendContextSection(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), title: []const u8, results: []const domain.SearchResult, result_type: []const u8, contains: []const u8) !void {
        try out.appendSlice(allocator, "\n");
        try out.appendSlice(allocator, title);
        try out.appendSlice(allocator, ":\n");
        var count: usize = 0;
        for (results) |result| {
            if (!std.mem.eql(u8, result.result_type, result_type)) continue;
            if (contains.len > 0 and std.ascii.indexOfIgnoreCase(result.title, contains) == null and std.ascii.indexOfIgnoreCase(result.text, contains) == null and std.ascii.indexOfIgnoreCase(result.status, contains) == null) continue;
            if (std.mem.eql(u8, title, "Verified decisions") and !std.mem.eql(u8, result.status, "verified") and !std.mem.eql(u8, result.status, "accepted")) continue;
            try out.appendSlice(allocator, "- ");
            try out.appendSlice(allocator, result.text);
            try out.append(allocator, '\n');
            count += 1;
        }
        if (count == 0) try out.appendSlice(allocator, "- None found.\n");
    }

    pub fn compatStore(self: *Self, allocator: std.mem.Allocator, input: CompatStoreInput) !void {
        try self.exec("BEGIN IMMEDIATE");
        errdefer self.exec("ROLLBACK") catch {};
        const atom = try self.createMemoryAtom(allocator, .{
            .predicate = "compat.memory",
            .object = input.key,
            .text = input.content,
            .scope = "agent:nullclaw",
            .confidence = 0.75,
            .status = "verified",
            .created_by = "agent",
            .tags_json = "[\"nullclaw\"]",
        });
        try self.compatDeleteExact(input.key, input.session_id);
        const stmt = try self.prepare("INSERT INTO compat_memories (key, session_id, memory_atom_id, category, timestamp_ms) VALUES (?1,?2,?3,?4,?5)");
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, input.key);
        bindNullableText(stmt, 2, input.session_id);
        bindText(stmt, 3, atom.id);
        bindText(stmt, 4, input.category);
        _ = c.sqlite3_bind_int64(stmt, 5, atom.created_at_ms);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.InsertFailed;
        try self.exec("COMMIT");
    }

    fn compatDeleteExact(self: *Self, key: []const u8, session_id: ?[]const u8) !void {
        const stmt = try self.prepare("SELECT memory_atom_id FROM compat_memories WHERE key = ?1 AND ((?2 IS NULL AND session_id IS NULL) OR (?2 IS NOT NULL AND session_id = ?2)) LIMIT 1");
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, key);
        bindNullableText(stmt, 2, session_id);
        var atom_id: ?[]u8 = null;
        if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            atom_id = try columnText(self.allocator, stmt, 0);
        }
        if (atom_id) |id_text| {
            defer self.allocator.free(id_text);
            _ = try self.patchMemoryAtomStatus(id_text, "deprecated", false);
        }

        const del = try self.prepare("DELETE FROM compat_memories WHERE key = ?1 AND ((?2 IS NULL AND session_id IS NULL) OR (?2 IS NOT NULL AND session_id = ?2))");
        defer _ = c.sqlite3_finalize(del);
        bindText(del, 1, key);
        bindNullableText(del, 2, session_id);
        if (c.sqlite3_step(del) != c.SQLITE_DONE) return error.DeleteFailed;
    }

    pub fn compatGet(self: *Self, allocator: std.mem.Allocator, key: []const u8, session_id: ?[]const u8) !?domain.CompatMemory {
        const stmt = try self.prepare(compatSelectSql("AND cm.key = ?1", "ORDER BY cm.timestamp_ms DESC LIMIT 1"));
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, key);
        bindNullableText(stmt, 2, session_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        const row = try readCompatMemory(allocator, stmt);
        return row;
    }

    pub fn compatList(self: *Self, allocator: std.mem.Allocator, category: ?[]const u8, session_id: ?[]const u8) ![]domain.CompatMemory {
        const sql = if (category != null)
            compatSelectSql("AND cm.category = ?1", "ORDER BY cm.timestamp_ms DESC LIMIT 100")
        else
            compatSelectSql("", "ORDER BY cm.timestamp_ms DESC LIMIT 100");
        const stmt = try self.prepare(sql);
        defer _ = c.sqlite3_finalize(stmt);
        if (category) |cat| bindText(stmt, 1, cat);
        bindNullableText(stmt, 2, session_id);
        var list: std.ArrayListUnmanaged(domain.CompatMemory) = .empty;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            try list.append(allocator, try readCompatMemory(allocator, stmt));
        }
        return list.toOwnedSlice(allocator);
    }

    pub fn compatSearch(self: *Self, allocator: std.mem.Allocator, query: []const u8, limit: usize, session_id: ?[]const u8) ![]domain.CompatMemory {
        const all = try self.compatList(allocator, null, session_id);
        var out: std.ArrayListUnmanaged(domain.CompatMemory) = .empty;
        for (all) |entry| {
            if (scoreText(query, entry.key) <= 0 and scoreText(query, entry.content) <= 0) continue;
            var copy = entry;
            copy.score = scoreText(query, entry.content) + 0.5;
            try out.append(allocator, copy);
            if (out.items.len >= @max(@as(usize, 1), limit)) break;
        }
        return out.toOwnedSlice(allocator);
    }

    pub fn compatDelete(self: *Self, key: []const u8, session_id: ?[]const u8) !bool {
        const stmt = try self.prepare("SELECT memory_atom_id FROM compat_memories WHERE key = ?1 AND ((?2 IS NULL AND session_id IS NULL) OR (?2 IS NOT NULL AND session_id = ?2))");
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, key);
        bindNullableText(stmt, 2, session_id);
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const id_text = try columnText(self.allocator, stmt, 0);
            defer self.allocator.free(id_text);
            _ = try self.patchMemoryAtomStatus(id_text, "deprecated", false);
        }
        const del = try self.prepare("DELETE FROM compat_memories WHERE key = ?1 AND ((?2 IS NULL AND session_id IS NULL) OR (?2 IS NOT NULL AND session_id = ?2))");
        defer _ = c.sqlite3_finalize(del);
        bindText(del, 1, key);
        bindNullableText(del, 2, session_id);
        if (c.sqlite3_step(del) != c.SQLITE_DONE) return error.DeleteFailed;
        return c.sqlite3_changes(self.db) > 0;
    }

    pub fn compatCount(self: *Self) !usize {
        return @intCast(try self.countSql("SELECT COUNT(*) FROM compat_memories"));
    }

    fn compatSelectSql(comptime extra_where: []const u8, comptime tail: []const u8) [*:0]const u8 {
        return "SELECT ma.id, cm.key, ma.text, cm.category, cm.timestamp_ms, cm.session_id, ma.confidence " ++
            "FROM compat_memories cm JOIN memory_atoms ma ON ma.id = cm.memory_atom_id " ++
            "WHERE ((?2 IS NULL AND cm.session_id IS NULL) OR (?2 IS NOT NULL AND cm.session_id = ?2)) " ++ extra_where ++ " " ++ tail;
    }

    fn readCompatMemory(allocator: std.mem.Allocator, stmt: *c.sqlite3_stmt) !domain.CompatMemory {
        const timestamp = try std.fmt.allocPrint(allocator, "{d}", .{c.sqlite3_column_int64(stmt, 4)});
        return .{
            .id = try columnText(allocator, stmt, 0),
            .key = try columnText(allocator, stmt, 1),
            .content = try columnText(allocator, stmt, 2),
            .category = try columnText(allocator, stmt, 3),
            .timestamp = timestamp,
            .session_id = try columnTextNullable(allocator, stmt, 5),
            .score = c.sqlite3_column_double(stmt, 6),
        };
    }

    pub fn saveMessage(self: *Self, session_id: []const u8, role: []const u8, content: []const u8) !void {
        const stmt = try self.prepare("INSERT INTO session_messages (session_id, role, content, created_at_ms) VALUES (?1,?2,?3,?4)");
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, session_id);
        bindText(stmt, 2, role);
        bindText(stmt, 3, content);
        _ = c.sqlite3_bind_int64(stmt, 4, ids.nowMs());
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.InsertFailed;
    }

    pub fn loadMessages(self: *Self, allocator: std.mem.Allocator, session_id: []const u8) ![]Message {
        const stmt = try self.prepare("SELECT role, content, created_at_ms FROM session_messages WHERE session_id = ?1 ORDER BY id ASC");
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, session_id);
        var out: std.ArrayListUnmanaged(Message) = .empty;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            try out.append(allocator, .{ .role = try columnText(allocator, stmt, 0), .content = try columnText(allocator, stmt, 1), .created_at_ms = c.sqlite3_column_int64(stmt, 2) });
        }
        return out.toOwnedSlice(allocator);
    }

    pub fn clearMessages(self: *Self, session_id: []const u8) !void {
        const stmt = try self.prepare("DELETE FROM session_messages WHERE session_id = ?1");
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, session_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DeleteFailed;
        const usage = try self.prepare("DELETE FROM session_usage WHERE session_id = ?1");
        defer _ = c.sqlite3_finalize(usage);
        bindText(usage, 1, session_id);
        _ = c.sqlite3_step(usage);
    }

    pub fn clearAutoSaved(self: *Self, session_id: ?[]const u8) !void {
        if (session_id) |sid| {
            const stmt = try self.prepare("DELETE FROM session_messages WHERE session_id = ?1 AND (role = 'autosave_user' OR role = 'autosave_assistant')");
            defer _ = c.sqlite3_finalize(stmt);
            bindText(stmt, 1, sid);
            if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DeleteFailed;
            return;
        }
        try self.exec("DELETE FROM session_messages WHERE role = 'autosave_user' OR role = 'autosave_assistant'");
    }

    pub fn saveUsage(self: *Self, session_id: []const u8, total_tokens: u64) !void {
        const stmt = try self.prepare("INSERT INTO session_usage (session_id,total_tokens,updated_at_ms) VALUES (?1,?2,?3) ON CONFLICT(session_id) DO UPDATE SET total_tokens = excluded.total_tokens, updated_at_ms = excluded.updated_at_ms");
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, session_id);
        _ = c.sqlite3_bind_int64(stmt, 2, @intCast(total_tokens));
        _ = c.sqlite3_bind_int64(stmt, 3, ids.nowMs());
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.UpdateFailed;
    }

    pub fn deleteUsage(self: *Self, session_id: []const u8) !bool {
        const stmt = try self.prepare("DELETE FROM session_usage WHERE session_id = ?1");
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, session_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DeleteFailed;
        return c.sqlite3_changes(self.db) > 0;
    }

    pub fn loadUsage(self: *Self, session_id: []const u8) !?u64 {
        const stmt = try self.prepare("SELECT total_tokens FROM session_usage WHERE session_id = ?1 LIMIT 1");
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, session_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        return @intCast(c.sqlite3_column_int64(stmt, 0));
    }

    pub fn listSessions(self: *Self, allocator: std.mem.Allocator, limit: usize, offset: usize) !HistoryList {
        const total = try self.countSql("SELECT COUNT(*) FROM (SELECT session_id FROM session_messages GROUP BY session_id)");
        const stmt = try self.prepare("SELECT session_id, COUNT(*), MIN(created_at_ms), MAX(created_at_ms) FROM session_messages GROUP BY session_id ORDER BY MAX(created_at_ms) DESC LIMIT ?1 OFFSET ?2");
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int64(stmt, 1, @intCast(limit));
        _ = c.sqlite3_bind_int64(stmt, 2, @intCast(offset));
        var sessions: std.ArrayListUnmanaged(SessionInfo) = .empty;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            try sessions.append(allocator, .{
                .session_id = try columnText(allocator, stmt, 0),
                .message_count = @intCast(c.sqlite3_column_int64(stmt, 1)),
                .first_message_at = c.sqlite3_column_int64(stmt, 2),
                .last_message_at = c.sqlite3_column_int64(stmt, 3),
            });
        }
        return .{ .total = @intCast(total), .sessions = try sessions.toOwnedSlice(allocator) };
    }

    pub fn history(self: *Self, allocator: std.mem.Allocator, session_id: []const u8, limit: usize, offset: usize) !HistoryShow {
        const count_stmt = try self.prepare("SELECT COUNT(*) FROM session_messages WHERE session_id = ?1");
        defer _ = c.sqlite3_finalize(count_stmt);
        bindText(count_stmt, 1, session_id);
        var total: u64 = 0;
        if (c.sqlite3_step(count_stmt) == c.SQLITE_ROW) total = @intCast(c.sqlite3_column_int64(count_stmt, 0));

        const stmt = try self.prepare("SELECT role, content, created_at_ms FROM session_messages WHERE session_id = ?1 ORDER BY id ASC LIMIT ?2 OFFSET ?3");
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, session_id);
        _ = c.sqlite3_bind_int64(stmt, 2, @intCast(limit));
        _ = c.sqlite3_bind_int64(stmt, 3, @intCast(offset));
        var messages: std.ArrayListUnmanaged(Message) = .empty;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            try messages.append(allocator, .{ .role = try columnText(allocator, stmt, 0), .content = try columnText(allocator, stmt, 1), .created_at_ms = c.sqlite3_column_int64(stmt, 2) });
        }
        return .{ .total = total, .messages = try messages.toOwnedSlice(allocator) };
    }

    pub fn createJob(self: *Self, allocator: std.mem.Allocator, input: JobInput) !Job {
        const id = try ids.make(allocator, "job_");
        const now = ids.nowMs();
        const stmt = try self.prepare("INSERT INTO jobs (id,job_type,status,scope,object_type,object_id,input_json,result_json,error_text,attempts,created_at_ms,updated_at_ms) VALUES (?1,?2,'queued',?3,?4,?5,?6,'{}',NULL,0,?7,?8)");
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, id);
        bindText(stmt, 2, input.job_type);
        bindText(stmt, 3, input.scope);
        bindText(stmt, 4, input.object_type);
        bindText(stmt, 5, input.object_id);
        bindText(stmt, 6, input.input_json);
        _ = c.sqlite3_bind_int64(stmt, 7, now);
        _ = c.sqlite3_bind_int64(stmt, 8, now);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.InsertFailed;
        self.insertAudit("job.created", "job", id);
        return .{
            .id = id,
            .job_type = input.job_type,
            .status = "queued",
            .scope = input.scope,
            .object_type = input.object_type,
            .object_id = input.object_id,
            .input_json = input.input_json,
            .result_json = "{}",
            .error_text = null,
            .attempts = 0,
            .created_at_ms = now,
            .updated_at_ms = now,
        };
    }

    pub fn getJob(self: *Self, allocator: std.mem.Allocator, id: []const u8) !?Job {
        const stmt = try self.prepare("SELECT id,job_type,status,scope,object_type,object_id,input_json,result_json,error_text,attempts,created_at_ms,updated_at_ms FROM jobs WHERE id = ?1 LIMIT 1");
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, id);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        return try readJob(allocator, stmt);
    }

    pub fn listJobs(self: *Self, allocator: std.mem.Allocator, input: JobListInput) ![]Job {
        const stmt = if (input.status) |_|
            try self.prepare("SELECT id,job_type,status,scope,object_type,object_id,input_json,result_json,error_text,attempts,created_at_ms,updated_at_ms FROM jobs WHERE status = ?1 ORDER BY created_at_ms DESC LIMIT ?2")
        else
            try self.prepare("SELECT id,job_type,status,scope,object_type,object_id,input_json,result_json,error_text,attempts,created_at_ms,updated_at_ms FROM jobs ORDER BY created_at_ms DESC LIMIT ?2");
        defer _ = c.sqlite3_finalize(stmt);
        if (input.status) |status| bindText(stmt, 1, status);
        _ = c.sqlite3_bind_int64(stmt, 2, @intCast(@max(@as(usize, 1), @min(input.limit, 500))));
        var out: std.ArrayListUnmanaged(Job) = .empty;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const scope = try columnText(allocator, stmt, 3);
            if (!domain.scopeVisible(scope, input.scopes_json)) continue;
            try out.append(allocator, try readJobWithScope(allocator, stmt, scope));
        }
        return out.toOwnedSlice(allocator);
    }

    pub fn finishJob(self: *Self, id: []const u8, status: []const u8, result_json: []const u8, error_text: ?[]const u8) !bool {
        const stmt = try self.prepare("UPDATE jobs SET status = ?1, result_json = ?2, error_text = ?3, attempts = attempts + 1, updated_at_ms = ?4 WHERE id = ?5");
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, status);
        bindText(stmt, 2, result_json);
        bindNullableText(stmt, 3, error_text);
        _ = c.sqlite3_bind_int64(stmt, 4, ids.nowMs());
        bindText(stmt, 5, id);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.UpdateFailed;
        const changed = c.sqlite3_changes(self.db) > 0;
        if (changed) self.insertAudit("job.finished", "job", id);
        return changed;
    }

    fn readJob(allocator: std.mem.Allocator, stmt: *c.sqlite3_stmt) !Job {
        const scope = try columnText(allocator, stmt, 3);
        return readJobWithScope(allocator, stmt, scope);
    }

    fn readJobWithScope(allocator: std.mem.Allocator, stmt: *c.sqlite3_stmt, scope: []const u8) !Job {
        return .{
            .id = try columnText(allocator, stmt, 0),
            .job_type = try columnText(allocator, stmt, 1),
            .status = try columnText(allocator, stmt, 2),
            .scope = scope,
            .object_type = try columnText(allocator, stmt, 4),
            .object_id = try columnText(allocator, stmt, 5),
            .input_json = try columnText(allocator, stmt, 6),
            .result_json = try columnText(allocator, stmt, 7),
            .error_text = try columnTextNullable(allocator, stmt, 8),
            .attempts = c.sqlite3_column_int64(stmt, 9),
            .created_at_ms = c.sqlite3_column_int64(stmt, 10),
            .updated_at_ms = c.sqlite3_column_int64(stmt, 11),
        };
    }

    pub fn listConflicts(self: *Self, allocator: std.mem.Allocator, input: ConflictListInput) ![]KnowledgeConflict {
        const stmt = if (input.status) |_|
            try self.prepare("SELECT id,conflict_type,object_a_type,object_a_id,object_b_type,object_b_id,scope,status,summary,created_at_ms,resolved_at_ms FROM knowledge_conflicts WHERE status = ?1 ORDER BY created_at_ms DESC LIMIT ?2")
        else
            try self.prepare("SELECT id,conflict_type,object_a_type,object_a_id,object_b_type,object_b_id,scope,status,summary,created_at_ms,resolved_at_ms FROM knowledge_conflicts ORDER BY created_at_ms DESC LIMIT ?2");
        defer _ = c.sqlite3_finalize(stmt);
        if (input.status) |status| bindText(stmt, 1, status);
        _ = c.sqlite3_bind_int64(stmt, 2, @intCast(@max(@as(usize, 1), @min(input.limit, 500))));
        var out: std.ArrayListUnmanaged(KnowledgeConflict) = .empty;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const scope = try columnText(allocator, stmt, 6);
            if (!domain.scopeVisible(scope, input.scopes_json)) continue;
            try out.append(allocator, try readConflictWithScope(allocator, stmt, scope));
        }
        return out.toOwnedSlice(allocator);
    }

    pub fn scanConflicts(self: *Self, allocator: std.mem.Allocator, input: ConflictListInput) ![]KnowledgeConflict {
        const atoms = try self.visibleMemoryAtomsForConflictScan(allocator, input.scopes_json, @max(@as(usize, 50), @min(input.limit * 10, 1000)));
        for (atoms, 0..) |a, i| {
            if (!domain.isDefaultVisibleStatus(a.status)) continue;
            for (atoms[i + 1 ..]) |b| {
                if (!domain.isDefaultVisibleStatus(b.status)) continue;
                if (!sameConflictSubject(a, b)) continue;
                if (std.mem.eql(u8, a.object, b.object)) continue;
                try self.insertConflictIfMissing(allocator, a, b);
            }
        }
        return try self.listConflicts(allocator, input);
    }

    fn visibleMemoryAtomsForConflictScan(self: *Self, allocator: std.mem.Allocator, scopes_json: []const u8, limit: usize) ![]domain.MemoryAtom {
        const stmt = try self.prepare("SELECT id,subject_entity_id,predicate,object,text,scope,confidence,status,source_ids_json,evidence_ranges_json,created_by,created_at_ms,valid_from_ms,valid_until_ms,last_verified_at_ms,owner,permissions_json,tags_json FROM memory_atoms ORDER BY created_at_ms DESC LIMIT ?1");
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int64(stmt, 1, @intCast(limit));
        var out: std.ArrayListUnmanaged(domain.MemoryAtom) = .empty;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const atom = try readMemoryAtom(allocator, stmt);
            if (!domain.recordVisible(atom.scope, atom.permissions_json, scopes_json)) continue;
            try out.append(allocator, atom);
        }
        return out.toOwnedSlice(allocator);
    }

    fn sameConflictSubject(a: domain.MemoryAtom, b: domain.MemoryAtom) bool {
        if (!std.mem.eql(u8, a.scope, b.scope)) return false;
        if (!std.mem.eql(u8, a.predicate, b.predicate)) return false;
        if (a.subject_entity_id != null and b.subject_entity_id != null) return std.mem.eql(u8, a.subject_entity_id.?, b.subject_entity_id.?);
        return true;
    }

    fn insertConflictIfMissing(self: *Self, allocator: std.mem.Allocator, a: domain.MemoryAtom, b: domain.MemoryAtom) !void {
        const a_id = if (std.mem.lessThan(u8, a.id, b.id)) a.id else b.id;
        const b_id = if (std.mem.lessThan(u8, a.id, b.id)) b.id else a.id;
        const summary = try std.fmt.allocPrint(allocator, "Potential conflicting {s}: {s} vs {s}", .{ a.predicate, a.object, b.object });
        const id = try ids.make(allocator, "cnf_");
        const now = ids.nowMs();
        const stmt = try self.prepare("INSERT OR IGNORE INTO knowledge_conflicts (id,conflict_type,object_a_type,object_a_id,object_b_type,object_b_id,scope,status,summary,created_at_ms,resolved_at_ms) VALUES (?1,'memory_atom_conflict','memory_atom',?2,'memory_atom',?3,?4,'open',?5,?6,NULL)");
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, id);
        bindText(stmt, 2, a_id);
        bindText(stmt, 3, b_id);
        bindText(stmt, 4, a.scope);
        bindText(stmt, 5, summary);
        _ = c.sqlite3_bind_int64(stmt, 6, now);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.InsertFailed;
        if (c.sqlite3_changes(self.db) > 0) self.insertAudit("conflict.detected", "knowledge_conflict", id);
    }

    fn readConflictWithScope(allocator: std.mem.Allocator, stmt: *c.sqlite3_stmt, scope: []const u8) !KnowledgeConflict {
        return .{
            .id = try columnText(allocator, stmt, 0),
            .conflict_type = try columnText(allocator, stmt, 1),
            .object_a_type = try columnText(allocator, stmt, 2),
            .object_a_id = try columnText(allocator, stmt, 3),
            .object_b_type = try columnText(allocator, stmt, 4),
            .object_b_id = try columnText(allocator, stmt, 5),
            .scope = scope,
            .status = try columnText(allocator, stmt, 7),
            .summary = try columnText(allocator, stmt, 8),
            .created_at_ms = c.sqlite3_column_int64(stmt, 9),
            .resolved_at_ms = if (c.sqlite3_column_type(stmt, 10) == c.SQLITE_NULL) null else c.sqlite3_column_int64(stmt, 10),
        };
    }

    fn countSql(self: *Self, sql: [*:0]const u8) !i64 {
        const stmt = try self.prepare(sql);
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return 0;
        return c.sqlite3_column_int64(stmt, 0);
    }
};

pub const PostgresStore = struct {
    allocator: std.mem.Allocator,
    url: []const u8,
    psql_bin: []const u8,

    pub fn init(allocator: std.mem.Allocator, url: []const u8) !PostgresStore {
        const owned = try allocator.dupe(u8, url);
        const psql_bin = compat.process.getEnvVarOwned(allocator, "NULLPANTRY_PSQL_BIN") catch blk: {
            break :blk try allocator.dupe(u8, "psql");
        };
        var self = PostgresStore{ .allocator = allocator, .url = owned, .psql_bin = psql_bin };
        try self.runSql(migrations.postgres_schema);
        return self;
    }

    pub fn deinit(self: *PostgresStore) void {
        self.allocator.free(self.url);
        self.allocator.free(self.psql_bin);
    }

    pub fn health(self: *PostgresStore) bool {
        self.runSql("SELECT 1;") catch return false;
        return true;
    }

    fn runSql(self: *PostgresStore, sql: []const u8) !void {
        const out = try self.queryRaw(self.allocator, sql);
        self.allocator.free(out);
    }

    fn queryRaw(self: *PostgresStore, allocator: std.mem.Allocator, sql: []const u8) ![]u8 {
        const argv = [_][]const u8{ self.psql_bin, self.url, "-X", "-v", "ON_ERROR_STOP=1", "-q", "-t", "-A", "-c", sql };
        const result = try std.process.run(allocator, compat.io(), .{
            .argv = &argv,
            .stdout_limit = .limited(32 * 1024 * 1024),
            .stderr_limit = .limited(4 * 1024 * 1024),
        });
        defer allocator.free(result.stderr);
        defer allocator.free(result.stdout);
        switch (result.term) {
            .exited => |code| if (code != 0) return error.PostgresCommandFailed,
            else => return error.PostgresCommandFailed,
        }
        return allocator.dupe(u8, std.mem.trim(u8, result.stdout, " \t\r\n"));
    }

    fn queryText(self: *PostgresStore, allocator: std.mem.Allocator, sql: []const u8) ![]u8 {
        return self.queryRaw(allocator, sql);
    }

    fn queryJson(self: *PostgresStore, allocator: std.mem.Allocator, sql: []const u8) !std.json.Parsed(std.json.Value) {
        const text = try self.queryText(allocator, sql);
        if (text.len == 0) return std.json.parseFromSlice(std.json.Value, allocator, "null", .{});
        return std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    }

    fn rowJsonSql(allocator: std.mem.Allocator, inner_sql: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "SELECT coalesce((SELECT row_to_json(t)::text FROM ({s}) t), 'null')", .{inner_sql});
    }

    fn arrayJsonSql(allocator: std.mem.Allocator, inner_sql: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "SELECT coalesce((SELECT json_agg(row_to_json(t))::text FROM ({s}) t), '[]')", .{inner_sql});
    }

    fn sqlString(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        try out.append(allocator, '\'');
        for (value) |ch| {
            if (ch == '\'') try out.append(allocator, '\'');
            try out.append(allocator, ch);
        }
        try out.append(allocator, '\'');
        return out.toOwnedSlice(allocator);
    }

    fn sqlNullableString(allocator: std.mem.Allocator, value: ?[]const u8) ![]u8 {
        if (value) |v| return sqlString(allocator, v);
        return allocator.dupe(u8, "NULL");
    }

    fn sqlJsonb(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
        const quoted = try sqlString(allocator, value);
        return std.fmt.allocPrint(allocator, "{s}::jsonb", .{quoted});
    }

    fn sqlNullableInt(allocator: std.mem.Allocator, value: ?i64) ![]u8 {
        if (value) |v| return std.fmt.allocPrint(allocator, "{d}", .{v});
        return allocator.dupe(u8, "NULL");
    }

    pub fn createSource(self: *PostgresStore, allocator: std.mem.Allocator, input: SourceInput) !domain.Source {
        const id = try ids.make(allocator, "src_");
        const now = ids.nowMs();
        const sql = try std.fmt.allocPrint(
            allocator,
            "INSERT INTO sources (id,type,title,raw_content_uri,content,author,participants_json,permissions_json,scope,created_at_ms,imported_at_ms,checksum,language,related_entities_json,metadata_json) VALUES ({s},{s},{s},{s},{s},{s},{s},{s},{s},{d},{d},{s},{s},{s},{s})",
            .{
                try sqlString(allocator, id),
                try sqlString(allocator, input.source_type),
                try sqlString(allocator, input.title),
                try sqlNullableString(allocator, input.raw_content_uri),
                try sqlString(allocator, input.content),
                try sqlNullableString(allocator, input.author),
                try sqlJsonb(allocator, input.participants_json),
                try sqlJsonb(allocator, input.permissions_json),
                try sqlString(allocator, input.scope),
                now,
                now,
                try sqlNullableString(allocator, input.checksum),
                try sqlNullableString(allocator, input.language),
                try sqlJsonb(allocator, input.related_entities_json),
                try sqlJsonb(allocator, input.metadata_json),
            },
        );
        try self.runSql(sql);
        return .{ .id = id, .source_type = input.source_type, .title = input.title, .raw_content_uri = input.raw_content_uri, .content = input.content, .author = input.author, .participants_json = input.participants_json, .permissions_json = input.permissions_json, .scope = input.scope, .created_at_ms = now, .imported_at_ms = now, .checksum = input.checksum, .language = input.language, .related_entities_json = input.related_entities_json, .metadata_json = input.metadata_json };
    }

    pub fn getSource(self: *PostgresStore, allocator: std.mem.Allocator, id: []const u8) !?domain.Source {
        const inner = try std.fmt.allocPrint(allocator, "SELECT id,type,title,raw_content_uri,content,author,participants_json,permissions_json,scope,created_at_ms,imported_at_ms,checksum,language,related_entities_json,metadata_json FROM sources WHERE id = {s} LIMIT 1", .{try sqlString(allocator, id)});
        const parsed = try self.queryJson(allocator, try rowJsonSql(allocator, inner));
        defer parsed.deinit();
        if (parsed.value == .null) return null;
        return try readPgSource(allocator, parsed.value.object);
    }

    pub fn createArtifact(self: *PostgresStore, allocator: std.mem.Allocator, input: ArtifactInput) !domain.Artifact {
        const id = try ids.make(allocator, "art_");
        const now = ids.nowMs();
        const sql = try std.fmt.allocPrint(
            allocator,
            "INSERT INTO artifacts (id,type,title,body,status,owner,space_id,version,created_at_ms,updated_at_ms,last_verified_at_ms,source_ids_json,related_entities_json,permissions_json,summary,agent_summary) VALUES ({s},{s},{s},{s},{s},{s},{s},1,{d},{d},NULL,{s},{s},{s},{s},{s})",
            .{ try sqlString(allocator, id), try sqlString(allocator, input.artifact_type), try sqlString(allocator, input.title), try sqlString(allocator, input.body), try sqlString(allocator, input.status), try sqlNullableString(allocator, input.owner), try sqlNullableString(allocator, input.space_id), now, now, try sqlJsonb(allocator, input.source_ids_json), try sqlJsonb(allocator, input.related_entities_json), try sqlJsonb(allocator, input.permissions_json), try sqlNullableString(allocator, input.summary), try sqlNullableString(allocator, input.agent_summary) },
        );
        try self.runSql(sql);
        return .{ .id = id, .artifact_type = input.artifact_type, .title = input.title, .body = input.body, .status = input.status, .owner = input.owner, .space_id = input.space_id, .version = 1, .created_at_ms = now, .updated_at_ms = now, .last_verified_at_ms = null, .source_ids_json = input.source_ids_json, .related_entities_json = input.related_entities_json, .permissions_json = input.permissions_json, .summary = input.summary, .agent_summary = input.agent_summary };
    }

    pub fn getArtifact(self: *PostgresStore, allocator: std.mem.Allocator, id: []const u8) !?domain.Artifact {
        const inner = try std.fmt.allocPrint(allocator, "SELECT id,type,title,body,status,owner,space_id,version,created_at_ms,updated_at_ms,last_verified_at_ms,source_ids_json,related_entities_json,permissions_json,summary,agent_summary FROM artifacts WHERE id = {s} LIMIT 1", .{try sqlString(allocator, id)});
        const parsed = try self.queryJson(allocator, try rowJsonSql(allocator, inner));
        defer parsed.deinit();
        if (parsed.value == .null) return null;
        return try readPgArtifact(allocator, parsed.value.object);
    }

    pub fn resolveEntity(self: *PostgresStore, allocator: std.mem.Allocator, input: EntityInput) !domain.Entity {
        if (try self.findEntity(allocator, input.entity_type, input.name)) |entity| return entity;
        const id = try ids.make(allocator, "ent_");
        const now = ids.nowMs();
        const sql = try std.fmt.allocPrint(
            allocator,
            "INSERT INTO entities (id,type,name,aliases_json,description,canonical_artifact_id,metadata_json,created_at_ms,updated_at_ms) VALUES ({s},{s},{s},{s},{s},{s},{s},{d},{d})",
            .{ try sqlString(allocator, id), try sqlString(allocator, input.entity_type), try sqlString(allocator, input.name), try sqlJsonb(allocator, input.aliases_json), try sqlNullableString(allocator, input.description), try sqlNullableString(allocator, input.canonical_artifact_id), try sqlJsonb(allocator, input.metadata_json), now, now },
        );
        try self.runSql(sql);
        return .{ .id = id, .entity_type = input.entity_type, .name = input.name, .aliases_json = input.aliases_json, .description = input.description, .canonical_artifact_id = input.canonical_artifact_id, .metadata_json = input.metadata_json, .created_at_ms = now, .updated_at_ms = now };
    }

    fn findEntity(self: *PostgresStore, allocator: std.mem.Allocator, entity_type: []const u8, name: []const u8) !?domain.Entity {
        const inner = try std.fmt.allocPrint(allocator, "SELECT id,type,name,aliases_json,description,canonical_artifact_id,metadata_json,created_at_ms,updated_at_ms FROM entities WHERE type = {s} AND lower(name) = lower({s}) LIMIT 1", .{ try sqlString(allocator, entity_type), try sqlString(allocator, name) });
        const parsed = try self.queryJson(allocator, try rowJsonSql(allocator, inner));
        defer parsed.deinit();
        if (parsed.value == .null) return null;
        return try readPgEntity(allocator, parsed.value.object);
    }

    pub fn createRelation(self: *PostgresStore, allocator: std.mem.Allocator, input: RelationInput) !domain.Relation {
        if (!try self.entityExists(allocator, input.from_entity_id) or !try self.entityExists(allocator, input.to_entity_id)) return error.EntityNotFound;
        const id = try ids.make(allocator, "rel_");
        const now = ids.nowMs();
        const sql = try std.fmt.allocPrint(allocator, "INSERT INTO relations (id,from_entity_id,relation_type,to_entity_id,source_ids_json,confidence,status,created_at_ms) VALUES ({s},{s},{s},{s},{s},{d},{s},{d})", .{ try sqlString(allocator, id), try sqlString(allocator, input.from_entity_id), try sqlString(allocator, input.relation_type), try sqlString(allocator, input.to_entity_id), try sqlJsonb(allocator, input.source_ids_json), input.confidence, try sqlString(allocator, input.status), now });
        try self.runSql(sql);
        return .{ .id = id, .from_entity_id = input.from_entity_id, .relation_type = input.relation_type, .to_entity_id = input.to_entity_id, .source_ids_json = input.source_ids_json, .confidence = input.confidence, .status = input.status, .created_at_ms = now };
    }

    fn entityExists(self: *PostgresStore, allocator: std.mem.Allocator, id: []const u8) !bool {
        const sql = try std.fmt.allocPrint(allocator, "SELECT CASE WHEN EXISTS (SELECT 1 FROM entities WHERE id = {s}) THEN 'true' ELSE 'false' END", .{try sqlString(allocator, id)});
        const text = try self.queryText(allocator, sql);
        return std.mem.eql(u8, text, "true");
    }

    pub fn createMemoryAtom(self: *PostgresStore, allocator: std.mem.Allocator, input: MemoryAtomInput) !domain.MemoryAtom {
        const id = try ids.make(allocator, "mem_");
        const now = ids.nowMs();
        const status = input.status orelse domain.defaultMemoryStatus(input.created_by, input.scope);
        const sql = try std.fmt.allocPrint(
            allocator,
            "INSERT INTO memory_atoms (id,subject_entity_id,predicate,object,text,scope,confidence,status,source_ids_json,evidence_ranges_json,created_by,created_at_ms,valid_from_ms,valid_until_ms,last_verified_at_ms,owner,permissions_json,tags_json) VALUES ({s},{s},{s},{s},{s},{s},{d},{s},{s},{s},{s},{d},{s},{s},NULL,{s},{s},{s})",
            .{ try sqlString(allocator, id), try sqlNullableString(allocator, input.subject_entity_id), try sqlString(allocator, input.predicate), try sqlString(allocator, input.object), try sqlString(allocator, input.text), try sqlString(allocator, input.scope), input.confidence, try sqlString(allocator, status), try sqlJsonb(allocator, input.source_ids_json), try sqlJsonb(allocator, input.evidence_ranges_json), try sqlString(allocator, input.created_by), now, try sqlNullableInt(allocator, input.valid_from_ms), try sqlNullableInt(allocator, input.valid_until_ms), try sqlNullableString(allocator, input.owner), try sqlJsonb(allocator, input.permissions_json), try sqlJsonb(allocator, input.tags_json) },
        );
        try self.runSql(sql);
        return .{ .id = id, .subject_entity_id = input.subject_entity_id, .predicate = input.predicate, .object = input.object, .text = input.text, .scope = input.scope, .confidence = input.confidence, .status = status, .source_ids_json = input.source_ids_json, .evidence_ranges_json = input.evidence_ranges_json, .created_by = input.created_by, .created_at_ms = now, .valid_from_ms = input.valid_from_ms, .valid_until_ms = input.valid_until_ms, .last_verified_at_ms = null, .owner = input.owner, .permissions_json = input.permissions_json, .tags_json = input.tags_json };
    }

    pub fn getMemoryAtom(self: *PostgresStore, allocator: std.mem.Allocator, id: []const u8) !?domain.MemoryAtom {
        const inner = try std.fmt.allocPrint(allocator, "SELECT id,subject_entity_id,predicate,object,text,scope,confidence,status,source_ids_json,evidence_ranges_json,created_by,created_at_ms,valid_from_ms,valid_until_ms,last_verified_at_ms,owner,permissions_json,tags_json FROM memory_atoms WHERE id = {s} LIMIT 1", .{try sqlString(allocator, id)});
        const parsed = try self.queryJson(allocator, try rowJsonSql(allocator, inner));
        defer parsed.deinit();
        if (parsed.value == .null) return null;
        return try readPgMemoryAtom(allocator, parsed.value.object);
    }

    pub fn patchMemoryAtomStatus(self: *PostgresStore, id: []const u8, status: []const u8, verified: bool) !bool {
        const sql = try std.fmt.allocPrint(self.allocator, "WITH updated AS (UPDATE memory_atoms SET status = {s}, last_verified_at_ms = CASE WHEN {s} THEN {d} ELSE last_verified_at_ms END WHERE id = {s} RETURNING id) SELECT count(*)::text FROM updated", .{ try sqlString(self.allocator, status), if (verified) "true" else "false", ids.nowMs(), try sqlString(self.allocator, id) });
        const text = try self.queryText(self.allocator, sql);
        defer self.allocator.free(text);
        return (std.fmt.parseInt(usize, text, 10) catch 0) > 0;
    }

    pub fn search(self: *PostgresStore, allocator: std.mem.Allocator, input: SearchInput) ![]domain.SearchResult {
        var results: std.ArrayListUnmanaged(domain.SearchResult) = .empty;
        try self.searchPgMemoryAtoms(allocator, input, &results);
        try self.searchPgSources(allocator, input, &results);
        try self.searchPgArtifacts(allocator, input, &results);
        try self.searchPgEntities(allocator, input, &results);
        try self.searchPgRelations(allocator, input, &results);
        try self.searchPgContextPacks(allocator, input, &results);
        try self.searchPgFeedEvents(allocator, input, &results);
        try self.searchPgCompat(allocator, input, &results);
        if (input.include_sessions and (domain.hasActorScope(input.scopes_json, "admin") or domain.hasActorScope(input.scopes_json, "agent:nullclaw"))) try self.searchPgSessions(allocator, input, &results);
        if (input.use_vector and input.query.len > 0) try self.searchPgVectorCandidates(allocator, input, &results);
        pgSortSearchResults(results.items);
        const out = try allocator.alloc(domain.SearchResult, @min(results.items.len, @max(@as(usize, 1), @min(input.limit, 100))));
        @memcpy(out, results.items[0..out.len]);
        return out;
    }

    pub fn upsertVectorChunk(self: *PostgresStore, allocator: std.mem.Allocator, input: VectorChunkInput) !VectorChunk {
        _ = try vector_mod.embeddingFromJson(allocator, input.embedding_json);
        const id = try std.fmt.allocPrint(allocator, "vec_{s}_{d}", .{ input.object_id, input.chunk_ordinal });
        const now = ids.nowMs();
        const sql = try std.fmt.allocPrint(allocator, "INSERT INTO vector_chunks (id,object_type,object_id,chunk_ordinal,text,scope,permissions_json,embedding_json,model,dimensions,created_at_ms,updated_at_ms) VALUES ({s},{s},{s},{d},{s},{s},{s},{s},{s},{d},{d},{d}) ON CONFLICT(id) DO UPDATE SET text=excluded.text, scope=excluded.scope, permissions_json=excluded.permissions_json, embedding_json=excluded.embedding_json, model=excluded.model, dimensions=excluded.dimensions, updated_at_ms=excluded.updated_at_ms", .{ try sqlString(allocator, id), try sqlString(allocator, input.object_type), try sqlString(allocator, input.object_id), input.chunk_ordinal, try sqlString(allocator, input.text), try sqlString(allocator, input.scope), try sqlJsonb(allocator, input.permissions_json), try sqlJsonb(allocator, input.embedding_json), try sqlNullableString(allocator, input.model), input.dimensions, now, now });
        try self.runSql(sql);
        _ = try self.enqueueVectorOutbox(.{ .action = "upsert", .object_type = input.object_type, .object_id = input.object_id });
        return .{ .id = id, .object_type = input.object_type, .object_id = input.object_id, .chunk_ordinal = input.chunk_ordinal, .text = input.text, .scope = input.scope, .permissions_json = input.permissions_json, .embedding_json = input.embedding_json, .model = input.model, .dimensions = input.dimensions, .created_at_ms = now, .updated_at_ms = now };
    }

    pub fn vectorSearch(self: *PostgresStore, allocator: std.mem.Allocator, input: VectorSearchInput) ![]vector_mod.VectorMatch {
        const query = try vector_mod.embeddingFromJson(allocator, input.embedding_json);
        const parsed = try self.queryJson(allocator, try arrayJsonSql(allocator, "SELECT id,object_id,object_type,text,scope,permissions_json,embedding_json FROM vector_chunks ORDER BY updated_at_ms DESC LIMIT 5000"));
        defer parsed.deinit();
        var records: std.ArrayListUnmanaged(vector_mod.VectorRecord) = .empty;
        if (parsed.value == .array) {
            for (parsed.value.array.items) |item| {
                if (item != .object) continue;
                const obj = item.object;
                const scope = try dupStringField(allocator, obj, "scope", "");
                const permissions = try rawJsonField(allocator, obj, "permissions_json", "[]");
                if (!domain.recordVisible(scope, permissions, input.scopes_json)) continue;
                const embedding_json = try rawJsonField(allocator, obj, "embedding_json", "[]");
                const embedding = vector_mod.embeddingFromJson(allocator, embedding_json) catch continue;
                try records.append(allocator, .{ .id = try dupStringField(allocator, obj, "id", ""), .object_id = try dupStringField(allocator, obj, "object_id", ""), .object_type = try dupStringField(allocator, obj, "object_type", ""), .text = try dupStringField(allocator, obj, "text", ""), .scope = scope, .embedding = embedding });
            }
        }
        return vector_mod.annSearch(allocator, query, records.items, 512, @max(@as(usize, 1), @min(input.limit, 100)));
    }

    pub fn enqueueVectorOutbox(self: *PostgresStore, input: VectorOutboxInput) !i64 {
        const now = ids.nowMs();
        const sql = try std.fmt.allocPrint(self.allocator, "INSERT INTO vector_outbox (action,object_type,object_id,status,attempts,payload_json,created_at_ms,updated_at_ms) VALUES ({s},{s},{s},'pending',0,{s},{d},{d}) RETURNING id::text", .{ try sqlString(self.allocator, input.action), try sqlString(self.allocator, input.object_type), try sqlString(self.allocator, input.object_id), try sqlJsonb(self.allocator, input.payload_json), now, now });
        const text = try self.queryText(self.allocator, sql);
        defer self.allocator.free(text);
        return std.fmt.parseInt(i64, text, 10) catch 0;
    }

    pub fn countVectorOutbox(self: *PostgresStore, status: ?[]const u8) !usize {
        const sql = if (status) |s| try std.fmt.allocPrint(self.allocator, "SELECT count(*)::text FROM vector_outbox WHERE status = {s}", .{try sqlString(self.allocator, s)}) else "SELECT count(*)::text FROM vector_outbox";
        const text = try self.queryText(self.allocator, sql);
        defer self.allocator.free(text);
        return std.fmt.parseInt(usize, text, 10) catch 0;
    }

    pub fn runVectorOutbox(self: *PostgresStore, limit: usize) !VectorOutboxRunResult {
        const capped = @max(@as(usize, 1), @min(limit, 1000));
        const now = ids.nowMs();
        const sql = try std.fmt.allocPrint(self.allocator, "WITH updated AS (UPDATE vector_outbox SET status = 'delivered_local', attempts = attempts + 1, updated_at_ms = {d} WHERE id IN (SELECT id FROM vector_outbox WHERE status = 'pending' ORDER BY id LIMIT {d}) RETURNING id) SELECT count(*)::text FROM updated", .{ now, capped });
        const text = try self.queryText(self.allocator, sql);
        defer self.allocator.free(text);
        return .{ .processed = std.fmt.parseInt(usize, text, 10) catch 0, .failed = 0 };
    }

    pub fn appendFeedEvent(self: *PostgresStore, input: FeedEventInput) !i64 {
        if (input.dedupe_key) |key| {
            if (try self.feedEventIdByDedupeKey(key)) |id| return id;
        }
        const now = ids.nowMs();
        const applied = if (std.mem.eql(u8, input.status, "applied")) try std.fmt.allocPrint(self.allocator, "{d}", .{now}) else "NULL";
        const sql = try std.fmt.allocPrint(self.allocator, "INSERT INTO memory_feed_events (event_type,object_type,object_id,scope,dedupe_key,payload_json,status,created_at_ms,applied_at_ms) VALUES ({s},{s},{s},{s},{s},{s},{s},{d},{s}) ON CONFLICT (dedupe_key) WHERE dedupe_key IS NOT NULL DO UPDATE SET dedupe_key = excluded.dedupe_key RETURNING id::text", .{ try sqlString(self.allocator, input.event_type), try sqlString(self.allocator, input.object_type), try sqlString(self.allocator, input.object_id), try sqlString(self.allocator, input.scope), try sqlNullableString(self.allocator, input.dedupe_key), try sqlJsonb(self.allocator, input.payload_json), try sqlString(self.allocator, input.status), now, applied });
        const text = try self.queryText(self.allocator, sql);
        defer self.allocator.free(text);
        return std.fmt.parseInt(i64, text, 10) catch 0;
    }

    fn feedEventIdByDedupeKey(self: *PostgresStore, key: []const u8) !?i64 {
        const sql = try std.fmt.allocPrint(self.allocator, "SELECT coalesce((SELECT id::text FROM memory_feed_events WHERE dedupe_key = {s} LIMIT 1), '')", .{try sqlString(self.allocator, key)});
        const text = try self.queryText(self.allocator, sql);
        defer self.allocator.free(text);
        if (text.len == 0) return null;
        return std.fmt.parseInt(i64, text, 10) catch null;
    }

    pub fn listFeedEvents(self: *PostgresStore, allocator: std.mem.Allocator, input: FeedListInput) ![]FeedEvent {
        const inner = try std.fmt.allocPrint(allocator, "SELECT id,event_type,object_type,object_id,scope,dedupe_key,payload_json,status,created_at_ms,applied_at_ms FROM memory_feed_events WHERE id > {d} ORDER BY id ASC LIMIT {d}", .{ input.since_id, @max(@as(usize, 1), @min(input.limit, 500)) });
        const parsed = try self.queryJson(allocator, try arrayJsonSql(allocator, inner));
        defer parsed.deinit();
        var out: std.ArrayListUnmanaged(FeedEvent) = .empty;
        if (parsed.value == .array) for (parsed.value.array.items) |item| {
            if (item != .object) continue;
            const event = try readPgFeedEvent(allocator, item.object);
            if (!domain.scopeVisible(event.scope, input.scopes_json)) continue;
            try out.append(allocator, event);
        };
        return out.toOwnedSlice(allocator);
    }

    pub fn getFeedEventByDedupeKey(self: *PostgresStore, allocator: std.mem.Allocator, dedupe_key: []const u8) !?FeedEvent {
        const inner = try std.fmt.allocPrint(allocator, "SELECT id,event_type,object_type,object_id,scope,dedupe_key,payload_json,status,created_at_ms,applied_at_ms FROM memory_feed_events WHERE dedupe_key = {s} LIMIT 1", .{try sqlString(allocator, dedupe_key)});
        const parsed = try self.queryJson(allocator, try rowJsonSql(allocator, inner));
        defer parsed.deinit();
        if (parsed.value == .null) return null;
        return try readPgFeedEvent(allocator, parsed.value.object);
    }

    pub fn createLifecycleSnapshot(self: *PostgresStore, allocator: std.mem.Allocator, snapshot_type: []const u8, summary_json: []const u8) !LifecycleSnapshot {
        const id = try ids.make(allocator, "snap_");
        const now = ids.nowMs();
        const sql = try std.fmt.allocPrint(allocator, "INSERT INTO lifecycle_snapshots (id,snapshot_type,summary_json,created_at_ms) VALUES ({s},{s},{s},{d})", .{ try sqlString(allocator, id), try sqlString(allocator, snapshot_type), try sqlJsonb(allocator, summary_json), now });
        try self.runSql(sql);
        return .{ .id = id, .snapshot_type = snapshot_type, .summary_json = summary_json, .created_at_ms = now };
    }

    pub fn lifecycleDiagnostics(self: *PostgresStore) !LifecycleDiagnostics {
        const sql = "SELECT json_build_object('total_memory_atoms',(SELECT count(*) FROM memory_atoms),'stale_memory_atoms',(SELECT count(*) FROM memory_atoms WHERE status='stale'),'vector_outbox_pending',(SELECT count(*) FROM vector_outbox WHERE status='pending'),'cache_entries',(SELECT count(*) FROM response_cache)+(SELECT count(*) FROM semantic_cache))::text";
        const parsed = try self.queryJson(self.allocator, sql);
        defer parsed.deinit();
        const obj = parsed.value.object;
        return .{ .total_memory_atoms = @intCast(json.intField(obj, "total_memory_atoms") orelse 0), .stale_memory_atoms = @intCast(json.intField(obj, "stale_memory_atoms") orelse 0), .vector_outbox_pending = @intCast(json.intField(obj, "vector_outbox_pending") orelse 0), .cache_entries = @intCast(json.intField(obj, "cache_entries") orelse 0) };
    }

    pub fn putResponseCache(self: *PostgresStore, input: ResponseCacheInput) !void {
        const now = input.now_ms orelse ids.nowMs();
        const expires = if (input.ttl_ms > 0) now + input.ttl_ms else 0;
        const sql = try std.fmt.allocPrint(self.allocator, "INSERT INTO response_cache (cache_key,response_json,created_at_ms,expires_at_ms) VALUES ({s},{s},{d},{d}) ON CONFLICT(cache_key) DO UPDATE SET response_json=excluded.response_json, created_at_ms=excluded.created_at_ms, expires_at_ms=excluded.expires_at_ms", .{ try sqlString(self.allocator, input.cache_key), try sqlJsonb(self.allocator, input.response_json), now, expires });
        try self.runSql(sql);
    }

    pub fn getResponseCache(self: *PostgresStore, allocator: std.mem.Allocator, cache_key: []const u8, now_ms: i64) !?ResponseCacheEntry {
        const inner = try std.fmt.allocPrint(allocator, "SELECT cache_key,response_json,created_at_ms,expires_at_ms FROM response_cache WHERE cache_key = {s} LIMIT 1", .{try sqlString(allocator, cache_key)});
        const parsed = try self.queryJson(allocator, try rowJsonSql(allocator, inner));
        defer parsed.deinit();
        if (parsed.value == .null) return null;
        const obj = parsed.value.object;
        const expires = json.intField(obj, "expires_at_ms") orelse 0;
        if (expires > 0 and expires <= now_ms) {
            try self.runSql(try std.fmt.allocPrint(allocator, "DELETE FROM response_cache WHERE cache_key = {s}", .{try sqlString(allocator, cache_key)}));
            return null;
        }
        return .{ .cache_key = try dupStringField(allocator, obj, "cache_key", ""), .response_json = try rawJsonField(allocator, obj, "response_json", "{}"), .created_at_ms = json.intField(obj, "created_at_ms") orelse 0, .expires_at_ms = expires };
    }

    pub fn putSemanticCache(self: *PostgresStore, input: SemanticCacheInput) !void {
        _ = try vector_mod.embeddingFromJson(self.allocator, input.embedding_json);
        const now = input.now_ms orelse ids.nowMs();
        const expires = if (input.ttl_ms > 0) now + input.ttl_ms else 0;
        const sql = try std.fmt.allocPrint(self.allocator, "INSERT INTO semantic_cache (cache_key,query,response_json,embedding_json,created_at_ms,expires_at_ms) VALUES ({s},{s},{s},{s},{d},{d}) ON CONFLICT(cache_key) DO UPDATE SET query=excluded.query, response_json=excluded.response_json, embedding_json=excluded.embedding_json, created_at_ms=excluded.created_at_ms, expires_at_ms=excluded.expires_at_ms", .{ try sqlString(self.allocator, input.cache_key), try sqlString(self.allocator, input.query), try sqlJsonb(self.allocator, input.response_json), try sqlJsonb(self.allocator, input.embedding_json), now, expires });
        try self.runSql(sql);
    }

    pub fn searchSemanticCache(self: *PostgresStore, allocator: std.mem.Allocator, input: SemanticCacheSearchInput) !?SemanticCacheMatch {
        const query = try vector_mod.embeddingFromJson(allocator, input.embedding_json);
        const now = input.now_ms orelse ids.nowMs();
        const parsed = try self.queryJson(allocator, try arrayJsonSql(allocator, "SELECT cache_key,query,response_json,embedding_json,created_at_ms,expires_at_ms FROM semantic_cache ORDER BY created_at_ms DESC LIMIT 1000"));
        defer parsed.deinit();
        var best: ?SemanticCacheMatch = null;
        var best_score = input.min_score;
        if (parsed.value == .array) for (parsed.value.array.items) |item| {
            if (item != .object) continue;
            const obj = item.object;
            const expires = json.intField(obj, "expires_at_ms") orelse 0;
            if (expires > 0 and expires <= now) continue;
            const embedding = vector_mod.embeddingFromJson(allocator, try rawJsonField(allocator, obj, "embedding_json", "[]")) catch continue;
            const score = vector_mod.cosine(query, embedding);
            if (score < best_score) continue;
            best_score = score;
            best = .{ .cache_key = try dupStringField(allocator, obj, "cache_key", ""), .query = try dupStringField(allocator, obj, "query", ""), .response_json = try rawJsonField(allocator, obj, "response_json", "{}"), .score = score, .created_at_ms = json.intField(obj, "created_at_ms") orelse 0, .expires_at_ms = expires };
        };
        return best;
    }

    pub fn runHygiene(self: *PostgresStore, input: HygieneRunInput) !HygieneRunResult {
        const now = input.now_ms orelse ids.nowMs();
        var result = HygieneRunResult{};
        const expired_sql = try std.fmt.allocPrint(self.allocator, "WITH r AS (DELETE FROM response_cache WHERE expires_at_ms > 0 AND expires_at_ms <= {d} RETURNING 1), s AS (DELETE FROM semantic_cache WHERE expires_at_ms > 0 AND expires_at_ms <= {d} RETURNING 1) SELECT ((SELECT count(*) FROM r) + (SELECT count(*) FROM s))::text", .{ now, now });
        const expired = try self.queryText(self.allocator, expired_sql);
        defer self.allocator.free(expired);
        result.expired_cache_entries = std.fmt.parseInt(usize, expired, 10) catch 0;

        const parsed = try self.queryJson(self.allocator, try arrayJsonSql(self.allocator, "SELECT id,status,last_verified_at_ms,created_at_ms FROM memory_atoms ORDER BY created_at_ms ASC LIMIT 5000"));
        defer parsed.deinit();
        if (parsed.value == .array) for (parsed.value.array.items) |item| {
            if (item != .object) continue;
            result.checked += 1;
            const obj = item.object;
            const status = json.stringField(obj, "status") orelse "proposed";
            const base_seen = json.intField(obj, "last_verified_at_ms") orelse (json.intField(obj, "created_at_ms") orelse now);
            const decision = lifecycle_mod.hygieneDecision(status, base_seen, now, input.stale_after_ms, input.archive_after_ms, input.purge_after_ms);
            const id_text = json.stringField(obj, "id") orelse continue;
            switch (decision) {
                .keep => {},
                .mark_stale => {
                    if (!std.mem.eql(u8, status, "stale") and try self.patchMemoryAtomStatus(id_text, "stale", false)) result.marked_stale += 1;
                },
                .archive => {
                    if (!std.mem.eql(u8, status, "deprecated") and try self.patchMemoryAtomStatus(id_text, "deprecated", false)) result.archived += 1;
                },
                .purge => if (input.hard_delete) {
                    if (try self.hardDeleteMemoryAtom(id_text)) result.purged += 1;
                } else {
                    if (!std.mem.eql(u8, status, "deprecated") and try self.patchMemoryAtomStatus(id_text, "deprecated", false)) result.archived += 1;
                },
            }
        };
        return result;
    }

    fn hardDeleteMemoryAtom(self: *PostgresStore, id_text: []const u8) !bool {
        const sql = try std.fmt.allocPrint(self.allocator, "WITH deleted AS (DELETE FROM memory_atoms WHERE id = {s} RETURNING 1) SELECT count(*)::text FROM deleted", .{try sqlString(self.allocator, id_text)});
        const text = try self.queryText(self.allocator, sql);
        defer self.allocator.free(text);
        return (std.fmt.parseInt(usize, text, 10) catch 0) > 0;
    }

    pub fn createContextPack(self: *PostgresStore, allocator: std.mem.Allocator, input: ContextPackInput) !ContextPackResult {
        const search_results = try self.search(allocator, .{ .query = input.query, .limit = 8, .scopes_json = input.scopes_json });
        const id = try ids.make(allocator, "ctx_");
        const now = ids.nowMs();
        const sources = try pgCollectResultIds(allocator, search_results, "source", true);
        const artifacts = try pgCollectResultIds(allocator, search_results, "artifact", false);
        const atoms = try pgCollectResultIds(allocator, search_results, "memory_atom", false);
        const summary = try pgBuildContextSummary(allocator, input.query, search_results);
        const sql = try std.fmt.allocPrint(allocator, "INSERT INTO context_packs (id,purpose,target,query_text,included_sources_json,included_artifacts_json,included_memory_atoms_json,generated_summary,token_budget,created_at_ms) VALUES ({s},{s},{s},{s},{s},{s},{s},{s},{d},{d})", .{ try sqlString(allocator, id), try sqlString(allocator, input.purpose), try sqlString(allocator, input.target), try sqlString(allocator, input.query), try sqlJsonb(allocator, sources), try sqlJsonb(allocator, artifacts), try sqlJsonb(allocator, atoms), try sqlString(allocator, summary), input.token_budget, now });
        try self.runSql(sql);
        return .{ .id = id, .purpose = input.purpose, .target = input.target, .query = input.query, .generated_summary = summary, .included_sources_json = sources, .included_artifacts_json = artifacts, .included_memory_atoms_json = atoms, .token_budget = input.token_budget, .created_at_ms = now };
    }

    pub fn compatStore(self: *PostgresStore, allocator: std.mem.Allocator, input: CompatStoreInput) !void {
        const atom = try self.createMemoryAtom(allocator, .{ .predicate = "compat.memory", .object = input.key, .text = input.content, .scope = "agent:nullclaw", .confidence = 0.75, .status = "verified", .created_by = "agent", .tags_json = "[\"nullclaw\"]" });
        _ = try self.compatDelete(input.key, input.session_id);
        const sql = try std.fmt.allocPrint(allocator, "INSERT INTO compat_memories (key,session_id,memory_atom_id,category,timestamp_ms) VALUES ({s},{s},{s},{s},{d})", .{ try sqlString(allocator, input.key), try sqlNullableString(allocator, input.session_id), try sqlString(allocator, atom.id), try sqlString(allocator, input.category), atom.created_at_ms });
        try self.runSql(sql);
    }

    pub fn compatGet(self: *PostgresStore, allocator: std.mem.Allocator, key: []const u8, session_id: ?[]const u8) !?domain.CompatMemory {
        const entries = try self.compatListInner(allocator, key, null, session_id, 1);
        if (entries.len == 0) return null;
        return entries[0];
    }

    pub fn compatList(self: *PostgresStore, allocator: std.mem.Allocator, category: ?[]const u8, session_id: ?[]const u8) ![]domain.CompatMemory {
        return self.compatListInner(allocator, null, category, session_id, 100);
    }

    fn compatListInner(self: *PostgresStore, allocator: std.mem.Allocator, key: ?[]const u8, category: ?[]const u8, session_id: ?[]const u8, limit: usize) ![]domain.CompatMemory {
        const session_filter = if (session_id) |sid| try std.fmt.allocPrint(allocator, "cm.session_id = {s}", .{try sqlString(allocator, sid)}) else "cm.session_id IS NULL";
        const key_filter = if (key) |k| try std.fmt.allocPrint(allocator, " AND cm.key = {s}", .{try sqlString(allocator, k)}) else "";
        const cat_filter = if (category) |cat| try std.fmt.allocPrint(allocator, " AND cm.category = {s}", .{try sqlString(allocator, cat)}) else "";
        const inner = try std.fmt.allocPrint(allocator, "SELECT ma.id,cm.key,ma.text AS content,cm.category,cm.timestamp_ms,cm.session_id,ma.confidence AS score FROM compat_memories cm JOIN memory_atoms ma ON ma.id = cm.memory_atom_id WHERE {s}{s}{s} ORDER BY cm.timestamp_ms DESC LIMIT {d}", .{ session_filter, key_filter, cat_filter, limit });
        const parsed = try self.queryJson(allocator, try arrayJsonSql(allocator, inner));
        defer parsed.deinit();
        var out: std.ArrayListUnmanaged(domain.CompatMemory) = .empty;
        if (parsed.value == .array) for (parsed.value.array.items) |item| {
            if (item != .object) continue;
            try out.append(allocator, try readPgCompatMemory(allocator, item.object));
        };
        return out.toOwnedSlice(allocator);
    }

    pub fn compatSearch(self: *PostgresStore, allocator: std.mem.Allocator, query: []const u8, limit: usize, session_id: ?[]const u8) ![]domain.CompatMemory {
        const all = try self.compatList(allocator, null, session_id);
        var out: std.ArrayListUnmanaged(domain.CompatMemory) = .empty;
        for (all) |entry| {
            if (pgScoreText(query, entry.key) <= 0 and pgScoreText(query, entry.content) <= 0) continue;
            var copy = entry;
            copy.score = pgScoreText(query, entry.content) + 0.5;
            try out.append(allocator, copy);
            if (out.items.len >= @max(@as(usize, 1), limit)) break;
        }
        return out.toOwnedSlice(allocator);
    }

    pub fn compatDelete(self: *PostgresStore, key: []const u8, session_id: ?[]const u8) !bool {
        const session_filter = if (session_id) |sid| try std.fmt.allocPrint(self.allocator, "session_id = {s}", .{try sqlString(self.allocator, sid)}) else "session_id IS NULL";
        const sql = try std.fmt.allocPrint(self.allocator, "WITH rows AS (DELETE FROM compat_memories WHERE key = {s} AND {s} RETURNING memory_atom_id), upd AS (UPDATE memory_atoms SET status='deprecated' WHERE id IN (SELECT memory_atom_id FROM rows) RETURNING 1) SELECT count(*)::text FROM rows", .{ try sqlString(self.allocator, key), session_filter });
        const text = try self.queryText(self.allocator, sql);
        defer self.allocator.free(text);
        return (std.fmt.parseInt(usize, text, 10) catch 0) > 0;
    }

    pub fn compatCount(self: *PostgresStore) !usize {
        const text = try self.queryText(self.allocator, "SELECT count(*)::text FROM compat_memories");
        defer self.allocator.free(text);
        return std.fmt.parseInt(usize, text, 10) catch 0;
    }

    pub fn saveMessage(self: *PostgresStore, session_id: []const u8, role: []const u8, content: []const u8) !void {
        const sql = try std.fmt.allocPrint(self.allocator, "INSERT INTO session_messages (session_id,role,content,created_at_ms) VALUES ({s},{s},{s},{d})", .{ try sqlString(self.allocator, session_id), try sqlString(self.allocator, role), try sqlString(self.allocator, content), ids.nowMs() });
        try self.runSql(sql);
    }

    pub fn loadMessages(self: *PostgresStore, allocator: std.mem.Allocator, session_id: []const u8) ![]Message {
        const inner = try std.fmt.allocPrint(allocator, "SELECT role,content,created_at_ms FROM session_messages WHERE session_id = {s} ORDER BY id ASC", .{try sqlString(allocator, session_id)});
        return try self.readMessagesArray(allocator, inner);
    }

    fn readMessagesArray(self: *PostgresStore, allocator: std.mem.Allocator, inner: []const u8) ![]Message {
        const parsed = try self.queryJson(allocator, try arrayJsonSql(allocator, inner));
        defer parsed.deinit();
        var out: std.ArrayListUnmanaged(Message) = .empty;
        if (parsed.value == .array) for (parsed.value.array.items) |item| {
            if (item != .object) continue;
            try out.append(allocator, .{ .role = try dupStringField(allocator, item.object, "role", ""), .content = try dupStringField(allocator, item.object, "content", ""), .created_at_ms = json.intField(item.object, "created_at_ms") orelse 0 });
        };
        return out.toOwnedSlice(allocator);
    }

    pub fn clearMessages(self: *PostgresStore, session_id: []const u8) !void {
        const sql = try std.fmt.allocPrint(self.allocator, "DELETE FROM session_messages WHERE session_id = {s}; DELETE FROM session_usage WHERE session_id = {s}", .{ try sqlString(self.allocator, session_id), try sqlString(self.allocator, session_id) });
        try self.runSql(sql);
    }

    pub fn clearAutoSaved(self: *PostgresStore, session_id: ?[]const u8) !void {
        const filter = if (session_id) |sid| try std.fmt.allocPrint(self.allocator, "session_id = {s} AND ", .{try sqlString(self.allocator, sid)}) else "";
        const sql = try std.fmt.allocPrint(self.allocator, "DELETE FROM session_messages WHERE {s}(role = 'autosave_user' OR role = 'autosave_assistant')", .{filter});
        try self.runSql(sql);
    }

    pub fn saveUsage(self: *PostgresStore, session_id: []const u8, total_tokens: u64) !void {
        const sql = try std.fmt.allocPrint(self.allocator, "INSERT INTO session_usage (session_id,total_tokens,updated_at_ms) VALUES ({s},{d},{d}) ON CONFLICT(session_id) DO UPDATE SET total_tokens=excluded.total_tokens, updated_at_ms=excluded.updated_at_ms", .{ try sqlString(self.allocator, session_id), total_tokens, ids.nowMs() });
        try self.runSql(sql);
    }

    pub fn deleteUsage(self: *PostgresStore, session_id: []const u8) !bool {
        const sql = try std.fmt.allocPrint(self.allocator, "WITH deleted AS (DELETE FROM session_usage WHERE session_id = {s} RETURNING 1) SELECT count(*)::text FROM deleted", .{try sqlString(self.allocator, session_id)});
        const text = try self.queryText(self.allocator, sql);
        defer self.allocator.free(text);
        return (std.fmt.parseInt(usize, text, 10) catch 0) > 0;
    }

    pub fn loadUsage(self: *PostgresStore, session_id: []const u8) !?u64 {
        const sql = try std.fmt.allocPrint(self.allocator, "SELECT coalesce((SELECT total_tokens::text FROM session_usage WHERE session_id = {s} LIMIT 1), '')", .{try sqlString(self.allocator, session_id)});
        const text = try self.queryText(self.allocator, sql);
        defer self.allocator.free(text);
        if (text.len == 0) return null;
        return std.fmt.parseInt(u64, text, 10) catch null;
    }

    pub fn listSessions(self: *PostgresStore, allocator: std.mem.Allocator, limit: usize, offset: usize) !HistoryList {
        const total_text = try self.queryText(allocator, "SELECT count(*)::text FROM (SELECT session_id FROM session_messages GROUP BY session_id) s");
        const total = std.fmt.parseInt(u64, total_text, 10) catch 0;
        const inner = try std.fmt.allocPrint(allocator, "SELECT session_id, count(*) AS message_count, min(created_at_ms) AS first_message_at, max(created_at_ms) AS last_message_at FROM session_messages GROUP BY session_id ORDER BY max(created_at_ms) DESC LIMIT {d} OFFSET {d}", .{ limit, offset });
        const parsed = try self.queryJson(allocator, try arrayJsonSql(allocator, inner));
        defer parsed.deinit();
        var sessions: std.ArrayListUnmanaged(SessionInfo) = .empty;
        if (parsed.value == .array) for (parsed.value.array.items) |item| {
            if (item != .object) continue;
            try sessions.append(allocator, .{ .session_id = try dupStringField(allocator, item.object, "session_id", ""), .message_count = @intCast(json.intField(item.object, "message_count") orelse 0), .first_message_at = json.intField(item.object, "first_message_at") orelse 0, .last_message_at = json.intField(item.object, "last_message_at") orelse 0 });
        };
        return .{ .total = total, .sessions = try sessions.toOwnedSlice(allocator) };
    }

    pub fn history(self: *PostgresStore, allocator: std.mem.Allocator, session_id: []const u8, limit: usize, offset: usize) !HistoryShow {
        const count_sql = try std.fmt.allocPrint(allocator, "SELECT count(*)::text FROM session_messages WHERE session_id = {s}", .{try sqlString(allocator, session_id)});
        const count_text = try self.queryText(allocator, count_sql);
        const inner = try std.fmt.allocPrint(allocator, "SELECT role,content,created_at_ms FROM session_messages WHERE session_id = {s} ORDER BY id ASC LIMIT {d} OFFSET {d}", .{ try sqlString(allocator, session_id), limit, offset });
        return .{ .total = std.fmt.parseInt(u64, count_text, 10) catch 0, .messages = try self.readMessagesArray(allocator, inner) };
    }

    pub fn createJob(self: *PostgresStore, allocator: std.mem.Allocator, input: JobInput) !Job {
        const id = try ids.make(allocator, "job_");
        const now = ids.nowMs();
        const sql = try std.fmt.allocPrint(allocator, "INSERT INTO jobs (id,job_type,status,scope,object_type,object_id,input_json,result_json,error_text,attempts,created_at_ms,updated_at_ms) VALUES ({s},{s},'queued',{s},{s},{s},{s},'{{}}'::jsonb,NULL,0,{d},{d})", .{ try sqlString(allocator, id), try sqlString(allocator, input.job_type), try sqlString(allocator, input.scope), try sqlString(allocator, input.object_type), try sqlString(allocator, input.object_id), try sqlJsonb(allocator, input.input_json), now, now });
        try self.runSql(sql);
        return .{ .id = id, .job_type = input.job_type, .status = "queued", .scope = input.scope, .object_type = input.object_type, .object_id = input.object_id, .input_json = input.input_json, .result_json = "{}", .error_text = null, .attempts = 0, .created_at_ms = now, .updated_at_ms = now };
    }

    pub fn getJob(self: *PostgresStore, allocator: std.mem.Allocator, id: []const u8) !?Job {
        const inner = try std.fmt.allocPrint(allocator, "SELECT id,job_type,status,scope,object_type,object_id,input_json,result_json,error_text,attempts,created_at_ms,updated_at_ms FROM jobs WHERE id = {s} LIMIT 1", .{try sqlString(allocator, id)});
        const parsed = try self.queryJson(allocator, try rowJsonSql(allocator, inner));
        defer parsed.deinit();
        if (parsed.value == .null) return null;
        return try readPgJob(allocator, parsed.value.object);
    }

    pub fn listJobs(self: *PostgresStore, allocator: std.mem.Allocator, input: JobListInput) ![]Job {
        const status_filter = if (input.status) |status| try std.fmt.allocPrint(allocator, "WHERE status = {s}", .{try sqlString(allocator, status)}) else "";
        const inner = try std.fmt.allocPrint(allocator, "SELECT id,job_type,status,scope,object_type,object_id,input_json,result_json,error_text,attempts,created_at_ms,updated_at_ms FROM jobs {s} ORDER BY created_at_ms DESC LIMIT {d}", .{ status_filter, @max(@as(usize, 1), @min(input.limit, 500)) });
        const parsed = try self.queryJson(allocator, try arrayJsonSql(allocator, inner));
        defer parsed.deinit();
        var out: std.ArrayListUnmanaged(Job) = .empty;
        if (parsed.value == .array) for (parsed.value.array.items) |item| {
            if (item != .object) continue;
            const job = try readPgJob(allocator, item.object);
            if (!domain.scopeVisible(job.scope, input.scopes_json)) continue;
            try out.append(allocator, job);
        };
        return out.toOwnedSlice(allocator);
    }

    pub fn finishJob(self: *PostgresStore, id: []const u8, status: []const u8, result_json: []const u8, error_text: ?[]const u8) !bool {
        const sql = try std.fmt.allocPrint(self.allocator, "WITH updated AS (UPDATE jobs SET status = {s}, result_json = {s}, error_text = {s}, attempts = attempts + 1, updated_at_ms = {d} WHERE id = {s} RETURNING 1) SELECT count(*)::text FROM updated", .{ try sqlString(self.allocator, status), try sqlJsonb(self.allocator, result_json), try sqlNullableString(self.allocator, error_text), ids.nowMs(), try sqlString(self.allocator, id) });
        const text = try self.queryText(self.allocator, sql);
        defer self.allocator.free(text);
        return (std.fmt.parseInt(usize, text, 10) catch 0) > 0;
    }

    pub fn listConflicts(self: *PostgresStore, allocator: std.mem.Allocator, input: ConflictListInput) ![]KnowledgeConflict {
        const status_filter = if (input.status) |status| try std.fmt.allocPrint(allocator, "WHERE status = {s}", .{try sqlString(allocator, status)}) else "";
        const inner = try std.fmt.allocPrint(allocator, "SELECT id,conflict_type,object_a_type,object_a_id,object_b_type,object_b_id,scope,status,summary,created_at_ms,resolved_at_ms FROM knowledge_conflicts {s} ORDER BY created_at_ms DESC LIMIT {d}", .{ status_filter, @max(@as(usize, 1), @min(input.limit, 500)) });
        const parsed = try self.queryJson(allocator, try arrayJsonSql(allocator, inner));
        defer parsed.deinit();
        var out: std.ArrayListUnmanaged(KnowledgeConflict) = .empty;
        if (parsed.value == .array) for (parsed.value.array.items) |item| {
            if (item != .object) continue;
            const conflict = try readPgConflict(allocator, item.object);
            if (!domain.scopeVisible(conflict.scope, input.scopes_json)) continue;
            try out.append(allocator, conflict);
        };
        return out.toOwnedSlice(allocator);
    }

    pub fn scanConflicts(self: *PostgresStore, allocator: std.mem.Allocator, input: ConflictListInput) ![]KnowledgeConflict {
        const parsed = try self.queryJson(allocator, try arrayJsonSql(allocator, "SELECT id,subject_entity_id,predicate,object,text,scope,confidence,status,source_ids_json,evidence_ranges_json,created_by,created_at_ms,valid_from_ms,valid_until_ms,last_verified_at_ms,owner,permissions_json,tags_json FROM memory_atoms ORDER BY created_at_ms DESC LIMIT 1000"));
        defer parsed.deinit();
        var atoms: std.ArrayListUnmanaged(domain.MemoryAtom) = .empty;
        if (parsed.value == .array) for (parsed.value.array.items) |item| {
            if (item != .object) continue;
            const atom = try readPgMemoryAtom(allocator, item.object);
            if (!domain.recordVisible(atom.scope, atom.permissions_json, input.scopes_json)) continue;
            try atoms.append(allocator, atom);
        };
        for (atoms.items, 0..) |a, i| {
            if (!domain.isDefaultVisibleStatus(a.status)) continue;
            for (atoms.items[i + 1 ..]) |b| {
                if (!domain.isDefaultVisibleStatus(b.status)) continue;
                if (!pgSameConflictSubject(a, b)) continue;
                if (std.mem.eql(u8, a.object, b.object)) continue;
                try self.insertPgConflict(allocator, a, b);
            }
        }
        return try self.listConflicts(allocator, input);
    }

    fn searchPgMemoryAtoms(self: *PostgresStore, allocator: std.mem.Allocator, input: SearchInput, results: *std.ArrayListUnmanaged(domain.SearchResult)) !void {
        const parsed = try self.queryJson(allocator, try arrayJsonSql(allocator, "SELECT id,subject_entity_id,predicate,object,text,scope,confidence,status,source_ids_json,evidence_ranges_json,created_by,created_at_ms,valid_from_ms,valid_until_ms,last_verified_at_ms,owner,permissions_json,tags_json FROM memory_atoms ORDER BY created_at_ms DESC LIMIT 1000"));
        defer parsed.deinit();
        if (parsed.value != .array) return;
        for (parsed.value.array.items) |item| {
            if (item != .object) continue;
            const atom = try readPgMemoryAtom(allocator, item.object);
            if (!input.include_deprecated and !domain.isDefaultVisibleStatus(atom.status)) continue;
            if (!domain.recordVisible(atom.scope, atom.permissions_json, input.scopes_json)) continue;
            const relevance = pgScoreText(input.query, atom.text) + pgScoreText(input.query, atom.predicate) + pgScoreText(input.query, atom.object);
            if (relevance <= 0 and input.query.len > 0) continue;
            try results.append(allocator, .{ .id = atom.id, .result_type = "memory_atom", .title = atom.id, .text = atom.text, .scope = atom.scope, .status = atom.status, .score = relevance + atom.confidence, .source_ids_json = try self.sanitizeSourceIds(allocator, atom.source_ids_json, input.scopes_json) });
        }
    }

    fn searchPgSources(self: *PostgresStore, allocator: std.mem.Allocator, input: SearchInput, results: *std.ArrayListUnmanaged(domain.SearchResult)) !void {
        const parsed = try self.queryJson(allocator, try arrayJsonSql(allocator, "SELECT id,type,title,raw_content_uri,content,author,participants_json,permissions_json,scope,created_at_ms,imported_at_ms,checksum,language,related_entities_json,metadata_json FROM sources ORDER BY imported_at_ms DESC LIMIT 500"));
        defer parsed.deinit();
        if (parsed.value != .array) return;
        for (parsed.value.array.items) |item| {
            if (item != .object) continue;
            const source = try readPgSource(allocator, item.object);
            if (!domain.recordVisible(source.scope, source.permissions_json, input.scopes_json)) continue;
            const relevance = pgScoreText(input.query, source.title) + pgScoreText(input.query, source.content);
            if (relevance <= 0 and input.query.len > 0) continue;
            try results.append(allocator, .{ .id = source.id, .result_type = "source", .title = source.title, .text = source.content, .scope = source.scope, .status = "active", .score = relevance, .source_ids_json = try std.fmt.allocPrint(allocator, "[\"{s}\"]", .{source.id}) });
        }
    }

    fn searchPgArtifacts(self: *PostgresStore, allocator: std.mem.Allocator, input: SearchInput, results: *std.ArrayListUnmanaged(domain.SearchResult)) !void {
        const parsed = try self.queryJson(allocator, try arrayJsonSql(allocator, "SELECT id,type,title,body,status,owner,space_id,version,created_at_ms,updated_at_ms,last_verified_at_ms,source_ids_json,related_entities_json,permissions_json,summary,agent_summary FROM artifacts ORDER BY updated_at_ms DESC LIMIT 500"));
        defer parsed.deinit();
        if (parsed.value != .array) return;
        for (parsed.value.array.items) |item| {
            if (item != .object) continue;
            const artifact = try readPgArtifact(allocator, item.object);
            if (!input.include_deprecated and !domain.isDefaultVisibleStatus(artifact.status)) continue;
            if (!domain.permissionsVisible(artifact.permissions_json, input.scopes_json)) continue;
            const relevance = pgScoreText(input.query, artifact.title) + pgScoreText(input.query, artifact.body);
            if (relevance <= 0 and input.query.len > 0) continue;
            try results.append(allocator, .{ .id = artifact.id, .result_type = "artifact", .title = artifact.title, .text = artifact.body, .scope = "artifact", .status = artifact.status, .score = relevance, .source_ids_json = try self.sanitizeSourceIds(allocator, artifact.source_ids_json, input.scopes_json) });
        }
    }

    fn searchPgEntities(self: *PostgresStore, allocator: std.mem.Allocator, input: SearchInput, results: *std.ArrayListUnmanaged(domain.SearchResult)) !void {
        const parsed = try self.queryJson(allocator, try arrayJsonSql(allocator, "SELECT id,type,name,aliases_json,description,canonical_artifact_id,metadata_json,created_at_ms,updated_at_ms FROM entities ORDER BY updated_at_ms DESC LIMIT 500"));
        defer parsed.deinit();
        if (parsed.value != .array) return;
        for (parsed.value.array.items) |item| {
            if (item != .object) continue;
            const entity = try readPgEntity(allocator, item.object);
            const text = entity.description orelse entity.name;
            const relevance = pgScoreText(input.query, entity.name) + pgScoreText(input.query, entity.aliases_json) + pgScoreText(input.query, text);
            if (relevance <= 0 and input.query.len > 0) continue;
            try results.append(allocator, .{ .id = entity.id, .result_type = "entity", .title = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ entity.entity_type, entity.name }), .text = text, .scope = "entity", .status = "active", .score = relevance + 0.25, .source_ids_json = "[]" });
        }
    }

    fn searchPgRelations(self: *PostgresStore, allocator: std.mem.Allocator, input: SearchInput, results: *std.ArrayListUnmanaged(domain.SearchResult)) !void {
        const inner = "SELECT r.id,r.from_entity_id,r.relation_type,r.to_entity_id,r.source_ids_json,r.confidence,r.status,r.created_at_ms,coalesce(fe.name,'') AS from_name,coalesce(te.name,'') AS to_name FROM relations r LEFT JOIN entities fe ON fe.id = r.from_entity_id LEFT JOIN entities te ON te.id = r.to_entity_id ORDER BY r.created_at_ms DESC LIMIT 500";
        const parsed = try self.queryJson(allocator, try arrayJsonSql(allocator, inner));
        defer parsed.deinit();
        if (parsed.value != .array) return;
        for (parsed.value.array.items) |item| {
            if (item != .object) continue;
            const obj = item.object;
            const status = try dupStringField(allocator, obj, "status", "proposed");
            if (!input.include_deprecated and !domain.isDefaultVisibleStatus(status)) continue;
            const relation_type = try dupStringField(allocator, obj, "relation_type", "");
            const text = try std.fmt.allocPrint(allocator, "{s} {s} {s}", .{ json.stringField(obj, "from_name") orelse "", relation_type, json.stringField(obj, "to_name") orelse "" });
            const relevance = pgScoreText(input.query, text) + pgScoreText(input.query, relation_type);
            if (relevance <= 0 and input.query.len > 0) continue;
            try results.append(allocator, .{ .id = try dupStringField(allocator, obj, "id", ""), .result_type = "relation", .title = relation_type, .text = text, .scope = "graph", .status = status, .score = relevance + (json.floatField(obj, "confidence") orelse 0.5), .source_ids_json = try self.sanitizeSourceIds(allocator, try rawJsonField(allocator, obj, "source_ids_json", "[]"), input.scopes_json) });
        }
    }

    fn searchPgContextPacks(self: *PostgresStore, allocator: std.mem.Allocator, input: SearchInput, results: *std.ArrayListUnmanaged(domain.SearchResult)) !void {
        const parsed = try self.queryJson(allocator, try arrayJsonSql(allocator, "SELECT id,purpose,target,query_text,included_sources_json,included_artifacts_json,included_memory_atoms_json,generated_summary,token_budget,created_at_ms FROM context_packs ORDER BY created_at_ms DESC LIMIT 500"));
        defer parsed.deinit();
        if (parsed.value != .array) return;
        for (parsed.value.array.items) |item| {
            if (item != .object) continue;
            const obj = item.object;
            const source_ids = try rawJsonField(allocator, obj, "included_sources_json", "[]");
            if (!try self.contextPackVisible(allocator, source_ids, try rawJsonField(allocator, obj, "included_artifacts_json", "[]"), try rawJsonField(allocator, obj, "included_memory_atoms_json", "[]"), input.scopes_json)) continue;
            const query_text = try dupStringField(allocator, obj, "query_text", "");
            const summary = try dupStringField(allocator, obj, "generated_summary", "");
            const purpose = try dupStringField(allocator, obj, "purpose", "");
            const relevance = pgScoreText(input.query, query_text) + pgScoreText(input.query, summary) + pgScoreText(input.query, purpose);
            if (relevance <= 0 and input.query.len > 0) continue;
            try results.append(allocator, .{ .id = try dupStringField(allocator, obj, "id", ""), .result_type = "context_pack", .title = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ purpose, json.stringField(obj, "target") orelse "" }), .text = summary, .scope = "context", .status = "active", .score = relevance + 0.4, .source_ids_json = try self.sanitizeSourceIds(allocator, source_ids, input.scopes_json) });
        }
    }

    fn searchPgFeedEvents(self: *PostgresStore, allocator: std.mem.Allocator, input: SearchInput, results: *std.ArrayListUnmanaged(domain.SearchResult)) !void {
        const events = try self.listFeedEvents(allocator, .{ .scopes_json = input.scopes_json, .limit = 500 });
        for (events) |event| {
            if (!input.include_deprecated and std.mem.eql(u8, event.status, "rejected")) continue;
            const text = try std.fmt.allocPrint(allocator, "{s} {s} {s} {s}", .{ event.event_type, event.object_type, event.object_id, event.payload_json });
            const relevance = pgScoreText(input.query, text);
            if (relevance <= 0 and input.query.len > 0) continue;
            try results.append(allocator, .{ .id = try std.fmt.allocPrint(allocator, "feed_{d}", .{event.id}), .result_type = "feed_event", .title = event.event_type, .text = text, .scope = event.scope, .status = event.status, .score = relevance + 0.2, .source_ids_json = "[]" });
        }
    }

    fn searchPgCompat(self: *PostgresStore, allocator: std.mem.Allocator, input: SearchInput, results: *std.ArrayListUnmanaged(domain.SearchResult)) !void {
        const inner = "SELECT cm.key,cm.category,cm.session_id,ma.id,ma.text,ma.scope,ma.status,ma.confidence,ma.source_ids_json,ma.permissions_json FROM compat_memories cm JOIN memory_atoms ma ON ma.id = cm.memory_atom_id ORDER BY cm.timestamp_ms DESC LIMIT 500";
        const parsed = try self.queryJson(allocator, try arrayJsonSql(allocator, inner));
        defer parsed.deinit();
        if (parsed.value != .array) return;
        for (parsed.value.array.items) |item| {
            if (item != .object) continue;
            const obj = item.object;
            const status = try dupStringField(allocator, obj, "status", "verified");
            const scope = try dupStringField(allocator, obj, "scope", "agent:nullclaw");
            const permissions = try rawJsonField(allocator, obj, "permissions_json", "[]");
            if (!input.include_deprecated and !domain.isDefaultVisibleStatus(status)) continue;
            if (!domain.recordVisible(scope, permissions, input.scopes_json)) continue;
            const text = try std.fmt.allocPrint(allocator, "{s} {s} {s}", .{ json.stringField(obj, "key") orelse "", json.stringField(obj, "category") orelse "", json.stringField(obj, "text") orelse "" });
            const relevance = pgScoreText(input.query, text);
            if (relevance <= 0 and input.query.len > 0) continue;
            try results.append(allocator, .{ .id = try std.fmt.allocPrint(allocator, "compat:{s}:{s}", .{ json.stringField(obj, "session_id") orelse "global", json.stringField(obj, "key") orelse "" }), .result_type = "compat_memory", .title = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ json.stringField(obj, "category") orelse "", json.stringField(obj, "key") orelse "" }), .text = text, .scope = scope, .status = status, .score = relevance + (json.floatField(obj, "confidence") orelse 0.5), .source_ids_json = try self.sanitizeSourceIds(allocator, try rawJsonField(allocator, obj, "source_ids_json", "[]"), input.scopes_json) });
        }
    }

    fn searchPgSessions(self: *PostgresStore, allocator: std.mem.Allocator, input: SearchInput, results: *std.ArrayListUnmanaged(domain.SearchResult)) !void {
        const parsed = try self.queryJson(allocator, try arrayJsonSql(allocator, "SELECT id,session_id,role,content,created_at_ms FROM session_messages ORDER BY id DESC LIMIT 500"));
        defer parsed.deinit();
        if (parsed.value != .array) return;
        for (parsed.value.array.items) |item| {
            if (item != .object) continue;
            const text = try dupStringField(allocator, item.object, "content", "");
            const relevance = pgScoreText(input.query, text) + pgScoreText(input.query, json.stringField(item.object, "session_id") orelse "") + pgScoreText(input.query, json.stringField(item.object, "role") orelse "");
            if (relevance <= 0 and input.query.len > 0) continue;
            try results.append(allocator, .{ .id = try std.fmt.allocPrint(allocator, "session_msg_{d}", .{json.intField(item.object, "id") orelse 0}), .result_type = "session_message", .title = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ json.stringField(item.object, "session_id") orelse "", json.stringField(item.object, "role") orelse "" }), .text = text, .scope = "agent:nullclaw", .status = "active", .score = relevance + 0.1, .source_ids_json = "[]" });
        }
    }

    fn searchPgVectorCandidates(self: *PostgresStore, allocator: std.mem.Allocator, input: SearchInput, results: *std.ArrayListUnmanaged(domain.SearchResult)) !void {
        const embedding = try vector_mod.deterministicEmbedding(allocator, input.query, 64);
        const matches = try self.vectorSearch(allocator, .{ .embedding_json = try vector_mod.embeddingToJson(allocator, embedding), .scopes_json = input.scopes_json, .limit = @max(@as(usize, 20), input.limit) });
        for (matches) |match| {
            if (try self.searchResultForVectorMatch(allocator, match, input)) |result| try results.append(allocator, result);
        }
    }

    fn searchResultForVectorMatch(self: *PostgresStore, allocator: std.mem.Allocator, match: vector_mod.VectorMatch, input: SearchInput) !?domain.SearchResult {
        if (std.mem.eql(u8, match.object_type, "memory_atom")) {
            const atom = (try self.getMemoryAtom(allocator, match.object_id)) orelse return null;
            if (!input.include_deprecated and !domain.isDefaultVisibleStatus(atom.status)) return null;
            if (!domain.recordVisible(atom.scope, atom.permissions_json, input.scopes_json)) return null;
            return .{ .id = atom.id, .result_type = "memory_atom", .title = atom.id, .text = atom.text, .scope = atom.scope, .status = atom.status, .score = match.score + atom.confidence, .source_ids_json = try self.sanitizeSourceIds(allocator, atom.source_ids_json, input.scopes_json) };
        }
        if (std.mem.eql(u8, match.object_type, "source")) {
            const source = (try self.getSource(allocator, match.object_id)) orelse return null;
            if (!domain.recordVisible(source.scope, source.permissions_json, input.scopes_json)) return null;
            return .{ .id = source.id, .result_type = "source", .title = source.title, .text = source.content, .scope = source.scope, .status = "active", .score = match.score, .source_ids_json = try std.fmt.allocPrint(allocator, "[\"{s}\"]", .{source.id}) };
        }
        if (std.mem.eql(u8, match.object_type, "artifact")) {
            const artifact = (try self.getArtifact(allocator, match.object_id)) orelse return null;
            if (!domain.permissionsVisible(artifact.permissions_json, input.scopes_json)) return null;
            return .{ .id = artifact.id, .result_type = "artifact", .title = artifact.title, .text = artifact.body, .scope = "artifact", .status = artifact.status, .score = match.score, .source_ids_json = try self.sanitizeSourceIds(allocator, artifact.source_ids_json, input.scopes_json) };
        }
        return .{ .id = match.object_id, .result_type = match.object_type, .title = match.object_id, .text = match.text, .scope = match.scope, .status = "active", .score = match.score, .source_ids_json = "[]" };
    }

    fn sanitizeSourceIds(self: *PostgresStore, allocator: std.mem.Allocator, source_ids_json: []const u8, scopes_json: []const u8) ![]const u8 {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, source_ids_json, .{}) catch return allocator.dupe(u8, "[]");
        defer parsed.deinit();
        if (parsed.value != .array) return allocator.dupe(u8, "[]");
        var out: std.ArrayListUnmanaged(u8) = .empty;
        try out.append(allocator, '[');
        var first = true;
        for (parsed.value.array.items) |item| {
            const source_id = switch (item) {
                .string => |s| s,
                else => continue,
            };
            const source = (try self.getSource(allocator, source_id)) orelse continue;
            if (!domain.recordVisible(source.scope, source.permissions_json, scopes_json)) continue;
            if (!first) try out.append(allocator, ',');
            first = false;
            try json.appendString(&out, allocator, source_id);
        }
        try out.append(allocator, ']');
        return out.toOwnedSlice(allocator);
    }

    fn contextPackVisible(self: *PostgresStore, allocator: std.mem.Allocator, sources_json: []const u8, artifacts_json: []const u8, atoms_json: []const u8, scopes_json: []const u8) !bool {
        return try self.allPgSourcesVisible(allocator, sources_json, scopes_json) and try self.allPgArtifactsVisible(allocator, artifacts_json, scopes_json) and try self.allPgAtomsVisible(allocator, atoms_json, scopes_json);
    }

    fn allPgSourcesVisible(self: *PostgresStore, allocator: std.mem.Allocator, ids_json: []const u8, scopes_json: []const u8) !bool {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, ids_json, .{}) catch return false;
        defer parsed.deinit();
        if (parsed.value != .array) return false;
        for (parsed.value.array.items) |item| {
            if (item != .string) return false;
            const source = (try self.getSource(allocator, item.string)) orelse return false;
            if (!domain.recordVisible(source.scope, source.permissions_json, scopes_json)) return false;
        }
        return true;
    }

    fn allPgArtifactsVisible(self: *PostgresStore, allocator: std.mem.Allocator, ids_json: []const u8, scopes_json: []const u8) !bool {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, ids_json, .{}) catch return false;
        defer parsed.deinit();
        if (parsed.value != .array) return false;
        for (parsed.value.array.items) |item| {
            if (item != .string) return false;
            const artifact = (try self.getArtifact(allocator, item.string)) orelse return false;
            if (!domain.permissionsVisible(artifact.permissions_json, scopes_json)) return false;
        }
        return true;
    }

    fn allPgAtomsVisible(self: *PostgresStore, allocator: std.mem.Allocator, ids_json: []const u8, scopes_json: []const u8) !bool {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, ids_json, .{}) catch return false;
        defer parsed.deinit();
        if (parsed.value != .array) return false;
        for (parsed.value.array.items) |item| {
            if (item != .string) return false;
            const atom = (try self.getMemoryAtom(allocator, item.string)) orelse return false;
            if (!domain.recordVisible(atom.scope, atom.permissions_json, scopes_json)) return false;
        }
        return true;
    }

    fn insertPgConflict(self: *PostgresStore, allocator: std.mem.Allocator, a: domain.MemoryAtom, b: domain.MemoryAtom) !void {
        const a_id = if (std.mem.lessThan(u8, a.id, b.id)) a.id else b.id;
        const b_id = if (std.mem.lessThan(u8, a.id, b.id)) b.id else a.id;
        const summary = try std.fmt.allocPrint(allocator, "Potential conflicting {s}: {s} vs {s}", .{ a.predicate, a.object, b.object });
        const id = try ids.make(allocator, "cnf_");
        const sql = try std.fmt.allocPrint(allocator, "INSERT INTO knowledge_conflicts (id,conflict_type,object_a_type,object_a_id,object_b_type,object_b_id,scope,status,summary,created_at_ms,resolved_at_ms) VALUES ({s},'memory_atom_conflict','memory_atom',{s},'memory_atom',{s},{s},'open',{s},{d},NULL) ON CONFLICT(conflict_type,object_a_id,object_b_id) DO NOTHING", .{ try sqlString(allocator, id), try sqlString(allocator, a_id), try sqlString(allocator, b_id), try sqlString(allocator, a.scope), try sqlString(allocator, summary), ids.nowMs() });
        try self.runSql(sql);
    }
};

fn dupStringField(allocator: std.mem.Allocator, obj: std.json.ObjectMap, name: []const u8, fallback: []const u8) ![]u8 {
    return allocator.dupe(u8, json.stringField(obj, name) orelse fallback);
}

fn dupNullableStringField(allocator: std.mem.Allocator, obj: std.json.ObjectMap, name: []const u8) !?[]u8 {
    const value = obj.get(name) orelse return null;
    return switch (value) {
        .string => |s| try allocator.dupe(u8, s),
        .null => null,
        else => null,
    };
}

fn rawJsonField(allocator: std.mem.Allocator, obj: std.json.ObjectMap, name: []const u8, fallback: []const u8) ![]u8 {
    const value = obj.get(name) orelse return allocator.dupe(u8, fallback);
    if (value == .null) return allocator.dupe(u8, fallback);
    return try json.jsonFromValue(allocator, value);
}

fn optionalIntField(obj: std.json.ObjectMap, name: []const u8) ?i64 {
    const value = obj.get(name) orelse return null;
    if (value == .null) return null;
    return json.intField(obj, name);
}

fn readPgSource(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !domain.Source {
    return .{
        .id = try dupStringField(allocator, obj, "id", ""),
        .source_type = try dupStringField(allocator, obj, "type", "manual"),
        .title = try dupStringField(allocator, obj, "title", ""),
        .raw_content_uri = try dupNullableStringField(allocator, obj, "raw_content_uri"),
        .content = try dupStringField(allocator, obj, "content", ""),
        .author = try dupNullableStringField(allocator, obj, "author"),
        .participants_json = try rawJsonField(allocator, obj, "participants_json", "[]"),
        .permissions_json = try rawJsonField(allocator, obj, "permissions_json", "[]"),
        .scope = try dupStringField(allocator, obj, "scope", "workspace"),
        .created_at_ms = json.intField(obj, "created_at_ms") orelse 0,
        .imported_at_ms = json.intField(obj, "imported_at_ms") orelse 0,
        .checksum = try dupNullableStringField(allocator, obj, "checksum"),
        .language = try dupNullableStringField(allocator, obj, "language"),
        .related_entities_json = try rawJsonField(allocator, obj, "related_entities_json", "[]"),
        .metadata_json = try rawJsonField(allocator, obj, "metadata_json", "{}"),
    };
}

fn readPgArtifact(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !domain.Artifact {
    return .{
        .id = try dupStringField(allocator, obj, "id", ""),
        .artifact_type = try dupStringField(allocator, obj, "type", "page"),
        .title = try dupStringField(allocator, obj, "title", ""),
        .body = try dupStringField(allocator, obj, "body", ""),
        .status = try dupStringField(allocator, obj, "status", "draft"),
        .owner = try dupNullableStringField(allocator, obj, "owner"),
        .space_id = try dupNullableStringField(allocator, obj, "space_id"),
        .version = json.intField(obj, "version") orelse 1,
        .created_at_ms = json.intField(obj, "created_at_ms") orelse 0,
        .updated_at_ms = json.intField(obj, "updated_at_ms") orelse 0,
        .last_verified_at_ms = optionalIntField(obj, "last_verified_at_ms"),
        .source_ids_json = try rawJsonField(allocator, obj, "source_ids_json", "[]"),
        .related_entities_json = try rawJsonField(allocator, obj, "related_entities_json", "[]"),
        .permissions_json = try rawJsonField(allocator, obj, "permissions_json", "[]"),
        .summary = try dupNullableStringField(allocator, obj, "summary"),
        .agent_summary = try dupNullableStringField(allocator, obj, "agent_summary"),
    };
}

fn readPgEntity(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !domain.Entity {
    return .{
        .id = try dupStringField(allocator, obj, "id", ""),
        .entity_type = try dupStringField(allocator, obj, "type", "concept"),
        .name = try dupStringField(allocator, obj, "name", ""),
        .aliases_json = try rawJsonField(allocator, obj, "aliases_json", "[]"),
        .description = try dupNullableStringField(allocator, obj, "description"),
        .canonical_artifact_id = try dupNullableStringField(allocator, obj, "canonical_artifact_id"),
        .metadata_json = try rawJsonField(allocator, obj, "metadata_json", "{}"),
        .created_at_ms = json.intField(obj, "created_at_ms") orelse 0,
        .updated_at_ms = json.intField(obj, "updated_at_ms") orelse 0,
    };
}

fn readPgMemoryAtom(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !domain.MemoryAtom {
    return .{
        .id = try dupStringField(allocator, obj, "id", ""),
        .subject_entity_id = try dupNullableStringField(allocator, obj, "subject_entity_id"),
        .predicate = try dupStringField(allocator, obj, "predicate", "states"),
        .object = try dupStringField(allocator, obj, "object", ""),
        .text = try dupStringField(allocator, obj, "text", ""),
        .scope = try dupStringField(allocator, obj, "scope", "workspace"),
        .confidence = json.floatField(obj, "confidence") orelse 0.5,
        .status = try dupStringField(allocator, obj, "status", "proposed"),
        .source_ids_json = try rawJsonField(allocator, obj, "source_ids_json", "[]"),
        .evidence_ranges_json = try rawJsonField(allocator, obj, "evidence_ranges_json", "[]"),
        .created_by = try dupStringField(allocator, obj, "created_by", "human"),
        .created_at_ms = json.intField(obj, "created_at_ms") orelse 0,
        .valid_from_ms = optionalIntField(obj, "valid_from_ms"),
        .valid_until_ms = optionalIntField(obj, "valid_until_ms"),
        .last_verified_at_ms = optionalIntField(obj, "last_verified_at_ms"),
        .owner = try dupNullableStringField(allocator, obj, "owner"),
        .permissions_json = try rawJsonField(allocator, obj, "permissions_json", "[]"),
        .tags_json = try rawJsonField(allocator, obj, "tags_json", "[]"),
    };
}

fn readPgFeedEvent(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !FeedEvent {
    return .{
        .id = json.intField(obj, "id") orelse 0,
        .event_type = try dupStringField(allocator, obj, "event_type", ""),
        .object_type = try dupStringField(allocator, obj, "object_type", ""),
        .object_id = try dupStringField(allocator, obj, "object_id", ""),
        .scope = try dupStringField(allocator, obj, "scope", "workspace"),
        .dedupe_key = try dupNullableStringField(allocator, obj, "dedupe_key"),
        .payload_json = try rawJsonField(allocator, obj, "payload_json", "{}"),
        .status = try dupStringField(allocator, obj, "status", "pending"),
        .created_at_ms = json.intField(obj, "created_at_ms") orelse 0,
        .applied_at_ms = optionalIntField(obj, "applied_at_ms"),
    };
}

fn readPgCompatMemory(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !domain.CompatMemory {
    return .{
        .id = try dupStringField(allocator, obj, "id", ""),
        .key = try dupStringField(allocator, obj, "key", ""),
        .content = try dupStringField(allocator, obj, "content", ""),
        .category = try dupStringField(allocator, obj, "category", "core"),
        .timestamp = try std.fmt.allocPrint(allocator, "{d}", .{json.intField(obj, "timestamp_ms") orelse 0}),
        .session_id = try dupNullableStringField(allocator, obj, "session_id"),
        .score = json.floatField(obj, "score"),
    };
}

fn readPgJob(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !Job {
    return .{
        .id = try dupStringField(allocator, obj, "id", ""),
        .job_type = try dupStringField(allocator, obj, "job_type", ""),
        .status = try dupStringField(allocator, obj, "status", "queued"),
        .scope = try dupStringField(allocator, obj, "scope", "workspace"),
        .object_type = try dupStringField(allocator, obj, "object_type", ""),
        .object_id = try dupStringField(allocator, obj, "object_id", ""),
        .input_json = try rawJsonField(allocator, obj, "input_json", "{}"),
        .result_json = try rawJsonField(allocator, obj, "result_json", "{}"),
        .error_text = try dupNullableStringField(allocator, obj, "error_text"),
        .attempts = json.intField(obj, "attempts") orelse 0,
        .created_at_ms = json.intField(obj, "created_at_ms") orelse 0,
        .updated_at_ms = json.intField(obj, "updated_at_ms") orelse 0,
    };
}

fn readPgConflict(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !KnowledgeConflict {
    return .{
        .id = try dupStringField(allocator, obj, "id", ""),
        .conflict_type = try dupStringField(allocator, obj, "conflict_type", ""),
        .object_a_type = try dupStringField(allocator, obj, "object_a_type", ""),
        .object_a_id = try dupStringField(allocator, obj, "object_a_id", ""),
        .object_b_type = try dupStringField(allocator, obj, "object_b_type", ""),
        .object_b_id = try dupStringField(allocator, obj, "object_b_id", ""),
        .scope = try dupStringField(allocator, obj, "scope", "workspace"),
        .status = try dupStringField(allocator, obj, "status", "open"),
        .summary = try dupStringField(allocator, obj, "summary", ""),
        .created_at_ms = json.intField(obj, "created_at_ms") orelse 0,
        .resolved_at_ms = optionalIntField(obj, "resolved_at_ms"),
    };
}

fn pgScoreText(query: []const u8, text: []const u8) f64 {
    if (query.len == 0) return 1.0;
    var score: f64 = 0.0;
    var it = std.mem.tokenizeAny(u8, query, " \t\r\n.,;:/\\-_*\"'");
    while (it.next()) |token| {
        if (token.len == 0) continue;
        if (std.ascii.indexOfIgnoreCase(text, token) != null) score += 1.0;
    }
    return score;
}

fn pgSortSearchResults(items: []domain.SearchResult) void {
    var i: usize = 0;
    while (i < items.len) : (i += 1) {
        var best = i;
        var j = i + 1;
        while (j < items.len) : (j += 1) {
            if (items[j].score > items[best].score) best = j;
        }
        if (best != i) std.mem.swap(domain.SearchResult, &items[i], &items[best]);
    }
}

fn pgCollectResultIds(allocator: std.mem.Allocator, results: []const domain.SearchResult, result_type: []const u8, collect_citations: bool) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.append(allocator, '[');
    var count: usize = 0;
    for (results) |result| {
        if (collect_citations) {
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, result.source_ids_json, .{}) catch continue;
            defer parsed.deinit();
            if (parsed.value != .array) continue;
            for (parsed.value.array.items) |item| {
                if (item != .string) continue;
                try appendUniqueJsonStringGlobal(allocator, &out, &count, item.string);
            }
        } else if (std.mem.eql(u8, result.result_type, result_type)) {
            try appendUniqueJsonStringGlobal(allocator, &out, &count, result.id);
        }
    }
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

fn appendUniqueJsonStringGlobal(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), count: *usize, value: []const u8) !void {
    const needle = try std.fmt.allocPrint(allocator, "\"{s}\"", .{value});
    if (std.mem.indexOf(u8, out.items, needle) != null) return;
    if (count.* > 0) try out.append(allocator, ',');
    try json.appendString(out, allocator, value);
    count.* += 1;
}

fn pgBuildContextSummary(allocator: std.mem.Allocator, query: []const u8, results: []const domain.SearchResult) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.appendSlice(allocator, "Context Pack\n\nTask:\n");
    try out.appendSlice(allocator, query);
    try out.appendSlice(allocator, "\n\nMemory atoms:\n");
    var count: usize = 0;
    for (results) |result| {
        if (!std.mem.eql(u8, result.result_type, "memory_atom")) continue;
        try out.appendSlice(allocator, "- ");
        try out.appendSlice(allocator, result.text);
        try out.append(allocator, '\n');
        count += 1;
    }
    if (count == 0) try out.appendSlice(allocator, "- None found.\n");
    try out.appendSlice(allocator, "\nArtifacts and sources:\n");
    count = 0;
    for (results) |result| {
        if (!std.mem.eql(u8, result.result_type, "artifact") and !std.mem.eql(u8, result.result_type, "source")) continue;
        try out.appendSlice(allocator, "- ");
        try out.appendSlice(allocator, result.title);
        try out.append(allocator, '\n');
        count += 1;
    }
    if (count == 0) try out.appendSlice(allocator, "- None found.\n");
    return out.toOwnedSlice(allocator);
}

fn pgSameConflictSubject(a: domain.MemoryAtom, b: domain.MemoryAtom) bool {
    if (!std.mem.eql(u8, a.scope, b.scope)) return false;
    if (!std.mem.eql(u8, a.predicate, b.predicate)) return false;
    if (a.subject_entity_id != null and b.subject_entity_id != null) return std.mem.eql(u8, a.subject_entity_id.?, b.subject_entity_id.?);
    return true;
}

fn testingSqliteCount(store: *Store, sql: [*:0]const u8) !i64 {
    return switch (store.backend) {
        .sqlite => |*s| s.countSql(sql),
        .postgres => error.UnsupportedBackend,
    };
}

test "sqlite storage creates and searches memory atoms" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const atom = try store.createMemoryAtom(alloc, .{
        .text = "NullPantry prepares trusted context for agents.",
        .scope = "project:nullpantry",
        .created_by = "agent",
        .source_ids_json = "[\"src_test\"]",
    });
    try std.testing.expectEqualStrings("proposed", atom.status);

    const results = try store.search(alloc, .{
        .query = "trusted context",
        .scopes_json = "[\"project:nullpantry\"]",
        .limit = 5,
    });
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings(atom.id, results[0].id);
}

test "sqlite storage contract covers primitives lifecycle and audit events" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = try store.createSource(alloc, .{
        .source_type = "transcript",
        .title = "Planning transcript",
        .content = "Release checklist discussion",
        .scope = "project:nullpantry",
        .permissions_json = "[\"project:nullpantry\"]",
    });
    const loaded_source = (try store.getSource(alloc, source.id)).?;
    try std.testing.expectEqualStrings(source.id, loaded_source.id);
    try std.testing.expectEqualStrings("transcript", loaded_source.source_type);

    const artifact = try store.createArtifact(alloc, .{
        .artifact_type = "decision",
        .title = "Use Memory Atoms",
        .body = "Decision: keep memory atom as core primitive.",
        .status = "accepted",
        .source_ids_json = "[\"src_test\"]",
        .permissions_json = "[\"project:nullpantry\"]",
    });
    const loaded_artifact = (try store.getArtifact(alloc, artifact.id)).?;
    try std.testing.expectEqualStrings("accepted", loaded_artifact.status);

    const from = try store.resolveEntity(alloc, .{ .entity_type = "project", .name = "NullPantry" });
    const to = try store.resolveEntity(alloc, .{ .entity_type = "service", .name = "NullClaw" });
    const relation = try store.createRelation(alloc, .{
        .from_entity_id = from.id,
        .relation_type = "serves_context_to",
        .to_entity_id = to.id,
        .confidence = 0.91,
    });
    try std.testing.expectEqualStrings(from.id, relation.from_entity_id);
    try std.testing.expectEqualStrings(to.id, relation.to_entity_id);

    const atom = try store.createMemoryAtom(alloc, .{
        .text = "Release runbook is owned by NullPantry.",
        .scope = "project:nullpantry",
        .created_by = "human",
        .source_ids_json = "[\"src_test\"]",
        .permissions_json = "[\"project:nullpantry\"]",
    });
    try std.testing.expectEqualStrings("verified", atom.status);
    try std.testing.expect(try store.patchMemoryAtomStatus(atom.id, "stale", false));
    const stale = (try store.getMemoryAtom(alloc, atom.id)).?;
    try std.testing.expectEqualStrings("stale", stale.status);
    try std.testing.expect(try store.patchMemoryAtomStatus(atom.id, "verified", true));
    const verified = (try store.getMemoryAtom(alloc, atom.id)).?;
    try std.testing.expect(verified.last_verified_at_ms != null);

    try std.testing.expect((try testingSqliteCount(&store, "SELECT COUNT(*) FROM audit_events")) >= 7);
    try std.testing.expect((try testingSqliteCount(&store, "SELECT COUNT(*) FROM schema_migrations WHERE version IN (1,2,3,4)")) == 4);
}

test "sqlite search excludes deprecated and superseded memory by default" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const deprecated = try store.createMemoryAtom(alloc, .{
        .text = "Deprecated pantry decision",
        .scope = "project:nullpantry",
        .created_by = "human",
    });
    const superseded = try store.createMemoryAtom(alloc, .{
        .text = "Superseded pantry decision",
        .scope = "project:nullpantry",
        .created_by = "human",
    });
    const fresh = try store.createMemoryAtom(alloc, .{
        .text = "Current pantry decision",
        .scope = "project:nullpantry",
        .created_by = "human",
    });

    try std.testing.expect(try store.patchMemoryAtomStatus(deprecated.id, "deprecated", false));
    try std.testing.expect(try store.patchMemoryAtomStatus(superseded.id, "superseded", false));

    const default_results = try store.search(alloc, .{
        .query = "pantry decision",
        .scopes_json = "[\"project:nullpantry\"]",
        .limit = 10,
    });
    try std.testing.expectEqual(@as(usize, 1), default_results.len);
    try std.testing.expectEqualStrings(fresh.id, default_results[0].id);

    const all_results = try store.search(alloc, .{
        .query = "pantry decision",
        .scopes_json = "[\"project:nullpantry\"]",
        .limit = 10,
        .include_deprecated = true,
    });
    try std.testing.expectEqual(@as(usize, 3), all_results.len);
}

test "sqlite vector layer stores chunks searches and enqueues outbox" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const a_json = try vector_mod.embeddingToJson(alloc, &[_]f32{ 1, 0, 0 });
    const b_json = try vector_mod.embeddingToJson(alloc, &[_]f32{ 0, 1, 0 });
    _ = try store.upsertVectorChunk(alloc, .{ .object_id = "mem_a", .text = "agent memory", .scope = "project:nullpantry", .embedding_json = a_json, .dimensions = 3 });
    _ = try store.upsertVectorChunk(alloc, .{ .object_id = "mem_b", .text = "other memory", .scope = "project:nullpantry", .embedding_json = b_json, .dimensions = 3 });

    try std.testing.expectEqual(@as(usize, 2), try store.countVectorOutbox("pending"));
    const results = try store.vectorSearch(alloc, .{ .embedding_json = a_json, .scopes_json = "[\"project:nullpantry\"]", .limit = 2 });
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("vec_mem_a_0", results[0].id);
}

test "sqlite vector search filters permissions" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const embedding = try vector_mod.embeddingToJson(alloc, &[_]f32{ 1, 0 });
    _ = try store.upsertVectorChunk(alloc, .{ .object_id = "mem_public", .text = "public vector", .scope = "public", .embedding_json = embedding, .dimensions = 2 });
    _ = try store.upsertVectorChunk(alloc, .{ .object_id = "mem_secret", .text = "secret vector", .scope = "project:secret", .permissions_json = "[\"project:secret\"]", .embedding_json = embedding, .dimensions = 2 });

    const public_results = try store.vectorSearch(alloc, .{ .embedding_json = embedding, .scopes_json = "[\"public\"]", .limit = 10 });
    try std.testing.expectEqual(@as(usize, 1), public_results.len);
    try std.testing.expectEqualStrings("vec_mem_public_0", public_results[0].id);

    const admin_results = try store.vectorSearch(alloc, .{ .embedding_json = embedding, .scopes_json = "[\"admin\"]", .limit = 10 });
    try std.testing.expectEqual(@as(usize, 2), admin_results.len);
}

test "sqlite global search covers primitives and sanitizes inaccessible citations" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const public_source = try store.createSource(alloc, .{ .title = "Public transcript", .content = "shared roadmap pantry", .scope = "public" });
    const secret_source = try store.createSource(alloc, .{ .title = "Secret transcript", .content = "hidden roadmap pantry", .scope = "project:secret", .permissions_json = "[\"project:secret\"]" });
    _ = try store.createArtifact(alloc, .{ .title = "Roadmap artifact", .body = "artifact pantry roadmap", .status = "accepted" });
    _ = try store.createMemoryAtom(alloc, .{
        .text = "roadmap atom",
        .scope = "public",
        .created_by = "human",
        .source_ids_json = try std.fmt.allocPrint(alloc, "[\"{s}\",\"{s}\"]", .{ public_source.id, secret_source.id }),
    });

    const results = try store.search(alloc, .{ .query = "roadmap", .scopes_json = "[\"public\"]", .limit = 20 });
    var saw_source = false;
    var saw_artifact = false;
    var saw_atom = false;
    for (results) |result| {
        if (std.mem.eql(u8, result.result_type, "source")) saw_source = true;
        if (std.mem.eql(u8, result.result_type, "artifact")) saw_artifact = true;
        if (std.mem.eql(u8, result.result_type, "memory_atom")) {
            saw_atom = true;
            try std.testing.expect(std.mem.indexOf(u8, result.source_ids_json, public_source.id) != null);
            try std.testing.expect(std.mem.indexOf(u8, result.source_ids_json, secret_source.id) == null);
        }
        try std.testing.expect(std.mem.indexOf(u8, result.text, "hidden roadmap pantry") == null);
    }
    try std.testing.expect(saw_source);
    try std.testing.expect(saw_artifact);
    try std.testing.expect(saw_atom);
}

test "sqlite global search covers operational first-class groups" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = try store.createSource(alloc, .{ .title = "Roadmap transcript", .content = "roadmap source", .scope = "public" });
    const artifact = try store.createArtifact(alloc, .{ .title = "Roadmap artifact", .body = "roadmap artifact", .status = "accepted" });
    const atom = try store.createMemoryAtom(alloc, .{
        .text = "roadmap atom",
        .scope = "public",
        .created_by = "human",
        .source_ids_json = try std.fmt.allocPrint(alloc, "[\"{s}\"]", .{source.id}),
    });
    const from = try store.resolveEntity(alloc, .{ .entity_type = "project", .name = "RoadmapProject" });
    const to = try store.resolveEntity(alloc, .{ .entity_type = "service", .name = "RoadmapService" });
    _ = try store.createRelation(alloc, .{ .from_entity_id = from.id, .relation_type = "roadmap_depends_on", .to_entity_id = to.id });
    _ = try store.createContextPack(alloc, .{ .query = "roadmap", .scopes_json = "[\"admin\"]" });
    _ = try store.appendFeedEvent(.{ .event_type = "roadmap.feed", .object_type = "memory_atom", .object_id = atom.id, .scope = "public", .payload_json = "{\"text\":\"roadmap feed\"}" });
    try store.compatStore(alloc, .{ .key = "roadmap.compat", .content = "roadmap compat memory", .category = "core", .session_id = null });
    try store.saveMessage("sess_roadmap", "user", "roadmap session message");
    _ = artifact;

    const results = try store.search(alloc, .{ .query = "roadmap", .scopes_json = "[\"admin\"]", .limit = 100, .include_sessions = true });
    var saw_relation = false;
    var saw_context_pack = false;
    var saw_feed = false;
    var saw_compat = false;
    var saw_session = false;
    for (results) |result| {
        if (std.mem.eql(u8, result.result_type, "relation")) saw_relation = true;
        if (std.mem.eql(u8, result.result_type, "context_pack")) saw_context_pack = true;
        if (std.mem.eql(u8, result.result_type, "feed_event")) saw_feed = true;
        if (std.mem.eql(u8, result.result_type, "compat_memory")) saw_compat = true;
        if (std.mem.eql(u8, result.result_type, "session_message")) saw_session = true;
    }
    try std.testing.expect(saw_relation);
    try std.testing.expect(saw_context_pack);
    try std.testing.expect(saw_feed);
    try std.testing.expect(saw_compat);
    try std.testing.expect(saw_session);

    const public_results = try store.search(alloc, .{ .query = "roadmap session", .scopes_json = "[\"public\"]", .limit = 20, .include_sessions = true });
    for (public_results) |result| {
        try std.testing.expect(!std.mem.eql(u8, result.result_type, "session_message"));
    }
}

test "sqlite memory feed append list and apply events are scope filtered" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const public_id = try store.appendFeedEvent(.{
        .event_type = "memory_atom.upsert",
        .object_type = "memory_atom",
        .object_id = "mem_public",
        .scope = "public",
        .payload_json = "{\"text\":\"public\"}",
    });
    _ = public_id;
    _ = try store.appendFeedEvent(.{
        .event_type = "memory_atom.upsert",
        .object_type = "memory_atom",
        .object_id = "mem_secret",
        .scope = "project:secret",
        .payload_json = "{\"text\":\"secret\"}",
        .status = "applied",
    });

    const visible = try store.listFeedEvents(alloc, .{ .scopes_json = "[\"public\"]", .limit = 10 });
    try std.testing.expectEqual(@as(usize, 1), visible.len);
    try std.testing.expectEqualStrings("mem_public", visible[0].object_id);
    try std.testing.expectEqualStrings("pending", visible[0].status);
    try std.testing.expect(visible[0].applied_at_ms == null);

    const all = try store.listFeedEvents(alloc, .{ .scopes_json = "[\"admin\"]", .limit = 10 });
    try std.testing.expectEqual(@as(usize, 2), all.len);
    try std.testing.expect(all[1].applied_at_ms != null);
}

test "sqlite memory feed dedupe key is idempotent" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();

    const first = try store.appendFeedEvent(.{ .event_type = "memory_atom.upsert", .object_type = "memory_atom", .object_id = "mem_a", .scope = "public", .dedupe_key = "evt-1", .payload_json = "{\"text\":\"one\"}" });
    const second = try store.appendFeedEvent(.{ .event_type = "memory_atom.upsert", .object_type = "memory_atom", .object_id = "mem_b", .scope = "public", .dedupe_key = "evt-1", .payload_json = "{\"text\":\"two\"}" });
    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(@as(i64, 1), try testingSqliteCount(&store, "SELECT COUNT(*) FROM memory_feed_events"));
}

test "sqlite lifecycle snapshots are persisted and audited" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const snapshot = try store.createLifecycleSnapshot(alloc, "manual", "{\"memory_atoms\":0}");
    try std.testing.expect(std.mem.startsWith(u8, snapshot.id, "snap_"));
    try std.testing.expect((try testingSqliteCount(&store, "SELECT COUNT(*) FROM lifecycle_snapshots")) == 1);
    try std.testing.expect((try testingSqliteCount(&store, "SELECT COUNT(*) FROM audit_events WHERE event_type = 'lifecycle.snapshot'")) == 1);
}

test "sqlite lifecycle diagnostics reads real counts" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const atom = try store.createMemoryAtom(alloc, .{ .text = "diagnostic memory", .scope = "public", .created_by = "human" });
    try std.testing.expect(try store.patchMemoryAtomStatus(atom.id, "stale", false));
    _ = try store.enqueueVectorOutbox(.{ .action = "upsert", .object_type = "memory_atom", .object_id = atom.id });

    const diag = try store.lifecycleDiagnostics();
    try std.testing.expectEqual(@as(usize, 1), diag.total_memory_atoms);
    try std.testing.expectEqual(@as(usize, 1), diag.stale_memory_atoms);
    try std.testing.expectEqual(@as(usize, 1), diag.vector_outbox_pending);
}

test "sqlite lifecycle cache semantic cache and hygiene are persistent" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try store.putResponseCache(.{ .cache_key = "prompt:a", .response_json = "{\"answer\":\"cached\"}", .ttl_ms = 1000, .now_ms = 100 });
    const cache_hit = (try store.getResponseCache(alloc, "prompt:a", 200)).?;
    try std.testing.expectEqualStrings("{\"answer\":\"cached\"}", cache_hit.response_json);
    try std.testing.expect((try store.getResponseCache(alloc, "prompt:a", 1200)) == null);

    const embedding = try vector_mod.embeddingToJson(alloc, &[_]f32{ 1, 0 });
    try store.putSemanticCache(.{ .cache_key = "semantic:a", .query = "release", .response_json = "{\"answer\":\"semantic\"}", .embedding_json = embedding, .ttl_ms = 1000, .now_ms = 100 });
    const semantic_hit = (try store.searchSemanticCache(alloc, .{ .embedding_json = embedding, .min_score = 0.9, .now_ms = 200 })).?;
    try std.testing.expectEqualStrings("semantic:a", semantic_hit.cache_key);

    const atom = try store.createMemoryAtom(alloc, .{ .text = "old memory", .scope = "public", .created_by = "human" });
    const hygiene = try store.runHygiene(.{
        .stale_after_ms = 1,
        .archive_after_ms = 10,
        .purge_after_ms = 0,
        .now_ms = atom.created_at_ms + 2,
    });
    try std.testing.expectEqual(@as(usize, 1), hygiene.checked);
    try std.testing.expectEqual(@as(usize, 1), hygiene.marked_stale);
    const stale = (try store.getMemoryAtom(alloc, atom.id)).?;
    try std.testing.expectEqualStrings("stale", stale.status);
}

test "nullclaw compatibility maps key memory to memory atom" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try store.compatStore(alloc, .{ .key = "pref.lang", .content = "Use Zig examples", .category = "core", .session_id = null });
    const entry = (try store.compatGet(alloc, "pref.lang", null)).?;
    try std.testing.expectEqualStrings("pref.lang", entry.key);
    try std.testing.expectEqualStrings("Use Zig examples", entry.content);
    try std.testing.expectEqual(@as(usize, 1), try store.compatCount());
}

test "nullclaw compatibility upsert preserves scoped memories" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try store.compatStore(alloc, .{ .key = "pref.lang", .content = "Session value", .category = "core", .session_id = "agent:coder" });
    try store.compatStore(alloc, .{ .key = "pref.lang", .content = "Global value", .category = "core", .session_id = null });

    const scoped = (try store.compatGet(alloc, "pref.lang", "agent:coder")).?;
    try std.testing.expectEqualStrings("Session value", scoped.content);
    const global = (try store.compatGet(alloc, "pref.lang", null)).?;
    try std.testing.expectEqualStrings("Global value", global.content);
    try std.testing.expectEqual(@as(usize, 2), try store.compatCount());
}

test "nullclaw compatibility scoped delete preserves global memory and deprecates deleted atom" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try store.compatStore(alloc, .{ .key = "pref.lang", .content = "Global value", .category = "core", .session_id = null });
    try store.compatStore(alloc, .{ .key = "pref.lang", .content = "Session value", .category = "core", .session_id = "agent:coder" });
    const scoped = (try store.compatGet(alloc, "pref.lang", "agent:coder")).?;

    try std.testing.expect(try store.compatDelete("pref.lang", "agent:coder"));
    try std.testing.expect((try store.compatGet(alloc, "pref.lang", "agent:coder")) == null);
    const global = (try store.compatGet(alloc, "pref.lang", null)).?;
    try std.testing.expectEqualStrings("Global value", global.content);
    try std.testing.expectEqual(@as(usize, 1), try store.compatCount());

    const deleted_atom = (try store.getMemoryAtom(alloc, scoped.id)).?;
    try std.testing.expectEqualStrings("deprecated", deleted_atom.status);
}

test "sqlite session store clears only autosaved messages in requested session" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try store.saveMessage("sess_a", "autosave_user", "draft A");
    try store.saveMessage("sess_a", "user", "kept A");
    try store.saveMessage("sess_b", "autosave_user", "draft B");

    try store.clearAutoSaved("sess_a");

    const a = try store.loadMessages(alloc, "sess_a");
    try std.testing.expectEqual(@as(usize, 1), a.len);
    try std.testing.expectEqualStrings("user", a[0].role);
    try std.testing.expectEqualStrings("kept A", a[0].content);

    const b = try store.loadMessages(alloc, "sess_b");
    try std.testing.expectEqual(@as(usize, 1), b.len);
    try std.testing.expectEqualStrings("autosave_user", b[0].role);
}

test "sqlite session usage delete removes usage record" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();

    try store.saveUsage("sess_usage", 77);
    try std.testing.expectEqual(@as(?u64, 77), try store.loadUsage("sess_usage"));
    try std.testing.expect(try store.deleteUsage("sess_usage"));
    try std.testing.expect((try store.loadUsage("sess_usage")) == null);
    try std.testing.expect(!try store.deleteUsage("sess_usage"));
}

test "sqlite jobs persist status transitions with scoped listing" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const job = try store.createJob(alloc, .{ .job_type = "ingest", .scope = "project:nullpantry", .input_json = "{\"title\":\"x\"}" });
    try std.testing.expectEqualStrings("queued", job.status);
    try std.testing.expect(try store.finishJob(job.id, "succeeded", "{\"ok\":true}", null));
    const loaded = (try store.getJob(alloc, job.id)).?;
    try std.testing.expectEqualStrings("succeeded", loaded.status);
    try std.testing.expectEqual(@as(i64, 1), loaded.attempts);

    const visible = try store.listJobs(alloc, .{ .scopes_json = "[\"project:nullpantry\"]", .status = "succeeded" });
    try std.testing.expectEqual(@as(usize, 1), visible.len);
    const hidden = try store.listJobs(alloc, .{ .scopes_json = "[\"public\"]", .status = "succeeded" });
    try std.testing.expectEqual(@as(usize, 0), hidden.len);
}

test "sqlite conflict scan records only visible contradictory atoms" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    _ = try store.createMemoryAtom(alloc, .{ .predicate = "decision.database", .object = "sqlite", .text = "Database is SQLite", .scope = "project:nullpantry", .created_by = "human" });
    _ = try store.createMemoryAtom(alloc, .{ .predicate = "decision.database", .object = "postgres", .text = "Database is Postgres", .scope = "project:nullpantry", .created_by = "human" });
    _ = try store.createMemoryAtom(alloc, .{ .predicate = "decision.database", .object = "secret", .text = "Secret database", .scope = "project:secret", .created_by = "human" });

    const conflicts = try store.scanConflicts(alloc, .{ .scopes_json = "[\"project:nullpantry\"]", .limit = 20 });
    try std.testing.expectEqual(@as(usize, 1), conflicts.len);
    try std.testing.expect(std.mem.indexOf(u8, conflicts[0].summary, "sqlite") != null);
    try std.testing.expect(std.mem.indexOf(u8, conflicts[0].summary, "postgres") != null);
    try std.testing.expect(std.mem.indexOf(u8, conflicts[0].summary, "secret") == null);
}

test "relation creation requires existing entities" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const a = try store.resolveEntity(alloc, .{ .name = "NullPantry", .entity_type = "project" });
    try std.testing.expectError(error.EntityNotFound, store.createRelation(alloc, .{ .from_entity_id = a.id, .to_entity_id = "ent_missing", .relation_type = "depends_on" }));
}

test "context pack excludes inaccessible scopes" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    _ = try store.createMemoryAtom(alloc, .{ .text = "Secret architecture detail", .scope = "secret:nullpantry", .created_by = "human" });
    _ = try store.createMemoryAtom(alloc, .{ .text = "Public architecture note", .scope = "public", .created_by = "human" });
    const pack = try store.createContextPack(alloc, .{ .query = "architecture", .scopes_json = "[]" });
    try std.testing.expect(std.mem.indexOf(u8, pack.generated_summary, "Public architecture note") != null);
    try std.testing.expect(std.mem.indexOf(u8, pack.generated_summary, "Secret architecture detail") == null);
}

test "context pack includes sanitized citations from memory atoms" {
    var store = try Store.initSQLite(std.testing.allocator, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const public_source = try store.createSource(alloc, .{ .title = "Public decision source", .content = "citation source", .scope = "public" });
    const secret_source = try store.createSource(alloc, .{ .title = "Secret decision source", .content = "secret citation", .scope = "project:secret", .permissions_json = "[\"project:secret\"]" });
    _ = try store.createMemoryAtom(alloc, .{
        .text = "Decision: context packs must cite accessible sources.",
        .scope = "public",
        .created_by = "human",
        .source_ids_json = try std.fmt.allocPrint(alloc, "[\"{s}\",\"{s}\"]", .{ public_source.id, secret_source.id }),
    });

    const pack = try store.createContextPack(alloc, .{ .query = "context packs cite", .scopes_json = "[\"public\"]" });
    try std.testing.expect(std.mem.indexOf(u8, pack.included_sources_json, public_source.id) != null);
    try std.testing.expect(std.mem.indexOf(u8, pack.included_sources_json, secret_source.id) == null);
    try std.testing.expect(std.mem.indexOf(u8, pack.generated_summary, "Citations:") != null);
    try std.testing.expect(std.mem.indexOf(u8, pack.generated_summary, public_source.id) != null);
    try std.testing.expect(std.mem.indexOf(u8, pack.generated_summary, secret_source.id) == null);
}
