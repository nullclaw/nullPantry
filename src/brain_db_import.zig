const std = @import("std");

const bounded_int = @import("bounded_int.zig");
const vector = @import("vector.zig");

const c = @cImport({
    @cInclude("sqlite3.h");
});

const SQLITE_STATIC: c.sqlite3_destructor_type = null;

pub const Options = struct {
    limit: usize = 10_000,
    max_value_bytes: usize = 4 * 1024 * 1024,
    max_total_bytes: usize = 64 * 1024 * 1024,
};

const ReadBudget = struct {
    remaining: usize,
    max_value_bytes: usize,
};

pub const Entry = struct {
    key: []u8,
    content: []u8,
    category: []u8,
    session_id: ?[]u8 = null,
    created_at: ?[]u8 = null,
    updated_at: ?[]u8 = null,
};

pub const MessageEntry = struct {
    session_id: []u8,
    role: []u8,
    content: []u8,
    created_at: ?[]u8 = null,
};

pub const UsageEntry = struct {
    session_id: []u8,
    total_tokens: u64,
    updated_at: ?[]u8 = null,
};

pub const SessionEntry = struct {
    session_id: []u8,
    provider: ?[]u8 = null,
    model: ?[]u8 = null,
    created_at: ?[]u8 = null,
    updated_at: ?[]u8 = null,
};

pub const KvEntry = struct {
    key: []u8,
    value: []u8,
};

pub const EmbeddingCacheEntry = struct {
    content_hash: []u8,
    embedding_json: []u8,
    dimensions: usize,
    created_at: ?[]u8 = null,
};

pub const MemoryEmbeddingEntry = struct {
    memory_key: []u8,
    embedding_json: []u8,
    dimensions: usize,
    updated_at: ?[]u8 = null,
};

pub const Result = struct {
    entries: []Entry,
    messages: []MessageEntry = &.{},
    usages: []UsageEntry = &.{},
    sessions: []SessionEntry = &.{},
    kvs: []KvEntry = &.{},
    embedding_cache_entries: []EmbeddingCacheEntry = &.{},
    memory_embeddings: []MemoryEmbeddingEntry = &.{},
    skipped_empty_content: usize = 0,
    skipped_empty_messages: usize = 0,
    skipped_empty_sessions: usize = 0,
    skipped_empty_kv: usize = 0,
    skipped_empty_embedding_cache: usize = 0,
    skipped_invalid_embedding_cache: usize = 0,
    skipped_empty_memory_embeddings: usize = 0,
    skipped_invalid_memory_embeddings: usize = 0,
    truncated: bool = false,
    messages_truncated: bool = false,
    usages_truncated: bool = false,
    sessions_truncated: bool = false,
    kvs_truncated: bool = false,
    embedding_cache_truncated: bool = false,
    memory_embeddings_truncated: bool = false,

    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        freeEntries(allocator, self.entries);
        freeMessages(allocator, self.messages);
        freeUsages(allocator, self.usages);
        freeSessions(allocator, self.sessions);
        freeKvs(allocator, self.kvs);
        freeEmbeddingCacheEntries(allocator, self.embedding_cache_entries);
        freeMemoryEmbeddings(allocator, self.memory_embeddings);
    }
};

pub fn freeEntries(allocator: std.mem.Allocator, entries: []Entry) void {
    for (entries) |entry| {
        allocator.free(entry.key);
        allocator.free(entry.content);
        allocator.free(entry.category);
        if (entry.session_id) |value| allocator.free(value);
        if (entry.created_at) |value| allocator.free(value);
        if (entry.updated_at) |value| allocator.free(value);
    }
    allocator.free(entries);
}

pub fn freeMessages(allocator: std.mem.Allocator, messages: []MessageEntry) void {
    for (messages) |message| {
        allocator.free(message.session_id);
        allocator.free(message.role);
        allocator.free(message.content);
        if (message.created_at) |value| allocator.free(value);
    }
    allocator.free(messages);
}

pub fn freeUsages(allocator: std.mem.Allocator, usages: []UsageEntry) void {
    for (usages) |usage| {
        allocator.free(usage.session_id);
        if (usage.updated_at) |value| allocator.free(value);
    }
    allocator.free(usages);
}

pub fn freeSessions(allocator: std.mem.Allocator, sessions: []SessionEntry) void {
    for (sessions) |session| {
        allocator.free(session.session_id);
        if (session.provider) |value| allocator.free(value);
        if (session.model) |value| allocator.free(value);
        if (session.created_at) |value| allocator.free(value);
        if (session.updated_at) |value| allocator.free(value);
    }
    allocator.free(sessions);
}

pub fn freeKvs(allocator: std.mem.Allocator, kvs: []KvEntry) void {
    for (kvs) |kv| {
        allocator.free(kv.key);
        allocator.free(kv.value);
    }
    allocator.free(kvs);
}

pub fn freeEmbeddingCacheEntries(allocator: std.mem.Allocator, entries: []EmbeddingCacheEntry) void {
    for (entries) |entry| {
        allocator.free(entry.content_hash);
        allocator.free(entry.embedding_json);
        if (entry.created_at) |value| allocator.free(value);
    }
    allocator.free(entries);
}

pub fn freeMemoryEmbeddings(allocator: std.mem.Allocator, entries: []MemoryEmbeddingEntry) void {
    for (entries) |entry| {
        allocator.free(entry.memory_key);
        allocator.free(entry.embedding_json);
        if (entry.updated_at) |value| allocator.free(value);
    }
    allocator.free(entries);
}

pub fn read(allocator: std.mem.Allocator, path: []const u8, options: Options) !Result {
    const z_path = try allocator.dupeZ(u8, path);
    defer allocator.free(z_path);
    return readZ(allocator, z_path, options);
}

