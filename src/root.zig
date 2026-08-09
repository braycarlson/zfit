const std = @import("std");

const assert = std.debug.assert;

pub const Decoder = @import("decoder.zig");
pub const Encoder = @import("encoder.zig");
pub const crc = @import("crc.zig");
pub const decode = @import("decode.zig");
pub const epoch = @import("epoch.zig");
pub const exporter = @import("exporter.zig");
pub const garmin = @import("garmin.zig");
pub const profile = @import("profile.zig");
pub const value = @import("value.zig");

pub const BaseType = Decoder.BaseType;
pub const DataMessage = Decoder.DataMessage;
pub const Error = Decoder.Error;
pub const Field = Decoder.Field;
pub const FieldIterator = Decoder.FieldIterator;
pub const Header = Decoder.Header;
pub const MessageDefinition = Decoder.MessageDefinition;

pub const FieldInfo = profile.FieldInfo;
pub const MessageInfo = profile.MessageInfo;
pub const Value = value.Value;

pub const DecodedField = decode.Field;
pub const Message = decode.Message;
pub const Stream = decode.Stream;

pub const ChecksumError = error{
    Truncated,
    ChecksumMismatch,
};

const file_bytes_min = Decoder.header_bytes + crc.checksum_bytes;

comptime {
    assert(file_bytes_min == 14);
}

pub fn verify_checksum(bytes: []const u8) ChecksumError!void {
    if (bytes.len < file_bytes_min) return error.Truncated;

    const body = bytes[0 .. bytes.len - crc.checksum_bytes];
    const trailer = bytes[bytes.len - crc.checksum_bytes ..][0..crc.checksum_bytes];
    const expected = std.mem.readInt(u16, trailer, .little);
    const actual = crc.checksum(0, body);

    if (actual != expected) return error.ChecksumMismatch;
}

test "verify_checksum accepts a valid trailer and rejects corruption" {
    var bytes = [_]u8{ 12, 0x20, 0x8F, 0x08, 0, 0, 0, 0, '.', 'F', 'I', 'T', 0, 0 };

    const sum = crc.checksum(0, bytes[0..12]);
    std.mem.writeInt(u16, bytes[12..14], sum, .little);
    try verify_checksum(&bytes);

    bytes[2] ^= 0xFF;
    try std.testing.expectError(error.ChecksumMismatch, verify_checksum(&bytes));
}

test "verify_checksum rejects a file that is too short" {
    try std.testing.expectError(error.Truncated, verify_checksum(&[_]u8{ 1, 2, 3 }));
}
