const std = @import("std");
const builtin = @import("builtin");
const ids = @import("ids.zig");
const json = @import("json_util.zig");
const domain = @import("domain.zig");
const access = @import("access.zig");
const compat = @import("compat.zig");
const net_security = @import("net_security.zig");
const redis = @import("redis.zig");
const agent_memory_reducer = @import("agent_memory_reducer.zig");

pub const BackendKind = enum {
    none,
    native,
    memory_lru,
    redis,
    api,

    pub fn parse(raw: []const u8) BackendKind {
        if (std.ascii.eqlIgnoreCase(raw, "none")) return .none;
        if (std.ascii.eqlIgnoreCase(raw, "memory")) return .memory_lru;
        if (std.ascii.eqlIgnoreCase(raw, "memory_lru")) return .memory_lru;
        if (std.ascii.eqlIgnoreCase(raw, "in_memory")) return .memory_lru;
        if (std.ascii.eqlIgnoreCase(raw, "redis")) return .redis;
        if (std.ascii.eqlIgnoreCase(raw, "api")) return .api;
        if (std.ascii.eqlIgnoreCase(raw, "http")) return .api;
        if (std.ascii.eqlIgnoreCase(raw, "nullpantry_api")) return .api;
        return .native;
    }

    pub fn name(self: BackendKind) []const u8 {
        return switch (self) {
            .none => "none",
            .native => "native",
            .memory_lru => "memory_lru",
            .redis => "redis",
            .api => "api",
        };
    }
};

pub const MemoryConfig = struct {
    max_entries: usize = 4096,
    max_messages: usize = 4096,
    max_usage_entries: usize = 4096,
    max_bytes: usize = 0,
    ttl_seconds: ?u32 = null,
};

pub const ApiConfig = struct {
    base_url: ?[]const u8 = null,
    token: ?[]const u8 = null,
    actor_scopes_json: []const u8 = "[\"admin\"]",
    actor_capabilities_json: []const u8 = "[\"read\",\"write\",\"propose\",\"verify\",\"delete\",\"export\",\"feed_apply\"]",
    timeout_secs: u32 = 30,
    max_response_bytes: usize = 2 * 1024 * 1024,
    allow_insecure_http: bool = false,
};

pub const Config = struct {
    backend: BackendKind = .native,
    memory: MemoryConfig = .{},
    redis: redis.Config = .{},
    api: ApiConfig = .{},
};

pub const NamedConfig = struct {
    name: []const u8,
    config: Config,
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
    operation: domain.AgentMemoryOperation = .put,
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
    none,
    native,
    memory_lru: MemoryAgentMemory,
    redis: RedisAgentMemory,
    api: ApiAgentMemory,

    pub fn init(allocator: std.mem.Allocator, config: Config) !Runtime {
        return switch (config.backend) {
            .none => .none,
            .native => .native,
            .memory_lru => .{ .memory_lru = MemoryAgentMemory.init(allocator, config.memory) },
            .redis => .{ .redis = RedisAgentMemory.init(allocator, config.redis) },
            .api => .{ .api = try ApiAgentMemory.init(allocator, config.api) },
        };
    }

    pub fn deinit(self: *Runtime) void {
        switch (self.*) {
            .none => {},
            .native => {},
            .memory_lru => |*engine| engine.deinit(),
            .redis => |*engine| engine.deinit(),
            .api => |*engine| engine.deinit(),
        }
    }

    pub fn isExternal(self: *const Runtime) bool {
        return self.* != .native;
    }

    pub fn backendName(self: *const Runtime) []const u8 {
        return switch (self.*) {
            .none => "none",
            .native => "native",
            .memory_lru => "memory_lru",
            .redis => "redis",
            .api => "api",
        };
    }

    pub fn store(self: *Runtime, allocator: std.mem.Allocator, input: Input) !domain.AgentMemory {
        return switch (self.*) {
            .none => error.AgentMemoryStorageUnavailable,
            .native => error.NativeAgentMemoryRuntime,
            .memory_lru => |*engine| engine.store(allocator, input),
            .redis => |*engine| engine.store(allocator, input),
            .api => |*engine| engine.store(allocator, input),
        };
    }

    pub fn get(self: *Runtime, allocator: std.mem.Allocator, key: []const u8, session_id: ?[]const u8, actor_id: ?[]const u8) !?domain.AgentMemory {
        return switch (self.*) {
            .none => null,
            .native => error.NativeAgentMemoryRuntime,
            .memory_lru => |*engine| engine.get(allocator, key, session_id, actor_id),
            .redis => |*engine| engine.get(allocator, key, session_id, actor_id),
            .api => |*engine| engine.get(allocator, key, session_id, actor_id),
        };
    }

    pub fn getVisible(self: *Runtime, allocator: std.mem.Allocator, key: []const u8, session_id: ?[]const u8, actor_id: []const u8, scopes_json: []const u8) !?domain.AgentMemory {
        return switch (self.*) {
            .none => null,
            .native => error.NativeAgentMemoryRuntime,
            .memory_lru => |*engine| engine.getVisible(allocator, key, session_id, actor_id, scopes_json),
            .redis => |*engine| engine.getVisible(allocator, key, session_id, actor_id, scopes_json),
            .api => |*engine| engine.getVisible(allocator, key, session_id, actor_id, scopes_json),
        };
    }

    pub fn list(self: *Runtime, allocator: std.mem.Allocator, category: ?[]const u8, session_id: ?[]const u8, actor_id: ?[]const u8) ![]domain.AgentMemory {
        return switch (self.*) {
            .none => allocator.alloc(domain.AgentMemory, 0),
            .native => error.NativeAgentMemoryRuntime,
            .memory_lru => |*engine| engine.list(allocator, category, session_id, actor_id),
            .redis => |*engine| engine.list(allocator, category, session_id, actor_id),
            .api => |*engine| engine.list(allocator, category, session_id, actor_id),
        };
    }

    pub fn listVisible(self: *Runtime, allocator: std.mem.Allocator, category: ?[]const u8, session_id: ?[]const u8, actor_id: []const u8, scopes_json: []const u8) ![]domain.AgentMemory {
        return switch (self.*) {
            .none => allocator.alloc(domain.AgentMemory, 0),
            .native => error.NativeAgentMemoryRuntime,
            .memory_lru => |*engine| engine.listVisible(allocator, category, session_id, actor_id, scopes_json),
            .redis => |*engine| engine.listVisible(allocator, category, session_id, actor_id, scopes_json),
            .api => |*engine| engine.listVisible(allocator, category, session_id, actor_id, scopes_json),
        };
    }

    pub fn search(self: *Runtime, allocator: std.mem.Allocator, query: []const u8, limit: usize, session_id: ?[]const u8, scopes_json: []const u8, actor_id: ?[]const u8) ![]domain.AgentMemory {
        return switch (self.*) {
            .none => allocator.alloc(domain.AgentMemory, 0),
            .native => error.NativeAgentMemoryRuntime,
            .memory_lru => |*engine| engine.search(allocator, query, limit, session_id, scopes_json, actor_id),
            .redis => |*engine| engine.search(allocator, query, limit, session_id, scopes_json, actor_id),
            .api => |*engine| engine.search(allocator, query, limit, session_id, scopes_json, actor_id),
        };
    }

    pub fn delete(self: *Runtime, key: []const u8, session_id: ?[]const u8, actor_id: ?[]const u8, writer_actor_id: ?[]const u8) !bool {
        return switch (self.*) {
            .none => false,
            .native => error.NativeAgentMemoryRuntime,
            .memory_lru => |*engine| engine.delete(key, session_id, actor_id, writer_actor_id),
            .redis => |*engine| engine.delete(key, session_id, actor_id, writer_actor_id),
            .api => |*engine| engine.delete(key, session_id, actor_id, writer_actor_id),
        };
    }

    pub fn count(self: *Runtime, actor_id: ?[]const u8, scopes_json: []const u8) !usize {
        return switch (self.*) {
            .none => 0,
            .native => error.NativeAgentMemoryRuntime,
            .memory_lru => |*engine| engine.count(actor_id, scopes_json),
            .redis => |*engine| engine.count(actor_id, scopes_json),
            .api => |*engine| engine.count(actor_id, scopes_json),
        };
    }

    pub fn saveMessage(self: *Runtime, session_id: []const u8, role: []const u8, content: []const u8, actor_id: ?[]const u8) !void {
        return switch (self.*) {
            .none => {},
            .native => error.NativeAgentMemoryRuntime,
            .memory_lru => |*engine| engine.saveMessage(session_id, role, content, actor_id),
            .redis => |*engine| engine.saveMessage(session_id, role, content, actor_id),
            .api => |*engine| engine.saveMessage(session_id, role, content, actor_id),
        };
    }

    pub fn loadMessages(self: *Runtime, allocator: std.mem.Allocator, session_id: []const u8, actor_id: ?[]const u8) ![]Message {
        return switch (self.*) {
            .none => allocator.alloc(Message, 0),
            .native => error.NativeAgentMemoryRuntime,
            .memory_lru => |*engine| engine.loadMessages(allocator, session_id, actor_id),
            .redis => |*engine| engine.loadMessages(allocator, session_id, actor_id),
            .api => |*engine| engine.loadMessages(allocator, session_id, actor_id),
        };
    }

    pub fn clearMessages(self: *Runtime, session_id: []const u8, actor_id: ?[]const u8) !void {
        return switch (self.*) {
            .none => {},
            .native => error.NativeAgentMemoryRuntime,
            .memory_lru => |*engine| engine.clearMessages(session_id, actor_id),
            .redis => |*engine| engine.clearMessages(session_id, actor_id),
            .api => |*engine| engine.clearMessages(session_id, actor_id),
        };
    }

    pub fn clearAutoSaved(self: *Runtime, session_id: ?[]const u8, actor_id: ?[]const u8) !void {
        return switch (self.*) {
            .none => {},
            .native => error.NativeAgentMemoryRuntime,
            .memory_lru => |*engine| engine.clearAutoSaved(session_id, actor_id),
            .redis => |*engine| engine.clearAutoSaved(session_id, actor_id),
            .api => |*engine| engine.clearAutoSaved(session_id, actor_id),
        };
    }

    pub fn saveUsage(self: *Runtime, session_id: []const u8, total_tokens: u64, actor_id: ?[]const u8) !void {
        return switch (self.*) {
            .none => {},
            .native => error.NativeAgentMemoryRuntime,
            .memory_lru => |*engine| engine.saveUsage(session_id, total_tokens, actor_id),
            .redis => |*engine| engine.saveUsage(session_id, total_tokens, actor_id),
            .api => |*engine| engine.saveUsage(session_id, total_tokens, actor_id),
        };
    }

    pub fn deleteUsage(self: *Runtime, session_id: []const u8, actor_id: ?[]const u8) !bool {
        return switch (self.*) {
            .none => false,
            .native => error.NativeAgentMemoryRuntime,
            .memory_lru => |*engine| engine.deleteUsage(session_id, actor_id),
            .redis => |*engine| engine.deleteUsage(session_id, actor_id),
            .api => |*engine| engine.deleteUsage(session_id, actor_id),
        };
    }

    pub fn loadUsage(self: *Runtime, session_id: []const u8, actor_id: ?[]const u8) !?u64 {
        return switch (self.*) {
            .none => null,
            .native => error.NativeAgentMemoryRuntime,
            .memory_lru => |*engine| engine.loadUsage(session_id, actor_id),
            .redis => |*engine| engine.loadUsage(session_id, actor_id),
            .api => |*engine| engine.loadUsage(session_id, actor_id),
        };
    }

    pub fn listSessions(self: *Runtime, allocator: std.mem.Allocator, limit: usize, offset: usize, actor_id: ?[]const u8) !HistoryList {
        return switch (self.*) {
            .none => .{ .total = 0, .sessions = try allocator.alloc(SessionInfo, 0) },
            .native => error.NativeAgentMemoryRuntime,
            .memory_lru => |*engine| engine.listSessions(allocator, limit, offset, actor_id),
            .redis => |*engine| engine.listSessions(allocator, limit, offset, actor_id),
            .api => |*engine| engine.listSessions(allocator, limit, offset, actor_id),
        };
    }

    pub fn history(self: *Runtime, allocator: std.mem.Allocator, session_id: []const u8, limit: usize, offset: usize, actor_id: ?[]const u8) !HistoryShow {
        return switch (self.*) {
            .none => .{ .total = 0, .messages = try allocator.alloc(Message, 0) },
            .native => error.NativeAgentMemoryRuntime,
            .memory_lru => |*engine| engine.history(allocator, session_id, limit, offset, actor_id),
            .redis => |*engine| engine.history(allocator, session_id, limit, offset, actor_id),
            .api => |*engine| engine.history(allocator, session_id, limit, offset, actor_id),
        };
    }
};

