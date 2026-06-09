const std = @import("std");

pub const DecodedVectorKey = struct {
    logical_key: []const u8,
    session_id: ?[]const u8,
    is_legacy: bool,
};

pub const DecodedVectorChunkId = struct {
    object_type: []const u8,
    object_id: []const u8,
    chunk_ordinal: i64,
    is_legacy: bool,
};

pub fn encode(allocator: std.mem.Allocator, logical_key: []const u8, session_id: ?[]const u8) ![]u8 {
    if (session_id) |sid| {
        return std.fmt.allocPrint(allocator, "s:{d}:{s}:{s}", .{ sid.len, sid, logical_key });
    }
    return std.fmt.allocPrint(allocator, "g:{s}", .{logical_key});
}

pub fn decode(stored_key: []const u8) DecodedVectorKey {
    if (std.mem.startsWith(u8, stored_key, "g:")) {
        return .{
            .logical_key = stored_key[2..],
            .session_id = null,
            .is_legacy = false,
        };
    }

    if (!std.mem.startsWith(u8, stored_key, "s:")) return legacyVectorKey(stored_key);

    const rest = stored_key[2..];
    const len_sep = std.mem.indexOfScalar(u8, rest, ':') orelse return legacyVectorKey(stored_key);
    const sid_len = std.fmt.parseInt(usize, rest[0..len_sep], 10) catch return legacyVectorKey(stored_key);
    const sid_start = 2 + len_sep + 1;
    if (sid_start > stored_key.len or sid_len > stored_key.len - sid_start) return legacyVectorKey(stored_key);
    const sid_end = sid_start + sid_len;
    if (sid_end >= stored_key.len or stored_key[sid_end] != ':') return legacyVectorKey(stored_key);

    return .{
        .logical_key = stored_key[(sid_end + 1)..],
        .session_id = stored_key[sid_start..sid_end],
        .is_legacy = false,
    };
}

pub fn encodeChunkId(
    allocator: std.mem.Allocator,
    object_type: []const u8,
    object_id: []const u8,
    chunk_ordinal: i64,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "vec:{d}:{s}:{s}:{d}", .{ object_type.len, object_type, object_id, chunk_ordinal });
}

pub fn decodeChunkId(stored_id: []const u8) DecodedVectorChunkId {
    if (!std.mem.startsWith(u8, stored_id, "vec:")) return legacyChunkId(stored_id);

    const rest = stored_id[4..];
    const len_sep = std.mem.indexOfScalar(u8, rest, ':') orelse return legacyChunkId(stored_id);
    const object_type_len = std.fmt.parseInt(usize, rest[0..len_sep], 10) catch return legacyChunkId(stored_id);
    const object_type_start = 4 + len_sep + 1;
    if (object_type_start > stored_id.len or object_type_len > stored_id.len - object_type_start) {
        return legacyChunkId(stored_id);
    }
    const object_type_end = object_type_start + object_type_len;
    if (object_type_len == 0 or object_type_end >= stored_id.len or stored_id[object_type_end] != ':') {
        return legacyChunkId(stored_id);
    }

    const object_and_ordinal = stored_id[(object_type_end + 1)..];
    const ordinal_sep = std.mem.lastIndexOfScalar(u8, object_and_ordinal, ':') orelse return legacyChunkId(stored_id);
    if (ordinal_sep == 0 or ordinal_sep + 1 >= object_and_ordinal.len) return legacyChunkId(stored_id);

    const chunk_ordinal = std.fmt.parseInt(i64, object_and_ordinal[(ordinal_sep + 1)..], 10) catch return legacyChunkId(stored_id);

    return .{
        .object_type = stored_id[object_type_start..object_type_end],
        .object_id = object_and_ordinal[0..ordinal_sep],
        .chunk_ordinal = chunk_ordinal,
        .is_legacy = false,
    };
}

