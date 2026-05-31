const std = @import("std");
const json = @import("json_util.zig");

pub const Message = struct {
    role: []const u8 = "",
    speaker: []const u8 = "",
    content: []const u8,
};

pub const Options = struct {
    max_chars: usize = 4000,
};

pub const Summary = struct {
    text: []const u8,
    sections_json: []const u8,
    provider: []const u8,
    message_count: usize,
    truncated: bool,
};

const SectionKind = enum {
    decisions,
    constraints,
    action_items,
    risks,
    open_questions,
    facts,

    fn name(self: SectionKind) []const u8 {
        return switch (self) {
            .decisions => "decisions",
            .constraints => "constraints",
            .action_items => "action_items",
            .risks => "risks",
            .open_questions => "open_questions",
            .facts => "facts",
        };
    }

    fn heading(self: SectionKind) []const u8 {
        return switch (self) {
            .decisions => "Decisions",
            .constraints => "Constraints",
            .action_items => "Action items",
            .risks => "Risks",
            .open_questions => "Open questions",
            .facts => "Key facts",
        };
    }
};

const Item = struct {
    kind: SectionKind,
    text: []const u8,
    message_index: usize,
    role: []const u8,
    speaker: []const u8,
};

const ClassifiedLine = struct {
    kind: SectionKind,
    text: []const u8,
};

pub fn summarizeMessages(allocator: std.mem.Allocator, messages: []const Message, options: Options) !Summary {
    var items: std.ArrayListUnmanaged(Item) = .empty;
    defer items.deinit(allocator);

    for (messages, 0..) |message, i| {
        var line_it = std.mem.splitScalar(u8, message.content, '\n');
        while (line_it.next()) |raw_line| {
            const line = cleanLine(raw_line);
            if (line.len == 0) continue;
            const classified = classifyLine(line);
            if (classified.kind == .facts and countKind(items.items, .facts) >= 8) continue;
            if (containsItem(items.items, classified.kind, classified.text)) continue;
            try items.append(allocator, .{
                .kind = classified.kind,
                .text = classified.text,
                .message_index = i,
                .role = message.role,
                .speaker = message.speaker,
            });
        }
    }

    const full_text = try buildTextSummary(allocator, items.items, messages.len);
    defer allocator.free(full_text);
    const trimmed = try trimUtf8WithSuffix(allocator, full_text, @max(options.max_chars, 1));
    errdefer allocator.free(trimmed.text);

    const sections_json = try buildSectionsJson(allocator, items.items);
    errdefer allocator.free(sections_json);

    return .{
        .text = trimmed.text,
        .sections_json = sections_json,
        .provider = "extractive_structured",
        .message_count = messages.len,
        .truncated = trimmed.truncated,
    };
}

pub fn buildLlmPrompt(allocator: std.mem.Allocator, messages: []const Message, max_chars: usize) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "Summarize the following NullPantry messages for agent memory. Preserve only source-grounded facts. Cite message indexes as [message:N].\n\n");
    for (messages, 0..) |message, i| {
        try out.print(allocator, "Message {d}", .{i + 1});
        if (message.speaker.len > 0) {
            try out.appendSlice(allocator, " speaker=");
            try out.appendSlice(allocator, message.speaker);
        }
        if (message.role.len > 0) {
            try out.appendSlice(allocator, " role=");
            try out.appendSlice(allocator, message.role);
        }
        try out.appendSlice(allocator, ":\n");
        try out.appendSlice(allocator, message.content);
        try out.appendSlice(allocator, "\n\n");
    }
    try out.print(allocator, "Return at most {d} characters.", .{max_chars});
    return out.toOwnedSlice(allocator);
}

