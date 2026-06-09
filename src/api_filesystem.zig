const std = @import("std");

pub const default_root = ".";

pub fn resolvePath(allocator: std.mem.Allocator, root: []const u8, request_path: []const u8) ![]u8 {
    const safe_root = std.mem.trim(u8, root, " \t\r\n");
    if (safe_root.len == 0) return error.InvalidFilesystemRoot;

    const safe_request_path = try validateRequestPath(request_path);
    if (std.mem.eql(u8, safe_root, ".")) return allocator.dupe(u8, safe_request_path);
    return std.fs.path.join(allocator, &.{ safe_root, safe_request_path });
}

pub fn validateRequestPath(request_path: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, request_path, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidFilesystemPath;
    if (std.fs.path.isAbsolute(trimmed) or
        std.fs.path.isAbsolutePosix(trimmed) or
        std.fs.path.isAbsoluteWindows(trimmed))
    {
        return error.InvalidFilesystemPath;
    }

    var meaningful_components: usize = 0;
    var parts = std.mem.splitAny(u8, trimmed, "/\\");
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        for (part) |byte| {
            if (byte == 0) return error.InvalidFilesystemPath;
        }
        if (std.mem.eql(u8, part, "..")) return error.InvalidFilesystemPath;
        if (std.mem.eql(u8, part, ".")) continue;
        meaningful_components += 1;
    }

    if (meaningful_components == 0 and !std.mem.eql(u8, trimmed, ".")) {
        return error.InvalidFilesystemPath;
    }
    return trimmed;
}

test "api filesystem paths reject absolute and parent traversal" {
    try std.testing.expectEqualStrings("docs/memory.md", try validateRequestPath("docs/memory.md"));
    try std.testing.expectEqualStrings(".", try validateRequestPath("."));
    try std.testing.expectError(error.InvalidFilesystemPath, validateRequestPath("../secret.md"));
    try std.testing.expectError(error.InvalidFilesystemPath, validateRequestPath("docs/../../secret.md"));
    try std.testing.expectError(error.InvalidFilesystemPath, validateRequestPath("/etc/passwd"));
    try std.testing.expectError(error.InvalidFilesystemPath, validateRequestPath("C:\\Users\\secret"));
}
