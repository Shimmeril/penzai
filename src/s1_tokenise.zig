//run: zig test %

const std = @import("std");
const Type = std.builtin.Type;
const expect = std.testing.expect;
 
const autocomplete = @import("autocomplete.zig");
const util = @import("util.zig");

/// @TODO: When struct tags are supported then we do not have to require descriptions
/// See: https://github.com/ziglang/zig/issues/1099
///
/// In your struct, you will have add help descriptions as so:
/// `const args = struct {
///     comptime a_example_field_desc = "A description of what this does",
///     a_example_field: u8,
/// }`
const DESC_TAG = "__help";
const COMP_TAG = "__comp";

fn hello(_: std.mem.Allocator)[]const []const u8 {
    return &.{"<comgen -A>"};
}
fn add_to_path(comptime T: type, comptime path: []const T, comptime addition: T) []const T {
    var new_path: [path.len + 1]T = undefined;
    inline for (0..path.len) |i| {
        new_path[i] = path[i];
    }
    new_path[path.len] = addition;
    return &new_path;
}


const ParsedType = enum {
    Bool,
    Int,
    Float,
    Enum,
    Item,
    ItemList,
    ItemUnboundList,
};
const ParsedTypeInfo = union(ParsedType) {
    Bool: void,
    Int: Type.Int,
    Float: Type.Float,
    // @TODO: I feel like std.builtin.Type.EnumField should be use a non comptime_int
    Enum: []const []const u8,
    Item, // String
    ItemList,
    ItemUnboundList,
};

const TokeniseErrorEnum = error{
    NotAStruct,
    MissingField,
    MissingDescription,
    DescriptionIsNotAString,
    DescriptionMissingDefaultValue,
    CompletionMissingDefaultValue,
    FieldIsAnInvalidType,

    TwoSubcommandFields,
    SubcommandIsNotAStruct,
    UnsupportedFieldType,
    //CompletionFunctionUnexpectedType,
};
const TokeniseError = struct { util.constructEnumFromError(TokeniseErrorEnum), []const u8 };
const TokeniseResult = union(util.Result) { Ok: TokenisedSubcommand, Err: TokeniseError };
const TokeniseSpec = struct {
    ast: TokenisedSubcommand,
    required_options: []const []const []const u8,
};
const TokenisedAstResult = union(util.Result) { Ok: TokeniseSpec, Err: TokeniseError };

pub const TokenisedSubcommand = struct {
    struct_path: []const []const u8,
    description: []const u8,
    subcommand_is_required: bool,
    subcommands: []const TokenisedSubcommand,
    options: []const TokenisedOption,

    //required_options: []const TokenisedOption = &[0]TokenisedOption{},
    //inherited_options: []const TokenisedOption = &[0]TokenisedOption{},

    pub fn name(comptime self: @This()) []const u8 {
        return if (self.struct_path.len == 0) "" else self.struct_path[self.struct_path.len - 1];
    }
};

pub const TokenisedOption = struct {
    type_spec: ParsedTypeInfo,
    type_name: []const u8,
    is_required: bool,
    name: []const u8,

    description: []const u8,
    completion: autocomplete.CompletionFunction,
    struct_path: []const []const u8,

    pub fn name(comptime self: @This()) []const u8 {
        return if (self.struct_path.len == 0) "" else self.struct_path[self.struct_path.len - 1];
    }
};


////////////////////////////////////////////////////////////////////////////////

/// This could be simplified by: https://github.com/ziglang/zig/issues/1099
/// Until we get tags for fields, are giving name suffixes special semantics
/// e.g. `foo__help: []const []const u8` is the help string for `foo: usize`
//
// Normally, we would have to `inline fn` as we are storing data inline.
// But for this it does not matter if inline or not as:
// - different specs/paths yield new functions with unique memory locations
// - it is pure (no side-effects), so running it twice yield the same result
pub fn tokenise(comptime Spec: type, comptime config: Config) TokenisedAstResult {
    const spec_info = if (@typeInfo(Spec) == .Struct) @typeInfo(Spec).Struct else return .{ .Err = .{ .NotAStruct, "The Spec for your command-line argument parser should be a struct." } };
    const field_len = spec_info.fields.len;
    // Because we support supplying optionals of a subcommand during any of its
    // child subcommands, we have have all subcommands retain copy of the
    // parent optionals. This means you have at most a triangle of options,
    // hence a max capacity of `n * n / 2`.
    var required_options: [field_len * field_len / 2][]const []const u8 = undefined;
    var len: usize = 0;
    switch (tokenise_module(Spec, .{&required_options, &len}, &.{}, &.{}, config)) {
        .Ok => |ok| return .{ .Ok = .{ .ast = ok, .required_options = required_options[0..len] } },
        .Err => |err| return .{ .Err = err },
    }
}

