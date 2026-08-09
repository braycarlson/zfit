const std = @import("std");

const Decoder = @import("decoder.zig");
const crc = @import("crc.zig");
const garmin = @import("garmin.zig");
const profile = @import("profile.zig");
const values = @import("value.zig");

const Allocator = std.mem.Allocator;
const DataMessage = Decoder.DataMessage;
const Endian = std.builtin.Endian;
const FieldInfo = profile.FieldInfo;
const MessageInfo = profile.MessageInfo;
const RawField = Decoder.Field;
const Value = values.Value;
const assert = std.debug.assert;

pub const Error = Decoder.Error || Allocator.Error || error{TooManySegments};

pub const Field = struct {
    number: u16,
    name: []const u8,
    fit_type: []const u8,
    units: []const u8,
    value: Value,
};

pub const Message = struct {
    global_number: u16,
    name: []const u8,
    timestamp: ?u32,
    fields: []const Field,
};

const DeveloperFieldInfo = struct {
    name: []const u8,
    units: []const u8,
    base_type: Decoder.BaseType,
    scale: f64,
    offset: f64,
};

const Resolution = struct {
    sequence: u32,
    info: ?*const MessageInfo,
    fields: []const ?*const FieldInfo,
};

const ResolvedInfo = struct {
    message: ?*const MessageInfo,
    field: ?*const FieldInfo,
};

