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

pub fn evidenceRangeJson(allocator: std.mem.Allocator, source_id: []const u8, start: usize, end: usize, line_no: usize) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.appendSlice(allocator, "[{\"source_id\":");
    try json.appendString(&out, allocator, source_id);
    try out.print(allocator, ",\"start\":{d},\"end\":{d},\"line\":{d}}}]", .{ start, end, line_no });
    return out.toOwnedSlice(allocator);
}

pub fn parseMemoryLine(line: []const u8) ?ParsedMemory {
    const trimmed = normalizeMemoryLine(line);
    if (trimmed.len == 0) return null;
    if (afterPrefix(trimmed, "Decision:")) |value| return .{ .predicate = "decision", .object = value, .text = trimmed, .confidence = 0.86, .tags_json = "[\"decision\"]" };
    if (afterPrefix(trimmed, "ADR:")) |value| return .{ .predicate = "decision", .object = value, .text = trimmed, .confidence = 0.84, .tags_json = "[\"decision\",\"adr\"]" };
    if (afterPrefix(trimmed, "Decided:")) |value| return .{ .predicate = "decision", .object = value, .text = trimmed, .confidence = 0.82, .tags_json = "[\"decision\"]" };
    if (afterPhrase(trimmed, "we decided to ")) |value| return .{ .predicate = "decision", .object = value, .text = trimmed, .confidence = 0.72, .tags_json = "[\"decision\",\"inferred\"]" };
    if (afterPrefix(trimmed, "Constraint:")) |value| return .{ .predicate = "constraint", .object = value, .text = trimmed, .confidence = 0.82, .tags_json = "[\"constraint\"]" };
    if (afterPrefix(trimmed, "Requirement:")) |value| return .{ .predicate = "requirement", .object = value, .text = trimmed, .confidence = 0.76, .tags_json = "[\"requirement\"]" };
    if (afterPrefix(trimmed, "Action:")) |value| return .{ .predicate = "action_item", .object = value, .text = trimmed, .confidence = 0.74, .tags_json = "[\"action_item\"]" };
    if (afterPrefix(trimmed, "Action item:")) |value| return .{ .predicate = "action_item", .object = value, .text = trimmed, .confidence = 0.76, .tags_json = "[\"action_item\"]" };
    if (afterPrefix(trimmed, "TODO:")) |value| return .{ .predicate = "action_item", .object = value, .text = trimmed, .confidence = 0.68, .tags_json = "[\"action_item\",\"todo\"]" };
    if (afterPrefix(trimmed, "Question:")) |value| return .{ .predicate = "open_question", .object = value, .text = trimmed, .confidence = 0.68, .tags_json = "[\"open_question\"]" };
    if (afterPrefix(trimmed, "Open question:")) |value| return .{ .predicate = "open_question", .object = value, .text = trimmed, .confidence = 0.72, .tags_json = "[\"open_question\"]" };
    if (afterPrefix(trimmed, "Risk:")) |value| return .{ .predicate = "risk", .object = value, .text = trimmed, .confidence = 0.72, .tags_json = "[\"risk\"]" };
    if (afterPrefix(trimmed, "Owner:")) |value| return .{ .predicate = "owner", .object = value, .text = trimmed, .confidence = 0.7, .tags_json = "[\"owner\"]" };
    if (afterPrefix(trimmed, "Assignee:")) |value| return .{ .predicate = "owner", .object = value, .text = trimmed, .confidence = 0.72, .tags_json = "[\"owner\",\"ticket\"]" };
    if (afterPrefix(trimmed, "Status:")) |value| return .{ .predicate = "status", .object = value, .text = trimmed, .confidence = 0.66, .tags_json = "[\"status\"]" };
    if (afterPrefix(trimmed, "Priority:")) |value| return .{ .predicate = "priority", .object = value, .text = trimmed, .confidence = 0.64, .tags_json = "[\"priority\",\"ticket\"]" };
    if (afterPrefix(trimmed, "Acceptance criteria:")) |value| return .{ .predicate = "requirement", .object = value, .text = trimmed, .confidence = 0.74, .tags_json = "[\"requirement\",\"acceptance_criteria\"]" };
    if (afterPrefix(trimmed, "Depends on:")) |value| return .{ .predicate = "depends_on", .object = value, .text = trimmed, .confidence = 0.72, .tags_json = "[\"dependency\"]" };
    if (afterPrefix(trimmed, "Blocked by:")) |value| return .{ .predicate = "blocked_by", .object = value, .text = trimmed, .confidence = 0.72, .tags_json = "[\"dependency\",\"blocked\"]" };
    if (afterPrefix(trimmed, "Affects:")) |value| return .{ .predicate = "affects", .object = value, .text = trimmed, .confidence = 0.7, .tags_json = "[\"relation\",\"impact\"]" };
    if (afterPrefix(trimmed, "Impact:")) |value| return .{ .predicate = "impact", .object = value, .text = trimmed, .confidence = 0.7, .tags_json = "[\"incident\",\"impact\"]" };
    if (afterPrefix(trimmed, "Symptom:")) |value| return .{ .predicate = "symptom", .object = value, .text = trimmed, .confidence = 0.68, .tags_json = "[\"incident\",\"symptom\"]" };
    if (afterPrefix(trimmed, "Root cause:")) |value| return .{ .predicate = "root_cause", .object = value, .text = trimmed, .confidence = 0.76, .tags_json = "[\"incident\",\"root_cause\"]" };
    if (afterPrefix(trimmed, "Mitigation:")) |value| return .{ .predicate = "mitigation", .object = value, .text = trimmed, .confidence = 0.74, .tags_json = "[\"incident\",\"mitigation\"]" };
    if (afterPrefix(trimmed, "Fix:")) |value| return .{ .predicate = "mitigation", .object = value, .text = trimmed, .confidence = 0.72, .tags_json = "[\"fix\",\"mitigation\"]" };
    if (afterPrefix(trimmed, "Follow-up:")) |value| return .{ .predicate = "follow_up", .object = value, .text = trimmed, .confidence = 0.7, .tags_json = "[\"follow_up\"]" };
    if (afterPrefix(trimmed, "PR:")) |value| return .{ .predicate = "related_pr", .object = value, .text = trimmed, .confidence = 0.72, .tags_json = "[\"pr\",\"code\"]" };
    if (afterPrefix(trimmed, "Commit:")) |value| return .{ .predicate = "related_commit", .object = value, .text = trimmed, .confidence = 0.68, .tags_json = "[\"commit\",\"code\"]" };
    if (afterPrefix(trimmed, "Supersedes:")) |value| return .{ .predicate = "supersedes", .object = value, .text = trimmed, .confidence = 0.8, .tags_json = "[\"supersedes\"]" };
    return null;
}

