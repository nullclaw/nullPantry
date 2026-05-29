const std = @import("std");
const json = @import("json_util.zig");

pub const ParsedMemory = struct {
    predicate: []const u8,
    object: []const u8,
    text: []const u8,
    confidence: f64,
    tags_json: []const u8,
    evidence: ?[]const u8 = null,
};

pub const ParsedRelation = struct {
    from_name: []const u8,
    relation_type: []const u8,
    to_name: []const u8,
    text: []const u8,
    confidence: f64,
    evidence: ?[]const u8 = null,
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

pub fn evidenceRangeForText(allocator: std.mem.Allocator, source_id: []const u8, content: []const u8, evidence_text: ?[]const u8) ![]u8 {
    const quote = if (evidence_text) |text| std.mem.trim(u8, text, " \t\r\n") else "";
    if (quote.len > 0) {
        if (std.mem.indexOf(u8, content, quote)) |start| {
            return evidenceRangeJson(allocator, source_id, start, start + quote.len, lineNumberAt(content, start));
        }
    }
    return evidenceRangeJson(allocator, source_id, 0, @min(content.len, quote.len), 1);
}

fn lineNumberAt(content: []const u8, offset: usize) usize {
    var line: usize = 1;
    for (content[0..@min(offset, content.len)]) |ch| {
        if (ch == '\n') line += 1;
    }
    return line;
}

pub fn memoryExtractionPrompt(allocator: std.mem.Allocator, title: []const u8, source_type: []const u8, content: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\Extract durable NullPantry memory atoms and entity relations from this source.
        \\
        \\Return only valid JSON in this shape:
        \\{{"memory_atoms":[{{"predicate":"decision|constraint|requirement|action_item|risk|open_question|owner|status|depends_on|supersedes|states","object":"short normalized object","text":"complete factual statement","confidence":0.0,"tags":["tag"],"evidence":"exact quote from source"}}],"relations":[{{"from":"entity name","relation_type":"depends_on|implements|fixes|produced|supersedes|affects|documents|belongs_to|uses|owns|creates","to":"entity name","confidence":0.0,"evidence":"exact quote from source"}}]}}
        \\
        \\Rules:
        \\- Extract only facts supported by the source.
        \\- Prefer decisions, constraints, requirements, owners, risks, dependencies, action items, and open questions.
        \\- Extract relations only when both endpoints are explicit in the source.
        \\- Do not invent entities or citations.
        \\- Use evidence as an exact substring from the source when possible.
        \\- Return empty arrays if nothing durable is present.
        \\
        \\Source title: {s}
        \\Source type: {s}
        \\
        \\Source:
        \\{s}
    , .{ title, source_type, content });
}

pub fn parseStructuredMemoryResponse(allocator: std.mem.Allocator, body: []const u8) ![]ParsedMemory {
    const json_body = jsonEnvelope(body) orelse return error.InvalidStructuredMemory;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_body, .{}) catch return error.InvalidStructuredMemory;
    defer parsed.deinit();
    const array = switch (parsed.value) {
        .array => |a| a,
        .object => |obj| blk: {
            const value = obj.get("memory_atoms") orelse obj.get("atoms") orelse obj.get("items") orelse return allocator.alloc(ParsedMemory, 0);
            break :blk switch (value) {
                .array => |a| a,
                else => return error.InvalidStructuredMemory,
            };
        },
        else => return error.InvalidStructuredMemory,
    };
    var out: std.ArrayListUnmanaged(ParsedMemory) = .empty;
    errdefer out.deinit(allocator);
    for (array.items) |item| {
        if (item != .object) continue;
        const obj = item.object;
        const text = json.stringField(obj, "text") orelse json.stringField(obj, "content") orelse continue;
        const normalized_text = std.mem.trim(u8, text, " \t\r\n");
        if (normalized_text.len == 0) continue;
        const predicate = std.mem.trim(u8, json.stringField(obj, "predicate") orelse "states", " \t\r\n");
        const object = std.mem.trim(u8, json.stringField(obj, "object") orelse normalized_text, " \t\r\n");
        const confidence = clampConfidence(json.floatField(obj, "confidence") orelse 0.62);
        const tags_json = if (obj.get("tags")) |tags| try json.jsonFromValue(allocator, tags) else try allocator.dupe(u8, "[\"llm_extracted\"]");
        try out.append(allocator, .{
            .predicate = try allocator.dupe(u8, if (predicate.len == 0) "states" else predicate),
            .object = try allocator.dupe(u8, if (object.len == 0) normalized_text else object),
            .text = try allocator.dupe(u8, normalized_text),
            .confidence = confidence,
            .tags_json = tags_json,
            .evidence = if (json.stringField(obj, "evidence") orelse json.stringField(obj, "source_quote")) |evidence| try allocator.dupe(u8, evidence) else null,
        });
    }
    return out.toOwnedSlice(allocator);
}

