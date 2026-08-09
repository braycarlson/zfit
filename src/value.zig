const std = @import("std");

const Decoder = @import("decoder.zig");
const profile = @import("profile.zig");

const BaseType = Decoder.BaseType;
const DataMessage = Decoder.DataMessage;
const Endian = std.builtin.Endian;
const Field = Decoder.Field;
const FieldInfo = profile.FieldInfo;
const TypeId = profile.TypeId;
const assert = std.debug.assert;

pub const Value = union(enum) {
    none,
    integer: i64,
    unsigned: u64,
    real: f64,
    string: []const u8,
    enumeration: []const u8,
    bytes: []const u8,
    integer_array: []const i64,
    real_array: []const f64,
};

pub const Meta = struct {
    name: []const u8,
    fit_type: []const u8,
    type_id: ?TypeId,
    scale: f64,
    offset: f64,
    units: []const u8,
};

pub const bits_max = @bitSizeOf(u64);
pub const bytes_max = @divExact(bits_max, 8);

comptime {
    assert(bytes_max == 8);
    assert(bytes_max == BaseType.uint64.size_bytes());
}

pub const plain = Meta{
    .name = "",
    .fit_type = "",
    .type_id = null,
    .scale = 1.0,
    .offset = 0.0,
    .units = "",
};

pub fn meta_for(message: *const DataMessage, info: *const FieldInfo) Meta {
    for (info.subfields) |sub| {
        if (reference_matches(message, sub.reference_field_number, sub.reference_value)) {
            return .{
                .name = sub.name,
                .fit_type = sub.fit_type,
                .type_id = sub.type_id,
                .scale = sub.scale,
                .offset = sub.offset,
                .units = sub.units,
            };
        }
    }

    return .{
        .name = info.name,
        .fit_type = info.fit_type,
        .type_id = info.type_id,
        .scale = info.scale,
        .offset = info.offset,
        .units = info.units,
    };
}

pub fn decode(field: Field, meta: Meta, architecture: Endian) Value {
    const base = field.base_type;
    const element = base.size_bytes();

    assert(element >= 1);
    assert(element <= bytes_max);

    if (field.data.len == 0) return .none;
    if (base == .string) return decode_string(field.data);
    if (field.data.len != element) return .{ .bytes = field.data };

    const raw = read_unsigned(field.data, architecture);

    if (is_invalid(base, raw)) return .none;

    if (base.is_float()) return scale_real(read_float(base, raw), meta);

    if (meta.type_id) |type_id| {
        if (profile.type_value_name(type_id, raw)) |name| return .{ .enumeration = name };
    }

    if (base.is_signed()) {
        const signed = sign_extend(raw, element);

        if (is_scaled(meta)) return .{ .real = apply_scale(@floatFromInt(signed), meta) };

        return .{ .integer = signed };
    }

    if (is_scaled(meta)) return .{ .real = apply_scale(@floatFromInt(raw), meta) };

    return .{ .unsigned = raw };
}

pub fn apply_scale(number: f64, meta: Meta) f64 {
    assert(meta.scale != 0.0);
    assert(std.math.isFinite(meta.scale));
    assert(std.math.isFinite(meta.offset));

    return number / meta.scale - meta.offset;
}

pub fn low_bits_mask(bits: u7) u64 {
    assert(bits >= 1);
    assert(bits <= bits_max);

    const mask = ~@as(u64, 0) >> @intCast(bits_max - @as(u32, bits));

    assert(mask >= 1);
    assert(@popCount(mask) == bits);

    return mask;
}

pub fn c_string(data: []const u8) []const u8 {
    var end: usize = 0;

    while (end < data.len and data[end] != 0) end += 1;

    return data[0..end];
}

fn is_scaled(meta: Meta) bool {
    assert(meta.scale != 0.0);
    assert(std.math.isFinite(meta.scale));

    return meta.scale != 1.0 or meta.offset != 0.0;
}

fn scale_real(number: f64, meta: Meta) Value {
    assert(meta.scale != 0.0);
    assert(std.math.isFinite(meta.offset));

    if (is_scaled(meta)) return .{ .real = apply_scale(number, meta) };

    assert(meta.scale == 1.0);
    assert(meta.offset == 0.0);

    return .{ .real = number };
}

fn reference_matches(message: *const DataMessage, number: u8, value: i64) bool {
    var fields = message.fields();

    while (fields.next()) |field| {
        if (field.field_definition_number != number) continue;

        const raw = field_unsigned(field, message.architecture) orelse return false;

        return raw == @as(u64, @intCast(value));
    }

    return false;
}

pub fn field_unsigned(field: Field, architecture: Endian) ?u64 {
    const element = field.base_type.size_bytes();

    assert(element >= 1);
    assert(element <= bytes_max);

    if (field.data.len != element) return null;

    return read_unsigned(field.data, architecture);
}

pub fn raw_bits(data: []const u8, architecture: Endian) ?u64 {
    if (data.len == 0) return null;
    if (data.len > bytes_max) return null;

    const bits = read_unsigned(data, architecture);

    if (data.len < bytes_max) assert(bits >> @intCast(data.len * 8) == 0);

    return bits;
}

