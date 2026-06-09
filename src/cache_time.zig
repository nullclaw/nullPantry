const std = @import("std");
const time_math = @import("time_math.zig");

pub fn expiresAtMs(now_ms: i64, ttl_ms: i64) i64 {
    if (ttl_ms <= 0) return 0;
    return time_math.saturatingAddMs(now_ms, ttl_ms);
}

pub fn isFresh(created_at_ms: i64, ttl_ms: i64, now_ms: i64) bool {
    if (ttl_ms <= 0) return true;
    return now_ms <= time_math.saturatingAddMs(created_at_ms, ttl_ms);
}

test "cache time expiration is overflow safe" {
    try std.testing.expectEqual(@as(i64, 0), expiresAtMs(100, 0));
    try std.testing.expectEqual(@as(i64, 0), expiresAtMs(100, -1));
    try std.testing.expectEqual(@as(i64, 150), expiresAtMs(100, 50));
    try std.testing.expectEqual(std.math.maxInt(i64), expiresAtMs(std.math.maxInt(i64) - 10, 100));
}

test "cache time freshness saturates overflowing ttl windows" {
    try std.testing.expect(isFresh(100, 0, std.math.maxInt(i64)));
    try std.testing.expect(isFresh(100, 50, 150));
    try std.testing.expect(!isFresh(100, 50, 151));
    try std.testing.expect(isFresh(std.math.maxInt(i64) - 10, 100, std.math.maxInt(i64) - 1));
}
