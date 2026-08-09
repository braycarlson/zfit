const std = @import("std");

const xml = @import("xml.zig");

const Allocator = std.mem.Allocator;
const CentralDirectoryFileHeader = std.zip.CentralDirectoryFileHeader;
const CompressionMethod = std.zip.CompressionMethod;
const EndRecord = std.zip.EndRecord;
const LocalFileHeader = std.zip.LocalFileHeader;
const Reader = std.Io.Reader;
const assert = std.debug.assert;

pub const ArchiveError = Allocator.Error || error{
    MalformedArchive,
    UnsupportedArchive,
    EntryNotFound,
    ChecksumMismatch,
};

pub const SheetError = ArchiveError || xml.DecodeError || error{
    MalformedSheet,
    SheetNotFound,
};

pub const Row = []const []const u8;

pub const Member = struct {
    name: []const u8,
    compression_method: CompressionMethod,
    compressed_size: u32,
    uncompressed_size: u32,
    crc32: u32,
    local_header_offset: u32,
};

pub const Archive = struct {
    bytes: []const u8,
    members: []const Member,

    pub fn open(arena: Allocator, bytes: []const u8) ArchiveError!Archive {
        const end_record = try find_end_record(bytes);

        if (end_record.need_zip64()) return error.UnsupportedArchive;

        const members = try arena.alloc(Member, end_record.record_count_total);
        var offset: usize = end_record.central_directory_offset;

        for (members) |*member| {
            const before = offset;
            offset = try read_member(bytes, offset, member);

            assert(offset > before);
            assert(offset <= bytes.len);
        }

        assert(offset <= bytes.len);
        assert(members.len == end_record.record_count_total);

        return .{ .bytes = bytes, .members = members };
    }

    pub fn member_named(archive: *const Archive, name: []const u8) ?*const Member {
        assert(name.len > 0);

        for (archive.members) |*member| {
            assert(member.compressed_size <= archive.bytes.len);

            if (std.mem.eql(u8, member.name, name)) return member;
        }

        return null;
    }

    pub fn read(
        archive: *const Archive,
        arena: Allocator,
        name: []const u8,
    ) ArchiveError![]const u8 {
        assert(name.len > 0);

        const member = archive.member_named(name) orelse return error.EntryNotFound;

        if (member.uncompressed_size > member_bytes_max) return error.UnsupportedArchive;

        const compressed = try archive.member_bytes(member);

        const data = switch (member.compression_method) {
            .store => compressed,
            .deflate => try inflate(arena, compressed, member.uncompressed_size),
            else => return error.UnsupportedArchive,
        };

        if (data.len != member.uncompressed_size) return error.MalformedArchive;
        if (std.hash.Crc32.hash(data) != member.crc32) return error.ChecksumMismatch;

        assert(data.len <= member_bytes_max);

        return data;
    }

    fn member_bytes(archive: *const Archive, member: *const Member) ArchiveError![]const u8 {
        const offset: usize = member.local_header_offset;
        const header = try read_header(LocalFileHeader, archive.bytes, offset);

        if (!std.mem.eql(u8, &header.signature, &std.zip.local_file_header_sig)) {
            return error.MalformedArchive;
        }

        const start = offset + @sizeOf(LocalFileHeader) + header.filename_len + header.extra_len;
        const end = start + member.compressed_size;

        if (end > archive.bytes.len) return error.MalformedArchive;

        assert(start <= end);

        return archive.bytes[start..end];
    }
};

