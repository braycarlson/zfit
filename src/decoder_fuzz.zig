const std = @import("std");

const Decoder = @import("decoder.zig");
const crc = @import("crc.zig");
const decode = @import("decode.zig");
const fuzz = @import("testing/fuzz.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Generated = struct {
    bytes: []const u8,
    message_count_total: u32,
    message_count_first: u32,
};

const Weights = struct {
    define: u8,
    data: u8,
    compressed: u8,
};

const Generator = struct {
    arena: Allocator,
    random: std.Random,
    body: std.ArrayList(u8),
    locals: [Decoder.local_type_count]?u32,

    fn emit_operation(g: *Generator, weights: Weights) !u32 {
        const any = g.pick_defined(Decoder.local_type_count) orelse {
            try g.emit_definition();

            return 0;
        };

        const total = @as(u32, weights.define) + weights.data + weights.compressed;
        const roll = g.random.uintLessThan(u32, total);

        if (roll < weights.define) {
            try g.emit_definition();

            return 0;
        }

        if (roll < @as(u32, weights.define) + weights.data) {
            try g.emit_data(any);

            return 1;
        }

        const low = g.pick_defined(compressed_local_count) orelse {
            try g.emit_data(any);

            return 1;
        };

        try g.emit_compressed(low);

        return 1;
    }

    fn pick_defined(g: *Generator, limit: u8) ?u4 {
        assert(limit >= 1);
        assert(limit <= Decoder.local_type_count);

        var candidates: [Decoder.local_type_count]u4 = undefined;
        var count: u8 = 0;

        for (g.locals[0..limit], 0..) |slot, index| {
            if (slot != null) {
                candidates[count] = @intCast(index);
                count += 1;
            }
        }

        if (count == 0) return null;

        return candidates[g.random.uintLessThan(u8, count)];
    }

    fn pick_global(g: *Generator) u16 {
        if (g.random.boolean()) {
            return globals_pool[g.random.uintLessThan(u8, globals_pool.len)];
        }

        return g.random.int(u16);
    }

    fn emit_definition(g: *Generator) !void {
        const local = g.random.int(u4);
        const big = g.random.boolean();
        const architecture: std.builtin.Endian = if (big) .big else .little;
        const global = g.pick_global();
        const field_count = g.random.uintAtMost(u8, field_count_gen_max);
        const has_developer = g.random.int(u2) == 0;

        const record = Decoder.RecordHeaderNormal{
            .local_message_type = local,
            .reserved = 0,
            .has_developer_data = @intFromBool(has_developer),
            .message_kind = .definition,
            .header_kind = .normal,
        };

        try g.body.append(g.arena, @bitCast(record));
        try g.body.append(g.arena, g.random.int(u8));
        try g.body.append(g.arena, @intFromBool(big));

        var global_bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &global_bytes, global, architecture);

        try g.body.appendSlice(g.arena, &global_bytes);
        try g.body.append(g.arena, field_count);

        var payload: u32 = 0;
        var index: u8 = 0;

        while (index < field_count) : (index += 1) {
            payload += try g.emit_field_definition();
        }

        if (has_developer) payload += try g.emit_developer_definitions();

        assert(payload <= payload_bytes_gen_max);

        g.locals[local] = payload;
    }

    fn emit_field_definition(g: *Generator) !u32 {
        const number = if (g.random.int(u2) == 0)
            Decoder.timestamp_field_number
        else
            g.random.int(u8);

        const base = g.random.enumValue(Decoder.BaseType);
        const element = base.size_bytes();

        const size: u8 = switch (g.random.int(u2)) {
            0 => element,
            1 => element * (1 + g.random.uintLessThan(u8, 4)),
            2 => g.random.int(u8),
            3 => 0,
        };

        try g.body.append(g.arena, number);
        try g.body.append(g.arena, size);
        try g.body.append(g.arena, @intFromEnum(base));

        return size;
    }

    fn emit_developer_definitions(g: *Generator) !u32 {
        const count = g.random.uintAtMost(u8, developer_count_gen_max);

        try g.body.append(g.arena, count);

        var total: u32 = 0;
        var index: u8 = 0;

        while (index < count) : (index += 1) {
            const size = g.random.uintAtMost(u8, developer_field_bytes_gen_max);

            try g.body.append(g.arena, g.random.int(u8));
            try g.body.append(g.arena, size);
            try g.body.append(g.arena, g.random.uintAtMost(u8, 3));

            total += size;
        }

        assert(total <= developer_count_gen_max * developer_field_bytes_gen_max);

        return total;
    }

    fn emit_data(g: *Generator, local: u4) !void {
        assert(g.locals[local] != null);

        const record = Decoder.RecordHeaderNormal{
            .local_message_type = local,
            .reserved = 0,
            .has_developer_data = 0,
            .message_kind = .data,
            .header_kind = .normal,
        };

        try g.body.append(g.arena, @bitCast(record));
        try g.emit_payload(g.locals[local].?);
    }

    fn emit_compressed(g: *Generator, local: u4) !void {
        assert(local < compressed_local_count);
        assert(g.locals[local] != null);

        const header = compressed_header_bit | (@as(u8, local) << 5) | g.random.int(u5);

        try g.body.append(g.arena, header);
        try g.emit_payload(g.locals[local].?);
    }

    fn emit_payload(g: *Generator, size: u32) !void {
        assert(size <= payload_bytes_gen_max);

        const slice = try g.body.addManyAsSlice(g.arena, size);

        g.random.bytes(slice);
    }
};

