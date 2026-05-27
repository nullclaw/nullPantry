const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat.zig");

const statement_timeout_ms = 30_000;
const default_libpq_idle_pool_size = 8;
const max_libpq_idle_pool_size = 128;

const supports_dynamic_libpq = switch (builtin.os.tag) {
    .linux,
    .driverkit,
    .ios,
    .maccatalyst,
    .macos,
    .tvos,
    .visionos,
    .watchos,
    .freebsd,
    .netbsd,
    .openbsd,
    .dragonfly,
    .illumos,
    => true,
    else => false,
};

pub fn withConnectTimeout(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    if (!std.mem.startsWith(u8, url, "postgres://") and !std.mem.startsWith(u8, url, "postgresql://")) {
        return allocator.dupe(u8, url);
    }
    if (std.mem.indexOf(u8, url, "connect_timeout=") != null) {
        return allocator.dupe(u8, url);
    }
    const sep: []const u8 = if (std.mem.indexOfScalar(u8, url, '?') == null) "?" else "&";
    return std.fmt.allocPrint(allocator, "{s}{s}connect_timeout=10", .{ url, sep });
}

pub const TransportKind = enum {
    libpq,
    psql,
};

pub fn parseTransportKind(raw: ?[]const u8) !TransportKind {
    const value = std.mem.trim(u8, raw orelse return .libpq, " \t\r\n");
    if (value.len == 0) return .libpq;
    if (std.ascii.eqlIgnoreCase(value, "libpq") or std.ascii.eqlIgnoreCase(value, "native")) return .libpq;
    if (std.ascii.eqlIgnoreCase(value, "psql")) return .psql;
    return error.InvalidPostgresTransport;
}

fn configuredTransportKind(allocator: std.mem.Allocator) !TransportKind {
    const raw = compat.process.getEnvVarOwned(allocator, "NULLPANTRY_POSTGRES_TRANSPORT") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return .libpq,
        else => |e| return e,
    };
    defer allocator.free(raw);
    return parseTransportKind(raw);
}

pub const QueryTransport = union(TransportKind) {
    libpq: LibpqTransport,
    psql: PsqlTransport,

    pub fn init(allocator: std.mem.Allocator, url: []const u8) !QueryTransport {
        return switch (try configuredTransportKind(allocator)) {
            .libpq => .{ .libpq = try LibpqTransport.init(allocator, url) },
            .psql => .{ .psql = try PsqlTransport.init(allocator, url) },
        };
    }

    pub fn deinit(self: *QueryTransport) void {
        switch (self.*) {
            .libpq => |*transport| transport.deinit(),
            .psql => |*transport| transport.deinit(),
        }
    }

    pub fn queryRaw(self: *QueryTransport, allocator: std.mem.Allocator, sql: []const u8) ![]u8 {
        return switch (self.*) {
            .libpq => |*transport| transport.queryRaw(allocator, sql),
            .psql => |*transport| transport.queryRaw(allocator, sql),
        };
    }

    pub fn name(self: *const QueryTransport) []const u8 {
        return switch (self.*) {
            .libpq => |*transport| transport.name(),
            .psql => |*transport| transport.name(),
        };
    }
};

const LibpqTransport = if (supports_dynamic_libpq) NativeLibpqTransport else UnsupportedLibpqTransport;

const UnsupportedLibpqTransport = struct {
    pub fn init(allocator: std.mem.Allocator, url: []const u8) !UnsupportedLibpqTransport {
        _ = allocator;
        _ = url;
        return error.LibpqUnavailable;
    }

    pub fn deinit(self: *UnsupportedLibpqTransport) void {
        _ = self;
    }

    pub fn queryRaw(self: *UnsupportedLibpqTransport, allocator: std.mem.Allocator, sql: []const u8) ![]u8 {
        _ = self;
        _ = allocator;
        _ = sql;
        return error.LibpqUnavailable;
    }

    pub fn name(self: *const UnsupportedLibpqTransport) []const u8 {
        _ = self;
        return "libpq";
    }
};