pub const Workbook = struct {
    archive: Archive,
    shared_strings: []const []const u8,
    sheets: []const Location,

    pub const Location = struct {
        name: []const u8,
        path: []const u8,
    };

    pub fn open(arena: Allocator, bytes: []const u8) SheetError!Workbook {
        const archive = try Archive.open(arena, bytes);
        const shared_strings = try load_shared_strings(arena, &archive);
        const sheets = try load_sheet_locations(arena, &archive);

        assert(bytes.len > 0);
        assert(sheets.len > 0);

        return .{ .archive = archive, .shared_strings = shared_strings, .sheets = sheets };
    }

    pub fn sheet_path(workbook: *const Workbook, name: []const u8) ?[]const u8 {
        assert(name.len > 0);
        assert(workbook.sheets.len > 0);

        for (workbook.sheets) |location| {
            assert(location.path.len > 0);

            if (std.mem.eql(u8, location.name, name)) return location.path;
        }

        return null;
    }

    pub fn read_sheet(
        workbook: *const Workbook,
        arena: Allocator,
        name: []const u8,
    ) SheetError![]const Row {
        assert(name.len > 0);

        const path = workbook.sheet_path(name) orelse return error.SheetNotFound;
        const source = try workbook.archive.read(arena, path);

        if (source.len > xml.event_count_max) return error.UnsupportedArchive;

        var builder = SheetBuilder{ .arena = arena, .shared_strings = workbook.shared_strings };
        var parser = xml.Parser.init(source);
        var events: u32 = 0;

        while (events < xml.event_count_max) : (events += 1) {
            const event = (try parser.next()) orelse break;

            try builder.consume(event);
        }

        assert(events < xml.event_count_max);
        assert(events <= source.len);
        assert(source.len > 0);
        assert(builder.state == .outside_cell);

        return builder.rows.items;
    }
};

const SheetBuilder = struct {
    arena: Allocator,
    shared_strings: []const []const u8,
    rows: std.ArrayList(Row) = .empty,
    cells: std.ArrayList(Cell) = .empty,
    text: std.ArrayList(u8) = .empty,
    column: u32 = 0,
    kind: Kind = .literal,
    state: State = .outside_cell,

    const State = enum { outside_cell, in_cell, capturing };

    const Kind = enum { literal, shared, inline_string };

    const Cell = struct {
        column: u32,
        text: []const u8,
    };

    fn consume(builder: *SheetBuilder, event: xml.Event) SheetError!void {
        assert(builder.column < column_count_max);

        switch (event) {
            .open => |element| try builder.open(element),
            .close => |name| try builder.close(xml.local(name)),
            .text => |raw| try builder.append_text(raw),
        }

        assert(builder.cells.items.len <= column_count_max);
    }

    fn open(builder: *SheetBuilder, element: xml.Element) SheetError!void {
        const name = element.local_name();

        assert(name.len > 0);

        if (std.mem.eql(u8, name, "row")) {
            builder.cells.clearRetainingCapacity();
            if (element.self_closing) try builder.finish_row();

            assert(builder.cells.items.len == 0);

            return;
        }

        if (std.mem.eql(u8, name, "c")) return try builder.start_cell(element);
        if (element.self_closing) return;
        if (builder.state != .in_cell) return;

        if (std.mem.eql(u8, name, "v")) builder.state = .capturing;
        if (std.mem.eql(u8, name, "t")) builder.state = .capturing;
    }

    fn close(builder: *SheetBuilder, name: []const u8) SheetError!void {
        assert(name.len > 0);

        if (std.mem.eql(u8, name, "v") or std.mem.eql(u8, name, "t")) {
            if (builder.state == .capturing) builder.state = .in_cell;

            assert(builder.state != .capturing);

            return;
        }

        if (std.mem.eql(u8, name, "c")) return try builder.finish_cell();
        if (std.mem.eql(u8, name, "row")) try builder.finish_row();
    }

    fn append_text(builder: *SheetBuilder, raw: []const u8) SheetError!void {
        if (builder.state != .capturing) return;

        assert(builder.state == .capturing);

        const decoded = try xml.decode(builder.arena, raw);

        assert(decoded.len <= raw.len);

        try builder.text.appendSlice(builder.arena, decoded);
    }

    fn start_cell(builder: *SheetBuilder, element: xml.Element) SheetError!void {
        const reference = (try element.attribute_local("r")) orelse return error.MalformedSheet;
        const kind = (try element.attribute_local("t")) orelse "";

        builder.column = try column_of(reference);
        builder.kind = if (std.mem.eql(u8, kind, "s"))
            .shared
        else if (std.mem.eql(u8, kind, "inlineStr"))
            .inline_string
        else
            .literal;

        builder.text.clearRetainingCapacity();
        builder.state = .in_cell;

        assert(builder.column < column_count_max);
        assert(builder.text.items.len == 0);

        if (element.self_closing) try builder.finish_cell();
    }

    fn finish_cell(builder: *SheetBuilder) SheetError!void {
        if (builder.state == .outside_cell) return;

        const raw = trim(builder.text.items);

        const resolved = switch (builder.kind) {
            .shared => try builder.shared_string(raw),
            .literal, .inline_string => try builder.arena.dupe(u8, raw),
        };

        builder.state = .outside_cell;

        if (builder.kind != .shared) assert(resolved.len <= raw.len);

        try builder.cells.append(builder.arena, .{ .column = builder.column, .text = resolved });
    }

    fn shared_string(builder: *const SheetBuilder, raw: []const u8) SheetError![]const u8 {
        if (raw.len == 0) return "";

        const index = std.fmt.parseInt(u32, raw, 10) catch return error.MalformedSheet;

        if (index >= builder.shared_strings.len) return error.MalformedSheet;

        assert(builder.shared_strings.len > 0);
        assert(index < builder.shared_strings.len);

        return trim(builder.shared_strings[index]);
    }

    fn finish_row(builder: *SheetBuilder) SheetError!void {
        var width: u32 = 0;

        for (builder.cells.items) |cell| {
            assert(cell.column < column_count_max);

            if (cell.column + 1 > width) width = cell.column + 1;
        }

        assert(width <= column_count_max);

        const row = try builder.arena.alloc([]const u8, width);
        @memset(row, "");

        for (builder.cells.items) |cell| {
            assert(cell.column < width);
            row[cell.column] = cell.text;
        }

        builder.cells.clearRetainingCapacity();
        builder.state = .outside_cell;

        try builder.rows.append(builder.arena, row);
    }
};

