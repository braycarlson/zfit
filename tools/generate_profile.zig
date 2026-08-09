const builtin = @import("builtin");
const std = @import("std");

const profile_gen = @import("profile_gen/root.zig");

const Allocator = std.mem.Allocator;
const Model = profile_gen.model.Model;
const Writer = std.Io.Writer;
const assert = std.debug.assert;

const Options = struct {
    check: bool,
    workbook_path: []const u8,
    types_path: []const u8,
    messages_path: []const u8,
};

const workbook_bytes_max = 32 * 1024 * 1024;

const table_bytes_max = 32 * 1024 * 1024;

const path_count = 3;

const check_flag = "--check";

const usage = "usage: generate_profile [--check] <Profile.xlsx> <types.zig> <messages.zig>\n";

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .initStreaming(stdout_file(), io, &stdout_buffer);
    const out = &stdout_writer.interface;

    const args = try init.minimal.args.toSlice(arena);

    const options = parse_options(args) orelse {
        try out.print(usage, .{});
        try out.flush();

        return error.MissingPathArgument;
    };

    const archive = try std.Io.Dir.cwd().readFileAlloc(
        io,
        options.workbook_path,
        arena,
        .limited(workbook_bytes_max),
    );

    const output = try profile_gen.generate(arena, archive);

    assert(output.types.len > 0);
    assert(output.messages.len > 0);

    if (options.check) {
        try check(io, arena, out, &options, output);
    } else {
        try write(io, &options, output);
    }

    try report(out, &output.profile);
    try out.flush();
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

fn parse_options(args: []const []const u8) ?Options {
    if (args.len < 2) return null;

    const check_requested = std.mem.eql(u8, args[1], check_flag);
    const paths = if (check_requested) args[2..] else args[1..];

    if (paths.len != path_count) return null;

    for (paths) |path| {
        if (path.len == 0) return null;
    }

    return .{
        .check = check_requested,
        .workbook_path = paths[0],
        .types_path = paths[1],
        .messages_path = paths[2],
    };
}

fn write(io: std.Io, options: *const Options, output: profile_gen.Output) !void {
    assert(output.types.len > 0);
    assert(output.messages.len > 0);
    assert(options.types_path.len > 0);
    assert(options.messages_path.len > 0);

    const cwd = std.Io.Dir.cwd();

    try cwd.writeFile(io, .{ .sub_path = options.types_path, .data = output.types });
    try cwd.writeFile(io, .{ .sub_path = options.messages_path, .data = output.messages });
}

fn check(
    io: std.Io,
    arena: Allocator,
    out: *Writer,
    options: *const Options,
    output: profile_gen.Output,
) !void {
    assert(options.types_path.len > 0);
    assert(options.messages_path.len > 0);

    var stale = false;
    stale = try check_one(io, arena, out, options.types_path, output.types) or stale;
    stale = try check_one(io, arena, out, options.messages_path, output.messages) or stale;

    if (stale) {
        try out.print("run `zig build profile` to regenerate\n", .{});
        try out.flush();

        return error.GeneratedTablesAreStale;
    }
}

fn check_one(
    io: std.Io,
    arena: Allocator,
    out: *Writer,
    path: []const u8,
    expected: []const u8,
) !bool {
    assert(path.len > 0);
    assert(expected.len > 0);

    const cwd = std.Io.Dir.cwd();

    const committed = cwd.readFileAlloc(io, path, arena, .limited(table_bytes_max)) catch {
        try out.print("{s}: missing\n", .{path});

        return true;
    };

    if (std.mem.eql(u8, committed, expected)) return false;

    try out.print("{s}: {d} bytes committed, {d} bytes generated\n", .{
        path,
        committed.len,
        expected.len,
    });

    return true;
}

fn report(out: *Writer, profile: *const Model) !void {
    assert(profile.types.len > 0);
    assert(profile.messages.len > 0);

    var fields: u32 = 0;
    var values: u32 = 0;

    for (profile.messages) |message| fields += @intCast(message.fields.len);
    for (profile.types) |table| values += @intCast(table.values.len);

    assert(fields >= profile.messages.len);
    assert(values >= profile.types.len);

    try out.print("types:    {d} ({d} named values)\n", .{ profile.types.len, values });
    try out.print("messages: {d}\n", .{profile.messages.len});
    try out.print("fields:   {d}\n", .{fields});
}
