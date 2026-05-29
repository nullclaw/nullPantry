const std = @import("std");
const domain = @import("domain.zig");
const json = @import("json_util.zig");

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

const Frontmatter = struct {
    title: ?[]const u8 = null,
    source_type: ?[]const u8 = null,
    artifact_type: ?[]const u8 = null,
    status: ?[]const u8 = null,
    scope: ?[]const u8 = null,
    permissions: ?[]const u8 = null,
    related_entities: ?[]const u8 = null,
    metadata: ?[]const u8 = null,
    fields: ?[]const u8 = null,
    author: ?[]const u8 = null,
    owner: ?[]const u8 = null,
    space_id: ?[]const u8 = null,
    raw_content_uri: ?[]const u8 = null,
    path: ?[]const u8 = null,
    checksum: ?[]const u8 = null,
};

pub fn parseImport(
    allocator: std.mem.Allocator,
    content: []const u8,
    fallback_title: []const u8,
    default_scope: []const u8,
    default_permissions_json: []const u8,
) !ParsedMarkdown {
    const split = splitFrontmatter(content);
    const fm = try parseFrontmatter(split.frontmatter orelse "");
    const body = std.mem.trim(u8, split.body, " \t\r\n");
    const heading_title = firstMarkdownHeading(body);
    const title = fm.title orelse heading_title orelse fallback_title;
    const artifact_type = normalizeArtifactType(fm.artifact_type orelse "page");
    const default_status = if (std.mem.eql(u8, artifact_type, "decision")) "proposed" else "draft";

    return .{
        .title = try allocator.dupe(u8, title),
        .source_type = try allocator.dupe(u8, normalizeSourceType(fm.source_type orelse "markdown")),
        .artifact_type = try allocator.dupe(u8, artifact_type),
        .status = try allocator.dupe(u8, fm.status orelse default_status),
        .scope = try allocator.dupe(u8, fm.scope orelse default_scope),
        .permissions_json = try normalizePermissionsJson(allocator, fm.permissions orelse default_permissions_json),
        .related_entities_json = try normalizeJsonArrayOrList(allocator, fm.related_entities, "[]"),
        .metadata_json = try normalizeRawJsonOr(allocator, fm.metadata, "{}"),
        .fields_json = try normalizeRawJsonOr(allocator, fm.fields, "{}"),
        .author = if (fm.author) |value| try allocator.dupe(u8, value) else null,
        .owner = if (fm.owner) |value| try allocator.dupe(u8, value) else null,
        .space_id = if (fm.space_id) |value| try allocator.dupe(u8, value) else null,
        .raw_content_uri = if (fm.raw_content_uri) |value| try allocator.dupe(u8, value) else null,
        .path = if (fm.path) |value| try allocator.dupe(u8, value) else null,
        .checksum = if (fm.checksum) |value| try allocator.dupe(u8, value) else null,
        .body = try allocator.dupe(u8, body),
    };
}

pub fn isMarkdownPath(path: []const u8) bool {
    return endsWithIgnoreCase(path, ".md") or endsWithIgnoreCase(path, ".markdown");
}

pub fn fallbackTitleFromPath(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    if (endsWithIgnoreCase(base, ".markdown")) return base[0 .. base.len - ".markdown".len];
    if (endsWithIgnoreCase(base, ".md")) return base[0 .. base.len - ".md".len];
    return base;
}

pub fn exportFileName(allocator: std.mem.Allocator, title: []const u8, id: []const u8, prefix: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var last_dash = false;
    for (title) |c| {
        const lower = std.ascii.toLower(c);
        const keep = (lower >= 'a' and lower <= 'z') or (lower >= '0' and lower <= '9');
        if (keep) {
            try out.append(allocator, lower);
            last_dash = false;
        } else if (!last_dash and out.items.len > 0) {
            try out.append(allocator, '-');
            last_dash = true;
        }
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == '-') {
        _ = out.pop();
    }
    if (out.items.len == 0) {
        try out.appendSlice(allocator, prefix);
        try out.append(allocator, '-');
        try out.appendSlice(allocator, id);
    } else {
        try out.append(allocator, '-');
        try out.appendSlice(allocator, id);
    }
    try out.appendSlice(allocator, ".md");
    return out.toOwnedSlice(allocator);
}

