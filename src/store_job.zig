const std = @import("std");
const json = @import("json_util.zig");

pub const Input = struct {
    job_type: []const u8,
    scope: []const u8 = "workspace",
    permissions_json: []const u8 = "[]",
    object_type: []const u8 = "",
    object_id: []const u8 = "",
    input_json: []const u8 = "{}",
    actor_id: ?[]const u8 = null,
};

pub const ListInput = struct {
    scopes_json: []const u8 = "[]",
    status: ?[]const u8 = null,
    limit: usize = 100,
    include_expired_running: bool = false,
};

pub fn includesExpiredRunning(input: ListInput) bool {
    const status = input.status orelse return false;
    return input.include_expired_running and std.mem.eql(u8, status, "queued");
}

pub const Job = struct {
    id: []const u8,
    job_type: []const u8,
    status: []const u8,
    scope: []const u8,
    permissions_json: []const u8,
    object_type: []const u8,
    object_id: []const u8,
    input_json: []const u8,
    result_json: []const u8,
    error_text: ?[]const u8,
    attempts: i64,
    locked_until_ms: ?i64 = null,
    worker_id: ?[]const u8 = null,
    created_at_ms: i64,
    updated_at_ms: i64,

    pub fn writeJson(self: Job, allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
        try out.appendSlice(allocator, "{\"id\":");
        try json.appendString(out, allocator, self.id);
        try out.appendSlice(allocator, ",\"type\":");
        try json.appendString(out, allocator, self.job_type);
        try out.appendSlice(allocator, ",\"status\":");
        try json.appendString(out, allocator, self.status);
        try out.appendSlice(allocator, ",\"scope\":");
        try json.appendString(out, allocator, self.scope);
        try out.appendSlice(allocator, ",\"permissions\":");
        try json.appendRawJsonArray(out, allocator, self.permissions_json);
        try out.appendSlice(allocator, ",\"object_type\":");
        try json.appendString(out, allocator, self.object_type);
        try out.appendSlice(allocator, ",\"object_id\":");
        try json.appendString(out, allocator, self.object_id);
        try out.appendSlice(allocator, ",\"input\":{\"redacted\":true},\"input_redacted\":true");
        try out.appendSlice(allocator, ",\"result\":");
        try json.appendRawJsonObject(out, allocator, self.result_json);
        try out.appendSlice(allocator, ",\"error\":");
        try json.appendNullableString(out, allocator, self.error_text);
        try out.print(allocator, ",\"attempts\":{d},\"locked_until_ms\":", .{self.attempts});
        if (self.locked_until_ms) |value| {
            try out.print(allocator, "{d}", .{value});
        } else {
            try out.appendSlice(allocator, "null");
        }
        try out.appendSlice(allocator, ",\"worker_id\":");
        try json.appendNullableString(out, allocator, self.worker_id);
        try out.print(allocator, ",\"created_at_ms\":{d},\"updated_at_ms\":{d}}}", .{ self.created_at_ms, self.updated_at_ms });
    }
};

pub fn freeJob(allocator: std.mem.Allocator, job: *Job) void {
    if (job.id.len > 0) allocator.free(job.id);
    if (job.job_type.len > 0) allocator.free(job.job_type);
    if (job.status.len > 0) allocator.free(job.status);
    if (job.scope.len > 0) allocator.free(job.scope);
    if (job.permissions_json.len > 0) allocator.free(job.permissions_json);
    if (job.object_type.len > 0) allocator.free(job.object_type);
    if (job.object_id.len > 0) allocator.free(job.object_id);
    if (job.input_json.len > 0) allocator.free(job.input_json);
    if (job.result_json.len > 0) allocator.free(job.result_json);
    if (job.error_text) |value| allocator.free(value);
    if (job.worker_id) |value| allocator.free(value);
    job.* = .{
        .id = "",
        .job_type = "",
        .status = "",
        .scope = "",
        .permissions_json = "",
        .object_type = "",
        .object_id = "",
        .input_json = "",
        .result_json = "",
        .error_text = null,
        .attempts = 0,
        .locked_until_ms = null,
        .worker_id = null,
        .created_at_ms = 0,
        .updated_at_ms = 0,
    };
}

pub fn freeJobs(allocator: std.mem.Allocator, jobs: []Job) void {
    for (jobs) |*job| freeJob(allocator, job);
    allocator.free(jobs);
}

test "store job contract writes redacted input json" {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(std.testing.allocator);

    try (Job{
        .id = "job_1",
        .job_type = "ingest",
        .status = "queued",
        .scope = "project:nullpantry",
        .permissions_json = "[\"team:platform\"]",
        .object_type = "source",
        .object_id = "src_1",
        .input_json = "{\"secret\":\"hidden\"}",
        .result_json = "{\"ok\":true}",
        .error_text = null,
        .attempts = 1,
        .locked_until_ms = null,
        .worker_id = null,
        .created_at_ms = 10,
        .updated_at_ms = 11,
    }).writeJson(std.testing.allocator, &out);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.items, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("ingest", parsed.value.object.get("type").?.string);
    try std.testing.expectEqual(true, parsed.value.object.get("input").?.object.get("redacted").?.bool);
    try std.testing.expect(parsed.value.object.get("input").?.object.get("secret") == null);
    try std.testing.expectEqual(true, parsed.value.object.get("input_redacted").?.bool);
}

test "store job contract enforces raw container root types" {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(std.testing.allocator);

    try std.testing.expectError(error.InvalidRawJson, (Job{
        .id = "job_bad_raw",
        .job_type = "ingest",
        .status = "queued",
        .scope = "project:nullpantry",
        .permissions_json = "{\"scope\":\"project:nullpantry\"}",
        .object_type = "source",
        .object_id = "src_1",
        .input_json = "{\"secret\":\"hidden\"}",
        .result_json = "[\"not-object\"]",
        .error_text = null,
        .attempts = 1,
        .created_at_ms = 10,
        .updated_at_ms = 11,
    }).writeJson(std.testing.allocator, &out));
}

test "store job list input detects expired running queue scans" {
    try std.testing.expectEqual(@as(usize, 100), (ListInput{}).limit);
    try std.testing.expect(!includesExpiredRunning(.{}));
    try std.testing.expect(!includesExpiredRunning(.{ .status = "running", .include_expired_running = true }));
    try std.testing.expect(includesExpiredRunning(.{ .status = "queued", .include_expired_running = true }));
}