pub const NamedRuntime = struct {
    name: []const u8,
    runtime: Runtime,
};

pub const RuntimeRegistry = struct {
    allocator: std.mem.Allocator,
    stores: std.ArrayListUnmanaged(NamedRuntime) = .empty,

    pub fn init(allocator: std.mem.Allocator, configs: []const NamedConfig) !RuntimeRegistry {
        var registry = RuntimeRegistry{ .allocator = allocator };
        errdefer registry.deinit();
        for (configs) |config| {
            const name = std.mem.trim(u8, config.name, " \t\r\n");
            if (name.len == 0) return error.InvalidAgentMemoryStoreName;
            if (isReservedStoreName(name)) return error.InvalidAgentMemoryStoreName;
            if (config.config.backend == .native) return error.InvalidAgentMemoryStoreBackend;
            if (registry.get(name) != null) return error.DuplicateAgentMemoryStoreName;
            const owned_name = try allocator.dupe(u8, name);
            errdefer allocator.free(owned_name);
            var runtime = try Runtime.init(allocator, config.config);
            errdefer runtime.deinit();
            try registry.stores.append(allocator, .{ .name = owned_name, .runtime = runtime });
        }
        return registry;
    }

    pub fn deinit(self: *RuntimeRegistry) void {
        const allocator = self.allocator;
        for (self.stores.items) |*store| {
            allocator.free(store.name);
            store.runtime.deinit();
        }
        self.stores.deinit(allocator);
        self.* = .{ .allocator = allocator };
    }

    pub fn get(self: *RuntimeRegistry, name: []const u8) ?*Runtime {
        for (self.stores.items) |*store| {
            if (std.mem.eql(u8, store.name, name)) return &store.runtime;
        }
        return null;
    }

    pub fn count(self: *const RuntimeRegistry) usize {
        return self.stores.items.len;
    }
};

fn isReservedStoreName(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "primary") or
        std.ascii.eqlIgnoreCase(name, "default") or
        std.ascii.eqlIgnoreCase(name, "native") or
        std.ascii.eqlIgnoreCase(name, "canonical") or
        std.ascii.eqlIgnoreCase(name, "sqlite") or
        std.ascii.eqlIgnoreCase(name, "postgres") or
        std.ascii.eqlIgnoreCase(name, "runtime") or
        std.ascii.eqlIgnoreCase(name, "external") or
        std.ascii.eqlIgnoreCase(name, "redis") or
        std.ascii.eqlIgnoreCase(name, "all") or
        std.ascii.eqlIgnoreCase(name, "federated");
}

const MemorySessionMessage = struct {
    actor_id: []const u8,
    session_id: []const u8,
    role: []const u8,
    content: []const u8,
    created_at_ms: i64,
    last_access_ms: i64,
};

const MemoryUsage = struct {
    actor_id: []const u8,
    session_id: []const u8,
    total_tokens: u64,
    updated_at_ms: i64,
    last_access_ms: i64,
};

const MemoryEntry = struct {
    entry: domain.AgentMemory,
    last_access_ms: i64,
};