pub fn parseStructuredRelationsResponse(allocator: std.mem.Allocator, body: []const u8) ![]ParsedRelation {
    const json_body = jsonEnvelope(body) orelse return error.InvalidStructuredMemory;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_body, .{}) catch return error.InvalidStructuredMemory;
    defer parsed.deinit();
    const array = switch (parsed.value) {
        .array => |a| a,
        .object => |obj| blk: {
            const value = obj.get("relations") orelse obj.get("links") orelse obj.get("edges") orelse return allocator.alloc(ParsedRelation, 0);
            break :blk switch (value) {
                .array => |a| a,
                else => return error.InvalidStructuredMemory,
            };
        },
        else => return error.InvalidStructuredMemory,
    };
    var out: std.ArrayListUnmanaged(ParsedRelation) = .empty;
    errdefer out.deinit(allocator);
    for (array.items) |item| {
        if (item != .object) continue;
        const obj = item.object;
        const from_raw = json.stringField(obj, "from") orelse json.stringField(obj, "from_name") orelse json.stringField(obj, "subject") orelse continue;
        const to_raw = json.stringField(obj, "to") orelse json.stringField(obj, "to_name") orelse json.stringField(obj, "object") orelse continue;
        const from_name = normalizeRelationEndpoint(from_raw);
        const to_name = normalizeRelationEndpoint(to_raw);
        if (!validRelationEndpoint(from_name) or !validRelationEndpoint(to_name)) continue;
        const relation_type = normalizeRelationType(json.stringField(obj, "relation_type") orelse json.stringField(obj, "predicate") orelse json.stringField(obj, "type") orelse "related_to");
        if (relation_type.len == 0) continue;
        const evidence = json.stringField(obj, "evidence") orelse json.stringField(obj, "source_quote");
        const text = evidence orelse try std.fmt.allocPrint(allocator, "{s} {s} {s}", .{ from_name, relation_type, to_name });
        try out.append(allocator, .{
            .from_name = try allocator.dupe(u8, from_name),
            .relation_type = try allocator.dupe(u8, relation_type),
            .to_name = try allocator.dupe(u8, to_name),
            .text = try allocator.dupe(u8, text),
            .confidence = clampConfidence(json.floatField(obj, "confidence") orelse 0.66),
            .evidence = if (evidence) |value| try allocator.dupe(u8, value) else null,
        });
    }
    return out.toOwnedSlice(allocator);
}

fn jsonEnvelope(body: []const u8) ?[]const u8 {
    var trimmed = std.mem.trim(u8, body, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "```")) {
        const first_newline = std.mem.indexOfScalar(u8, trimmed, '\n') orelse return null;
        trimmed = std.mem.trim(u8, trimmed[first_newline + 1 ..], " \t\r\n");
        if (std.mem.lastIndexOf(u8, trimmed, "```")) |end| trimmed = std.mem.trim(u8, trimmed[0..end], " \t\r\n");
    }
    if (trimmed.len == 0) return null;
    if (trimmed[0] == '{' or trimmed[0] == '[') return trimmed;
    const object_start = std.mem.indexOfScalar(u8, trimmed, '{');
    const array_start = std.mem.indexOfScalar(u8, trimmed, '[');
    const start = if (object_start) |obj| if (array_start) |arr| @min(obj, arr) else obj else (array_start orelse return null);
    const end = if (trimmed[start] == '{')
        (std.mem.lastIndexOfScalar(u8, trimmed, '}') orelse return null)
    else
        (std.mem.lastIndexOfScalar(u8, trimmed, ']') orelse return null);
    if (end < start) return null;
    return trimmed[start .. end + 1];
}

