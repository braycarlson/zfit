const std = @import("std");

const Endian = std.builtin.Endian;
const Reader = std.Io.Reader;
const assert = std.debug.assert;

const Decoder = @This();

reader: *Reader,
header: Header,
bytes_remaining: u32,
definitions: [local_type_count]?MessageDefinition,
definition_sequence: u32,
timestamp: ?u32,

pub const Error = error{
    ReadFailed,
    Truncated,
    NotFitFile,
    BadHeaderSize,
    FileTooLarge,
    UnknownBaseType,
    UndefinedLocalType,
};

pub const Header = struct {
    header_size: u8,
    protocol_version: u8,
    profile_version: u16,
    data_size: u32,
    crc: u16,

    pub fn parse(reader: *Reader) Error!Header {
        const header_size = reader.takeByte() catch |err| return map_error(err);

        switch (header_size) {
            header_bytes, header_bytes_with_crc => {},
            else => return error.BadHeaderSize,
        }

        const protocol_version = reader.takeByte() catch |err| return map_error(err);
        const profile_version = reader.takeInt(u16, .little) catch |err| return map_error(err);
        const data_size = reader.takeInt(u32, .little) catch |err| return map_error(err);

        const signature = (reader.takeArray(signature_bytes) catch |err| return map_error(err)).*;

        if (!std.mem.eql(u8, &signature, file_signature)) return error.NotFitFile;

        var header_crc: u16 = 0;

        if (header_size == header_bytes_with_crc) {
            header_crc = reader.takeInt(u16, .little) catch |err| return map_error(err);
        }

        return .{
            .header_size = header_size,
            .protocol_version = protocol_version,
            .profile_version = profile_version,
            .data_size = data_size,
            .crc = header_crc,
        };
    }
};

pub const BaseType = enum(u8) {
    enum_value = 0x00,
    sint8 = 0x01,
    uint8 = 0x02,
    string = 0x07,
    uint8z = 0x0A,
    byte = 0x0D,
    sint16 = 0x83,
    uint16 = 0x84,
    sint32 = 0x85,
    uint32 = 0x86,
    float32 = 0x88,
    float64 = 0x89,
    uint16z = 0x8B,
    uint32z = 0x8C,
    sint64 = 0x8E,
    uint64 = 0x8F,
    uint64z = 0x90,

    pub fn size_bytes(base_type: BaseType) u8 {
        return switch (base_type) {
            .enum_value, .sint8, .uint8, .string, .uint8z, .byte => 1,
            .sint16, .uint16, .uint16z => 2,
            .sint32, .uint32, .float32, .uint32z => 4,
            .float64, .sint64, .uint64, .uint64z => 8,
        };
    }

    pub fn invalid_value(base_type: BaseType) ?u64 {
        return switch (base_type) {
            .enum_value, .uint8, .byte => 0xFF,
            .sint8 => 0x7F,
            .uint16 => 0xFFFF,
            .sint16 => 0x7FFF,
            .uint32, .float32 => 0xFFFFFFFF,
            .sint32 => 0x7FFFFFFF,
            .uint64, .float64 => 0xFFFFFFFFFFFFFFFF,
            .sint64 => 0x7FFFFFFFFFFFFFFF,
            .uint8z, .uint16z, .uint32z, .uint64z => 0,
            .string => null,
        };
    }

    pub fn is_signed(base_type: BaseType) bool {
        return switch (base_type) {
            .sint8, .sint16, .sint32, .sint64 => true,
            .enum_value, .uint8, .uint16, .uint32, .uint64 => false,
            .uint8z, .uint16z, .uint32z, .uint64z => false,
            .float32, .float64, .string, .byte => false,
        };
    }

    pub fn is_float(base_type: BaseType) bool {
        return switch (base_type) {
            .float32, .float64 => true,
            .enum_value, .sint8, .uint8, .string, .uint8z, .byte => false,
            .sint16, .uint16, .uint16z => false,
            .sint32, .uint32, .uint32z => false,
            .sint64, .uint64, .uint64z => false,
        };
    }
};

pub const FieldDefinition = struct {
    field_definition_number: u8,
    size_bytes: u8,
    base_type: BaseType,
};

pub const DeveloperFieldDefinition = struct {
    developer_data_index: u8,
    field_number: u8,
    size_bytes: u8,
};