pub fn trimUtf8WithSuffix(allocator: std.mem.Allocator, text: []const u8, max_chars: usize) !struct { text: []const u8, truncated: bool } {
    if (text.len <= max_chars) return .{ .text = try allocator.dupe(u8, text), .truncated = false };
    if (max_chars <= 32) return .{ .text = try allocator.dupe(u8, text[0..utf8End(text, max_chars)]), .truncated = true };
    const suffix = "\n[truncated]\n";
    const keep_len = if (max_chars > suffix.len) max_chars - suffix.len else max_chars;
    const end = utf8End(text, keep_len);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, text[0..end]);
    try out.appendSlice(allocator, suffix);
    return .{ .text = try out.toOwnedSlice(allocator), .truncated = true };
}

fn buildTextSummary(allocator: std.mem.Allocator, items: []const Item, message_count: usize) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "Structured Summary\n");
    try out.print(allocator, "Messages: {d}\n", .{message_count});
    var wrote_any = false;
    inline for (.{ SectionKind.decisions, SectionKind.constraints, SectionKind.action_items, SectionKind.risks, SectionKind.open_questions, SectionKind.facts }) |kind| {
        const before = out.items.len;
        try appendTextSection(allocator, &out, kind, items);
        wrote_any = wrote_any or out.items.len > before;
    }
    if (!wrote_any) try out.appendSlice(allocator, "\nNo summarizable content was found.\n");
    return out.toOwnedSlice(allocator);
}

fn appendTextSection(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), kind: SectionKind, items: []const Item) !void {
    var count: usize = 0;
    for (items) |item| {
        if (item.kind != kind) continue;
        if (count == 0) {
            try out.append(allocator, '\n');
            try out.appendSlice(allocator, kind.heading());
            try out.appendSlice(allocator, ":\n");
        }
        try out.appendSlice(allocator, "- ");
        try out.appendSlice(allocator, item.text);
        try out.print(allocator, " [message:{d}]\n", .{item.message_index + 1});
        count += 1;
        if (count >= 8) break;
    }
}

fn buildSectionsJson(allocator: std.mem.Allocator, items: []const Item) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '{');
    inline for (.{ SectionKind.decisions, SectionKind.constraints, SectionKind.action_items, SectionKind.risks, SectionKind.open_questions, SectionKind.facts }, 0..) |kind, i| {
        if (i > 0) try out.append(allocator, ',');
        try json.appendString(&out, allocator, kind.name());
        try out.appendSlice(allocator, ":[");
        var first = true;
        for (items) |item| {
            if (item.kind != kind) continue;
            if (!first) try out.append(allocator, ',');
            first = false;
            try out.append(allocator, '{');
            try json.appendString(&out, allocator, "text");
            try out.append(allocator, ':');
            try json.appendString(&out, allocator, item.text);
            try out.appendSlice(allocator, ",\"message_index\":");
            try out.print(allocator, "{d}", .{item.message_index});
            if (item.role.len > 0) {
                try out.appendSlice(allocator, ",\"role\":");
                try json.appendString(&out, allocator, item.role);
            }
            if (item.speaker.len > 0) {
                try out.appendSlice(allocator, ",\"speaker\":");
                try json.appendString(&out, allocator, item.speaker);
            }
            try out.append(allocator, '}');
        }
        try out.append(allocator, ']');
    }
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

fn classifyLine(line: []const u8) ClassifiedLine {
    if (stripPrefixed(line, &decision_prefixes)) |text| return .{ .kind = .decisions, .text = text };
    if (stripPrefixed(line, &constraint_prefixes)) |text| return .{ .kind = .constraints, .text = text };
    if (stripPrefixed(line, &action_prefixes)) |text| return .{ .kind = .action_items, .text = text };
    if (stripPrefixed(line, &risk_prefixes)) |text| return .{ .kind = .risks, .text = text };
    if (stripPrefixed(line, &question_prefixes)) |text| return .{ .kind = .open_questions, .text = text };
    return .{ .kind = .facts, .text = line };
}

