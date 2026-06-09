const std = @import("std");

const access = @import("access.zig");
const agent_memory_reducer = @import("agent_memory_reducer.zig");
const bounded_int = @import("bounded_int.zig");
const compat = @import("compat.zig");
const domain = @import("domain.zig");
const ids = @import("ids.zig");
const retrieval = @import("retrieval.zig");
const requests = @import("agent_memory_requests.zig");
const result_contracts = @import("agent_memory_results.zig");
const vendor = @import("agent_memory_vendor.zig");
const config_contracts = @import("agent_memory_holographic_config.zig");

const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const is_compiled = true;
const SQLITE_STATIC: c.sqlite3_destructor_type = null;
pub const default_db_path = config_contracts.default_db_path;
pub const Config = config_contracts.Config;
const GetInput = requests.GetInput;
const ListInput = requests.ListInput;
const SearchInput = requests.SearchInput;
const DeleteInput = requests.DeleteInput;
const PatchStatusInput = requests.PatchStatusInput;
const CountInput = requests.CountInput;
const SaveMessageInput = requests.SaveMessageInput;
const LoadMessagesInput = requests.LoadMessagesInput;
const ClearMessagesInput = requests.ClearMessagesInput;
const ClearAutoSavedInput = requests.ClearAutoSavedInput;
const SaveUsageInput = requests.SaveUsageInput;
const DeleteUsageInput = requests.DeleteUsageInput;
const LoadUsageInput = requests.LoadUsageInput;
const ListSessionsInput = requests.ListSessionsInput;
const HistoryInput = requests.HistoryInput;
const Message = result_contracts.Message;
const HistoryList = result_contracts.HistoryList;
const HistoryShow = result_contracts.HistoryShow;
const store_name = "holographic";
const global_session_key = "__global__";
const hrr_dimensions = 32;
const search_candidate_multiplier: usize = 20;
const max_search_candidates: usize = 5000;

pub const WriteInput = struct {
    key: []const u8,
    content: []const u8,
    category: []const u8 = "core",
    session_id: ?[]const u8 = null,
    owner_actor_id: []const u8,
    writer_actor_id: []const u8,
    requested_scope: ?[]const u8 = null,
    requested_permissions_json: []const u8 = "[]",
    metadata_json: []const u8 = "{}",
    operation: domain.AgentMemoryOperation = .put,
    timestamp_ms: i64,
};

const QueryMode = enum {
    exact,
    visible,
};

const RowFilters = struct {
    key: ?[]const u8 = null,
    category: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    include_sessions: bool = false,
    actor_id: ?[]const u8 = null,
};

