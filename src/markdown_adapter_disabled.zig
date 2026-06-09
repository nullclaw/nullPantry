const std = @import("std");
const domain = @import("domain.zig");

pub const is_compiled = false;

pub const ParsedMarkdown = struct {
    title: []const u8,
    source_type: []const u8,
    artifact_type: []const u8,
    status: []const u8,
    scope: []const u8,
    permissions_json: []const u8,
    related_entities_json: []const u8,
    metadata_json: []const u8,
    fields_json: []const u8,
    author: ?[]const u8,
    owner: ?[]const u8,
    space_id: ?[]const u8,
    raw_content_uri: ?[]const u8,
    path: ?[]const u8,
    checksum: ?[]const u8,
    body: []const u8,

    pub fn deinit(self: ParsedMarkdown, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.source_type);
        allocator.free(self.artifact_type);
        allocator.free(self.status);
        allocator.free(self.scope);
        allocator.free(self.permissions_json);
        allocator.free(self.related_entities_json);
        allocator.free(self.metadata_json);
        allocator.free(self.fields_json);
        if (self.author) |value| allocator.free(value);
        if (self.owner) |value| allocator.free(value);
        if (self.space_id) |value| allocator.free(value);
        if (self.raw_content_uri) |value| allocator.free(value);
        if (self.path) |value| allocator.free(value);
        if (self.checksum) |value| allocator.free(value);
        allocator.free(self.body);
    }
};

pub fn parseImport(
    allocator: std.mem.Allocator,
    content: []const u8,
    fallback_title: []const u8,
    default_scope: []const u8,
    default_permissions_json: []const u8,
) !ParsedMarkdown {
    _ = allocator;
    _ = content;
    _ = fallback_title;
    _ = default_scope;
    _ = default_permissions_json;
    return error.EngineNotCompiled;
}

pub fn isMarkdownPath(path: []const u8) bool {
    _ = path;
    return false;
}

pub fn fallbackTitleFromPath(path: []const u8) []const u8 {
    return std.fs.path.basename(path);
}

pub fn exportFileName(allocator: std.mem.Allocator, title: []const u8, id: []const u8, prefix: []const u8) ![]const u8 {
    _ = allocator;
    _ = title;
    _ = id;
    _ = prefix;
    return error.EngineNotCompiled;
}

pub fn appendSourceMarkdown(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), source: domain.Source) !void {
    _ = allocator;
    _ = out;
    _ = source;
    return error.EngineNotCompiled;
}

pub fn appendArtifactMarkdown(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), artifact: domain.Artifact) !void {
    _ = allocator;
    _ = out;
    _ = artifact;
    return error.EngineNotCompiled;
}
