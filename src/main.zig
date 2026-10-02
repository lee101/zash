const std = @import("std");
const zash = @import("zash");

pub fn main() void {
    std.debug.print("zash {s}\n", .{zash.version});
}