pub const Engine = struct {
    allocator: std.mem.Allocator,
    db: *c.sqlite3,
    db_path: []u8,
    config: Config,

    pub fn init(allocator: std.mem.Allocator, config: Config) !Engine {
        const raw_path = config.db_path orelse default_db_path;
        try ensureParentDir(raw_path);
        const db_path = try allocator.dupe(u8, raw_path);
        errdefer allocator.free(db_path);
        const z_path = try allocator.dupeZ(u8, raw_path);
        defer allocator.free(z_path);

        var db: ?*c.sqlite3 = null;
        const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_FULLMUTEX;
        if (c.sqlite3_open_v2(z_path.ptr, &db, flags, null) != c.SQLITE_OK) {
            if (db) |handle| _ = c.sqlite3_close(handle);
            return error.AgentMemoryStorageUnavailable;
        }
        errdefer _ = c.sqlite3_close(db.?);
        _ = c.sqlite3_busy_timeout(db.?, 5000);

        var engine = Engine{
            .allocator = allocator,
            .db = db.?,
            .db_path = db_path,
            .config = normalizedConfig(config),
        };
        try engine.initSchema();
        return engine;
    }

    pub fn deinit(self: *Engine) void {
        _ = c.sqlite3_close(self.db);
        self.allocator.free(self.db_path);
        self.* = undefined;
    }

    pub fn store(self: *Engine, allocator: std.mem.Allocator, input: WriteInput) !domain.AgentMemory {
        const existing = try self.get(allocator, input.key, input.session_id, input.owner_actor_id);
        defer if (existing) |entry_value| {
            var entry = entry_value;
            vendor.freeAgentMemory(allocator, &entry);
        };
        const existing_content = if (existing) |entry| entry.content else null;
        const reduced = try agent_memory_reducer.reduceContent(allocator, input.operation, existing_content, input.content);
        defer allocator.free(reduced);

        const scope = try access.agentMemoryScope(allocator, input.owner_actor_id, input.session_id, input.requested_scope);
        defer allocator.free(scope);
        const permissions = try access.agentMemoryPermissions(allocator, input.owner_actor_id, input.requested_scope, input.requested_permissions_json);
        defer allocator.free(permissions);
        const status = domain.defaultMemoryStatus("agent", scope);
        const trust = clampTrust(if (existing) |entry| entry.score orelse self.config.default_trust else self.config.default_trust);
        const hrr = try hrrSignature(allocator, input.key, reduced, input.category);
        defer allocator.free(hrr);
        const entry_id = try memoryEntryId(allocator, input.owner_actor_id, input.session_id, input.key);
        defer allocator.free(entry_id);

        var tx = try self.beginTransaction();
        errdefer tx.rollback();
        {
            const stmt = try self.prepare(
                \\INSERT INTO holographic_agent_memory (
                \\  id, key, content, category, timestamp_ms, session_id, session_key,
                \\  actor_id, writer_actor_id, scope, permissions_json, status,
                \\  trust, hrr_signature, metadata_json, updated_at_ms
                \\) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16)
                \\ON CONFLICT(actor_id, key, session_key) DO UPDATE SET
                \\  id=excluded.id,
                \\  content=excluded.content,
                \\  category=excluded.category,
                \\  timestamp_ms=excluded.timestamp_ms,
                \\  session_id=excluded.session_id,
                \\  writer_actor_id=excluded.writer_actor_id,
                \\  scope=excluded.scope,
                \\  permissions_json=excluded.permissions_json,
                \\  status=excluded.status,
                \\  trust=excluded.trust,
                \\  hrr_signature=excluded.hrr_signature,
                \\  metadata_json=excluded.metadata_json,
                \\  updated_at_ms=excluded.updated_at_ms
            );
            defer _ = c.sqlite3_finalize(stmt);
            bindText(stmt, 1, entry_id);
            bindText(stmt, 2, input.key);
            bindText(stmt, 3, reduced);
            bindText(stmt, 4, input.category);
            _ = c.sqlite3_bind_int64(stmt, 5, input.timestamp_ms);
            bindNullableText(stmt, 6, input.session_id);
            bindText(stmt, 7, sessionKey(input.session_id));
            bindText(stmt, 8, input.owner_actor_id);
            bindText(stmt, 9, input.writer_actor_id);
            bindText(stmt, 10, scope);
            bindText(stmt, 11, permissions);
            bindText(stmt, 12, status);
            _ = c.sqlite3_bind_double(stmt, 13, trust);
            bindText(stmt, 14, hrr);
            bindText(stmt, 15, input.metadata_json);
            _ = c.sqlite3_bind_int64(stmt, 16, input.timestamp_ms);
            if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.AgentMemoryStorageUnavailable;
        }
        try self.refreshFts(entry_id, input.key, reduced, input.category, scope, input.owner_actor_id);
        try tx.commit();
        return try self.get(allocator, input.key, input.session_id, input.owner_actor_id) orelse error.AgentMemoryStorageUnavailable;
    }

    pub fn getByInput(self: *Engine, allocator: std.mem.Allocator, input: GetInput) !?domain.AgentMemory {
        const normalized_session_id = access.normalizeSessionId(input.session_id);
        if (input.scopes_json) |scopes_json| {
            const actor_id = input.actor_id orelse return error.InvalidAgentMemoryRuntimeRequest;
            if (input.any_session) return self.getAnyVisible(allocator, input.key, actor_id, scopes_json);
            return self.getVisible(allocator, input.key, normalized_session_id, actor_id, scopes_json);
        }
        return self.get(allocator, input.key, normalized_session_id, input.actor_id);
    }

    fn get(self: *Engine, allocator: std.mem.Allocator, key: []const u8, session_id: ?[]const u8, actor_id: ?[]const u8) !?domain.AgentMemory {
        const owner = actor_id orelse return null;
        return self.firstByFilters(allocator, .exact, .{ .key = key, .session_id = session_id, .actor_id = owner }, owner, "[]");
    }

    fn getVisible(self: *Engine, allocator: std.mem.Allocator, key: []const u8, session_id: ?[]const u8, actor_id: []const u8, scopes_json: []const u8) !?domain.AgentMemory {
        return self.firstByFilters(allocator, .visible, .{ .key = key, .session_id = session_id }, actor_id, scopes_json);
    }

    fn getAnyVisible(self: *Engine, allocator: std.mem.Allocator, key: []const u8, actor_id: []const u8, scopes_json: []const u8) !?domain.AgentMemory {
        return self.firstByFilters(allocator, .visible, .{ .key = key, .include_sessions = true }, actor_id, scopes_json);
    }

    pub fn listByInput(self: *Engine, allocator: std.mem.Allocator, input: ListInput) ![]domain.AgentMemory {
        const normalized_session_id = access.normalizeSessionId(input.session_id);
        if (input.limit) |limit| {
            if (limit == 0) return allocator.alloc(domain.AgentMemory, 0);
            if (input.scopes_json) |scopes_json| {
                const actor_id = input.actor_id orelse return error.InvalidAgentMemoryRuntimeRequest;
                if (input.any_session) return self.listAnyVisibleWindow(allocator, input.category, actor_id, scopes_json, limit, input.offset);
                return self.listVisibleWindow(allocator, input.category, normalized_session_id, actor_id, scopes_json, limit, input.offset);
            }
            return self.listWindow(allocator, input.category, normalized_session_id, input.actor_id, limit, input.offset);
        }
        if (input.scopes_json) |scopes_json| {
            const actor_id = input.actor_id orelse return error.InvalidAgentMemoryRuntimeRequest;
            if (input.any_session) return self.listAnyVisible(allocator, input.category, actor_id, scopes_json);
            return self.listVisible(allocator, input.category, normalized_session_id, actor_id, scopes_json);
        }
        return self.list(allocator, input.category, normalized_session_id, input.actor_id);
    }

    fn list(self: *Engine, allocator: std.mem.Allocator, category: ?[]const u8, session_id: ?[]const u8, actor_id: ?[]const u8) ![]domain.AgentMemory {
        const owner = actor_id orelse return allocator.alloc(domain.AgentMemory, 0);
        return self.listByFilters(allocator, .exact, .{ .category = category, .session_id = session_id, .actor_id = owner }, owner, "[]", std.math.maxInt(usize), 0);
    }

    fn listWindow(self: *Engine, allocator: std.mem.Allocator, category: ?[]const u8, session_id: ?[]const u8, actor_id: ?[]const u8, limit: usize, offset: usize) ![]domain.AgentMemory {
        if (limit == 0) return allocator.alloc(domain.AgentMemory, 0);
        const owner = actor_id orelse return allocator.alloc(domain.AgentMemory, 0);
        return self.listByFilters(allocator, .exact, .{ .category = category, .session_id = session_id, .actor_id = owner }, owner, "[]", limit, offset);
    }

    fn listVisible(self: *Engine, allocator: std.mem.Allocator, category: ?[]const u8, session_id: ?[]const u8, actor_id: []const u8, scopes_json: []const u8) ![]domain.AgentMemory {
        return self.listByFilters(allocator, .visible, .{ .category = category, .session_id = session_id }, actor_id, scopes_json, std.math.maxInt(usize), 0);
    }

    fn listVisibleWindow(self: *Engine, allocator: std.mem.Allocator, category: ?[]const u8, session_id: ?[]const u8, actor_id: []const u8, scopes_json: []const u8, limit: usize, offset: usize) ![]domain.AgentMemory {
        if (limit == 0) return allocator.alloc(domain.AgentMemory, 0);
        return self.listByFilters(allocator, .visible, .{ .category = category, .session_id = session_id }, actor_id, scopes_json, limit, offset);
    }

    fn listAnyVisible(self: *Engine, allocator: std.mem.Allocator, category: ?[]const u8, actor_id: []const u8, scopes_json: []const u8) ![]domain.AgentMemory {
        return self.listByFilters(allocator, .visible, .{ .category = category, .include_sessions = true }, actor_id, scopes_json, std.math.maxInt(usize), 0);
    }

    fn listAnyVisibleWindow(self: *Engine, allocator: std.mem.Allocator, category: ?[]const u8, actor_id: []const u8, scopes_json: []const u8, limit: usize, offset: usize) ![]domain.AgentMemory {
        if (limit == 0) return allocator.alloc(domain.AgentMemory, 0);
        return self.listByFilters(allocator, .visible, .{ .category = category, .include_sessions = true }, actor_id, scopes_json, limit, offset);
    }

    pub fn searchByInput(self: *Engine, allocator: std.mem.Allocator, input: SearchInput) ![]domain.AgentMemory {
        if (input.limit == 0) return allocator.alloc(domain.AgentMemory, 0);
        const normalized_session_id = access.normalizeSessionId(input.session_id);
        if (input.any_session) return self.searchAnyVisible(allocator, input.query, input.limit, input.scopes_json, input.actor_id);
        return self.search(allocator, input.query, input.limit, normalized_session_id, input.scopes_json, input.actor_id);
    }

    fn search(self: *Engine, allocator: std.mem.Allocator, query: []const u8, limit: usize, session_id: ?[]const u8, scopes_json: []const u8, actor_id: ?[]const u8) ![]domain.AgentMemory {
        const actor = actor_id orelse return allocator.alloc(domain.AgentMemory, 0);
        return self.searchInternal(allocator, query, limit, session_id, false, actor, scopes_json);
    }

    fn searchAnyVisible(self: *Engine, allocator: std.mem.Allocator, query: []const u8, limit: usize, scopes_json: []const u8, actor_id: ?[]const u8) ![]domain.AgentMemory {
        const actor = actor_id orelse return allocator.alloc(domain.AgentMemory, 0);
        return self.searchInternal(allocator, query, limit, null, true, actor, scopes_json);
    }

    pub fn deleteByInput(self: *Engine, input: DeleteInput) !bool {
        const normalized_session_id = access.normalizeSessionId(input.session_id);
        if (input.all_owners) return self.deleteAll(input.key, input.actor_id, input.writer_actor_id);
        return self.delete(input.key, normalized_session_id, input.actor_id, input.writer_actor_id);
    }

    fn delete(self: *Engine, key: []const u8, session_id: ?[]const u8, actor_id: ?[]const u8, writer_actor_id: ?[]const u8) !bool {
        _ = writer_actor_id;
        const owner = actor_id orelse return false;
        const entry_id = try memoryEntryId(self.allocator, owner, session_id, key);
        defer self.allocator.free(entry_id);
        var tx = try self.beginTransaction();
        errdefer tx.rollback();
        try self.deleteFts(entry_id);
        const changed = blk: {
            const stmt = try self.prepare("DELETE FROM holographic_agent_memory WHERE actor_id=?1 AND key=?2 AND session_key=?3");
            defer _ = c.sqlite3_finalize(stmt);
            bindText(stmt, 1, owner);
            bindText(stmt, 2, key);
            bindText(stmt, 3, sessionKey(session_id));
            if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.AgentMemoryStorageUnavailable;
            break :blk c.sqlite3_changes(self.db) > 0;
        };
        try tx.commit();
        return changed;
    }

    fn deleteAll(self: *Engine, key: []const u8, actor_id: ?[]const u8, writer_actor_id: ?[]const u8) !bool {
        _ = writer_actor_id;
        const owner = actor_id orelse return false;
        const ids_to_delete = try self.memoryIdsForOwnerKey(self.allocator, owner, key);
        defer freeStringSlice(self.allocator, ids_to_delete);

        var tx = try self.beginTransaction();
        errdefer tx.rollback();
        for (ids_to_delete) |id| try self.deleteFts(id);
        const changed = blk: {
            const stmt = try self.prepare("DELETE FROM holographic_agent_memory WHERE actor_id=?1 AND key=?2");
            defer _ = c.sqlite3_finalize(stmt);
            bindText(stmt, 1, owner);
            bindText(stmt, 2, key);
            if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.AgentMemoryStorageUnavailable;
            break :blk c.sqlite3_changes(self.db) > 0;
        };
        try tx.commit();
        return changed or ids_to_delete.len > 0;
    }

    pub fn patchStatusByInput(self: *Engine, allocator: std.mem.Allocator, input: PatchStatusInput) !bool {
        return self.patchStatus(allocator, input.key, access.normalizeSessionId(input.session_id), input.actor_id, input.status, input.writer_actor_id);
    }

    fn patchStatus(self: *Engine, allocator: std.mem.Allocator, key: []const u8, session_id: ?[]const u8, actor_id: ?[]const u8, status: []const u8, writer_actor_id: ?[]const u8) !bool {
        _ = allocator;
        _ = writer_actor_id;
        const owner = actor_id orelse return false;
        const delta = statusTrustDelta(self.config, status);
        const stmt = try self.prepare(
            \\UPDATE holographic_agent_memory
            \\SET status=?1,
            \\    trust=max(0.0, min(1.0, trust + ?2)),
            \\    updated_at_ms=?3
            \\WHERE actor_id=?4 AND key=?5 AND session_key=?6
        );
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, status);
        _ = c.sqlite3_bind_double(stmt, 2, delta);
        _ = c.sqlite3_bind_int64(stmt, 3, ids.nowMs());
        bindText(stmt, 4, owner);
        bindText(stmt, 5, key);
        bindText(stmt, 6, sessionKey(session_id));
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.AgentMemoryStorageUnavailable;
        return c.sqlite3_changes(self.db) > 0;
    }

    pub fn countByInput(self: *Engine, input: CountInput) !usize {
        return self.count(input.actor_id, input.scopes_json);
    }

    fn count(self: *Engine, actor_id: ?[]const u8, scopes_json: []const u8) !usize {
        if (actor_id) |actor| {
            const entries = try self.listAnyVisible(self.allocator, null, actor, scopes_json);
            defer {
                for (entries) |*entry| vendor.freeAgentMemory(self.allocator, entry);
                self.allocator.free(entries);
            }
            return entries.len;
        }
        const stmt = try self.prepare("SELECT count(*) FROM holographic_agent_memory");
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return 0;
        return bounded_int.nonNegativeI64ToUsize(c.sqlite3_column_int64(stmt, 0));
    }

    pub fn saveMessageByInput(_: *Engine, _: SaveMessageInput) !void {
        return error.NotSupported;
    }

    pub fn loadMessagesByInput(_: *Engine, _: std.mem.Allocator, _: LoadMessagesInput) ![]Message {
        return error.NotSupported;
    }

    pub fn clearMessagesByInput(_: *Engine, _: ClearMessagesInput) !void {
        return error.NotSupported;
    }

    pub fn clearAutoSavedByInput(_: *Engine, _: ClearAutoSavedInput) !void {
        return error.NotSupported;
    }

    pub fn saveUsageByInput(_: *Engine, _: SaveUsageInput) !void {
        return error.NotSupported;
    }

    pub fn deleteUsageByInput(_: *Engine, _: DeleteUsageInput) !bool {
        return error.NotSupported;
    }

    pub fn loadUsageByInput(_: *Engine, _: LoadUsageInput) !?u64 {
        return error.NotSupported;
    }

    pub fn listSessionsByInput(_: *Engine, _: std.mem.Allocator, _: ListSessionsInput) !HistoryList {
        return error.NotSupported;
    }

    pub fn historyByInput(_: *Engine, _: std.mem.Allocator, _: HistoryInput) !HistoryShow {
        return error.NotSupported;
    }

    fn initSchema(self: *Engine) !void {
        try self.exec("PRAGMA journal_mode=WAL;");
        try self.exec("PRAGMA synchronous=NORMAL;");
        try self.exec(
            \\CREATE TABLE IF NOT EXISTS holographic_agent_memory (
            \\  id TEXT PRIMARY KEY,
            \\  key TEXT NOT NULL,
            \\  content TEXT NOT NULL,
            \\  category TEXT NOT NULL,
            \\  timestamp_ms INTEGER NOT NULL,
            \\  session_id TEXT,
            \\  session_key TEXT NOT NULL,
            \\  actor_id TEXT NOT NULL,
            \\  writer_actor_id TEXT NOT NULL,
            \\  scope TEXT NOT NULL,
            \\  permissions_json TEXT NOT NULL,
            \\  status TEXT NOT NULL,
            \\  trust REAL NOT NULL,
            \\  hrr_signature TEXT NOT NULL,
            \\  metadata_json TEXT NOT NULL,
            \\  updated_at_ms INTEGER NOT NULL,
            \\  UNIQUE(actor_id, key, session_key)
            \\);
        );
        try self.exec("CREATE INDEX IF NOT EXISTS idx_holographic_memory_owner ON holographic_agent_memory(actor_id, key, session_key);");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_holographic_memory_category ON holographic_agent_memory(category, timestamp_ms DESC);");
        try self.exec(
            \\CREATE VIRTUAL TABLE IF NOT EXISTS holographic_agent_memory_fts
            \\USING fts5(memory_id UNINDEXED, key, content, category, scope, actor_id, tokenize='unicode61');
        );
    }

    fn firstByFilters(self: *Engine, allocator: std.mem.Allocator, mode: QueryMode, filters: RowFilters, actor_id: []const u8, scopes_json: []const u8) !?domain.AgentMemory {
        var entries = try self.listByFilters(allocator, mode, filters, actor_id, scopes_json, 1, 0);
        defer allocator.free(entries);
        if (entries.len == 0) return null;
        const first = entries[0];
        vendor.detachAgentMemory(&entries[0]);
        return first;
    }

    fn listByFilters(self: *Engine, allocator: std.mem.Allocator, mode: QueryMode, filters: RowFilters, actor_id: []const u8, scopes_json: []const u8, limit: usize, offset: usize) ![]domain.AgentMemory {
        const stmt = try self.prepare(
            \\SELECT id, key, content, category, timestamp_ms, session_id, actor_id,
            \\       writer_actor_id, scope, permissions_json, status, trust
            \\FROM holographic_agent_memory
            \\WHERE (?1 IS NULL OR key=?1)
            \\  AND (?2 IS NULL OR category=?2)
            \\  AND (?3 IS NULL OR session_key=?3)
            \\  AND (?4 != 0 OR session_id IS NULL)
            \\  AND (?5 IS NULL OR actor_id=?5)
            \\ORDER BY trust DESC, timestamp_ms DESC, key ASC
        );
        defer _ = c.sqlite3_finalize(stmt);
        bindNullableText(stmt, 1, filters.key);
        bindNullableText(stmt, 2, filters.category);
        if (filters.session_id) |sid| bindText(stmt, 3, sessionKey(sid)) else _ = c.sqlite3_bind_null(stmt, 3);
        _ = c.sqlite3_bind_int(stmt, 4, if (filters.include_sessions or filters.session_id != null) 1 else 0);
        bindNullableText(stmt, 5, filters.actor_id);
        return self.collectRows(allocator, stmt, mode, actor_id, scopes_json, limit, offset, null, null);
    }

    fn searchInternal(self: *Engine, allocator: std.mem.Allocator, query: []const u8, limit: usize, session_id: ?[]const u8, include_sessions: bool, actor_id: []const u8, scopes_json: []const u8) ![]domain.AgentMemory {
        if (limit == 0) return allocator.alloc(domain.AgentMemory, 0);
        const fts_query = try ftsQuery(allocator, query);
        defer allocator.free(fts_query);
        if (fts_query.len == 0) {
            return self.listByFilters(allocator, .visible, .{ .session_id = session_id, .include_sessions = include_sessions }, actor_id, scopes_json, limit, 0);
        }
        const query_signature = try hrrSignature(allocator, query, "", "");
        defer allocator.free(query_signature);
        const candidate_limit = holographicSearchCandidateLimit(limit);

        const stmt = try self.prepare(
            \\SELECT h.id, h.key, h.content, h.category, h.timestamp_ms, h.session_id, h.actor_id,
            \\       h.writer_actor_id, h.scope, h.permissions_json, h.status, h.trust,
            \\       h.hrr_signature, bm25(holographic_agent_memory_fts)
            \\FROM holographic_agent_memory_fts
            \\JOIN holographic_agent_memory h ON h.id = holographic_agent_memory_fts.memory_id
            \\WHERE holographic_agent_memory_fts MATCH ?1
            \\  AND (?2 IS NULL OR h.session_key=?2)
            \\  AND (?3 != 0 OR h.session_id IS NULL)
            \\ORDER BY bm25(holographic_agent_memory_fts) ASC, h.trust DESC, h.timestamp_ms DESC
            \\LIMIT ?4
        );
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, fts_query);
        if (session_id) |sid| bindText(stmt, 2, sessionKey(sid)) else _ = c.sqlite3_bind_null(stmt, 2);
        _ = c.sqlite3_bind_int(stmt, 3, if (include_sessions) 1 else 0);
        _ = c.sqlite3_bind_int64(stmt, 4, bounded_int.usizeToI64Saturating(candidate_limit));
        return self.collectRows(allocator, stmt, .visible, actor_id, scopes_json, limit, 0, query, query_signature);
    }

    fn collectRows(self: *Engine, allocator: std.mem.Allocator, stmt: *c.sqlite3_stmt, mode: QueryMode, actor_id: []const u8, scopes_json: []const u8, limit: usize, offset: usize, query: ?[]const u8, query_signature: ?[]const u8) ![]domain.AgentMemory {
        _ = self;
        var out: std.ArrayListUnmanaged(domain.AgentMemory) = .empty;
        errdefer {
            for (out.items) |*entry| vendor.freeAgentMemory(allocator, entry);
            out.deinit(allocator);
        }
        var skipped: usize = 0;
        const capped = @min(limit, @as(usize, 5000));
        while (true) {
            const rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return error.AgentMemoryStorageUnavailable;
            var entry = try readMemoryRow(allocator, stmt);
            var owned = true;
            errdefer if (owned) vendor.freeAgentMemory(allocator, &entry);
            if (mode == .visible and !try vendor.entryVisible(allocator, entry, actor_id, scopes_json)) {
                vendor.freeAgentMemory(allocator, &entry);
                owned = false;
                continue;
            }
            if (query) |raw_query| {
                const associative = if (query_signature) |signature| blk: {
                    if (c.sqlite3_column_count(stmt) <= 12) break :blk 0.0;
                    const stored_signature = c.sqlite3_column_text(stmt, 12) orelse break :blk 0.0;
                    const signature_len = columnBytes(stmt, 12);
                    break :blk signatureCosine(signature, stored_signature[0..signature_len]);
                } else 0.0;
                entry.score = holographicScore(raw_query, entry, associative);
            }
            if (skipped < offset) {
                skipped += 1;
                vendor.freeAgentMemory(allocator, &entry);
                owned = false;
                continue;
            }
            if (out.items.len < capped) {
                try out.append(allocator, entry);
                owned = false;
                continue;
            }
            vendor.freeAgentMemory(allocator, &entry);
            owned = false;
            break;
        }
        sortAgentMemory(out.items);
        return out.toOwnedSlice(allocator);
    }

    fn refreshFts(self: *Engine, id: []const u8, key: []const u8, content: []const u8, category: []const u8, scope: []const u8, actor_id: []const u8) !void {
        try self.deleteFts(id);
        const stmt = try self.prepare(
            \\INSERT INTO holographic_agent_memory_fts(memory_id, key, content, category, scope, actor_id)
            \\VALUES(?1, ?2, ?3, ?4, ?5, ?6)
        );
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, id);
        bindText(stmt, 2, key);
        bindText(stmt, 3, content);
        bindText(stmt, 4, category);
        bindText(stmt, 5, scope);
        bindText(stmt, 6, actor_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.AgentMemoryStorageUnavailable;
    }

    fn deleteFts(self: *Engine, id: []const u8) !void {
        const stmt = try self.prepare("DELETE FROM holographic_agent_memory_fts WHERE memory_id=?1");
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, id);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.AgentMemoryStorageUnavailable;
    }

    fn memoryIdsForOwnerKey(self: *Engine, allocator: std.mem.Allocator, actor_id: []const u8, key: []const u8) ![][]u8 {
        var out: std.ArrayListUnmanaged([]u8) = .empty;
        errdefer {
            for (out.items) |id| allocator.free(id);
            out.deinit(allocator);
        }
        const stmt = try self.prepare("SELECT id FROM holographic_agent_memory WHERE actor_id=?1 AND key=?2");
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, actor_id);
        bindText(stmt, 2, key);
        while (true) {
            const rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return error.AgentMemoryStorageUnavailable;
            try out.append(allocator, try columnText(allocator, stmt, 0));
        }
        return out.toOwnedSlice(allocator);
    }

    fn prepare(self: *Engine, sql: [*:0]const u8) !*c.sqlite3_stmt {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.AgentMemoryStorageUnavailable;
        return stmt.?;
    }

    fn exec(self: *Engine, sql: [*:0]const u8) !void {
        var err_msg: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.db, sql, null, null, &err_msg);
        if (rc != c.SQLITE_OK) {
            if (err_msg) |msg| c.sqlite3_free(msg);
            return error.AgentMemoryStorageUnavailable;
        }
    }

    fn beginTransaction(self: *Engine) !Transaction {
        try self.exec("BEGIN IMMEDIATE;");
        return .{ .engine = self };
    }
};

