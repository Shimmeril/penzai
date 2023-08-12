// Comptime tokenisation and comptime helper function for printing
// Our library only has two steps, token generation and token consumption
// This mo
const std = @import("std");
const expect = std.testing.expect;
const Type = std.builtin.Type;

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
 

////////////////////////////////////////////////////////////////////////////////
// Algebraic-type-like result type
////////////////////////////////////////////////////////////////////////////////

// There is five places where the same code will appear
// * enum for the tag
// * type definition for the result union
// * union for the result which contains the error message
// *
const TokeniseErrorEnum = error {
    MissingField,
    MissingDescription,
    DescriptionIsNotAString,
    DescriptionMissingDefaultValue,
    FieldIsAnInvalidType,

    TwoSubcommandFields,
    SubcommandIsNotAStruct,
    //CompletionFunctionUnexpectedType,
};
const TokeniseError = struct { util.constructEnumFromError(TokeniseErrorEnum), []const u8};


const TokeniseResult = union(util.Result) { Ok: TokenisedSpec, Err: TokeniseError};
//@typeInfo(tokeniseStruct2).Fn.return_type.?;
pub fn unwrapTokeniseResult(comptime result: TokeniseResult) TokenisedSpec {
    return switch (result) {
        .Ok => |ok| ok,
        .Err => |err| @compileError(std.fmt.comptimePrint("{s} - {s}", .{
            @typeInfo(TokeniseErrorEnum).ErrorSet.?[@intFromEnum(err[0])].name,
            err[1]
        })),
    };
}


pub const TokenisedSpec = struct {
    param_path: []const []const u8,
    description: []const u8,
    subcommand_path: ?[]const []const u8,
    subcommands: []const TokenisedSpec,
    options: []const FieldToken,
    is_optional: bool,

    //required_options: []const FieldToken = &[0]FieldToken{},
    //inherited_options: []const FieldToken = &[0]FieldToken{},

    pub fn name(comptime self: @This()) []const u8 {
        return if (self.param_path.len == 0) "" else self.param_path[self.param_path.len - 1];
    }
};

pub const FieldToken = struct {
    type_spec: ParsedTypeInfo,
    type_name: []const u8,
    is_optional: bool,
    name: []const u8,

    description: []const u8,
    completion: ?[]const []const u8,
    completion_function: autocomplete.CompletionFunction,
    param_path: []const []const u8,

    pub fn name(comptime self: @This()) []const u8 {
        return if (self.param_path.len == 0) "" else self.param_path[self.param_path.len - 1];
    }
};

////////////////////////////////////////////////////////////////////////////////
// Generate Tokens - Parsing
////////////////////////////////////////////////////////////////////////////////

// Parse step before FieldToken
const FieldExtract = struct{type, []const u8, ?*const anyopaque};

fn addToPath(comptime T: type, comptime path: []const T, comptime addition: T) []const T {
    var new_path: [path.len + 1]T = undefined;
    inline for (0..path.len) |i| {
        new_path[i] = path[i];
    }
    new_path[path.len] = addition;
    return &new_path;
}




