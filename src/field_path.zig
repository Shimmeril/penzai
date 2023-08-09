// This module is comptime
const std = @import("std");
const expect = std.testing.expect;

const util = @import("util.zig");

/// This is only used at comptime, the result of a parse should only be exposed through the .Ok value
const FieldError = struct {
    []const u8,
    []const u8,
    []const u8,
};

const FieldResult = union(util.Result) {
    Ok: type,
    Err: FieldPathError,
};

const FieldPathErrorSet = error{
    InvalidVariant,
    InvalidOptionalRoute,
    InvalidFieldRoute,
};
const FieldPathError = struct { util.constructEnumFromError(FieldPathErrorSet), []const u8 };

/// Like calling `@field(s, name)` on a struct, but calling it for the type %[T]
pub fn select_field_type_by_name(comptime T: type, comptime name: []const u8) FieldResult {
    const selectFieldInInfoOutType = struct {
        fn struct_union_same_code(comptime info: anytype) FieldResult {
            inline for (info.fields) |field| {
                if (std.mem.eql(u8, field.name, name)) return .{ .Ok = field.type };
                //msg = msg ++ field.name ++ "\n";
            }

            // If no field found, then
            const field_format = "- '{s}'\n";
            var join_len = 0;
            inline for (info.fields) |field| join_len += std.fmt.count(field_format, .{field.name});
            var join: [join_len]u8 = undefined;
            var i = 0;
            inline for (info.fields) |field| {
                std.mem.copyForwards(u8, join[i..], std.fmt.comptimePrint(field_format, .{field.name}));
                i += std.fmt.count(field_format, .{field.name});
            }

            return .{ .Err = .{ .InvalidVariant, name ++ @typeName(T) ++ &join } };
        }
    }.struct_union_same_code;

    switch (@typeInfo(T)) {
        .Struct => |info| return selectFieldInInfoOutType(info),
        .Union => |info| return selectFieldInInfoOutType(info),
        .Optional => |info| {
            return if (name.len != 0)
                .{ .Err = .{ .InvalidOptionalRoute, "Use the empty string \"\" instead of " ++ name ++ " for optionals." } }
            else
                .{ .Ok = info.child };
        },
        else => return .{ .Err = .{ .InvalidFieldRoute, "The field '" ++ name ++ "' is not a struct, union, or optional" } },
    }
}

/// Recursive logic for select_field_type_by_name
fn select_field_type_by_path(comptime T: type, comptime path: []const []const u8) FieldResult {
    const len = path.len;
    switch (len) {
        0 => return .{ .Ok = T },
        1 => return select_field_type_by_name(T, path[0]),
        else => {
            const result_pair = select_field_type_by_name(T, path[0]);
            switch (result_pair) {
                .Ok => |ty| return select_field_type_by_path(ty, path[1..len]),
                else => |err| return FieldResult.Err{err},
            }
        },
    }
}

fn point_to_field_type(comptime T: type, comptime path: []const []const u8) type {
    return switch (select_field_type_by_path(T, path)) {
        .Ok => |ty| union(util.Result) { Ok: *ty, Err: FieldPathError },
        .Err => union(util.Result) { Ok: void, Err: FieldPathError },
    };
}

