const std = @import("std");

const xlsx = @import("xlsx.zig");

const Allocator = std.mem.Allocator;
const Row = xlsx.Row;
const assert = std.debug.assert;

pub const Sheets = struct {
    types: []const TypeDefinition,
    messages: []const MessageDefinition,

    pub fn type_named(sheets: *const Sheets, name: []const u8) ?*const TypeDefinition {
        if (name.len == 0) return null;

        for (sheets.types) |*definition| {
            assert(definition.name.len > 0);

            if (std.mem.eql(u8, definition.name, name)) return definition;
        }

        return null;
    }

    pub fn global_number(sheets: *const Sheets, name: []const u8) ?i64 {
        if (name.len == 0) return null;

        const numbers = sheets.type_named(message_number_type) orelse return null;

        var found: ?i64 = null;

        for (numbers.values) |value| {
            assert(value.number >= 0);

            if (std.mem.eql(u8, value.name, name)) found = value.number;
        }

        if (found) |number| assert(number >= 0);
        if (found) |number| assert(number <= std.math.maxInt(u16));

        return found;
    }

    pub fn type_id_of(sheets: *const Sheets, fit_type: []const u8) ?[]const u8 {
        const definition = sheets.type_named(fit_type) orelse return null;

        if (definition.values.len == 0) return null;

        assert(definition.name.len > 0);
        assert(definition.values.len > 0);

        return definition.name;
    }

    pub fn base_type_of(sheets: *const Sheets, fit_type: []const u8) ?[]const u8 {
        if (find_base_type(fit_type)) |base| return base;

        const definition = sheets.type_named(fit_type) orelse return null;
        const base = find_base_type(definition.base) orelse return null;

        assert(base.len > 0);

        return base;
    }

    pub fn value_of(sheets: *const Sheets, fit_type: []const u8, text: []const u8) ?i64 {
        if (text.len == 0) return null;
        if (parse_int(text)) |literal| return literal;

        assert(text.len > 0);
        assert(parse_int(text) == null);

        const definition = sheets.type_named(fit_type) orelse return null;

        return definition.value_of(text);
    }
};

pub const Error = Allocator.Error || error{
    DuplicateType,
    FieldNumberOutOfRange,
};

pub const TypeColumn = enum(u8) {
    type_name = 0,
    base_type = 1,
    value_name = 2,
    value = 3,
};

pub const MessageColumn = enum(u8) {
    message_name = 0,
    field_number = 1,
    field_name = 2,
    field_type = 3,
    array = 4,
    components = 5,
    scale = 6,
    offset = 7,
    units = 8,
    bits = 9,
    accumulate = 10,
    reference_field_name = 11,
    reference_field_value = 12,
};

pub const NamedValue = struct {
    name: []const u8,
    number: i64,
};

pub const TypeDefinition = struct {
    name: []const u8,
    base: []const u8,
    values: []const NamedValue,

    pub fn value_of(definition: *const TypeDefinition, name: []const u8) ?i64 {
        if (name.len == 0) return null;

        for (definition.values) |value| {
            assert(value.name.len > 0);

            if (std.mem.eql(u8, value.name, name)) return value.number;
        }

        return null;
    }
};

pub const FieldRow = struct {
    name: []const u8,
    fit_type: []const u8,
    array: []const u8,
    components: []const []const u8,
    scale: []const []const u8,
    offset: []const []const u8,
    units: []const []const u8,
    bits: []const []const u8,
    accumulate: []const []const u8,
    reference_fields: []const []const u8,
    reference_values: []const []const u8,
    number: ?u8 = null,
    subfields: []const FieldRow = &.{},
};

pub const MessageDefinition = struct {
    name: []const u8,
    fields: []const FieldRow,

    pub fn field_named(message: *const MessageDefinition, name: []const u8) ?*const FieldRow {
        if (name.len == 0) return null;

        var found: ?*const FieldRow = null;

        for (message.fields) |*field| {
            assert(field.name.len > 0);

            if (std.mem.eql(u8, field.name, name)) found = field;
        }

        return found;
    }
};

