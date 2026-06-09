const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Language = enum {
    en,
    zh,
    ko,
    ja,
    es,
    pt,
    ru,
    ar,
    unknown,
};

pub const ExpandedQuery = struct {
    fts5_query: []const u8,
    original_tokens: []const []const u8,
    filtered_tokens: []const []const u8,
    language: Language,

    pub fn deinit(self: *ExpandedQuery, allocator: Allocator) void {
        allocator.free(self.fts5_query);
        for (self.original_tokens) |token| allocator.free(token);
        allocator.free(self.original_tokens);
        for (self.filtered_tokens) |token| allocator.free(token);
        allocator.free(self.filtered_tokens);
        self.* = undefined;
    }
};

pub fn expandQuery(allocator: Allocator, raw_query: []const u8) !ExpandedQuery {
    const trimmed = std.mem.trim(u8, raw_query, " \t\r\n");
    if (trimmed.len == 0) {
        return .{
            .fts5_query = try allocator.dupe(u8, ""),
            .original_tokens = try allocator.alloc([]const u8, 0),
            .filtered_tokens = try allocator.alloc([]const u8, 0),
            .language = .unknown,
        };
    }

    const language = detectLanguage(trimmed);

    var original_tokens: std.ArrayListUnmanaged([]const u8) = .empty;
    defer original_tokens.deinit(allocator);
    errdefer freeOwnedTokens(original_tokens.items, allocator);

    var raw_tokens: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        freeOwnedTokens(raw_tokens.items, allocator);
        raw_tokens.deinit(allocator);
    }

    var filtered_tokens: std.ArrayListUnmanaged([]const u8) = .empty;
    defer filtered_tokens.deinit(allocator);
    errdefer freeOwnedTokens(filtered_tokens.items, allocator);

    var words = std.mem.splitScalar(u8, trimmed, ' ');
    while (words.next()) |word| {
        const token = std.mem.trim(u8, word, " \t\r\n");
        if (token.len == 0) continue;
        const lowered = try toLower(allocator, token);
        errdefer allocator.free(lowered);
        try original_tokens.append(allocator, lowered);
    }

    try tokenize(allocator, trimmed, language, &raw_tokens);

    var seen = std.StringHashMap(void).init(allocator);
    defer {
        var keys = seen.keyIterator();
        while (keys.next()) |key| allocator.free(key.*);
        seen.deinit();
    }

    for (raw_tokens.items) |token| {
        if (isStopWord(token)) continue;
        if (!isValidKeyword(token)) continue;
        if (seen.contains(token)) continue;

        const seen_key = try allocator.dupe(u8, token);
        errdefer allocator.free(seen_key);
        try seen.put(seen_key, {});

        const filtered = try allocator.dupe(u8, token);
        errdefer allocator.free(filtered);
        try filtered_tokens.append(allocator, filtered);
    }

    const fts5_query = if (filtered_tokens.items.len == 0)
        try allocator.dupe(u8, trimmed)
    else
        try buildFts5TokenQuery(allocator, filtered_tokens.items);
    errdefer allocator.free(fts5_query);

    const owned_original = try original_tokens.toOwnedSlice(allocator);
    errdefer {
        for (owned_original) |token| allocator.free(token);
        allocator.free(owned_original);
    }

    const owned_filtered = try filtered_tokens.toOwnedSlice(allocator);
    errdefer {
        for (owned_filtered) |token| allocator.free(token);
        allocator.free(owned_filtered);
    }

    return .{
        .fts5_query = fts5_query,
        .original_tokens = owned_original,
        .filtered_tokens = owned_filtered,
        .language = language,
    };
}

pub fn extractKeywords(allocator: Allocator, query: []const u8) ![]const []const u8 {
    const expanded = try expandQuery(allocator, query);
    allocator.free(expanded.fts5_query);
    for (expanded.original_tokens) |token| allocator.free(token);
    allocator.free(expanded.original_tokens);
    return expanded.filtered_tokens;
}

