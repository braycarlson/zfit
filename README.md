<p align="center">
    <picture>
        <source media="(prefers-color-scheme: dark)" srcset="assets/zfit-wordmark-on-dark.svg">
        <source media="(prefers-color-scheme: light)" srcset="assets/zfit-wordmark-on-light.svg">
        <img alt="zfit" src="assets/zfit-wordmark-on-light.svg" width="250">
    </picture>
</p>

&nbsp;

<p align="center">
    A decoder and encoder for the FIT file format used by Garmin and other fitness devices.
</p>

<p align="center">
    <a href="https://github.com/braycarlson/zfit/actions/workflows/ci.yml"><img alt="ci" src="https://img.shields.io/github/actions/workflow/status/braycarlson/zfit/ci.yml?branch=main&amp;style=flat-square&amp;label=ci"></a>
    <a href="https://ziglang.org"><img alt="zig" src="https://img.shields.io/badge/zig-0.16.0-orange.svg?style=flat-square"></a>
    <a href="LICENSE"><img alt="license" src="https://img.shields.io/badge/license-MIT-blue.svg?style=flat-square"></a>
</p>

## Overview

A FIT file is a binary container whose field meanings live in a profile shipped apart from
it, so the work is resolution rather than parsing. A field arrives from the decoder with
its name, units, and value already resolved.

## Features

- **Profile resolution**: The name, units, scale, and enum values come from the FIT
  profile, which covers 123 messages and 197 types.
- **Field expansion**: The decoder expands components, accumulators, subfields, and
  developer fields.
- **Garmin supplements**: The undocumented messages and fields carry names, including the
  channels packed into message 233.
- **Chained files**: The decoder follows each segment to the end of the file.
- **Encoding**: An encoder writes messages and closes the file with its CRC.
- **Command line**: The dump, JSON, CSV, and channel exports ship in one binary.
- **Dependencies**: There are none outside the Zig toolchain.

## Install

The library ships as a Zig package holding one module, also named `zfit`. Fetch it into
your own project and import the module in your `build.zig`.

```
zig fetch --save git+https://github.com/braycarlson/zfit
```

```zig
const zfit = b.dependency("zfit", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("zfit", zfit.module("zfit"));
```

zfit requires Zig 0.16.0.

## Decoding

A `Stream` reads one message at a time and builds it in an arena the caller passes in, so
resetting that arena on each iteration holds the peak allocation to a single message. A
scalar holding the invalid sentinel for its base type decodes to `.none`.

```zig
const std = @import("std");

const zfit = @import("zfit");

pub fn print_heart_rate(gpa: std.mem.Allocator, bytes: []const u8) !void {
    try zfit.verify_checksum(bytes);

    var reader = std.Io.Reader.fixed(bytes);
    var decoder = try zfit.Decoder.init(&reader);

    var stream = zfit.Stream.init(&decoder, gpa);
    defer stream.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var count: u32 = 0;

    while (count < zfit.Decoder.message_count_max) : (count += 1) {
        _ = arena.reset(.retain_capacity);

        const message = (try stream.next(arena.allocator())) orelse break;

        if (message.global_number != 20) continue;

        for (message.fields) |field| {
            if (!std.mem.eql(u8, field.name, "heart_rate")) continue;
            if (field.value != .unsigned) continue;

            std.debug.print("{d} {s}\n", .{ field.value.unsigned, field.units });
        }
    }
}
```

## Encoding

The encoder buffers messages and writes the header, body, and trailing CRC on `finish`.
The numbers are the profile's, so 0 is `file_id`, 20 is `record`, and 253 is the
timestamp field on any message.

```zig
pub fn write_activity(gpa: std.mem.Allocator, out: *std.Io.Writer) !void {
    var encoder = zfit.Encoder.init(gpa);
    defer encoder.deinit();

    try encoder.message(0, &.{
        .{ .number = 0, .value = .{ .enum_value = 4 } },
        .{ .number = 1, .value = .{ .uint16 = 1 } },
    });

    try encoder.message(20, &.{
        .{ .number = 253, .value = .{ .uint32 = 1_000_000_000 } },
        .{ .number = 3, .value = .{ .uint8 = 120 } },
    });

    try encoder.finish(out);
}
```

## Command Line

The same decoder backs a command line tool, run through `just run` in a checkout. Each
mode takes the file first and the mode flag after it.

| Command | Output |
|---|---|
| `just run <file>` | The header summary, the first message of each type, and a count per type. |
| `just run <file> --json` | A JSON object per message. |
| `just run <file> --csv [global]` | A row per message of one type, `record` by default. |
| `just run <file> --ch233` | The channel samples packed into message 233. |

```console
$ just run activity.fit
zig build run -- activity.fit
file:     activity.fit
size:     4561 bytes
protocol: 2.0
profile:  0
crc:      ok

[file_id]  global 0
  type                       = activity
  manufacturer               = garmin
  time_created               = 2025-01-01 00:00:00 UTC

[record]  global 20  @ 2025-01-01 00:00:00 UTC
  timestamp                  = 2025-01-01 00:00:00 UTC
  heart_rate                 = 138 bpm
  cadence                    = 82 rpm
  distance                   = 0.000 m
  speed                      = 3.050 m/s
  enhanced_speed             = 3.050 m/s
  altitude                   = 548.000 m
  enhanced_altitude          = 548.000 m

messages by type (desc):
  record                        300  (global 20)
  file_id                         1  (global 0)

total: 301 messages across 2 types
```

## Development

The recipes below wrap `zig build`, and a bare `just` lists them all. The tidy law is a
test rather than a separate linter, so the mechanical rules run with everything else.

| Command | What it runs |
|---|---|
| `just ci` | The formatting check, compilation, the unit tests, and the fuzzer smoke run. |
| `just test` | Each test suite and the formatting check. |
| `just tidy` | The tidy law on its own. |
| `just fuzz <name> [seed] [events]` | The named fuzzer: `decoder`, `round_trip`, `canary`, or `smoke`. |
| `just profile` | The regeneration of `src/profile/` from `tools/Profile.xlsx`. |

## Licence

MIT. See [LICENSE](LICENSE).