const Transaction = struct {
    engine: *Engine,
    committed: bool = false,

    fn commit(self: *Transaction) !void {
        try self.engine.exec("COMMIT;");
        self.committed = true;
    }

    fn rollback(self: *Transaction) void {
        if (!self.committed) self.engine.exec("ROLLBACK;") catch {};
    }
};

fn normalizedConfig(config: Config) Config {
    var out = config;
    out.default_trust = clampTrust(config.default_trust);
    out.trust_reward = @max(0.0, @min(config.trust_reward, 1.0));
    out.trust_penalty = @max(0.0, @min(config.trust_penalty, 1.0));
    return out;
}

fn ensureParentDir(path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    if (parent.len == 0) return;
    try std.Io.Dir.cwd().createDirPath(compat.io(), parent);
}

fn sessionKey(session_id: ?[]const u8) []const u8 {
    return session_id orelse global_session_key;
}

fn clampTrust(value: f64) f64 {
    return @max(0.0, @min(value, 1.0));
}

fn statusTrustDelta(config: Config, status: []const u8) f64 {
    if (std.mem.eql(u8, status, "verified")) return config.trust_reward;
    if (std.mem.eql(u8, status, "rejected") or
        std.mem.eql(u8, status, "deprecated") or
        std.mem.eql(u8, status, "superseded") or
        std.mem.eql(u8, status, "stale"))
    {
        return -config.trust_penalty;
    }
    return 0.0;
}