fn legacyVectorKey(stored_key: []const u8) DecodedVectorKey {
    return .{
        .logical_key = stored_key,
        .session_id = null,
        .is_legacy = true,
    };
}

fn legacyChunkId(stored_id: []const u8) DecodedVectorChunkId {
    return .{
        .object_type = "",
        .object_id = stored_id,
        .chunk_ordinal = 0,
        .is_legacy = true,
    };
}

test "vector key codec preserves nullclaw-compatible global keys" {
    const allocator = std.testing.allocator;
    const encoded = try encode(allocator, "preference.docs_style", null);
    defer allocator.free(encoded);

    try std.testing.expectEqualStrings("g:preference.docs_style", encoded);
    const decoded = decode(encoded);
    try std.testing.expect(!decoded.is_legacy);
    try std.testing.expectEqual(@as(?[]const u8, null), decoded.session_id);
    try std.testing.expectEqualStrings("preference.docs_style", decoded.logical_key);
}

test "vector key codec preserves nullclaw-compatible scoped keys" {
    const allocator = std.testing.allocator;
    const encoded = try encode(allocator, "trait", "agent:one");
    defer allocator.free(encoded);

    try std.testing.expectEqualStrings("s:9:agent:one:trait", encoded);
    const decoded = decode(encoded);
    try std.testing.expect(!decoded.is_legacy);
    try std.testing.expectEqualStrings("agent:one", decoded.session_id.?);
    try std.testing.expectEqualStrings("trait", decoded.logical_key);
}

test "vector key codec reports unknown vector keys as legacy" {
    const decoded = decode("plain-key");
    try std.testing.expect(decoded.is_legacy);
    try std.testing.expectEqualStrings("plain-key", decoded.logical_key);
    try std.testing.expectEqual(@as(?[]const u8, null), decoded.session_id);
}

test "vector key codec treats oversized declared session lengths as legacy" {
    const decoded = decode("s:18446744073709551615:a:key");
    try std.testing.expect(decoded.is_legacy);
    try std.testing.expectEqualStrings("s:18446744073709551615:a:key", decoded.logical_key);
}

test "vector chunk codec roundtrips typed nullpantry ids" {
    const allocator = std.testing.allocator;
    const encoded = try encodeChunkId(allocator, "memory_atom", "shared_vector_id", 7);
    defer allocator.free(encoded);

    try std.testing.expectEqualStrings("vec:11:memory_atom:shared_vector_id:7", encoded);
    const decoded = decodeChunkId(encoded);
    try std.testing.expect(!decoded.is_legacy);
    try std.testing.expectEqualStrings("memory_atom", decoded.object_type);
    try std.testing.expectEqualStrings("shared_vector_id", decoded.object_id);
    try std.testing.expectEqual(@as(i64, 7), decoded.chunk_ordinal);
}

test "vector chunk codec supports object ids containing colons" {
    const allocator = std.testing.allocator;
    const encoded = try encodeChunkId(allocator, "agent_memory", "agent:a:session:b:key", 3);
    defer allocator.free(encoded);

    const decoded = decodeChunkId(encoded);
    try std.testing.expect(!decoded.is_legacy);
    try std.testing.expectEqualStrings("agent_memory", decoded.object_type);
    try std.testing.expectEqualStrings("agent:a:session:b:key", decoded.object_id);
    try std.testing.expectEqual(@as(i64, 3), decoded.chunk_ordinal);
}

test "vector chunk codec reports malformed chunk ids as legacy" {
    const malformed = [_][]const u8{
        "legacy-vector-id",
        "vec:not-a-len:memory_atom:id:0",
        "vec:0::id:0",
        "vec:18446744073709551615:memory_atom:id:0",
        "vec:11:memory_atom:id",
        "vec:11:memory_atom:id:not-an-int",
    };
    for (malformed) |id| {
        const decoded = decodeChunkId(id);
        try std.testing.expect(decoded.is_legacy);
        try std.testing.expectEqualStrings(id, decoded.object_id);
    }
}
