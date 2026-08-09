const std = @import("std");

const assert = std.debug.assert;

const Steps = struct {
    check: *std.Build.Step,
    ci: *std.Build.Step,
    fuzz: *std.Build.Step,
    fuzz_build: *std.Build.Step,
    fuzz_smoke: *std.Build.Step,
    profile: *std.Build.Step,
    run: *std.Build.Step,
    test_all: *std.Build.Step,
    test_fmt: *std.Build.Step,
    test_unit: *std.Build.Step,
};

const format_paths = [_][]const u8{ "build.zig", "src", "tools" };

const workbook_path = "tools/Profile.xlsx";

const types_path = "src/profile/types.zig";
const messages_path = "src/profile/messages.zig";

comptime {
    assert(format_paths.len > 0);
    assert(std.mem.endsWith(u8, workbook_path, ".xlsx"));
    assert(std.mem.endsWith(u8, types_path, ".zig"));
    assert(std.mem.endsWith(u8, messages_path, ".zig"));
    assert(!std.mem.eql(u8, types_path, messages_path));
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const steps = Steps{
        .check = b.step("check", "Compile every artifact without running it"),
        .ci = b.step("ci", "Run formatting, compilation, unit tests, and fuzzer smoke"),
        .fuzz = b.step("fuzz", "Run a fuzzer: -- <fuzzer> [seed] [events]"),
        .fuzz_build = b.step("fuzz:build", "Compile the fuzzer without running it"),
        .fuzz_smoke = b.step("fuzz:smoke", "Run every fuzzer briefly with a fixed seed"),
        .profile = b.step("profile", "Regenerate src/profile/ from " ++ workbook_path),
        .run = b.step("run", "Run the FIT dump CLI"),
        .test_all = b.step("test", "Run every test suite and the formatting check"),
        .test_fmt = b.step("test:fmt", "Check that every source file is formatted"),
        .test_unit = b.step("test:unit", "Run the colocated unit tests and the tidy law"),
    };

    const module = b.addModule("zfit", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const generator = add_generator(b, &steps, optimize);

    add_format(b, &steps);
    add_cli(b, &steps, module, target, optimize);
    add_fuzz(b, &steps, target, optimize);
    add_profile(b, &steps, generator);
    add_unit_tests(b, &steps, module, generator, target, optimize);

    steps.ci.dependOn(steps.test_fmt);
    steps.ci.dependOn(steps.check);
    steps.ci.dependOn(steps.test_unit);
    steps.ci.dependOn(steps.fuzz_smoke);

    b.default_step.dependOn(steps.check);
}

fn add_format(b: *std.Build, steps: *const Steps) void {
    const fmt = b.addFmt(.{
        .paths = &format_paths,
        .check = true,
    });

    steps.test_fmt.dependOn(&fmt.step);
    steps.test_all.dependOn(&fmt.step);
}

fn add_cli(
    b: *std.Build,
    steps: *const Steps,
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const exe = b.addExecutable(.{
        .name = "zfit",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zfit", .module = module }},
        }),
    });

    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);

    run.step.dependOn(b.getInstallStep());

    if (b.args) |args| run.addArgs(args);

    steps.run.dependOn(&run.step);
    steps.check.dependOn(&exe.step);
}

fn add_fuzz(
    b: *std.Build,
    steps: *const Steps,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const exe = b.addExecutable(.{
        .name = "fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fuzz_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run = b.addRunArtifact(exe);

    if (b.args) |args| run.addArgs(args);

    const smoke = b.addRunArtifact(exe);

    smoke.addArg("smoke");

    steps.fuzz.dependOn(&run.step);
    steps.fuzz_build.dependOn(&exe.step);
    steps.fuzz_smoke.dependOn(&smoke.step);
    steps.check.dependOn(&exe.step);
}

fn add_generator(
    b: *std.Build,
    steps: *const Steps,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = "generate_profile",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/generate_profile.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });

    steps.check.dependOn(&exe.step);

    return exe;
}

fn add_profile(b: *std.Build, steps: *const Steps, generator: *std.Build.Step.Compile) void {
    const generate = b.addRunArtifact(generator);

    generate.stdio = .inherit;
    generate.addFileArg(b.path(workbook_path));

    const types_zig = generate.addOutputFileArg("types.zig");
    const messages_zig = generate.addOutputFileArg("messages.zig");

    const update = b.addUpdateSourceFiles();

    update.addCopyFileToSource(types_zig, types_path);
    update.addCopyFileToSource(messages_zig, messages_path);

    steps.profile.dependOn(&update.step);
}

fn add_unit_tests(
    b: *std.Build,
    steps: *const Steps,
    module: *std.Build.Module,
    generator: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const check_profile = b.addRunArtifact(generator);

    check_profile.stdio = .inherit;
    check_profile.addArg("--check");
    check_profile.addFileArg(b.path(workbook_path));
    check_profile.addFileArg(b.path(types_path));
    check_profile.addFileArg(b.path(messages_path));

    const unit = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/unit_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = b.args orelse &.{},
    });

    const tools = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/profile_gen/unit_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zfit", .module = module }},
        }),
        .filters = b.args orelse &.{},
    });

    const run_unit = b.addRunArtifact(unit);
    const run_tools = b.addRunArtifact(tools);

    steps.test_unit.dependOn(&run_unit.step);
    steps.test_unit.dependOn(&run_tools.step);
    steps.test_unit.dependOn(&check_profile.step);

    steps.test_all.dependOn(&run_unit.step);
    steps.test_all.dependOn(&run_tools.step);
    steps.test_all.dependOn(&check_profile.step);

    steps.check.dependOn(&unit.step);
    steps.check.dependOn(&tools.step);
}