const TypeBuilder = struct {
    name: []const u8,
    base: []const u8,
    values: std.ArrayList(NamedValue) = .empty,
};

const ParsedRow = struct {
    field: FieldRow,
    numbered: bool,
};

pub const message_number_type = "mesg_num";

const list_separator = ',';
const list_whitespace_bytes = " \t\n\r";

const base_decimal = 10;
const base_hexadecimal = 16;
const hexadecimal_prefix = "0x";

const base_types = [_]struct { from: []const u8, to: []const u8 }{
    .{ .from = "enum", .to = "enum_value" },
    .{ .from = "sint8", .to = "sint8" },
    .{ .from = "uint8", .to = "uint8" },
    .{ .from = "sint16", .to = "sint16" },
    .{ .from = "uint16", .to = "uint16" },
    .{ .from = "sint32", .to = "sint32" },
    .{ .from = "uint32", .to = "uint32" },
    .{ .from = "string", .to = "string" },
    .{ .from = "float32", .to = "float32" },
    .{ .from = "float64", .to = "float64" },
    .{ .from = "uint8z", .to = "uint8z" },
    .{ .from = "uint16z", .to = "uint16z" },
    .{ .from = "uint32z", .to = "uint32z" },
    .{ .from = "byte", .to = "byte" },
    .{ .from = "sint64", .to = "sint64" },
    .{ .from = "uint64", .to = "uint64" },
    .{ .from = "uint64z", .to = "uint64z" },
    .{ .from = "bool", .to = "enum_value" },
};

comptime {
    assert(message_number_type.len > 0);
    assert(base_types.len == 18);
    assert(list_whitespace_bytes.len == 4);
    assert(base_decimal < base_hexadecimal);
    assert(hexadecimal_prefix.len == 2);

    for (base_types) |pair| {
        assert(pair.from.len > 0);
        assert(pair.to.len > 0);
    }
}

pub const type_rows_fixture = [_]Row{
    &.{ "Type Name", "Base Type", "Value Name", "Value", "Comment" },
    &.{ "file", "enum" },
    &.{ "", "", "device", "1" },
    &.{ "", "", "settings", "2" },
    &.{ "", "", "settings_again", "2" },
    &.{ "", "", "negative", "-1" },
    &.{ "manufacturer", "uint16" },
    &.{ "", "", "garmin", "1" },
    &.{ "mesg_num", "uint16" },
    &.{ "", "", "record", "20" },
    &.{ "", "", "file_id", "0x00" },
    &.{ "undocumented", "uint8" },
};

pub const message_rows_fixture = [_]Row{
    &.{ "Message Name", "Field Def #", "Field Name", "Field Type" },
    &.{ "orphaned", "", "stray", "uint8" },
    &.{"record"},
    &.{ "", "1", "manufacturer", "manufacturer" },
    &.{ "", "6", "speed", "uint16", "", "enhanced_speed", "1000", "", "m/s", "16" },
    &.{ "", "73", "enhanced_speed", "uint32", "", "", "1000", "", "m/s" },
    &.{ "", "2", "product", "uint16" },
    &.{
        "",       "", "garmin_product", "manufacturer",
        "",       "", "",               "",
        "",       "", "",               "manufacturer",
        "garmin",
    },
    &.{ "", "10", "counter", "uint8", "1", "", "", "", "", "", "true" },
    &.{"undocumented_message"},
    &.{ "", "0", "whatever", "uint8" },
};

pub fn parse(arena: Allocator, type_rows: []const Row, message_rows: []const Row) Error!Sheets {
    const types = try parse_types(arena, type_rows);
    const messages = try parse_messages(arena, message_rows);

    assert(types.len > 0);
    assert(messages.len > 0);

    return .{ .types = types, .messages = messages };
}

