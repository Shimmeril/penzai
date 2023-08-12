// @TODO: Register-ArgumentCompleter for powershell usage

const std = @import("std");
// Compile-time error
const tokenise = @import("tokenise.zig");
const field_path = @import("field_path.zig");

// Consume tokenise
const cli_parse = @import("cli_parse.zig");
const autocomplete = @import("autocomplete.zig");
const autocomplete_tests = @import("autocomplete_tests.zig");
const util = @import("util.zig");

const fs = std.fs;

// Define a struct with some fields
const MyStruct = struct {
    fooasdf: ?union {
        hello: struct {
            __help: []const u8 = "this is a a sample",

            opt__help: []const u8 = "this is a sample",
            opt: ?u8,
        },
    },

    comptime bar__help: []const u8 = "stuff to do",
    bar: ?bool,

    comptime baz__help: []const u8 = "yoyo",
    comptime baz__comp: autocomplete.CompletionFunction = struct {
        fn comp(_: std.mem.Allocator) []const []const u8 {
            return &[_][]const u8{"hello", "world"};
        }
    }.comp,
    // @NOTE: try experimenting with different usizes, causes this to fail on print("{!}")
    baz: ?u8 = null,
};

// compline test cases:
// penzai hello a <tab>    -> |../zig-out/src| |penzai| ||      |a|
// penzai hello a\ <tab>b  -> |../zig-out/src| |penzai| |a\ |   |hello|
// penzai hello "a <tab>   -> |../zig-out/src| |penzai| |a |    |hello|
// penzai hello "a\ <tab>  -> |../zig-out/src| |penzai| |a\ |    |hello|
// penzai hello "a b"<tab> -> |../zig-out/src| |penzai| |a b|   |hello|
// penzai hello "a b"<tab> -> |../zig-out/src| |penzai| |"a b"| |hello|


// run: zig build run -- hello asdfasdf --bar 10 qwer2
// run: zig run main.zig -- --baz 155 a b c
//run: zig build test -freference-trace

// @TODO: to just make auto completion work

const Config = struct {
    const warn_unmatched_options = true;
};
const ParseArgError = error{
    MissingArguments,
    TODO,
};
const ParseError = ParseArgError || std.fmt.ParseFloatError || std.fmt.ParseIntError;

pub fn parse_args(comptime Spec: type, ret: *Spec, args: util.IterToString) ?ClapErr {
    const spec = comptime tokenise.unwrapTokeniseResult(tokenise.tokeniseStruct(Spec, &[0][]u8{}));
    return parse_module(Spec, spec, ret, args);
}

// @TODO: standarise on either module or subcommand terminology
// Should be monomorphised to one function per module %[mod]
// @TODO: Maybe this can be monomorphised to only one function per spec if we
//        spec if
pub fn parse_module(comptime Spec: type, comptime mod: tokenise.TokenisedSpec, ret: *Spec, arg_iter: util.IterToString) ?ClapErr {
    var bound_index: u16 = 0;
    var i: u16 = 0;
    var is_subcommand_seen = false;
    var peek = arg_iter.next();
    outer: while (peek) |arg| : (bound_index += 1) {
        const upper_bound = 30000;
        if (bound_index > upper_bound) std.debug.panic("Exceed runtime bound of {d}", .{upper_bound});

        const is_positional = blk: {
            if (std.mem.startsWith(u8, arg, "--")) {
                switch (parse_all_options(Spec, mod.options, ret, arg[2..], arg_iter)) {
                    .Ok => |x| {
                        peek = x.peek;
                        break :blk x.is_positional;
                    },
                    .Err => |err| return err,
                }
                const x = parse_all_options(Spec, mod.options, ret, arg[2..], arg_iter);
                peek = x.Ok.peek;
                break :blk x.Ok.is_positional;
            } else if (!is_subcommand_seen) {
                inline for (0.., mod.subcommands) |field_index, subcmd| {
                    if (std.mem.eql(u8, arg, subcmd.name())) {
                        is_subcommand_seen = true;
                        _ = field_index;
                        //parse_module(Spec)
                        peek = null;
                        break :outer;
                        //return .{ .close = cursor.start + i, .next_field = .{ .Subcommand, field_index, arg } };
                    }
                }
                break :blk true;
            } else {
                break :blk true;
            }
        };

        if (is_positional) {
            peek = null;
            const index = i;
            i += 1;
            std.debug.print("Positional arg {d}: {s}\n", .{ index, arg });
        }

        if (peek == null) peek = arg_iter.next();
    }
    return null;
}