const FieldExtract = struct {
    // Outer/inner_type are for working with zig optionals which represent
    // whether an option argument is optional or required.
    // if `outer_type == inner_type`, then this option argument is required
    outer_type: type,
    inner_type: type,
    original_name: []const u8,
    // @TODO: prepend with prefix (e.g. '--')
    name: []const u8,
    default: ?*const anyopaque,
};

// @TODO: rethink this when we have struct tags
pub const Config = struct {
    replace_underscore_with_dash: bool = true,
    option_prefix: []const u8 = "-",
    help_print_types: bool = false,
};

fn handle_description(comptime extract: FieldExtract) union(util.Result) { Ok: []const u8, Err: TokeniseError } {
    std.debug.assert(std.mem.endsWith(u8, extract.original_name, DESC_TAG));
    if (extract.outer_type != []const u8) {
        return .{ .Err = .{ .DescriptionIsNotAString, "The field '" ++ extract.original_name ++ "' is parsed as a description because it ends with '" ++ DESC_TAG ++ "', so it should be a '[]const u8'." } };
    } else if (extract.default) |p| {
        return .{ .Ok = @as(*const []const u8, @ptrCast(@alignCast(p))).* };
    } else {
        return .{ .Err = .{ .DescriptionMissingDefaultValue, "The field '" ++ extract.original_name ++ "' should be filled out with a string that will appear in help." } };
    }
}

