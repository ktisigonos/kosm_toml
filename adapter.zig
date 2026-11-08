//! TOML (D105): values as TOML spells them, and whole files with `[table]` sections. Colors and
//! joined values are strings, since TOML has neither; floats always keep a `.` or an exponent,
//! since `1` would be read back as an integer.

const std = @import("std");
const kosm = @import("kosm");
const Parser = @import("Parser.zig");

/// The adapter for `.toml` files; enables `generate`, `block` (D71) and `edit`.
pub const adapter: kosm.Adapter = .{
    .name = "toml",
    .extensions = &.{".toml"},
    .default_format = .{ .color = .hex, .boolean = .true_false },
    .format = format,
    .parser = Parser.parse,
    .serialize = serialize,
    .comment = .{ .line = "#" },
};

/// Longest joined value kosm renders into one string.
const max_joined_length = 64 * 1024;

/// Deepest `[a.b.c]` header `serialize` writes.
const max_header_depth = 64;

/// The keys of the section being written, outermost first.
const HeaderPath = struct {
    keys: [max_header_depth][]const u8 = undefined,
    length: usize = 0,
};

fn serialize(writer: *std.Io.Writer, root: kosm.Value, context: *kosm.Adapter.Context) kosm.Adapter.Error!void {
    if (root != .table) return context.unsupported("a TOML file is a table, not a {s}", .{@tagName(root)});
    var path: HeaderPath = .{};
    var wrote_anything = false;
    try writeTable(writer, root.table, &path, &wrote_anything, context);
}

/// A table's own values first, then its sections, as TOML requires.
fn writeTable(writer: *std.Io.Writer, entries: []const kosm.Value.Entry, path: *HeaderPath, wrote_anything: *bool, context: *kosm.Adapter.Context) kosm.Adapter.Error!void {
    for (entries) |entry| {
        if (isSection(entry.value)) continue;
        try writeKey(writer, entry.key);
        try writer.writeAll(" = ");
        try format(writer, entry.value, context);
        try writer.writeByte('\n');
        wrote_anything.* = true;
    }
    for (entries) |entry| {
        if (!isSection(entry.value)) continue;
        if (path.length == max_header_depth) return context.unsupported("tables nest deeper than {d} levels", .{max_header_depth});
        path.keys[path.length] = entry.key;
        path.length += 1;
        defer path.length -= 1;
        switch (entry.value) {
            .table => |table| {
                if (needsHeader(table)) try writeHeader(writer, path, "[", "]", wrote_anything);
                try writeTable(writer, table, path, wrote_anything, context);
            },
            .list => |elements| for (elements) |element| {
                try writeHeader(writer, path, "[[", "]]", wrote_anything);
                try writeTable(writer, element.table, path, wrote_anything, context);
            },
            else => unreachable,
        }
    }
}

/// Tables become `[sections]` and lists of only tables `[[arrays of tables]]`; the rest is
/// written on the key's line.
fn isSection(value: kosm.Value) bool {
    return switch (value) {
        .table => true,
        .list => |elements| elements.len > 0 and for (elements) |element| {
            if (element != .table) break false;
        } else true,
        else => false,
    };
}

/// A table holding only sections is defined by their headers, so its own is left out.
fn needsHeader(entries: []const kosm.Value.Entry) bool {
    if (entries.len == 0) return true;
    for (entries) |entry| if (!isSection(entry.value)) return true;
    return false;
}

fn writeHeader(writer: *std.Io.Writer, path: *const HeaderPath, open: []const u8, close: []const u8, wrote_anything: *bool) std.Io.Writer.Error!void {
    if (wrote_anything.*) try writer.writeByte('\n');
    try writer.writeAll(open);
    for (path.keys[0..path.length], 0..) |path_key, index| {
        if (index != 0) try writer.writeByte('.');
        try writeKey(writer, path_key);
    }
    try writer.writeAll(close);
    try writer.writeByte('\n');
    wrote_anything.* = true;
}

