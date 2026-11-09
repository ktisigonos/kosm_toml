//! Reads TOML into the tree kosm matches paths against. Hand-written: a
//! key belongs to the `[header]` above it, `[[x]]` elements lie scattered through the file, and
//! dotted keys and headers both nest, which no node-name mapping expresses. The tree is the
//! file's meaning, not its spelling: `[a.b]`, `a.b = 1` and `a = { b = 1 }` all reach `a.b`, and
//! a table spelled in several places is one node. Keys keep their escapes as written.

const Parser = @This();

const std = @import("std");
const kosm = @import("kosm");
const Node = kosm.Adapter.Node;
const Range = kosm.Adapter.Range;

allocator: std.mem.Allocator,
source: []const u8,
context: *kosm.Adapter.Context,
index: usize = 0,

/// Deeper nesting of arrays and inline tables is refused rather than risking the stack.
const max_depth = 256;

const Error = kosm.Adapter.ParseError;

/// A node while the file is read: tables still grow as later lines add to them.
const Draft = struct {
    key: ?[]const u8,
    position: usize,
    kind: Node.Kind,
    value: ?Range = null,
    origin: Origin,
    children: std.ArrayList(*Draft) = .empty,
};

/// How a node came to be, which decides what may add to it later (TOML's redefinition rules).
const Origin = enum {
    root,
    /// A table only named on the way to a deeper header (`a` of `[a.b]`); a header may define it.
    implicit,
    /// A `[table]` header, or one element of an array of tables.
    header,
    /// A table made by a dotted key (`a` of `a.b = 1`); more dotted keys may add to it.
    dotted,
    /// A value written whole: a scalar, an array or an inline table. Nothing adds to it.
    value,
    /// A list made by `[[x]]` headers; each one appends an element.
    array_of_tables,
};

/// One part of a dotted key, quotes dropped.
const KeyPart = struct {
    text: []const u8,
    position: usize,
};

/// An adapter `parser`: the file as one table. Nodes point into `source`.
pub fn parse(allocator: std.mem.Allocator, source: []const u8, context: *kosm.Adapter.Context) Error!Node {
    var parser: Parser = .{ .allocator = allocator, .source = source, .context = context };
    const root = try parser.newDraft(.{ .key = null, .position = 0, .kind = .table, .origin = .root });
    root.value = .{ .start = 0, .end = source.len };
    var table = root;
    while (true) {
        parser.skipSpaces();
        const byte = parser.peek() orelse break;
        switch (byte) {
            '\r', '\n' => try parser.newline(),
            '#' => parser.skipComment(),
            '[' => {
                table = try parser.header(root);
                try parser.lineEnd();
            },
            else => {
                try parser.pair(table, 0);
                try parser.lineEnd();
            },
        }
    }
    return parser.freeze(root);
}

fn newDraft(parser: *Parser, draft: Draft) Error!*Draft {
    const pointer = try parser.allocator.create(Draft);
    pointer.* = draft;
    return pointer;
}

/// `[a.b]` or `[[a.b]]`; the table the lines below it fill.
fn header(parser: *Parser, root: *Draft) Error!*Draft {
    const start = parser.index;
    const is_array = std.mem.startsWith(u8, parser.source[parser.index..], "[[");
    parser.index += if (is_array) 2 else 1;
    parser.skipSpaces();
    const parts = try parser.key();
    parser.skipSpaces();
    const close = if (is_array) "]]" else "]";
    if (!std.mem.startsWith(u8, parser.source[parser.index..], close)) return parser.fail("expected '{s}' to close the header", .{close});
    parser.index += close.len;
    const spelled = parser.source[start..parser.index];

    var table = root;
    for (parts[0 .. parts.len - 1]) |part| table = try parser.headerStep(table, part);
    const last = parts[parts.len - 1];
    const existing = find(table, last.text);
    if (is_array) {
        const list = existing orelse blk: {
            const list = try parser.newDraft(.{ .key = last.text, .position = last.position, .kind = .list, .origin = .array_of_tables });
            try table.children.append(parser.allocator, list);
            break :blk list;
        };
        if (list.origin != .array_of_tables)
            return parser.failAt(start, "{s}: '{s}' is already defined on line {d} and is not an array of tables", .{ spelled, last.text, parser.lineOf(list.position) });
        const element = try parser.newDraft(.{ .key = null, .position = start, .kind = .table, .origin = .header });
        try list.children.append(parser.allocator, element);
        return element;
    }
    const found = existing orelse {
        const created = try parser.newDraft(.{ .key = last.text, .position = last.position, .kind = .table, .origin = .header });
        try table.children.append(parser.allocator, created);
        return created;
    };
    switch (found.origin) {
        .implicit => {
            found.origin = .header;
            return found;
        },
        .header => return parser.failAt(start, "table {s} is defined twice, first on line {d}", .{ spelled, parser.lineOf(found.position) }),
        .dotted => return parser.failAt(start, "{s}: '{s}' is already defined by dotted keys on line {d}", .{ spelled, last.text, parser.lineOf(found.position) }),
        .value, .array_of_tables, .root => return parser.failAt(start, "{s}: '{s}' is already a value on line {d}, not a table", .{ spelled, last.text, parser.lineOf(found.position) }),
    }
}