fn parse_types(arena: Allocator, rows: []const Row) Error![]const TypeDefinition {
    var builders: std.ArrayList(TypeBuilder) = .empty;

    for (body(rows)) |row| {
        const type_name = type_cell(row, .type_name);

        if (type_name.len > 0) {
            if (find_builder(builders.items, type_name) != null) return error.DuplicateType;

            try builders.append(arena, .{ .name = type_name, .base = type_cell(row, .base_type) });
            continue;
        }

        if (builders.items.len == 0) continue;

        const current = &builders.items[builders.items.len - 1];

        assert(current.name.len > 0);

        try append_value(arena, current, type_cell(row, .value_name), type_cell(row, .value));
    }

    assert(builders.items.len <= rows.len);

    const types = try arena.alloc(TypeDefinition, builders.items.len);

    for (types, builders.items) |*definition, builder| {
        assert(builder.name.len > 0);

        definition.* = .{
            .name = builder.name,
            .base = builder.base,
            .values = builder.values.items,
        };
    }

    assert(types.len == builders.items.len);

    return types;
}

fn append_value(
    arena: Allocator,
    builder: *TypeBuilder,
    value_name: []const u8,
    value_text: []const u8,
) Error!void {
    assert(builder.name.len > 0);

    if (value_name.len == 0) return;
    if (value_text.len == 0) return;

    const number = parse_int(value_text) orelse return;

    if (number < 0) return;

    for (builder.values.items) |existing| {
        if (existing.number == number) return;
    }

    const before = builder.values.items.len;

    assert(number >= 0);
    assert(value_name.len > 0);

    try builder.values.append(arena, .{ .name = value_name, .number = number });

    assert(builder.values.items.len == before + 1);
}

fn find_builder(builders: []const TypeBuilder, name: []const u8) ?*const TypeBuilder {
    if (name.len == 0) return null;

    for (builders) |*builder| {
        assert(builder.name.len > 0);

        if (std.mem.eql(u8, builder.name, name)) return builder;
    }

    return null;
}

fn parse_messages(arena: Allocator, rows: []const Row) Error![]const MessageDefinition {
    var messages: std.ArrayList(MessageDefinition) = .empty;
    var pending: std.ArrayList(ParsedRow) = .empty;
    var name: []const u8 = "";
    var open = false;

    for (body(rows)) |row| {
        const message_name = message_cell(row, .message_name);

        if (message_name.len > 0) {
            if (open) try messages.append(arena, .{
                .name = name,
                .fields = try group_fields(arena, pending.items),
            });

            pending.clearRetainingCapacity();
            name = message_name;
            open = true;
            continue;
        }

        if (!open) continue;
        if (message_cell(row, .field_name).len == 0) continue;

        try pending.append(arena, try parse_field_row(arena, row));
    }

    if (open) try messages.append(arena, .{
        .name = name,
        .fields = try group_fields(arena, pending.items),
    });

    assert(messages.items.len > 0);
    assert(messages.items.len <= rows.len);

    return messages.items;
}

fn parse_field_row(arena: Allocator, row: Row) Error!ParsedRow {
    assert(message_cell(row, .field_name).len > 0);

    const number_text = message_cell(row, .field_number);

    const field = FieldRow{
        .name = message_cell(row, .field_name),
        .fit_type = message_cell(row, .field_type),
        .array = message_cell(row, .array),
        .components = try split_list(arena, message_cell(row, .components)),
        .scale = try split_list(arena, message_cell(row, .scale)),
        .offset = try split_list(arena, message_cell(row, .offset)),
        .units = try split_list(arena, message_cell(row, .units)),
        .bits = try split_list(arena, message_cell(row, .bits)),
        .accumulate = try split_list(arena, message_cell(row, .accumulate)),
        .reference_fields = try split_list(arena, message_cell(row, .reference_field_name)),
        .reference_values = try split_list(arena, message_cell(row, .reference_field_value)),
        .number = if (number_text.len > 0) try field_number(number_text) else null,
    };

    assert(field.name.len > 0);

    return .{ .field = field, .numbered = number_text.len > 0 };
}

fn field_number(text: []const u8) Error!?u8 {
    assert(text.len > 0);

    const number = parse_int(text) orelse return null;

    if (number < 0) return error.FieldNumberOutOfRange;
    if (number > std.math.maxInt(u8)) return error.FieldNumberOutOfRange;

    assert(number >= 0);
    assert(number <= std.math.maxInt(u8));

    return @intCast(number);
}

