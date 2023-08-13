// Positionals will be handled by parse_args
// @TODO: prevent dashs in tokenise step
// @TODO: Generate a perfect hash table at comptime for faster arg parsing?
//        We might want to do linear search if size is less than 8 or something
// @TODO: turn off warnings :warning:

const std = @import("std");
const expect = std.testing.expect;

const field_path = @import("field_path.zig");
const tokenise = @import("s1_tokenise.zig");
const util = @import("util.zig");

// ARGS_MAX is a thing, this should be able to hold at least ARGS_MAX
// @TODO: do we want to support "usize" arguments?
const ArgIndex = usize;
const ArgItem = []u8;
const ArgList = []ArgItem; // @TODO: Do I want to use [][:0]u8 or [][]u8?

////////////////////////////////////////////////////////////////////////////////
// Consume Tokens - Parse Args
////////////////////////////////////////////////////////////////////////////////

pub fn contains(comptime T: type, comptime map_fn: fn (T) []const u8, comptime haystack: []T, needle: []u8) bool {
    inline for (haystack) |field| {
        if (std.mem.equal(needle, map_fn(field))) return true;
    }
    return false;
}

// run: zig run main.zig -- --baz 20000000000000000000000000000000000000000000000
// run: zig run -freference-trace main.zig -- hello asdfasdf --bar 10 qwer2
//run: zig build test -freference-trace

const ParseArgError = error{
    MissingArguments,
    TODO,
};
const ParseError = ParseArgError || std.fmt.ParseFloatError || std.fmt.ParseIntError;

const TestError = struct { ParseError, []const u8 };

pub fn parseArgs(comptime Spec: type, s: *Spec, args: [][]u8) ?TestError {
    // @TODO: to save allocations, cast this as slice of nullable strings -- @ptrCast([]?[*:0]u8, args)
    //        1. Mark parsed arguments as null
    //        2. Compact the array on a second pass to leave only the positionals?

    const spec = comptime tokenise.unwrap_tokenise_result(tokenise.tokenise(Spec, &[0][]u8{}));

    if (true) {
        inline for (spec.options) |a| {
            switch (a.completion) {
                .Auto => |list| {
                    for (list) |c| {
                        std.debug.print("- completion option: |{s}|\n", .{c});
                    }
                },
                .Func => |f| {
                    for (f()) |c| {
                        std.debug.print("- completion option: |{s}|\n", .{c});
                    }
                },
                //std.debug.print("{?}\n", .{@call(std.builtin.CallModifier {}, b, .{})});
                //std.debug.print("{?}\n", .{b()});
            }
        }
        //return .{ .Ok = ret };
    }

    //var ret: T = undefined;
    //// Not sure if there is a nice, non-brittle way to initialise a struct
    //// We only need this so that the print function does not try to deref 0xAA pointers in debug
    //// @TODO: check if double nested submodules can be printed?
    //if (spec.subcommand_path) |path| field_path.pointToField(T, &ret, path).Ok.* = null;
    //inline for (spec.options) |option_spec| {
    //    if (option_spec.is_optional) {
    //        const ptr = field_path.pointToField(T, &ret, option_spec.param_path).Ok;
    //        ptr.* = null;
    //    }
    //    //std.debug.print("\n", .{});
    //}

    if (parse_module(Spec, spec, s, args)) |test_error| {
        std.debug.print("aldfslkjadsklfjasdkljf\n", .{});
        std.debug.print("{} {s}\n", .{ test_error[0], test_error[1] });
    }
    return null;
    //return .{ .Ok = ret };
}