pub const MemoryAgentMemory = struct {
    allocator: std.mem.Allocator,
    config: MemoryConfig = .{},
    entries: std.ArrayListUnmanaged(MemoryEntry) = .empty,
    messages: std.ArrayListUnmanaged(MemorySessionMessage) = .empty,
    usage: std.ArrayListUnmanaged(MemoryUsage) = .empty,

    pub fn init(allocator: std.mem.Allocator, config: MemoryConfig) MemoryAgentMemory {
        return .{ .allocator = allocator, .config = config };
    }

    pub fn deinit(self: *MemoryAgentMemory) void {
        for (self.entries.items) |*entry| freeAgentMemory(self.allocator, &entry.entry);
        self.entries.deinit(self.allocator);
        for (self.messages.items) |*message| freeMemorySessionMessage(self.allocator, message);
        self.messages.deinit(self.allocator);
        for (self.usage.items) |*item| freeMemoryUsage(self.allocator, item);
        self.usage.deinit(self.allocator);
    }

    pub fn store(self: *MemoryAgentMemory, allocator: std.mem.Allocator, input: Input) !domain.AgentMemory {
        self.purgeExpired();
        const request_actor = try access.requiredActorId(input.actor_id);
        const owner_actor = try access.agentMemoryOwner(allocator, request_actor, input.scope);
        defer allocator.free(owner_actor);
        const writer_actor = input.writer_actor_id orelse request_actor;
        const scope = try access.agentMemoryScope(allocator, owner_actor, input.session_id, input.scope);
        defer allocator.free(scope);
        const permissions = try access.agentMemoryPermissions(allocator, owner_actor, input.scope, input.permissions_json);
        defer allocator.free(permissions);
        const existing_idx = self.findEntryIndex(owner_actor, input.session_id, input.key);
        const existing_content = if (existing_idx) |idx| self.entries.items[idx].entry.content else null;
        const reduced_content = try agent_memory_reducer.reduceContent(allocator, input.operation, existing_content, input.content);
        defer allocator.free(reduced_content);
        _ = try self.delete(input.key, input.session_id, owner_actor, writer_actor);

        const timestamp = ids.nowMs();
        const timestamp_text = try std.fmt.allocPrint(self.allocator, "{d}", .{timestamp});
        var timestamp_owned = true;
        errdefer if (timestamp_owned) self.allocator.free(timestamp_text);
        const entry_id = try memoryEntryId(self.allocator, owner_actor, input.session_id, input.key);
        var entry_id_owned = true;
        errdefer if (entry_id_owned) self.allocator.free(entry_id);
        var stored = domain.AgentMemory{
            .id = entry_id,
            .key = try self.allocator.dupe(u8, input.key),
            .content = try self.allocator.dupe(u8, reduced_content),
            .category = try self.allocator.dupe(u8, input.category),
            .timestamp = timestamp_text,
            .session_id = if (input.session_id) |sid| try self.allocator.dupe(u8, sid) else null,
            .actor_id = try self.allocator.dupe(u8, owner_actor),
            .writer_actor_id = try self.allocator.dupe(u8, writer_actor),
            .scope = try self.allocator.dupe(u8, scope),
            .permissions_json = try self.allocator.dupe(u8, permissions),
        };
        timestamp_owned = false;
        entry_id_owned = false;
        var stored_owned = true;
        errdefer {
            if (stored_owned) freeAgentMemory(self.allocator, &stored);
        }
        try self.entries.append(self.allocator, .{ .entry = stored, .last_access_ms = timestamp });
        stored_owned = false;
        errdefer {
            var removed = self.entries.orderedRemove(self.entries.items.len - 1);
            freeAgentMemory(self.allocator, &removed.entry);
        }
        const result = try cloneAgentMemory(allocator, stored);
        self.enforceLimits();
        return result;
    }

    pub fn get(self: *MemoryAgentMemory, allocator: std.mem.Allocator, key: []const u8, session_id: ?[]const u8, actor_id: ?[]const u8) !?domain.AgentMemory {
        self.purgeExpired();
        const owner = actor_id orelse return null;
        const idx = self.findEntryIndex(owner, session_id, key) orelse return null;
        self.entries.items[idx].last_access_ms = ids.nowMs();
        return try cloneAgentMemory(allocator, self.entries.items[idx].entry);
    }

    pub fn getVisible(self: *MemoryAgentMemory, allocator: std.mem.Allocator, key: []const u8, session_id: ?[]const u8, actor_id: []const u8, scopes_json: []const u8) !?domain.AgentMemory {
        const all = try self.listVisible(allocator, null, session_id, actor_id, scopes_json);
        defer {
            for (all) |*entry| freeAgentMemory(allocator, entry);
            allocator.free(all);
        }
        for (all) |*entry| {
            if (std.mem.eql(u8, entry.key, key)) {
                const result = entry.*;
                self.touchEntryById(result.id, ids.nowMs());
                detachAgentMemory(entry);
                return result;
            }
        }
        return null;
    }

    pub fn list(self: *MemoryAgentMemory, allocator: std.mem.Allocator, category: ?[]const u8, session_id: ?[]const u8, actor_id: ?[]const u8) ![]domain.AgentMemory {
        return self.listInternal(allocator, category, session_id, actor_id, null, false);
    }

    pub fn listVisible(self: *MemoryAgentMemory, allocator: std.mem.Allocator, category: ?[]const u8, session_id: ?[]const u8, actor_id: []const u8, scopes_json: []const u8) ![]domain.AgentMemory {
        return self.listInternal(allocator, category, session_id, null, .{ .actor_id = actor_id, .scopes_json = scopes_json }, true);
    }

    pub fn search(self: *MemoryAgentMemory, allocator: std.mem.Allocator, query: []const u8, limit: usize, session_id: ?[]const u8, scopes_json: []const u8, actor_id: ?[]const u8) ![]domain.AgentMemory {
        const actor = actor_id orelse return allocator.alloc(domain.AgentMemory, 0);
        if (limit == 0) return allocator.alloc(domain.AgentMemory, 0);
        const all = try self.listVisible(allocator, null, session_id, actor, scopes_json);
        defer {
            for (all) |*entry| freeAgentMemory(allocator, entry);
            allocator.free(all);
        }
        var out: std.ArrayListUnmanaged(domain.AgentMemory) = .empty;
        errdefer {
            for (out.items) |*entry| freeAgentMemory(allocator, entry);
            out.deinit(allocator);
        }
        const access_time = ids.nowMs();
        for (all) |*entry| {
            if (out.items.len >= @max(@as(usize, 1), limit)) break;
            const score = scoreText(query, entry.key) + scoreText(query, entry.content);
            if (score <= 0 and query.len > 0) continue;
            var copy = entry.*;
            copy.score = score + 0.5;
            try out.append(allocator, copy);
            self.touchEntryById(entry.id, access_time);
            detachAgentMemory(entry);
        }
        sortAgentMemory(out.items);
        if (out.items.len > limit) out.shrinkRetainingCapacity(limit);
        return out.toOwnedSlice(allocator);
    }

    pub fn delete(self: *MemoryAgentMemory, key: []const u8, session_id: ?[]const u8, actor_id: ?[]const u8, _: ?[]const u8) !bool {
        self.purgeExpired();
        const owner = actor_id orelse return false;
        const idx = self.findEntryIndex(owner, session_id, key) orelse return false;
        var removed = self.entries.orderedRemove(idx);
        freeAgentMemory(self.allocator, &removed.entry);
        return true;
    }

    pub fn count(self: *MemoryAgentMemory, actor_id: ?[]const u8, scopes_json: []const u8) !usize {
        self.purgeExpired();
        if (actor_id) |actor| {
            const visible = try self.listVisible(self.allocator, null, null, actor, scopes_json);
            defer {
                for (visible) |*entry| freeAgentMemory(self.allocator, entry);
                self.allocator.free(visible);
            }
            return visible.len;
        }
        return self.entries.items.len;
    }

    pub fn saveMessage(self: *MemoryAgentMemory, session_id: []const u8, role: []const u8, content: []const u8, actor_id: ?[]const u8) !void {
        self.purgeExpired();
        const actor = try access.requiredActorId(actor_id);
        const now = ids.nowMs();
        const stored = MemorySessionMessage{
            .actor_id = try self.allocator.dupe(u8, actor),
            .session_id = try self.allocator.dupe(u8, session_id),
            .role = try self.allocator.dupe(u8, role),
            .content = try self.allocator.dupe(u8, content),
            .created_at_ms = now,
            .last_access_ms = now,
        };
        errdefer {
            var cleanup = stored;
            freeMemorySessionMessage(self.allocator, &cleanup);
        }
        try self.messages.append(self.allocator, stored);
        self.enforceLimits();
    }

    pub fn loadMessages(self: *MemoryAgentMemory, allocator: std.mem.Allocator, session_id: []const u8, actor_id: ?[]const u8) ![]Message {
        self.purgeExpired();
        const actor = actor_id orelse return allocator.alloc(Message, 0);
        var out: std.ArrayListUnmanaged(Message) = .empty;
        errdefer {
            for (out.items) |*message| freeMessage(allocator, message);
            out.deinit(allocator);
        }
        const access_time = ids.nowMs();
        for (self.messages.items) |*message| {
            if (!std.mem.eql(u8, message.actor_id, actor) or !std.mem.eql(u8, message.session_id, session_id)) continue;
            message.last_access_ms = access_time;
            try out.append(allocator, .{
                .role = try allocator.dupe(u8, message.role),
                .content = try allocator.dupe(u8, message.content),
                .created_at_ms = message.created_at_ms,
            });
        }
        return out.toOwnedSlice(allocator);
    }

    pub fn clearMessages(self: *MemoryAgentMemory, session_id: []const u8, actor_id: ?[]const u8) !void {
        self.purgeExpired();
        const actor = actor_id orelse return;
        var i: usize = 0;
        while (i < self.messages.items.len) {
            if (std.mem.eql(u8, self.messages.items[i].actor_id, actor) and std.mem.eql(u8, self.messages.items[i].session_id, session_id)) {
                var removed = self.messages.orderedRemove(i);
                freeMemorySessionMessage(self.allocator, &removed);
                continue;
            }
            i += 1;
        }
    }

    pub fn clearAutoSaved(self: *MemoryAgentMemory, session_id: ?[]const u8, actor_id: ?[]const u8) !void {
        self.purgeExpired();
        const actor = actor_id orelse return;
        var i: usize = 0;
        while (i < self.messages.items.len) {
            const message = self.messages.items[i];
            const same_actor = std.mem.eql(u8, message.actor_id, actor);
            const same_session = if (session_id) |sid| std.mem.eql(u8, message.session_id, sid) else true;
            const autosave = std.mem.eql(u8, message.role, "autosave_user") or std.mem.eql(u8, message.role, "autosave_assistant");
            if (same_actor and same_session and autosave) {
                var removed = self.messages.orderedRemove(i);
                freeMemorySessionMessage(self.allocator, &removed);
                continue;
            }
            i += 1;
        }
    }

    pub fn saveUsage(self: *MemoryAgentMemory, session_id: []const u8, total_tokens: u64, actor_id: ?[]const u8) !void {
        self.purgeExpired();
        const actor = try access.requiredActorId(actor_id);
        const now = ids.nowMs();
        if (self.findUsageIndex(actor, session_id)) |idx| {
            self.usage.items[idx].total_tokens = total_tokens;
            self.usage.items[idx].updated_at_ms = now;
            self.usage.items[idx].last_access_ms = now;
            return;
        }
        const stored = MemoryUsage{
            .actor_id = try self.allocator.dupe(u8, actor),
            .session_id = try self.allocator.dupe(u8, session_id),
            .total_tokens = total_tokens,
            .updated_at_ms = now,
            .last_access_ms = now,
        };
        errdefer {
            var cleanup = stored;
            freeMemoryUsage(self.allocator, &cleanup);
        }
        try self.usage.append(self.allocator, stored);
        self.enforceLimits();
    }

    pub fn deleteUsage(self: *MemoryAgentMemory, session_id: []const u8, actor_id: ?[]const u8) !bool {
        self.purgeExpired();
        const actor = actor_id orelse return false;
        const idx = self.findUsageIndex(actor, session_id) orelse return false;
        var removed = self.usage.orderedRemove(idx);
        freeMemoryUsage(self.allocator, &removed);
        return true;
    }

    pub fn loadUsage(self: *MemoryAgentMemory, session_id: []const u8, actor_id: ?[]const u8) !?u64 {
        self.purgeExpired();
        const actor = actor_id orelse return null;
        const idx = self.findUsageIndex(actor, session_id) orelse return null;
        self.usage.items[idx].last_access_ms = ids.nowMs();
        return self.usage.items[idx].total_tokens;
    }

    pub fn listSessions(self: *MemoryAgentMemory, allocator: std.mem.Allocator, limit: usize, offset: usize, actor_id: ?[]const u8) !HistoryList {
        self.purgeExpired();
        const actor = actor_id orelse return .{ .total = 0, .sessions = try allocator.alloc(SessionInfo, 0) };
        var all_sessions: std.ArrayListUnmanaged(SessionInfo) = .empty;
        errdefer {
            for (all_sessions.items) |*info| freeSessionInfo(allocator, info);
            all_sessions.deinit(allocator);
        }
        for (self.messages.items) |message| {
            if (!std.mem.eql(u8, message.actor_id, actor)) continue;
            if (!domain.sessionMessageVisibleInHistory(message.role)) continue;
            if (findSessionInfo(all_sessions.items, message.session_id)) |idx| {
                all_sessions.items[idx].message_count += 1;
                all_sessions.items[idx].first_message_at = @min(all_sessions.items[idx].first_message_at, message.created_at_ms);
                all_sessions.items[idx].last_message_at = @max(all_sessions.items[idx].last_message_at, message.created_at_ms);
            } else {
                try all_sessions.append(allocator, .{
                    .session_id = try allocator.dupe(u8, message.session_id),
                    .message_count = 1,
                    .first_message_at = message.created_at_ms,
                    .last_message_at = message.created_at_ms,
                });
            }
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

    pub fn history(self: *MemoryAgentMemory, allocator: std.mem.Allocator, session_id: []const u8, limit: usize, offset: usize, actor_id: ?[]const u8) !HistoryShow {
        const messages = try self.loadMessages(allocator, session_id, actor_id);
        defer {
            for (messages) |*message| freeMessage(allocator, message);
            allocator.free(messages);
        }
        var total: usize = 0;
        var out: std.ArrayListUnmanaged(Message) = .empty;
        errdefer {
            for (out.items) |*message| freeMessage(allocator, message);
            out.deinit(allocator);
        }
        for (messages) |*message| {
            if (!domain.sessionMessageVisibleInHistory(message.role)) continue;
            if (total >= offset and out.items.len < limit) {
                try out.append(allocator, message.*);
                detachMessage(message);
            }
            total += 1;
        }
        return .{ .total = @intCast(total), .messages = try out.toOwnedSlice(allocator) };
    }

    const VisibleFilter = struct {
        actor_id: []const u8,
        scopes_json: []const u8,
    };

    fn listInternal(self: *MemoryAgentMemory, allocator: std.mem.Allocator, category: ?[]const u8, session_id: ?[]const u8, actor_id: ?[]const u8, visible: ?VisibleFilter, visible_only: bool) ![]domain.AgentMemory {
        self.purgeExpired();
        var out: std.ArrayListUnmanaged(domain.AgentMemory) = .empty;
        errdefer {
            for (out.items) |*entry| freeAgentMemory(allocator, entry);
            out.deinit(allocator);
        }
        for (self.entries.items) |wrapped| {
            const entry = wrapped.entry;
            if (actor_id) |actor| if (!std.mem.eql(u8, entry.actor_id, actor)) continue;
            if (category) |cat| if (!std.mem.eql(u8, entry.category, cat)) continue;
            if (session_id) |sid| {
                if (entry.session_id == null or !std.mem.eql(u8, entry.session_id.?, sid)) continue;
            } else if (entry.session_id != null) continue;
            if (visible_only) {
                const filter = visible orelse continue;
                if (!try entryVisible(allocator, entry, filter.actor_id, filter.scopes_json)) continue;
            }
            try out.append(allocator, try cloneAgentMemory(allocator, entry));
        }
        sortAgentMemory(out.items);
        return out.toOwnedSlice(allocator);
    }

    fn findEntryIndex(self: *MemoryAgentMemory, actor_id: []const u8, session_id: ?[]const u8, key: []const u8) ?usize {
        for (self.entries.items, 0..) |wrapped, i| {
            const entry = wrapped.entry;
            if (!std.mem.eql(u8, entry.actor_id, actor_id)) continue;
            if (!std.mem.eql(u8, entry.key, key)) continue;
            if (!sameOptionalString(entry.session_id, session_id)) continue;
            return i;
        }
        return null;
    }

    fn touchEntryById(self: *MemoryAgentMemory, id: []const u8, at_ms: i64) void {
        for (self.entries.items) |*wrapped| {
            if (std.mem.eql(u8, wrapped.entry.id, id)) {
                wrapped.last_access_ms = at_ms;
                return;
            }
        }
    }

    fn purgeExpired(self: *MemoryAgentMemory) void {
        const ttl = self.config.ttl_seconds orelse return;
        if (ttl == 0) return;
        const cutoff = ids.nowMs() - (@as(i64, @intCast(ttl)) * 1000);
        var i: usize = 0;
        while (i < self.entries.items.len) {
            if (parseMemoryTimestamp(self.entries.items[i].entry.timestamp) <= cutoff) {
                var removed = self.entries.orderedRemove(i);
                freeAgentMemory(self.allocator, &removed.entry);
                continue;
            }
            i += 1;
        }
        i = 0;
        while (i < self.messages.items.len) {
            if (self.messages.items[i].created_at_ms <= cutoff) {
                var removed = self.messages.orderedRemove(i);
                freeMemorySessionMessage(self.allocator, &removed);
                continue;
            }
            i += 1;
        }
        i = 0;
        while (i < self.usage.items.len) {
            if (self.usage.items[i].updated_at_ms <= cutoff) {
                var removed = self.usage.orderedRemove(i);
                freeMemoryUsage(self.allocator, &removed);
                continue;
            }
            i += 1;
        }
    }

    fn enforceLimits(self: *MemoryAgentMemory) void {
        self.purgeExpired();
        while (self.config.max_entries > 0 and self.entries.items.len > self.config.max_entries) {
            if (!self.evictLeastRecentEntry()) break;
        }
        while (self.config.max_messages > 0 and self.messages.items.len > self.config.max_messages) {
            if (!self.evictLeastRecentMessage()) break;
        }
        while (self.config.max_usage_entries > 0 and self.usage.items.len > self.config.max_usage_entries) {
            if (!self.evictLeastRecentUsage()) break;
        }
        while (self.config.max_bytes > 0 and self.approxMemoryBytes() > self.config.max_bytes) {
            if (!self.evictLeastRecentAny()) break;
        }
    }

    fn evictLeastRecentEntry(self: *MemoryAgentMemory) bool {
        if (self.entries.items.len == 0) return false;
        var idx: usize = 0;
        var oldest = self.entries.items[0].last_access_ms;
        for (self.entries.items[1..], 1..) |entry, i| {
            if (entry.last_access_ms < oldest) {
                oldest = entry.last_access_ms;
                idx = i;
            }
        }
        var removed = self.entries.orderedRemove(idx);
        freeAgentMemory(self.allocator, &removed.entry);
        return true;
    }

    fn evictLeastRecentMessage(self: *MemoryAgentMemory) bool {
        if (self.messages.items.len == 0) return false;
        var idx: usize = 0;
        var oldest = self.messages.items[0].last_access_ms;
        for (self.messages.items[1..], 1..) |message, i| {
            if (message.last_access_ms < oldest) {
                oldest = message.last_access_ms;
                idx = i;
            }
        }
        var removed = self.messages.orderedRemove(idx);
        freeMemorySessionMessage(self.allocator, &removed);
        return true;
    }

    fn evictLeastRecentUsage(self: *MemoryAgentMemory) bool {
        if (self.usage.items.len == 0) return false;
        var idx: usize = 0;
        var oldest = self.usage.items[0].last_access_ms;
        for (self.usage.items[1..], 1..) |item, i| {
            if (item.last_access_ms < oldest) {
                oldest = item.last_access_ms;
                idx = i;
            }
        }
        var removed = self.usage.orderedRemove(idx);
        freeMemoryUsage(self.allocator, &removed);
        return true;
    }

    fn evictLeastRecentAny(self: *MemoryAgentMemory) bool {
        var kind: enum { none, entry, message, usage } = .none;
        var oldest: i64 = 0;
        for (self.entries.items) |entry| {
            if (kind == .none or entry.last_access_ms < oldest) {
                kind = .entry;
                oldest = entry.last_access_ms;
            }
        }
        for (self.messages.items) |message| {
            if (kind == .none or message.last_access_ms < oldest) {
                kind = .message;
                oldest = message.last_access_ms;
            }
        }
        for (self.usage.items) |item| {
            if (kind == .none or item.last_access_ms < oldest) {
                kind = .usage;
                oldest = item.last_access_ms;
            }
        }
        return switch (kind) {
            .none => false,
            .entry => self.evictLeastRecentEntry(),
            .message => self.evictLeastRecentMessage(),
            .usage => self.evictLeastRecentUsage(),
        };
    }

    fn approxMemoryBytes(self: *MemoryAgentMemory) usize {
        var total: usize = 0;
        for (self.entries.items) |entry| total += agentMemoryByteSize(entry.entry);
        for (self.messages.items) |message| total += messageByteSize(message);
        for (self.usage.items) |item| total += usageByteSize(item);
        return total;
    }

    fn findUsageIndex(self: *MemoryAgentMemory, actor_id: []const u8, session_id: []const u8) ?usize {
        for (self.usage.items, 0..) |item, i| {
            if (std.mem.eql(u8, item.actor_id, actor_id) and std.mem.eql(u8, item.session_id, session_id)) return i;
        }
        return null;
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
        const reduced_content = try agent_memory_reducer.reduceContent(allocator, input.operation, if (old_entry) |entry| entry.content else null, input.content);
        defer allocator.free(reduced_content);

        const global = try self.globalIndexKey(allocator);
        defer allocator.free(global);
        const owner = try self.ownerIndexKey(allocator, owner_actor);
        defer allocator.free(owner);
        const cat = try self.categoryIndexKey(allocator, input.category);
        defer allocator.free(cat);
        const session_index = if (input.session_id) |sid| try self.agentSessionIndexKey(allocator, owner_actor, sid) else null;
        defer if (session_index) |key_value| allocator.free(key_value);

        try self.beginTransaction();
        var committed = false;
        defer if (!committed) self.discardTransaction();

        if (old_entry) |entry| try self.queueRemoveEntryIndexes(entry_key, entry);
        try self.queueCommand(&.{
            "HSET",             entry_key,
            "id",               entry_id,
            "key",              input.key,
            "content",          reduced_content,
            "category",         input.category,
            "timestamp",        timestamp_text,
            "session_id",       input.session_id orelse "",
            "actor_id",         owner_actor,
            "writer_actor_id",  writer_actor,
            "scope",            scope,
            "permissions_json", permissions,
        });
        try self.queueCommand(&.{ "SADD", global, entry_key });
        try self.queueCommand(&.{ "SADD", owner, entry_key });
        try self.queueCommand(&.{ "SADD", cat, entry_key });
        if (session_index) |key_value| try self.queueCommand(&.{ "SADD", key_value, entry_key });
        try self.queueExpireKey(entry_key);
        try self.queueExpireKey(global);
        try self.queueExpireKey(owner);
        try self.queueExpireKey(cat);
        if (session_index) |key_value| try self.queueExpireKey(key_value);
        var exec = try self.execTransaction();
        exec.deinit(self.allocator);
        committed = true;

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
        try self.beginTransaction();
        var committed = false;
        defer if (!committed) self.discardTransaction();
        if (try self.agentMemoryFromHash(self.allocator, existing_hash)) |existing| {
            var mutable_existing = existing;
            defer freeAgentMemory(self.allocator, &mutable_existing);
            try self.queueRemoveEntryIndexes(entry_key, mutable_existing);
        }
        try self.queueCommand(&.{ "DEL", entry_key });
        var resp = try self.execTransaction();
        committed = true;
        defer resp.deinit(self.allocator);
        const replies = switch (resp) {
            .array => |maybe_items| maybe_items orelse return false,
            else => return false,
        };
        if (replies.len == 0) return false;
        return switch (replies[replies.len - 1]) {
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

        try self.beginTransaction();
        var committed = false;
        defer if (!committed) self.discardTransaction();
        try self.queueCommand(&.{ "RPUSH", list_key, payload });
        try self.queueCommand(&.{ "SADD", sessions_key, session_id });
        try self.queueCommand(&.{ "HSET", meta_key, "last_message_at", created_text, "session_id", session_id });
        try self.queueCommand(&.{ "HSETNX", meta_key, "first_message_at", created_text });
        try self.queueCommand(&.{ "HINCRBY", meta_key, "message_count", "1" });
        try self.queueExpireKey(list_key);
        try self.queueExpireKey(meta_key);
        try self.queueExpireKey(sessions_key);
        var exec = try self.execTransaction();
        exec.deinit(self.allocator);
        committed = true;
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
        try self.beginTransaction();
        var committed = false;
        defer if (!committed) self.discardTransaction();
        try self.queueCommand(&.{ "DEL", list_key, meta_key });
        try self.queueCommand(&.{ "SREM", sessions_key, session_id });
        var exec = try self.execTransaction();
        exec.deinit(self.allocator);
        committed = true;
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
        try self.beginTransaction();
        var committed = false;
        defer if (!committed) self.discardTransaction();
        try self.queueCommand(&.{ "SET", key, value });
        try self.queueExpireKey(key);
        var exec = try self.execTransaction();
        exec.deinit(self.allocator);
        committed = true;
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
            if (try self.visibleSessionInfo(allocator, actor, sid)) |info| {
                try all_sessions.append(allocator, info);
            }
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
        var total: usize = 0;
        var out: std.ArrayListUnmanaged(Message) = .empty;
        errdefer {
            for (out.items) |*message| freeMessage(allocator, message);
            out.deinit(allocator);
        }
        for (messages) |*message| {
            if (!domain.sessionMessageVisibleInHistory(message.role)) continue;
            if (total >= offset and out.items.len < limit) {
                try out.append(allocator, message.*);
                detachMessage(message);
            }
            total += 1;
        }
        return .{ .total = @intCast(total), .messages = try out.toOwnedSlice(allocator) };
    }

    fn beginTransaction(self: *RedisAgentMemory) !void {
        var resp = try self.client.command(&.{"MULTI"});
        defer resp.deinit(self.allocator);
        try expectRedisSimple(resp, "OK");
    }

    fn queueCommand(self: *RedisAgentMemory, args: []const []const u8) !void {
        var resp = try self.client.command(args);
        defer resp.deinit(self.allocator);
        try expectRedisSimple(resp, "QUEUED");
    }

    fn execTransaction(self: *RedisAgentMemory) !redis.RespValue {
        var resp = try self.client.command(&.{"EXEC"});
        errdefer resp.deinit(self.allocator);
        switch (resp) {
            .array => |maybe_items| {
                if (maybe_items) |items| {
                    for (items) |item| {
                        if (item == .err) return error.RedisTransactionFailed;
                    }
                }
                return resp;
            },
            .err => return error.RedisTransactionFailed,
            else => return error.UnexpectedRedisResponse,
        }
    }

    fn discardTransaction(self: *RedisAgentMemory) void {
        var resp = self.client.command(&.{"DISCARD"}) catch return;
        resp.deinit(self.allocator);
    }

    fn queueExpireKey(self: *RedisAgentMemory, key: []const u8) !void {
        const ttl = self.ttl_seconds orelse return;
        if (ttl == 0) return;
        var ttl_buf: [16]u8 = undefined;
        const ttl_text = try std.fmt.bufPrint(&ttl_buf, "{d}", .{ttl});
        try self.queueCommand(&.{ "EXPIRE", key, ttl_text });
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

    fn queueRemoveEntryIndexes(self: *RedisAgentMemory, entry_key: []const u8, entry: domain.AgentMemory) !void {
        const global = try self.globalIndexKey(self.allocator);
        defer self.allocator.free(global);
        const owner = try self.ownerIndexKey(self.allocator, entry.actor_id);
        defer self.allocator.free(owner);
        const cat = try self.categoryIndexKey(self.allocator, entry.category);
        defer self.allocator.free(cat);
        try self.queueCommand(&.{ "SREM", global, entry_key });
        try self.queueCommand(&.{ "SREM", owner, entry_key });
        try self.queueCommand(&.{ "SREM", cat, entry_key });
        if (entry.session_id) |sid| {
            const session = try self.agentSessionIndexKey(self.allocator, entry.actor_id, sid);
            defer self.allocator.free(session);
            try self.queueCommand(&.{ "SREM", session, entry_key });
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
        const store_name = hashField(fields, "store") orelse "";
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
        const out_store = try allocator.dupe(u8, store_name);
        errdefer allocator.free(out_store);
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
            .store = out_store,
        };
    }

    fn visibleSessionInfo(self: *RedisAgentMemory, allocator: std.mem.Allocator, actor: []const u8, session_id: []const u8) !?SessionInfo {
        const messages = try self.loadMessages(allocator, session_id, actor);
        defer {
            for (messages) |*message| freeMessage(allocator, message);
            allocator.free(messages);
        }
        var visible_count: u64 = 0;
        var first: i64 = std.math.maxInt(i64);
        var last: i64 = 0;
        for (messages) |message| {
            if (!domain.sessionMessageVisibleInHistory(message.role)) continue;
            visible_count += 1;
            first = @min(first, message.created_at_ms);
            last = @max(last, message.created_at_ms);
        }
        if (visible_count == 0) return null;
        return .{
            .session_id = try allocator.dupe(u8, session_id),
            .message_count = visible_count,
            .first_message_at = first,
            .last_message_at = last,
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

const ApiHttpResponse = struct {
    status: std.http.Status,
    body: []u8,
};

pub const ApiAgentMemory = struct {
    allocator: std.mem.Allocator,
    config: ApiConfig,

    pub fn init(allocator: std.mem.Allocator, config: ApiConfig) !ApiAgentMemory {
        const base_url = config.base_url orelse return error.MissingApiBackendUrl;
        if (std.mem.trim(u8, base_url, " \t\r\n").len == 0) return error.MissingApiBackendUrl;
        try net_security.validateHttpBaseUrl(base_url, config.allow_insecure_http);
        return .{ .allocator = allocator, .config = config };
    }

    pub fn deinit(_: *ApiAgentMemory) void {}

    pub fn store(self: *ApiAgentMemory, allocator: std.mem.Allocator, input: Input) !domain.AgentMemory {
        if (input.operation != .put) return self.applyAgentMemoryReducer(allocator, input);
        const actor = try access.requiredActorId(input.writer_actor_id orelse input.actor_id);
        const encoded_key = try percentEncode(allocator, input.key);
        defer allocator.free(encoded_key);
        const path = try std.fmt.allocPrint(allocator, "/agent-memory/{s}", .{encoded_key});
        defer allocator.free(path);

        const body = try agentMemoryStorePayload(allocator, input);
        defer allocator.free(body);
        const response = try self.request(allocator, .PUT, path, "", actor, null, body);
        defer allocator.free(response.body);
        if (response.status != .ok) return error.AgentMemoryStorageUnavailable;
        return (try parseAgentMemoryWrapper(allocator, response.body, "memory")) orelse error.AgentMemoryStorageUnavailable;
    }

    fn applyAgentMemoryReducer(self: *ApiAgentMemory, allocator: std.mem.Allocator, input: Input) !domain.AgentMemory {
        const actor = try access.requiredActorId(input.writer_actor_id orelse input.actor_id);
        const body = try agentMemoryApplyPayload(allocator, input, actor);
        defer allocator.free(body);
        const response = try self.request(allocator, .POST, "/memory/apply", "", actor, null, body);
        defer allocator.free(response.body);
        if (response.status != .ok) return error.AgentMemoryStorageUnavailable;
        return (try self.getAppliedMemory(allocator, input, actor)) orelse error.AgentMemoryStorageUnavailable;
    }

    fn getAppliedMemory(self: *ApiAgentMemory, allocator: std.mem.Allocator, input: Input, actor: []const u8) !?domain.AgentMemory {
        return self.getWithScopes(allocator, input.key, input.session_id, actor, self.config.actor_scopes_json, input.scope);
    }

    pub fn get(self: *ApiAgentMemory, allocator: std.mem.Allocator, key: []const u8, session_id: ?[]const u8, actor_id: ?[]const u8) !?domain.AgentMemory {
        const actor = actor_id orelse return null;
        const scope = sharedScopeFromOwner(actor);
        const scopes = if (scope) |s| try scopesJson(allocator, &.{s}) else try allocator.dupe(u8, "[]");
        defer allocator.free(scopes);
        return self.getWithScopes(allocator, key, session_id, actor, scopes, scope);
    }

    pub fn getVisible(self: *ApiAgentMemory, allocator: std.mem.Allocator, key: []const u8, session_id: ?[]const u8, actor_id: []const u8, scopes_json: []const u8) !?domain.AgentMemory {
        return self.getWithScopes(allocator, key, session_id, actor_id, scopes_json, null);
    }

    pub fn list(self: *ApiAgentMemory, allocator: std.mem.Allocator, category: ?[]const u8, session_id: ?[]const u8, actor_id: ?[]const u8) ![]domain.AgentMemory {
        const actor = actor_id orelse return allocator.alloc(domain.AgentMemory, 0);
        return self.listVisible(allocator, category, session_id, actor, "[]");
    }

    pub fn listVisible(self: *ApiAgentMemory, allocator: std.mem.Allocator, category: ?[]const u8, session_id: ?[]const u8, actor_id: []const u8, scopes_json: []const u8) ![]domain.AgentMemory {
        var all: std.ArrayListUnmanaged(domain.AgentMemory) = .empty;
        errdefer {
            for (all.items) |*entry| freeAgentMemory(allocator, entry);
            all.deinit(allocator);
        }

        var offset: usize = 0;
        const page_size: usize = 500;
        while (true) {
            const query = try agentMemoryListQuery(allocator, category, session_id, page_size, offset);
            defer allocator.free(query);
            const response = try self.request(allocator, .GET, "/agent-memory", query, actor_id, scopes_json, "");
            defer allocator.free(response.body);
            if (response.status != .ok) return error.AgentMemoryStorageUnavailable;
            const page = try parseAgentMemoryArrayWrapper(allocator, response.body, "memories");
            defer allocator.free(page);
            const page_len = page.len;
            for (page) |entry| try all.append(allocator, entry);
            if (page_len < page_size) break;
            offset += page_size;
        }
        sortAgentMemory(all.items);
        return all.toOwnedSlice(allocator);
    }

    pub fn search(self: *ApiAgentMemory, allocator: std.mem.Allocator, query_text: []const u8, limit: usize, session_id: ?[]const u8, scopes_json: []const u8, actor_id: ?[]const u8) ![]domain.AgentMemory {
        const actor = actor_id orelse return allocator.alloc(domain.AgentMemory, 0);
        if (limit == 0) return allocator.alloc(domain.AgentMemory, 0);
        const body = try agentMemorySearchPayload(allocator, query_text, limit, session_id, scopes_json);
        defer allocator.free(body);
        const response = try self.request(allocator, .POST, "/agent-memory/search", "", actor, scopes_json, body);
        defer allocator.free(response.body);
        if (response.status != .ok) return error.AgentMemoryStorageUnavailable;
        const out = try parseAgentMemoryArrayWrapper(allocator, response.body, "memories");
        if (out.len > limit) {
            for (out[limit..]) |*entry| freeAgentMemory(allocator, entry);
            return allocator.realloc(out, limit);
        }
        return out;
    }

    pub fn delete(self: *ApiAgentMemory, key: []const u8, session_id: ?[]const u8, actor_id: ?[]const u8, writer_actor_id: ?[]const u8) !bool {
        const actor = writer_actor_id orelse actor_id orelse return false;
        const encoded_key = try percentEncode(self.allocator, key);
        defer self.allocator.free(encoded_key);
        const path = try std.fmt.allocPrint(self.allocator, "/agent-memory/{s}", .{encoded_key});
        defer self.allocator.free(path);
        const scope = if (actor_id) |owner| sharedScopeFromOwner(owner) else null;
        const query = try agentMemoryExactQuery(self.allocator, session_id, scope);
        defer self.allocator.free(query);
        const response = try self.request(self.allocator, .DELETE, path, query, actor, self.config.actor_scopes_json, "");
        defer self.allocator.free(response.body);
        if (response.status == .not_found) return false;
        if (response.status != .ok and response.status != .no_content) return error.AgentMemoryStorageUnavailable;
        return true;
    }

    pub fn count(self: *ApiAgentMemory, actor_id: ?[]const u8, scopes_json: []const u8) !usize {
        const actor = actor_id orelse "";
        const response = try self.request(self.allocator, .GET, "/agent-memory/count", "", actor, scopes_json, "");
        defer self.allocator.free(response.body);
        if (response.status != .ok) return error.AgentMemoryStorageUnavailable;
        return @intCast(parseJsonU64(response.body, "count", 0));
    }

    pub fn saveMessage(self: *ApiAgentMemory, session_id: []const u8, role: []const u8, content: []const u8, actor_id: ?[]const u8) !void {
        const actor = try access.requiredActorId(actor_id);
        const path = try sessionPath(self.allocator, session_id, "/messages");
        defer self.allocator.free(path);
        const scopes = try sessionScopesJson(self.allocator, session_id, true);
        defer self.allocator.free(scopes);
        const body = try messagePayload(self.allocator, role, content, ids.nowMs());
        defer self.allocator.free(body);
        const response = try self.request(self.allocator, .POST, path, "", actor, scopes, body);
        defer self.allocator.free(response.body);
        if (response.status != .ok) return error.AgentMemoryStorageUnavailable;
    }

    pub fn loadMessages(self: *ApiAgentMemory, allocator: std.mem.Allocator, session_id: []const u8, actor_id: ?[]const u8) ![]Message {
        const actor = actor_id orelse return allocator.alloc(Message, 0);
        const path = try sessionPath(allocator, session_id, "/messages");
        defer allocator.free(path);
        const scopes = try sessionScopesJson(allocator, session_id, false);
        defer allocator.free(scopes);
        const response = try self.request(allocator, .GET, path, "", actor, scopes, "");
        defer allocator.free(response.body);
        if (response.status != .ok) return error.AgentMemoryStorageUnavailable;
        return parseMessagesWrapper(allocator, response.body);
    }

    pub fn clearMessages(self: *ApiAgentMemory, session_id: []const u8, actor_id: ?[]const u8) !void {
        const actor = actor_id orelse return;
        const path = try sessionPath(self.allocator, session_id, "/messages");
        defer self.allocator.free(path);
        const scopes = try sessionScopesJson(self.allocator, session_id, true);
        defer self.allocator.free(scopes);
        const response = try self.request(self.allocator, .DELETE, path, "", actor, scopes, "");
        defer self.allocator.free(response.body);
        if (response.status != .ok and response.status != .no_content) return error.AgentMemoryStorageUnavailable;
    }

    pub fn clearAutoSaved(self: *ApiAgentMemory, session_id: ?[]const u8, actor_id: ?[]const u8) !void {
        const actor = actor_id orelse return;
        const query = if (session_id) |sid| blk: {
            const encoded = try percentEncode(self.allocator, sid);
            defer self.allocator.free(encoded);
            break :blk try std.fmt.allocPrint(self.allocator, "session_id={s}", .{encoded});
        } else try self.allocator.dupe(u8, "");
        defer self.allocator.free(query);
        const scopes = if (session_id) |sid| try sessionScopesJson(self.allocator, sid, true) else try allocatorSessionAllScopesJson(self.allocator, true);
        defer self.allocator.free(scopes);
        const response = try self.request(self.allocator, .DELETE, "/agent-sessions/auto-saved", query, actor, scopes, "");
        defer self.allocator.free(response.body);
        if (response.status != .ok and response.status != .no_content) return error.AgentMemoryStorageUnavailable;
    }

    pub fn saveUsage(self: *ApiAgentMemory, session_id: []const u8, total_tokens: u64, actor_id: ?[]const u8) !void {
        const actor = try access.requiredActorId(actor_id);
        const path = try sessionPath(self.allocator, session_id, "/usage");
        defer self.allocator.free(path);
        const scopes = try sessionScopesJson(self.allocator, session_id, true);
        defer self.allocator.free(scopes);
        const body = try std.fmt.allocPrint(self.allocator, "{{\"total_tokens\":{d}}}", .{total_tokens});
        defer self.allocator.free(body);
        const response = try self.request(self.allocator, .PUT, path, "", actor, scopes, body);
        defer self.allocator.free(response.body);
        if (response.status != .ok) return error.AgentMemoryStorageUnavailable;
    }

    pub fn deleteUsage(self: *ApiAgentMemory, session_id: []const u8, actor_id: ?[]const u8) !bool {
        const actor = actor_id orelse return false;
        const path = try sessionPath(self.allocator, session_id, "/usage");
        defer self.allocator.free(path);
        const scopes = try sessionScopesJson(self.allocator, session_id, true);
        defer self.allocator.free(scopes);
        const response = try self.request(self.allocator, .DELETE, path, "", actor, scopes, "");
        defer self.allocator.free(response.body);
        if (response.status == .not_found) return false;
        if (response.status != .ok and response.status != .no_content) return error.AgentMemoryStorageUnavailable;
        return true;
    }

    pub fn loadUsage(self: *ApiAgentMemory, session_id: []const u8, actor_id: ?[]const u8) !?u64 {
        const actor = actor_id orelse return null;
        const path = try sessionPath(self.allocator, session_id, "/usage");
        defer self.allocator.free(path);
        const scopes = try sessionScopesJson(self.allocator, session_id, false);
        defer self.allocator.free(scopes);
        const response = try self.request(self.allocator, .GET, path, "", actor, scopes, "");
        defer self.allocator.free(response.body);
        if (response.status == .not_found) return null;
        if (response.status != .ok) return error.AgentMemoryStorageUnavailable;
        return parseJsonU64(response.body, "total_tokens", 0);
    }

    pub fn listSessions(self: *ApiAgentMemory, allocator: std.mem.Allocator, limit: usize, offset: usize, actor_id: ?[]const u8) !HistoryList {
        const actor = actor_id orelse return .{ .total = 0, .sessions = try allocator.alloc(SessionInfo, 0) };
        const scopes = try allocatorSessionAllScopesJson(allocator, false);
        defer allocator.free(scopes);
        const query = try std.fmt.allocPrint(allocator, "limit={d}&offset={d}", .{ limit, offset });
        defer allocator.free(query);
        const response = try self.request(allocator, .GET, "/agent-sessions", query, actor, scopes, "");
        defer allocator.free(response.body);
        if (response.status != .ok) return error.AgentMemoryStorageUnavailable;
        return parseHistoryList(allocator, response.body);
    }

    pub fn history(self: *ApiAgentMemory, allocator: std.mem.Allocator, session_id: []const u8, limit: usize, offset: usize, actor_id: ?[]const u8) !HistoryShow {
        const actor = actor_id orelse return .{ .total = 0, .messages = try allocator.alloc(Message, 0) };
        const path = try sessionPath(allocator, session_id, "");
        defer allocator.free(path);
        const scopes = try sessionScopesJson(allocator, session_id, false);
        defer allocator.free(scopes);
        const query = try std.fmt.allocPrint(allocator, "limit={d}&offset={d}", .{ limit, offset });
        defer allocator.free(query);
        const response = try self.request(allocator, .GET, path, query, actor, scopes, "");
        defer allocator.free(response.body);
        if (response.status != .ok) return error.AgentMemoryStorageUnavailable;
        return parseHistoryShow(allocator, response.body);
    }

    fn getWithScopes(self: *ApiAgentMemory, allocator: std.mem.Allocator, key: []const u8, session_id: ?[]const u8, actor_id: []const u8, scopes_json: []const u8, explicit_scope: ?[]const u8) !?domain.AgentMemory {
        const encoded_key = try percentEncode(allocator, key);
        defer allocator.free(encoded_key);
        const path = try std.fmt.allocPrint(allocator, "/agent-memory/{s}", .{encoded_key});
        defer allocator.free(path);
        const query = try agentMemoryExactQuery(allocator, session_id, explicit_scope);
        defer allocator.free(query);
        const response = try self.request(allocator, .GET, path, query, actor_id, scopes_json, "");
        defer allocator.free(response.body);
        if (response.status == .not_found) return null;
        if (response.status != .ok) return error.AgentMemoryStorageUnavailable;
        return try parseAgentMemoryWrapper(allocator, response.body, "memory");
    }

    fn request(self: *ApiAgentMemory, allocator: std.mem.Allocator, method: std.http.Method, path: []const u8, query: []const u8, actor_id: ?[]const u8, scopes_json: ?[]const u8, payload: []const u8) !ApiHttpResponse {
        const url = try apiBackendUrl(allocator, self.config.base_url.?, path, query);
        defer allocator.free(url);
        return requestApiJson(allocator, method, url, self.config, actor_id, scopes_json, payload);
    }
};

fn agentMemoryStorePayload(allocator: std.mem.Allocator, input: Input) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"content\":");
    try json.appendString(&out, allocator, input.content);
    try out.appendSlice(allocator, ",\"category\":");
    try json.appendString(&out, allocator, input.category);
    try out.appendSlice(allocator, ",\"session_id\":");
    try json.appendNullableString(&out, allocator, input.session_id);
    try out.appendSlice(allocator, ",\"scope\":");
    try json.appendNullableString(&out, allocator, input.scope);
    try out.appendSlice(allocator, ",\"permissions\":");
    try json.appendRawJsonOr(&out, allocator, input.permissions_json, "[]");
    try out.appendSlice(allocator, ",\"metadata\":");
    try json.appendRawJsonOr(&out, allocator, input.metadata_json, "{}");
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

fn agentMemoryApplyPayload(allocator: std.mem.Allocator, input: Input, actor_id: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"event_type\":\"agent_memory.");
    try out.appendSlice(allocator, input.operation.name());
    try out.appendSlice(allocator, "\",\"operation\":\"");
    try out.appendSlice(allocator, input.operation.name());
    try out.appendSlice(allocator, "\",\"object_type\":\"agent_memory\",\"actor_id\":");
    try json.appendString(&out, allocator, actor_id);
    try out.appendSlice(allocator, ",\"payload\":{\"key\":");
    try json.appendString(&out, allocator, input.key);
    try out.appendSlice(allocator, ",\"category\":");
    try json.appendString(&out, allocator, input.category);
    try out.appendSlice(allocator, ",\"session_id\":");
    try json.appendNullableString(&out, allocator, input.session_id);
    try out.appendSlice(allocator, ",\"scope\":");
    try json.appendNullableString(&out, allocator, input.scope);
    try out.appendSlice(allocator, ",\"permissions\":");
    try json.appendRawJsonOr(&out, allocator, input.permissions_json, "[]");
    try out.appendSlice(allocator, ",\"metadata\":");
    try json.appendRawJsonOr(&out, allocator, input.metadata_json, "{}");
    switch (input.operation) {
        .put => {
            try out.appendSlice(allocator, ",\"content\":");
            try json.appendString(&out, allocator, input.content);
        },
        .merge_string_set => {
            try out.appendSlice(allocator, ",\"values\":");
            try json.appendRawJsonOr(&out, allocator, input.content, "[]");
        },
        .merge_object => {
            try out.appendSlice(allocator, ",\"object\":");
            try json.appendRawJsonOr(&out, allocator, input.content, "{}");
        },
    }
    try out.appendSlice(allocator, "}}");
    return out.toOwnedSlice(allocator);
}

fn agentMemorySearchPayload(allocator: std.mem.Allocator, query_text: []const u8, limit: usize, session_id: ?[]const u8, scopes_json: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"query\":");
    try json.appendString(&out, allocator, query_text);
    try out.print(allocator, ",\"limit\":{d},\"session_id\":", .{limit});
    try json.appendNullableString(&out, allocator, session_id);
    try out.appendSlice(allocator, ",\"scopes\":");
    try json.appendRawJsonOr(&out, allocator, scopes_json, "[]");
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

fn agentMemoryListQuery(allocator: std.mem.Allocator, category: ?[]const u8, session_id: ?[]const u8, limit: usize, offset: usize) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var first = true;
    try appendQueryUsize(allocator, &out, &first, "limit", limit);
    try appendQueryUsize(allocator, &out, &first, "offset", offset);
    if (category) |value| try appendQueryString(allocator, &out, &first, "category", value);
    if (session_id) |value| try appendQueryString(allocator, &out, &first, "session_id", value);
    return out.toOwnedSlice(allocator);
}

fn agentMemoryExactQuery(allocator: std.mem.Allocator, session_id: ?[]const u8, scope: ?[]const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var first = true;
    if (session_id) |value| try appendQueryString(allocator, &out, &first, "session_id", value);
    if (scope) |value| try appendQueryString(allocator, &out, &first, "scope", value);
    return out.toOwnedSlice(allocator);
}

fn sessionPath(allocator: std.mem.Allocator, session_id: []const u8, suffix: []const u8) ![]u8 {
    const encoded = try percentEncode(allocator, session_id);
    defer allocator.free(encoded);
    return std.fmt.allocPrint(allocator, "/agent-sessions/{s}{s}", .{ encoded, suffix });
}

fn sharedScopeFromOwner(actor_id: []const u8) ?[]const u8 {
    const prefix = "shared:";
    if (!std.mem.startsWith(u8, actor_id, prefix)) return null;
    return actor_id[prefix.len..];
}

fn scopesJson(allocator: std.mem.Allocator, scopes: []const []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '[');
    for (scopes, 0..) |scope, i| {
        if (i > 0) try out.append(allocator, ',');
        try json.appendString(&out, allocator, scope);
    }
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

fn sessionScopesJson(allocator: std.mem.Allocator, session_id: []const u8, write: bool) ![]u8 {
    const read_scope = try std.fmt.allocPrint(allocator, "session:{s}", .{session_id});
    defer allocator.free(read_scope);
    if (!write) return scopesJson(allocator, &.{read_scope});
    const write_scope = try std.fmt.allocPrint(allocator, "write:session:{s}", .{session_id});
    defer allocator.free(write_scope);
    return scopesJson(allocator, &.{ read_scope, write_scope });
}

fn allocatorSessionAllScopesJson(allocator: std.mem.Allocator, write: bool) ![]u8 {
    return if (write) scopesJson(allocator, &.{ "session:*", "write:session:*" }) else scopesJson(allocator, &.{"session:*"});
}

fn appendQueryUsize(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), first: *bool, name: []const u8, value: usize) !void {
    if (!first.*) try out.append(allocator, '&');
    first.* = false;
    try out.print(allocator, "{s}={d}", .{ name, value });
}

fn appendQueryString(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), first: *bool, name: []const u8, value: []const u8) !void {
    const encoded = try percentEncode(allocator, value);
    defer allocator.free(encoded);
    if (!first.*) try out.append(allocator, '&');
    first.* = false;
    try out.appendSlice(allocator, name);
    try out.append(allocator, '=');
    try out.appendSlice(allocator, encoded);
}

fn apiBackendUrl(allocator: std.mem.Allocator, base_url: []const u8, path: []const u8, query: []const u8) ![]u8 {
    var end = base_url.len;
    while (end > 0 and base_url[end - 1] == '/') : (end -= 1) {}
    const trimmed = base_url[0..end];
    const versioned = std.mem.endsWith(u8, trimmed, "/v1");
    const separator = if (path.len > 0 and path[0] == '/') "" else "/";
    if (query.len > 0) {
        if (versioned) return std.fmt.allocPrint(allocator, "{s}{s}{s}?{s}", .{ trimmed, separator, path, query });
        return std.fmt.allocPrint(allocator, "{s}/v1{s}{s}?{s}", .{ trimmed, separator, path, query });
    }
    if (versioned) return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ trimmed, separator, path });
    return std.fmt.allocPrint(allocator, "{s}/v1{s}{s}", .{ trimmed, separator, path });
}

