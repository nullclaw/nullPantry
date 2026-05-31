const std = @import("std");
const json = @import("json_util.zig");

pub const key_prefix = "__bootstrap.prompt.";

pub const Doc = struct {
    filename: []const u8,
    memory_key: []const u8,
};

pub const docs = [_]Doc{
    .{ .filename = "AGENTS.md", .memory_key = "__bootstrap.prompt.AGENTS.md" },
    .{ .filename = "SOUL.md", .memory_key = "__bootstrap.prompt.SOUL.md" },
    .{ .filename = "TOOLS.md", .memory_key = "__bootstrap.prompt.TOOLS.md" },
    .{ .filename = "CONFIG.md", .memory_key = "__bootstrap.prompt.CONFIG.md" },
    .{ .filename = "IDENTITY.md", .memory_key = "__bootstrap.prompt.IDENTITY.md" },
    .{ .filename = "USER.md", .memory_key = "__bootstrap.prompt.USER.md" },
    .{ .filename = "HEARTBEAT.md", .memory_key = "__bootstrap.prompt.HEARTBEAT.md" },
    .{ .filename = "BOOTSTRAP.md", .memory_key = "__bootstrap.prompt.BOOTSTRAP.md" },
    .{ .filename = "MEMORY.md", .memory_key = "__bootstrap.prompt.MEMORY.md" },
};

pub fn memoryKey(filename: []const u8) ?[]const u8 {
    for (docs) |doc| {
        if (std.mem.eql(u8, doc.filename, filename)) return doc.memory_key;
    }
    return null;
}

pub fn usesWorkspaceFiles(memory_backend: ?[]const u8) bool {
    const backend = memory_backend orelse return true;
    return std.mem.eql(u8, backend, "markdown") or std.mem.eql(u8, backend, "hybrid");
}

pub fn isInternalKey(key: []const u8) bool {
    return std.mem.startsWith(u8, key, key_prefix);
}

pub const Fingerprint = struct {
    value: u64,
    present: usize,
    total: usize,
};

pub fn fingerprint(entries: []const ?[]const u8) Fingerprint {
    var hasher = std.hash.Fnv1a_64.init();
    var present: usize = 0;
    for (docs, 0..) |doc, i| {
        hasher.update(doc.filename);
        hasher.update("\n");
        if (i < entries.len and entries[i] != null) {
            present += 1;
            hasher.update("present");
            hasher.update(entries[i].?);
        } else {
            hasher.update("missing");
        }
        hasher.update("\n");
    }
    return .{ .value = hasher.final(), .present = present, .total = docs.len };
}

pub const Excerpt = struct {
    content: []const u8,
    truncated: bool,
};

pub fn excerpt(allocator: std.mem.Allocator, content: []const u8, max_bytes: usize) !Excerpt {
    if (max_bytes == 0 or content.len <= max_bytes) {
        return .{ .content = content, .truncated = false };
    }
    const suffix = "\n[truncated]\n";
    if (max_bytes <= suffix.len + 4) {
        const end = utf8End(content, max_bytes);
        return .{ .content = try allocator.dupe(u8, content[0..end]), .truncated = true };
    }
    const keep_len = max_bytes - suffix.len;
    const end = utf8End(content, keep_len);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, content[0..end]);
    try out.appendSlice(allocator, suffix);
    return .{ .content = try out.toOwnedSlice(allocator), .truncated = true };
}

fn utf8End(text: []const u8, requested: usize) usize {
    var end = @min(text.len, requested);
    if (end == text.len) return end;
    while (end > 0 and (text[end] & 0xc0) == 0x80) end -= 1;
    return end;
}

pub const StoreBodyOptions = struct {
    scope: ?[]const u8 = null,
    permissions_json: []const u8 = "[]",
    storage: ?[]const u8 = null,
    store: ?[]const u8 = null,
    target_store: ?[]const u8 = null,
    stores_json: ?[]const u8 = null,
};

pub fn buildStoreBody(allocator: std.mem.Allocator, content: []const u8, options: StoreBodyOptions) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"content\":");
    try json.appendString(&out, allocator, content);
    try out.appendSlice(allocator, ",\"category\":\"core\"");
    if (options.scope) |scope| {
        try out.appendSlice(allocator, ",\"scope\":");
        try json.appendString(&out, allocator, scope);
    }
    try out.appendSlice(allocator, ",\"permissions\":");
    try json.appendRawJsonOr(&out, allocator, options.permissions_json, "[]");
    if (options.storage) |value| try appendStringField(allocator, &out, "storage", value);
    if (options.store) |value| try appendStringField(allocator, &out, "store", value);
    if (options.target_store) |value| try appendStringField(allocator, &out, "target_store", value);
    if (options.stores_json) |value| {
        try out.appendSlice(allocator, ",\"stores\":");
        try json.appendRawJsonOr(&out, allocator, value, "[]");
    }
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

fn appendStringField(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), name: []const u8, value: []const u8) !void {
    try out.append(allocator, ',');
    try json.appendString(out, allocator, name);
    try out.append(allocator, ':');
    try json.appendString(out, allocator, value);
}

test "bootstrap prompt registry mirrors nullclaw prompt keys" {
    try std.testing.expectEqualStrings("__bootstrap.prompt.AGENTS.md", memoryKey("AGENTS.md").?);
    try std.testing.expect(memoryKey("README.md") == null);
    try std.testing.expect(usesWorkspaceFiles("markdown"));
    try std.testing.expect(!usesWorkspaceFiles("redis"));
    try std.testing.expect(isInternalKey("__bootstrap.prompt.MEMORY.md"));
}

test "bootstrap prompt fingerprint is stable over registered docs" {
    const inputs = [_]?[]const u8{ "a", null, "c" };
    const first = fingerprint(inputs[0..]);
    const second = fingerprint(inputs[0..]);
    try std.testing.expectEqual(first.value, second.value);
    try std.testing.expectEqual(@as(usize, 2), first.present);
    try std.testing.expectEqual(@as(usize, docs.len), first.total);
}