pub fn appendSourceMarkdown(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), source: domain.Source) !void {
    try out.appendSlice(allocator, "---\n");
    try appendYamlString(allocator, out, "nullpantry_object", "source");
    try appendYamlString(allocator, out, "id", source.id);
    try appendYamlString(allocator, out, "source_type", source.source_type);
    try appendYamlString(allocator, out, "title", source.title);
    try appendYamlString(allocator, out, "scope", source.scope);
    if (source.author) |author| try appendYamlString(allocator, out, "author", author);
    if (source.raw_content_uri) |uri| try appendYamlString(allocator, out, "raw_content_uri", uri);
    try appendYamlRawJson(allocator, out, "permissions", source.permissions_json, "[]");
    try appendYamlRawJson(allocator, out, "related_entities", source.related_entities_json, "[]");
    try appendYamlRawJson(allocator, out, "metadata", source.metadata_json, "{}");
    try out.appendSlice(allocator, "---\n\n");
    try appendBodyWithOptionalTitle(allocator, out, source.title, source.content);
}

pub fn appendArtifactMarkdown(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), artifact: domain.Artifact) !void {
    try out.appendSlice(allocator, "---\n");
    try appendYamlString(allocator, out, "nullpantry_object", "artifact");
    try appendYamlString(allocator, out, "id", artifact.id);
    try appendYamlString(allocator, out, "artifact_type", artifact.artifact_type);
    try appendYamlString(allocator, out, "title", artifact.title);
    try appendYamlString(allocator, out, "status", artifact.status);
    try appendYamlString(allocator, out, "scope", artifact.scope);
    if (artifact.owner) |owner| try appendYamlString(allocator, out, "owner", owner);
    if (artifact.space_id) |space_id| try appendYamlString(allocator, out, "space_id", space_id);
    try appendYamlRawJson(allocator, out, "source_ids", artifact.source_ids_json, "[]");
    try appendYamlRawJson(allocator, out, "related_entities", artifact.related_entities_json, "[]");
    try appendYamlRawJson(allocator, out, "permissions", artifact.permissions_json, "[]");
    try appendYamlRawJson(allocator, out, "fields", artifact.fields_json, "{}");
    if (artifact.summary) |summary| try appendYamlString(allocator, out, "summary", summary);
    if (artifact.agent_summary) |summary| try appendYamlString(allocator, out, "agent_summary", summary);
    try out.appendSlice(allocator, "---\n\n");
    try appendBodyWithOptionalTitle(allocator, out, artifact.title, artifact.body);
}

const MarkdownSplit = struct {
    frontmatter: ?[]const u8,
    body: []const u8,
};

fn splitFrontmatter(content: []const u8) MarkdownSplit {
    if (!std.mem.startsWith(u8, content, "---")) return .{ .frontmatter = null, .body = content };
    if (content.len > 3 and content[3] != '\n' and content[3] != '\r') return .{ .frontmatter = null, .body = content };
    const start = lineEnd(content, 0) orelse return .{ .frontmatter = null, .body = content };
    var pos = start;
    while (pos < content.len) {
        const end = lineEnd(content, pos) orelse content.len;
        const line = trimLine(content[pos..end]);
        if (std.mem.eql(u8, line, "---")) {
            return .{
                .frontmatter = content[start..pos],
                .body = content[if (end < content.len) end else content.len..],
            };
        }
        pos = end;
    }
    return .{ .frontmatter = null, .body = content };
}

fn lineEnd(content: []const u8, start: usize) ?usize {
    const nl = std.mem.indexOfScalarPos(u8, content, start, '\n') orelse return null;
    return nl + 1;
}

