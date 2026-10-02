const std = @import("std");

pub const version = "0.0.1";

fn is_module_name(comptime name: []const u8) bool {
    if (name.len == 0 or std.ascii.isUpper(name[0])) return false;
    return !std.mem.eql(u8, name, "std") and !std.mem.eql(u8, name, "builtin");
}

fn ref_all(comptime T: type, comptime depth: u8) void {
    if (depth == 0) return;
    inline for (comptime std.meta.declarations(T)) |decl| {
        if (comptime is_module_name(decl.name)) {
            const v = @field(T, decl.name);
            if (@TypeOf(v) == type and @typeInfo(v) == .@"struct") {
                ref_all(v, depth - 1);
            }
        }
    }
}

test {
    std.testing.refAllDecls(@This());
    ref_all(@This(), 4);
}
