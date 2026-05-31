const std = @import("std");
const json = @import("json_util.zig");

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

pub fn limitsFromObject(obj: std.json.ObjectMap) Limits {
    var limits = Limits{};
    applyLimitFields(&limits, obj);
    if (obj.get("limits")) |value| {
        if (value == .object) applyLimitFields(&limits, value.object);
    }
    if (limits.max_results == 0) limits.max_results = 1;
    if (limits.max_snippet_chars == 0) limits.max_snippet_chars = 1;
    if (limits.max_injected_chars == 0) limits.max_injected_chars = limits.max_snippet_chars;
    return limits;
}

pub fn normalizeValue(allocator: std.mem.Allocator, value: std.json.Value, limits: Limits) ![]NormalizedItem {
    var items: std.ArrayListUnmanaged(NormalizedItem) = .empty;
    errdefer {
        for (items.items) |*item| item.deinit(allocator);
        items.deinit(allocator);
    }

    var total_chars: usize = 0;
    switch (value) {
        .array => |array| {
            for (array.items, 0..) |item_value, i| {
                if (items.items.len >= limits.max_results or total_chars >= limits.max_injected_chars) break;
                if (item_value != .object) continue;
                if (try normalizeObject(allocator, item_value.object, limits, i, &total_chars)) |item| {
                    try items.append(allocator, item);
                }
            }
        },
        .object => |obj| {
            if (try normalizeObject(allocator, obj, limits, 0, &total_chars)) |item| {
                try items.append(allocator, item);
            }
        },
        else => return allocator.alloc(NormalizedItem, 0),
    }

    return items.toOwnedSlice(allocator);
}

pub fn deinitItems(allocator: std.mem.Allocator, items: []NormalizedItem) void {
    for (items) |*item| item.deinit(allocator);
    allocator.free(items);
}

fn applyLimitFields(limits: *Limits, obj: std.json.ObjectMap) void {
    if (json.intField(obj, "max_results")) |value| limits.max_results = positiveUsize(value, limits.max_results);
    if (json.intField(obj, "max_snippet_chars")) |value| limits.max_snippet_chars = positiveUsize(value, limits.max_snippet_chars);
    if (json.intField(obj, "max_injected_chars")) |value| limits.max_injected_chars = positiveUsize(value, limits.max_injected_chars);
}

fn positiveUsize(value: i64, fallback: usize) usize {
    if (value <= 0) return fallback;
    return @intCast(value);
}

fn normalizeObject(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    limits: Limits,
    rank: usize,
    total_chars: *usize,
) !?NormalizedItem {
    const path = nonEmpty(json.stringField(obj, "path") orelse json.stringField(obj, "file") orelse json.stringField(obj, "source_path"));
    const title_field = nonEmpty(json.stringField(obj, "title") orelse json.stringField(obj, "key"));
    const raw_content = nonEmpty(json.stringField(obj, "content") orelse json.stringField(obj, "text") orelse json.stringField(obj, "snippet"));
    const title = title_field orelse (if (path) |p| fallbackTitleFromPath(p) else null) orelse "qmd result";
    const content = raw_content orelse title;

    if (path == null and title_field == null and raw_content == null) return null;
    if (total_chars.* >= limits.max_injected_chars) return null;

    const remaining = limits.max_injected_chars - total_chars.*;
    const snippet_len = @min(@min(content.len, limits.max_snippet_chars), remaining);
    const snippet = content[0..snippet_len];
    total_chars.* += snippet_len;

    const metadata_json = try metadataJson(allocator, obj, path, title, snippet, rank);
    errdefer allocator.free(metadata_json);

    return .{
        .title = try allocator.dupe(u8, title),
        .content = try allocator.dupe(u8, content),
        .raw_content_uri = if (path) |p| try allocator.dupe(u8, p) else null,
        .checksum = try checksum(allocator, path, content),
        .metadata_json = metadata_json,
    };
}

fn metadataJson(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    path: ?[]const u8,
    title: []const u8,
    snippet: []const u8,
    rank: usize,
) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"connector\":\"qmd\",\"rank\":");
    try out.print(allocator, "{d}", .{rank + 1});
    try out.appendSlice(allocator, ",\"title\":");
    try json.appendString(&out, allocator, title);
    if (path) |p| {
        try out.appendSlice(allocator, ",\"path\":");
        try json.appendString(&out, allocator, p);
    }
    if (json.intField(obj, "start_line")) |line| {
        try out.print(allocator, ",\"start_line\":{d}", .{line});
    }
    if (json.intField(obj, "end_line")) |line| {
        try out.print(allocator, ",\"end_line\":{d}", .{line});
    }
    if (snippet.len > 0) {
        try out.appendSlice(allocator, ",\"snippet\":");
        try json.appendString(&out, allocator, snippet);
    }
    if (obj.get("metadata")) |value| {
        const raw = try json.jsonFromValue(allocator, value);
        defer allocator.free(raw);
        try out.appendSlice(allocator, ",\"metadata\":");
        try json.appendRawJsonOr(&out, allocator, raw, "{}");
    }
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

fn checksum(allocator: std.mem.Allocator, path: ?[]const u8, content: []const u8) ![]const u8 {
    var hasher = std.hash.Wyhash.init(0);
    if (path) |p| hasher.update(p);
    hasher.update(content);
    return std.fmt.allocPrint(allocator, "wyhash:{x}", .{hasher.final()});
}

fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    const text = value orelse return null;
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    return if (trimmed.len == 0) null else trimmed;
}

fn fallbackTitleFromPath(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    if (endsWithIgnoreCase(base, ".markdown")) return base[0 .. base.len - ".markdown".len];
    if (endsWithIgnoreCase(base, ".md")) return base[0 .. base.len - ".md".len];
    return base;
}

fn endsWithIgnoreCase(value: []const u8, suffix: []const u8) bool {
    if (suffix.len > value.len) return false;
    return std.ascii.eqlIgnoreCase(value[value.len - suffix.len ..], suffix);
}

test "qmd adapter normalizes result arrays with limits and metadata" {
    const body =
        \\[
        \\ {"path":"docs/a.md","content":"Decision: A uses NullPantry","start_line":10,"end_line":12},
        \\ {"title":"B","text":"Constraint: B stays small"}
        \\]
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const items = try normalizeValue(std.testing.allocator, parsed.value, .{ .max_results = 4, .max_snippet_chars = 16, .max_injected_chars = 24 });
    defer deinitItems(std.testing.allocator, items);

    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("a", items[0].title);
    try std.testing.expectEqualStrings("docs/a.md", items[0].raw_content_uri.?);
    try std.testing.expect(std.mem.indexOf(u8, items[0].metadata_json, "\"connector\":\"qmd\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, items[0].metadata_json, "\"start_line\":10") != null);
    try std.testing.expect(std.mem.indexOf(u8, items[0].metadata_json, "Decision: A uses") != null);
}

test "qmd adapter accepts object shaped single result" {
    const body = "{\"path\":\"session/s1.md\",\"text\":\"Action: capture session context\"}";
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const items = try normalizeValue(std.testing.allocator, parsed.value, .{});
    defer deinitItems(std.testing.allocator, items);

    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("s1", items[0].title);
    try std.testing.expect(std.mem.indexOf(u8, items[0].content, "Action: capture") != null);
}
