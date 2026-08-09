const std = @import("std");

const render = @import("render.zig");
const sheets = @import("sheets.zig");

const Allocator = std.mem.Allocator;
const EnumLiteral = render.EnumLiteral;
const FieldRow = sheets.FieldRow;
const MessageDefinition = sheets.MessageDefinition;
const NamedValue = sheets.NamedValue;
const Sheets = sheets.Sheets;
const assert = std.debug.assert;

pub const Model = struct {
    types: []const TypeTable,
    messages: []const Message,
};

pub const Error = Allocator.Error || sheets.Error || error{
    ComponentBitsOutOfRange,
    GlobalNumberOutOfRange,
    InvalidScale,
    InvalidOffset,
    ReferenceValueOutOfRange,
};

pub const Component = struct {
    field_number: u8,
    bits: u8,
    scale: f64,
    offset: f64,
    accumulate: bool,
};

pub const SubField = struct {
    name: []const u8,
    fit_type: []const u8,
    type_id: ?EnumLiteral,
    scale: f64,
    offset: f64,
    units: []const u8,
    reference_field_number: u8,
    reference_value: i64,
};

pub const FieldInfo = struct {
    number: u8,
    name: []const u8,
    fit_type: []const u8,
    type_id: ?EnumLiteral,
    base_type: ?EnumLiteral,
    scale: f64,
    offset: f64,
    units: []const u8,
    array: bool,
    accumulate: bool,
    components: []const Component,
    subfields: []const SubField,
};

pub const Message = struct {
    name: []const u8,
    global_number: u16,
    fields: []const FieldInfo,
};

pub const TypeTable = struct {
    name: []const u8,
    values: []const NamedValue,
};

const ScaleOffset = struct {
    scale: f64,
    offset: f64,
};

const component_bits_max = 64;

const boolean_true = "true";

const scale_identity = 1.0;
const offset_identity = 0.0;

comptime {
    assert(component_bits_max == 64);
    assert(component_bits_max <= std.math.maxInt(u8));
    assert(boolean_true.len == 4);
    assert(scale_identity != 0.0);
    assert(offset_identity == 0.0);
}

pub fn resolve(arena: Allocator, source: *const Sheets) Error!Model {
    assert(source.types.len > 0);
    assert(source.messages.len > 0);

    var types: std.ArrayList(TypeTable) = .empty;

    for (source.types) |definition| {
        if (definition.values.len == 0) continue;

        assert(definition.name.len > 0);

        try types.append(arena, .{ .name = definition.name, .values = definition.values });
    }

    var messages: std.ArrayList(Message) = .empty;

    for (source.messages) |*definition| {
        const number = source.global_number(definition.name) orelse continue;

        if (number < 0) return error.GlobalNumberOutOfRange;
        if (number > std.math.maxInt(u16)) return error.GlobalNumberOutOfRange;

        assert(number >= 0);
        assert(definition.name.len > 0);

        try messages.append(arena, .{
            .name = definition.name,
            .global_number = @intCast(number),
            .fields = try resolve_fields(arena, source, definition),
        });
    }

    assert(types.items.len > 0);
    assert(messages.items.len > 0);
    assert(types.items.len <= source.types.len);
    assert(messages.items.len <= source.messages.len);

    return .{ .types = types.items, .messages = messages.items };
}

fn resolve_fields(
    arena: Allocator,
    source: *const Sheets,
    message: *const MessageDefinition,
) Error![]const FieldInfo {
    var fields: std.ArrayList(FieldInfo) = .empty;

    assert(message.name.len > 0);

    for (message.fields) |*row| {
        const number = row.number orelse continue;
        const scaling = try scale_offset(row);

        assert(row.name.len > 0);
        assert(scaling.scale != 0.0);
        assert(std.math.isFinite(scaling.offset));

        try fields.append(arena, .{
            .number = number,
            .name = row.name,
            .fit_type = row.fit_type,
            .type_id = enum_literal(source.type_id_of(row.fit_type)),
            .base_type = enum_literal(source.base_type_of(row.fit_type)),
            .scale = scaling.scale,
            .offset = scaling.offset,
            .units = first(row.units),
            .array = row.array.len > 0,
            .accumulate = is_true(first(row.accumulate)),
            .components = try resolve_components(arena, message, row),
            .subfields = try resolve_subfields(arena, source, message, row),
        });
    }

    assert(fields.items.len <= message.fields.len);

    return fields.items;
}

