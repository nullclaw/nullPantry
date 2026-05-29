const std = @import("std");
const ids = @import("ids.zig");
const json = @import("json_util.zig");
const domain = @import("domain.zig");
const access = @import("access.zig");
const compat = @import("compat.zig");
const redis = @import("redis.zig");

pub const BackendKind = enum {
    native,
    redis,

    pub fn parse(raw: []const u8) BackendKind {
        if (std.ascii.eqlIgnoreCase(raw, "redis")) return .redis;
        return .native;
    }

    pub fn name(self: BackendKind) []const u8 {
        return switch (self) {
            .native => "native",
            .redis => "redis",
        };
    }
};

pub const Config = struct {
    backend: BackendKind = .native,
    redis: redis.Config = .{},
};

pub const Input = struct {
    key: []const u8,
    content: []const u8,
    category: []const u8 = "core",
    session_id: ?[]const u8 = null,
    scope: ?[]const u8 = null,
    permissions_json: []const u8 = "[]",
    metadata_json: []const u8 = "{}",
    actor_id: ?[]const u8 = null,
    writer_actor_id: ?[]const u8 = null,
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

pub const Runtime = union(BackendKind) {
    native,
    redis: RedisAgentMemory,

    pub fn init(allocator: std.mem.Allocator, config: Config) !Runtime {
        return switch (config.backend) {
            .native => .native,
            .redis => .{ .redis = RedisAgentMemory.init(allocator, config.redis) },
        };
    }

    pub fn deinit(self: *Runtime) void {
        switch (self.*) {
            .native => {},
            .redis => |*engine| engine.deinit(),
        }
    }

    pub fn isExternal(self: *const Runtime) bool {
        return self.* != .native;
    }

    pub fn backendName(self: *const Runtime) []const u8 {
        return switch (self.*) {
            .native => "native",
            .redis => "redis",
        };
    }

    pub fn store(self: *Runtime, allocator: std.mem.Allocator, input: Input) !domain.AgentMemory {
        return switch (self.*) {
            .native => error.NativeAgentMemoryRuntime,
            .redis => |*engine| engine.store(allocator, input),
        };
    }

    pub fn get(self: *Runtime, allocator: std.mem.Allocator, key: []const u8, session_id: ?[]const u8, actor_id: ?[]const u8) !?domain.AgentMemory {
        return switch (self.*) {
            .native => error.NativeAgentMemoryRuntime,
            .redis => |*engine| engine.get(allocator, key, session_id, actor_id),
        };
    }

    pub fn getVisible(self: *Runtime, allocator: std.mem.Allocator, key: []const u8, session_id: ?[]const u8, actor_id: []const u8, scopes_json: []const u8) !?domain.AgentMemory {
        return switch (self.*) {
            .native => error.NativeAgentMemoryRuntime,
            .redis => |*engine| engine.getVisible(allocator, key, session_id, actor_id, scopes_json),
        };
    }

    pub fn list(self: *Runtime, allocator: std.mem.Allocator, category: ?[]const u8, session_id: ?[]const u8, actor_id: ?[]const u8) ![]domain.AgentMemory {
        return switch (self.*) {
            .native => error.NativeAgentMemoryRuntime,
            .redis => |*engine| engine.list(allocator, category, session_id, actor_id),
        };
    }

    pub fn listVisible(self: *Runtime, allocator: std.mem.Allocator, category: ?[]const u8, session_id: ?[]const u8, actor_id: []const u8, scopes_json: []const u8) ![]domain.AgentMemory {
        return switch (self.*) {
            .native => error.NativeAgentMemoryRuntime,
            .redis => |*engine| engine.listVisible(allocator, category, session_id, actor_id, scopes_json),
        };
    }

    pub fn search(self: *Runtime, allocator: std.mem.Allocator, query: []const u8, limit: usize, session_id: ?[]const u8, scopes_json: []const u8, actor_id: ?[]const u8) ![]domain.AgentMemory {
        return switch (self.*) {
            .native => error.NativeAgentMemoryRuntime,
            .redis => |*engine| engine.search(allocator, query, limit, session_id, scopes_json, actor_id),
        };
    }

    pub fn delete(self: *Runtime, key: []const u8, session_id: ?[]const u8, actor_id: ?[]const u8, writer_actor_id: ?[]const u8) !bool {
        return switch (self.*) {
            .native => error.NativeAgentMemoryRuntime,
            .redis => |*engine| engine.delete(key, session_id, actor_id, writer_actor_id),
        };
    }

    pub fn count(self: *Runtime, actor_id: ?[]const u8, scopes_json: []const u8) !usize {
        return switch (self.*) {
            .native => error.NativeAgentMemoryRuntime,
            .redis => |*engine| engine.count(actor_id, scopes_json),
        };
    }

    pub fn saveMessage(self: *Runtime, session_id: []const u8, role: []const u8, content: []const u8, actor_id: ?[]const u8) !void {
        return switch (self.*) {
            .native => error.NativeAgentMemoryRuntime,
            .redis => |*engine| engine.saveMessage(session_id, role, content, actor_id),
        };
    }

    pub fn loadMessages(self: *Runtime, allocator: std.mem.Allocator, session_id: []const u8, actor_id: ?[]const u8) ![]Message {
        return switch (self.*) {
            .native => error.NativeAgentMemoryRuntime,
            .redis => |*engine| engine.loadMessages(allocator, session_id, actor_id),
        };
    }

    pub fn clearMessages(self: *Runtime, session_id: []const u8, actor_id: ?[]const u8) !void {
        return switch (self.*) {
            .native => error.NativeAgentMemoryRuntime,
            .redis => |*engine| engine.clearMessages(session_id, actor_id),
        };
    }

    pub fn clearAutoSaved(self: *Runtime, session_id: ?[]const u8, actor_id: ?[]const u8) !void {
        return switch (self.*) {
            .native => error.NativeAgentMemoryRuntime,
            .redis => |*engine| engine.clearAutoSaved(session_id, actor_id),
        };
    }

    pub fn saveUsage(self: *Runtime, session_id: []const u8, total_tokens: u64, actor_id: ?[]const u8) !void {
        return switch (self.*) {
            .native => error.NativeAgentMemoryRuntime,
            .redis => |*engine| engine.saveUsage(session_id, total_tokens, actor_id),
        };
    }

    pub fn deleteUsage(self: *Runtime, session_id: []const u8, actor_id: ?[]const u8) !bool {
        return switch (self.*) {
            .native => error.NativeAgentMemoryRuntime,
            .redis => |*engine| engine.deleteUsage(session_id, actor_id),
        };
    }

    pub fn loadUsage(self: *Runtime, session_id: []const u8, actor_id: ?[]const u8) !?u64 {
        return switch (self.*) {
            .native => error.NativeAgentMemoryRuntime,
            .redis => |*engine| engine.loadUsage(session_id, actor_id),
        };
    }

    pub fn listSessions(self: *Runtime, allocator: std.mem.Allocator, limit: usize, offset: usize, actor_id: ?[]const u8) !HistoryList {
        return switch (self.*) {
            .native => error.NativeAgentMemoryRuntime,
            .redis => |*engine| engine.listSessions(allocator, limit, offset, actor_id),
        };
    }

    pub fn history(self: *Runtime, allocator: std.mem.Allocator, session_id: []const u8, limit: usize, offset: usize, actor_id: ?[]const u8) !HistoryShow {
        return switch (self.*) {
            .native => error.NativeAgentMemoryRuntime,
            .redis => |*engine| engine.history(allocator, session_id, limit, offset, actor_id),
        };
    }
};

pub const RedisAgentMemory = struct {
    allocator: std.mem.Allocator,
    client: redis.Client,
    prefix: []const u8,
    ttl_seconds: ?u32,

    pub fn init(allocator: std.mem.Allocator, config: redis.Config) RedisAgentMemory {
        return .{
            .allocator = allocator,
            .client = redis.Client.init(allocator, config),
            .prefix = config.key_prefix,
            .ttl_seconds = config.ttl_seconds,
        };
    }

    pub fn deinit(self: *RedisAgentMemory) void {
        self.client.deinit();
    }

    pub fn store(self: *RedisAgentMemory, allocator: std.mem.Allocator, input: Input) !domain.AgentMemory {
        const request_actor = try access.requiredActorId(input.actor_id);
        const owner_actor = try access.agentMemoryOwner(allocator, request_actor, input.scope);
        defer allocator.free(owner_actor);
        const writer_actor = input.writer_actor_id orelse request_actor;
        const scope = try access.agentMemoryScope(allocator, owner_actor, input.session_id, input.scope);
        defer allocator.free(scope);
        const permissions = try access.agentMemoryPermissions(allocator, owner_actor, input.scope, input.permissions_json);
        defer allocator.free(permissions);
        const timestamp = ids.nowMs();
        const timestamp_text = try std.fmt.allocPrint(allocator, "{d}", .{timestamp});
        defer allocator.free(timestamp_text);
        const entry_key = try self.entryKey(allocator, owner_actor, input.session_id, input.key);
        defer allocator.free(entry_key);
        const entry_id = try self.entryId(allocator, owner_actor, input.session_id, input.key);
        defer allocator.free(entry_id);
        var old_hash = try self.client.command(&.{ "HGETALL", entry_key });
        defer old_hash.deinit(self.allocator);
        var old_entry = try self.agentMemoryFromHash(self.allocator, old_hash);
        defer if (old_entry) |*entry| freeAgentMemory(self.allocator, entry);

        var hset = try self.client.command(&.{
            "HSET", entry_key,
            "id", entry_id,
            "key", input.key,
            "content", input.content,
            "category", input.category,
            "timestamp", timestamp_text,
            "session_id", input.session_id orelse "",
            "actor_id", owner_actor,
            "writer_actor_id", writer_actor,
            "scope", scope,
            "permissions_json", permissions,
        });
        defer hset.deinit(self.allocator);

        if (old_entry) |entry| try self.removeEntryIndexes(entry_key, entry);
        try self.indexEntry(entry_key, owner_actor, input.session_id, input.category);
        if (self.ttl_seconds) |ttl| {
            var ttl_buf: [16]u8 = undefined;
            const ttl_text = try std.fmt.bufPrint(&ttl_buf, "{d}", .{ttl});
            var expire = try self.client.command(&.{ "EXPIRE", entry_key, ttl_text });
            expire.deinit(self.allocator);
        }

        return (try self.get(allocator, input.key, input.session_id, owner_actor)).?;
    }

    pub fn get(self: *RedisAgentMemory, allocator: std.mem.Allocator, key: []const u8, session_id: ?[]const u8, actor_id: ?[]const u8) !?domain.AgentMemory {
        const owner = actor_id orelse return null;
        const entry_key = try self.entryKey(allocator, owner, session_id, key);
        defer allocator.free(entry_key);
        var resp = try self.client.command(&.{ "HGETALL", entry_key });
        defer resp.deinit(self.allocator);
        return self.agentMemoryFromHash(allocator, resp);
    }

    pub fn getVisible(self: *RedisAgentMemory, allocator: std.mem.Allocator, key: []const u8, session_id: ?[]const u8, actor_id: []const u8, scopes_json: []const u8) !?domain.AgentMemory {
        const all = try self.listVisible(allocator, null, session_id, actor_id, scopes_json);
        defer allocator.free(all);
        for (all) |*entry| {
            if (std.mem.eql(u8, entry.key, key)) {
                const result = entry.*;
                detachAgentMemory(entry);
                for (all) |*other| freeAgentMemory(allocator, other);
                return result;
            }
        }
        for (all) |*entry| freeAgentMemory(allocator, entry);
        return null;
    }

    pub fn list(self: *RedisAgentMemory, allocator: std.mem.Allocator, category: ?[]const u8, session_id: ?[]const u8, actor_id: ?[]const u8) ![]domain.AgentMemory {
        const index_key = if (actor_id) |actor|
            try self.ownerIndexKey(allocator, actor)
        else
            try self.globalIndexKey(allocator);
        defer allocator.free(index_key);
        return self.listFromIndex(allocator, index_key, category, session_id, null, "[]", false);
    }

    pub fn listVisible(self: *RedisAgentMemory, allocator: std.mem.Allocator, category: ?[]const u8, session_id: ?[]const u8, actor_id: []const u8, scopes_json: []const u8) ![]domain.AgentMemory {
        const index_key = try self.globalIndexKey(allocator);
        defer allocator.free(index_key);
        return self.listFromIndex(allocator, index_key, category, session_id, actor_id, scopes_json, true);
    }

    pub fn search(self: *RedisAgentMemory, allocator: std.mem.Allocator, query: []const u8, limit: usize, session_id: ?[]const u8, scopes_json: []const u8, actor_id: ?[]const u8) ![]domain.AgentMemory {
        const actor = actor_id orelse return allocator.alloc(domain.AgentMemory, 0);
        if (limit == 0) return allocator.alloc(domain.AgentMemory, 0);
        const all = try self.listVisible(allocator, null, session_id, actor, scopes_json);
        defer allocator.free(all);
        var out: std.ArrayListUnmanaged(domain.AgentMemory) = .empty;
        errdefer out.deinit(allocator);
        for (all) |*entry| {
            if (out.items.len >= @max(@as(usize, 1), limit)) break;
            const score = scoreText(query, entry.key) + scoreText(query, entry.content);
            if (score <= 0 and query.len > 0) continue;
            var copy = entry.*;
            copy.score = score + 0.5;
            try out.append(allocator, copy);
            detachAgentMemory(entry);
        }
        for (all) |*entry| freeAgentMemory(allocator, entry);
        sortAgentMemory(out.items);
        if (out.items.len > limit) out.shrinkRetainingCapacity(limit);
        return out.toOwnedSlice(allocator);
    }

    pub fn delete(self: *RedisAgentMemory, key: []const u8, session_id: ?[]const u8, actor_id: ?[]const u8, _: ?[]const u8) !bool {
        const owner = actor_id orelse return false;
        const entry_key = try self.entryKey(self.allocator, owner, session_id, key);
        defer self.allocator.free(entry_key);
        var existing_hash = try self.client.command(&.{ "HGETALL", entry_key });
        defer existing_hash.deinit(self.allocator);
        if (try self.agentMemoryFromHash(self.allocator, existing_hash)) |existing| {
            var mutable_existing = existing;
            defer freeAgentMemory(self.allocator, &mutable_existing);
            try self.removeEntryIndexes(entry_key, mutable_existing);
        }
        var resp = try self.client.command(&.{ "DEL", entry_key });
        defer resp.deinit(self.allocator);
        return switch (resp) {
            .integer => |changed| changed > 0,
            else => false,
        };
    }

    pub fn count(self: *RedisAgentMemory, actor_id: ?[]const u8, scopes_json: []const u8) !usize {
        if (actor_id) |actor| {
            const visible = try self.listVisible(self.allocator, null, null, actor, scopes_json);
            defer {
                for (visible) |*entry| freeAgentMemory(self.allocator, entry);
                self.allocator.free(visible);
            }
            return visible.len;
        }
        const index_key = try self.globalIndexKey(self.allocator);
        defer self.allocator.free(index_key);
        var resp = try self.client.command(&.{ "SCARD", index_key });
        defer resp.deinit(self.allocator);
        return switch (resp) {
            .integer => |count_value| @intCast(@max(count_value, 0)),
            else => 0,
        };
    }

    pub fn saveMessage(self: *RedisAgentMemory, session_id: []const u8, role: []const u8, content: []const u8, actor_id: ?[]const u8) !void {
        const actor = try access.requiredActorId(actor_id);
        const created_at = ids.nowMs();
        const list_key = try self.sessionListKey(self.allocator, actor, session_id);
        defer self.allocator.free(list_key);
        const meta_key = try self.sessionMetaKey(self.allocator, actor, session_id);
        defer self.allocator.free(meta_key);
        const sessions_key = try self.sessionsIndexKey(self.allocator, actor);
        defer self.allocator.free(sessions_key);
        const payload = try messagePayload(self.allocator, role, content, created_at);
        defer self.allocator.free(payload);
        const created_text = try std.fmt.allocPrint(self.allocator, "{d}", .{created_at});
        defer self.allocator.free(created_text);

        var rpush = try self.client.command(&.{ "RPUSH", list_key, payload });
        rpush.deinit(self.allocator);
        var sadd = try self.client.command(&.{ "SADD", sessions_key, session_id });
        sadd.deinit(self.allocator);
        var hset = try self.client.command(&.{ "HSET", meta_key, "last_message_at", created_text, "session_id", session_id });
        hset.deinit(self.allocator);
        var hsetnx = try self.client.command(&.{ "HSETNX", meta_key, "first_message_at", created_text });
        hsetnx.deinit(self.allocator);
        var hincr = try self.client.command(&.{ "HINCRBY", meta_key, "message_count", "1" });
        hincr.deinit(self.allocator);
    }

    pub fn loadMessages(self: *RedisAgentMemory, allocator: std.mem.Allocator, session_id: []const u8, actor_id: ?[]const u8) ![]Message {
        const actor = actor_id orelse return allocator.alloc(Message, 0);
        const list_key = try self.sessionListKey(allocator, actor, session_id);
        defer allocator.free(list_key);
        var resp = try self.client.command(&.{ "LRANGE", list_key, "0", "-1" });
        defer resp.deinit(self.allocator);
        return messagesFromResp(allocator, resp);
    }

    pub fn clearMessages(self: *RedisAgentMemory, session_id: []const u8, actor_id: ?[]const u8) !void {
        const actor = actor_id orelse return;
        const list_key = try self.sessionListKey(self.allocator, actor, session_id);
        defer self.allocator.free(list_key);
        const meta_key = try self.sessionMetaKey(self.allocator, actor, session_id);
        defer self.allocator.free(meta_key);
        const sessions_key = try self.sessionsIndexKey(self.allocator, actor);
        defer self.allocator.free(sessions_key);
        var del = try self.client.command(&.{ "DEL", list_key, meta_key });
        del.deinit(self.allocator);
        var srem = try self.client.command(&.{ "SREM", sessions_key, session_id });
        srem.deinit(self.allocator);
    }

    pub fn clearAutoSaved(self: *RedisAgentMemory, session_id: ?[]const u8, actor_id: ?[]const u8) !void {
        if (session_id) |sid| {
            const loaded = try self.loadMessages(self.allocator, sid, actor_id);
            defer {
                for (loaded) |message| {
                    self.allocator.free(message.role);
                    self.allocator.free(message.content);
                }
                self.allocator.free(loaded);
            }
            try self.clearMessages(sid, actor_id);
            for (loaded) |message| {
                if (std.mem.eql(u8, message.role, "autosave_user") or std.mem.eql(u8, message.role, "autosave_assistant")) continue;
                try self.saveMessage(sid, message.role, message.content, actor_id);
            }
        }
    }

    pub fn saveUsage(self: *RedisAgentMemory, session_id: []const u8, total_tokens: u64, actor_id: ?[]const u8) !void {
        const actor = try access.requiredActorId(actor_id);
        const key = try self.usageKey(self.allocator, actor, session_id);
        defer self.allocator.free(key);
        const value = try std.fmt.allocPrint(self.allocator, "{d}", .{total_tokens});
        defer self.allocator.free(value);
        var set = try self.client.command(&.{ "SET", key, value });
        set.deinit(self.allocator);
    }

    pub fn deleteUsage(self: *RedisAgentMemory, session_id: []const u8, actor_id: ?[]const u8) !bool {
        const actor = actor_id orelse return false;
        const key = try self.usageKey(self.allocator, actor, session_id);
        defer self.allocator.free(key);
        var del = try self.client.command(&.{ "DEL", key });
        defer del.deinit(self.allocator);
        return switch (del) {
            .integer => |changed| changed > 0,
            else => false,
        };
    }

    pub fn loadUsage(self: *RedisAgentMemory, session_id: []const u8, actor_id: ?[]const u8) !?u64 {
        const actor = actor_id orelse return null;
        const key = try self.usageKey(self.allocator, actor, session_id);
        defer self.allocator.free(key);
        var response = try self.client.command(&.{ "GET", key });
        defer response.deinit(self.allocator);
        const value = response.asString() orelse return null;
        return std.fmt.parseInt(u64, value, 10) catch null;
    }

    pub fn listSessions(self: *RedisAgentMemory, allocator: std.mem.Allocator, limit: usize, offset: usize, actor_id: ?[]const u8) !HistoryList {
        const actor = actor_id orelse return .{ .total = 0, .sessions = try allocator.alloc(SessionInfo, 0) };
        const index_key = try self.sessionsIndexKey(allocator, actor);
        defer allocator.free(index_key);
        var resp = try self.client.command(&.{ "SMEMBERS", index_key });
        defer resp.deinit(self.allocator);
        const values = switch (resp) {
            .array => |maybe_items| maybe_items orelse return .{ .total = 0, .sessions = try allocator.alloc(SessionInfo, 0) },
            else => return .{ .total = 0, .sessions = try allocator.alloc(SessionInfo, 0) },
        };
        var all_sessions: std.ArrayListUnmanaged(SessionInfo) = .empty;
        errdefer {
            for (all_sessions.items) |*info| freeSessionInfo(allocator, info);
            all_sessions.deinit(allocator);
        }
        for (values) |value| {
            const sid = value.asString() orelse continue;
            const info = try self.sessionInfo(allocator, actor, sid);
            try all_sessions.append(allocator, info);
        }
        sortSessions(all_sessions.items);
        const total = all_sessions.items.len;
        const start = @min(offset, total);
        const end = @min(total, start + limit);
        var sessions = try allocator.alloc(SessionInfo, end - start);
        for (all_sessions.items, 0..) |*info, i| {
            if (i >= start and i < end) {
                sessions[i - start] = info.*;
                detachSessionInfo(info);
            } else {
                freeSessionInfo(allocator, info);
            }
        }
        all_sessions.deinit(allocator);
        return .{ .total = @intCast(total), .sessions = sessions };
    }

    pub fn history(self: *RedisAgentMemory, allocator: std.mem.Allocator, session_id: []const u8, limit: usize, offset: usize, actor_id: ?[]const u8) !HistoryShow {
        const messages = try self.loadMessages(allocator, session_id, actor_id);
        defer {
            for (messages) |*message| freeMessage(allocator, message);
            allocator.free(messages);
        }
        const total = messages.len;
        const start = @min(offset, messages.len);
        const end = @min(messages.len, start + limit);
        var out = try allocator.alloc(Message, end - start);
        for (messages, 0..) |*message, i| {
            if (i >= start and i < end) {
                out[i - start] = message.*;
                detachMessage(message);
            } else {
                freeMessage(allocator, message);
            }
        }
        return .{ .total = @intCast(total), .messages = out };
    }

    fn indexEntry(self: *RedisAgentMemory, entry_key: []const u8, owner_actor: []const u8, session_id: ?[]const u8, category: []const u8) !void {
        const global = try self.globalIndexKey(self.allocator);
        defer self.allocator.free(global);
        const owner = try self.ownerIndexKey(self.allocator, owner_actor);
        defer self.allocator.free(owner);
        const cat = try self.categoryIndexKey(self.allocator, category);
        defer self.allocator.free(cat);
        var sadd = try self.client.command(&.{ "SADD", global, entry_key });
        sadd.deinit(self.allocator);
        sadd = try self.client.command(&.{ "SADD", owner, entry_key });
        sadd.deinit(self.allocator);
        sadd = try self.client.command(&.{ "SADD", cat, entry_key });
        sadd.deinit(self.allocator);
        if (session_id) |sid| {
            const session = try self.agentSessionIndexKey(self.allocator, owner_actor, sid);
            defer self.allocator.free(session);
            sadd = try self.client.command(&.{ "SADD", session, entry_key });
            sadd.deinit(self.allocator);
        }
    }

    fn removeEntryIndexes(self: *RedisAgentMemory, entry_key: []const u8, entry: domain.AgentMemory) !void {
        const global = try self.globalIndexKey(self.allocator);
        defer self.allocator.free(global);
        const owner = try self.ownerIndexKey(self.allocator, entry.actor_id);
        defer self.allocator.free(owner);
        const cat = try self.categoryIndexKey(self.allocator, entry.category);
        defer self.allocator.free(cat);
        try self.removeIndexMember(global, entry_key);
        try self.removeIndexMember(owner, entry_key);
        try self.removeIndexMember(cat, entry_key);
        if (entry.session_id) |sid| {
            const session = try self.agentSessionIndexKey(self.allocator, entry.actor_id, sid);
            defer self.allocator.free(session);
            try self.removeIndexMember(session, entry_key);
        }
    }

    fn removeIndexMember(self: *RedisAgentMemory, index_key: []const u8, entry_key: []const u8) !void {
        var srem = try self.client.command(&.{ "SREM", index_key, entry_key });
        srem.deinit(self.allocator);
    }

    fn listFromIndex(self: *RedisAgentMemory, allocator: std.mem.Allocator, index_key: []const u8, category: ?[]const u8, session_id: ?[]const u8, actor_id: ?[]const u8, scopes_json: []const u8, visible_only: bool) ![]domain.AgentMemory {
        var resp = try self.client.command(&.{ "SMEMBERS", index_key });
        defer resp.deinit(self.allocator);
        const members = switch (resp) {
            .array => |maybe_items| maybe_items orelse return allocator.alloc(domain.AgentMemory, 0),
            else => return allocator.alloc(domain.AgentMemory, 0),
        };
        var out: std.ArrayListUnmanaged(domain.AgentMemory) = .empty;
        errdefer out.deinit(allocator);
        for (members) |member| {
            const redis_key = member.asString() orelse continue;
            var hash = try self.client.command(&.{ "HGETALL", redis_key });
            const maybe_entry = try self.agentMemoryFromHash(allocator, hash);
            hash.deinit(self.allocator);
            var entry = maybe_entry orelse {
                try self.removeIndexMember(index_key, redis_key);
                continue;
            };
            if (category) |cat| {
                if (!std.mem.eql(u8, entry.category, cat)) {
                    freeAgentMemory(allocator, &entry);
                    continue;
                }
            }
            if (session_id) |sid| {
                if (entry.session_id == null or !std.mem.eql(u8, entry.session_id.?, sid)) {
                    freeAgentMemory(allocator, &entry);
                    continue;
                }
            } else if (entry.session_id != null) {
                freeAgentMemory(allocator, &entry);
                continue;
            }
            if (visible_only) {
                const actor = actor_id orelse {
                    freeAgentMemory(allocator, &entry);
                    continue;
                };
                if (!try entryVisible(allocator, entry, actor, scopes_json)) {
                    freeAgentMemory(allocator, &entry);
                    continue;
                }
            }
            try out.append(allocator, entry);
        }
        sortAgentMemory(out.items);
        return out.toOwnedSlice(allocator);
    }

    fn agentMemoryFromHash(self: *RedisAgentMemory, allocator: std.mem.Allocator, resp: redis.RespValue) !?domain.AgentMemory {
        _ = self;
        const fields = switch (resp) {
            .array => |maybe_items| maybe_items orelse return null,
            else => return null,
        };
        if (fields.len == 0) return null;
        const id_value = hashField(fields, "id") orelse return null;
        const key = hashField(fields, "key") orelse return null;
        const content = hashField(fields, "content") orelse "";
        const category = hashField(fields, "category") orelse "core";
        const timestamp = hashField(fields, "timestamp") orelse "0";
        const session = hashField(fields, "session_id");
        const owner = hashField(fields, "actor_id") orelse return null;
        const writer = hashField(fields, "writer_actor_id") orelse owner;
        const scope = hashField(fields, "scope") orelse "";
        const permissions = hashField(fields, "permissions_json") orelse "[]";
        const out_id = try allocator.dupe(u8, id_value);
        errdefer allocator.free(out_id);
        const out_key = try allocator.dupe(u8, key);
        errdefer allocator.free(out_key);
        const out_content = try allocator.dupe(u8, content);
        errdefer allocator.free(out_content);
        const out_category = try allocator.dupe(u8, category);
        errdefer allocator.free(out_category);
        const out_timestamp = try allocator.dupe(u8, timestamp);
        errdefer allocator.free(out_timestamp);
        const out_session = if (session != null and session.?.len > 0) try allocator.dupe(u8, session.?) else null;
        errdefer if (out_session) |sid| allocator.free(sid);
        const out_actor = try allocator.dupe(u8, owner);
        errdefer allocator.free(out_actor);
        const out_writer = try allocator.dupe(u8, writer);
        errdefer allocator.free(out_writer);
        const out_scope = try allocator.dupe(u8, scope);
        errdefer allocator.free(out_scope);
        const out_permissions = try allocator.dupe(u8, permissions);
        errdefer allocator.free(out_permissions);
        return .{
            .id = out_id,
            .key = out_key,
            .content = out_content,
            .category = out_category,
            .timestamp = out_timestamp,
            .session_id = out_session,
            .actor_id = out_actor,
            .writer_actor_id = out_writer,
            .scope = out_scope,
            .permissions_json = out_permissions,
        };
    }

    fn sessionInfo(self: *RedisAgentMemory, allocator: std.mem.Allocator, actor: []const u8, session_id: []const u8) !SessionInfo {
        const meta_key = try self.sessionMetaKey(allocator, actor, session_id);
        defer allocator.free(meta_key);
        var resp = try self.client.command(&.{ "HGETALL", meta_key });
        defer resp.deinit(self.allocator);
        const fields = switch (resp) {
            .array => |maybe_items| maybe_items orelse &[_]redis.RespValue{},
            else => &[_]redis.RespValue{},
        };
        return .{
            .session_id = try allocator.dupe(u8, session_id),
            .message_count = parseU64(hashField(fields, "message_count"), 0),
            .first_message_at = parseI64(hashField(fields, "first_message_at"), 0),
            .last_message_at = parseI64(hashField(fields, "last_message_at"), 0),
        };
    }

    fn globalIndexKey(self: *RedisAgentMemory, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}:agent-memory:index", .{self.prefix});
    }

    fn ownerIndexKey(self: *RedisAgentMemory, allocator: std.mem.Allocator, actor: []const u8) ![]u8 {
        const encoded = try hex(allocator, actor);
        defer allocator.free(encoded);
        return std.fmt.allocPrint(allocator, "{s}:agent-memory:owner:{s}", .{ self.prefix, encoded });
    }

    fn categoryIndexKey(self: *RedisAgentMemory, allocator: std.mem.Allocator, category: []const u8) ![]u8 {
        const encoded = try hex(allocator, category);
        defer allocator.free(encoded);
        return std.fmt.allocPrint(allocator, "{s}:agent-memory:category:{s}", .{ self.prefix, encoded });
    }

    fn agentSessionIndexKey(self: *RedisAgentMemory, allocator: std.mem.Allocator, actor: []const u8, session_id: []const u8) ![]u8 {
        const actor_hex = try hex(allocator, actor);
        defer allocator.free(actor_hex);
        const session_hex = try hex(allocator, session_id);
        defer allocator.free(session_hex);
        return std.fmt.allocPrint(allocator, "{s}:agent-memory:session:{s}:{s}", .{ self.prefix, actor_hex, session_hex });
    }

    fn entryKey(self: *RedisAgentMemory, allocator: std.mem.Allocator, actor: []const u8, session_id: ?[]const u8, key: []const u8) ![]u8 {
        const actor_hex = try hex(allocator, actor);
        defer allocator.free(actor_hex);
        const session_hex = try hex(allocator, session_id orelse "");
        defer allocator.free(session_hex);
        const key_hex = try hex(allocator, key);
        defer allocator.free(key_hex);
        return std.fmt.allocPrint(allocator, "{s}:agent-memory:item:{s}:{s}:{s}", .{ self.prefix, actor_hex, session_hex, key_hex });
    }

    fn entryId(self: *RedisAgentMemory, allocator: std.mem.Allocator, actor: []const u8, session_id: ?[]const u8, key: []const u8) ![]u8 {
        _ = self;
        var hash_value = std.hash.Wyhash.hash(0, actor);
        hash_value = std.hash.Wyhash.hash(hash_value, session_id orelse "");
        hash_value = std.hash.Wyhash.hash(hash_value, key);
        return std.fmt.allocPrint(allocator, "agm_{x}", .{hash_value});
    }

    fn sessionListKey(self: *RedisAgentMemory, allocator: std.mem.Allocator, actor: []const u8, session_id: []const u8) ![]u8 {
        const actor_hex = try hex(allocator, actor);
        defer allocator.free(actor_hex);
        const session_hex = try hex(allocator, session_id);
        defer allocator.free(session_hex);
        return std.fmt.allocPrint(allocator, "{s}:sessions:{s}:{s}:messages", .{ self.prefix, actor_hex, session_hex });
    }

    fn sessionMetaKey(self: *RedisAgentMemory, allocator: std.mem.Allocator, actor: []const u8, session_id: []const u8) ![]u8 {
        const actor_hex = try hex(allocator, actor);
        defer allocator.free(actor_hex);
        const session_hex = try hex(allocator, session_id);
        defer allocator.free(session_hex);
        return std.fmt.allocPrint(allocator, "{s}:sessions:{s}:{s}:meta", .{ self.prefix, actor_hex, session_hex });
    }

    fn sessionsIndexKey(self: *RedisAgentMemory, allocator: std.mem.Allocator, actor: []const u8) ![]u8 {
        const actor_hex = try hex(allocator, actor);
        defer allocator.free(actor_hex);
        return std.fmt.allocPrint(allocator, "{s}:sessions:{s}:index", .{ self.prefix, actor_hex });
    }

    fn usageKey(self: *RedisAgentMemory, allocator: std.mem.Allocator, actor: []const u8, session_id: []const u8) ![]u8 {
        const actor_hex = try hex(allocator, actor);
        defer allocator.free(actor_hex);
        const session_hex = try hex(allocator, session_id);
        defer allocator.free(session_hex);
        return std.fmt.allocPrint(allocator, "{s}:sessions:{s}:{s}:usage", .{ self.prefix, actor_hex, session_hex });
    }
};