const SharedStringBuilder = struct {
    arena: Allocator,
    strings: std.ArrayList([]const u8) = .empty,
    text: std.ArrayList(u8) = .empty,
    in_item: bool = false,
    capturing: bool = false,

    fn consume(builder: *SharedStringBuilder, event: xml.Event) SheetError!void {
        if (builder.capturing) assert(builder.in_item);

        switch (event) {
            .open => |element| try builder.open(element),
            .close => |raw| try builder.close(xml.local(raw)),
            .text => |raw| try builder.append_text(raw),
        }

        if (builder.capturing) assert(builder.in_item);
    }

    fn open(builder: *SharedStringBuilder, element: xml.Element) SheetError!void {
        const name = element.local_name();

        assert(name.len > 0);

        if (std.mem.eql(u8, name, "si")) {
            builder.text.clearRetainingCapacity();
            builder.in_item = !element.self_closing;

            if (element.self_closing) try builder.strings.append(builder.arena, "");

            return;
        }

        if (!std.mem.eql(u8, name, "t")) return;
        if (!builder.in_item) return;

        builder.capturing = !element.self_closing;
    }

    fn close(builder: *SharedStringBuilder, name: []const u8) SheetError!void {
        assert(name.len > 0);

        if (std.mem.eql(u8, name, "t")) builder.capturing = false;
        if (!std.mem.eql(u8, name, "si")) return;
        if (!builder.in_item) return;

        const owned = try builder.arena.dupe(u8, builder.text.items);

        assert(owned.len == builder.text.items.len);

        try builder.strings.append(builder.arena, owned);

        builder.in_item = false;
    }

    fn append_text(builder: *SharedStringBuilder, raw: []const u8) SheetError!void {
        if (!builder.capturing) return;

        const decoded = try xml.decode(builder.arena, raw);

        assert(builder.in_item);
        assert(decoded.len <= raw.len);

        try builder.text.appendSlice(builder.arena, decoded);
    }
};

const Relationship = struct {
    id: []const u8,
    target: []const u8,
};

const FixtureEntry = struct {
    name: []const u8,
    data: []const u8,
};

const comment_bytes_max = std.math.maxInt(u16);

const member_bytes_max = 64 * 1024 * 1024;

const column_letters_max = 3;

const column_count_max = 26 * 26 * 26 + 26 * 26 + 26;

const shared_strings_path = "xl/sharedStrings.xml";
const workbook_path = "xl/workbook.xml";
const relationships_path = "xl/_rels/workbook.xml.rels";
const package_prefix = "xl/";

const whitespace_bytes = " \t\n\r\x0b\x0c";