fn detectLanguage(text: []const u8) Language {
    var has_cjk = false;
    var has_hangul = false;
    var has_kana = false;
    var has_arabic = false;
    var has_cyrillic = false;

    var i: usize = 0;
    while (i < text.len) {
        const cp_len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            i += 1;
            continue;
        };
        if (i + cp_len > text.len) break;
        const cp = std.unicode.utf8Decode(text[i..][0..cp_len]) catch {
            i += 1;
            continue;
        };
        if ((cp >= 0xAC00 and cp <= 0xD7AF) or (cp >= 0x3131 and cp <= 0x3163)) {
            has_hangul = true;
        } else if (cp >= 0x3040 and cp <= 0x30FF) {
            has_kana = true;
        } else if (cp >= 0x4E00 and cp <= 0x9FFF) {
            has_cjk = true;
        } else if ((cp >= 0x0600 and cp <= 0x06FF) or (cp >= 0x0750 and cp <= 0x077F)) {
            has_arabic = true;
        } else if ((cp >= 0x0400 and cp <= 0x04FF) or (cp >= 0x0500 and cp <= 0x052F)) {
            has_cyrillic = true;
        }
        i += cp_len;
    }

    if (has_hangul) return .ko;
    if (has_kana) return .ja;
    if (has_cjk) return .zh;
    if (has_arabic) return .ar;
    if (has_cyrillic) return .ru;

    const lower = lowerStack(text);
    const haystack = lower.constSlice();
    if (containsAny(haystack, &.{ " el ", " la ", " los ", " las ", " del ", " como ", " pero " })) return .es;
    if (containsAny(haystack, &.{ " da ", " das ", " dos ", " pela ", " pelas " })) return .pt;
    return .en;
}

const StackLower = struct {
    data: [514]u8 = undefined,
    len: usize = 0,

    fn constSlice(self: *const StackLower) []const u8 {
        return self.data[0..self.len];
    }
};

fn lowerStack(text: []const u8) StackLower {
    var out = StackLower{};
    out.data[0] = ' ';
    out.len = 1;
    const limit = @min(text.len, out.data.len - 2);
    for (text[0..limit]) |ch| {
        out.data[out.len] = if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
        out.len += 1;
    }
    out.data[out.len] = ' ';
    out.len += 1;
    return out;
}

fn tokenize(allocator: Allocator, text: []const u8, language: Language, out: *std.ArrayListUnmanaged([]const u8)) !void {
    var segments = std.mem.splitScalar(u8, text, ' ');
    while (segments.next()) |segment| {
        const trimmed = std.mem.trim(u8, segment, " \t\r\n");
        if (trimmed.len == 0) continue;
        const cleaned = stripAsciiPunctuation(trimmed);
        if (cleaned.len == 0) continue;

        switch (language) {
            .zh => try tokenizeChinese(allocator, cleaned, out),
            .ja => try tokenizeJapanese(allocator, cleaned, out),
            .ko => try tokenizeKorean(allocator, cleaned, out),
            else => {
                const lowered = try toLower(allocator, cleaned);
                errdefer allocator.free(lowered);
                try out.append(allocator, lowered);
            },
        }
    }
}

fn tokenizeKorean(allocator: Allocator, text: []const u8, out: *std.ArrayListUnmanaged([]const u8)) !void {
    const lowered = try toLower(allocator, text);
    errdefer allocator.free(lowered);
    try out.append(allocator, lowered);

    if (stripKoreanParticle(lowered)) |stem_end| {
        const stem = lowered[0..stem_end];
        if (isUsefulKoreanStem(stem) and !isStopWord(stem)) {
            const owned = try allocator.dupe(u8, stem);
            errdefer allocator.free(owned);
            try out.append(allocator, owned);
        }
    }
}

