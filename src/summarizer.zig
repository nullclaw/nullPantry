const std = @import("std");
const bounded_int = @import("bounded_int.zig");
const json = @import("json_util.zig");
const redaction = @import("redaction.zig");

pub const Message = struct {
    role: []const u8 = "",
    speaker: []const u8 = "",
    content: []const u8,
};

pub const Options = struct {
    max_chars: usize = 4000,
    profile: Profile = .generic,
    window_size_tokens: usize = 0,
    max_items_per_section: usize = 8,
};

pub const Profile = enum {
    generic,
    meeting,
    incident,
    decision,
    research,
    compact,

    pub fn name(self: Profile) []const u8 {
        return @tagName(self);
    }

    pub fn parse(raw: ?[]const u8) Profile {
        const value = raw orelse return .generic;
        if (std.ascii.eqlIgnoreCase(value, "meeting") or std.ascii.eqlIgnoreCase(value, "meeting_note")) return .meeting;
        if (std.ascii.eqlIgnoreCase(value, "incident") or std.ascii.eqlIgnoreCase(value, "incident_report")) return .incident;
        if (std.ascii.eqlIgnoreCase(value, "decision") or std.ascii.eqlIgnoreCase(value, "adr")) return .decision;
        if (std.ascii.eqlIgnoreCase(value, "research") or std.ascii.eqlIgnoreCase(value, "research_note")) return .research;
        if (std.ascii.eqlIgnoreCase(value, "compact") or std.ascii.eqlIgnoreCase(value, "compaction")) return .compact;
        return .generic;
    }
};

pub const Partition = struct {
    to_summarize: usize,
    to_keep: usize,
};

pub const ExtractedFact = struct {
    key: []const u8,
    content: []const u8,
    category: []const u8 = "core",

    pub fn deinit(self: *ExtractedFact, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.content);
        self.* = .{ .key = "", .content = "" };
    }
};

pub const Summary = struct {
    text: []const u8,
    sections_json: []const u8,
    quality_json: []const u8,
    provider: []const u8,
    profile: Profile,
    strategy: []const u8,
    message_count: usize,
    segment_count: usize,
    truncated: bool,
};

pub const TrimmedText = struct {
    text: []const u8,
    truncated: bool,
};

pub fn freeExtractedFacts(allocator: std.mem.Allocator, facts: []ExtractedFact) void {
    for (facts) |*fact| fact.deinit(allocator);
    allocator.free(facts);
}

pub fn estimateTokens(text: []const u8) usize {
    return text.len / 4;
}

pub fn estimateMessageTokens(message: Message) usize {
    var total = estimateTokens(message.role);
    total = tokenEstimateAdd(total, estimateTokens(message.speaker));
    total = tokenEstimateAdd(total, estimateTokens(message.content));
    return tokenEstimateAdd(total, 1);
}

pub fn shouldSummarize(messages: []const Message, window_size_tokens: usize) bool {
    if (messages.len <= 1) return false;
    var total_tokens: usize = 0;
    for (messages) |message| {
        const message_tokens = estimateMessageTokens(message);
        if (!tokenBudgetCanFit(total_tokens, message_tokens, window_size_tokens)) return true;
        total_tokens = tokenEstimateAdd(total_tokens, message_tokens);
    }
    return total_tokens > window_size_tokens;
}

pub fn partitionMessages(messages: []const Message, window_size_tokens: usize) Partition {
    if (messages.len <= 1) return .{ .to_summarize = 0, .to_keep = messages.len };

    var kept_tokens: usize = 0;
    var keep_count: usize = 0;
    var i: usize = messages.len;
    while (i > 0) {
        i -= 1;
        const message_tokens = estimateMessageTokens(messages[i]);
        if (!tokenBudgetCanFit(kept_tokens, message_tokens, window_size_tokens) and keep_count > 0) break;
        kept_tokens = tokenEstimateAdd(kept_tokens, message_tokens);
        keep_count += 1;
    }

    return .{ .to_summarize = messages.len - keep_count, .to_keep = keep_count };
}

fn tokenEstimateAdd(left: usize, right: usize) usize {
    return bounded_int.saturatingUsizeAdd(left, right);
}

fn tokenBudgetCanFit(current: usize, addition: usize, budget: usize) bool {
    return addition <= budget -| current;
}