/// Any errors this produces should be resolved at comptime as we are parsing the CLI args struct
/// Subcommands (unions) are processed recursively
pub fn tokeniseStruct(comptime T: type, comptime path: []const []const u8) TokeniseResult {
    if (!@inComptime()) @compileError("Call this with comptime at site");

    const sorted = comptime sorted: {
        const fields = @typeInfo(T).Struct.fields;
        var unsorted: [fields.len]FieldExtract = undefined;
        var has_description = false;
        var subcmd_extract: ?FieldExtract = null;
        var is_optional = false;

        //for (0.., fields) |i, x| @compileLog("hello:", i, x.name);

        var i = 0;
        for (fields) |field| {
            const info = @typeInfo(field.type);
            const extract = .{field.type, field.name, field.default_value};
            if (info == .Union or (info == .Optional and @typeInfo(info.Optional.child) == .Union)) {
                if (subcmd_extract) |old| return .{ .Err = .{.TwoSubcommandFields, "Two unions '" ++ old[1] ++ "' and '" ++ field[1] ++ "' exist. Use only one union to specify subcommands."} };

                if (info == .Optional) {
                    subcmd_extract = .{info.Optional.child, field.name, field.default_value};
                    is_optional = true;
                } else {
                    subcmd_extract = extract;
                }
            } else {
                has_description = has_description or std.mem.eql(u8, field.name, DESC_TAG);
                unsorted[i] = extract;
                i += 1;
                std.debug.assert(std.mem.lessThan(u8, field.name, field.name ++ DESC_TAG));
            }
        }


        const adjusted_len = i;
        const sorter = struct {
            fn lessThan(_: void, comptime lhs: FieldExtract, comptime rhs: FieldExtract) bool {
                if (std.mem.eql(u8, lhs[1], DESC_TAG)) return true;
                if (std.mem.eql(u8, rhs[1], DESC_TAG)) return false;
                return std.mem.lessThan(u8, lhs[1], rhs[1]);
            }
        };

        // Broken as of since zig 0.10 -> 0.11
        // https://github.com/ziglang/zig/issues/16454
        //std.mem.sortUnstable(FieldExtract, unsorted[0..adjusted_len], {}, sorter.lessThan);

        // Replacement bubble sort
        for (0..adjusted_len) |j| {
            for (j + 1..adjusted_len) |k| {
                if (sorter.lessThan(undefined, unsorted[k], unsorted[j])) {
                    const temp = unsorted[k];
                    unsorted[k] = unsorted[j];
                    unsorted[j] = temp;
                }
            }
        }

        break :sorted .{
            .fields = unsorted[0..adjusted_len],
            .has_description = has_description,
            .subcommands = subcmd_extract,
            .subcommands_is_optional = is_optional,
        };
    };
    //inline for (sorted.fields) |a| @compileLog(a); @compileLog();
    //@compileLog(@typeName(T), sorted.fields);

    // Parse the descriptions
    const tagged = comptime tagged: {
        // Description for the current struct {T}
        var help_text: ?[]const u8 = null;

        const len = (sorted.fields.len >> 1) + 1;
        var fields: [len]FieldExtract = undefined;
        // Descriptions for each field
        var descriptions: [len][]const u8 = undefined;
        var completions: [len]struct{?[]const []const u8, autocomplete.CompletionFunction} = undefined;

        //var buffer: ?FieldExtract = FieldExtract{u8, "", ""};
        //_ = buffer;
        var inp = if (sorted.has_description) blk: {
            std.debug.assert(std.mem.eql(u8, sorted.fields[0][1], DESC_TAG));
            break :blk 1;
        } else 0;

        var out = 0;
        inline while (inp < sorted.fields.len) {
            const param_index = inp;
            const param_name = sorted.fields[param_index][1];
            //if (inp + 0 < sorted.fields.len) @compileLog(inp + 0, sorted.fields[inp + 0][1]);
            //if (inp + 1 < sorted.fields.len) @compileLog(inp + 1, sorted.fields[inp + 1][1]);
            //if (inp + 2 < sorted.fields.len) @compileLog(inp + 2, sorted.fields[inp + 2][1]);

            const PARAM_OR_NOARG = 0b00;
            const COMPLETION = 0b01;
            const DESCRIPTION = 0b10;
            const UNREACHABLE = 0b11;
            var flags = [_]u2{PARAM_OR_NOARG, PARAM_OR_NOARG, PARAM_OR_NOARG};
            for (0..3) |j| {
                if ((inp + j) >= sorted.fields.len) break;
                if (!std.mem.startsWith(u8, sorted.fields[inp + j][1], param_name)) break;
                const is_comp = std.mem.endsWith(u8, sorted.fields[inp + j][1], COMP_TAG);
                const is_desc = std.mem.endsWith(u8, sorted.fields[inp + j][1], DESC_TAG);
                std.debug.assert((is_comp and is_desc) == false);

                if (is_comp) flags[j] = COMPLETION;
                if (is_desc) flags[j] = DESCRIPTION;
            }

            // Required
            fields[out] = switch (flags[0]) {
                PARAM_OR_NOARG => blk: { defer inp += 1; break :blk sorted.fields[param_index]; },
                COMPLETION     => return .{ .Err = .{.MissingField, "The help description '" ++ param_name ++ "' is missing the corresponding field '" ++ param_name[0..param_name.len - DESC_TAG.len] ++ "'."} },
                DESCRIPTION    => return .{ .Err = .{.MissingField, "The completion rule '" ++ param_name ++ "' is missing the corresponding field '" ++ param_name[0..param_name.len - COMP_TAG.len]  ++ "'."} },
                UNREACHABLE    => unreachable,
            };

            // Description is required, Completion is optional. Completion is present appears before description ("comp" -> "desc")
            const to_check: struct{FieldExtract, ?FieldExtract} = switch (flags[1] | @as(u4, flags[2]) << 2) {
                (COMPLETION | DESCRIPTION << 2) => blk: {
                    inp += 2;
                    std.debug.assert(std.mem.startsWith(u8, sorted.fields[param_index + 1][1], param_name));
                    std.debug.assert(std.mem.startsWith(u8, sorted.fields[param_index + 1][1], param_name));
                    break :blk .{sorted.fields[param_index + 2], sorted.fields[param_index + 1]};
                },
                (DESCRIPTION | PARAM_OR_NOARG << 2), (DESCRIPTION | COMPLETION << 2), (DESCRIPTION | DESCRIPTION << 2), => blk: {
                    inp += 1;
                    std.debug.assert(std.mem.startsWith(u8, sorted.fields[param_index + 1][1], param_name));
                    break :blk .{sorted.fields[param_index + 1], null};
                },

                (PARAM_OR_NOARG | PARAM_OR_NOARG << 2), (PARAM_OR_NOARG | COMPLETION << 2), (PARAM_OR_NOARG | DESCRIPTION << 2),
                (COMPLETION | PARAM_OR_NOARG << 2), (COMPLETION | COMPLETION << 2)
                => return .{ .Err = .{.MissingDescription, "The field '" ++ param_name ++ "' does not have a description field '" ++ param_name ++ DESC_TAG  ++ "'."} },

                else => |f| {
                    std.debug.assert(UNREACHABLE == 0b11);
                    std.debug.assert((f & 0b11 == 0b11) or (f >> 2 == 0b11));
                    @compileError(std.fmt.comptimePrint("You skipped the case: {d}", f));
                }
            };
            const desc = to_check[0];
            const maybe_comp = to_check[1];

            descriptions[out] = if (desc[0] != []const u8) {
                return .{ .Err = .{.DescriptionIsNotAString, "The field '" ++ desc[1] ++ "' is parsed as a description because it ends with '" ++ DESC_TAG ++ "', so it should be a '[]const u8'."} };
            // @TODO: use alignCast
            } else if (desc[2]) |p| blk: {
                const ptr: *const []const u8 = @ptrCast(@alignCast(p));
                break :blk ptr.*;
            } else {
                return .{ .Err = .{.DescriptionMissingDefaultValue, "The field '" ++ desc[1] ++ "' should be filled out with a string that will appear in help."} };
            };
            completions[out] = if (maybe_comp) |inner_comp| switch (inner_comp[0]) {
                inline autocomplete.CompletionFunction => |Ty| blk: {
                    const a: []const []const u8 = &[_][]const u8{"a"};
                    break :blk .{a, @as(*const Ty, @ptrCast(inner_comp[2].?)).* };
                },
                inline else => @compileError("TODO: missing value for completion"),
            } else switch (@typeInfo(sorted.fields[param_index][0])) {
                .Enum => .{ null, hello },
                else => .{ null, hello },
            };
            out += 1;
            //if (inp >= sorted.fields.len) break;
        }

        break :tagged .{
            .fields = fields[0..out],
            .descriptions = descriptions[0..out],
            .completions = completions[0..out],
            .help_text = help_text orelse "",
        };
    };

    var options: [tagged.fields.len]FieldToken = undefined;
    var to_process_subcmd: ?FieldToken = null;
    inline for (0.., tagged.fields) |i, extract| {
        const info = @typeInfo(extract[0]);
        const inner_type = if (@typeInfo(extract[0]) == .Optional)
            .{.ty = info.Optional.child, .is_optional = true}
        else {
            //.{.ty = extract[0], .is_required = true};
            return .{ .Err = .{.FieldIsAnInvalidType, "'" ++ extract[1] ++ "' is not an optional or a union"} };
        };

        switch (@typeInfo(inner_type.ty)) {
            inline .Struct => @compileError("@TODO: Struct inputs unsupported as of now, use a union to define subcommands"),
            inline .Optional => @compileError("@TODO: Is it even possible to do ??anytype in zig"),
            inline .Union => unreachable, // Already processed during {sorted}
            inline else => {},
        }


        const adjust = if (to_process_subcmd) |_| 1 else 0;
        options[i - adjust] = FieldToken{
            .type_spec           = reify_type_spec(inner_type.ty),
            .type_name           = @typeName(inner_type.ty),
            // Used by parse_args
            .is_optional         = inner_type.is_optional,

            // Without unwrapping the
            .completion          = tagged.completions[i][0],
            .completion_function = tagged.completions[i][1],
            .name                = extract[1],
            .description         = tagged.descriptions[i],
            .param_path          = addToPath([]const u8, path, extract[1]),
        };
        to_process_subcmd = null;
    }

    var subcommands: []const TokenisedSpec = &[0]TokenisedSpec{};
    const subcommand_path = if (sorted.subcommands) |extract| blk: {
        const info = @typeInfo(extract[0]).Union;
        const field_path = addToPath([]const u8, path, extract[1]);

        var temp: [info.fields.len]TokenisedSpec = undefined;
        const base_path = if (sorted.subcommands_is_optional) addToPath([]const u8, field_path, "") else field_path;

        inline for (0.., info.fields) |j, subcommand| {
            if (@typeInfo(subcommand.type) != .Struct) {
                return .{ .Err = .{.SubcommandIsNotAStruct, "The subcommand '" ++ subcommand.name ++ "' must be a struct"} };
            }
            temp[j] = unwrapTokeniseResult(tokeniseStruct(
                subcommand.type,
                addToPath([]const u8, base_path, subcommand.name)
                //addToPath([]const u8, addToPath([]const u8, path, extract[1]), subcommand.name)
            ));
        }
        subcommands = &temp;
        break :blk field_path;
    } else null;


    return .{
        .Ok = TokenisedSpec {
            .param_path      = path,
            .description     = tagged.help_text,
            .subcommand_path = subcommand_path,
            .subcommands     = subcommands,
            .options         = &options,
            .is_optional     = sorted.subcommands_is_optional,
        }
    };
}