fn tokenizeChinese(allocator: Allocator, text: []const u8, out: *std.ArrayListUnmanaged([]const u8)) !void {
    var chars: std.ArrayListUnmanaged([]const u8) = .empty;
    defer chars.deinit(allocator);

    var ascii: std.ArrayListUnmanaged(u8) = .empty;
    defer ascii.deinit(allocator);

    var i: usize = 0;
    while (i < text.len) {
        const cp_len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            i += 1;
            continue;
        };
        if (i + cp_len > text.len) break;
        const cp = std.unicode.utf8Decode(text[i..][0..cp_len]) catch {
            i += 1;
            continue;
        };

        if (cp >= 0x4E00 and cp <= 0x9FFF) {
            try flushAsciiToken(allocator, &ascii, out);
            try chars.append(allocator, text[i..][0..cp_len]);
        } else if (isAsciiSearchChar(cp)) {
            try ascii.append(allocator, std.ascii.toLower(@as(u8, @intCast(cp))));
        } else {
            try flushAsciiToken(allocator, &ascii, out);
        }
        i += cp_len;
    }

    try flushAsciiToken(allocator, &ascii, out);
    if (chars.items.len >= 2) {
        for (0..chars.items.len - 1) |idx| {
            const bigram = try std.fmt.allocPrint(allocator, "{s}{s}", .{ chars.items[idx], chars.items[idx + 1] });
            errdefer allocator.free(bigram);
            try out.append(allocator, bigram);
        }
    } else if (chars.items.len == 1) {
        const unigram = try allocator.dupe(u8, chars.items[0]);
        errdefer allocator.free(unigram);
        try out.append(allocator, unigram);
    }
}

const JapaneseScript = enum { none, ascii, katakana, kanji, hiragana };

fn tokenizeJapanese(allocator: Allocator, text: []const u8, out: *std.ArrayListUnmanaged([]const u8)) !void {
    var current: JapaneseScript = .none;
    var start: usize = 0;
    var end: usize = 0;

    var i: usize = 0;
    while (i < text.len) {
        const cp_len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            i += 1;
            continue;
        };
        if (i + cp_len > text.len) break;
        const cp = std.unicode.utf8Decode(text[i..][0..cp_len]) catch {
            i += 1;
            continue;
        };
        const script: JapaneseScript = if (isAsciiSearchChar(cp))
            .ascii
        else if ((cp >= 0x30A0 and cp <= 0x30FF) or cp == 0x30FC)
            .katakana
        else if (cp >= 0x4E00 and cp <= 0x9FFF)
            .kanji
        else if (cp >= 0x3040 and cp <= 0x309F)
            .hiragana
        else
            .none;

        if (script != current) {
            if (current != .none and end > start) try emitJapaneseChunk(allocator, text[start..end], current, out);
            current = script;
            start = i;
        }
        end = i + cp_len;
        i += cp_len;
    }

    if (current != .none and end > start) try emitJapaneseChunk(allocator, text[start..end], current, out);
}

fn emitJapaneseChunk(allocator: Allocator, chunk: []const u8, script: JapaneseScript, out: *std.ArrayListUnmanaged([]const u8)) !void {
    switch (script) {
        .ascii => {
            const lowered = try toLower(allocator, chunk);
            errdefer allocator.free(lowered);
            try out.append(allocator, lowered);
        },
        .katakana => {
            const owned = try allocator.dupe(u8, chunk);
            errdefer allocator.free(owned);
            try out.append(allocator, owned);
        },
        .kanji => {
            const owned = try allocator.dupe(u8, chunk);
            errdefer allocator.free(owned);
            try out.append(allocator, owned);
            try tokenizeChinese(allocator, chunk, out);
        },
        .hiragana => {
            if (utf8CodepointCount(chunk) >= 2) {
                const owned = try allocator.dupe(u8, chunk);
                errdefer allocator.free(owned);
                try out.append(allocator, owned);
            }
        },
        .none => {},
    }
}

fn flushAsciiToken(allocator: Allocator, ascii: *std.ArrayListUnmanaged(u8), out: *std.ArrayListUnmanaged([]const u8)) !void {
    if (ascii.items.len == 0) return;
    const token = try ascii.toOwnedSlice(allocator);
    errdefer allocator.free(token);
    try out.append(allocator, token);
}

fn isAsciiSearchChar(cp: u21) bool {
    return (cp >= 'a' and cp <= 'z') or
        (cp >= 'A' and cp <= 'Z') or
        (cp >= '0' and cp <= '9') or
        cp == '_';
}