fn entryVisible(allocator: std.mem.Allocator, entry: domain.AgentMemory, actor_id: []const u8, scopes_json: []const u8) !bool {
    return access.agentMemoryVisible(allocator, .{
        .owner_actor_id = entry.actor_id,
        .scope = entry.scope,
        .permissions_json = entry.permissions_json,
        .session_id = entry.session_id,
        .request_actor_id = actor_id,
        .request_scopes_json = scopes_json,
        .record_visible = domain.scopeVisible(entry.scope, scopes_json) or access.permissionsVisibleForActor(allocator, entry.permissions_json, scopes_json, actor_id),
        .session_visible = if (entry.session_id) |sid| access.sessionVisibleForScopes(allocator, sid, scopes_json) else true,
    });
}

fn hashField(fields: []const redis.RespValue, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + 1 < fields.len) : (i += 2) {
        const key = fields[i].asString() orelse continue;
        if (std.mem.eql(u8, key, name)) return fields[i + 1].asString();
    }
    return null;
}

fn messagePayload(allocator: std.mem.Allocator, role: []const u8, content: []const u8, created_at_ms: i64) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"role\":");
    try json.appendString(&out, allocator, role);
    try out.appendSlice(allocator, ",\"content\":");
    try json.appendString(&out, allocator, content);
    try out.print(allocator, ",\"created_at_ms\":{d}}}", .{created_at_ms});
    return out.toOwnedSlice(allocator);
}