fn tokenise_module(comptime Spec: type,
    comptime required_options: struct{ [][]const []const u8, *usize},
    comptime path: []const []const u8,
    comptime previous_options: []const TokenisedOption,
    comptime config: Config,
) TokeniseResult {
    const spec_info = @typeInfo(Spec).Struct;
    const first_pass = first_pass: {
        var fields: [spec_info.fields.len]FieldExtract = undefined;
        var subcommands: ?FieldExtract = null;
        var description: []const u8 = "";
        var len = 0;
        for (spec_info.fields) |field| {
            // Remove the one layer of indirection for optionals arguments
            const inner_type = switch (@typeInfo(field.type)) {
                inline .Optional => |x| x.child,
                inline else => field.type,
            };

            const extract = FieldExtract{
                .outer_type = field.type,
                .inner_type = inner_type,
                .original_name = field.name,
                .name = if (config.replace_underscore_with_dash) name: {
                    var original: [field.name.len]u8 = undefined;
                    @memcpy(&original, field.name);
                    std.mem.replaceScalar(u8, &original, '_', '-');
                    break :name &original;
                } else field.name,
                .default = field.default_value,
            };
            if (@typeInfo(inner_type) == .Union) {
                if (subcommands) |old| {
                    return .{ .Err = .{ .TwoSubcommandFields, "Two unions '" ++ old[1] ++ "' and '" ++ extract.name ++ "' exist. Use only one union to specify subcommands." } };
                } else {
                    subcommands = extract;
                }
            } else if (std.mem.eql(u8, extract.original_name, DESC_TAG)) {
                // Zig will ensure that you cannot have two fields of the same name
                std.debug.assert(description.len == 0);
                switch (handle_description(extract)) {
                    inline .Ok => |s| description = s,
                    inline .Err => |err| return .{ .Err = err },
                }
            } else {
                fields[len] = extract;
                len += 1;
            }
        }

        const less_than = struct {
            fn f(_: void, comptime lhs: FieldExtract, comptime rhs: FieldExtract) bool {
                return std.mem.lessThan(u8, lhs.name, rhs.name);
            }
        }.f;

        // Broken as of since zig 0.10 -> 0.11
        // https://github.com/ziglang/zig/issues/16454
        //std.mem.sortUnstable(FieldExtract, fields[0..len], {}, less_than);

        // Replacement bubble sort
        for (0..len) |j| {
            for (j + 1..len) |k| {
                if (less_than(undefined, fields[k], fields[j])) {
                    const temp = fields[k];
                    fields[k] = fields[j];
                    fields[j] = temp;
                }
            }
        }

        break :first_pass .{
            .description = description,
            .subcommands = subcommands,
            .sorted_extracts = fields[0..len],
        };
    };
    //_ = sorted_fields;

    // Tag
    const options = second_pass: {
        const extract_count = first_pass.sorted_extracts.len;
        var options: [extract_count + previous_options.len]TokenisedOption = undefined;
        var option_count = 0;
        var index = 0;

        while (index < extract_count) {
            const prefix = first_pass.sorted_extracts[index].original_name;
            var main = first_pass.sorted_extracts[index];
            var description_extract: ?FieldExtract = null;
            var completion__extract: ?FieldExtract = null;
            index += 1;

            //std.debug.assert(std.mem.lessThan(u8, COMP_TAG, DESC_TAG));
            if (std.mem.endsWith(u8, prefix, DESC_TAG) or std.mem.endsWith(u8, prefix, COMP_TAG)) {
                return .{ .Err = .{ .MissingField, "The field '" ++ main.original_name ++ "' is an invalid field name. Fields cannot end with '" ++ DESC_TAG ++ "' or '" ++ COMP_TAG ++ "'"  } };
            }

            for (0..2) |_| {
                if (index >= extract_count) break;
                const extract = first_pass.sorted_extracts[index];
                if (!std.mem.startsWith(u8, extract.original_name, prefix)) {
                    break;
                } else if (std.mem.eql(u8, extract.original_name[prefix.len..], DESC_TAG)) {
                    std.debug.assert(description_extract == null);
                    index += 1;
                    description_extract = extract;
                } else if (std.mem.eql(u8, extract.original_name[prefix.len..], COMP_TAG)) {
                    std.debug.assert(completion__extract == null);
                    index += 1;
                    completion__extract = extract;
                }
            }

            // Narrow `type` down into allowed types and converted into ParsedTypeInfo
            const type_spec: ParsedTypeInfo = switch (@typeInfo(main.inner_type)) {
                .Type => return .{ .Err = .{ .UnsupportedFieldType, "Fields of type 'type' do not make sense at runtime" } },
                .Void => @compileError("Is there a point to void options? Use this instead of bool?"),
                .Bool => .Bool,
                .NoReturn => @compileError("Unreachable does not make sense for arg parsing."),
                .Int  => |info| .{ .Int = info },
                .Float  => |info| .{ .Float = info },
                .Pointer => @compileError("TODO: pointer"),
                //.Pointer  => |info| blk: {
                //    if (info.size != .Slice) @compileError("Use []" ++ (if (info.is_const) "const " else "") ++ @typeName(info.child) ++ " instead");
                //    if (info.is_volatile) @compileError("Does it make sense for []const u8 to be volatile?");
                //    // @TODO: It probably does make sense to have []const u8 instead of only []u8
                //    if (info.is_const) @compileError("Does it make sense for []const u8 to be constant? Probably does");
                //    if (info.is_allowzero) @compileError("For kernal code (mappable 0 address). Does this even make sense for that use-case?");
                //    if (info.address_space != .generic) @compileLog("Not really positive what this means address_space is for" ++ @tagName(info.address_space));

                //    switch (info.child) {
                //        u8 => break :blk .Item,
                //        else => @compileLog("TODO: pointer to " ++ @typeName(info.child)),
                //    }

                //    //std.debug.assert(info.alignment == 1);
                //    break :blk .{ .Item = info };
                //},
                .Array => @compileError("TODO: array"),
                .Struct => @compileError("Struct is unsupported for options"),
                .ComptimeFloat => @compileError("TODO: not a runtime value"),
                .ComptimeInt => @compileError("TODO: not a runtime value"),
                .Undefined => @compileError("TODO: not a runtime value"),
                .Null => @compileError("TODO: error set same as enum?"),
                .Optional => @compileError("TODO: error set same as enum?"),
                .ErrorUnion => @compileError("TODO: not a runtime value"),
                .ErrorSet => @compileError("TODO: error set same as enum?"),
                .Enum => .{ .Enum = autocomplete.enum_names(main.inner_type) },
                .Union => unreachable, // Already handled by `tokenise()`
                .Fn => @compileError("Not a runtime value: function"),
                .Opaque => @compileError("Unsupported: Opaque"),
                .Frame => @compileError(""),
                .AnyFrame => @compileError(""),
                .Vector => @compileError(""),
                .EnumLiteral => @compileError(""),
                //else => |Ty| @compileError("TODO: '" ++ Ty ++ "' is a new type not yet handled by penzai"),
            };

            const description = if (description_extract) |d| switch (handle_description(d)) {
                .Ok => |ok| ok,
                .Err => |err| return .{ .Err = err },
            } else return .{ .Err = .{.MissingDescription, "The field '" ++ main.original_name ++ "' does not have a description field '" ++ main.name ++ DESC_TAG  ++ "'."} };

            // 
            const completion = if (completion__extract) |e| switch (e.outer_type) {
                inline autocomplete.CompletionFunction => |ACFn| if (e.default) |p|
                    @as(*const ACFn, @ptrCast(@alignCast(p))).*
                else return .{ .Err = .{ .CompletionMissingDefaultValue, "The field '" ++ completion__extract.original_name ++ "' is missing the implementation for its completion function. Either remove this decleration or provide a default value." } },
            
                inline else => return .{ .Err = .{ .CompletionIsIncorrectType, "The field '" ++ completion__extract.original_name ++ "' should be the type '" ++ @typeName(autocomplete.CompletionFunction) ++ "'."} },

            // Default implementation of autocompletion functions
            } else switch (@typeInfo(main.inner_type)) {
                inline .Enum => autocomplete.enum_completion(type_spec.Enum),
                inline else => hello,
            };

            const is_required = main.inner_type == main.outer_type;
            const struct_path = add_to_path([]const u8, path, main.original_name);

            options[option_count] = TokenisedOption {
                .type_spec = type_spec,
                .type_name = @typeName(main.inner_type),
                .is_required = is_required,
                .name = main.name,

                .description = description,
                .completion = completion,
                .struct_path = struct_path,

            };
            if (is_required) {
                required_options[0][required_options[1].*] = struct_path;
                required_options[1].* += 1;
            }
            option_count += 1;
        }
        inline for (previous_options) |opt| {
            options[option_count] = opt;
            option_count += 1;
        }
        break :second_pass options[0..option_count];
    };


    //var subcommands: []const TokenisedSubcommand = &[0]TokenisedSubcommand{};
    const subcommands = if (first_pass.subcommands) |extract| blk: {
        const info = @typeInfo(extract.inner_type).Union;
        const base_path = path_to_struct: {
            const path_to_union = add_to_path([]const u8, path, extract.original_name);
            // Unwraps the optional
            if (extract.inner_type == extract.outer_type) {
                const path_to_some = add_to_path([]const u8, path_to_union, "");
                required_options[0][required_options[1].*] = path;
                required_options[1].* += 1;
                break :path_to_struct path_to_some;
            } else break :path_to_struct path_to_union;
        };

        var subcommands: [info.fields.len]TokenisedSubcommand = undefined;
        inline for (0.., info.fields) |i, cmd| {
            switch (@typeInfo(cmd.type)) {
                .Struct => subcommands[i] = switch (tokenise_module(cmd.type, required_options, base_path, &.{}, config)) {
                    .Ok => |ok| ok,
                    .Err => |err| return .{ .Err = err },
                },
                else => return .{ .Err = .{ .SubcommandIsNotAStruct, "The subcommand '" ++ cmd.name ++ "' must be a struct" } },
            }

        }
        break :blk &subcommands;
    } else &[0]TokenisedSubcommand{};

    // @TODO: Should we require descriptions to be defined?
    return .{
        .Ok = TokenisedSubcommand{
            .struct_path = path,
            .description = first_pass.description,
            .subcommand_is_required = if (first_pass.subcommands) |extract| extract.inner_type == extract.outer_type else false,
            .subcommands = subcommands,
            .options = options,

            //required_options: []const TokenisedOption = &[0]TokenisedOption{},
            //inherited_options: []const TokenisedOption = &[0]TokenisedOption{},
        },
    };
}

