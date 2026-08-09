const std = @import("std");

const Decoder = @import("decoder.zig");
const crc = @import("crc.zig");
const zfit = @import("root.zig");

const Allocator = std.mem.Allocator;
const BaseType = Decoder.BaseType;
const RecordHeaderNormal = Decoder.RecordHeaderNormal;
const Writer = std.Io.Writer;
const assert = std.debug.assert;

const Encoder = @This();

gpa: Allocator,
body: std.ArrayList(u8) = .empty,
slots: [local_type_count]?u64 = .{null} ** local_type_count,
clock: u4 = 0,

pub const Error = Allocator.Error || Writer.Error || error{
    TooManyFields,
    StringTooLong,
    FileTooLarge,
};

pub const Value = union(enum) {
    enum_value: u8,
    uint8: u8,
    uint16: u16,
    uint32: u32,
    sint8: i8,
    sint16: i16,
    sint32: i32,
    float32: f32,
    float64: f64,
    string: []const u8,

    fn base_type(value: Value) BaseType {
        const base = switch (value) {
            .enum_value => BaseType.enum_value,
            .uint8 => BaseType.uint8,
            .uint16 => BaseType.uint16,
            .uint32 => BaseType.uint32,
            .sint8 => BaseType.sint8,
            .sint16 => BaseType.sint16,
            .sint32 => BaseType.sint32,
            .float32 => BaseType.float32,
            .float64 => BaseType.float64,
            .string => BaseType.string,
        };

        if (value != .string) assert(base.size_bytes() == value.size_bytes());

        return base;
    }

    fn size_bytes(value: Value) u8 {
        const size: u8 = switch (value) {
            .enum_value, .uint8, .sint8 => 1,
            .uint16, .sint16 => 2,
            .uint32, .sint32, .float32 => 4,
            .float64 => 8,
            .string => |text| blk: {
                assert(text.len <= string_bytes_max);

                break :blk @intCast(text.len + 1);
            },
        };

        assert(size <= Decoder.field_bytes_max);

        return size;
    }

    fn write(value: Value, body: *std.ArrayList(u8), gpa: Allocator) Allocator.Error!void {
        const before = body.items.len;

        switch (value) {
            .enum_value, .uint8 => |number| try body.append(gpa, number),
            .sint8 => |number| try body.append(gpa, @bitCast(number)),
            .uint16 => |number| try append_int(body, gpa, u16, number),
            .sint16 => |number| try append_int(body, gpa, u16, @bitCast(number)),
            .uint32 => |number| try append_int(body, gpa, u32, number),
            .sint32 => |number| try append_int(body, gpa, u32, @bitCast(number)),
            .float32 => |number| try append_int(body, gpa, u32, @bitCast(number)),
            .float64 => |number| try append_int(body, gpa, u64, @bitCast(number)),
            .string => |text| {
                assert(text.len <= string_bytes_max);

                try body.appendSlice(gpa, text);
                try body.append(gpa, 0);
            },
        }

        assert(body.items.len == before + value.size_bytes());
    }
};

pub const Field = struct {
    number: u8,
    value: Value,
};

pub const local_type_count = Decoder.local_type_count;

pub const field_count_max = Decoder.field_count_max;

pub const string_bytes_max = Decoder.field_bytes_max - 1;

const architecture_little_endian = 0;

const protocol_version = 0x20;

const profile_version = 0;

const definition_fixed_bytes = 6;

comptime {
    assert(local_type_count == std.math.maxInt(u4) + 1);
    assert(protocol_version >> 4 == 2);
    assert(definition_fixed_bytes == 1 + 1 + 1 + 2 + 1);
}

pub fn init(gpa: Allocator) Encoder {
    return .{ .gpa = gpa };
}

pub fn deinit(encoder: *Encoder) void {
    encoder.body.deinit(encoder.gpa);
}

