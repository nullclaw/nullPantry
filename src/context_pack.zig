const std = @import("std");
const domain = @import("domain.zig");
const json = @import("json_util.zig");

pub const forbidden_assumptions_json =
    \\["Do not treat uncited or inaccessible source content as verified context.","Do not use stale, deprecated, rejected, or superseded memory unless explicitly requested.","Do not infer hidden-source details from missing citations or permission-filtered gaps."]
;

pub const suggested_next_steps_json =
    \\["Apply verified decisions before proposed memory.","Review open questions and risks before changing implementation.","Cite source IDs or object IDs when using this context in agent output."]
;

pub fn buildSummary(allocator: std.mem.Allocator, query: []const u8, results: []const domain.SearchResult) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "Context Pack\n\nTask:\n");
    try out.appendSlice(allocator, query);
    try appendSectionText(allocator, &out, "Verified decisions", results, "memory_atom", "decision");
    try appendSectionText(allocator, &out, "Constraints", results, "memory_atom", "constraint");
    try appendSectionText(allocator, &out, "Runbooks", results, "artifact", "runbook");
    try appendSectionText(allocator, &out, "Known risks", results, "memory_atom", "risk");
    try appendSectionText(allocator, &out, "Memory atoms", results, "memory_atom", "");
    try appendSectionText(allocator, &out, "Artifacts", results, "artifact", "");
    try appendSectionText(allocator, &out, "Sources", results, "source", "");
    try appendSectionText(allocator, &out, "Entities", results, "entity", "");
    try appendSectionText(allocator, &out, "Agent memory", results, "agent_memory", "");
    try appendSectionText(allocator, &out, "Spaces", results, "space", "");
    try appendSectionText(allocator, &out, "Policy scopes", results, "policy_scope", "");
    try appendSectionText(allocator, &out, "Graph relations", results, "relation", "");
    try appendSectionText(allocator, &out, "Open questions", results, "memory_atom", "question");
    try appendRecentChanges(allocator, &out, results);
    try appendRelatedObjects(allocator, &out, results);
    try appendStaticBullets(allocator, &out, "Forbidden assumptions", &[_][]const u8{
        "Do not treat uncited or inaccessible source content as verified context.",
        "Do not use stale, deprecated, rejected, or superseded memory unless explicitly requested.",
        "Do not infer hidden-source details from missing citations or permission-filtered gaps.",
    });
    try appendStaticBullets(allocator, &out, "Suggested next steps", &[_][]const u8{
        "Apply verified decisions before proposed memory.",
        "Review open questions and risks before changing implementation.",
        "Cite source IDs or object IDs when using this context in agent output.",
    });
    try appendCitations(allocator, &out, results);
    return out.toOwnedSlice(allocator);
}

pub fn buildSectionsJson(allocator: std.mem.Allocator, results: []const domain.SearchResult) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '{');
    var first = true;
    try appendSectionJson(allocator, &out, &first, "verified_decisions", results, "memory_atom", "decision");
    try appendSectionJson(allocator, &out, &first, "constraints", results, "memory_atom", "constraint");
    try appendSectionJson(allocator, &out, &first, "runbooks", results, "artifact", "runbook");
    try appendSectionJson(allocator, &out, &first, "known_risks", results, "memory_atom", "risk");
    try appendSectionJson(allocator, &out, &first, "memory_atoms", results, "memory_atom", "");
    try appendSectionJson(allocator, &out, &first, "artifacts", results, "artifact", "");
    try appendSectionJson(allocator, &out, &first, "sources", results, "source", "");
    try appendSectionJson(allocator, &out, &first, "entities", results, "entity", "");
    try appendSectionJson(allocator, &out, &first, "agent_memory", results, "agent_memory", "");
    try appendSectionJson(allocator, &out, &first, "relations", results, "relation", "");
    try appendSectionJson(allocator, &out, &first, "open_questions", results, "memory_atom", "question");
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

pub fn requiredScopesJson(allocator: std.mem.Allocator, results: []const domain.SearchResult) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '[');
    var count: usize = 0;
    for (results) |result| {
        var had_explicit_required = false;
        var appended_required = false;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, result.required_scopes_json, .{}) catch null;
        if (parsed) |*required| {
            defer required.deinit();
            if (required.value == .array) {
                had_explicit_required = true;
                for (required.value.array.items) |item| {
                    if (item != .string) continue;
                    if (item.string.len == 0 or std.mem.eql(u8, item.string, "public")) continue;
                    try appendUniqueJsonString(allocator, &out, &count, item.string);
                    appended_required = true;
                }
            }
        }
        if (appended_required or had_explicit_required) continue;
        if (result.scope.len == 0 or std.mem.eql(u8, result.scope, "public")) continue;
        try appendUniqueJsonString(allocator, &out, &count, result.scope);
    }
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