pub fn unwrap_tokenise_result(comptime result: TokenisedAstResult) TokeniseSpec {
    return switch (result) {
        inline .Ok => |ok| ok,
        inline .Err => |err| @compileError(std.fmt.comptimePrint("{s} - {s}", .{
            @typeInfo(TokeniseErrorEnum).ErrorSet.?[@intFromEnum(err[0])].name,
            err[1]
        })),
    };
}

//pub fn unwrap_tokenise_result(comptime result: TokeniseResult) TokenisedSubcommand {
//    return switch (result) {
//        inline .Ok => |ok| ok,
//        inline .Err => |err| @compileError(std.fmt.comptimePrint("{s} - {s}", .{
//            @typeInfo(TokeniseErrorEnum).ErrorSet.?[@intFromEnum(err[0])].name,
//            err[1]
//        })),
//    };
//}


test "tokenise_rework" {
    const Clap = struct {
        comptime __help: []const u8 = "This is a description for the program itself",
        subcommands: ?union {
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
                return &[_][]const u8{ "hello", "world" };
            }
        }.comp,
        // @NOTE: try experimenting with different usizes, causes this to fail on print("{!}")
        baz: u8,
    };

    std.debug.print("===\n", .{});

    const tokens = tokenise(Clap, .{ .replace_underscore_with_dash = true });
    inline for (tokens.Ok.ast.options) |opt| {
        //std.debug.print("{s}\n", .{opt.name});
        //@compileLog(opt.struct_path);
        _ = opt;
    }
    inline for (tokens.Ok.required_options) |path| {
        std.debug.print("required: {s}\n", .{path});
    }
    std.debug.print("===\n", .{});
}

