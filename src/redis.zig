const std = @import("std");
const compat = @import("compat.zig");
const net_security = @import("net_security.zig");
const redis_config = @import("redis_config.zig");

const max_response_bytes: usize = 16 * 1024 * 1024;

pub const is_compiled = true;

const RespBulkStringRange = struct {
    start: usize,
    end: usize,
};

pub const RespValue = union(enum) {
    simple_string: []const u8,
    err: []const u8,
    integer: i64,
    bulk_string: ?[]const u8,
    array: ?[]RespValue,

    pub fn deinit(self: *RespValue, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .simple_string => |value| allocator.free(value),
            .err => |value| allocator.free(value),
            .bulk_string => |maybe_value| if (maybe_value) |value| allocator.free(value),
            .array => |maybe_items| if (maybe_items) |items| {
                for (items) |*item| item.deinit(allocator);
                allocator.free(items);
            },
            .integer => {},
        }
    }

    pub fn asString(self: RespValue) ?[]const u8 {
        return switch (self) {
            .simple_string => |value| value,
            .bulk_string => |maybe_value| maybe_value,
            else => null,
        };
    }
};

pub const Config = redis_config.Config;
pub const parseUrl = redis_config.parseUrl;

fn responseByteLimitExceeded(current_len: usize, incoming_len: usize) bool {
    return net_security.exceedsByteLimit(current_len, incoming_len, max_response_bytes);
}

pub fn formatCommand(allocator: std.mem.Allocator, args: []const []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.print(allocator, "*{d}\r\n", .{args.len});
    for (args) |arg| {
        try out.print(allocator, "${d}\r\n", .{arg.len});
        try out.appendSlice(allocator, arg);
        try out.appendSlice(allocator, "\r\n");
    }
    return out.toOwnedSlice(allocator);
}

pub fn parseResp(allocator: std.mem.Allocator, data: []const u8) !struct { value: RespValue, consumed: usize } {
    if (data.len == 0) return error.IncompleteData;
    const rest = data[1..];
    switch (data[0]) {
        '+' => {
            const end = std.mem.indexOf(u8, rest, "\r\n") orelse return error.IncompleteData;
            return .{ .value = .{ .simple_string = try allocator.dupe(u8, rest[0..end]) }, .consumed = 1 + end + 2 };
        },
        '-' => {
            const end = std.mem.indexOf(u8, rest, "\r\n") orelse return error.IncompleteData;
            return .{ .value = .{ .err = try allocator.dupe(u8, rest[0..end]) }, .consumed = 1 + end + 2 };
        },
        ':' => {
            const end = std.mem.indexOf(u8, rest, "\r\n") orelse return error.IncompleteData;
            return .{ .value = .{ .integer = try std.fmt.parseInt(i64, rest[0..end], 10) }, .consumed = 1 + end + 2 };
        },
        '$' => {
            const end = std.mem.indexOf(u8, rest, "\r\n") orelse return error.IncompleteData;
            const len = try std.fmt.parseInt(i64, rest[0..end], 10);
            if (len < 0) return .{ .value = .{ .bulk_string = null }, .consumed = 1 + end + 2 };
            const value_len = std.math.cast(usize, len) orelse return error.IncompleteData;
            const range = try respBulkStringRange(rest.len, end, value_len);
            if (rest[range.end] != '\r' or rest[range.end + 1] != '\n') return error.InvalidResp;
            return .{
                .value = .{ .bulk_string = try allocator.dupe(u8, rest[range.start..range.end]) },
                .consumed = 1 + range.end + 2,
            };
        },
        '*' => {
            const end = std.mem.indexOf(u8, rest, "\r\n") orelse return error.IncompleteData;
            const count = try std.fmt.parseInt(i64, rest[0..end], 10);
            if (count < 0) return .{ .value = .{ .array = null }, .consumed = 1 + end + 2 };
            const item_count = std.math.cast(usize, count) orelse return error.IncompleteData;
            if (item_count > data.len) return error.IncompleteData;
            var items = try allocator.alloc(RespValue, item_count);
            var initialized: usize = 0;
            errdefer {
                for (items[0..initialized]) |*item| item.deinit(allocator);
                allocator.free(items);
            }
            var consumed: usize = 1 + end + 2;
            while (initialized < item_count) : (initialized += 1) {
                const child = try parseResp(allocator, data[consumed..]);
                items[initialized] = child.value;
                consumed += child.consumed;
            }
            return .{ .value = .{ .array = items }, .consumed = consumed };
        },
        else => return error.UnknownRespType,
    }
}

fn respBulkStringRange(rest_len: usize, header_end: usize, value_len: usize) !RespBulkStringRange {
    const start = std.math.add(usize, header_end, 2) catch return error.IncompleteData;
    if (start > rest_len) return error.IncompleteData;
    const end = std.math.add(usize, start, value_len) catch return error.IncompleteData;
    if (end > rest_len or rest_len - end < 2) return error.IncompleteData;
    return .{ .start = start, .end = end };
}