fn trimLine(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \t\r\n");
}

fn parseFrontmatter(frontmatter: []const u8) !Frontmatter {
    var out: Frontmatter = .{};
    var lines = std.mem.splitScalar(u8, frontmatter, '\n');
    while (lines.next()) |raw_line| {
        const line = trimLine(raw_line);
        if (line.len == 0 or line[0] == '#') continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        const value = parseScalar(std.mem.trim(u8, line[colon + 1 ..], " \t"));
        applyFrontmatterField(&out, key, value);
    }
    return out;
}

fn applyFrontmatterField(out: *Frontmatter, key: []const u8, value: []const u8) void {
    if (std.mem.eql(u8, key, "title")) {
        out.title = value;
    } else if (std.mem.eql(u8, key, "type") or std.mem.eql(u8, key, "artifact_type")) {
        out.artifact_type = value;
    } else if (std.mem.eql(u8, key, "source_type")) {
        out.source_type = value;
    } else if (std.mem.eql(u8, key, "status")) {
        out.status = value;
    } else if (std.mem.eql(u8, key, "scope")) {
        out.scope = value;
    } else if (std.mem.eql(u8, key, "permissions")) {
        out.permissions = value;
    } else if (std.mem.eql(u8, key, "related_entities")) {
        out.related_entities = value;
    } else if (std.mem.eql(u8, key, "metadata")) {
        out.metadata = value;
    } else if (std.mem.eql(u8, key, "fields")) {
        out.fields = value;
    } else if (std.mem.eql(u8, key, "author")) {
        out.author = value;
    } else if (std.mem.eql(u8, key, "owner")) {
        out.owner = value;
    } else if (std.mem.eql(u8, key, "space_id")) {
        out.space_id = value;
    } else if (std.mem.eql(u8, key, "raw_content_uri")) {
        out.raw_content_uri = value;
    } else if (std.mem.eql(u8, key, "path")) {
        out.path = value;
    } else if (std.mem.eql(u8, key, "checksum")) {
        out.checksum = value;
    }
}

fn parseScalar(value: []const u8) []const u8 {
    if (value.len >= 2) {
        const first = value[0];
        const last = value[value.len - 1];
        if ((first == '"' and last == '"') or (first == '\'' and last == '\'')) {
            return value[1 .. value.len - 1];
        }
    }
    return value;
}

fn firstMarkdownHeading(body: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (!std.mem.startsWith(u8, line, "#")) continue;
        var i: usize = 0;
        while (i < line.len and line[i] == '#') : (i += 1) {}
        if (i == 0 or i >= line.len or line[i] != ' ') continue;
        return std.mem.trim(u8, line[i + 1 ..], " \t\r\n");
    }
    return null;
}

fn normalizeArtifactType(value: []const u8) []const u8 {
    if (std.mem.eql(u8, value, "recipe")) return "runbook";
    if (std.mem.eql(u8, value, "page") or
        std.mem.eql(u8, value, "spec") or
        std.mem.eql(u8, value, "decision") or
        std.mem.eql(u8, value, "runbook") or
        std.mem.eql(u8, value, "meeting_note") or
        std.mem.eql(u8, value, "research") or
        std.mem.eql(u8, value, "incident_report") or
        std.mem.eql(u8, value, "memory_item"))
    {
        return value;
    }
    return "page";
}

fn normalizeSourceType(value: []const u8) []const u8 {
    if (std.mem.eql(u8, value, "md")) return "markdown";
    return value;
}

fn normalizeRawJsonOr(allocator: std.mem.Allocator, value: ?[]const u8, fallback: []const u8) ![]const u8 {
    const text = value orelse return allocator.dupe(u8, fallback);
    if (std.json.validate(allocator, text) catch false) return allocator.dupe(u8, text);
    return allocator.dupe(u8, fallback);
}

