const std = @import("std");
const build_options = @import("build_options");
const compat = @import("compat.zig");
const api = @import("api.zig");
const store_mod = @import("store.zig");

const default_port: u16 = 8765;
const max_request_size: usize = 2 * 1024 * 1024;
const read_chunk_size: usize = 4096;

const RuntimeConfig = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = default_port,
    db_path: [:0]const u8 = ".nullpantry/nullpantry.db",
    backend: store_mod.BackendKind = .sqlite,
    postgres_url: ?[]const u8 = null,
    token: ?[]const u8 = null,
    actor_scopes_json: []const u8 = "[\"admin\"]",
    actor_capabilities_json: []const u8 = "[\"read\",\"write\",\"propose\",\"verify\",\"delete\",\"export\",\"feed_apply\"]",
};

pub fn main(init: std.process.Init) !void {
    compat.initProcess(init);
    const allocator = std.heap.smp_allocator;

    const args = try compat.process.argsAlloc(allocator);
    defer compat.process.argsFree(allocator, args);

    const cfg = try parseArgs(allocator, args);
    if (cfg.backend == .sqlite) try ensureParentDirForFile(cfg.db_path);

    var store = switch (cfg.backend) {
        .sqlite => try store_mod.Store.initSQLite(allocator, cfg.db_path),
        .postgres => try store_mod.Store.initPostgres(allocator, cfg.postgres_url orelse return error.MissingPostgresUrl),
    };
    defer store.deinit();

    const addr = try std.Io.net.IpAddress.resolve(compat.io(), cfg.host, cfg.port);
    var server = try addr.listen(compat.io(), .{ .reuse_address = true });
    defer server.deinit(compat.io());

    std.debug.print("nullpantry v{s}\n", .{build_options.version});
    std.debug.print("listening on http://{s}:{d}\n", .{ cfg.host, cfg.port });
    std.debug.print("storage backend: {s}\n", .{@tagName(cfg.backend)});

    while (true) {
        var conn = server.accept(compat.io()) catch |err| {
            std.debug.print("accept error: {}\n", .{err});
            continue;
        };
        defer conn.close(compat.io());

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const req_alloc = arena.allocator();

        const raw = readHttpRequest(req_alloc, &conn, max_request_size) catch |err| {
            std.debug.print("request read error: {}\n", .{err});
            continue;
        } orelse continue;

        const first_line_end = std.mem.indexOf(u8, raw, "\r\n") orelse continue;
        const first_line = raw[0..first_line_end];
        var parts = std.mem.splitScalar(u8, first_line, ' ');
        const method = parts.next() orelse continue;
        const target = parts.next() orelse continue;
        const body = @import("json_util.zig").extractBody(raw);

        var ctx = api.Context{ .allocator = req_alloc, .store = &store, .required_token = cfg.token, .actor_scopes_json = cfg.actor_scopes_json, .actor_capabilities_json = cfg.actor_capabilities_json };
        const response = api.handleRequest(&ctx, method, target, body, raw);

        var header_buf: [512]u8 = undefined;
        const header = std.fmt.bufPrint(
            &header_buf,
            "HTTP/1.1 {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
            .{ response.status, response.body.len },
        ) catch continue;
        var write_buffer: [4096]u8 = undefined;
        var writer = conn.writer(compat.io(), &write_buffer);
        writer.interface.writeAll(header) catch continue;
        writer.interface.writeAll(response.body) catch continue;
        writer.interface.flush() catch continue;
    }
}