pub const Stream = struct {
    decoder: *Decoder,
    gpa: Allocator,
    accumulators: std.AutoHashMapUnmanaged(u32, u64) = .empty,
    developer_field_infos: std.AutoHashMapUnmanaged(u16, DeveloperFieldInfo) = .empty,
    developer_arena: std.heap.ArenaAllocator,
    resolutions: [Decoder.local_type_count]?Resolution = .{null} ** Decoder.local_type_count,

    pub fn init(decoder: *Decoder, gpa: Allocator) Stream {
        assert(decoder.bytes_remaining == decoder.header.data_size);
        assert(decoder.timestamp == null);

        return .{
            .decoder = decoder,
            .gpa = gpa,
            .developer_arena = std.heap.ArenaAllocator.init(gpa),
        };
    }

    pub fn deinit(stream: *Stream) void {
        stream.invalidate_resolutions();
        stream.accumulators.deinit(stream.gpa);
        stream.developer_field_infos.deinit(stream.gpa);
        stream.developer_arena.deinit();
    }

    fn invalidate_resolutions(stream: *Stream) void {
        for (&stream.resolutions) |*slot| {
            if (slot.*) |resolution| stream.gpa.free(resolution.fields);
            slot.* = null;
        }
    }

    fn resolve(stream: *Stream, message: *const DataMessage) Allocator.Error!*const Resolution {
        const definition = message.definition;
        const slot = &stream.resolutions[message.local_type];

        if (slot.*) |*cached| {
            if (cached.sequence == definition.sequence) return cached;

            stream.gpa.free(cached.fields);
            slot.* = null;
        }

        const info = profile.message_info(definition.global_message_number);
        const resolved = try stream.gpa.alloc(?*const FieldInfo, definition.field_count);

        for (resolved, definition.fields[0..definition.field_count]) |*entry, field| {
            entry.* = if (info) |message_info|
                message_info.field(field.field_definition_number)
            else
                null;
        }

        slot.* = .{ .sequence = definition.sequence, .info = info, .fields = resolved };

        assert(slot.*.?.fields.len == definition.field_count);

        return &slot.*.?;
    }

    pub fn next(stream: *Stream, arena: Allocator) Error!?Message {
        var segment: u32 = 0;

        while (segment < segment_count_max) : (segment += 1) {
            if (try stream.decoder.next()) |message| {
                assert(message.payload.len == message.definition.payload_size_bytes);

                return try stream.decode_message(arena, &message);
            }

            if (!try stream.advance_segment()) return null;
        }

        return error.TooManySegments;
    }

    fn advance_segment(stream: *Stream) Error!bool {
        const reader = stream.decoder.reader;

        reader.discardAll(crc.checksum_bytes) catch |err| switch (err) {
            error.EndOfStream => return false,
            error.ReadFailed => return error.ReadFailed,
        };

        if (reader.bufferedLen() < Decoder.header_bytes) return false;

        stream.decoder.* = Decoder.init(reader) catch |err| switch (err) {
            error.ReadFailed => return error.ReadFailed,
            error.Truncated,
            error.NotFitFile,
            error.BadHeaderSize,
            error.FileTooLarge,
            error.UnknownBaseType,
            error.UndefinedLocalType,
            => return false,
        };

        stream.invalidate_resolutions();

        assert(stream.decoder.bytes_remaining == stream.decoder.header.data_size);
        assert(stream.decoder.header.data_size <= Decoder.data_size_max);
        assert(stream.decoder.reader == reader);

        return true;
    }

    fn decode_message(
        stream: *Stream,
        arena: Allocator,
        message: *const DataMessage,
    ) Error!Message {
        const resolution = try stream.resolve(message);

        var fields: std.ArrayList(Field) = .empty;
        var raw_fields = message.fields();
        var index: u32 = 0;

        while (raw_fields.next()) |raw| : (index += 1) {
            try stream.append_field(arena, &fields, message, raw, .{
                .message = resolution.info,
                .field = resolution.fields[index],
            });
        }

        try stream.append_developer_fields(arena, &fields, message);

        if (message.global_message_number == field_description_number) {
            try stream.learn_field_description(message);
        }

        if (message.global_message_number == garmin.channel_message_number) {
            try append_channel_233(arena, &fields, message);
        }

        const name = if (resolution.info) |message_info|
            message_info.name
        else
            garmin.message_name(message.global_message_number) orelse unknown_message_name;

        assert(index == message.definition.field_count);
        assert(fields.items.len >= message.definition.field_count);

        return .{
            .global_number = message.global_message_number,
            .name = name,
            .timestamp = message.timestamp,
            .fields = try fields.toOwnedSlice(arena),
        };
    }

    fn append_developer_fields(
        stream: *Stream,
        arena: Allocator,
        fields: *std.ArrayList(Field),
        message: *const DataMessage,
    ) Error!void {
        const before = fields.items.len;

        var iterator = message.developer_fields();

        while (iterator.next()) |developer| {
            const key = developer_key(.{
                .developer_data_index = developer.developer_data_index,
                .field_number = developer.field_number,
            });

            const developer_info = stream.developer_field_infos.get(key) orelse {
                try append_opaque_developer_field(arena, fields, developer);
                continue;
            };

            assert(developer_info.scale != 0.0);
            assert(std.math.isFinite(developer_info.offset));

            const meta = values.Meta{
                .name = developer_info.name,
                .fit_type = "",
                .type_id = null,
                .scale = developer_info.scale,
                .offset = developer_info.offset,
                .units = developer_info.units,
            };

            const raw = RawField{
                .field_definition_number = developer.field_number,
                .base_type = developer_info.base_type,
                .data = developer.data,
            };

            try fields.append(arena, .{
                .number = developer.field_number,
                .name = developer_info.name,
                .fit_type = "",
                .units = developer_info.units,
                .value = try decode_value(arena, raw, meta, message.architecture),
            });
        }

        assert(fields.items.len >= before);
        assert(fields.items.len - before <= Decoder.developer_field_count_max);
    }

    fn learn_field_description(stream: *Stream, message: *const DataMessage) Error!void {
        const strings = stream.developer_arena.allocator();

        var developer_data_index: ?u8 = null;
        var field_number: ?u8 = null;
        var base_type: Decoder.BaseType = .uint8;
        var name: []const u8 = "";
        var units: []const u8 = "";
        var scale: f64 = 1.0;
        var offset: f64 = 0.0;

        var iterator = message.fields();

        while (iterator.next()) |field| {
            switch (field.field_definition_number) {
                0 => developer_data_index = scalar_u8(field),
                1 => field_number = scalar_u8(field),
                2 => if (scalar_u8(field)) |id| {
                    base_type = std.enums.fromInt(Decoder.BaseType, id) orelse .uint8;
                },
                3 => name = try strings.dupe(u8, values.c_string(field.data)),
                6 => if (scalar_u8(field)) |value| {
                    if (value != 0) scale = @floatFromInt(value);
                },
                7 => if (scalar_i8(field)) |value| {
                    offset = @floatFromInt(value);
                },
                8 => units = try strings.dupe(u8, values.c_string(field.data)),
                else => {},
            }
        }

        const index = developer_data_index orelse return;
        const number = field_number orelse return;

        const key = developer_key(.{ .developer_data_index = index, .field_number = number });

        assert(scale != 0.0);
        assert(std.math.isFinite(scale));
        assert(std.math.isFinite(offset));
        assert(base_type.size_bytes() >= 1);

        try stream.developer_field_infos.put(stream.gpa, key, .{
            .name = name,
            .units = units,
            .base_type = base_type,
            .scale = scale,
            .offset = offset,
        });

        assert(stream.developer_field_infos.contains(key));
    }

    fn append_field(
        stream: *Stream,
        arena: Allocator,
        fields: *std.ArrayList(Field),
        message: *const DataMessage,
        raw: RawField,
        resolved: ResolvedInfo,
    ) Error!void {
        const architecture = message.architecture;

        const meta = if (resolved.field) |info|
            values.meta_for(message, info)
        else
            supplement_meta(message.global_message_number, raw.field_definition_number);

        var value = try decode_value(arena, raw, meta, architecture);

        if (resolved.field) |info| {
            if (accumulates(raw, info)) {
                value = try stream.accumulate_field(message, raw, meta, value);
            }
        }

        const name = if (meta.name.len > 0)
            meta.name
        else
            try std.fmt.allocPrint(arena, unknown_field_format, .{raw.field_definition_number});

        try fields.append(arena, .{
            .number = raw.field_definition_number,
            .name = name,
            .fit_type = meta.fit_type,
            .units = meta.units,
            .value = value,
        });

        if (resolved.field) |info| {
            const message_info = resolved.message orelse return;

            try stream.expand_components(arena, fields, message, raw, message_info, info);
        }
    }

    fn accumulate_field(
        stream: *Stream,
        message: *const DataMessage,
        raw: RawField,
        meta: values.Meta,
        decoded: Value,
    ) Error!Value {
        assert(raw.data.len >= 1);
        assert(raw.data.len < accumulator_bytes_max);

        const reading = values.field_unsigned(raw, message.architecture) orelse return decoded;
        const bits: u7 = @intCast(raw.data.len * 8);
        const key = accumulator_key(message.global_message_number, raw.field_definition_number);

        assert(bits >= 8);
        assert(bits < packed_bits_max);

        const total = try stream.accumulate(key, reading, bits);

        assert(total >= reading);

        return scaled_unsigned(total, .{ .scale = meta.scale, .offset = meta.offset });
    }

    fn expand_components(
        stream: *Stream,
        arena: Allocator,
        fields: *std.ArrayList(Field),
        message: *const DataMessage,
        raw: RawField,
        info: *const MessageInfo,
        field_info: *const FieldInfo,
    ) Error!void {
        if (field_info.components.len == 0) return;

        const packed_value = values.raw_bits(raw.data, message.architecture) orelse return;

        var bit_offset: u32 = 0;

        for (field_info.components) |component| {
            if (component.bits == 0) break;
            if (component.bits > packed_bits_max) break;
            if (bit_offset + component.bits > packed_bits_max) break;

            const width: u7 = @intCast(component.bits);
            const mask = values.low_bits_mask(width);

            var extracted = (packed_value >> @intCast(bit_offset)) & mask;
            bit_offset += component.bits;

            assert(width >= 1);
            assert(bit_offset <= packed_bits_max);
            assert(extracted <= mask);

            if (component.accumulate) {
                const key = accumulator_key(message.global_message_number, component.field_number);
                extracted = try stream.accumulate(key, extracted, width);

                assert(extracted & mask == (packed_value >> @intCast(bit_offset - width)) & mask);
            }

            try append_component(arena, fields, info, component, extracted);
        }

        assert(bit_offset <= packed_bits_max);
    }

    fn accumulate(stream: *Stream, key: u32, value: u64, bits: u7) Allocator.Error!u64 {
        assert(bits >= 1);
        assert(bits <= packed_bits_max);

        return accumulate_into(&stream.accumulators, stream.gpa, key, value, bits);
    }
};