fn messagesFromResp(allocator: std.mem.Allocator, resp: redis.RespValue) ![]Message {
    const items = switch (resp) {
        .array => |maybe_items| maybe_items orelse return allocator.alloc(Message, 0),
        else => return allocator.alloc(Message, 0),
    };
    var out: std.ArrayListUnmanaged(Message) = .empty;
    errdefer {
        for (out.items) |*message| freeMessage(allocator, message);
        out.deinit(allocator);
    }
    for (items) |item| {
        const payload = item.asString() orelse continue;
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const obj = parsed.value.object;
        const role = try allocator.dupe(u8, json.stringField(obj, "role") orelse "");
        errdefer allocator.free(role);
        const content = try allocator.dupe(u8, json.stringField(obj, "content") orelse "");
        errdefer allocator.free(content);
        try out.append(allocator, .{
            .role = role,
            .content = content,
            .created_at_ms = json.intField(obj, "created_at_ms") orelse 0,
        });
    }
    return out.toOwnedSlice(allocator);
}

fn parseU64(raw: ?[]const u8, fallback: u64) u64 {
    const value = raw orelse return fallback;
    return std.fmt.parseInt(u64, value, 10) catch fallback;
}

fn parseI64(raw: ?[]const u8, fallback: i64) i64 {
    const value = raw orelse return fallback;
    return std.fmt.parseInt(i64, value, 10) catch fallback;
}