pub fn resultRefsJson(allocator: std.mem.Allocator, results: []const domain.SearchResult) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '[');
    for (results, 0..) |result, i| {
        if (i > 0) try out.append(allocator, ',');
        try out.append(allocator, '{');
        try json.appendString(&out, allocator, "type");
        try out.append(allocator, ':');
        try json.appendString(&out, allocator, result.result_type);
        try out.append(allocator, ',');
        try json.appendString(&out, allocator, "id");
        try out.append(allocator, ':');
        try json.appendString(&out, allocator, result.id);
        try out.append(allocator, ',');
        try json.appendString(&out, allocator, "required_scopes");
        try out.append(allocator, ':');
        try json.appendRawJsonOr(&out, allocator, result.required_scopes_json, "[]");
        try out.append(allocator, ',');
        try json.appendString(&out, allocator, "actor_isolated");
        try out.append(allocator, ':');
        try out.appendSlice(allocator, if (result.actor_isolated) "true" else "false");
        try out.append(allocator, '}');
    }
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

pub fn requiresActorIsolation(results: []const domain.SearchResult) bool {
    for (results) |result| {
        if (result.actor_isolated) return true;
    }
    return false;
}

pub fn sortResults(items: []domain.SearchResult) void {
    var i: usize = 0;
    while (i < items.len) : (i += 1) {
        var best = i;
        var j = i + 1;
        while (j < items.len) : (j += 1) {
            const best_priority = priority(items[best]);
            const candidate_priority = priority(items[j]);
            if (candidate_priority < best_priority or (candidate_priority == best_priority and items[j].score > items[best].score)) {
                best = j;
            }
        }
        if (best != i) std.mem.swap(domain.SearchResult, &items[i], &items[best]);
    }
}

pub fn budgetResults(allocator: std.mem.Allocator, results: []const domain.SearchResult, token_budget: i64) ![]domain.SearchResult {
    const budget_tokens: usize = @intCast(@max(@as(i64, 1), @min(token_budget, @as(i64, 200_000))));
    const max_chars = budget_tokens * 4;
    var used_chars: usize = 0;
    var out: std.ArrayListUnmanaged(domain.SearchResult) = .empty;
    errdefer out.deinit(allocator);
    for (results) |result| {
        const metadata_cost = result.id.len + result.result_type.len + result.title.len + result.scope.len + result.status.len + result.source_ids_json.len + result.required_scopes_json.len + 192;
        const cost = metadata_cost + result.text.len;
        if (used_chars + cost <= max_chars) {
            used_chars += cost;
            try out.append(allocator, result);
            if (used_chars >= max_chars) break;
            continue;
        }

        const remaining = max_chars -| used_chars;
        if (remaining <= metadata_cost + 24) continue;
        var trimmed = result;
        trimmed.text = try trimTextToChars(allocator, result.text, remaining - metadata_cost);
        used_chars += metadata_cost + trimmed.text.len;
        try out.append(allocator, trimmed);
        break;
    }
    return out.toOwnedSlice(allocator);
}

pub fn trimSummaryToBudget(allocator: std.mem.Allocator, summary: []const u8, token_budget: i64) ![]u8 {
    const budget_tokens: usize = @intCast(@max(@as(i64, 1), @min(token_budget, @as(i64, 200_000))));
    const max_chars = @max(@as(usize, 512), budget_tokens * 4);
    if (summary.len <= max_chars) return allocator.dupe(u8, summary);
    const suffix = "\n[truncated to token_budget]\n";
    const keep_len = if (max_chars > suffix.len) max_chars - suffix.len else max_chars;
    var end = keep_len;
    while (end > 0 and (summary[end] & 0b1100_0000) == 0b1000_0000) : (end -= 1) {}
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, summary[0..end]);
    try out.appendSlice(allocator, suffix);
    return out.toOwnedSlice(allocator);
}

