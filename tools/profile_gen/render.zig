const std = @import("std");

const Writer = std.Io.Writer;
const assert = std.debug.assert;

pub const Error = Writer.Error;

pub const EnumLiteral = struct {
    name: []const u8,
};

pub const Verbatim = struct {
    text: []const u8,
};

const Inner = struct {
    number: u8,
    flag: bool,
};

const Outer = struct {
    name: []const u8,
    type_id: ?EnumLiteral,
    scale: f64,
    signed: i64,
    items: []const Inner,
    reference: Verbatim,
};

const real_bytes_max = 32;

const float_marker_bytes = ".eE";

comptime {
    assert(real_bytes_max >= 24);
}

const workbook_reals = [_]struct { value: f64, text: []const u8 }{
    .{ .value = -110.0, .text = "-110.0" },
    .{ .value = 0.0, .text = "0.0" },
    .{ .value = 0.7111111, .text = "0.7111111" },
    .{ .value = 1.0, .text = "1.0" },
    .{ .value = 1.024, .text = "1.024" },
    .{ .value = 10.0, .text = "10.0" },
    .{ .value = 100.0, .text = "100.0" },
    .{ .value = 1000.0, .text = "1000.0" },
    .{ .value = 1000000.0, .text = "1000000.0" },
    .{ .value = 1024.0, .text = "1024.0" },
    .{ .value = 10430.38, .text = "10430.38" },
    .{ .value = 128.0, .text = "128.0" },
    .{ .value = 16.0, .text = "16.0" },
    .{ .value = 2.0, .text = "2.0" },
    .{ .value = 25.0, .text = "25.0" },
    .{ .value = 256.0, .text = "256.0" },
    .{ .value = 28.57143, .text = "28.57143" },
    .{ .value = 32768.0, .text = "32768.0" },
    .{ .value = 4.0, .text = "4.0" },
    .{ .value = 5.0, .text = "5.0" },
    .{ .value = 500.0, .text = "500.0" },
    .{ .value = 5000.0, .text = "5000.0" },
    .{ .value = 65535.0, .text = "65535.0" },
    .{ .value = 65536.0, .text = "65536.0" },
};

pub fn value(writer: *Writer, data: anytype) Error!void {
    const Data = @TypeOf(data);
    comptime assert(@typeInfo(Data) != .@"fn");
    comptime assert(@typeInfo(Data) != .void);

    if (Data == EnumLiteral) return writer.print(".{f}", .{std.zig.fmtId(data.name)});
    if (Data == Verbatim) return writer.writeAll(data.text);
    if (Data == []const u8) return writer.print("\"{f}\"", .{std.zig.fmtString(data)});

    return switch (@typeInfo(Data)) {
        .bool => writer.writeAll(if (data) "true" else "false"),
        .int => writer.print("{d}", .{data}),
        .float => real(writer, data),
        .optional => optional(writer, data),
        .pointer => slice(writer, data),
        .@"struct" => structure(writer, data),
        else => @compileError("no Zig literal for " ++ @typeName(Data)),
    };
}

pub fn real(writer: *Writer, number: f64) Error!void {
    assert(std.math.isFinite(number));

    var buffer: [real_bytes_max]u8 = undefined;

    const text = std.fmt.bufPrint(&buffer, "{d}", .{number}) catch |err| switch (err) {
        error.NoSpaceLeft => @panic("real_bytes_max too small for an f64 literal"),
    };

    assert(text.len > 0);
    assert(text.len <= real_bytes_max);

    try writer.writeAll(text);

    if (std.mem.indexOfAny(u8, text, float_marker_bytes) == null) {
        try writer.writeAll(".0");
    }
}

fn optional(writer: *Writer, data: anytype) Error!void {
    comptime assert(@typeInfo(@TypeOf(data)) == .optional);
    comptime assert(@typeInfo(@TypeOf(data)).optional.child != void);

    const present = data orelse return writer.writeAll("null");

    return value(writer, present);
}

fn slice(writer: *Writer, data: anytype) Error!void {
    comptime assert(@typeInfo(@TypeOf(data)).pointer.size == .slice);
    comptime assert(@TypeOf(data) != []const u8);

    if (data.len == 0) return writer.writeAll("&.{}");

    const tight = data.len == 1;

    try writer.writeAll(if (tight) "&.{" else "&.{ ");

    for (data, 0..) |item, index| {
        if (index > 0) try writer.writeAll(", ");

        try value(writer, item);
    }

    try writer.writeAll(if (tight) "}" else " }");
}