fn requestApiJson(allocator: std.mem.Allocator, method: std.http.Method, url: []const u8, cfg: ApiConfig, actor_id: ?[]const u8, scopes_json: ?[]const u8, payload: []const u8) !ApiHttpResponse {
    var auth_header: ?[]u8 = null;
    defer if (auth_header) |h| allocator.free(h);

    var extra_headers_buf: [4]std.http.Header = undefined;
    var header_count: usize = 0;
    if (cfg.token) |token| {
        auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
        extra_headers_buf[header_count] = .{ .name = "Authorization", .value = auth_header.? };
        header_count += 1;
    }
    if (actor_id) |actor| {
        if (actor.len > 0) {
            extra_headers_buf[header_count] = .{ .name = "X-NullPantry-Actor-Id", .value = actor };
            header_count += 1;
        }
    }
    extra_headers_buf[header_count] = .{ .name = "X-NullPantry-Actor-Scopes", .value = scopes_json orelse cfg.actor_scopes_json };
    header_count += 1;
    extra_headers_buf[header_count] = .{ .name = "X-NullPantry-Actor-Capabilities", .value = cfg.actor_capabilities_json };
    header_count += 1;

    var client: std.http.Client = .{ .allocator = allocator, .io = compat.io() };
    defer client.deinit();

    const uri = std.Uri.parse(url) catch return error.AgentMemoryStorageUnavailable;
    var req = client.request(method, uri, .{
        .redirect_behavior = .unhandled,
        .keep_alive = false,
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .accept_encoding = .omit,
            .connection = .{ .override = "close" },
        },
        .extra_headers = extra_headers_buf[0..header_count],
    }) catch return error.AgentMemoryStorageUnavailable;
    defer req.deinit();

    applyApiSocketTimeout(req.connection, cfg.timeout_secs);

    if (method.requestHasBody()) {
        req.transfer_encoding = .{ .content_length = payload.len };
        var body_writer = req.sendBodyUnflushed(&.{}) catch return error.AgentMemoryStorageUnavailable;
        body_writer.writer.writeAll(payload) catch return error.AgentMemoryStorageUnavailable;
        body_writer.end() catch return error.AgentMemoryStorageUnavailable;
        req.connection.?.flush() catch return error.AgentMemoryStorageUnavailable;
    } else {
        req.sendBodiless() catch return error.AgentMemoryStorageUnavailable;
    }

    var response = req.receiveHead(&.{}) catch return error.AgentMemoryStorageUnavailable;
    const reader = response.reader(&.{});
    const read_limit = if (cfg.max_response_bytes == std.math.maxInt(usize)) cfg.max_response_bytes else cfg.max_response_bytes + 1;
    const body = reader.allocRemaining(allocator, .limited(read_limit)) catch return error.AgentMemoryStorageUnavailable;
    if (body.len > cfg.max_response_bytes) {
        allocator.free(body);
        return error.AgentMemoryResponseTooLarge;
    }
    return .{ .status = response.head.status, .body = body };
}