const DeveloperKey = struct {
    developer_data_index: u8,
    field_number: u8,
};

const Scaling = struct {
    scale: f64,
    offset: f64,
};

pub const segment_count_max = 1024;

const packed_bits_max = values.bits_max;

const accumulator_bytes_max = values.bytes_max;

const unknown_field_format = "field_{d}";

const unknown_message_name = "unknown";

const timestamp_meta = values.Meta{
    .name = "timestamp",
    .fit_type = "date_time",
    .type_id = null,
    .scale = 1.0,
    .offset = 0.0,
    .units = "",
};

const opaque_developer_field_prefix = "dev_";
const opaque_developer_field_format = opaque_developer_field_prefix ++ "{d}_{d}";

const field_description_number = 206;

const uint8_invalid: u8 = @intCast(Decoder.BaseType.uint8.invalid_value().?);
const sint8_invalid: u8 = @intCast(Decoder.BaseType.sint8.invalid_value().?);

comptime {
    assert(packed_bits_max == 64);
    assert(accumulator_bytes_max == 8);
    assert(uint8_invalid == 0xFF);
    assert(sint8_invalid == 0x7F);
}

pub fn accumulate_into(
    map: *std.AutoHashMapUnmanaged(u32, u64),
    gpa: Allocator,
    key: u32,
    value: u64,
    bits: u7,
) Allocator.Error!u64 {
    const mask = values.low_bits_mask(bits);

    assert(value <= mask);

    const entry = try map.getOrPut(gpa, key);

    if (!entry.found_existing) entry.value_ptr.* = 0;

    var accumulated = entry.value_ptr.*;
    accumulated +%= (value -% accumulated) & mask;
    entry.value_ptr.* = accumulated;

    assert(accumulated & mask == value);
    assert(accumulated >= value);

    return accumulated;
}