pub fn readZ(allocator: std.mem.Allocator, path: [:0]const u8, options: Options) !Result {
    var db: ?*c.sqlite3 = null;
    if (c.sqlite3_open_v2(path.ptr, &db, c.SQLITE_OPEN_READONLY, null) != c.SQLITE_OK) {
        if (db) |handle| _ = c.sqlite3_close(handle);
        return error.OpenFailed;
    }
    defer _ = c.sqlite3_close(db.?);

    if (!(try tableExists(db.?, "memories"))) return error.NoMemoriesTable;
    const columns = try detectColumns(allocator, db.?);
    const content_expr = columns.contentExpr() orelse return error.NoContentColumn;
    var budget = ReadBudget{ .remaining = options.max_total_bytes, .max_value_bytes = options.max_value_bytes };

    const query_raw = try std.fmt.allocPrint(
        allocator,
        "SELECT CAST({s} AS TEXT), CAST({s} AS TEXT), CAST({s} AS TEXT), CAST({s} AS TEXT), CAST({s} AS TEXT), CAST({s} AS TEXT) FROM memories ORDER BY rowid LIMIT ?",
        .{ columns.keyExpr(), content_expr, columns.categoryExpr(), columns.sessionExpr(), columns.createdAtExpr(), columns.updatedAtExpr() },
    );
    defer allocator.free(query_raw);
    const query = try allocator.dupeZ(u8, query_raw);
    defer allocator.free(query);

    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db.?, query.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.QueryFailed;
    defer _ = c.sqlite3_finalize(stmt);

    const limit = options.limit;
    _ = c.sqlite3_bind_int64(stmt, 1, sqlitePreviewLimit(limit));

    var out: std.ArrayListUnmanaged(Entry) = .empty;
    errdefer {
        for (out.items) |entry| {
            allocator.free(entry.key);
            allocator.free(entry.content);
            allocator.free(entry.category);
            if (entry.session_id) |value| allocator.free(value);
            if (entry.created_at) |value| allocator.free(value);
            if (entry.updated_at) |value| allocator.free(value);
        }
        out.deinit(allocator);
    }

    var result = Result{ .entries = &.{} };
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return error.QueryFailed;

        if (out.items.len >= limit) {
            result.truncated = true;
            break;
        }

        if (columnBytes(stmt.?, 1) == 0) {
            result.skipped_empty_content += 1;
            continue;
        }

        const key = try columnTextAllocBudget(allocator, stmt.?, 0, &budget);
        errdefer allocator.free(key);
        const content = try columnTextAllocBudget(allocator, stmt.?, 1, &budget);
        errdefer allocator.free(content);
        const category = try nonEmptyColumnTextOrBudget(allocator, stmt.?, 2, "core", &budget);
        errdefer allocator.free(category);
        const session_id = try nonEmptyColumnTextNullableBudget(allocator, stmt.?, 3, &budget);
        errdefer if (session_id) |value| allocator.free(value);
        const created_at = try nonEmptyColumnTextNullableBudget(allocator, stmt.?, 4, &budget);
        errdefer if (created_at) |value| allocator.free(value);
        const updated_at = try nonEmptyColumnTextNullableBudget(allocator, stmt.?, 5, &budget);
        errdefer if (updated_at) |value| allocator.free(value);

        try out.append(allocator, .{
            .key = key,
            .content = content,
            .category = category,
            .session_id = session_id,
            .created_at = created_at,
            .updated_at = updated_at,
        });
    }

    result.entries = try out.toOwnedSlice(allocator);
    errdefer freeEntries(allocator, result.entries);

    var messages_owned = false;
    errdefer if (messages_owned) freeMessages(allocator, result.messages);
    if (try tableExists(db.?, "messages")) {
        const messages = try readMessages(allocator, db.?, options.limit, &budget);
        result.messages = messages.entries;
        result.skipped_empty_messages = messages.skipped_empty;
        result.messages_truncated = messages.truncated;
        messages_owned = true;
    }

    var usages_owned = false;
    errdefer if (usages_owned) freeUsages(allocator, result.usages);
    if (try tableExists(db.?, "session_usage")) {
        const usages = try readUsages(allocator, db.?, options.limit, &budget);
        result.usages = usages.entries;
        result.usages_truncated = usages.truncated;
        usages_owned = true;
    }

    var sessions_owned = false;
    errdefer if (sessions_owned) freeSessions(allocator, result.sessions);
    if (try tableExists(db.?, "sessions")) {
        const sessions = try readSessions(allocator, db.?, options.limit, &budget);
        result.sessions = sessions.entries;
        result.skipped_empty_sessions = sessions.skipped_empty;
        result.sessions_truncated = sessions.truncated;
        sessions_owned = true;
    }

    var kvs_owned = false;
    errdefer if (kvs_owned) freeKvs(allocator, result.kvs);
    if (try tableExists(db.?, "kv")) {
        const kvs = try readKvs(allocator, db.?, options.limit, &budget);
        result.kvs = kvs.entries;
        result.skipped_empty_kv = kvs.skipped_empty;
        result.kvs_truncated = kvs.truncated;
        kvs_owned = true;
    }

    var embedding_cache_owned = false;
    errdefer if (embedding_cache_owned) freeEmbeddingCacheEntries(allocator, result.embedding_cache_entries);
    if (try tableExists(db.?, "embedding_cache")) {
        const cache_entries = try readEmbeddingCacheEntries(allocator, db.?, options.limit, &budget);
        result.embedding_cache_entries = cache_entries.entries;
        result.skipped_empty_embedding_cache = cache_entries.skipped_empty;
        result.skipped_invalid_embedding_cache = cache_entries.skipped_invalid;
        result.embedding_cache_truncated = cache_entries.truncated;
        embedding_cache_owned = true;
    }

    var memory_embeddings_owned = false;
    errdefer if (memory_embeddings_owned) freeMemoryEmbeddings(allocator, result.memory_embeddings);
    if (try tableExists(db.?, "memory_embeddings")) {
        const embeddings = try readMemoryEmbeddings(allocator, db.?, options.limit, &budget);
        result.memory_embeddings = embeddings.entries;
        result.skipped_empty_memory_embeddings = embeddings.skipped_empty;
        result.skipped_invalid_memory_embeddings = embeddings.skipped_invalid;
        result.memory_embeddings_truncated = embeddings.truncated;
        memory_embeddings_owned = true;
    }
    return result;
}

const ColumnSet = struct {
    key: bool = false,
    id: bool = false,
    name: bool = false,
    content: bool = false,
    value: bool = false,
    text: bool = false,
    memory: bool = false,
    category: bool = false,
    kind: bool = false,
    type_col: bool = false,
    session_id: bool = false,
    session: bool = false,
    sid: bool = false,
    created_at: bool = false,
    updated_at: bool = false,

    fn mark(self: *ColumnSet, name: []const u8) void {
        if (std.mem.eql(u8, name, "key")) self.key = true;
        if (std.mem.eql(u8, name, "id")) self.id = true;
        if (std.mem.eql(u8, name, "name")) self.name = true;
        if (std.mem.eql(u8, name, "content")) self.content = true;
        if (std.mem.eql(u8, name, "value")) self.value = true;
        if (std.mem.eql(u8, name, "text")) self.text = true;
        if (std.mem.eql(u8, name, "memory")) self.memory = true;
        if (std.mem.eql(u8, name, "category")) self.category = true;
        if (std.mem.eql(u8, name, "kind")) self.kind = true;
        if (std.mem.eql(u8, name, "type")) self.type_col = true;
        if (std.mem.eql(u8, name, "session_id")) self.session_id = true;
        if (std.mem.eql(u8, name, "session")) self.session = true;
        if (std.mem.eql(u8, name, "sid")) self.sid = true;
        if (std.mem.eql(u8, name, "created_at")) self.created_at = true;
        if (std.mem.eql(u8, name, "updated_at")) self.updated_at = true;
    }

    fn keyExpr(self: ColumnSet) []const u8 {
        if (self.key) return "\"key\"";
        if (self.id) return "\"id\"";
        if (self.name) return "\"name\"";
        return "rowid";
    }

    fn contentExpr(self: ColumnSet) ?[]const u8 {
        if (self.content) return "\"content\"";
        if (self.value) return "\"value\"";
        if (self.text) return "\"text\"";
        if (self.memory) return "\"memory\"";
        return null;
    }

    fn categoryExpr(self: ColumnSet) []const u8 {
        if (self.category) return "\"category\"";
        if (self.kind) return "\"kind\"";
        if (self.type_col) return "\"type\"";
        return "'core'";
    }

    fn sessionExpr(self: ColumnSet) []const u8 {
        if (self.session_id) return "\"session_id\"";
        if (self.session) return "\"session\"";
        if (self.sid) return "\"sid\"";
        return "NULL";
    }

    fn createdAtExpr(self: ColumnSet) []const u8 {
        if (self.created_at) return "\"created_at\"";
        return "NULL";
    }

    fn updatedAtExpr(self: ColumnSet) []const u8 {
        if (self.updated_at) return "\"updated_at\"";
        return "NULL";
    }
};

