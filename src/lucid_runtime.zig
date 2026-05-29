const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat.zig");
const domain = @import("domain.zig");
const ids = @import("ids.zig");

pub const max_lucid_output_bytes: usize = 1024 * 1024;

pub const Config = struct {
    enabled: bool = false,
    command: []const u8 = "lucid",
    workspace_dir: []const u8 = ".",
    token_budget: usize = 200,
    local_hit_threshold: usize = 3,
    recall_timeout_ms: u32 = 500,
    store_timeout_ms: u32 = 800,
    failure_cooldown_ms: u64 = 15_000,
    project_scopes_json: []const u8 = "[\"public\"]",
    result_scope: []const u8 = "public",
    permissions_json: []const u8 = "[]",

    pub fn isEnabled(self: Config) bool {
        return self.enabled and self.command.len > 0;
    }
};

pub const Entry = struct {
    id: []const u8,
    label: []const u8,
    content: []const u8,
    score: f64,
};

pub const Runtime = struct {
    config: Config = .{},
    cooldown_until_ms: i64 = 0,

    pub fn init(config: Config) Runtime {
        return .{ .config = config };
    }

    pub fn backendName(self: *const Runtime) []const u8 {
        return if (self.config.isEnabled()) "lucid" else "none";
    }

    pub fn isEnabled(self: *const Runtime) bool {
        return self.config.isEnabled();
    }

    pub fn shouldAugment(self: *const Runtime, current_result_count: usize) bool {
        return self.config.isEnabled() and current_result_count < @max(@as(usize, 1), self.config.local_hit_threshold);
    }

    pub fn resultVisible(self: *const Runtime, allocator: std.mem.Allocator, scopes_json: []const u8, actor_id: ?[]const u8) bool {
        return domain.scopeVisible(self.config.result_scope, scopes_json) and
            @import("access.zig").permissionsVisibleForActor(allocator, self.config.permissions_json, scopes_json, actor_id);
    }

    pub fn canProject(self: *const Runtime, scope: []const u8, permissions_json: []const u8) bool {
        if (!self.config.isEnabled()) return false;
        return domain.recordVisible(scope, permissions_json, self.config.project_scopes_json);
    }

    pub fn storeMemoryAtom(self: *Runtime, allocator: std.mem.Allocator, id: []const u8, text: []const u8, predicate: []const u8, scope: []const u8, permissions_json: []const u8) !void {
        if (!self.canProject(scope, permissions_json)) return;
        const lucid_type = typeForMemoryAtom(predicate, text);
        try self.store(allocator, id, text, lucid_type);
    }

    pub fn storeAgentMemory(self: *Runtime, allocator: std.mem.Allocator, key: []const u8, content: []const u8, category: []const u8, scope: []const u8, permissions_json: []const u8) !void {
        if (!self.canProject(scope, permissions_json)) return;
        try self.store(allocator, key, content, typeForAgentCategory(category));
    }

    pub fn context(self: *Runtime, allocator: std.mem.Allocator, query: []const u8) ![]Entry {
        if (!self.config.isEnabled()) return allocator.alloc(Entry, 0);
        if (self.inFailureCooldown()) return allocator.alloc(Entry, 0);

        const budget_flag = try std.fmt.allocPrint(allocator, "--budget={d}", .{self.config.token_budget});
        defer allocator.free(budget_flag);
        const project_flag = try std.fmt.allocPrint(allocator, "--project={s}", .{self.config.workspace_dir});
        defer allocator.free(project_flag);
        const argv = [_][]const u8{ self.config.command, "context", query, budget_flag, project_flag };

        const raw = self.run(allocator, &argv, self.config.recall_timeout_ms) catch {
            self.markFailure();
            return allocator.alloc(Entry, 0);
        };
        defer allocator.free(raw);
        self.clearFailure();
        return parseContext(allocator, raw);
    }

    fn store(self: *Runtime, allocator: std.mem.Allocator, key: []const u8, content: []const u8, lucid_type: []const u8) !void {
        if (!self.config.isEnabled()) return;
        if (self.inFailureCooldown()) return;

        const payload = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ key, content });
        defer allocator.free(payload);
        const type_flag = try std.fmt.allocPrint(allocator, "--type={s}", .{lucid_type});
        defer allocator.free(type_flag);
        const project_flag = try std.fmt.allocPrint(allocator, "--project={s}", .{self.config.workspace_dir});
        defer allocator.free(project_flag);
        const argv = [_][]const u8{ self.config.command, "store", payload, type_flag, project_flag };

        const out = self.run(allocator, &argv, self.config.store_timeout_ms) catch {
            self.markFailure();
            return;
        };
        allocator.free(out);
        self.clearFailure();
    }

    fn run(self: *Runtime, allocator: std.mem.Allocator, argv: []const []const u8, timeout_ms: u32) ![]u8 {
        _ = self;
        const result = try std.process.run(allocator, compat.io(), .{
            .argv = argv,
            .stdout_limit = .limited(max_lucid_output_bytes),
            .stderr_limit = .limited(16 * 1024),
            .timeout = .{ .duration = .{
                .raw = std.Io.Duration.fromMilliseconds(@intCast(timeout_ms)),
                .clock = .awake,
            } },
        });
        defer allocator.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code == 0) return result.stdout,
            else => {},
        }
        allocator.free(result.stdout);
        return error.LucidCommandFailed;
    }

    fn inFailureCooldown(self: *const Runtime) bool {
        if (self.cooldown_until_ms == 0) return false;
        return nowMs() < self.cooldown_until_ms;
    }

    fn markFailure(self: *Runtime) void {
        self.cooldown_until_ms = nowMs() + @as(i64, @intCast(self.config.failure_cooldown_ms));
    }

    fn clearFailure(self: *Runtime) void {
        self.cooldown_until_ms = 0;
    }
};

