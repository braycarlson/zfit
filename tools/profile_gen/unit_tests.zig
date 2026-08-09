const std = @import("std");

const zfit = @import("zfit");
const model = @import("model.zig");

fn expect_same_shape(comptime Generated: type, comptime Runtime: type) !void {
    const generated = @typeInfo(Generated).@"struct".fields;
    const runtime = @typeInfo(Runtime).@"struct".fields;

    try std.testing.expectEqual(runtime.len, generated.len);
    inline for (generated, runtime) |left, right| {
        try std.testing.expectEqualStrings(right.name, left.name);
    }
}

test {
    _ = @import("model.zig");
    _ = @import("render.zig");
    _ = @import("sheets.zig");
    _ = @import("xlsx.zig");
    _ = @import("xml.zig");
}

test "the model mirrors the runtime profile structs field for field" {
    try expect_same_shape(model.FieldInfo, zfit.profile.FieldInfo);
    try expect_same_shape(model.SubField, zfit.profile.SubField);
    try expect_same_shape(model.Component, zfit.profile.Component);
}