const MessageReadResult = struct {
    entries: []MessageEntry,
    skipped_empty: usize = 0,
    truncated: bool = false,
};

const UsageReadResult = struct {
    entries: []UsageEntry,
    truncated: bool = false,
};

const SessionReadResult = struct {
    entries: []SessionEntry,
    skipped_empty: usize = 0,
    truncated: bool = false,
};

const KvReadResult = struct {
    entries: []KvEntry,
    skipped_empty: usize = 0,
    truncated: bool = false,
};

const EmbeddingCacheReadResult = struct {
    entries: []EmbeddingCacheEntry,
    skipped_empty: usize = 0,
    skipped_invalid: usize = 0,
    truncated: bool = false,
};

const MemoryEmbeddingReadResult = struct {
    entries: []MemoryEmbeddingEntry,
    skipped_empty: usize = 0,
    skipped_invalid: usize = 0,
    truncated: bool = false,
};

const MessageColumnSet = struct {
    session_id: bool = false,
    session: bool = false,
    sid: bool = false,
    role: bool = false,
    content: bool = false,
    message: bool = false,
    text: bool = false,
    created_at: bool = false,
    timestamp: bool = false,

    fn mark(self: *MessageColumnSet, name: []const u8) void {
        if (std.mem.eql(u8, name, "session_id")) self.session_id = true;
        if (std.mem.eql(u8, name, "session")) self.session = true;
        if (std.mem.eql(u8, name, "sid")) self.sid = true;
        if (std.mem.eql(u8, name, "role")) self.role = true;
        if (std.mem.eql(u8, name, "content")) self.content = true;
        if (std.mem.eql(u8, name, "message")) self.message = true;
        if (std.mem.eql(u8, name, "text")) self.text = true;
        if (std.mem.eql(u8, name, "created_at")) self.created_at = true;
        if (std.mem.eql(u8, name, "timestamp")) self.timestamp = true;
    }

    fn sessionExpr(self: MessageColumnSet) ?[]const u8 {
        if (self.session_id) return "\"session_id\"";
        if (self.session) return "\"session\"";
        if (self.sid) return "\"sid\"";
        return null;
    }

    fn roleExpr(self: MessageColumnSet) []const u8 {
        if (self.role) return "\"role\"";
        return "'user'";
    }

    fn contentExpr(self: MessageColumnSet) ?[]const u8 {
        if (self.content) return "\"content\"";
        if (self.message) return "\"message\"";
        if (self.text) return "\"text\"";
        return null;
    }

    fn createdAtExpr(self: MessageColumnSet) []const u8 {
        if (self.created_at) return "\"created_at\"";
        if (self.timestamp) return "\"timestamp\"";
        return "NULL";
    }
};

const UsageColumnSet = struct {
    session_id: bool = false,
    session: bool = false,
    sid: bool = false,
    total_tokens: bool = false,
    tokens: bool = false,
    usage: bool = false,
    updated_at: bool = false,

    fn mark(self: *UsageColumnSet, name: []const u8) void {
        if (std.mem.eql(u8, name, "session_id")) self.session_id = true;
        if (std.mem.eql(u8, name, "session")) self.session = true;
        if (std.mem.eql(u8, name, "sid")) self.sid = true;
        if (std.mem.eql(u8, name, "total_tokens")) self.total_tokens = true;
        if (std.mem.eql(u8, name, "tokens")) self.tokens = true;
        if (std.mem.eql(u8, name, "usage")) self.usage = true;
        if (std.mem.eql(u8, name, "updated_at")) self.updated_at = true;
    }

    fn sessionExpr(self: UsageColumnSet) ?[]const u8 {
        if (self.session_id) return "\"session_id\"";
        if (self.session) return "\"session\"";
        if (self.sid) return "\"sid\"";
        return null;
    }

    fn totalExpr(self: UsageColumnSet) ?[]const u8 {
        if (self.total_tokens) return "\"total_tokens\"";
        if (self.tokens) return "\"tokens\"";
        if (self.usage) return "\"usage\"";
        return null;
    }

    fn updatedAtExpr(self: UsageColumnSet) []const u8 {
        if (self.updated_at) return "\"updated_at\"";
        return "NULL";
    }
};

const SessionColumnSet = struct {
    id: bool = false,
    session_id: bool = false,
    session: bool = false,
    sid: bool = false,
    provider: bool = false,
    model: bool = false,
    created_at: bool = false,
    updated_at: bool = false,

    fn mark(self: *SessionColumnSet, name: []const u8) void {
        if (std.mem.eql(u8, name, "id")) self.id = true;
        if (std.mem.eql(u8, name, "session_id")) self.session_id = true;
        if (std.mem.eql(u8, name, "session")) self.session = true;
        if (std.mem.eql(u8, name, "sid")) self.sid = true;
        if (std.mem.eql(u8, name, "provider")) self.provider = true;
        if (std.mem.eql(u8, name, "model")) self.model = true;
        if (std.mem.eql(u8, name, "created_at")) self.created_at = true;
        if (std.mem.eql(u8, name, "updated_at")) self.updated_at = true;
    }

    fn idExpr(self: SessionColumnSet) ?[]const u8 {
        if (self.id) return "\"id\"";
        if (self.session_id) return "\"session_id\"";
        if (self.session) return "\"session\"";
        if (self.sid) return "\"sid\"";
        return null;
    }

    fn providerExpr(self: SessionColumnSet) []const u8 {
        if (self.provider) return "\"provider\"";
        return "NULL";
    }

    fn modelExpr(self: SessionColumnSet) []const u8 {
        if (self.model) return "\"model\"";
        return "NULL";
    }

    fn createdAtExpr(self: SessionColumnSet) []const u8 {
        if (self.created_at) return "\"created_at\"";
        return "NULL";
    }

    fn updatedAtExpr(self: SessionColumnSet) []const u8 {
        if (self.updated_at) return "\"updated_at\"";
        return "NULL";
    }
};

const KvColumnSet = struct {
    key: bool = false,
    id: bool = false,
    name: bool = false,
    value: bool = false,
    content: bool = false,
    text: bool = false,

    fn mark(self: *KvColumnSet, name: []const u8) void {
        if (std.mem.eql(u8, name, "key")) self.key = true;
        if (std.mem.eql(u8, name, "id")) self.id = true;
        if (std.mem.eql(u8, name, "name")) self.name = true;
        if (std.mem.eql(u8, name, "value")) self.value = true;
        if (std.mem.eql(u8, name, "content")) self.content = true;
        if (std.mem.eql(u8, name, "text")) self.text = true;
    }

    fn keyExpr(self: KvColumnSet) ?[]const u8 {
        if (self.key) return "\"key\"";
        if (self.id) return "\"id\"";
        if (self.name) return "\"name\"";
        return null;
    }

    fn valueExpr(self: KvColumnSet) ?[]const u8 {
        if (self.value) return "\"value\"";
        if (self.content) return "\"content\"";
        if (self.text) return "\"text\"";
        return null;
    }
};