////////////////////////////////////////////////////////////////////////////////
// Reconstructable TypeInfo
////////////////////////////////////////////////////////////////////////////////

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
    Enum: struct { tag_type_info: Type.Int, fields: []const []const u8, is_exhaustive: bool },
    Item, // String
    ItemList,
    ItemUnboundList,
};

// @TODO: convert all these @compileError()'s into result values
fn reify_type_spec(comptime T: type) ParsedTypeInfo {
    return switch (@typeInfo(T)) {
        .Type => @compileError("I cannot imagine a use case for arg parsing at compile time"),
        .Void => @compileError("Is there a point to void options? Use this instead of bool?"),
        .NoReturn => @compileError("Unreachable does not make sense for arg parsing."),
        .Pointer  => |info| blk: {
            if (info.size != .Slice) @compileError("Use []" ++ (if (info.is_const) "const " else "") ++ @typeName(info.child) ++ " instead");
            if (info.is_volatile) @compileError("Does it make sense for []const u8 to be volatile?");
            // @TODO: It probably does make sense to have []const u8 instead of only []u8
            if (info.is_const) @compileError("Does it make sense for []const u8 to be constant? Probably does");
            if (info.is_allowzero) @compileError("For kernal code (mappable 0 address). Does this even make sense for that use-case?");
            if (info.address_space != .generic) @compileLog("Not really positive what this means address_space is for" ++ @tagName(info.address_space));

            switch (info.child) {
                u8 => break :blk .Item,
                else => @compileLog("TODO: pointer to " ++ @typeName(info.child)),
            }

            //std.debug.assert(info.alignment == 1);
            break :blk .{ .Item = info };
        },
        //.Array => {},
        .Bool => .Bool,
        .Int  => |info| .{ .Int = info },
        .Float  => |info| .{ .Float = info },
        .Enum => |info| .{ .Enum = .{ .tag_type_info = @typeInfo(info).Int, .fields = info.fields, .is_exhaustive = info.is_exhaustive } },
        .Union => unreachable, // Already handled by `tokenise()`
        .Struct => @compileError("Struct is unsupported for options"),
        else => @compileError("TODO: " ++ @typeName(T)),
    };
}