fn stripKoreanParticle(token: []const u8) ?usize {
    const particles = [_][]const u8{
        "\xec\x97\x90\xec\x84\x9c",
        "\xec\x9c\xbc\xeb\xa1\x9c",
        "\xec\x97\x90\xea\xb2\x8c",
        "\xed\x95\x9c\xed\x85\x8c",
        "\xec\x9d\x80",
        "\xeb\x8a\x94",
        "\xec\x9d\xb4",
        "\xea\xb0\x80",
        "\xec\x9d\x84",
        "\xeb\xa5\xbc",
        "\xec\x9d\x98",
        "\xec\x97\x90",
        "\xeb\xa1\x9c",
        "\xec\x99\x80",
        "\xea\xb3\xbc",
        "\xeb\x8f\x84",
        "\xeb\xa7\x8c",
    };
    for (particles) |particle| {
        if (token.len > particle.len and std.mem.endsWith(u8, token, particle)) return token.len - particle.len;
    }
    return null;
}

fn isUsefulKoreanStem(stem: []const u8) bool {
    var has_hangul = false;
    var count: usize = 0;
    var i: usize = 0;
    while (i < stem.len) {
        const cp_len = std.unicode.utf8ByteSequenceLength(stem[i]) catch {
            i += 1;
            continue;
        };
        if (i + cp_len > stem.len) break;
        const cp = std.unicode.utf8Decode(stem[i..][0..cp_len]) catch {
            i += 1;
            continue;
        };
        if (cp >= 0xAC00 and cp <= 0xD7AF) has_hangul = true;
        count += 1;
        i += cp_len;
    }
    return if (has_hangul) count >= 2 else isAsciiAlnum(stem);
}

fn isStopWord(token: []const u8) bool {
    return stop_words_en.has(token) or
        stop_words_zh.has(token) or
        stop_words_ko.has(token) or
        stop_words_ja.has(token) or
        stop_words_es.has(token) or
        stop_words_pt.has(token) or
        stop_words_ru.has(token) or
        stop_words_ar.has(token);
}

const stop_words_en = std.StaticStringMap(void).initComptime(.{
    .{"a"},       .{"about"},     .{"above"},   .{"after"},    .{"again"},    .{"all"},
    .{"also"},    .{"an"},        .{"and"},     .{"any"},      .{"are"},      .{"as"},
    .{"at"},      .{"be"},        .{"been"},    .{"before"},   .{"being"},    .{"below"},
    .{"between"}, .{"but"},       .{"by"},      .{"can"},      .{"could"},    .{"did"},
    .{"do"},      .{"does"},      .{"during"},  .{"each"},     .{"every"},    .{"find"},
    .{"for"},     .{"from"},      .{"further"}, .{"get"},      .{"give"},     .{"had"},
    .{"has"},     .{"have"},      .{"he"},      .{"help"},     .{"her"},      .{"his"},
    .{"how"},     .{"i"},         .{"if"},      .{"in"},       .{"into"},     .{"is"},
    .{"it"},      .{"its"},       .{"just"},    .{"may"},      .{"me"},       .{"might"},
    .{"must"},    .{"my"},        .{"nor"},     .{"not"},      .{"now"},      .{"of"},
    .{"off"},     .{"on"},        .{"once"},    .{"or"},       .{"our"},      .{"out"},
    .{"over"},    .{"please"},    .{"shall"},   .{"she"},      .{"should"},   .{"show"},
    .{"so"},      .{"some"},      .{"tell"},    .{"than"},     .{"that"},     .{"the"},
    .{"their"},   .{"them"},      .{"then"},    .{"these"},    .{"they"},     .{"thing"},
    .{"things"},  .{"this"},      .{"those"},   .{"through"},  .{"to"},       .{"too"},
    .{"under"},   .{"up"},        .{"used"},    .{"very"},     .{"was"},      .{"we"},
    .{"were"},    .{"what"},      .{"when"},    .{"where"},    .{"which"},    .{"who"},
    .{"whom"},    .{"why"},       .{"will"},    .{"with"},     .{"would"},    .{"you"},
    .{"your"},    .{"yesterday"}, .{"today"},   .{"tomorrow"}, .{"recently"},
});

