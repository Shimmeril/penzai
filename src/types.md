1. completing a subcommand name
1. completing a option name
1. completion an argument to an option
1. completion a positional


custom completion functions -> []const u8

* Bool: void,              -> []
* Int: Int,                -> []
* Float: Float,            -> []
* Pointer: Pointer,        -> []
* Array: Array,            -> []
* Struct: Struct,          -> []
* Optional: Optional,      -> []
* ErrorSet: ErrorSet,      -> []const u8
* Enum: Enum,              -> []const u8
* Vector: Vector,          -> []
