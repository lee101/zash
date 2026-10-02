const std = @import("std");
const common = @import("common.zig");

pub const common_mod = common;
pub const Ctx = common.Ctx;
pub const Stdio = common.Stdio;
pub const EnvView = common.EnvView;
pub const UtilFn = common.UtilFn;

pub const Entry = struct {
    name: []const u8,
    run: UtilFn,
    supports: common.SupportsFn,
    supports_env: ?common.SupportsEnvFn = null,
};

pub const entries = [_]Entry{
    .{ .name = "head", .run = @import("head.zig").run, .supports = @import("head.zig").supports },
    .{ .name = "cat", .run = @import("cat.zig").run, .supports = @import("cat.zig").supports },
    .{ .name = "wc", .run = @import("wc.zig").run, .supports = @import("wc.zig").supports, .supports_env = @import("wc.zig").supportsEnv },
    .{ .name = "tail", .run = @import("tail.zig").run, .supports = @import("tail.zig").supports },
};

fn find(name: []const u8) ?*const Entry {
    for (&entries) |*e| if (std.mem.eql(u8, e.name, name)) return e;
    return null;
}

pub fn lookup(name: []const u8) ?UtilFn {
    return (find(name) orelse return null).run;
}

pub fn supports(argv: []const []const u8) bool {
    if (argv.len == 0) return false;
    const e = find(argv[0]) orelse return false;
    return e.supports(argv);
}

pub fn supportsEnv(env: *const EnvView, argv: []const []const u8) bool {
    if (argv.len == 0) return false;
    const e = find(argv[0]) orelse return false;
    if (!e.supports(argv)) return false;
    if (e.supports_env) |f| return f(env, argv);
    return true;
}

test {
    std.testing.refAllDecls(@This());
}