fn clampConfidence(value: f64) f64 {
    if (!std.math.isFinite(value)) return 0.5;
    return @max(@as(f64, 0.0), @min(@as(f64, 1.0), value));
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

pub fn parseRelationLine(line: []const u8) ?ParsedRelation {
    const trimmed = trimTrailingSentencePunctuation(normalizeMemoryLine(line));
    if (trimmed.len == 0) return null;
    if (afterPrefix(trimmed, "Relation:")) |value| {
        if (parseArrowRelation(value, 0.84)) |relation| return relation;
        if (parseKnownRelation(value, 0.8)) |relation| return relation;
    }
    if (afterPrefix(trimmed, "Link:")) |value| {
        if (parseArrowRelation(value, 0.82)) |relation| return relation;
        if (parseKnownRelation(value, 0.78)) |relation| return relation;
    }
    if (isMemoryStatementPrefix(trimmed)) return null;
    if (parseArrowRelation(trimmed, 0.76)) |relation| return relation;
    return parseKnownRelation(trimmed, 0.72);
}

const RelationPhrase = struct {
    phrase: []const u8,
    relation_type: []const u8,
};

const relation_phrases = [_]RelationPhrase{
    .{ .phrase = " produced decision ", .relation_type = "produced" },
    .{ .phrase = " is superseded by ", .relation_type = "superseded_by" },
    .{ .phrase = " is blocked by ", .relation_type = "blocked_by" },
    .{ .phrase = " depends upon ", .relation_type = "depends_on" },
    .{ .phrase = " depends on ", .relation_type = "depends_on" },
    .{ .phrase = " blocked by ", .relation_type = "blocked_by" },
    .{ .phrase = " implements ", .relation_type = "implements" },
    .{ .phrase = " supersedes ", .relation_type = "supersedes" },
    .{ .phrase = " affected ", .relation_type = "affected" },
    .{ .phrase = " affects ", .relation_type = "affects" },
    .{ .phrase = " fixes ", .relation_type = "fixes" },
    .{ .phrase = " produced ", .relation_type = "produced" },
    .{ .phrase = " documents ", .relation_type = "documents" },
    .{ .phrase = " belongs to ", .relation_type = "belongs_to" },
    .{ .phrase = " creates ", .relation_type = "creates" },
    .{ .phrase = " created ", .relation_type = "created" },
    .{ .phrase = " owns ", .relation_type = "owns" },
    .{ .phrase = " uses ", .relation_type = "uses" },
};

fn parseKnownRelation(value: []const u8, confidence: f64) ?ParsedRelation {
    for (relation_phrases) |candidate| {
        const idx = indexOfIgnoreCase(value, candidate.phrase) orelse continue;
        const from_name = normalizeRelationEndpoint(value[0..idx]);
        const to_name = normalizeRelationEndpoint(value[idx + candidate.phrase.len ..]);
        if (!validRelationEndpoint(from_name) or !validRelationEndpoint(to_name)) continue;
        return .{
            .from_name = from_name,
            .relation_type = candidate.relation_type,
            .to_name = to_name,
            .text = value,
            .confidence = confidence,
            .evidence = value,
        };
    }
    return null;
}

fn parseArrowRelation(value: []const u8, confidence: f64) ?ParsedRelation {
    const first = std.mem.indexOf(u8, value, "->") orelse return null;
    const rest = value[first + 2 ..];
    const second_rel = std.mem.indexOf(u8, rest, "->");
    const from_name = normalizeRelationEndpoint(value[0..first]);
    if (second_rel) |second| {
        const relation_type = normalizeRelationType(rest[0..second]);
        const to_name = normalizeRelationEndpoint(rest[second + 2 ..]);
        if (!validRelationEndpoint(from_name) or relation_type.len == 0 or !validRelationEndpoint(to_name)) return null;
        return .{ .from_name = from_name, .relation_type = relation_type, .to_name = to_name, .text = value, .confidence = confidence, .evidence = value };
    }
    const to_name = normalizeRelationEndpoint(rest);
    if (!validRelationEndpoint(from_name) or !validRelationEndpoint(to_name)) return null;
    return .{ .from_name = from_name, .relation_type = "related_to", .to_name = to_name, .text = value, .confidence = confidence, .evidence = value };
}

fn normalizeRelationEndpoint(value: []const u8) []const u8 {
    var trimmed = std.mem.trim(u8, value, " \t\r\n\"'`.,;:()[]{}<>");
    if (startsWithIgnoreCase(trimmed, "the ")) trimmed = std.mem.trim(u8, trimmed[4..], " \t\r\n");
    const prefixes = [_][]const u8{ "ticket ", "issue ", "decision ", "adr ", "pr ", "pull request ", "incident " };
    for (prefixes) |prefix| {
        if (startsWithIgnoreCase(trimmed, prefix) and trimmed.len > prefix.len) {
            return std.mem.trim(u8, trimmed[prefix.len..], " \t\r\n\"'`.,;:()[]{}<>");
        }
    }
    return trimmed;
}

fn normalizeRelationType(value: []const u8) []const u8 {
    var trimmed = std.mem.trim(u8, value, " \t\r\n\"'`.,;:()[]{}<>");
    if (startsWithIgnoreCase(trimmed, "relation:")) trimmed = std.mem.trim(u8, trimmed["relation:".len..], " \t\r\n");
    return trimmed;
}

fn validRelationEndpoint(value: []const u8) bool {
    if (value.len < 2 or value.len > 160) return false;
    var saw_alnum = false;
    for (value) |ch| {
        if (std.ascii.isAlphanumeric(ch)) {
            saw_alnum = true;
            continue;
        }
        if (ch == ' ' or ch == '_' or ch == '-' or ch == '/' or ch == ':' or ch == '#' or ch == '.' or ch == '@') continue;
        return false;
    }
    return saw_alnum;
}

fn isMemoryStatementPrefix(value: []const u8) bool {
    const prefixes = [_][]const u8{
        "Decision:",
        "ADR:",
        "Decided:",
        "Constraint:",
        "Requirement:",
        "Action:",
        "Action item:",
        "TODO:",
        "Question:",
        "Open question:",
        "Risk:",
        "Owner:",
        "Assignee:",
        "Status:",
        "Priority:",
        "Acceptance criteria:",
        "Depends on:",
        "Blocked by:",
        "Affects:",
        "Impact:",
        "Symptom:",
        "Root cause:",
        "Mitigation:",
        "Fix:",
        "Follow-up:",
        "PR:",
        "Commit:",
        "Supersedes:",
    };
    for (prefixes) |prefix| {
        if (startsWithIgnoreCase(value, prefix)) return true;
    }
    return false;
}

fn trimTrailingSentencePunctuation(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, " \t\r\n.");
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

fn indexOfIgnoreCase(value: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or value.len < needle.len) return null;
    var i: usize = 0;
    while (i + needle.len <= value.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(value[i .. i + needle.len], needle)) return i;
    }
    return null;
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