const ClapOk = struct {
    is_positional: bool,
    peek: ?util.IterToString.Item,
};

const ClapErr = struct {
    err: ParseError,
    completion_options:  []const []const u8,
    message: []const u8,
};

const Result = union(util.Result) {
    Ok: ClapOk,
    Err: ClapErr,
};
    

// @TODO: make this monomorphise to only one instance by putting all fields
//        in a single array and having the tokenise.TokenisedSpec instead use
//        subarrays into this larger array
fn parse_all_options(
    comptime Spec: type,
    comptime options_spec: []const tokenise.FieldToken,
    s: *Spec,
    name: []const u8,
    arg_iter: util.IterToString,
) Result {
    inline for (0.., options_spec) |j, opt| {
        _ = j;
        if (std.mem.eql(u8, opt.name, name)) {
            std.debug.print("Set optional: {s}\n", .{opt.name});
            return parse_option(Spec, opt, s, arg_iter);
        }
    }
    if (Config.warn_unmatched_options) std.debug.print("unmatched option: {s}{s}", .{ "--", name });
    return .{ .Ok = .{ .is_positional = true, .peek = null } };
}


//inline fn next(arg_iter: util.IterToString, completion_options: []const []const u8) Result  {
inline fn next(arg_iter: util.IterToString, comptime option_spec: tokenise.FieldToken) union(util.Result) { Ok: util.IterToString.Item, Err: ClapErr }  {
    //return if (arg_iter.next()) |arg| .{ .Ok = .{
    //    .is_positional = undefined,
    //    .peek = arg,
    //} } else .{ .Err = .{

    //_ = option_spec;
    return if (arg_iter.next()) |arg| .{ .Ok = arg } else .{ .Err = .{
        .err = ParseError.MissingArguments,
        // @TODO: do we want to .always_inline?
        .completion_options = option_spec.completion_function(std.heap.page_allocator),
        //.completion_options = @call(.auto, option_spec.completion.*, .{}),
        .message = "Not enough arguments",
    } };
}

//inline fn errorify(comptime T: type, result: T) error{ NeverUse }!field_path.select_field_type_by_name(T, "Ok").Ok {
//    std.debug.assert(@typeInfo(T).Union.tag_type.? == util.Result);
//    return switch (result) {
//        .Ok => |x| x,
//        .Err => .NeverUse,
//    };
//}

