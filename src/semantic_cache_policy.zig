const std = @import("std");
const bounded_int = @import("bounded_int.zig");

pub const default_candidate_limit: usize = 10_000;
pub const max_candidate_limit: usize = 100_000;

pub fn requestCandidateLimit(raw: ?i64) usize {
    const value = raw orelse return default_candidate_limit;
    if (value <= 1) return 1;
    return bounded_int.positiveI64ToUsizeBounded(value, max_candidate_limit);
}

pub fn storeCandidateLimit(limit: usize) i64 {
    const bounded = if (limit == 0) default_candidate_limit else @min(limit, max_candidate_limit);
    return bounded_int.usizeToI64Saturating(@max(bounded, @as(usize, 1)));
}

test "semantic cache policy bounds request candidate limits" {
    try std.testing.expectEqual(default_candidate_limit, requestCandidateLimit(null));
    try std.testing.expectEqual(@as(usize, 1), requestCandidateLimit(-10));
    try std.testing.expectEqual(@as(usize, 1), requestCandidateLimit(0));
    try std.testing.expectEqual(@as(usize, 1), requestCandidateLimit(1));
    try std.testing.expectEqual(@as(usize, 42), requestCandidateLimit(42));
    try std.testing.expectEqual(max_candidate_limit, requestCandidateLimit(std.math.maxInt(i64)));
}

test "semantic cache policy bounds store candidate limits" {
    try std.testing.expectEqual(@as(i64, default_candidate_limit), storeCandidateLimit(0));
    try std.testing.expectEqual(@as(i64, 1), storeCandidateLimit(1));
    try std.testing.expectEqual(@as(i64, 42), storeCandidateLimit(42));
    try std.testing.expectEqual(@as(i64, max_candidate_limit), storeCandidateLimit(max_candidate_limit + 1));
}