const decision_prefixes = [_][]const u8{ "Decision:", "Decided:", "ADR:", "Решение:", "Решили:" };
const constraint_prefixes = [_][]const u8{ "Constraint:", "Constraints:", "Invariant:", "Ограничение:", "Ограничения:" };
const action_prefixes = [_][]const u8{ "Action:", "Action item:", "TODO:", "Next step:", "Owner:", "Действие:", "Задача:" };
const risk_prefixes = [_][]const u8{ "Risk:", "Risks:", "Concern:", "Issue:", "Риск:", "Проблема:" };
const question_prefixes = [_][]const u8{ "Question:", "Open question:", "Q:", "Вопрос:", "Открытый вопрос:" };

fn stripPrefixed(line: []const u8, prefixes: []const []const u8) ?[]const u8 {
    for (prefixes) |prefix| {
        if (startsWithFold(line, prefix)) {
            const stripped = std.mem.trim(u8, line[prefix.len..], " \t-:");
            return if (stripped.len == 0) line else stripped;
        }
    }
    return null;
}

fn startsWithFold(line: []const u8, prefix: []const u8) bool {
    if (line.len < prefix.len) return false;
    if (std.ascii.eqlIgnoreCase(line[0..prefix.len], prefix)) return true;
    return std.mem.eql(u8, line[0..prefix.len], prefix);
}

fn cleanLine(raw: []const u8) []const u8 {
    var line = std.mem.trim(u8, raw, " \t\r\n");
    while (line.len > 0) {
        if (std.mem.startsWith(u8, line, "- ") or std.mem.startsWith(u8, line, "* ")) {
            line = std.mem.trim(u8, line[2..], " \t\r\n");
            continue;
        }
        if (line.len > 3 and std.ascii.isDigit(line[0]) and line[1] == '.' and line[2] == ' ') {
            line = std.mem.trim(u8, line[3..], " \t\r\n");
            continue;
        }
        break;
    }
    return line;
}

fn containsItem(items: []const Item, kind: SectionKind, text: []const u8) bool {
    for (items) |item| {
        if (item.kind == kind and std.mem.eql(u8, item.text, text)) return true;
    }
    return false;
}

fn countKind(items: []const Item, kind: SectionKind) usize {
    var count: usize = 0;
    for (items) |item| {
        if (item.kind == kind) count += 1;
    }
    return count;
}

fn utf8End(text: []const u8, requested: usize) usize {
    var end = @min(text.len, requested);
    while (end > 0 and (text[end] & 0b1100_0000) == 0b1000_0000) : (end -= 1) {}
    return end;
}

test "summarizer extracts structured sections with message citations" {
    const messages = [_]Message{
        .{ .speaker = "Igor", .content = "Decision: NullPantry owns central memory\nRisk: stale context can leak into agents" },
        .{ .role = "assistant", .content = "TODO: add structured summarizer\nQuestion: should summaries persist?" },
    };
    const summary = try summarizeMessages(std.testing.allocator, &messages, .{ .max_chars = 2000 });
    defer std.testing.allocator.free(summary.text);
    defer std.testing.allocator.free(summary.sections_json);

    try std.testing.expectEqualStrings("extractive_structured", summary.provider);
    try std.testing.expect(std.mem.indexOf(u8, summary.text, "NullPantry owns central memory [message:1]") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary.text, "add structured summarizer [message:2]") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary.sections_json, "\"decisions\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary.sections_json, "\"speaker\":\"Igor\"") != null);
}

test "summarizer respects tight character budgets" {
    const messages = [_]Message{.{ .content = "Decision: NullPantry should keep summaries bounded for agents" }};
    const summary = try summarizeMessages(std.testing.allocator, &messages, .{ .max_chars = 12 });
    defer std.testing.allocator.free(summary.text);
    defer std.testing.allocator.free(summary.sections_json);
    try std.testing.expect(summary.truncated);
    try std.testing.expect(summary.text.len <= 12);
}
