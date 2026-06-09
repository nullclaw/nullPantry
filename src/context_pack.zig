const std = @import("std");
const access = @import("access.zig");
const domain = @import("domain.zig");
const json = @import("json_util.zig");
const bounded_int = @import("bounded_int.zig");

const context_pack_metadata_overhead: usize = 192;
const context_pack_min_trim_text_chars: usize = 24;
const context_pack_min_token_budget: usize = 1;
const context_pack_max_token_budget: usize = 200_000;
const context_pack_chars_per_token: usize = 4;

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
        const required_access = std.mem.trim(u8, result.required_scopes_json, " \t\r\n");
        if (required_access.len == 0) {
            if (result.scope.len == 0 or std.mem.eql(u8, result.scope, "public")) continue;
            try appendUniqueJsonString(allocator, &out, &count, result.scope);
            continue;
        }
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, required_access, .{}) catch {
            try appendUniqueJsonString(allocator, &out, &count, access.malformed_required_access_gate);
            continue;
        };
        defer parsed.deinit();
        if (parsed.value == .array) {
            had_explicit_required = true;
            for (parsed.value.array.items) |item| {
                if (item != .string) {
                    try appendUniqueJsonString(allocator, &out, &count, access.malformed_required_access_gate);
                    appended_required = true;
                    break;
                }
                if (item.string.len == 0) {
                    try appendUniqueJsonString(allocator, &out, &count, access.malformed_required_access_gate);
                    appended_required = true;
                    break;
                }
                if (std.mem.eql(u8, item.string, "public")) continue;
                try appendUniqueJsonString(allocator, &out, &count, item.string);
                appended_required = true;
            }
        } else {
            try appendUniqueJsonString(allocator, &out, &count, access.malformed_required_access_gate);
            continue;
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
        try json.appendString(&out, allocator, "heading_path");
        try out.append(allocator, ':');
        try json.appendRawJsonArray(&out, allocator, result.heading_path_json);
        try out.append(allocator, ',');
        try json.appendString(&out, allocator, "required_scopes");
        try out.append(allocator, ':');
        try appendResultRequiredAccessJson(allocator, &out, result);
        try out.append(allocator, ',');
        try json.appendString(&out, allocator, "actor_isolated");
        try out.append(allocator, ':');
        try out.appendSlice(allocator, if (result.actor_isolated) "true" else "false");
        if (result.store.len > 0) {
            try out.append(allocator, ',');
            try json.appendString(&out, allocator, "store");
            try out.append(allocator, ':');
            try json.appendString(&out, allocator, result.store);
            try out.append(allocator, ',');
            try json.appendString(&out, allocator, "storage");
            try out.append(allocator, ':');
            try json.appendString(&out, allocator, result.store);
        }
        try out.append(allocator, '}');
    }
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

fn appendResultRequiredAccessJson(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), result: domain.SearchResult) !void {
    const required_access = std.mem.trim(u8, result.required_scopes_json, " \t\r\n");
    if (required_access.len > 0) return appendRequiredAccessJsonOrFailClosed(allocator, out, required_access);
    if (result.scope.len == 0 or std.mem.eql(u8, result.scope, "public")) return out.appendSlice(allocator, "[]");

    try out.append(allocator, '[');
    try json.appendString(out, allocator, result.scope);
    try out.append(allocator, ']');
}

fn appendRequiredAccessJsonOrFailClosed(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), required_access_json: []const u8) !void {
    const trimmed = std.mem.trim(u8, required_access_json, " \t\r\n");
    if (trimmed.len == 0) return out.appendSlice(allocator, "[]");
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch {
        return appendMalformedRequiredAccessJson(allocator, out);
    };
    defer parsed.deinit();
    if (parsed.value != .array) return appendMalformedRequiredAccessJson(allocator, out);
    for (parsed.value.array.items) |item| {
        if (item != .string) return appendMalformedRequiredAccessJson(allocator, out);
        if (item.string.len == 0) return appendMalformedRequiredAccessJson(allocator, out);
    }
    try out.appendSlice(allocator, trimmed);
}

