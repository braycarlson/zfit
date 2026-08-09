const builtin = @import("builtin");
const std = @import("std");

const zfit = @import("zfit");

const Allocator = std.mem.Allocator;
const DecodedField = zfit.DecodedField;
const Message = zfit.Message;
const Reader = std.Io.Reader;
const Value = zfit.Value;
const Writer = std.Io.Writer;
const assert = std.debug.assert;

const Mode = enum {
    dump,
    json,
    csv,
    channels,

    fn parse(text: []const u8) ?Mode {
        if (text.len == 0) return .dump;
        if (std.mem.eql(u8, text, "--json")) return .json;
        if (std.mem.eql(u8, text, "--csv")) return .csv;
        if (std.mem.eql(u8, text, "--ch233")) return .channels;

        return null;
    }
};

const Tally = struct {
    global_numbers: [entry_count_max]u16 = undefined,
    counts: [entry_count_max]u32 = undefined,
    len: u16 = 0,

    const entry_count_max = 256;

    fn add(tally: *Tally, global_number: u16) bool {
        assert(tally.len <= entry_count_max);

        var index: u16 = 0;

        while (index < tally.len) : (index += 1) {
            if (tally.global_numbers[index] == global_number) {
                tally.counts[index] += 1;

                assert(tally.counts[index] >= 2);

                return false;
            }
        }

        if (tally.len == entry_count_max) return false;

        tally.global_numbers[tally.len] = global_number;
        tally.counts[tally.len] = 1;
        tally.len += 1;

        assert(tally.len <= entry_count_max);
        assert(tally.global_numbers[tally.len - 1] == global_number);

        return true;
    }
};

const file_bytes_max = 64 * 1024 * 1024;

const array_print_max = 8;

const hex_print_max = 16;

const csv_global_number_default = 20;

const message_count_max = zfit.Decoder.message_count_max;

const usage = "usage: zfit <file.fit> [--json | --csv [global] | --ch233]\n";

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .initStreaming(stdout_file(), io, &stdout_buffer);
    const out = &stdout_writer.interface;

    const args = try init.minimal.args.toSlice(arena);

    if (args.len < 2) {
        try out.print(usage, .{});
        try out.flush();

        return error.MissingPathArgument;
    }

    const path = args[1];

    if (path.len == 0) return error.MissingPathArgument;

    const mode = Mode.parse(if (args.len > 2) args[2] else "") orelse {
        try out.print(usage, .{});
        try out.flush();

        return error.UnknownMode;
    };

    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(file_bytes_max));

    run(out, arena, mode, args, path, bytes) catch |err| switch (err) {
        error.WriteFailed => if (!stdout_closed(&stdout_writer)) return err,
        else => return err,
    };
}

fn run(
    out: *Writer,
    arena: Allocator,
    mode: Mode,
    args: []const []const u8,
    path: []const u8,
    bytes: []const u8,
) !void {
    switch (mode) {
        .dump => try dump(out, arena, path, bytes),
        .json => try zfit.exporter.write_json(out, arena, bytes),
        .csv => try zfit.exporter.write_csv(out, arena, bytes, try csv_global_number(args)),
        .channels => try zfit.exporter.write_channels_233(out, arena, bytes),
    }

    try out.flush();
}

fn stdout_closed(writer: *const std.Io.File.Writer) bool {
    const err = writer.err orelse return false;

    return switch (err) {
        error.BrokenPipe => true,
        error.Unexpected => builtin.os.tag == .windows,
        else => false,
    };
}

fn stdout_file() std.Io.File {
    var file = std.Io.File.stdout();

    if (builtin.os.tag == .windows) {
        file.flags.nonblocking = handle_is_asynchronous(file.handle);
    }

    return file;
}

fn handle_is_asynchronous(handle: std.os.windows.HANDLE) bool {
    const windows = std.os.windows;

    var status_block: windows.IO_STATUS_BLOCK = undefined;
    var info: windows.FILE.MODE.INFORMATION = undefined;

    const status = windows.ntdll.NtQueryInformationFile(
        handle,
        &status_block,
        &info,
        @sizeOf(windows.FILE.MODE.INFORMATION),
        .Mode,
    );

    if (status != .SUCCESS) return false;

    return info.Mode.IO == .ASYNCHRONOUS;
}

fn csv_global_number(args: []const []const u8) !u16 {
    if (args.len <= 3) return csv_global_number_default;

    return std.fmt.parseInt(u16, args[3], 10) catch error.InvalidGlobalMessageNumber;
}

fn dump(out: *Writer, gpa: Allocator, path: []const u8, bytes: []const u8) !void {
    assert(path.len > 0);

    var reader = Reader.fixed(bytes);
    var decoder = try zfit.Decoder.init(&reader);
    const header = decoder.header;

    try print_file_summary(out, path, bytes, header);

    var stream = zfit.Stream.init(&decoder, gpa);
    defer stream.deinit();

    var message_arena = std.heap.ArenaAllocator.init(gpa);
    defer message_arena.deinit();

    var tally = Tally{};
    var message_count: u32 = 0;

    while (message_count < message_count_max) {
        _ = message_arena.reset(.retain_capacity);

        const message = (try stream.next(message_arena.allocator())) orelse break;
        const first_seen = tally.add(message.global_number);
        message_count += 1;

        assert(message.name.len > 0);
        assert(tally.len <= Tally.entry_count_max);

        if (first_seen) try print_message(out, message);
    }

    try print_histogram(out, &tally);
    try out.print("\ntotal: {d} messages across {d} types\n", .{ message_count, tally.len });

    assert(message_count >= tally.len);
    assert(message_count <= message_count_max);
}

