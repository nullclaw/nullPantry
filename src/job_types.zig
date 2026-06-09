const std = @import("std");

pub const Class = enum {
    summarize,
    ingest,
    hygiene,
    scan_conflicts,
    lucid_projection,
    graph_projection,
    agent_memory_mirror,
    vector_outbox,
    memory_drain_outbox,
    memory_reindex,
    vector_rebuild,
    vector_reconcile,
};

pub fn classify(job_type: []const u8) ?Class {
    if (isSummarize(job_type)) return .summarize;
    if (isIngest(job_type)) return .ingest;
    if (isHygiene(job_type)) return .hygiene;
    if (isScanConflicts(job_type)) return .scan_conflicts;
    if (isLucidProjection(job_type)) return .lucid_projection;
    if (isGraphProjection(job_type)) return .graph_projection;
    if (isAgentMemoryMirror(job_type)) return .agent_memory_mirror;
    if (isVectorOutbox(job_type)) return .vector_outbox;
    if (isMemoryDrainOutbox(job_type)) return .memory_drain_outbox;
    if (isMemoryReindex(job_type)) return .memory_reindex;
    if (isVectorRebuild(job_type)) return .vector_rebuild;
    if (isVectorReconcile(job_type)) return .vector_reconcile;
    return null;
}

pub fn isSupported(job_type: []const u8) bool {
    return classify(job_type) != null;
}

pub fn isSummarize(job_type: []const u8) bool {
    return eql(job_type, "summarize") or
        eql(job_type, "summarize_session") or
        eql(job_type, "session_summarize");
}

pub fn isIngest(job_type: []const u8) bool {
    return eql(job_type, "ingest") or
        eql(job_type, "ingest_source") or
        eql(job_type, "extract_memory");
}

pub fn isHygiene(job_type: []const u8) bool {
    return eql(job_type, "hygiene");
}

pub fn isScanConflicts(job_type: []const u8) bool {
    return eql(job_type, "scan_conflicts") or
        eql(job_type, "conflict_scan");
}

pub fn isLucidProjection(job_type: []const u8) bool {
    return eql(job_type, "lucid_projection");
}

pub fn isGraphProjection(job_type: []const u8) bool {
    return eql(job_type, "graph_projection") or
        eql(job_type, "external_graph_projection");
}

pub fn isAgentMemoryMirror(job_type: []const u8) bool {
    return eql(job_type, "agent_memory_mirror") or
        eql(job_type, "mirror_agent_memory") or
        eql(job_type, "primitive_memory_mirror");
}

pub fn isVectorMaintenance(job_type: []const u8) bool {
    return isVectorOutbox(job_type) or
        isMemoryDrainOutbox(job_type) or
        isMemoryReindex(job_type) or
        isVectorRebuild(job_type) or
        isVectorReconcile(job_type);
}

pub fn isVectorOutbox(job_type: []const u8) bool {
    return eql(job_type, "vector_outbox") or
        eql(job_type, "vector_outbox_run") or
        eql(job_type, "run_vector_outbox");
}

pub fn isMemoryDrainOutbox(job_type: []const u8) bool {
    return eql(job_type, "memory_drain_outbox") or
        eql(job_type, "drain_outbox") or
        eql(job_type, "agent_memory_drain_outbox");
}

pub fn isMemoryReindex(job_type: []const u8) bool {
    return eql(job_type, "memory_reindex") or
        eql(job_type, "agent_memory_reindex") or
        eql(job_type, "reindex");
}

pub fn isVectorRebuild(job_type: []const u8) bool {
    return eql(job_type, "vector_rebuild") or
        eql(job_type, "rebuild_vector") or
        eql(job_type, "rebuild_vector_index");
}

pub fn isVectorReconcile(job_type: []const u8) bool {
    return eql(job_type, "vector_reconcile") or
        eql(job_type, "reconcile_vector") or
        eql(job_type, "reconcile_vector_index");
}

fn eql(actual: []const u8, expected: []const u8) bool {
    return std.mem.eql(u8, actual, expected);
}

test "job type aliases classify to stable classes" {
    try std.testing.expectEqual(Class.summarize, classify("summarize_session").?);
    try std.testing.expectEqual(Class.ingest, classify("extract_memory").?);
    try std.testing.expectEqual(Class.scan_conflicts, classify("conflict_scan").?);
    try std.testing.expectEqual(Class.graph_projection, classify("external_graph_projection").?);
    try std.testing.expectEqual(Class.agent_memory_mirror, classify("mirror_agent_memory").?);
    try std.testing.expectEqual(Class.vector_outbox, classify("run_vector_outbox").?);
    try std.testing.expectEqual(Class.memory_drain_outbox, classify("agent_memory_drain_outbox").?);
    try std.testing.expectEqual(Class.memory_reindex, classify("reindex").?);
    try std.testing.expectEqual(Class.vector_rebuild, classify("rebuild_vector_index").?);
    try std.testing.expectEqual(Class.vector_reconcile, classify("reconcile_vector_index").?);
}

test "job type support and vector maintenance are derived from stable job classes" {
    try std.testing.expect(isSupported("hygiene"));
    try std.testing.expect(isSupported("lucid_projection"));
    try std.testing.expect(isSupported("graph_projection"));
    try std.testing.expect(isSupported("agent_memory_mirror"));
    try std.testing.expect(isVectorMaintenance("memory_reindex"));
    try std.testing.expect(isVectorMaintenance("vector_reconcile"));
    try std.testing.expect(!isVectorMaintenance("summarize"));
    try std.testing.expect(!isSupported("unknown_job"));
    try std.testing.expect(classify("unknown_job") == null);
}