fn appendMalformedRequiredAccessJson(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    try out.append(allocator, '[');
    try json.appendString(out, allocator, access.malformed_required_access_gate);
    try out.append(allocator, ']');
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

pub const BudgetedResults = struct {
    items: []domain.SearchResult,
    owned_texts: []const []const u8,

    pub fn deinit(self: BudgetedResults, allocator: std.mem.Allocator) void {
        for (self.owned_texts) |text| allocator.free(text);
        allocator.free(self.owned_texts);
        allocator.free(self.items);
    }
};

pub fn budgetResults(allocator: std.mem.Allocator, results: []const domain.SearchResult, token_budget: i64) !BudgetedResults {
    const budget_tokens = contextPackTokenBudget(token_budget);
    const max_chars = contextPackCharBudget(budget_tokens);
    var used_chars: usize = 0;
    var out: std.ArrayListUnmanaged(domain.SearchResult) = .empty;
    var owned_texts: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (owned_texts.items) |text| allocator.free(text);
        owned_texts.deinit(allocator);
        out.deinit(allocator);
    }
    for (results) |result| {
        const metadata_cost = contextPackMetadataCost(result);
        const cost = contextPackResultCost(metadata_cost, result.text.len);
        if (contextPackBudgetCanFit(used_chars, cost, max_chars)) {
            used_chars = contextPackAddCost(used_chars, cost);
            try out.append(allocator, result);
            if (used_chars >= max_chars) break;
            continue;
        }

        const remaining = max_chars -| used_chars;
        if (!contextPackTrimCanFit(metadata_cost, remaining)) continue;
        var trimmed = result;
        trimmed.text = try trimTextToChars(allocator, result.text, remaining - metadata_cost);
        try owned_texts.append(allocator, trimmed.text);
        used_chars = contextPackAddCost(used_chars, contextPackResultCost(metadata_cost, trimmed.text.len));
        try out.append(allocator, trimmed);
        break;
    }
    return .{
        .items = try out.toOwnedSlice(allocator),
        .owned_texts = try owned_texts.toOwnedSlice(allocator),
    };
}

pub fn trimSummaryToBudget(allocator: std.mem.Allocator, summary: []const u8, token_budget: i64) ![]u8 {
    const budget_tokens = contextPackTokenBudget(token_budget);
    const max_chars = contextPackSummaryCharBudget(budget_tokens);
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
        if (!resultBelongsInSection(result, key, result_type, contains)) continue;
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
        if (!resultBelongsInSection(result, title, result_type, contains)) continue;
        try out.appendSlice(allocator, "- ");
        try appendStorePrefix(allocator, out, result);
        try appendHeadingPathPrefix(allocator, out, result);
        try out.appendSlice(allocator, result.text);
        try out.append(allocator, '\n');
        count += 1;
    }
    if (count == 0) try out.appendSlice(allocator, "- None found.\n");
}

fn resultBelongsInSection(result: domain.SearchResult, section: []const u8, result_type: []const u8, contains: []const u8) bool {
    if (sectionIsMemoryCatchAll(section)) return genericMemoryAtom(result);
    if (sectionIsArtifactCatchAll(section)) return genericArtifact(result);
    if (sectionIsRunbook(section)) return runbookArtifact(result);
    if (!sectionIncludes(result, result_type, contains)) return false;
    if (sectionIsVerifiedDecision(section)) return verifiedOrAccepted(result);
    return true;
}

fn sectionIsVerifiedDecision(section: []const u8) bool {
    return std.mem.eql(u8, section, "verified_decisions") or std.mem.eql(u8, section, "Verified decisions");
}

fn sectionIsMemoryCatchAll(section: []const u8) bool {
    return std.mem.eql(u8, section, "memory_atoms") or std.mem.eql(u8, section, "Memory atoms");
}

fn sectionIsArtifactCatchAll(section: []const u8) bool {
    return std.mem.eql(u8, section, "artifacts") or std.mem.eql(u8, section, "Artifacts");
}

fn sectionIsRunbook(section: []const u8) bool {
    return std.mem.eql(u8, section, "runbooks") or std.mem.eql(u8, section, "Runbooks");
}

fn genericMemoryAtom(result: domain.SearchResult) bool {
    if (!std.mem.eql(u8, result.result_type, "memory_atom")) return false;
    return !memoryAtomHasSpecificSection(result);
}