pub fn extractSemanticFacts(allocator: std.mem.Allocator, summary_text: []const u8, key_prefix: []const u8) ![]ExtractedFact {
    var facts: std.ArrayListUnmanaged(ExtractedFact) = .empty;
    errdefer {
        for (facts.items) |*fact| fact.deinit(allocator);
        facts.deinit(allocator);
    }

    var line_iter = std.mem.splitScalar(u8, summary_text, '\n');
    var fact_idx: usize = 0;
    while (line_iter.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        const content = keyFactContent(line) orelse continue;
        if (content.len == 0) continue;

        const key = try std.fmt.allocPrint(allocator, "{s}{d}", .{ key_prefix, fact_idx });
        errdefer allocator.free(key);
        const owned_content = try allocator.dupe(u8, content);
        errdefer allocator.free(owned_content);
        try facts.append(allocator, .{
            .key = key,
            .content = owned_content,
            .category = "core",
        });
        fact_idx += 1;
    }

    return facts.toOwnedSlice(allocator);
}

const SectionKind = enum {
    topics,
    decisions,
    constraints,
    action_items,
    risks,
    open_questions,
    facts,
    owners,
    timeline,
    root_causes,
    mitigations,
    follow_ups,

    fn name(self: SectionKind) []const u8 {
        return switch (self) {
            .topics => "topics",
            .decisions => "decisions",
            .constraints => "constraints",
            .action_items => "action_items",
            .risks => "risks",
            .open_questions => "open_questions",
            .facts => "facts",
            .owners => "owners",
            .timeline => "timeline",
            .root_causes => "root_causes",
            .mitigations => "mitigations",
            .follow_ups => "follow_ups",
        };
    }

    fn heading(self: SectionKind) []const u8 {
        return switch (self) {
            .topics => "Topics",
            .decisions => "Decisions",
            .constraints => "Constraints",
            .action_items => "Action items",
            .risks => "Risks",
            .open_questions => "Open questions",
            .facts => "Key facts",
            .owners => "Owners",
            .timeline => "Timeline",
            .root_causes => "Root causes",
            .mitigations => "Mitigations",
            .follow_ups => "Follow-ups",
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

    const max_items = @max(options.max_items_per_section, 1);
    var segment_count: usize = 1;
    if (options.window_size_tokens > 0 and shouldSummarize(messages, options.window_size_tokens)) {
        segment_count = try collectWindowedItems(allocator, &items, messages, options.window_size_tokens, max_items);
    } else {
        try collectItems(allocator, &items, messages, 0, max_items);
    }

    return buildSummaryFromItems(allocator, items.items, messages.len, options, if (segment_count > 1) "extractive_structured_map_reduce" else "extractive_structured", segment_count);
}

fn collectWindowedItems(allocator: std.mem.Allocator, items: *std.ArrayListUnmanaged(Item), messages: []const Message, window_size_tokens: usize, max_items_per_section: usize) !usize {
    if (messages.len == 0) return 0;
    var segment_count: usize = 0;
    var start: usize = 0;
    while (start < messages.len) {
        var end = start;
        var tokens: usize = 0;
        while (end < messages.len) : (end += 1) {
            const next_tokens = estimateMessageTokens(messages[end]);
            if (end > start and !tokenBudgetCanFit(tokens, next_tokens, window_size_tokens)) break;
            tokens = tokenEstimateAdd(tokens, next_tokens);
        }
        if (end == start) end += 1;
        try collectItems(allocator, items, messages[start..end], start, max_items_per_section);
        segment_count += 1;
        start = end;
    }
    return segment_count;
}

fn collectItems(allocator: std.mem.Allocator, items: *std.ArrayListUnmanaged(Item), messages: []const Message, start_index: usize, max_items_per_section: usize) !void {
    for (messages, 0..) |message, i| {
        var line_it = std.mem.splitScalar(u8, message.content, '\n');
        while (line_it.next()) |raw_line| {
            const line = cleanLine(raw_line);
            if (line.len == 0) continue;
            const line_item = classifyLine(line);
            if (countKind(items.items, line_item.kind) >= max_items_per_section) continue;
            if (containsItem(items.items, line_item.kind, line_item.text)) continue;
            try items.append(allocator, .{
                .kind = line_item.kind,
                .text = line_item.text,
                .message_index = start_index + i,
                .role = message.role,
                .speaker = message.speaker,
            });
        }
    }
}

fn buildSummaryFromItems(allocator: std.mem.Allocator, items: []const Item, message_count: usize, options: Options, strategy: []const u8, segment_count: usize) !Summary {
    const full_text = try buildTextSummary(allocator, items, message_count, options.profile, @max(options.max_items_per_section, 1));
    defer allocator.free(full_text);
    const trimmed = try trimUtf8WithSuffix(allocator, full_text, @max(options.max_chars, 1));
    errdefer allocator.free(trimmed.text);

    const sections_json = try buildSectionsJson(allocator, items);
    errdefer allocator.free(sections_json);
    const quality_json = try buildQualityJson(allocator, .{
        .profile = options.profile,
        .strategy = strategy,
        .message_count = message_count,
        .segment_count = segment_count,
        .item_count = items.len,
        .cited_item_count = items.len,
        .truncated = trimmed.truncated,
    });
    errdefer allocator.free(quality_json);

    return .{
        .text = trimmed.text,
        .sections_json = sections_json,
        .quality_json = quality_json,
        .provider = strategy,
        .profile = options.profile,
        .strategy = strategy,
        .message_count = message_count,
        .segment_count = segment_count,
        .truncated = trimmed.truncated,
    };
}

pub fn buildLlmPrompt(allocator: std.mem.Allocator, messages: []const Message, max_chars: usize, profile: Profile) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var redactor = redaction.Redactor.init(allocator, .{});
    defer redactor.deinit();
    try out.print(allocator, "Summarize the following NullPantry messages for agent memory using the {s} profile. Preserve only source-grounded facts. Cite message indexes as [message:N].\n", .{profile.name()});
    try out.appendSlice(allocator, "Prefer typed sections when evidence exists: Topics, Decisions, Constraints, Action items, Owners, Risks, Open questions, Timeline, Root causes, Mitigations, Follow-ups, Key facts.\n\n");
    for (messages, 0..) |message, i| {
        try out.print(allocator, "Message {d}", .{i + 1});
        if (message.speaker.len > 0) {
            const safe_speaker = try redactor.redact(allocator, message.speaker);
            defer allocator.free(safe_speaker);
            try out.appendSlice(allocator, " speaker=");
            try out.appendSlice(allocator, safe_speaker);
        }
        if (message.role.len > 0) {
            const safe_role = try redactor.redact(allocator, message.role);
            defer allocator.free(safe_role);
            try out.appendSlice(allocator, " role=");
            try out.appendSlice(allocator, safe_role);
        }
        const safe_content = try redactor.redact(allocator, message.content);
        defer allocator.free(safe_content);
        try out.appendSlice(allocator, ":\n");
        try out.appendSlice(allocator, safe_content);
        try out.appendSlice(allocator, "\n\n");
    }
    try out.print(allocator, "Return at most {d} characters.", .{max_chars});
    return out.toOwnedSlice(allocator);
}

pub fn trimUtf8WithSuffix(allocator: std.mem.Allocator, text: []const u8, max_chars: usize) !TrimmedText {
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

pub fn groundedLlmSummary(allocator: std.mem.Allocator, text: []const u8, max_chars: usize, message_count: usize) !?TrimmedText {
    const trimmed = try trimUtf8WithSuffix(allocator, text, max_chars);
    errdefer allocator.free(trimmed.text);
    if (!summaryCitationsValid(trimmed.text, message_count)) {
        allocator.free(trimmed.text);
        return null;
    }
    return trimmed;
}

pub fn groundedLlmSummaryAgainstMessages(allocator: std.mem.Allocator, text: []const u8, max_chars: usize, messages: []const Message) !?TrimmedText {
    const trimmed = try trimUtf8WithSuffix(allocator, text, max_chars);
    errdefer allocator.free(trimmed.text);
    if (!summaryCitationsValid(trimmed.text, messages.len) or !summaryClaimsSupported(trimmed.text, messages)) {
        allocator.free(trimmed.text);
        return null;
    }
    return trimmed;
}

pub fn sectionsFromGroundedSummary(allocator: std.mem.Allocator, text: []const u8, messages: []const Message, max_items_per_section: usize) ![]const u8 {
    var items: std.ArrayListUnmanaged(Item) = .empty;
    defer items.deinit(allocator);

    var line_it = std.mem.splitScalar(u8, text, '\n');
    while (line_it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0 or isSectionHeading(line) or isExplicitUnknown(line)) continue;
        const citation = firstMessageCitation(line, messages.len) orelse continue;
        const cleaned = stripMessageCitationSuffix(cleanLine(line));
        if (cleaned.len == 0) continue;
        const line_item = classifyLine(cleaned);
        if (countKind(items.items, line_item.kind) >= @max(max_items_per_section, 1)) continue;
        if (containsItem(items.items, line_item.kind, line_item.text)) continue;
        const source_message = messages[citation - 1];
        try items.append(allocator, .{
            .kind = line_item.kind,
            .text = line_item.text,
            .message_index = citation - 1,
            .role = source_message.role,
            .speaker = source_message.speaker,
        });
    }

    return buildSectionsJson(allocator, items.items);
}

pub fn countGroundedSummaryLines(text: []const u8, message_count: usize) usize {
    var count: usize = 0;
    var line_it = std.mem.splitScalar(u8, text, '\n');
    while (line_it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0 or isSectionHeading(line) or isExplicitUnknown(line)) continue;
        if (firstMessageCitation(line, message_count) != null) count += 1;
    }
    return count;
}

