const std = @import("std");

const EngineSelection = struct {
    enable_none: bool = false,
    enable_sqlite: bool = false,
    enable_markdown: bool = false,
    enable_hybrid: bool = false,
    enable_memory_lru: bool = false,
    enable_kg: bool = false,
    enable_postgres: bool = false,
    enable_redis: bool = false,
    enable_clickhouse: bool = false,
    enable_api_runtime: bool = false,
    enable_supermemory: bool = false,
    enable_openviking: bool = false,
    enable_honcho: bool = false,
    enable_mem0: bool = false,
    enable_hindsight: bool = false,
    enable_retaindb: bool = false,
    enable_byterover: bool = false,
    enable_holographic: bool = false,
    enable_zep: bool = false,
    enable_falkordb: bool = false,
    enable_pgvector: bool = false,
    enable_qdrant: bool = false,
    enable_lancedb: bool = false,
    enable_lancedb_http: bool = false,
    enable_weaviate: bool = false,
    enable_chroma: bool = false,
    enable_opensearch: bool = false,
    enable_neo4j: bool = false,
    enable_lucid: bool = false,
    enable_qmd: bool = false,

    fn enableNullClawBaseline(self: *EngineSelection) void {
        self.enable_none = true;
        self.enable_sqlite = true;
        self.enable_markdown = true;
        self.enable_hybrid = true;
        self.enable_memory_lru = true;
    }

    fn enableMinimal(self: *EngineSelection) void {
        self.enable_none = true;
        self.enable_sqlite = true;
        self.enable_memory_lru = true;
    }

    fn enableAll(self: *EngineSelection) void {
        self.enable_none = true;
        self.enable_sqlite = true;
        self.enable_markdown = true;
        self.enable_hybrid = true;
        self.enable_memory_lru = true;
        self.enable_kg = true;
        self.enable_postgres = true;
        self.enable_redis = true;
        self.enable_clickhouse = true;
        self.enable_api_runtime = true;
        self.enable_supermemory = true;
        self.enable_openviking = true;
        self.enable_honcho = true;
        self.enable_mem0 = true;
        self.enable_hindsight = true;
        self.enable_retaindb = true;
        self.enable_byterover = true;
        self.enable_holographic = true;
        self.enable_zep = true;
        self.enable_falkordb = true;
        self.enable_pgvector = true;
        self.enable_qdrant = true;
        self.enable_lancedb = true;
        self.enable_lancedb_http = true;
        self.enable_weaviate = true;
        self.enable_chroma = true;
        self.enable_opensearch = true;
        self.enable_neo4j = true;
        self.enable_lucid = true;
        self.enable_qmd = true;
    }

    fn finalize(self: *EngineSelection) void {
        if (self.enable_hybrid) {
            self.enable_sqlite = true;
            self.enable_markdown = true;
        }
    }

    fn validate(self: EngineSelection) !void {
        if (!self.enable_sqlite and !self.enable_postgres) {
            std.log.err("NullPantry requires a canonical record store; enable sqlite or postgres", .{});
            return error.InvalidEngineSelection;
        }
    }

    fn disableRecordStores(self: *EngineSelection) void {
        self.enable_sqlite = false;
        self.enable_postgres = false;
        self.enable_hybrid = false;
    }

    fn disableAgentMemoryStores(self: *EngineSelection) void {
        self.enable_none = false;
        self.enable_memory_lru = false;
        self.enable_redis = false;
        self.enable_clickhouse = false;
        self.enable_api_runtime = false;
        self.enable_supermemory = false;
        self.enable_openviking = false;
        self.enable_honcho = false;
        self.enable_mem0 = false;
        self.enable_hindsight = false;
        self.enable_retaindb = false;
        self.enable_byterover = false;
        self.enable_holographic = false;
        self.enable_zep = false;
        self.enable_falkordb = false;
    }

    fn disableVectorStores(self: *EngineSelection) void {
        self.enable_pgvector = false;
        self.enable_qdrant = false;
        self.enable_lancedb = false;
        self.enable_lancedb_http = false;
        self.enable_weaviate = false;
        self.enable_chroma = false;
        self.enable_opensearch = false;
    }
};

const EngineList = enum {
    flat,
    record,
    agent_memory,
    vector,
};

fn defaultEngineSelection(profile: []const u8) !EngineSelection {
    var selection = EngineSelection{};
    if (std.mem.eql(u8, profile, "nullclaw") or std.mem.eql(u8, profile, "base")) {
        selection.enableNullClawBaseline();
    } else if (std.mem.eql(u8, profile, "minimal")) {
        selection.enableMinimal();
    } else if (std.mem.eql(u8, profile, "full") or std.mem.eql(u8, profile, "all")) {
        selection.enableAll();
    } else if (std.mem.eql(u8, profile, "custom")) {
        return selection;
    } else {
        std.log.err("unknown -Dengine-profile '{s}'; use nullclaw, minimal, full, or custom", .{profile});
        return error.InvalidEngineProfile;
    }
    return selection;
}

fn parseEnginesOption(raw: []const u8) !EngineSelection {
    var selection = EngineSelection{};
    try parseEngineList(&selection, raw, .flat);
    return selection;
}