fn applyApiSocketTimeout(connection: ?*std.http.Client.Connection, timeout_secs: u32) void {
    if (timeout_secs == 0) return;
    switch (builtin.target.os.tag) {
        .windows => {},
        else => {
            const timeout = std.posix.timeval{ .sec = @intCast(@max(timeout_secs, 1)), .usec = 0 };
            if (connection) |conn| {
                const handle = conn.stream_reader.stream.socket.handle;
                std.posix.setsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {};
                std.posix.setsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&timeout)) catch {};
            }
        },
    }
}

fn parseAgentMemoryWrapper(allocator: std.mem.Allocator, body: []const u8, field: []const u8) !?domain.AgentMemory {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.AgentMemoryStorageUnavailable;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const value = parsed.value.object.get(field) orelse return null;
    return agentMemoryFromJsonValue(allocator, value);
}

fn parseAgentMemoryArrayWrapper(allocator: std.mem.Allocator, body: []const u8, field: []const u8) ![]domain.AgentMemory {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.AgentMemoryStorageUnavailable;
    defer parsed.deinit();
    if (parsed.value != .object) return allocator.alloc(domain.AgentMemory, 0);
    const value = parsed.value.object.get(field) orelse return allocator.alloc(domain.AgentMemory, 0);
    if (value != .array) return allocator.alloc(domain.AgentMemory, 0);
    var out: std.ArrayListUnmanaged(domain.AgentMemory) = .empty;
    errdefer {
        for (out.items) |*entry| freeAgentMemory(allocator, entry);
        out.deinit(allocator);
    }
    for (value.array.items) |item| {
        if (try agentMemoryFromJsonValue(allocator, item)) |entry| {
            try out.append(allocator, entry);
        }
    }
    return out.toOwnedSlice(allocator);
}