pub fn freeEntries(allocator: std.mem.Allocator, entries: []Entry) void {
    for (entries) |entry| {
        allocator.free(entry.id);
        allocator.free(entry.label);
        allocator.free(entry.content);
    }
    allocator.free(entries);
}

pub fn parseContext(allocator: std.mem.Allocator, raw: []const u8) ![]Entry {
    var entries: std.ArrayListUnmanaged(Entry) = .empty;
    errdefer {
        for (entries.items) |entry| {
            allocator.free(entry.id);
            allocator.free(entry.label);
            allocator.free(entry.content);
        }
        entries.deinit(allocator);
    }

    var in_context_block = false;
    var rank: usize = 0;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (std.mem.eql(u8, line, "<lucid-context>")) {
            in_context_block = true;
            continue;
        }
        if (std.mem.eql(u8, line, "</lucid-context>")) break;
        if (!in_context_block or line.len == 0) continue;

        const rest = stripPrefix(line, "- [") orelse continue;
        const close_bracket = std.mem.indexOfScalar(u8, rest, ']') orelse continue;
        const label = std.mem.trim(u8, rest[0..close_bracket], " \t");
        const content = std.mem.trim(u8, rest[close_bracket + 1 ..], " \t");
        if (content.len == 0) continue;

        {
            const id = try std.fmt.allocPrint(allocator, "lucid:{d}", .{rank});
            errdefer allocator.free(id);
            const label_owned = try allocator.dupe(u8, label);
            errdefer allocator.free(label_owned);
            const content_owned = try allocator.dupe(u8, content);
            errdefer allocator.free(content_owned);
            try entries.append(allocator, .{
                .id = id,
                .label = label_owned,
                .content = content_owned,
                .score = @max(1.0 - @as(f64, @floatFromInt(rank)) * 0.05, 0.1),
            });
        }
        rank += 1;
    }
    return entries.toOwnedSlice(allocator);
}

pub fn typeForAgentCategory(category: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(category, "core")) return "decision";
    if (std.ascii.eqlIgnoreCase(category, "daily")) return "context";
    if (std.ascii.eqlIgnoreCase(category, "conversation")) return "conversation";
    return "learning";
}

