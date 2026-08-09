const std = @import("std");

const Decoder = @import("decoder.zig");
const decode = @import("decode.zig");
const epoch = @import("epoch.zig");
const garmin = @import("garmin.zig");
const value_module = @import("value.zig");

const Allocator = std.mem.Allocator;
const Message = decode.Message;
const Value = value_module.Value;
const Writer = std.Io.Writer;
const assert = std.debug.assert;

pub const Error = decode.Error || Writer.Error;

const Columns = struct {
    names: []const []const u8,
    index_of: std.StringHashMapUnmanaged(u32),

    fn deinit(columns: *Columns, gpa: Allocator) void {
        assert(columns.names.len == columns.index_of.count());

        columns.index_of.deinit(gpa);
    }
};

const ChannelSample = struct {
    id: u64,
    value: u64,
};

const message_count_max = Decoder.message_count_max;

const column_count_max = 4096;

const csv_quoting_bytes = ",\"\n";

comptime {
    assert(column_count_max > Decoder.field_count_max);
}

pub fn write_json(out: *Writer, gpa: Allocator, bytes: []const u8) Error!void {
    var reader = std.Io.Reader.fixed(bytes);
    var decoder = try Decoder.init(&reader);
    var stream = decode.Stream.init(&decoder, gpa);
    defer stream.deinit();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    try out.writeAll("[\n");

    var count: u32 = 0;

    while (count < message_count_max) : (count += 1) {
        _ = arena_state.reset(.retain_capacity);

        const message = (try stream.next(arena_state.allocator())) orelse break;

        if (count > 0) try out.writeAll(",\n");

        try write_message_json(out, message);
    }

    try out.writeAll("\n]\n");
}

fn write_message_json(out: *Writer, message: Message) Error!void {
    assert(message.name.len > 0);

    try out.writeAll("  {\"message\": ");
    try write_json_string(out, message.name);
    try out.print(", \"global\": {d}", .{message.global_number});

    if (message.timestamp) |timestamp| {
        try out.print(", \"timestamp\": {d}", .{epoch.to_unix_seconds(timestamp)});
    }

    try out.writeAll(", \"fields\": {");

    for (message.fields, 0..) |field, index| {
        if (index > 0) try out.writeAll(", ");

        assert(field.name.len > 0);

        try write_json_string(out, field.name);
        try out.writeAll(": ");
        try write_value_json(out, field.value);
    }

    try out.writeAll("}}");
}

fn write_value_json(out: *Writer, value: Value) Error!void {
    switch (value) {
        .none => try out.writeAll("null"),
        .integer => |number| try out.print("{d}", .{number}),
        .unsigned => |number| try out.print("{d}", .{number}),
        .real => |number| try write_json_number(out, number),
        .string => |text| try write_json_string(out, text),
        .enumeration => |name| try write_json_string(out, name),
        .bytes => |data| try write_hex_string(out, data),
        .integer_array => |items| {
            try out.writeAll("[");

            for (items, 0..) |item, index| {
                if (index > 0) try out.writeAll(", ");

                try out.print("{d}", .{item});
            }

            try out.writeAll("]");
        },
        .real_array => |items| {
            try out.writeAll("[");

            for (items, 0..) |item, index| {
                if (index > 0) try out.writeAll(", ");

                try write_json_number(out, item);
            }

            try out.writeAll("]");
        },
    }
}

fn write_json_number(out: *Writer, number: f64) Error!void {
    if (std.math.isFinite(number)) {
        try out.print("{d}", .{number});
    } else {
        try out.writeAll("null");
    }
}

pub fn write_csv(out: *Writer, gpa: Allocator, bytes: []const u8, global_number: u16) Error!void {
    var columns_arena = std.heap.ArenaAllocator.init(gpa);
    defer columns_arena.deinit();

    const columns_allocator = columns_arena.allocator();

    var columns = try collect_columns(gpa, columns_allocator, bytes, global_number);
    defer columns.deinit(gpa);

    const row = try columns_allocator.alloc(?Value, columns.names.len);

    assert(row.len == columns.names.len);
    assert(row.len <= column_count_max);

    try out.writeAll("timestamp_unix");

    for (columns.names) |name| {
        try out.writeAll(",");
        try write_csv_field(out, name);
    }

    try out.writeAll("\n");

    var reader = std.Io.Reader.fixed(bytes);
    var decoder = try Decoder.init(&reader);
    var stream = decode.Stream.init(&decoder, gpa);
    defer stream.deinit();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    var count: u32 = 0;

    while (count < message_count_max) : (count += 1) {
        _ = arena_state.reset(.retain_capacity);

        const message = (try stream.next(arena_state.allocator())) orelse break;

        if (message.global_number != global_number) continue;

        fill_row(&columns, row, message);

        try write_csv_row(out, row, message.timestamp);
    }
}

fn fill_row(columns: *const Columns, row: []?Value, message: Message) void {
    assert(row.len == columns.names.len);
    assert(row.len == columns.index_of.count());

    @memset(row, null);

    for (message.fields) |field| {
        const column = columns.index_of.get(field.name) orelse continue;

        assert(column < row.len);
        assert(std.mem.eql(u8, columns.names[column], field.name));

        if (row[column] == null) row[column] = field.value;
    }
}

fn write_csv_row(out: *Writer, row: []const ?Value, timestamp: ?u32) Error!void {
    assert(row.len <= column_count_max);

    if (timestamp) |seconds| {
        try out.print("{d}", .{epoch.to_unix_seconds(seconds)});
    }

    for (row) |cell| {
        try out.writeAll(",");
        if (cell) |value| try write_value_csv(out, value);
    }

    try out.writeAll("\n");
}