fn parseArgs(allocator: std.mem.Allocator, args: []const [:0]const u8) !RuntimeConfig {
    var cfg = RuntimeConfig{};
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_TOKEN")) |token| {
        cfg.token = token;
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_DATABASE_URL")) |url| {
        cfg.backend = .postgres;
        cfg.postgres_url = url;
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_SCOPES")) |scopes| {
        cfg.actor_scopes_json = scopes;
    } else |_| {}
    if (compat.process.getEnvVarOwned(allocator, "NULLPANTRY_CAPABILITIES")) |caps| {
        cfg.actor_capabilities_json = caps;
    } else |_| {}

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--version")) {
            std.debug.print("nullpantry v{s}\n", .{build_options.version});
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--help")) {
            printUsage();
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--host") and i + 1 < args.len) {
            i += 1;
            cfg.host = args[i];
        } else if (std.mem.eql(u8, arg, "--port") and i + 1 < args.len) {
            i += 1;
            cfg.port = try std.fmt.parseInt(u16, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--db") and i + 1 < args.len) {
            i += 1;
            cfg.db_path = args[i];
            cfg.backend = .sqlite;
        } else if (std.mem.eql(u8, arg, "--backend") and i + 1 < args.len) {
            i += 1;
            cfg.backend = store_mod.BackendKind.parse(args[i]);
        } else if (std.mem.eql(u8, arg, "--postgres-url") and i + 1 < args.len) {
            i += 1;
            cfg.postgres_url = args[i];
            cfg.backend = .postgres;
        } else if (std.mem.eql(u8, arg, "--token") and i + 1 < args.len) {
            i += 1;
            cfg.token = args[i];
        } else if (std.mem.eql(u8, arg, "--actor-scopes") and i + 1 < args.len) {
            i += 1;
            cfg.actor_scopes_json = args[i];
        } else if (std.mem.eql(u8, arg, "--actor-capabilities") and i + 1 < args.len) {
            i += 1;
            cfg.actor_capabilities_json = args[i];
        }
    }
    return cfg;
}

fn printUsage() void {
    std.debug.print(
        \\Usage: nullpantry [--host HOST] [--port PORT] [--db PATH] [--token TOKEN] [--actor-scopes JSON] [--actor-capabilities JSON]
        \\       nullpantry --backend postgres --postgres-url URL [--token TOKEN]
        \\
        \\Environment:
        \\  NULLPANTRY_TOKEN
        \\  NULLPANTRY_DATABASE_URL
        \\  NULLPANTRY_SCOPES
        \\  NULLPANTRY_CAPABILITIES
        \\
    , .{});
}

fn ensureParentDirForFile(path: []const u8) !void {
    if (path.len == 0 or std.mem.eql(u8, path, ":memory:")) return;
    const parent = std.fs.path.dirname(path) orelse return;
    if (parent.len == 0) return;
    if (std.Io.Dir.cwd().statFile(compat.io(), parent, .{})) |stat| {
        if (stat.kind == .directory) return;
        return error.NotDir;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    try std.Io.Dir.cwd().createDirPath(compat.io(), parent);
}

fn readHttpRequest(allocator: std.mem.Allocator, stream: *std.Io.net.Stream, max_bytes: usize) !?[]u8 {
    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    defer buffer.deinit(allocator);

    var read_buffer: [read_chunk_size]u8 = undefined;
    var reader = stream.reader(compat.io(), &read_buffer);
    while (true) {
        const line = reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => return if (buffer.items.len == 0) null else error.UnexpectedEof,
            else => |e| return e,
        };
        if (buffer.items.len + line.len > max_bytes) return error.RequestTooLarge;
        try buffer.appendSlice(allocator, line);
        if (std.mem.endsWith(u8, buffer.items, "\r\n\r\n")) break;
    }

    const header_text = buffer.items;
    var content_length: usize = 0;
    var lines = std.mem.splitSequence(u8, header_text, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        if (std.ascii.eqlIgnoreCase(key, "Content-Length")) {
            const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
            content_length = std.fmt.parseInt(usize, value, 10) catch 0;
        }
    }
    if (buffer.items.len + content_length > max_bytes) return error.RequestTooLarge;
    if (content_length > 0) {
        const body = try allocator.alloc(u8, content_length);
        try reader.interface.readSliceAll(body);
        try buffer.appendSlice(allocator, body);
    }
    return try buffer.toOwnedSlice(allocator);
}

test {
    _ = @import("ids.zig");
    _ = @import("json_util.zig");
    _ = @import("domain.zig");
    _ = @import("engines.zig");
    _ = @import("vector.zig");
    _ = @import("retrieval.zig");
    _ = @import("lifecycle.zig");
    _ = @import("store.zig");
    _ = @import("api.zig");
}