fn supplement_meta(global_number: u16, field_number: u8) values.Meta {
    if (field_number == Decoder.timestamp_field_number) return timestamp_meta;

    const found = garmin.field_supplement(global_number, field_number) orelse
        return values.plain;

    return .{
        .name = found.name,
        .fit_type = found.fit_type,
        .type_id = null,
        .scale = found.scale,
        .offset = found.offset,
        .units = found.units,
    };
}

fn accumulates(raw: RawField, info: *const FieldInfo) bool {
    if (!info.accumulate) return false;
    if (!is_scalar(raw)) return false;
    if (raw.data.len >= accumulator_bytes_max) return false;

    return true;
}

fn is_scalar(raw: RawField) bool {
    const element = raw.base_type.size_bytes();

    assert(element >= 1);
    assert(element <= accumulator_bytes_max);

    return raw.data.len == element;
}

fn accumulator_key(global_number: u16, field_number: u8) u32 {
    const key = (@as(u32, global_number) << 8) | field_number;

    assert(key >> 8 == global_number);
    assert(key & 0xFF == field_number);

    return key;
}

fn developer_key(identity: DeveloperKey) u16 {
    const key = (@as(u16, identity.developer_data_index) << 8) | identity.field_number;

    assert(key >> 8 == identity.developer_data_index);
    assert(key & 0xFF == identity.field_number);

    return key;
}