fn priority(result: domain.SearchResult) u8 {
    if (std.mem.eql(u8, result.result_type, "memory_atom")) {
        if ((std.mem.eql(u8, result.status, "verified") or std.mem.eql(u8, result.status, "accepted")) and
            (std.ascii.indexOfIgnoreCase(result.title, "decision") != null or std.ascii.indexOfIgnoreCase(result.text, "decision") != null))
        {
            return 0;
        }
        if (std.ascii.indexOfIgnoreCase(result.title, "constraint") != null or std.ascii.indexOfIgnoreCase(result.text, "constraint") != null) return 1;
        if (std.ascii.indexOfIgnoreCase(result.title, "question") != null or std.ascii.indexOfIgnoreCase(result.text, "question") != null) return 6;
        return 2;
    }
    if (std.mem.eql(u8, result.result_type, "artifact")) {
        if (std.ascii.indexOfIgnoreCase(result.title, "runbook") != null or std.ascii.indexOfIgnoreCase(result.title, "recipe") != null) return 3;
        return 4;
    }
    if (std.mem.eql(u8, result.result_type, "relation")) return 5;
    if (std.mem.eql(u8, result.result_type, "agent_memory")) return 6;
    if (std.mem.eql(u8, result.result_type, "source")) return 7;
    return 8;
}

fn trimTextToChars(allocator: std.mem.Allocator, text: []const u8, max_chars: usize) ![]const u8 {
    if (text.len <= max_chars) return allocator.dupe(u8, text);
    const suffix = "\n[truncated to token_budget]\n";
    if (max_chars <= suffix.len) return allocator.dupe(u8, "");
    var end = max_chars - suffix.len;
    while (end > 0 and (text[end] & 0b1100_0000) == 0b1000_0000) : (end -= 1) {}
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, text[0..end]);
    try out.appendSlice(allocator, suffix);
    return out.toOwnedSlice(allocator);
}

fn appendSectionJson(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    first_key: *bool,
    key: []const u8,
    results: []const domain.SearchResult,
    result_type: []const u8,
    contains: []const u8,
) !void {
    if (!first_key.*) try out.append(allocator, ',');
    first_key.* = false;
    try json.appendString(out, allocator, key);
    try out.append(allocator, ':');
    try out.append(allocator, '[');
    var first_item = true;
    for (results) |result| {
        if (!sectionIncludes(result, result_type, contains)) continue;
        if (std.mem.eql(u8, key, "verified_decisions") and !verifiedOrAccepted(result)) continue;
        if (!first_item) try out.append(allocator, ',');
        first_item = false;
        try result.writeJson(allocator, out);
    }
    try out.append(allocator, ']');
}

fn appendSectionText(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), title: []const u8, results: []const domain.SearchResult, result_type: []const u8, contains: []const u8) !void {
    try out.appendSlice(allocator, "\n");
    try out.appendSlice(allocator, title);
    try out.appendSlice(allocator, ":\n");
    var count: usize = 0;
    for (results) |result| {
        if (!sectionIncludes(result, result_type, contains)) continue;
        if (std.mem.eql(u8, title, "Verified decisions") and !verifiedOrAccepted(result)) continue;
        try out.appendSlice(allocator, "- ");
        try out.appendSlice(allocator, result.text);
        try out.append(allocator, '\n');
        count += 1;
    }
    if (count == 0) try out.appendSlice(allocator, "- None found.\n");
}

fn sectionIncludes(result: domain.SearchResult, result_type: []const u8, contains: []const u8) bool {
    if (!std.mem.eql(u8, result.result_type, result_type)) return false;
    if (contains.len == 0) return true;
    return std.ascii.indexOfIgnoreCase(result.title, contains) != null or
        std.ascii.indexOfIgnoreCase(result.text, contains) != null or
        std.ascii.indexOfIgnoreCase(result.status, contains) != null;
}

fn verifiedOrAccepted(result: domain.SearchResult) bool {
    return std.mem.eql(u8, result.status, "verified") or std.mem.eql(u8, result.status, "accepted");
}

fn appendRecentChanges(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), results: []const domain.SearchResult) !void {
    try out.appendSlice(allocator, "\nRecent changes:\n");
    var count: usize = 0;
    for (results) |result| {
        if (!std.mem.eql(u8, result.result_type, "feed_event") and
            !std.mem.eql(u8, result.result_type, "session_message"))
        {
            continue;
        }
        try out.appendSlice(allocator, "- ");
        try out.appendSlice(allocator, result.title);
        try out.appendSlice(allocator, ": ");
        try out.appendSlice(allocator, result.text);
        try out.append(allocator, '\n');
        count += 1;
    }
    if (count == 0) try out.appendSlice(allocator, "- None found.\n");
}

