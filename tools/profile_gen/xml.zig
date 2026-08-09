const std = @import("std");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const Error = error{
    MalformedXml,
    UnsupportedMarkup,
    UnsupportedEntity,
};

pub const DecodeError = Error || Allocator.Error;

pub const Attribute = struct {
    name: []const u8,
    value: []const u8,
};

pub const Element = struct {
    name: []const u8,
    attributes: []const u8,
    self_closing: bool,

    pub fn local_name(element: Element) []const u8 {
        assert(element.name.len > 0);

        return local(element.name);
    }

    pub fn attribute(element: Element, name: []const u8) Error!?[]const u8 {
        assert(name.len > 0);
        assert(element.name.len > 0);

        var attributes = element.iterator();

        while (try attributes.next()) |found| {
            assert(found.name.len > 0);

            if (std.mem.eql(u8, found.name, name)) return found.value;
        }

        return null;
    }

    pub fn attribute_local(element: Element, name: []const u8) Error!?[]const u8 {
        assert(name.len > 0);
        assert(std.mem.indexOfScalar(u8, name, ':') == null);

        var attributes = element.iterator();

        while (try attributes.next()) |found| {
            assert(found.name.len > 0);

            if (std.mem.eql(u8, local(found.name), name)) return found.value;
        }

        return null;
    }

    pub fn iterator(element: Element) AttributeIterator {
        assert(element.name.len > 0);

        return .{ .source = element.attributes, .index = 0 };
    }
};

pub const AttributeIterator = struct {
    source: []const u8,
    index: usize,

    pub fn next(iterator: *AttributeIterator) Error!?Attribute {
        const source = iterator.source;

        iterator.index = skip_space(source, iterator.index);
        if (iterator.index >= source.len) return null;

        const name_start = iterator.index;

        while (iterator.index < source.len) : (iterator.index += 1) {
            const byte = source[iterator.index];

            if (is_space(byte) or byte == '=') break;
        }

        const name = source[name_start..iterator.index];

        if (name.len == 0) return error.MalformedXml;

        assert(iterator.index > name_start);
        assert(iterator.index <= source.len);

        iterator.index = skip_space(source, iterator.index);
        if (iterator.index >= source.len) return error.MalformedXml;
        if (source[iterator.index] != '=') return error.MalformedXml;
        iterator.index += 1;

        iterator.index = skip_space(source, iterator.index);
        if (iterator.index >= source.len) return error.MalformedXml;

        const quote = source[iterator.index];

        switch (quote) {
            '"', '\'' => {},
            else => return error.MalformedXml,
        }

        iterator.index += 1;

        const value_start = iterator.index;
        const value_end = std.mem.indexOfScalarPos(u8, source, value_start, quote) orelse
            return error.MalformedXml;

        iterator.index = value_end + 1;

        assert(iterator.index <= source.len);
        assert(value_start <= value_end);
        assert(source[value_end] == quote);
        assert(name.len >= 1);

        return .{ .name = name, .value = source[value_start..value_end] };
    }
};

pub const Event = union(enum) {
    open: Element,
    close: []const u8,
    text: []const u8,
};