pub fn summaryCitationsValid(text: []const u8, message_count: usize) bool {
    if (message_count == 0) return false;
    var grounded_lines: usize = 0;
    var unknown_lines: usize = 0;
    var line_it = std.mem.splitScalar(u8, text, '\n');
    while (line_it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0 or isSectionHeading(line)) continue;
        if (isExplicitUnknown(line)) {
            unknown_lines += 1;
            continue;
        }
        const citations = messageCitationState(line, message_count);
        if (citations.invalid or !citations.valid) return false;
        grounded_lines += 1;
    }
    return grounded_lines > 0 or unknown_lines > 0;
}

fn summaryClaimsSupported(text: []const u8, messages: []const Message) bool {
    if (messages.len == 0) return false;
    var grounded_lines: usize = 0;
    var unknown_lines: usize = 0;
    var line_it = std.mem.splitScalar(u8, text, '\n');
    while (line_it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0 or isSectionHeading(line)) continue;
        if (isExplicitUnknown(line)) {
            unknown_lines += 1;
            continue;
        }
        const citation = firstMessageCitation(line, messages.len) orelse return false;
        if (!lineSupportedByMessage(line, messages[citation - 1].content)) return false;
        grounded_lines += 1;
    }
    return grounded_lines > 0 or unknown_lines > 0;
}