fn scoreText(query: []const u8, text: []const u8) f64 {
    if (query.len == 0) return 1.0;
    var score: f64 = 0.0;
    var it = std.mem.tokenizeAny(u8, query, " \t\r\n.,;:/\\-_*\"'()[]{}<>!?");
    while (it.next()) |token| {
        if (token.len > 0 and std.ascii.indexOfIgnoreCase(text, token) != null) score += 1.0;
    }
    return score;
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

fn sortSessions(items: []SessionInfo) void {
    std.mem.sort(SessionInfo, items, {}, struct {
        fn lessThan(_: void, a: SessionInfo, b: SessionInfo) bool {
            return a.last_message_at > b.last_message_at;
        }
    }.lessThan);
}

fn detachAgentMemory(entry: *domain.AgentMemory) void {
    entry.id = "";
    entry.key = "";
    entry.content = "";
    entry.category = "";
    entry.timestamp = "";
    entry.session_id = null;
    entry.actor_id = "";
    entry.writer_actor_id = "";
    entry.scope = "";
    entry.permissions_json = "";
}

pub fn freeAgentMemory(allocator: std.mem.Allocator, entry: *domain.AgentMemory) void {
    if (entry.id.len == 0) return;
    if (entry.id.len > 0) allocator.free(entry.id);
    if (entry.key.len > 0) allocator.free(entry.key);
    if (entry.content.len > 0) allocator.free(entry.content);
    if (entry.category.len > 0) allocator.free(entry.category);
    if (entry.timestamp.len > 0) allocator.free(entry.timestamp);
    if (entry.session_id) |sid| allocator.free(sid);
    if (entry.actor_id.len > 0) allocator.free(entry.actor_id);
    if (entry.writer_actor_id.len > 0) allocator.free(entry.writer_actor_id);
    if (entry.scope.len > 0) allocator.free(entry.scope);
    if (entry.permissions_json.len > 0) allocator.free(entry.permissions_json);
    detachAgentMemory(entry);
}

fn detachMessage(message: *Message) void {
    message.role = "";
    message.content = "";
    message.created_at_ms = 0;
}

fn freeMessage(allocator: std.mem.Allocator, message: *Message) void {
    if (message.role.len > 0) allocator.free(message.role);
    if (message.content.len > 0) allocator.free(message.content);
    detachMessage(message);
}

fn detachSessionInfo(info: *SessionInfo) void {
    info.session_id = "";
    info.message_count = 0;
    info.first_message_at = 0;
    info.last_message_at = 0;
}

fn freeSessionInfo(allocator: std.mem.Allocator, info: *SessionInfo) void {
    if (info.session_id.len > 0) allocator.free(info.session_id);
    detachSessionInfo(info);
}

fn hex(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, raw.len * 2);
    const digits = "0123456789abcdef";
    for (raw, 0..) |byte, i| {
        out[i * 2] = digits[byte >> 4];
        out[i * 2 + 1] = digits[byte & 0x0f];
    }
    return out;
}