/// Writes one value; with `parser`, enables `edit` (D42). Tables are inline tables here.
fn format(writer: *std.Io.Writer, value: kosm.Value, context: *kosm.Adapter.Context) kosm.Adapter.Error!void {
    switch (value) {
        .string => |text| try writeString(writer, text),
        .raw => |text| try writer.writeAll(text),
        .integer => |integer| try writer.print("{d}", .{integer}),
        .float => |float| try writeFloat(writer, float, context),
        .boolean => |boolean| {
            if (context.format.boolean != .true_false)
                return context.unsupported("TOML spells booleans only as true and false; leave format.boolean at .true_false", .{});
            try context.writeBoolean(writer, boolean);
        },
        .color, .joined => {
            var buffer: [max_joined_length]u8 = undefined;
            var rendered: std.Io.Writer = .fixed(&buffer);
            writePlain(&rendered, value, context) catch |err| switch (err) {
                error.WriteFailed => return context.unsupported("the value is longer than {d} bytes", .{max_joined_length}),
                error.UnsupportedValue => return error.UnsupportedValue,
            };
            try writeString(writer, rendered.buffered());
        },
        .list => |items| {
            try writer.writeByte('[');
            for (items, 0..) |item, index| {
                if (index != 0) try writer.writeAll(", ");
                try format(writer, item, context);
            }
            try writer.writeByte(']');
        },
        .table => |entries| {
            if (entries.len == 0) return writer.writeAll("{}");
            try writer.writeAll("{ ");
            for (entries, 0..) |entry, index| {
                if (index != 0) try writer.writeAll(", ");
                try writeKey(writer, entry.key);
                try writer.writeAll(" = ");
                try format(writer, entry.value, context);
            }
            try writer.writeAll(" }");
        },
    }
}

/// A value's text inside a string: parts of a joined value are written back to back (D89).
fn writePlain(writer: *std.Io.Writer, value: kosm.Value, context: *kosm.Adapter.Context) kosm.Adapter.Error!void {
    switch (value) {
        .string, .raw => |text| try writer.writeAll(text),
        .integer => |integer| try writer.print("{d}", .{integer}),
        .float => |float| try context.writeFloat(writer, float),
        .boolean => |boolean| try context.writeBoolean(writer, boolean),
        .color => |color| try context.writeColor(writer, color),
        .joined => |parts| for (parts) |part| try writePlain(writer, part, context),
        .list, .table => return context.unsupported("a joined value holds plain values, not a {s}", .{@tagName(value)}),
    }
}

/// A float at the file's precision that TOML reads back as a float: `13` is written `13.0`.
fn writeFloat(writer: *std.Io.Writer, float: f64, context: *kosm.Adapter.Context) std.Io.Writer.Error!void {
    if (std.math.isNan(float)) return writer.writeAll("nan");
    if (std.math.isInf(float)) return writer.writeAll(if (float > 0) "inf" else "-inf");
    // An f64 printed without an exponent is at most 309 digits, plus 12 decimals.
    var buffer: [400]u8 = undefined;
    var rendered: std.Io.Writer = .fixed(&buffer);
    context.writeFloat(&rendered, float) catch unreachable;
    const text = rendered.buffered();
    try writer.writeAll(text);
    if (std.mem.indexOfAny(u8, text, ".eE") == null) try writer.writeAll(".0");
}

/// A bare key when TOML allows one, a quoted key otherwise.
fn writeKey(writer: *std.Io.Writer, key: []const u8) std.Io.Writer.Error!void {
    const bare = key.len > 0 and for (key) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') break false;
    } else true;
    if (bare) return writer.writeAll(key);
    try writeString(writer, key);
}

/// A TOML basic string in double quotes.
fn writeString(writer: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    try writer.writeByte('"');
    for (text) |byte| switch (byte) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        0x08 => try writer.writeAll("\\b"),
        0x0c => try writer.writeAll("\\f"),
        0...0x07, 0x0b, 0x0e...0x1f, 0x7f => try writer.print("\\u{x:0>4}", .{byte}),
        else => try writer.writeByte(byte),
    };
    try writer.writeByte('"');
}

const testing = std.testing;

fn formatForTest(value: kosm.Value, output: *std.Io.Writer.Allocating) !void {
    var context: kosm.Adapter.Context = .{ .format = adapter.default_format.resolve() };
    try format(&output.writer, value, &context);
}