/// One step into a header's key: an array of tables steps into its last element.
fn headerStep(parser: *Parser, table: *Draft, part: KeyPart) Error!*Draft {
    const found = find(table, part.text) orelse {
        const created = try parser.newDraft(.{ .key = part.text, .position = part.position, .kind = .table, .origin = .implicit });
        try table.children.append(parser.allocator, created);
        return created;
    };
    switch (found.origin) {
        .implicit, .header, .dotted => return found,
        .array_of_tables => return found.children.items[found.children.items.len - 1],
        .value, .root => return parser.failAt(part.position, "'{s}' is already a value on line {d}, not a table", .{ part.text, parser.lineOf(found.position) }),
    }
}

fn find(table: *const Draft, key_text: []const u8) ?*Draft {
    for (table.children.items) |child| {
        if (child.key) |child_key| if (std.mem.eql(u8, child_key, key_text)) return child;
    }
    return null;
}

/// A dotted key: `a."b.c".'d'`.
fn key(parser: *Parser) Error![]const KeyPart {
    var parts: std.ArrayList(KeyPart) = .empty;
    while (true) {
        try parts.append(parser.allocator, try parser.simpleKey());
        parser.skipSpaces();
        if (parser.peek() != '.') break;
        parser.index += 1;
        parser.skipSpaces();
    }
    return parts.items;
}

/// A bare key, `"basic"` or `'literal'`; quotes dropped, escapes kept as written.
fn simpleKey(parser: *Parser) Error!KeyPart {
    const start = parser.index;
    const first = parser.peek() orelse return parser.fail("expected a key", .{});
    switch (first) {
        '"', '\'' => {
            if (std.mem.startsWith(u8, parser.source[start..], &.{ first, first, first }))
                return parser.fail("a key can't be a multi-line string", .{});
            try parser.singleLineString(first);
            return .{ .text = parser.source[start + 1 .. parser.index - 1], .position = start };
        },
        else => {
            while (parser.peek()) |byte| {
                if (!isBareKeyByte(byte)) break;
                parser.index += 1;
            }
            if (parser.index == start) return parser.fail("'{c}' does not start a key", .{first});
            return .{ .text = parser.source[start..parser.index], .position = start };
        },
    }
}

/// Any value; its key is filled in by the caller.
fn value(parser: *Parser, depth: usize) Error!*Draft {
    if (depth == max_depth) return parser.fail("values nest deeper than {d} levels", .{max_depth});
    const start = parser.index;
    const first = parser.peek() orelse return parser.fail("a value is missing", .{});
    const draft = try parser.newDraft(.{ .key = null, .position = start, .kind = .scalar, .origin = .value });
    switch (first) {
        '"', '\'' => {
            if (std.mem.startsWith(u8, parser.source[start..], &.{ first, first, first }))
                try parser.multiLineString(first)
            else
                try parser.singleLineString(first);
        },
        '[' => {
            draft.kind = .list;
            try parser.array(draft, depth);
        },
        '{' => {
            draft.kind = .table;
            try parser.inlineTable(draft, depth);
        },
        '\r', '\n', '#' => return parser.fail("a value is missing", .{}),
        else => try parser.bareValue(),
    }
    draft.value = .{ .start = start, .end = parser.index };
    return draft;
}