pub const MessageDefinition = struct {
    global_message_number: u16,
    architecture: Endian,
    sequence: u32,
    field_count: u8,
    fields: [field_count_max]FieldDefinition,
    payload_size_bytes: u32,
    regular_size_bytes: u32,
    timestamp_offset: ?u16,
    developer_fields: [developer_field_count_max]DeveloperFieldDefinition,
    developer_field_count: u8,
};

pub const Field = struct {
    field_definition_number: u8,
    base_type: BaseType,
    data: []const u8,
};

pub const DataMessage = struct {
    global_message_number: u16,
    architecture: Endian,
    local_type: u4,
    definition: *const MessageDefinition,
    payload: []const u8,
    timestamp: ?u32,

    pub fn fields(message: *const DataMessage) FieldIterator {
        assert(message.definition.payload_size_bytes == message.payload.len);
        assert(message.definition.regular_size_bytes <= message.payload.len);

        return .{ .message = message, .index = 0, .offset = 0 };
    }

    pub fn developer_fields(message: *const DataMessage) DeveloperFieldIterator {
        const start = message.definition.regular_size_bytes;

        assert(message.definition.payload_size_bytes == message.payload.len);
        assert(start <= message.payload.len);

        return .{ .message = message, .index = 0, .offset = start };
    }
};

pub const FieldIterator = struct {
    message: *const DataMessage,
    index: u8,
    offset: u32,

    pub fn next(iterator: *FieldIterator) ?Field {
        const definition = iterator.message.definition;

        if (iterator.index >= definition.field_count) return null;

        const field = definition.fields[iterator.index];
        const start = iterator.offset;
        const end = start + field.size_bytes;

        assert(end <= definition.regular_size_bytes);
        assert(end <= iterator.message.payload.len);

        iterator.index += 1;
        iterator.offset = end;

        return .{
            .field_definition_number = field.field_definition_number,
            .base_type = field.base_type,
            .data = iterator.message.payload[start..end],
        };
    }
};

pub const DeveloperField = struct {
    developer_data_index: u8,
    field_number: u8,
    data: []const u8,
};

pub const DeveloperFieldIterator = struct {
    message: *const DataMessage,
    index: u8,
    offset: u32,

    pub fn next(iterator: *DeveloperFieldIterator) ?DeveloperField {
        const definition = iterator.message.definition;

        if (iterator.index >= definition.developer_field_count) return null;

        const field = definition.developer_fields[iterator.index];
        const start = iterator.offset;
        const end = start + field.size_bytes;

        assert(start >= definition.regular_size_bytes);
        assert(end <= iterator.message.payload.len);

        iterator.index += 1;
        iterator.offset = end;

        return .{
            .developer_data_index = field.developer_data_index,
            .field_number = field.field_number,
            .data = iterator.message.payload[start..end],
        };
    }
};

const HeaderKind = enum(u1) { normal = 0, compressed = 1 };
const MessageKind = enum(u1) { data = 0, definition = 1 };

pub const RecordHeaderNormal = packed struct(u8) {
    local_message_type: u4,
    reserved: u1,
    has_developer_data: u1,
    message_kind: MessageKind,
    header_kind: HeaderKind,
};

const RecordHeaderCompressed = packed struct(u8) {
    time_offset: u5,
    local_message_type: u2,
    header_kind: HeaderKind,
};

pub const local_type_count = 16;

pub const field_count_max = 255;

pub const field_bytes_max = 255;

pub const developer_field_count_max = 32;

pub const payload_bytes_max: u32 = 2 * @as(u32, field_count_max) * field_bytes_max;

pub const data_size_max = 256 * 1024 * 1024;

pub const message_count_max = data_size_max;

pub const header_bytes = 12;
pub const header_bytes_with_crc = 14;

pub const file_signature = ".FIT";
pub const signature_bytes = 4;
pub const signature_offset = 8;

const crc_bytes = 2;

pub const timestamp_field_number = 253;

const timestamp_size_bytes = 4;
const timestamp_invalid: u32 = 0xFFFFFFFF;

const rollover_seconds: u32 = 1 << @bitSizeOf(u5);
const rollover_mask: u32 = rollover_seconds - 1;

const base_type_bytes_max = 8;