const EmbeddingCacheColumnSet = struct {
    content_hash: bool = false,
    cache_key: bool = false,
    hash: bool = false,
    embedding: bool = false,
    embedding_json: bool = false,
    created_at: bool = false,

    fn mark(self: *EmbeddingCacheColumnSet, name: []const u8) void {
        if (std.mem.eql(u8, name, "content_hash")) self.content_hash = true;
        if (std.mem.eql(u8, name, "cache_key")) self.cache_key = true;
        if (std.mem.eql(u8, name, "hash")) self.hash = true;
        if (std.mem.eql(u8, name, "embedding")) self.embedding = true;
        if (std.mem.eql(u8, name, "embedding_json")) self.embedding_json = true;
        if (std.mem.eql(u8, name, "created_at")) self.created_at = true;
    }

    fn keyExpr(self: EmbeddingCacheColumnSet) ?[]const u8 {
        if (self.content_hash) return "\"content_hash\"";
        if (self.cache_key) return "\"cache_key\"";
        if (self.hash) return "\"hash\"";
        return null;
    }

    fn embeddingExpr(self: EmbeddingCacheColumnSet) ?[]const u8 {
        if (self.embedding_json) return "\"embedding_json\"";
        if (self.embedding) return "\"embedding\"";
        return null;
    }

    fn createdAtExpr(self: EmbeddingCacheColumnSet) []const u8 {
        if (self.created_at) return "\"created_at\"";
        return "NULL";
    }
};

const MemoryEmbeddingColumnSet = struct {
    memory_key: bool = false,
    key: bool = false,
    object_id: bool = false,
    embedding: bool = false,
    embedding_json: bool = false,
    updated_at: bool = false,

    fn mark(self: *MemoryEmbeddingColumnSet, name: []const u8) void {
        if (std.mem.eql(u8, name, "memory_key")) self.memory_key = true;
        if (std.mem.eql(u8, name, "key")) self.key = true;
        if (std.mem.eql(u8, name, "object_id")) self.object_id = true;
        if (std.mem.eql(u8, name, "embedding")) self.embedding = true;
        if (std.mem.eql(u8, name, "embedding_json")) self.embedding_json = true;
        if (std.mem.eql(u8, name, "updated_at")) self.updated_at = true;
    }

    fn keyExpr(self: MemoryEmbeddingColumnSet) ?[]const u8 {
        if (self.memory_key) return "\"memory_key\"";
        if (self.key) return "\"key\"";
        if (self.object_id) return "\"object_id\"";
        return null;
    }

    fn embeddingExpr(self: MemoryEmbeddingColumnSet) ?[]const u8 {
        if (self.embedding_json) return "\"embedding_json\"";
        if (self.embedding) return "\"embedding\"";
        return null;
    }

    fn updatedAtExpr(self: MemoryEmbeddingColumnSet) []const u8 {
        if (self.updated_at) return "\"updated_at\"";
        return "NULL";
    }
};

fn readMessages(allocator: std.mem.Allocator, db: *c.sqlite3, limit: usize, budget: *ReadBudget) !MessageReadResult {
    const columns = try detectMessageColumns(allocator, db);
    const session_expr = columns.sessionExpr() orelse return .{ .entries = &.{} };
    const content_expr = columns.contentExpr() orelse return .{ .entries = &.{} };

    const query_raw = try std.fmt.allocPrint(
        allocator,
        "SELECT CAST({s} AS TEXT), CAST({s} AS TEXT), CAST({s} AS TEXT), CAST({s} AS TEXT) FROM messages ORDER BY rowid LIMIT ?",
        .{ session_expr, columns.roleExpr(), content_expr, columns.createdAtExpr() },
    );
    defer allocator.free(query_raw);
    const query = try allocator.dupeZ(u8, query_raw);
    defer allocator.free(query);

    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, query.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.QueryFailed;
    defer _ = c.sqlite3_finalize(stmt);

    _ = c.sqlite3_bind_int64(stmt, 1, sqlitePreviewLimit(limit));

    var out: std.ArrayListUnmanaged(MessageEntry) = .empty;
    errdefer {
        for (out.items) |message| {
            allocator.free(message.session_id);
            allocator.free(message.role);
            allocator.free(message.content);
            if (message.created_at) |value| allocator.free(value);
        }
        out.deinit(allocator);
    }

    var result = MessageReadResult{ .entries = &.{} };
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return error.QueryFailed;
        if (out.items.len >= limit) {
            result.truncated = true;
            break;
        }
        if (columnBytes(stmt.?, 0) == 0 or columnBytes(stmt.?, 2) == 0) {
            result.skipped_empty += 1;
            continue;
        }
        const session_id = try columnTextAllocBudget(allocator, stmt.?, 0, budget);
        errdefer allocator.free(session_id);
        const role = try nonEmptyColumnTextOrBudget(allocator, stmt.?, 1, "user", budget);
        errdefer allocator.free(role);
        const content = try columnTextAllocBudget(allocator, stmt.?, 2, budget);
        errdefer allocator.free(content);
        const created_at = try nonEmptyColumnTextNullableBudget(allocator, stmt.?, 3, budget);
        errdefer if (created_at) |value| allocator.free(value);
        try out.append(allocator, .{
            .session_id = session_id,
            .role = role,
            .content = content,
            .created_at = created_at,
        });
    }

    result.entries = try out.toOwnedSlice(allocator);
    return result;
}

fn readUsages(allocator: std.mem.Allocator, db: *c.sqlite3, limit: usize, budget: *ReadBudget) !UsageReadResult {
    const columns = try detectUsageColumns(allocator, db);
    const session_expr = columns.sessionExpr() orelse return .{ .entries = &.{} };
    const total_expr = columns.totalExpr() orelse return .{ .entries = &.{} };

    const query_raw = try std.fmt.allocPrint(
        allocator,
        "SELECT CAST({s} AS TEXT), {s}, CAST({s} AS TEXT) FROM session_usage ORDER BY rowid LIMIT ?",
        .{ session_expr, total_expr, columns.updatedAtExpr() },
    );
    defer allocator.free(query_raw);
    const query = try allocator.dupeZ(u8, query_raw);
    defer allocator.free(query);

    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, query.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.QueryFailed;
    defer _ = c.sqlite3_finalize(stmt);

    _ = c.sqlite3_bind_int64(stmt, 1, sqlitePreviewLimit(limit));

    var out: std.ArrayListUnmanaged(UsageEntry) = .empty;
    errdefer {
        for (out.items) |usage| {
            allocator.free(usage.session_id);
            if (usage.updated_at) |value| allocator.free(value);
        }
        out.deinit(allocator);
    }

    var result = UsageReadResult{ .entries = &.{} };
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return error.QueryFailed;
        if (out.items.len >= limit) {
            result.truncated = true;
            break;
        }
        if (columnBytes(stmt.?, 0) == 0) continue;
        const session_id = try columnTextAllocBudget(allocator, stmt.?, 0, budget);
        errdefer allocator.free(session_id);
        const raw_total = c.sqlite3_column_int64(stmt.?, 1);
        const total_tokens: u64 = if (raw_total < 0) 0 else @intCast(raw_total);
        const updated_at = try nonEmptyColumnTextNullableBudget(allocator, stmt.?, 2, budget);
        errdefer if (updated_at) |value| allocator.free(value);
        try out.append(allocator, .{
            .session_id = session_id,
            .total_tokens = total_tokens,
            .updated_at = updated_at,
        });
    }

    result.entries = try out.toOwnedSlice(allocator);
    return result;
}

