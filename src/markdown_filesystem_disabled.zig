const std = @import("std");

pub const is_compiled = false;

pub const DiscoveredFile = struct {
    path: []const u8,
    fallback_title: []const u8,
    content: []const u8,
    checksum: []const u8,
};

pub const DirectoryReadResult = struct {
    files: []DiscoveredFile,
    skipped: usize,
};

pub fn deinitDirectoryReadResult(allocator: std.mem.Allocator, result: DirectoryReadResult) void {
    for (result.files) |file| {
        allocator.free(file.path);
        allocator.free(file.fallback_title);
        allocator.free(file.content);
        allocator.free(file.checksum);
    }
    allocator.free(result.files);
}

pub fn readDirectory(
    allocator: std.mem.Allocator,
    root_path: []const u8,
    max_files: usize,
    max_file_bytes: usize,
    max_total_bytes: usize,
) !DirectoryReadResult {
    _ = allocator;
    _ = root_path;
    _ = max_files;
    _ = max_file_bytes;
    _ = max_total_bytes;
    return error.EngineNotCompiled;
}

pub fn writeFile(path: []const u8, content: []const u8, overwrite: bool) !void {
    _ = path;
    _ = content;
    _ = overwrite;
    return error.EngineNotCompiled;
}

pub fn contentChecksum(allocator: std.mem.Allocator, content: []const u8) ![]const u8 {
    _ = allocator;
    _ = content;
    return error.EngineNotCompiled;
}
