const std = @import("std");

const BaseType = @import("decoder.zig").BaseType;
const messages = @import("profile/messages.zig");
const types = @import("profile/types.zig");

pub const TypeId = types.TypeId;
pub const type_value_name = types.type_value_name;
pub const message_info = messages.message_info;

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
    type_id: ?TypeId,
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
    type_id: ?TypeId,
    base_type: ?BaseType,
    scale: f64,
    offset: f64,
    units: []const u8,
    array: bool,
    accumulate: bool,
    components: []const Component,
    subfields: []const SubField,
};

pub const MessageInfo = struct {
    global_number: u16,
    name: []const u8,
    fields: []const FieldInfo,

    pub fn field(message: *const MessageInfo, number: u8) ?*const FieldInfo {
        for (message.fields) |*info| {
            if (info.number == number) return info;
        }

        return null;
    }
};

test "profile resolves known messages, fields, and enum names" {
    const record = message_info(20).?;

    try std.testing.expectEqualStrings("record", record.name);

    const heart_rate = record.field(3).?;

    try std.testing.expectEqualStrings("heart_rate", heart_rate.name);
    try std.testing.expectEqualStrings("bpm", heart_rate.units);

    const speed = record.field(6).?;

    try std.testing.expectEqualStrings("m/s", speed.units);
    try std.testing.expectEqual(@as(f64, 1000.0), speed.scale);

    try std.testing.expectEqualStrings("file_id", message_info(0).?.name);
    try std.testing.expectEqualStrings("activity", type_value_name(.file, 4).?);
    try std.testing.expectEqualStrings("garmin", type_value_name(.manufacturer, 1).?);
    try std.testing.expect(message_info(64000) == null);
}