fn normalizeJsonArrayOrList(allocator: std.mem.Allocator, value: ?[]const u8, fallback: []const u8) ![]const u8 {
    const text = value orelse return allocator.dupe(u8, fallback);
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return allocator.dupe(u8, fallback);
    if (std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch null) |parsed| {
        defer parsed.deinit();
        if (parsed.value == .array) return allocator.dupe(u8, trimmed);
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '[');
    var first = true;
    var parts = std.mem.splitScalar(u8, trimmed, ',');
    while (parts.next()) |part| {
        const item = std.mem.trim(u8, part, " \t\r\n");
        if (item.len == 0) continue;
        if (!first) try out.append(allocator, ',');
        first = false;
        try json.appendString(&out, allocator, item);
    }
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

fn normalizePermissionsJson(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return allocator.dupe(u8, "[]");
    if (std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch null) |parsed| {
        defer parsed.deinit();
        switch (parsed.value) {
            .array => return allocator.dupe(u8, trimmed),
            .string => |s| return permissionsListTextToJson(allocator, s),
            else => return allocator.dupe(u8, "[]"),
        }
    }
    return permissionsListTextToJson(allocator, trimmed);
}

fn permissionsListTextToJson(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '[');
    var first = true;
    var parts = std.mem.splitScalar(u8, trimmed, ',');
    while (parts.next()) |part| {
        const permission = std.mem.trim(u8, part, " \t\r\n");
        if (permission.len == 0) continue;
        if (!first) try out.append(allocator, ',');
        first = false;
        try json.appendString(&out, allocator, permission);
    }
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

fn appendYamlString(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), key: []const u8, value: []const u8) !void {
    try out.appendSlice(allocator, key);
    try out.appendSlice(allocator, ": ");
    try json.appendString(out, allocator, value);
    try out.append(allocator, '\n');
}

fn appendYamlRawJson(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), key: []const u8, raw: []const u8, fallback: []const u8) !void {
    try out.appendSlice(allocator, key);
    try out.appendSlice(allocator, ": ");
    try json.appendRawJsonOr(out, allocator, raw, fallback);
    try out.append(allocator, '\n');
}

fn appendBodyWithOptionalTitle(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), title: []const u8, body: []const u8) !void {
    if (!startsWithMarkdownHeading(body)) {
        try out.appendSlice(allocator, "# ");
        try out.appendSlice(allocator, title);
        try out.appendSlice(allocator, "\n\n");
    }
    try out.appendSlice(allocator, body);
    if (body.len == 0 or !std.mem.endsWith(u8, body, "\n")) try out.append(allocator, '\n');
}

fn startsWithMarkdownHeading(body: []const u8) bool {
    var start: usize = 0;
    while (start < body.len and isTrimByte(body[start])) : (start += 1) {}
    const trimmed = body[start..];
    if (!std.mem.startsWith(u8, trimmed, "#")) return false;
    var i: usize = 0;
    while (i < trimmed.len and trimmed[i] == '#') : (i += 1) {}
    return i > 0 and i < trimmed.len and trimmed[i] == ' ';
}

fn isTrimByte(value: u8) bool {
    return value == ' ' or value == '\t' or value == '\r' or value == '\n';
}

fn endsWithIgnoreCase(value: []const u8, suffix: []const u8) bool {
    if (value.len < suffix.len) return false;
    return std.ascii.eqlIgnoreCase(value[value.len - suffix.len ..], suffix);
}

