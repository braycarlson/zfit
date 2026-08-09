const std = @import("std");

const profile = @import("profile.zig");

const assert = std.debug.assert;

pub const Channel233 = struct {
    id: u8,
    value: u32,
};

pub const Evidence = enum {
    measured,
    reported,
};

pub const MessageSupplement = struct {
    global_number: u16,
    name: []const u8,
    evidence: Evidence,
};

pub const FieldSupplement = struct {
    global_number: u16,
    field_number: u8,
    name: []const u8,
    fit_type: []const u8,
    units: []const u8,
    scale: f64,
    offset: f64,
    evidence: Evidence,
};

pub const channel_message_number = 233;

pub const channel_field_number = 2;

pub const channel_field_name = "channel";
pub const channel_value_field_name = "channel_value";

const channel_field_bytes = 4;
const channel_id_shift = 27;
const channel_value_mask: u32 = (1 << channel_id_shift) - 1;

comptime {
    assert(channel_field_bytes == @sizeOf(u32));
    assert(channel_id_shift < @bitSizeOf(u32));
    assert(channel_value_mask == 0x07FFFFFF);
    assert(@popCount(channel_value_mask) == channel_id_shift);
}

const date_time_type = "date_time";

const vo2_max_scale_narrow = 1024.0 / 3.5;
const vo2_max_scale_wide = 65536.0 / 3.5;

comptime {
    assert(vo2_max_scale_narrow > 0.0);
    assert(vo2_max_scale_wide > vo2_max_scale_narrow);
}

pub const message_supplements = [_]MessageSupplement{
    .{ .global_number = 22, .name = "device_used", .evidence = .reported },
    .{ .global_number = 79, .name = "user_metrics", .evidence = .measured },
    .{ .global_number = 104, .name = "device_status", .evidence = .measured },
    .{ .global_number = 140, .name = "activity_metrics", .evidence = .reported },
    .{ .global_number = 141, .name = "epo_status", .evidence = .reported },
    .{ .global_number = 288, .name = "ambient_conditions", .evidence = .measured },
    .{ .global_number = 325, .name = "gnss_status", .evidence = .measured },
    .{ .global_number = 326, .name = "gps_event", .evidence = .reported },
    .{ .global_number = 394, .name = "cpe_status", .evidence = .measured },
};

pub const field_supplements = [_]FieldSupplement{
    plain_field(19, 27, "nec_lat", "semicircles", .measured),
    plain_field(19, 28, "nec_long", "semicircles", .measured),
    plain_field(19, 29, "swc_lat", "semicircles", .measured),
    plain_field(19, 30, "swc_long", "semicircles", .measured),
    plain_field(19, 145, "est_sweat_loss", "ml", .reported),
    plain_field(19, 152, "execution_score", "percent", .reported),
    plain_field(19, 155, "resting_calories", "kcal", .measured),

    plain_field(20, 136, "wrist_heart_rate", "bpm", .measured),
    plain_field(20, 143, "body_battery", "", .reported),

    plain_field(22, 0, "speed_device_index", "", .reported),
    plain_field(22, 1, "distance_device_index", "", .reported),
    plain_field(22, 2, "cadence_device_index", "", .reported),
    plain_field(22, 3, "elevation_device_index", "", .reported),
    plain_field(22, 4, "heart_rate_device_index", "", .reported),
    plain_field(22, 6, "power_device_index", "", .reported),

    scaled_field(79, 0, "vo2_max", "ml/kg/min", vo2_max_scale_narrow, .measured),
    plain_field(79, 1, "age", "yrs", .measured),
    scaled_field(79, 2, "height", "m", 100.0, .measured),
    scaled_field(79, 3, "weight", "kg", 10.0, .measured),
    plain_field(79, 6, "max_heart_rate", "bpm", .measured),
    plain_field(79, 8, "remaining_recovery_time", "min", .reported),
    plain_field(79, 11, "lactate_threshold_heart_rate", "bpm", .reported),
    plain_field(79, 15, "beginning_body_battery", "", .measured),
    time_field(79, 16, "start_of_activity", .reported),
    scaled_field(79, 19, "first_vo2_max", "ml/kg/min", vo2_max_scale_wide, .reported),
    time_field(79, 35, "end_of_previous_activity", .reported),
    time_field(79, 39, "wake_up_time", .reported),

    scaled_field(104, 0, "battery_voltage", "V", 1000.0, .measured),
    plain_field(104, 2, "battery_level", "percent", .measured),
    plain_field(104, 3, "temperature", "C", .measured),

    scaled_field(140, 4, "aerobic_training_effect", "", 10.0, .reported),
    scaled_field(140, 7, "vo2_max", "ml/kg/min", vo2_max_scale_wide, .reported),
    plain_field(140, 9, "recovery_time", "min", .reported),
    plain_field(140, 14, "lactate_threshold_heart_rate", "bpm", .reported),
    scaled_field(140, 20, "anaerobic_training_effect", "", 10.0, .reported),
    plain_field(140, 25, "ending_body_battery", "", .reported),

    plain_field(141, 0, "status", "", .reported),
    time_field(141, 1, "start_time", .reported),
    time_field(141, 2, "end_time", .reported),

    plain_field(288, 0, "temperature", "C", .measured),
    plain_field(288, 1, "humidity", "percent", .measured),

    plain_field(325, 2, "solution_state", "", .measured),

    plain_field(326, 0, "event_type", "", .reported),
    plain_field(326, 1, "data", "", .reported),

    plain_field(394, 0, "status", "", .reported),
    time_field(394, 1, "start_time", .measured),
    time_field(394, 2, "end_time", .measured),
};