comptime {
    assert(column_count_max == 18278);
    assert(member_bytes_max <= std.math.maxInt(u32));
    assert(std.mem.startsWith(u8, shared_strings_path, package_prefix));
    assert(std.mem.startsWith(u8, workbook_path, package_prefix));
    assert(std.mem.startsWith(u8, relationships_path, package_prefix));
}

const shared_strings_xml =
    \\<?xml version="1.0"?><x:sst xmlns:x="urn:main"><x:si><x:t>shared</x:t></x:si></x:sst>
;

const workbook_xml =
    \\<?xml version="1.0"?><x:workbook xmlns:x="urn:main" xmlns:r="urn:rel"><x:sheets>
    \\<x:sheet name="Types" sheetId="1" r:id="rId1" /></x:sheets></x:workbook>
;

const relationships_xml =
    \\<?xml version="1.0"?><Relationships xmlns="urn:rel">
    \\<Relationship Id="rId1" Target="worksheets/sheet1.xml" /></Relationships>
;

const sheet_xml =
    \\<?xml version="1.0"?><x:worksheet xmlns:x="urn:main"><x:sheetData>
    \\<x:row r="1"><x:c r="A1" t="s"><x:v>0</x:v></x:c><x:c r="B1" />
    \\<x:c r="C1"><x:v>42</x:v></x:c></x:row>
    \\<x:row r="2"><x:c r="B2" t="inlineStr">
    \\<x:is><x:t>  inline &amp; text  </x:t></x:is></x:c></x:row>
    \\<x:row r="3" />
    \\</x:sheetData></x:worksheet>
;

fn column_of(reference: []const u8) SheetError!u32 {
    if (reference.len == 0) return error.MalformedSheet;

    var index: u32 = 0;
    var letters: u32 = 0;

    for (reference) |byte| {
        const value = switch (byte) {
            'A'...'Z' => byte - 'A' + 1,
            'a'...'z' => byte - 'a' + 1,
            else => break,
        };

        assert(value >= 1);
        assert(value <= 26);

        index = index * 26 + value;
        letters += 1;
        if (letters > column_letters_max) return error.MalformedSheet;
    }

    if (letters == 0) return error.MalformedSheet;

    assert(letters >= 1);
    assert(letters <= column_letters_max);
    assert(index >= 1);
    assert(index <= column_count_max);

    return index - 1;
}

fn load_shared_strings(
    arena: Allocator,
    archive: *const Archive,
) SheetError![]const []const u8 {
    const source = archive.read(arena, shared_strings_path) catch |err| switch (err) {
        error.EntryNotFound => return &.{},
        else => return err,
    };

    if (source.len > xml.event_count_max) return error.UnsupportedArchive;

    var builder = SharedStringBuilder{ .arena = arena };
    var parser = xml.Parser.init(source);
    var events: u32 = 0;

    while (events < xml.event_count_max) : (events += 1) {
        const event = (try parser.next()) orelse break;

        try builder.consume(event);
    }

    assert(events < xml.event_count_max);
    assert(events <= source.len);
    assert(!builder.in_item);
    assert(!builder.capturing);

    return builder.strings.items;
}

fn load_sheet_locations(
    arena: Allocator,
    archive: *const Archive,
) SheetError![]const Workbook.Location {
    const relationships = try load_relationships(arena, archive);
    const source = try archive.read(arena, workbook_path);

    if (source.len > xml.event_count_max) return error.UnsupportedArchive;

    var locations: std.ArrayList(Workbook.Location) = .empty;
    var sheets = xml.ElementIterator.init(source, "sheet");
    var events: u32 = 0;

    while (events < xml.event_count_max) : (events += 1) {
        const element = (try sheets.next()) orelse break;

        const name = (try element.attribute_local("name")) orelse return error.MalformedArchive;
        const id = (try element.attribute_local("id")) orelse return error.MalformedArchive;
        const target = find_target(relationships, id) orelse return error.MalformedArchive;

        assert(name.len > 0);
        assert(target.len > 0);

        try locations.append(arena, .{
            .name = try xml.decode(arena, name),
            .path = try normalize_target(arena, target),
        });
    }

    if (locations.items.len == 0) return error.MalformedArchive;

    assert(events < xml.event_count_max);
    assert(locations.items.len > 0);
    assert(locations.items.len <= events);
    assert(source.len > 0);

    return locations.items;
}

