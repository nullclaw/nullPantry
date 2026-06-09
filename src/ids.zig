const std = @import("std");
const compat = @import("compat.zig");

pub fn nowMs() i64 {
    const ts = std.Io.Clock.real.now(compat.io());
    return timestampNanosecondsToMs(ts.nanoseconds);
}

pub fn make(allocator: std.mem.Allocator, prefix: []const u8) ![]u8 {
    var random_bytes: [12]u8 = undefined;
    std.Io.random(compat.io(), &random_bytes);

    const hex = std.fmt.bytesToHex(random_bytes, .lower);
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, hex[0..] });
}

pub fn timestampIso(allocator: std.mem.Allocator, ms: i64) ![]u8 {
    return std.fmt.allocPrint(allocator, "{d}", .{ms});
}

pub fn timestampNanosecondsToMs(nanoseconds: i96) i64 {
    const milliseconds = @divTrunc(nanoseconds, std.time.ns_per_ms);
    if (milliseconds > std.math.maxInt(i64)) return std.math.maxInt(i64);
    if (milliseconds < std.math.minInt(i64)) return std.math.minInt(i64);
    return @intCast(milliseconds);
}

test "ids use requested prefix" {
    const id = try make(std.testing.allocator, "mem_");
    defer std.testing.allocator.free(id);
    try std.testing.expect(std.mem.startsWith(u8, id, "mem_"));
    try std.testing.expect(id.len > "mem_".len);
}

test "ids timestamp nanoseconds conversion saturates to millisecond bounds" {
    try std.testing.expectEqual(@as(i64, 42), timestampNanosecondsToMs(42 * std.time.ns_per_ms));
    try std.testing.expectEqual(@as(i64, -42), timestampNanosecondsToMs(-42 * std.time.ns_per_ms));

    const max_i64_ms: i96 = @intCast(std.math.maxInt(i64));
    try std.testing.expectEqual(std.math.maxInt(i64), timestampNanosecondsToMs((max_i64_ms + 1) * std.time.ns_per_ms));

    const min_i64_ms: i96 = @intCast(std.math.minInt(i64));
    try std.testing.expectEqual(std.math.minInt(i64), timestampNanosecondsToMs((min_i64_ms - 1) * std.time.ns_per_ms));
}
