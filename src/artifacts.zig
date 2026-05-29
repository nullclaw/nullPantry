const std = @import("std");
const json = @import("json_util.zig");

pub const ArtifactTypeDescriptor = struct {
    name: []const u8,
    alias: ?[]const u8 = null,
    statuses: []const []const u8,
    required_fields: []const []const u8 = &.{},
};

const page_statuses = [_][]const u8{ "draft", "verified", "stale", "deprecated", "superseded" };
const spec_statuses = [_][]const u8{ "draft", "review", "accepted", "deprecated", "superseded" };
const decision_statuses = [_][]const u8{ "proposed", "accepted", "rejected", "deprecated", "superseded" };
const runbook_statuses = [_][]const u8{ "draft", "verified", "stale", "deprecated" };

const spec_fields = [_][]const u8{ "problem", "goals", "non_goals", "users", "use_cases", "requirements", "risks", "dependencies", "success_metrics" };
const decision_fields = [_][]const u8{ "context", "decision", "alternatives", "consequences", "owner", "review_date" };
const runbook_fields = [_][]const u8{ "purpose", "prerequisites", "steps", "rollback", "owners", "verification" };
const meeting_fields = [_][]const u8{ "summary", "topics", "decisions", "action_items", "open_questions", "risks", "mentioned_entities" };
const research_fields = [_][]const u8{ "question", "sources", "findings", "assumptions", "conclusion", "confidence", "unresolved_questions" };
const incident_fields = [_][]const u8{ "timeline", "affected_systems", "symptoms", "root_cause", "mitigation", "follow_ups", "lessons_learned" };
const memory_item_fields = [_][]const u8{ "content", "source", "confidence", "owner", "expires_at", "tags" };

pub const artifact_types = [_]ArtifactTypeDescriptor{
    .{ .name = "page", .statuses = &page_statuses },
    .{ .name = "spec", .statuses = &spec_statuses, .required_fields = &spec_fields },
    .{ .name = "decision", .statuses = &decision_statuses, .required_fields = &decision_fields },
    .{ .name = "runbook", .alias = "recipe", .statuses = &runbook_statuses, .required_fields = &runbook_fields },
    .{ .name = "meeting_note", .statuses = &page_statuses, .required_fields = &meeting_fields },
    .{ .name = "research", .statuses = &page_statuses, .required_fields = &research_fields },
    .{ .name = "incident_report", .statuses = &page_statuses, .required_fields = &incident_fields },
    .{ .name = "memory_item", .statuses = &page_statuses, .required_fields = &memory_item_fields },
};

pub fn validStatus(artifact_type: []const u8, status: []const u8) bool {
    const descriptor = descriptorFor(artifact_type) orelse return status.len > 0;
    return oneOf(status, descriptor.statuses);
}

pub fn appendRequiredFieldsJson(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), artifact_type: []const u8) !void {
    const descriptor = descriptorFor(artifact_type) orelse {
        try out.appendSlice(allocator, "[]");
        return;
    };
    try appendStringArrayJson(allocator, out, descriptor.required_fields);
}

pub fn appendTypesJson(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    try out.append(allocator, '[');
    for (artifact_types, 0..) |descriptor, i| {
        if (i > 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, "{\"type\":");
        try json.appendString(out, allocator, descriptor.name);
        if (descriptor.alias) |alias| {
            try out.appendSlice(allocator, ",\"alias\":");
            try json.appendString(out, allocator, alias);
        }
        try out.appendSlice(allocator, ",\"statuses\":");
        try appendStringArrayJson(allocator, out, descriptor.statuses);
        try out.appendSlice(allocator, ",\"required_fields\":");
        try appendStringArrayJson(allocator, out, descriptor.required_fields);
        try out.append(allocator, '}');
    }
    try out.append(allocator, ']');
}

fn descriptorFor(artifact_type: []const u8) ?ArtifactTypeDescriptor {
    for (artifact_types) |descriptor| {
        if (std.mem.eql(u8, artifact_type, descriptor.name)) return descriptor;
        if (descriptor.alias) |alias| {
            if (std.mem.eql(u8, artifact_type, alias)) return descriptor;
        }
    }
    return null;
}

fn appendStringArrayJson(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), values: []const []const u8) !void {
    try out.append(allocator, '[');
    for (values, 0..) |value, i| {
        if (i > 0) try out.append(allocator, ',');
        try json.appendString(out, allocator, value);
    }
    try out.append(allocator, ']');
}

fn oneOf(value: []const u8, values: []const []const u8) bool {
    for (values) |candidate| {
        if (std.mem.eql(u8, value, candidate)) return true;
    }
    return false;
}

test "artifact type status validation covers first-class types" {
    try std.testing.expect(validStatus("decision", "accepted"));
    try std.testing.expect(!validStatus("decision", "verified"));
    try std.testing.expect(validStatus("runbook", "verified"));
    try std.testing.expect(validStatus("recipe", "verified"));
    try std.testing.expect(validStatus("memory_item", "stale"));

    var fields: std.ArrayListUnmanaged(u8) = .empty;
    defer fields.deinit(std.testing.allocator);
    try appendRequiredFieldsJson(std.testing.allocator, &fields, "incident_report");
    try std.testing.expect(std.mem.indexOf(u8, fields.items, "root_cause") != null);
    fields.clearRetainingCapacity();
    try appendRequiredFieldsJson(std.testing.allocator, &fields, "memory_item");
    try std.testing.expect(std.mem.indexOf(u8, fields.items, "expires_at") != null);
}

test "artifact types json is generated from descriptor registry" {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try appendTypesJson(std.testing.allocator, &out);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"type\":\"decision\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"alias\":\"recipe\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"type\":\"memory_item\"") != null);
}