fn parseRecordStoresOption(selection: *EngineSelection, raw: []const u8) !void {
    selection.disableRecordStores();
    try parseEngineList(selection, raw, .record);
}

fn parseAgentMemoryStoresOption(selection: *EngineSelection, raw: []const u8) !void {
    selection.disableAgentMemoryStores();
    try parseEngineList(selection, raw, .agent_memory);
}

fn parseVectorStoresOption(selection: *EngineSelection, raw: []const u8) !void {
    selection.disableVectorStores();
    try parseEngineList(selection, raw, .vector);
}

fn parseEngineList(selection: *EngineSelection, raw: []const u8, list: EngineList) !void {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return emptyEngineListError(list);

    var saw_token = false;
    var it = std.mem.splitScalar(u8, trimmed, ',');
    while (it.next()) |raw_token| {
        const token = std.mem.trim(u8, raw_token, " \t\r\n");
        if (token.len == 0) continue;
        saw_token = true;
        if (!enableEngineToken(selection, token, list)) {
            logUnknownEngineToken(token, list);
            return error.InvalidEngineSelection;
        }
    }
    if (!saw_token) return emptyEngineListError(list);
}

fn enableEngineToken(selection: *EngineSelection, token: []const u8, list: EngineList) bool {
    return switch (list) {
        .flat => enableFlatEngineToken(selection, token),
        .record => enableRecordEngineToken(selection, token),
        .agent_memory => enableAgentMemoryEngineToken(selection, token),
        .vector => enableVectorEngineToken(selection, token),
    };
}

fn enableFlatEngineToken(selection: *EngineSelection, token: []const u8) bool {
    if (tokenIs(token, &.{ "nullclaw", "base" })) {
        selection.enableNullClawBaseline();
    } else if (tokenIs(token, &.{"minimal"})) {
        selection.enableMinimal();
    } else if (tokenIs(token, &.{ "full", "all" })) {
        selection.enableAll();
    } else if (enableRecordEngineToken(selection, token)) {
        return true;
    } else if (tokenIs(token, &.{"markdown"})) {
        selection.enable_markdown = true;
    } else if (tokenIs(token, &.{ "hybrid", "sqlite_markdown" })) {
        selection.enable_hybrid = true;
    } else if (enableAgentMemoryEngineToken(selection, token)) {
        return true;
    } else if (tokenIs(token, &.{"kg"})) {
        selection.enable_kg = true;
    } else if (enableVectorEngineToken(selection, token)) {
        return true;
    } else if (tokenIs(token, &.{"neo4j"})) {
        selection.enable_neo4j = true;
    } else if (tokenIs(token, &.{"lucid"})) {
        selection.enable_lucid = true;
    } else if (tokenIs(token, &.{"qmd"})) {
        selection.enable_qmd = true;
    } else {
        return false;
    }
    return true;
}

fn enableRecordEngineToken(selection: *EngineSelection, token: []const u8) bool {
    if (tokenIs(token, &.{"sqlite"})) {
        selection.enable_sqlite = true;
    } else if (tokenIs(token, &.{"postgres"})) {
        selection.enable_postgres = true;
    } else {
        return false;
    }
    return true;
}

fn enableAgentMemoryEngineToken(selection: *EngineSelection, token: []const u8) bool {
    if (tokenIs(token, &.{"none"})) {
        selection.enable_none = true;
    } else if (tokenIs(token, &.{ "memory", "memory_lru", "in_memory" })) {
        selection.enable_memory_lru = true;
    } else if (tokenIs(token, &.{"redis"})) {
        selection.enable_redis = true;
    } else if (tokenIs(token, &.{"clickhouse"})) {
        selection.enable_clickhouse = true;
    } else if (tokenIs(token, &.{ "api", "api-runtime", "nullpantry_api" })) {
        selection.enable_api_runtime = true;
    } else if (tokenIs(token, &.{"supermemory"})) {
        selection.enable_supermemory = true;
    } else if (tokenIs(token, &.{ "openviking", "openviking_api" })) {
        selection.enable_openviking = true;
    } else if (tokenIs(token, &.{ "honcho", "honcho_api" })) {
        selection.enable_honcho = true;
    } else if (tokenIs(token, &.{ "mem0", "mem0_api" })) {
        selection.enable_mem0 = true;
    } else if (tokenIs(token, &.{ "hindsight", "hindsight_api" })) {
        selection.enable_hindsight = true;
    } else if (tokenIs(token, &.{ "retaindb", "retaindb_api", "retain_db" })) {
        selection.enable_retaindb = true;
    } else if (tokenIs(token, &.{ "byterover", "byterover_cli", "brv" })) {
        selection.enable_byterover = true;
    } else if (tokenIs(token, &.{ "holographic", "holographic_sqlite" })) {
        selection.enable_holographic = true;
    } else if (tokenIs(token, &.{ "zep", "zep_api" })) {
        selection.enable_zep = true;
    } else if (tokenIs(token, &.{ "falkordb", "falkor", "falkordb_graph" })) {
        selection.enable_falkordb = true;
    } else {
        return false;
    }
    return true;
}

