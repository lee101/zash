const std = @import("std");

pub const version = "0.0.1";

test {
    std.testing.refAllDecls(@This());
}