fn memoryAtomHasSpecificSection(result: domain.SearchResult) bool {
    if (memoryAtomContains(result, "constraint")) return true;
    if (memoryAtomContains(result, "risk")) return true;
    if (memoryAtomContains(result, "question")) return true;
    return memoryAtomContains(result, "decision") and verifiedOrAccepted(result);
}

fn genericArtifact(result: domain.SearchResult) bool {
    if (!std.mem.eql(u8, result.result_type, "artifact")) return false;
    return !runbookArtifact(result);
}

fn runbookArtifact(result: domain.SearchResult) bool {
    if (!std.mem.eql(u8, result.result_type, "artifact")) return false;
    return std.ascii.indexOfIgnoreCase(result.title, "runbook") != null or
        std.ascii.indexOfIgnoreCase(result.title, "recipe") != null or
        std.ascii.indexOfIgnoreCase(result.text, "runbook") != null or
        std.ascii.indexOfIgnoreCase(result.text, "recipe") != null or
        std.ascii.indexOfIgnoreCase(result.status, "runbook") != null;
}

fn memoryAtomContains(result: domain.SearchResult, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(result.title, needle) != null or
        std.ascii.indexOfIgnoreCase(result.text, needle) != null or
        std.ascii.indexOfIgnoreCase(result.status, needle) != null;
}

fn appendStorePrefix(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), result: domain.SearchResult) !void {
    if (result.store.len == 0) return;
    try out.appendSlice(allocator, "[store:");
    try out.appendSlice(allocator, result.store);
    try out.appendSlice(allocator, "] ");
}

fn appendHeadingPathPrefix(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), result: domain.SearchResult) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, result.heading_path_json, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .array) return;
    var count: usize = 0;
    for (parsed.value.array.items) |item| {
        if (item != .string or item.string.len == 0) continue;
        if (count == 0) try out.append(allocator, '[') else try out.appendSlice(allocator, " > ");
        try out.appendSlice(allocator, item.string);
        count += 1;
    }
    if (count > 0) try out.appendSlice(allocator, "] ");
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
    const needle = try json.stringLiteral(allocator, value);
    defer allocator.free(needle);
    if (std.mem.indexOf(u8, out.items, needle) != null) return;
    if (count.* > 0) try out.append(allocator, ',');
    try json.appendString(out, allocator, value);
    count.* += 1;
}

fn contextPackMetadataCost(result: domain.SearchResult) usize {
    var cost = context_pack_metadata_overhead;
    cost = contextPackAddCost(cost, result.id.len);
    cost = contextPackAddCost(cost, result.result_type.len);
    cost = contextPackAddCost(cost, result.title.len);
    cost = contextPackAddCost(cost, result.scope.len);
    cost = contextPackAddCost(cost, result.status.len);
    cost = contextPackAddCost(cost, result.source_ids_json.len);
    cost = contextPackAddCost(cost, result.heading_path_json.len);
    cost = contextPackAddCost(cost, result.required_scopes_json.len);
    return cost;
}

fn contextPackResultCost(metadata_cost: usize, text_len: usize) usize {
    return contextPackAddCost(metadata_cost, text_len);
}

fn contextPackAddCost(left: usize, right: usize) usize {
    return bounded_int.saturatingUsizeAdd(left, right);
}

fn contextPackTokenBudget(token_budget: i64) usize {
    return @max(context_pack_min_token_budget, bounded_int.positiveI64ToUsizeBounded(token_budget, context_pack_max_token_budget));
}

fn contextPackCharBudget(token_budget: usize) usize {
    return bounded_int.saturatingUsizeMul(token_budget, context_pack_chars_per_token);
}

fn contextPackSummaryCharBudget(token_budget: usize) usize {
    return @max(@as(usize, 512), contextPackCharBudget(token_budget));
}

fn contextPackBudgetCanFit(used_chars: usize, cost: usize, max_chars: usize) bool {
    return cost <= max_chars -| used_chars;
}

