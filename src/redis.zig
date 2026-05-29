const std = @import("std");
const compat = @import("compat.zig");

const max_response_bytes: usize = 16 * 1024 * 1024;

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

pub const Config = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 6379,
    password: ?[]const u8 = null,
    db_index: u8 = 0,
    key_prefix: []const u8 = "nullpantry",
    ttl_seconds: ?u32 = null,
};

pub fn parseUrl(allocator: std.mem.Allocator, raw_url: []const u8) !Config {
    if (raw_url.len == 0) return Config{};
    if (!std.mem.startsWith(u8, raw_url, "redis://")) return error.InvalidRedisUrl;
    var rest = raw_url["redis://".len..];
    var cfg = Config{};
    var host_allocated = false;
    var password_allocated = false;
    errdefer {
        if (host_allocated) allocator.free(cfg.host);
        if (password_allocated) if (cfg.password) |password| allocator.free(password);
    }

    const slash_index = std.mem.indexOfScalar(u8, rest, '/');
    const authority = if (slash_index) |idx| rest[0..idx] else rest;
    const db_part = if (slash_index) |idx| rest[idx + 1 ..] else "";
    if (db_part.len > 0) cfg.db_index = std.fmt.parseInt(u8, db_part, 10) catch return error.InvalidRedisUrl;

    var host_port = authority;
    if (std.mem.lastIndexOfScalar(u8, authority, '@')) |idx| {
        const auth = authority[0..idx];
        host_port = authority[idx + 1 ..];
        if (std.mem.startsWith(u8, auth, ":")) {
            cfg.password = try allocator.dupe(u8, auth[1..]);
        } else if (std.mem.indexOfScalar(u8, auth, ':')) |colon| {
            cfg.password = try allocator.dupe(u8, auth[colon + 1 ..]);
        } else {
            cfg.password = try allocator.dupe(u8, auth);
        }
        password_allocated = true;
    }

    if (host_port.len == 0) return error.InvalidRedisUrl;
    if (std.mem.lastIndexOfScalar(u8, host_port, ':')) |colon| {
        cfg.host = try allocator.dupe(u8, host_port[0..colon]);
        host_allocated = true;
        cfg.port = std.fmt.parseInt(u16, host_port[colon + 1 ..], 10) catch return error.InvalidRedisUrl;
    } else {
        cfg.host = try allocator.dupe(u8, host_port);
        host_allocated = true;
    }
    return cfg;
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
            const value_len: usize = @intCast(len);
            const start = end + 2;
            if (rest.len < start + value_len + 2) return error.IncompleteData;
            return .{
                .value = .{ .bulk_string = try allocator.dupe(u8, rest[start .. start + value_len]) },
                .consumed = 1 + start + value_len + 2,
            };
        },
        '*' => {
            const end = std.mem.indexOf(u8, rest, "\r\n") orelse return error.IncompleteData;
            const count = try std.fmt.parseInt(i64, rest[0..end], 10);
            if (count < 0) return .{ .value = .{ .array = null }, .consumed = 1 + end + 2 };
            const item_count: usize = @intCast(count);
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
            var chunk: [4096]u8 = undefined;
            const read = reader.interface.readSliceShort(&chunk) catch |err| {
                self.closeAfterIoError();
                return err;
            };
            if (read == 0) {
                self.closeAfterIoError();
                return error.RedisConnectionClosed;
            }
            if (data.items.len + read > max_response_bytes) return error.RedisResponseTooLarge;
            try data.appendSlice(self.allocator, chunk[0..read]);
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