fn appendRelatedObjects(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), results: []const domain.SearchResult) !void {
    try out.appendSlice(allocator, "\nRelated objects:\n");
    var count: usize = 0;
    for (results) |result| {
        if (!std.mem.eql(u8, result.result_type, "artifact") and
            !std.mem.eql(u8, result.result_type, "source") and
            !std.mem.eql(u8, result.result_type, "entity") and
            !std.mem.eql(u8, result.result_type, "relation") and
            !std.mem.eql(u8, result.result_type, "space") and
            !std.mem.eql(u8, result.result_type, "policy_scope"))
        {
            continue;
        }
        try out.appendSlice(allocator, "- ");
        try out.appendSlice(allocator, result.result_type);
        try out.appendSlice(allocator, ": ");
        try out.appendSlice(allocator, result.title);
        try out.appendSlice(allocator, " (");
        try out.appendSlice(allocator, result.id);
        try out.appendSlice(allocator, ")\n");
        count += 1;
    }
    if (count == 0) try out.appendSlice(allocator, "- None found.\n");
}

fn appendStaticBullets(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), title: []const u8, items: []const []const u8) !void {
    try out.appendSlice(allocator, "\n");
    try out.appendSlice(allocator, title);
    try out.appendSlice(allocator, ":\n");
    for (items) |item| {
        try out.appendSlice(allocator, "- ");
        try out.appendSlice(allocator, item);
        try out.append(allocator, '\n');
    }
}

fn appendCitations(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), results: []const domain.SearchResult) !void {
    try out.appendSlice(allocator, "\nCitations:\n");
    var citation_count: usize = 0;
    for (results) |result| {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, result.source_ids_json, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .array) continue;
        for (parsed.value.array.items) |item| {
            if (item != .string) continue;
            try out.appendSlice(allocator, "- ");
            try out.appendSlice(allocator, item.string);
            try out.append(allocator, '\n');
            citation_count += 1;
        }
    }
    if (citation_count == 0) try out.appendSlice(allocator, "- No source citations available.\n");
}

fn appendUniqueJsonString(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), count: *usize, value: []const u8) !void {
    const needle = try std.fmt.allocPrint(allocator, "\"{s}\"", .{value});
    defer allocator.free(needle);
    if (std.mem.indexOf(u8, out.items, needle) != null) return;
    if (count.* > 0) try out.append(allocator, ',');
    try json.appendString(out, allocator, value);
    count.* += 1;
}

fn sample(id: []const u8, result_type: []const u8, title: []const u8, text: []const u8, scope: []const u8, status: []const u8, score: f64) domain.SearchResult {
    return .{
        .id = id,
        .result_type = result_type,
        .title = title,
        .text = text,
        .scope = scope,
        .status = status,
        .score = score,
        .source_ids_json = "[\"src_1\"]",
        .required_scopes_json = if (std.mem.eql(u8, scope, "public")) "[]" else "[\"project:nullpantry\"]",
        .created_at_ms = 1,
        .confidence = 0.9,
    };
}

test "context pack sorting prioritizes verified decisions and constraints" {
    var items = [_]domain.SearchResult{
        sample("art_1", "artifact", "Page", "General page", "public", "published", 10),
        sample("mem_1", "memory_atom", "Decision", "Decision: use atoms", "project:nullpantry", "verified", 1),
        sample("mem_2", "memory_atom", "Constraint", "Constraint: cite sources", "project:nullpantry", "verified", 0.5),
    };
    sortResults(&items);
    try std.testing.expectEqualStrings("mem_1", items[0].id);
    try std.testing.expectEqualStrings("mem_2", items[1].id);
}

test "context pack budget trims first oversized result" {
    const huge_text =
        "start " ++
        "abcdefghijklmnopqrstuvwxyz abcdefghijklmnopqrstuvwxyz abcdefghijklmnopqrstuvwxyz " ++
        "abcdefghijklmnopqrstuvwxyz abcdefghijklmnopqrstuvwxyz abcdefghijklmnopqrstuvwxyz " ++
        "tail-marker";
    const items = [_]domain.SearchResult{
        sample("src_big", "source", "Oversized source", huge_text, "public", "active", 1),
    };
    const budgeted = try budgetResults(std.testing.allocator, &items, 96);
    defer {
        if (budgeted[0].text.ptr != huge_text.ptr) std.testing.allocator.free(budgeted[0].text);
        std.testing.allocator.free(budgeted);
    }
    try std.testing.expectEqual(@as(usize, 1), budgeted.len);
    try std.testing.expect(budgeted[0].text.len < huge_text.len);
    try std.testing.expect(std.mem.indexOf(u8, budgeted[0].text, "tail-marker") == null);
    try std.testing.expect(std.mem.indexOf(u8, budgeted[0].text, "truncated to token_budget") != null);

    const sections = try buildSectionsJson(std.testing.allocator, budgeted);
    defer std.testing.allocator.free(sections);
    try std.testing.expect(std.mem.indexOf(u8, sections, "tail-marker") == null);
}

