// Fast allocation-free v4 UUIDs.
// Inspired by the Go implementation at github.com/skeeto/uuid

// CREDITS
// https://github.com/nitrogenez/zig-uuid (a fork of) https://github.com/dmgk/zig-uuid

const std = @import("std");
const testing = std.testing;

// TODO: come up with a better name for this
pub const SLICE_LEN = 36;

pub fn v4(buf_: []u8, io_: std.Io) !void {
    if (buf_.len != SLICE_LEN) return error.InvalidUUIDv4BufferSize;

    var bytes: [16]u8 = undefined;

    var io_source = std.Random.IoSource{ .io = io_ };
    const random = io_source.interface();
    random.bytes(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    buf_[8] = '-';
    buf_[13] = '-';
    buf_[18] = '-';
    buf_[23] = '-';

    const buf_indexes = [16]u8{ 0, 2, 4, 6, 9, 11, 14, 16, 19, 21, 24, 26, 28, 30, 32, 34 };
    const hex = "0123456789abcdef";
    inline for (buf_indexes, 0..) |i, j| {
        buf_[i + 0] = hex[bytes[j] >> 4];
        buf_[i + 1] = hex[bytes[j] & 0x0f];
    }
}

test v4 {
    var buf: [SLICE_LEN]u8 = undefined;
    try v4(&buf, std.testing.io);

    // 1. Correct length and hyphen positions
    try std.testing.expectEqual(@as(usize, 36), buf.len);
    try std.testing.expectEqual(@as(u8, '-'), buf[8]);
    try std.testing.expectEqual(@as(u8, '-'), buf[13]);
    try std.testing.expectEqual(@as(u8, '-'), buf[18]);
    try std.testing.expectEqual(@as(u8, '-'), buf[23]);

    // 2. Version = 4 (character at position 14 must be '4')
    try std.testing.expectEqual(@as(u8, '4'), buf[14]);

    // 3. Variant bits (RFC 4122): characters at position 19 must be 8,9,a,b (case insensitive)
    const variant_char = std.ascii.toLower(buf[19]);
    try std.testing.expect(variant_char == '8' or variant_char == '9' or
        variant_char == 'a' or variant_char == 'b');

    // 4. All other characters are valid hex
    for (buf) |c| {
        if (c != '-') {
            try std.testing.expect(std.ascii.isHex(c));
        }
    }
}

test "invalid buffer size" {
    var buf: [SLICE_LEN - 1]u8 = undefined;
    try testing.expectError(error.InvalidUUIDv4BufferSize, v4(&buf, std.testing.io));
}