test "values are written as TOML spells them" {
    const cases = [_]struct { kosm.Value, []const u8 }{
        .{ .{ .string = "say \"hi\"\\\n\t\u{1}\u{7f}" }, "\"say \\\"hi\\\"\\\\\\n\\t\\u0001\\u007f\"" },
        .{ .{ .integer = -42 }, "-42" },
        .{ .{ .float = 13 }, "13.0" },
        .{ .{ .float = -0.5 }, "-0.5" },
        .{ .{ .float = 1e21 }, "1000000000000000000000.0" },
        .{ .{ .float = std.math.inf(f64) }, "inf" },
        .{ .{ .float = -std.math.inf(f64) }, "-inf" },
        .{ .{ .float = std.math.nan(f64) }, "nan" },
        .{ .{ .boolean = false }, "false" },
        .{ .{ .color = try kosm.Color.parseHex("#041c26") }, "\"#041c26\"" },
        .{ .{ .joined = &.{ .{ .integer = 2 }, .{ .raw = "pt" } } }, "\"2pt\"" },
        .{ .{ .raw = "1979-05-27" }, "1979-05-27" },
        .{ .{ .list = &.{ .{ .integer = 1 }, .{ .string = "a" } } }, "[1, \"a\"]" },
        .{ .{ .table = &.{ .{ .key = "x", .value = .{ .integer = 10 } }, .{ .key = "a.b", .value = .{ .table = &.{} } } } }, "{ x = 10, \"a.b\" = {} }" },
    };
    for (cases) |case| {
        var output: std.Io.Writer.Allocating = .init(testing.allocator);
        defer output.deinit();
        try formatForTest(case[0], &output);
        try testing.expectEqualStrings(case[1], output.written());
    }
}

test "booleans other than true and false are refused" {
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var context: kosm.Adapter.Context = .{ .format = (kosm.Format{ .boolean = .yes_no }).orElse(adapter.default_format).resolve() };
    try testing.expectError(error.UnsupportedValue, format(&output.writer, .{ .boolean = true }, &context));
    try testing.expectEqualStrings("TOML spells booleans only as true and false; leave format.boolean at .true_false", context.message());
}

fn serializeForTest(root: kosm.Value, output: *std.Io.Writer.Allocating) !void {
    var context: kosm.Adapter.Context = .{ .format = adapter.default_format.resolve() };
    try serialize(&output.writer, root, &context);
}

const generated_value: kosm.Value = .{ .table = &.{
    .{ .key = "colors", .value = .{ .table = &.{
        .{ .key = "primary", .value = .{ .table = &.{
            .{ .key = "background", .value = .{ .string = "#041c26" } },
        } } },
        .{ .key = "transparent_background_colors", .value = .{ .boolean = true } },
        .{ .key = "accents", .value = .{ .table = &.{
            .{ .key = "blue", .value = .{ .string = "2D8699" } },
        } } },
    } } },
    .{ .key = "title", .value = .{ .string = "kyanos" } },
    .{ .key = "window", .value = .{ .table = &.{
        .{ .key = "dimensions", .value = .{ .table = &.{
            .{ .key = "columns", .value = .{ .integer = 80 } },
        } } },
    } } },
    .{ .key = "keyboard", .value = .{ .table = &.{
        .{ .key = "bindings", .value = .{ .list = &.{
            .{ .table = &.{
                .{ .key = "key", .value = .{ .string = "N" } },
                .{ .key = "chars", .value = .{ .table = &.{.{ .key = "x", .value = .{ .integer = 1 } }} } },
            } },
            .{ .table = &.{.{ .key = "key", .value = .{ .string = "Q" } }} },
        } } },
    } } },
    .{ .key = "empty", .value = .{ .table = &.{} } },
    .{ .key = "import", .value = .{ .list = &.{.{ .string = "a.toml" }} } },
    .{ .key = "font.size", .value = .{ .float = 12 } },
} };

test "a file is written with a table's values before its sections" {
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try serializeForTest(generated_value, &output);
    try testing.expectEqualStrings(
        \\title = "kyanos"
        \\import = ["a.toml"]
        \\"font.size" = 12.0
        \\
        \\[colors]
        \\transparent_background_colors = true
        \\
        \\[colors.primary]
        \\background = "#041c26"
        \\
        \\[colors.accents]
        \\blue = "2D8699"
        \\
        \\[window.dimensions]
        \\columns = 80
        \\
        \\[[keyboard.bindings]]
        \\key = "N"
        \\
        \\[keyboard.bindings.chars]
        \\x = 1
        \\
        \\[[keyboard.bindings]]
        \\key = "Q"
        \\
        \\[empty]
        \\
    , output.written());
}