fn firstMessageCitation(line: []const u8, message_count: usize) ?usize {
    const start = std.mem.indexOf(u8, line, "[message:") orelse return null;
    const number_start = start + "[message:".len;
    const close_rel = std.mem.indexOfScalar(u8, line[number_start..], ']') orelse return null;
    const number_end = number_start + close_rel;
    const raw_number = std.mem.trim(u8, line[number_start..number_end], " \t\r\n");
    const parsed = std.fmt.parseInt(usize, raw_number, 10) catch return null;
    if (parsed == 0 or parsed > message_count) return null;
    return parsed;
}

fn lineSupportedByMessage(line: []const u8, message: []const u8) bool {
    const claim = stripMessageCitationSuffix(cleanLine(line));
    const line_item = classifyLine(claim);
    const claim_text = std.mem.trim(u8, line_item.text, " \t\r\n");
    if (claim_text.len == 0) return false;
    if (containsFold(message, claim_text)) return true;

    const max_grounding_tokens = 24;
    var meaningful: usize = 0;
    var matched: usize = 0;
    var token_it = std.mem.tokenizeAny(u8, line_item.text, " \t\r\n.,;:!?()[]{}<>\"'`*/\\|+-_=#");
    while (token_it.next()) |token| {
        if (!isMeaningfulGroundingToken(token)) continue;
        meaningful += 1;
        if (containsFold(message, token)) matched += 1;
        if (meaningful >= max_grounding_tokens) break;
    }
    if (meaningful < 2) return false;

    const required = groundingMatchThreshold(meaningful);
    return matched >= required;
}

fn groundingMatchThreshold(meaningful: usize) usize {
    if (meaningful <= 4) return meaningful;
    const scaled = (@as(u128, meaningful) * 4 + 4) / 5;
    const required = @max(@as(u128, 4), scaled);
    return @intCast(required);
}

fn isMeaningfulGroundingToken(token: []const u8) bool {
    if (token.len < 4) return false;
    const stopwords = [_][]const u8{ "this", "that", "with", "from", "message", "decision", "decisions", "risk", "risks", "action", "items", "question", "summary", "uses", "used", "needs", "need", "should", "must" };
    for (stopwords) |stopword| {
        if (std.ascii.eqlIgnoreCase(token, stopword)) return false;
    }
    for (token) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch >= 0x80) return true;
    }
    return false;
}

const CitationState = struct {
    valid: bool = false,
    invalid: bool = false,
};