fn scalar_u8(field: RawField) ?u8 {
    if (field.data.len == 0) return null;
    if (field.data[0] == uint8_invalid) return null;

    return field.data[0];
}

fn scalar_i8(field: RawField) ?i8 {
    if (field.data.len == 0) return null;
    if (field.data[0] == sint8_invalid) return null;

    return @bitCast(field.data[0]);
}

fn append_opaque_developer_field(
    arena: Allocator,
    fields: *std.ArrayList(Field),
    developer: Decoder.DeveloperField,
) Error!void {
    const before = fields.items.len;

    const name = try std.fmt.allocPrint(arena, opaque_developer_field_format, .{
        developer.developer_data_index,
        developer.field_number,
    });

    assert(name.len > opaque_developer_field_prefix.len);
    assert(std.mem.startsWith(u8, name, opaque_developer_field_prefix));
    assert(developer.data.len <= Decoder.field_bytes_max);

    try fields.append(arena, .{
        .number = developer.field_number,
        .name = name,
        .fit_type = "",
        .units = "",
        .value = .{ .bytes = developer.data },
    });

    assert(fields.items.len == before + 1);
}

fn append_component(
    arena: Allocator,
    fields: *std.ArrayList(Field),
    info: *const MessageInfo,
    component: profile.Component,
    raw: u64,
) Error!void {
    assert(component.bits >= 1);
    assert(component.bits <= packed_bits_max);

    const before = fields.items.len;
    const target = info.field(component.field_number);

    if (target) |field_info| assert(field_info.number == component.field_number);

    const name = if (target) |field_info|
        field_info.name
    else
        try std.fmt.allocPrint(arena, unknown_field_format, .{component.field_number});

    try fields.append(arena, .{
        .number = component.field_number,
        .name = name,
        .fit_type = if (target) |field_info| field_info.fit_type else "",
        .units = if (target) |field_info| field_info.units else "",
        .value = scaled_unsigned(raw, .{ .scale = component.scale, .offset = component.offset }),
    });

    assert(fields.items.len == before + 1);
}

fn append_channel_233(
    arena: Allocator,
    fields: *std.ArrayList(Field),
    message: *const DataMessage,
) Error!void {
    const before = fields.items.len;

    assert(message.global_message_number == garmin.channel_message_number);

    var raw_fields = message.fields();

    while (raw_fields.next()) |raw| {
        if (raw.field_definition_number != garmin.channel_field_number) continue;

        const sample = garmin.channel_233(raw.data) orelse continue;

        assert(sample.id <= std.math.maxInt(u5));
        assert(sample.value <= std.math.maxInt(u27));

        try fields.append(arena, .{
            .number = garmin.channel_field_number,
            .name = garmin.channel_field_name,
            .fit_type = "",
            .units = "",
            .value = .{ .unsigned = sample.id },
        });

        try fields.append(arena, .{
            .number = garmin.channel_field_number,
            .name = garmin.channel_value_field_name,
            .fit_type = "",
            .units = "",
            .value = .{ .unsigned = sample.value },
        });
    }

    assert(fields.items.len >= before);
    assert((fields.items.len - before) % 2 == 0);
}

fn scaled_unsigned(raw: u64, scaling: Scaling) Value {
    assert(scaling.scale != 0.0);
    assert(std.math.isFinite(scaling.scale));
    assert(std.math.isFinite(scaling.offset));

    if (scaling.scale != 1.0 or scaling.offset != 0.0) {
        return .{ .real = @as(f64, @floatFromInt(raw)) / scaling.scale - scaling.offset };
    }

    assert(scaling.scale == 1.0);
    assert(scaling.offset == 0.0);

    return .{ .unsigned = raw };
}