comptime {
    @setEvalBranchQuota(8 * (message_supplements.len * message_supplements.len +
        field_supplements.len * field_supplements.len) + 1000);

    assert(message_supplements.len > 0);
    assert(field_supplements.len > 0);

    for (message_supplements, 0..) |entry, index| {
        assert(entry.name.len > 0);

        for (message_supplements[index + 1 ..]) |later| {
            assert(entry.global_number != later.global_number);
        }
    }

    for (field_supplements, 0..) |entry, index| {
        assert(entry.name.len > 0);
        assert(entry.scale != 0.0);
        assert(std.math.isFinite(entry.scale));
        assert(std.math.isFinite(entry.offset));

        for (field_supplements[index + 1 ..]) |later| {
            if (entry.global_number != later.global_number) continue;

            assert(entry.field_number != later.field_number);
        }
    }
}

pub fn channel_233(field2: []const u8) ?Channel233 {
    if (field2.len != channel_field_bytes) return null;

    const packed_value = std.mem.readInt(u32, field2[0..channel_field_bytes], .little);
    const id: u8 = @intCast(packed_value >> channel_id_shift);
    const value = packed_value & channel_value_mask;

    assert((@as(u32, id) << channel_id_shift) | value == packed_value);

    return .{ .id = id, .value = value };
}

fn plain_field(
    global_number: u16,
    field_number: u8,
    name: []const u8,
    units: []const u8,
    evidence: Evidence,
) FieldSupplement {
    return .{
        .global_number = global_number,
        .field_number = field_number,
        .name = name,
        .fit_type = "",
        .units = units,
        .scale = 1.0,
        .offset = 0.0,
        .evidence = evidence,
    };
}

fn scaled_field(
    global_number: u16,
    field_number: u8,
    name: []const u8,
    units: []const u8,
    scale: f64,
    evidence: Evidence,
) FieldSupplement {
    return .{
        .global_number = global_number,
        .field_number = field_number,
        .name = name,
        .fit_type = "",
        .units = units,
        .scale = scale,
        .offset = 0.0,
        .evidence = evidence,
    };
}

fn time_field(
    global_number: u16,
    field_number: u8,
    name: []const u8,
    evidence: Evidence,
) FieldSupplement {
    return .{
        .global_number = global_number,
        .field_number = field_number,
        .name = name,
        .fit_type = date_time_type,
        .units = "",
        .scale = 1.0,
        .offset = 0.0,
        .evidence = evidence,
    };
}

