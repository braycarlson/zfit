const std = @import("std");

const zfit = @import("root.zig");

const Decoder = zfit.Decoder;
const Encoder = zfit.Encoder;
const ValueTag = std.meta.Tag(Encoder.Value);

const Message = struct {
    global_number: u16,
    fields: []const Encoder.Field,
};

const round_count = 64;
const message_count_max = 16;
const field_count_max = 8;
const string_bytes_max = 12;
const file_bytes_max = 1 << 16;

fn check_round_trip(random: std.Random) !void {
    const gpa = std.testing.allocator;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const messages = try random_messages(arena, random);

    var encoder = Encoder.init(gpa);
    defer encoder.deinit();

    for (messages) |message| try encoder.message(message.global_number, message.fields);

    var storage: [file_bytes_max]u8 = undefined;
    var out = std.Io.Writer.fixed(&storage);

    try encoder.finish(&out);

    const bytes = out.buffered();

    try zfit.verify_checksum(bytes);

    var reader = std.Io.Reader.fixed(bytes);
    var decoder = try Decoder.init(&reader);

    for (messages) |message| {
        const decoded = (try decoder.next()).?;

        try std.testing.expectEqual(message.global_number, decoded.global_message_number);

        var fields = decoded.fields();

        for (message.fields) |expected| {
            const actual = fields.next().?;

            try std.testing.expectEqual(expected.number, actual.field_definition_number);
            try expect_field_bytes(expected.value, actual);
        }

        try std.testing.expect(fields.next() == null);
    }

    try std.testing.expect((try decoder.next()) == null);
}

fn random_messages(arena: std.mem.Allocator, random: std.Random) ![]const Message {
    const message_count = random.intRangeAtMost(u32, 1, message_count_max);
    const messages = try arena.alloc(Message, message_count);

    for (messages) |*message| {
        const field_count = random.intRangeAtMost(u32, 0, field_count_max);
        const fields = try arena.alloc(Encoder.Field, field_count);

        for (fields) |*field| {
            field.* = .{
                .number = random.int(u8),
                .value = try random_value(arena, random),
            };
        }

        message.* = .{
            .global_number = random.int(u16),
            .fields = fields,
        };
    }

    return messages;
}

fn random_value(arena: std.mem.Allocator, random: std.Random) !Encoder.Value {
    return switch (random.enumValue(ValueTag)) {
        .enum_value => .{ .enum_value = random.int(u8) },
        .uint8 => .{ .uint8 = random.int(u8) },
        .uint16 => .{ .uint16 = random.int(u16) },
        .uint32 => .{ .uint32 = random.int(u32) },
        .sint8 => .{ .sint8 = random.int(i8) },
        .sint16 => .{ .sint16 = random.int(i16) },
        .sint32 => .{ .sint32 = random.int(i32) },
        .float32 => .{ .float32 = @bitCast(random.int(u32)) },
        .float64 => .{ .float64 = @bitCast(random.int(u64)) },
        .string => blk: {
            const text = try arena.alloc(u8, random.intRangeAtMost(u32, 0, string_bytes_max));

            for (text) |*byte| byte.* = random.intRangeAtMost(u8, 1, 255);

            break :blk .{ .string = text };
        },
    };
}

fn expect_field_bytes(expected: Encoder.Value, actual: Decoder.Field) !void {
    switch (expected) {
        .enum_value, .uint8 => |value| {
            try std.testing.expectEqual(@as(usize, 1), actual.data.len);
            try std.testing.expectEqual(value, actual.data[0]);
        },
        .sint8 => |value| {
            try std.testing.expectEqual(@as(usize, 1), actual.data.len);
            try std.testing.expectEqual(value, @as(i8, @bitCast(actual.data[0])));
        },
        .uint16 => |value| {
            try std.testing.expectEqual(value, std.mem.readInt(u16, actual.data[0..2], .little));
        },
        .sint16 => |value| {
            try std.testing.expectEqual(value, std.mem.readInt(i16, actual.data[0..2], .little));
        },
        .uint32 => |value| {
            try std.testing.expectEqual(value, std.mem.readInt(u32, actual.data[0..4], .little));
        },
        .sint32 => |value| {
            try std.testing.expectEqual(value, std.mem.readInt(i32, actual.data[0..4], .little));
        },
        .float32 => |value| {
            const bits: u32 = @bitCast(value);

            try std.testing.expectEqual(bits, std.mem.readInt(u32, actual.data[0..4], .little));
        },
        .float64 => |value| {
            const bits: u64 = @bitCast(value);

            try std.testing.expectEqual(bits, std.mem.readInt(u64, actual.data[0..8], .little));
        },
        .string => |text| {
            try std.testing.expectEqual(text.len + 1, actual.data.len);
            try std.testing.expectEqualSlices(u8, text, actual.data[0..text.len]);
            try std.testing.expectEqual(@as(u8, 0), actual.data[text.len]);
        },
    }
}

test "random messages survive an encode/decode round trip" {
    var prng = std.Random.DefaultPrng.init(0x2f17_5eed);
    const random = prng.random();

    var round: u32 = 0;

    while (round < round_count) : (round += 1) {
        try check_round_trip(random);
    }
}

test "definitions beyond the local type budget evict and re-encode" {
    const gpa = std.testing.allocator;
    const definition_count = 2 * Encoder.local_type_count + 1;

    var encoder = Encoder.init(gpa);
    defer encoder.deinit();

    var number: u8 = 0;

    while (number < definition_count) : (number += 1) {
        const fields = [_]Encoder.Field{.{ .number = number, .value = .{ .uint8 = number } }};

        try encoder.message(number, &fields);
    }

    const revisit = [_]Encoder.Field{.{ .number = 0, .value = .{ .uint8 = 0xAB } }};

    try encoder.message(0, &revisit);

    var storage: [file_bytes_max]u8 = undefined;
    var out = std.Io.Writer.fixed(&storage);

    try encoder.finish(&out);

    const bytes = out.buffered();

    try zfit.verify_checksum(bytes);

    var reader = std.Io.Reader.fixed(bytes);
    var decoder = try Decoder.init(&reader);

    var decoded: u32 = 0;

    while (decoded < definition_count + 1) : (decoded += 1) {
        const message = (try decoder.next()).?;
        const expected: u16 = if (decoded < definition_count) @intCast(decoded) else 0;

        try std.testing.expectEqual(expected, message.global_message_number);
    }

    try std.testing.expect((try decoder.next()) == null);
}
