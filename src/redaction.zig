const std = @import("std");

pub const Config = struct {
    redact_email: bool = true,
    redact_phone: bool = true,
    redact_card: bool = true,
    redact_id: bool = true,
    redact_tokens: bool = true,
};

pub const Redactor = struct {
    allocator: std.mem.Allocator,
    config: Config,
    emails: std.StringHashMap(u32),
    phones: std.StringHashMap(u32),
    cards: std.StringHashMap(u32),
    ids: std.StringHashMap(u32),
    tokens: std.StringHashMap(u32),
    email_count: u32 = 0,
    phone_count: u32 = 0,
    card_count: u32 = 0,
    id_count: u32 = 0,
    token_count: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, config: Config) Redactor {
        return .{
            .allocator = allocator,
            .config = config,
            .emails = std.StringHashMap(u32).init(allocator),
            .phones = std.StringHashMap(u32).init(allocator),
            .cards = std.StringHashMap(u32).init(allocator),
            .ids = std.StringHashMap(u32).init(allocator),
            .tokens = std.StringHashMap(u32).init(allocator),
        };
    }

    pub fn deinit(self: *Redactor) void {
        freeMapKeys(self.allocator, &self.emails);
        freeMapKeys(self.allocator, &self.phones);
        freeMapKeys(self.allocator, &self.cards);
        freeMapKeys(self.allocator, &self.ids);
        freeMapKeys(self.allocator, &self.tokens);
        self.emails.deinit();
        self.phones.deinit();
        self.cards.deinit();
        self.ids.deinit();
        self.tokens.deinit();
    }

    pub fn redact(self: *Redactor, dest_allocator: std.mem.Allocator, text: []const u8) ![]u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(dest_allocator);

        var i: usize = 0;
        while (i < text.len) {
            if (self.config.redact_tokens) {
                if (matchKeyValueSecret(text, i)) |m| {
                    try out.appendSlice(dest_allocator, text[i..m.value_start]);
                    const id = try self.intern(&self.tokens, &self.token_count, text[m.value_start..m.value_end]);
                    try appendPlaceholder(dest_allocator, &out, "TOKEN", id);
                    i = m.value_end;
                    continue;
                }
                if (matchBearerToken(text, i)) |m| {
                    try out.appendSlice(dest_allocator, text[i .. i + m.prefix_len]);
                    const id = try self.intern(&self.tokens, &self.token_count, text[i + m.prefix_len .. m.end]);
                    try appendPlaceholder(dest_allocator, &out, "TOKEN", id);
                    i = m.end;
                    continue;
                }
                if (matchPrefixToken(text, i)) |m| {
                    const id = try self.intern(&self.tokens, &self.token_count, text[i..m.end]);
                    try appendPlaceholder(dest_allocator, &out, "TOKEN", id);
                    i = m.end;
                    continue;
                }
            }

            if (self.config.redact_email) {
                if (matchEmail(text, i)) |m| {
                    const id = try self.intern(&self.emails, &self.email_count, text[m.start..m.end]);
                    try appendPlaceholder(dest_allocator, &out, "EMAIL", id);
                    i = m.end;
                    continue;
                }
            }

            if (self.config.redact_card) {
                if (matchCard(text, i)) |m| {
                    const id = try self.intern(&self.cards, &self.card_count, text[m.start..m.end]);
                    try appendPlaceholder(dest_allocator, &out, "CARD", id);
                    i = m.end;
                    continue;
                }
            }

            if (self.config.redact_phone) {
                if (matchPhone(text, i)) |m| {
                    const id = try self.intern(&self.phones, &self.phone_count, text[m.start..m.end]);
                    try appendPlaceholder(dest_allocator, &out, "PHONE", id);
                    i = m.end;
                    continue;
                }
            }

            if (self.config.redact_id) {
                if (matchAnchoredId(text, i)) |m| {
                    try out.appendSlice(dest_allocator, text[i..m.value_start]);
                    const id = try self.intern(&self.ids, &self.id_count, text[m.value_start..m.value_end]);
                    try appendPlaceholder(dest_allocator, &out, "ID", id);
                    i = m.value_end;
                    continue;
                }
            }

            try out.append(dest_allocator, text[i]);
            i += 1;
        }

        return out.toOwnedSlice(dest_allocator);
    }

    fn intern(self: *Redactor, map: *std.StringHashMap(u32), counter: *u32, value: []const u8) !u32 {
        if (map.get(value)) |existing| return existing;
        const key = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(key);
        counter.* += 1;
        try map.put(key, counter.*);
        return counter.*;
    }
};