test "markdown import parses frontmatter and heading" {
    const alloc = std.testing.allocator;
    const parsed = try parseImport(alloc,
        \\---
        \\title: "Decision: Memory routing"
        \\artifact_type: decision
        \\status: accepted
        \\scope: project:nullpantry
        \\permissions: project:nullpantry, team:memory
        \\related_entities: NullPantry, NullClaw
        \\metadata: {"source":"docs"}
        \\fields: {"context":"Need shared memory","decision":"Use NullPantry"}
        \\author: alice
        \\owner: bob
        \\space_id: sp_arch
        \\path: docs/adr.md
        \\checksum: wyhash:abc
        \\---
        \\
        \\# Ignored body heading
        \\
        \\Decision: route complex agent memory through NullPantry.
    , "Fallback", "workspace", "[]");
    defer parsed.deinit(alloc);

    try std.testing.expectEqualStrings("Decision: Memory routing", parsed.title);
    try std.testing.expectEqualStrings("decision", parsed.artifact_type);
    try std.testing.expectEqualStrings("accepted", parsed.status);
    try std.testing.expectEqualStrings("project:nullpantry", parsed.scope);
    try std.testing.expectEqualStrings("[\"project:nullpantry\",\"team:memory\"]", parsed.permissions_json);
    try std.testing.expectEqualStrings("[\"NullPantry\",\"NullClaw\"]", parsed.related_entities_json);
    try std.testing.expectEqualStrings("{\"source\":\"docs\"}", parsed.metadata_json);
    try std.testing.expectEqualStrings("{\"context\":\"Need shared memory\",\"decision\":\"Use NullPantry\"}", parsed.fields_json);
    try std.testing.expectEqualStrings("alice", parsed.author.?);
    try std.testing.expectEqualStrings("bob", parsed.owner.?);
    try std.testing.expectEqualStrings("sp_arch", parsed.space_id.?);
    try std.testing.expectEqualStrings("docs/adr.md", parsed.path.?);
    try std.testing.expectEqualStrings("wyhash:abc", parsed.checksum.?);
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "Decision: route complex agent memory") != null);
}

test "markdown import falls back to first heading" {
    const alloc = std.testing.allocator;
    const parsed = try parseImport(alloc,
        \\# Project Page
        \\
        \\Body.
    , "Fallback", "public", "[\"public\"]");
    defer parsed.deinit(alloc);

    try std.testing.expectEqualStrings("Project Page", parsed.title);
    try std.testing.expectEqualStrings("page", parsed.artifact_type);
    try std.testing.expectEqualStrings("draft", parsed.status);
    try std.testing.expectEqualStrings("public", parsed.scope);
    try std.testing.expectEqualStrings("[\"public\"]", parsed.permissions_json);
}

test "markdown export emits artifact frontmatter and body" {
    const alloc = std.testing.allocator;
    const artifact = domain.Artifact{
        .id = "artifact_test",
        .artifact_type = "runbook",
        .title = "Release NullPantry",
        .body = "Step 1\nStep 2",
        .status = "verified",
        .owner = "ops",
        .space_id = null,
        .version = 1,
        .created_at_ms = 1,
        .updated_at_ms = 1,
        .last_verified_at_ms = null,
        .scope = "team:ops",
        .source_ids_json = "[\"src_1\"]",
        .related_entities_json = "[]",
        .permissions_json = "[\"team:ops\"]",
        .fields_json = "{\"procedure\":\"release\"}",
        .summary = null,
        .agent_summary = null,
    };
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    try appendArtifactMarkdown(alloc, &out, artifact);

    try std.testing.expect(std.mem.indexOf(u8, out.items, "artifact_type: \"runbook\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "permissions: [\"team:ops\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "Step 2") != null);
}

test "markdown filesystem helpers classify and name files" {
    const alloc = std.testing.allocator;
    try std.testing.expect(isMarkdownPath("docs/Runbook.MD"));
    try std.testing.expect(isMarkdownPath("docs/note.markdown"));
    try std.testing.expect(!isMarkdownPath("docs/note.txt"));
    try std.testing.expectEqualStrings("Service ADR", fallbackTitleFromPath("docs/Service ADR.md"));

    const file_name = try exportFileName(alloc, "Release NullPantry / V1", "artifact_1", "artifact");
    defer alloc.free(file_name);
    try std.testing.expectEqualStrings("release-nullpantry-v1-artifact_1.md", file_name);
}
