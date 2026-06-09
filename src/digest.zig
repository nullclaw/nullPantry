const std = @import("std");

pub const Sha256 = std.crypto.hash.sha2.Sha256;

pub fn finalSha256Hex(hasher: *Sha256) [64]u8 {
    var raw: [32]u8 = undefined;
    hasher.final(&raw);
    return bytesToLowerHex(raw);
}

pub fn sha256PartsHex(parts: []const []const u8) [64]u8 {
    var hasher = Sha256.init(.{});
    for (parts) |part| updateLengthDelimited(&hasher, part);
    return finalSha256Hex(&hasher);
}

pub fn updateLengthDelimited(hasher: *Sha256, part: []const u8) void {
    var len_buf: [32]u8 = undefined;
    const len = std.fmt.bufPrint(&len_buf, "{d}:", .{part.len}) catch unreachable;
    hasher.update(len);
    hasher.update(part);
    hasher.update(";");
}

fn bytesToLowerHex(bytes: [32]u8) [64]u8 {
    const hex_chars = "0123456789abcdef";
    var hex: [64]u8 = undefined;
    for (bytes, 0..) |byte, i| {
        hex[i * 2] = hex_chars[byte >> 4];
        hex[i * 2 + 1] = hex_chars[byte & 0x0f];
    }
    return hex;
}

test "sha256 parts are length delimited" {
    const a = sha256PartsHex(&.{ "ab", "c" });
    const b = sha256PartsHex(&.{ "a", "bc" });
    try std.testing.expect(!std.mem.eql(u8, a[0..], b[0..]));
    try std.testing.expectEqual(@as(usize, 64), a.len);
}