pub fn redactForEmbedding(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return redactForModelBoundary(allocator, text);
}

pub fn redactForModelBoundary(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var redactor = Redactor.init(allocator, .{});
    defer redactor.deinit();
    return redactor.redact(allocator, text);
}

fn freeMapKeys(allocator: std.mem.Allocator, map: *std.StringHashMap(u32)) void {
    var it = map.keyIterator();
    while (it.next()) |key| allocator.free(key.*);
}

fn appendPlaceholder(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), kind: []const u8, id: u32) !void {
    try out.print(allocator, "[{s}_{d}]", .{ kind, id });
}

const Match = struct {
    start: usize,
    end: usize,
};

const ValueMatch = struct {
    value_start: usize,
    value_end: usize,
};

const TokenMatch = struct {
    prefix_len: usize,
    end: usize,
};

fn matchKeyValueSecret(input: []const u8, i: usize) ?ValueMatch {
    if (!hasLeftBoundary(input, i)) return null;
    const prefixes = [_][]const u8{
        "api_key=",
        "apikey=",
        "access_token=",
        "refresh_token=",
        "client_secret=",
        "password=",
        "secret=",
        "token=",
    };
    for (prefixes) |prefix| {
        if (startsWithIgnoreCase(input[i..], prefix)) {
            const value_start = i + prefix.len;
            const value_end = scanSecretValueEnd(input, value_start);
            if (value_end > value_start) return .{ .value_start = value_start, .value_end = value_end };
        }
    }
    return null;
}

fn matchBearerToken(input: []const u8, i: usize) ?TokenMatch {
    if (!hasLeftBoundary(input, i)) return null;
    const prefix = "bearer ";
    if (!startsWithIgnoreCase(input[i..], prefix)) return null;
    const value_start = i + prefix.len;
    const end = scanSecretValueEnd(input, value_start);
    if (end <= value_start) return null;
    return .{ .prefix_len = prefix.len, .end = end };
}

fn matchPrefixToken(input: []const u8, i: usize) ?Match {
    if (!hasLeftBoundary(input, i)) return null;
    const prefixes = [_][]const u8{ "sk-", "ghp_", "github_pat_", "xoxb-", "xoxp-", "pat_" };
    for (prefixes) |prefix| {
        if (startsWithIgnoreCase(input[i..], prefix)) {
            const end = scanSecretValueEnd(input, i);
            if (end > i + prefix.len) return .{ .start = i, .end = end };
        }
    }
    return null;
}

fn matchEmail(input: []const u8, i: usize) ?Match {
    if (!hasLeftBoundary(input, i) or i >= input.len or !isEmailChar(input[i])) return null;
    var end = i;
    while (end < input.len and isEmailChar(input[end])) : (end += 1) {}
    while (end > i and isTrailingPunctuation(input[end - 1])) : (end -= 1) {}
    const token = input[i..end];
    const at = std.mem.indexOfScalar(u8, token, '@') orelse return null;
    if (at == 0 or at + 1 >= token.len) return null;
    if (std.mem.indexOfScalar(u8, token[at + 1 ..], '.') == null) return null;
    return .{ .start = i, .end = end };
}

fn matchPhone(input: []const u8, i: usize) ?Match {
    if (!hasLeftBoundary(input, i)) return null;
    if (i >= input.len or input[i] != '+') return null;
    var end = i + 1;
    var digits: usize = 0;
    while (end < input.len and (std.ascii.isDigit(input[end]) or input[end] == ' ' or input[end] == '-' or input[end] == '(' or input[end] == ')')) : (end += 1) {
        if (std.ascii.isDigit(input[end])) digits += 1;
    }
    if (digits < 8) return null;
    return .{ .start = i, .end = end };
}

fn matchCard(input: []const u8, i: usize) ?Match {
    if (!hasLeftBoundary(input, i) or i >= input.len or !std.ascii.isDigit(input[i])) return null;
    var end = i;
    var digits_buf: [32]u8 = undefined;
    var digits: usize = 0;
    var separators: usize = 0;
    while (end < input.len and (std.ascii.isDigit(input[end]) or input[end] == ' ' or input[end] == '-')) : (end += 1) {
        if (std.ascii.isDigit(input[end])) {
            if (digits >= digits_buf.len) return null;
            digits_buf[digits] = input[end];
            digits += 1;
        } else {
            separators += 1;
        }
    }
    if (digits < 13 or digits > 19 or separators == 0) return null;
    if (!luhnValid(digits_buf[0..digits])) return null;
    return .{ .start = i, .end = end };
}