fn contextPackTrimCanFit(metadata_cost: usize, remaining_chars: usize) bool {
    return remaining_chars > contextPackAddCost(metadata_cost, context_pack_min_trim_text_chars);
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
    defer budgeted.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), budgeted.items.len);
    try std.testing.expectEqual(@as(usize, 1), budgeted.owned_texts.len);
    try std.testing.expect(budgeted.items[0].text.len < huge_text.len);
    try std.testing.expect(std.mem.indexOf(u8, budgeted.items[0].text, "tail-marker") == null);
    try std.testing.expect(std.mem.indexOf(u8, budgeted.items[0].text, "truncated to token_budget") != null);

    const sections = try buildSectionsJson(std.testing.allocator, budgeted.items);
    defer std.testing.allocator.free(sections);
    try std.testing.expect(std.mem.indexOf(u8, sections, "tail-marker") == null);
}

test "context pack budget accounting saturates oversized costs" {
    const max = std.math.maxInt(usize);
    const normal = sample("src", "source", "Title", "text", "public", "active", 1);
    const normal_metadata_cost = contextPackMetadataCost(normal);
    const normal_result_cost = contextPackResultCost(normal_metadata_cost, normal.text.len);

    try std.testing.expectEqual(@as(usize, 231), normal_metadata_cost);
    try std.testing.expectEqual(@as(usize, 235), normal_result_cost);
    try std.testing.expect(contextPackBudgetCanFit(0, normal_result_cost, normal_result_cost));

    try std.testing.expectEqual(max, contextPackAddCost(max - 1, 2));
    try std.testing.expectEqual(max, contextPackResultCost(max - 3, 8));
    try std.testing.expect(!contextPackBudgetCanFit(0, max, 800_000));
    try std.testing.expect(!contextPackTrimCanFit(max - context_pack_min_trim_text_chars + 1, max));
}

