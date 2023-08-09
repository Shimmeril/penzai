//run: zig build test
// run: zig test % --test-filter ending_with_whitespace

const std = @import("std");
const util = @import("util.zig");

pub const CompletionFunction = fn (allocator: std.mem.Allocator) []const []const u8;


pub fn enum_names(comptime Enum: type)[]const []const u8 {
    const fields = @typeInfo(Enum).Enum.fields;
    var names: [fields.len][]const u8 = undefined;
    inline for (0.., fields) |i, field| {
        names[i] = field.name;
    }
    return &names;
}

// Must be inline as we are giving pointers to data iternal to us
pub fn enum_completion(comptime names: []const []const u8) CompletionFunction {
    return struct {
        fn f(_: std.mem.Allocator) []const []const u8 {
            return names;
        }
    }.f;
}


pub const AutoCompleteInfo = struct {
    COMP_KEY: []const u8, // Key used to invoke completion
    COMP_LINE: []const u8, // Full
    COMP_POINT: usize, // Index of where COMP_KEY was pressed

    // From the bash manual
    //   (9)  TAB: normal completion
    //   (63) ?: listing completions after successive tabs
    //   (33) !: listing alternatives on partial word completion
    //   (64) @: listing completions if the word is not unmodified
    //   (37) %: menu completion
    COMP_TYPE: []const u8,
    COMP_WORDBREAKS: []const u8,
    comp_str: []const u8,

    const Self = @This();

    pub fn from_env() Self {
        var ret: AutoCompleteInfo = undefined;
        inline for ([_][]const u8{"COMP_LINE", "COMP_WORDBREAKS", "COMP_KEY", "COMP_TYPE"}) |var_name| {
            @field(ret, var_name) = std.os.getenv(var_name) orelse "";
        }
        const comp_point = std.fmt.parseInt(usize, (std.os.getenv("COMP_POINT") orelse unreachable), 10) catch ret.COMP_LINE.len;
        ret.COMP_POINT = comp_point;

        ret.comp_str = ret.COMP_LINE[0..comp_point];
        return ret;
    }

    const FormatString =
        \\COMP_KEY:        |{s}|
        \\COMP_LINE:       |{s}|
        \\COMP_POINT:      |{d}|
        \\COMP_TYPE:       |{s}|
        \\COMP_WORDBREAKS: |{s}|
        \\
    ;
    pub fn count(self: Self)u64 {
        return std.fmt.count(Self.FormatString, .{self.COMP_KEY, self.COMP_LINE, self.COMP_POINT, self.COMP_TYPE, self.COMP_WORDBREAKS});
    }
    pub fn printBuf(self: Self, buf: []u8)![]const u8 {
        return std.fmt.bufPrint(buf, Self.FormatString, .{self.COMP_KEY, self.COMP_LINE, self.COMP_POINT, self.COMP_TYPE, self.COMP_WORDBREAKS});
    }
};


////////////////////////////////////////////////////////////////////////////////

// It would not be that much more work to support tab completion, but it
// it would be hard to do tests that robustly support unicode because, then
// we have to import something that can understand grapheme clusters.
// And even if we were to properly support grapheme clusters, terminal
// emulators are limited by the font they support
//
//   e.g. If the terminal emulator font does  not support woman + microscope
//   (which combines into a doctor emoji 2 spaces), then the amount of spaces
//   we have to move is 4 to the left instead of 2.
pub fn construct_completion(comptime input: []const u8, comptime comp_type: []const u8)AutoCompleteInfo {
    if (!@inComptime()) @compileError("Run this with comptime");
    // @TODO: debug assert there is only one tab
    if (!std.mem.endsWith(u8, input, "\t")) @compileError("%[input] must end with a tab");
    _ = std.fmt.parseInt(usize, comp_type, 10) catch |err| std.debug.panic("Please enter an natural number for comp_type. Parsing {s} yielded {?}", .{comp_type, err});

    var iter = std.mem.splitScalar(u8, input, '\t');
    const pre__tab = iter.next() orelse std.debug.panic("DEV: There is no tab in %[input]:\n    |{s}|", .{input});
    const post_tab = iter.next() orelse std.debug.panic("%[input] is missing a tab:\n    {s}", .{input});
    if (iter.next() != null) std.debug.panic("%[input] has more than one tab:\n    {s}", .{input});
    _ = post_tab;

    return .{
        .COMP_KEY = "9", // Tab
        .COMP_LINE = input[0..input.len - "\t".len],
        .COMP_POINT = pre__tab.len,
        .COMP_TYPE = comp_type,
        .COMP_WORDBREAKS = "",
        .comp_str = pre__tab,
    };
}