fn group_fields(arena: Allocator, parsed: []const ParsedRow) Error![]const FieldRow {
    var fields: std.ArrayList(FieldRow) = .empty;

    var index: usize = 0;

    while (index < parsed.len) {
        const row = parsed[index];
        index += 1;
        if (!row.numbered) continue;

        const start = index;

        while (index < parsed.len and !parsed[index].numbered) index += 1;

        assert(index >= start);
        assert(index <= parsed.len);

        const subfields = try arena.alloc(FieldRow, index - start);

        for (subfields, parsed[start..index]) |*subfield, source| subfield.* = source.field;

        var field = row.field;
        field.subfields = subfields;

        assert(field.name.len > 0);
        assert(field.number != null);

        try fields.append(arena, field);
    }

    assert(index == parsed.len);
    assert(fields.items.len <= parsed.len);

    return fields.items;
}

fn body(rows: []const Row) []const Row {
    if (rows.len == 0) return &.{};

    assert(rows.len >= 1);

    return rows[1..];
}

fn type_cell(row: Row, column: TypeColumn) []const u8 {
    comptime assert(@intFromEnum(TypeColumn.type_name) == 0);
    assert(@intFromEnum(column) <= @intFromEnum(TypeColumn.value));

    return cell(row, @intFromEnum(column));
}

fn message_cell(row: Row, column: MessageColumn) []const u8 {
    comptime assert(@intFromEnum(MessageColumn.message_name) == 0);
    assert(@intFromEnum(column) <= @intFromEnum(MessageColumn.reference_field_value));

    return cell(row, @intFromEnum(column));
}

fn cell(row: Row, index: usize) []const u8 {
    if (index >= row.len) return "";

    assert(index < row.len);

    return row[index];
}

fn find_base_type(fit_type: []const u8) ?[]const u8 {
    if (fit_type.len == 0) return null;

    for (base_types) |pair| {
        assert(pair.from.len > 0);
        assert(pair.to.len > 0);

        if (std.mem.eql(u8, pair.from, fit_type)) return pair.to;
    }

    return null;
}

fn split_list(arena: Allocator, text: []const u8) Error![]const []const u8 {
    if (text.len == 0) return &.{};

    var parts: std.ArrayList([]const u8) = .empty;
    var fields = std.mem.splitScalar(u8, text, list_separator);

    while (fields.next()) |part| {
        assert(part.len <= text.len);

        try parts.append(arena, std.mem.trim(u8, part, list_whitespace_bytes));
    }

    assert(parts.items.len >= 1);
    assert(parts.items.len <= text.len + 1);

    return parts.items;
}

pub fn parse_int(text: []const u8) ?i64 {
    if (text.len == 0) return null;

    const hex = std.ascii.startsWithIgnoreCase(text, hexadecimal_prefix);
    const digits = if (hex) text[hexadecimal_prefix.len..] else text;
    const base: u8 = if (hex) base_hexadecimal else base_decimal;

    if (digits.len == 0) return null;

    if (hex) assert(digits.len == text.len - hexadecimal_prefix.len);

    assert(base == base_decimal or base == base_hexadecimal);
    assert(digits.len <= text.len);

    return std.fmt.parseInt(i64, digits, base) catch null;
}

pub fn parse_fixture(arena: Allocator) !Sheets {
    return try parse(arena, &type_rows_fixture, &message_rows_fixture);
}

test "types keep sheet order, drop repeats, and drop negative values" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const source = try parse_fixture(arena_state.allocator());

    try std.testing.expectEqual(@as(usize, 4), source.types.len);
    try std.testing.expectEqualStrings("file", source.types[0].name);

    const file = source.type_named("file").?;

    try std.testing.expectEqualStrings("enum", file.base);
    try std.testing.expectEqual(@as(usize, 2), file.values.len);
    try std.testing.expectEqualStrings("device", file.values[0].name);
    try std.testing.expectEqualStrings("settings", file.values[1].name);
    try std.testing.expectEqual(@as(?i64, 2), file.value_of("settings"));
    try std.testing.expect(file.value_of("settings_again") == null);
    try std.testing.expect(file.value_of("negative") == null);
}