fn decode_value(
    arena: Allocator,
    raw: RawField,
    meta: values.Meta,
    architecture: Endian,
) Error!Value {
    const base = raw.base_type;
    const element = base.size_bytes();

    assert(element >= 1);
    assert(element <= values.bytes_max);

    if (raw.data.len == 0) return .none;
    if (base == .string) return values.decode(raw, meta, architecture);

    if (base == .byte) {
        if (raw.data.len != 1) return .{ .bytes = raw.data };
    }

    if (raw.data.len == element) return values.decode(raw, meta, architecture);
    if (raw.data.len < element) return .none;

    assert(raw.data.len > element);

    const count = @divFloor(raw.data.len, element);
    const scaled = meta.scale != 1.0 or meta.offset != 0.0 or base.is_float();

    assert(count >= 1);
    assert(count <= Decoder.field_bytes_max);
    assert(count * element <= raw.data.len);

    if (scaled) return decode_real_array(arena, raw, meta, architecture, count);

    return decode_integer_array(arena, raw, meta, architecture, count);
}

fn decode_real_array(
    arena: Allocator,
    raw: RawField,
    meta: values.Meta,
    architecture: Endian,
    count: usize,
) Error!Value {
    const element = raw.base_type.size_bytes();

    assert(count >= 1);
    assert(element >= 1);
    assert(count * element <= raw.data.len);

    const out = try arena.alloc(f64, count);

    assert(out.len == count);

    for (out, 0..) |*slot, index| {
        const field = element_field(raw, index, element);

        slot.* = switch (values.decode(field, meta, architecture)) {
            .real => |number| number,
            .integer => |number| @floatFromInt(number),
            .unsigned => |number| @floatFromInt(number),
            .none, .string, .enumeration, .bytes => std.math.nan(f64),
            .integer_array, .real_array => std.math.nan(f64),
        };
    }

    return .{ .real_array = out };
}

fn decode_integer_array(
    arena: Allocator,
    raw: RawField,
    meta: values.Meta,
    architecture: Endian,
    count: usize,
) Error!Value {
    const element = raw.base_type.size_bytes();

    assert(count >= 1);
    assert(element >= 1);
    assert(count * element <= raw.data.len);

    const out = try arena.alloc(i64, count);

    assert(out.len == count);

    for (out, 0..) |*slot, index| {
        const field = element_field(raw, index, element);

        slot.* = switch (values.decode(field, meta, architecture)) {
            .integer => |number| number,
            .unsigned => |number| std.math.cast(i64, number) orelse 0,
            .none, .real, .string, .enumeration, .bytes => 0,
            .integer_array, .real_array => 0,
        };
    }

    return .{ .integer_array = out };
}

fn element_field(raw: RawField, index: usize, element: u8) RawField {
    const start = index * element;
    const end = start + element;

    assert(element >= 1);
    assert(start < raw.data.len);
    assert(end - start == element);
    assert(end <= raw.data.len);

    return .{
        .field_definition_number = raw.field_definition_number,
        .base_type = raw.base_type,
        .data = raw.data[start..end],
    };
}

test "stream decodes named, timestamped fields" {
    const bytes = [_]u8{
        12,   0x20, 0x8F, 0x08,
        14,   0x00, 0x00, 0x00,
        '.',  'F',  'I',  'T',
        0x40, 0x00, 0x00, 0x14,
        0x00, 0x01, 0xFD, 0x04,
        0x86, 0x00, 0x00, 0xCA,
        0x9A, 0x3B,
    };

    var reader = std.Io.Reader.fixed(&bytes);
    var decoder = try Decoder.init(&reader);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var stream = Stream.init(&decoder, std.testing.allocator);
    defer stream.deinit();

    const message = (try stream.next(arena_state.allocator())).?;

    try std.testing.expectEqualStrings("record", message.name);
    try std.testing.expectEqual(@as(?u32, 1_000_000_000), message.timestamp);
    try std.testing.expectEqual(@as(usize, 1), message.fields.len);
    try std.testing.expectEqualStrings("timestamp", message.fields[0].name);

    try std.testing.expect((try stream.next(arena_state.allocator())) == null);
}