pub const Parser = struct {
    source: []const u8,
    index: usize,

    pub fn init(source: []const u8) Parser {
        assert(source.len <= event_count_max);

        return .{ .source = source, .index = 0 };
    }

    pub fn next(parser: *Parser) Error!?Event {
        while (parser.index < parser.source.len) {
            const before = parser.index;

            if (parser.source[parser.index] != '<') return try parser.take_text();
            if (parser.starts_with("</")) return try parser.take_close();
            if (parser.starts_with("<![CDATA[")) return error.UnsupportedMarkup;

            if (parser.starts_with("<?")) {
                try parser.skip_past("?>");
            } else if (parser.starts_with("<!--")) {
                try parser.skip_past("-->");
            } else if (parser.starts_with("<!")) {
                try parser.skip_past(">");
            } else {
                return try parser.take_open();
            }

            assert(parser.index > before);
        }

        assert(parser.index == parser.source.len);

        return null;
    }

    fn take_open(parser: *Parser) Error!Event {
        assert(parser.source[parser.index] == '<');

        const end = find_tag_end(parser.source, parser.index) orelse return error.MalformedXml;
        const body = parser.source[parser.index + 1 .. end];
        parser.index = end + 1;
        if (body.len == 0) return error.MalformedXml;

        const self_closing = body[body.len - 1] == '/';
        const inner = if (self_closing) body[0 .. body.len - 1] else body;
        const name_end = index_of_space(inner) orelse inner.len;
        const name = inner[0..name_end];

        if (name.len == 0) return error.MalformedXml;

        assert(parser.index > end - 1);
        assert(parser.index <= parser.source.len);
        assert(name_end <= inner.len);

        return .{ .open = .{
            .name = name,
            .attributes = inner[name_end..],
            .self_closing = self_closing,
        } };
    }

    fn take_close(parser: *Parser) Error!Event {
        assert(parser.starts_with("</"));

        const end = find_tag_end(parser.source, parser.index) orelse return error.MalformedXml;
        const name = trim_space(parser.source[parser.index + 2 .. end]);
        parser.index = end + 1;
        if (name.len == 0) return error.MalformedXml;

        assert(parser.index > end);
        assert(parser.index <= parser.source.len);

        return .{ .close = name };
    }

    fn take_text(parser: *Parser) Error!Event {
        assert(parser.source[parser.index] != '<');

        const start = parser.index;
        const found = std.mem.indexOfScalarPos(u8, parser.source, start, '<');
        const end = found orelse parser.source.len;
        parser.index = end;

        assert(parser.index > start);
        assert(parser.index <= parser.source.len);

        return .{ .text = parser.source[start..end] };
    }

    fn skip_past(parser: *Parser, terminator: []const u8) Error!void {
        assert(terminator.len > 0);

        const before = parser.index;

        const found = std.mem.indexOfPos(u8, parser.source, parser.index, terminator) orelse
            return error.MalformedXml;

        parser.index = found + terminator.len;

        assert(parser.index > before);
        assert(parser.index <= parser.source.len);
    }

    fn starts_with(parser: *const Parser, prefix: []const u8) bool {
        assert(prefix.len > 0);
        assert(parser.index <= parser.source.len);

        if (parser.index + prefix.len > parser.source.len) return false;

        return std.mem.eql(u8, parser.source[parser.index..][0..prefix.len], prefix);
    }
};

pub const ElementIterator = struct {
    parser: Parser,
    name: []const u8,

    pub fn init(source: []const u8, name: []const u8) ElementIterator {
        assert(name.len > 0);
        assert(source.len <= event_count_max);

        return .{ .parser = Parser.init(source), .name = name };
    }

    pub fn next(iterator: *ElementIterator) Error!?Element {
        while (try iterator.parser.next()) |event| {
            assert(iterator.parser.index <= iterator.parser.source.len);

            const element = switch (event) {
                .open => |open| open,
                .close, .text => continue,
            };

            if (std.mem.eql(u8, element.local_name(), iterator.name)) return element;
        }

        assert(iterator.parser.index == iterator.parser.source.len);

        return null;
    }
};

pub const event_count_max = 64 * 1024 * 1024;

comptime {
    assert(event_count_max > 0);
    assert(event_count_max <= std.math.maxInt(u32));
}

const space_bytes = " \t\n\r";

const utf8_bytes_max = 4;

comptime {
    assert(space_bytes.len == 4);
    assert(utf8_bytes_max == 4);
}

pub fn decode(arena: Allocator, raw: []const u8) DecodeError![]const u8 {
    if (std.mem.indexOfScalar(u8, raw, '&') == null) return raw;

    var out: std.ArrayList(u8) = .empty;

    try out.ensureTotalCapacity(arena, raw.len);

    var index: usize = 0;

    while (index < raw.len) {
        const before = index;
        const byte = raw[index];

        if (byte != '&') {
            out.appendAssumeCapacity(byte);
            index += 1;
            continue;
        }

        const end = std.mem.indexOfScalarPos(u8, raw, index, ';') orelse
            return error.UnsupportedEntity;

        try append_entity(&out, arena, raw[index + 1 .. end]);
        index = end + 1;

        assert(index > before);
        assert(index <= raw.len);
    }

    assert(index == raw.len);
    assert(out.items.len <= raw.len);

    return try out.toOwnedSlice(arena);
}