fn normalizeMemoryLine(line: []const u8) []const u8 {
    var trimmed = std.mem.trim(u8, line, " \t\r\n-*");
    if (trimmed.len == 0) return trimmed;
    if (trimmed[0] == '[') {
        if (std.mem.indexOfScalar(u8, trimmed, ']')) |end| {
            trimmed = std.mem.trim(u8, trimmed[end + 1 ..], " \t\r\n-");
        }
    }
    if (std.mem.indexOfScalar(u8, trimmed, ':')) |colon| {
        const prefix = std.mem.trim(u8, trimmed[0..colon], " \t\r\n");
        if (isLikelySpeaker(prefix)) {
            trimmed = std.mem.trim(u8, trimmed[colon + 1 ..], " \t\r\n-");
        }
    }
    return trimmed;
}

fn isLikelySpeaker(value: []const u8) bool {
    if (value.len == 0 or value.len > 80) return false;
    if (startsWithIgnoreCase(value, "Decision") or
        startsWithIgnoreCase(value, "ADR") or
        startsWithIgnoreCase(value, "Decided") or
        startsWithIgnoreCase(value, "Constraint") or
        startsWithIgnoreCase(value, "Requirement") or
        startsWithIgnoreCase(value, "Action") or
        startsWithIgnoreCase(value, "Action item") or
        startsWithIgnoreCase(value, "TODO") or
        startsWithIgnoreCase(value, "Question") or
        startsWithIgnoreCase(value, "Open question") or
        startsWithIgnoreCase(value, "Risk") or
        startsWithIgnoreCase(value, "Owner") or
        startsWithIgnoreCase(value, "Assignee") or
        startsWithIgnoreCase(value, "Status") or
        startsWithIgnoreCase(value, "Priority") or
        startsWithIgnoreCase(value, "Acceptance criteria") or
        startsWithIgnoreCase(value, "Depends on") or
        startsWithIgnoreCase(value, "Blocked by") or
        startsWithIgnoreCase(value, "Affects") or
        startsWithIgnoreCase(value, "Impact") or
        startsWithIgnoreCase(value, "Symptom") or
        startsWithIgnoreCase(value, "Root cause") or
        startsWithIgnoreCase(value, "Mitigation") or
        startsWithIgnoreCase(value, "Fix") or
        startsWithIgnoreCase(value, "Follow-up") or
        startsWithIgnoreCase(value, "PR") or
        startsWithIgnoreCase(value, "Commit") or
        startsWithIgnoreCase(value, "Supersedes")) return false;
    var saw_alpha = false;
    for (value) |ch| {
        if (std.ascii.isAlphabetic(ch)) {
            saw_alpha = true;
            continue;
        }
        if (std.ascii.isDigit(ch) or ch == ' ' or ch == '_' or ch == '-' or ch == '.') continue;
        return false;
    }
    return saw_alpha;
}