fn readSessions(allocator: std.mem.Allocator, db: *c.sqlite3, limit: usize, budget: *ReadBudget) !SessionReadResult {
    const columns = try detectSessionColumns(allocator, db);
    const id_expr = columns.idExpr() orelse return .{ .entries = &.{} };

    const query_raw = try std.fmt.allocPrint(
        allocator,
        "SELECT CAST({s} AS TEXT), CAST({s} AS TEXT), CAST({s} AS TEXT), CAST({s} AS TEXT), CAST({s} AS TEXT) FROM sessions ORDER BY rowid LIMIT ?",
        .{ id_expr, columns.providerExpr(), columns.modelExpr(), columns.createdAtExpr(), columns.updatedAtExpr() },
    );
    defer allocator.free(query_raw);
    const query = try allocator.dupeZ(u8, query_raw);
    defer allocator.free(query);

    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, query.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.QueryFailed;
    defer _ = c.sqlite3_finalize(stmt);

    _ = c.sqlite3_bind_int64(stmt, 1, sqlitePreviewLimit(limit));

    var out: std.ArrayListUnmanaged(SessionEntry) = .empty;
    errdefer {
        for (out.items) |session| {
            allocator.free(session.session_id);
            if (session.provider) |value| allocator.free(value);
            if (session.model) |value| allocator.free(value);
            if (session.created_at) |value| allocator.free(value);
            if (session.updated_at) |value| allocator.free(value);
        }
        out.deinit(allocator);
    }

    var result = SessionReadResult{ .entries = &.{} };
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return error.QueryFailed;
        if (out.items.len >= limit) {
            result.truncated = true;
            break;
        }
        if (columnBytes(stmt.?, 0) == 0) {
            result.skipped_empty += 1;
            continue;
        }
        const session_id = try columnTextAllocBudget(allocator, stmt.?, 0, budget);
        errdefer allocator.free(session_id);
        const provider = try nonEmptyColumnTextNullableBudget(allocator, stmt.?, 1, budget);
        errdefer if (provider) |value| allocator.free(value);
        const model = try nonEmptyColumnTextNullableBudget(allocator, stmt.?, 2, budget);
        errdefer if (model) |value| allocator.free(value);
        const created_at = try nonEmptyColumnTextNullableBudget(allocator, stmt.?, 3, budget);
        errdefer if (created_at) |value| allocator.free(value);
        const updated_at = try nonEmptyColumnTextNullableBudget(allocator, stmt.?, 4, budget);
        errdefer if (updated_at) |value| allocator.free(value);
        try out.append(allocator, .{
            .session_id = session_id,
            .provider = provider,
            .model = model,
            .created_at = created_at,
            .updated_at = updated_at,
        });
    }

    result.entries = try out.toOwnedSlice(allocator);
    return result;
}

fn readKvs(allocator: std.mem.Allocator, db: *c.sqlite3, limit: usize, budget: *ReadBudget) !KvReadResult {
    const columns = try detectKvColumns(allocator, db);
    const key_expr = columns.keyExpr() orelse return .{ .entries = &.{} };
    const value_expr = columns.valueExpr() orelse return .{ .entries = &.{} };

    const query_raw = try std.fmt.allocPrint(
        allocator,
        "SELECT CAST({s} AS TEXT), CAST({s} AS TEXT) FROM kv ORDER BY rowid LIMIT ?",
        .{ key_expr, value_expr },
    );
    defer allocator.free(query_raw);
    const query = try allocator.dupeZ(u8, query_raw);
    defer allocator.free(query);

    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, query.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.QueryFailed;
    defer _ = c.sqlite3_finalize(stmt);

    _ = c.sqlite3_bind_int64(stmt, 1, sqlitePreviewLimit(limit));

    var out: std.ArrayListUnmanaged(KvEntry) = .empty;
    errdefer {
        for (out.items) |kv| {
            allocator.free(kv.key);
            allocator.free(kv.value);
        }
        out.deinit(allocator);
    }

    var result = KvReadResult{ .entries = &.{} };
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return error.QueryFailed;
        if (out.items.len >= limit) {
            result.truncated = true;
            break;
        }
        if (columnBytes(stmt.?, 0) == 0) {
            result.skipped_empty += 1;
            continue;
        }
        const key = try columnTextAllocBudget(allocator, stmt.?, 0, budget);
        errdefer allocator.free(key);
        const value = try columnTextAllocBudget(allocator, stmt.?, 1, budget);
        errdefer allocator.free(value);
        try out.append(allocator, .{
            .key = key,
            .value = value,
        });
    }

    result.entries = try out.toOwnedSlice(allocator);
    return result;
}

fn readEmbeddingCacheEntries(allocator: std.mem.Allocator, db: *c.sqlite3, limit: usize, budget: *ReadBudget) !EmbeddingCacheReadResult {
    const columns = try detectEmbeddingCacheColumns(allocator, db);
    const key_expr = columns.keyExpr() orelse return .{ .entries = &.{} };
    const embedding_expr = columns.embeddingExpr() orelse return .{ .entries = &.{} };

    const query_raw = try std.fmt.allocPrint(
        allocator,
        "SELECT CAST({s} AS TEXT), {s}, CAST({s} AS TEXT) FROM embedding_cache ORDER BY rowid LIMIT ?",
        .{ key_expr, embedding_expr, columns.createdAtExpr() },
    );
    defer allocator.free(query_raw);
    const query = try allocator.dupeZ(u8, query_raw);
    defer allocator.free(query);

    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, query.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.QueryFailed;
    defer _ = c.sqlite3_finalize(stmt);

    _ = c.sqlite3_bind_int64(stmt, 1, sqlitePreviewLimit(limit));

    var out: std.ArrayListUnmanaged(EmbeddingCacheEntry) = .empty;
    errdefer {
        for (out.items) |entry| {
            allocator.free(entry.content_hash);
            allocator.free(entry.embedding_json);
            if (entry.created_at) |value| allocator.free(value);
        }
        out.deinit(allocator);
    }

    var result = EmbeddingCacheReadResult{ .entries = &.{} };
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return error.QueryFailed;
        if (out.items.len >= limit) {
            result.truncated = true;
            break;
        }
        if (columnBytes(stmt.?, 0) == 0 or columnBytes(stmt.?, 1) == 0) {
            result.skipped_empty += 1;
            continue;
        }
        const content_hash = try columnTextAllocBudget(allocator, stmt.?, 0, budget);
        errdefer allocator.free(content_hash);
        const embedding_blob = try columnBlobAllocBudget(allocator, stmt.?, 1, budget);
        defer allocator.free(embedding_blob);
        const normalized = embeddingJsonFromLegacyBlob(allocator, embedding_blob) catch {
            result.skipped_invalid += 1;
            allocator.free(content_hash);
            continue;
        };
        errdefer allocator.free(normalized.embedding_json);
        const created_at = try nonEmptyColumnTextNullableBudget(allocator, stmt.?, 2, budget);
        errdefer if (created_at) |value| allocator.free(value);
        try out.append(allocator, .{
            .content_hash = content_hash,
            .embedding_json = normalized.embedding_json,
            .dimensions = normalized.dimensions,
            .created_at = created_at,
        });
    }

    result.entries = try out.toOwnedSlice(allocator);
    return result;
}