pub fn local(name: []const u8) []const u8 {
    assert(name.len > 0);

    const colon = std.mem.indexOfScalar(u8, name, ':') orelse return name;
    assert(colon < name.len);

    return name[colon + 1 ..];
}

fn append_entity(out: *std.ArrayList(u8), arena: Allocator, name: []const u8) DecodeError!void {
    if (name.len == 0) return error.UnsupportedEntity;

    if (std.mem.eql(u8, name, "amp")) return out.append(arena, '&');
    if (std.mem.eql(u8, name, "lt")) return out.append(arena, '<');
    if (std.mem.eql(u8, name, "gt")) return out.append(arena, '>');
    if (std.mem.eql(u8, name, "quot")) return out.append(arena, '"');
    if (std.mem.eql(u8, name, "apos")) return out.append(arena, '\'');

    if (name[0] != '#') return error.UnsupportedEntity;

    const hex = name.len > 1 and (name[1] == 'x' or name[1] == 'X');
    const digits = if (hex) name[2..] else name[1..];
    const base: u8 = if (hex) 16 else 10;

    if (digits.len == 0) return error.UnsupportedEntity;

    assert(base == 10 or base == 16);
    assert(digits.len < name.len);

    const point = std.fmt.parseInt(u21, digits, base) catch return error.UnsupportedEntity;

    var encoded: [utf8_bytes_max]u8 = undefined;
    const length = std.unicode.utf8Encode(point, &encoded) catch return error.UnsupportedEntity;

    assert(length >= 1);
    assert(length <= encoded.len);

    return out.appendSlice(arena, encoded[0..length]);
}

fn find_tag_end(source: []const u8, start: usize) ?usize {
    assert(start < source.len);
    assert(source[start] == '<');

    var quote: u8 = 0;
    var index = start;

    while (index < source.len) : (index += 1) {
        const byte = source[index];

        if (quote != 0) {
            if (byte == quote) quote = 0;
            continue;
        }

        if (byte == '"' or byte == '\'') {
            quote = byte;
            continue;
        }

        if (byte == '>') return index;
    }

    return null;
}

fn is_space(byte: u8) bool {
    assert(space_bytes.len == 4);

    return std.mem.indexOfScalar(u8, space_bytes, byte) != null;
}

fn skip_space(source: []const u8, start: usize) usize {
    assert(start <= source.len);

    var index = start;

    while (index < source.len and is_space(source[index])) index += 1;

    if (index < source.len) assert(!is_space(source[index]));

    assert(index >= start);
    assert(index <= source.len);

    return index;
}

fn index_of_space(source: []const u8) ?usize {
    for (source, 0..) |byte, index| {
        assert(index < source.len);

        if (is_space(byte)) return index;
    }

    assert(std.mem.indexOfAny(u8, source, space_bytes) == null);

    return null;
}

fn trim_space(source: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, source, space_bytes);

    assert(trimmed.len <= source.len);

    return trimmed;
}

test "parser reports elements, attributes, and text" {
    var parser = Parser.init("<x:row r=\"1\">hello</x:row>");

    const open = (try parser.next()).?.open;

    try std.testing.expectEqualStrings("x:row", open.name);
    try std.testing.expectEqualStrings("row", open.local_name());
    try std.testing.expectEqualStrings("1", (try open.attribute("r")).?);
    try std.testing.expect(!open.self_closing);

    try std.testing.expectEqualStrings("hello", (try parser.next()).?.text);
    try std.testing.expectEqualStrings("x:row", (try parser.next()).?.close);
    try std.testing.expect((try parser.next()) == null);
}

test "parser marks a self-closing element and reports no close" {
    var parser = Parser.init("<c r=\"A1\" />");

    const open = (try parser.next()).?.open;

    try std.testing.expect(open.self_closing);
    try std.testing.expectEqualStrings("A1", (try open.attribute("r")).?);
    try std.testing.expect((try parser.next()) == null);
}

test "parser skips the declaration, comments, and the doctype" {
    var parser = Parser.init("<?xml version=\"1.0\"?><!-- <fake> --><!DOCTYPE x><a/>");

    const open = (try parser.next()).?.open;

    try std.testing.expectEqualStrings("a", open.name);
    try std.testing.expect((try parser.next()) == null);
}

