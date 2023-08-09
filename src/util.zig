const std = @import("std");

pub const Result = enum {
    Ok,
    Err,
};

/// Construct an enum. To construct it from Errors, do the following:
///
/// const Err = error { Sample }
/// const Tag = constructEnum(
///     std.builtin.Type.Error,
///     @typeInfo(Err).ErrorSet.?,
///     struct {
///         fn func(variant: std.builtin.Type.Error) []const u8 { return variant.name; }
///     }.func,
/// );
pub fn constructEnum(comptime T: type, comptime variants: []const T, comptime map: fn (T) []const u8) type {
    var fields: [variants.len]std.builtin.Type.EnumField = undefined;
    for (0.., variants) |i, tag| {
        fields[i] = std.builtin.Type.EnumField{ .name = map(tag), .value = i };
    }
    var enum_backend: type = undefined;
    for (0..128 + 1) |i| {
        enum_backend = @Type(.{
            .Int = .{
                .signedness = std.builtin.Signedness.unsigned,
                .bits = i,
            },
        });
        if (variants.len <= std.math.maxInt(enum_backend)) break;
    }
    return @Type(.{ .Enum = .{
        .tag_type = enum_backend,
        .fields = &fields,
        .decls = &[_]std.builtin.Type.Declaration{},
        .is_exhaustive = true,
    } });
}

pub fn constructEnumFromError(comptime err: type) type {
    return constructEnum(
        std.builtin.Type.Error,
        @typeInfo(err).ErrorSet.?,
        struct {
            fn func(variant: std.builtin.Type.Error) []const u8 {
                return variant.name;
            }
        }.func,
    );
}

test "constructEnum" {
    const Err = error{
        Overflow,
        OutOfMemory,
    };
    const Tag = constructEnum(
        std.builtin.Type.Error,
        @typeInfo(Err).ErrorSet.?,
        struct {
            fn func(variant: std.builtin.Type.Error) []const u8 {
                return variant.name;
            }
        }.func,
    );

    const UseTag = union(Tag) {
        Overflow: u8,
        OutOfMemory: u8,
    };

    const example = UseTag{ .Overflow = 18 };
    try std.testing.expectEqual(example.Overflow, 18);
}

fn make_iterator(comptime NextItem: type) type {
    return struct {
        const Self = @This();
        pub const Item = NextItem;

        iter: *anyopaque,
        iter_next: *const fn (*anyopaque) ?Item,

        pub fn init(comptime Impl: type, impl: *Impl) Self {
            const ptr_info = @typeInfo(*Impl);

            if (ptr_info != .Pointer) @compileError(@typeName(Impl) ++ ".ptr must be a pointer");
            if (ptr_info.Pointer.size != .One) @compileError(@typeName(Impl) ++ ".ptr must be a single item pointer");
            return .{
                .iter = impl,
                .iter_next = struct {
                    pub fn f(pointer: *anyopaque) ?Item {
                        const self: *Impl = @ptrCast(@alignCast(pointer));
                        return @call(.always_inline, ptr_info.Pointer.child.impl_next, .{self});
                    }
                }.f,
            };
        }
        pub inline fn next(self: Self) ?Item {
            return self.iter_next(self.iter);
        }
    };
}

pub const IterToString = make_iterator([]const u8);
pub const ArrayIter = struct {
    const Self = @This();

    dynamic_array: []const [:0]const u8,

    pub fn iterator_interface(self: *Self) IterToString {
        return IterToString.init(Self, self);
    }

    pub fn impl_next(self: *Self) ?IterToString.Item {
        if (self.dynamic_array.len == 0) return null;
        const ret = self.dynamic_array[0];
        self.dynamic_array = self.dynamic_array[1..];
        return ret;
    }
};

//run: zig build test

test "hello" {
    if (false) {
        var range = ArrayIter{ .dynamic_array = &[_][]const u8{ "hello", "bcde" } };
        const iter = range.iterator_interface();
        try std.testing.expectEqualStrings("hello", iter.next() orelse "<null>");
        try std.testing.expectEqualStrings("bcde", iter.next() orelse "<null>");
        try std.testing.expectEqual(@as(?[]const u8, null), iter.next());
    }
}
