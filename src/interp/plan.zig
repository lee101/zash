const ast = @import("../ast.zig");

pub const Strategy = enum { general };

pub fn classify(p: ast.Pipeline) Strategy {
    _ = p;
    return .general;
}