fn enableVectorEngineToken(selection: *EngineSelection, token: []const u8) bool {
    if (tokenIs(token, &.{"none"})) {
        return true;
    } else if (tokenIs(token, &.{"pgvector"})) {
        selection.enable_pgvector = true;
    } else if (tokenIs(token, &.{"qdrant"})) {
        selection.enable_qdrant = true;
    } else if (tokenIs(token, &.{"lancedb"})) {
        selection.enable_lancedb = true;
    } else if (tokenIs(token, &.{ "lancedb_http", "lancedb-http", "lancedb-compatible" })) {
        selection.enable_lancedb_http = true;
    } else if (tokenIs(token, &.{"weaviate"})) {
        selection.enable_weaviate = true;
    } else if (tokenIs(token, &.{"chroma"})) {
        selection.enable_chroma = true;
    } else if (tokenIs(token, &.{ "opensearch", "open_search" })) {
        selection.enable_opensearch = true;
    } else {
        return false;
    }
    return true;
}

fn tokenIs(token: []const u8, aliases: []const []const u8) bool {
    for (aliases) |alias| {
        if (std.mem.eql(u8, token, alias)) return true;
    }
    return false;
}

fn emptyEngineListError(list: EngineList) error{InvalidEngineSelection} {
    switch (list) {
        .flat => std.log.err("empty -Dengines list; use e.g. -Dengines=nullclaw or -Dengines=sqlite,markdown,memory", .{}),
        .record => std.log.err("empty -Drecords list; use sqlite, postgres, or sqlite,postgres", .{}),
        .agent_memory => std.log.err("empty -Dagent-memory list", .{}),
        .vector => std.log.err("empty -Dvectors list", .{}),
    }
    return error.InvalidEngineSelection;
}

fn logUnknownEngineToken(token: []const u8, list: EngineList) void {
    switch (list) {
        .flat => std.log.err("unknown engine '{s}' in -Dengines list", .{token}),
        .record => std.log.err("unknown record store '{s}' in -Drecords; use sqlite or postgres", .{token}),
        .agent_memory => std.log.err("unknown agent memory store '{s}' in -Dagent-memory", .{token}),
        .vector => std.log.err("unknown vector store '{s}' in -Dvectors", .{token}),
    }
}

fn boolBuildOption(b: *std.Build, name: []const u8, description: []const u8, current: bool) bool {
    return b.option(bool, name, description) orelse current;
}

fn profileIsMinimal(profile: []const u8) bool {
    return std.mem.eql(u8, profile, "minimal");
}

fn profileIsFull(profile: []const u8) bool {
    return std.mem.eql(u8, profile, "full") or std.mem.eql(u8, profile, "all");
}

fn resolveFullImportTests(profile: []const u8, requested: ?bool) bool {
    if (profileIsMinimal(profile)) return false;
    return requested orelse profileIsFull(profile);
}

fn resolveServerTests(requested: ?bool) bool {
    return requested orelse false;
}

fn recursiveProfileRunsServerTests(profile: []const u8) bool {
    return !profileIsMinimal(profile);
}

fn recursiveProfileRunsFullImportTests(profile: []const u8) bool {
    return profileIsFull(profile);
}

fn addRecursiveProfileTestStep(
    b: *std.Build,
    name: []const u8,
    description: []const u8,
    profile: []const u8,
    test_filter: ?[]const u8,
) *std.Build.Step {
    const step = b.step(name, description);
    const cmd = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "test" });
    cmd.addArg(b.fmt("-Dengine-profile={s}", .{profile}));
    cmd.addArg(if (recursiveProfileRunsServerTests(profile)) "-Dserver-tests=true" else "-Dserver-tests=false");
    cmd.addArg(if (recursiveProfileRunsFullImportTests(profile)) "-Dfull-import-tests=true" else "-Dfull-import-tests=false");
    if (test_filter) |filter| cmd.addArg(b.fmt("-Dtest-filter={s}", .{filter}));
    step.dependOn(&cmd.step);
    return step;
}

fn addRecursiveFilteredServerTestStep(
    b: *std.Build,
    name: []const u8,
    description: []const u8,
    profile: []const u8,
    filters: []const []const u8,
) *std.Build.Step {
    const step = b.step(name, description);
    for (filters) |filter| {
        const cmd = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "test-server" });
        cmd.addArg(b.fmt("-Dengine-profile={s}", .{profile}));
        cmd.addArg(b.fmt("-Dtest-filter={s}", .{filter}));
        step.dependOn(&cmd.step);
    }
    return step;
}

fn addRecursiveContractServerTestStep(
    b: *std.Build,
    name: []const u8,
    description: []const u8,
    require_env_name: ?[]const u8,
    build_args: []const []const u8,
    filters: []const []const u8,
) *std.Build.Step {
    const step = b.step(name, description);
    for (filters) |filter| {
        const cmd = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "test-server" });
        for (build_args) |arg| cmd.addArg(arg);
        cmd.addArg(b.fmt("-Dtest-filter={s}", .{filter}));
        if (require_env_name) |name_| cmd.setEnvironmentVariable(name_, "1");
        step.dependOn(&cmd.step);
    }
    return step;
}