test "context pack token budgets clamp request values" {
    const max = std.math.maxInt(usize);

    try std.testing.expectEqual(context_pack_min_token_budget, contextPackTokenBudget(-1));
    try std.testing.expectEqual(context_pack_min_token_budget, contextPackTokenBudget(0));
    try std.testing.expectEqual(@as(usize, 42), contextPackTokenBudget(42));
    try std.testing.expectEqual(context_pack_max_token_budget, contextPackTokenBudget(std.math.maxInt(i64)));

    try std.testing.expectEqual(@as(usize, 4), contextPackCharBudget(1));
    try std.testing.expectEqual(@as(usize, 168), contextPackCharBudget(42));
    try std.testing.expectEqual(max, contextPackCharBudget(max));
    try std.testing.expectEqual(@as(usize, 512), contextPackSummaryCharBudget(1));
    try std.testing.expectEqual(@as(usize, 800), contextPackSummaryCharBudget(200));
    try std.testing.expectEqual(max, contextPackSummaryCharBudget(max));
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

test "context pack catch-all sections do not duplicate section-specific context" {
    const items = [_]domain.SearchResult{
        sample("mem_decision", "memory_atom", "Decision", "Decision: Accepted plan.", "project:nullpantry", "verified", 1),
        sample("mem_proposed", "memory_atom", "Decision", "Decision: Proposed plan.", "project:nullpantry", "proposed", 0.9),
        sample("mem_constraint", "memory_atom", "Constraint", "Constraint: cite sources.", "project:nullpantry", "verified", 0.8),
        sample("mem_risk", "memory_atom", "Risk", "Risk: stale context.", "project:nullpantry", "verified", 0.7),
        sample("mem_question", "memory_atom", "Question", "Question: who owns ingestion?", "project:nullpantry", "verified", 0.6),
        sample("art_runbook", "artifact", "Recipe: release", "Recipe for release.", "public", "published", 0.5),
        sample("art_page", "artifact", "Page", "General architecture page.", "public", "published", 0.4),
    };

    const sections = try buildSectionsJson(std.testing.allocator, &items);
    defer std.testing.allocator.free(sections);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, sections, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqual(@as(usize, 1), root.get("verified_decisions").?.array.items.len);
    try std.testing.expectEqualStrings("mem_decision", root.get("verified_decisions").?.array.items[0].object.get("id").?.string);
    try std.testing.expectEqual(@as(usize, 1), root.get("constraints").?.array.items.len);
    try std.testing.expectEqualStrings("mem_constraint", root.get("constraints").?.array.items[0].object.get("id").?.string);
    try std.testing.expectEqual(@as(usize, 1), root.get("known_risks").?.array.items.len);
    try std.testing.expectEqualStrings("mem_risk", root.get("known_risks").?.array.items[0].object.get("id").?.string);
    try std.testing.expectEqual(@as(usize, 1), root.get("open_questions").?.array.items.len);
    try std.testing.expectEqualStrings("mem_question", root.get("open_questions").?.array.items[0].object.get("id").?.string);
    try std.testing.expectEqual(@as(usize, 1), root.get("memory_atoms").?.array.items.len);
    try std.testing.expectEqualStrings("mem_proposed", root.get("memory_atoms").?.array.items[0].object.get("id").?.string);
    try std.testing.expectEqual(@as(usize, 1), root.get("runbooks").?.array.items.len);
    try std.testing.expectEqualStrings("art_runbook", root.get("runbooks").?.array.items[0].object.get("id").?.string);
    try std.testing.expectEqual(@as(usize, 1), root.get("artifacts").?.array.items.len);
    try std.testing.expectEqualStrings("art_page", root.get("artifacts").?.array.items[0].object.get("id").?.string);
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

test "context pack required scopes fail closed for malformed result access" {
    const items = [_]domain.SearchResult{
        .{
            .id = "bad_access",
            .result_type = "feed_event",
            .title = "bad access",
            .text = "private feed",
            .scope = "public",
            .status = "applied",
            .score = 1,
            .source_ids_json = "[]",
            .required_scopes_json = "{\"scope\":\"team:secret\"}",
        },
        .{
            .id = "mixed_access",
            .result_type = "feed_event",
            .title = "mixed access",
            .text = "private feed",
            .scope = "public",
            .status = "applied",
            .score = 1,
            .source_ids_json = "[]",
            .required_scopes_json = "[\"team:secret\",42]",
        },
        .{
            .id = "empty_access",
            .result_type = "feed_event",
            .title = "empty access",
            .text = "private feed",
            .scope = "public",
            .status = "applied",
            .score = 1,
            .source_ids_json = "[]",
            .required_scopes_json = "[\"\"]",
        },
    };
    const scopes = try requiredScopesJson(std.testing.allocator, &items);
    defer std.testing.allocator.free(scopes);
    try std.testing.expect(std.mem.indexOf(u8, scopes, access.malformed_required_access_gate) != null);
    try std.testing.expect(std.mem.indexOf(u8, scopes, "team:secret") != null);
}

test "context pack required scopes dedupe canonical escaped strings" {
    const items = [_]domain.SearchResult{
        .{
            .id = "feed_escaped",
            .result_type = "feed_event",
            .title = "feed escaped",
            .text = "private feed",
            .scope = "public",
            .status = "applied",
            .score = 1,
            .source_ids_json = "[]",
            .required_scopes_json = "[\"team:\\u0041\"]",
        },
        .{
            .id = "feed_plain",
            .result_type = "feed_event",
            .title = "feed plain",
            .text = "private feed",
            .scope = "public",
            .status = "applied",
            .score = 1,
            .source_ids_json = "[]",
            .required_scopes_json = "[\"team:A\"]",
        },
    };
    const scopes = try requiredScopesJson(std.testing.allocator, &items);
    defer std.testing.allocator.free(scopes);
    try std.testing.expectEqualStrings("[\"team:A\"]", scopes);
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
            .heading_path_json = "[\"# Agent\",\"## Memory\"]",
            .required_scopes_json = "[\"agent:agent:a\"]",
            .actor_isolated = true,
        },
    };
    const refs = try resultRefsJson(std.testing.allocator, &items);
    defer std.testing.allocator.free(refs);
    try std.testing.expect(std.mem.indexOf(u8, refs, "\"type\":\"agent_memory\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, refs, "\"heading_path\":[\"# Agent\",\"## Memory\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, refs, "\"required_scopes\":[\"agent:agent:a\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, refs, "\"actor_isolated\":true") != null);
}

test "context pack result refs reject malformed heading paths" {
    const items = [_]domain.SearchResult{
        .{
            .id = "bad_heading",
            .result_type = "artifact",
            .title = "bad heading",
            .text = "bad",
            .scope = "public",
            .status = "verified",
            .score = 1,
            .source_ids_json = "[]",
            .heading_path_json = "{\"heading\":\"Intro\"}",
            .required_scopes_json = "[]",
        },
    };
    try std.testing.expectError(error.InvalidRawJson, resultRefsJson(std.testing.allocator, &items));
}

