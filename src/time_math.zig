const std = @import("std");

pub fn saturatingAddMs(base_ms: i64, delta_ms: i64) i64 {
    return std.math.add(i64, base_ms, delta_ms) catch if (delta_ms < 0) std.math.minInt(i64) else std.math.maxInt(i64);
}

pub fn deadlineMs(now_ms: i64, duration_ms: i64) i64 {
    if (duration_ms <= 0) return now_ms;
    return saturatingAddMs(now_ms, duration_ms);
}

pub fn elapsedSinceMs(now_ms: i64, since_ms: i64) i64 {
    if (now_ms <= since_ms) return 0;
    return std.math.sub(i64, now_ms, since_ms) catch std.math.maxInt(i64);
}

pub fn secondsToMs(seconds: u64) i64 {
    const milliseconds = std.math.mul(u64, seconds, std.time.ms_per_s) catch return std.math.maxInt(i64);
    return std.math.cast(i64, milliseconds) orelse std.math.maxInt(i64);
}

test "time math saturates signed millisecond addition" {
    try std.testing.expectEqual(@as(i64, 150), saturatingAddMs(100, 50));
    try std.testing.expectEqual(std.math.maxInt(i64), saturatingAddMs(std.math.maxInt(i64) - 10, 100));
    try std.testing.expectEqual(std.math.minInt(i64), saturatingAddMs(std.math.minInt(i64) + 10, -100));
}

test "time math computes bounded deadlines and elapsed windows" {
    try std.testing.expectEqual(@as(i64, 100), deadlineMs(100, 0));
    try std.testing.expectEqual(@as(i64, 100), deadlineMs(100, -1));
    try std.testing.expectEqual(@as(i64, 150), deadlineMs(100, 50));
    try std.testing.expectEqual(std.math.maxInt(i64), deadlineMs(std.math.maxInt(i64) - 10, 100));

    try std.testing.expectEqual(@as(i64, 0), elapsedSinceMs(100, 150));
    try std.testing.expectEqual(@as(i64, 50), elapsedSinceMs(150, 100));
    try std.testing.expectEqual(std.math.maxInt(i64), elapsedSinceMs(std.math.maxInt(i64), std.math.minInt(i64)));
}

test "time math converts seconds to bounded milliseconds" {
    try std.testing.expectEqual(@as(i64, 0), secondsToMs(0));
    try std.testing.expectEqual(@as(i64, 7_000), secondsToMs(7));

    const max_whole_seconds: u64 = @intCast(@divTrunc(std.math.maxInt(i64), std.time.ms_per_s));
    try std.testing.expectEqual(@as(i64, @intCast(max_whole_seconds * std.time.ms_per_s)), secondsToMs(max_whole_seconds));
    try std.testing.expectEqual(std.math.maxInt(i64), secondsToMs(max_whole_seconds + 1));
    try std.testing.expectEqual(std.math.maxInt(i64), secondsToMs(std.math.maxInt(u64)));
}