const stop_words_zh = std.StaticStringMap(void).initComptime(.{
    .{"\xe6\x88\x91"}, .{"\xe4\xbd\xa0"}, .{"\xe4\xbb\x96"},             .{"\xe5\xa5\xb9"},
    .{"\xe8\xbf\x99"}, .{"\xe9\x82\xa3"}, .{"\xe7\x9a\x84"},             .{"\xe4\xba\x86"},
    .{"\xe6\x98\xaf"}, .{"\xe6\x9c\x89"}, .{"\xe5\x9c\xa8"},             .{"\xe5\x92\x8c"},
    .{"\xe6\x88\x96"}, .{"\xe4\xbd\x86"}, .{"\xe4\xbb\x80\xe4\xb9\x88"},
});

const stop_words_ko = std.StaticStringMap(void).initComptime(.{
    .{"\xec\x9d\x80"}, .{"\xeb\x8a\x94"}, .{"\xec\x9d\xb4"}, .{"\xea\xb0\x80"},
    .{"\xec\x9d\x84"}, .{"\xeb\xa5\xbc"}, .{"\xec\x9d\x98"}, .{"\xec\x97\x90"},
    .{"\xeb\xa1\x9c"}, .{"\xeb\x8f\x84"}, .{"\xec\x99\x9c"}, .{"\xeb\xad\x90"},
});

const stop_words_ja = std.StaticStringMap(void).initComptime(.{
    .{"\xe3\x81\x93\xe3\x82\x8c"}, .{"\xe3\x81\x9d\xe3\x82\x8c"},
    .{"\xe3\x81\x99\xe3\x82\x8b"}, .{"\xe3\x81\xa7\xe3\x81\x99"},
    .{"\xe3\x81\xbe\xe3\x81\x99"}, .{"\xe3\x81\xae"},
});

const stop_words_es = std.StaticStringMap(void).initComptime(.{
    .{"el"},  .{"la"},   .{"los"},    .{"las"},   .{"un"},   .{"una"}, .{"de"}, .{"del"},
    .{"a"},   .{"en"},   .{"con"},    .{"por"},   .{"para"}, .{"y"},   .{"o"},  .{"pero"},
    .{"que"}, .{"como"}, .{"cuando"}, .{"donde"},
});

const stop_words_pt = std.StaticStringMap(void).initComptime(.{
    .{"o"},  .{"a"},  .{"os"},  .{"as"},  .{"um"},   .{"uma"}, .{"de"}, .{"do"},
    .{"da"}, .{"em"}, .{"com"}, .{"por"}, .{"para"}, .{"e"},   .{"ou"}, .{"mas"},
});

const stop_words_ru = std.StaticStringMap(void).initComptime(.{
    .{"а"},
    .{"без"},
    .{"бы"},
    .{"был"},
    .{"была"},
    .{"были"},
    .{"быть"},
    .{"в"},
    .{"во"},
    .{"где"},
    .{"для"},
    .{"до"},
    .{"его"},
    .{"ее"},
    .{"если"},
    .{"есть"},
    .{"еще"},
    .{"же"},
    .{"за"},
    .{"зачем"},
    .{"и"},
    .{"из"},
    .{"или"},
    .{"им"},
    .{"их"},
    .{"как"},
    .{"когда"},
    .{"кто"},
    .{"ли"},
    .{"мы"},
    .{"на"},
    .{"над"},
    .{"нам"},
    .{"нас"},
    .{"не"},
    .{"но"},
    .{"о"},
    .{"об"},
    .{"он"},
    .{"она"},
    .{"они"},
    .{"оно"},
    .{"от"},
    .{"по"},
    .{"под"},
    .{"почему"},
    .{"при"},
    .{"про"},
    .{"с"},
    .{"со"},
    .{"так"},
    .{"то"},
    .{"у"},
    .{"чем"},
    .{"что"},
    .{"чтобы"},
    .{"это"},
    .{"этот"},
    .{"эта"},
    .{"эти"},
    .{"делать"},
    .{"сделать"},
});

