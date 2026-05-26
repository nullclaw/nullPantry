const std = @import("std");
const ids = @import("ids.zig");
const domain = @import("domain.zig");
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
        _ = allocator;
        _ = url;
        return error.PostgresAdapterIncomplete;
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

    pub fn init(allocator: std.mem.Allocator, url: []const u8) !PostgresStore {
        const owned = try allocator.dupe(u8, url);
        var self = PostgresStore{ .allocator = allocator, .url = owned };
        try self.runSql(migrations.postgres_schema);
        return self;
    }

    pub fn deinit(self: *PostgresStore) void {
        self.allocator.free(self.url);
    }

    pub fn health(self: *PostgresStore) bool {
        self.runSql("SELECT 1;") catch return false;
        return true;
    }

    fn runSql(self: *PostgresStore, sql: []const u8) !void {
        const argv = [_][]const u8{ "psql", self.url, "-v", "ON_ERROR_STOP=1", "-q", "-c", sql };
        var child = try std.process.spawn(compat.io(), .{
            .argv = &argv,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });
        const term = try child.wait(compat.io());
        switch (term) {
            .exited => |code| if (code != 0) return error.PostgresCommandFailed,
            else => return error.PostgresCommandFailed,
        }
    }

    pub fn createSource(_: *PostgresStore, _: std.mem.Allocator, _: SourceInput) !domain.Source {
        return error.PostgresAdapterIncomplete;
    }
    pub fn getSource(_: *PostgresStore, _: std.mem.Allocator, _: []const u8) !?domain.Source {
        return error.PostgresAdapterIncomplete;
    }
    pub fn createArtifact(_: *PostgresStore, _: std.mem.Allocator, _: ArtifactInput) !domain.Artifact {
        return error.PostgresAdapterIncomplete;
    }
    pub fn getArtifact(_: *PostgresStore, _: std.mem.Allocator, _: []const u8) !?domain.Artifact {
        return error.PostgresAdapterIncomplete;
    }
    pub fn resolveEntity(_: *PostgresStore, _: std.mem.Allocator, _: EntityInput) !domain.Entity {
        return error.PostgresAdapterIncomplete;
    }
    pub fn createRelation(_: *PostgresStore, _: std.mem.Allocator, _: RelationInput) !domain.Relation {
        return error.PostgresAdapterIncomplete;
    }
    pub fn createMemoryAtom(_: *PostgresStore, _: std.mem.Allocator, _: MemoryAtomInput) !domain.MemoryAtom {
        return error.PostgresAdapterIncomplete;
    }
    pub fn getMemoryAtom(_: *PostgresStore, _: std.mem.Allocator, _: []const u8) !?domain.MemoryAtom {
        return error.PostgresAdapterIncomplete;
    }
    pub fn patchMemoryAtomStatus(_: *PostgresStore, _: []const u8, _: []const u8, _: bool) !bool {
        return error.PostgresAdapterIncomplete;
    }
    pub fn search(_: *PostgresStore, _: std.mem.Allocator, _: SearchInput) ![]domain.SearchResult {
        return error.PostgresAdapterIncomplete;
    }
    pub fn upsertVectorChunk(_: *PostgresStore, _: std.mem.Allocator, _: VectorChunkInput) !VectorChunk {
        return error.PostgresAdapterIncomplete;
    }
    pub fn vectorSearch(_: *PostgresStore, allocator: std.mem.Allocator, _: VectorSearchInput) ![]vector_mod.VectorMatch {
        return allocator.alloc(vector_mod.VectorMatch, 0);
    }
    pub fn enqueueVectorOutbox(_: *PostgresStore, _: VectorOutboxInput) !i64 {
        return error.PostgresAdapterIncomplete;
    }
    pub fn countVectorOutbox(_: *PostgresStore, _: ?[]const u8) !usize {
        return error.PostgresAdapterIncomplete;
    }
    pub fn appendFeedEvent(_: *PostgresStore, _: FeedEventInput) !i64 {
        return error.PostgresAdapterIncomplete;
    }
    pub fn listFeedEvents(_: *PostgresStore, allocator: std.mem.Allocator, _: FeedListInput) ![]FeedEvent {
        return allocator.alloc(FeedEvent, 0);
    }
    pub fn getFeedEventByDedupeKey(_: *PostgresStore, _: std.mem.Allocator, _: []const u8) !?FeedEvent {
        return error.PostgresAdapterIncomplete;
    }
    pub fn createLifecycleSnapshot(_: *PostgresStore, _: std.mem.Allocator, _: []const u8, _: []const u8) !LifecycleSnapshot {
        return error.PostgresAdapterIncomplete;
    }
    pub fn lifecycleDiagnostics(_: *PostgresStore) !LifecycleDiagnostics {
        return error.PostgresAdapterIncomplete;
    }
    pub fn putResponseCache(_: *PostgresStore, _: ResponseCacheInput) !void {
        return error.PostgresAdapterIncomplete;
    }
    pub fn getResponseCache(_: *PostgresStore, _: std.mem.Allocator, _: []const u8, _: i64) !?ResponseCacheEntry {
        return error.PostgresAdapterIncomplete;
    }
    pub fn putSemanticCache(_: *PostgresStore, _: SemanticCacheInput) !void {
        return error.PostgresAdapterIncomplete;
    }
    pub fn searchSemanticCache(_: *PostgresStore, _: std.mem.Allocator, _: SemanticCacheSearchInput) !?SemanticCacheMatch {
        return error.PostgresAdapterIncomplete;
    }
    pub fn runHygiene(_: *PostgresStore, _: HygieneRunInput) !HygieneRunResult {
        return error.PostgresAdapterIncomplete;
    }
    pub fn createContextPack(_: *PostgresStore, _: std.mem.Allocator, _: ContextPackInput) !ContextPackResult {
        return error.PostgresAdapterIncomplete;
    }
    pub fn compatStore(_: *PostgresStore, _: std.mem.Allocator, _: CompatStoreInput) !void {
        return error.PostgresAdapterIncomplete;
    }
    pub fn compatGet(_: *PostgresStore, _: std.mem.Allocator, _: []const u8, _: ?[]const u8) !?domain.CompatMemory {
        return error.PostgresAdapterIncomplete;
    }
    pub fn compatList(_: *PostgresStore, allocator: std.mem.Allocator, _: ?[]const u8, _: ?[]const u8) ![]domain.CompatMemory {
        return allocator.alloc(domain.CompatMemory, 0);
    }
    pub fn compatSearch(_: *PostgresStore, allocator: std.mem.Allocator, _: []const u8, _: usize, _: ?[]const u8) ![]domain.CompatMemory {
        return allocator.alloc(domain.CompatMemory, 0);
    }
    pub fn compatDelete(_: *PostgresStore, _: []const u8, _: ?[]const u8) !bool {
        return error.PostgresAdapterIncomplete;
    }
    pub fn compatCount(_: *PostgresStore) !usize {
        return error.PostgresAdapterIncomplete;
    }
    pub fn saveMessage(_: *PostgresStore, _: []const u8, _: []const u8, _: []const u8) !void {
        return error.PostgresAdapterIncomplete;
    }
    pub fn loadMessages(_: *PostgresStore, allocator: std.mem.Allocator, _: []const u8) ![]Message {
        return allocator.alloc(Message, 0);
    }
    pub fn clearMessages(_: *PostgresStore, _: []const u8) !void {
        return error.PostgresAdapterIncomplete;
    }
    pub fn clearAutoSaved(_: *PostgresStore, _: ?[]const u8) !void {
        return error.PostgresAdapterIncomplete;
    }
    pub fn saveUsage(_: *PostgresStore, _: []const u8, _: u64) !void {
        return error.PostgresAdapterIncomplete;
    }
    pub fn deleteUsage(_: *PostgresStore, _: []const u8) !bool {
        return error.PostgresAdapterIncomplete;
    }
    pub fn loadUsage(_: *PostgresStore, _: []const u8) !?u64 {
        return error.PostgresAdapterIncomplete;
    }
    pub fn listSessions(_: *PostgresStore, allocator: std.mem.Allocator, _: usize, _: usize) !HistoryList {
        return .{ .total = 0, .sessions = try allocator.alloc(SessionInfo, 0) };
    }
    pub fn history(_: *PostgresStore, allocator: std.mem.Allocator, _: []const u8, _: usize, _: usize) !HistoryShow {
        return .{ .total = 0, .messages = try allocator.alloc(Message, 0) };
    }
};

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
    try std.testing.expect((try testingSqliteCount(&store, "SELECT COUNT(*) FROM schema_migrations WHERE version IN (1,2,3)")) == 3);
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