fn messageCitationState(line: []const u8, message_count: usize) CitationState {
    var state = CitationState{};
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, line, pos, "[message:")) |start| {
        const number_start = start + "[message:".len;
        const close_rel = std.mem.indexOfScalar(u8, line[number_start..], ']') orelse {
            state.invalid = true;
            return state;
        };
        const number_end = number_start + close_rel;
        const raw_number = std.mem.trim(u8, line[number_start..number_end], " \t\r\n");
        if (raw_number.len == 0) {
            state.invalid = true;
            return state;
        }
        const parsed = std.fmt.parseInt(usize, raw_number, 10) catch {
            state.invalid = true;
            return state;
        };
        if (parsed == 0 or parsed > message_count) {
            state.invalid = true;
            return state;
        }
        state.valid = true;
        pos = number_end + 1;
    }
    return state;
}

fn isSectionHeading(line: []const u8) bool {
    if (std.mem.indexOf(u8, line, "[message:") != null) return false;
    if (line.len == 0 or line[line.len - 1] != ':') return false;
    return line.len <= 80;
}

fn isExplicitUnknown(line: []const u8) bool {
    return containsFold(line, "i don't know") or
        containsFold(line, "insufficient evidence") or
        containsFold(line, "not enough evidence") or
        containsFold(line, "no supported") or
        containsFold(line, "no source-grounded");
}

fn containsFold(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

pub const QualityInput = struct {
    profile: Profile,
    strategy: []const u8,
    message_count: usize,
    segment_count: usize,
    item_count: usize,
    cited_item_count: usize,
    truncated: bool,
};

pub fn buildQualityJson(allocator: std.mem.Allocator, input: QualityInput) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"profile\":");
    try json.appendString(&out, allocator, input.profile.name());
    try out.appendSlice(allocator, ",\"strategy\":");
    try json.appendString(&out, allocator, input.strategy);
    try out.print(
        allocator,
        ",\"message_count\":{d},\"segment_count\":{d},\"item_count\":{d},\"cited_item_count\":{d},\"citation_coverage\":{d},\"truncated\":{s}}}",
        .{
            input.message_count,
            input.segment_count,
            input.item_count,
            input.cited_item_count,
            citationCoveragePercent(input.cited_item_count, input.item_count),
            if (input.truncated) "true" else "false",
        },
    );
    return out.toOwnedSlice(allocator);
}

fn citationCoveragePercent(cited_item_count: usize, item_count: usize) usize {
    if (item_count == 0) return 0;
    const cited = @min(cited_item_count, item_count);
    const percent = (@as(u128, cited) * 100) / @as(u128, item_count);
    return @intCast(percent);
}

fn buildTextSummary(allocator: std.mem.Allocator, items: []const Item, message_count: usize, profile: Profile, max_items_per_section: usize) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "Structured Summary\n");
    try out.print(allocator, "Profile: {s}\n", .{profile.name()});
    try out.print(allocator, "Messages: {d}\n", .{message_count});
    var wrote_any = false;
    inline for (summary_section_order) |kind| {
        const before = out.items.len;
        try appendTextSection(allocator, &out, kind, items, max_items_per_section);
        wrote_any = wrote_any or out.items.len > before;
    }
    if (!wrote_any) try out.appendSlice(allocator, "\nNo summarizable content was found.\n");
    return out.toOwnedSlice(allocator);
}

fn appendTextSection(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), kind: SectionKind, items: []const Item, max_items_per_section: usize) !void {
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
        if (count >= max_items_per_section) break;
    }
}