fn resolve_components(
    arena: Allocator,
    message: *const MessageDefinition,
    row: *const FieldRow,
) Error![]const Component {
    var components: std.ArrayList(Component) = .empty;

    for (row.components, 0..) |name, index| {
        const target = message.field_named(name) orelse continue;
        const number = target.number orelse continue;

        const bits = sheets.parse_int(at(row.bits, index, "0")) orelse 0;

        if (bits < 0) return error.ComponentBitsOutOfRange;
        if (bits > component_bits_max) return error.ComponentBitsOutOfRange;

        assert(bits >= 0);
        assert(bits <= component_bits_max);
        assert(std.mem.eql(u8, target.name, name));

        try components.append(arena, .{
            .field_number = number,
            .bits = @intCast(bits),
            .scale = try parse_scale(at(row.scale, index, "")),
            .offset = try parse_offset(at(row.offset, index, "")),
            .accumulate = is_true(at(row.accumulate, index, "")),
        });
    }

    assert(components.items.len <= row.components.len);

    return components.items;
}

fn resolve_subfields(
    arena: Allocator,
    source: *const Sheets,
    message: *const MessageDefinition,
    row: *const FieldRow,
) Error![]const SubField {
    var subfields: std.ArrayList(SubField) = .empty;

    for (row.subfields) |*subfield| {
        const scaling = try scale_offset(subfield);
        const pairs = @min(subfield.reference_fields.len, subfield.reference_values.len);

        assert(subfield.name.len > 0);
        assert(pairs <= subfield.reference_fields.len);
        assert(pairs <= subfield.reference_values.len);

        var index: usize = 0;

        while (index < pairs) : (index += 1) {
            const name = subfield.reference_fields[index];
            const reference = message.field_named(name) orelse continue;
            const number = reference.number orelse continue;

            const value = source.value_of(
                reference.fit_type,
                subfield.reference_values[index],
            ) orelse continue;

            if (value < 0) return error.ReferenceValueOutOfRange;

            assert(value >= 0);
            assert(scaling.scale != 0.0);

            try subfields.append(arena, .{
                .name = subfield.name,
                .fit_type = subfield.fit_type,
                .type_id = enum_literal(source.type_id_of(subfield.fit_type)),
                .scale = scaling.scale,
                .offset = scaling.offset,
                .units = first(subfield.units),
                .reference_field_number = number,
                .reference_value = value,
            });
        }

        assert(index == pairs);
    }

    assert(row.name.len > 0);

    return subfields.items;
}

fn scale_offset(row: *const FieldRow) Error!ScaleOffset {
    const scale = try parse_scale(first(row.scale));
    const offset = try parse_offset(first(row.offset));

    assert(scale != 0.0);
    assert(std.math.isFinite(offset));

    return .{ .scale = scale, .offset = offset };
}

fn parse_scale(text: []const u8) Error!f64 {
    if (text.len == 0) return scale_identity;

    const scale = std.fmt.parseFloat(f64, text) catch return error.InvalidScale;

    if (!std.math.isFinite(scale)) return error.InvalidScale;
    if (scale == 0.0) return scale_identity;

    assert(scale != 0.0);
    assert(std.math.isFinite(scale));
    assert(!std.math.isNan(scale));

    return scale;
}

fn parse_offset(text: []const u8) Error!f64 {
    if (text.len == 0) return offset_identity;

    const offset = std.fmt.parseFloat(f64, text) catch return error.InvalidOffset;

    if (!std.math.isFinite(offset)) return error.InvalidOffset;

    assert(std.math.isFinite(offset));
    assert(!std.math.isNan(offset));

    return offset;
}

