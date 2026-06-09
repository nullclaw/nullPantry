const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

var fallback_threaded: std.Io.Threaded = .init_single_threaded;
var process_io: ?std.Io = null;
var process_args: ?std.process.Args = null;
var process_environ: ?std.process.Environ = null;

pub fn initProcess(init: std.process.Init) void {
    process_io = init.io;
    process_args = init.minimal.args;
    process_environ = init.minimal.environ;
}

pub fn io() std.Io {
    if (builtin.is_test) return std.testing.io;
    if (process_io) |current| return current;
    return fallback_threaded.io();
}

fn processParentIo() std.Io {
    return io();
}

fn environ() std.process.Environ {
    if (process_environ) |env| return env;
    return switch (builtin.os.tag) {
        .windows, .freestanding, .other => .{ .block = .global },
        .wasi, .emscripten => if (builtin.link_libc) blk: {
            const c_environ = std.c.environ;
            var env_count: usize = 0;
            while (c_environ[env_count] != null) : (env_count += 1) {}
            break :blk .{ .block = .{ .slice = c_environ[0..env_count :null] } };
        } else .{ .block = .global },
        else => blk: {
            const c_environ = std.c.environ;
            var env_count: usize = 0;
            while (c_environ[env_count] != null) : (env_count += 1) {}
            break :blk .{ .block = .{ .slice = c_environ[0..env_count :null] } };
        },
    };
}

pub const process = struct {
    pub const ChildProcessIo = struct {
        threaded: ?std.Io.Threaded = null,

        pub fn init(allocator: Allocator) ChildProcessIo {
            if (builtin.is_test) {
                return .{ .threaded = std.Io.Threaded.init(allocator, .{ .environ = .empty }) };
            }
            return .{};
        }

        pub fn io(self: *ChildProcessIo) std.Io {
            if (self.threaded) |*threaded| return threaded.io();
            return processParentIo();
        }

        pub fn deinit(self: *ChildProcessIo) void {
            if (self.threaded) |*threaded| threaded.deinit();
            self.* = .{};
        }
    };

    pub fn childProcessIo(allocator: Allocator) ChildProcessIo {
        return ChildProcessIo.init(allocator);
    }

    pub fn argsAlloc(allocator: Allocator) ![]const [:0]const u8 {
        const args = process_args orelse return error.MissingProcessContext;
        var iter = try args.iterateAllocator(allocator);
        defer iter.deinit();

        var list: std.ArrayList([:0]const u8) = .empty;
        errdefer {
            for (list.items) |arg| allocator.free(arg);
            list.deinit(allocator);
        }

        while (iter.next()) |arg| {
            try list.append(allocator, try allocator.dupeZ(u8, arg));
        }
        return try list.toOwnedSlice(allocator);
    }

    pub fn argsFree(allocator: Allocator, args: []const [:0]const u8) void {
        for (args) |arg| allocator.free(arg);
        allocator.free(args);
    }

    pub fn getEnvVarOwned(allocator: Allocator, name: []const u8) ![]u8 {
        return environ().getAlloc(allocator, name) catch |err| switch (err) {
            error.EnvironmentVariableMissing => error.EnvironmentVariableNotFound,
            else => |e| e,
        };
    }

    pub fn sanitizedChildEnv(allocator: Allocator) !std.process.Environ.Map {
        var env = std.process.Environ.Map.init(allocator);
        errdefer env.deinit();
        try env.put("PATH", sanitizedChildPath());
        return env;
    }

    fn sanitizedChildPath() []const u8 {
        return switch (builtin.os.tag) {
            .windows => "C:\\Windows\\System32;C:\\Windows",
            else => "/usr/local/bin:/usr/bin:/bin",
        };
    }
};

test "sanitized child env omits nullpantry variables" {
    var env = try process.sanitizedChildEnv(std.testing.allocator);
    defer env.deinit();

    try std.testing.expect(env.get("PATH") != null);
    try std.testing.expect(env.get("NULLPANTRY_TOKEN") == null);
    try std.testing.expect(env.get("NULLPANTRY_DATABASE_URL") == null);
}