pub fn message(encoder: *Encoder, global_number: u16, fields: []const Field) Error!void {
    try validate(fields);

    const print = fingerprint(global_number, fields);
    const before = encoder.body.items.len;

    if (encoder.find_slot(print)) |local| {
        try encoder.write_data(local, fields);

        assert(encoder.slots[local].? == print);
        assert(encoder.body.items.len > before);

        return;
    }

    const local = encoder.clock;
    encoder.clock +%= 1;
    encoder.slots[local] = print;

    try encoder.write_definition(local, global_number, fields);
    try encoder.write_data(local, fields);

    assert(encoder.body.items.len > before);
    assert(encoder.find_slot(print).? == local);
}

pub fn finish(encoder: *Encoder, out: *Writer) Error!void {
    const body = encoder.body.items;

    if (body.len > Decoder.data_size_max) return error.FileTooLarge;

    const signature_end = Decoder.signature_offset + Decoder.signature_bytes;

    var header: [Decoder.header_bytes]u8 = undefined;
    header[0] = Decoder.header_bytes;
    header[1] = protocol_version;
    std.mem.writeInt(u16, header[2..4], profile_version, .little);
    std.mem.writeInt(u32, header[4..8], @intCast(body.len), .little);
    @memcpy(header[Decoder.signature_offset..signature_end], Decoder.file_signature);

    var checksum = crc.checksum(0, &header);
    checksum = crc.checksum(checksum, body);

    var trailer: [crc.checksum_bytes]u8 = undefined;
    std.mem.writeInt(u16, &trailer, checksum, .little);

    const signature = header[Decoder.signature_offset..signature_end];

    assert(std.mem.readInt(u32, header[4..8], .little) == body.len);
    assert(std.mem.eql(u8, signature, Decoder.file_signature));

    try out.writeAll(&header);
    try out.writeAll(body);
    try out.writeAll(&trailer);
}

fn validate(fields: []const Field) Error!void {
    if (fields.len > field_count_max) return error.TooManyFields;

    for (fields) |field| {
        switch (field.value) {
            .string => |text| if (text.len > string_bytes_max) return error.StringTooLong,
            .enum_value, .uint8, .uint16, .uint32 => {},
            .sint8, .sint16, .sint32 => {},
            .float32, .float64 => {},
        }
    }
}

fn find_slot(encoder: *const Encoder, print: u64) ?u4 {
    for (encoder.slots, 0..) |slot, index| {
        if (slot) |cached| {
            if (cached == print) return @intCast(index);
        }
    }

    return null;
}

fn write_definition(
    encoder: *Encoder,
    local: u4,
    global_number: u16,
    fields: []const Field,
) Error!void {
    assert(fields.len <= field_count_max);

    const gpa = encoder.gpa;
    const before = encoder.body.items.len;

    const record = RecordHeaderNormal{
        .local_message_type = local,
        .reserved = 0,
        .has_developer_data = 0,
        .message_kind = .definition,
        .header_kind = .normal,
    };

    try encoder.body.append(gpa, @bitCast(record));
    try encoder.body.append(gpa, 0x00);
    try encoder.body.append(gpa, architecture_little_endian);
    try append_int(&encoder.body, gpa, u16, global_number);
    try encoder.body.append(gpa, @intCast(fields.len));

    for (fields) |field| {
        try encoder.body.append(gpa, field.number);
        try encoder.body.append(gpa, field.value.size_bytes());
        try encoder.body.append(gpa, @intFromEnum(field.value.base_type()));
    }

    assert(encoder.body.items.len == before + definition_fixed_bytes + 3 * fields.len);
}

fn write_data(encoder: *Encoder, local: u4, fields: []const Field) Error!void {
    assert(fields.len <= field_count_max);

    const before = encoder.body.items.len;

    const record = RecordHeaderNormal{
        .local_message_type = local,
        .reserved = 0,
        .has_developer_data = 0,
        .message_kind = .data,
        .header_kind = .normal,
    };

    try encoder.body.append(encoder.gpa, @bitCast(record));
    for (fields) |field| try field.value.write(&encoder.body, encoder.gpa);

    var payload_size: u32 = 0;

    for (fields) |field| payload_size += field.value.size_bytes();

    assert(encoder.body.items.len == before + 1 + payload_size);
}