pub fn parse_module(comptime Spec: type, comptime mod: tokenise.TokenisedSubcommand, ret: *Spec, args: ArgList) ?TestError {
    const Field = struct { enum { Subcommand, Option }, ArgIndex, ArgItem };

    // @TODO: Look into iterator syntax?
    const ArgCursor = struct {
        start: ArgIndex,

        const Self = @This();
        /// Here field means a subcommand or option
        fn find_next_field(cursor: *Self, all_args: [][]u8) struct { close: ArgIndex, next_field: ?Field } {
            const remaining = all_args[cursor.start..];
            for (0.., remaining) |i, arg| {
                if (std.mem.startsWith(u8, arg, "--")) {
                    inline for (0.., mod.options) |field_index, opt| {
                        if (std.mem.eql(u8, arg[2..], opt.name)) {
                            return .{ .close = cursor.start + i, .next_field = .{ .Option, field_index, arg } };
                        }
                    }
                    std.debug.panic("TODO", .{});
                } else {
                    inline for (0.., mod.subcommands) |field_index, subcmd| {
                        if (std.mem.eql(u8, arg, subcmd.name())) {
                            return .{ .close = cursor.start + i, .next_field = .{ .Subcommand, field_index, arg } };
                        }
                    }
                }
            }
            return .{ .close = cursor.start + remaining.len, .next_field = null };
        }
    };
    const ParseFSM = enum {
        WaitingForSubcommand,
        SeenSubcommand,
    };

    var cursor = ArgCursor{ .start = 0 };
    var curr_field: ?Field = null;
    var fsm = ParseFSM.WaitingForSubcommand;
    for (args) |_| { // Cap the number of calls to the iterable
        const partition = cursor.find_next_field(args);
        const curr_args = args[cursor.start..partition.close];
        _ = curr_args;

        //const random_results = false;

        // First iteration we start with null and for any iteration where the
        // field was eaten by the previous iteration.
        //
        // A %[partition] is ordering of the following:
        //
        // * starting with the field ("--option" or "subcommand"), except first
        //   in the cases of null as described above
        // * any number of arguments from %[args] before %[partition.next_field]
        // * %[partition.next_field]
        //
        // If the next_field is eaten, the the next partition's curr_field will
        // be `null`
        const is_next_field_eaten = if (curr_field) |field| next: {
            const rt_i = field[1];
            //_ = rt_i;
            const positionals = args[cursor.start..partition.close];
            inline for (0.., mod.options) |ct_i, option_spec| {
                const next_item = if (partition.next_field) |next| next[2] else null;
                if (ct_i == rt_i) {
                    if (move_cursor_post_field_parse(&cursor.start, Spec, ret, option_spec, positionals, next_item)) |err| return err;
                }
            }
            break :next false;
        } else false;

        // Subcommands can only be the first positional
        switch (fsm) {
            .WaitingForSubcommand => {
                if (args[cursor.start..].len == 0) {
                    if (partition.next_field) |field| {
                        switch (field[0]) {
                            .Option => {},
                            .Subcommand => {
                                std.debug.panic("TODO: call parseModule(with cursor.start + 1)", .{});
                                return null;
                            },
                        }
                    }
                } else if (mod.is_optional) {
                    fsm = .SeenSubcommand;
                    field_path.pointToField(Spec, ret, mod.subcommand_path.?).Ok.* = null;
                } else {
                    std.debug.print("required: {s} {}\n", .{ @typeName(Spec), mod.is_optional });
                    return .{ ParseError.TODO, "Subcommand is required" };
                }
            },
            .SeenSubcommand => {},
        }

        for (args[cursor.start..partition.close]) |arg| {
            std.debug.print("positional: {s}\n", .{arg});
        }

        curr_field = if (is_next_field_eaten) null else partition.next_field;
        cursor.start = partition.close + 1; // skip %[partition.next_field]
        if (cursor.start >= args.len) break;
    }
    return null;
}