test "parser keeps an unescaped angle bracket inside an attribute value" {
    var parser = Parser.init("<a b=\"x>y\" c='1'>t</a>");

    const open = (try parser.next()).?.open;

    try std.testing.expectEqualStrings("x>y", (try open.attribute("b")).?);
    try std.testing.expectEqualStrings("1", (try open.attribute("c")).?);
    try std.testing.expectEqualStrings("t", (try parser.next()).?.text);
}

test "attribute lookup by local name ignores the namespace prefix" {
    var parser = Parser.init("<sheet name=\"Types\" sheetId=\"1\" r:id=\"rId2\"/>");

    const open = (try parser.next()).?.open;

    try std.testing.expectEqualStrings("rId2", (try open.attribute_local("id")).?);
    try std.testing.expectEqualStrings("Types", (try open.attribute_local("name")).?);

    try std.testing.expect((try open.attribute("id")) == null);
    try std.testing.expect((try open.attribute("missing")) == null);
}

test "attribute iteration walks every attribute in order" {
    var parser = Parser.init("<a one=\"1\" two=\"2\"/>");

    const open = (try parser.next()).?.open;
    var attributes = open.iterator();

    const first = (try attributes.next()).?;

    try std.testing.expectEqualStrings("one", first.name);
    try std.testing.expectEqualStrings("1", first.value);

    const second = (try attributes.next()).?;

    try std.testing.expectEqualStrings("two", second.name);
    try std.testing.expectEqualStrings("2", second.value);

    try std.testing.expect((try attributes.next()) == null);
}

test "the element iterator yields only the named elements" {
    const source =
        \\<?xml version="1.0"?><x:root><x:sheet name="Types" /><x:other />
        \\<x:sheet name="Messages" />text</x:root>
    ;

    var sheets = ElementIterator.init(source, "sheet");

    const types = (try (try sheets.next()).?.attribute_local("name")).?;
    const messages = (try (try sheets.next()).?.attribute_local("name")).?;

    try std.testing.expectEqualStrings("Types", types);
    try std.testing.expectEqualStrings("Messages", messages);
    try std.testing.expect((try sheets.next()) == null);
}

test "decode expands predefined and numeric entities" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();

    const predefined = try decode(arena, "a&amp;b&lt;c&gt;d&quot;e&apos;f");

    try std.testing.expectEqualStrings("a&b<c>d\"e'f", predefined);
    try std.testing.expectEqualStrings("A", try decode(arena, "&#65;"));
    try std.testing.expectEqualStrings("A", try decode(arena, "&#x41;"));
    try std.testing.expectEqualStrings("\u{00e9}", try decode(arena, "&#xe9;"));
}

test "decode returns the input untouched when it holds no entity" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const plain = "no entities here";
    const decoded = try decode(arena_state.allocator(), plain);

    try std.testing.expectEqual(plain.ptr, decoded.ptr);
}

test "decode rejects an entity it does not know" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();

    try std.testing.expectError(error.UnsupportedEntity, decode(arena, "&nbsp;"));
    try std.testing.expectError(error.UnsupportedEntity, decode(arena, "&amp"));
    try std.testing.expectError(error.UnsupportedEntity, decode(arena, "&#zz;"));
}

test "parser rejects markup outside the supported subset" {
    var cdata = Parser.init("<a><![CDATA[x]]></a>");

    _ = try cdata.next();
    try std.testing.expectError(error.UnsupportedMarkup, cdata.next());

    var unterminated = Parser.init("<a");

    try std.testing.expectError(error.MalformedXml, unterminated.next());

    var empty_tag = Parser.init("<>");

    try std.testing.expectError(error.MalformedXml, empty_tag.next());

    var empty_close = Parser.init("</>");

    try std.testing.expectError(error.MalformedXml, empty_close.next());
}

test "attribute parsing rejects a malformed attribute list" {
    var missing_value = Parser.init("<a b/>");
    const open = (try missing_value.next()).?.open;

    try std.testing.expectError(error.MalformedXml, open.attribute("b"));

    var unquoted = Parser.init("<a b=1/>");
    const bare = (try unquoted.next()).?.open;

    try std.testing.expectError(error.MalformedXml, bare.attribute("b"));
}