test "context pack result refs distinguish missing and explicitly empty access metadata" {
    const items = [_]domain.SearchResult{
        .{
            .id = "missing_acl",
            .result_type = "source",
            .title = "missing acl",
            .text = "private",
            .scope = "project:secret",
            .status = "verified",
            .score = 1,
            .source_ids_json = "[]",
        },
        .{
            .id = "explicit_empty_acl",
            .result_type = "agent_memory",
            .title = "explicit empty acl",
            .text = "actor private",
            .scope = "agent:agent:a",
            .status = "verified",
            .score = 1,
            .source_ids_json = "[]",
            .required_scopes_json = "[]",
            .actor_isolated = true,
        },
    };
    const refs = try resultRefsJson(std.testing.allocator, &items);
    defer std.testing.allocator.free(refs);
    try std.testing.expect(std.mem.indexOf(u8, refs, "\"id\":\"missing_acl\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, refs, "\"required_scopes\":[\"project:secret\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, refs, "\"id\":\"explicit_empty_acl\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, refs, "\"required_scopes\":[],\"actor_isolated\":true") != null);
}

test "context pack result refs fail closed for malformed acl metadata" {
    const items = [_]domain.SearchResult{
        .{
            .id = "bad_acl",
            .result_type = "feed_event",
            .title = "bad acl",
            .text = "private",
            .scope = "public",
            .status = "applied",
            .score = 1,
            .source_ids_json = "[]",
            .required_scopes_json = "not-json",
        },
    };
    const refs = try resultRefsJson(std.testing.allocator, &items);
    defer std.testing.allocator.free(refs);
    try std.testing.expect(std.mem.indexOf(u8, refs, "\"required_scopes\":[\"__nullpantry_malformed_required_access_json__\"]") != null);
}

test "context pack result refs fail closed for empty required access gates" {
    const items = [_]domain.SearchResult{
        .{
            .id = "bad_empty",
            .result_type = "source",
            .title = "bad empty",
            .text = "private",
            .scope = "public",
            .status = "verified",
            .score = 1,
            .source_ids_json = "[]",
            .required_scopes_json = "[\"\"]",
        },
    };
    const refs = try resultRefsJson(std.testing.allocator, &items);
    defer std.testing.allocator.free(refs);
    try std.testing.expect(std.mem.indexOf(u8, refs, "\"required_scopes\":[\"__nullpantry_malformed_required_access_json__\"]") != null);
}

test "context pack summary and refs preserve agent memory store identity" {
    const items = [_]domain.SearchResult{
        .{
            .id = "agent_memory:scratch:agm_same",
            .result_type = "agent_memory",
            .title = "named.same",
            .text = "Scratch store preference",
            .scope = "agent:agent:a",
            .status = "verified",
            .score = 1,
            .source_ids_json = "[]",
            .required_scopes_json = "[\"agent:agent:a\"]",
            .actor_isolated = true,
            .store = "scratch",
        },
        .{
            .id = "agent_memory:archive:agm_same",
            .result_type = "agent_memory",
            .title = "named.same",
            .text = "Archive store preference",
            .scope = "agent:agent:a",
            .status = "verified",
            .score = 1,
            .source_ids_json = "[]",
            .required_scopes_json = "[\"agent:agent:a\"]",
            .actor_isolated = true,
            .store = "archive",
        },
    };

    const summary = try buildSummary(std.testing.allocator, "named.same", &items);
    defer std.testing.allocator.free(summary);
    try std.testing.expect(std.mem.indexOf(u8, summary, "[store:scratch] Scratch store preference") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "[store:archive] Archive store preference") != null);

    const refs = try resultRefsJson(std.testing.allocator, &items);
    defer std.testing.allocator.free(refs);
    try std.testing.expect(std.mem.indexOf(u8, refs, "\"id\":\"agent_memory:scratch:agm_same\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, refs, "\"store\":\"scratch\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, refs, "\"storage\":\"scratch\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, refs, "\"id\":\"agent_memory:archive:agm_same\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, refs, "\"store\":\"archive\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, refs, "\"storage\":\"archive\"") != null);
}