fn buildSectionsJson(allocator: std.mem.Allocator, items: []const Item) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '{');
    inline for (summary_section_order, 0..) |kind, i| {
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

const summary_section_order = [_]SectionKind{
    .topics,
    .decisions,
    .constraints,
    .action_items,
    .owners,
    .risks,
    .open_questions,
    .timeline,
    .root_causes,
    .mitigations,
    .follow_ups,
    .facts,
};

fn classifyLine(line: []const u8) ClassifiedLine {
    if (stripPrefixed(line, &topic_prefixes)) |text| return .{ .kind = .topics, .text = text };
    if (stripPrefixed(line, &decision_prefixes)) |text| return .{ .kind = .decisions, .text = text };
    if (stripPrefixed(line, &constraint_prefixes)) |text| return .{ .kind = .constraints, .text = text };
    if (stripPrefixed(line, &owner_prefixes)) |text| return .{ .kind = .owners, .text = text };
    if (stripPrefixed(line, &action_prefixes)) |text| return .{ .kind = .action_items, .text = text };
    if (stripPrefixed(line, &risk_prefixes)) |text| return .{ .kind = .risks, .text = text };
    if (stripPrefixed(line, &question_prefixes)) |text| return .{ .kind = .open_questions, .text = text };
    if (stripPrefixed(line, &timeline_prefixes)) |text| return .{ .kind = .timeline, .text = text };
    if (stripPrefixed(line, &root_cause_prefixes)) |text| return .{ .kind = .root_causes, .text = text };
    if (stripPrefixed(line, &mitigation_prefixes)) |text| return .{ .kind = .mitigations, .text = text };
    if (stripPrefixed(line, &follow_up_prefixes)) |text| return .{ .kind = .follow_ups, .text = text };
    return .{ .kind = .facts, .text = line };
}

const topic_prefixes = [_][]const u8{ "Topic:", "Topics:", "Agenda:", "Тема:", "Темы:" };
const decision_prefixes = [_][]const u8{ "Decision:", "Decided:", "ADR:", "Решение:", "Решили:" };
const constraint_prefixes = [_][]const u8{ "Constraint:", "Constraints:", "Invariant:", "Ограничение:", "Ограничения:" };
const action_prefixes = [_][]const u8{ "Action:", "Action item:", "TODO:", "Next step:", "Owner:", "Действие:", "Задача:" };
const owner_prefixes = [_][]const u8{ "Assigned:", "Assignee:", "Responsible:", "Owner:", "Владелец:", "Ответственный:" };
const risk_prefixes = [_][]const u8{ "Risk:", "Risks:", "Concern:", "Issue:", "Риск:", "Проблема:" };
const question_prefixes = [_][]const u8{ "Question:", "Open question:", "Q:", "Вопрос:", "Открытый вопрос:" };
const timeline_prefixes = [_][]const u8{ "Timeline:", "At:", "Event:", "Событие:", "Таймлайн:" };
const root_cause_prefixes = [_][]const u8{ "Root cause:", "Cause:", "Причина:", "Корневая причина:" };
const mitigation_prefixes = [_][]const u8{ "Mitigation:", "Mitigated:", "Fix:", "Исправление:", "Митигация:" };
const follow_up_prefixes = [_][]const u8{ "Follow-up:", "Follow up:", "Followup:", "Lesson:", "Lesson learned:", "Последующее:", "Урок:" };

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

fn keyFactContent(line: []const u8) ?[]const u8 {
    const prefixes = [_][]const u8{ "Key fact:", "Key fact -", "- Key fact:", "* Key fact:" };
    for (prefixes) |prefix| {
        if (!startsWithFold(line, prefix)) continue;
        return stripMessageCitationSuffix(std.mem.trim(u8, line[prefix.len..], " \t-:"));
    }
    return null;
}

fn stripMessageCitationSuffix(text: []const u8) []const u8 {
    if (text.len == 0 or text[text.len - 1] != ']') return text;
    const marker = " [message:";
    const idx = std.mem.lastIndexOf(u8, text, marker) orelse return text;
    return std.mem.trim(u8, text[0..idx], " \t\r\n");
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
    defer std.testing.allocator.free(summary.quality_json);

    try std.testing.expectEqualStrings("extractive_structured", summary.provider);
    try std.testing.expectEqualStrings("extractive_structured", summary.strategy);
    try std.testing.expectEqual(@as(usize, 1), summary.segment_count);
    try std.testing.expect(std.mem.indexOf(u8, summary.text, "NullPantry owns central memory [message:1]") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary.text, "add structured summarizer [message:2]") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary.sections_json, "\"decisions\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary.sections_json, "\"speaker\":\"Igor\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary.quality_json, "\"citation_coverage\":100") != null);
}

test "summarizer respects tight character budgets" {
    const messages = [_]Message{.{ .content = "Decision: NullPantry should keep summaries bounded for agents" }};
    const summary = try summarizeMessages(std.testing.allocator, &messages, .{ .max_chars = 12 });
    defer std.testing.allocator.free(summary.text);
    defer std.testing.allocator.free(summary.sections_json);
    defer std.testing.allocator.free(summary.quality_json);
    try std.testing.expect(summary.truncated);
    try std.testing.expect(summary.text.len <= 12);
}

test "summarizer sliding window primitives match nullclaw behavior" {
    const messages = [_]Message{
        .{ .role = "user", .content = "a" ** 20000 },
        .{ .role = "assistant", .content = "b" ** 20000 },
        .{ .role = "user", .content = "short recent" },
    };

    try std.testing.expect(shouldSummarize(&messages, 4000));
    const partition = partitionMessages(&messages, 4000);
    try std.testing.expectEqual(@as(usize, 2), partition.to_summarize);
    try std.testing.expectEqual(@as(usize, 1), partition.to_keep);
    try std.testing.expect(!shouldSummarize(messages[2..], 4000));
}