const segment_count_gen_max = 3;
const operation_count_gen_max = 64;
const field_count_gen_max = 8;
const developer_count_gen_max = 40;
const developer_field_bytes_gen_max = 16;
const mutation_round_count = 4;
const mutation_flip_count_max = 16;

const compressed_header_bit: u8 = 0x80;
const compressed_local_count = 4;

const definition_bytes_max = 6 + 3 * field_count_gen_max + 1 + 3 * developer_count_gen_max;
const payload_bytes_gen_max = field_count_gen_max * Decoder.field_bytes_max +
    developer_count_gen_max * developer_field_bytes_gen_max;
const operation_bytes_max = 1 + payload_bytes_gen_max;
const body_bytes_gen_max = operation_count_gen_max * operation_bytes_max;

const globals_pool = [_]u16{ 0, 18, 19, 20, 21, 34, 78, 104, 206, 233 };

comptime {
    assert(compressed_header_bit == 1 << 7);
    assert(compressed_local_count == std.math.maxInt(u2) + 1);
    assert(compressed_local_count <= Decoder.local_type_count);
    assert(developer_count_gen_max > Decoder.developer_field_count_max);
    assert(definition_bytes_max < operation_bytes_max);
    assert(payload_bytes_gen_max <= Decoder.payload_bytes_max);
    assert(body_bytes_gen_max <= Decoder.data_size_max);
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
    const generated = try generate(arena, random);

    assert(generated.bytes.len >= Decoder.header_bytes + crc.checksum_bytes);
    assert(generated.message_count_first <= generated.message_count_total);

    try check_valid_decoder(&generated);
    try check_valid_stream(gpa, &generated);

    var round: u32 = 0;

    while (round < mutation_round_count) : (round += 1) {
        try check_mutated(gpa, arena, random, generated.bytes);
    }
}

fn generate(arena: Allocator, random: std.Random) !Generated {
    var file: std.ArrayList(u8) = .empty;

    const segment_count = 1 + random.uintLessThan(u8, segment_count_gen_max);

    var total: u32 = 0;
    var first: u32 = 0;
    var segment: u8 = 0;

    while (segment < segment_count) : (segment += 1) {
        const count = try generate_segment(arena, random, &file);

        if (segment == 0) first = count;

        total += count;
    }

    assert(file.items.len >= segment_count * (Decoder.header_bytes + crc.checksum_bytes));

    return .{
        .bytes = file.items,
        .message_count_total = total,
        .message_count_first = first,
    };
}

fn generate_segment(arena: Allocator, random: std.Random, file: *std.ArrayList(u8)) !u32 {
    var generator = Generator{
        .arena = arena,
        .random = random,
        .body = .empty,
        .locals = .{null} ** Decoder.local_type_count,
    };

    const weights = Weights{
        .define = 1 + random.uintLessThan(u8, 8),
        .data = 1 + random.uintLessThan(u8, 8),
        .compressed = random.uintLessThan(u8, 4),
    };

    const operation_count = random.uintAtMost(u8, operation_count_gen_max);

    var messages: u32 = 0;
    var operation: u8 = 0;

    while (operation < operation_count) : (operation += 1) {
        messages += try generator.emit_operation(weights);
    }

    assert(generator.body.items.len <= body_bytes_gen_max);
    assert(messages <= operation_count);

    try wrap_segment(arena, random, file, generator.body.items);

    return messages;
}