fn bindText(stmt: *c.sqlite3_stmt, index: c_int, value: []const u8) void {
    _ = c.sqlite3_bind_text64(stmt, index, value.ptr, @intCast(bounded_int.usizeToU64Saturating(value.len)), SQLITE_STATIC, c.SQLITE_UTF8);
}

fn bindNullableText(stmt: *c.sqlite3_stmt, index: c_int, value: ?[]const u8) void {
    if (value) |v| bindText(stmt, index, v) else _ = c.sqlite3_bind_null(stmt, index);
}

fn columnBytes(stmt: *c.sqlite3_stmt, index: c_int) usize {
    return bounded_int.nonNegativeCIntToUsize(c.sqlite3_column_bytes(stmt, index));
}

fn columnText(allocator: std.mem.Allocator, stmt: *c.sqlite3_stmt, index: c_int) ![]u8 {
    const ptr = c.sqlite3_column_text(stmt, index) orelse return allocator.dupe(u8, "");
    const len = columnBytes(stmt, index);
    return allocator.dupe(u8, ptr[0..len]);
}

fn columnTextNullable(allocator: std.mem.Allocator, stmt: *c.sqlite3_stmt, index: c_int) !?[]u8 {
    if (c.sqlite3_column_type(stmt, index) == c.SQLITE_NULL) return null;
    return try columnText(allocator, stmt, index);
}