fn load_relationships(
    arena: Allocator,
    archive: *const Archive,
) SheetError![]const Relationship {
    const source = try archive.read(arena, relationships_path);

    if (source.len > xml.event_count_max) return error.UnsupportedArchive;

    var relationships: std.ArrayList(Relationship) = .empty;
    var elements = xml.ElementIterator.init(source, "Relationship");
    var events: u32 = 0;

    while (events < xml.event_count_max) : (events += 1) {
        const element = (try elements.next()) orelse break;

        const id = (try element.attribute_local("Id")) orelse return error.MalformedArchive;
        const raw = try element.attribute_local("Target");
        const target = raw orelse return error.MalformedArchive;

        assert(id.len > 0);
        assert(target.len > 0);

        try relationships.append(arena, .{
            .id = try xml.decode(arena, id),
            .target = try xml.decode(arena, target),
        });
    }

    assert(events < xml.event_count_max);
    assert(relationships.items.len > 0);
    assert(relationships.items.len <= events);
    assert(source.len > 0);

    return relationships.items;
}

fn find_target(relationships: []const Relationship, id: []const u8) ?[]const u8 {
    assert(id.len > 0);
    assert(relationships.len > 0);

    for (relationships) |relationship| {
        assert(relationship.id.len > 0);

        if (std.mem.eql(u8, relationship.id, id)) return relationship.target;
    }

    return null;
}

fn normalize_target(arena: Allocator, target: []const u8) SheetError![]const u8 {
    if (target.len == 0) return error.MalformedArchive;

    if (target[0] == '/') return std.mem.trimStart(u8, target, "/");
    if (std.mem.startsWith(u8, target, package_prefix)) return target;

    assert(target[0] != '/');
    assert(!std.mem.startsWith(u8, target, package_prefix));

    const path = try std.fmt.allocPrint(arena, package_prefix ++ "{s}", .{target});

    assert(path.len == target.len + package_prefix.len);
    assert(std.mem.startsWith(u8, path, package_prefix));

    return path;
}

fn read_member(bytes: []const u8, offset: usize, member: *Member) ArchiveError!usize {
    assert(offset < bytes.len);

    const header = try read_header(CentralDirectoryFileHeader, bytes, offset);

    if (!std.mem.eql(u8, &header.signature, &std.zip.central_file_header_sig)) {
        return error.MalformedArchive;
    }

    const name_start = offset + @sizeOf(CentralDirectoryFileHeader);
    const name_end = name_start + header.filename_len;

    if (name_end > bytes.len) return error.MalformedArchive;

    assert(name_start > offset);
    assert(name_end >= name_start);

    member.* = .{
        .name = bytes[name_start..name_end],
        .compression_method = header.compression_method,
        .compressed_size = header.compressed_size,
        .uncompressed_size = header.uncompressed_size,
        .crc32 = header.crc32,
        .local_header_offset = header.local_file_header_offset,
    };

    const next = name_end + header.extra_len + header.comment_len;

    if (next > bytes.len) return error.MalformedArchive;

    assert(next > offset);

    return next;
}

fn inflate(arena: Allocator, compressed: []const u8, size: u32) ArchiveError![]const u8 {
    assert(compressed.len > 0);
    assert(size <= member_bytes_max);

    const window = try arena.alloc(u8, std.compress.flate.max_window_len);
    defer arena.free(window);

    const out = try arena.alloc(u8, size);

    var input = Reader.fixed(compressed);
    var decompress = std.compress.flate.Decompress.init(&input, .raw, window);
    decompress.reader.readSliceAll(out) catch return error.MalformedArchive;

    assert(out.len == size);
    assert(window.len == std.compress.flate.max_window_len);

    return out;
}

fn read_header(comptime Header: type, bytes: []const u8, offset: usize) ArchiveError!Header {
    comptime assert(@typeInfo(Header).@"struct".layout == .@"extern");
    comptime assert(@sizeOf(Header) > 0);

    if (offset + @sizeOf(Header) > bytes.len) return error.MalformedArchive;

    assert(offset < bytes.len);
    assert(bytes.len - offset >= @sizeOf(Header));

    var reader = Reader.fixed(bytes[offset..]);

    return reader.takeStruct(Header, .little) catch error.MalformedArchive;
}