test "stream expands a component into its target field" {
    const bytes = [_]u8{
        12,   0x20, 0x8F, 0x08,
        12,   0x00, 0x00, 0x00,
        '.',  'F',  'I',  'T',
        0x40, 0x00, 0x00, 0x14,
        0x00, 0x01, 0x06, 0x02,
        0x84, 0x00, 0xD0, 0x07,
    };

    var reader = std.Io.Reader.fixed(&bytes);
    var decoder = try Decoder.init(&reader);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var stream = Stream.init(&decoder, std.testing.allocator);
    defer stream.deinit();

    const message = (try stream.next(arena_state.allocator())).?;

    try std.testing.expectEqual(@as(usize, 2), message.fields.len);
    try std.testing.expectEqualStrings("speed", message.fields[0].name);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), message.fields[0].value.real, 1e-9);
    try std.testing.expectEqualStrings("enhanced_speed", message.fields[1].name);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), message.fields[1].value.real, 1e-9);
}

test "stream decodes array fields" {
    const bytes = [_]u8{
        12,   0x20, 0x8F, 0x08,
        13,   0x00, 0x00, 0x00,
        '.',  'F',  'I',  'T',
        0x40, 0x00, 0x00, 0x14,
        0x00, 0x01, 0xC8, 0x03,
        0x02, 0x00, 0x0A, 0x14,
        0x1E,
    };

    var reader = std.Io.Reader.fixed(&bytes);
    var decoder = try Decoder.init(&reader);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var stream = Stream.init(&decoder, std.testing.allocator);
    defer stream.deinit();

    const message = (try stream.next(arena_state.allocator())).?;

    try std.testing.expectEqual(@as(usize, 1), message.fields.len);

    const array = message.fields[0].value.integer_array;

    try std.testing.expectEqual(@as(usize, 3), array.len);
    try std.testing.expectEqual(@as(i64, 10), array[0]);
    try std.testing.expectEqual(@as(i64, 30), array[2]);
}

test "stream chains multiple FIT segments" {
    const segment = [_]u8{
        12,   0x20, 0x8F, 0x08,
        14,   0x00, 0x00, 0x00,
        '.',  'F',  'I',  'T',
        0x40, 0x00, 0x00, 0x14,
        0x00, 0x01, 0xFD, 0x04,
        0x86, 0x00, 0x00, 0xCA,
        0x9A, 0x3B, 0x00, 0x00,
    };

    const bytes = segment ++ segment;

    var reader = std.Io.Reader.fixed(&bytes);
    var decoder = try Decoder.init(&reader);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var stream = Stream.init(&decoder, std.testing.allocator);
    defer stream.deinit();

    const first = (try stream.next(arena_state.allocator())).?;

    try std.testing.expectEqualStrings("record", first.name);

    const second = (try stream.next(arena_state.allocator())).?;

    try std.testing.expectEqualStrings("record", second.name);
    try std.testing.expect((try stream.next(arena_state.allocator())) == null);
}