const NativeLibpqTransport = struct {
    allocator: std.mem.Allocator,
    url_z: [:0]const u8,
    lib: NativeLibpqLibrary,
    idle_connections: std.ArrayListUnmanaged(*PGconn) = .empty,
    max_idle_connections: usize,
    mutex: std.Io.Mutex = .init,

    pub fn init(allocator: std.mem.Allocator, url: []const u8) !NativeLibpqTransport {
        var lib = try NativeLibpqLibrary.load(allocator);
        errdefer lib.deinit();
        const url_z = try allocator.dupeZ(u8, url);
        errdefer allocator.free(url_z);
        return .{
            .allocator = allocator,
            .url_z = url_z,
            .lib = lib,
            .max_idle_connections = try configuredLibpqIdlePoolSize(allocator),
        };
    }

    pub fn deinit(self: *NativeLibpqTransport) void {
        for (self.idle_connections.items) |conn| {
            self.lib.PQfinish(conn);
        }
        self.idle_connections.deinit(self.allocator);
        self.allocator.free(self.url_z);
        self.lib.deinit();
    }

    pub fn name(self: *const NativeLibpqTransport) []const u8 {
        _ = self;
        return "libpq";
    }

    pub fn queryRaw(self: *NativeLibpqTransport, allocator: std.mem.Allocator, sql: []const u8) ![]u8 {
        const conn = try self.acquireConnection();
        defer self.releaseConnection(conn);

        const guarded_sql = try std.fmt.allocPrint(allocator, "SET statement_timeout = '{d}ms';\n{s}", .{ statement_timeout_ms, sql });
        defer allocator.free(guarded_sql);
        const sql_z = try allocator.dupeZ(u8, guarded_sql);
        defer allocator.free(sql_z);

        const result = self.lib.PQexec(conn, sql_z.ptr) orelse return error.PostgresCommandFailed;
        defer self.lib.PQclear(result);

        const status = self.lib.PQresultStatus(result);
        return switch (status) {
            pgres_empty_query, pgres_command_ok => allocator.dupe(u8, ""),
            pgres_tuples_ok => blk: {
                if (self.lib.PQntuples(result) <= 0 or self.lib.PQnfields(result) <= 0) {
                    break :blk allocator.dupe(u8, "");
                }
                const value = self.lib.PQgetvalue(result, 0, 0);
                const len: usize = @intCast(self.lib.PQgetlength(result, 0, 0));
                const trimmed = std.mem.trim(u8, value[0..len], " \t\r\n");
                break :blk allocator.dupe(u8, trimmed);
            },
            else => error.PostgresCommandFailed,
        };
    }

    fn acquireConnection(self: *NativeLibpqTransport) !*PGconn {
        self.mutex.lockUncancelable(compat.io());
        if (self.idle_connections.pop()) |conn| {
            self.mutex.unlock(compat.io());
            if (self.lib.PQstatus(conn) == connection_ok) return conn;
            self.lib.PQfinish(conn);
        } else {
            self.mutex.unlock(compat.io());
        }
        return self.connectNew();
    }

    fn releaseConnection(self: *NativeLibpqTransport, conn: *PGconn) void {
        if (self.max_idle_connections == 0 or self.lib.PQstatus(conn) != connection_ok) {
            self.lib.PQfinish(conn);
            return;
        }

        self.mutex.lockUncancelable(compat.io());
        defer self.mutex.unlock(compat.io());
        if (self.idle_connections.items.len >= self.max_idle_connections) {
            self.lib.PQfinish(conn);
            return;
        }
        self.idle_connections.append(self.allocator, conn) catch {
            self.lib.PQfinish(conn);
        };
    }

    fn connectNew(self: *NativeLibpqTransport) !*PGconn {
        const conn = self.lib.PQconnectdb(self.url_z.ptr) orelse return error.PostgresConnectionFailed;
        if (self.lib.PQstatus(conn) != connection_ok) {
            self.lib.PQfinish(conn);
            return error.PostgresConnectionFailed;
        }
        return conn;
    }
};

fn configuredLibpqIdlePoolSize(allocator: std.mem.Allocator) !usize {
    const raw = compat.process.getEnvVarOwned(allocator, "NULLPANTRY_POSTGRES_POOL_SIZE") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return default_libpq_idle_pool_size,
        else => |e| return e,
    };
    defer allocator.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return default_libpq_idle_pool_size;
    const parsed = try std.fmt.parseInt(usize, trimmed, 10);
    return @min(parsed, max_libpq_idle_pool_size);
}