fn enum_literal(name: ?[]const u8) ?EnumLiteral {
    const present = name orelse return null;

    assert(present.len > 0);
    assert(std.mem.indexOfScalar(u8, present, ' ') == null);

    return .{ .name = present };
}

fn first(list: []const []const u8) []const u8 {
    if (list.len == 0) return "";

    assert(list.len >= 1);

    return list[0];
}

fn at(list: []const []const u8, index: usize, fallback: []const u8) []const u8 {
    if (index >= list.len) return fallback;

    assert(index < list.len);

    return list[index];
}

fn is_true(text: []const u8) bool {
    if (text.len != boolean_true.len) return false;

    assert(text.len == boolean_true.len);

    return std.ascii.eqlIgnoreCase(text, boolean_true);
}

fn resolve_fixture(arena: Allocator) !Model {
    const source = try sheets.parse_fixture(arena);

    return try resolve(arena, &source);
}

test "only types with named values and messages with a global number survive" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const profile = try resolve_fixture(arena_state.allocator());

    try std.testing.expectEqual(@as(usize, 3), profile.types.len);
    try std.testing.expectEqual(@as(usize, 1), profile.messages.len);
    try std.testing.expectEqualStrings("record", profile.messages[0].name);
    try std.testing.expectEqual(@as(u16, 20), profile.messages[0].global_number);
}

test "a field resolves its type id, base type, units, and scaling" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const profile = try resolve_fixture(arena_state.allocator());
    const fields = profile.messages[0].fields;

    const speed = fields[1];

    try std.testing.expectEqualStrings("speed", speed.name);
    try std.testing.expectEqual(@as(u8, 6), speed.number);
    try std.testing.expect(speed.type_id == null);
    try std.testing.expectEqualStrings("uint16", speed.base_type.?.name);
    try std.testing.expectEqualStrings("m/s", speed.units);
    try std.testing.expectApproxEqAbs(@as(f64, 1000.0), speed.scale, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), speed.offset, 1e-9);

    const manufacturer = fields[0];

    try std.testing.expectEqualStrings("manufacturer", manufacturer.type_id.?.name);
    try std.testing.expectEqualStrings("uint16", manufacturer.base_type.?.name);
}

test "the array and accumulate columns resolve to flags" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const profile = try resolve_fixture(arena_state.allocator());
    const fields = profile.messages[0].fields;

    const counter = fields[4];

    try std.testing.expectEqualStrings("counter", counter.name);
    try std.testing.expect(counter.array);
    try std.testing.expect(counter.accumulate);
    try std.testing.expect(!fields[1].array);
    try std.testing.expect(!fields[1].accumulate);
}

test "components resolve their target field, bits, and scaling" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const profile = try resolve_fixture(arena_state.allocator());
    const speed = profile.messages[0].fields[1];

    try std.testing.expectEqual(@as(usize, 1), speed.components.len);
    try std.testing.expectEqual(@as(u8, 73), speed.components[0].field_number);
    try std.testing.expectEqual(@as(u8, 16), speed.components[0].bits);
    try std.testing.expectApproxEqAbs(@as(f64, 1000.0), speed.components[0].scale, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), speed.components[0].offset, 1e-9);
    try std.testing.expect(!speed.components[0].accumulate);
}

test "subfields resolve their reference field number and enum value" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const profile = try resolve_fixture(arena_state.allocator());
    const product = profile.messages[0].fields[3];

    try std.testing.expectEqualStrings("product", product.name);
    try std.testing.expectEqual(@as(usize, 1), product.subfields.len);

    const subfield = product.subfields[0];

    try std.testing.expectEqualStrings("garmin_product", subfield.name);
    try std.testing.expectEqualStrings("manufacturer", subfield.type_id.?.name);
    try std.testing.expectEqual(@as(u8, 1), subfield.reference_field_number);
    try std.testing.expectEqual(@as(i64, 1), subfield.reference_value);
}

test "a blank or zero scale reads as unscaled" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const profile = try resolve_fixture(arena_state.allocator());
    const product = profile.messages[0].fields[3];

    try std.testing.expectApproxEqAbs(@as(f64, 1.0), product.scale, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), product.offset, 1e-9);
}