pub fn typeForMemoryAtom(predicate: []const u8, text: []const u8) []const u8 {
    if (containsIgnoreCase(predicate, "decision") or containsIgnoreCase(text, "decision:")) return "decision";
    if (containsIgnoreCase(predicate, "conversation") or containsIgnoreCase(predicate, "meeting")) return "conversation";
    if (containsIgnoreCase(predicate, "runbook") or containsIgnoreCase(predicate, "procedure")) return "context";
    return "learning";
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn stripPrefix(s: []const u8, prefix: []const u8) ?[]const u8 {
    if (s.len < prefix.len) return null;
    if (std.mem.eql(u8, s[0..prefix.len], prefix)) return s[prefix.len..];
    return null;
}

fn nowMs() i64 {
    return ids.nowMs();
}

test "lucid context parser returns ranked projection entries" {
    const raw =
        \\<lucid-context>
        \\- [decision] Use token refresh middleware
        \\- [context] Working in src/auth.rs
        \\</lucid-context>
    ;
    const entries = try parseContext(std.testing.allocator, raw);
    defer freeEntries(std.testing.allocator, entries);

    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("lucid:0", entries[0].id);
    try std.testing.expectEqualStrings("decision", entries[0].label);
    try std.testing.expectEqualStrings("Use token refresh middleware", entries[0].content);
    try std.testing.expect(entries[0].score > entries[1].score);
}

test "lucid projection gates writes by configured projection scopes" {
    var runtime = Runtime.init(.{ .enabled = true, .project_scopes_json = "[\"public\"]" });
    try std.testing.expect(runtime.canProject("public", "[]"));
    try std.testing.expect(!runtime.canProject("project:secret", "[]"));
    var admin_runtime = Runtime.init(.{ .enabled = true, .project_scopes_json = "[\"admin\"]" });
    try std.testing.expect(admin_runtime.canProject("project:secret", "[\"team:secret\"]"));
}

test "lucid type mapping keeps nullclaw categories recognizable" {
    try std.testing.expectEqualStrings("decision", typeForAgentCategory("core"));
    try std.testing.expectEqualStrings("context", typeForAgentCategory("daily"));
    try std.testing.expectEqualStrings("conversation", typeForAgentCategory("conversation"));
    try std.testing.expectEqualStrings("learning", typeForAgentCategory("custom"));
    try std.testing.expectEqualStrings("decision", typeForMemoryAtom("decision.database", "Database is SQLite"));
}

test "lucid projection CLI contract with fake command" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const tmp_random = try ids.make(std.testing.allocator, "");
    defer std.testing.allocator.free(tmp_random);
    const tmp_name = try std.fmt.allocPrint(std.testing.allocator, "lucidcontract{d}_{s}", .{ std.c.getpid(), tmp_random });
    defer std.testing.allocator.free(tmp_name);
    const tmp_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp_name});
    defer std.testing.allocator.free(tmp_path);
    try std.Io.Dir.cwd().createDirPath(compat.io(), tmp_path);
    defer std.Io.Dir.cwd().deleteTree(compat.io(), tmp_path) catch {};

    const script =
        \\#!/bin/sh
        \\if [ "$1" = "context" ]; then
        \\  echo "<lucid-context>"
        \\  echo "- [decision] Contract lucid projection works"
        \\  echo "</lucid-context>"
        \\  exit 0
        \\fi
        \\if [ "$1" = "store" ]; then
        \\  exit 0
        \\fi
        \\exit 1
        \\
    ;
    const command = try std.fmt.allocPrint(std.testing.allocator, "{s}/lucid", .{tmp_path});
    defer std.testing.allocator.free(command);
    var file = try std.Io.Dir.cwd().createFile(compat.io(), command, .{ .read = true });
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.File.Writer = .init(file, compat.io(), &buffer);
    try writer.interface.writeAll(script);
    try writer.interface.flush();
    try file.setPermissions(compat.io(), .executable_file);
    file.close(compat.io());

    var runtime = Runtime.init(.{
        .enabled = true,
        .command = command,
        .workspace_dir = ".",
        .project_scopes_json = "[\"public\"]",
        .result_scope = "public",
        .recall_timeout_ms = 10_000,
        .store_timeout_ms = 10_000,
        .failure_cooldown_ms = 0,
    });
    try runtime.storeAgentMemory(std.testing.allocator, "pref.lang", "User prefers Zig", "core", "public", "[]");
    const entries = try runtime.context(std.testing.allocator, "projection");
    defer freeEntries(std.testing.allocator, entries);

    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("Contract lucid projection works", entries[0].content);
}
