const std = @import("std");
const build_options = @import("build_options");
const api_routes = @import("api_routes.zig");
const engines = @import("engines.zig");
const test_imports = @import("test_imports.zig");

test {
    test_imports.importProfileSmokeSuite();
}

test "profile import root covers route and engine metadata" {
    try std.testing.expect(api_routes.routes.len > 0);
    try std.testing.expect(engines.descriptors.len > 0);

    var enabled_count: usize = 0;
    for (engines.descriptors) |descriptor| {
        if (engines.kindEnabled(descriptor.kind)) enabled_count += 1;
    }
    try std.testing.expect(enabled_count > 0);
}

test "minimal profile includes local baseline engines" {
    if (!std.mem.eql(u8, build_options.engine_profile, "minimal")) return;

    try std.testing.expect(build_options.enable_engine_none);
    try std.testing.expect(build_options.enable_engine_sqlite);
    try std.testing.expect(build_options.enable_engine_memory_lru);
}