fn agentMemoryFromJsonValue(allocator: std.mem.Allocator, value: std.json.Value) !?domain.AgentMemory {
    if (value != .object) return null;
    const obj = value.object;
    const id_value = jsonStringishField(obj, &.{"id"}) orelse return null;
    const key_value = jsonStringishField(obj, &.{"key"}) orelse return null;
    const owner_value = jsonStringishField(obj, &.{ "actor_id", "owner_id" }) orelse return null;
    const id_value_owned = try allocator.dupe(u8, id_value);
    errdefer allocator.free(id_value_owned);
    const key = try allocator.dupe(u8, key_value);
    errdefer allocator.free(key);
    const content = try allocator.dupe(u8, jsonStringishField(obj, &.{"content"}) orelse "");
    errdefer allocator.free(content);
    const category = try allocator.dupe(u8, jsonStringishField(obj, &.{"category"}) orelse "core");
    errdefer allocator.free(category);
    const timestamp = try allocator.dupe(u8, jsonStringishField(obj, &.{"timestamp"}) orelse "0");
    errdefer allocator.free(timestamp);
    const session_id = try jsonNullableStringishField(allocator, obj, &.{"session_id"});
    errdefer if (session_id) |sid| allocator.free(sid);
    const owner = try allocator.dupe(u8, owner_value);
    errdefer allocator.free(owner);
    const writer = try allocator.dupe(u8, jsonStringishField(obj, &.{ "writer_actor_id", "created_by_actor_id" }) orelse owner_value);
    errdefer allocator.free(writer);
    const scope = try allocator.dupe(u8, jsonStringishField(obj, &.{"scope"}) orelse "");
    errdefer allocator.free(scope);
    const permissions = try jsonRawField(allocator, obj, &.{ "permissions", "permissions_json" }, "[]");
    errdefer allocator.free(permissions);
    const store = try allocator.dupe(u8, jsonStringishField(obj, &.{ "store", "storage" }) orelse "");
    errdefer allocator.free(store);
    return .{
        .id = id_value_owned,
        .key = key,
        .content = content,
        .category = category,
        .timestamp = timestamp,
        .session_id = session_id,
        .actor_id = owner,
        .writer_actor_id = writer,
        .scope = scope,
        .permissions_json = permissions,
        .store = store,
        .score = json.floatField(obj, "score"),
    };
}