fn matchAnchoredId(input: []const u8, i: usize) ?ValueMatch {
    if (!hasLeftBoundary(input, i)) return null;
    const prefixes = [_][]const u8{ "id=", "user_id=", "customer_id=", "passport=", "ssn=" };
    for (prefixes) |prefix| {
        if (startsWithIgnoreCase(input[i..], prefix)) {
            const value_start = i + prefix.len;
            const value_end = scanSecretValueEnd(input, value_start);
            if (value_end > value_start) return .{ .value_start = value_start, .value_end = value_end };
        }
    }
    return null;
}

fn scanSecretValueEnd(input: []const u8, start: usize) usize {
    var end = start;
    while (end < input.len and !isSecretDelimiter(input[end])) : (end += 1) {}
    while (end > start and isTrailingPunctuation(input[end - 1])) : (end -= 1) {}
    return end;
}

fn startsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[0..needle.len], needle);
}

fn hasLeftBoundary(input: []const u8, i: usize) bool {
    if (i == 0) return true;
    const ch = input[i - 1];
    return std.ascii.isWhitespace(ch) or ch == '"' or ch == '\'' or ch == '(' or ch == '[' or ch == '{' or ch == ':' or ch == '&' or ch == '?' or ch == '=';
}

fn isEmailChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '@' or ch == '.' or ch == '_' or ch == '%' or ch == '+' or ch == '-';
}

fn isSecretDelimiter(ch: u8) bool {
    return std.ascii.isWhitespace(ch) or ch == '"' or ch == '\'' or ch == '<' or ch == '>' or ch == '&' or ch == ',' or ch == ';';
}

fn isTrailingPunctuation(ch: u8) bool {
    return ch == '.' or ch == ',' or ch == ';' or ch == ':' or ch == ')' or ch == ']' or ch == '}';
}

fn luhnValid(digits: []const u8) bool {
    var sum: u32 = 0;
    var double = false;
    var i = digits.len;
    while (i > 0) {
        i -= 1;
        var n: u32 = digits[i] - '0';
        if (double) {
            n *= 2;
            if (n > 9) n -= 9;
        }
        sum += n;
        double = !double;
    }
    return sum > 0 and sum % 10 == 0;
}

test "redaction replaces embedding-boundary PII and secrets" {
    const allocator = std.testing.allocator;
    const safe = try redactForEmbedding(allocator, "email alice@example.com token=abc123 sk-live-secret +1 (415) 555-1234 card 4242-4242-4242-4242 id=user-42");
    defer allocator.free(safe);

    try std.testing.expect(std.mem.indexOf(u8, safe, "alice@example.com") == null);
    try std.testing.expect(std.mem.indexOf(u8, safe, "abc123") == null);
    try std.testing.expect(std.mem.indexOf(u8, safe, "sk-live-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, safe, "+1 (415) 555-1234") == null);
    try std.testing.expect(std.mem.indexOf(u8, safe, "4242-4242-4242-4242") == null);
    try std.testing.expect(std.mem.indexOf(u8, safe, "user-42") == null);
    try std.testing.expect(std.mem.indexOf(u8, safe, "[EMAIL_1]") != null);
    try std.testing.expect(std.mem.indexOf(u8, safe, "token=[TOKEN_1]") != null);
    try std.testing.expect(std.mem.indexOf(u8, safe, "[TOKEN_2]") != null);
    try std.testing.expect(std.mem.indexOf(u8, safe, "[PHONE_1]") != null);
    try std.testing.expect(std.mem.indexOf(u8, safe, "[CARD_1]") != null);
    try std.testing.expect(std.mem.indexOf(u8, safe, "id=[ID_1]") != null);
}

test "redaction keeps repeated identities stable within one embedding payload" {
    const allocator = std.testing.allocator;
    const safe = try redactForEmbedding(allocator, "owner=a@example.com b@example.com a@example.com token=one token=one");
    defer allocator.free(safe);

    try std.testing.expect(std.mem.indexOf(u8, safe, "owner=[EMAIL_1] [EMAIL_2] [EMAIL_1]") != null);
    try std.testing.expect(std.mem.indexOf(u8, safe, "token=[TOKEN_1] token=[TOKEN_1]") != null);
}
