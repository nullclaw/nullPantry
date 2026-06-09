const std = @import("std");

pub fn wellFormed(raw: []const u8) bool {
    var it = Iterator.init(raw);
    while (it.next() != null) {}
    return !it.invalid;
}

pub fn itemsNonBlank(raw: []const u8) bool {
    if (!wellFormed(raw)) return false;
    var it = Iterator.init(raw);
    while (it.next()) |item| {
        if (literalBlank(item)) return false;
    }
    return !it.invalid;
}

pub fn literalWellFormed(encoded: []const u8) bool {
    var reader = ByteReader.init(encoded);
    while (reader.next() != null) {}
    return !reader.failed;
}

fn literalBlank(encoded: []const u8) bool {
    var reader = ByteReader.init(encoded);
    while (reader.next()) |byte| {
        if (!std.ascii.isWhitespace(byte)) return false;
    }
    return !reader.failed;
}

pub const Iterator = struct {
    input: []const u8,
    index: usize = 0,
    first: bool = true,
    done: bool = false,
    invalid: bool = false,

    pub fn init(raw: []const u8) Iterator {
        return .{ .input = std.mem.trim(u8, raw, " \t\r\n") };
    }

    pub fn next(self: *Iterator) ?[]const u8 {
        if (self.done or self.invalid) return null;
        if (self.index == 0) {
            self.skipWhitespace();
            if (!self.consume('[')) return self.fail();
            self.skipWhitespace();
            if (self.consume(']')) return self.finishEmpty();
        } else if (!self.first) {
            self.skipWhitespace();
            if (self.consume(']')) return self.finishEmpty();
            if (!self.consume(',')) return self.fail();
            self.skipWhitespace();
            if (self.peek(']')) return self.fail();
        }

        if (!self.consume('"')) return self.fail();
        const start = self.index;
        while (self.index < self.input.len) : (self.index += 1) {
            if (self.input[self.index] == '\\') {
                self.index += 1;
                if (self.index >= self.input.len) return self.fail();
                continue;
            }
            if (self.input[self.index] == '"') {
                const value = self.input[start..self.index];
                self.index += 1;
                if (!literalWellFormed(value)) return self.fail();
                self.skipWhitespace();
                if (!self.peek(']') and !self.peek(',')) return self.fail();
                self.first = false;
                return value;
            }
        }
        return self.fail();
    }

    fn consume(self: *Iterator, ch: u8) bool {
        if (self.index < self.input.len and self.input[self.index] == ch) {
            self.index += 1;
            return true;
        }
        return false;
    }

    fn peek(self: Iterator, ch: u8) bool {
        return self.index < self.input.len and self.input[self.index] == ch;
    }

    fn skipWhitespace(self: *Iterator) void {
        while (self.index < self.input.len) : (self.index += 1) {
            switch (self.input[self.index]) {
                ' ', '\t', '\r', '\n' => {},
                else => return,
            }
        }
    }

    fn finishEmpty(self: *Iterator) ?[]const u8 {
        self.skipWhitespace();
        if (self.index != self.input.len) return self.fail();
        self.done = true;
        return null;
    }

    fn fail(self: *Iterator) ?[]const u8 {
        self.invalid = true;
        return null;
    }
};

pub const ByteReader = struct {
    encoded: []const u8,
    index: usize = 0,
    pending: [4]u8 = undefined,
    pending_index: usize = 0,
    pending_len: usize = 0,
    failed: bool = false,

    pub fn init(encoded: []const u8) ByteReader {
        return .{ .encoded = encoded };
    }

    pub fn next(self: *ByteReader) ?u8 {
        if (self.pending_index < self.pending_len) {
            const byte = self.pending[self.pending_index];
            self.pending_index += 1;
            return byte;
        }
        self.pending_index = 0;
        self.pending_len = 0;

        if (self.index >= self.encoded.len) return null;
        if (self.encoded[self.index] != '\\') {
            const byte = self.encoded[self.index];
            self.index += 1;
            return byte;
        }

        self.index += 1;
        if (self.index >= self.encoded.len) return self.fail();
        const escaped = self.encoded[self.index];
        self.index += 1;
        switch (escaped) {
            '"', '\\', '/' => return escaped,
            'b' => return 0x08,
            'f' => return 0x0c,
            'n' => return '\n',
            'r' => return '\r',
            't' => return '\t',
            'u' => {
                var codepoint = parseJsonHex4(self.encoded, &self.index) orelse return self.fail();
                if (codepoint >= 0xd800 and codepoint <= 0xdbff) {
                    if (self.index + 6 > self.encoded.len or self.encoded[self.index] != '\\' or self.encoded[self.index + 1] != 'u') return self.fail();
                    self.index += 2;
                    const low = parseJsonHex4(self.encoded, &self.index) orelse return self.fail();
                    if (low < 0xdc00 or low > 0xdfff) return self.fail();
                    codepoint = 0x10000 + ((codepoint - 0xd800) << 10) + (low - 0xdc00);
                } else if (codepoint >= 0xdc00 and codepoint <= 0xdfff) {
                    return self.fail();
                }
                self.pending_len = std.unicode.utf8Encode(@intCast(codepoint), &self.pending) catch return self.fail();
                self.pending_index = 1;
                return self.pending[0];
            },
            else => return self.fail(),
        }
    }

    fn fail(self: *ByteReader) ?u8 {
        self.failed = true;
        return null;
    }
};

fn parseJsonHex4(encoded: []const u8, index: *usize) ?u21 {
    if (index.* + 4 > encoded.len) return null;
    var value: u21 = 0;
    for (encoded[index.* .. index.* + 4]) |ch| {
        const digit: u21 = switch (ch) {
            '0'...'9' => ch - '0',
            'a'...'f' => 10 + ch - 'a',
            'A'...'F' => 10 + ch - 'A',
            else => return null,
        };
        value = value * 16 + digit;
    }
    index.* += 4;
    return value;
}

test "json string array contract accepts well-formed nonblank string arrays" {
    try std.testing.expect(itemsNonBlank("[]"));
    try std.testing.expect(itemsNonBlank("[\"public\",\"team:\\u0041\"]"));
    try std.testing.expect(!itemsNonBlank("\"public\""));
    try std.testing.expect(!itemsNonBlank("[1]"));
    try std.testing.expect(!itemsNonBlank("[\"\"]"));
    try std.testing.expect(!itemsNonBlank("[\"  \"]"));
    try std.testing.expect(!itemsNonBlank("[\"\\u0020\"]"));
    try std.testing.expect(!itemsNonBlank("[\"public\",]"));
}