const stop_words_ar = std.StaticStringMap(void).initComptime(.{
    .{"\xd8\xa7\xd9\x84"},         .{"\xd9\x88"},                 .{"\xd8\xa3\xd9\x88"},
    .{"\xd9\x85\xd9\x86"},         .{"\xd8\xa5\xd9\x84\xd9\x89"}, .{"\xd9\x81\xd9\x8a"},
    .{"\xd8\xb9\xd9\x84\xd9\x89"},
});

fn isValidKeyword(token: []const u8) bool {
    if (token.len == 0) return false;
    if (isPureAsciiAlpha(token)) return token.len >= 3;
    if (isPureNumeric(token)) return false;
    if (isPurePunctuation(token)) return false;
    return true;
}

fn buildFts5TokenQuery(allocator: Allocator, tokens: []const []const u8) ![]const u8 {
    var parts: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (parts.items) |part| allocator.free(part);
        parts.deinit(allocator);
    }

    for (tokens) |token| {
        const escaped = try escapeFts5Quotes(allocator, token);
        defer allocator.free(escaped);
        const needs_quote = hasFts5Special(token);
        const needs_prefix = isPureAsciiAlpha(token) and token.len < 4;
        const part = if (needs_quote and needs_prefix)
            try std.fmt.allocPrint(allocator, "\"{s}\"*", .{escaped})
        else if (needs_quote)
            try std.fmt.allocPrint(allocator, "\"{s}\"", .{escaped})
        else if (needs_prefix)
            try std.fmt.allocPrint(allocator, "{s}*", .{token})
        else
            try allocator.dupe(u8, token);
        errdefer allocator.free(part);
        try parts.append(allocator, part);
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    for (parts.items, 0..) |part, idx| {
        if (idx > 0) try out.append(allocator, ' ');
        try out.appendSlice(allocator, part);
    }
    return out.toOwnedSlice(allocator);
}

fn hasFts5Special(token: []const u8) bool {
    for (token) |ch| {
        switch (ch) {
            '"', '*', '+', '-', '(', ')', ':', '^' => return true,
            else => {},
        }
    }
    return false;
}

fn escapeFts5Quotes(allocator: Allocator, token: []const u8) ![]const u8 {
    var quotes: usize = 0;
    for (token) |ch| {
        if (ch == '"') quotes += 1;
    }
    if (quotes == 0) return allocator.dupe(u8, token);
    const out_len = try escapedFts5QuoteLen(token.len, quotes);
    var out = try allocator.alloc(u8, out_len);
    var pos: usize = 0;
    for (token) |ch| {
        if (ch == '"') {
            out[pos] = '"';
            pos += 1;
        }
        out[pos] = ch;
        pos += 1;
    }
    return out;
}

fn escapedFts5QuoteLen(token_len: usize, quote_count: usize) !usize {
    return std.math.add(usize, token_len, quote_count) catch return error.OutOfMemory;
}

fn toLower(allocator: Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < text.len) {
        const ch = text[i];
        if (ch < 0x80) {
            try out.append(allocator, if (ch >= 'A' and ch <= 'Z') ch + 32 else ch);
            i += 1;
            continue;
        }
        const cp_len = std.unicode.utf8ByteSequenceLength(ch) catch {
            try out.append(allocator, ch);
            i += 1;
            continue;
        };
        if (i + cp_len > text.len) {
            try out.appendSlice(allocator, text[i..]);
            break;
        }
        const cp = std.unicode.utf8Decode(text[i..][0..cp_len]) catch {
            try out.appendSlice(allocator, text[i..][0..cp_len]);
            i += cp_len;
            continue;
        };
        try appendUtf8Codepoint(allocator, &out, lowercaseCodepoint(cp));
        i += cp_len;
    }
    return out.toOwnedSlice(allocator);
}

fn lowercaseCodepoint(cp: u21) u21 {
    if (cp >= 0x0410 and cp <= 0x042F) return cp + 0x20;
    if (cp == 0x0401) return 0x0451;
    return cp;
}