const PGconn = opaque {};
const PGresult = opaque {};

const connection_ok: c_int = 0;
const pgres_empty_query: c_int = 0;
const pgres_command_ok: c_int = 1;
const pgres_tuples_ok: c_int = 2;

const FnPQconnectdb = *const fn ([*:0]const u8) callconv(.c) ?*PGconn;
const FnPQfinish = *const fn (?*PGconn) callconv(.c) void;
const FnPQstatus = *const fn (?*PGconn) callconv(.c) c_int;
const FnPQexec = *const fn (?*PGconn, [*:0]const u8) callconv(.c) ?*PGresult;
const FnPQresultStatus = *const fn (?*PGresult) callconv(.c) c_int;
const FnPQntuples = *const fn (?*PGresult) callconv(.c) c_int;
const FnPQnfields = *const fn (?*PGresult) callconv(.c) c_int;
const FnPQgetvalue = *const fn (?*PGresult, c_int, c_int) callconv(.c) [*]const u8;
const FnPQgetlength = *const fn (?*PGresult, c_int, c_int) callconv(.c) c_int;
const FnPQclear = *const fn (?*PGresult) callconv(.c) void;

const NativeLibpqLibrary = struct {
    dyn: std.DynLib,
    PQconnectdb: FnPQconnectdb,
    PQfinish: FnPQfinish,
    PQstatus: FnPQstatus,
    PQexec: FnPQexec,
    PQresultStatus: FnPQresultStatus,
    PQntuples: FnPQntuples,
    PQnfields: FnPQnfields,
    PQgetvalue: FnPQgetvalue,
    PQgetlength: FnPQgetlength,
    PQclear: FnPQclear,

    fn load(allocator: std.mem.Allocator) !NativeLibpqLibrary {
        if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_LIBPQ_PATH")) |path| {
            defer allocator.free(path);
            return loadPath(path);
        } else |err| switch (err) {
            error.EnvironmentVariableNotFound => {},
            else => |e| return e,
        }

        var last_err: ?anyerror = null;
        for (defaultLibpqCandidates()) |candidate| {
            return loadPath(candidate) catch |err| {
                last_err = err;
                continue;
            };
        }
        return last_err orelse error.LibpqUnavailable;
    }

    fn loadPath(path: []const u8) !NativeLibpqLibrary {
        var dyn = try std.DynLib.open(path);
        errdefer dyn.close();
        return .{
            .dyn = dyn,
            .PQconnectdb = dyn.lookup(FnPQconnectdb, "PQconnectdb") orelse return error.MissingLibpqSymbol,
            .PQfinish = dyn.lookup(FnPQfinish, "PQfinish") orelse return error.MissingLibpqSymbol,
            .PQstatus = dyn.lookup(FnPQstatus, "PQstatus") orelse return error.MissingLibpqSymbol,
            .PQexec = dyn.lookup(FnPQexec, "PQexec") orelse return error.MissingLibpqSymbol,
            .PQresultStatus = dyn.lookup(FnPQresultStatus, "PQresultStatus") orelse return error.MissingLibpqSymbol,
            .PQntuples = dyn.lookup(FnPQntuples, "PQntuples") orelse return error.MissingLibpqSymbol,
            .PQnfields = dyn.lookup(FnPQnfields, "PQnfields") orelse return error.MissingLibpqSymbol,
            .PQgetvalue = dyn.lookup(FnPQgetvalue, "PQgetvalue") orelse return error.MissingLibpqSymbol,
            .PQgetlength = dyn.lookup(FnPQgetlength, "PQgetlength") orelse return error.MissingLibpqSymbol,
            .PQclear = dyn.lookup(FnPQclear, "PQclear") orelse return error.MissingLibpqSymbol,
        };
    }

    fn deinit(self: *NativeLibpqLibrary) void {
        self.dyn.close();
    }
};

fn defaultLibpqCandidates() []const []const u8 {
    return switch (builtin.os.tag) {
        .macos => &.{
            "libpq.5.dylib",
            "libpq.dylib",
            "/opt/homebrew/opt/libpq/lib/libpq.5.dylib",
            "/opt/homebrew/lib/libpq.5.dylib",
            "/usr/local/opt/libpq/lib/libpq.5.dylib",
            "/usr/local/lib/libpq.5.dylib",
        },
        .linux => &.{ "libpq.so.5", "libpq.so" },
        else => &.{ "libpq.so.5", "libpq.so", "libpq.5.dylib", "libpq.dylib" },
    };
}