/// `[ value, ... ]`, across lines, with comments and a trailing comma.
fn array(parser: *Parser, list: *Draft, depth: usize) Error!void {
    parser.index += 1;
    while (true) {
        try parser.skipBlank();
        if (parser.peek() == ']') break;
        const element = try parser.value(depth + 1);
        try list.children.append(parser.allocator, element);
        try parser.skipBlank();
        const byte = parser.peek() orelse return parser.fail("an array is never closed", .{});
        if (byte == ']') break;
        if (byte != ',') return parser.fail("expected ',' or ']' after an array element", .{});
        parser.index += 1;
    }
    parser.index += 1;
}

/// `{ key = value, ... }`. TOML 1.1's newlines, comments and trailing comma are read too.
fn inlineTable(parser: *Parser, table: *Draft, depth: usize) Error!void {
    parser.index += 1;
    while (true) {
        try parser.skipBlank();
        if (parser.peek() == '}') break;
        try parser.pair(table, depth + 1);
        try parser.skipBlank();
        const byte = parser.peek() orelse return parser.fail("an inline table is never closed", .{});
        if (byte == '}') break;
        if (byte != ',') return parser.fail("expected ',' or '}}' after an inline table's entry", .{});
        parser.index += 1;
    }
    parser.index += 1;
}

/// `key = value`, added to `table`; `depth` counts the arrays and inline tables around it.
fn pair(parser: *Parser, table: *Draft, depth: usize) Error!void {
    const parts = try parser.key();
    parser.skipSpaces();
    if (parser.peek() != '=') return parser.fail("expected '=' after the key", .{});
    parser.index += 1;
    parser.skipSpaces();
    const value_draft = try parser.value(depth);
    try parser.place(table, parts, value_draft);
}

/// Adds `value_draft` under `parts` in `table`, making the dotted tables on the way.
fn place(parser: *Parser, table: *Draft, parts: []const KeyPart, value_draft: *Draft) Error!void {
    var parent = table;
    for (parts[0 .. parts.len - 1]) |part| {
        if (find(parent, part.text)) |found| {
            if (found.origin != .dotted)
                return parser.failAt(part.position, "'{s}' is defined on line {d}; dotted keys can't add to it", .{ part.text, parser.lineOf(found.position) });
            parent = found;
        } else {
            const created = try parser.newDraft(.{ .key = part.text, .position = part.position, .kind = .table, .origin = .dotted });
            try parent.children.append(parser.allocator, created);
            parent = created;
        }
    }
    const last = parts[parts.len - 1];
    if (find(parent, last.text)) |found|
        return parser.failAt(last.position, "'{s}' is already defined on line {d}", .{ last.text, parser.lineOf(found.position) });
    value_draft.key = last.text;
    value_draft.position = last.position;
    try parent.children.append(parser.allocator, value_draft);
}

/// `"..."` with escapes, or `'...'` without; on one line.
fn singleLineString(parser: *Parser, quote: u8) Error!void {
    const start = parser.index;
    parser.index += 1;
    while (parser.peek()) |byte| : (parser.index += 1) {
        if (byte == '\n' or byte == '\r') break;
        if (byte == '\\' and quote == '"') {
            parser.index += 1;
            if (parser.peek() == '\n' or parser.peek() == '\r') break;
            continue;
        }
        if (byte == quote) {
            parser.index += 1;
            return;
        }
    }
    return parser.failAt(start, "a string is never closed on its line", .{});
}

/// `"""..."""` or `'''...'''`. Up to two quotes may sit right before the closing three.
fn multiLineString(parser: *Parser, quote: u8) Error!void {
    const start = parser.index;
    parser.index += 3;
    while (parser.peek()) |byte| {
        if (byte == '\\' and quote == '"') {
            parser.index += 2;
            continue;
        }
        if (byte != quote) {
            parser.index += 1;
            continue;
        }
        var run: usize = 0;
        while (parser.peek() == quote) : (run += 1) parser.index += 1;
        if (run > 5) return parser.fail("too many quotes in a row inside a multi-line string", .{});
        if (run >= 3) return;
    }
    return parser.failAt(start, "a multi-line string is never closed", .{});
}

