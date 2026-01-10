// Fast allocation-free v4 UUIDs.
// Inspired by the Go implementation at github.com/skeeto/uuid

// CREDITS
// https://github.com/nitrogenez/zig-uuid (a fork of) https://github.com/dmgk/zig-uuid

const std = @import("std");
const crypto = std.crypto;
const testing = std.testing;

pub const SLICE_LEN = 36;

pub fn genUuidV4(buf: []u8) !void {
    if (buf.len != SLICE_LEN) return error.InvalidUUIDv4BufferSize;

    var bytes: [16]u8 = undefined;

    crypto.random.bytes(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    buf[8] = '-';
    buf[13] = '-';
    buf[18] = '-';
    buf[23] = '-';

    const buf_indexes = [16]u8{ 0, 2, 4, 6, 9, 11, 14, 16, 19, 21, 24, 26, 28, 30, 32, 34 };
    const hex = "0123456789abcdef";
    inline for (buf_indexes, 0..) |i, j| {
        buf[i + 0] = hex[bytes[j] >> 4];
        buf[i + 1] = hex[bytes[j] & 0x0f];
    }
}

test genUuidV4 {
    var buf: [SLICE_LEN]u8 = undefined;
    try genUuidV4(&buf);
    std.debug.print("{s}\n", .{buf});
}

test "invalid buffer size" {
    var buf: [SLICE_LEN - 1]u8 = undefined;
    try testing.expectError(error.InvalidUUIDv4BufferSize, genUuidV4(&buf));
}