// Recursively do @field(@field(@field(..., path[0]), path[1]), ...) on {s}
pub fn pointToField(comptime T: type, s: *T, comptime path: []const []const u8) point_to_field_type(T, path) {
    const len = path.len;
    if (len == 0) return .{ .Ok = s };

    // Evaluate path[0]
    // Use `select_field_type_by_name()` instead of @typeInfo(T).Struct for better error message
    const first_child_type_result = select_field_type_by_name(T, path[0]);
    const first_child_pointer = switch (first_child_type_result) {
        // Repeat expansion logic of select_field_type_by_name, since we what to
        // `.?` expand an optional instead of `@field()` expanding it
        .Ok => switch (@typeInfo(T)) {
            .Optional => blk: {
                std.debug.assert(path[0].len == 0);
                // Do not use the `typeInfo(T).Pointer.inner_value` because then
                // we have to remove the const from it with @constcast. This
                // creates a new pointer in the data region
                // We can `.?` because already checked in `select_field_type_by_name()`
                break :blk &s.*.?;
            },
            else => &@field(s.*, path[0]),
        },
        .Err => |e| return .{ .Err = e },
    };
    if (len == 1) return .{ .Ok = first_child_pointer };

    std.debug.assert(len > 1);
    const first_child_type = first_child_type_result.Ok;
    const final_child_pointer = pointToField(first_child_type, first_child_pointer, path[1..len]);
    return .{ .Ok = final_child_pointer.Ok };
}

//run: zig test %

const TestStruct = struct {
    subcmd: union {
        option: struct {
            value: u8,
        },
        invalid: bool,
    },
    hello: ?struct {
        name: []const u8,
    },
};

test "error" {
    var s = TestStruct{
        .subcmd = .{ .option = .{ .value = 1 } },
        .hello = .{
            .name = "world",
        },
    };
    try expect(pointToField(TestStruct, &s, &[_][]const u8{"a"}).Err[0] == .InvalidVariant);
    //try expect(pointToField(TestStruct, &s, &[_][]const u8{"hello"}).Err[0] == .InvalidVariant);
    //std.debug.print("{}\n", .{pointToField(TestStruct, &s, &[_][]const u8{"hello", "", "name"})});
}

test "explore" {
    var s = TestStruct{
        .subcmd = .{ .option = .{ .value = 1 } },
        .hello = .{
            .name = "world",
        },
    };
    try expect(pointToField(TestStruct, &s, &[_][]const u8{}).Ok == &s);
    try expect(pointToField(TestStruct, &s, &[_][]const u8{"subcmd"}).Ok == &s.subcmd);
    try expect(pointToField(TestStruct, &s, &[_][]const u8{ "subcmd", "option" }).Ok == &s.subcmd.option);
    try expect(pointToField(TestStruct, &s, &[_][]const u8{ "subcmd", "option", "value" }).Ok == &s.subcmd.option.value);

    try expect(pointToField(TestStruct, &s, &[_][]const u8{"hello"}).Ok == &s.hello);
    try expect(pointToField(TestStruct, &s, &[_][]const u8{ "hello", "" }).Ok == &s.hello.?);
    try expect(pointToField(TestStruct, &s, &[_][]const u8{ "hello", "", "name" }).Ok == &s.hello.?.name);
}

test "mutation" {
    var s = TestStruct{ .subcmd = .{
        .invalid = false,
    }, .hello = .{
        .name = "world",
    } };
    const names = [_][]const u8{ "subcmd", "invalid" };

    try expect(s.subcmd.invalid == false);
    const idx = 1;
    const asdf = pointToField(TestStruct, &s, names[0 .. idx + 1]);
    asdf.Ok.* = true;
    try expect(s.subcmd.invalid == true);
}

test "mutate_optional" {
    //const tokenise = @import("tokenise.zig");
    const OptionalSubcommands = struct {
        modules: ?union {
            a: u8,
            b: u8,
        },
    };
    //const parsed = comptime tokenise.unwrapTokeniseResult(tokenise.tokeniseStruct(OptionalSubcommands, &[0][]const u8{}));
    const path = &[_][]const u8{"modules"};

    var instance: OptionalSubcommands = .{ .modules = null };
    var s = &instance;

    const ty = point_to_field_type(OptionalSubcommands, path);
    const ptr = pointToField(OptionalSubcommands, s, path);
    std.debug.assert(@TypeOf(ptr.Ok) == @typeInfo(ty).Union.fields[0].type);

    ptr.Ok.* = .{ .a = 5 };
    try expect(s.modules.?.a == 5);
    ptr.Ok.* = null;
    try expect(s.modules == null);
}