test "summarizer token budget helpers fail closed on overflow" {
    const max = std.math.maxInt(usize);
    try std.testing.expectEqual(max, tokenEstimateAdd(max - 1, 2));
    try std.testing.expect(tokenBudgetCanFit(10, 5, 15));
    try std.testing.expect(!tokenBudgetCanFit(10, 6, 15));
    try std.testing.expect(!tokenBudgetCanFit(max - 1, 2, max));
    try std.testing.expect(!tokenBudgetCanFit(max, 1, max));

    const messages = [_]Message{
        .{ .role = "user", .content = "first" },
        .{ .role = "assistant", .content = "second" },
    };
    try std.testing.expect(shouldSummarize(&messages, 0));
    const partition = partitionMessages(&messages, 0);
    try std.testing.expectEqual(@as(usize, 1), partition.to_summarize);
    try std.testing.expectEqual(@as(usize, 1), partition.to_keep);
}

test "summarizer quality ratio helpers avoid overflow" {
    const max = std.math.maxInt(usize);

    try std.testing.expectEqual(@as(usize, 0), citationCoveragePercent(0, 0));
    try std.testing.expectEqual(@as(usize, 0), citationCoveragePercent(0, 10));
    try std.testing.expectEqual(@as(usize, 40), citationCoveragePercent(2, 5));
    try std.testing.expectEqual(@as(usize, 100), citationCoveragePercent(5, 5));
    try std.testing.expectEqual(@as(usize, 100), citationCoveragePercent(max, max));
    try std.testing.expectEqual(@as(usize, 100), citationCoveragePercent(max, 1));

    try std.testing.expectEqual(@as(usize, 1), groundingMatchThreshold(1));
    try std.testing.expectEqual(@as(usize, 4), groundingMatchThreshold(4));
    try std.testing.expectEqual(@as(usize, 4), groundingMatchThreshold(5));
    try std.testing.expectEqual(@as(usize, 20), groundingMatchThreshold(24));
    try std.testing.expect(groundingMatchThreshold(max) > max / 2);
}

test "summarizer extracts semantic key facts from LLM-style response" {
    const facts = try extractSemanticFacts(std.testing.allocator,
        \\Conversation summary.
        \\Key fact: NullPantry owns central memory.
        \\- Key fact: Agents can share project memory through scoped permissions.
        \\Not a fact: ignore this line.
    , "semantic_fact_");
    defer freeExtractedFacts(std.testing.allocator, facts);

    try std.testing.expectEqual(@as(usize, 2), facts.len);
    try std.testing.expectEqualStrings("semantic_fact_0", facts[0].key);
    try std.testing.expectEqualStrings("NullPantry owns central memory.", facts[0].content);
    try std.testing.expectEqualStrings("semantic_fact_1", facts[1].key);
    try std.testing.expectEqualStrings("Agents can share project memory through scoped permissions.", facts[1].content);
}

test "summarizer LLM prompt redacts model-boundary PII and secrets" {
    const messages = [_]Message{
        .{ .speaker = "alice@example.com", .content = "Decision: contact alice@example.com using token=abc123 and sk-live-secret" },
    };
    const prompt = try buildLlmPrompt(std.testing.allocator, &messages, 1000, .meeting);
    defer std.testing.allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "meeting profile") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "alice@example.com") == null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "abc123") == null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "sk-live-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "[EMAIL_1]") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "[TOKEN_1]") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "[TOKEN_2]") != null);
}

test "summarizer validates LLM message citations before accepting grounded summaries" {
    try std.testing.expect(summaryCitationsValid(
        \\Decisions:
        \\- NullPantry owns central summaries [message:1]
        \\- Agents need cited context [message:2]
    , 2));
    try std.testing.expect(summaryCitationsValid("I don't know from the supplied messages.", 2));
    try std.testing.expect(!summaryCitationsValid("NullPantry owns central summaries.", 2));
    try std.testing.expect(!summaryCitationsValid("- Uses Postgres [message:3]", 2));
    try std.testing.expect(!summaryCitationsValid("- Broken citation [message:x]", 2));
    try std.testing.expect(!summaryCitationsValid("- Missing close [message:1", 2));
    try std.testing.expect(!summaryCitationsValid("I don't know.\nUnsupported extra fact.", 2));
}