fn readMemoryRow(allocator: std.mem.Allocator, stmt: *c.sqlite3_stmt) !domain.AgentMemory {
    var entry = domain.AgentMemory{
        .id = "",
        .key = "",
        .content = "",
        .category = "",
        .timestamp = "",
        .session_id = null,
        .actor_id = "",
        .writer_actor_id = "",
        .scope = "",
        .permissions_json = "",
        .status = "",
        .store = "",
        .score = c.sqlite3_column_double(stmt, 11),
    };
    errdefer vendor.freeAgentMemory(allocator, &entry);

    entry.id = try columnText(allocator, stmt, 0);
    entry.key = try columnText(allocator, stmt, 1);
    entry.content = try columnText(allocator, stmt, 2);
    entry.category = try columnText(allocator, stmt, 3);
    entry.timestamp = try std.fmt.allocPrint(allocator, "{d}", .{c.sqlite3_column_int64(stmt, 4)});
    entry.session_id = try columnTextNullable(allocator, stmt, 5);
    entry.actor_id = try columnText(allocator, stmt, 6);
    entry.writer_actor_id = try columnText(allocator, stmt, 7);
    entry.scope = try columnText(allocator, stmt, 8);
    entry.permissions_json = try columnText(allocator, stmt, 9);
    entry.status = try columnText(allocator, stmt, 10);
    entry.store = try allocator.dupe(u8, store_name);

    const out = entry;
    vendor.detachAgentMemory(&entry);
    return out;
}