/// A boolean, number, date or time, checked so a typo is an error, never a value kosm edits.
fn bareValue(parser: *Parser) Error!void {
    const start = parser.index;
    parser.scanBareToken();
    // A date and a time may be split by a space: `1979-05-27 07:32:00Z`.
    if (isDate(parser.source[start..parser.index]) and parser.index + 3 < parser.source.len and
        parser.source[parser.index] == ' ' and std.ascii.isDigit(parser.source[parser.index + 1]) and
        std.ascii.isDigit(parser.source[parser.index + 2]) and parser.source[parser.index + 3] == ':')
    {
        parser.index += 1;
        parser.scanBareToken();
    }
    const token = parser.source[start..parser.index];
    if (token.len == 0) return parser.failAt(start, "'{c}' does not start a value", .{parser.source[start]});
    if (!isBareValue(token)) return parser.failAt(start, "'{s}' is not a TOML value; quote text as a string", .{token});
}

fn scanBareToken(parser: *Parser) void {
    while (parser.peek()) |byte| {
        switch (byte) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '+', '-', '.', ':' => parser.index += 1,
            else => break,
        }
    }
}

/// Requires the rest of the line to be blank or a comment.
fn lineEnd(parser: *Parser) Error!void {
    parser.skipSpaces();
    if (parser.peek() == '#') parser.skipComment();
    if (parser.peek() == null) return;
    if (parser.peek() != '\n' and parser.peek() != '\r') return parser.fail("expected the end of the line", .{});
    try parser.newline();
}

fn newline(parser: *Parser) Error!void {
    if (parser.peek() == '\r') {
        parser.index += 1;
        if (parser.peek() != '\n') return parser.fail("a carriage return must be followed by a newline", .{});
    }
    parser.index += 1;
}

fn skipSpaces(parser: *Parser) void {
    while (parser.peek()) |byte| {
        if (byte != ' ' and byte != '\t') break;
        parser.index += 1;
    }
}

fn skipComment(parser: *Parser) void {
    parser.index = std.mem.indexOfScalarPos(u8, parser.source, parser.index, '\n') orelse parser.source.len;
    if (parser.index > 0 and parser.source[parser.index - 1] == '\r') parser.index -= 1;
}

/// Spaces, newlines and comments, as allowed inside arrays.
fn skipBlank(parser: *Parser) Error!void {
    while (true) {
        parser.skipSpaces();
        const byte = parser.peek() orelse return;
        switch (byte) {
            '#' => parser.skipComment(),
            '\r', '\n' => try parser.newline(),
            else => return,
        }
    }
}

fn peek(parser: *const Parser) ?u8 {
    return if (parser.index < parser.source.len) parser.source[parser.index] else null;
}

fn freeze(parser: *Parser, draft: *const Draft) Error!Node {
    const children = try parser.allocator.alloc(Node, draft.children.items.len);
    for (draft.children.items, children) |child, *node| node.* = try parser.freeze(child);
    return .{ .key = draft.key, .kind = draft.kind, .position = draft.position, .value = draft.value, .children = children };
}

fn lineOf(parser: *const Parser, position: usize) usize {
    return 1 + std.mem.count(u8, parser.source[0..@min(position, parser.source.len)], "\n");
}

fn fail(parser: *const Parser, comptime format: []const u8, arguments: anytype) error{InvalidSyntax} {
    return parser.failAt(parser.index, format, arguments);
}

fn failAt(parser: *const Parser, position: usize, comptime format: []const u8, arguments: anytype) error{InvalidSyntax} {
    return parser.context.invalidSyntax("line {d}: " ++ format, .{parser.lineOf(position)} ++ arguments);
}

fn isBareKeyByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-';
}

fn isBareValue(token: []const u8) bool {
    return std.mem.eql(u8, token, "true") or std.mem.eql(u8, token, "false") or
        isInteger(token) or isFloat(token) or isDateTime(token);
}