////////////////////////////////////////////////////////////////////////////////
// Test
////////////////////////////////////////////////////////////////////////////////

// Because tokenisation happens at comptime, we need tests, zig build only
// does parsing, not semantic analysis. We need tests to explore all code
// paths.
test "EmptyStruct" {
    const result = comptime tokenise(struct {}, .{});
    try expect(result == .Ok);
}

test "MissingDescription" {
    const result1 = comptime tokenise(struct {
        a: ?u8,
    }, .{});
    try expect(result1.Err[0] == .MissingDescription);

    const result2 = comptime tokenise(struct {
        comptime a__help: []const u8 = "",
        a: ?u8,
        b: ?u8,
    }, .{});
    //@compileLog("{s}\n", .{@tagName(result2)});
    try expect(result2.Err[0] == .MissingDescription);
}

test "MissingField" {
    const result1 = comptime tokenise(struct {
        comptime a__help: []const u8 = "",
    }, .{});
    try expect(result1.Err[0] == .MissingField);

    const result2 = comptime tokenise(struct {
        comptime a__help: []const u8 = "",
        a: ?u8,
        comptime b__help: []const u8 = "",
    }, .{});
    try expect(result2.Err[0] == .MissingField);
}

test "DescriptionIsNotAString" {
    const result = comptime tokenise(struct {
        comptime a__help: u8 = 12,
        a: ?u8,
    }, .{});
    try expect(result.Err[0] == .DescriptionIsNotAString);
}

test "DescriptionMissingDefaultValue" {
    const result = comptime tokenise(struct {
        a__help: []const u8,
        a: ?u8,
    }, .{});
    try expect(result.Err[0] == .DescriptionMissingDefaultValue);
}

//test "FieldIsAnInvalidType" {
//    const result = tokenise(struct {
//        a__help: []const u8,
//        a: ?u8,
//    }, &[0]type{}, &[0][]u8{});
//    try expect(result.Err[0] == .FieldIsAnInvalidType);
//}

//test "TwoSubcommandFields" {
//    const result = tokenise(struct {
//        comptime a__help: []const u8 = "",
//        a: ?u8,
//
//        subcmd1: ?union
//    }, &[0]type{}, &[0][]u8{});
//    try expect(result.Err[0] == .TwoSubcommandFields);
//}

    //TwoSubcommandFields,
    //SubcommandIsNotAStruct,