fn parseMessagesWrapper(allocator: std.mem.Allocator, body: []const u8) ![]Message {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.AgentMemoryStorageUnavailable;
    defer parsed.deinit();
    if (parsed.value != .object) return allocator.alloc(Message, 0);
    const value = parsed.value.object.get("messages") orelse return allocator.alloc(Message, 0);
    return parseMessagesArray(allocator, value);
}

fn parseHistoryList(allocator: std.mem.Allocator, body: []const u8) !HistoryList {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.AgentMemoryStorageUnavailable;
    defer parsed.deinit();
    if (parsed.value != .object) return .{ .total = 0, .sessions = try allocator.alloc(SessionInfo, 0) };
    const obj = parsed.value.object;
    const value = obj.get("sessions") orelse return .{ .total = parseJsonU64(body, "total", 0), .sessions = try allocator.alloc(SessionInfo, 0) };
    if (value != .array) return .{ .total = parseJsonU64(body, "total", 0), .sessions = try allocator.alloc(SessionInfo, 0) };
    var out: std.ArrayListUnmanaged(SessionInfo) = .empty;
    errdefer {
        for (out.items) |*info| freeSessionInfo(allocator, info);
        out.deinit(allocator);
    }
    for (value.array.items) |item| {
        if (item != .object) continue;
        const session_id = jsonStringishField(item.object, &.{"session_id"}) orelse continue;
        try out.append(allocator, .{
            .session_id = try allocator.dupe(u8, session_id),
            .message_count = jsonU64Field(item.object, "message_count", 0),
            .first_message_at = jsonI64Field(item.object, "first_message_at", 0),
            .last_message_at = jsonI64Field(item.object, "last_message_at", 0),
        });
    }
    return .{ .total = jsonU64Field(obj, "total", out.items.len), .sessions = try out.toOwnedSlice(allocator) };
}

fn parseHistoryShow(allocator: std.mem.Allocator, body: []const u8) !HistoryShow {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.AgentMemoryStorageUnavailable;
    defer parsed.deinit();
    if (parsed.value != .object) return .{ .total = 0, .messages = try allocator.alloc(Message, 0) };
    const obj = parsed.value.object;
    const value = obj.get("messages") orelse return .{ .total = jsonU64Field(obj, "total", 0), .messages = try allocator.alloc(Message, 0) };
    const messages = try parseMessagesArray(allocator, value);
    return .{ .total = jsonU64Field(obj, "total", messages.len), .messages = messages };
}

fn parseMessagesArray(allocator: std.mem.Allocator, value: std.json.Value) ![]Message {
    if (value != .array) return allocator.alloc(Message, 0);
    var out: std.ArrayListUnmanaged(Message) = .empty;
    errdefer {
        for (out.items) |*message| freeMessage(allocator, message);
        out.deinit(allocator);
    }
    for (value.array.items) |item| {
        if (item != .object) continue;
        const role = try allocator.dupe(u8, jsonStringishField(item.object, &.{"role"}) orelse "");
        errdefer allocator.free(role);
        const content = try allocator.dupe(u8, jsonStringishField(item.object, &.{"content"}) orelse "");
        errdefer allocator.free(content);
        try out.append(allocator, .{
            .role = role,
            .content = content,
            .created_at_ms = jsonI64Field(item.object, "created_at_ms", jsonI64Field(item.object, "created_at", 0)),
        });
    }
    return out.toOwnedSlice(allocator);
}

fn jsonStringishField(obj: std.json.ObjectMap, names: []const []const u8) ?[]const u8 {
    for (names) |name| {
        const value = obj.get(name) orelse continue;
        switch (value) {
            .string => |s| return s,
            .integer, .float, .bool => continue,
            else => continue,
        }
    }
    return null;
}

fn jsonNullableStringishField(allocator: std.mem.Allocator, obj: std.json.ObjectMap, names: []const []const u8) !?[]u8 {
    for (names) |name| {
        const value = obj.get(name) orelse continue;
        switch (value) {
            .null => return null,
            .string => |s| {
                if (s.len == 0) return null;
                return try allocator.dupe(u8, s);
            },
            else => continue,
        }
    }
    return null;
}

fn jsonRawField(allocator: std.mem.Allocator, obj: std.json.ObjectMap, names: []const []const u8, fallback: []const u8) ![]u8 {
    for (names) |name| {
        const value = obj.get(name) orelse continue;
        if (std.mem.eql(u8, name, "permissions_json")) {
            if (value == .string) return allocator.dupe(u8, value.string);
        }
        return json.jsonFromValue(allocator, value);
    }
    return allocator.dupe(u8, fallback);
}

fn jsonU64Field(obj: std.json.ObjectMap, name: []const u8, fallback: u64) u64 {
    const value = obj.get(name) orelse return fallback;
    return switch (value) {
        .integer => |n| @intCast(@max(n, 0)),
        .float => |f| if (f < 0) fallback else @intFromFloat(f),
        .string => |s| std.fmt.parseInt(u64, s, 10) catch fallback,
        else => fallback,
    };
}

fn jsonI64Field(obj: std.json.ObjectMap, name: []const u8, fallback: i64) i64 {
    const value = obj.get(name) orelse return fallback;
    return switch (value) {
        .integer => |n| n,
        .float => |f| @intFromFloat(f),
        .string => |s| std.fmt.parseInt(i64, s, 10) catch fallback,
        else => fallback,
    };
}

fn parseJsonU64(body: []const u8, field: []const u8, fallback: u64) u64 {
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, body, .{}) catch return fallback;
    defer parsed.deinit();
    if (parsed.value != .object) return fallback;
    return jsonU64Field(parsed.value.object, field, fallback);
}

fn percentEncode(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    const digits = "0123456789ABCDEF";
    for (raw) |ch| {
        const unreserved = (ch >= 'a' and ch <= 'z') or
            (ch >= 'A' and ch <= 'Z') or
            (ch >= '0' and ch <= '9') or
            ch == '-' or ch == '_' or ch == '.' or ch == '~';
        if (unreserved) {
            try out.append(allocator, ch);
        } else {
            try out.append(allocator, '%');
            try out.append(allocator, digits[ch >> 4]);
            try out.append(allocator, digits[ch & 0x0f]);
        }
    }
    return out.toOwnedSlice(allocator);
}

fn expectRedisSimple(resp: redis.RespValue, expected: []const u8) !void {
    return switch (resp) {
        .simple_string => |value| if (std.mem.eql(u8, value, expected)) {} else error.UnexpectedRedisResponse,
        .err => error.RedisCommandFailed,
        else => error.UnexpectedRedisResponse,
    };
}

