const std = @import("std");
const Store = @import("store.zig").Store;
const json = @import("json_util.zig");
const retrieval = @import("retrieval.zig");
const lifecycle = @import("lifecycle.zig");
const vector_mod = @import("vector.zig");
const runtime_config = @import("runtime_config.zig");

pub const Context = struct {
    allocator: std.mem.Allocator,
    store: *Store,
    required_token: ?[]const u8 = null,
    token_principals_json: ?[]const u8 = null,
    actor_id: []const u8 = runtime_config.local_actor_id,
    feed_instance_id: []const u8 = "nullpantry",
    actor_scopes_json: []const u8 = runtime_config.admin_scopes_json,
    actor_capabilities_json: []const u8 = runtime_config.admin_capabilities_json,
    provider: runtime_config.ProviderConfig = .{},
    filesystem_root: []const u8 = runtime_config.default_filesystem_root,
    trust_actor_headers: bool = false,
    adaptive_keyword_max_tokens: u32 = retrieval.default_adaptive_keyword_max_tokens,
    adaptive_vector_min_tokens: u32 = retrieval.default_adaptive_vector_min_tokens,
    retrieval_rollout_policy: lifecycle.RolloutPolicy = .{ .mode = .on, .salt = "retrieval" },
    chunker: vector_mod.ChunkerConfig = .{},
};

pub const HttpResponse = json.HttpResponse;

test "api context defaults to local admin development principal" {
    const ctx = Context{
        .allocator = std.testing.allocator,
        .store = undefined,
    };
    try std.testing.expectEqualStrings(runtime_config.local_actor_id, ctx.actor_id);
    try std.testing.expectEqualStrings(runtime_config.admin_scopes_json, ctx.actor_scopes_json);
    try std.testing.expectEqualStrings(runtime_config.admin_capabilities_json, ctx.actor_capabilities_json);
}
