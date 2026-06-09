const std = @import("std");

pub fn nonNegativeI64ToUsize(value: i64) usize {
    if (value <= 0) return 0;
    const max_usize_as_i64: i64 = if (@bitSizeOf(usize) >= @bitSizeOf(i64)) std.math.maxInt(i64) else @intCast(std.math.maxInt(usize));
    return @intCast(@min(value, max_usize_as_i64));
}

pub fn nonNegativeI64ToU64(value: i64) u64 {
    if (value <= 0) return 0;
    return @intCast(value);
}

pub fn nonNegativeI64ToU32(value: i64) u32 {
    if (value <= 0) return 0;
    return @intCast(@min(value, @as(i64, std.math.maxInt(u32))));
}

pub fn positiveI64ToUsizeBounded(value: i64, max_value: usize) usize {
    if (value <= 0 or max_value == 0) return 0;
    return @intCast(@min(value, usizeToI64Saturating(max_value)));
}

pub fn positiveI64ToU32Bounded(value: i64, max_value: u32) u32 {
    if (value <= 0 or max_value == 0) return 0;
    return @intCast(@min(value, @as(i64, @intCast(max_value))));
}

pub fn nonNegativeCIntToUsize(value: c_int) usize {
    return nonNegativeI64ToUsize(@intCast(value));
}

pub fn usizeToU64Saturating(value: usize) u64 {
    return std.math.cast(u64, value) orelse std.math.maxInt(u64);
}

pub fn u64ToUsizeSaturating(value: u64) usize {
    return std.math.cast(usize, value) orelse std.math.maxInt(usize);
}

pub fn u64ToI64Saturating(value: u64) i64 {
    return std.math.cast(i64, value) orelse std.math.maxInt(i64);
}

pub fn usizeToI64Saturating(value: usize) i64 {
    return std.math.cast(i64, value) orelse std.math.maxInt(i64);
}

pub fn saturatingUsizeAdd(left: usize, right: usize) usize {
    return std.math.add(usize, left, right) catch std.math.maxInt(usize);
}

pub fn saturatingUsizeMul(left: usize, right: usize) usize {
    return std.math.mul(usize, left, right) catch std.math.maxInt(usize);
}

pub fn saturatingU64Add(left: u64, right: u64) u64 {
    return std.math.add(u64, left, right) catch std.math.maxInt(u64);
}

pub fn saturatingUsizeSum(values: []const usize) usize {
    var total: usize = 0;
    for (values) |value| total = saturatingUsizeAdd(total, value);
    return total;
}

test "non-negative signed integer counters clamp to unsigned sizes" {
    try std.testing.expectEqual(@as(usize, 0), nonNegativeI64ToUsize(-1));
    try std.testing.expectEqual(@as(usize, 0), nonNegativeI64ToUsize(0));
    try std.testing.expectEqual(@as(usize, 9), nonNegativeI64ToUsize(9));

    const expected_max: usize = if (@bitSizeOf(usize) >= @bitSizeOf(i64)) @intCast(std.math.maxInt(i64)) else std.math.maxInt(usize);
    try std.testing.expectEqual(expected_max, nonNegativeI64ToUsize(std.math.maxInt(i64)));
}

test "non-negative signed integer counters clamp to u64" {
    try std.testing.expectEqual(@as(u64, 0), nonNegativeI64ToU64(-1));
    try std.testing.expectEqual(@as(u64, 0), nonNegativeI64ToU64(0));
    try std.testing.expectEqual(@as(u64, 9), nonNegativeI64ToU64(9));
    try std.testing.expectEqual(@as(u64, @intCast(std.math.maxInt(i64))), nonNegativeI64ToU64(std.math.maxInt(i64)));
}

test "non-negative signed integer counters clamp to u32" {
    try std.testing.expectEqual(@as(u32, 0), nonNegativeI64ToU32(-1));
    try std.testing.expectEqual(@as(u32, 0), nonNegativeI64ToU32(0));
    try std.testing.expectEqual(@as(u32, 9), nonNegativeI64ToU32(9));
    try std.testing.expectEqual(std.math.maxInt(u32), nonNegativeI64ToU32(std.math.maxInt(i64)));
}

test "positive signed integer counters clamp to bounded unsigned sizes" {
    try std.testing.expectEqual(@as(usize, 0), positiveI64ToUsizeBounded(-1, 10));
    try std.testing.expectEqual(@as(usize, 0), positiveI64ToUsizeBounded(0, 10));
    try std.testing.expectEqual(@as(usize, 0), positiveI64ToUsizeBounded(10, 0));
    try std.testing.expectEqual(@as(usize, 9), positiveI64ToUsizeBounded(9, 100));
    try std.testing.expectEqual(@as(usize, 7), positiveI64ToUsizeBounded(100, 7));
    try std.testing.expectEqual(nonNegativeI64ToUsize(std.math.maxInt(i64)), positiveI64ToUsizeBounded(std.math.maxInt(i64), std.math.maxInt(usize)));
}