fn readMemoryEmbeddings(allocator: std.mem.Allocator, db: *c.sqlite3, limit: usize, budget: *ReadBudget) !MemoryEmbeddingReadResult {
    const columns = try detectMemoryEmbeddingColumns(allocator, db);
    const key_expr = columns.keyExpr() orelse return .{ .entries = &.{} };
    const embedding_expr = columns.embeddingExpr() orelse return .{ .entries = &.{} };

    const query_raw = try std.fmt.allocPrint(
        allocator,
        "SELECT CAST({s} AS TEXT), {s}, CAST({s} AS TEXT) FROM memory_embeddings ORDER BY rowid LIMIT ?",
        .{ key_expr, embedding_expr, columns.updatedAtExpr() },
    );
    defer allocator.free(query_raw);
    const query = try allocator.dupeZ(u8, query_raw);
    defer allocator.free(query);

    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, query.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.QueryFailed;
    defer _ = c.sqlite3_finalize(stmt);

    _ = c.sqlite3_bind_int64(stmt, 1, sqlitePreviewLimit(limit));

    var out: std.ArrayListUnmanaged(MemoryEmbeddingEntry) = .empty;
    errdefer {
        for (out.items) |entry| {
            allocator.free(entry.memory_key);
            allocator.free(entry.embedding_json);
            if (entry.updated_at) |value| allocator.free(value);
        }
        out.deinit(allocator);
    }

    var result = MemoryEmbeddingReadResult{ .entries = &.{} };
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return error.QueryFailed;
        if (out.items.len >= limit) {
            result.truncated = true;
            break;
        }
        if (columnBytes(stmt.?, 0) == 0 or columnBytes(stmt.?, 1) == 0) {
            result.skipped_empty += 1;
            continue;
        }
        const memory_key = try columnTextAllocBudget(allocator, stmt.?, 0, budget);
        errdefer allocator.free(memory_key);
        const embedding_blob = try columnBlobAllocBudget(allocator, stmt.?, 1, budget);
        defer allocator.free(embedding_blob);
        const normalized = embeddingJsonFromLegacyBlob(allocator, embedding_blob) catch {
            result.skipped_invalid += 1;
            allocator.free(memory_key);
            continue;
        };
        errdefer allocator.free(normalized.embedding_json);
        const updated_at = try nonEmptyColumnTextNullableBudget(allocator, stmt.?, 2, budget);
        errdefer if (updated_at) |value| allocator.free(value);
        try out.append(allocator, .{
            .memory_key = memory_key,
            .embedding_json = normalized.embedding_json,
            .dimensions = normalized.dimensions,
            .updated_at = updated_at,
        });
    }

    result.entries = try out.toOwnedSlice(allocator);
    return result;
}

fn sqlitePreviewLimit(limit: usize) i64 {
    return bounded_int.usizeToI64Saturating(limit +| 1);
}

test "brain db import SQLite preview limits saturate to bindable i64" {
    try std.testing.expectEqual(@as(i64, 1), sqlitePreviewLimit(0));
    try std.testing.expectEqual(@as(i64, 101), sqlitePreviewLimit(100));

    if (std.math.cast(usize, std.math.maxInt(i64))) |max_i64_as_usize| {
        try std.testing.expectEqual(std.math.maxInt(i64), sqlitePreviewLimit(max_i64_as_usize));
    }

    try std.testing.expectEqual(std.math.maxInt(i64), sqlitePreviewLimit(std.math.maxInt(usize)));
}

fn tableExists(db: *c.sqlite3, name: []const u8) !bool {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, "SELECT 1 FROM sqlite_master WHERE type IN ('table','view') AND name = ? LIMIT 1", -1, &stmt, null) != c.SQLITE_OK) return error.QueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text64(stmt, 1, name.ptr, @intCast(bounded_int.usizeToU64Saturating(name.len)), SQLITE_STATIC, c.SQLITE_UTF8);
    const rc = c.sqlite3_step(stmt);
    if (rc == c.SQLITE_ROW) return true;
    if (rc == c.SQLITE_DONE) return false;
    return error.QueryFailed;
}

fn detectColumns(allocator: std.mem.Allocator, db: *c.sqlite3) !ColumnSet {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, "PRAGMA table_info(memories)", -1, &stmt, null) != c.SQLITE_OK) return error.QueryFailed;
    defer _ = c.sqlite3_finalize(stmt);

    var columns: ColumnSet = .{};
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return error.QueryFailed;
        const name = try columnTextAlloc(allocator, stmt.?, 1);
        defer allocator.free(name);
        columns.mark(name);
    }
    return columns;
}

fn detectMessageColumns(allocator: std.mem.Allocator, db: *c.sqlite3) !MessageColumnSet {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, "PRAGMA table_info(messages)", -1, &stmt, null) != c.SQLITE_OK) return error.QueryFailed;
    defer _ = c.sqlite3_finalize(stmt);

    var columns: MessageColumnSet = .{};
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return error.QueryFailed;
        const name = try columnTextAlloc(allocator, stmt.?, 1);
        defer allocator.free(name);
        columns.mark(name);
    }
    return columns;
}

fn detectUsageColumns(allocator: std.mem.Allocator, db: *c.sqlite3) !UsageColumnSet {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, "PRAGMA table_info(session_usage)", -1, &stmt, null) != c.SQLITE_OK) return error.QueryFailed;
    defer _ = c.sqlite3_finalize(stmt);

    var columns: UsageColumnSet = .{};
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return error.QueryFailed;
        const name = try columnTextAlloc(allocator, stmt.?, 1);
        defer allocator.free(name);
        columns.mark(name);
    }
    return columns;
}

fn detectSessionColumns(allocator: std.mem.Allocator, db: *c.sqlite3) !SessionColumnSet {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, "PRAGMA table_info(sessions)", -1, &stmt, null) != c.SQLITE_OK) return error.QueryFailed;
    defer _ = c.sqlite3_finalize(stmt);

    var columns: SessionColumnSet = .{};
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return error.QueryFailed;
        const name = try columnTextAlloc(allocator, stmt.?, 1);
        defer allocator.free(name);
        columns.mark(name);
    }
    return columns;
}

fn detectKvColumns(allocator: std.mem.Allocator, db: *c.sqlite3) !KvColumnSet {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, "PRAGMA table_info(kv)", -1, &stmt, null) != c.SQLITE_OK) return error.QueryFailed;
    defer _ = c.sqlite3_finalize(stmt);

    var columns: KvColumnSet = .{};
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return error.QueryFailed;
        const name = try columnTextAlloc(allocator, stmt.?, 1);
        defer allocator.free(name);
        columns.mark(name);
    }
    return columns;
}