comptime {
    assert(local_type_count == std.math.maxInt(u4) + 1);
    assert(field_count_max == std.math.maxInt(u8));
    assert(field_bytes_max == std.math.maxInt(u8));
    assert(developer_field_count_max <= field_count_max);
    assert(header_bytes < header_bytes_with_crc);
    assert(header_bytes_with_crc - header_bytes == crc_bytes);
    assert(signature_bytes == file_signature.len);
    assert(header_bytes == signature_offset + signature_bytes);
    assert(data_size_max <= std.math.maxInt(u32));
    assert(payload_bytes_max <= data_size_max);
    assert(timestamp_size_bytes == BaseType.uint32.size_bytes());
    assert(timestamp_invalid == BaseType.uint32.invalid_value().?);
    assert(rollover_seconds == 32);
    assert(base_type_bytes_max == BaseType.uint64.size_bytes());
}

comptime {
    for (@typeInfo(BaseType).@"enum".fields) |field| {
        const base_type: BaseType = @enumFromInt(field.value);
        const size = base_type.size_bytes();

        assert(size >= 1);
        assert(size <= base_type_bytes_max);
        assert(std.math.isPowerOfTwo(size));

        if (base_type.is_float()) assert(!base_type.is_signed());
        if (base_type.is_signed()) assert(!base_type.is_float());

        if (base_type.invalid_value()) |sentinel| {
            const width_bits = @as(u16, size) * 8;

            assert(width_bits >= 8);
            assert(width_bits <= base_type_bytes_max * 8);

            if (width_bits < base_type_bytes_max * 8) {
                assert(sentinel >> @intCast(width_bits) == 0);
            }
        } else {
            assert(base_type == .string);
        }
    }
}

pub fn init(reader: *Reader) Error!Decoder {
    const header = try Header.parse(reader);

    if (header.data_size > data_size_max) return error.FileTooLarge;

    if (reader.bufferedLen() < header.data_size) return error.Truncated;

    assert(header.header_size >= header_bytes);
    assert(header.header_size <= header_bytes_with_crc);

    return .{
        .reader = reader,
        .header = header,
        .bytes_remaining = header.data_size,
        .definitions = .{null} ** local_type_count,
        .definition_sequence = 0,
        .timestamp = null,
    };
}

pub fn next(decoder: *Decoder) Error!?DataMessage {
    while (decoder.bytes_remaining > 0) {
        const first = try decoder.take_byte();
        const record: RecordHeaderNormal = @bitCast(first);

        switch (record.header_kind) {
            .compressed => {
                const compressed: RecordHeaderCompressed = @bitCast(first);
                const local_type = compressed.local_message_type;

                return try decoder.read_data_message(local_type, compressed.time_offset);
            },
            .normal => switch (record.message_kind) {
                .definition => try decoder.read_definition(record),
                .data => return try decoder.read_data_message(record.local_message_type, null),
            },
        }
    }

    return null;
}

fn read_definition(decoder: *Decoder, record: RecordHeaderNormal) Error!void {
    assert(record.header_kind == .normal);
    assert(record.message_kind == .definition);

    _ = try decoder.take_byte();
    const architecture: Endian = if ((try decoder.take_byte()) == 0) .little else .big;
    const global_message_number = try decoder.take_int(u16, architecture);
    const field_count = try decoder.take_byte();

    decoder.definition_sequence += 1;

    const slot = &decoder.definitions[record.local_message_type];

    slot.* = .{
        .global_message_number = global_message_number,
        .architecture = architecture,
        .sequence = decoder.definition_sequence,
        .field_count = field_count,
        .fields = undefined,
        .payload_size_bytes = 0,
        .regular_size_bytes = 0,
        .timestamp_offset = null,
        .developer_fields = undefined,
        .developer_field_count = 0,
    };

    errdefer slot.* = null;

    const definition = &slot.*.?;
    definition.regular_size_bytes = try decoder.read_field_definitions(definition);
    definition.payload_size_bytes = definition.regular_size_bytes;

    if (record.has_developer_data == 1) {
        definition.payload_size_bytes += try decoder.read_developer_fields(definition);
    } else {
        assert(definition.developer_field_count == 0);
        assert(definition.payload_size_bytes == definition.regular_size_bytes);
    }

    assert(slot.* != null);
    assert(definition.global_message_number == global_message_number);
    assert(definition.field_count == field_count);
    assert(definition.developer_field_count <= developer_field_count_max);
    assert(definition.payload_size_bytes >= definition.regular_size_bytes);
    assert(definition.payload_size_bytes <= payload_bytes_max);
}