fn memoryEntryId(allocator: std.mem.Allocator, actor: []const u8, session_id: ?[]const u8, key: []const u8) ![]u8 {
    var hash_value = std.hash.Wyhash.hash(0, actor);
    hash_value = std.hash.Wyhash.hash(hash_value, session_id orelse "");
    hash_value = std.hash.Wyhash.hash(hash_value, key);
    return std.fmt.allocPrint(allocator, "hgm_{x}", .{hash_value});
}

fn hrrSignature(allocator: std.mem.Allocator, key: []const u8, content: []const u8, category: []const u8) ![]u8 {
    var values: [hrr_dimensions]i32 = [_]i32{0} ** hrr_dimensions;
    try addTokensToSignature(&values, key);
    try addTokensToSignature(&values, content);
    try addTokensToSignature(&values, category);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    for (values, 0..) |value, i| {
        if (i > 0) try out.append(allocator, ',');
        try out.print(allocator, "{d}", .{value});
    }
    return out.toOwnedSlice(allocator);
}

fn addTokensToSignature(values: *[hrr_dimensions]i32, text: []const u8) !void {
    var start: ?usize = null;
    for (text, 0..) |ch, i| {
        if (isTokenChar(ch)) {
            if (start == null) start = i;
        } else if (start) |s| {
            addTokenToSignature(values, text[s..i]);
            start = null;
        }
    }
    if (start) |s| addTokenToSignature(values, text[s..]);
}

