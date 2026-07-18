//! Binding-facing, ephemeral data fingerprints.
const std = @import("std");

/// Canonical BLAKE3-128 digest bytes.
pub const Digest = [16]u8;

/// Incremental BLAKE3-128 hasher.
pub const Hasher = struct {
    inner: std.crypto.hash.Blake3,

    pub fn init() Hasher {
        return .{ .inner = .init(.{}) };
    }

    pub fn update(self: *Hasher, bytes: []const u8) void {
        self.inner.update(bytes);
    }

    /// Return the digest without consuming the state.
    pub fn final(self: *const Hasher) Digest {
        var digest: Digest = undefined;
        self.inner.final(&digest);
        return digest;
    }
};

/// Hash one byte slice in a single call.
pub fn hash(bytes: []const u8) Digest {
    var digest: Digest = undefined;
    std.crypto.hash.Blake3.hash(bytes, &digest, .{});
    return digest;
}

test "BLAKE3-128 known vectors" {
    const empty = [_]u8{
        0xaf, 0x13, 0x49, 0xb9, 0xf5, 0xf9, 0xa1, 0xa6,
        0xa0, 0x40, 0x4d, 0xea, 0x36, 0xdc, 0xc9, 0x49,
    };
    const abc = [_]u8{
        0x64, 0x37, 0xb3, 0xac, 0x38, 0x46, 0x51, 0x33,
        0xff, 0xb6, 0x3b, 0x75, 0x27, 0x3a, 0x8d, 0xb5,
    };
    try std.testing.expectEqualSlices(u8, &empty, &hash(""));
    try std.testing.expectEqualSlices(u8, &abc, &hash("abc"));
}

test "streaming matches one-shot and final is non-consuming" {
    const input = "logical bytes can arrive in irregular chunks";
    var hasher = Hasher.init();
    hasher.update(input[0..1]);
    hasher.update(input[1..13]);
    hasher.update("");
    hasher.update(input[13..]);

    const first = hasher.final();
    try std.testing.expectEqualSlices(u8, &hash(input), &first);
    try std.testing.expectEqualSlices(u8, &first, &hasher.final());
}