fn wrap_segment(
    arena: Allocator,
    random: std.Random,
    file: *std.ArrayList(u8),
    body: []const u8,
) !void {
    assert(body.len <= Decoder.data_size_max);

    const with_crc = random.boolean();
    const header_size: u8 = if (with_crc) Decoder.header_bytes_with_crc else Decoder.header_bytes;

    var header: [Decoder.header_bytes_with_crc]u8 = undefined;
    header[0] = header_size;
    header[1] = random.int(u8);
    std.mem.writeInt(u16, header[2..4], random.int(u16), .little);
    std.mem.writeInt(u32, header[4..8], @intCast(body.len), .little);
    @memcpy(header[Decoder.signature_offset..Decoder.header_bytes], Decoder.file_signature);

    if (with_crc) {
        const header_crc = if (random.boolean()) crc.checksum(0, header[0..12]) else 0;

        std.mem.writeInt(u16, header[12..14], header_crc, .little);
    }

    const start = file.items.len;

    try file.appendSlice(arena, header[0..header_size]);
    try file.appendSlice(arena, body);

    const trailer = crc.checksum(0, file.items[start..]);

    var trailer_bytes: [crc.checksum_bytes]u8 = undefined;
    std.mem.writeInt(u16, &trailer_bytes, trailer, .little);

    try file.appendSlice(arena, &trailer_bytes);

    assert(file.items.len == start + header_size + body.len + crc.checksum_bytes);
}

fn check_valid_decoder(generated: *const Generated) !void {
    var reader = std.Io.Reader.fixed(generated.bytes);
    var decoder = try Decoder.init(&reader);

    var count: u32 = 0;

    while (try decoder.next()) |message| {
        count += 1;

        assert(count <= generated.message_count_first);
        assert(message.payload.len == message.definition.payload_size_bytes);

        var fields = message.fields();

        while (fields.next()) |field| std.mem.doNotOptimizeAway(field.data.len);

        var developer_fields = message.developer_fields();

        while (developer_fields.next()) |field| std.mem.doNotOptimizeAway(field.data.len);
    }

    assert(count == generated.message_count_first);
}

fn check_valid_stream(gpa: Allocator, generated: *const Generated) !void {
    var reader = std.Io.Reader.fixed(generated.bytes);
    var decoder = try Decoder.init(&reader);

    var stream = decode.Stream.init(&decoder, gpa);
    defer stream.deinit();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    var count: u32 = 0;

    while (count <= generated.message_count_total) : (count += 1) {
        _ = arena_state.reset(.retain_capacity);

        const message = (try stream.next(arena_state.allocator())) orelse break;

        assert(message.name.len > 0);

        std.mem.doNotOptimizeAway(message.fields.len);
    }

    assert(count == generated.message_count_total);
}

fn check_mutated(gpa: Allocator, arena: Allocator, random: std.Random, bytes: []const u8) !void {
    assert(bytes.len >= Decoder.header_bytes);

    const copy = try arena.dupe(u8, bytes);
    const flips = 1 + random.uintLessThan(u32, mutation_flip_count_max);

    var flip: u32 = 0;

    while (flip < flips) : (flip += 1) {
        const index = random.uintLessThan(usize, copy.len);
        copy[index] ^= random.int(u8);
    }

    const length = if (random.int(u2) == 0) random.uintAtMost(usize, copy.len) else copy.len;

    decode_survives(gpa, copy[0..length]);
}

fn decode_survives(gpa: Allocator, bytes: []const u8) void {
    var reader = std.Io.Reader.fixed(bytes);
    var decoder = Decoder.init(&reader) catch return;

    var stream = decode.Stream.init(&decoder, gpa);
    defer stream.deinit();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    var count: usize = 0;

    while (count <= bytes.len) : (count += 1) {
        _ = arena_state.reset(.retain_capacity);

        const message = (stream.next(arena_state.allocator()) catch return) orelse return;

        std.mem.doNotOptimizeAway(message.fields.len);
    }

    unreachable;
}

test "fuzz: generated files decode exactly and mutations cannot crash" {
    try main(std.testing.allocator, .{ .seed = 0xDEC0DE, .events_max = 8 });
}
