const test_imports = @import("test_imports.zig");

comptime {
    test_imports.importFullImportSuite();
}

pub fn main() void {}
