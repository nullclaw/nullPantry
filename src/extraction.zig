const std = @import("std");
const json = @import("json_util.zig");

pub const ParsedMemory = struct {
    predicate: []const u8,
    object: []const u8,
    text: []const u8,
    confidence: f64,
    tags_json: []const u8,
};

pub fn artifactTypeForSource(source_type: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(source_type, "transcript") or std.ascii.eqlIgnoreCase(source_type, "chat")) return "meeting_note";
    if (std.ascii.eqlIgnoreCase(source_type, "incident")) return "incident_report";
    if (std.ascii.eqlIgnoreCase(source_type, "ticket") or std.ascii.eqlIgnoreCase(source_type, "issue")) return "page";
    if (std.ascii.eqlIgnoreCase(source_type, "pr")) return "research";
    return "page";
}

pub fn sourceTitleForArtifact(allocator: std.mem.Allocator, title: []const u8, source_type: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{s}: {s}", .{ artifactTypeForSource(source_type), title });
}

pub fn summarize(allocator: std.mem.Allocator, content: []const u8, max_chars: usize) ![]u8 {
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    if (trimmed.len <= max_chars) return allocator.dupe(u8, trimmed);
    return allocator.dupe(u8, trimmed[0..max_chars]);
}

pub fn sourceIdsJson(allocator: std.mem.Allocator, source_id: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.append(allocator, '[');
    try json.appendString(&out, allocator, source_id);
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

pub fn parseMemoryLine(line: []const u8) ?ParsedMemory {
    const trimmed = std.mem.trim(u8, line, " \t\r\n-*");
    if (trimmed.len == 0) return null;
    if (afterPrefix(trimmed, "Decision:")) |value| return .{ .predicate = "decision", .object = value, .text = trimmed, .confidence = 0.86, .tags_json = "[\"decision\"]" };
    if (afterPrefix(trimmed, "ADR:")) |value| return .{ .predicate = "decision", .object = value, .text = trimmed, .confidence = 0.84, .tags_json = "[\"decision\",\"adr\"]" };
    if (afterPrefix(trimmed, "Constraint:")) |value| return .{ .predicate = "constraint", .object = value, .text = trimmed, .confidence = 0.82, .tags_json = "[\"constraint\"]" };
    if (afterPrefix(trimmed, "Action:")) |value| return .{ .predicate = "action_item", .object = value, .text = trimmed, .confidence = 0.74, .tags_json = "[\"action_item\"]" };
    if (afterPrefix(trimmed, "Question:")) |value| return .{ .predicate = "open_question", .object = value, .text = trimmed, .confidence = 0.68, .tags_json = "[\"open_question\"]" };
    if (afterPrefix(trimmed, "Risk:")) |value| return .{ .predicate = "risk", .object = value, .text = trimmed, .confidence = 0.72, .tags_json = "[\"risk\"]" };
    if (afterPrefix(trimmed, "Owner:")) |value| return .{ .predicate = "owner", .object = value, .text = trimmed, .confidence = 0.7, .tags_json = "[\"owner\"]" };
    if (afterPrefix(trimmed, "Supersedes:")) |value| return .{ .predicate = "supersedes", .object = value, .text = trimmed, .confidence = 0.8, .tags_json = "[\"supersedes\"]" };
    return null;
}

fn afterPrefix(value: []const u8, prefix: []const u8) ?[]const u8 {
    if (!startsWithIgnoreCase(value, prefix)) return null;
    return std.mem.trim(u8, value[prefix.len..], " \t\r\n");
}

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    if (value.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

pub fn extractEntityNamesJson(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.append(allocator, '[');
    var count: usize = 0;
    var tokens = std.mem.tokenizeAny(u8, content, " \t\r\n.,;:/\\()[]{}<>!?\"'");
    while (tokens.next()) |raw| {
        const token = std.mem.trim(u8, raw, "-_*`");
        if (!std.mem.startsWith(u8, token, "Null")) continue;
        if (!isEntityLike(token)) continue;
        if (containsJsonString(out.items, token)) continue;
        if (count > 0) try out.append(allocator, ',');
        try json.appendString(&out, allocator, token);
        count += 1;
        if (count >= 64) break;
    }
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

fn isEntityLike(value: []const u8) bool {
    if (value.len <= "Null".len) return false;
    for (value) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-') return false;
    }
    return true;
}

fn containsJsonString(haystack: []const u8, value: []const u8) bool {
    var buf: [256]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "\"{s}\"", .{value}) catch return false;
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "extraction parses structured meeting lines" {
    const parsed = parseMemoryLine("Decision: NullPantry uses Sources and Memory Atoms").?;
    try std.testing.expectEqualStrings("decision", parsed.predicate);
    try std.testing.expectEqualStrings("NullPantry uses Sources and Memory Atoms", parsed.object);
    try std.testing.expectEqualStrings("[\"decision\"]", parsed.tags_json);

    const risk = parseMemoryLine("- Risk: stale memory can leak bad context").?;
    try std.testing.expectEqualStrings("risk", risk.predicate);
}

test "extraction emits unique Null ecosystem entities" {
    const alloc = std.testing.allocator;
    const entities = try extractEntityNamesJson(alloc, "NullPantry links NullClaw and NullPantry.");
    defer alloc.free(entities);
    try std.testing.expectEqualStrings("[\"NullPantry\",\"NullClaw\"]", entities);
}
