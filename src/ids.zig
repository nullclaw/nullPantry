const std = @import("std");
const compat = @import("compat.zig");

pub fn nowMs() i64 {
    const ts = std.Io.Clock.real.now(compat.io());
    return @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_ms));
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

test "ids use requested prefix" {
    const id = try make(std.testing.allocator, "mem_");
    defer std.testing.allocator.free(id);
    try std.testing.expect(std.mem.startsWith(u8, id, "mem_"));
    try std.testing.expect(id.len > "mem_".len);
}
