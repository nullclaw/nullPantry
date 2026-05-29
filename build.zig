const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const app_version = b.option([]const u8, "version", "Version string embedded in the binary") orelse "2026.5.26";

    const sqlite3_dep = b.dependency("sqlite3", .{
        .target = target,
        .optimize = optimize,
    });
    const sqlite3_lib = sqlite3_dep.artifact("sqlite3");
    sqlite3_lib.root_module.addCMacro("SQLITE_ENABLE_FTS5", "1");

    var options = b.addOptions();
    options.addOption([]const u8, "version", app_version);
    const options_module = options.createModule();

    const exe = b.addExecutable(.{
        .name = "nullpantry",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("build_options", options_module);
    exe.root_module.linkLibrary(sqlite3_lib);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run nullpantry");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addImport("build_options", options_module);
    tests.root_module.linkLibrary(sqlite3_lib);
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit and integration tests");
    test_step.dependOn(&run_tests.step);

    const postgres_contract_cmd = b.addRunArtifact(tests);
    postgres_contract_cmd.setEnvironmentVariable("NULLPANTRY_REQUIRE_POSTGRES_TEST", "1");
    const postgres_contract_step = b.step("postgres-contract", "Run the required Postgres/pgvector storage contract with NULLPANTRY_TEST_POSTGRES_URL");
    postgres_contract_step.dependOn(&postgres_contract_cmd.step);

    const redis_contract_cmd = b.addRunArtifact(tests);
    redis_contract_cmd.setEnvironmentVariable("NULLPANTRY_REQUIRE_REDIS_TEST", "1");
    const redis_contract_step = b.step("redis-contract", "Run the Redis agent-memory contract with NULLPANTRY_TEST_REDIS_URL");
    redis_contract_step.dependOn(&redis_contract_cmd.step);
}