const PsqlTransport = struct {
    allocator: std.mem.Allocator,
    url: []const u8,
    psql_bin: []const u8,

    pub fn init(allocator: std.mem.Allocator, url: []const u8) !PsqlTransport {
        const owned_url = try allocator.dupe(u8, url);
        errdefer allocator.free(owned_url);
        const psql_bin = compat.process.getEnvVarOwned(allocator, "NULLPANTRY_PSQL_BIN") catch blk: {
            break :blk try allocator.dupe(u8, "psql");
        };
        return .{ .allocator = allocator, .url = owned_url, .psql_bin = psql_bin };
    }

    pub fn deinit(self: *PsqlTransport) void {
        self.allocator.free(self.url);
        self.allocator.free(self.psql_bin);
    }

    pub fn name(self: *const PsqlTransport) []const u8 {
        _ = self;
        return "psql";
    }

    pub fn queryRaw(self: *PsqlTransport, allocator: std.mem.Allocator, sql: []const u8) ![]u8 {
        const guarded_sql = try std.fmt.allocPrint(allocator, "SET statement_timeout = '{d}ms';\n{s}", .{ statement_timeout_ms, sql });
        defer allocator.free(guarded_sql);
        var env_map = std.process.Environ.Map.init(allocator);
        defer env_map.deinit();
        const inherited_env = [_][]const u8{ "PATH", "HOME", "USER", "LANG", "LC_ALL", "PGSSLMODE", "PGSSLROOTCERT", "PGSERVICE", "PGSERVICEFILE", "PGPASSFILE" };
        inline for (inherited_env) |env_name| {
            if (compat.process.getEnvVarOwned(allocator, env_name)) |value| {
                defer allocator.free(value);
                try env_map.put(env_name, value);
            } else |_| {}
        }
        try env_map.put("PGDATABASE", self.url);
        const argv = [_][]const u8{ self.psql_bin, "-X", "-v", "ON_ERROR_STOP=1", "-q", "-t", "-A", "-c", guarded_sql };
        const result = try std.process.run(allocator, compat.io(), .{
            .argv = &argv,
            .environ_map = &env_map,
            .stdout_limit = .limited(32 * 1024 * 1024),
            .stderr_limit = .limited(4 * 1024 * 1024),
        });
        defer allocator.free(result.stderr);
        defer allocator.free(result.stdout);
        switch (result.term) {
            .exited => |code| if (code != 0) return error.PostgresCommandFailed,
            else => return error.PostgresCommandFailed,
        }
        return allocator.dupe(u8, std.mem.trim(u8, result.stdout, " \t\r\n"));
    }
};

test "postgres transport selection defaults to native libpq" {
    try std.testing.expectEqual(TransportKind.libpq, try parseTransportKind(null));
    try std.testing.expectEqual(TransportKind.libpq, try parseTransportKind(""));
    try std.testing.expectEqual(TransportKind.libpq, try parseTransportKind("native"));
    try std.testing.expectEqual(TransportKind.psql, try parseTransportKind("psql"));
    try std.testing.expectError(error.InvalidPostgresTransport, parseTransportKind("auto"));
}

test "postgres url connect timeout is added only to postgres urls" {
    const allocator = std.testing.allocator;
    const first = try withConnectTimeout(allocator, "postgres://user@host/db");
    defer allocator.free(first);
    try std.testing.expectEqualStrings("postgres://user@host/db?connect_timeout=10", first);

    const second = try withConnectTimeout(allocator, "postgresql://user@host/db?sslmode=require");
    defer allocator.free(second);
    try std.testing.expectEqualStrings("postgresql://user@host/db?sslmode=require&connect_timeout=10", second);

    const existing = try withConnectTimeout(allocator, "postgres://user@host/db?connect_timeout=3");
    defer allocator.free(existing);
    try std.testing.expectEqualStrings("postgres://user@host/db?connect_timeout=3", existing);

    const service = try withConnectTimeout(allocator, "service=nullpantry");
    defer allocator.free(service);
    try std.testing.expectEqualStrings("service=nullpantry", service);
}
