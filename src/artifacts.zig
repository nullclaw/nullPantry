const std = @import("std");

pub fn validStatus(artifact_type: []const u8, status: []const u8) bool {
    if (std.mem.eql(u8, artifact_type, "decision")) {
        return oneOf(status, &.{ "proposed", "accepted", "rejected", "deprecated", "superseded" });
    }
    if (std.mem.eql(u8, artifact_type, "spec")) {
        return oneOf(status, &.{ "draft", "review", "accepted", "deprecated", "superseded" });
    }
    if (std.mem.eql(u8, artifact_type, "runbook") or std.mem.eql(u8, artifact_type, "recipe")) {
        return oneOf(status, &.{ "draft", "verified", "stale", "deprecated" });
    }
    if (std.mem.eql(u8, artifact_type, "meeting_note") or std.mem.eql(u8, artifact_type, "research") or std.mem.eql(u8, artifact_type, "incident_report") or std.mem.eql(u8, artifact_type, "memory_item") or std.mem.eql(u8, artifact_type, "page")) {
        return oneOf(status, &.{ "draft", "verified", "stale", "deprecated", "superseded" });
    }
    return status.len > 0;
}

pub fn requiredFieldsJson(artifact_type: []const u8) []const u8 {
    if (std.mem.eql(u8, artifact_type, "spec")) return "[\"problem\",\"goals\",\"non_goals\",\"users\",\"use_cases\",\"requirements\",\"risks\",\"dependencies\",\"success_metrics\"]";
    if (std.mem.eql(u8, artifact_type, "decision")) return "[\"context\",\"decision\",\"alternatives\",\"consequences\",\"owner\",\"review_date\"]";
    if (std.mem.eql(u8, artifact_type, "runbook") or std.mem.eql(u8, artifact_type, "recipe")) return "[\"purpose\",\"prerequisites\",\"steps\",\"rollback\",\"owners\",\"verification\"]";
    if (std.mem.eql(u8, artifact_type, "meeting_note")) return "[\"summary\",\"topics\",\"decisions\",\"action_items\",\"open_questions\",\"risks\",\"mentioned_entities\"]";
    if (std.mem.eql(u8, artifact_type, "research")) return "[\"question\",\"sources\",\"findings\",\"assumptions\",\"conclusion\",\"confidence\",\"unresolved_questions\"]";
    if (std.mem.eql(u8, artifact_type, "incident_report")) return "[\"timeline\",\"affected_systems\",\"symptoms\",\"root_cause\",\"mitigation\",\"follow_ups\",\"lessons_learned\"]";
    if (std.mem.eql(u8, artifact_type, "memory_item")) return "[\"content\",\"source\",\"confidence\",\"owner\",\"expires_at\",\"tags\"]";
    return "[]";
}

pub fn appendTypesJson(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    try out.appendSlice(allocator,
        \\[{"type":"page","statuses":["draft","verified","stale","deprecated","superseded"],"required_fields":[]},{"type":"spec","statuses":["draft","review","accepted","deprecated","superseded"],"required_fields":["problem","goals","non_goals","users","use_cases","requirements","risks","dependencies","success_metrics"]},{"type":"decision","statuses":["proposed","accepted","rejected","deprecated","superseded"],"required_fields":["context","decision","alternatives","consequences","owner","review_date"]},{"type":"runbook","alias":"recipe","statuses":["draft","verified","stale","deprecated"],"required_fields":["purpose","prerequisites","steps","rollback","owners","verification"]},{"type":"meeting_note","statuses":["draft","verified","stale","deprecated","superseded"],"required_fields":["summary","topics","decisions","action_items","open_questions","risks","mentioned_entities"]},{"type":"research","statuses":["draft","verified","stale","deprecated","superseded"],"required_fields":["question","sources","findings","assumptions","conclusion","confidence","unresolved_questions"]},{"type":"incident_report","statuses":["draft","verified","stale","deprecated","superseded"],"required_fields":["timeline","affected_systems","symptoms","root_cause","mitigation","follow_ups","lessons_learned"]},{"type":"memory_item","statuses":["draft","verified","stale","deprecated","superseded"],"required_fields":["content","source","confidence","owner","expires_at","tags"]}]
    );
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
    try std.testing.expect(validStatus("memory_item", "stale"));
    try std.testing.expect(std.mem.indexOf(u8, requiredFieldsJson("incident_report"), "root_cause") != null);
    try std.testing.expect(std.mem.indexOf(u8, requiredFieldsJson("memory_item"), "expires_at") != null);
}