/// You have three types of arguments
/// * Eat one argument, e.g. int, string. This could eat the optional %[next_item],
///   in which case the control flow function should not parse it
/// * Booleans that eat zero arguments
/// * Arrays that do not touch %[next_item]
pub fn move_cursor_post_field_parse(
    cursor: *ArgIndex,
    comptime Spec: type,
    s: *Spec,
    comptime field_spec: tokenise.FieldToken, // First item
    partition: ArgList,
    next_item: ?ArgItem,
) ?TestError {
    std.debug.assert(partition.len >= 1);
    const procure_one_argument = struct {
        fn f(list: []ArgItem, next: ?ArgItem, field_name: []const u8) ?ArgItem {
            if (list.len == 0) {
                // :warning:
                if (next) |item| std.debug.print("Warning: you did not provide an argument for --{s} and we are using {s}\n", .{ field_name, item });
                return next;
            } else {
                std.debug.assert(list.len >= 1);
                return list[0];
            }
        }
    }.f;
    const missing_arg_message = std.fmt.comptimePrint("--{s} requires an argument of type {s}", .{ field_spec.name, field_spec.type_name });

    const field_pointer = field_path.pointToField(Spec, s, field_spec.param_path).Ok;
    //std.debug.print("hello {s}\n", .{@tagName(field_spec.type_spec)});
    switch (field_spec.type_spec) {
        inline .Int => |info| {
            std.debug.print("hello asdklfjladkjsf\n", .{});
            const arg = procure_one_argument(partition, next_item, field_spec.name) orelse return .{ ParseError.MissingArguments, missing_arg_message };
            cursor.* += 1;

            const ty = @Type(.{ .Int = info });
            const num = std.fmt.parseInt(ty, arg, 10) catch |err| {
                std.debug.assert(err == std.fmt.ParseIntError.Overflow or err == std.fmt.ParseIntError.InvalidCharacter);
                return .{ .Err = .{ err, std.fmt.comptimePrint("--" ++ field_spec.name ++ " requires a number argument between {d} and {d}", .{
                    std.math.minInt(ty),
                    std.math.maxInt(ty),
                }) } };
            };
            field_pointer.* = num;
        },
        //.Float => {
        //    const next = eatNext(i, partition) orelse return TestError{ ParseError.MissingArguments, missing_arg_message };
        //    const num = switch (info.bits) {
        //        16 => std.fmt.parseFloat(f16, next),
        //        32 => std.fmt.parseFloat(f32, next),
        //        64 => std.fmt.parseFloat(f64, next),
        //        80 => std.fmt.parseFloat(f80, next),
        //        128 => std.fmt.parseFloat(f128, next),
        //        else => @compileError("Not a valid float type"),
        //    } catch |err| {
        //        std.debug.assert(err == std.fmt.ParseFloatError.InvalidCharacter);
        //        return TestError{ ParseError.InvalidCharacter, "--" ++ field_spec.name ++ " cannot parse its argument." };
        //    };
        //    field_pointer.* = num;
        //}
        inline .Bool => field_pointer.* = true,
        inline .Item => {
            const arg = procure_one_argument(partition, next_item, field_spec.name) orelse return .{ ParseError.MissingArguments, missing_arg_message };
            cursor.* += 1;
            field_pointer.* = arg;
        },
        else => @compileError("@TODO: '" ++ field_spec.type_name ++ "' arguments refied by '" ++ @tagName(field_spec.type_spec) ++ "' are currently unsupported."),
    }
    //_ = parse_positionals(args[cursor..]);
    //return .{ .Ok = is_next_eaten };
    return null;
}

////////////////////////////////////////////////////////////////////////////////
// Algebraic-type-like result type
////////////////////////////////////////////////////////////////////////////////

// This also serves as a use-case
pub fn print_parsed_struct(comptime T: type, s: *const T) void {
    const spec = comptime tokenise.unwrap_tokenise_result(tokenise.tokenise(T, &[0][]u8{}));

    const indent = 1;
    std.debug.print("{{\n", .{});
    if (spec.subcommand_path) |path| {
        std.debug.print("  " ** (indent * 2), .{});
        //std.debug.print("!subcmd: {s}\n", .{ cmd.name()});
        const ptr = field_path.pointToField(T, @constCast(s), path).Ok;
        std.debug.print("!subcommand {s}: ", .{path[path.len - 1]});
        if (ptr.*) |subcommand|
            std.debug.print("{!}\n", .{subcommand})
        else
            std.debug.print("null\n", .{});
    }
    inline for (spec.options) |option| {
        std.debug.print("  " ** (indent * 2), .{});
        std.debug.print("{s}: ", .{option.name});
        const v = field_path.pointToField(T, @constCast(s), option.param_path).Ok.*;

        switch (option.type_spec) {
            .Bool => std.debug.print("{s}", .{if (option.is_optional) (if (v) |_| "true" else "null") else "true todo"}),
            .Int => std.debug.print("{?}", .{v}),
            .Float => std.debug.print("{d}", .{v}),
            .Enum => std.debug.print("{s}", .{v}),
            .Item => {
                if (option.is_optional) {
                    if (v) |optional_some|
                        //std.debug.print("{s}", .{"TODO how to handle undefined (0xAA)?"})
                        std.debug.print("{s}", .{optional_some})
                    else
                        std.debug.print("null", .{});
                } else std.debug.print("{}\n", .{v});
            },
            .ItemList => @compileError("TODO: " ++ @tagName(option.type_spec)),
            .ItemUnboundList => @compileError("TODO: " ++ @tagName(option.type_spec)),
        }
        std.debug.print("\n", .{});
        //std.debug.print("{s}: {?}\n", .{ option.name, field_path.pointToField(T, @constCast(s), option.param_path).Ok.* });
    }
    std.debug.print("}}\n", .{});
}