pub const Client = struct {
    allocator: std.mem.Allocator,
    config: Config,
    stream: ?std.Io.net.Stream = null,

    pub fn init(allocator: std.mem.Allocator, config: Config) Client {
        return .{ .allocator = allocator, .config = config };
    }

    pub fn deinit(self: *Client) void {
        if (self.stream) |*stream| {
            stream.close(compat.io());
            self.stream = null;
        }
    }

    fn ensureConnected(self: *Client) !void {
        if (self.stream != null) return;
        const address = try std.Io.net.IpAddress.resolve(compat.io(), self.config.host, self.config.port);
        self.stream = try address.connect(compat.io(), .{ .mode = .stream });
        if (self.config.password) |password| {
            var auth = try self.commandConnected(&.{ "AUTH", password });
            defer auth.deinit(self.allocator);
            switch (auth) {
                .err => return error.RedisAuthFailed,
                else => {},
            }
        }
        if (self.config.db_index != 0) {
            var db_buf: [4]u8 = undefined;
            const db = try std.fmt.bufPrint(&db_buf, "{d}", .{self.config.db_index});
            var select = try self.commandConnected(&.{ "SELECT", db });
            defer select.deinit(self.allocator);
            switch (select) {
                .err => return error.RedisSelectFailed,
                else => {},
            }
        }
    }

    pub fn command(self: *Client, args: []const []const u8) !RespValue {
        try self.ensureConnected();
        return self.commandConnected(args);
    }

    fn commandConnected(self: *Client, args: []const []const u8) !RespValue {
        const stream = self.stream orelse return error.RedisNotConnected;
        const encoded = try formatCommand(self.allocator, args);
        defer self.allocator.free(encoded);
        var write_buffer: [4096]u8 = undefined;
        var writer = stream.writer(compat.io(), &write_buffer);
        writer.interface.writeAll(encoded) catch |err| {
            self.closeAfterIoError();
            return err;
        };
        writer.interface.flush() catch |err| {
            self.closeAfterIoError();
            return err;
        };
        return self.readResponse();
    }

    fn readResponse(self: *Client) !RespValue {
        const stream = self.stream orelse return error.RedisNotConnected;
        var data: std.ArrayListUnmanaged(u8) = .empty;
        defer data.deinit(self.allocator);
        var read_buffer: [4096]u8 = undefined;
        var reader = stream.reader(compat.io(), &read_buffer);
        while (true) {
            const byte = reader.interface.takeByte() catch |err| {
                self.closeAfterIoError();
                return err;
            };
            if (responseByteLimitExceeded(data.items.len, 1)) return error.RedisResponseTooLarge;
            try data.append(self.allocator, byte);
            const parsed = parseResp(self.allocator, data.items) catch |err| switch (err) {
                error.IncompleteData => continue,
                else => return err,
            };
            return parsed.value;
        }
    }

    fn closeAfterIoError(self: *Client) void {
        if (self.stream) |*stream| stream.close(compat.io());
        self.stream = null;
    }
};

test "redis formats RESP commands" {
    const encoded = try formatCommand(std.testing.allocator, &.{ "HSET", "k", "field", "value" });
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("*4\r\n$4\r\nHSET\r\n$1\r\nk\r\n$5\r\nfield\r\n$5\r\nvalue\r\n", encoded);
}

test "redis parses nested RESP arrays" {
    var parsed = try parseResp(std.testing.allocator, "*2\r\n$3\r\nfoo\r\n:42\r\n");
    defer parsed.value.deinit(std.testing.allocator);
    const items = parsed.value.array.?;
    try std.testing.expectEqualStrings("foo", items[0].asString().?);
    try std.testing.expectEqual(@as(i64, 42), items[1].integer);
}

test "redis parses empty bulk strings" {
    var parsed = try parseResp(std.testing.allocator, "$0\r\n\r\n");
    defer parsed.value.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("", parsed.value.asString().?);
    try std.testing.expectEqual(@as(usize, 6), parsed.consumed);
}

test "redis parser rejects oversized lengths without trapping or allocating" {
    try std.testing.expectError(error.IncompleteData, parseResp(std.testing.allocator, "$9223372036854775807\r\nx\r\n"));
    try std.testing.expectError(error.IncompleteData, parseResp(std.testing.allocator, "*9223372036854775807\r\n"));
    try std.testing.expectError(error.InvalidResp, parseResp(std.testing.allocator, "$3\r\nfooXX"));
}

test "redis bulk string range checks boundary arithmetic" {
    const ok = try respBulkStringRange(8, 1, 3);
    try std.testing.expectEqual(@as(usize, 3), ok.start);
    try std.testing.expectEqual(@as(usize, 6), ok.end);

    try std.testing.expectError(error.IncompleteData, respBulkStringRange(6, 1, 3));
    try std.testing.expectError(error.IncompleteData, respBulkStringRange(8, std.math.maxInt(usize), 0));
    try std.testing.expectError(error.IncompleteData, respBulkStringRange(8, 1, std.math.maxInt(usize)));
}

test "redis response byte limit check is overflow-safe" {
    try std.testing.expect(!responseByteLimitExceeded(max_response_bytes - 1, 1));
    try std.testing.expect(responseByteLimitExceeded(max_response_bytes, 1));
    try std.testing.expect(responseByteLimitExceeded(std.math.maxInt(usize), 1));
}

test "redis parses url with password and db" {
    const cfg = try parseUrl(std.testing.allocator, "redis://:secret@redis.local:6380/7");
    defer {
        std.testing.allocator.free(cfg.host);
        std.testing.allocator.free(cfg.password.?);
    }
    try std.testing.expectEqualStrings("redis.local", cfg.host);
    try std.testing.expectEqual(@as(u16, 6380), cfg.port);
    try std.testing.expectEqualStrings("secret", cfg.password.?);
    try std.testing.expectEqual(@as(u8, 7), cfg.db_index);
}
