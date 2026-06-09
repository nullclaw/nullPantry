const std = @import("std");
const agent_memory_config = @import("agent_memory_config.zig");
const vector_runtime = @import("vector_runtime.zig");
const analytics_runtime = @import("analytics_runtime.zig");
const lucid_runtime = @import("lucid_runtime.zig");
const graph_runtime = @import("graph_runtime.zig");

pub const BackendKind = enum {
    sqlite,
    postgres,

    pub fn parse(value: []const u8) !BackendKind {
        if (std.ascii.eqlIgnoreCase(value, "sqlite")) return .sqlite;
        if (std.ascii.eqlIgnoreCase(value, "postgres")) return .postgres;
        return error.InvalidStoreBackend;
    }
};

pub const StoreOptions = struct {
    agent_memory: agent_memory_config.Config = .{},
    agent_memory_stores: []const agent_memory_config.NamedConfig = &.{},
    vector_backend: vector_runtime.Config = .{},
    vector_stores: []const vector_runtime.NamedConfig = &.{},
    graph_projection: graph_runtime.Config = .{},
    analytics_backend: analytics_runtime.Config = .{},
    lucid_projection: lucid_runtime.Config = .{},
    run_legacy_compat_cleanup: bool = false,
};

test "store backend parser fails closed on unknown names" {
    try std.testing.expectEqual(BackendKind.sqlite, try BackendKind.parse("sqlite"));
    try std.testing.expectEqual(BackendKind.postgres, try BackendKind.parse("postgres"));
    try std.testing.expectError(error.InvalidStoreBackend, BackendKind.parse("unknown"));
}