pub fn write_channels_233(out: *Writer, gpa: Allocator, bytes: []const u8) Error!void {
    var reader = std.Io.Reader.fixed(bytes);
    var decoder = try Decoder.init(&reader);
    var stream = decode.Stream.init(&decoder, gpa);
    defer stream.deinit();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    try out.writeAll("index,timestamp_unix,channel,value\n");

    var count: u32 = 0;
    var index: u32 = 0;

    while (count < message_count_max) : (count += 1) {
        _ = arena_state.reset(.retain_capacity);

        const message = (try stream.next(arena_state.allocator())) orelse break;

        if (message.global_number != garmin.channel_message_number) continue;

        const sample = channel_sample(message) orelse continue;

        try write_channel_row(out, index, stream.decoder.timestamp, sample);

        index += 1;
    }
}

fn channel_sample(message: Message) ?ChannelSample {
    assert(message.global_number == garmin.channel_message_number);

    var id: ?u64 = null;
    var value: ?u64 = null;

    for (message.fields) |field| {
        const unsigned = switch (field.value) {
            .unsigned => |number| number,
            .none, .integer, .real, .string, .enumeration, .bytes => continue,
            .integer_array, .real_array => continue,
        };

        if (std.mem.eql(u8, field.name, garmin.channel_field_name)) id = unsigned;
        if (std.mem.eql(u8, field.name, garmin.channel_value_field_name)) value = unsigned;
    }

    const found_id = id orelse return null;
    const found_value = value orelse return null;

    if (found_id > std.math.maxInt(u5)) return null;
    if (found_value > std.math.maxInt(u27)) return null;

    return .{ .id = found_id, .value = found_value };
}

fn write_channel_row(
    out: *Writer,
    index: u32,
    timestamp: ?u32,
    sample: ChannelSample,
) Error!void {
    assert(sample.id <= std.math.maxInt(u5));
    assert(sample.value <= std.math.maxInt(u27));

    try out.print("{d},", .{index});

    if (timestamp) |seconds| try out.print("{d}", .{epoch.to_unix_seconds(seconds)});

    try out.print(",{d},{d}\n", .{ sample.id, sample.value });
}

fn collect_columns(
    gpa: Allocator,
    storage: Allocator,
    bytes: []const u8,
    global_number: u16,
) Error!Columns {
    var reader = std.Io.Reader.fixed(bytes);
    var decoder = try Decoder.init(&reader);
    var stream = decode.Stream.init(&decoder, gpa);
    defer stream.deinit();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    var names: std.ArrayList([]const u8) = .empty;
    var index_of: std.StringHashMapUnmanaged(u32) = .empty;
    errdefer index_of.deinit(gpa);

    var count: u32 = 0;

    while (count < message_count_max) : (count += 1) {
        _ = arena_state.reset(.retain_capacity);

        const message = (try stream.next(arena_state.allocator())) orelse break;

        if (message.global_number != global_number) continue;
        if (names.items.len == column_count_max) break;

        for (message.fields) |field| {
            if (names.items.len == column_count_max) break;

            if (index_of.contains(field.name)) continue;

            const owned = try storage.dupe(u8, field.name);
            const column: u32 = @intCast(names.items.len);

            try index_of.put(gpa, owned, column);
            try names.append(storage, owned);

            assert(index_of.get(owned).? == column);
        }
    }

    assert(names.items.len == index_of.count());
    assert(names.items.len <= column_count_max);

    return .{ .names = names.items, .index_of = index_of };
}

fn write_value_csv(out: *Writer, value: Value) Error!void {
    switch (value) {
        .none => {},
        .integer => |number| try out.print("{d}", .{number}),
        .unsigned => |number| try out.print("{d}", .{number}),
        .real => |number| try out.print("{d}", .{number}),
        .string => |text| try write_csv_field(out, text),
        .enumeration => |name| try write_csv_field(out, name),
        .bytes => |data| for (data) |byte| try out.print("{x:0>2}", .{byte}),
        .integer_array => |items| for (items, 0..) |item, index| {
            if (index > 0) try out.writeAll(" ");

            try out.print("{d}", .{item});
        },
        .real_array => |items| for (items, 0..) |item, index| {
            if (index > 0) try out.writeAll(" ");

            try out.print("{d}", .{item});
        },
    }
}

fn write_csv_field(out: *Writer, text: []const u8) Error!void {
    if (std.mem.indexOfAny(u8, text, csv_quoting_bytes) == null) {
        try out.writeAll(text);

        return;
    }

    try out.writeAll("\"");

    for (text) |byte| {
        if (byte == '"') try out.writeAll("\"\"") else try out.writeByte(byte);
    }

    try out.writeAll("\"");
}

fn write_hex_string(out: *Writer, data: []const u8) Error!void {
    assert(data.len <= Decoder.field_bytes_max);

    try out.writeAll("\"");
    for (data) |byte| try out.print("{x:0>2}", .{byte});
    try out.writeAll("\"");
}

fn write_json_string(out: *Writer, text: []const u8) Error!void {
    assert(text.len <= Decoder.payload_bytes_max);

    try out.writeAll("\"");

    for (text) |byte| {
        switch (byte) {
            '"' => try out.writeAll("\\\""),
            '\\' => try out.writeAll("\\\\"),
            '\n' => try out.writeAll("\\n"),
            '\r' => try out.writeAll("\\r"),
            '\t' => try out.writeAll("\\t"),
            else => try out.writeByte(byte),
        }
    }

    try out.writeAll("\"");
}