////////////////////////////////////////////////////////////////////////////////
// Test
////////////////////////////////////////////////////////////////////////////////

// run: zig build test
//run: zig build run -freference-trace -- --baz 155



// Because tokenisation happens at comptime, we need tests, zig build only
// does parsing, not semantic analysis. We need tests to explore all code
// paths.
test "EmptyStruct" {
    const result = comptime tokeniseStruct(struct {}, &[0][]u8{});
    try expect(result == .Ok);
}

test "MissingDescription" {
    const result1 = comptime tokeniseStruct(struct {
        a: ?u8,
    }, &[0][]u8{});
    try expect(result1.Err[0] == .MissingDescription);

    const result2 = comptime tokeniseStruct(struct {
        comptime a__help: []const u8 = "",
        a: ?u8,
        b: ?u8,
    }, &[0][]u8{});
    //@compileLog("{s}\n", .{@tagName(result2)});
    try expect(result2.Err[0] == .MissingDescription);
}

test "MissingField" {
    const result1 = comptime tokeniseStruct(struct {
        comptime a__help: []const u8 = "",
    }, &[0][]u8{});
    try expect(result1.Err[0] == .MissingField);

    const result2 = comptime tokeniseStruct(struct {
        comptime a__help: []const u8 = "",
        a: ?u8,
        comptime b__help: []const u8 = "",
    }, &[0][]u8{});
    try expect(result2.Err[0] == .MissingField);
}

test "DescriptionIsNotAString" {
    const result = comptime tokeniseStruct(struct {
        comptime a__help: u8 = 12,
        a: ?u8,
    }, &[0][]u8{});
    try expect(result.Err[0] == .DescriptionIsNotAString);
}

test "DescriptionMissingDefaultValue" {
    const result = comptime tokeniseStruct(struct {
        a__help: []const u8,
        a: ?u8,
    }, &[0][]u8{});
    try expect(result.Err[0] == .DescriptionMissingDefaultValue);
}

//test "FieldIsAnInvalidType" {
//    const result = tokeniseStruct(struct {
//        a__help: []const u8,
//        a: ?u8,
//    }, &[0]type{}, &[0][]u8{});
//    try expect(result.Err[0] == .FieldIsAnInvalidType);
//}

//test "TwoSubcommandFields" {
//    const result = tokeniseStruct(struct {
//        comptime a__help: []const u8 = "",
//        a: ?u8,
//
//        subcmd1: ?union
//    }, &[0]type{}, &[0][]u8{});
//    try expect(result.Err[0] == .TwoSubcommandFields);
//}

    //TwoSubcommandFields,
    //SubcommandIsNotAStruct,
