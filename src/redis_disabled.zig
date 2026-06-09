const std = @import("std");
const redis_config = @import("redis_config.zig");

pub const is_compiled = false;

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

pub fn formatCommand(allocator: std.mem.Allocator, args: []const []const u8) ![]u8 {
    _ = allocator;
    _ = args;
    return error.EngineNotCompiled;
}

pub fn parseResp(allocator: std.mem.Allocator, data: []const u8) !struct { value: RespValue, consumed: usize } {
    _ = allocator;
    _ = data;
    return error.EngineNotCompiled;
}

pub const Client = struct {
    allocator: std.mem.Allocator,
    config: Config,

    pub fn init(allocator: std.mem.Allocator, config: Config) Client {
        return .{ .allocator = allocator, .config = config };
    }

    pub fn deinit(self: *Client) void {
        _ = self;
    }

    pub fn command(self: *Client, args: []const []const u8) !RespValue {
        _ = self;
        _ = args;
        return error.EngineNotCompiled;
    }
};

test "disabled redis transport preserves RESP value helpers" {
    var resp = RespValue{ .bulk_string = try std.testing.allocator.dupe(u8, "ok") };
    defer resp.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("ok", resp.asString().?);
}
