const std = @import("std");
const compat = @import("compat.zig");
const ids = @import("ids.zig");
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

pub fn appendSessionHeader(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), session_id: []const u8) !void {
    try out.appendSlice(allocator, "---\nconnector: qmd\nobject_type: agent_session\nsession_id: ");
    try appendQuotedYaml(allocator, out, session_id);
    try out.appendSlice(allocator, "\n---\n\n# Agent Session ");
    try out.appendSlice(allocator, session_id);
    try out.appendSlice(allocator, "\n\n");
}

pub fn appendSessionMessage(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    role: []const u8,
    content: []const u8,
    created_at_ms: i64,
    options: SessionMarkdownOptions,
) !bool {
    if (!sessionRoleExportable(role, options.include_internal)) return false;
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    if (trimmed.len == 0) return false;
    const clipped = if (trimmed.len > options.max_message_chars) trimmed[0..options.max_message_chars] else trimmed;

    try out.appendSlice(allocator, "## ");
    try out.appendSlice(allocator, sessionRoleTitle(role));
    try out.appendSlice(allocator, "\n\n");
    try out.print(allocator, "created_at_ms: {d}\n\n", .{created_at_ms});
    try out.appendSlice(allocator, clipped);
    if (trimmed.len > clipped.len) try out.appendSlice(allocator, "\n\n[truncated]\n");
    try out.appendSlice(allocator, "\n\n");
    return true;
}

pub fn sessionExportPath(allocator: std.mem.Allocator, directory: []const u8, session_id: []const u8) ![]const u8 {
    const filename = try sessionExportFileName(allocator, session_id);
    defer allocator.free(filename);
    return std.fs.path.join(allocator, &.{ directory, filename });
}

pub fn writeSessionExport(
    allocator: std.mem.Allocator,
    directory: []const u8,
    session_id: []const u8,
    markdown: []const u8,
    max_existing_bytes: usize,
) !SessionExportWriteResult {
    try std.Io.Dir.cwd().createDirPath(compat.io(), directory);
    const path = try sessionExportPath(allocator, directory, session_id);
    errdefer allocator.free(path);

    const existing: ?[]u8 = std.Io.Dir.cwd().readFileAlloc(compat.io(), path, allocator, .limited(max_existing_bytes)) catch |err| switch (err) {
        error.FileNotFound => null,
        error.StreamTooLong => null,
        else => return err,
    };
    if (existing) |bytes| {
        defer allocator.free(bytes);
        if (std.mem.eql(u8, bytes, markdown)) {
            return .{ .path = path, .written = false, .unchanged = true, .bytes = markdown.len };
        }
    }

    try std.Io.Dir.cwd().writeFile(compat.io(), .{
        .sub_path = path,
        .data = markdown,
        .flags = .{ .truncate = true },
    });
    return .{ .path = path, .written = true, .unchanged = false, .bytes = markdown.len };
}

pub fn pruneSessionExports(directory: []const u8, retention_days: u32) !SessionPruneResult {
    var dir = try std.Io.Dir.cwd().openDir(compat.io(), directory, .{ .iterate = true });
    defer dir.close(compat.io());

    const now_ms = ids.nowMs();
    const retention_ms: i64 = @intCast(@as(u64, retention_days) * std.time.ms_per_day);
    var iter = dir.iterate();
    var result = SessionPruneResult{};
    while (try iter.next(compat.io())) |entry| {
        if (entry.kind != .file or !endsWithIgnoreCase(entry.name, ".md")) {
            result.skipped += 1;
            continue;
        }
        const stat = dir.statFile(compat.io(), entry.name, .{}) catch {
            result.skipped += 1;
            continue;
        };
        const mtime_ms: i64 = @intCast(@divTrunc(stat.mtime.nanoseconds, std.time.ns_per_ms));
        const expired = retention_days == 0 or (now_ms > mtime_ms and now_ms - mtime_ms >= retention_ms);
        if (!expired) {
            result.skipped += 1;
            continue;
        }
        dir.deleteFile(compat.io(), entry.name) catch {
            result.skipped += 1;
            continue;
        };
        result.deleted += 1;
    }
    return result;
}

fn sessionExportFileName(allocator: std.mem.Allocator, session_id: []const u8) ![]const u8 {
    var sanitized: std.ArrayListUnmanaged(u8) = .empty;
    defer sanitized.deinit(allocator);
    for (session_id) |ch| {
        if (sanitized.items.len >= 96) break;
        try sanitized.append(allocator, if (sessionFileNameChar(ch)) ch else '_');
    }
    while (sanitized.items.len > 0 and sanitized.items[sanitized.items.len - 1] == '_') _ = sanitized.pop();
    const base = if (sanitized.items.len == 0 or std.mem.eql(u8, sanitized.items, ".") or std.mem.eql(u8, sanitized.items, "..")) "session" else sanitized.items;
    return std.fmt.allocPrint(allocator, "qmd-session-{x}-{s}.md", .{ std.hash.Wyhash.hash(0, session_id), base });
}

fn sessionFileNameChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-' or ch == '.' or ch == ':' or ch == '@';
}

fn sessionRoleExportable(role: []const u8, include_internal: bool) bool {
    if (std.ascii.eqlIgnoreCase(role, "autosave_user") or std.ascii.eqlIgnoreCase(role, "autosave_assistant")) return false;
    if (std.ascii.eqlIgnoreCase(role, "runtime") or std.ascii.eqlIgnoreCase(role, "runtime_command") or std.ascii.startsWithIgnoreCase(role, "runtime:")) return false;
    if (include_internal) return true;
    return !(std.ascii.eqlIgnoreCase(role, "system") or
        std.ascii.eqlIgnoreCase(role, "developer") or
        std.ascii.eqlIgnoreCase(role, "tool") or
        std.ascii.eqlIgnoreCase(role, "function") or
        std.ascii.eqlIgnoreCase(role, "internal"));
}

fn sessionRoleTitle(role: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(role, "user")) return "User";
    if (std.ascii.eqlIgnoreCase(role, "assistant")) return "Assistant";
    if (std.ascii.eqlIgnoreCase(role, "system")) return "System";
    if (std.ascii.eqlIgnoreCase(role, "developer")) return "Developer";
    if (std.ascii.eqlIgnoreCase(role, "tool")) return "Tool";
    return role;
}

fn appendQuotedYaml(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), value: []const u8) !void {
    try out.append(allocator, '"');
    for (value) |ch| {
        if (ch == '"' or ch == '\\') try out.append(allocator, '\\');
        try out.append(allocator, ch);
    }
    try out.append(allocator, '"');
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

test "qmd adapter formats session exports without internal roles" {
    const alloc = std.testing.allocator;
    var markdown: std.ArrayListUnmanaged(u8) = .empty;
    defer markdown.deinit(alloc);

    try appendSessionHeader(alloc, &markdown, "agent/session:1");
    try std.testing.expect(try appendSessionMessage(alloc, &markdown, "user", "remember project context", 42, .{}));
    try std.testing.expect(!(try appendSessionMessage(alloc, &markdown, "system", "hidden prompt", 43, .{})));
    try std.testing.expect(!(try appendSessionMessage(alloc, &markdown, "autosave_user", "draft", 44, .{})));

    try std.testing.expect(std.mem.indexOf(u8, markdown.items, "agent/session:1") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown.items, "remember project context") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown.items, "hidden prompt") == null);
}