test "context pack summary and sections are citation backed" {
    const items = [_]domain.SearchResult{
        sample("mem_1", "memory_atom", "Decision", "Decision: NullPantry prepares trusted context.", "project:nullpantry", "verified", 1),
    };
    const summary = try buildSummary(std.testing.allocator, "Implement retrieval", &items);
    defer std.testing.allocator.free(summary);
    try std.testing.expect(std.mem.indexOf(u8, summary, "Verified decisions") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "src_1") != null);

    const sections = try buildSectionsJson(std.testing.allocator, &items);
    defer std.testing.allocator.free(sections);
    try std.testing.expect(std.mem.indexOf(u8, sections, "verified_decisions") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections, "mem_1") != null);
}

test "context pack verified decision section excludes proposed decisions" {
    const items = [_]domain.SearchResult{
        sample("mem_1", "memory_atom", "Decision", "Decision: Proposed plan.", "project:nullpantry", "proposed", 2),
        sample("mem_2", "memory_atom", "Decision", "Decision: Accepted plan.", "project:nullpantry", "verified", 1),
    };
    const sections = try buildSectionsJson(std.testing.allocator, &items);
    defer std.testing.allocator.free(sections);
    try std.testing.expect(std.mem.indexOf(u8, sections, "mem_2") != null);
    const verified_start = std.mem.indexOf(u8, sections, "\"verified_decisions\"").?;
    const constraints_start = std.mem.indexOf(u8, sections, "\"constraints\"").?;
    try std.testing.expect(std.mem.indexOf(u8, sections[verified_start..constraints_start], "mem_1") == null);
}

test "context pack required scopes are unique and skip public" {
    const items = [_]domain.SearchResult{
        sample("src_1", "source", "Public", "Public source", "public", "verified", 1),
        sample("mem_1", "memory_atom", "One", "One", "project:nullpantry", "verified", 1),
        sample("mem_2", "memory_atom", "Two", "Two", "project:nullpantry", "verified", 1),
    };
    const scopes = try requiredScopesJson(std.testing.allocator, &items);
    defer std.testing.allocator.free(scopes);
    try std.testing.expectEqualStrings("[\"project:nullpantry\"]", scopes);
}

test "context pack required scopes include permission grants from search results" {
    const items = [_]domain.SearchResult{
        .{
            .id = "feed_1",
            .result_type = "feed_event",
            .title = "feed",
            .text = "private feed",
            .scope = "public",
            .status = "applied",
            .score = 1,
            .source_ids_json = "[]",
            .required_scopes_json = "[\"team:secret\"]",
        },
    };
    const scopes = try requiredScopesJson(std.testing.allocator, &items);
    defer std.testing.allocator.free(scopes);
    try std.testing.expectEqualStrings("[\"team:secret\"]", scopes);
}

test "context pack actor isolation is derived from included results" {
    const items = [_]domain.SearchResult{
        .{ .id = "agm_1", .result_type = "agent_memory", .title = "memory", .text = "private", .scope = "agent:agent:a", .status = "proposed", .score = 1, .source_ids_json = "[]", .actor_isolated = true },
    };
    try std.testing.expect(requiresActorIsolation(&items));
}

test "context pack result refs preserve non-primitive acl metadata" {
    const items = [_]domain.SearchResult{
        .{
            .id = "agm_1",
            .result_type = "agent_memory",
            .title = "memory",
            .text = "private",
            .scope = "agent:agent:a",
            .status = "verified",
            .score = 1,
            .source_ids_json = "[]",
            .required_scopes_json = "[\"agent:agent:a\"]",
            .actor_isolated = true,
        },
    };
    const refs = try resultRefsJson(std.testing.allocator, &items);
    defer std.testing.allocator.free(refs);
    try std.testing.expect(std.mem.indexOf(u8, refs, "\"type\":\"agent_memory\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, refs, "\"required_scopes\":[\"agent:agent:a\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, refs, "\"actor_isolated\":true") != null);
}