fn read_unsigned(data: []const u8, architecture: Endian) u64 {
    assert(data.len >= 1);
    assert(data.len <= bytes_max);

    const raw = std.mem.readVarInt(u64, data, architecture);

    if (data.len < bytes_max) assert(raw >> @intCast(data.len * 8) == 0);

    return raw;
}

fn read_float(base: BaseType, raw: u64) f64 {
    assert(base.is_float());
    assert(!base.is_signed());

    return switch (base) {
        .float32 => @as(f32, @bitCast(@as(u32, @intCast(raw)))),
        .float64 => @bitCast(raw),
        .enum_value, .sint8, .uint8, .string, .uint8z, .byte => unreachable,
        .sint16, .uint16, .uint16z => unreachable,
        .sint32, .uint32, .uint32z => unreachable,
        .sint64, .uint64, .uint64z => unreachable,
    };
}

fn sign_extend(raw: u64, element: u8) i64 {
    assert(element >= 1);
    assert(element <= bytes_max);
    assert(std.math.isPowerOfTwo(element));

    const widened: i64 = switch (element) {
        1 => @as(i8, @bitCast(@as(u8, @intCast(raw)))),
        2 => @as(i16, @bitCast(@as(u16, @intCast(raw)))),
        4 => @as(i32, @bitCast(@as(u32, @intCast(raw)))),
        8 => @bitCast(raw),
        else => unreachable,
    };

    if (element < bytes_max) {
        const mask = low_bits_mask(@intCast(element * 8));

        assert(@as(u64, @bitCast(widened)) & mask == raw);
    }

    return widened;
}

fn is_invalid(base: BaseType, raw: u64) bool {
    const sentinel = base.invalid_value() orelse {
        assert(base == .string);

        return false;
    };

    const element = base.size_bytes();

    assert(element >= 1);
    assert(element <= bytes_max);

    if (element < bytes_max) assert(sentinel >> @intCast(element * 8) == 0);

    return raw == sentinel;
}

fn decode_string(data: []const u8) Value {
    assert(data.len >= 1);

    const text = c_string(data);

    if (text.len == 0) return .none;

    assert(text.len <= data.len);

    return .{ .string = text };
}

fn make(comptime number: u8, base: BaseType, data: []const u8) Field {
    return .{ .field_definition_number = number, .base_type = base, .data = data };
}

test "decode returns unsigned for a plain integer field" {
    const value = decode(make(3, .uint8, &[_]u8{150}), plain, .little);

    try std.testing.expectEqual(@as(u64, 150), value.unsigned);
}

test "decode reports invalid sentinels as none" {
    try std.testing.expect(decode(make(3, .uint8, &[_]u8{0xFF}), plain, .little) == .none);
    try std.testing.expect(decode(make(0, .uint16z, &[_]u8{ 0, 0 }), plain, .little) == .none);
}

test "decode applies scale and offset" {
    const meta = Meta{
        .name = "speed",
        .fit_type = "uint16",
        .type_id = null,
        .scale = 1000.0,
        .offset = 0.0,
        .units = "m/s",
    };

    const value = decode(make(6, .uint16, &[_]u8{ 0xE8, 0x03 }), meta, .little);

    try std.testing.expectApproxEqAbs(@as(f64, 1.0), value.real, 1e-9);
}

test "decode resolves enum names" {
    const meta = Meta{
        .name = "type",
        .fit_type = "file",
        .type_id = .file,
        .scale = 1.0,
        .offset = 0.0,
        .units = "",
    };

    const value = decode(make(0, .enum_value, &[_]u8{4}), meta, .little);

    try std.testing.expectEqualStrings("activity", value.enumeration);
}

test "decode sign-extends signed fields" {
    const value = decode(make(0, .sint8, &[_]u8{0xFF}), plain, .little);

    try std.testing.expectEqual(@as(i64, -1), value.integer);

    const negative = decode(make(0, .sint16, &[_]u8{ 0xFE, 0xFF }), plain, .little);

    try std.testing.expectEqual(@as(i64, -2), negative.integer);

    try std.testing.expect(decode(make(0, .sint8, &[_]u8{0x7F}), plain, .little) == .none);
}

test "low_bits_mask covers one bit up to the full word" {
    try std.testing.expectEqual(@as(u64, 0x1), low_bits_mask(1));
    try std.testing.expectEqual(@as(u64, 0xFF), low_bits_mask(8));
    try std.testing.expectEqual(@as(u64, 0xFFFFFFFF), low_bits_mask(32));
    try std.testing.expectEqual(~@as(u64, 0), low_bits_mask(64));
}

test "c_string stops at the first null and tolerates an unterminated field" {
    try std.testing.expectEqualStrings("ab", c_string(&[_]u8{ 'a', 'b', 0, 'c' }));
    try std.testing.expectEqualStrings("abc", c_string(&[_]u8{ 'a', 'b', 'c' }));
    try std.testing.expectEqualStrings("", c_string(&[_]u8{0}));
    try std.testing.expectEqualStrings("", c_string(&[_]u8{}));
}