fn appendUtf8Codepoint(allocator: Allocator, out: *std.ArrayListUnmanaged(u8), cp: u21) !void {
    if (cp <= 0x7F) {
        try out.append(allocator, @intCast(cp));
    } else if (cp <= 0x7FF) {
        try out.append(allocator, @intCast(0xC0 | (cp >> 6)));
        try out.append(allocator, @intCast(0x80 | (cp & 0x3F)));
    } else if (cp <= 0xFFFF) {
        try out.append(allocator, @intCast(0xE0 | (cp >> 12)));
        try out.append(allocator, @intCast(0x80 | ((cp >> 6) & 0x3F)));
        try out.append(allocator, @intCast(0x80 | (cp & 0x3F)));
    } else {
        try out.append(allocator, @intCast(0xF0 | (cp >> 18)));
        try out.append(allocator, @intCast(0x80 | ((cp >> 12) & 0x3F)));
        try out.append(allocator, @intCast(0x80 | ((cp >> 6) & 0x3F)));
        try out.append(allocator, @intCast(0x80 | (cp & 0x3F)));
    }
}

fn stripAsciiPunctuation(text: []const u8) []const u8 {
    var start: usize = 0;
    var end = text.len;
    while (start < end and isAsciiPunct(text[start])) start += 1;
    while (end > start and isAsciiPunct(text[end - 1])) end -= 1;
    return text[start..end];
}

fn isAsciiPunct(ch: u8) bool {
    return switch (ch) {
        '!', '"', '#', '$', '%', '&', '\'', '(', ')', '*', '+', ',', '-', '.', '/', ':', ';', '<', '=', '>', '?', '@', '[', '\\', ']', '^', '_', '`', '{', '|', '}', '~' => true,
        else => false,
    };
}

fn isAsciiAlnum(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
    }
    return true;
}

fn isPureAsciiAlpha(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |ch| {
        if (!std.ascii.isAlphabetic(ch)) return false;
    }
    return true;
}

fn isPureNumeric(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |ch| {
        if (!std.ascii.isDigit(ch)) return false;
    }
    return true;
}

fn isPurePunctuation(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |ch| {
        if (!isAsciiPunct(ch)) return false;
    }
    return true;
}

fn utf8CodepointCount(text: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const cp_len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            i += 1;
            continue;
        };
        if (i + cp_len > text.len) break;
        count += 1;
        i += cp_len;
    }
    return count;
}

fn containsAny(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (std.mem.indexOf(u8, haystack, needle) != null) return true;
    }
    return false;
}

fn freeOwnedTokens(tokens: []const []const u8, allocator: Allocator) void {
    for (tokens) |token| allocator.free(token);
}

fn expectContains(tokens: []const []const u8, needle: []const u8) !void {
    for (tokens) |token| {
        if (std.mem.eql(u8, token, needle)) return;
    }
    return error.ExpectedTokenMissing;
}

fn expectNotContains(tokens: []const []const u8, needle: []const u8) !void {
    for (tokens) |token| {
        if (std.mem.eql(u8, token, needle)) return error.UnexpectedTokenFound;
    }
}

test "query expansion returns nullclaw compatible structured english result" {
    var expanded = try expandQuery(std.testing.allocator, "what is the best way to learn Zig");
    defer expanded.deinit(std.testing.allocator);

    try std.testing.expectEqual(Language.en, expanded.language);
    try std.testing.expect(expanded.original_tokens.len >= 7);
    try expectContains(expanded.filtered_tokens, "best");
    try expectContains(expanded.filtered_tokens, "way");
    try expectContains(expanded.filtered_tokens, "learn");
    try expectContains(expanded.filtered_tokens, "zig");
    try expectNotContains(expanded.filtered_tokens, "what");
    try expectNotContains(expanded.filtered_tokens, "the");
    try std.testing.expect(std.mem.indexOf(u8, expanded.fts5_query, "zig*") != null);
}

test "query expansion escapes fts5 quotes with checked allocation sizing" {
    const escaped = try escapeFts5Quotes(std.testing.allocator, "alpha\"beta\"");
    defer std.testing.allocator.free(escaped);
    try std.testing.expectEqualStrings("alpha\"\"beta\"\"", escaped);

    try std.testing.expectEqual(@as(usize, 12), try escapedFts5QuoteLen(10, 2));
    try std.testing.expectError(error.OutOfMemory, escapedFts5QuoteLen(std.math.maxInt(usize), 1));
}