test "a repeated type name is rejected rather than emitted twice" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const duplicated = [_]Row{
        &.{ "Type Name", "Base Type" },
        &.{ "file", "enum" },
        &.{ "file", "enum" },
    };

    const arena = arena_state.allocator();

    try std.testing.expectError(
        error.DuplicateType,
        parse(arena, &duplicated, &message_rows_fixture),
    );
}

test "a type with no named values carries no type id but still resolves a base" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const source = try parse_fixture(arena_state.allocator());

    try std.testing.expectEqualStrings("file", source.type_id_of("file").?);
    try std.testing.expect(source.type_id_of("undocumented") == null);
    try std.testing.expectEqualStrings("uint8", source.base_type_of("undocumented").?);

    try std.testing.expectEqualStrings("uint16", source.base_type_of("uint16").?);
    try std.testing.expectEqualStrings("enum_value", source.base_type_of("bool").?);
    try std.testing.expectEqualStrings("uint16", source.base_type_of("manufacturer").?);
    try std.testing.expect(source.base_type_of("not_a_type") == null);
}

test "global numbers come from mesg_num and accept a hexadecimal value" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const source = try parse_fixture(arena_state.allocator());

    try std.testing.expectEqual(@as(?i64, 20), source.global_number("record"));
    try std.testing.expectEqual(@as(?i64, 0), source.global_number("file_id"));
    try std.testing.expect(source.global_number("undocumented_message") == null);
}

test "messages keep their fields and drop a subfield row that has no field" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const source = try parse_fixture(arena_state.allocator());

    try std.testing.expectEqual(@as(usize, 3), source.messages.len);
    try std.testing.expectEqualStrings("orphaned", source.messages[0].name);
    try std.testing.expectEqual(@as(usize, 0), source.messages[0].fields.len);

    const record = &source.messages[1];

    try std.testing.expectEqualStrings("record", record.name);
    try std.testing.expectEqual(@as(usize, 5), record.fields.len);
    try std.testing.expectEqual(@as(?u8, 6), record.field_named("speed").?.number);
    try std.testing.expect(record.field_named("missing") == null);
}

test "a field's subfield rows attach to the field above them" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const source = try parse_fixture(arena_state.allocator());
    const record = &source.messages[1];

    const product = record.field_named("product").?;

    try std.testing.expectEqual(@as(usize, 1), product.subfields.len);
    try std.testing.expectEqualStrings("garmin_product", product.subfields[0].name);
    try std.testing.expectEqual(@as(usize, 0), record.field_named("speed").?.subfields.len);
}

test "a list column splits on commas and trims each entry" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const listed = [_]Row{
        &.{ "Message Name", "Field Def #", "Field Name", "Field Type" },
        &.{"record"},
        &.{ "", "0", "packed", "uint32", "", " a , b ,c", "1, 2", "", "m,s", "8,16" },
    };

    const arena = arena_state.allocator();
    const source = try parse(arena, &type_rows_fixture, &listed);
    const field = source.messages[0].field_named("packed").?;

    try std.testing.expectEqual(@as(usize, 3), field.components.len);
    try std.testing.expectEqualStrings("a", field.components[0]);
    try std.testing.expectEqualStrings("b", field.components[1]);
    try std.testing.expectEqualStrings("c", field.components[2]);
    try std.testing.expectEqual(@as(usize, 2), field.bits.len);
    try std.testing.expectEqualStrings("16", field.bits[1]);
}

test "parse_int reads decimal and hexadecimal, and rejects prose" {
    try std.testing.expectEqual(@as(?i64, 20), parse_int("20"));
    try std.testing.expectEqual(@as(?i64, -3), parse_int("-3"));
    try std.testing.expectEqual(@as(?i64, 255), parse_int("0xFF"));
    try std.testing.expectEqual(@as(?i64, 255), parse_int("0Xff"));
    try std.testing.expect(parse_int("") == null);
    try std.testing.expect(parse_int("0x") == null);
    try std.testing.expect(parse_int("1.5") == null);
    try std.testing.expect(parse_int("garmin") == null);
}