/// `42`, `+1_000`, `0xdead_beef`, `0o755`, `0b1101`.
fn isInteger(token: []const u8) bool {
    if (token.len > 2 and token[0] == '0') {
        const digits = token[2..];
        return switch (token[1]) {
            'x' => isDigitRun(digits, std.ascii.isHex),
            'o' => isDigitRun(digits, isOctal),
            'b' => isDigitRun(digits, isBinary),
            else => false,
        };
    }
    return isDecimalInteger(token);
}

/// `[+-]` then `0` or digits without a leading zero.
fn isDecimalInteger(token: []const u8) bool {
    const unsigned = if (token.len > 0 and (token[0] == '+' or token[0] == '-')) token[1..] else token;
    if (unsigned.len > 1 and unsigned[0] == '0') return false;
    return isDigitRun(unsigned, std.ascii.isDigit);
}

/// `3.14`, `-0.01`, `5e+22`, `6.626e-34`, `1_000.5`, `inf`, `-nan`.
fn isFloat(token: []const u8) bool {
    const unsigned = if (token.len > 0 and (token[0] == '+' or token[0] == '-')) token[1..] else token;
    if (std.mem.eql(u8, unsigned, "inf") or std.mem.eql(u8, unsigned, "nan")) return true;
    const exponent_at = std.mem.indexOfAny(u8, token, "eE");
    const mantissa = token[0 .. exponent_at orelse token.len];
    if (exponent_at) |at| {
        if (!isDecimalExponent(token[at + 1 ..])) return false;
    }
    if (std.mem.indexOfScalar(u8, mantissa, '.')) |dot| {
        return isDecimalInteger(mantissa[0..dot]) and isDigitRun(mantissa[dot + 1 ..], std.ascii.isDigit);
    }
    return exponent_at != null and isDecimalInteger(mantissa);
}

fn isDecimalExponent(text: []const u8) bool {
    const unsigned = if (text.len > 0 and (text[0] == '+' or text[0] == '-')) text[1..] else text;
    return isDigitRun(unsigned, std.ascii.isDigit);
}

/// Digits, with single underscores only between two of them.
fn isDigitRun(text: []const u8, isDigit: fn (u8) bool) bool {
    if (text.len == 0) return false;
    for (text, 0..) |byte, index| {
        if (byte == '_') {
            if (index == 0 or index == text.len - 1 or !isDigit(text[index - 1]) or !isDigit(text[index + 1])) return false;
        } else if (!isDigit(byte)) return false;
    }
    return true;
}

fn isOctal(byte: u8) bool {
    return byte >= '0' and byte <= '7';
}

fn isBinary(byte: u8) bool {
    return byte == '0' or byte == '1';
}

/// A date, a time, or both: `1979-05-27`, `07:32:00.999`, `1979-05-27T07:32:00-07:00`.
fn isDateTime(token: []const u8) bool {
    if (isTime(token)) return true;
    if (token.len < 10 or !isDate(token[0..10])) return false;
    if (token.len == 10) return true;
    const separator = token[10];
    if (separator != 'T' and separator != 't' and separator != ' ') return false;
    var time = token[11..];
    if (time.len > 0 and (time[time.len - 1] == 'Z' or time[time.len - 1] == 'z')) {
        time = time[0 .. time.len - 1];
    } else if (time.len > 6 and (time[time.len - 6] == '+' or time[time.len - 6] == '-')) {
        if (!matchesPattern(time[time.len - 5 ..], "00:00")) return false;
        time = time[0 .. time.len - 6];
    }
    return isTime(time);
}

fn isDate(text: []const u8) bool {
    return matchesPattern(text, "0000-00-00");
}

/// `07:32`, `07:32:00` or `07:32:00.999` (seconds are optional since TOML 1.1).
fn isTime(text: []const u8) bool {
    if (matchesPattern(text, "00:00")) return true;
    if (text.len < 8 or !matchesPattern(text[0..8], "00:00:00")) return false;
    if (text.len == 8) return true;
    return text[8] == '.' and isDigitRun(text[9..], std.ascii.isDigit) and std.mem.indexOfScalar(u8, text[9..], '_') == null;
}

/// `0` in `pattern` stands for any digit; every other byte must match itself.
fn matchesPattern(text: []const u8, pattern: []const u8) bool {
    if (text.len != pattern.len) return false;
    for (text, pattern) |byte, expected| {
        if (expected == '0') {
            if (!std.ascii.isDigit(byte)) return false;
        } else if (byte != expected) return false;
    }
    return true;
}