fn read_field_definitions(decoder: *Decoder, definition: *MessageDefinition) Error!u32 {
    const field_count = definition.field_count;

    var payload_size: u32 = 0;
    var index: u8 = 0;

    while (index < field_count) : (index += 1) {
        const field_definition_number = try decoder.take_byte();
        const size_bytes = try decoder.take_byte();
        const base_type_raw = try decoder.take_byte();

        const base_type = std.enums.fromInt(BaseType, base_type_raw) orelse
            return error.UnknownBaseType;

        assert(base_type.size_bytes() >= 1);
        assert(base_type.size_bytes() <= base_type_bytes_max);

        if (field_definition_number == timestamp_field_number) {
            if (size_bytes == timestamp_size_bytes) {
                definition.timestamp_offset = @intCast(payload_size);
            }
        }

        definition.fields[index] = .{
            .field_definition_number = field_definition_number,
            .size_bytes = size_bytes,
            .base_type = base_type,
        };

        payload_size += size_bytes;

        assert(payload_size <= @as(u32, field_count_max) * field_bytes_max);
    }

    if (definition.timestamp_offset) |offset| {
        assert(@as(u32, offset) + timestamp_size_bytes <= payload_size);
    }

    return payload_size;
}

fn read_developer_fields(decoder: *Decoder, definition: *MessageDefinition) Error!u32 {
    const count = try decoder.take_byte();

    var size_total: u32 = 0;
    var stored: u8 = 0;
    var index: u8 = 0;

    while (index < count) : (index += 1) {
        const field_number = try decoder.take_byte();
        const size_bytes = try decoder.take_byte();
        const developer_data_index = try decoder.take_byte();
        size_total += size_bytes;

        assert(size_total <= @as(u32, field_count_max) * field_bytes_max);

        if (stored < developer_field_count_max) {
            definition.developer_fields[stored] = .{
                .developer_data_index = developer_data_index,
                .field_number = field_number,
                .size_bytes = size_bytes,
            };

            stored += 1;
        } else {
            assert(stored == developer_field_count_max);
        }
    }

    definition.developer_field_count = stored;

    assert(stored <= developer_field_count_max);

    return size_total;
}

fn read_data_message(decoder: *Decoder, local_type: u4, compressed_offset: ?u5) Error!DataMessage {
    const slot = &decoder.definitions[local_type];

    if (slot.* == null) return error.UndefinedLocalType;

    const definition = &slot.*.?;
    const payload = try decoder.take_bytes(definition.payload_size_bytes);

    assert(payload.len == definition.payload_size_bytes);
    assert(payload.len >= definition.regular_size_bytes);
    assert(payload.len <= payload_bytes_max);
    assert(decoder.bytes_remaining <= decoder.header.data_size);

    return .{
        .global_message_number = definition.global_message_number,
        .architecture = definition.architecture,
        .local_type = local_type,
        .definition = definition,
        .payload = payload,
        .timestamp = decoder.message_timestamp(definition, payload, compressed_offset),
    };
}

fn message_timestamp(
    decoder: *Decoder,
    definition: *const MessageDefinition,
    payload: []const u8,
    compressed_offset: ?u5,
) ?u32 {
    if (compressed_offset) |offset| return decoder.reconstruct_timestamp(offset);

    const offset = definition.timestamp_offset orelse return null;
    const end = @as(u32, offset) + timestamp_size_bytes;

    assert(end <= definition.regular_size_bytes);
    assert(end <= payload.len);

    const bytes = payload[offset..][0..timestamp_size_bytes];
    const raw = std.mem.readInt(u32, bytes, definition.architecture);

    if (raw == timestamp_invalid) return null;

    decoder.timestamp = raw;

    assert(bytes.len == timestamp_size_bytes);
    assert(decoder.timestamp.? != timestamp_invalid);

    return raw;
}

fn reconstruct_timestamp(decoder: *Decoder, offset: u5) ?u32 {
    const previous = decoder.timestamp orelse return null;

    var stamp = (previous & ~rollover_mask) | @as(u32, offset);

    if (@as(u32, offset) < (previous & rollover_mask)) {
        stamp +%= rollover_seconds;

        assert(stamp -% previous > 0);
    } else {
        assert(stamp >= (previous & ~rollover_mask));
    }

    decoder.timestamp = stamp;

    assert(stamp & rollover_mask == @as(u32, offset));
    assert(stamp -% previous < rollover_seconds);

    return stamp;
}

fn take_byte(decoder: *Decoder) Error!u8 {
    if (decoder.bytes_remaining < 1) return error.Truncated;

    const byte = decoder.reader.takeByte() catch |err| return map_error(err);
    decoder.bytes_remaining -= 1;

    assert(decoder.bytes_remaining < decoder.header.data_size);

    return byte;
}