fn detectEmbeddingCacheColumns(allocator: std.mem.Allocator, db: *c.sqlite3) !EmbeddingCacheColumnSet {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, "PRAGMA table_info(embedding_cache)", -1, &stmt, null) != c.SQLITE_OK) return error.QueryFailed;
    defer _ = c.sqlite3_finalize(stmt);

    var columns: EmbeddingCacheColumnSet = .{};
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return error.QueryFailed;
        const name = try columnTextAlloc(allocator, stmt.?, 1);
        defer allocator.free(name);
        columns.mark(name);
    }
    return columns;
}

fn detectMemoryEmbeddingColumns(allocator: std.mem.Allocator, db: *c.sqlite3) !MemoryEmbeddingColumnSet {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, "PRAGMA table_info(memory_embeddings)", -1, &stmt, null) != c.SQLITE_OK) return error.QueryFailed;
    defer _ = c.sqlite3_finalize(stmt);

    var columns: MemoryEmbeddingColumnSet = .{};
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return error.QueryFailed;
        const name = try columnTextAlloc(allocator, stmt.?, 1);
        defer allocator.free(name);
        columns.mark(name);
    }
    return columns;
}

fn columnBytes(stmt: *c.sqlite3_stmt, index: c_int) usize {
    return sqliteColumnByteCount(c.sqlite3_column_bytes(stmt, index));
}

fn sqliteColumnByteCount(raw: c_int) usize {
    return bounded_int.nonNegativeCIntToUsize(raw);
}

fn reserveColumnBytes(stmt: *c.sqlite3_stmt, index: c_int, budget: *ReadBudget) !void {
    const len = columnBytes(stmt, index);
    if (len > budget.max_value_bytes or len > budget.remaining) return error.ValueTooLarge;
    budget.remaining -= len;
}

fn columnTextAlloc(allocator: std.mem.Allocator, stmt: *c.sqlite3_stmt, index: c_int) ![]u8 {
    const ptr = c.sqlite3_column_text(stmt, index) orelse return allocator.dupe(u8, "");
    const len = columnBytes(stmt, index);
    return allocator.dupe(u8, ptr[0..len]);
}

fn columnTextAllocBudget(allocator: std.mem.Allocator, stmt: *c.sqlite3_stmt, index: c_int, budget: *ReadBudget) ![]u8 {
    try reserveColumnBytes(stmt, index, budget);
    return columnTextAlloc(allocator, stmt, index);
}

fn columnBlobAlloc(allocator: std.mem.Allocator, stmt: *c.sqlite3_stmt, index: c_int) ![]u8 {
    const ptr = c.sqlite3_column_blob(stmt, index) orelse return allocator.dupe(u8, "");
    const len = columnBytes(stmt, index);
    return allocator.dupe(u8, @as([*]const u8, @ptrCast(ptr))[0..len]);
}

fn columnBlobAllocBudget(allocator: std.mem.Allocator, stmt: *c.sqlite3_stmt, index: c_int, budget: *ReadBudget) ![]u8 {
    try reserveColumnBytes(stmt, index, budget);
    return columnBlobAlloc(allocator, stmt, index);
}

fn nonEmptyColumnTextOr(allocator: std.mem.Allocator, stmt: *c.sqlite3_stmt, index: c_int, fallback: []const u8) ![]u8 {
    if (columnBytes(stmt, index) == 0) return allocator.dupe(u8, fallback);
    return columnTextAlloc(allocator, stmt, index);
}

fn nonEmptyColumnTextOrBudget(allocator: std.mem.Allocator, stmt: *c.sqlite3_stmt, index: c_int, fallback: []const u8, budget: *ReadBudget) ![]u8 {
    if (columnBytes(stmt, index) == 0) return allocator.dupe(u8, fallback);
    return columnTextAllocBudget(allocator, stmt, index, budget);
}

fn nonEmptyColumnTextNullable(allocator: std.mem.Allocator, stmt: *c.sqlite3_stmt, index: c_int) !?[]u8 {
    if (c.sqlite3_column_type(stmt, index) == c.SQLITE_NULL) return null;
    if (columnBytes(stmt, index) == 0) return null;
    const text = try columnTextAlloc(allocator, stmt, index);
    return text;
}

fn nonEmptyColumnTextNullableBudget(allocator: std.mem.Allocator, stmt: *c.sqlite3_stmt, index: c_int, budget: *ReadBudget) !?[]u8 {
    if (c.sqlite3_column_type(stmt, index) == c.SQLITE_NULL) return null;
    if (columnBytes(stmt, index) == 0) return null;
    const text = try columnTextAllocBudget(allocator, stmt, index, budget);
    return text;
}

const LegacyEmbeddingJson = struct {
    embedding_json: []u8,
    dimensions: usize,
};

fn embeddingJsonFromLegacyBlob(allocator: std.mem.Allocator, raw: []const u8) !LegacyEmbeddingJson {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidEmbedding;
    if (trimmed[0] == '[') {
        const parsed = try vector.embeddingFromJson(allocator, trimmed);
        defer allocator.free(parsed);
        const owned = try allocator.dupe(u8, trimmed);
        return .{ .embedding_json = owned, .dimensions = parsed.len };
    }
    if (raw.len % @sizeOf(f32) != 0) return error.InvalidEmbedding;
    const dimensions = raw.len / @sizeOf(f32);
    if (dimensions == 0) return error.InvalidEmbedding;
    const values = try allocator.alloc(f32, dimensions);
    defer allocator.free(values);
    for (0..dimensions) |i| {
        const chunk = raw[i * @sizeOf(f32) ..][0..@sizeOf(f32)];
        values[i] = @bitCast(chunk.*);
    }
    const embedding_json = try vector.embeddingToJson(allocator, values);
    return .{ .embedding_json = embedding_json, .dimensions = dimensions };
}

pub fn testingCreateDatabase(allocator: std.mem.Allocator, path: []const u8, sql: [:0]const u8) !void {
    const z_path = try allocator.dupeZ(u8, path);
    defer allocator.free(z_path);

    var db: ?*c.sqlite3 = null;
    const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE;
    if (c.sqlite3_open_v2(z_path.ptr, &db, flags, null) != c.SQLITE_OK) {
        if (db) |handle| _ = c.sqlite3_close(handle);
        return error.OpenFailed;
    }
    defer _ = c.sqlite3_close(db.?);

    var err_msg: [*c]u8 = null;
    const rc = c.sqlite3_exec(db.?, sql.ptr, null, null, &err_msg);
    if (rc != c.SQLITE_OK) {
        if (err_msg) |msg| c.sqlite3_free(msg);
        return error.QueryFailed;
    }
}