fn afterPrefix(value: []const u8, prefix: []const u8) ?[]const u8 {
    if (!startsWithIgnoreCase(value, prefix)) return null;
    return std.mem.trim(u8, value[prefix.len..], " \t\r\n");
}

fn afterPhrase(value: []const u8, phrase: []const u8) ?[]const u8 {
    if (value.len < phrase.len) return null;
    var i: usize = 0;
    while (i + phrase.len <= value.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(value[i .. i + phrase.len], phrase)) {
            return std.mem.trim(u8, value[i + phrase.len ..], " \t\r\n.");
        }
    }
    return null;
}

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    if (value.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

pub fn extractEntityNamesJson(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.append(allocator, '[');
    var count: usize = 0;
    var tokens = std.mem.tokenizeAny(u8, content, " \t\r\n.,;:\\()[]{}<>!?\"'");
    while (tokens.next()) |raw| {
        const token = std.mem.trim(u8, raw, "-_*`");
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
    if (value.len < 3) return false;
    if (std.mem.startsWith(u8, value, "@")) return value.len > 1;
    if (ticketLike(value)) return true;
    if (repoLike(value)) return true;
    if (std.mem.startsWith(u8, value, "Null")) return value.len > "Null".len;
    if (camelOrAcronymLike(value)) return true;
    for (value) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-') return false;
    }
    return false;
}

fn ticketLike(value: []const u8) bool {
    const dash = std.mem.indexOfScalar(u8, value, '-') orelse return false;
    if (dash == 0 or dash + 1 >= value.len) return false;
    for (value[0..dash]) |ch| {
        if (!std.ascii.isUpper(ch)) return false;
    }
    for (value[dash + 1 ..]) |ch| {
        if (!std.ascii.isDigit(ch)) return false;
    }
    return true;
}

fn repoLike(value: []const u8) bool {
    const slash = std.mem.indexOfScalar(u8, value, '/') orelse return false;
    return slash > 0 and slash + 1 < value.len and std.mem.indexOfScalar(u8, value, ' ') == null;
}

fn camelOrAcronymLike(value: []const u8) bool {
    var upper: usize = 0;
    var lower: usize = 0;
    var digit: usize = 0;
    for (value) |ch| {
        if (std.ascii.isUpper(ch)) upper += 1 else if (std.ascii.isLower(ch)) lower += 1 else if (std.ascii.isDigit(ch)) digit += 1 else return false;
    }
    return (upper >= 2 and lower > 0) or (upper >= 2 and digit > 0) or (upper >= 3 and value.len <= 12);
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

    const transcript_decision = parseMemoryLine("[00:01:04] Alice: Decision: Meeting Memory is a pipeline").?;
    try std.testing.expectEqualStrings("decision", transcript_decision.predicate);
    try std.testing.expectEqualStrings("Meeting Memory is a pipeline", transcript_decision.object);

    const root_cause = parseMemoryLine("Root cause: Redis timeout during deploy").?;
    try std.testing.expectEqualStrings("root_cause", root_cause.predicate);

    const inferred = parseMemoryLine("Alice: we decided to keep NullPantry headless").?;
    try std.testing.expectEqualStrings("decision", inferred.predicate);

    const assignee = parseMemoryLine("Assignee: agent:coder").?;
    try std.testing.expectEqualStrings("owner", assignee.predicate);

    const acceptance = parseMemoryLine("Acceptance criteria: context pack includes citations").?;
    try std.testing.expectEqualStrings("requirement", acceptance.predicate);

    const pr = parseMemoryLine("PR: nullclaw/nullPantry#12").?;
    try std.testing.expectEqualStrings("related_pr", pr.predicate);
}

test "extraction emits unique Null ecosystem entities" {
    const alloc = std.testing.allocator;
    const entities = try extractEntityNamesJson(alloc, "NullPantry links NullClaw, NP-42, AuthService and nullclaw/nullPantry.");
    defer alloc.free(entities);
    try std.testing.expectEqualStrings("[\"NullPantry\",\"NullClaw\",\"NP-42\",\"AuthService\",\"nullclaw/nullPantry\"]", entities);
}
