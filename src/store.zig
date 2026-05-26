const std = @import("std");
const ids = @import("ids.zig");
const domain = @import("domain.zig");
const migrations = @import("migrations.zig");
const compat = @import("compat.zig");

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
        const fts_query = try buildFtsQuery(allocator, input.query);
        const use_fts = fts_query.len > 0;
        const stmt = if (use_fts)
            try self.prepare("SELECT ma.id,ma.text,ma.scope,ma.status,ma.confidence,ma.source_ids_json,ma.created_at_ms,ma.permissions_json,bm25(memory_atoms_fts) FROM memory_atoms_fts JOIN memory_atoms ma ON ma.id = memory_atoms_fts.id WHERE memory_atoms_fts MATCH ?1 ORDER BY bm25(memory_atoms_fts) LIMIT 1000")
        else
            try self.prepare("SELECT id,text,scope,status,confidence,source_ids_json,created_at_ms,permissions_json,0 FROM memory_atoms ORDER BY created_at_ms DESC LIMIT 1000");
        defer _ = c.sqlite3_finalize(stmt);
        if (use_fts) bindText(stmt, 1, fts_query);
        var results: std.ArrayListUnmanaged(domain.SearchResult) = .empty;
        errdefer results.deinit(allocator);
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
            try results.append(allocator, .{
                .id = id_text,
                .result_type = "memory_atom",
                .title = id_text,
                .text = text,
                .scope = scope,
                .status = status,
                .score = relevance + confidence,
                .source_ids_json = source_ids,
            });
            if (results.items.len >= limit) break;
        }
        return results.toOwnedSlice(allocator);
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

    pub fn createContextPack(self: *Self, allocator: std.mem.Allocator, input: ContextPackInput) !ContextPackResult {
        const search_results = try self.search(allocator, .{ .query = input.query, .limit = 8, .scopes_json = input.scopes_json });
        const id = try ids.make(allocator, "ctx_");
        const now = ids.nowMs();
        var atoms_json: std.ArrayListUnmanaged(u8) = .empty;
        try atoms_json.append(allocator, '[');
        for (search_results, 0..) |result, i| {
            if (i > 0) try atoms_json.append(allocator, ',');
            try atoms_json.print(allocator, "\"{s}\"", .{result.id});
        }
        try atoms_json.append(allocator, ']');
        const atoms = try atoms_json.toOwnedSlice(allocator);
        const summary = try buildContextSummary(allocator, input.query, search_results);
        const stmt = try self.prepare("INSERT INTO context_packs (id,purpose,target,query_text,included_sources_json,included_artifacts_json,included_memory_atoms_json,generated_summary,token_budget,created_at_ms) VALUES (?1,?2,?3,?4,'[]','[]',?5,?6,?7,?8)");
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, id);
        bindText(stmt, 2, input.purpose);
        bindText(stmt, 3, input.target);
        bindText(stmt, 4, input.query);
        bindText(stmt, 5, atoms);
        bindText(stmt, 6, summary);
        _ = c.sqlite3_bind_int64(stmt, 7, input.token_budget);
        _ = c.sqlite3_bind_int64(stmt, 8, now);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.InsertFailed;
        self.insertAudit("context_pack.created", "context_pack", id);
        return .{ .id = id, .purpose = input.purpose, .target = input.target, .query = input.query, .generated_summary = summary, .included_memory_atoms_json = atoms, .token_budget = input.token_budget, .created_at_ms = now };
    }

    fn buildContextSummary(allocator: std.mem.Allocator, query: []const u8, results: []const domain.SearchResult) ![]u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        try out.appendSlice(allocator, "Context Pack\n\nTask:\n");
        try out.appendSlice(allocator, query);
        try out.appendSlice(allocator, "\n\nRelevant memory:\n");
        for (results) |result| {
            try out.appendSlice(allocator, "- ");
            try out.appendSlice(allocator, result.text);
            try out.appendSlice(allocator, "\n");
        }
        if (results.len == 0) try out.appendSlice(allocator, "- No matching verified memory found.\n");
        return out.toOwnedSlice(allocator);
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
        const stmt = try self.prepare("SELECT memory_atom_id FROM compat_memories WHERE key = ?1 AND ((?2 IS NULL AND session_id IS NULL) OR session_id = ?2) LIMIT 1");
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

        const del = try self.prepare("DELETE FROM compat_memories WHERE key = ?1 AND ((?2 IS NULL AND session_id IS NULL) OR session_id = ?2)");
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
        const stmt = try self.prepare("SELECT memory_atom_id FROM compat_memories WHERE key = ?1 AND (?2 IS NULL OR session_id = ?2)");
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, key);
        bindNullableText(stmt, 2, session_id);
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const id_text = try columnText(self.allocator, stmt, 0);
            defer self.allocator.free(id_text);
            _ = try self.patchMemoryAtomStatus(id_text, "deprecated", false);
        }
        const del = try self.prepare("DELETE FROM compat_memories WHERE key = ?1 AND (?2 IS NULL OR session_id = ?2)");
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
            "WHERE (?2 IS NULL OR cm.session_id = ?2) " ++ extra_where ++ " " ++ tail;
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
    try std.testing.expect(std.mem.eql(u8, global.content, "Session value") or std.mem.eql(u8, global.content, "Global value"));
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