fn entryVisible(allocator: std.mem.Allocator, entry: domain.AgentMemory, actor_id: []const u8, scopes_json: []const u8) !bool {
    const record_visible = domain.scopeVisible(entry.scope, scopes_json) and
        access.permissionsVisibleForActor(allocator, entry.permissions_json, scopes_json, actor_id);
    return access.agentMemoryVisible(allocator, .{
        .owner_actor_id = entry.actor_id,
        .scope = entry.scope,
        .permissions_json = entry.permissions_json,
        .session_id = entry.session_id,
        .request_actor_id = actor_id,
        .request_scopes_json = scopes_json,
        .record_visible = record_visible,
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
    entry.store = "";
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
    if (entry.store.len > 0) allocator.free(entry.store);
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

fn cloneAgentMemory(allocator: std.mem.Allocator, entry: domain.AgentMemory) !domain.AgentMemory {
    return .{
        .id = try allocator.dupe(u8, entry.id),
        .key = try allocator.dupe(u8, entry.key),
        .content = try allocator.dupe(u8, entry.content),
        .category = try allocator.dupe(u8, entry.category),
        .timestamp = try allocator.dupe(u8, entry.timestamp),
        .session_id = if (entry.session_id) |sid| try allocator.dupe(u8, sid) else null,
        .actor_id = try allocator.dupe(u8, entry.actor_id),
        .writer_actor_id = try allocator.dupe(u8, if (entry.writer_actor_id.len > 0) entry.writer_actor_id else entry.actor_id),
        .scope = try allocator.dupe(u8, entry.scope),
        .permissions_json = try allocator.dupe(u8, entry.permissions_json),
        .store = try allocator.dupe(u8, entry.store),
        .score = entry.score,
    };
}

fn sameOptionalString(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

fn memoryEntryId(allocator: std.mem.Allocator, actor: []const u8, session_id: ?[]const u8, key: []const u8) ![]u8 {
    var hash_value = std.hash.Wyhash.hash(0, actor);
    hash_value = std.hash.Wyhash.hash(hash_value, session_id orelse "");
    hash_value = std.hash.Wyhash.hash(hash_value, key);
    return std.fmt.allocPrint(allocator, "agm_{x}", .{hash_value});
}

fn parseMemoryTimestamp(raw: []const u8) i64 {
    return std.fmt.parseInt(i64, raw, 10) catch 0;
}

fn agentMemoryByteSize(entry: domain.AgentMemory) usize {
    return entry.id.len +
        entry.key.len +
        entry.content.len +
        entry.category.len +
        entry.timestamp.len +
        (if (entry.session_id) |sid| sid.len else 0) +
        entry.actor_id.len +
        entry.writer_actor_id.len +
        entry.scope.len +
        entry.permissions_json.len +
        128;
}

fn messageByteSize(message: MemorySessionMessage) usize {
    return message.actor_id.len + message.session_id.len + message.role.len + message.content.len + 48;
}

fn usageByteSize(usage: MemoryUsage) usize {
    return usage.actor_id.len + usage.session_id.len + 40;
}

fn freeMemorySessionMessage(allocator: std.mem.Allocator, message: *MemorySessionMessage) void {
    if (message.actor_id.len > 0) allocator.free(message.actor_id);
    if (message.session_id.len > 0) allocator.free(message.session_id);
    if (message.role.len > 0) allocator.free(message.role);
    if (message.content.len > 0) allocator.free(message.content);
    message.* = .{ .actor_id = "", .session_id = "", .role = "", .content = "", .created_at_ms = 0, .last_access_ms = 0 };
}

fn freeMemoryUsage(allocator: std.mem.Allocator, usage: *MemoryUsage) void {
    if (usage.actor_id.len > 0) allocator.free(usage.actor_id);
    if (usage.session_id.len > 0) allocator.free(usage.session_id);
    usage.* = .{ .actor_id = "", .session_id = "", .total_tokens = 0, .updated_at_ms = 0, .last_access_ms = 0 };
}

fn findSessionInfo(items: []const SessionInfo, session_id: []const u8) ?usize {
    for (items, 0..) |item, i| {
        if (std.mem.eql(u8, item.session_id, session_id)) return i;
    }
    return null;
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
    try std.testing.expectEqual(BackendKind.none, BackendKind.parse("none"));
    try std.testing.expectEqual(BackendKind.memory_lru, BackendKind.parse("memory"));
    try std.testing.expectEqual(BackendKind.memory_lru, BackendKind.parse("memory_lru"));
    try std.testing.expectEqual(BackendKind.redis, BackendKind.parse("redis"));
    try std.testing.expectEqual(BackendKind.api, BackendKind.parse("api"));
    try std.testing.expectEqual(BackendKind.api, BackendKind.parse("http"));
    try std.testing.expectEqual(BackendKind.native, BackendKind.parse("sqlite"));
}

test "agent memory api backend builds urls and parses memory responses" {
    _ = try ApiAgentMemory.init(std.testing.allocator, .{ .base_url = "https://pantry.example/v1" });
    _ = try ApiAgentMemory.init(std.testing.allocator, .{ .base_url = "http://localhost:8765" });
    try std.testing.expectError(error.InsecureRuntimeUrl, ApiAgentMemory.init(std.testing.allocator, .{ .base_url = "http://pantry.internal:8765" }));
    _ = try ApiAgentMemory.init(std.testing.allocator, .{ .base_url = "http://pantry.internal:8765", .allow_insecure_http = true });

    const url_root = try apiBackendUrl(std.testing.allocator, "https://pantry.example", "/agent-memory/key", "limit=1");
    defer std.testing.allocator.free(url_root);
    try std.testing.expectEqualStrings("https://pantry.example/v1/agent-memory/key?limit=1", url_root);

    const url_v1 = try apiBackendUrl(std.testing.allocator, "https://pantry.example/v1/", "/agent-memory/key", "");
    defer std.testing.allocator.free(url_v1);
    try std.testing.expectEqualStrings("https://pantry.example/v1/agent-memory/key", url_v1);

    const encoded = try percentEncode(std.testing.allocator, "team pref/ru");
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("team%20pref%2Fru", encoded);

    const parsed = (try parseAgentMemoryWrapper(std.testing.allocator,
        \\{"memory":{"id":"m1","key":"pref","content":"value","category":"core","timestamp":"42","session_id":null,"owner_id":"agent:a","created_by_actor_id":"agent:b","scope":"agent:agent:a","permissions":["agent:a"],"score":0.7}}
    , "memory")).?;
    defer {
        var copy = parsed;
        freeAgentMemory(std.testing.allocator, &copy);
    }
    try std.testing.expectEqualStrings("agent:a", parsed.actor_id);
    try std.testing.expectEqualStrings("agent:b", parsed.writer_actor_id);
    try std.testing.expectEqualStrings("[\"agent:a\"]", parsed.permissions_json);

    const apply_payload = try agentMemoryApplyPayload(std.testing.allocator, .{
        .key = "team.tools",
        .content = "[\"zig\"]",
        .category = "prefs",
        .scope = "team:alpha",
        .permissions_json = "[\"team:secret\"]",
        .metadata_json = "{\"store\":\"remote\"}",
        .actor_id = "agent:a",
        .operation = .merge_string_set,
    }, "agent:a");
    defer std.testing.allocator.free(apply_payload);
    try std.testing.expect(std.mem.indexOf(u8, apply_payload, "\"event_type\":\"agent_memory.merge_string_set\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, apply_payload, "\"actor_id\":\"agent:a\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, apply_payload, "\"scope\":\"team:alpha\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, apply_payload, "\"permissions\":[\"team:secret\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, apply_payload, "\"values\":[\"zig\"]") != null);

    const exact_query = try agentMemoryExactQuery(std.testing.allocator, null, "team:alpha");
    defer std.testing.allocator.free(exact_query);
    try std.testing.expectEqualStrings("scope=team%3Aalpha", exact_query);
}

test "named runtime registry rejects reserved duplicate and native stores" {
    try std.testing.expectError(error.InvalidAgentMemoryStoreName, RuntimeRegistry.init(std.testing.allocator, &.{
        .{ .name = "native", .config = .{ .backend = .memory_lru } },
    }));
    try std.testing.expectError(error.InvalidAgentMemoryStoreBackend, RuntimeRegistry.init(std.testing.allocator, &.{
        .{ .name = "scratch", .config = .{ .backend = .native } },
    }));
    try std.testing.expectError(error.DuplicateAgentMemoryStoreName, RuntimeRegistry.init(std.testing.allocator, &.{
        .{ .name = "scratch", .config = .{ .backend = .memory_lru } },
        .{ .name = "scratch", .config = .{ .backend = .memory_lru } },
    }));
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

test "memory_lru and none agent memory runtimes match agent memory contract" {
    var none_runtime = try Runtime.init(std.testing.allocator, .{ .backend = .none });
    defer none_runtime.deinit();
    try std.testing.expect(none_runtime.isExternal());
    try std.testing.expectEqualStrings("none", none_runtime.backendName());
    try std.testing.expectError(error.AgentMemoryStorageUnavailable, none_runtime.store(std.testing.allocator, .{ .key = "ignored", .content = "ignored", .actor_id = "agent:none" }));
    const none_list = try none_runtime.listVisible(std.testing.allocator, null, null, "agent:none", "[\"public\"]");
    defer std.testing.allocator.free(none_list);
    try std.testing.expectEqual(@as(usize, 0), none_list.len);

    var runtime = try Runtime.init(std.testing.allocator, .{ .backend = .memory_lru });
    defer runtime.deinit();
    try std.testing.expect(runtime.isExternal());
    try std.testing.expectEqualStrings("memory_lru", runtime.backendName());

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
    const hidden_from_a = try runtime.getVisible(std.testing.allocator, "pref.lang", null, "agent:a", "[\"public\"]");
    try std.testing.expect(hidden_from_a != null);
    var hidden_copy = hidden_from_a.?;
    defer freeAgentMemory(std.testing.allocator, &hidden_copy);
    const shared_visible = (try runtime.getVisible(std.testing.allocator, "team.pref", null, "agent:b", "[\"team:alpha\"]")).?;
    defer {
        var copy = shared_visible;
        freeAgentMemory(std.testing.allocator, &copy);
    }
    try std.testing.expectEqualStrings("team shared", shared_visible.content);
    try std.testing.expect((try runtime.getVisible(std.testing.allocator, "team.pref", null, "agent:c", "[\"public\"]")) == null);

    try runtime.saveMessage("sess", "user", "hello from a", "agent:a");
    try runtime.saveMessage("sess", "user", "hello from b", "agent:b");
    try runtime.saveUsage("sess", 42, "agent:a");
    const usage = try runtime.loadUsage("sess", "agent:a");
    try std.testing.expectEqual(@as(?u64, 42), usage);
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
    try runtime.saveMessage("sess", domain.runtime_command_role, "internal runtime command", "agent:a");
    const history = try runtime.history(std.testing.allocator, "sess", 10, 0, "agent:a");
    defer {
        for (history.messages) |message| {
            std.testing.allocator.free(message.role);
            std.testing.allocator.free(message.content);
        }
        std.testing.allocator.free(history.messages);
    }
    try std.testing.expectEqual(@as(u64, 1), history.total);
    try std.testing.expectEqualStrings("hello from a", history.messages[0].content);
    const sessions = try runtime.listSessions(std.testing.allocator, 10, 0, "agent:a");
    defer {
        for (sessions.sessions) |session| std.testing.allocator.free(session.session_id);
        std.testing.allocator.free(sessions.sessions);
    }
    try std.testing.expectEqual(@as(u64, 1), sessions.total);
    try std.testing.expectEqual(@as(u64, 1), sessions.sessions[0].message_count);
}

test "memory_lru evicts least recently used agent memory entries" {
    var runtime = try Runtime.init(std.testing.allocator, .{
        .backend = .memory_lru,
        .memory = .{ .max_entries = 2 },
    });
    defer runtime.deinit();

    var first = try runtime.store(std.testing.allocator, .{ .key = "one", .content = "first", .actor_id = "agent:lru" });
    defer freeAgentMemory(std.testing.allocator, &first);
    var second = try runtime.store(std.testing.allocator, .{ .key = "two", .content = "second", .actor_id = "agent:lru" });
    defer freeAgentMemory(std.testing.allocator, &second);

    switch (runtime) {
        .memory_lru => |*engine| {
            engine.entries.items[engine.findEntryIndex("agent:lru", null, "one").?].last_access_ms = 1;
            engine.entries.items[engine.findEntryIndex("agent:lru", null, "two").?].last_access_ms = 2;
        },
        else => unreachable,
    }

    var touched = (try runtime.get(std.testing.allocator, "one", null, "agent:lru")).?;
    defer freeAgentMemory(std.testing.allocator, &touched);
    var third = try runtime.store(std.testing.allocator, .{ .key = "three", .content = "third", .actor_id = "agent:lru" });
    defer freeAgentMemory(std.testing.allocator, &third);

    var one = (try runtime.get(std.testing.allocator, "one", null, "agent:lru")).?;
    defer freeAgentMemory(std.testing.allocator, &one);
    try std.testing.expectEqualStrings("first", one.content);
    try std.testing.expect((try runtime.get(std.testing.allocator, "two", null, "agent:lru")) == null);
    var three = (try runtime.get(std.testing.allocator, "three", null, "agent:lru")).?;
    defer freeAgentMemory(std.testing.allocator, &three);
    try std.testing.expectEqualStrings("third", three.content);
}

test "memory_lru expires entries messages and usage by ttl" {
    var runtime = try Runtime.init(std.testing.allocator, .{
        .backend = .memory_lru,
        .memory = .{ .ttl_seconds = 1 },
    });
    defer runtime.deinit();

    var stored = try runtime.store(std.testing.allocator, .{ .key = "temp", .content = "old", .actor_id = "agent:ttl" });
    defer freeAgentMemory(std.testing.allocator, &stored);
    try runtime.saveMessage("session", "user", "old message", "agent:ttl");
    try runtime.saveUsage("session", 7, "agent:ttl");

    switch (runtime) {
        .memory_lru => |*engine| {
            const idx = engine.findEntryIndex("agent:ttl", null, "temp").?;
            engine.allocator.free(engine.entries.items[idx].entry.timestamp);
            engine.entries.items[idx].entry.timestamp = try engine.allocator.dupe(u8, "0");
            engine.entries.items[idx].last_access_ms = 0;
            engine.messages.items[0].created_at_ms = 0;
            engine.messages.items[0].last_access_ms = 0;
            engine.usage.items[0].updated_at_ms = 0;
            engine.usage.items[0].last_access_ms = 0;
        },
        else => unreachable,
    }

    try std.testing.expect((try runtime.get(std.testing.allocator, "temp", null, "agent:ttl")) == null);
    const messages = try runtime.loadMessages(std.testing.allocator, "session", "agent:ttl");
    defer std.testing.allocator.free(messages);
    try std.testing.expectEqual(@as(usize, 0), messages.len);
    try std.testing.expectEqual(@as(?u64, null), try runtime.loadUsage("session", "agent:ttl"));
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
    cfg.ttl_seconds = 60;

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
    switch (runtime) {
        .redis => |*engine| {
            const key = try engine.entryKey(std.testing.allocator, "agent:a", null, "pref.lang");
            defer std.testing.allocator.free(key);
            var ttl = try engine.client.command(&.{ "TTL", key });
            defer ttl.deinit(std.testing.allocator);
            try std.testing.expect(switch (ttl) {
                .integer => |value| value > 0,
                else => false,
            });
        },
        else => unreachable,
    }
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

    const private_search = try runtime.search(std.testing.allocator, "agent a", 10, null, "[]", "agent:a");
    defer {
        for (private_search) |*entry| freeAgentMemory(std.testing.allocator, entry);
        std.testing.allocator.free(private_search);
    }
    try std.testing.expect(private_search.len > 0);
    try std.testing.expectEqualStrings("agent a private", private_search[0].content);
    const shared_search = try runtime.search(std.testing.allocator, "team", 10, null, "[\"team:alpha\"]", "agent:b");
    defer {
        for (shared_search) |*entry| freeAgentMemory(std.testing.allocator, entry);
        std.testing.allocator.free(shared_search);
    }
    var saw_shared = false;
    for (shared_search) |entry| {
        if (std.mem.eql(u8, entry.content, "team shared")) saw_shared = true;
    }
    try std.testing.expect(saw_shared);
    try std.testing.expect((try runtime.count("agent:a", "[]")) >= 1);

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
    try runtime.saveMessage("sess", domain.runtime_command_role, "internal runtime command", "agent:a");
    try runtime.saveMessage("sess", "autosave_user", "draft", "agent:a");
    try runtime.saveMessage("sess", "assistant", "kept", "agent:a");
    try runtime.clearAutoSaved("sess", "agent:a");
    const history = try runtime.history(std.testing.allocator, "sess", 10, 0, "agent:a");
    defer {
        for (history.messages) |message| {
            std.testing.allocator.free(message.role);
            std.testing.allocator.free(message.content);
        }
        std.testing.allocator.free(history.messages);
    }
    try std.testing.expectEqual(@as(u64, 2), history.total);
    try std.testing.expectEqualStrings("hello from a", history.messages[0].content);
    try std.testing.expectEqualStrings("kept", history.messages[1].content);
    const sessions = try runtime.listSessions(std.testing.allocator, 10, 0, "agent:a");
    defer {
        for (sessions.sessions) |session| std.testing.allocator.free(session.session_id);
        std.testing.allocator.free(sessions.sessions);
    }
    try std.testing.expectEqual(@as(u64, 1), sessions.total);
    try std.testing.expectEqual(@as(u64, 2), sessions.sessions[0].message_count);
    try runtime.saveUsage("sess", 128, "agent:a");
    try std.testing.expectEqual(@as(?u64, 128), try runtime.loadUsage("sess", "agent:a"));
    try std.testing.expect(try runtime.deleteUsage("sess", "agent:a"));
    try std.testing.expectEqual(@as(?u64, null), try runtime.loadUsage("sess", "agent:a"));
    try std.testing.expect(try runtime.delete("pref.lang", null, "agent:a", "agent:a"));
    try std.testing.expect((try runtime.get(std.testing.allocator, "pref.lang", null, "agent:a")) == null);
    const still_b = (try runtime.get(std.testing.allocator, "pref.lang", null, "agent:b")).?;
    defer {
        var copy = still_b;
        freeAgentMemory(std.testing.allocator, &copy);
    }
    try std.testing.expectEqualStrings("agent b private", still_b.content);
}