const testing = std.testing;

fn parseForTest(allocator: std.mem.Allocator, source: []const u8) !Node {
    var context: kosm.Adapter.Context = .{ .format = kosm.Format.kosm_default };
    return parse(allocator, source, &context);
}

fn childFor(node: Node, key_text: []const u8) !Node {
    for (node.children) |entry| {
        if (entry.key) |entry_key| if (std.mem.eql(u8, entry_key, key_text)) return entry;
    }
    std.debug.print("no key '{s}'\n", .{key_text});
    return error.TestExpectedEqual;
}

fn valueText(source: []const u8, node: Node) []const u8 {
    return source[node.value.?.start..node.value.?.end];
}

test "headers, dotted keys and inline tables reach one tree" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const source =
        \\title = "kyanos" # trailing comment
        \\window.opacity = 0.9
        \\window.padding = { x = 10, y = 10 }
        \\
        \\[font]
        \\size = 12.0
        \\normal = { family = "JetBrains Mono", style = 'Regular' }
        \\
        \\[colors.primary]
        \\background = '#1d1f21'
        \\
        \\[colors]
        \\cursor.text = "CellBackground"
        \\"dim.foreground" = "#828482"
        \\
    ;
    const root = try parseForTest(arena.allocator(), source);
    try testing.expectEqual(4, root.children.len);
    try testing.expectEqualStrings("\"kyanos\"", valueText(source, try childFor(root, "title")));
    const window = try childFor(root, "window");
    try testing.expectEqual(null, window.value);
    try testing.expectEqualStrings("0.9", valueText(source, try childFor(window, "opacity")));
    const padding = try childFor(window, "padding");
    try testing.expectEqual(.table, padding.kind);
    try testing.expectEqualStrings("{ x = 10, y = 10 }", valueText(source, padding));
    try testing.expectEqualStrings("10", valueText(source, try childFor(padding, "y")));
    const normal = try childFor(try childFor(root, "font"), "normal");
    try testing.expectEqualStrings("'Regular'", valueText(source, try childFor(normal, "style")));
    const colors = try childFor(root, "colors");
    try testing.expectEqual(3, colors.children.len);
    try testing.expectEqualStrings("'#1d1f21'", valueText(source, try childFor(try childFor(colors, "primary"), "background")));
    try testing.expectEqualStrings("\"CellBackground\"", valueText(source, try childFor(try childFor(colors, "cursor"), "text")));
    try testing.expectEqualStrings("\"#828482\"", valueText(source, try childFor(colors, "dim.foreground")));
}

test "arrays of tables are one list, and a header below one nests into its last element" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const source =
        \\[[keyboard.bindings]]
        \\key = "N"
        \\mods = "Control|Shift"
        \\
        \\[general]
        \\live_config_reload = true
        \\
        \\[[keyboard.bindings]]
        \\key = "Q"
        \\
        \\[keyboard.bindings.extra]
        \\chars = "\u0003"
    ;
    const root = try parseForTest(arena.allocator(), source);
    const bindings = try childFor(try childFor(root, "keyboard"), "bindings");
    try testing.expectEqual(.list, bindings.kind);
    try testing.expectEqual(2, bindings.children.len);
    try testing.expectEqualStrings("\"N\"", valueText(source, try childFor(bindings.children[0], "key")));
    try testing.expectEqual(1, (try childFor(root, "general")).children.len);
    const second = bindings.children[1];
    try testing.expectEqual(null, second.key);
    try testing.expectEqualStrings("\"\\u0003\"", valueText(source, try childFor(try childFor(second, "extra"), "chars")));
}