fn take_bytes(decoder: *Decoder, count: u32) Error![]const u8 {
    if (count > decoder.bytes_remaining) return error.Truncated;

    const slice = decoder.reader.take(count) catch |err| return map_error(err);
    decoder.bytes_remaining -= count;

    assert(slice.len == count);
    assert(decoder.bytes_remaining <= decoder.header.data_size);

    return slice;
}

fn take_int(decoder: *Decoder, comptime Int: type, architecture: Endian) Error!Int {
    const size = @divExact(@typeInfo(Int).int.bits, 8);
    comptime assert(size >= 1);
    comptime assert(size <= 8);

    if (decoder.bytes_remaining < size) return error.Truncated;

    const value = decoder.reader.takeInt(Int, architecture) catch |err| return map_error(err);
    decoder.bytes_remaining -= size;

    assert(decoder.bytes_remaining <= decoder.header.data_size);

    return value;
}

fn map_error(err: Reader.Error) Error {
    return switch (err) {
        error.EndOfStream => error.Truncated,
        error.ReadFailed => error.ReadFailed,
    };
}

test "decode a single record message" {
    const bytes = [_]u8{
        12,   0x20, 0x8F, 0x08,
        14,   0x00, 0x00, 0x00,
        '.',  'F',  'I',  'T',
        0x40, 0x00, 0x00, 0x14,
        0x00, 0x01, 0xFD, 0x04,
        0x86, 0x00, 0x00, 0xCA,
        0x9A, 0x3B,
    };

    var reader = Reader.fixed(&bytes);
    var decoder = try Decoder.init(&reader);

    const message = (try decoder.next()).?;

    try std.testing.expectEqual(@as(u16, 20), message.global_message_number);
    try std.testing.expectEqual(Endian.little, message.architecture);
    try std.testing.expectEqual(@as(?u32, 1_000_000_000), message.timestamp);

    var iterator = message.fields();
    const field = iterator.next().?;

    try std.testing.expectEqual(@as(u8, 253), field.field_definition_number);
    try std.testing.expectEqual(BaseType.uint32, field.base_type);
    try std.testing.expectEqual(@as(usize, 4), field.data.len);

    try std.testing.expectEqual(
        @as(u32, 1_000_000_000),
        std.mem.readInt(u32, field.data[0..4], .little),
    );

    try std.testing.expect(iterator.next() == null);
    try std.testing.expect((try decoder.next()) == null);
}

test "data message before its definition is an error" {
    const bytes = [_]u8{
        12,   0x20, 0x8F, 0x08,
        1,    0x00, 0x00, 0x00,
        '.',  'F',  'I',  'T',
        0x00,
    };

    var reader = Reader.fixed(&bytes);
    var decoder = try Decoder.init(&reader);

    try std.testing.expectError(error.UndefinedLocalType, decoder.next());
}

test "a non-FIT signature is rejected" {
    const bytes = [_]u8{ 12, 0x20, 0x8F, 0x08, 0, 0, 0, 0, 'N', 'O', 'P', 'E' };

    var reader = Reader.fixed(&bytes);

    try std.testing.expectError(error.NotFitFile, Decoder.init(&reader));
}

test "compressed-timestamp records reconstruct an absolute timestamp" {
    const bytes = [_]u8{
        12,   0x20, 0x8F, 0x08,
        25,   0x00, 0x00, 0x00,
        '.',  'F',  'I',  'T',
        0x40, 0x00, 0x00, 0x14,
        0x00, 0x01, 0xFD, 0x04,
        0x86, 0x00, 0xE8, 0x03,
        0x00, 0x00, 0x41, 0x00,
        0x00, 0x15, 0x00, 0x01,
        0x03, 0x01, 0x02, 0xAA,
        0x64,
    };

    var reader = Reader.fixed(&bytes);
    var decoder = try Decoder.init(&reader);

    const base = (try decoder.next()).?;

    try std.testing.expectEqual(@as(?u32, 1000), base.timestamp);

    const compressed = (try decoder.next()).?;

    try std.testing.expectEqual(@as(u16, 21), compressed.global_message_number);
    try std.testing.expectEqual(@as(?u32, 1002), compressed.timestamp);

    var iterator = compressed.fields();
    const heart_rate = iterator.next().?;

    try std.testing.expectEqual(@as(u8, 3), heart_rate.field_definition_number);
    try std.testing.expectEqual(@as(u8, 100), heart_rate.data[0]);

    try std.testing.expect((try decoder.next()) == null);
}