test "a written file parses back to the same keys" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try serializeForTest(generated_value, &output);
    var context: kosm.Adapter.Context = .{ .format = adapter.default_format.resolve() };
    const root = try Parser.parse(arena.allocator(), output.written(), &context);
    try expectSameKeys(generated_value, root);
}

fn expectSameKeys(value: kosm.Value, node: kosm.Adapter.Node) !void {
    switch (value) {
        .table => |entries| {
            try testing.expectEqual(.table, node.kind);
            try testing.expectEqual(entries.len, node.children.len);
            for (entries) |entry| {
                const found = for (node.children) |entry_node| {
                    if (std.mem.eql(u8, entry_node.key.?, entry.key)) break entry_node;
                } else return error.TestExpectedEqual;
                try expectSameKeys(entry.value, found);
            }
        },
        .list => |elements| {
            try testing.expectEqual(.list, node.kind);
            try testing.expectEqual(elements.len, node.children.len);
            for (elements, node.children) |element, element_node| try expectSameKeys(element, element_node);
        },
        else => try testing.expectEqual(.scalar, node.kind),
    }
}

const Fixture = struct {
    tmp: testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    plan: kosm.Plan,
    diagnostics: kosm.Diagnostics = .{},
    warnings: kosm.Warnings = undefined,
    home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined,
    output: kosm.Output = undefined,

    fn init(fixture: *Fixture, path: []const u8, contents: []const u8) !void {
        fixture.* = .{ .tmp = testing.tmpDir(.{}), .arena = .init(testing.allocator), .plan = .init(testing.allocator, testing.io) };
        if (std.Io.Dir.path.dirname(path)) |parent| try fixture.tmp.dir.createDirPath(testing.io, parent);
        try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = path, .data = contents });
        fixture.warnings = .init(fixture.arena.allocator());
        const length = try fixture.tmp.dir.realPath(testing.io, &fixture.home_buffer);
        fixture.output = .{
            .allocator = fixture.arena.allocator(),
            .home = fixture.home_buffer[0..length],
            .adapters = &.{adapter},
            .plan = &fixture.plan,
            .diagnostics = &fixture.diagnostics,
            .warnings = &fixture.warnings,
            .app = "alacritty",
        };
    }

    fn deinit(fixture: *Fixture) void {
        fixture.plan.deinit();
        fixture.arena.deinit();
        fixture.tmp.cleanup();
    }
};

const alacritty_toml =
    \\[general]
    \\live_config_reload = true
    \\import = ["~/.config/alacritty/kosm.toml"]
    \\
    \\[window]
    \\padding = {x = 10, y = 10}
    \\opacity = 1
    \\
    \\[font]
    \\normal = { family = "Maple Mono Normal NFP", style = "Regular" }
    \\bold = { family = "Maple Mono Normal NFP", style = "Bold" }
    \\size = 16
    \\
    \\[colors]
    \\footer_bar = { foreground = "#A3C5CC", background = "#041C26" }
    \\
    \\[colors.primary]
    \\foreground = "#A3C5CC"   # the text
    \\background = '#041C26'
    \\
    \\[colors.normal]
    \\black = "#041C26"
    \\red = "#80333C"
    \\
    \\[colors.bright]
    \\black = "#082E3F"
    \\red = "#993D49"
    \\
    \\[[keyboard.bindings]]
    \\key = "N"
    \\mods = "Control|Shift"
    \\action = "CreateNewWindow"
    \\
    \\[[keyboard.bindings]]
    \\key = "Return"
    \\mods = "Control|Shift"
    \\action = "SpawnNewInstance"
    \\
;

