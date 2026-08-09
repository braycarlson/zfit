const std = @import("std");

pub const emit = @import("emit.zig");
pub const model = @import("model.zig");
pub const render = @import("render.zig");
pub const sheets = @import("sheets.zig");
pub const xlsx = @import("xlsx.zig");
pub const xml = @import("xml.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const Error = xlsx.SheetError || sheets.Error || model.Error || emit.Error;

pub const Output = struct {
    types: []const u8,
    messages: []const u8,
    profile: model.Model,
};

pub const types_sheet = "Types";
pub const messages_sheet = "Messages";

comptime {
    assert(types_sheet.len > 0);
    assert(messages_sheet.len > 0);
    assert(!std.mem.eql(u8, types_sheet, messages_sheet));
}

pub fn generate(arena: Allocator, archive: []const u8) Error!Output {
    assert(archive.len > 0);

    const workbook = try xlsx.Workbook.open(arena, archive);
    const type_rows = try workbook.read_sheet(arena, types_sheet);
    const message_rows = try workbook.read_sheet(arena, messages_sheet);

    assert(type_rows.len > 0);
    assert(message_rows.len > 0);

    const source = try sheets.parse(arena, type_rows, message_rows);
    const profile = try model.resolve(arena, &source);

    assert(profile.types.len > 0);
    assert(profile.messages.len > 0);
    assert(profile.types.len <= source.types.len);
    assert(profile.messages.len <= source.messages.len);

    return .{
        .types = try emit.types_file(arena, &profile),
        .messages = try emit.messages_file(arena, &profile),
        .profile = profile,
    };
}