test "engine list keeps lancedb sdk and http adapter explicit" {
    const selected = try parseEnginesOption("sqlite,lancedb");
    try std.testing.expect(selected.enable_sqlite);
    try std.testing.expect(selected.enable_lancedb);
    try std.testing.expect(!selected.enable_lancedb_http);

    const adapter = try parseEnginesOption("sqlite,lancedb_http");
    try std.testing.expect(!adapter.enable_lancedb);
    try std.testing.expect(adapter.enable_lancedb_http);
}

test "vector store list keeps lancedb sdk and http adapter explicit" {
    var selected = EngineSelection{};
    try parseVectorStoresOption(&selected, "lancedb");
    try std.testing.expect(selected.enable_lancedb);
    try std.testing.expect(!selected.enable_lancedb_http);

    var adapter = EngineSelection{};
    try parseVectorStoresOption(&adapter, "lancedb_http");
    try std.testing.expect(!adapter.enable_lancedb);
    try std.testing.expect(adapter.enable_lancedb_http);
}

test "store-specific engine lists reset only their own list" {
    var selected = try parseEnginesOption("full");

    try parseRecordStoresOption(&selected, "postgres");
    try std.testing.expect(!selected.enable_sqlite);
    try std.testing.expect(!selected.enable_hybrid);
    try std.testing.expect(selected.enable_postgres);
    try std.testing.expect(selected.enable_redis);
    try std.testing.expect(selected.enable_qdrant);

    try parseAgentMemoryStoresOption(&selected, "memory,none");
    try std.testing.expect(selected.enable_postgres);
    try std.testing.expect(selected.enable_memory_lru);
    try std.testing.expect(selected.enable_none);
    try std.testing.expect(!selected.enable_redis);
    try std.testing.expect(!selected.enable_supermemory);
    try std.testing.expect(!selected.enable_zep);
    try std.testing.expect(!selected.enable_falkordb);
    try std.testing.expect(selected.enable_qdrant);

    try parseVectorStoresOption(&selected, "none");
    try std.testing.expect(selected.enable_postgres);
    try std.testing.expect(selected.enable_memory_lru);
    try std.testing.expect(!selected.enable_qdrant);
    try std.testing.expect(!selected.enable_lancedb);
    try std.testing.expect(!selected.enable_weaviate);
    try std.testing.expect(!selected.enable_chroma);
    try std.testing.expect(!selected.enable_opensearch);
}

test "backend-specific engine token classifier rejects engines from the wrong list" {
    var selected = EngineSelection{};
    try std.testing.expect(!enableEngineToken(&selected, "redis", .record));
    try std.testing.expect(!enableEngineToken(&selected, "pgvector", .agent_memory));
    try std.testing.expect(!enableEngineToken(&selected, "postgres", .vector));
    try std.testing.expect(!enableEngineToken(&selected, "weaviate", .agent_memory));
}

test "new external memory vector and graph engine tokens are selectable" {
    const selected = try parseEnginesOption("sqlite,zep,falkordb,weaviate,chroma,opensearch,neo4j");
    try std.testing.expect(selected.enable_sqlite);
    try std.testing.expect(selected.enable_zep);
    try std.testing.expect(selected.enable_falkordb);
    try std.testing.expect(selected.enable_weaviate);
    try std.testing.expect(selected.enable_chroma);
    try std.testing.expect(selected.enable_opensearch);
    try std.testing.expect(selected.enable_neo4j);

    var agent_memory = EngineSelection{};
    try parseAgentMemoryStoresOption(&agent_memory, "zep,falkordb");
    try std.testing.expect(agent_memory.enable_zep);
    try std.testing.expect(agent_memory.enable_falkordb);

    var vectors = EngineSelection{};
    try parseVectorStoresOption(&vectors, "weaviate,chroma,opensearch");
    try std.testing.expect(vectors.enable_weaviate);
    try std.testing.expect(vectors.enable_chroma);
    try std.testing.expect(vectors.enable_opensearch);
}

test "minimal engine profile is local and in-process by default" {
    const selected = try defaultEngineSelection("minimal");
    try std.testing.expect(selected.enable_none);
    try std.testing.expect(selected.enable_sqlite);
    try std.testing.expect(selected.enable_memory_lru);
    try std.testing.expect(!selected.enable_markdown);
    try std.testing.expect(!selected.enable_qmd);
    try std.testing.expect(!selected.enable_redis);
}

test "minimal engine profile never pulls aggregate full import tests" {
    try std.testing.expect(!resolveFullImportTests("minimal", null));
    try std.testing.expect(!resolveFullImportTests("minimal", false));
    try std.testing.expect(!resolveFullImportTests("minimal", true));
    try std.testing.expect(!resolveFullImportTests("nullclaw", null));
    try std.testing.expect(resolveFullImportTests("nullclaw", true));
    try std.testing.expect(resolveFullImportTests("full", null));
    try std.testing.expect(!resolveFullImportTests("full", false));
    try std.testing.expect(resolveFullImportTests("all", null));
}

