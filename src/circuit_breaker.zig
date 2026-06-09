const std = @import("std");
const bounded_int = @import("bounded_int.zig");
const ids = @import("ids.zig");
const time_math = @import("time_math.zig");

pub const max_failure_threshold: u32 = 1_000;
pub const max_cooldown_ms: i64 = 60 * 60 * 1000;

pub fn boundedFailureThreshold(value: ?i64, fallback: u32) u32 {
    if (value) |raw| {
        return @max(@as(u32, 1), bounded_int.positiveI64ToU32Bounded(raw, max_failure_threshold));
    }
    return @max(@as(u32, 1), @min(fallback, max_failure_threshold));
}

pub fn boundedCooldownMs(value: ?i64, fallback: i64) i64 {
    if (value) |raw| return @max(@as(i64, 1), @min(raw, max_cooldown_ms));
    return @max(@as(i64, 1), @min(fallback, max_cooldown_ms));
}

pub fn boundedCooldownMsU64(value: ?i64, fallback: u64) u64 {
    return @intCast(boundedCooldownMs(value, bounded_int.u64ToI64Saturating(fallback)));
}

pub fn validFailureThreshold(value: u32) bool {
    return value > 0 and value <= max_failure_threshold;
}

pub fn validCooldownMs(value: i64) bool {
    return value > 0 and value <= max_cooldown_ms;
}

pub fn validCooldownMsU64(value: u64) bool {
    return value > 0 and value <= @as(u64, @intCast(max_cooldown_ms));
}

pub const State = enum {
    closed,
    open,
    half_open,

    pub fn name(self: State) []const u8 {
        return @tagName(self);
    }
};

pub const Options = struct {
    enabled: bool = true,
    failure_threshold: u32 = 3,
    cooldown_ms: i64 = 30_000,
};

pub const Runtime = struct {
    enabled: bool = true,
    state: State = .closed,
    failure_count: u32 = 0,
    failure_threshold: u32 = 3,
    cooldown_ms: i64 = 30_000,
    last_failure_ms: i64 = 0,
    half_open_probe_sent: bool = false,
    attempts: u64 = 0,
    successes: u64 = 0,
    failures: u64 = 0,
    skipped: u64 = 0,

    pub fn init(options: Options) Runtime {
        return .{
            .enabled = options.enabled,
            .failure_threshold = boundedFailureThreshold(null, options.failure_threshold),
            .cooldown_ms = boundedCooldownMs(null, options.cooldown_ms),
        };
    }

    pub fn allow(self: *Runtime) bool {
        return self.allowAt(ids.nowMs());
    }

    pub fn allowAt(self: *Runtime, now_ms: i64) bool {
        if (!self.enabled) return true;
        switch (self.state) {
            .closed => {
                self.attempts += 1;
                return true;
            },
            .open => {
                if (self.cooldown_ms <= 0 or time_math.elapsedSinceMs(now_ms, self.last_failure_ms) >= self.cooldown_ms) {
                    self.state = .half_open;
                    self.half_open_probe_sent = true;
                    self.attempts += 1;
                    return true;
                }
                self.skipped += 1;
                return false;
            },
            .half_open => {
                if (!self.half_open_probe_sent) {
                    self.half_open_probe_sent = true;
                    self.attempts += 1;
                    return true;
                }
                self.skipped += 1;
                return false;
            },
        }
    }

    pub fn recordSuccess(self: *Runtime) void {
        if (!self.enabled) return;
        self.state = .closed;
        self.failure_count = 0;
        self.half_open_probe_sent = false;
        self.successes += 1;
    }

    pub fn recordFailure(self: *Runtime) void {
        self.recordFailureAt(ids.nowMs());
    }

    pub fn recordFailureAt(self: *Runtime, now_ms: i64) void {
        if (!self.enabled) return;
        self.failure_count +|= 1;
        self.failures += 1;
        self.last_failure_ms = now_ms;
        if (self.state == .half_open or self.failure_count >= self.failure_threshold) {
            self.state = .open;
            self.half_open_probe_sent = false;
        }
    }
};