fn structure(writer: *Writer, data: anytype) Error!void {
    comptime assert(@typeInfo(@TypeOf(data)) == .@"struct");
    comptime assert(@typeInfo(@TypeOf(data)).@"struct".fields.len > 0);

    try writer.writeByte('.');

    return structure_body(writer, data);
}

pub fn structure_body(writer: *Writer, data: anytype) Error!void {
    const fields = @typeInfo(@TypeOf(data)).@"struct".fields;
    comptime assert(fields.len > 0);
    comptime assert(@typeInfo(@TypeOf(data)).@"struct".layout == .auto);

    try writer.writeAll("{ ");

    inline for (fields, 0..) |field, index| {
        if (index > 0) try writer.writeAll(", ");

        comptime assert(field.name.len > 0);

        try writer.print(".{s} = ", .{field.name});
        try value(writer, @field(data, field.name));
    }

    try writer.writeAll(" }");
}

fn rendered(arena: std.mem.Allocator, data: anytype) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);

    try value(&out.writer, data);

    return out.writer.buffered();
}

test "a struct renders as a literal with its fields in declaration order" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const data = Outer{
        .name = "speed",
        .type_id = .{ .name = "file" },
        .scale = 1000.0,
        .signed = -2,
        .items = &.{ .{ .number = 1, .flag = true }, .{ .number = 2, .flag = false } },
        .reference = .{ .text = "&record_fields" },
    };

    try std.testing.expectEqualStrings(
        ".{ .name = \"speed\", .type_id = .file, .scale = 1000.0, .signed = -2, " ++
            ".items = &.{ .{ .number = 1, .flag = true }, .{ .number = 2, .flag = false } }, " ++
            ".reference = &record_fields }",
        try rendered(arena_state.allocator(), data),
    );
}

test "an absent optional renders as null" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("null", try rendered(arena, @as(?EnumLiteral, null)));
    try std.testing.expectEqualStrings("null", try rendered(arena, @as(?u8, null)));
    try std.testing.expectEqualStrings("7", try rendered(arena, @as(?u8, 7)));
}

test "a slice renders tight when it holds one element" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const empty: []const Inner = &.{};
    const one: []const Inner = &.{.{ .number = 3, .flag = false }};

    const two: []const Inner = &.{
        .{ .number = 3, .flag = false },
        .{ .number = 4, .flag = true },
    };

    try std.testing.expectEqualStrings("&.{}", try rendered(arena, empty));

    try std.testing.expectEqualStrings(
        "&.{.{ .number = 3, .flag = false }}",
        try rendered(arena, one),
    );

    try std.testing.expectEqualStrings(
        "&.{ .{ .number = 3, .flag = false }, .{ .number = 4, .flag = true } }",
        try rendered(arena, two),
    );
}

test "an enum literal is quoted only when it has to be" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();

    const Case = struct { name: []const u8, literal: []const u8 };

    const cases = [_]Case{
        .{ .name = "record", .literal = ".record" },
        .{ .name = "mesg_num", .literal = ".mesg_num" },
        .{ .name = "switch", .literal = ".@\"switch\"" },
        .{ .name = "u8", .literal = ".@\"u8\"" },
        .{ .name = "4iiii", .literal = ".@\"4iiii\"" },
    };

    for (cases) |case| {
        const literal = try rendered(arena, EnumLiteral{ .name = case.name });

        try std.testing.expectEqualStrings(case.literal, literal);
    }
}

test "strings are quoted and escaped" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("\"\"", try rendered(arena, @as([]const u8, "")));
    try std.testing.expectEqualStrings("\"m/s\"", try rendered(arena, @as([]const u8, "m/s")));
    try std.testing.expectEqualStrings("\"a\\\"b\"", try rendered(arena, @as([]const u8, "a\"b")));
    try std.testing.expectEqualStrings("\"a\\\\b\"", try rendered(arena, @as([]const u8, "a\\b")));
    try std.testing.expectEqualStrings("\"a\\nb\"", try rendered(arena, @as([]const u8, "a\nb")));
}

test "reals render as float literals that round trip" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();

    for (workbook_reals) |expected| {
        const text = try rendered(arena, expected.value);

        try std.testing.expectEqualStrings(expected.text, text);
        try std.testing.expectEqual(expected.value, try std.fmt.parseFloat(f64, text));
    }
}

test "an integral real still renders with a fractional part" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("7.0", try rendered(arena, @as(f64, 7.0)));
    try std.testing.expectEqualStrings("-7.0", try rendered(arena, @as(f64, -7.0)));
    try std.testing.expectEqualStrings("0.5", try rendered(arena, @as(f64, 0.5)));
}