fn find_end_record(bytes: []const u8) ArchiveError!EndRecord {
    const size = @sizeOf(EndRecord);

    if (bytes.len < size) return error.MalformedArchive;

    const span = @min(bytes.len - size, comment_bytes_max);
    const start = bytes.len - size;

    assert(span <= comment_bytes_max);

    var back: usize = 0;

    while (back <= span) : (back += 1) {
        assert(back <= comment_bytes_max);

        const offset = start - back;
        const signature = bytes[offset..][0..std.zip.end_record_sig.len];

        if (!std.mem.eql(u8, signature, &std.zip.end_record_sig)) continue;

        assert(offset + size <= bytes.len);

        const record = try read_header(EndRecord, bytes, offset);

        if (offset + size + record.comment_len == bytes.len) return record;
    }

    assert(back == span + 1);

    return error.MalformedArchive;
}

fn trim(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, whitespace_bytes);

    assert(trimmed.len <= text.len);
    if (trimmed.len > 0) assert(std.mem.indexOfScalar(u8, whitespace_bytes, trimmed[0]) == null);

    return trimmed;
}

fn append_int(bytes: *std.ArrayList(u8), gpa: Allocator, comptime Int: type, value: Int) !void {
    var buffer: [@sizeOf(Int)]u8 = undefined;
    std.mem.writeInt(Int, &buffer, value, .little);

    try bytes.appendSlice(gpa, &buffer);
}

fn append_local_entry(bytes: *std.ArrayList(u8), gpa: Allocator, entry: FixtureEntry) !void {
    try bytes.appendSlice(gpa, "PK\x03\x04");
    try append_int(bytes, gpa, u16, 20);
    try append_int(bytes, gpa, u16, 0);
    try append_int(bytes, gpa, u16, 0);
    try append_int(bytes, gpa, u16, 0);
    try append_int(bytes, gpa, u16, 0);
    try append_int(bytes, gpa, u32, std.hash.Crc32.hash(entry.data));
    try append_int(bytes, gpa, u32, @intCast(entry.data.len));
    try append_int(bytes, gpa, u32, @intCast(entry.data.len));
    try append_int(bytes, gpa, u16, @intCast(entry.name.len));
    try append_int(bytes, gpa, u16, 0);

    try bytes.appendSlice(gpa, entry.name);
    try bytes.appendSlice(gpa, entry.data);
}

fn append_directory_entry(
    bytes: *std.ArrayList(u8),
    gpa: Allocator,
    entry: FixtureEntry,
    offset: u32,
) !void {
    try bytes.appendSlice(gpa, "PK\x01\x02");
    try append_int(bytes, gpa, u16, 20);
    try append_int(bytes, gpa, u16, 20);
    try append_int(bytes, gpa, u16, 0);
    try append_int(bytes, gpa, u16, 0);
    try append_int(bytes, gpa, u16, 0);
    try append_int(bytes, gpa, u16, 0);
    try append_int(bytes, gpa, u32, std.hash.Crc32.hash(entry.data));
    try append_int(bytes, gpa, u32, @intCast(entry.data.len));
    try append_int(bytes, gpa, u32, @intCast(entry.data.len));
    try append_int(bytes, gpa, u16, @intCast(entry.name.len));
    try append_int(bytes, gpa, u16, 0);
    try append_int(bytes, gpa, u16, 0);
    try append_int(bytes, gpa, u16, 0);
    try append_int(bytes, gpa, u16, 0);
    try append_int(bytes, gpa, u32, 0);
    try append_int(bytes, gpa, u32, offset);

    try bytes.appendSlice(gpa, entry.name);
}