test "summarizer rejects ungrounded LLM summary text before persistence" {
    const accepted = try groundedLlmSummary(std.testing.allocator, "Decision: cited summary [message:1]", 200, 1);
    try std.testing.expect(accepted != null);
    std.testing.allocator.free(accepted.?.text);

    const rejected = try groundedLlmSummary(std.testing.allocator, "Decision: uncited summary", 200, 1);
    try std.testing.expect(rejected == null);
}

test "summarizer incident profile extracts lifecycle-specific sections" {
    const messages = [_]Message{
        .{ .content = "Timeline: 03:12 NullWatch fired high latency\nRoot cause: queue workers stopped heartbeating" },
        .{ .content = "Mitigation: restarted stuck worker pool\nFollow-up: add worker lease reclaim test" },
    };
    const summary = try summarizeMessages(std.testing.allocator, &messages, .{ .max_chars = 2000, .profile = .incident });
    defer std.testing.allocator.free(summary.text);
    defer std.testing.allocator.free(summary.sections_json);
    defer std.testing.allocator.free(summary.quality_json);

    try std.testing.expectEqual(.incident, summary.profile);
    try std.testing.expect(std.mem.indexOf(u8, summary.text, "Profile: incident") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary.sections_json, "\"timeline\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary.sections_json, "\"root_causes\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary.sections_json, "\"mitigations\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary.sections_json, "\"follow_ups\"") != null);
}

test "summarizer map reduce preserves original message citations" {
    const messages = [_]Message{
        .{ .content = "Decision: first window uses Sources" ++ (" a" ** 80) },
        .{ .content = "Decision: second window uses Artifacts" ++ (" b" ** 80) },
        .{ .content = "Decision: third window uses Memory Atoms" ++ (" c" ** 80) },
    };
    const summary = try summarizeMessages(std.testing.allocator, &messages, .{ .max_chars = 3000, .window_size_tokens = 30 });
    defer std.testing.allocator.free(summary.text);
    defer std.testing.allocator.free(summary.sections_json);
    defer std.testing.allocator.free(summary.quality_json);

    try std.testing.expectEqualStrings("extractive_structured_map_reduce", summary.strategy);
    try std.testing.expect(summary.segment_count > 1);
    try std.testing.expect(std.mem.indexOf(u8, summary.text, "[message:1]") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary.text, "[message:2]") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary.text, "[message:3]") != null);
}

test "summarizer validates LLM claims against cited message content" {
    const messages = [_]Message{
        .{ .content = "Decision: NullPantry uses Sources and Memory Atoms." },
        .{ .content = "Risk: stale context can mislead agents." },
    };
    const accepted = try groundedLlmSummaryAgainstMessages(std.testing.allocator, "Decision: NullPantry uses Memory Atoms [message:1]", 500, &messages);
    try std.testing.expect(accepted != null);
    std.testing.allocator.free(accepted.?.text);

    const wrong_source = try groundedLlmSummaryAgainstMessages(std.testing.allocator, "Decision: NullPantry uses Memory Atoms [message:2]", 500, &messages);
    try std.testing.expect(wrong_source == null);

    const contradicted = try groundedLlmSummaryAgainstMessages(std.testing.allocator, "Decision: NullPantry uses Postgres [message:1]", 500, &messages);
    try std.testing.expect(contradicted == null);

    const unsupported_extra = try groundedLlmSummaryAgainstMessages(std.testing.allocator, "Decision: NullPantry uses Memory Atoms and Redis [message:1]", 500, &messages);
    try std.testing.expect(unsupported_extra == null);

    const uncited = try groundedLlmSummaryAgainstMessages(std.testing.allocator, "Decision: NullPantry uses Memory Atoms", 500, &messages);
    try std.testing.expect(uncited == null);
}

test "summarizer builds sections from grounded LLM output" {
    const messages = [_]Message{
        .{ .speaker = "Igor", .content = "Decision: NullPantry keeps agent memory centralized." },
        .{ .role = "assistant", .content = "Risk: stale memory can leak bad context." },
    };
    const sections = try sectionsFromGroundedSummary(std.testing.allocator,
        \\Decisions:
        \\- Decision: NullPantry keeps agent memory centralized [message:1]
        \\Risks:
        \\- Risk: stale memory can leak bad context [message:2]
    , &messages, 8);
    defer std.testing.allocator.free(sections);

    try std.testing.expect(std.mem.indexOf(u8, sections, "\"decisions\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections, "\"message_index\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections, "\"speaker\":\"Igor\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections, "\"risks\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections, "\"message_index\":1") != null);
}