fn addTokenToSignature(values: *[hrr_dimensions]i32, token: []const u8) void {
    if (token.len == 0) return;
    const lower_hash = foldedTokenHash(0x48475252, token);
    const dim = @as(usize, @intCast(lower_hash % hrr_dimensions));
    const sign: i32 = if ((lower_hash & 1) == 0) 1 else -1;
    values[dim] += sign;
}

fn foldedTokenHash(seed: u64, token: []const u8) u64 {
    var hash = seed ^ 0xcbf29ce484222325;
    for (token) |ch| {
        hash ^= std.ascii.toLower(ch);
        hash *%= 0x100000001b3;
    }
    return hash;
}

fn ftsQuery(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var start: ?usize = null;
    var token_count: usize = 0;
    for (raw, 0..) |ch, i| {
        if (isTokenChar(ch)) {
            if (start == null) start = i;
        } else if (start) |s| {
            try appendFtsToken(allocator, &out, raw[s..i], &token_count);
            start = null;
        }
    }
    if (start) |s| try appendFtsToken(allocator, &out, raw[s..], &token_count);
    return out.toOwnedSlice(allocator);
}

fn appendFtsToken(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), token: []const u8, token_count: *usize) !void {
    if (token.len == 0) return;
    if (token_count.* > 0) try out.appendSlice(allocator, " OR ");
    try out.append(allocator, '"');
    try out.appendSlice(allocator, token);
    try out.append(allocator, '"');
    token_count.* += 1;
}

fn isTokenChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