test "default test step keeps server entrypoint tests opt-in" {
    try std.testing.expect(!resolveServerTests(null));
    try std.testing.expect(!resolveServerTests(false));
    try std.testing.expect(resolveServerTests(true));
}

test "recursive profile test steps preserve intended coverage" {
    try std.testing.expect(!recursiveProfileRunsServerTests("minimal"));
    try std.testing.expect(recursiveProfileRunsServerTests("nullclaw"));
    try std.testing.expect(recursiveProfileRunsServerTests("full"));
    try std.testing.expect(recursiveProfileRunsServerTests("all"));

    try std.testing.expect(!recursiveProfileRunsFullImportTests("minimal"));
    try std.testing.expect(!recursiveProfileRunsFullImportTests("nullclaw"));
    try std.testing.expect(recursiveProfileRunsFullImportTests("full"));
    try std.testing.expect(recursiveProfileRunsFullImportTests("all"));
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const app_version = b.option([]const u8, "version", "Version string embedded in the binary") orelse "2026.5.26";
    const test_filter = b.option([]const u8, "test-filter", "Only compile and run tests whose name contains this text");
    const test_filters: []const []const u8 = if (test_filter) |filter| &.{filter} else &.{};
    const engine_profile = b.option([]const u8, "engine-profile", "Engine preset: nullclaw, minimal, full, or custom") orelse "nullclaw";
    const minimal_profile = profileIsMinimal(engine_profile);
    const requested_full_import_tests = b.option(bool, "full-import-tests", "Run the aggregate import smoke test. Ignored for -Dengine-profile=minimal. Defaults on for -Dengine-profile=full.");
    const full_import_tests = resolveFullImportTests(engine_profile, requested_full_import_tests);
    const server_tests = resolveServerTests(b.option(bool, "server-tests", "Run src/main.zig server entrypoint tests as part of `zig build test`. Defaults off; use `zig build test-local` for the full local suite."));
    if (minimal_profile and (requested_full_import_tests orelse false)) {
        std.log.warn("-Dfull-import-tests=true is ignored for -Dengine-profile=minimal; use `zig build test-full-engine` for the full suite", .{});
    }
    const engines_raw = b.option([]const u8, "engines", "Comma-separated engine list. Tokens: nullclaw|minimal|full|none|sqlite|markdown|hybrid|memory|kg|postgres|redis|clickhouse|api|supermemory|openviking|honcho|mem0|hindsight|retaindb|byterover|holographic|zep|falkordb|pgvector|qdrant|lancedb|lancedb_http|weaviate|chroma|opensearch|neo4j|lucid|qmd");
    const records_raw = b.option([]const u8, "records", "Comma-separated canonical record stores: sqlite|postgres. These store Source/Artifact/MemoryAtom/Entity/Relation records.");
    const agent_memory_raw = b.option([]const u8, "agent-memory", "Comma-separated agent memory stores: none|memory|redis|clickhouse|api|supermemory|openviking|honcho|mem0|hindsight|retaindb|byterover|holographic|zep|falkordb.");
    const vectors_raw = b.option([]const u8, "vectors", "Comma-separated rebuildable vector indexes: none|pgvector|qdrant|lancedb|lancedb_http|weaviate|chroma|opensearch.");
    var engines = if (engines_raw) |raw| parseEnginesOption(raw) catch {
        std.process.exit(1);
    } else defaultEngineSelection(engine_profile) catch {
        std.process.exit(1);
    };

    if (records_raw) |raw| parseRecordStoresOption(&engines, raw) catch std.process.exit(1);
    if (agent_memory_raw) |raw| parseAgentMemoryStoresOption(&engines, raw) catch std.process.exit(1);
    if (vectors_raw) |raw| parseVectorStoresOption(&engines, raw) catch std.process.exit(1);

    engines.enable_none = boolBuildOption(b, "enable-none", "Compile-enable the disabled/no-op memory runtime", engines.enable_none);
    engines.enable_sqlite = boolBuildOption(b, "enable-sqlite", "Compile-enable the SQLite record store", engines.enable_sqlite);
    engines.enable_markdown = boolBuildOption(b, "enable-markdown", "Compile-enable Markdown import/export surfaces", engines.enable_markdown);
    engines.enable_hybrid = boolBuildOption(b, "enable-hybrid", "Compile-enable the SQLite+Markdown compatibility engine descriptor", engines.enable_hybrid);
    engines.enable_memory_lru = boolBuildOption(b, "enable-memory-lru", "Compile-enable the in-process LRU agent-memory runtime", engines.enable_memory_lru);
    engines.enable_kg = boolBuildOption(b, "enable-kg", "Compile-enable the native knowledge graph compatibility backend", engines.enable_kg);
    engines.enable_postgres = boolBuildOption(b, "enable-postgres", "Compile-enable the Postgres record store", engines.enable_postgres);
    engines.enable_redis = boolBuildOption(b, "enable-redis", "Compile-enable the Redis agent-memory runtime", engines.enable_redis);
    engines.enable_clickhouse = boolBuildOption(b, "enable-clickhouse", "Compile-enable ClickHouse agent-memory and analytics runtimes", engines.enable_clickhouse);
    engines.enable_api_runtime = boolBuildOption(b, "enable-api-runtime", "Compile-enable the remote NullPantry-compatible API runtime", engines.enable_api_runtime);
    engines.enable_supermemory = boolBuildOption(b, "enable-supermemory", "Compile-enable the Supermemory runtime profile", engines.enable_supermemory);
    engines.enable_openviking = boolBuildOption(b, "enable-openviking", "Compile-enable the OpenViking runtime profile", engines.enable_openviking);
    engines.enable_honcho = boolBuildOption(b, "enable-honcho", "Compile-enable the Honcho runtime profile", engines.enable_honcho);
    engines.enable_mem0 = boolBuildOption(b, "enable-mem0", "Compile-enable the Mem0 runtime profile", engines.enable_mem0);
    engines.enable_hindsight = boolBuildOption(b, "enable-hindsight", "Compile-enable the Hindsight runtime profile", engines.enable_hindsight);
    engines.enable_retaindb = boolBuildOption(b, "enable-retaindb", "Compile-enable the RetainDB runtime profile", engines.enable_retaindb);
    engines.enable_byterover = boolBuildOption(b, "enable-byterover", "Compile-enable the ByteRover CLI runtime profile", engines.enable_byterover);
    engines.enable_holographic = boolBuildOption(b, "enable-holographic", "Compile-enable the local Holographic SQLite/FTS agent-memory runtime", engines.enable_holographic);
    engines.enable_zep = boolBuildOption(b, "enable-zep", "Compile-enable the Zep temporal graph agent-memory runtime profile", engines.enable_zep);
    engines.enable_falkordb = boolBuildOption(b, "enable-falkordb", "Compile-enable the FalkorDB graph agent-memory runtime profile", engines.enable_falkordb);
    engines.enable_pgvector = boolBuildOption(b, "enable-pgvector", "Compile-enable pgvector runtime", engines.enable_pgvector);
    engines.enable_qdrant = boolBuildOption(b, "enable-qdrant", "Compile-enable Qdrant runtime", engines.enable_qdrant);
    engines.enable_lancedb = boolBuildOption(b, "enable-lancedb", "Compile-enable the LanceDB SDK runtime", engines.enable_lancedb);
    engines.enable_lancedb_http = boolBuildOption(b, "enable-lancedb-http", "Compile-enable the LanceDB-compatible HTTP runtime", engines.enable_lancedb_http);
    engines.enable_weaviate = boolBuildOption(b, "enable-weaviate", "Compile-enable the Weaviate vector/search runtime", engines.enable_weaviate);
    engines.enable_chroma = boolBuildOption(b, "enable-chroma", "Compile-enable the Chroma vector/search runtime", engines.enable_chroma);
    engines.enable_opensearch = boolBuildOption(b, "enable-opensearch", "Compile-enable the OpenSearch vector/search runtime", engines.enable_opensearch);
    engines.enable_neo4j = boolBuildOption(b, "enable-neo4j", "Compile-enable the Neo4j graph projection runtime", engines.enable_neo4j);
    engines.enable_lucid = boolBuildOption(b, "enable-lucid", "Compile-enable Lucid projection runtime", engines.enable_lucid);
    engines.enable_qmd = boolBuildOption(b, "enable-qmd", "Compile-enable QMD connector surface", engines.enable_qmd);
    engines.finalize();
    engines.validate() catch {
        std.process.exit(1);
    };
    const enable_nullclaw_adapter = b.option(bool, "enable-nullclaw-adapter", "Compile-enable NullClaw compatibility adapter routes") orelse true;

    const sqlite3_dep = b.dependency("sqlite3", .{
        .target = target,
        .optimize = optimize,
    });
    const sqlite3_lib = sqlite3_dep.artifact("sqlite3");
    sqlite3_lib.root_module.addCMacro("SQLITE_ENABLE_FTS5", "1");

    var options = b.addOptions();
    options.addOption([]const u8, "version", app_version);
    options.addOption([]const u8, "engine_profile", engine_profile);
    options.addOption([]const u8, "engine_selection", engines_raw orelse engine_profile);
    options.addOption([]const u8, "records_selection", records_raw orelse "");
    options.addOption([]const u8, "agent_memory_selection", agent_memory_raw orelse "");
    options.addOption([]const u8, "vectors_selection", vectors_raw orelse "");
    options.addOption(bool, "enable_engine_none", engines.enable_none);
    options.addOption(bool, "enable_engine_sqlite", engines.enable_sqlite);
    options.addOption(bool, "enable_engine_markdown", engines.enable_markdown);
    options.addOption(bool, "enable_engine_hybrid", engines.enable_hybrid);
    options.addOption(bool, "enable_engine_memory_lru", engines.enable_memory_lru);
    options.addOption(bool, "enable_engine_kg", engines.enable_kg);
    options.addOption(bool, "enable_engine_postgres", engines.enable_postgres);
    options.addOption(bool, "enable_engine_redis", engines.enable_redis);
    options.addOption(bool, "enable_engine_clickhouse", engines.enable_clickhouse);
    options.addOption(bool, "enable_engine_api", engines.enable_api_runtime);
    options.addOption(bool, "enable_engine_supermemory", engines.enable_supermemory);
    options.addOption(bool, "enable_engine_openviking", engines.enable_openviking);
    options.addOption(bool, "enable_engine_honcho", engines.enable_honcho);
    options.addOption(bool, "enable_engine_mem0", engines.enable_mem0);
    options.addOption(bool, "enable_engine_hindsight", engines.enable_hindsight);
    options.addOption(bool, "enable_engine_retaindb", engines.enable_retaindb);
    options.addOption(bool, "enable_engine_byterover", engines.enable_byterover);
    options.addOption(bool, "enable_engine_holographic", engines.enable_holographic);
    options.addOption(bool, "enable_engine_zep", engines.enable_zep);
    options.addOption(bool, "enable_engine_falkordb", engines.enable_falkordb);
    options.addOption(bool, "enable_engine_pgvector", engines.enable_pgvector);
    options.addOption(bool, "enable_engine_qdrant", engines.enable_qdrant);
    options.addOption(bool, "enable_engine_lancedb", engines.enable_lancedb);
    options.addOption(bool, "enable_engine_lancedb_http", engines.enable_lancedb_http);
    options.addOption(bool, "enable_engine_weaviate", engines.enable_weaviate);
    options.addOption(bool, "enable_engine_chroma", engines.enable_chroma);
    options.addOption(bool, "enable_engine_opensearch", engines.enable_opensearch);
    options.addOption(bool, "enable_engine_neo4j", engines.enable_neo4j);
    options.addOption(bool, "enable_engine_lucid", engines.enable_lucid);
    options.addOption(bool, "enable_engine_qmd", engines.enable_qmd);
    options.addOption(bool, "enable_nullclaw_adapter", enable_nullclaw_adapter);
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

    const server_entrypoint_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = test_filters,
    });
    server_entrypoint_tests.root_module.addImport("build_options", options_module);
    server_entrypoint_tests.root_module.linkLibrary(sqlite3_lib);
    const run_server_entrypoint_tests = b.addRunArtifact(server_entrypoint_tests);
    const server_test_step = b.step("test-server", "Run server entrypoint tests from src/main.zig");
    server_test_step.dependOn(&run_server_entrypoint_tests.step);

    const aggregate_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/all_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = test_filters,
    });
    aggregate_tests.root_module.addImport("build_options", options_module);
    aggregate_tests.root_module.linkLibrary(sqlite3_lib);
    const run_aggregate_tests = b.addRunArtifact(aggregate_tests);
    const full_import_step = b.step("test-full-import", "Run aggregate module import smoke tests for non-minimal profiles");

    const import_smoke = b.addExecutable(.{
        .name = "nullpantry-import-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/import_smoke.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    import_smoke.root_module.addImport("build_options", options_module);
    import_smoke.root_module.linkLibrary(sqlite3_lib);
    const check_full_import_step = b.step("check-full-import", "Compile aggregate module import smoke without running module tests for non-minimal profiles");

    const profile_import_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/profile_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = test_filters,
    });
    profile_import_tests.root_module.addImport("build_options", options_module);
    profile_import_tests.root_module.linkLibrary(sqlite3_lib);
    const run_profile_import_tests = b.addRunArtifact(profile_import_tests);
    const profile_import_step = b.step("test-profile", "Run profile-aware module import smoke tests");
    profile_import_step.dependOn(&run_profile_import_tests.step);
    if (minimal_profile) {
        full_import_step.dependOn(&run_profile_import_tests.step);
        check_full_import_step.dependOn(&profile_import_tests.step);
    } else {
        full_import_step.dependOn(&run_aggregate_tests.step);
        check_full_import_step.dependOn(&import_smoke.step);
    }

    const build_config_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("build.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = test_filters,
    });
    const run_build_config_tests = b.addRunArtifact(build_config_tests);
    const fast_test_step = b.step("test-fast", "Run fast local build/profile tests");
    fast_test_step.dependOn(&run_build_config_tests.step);
    fast_test_step.dependOn(&run_profile_import_tests.step);

    const local_test_step = b.step("test-local", "Run fast tests plus server/API/storage local tests");
    local_test_step.dependOn(&run_build_config_tests.step);
    local_test_step.dependOn(&run_profile_import_tests.step);
    local_test_step.dependOn(&run_server_entrypoint_tests.step);

    const all_local_test_step = b.step("test-all-local", "Run local tests plus aggregate import tests");
    all_local_test_step.dependOn(&run_build_config_tests.step);
    all_local_test_step.dependOn(&run_profile_import_tests.step);
    all_local_test_step.dependOn(&run_server_entrypoint_tests.step);
    if (!minimal_profile) all_local_test_step.dependOn(&run_aggregate_tests.step);

    const test_step = b.step("test", "Run fast local tests; opt into server tests with -Dserver-tests=true");
    test_step.dependOn(&run_build_config_tests.step);
    test_step.dependOn(&run_profile_import_tests.step);
    if (server_tests) test_step.dependOn(&run_server_entrypoint_tests.step);
    if (full_import_tests) test_step.dependOn(&run_aggregate_tests.step);

    _ = addRecursiveFilteredServerTestStep(b, "test-api", "Run API route/contract tests", engine_profile, &.{"api"});
    _ = addRecursiveFilteredServerTestStep(b, "test-store", "Run SQLite/storage tests", engine_profile, &.{ "sqlite", "store" });
    _ = addRecursiveFilteredServerTestStep(b, "test-agent-memory", "Run agent memory tests", engine_profile, &.{"agent memory"});
    _ = addRecursiveFilteredServerTestStep(b, "test-vector", "Run vector indexing/runtime tests", engine_profile, &.{"vector"});
    _ = addRecursiveFilteredServerTestStep(b, "test-retrieval", "Run retrieval/ranking tests", engine_profile, &.{"retrieval"});
    _ = addRecursiveFilteredServerTestStep(b, "test-worker", "Run durable worker tests", engine_profile, &.{"worker"});
    _ = addRecursiveFilteredServerTestStep(b, "test-provider", "Run provider/model boundary tests", engine_profile, &.{"provider"});
    _ = addRecursiveFilteredServerTestStep(b, "test-runtime", "Run runtime backend/config tests", engine_profile, &.{"runtime"});

    const fast_minimal_step = addRecursiveProfileTestStep(b, "test-fast-minimal", "Run the fast minimal engine-profile tests", "minimal", test_filter);
    const nullclaw_step = addRecursiveProfileTestStep(b, "test-nullclaw", "Run the default nullclaw engine-profile tests", "nullclaw", test_filter);
    const full_engine_step = addRecursiveProfileTestStep(b, "test-full-engine", "Run the full engine-profile test suite", "full", test_filter);
    const matrix_step = b.step("test-matrix", "Run minimal, nullclaw, and full engine-profile tests");
    matrix_step.dependOn(fast_minimal_step);
    matrix_step.dependOn(nullclaw_step);
    matrix_step.dependOn(full_engine_step);

    const postgres_contract_step = addRecursiveContractServerTestStep(b, "postgres-contract", "Run the required Postgres storage contract with NULLPANTRY_TEST_POSTGRES_URL", "NULLPANTRY_REQUIRE_POSTGRES_TEST", &.{"-Denable-postgres=true"}, &.{"postgres storage contract covers primitives when configured"});
    const pgvector_contract_step = addRecursiveContractServerTestStep(b, "pgvector-contract", "Run the standalone pgvector vector runtime contract with NULLPANTRY_TEST_PGVECTOR_URL", "NULLPANTRY_REQUIRE_PGVECTOR_TEST", &.{"-Denable-pgvector=true"}, &.{"pgvector live vector contract when configured"});
    const redis_contract_step = addRecursiveContractServerTestStep(b, "redis-contract", "Run the Redis agent-memory contract with NULLPANTRY_TEST_REDIS_URL", "NULLPANTRY_REQUIRE_REDIS_TEST", &.{"-Denable-redis=true"}, &.{"redis agent memory contract when configured"});
    const qdrant_contract_step = addRecursiveContractServerTestStep(b, "qdrant-contract", "Run the Qdrant vector runtime contract with NULLPANTRY_TEST_QDRANT_URL", "NULLPANTRY_REQUIRE_QDRANT_TEST", &.{"-Denable-qdrant=true"}, &.{"qdrant live vector contract when configured"});
    const lancedb_contract_step = addRecursiveContractServerTestStep(b, "lancedb-contract", "Run the LanceDB SDK or HTTP vector runtime contract with NULLPANTRY_TEST_LANCEDB_URI or NULLPANTRY_TEST_LANCEDB_URL", "NULLPANTRY_REQUIRE_LANCEDB_TEST", &.{"-Denable-lancedb=true"}, &.{"lancedb live vector contract when configured"});
    const clickhouse_contract_step = addRecursiveContractServerTestStep(b, "clickhouse-contract", "Run the ClickHouse analytics and agent-memory contracts with NULLPANTRY_TEST_CLICKHOUSE_URL", "NULLPANTRY_REQUIRE_CLICKHOUSE_TEST", &.{"-Denable-clickhouse=true"}, &.{ "agent memory clickhouse live contract when configured", "clickhouse analytics live contract when configured" });
    const lucid_contract_step = addRecursiveContractServerTestStep(b, "lucid-contract", "Run the Lucid projection runtime contracts with a fake Lucid CLI", null, &.{"-Denable-lucid=true"}, &.{ "lucid projection CLI contract with fake command", "worker processes durable Lucid projection jobs" });

    const runtime_contracts_step = b.step("runtime-contracts", "Run concrete external runtime contracts when their services are configured");
    runtime_contracts_step.dependOn(postgres_contract_step);
    runtime_contracts_step.dependOn(pgvector_contract_step);
    runtime_contracts_step.dependOn(redis_contract_step);
    runtime_contracts_step.dependOn(qdrant_contract_step);
    runtime_contracts_step.dependOn(lancedb_contract_step);
    runtime_contracts_step.dependOn(clickhouse_contract_step);
    runtime_contracts_step.dependOn(lucid_contract_step);
}