test "edit changes only the values' bytes, however the file nests its keys" {
    var fixture: Fixture = undefined;
    try fixture.init(".config/alacritty/alacritty.toml", alacritty_toml);
    defer fixture.deinit();
    var file = try fixture.output.edit(.{ .files = "~/.config/alacritty/alacritty.toml" });
    try file.set("window.opacity", 0.5);
    try file.set("window.padding.x", 12);
    try file.set("font.size", 13.0);
    try file.set("font.normal.family", "Iosevka");
    try file.set("colors.primary.background", kosm.hex("102840"));
    try file.set("colors.footer_bar.background", kosm.hex("102840"));
    try file.setAll("colors.*.red", kosm.hex("bf616a"));
    try file.set("general.live_config_reload", false);

    try testing.expectEqualStrings(
        \\[general]
        \\live_config_reload = false
        \\import = ["~/.config/alacritty/kosm.toml"]
        \\
        \\[window]
        \\padding = {x = 12, y = 10}
        \\opacity = 0.5
        \\
        \\[font]
        \\normal = { family = "Iosevka", style = "Regular" }
        \\bold = { family = "Maple Mono Normal NFP", style = "Bold" }
        \\size = 13.0
        \\
        \\[colors]
        \\footer_bar = { foreground = "#A3C5CC", background = "#102840" }
        \\
        \\[colors.primary]
        \\foreground = "#A3C5CC"   # the text
        \\background = "#102840"
        \\
        \\[colors.normal]
        \\black = "#041C26"
        \\red = "#bf616a"
        \\
        \\[colors.bright]
        \\black = "#082E3F"
        \\red = "#bf616a"
        \\
        \\[[keyboard.bindings]]
        \\key = "N"
        \\mods = "Control|Shift"
        \\action = "CreateNewWindow"
        \\
        \\[[keyboard.bindings]]
        \\key = "Return"
        \\mods = "Control|Shift"
        \\action = "SpawnNewInstance"
        \\
    , fixture.plan.files.items[0].new);
}

test "set counts matches across a file: none, too many, and indices" {
    var fixture: Fixture = undefined;
    try fixture.init(".config/alacritty/alacritty.toml", alacritty_toml);
    defer fixture.deinit();
    var file = try fixture.output.edit(.{ .files = "~/.config/alacritty/alacritty.toml" });
    try testing.expectError(error.NoMatch, file.set("colors.primary.cursor", kosm.hex("ffffff")));
    try testing.expectError(error.TooManyMatches, file.set("colors.*.black", kosm.hex("000000")));
    try testing.expectError(error.IndexOutOfRange, file.setNth("colors.*.black", 2, kosm.hex("000000")));
    try testing.expectError(error.NoMatch, file.set("keyboard.bindings.key", "M"));
    try file.setNth("colors.*.black", 1, kosm.hex("000000"));
    try testing.expect(std.mem.indexOf(u8, fixture.plan.files.items[0].new, "[colors.bright]\nblack = \"#000000\"") != null);
}

test "arrays of tables are reached through elements" {
    var fixture: Fixture = undefined;
    try fixture.init(".config/alacritty/alacritty.toml", alacritty_toml);
    defer fixture.deinit();
    var file = try fixture.output.edit(.{ .files = "~/.config/alacritty/alacritty.toml" });
    const bindings = try file.nodes("keyboard.bindings");
    try testing.expectEqual(1, bindings.len);
    const elements = try file.elements(bindings[0]);
    try testing.expectEqual(2, elements.len);
    try testing.expectEqual(.table, elements[1].kind);
    try testing.expectEqual(34, elements[1].line);
    const imports = try file.elements((try file.nodes("general.import"))[0]);
    try file.replace(imports[0], "~/.config/alacritty/theme.toml");
    try testing.expect(std.mem.indexOf(u8, fixture.plan.files.items[0].new, "import = [\"~/.config/alacritty/theme.toml\"]") != null);
}

const vicinae_theme =
    \\[meta]
    \\name = "Ricer"
    \\variant = "dark"
    \\inherits = "vicinae-dark"
    \\
    \\[colors.core]
    \\accent = "041C26-highlight"
    \\background = "041C26"
    \\
    \\[colors.main_window]
    \\border = "2D8699"
    \\footer = { background = "colors.core.secondary_background" }
    \\
    \\# For now, shortcuts cannot have their own dedicated background
    \\[colors.shortcut]
    \\border = "colors.core.border"
    \\
    \\[colors.text]
    \\default = "colors.core.foreground"
    \\selection = { background = "colors.core.foreground", foreground = "colors.core.background" }
    \\
    \\[colors.text.links]
    \\default = "2D998F"
    \\