fn freeStringSlice(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

fn signatureCosine(query_signature: []const u8, stored_signature: []const u8) f64 {
    var query_idx: usize = 0;
    var stored_idx: usize = 0;
    var dot: f64 = 0;
    var query_mag: f64 = 0;
    var stored_mag: f64 = 0;
    while (true) {
        const query_value = nextSignatureValue(query_signature, &query_idx);
        const stored_value = nextSignatureValue(stored_signature, &stored_idx);
        if (query_value == null and stored_value == null) break;
        const q: f64 = @floatFromInt(query_value orelse 0);
        const s: f64 = @floatFromInt(stored_value orelse 0);
        dot += q * s;
        query_mag += q * q;
        stored_mag += s * s;
    }
    if (query_mag == 0 or stored_mag == 0) return 0;
    return @max(0.0, dot / (std.math.sqrt(query_mag) * std.math.sqrt(stored_mag)));
}

fn nextSignatureValue(signature: []const u8, index: *usize) ?i32 {
    while (index.* < signature.len and isSignatureSeparator(signature[index.*])) index.* += 1;
    if (index.* >= signature.len) return null;
    const start = index.*;
    if (signature[index.*] == '-' or signature[index.*] == '+') index.* += 1;
    const digits_start = index.*;
    while (index.* < signature.len and std.ascii.isDigit(signature[index.*])) index.* += 1;
    if (digits_start == index.*) return null;
    const value = std.fmt.parseInt(i32, signature[start..index.*], 10) catch return null;
    while (index.* < signature.len and signature[index.*] != ',') index.* += 1;
    if (index.* < signature.len and signature[index.*] == ',') index.* += 1;
    return value;
}

fn isSignatureSeparator(ch: u8) bool {
    return ch == ',' or ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n';
}

fn holographicScore(query: []const u8, entry: domain.AgentMemory, associative: f64) f64 {
    const lexical = retrieval.lexicalScore(query, entry.key) + retrieval.lexicalScore(query, entry.content);
    const trust = entry.score orelse 0.5;
    return lexical + trust + (associative * 0.5);
}

fn holographicSearchCandidateLimit(limit: usize) usize {
    if (limit == 0) return 0;
    const expanded = bounded_int.saturatingUsizeMul(limit, search_candidate_multiplier);
    return @min(expanded, max_search_candidates);
}

fn sortAgentMemory(items: []domain.AgentMemory) void {
    std.mem.sort(domain.AgentMemory, items, {}, struct {
        fn lessThan(_: void, a: domain.AgentMemory, b: domain.AgentMemory) bool {
            const as = a.score orelse 0;
            const bs = b.score orelse 0;
            if (as != bs) return as > bs;
            return std.mem.order(u8, a.timestamp, b.timestamp) == .gt;
        }
    }.lessThan);
}

fn tmpDbPath(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    try std.Io.Dir.cwd().createDirPath(compat.io(), ".zig-cache/nullpantry-tests");
    return std.fmt.allocPrint(allocator, ".zig-cache/nullpantry-tests/{s}-{d}.db", .{ name, ids.nowMs() });
}

fn deleteSqliteTestFiles(allocator: std.mem.Allocator, path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(compat.io(), path) catch {};
    const wal = std.fmt.allocPrint(allocator, "{s}-wal", .{path}) catch return;
    defer allocator.free(wal);
    std.Io.Dir.cwd().deleteFile(compat.io(), wal) catch {};
    const shm = std.fmt.allocPrint(allocator, "{s}-shm", .{path}) catch return;
    defer allocator.free(shm);
    std.Io.Dir.cwd().deleteFile(compat.io(), shm) catch {};
}

test "holographic stores isolated and shared memory with fts search" {
    const allocator = std.testing.allocator;
    const path = try tmpDbPath(allocator, "holographic-basic");
    defer allocator.free(path);
    defer deleteSqliteTestFiles(allocator, path);

    var engine = try Engine.init(allocator, .{ .db_path = path });
    defer engine.deinit();

    var own = try engine.store(allocator, .{
        .key = "pref.language",
        .content = "Prefer Zig examples",
        .category = "preference",
        .owner_actor_id = "agent:a",
        .writer_actor_id = "agent:a",
        .timestamp_ms = 10,
    });
    defer vendor.freeAgentMemory(allocator, &own);
    try std.testing.expectEqualStrings(store_name, own.store);
    try std.testing.expectEqualStrings("agent:a", own.actor_id);

    const hidden = try engine.getVisible(allocator, "pref.language", null, "agent:b", "[\"agent:agent:b\"]");
    try std.testing.expect(hidden == null);

    var team = try engine.store(allocator, .{
        .key = "team.rule",
        .content = "Team alpha prefers architecture notes with citations",
        .category = "preference",
        .owner_actor_id = "shared:team:alpha",
        .writer_actor_id = "agent:a",
        .requested_scope = "team:alpha",
        .requested_permissions_json = "[\"team:alpha\"]",
        .timestamp_ms = 11,
    });
    defer vendor.freeAgentMemory(allocator, &team);
    try std.testing.expectEqualStrings("shared:team:alpha", team.actor_id);

    const hits = try engine.searchAnyVisible(allocator, "architecture citations", 5, "[\"team:alpha\"]", "agent:b");
    defer {
        for (hits) |*entry| vendor.freeAgentMemory(allocator, entry);
        allocator.free(hits);
    }
    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectEqualStrings("team.rule", hits[0].key);

    var session_team = try engine.store(allocator, .{
        .key = "team.rule",
        .content = "Session scoped team alpha notes still require citations",
        .category = "preference",
        .session_id = "session-1",
        .owner_actor_id = "shared:team:alpha",
        .writer_actor_id = "agent:a",
        .requested_scope = "team:alpha",
        .requested_permissions_json = "[\"team:alpha\"]",
        .timestamp_ms = 12,
    });
    defer vendor.freeAgentMemory(allocator, &session_team);
    try std.testing.expect(try engine.deleteAll("team.rule", "shared:team:alpha", "agent:a"));
    const after_delete = try engine.searchAnyVisible(allocator, "citations", 5, "[\"team:alpha\"]", "agent:b");
    defer {
        for (after_delete) |*entry| vendor.freeAgentMemory(allocator, entry);
        allocator.free(after_delete);
    }
    try std.testing.expectEqual(@as(usize, 0), after_delete.len);
}

test "holographic applies deterministic reducers and trust status" {
    const allocator = std.testing.allocator;
    const path = try tmpDbPath(allocator, "holographic-reducer");
    defer allocator.free(path);
    defer deleteSqliteTestFiles(allocator, path);

    var engine = try Engine.init(allocator, .{ .db_path = path, .default_trust = 0.4, .trust_reward = 0.2 });
    defer engine.deinit();

    var first = try engine.store(allocator, .{
        .key = "traits",
        .content = "[\"zig\"]",
        .owner_actor_id = "agent:a",
        .writer_actor_id = "agent:a",
        .operation = .merge_string_set,
        .timestamp_ms = 20,
    });
    defer vendor.freeAgentMemory(allocator, &first);

    var second = try engine.store(allocator, .{
        .key = "traits",
        .content = "[\"sqlite\",\"zig\"]",
        .owner_actor_id = "agent:a",
        .writer_actor_id = "agent:a",
        .operation = .merge_string_set,
        .timestamp_ms = 21,
    });
    defer vendor.freeAgentMemory(allocator, &second);
    try std.testing.expectEqualStrings("[\"sqlite\",\"zig\"]", second.content);

    try std.testing.expect(try engine.patchStatus(allocator, "traits", null, "agent:a", "verified", "agent:a"));
    var after = (try engine.get(allocator, "traits", null, "agent:a")).?;
    defer vendor.freeAgentMemory(allocator, &after);
    try std.testing.expect((after.score orelse 0) > (second.score orelse 0));
}

test "holographic associative signature folds token case" {
    const allocator = std.testing.allocator;
    const upper = try hrrSignature(allocator, "Zig", "SQLite Notes", "Preference");
    defer allocator.free(upper);
    const lower = try hrrSignature(allocator, "zig", "sqlite notes", "preference");
    defer allocator.free(lower);

    try std.testing.expectEqualStrings(upper, lower);
    try std.testing.expect(signatureCosine(upper, lower) > 0.99);
}

test "holographic search candidate limit uses checked bounded expansion" {
    try std.testing.expectEqual(@as(usize, 0), holographicSearchCandidateLimit(0));
    try std.testing.expectEqual(@as(usize, 20), holographicSearchCandidateLimit(1));
    try std.testing.expectEqual(@as(usize, 5000), holographicSearchCandidateLimit(250));
    try std.testing.expectEqual(@as(usize, 5000), holographicSearchCandidateLimit(251));
    try std.testing.expectEqual(@as(usize, 5000), holographicSearchCandidateLimit(std.math.maxInt(usize)));
}