// Reduce right drift
inline fn parse_option(
    comptime Spec: type,
    comptime option_spec: tokenise.FieldToken,
    s: *Spec,
    arg_iter: util.IterToString,
) Result {
    const field_pointer = field_path.pointToField(Spec, s, option_spec.param_path).Ok;
    switch (option_spec.type_spec) {
        inline .Int => |info| {
            const arg = switch (next(arg_iter, option_spec)) {
                .Ok => |x| x,
                .Err => |err| return .{ .Err = err },
            };
            std.debug.print("arg: |{s}|\n", .{arg});
            const ty = @Type(.{ .Int = info });
            const num = std.fmt.parseInt(ty, arg, 10) catch |err| {
                std.debug.assert(err == std.fmt.ParseIntError.Overflow or err == std.fmt.ParseIntError.InvalidCharacter);
                std.debug.print("{any}", .{option_spec.completion});
                return .{ .Err = .{
                    .err = err,
                    .completion_options = option_spec.completion_function(std.heap.page_allocator),
                    .message = std.fmt.comptimePrint("--" ++ option_spec.name ++ " requires a number argument between {d} and {d}", .{
                        std.math.minInt(ty),
                        std.math.maxInt(ty),
                    })
                } };
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
        //        return TestError{ ParseError.InvalidCharacter, "--" ++ option_spec.name ++ " cannot parse its argument." };
        //    };
        //    field_pointer.* = num;
        //}
        inline .Bool => field_pointer.* = true,

        inline .Item => switch (next(arg_iter, option_spec)) {
            .Ok => |arg| field_pointer.* = arg,
            .Err => |err| return .{ .Err = err },
        },
        else => @compileError("@TODO: '" ++ option_spec.type_name ++ "' for --" ++ option_spec.name ++ " are currently unsupported."),
    }
    return .{ .Ok = .{ .is_positional = false, .peek = null } };
}

////////////////////////////////////////////////////////////////////////////////
fn handle_comp_line(comptime Spec: type, writer: anytype, info: autocomplete.AutoCompleteInfo)!void {
    if (true) {
        // For debugging run `mkfifo "test"`. You can see output by `tail -f "test"`
        var buf: [10000]u8 = undefined;
        _ = try writer.write(try info.printBuf(&buf));
    }

    if (std.mem.eql(u8, info.COMP_TYPE, "64")) { // State after first Tab
        var iter_state = autocomplete.CompLineIter{ .comp_line = info.comp_str };
        const iter = iter_state.iterator_interface();

        const program_name = iter.next(); // Skip the name of the auto completion keyword (usually the name the program, not an argument that is meant to be processed)
        _ = program_name;

        var clap: Spec = undefined; 
        init_clap_struct(MyStruct, &clap);
        if (parse_args(Spec, &clap, iter)) |err| {
            // NOTE: to see an example of proper output do `compgen -A file` in bash
            _ = try writer.write("\n=== completion options ===\n");
            for (err.completion_options) |entry| {
                _ = try writer.write(entry);
                _ = try writer.write("\n");
            }
        }
        //while (iter.next()) |x| {
        //    _ = try writer.write("|");
        //    _ = try writer.write(x);
        //    _ = try writer.write("| ");
        //}
        //_ = try writer.write("\n");
        //parse_args(MyStruct, &parsed_args, iter);
        //parse_args(MyStruct, &parsed_args, iter);

    } else if (std.mem.eql(u8, info.COMP_TYPE, "63")) { // State after first Tab
        // Do not do anything
    } else {}
}

fn parse_command_line(comptime Spec: type, clap: *Spec, args: []const [:0]const u8)void {
    const program_name = args[0][if (std.mem.lastIndexOf(u8, args[0], "/")) |slash_idx| slash_idx + 1 else 0..];
    if (true) cli_parse.help(MyStruct, program_name, true);

    var iter_state = util.ArrayIter{ .dynamic_array = args };
    const iter = iter_state.iterator_interface();
    _ = iter.next(); // Skip $0, name of program

    if (parse_args(Spec, clap, iter)) |err| {
        // @TODO: print help
        std.debug.print("{s}", .{err.message});
        std.process.exit(1);
    }
}



/// In debug mode we initialise to 0xAA for all values, when using
/// cli_parse.printParsedStruct() or indeed any regular usage, this will error
/// on null pointers
fn init_clap_struct(comptime Spec: type, clap: *Spec) void {
    const spec = comptime tokenise.unwrapTokeniseResult(tokenise.tokeniseStruct(Spec, &[0][]u8{}));

    // @TODO: check if this is optional or not, if not then do not assign null
    field_path.pointToField(Spec, clap, spec.subcommand_path.?).Ok.* = null;

    inline for (spec.options) |option_spec| {
        if (option_spec.is_optional) {
            field_path.pointToField(Spec, clap, option_spec.param_path).Ok.* = null;
        }
        //std.debug.print("\n", .{});
    }
}

test "hello" {
    std.debug.print("=\n", .{});

    _ = autocomplete_tests; // Include this as a target for refAllDeclsRecursive

    std.testing.refAllDeclsRecursive(@This());
}

test "main" {
    if (true) {
        const info = comptime autocomplete.construct_completion("penzai --baz \t", "64");
        try handle_comp_line(MyStruct, std.io.getStdErr(), info);

    } else {
        if (std.os.getenv("COMP_LINE")) |_| {
            // This will stall if you do not have something reading the fifo pipe
            const fifo_pipe = try std.fs.cwd().openFile("test", .{ .mode = fs.File.OpenMode.write_only });
            defer fifo_pipe.close();

            const info = autocomplete.AutoCompleteInfo.from_env();
            try handle_comp_line(MyStruct, fifo_pipe, info);
            std.process.exit(0);
        }

        const allocator = std.heap.page_allocator;
        const args = try std.process.argsAlloc(allocator);
        defer std.process.argsFree(allocator, args);

        var clap: MyStruct = undefined;
        init_clap_struct(MyStruct, &clap);
        parse_command_line(MyStruct, &clap, args);
        cli_parse.print_parsed_struct(MyStruct, &clap);
        //_ = parsed_args;
    }

    std.debug.print("=== Exit 0 ===\n\n", .{});
}