test "query expansion filters Russian question stopwords" {
    var expanded = try expandQuery(std.testing.allocator, "Почему мы решили делать NullPantry как отдельный продукт");
    defer expanded.deinit(std.testing.allocator);

    try std.testing.expectEqual(Language.ru, expanded.language);
    try expectContains(expanded.filtered_tokens, "решили");
    try expectContains(expanded.filtered_tokens, "nullpantry");
    try expectContains(expanded.filtered_tokens, "отдельный");
    try expectContains(expanded.filtered_tokens, "продукт");
    try expectNotContains(expanded.filtered_tokens, "почему");
    try expectNotContains(expanded.filtered_tokens, "мы");
    try expectNotContains(expanded.filtered_tokens, "делать");
    try expectNotContains(expanded.filtered_tokens, "как");
}

test "query expansion handles empty and all-stopword fallbacks" {
    var empty = try expandQuery(std.testing.allocator, "   ");
    defer empty.deinit(std.testing.allocator);
    try std.testing.expectEqual(Language.unknown, empty.language);
    try std.testing.expectEqualStrings("", empty.fts5_query);
    try std.testing.expectEqual(@as(usize, 0), empty.filtered_tokens.len);

    var stopwords = try expandQuery(std.testing.allocator, "the a an is are");
    defer stopwords.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), stopwords.filtered_tokens.len);
    try std.testing.expectEqualStrings("the a an is are", stopwords.fts5_query);
}

test "query expansion detects cjk korean japanese and arabic" {
    var zh = try expandQuery(std.testing.allocator, "\xe8\xae\xa8\xe8\xae\xba\xe6\x95\xb0\xe6\x8d\xae\xe5\xba\x93");
    defer zh.deinit(std.testing.allocator);
    try std.testing.expectEqual(Language.zh, zh.language);
    try expectContains(zh.filtered_tokens, "\xe8\xae\xa8\xe8\xae\xba");

    var ko = try expandQuery(std.testing.allocator, "\xec\x84\x9c\xeb\xb2\x84\xeb\x8a\x94 \xec\x97\x90\xeb\x9f\xac\xeb\xa5\xbc \xed\x99\x95\xec\x9d\xb8");
    defer ko.deinit(std.testing.allocator);
    try std.testing.expectEqual(Language.ko, ko.language);
    try expectContains(ko.filtered_tokens, "\xec\x84\x9c\xeb\xb2\x84");
    try expectContains(ko.filtered_tokens, "\xec\x97\x90\xeb\x9f\xac");

    var ja = try expandQuery(std.testing.allocator, "\xe3\x82\xb5\xe3\x83\xbc\xe3\x83\x90\xe3\x83\xbc\xe9\x9a\x9c\xe5\xae\xb3");
    defer ja.deinit(std.testing.allocator);
    try std.testing.expectEqual(Language.ja, ja.language);
    try std.testing.expect(ja.filtered_tokens.len > 0);

    var ar = try expandQuery(std.testing.allocator, "\xd9\x83\xd9\x8a\xd9\x81 \xd8\xaa\xd8\xb9\xd9\x85\xd9\x84 \xd9\x82\xd8\xa7\xd8\xb9\xd8\xaf\xd8\xa9 \xd8\xa7\xd9\x84\xd8\xa8\xd9\x8a\xd8\xa7\xd9\x86\xd8\xa7\xd8\xaa");
    defer ar.deinit(std.testing.allocator);
    try std.testing.expectEqual(Language.ar, ar.language);
    try std.testing.expect(ar.filtered_tokens.len > 0);
}

test "query expansion extracts owned keywords" {
    const keywords = try extractKeywords(std.testing.allocator, "best way to learn Zig");
    defer {
        for (keywords) |keyword| std.testing.allocator.free(keyword);
        std.testing.allocator.free(keywords);
    }

    try expectContains(keywords, "best");
    try expectContains(keywords, "zig");
}
