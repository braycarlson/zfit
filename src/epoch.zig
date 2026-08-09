const std = @import("std");

const assert = std.debug.assert;

pub const unix_offset_seconds = 631065600;

comptime {
    assert(@as(i64, std.math.maxInt(u32)) + unix_offset_seconds < std.math.maxInt(i64));
}

pub fn to_unix_seconds(fit_seconds: u32) i64 {
    const unix = @as(i64, fit_seconds) + unix_offset_seconds;

    assert(unix >= unix_offset_seconds);

    return unix;
}