test "positive signed integer counters clamp to bounded u32 values" {
    try std.testing.expectEqual(@as(u32, 0), positiveI64ToU32Bounded(-1, 10));
    try std.testing.expectEqual(@as(u32, 0), positiveI64ToU32Bounded(0, 10));
    try std.testing.expectEqual(@as(u32, 0), positiveI64ToU32Bounded(10, 0));
    try std.testing.expectEqual(@as(u32, 9), positiveI64ToU32Bounded(9, 100));
    try std.testing.expectEqual(@as(u32, 7), positiveI64ToU32Bounded(100, 7));
    try std.testing.expectEqual(std.math.maxInt(u32), positiveI64ToU32Bounded(std.math.maxInt(i64), std.math.maxInt(u32)));
}

test "non-negative C integer counters clamp to unsigned sizes" {
    try std.testing.expectEqual(@as(usize, 0), nonNegativeCIntToUsize(@as(c_int, -1)));
    try std.testing.expectEqual(@as(usize, 0), nonNegativeCIntToUsize(@as(c_int, 0)));
    try std.testing.expectEqual(@as(usize, 42), nonNegativeCIntToUsize(@as(c_int, 42)));
}

test "usize to u64 conversion saturates" {
    try std.testing.expectEqual(@as(u64, 0), usizeToU64Saturating(0));
    try std.testing.expectEqual(@as(u64, 42), usizeToU64Saturating(42));

    const expected_max = std.math.cast(u64, std.math.maxInt(usize)) orelse std.math.maxInt(u64);
    try std.testing.expectEqual(expected_max, usizeToU64Saturating(std.math.maxInt(usize)));
}

test "u64 to usize conversion saturates" {
    try std.testing.expectEqual(@as(usize, 0), u64ToUsizeSaturating(0));
    try std.testing.expectEqual(@as(usize, 42), u64ToUsizeSaturating(42));

    const expected_max = std.math.cast(usize, std.math.maxInt(u64)) orelse std.math.maxInt(usize);
    try std.testing.expectEqual(expected_max, u64ToUsizeSaturating(std.math.maxInt(u64)));
}

test "u64 to i64 conversion saturates" {
    try std.testing.expectEqual(@as(i64, 0), u64ToI64Saturating(0));
    try std.testing.expectEqual(@as(i64, 42), u64ToI64Saturating(42));
    try std.testing.expectEqual(std.math.maxInt(i64), u64ToI64Saturating(@as(u64, @intCast(std.math.maxInt(i64)))));
    try std.testing.expectEqual(std.math.maxInt(i64), u64ToI64Saturating(std.math.maxInt(u64)));
}

test "usize to i64 conversion saturates" {
    try std.testing.expectEqual(@as(i64, 0), usizeToI64Saturating(0));
    try std.testing.expectEqual(@as(i64, 42), usizeToI64Saturating(42));

    const expected_max = std.math.cast(i64, std.math.maxInt(usize)) orelse std.math.maxInt(i64);
    try std.testing.expectEqual(expected_max, usizeToI64Saturating(std.math.maxInt(usize)));
}

test "saturating usize arithmetic and sums do not overflow" {
    try std.testing.expectEqual(@as(usize, 7), saturatingUsizeAdd(3, 4));
    try std.testing.expectEqual(std.math.maxInt(usize), saturatingUsizeAdd(std.math.maxInt(usize) - 1, 4));
    try std.testing.expectEqual(@as(usize, 12), saturatingUsizeMul(3, 4));
    try std.testing.expectEqual(std.math.maxInt(usize), saturatingUsizeMul((std.math.maxInt(usize) / 2) + 1, 2));

    try std.testing.expectEqual(@as(usize, 6), saturatingUsizeSum(&.{ 1, 2, 3 }));
    try std.testing.expectEqual(std.math.maxInt(usize), saturatingUsizeSum(&.{ std.math.maxInt(usize), 1 }));
}

test "saturating u64 addition does not overflow" {
    try std.testing.expectEqual(@as(u64, 7), saturatingU64Add(3, 4));
    try std.testing.expectEqual(std.math.maxInt(u64), saturatingU64Add(std.math.maxInt(u64) - 1, 4));
}