test "every kind of value is read whole" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const cases = [_][]const u8{
        "\"tab\\there \\\"quoted\\\"\"",            "'C:\\Users\\nodejs'",
        "\"\"\"\nline one\nline \"\"two\"\"\"\"\"", "'''\nraw ''inner'' quotes\n'''",
        "+1_000",                                   "-17",
        "0",                                        "0xDEAD_beef",
        "0o755",                                    "0b1101",
        "3.1415",                                   "-0.01",
        "5e+22",                                    "6.626e-34",
        "-inf",                                     "nan",
        "true",                                     "1979-05-27T07:32:00Z",
        "1979-05-27 00:32:00.999999-07:00",         "1979-05-27",
        "07:32:00",                                 "[ 1, [ \"a\", 'b' ], { x = 1 }, ]",
        "[\n  # a comment\n  1,\n  2 # another\n]",
    };
    for (cases) |text| {
        const source = try arena.allocator().print("value = {s}\nafter = 1\n", .{text});
        const root = parseForTest(arena.allocator(), source) catch |err| {
            std.debug.print("failed on: {s}\n", .{text});
            return err;
        };
        try testing.expectEqualStrings(text, valueText(source, try childFor(root, "value")));
        _ = try childFor(root, "after");
    }
}

test "arrays hold their elements, inline tables their keys" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const source = "import = [\"a.toml\", { b = 2 }]\r\nempty = []\r\n";
    const root = try parseForTest(arena.allocator(), source);
    const import = try childFor(root, "import");
    try testing.expectEqual(.list, import.kind);
    try testing.expectEqual(2, import.children.len);
    try testing.expectEqualStrings("\"a.toml\"", valueText(source, import.children[0]));
    try testing.expectEqualStrings("2", valueText(source, try childFor(import.children[1], "b")));
    try testing.expectEqual(0, (try childFor(root, "empty")).children.len);
}

test "what TOML forbids is an error naming the line" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var context: kosm.Adapter.Context = .{ .format = kosm.Format.kosm_default };
    const cases = [_][2][]const u8{
        .{ "a = 1\na = 2\n", "line 2: 'a' is already defined on line 1" },
        .{ "[a]\nx = 1\n[a]\n", "line 3: table [a] is defined twice, first on line 1" },
        .{ "a = { b = 1 }\n[a.c]\n", "line 2: 'a' is already a value on line 1, not a table" },
        .{ "a = { b = 1 }\na.c = 2\n", "line 2: 'a' is defined on line 1; dotted keys can't add to it" },
        .{ "[x]\na.b = 1\n[x.a]\n", "line 3: [x.a]: 'a' is already defined by dotted keys on line 2" },
        .{ "[a.b]\n[a]\nb.c = 1\n", "line 3: 'b' is defined on line 1; dotted keys can't add to it" },
        .{ "[a]\n[[a]]\n", "line 2: [[a]]: 'a' is already defined on line 1 and is not an array of tables" },
        .{ "a = yes\n", "line 1: 'yes' is not a TOML value; quote text as a string" },
        .{ "a = 007\n", "line 1: '007' is not a TOML value; quote text as a string" },
        .{ "a = 1__0\n", "line 1: '1__0' is not a TOML value; quote text as a string" },
        .{ "a = 1 b = 2\n", "line 1: expected the end of the line" },
        .{ "a = \"open\nb = 1\n", "line 1: a string is never closed on its line" },
        .{ "\n\na = '''open\n", "line 3: a multi-line string is never closed" },
        .{ "a = [1, 2\n", "line 2: an array is never closed" },
        .{ "a = [1 2]\n", "line 1: expected ',' or ']' after an array element" },
        .{ "a\n", "line 1: expected '=' after the key" },
        .{ "a =\n", "line 1: a value is missing" },
        .{ "[a\n", "line 1: expected ']' to close the header" },
        .{ "= 1\n", "line 1: '=' does not start a key" },
        .{ "\"\"\"a\"\"\" = 1\n", "line 1: a key can't be a multi-line string" },
        .{ "a = 1\r b = 2\n", "line 1: a carriage return must be followed by a newline" },
    };
    for (cases) |case| {
        const result = parse(arena.allocator(), case[0], &context);
        if (result) |_| {
            std.debug.print("parsed: {s}\n", .{case[0]});
            return error.TestExpectedError;
        } else |err| try testing.expectEqual(error.InvalidSyntax, err);
        try testing.expectEqualStrings(case[1], context.message());
    }
}

test "an empty file or one of only comments is an empty table" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(0, (try parseForTest(arena.allocator(), "")).children.len);
    try testing.expectEqual(0, (try parseForTest(arena.allocator(), "# only\n\n  # comments")).children.len);
}