////////////////////////////////////////////////////////////////////////////////
// Consume Tokens - Help
////////////////////////////////////////////////////////////////////////////////

fn printHelpLine(
    is_print_type: bool,
    field: []const u8,
    field_type: []const u8,
    description: []const u8,
    comptime name_padding: []const u8,
    comptime type_padding: []const u8,
) void {
    if (is_print_type) {
        std.debug.print("{s: <" ++ name_padding ++ "}   {s: <" ++ type_padding ++ "}   {s}\n", .{ field, field_type, description });
    } else {
        std.debug.print("{s: <" ++ name_padding ++ "}   {s}\n", .{ field, description });
    }
}

//const helper = struct {[]const u8};

pub fn help(comptime Spec: type, name: []const u8, config: tokenise.Config) void {
    //const fields = @typeInfo(Spec).Struct.fields;
    //const asdf = helper{""};
    const spec = comptime tokenise.unwrap_tokenise_result(tokenise.tokenise(Spec, .{}));

    const lens = comptime lens: { // @TODO: Do we want to do ut8 grapheme terminal len?
        var max_field: usize = 0;
        var max_type: usize = 0;
        inline for (spec.ast.subcommands) |cmd| {
            max_field = @max(max_field, cmd.struct_path[cmd.struct_path.len - 1].len);
        }
        inline for (spec.ast.options) |opt| {
            max_field = @max(max_field, opt.name.len + 1); // + 1 for '-'
            max_type = @max(max_type, opt.type_name.len);
        }
        break :lens .{ comptimeIntToString(max_field), comptimeIntToString(max_type) };
    };

    std.debug.print("Usage: {s}\n", .{name});

    if (spec.ast.subcommands.len > 0) {
        std.debug.print("\nCommands:\n\n", .{});
        inline for (spec.ast.subcommands) |parsed_spec| {
            std.debug.print("  ", .{});
            //std.debug.print("{s}  ", .{parsed_spec.param_path});
            printHelpLine(config.help_print_types, parsed_spec.name(), "", parsed_spec.description, lens[0], lens[1]);
        }
    }

    if (spec.ast.options.len > 0) {
        std.debug.print("\nGeneral Options:\n\n", .{});
        inline for (spec.ast.options) |token| {
            std.debug.print("  -", .{});
            //std.debug.print("{s}  ", .{token.param_path});
            printHelpLine(config.help_print_types, token.name, token.type_name, token.description, lens[0], lens[1]);
        }
    }
}

////////////////////////////////////////////////////////////////////////////////
// Util functions

pub fn comptimeIntToString(comptime num: anytype) []const u8 {
    const LargestIntType = u128;
    const max_int: LargestIntType = std.math.maxInt(LargestIntType);
    const max_byte_count = std.math.log10_int(max_int) + 1; // signed int might be larger due to minus sign

    var as_base10_string: [max_byte_count]u8 = undefined;
    const len = std.fmt.formatIntBuf(&as_base10_string, num, 10, .lower, .{});
    return as_base10_string[0..len];
}

pub inline fn stackIntToString(comptime Num: type, num: Num) []const u8 {
    const max_int: Num = std.math.maxInt(Num);
    const max_byte_count = comptime std.math.log10_int(max_int) + 1; // signed int might be larger due to minus sign

    var as_base10_string: [max_byte_count]u8 = undefined;
    const len = std.fmt.formatIntBuf(&as_base10_string, num, 10, .lower, .{});
    return as_base10_string[0..len];
}

// run: zig test %