;

test "a vicinae theme's colors are set by path, in sections and inline tables" {
    var fixture: Fixture = undefined;
    try fixture.init(".local/share/vicinae/themes/kosm.toml", vicinae_theme);
    defer fixture.deinit();
    var theme = try fixture.output.edit(.{ .files = "~/.local/share/vicinae/themes/kosm.toml" });
    const background = kosm.hex("102840");
    try theme.set("colors.core.background", background.format("{}", &.{.hex_upper}));
    try theme.set("colors.text.selection.foreground", "colors.core.foreground");
    try theme.set("colors.text.links.default", "5E81AC");
    try theme.set("colors.main_window.footer.background", "colors.core.background");
    try testing.expectEqualStrings(
        \\[meta]
        \\name = "Ricer"
        \\variant = "dark"
        \\inherits = "vicinae-dark"
        \\
        \\[colors.core]
        \\accent = "041C26-highlight"
        \\background = "102840"
        \\
        \\[colors.main_window]
        \\border = "2D8699"
        \\footer = { background = "colors.core.background" }
        \\
        \\# For now, shortcuts cannot have their own dedicated background
        \\[colors.shortcut]
        \\border = "colors.core.border"
        \\
        \\[colors.text]
        \\default = "colors.core.foreground"
        \\selection = { background = "colors.core.foreground", foreground = "colors.core.foreground" }
        \\
        \\[colors.text.links]
        \\default = "5E81AC"
        \\
    , fixture.plan.files.items[0].new);
}

test "dotted keys, quoted keys and multi-line strings are edited in place" {
    var fixture: Fixture = undefined;
    try fixture.init("config.toml",
        \\window.dimensions.columns = 80
        \\"dim.foreground" = "#828482"
        \\banner = """
        \\first line
        \\second "line"
        \\"""
        \\after = 'kept'
        \\
    );
    defer fixture.deinit();
    var file = try fixture.output.edit(.{ .files = "~/config.toml" });
    try file.set("window.dimensions.columns", 100);
    try file.set("\"dim.foreground\"", kosm.hex("ffffff"));
    try file.set("banner", "one line");
    try testing.expectError(error.NoValue, file.set("window.dimensions", 1));
    try testing.expectEqualStrings(
        \\window.dimensions.columns = 100
        \\"dim.foreground" = "#ffffff"
        \\banner = "one line"
        \\after = 'kept'
        \\
    , fixture.plan.files.items[0].new);
}

test "an unchanged value leaves the file unwritten" {
    var fixture: Fixture = undefined;
    try fixture.init(".config/alacritty/alacritty.toml", alacritty_toml);
    defer fixture.deinit();
    var file = try fixture.output.edit(.{ .files = "~/.config/alacritty/alacritty.toml" });
    try file.set("colors.normal.red", kosm.hex("80333c").format("#{}", &.{.hex_upper}));
    try testing.expect(!fixture.plan.hasChanges());
}

test "a file TOML would reject is an error naming the file and line" {
    var fixture: Fixture = undefined;
    try fixture.init("bad.toml", "[a]\nx = 1\n[a]\n");
    defer fixture.deinit();
    try testing.expectError(error.InvalidSyntax, fixture.output.edit(.{ .files = "~/bad.toml" }));
    try testing.expect(std.mem.indexOf(u8, fixture.diagnostics.message(), "line 3: table [a] is defined twice, first on line 1") != null);
}

test "a block of values keeps the user's own lines around it" {
    var fixture: Fixture = undefined;
    try fixture.init("config.toml", "[general]\nlive_config_reload = true\n");
    defer fixture.deinit();
    try fixture.output.block(.{ .file = "~/config.toml", .id = "colors" }, kosm.Value{ .table = &.{
        .{ .key = "colors", .value = .{ .table = &.{.{ .key = "primary", .value = .{ .table = &.{
            .{ .key = "background", .value = .{ .color = try kosm.Color.parseHex("#041c26") } },
        } } }} } },
    } });
    try testing.expectEqualStrings(
        \\[general]
        \\live_config_reload = true
        \\# kosm:begin colors
        \\[colors.primary]
        \\background = "#041c26"
        \\# kosm:end
        \\
    , fixture.plan.files.items[0].new);
}