test "brain db import reads canonical nullclaw memories table" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/brain.db", .{tmp.sub_path});
    defer std.testing.allocator.free(path);

    try testingCreateDatabase(std.testing.allocator, path,
        \\CREATE TABLE memories(key TEXT, content TEXT, category TEXT, session_id TEXT, created_at TEXT, updated_at TEXT);
        \\INSERT INTO memories(key, content, category, session_id, created_at, updated_at) VALUES ('pref.lang', 'Use Zig examples', 'preference', 'sess-docs', '2026-05-01T10:00:00Z', '2026-05-02T10:00:00Z');
        \\INSERT INTO memories(key, content, category, session_id) VALUES ('empty.pref', '', 'preference', 'sess-docs');
        \\CREATE TABLE messages(id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL, role TEXT NOT NULL, content TEXT NOT NULL, created_at TEXT);
        \\INSERT INTO messages(session_id, role, content, created_at) VALUES ('sess-docs', 'user', 'How should docs look?', '1000');
        \\INSERT INTO messages(session_id, role, content, created_at) VALUES ('sess-docs', 'assistant', 'Use concise Zig examples.', '2000');
        \\CREATE TABLE session_usage(session_id TEXT PRIMARY KEY, total_tokens INTEGER NOT NULL, updated_at TEXT);
        \\INSERT INTO session_usage(session_id, total_tokens, updated_at) VALUES ('sess-docs', 1234, '3000');
        \\CREATE TABLE sessions(id TEXT PRIMARY KEY, provider TEXT, model TEXT, created_at TEXT, updated_at TEXT);
        \\INSERT INTO sessions(id, provider, model, created_at, updated_at) VALUES ('sess-docs', 'openai', 'gpt-5', '500', '600');
        \\CREATE TABLE kv(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        \\INSERT INTO kv(key, value) VALUES ('last_hygiene_at', '1772051598');
        \\CREATE TABLE embedding_cache(content_hash TEXT PRIMARY KEY, embedding BLOB NOT NULL, created_at TEXT);
        \\INSERT INTO embedding_cache(content_hash, embedding, created_at) VALUES ('hash:docs', '[1,0]', '700');
        \\CREATE TABLE memory_embeddings(memory_key TEXT PRIMARY KEY, embedding BLOB NOT NULL, updated_at TEXT);
        \\INSERT INTO memory_embeddings(memory_key, embedding, updated_at) VALUES ('pref.lang', x'0000803F00000000', '800');
    );

    const result = try read(std.testing.allocator, path, .{ .limit = 100 });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.entries.len);
    try std.testing.expectEqual(@as(usize, 1), result.skipped_empty_content);
    try std.testing.expectEqualStrings("pref.lang", result.entries[0].key);
    try std.testing.expectEqualStrings("Use Zig examples", result.entries[0].content);
    try std.testing.expectEqualStrings("preference", result.entries[0].category);
    try std.testing.expectEqualStrings("sess-docs", result.entries[0].session_id.?);
    try std.testing.expectEqualStrings("2026-05-01T10:00:00Z", result.entries[0].created_at.?);
    try std.testing.expectEqualStrings("2026-05-02T10:00:00Z", result.entries[0].updated_at.?);
    try std.testing.expectEqual(@as(usize, 2), result.messages.len);
    try std.testing.expectEqualStrings("sess-docs", result.messages[0].session_id);
    try std.testing.expectEqualStrings("user", result.messages[0].role);
    try std.testing.expectEqualStrings("How should docs look?", result.messages[0].content);
    try std.testing.expectEqualStrings("1000", result.messages[0].created_at.?);
    try std.testing.expectEqual(@as(usize, 1), result.usages.len);
    try std.testing.expectEqualStrings("sess-docs", result.usages[0].session_id);
    try std.testing.expectEqual(@as(u64, 1234), result.usages[0].total_tokens);
    try std.testing.expectEqualStrings("3000", result.usages[0].updated_at.?);
    try std.testing.expectEqual(@as(usize, 1), result.sessions.len);
    try std.testing.expectEqualStrings("sess-docs", result.sessions[0].session_id);
    try std.testing.expectEqualStrings("openai", result.sessions[0].provider.?);
    try std.testing.expectEqualStrings("gpt-5", result.sessions[0].model.?);
    try std.testing.expectEqualStrings("500", result.sessions[0].created_at.?);
    try std.testing.expectEqualStrings("600", result.sessions[0].updated_at.?);
    try std.testing.expectEqual(@as(usize, 1), result.kvs.len);
    try std.testing.expectEqualStrings("last_hygiene_at", result.kvs[0].key);
    try std.testing.expectEqualStrings("1772051598", result.kvs[0].value);
    try std.testing.expectEqual(@as(usize, 1), result.embedding_cache_entries.len);
    try std.testing.expectEqualStrings("hash:docs", result.embedding_cache_entries[0].content_hash);
    try std.testing.expectEqualStrings("[1,0]", result.embedding_cache_entries[0].embedding_json);
    try std.testing.expectEqual(@as(usize, 2), result.embedding_cache_entries[0].dimensions);
    try std.testing.expectEqualStrings("700", result.embedding_cache_entries[0].created_at.?);
    try std.testing.expectEqual(@as(usize, 1), result.memory_embeddings.len);
    try std.testing.expectEqualStrings("pref.lang", result.memory_embeddings[0].memory_key);
    try std.testing.expectEqualStrings("[1,0]", result.memory_embeddings[0].embedding_json);
    try std.testing.expectEqual(@as(usize, 2), result.memory_embeddings[0].dimensions);
    try std.testing.expectEqualStrings("800", result.memory_embeddings[0].updated_at.?);
}

test "brain db import reads legacy id value kind schema" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/legacy-brain.db", .{tmp.sub_path});
    defer std.testing.allocator.free(path);

    try testingCreateDatabase(std.testing.allocator, path,
        \\CREATE TABLE memories(id TEXT, value TEXT, kind TEXT);
        \\INSERT INTO memories(id, value, kind) VALUES ('legacy.id', 'Legacy value', 'trait');
    );

    const result = try read(std.testing.allocator, path, .{ .limit = 100 });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.entries.len);
    try std.testing.expectEqualStrings("legacy.id", result.entries[0].key);
    try std.testing.expectEqualStrings("Legacy value", result.entries[0].content);
    try std.testing.expectEqualStrings("trait", result.entries[0].category);
}

test "brain db import rejects values above configured byte limits" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/large-value-brain.db", .{tmp.sub_path});
    defer std.testing.allocator.free(path);

    try testingCreateDatabase(std.testing.allocator, path,
        \\CREATE TABLE memories(key TEXT, content TEXT, category TEXT);
        \\INSERT INTO memories(key, content, category) VALUES ('big', '0123456789abcdef', 'preference');
    );

    try std.testing.expectError(error.ValueTooLarge, read(std.testing.allocator, path, .{
        .limit = 10,
        .max_value_bytes = 8,
        .max_total_bytes = 128,
    }));
}

test "brain db import rejects total payload above configured byte limit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/large-total-brain.db", .{tmp.sub_path});
    defer std.testing.allocator.free(path);

    try testingCreateDatabase(std.testing.allocator, path,
        \\CREATE TABLE memories(key TEXT, content TEXT, category TEXT);
        \\INSERT INTO memories(key, content, category) VALUES ('a', 'one', 'p');
        \\INSERT INTO memories(key, content, category) VALUES ('b', 'two', 'p');
    );

    try std.testing.expectError(error.ValueTooLarge, read(std.testing.allocator, path, .{
        .limit = 10,
        .max_value_bytes = 16,
        .max_total_bytes = 9,
    }));
}
