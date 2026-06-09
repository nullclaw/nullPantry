const std = @import("std");

pub const is_compiled = false;

pub const Limits = struct {
    max_results: usize = 6,
    max_snippet_chars: usize = 700,
    max_injected_chars: usize = 4000,
};

pub const NormalizedItem = struct {
    title: []const u8,
    content: []const u8,
    raw_content_uri: ?[]const u8,
    checksum: []const u8,
    metadata_json: []const u8,

    pub fn deinit(self: *NormalizedItem, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.content);
        if (self.raw_content_uri) |uri| allocator.free(uri);
        allocator.free(self.checksum);
        allocator.free(self.metadata_json);
        self.* = undefined;
    }
};

pub const SessionMarkdownOptions = struct {
    include_internal: bool = false,
    max_message_chars: usize = 64 * 1024,
};

pub const SessionExportWriteResult = struct {
    path: []const u8,
    written: bool,
    unchanged: bool,
    bytes: usize,
};

pub const SessionPruneResult = struct {
    deleted: usize = 0,
    skipped: usize = 0,
};

pub fn limitsFromObject(obj: std.json.ObjectMap) Limits {
    _ = obj;
    return .{};
}

pub fn normalizeValue(allocator: std.mem.Allocator, value: std.json.Value, limits: Limits) ![]NormalizedItem {
    _ = allocator;
    _ = value;
    _ = limits;
    return error.EngineNotCompiled;
}

pub fn deinitItems(allocator: std.mem.Allocator, items: []NormalizedItem) void {
    for (items) |*item| item.deinit(allocator);
    allocator.free(items);
}

pub fn appendSessionHeader(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), session_id: []const u8) !void {
    _ = allocator;
    _ = out;
    _ = session_id;
    return error.EngineNotCompiled;
}

pub fn appendSessionMessage(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    role: []const u8,
    content: []const u8,
    created_at_ms: i64,
    options: SessionMarkdownOptions,
) !bool {
    _ = allocator;
    _ = out;
    _ = role;
    _ = content;
    _ = created_at_ms;
    _ = options;
    return error.EngineNotCompiled;
}

pub fn sessionExportPath(allocator: std.mem.Allocator, directory: []const u8, session_id: []const u8) ![]const u8 {
    _ = allocator;
    _ = directory;
    _ = session_id;
    return error.EngineNotCompiled;
}

pub fn writeSessionExport(
    allocator: std.mem.Allocator,
    directory: []const u8,
    session_id: []const u8,
    markdown: []const u8,
    max_existing_bytes: usize,
) !SessionExportWriteResult {
    _ = allocator;
    _ = directory;
    _ = session_id;
    _ = markdown;
    _ = max_existing_bytes;
    return error.EngineNotCompiled;
}

pub fn pruneSessionExports(directory: []const u8, retention_days: u32) !SessionPruneResult {
    _ = directory;
    _ = retention_days;
    return error.EngineNotCompiled;
}