test "stream resolves developer fields via field_description" {
    const bytes = [_]u8{
        12,   0x20, 0x8F, 0x08,
        52,   0x00, 0x00, 0x00,
        '.',  'F',  'I',  'T',
        0x40, 0x00, 0x00, 0xCE,
        0x00, 0x05, 0x00, 0x01,
        0x02, 0x01, 0x01, 0x02,
        0x02, 0x01, 0x02, 0x03,
        0x06, 0x07, 0x08, 0x02,
        0x07, 0x00, 0x00, 0x00,
        0x02, 'p',  'o',  'w',
        'e',  'r',  0x00, 'W',
        0x00, 0x61, 0x00, 0x00,
        0x14, 0x00, 0x01, 0xFD,
        0x04, 0x86, 0x01, 0x00,
        0x01, 0x00, 0x01, 0x00,
        0xCA, 0x9A, 0x3B, 0xFA,
    };

    var reader = std.Io.Reader.fixed(&bytes);
    var decoder = try Decoder.init(&reader);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var stream = Stream.init(&decoder, std.testing.allocator);
    defer stream.deinit();

    const description = (try stream.next(arena_state.allocator())).?;

    try std.testing.expectEqualStrings("field_description", description.name);

    const record = (try stream.next(arena_state.allocator())).?;

    try std.testing.expectEqualStrings("record", record.name);

    var found = false;

    for (record.fields) |field| {
        if (std.mem.eql(u8, field.name, "power")) {
            try std.testing.expectEqual(@as(u64, 250), field.value.unsigned);
            found = true;
        }
    }

    try std.testing.expect(found);
    try std.testing.expect((try stream.next(arena_state.allocator())) == null);
}

test "accumulate reconstructs rolling totals across rollover" {
    var map: std.AutoHashMapUnmanaged(u32, u64) = .empty;
    defer map.deinit(std.testing.allocator);

    const gpa = std.testing.allocator;
    const bits: u7 = 8;

    try std.testing.expectEqual(@as(u64, 10), try accumulate_into(&map, gpa, 1, 10, bits));
    try std.testing.expectEqual(@as(u64, 250), try accumulate_into(&map, gpa, 1, 250, bits));
    try std.testing.expectEqual(@as(u64, 261), try accumulate_into(&map, gpa, 1, 5, bits));
}

test "accumulate keeps separate totals per key and handles a full-width field" {
    var map: std.AutoHashMapUnmanaged(u32, u64) = .empty;
    defer map.deinit(std.testing.allocator);

    const gpa = std.testing.allocator;

    try std.testing.expectEqual(@as(u64, 7), try accumulate_into(&map, gpa, 1, 7, 8));
    try std.testing.expectEqual(@as(u64, 9), try accumulate_into(&map, gpa, 2, 9, 8));
    try std.testing.expectEqual(@as(u64, 8), try accumulate_into(&map, gpa, 1, 8, 8));

    const wide = try accumulate_into(&map, gpa, 3, std.math.maxInt(u64), 64);

    try std.testing.expectEqual(std.math.maxInt(u64), wide);
}

test "stream rejects a definition whose base type is not a FIT base type" {
    const bytes = [_]u8{
        12,   0x20, 0x8F, 0x08,
        9,    0x00, 0x00, 0x00,
        '.',  'F',  'I',  'T',
        0x40, 0x00, 0x00, 0x14,
        0x00, 0x01, 0xFD, 0x04,
        0x99,
    };

    var reader = std.Io.Reader.fixed(&bytes);
    var decoder = try Decoder.init(&reader);

    try std.testing.expectError(error.UnknownBaseType, decoder.next());

    try std.testing.expect(decoder.definitions[0] == null);
}

test "decoder rejects a data record whose local type was never defined" {
    const bytes = [_]u8{
        12,   0x20, 0x8F, 0x08,
        1,    0x00, 0x00, 0x00,
        '.',  'F',  'I',  'T',
        0x03,
    };

    var reader = std.Io.Reader.fixed(&bytes);
    var decoder = try Decoder.init(&reader);

    try std.testing.expectError(error.UndefinedLocalType, decoder.next());
}

test "decoder rejects a header the reader cannot fully back" {
    const bytes = [_]u8{
        12,  0x20, 0x8F, 0x08,
        64,  0x00, 0x00, 0x00,
        '.', 'F',  'I',  'T',
    };

    var reader = std.Io.Reader.fixed(&bytes);

    try std.testing.expectError(error.Truncated, Decoder.init(&reader));
}
