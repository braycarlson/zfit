const std = @import("std");

const Decoder = @import("decoder.zig");
const Encoder = @import("encoder.zig");
const decode = @import("decode.zig");
const fuzz = @import("testing/fuzz.zig");
const zfit = @import("root.zig");

const Allocator = std.mem.Allocator;
const ValueTag = std.meta.Tag(Encoder.Value);
const assert = std.debug.assert;

const Message = struct {
    global_number: u16,
    fields: []const Encoder.Field,
};

const message_count_gen_max = 64;
const field_count_gen_max = 32;
const string_bytes_gen_max = 32;

const globals_pool = [_]u16{ 0, 18, 19, 20, 21, 34, 78, 104, 206, 233 };

comptime {
    assert(field_count_gen_max <= Encoder.field_count_max);
    assert(string_bytes_gen_max < Encoder.string_bytes_max);
}

pub fn main(gpa: Allocator, args: fuzz.FuzzArgs) !void {
    assert(args.events_max >= 1);

    var prng = std.Random.DefaultPrng.init(args.seed);
    const random = prng.random();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    var event: u32 = 0;

    while (event < args.events_max) : (event += 1) {
        _ = arena_state.reset(.retain_capacity);

        try fuzz_one(gpa, arena_state.allocator(), random);
    }
}

fn fuzz_one(gpa: Allocator, arena: Allocator, random: std.Random) !void {
    const messages = try generate_messages(arena, random);

    var encoder = Encoder.init(gpa);
    defer encoder.deinit();

    for (messages) |message| try encoder.message(message.global_number, message.fields);

    var out: std.Io.Writer.Allocating = .init(arena);

    try encoder.finish(&out.writer);

    const bytes = out.writer.buffered();

    assert(bytes.len >= Decoder.header_bytes + 2);

    try zfit.verify_checksum(bytes);
    try check_decoder(messages, bytes);
    try check_stream(gpa, messages.len, bytes);
}

fn generate_messages(arena: Allocator, random: std.Random) ![]const Message {
    const message_count = 1 + random.uintLessThan(u32, message_count_gen_max);
    const messages = try arena.alloc(Message, message_count);

    for (messages) |*message| {
        const field_count = random.uintAtMost(u32, field_count_gen_max);
        const fields = try arena.alloc(Encoder.Field, field_count);

        for (fields) |*field| {
            field.* = .{
                .number = random.int(u8),
                .value = try generate_value(arena, random),
            };
        }

        message.* = .{
            .global_number = pick_global(random),
            .fields = fields,
        };
    }

    return messages;
}

fn pick_global(random: std.Random) u16 {
    if (random.boolean()) return globals_pool[random.uintLessThan(u8, globals_pool.len)];

    return random.int(u16);
}

fn generate_value(arena: Allocator, random: std.Random) !Encoder.Value {
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
        .string => .{ .string = try generate_string(arena, random) },
    };
}

fn generate_string(arena: Allocator, random: std.Random) ![]const u8 {
    const length: u32 = switch (random.int(u2)) {
        0 => 0,
        1 => Encoder.string_bytes_max,
        else => random.uintAtMost(u32, string_bytes_gen_max),
    };

    const text = try arena.alloc(u8, length);

    for (text) |*byte| byte.* = random.intRangeAtMost(u8, 1, 255);

    return text;
}

fn check_decoder(messages: []const Message, bytes: []const u8) !void {
    var reader = std.Io.Reader.fixed(bytes);
    var decoder = try Decoder.init(&reader);

    for (messages) |message| {
        const decoded = (try decoder.next()).?;

        assert(decoded.global_message_number == message.global_number);
        assert(decoded.architecture == .little);

        var fields = decoded.fields();

        for (message.fields) |expected| {
            const actual = fields.next().?;

            assert(actual.field_definition_number == expected.number);

            check_field(expected.value, actual);
        }

        assert(fields.next() == null);
    }

    assert((try decoder.next()) == null);
}

fn check_field(expected: Encoder.Value, actual: Decoder.Field) void {
    const base = base_type_of(expected);

    assert(actual.base_type == base);

    if (expected != .string) assert(actual.data.len == base.size_bytes());

    switch (expected) {
        .enum_value, .uint8 => |value| assert(actual.data[0] == value),
        .sint8 => |value| assert(@as(i8, @bitCast(actual.data[0])) == value),
        .uint16 => |value| assert(std.mem.readInt(u16, actual.data[0..2], .little) == value),
        .sint16 => |value| assert(std.mem.readInt(i16, actual.data[0..2], .little) == value),
        .uint32 => |value| assert(std.mem.readInt(u32, actual.data[0..4], .little) == value),
        .sint32 => |value| assert(std.mem.readInt(i32, actual.data[0..4], .little) == value),
        .float32 => |value| {
            const bits: u32 = @bitCast(value);

            assert(std.mem.readInt(u32, actual.data[0..4], .little) == bits);
        },
        .float64 => |value| {
            const bits: u64 = @bitCast(value);

            assert(std.mem.readInt(u64, actual.data[0..8], .little) == bits);
        },
        .string => |text| {
            assert(actual.data.len == text.len + 1);
            assert(std.mem.eql(u8, actual.data[0..text.len], text));
            assert(actual.data[text.len] == 0);
        },
    }
}

fn base_type_of(value: Encoder.Value) Decoder.BaseType {
    return switch (value) {
        .enum_value => .enum_value,
        .uint8 => .uint8,
        .uint16 => .uint16,
        .uint32 => .uint32,
        .sint8 => .sint8,
        .sint16 => .sint16,
        .sint32 => .sint32,
        .float32 => .float32,
        .float64 => .float64,
        .string => .string,
    };
}

fn check_stream(gpa: Allocator, message_count: usize, bytes: []const u8) !void {
    var reader = std.Io.Reader.fixed(bytes);
    var decoder = try Decoder.init(&reader);

    var stream = decode.Stream.init(&decoder, gpa);
    defer stream.deinit();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    var count: usize = 0;

    while (count <= message_count) : (count += 1) {
        _ = arena_state.reset(.retain_capacity);

        const message = (try stream.next(arena_state.allocator())) orelse break;

        assert(message.name.len > 0);

        std.mem.doNotOptimizeAway(message.fields.len);
    }

    assert(count == message_count);
}

test "fuzz: random encoder output round-trips through the decoder" {
    try main(std.testing.allocator, .{ .seed = 0x2f17_f5ed, .events_max = 8 });
}