pub fn message_name(global_number: u16) ?[]const u8 {
    for (message_supplements) |entry| {
        if (entry.global_number == global_number) return entry.name;
    }

    return null;
}

pub fn field_supplement(global_number: u16, field_number: u8) ?*const FieldSupplement {
    for (&field_supplements) |*entry| {
        if (entry.global_number != global_number) continue;
        if (entry.field_number != field_number) continue;

        return entry;
    }

    return null;
}

test "channel_233 splits the multiplexed field" {
    const sample = channel_233(&[_]u8{ 0xA2, 0x00, 0x00, 0x18 }).?;

    try std.testing.expectEqual(@as(u8, 3), sample.id);
    try std.testing.expectEqual(@as(u32, 162), sample.value);

    const zero = channel_233(&[_]u8{ 0x00, 0x00, 0x00, 0x40 }).?;

    try std.testing.expectEqual(@as(u8, 8), zero.id);
    try std.testing.expectEqual(@as(u32, 0), zero.value);

    try std.testing.expect(channel_233(&[_]u8{ 1, 2, 3 }) == null);
}

test "message_name covers only the messages the profile omits" {
    try std.testing.expectEqualStrings("device_status", message_name(104).?);
    try std.testing.expectEqualStrings("cpe_status", message_name(394).?);
    try std.testing.expectEqualStrings("user_metrics", message_name(79).?);
    try std.testing.expectEqualStrings("gnss_status", message_name(325).?);

    try std.testing.expect(message_name(20) == null);
    try std.testing.expect(message_name(19) == null);
    try std.testing.expect(message_name(327) == null);
}

test "field_supplement carries the recovered scale and units" {
    const voltage = field_supplement(104, 0).?;

    try std.testing.expectEqualStrings("battery_voltage", voltage.name);
    try std.testing.expectEqualStrings("V", voltage.units);
    try std.testing.expectEqual(@as(f64, 1000.0), voltage.scale);

    try std.testing.expectApproxEqAbs(@as(f64, 4.33), 4330.0 / voltage.scale, 1e-9);

    const vo2 = field_supplement(79, 0).?;

    try std.testing.expectEqualStrings("vo2_max", vo2.name);
    try std.testing.expectApproxEqAbs(@as(f64, 37.43), 10952.0 / vo2.scale, 0.01);
}

test "ambient_conditions carries temperature and humidity" {
    try std.testing.expectEqualStrings("ambient_conditions", message_name(288).?);

    const temperature = field_supplement(288, 0).?;

    try std.testing.expectEqualStrings("temperature", temperature.name);
    try std.testing.expectEqualStrings("C", temperature.units);
    try std.testing.expectEqual(@as(f64, 1.0), temperature.scale);

    const humidity = field_supplement(288, 1).?;

    try std.testing.expectEqualStrings("humidity", humidity.name);
    try std.testing.expectEqualStrings("percent", humidity.units);

    try std.testing.expect(field_supplement(288, 2) == null);
}

test "gnss_status names only the state field" {
    try std.testing.expectEqualStrings("gnss_status", message_name(325).?);

    const state = field_supplement(325, 2).?;

    try std.testing.expectEqualStrings("solution_state", state.name);
    try std.testing.expectEqual(@as(f64, 1.0), state.scale);
    try std.testing.expect(state.evidence == .measured);

    try std.testing.expect(field_supplement(325, 0) == null);
    try std.testing.expect(field_supplement(325, 1) == null);
    try std.testing.expect(field_supplement(325, 3) == null);
    try std.testing.expect(field_supplement(325, 4) == null);
    try std.testing.expect(field_supplement(325, 5) == null);
}

test "field_supplement leaves fields the profile already names alone" {
    try std.testing.expect(field_supplement(20, 3) == null);

    try std.testing.expect(field_supplement(327, 0) == null);
}

test "supplement tables agree with themselves" {
    for (field_supplements) |entry| {
        const described = profile.message_info(entry.global_number) != null or
            message_name(entry.global_number) != null;

        try std.testing.expect(described);
        try std.testing.expect(entry.name.len > 0);
        try std.testing.expect(entry.scale != 0.0);
    }
}