// Behaviour is to break on whitespace %[CompLineIter.IFS], accounting for
// quotes and escaping with backslash as per POSIX. Additionally, we want to
// provide the empty string as last if there is whitespace at the end because
// the behaviour for autocompleting "cmd a" (limit search space to 'a') and
// "cmd a " (no limit on search space) is different.
pub const CompLineIter = struct {
    const Self = @This();
    // Also using this as the counter
    comp_line: []const u8,
    cursor: usize = 0,
    state: enum {
        Whitespace,
        Base,
        SingleQuote,
        DoubleQuote,
    } = .Whitespace,
    pub fn iterator_interface(self: *Self) util.IterToString {
        return util.IterToString.init(Self, self);
    }

    // POSIX 2018 spec
    // https://pubs.opengroup.org/onlinepubs/9699919799/utilities/V3_chap02.html#tag_18_06_05
    const IFS = &[_]u8{'\n', '\t', ' '};

    pub fn impl_next(self: *Self) ?util.IterToString.Item {
        // @TODO IFS instead of defined character set?
        var i = self.cursor;
        _ = 1;

        while (i < self.comp_line.len) : (i += 1) {
            const c = self.comp_line[i];
            //std.debug.print("next {d} {d} {d} {s} |{s}|\n", .{self.cursor, i, self.comp_line.len, @tagName(self.state), self.comp_line[i..]});

            // Following is a switch statement in the spirit of a rust match
            // @TODO: Do table-driven parsing? Zig is probably pretty good generating the table
            if (false) {

            // @TODO: Lookup POSIX PEG spec for what are whitespace characters (probably ASCII-only)
            } else if (self.state == .Whitespace and std.mem.indexOfScalar(u8, IFS, c) != null) {
                self.cursor = i + 1;
                if (i + 1 >= self.comp_line.len) {
                    return self.comp_line[self.comp_line.len..self.comp_line.len];
                }
            //} else if (self.state == .Whitespace and c == '\\') {
            } else if (self.state == .Whitespace and c == '\'') {
                self.state = .SingleQuote;
                self.cursor = i;
            } else if (self.state == .Whitespace and c == '"') {
                self.state = .DoubleQuote;
                self.cursor = i;
            } else if (self.state == .Whitespace) {
                self.state = .Base;
                self.cursor = i;

            } else if (self.state == .Base and c == '\'') {
                self.state = .SingleQuote;
            } else if (self.state == .SingleQuote and c == '\'') {
                self.state = .Base;
            } else if (c == '\'') {
                unreachable;

            } else if (self.state == .Base and c == '"') {
                std.debug.print("Started a double quote\n", .{});
                self.state = .DoubleQuote;
            } else if (self.state == .DoubleQuote and c == '"') {
                self.state = .Base;
            } else if (self.state == .DoubleQuote and c == '\\') {
                i += 1;
            } else if (c == '"') {
                unreachable;

            } else if (self.state == .Base and c == '\\') {
                i += 1;
            } else if (self.state == .Base and c == ' ') {
                self.state = .Whitespace;
                const ret = self.comp_line[self.cursor..i];
                self.cursor = i;
                return ret;
            }
        }
        if (self.cursor < self.comp_line.len) {
            const ret = self.comp_line[self.cursor..];
            self.cursor = self.comp_line.len;
            return ret;
        } else return null;
    }
};

test "comp_line" {
    std.debug.print("=== comp_line ===\n", .{});
    const comp_lines = &[_][5][]const u8{
        // 0: line on your shell, 1-4: what bash passes when doing an command completion (complete -C) as CLI arguments
        [5][]const u8{"penzai hello a \t",    "../zig-out/src", "penzai", "",     "a"},
        [5][]const u8{"penzai hello a\\ ",    "../zig-out/src", "penzai", "a\\ ", "hello"},
        [5][]const u8{"penzai hello \"a ",    "../zig-out/src", "penzai", "a ",   "hello"},
        [5][]const u8{"penzai hello \"a\\ ",  "../zig-out/src", "penzai", "a\\ ", "hello"},
        [5][]const u8{"penzai hello \"a b\"", "../zig-out/src", "penzai", "a b",  "hello"},
    };
    for (comp_lines) |example| {
        // @TODO: I believe example[1] does not account for quotes and escaping.
        var iter = CompLineIter{ .comp_line = example[0][example[2].len..] };
        const iter_if = iter.iterator_interface();
        //var last_two = .{@as([]const u8, ""), @as([]const u8, "")};
        var last_two: struct {[]const u8, []const u8} = .{"", ""};
        while (iter_if.next()) |x| {
            //std.debug.print("debug {s}\n", .{x});
            last_two[0] = last_two[1];
            last_two[1] = x;
        }
        std.debug.print("last_two '{s}' '{s}' | '{s}'\n", last_two ++ .{example[0]});
    }
}

test "basic" {
    const example = "penzai asdf \\\\a a a\\  ";
    var asdf = CompLineIter{ .comp_line = example["penzai".len..] };
    const interface = asdf.iterator_interface();
    try std.testing.expectEqualStrings("asdf", interface.next() orelse "<null>");
    try std.testing.expectEqualStrings("\\\\a", interface.next() orelse "<null>");
    try std.testing.expectEqualStrings("a", interface.next() orelse "<null>");
    try std.testing.expectEqualStrings("a\\ ", interface.next() orelse "<null>");
    try std.testing.expectEqualStrings("", interface.next() orelse "<null>");
    try std.testing.expectEqual(@as(?[]const u8, null), interface.next());
}