test "circuit breaker opens and recovers through one half-open probe" {
    var breaker = Runtime.init(.{ .failure_threshold = 2, .cooldown_ms = 10 });
    try std.testing.expect(breaker.allowAt(100));
    breaker.recordFailureAt(101);
    try std.testing.expectEqual(State.closed, breaker.state);
    breaker.recordFailureAt(102);
    try std.testing.expectEqual(State.open, breaker.state);
    try std.testing.expect(!breaker.allowAt(105));
    try std.testing.expectEqual(@as(u64, 1), breaker.skipped);
    try std.testing.expect(breaker.allowAt(112));
    try std.testing.expectEqual(State.half_open, breaker.state);
    try std.testing.expect(!breaker.allowAt(113));
    breaker.recordSuccess();
    try std.testing.expectEqual(State.closed, breaker.state);
    try std.testing.expectEqual(@as(u32, 0), breaker.failure_count);
    try std.testing.expectEqual(@as(u64, 2), breaker.attempts);
    try std.testing.expectEqual(@as(u64, 1), breaker.successes);
    try std.testing.expectEqual(@as(u64, 2), breaker.failures);
}

test "circuit breaker options are bounded to usable values" {
    try std.testing.expectEqual(@as(u32, 1), boundedFailureThreshold(-1, 3));
    try std.testing.expectEqual(@as(u32, 1), boundedFailureThreshold(0, 3));
    try std.testing.expectEqual(@as(u32, 42), boundedFailureThreshold(42, 3));
    try std.testing.expectEqual(max_failure_threshold, boundedFailureThreshold(std.math.maxInt(i64), 3));
    try std.testing.expectEqual(max_failure_threshold, boundedFailureThreshold(null, max_failure_threshold + 1));

    try std.testing.expectEqual(@as(i64, 1), boundedCooldownMs(-1, 30_000));
    try std.testing.expectEqual(@as(i64, 1), boundedCooldownMs(0, 30_000));
    try std.testing.expectEqual(@as(i64, 42), boundedCooldownMs(42, 30_000));
    try std.testing.expectEqual(max_cooldown_ms, boundedCooldownMs(std.math.maxInt(i64), 30_000));
    try std.testing.expectEqual(max_cooldown_ms, boundedCooldownMs(null, max_cooldown_ms + 1));

    const normalized = Runtime.init(.{ .failure_threshold = 0, .cooldown_ms = -1 });
    try std.testing.expectEqual(@as(u32, 1), normalized.failure_threshold);
    try std.testing.expectEqual(@as(i64, 1), normalized.cooldown_ms);
}

test "circuit breaker cooldown elapsed time is overflow safe" {
    var min_failure = Runtime.init(.{ .failure_threshold = 1, .cooldown_ms = std.math.maxInt(i64) - 1 });
    min_failure.recordFailureAt(std.math.minInt(i64));
    try std.testing.expectEqual(State.open, min_failure.state);
    try std.testing.expect(min_failure.allowAt(std.math.maxInt(i64)));
    try std.testing.expectEqual(State.half_open, min_failure.state);

    var future_failure = Runtime.init(.{ .failure_threshold = 1, .cooldown_ms = 10 });
    future_failure.recordFailureAt(100);
    try std.testing.expectEqual(State.open, future_failure.state);
    try std.testing.expect(!future_failure.allowAt(50));
    try std.testing.expectEqual(State.open, future_failure.state);
}

test "circuit breaker disabled is transparent and does not collect runtime stats" {
    var breaker = Runtime.init(.{ .enabled = false, .failure_threshold = 1, .cooldown_ms = 10 });
    try std.testing.expect(breaker.allowAt(100));
    breaker.recordFailureAt(101);
    try std.testing.expectEqual(State.closed, breaker.state);
    try std.testing.expectEqual(@as(u64, 0), breaker.attempts);
    try std.testing.expectEqual(@as(u64, 0), breaker.failures);
}