test "extraction parses durable relation lines" {
    const dependency = parseRelationLine("NullPantry depends on NullClaw").?;
    try std.testing.expectEqualStrings("NullPantry", dependency.from_name);
    try std.testing.expectEqualStrings("depends_on", dependency.relation_type);
    try std.testing.expectEqualStrings("NullClaw", dependency.to_name);

    const arrow = parseRelationLine("Relation: NP-42 -> implements -> ADR-7").?;
    try std.testing.expectEqualStrings("NP-42", arrow.from_name);
    try std.testing.expectEqualStrings("implements", arrow.relation_type);
    try std.testing.expectEqualStrings("ADR-7", arrow.to_name);

    try std.testing.expect(parseRelationLine("Decision: NullPantry uses ingestion jobs") == null);
}

test "extraction parses structured llm memory response" {
    const alloc = std.testing.allocator;
    const body =
        \\```json
        \\{"memory_atoms":[{"predicate":"decision","object":"NullPantry extraction","text":"Decision: NullPantry uses structured extraction.","confidence":0.91,"tags":["decision","llm"],"evidence":"NullPantry uses structured extraction"}]}
        \\```
    ;
    const memories = try parseStructuredMemoryResponse(alloc, body);
    defer {
        for (memories) |memory| {
            alloc.free(memory.predicate);
            alloc.free(memory.object);
            alloc.free(memory.text);
            alloc.free(memory.tags_json);
            if (memory.evidence) |evidence| alloc.free(evidence);
        }
        alloc.free(memories);
    }
    try std.testing.expectEqual(@as(usize, 1), memories.len);
    try std.testing.expectEqualStrings("decision", memories[0].predicate);
    try std.testing.expectEqualStrings("NullPantry extraction", memories[0].object);
    try std.testing.expect(std.mem.indexOf(u8, memories[0].tags_json, "llm") != null);
    try std.testing.expectApproxEqAbs(@as(f64, 0.91), memories[0].confidence, 0.0001);
}

test "extraction parses structured llm relation response" {
    const alloc = std.testing.allocator;
    const body =
        \\{"memory_atoms":[],"relations":[{"from":"NullTickets","relation_type":"implements","to":"NP-42","confidence":0.88,"evidence":"NullTickets implements NP-42"}]}
    ;
    const relations = try parseStructuredRelationsResponse(alloc, body);
    defer {
        for (relations) |relation| {
            alloc.free(relation.from_name);
            alloc.free(relation.relation_type);
            alloc.free(relation.to_name);
            alloc.free(relation.text);
            if (relation.evidence) |evidence| alloc.free(evidence);
        }
        alloc.free(relations);
    }
    try std.testing.expectEqual(@as(usize, 1), relations.len);
    try std.testing.expectEqualStrings("NullTickets", relations[0].from_name);
    try std.testing.expectEqualStrings("implements", relations[0].relation_type);
    try std.testing.expectEqualStrings("NP-42", relations[0].to_name);
    try std.testing.expectApproxEqAbs(@as(f64, 0.88), relations[0].confidence, 0.0001);
}

test "extraction maps evidence quote to source range" {
    const alloc = std.testing.allocator;
    const ranges = try evidenceRangeForText(alloc, "src_a", "Intro\nDecision: keep NullPantry headless\nTail", "keep NullPantry headless");
    defer alloc.free(ranges);
    try std.testing.expect(std.mem.indexOf(u8, ranges, "\"source_id\":\"src_a\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ranges, "\"line\":2") != null);
}