fn build_archive(gpa: Allocator, entries: []const FixtureEntry) ![]const u8 {
    var bytes: std.ArrayList(u8) = .empty;
    var offsets: std.ArrayList(u32) = .empty;
    defer offsets.deinit(gpa);

    for (entries) |entry| {
        try offsets.append(gpa, @intCast(bytes.items.len));
        try append_local_entry(&bytes, gpa, entry);
    }

    const directory_start = bytes.items.len;

    for (entries, offsets.items) |entry, offset| {
        try append_directory_entry(&bytes, gpa, entry, offset);
    }

    const directory_size = bytes.items.len - directory_start;

    try bytes.appendSlice(gpa, "PK\x05\x06");
    try append_int(&bytes, gpa, u16, 0);
    try append_int(&bytes, gpa, u16, 0);
    try append_int(&bytes, gpa, u16, @intCast(entries.len));
    try append_int(&bytes, gpa, u16, @intCast(entries.len));
    try append_int(&bytes, gpa, u32, @intCast(directory_size));
    try append_int(&bytes, gpa, u32, @intCast(directory_start));
    try append_int(&bytes, gpa, u16, 0);

    return bytes.items;
}

fn build_workbook_archive(gpa: Allocator) ![]const u8 {
    return try build_archive(gpa, &.{
        .{ .name = "xl/workbook.xml", .data = workbook_xml },
        .{ .name = "xl/_rels/workbook.xml.rels", .data = relationships_xml },
        .{ .name = "xl/sharedStrings.xml", .data = shared_strings_xml },
        .{ .name = "xl/worksheets/sheet1.xml", .data = sheet_xml },
    });
}

test "an archive indexes every member once and reads them by name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const archive = try Archive.open(arena, try build_workbook_archive(arena));

    try std.testing.expectEqual(@as(usize, 4), archive.members.len);
    try std.testing.expectEqualStrings("xl/workbook.xml", archive.members[0].name);
    try std.testing.expect(archive.member_named("xl/nope.xml") == null);

    const found = try archive.read(arena, "xl/sharedStrings.xml");

    try std.testing.expectEqualStrings(shared_strings_xml, found);

    try std.testing.expectError(error.EntryNotFound, archive.read(arena, "xl/nope.xml"));
}

test "reading a member whose contents do not match its checksum is an error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const bytes = try build_archive(arena, &.{.{ .name = "a.txt", .data = "payload" }});

    const corrupt = try arena.dupe(u8, bytes);
    const payload = std.mem.indexOf(u8, corrupt, "payload").?;
    corrupt[payload] = 'X';

    const archive = try Archive.open(arena, corrupt);

    try std.testing.expectError(error.ChecksumMismatch, archive.read(arena, "a.txt"));
}

test "an archive with no end record is rejected" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();

    const not_a_zip = Archive.open(arena, "not a zip at all");
    const empty = Archive.open(arena, "");

    try std.testing.expectError(error.MalformedArchive, not_a_zip);
    try std.testing.expectError(error.MalformedArchive, empty);
}

test "workbook resolves a sheet by name through its relationship" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const workbook = try Workbook.open(arena, try build_workbook_archive(arena));

    try std.testing.expectEqual(@as(usize, 1), workbook.shared_strings.len);
    try std.testing.expectEqualStrings("shared", workbook.shared_strings[0]);
    try std.testing.expectEqualStrings("xl/worksheets/sheet1.xml", workbook.sheet_path("Types").?);
    try std.testing.expect(workbook.sheet_path("Messages") == null);
}

test "sheet rows are dense up to the last populated cell" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const workbook = try Workbook.open(arena, try build_workbook_archive(arena));
    const rows = try workbook.read_sheet(arena, "Types");

    try std.testing.expectEqual(@as(usize, 3), rows.len);

    try std.testing.expectEqual(@as(usize, 3), rows[0].len);
    try std.testing.expectEqualStrings("shared", rows[0][0]);
    try std.testing.expectEqualStrings("", rows[0][1]);
    try std.testing.expectEqualStrings("42", rows[0][2]);

    try std.testing.expectEqual(@as(usize, 2), rows[1].len);
    try std.testing.expectEqualStrings("", rows[1][0]);
    try std.testing.expectEqualStrings("inline & text", rows[1][1]);

    try std.testing.expectEqual(@as(usize, 0), rows[2].len);
}

test "reading an absent sheet is an error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const workbook = try Workbook.open(arena, try build_workbook_archive(arena));

    try std.testing.expectError(error.SheetNotFound, workbook.read_sheet(arena, "Messages"));
}
