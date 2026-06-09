const std = @import("std");
const domain = @import("domain.zig");

pub const is_compiled = false;

pub const WriteInput = struct {
    key: []const u8,
    content: []const u8,
    category: []const u8 = "core",
    session_id: ?[]const u8 = null,
    owner_actor_id: []const u8,
    writer_actor_id: []const u8,
    requested_scope: ?[]const u8 = null,
    requested_permissions_json: []const u8 = "[]",
    metadata_json: ?[]const u8 = null,
    timestamp_ms: i64,
    status: []const u8 = "proposed",
    remote_id: ?[]const u8 = null,
};

pub const VisibleOwners = struct {
    owners: std.ArrayListUnmanaged([]u8) = .empty,
    requires_global_scan: bool = false,

    pub fn deinit(self: *VisibleOwners, allocator: std.mem.Allocator) void {
        for (self.owners.items) |owner| allocator.free(owner);
        self.owners.deinit(allocator);
    }
};

pub const VisibleContainerTags = struct {
    tags: std.ArrayListUnmanaged([]u8) = .empty,
    use_global_scan: bool = false,

    pub fn deinit(self: *VisibleContainerTags, allocator: std.mem.Allocator) void {
        for (self.tags.items) |tag| allocator.free(tag);
        self.tags.deinit(allocator);
    }
};

pub const SearchHit = struct {
    uri: []u8,
    score: ?f64 = null,

    pub fn deinit(self: *SearchHit, allocator: std.mem.Allocator) void {
        allocator.free(self.uri);
    }
};

pub const PageFetchPlan = struct {
    page_size: usize,
    max_pages: usize,
};

pub fn disabledString(allocator: std.mem.Allocator) ![]u8 {
    _ = allocator;
    return error.EngineNotCompiled;
}

pub fn disabledMaybeMemory(allocator: std.mem.Allocator) !?domain.AgentMemory {
    _ = allocator;
    return error.EngineNotCompiled;
}

pub fn disabledMemory(allocator: std.mem.Allocator) !domain.AgentMemory {
    _ = allocator;
    return error.EngineNotCompiled;
}

pub fn disabledMemorySlice(allocator: std.mem.Allocator) ![]domain.AgentMemory {
    _ = allocator;
    return error.EngineNotCompiled;
}

pub fn disabledHitSlice(allocator: std.mem.Allocator) ![]SearchHit {
    _ = allocator;
    return error.EngineNotCompiled;
}

pub fn disabledVisibleOwners(allocator: std.mem.Allocator) !VisibleOwners {
    _ = allocator;
    return error.EngineNotCompiled;
}

pub fn disabledContainerTags(allocator: std.mem.Allocator) !VisibleContainerTags {
    _ = allocator;
    return error.EngineNotCompiled;
}

pub fn disabledAppendMemory(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(domain.AgentMemory), entry: domain.AgentMemory) !void {
    _ = allocator;
    _ = out;
    _ = entry;
    return error.EngineNotCompiled;
}

pub fn disabledAppendPage(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(domain.AgentMemory)) !usize {
    _ = allocator;
    _ = out;
    return error.EngineNotCompiled;
}

pub fn disabledPageFetchPlan() PageFetchPlan {
    return .{ .page_size = 1, .max_pages = 0 };
}

pub fn disabledContinuePages() bool {
    return false;
}
