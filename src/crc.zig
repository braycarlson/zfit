const std = @import("std");

const assert = std.debug.assert;

pub const checksum_bytes = 2;

const table = [16]u16{
    0x0000, 0xCC01, 0xD801, 0x1400,
    0xF001, 0x3C00, 0x2800, 0xE401,
    0xA001, 0x6C00, 0x7800, 0xB401,
    0x5000, 0x9C01, 0x8801, 0x4400,
};

const nibble_mask = 0x0F;
const nibble_bits = 4;

const shifted_mask = 0x0FFF;

comptime {
    assert(checksum_bytes == @sizeOf(u16));
    assert(table.len == nibble_mask + 1);
    assert(table.len == 1 << nibble_bits);
    assert(nibble_mask == (1 << nibble_bits) - 1);
    assert(shifted_mask == std.math.maxInt(u16) >> nibble_bits);
}

pub fn checksum(seed: u16, bytes: []const u8) u16 {
    var value = seed;

    for (bytes) |byte| {
        value = update(value, byte);
    }

    return value;
}

fn update(value_in: u16, byte: u8) u16 {
    var value = value_in;

    var temp = table[value & nibble_mask];
    value = (value >> nibble_bits) & shifted_mask;
    value = value ^ temp ^ table[byte & nibble_mask];

    temp = table[value & nibble_mask];
    value = (value >> nibble_bits) & shifted_mask;
    value = value ^ temp ^ table[(byte >> nibble_bits) & nibble_mask];

    return value;
}

test "checksum is seedable so a split pass equals a whole pass" {
    const whole = checksum(0, "hello world");
    const split = checksum(checksum(0, "hello "), "world");

    try std.testing.expectEqual(whole, split);
}

test "checksum depends on byte order" {
    try std.testing.expect(checksum(0, "hello") != checksum(0, "olleh"));
}

test "empty input leaves the seed unchanged" {
    try std.testing.expectEqual(@as(u16, 0x1234), checksum(0x1234, ""));
}
