const std = @import("std");
const bounded_int = @import("bounded_int.zig");

pub const max_timeout_secs: u32 = 3600;
pub const max_response_bytes: usize = 64 * 1024 * 1024;

pub fn boundedTimeoutSecs(value: ?i64, fallback: u32) u32 {
    if (value) |raw| {
        return @max(@as(u32, 1), bounded_int.positiveI64ToU32Bounded(raw, max_timeout_secs));
    }
    return @max(@as(u32, 1), @min(fallback, max_timeout_secs));
}

pub fn boundedResponseBytes(value: ?i64, fallback: usize) usize {
    if (value) |raw| {
        return @max(@as(usize, 1), bounded_int.positiveI64ToUsizeBounded(raw, max_response_bytes));
    }
    return @max(@as(usize, 1), @min(fallback, max_response_bytes));
}

pub fn validTimeoutSecs(value: u32) bool {
    return value > 0 and value <= max_timeout_secs;
}

pub fn validResponseBytes(value: usize) bool {
    return value > 0 and value <= max_response_bytes;
}

test "runtime timeout limits clamp to usable values" {
    try std.testing.expectEqual(@as(u32, 1), boundedTimeoutSecs(-1, 30));
    try std.testing.expectEqual(@as(u32, 1), boundedTimeoutSecs(0, 30));
    try std.testing.expectEqual(@as(u32, 42), boundedTimeoutSecs(42, 30));
    try std.testing.expectEqual(max_timeout_secs, boundedTimeoutSecs(std.math.maxInt(i64), 30));
    try std.testing.expectEqual(max_timeout_secs, boundedTimeoutSecs(null, max_timeout_secs + 1));

    try std.testing.expect(validTimeoutSecs(1));
    try std.testing.expect(validTimeoutSecs(max_timeout_secs));
    try std.testing.expect(!validTimeoutSecs(0));
    try std.testing.expect(!validTimeoutSecs(max_timeout_secs + 1));
}

test "runtime response limits clamp to usable values" {
    try std.testing.expectEqual(@as(usize, 1), boundedResponseBytes(-1, 4096));
    try std.testing.expectEqual(@as(usize, 1), boundedResponseBytes(0, 4096));
    try std.testing.expectEqual(@as(usize, 4096), boundedResponseBytes(4096, 8192));
    try std.testing.expectEqual(max_response_bytes, boundedResponseBytes(std.math.maxInt(i64), 8192));
    try std.testing.expectEqual(max_response_bytes, boundedResponseBytes(null, max_response_bytes + 1));

    try std.testing.expect(validResponseBytes(1));
    try std.testing.expect(validResponseBytes(max_response_bytes));
    try std.testing.expect(!validResponseBytes(0));
    try std.testing.expect(!validResponseBytes(max_response_bytes + 1));
}
