const std = @import("std");
const compat = @import("compat.zig");
const markdown_adapter = @import("markdown_adapter.zig");

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
) !DirectoryReadResult {
    var dir = try std.Io.Dir.cwd().openDir(compat.io(), root_path, .{ .iterate = true });
    defer dir.close(compat.io());

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var files: std.ArrayList(DiscoveredFile) = .empty;
    errdefer {
        for (files.items) |file| {
            allocator.free(file.path);
            allocator.free(file.fallback_title);
            allocator.free(file.content);
            allocator.free(file.checksum);
        }
        files.deinit(allocator);
    }

    var skipped: usize = 0;
    while (try walker.next(compat.io())) |entry| {
        if (entry.kind != .file) continue;
        if (!markdown_adapter.isMarkdownPath(entry.path)) {
            skipped += 1;
            continue;
        }
        if (files.items.len >= max_files) {
            skipped += 1;
            continue;
        }

        const full_path = try std.fs.path.join(allocator, &.{ root_path, entry.path });
        const content = try std.Io.Dir.cwd().readFileAlloc(compat.io(), full_path, allocator, .limited(max_file_bytes));
        try files.append(allocator, .{
            .path = full_path,
            .fallback_title = try allocator.dupe(u8, markdown_adapter.fallbackTitleFromPath(entry.basename)),
            .content = content,
            .checksum = try contentChecksum(allocator, content),
        });
    }

    return .{ .files = try files.toOwnedSlice(allocator), .skipped = skipped };
}

pub fn writeFile(path: []const u8, content: []const u8, overwrite: bool) !void {
    if (std.fs.path.dirname(path)) |parent| {
        if (parent.len > 0) try std.Io.Dir.cwd().createDirPath(compat.io(), parent);
    }
    try std.Io.Dir.cwd().writeFile(compat.io(), .{
        .sub_path = path,
        .data = content,
        .flags = .{ .truncate = overwrite, .exclusive = !overwrite },
    });
}

pub fn contentChecksum(allocator: std.mem.Allocator, content: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "wyhash:{x}", .{std.hash.Wyhash.hash(0, content)});
}

test "markdown filesystem discovers markdown files recursively" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const root_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/markdown-fs", .{tmp.sub_path});
    defer alloc.free(root_path);
    const nested_path = try std.fs.path.join(alloc, &.{ root_path, "nested" });
    defer alloc.free(nested_path);
    try std.Io.Dir.cwd().createDirPath(compat.io(), nested_path);
    const a_path = try std.fs.path.join(alloc, &.{ root_path, "a.md" });
    defer alloc.free(a_path);
    const b_path = try std.fs.path.join(alloc, &.{ nested_path, "b.markdown" });
    defer alloc.free(b_path);
    const ignored_path = try std.fs.path.join(alloc, &.{ root_path, "ignore.txt" });
    defer alloc.free(ignored_path);
    try std.Io.Dir.cwd().writeFile(compat.io(), .{ .sub_path = a_path, .data = "# A\n" });
    try std.Io.Dir.cwd().writeFile(compat.io(), .{ .sub_path = b_path, .data = "# B\n" });
    try std.Io.Dir.cwd().writeFile(compat.io(), .{ .sub_path = ignored_path, .data = "ignore" });

    const result = try readDirectory(alloc, root_path, 10, 1024 * 1024);
    defer deinitDirectoryReadResult(alloc, result);
    try std.testing.expectEqual(@as(usize, 2), result.files.len);
    try std.testing.expectEqual(@as(usize, 1), result.skipped);
}
