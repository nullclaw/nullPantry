const std = @import("std");
const build_options = @import("build_options");
const test_imports = @import("test_imports.zig");

test {
    test_imports.importFullImportSuite();
}

test "minimal profile includes local baseline engines" {
    if (std.mem.eql(u8, build_options.engine_profile, "minimal")) {
        try std.testing.expect(build_options.enable_engine_none);
        try std.testing.expect(build_options.enable_engine_sqlite);
        try std.testing.expect(build_options.enable_engine_memory_lru);
    }
}