fn print_file_summary(
    out: *Writer,
    path: []const u8,
    bytes: []const u8,
    header: zfit.Header,
) !void {
    assert(path.len > 0);
    assert(bytes.len >= zfit.Decoder.header_bytes);

    const protocol_major = header.protocol_version >> 4;
    const protocol_minor = header.protocol_version & 0x0F;

    const crc_ok = if (zfit.verify_checksum(bytes)) |_| true else |_| false;

    try out.print("file:     {s}\n", .{path});
    try out.print("size:     {d} bytes\n", .{bytes.len});
    try out.print("protocol: {d}.{d}\n", .{ protocol_major, protocol_minor });
    try out.print("profile:  {d}\n", .{header.profile_version});
    try out.print("crc:      {s}\n\n", .{if (crc_ok) "ok" else "MISMATCH"});
}

fn print_message(out: *Writer, message: Message) !void {
    assert(message.name.len > 0);

    try out.print("[{s}]  global {d}", .{ message.name, message.global_number });

    if (message.timestamp) |timestamp| {
        try out.print("  @ ", .{});
        try print_datetime(out, timestamp);
    }

    try out.print("\n", .{});

    for (message.fields) |field| try print_field(out, field);
    try out.print("\n", .{});
}

fn print_field(out: *Writer, field: DecodedField) !void {
    assert(field.name.len > 0);

    try out.print("  {s:<26} = ", .{field.name});

    if (date_value(field)) |seconds| {
        try print_datetime(out, seconds);
    } else {
        try print_value(out, field.value, field.units);
    }

    try out.print("\n", .{});
}

fn date_value(field: DecodedField) ?u32 {
    const is_date = std.mem.eql(u8, field.fit_type, "date_time") or
        std.mem.eql(u8, field.fit_type, "local_date_time");

    if (!is_date) return null;
    if (field.value != .unsigned) return null;
    if (field.value.unsigned > std.math.maxInt(u32)) return null;

    return @intCast(field.value.unsigned);
}

fn print_value(out: *Writer, value: Value, units: []const u8) !void {
    switch (value) {
        .none => try out.print("(invalid)", .{}),
        .integer => |number| try out.print("{d}", .{number}),
        .unsigned => |number| try out.print("{d}", .{number}),
        .real => |number| try out.print("{d:.3}", .{number}),
        .string => |text| try out.print("\"{s}\"", .{text}),
        .enumeration => |name| try out.print("{s}", .{name}),
        .bytes => |data| try print_hex(out, data),
        .integer_array => |items| try print_array(out, i64, "{d}", items),
        .real_array => |items| try print_array(out, f64, "{d:.3}", items),
    }

    switch (value) {
        .integer, .unsigned, .real, .integer_array, .real_array => {
            if (units.len > 0) try out.print(" {s}", .{units});
        },
        .none, .string, .enumeration, .bytes => {},
    }
}

fn print_array(
    out: *Writer,
    comptime T: type,
    comptime item_format: []const u8,
    items: []const T,
) !void {
    const shown = @min(items.len, array_print_max);

    try out.print("[", .{});

    for (items[0..shown], 0..) |item, index| {
        if (index > 0) try out.print(", ", .{});

        try out.print(item_format, .{item});
    }

    if (items.len > shown) try out.print(", ...", .{});

    try out.print("]", .{});
}

fn print_hex(out: *Writer, data: []const u8) !void {
    const shown = @min(data.len, hex_print_max);

    for (data[0..shown]) |byte| try out.print("{x:0>2}", .{byte});

    if (data.len > shown) try out.print("...", .{});
}

fn print_datetime(out: *Writer, fit_seconds: u32) !void {
    const unix = zfit.epoch.to_unix_seconds(fit_seconds);

    assert(unix >= zfit.epoch.unix_offset_seconds);

    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(unix) };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();

    try out.print("{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} UTC", .{
        year_day.year,
        month_day.month.numeric(),
        @as(u16, month_day.day_index) + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    });
}

fn print_histogram(out: *Writer, tally: *const Tally) !void {
    assert(tally.len <= Tally.entry_count_max);

    try out.print("messages by type (desc):\n", .{});

    var order: [Tally.entry_count_max]u16 = undefined;
    var index: u16 = 0;

    while (index < tally.len) : (index += 1) order[index] = index;

    const slice = order[0..tally.len];
    std.mem.sort(u16, slice, tally, struct {
        fn less(context: *const Tally, left: u16, right: u16) bool {
            assert(left < context.len);
            assert(right < context.len);

            return context.counts[left] > context.counts[right];
        }
    }.less);

    for (slice) |entry| {
        const global_number = tally.global_numbers[entry];
        const info = zfit.profile.message_info(global_number);
        const name = if (info) |found| found.name else "unknown";
        const count = tally.counts[entry];

        assert(count >= 1);
        assert(name.len > 0);

        try out.print("  {s:<26} {d:>6}  (global {d})\n", .{ name, count, global_number });
    }
}