fn append_int(
    body: *std.ArrayList(u8),
    gpa: Allocator,
    comptime Int: type,
    value: Int,
) Allocator.Error!void {
    const size = @divExact(@typeInfo(Int).int.bits, 8);
    comptime assert(size >= 1);
    comptime assert(size <= 8);

    var buffer: [size]u8 = undefined;
    std.mem.writeInt(Int, &buffer, value, .little);

    try body.appendSlice(gpa, &buffer);
}

fn fingerprint(global_number: u16, fields: []const Field) u64 {
    assert(fields.len <= field_count_max);

    var hasher = std.hash.Wyhash.init(global_number);

    for (fields) |field| {
        const layout = [_]u8{
            field.number,
            field.value.size_bytes(),
            @intFromEnum(field.value.base_type()),
        };

        hasher.update(&layout);
    }

    return hasher.final();
}

test "encode then decode round-trips values" {
    var encoder = Encoder.init(std.testing.allocator);
    defer encoder.deinit();

    try encoder.message(0, &.{
        .{ .number = 0, .value = .{ .enum_value = 4 } },
        .{ .number = 1, .value = .{ .uint16 = 1 } },
        .{ .number = 3, .value = .{ .uint32 = 12345 } },
    });

    try encoder.message(20, &.{
        .{ .number = 253, .value = .{ .uint32 = 1_000_000_000 } },
        .{ .number = 3, .value = .{ .uint8 = 75 } },
    });

    var storage: [256]u8 = undefined;
    var out = Writer.fixed(&storage);

    try encoder.finish(&out);

    const bytes = out.buffered();

    const body = bytes[0 .. bytes.len - 2];
    const stored_crc = std.mem.readInt(u16, bytes[bytes.len - 2 ..][0..2], .little);

    try std.testing.expectEqual(crc.checksum(0, body), stored_crc);

    var reader = std.Io.Reader.fixed(bytes);
    var decoder = try Decoder.init(&reader);

    const file_id = (try decoder.next()).?;

    try std.testing.expectEqual(@as(u16, 0), file_id.global_message_number);

    var file_id_fields = file_id.fields();

    try std.testing.expectEqual(@as(u8, 4), file_id_fields.next().?.data[0]);

    const record = (try decoder.next()).?;

    try std.testing.expectEqual(@as(u16, 20), record.global_message_number);
    try std.testing.expectEqual(@as(?u32, 1_000_000_000), record.timestamp);

    try std.testing.expect((try decoder.next()) == null);
}

test "repeated message layout reuses one definition" {
    var encoder = Encoder.init(std.testing.allocator);
    defer encoder.deinit();

    const fields = [_]Field{.{ .number = 3, .value = .{ .uint8 = 60 } }};

    try encoder.message(20, &fields);

    const after_first = encoder.body.items.len;

    try encoder.message(20, &fields);

    const after_second = encoder.body.items.len;

    try std.testing.expectEqual(@as(usize, 2), after_second - after_first);
}

test "encoder rejects a string longer than a field size can express" {
    var encoder = Encoder.init(std.testing.allocator);
    defer encoder.deinit();

    const too_long = "x" ** (string_bytes_max + 1);
    const fields = [_]Field{.{ .number = 3, .value = .{ .string = too_long } }};

    try std.testing.expectError(error.StringTooLong, encoder.message(20, &fields));

    try std.testing.expectEqual(@as(usize, 0), encoder.body.items.len);
}

test "encoder accepts a string that exactly fills a field" {
    var encoder = Encoder.init(std.testing.allocator);
    defer encoder.deinit();

    const longest = "x" ** string_bytes_max;
    const fields = [_]Field{.{ .number = 3, .value = .{ .string = longest } }};

    try encoder.message(20, &fields);

    var storage: [1024]u8 = undefined;
    var out = Writer.fixed(&storage);

    try encoder.finish(&out);
    try zfit.verify_checksum(out.buffered());
}

test "encoder rejects more fields than a definition can declare" {
    var encoder = Encoder.init(std.testing.allocator);
    defer encoder.deinit();

    const fields = [_]Field{.{ .number = 3, .value = .{ .uint8 = 1 } }} ** 256;

    try std.testing.expectError(error.TooManyFields, encoder.message(20, &fields));
}