test "agent memory runtime parses backend names" {
    try std.testing.expectEqual(BackendKind.redis, BackendKind.parse("redis"));
    try std.testing.expectEqual(BackendKind.native, BackendKind.parse("sqlite"));
}

test "agent memory runtime encodes message payloads" {
    const payload = try messagePayload(std.testing.allocator, "user", "hello", 42);
    defer std.testing.allocator.free(payload);
    const resp = redis.RespValue{ .array = try std.testing.allocator.dupe(redis.RespValue, &[_]redis.RespValue{.{ .bulk_string = payload }}) };
    defer {
        const items = resp.array.?;
        std.testing.allocator.free(items);
    }
    const messages = try messagesFromResp(std.testing.allocator, resp);
    defer {
        for (messages) |message| {
            std.testing.allocator.free(message.role);
            std.testing.allocator.free(message.content);
        }
        std.testing.allocator.free(messages);
    }
    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expectEqualStrings("hello", messages[0].content);
}

test "redis agent memory contract when configured" {
    const url = compat.process.getEnvVarOwned(std.testing.allocator, "NULLPANTRY_TEST_REDIS_URL") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => {
            const required = compat.process.getEnvVarOwned(std.testing.allocator, "NULLPANTRY_REQUIRE_REDIS_TEST") catch null;
            if (required) |value| {
                std.testing.allocator.free(value);
                return error.MissingRedisContractUrl;
            }
            return error.SkipZigTest;
        },
        else => return err,
    };
    defer std.testing.allocator.free(url);

    var cfg = try redis.parseUrl(std.testing.allocator, url);
    defer {
        std.testing.allocator.free(cfg.host);
        if (cfg.password) |password| std.testing.allocator.free(password);
    }
    cfg.key_prefix = try std.fmt.allocPrint(std.testing.allocator, "np-test:{d}", .{ids.nowMs()});
    defer std.testing.allocator.free(cfg.key_prefix);

    var runtime = try Runtime.init(std.testing.allocator, .{ .backend = .redis, .redis = cfg });
    defer runtime.deinit();

    const private_a = try runtime.store(std.testing.allocator, .{ .key = "pref.lang", .content = "agent a private", .actor_id = "agent:a" });
    defer {
        var copy = private_a;
        freeAgentMemory(std.testing.allocator, &copy);
    }
    const private_b = try runtime.store(std.testing.allocator, .{ .key = "pref.lang", .content = "agent b private", .actor_id = "agent:b" });
    defer {
        var copy = private_b;
        freeAgentMemory(std.testing.allocator, &copy);
    }
    const shared = try runtime.store(std.testing.allocator, .{ .key = "team.pref", .content = "team shared", .scope = "team:alpha", .actor_id = "agent:a" });
    defer {
        var copy = shared;
        freeAgentMemory(std.testing.allocator, &copy);
    }

    const a = (try runtime.get(std.testing.allocator, "pref.lang", null, "agent:a")).?;
    defer {
        var copy = a;
        freeAgentMemory(std.testing.allocator, &copy);
    }
    try std.testing.expectEqualStrings("agent a private", a.content);
    const b = (try runtime.get(std.testing.allocator, "pref.lang", null, "agent:b")).?;
    defer {
        var copy = b;
        freeAgentMemory(std.testing.allocator, &copy);
    }
    try std.testing.expectEqualStrings("agent b private", b.content);
    const shared_visible = (try runtime.getVisible(std.testing.allocator, "team.pref", null, "agent:b", "[\"team:alpha\"]")).?;
    defer {
        var copy = shared_visible;
        freeAgentMemory(std.testing.allocator, &copy);
    }
    try std.testing.expectEqualStrings("team shared", shared_visible.content);
    try std.testing.expect((try runtime.getVisible(std.testing.allocator, "team.pref", null, "agent:c", "[\"public\"]")) == null);

    try runtime.saveMessage("sess", "user", "hello from a", "agent:a");
    try runtime.saveMessage("sess", "user", "hello from b", "agent:b");
    const a_messages = try runtime.loadMessages(std.testing.allocator, "sess", "agent:a");
    defer {
        for (a_messages) |message| {
            std.testing.allocator.free(message.role);
            std.testing.allocator.free(message.content);
        }
        std.testing.allocator.free(a_messages);
    }
    try std.testing.expectEqual(@as(usize, 1), a_messages.len);
    try std.testing.expectEqualStrings("hello from a", a_messages[0].content);
}
